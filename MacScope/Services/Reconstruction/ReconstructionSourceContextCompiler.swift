import Foundation

/// A bounded view of an authenticated committed source cut. Receipt authentication stays with
/// the production owner; this compiler verifies content identities and exact selected coordinates.
struct ReconstructionSourceContextCompiler: Sendable {
    enum Failure: Error, Equatable {
        case invalidCut, oracleUnavailable, ambiguousOracle, invalidOracle
        case parentUnavailable, ambiguousParent, invalidParent, parentBounds
        case invalidDiagnostic, ambiguousDiagnostic, contextBounds
    }
    static let domain = "reconstruction.source-context.v10"
    static let maximumContextBytes = 32_768
    static let maximumBaseContextBytes = 16_384
    static let maximumParentBytes = 4_096
    static let evaluationOperationID = "reconstruction.source.evaluate"
    static let buildOperationID = "reconstruction.source.build"
    static let behaviorOperationID = "reconstruction.source.behavior"

    struct OracleSummary: Codable, Hashable, Sendable {
        let evidenceID: UUID
        let payloadSHA256: String
        let suiteSHA256: String
        let function: ReconstructionFunctionCoordinate
        let profileID: String
        let inputs: [UInt32]
        let outputs: [UInt32]
    }
    struct ParentSummary: Codable, Hashable, Sendable {
        let evidenceID: UUID
        let payloadSHA256: String
        let revisionSHA256: String
        let sourceSHA256: String
        let sourceText: String
    }
    struct DiagnosticSummary: Codable, Hashable, Sendable {
        let evidenceID: UUID
        let payloadSHA256: String
        let operationID: String
        let checkpointRevision: UInt64
        let revisionSHA256: String
        let sourceSHA256: String
        let diagnostic: String
    }
    struct Envelope: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let domain: String
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let evidenceIDs: [UUID]
        let baseContext: Data
        let baseContextSHA256: String
        let oracle: OracleSummary
        let parent: ParentSummary?
        let diagnostics: [DiagnosticSummary]
    }

    func compile(cut: ReconstructionEvidenceCut, query: ReconstructionRetrievalQuery,
        function: ReconstructionFunctionCoordinate, oracleSuiteSHA256: String,
        parentRevisionSHA256: String?) throws -> ReconstructionRetrievedContext {
        try Task.checkCancellation()
        guard ReconstructionSourceInferenceContract.isSHA256(oracleSuiteSHA256),
              parentRevisionSHA256.map(ReconstructionSourceInferenceContract.isSHA256) ?? true,
              cut.corpusManifestSHA256 == query.corpusManifestSHA256 else { throw Failure.invalidCut }
        // Validate the full cut, then compile only ordinary evidence for the bounded base. The
        // source records remain bound to the original frontier and are validated below. Gap
        // identifiers grant no source-channel authority and are omitted from source presentation.
        let base = try ReconstructionContextCompiler(maximumContextBytes: Self.maximumBaseContextBytes).compileSourceBase(
            cut: cut, query: query)
        guard var baseObject = try JSONSerialization.jsonObject(with: base.canonicalBytes) as? [String: Any] else {
            throw Failure.invalidCut
        }
        baseObject["allowedGapIDs"] = [] as [String]
        let baseBytes = try JSONSerialization.data(withJSONObject: baseObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let oracleCandidates = try cut.records.filter {
            $0.operationID == ReconstructionSourceOracleEvidence.operationID && $0.subject == .function(function)
                && cut.projectedClassificationsByEvidenceID[$0.evidenceID] == .acceptedCurrent
        }.compactMap { record -> (ReconstructionEvidenceRecord, ReconstructionSourceOracle)? in
            try validatePayload(record)
            guard record.payloadKind == .structuredJSON, record.classification == .acceptedCurrent else { throw Failure.invalidOracle }
            let oracle = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: record.payload)
            guard oracle.function == function, ReconstructionSourceProfile.admits(oracle.profileID),
                  oracle.inputs.count == 37, oracle.outputs.count == 37,
                  record.creatingJobID == oracle.jobID else { throw Failure.invalidOracle }
            return oracle.suiteSHA256 == oracleSuiteSHA256 ? (record, oracle) : nil
        }
        guard !oracleCandidates.isEmpty else { throw Failure.oracleUnavailable }
        guard oracleCandidates.count == 1, let (oracleRecord, oracle) = oracleCandidates.first else { throw Failure.ambiguousOracle }
        let oracleSummary = OracleSummary(evidenceID: oracleRecord.evidenceID, payloadSHA256: oracleRecord.payloadSHA256,
            suiteSHA256: oracle.suiteSHA256, function: oracle.function, profileID: oracle.profileID,
            inputs: oracle.inputs, outputs: oracle.outputs)
        let parent: ParentSummary?
        let parentRequestSHA256: String?
        if let parentRevisionSHA256 {
            let candidates = try cut.records.filter {
                guard let classification = cut.projectedClassificationsByEvidenceID[$0.evidenceID] else { return false }
                return $0.operationID == ReconstructionSourceRevisionEvidence.operationID && $0.subject == .function(function)
                    && [.acceptedCurrent, .acceptedHistorical].contains(classification)
            }.compactMap { record -> (ReconstructionEvidenceRecord, ReconstructionSourceRevision)? in
                try validatePayload(record)
                guard record.payloadKind == .structuredJSON,
                      record.payload.count <= ReconstructionSourceRevision.maximumPayloadBytes else { throw Failure.invalidParent }
                let decoded = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: record.payload)
                guard decoded.revisionSHA256 == parentRevisionSHA256 else { return nil }
                let offeredIDs: Set<UUID>
                if let binding = decoded.requestBinding {
                    guard !binding.canonicalRequestBytes.isEmpty,
                          binding.canonicalRequestBytes.count <= ReconstructionSourceRequestBinding.maximumRequestBytes,
                          ReconstructionSourceInferenceContract.sha256(binding.canonicalRequestBytes) == binding.requestSHA256 else {
                        throw Failure.invalidParent
                    }
                    let request = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self, from: binding.canonicalRequestBytes)
                    try request.validate()
                    guard try ReconstructionCanonicalJSON.encode(request) == binding.canonicalRequestBytes,
                          request.projectID == oracle.projectID, request.jobID == oracle.jobID,
                          request.function == function, request.oracleSuiteSHA256 == oracleSuiteSHA256,
                          request.objective.sha256 == decoded.objectiveSHA256,
                          request.evidenceFrontierSHA256 == decoded.evidenceFrontierSHA256,
                          request.parentRevisionSHA256 == nil,
                          request.taskID == binding.taskID, request.taskID == record.creatingTaskID,
                          request.roundID == binding.roundID, request.checkpointRevision == binding.checkpointRevision,
                          Set(request.context.evidenceIDs).isSubset(of: Set(cut.records.map(\.evidenceID))) else {
                        throw Failure.invalidParent
                    }
                    // A candidate may cite a strict subset of the offered evidence. The retained
                    // request, not the selected citations, defines the prior admission authority.
                    offeredIDs = Set(request.context.evidenceIDs)
                } else {
                    // Preserve bounded legacy payload validation; this path cannot invent a
                    // retained request or confer production receipt authority on an unbound row.
                    offeredIDs = Set(decoded.evidenceIDs)
                }
                let authority = ReconstructionSourceRevisionAuthority(projectID: oracle.projectID, jobID: oracle.jobID,
                    function: function, objectiveSHA256: decoded.objectiveSHA256,
                    evidenceFrontierSHA256: decoded.evidenceFrontierSHA256, oracleSuiteSHA256: oracleSuiteSHA256,
                    admissibleEvidenceIDs: offeredIDs, currentRevision: nil, requestBinding: decoded.requestBinding)
                let revision = try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: record.payload, authority: authority)
                guard revision.parentRevisionSHA256 == nil, revision.profileID == oracle.profileID,
                      record.creatingJobID == oracle.jobID else { throw Failure.invalidParent }
                return (record, revision)
            }
            guard !candidates.isEmpty else { throw Failure.parentUnavailable }
            guard candidates.count == 1, let (record, revision) = candidates.first else { throw Failure.ambiguousParent }
            guard revision.sourceUTF8.count <= Self.maximumParentBytes,
                  let sourceText = String(data: revision.sourceUTF8, encoding: .utf8) else { throw Failure.parentBounds }
            parentRequestSHA256 = revision.requestBinding?.requestSHA256
            parent = .init(evidenceID: record.evidenceID, payloadSHA256: record.payloadSHA256,
                revisionSHA256: revision.revisionSHA256, sourceSHA256: revision.sourceSHA256, sourceText: sourceText)
        } else { parent = nil; parentRequestSHA256 = nil }
        let diagnostics = try diagnosticSummaries(cut: cut, function: function, projectID: oracle.projectID,
            jobID: oracle.jobID, oracle: oracleSummary, parent: parent, parentRequestSHA256: parentRequestSHA256)
        var evidenceIDs = Set(base.evidenceIDs)
        evidenceIDs.insert(oracleSummary.evidenceID)
        if let parent { evidenceIDs.insert(parent.evidenceID) }
        evidenceIDs.formUnion(diagnostics.map(\.evidenceID))
        guard evidenceIDs.count <= 64 else { throw Failure.contextBounds }
        let ids = ReconstructionValidation.sortedUUIDs(Array(evidenceIDs))
        let envelope = Envelope(schemaVersion: 10, domain: Self.domain, corpusManifestSHA256: cut.corpusManifestSHA256,
            evidenceFrontierSHA256: cut.frontierSHA256, evidenceIDs: ids, baseContext: baseBytes,
            baseContextSHA256: ReconstructionSourceInferenceContract.sha256(baseBytes),
            oracle: oracleSummary, parent: parent, diagnostics: diagnostics)
        let bytes = try ReconstructionCanonicalJSON.encode(envelope)
        guard !bytes.isEmpty, bytes.count <= Self.maximumContextBytes else { throw Failure.contextBounds }
        return .init(canonicalBytes: bytes, canonicalSHA256: ReconstructionSourceInferenceContract.sha256(bytes), evidenceIDs: ids)
    }

    private func validatePayload(_ record: ReconstructionEvidenceRecord) throws {
        guard record.payloadByteCount == UInt64(record.payload.count),
              record.payloadSHA256 == ReconstructionSourceInferenceContract.sha256(record.payload),
              record.supersededByEvidenceID == nil else { throw Failure.invalidCut }
    }

    private func aggregateDiagnostic(cut: ReconstructionEvidenceCut, function: ReconstructionFunctionCoordinate,
        projectID: UUID, jobID: UUID, oracle: OracleSummary, parent: ParentSummary,
        parentRequestSHA256: String?) throws -> DiagnosticSummary? {
        var candidates: [(ReconstructionEvidenceRecord, ReconstructionSourceEvaluation, UInt64)] = []
        for record in cut.records where record.operationID == Self.evaluationOperationID && record.subject == .function(function) {
            guard let classification = cut.projectedClassificationsByEvidenceID[record.evidenceID],
                  [.acceptedCurrent, .failed, .truncated].contains(classification) else { continue }
            try validatePayload(record)
            guard record.payloadKind == .structuredJSON, record.toolReceiptID != nil,
                  record.modelReceiptID == nil, record.creatingJobID == jobID else { throw Failure.invalidDiagnostic }
            let evaluation = try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: record.payload)
            guard evaluation.revisionSHA256 == parent.revisionSHA256 else { continue }
            guard evaluation.profileID == oracle.profileID, evaluation.projectID == projectID, evaluation.jobID == jobID, evaluation.function == function,
                  evaluation.sourceSHA256 == parent.sourceSHA256, evaluation.oracleSuiteSHA256 == oracle.suiteSHA256,
                  evaluation.sourceEvidenceID == parent.evidenceID, evaluation.sourcePayloadSHA256 == parent.payloadSHA256,
                  evaluation.oracleEvidenceID == oracle.evidenceID, evaluation.oraclePayloadSHA256 == oracle.payloadSHA256,
                  evaluation.sourceRequestSHA256 == parentRequestSHA256,
                  record.producer.operationIdentity == Self.evaluationOperationID,
                  record.producer.canonicalSHA256 == evaluation.producerSHA256,
                  record.creatingTaskID == evaluation.taskID,
                  let checkpointRevision = cut.checkpointRevisionsByID[record.creatingCheckpointID],
                  let parentRecord = cut.records.first(where: { $0.evidenceID == parent.evidenceID }),
                  let parentCheckpointRevision = cut.checkpointRevisionsByID[parentRecord.creatingCheckpointID],
                  checkpointRevision == evaluation.checkpointRevision,
                  checkpointRevision > parentCheckpointRevision else { throw Failure.invalidDiagnostic }
            candidates.append((record, evaluation, checkpointRevision))
        }
        guard let newest = candidates.map({ $0.2 }).max() else { return nil }
        let latest = candidates.filter { $0.2 == newest }
        guard latest.count == 1, let (record, evaluation, checkpointRevision) = latest.first else { throw Failure.ambiguousDiagnostic }
        let diagnostic = aggregateText(evaluation, oracle: oracle)
        guard !diagnostic.isEmpty, diagnostic.utf8.count <= 2_048, !diagnostic.utf8.contains(0) else { throw Failure.invalidDiagnostic }
        return .init(evidenceID: record.evidenceID, payloadSHA256: record.payloadSHA256,
            operationID: Self.evaluationOperationID, checkpointRevision: checkpointRevision,
            revisionSHA256: parent.revisionSHA256, sourceSHA256: parent.sourceSHA256, diagnostic: diagnostic)
    }

    private func aggregateText(_ evaluation: ReconstructionSourceEvaluation, oracle: OracleSummary) -> String {
        let outcome = evaluation.capturedOutcome
        var headline = "Evaluation: " + outcome.status.rawValue
        if let failure = outcome.failureDetail { headline += "\nFailure: " + failure }
        headline = boundedDiagnosticText(headline, maximumBytes: 320)
        let phases = outcome.phases
        guard !phases.isEmpty else { return boundedDiagnosticText(headline, maximumBytes: 2_048) }
        let phaseBudget = (2_048 - headline.utf8.count - phases.count) / phases.count
        let rows = phases.map { phase -> String in
            let label: String
            switch phase.operation.rawValue {
            case "inspect": label = "Inspection"
            case "compile": label = "Compiler"
            case "behavior": label = "Behavior"
            default: label = phase.operation.rawValue
            }
            var text = label + ": " + phase.status.rawValue
            if let terminal = phase.terminal {
                text += " terminal=" + terminal.kind.rawValue
                if let status = terminal.status { text += "(\(status))" }
            }
            if let failure = phase.failure { text += "\nFailure: " + failure }
            let hasObservedBehavior = phase.operation == .behavior && outcome.observations.count == oracle.outputs.count
            if hasObservedBehavior {
                let observed = outcome.observations.map(\.output)
                let mismatches = observed.indices.filter { observed[$0] != oracle.outputs[$0] }
                text += "\nObserved \(observed.count) cases; \(mismatches.count) mismatches."
                for index in mismatches {
                    text += "\ninput=\(oracle.inputs[index]) expected=\(oracle.outputs[index]) observed=\(observed[index])"
                }
            }
            if !hasObservedBehavior && !phase.diagnostics.isEmpty {
                if let diagnostic = String(data: phase.diagnostics, encoding: .utf8) { text += "\n" + diagnostic }
                else { text += "\nNon-UTF-8 diagnostics SHA256=" + ReconstructionSourceInferenceContract.sha256(phase.diagnostics) }
            }
            return boundedDiagnosticText(text, maximumBytes: phaseBudget)
        }
        return ([headline] + rows).joined(separator: "\n")
    }

    private func boundedDiagnosticText(_ text: String, maximumBytes: Int) -> String {
        let safe = text.replacingOccurrences(of: "\0", with: "\\0")
        guard safe.utf8.count > maximumBytes else { return safe }
        let marker = " [diagnostic text omitted]"
        var prefix = "", bytes = 0
        for character in safe {
            let size = String(character).utf8.count
            guard bytes + size + marker.utf8.count <= maximumBytes else { break }
            prefix.append(character); bytes += size
        }
        return prefix + marker
    }

    private func diagnosticSummaries(cut: ReconstructionEvidenceCut, function: ReconstructionFunctionCoordinate,
        projectID: UUID, jobID: UUID, oracle: OracleSummary, parent: ParentSummary?,
        parentRequestSHA256: String?) throws -> [DiagnosticSummary] {
        guard let parent else { return [] }
        if let evaluation = try aggregateDiagnostic(cut: cut, function: function, projectID: projectID,
            jobID: jobID, oracle: oracle, parent: parent, parentRequestSHA256: parentRequestSHA256) {
            return [evaluation]
        }
        var output: [DiagnosticSummary] = []
        for operation in [Self.buildOperationID, Self.behaviorOperationID] {
            var candidates: [DiagnosticSummary] = []
            for record in cut.records where record.operationID == operation && record.subject == .function(function) {
                guard record.creatingJobID == jobID else { throw Failure.invalidDiagnostic }
                guard let classification = cut.projectedClassificationsByEvidenceID[record.evidenceID],
                      [.acceptedCurrent, .failed, .truncated].contains(classification) else { continue }
                try validatePayload(record)
                guard record.payloadKind == .structuredJSON, record.payload.count <= 8_192 else { throw Failure.invalidDiagnostic }
                let payload = try JSONDecoder().decode(ReconstructionSourceDiagnosticPayload.self, from: record.payload)
                guard try ReconstructionCanonicalJSON.encode(payload) == record.payload,
                      payload.version == 1, payload.profileID == oracle.profileID,
                      payload.function == function, ReconstructionSourceInferenceContract.isSHA256(payload.revisionSHA256),
                      ReconstructionSourceInferenceContract.isSHA256(payload.sourceSHA256),
                      !payload.diagnostic.isEmpty, payload.diagnostic.utf8.count <= 2_048,
                      !payload.diagnostic.utf8.contains(0) else { throw Failure.invalidDiagnostic }
                guard payload.revisionSHA256 == parent.revisionSHA256,
                      payload.sourceSHA256 == parent.sourceSHA256 else { continue }
                guard let checkpointRevision = cut.checkpointRevisionsByID[record.creatingCheckpointID] else { throw Failure.invalidDiagnostic }
                candidates.append(.init(evidenceID: record.evidenceID, payloadSHA256: record.payloadSHA256,
                    operationID: operation, checkpointRevision: checkpointRevision, revisionSHA256: payload.revisionSHA256,
                    sourceSHA256: payload.sourceSHA256, diagnostic: payload.diagnostic))
            }
            if let newest = candidates.map(\.checkpointRevision).max() {
                let latest = candidates.filter { $0.checkpointRevision == newest }
                guard latest.count == 1, let diagnostic = latest.first else { throw Failure.ambiguousDiagnostic }
                output.append(diagnostic)
            }
        }
        return output
    }
}

/// Closed, bounded diagnostic payload authored by the existing tool-evidence owner.
struct ReconstructionSourceDiagnosticPayload: Codable, Hashable, Sendable {
    let version: Int
    let profileID: String
    let function: ReconstructionFunctionCoordinate
    let revisionSHA256: String
    let sourceSHA256: String
    let diagnostic: String
}

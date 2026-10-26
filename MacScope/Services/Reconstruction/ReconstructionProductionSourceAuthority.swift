import Foundation

/// Captures source authority only from the existing committed owner cut. Neither model JSON nor
/// staged files can select an oracle, invent a parent, or replace a prior request's evidence cut.
enum ReconstructionProductionSourceAuthority {
    struct Captured: Sendable {
        let authority: ReconstructionSourceRevisionAuthority
        let priorRecords: [ReconstructionEvidenceRecord]
        let priorContexts: [ReconstructionSourceRevisionEvidence.Context]
    }

    static func capture(request: ReconstructionSourceRevisionRequest,
                        basis: ReconstructionProductionRoundBasis) throws -> Captured {
        try request.validate()
        guard request.projectID == basis.project.projectID, request.jobID == basis.job.jobID,
              request.profileID == (try ReconstructionSourceProfile.retainedSourceProfile(basis.job.sourceProfileID)).rawValue,
              request.checkpointRevision == basis.checkpoint.revision,
              request.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              request.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256,
              request.objective == (try ReconstructionRequestObjective(jobID: basis.job.jobID,
                text: basis.job.objective, sha256: basis.job.objectiveSHA256)),
              request.context.canonicalBytes.count <= ReconstructionSourceContextCompiler.maximumContextBytes,
              basis.freshnessAuthority.currentArtifacts.contains(request.function.artifact),
              basis.freshnessAuthority.currentImages.contains(where: {
                  $0.artifact == request.function.artifact && $0.image == request.function.image
                      && $0.analysisFingerprintSHA256 == request.function.analysisFingerprintSHA256
              }) else { throw Failure.invalidCut }
        let oracle = try committedOracle(function: request.function, basis: basis)
        guard oracle.profileID == request.profileID, oracle.suiteSHA256 == request.oracleSuiteSHA256,
              basis.evidenceCut.records.contains(where: {
                  $0.operationID == ReconstructionSourceOracleEvidence.operationID
                      && $0.creatingJobID == request.jobID && $0.subject == .function(request.function)
                      && request.context.evidenceIDs.contains($0.evidenceID)
              }) else { throw Failure.invalidOracle }
        let query = try ReconstructionRetrievalQuery(corpusManifestSHA256: basis.manifest.canonicalSHA256,
            subject: .function(request.function), operationIDs: ReconstructionOperationID.allCases,
            classifications: [.acceptedCurrent], cursor: nil, maximumRecords: 4,
            maximumEncodedBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes, focus: basis.job.focus)
        let delivered = try ReconstructionSourceContextCompiler().compile(cut: basis.evidenceCut,
            query: query, function: request.function, oracleSuiteSHA256: request.oracleSuiteSHA256,
            parentRevisionSHA256: request.parentRevisionSHA256)
        guard request.context == delivered else { throw Failure.invalidCut }
        let priorRecords = basis.evidenceCut.records.filter {
            $0.creatingJobID == basis.job.jobID && $0.operationID == ReconstructionSourceRevisionEvidence.operationID
        }.sorted { revision(of: $0, basis: basis) < revision(of: $1, basis: basis) }
        guard priorRecords.count <= 1 else { throw Failure.revisionLimit }
        var contexts: [ReconstructionSourceRevisionEvidence.Context] = []
        var parent: ReconstructionSourceRevision?
        for record in priorRecords {
            guard record.payload.count <= ReconstructionSourceRevision.maximumPayloadBytes,
                  let checkpoint = retainedCheckpoint(record.creatingCheckpointID, basis: basis),
                  let task = basis.tasks.first(where: { $0.identity.taskID == record.creatingTaskID }),
                  let receipt = basis.modelReceipts.first(where: { $0.receiptID == record.modelReceiptID }),
                  let parentCheckpointID = checkpoint.parentCheckpointID,
                  let admissionCheckpoint = retainedCheckpoint(parentCheckpointID, basis: basis) else {
                throw Failure.invalidParent
            }
            let decoded = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: record.payload)
            guard let binding = decoded.requestBinding else { throw Failure.invalidParent }
            let priorRequest = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
                from: binding.canonicalRequestBytes)
            try priorRequest.validate()
            guard priorRequest.jobID == request.jobID, priorRequest.projectID == request.projectID,
                  priorRequest.profileID == request.profileID,
                  priorRequest.function == request.function,
                  priorRequest.objective == request.objective,
                  priorRequest.oracleSuiteSHA256 == oracle.suiteSHA256,
                  priorRequest.checkpointRevision == admissionCheckpoint.revision,
                  priorRequest.evidenceFrontierSHA256 == admissionCheckpoint.evidenceFrontierSHA256,
                  priorRequest.corpusManifestSHA256 == admissionCheckpoint.corpusManifestSHA256,
                  binding.requestSHA256 == receipt.requestIdentitySHA256,
                  binding.taskID == task.identity.taskID,
                  try ReconstructionCanonicalJSON.encode(priorRequest) == binding.canonicalRequestBytes else {
                throw Failure.invalidParent
            }
            let authority = ReconstructionSourceRevisionAuthority(projectID: request.projectID,
                jobID: request.jobID, function: request.function, objectiveSHA256: request.objective.sha256,
                evidenceFrontierSHA256: priorRequest.evidenceFrontierSHA256,
                oracleSuiteSHA256: oracle.suiteSHA256,
                admissibleEvidenceIDs: Set(priorRequest.context.evidenceIDs), currentRevision: parent,
                requestBinding: binding, profileID: request.profileID)
            let context = ReconstructionSourceRevisionEvidence.Context(admissionAuthority: authority,
                task: task, checkpoint: checkpoint, modelReceipt: receipt,
                expectedRequestIdentitySHA256: binding.requestSHA256,
                committedEvidenceCut: basis.evidenceCut.records,
                committedPriorRevisionRecords: [], priorRevisionContexts: [])
            parent = try ReconstructionSourceRevisionEvidence.validate(record: record, context: context)
            contexts.append(context)
        }
        guard request.parentRevisionSHA256 == parent?.revisionSHA256 else { throw Failure.invalidParent }
        let initialAuthority = ReconstructionSourceRevisionAuthority(projectID: request.projectID,
            jobID: request.jobID, function: request.function, objectiveSHA256: request.objective.sha256,
            evidenceFrontierSHA256: request.evidenceFrontierSHA256, oracleSuiteSHA256: oracle.suiteSHA256,
            admissibleEvidenceIDs: Set(request.context.evidenceIDs), currentRevision: parent, profileID: request.profileID)
        let requestBytes = try ReconstructionCanonicalJSON.encode(request)
        let binding = try ReconstructionSourceRevisionAdmission.makeRequestBinding(
            canonicalRequestBytes: requestBytes,
            requestSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(requestBytes),
            authority: initialAuthority, expectedTaskID: request.taskID, expectedRoundID: request.roundID,
            expectedCheckpointRevision: request.checkpointRevision)
        let authority = ReconstructionSourceRevisionAuthority(projectID: request.projectID,
            jobID: request.jobID, function: request.function, objectiveSHA256: request.objective.sha256,
            evidenceFrontierSHA256: request.evidenceFrontierSHA256, oracleSuiteSHA256: oracle.suiteSHA256,
            admissibleEvidenceIDs: Set(request.context.evidenceIDs), currentRevision: parent,
            requestBinding: binding, profileID: request.profileID)
        return Captured(authority: authority, priorRecords: priorRecords, priorContexts: contexts)
    }

    struct CommittedRevision: Sendable {
        let record: ReconstructionEvidenceRecord
        let revision: ReconstructionSourceRevision
        let context: ReconstructionSourceRevisionEvidence.Context
    }

    static func committedRevisions(function: ReconstructionFunctionCoordinate,
        basis: ReconstructionProductionRoundBasis) throws -> [CommittedRevision] {
        let oracle = try committedOracle(function: function, basis: basis)
        let records = basis.evidenceCut.records.filter {
            $0.creatingJobID == basis.job.jobID && $0.operationID == ReconstructionSourceRevisionEvidence.operationID
        }.sorted { revision(of: $0, basis: basis) < revision(of: $1, basis: basis) }
        guard records.count <= 2 else { throw Failure.revisionLimit }
        var committed: [CommittedRevision] = []
        for record in records {
            guard record.payload.count <= ReconstructionSourceRevision.maximumPayloadBytes,
                  let checkpoint = retainedCheckpoint(record.creatingCheckpointID, basis: basis),
                  let admissionID = checkpoint.parentCheckpointID,
                  let admission = retainedCheckpoint(admissionID, basis: basis),
                  let task = basis.tasks.first(where: { $0.identity.taskID == record.creatingTaskID }),
                  let receipt = basis.modelReceipts.first(where: { $0.receiptID == record.modelReceiptID }) else {
                throw Failure.invalidParent
            }
            let decoded = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: record.payload)
            guard let binding = decoded.requestBinding else { throw Failure.invalidParent }
            let request = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
                from: binding.canonicalRequestBytes)
            try request.validate()
            guard request.projectID == basis.project.projectID, request.jobID == basis.job.jobID,
                  request.profileID == (try ReconstructionSourceProfile.retainedSourceProfile(basis.job.sourceProfileID)).rawValue, request.profileID == oracle.profileID,
                  request.function == function, request.objective.sha256 == basis.job.objectiveSHA256,
                  request.objective.text == basis.job.objective,
                  request.oracleSuiteSHA256 == oracle.suiteSHA256,
                  request.checkpointRevision == admission.revision,
                  request.evidenceFrontierSHA256 == admission.evidenceFrontierSHA256,
                  request.corpusManifestSHA256 == admission.corpusManifestSHA256,
                  binding.taskID == task.identity.taskID,
                  binding.requestSHA256 == receipt.requestIdentitySHA256,
                  try ReconstructionCanonicalJSON.encode(request) == binding.canonicalRequestBytes else {
                throw Failure.invalidParent
            }
            let authority = ReconstructionSourceRevisionAuthority(projectID: request.projectID,
                jobID: request.jobID, function: function, objectiveSHA256: request.objective.sha256,
                evidenceFrontierSHA256: request.evidenceFrontierSHA256,
                oracleSuiteSHA256: oracle.suiteSHA256, admissibleEvidenceIDs: Set(request.context.evidenceIDs),
                currentRevision: committed.last?.revision, requestBinding: binding, profileID: request.profileID)
            let context = ReconstructionSourceRevisionEvidence.Context(admissionAuthority: authority,
                task: task, checkpoint: checkpoint, modelReceipt: receipt,
                expectedRequestIdentitySHA256: binding.requestSHA256,
                committedEvidenceCut: basis.evidenceCut.records,
                committedPriorRevisionRecords: committed.map(\.record),
                priorRevisionContexts: committed.map(\.context))
            let revision = try ReconstructionSourceRevisionEvidence.validate(record: record, context: context)
            committed.append(.init(record: record, revision: revision, context: context))
        }
        return committed
    }

    static func oracleContext(function: ReconstructionFunctionCoordinate,
        basis: ReconstructionProductionRoundBasis) throws
        -> (record: ReconstructionEvidenceRecord, context: ReconstructionSourceOracleEvidence.Context) {
        let oracle = try committedOracle(function: function, basis: basis)
        guard let record = basis.evidenceCut.records.first(where: {
            $0.creatingJobID == basis.job.jobID && $0.operationID == ReconstructionSourceOracleEvidence.operationID
                && $0.subject == .function(function)
        }), let receipt = basis.toolReceipts.first(where: { $0.receiptID == record.toolReceiptID }),
            let task = basis.tasks.first(where: { $0.identity.taskID == record.creatingTaskID }),
            let checkpoint = retainedCheckpoint(record.creatingCheckpointID, basis: basis) else {
            throw Failure.invalidOracle
        }
        return (record, .init(authority: .init(projectID: oracle.projectID, jobID: oracle.jobID,
            function: function, execution: oracle.execution, evidenceIDs: oracle.evidenceIDs, profileID: oracle.profileID),
            task: task, checkpoint: checkpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: receipt.requestIdentitySHA256,
            expectedProducer: receipt.producer, committedEvidenceCut: basis.evidenceCut.records))
    }

    static func committedOracle(function: ReconstructionFunctionCoordinate,
                                basis: ReconstructionProductionRoundBasis) throws -> ReconstructionSourceOracle {
        let records = basis.evidenceCut.records.filter {
            $0.operationID == ReconstructionSourceOracleEvidence.operationID
                && $0.creatingJobID == basis.job.jobID && $0.subject == .function(function)
                && basis.evidenceCut.projectedClassificationsByEvidenceID[$0.evidenceID] == .acceptedCurrent
        }
        guard records.count == 1, let record = records.first,
              let receipt = basis.toolReceipts.first(where: { $0.receiptID == record.toolReceiptID }),
              let task = basis.tasks.first(where: { $0.identity.taskID == record.creatingTaskID }),
              let checkpoint = retainedCheckpoint(record.creatingCheckpointID, basis: basis) else {
            throw Failure.invalidOracle
        }
        let oracle = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: record.payload)
        guard oracle.projectID == basis.project.projectID, oracle.jobID == basis.job.jobID,
              oracle.profileID == (try ReconstructionSourceProfile.retainedSourceProfile(basis.job.sourceProfileID)).rawValue, ReconstructionSourceProfile.admits(oracle.profileID),
              oracle.function == function,
              oracle.execution.originalExecutableSHA256 == function.artifact.contentIdentity.digest else {
            throw Failure.invalidOracle
        }
        return try ReconstructionSourceOracleEvidence.validate(record: record, context: .init(
            authority: .init(projectID: oracle.projectID, jobID: oracle.jobID, function: oracle.function,
                execution: oracle.execution, evidenceIDs: oracle.evidenceIDs, profileID: oracle.profileID), task: task,
            checkpoint: checkpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: receipt.requestIdentitySHA256,
            expectedProducer: receipt.producer, committedEvidenceCut: basis.evidenceCut.records))
    }

    private static func retainedCheckpoint(_ id: UUID, basis: ReconstructionProductionRoundBasis)
        -> ReconstructionCheckpoint? {
        if basis.checkpoint.checkpointID == id { return basis.checkpoint }
        return basis.checkpointHistory.first { $0.checkpointID == id }
    }

    private static func revision(of record: ReconstructionEvidenceRecord,
                                 basis: ReconstructionProductionRoundBasis) -> UInt64 {
        retainedCheckpoint(record.creatingCheckpointID, basis: basis)?.revision ?? UInt64.max
    }

    enum Failure: Error { case invalidCut, invalidOracle, invalidParent, revisionLimit }
}

import Foundation
@testable import MacScope
import MacScopeAnalysisCore

/// DOT-08: newly authored fake observations only. No saved prompts, fixtures, models or inference.
/// These values exercise production DTOs and production hashes/compilers. The outputs in the
/// source oracle are synthetic fixture values, not a claim of observed native execution.
enum ReplayEconomyFixtures {
    enum Expected: String, Codable, Sendable {
        case sameIdentity, differentIdentity, modelChanged
        case providerBudgetRefusal, contextBudgetRefusal, historicalTransientRecovery
    }

    struct Model: Sendable {
        let lease: Phase2ReadyInferenceLease
        let inventory: Phase2LocalModelInventory

        func configuration(for request: ReconstructionAIWorkerRequest) throws -> Phase2AIWorkerConfigurationWire {
            let value = lease.configuration
            return .init(schemaVersion: 1, profileID: value.profileID, generation: value.generation,
                endpointOrigin: value.endpointOrigin, model: value.model,
                protocolManifestDigest: (try request.protocolBundle).manifestDigest,
                maximumTokens: value.maximumTokens,
                requestTimeoutMilliseconds: value.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: value.resourceTimeoutMilliseconds,
                inferencePolicy: value.inferencePolicy)
        }
    }

    struct ContextInput: Sendable {
        let cut: ReconstructionEvidenceCut
        let query: ReconstructionRetrievalQuery

        func compile(maximumContextBytes: Int = 32_768) throws -> ReconstructionRetrievedContext {
            try ReconstructionContextCompiler(maximumContextBytes: maximumContextBytes).compile(
                cut: cut, query: query, allowedGapSubjects: [], allowedGapCategories: [])
        }
    }

    struct Scenario: Sendable {
        let name: String
        let original: ReconstructionAIWorkerRequest
        let current: ReconstructionAIWorkerRequest
        let originalTools: [ReconstructionToolRequest]
        let currentTools: [ReconstructionToolRequest]
        let originalModel: Model
        let currentModel: Model
        let expected: Expected
        let contextInput: ContextInput
        let maximumProviderBodyBytes: Int?
        let maximumContextBytes: Int?

        var objectiveSHA256: String { current.replayObjective!.sha256 }
    }

    static let jobID = id(1)
    static let taskID = id(2)
    static let workspaceID = id(3)
    static let projectID = id(4)
    static let logicalRoundIndex = 3
    static let baseObjective = "Describe the fake amber counter and cite only the supplied observation."
    static let unicodeObjective = "Explain compteur café, e\u{301}, 雪 and 🧪 without normalizing their spelling."

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "d0080000-1000-4000-8000-%012x", value))!
    }

    static func sha(_ text: String) -> String {
        ReconstructionSourceInferenceContract.sha256(Data(text.utf8))
    }

    static func objective(_ text: String = baseObjective) throws -> ReconstructionRequestObjective {
        try .init(jobID: jobID, text: text, sha256: sha(text))
    }

    static func model(restarted: Bool = false, key: String = "dot08-synthetic-amber") throws -> Model {
        let profileID = id(restarted ? 602 : 601)
        let generation: UInt64 = restarted ? 7 : 2
        let descriptor = Phase2LocalModelDescriptor(type: .language, publisher: "DOT08 synthetic",
            key: key, displayName: "Amber fake offline model", architecture: nil,
            quantization: nil, sizeBytesOnDisk: 16, parameterCountDescription: nil,
            maximumContextLength: 32_768, format: nil, capabilities: nil, variants: [],
            providerSelectedVariant: nil,
            loadedInstances: [.init(id: restarted ? "synthetic-restarted" : "synthetic-original",
                configuration: .init(effectiveContextLength: 32_768))])
        let inventory = try Phase2LocalModelInventory(profileID: profileID, generation: generation,
            models: [descriptor])
        let configuration = try Phase2AIProviderConfiguration(profileID: profileID, generation: generation,
            endpointOrigin: "http://127.0.0.1:8765", model: key, maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000,
            inferencePolicy: .init(effectiveContextTokens: 32_768))
        return .init(lease: .init(providerRevision: generation, configuration: configuration,
            observedModelInventorySHA256: Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory)),
            inventory: inventory)
    }

    static func function() throws -> ReconstructionFunctionCoordinate {
        // This ASCII string, not private object code, is the entire fake artifact preimage.
        let artifactBytes = Data("DOT08 synthetic amber artifact".utf8)
        return try .init(artifact: .init(occurrenceID: .init(rawValue: id(20)),
            contentIdentity: .init(algorithm: .sha256,
                digest: ReconstructionSourceInferenceContract.sha256(artifactBytes),
                byteCount: UInt64(artifactBytes.count))),
            image: .init(binaryID: id(21), imageSlot: .primary, selectedSliceIndex: nil,
                architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("DOT08 synthetic analysis A"),
            startAddress: 0x2400, endAddressExclusive: 0x2418,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: "amber_counter")
    }

    static func contextInput(unicode: Bool = false, changed: Bool = false,
                             historical: Bool = false) throws -> ContextInput {
        let payload = Data((unicode
            ? "Fake note: café / e\u{301} / 雪 / 🧪; path=synthetic/δ; timestamp=2040-01-02."
            : changed ? "Fake amber observation: input 6 maps to 9; timestamp=2040-01-02."
                : "Fake amber observation: input 6 maps to 7; timestamp=2040-01-02.").utf8)
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.corpusArtifactDescribe
        let classification: ReconstructionEvidenceClassification = historical ? .acceptedHistorical : .acceptedCurrent
        let record = try ReconstructionEvidenceRecord(evidenceID: id(30), subject: .artifact(function().artifact),
            operationID: operation.rawValue, payloadKind: .text, payload: payload,
            payloadByteCount: UInt64(payload.count),
            payloadSHA256: ReconstructionSourceInferenceContract.sha256(payload), facetDependencies: [],
            producer: .init(macScopeBuildIdentity: "dot08-fake-build", macScopeSourceIdentity: "dot08-fake-source",
                operationIdentity: operation.rawValue, registryIdentity: "dot08-fake-registry",
                protocolIdentity: "dot08-fake-observation-v1", canonicalSHA256: sha("DOT08 fake producer preimage")),
            citations: [], creatingJobID: jobID, creatingTaskID: id(31), creatingCheckpointID: id(32),
            modelReceiptID: nil, toolReceiptID: id(33), classification: classification,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let corpus = sha("DOT08 synthetic corpus manifest")
        let classes = [record.evidenceID: classification]
        let revisions: [UUID: UInt64] = [record.creatingCheckpointID: 2]
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(corpusManifestSHA256: corpus,
            records: [record], projectedClassificationsByEvidenceID: classes,
            relations: [], gaps: [], checkpointRevisionsByID: revisions)
        let cut = try ReconstructionEvidenceCut(corpusManifestSHA256: corpus, records: [record],
            relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: classes, checkpointRevisionsByID: revisions)
        let query = try ReconstructionRetrievalQuery(corpusManifestSHA256: corpus, subject: nil,
            operationIDs: [operation], classifications: [.acceptedCurrent, .acceptedHistorical],
            cursor: nil, maximumRecords: 2, maximumEncodedBytes: 12_288)
        return .init(cut: cut, query: query)
    }

    static func round(context: ReconstructionRetrievedContext, revision: UInt64 = 4,
                      objectiveText: String = baseObjective, operations: [MacScopeAnalysisCore.ReconstructionOperationID] = [.corpusSummary],
                      transient: ReconstructionTransientAnalysis? = nil) throws -> ReconstructionAIWorkerRequest {
        // Authority is obtained from the actual context envelope, not a separately invented frontier.
        let values = try JSONSerialization.jsonObject(with: context.canonicalBytes) as! [String: Any]
        return .roundR2(.init(protocolVersion: 9, objective: try objective(objectiveText),
            request: .init(protocolVersion: 8, jobID: jobID, checkpointRevision: revision,
                roundID: id(100 + Int(revision)), corpusManifestSHA256: values["corpusManifestSHA256"] as! String,
                evidenceFrontierSHA256: values["evidenceFrontierSHA256"] as! String,
                registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                context: context, handles: operations.enumerated().map {
                    .init(handleID: id(200 + Int(revision) * 10 + $0.offset), operationID: $0.element)
                }, transientAnalysis: transient)))
    }

    static func final(context: ReconstructionRetrievedContext, revision: UInt64) throws -> ReconstructionAIWorkerRequest {
        let input = try round(context: context, revision: revision)
        guard case .roundR2(let value) = input else { preconditionFailure("fixture round") }
        return .finalSynthesisR2(.init(protocolVersion: 9, objective: value.objective,
            request: .init(jobID: jobID, checkpointRevision: revision,
                corpusManifestSHA256: value.request.corpusManifestSHA256,
                evidenceFrontierSHA256: value.request.evidenceFrontierSHA256,
                acceptedEvidenceIDs: context.evidenceIDs, context: context)))
    }

    static func tools(_ operations: [MacScopeAnalysisCore.ReconstructionOperationID] = [.corpusSummary]) -> [ReconstructionToolRequest] {
        operations.map { .init(operationID: $0, taskID: taskID, subject: nil,
            retrievalQuery: nil, offset: 0, maximumRecords: 2, maximumEncodedBytes: 4_096) }
    }

    static func transient(for request: ReconstructionAIWorkerRequest, changed: Bool = false) throws -> ReconstructionTransientAnalysis {
        guard case .roundR2(let value) = request else { throw ReconstructionReplayError.unsupportedRequest }
        let subject = try function()
        let fact = ReconstructionTransientNativeFact(factID: id(70), subject: subject, sourceTaskID: id(71),
            providerIdentitySHA256: sha("DOT08 fake native provider"), nativeRequestID: id(72),
            nativeRequestSHA256: sha("DOT08 fake native request"),
            analysisInputFingerprintSHA256: subject.analysisFingerprintSHA256,
            nativeImageID: "dot08-amber-image", nativeImageUUID: id(73), publicationGeneration: 2,
            functionName: "amber_counter", pseudocodeLanguage: "C",
            pseudocode: changed ? "return value + 2;" : "return value + 1;", pseudocodeWasTruncated: false,
            callTargets: [], variableNames: ["value"], blockCount: 1, callCount: 0,
            variableCount: 1, warningCodes: ["syntheticObservation"])
        let omission = ReconstructionTransientNativeOmission(subjectSHA256: sha("DOT08 omitted sibling"),
            publicationGeneration: nil, reason: .unavailable)
        let used = try ReconstructionCanonicalJSON.encode([fact]).count
        return .init(schemaVersion: 1, domain: ReconstructionTransientAnalysis.domain,
            jobID: jobID, checkpointRevision: value.request.checkpointRevision,
            corpusManifestSHA256: value.request.corpusManifestSHA256,
            evidenceFrontierSHA256: value.request.evidenceFrontierSHA256,
            budgetBytes: 4_096, usedBytes: used, facts: [fact], omissions: [omission])
    }

    static func replacingTransient(_ request: ReconstructionAIWorkerRequest,
                                   _ transient: ReconstructionTransientAnalysis?) throws -> ReconstructionAIWorkerRequest {
        guard case .roundR2(let value) = request else { throw ReconstructionReplayError.unsupportedRequest }
        let source = value.request
        return .roundR2(.init(protocolVersion: value.protocolVersion, objective: value.objective,
            request: .init(protocolVersion: source.protocolVersion, jobID: source.jobID,
                checkpointRevision: source.checkpointRevision, roundID: source.roundID,
                corpusManifestSHA256: source.corpusManifestSHA256,
                evidenceFrontierSHA256: source.evidenceFrontierSHA256,
                registryManifestSHA256: source.registryManifestSHA256, context: source.context,
                handles: source.handles, transientAnalysis: transient)))
    }

    static func source(base: ReconstructionRetrievedContext, revision: UInt64) throws -> ReconstructionAIWorkerRequest {
        let shell = try round(context: base)
        guard case .roundR2(let round) = shell else { throw ReconstructionReplayError.unsupportedRequest }
        let sourceText = "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x + 1u; }\n"
        let parentRevision = sha("DOT08 fake parent revision")
        let inputs = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().inputs
        let ids = ReconstructionValidation.sortedUUIDs(base.evidenceIDs + [id(80), id(81), id(82)])
        let envelope = ReconstructionSourceContextCompiler.Envelope(schemaVersion: 10,
            domain: ReconstructionSourceContextCompiler.domain,
            corpusManifestSHA256: round.request.corpusManifestSHA256,
            evidenceFrontierSHA256: round.request.evidenceFrontierSHA256, evidenceIDs: ids,
            baseContext: base.canonicalBytes, baseContextSHA256: base.canonicalSHA256,
            oracle: .init(evidenceID: id(80), payloadSHA256: sha("DOT08 synthetic oracle payload"),
                suiteSHA256: sha("DOT08 synthetic oracle suite"), function: try function(),
                profileID: ReconstructionSourceInferenceContract.profileID, inputs: inputs,
                outputs: inputs.map { $0 == UInt32.max ? $0 : $0 + 1 }),
            parent: .init(evidenceID: id(81), payloadSHA256: sha("DOT08 synthetic parent payload"),
                revisionSHA256: parentRevision, sourceSHA256: sha(sourceText), sourceText: sourceText),
            diagnostics: [.init(evidenceID: id(82), payloadSHA256: sha("DOT08 synthetic diagnostic payload"),
                operationID: ReconstructionSourceContextCompiler.evaluationOperationID, checkpointRevision: 3,
                revisionSHA256: parentRevision, sourceSHA256: sha(sourceText),
                diagnostic: "Synthetic behavior mismatch at 4294967295: expected saturation; observed wraparound. No execution occurred.")])
        let bytes = try ReconstructionCanonicalJSON.encode(envelope)
        return .sourceRevision(.init(protocolVersion: 10,
            objective: try objective("Propose a bounded unsigned C correction for the fake amber counter."),
            projectID: projectID, jobID: jobID, taskID: taskID, checkpointRevision: revision,
            roundID: id(300 + Int(revision)), function: try function(),
            corpusManifestSHA256: round.request.corpusManifestSHA256,
            evidenceFrontierSHA256: round.request.evidenceFrontierSHA256,
            oracleSuiteSHA256: envelope.oracle.suiteSHA256, profileID: ReconstructionSourceInferenceContract.profileID,
            parentRevisionSHA256: parentRevision,
            context: .init(canonicalBytes: bytes, canonicalSHA256: ReconstructionSourceInferenceContract.sha256(bytes), evidenceIDs: ids)))
    }

    /// Exactly 12 authored scenario pairs. Limits are intentionally small, not oversized payloads.
    static func scenarios() throws -> [Scenario] {
        let base = try contextInput(), baseContext = try base.compile()
        let different = try contextInput(changed: true), differentContext = try different.compile()
        let unicode = try contextInput(unicode: true), unicodeContext = try unicode.compile()
        let historical = try contextInput(historical: true), historicalContext = try historical.compile()
        let first = try model(), restart = try model(restarted: true)
        let a = try round(context: baseContext), b = try round(context: baseContext, revision: 11)
        func scenario(_ name: String, _ original: ReconstructionAIWorkerRequest,
                      _ current: ReconstructionAIWorkerRequest, _ expected: Expected,
                      originalTools: [ReconstructionToolRequest] = tools(),
                      currentTools: [ReconstructionToolRequest] = tools(), currentModel: Model? = nil,
                      contextInput: ContextInput? = nil, providerLimit: Int? = nil,
                      contextLimit: Int? = nil) -> Scenario {
            .init(name: name, original: original, current: current, originalTools: originalTools,
                currentTools: currentTools, originalModel: first, currentModel: currentModel ?? restart,
                expected: expected, contextInput: contextInput ?? base,
                maximumProviderBodyBytes: providerLimit, maximumContextBytes: contextLimit)
        }
        let historicalBare = try round(context: historicalContext)
        let historicalOriginal = try replacingTransient(historicalBare, transient(for: historicalBare))
        let historicalCurrentBare = try round(context: historicalContext, revision: 11)
        let transientChanged = try replacingTransient(b, transient(for: b, changed: true))
        let transientOriginal = try replacingTransient(a, transient(for: a))
        return [
            scenario("round_exact_retry", a, b, .sameIdentity),
            scenario("final_exact_retry", try final(context: baseContext, revision: 4),
                try final(context: baseContext, revision: 11), .sameIdentity, originalTools: [], currentTools: []),
            scenario("source_repair_exact_retry", try source(base: baseContext, revision: 4),
                try source(base: baseContext, revision: 11), .sameIdentity, originalTools: [], currentTools: []),
            scenario("changed_objective", a, try round(context: baseContext, revision: 11,
                objectiveText: "List only the fake amber observation; do not infer arithmetic."), .differentIdentity),
            scenario("changed_evidence", a, try round(context: differentContext, revision: 11),
                .differentIdentity, contextInput: different),
            scenario("changed_tool_set", a, try round(context: baseContext, revision: 11,
                operations: [.corpusSummary, .checkpointStatus]), .differentIdentity,
                currentTools: tools([.corpusSummary, .checkpointStatus])),
            scenario("changed_model", a, b, .modelChanged,
                currentModel: try model(restarted: true, key: "dot08-synthetic-violet")),
            scenario("unicode_exact_retry", try round(context: unicodeContext, objectiveText: unicodeObjective),
                try round(context: unicodeContext, revision: 11, objectiveText: unicodeObjective),
                .sameIdentity, contextInput: unicode),
            scenario("provider_budget_refusal", a, b, .providerBudgetRefusal, providerLimit: 128),
            scenario("context_budget_refusal", a, b, .contextBudgetRefusal, contextLimit: 128),
            scenario("historical_transient_recovery", historicalOriginal, historicalCurrentBare,
                .historicalTransientRecovery, contextInput: historical),
            scenario("changed_transient_fact", transientOriginal, transientChanged, .differentIdentity),
        ]
    }

    static func identity(request: ReconstructionAIWorkerRequest, model: Model,
                         toolRequests: [ReconstructionToolRequest]) throws -> ReconstructionPromptReplayIdentity {
        try .make(request: request, lease: model.lease, jobID: jobID, taskID: taskID,
            logicalRoundIndex: logicalRoundIndex, objectiveSHA256: request.replayObjective!.sha256,
            toolRequests: toolRequests, selectedModelIdentitySHA256:
                ReconstructionReplayModelIdentity.stableSelectedModelIdentity(lease: model.lease, inventory: model.inventory))
    }

    static func candidate(for request: ReconstructionAIWorkerRequest) throws -> ReconstructionReplayCandidate {
        switch request {
        case .roundR2(let value):
            return .round(.init(jobID: jobID, checkpointRevision: value.request.checkpointRevision,
                roundID: value.request.roundID, selectedHandleIDs: [],
                disposition: .sufficientEvidence, unresolvedGaps: []))
        case .finalSynthesisR2(let value):
            return .final(.init(kind: .synthesis, text: "The fake amber observation reports one bounded input/output pair.",
                evidenceIDs: value.request.acceptedEvidenceIDs))
        case .sourceRevision(let value):
            return .source(.init(profileID: value.profileID, parentRevisionSHA256: value.parentRevisionSHA256,
                sourceText: "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x == UINT32_MAX ? x : x + 1u; }\n",
                evidenceIDs: value.context.evidenceIDs))
        default: throw ReconstructionReplayError.unsupportedRequest
        }
    }

    /// Authored historical reply for a fixture, never a current worker/process attestation.
    /// Use only with a clearly labeled in-memory journal, or the real database in owner-selected tests.
    static func record(for scenario: Scenario) throws -> ReconstructionReplayRecord {
        let request = scenario.original, model = scenario.originalModel
        let requestID = id(900)
        let terminal = ReconstructionTerminalReceipt(requestID: requestID, jobID: jobID,
            checkpointRevision: request.replayCheckpointRevision, roundID: request.replayRoundID, status: .completed)
        let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: requestID,
            request: request, terminalReceipt: terminal)
        let selectedModel = try ReconstructionReplayModelIdentity.stableSelectedModelIdentity(
            lease: model.lease, inventory: model.inventory)
        return .init(schemaVersion: 1,
            identity: try identity(request: request, model: model, toolRequests: scenario.originalTools),
            dispatches: [.init(requestID: requestID, processSessionID: id(901),
                dispatchedAt: Date(timeIntervalSince1970: 2_100_000_000), previousRequestOutcomeUnknown: nil)],
            freshReply: .init(requestIdentitySHA256: authority.requestIdentitySHA256,
                originalRequestBytes: try request.replayEncodedRequest(), terminalReceipt: terminal,
                candidate: try candidate(for: request), usage: .init(promptTokens: 0, completionTokens: 0, totalTokens: 0),
                modelIdentity: try .init(lease: model.lease, request: request, selectedModelIdentitySHA256: selectedModel),
                attestation: .notRequired, offeredHandles: request.replayHandles,
                publishedAt: Date(timeIntervalSince1970: 2_100_000_001)),
            latestObservation: nil, replayCount: 0)
    }
}

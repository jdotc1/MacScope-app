import CryptoKit
import Foundation

enum ReconstructionReplayError: Error, Equatable, Sendable {
    case invalidScope, invalidRecord, conflictingRecord, journalFull, unsupportedRequest
    case requestInFlight, staleAdmission, missingOriginalAttestation
    /// A completed reply for this exact request was recorded under a different selected model.
    /// Terminal: the job cannot replay under a different model, and retrying cannot fix it.
    case modelChanged
}

/// Carried only by the product job planner. Ordinary AI requests, standalone inference calls,
/// and unrelated test hosts never acquire a journal merely because one exists in the process.
struct ReconstructionReplayScope: Sendable {
    @TaskLocal static var current: Self?

    let owner: ReconstructionDatabaseOwner
    let workspaceID: UUID
    let jobID: UUID
    let taskID: UUID
    let logicalRoundIndex: Int
    let objectiveSHA256: String
    let toolRequests: [ReconstructionToolRequest]
}

/// Persistent selected-model identity, not a resurrected Phase2ReadyInferenceLease. Connection
/// generation and controller revision are launch-local; they remain in the historical
/// attestation but cannot turn a replay into a fresh provider call.
struct ReconstructionReplayModelIdentity: Codable, Hashable, Sendable {
    let profileID: UUID
    let endpointOrigin: String
    let model: String
    let observedModelInventorySHA256: String
    let selectedModelIdentitySHA256: String
    let maximumTokens: Int
    let inferencePolicy: Phase2LocalInferencePolicy?
    let protocolManifestDigest: String

    init(lease: Phase2ReadyInferenceLease, request: ReconstructionAIWorkerRequest,
         selectedModelIdentitySHA256: String) throws {
        profileID = lease.configuration.profileID
        endpointOrigin = lease.configuration.endpointOrigin
        model = lease.configuration.model
        observedModelInventorySHA256 = lease.observedModelInventorySHA256
        self.selectedModelIdentitySHA256 = selectedModelIdentitySHA256
        maximumTokens = lease.configuration.maximumTokens
        inferencePolicy = lease.configuration.inferencePolicy
        protocolManifestDigest = (try request.protocolBundle).manifestDigest
    }

    var sha256: String {
        get throws {
            struct StableIdentity: Encodable {
                let endpointOrigin: String
                let model: String
                let selectedModelIdentitySHA256: String
                let maximumTokens: Int
                let inferencePolicy: Phase2LocalInferencePolicy?
                let protocolManifestDigest: String
            }
            // profileID is minted on every launch; the observed catalog digest includes that
            // profileID. Both remain historical evidence, never persistent model coordinates.
            return try ReconstructionCanonicalJSON.sha256(of: StableIdentity(endpointOrigin: endpointOrigin,
                model: model, selectedModelIdentitySHA256: selectedModelIdentitySHA256,
                maximumTokens: maximumTokens, inferencePolicy: inferencePolicy,
                protocolManifestDigest: protocolManifestDigest))
        }
    }

    static func stableSelectedModelIdentity(lease: Phase2ReadyInferenceLease,
                                           inventory: Phase2LocalModelInventory?) throws -> String {
        guard let inventory, inventory.profileID == lease.configuration.profileID,
              inventory.generation == lease.configuration.generation,
              Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory) == lease.observedModelInventorySHA256,
              let selected = inventory.models.first(where: { $0.key == lease.configuration.model }) else {
            throw ReconstructionReplayError.staleAdmission
        }
        // The existing inventory identity already excludes loaded-instance IDs and retains all
        // semantic model/configuration metadata. Normalize only its launch-local profile wrapper.
        let stable = try Phase2LocalModelInventory(
            profileID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            generation: 1, models: [selected])
        return Phase2LocalModelInventoryIdentity.canonicalSHA256(stable)
    }
}

struct ReconstructionPromptReplayIdentity: Codable, Hashable, Sendable {
    static let domain = "reconstruction.prompt-replay.v1"
    let domain: String
    let objectiveID: UUID
    let objectiveSHA256: String
    let taskID: UUID
    let logicalRoundIndex: Int
    let requestKind: String
    let modelIdentitySHA256: String
    let canonicalPromptSHA256: String

    var key: String { get throws { try ReconstructionCanonicalJSON.sha256(of: self) } }

    /// Closed-schema volatile removal: requestID, sent/started/deadline timestamps, connection
    /// nonces and absolute run/staging roots belong to the transport and never enter these typed
    /// semantic requests. The ONLY fields normalized inside a request are its top-level retry
    /// checkpoint revision/round ID, offered-handle IDs (replaced by their operation identity),
    /// and transientAnalysis.checkpointRevision. Evidence, diagnostic timestamps, target paths,
    /// source text, native fact identity, objective and all context bytes remain exact. In
    /// particular this never recursively strips fields named "timestamp", "nonce" or "path".
    static func make(request: ReconstructionAIWorkerRequest, lease: Phase2ReadyInferenceLease,
                     jobID: UUID, taskID: UUID, logicalRoundIndex: Int,
                     objectiveSHA256: String, toolRequests: [ReconstructionToolRequest],
                     selectedModelIdentitySHA256: String) throws -> Self {
        guard logicalRoundIndex >= 0, request.replayJobID == jobID,
              request.replayObjective?.sha256 == objectiveSHA256,
              request.replayObjective?.jobID == jobID else { throw ReconstructionReplayError.invalidScope }
        let normalized = try canonicalRequest(request)
        let model = try ReconstructionReplayModelIdentity(lease: lease, request: request,
            selectedModelIdentitySHA256: selectedModelIdentitySHA256)
        let configuration = lease.configuration
        let canonicalPrompt: Data
        if configuration.inferencePolicy != nil {
            // Use the actual provider encoder: changes to system instructions, tool/output
            // schemas or sampling controls invalidate reuse as well as request changes.
            canonicalPrompt = try Phase2ReconstructionOpenAIChatRequestEncoder().encode(
                request: normalized, configuration: .init(schemaVersion: 1,
                    profileID: configuration.profileID, generation: configuration.generation,
                    endpointOrigin: configuration.endpointOrigin, model: configuration.model,
                    protocolManifestDigest: (try request.protocolBundle).manifestDigest,
                    maximumTokens: configuration.maximumTokens,
                    requestTimeoutMilliseconds: configuration.requestTimeoutMilliseconds,
                    resourceTimeoutMilliseconds: configuration.resourceTimeoutMilliseconds,
                    inferencePolicy: configuration.inferencePolicy)).requestBody
        } else {
            // Legacy deterministic fixtures have no production provider policy. They still bind
            // the complete semantic request and negotiated protocol; nil never authorizes MTPLX.
            canonicalPrompt = try normalized.replayEncodedRequest()
        }
        struct Prompt: Encodable {
            let providerBody: Data
            let toolRequests: [ReconstructionToolRequest]
            let protocolManifestDigest: String
        }
        let offered = request.replayHandles
        guard Set(offered.map(\.operationID)).count == offered.count,
              offered.isEmpty || Set(toolRequests.map(\.operationID)) == Set(offered.map(\.operationID)),
              Set(toolRequests.map(\.operationID)).count == toolRequests.count else {
            throw ReconstructionReplayError.invalidScope
        }
        return .init(domain: Self.domain, objectiveID: jobID,
            objectiveSHA256: objectiveSHA256, taskID: taskID, logicalRoundIndex: logicalRoundIndex,
            requestKind: request.replayKind, modelIdentitySHA256: try model.sha256,
            canonicalPromptSHA256: try ReconstructionCanonicalJSON.sha256(of: Prompt(
                providerBody: canonicalPrompt,
                toolRequests: toolRequests.sorted { $0.operationID.rawValue < $1.operationID.rawValue },
                protocolManifestDigest: (try request.protocolBundle).manifestDigest)))
    }

    static func canonicalRequest(_ request: ReconstructionAIWorkerRequest) throws -> ReconstructionAIWorkerRequest {
        let normalizedRoundID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        func round(_ value: ReconstructionInferenceRoundRequest) -> ReconstructionInferenceRoundRequest {
            let transient = value.transientAnalysis.map {
                ReconstructionTransientAnalysis(schemaVersion: $0.schemaVersion, domain: $0.domain,
                    jobID: $0.jobID, checkpointRevision: 0, corpusManifestSHA256: $0.corpusManifestSHA256,
                    evidenceFrontierSHA256: $0.evidenceFrontierSHA256, budgetBytes: $0.budgetBytes,
                    usedBytes: $0.usedBytes, facts: $0.facts, omissions: $0.omissions)
            }
            return .init(protocolVersion: value.protocolVersion, jobID: value.jobID,
                checkpointRevision: 0, roundID: normalizedRoundID,
                corpusManifestSHA256: value.corpusManifestSHA256,
                evidenceFrontierSHA256: value.evidenceFrontierSHA256,
                registryManifestSHA256: value.registryManifestSHA256, context: value.context,
                handles: value.handles.map { .init(handleID: handleAlias($0.operationID), operationID: $0.operationID) },
                transientAnalysis: transient)
        }
        func final(_ value: ReconstructionFinalSynthesisRequest) -> ReconstructionFinalSynthesisRequest {
            .init(jobID: value.jobID, checkpointRevision: 0, corpusManifestSHA256: value.corpusManifestSHA256,
                  evidenceFrontierSHA256: value.evidenceFrontierSHA256,
                  acceptedEvidenceIDs: value.acceptedEvidenceIDs, context: value.context)
        }
        switch request {
        case .sourceRevision(let value):
            // A repair prompt's retained diagnostic revision is semantic evidence. Zeroing the
            // request revision would make that evidence appear to come from the future and fail
            // the actual provider encoder. Normalize the volatile request binding to the same
            // evidence-derived floor on every retry, leaving all diagnostic bytes unchanged.
            let floor = try sourceDiagnosticRevisionFloor(value)
            return .sourceRevision(.init(protocolVersion: value.protocolVersion, objective: value.objective,
                projectID: value.projectID, jobID: value.jobID, taskID: value.taskID,
                checkpointRevision: floor, roundID: normalizedRoundID, function: value.function,
                corpusManifestSHA256: value.corpusManifestSHA256, evidenceFrontierSHA256: value.evidenceFrontierSHA256,
                oracleSuiteSHA256: value.oracleSuiteSHA256, profileID: value.profileID,
                parentRevisionSHA256: value.parentRevisionSHA256, context: value.context))
        case .round(let value): return .round(round(value))
        case .roundR2(let value): return .roundR2(.init(protocolVersion: value.protocolVersion,
            objective: value.objective, request: round(value.request)))
        case .finalSynthesis(let value): return .finalSynthesis(final(value))
        case .finalSynthesisR2(let value): return .finalSynthesisR2(.init(protocolVersion: value.protocolVersion,
            objective: value.objective, request: final(value.request)))
        }
    }

    private static func sourceDiagnosticRevisionFloor(_ request: ReconstructionSourceRevisionRequest) throws -> UInt64 {
        struct Context: Decodable {
            struct Diagnostic: Decodable { let checkpointRevision: UInt64 }
            let domain: String
            let diagnostics: [Diagnostic]?
        }
        let context = try JSONDecoder().decode(Context.self, from: request.context.canonicalBytes)
        let floor = context.domain == ReconstructionSourceContextCompiler.domain
            ? (context.diagnostics?.map(\.checkpointRevision).max() ?? 0) : 0
        guard floor <= request.checkpointRevision else { throw ReconstructionReplayError.invalidScope }
        return floor
    }

    private static func handleAlias(_ operation: ReconstructionOperationID) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((domain + ":handle:" + operation.rawValue).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension ReconstructionAIWorkerRequest {
    var replayKind: String {
        switch self {
        case .sourceRevision: "sourceRevision"
        case .round: "round"
        case .roundR2: "roundR2"
        case .finalSynthesis: "finalSynthesis"
        case .finalSynthesisR2: "finalSynthesisR2"
        }
    }
    var replayObjective: ReconstructionRequestObjective? {
        switch self {
        case .sourceRevision(let value): value.objective
        case .roundR2(let value): value.objective
        case .finalSynthesisR2(let value): value.objective
        case .round, .finalSynthesis: nil
        }
    }
    var replayJobID: UUID {
        switch semanticRequest {
        case .sourceRevision(let value): value.jobID
        case .round(let value): value.jobID
        case .finalSynthesis(let value): value.jobID
        case .roundR2(let value): value.request.jobID
        case .finalSynthesisR2(let value): value.request.jobID
        }
    }
    var replayCheckpointRevision: UInt64 {
        switch semanticRequest {
        case .sourceRevision(let value): value.checkpointRevision
        case .round(let value): value.checkpointRevision
        case .finalSynthesis(let value): value.checkpointRevision
        case .roundR2(let value): value.request.checkpointRevision
        case .finalSynthesisR2(let value): value.request.checkpointRevision
        }
    }
    var replayRoundID: UUID? {
        switch semanticRequest {
        case .sourceRevision(let value): value.roundID
        case .round(let value): value.roundID
        case .finalSynthesis, .finalSynthesisR2: nil
        case .roundR2(let value): value.request.roundID
        }
    }
    var replayHandles: [ReconstructionOfferedToolHandle] {
        switch semanticRequest {
        case .round(let value): value.handles
        case .roundR2(let value): value.request.handles
        default: []
        }
    }
    func replayEncodedRequest() throws -> Data {
        switch self {
        case .sourceRevision(let value): try ReconstructionCanonicalJSON.encode(value)
        case .round(let value): try ReconstructionCanonicalJSON.encode(value)
        case .roundR2(let value): try ReconstructionCanonicalJSON.encode(value)
        case .finalSynthesis(let value): try ReconstructionCanonicalJSON.encode(value)
        case .finalSynthesisR2(let value): try ReconstructionCanonicalJSON.encode(value)
        }
    }
}

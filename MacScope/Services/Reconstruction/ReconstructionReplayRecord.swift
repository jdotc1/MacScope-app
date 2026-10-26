import Foundation

/// Historical observations only. These values never implement a live-worker receipt protocol,
/// and no replay admission can pass them to a current connection validator.
struct ReconstructionReplayAttestation: Codable, Hashable, Sendable {
    struct Worker: Codable, Hashable, Sendable {
        let processIdentifier: Int32
        let providerGeneration: UInt64
        let connectionIdentity: UUID
        let profileID: UUID
        let configurationGeneration: UInt64
        let protocolManifestDigest: String

        init(_ receipt: Phase2InferenceWorkerProcessReceipt) {
            processIdentifier = receipt.processIdentifier
            providerGeneration = receipt.providerGeneration
            connectionIdentity = receipt.connectionIdentity
            profileID = receipt.profileID
            configurationGeneration = receipt.configurationGeneration
            protocolManifestDigest = receipt.protocolManifestDigest
        }
    }
    struct Connection: Codable, Hashable, Sendable {
        let localAddress: String
        let localPort: UInt16
        let remoteAddress: String
        let remotePort: UInt16

        init(_ receipt: Phase2InferenceProviderConnectionReceipt) {
            localAddress = receipt.localAddress
            localPort = receipt.localPort
            remoteAddress = receipt.remoteAddress
            remotePort = receipt.remotePort
        }
    }
    let worker: Worker?
    let connection: Connection?
    let dispatchRequestID: UUID?
    let connectionWasAttested: Bool

    static let notRequired = Self(worker: nil, connection: nil,
        dispatchRequestID: nil, connectionWasAttested: false)

    func validate(originalRequestID: UUID, model: ReconstructionReplayModelIdentity) throws {
        guard !connectionWasAttested || worker != nil && connection != nil
                && dispatchRequestID == originalRequestID else {
            throw ReconstructionReplayError.missingOriginalAttestation
        }
        if let worker {
            guard worker.processIdentifier > 1,
                  worker.profileID == model.profileID,
                  worker.protocolManifestDigest == model.protocolManifestDigest,
                  worker.configurationGeneration > 0 else { throw ReconstructionReplayError.invalidRecord }
        }
        if let connection {
            guard ["127.0.0.1", "::1"].contains(connection.localAddress),
                  ["127.0.0.1", "::1"].contains(connection.remoteAddress),
                  connection.localPort > 0, connection.remotePort > 0 else {
                throw ReconstructionReplayError.invalidRecord
            }
        }
    }
}

enum ReconstructionReplayCandidate: Codable, Hashable, Sendable {
    case source(ReconstructionSourceRevisionCandidate)
    case round(ReconstructionInferenceRoundCandidate)
    case final(ReconstructionFinalSynthesisCandidate)
}

struct ReconstructionReplayDispatch: Codable, Hashable, Sendable {
    let requestID: UUID
    let processSessionID: UUID
    let dispatchedAt: Date
    /// The prior durable marker had no completed reply. This is an evidence-backed uncertainty,
    /// not a claim that the provider did or did not perform inference before the process died.
    let previousRequestOutcomeUnknown: UUID?
}

struct ReconstructionReplayFreshReply: Codable, Equatable, Sendable {
    let requestIdentitySHA256: String
    let originalRequestBytes: Data
    let terminalReceipt: ReconstructionTerminalReceipt
    let candidate: ReconstructionReplayCandidate
    let usage: Phase2AIWorkerWireUsage
    let modelIdentity: ReconstructionReplayModelIdentity
    let attestation: ReconstructionReplayAttestation
    let offeredHandles: [ReconstructionOfferedToolHandle]
    let publishedAt: Date

    var sha256: String { get throws { try ReconstructionCanonicalJSON.sha256(of: self) } }
}

struct ReconstructionModelReplayReceipt: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable { case fresh, replayed }
    let mode: Mode
    let idempotencyKey: String
    let canonicalPromptSHA256: String
    let logicalRoundIndex: Int
    let modelIdentitySHA256: String
    let originalRequestID: UUID
    let currentRequestID: UUID
    let originalReplySHA256: String
    let observedAt: Date
    let previousRequestOutcomeUnknown: UUID?

    /// Provenance belongs to owner storage. Successful model diagnostics remain nil, including
    /// when a historical reply is accepted after restart.
    var freshModelCallCount: Int { mode == .fresh ? 1 : 0 }
}

struct ReconstructionReplayRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumDispatches = 16
    static let maximumRecordBytes = 1_048_576
    let schemaVersion: Int
    let identity: ReconstructionPromptReplayIdentity
    let dispatches: [ReconstructionReplayDispatch]
    let freshReply: ReconstructionReplayFreshReply?
    let latestObservation: ReconstructionModelReplayReceipt?
    let replayCount: UInt64

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              identity.domain == ReconstructionPromptReplayIdentity.domain,
              identity.logicalRoundIndex >= 0,
              !dispatches.isEmpty, dispatches.count <= Self.maximumDispatches,
              Set(dispatches.map(\.requestID)).count == dispatches.count,
              [identity.objectiveSHA256, identity.modelIdentitySHA256, identity.canonicalPromptSHA256]
                .allSatisfy(ReconstructionSourceInferenceContract.isSHA256),
              dispatches.allSatisfy({ $0.dispatchedAt.timeIntervalSince1970.isFinite }) else {
            throw ReconstructionReplayError.invalidRecord
        }
        if let freshReply {
            let terminal = freshReply.terminalReceipt
            guard terminal.status == .completed,
                  terminal.jobID == identity.objectiveID,
                  terminal.requestID == dispatches.last?.requestID,
                  try freshReply.modelIdentity.sha256 == identity.modelIdentitySHA256,
                  ReconstructionSourceInferenceContract.isSHA256(freshReply.requestIdentitySHA256),
                  Set(freshReply.offeredHandles.map(\.handleID)).count == freshReply.offeredHandles.count,
                  Set(freshReply.offeredHandles.map(\.operationID)).count == freshReply.offeredHandles.count else {
                throw ReconstructionReplayError.invalidRecord
            }
            try freshReply.attestation.validate(originalRequestID: terminal.requestID,
                                                model: freshReply.modelIdentity)
            if case .round(let candidate) = freshReply.candidate {
                guard candidate.jobID == terminal.jobID,
                      candidate.checkpointRevision == terminal.checkpointRevision,
                      candidate.roundID == terminal.roundID,
                      Set(candidate.selectedHandleIDs).isSubset(of: Set(freshReply.offeredHandles.map(\.handleID))) else {
                    throw ReconstructionReplayError.invalidRecord
                }
            }
        } else if latestObservation != nil || replayCount != 0 { throw ReconstructionReplayError.invalidRecord }
        if let observation = latestObservation {
            guard let freshReply,
                  observation.idempotencyKey == (try identity.key),
                  observation.originalRequestID == freshReply.terminalReceipt.requestID,
                  observation.modelIdentitySHA256 == identity.modelIdentitySHA256,
                  observation.canonicalPromptSHA256 == identity.canonicalPromptSHA256,
                  observation.logicalRoundIndex == identity.logicalRoundIndex,
                  observation.originalReplySHA256 == (try freshReply.sha256) else {
                throw ReconstructionReplayError.invalidRecord
            }
        }
    }
}

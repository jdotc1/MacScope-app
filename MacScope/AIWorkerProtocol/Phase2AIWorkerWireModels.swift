import Foundation

struct Phase2AIWorkerHandshake: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case ready }

    let wireProtocol: String
    let inferenceProtocol: String
    let manifestIdentity: String
    let status: Status
}

struct Phase2AIWorkerWireLimits: Codable, Equatable, Sendable {
    let maximumGoalBytes: Int
    let maximumEventBytes: Int
    let maximumCumulativeEventBytes: Int
    let maximumEvents: Int
    let maximumToolHandles: Int
    let maximumToolProposals: Int
    let maximumFinalTextBytes: Int
    let maximumEvidenceReferences: Int

    static let maximum = Self(
        maximumGoalBytes: 65_536,
        maximumEventBytes: 65_536,
        maximumCumulativeEventBytes: 1_048_576,
        maximumEvents: 256,
        maximumToolHandles: 3,
        maximumToolProposals: 3,
        maximumFinalTextBytes: 65_536,
        maximumEvidenceReferences: 3
    )

    /// R2 live Assistant ceiling. Keep `maximum` frozen because it is serialized into the
    /// qualified R1 request corpus; only validation needs to admit the larger R2 handle set.
    static let assistantMaximum = Self(
        maximumGoalBytes: 65_536,
        maximumEventBytes: 65_536,
        maximumCumulativeEventBytes: 1_048_576,
        maximumEvents: 256,
        maximumToolHandles: 8,
        maximumToolProposals: 3,
        maximumFinalTextBytes: 65_536,
        maximumEvidenceReferences: 3
    )

    var isValid: Bool {
        let values = [
            maximumGoalBytes, maximumEventBytes, maximumCumulativeEventBytes, maximumEvents,
            maximumToolHandles, maximumToolProposals, maximumFinalTextBytes,
            maximumEvidenceReferences,
        ]
        let ceilings = [
            Self.assistantMaximum.maximumGoalBytes, Self.assistantMaximum.maximumEventBytes,
            Self.assistantMaximum.maximumCumulativeEventBytes, Self.assistantMaximum.maximumEvents,
            Self.assistantMaximum.maximumToolHandles, Self.assistantMaximum.maximumToolProposals,
            Self.assistantMaximum.maximumFinalTextBytes,
            Self.assistantMaximum.maximumEvidenceReferences,
        ]
        return zip(values, ceilings).allSatisfy { $0 > 0 && $0 <= $1 }
    }
}

struct Phase2AIWorkerWireToolHandle: Codable, Equatable, Sendable {
    let handleID: UUID
    let operationID: String
}

struct Phase2AIWorkerWireConversationTurn: Codable, Equatable, Sendable {
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let user: String
    let assistant: String
    let isLegacy: Bool

    init(
        conversationID: UUID,
        inferenceTurnID: UUID,
        turnSequence: UInt64,
        user: String,
        assistant: String,
        isLegacy: Bool = false
    ) {
        self.conversationID = conversationID
        self.inferenceTurnID = inferenceTurnID
        self.turnSequence = turnSequence
        self.user = user
        self.assistant = assistant
        self.isLegacy = isLegacy
    }
}

struct Phase2AIWorkerWireConversationContext: Codable, Equatable, Sendable {
    let turns: [Phase2AIWorkerWireConversationTurn]
    let omittedTurnCount: Int
}

struct Phase2AIWorkerWireShellContinuationCoordinate: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let workspaceDocumentIdentityDigest: String
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let originatingFinalizationRequestID: UUID
    let shellProposalID: UUID
    let shellExecutionID: UUID
    let runtimeAuthorityRecordID: UUID
    let shellProposalDigest: String
    let shellExecutionResultDigest: String
    let runtimeAuthorityRecordDigest: String
    let productionManifestIdentity: String
    let providerRevision: UInt64
    let continuationOrdinal: UInt64
    let continuationRequestID: UUID
    let integrityDigest: String

}

struct Phase2AIWorkerWireRequest: Codable, Equatable, Sendable {
    let wireProtocol: String
    let protocolVersion: Int
    let phase: Phase2AIWorkerWirePhase
    let sessionID: UUID
    let turnID: UUID
    let requestID: UUID
    let documentID: UUID
    let workspaceID: UUID
    let lifecycleRevision: UInt64
    let userGoal: String
    let canonicalContext: Data
    let contextDigest: String
    let evidenceIDs: [UUID]
    let toolHandles: [Phase2AIWorkerWireToolHandle]
    let conversationContext: Phase2AIWorkerWireConversationContext?
    let shellContinuationCoordinate: Phase2AIWorkerWireShellContinuationCoordinate?
    let limits: Phase2AIWorkerWireLimits

    init(
        wireProtocol: String = Phase2AIWorkerProductionProtocol.wireIdentity,
        protocolVersion: Int,
        phase: Phase2AIWorkerWirePhase = .finalization,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        documentID: UUID,
        workspaceID: UUID,
        lifecycleRevision: UInt64,
        userGoal: String,
        canonicalContext: Data,
        contextDigest: String,
        evidenceIDs: [UUID],
        toolHandles: [Phase2AIWorkerWireToolHandle],
        conversationContext: Phase2AIWorkerWireConversationContext? = nil,
        shellContinuationCoordinate: Phase2AIWorkerWireShellContinuationCoordinate? = nil,
        limits: Phase2AIWorkerWireLimits
    ) {
        self.wireProtocol = wireProtocol
        self.protocolVersion = protocolVersion
        self.phase = phase
        self.sessionID = sessionID
        self.turnID = turnID
        self.requestID = requestID
        self.documentID = documentID
        self.workspaceID = workspaceID
        self.lifecycleRevision = lifecycleRevision
        self.userGoal = userGoal
        self.canonicalContext = canonicalContext
        self.contextDigest = contextDigest
        self.evidenceIDs = evidenceIDs
        self.toolHandles = toolHandles
        self.conversationContext = conversationContext
        self.shellContinuationCoordinate = shellContinuationCoordinate
        self.limits = limits
    }
}

enum Phase2AIWorkerWireFinalKind: String, Codable, Equatable, Sendable {
    case answer
    case insufficientEvidence
}

/// Provider-neutral accounting retained by the app for qualification measurements. The wire
/// deliberately excludes provider payloads, reasoning, prose, identifiers, and wall-clock data.
struct Phase2AIWorkerWireUsage: Codable, Equatable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

/// Control-plane evidence derived from Foundation networking metrics. This is intercepted by the
/// app-side provider and never enters provider-neutral inference events or qualification scoring.
struct Phase2AIWorkerWireProviderConnectionReceipt: Codable, Equatable, Sendable {
    let localAddress: String
    let localPort: Int
    let remoteAddress: String
    let remotePort: Int
}

struct Phase2AIWorkerWireShellProposal: Codable, Equatable, Sendable {
    let proposalID: UUID
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String?
    let timeoutMilliseconds: Int
    let maximumOutputBytes: Int
    let executionSurface: String
    let requestedEffects: [String]
}

struct Phase2AIWorkerWireDebuggerActionProposal: Codable, Equatable, Sendable {
    let proposalID: UUID
    let action: String
    let sessionID: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?
    let requestedAuthority: String
}

enum Phase2AIWorkerWireEventBody: Codable, Equatable, Sendable {
    case contentDelta(String)
    case toolProposal(callID: String, handleID: UUID, functionName: String, operationID: String)
    case shellProposal(Phase2AIWorkerWireShellProposal)
    case debuggerActionProposal(Phase2AIWorkerWireDebuggerActionProposal)
    case finalCandidate(kind: Phase2AIWorkerWireFinalKind, text: String, evidenceIDs: [UUID])
    case usage(Phase2AIWorkerWireUsage)
    case providerConnection(Phase2AIWorkerWireProviderConnectionReceipt)
    case providerDispatch
    case awaitingTools
    case completed
}

struct Phase2AIWorkerWireEvent: Codable, Equatable, Sendable {
    let wireProtocol: String
    let protocolVersion: Int
    let phase: Phase2AIWorkerWirePhase
    let sessionID: UUID
    let turnID: UUID
    let requestID: UUID
    let documentID: UUID
    let workspaceID: UUID
    let lifecycleRevision: UInt64
    let sequence: UInt64
    let body: Phase2AIWorkerWireEventBody

    init(
        wireProtocol: String = Phase2AIWorkerProductionProtocol.wireIdentity,
        protocolVersion: Int,
        phase: Phase2AIWorkerWirePhase = .finalization,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        documentID: UUID,
        workspaceID: UUID,
        lifecycleRevision: UInt64,
        sequence: UInt64,
        body: Phase2AIWorkerWireEventBody
    ) {
        self.wireProtocol = wireProtocol
        self.protocolVersion = protocolVersion
        self.phase = phase
        self.sessionID = sessionID
        self.turnID = turnID
        self.requestID = requestID
        self.documentID = documentID
        self.workspaceID = workspaceID
        self.lifecycleRevision = lifecycleRevision
        self.sequence = sequence
        self.body = body
    }
}

struct Phase2AIWorkerTerminal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case completed
        case awaitingTools
        case cancelled
        case failed
    }

    enum Reason: String, Codable, Sendable {
        case workerNotConfigured
        case requestIdentityMismatch
        case duplicateRequest
        case invalidRequest
        case workerHandlerFailed
        case outputLimitExceeded
        case contextBudgetExceeded
        case overallDeadlineExceeded
        case streamInactivityTimeout
    }

    let wireProtocol: String
    let protocolVersion: Int
    let phase: Phase2AIWorkerWirePhase?
    let requestID: UUID
    let status: Status
    let reason: Reason?
}

enum Phase2AIWorkerWireError: Error, Equatable, Sendable {
    case envelopeTooLarge
    case malformedEnvelope
    case unsupportedWireProtocol(String)
    case unsupportedProtocolVersion(Int)
    case invalidEnvelope
}

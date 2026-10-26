import Foundation

struct Phase2InferenceProtocolVersion: RawRepresentable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let v1 = Self(rawValue: 1)
    static let v2 = Self(rawValue: 2)
    static let v3 = Self(rawValue: 3)
    static let v4 = Self(rawValue: 4)
    static let v5 = Self(rawValue: 5)
    static let v6 = Self(rawValue: 6)

    var requiresProviderUsage: Bool {
        self == .v3 || self == .v4 || self == .v5 || self == .v6
    }
}

struct Phase2InferenceConversationTurn: Hashable, Sendable {
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

struct Phase2InferenceConversationContext: Hashable, Sendable {
    static let maximumTurns = 8
    static let maximumUTF8Bytes = 65_536

    let turns: [Phase2InferenceConversationTurn]
    let omittedTurnCount: Int

    static func retainingNewest(
        from completedTurns: [Phase2InferenceConversationTurn]
    ) -> Self {
        var retained: [Phase2InferenceConversationTurn] = []
        var retainedBytes = 0
        for turn in completedTurns.reversed() {
            let bytes = turn.user.utf8.count + turn.assistant.utf8.count
            guard retained.count < maximumTurns,
                  bytes <= maximumUTF8Bytes - retainedBytes else { break }
            retained.append(turn)
            retainedBytes += bytes
        }
        retained.reverse()
        return .init(
            turns: retained,
            omittedTurnCount: completedTurns.count - retained.count
        )
    }
}

enum Phase2InferencePhase: String, Hashable, Sendable {
    case toolSelection
    case finalization
    case shellContinuation
}

struct Phase2InferenceLimits: Hashable, Sendable {
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

    /// R2 live Assistant ceiling. The frozen R1 `maximum` remains unchanged above.
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
            maximumGoalBytes,
            maximumEventBytes,
            maximumCumulativeEventBytes,
            maximumEvents,
            maximumToolHandles,
            maximumToolProposals,
            maximumFinalTextBytes,
            maximumEvidenceReferences,
        ]
        let ceilings = [
            Self.assistantMaximum.maximumGoalBytes,
            Self.assistantMaximum.maximumEventBytes,
            Self.assistantMaximum.maximumCumulativeEventBytes,
            Self.assistantMaximum.maximumEvents,
            Self.assistantMaximum.maximumToolHandles,
            Self.assistantMaximum.maximumToolProposals,
            Self.assistantMaximum.maximumFinalTextBytes,
            Self.assistantMaximum.maximumEvidenceReferences,
        ]
        return zip(values, ceilings).allSatisfy { $0 > 0 && $0 <= $1 }
    }
}

/// Inert provider-visible metadata. The app retains the matching `Phase2PreparedRead` elsewhere.
struct Phase2InferenceToolHandle: Hashable, Sendable {
    let handleID: UUID
    let operationID: Phase2ReadOperationID
}

struct Phase2InferenceRequest: Hashable, Sendable {
    let protocolVersion: Phase2InferenceProtocolVersion
    let phase: Phase2InferencePhase
    let sessionID: UUID
    let turnID: UUID
    let requestID: UUID
    let document: Phase2ReadDocumentIdentity
    let workspace: Phase2ReadWorkspaceIdentity
    let lifecycleRevision: UInt64
    let userGoal: String
    let groundedContext: Phase2GroundedContext
    let toolHandles: [Phase2InferenceToolHandle]
    let conversationContext: Phase2InferenceConversationContext?
    let shellContinuationCoordinate: Phase2AssistantShellContinuationCoordinate?
    let limits: Phase2InferenceLimits
    /// Optional per-request ceiling, applied to the existing selected provider configuration.
    let maximumOutputTokens: Int?

    init(
        protocolVersion: Phase2InferenceProtocolVersion,
        phase: Phase2InferencePhase = .finalization,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        document: Phase2ReadDocumentIdentity,
        workspace: Phase2ReadWorkspaceIdentity,
        lifecycleRevision: UInt64,
        userGoal: String,
        groundedContext: Phase2GroundedContext,
        toolHandles: [Phase2InferenceToolHandle],
        conversationContext: Phase2InferenceConversationContext? = nil,
        shellContinuationCoordinate: Phase2AssistantShellContinuationCoordinate? = nil,
        limits: Phase2InferenceLimits,
        maximumOutputTokens: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.phase = phase
        self.sessionID = sessionID
        self.turnID = turnID
        self.requestID = requestID
        self.document = document
        self.workspace = workspace
        self.lifecycleRevision = lifecycleRevision
        self.userGoal = userGoal
        self.groundedContext = groundedContext
        self.toolHandles = toolHandles
        self.conversationContext = conversationContext
        self.shellContinuationCoordinate = shellContinuationCoordinate
        self.limits = limits
        self.maximumOutputTokens = maximumOutputTokens
    }

    func boundedProviderConfiguration(
        _ configuration: Phase2AIProviderConfiguration
    ) throws -> Phase2AIProviderConfiguration {
        guard let maximumOutputTokens else { return configuration }
        guard (1...16_384).contains(maximumOutputTokens) else {
            throw Phase2AIProviderConfiguration.ValidationError.invalidMaximumTokens
        }
        return try .init(
            endpoint: configuration.endpoint,
            model: configuration.model,
            maximumTokens: min(configuration.maximumTokens, maximumOutputTokens)
        )
    }
}

enum Phase2InferenceFinalKind: String, Hashable, Sendable {
    case answer
    case insufficientEvidence
}

struct Phase2InferenceFinalCandidate: Hashable, Sendable {
    let kind: Phase2InferenceFinalKind
    let text: String
    let evidenceIDs: [UUID]

    init(
        kind: Phase2InferenceFinalKind = .answer,
        text: String,
        evidenceIDs: [UUID]
    ) {
        self.kind = kind
        self.text = text
        self.evidenceIDs = evidenceIDs
    }
}

/// Opaque provider-local correlation metadata, preserved byte-for-byte.
struct Phase2ProviderToolCallID: RawRepresentable, Hashable, Sendable {
    static let maximumUTF8Bytes = 256

    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Bytes,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  scalar.value > 0x1f && scalar.value != 0x7f
              })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.utf8.count)
        for byte in rawValue.utf8 {
            hasher.combine(byte)
        }
    }
}

/// A provider may propose only an app-issued handle and a provider-local unique call identity.
struct Phase2InferenceToolProposal: Hashable, Sendable {
    let callID: Phase2ProviderToolCallID
    let handleID: UUID
    let functionName: String
    let operationID: Phase2ReadOperationID
}

/// Provider-neutral accounting. Only internally consistent nonnegative token counts survive the
/// worker transport; timing remains app-monotonic and provider payloads never enter this model.
struct Phase2ProviderUsage: Hashable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    init?(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        let (sum, overflow) = promptTokens.addingReportingOverflow(completionTokens)
        guard promptTokens >= 0,
              completionTokens >= 0,
              totalTokens >= 0,
              !overflow,
              sum == totalTokens
        else { return nil }
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

enum Phase2InferenceEventBody: Hashable, Sendable {
    case contentDelta(String)
    case toolProposal(Phase2InferenceToolProposal)
    case shellProposal(Phase2AIShellCommandProposal)
    case debuggerActionProposal(Phase2AIDebuggerActionProposal)
    case finalCandidate(Phase2InferenceFinalCandidate)
    case usage(Phase2ProviderUsage)
    case awaitingTools
    case completed
}

struct Phase2InferenceEvent: Hashable, Sendable {
    let protocolVersion: Phase2InferenceProtocolVersion
    let phase: Phase2InferencePhase
    let sessionID: UUID
    let turnID: UUID
    let requestID: UUID
    let document: Phase2ReadDocumentIdentity
    let workspace: Phase2ReadWorkspaceIdentity
    let lifecycleRevision: UInt64
    let sequence: UInt64
    let body: Phase2InferenceEventBody

    init(
        protocolVersion: Phase2InferenceProtocolVersion,
        phase: Phase2InferencePhase = .finalization,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        document: Phase2ReadDocumentIdentity,
        workspace: Phase2ReadWorkspaceIdentity,
        lifecycleRevision: UInt64,
        sequence: UInt64,
        body: Phase2InferenceEventBody
    ) {
        self.protocolVersion = protocolVersion
        self.phase = phase
        self.sessionID = sessionID
        self.turnID = turnID
        self.requestID = requestID
        self.document = document
        self.workspace = workspace
        self.lifecycleRevision = lifecycleRevision
        self.sequence = sequence
        self.body = body
    }

    var estimatedBytes: Int {
        let fixedEnvelopeBytes = 176
        switch body {
        case .contentDelta(let text):
            return fixedEnvelopeBytes + text.utf8.count
        case .toolProposal(let proposal):
            return fixedEnvelopeBytes + proposal.callID.rawValue.utf8.count + 16
                + proposal.functionName.utf8.count + proposal.operationID.rawValue.utf8.count
        case .shellProposal(let proposal):
            return fixedEnvelopeBytes + 16
                + proposal.executablePath.utf8.count
                + proposal.arguments.reduce(0) { $0 + $1.utf8.count }
                + proposal.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                + (proposal.workingDirectoryPath?.utf8.count ?? 0)
                + proposal.executionSurface.rawValue.utf8.count
                + proposal.requestedEffects.reduce(0) { $0 + $1.rawValue.utf8.count }
        case .debuggerActionProposal(let proposal):
            return fixedEnvelopeBytes + 16
                + proposal.action.rawValue.utf8.count
                + proposal.requestedAuthority.rawValue.utf8.count
                + 48
        case .finalCandidate(let candidate):
            return fixedEnvelopeBytes + candidate.text.utf8.count
                + candidate.evidenceIDs.count * 16
        case .usage:
            return 224
        case .awaitingTools, .completed:
            return fixedEnvelopeBytes
        }
    }
}

enum Phase2InferenceViolation: Error, Equatable, Sendable {
    case invalidRequest
    case identityMismatch
    case sequenceMismatch(expected: UInt64, actual: UInt64)
    case eventTooLarge
    case cumulativeEventLimitExceeded
    case eventCountLimitExceeded
    case phaseMismatch
    case eventNotAllowedInPhase(Phase2InferencePhase)
    case eventNotAllowedInProtocolVersion(Phase2InferenceProtocolVersion)
    case duplicateCallID
    case unknownToolHandle(UUID)
    case toolOperationMismatch(UUID, Phase2ReadOperationID)
    case toolFunctionMismatch(String, Phase2ReadOperationID)
    case repeatedToolHandle(UUID)
    case toolProposalLimitExceeded
    case shellProposalLimitExceeded
    case duplicateShellProposal
    case invalidShellProposal
    case debuggerActionProposalLimitExceeded
    case duplicateDebuggerActionProposal
    case invalidDebuggerActionProposal
    case duplicateFinalCandidate
    case usageBeforeSemanticOutput
    case semanticOutputAfterProviderUsage
    case duplicateProviderUsage
    case invalidFinalCandidate
    case unknownEvidenceID(UUID)
    case duplicateEvidenceID(UUID)
    case completionBeforeFinal
    case completionBeforeToolProposal
    case completionBeforeProviderUsage
    case duplicateCompletion
    case postTerminalEvent
    case providerReturnedWithoutCompletion
    case providerOutputLimitReached
}

/// The provider stopped because the model reached its output-token limit, so
/// any answer it produced is incomplete.
struct Phase2ProviderOutputLimitReached: Error, Equatable, Sendable {}

enum Phase2InferenceDisposition: Equatable, Sendable {
    case completed
    case awaitingTools
    case cancelled
    case protocolViolation
    case limitExceeded
    case providerFailed
    case interrupted
}

struct Phase2InferenceOutcome: Equatable, Sendable {
    let disposition: Phase2InferenceDisposition
    let previewDeltas: [String]
    let toolProposals: [Phase2InferenceToolProposal]
    let shellProposals: [Phase2AIShellCommandProposal]
    let debuggerActionProposals: [Phase2AIDebuggerActionProposal]
    let finalCandidate: Phase2InferenceFinalCandidate?
    let providerUsage: Phase2ProviderUsage?
    let violation: Phase2InferenceViolation?
    let acceptedEventCount: Int
    let cumulativeEventBytes: Int

    init(
        disposition: Phase2InferenceDisposition,
        previewDeltas: [String],
        toolProposals: [Phase2InferenceToolProposal],
        shellProposals: [Phase2AIShellCommandProposal] = [],
        debuggerActionProposals: [Phase2AIDebuggerActionProposal] = [],
        finalCandidate: Phase2InferenceFinalCandidate?,
        providerUsage: Phase2ProviderUsage?,
        violation: Phase2InferenceViolation?,
        acceptedEventCount: Int,
        cumulativeEventBytes: Int
    ) {
        self.disposition = disposition
        self.previewDeltas = previewDeltas
        self.toolProposals = toolProposals
        self.shellProposals = shellProposals
        self.debuggerActionProposals = debuggerActionProposals
        self.finalCandidate = finalCandidate
        self.providerUsage = providerUsage
        self.violation = violation
        self.acceptedEventCount = acceptedEventCount
        self.cumulativeEventBytes = cumulativeEventBytes
    }
}

import Foundation

enum Phase2AssistantSheetState: Equatable {
    case idle
    case running(Phase2AssistantIntent)
    case readinessBlocked(Phase2LocalAIProviderReadiness)
    case failed(title: String, detail: String)
    case cancelled(title: String, detail: String)
    case completed(Phase2AssistantDisplayResult)
}

// MARK: - Same-turn shell continuation presentation

struct Phase2AssistantSameTurnShellCompletionEvidence: Equatable, Sendable {
    let workspaceID: UUID
    let documentID: UUID
    let sessionID: UUID
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: Int
    let originatingRequestID: UUID
    let proposalID: UUID
    let executionID: UUID
    let executionResultDigest: String
    let continuationRequestID: UUID
    let providerRevision: UInt64

    var facts: [Phase2AssistantEvidenceFactDisplay] {
        [
            .init(id: "workspaceID", label: "Workspace ID", value: workspaceID.uuidString),
            .init(id: "documentID", label: "Document ID", value: documentID.uuidString),
            .init(id: "assistantSessionID", label: "Assistant session ID", value: sessionID.uuidString),
            .init(id: "conversationID", label: "Conversation ID", value: conversationID.uuidString),
            .init(id: "inferenceTurnID", label: "Inference turn ID", value: inferenceTurnID.uuidString),
            .init(id: "turnSequence", label: "Turn sequence", value: String(turnSequence)),
            .init(
                id: "originatingRequestID",
                label: "Originating request ID",
                value: originatingRequestID.uuidString
            ),
            .init(id: "shellProposalID", label: "Shell proposal ID", value: proposalID.uuidString),
            .init(id: "shellExecutionID", label: "Shell execution ID", value: executionID.uuidString),
            .init(
                id: "shellExecutionResultDigest",
                label: "Execution result digest",
                value: executionResultDigest
            ),
            .init(
                id: "shellContinuationRequestID",
                label: "Continuation request ID",
                value: continuationRequestID.uuidString
            ),
            .init(
                id: "shellProviderRevision",
                label: "Provider revision",
                value: String(providerRevision)
            ),
        ]
    }

    var plainTextLines: [String] {
        ["Same-turn shell evidence"] + facts.map { "- \($0.label): \($0.value)" }
    }
}

/// Presentation-only projection for the durable same-turn shell lifecycle.
///
/// The persistence/state-machine layer remains the authority for transitions. This type owns
/// only what the Assistant sheet renders and which existing human actions it exposes.
enum Phase2AssistantSameTurnShellPresentationPhase: Equatable, Sendable {
    enum FailureStage: Equatable, Sendable {
        case execution
        case authorityValidation
        case continuation
        case recovery

        var title: String {
            switch self {
            case .execution: "Approved command failed"
            case .authorityValidation: "Shell result could not be verified"
            case .continuation: "Assistant continuation failed"
            case .recovery: "Assistant turn could not be resumed safely"
            }
        }
    }

    case awaitingReview
    case approvedAwaitingRun
    case runningApprovedCommand
    case preparingShellResult
    case continuingAssistant
    case completed(evidence: Phase2AssistantSameTurnShellCompletionEvidence)
    case rejected
    case dismissed
    case cancelled
    case failed(stage: FailureStage, detail: String)
    case recoveryBlocked(detail: String)
}

struct Phase2AssistantSameTurnShellPresentation: Equatable, Sendable {
    enum RetryPolicy: Equatable, Sendable {
        case unavailable
        case startNewTurn
    }

    let title: String
    let detail: String
    let showsProgress: Bool
    let showsApproveAction: Bool
    let showsRunAction: Bool
    let showsRejectAction: Bool
    let showsDismissAction: Bool
    let showsCancelAction: Bool
    let showsManualShellResultContinuation: Bool
    let blocksComposer: Bool
    let isTerminal: Bool
    let retryPolicy: RetryPolicy
    let statusSystemImage: String
    let completionEvidence: Phase2AssistantSameTurnShellCompletionEvidence?

    var accessibilityLabel: String { "Same-turn shell status" }
    var accessibilityValue: String { "\(title). \(detail)" }

    init(phase: Phase2AssistantSameTurnShellPresentationPhase) {
        showsApproveAction = phase == .awaitingReview
        showsRunAction = phase == .approvedAwaitingRun
        showsRejectAction = phase == .awaitingReview
        showsDismissAction = phase == .awaitingReview
        // Cancellation is offered only before Run crosses its durable execution boundary.
        showsCancelAction = phase == .approvedAwaitingRun
        // Eligible R4/v6 turns continue automatically after the explicit Run action.
        // The legacy draft/button remains outside this presentation seam.
        showsManualShellResultContinuation = false
        if case .completed(let evidence) = phase {
            completionEvidence = evidence
        } else {
            completionEvidence = nil
        }

        switch phase {
        case .awaitingReview:
            title = "Shell proposal awaiting review"
            detail = "Review the exact command and limits before approving restricted one-shot execution."
            showsProgress = false
            blocksComposer = true
            isTerminal = false
            retryPolicy = .unavailable
            statusSystemImage = "terminal"
        case .approvedAwaitingRun:
            title = "Shell proposal approved"
            detail = "Run executes the exact approved command once. The command cannot be edited or retried."
            showsProgress = false
            blocksComposer = true
            isTerminal = false
            retryPolicy = .unavailable
            statusSystemImage = "terminal"
        case .runningApprovedCommand:
            title = "Running approved command"
            detail = "MacScope is executing the reviewed restricted one-shot command."
            showsProgress = true
            blocksComposer = true
            isTerminal = false
            retryPolicy = .unavailable
            statusSystemImage = "terminal"
        case .preparingShellResult:
            title = "Preparing shell result"
            detail = "MacScope is validating and sealing the completed execution result."
            showsProgress = true
            blocksComposer = true
            isTerminal = false
            retryPolicy = .unavailable
            statusSystemImage = "terminal"
        case .continuingAssistant:
            title = "Continuing Assistant"
            detail = "MacScope is requesting the final answer from the authority-audited shell result."
            showsProgress = true
            blocksComposer = true
            isTerminal = false
            retryPolicy = .unavailable
            statusSystemImage = "terminal"
        case .completed:
            title = "Shell-assisted turn completed"
            detail = "The approved command completed and its sealed shell result was supplied to the final Assistant continuation."
            showsProgress = false
            blocksComposer = false
            isTerminal = true
            retryPolicy = .unavailable
            statusSystemImage = "checkmark.circle"
        case .rejected:
            title = "Shell proposal rejected"
            detail = "The command was not executed and no shell result was sent to the provider."
            showsProgress = false
            blocksComposer = false
            isTerminal = true
            retryPolicy = .startNewTurn
            statusSystemImage = "xmark.circle"
        case .dismissed:
            title = "Shell proposal dismissed"
            detail = "The command was not executed and this Assistant turn ended."
            showsProgress = false
            blocksComposer = false
            isTerminal = true
            retryPolicy = .startNewTurn
            statusSystemImage = "xmark.circle"
        case .cancelled:
            title = "Assistant turn cancelled"
            detail = "The pending operation was cancelled. No automatic retry will occur."
            showsProgress = false
            blocksComposer = false
            isTerminal = true
            retryPolicy = .startNewTurn
            statusSystemImage = "xmark.circle"
        case .failed(let stage, let failureDetail):
            title = stage.title
            detail = failureDetail
            showsProgress = false
            blocksComposer = false
            isTerminal = true
            retryPolicy = .startNewTurn
            statusSystemImage = "xmark.octagon"
        case .recoveryBlocked(let failureDetail):
            title = "Assistant turn requires durable recovery"
            detail = failureDetail
            showsProgress = false
            blocksComposer = true
            isTerminal = false
            retryPolicy = .unavailable
            statusSystemImage = "exclamationmark.triangle"
        }
    }
}

struct Phase2AssistantHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let sequence: Int
    let intent: Phase2AssistantIntent
    let userGoal: String
    let state: Phase2AssistantSheetState
    let createdAt: Date
    let shellProposalAudit: Phase2AssistantShellProposalReviewAudit?
    private let persistedPlainTextExport: String?

    var isLegacy: Bool { true }

    init(
        id: UUID,
        sequence: Int,
        intent: Phase2AssistantIntent,
        userGoal: String,
        state: Phase2AssistantSheetState,
        createdAt: Date,
        shellProposalAudit: Phase2AssistantShellProposalReviewAudit? = nil,
        persistedPlainTextExport: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.intent = intent
        self.userGoal = userGoal
        self.state = state
        self.createdAt = createdAt
        self.shellProposalAudit = shellProposalAudit
        self.persistedPlainTextExport = persistedPlainTextExport
    }

    var title: String {
        if shellProposalAudit != nil {
            return "Review \(sequence) · Shell proposal"
        }
        return "Run \(sequence) · \(intent.title)"
    }

    var status: String {
        if let shellProposalAudit {
            return shellProposalAudit.status
        }
        switch state {
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .readinessBlocked:
            return "Provider not ready"
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        }
    }

    var summary: String {
        if let shellProposalAudit {
            return shellProposalAudit.summary
        }
        switch state {
        case .completed(let display):
            return display.answer
        case .failed(let title, let detail):
            return "\(title): \(detail)"
        case .cancelled(let title, let detail):
            return "\(title): \(detail)"
        case .readinessBlocked(let readiness):
            return "\(readiness.assistantTitle): \(readiness.assistantDetail)"
        case .idle:
            return "No result."
        case .running(let intent):
            return "Running \(intent.title)…"
        }
    }

    func matchesHistoryFilter(_ query: String) -> Bool {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return true }

        var haystackParts = [
            title,
            status,
            intent.title,
            userGoal,
            summary,
        ]
        if let shellProposalAudit {
            haystackParts.append(shellProposalAudit.plainTextExport(sequence: sequence))
        }
        let haystack = haystackParts.joined(separator: "\n")
        return terms.allSatisfy { term in
            haystack.localizedCaseInsensitiveContains(term)
        }
    }

    var canReuseDraft: Bool {
        shellProposalAudit == nil
    }

    var draft: Phase2AssistantHistoryDraft {
        Phase2AssistantHistoryDraft(
            intent: intent,
            userGoal: trimmedGoal.isEmpty ? intent.defaultGoal(userGoal: "") : trimmedGoal
        )
    }

    var plainTextExport: String {
        if let persistedPlainTextExport,
           !persistedPlainTextExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return persistedPlainTextExport
        }
        if let shellProposalAudit {
            return shellProposalAudit.plainTextExport(sequence: sequence)
        }

        var lines = [
            "MacScope Assistant Session Entry",
            "",
            "Run: \(sequence)",
            "Action: \(intent.title)",
            "Status: \(status)",
            "Prompt: \(trimmedGoal.isEmpty ? intent.defaultGoal(userGoal: "") : trimmedGoal)",
            ""
        ]

        switch state {
        case .completed(let display):
            lines.append(display.plainTextExport)
        case .failed(let title, let detail):
            lines.append("Failure")
            lines.append("- \(title): \(detail)")
            lines.append(contentsOf: state.stopActivity?.plainTextLines ?? [])
        case .cancelled(let title, let detail):
            lines.append("Cancellation")
            lines.append("- \(title): \(detail)")
            lines.append(contentsOf: state.stopActivity?.plainTextLines ?? [])
        case .readinessBlocked(let readiness):
            lines.append("Readiness")
            lines.append("- \(readiness.assistantTitle): \(readiness.assistantDetail)")
            lines.append(contentsOf: state.stopActivity?.plainTextLines ?? [])
        case .idle:
            lines.append("No result.")
        case .running(let intent):
            lines.append("Running \(intent.title)…")
        }
        return lines.joined(separator: "\n")
    }

    var citationPlainTextExport: String? {
        guard case .completed(let display) = state else { return nil }
        return display.citationPlainTextExport
    }

    var evidencePlainTextExport: String? {
        guard case .completed(let display) = state else { return nil }
        return display.evidencePlainTextExport
    }

    var contextPlainTextExport: String? {
        guard case .completed(let display) = state else { return nil }
        return display.contextPlainTextExport
    }

    private var trimmedGoal: String {
        userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Phase2AssistantShellProposalReviewAudit: Equatable {
    enum Event: Equatable {
        case approvedForFutureOneShot
        case approvedForFutureShellBrokerPTY
        case rejectedByUser
        case dismissed
    }

    let event: Event
    let proposalID: UUID
    let disposition: String
    let humanDecision: String
    let command: String
    let workingDirectory: String
    let limits: String
    let authority: String
    let canExecute: Bool
    let validationIssues: [String]

    init?(
        event: Event,
        review: Phase2AIShellProposalReviewState
    ) {
        guard review.isActive,
              let proposalID = review.proposal?.proposalID,
              let command = review.argvPreview
        else { return nil }
        self.event = event
        self.proposalID = proposalID
        self.disposition = review.dispositionSummary
        self.humanDecision = review.humanDecisionSummary
        self.command = command
        self.workingDirectory = review.workingDirectoryPreview ?? "none"
        self.limits = review.limitsPreview ?? "none"
        self.authority = review.authoritySummary
        self.canExecute = review.canExecute
        self.validationIssues = review.issueSummaries
    }

    var status: String {
        switch event {
        case .approvedForFutureOneShot, .approvedForFutureShellBrokerPTY:
            "Review approved"
        case .rejectedByUser:
            "Review rejected"
        case .dismissed:
            "Review dismissed"
        }
    }

    var summary: String {
        "\(event.summaryPrefix): \(command)"
    }

    func plainTextExport(sequence: Int) -> String {
        var lines = [
            "MacScope AI Shell Proposal Review Audit",
            "",
            "Review: \(sequence)",
            "Event: \(event.displayName)",
            "Proposal ID: \(proposalID.uuidString)",
            "Disposition: \(disposition)",
            "Human decision: \(humanDecision)",
            "Command: \(command)",
            "Working directory: \(workingDirectory)",
            "Limits: \(limits)",
            "Authority: \(authority)",
            "Can execute: \(canExecute ? "yes" : "no")"
        ]
        if validationIssues.isEmpty {
            lines.append("Validation issues: none")
        } else {
            lines.append("Validation issues:")
            lines.append(contentsOf: validationIssues.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

private extension Phase2AssistantShellProposalReviewAudit.Event {
    var displayName: String {
        switch self {
        case .approvedForFutureOneShot:
            "Approved for future restricted one-shot"
        case .approvedForFutureShellBrokerPTY:
            "Approved for future ShellBroker PTY transport"
        case .rejectedByUser:
            "Rejected by user"
        case .dismissed:
            "Dismissed"
        }
    }

    var summaryPrefix: String {
        switch self {
        case .approvedForFutureOneShot:
            "Approved shell proposal review"
        case .approvedForFutureShellBrokerPTY:
            "Approved ShellBroker PTY proposal review"
        case .rejectedByUser:
            "Rejected shell proposal review"
        case .dismissed:
            "Dismissed shell proposal review"
        }
    }
}

struct Phase2AssistantHistoryDraft: Equatable {
    let intent: Phase2AssistantIntent
    let userGoal: String
}

struct Phase2AssistantHistoryExportSnapshot: Equatable {
    let text: String
    let suggestedFilename: String
    let entryCount: Int
    let isFiltered: Bool

    init?(
        entries: [Phase2AssistantHistoryEntry],
        filterText: String = ""
    ) {
        let normalizedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleEntries = normalizedFilter.isEmpty
            ? entries
            : entries.filter { $0.matchesHistoryFilter(normalizedFilter) }
        guard !visibleEntries.isEmpty else { return nil }
        self.text = visibleEntries
            .map(\.plainTextExport)
            .joined(separator: "\n\n---\n\n")
        self.suggestedFilename = normalizedFilter.isEmpty
            ? "MacScope-Assistant-History"
            : "MacScope-Assistant-History-Filtered"
        self.entryCount = visibleEntries.count
        self.isFiltered = !normalizedFilter.isEmpty
    }
}

// MARK: - R4 Conversation Presentation

struct Phase2AssistantProviderVisiblePriorTurn: Equatable {
    let inferenceTurnID: UUID
    let turnSequence: Int
    let userMessage: String
    let assistantMessage: String

    var utf8ByteCount: Int {
        userMessage.utf8.count + assistantMessage.utf8.count
    }
}

struct Phase2AssistantConversationTurn: Identifiable, Equatable {
    let inferenceTurnID: UUID
    let turnSequence: Int
    let intent: Phase2AssistantIntent
    let userMessage: String
    var state: Phase2AssistantSheetState
    let createdAt: Date

    var id: UUID { inferenceTurnID }
    var isLegacy: Bool { false }

    var isInFlight: Bool {
        if case .running = state { true } else { false }
    }

    var providerVisiblePriorTurn: Phase2AssistantProviderVisiblePriorTurn? {
        guard case .completed(let result) = state else { return nil }
        let normalizedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAssistantMessage = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserMessage.isEmpty, !normalizedAssistantMessage.isEmpty else { return nil }
        return Phase2AssistantProviderVisiblePriorTurn(
            inferenceTurnID: inferenceTurnID,
            turnSequence: turnSequence,
            userMessage: normalizedUserMessage,
            assistantMessage: normalizedAssistantMessage
        )
    }
}

struct Phase2AssistantConversation: Identifiable, Equatable {
    let conversationID: UUID
    var title: String
    let createdAt: Date
    private(set) var turns: [Phase2AssistantConversationTurn]

    var id: UUID { conversationID }
    var isLegacy: Bool { false }

    init(
        conversationID: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = Date(),
        turns: [Phase2AssistantConversationTurn] = []
    ) {
        self.conversationID = conversationID
        self.title = title
        self.createdAt = createdAt
        self.turns = turns.sorted { lhs, rhs in
            if lhs.turnSequence == rhs.turnSequence { return lhs.createdAt < rhs.createdAt }
            return lhs.turnSequence < rhs.turnSequence
        }
    }

    var nextTurnOrdinal: Int {
        (turns.map(\.turnSequence).max() ?? 0) + 1
    }

    var hasInFlightTurn: Bool {
        turns.contains(where: \.isInFlight)
    }

    var lastActivityAt: Date {
        turns.map(\.createdAt).max() ?? createdAt
    }

    var canSubmitTurn: Bool {
        !hasInFlightTurn
    }

    mutating func appendTurn(_ turn: Phase2AssistantConversationTurn) throws {
        guard !turns.contains(where: {
            $0.inferenceTurnID == turn.inferenceTurnID || $0.turnSequence == turn.turnSequence
        }) else {
            throw Phase2AssistantConversationMutationError.duplicateTurn
        }
        guard !turn.isInFlight || !hasInFlightTurn else {
            throw Phase2AssistantConversationMutationError.turnAlreadyInFlight
        }
        turns.append(turn)
        turns.sort { $0.turnSequence < $1.turnSequence }
    }

    mutating func updateTurnState(
        inferenceTurnID: UUID,
        state: Phase2AssistantSheetState
    ) throws {
        guard let index = turns.firstIndex(where: { $0.inferenceTurnID == inferenceTurnID }) else {
            throw Phase2AssistantConversationMutationError.turnNotFound
        }
        if case .running = state,
           turns.contains(where: { $0.inferenceTurnID != inferenceTurnID && $0.isInFlight }) {
            throw Phase2AssistantConversationMutationError.turnAlreadyInFlight
        }
        turns[index].state = state
    }

    @discardableResult
    mutating func deleteTurn(inferenceTurnID: UUID) -> Bool {
        guard let index = turns.firstIndex(where: { $0.inferenceTurnID == inferenceTurnID }) else {
            return false
        }
        turns.remove(at: index)
        return true
    }

    func providerVisiblePriorTurns(
        maximumCompletedTurns: Int = 8,
        maximumUTF8Bytes: Int = 64 * 1_024
    ) -> [Phase2AssistantProviderVisiblePriorTurn] {
        guard maximumCompletedTurns > 0, maximumUTF8Bytes > 0 else { return [] }
        let completed = turns.compactMap(\.providerVisiblePriorTurn)
        var selected: [Phase2AssistantProviderVisiblePriorTurn] = []
        var selectedBytes = 0

        for turn in completed.reversed() {
            guard selected.count < maximumCompletedTurns else { break }
            guard selectedBytes + turn.utf8ByteCount <= maximumUTF8Bytes else { break }
            selected.append(turn)
            selectedBytes += turn.utf8ByteCount
        }
        return selected.reversed()
    }

    func transcriptProjection(
        maximumTurnCount: Int = 48
    ) -> Phase2AssistantTranscriptProjection {
        guard maximumTurnCount > 0 else {
            return .init(turns: [], omittedTurnCount: turns.count)
        }
        let visibleTurns = Array(turns.suffix(maximumTurnCount))
        return .init(
            turns: visibleTurns,
            omittedTurnCount: turns.count - visibleTurns.count
        )
    }
}

struct Phase2AssistantTranscriptProjection: Equatable {
    let turns: [Phase2AssistantConversationTurn]
    let omittedTurnCount: Int
}

enum Phase2AssistantConversationMutationError: Error, Equatable {
    case conversationNotFound
    case turnNotFound
    case duplicateTurn
    case turnAlreadyInFlight
}

struct Phase2AssistantConversationPresentation: Equatable {
    private(set) var conversations: [Phase2AssistantConversation]
    private(set) var activeConversationID: UUID?
    private(set) var legacyRuns: [Phase2AssistantHistoryEntry]

    init(
        conversations: [Phase2AssistantConversation] = [],
        activeConversationID: UUID? = nil,
        legacyRuns: [Phase2AssistantHistoryEntry] = []
    ) {
        self.conversations = conversations
        self.activeConversationID = conversations.contains(where: { $0.id == activeConversationID })
            ? activeConversationID
            : nil
        self.legacyRuns = legacyRuns
    }

    var activeConversation: Phase2AssistantConversation? {
        guard let activeConversationID else { return nil }
        return conversations.first(where: { $0.id == activeConversationID })
    }

    var activeState: Phase2AssistantSheetState {
        activeConversation?.turns.last?.state ?? .idle
    }

    var canSubmitActiveTurn: Bool {
        activeConversation?.canSubmitTurn ?? true
    }

    var resumableConversations: [Phase2AssistantConversation] {
        conversations.sorted { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    @discardableResult
    mutating func newConversation(
        id: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = Date()
    ) -> UUID {
        conversations.append(
            Phase2AssistantConversation(conversationID: id, title: title, createdAt: createdAt)
        )
        activeConversationID = id
        return id
    }

    mutating func resumeConversation(id: UUID) throws {
        guard conversations.contains(where: { $0.id == id }) else {
            throw Phase2AssistantConversationMutationError.conversationNotFound
        }
        activeConversationID = id
    }

    mutating func replaceConversation(_ conversation: Phase2AssistantConversation) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            throw Phase2AssistantConversationMutationError.conversationNotFound
        }
        conversations[index] = conversation
    }

    @discardableResult
    mutating func deleteConversation(id: UUID) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        conversations.remove(at: index)
        if activeConversationID == id {
            activeConversationID = resumableConversations.first?.id
        }
        return true
    }

    mutating func replaceLegacyRuns(_ entries: [Phase2AssistantHistoryEntry]) {
        legacyRuns = entries
    }
}

struct Phase2AssistantConversationExportSnapshot: Equatable {
    let text: String
    let suggestedFilename: String
    let turnCount: Int

    init?(conversation: Phase2AssistantConversation) {
        guard !conversation.turns.isEmpty else { return nil }
        var lines = [
            "MacScope Assistant Conversation",
            "",
            "Conversation ID: \(conversation.id.uuidString)",
            "Title: \(conversation.title)",
        ]
        for turn in conversation.turns {
            lines.append("")
            lines.append("Turn \(turn.turnSequence)")
            lines.append("User: \(turn.userMessage)")
            switch turn.state {
            case .completed(let result):
                lines.append("Assistant: \(result.answer)")
            case .failed(let title, let detail):
                lines.append("Failed: \(title): \(detail)")
            case .cancelled(let title, let detail):
                lines.append("Cancelled: \(title): \(detail)")
            case .readinessBlocked(let readiness):
                lines.append("Provider not ready: \(readiness.assistantTitle): \(readiness.assistantDetail)")
            case .idle:
                lines.append("Status: Idle")
            case .running(let intent):
                lines.append("Status: Running \(intent.title)")
            }
        }
        self.text = lines.joined(separator: "\n")
        self.suggestedFilename = "MacScope-Assistant-Conversation-\(conversation.id.uuidString)"
        self.turnCount = conversation.turns.count
    }
}

struct Phase2AssistantHistoryState: Equatable {
    static let defaultLimit = 12

    private(set) var entries: [Phase2AssistantHistoryEntry] = []
    private(set) var nextSequence: Int = 1
    var limit: Int = Self.defaultLimit

    var plainTextExport: String? {
        plainTextExport(for: entries)
    }

    func filteredEntries(matching query: String) -> [Phase2AssistantHistoryEntry] {
        entries.filter { $0.matchesHistoryFilter(query) }
    }

    func plainTextExport(matching query: String) -> String? {
        plainTextExport(for: filteredEntries(matching: query))
    }

    private func plainTextExport(for entries: [Phase2AssistantHistoryEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        return entries
            .map(\.plainTextExport)
            .joined(separator: "\n\n---\n\n")
    }

    init(
        entries: [Phase2AssistantHistoryEntry] = [],
        nextSequence: Int = 1,
        limit: Int = Self.defaultLimit
    ) {
        self.limit = limit
        self.entries = Array(entries.prefix(limit))
        self.nextSequence = max(nextSequence, 1)
    }

    init(
        persistenceRecords records: [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord],
        limit: Int = Self.defaultLimit
    ) {
        let sortedRecords = records.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.sequence > rhs.sequence
        }
        let entries = sortedRecords.prefix(limit).compactMap(Self.historyEntry)
        let maxSequence = records.map(\.sequence).max() ?? 0
        self.init(
            entries: entries,
            nextSequence: maxSequence + 1,
            limit: limit
        )
    }

    mutating func record(
        _ state: Phase2AssistantSheetState,
        intent: Phase2AssistantIntent,
        userGoal: String,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        guard state.isHistoryRecordable else { return }
        let entry = Phase2AssistantHistoryEntry(
            id: id,
            sequence: nextSequence,
            intent: intent,
            userGoal: userGoal,
            state: state,
            createdAt: createdAt
        )
        nextSequence += 1
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    mutating func recordShellProposalReview(
        _ review: Phase2AIShellProposalReviewState,
        event: Phase2AssistantShellProposalReviewAudit.Event,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        guard let audit = Phase2AssistantShellProposalReviewAudit(
            event: event,
            review: review
        ) else { return }
        let entry = Phase2AssistantHistoryEntry(
            id: id,
            sequence: nextSequence,
            intent: .askMacScope,
            userGoal: "Review AI shell proposal \(audit.proposalID.uuidString)",
            state: .idle,
            createdAt: createdAt,
            shellProposalAudit: audit
        )
        nextSequence += 1
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    mutating func clear() {
        entries.removeAll()
        nextSequence = 1
    }

    mutating func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty {
            nextSequence = 1
        }
    }

    private static func historyEntry(
        from record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord
    ) -> Phase2AssistantHistoryEntry? {
        let intent = Phase2AssistantIntent(rawValue: record.intentID) ?? .askMacScope
        return Phase2AssistantHistoryEntry(
            id: record.id,
            sequence: record.sequence,
            intent: intent,
            userGoal: record.userGoal,
            state: sheetState(from: record, intent: intent),
            createdAt: record.createdAt,
            persistedPlainTextExport: record.transcriptText
        )
    }

    private static func sheetState(
        from record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord,
        intent: Phase2AssistantIntent
    ) -> Phase2AssistantSheetState {
        switch record.status {
        case .completed:
            return .completed(
                Phase2AssistantDisplayResult(
                    answer: record.answerText ?? record.transcriptText,
                    citations: [],
                    evidenceSummaries: [],
                    activity: nil,
                    contextDisclosure: nil,
                    providerToolCount: record.providerToolCount
                )
            )
        case .failed:
            return .failed(
                title: "Assistant run failed",
                detail: record.transcriptText
            )
        case .cancelled:
            return .cancelled(
                title: "Assistant run cancelled",
                detail: record.transcriptText
            )
        case .readinessBlocked:
            return .readinessBlocked(.unavailable)
        case .outcomeUnknown:
            if let pending = Phase2AssistantSheetState.nonterminalContinuationState(
                intent: intent,
                logicalState: record.continuationCheckpoint?.logicalState
            ) {
                return pending
            }
            return .failed(
                title: "Assistant outcome unavailable",
                detail: record.transcriptText
            )
        }
    }
}

extension Phase2AssistantSheetState {
    static func nonterminalContinuationState(
        intent: Phase2AssistantIntent,
        logicalState: String?
    ) -> Phase2AssistantSheetState? {
        guard let logicalState,
              let continuationState = Phase2AssistantShellContinuationState(
                  rawValue: logicalState
              ),
              !continuationState.isTerminal
        else { return nil }
        return .running(intent)
    }

    var isHistoryRecordable: Bool {
        switch self {
        case .completed, .failed, .cancelled, .readinessBlocked:
            true
        case .idle, .running:
            false
        }
    }

    var isRetryableTerminalState: Bool {
        switch self {
        case .failed, .cancelled, .readinessBlocked:
            true
        case .idle, .running, .completed:
            false
        }
    }

    var stopActivity: Phase2AssistantActivityDisplay? {
        switch self {
        case .failed(let title, let detail):
            return Phase2AssistantActivityDisplay(
                summary: "Stopped: \(title)",
                facts: [
                    Phase2AssistantEvidenceFactDisplay(
                        id: "status",
                        label: "Status",
                        value: "failed"
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "reason",
                        label: "Reason",
                        value: title
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "detail",
                        label: "Detail",
                        value: detail
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "sideEffects",
                        label: "Side effects",
                        value: "none from stop presentation"
                    ),
                ]
            )
        case .readinessBlocked(let readiness):
            return Phase2AssistantActivityDisplay(
                summary: "Blocked: \(readiness.assistantTitle)",
                facts: [
                    Phase2AssistantEvidenceFactDisplay(
                        id: "status",
                        label: "Status",
                        value: "provider not ready"
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "reason",
                        label: "Reason",
                        value: readiness.assistantTitle
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "detail",
                        label: "Detail",
                        value: readiness.assistantDetail
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "providerDispatch",
                        label: "Provider dispatch",
                        value: "not started"
                    ),
                ]
            )
        case .cancelled(let title, let detail):
            return Phase2AssistantActivityDisplay(
                summary: "Cancelled: \(title)",
                facts: [
                    Phase2AssistantEvidenceFactDisplay(
                        id: "status",
                        label: "Status",
                        value: "cancelled"
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "reason",
                        label: "Reason",
                        value: title
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "detail",
                        label: "Detail",
                        value: detail
                    ),
                    Phase2AssistantEvidenceFactDisplay(
                        id: "finalAnswer",
                        label: "Final answer",
                        value: "none accepted"
                    ),
                ]
            )
        case .idle, .running, .completed:
            return nil
        }
    }
}

struct Phase2AssistantDisplayResult: Equatable {
    let answer: String
    let citations: [Phase2AssistantCitationDisplay]
    let evidenceSummaries: [Phase2AssistantEvidenceDisplay]
    let activity: Phase2AssistantActivityDisplay?
    let contextDisclosure: Phase2AssistantContextDisclosureDisplay?
    let providerToolCount: Int
    let sameTurnShellEvidence: Phase2AssistantSameTurnShellCompletionEvidence?
    /// Addresses in the answer that the accepted evidence does not support.
    let unverifiedAddresses: [String]

    init(
        answer: String,
        citations: [Phase2AssistantCitationDisplay],
        evidenceSummaries: [Phase2AssistantEvidenceDisplay],
        activity: Phase2AssistantActivityDisplay?,
        contextDisclosure: Phase2AssistantContextDisclosureDisplay?,
        providerToolCount: Int = 0,
        sameTurnShellEvidence: Phase2AssistantSameTurnShellCompletionEvidence? = nil,
        unverifiedAddresses: [String] = []
    ) {
        self.unverifiedAddresses = unverifiedAddresses
        self.answer = answer
        self.citations = citations
        self.evidenceSummaries = evidenceSummaries
        self.activity = activity
        self.contextDisclosure = contextDisclosure
        self.providerToolCount = providerToolCount
        self.sameTurnShellEvidence = sameTurnShellEvidence
    }

    var isFullyGrounded: Bool { unverifiedAddresses.isEmpty }

    /// Shown with an answer that quotes addresses the evidence does not support.
    var groundingWarning: String? {
        guard !unverifiedAddresses.isEmpty else { return nil }
        return "Not fully grounded: \(unverifiedAddresses.joined(separator: ", ")) "
            + "\(unverifiedAddresses.count == 1 ? "is" : "are") not in the accepted evidence. "
            + "Check these addresses before relying on them."
    }

    var plainTextExport: String {
        var lines = [
            "MacScope Assistant Result",
            "",
            answer
        ]
        if let groundingWarning {
            lines.append("")
            lines.append(groundingWarning)
        }

        if !evidenceSummaries.isEmpty {
            lines.append("")
            lines.append("Evidence")
            for evidence in evidenceSummaries {
                lines.append("- \(evidence.title): \(evidence.summary)")
                for fact in evidence.allFacts {
                    lines.append("  - \(fact.label): \(fact.value)")
                }
                if !evidence.identityFacts.isEmpty {
                    lines.append("  - Accepted record:")
                    for fact in evidence.identityFacts {
                        lines.append("    - \(fact.label): \(fact.value)")
                    }
                }
                if !evidence.citations.isEmpty {
                    lines.append("  - Citation targets:")
                    for citation in evidence.citations {
                        lines.append("    - \(citation.title): \(citation.detail)")
                    }
                }
            }
        }

        if let sameTurnShellEvidence {
            lines.append("")
            lines.append(contentsOf: sameTurnShellEvidence.plainTextLines)
        }

        if let activity {
            lines.append("")
            lines.append("Activity")
            lines.append("- \(activity.summary)")
            for fact in activity.facts {
                lines.append("  - \(fact.label): \(fact.value)")
            }
        }

        if let contextDisclosure {
            lines.append("")
            lines.append("Context")
            lines.append("- Sent: \(contextDisclosure.actualOperations.map(\.id).joined(separator: ", "))")
            let excluded = contextDisclosure.excludedOperations.map(\.id).joined(separator: ", ")
            lines.append("- Excluded: \(excluded.isEmpty ? "none" : excluded)")
            lines.append("- Omitted: \(contextDisclosure.omittedEvidence.isEmpty ? "none" : "\(contextDisclosure.omittedEvidence.count)")")
            if let canonicalByteCount = contextDisclosure.canonicalByteCount {
                lines.append("- Canonical bytes: \(canonicalByteCount)")
            }
            if let digest = contextDisclosure.digest {
                lines.append("- Digest: \(digest)")
            }
            lines.append("- \(contextDisclosure.authoritySummary)")
            lines.append("- Retention: \(contextDisclosure.retentionSummary)")
        }

        if !citations.isEmpty {
            lines.append("")
            lines.append("Citations")
            for citation in citations {
                lines.append("- \(citation.title): \(citation.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var citationPlainTextExport: String? {
        guard !citations.isEmpty else { return nil }
        var lines = [
            "MacScope Assistant Citations"
        ]
        for citation in citations {
            lines.append("- \(citation.title): \(citation.detail)")
        }
        return lines.joined(separator: "\n")
    }

    var evidencePlainTextExport: String? {
        guard !evidenceSummaries.isEmpty || sameTurnShellEvidence != nil else { return nil }
        var lines = [
            "MacScope Assistant Evidence"
        ]
        for evidence in evidenceSummaries {
            lines.append("- \(evidence.title): \(evidence.summary)")
            for fact in evidence.allFacts {
                lines.append("  - \(fact.label): \(fact.value)")
            }
            if !evidence.identityFacts.isEmpty {
                lines.append("  - Accepted record:")
                for fact in evidence.identityFacts {
                    lines.append("    - \(fact.label): \(fact.value)")
                }
            }
            if !evidence.citations.isEmpty {
                lines.append("  - Citation targets:")
                for citation in evidence.citations {
                    lines.append("    - \(citation.title): \(citation.detail)")
                }
            }
        }
        if let sameTurnShellEvidence {
            if !evidenceSummaries.isEmpty { lines.append("") }
            lines.append(contentsOf: sameTurnShellEvidence.plainTextLines)
        }
        return lines.joined(separator: "\n")
    }

    var contextPlainTextExport: String? {
        contextDisclosure?.plainTextExport
    }
}

struct Phase2AssistantActivityDisplay: Equatable {
    let summary: String
    let facts: [Phase2AssistantEvidenceFactDisplay]

    var plainTextLines: [String] {
        var lines = [
            "Activity",
            "- \(summary)"
        ]
        for fact in facts {
            lines.append("  - \(fact.label): \(fact.value)")
        }
        return lines
    }
}

struct Phase2AssistantContextDisclosureDisplay: Equatable {
    let plannedOperations: [Phase2AssistantContextOperationDisplay]
    let excludedOperations: [Phase2AssistantContextOperationDisplay]
    let actualOperations: [Phase2AssistantContextOperationDisplay]
    let omittedEvidence: [Phase2AssistantContextOmissionDisplay]
    let canonicalByteCount: Int?
    let digest: String?
    let privacySummary: String
    let authoritySummary: String
    let retentionSummary: String

    var plainTextExport: String {
        var lines = [
            "MacScope Assistant Context",
            "- Sent: \(actualOperations.map(\.id).joined(separator: ", "))"
        ]
        let excluded = excludedOperations.map(\.id).joined(separator: ", ")
        lines.append("- Excluded: \(excluded.isEmpty ? "none" : excluded)")
        lines.append("- Omitted: \(omittedEvidence.isEmpty ? "none" : "\(omittedEvidence.count)")")
        if let canonicalByteCount {
            lines.append("- Canonical bytes: \(canonicalByteCount)")
        }
        if let digest {
            lines.append("- Digest: \(digest)")
        }
        lines.append("- \(authoritySummary)")
        lines.append("- Retention: \(retentionSummary)")
        return lines.joined(separator: "\n")
    }
}

struct Phase2AssistantContextOperationDisplay: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isSupplemental: Bool
}

struct Phase2AssistantContextOmissionDisplay: Identifiable, Equatable {
    let id: UUID
    let reason: String
}

struct Phase2AssistantEvidenceDisplay: Identifiable, Equatable {
    let id: UUID
    let title: String
    let summary: String
    let facts: [Phase2AssistantEvidenceFactDisplay]
    let allFacts: [Phase2AssistantEvidenceFactDisplay]
    let identityFacts: [Phase2AssistantEvidenceFactDisplay]
    let citations: [Phase2AssistantCitationDisplay]

    var hiddenFactCount: Int {
        max(0, allFacts.count - facts.count)
    }
}

struct Phase2AssistantEvidenceFactDisplay: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

struct Phase2AssistantCitationDisplay: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String
    let target: Phase2ReadCitationTarget

    var isNavigable: Bool {
        switch target {
        case .image, .staticLocation, .functionRange:
            return true
        case .workspace:
            return false
        }
    }
}

extension Phase2ReadCitationTarget {
    /// The reader-facing location of a citation, e.g. "image 0 · 0x100000434–0x10000045c".
    var displayLabel: String {
        func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
        switch self {
        case .workspace:
            return "workspace"
        case .image(let image):
            return "image \(image.slot.rawValue)"
        case .staticLocation(let location):
            let address: String
            switch location.domain {
            case .imageVirtualAddress: address = hex(location.address)
            case .fileOffset: address = "file offset " + hex(location.address)
            case .syntheticPresentation: address = "synthetic " + hex(location.address)
            }
            return "image \(location.image.slot.rawValue) · \(address)"
        case .functionRange(let range):
            return "image \(range.image.slot.rawValue) · \(hex(range.start))–\(hex(range.endExclusive))"
        }
    }
}

enum Phase2AssistantDisplayMapper {
    static func contextPreview(
        intent: Phase2AssistantIntent,
        options: Phase2AssistantContextOptions = .default
    ) -> Phase2AssistantContextDisclosureDisplay {
        let planned = intent.requiredOperations.map {
            contextOperationDisplay(for: $0, isSupplemental: false)
        } + intent.includedSupplementalOperations(options: options).map {
            contextOperationDisplay(for: $0, isSupplemental: true)
        }
        let excluded = intent.excludedSupplementalOperations(options: options).map {
            contextOperationDisplay(for: $0, isSupplemental: true)
        }
        return Phase2AssistantContextDisclosureDisplay(
            plannedOperations: planned,
            excludedOperations: excluded,
            actualOperations: planned,
            omittedEvidence: [],
            canonicalByteCount: nil,
            digest: nil,
            privacySummary: Self.privacySummary,
            authoritySummary: authoritySummary(options: options),
            retentionSummary: Self.retentionSummary
        )
    }

    static var staleResultState: Phase2AssistantSheetState {
        .failed(
            title: "Assistant result stale",
            detail: "The workspace, focused image, selection, or analysis changed before the assistant finished. Run the request again for the current state."
        )
    }

    static func state(
        for result: Phase2AssistantSessionResult,
        sameTurnShellEvidence: Phase2AssistantSameTurnShellCompletionEvidence? = nil
    ) -> Phase2AssistantSheetState {
        if let failure = result.failure {
            return failureState(for: failure, rejection: result.requestRejection)
        }

        guard let outcome = result.inferenceOutcome else {
            return .failed(
                title: "No inference result",
                detail: "The assistant run ended before the provider returned a final answer."
            )
        }

        if outcome.violation == .providerOutputLimitReached {
            return .failed(
                title: "Output limit reached",
                detail: "The model reached its maximum output before finishing, so the answer is incomplete. "
                    + "Raise Maximum output in Settings > Local AI or ask a narrower question."
            )
        }

        guard result.isAcceptedFinalAnswer,
              let candidate = outcome.finalCandidate
        else {
            return .failed(
                title: "No accepted final answer",
                detail: rejectedFinalizationDetail(outcome)
            )
        }

        let citations = result.groundedContext?.records.flatMap { record in
            record.citations.map { citation in
                Phase2AssistantCitationDisplay(
                    id: citation.id,
                    title: record.descriptor.id.rawValue,
                    detail: citation.target.displayLabel,
                    target: citation.target
                )
            }
        } ?? []
        let evidenceSummaries = result.groundedContext?.records.map(evidenceDisplay) ?? []
        let contextDisclosure = result.groundedContext.map { context in
            actualContextDisclosure(
                for: context,
                intent: result.intent,
                usedProviderVisibleToolSelection: result.toolSelectionRequest != nil
            )
        }
        let extractedAnswer = Phase2AssistantAuthoringProposalDraft.extract(from: candidate.text).answer
        let displayedAnswer = result.unverifiedAddresses.isEmpty || result.groundedContext == nil
            ? extractedAnswer
            : Phase2AssistantAddressCheck(context: result.groundedContext!)
                .flaggingUnsupportedAddresses(in: extractedAnswer)

        return .completed(
            Phase2AssistantDisplayResult(
                answer: displayedAnswer,
                citations: citations,
                evidenceSummaries: evidenceSummaries,
                activity: activityDisplay(
                    for: result,
                    sameTurnShellEvidence: sameTurnShellEvidence
                ),
                contextDisclosure: contextDisclosure,
                providerToolCount: result.toolSelectionOutcome?.toolProposals.count ?? 0,
                sameTurnShellEvidence: sameTurnShellEvidence,
                unverifiedAddresses: result.unverifiedAddresses
            )
        )
    }

    private static func rejectedFinalizationDetail(_ outcome: Phase2InferenceOutcome) -> String {
        // Preserve the existing typed failure in history without retaining model output.
        // Associated violation metadata is bounded even if supplied by a hostile provider.
        let violation = outcome.violation.map {
            String(String.UnicodeScalarView(String(describing: $0).unicodeScalars.prefix(512)))
        } ?? "none"
        let kind = outcome.finalCandidate?.kind.rawValue ?? "none"
        return "The provider did not return a completed answer backed by the accepted evidence set. "
            + "Finalization disposition: \(outcome.disposition). Violation: \(violation). Candidate kind: \(kind)."
    }

    private static let privacySummary = "Only accepted read-only MacScope evidence from the current workspace is sent. Binary-derived strings are treated as untrusted project data."
    private static let retentionSummary = "Terminal Assistant results are stored in the workspace history; grounded context is summarized and cited, not retained as a provider session."

    private static func actualContextDisclosure(
        for context: Phase2GroundedContext,
        intent: Phase2AssistantIntent,
        usedProviderVisibleToolSelection: Bool
    ) -> Phase2AssistantContextDisclosureDisplay {
        let actual = context.records.map {
            contextOperationDisplay(
                for: $0.descriptor.id,
                isSupplemental: intent.supplementalOperations.contains($0.descriptor.id)
            )
        }
        let actualIDs = Set(context.records.map(\.descriptor.id))
        let excluded = intent.supplementalOperations
            .filter { !actualIDs.contains($0) }
            .map { contextOperationDisplay(for: $0, isSupplemental: true) }
        return Phase2AssistantContextDisclosureDisplay(
            plannedOperations: actual,
            excludedOperations: excluded,
            actualOperations: actual,
            omittedEvidence: context.omissions.map {
                Phase2AssistantContextOmissionDisplay(
                    id: $0.evidenceID,
                    reason: $0.reason.rawValue
                )
            },
            canonicalByteCount: context.canonicalBytes.count,
            digest: context.digest,
            privacySummary: Self.privacySummary,
            authoritySummary: authoritySummary(
                useProviderVisibleToolSelection: usedProviderVisibleToolSelection
            ),
            retentionSummary: Self.retentionSummary
        )
    }

    private static func authoritySummary(options: Phase2AssistantContextOptions) -> String {
        authoritySummary(
            useProviderVisibleToolSelection: options.useProviderVisibleToolSelection
        )
    }

    private static func authoritySummary(useProviderVisibleToolSelection: Bool) -> String {
        if useProviderVisibleToolSelection {
            return "Provider tools: read-only R1 MacScope handles only; MacScope executes accepted reads and finalization receives accepted evidence."
        }
        return "Provider tools: none. The model receives finalization context only."
    }

    private static func contextOperationDisplay(
        for operation: Phase2ReadOperationID,
        isSupplemental: Bool
    ) -> Phase2AssistantContextOperationDisplay {
        Phase2AssistantContextOperationDisplay(
            id: operation.rawValue,
            title: operation.rawValue,
            detail: contextOperationDetail(for: operation, isSupplemental: isSupplemental),
            isSupplemental: isSupplemental
        )
    }

    private static func contextOperationDetail(
        for operation: Phase2ReadOperationID,
        isSupplemental: Bool
    ) -> String {
        switch operation {
        case .workspaceSummary:
            return "Required workspace overview"
        case .applicationGraphSummary:
            return "Supplemental dependency graph summary"
        case .selectionExplain:
            return "Required selected-location evidence"
        case .functionReview:
            return "Required current-function evidence"
        case .decompilerNativeResult:
            return "Native decompiler evidence"
        case .decompilerMacScopeResult:
            return "MacScope decompiler evidence"
        case .decompilerCompare:
            return "Native and MacScope comparison evidence"
        default:
            return isSupplemental ? "Supplemental read-only evidence" : "Required read-only evidence"
        }
    }

    private static func evidenceDisplay(
        for record: Phase2GroundedContextRecord
    ) -> Phase2AssistantEvidenceDisplay {
        let allFacts = evidenceFacts(for: record.data)
        let citations = record.citations.map {
            Phase2AssistantCitationDisplay(
                id: $0.id,
                title: record.descriptor.id.rawValue,
                detail: $0.target.displayLabel,
                target: $0.target
            )
        }
        return Phase2AssistantEvidenceDisplay(
            id: record.evidenceID,
            title: record.descriptor.id.rawValue,
            summary: evidenceSummary(for: record),
            facts: Array(allFacts.prefix(6)),
            allFacts: allFacts,
            identityFacts: evidenceIdentityFacts(for: record),
            citations: citations
        )
    }

    private static func activityDisplay(
        for result: Phase2AssistantSessionResult,
        sameTurnShellEvidence: Phase2AssistantSameTurnShellCompletionEvidence?
    ) -> Phase2AssistantActivityDisplay {
        let toolSelectionOutcome = result.toolSelectionOutcome
        let finalOutcome = result.inferenceOutcome
        let usedProviderVisibleSelection = toolSelectionOutcome != nil
        let toolProposalCount = toolSelectionOutcome?.toolProposals.count ?? 0
        let shellProposalCount = sameTurnShellEvidence == nil
            ? (finalOutcome?.shellProposals.count ?? 0)
            : 1
        let finalEventCount = finalOutcome?.acceptedEventCount ?? 0
        let toolSelectionEventCount = toolSelectionOutcome?.acceptedEventCount ?? 0
        let finalBytes = finalOutcome?.cumulativeEventBytes ?? 0
        let toolSelectionBytes = toolSelectionOutcome?.cumulativeEventBytes ?? 0
        let providerUsage = finalOutcome?.providerUsage

        var facts = [
            Phase2AssistantEvidenceFactDisplay(
                id: "providerVisibleSelection",
                label: "Provider-visible read selection",
                value: usedProviderVisibleSelection ? "yes" : "no"
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "readExecutions",
                label: "Native reads executed",
                value: String(result.readExecutions.count)
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "toolProposals",
                label: "Tool proposals accepted",
                value: String(toolProposalCount)
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "shellProposals",
                label: "Shell proposals staged",
                value: String(shellProposalCount)
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "providerEvents",
                label: "Provider events accepted",
                value: String(finalEventCount + toolSelectionEventCount)
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "providerEventBytes",
                label: "Provider event bytes",
                value: String(finalBytes + toolSelectionBytes)
            ),
        ]

        if let providerUsage {
            facts.append(contentsOf: [
                Phase2AssistantEvidenceFactDisplay(
                    id: "promptTokens",
                    label: "Prompt tokens",
                    value: String(providerUsage.promptTokens)
                ),
                Phase2AssistantEvidenceFactDisplay(
                    id: "completionTokens",
                    label: "Completion tokens",
                    value: String(providerUsage.completionTokens)
                ),
                Phase2AssistantEvidenceFactDisplay(
                    id: "totalTokens",
                    label: "Total tokens",
                    value: String(providerUsage.totalTokens)
                ),
            ])
        }

        if let sameTurnShellEvidence {
            facts.append(contentsOf: sameTurnShellEvidence.facts)
        }

        let readText = "\(result.readExecutions.count) native read\(result.readExecutions.count == 1 ? "" : "s")"
        let eventCount = finalEventCount + toolSelectionEventCount
        let eventText = "\(eventCount) accepted provider event\(eventCount == 1 ? "" : "s")"
        let shellText = sameTurnShellEvidence == nil ? "" : ", 1 approved shell execution"
        return Phase2AssistantActivityDisplay(
            summary: "\(readText), \(eventText)\(shellText)",
            facts: facts
        )
    }

    private static func evidenceIdentityFacts(
        for record: Phase2GroundedContextRecord
    ) -> [Phase2AssistantEvidenceFactDisplay] {
        [
            Phase2AssistantEvidenceFactDisplay(
                id: "evidenceID",
                label: "Evidence ID",
                value: record.evidenceID.uuidString
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "candidateID",
                label: "Candidate ID",
                value: record.candidateID.uuidString
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "invocationID",
                label: "Invocation ID",
                value: record.invocationID.uuidString
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "sequence",
                label: "Sequence",
                value: String(record.sequence)
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "producer",
                label: "Producer",
                value: String(describing: record.producingPrincipal)
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "trustClass",
                label: "Trust Class",
                value: record.trustClass.rawValue
            ),
            Phase2AssistantEvidenceFactDisplay(
                id: "payloadDigest",
                label: "Payload Digest",
                value: record.payloadDigest
            ),
        ]
    }

    private static func evidenceSummary(for record: Phase2GroundedContextRecord) -> String {
        switch record.descriptor.id {
        case let id where id == .workspaceSummary:
            let workspace = record.data.field("workspaceName")?.displayValue ?? "workspace"
            let imageCount = record.data.field("loadedImageCount")?.displayValue ?? "0"
            return "\(workspace), \(imageCount) loaded image\(imageCount == "1" ? "" : "s")"
        case let id where id == .applicationGraphSummary:
            let declared = record.data.field("declaredDependencyCount")?.displayValue ?? "0"
            let external = record.data.field("externalDependencyCount")?.displayValue ?? "0"
            let unresolved = record.data.field("unresolvedDependencyCount")?.displayValue ?? "0"
            return "\(declared) declared dependenc\(declared == "1" ? "y" : "ies"), \(external) external, \(unresolved) unresolved"
        case let id where id == .selectionExplain:
            let location = record.data.field("location")?.displayValue ?? "current selection"
            return "Selection at \(location)"
        case let id where id == .functionReview:
            let name = record.data.field("name")?.displayValue ?? "current function"
            let total = record.data.field("instructionPage")?.field("totalCount")?.displayValue ?? "0"
            return "\(name), \(total) instruction\(total == "1" ? "" : "s")"
        case let id where id == .decompilerNativeResult:
            return decompilerEvidenceSummary(record, fallbackSource: "Native")
        case let id where id == .decompilerMacScopeResult:
            return decompilerEvidenceSummary(record, fallbackSource: "MacScope")
        case let id where id == .decompilerCompare:
            return "Native and MacScope evidence for the current function"
        default:
            return record.descriptor.id.rawValue
        }
    }

    private static func decompilerEvidenceSummary(
        _ record: Phase2GroundedContextRecord,
        fallbackSource: String
    ) -> String {
        let source = record.data.field("source")?.displayValue ?? fallbackSource
        let status = record.data.field("status")?.displayValue ?? "unavailable"
        let function = record.data.field("functionName")?.displayValue ?? "current function"
        return "\(source) \(status) evidence for \(function)"
    }

    private static func evidenceFacts(
        for data: Phase2ReadCandidateData
    ) -> [Phase2AssistantEvidenceFactDisplay] {
        guard case .value(let value) = data else { return [] }
        return value.flattenedAssistantFacts()
    }

    private static func failureState(for failure: Phase2AssistantSessionFailure,
                                     rejection: Phase2AssistantRequestRejection?) -> Phase2AssistantSheetState {
        switch failure {
        case .readUnavailable(let operation, let reason):
            return .failed(
                title: "Read unavailable",
                detail: "\(operation.rawValue): \(reason.rawValue)"
            )
        case .readRejected(let operation, let disposition),
             .evidenceRejected(let operation, let disposition):
            return .failed(
                title: "Evidence rejected",
                detail: "\(operation.rawValue): \(disposition.rawValue)"
            )
        case .groundedContextUnavailable:
            return .failed(
                title: "No grounded context",
                detail: "The accepted read did not produce provider-safe grounded context."
            )
        case .groundedContextFailed(let detail):
            return .failed(title: "Grounding failed", detail: detail)
        case .inferenceNotReady(let readiness):
            return .readinessBlocked(readiness)
        case .inferenceBusy:
            return .failed(title: "Assistant busy", detail: "A ready-inference request is already running.")
        case .inferenceInvalidRequest:
            let detail = rejection.map {
                "The Assistant request was rejected at \($0.stage.rawValue). \($0.reasonCode)."
            } ?? "The Assistant request was rejected. The rejecting stage was not retained."
            return .failed(title: "Invalid inference request", detail: detail)
        case .providerAuthorityChanged:
            return .failed(title: "Provider changed", detail: "The selected provider authority changed before the run could complete.")
        }
    }
}

private extension Phase2AssistantIntent {
    func includedSupplementalOperations(
        options: Phase2AssistantContextOptions
    ) -> [Phase2ReadOperationID] {
        supplementalOperations.filter { operation in
            switch operation {
            case .applicationGraphSummary:
                options.includeApplicationGraphContext
            default:
                true
            }
        }
    }

    func excludedSupplementalOperations(
        options: Phase2AssistantContextOptions
    ) -> [Phase2ReadOperationID] {
        supplementalOperations.filter { operation in
            !includedSupplementalOperations(options: options).contains(operation)
        }
    }
}

private extension Phase2ReadCandidateData {
    func field(_ name: String) -> Phase2ReadFactValue? {
        guard case .value(let value) = self else { return nil }
        return value.field(name)
    }
}

private extension Phase2ReadFactValue {
    func field(_ name: String) -> Phase2ReadFactValue? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.name == name }?.value
    }

    func flattenedAssistantFacts(
        path: [String] = []
    ) -> [Phase2AssistantEvidenceFactDisplay] {
        switch self {
        case .object(let fields):
            return fields.flatMap { field in
                field.value.flattenedAssistantFacts(
                    path: path + [field.name]
                )
            }
        case .list(let values):
            guard !values.isEmpty else {
                return [assistantFact(path: path, value: "0 items")]
            }
            let summary = [assistantFact(
                path: path,
                value: "\(values.count) item\(values.count == 1 ? "" : "s")"
            )]
            let expanded = values.enumerated().flatMap { index, value in
                value.flattenedAssistantFacts(
                    path: path + ["\(index)"]
                )
            }
            return summary + expanded
        case .unsignedInteger(let address)
            where path.last.map(Phase2GroundedAddressProjection.addressFactNames.contains) == true:
            return [assistantFact(path: path, value: Phase2GroundedAddressProjection.hex(address))]
        default:
            let value = displayValue
            guard !value.isEmpty else { return [] }
            return [assistantFact(path: path, value: value)]
        }
    }

    private func assistantFact(
        path: [String],
        value: String
    ) -> Phase2AssistantEvidenceFactDisplay {
        let id = path.isEmpty ? "value" : path.joined(separator: ".")
        return Phase2AssistantEvidenceFactDisplay(
            id: id,
            label: id.phase2AssistantFactLabel,
            value: value
        )
    }
}

extension Phase2ReadFactValue {
    /// Readable text for an evidence fact, shared by summaries, fact rows and tests.
    var displayValue: String {
        switch self {
        case .boolean(let value):
            return value ? "true" : "false"
        case .signedInteger(let value):
            return String(value)
        case .unsignedInteger(let value):
            return String(value)
        case .text(let value):
            return value
        case .staticLocation(let location):
            return Phase2ReadCitationTarget.staticLocation(location).displayLabel
        case .list(let values):
            return "\(values.count) item\(values.count == 1 ? "" : "s")"
        case .object(let fields):
            if let name = fields.first(where: { $0.name == "name" })?.value.displayValue,
               !name.isEmpty {
                return name
            }
            if let page = fields.first(where: { $0.name == "totalCount" })?.value.displayValue {
                return "\(page) total"
            }
            return "\(fields.count) field\(fields.count == 1 ? "" : "s")"
        }
    }
}

private extension String {
    var phase2AssistantFactLabel: String {
        split(separator: ".")
            .map { String($0).phase2AssistantFactSegmentLabel }
            .joined(separator: " · ")
    }

    private var phase2AssistantFactSegmentLabel: String {
        if allSatisfy(\.isNumber) {
            return "[\(self)]"
        }
        var label = ""
        for character in self {
            if character.isUppercase, !label.isEmpty {
                label.append(" ")
            }
            label.append(character)
        }
        return label.prefix(1).uppercased() + String(label.dropFirst())
    }
}

struct Phase2AssistantPublicationToken: Equatable {
    let intent: Phase2AssistantIntent
    let focusedImageSlot: ImageSlot
    let selectedImageAddress: ImageAddress?
    let workspace: Phase2ReadWorkspaceIdentity
    let workspaceRevision: UInt64
    let image: Phase2ReadImageIdentity?

    @MainActor
    static func capture(
        intent: Phase2AssistantIntent,
        store: WorkspaceStore
    ) -> Phase2AssistantPublicationToken {
        let focusedSlot = store.focusedImageSlot
        let current = store.phase2ReadLedger.currentState(
            for: focusedSlot,
            snapshot: store.snapshot
        )
        return Phase2AssistantPublicationToken(
            intent: intent,
            focusedImageSlot: focusedSlot,
            selectedImageAddress: store.selectedImageAddress,
            workspace: current.workspace,
            workspaceRevision: current.workspaceRevision,
            image: current.image
        )
    }

    @MainActor
    func isCurrent(in store: WorkspaceStore) -> Bool {
        guard store.focusedImageSlot == focusedImageSlot,
              store.selectedImageAddress == selectedImageAddress
        else { return false }

        let current = store.phase2ReadLedger.currentState(
            for: focusedImageSlot,
            snapshot: store.snapshot
        )
        return current.workspace == workspace
            && current.workspaceRevision == workspaceRevision
            && current.image == image
    }
}

extension Phase2LocalAIProviderReadiness {
    var isReadyForAssistant: Bool {
        if case .ready = self { true } else { false }
    }

    var assistantTitle: String {
        switch self {
        case .ready:
            return "Local model ready"
        case .endpointMissing:
            return "Provider endpoint required"
        case .inventoryRequired:
            return "Model inventory required"
        case .authenticationRequired:
            return "Authentication required"
        case .unavailable:
            return "Provider unavailable"
        case .incompatible:
            return "Provider incompatible"
        case .reconciliationRequired:
            return "Provider reconciliation required"
        case .selectionRequired:
            return "Model selection required"
        case .selectionIdentityMismatch:
            return "Selected model changed"
        case .selectedModelMissing:
            return "Selected model missing"
        case .selectedModelNotLanguage:
            return "Selected model is not a language model"
        case .loadRequired:
            return "Selected model must be loaded"
        }
    }

    var assistantDetail: String {
        switch self {
        case .ready(let configuration):
            return "Ready to run finalization with \(configuration.model)."
        case .endpointMissing:
            return "Configure the local provider endpoint in Settings before using Ask MacScope."
        case .inventoryRequired:
            return "Refresh model inventory so MacScope can verify the selected model."
        case .authenticationRequired:
            return "The provider requires authentication before MacScope can use it."
        case .unavailable:
            return "MacScope cannot currently reach the local provider."
        case .incompatible:
            return "The provider does not expose the required local inference protocol."
        case .reconciliationRequired:
            return "Refresh or reconcile the selected model before running a grounded answer."
        case .selectionRequired:
            return "Select a qualified local language model in Settings."
        case .selectionIdentityMismatch:
            return "The saved model selection no longer matches the provider inventory."
        case .selectedModelMissing:
            return "The selected model is not present in the current provider inventory."
        case .selectedModelNotLanguage:
            return "Choose a local language model for finalization."
        case .loadRequired(let modelKey):
            return "Load \(modelKey) in the provider before running Ask MacScope."
        }
    }
}

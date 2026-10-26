import Foundation

/// Inert provider-authored proposal for a future app-mediated debugger action.
///
/// This model never executes LLDB commands. It binds one requested action to exact debugger
/// runtime coordinates so MacScope can validate, review, and either reject or later convert it
/// into an app/user-owned debugger control operation.
struct Phase2AIDebuggerActionProposal: Hashable, Sendable {
    let proposalID: UUID
    let action: Phase2AIDebuggerAction
    let sessionID: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?
    let requestedAuthority: Phase2DebuggerToolAuthority

    init(
        proposalID: UUID,
        action: Phase2AIDebuggerAction,
        sessionID: UUID,
        lifecycleRevision: UInt64,
        stopRevision: UInt64? = nil,
        eventSequence: UInt64? = nil,
        requestedAuthority: Phase2DebuggerToolAuthority = .controlledRuntimeActions
    ) {
        self.proposalID = proposalID
        self.action = action
        self.sessionID = sessionID
        self.lifecycleRevision = lifecycleRevision
        self.stopRevision = stopRevision
        self.eventSequence = eventSequence
        self.requestedAuthority = requestedAuthority
    }
}

enum Phase2AIDebuggerAction: String, CaseIterable, Hashable, Sendable {
    case continueExecution
    case stepOver
    case stepInto
    case stepOut
    case pause
    case refreshSnapshot

    var title: String {
        switch self {
        case .continueExecution: "Continue"
        case .stepOver: "Step Over"
        case .stepInto: "Step Into"
        case .stepOut: "Step Out"
        case .pause: "Pause"
        case .refreshSnapshot: "Refresh Snapshot"
        }
    }

    var requiresStopCoordinate: Bool {
        switch self {
        case .continueExecution, .stepOver, .stepInto, .stepOut, .refreshSnapshot:
            true
        case .pause:
            false
        }
    }
}

/// App-minted correlation authority for one approved proposal dispatch. The executor must return
/// an accepted debugger event carrying this exact execution ID; a merely newer event is not proof
/// that the proposal caused it.
struct Phase2AIDebuggerProposalExecutionRequest: Equatable, Sendable {
    let executionID: UUID
    let proposalID: UUID
    let action: Phase2AIDebuggerAction
}

struct Phase2AIDebuggerProposalValidationResult: Equatable, Sendable {
    let issues: [Phase2AIDebuggerProposalValidationIssue]

    var isAccepted: Bool { issues.isEmpty }
}

enum Phase2AIDebuggerProposalValidationIssue: String, CaseIterable, Equatable, Sendable {
    case unsupportedAuthority
    case missingLifecycleRevision
    case missingStopCoordinate
    case missingEventSequence

    var displaySummary: String {
        switch self {
        case .unsupportedAuthority:
            "Requested debugger authority is not controlled runtime actions."
        case .missingLifecycleRevision:
            "Debugger lifecycle revision is missing."
        case .missingStopCoordinate:
            "This debugger action requires an exact stopped-process coordinate."
        case .missingEventSequence:
            "Debugger event sequence is missing."
        }
    }
}

enum Phase2AIDebuggerProposalValidator {
    static func validate(
        _ proposal: Phase2AIDebuggerActionProposal
    ) -> Phase2AIDebuggerProposalValidationResult {
        var issues: [Phase2AIDebuggerProposalValidationIssue] = []
        if proposal.requestedAuthority != .controlledRuntimeActions {
            issues.append(.unsupportedAuthority)
        }
        if proposal.lifecycleRevision == 0 {
            issues.append(.missingLifecycleRevision)
        }
        if proposal.action.requiresStopCoordinate && proposal.stopRevision == nil {
            issues.append(.missingStopCoordinate)
        }
        if proposal.eventSequence == nil {
            issues.append(.missingEventSequence)
        }
        return Phase2AIDebuggerProposalValidationResult(issues: issues)
    }
}

enum Phase2AIDebuggerProposalExecutionDisposition: String, Equatable, Sendable {
    case dispatched
    case validationRejected
    case authorizationRejected
    case staleDebuggerCoordinate
    case debuggerUnavailable
    case failed
}

struct Phase2AIDebuggerProposalExecutionResult: Equatable, Sendable, Identifiable {
    let id: UUID
    let proposalID: UUID?
    let action: Phase2AIDebuggerAction?
    let runtimeSessionID: UUID?
    let lifecycleRevision: UInt64?
    let stopRevision: UInt64?
    let eventSequence: UInt64?
    let disposition: Phase2AIDebuggerProposalExecutionDisposition
    let failureMessage: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        proposalID: UUID?,
        action: Phase2AIDebuggerAction?,
        runtimeSessionID: UUID? = nil,
        lifecycleRevision: UInt64? = nil,
        stopRevision: UInt64? = nil,
        eventSequence: UInt64? = nil,
        disposition: Phase2AIDebuggerProposalExecutionDisposition,
        failureMessage: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.proposalID = proposalID
        self.action = action
        self.runtimeSessionID = runtimeSessionID
        self.lifecycleRevision = lifecycleRevision
        self.stopRevision = stopRevision
        self.eventSequence = eventSequence
        self.disposition = disposition
        self.failureMessage = failureMessage
        self.createdAt = createdAt
    }

    static func rejected(
        proposal: Phase2AIDebuggerActionProposal?,
        requestedProposalID: UUID? = nil,
        disposition: Phase2AIDebuggerProposalExecutionDisposition,
        message: String,
        now: Date = Date()
    ) -> Self {
        Self(
            proposalID: proposal?.proposalID ?? requestedProposalID,
            action: proposal?.action,
            disposition: disposition,
            failureMessage: message,
            createdAt: now
        )
    }

    func providerVisibleEvidenceText(maximumUTF8Bytes: Int = 2_048) -> String {
        var lines = [
            "Debugger control execution ID: \(id.uuidString)",
            "Proposal ID: \(proposalID?.uuidString ?? "none")",
            "Action: \(action?.title ?? "unknown")",
            "Disposition: \(disposition.rawValue)",
        ]
        if let runtimeSessionID {
            lines.append("Runtime session ID: \(runtimeSessionID.uuidString)")
        }
        if let lifecycleRevision {
            lines.append("Lifecycle revision: \(lifecycleRevision)")
        }
        if let stopRevision {
            lines.append("Stop revision: \(stopRevision)")
        }
        if let eventSequence {
            lines.append("Event sequence: \(eventSequence)")
        }
        if let failureMessage, !failureMessage.isEmpty {
            lines.append("Failure: \(failureMessage)")
        }
        return Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            lines.joined(separator: "\n"),
            maximumBytes: maximumUTF8Bytes
        )
    }
}

/// Transient app-owned review state for one provider debugger proposal.
struct Phase2AIDebuggerProposalReviewState: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case inactive
        case staged
        case rejected
    }

    enum HumanDecision: Equatable, Sendable {
        case none
        case pendingReview
        case approvedForFutureDebuggerControl
        case rejectedByUser
        case blockedByValidation
    }

    let disposition: Disposition
    let proposal: Phase2AIDebuggerActionProposal?
    let validationResult: Phase2AIDebuggerProposalValidationResult
    let humanDecision: HumanDecision

    var isActive: Bool { disposition != .inactive }
    var isStaged: Bool { disposition == .staged }
    var canApproveForFutureDebuggerControl: Bool {
        isStaged
            && validationResult.isAccepted
            && humanDecision != .approvedForFutureDebuggerControl
            && humanDecision != .rejectedByUser
    }
    var canExecuteDebuggerControl: Bool {
        isStaged
            && validationResult.isAccepted
            && humanDecision == .approvedForFutureDebuggerControl
    }

    var title: String {
        switch (disposition, humanDecision) {
        case (.inactive, _):
            "No debugger proposal"
        case (.staged, .approvedForFutureDebuggerControl):
            "Debugger proposal approved for future control"
        case (.staged, .rejectedByUser):
            "Debugger proposal rejected by user"
        case (.staged, _):
            "Debugger proposal ready for review"
        case (.rejected, .rejectedByUser):
            "Debugger proposal rejected by user"
        case (.rejected, _):
            "Debugger proposal rejected"
        }
    }

    var authoritySummary: String {
        switch disposition {
        case .inactive:
            "none"
        case .staged:
            "exact controlled debugger runtime-action proposal only; no direct model LLDB command execution, breakpoint mutation, memory/register writes, process launch, attach, detach, or terminate authority"
        case .rejected:
            "no authority granted"
        }
    }

    var reviewPlainTextExport: String? {
        guard isActive, let proposal else { return nil }
        var lines = [
            "MacScope AI Debugger Proposal Review",
            "- Disposition: \(disposition.displayName)",
            "- Proposal ID: \(proposal.proposalID.uuidString)",
            "- Action: \(proposal.action.title)",
            "- Session ID: \(proposal.sessionID.uuidString)",
            "- Lifecycle revision: \(proposal.lifecycleRevision)",
            "- Stop revision: \(proposal.stopRevision.map(String.init) ?? "none")",
            "- Event sequence: \(proposal.eventSequence.map(String.init) ?? "none")",
            "- Requested authority: \(proposal.requestedAuthority.rawValue)",
            "- Human decision: \(humanDecision.displayName)",
            "- Authority: \(authoritySummary)",
            "- Can execute: \(canExecuteDebuggerControl ? "yes" : "no")",
        ]
        if !validationResult.issues.isEmpty {
            lines.append("- Validation issues:")
            lines.append(contentsOf: validationResult.issues.map { "  - \($0.displaySummary)" })
        }
        return lines.joined(separator: "\n")
    }

    static let inactive = Self(
        disposition: .inactive,
        proposal: nil,
        validationResult: .init(issues: []),
        humanDecision: .none
    )

    static func review(
        proposal: Phase2AIDebuggerActionProposal
    ) -> Phase2AIDebuggerProposalReviewState {
        let validation = Phase2AIDebuggerProposalValidator.validate(proposal)
        return Self(
            disposition: validation.isAccepted ? .staged : .rejected,
            proposal: proposal,
            validationResult: validation,
            humanDecision: validation.isAccepted ? .pendingReview : .blockedByValidation
        )
    }

    func approvingForFutureDebuggerControl() -> Phase2AIDebuggerProposalReviewState {
        guard canApproveForFutureDebuggerControl else { return self }
        return Self(
            disposition: disposition,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: .approvedForFutureDebuggerControl
        )
    }

    func rejectingByUser() -> Phase2AIDebuggerProposalReviewState {
        guard isActive else { return self }
        return Self(
            disposition: .rejected,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: .rejectedByUser
        )
    }
}

private extension Phase2AIDebuggerProposalReviewState.Disposition {
    var displayName: String {
        switch self {
        case .inactive: "inactive"
        case .staged: "staged"
        case .rejected: "rejected"
        }
    }
}

private extension Phase2AIDebuggerProposalReviewState.HumanDecision {
    var displayName: String {
        switch self {
        case .none: "none"
        case .pendingReview: "pending review"
        case .approvedForFutureDebuggerControl: "approved for future debugger control"
        case .rejectedByUser: "rejected by user"
        case .blockedByValidation: "blocked by validation"
        }
    }
}

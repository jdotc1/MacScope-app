import Foundation

/// R3 Audited AI Shell proposal metadata.
///
/// This model is intentionally inert. It describes an exact command request that the
/// app may later show, approve, stage, deny, or convert into a separate restricted
/// one-shot job or ShellBroker PTY transport request. It never executes a command
/// and never gives the model direct ownership of the human-owned `ShellBroker` PTY
/// surface from R2.
struct Phase2AIShellCommandProposal: Hashable, Sendable {
    let proposalID: UUID
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String?
    let timeoutMilliseconds: Int
    let maximumOutputBytes: Int
    let executionSurface: Phase2AIShellExecutionSurface
    let requestedEffects: Set<Phase2EffectClass>

    init(
        proposalID: UUID,
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryPath: String? = nil,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int,
        executionSurface: Phase2AIShellExecutionSurface = .restrictedOneShotJob,
        requestedEffects: Set<Phase2EffectClass> = [.a5]
    ) {
        self.proposalID = proposalID
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumOutputBytes = maximumOutputBytes
        self.executionSurface = executionSurface
        self.requestedEffects = requestedEffects
    }
}

enum Phase2AIShellExecutionSurface: String, CaseIterable, Equatable, Sendable {
    case restrictedOneShotJob
    case humanPTYSession
    case shellBrokerPTY
    case debuggerConsole
}

struct Phase2AIShellProposalValidationResult: Equatable, Sendable {
    let issues: [Phase2AIShellProposalValidationIssue]

    var isAccepted: Bool { issues.isEmpty }
}

enum Phase2AIShellBrokerPTYExecutionDisposition: String, Equatable, Sendable {
    case dispatched
    case authorizationRejected
    case brokerRejected
}

struct Phase2AIShellBrokerPTYExecutionResult: Equatable, Identifiable, Sendable {
    let id: UUID
    let proposalID: UUID
    let sessionID: UUID?
    let requestID: UUID?
    let disposition: Phase2AIShellBrokerPTYExecutionDisposition
    let commandText: String
    let bytesWritten: Int?
    let failureMessage: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        proposalID: UUID,
        sessionID: UUID?,
        requestID: UUID?,
        disposition: Phase2AIShellBrokerPTYExecutionDisposition,
        commandText: String,
        bytesWritten: Int?,
        failureMessage: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.proposalID = proposalID
        self.sessionID = sessionID
        self.requestID = requestID
        self.disposition = disposition
        self.commandText = commandText
        self.bytesWritten = bytesWritten
        self.failureMessage = failureMessage
        self.createdAt = createdAt
    }

    func providerVisibleEvidenceText(maximumUTF8Bytes: Int = 2_048) -> String {
        var lines = [
            "Execution ID: \(id.uuidString)",
            "Proposal ID: \(proposalID.uuidString)",
            "Execution surface: ShellBroker PTY",
            "Disposition: \(disposition.rawValue)",
            "Command written to PTY: \(commandText)",
        ]
        if let sessionID {
            lines.append("Shell session ID: \(sessionID.uuidString)")
        }
        if let requestID {
            lines.append("Shell request ID: \(requestID.uuidString)")
        }
        if let bytesWritten {
            lines.append("Bytes accepted by ShellBroker: \(bytesWritten)")
        }
        if let failureMessage, !failureMessage.isEmpty {
            let boundedFailure = Phase2AIShellOneShotExecutionResult.truncatedUTF8(
                failureMessage,
                maximumBytes: maximumUTF8Bytes
            )
            lines.append("Failure: \(boundedFailure)")
        }
        lines.append(
            "Execution note: command bytes were app-reviewed and written into an existing ShellBroker PTY; this is not a standalone process result and carries no direct model PTY ownership."
        )
        return Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            lines.joined(separator: "\n"),
            maximumBytes: maximumUTF8Bytes
        )
    }
}

/// App-owned presentation/review state for one R3 shell proposal.
///
/// This is intentionally a transient projection rather than persistence or execution authority.
/// Staging a proposal makes the exact argv/env/limits reviewable by the app; it does not run,
/// approve, enqueue, or forward the proposal to the human PTY, ShellBroker, or debugger console.
struct Phase2AIShellProposalReviewState: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case inactive
        case staged
        case rejected
    }

    enum HumanDecision: Equatable, Sendable {
        case none
        case pendingReview
        case approvedForFutureOneShot
        case approvedForFutureShellBrokerPTY
        case executingOneShot
        case executingShellBrokerPTY
        case consumed
        case rejectedByUser
        case blockedByValidation
    }

    let disposition: Disposition
    let proposal: Phase2AIShellCommandProposal?
    let validationResult: Phase2AIShellProposalValidationResult
    let humanDecision: HumanDecision

    var isActive: Bool { disposition != .inactive }
    var isStaged: Bool { disposition == .staged }
    var canDismiss: Bool { isActive }
    var canCopyArgv: Bool { isStaged }
    var canCopyReview: Bool { isActive }
    var canCopyReviewJSON: Bool { isActive }
    var canApproveForFutureOneShot: Bool {
        isStaged && validationResult.isAccepted && canGrantFreshApproval
            && proposal?.executionSurface == .restrictedOneShotJob
            && humanDecision != .rejectedByUser
    }
    var canApproveForFutureShellBrokerPTY: Bool {
        isStaged && validationResult.isAccepted && canGrantFreshApproval
            && proposal?.executionSurface == .shellBrokerPTY
            && humanDecision != .rejectedByUser
    }
    var canRejectByUser: Bool {
        isActive && humanDecision != .rejectedByUser
            && humanDecision != .executingOneShot
            && humanDecision != .executingShellBrokerPTY
            && humanDecision != .consumed
    }
    var canExecute: Bool {
        isStaged
            && validationResult.isAccepted
            && humanDecision == .approvedForFutureOneShot
            && proposal?.executionSurface == .restrictedOneShotJob
    }
    var canExecuteShellBrokerPTY: Bool {
        isStaged
            && validationResult.isAccepted
            && humanDecision == .approvedForFutureShellBrokerPTY
            && proposal?.executionSurface == .shellBrokerPTY
    }

    var title: String {
        switch (disposition, humanDecision) {
        case (.inactive, _):
            "No shell proposal"
        case (.staged, .approvedForFutureOneShot):
            "Shell proposal approved for future one-shot review"
        case (.staged, .approvedForFutureShellBrokerPTY):
            "Shell proposal approved for future ShellBroker PTY transport"
        case (.staged, .executingOneShot):
            "Executing approved one-shot shell proposal"
        case (.staged, .executingShellBrokerPTY):
            "Dispatching approved ShellBroker PTY proposal"
        case (.staged, .consumed):
            "Shell proposal approval consumed"
        case (.staged, .rejectedByUser):
            "Shell proposal rejected by user"
        case (.staged, _):
            "Shell proposal ready for review"
        case (.rejected, .rejectedByUser):
            "Shell proposal rejected by user"
        case (.rejected, _):
            "Shell proposal rejected"
        }
    }

    var detail: String {
        switch (disposition, humanDecision) {
        case (.inactive, _):
            "No AI shell proposal is staged."
        case (.staged, .approvedForFutureOneShot):
            "Human review accepted this exact command for restricted one-shot execution. It will run as a separate app-owned process, not in the human PTY."
        case (.staged, .approvedForFutureShellBrokerPTY):
            "Human review accepted this exact command for future app-mediated ShellBroker PTY transport. It is not executed until the PTY transport executor authorizes and writes it."
        case (.staged, .executingOneShot), (.staged, .executingShellBrokerPTY):
            "The exact approved command is executing. Its one-use approval has already been consumed for dispatch."
        case (.staged, .consumed):
            "The prior one-use approval was consumed. Explicit fresh approval is required before retrying this command."
        case (.staged, .rejectedByUser):
            "Human review rejected this proposal. It remains inert and cannot execute."
        case (.staged, _):
            switch proposal?.executionSurface {
            case .shellBrokerPTY:
                "Validated as an app-mediated ShellBroker PTY transport proposal. Explicit human approval is required before any PTY write."
            default:
                "Validated as a restricted one-shot process proposal. Explicit human approval is required before execution."
            }
        case (.rejected, .rejectedByUser):
            "Human review confirmed rejection. The proposal remains inert and has no granted authority."
        case (.rejected, _):
            "Rejected before staging because the proposal requested unsupported command shape or authority."
        }
    }

    var authoritySummary: String {
        switch disposition {
        case .inactive:
            "none"
        case .staged:
            switch proposal?.executionSurface {
            case .shellBrokerPTY:
                "exact .a5 app-mediated ShellBroker PTY transport request only; no direct model PTY ownership, human PTY ownership, debugger, network, credential, or mutation authority"
            default:
                "exact .a5 restricted one-shot process only; no ShellBroker PTY, human PTY, debugger, network, credential, or mutation authority"
            }
        case .rejected:
            "no authority granted"
        }
    }

    var argvPreview: String? {
        guard let proposal else { return nil }
        return ([proposal.executablePath] + proposal.arguments)
            .map(Self.displayQuoted)
            .joined(separator: " ")
    }

    var environmentPreview: [String] {
        guard let proposal else { return [] }
        return proposal.environment
            .sorted { $0.key < $1.key }
            .map { "\(Self.displayQuoted($0.key))=\(Self.displayQuoted($0.value))" }
    }

    var workingDirectoryPreview: String? {
        guard let workingDirectoryPath = proposal?.workingDirectoryPath else { return nil }
        return Self.displayQuoted(workingDirectoryPath)
    }

    var limitsPreview: String? {
        guard let proposal else { return nil }
        return "timeout \(proposal.timeoutMilliseconds) ms · output \(proposal.maximumOutputBytes) bytes"
    }

    var issueSummaries: [String] {
        validationResult.issues.map(\.displaySummary)
    }

    var humanDecisionSummary: String {
        humanDecision.displayName
    }

    var dispositionSummary: String {
        disposition.displayName
    }

    var rejectedIssueCount: Int {
        validationResult.issues.count
    }

    var reviewPlainTextExport: String? {
        guard isActive, let proposal else { return nil }
        var lines = [
            "MacScope AI Shell Proposal Review",
            "- Disposition: \(disposition.displayName)",
            "- Proposal ID: \(proposal.proposalID.uuidString)",
            "- Command: \(argvPreview ?? Self.displayQuoted(proposal.executablePath))",
            "- Working directory: \(workingDirectoryPreview ?? "none")",
            "- Limits: \(limitsPreview ?? "none")",
            "- Execution surface: \(proposal.executionSurface.rawValue)",
            "- Requested effects: \(proposal.requestedEffects.map(\.rawValue).sorted().joined(separator: ", "))",
            "- Human decision: \(humanDecisionSummary)",
            "- Authority: \(authoritySummary)",
            "- Can execute: \(canExecute ? "yes" : "no")",
            "- Can execute ShellBroker PTY: \(canExecuteShellBrokerPTY ? "yes" : "no")"
        ]
        if environmentPreview.isEmpty {
            lines.append("- Environment: none")
        } else {
            lines.append("- Environment:")
            lines.append(contentsOf: environmentPreview.map { "  - \($0)" })
        }
        if issueSummaries.isEmpty {
            lines.append("- Validation issues: none")
        } else {
            lines.append("- Validation issues:")
            lines.append(contentsOf: issueSummaries.map { "  - \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    var reviewJSONExport: String? {
        guard isActive, let proposal else { return nil }
        let payload = ReviewJSONPayload(
            authority: authoritySummary,
            canExecute: canExecute,
            canExecuteShellBrokerPTY: canExecuteShellBrokerPTY,
            command: [proposal.executablePath] + proposal.arguments,
            disposition: disposition.displayName,
            environment: proposal.environment
                .sorted { $0.key < $1.key }
                .map { ReviewEnvironmentEntry(key: $0.key, value: $0.value) },
            executionSurface: proposal.executionSurface.rawValue,
            humanDecision: humanDecisionSummary,
            limits: ReviewLimits(
                maximumOutputBytes: proposal.maximumOutputBytes,
                timeoutMilliseconds: proposal.timeoutMilliseconds
            ),
            proposalID: proposal.proposalID.uuidString,
            requestedEffects: proposal.requestedEffects.map(\.rawValue).sorted(),
            validationIssues: issueSummaries,
            workingDirectoryPath: proposal.workingDirectoryPath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let inactive = Phase2AIShellProposalReviewState(
        disposition: .inactive,
        proposal: nil,
        validationResult: Phase2AIShellProposalValidationResult(issues: []),
        humanDecision: .none
    )

    static func review(proposal: Phase2AIShellCommandProposal) -> Phase2AIShellProposalReviewState {
        let validationResult = Phase2AIShellProposalValidator.validate(proposal)
        return Phase2AIShellProposalReviewState(
            disposition: validationResult.isAccepted ? .staged : .rejected,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: validationResult.isAccepted ? .pendingReview : .blockedByValidation
        )
    }

    func approvingForFutureOneShot() -> Phase2AIShellProposalReviewState {
        guard canApproveForFutureOneShot else { return self }
        return Phase2AIShellProposalReviewState(
            disposition: disposition,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: .approvedForFutureOneShot
        )
    }

    func approvingForFutureShellBrokerPTY() -> Phase2AIShellProposalReviewState {
        guard canApproveForFutureShellBrokerPTY else { return self }
        return Phase2AIShellProposalReviewState(
            disposition: disposition,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: .approvedForFutureShellBrokerPTY
        )
    }

    func rejectingByUser() -> Phase2AIShellProposalReviewState {
        guard canRejectByUser else { return self }
        return Phase2AIShellProposalReviewState(
            disposition: disposition,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: .rejectedByUser
        )
    }

    func beginningOneShotExecution() -> Phase2AIShellProposalReviewState? {
        guard canExecute else { return nil }
        return replacingHumanDecision(with: .executingOneShot)
    }

    func beginningShellBrokerPTYExecution() -> Phase2AIShellProposalReviewState? {
        guard canExecuteShellBrokerPTY else { return nil }
        return replacingHumanDecision(with: .executingShellBrokerPTY)
    }

    func consumingExecutionApproval() -> Phase2AIShellProposalReviewState {
        guard humanDecision == .executingOneShot || humanDecision == .executingShellBrokerPTY else {
            return self
        }
        return replacingHumanDecision(with: .consumed)
    }

    private var canGrantFreshApproval: Bool {
        humanDecision == .pendingReview || humanDecision == .consumed
    }

    private func replacingHumanDecision(
        with humanDecision: HumanDecision
    ) -> Phase2AIShellProposalReviewState {
        Phase2AIShellProposalReviewState(
            disposition: disposition,
            proposal: proposal,
            validationResult: validationResult,
            humanDecision: humanDecision
        )
    }

    private static func displayQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private struct ReviewJSONPayload: Encodable {
        let authority: String
        let canExecute: Bool
        let canExecuteShellBrokerPTY: Bool
        let command: [String]
        let disposition: String
        let environment: [ReviewEnvironmentEntry]
        let executionSurface: String
        let humanDecision: String
        let limits: ReviewLimits
        let proposalID: String
        let requestedEffects: [String]
        let validationIssues: [String]
        let workingDirectoryPath: String?
    }

    private struct ReviewEnvironmentEntry: Encodable {
        let key: String
        let value: String
    }

    private struct ReviewLimits: Encodable {
        let maximumOutputBytes: Int
        let timeoutMilliseconds: Int
    }
}

private extension Phase2AIShellProposalReviewState.HumanDecision {
    var displayName: String {
        switch self {
        case .none:
            "none"
        case .pendingReview:
            "pending review"
        case .approvedForFutureOneShot:
            "approved for future restricted one-shot"
        case .approvedForFutureShellBrokerPTY:
            "approved for future ShellBroker PTY transport"
        case .executingOneShot:
            "executing restricted one-shot"
        case .executingShellBrokerPTY:
            "dispatching through ShellBroker PTY"
        case .consumed:
            "approval consumed"
        case .rejectedByUser:
            "rejected by user"
        case .blockedByValidation:
            "blocked by validation"
        }
    }
}

private extension Phase2AIShellProposalReviewState.Disposition {
    var displayName: String {
        switch self {
        case .inactive:
            "inactive"
        case .staged:
            "staged"
        case .rejected:
            "rejected"
        }
    }
}

enum Phase2AIShellProposalValidationIssue: Equatable, Sendable {
    case proposalIDNil
    case executablePathEmpty
    case executablePathNotAbsolute(String)
    case executablePathContainsNUL
    case tooManyArguments(count: Int, maximum: Int)
    case argumentContainsNUL(index: Int)
    case tooManyEnvironmentEntries(count: Int, maximum: Int)
    case environmentKeyEmpty
    case environmentKeyContainsInvalidCharacter(String)
    case environmentValueContainsNUL(key: String)
    case workingDirectoryNotAbsolute(String)
    case workingDirectoryContainsNUL
    case invalidTimeout(milliseconds: Int)
    case invalidOutputLimit(bytes: Int)
    case unsupportedExecutionSurface(Phase2AIShellExecutionSurface)
    case missingProcessAuthority
    case disallowedAuthority(Phase2EffectClass)

    var displaySummary: String {
        switch self {
        case .proposalIDNil:
            return "Proposal ID is the nil UUID."
        case .executablePathEmpty:
            return "Executable path is empty."
        case .executablePathNotAbsolute(let path):
            return "Executable path is not absolute: \(path)"
        case .executablePathContainsNUL:
            return "Executable path contains a NUL byte."
        case .tooManyArguments(let count, let maximum):
            return "Argument count \(count) exceeds maximum \(maximum)."
        case .argumentContainsNUL(let index):
            return "Argument \(index) contains a NUL byte."
        case .tooManyEnvironmentEntries(let count, let maximum):
            return "Environment entry count \(count) exceeds maximum \(maximum)."
        case .environmentKeyEmpty:
            return "Environment contains an empty key."
        case .environmentKeyContainsInvalidCharacter(let key):
            return "Environment key contains an invalid character: \(key)"
        case .environmentValueContainsNUL(let key):
            return "Environment value for \(key) contains a NUL byte."
        case .workingDirectoryNotAbsolute(let path):
            return "Working directory is not absolute: \(path)"
        case .workingDirectoryContainsNUL:
            return "Working directory contains a NUL byte."
        case .invalidTimeout(let milliseconds):
            return "Timeout \(milliseconds) ms is outside the accepted range."
        case .invalidOutputLimit(let bytes):
            return "Output limit \(bytes) bytes is outside the accepted range."
        case .unsupportedExecutionSurface(let surface):
            return "Execution surface \(surface.rawValue) is not accepted for AI shell proposals."
        case .missingProcessAuthority:
            return "Proposal does not declare exact process authority."
        case .disallowedAuthority(let effect):
            return "Effect \(effect.rawValue) is not allowed for AI shell proposals."
        }
    }
}

enum Phase2AIShellProposalValidator {
    static let maximumArguments = 64
    static let maximumEnvironmentEntries = 64
    static let maximumTimeoutMilliseconds = 120_000
    static let maximumOutputBytes = 1_048_576

    static func validate(
        _ proposal: Phase2AIShellCommandProposal
    ) -> Phase2AIShellProposalValidationResult {
        var issues: [Phase2AIShellProposalValidationIssue] = []

        if proposal.proposalID == UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
            issues.append(.proposalIDNil)
        }

        if proposal.executablePath.isEmpty {
            issues.append(.executablePathEmpty)
        } else {
            if !proposal.executablePath.hasPrefix("/") {
                issues.append(.executablePathNotAbsolute(proposal.executablePath))
            }
            if proposal.executablePath.containsNUL {
                issues.append(.executablePathContainsNUL)
            }
        }

        if proposal.arguments.count > maximumArguments {
            issues.append(.tooManyArguments(
                count: proposal.arguments.count,
                maximum: maximumArguments
            ))
        }
        for (index, argument) in proposal.arguments.enumerated() where argument.containsNUL {
            issues.append(.argumentContainsNUL(index: index))
        }

        if proposal.environment.count > maximumEnvironmentEntries {
            issues.append(.tooManyEnvironmentEntries(
                count: proposal.environment.count,
                maximum: maximumEnvironmentEntries
            ))
        }
        for key in proposal.environment.keys.sorted() {
            guard let value = proposal.environment[key] else { continue }
            if key.isEmpty {
                issues.append(.environmentKeyEmpty)
            }
            if key.contains("=") || key.containsNUL {
                issues.append(.environmentKeyContainsInvalidCharacter(key))
            }
            if value.containsNUL {
                issues.append(.environmentValueContainsNUL(key: key))
            }
        }

        if let workingDirectoryPath = proposal.workingDirectoryPath {
            if !workingDirectoryPath.hasPrefix("/") {
                issues.append(.workingDirectoryNotAbsolute(workingDirectoryPath))
            }
            if workingDirectoryPath.containsNUL {
                issues.append(.workingDirectoryContainsNUL)
            }
        }

        if !(1...maximumTimeoutMilliseconds).contains(proposal.timeoutMilliseconds) {
            issues.append(.invalidTimeout(milliseconds: proposal.timeoutMilliseconds))
        }
        if !(1...maximumOutputBytes).contains(proposal.maximumOutputBytes) {
            issues.append(.invalidOutputLimit(bytes: proposal.maximumOutputBytes))
        }

        let supportedExecutionSurfaces: Set<Phase2AIShellExecutionSurface> = [
            .restrictedOneShotJob,
            .shellBrokerPTY,
        ]
        if !supportedExecutionSurfaces.contains(proposal.executionSurface) {
            issues.append(.unsupportedExecutionSurface(proposal.executionSurface))
        }

        if !proposal.requestedEffects.contains(.a5) {
            issues.append(.missingProcessAuthority)
        }
        let permittedEffects: Set<Phase2EffectClass> = [.a5]
        for effect in proposal.requestedEffects where !permittedEffects.contains(effect) {
            issues.append(.disallowedAuthority(effect))
        }

        return Phase2AIShellProposalValidationResult(issues: issues)
    }
}

private extension String {
    var containsNUL: Bool {
        unicodeScalars.contains { $0.value == 0 }
    }
}

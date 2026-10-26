import Foundation

/// Pure R2 broker contract for a future human-owned terminal.
///
/// This file intentionally does not allocate a PTY, spawn a process, talk to XPC,
/// or expose terminal authority to the AI worker. It freezes the app-side command
/// and event shapes that later process code must satisfy.
struct Phase2HumanPTYLaunchPlan: Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String?
    let initialSize: Phase2HumanPTYTerminalSize
    let transcriptLimits: Phase2HumanPTYTranscriptLimits

    init(
        sessionID: UUID,
        requestID: UUID,
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryPath: String? = nil,
        initialSize: Phase2HumanPTYTerminalSize,
        transcriptLimits: Phase2HumanPTYTranscriptLimits = .productionMaximum
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
        self.initialSize = initialSize
        self.transcriptLimits = transcriptLimits
    }
}

struct Phase2HumanPTYTerminalSize: Equatable, Sendable {
    let columns: Int
    let rows: Int

    static let defaultInteractive = Self(columns: 120, rows: 32)

    var isValid: Bool {
        (1...1_000).contains(columns) && (1...1_000).contains(rows)
    }
}

enum Phase2HumanPTYCommandAuthority: String, CaseIterable, Equatable, Sendable {
    case human
    case app
}

struct Phase2HumanPTYBrokerCommand: Equatable, Sendable {
    let commandID: UUID
    let sessionID: UUID
    let authority: Phase2HumanPTYCommandAuthority
    let payload: Phase2HumanPTYBrokerCommandPayload

    init(
        commandID: UUID,
        sessionID: UUID,
        authority: Phase2HumanPTYCommandAuthority,
        payload: Phase2HumanPTYBrokerCommandPayload
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.authority = authority
        self.payload = payload
    }
}

enum Phase2HumanPTYBrokerCommandPayload: Equatable, Sendable {
    case launch(Phase2HumanPTYLaunchPlan)
    case writeInput([UInt8])
    case resize(Phase2HumanPTYTerminalSize)
    case signal(Phase2HumanPTYSignal)
    case reconnect(reconnectID: UUID)
    case cancel

    var kind: Phase2HumanPTYBrokerCommandPayloadKind {
        switch self {
        case .launch:
            .launch
        case .writeInput:
            .writeInput
        case .resize:
            .resize
        case .signal:
            .signal
        case .reconnect:
            .reconnect
        case .cancel:
            .cancel
        }
    }
}

enum Phase2HumanPTYBrokerCommandPayloadKind: String, Equatable, Sendable {
    case launch
    case writeInput
    case resize
    case signal
    case reconnect
    case cancel
}

struct Phase2HumanPTYBrokerEvent: Equatable, Sendable {
    let sessionID: UUID
    let eventID: UUID
    let payload: Phase2HumanPTYBrokerEventPayload
}

enum Phase2HumanPTYBrokerEventPayload: Equatable, Sendable {
    case prepared(requestID: UUID)
    case launchRejected(requestID: UUID, reason: String)
    case running(processIdentifier: Int32)
    case transcript(Phase2HumanPTYTranscriptEvent)
    case brokerTerminated(Phase2HumanPTYTerminalOutcome)
}

struct Phase2HumanPTYLaunchPlanValidationResult: Equatable, Sendable {
    let issues: [Phase2HumanPTYLaunchPlanValidationIssue]

    var isAccepted: Bool { issues.isEmpty }
}

enum Phase2HumanPTYLaunchPlanValidationIssue: Equatable, Sendable {
    case executablePathEmpty
    case executablePathNotAbsolute(String)
    case executablePathContainsNUL
    case argumentContainsNUL(index: Int)
    case environmentKeyEmpty
    case environmentKeyContainsInvalidCharacter(String)
    case environmentValueContainsNUL(key: String)
    case workingDirectoryNotAbsolute(String)
    case workingDirectoryContainsNUL
    case invalidInitialTerminalSize(Phase2HumanPTYTerminalSize)
    case invalidTranscriptLimits
}

enum Phase2HumanPTYLaunchPlanValidator {
    static func validate(_ plan: Phase2HumanPTYLaunchPlan) -> Phase2HumanPTYLaunchPlanValidationResult {
        var issues: [Phase2HumanPTYLaunchPlanValidationIssue] = []

        if plan.executablePath.isEmpty {
            issues.append(.executablePathEmpty)
        } else {
            if !plan.executablePath.hasPrefix("/") {
                issues.append(.executablePathNotAbsolute(plan.executablePath))
            }
            if plan.executablePath.containsNUL {
                issues.append(.executablePathContainsNUL)
            }
        }

        for (index, argument) in plan.arguments.enumerated() where argument.containsNUL {
            issues.append(.argumentContainsNUL(index: index))
        }

        for key in plan.environment.keys.sorted() {
            guard let value = plan.environment[key] else { continue }
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

        if let workingDirectoryPath = plan.workingDirectoryPath {
            if !workingDirectoryPath.hasPrefix("/") {
                issues.append(.workingDirectoryNotAbsolute(workingDirectoryPath))
            }
            if workingDirectoryPath.containsNUL {
                issues.append(.workingDirectoryContainsNUL)
            }
        }

        if !plan.initialSize.isValid {
            issues.append(.invalidInitialTerminalSize(plan.initialSize))
        }

        if !plan.transcriptLimits.isValid {
            issues.append(.invalidTranscriptLimits)
        }

        return Phase2HumanPTYLaunchPlanValidationResult(issues: issues)
    }
}

struct Phase2HumanPTYBrokerCommandValidationResult: Equatable, Sendable {
    let issues: [Phase2HumanPTYBrokerCommandValidationIssue]

    var isAccepted: Bool { issues.isEmpty }
}

enum Phase2HumanPTYBrokerCommandValidationIssue: Equatable, Sendable {
    case sessionMismatch(expected: UUID, actual: UUID)
    case disallowedAuthority(
        authority: Phase2HumanPTYCommandAuthority,
        payload: Phase2HumanPTYBrokerCommandPayloadKind
    )
    case invalidLaunchPlan([Phase2HumanPTYLaunchPlanValidationIssue])
    case invalidInput
    case invalidResize(Phase2HumanPTYTerminalSize)
}

enum Phase2HumanPTYBrokerCommandValidator {
    static func validate(
        _ command: Phase2HumanPTYBrokerCommand,
        expectedSessionID: UUID
    ) -> Phase2HumanPTYBrokerCommandValidationResult {
        var issues: [Phase2HumanPTYBrokerCommandValidationIssue] = []

        if command.sessionID != expectedSessionID {
            issues.append(.sessionMismatch(expected: expectedSessionID, actual: command.sessionID))
        }

        if !isAuthorityAllowed(command.authority, for: command.payload) {
            issues.append(.disallowedAuthority(
                authority: command.authority,
                payload: command.payload.kind
            ))
        }

        switch command.payload {
        case .launch(let plan):
            if plan.sessionID != command.sessionID {
                issues.append(.sessionMismatch(expected: command.sessionID, actual: plan.sessionID))
            }
            let launchResult = Phase2HumanPTYLaunchPlanValidator.validate(plan)
            if !launchResult.isAccepted {
                issues.append(.invalidLaunchPlan(launchResult.issues))
            }
        case .writeInput(let bytes):
            if bytes.isEmpty {
                issues.append(.invalidInput)
            }
        case .resize(let size):
            if !size.isValid {
                issues.append(.invalidResize(size))
            }
        case .signal, .reconnect, .cancel:
            break
        }

        return Phase2HumanPTYBrokerCommandValidationResult(issues: issues)
    }

    private static func isAuthorityAllowed(
        _ authority: Phase2HumanPTYCommandAuthority,
        for payload: Phase2HumanPTYBrokerCommandPayload
    ) -> Bool {
        switch payload {
        case .launch, .writeInput, .resize, .signal:
            authority == .human
        case .reconnect:
            authority == .app
        case .cancel:
            authority == .human || authority == .app
        }
    }
}

private extension String {
    var containsNUL: Bool {
        contains("\u{0}")
    }
}

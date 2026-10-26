import Foundation

struct Phase2ShellLaunchDraft: Equatable, Sendable {
    var executablePathText: String
    var argumentsText: String
    var environmentText: String
    var workingDirectoryPathText: String

    init(
        executablePathText: String = "/bin/zsh",
        argumentsText: String = "",
        environmentText: String = "",
        workingDirectoryPathText: String = ""
    ) {
        self.executablePathText = executablePathText
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.workingDirectoryPathText = workingDirectoryPathText
    }

    init(restoredLaunchPlan plan: Phase2HumanPTYLaunchPlan) {
        executablePathText = plan.executablePath
        argumentsText = Self.argumentsText(from: plan.arguments)
        environmentText = Self.environmentText(from: plan.environment)
        workingDirectoryPathText = plan.workingDirectoryPath ?? ""
    }

    var normalizedExecutablePath: String? {
        Self.normalizedExecutablePath(from: executablePathText)
    }

    var normalizedArguments: [String]? {
        Self.normalizedArguments(from: argumentsText)
    }

    var normalizedEnvironment: [String: String]? {
        Self.normalizedEnvironment(from: environmentText)
    }

    var normalizedWorkingDirectoryPath: String? {
        Self.normalizedWorkingDirectoryPath(from: workingDirectoryPathText)
    }

    var launchConfigurationValidationMessage: String? {
        if let message = Self.validateExecutablePath(executablePathText) {
            return message
        }
        if let message = Self.validateArguments(argumentsText) {
            return message
        }
        if let message = Self.validateEnvironment(environmentText) {
            return message
        }
        return workingDirectoryValidationMessage
    }

    var workingDirectoryValidationMessage: String? {
        Self.validateWorkingDirectoryPath(workingDirectoryPathText)
    }

    static func normalizedExecutablePath(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedArguments(from text: String) -> [String]? {
        switch parseShellWords(text) {
        case .success(let words):
            return words
        case .failure:
            return nil
        }
    }

    static func argumentsText(from arguments: [String]) -> String {
        arguments.map(shellEscapedWord).joined(separator: " ")
    }

    static func environmentText(from environment: [String: String]) -> String {
        environment.keys.sorted().compactMap { key in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(environmentEscapedValue(value))"
        }
        .joined(separator: "\n")
    }

    static func normalizedEnvironment(from text: String) -> [String: String]? {
        switch parseEnvironmentEntries(text) {
        case .success(let environment):
            return environment
        case .failure:
            return nil
        }
    }

    static func normalizedWorkingDirectoryPath(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validateExecutablePath(_ text: String) -> String? {
        guard let path = normalizedExecutablePath(from: text) else {
            return "Executable path is required."
        }
        if path.unicodeScalars.contains(where: { $0.value == 0 }) {
            return "Executable path contains a NUL byte."
        }
        if !path.hasPrefix("/") {
            return "Executable path must be absolute."
        }
        return nil
    }

    static func validateArguments(_ text: String) -> String? {
        switch parseShellWords(text) {
        case .success(let arguments):
            if let index = arguments.firstIndex(where: { $0.unicodeScalars.contains(where: { $0.value == 0 }) }) {
                return "Argument \(index) contains a NUL byte."
            }
            return nil
        case .failure(let error):
            return error.message
        }
    }

    static func validateEnvironment(_ text: String) -> String? {
        switch parseEnvironmentEntries(text) {
        case .success:
            return nil
        case .failure(let error):
            return error.message
        }
    }

    static func validateWorkingDirectoryPath(_ text: String) -> String? {
        guard let path = normalizedWorkingDirectoryPath(from: text) else { return nil }

        if path.unicodeScalars.contains(where: { $0.value == 0 }) {
            return "Working directory contains a NUL byte."
        }
        if !path.hasPrefix("/") {
            return "Working directory must be an absolute path."
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "Working directory does not exist."
        }
        guard isDirectory.boolValue else {
            return "Working directory is not a directory."
        }

        return nil
    }

    func launchSummaryClipboardText(
        terminalSize: Phase2HumanPTYTerminalSize
    ) -> String? {
        guard launchConfigurationValidationMessage == nil,
              let executablePath = normalizedExecutablePath,
              let arguments = normalizedArguments,
              let environment = normalizedEnvironment
        else { return nil }

        var lines = [
            "Shell Launch",
            "Executable: \(executablePath)",
            "Arguments: \(arguments.isEmpty ? "(none)" : Self.argumentsText(from: arguments))",
            "Working directory: \(normalizedWorkingDirectoryPath ?? "ShellBroker default")",
            "Terminal size: \(terminalSize.columns)×\(terminalSize.rows)",
        ]

        if environment.isEmpty {
            lines.append("Environment: (empty)")
        } else {
            lines.append("Environment:")
            lines.append(contentsOf: environment.keys.sorted().compactMap { key in
                guard let value = environment[key] else { return nil }
                return "  \(key)=\(Self.environmentEscapedValue(value))"
            })
        }

        return lines.joined(separator: "\n")
    }

    private static func parseShellWords(_ text: String) -> Result<[String], Phase2ShellLaunchDraftParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success([]) }

        var words: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        var didStartWord = false

        for character in trimmed {
            if isEscaping {
                current.append(character)
                isEscaping = false
                didStartWord = true
                continue
            }

            if character == "\\" {
                isEscaping = true
                didStartWord = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                didStartWord = true
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                didStartWord = true
                continue
            }

            if character.isWhitespace {
                if didStartWord {
                    words.append(current)
                    current = ""
                    didStartWord = false
                }
                continue
            }

            current.append(character)
            didStartWord = true
        }

        if isEscaping {
            return .failure(.danglingEscape)
        }
        if quote != nil {
            return .failure(.unterminatedQuote)
        }
        if didStartWord {
            words.append(current)
        }
        return .success(words)
    }

    private static func parseEnvironmentEntries(
        _ text: String
    ) -> Result<[String: String], Phase2ShellLaunchDraftParseError> {
        let entries = parseEnvironmentEntryTexts(text)
        guard !entries.isEmpty else { return .success([:]) }

        var environment: [String: String] = [:]
        for entry in entries {
            guard let equalsIndex = entry.firstIndex(of: "=") else {
                return .failure(.malformedEnvironmentEntry(entry))
            }
            let key = String(entry[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = entry.index(after: equalsIndex)
            let value = String(entry[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else {
                return .failure(.emptyEnvironmentKey)
            }
            guard key.allSatisfy({ $0 != "=" && !$0.isWhitespace }) else {
                return .failure(.invalidEnvironmentKey(key))
            }
            guard !key.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return .failure(.invalidEnvironmentKey(key))
            }
            guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return .failure(.environmentValueContainsNUL(key))
            }
            guard environment[key] == nil else {
                return .failure(.duplicateEnvironmentKey(key))
            }
            environment[key] = value
        }

        return .success(environment)
    }

    private static func parseEnvironmentEntryTexts(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var entries: [String] = []
        var current = ""
        var isEscaping = false

        for character in trimmed {
            if isEscaping {
                switch character {
                case "n":
                    current.append("\n")
                case ";", "\n", "\\":
                    current.append(character)
                default:
                    current.append("\\")
                    current.append(character)
                }
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == ";" || character == "\n" {
                let entry = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !entry.isEmpty {
                    entries.append(entry)
                }
                current = ""
                continue
            }

            current.append(character)
        }

        if isEscaping {
            current.append("\\")
        }

        let entry = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entry.isEmpty {
            entries.append(entry)
        }
        return entries
    }

    private static func shellEscapedWord(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        let safeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if word.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
            return word
        }
        return "'\(word.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func environmentEscapedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    static func invalidLaunchPlanMessage(
        for issues: [Phase2HumanPTYLaunchPlanValidationIssue]
    ) -> String {
        let details = issues.map(issueDescription).joined(separator: "; ")
        return "Invalid Phase 2 shell launch plan: \(details)"
    }

    private static func issueDescription(_ issue: Phase2HumanPTYLaunchPlanValidationIssue) -> String {
        switch issue {
        case .executablePathEmpty:
            return "executable path is empty"
        case .executablePathNotAbsolute(let path):
            return "executable path must be absolute (\(path))"
        case .executablePathContainsNUL:
            return "executable path contains a NUL byte"
        case .argumentContainsNUL(let index):
            return "argument \(index) contains a NUL byte"
        case .environmentKeyEmpty:
            return "environment key is empty"
        case .environmentKeyContainsInvalidCharacter(let key):
            return "environment key contains an invalid character (\(key))"
        case .environmentValueContainsNUL(let key):
            return "environment value for \(key) contains a NUL byte"
        case .workingDirectoryNotAbsolute(let path):
            return "working directory must be absolute (\(path))"
        case .workingDirectoryContainsNUL:
            return "working directory contains a NUL byte"
        case .invalidInitialTerminalSize(let size):
            return "terminal size is invalid (\(size.columns)×\(size.rows))"
        case .invalidTranscriptLimits:
            return "transcript limits are invalid"
        }
    }
}

private enum Phase2ShellLaunchDraftParseError: Error, Equatable {
    case danglingEscape
    case unterminatedQuote
    case malformedEnvironmentEntry(String)
    case emptyEnvironmentKey
    case invalidEnvironmentKey(String)
    case environmentValueContainsNUL(String)
    case duplicateEnvironmentKey(String)

    var message: String {
        switch self {
        case .danglingEscape:
            return "Arguments end with an unfinished escape."
        case .unterminatedQuote:
            return "Arguments contain an unterminated quote."
        case .malformedEnvironmentEntry(let entry):
            return "Environment entry must be KEY=value (\(entry))."
        case .emptyEnvironmentKey:
            return "Environment key is empty."
        case .invalidEnvironmentKey(let key):
            return "Environment key contains an invalid character (\(key))."
        case .environmentValueContainsNUL(let key):
            return "Environment value for \(key) contains a NUL byte."
        case .duplicateEnvironmentKey(let key):
            return "Environment key is duplicated (\(key))."
        }
    }
}

import Foundation

enum DebuggerPublishedDiagnosticText {
    static let maximumUTF8Bytes = 1_024
    static let truncationMarker = "… [truncated]"

    struct Value: Equatable {
        let text: String
        let isTruncated: Bool
    }

    static func project(
        _ rawText: String,
        userHomeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        maximumUTF8Bytes: Int = maximumUTF8Bytes
    ) -> Value {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = userHomeDirectory.isEmpty
            ? trimmed
            : trimmed.replacingOccurrences(of: userHomeDirectory, with: "<home>")
        let escaped = escapeControls(in: redacted)
        return utf8Bounded(escaped, maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private static func escapeControls(in text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                escaped += "\\n"
            case 0x0D:
                escaped += "\\r"
            case 0x09:
                escaped += "\\t"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u{%04X}", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }

    private static func utf8Bounded(_ text: String, maximumUTF8Bytes: Int) -> Value {
        guard maximumUTF8Bytes > 0 else {
            return Value(text: "", isTruncated: !text.isEmpty)
        }
        guard text.utf8.count > maximumUTF8Bytes else {
            return Value(text: text, isTruncated: false)
        }

        let markerFits = truncationMarker.utf8.count <= maximumUTF8Bytes
        let marker = markerFits ? truncationMarker : ""
        let availablePrefixBytes = maximumUTF8Bytes - marker.utf8.count
        var prefix = ""
        prefix.reserveCapacity(availablePrefixBytes)
        var prefixByteCount = 0

        for scalar in text.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard prefixByteCount + scalarByteCount <= availablePrefixBytes else { break }
            prefix.unicodeScalars.append(scalar)
            prefixByteCount += scalarByteCount
        }

        return Value(text: prefix + marker, isTruncated: true)
    }
}

struct DebuggerExternalCommand: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var timeoutSeconds: TimeInterval

    var displayString: String {
        ([executablePath] + arguments).map { argument in
            guard argument.contains(" ") else { return argument }
            return "'\(argument)'"
        }.joined(separator: " ")
    }
}

struct DebuggerLLDBToolchain: Equatable {
    var executablePath: String
    var developerDirectory: String?
    var discoverySource: String
    var candidatePaths: [String]
}

struct DebuggerSubprocessResult: Equatable {
    var terminationStatus: Int32
    var standardOutput: String
    var standardError: String
    var timedOut: Bool

    var succeeded: Bool {
        !timedOut && terminationStatus == 0
    }
}

struct DebuggerLLDBProofResult: Equatable {
    enum Status: Equatable {
        case passed
        case failed(exitCode: Int32)
        case timedOut
        case executionFailed(String)
    }

    var toolchain: DebuggerLLDBToolchain
    var command: DebuggerExternalCommand
    var status: Status
    var versionSummary: String?
    var hostTriple: String?
    var platformSummary: String?
    var outputPreview: String
    var errorPreview: String

    var succeeded: Bool {
        status == .passed
    }

    var summary: String {
        let rawSummary: String
        switch status {
        case .passed:
            let version = versionSummary ?? "LLDB version unavailable"
            let triple = hostTriple.map { " host \($0)" } ?? ""
            rawSummary = "LLDB subprocess proof passed with \(version)\(triple)."
        case .failed(let exitCode):
            let detail = failureDetail
            rawSummary = "LLDB subprocess proof failed with exit code \(exitCode)\(detail)."
        case .timedOut:
            rawSummary = "LLDB subprocess proof timed out after \(Int(command.timeoutSeconds)) seconds."
        case .executionFailed(let reason):
            rawSummary = "LLDB subprocess proof could not start: \(reason)"
        }
        return DebuggerPublishedDiagnosticText.project(rawSummary).text
    }

    private var failureDetail: String {
        let detail = [errorPreview, outputPreview]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return detail.map { ": \($0)" } ?? ""
    }
}

enum DebuggerBackendAvailability: Equatable {
    case unavailable(reason: String)
    case discovered(toolPath: String, details: String)
    case ready(adapterName: String, details: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .unavailable(let reason):
            reason
        case .discovered(_, let details), .ready(_, let details):
            details
        }
    }
}

enum DebuggerOperationSupport: Equatable {
    case unsupported(reason: String)
    case supported

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    var unavailableReason: String? {
        guard case .unsupported(let reason) = self else { return nil }
        return reason
    }
}

struct DebuggerCapabilityReport: Equatable {
    var backendName: String
    var isBackendAvailable: Bool
    var canLaunch: Bool
    var canAttach: Bool
    var canControlExecution: Bool
    var limitations: [String]
    var entitlementNotes: [String]
    var backendAvailability: DebuggerBackendAvailability
    var launchSupport: DebuggerOperationSupport
    var attachSupport: DebuggerOperationSupport
    var executionControlSupport: DebuggerOperationSupport
    var lldbProof: DebuggerLLDBProofResult?

    var summary: String {
        backendAvailability.summary
    }

    init(
        backendName: String,
        isBackendAvailable: Bool,
        canLaunch: Bool,
        canAttach: Bool,
        canControlExecution: Bool,
        limitations: [String],
        entitlementNotes: [String],
        backendAvailability: DebuggerBackendAvailability? = nil,
        launchSupport: DebuggerOperationSupport? = nil,
        attachSupport: DebuggerOperationSupport? = nil,
        executionControlSupport: DebuggerOperationSupport? = nil,
        lldbProof: DebuggerLLDBProofResult? = nil
    ) {
        let fallbackReason = limitations.first ?? "\(backendName) is not available."
        let resolvedAvailability = backendAvailability ?? (
            isBackendAvailable
            ? .ready(adapterName: backendName, details: "\(backendName) is available.")
            : .unavailable(reason: fallbackReason)
        )
        let resolvedLaunchSupport = launchSupport ?? (
            canLaunch ? .supported : .unsupported(reason: fallbackReason)
        )
        let resolvedAttachSupport = attachSupport ?? (
            canAttach ? .supported : .unsupported(reason: fallbackReason)
        )
        let resolvedControlSupport = executionControlSupport ?? (
            canControlExecution ? .supported : .unsupported(reason: fallbackReason)
        )

        self.backendName = backendName
        self.backendAvailability = resolvedAvailability
        self.launchSupport = resolvedLaunchSupport
        self.attachSupport = resolvedAttachSupport
        self.executionControlSupport = resolvedControlSupport
        self.isBackendAvailable = resolvedAvailability.isReady
        self.canLaunch = resolvedLaunchSupport.isSupported
        self.canAttach = resolvedAttachSupport.isSupported
        self.canControlExecution = resolvedControlSupport.isSupported
        self.limitations = limitations
        self.entitlementNotes = entitlementNotes
        self.lldbProof = lldbProof
    }
}

struct DebuggerLaunchConfiguration: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var initialBreakpoints: [DebuggerBreakpoint]

    init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialBreakpoints: [DebuggerBreakpoint] = []
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.initialBreakpoints = initialBreakpoints
    }

    var displayName: String {
        let expandedPath = normalizedExecutablePath
        guard !expandedPath.isEmpty else { return "target" }
        return URL(fileURLWithPath: expandedPath).lastPathComponent
    }

    var normalizedExecutablePath: String {
        (executablePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    var normalizedWorkingDirectory: String? {
        guard let workingDirectory else { return nil }
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    var normalizedEnvironment: [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in environment {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            normalized[trimmedKey] = value
        }
        return normalized
    }
}

enum DebuggerLaunchValidationSeverity: Equatable {
    case blocker
    case warning
}

struct DebuggerLaunchValidationIssue: Identifiable, Equatable {
    var severity: DebuggerLaunchValidationSeverity
    var message: String

    var id: String {
        "\(severity)-\(message)"
    }
}

struct DebuggerLaunchValidationSummary: Equatable {
    var displayName: String
    var executablePath: String
    var workingDirectory: String?
    var argumentCount: Int
    var environmentVariableCount: Int
    var issues: [DebuggerLaunchValidationIssue]

    var isLaunchable: Bool {
        disabledReason == nil
    }

    var disabledReason: String? {
        issues.first { $0.severity == .blocker }?.message
    }

    var statusTitle: String {
        isLaunchable ? "Ready" : "Blocked"
    }

    var argumentSummary: String {
        switch argumentCount {
        case 0:
            return "No arguments"
        case 1:
            return "1 argument"
        default:
            return "\(argumentCount) arguments"
        }
    }

    var environmentSummary: String {
        switch environmentVariableCount {
        case 0:
            return "No environment overrides"
        case 1:
            return "1 environment override"
        default:
            return "\(environmentVariableCount) environment overrides"
        }
    }

    var workingDirectorySummary: String {
        workingDirectory ?? "default working directory"
    }

    var detail: String {
        if let disabledReason {
            return disabledReason
        }

        return "Launch \(displayName) from \(workingDirectorySummary). \(argumentSummary); \(environmentSummary)."
    }

    static func evaluate(
        configuration: DebuggerLaunchConfiguration,
        launchSupport: DebuggerOperationSupport,
        blockedReason: String? = nil,
        fileManager: FileManager = .default,
        requiresExecutableFile: Bool = true
    ) -> DebuggerLaunchValidationSummary {
        let executablePath = configuration.normalizedExecutablePath
        let displayName = DebuggerTargetSelectionDescriptor.displayName(forPath: executablePath)
        let workingDirectory = configuration.normalizedWorkingDirectory
        var issues: [DebuggerLaunchValidationIssue] = []

        if let blockedReason {
            issues.append(.init(severity: .blocker, message: blockedReason))
        }

        if case .unsupported(let reason) = launchSupport {
            issues.append(.init(severity: .blocker, message: reason))
        }

        if executablePath.isEmpty {
            issues.append(.init(severity: .blocker, message: "Choose an imported executable before launching."))
        } else if !executablePath.hasPrefix("/") {
            issues.append(.init(severity: .blocker, message: "Launch target path must be absolute before launching."))
        } else if requiresExecutableFile && !fileManager.isExecutableFile(atPath: executablePath) {
            issues.append(.init(severity: .blocker, message: "No executable file exists at \(executablePath)."))
        }

        if let workingDirectory {
            var isDirectory = ObjCBool(false)
            if !fileManager.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) || !isDirectory.boolValue {
                issues.append(.init(severity: .blocker, message: "Working directory does not exist: \(workingDirectory)."))
            }
        }

        issues += validateArguments(configuration.arguments)
        // Validate the authored map before normalization can discard an empty key, trim a control
        // character, or collapse two keys onto the same normalized identifier.
        issues += validateEnvironment(configuration.environment)

        return DebuggerLaunchValidationSummary(
            displayName: displayName,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            argumentCount: configuration.arguments.count,
            environmentVariableCount: configuration.normalizedEnvironment.count,
            issues: issues
        )
    }

    private static func validateArguments(_ arguments: [String]) -> [DebuggerLaunchValidationIssue] {
        arguments.enumerated().compactMap { index, argument in
            guard DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(argument) else {
                return nil
            }
            return DebuggerLaunchValidationIssue(
                severity: .blocker,
                message: "Launch argument \(index + 1) contains unsupported control characters."
            )
        }
    }

    private static func validateEnvironment(_ environment: [String: String]) -> [DebuggerLaunchValidationIssue] {
        var seenKeys: Set<String> = []
        return environment.keys.sorted().flatMap { rawKey -> [DebuggerLaunchValidationIssue] in
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            var issues: [DebuggerLaunchValidationIssue] = []
            if key.isEmpty {
                issues.append(.init(
                    severity: .blocker,
                    message: "Environment key cannot be empty."
                ))
            } else if DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(rawKey)
                || !DebuggerAuthoredInputValidation.isValidEnvironmentKey(key) {
                issues.append(.init(
                    severity: .blocker,
                    message: "Environment key \(key) contains unsupported characters."
                ))
            } else if !seenKeys.insert(key).inserted {
                issues.append(.init(
                    severity: .blocker,
                    message: "Environment key \(key) is set more than once."
                ))
            }

            if let value = environment[rawKey],
               DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(value) {
                issues.append(.init(
                    severity: .blocker,
                    message: "Environment value for \(key) contains unsupported control characters."
                ))
            }

            return issues
        }
    }
}

enum DebuggerControlAction: Equatable {
    case launch
    case attachProcess
    case continueExecution
    case runToCursor
    case stepOver
    case stepInto
    case stepOut
    case pause
    case detach
    case terminate
    case refreshSnapshot
    case writeRegister
    case readMemory
    case writeMemory
    case evaluateExpression
    case selectThread
    case selectFrame

    var title: String {
        switch self {
        case .launch:
            "Launch"
        case .attachProcess:
            "Attach"
        case .continueExecution:
            "Continue"
        case .runToCursor:
            "Run to Cursor"
        case .stepOver:
            "Step Over"
        case .stepInto:
            "Step Into"
        case .stepOut:
            "Step Out"
        case .pause:
            "Pause"
        case .detach:
            "Detach"
        case .terminate:
            "Terminate"
        case .refreshSnapshot:
            "Refresh Snapshot"
        case .writeRegister:
            "Write Register"
        case .readMemory:
            "Read Memory"
        case .writeMemory:
            "Write Memory"
        case .evaluateExpression:
            "Evaluate Expression"
        case .selectThread:
            "Select Thread"
        case .selectFrame:
            "Select Frame"
        }
    }
}

struct DebuggerControlAvailability: Equatable {
    var action: DebuggerControlAction
    var isEnabled: Bool
    var disabledReason: String?

    var helpText: String {
        if let disabledReason {
            return disabledReason
        }

        return "\(action.title) debugger target"
    }
}

enum DebuggerClientError: LocalizedError, Equatable {
    case backendUnavailable(String)
    case unsupportedOperation(String)
    case invalidConfiguration(String)
    case invalidState(String)
    case backendFailure(String)

    var errorDescription: String? {
        switch self {
        case .backendUnavailable(let reason),
             .unsupportedOperation(let reason),
             .invalidConfiguration(let reason),
             .invalidState(let reason),
             .backendFailure(let reason):
            reason
        }
    }
}

@MainActor
protocol DebuggerClient {
    func shutdown() async
    var capabilities: DebuggerCapabilityReport { get }

    func makeInitialSnapshot() -> DebuggerSessionSnapshot
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot
    /// Attaches only from a fully observed, immutable local-process identity.
    /// Implementations must not reduce this authority back to an unverified caller PID.
    func attach(_ request: DebuggerLocalAttachRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    /// Legacy UI compatibility seam. Production backends must fail this raw-PID route closed.
    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    /// Reconciles one complete catalog + pure-resolution authority bundle with a typed live
    /// session. The opaque request is the only public live breakpoint mutation seam.
    func reconcileLogicalBreakpoints(_ request: DebuggerLogicalBreakpointReconcileRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func updateWatchpoints(_ request: DebuggerWatchpointRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult
    func expandVariableChildren(_ request: DebuggerVariableExpansionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    /// Internal live-session observation used after asynchronous run control. Implementations must
    /// author state only from a correlated backend observation; callers must not synthesize a stop.
    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
}

extension DebuggerClient {
    func updateWatchpoints(_ request: DebuggerWatchpointRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Watchpoints require a persistent LLDB session.")
    }

    func shutdown() async {}
    func reconcileLogicalBreakpoints(
        _ request: DebuggerLogicalBreakpointReconcileRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Typed logical-breakpoint reconciliation is not supported by this debugger backend."
        )
    }

    /// Default step-into / step-out fall back to the unsupported posture so that
    /// pre-existing conformers (notably test doubles) keep compiling without
    /// reimplementing the new transport commands. Real backends override these to
    /// issue `thread step-in` / `thread step-out`.
    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Step into is not supported for this target.")
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Step out is not supported for this target.")
    }

    /// Default run-to-cursor mirrors the step-into/out posture so pre-existing
    /// conformers (notably test doubles) keep compiling without reimplementing the
    /// temp-breakpoint + continue sequence. The real backend overrides this to set
    /// a one-shot breakpoint at the cursor and `process continue`.
    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Run to cursor is not supported for this target.")
    }

    /// Default register-write / memory-read mirror the step-into/out posture so
    /// that pre-existing conformers (notably test doubles) keep compiling. The
    /// real backend overrides both to issue `register write` / `memory read`.
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Register write is not supported for this target.")
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Memory read is not supported for this target.")
    }

    /// Default memory-write mirrors the memory-read posture so pre-existing
    /// conformers (notably test doubles) keep compiling. The real backend overrides
    /// this to issue `memory write` and read the bytes back.
    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Memory write is not supported for this target.")
    }

    /// Default expression-evaluation / thread-selection mirror the register-write
    /// / memory-read posture so that pre-existing conformers (notably test doubles)
    /// keep compiling. The real backend overrides both to issue `expression --` /
    /// `thread select`.
    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        throw DebuggerClientError.unsupportedOperation("Expression evaluation is not supported for this target.")
    }

    func expandVariableChildren(
        _ request: DebuggerVariableExpansionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Variable child expansion is not supported for this target."
        )
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Thread selection is not supported for this target.")
    }

    /// Default frame-selection mirrors the thread-selection posture so pre-existing
    /// conformers (notably test doubles) keep compiling. The real backend overrides
    /// this to issue `frame select <index>` and re-read that frame's context.
    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Frame selection is not supported for this target.")
    }

    /// A complete local-process identity is the only attach authority admitted
    /// to a backend. The default remains unsupported so existing conformers fail
    /// closed until they implement the exact attach transaction.
    func attach(
        _ request: DebuggerLocalAttachRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Exact local-process attach is not supported by this debugger backend."
        )
    }

    /// The raw-PID compatibility seam deliberately has no transport default.
    /// User-entered or process-list PIDs must be upgraded to an exact identity
    /// before any attach implementation can be reached.
    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Raw PID attach is disabled; select and authorize an exactly identified local process."
        )
    }

    func pollProcessStatus(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation(
            "Live process-status observation is not supported for this target."
        )
    }

    /// Exact attached-origin sessions end by detaching, not by terminating the target. The default
    /// remains unsupported so older test doubles fail closed unless they intentionally opt in.
    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation("Detach is not supported for this target.")
    }
}

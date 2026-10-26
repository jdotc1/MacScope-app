import Darwin
import Foundation

/// Shared construction boundary for the retained Xcode-bundled LLDB child process.
///
/// This factory authors only interpreter startup state. It accepts no target, PID, process name,
/// debugger authority, semantic command, or user-authored command. Both exact launch and exact
/// attach therefore use the same selected-Xcode validation, environment allowlist, working
/// directory validation, and fail-closed asynchronous-mode startup gate.
enum PersistentLLDBCLIProcessPlanFactory {
    @MainActor
    static func make(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String],
        workingDirectory: String,
        fileManager: FileManager = .default
    ) throws -> PersistentLLDBCLIProcessLaunchPlan {
        try validateResolvedWorkingDirectory(workingDirectory, fileManager: fileManager)

        guard let developerDirectory = resolvedDeveloperDirectory(
            toolchain: toolchain,
            environment: environment
        ) else {
            throw invalid("LLDB live launch requires a selected Xcode developer directory.")
        }

        var processEnvironment = sanitizedAdapterEnvironment(environment)
        processEnvironment["TERM"] = "dumb"
        processEnvironment["NSUnbufferedIO"] = "YES"
        processEnvironment["DEVELOPER_DIR"] = developerDirectory
        let processLaunchPlan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: toolchain.executablePath,
            developerDirectory: developerDirectory,
            environment: processEnvironment,
            workingDirectory: workingDirectory
        )
        guard processLaunchPlan.arguments.contains(
            PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand
        ) else {
            throw invalid(
                "The persistent LLDB process plan is missing its fail-closed async startup gate."
            )
        }
        return processLaunchPlan
    }

    private static func validateResolvedWorkingDirectory(
        _ path: String,
        fileManager: FileManager
    ) throws {
        guard path.hasPrefix("/") else {
            throw invalid("LLDB live launch requires an absolute working directory.")
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw invalid("Working directory does not exist: \(path).")
        }
    }

    private static func resolvedDeveloperDirectory(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String]
    ) -> String? {
        if let selected = toolchain.developerDirectory, !selected.isEmpty {
            return selected
        }
        if let selected = environment["DEVELOPER_DIR"], !selected.isEmpty {
            return selected
        }
        return nil
    }

    private static func sanitizedAdapterEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        let exactKeys: Set<String> = [
            "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL",
        ]
        return environment.reduce(into: [:]) { result, entry in
            let (key, value) = entry
            guard exactKeys.contains(key) || key.hasPrefix("LC_") else { return }
            // Empty or control-bearing values are not useful process baselines and are excluded
            // rather than allowing an unreviewed host value into the LLDB adapter environment.
            guard !value.isEmpty,
                  !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(value)
            else { return }
            result[key] = value
        }
    }

    private static func invalid(_ message: String) -> DebuggerClientError {
        .invalidConfiguration(message)
    }
}

/// Opaque proof that one canonical executable's final path component was opened with
/// `O_NOFOLLOW`, validated as one unambiguous native Mach-O slice, fully hashed, and
/// metadata-rechecked off the main actor. Parent path components remain subject to normal Darwin
/// path resolution; post-launch identity corroboration is therefore still mandatory.
struct DebuggerExecutableSealingGrant: Sendable {
    fileprivate let seal: DebuggerImportedExecutableSeal

    fileprivate init(seal: DebuggerImportedExecutableSeal) {
        self.seal = seal
    }
}

enum DebuggerExecutableSealer {
    static func seal(
        canonicalExecutablePath: String,
        timeout: Duration
    ) async throws -> DebuggerExecutableSealingGrant {
        guard timeout > .zero else {
            throw invalid("Executable sealing requires a positive timeout.")
        }
        let task = Task.detached {
            try sealSynchronously(
                canonicalExecutablePath: canonicalExecutablePath,
                timeout: timeout
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct ExecutableMetadata: Equatable {
        let deviceID: UInt64
        let fileID: UInt64
        let byteCount: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private static func sealSynchronously(
        canonicalExecutablePath: String,
        timeout: Duration
    ) throws -> DebuggerExecutableSealingGrant {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try checkProgress(deadline: deadline)
        errno = 0
        let descriptor = Darwin.open(
            canonicalExecutablePath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw invalid("Launch target could not be opened for exact sealing.")
        }
        defer { Darwin.close(descriptor) }
        guard let before = executableMetadata(descriptor: descriptor) else {
            throw invalid("Launch target metadata could not be sealed exactly.")
        }
        try checkProgress(deadline: deadline)
        let read: (UInt64, Int) -> DarwinReadResult<Data> = { offset, count in
            guard !Task.isCancelled else { return .cancelled }
            guard ContinuousClock.now < deadline else { return .failed(ETIMEDOUT) }
            return readExecutable(descriptor: descriptor, offset: offset, count: count)
        }
        try checkProgress(deadline: deadline)
        let arm64 = DarwinMachOParser.observe(
            fileByteCount: before.byteCount,
            expectedArchitecture: .arm64,
            read: read
        )
        try checkProgress(deadline: deadline)
        let arm64e = DarwinMachOParser.observe(
            fileByteCount: before.byteCount,
            expectedArchitecture: .arm64e,
            read: read
        )
        try checkProgress(deadline: deadline)
        let observation: DarwinMachOObservation
        switch (arm64, arm64e) {
        case (.value(let value), .malformed):
            observation = value
        case (.malformed, .value(let value)):
            observation = value
        case (.value, .value):
            throw invalid(
                "Launch target contains ambiguous arm64 and arm64e slices; an exact architecture "
                    + "selection is required."
            )
        case (.cancelled, _), (_, .cancelled):
            throw CancellationError()
        default:
            throw invalid("Launch target is not one unambiguous native ARM64 Mach-O executable.")
        }
        let digest: String
        try checkProgress(deadline: deadline)
        switch DarwinAuthorizationHasher.sha256(
            byteCount: before.byteCount,
            deadlineExpired: { ContinuousClock.now >= deadline },
            isCancelled: { Task.isCancelled },
            read: read
        ) {
        case .success(let value):
            digest = value
        case .cancelled:
            throw CancellationError()
        case .timeout:
            throw invalid("Launch target exact sealing exceeded its bounded deadline.")
        case .unstable:
            try checkProgress(deadline: deadline)
            throw invalid("Launch target contents could not be sealed exactly.")
        }
        try checkProgress(deadline: deadline)
        guard executableMetadata(descriptor: descriptor) == before else {
            throw invalid("Launch target changed while its exact seal was being created.")
        }
        do {
            let seal = try DebuggerImportedExecutableSeal(
                canonicalPath: canonicalExecutablePath,
                deviceID: before.deviceID,
                fileID: before.fileID,
                byteCount: before.byteCount,
                sha256: digest,
                architecture: observation.architecture == .arm64 ? .arm64 : .arm64e,
                machOUUID: observation.uuid
            )
            return DebuggerExecutableSealingGrant(seal: seal)
        } catch {
            throw invalid("Launch target exact seal was malformed.")
        }
    }

    private static func executableMetadata(descriptor: Int32) -> ExecutableMetadata? {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_dev > 0,
              value.st_ino > 0,
              value.st_size > 0,
              (0..<1_000_000_000).contains(value.st_mtimespec.tv_nsec),
              (0..<1_000_000_000).contains(value.st_ctimespec.tv_nsec) else { return nil }
        return ExecutableMetadata(
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            byteCount: UInt64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private static func checkProgress(
        deadline: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        if ContinuousClock.now >= deadline {
            throw invalid("Launch target exact sealing exceeded its bounded deadline.")
        }
    }

    private static func readExecutable(
        descriptor: Int32,
        offset: UInt64,
        count: Int
    ) -> DarwinReadResult<Data> {
        guard count >= 0, offset <= UInt64(Int64.max) else { return .malformed }
        if count == 0 { return .value(Data()) }
        var data = Data(count: count)
        errno = 0
        let result = data.withUnsafeMutableBytes {
            Darwin.pread(descriptor, $0.baseAddress!, count, off_t(offset))
        }
        if result < 0 {
            return errno == EINTR ? .interrupted : .failed(errno)
        }
        guard result > 0 else { return .endOfFile }
        data.removeSubrange(result..<data.count)
        return .value(data)
    }

    private static func invalid(_ message: String) -> DebuggerClientError {
        .invalidConfiguration(message)
    }
}

/// All value copies of one frozen launch plan share this ticket. Exactly one coordinator can
/// consume it, including when the first attempt fails before dispatching the final launch command.
private final class DebuggerExactLaunchExecutionTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var isConsumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isConsumed else { return false }
        isConsumed = true
        return true
    }
}

/// A fully validated, immutable launch boundary for the persistent LLDB transport.
///
/// Construction performs every authored-input, rendered-command, filesystem, process-plan, and
/// aggregate-wire check before a caller is allowed to stop an existing adapter or start a new
/// one. Callers must retain this value rather than rebuilding commands after preflight.
struct DebuggerLLDBSealedLaunchPlan: Sendable {
    static let maximumArgumentCount = 128
    static let maximumArgumentBytes = 1_024
    static let maximumEnvironmentEntryCount = 128
    static let maximumEnvironmentKeyBytes = 128
    static let maximumEnvironmentValueBytes = 1_024
    static let maximumBreakpointConditionBytes = 1_024
    static let maximumPathBytes = 1_024
    static let maximumEncodedWireBytes = LLDBCLITranscriptDecoder.maximumCommandBytes

    /// Runs during retained-LLDB startup, before stdin is processed. The explicit child exit is
    /// the fail-closed gate: an LLDB build that declines async mode cannot continue on to consume
    /// a later target-create or process-launch request. This belongs to the immutable process
    /// launch plan and must never be duplicated in target semantic commands.
    static let failClosedAsyncStartupCommand =
        PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand

    let processLaunchPlan: PersistentLLDBCLIProcessLaunchPlan
    let semanticCommands: [String]
    /// The exact canonical path rendered into `target create`. Exact launched-process
    /// corroboration compares OS-observed identity against this frozen value rather than parsing
    /// command text or accepting a second caller-authored path.
    let canonicalExecutablePath: String
    /// Exact bytes and filesystem/Mach-O identity opened and hashed before the retained adapter
    /// exists. Post-launch process identity must match every field before authority is published.
    let executableSeal: DebuggerImportedExecutableSeal
    private let executionTicket: DebuggerExactLaunchExecutionTicket
    let normalizedDisplayName: String
    let normalizedBreakpoints: [DebuggerBreakpoint]
    let sensitivityCatalog: DebuggerDiagnosticSensitivityCatalog
    let timeout: Duration
    let encodedWireByteCount: Int

    private init(
        processLaunchPlan: PersistentLLDBCLIProcessLaunchPlan,
        semanticCommands: [String],
        canonicalExecutablePath: String,
        executableSeal: DebuggerImportedExecutableSeal,
        executionTicket: DebuggerExactLaunchExecutionTicket,
        normalizedDisplayName: String,
        normalizedBreakpoints: [DebuggerBreakpoint],
        sensitivityCatalog: DebuggerDiagnosticSensitivityCatalog,
        timeout: Duration,
        encodedWireByteCount: Int
    ) {
        self.processLaunchPlan = processLaunchPlan
        self.semanticCommands = semanticCommands
        self.canonicalExecutablePath = canonicalExecutablePath
        self.executableSeal = executableSeal
        self.executionTicket = executionTicket
        self.normalizedDisplayName = normalizedDisplayName
        self.normalizedBreakpoints = normalizedBreakpoints
        self.sensitivityCatalog = sensitivityCatalog
        self.timeout = timeout
        self.encodedWireByteCount = encodedWireByteCount
    }

    @MainActor
    static func prepareCanonicalExecutablePath(
        configuration: DebuggerLaunchConfiguration,
        fileManager: FileManager = .default
    ) throws -> String {
        var authoritativeConfiguration = configuration
        authoritativeConfiguration.initialBreakpoints = []
        try validateRawAuthoredInputs(authoritativeConfiguration)
        try XcodeLLDBCommandLineAdapter.validateLiveLaunchConfiguration(
            authoritativeConfiguration,
            fileManager: fileManager
        )
        return URL(
            fileURLWithPath: authoritativeConfiguration.normalizedExecutablePath
        ).resolvingSymlinksInPath().standardizedFileURL.path
    }

    @MainActor
    static func make(
        configuration: DebuggerLaunchConfiguration,
        executableSealingGrant: DebuggerExecutableSealingGrant,
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String],
        fallbackWorkingDirectory: String,
        timeout: Duration,
        fileManager: FileManager = .default
    ) throws -> DebuggerLLDBSealedLaunchPlan {
        guard timeout > .zero else {
            throw invalid("LLDB live launch requires a positive timeout.")
        }

        // `initialBreakpoints` remains on the shared launch configuration for compatibility with
        // the legacy batch client. The persistent authoritative path must not validate, render,
        // diagnose, or otherwise consume those unchecked static addresses. WS-21 materializes
        // logical breakpoints only after the reducer has accepted an exact stopped inventory.
        var authoritativeConfiguration = configuration
        authoritativeConfiguration.initialBreakpoints = []

        try validateRawAuthoredInputs(authoritativeConfiguration)
        try XcodeLLDBCommandLineAdapter.validateLiveLaunchConfiguration(
            authoritativeConfiguration,
            fileManager: fileManager
        )
        let canonicalExecutablePath = URL(
            fileURLWithPath: authoritativeConfiguration.normalizedExecutablePath
        ).resolvingSymlinksInPath().standardizedFileURL.path
        authoritativeConfiguration.executablePath = canonicalExecutablePath
        try validateFrozenBounds(
            authoritativeConfiguration,
            fallbackWorkingDirectory: fallbackWorkingDirectory
        )
        try XcodeLLDBCommandLineAdapter.validateLiveLaunchConfiguration(
            authoritativeConfiguration,
            fileManager: fileManager
        )
        let executableSeal = executableSealingGrant.seal
        guard executableSeal.canonicalPath.utf8.elementsEqual(
            canonicalExecutablePath.utf8
        ) else {
            throw invalid("Executable sealing grant does not match the canonical launch target.")
        }

        let workingDirectory = authoritativeConfiguration.normalizedWorkingDirectory
            ?? fallbackWorkingDirectory
        try validateResolvedWorkingDirectory(workingDirectory, fileManager: fileManager)

        let normalizedBreakpoints: [DebuggerBreakpoint] = []
        let semanticCommands = makeSemanticCommands(configuration: authoritativeConfiguration)
        for command in semanticCommands {
            try LLDBCLITranscriptDecoder.validateRenderedCommand(command)
        }
        let encodedWireByteCount = try encodedWireByteCount(for: semanticCommands)
        guard encodedWireByteCount <= maximumEncodedWireBytes else {
            throw invalid(
                "LLDB live launch setup encodes to \(encodedWireByteCount) bytes; "
                + "the complete correlated request must not exceed \(maximumEncodedWireBytes) bytes."
            )
        }

        let processLaunchPlan = try PersistentLLDBCLIProcessPlanFactory.make(
            toolchain: toolchain,
            environment: environment,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )

        let normalizedEnvironment = authoritativeConfiguration.normalizedEnvironment
        let sensitivityCatalog = DebuggerDiagnosticSensitivityCatalog(
            environmentValues: normalizedEnvironment.keys.sorted().compactMap {
                normalizedEnvironment[$0]
            },
            authoredArguments: authoritativeConfiguration.arguments,
            breakpointConditions: []
        )

        return DebuggerLLDBSealedLaunchPlan(
            processLaunchPlan: processLaunchPlan,
            semanticCommands: semanticCommands,
            canonicalExecutablePath: canonicalExecutablePath,
            executableSeal: executableSeal,
            executionTicket: DebuggerExactLaunchExecutionTicket(),
            normalizedDisplayName: authoritativeConfiguration.displayName,
            normalizedBreakpoints: normalizedBreakpoints,
            sensitivityCatalog: sensitivityCatalog,
            timeout: timeout,
            encodedWireByteCount: encodedWireByteCount
        )
    }

    private static func validateRawAuthoredInputs(
        _ configuration: DebuggerLaunchConfiguration
    ) throws {
        guard !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(
            configuration.executablePath
        ) else {
            throw invalid("Launch target path contains unsupported control characters.")
        }
        if let workingDirectory = configuration.workingDirectory {
            guard !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(
                workingDirectory
            ) else {
                throw invalid("Working directory contains unsupported control characters.")
            }
        }

        for (index, argument) in configuration.arguments.enumerated() {
            guard !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(argument) else {
                throw invalid(
                    "Launch argument \(index + 1) contains unsupported control characters."
                )
            }
        }

        var normalizedKeys: Set<String> = []
        for rawKey in configuration.environment.keys.sorted() {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(rawKey),
                  DebuggerAuthoredInputValidation.isValidEnvironmentKey(key) else {
                throw invalid("Environment key \(key) contains unsupported characters.")
            }
            guard normalizedKeys.insert(key).inserted else {
                throw invalid("Environment key \(key) is set more than once.")
            }
            if let value = configuration.environment[rawKey] {
                guard !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(value) else {
                    throw invalid(
                        "Environment value for \(key) contains unsupported control characters."
                    )
                }
            }
        }

    }

    private static func validateFrozenBounds(
        _ configuration: DebuggerLaunchConfiguration,
        fallbackWorkingDirectory: String
    ) throws {
        try requireByteBound(
            configuration.normalizedExecutablePath,
            field: "Launch target path",
            maximum: maximumPathBytes
        )
        let resolvedWorkingDirectory = configuration.normalizedWorkingDirectory
            ?? fallbackWorkingDirectory
        try requireByteBound(
            resolvedWorkingDirectory,
            field: "Working directory",
            maximum: maximumPathBytes
        )

        guard configuration.arguments.count <= maximumArgumentCount else {
            throw invalid(
                "LLDB live launch accepts at most \(maximumArgumentCount) arguments."
            )
        }
        for (index, argument) in configuration.arguments.enumerated() {
            try requireByteBound(
                argument,
                field: "Launch argument \(index + 1)",
                maximum: maximumArgumentBytes
            )
        }

        guard configuration.environment.count <= maximumEnvironmentEntryCount else {
            throw invalid(
                "LLDB live launch accepts at most \(maximumEnvironmentEntryCount) environment entries."
            )
        }
        for rawKey in configuration.environment.keys.sorted() {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            try requireByteBound(
                key,
                field: "Environment key",
                maximum: maximumEnvironmentKeyBytes
            )
            if let value = configuration.environment[rawKey] {
                try requireByteBound(
                    value,
                    field: "Environment value for \(key)",
                    maximum: maximumEnvironmentValueBytes
                )
            }
        }

    }

    private static func validateResolvedWorkingDirectory(
        _ path: String,
        fileManager: FileManager
    ) throws {
        guard path.hasPrefix("/") else {
            throw invalid("LLDB live launch requires an absolute working directory.")
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw invalid("Working directory does not exist: \(path).")
        }
    }

    @MainActor
    private static func makeSemanticCommands(
        configuration: DebuggerLaunchConfiguration
    ) -> [String] {
        var commands = [
            "settings set use-color false",
            // A target must never inherit the persistent interpreter's control pipe. Standard-I/O
            // support is a separate product surface; WS-19 launches with an explicit null input
            // and `--no-stdio` so target code cannot consume or forge framed commands while the
            // asynchronous debugger command channel remains available during execution.
            "settings set target.input-path /dev/null",
            // Xcode 27's default thread formats request libdispatch extended-thread metadata.
            // A stop can race that formatter against our correlated status/readback commands and
            // crash LLDB itself. Keep launch-local formatting deterministic and limited to fields
            // that do not invoke the SystemRuntimeMacOSX extended-info path. The thread list also
            // carries the top frame's `module`function` (frame symbolication) and the pthread name
            // (reported by debugserver, not libdispatch); `${thread.queue}` stays out.
            "settings set thread-stop-format \"thread #${thread.index}: "
                + "tid = ${thread.id%tid}{, stop reason = ${thread.stop-reason}}\\n\"",
            "settings set thread-format \"thread #${thread.index}: tid = ${thread.id%tid}"
                + "{, ${frame.pc}}{ ${module.file.basename}`${function.name}}{, name = '${thread.name}'}"
                + "{, stop reason = ${thread.stop-reason}}\\n\"",
            XcodeLLDBCommandLineAdapter.makeTargetCreateCommand(for: configuration),
        ]
        if let environmentCommand = XcodeLLDBCommandLineAdapter.makeEnvironmentCommand(
            for: configuration.normalizedEnvironment
        ) {
            commands.append(environmentCommand)
        }
        if let argumentsCommand = XcodeLLDBCommandLineAdapter.makeRunArgumentsCommand(
            for: configuration.arguments
        ) {
            commands.append(argumentsCommand)
        }
        commands.append("process launch --stop-at-entry --no-stdio")
        return commands
    }

    private static func encodedWireByteCount(for commands: [String]) throws -> Int {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "f", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        return PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: commands,
            markers: markers
        ).count
    }

    private static func requireByteBound(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        let actual = value.utf8.count
        guard actual <= maximum else {
            throw invalid(
                "\(field) is \(actual) UTF-8 bytes; the maximum is \(maximum) bytes."
            )
        }
    }

    private static func invalid(_ message: String) -> DebuggerClientError {
        .invalidConfiguration(message)
    }

    func claimExactLaunchExecution() -> Bool {
        executionTicket.claim()
    }

}

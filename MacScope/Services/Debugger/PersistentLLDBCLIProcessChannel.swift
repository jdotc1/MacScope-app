import Darwin
import Foundation

enum PersistentLLDBCLIProcessChannelError: Error, LocalizedError, Sendable, Equatable {
    case invalidDeveloperDirectory
    case lldbOutsideSelectedXcode
    case invalidWorkingDirectory
    case missingLLDBExecutable(String)
    case processLaunchFailed(String)
    case invalidProcessState
    case inputSignalProtectionFailed(Int32)
    case adapterNotRunning
    case inputClosed
    case inputWriteFailed(Int32)
    case writeTooLarge
    case readBufferOverflow
    case multipleReaders

    var errorDescription: String? {
        switch self {
        case .invalidDeveloperDirectory:
            "The selected Xcode developer directory must be absolute."
        case .lldbOutsideSelectedXcode:
            "LLDB must be the executable bundled inside the selected Xcode developer directory."
        case .invalidWorkingDirectory:
            "The LLDB working directory must be an existing absolute directory."
        case .missingLLDBExecutable(let path):
            "The selected Xcode-bundled LLDB is not executable: \(path)"
        case .processLaunchFailed(let reason):
            "The selected Xcode-bundled LLDB could not start: \(reason)"
        case .invalidProcessState:
            "The retained LLDB adapter process is not in the required lifecycle state."
        case .inputSignalProtectionFailed(let code):
            "The retained LLDB adapter input could not suppress SIGPIPE: \(Self.posixMessage(code))"
        case .adapterNotRunning:
            "The retained LLDB adapter process is not running."
        case .inputClosed:
            "The retained LLDB adapter input is closed."
        case .inputWriteFailed(let code):
            "The retained LLDB adapter input write failed: \(Self.posixMessage(code))"
        case .writeTooLarge:
            "The LLDB adapter write exceeds the frozen command bound."
        case .readBufferOverflow:
            "The LLDB adapter produced more unread output than the frozen exchange bound."
        case .multipleReaders:
            "The LLDB adapter permits exactly one continuous read pump."
        }
    }

    private static func posixMessage(_ code: Int32) -> String {
        String(cString: Darwin.strerror(code))
    }
}

/// Immutable, validated launch authority for the one persistent CLI process.
struct PersistentLLDBCLIProcessLaunchPlan: Sendable, Equatable {
    /// A trusted startup-only command. If LLDB cannot enter asynchronous mode, it terminates the
    /// adapter before stdin is consumed, so no queued target-creation or launch command can run.
    /// `os._exit` is intentionally scoped to the retained LLDB child, never the debug target.
    static let requireAsyncModeCommand =
        "script lldb.debugger.SetAsync(True); __import__('os')._exit(86) if not lldb.debugger.GetAsync() else None"

    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String
    let usesMergedOrderedOutput: Bool

    private init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.usesMergedOrderedOutput = true
    }

    static func make(
        lldbExecutablePath: String,
        developerDirectory: String,
        environment: [String: String],
        workingDirectory: String
    ) throws -> PersistentLLDBCLIProcessLaunchPlan {
        let developerURL = URL(fileURLWithPath: developerDirectory).standardizedFileURL
        let lldbURL = URL(fileURLWithPath: lldbExecutablePath).standardizedFileURL
        let workingURL = URL(fileURLWithPath: workingDirectory).standardizedFileURL

        guard developerDirectory.hasPrefix("/"), developerURL.path.hasPrefix("/") else {
            throw PersistentLLDBCLIProcessChannelError.invalidDeveloperDirectory
        }
        let developerPrefix = developerURL.path.hasSuffix("/")
            ? developerURL.path
            : developerURL.path + "/"
        guard lldbExecutablePath.hasPrefix("/"),
              lldbURL.path.hasPrefix(developerPrefix),
              lldbURL.lastPathComponent == "lldb",
              !lldbExecutablePath.components(separatedBy: "/").contains("..") else {
            throw PersistentLLDBCLIProcessChannelError.lldbOutsideSelectedXcode
        }
        guard workingDirectory.hasPrefix("/"), workingURL.path.hasPrefix("/") else {
            throw PersistentLLDBCLIProcessChannelError.invalidWorkingDirectory
        }

        var resolvedEnvironment = environment
        resolvedEnvironment["DEVELOPER_DIR"] = developerURL.path
        return PersistentLLDBCLIProcessLaunchPlan(
            executablePath: lldbURL.path,
            arguments: [
                "--no-lldbinit",
                "--one-line",
                "settings set interpreter.echo-commands false",
                "--one-line",
                requireAsyncModeCommand,
            ],
            environment: resolvedEnvironment,
            workingDirectory: workingURL.path
        )
    }
}

/// Retains the exact Process and the three pipes before launch. The same output pipe is installed
/// for stdout and stderr, giving the decoder one kernel-ordered byte stream. No second stream can
/// author status, and no cross-pipe chronology is inferred after the fact.
final class FoundationPersistentLLDBCLIConfiguredProcess: @unchecked Sendable {
    let process: Process
    let inputPipe: Pipe
    let outputPipe: Pipe

    init(process: Process, inputPipe: Pipe, outputPipe: Pipe) {
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
    }
}

/// Concrete retained Xcode-LLDB process plus its asynchronous byte channel.
///
/// The actor is the sole owner after launch. Its only signal methods operate on the retained
/// `Process` instance and captured adapter PID; it never records or signals a target PID, process
/// name, process group, or descendant inventory.
actor FoundationPersistentLLDBCLIProcessChannel:
    PersistentLLDBCLIByteChannel,
    PersistentLLDBCLIRetainedProcess,
    DebuggerOwnedInfrastructureRetainedProcessBinding,
    PersistentLLDBOwnedPreparedProcessChannel
{
    private enum ProcessState: Sendable {
        case prepared
        case launching
        case launchFailed
        case launchedIdentityUnknown(processID: Int32)
        case running(processID: Int32)
        case exited(processID: Int32)
        case reaped(processID: Int32)
    }

    private static let maximumUnreadByteCount = LLDBCLITranscriptDecoder.maximumExchangeBytes
    private let process: Process
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private var processState: ProcessState = .prepared

    private var pendingReads: [Data] = []
    private var pendingReadByteCount = 0
    private var readWaiter: CheckedContinuation<Data?, Error>?
    private var terminalReadError: PersistentLLDBCLIProcessChannelError?
    private var reachedEOF = false
    private var inputIsClosed = false
    private var handlesAreClosed = false
    private var observedTermination = false
    private var readerTask: Task<Void, Never>?

    private init(configured: FoundationPersistentLLDBCLIConfiguredProcess) {
        self.process = configured.process
        self.inputPipe = configured.inputPipe
        self.outputPipe = configured.outputPipe
        self.inputHandle = configured.inputPipe.fileHandleForWriting
        self.outputHandle = configured.outputPipe.fileHandleForReading
    }

    static func launch(
        plan: PersistentLLDBCLIProcessLaunchPlan
    ) async throws -> FoundationPersistentLLDBCLIProcessChannel {
        let channel = try prepare(plan: plan)
        try await channel.launchPreparedProcess()
        return channel
    }

    static func prepare(
        plan: PersistentLLDBCLIProcessLaunchPlan
    ) throws -> FoundationPersistentLLDBCLIProcessChannel {
        guard FileManager.default.isExecutableFile(atPath: plan.executablePath) else {
            throw PersistentLLDBCLIProcessChannelError.missingLLDBExecutable(plan.executablePath)
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: plan.workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PersistentLLDBCLIProcessChannelError.invalidWorkingDirectory
        }

        let configured = try configureProcess(for: plan)
        return FoundationPersistentLLDBCLIProcessChannel(configured: configured)
    }

    func launchPreparedProcess() async throws {
        guard case .prepared = processState else {
            throw PersistentLLDBCLIProcessChannelError.invalidProcessState
        }
        processState = .launching
        let process = self.process
        do {
            try await Task.detached(priority: .userInitiated) {
                try process.run()
            }.value
        } catch {
            processState = .launchFailed
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            throw PersistentLLDBCLIProcessChannelError.processLaunchFailed(
                error.localizedDescription
            )
        }

        let processID = process.processIdentifier
        guard processID > 1 else {
            processState = .launchedIdentityUnknown(processID: processID)
            throw PersistentLLDBCLIProcessChannelError.processLaunchFailed(
                "The retained process did not publish a valid child PID."
            )
        }
        processState = .running(processID: processID)
        installHandlers()
    }

    static func configureProcess(
        for plan: PersistentLLDBCLIProcessLaunchPlan
    ) throws -> FoundationPersistentLLDBCLIConfiguredProcess {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let inputDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        guard Darwin.fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            let code = Darwin.errno
            try? inputPipe.fileHandleForWriting.close()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            throw PersistentLLDBCLIProcessChannelError.inputSignalProtectionFailed(code)
        }
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        return FoundationPersistentLLDBCLIConfiguredProcess(
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe
        )
    }

    /// Writes the complete bounded command without allowing a closed LLDB stdin to signal the
    /// MacScope process. `configureProcess` establishes descriptor-local `F_SETNOSIGPIPE` before
    /// this function can be reached.
    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written > 0 {
                    address = address.advanced(by: written)
                    remaining -= written
                    continue
                }
                if written == -1, Darwin.errno == EINTR {
                    continue
                }
                let code = Darwin.errno
                if code == EPIPE || code == EBADF {
                    throw PersistentLLDBCLIProcessChannelError.inputClosed
                }
                throw PersistentLLDBCLIProcessChannelError.inputWriteFailed(code)
            }
        }
    }

    var retainedProcessIdentifier: Int32 {
        switch processState {
        case .launchedIdentityUnknown(let processID), .running(let processID),
             .exited(let processID), .reaped(let processID):
            processID
        case .prepared, .launching, .launchFailed:
            0
        }
    }

    var isRetainedAdapterRunning: Bool {
        switch processState {
        case .running(let processID):
            return process.processIdentifier == processID
                && process.isRunning
                && !observedTermination
        case .launchedIdentityUnknown:
            return process.isRunning && !observedTermination
        case .prepared, .launching, .launchFailed, .exited, .reaped:
            return false
        }
    }

    func write(_ data: Data) async throws {
        guard data.count <= LLDBCLITranscriptDecoder.maximumCommandBytes else {
            throw PersistentLLDBCLIProcessChannelError.writeTooLarge
        }
        guard !inputIsClosed else {
            throw PersistentLLDBCLIProcessChannelError.inputClosed
        }
        guard isRetainedAdapterRunning else {
            throw PersistentLLDBCLIProcessChannelError.adapterNotRunning
        }
        try Self.writeAll(data, to: inputHandle.fileDescriptor)
    }

    func nextBytes() async throws -> Data? {
        if let terminalReadError {
            throw terminalReadError
        }
        if !pendingReads.isEmpty {
            let data = pendingReads.removeFirst()
            pendingReadByteCount -= data.count
            return data
        }
        if reachedEOF || handlesAreClosed {
            return nil
        }
        guard readWaiter == nil else {
            throw PersistentLLDBCLIProcessChannelError.multipleReaders
        }
        return try await withCheckedThrowingContinuation { continuation in
            readWaiter = continuation
        }
    }

    func closeInput() async {
        guard !inputIsClosed else { return }
        inputIsClosed = true
        try? inputHandle.close()
    }

    func closeHandles() async {
        await closeHandlesAndReader()
    }

    func waitForExit(maximumDuration: Duration) async -> Bool {
        guard maximumDuration > .zero else {
            return !isRetainedAdapterRunning
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while isRetainedAdapterRunning, clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            do {
                try await clock.sleep(for: min(remaining, .milliseconds(10)))
            } catch {
                break
            }
        }
        return !isRetainedAdapterRunning
    }

    func terminateRetainedAdapter() async {
        guard isRetainedAdapterRunning else { return }
        process.terminate()
    }

    func killRetainedAdapterIfStillRunning() async -> Bool {
        guard isRetainedAdapterRunning else { return false }
        let retainedPID = retainedProcessIdentifier
        guard retainedPID > 1 else { return false }
        // The retained Process has not been reaped while `isRunning` is true, so this PID still
        // denotes the exact child. No target PID or name-derived lookup reaches this call.
        return Darwin.kill(pid_t(retainedPID), SIGKILL) == 0
    }

    func reapAndClose() async -> Bool {
        guard !isRetainedAdapterRunning else { return false }
        let processID: Int32
        switch processState {
        case .launchedIdentityUnknown(let retainedProcessID),
             .running(let retainedProcessID), .exited(let retainedProcessID):
            processID = retainedProcessID
        case .prepared, .launching, .launchFailed, .reaped:
            return false
        }
        process.terminationHandler = nil
        process.waitUntilExit()
        observedTermination = true
        processState = .reaped(processID: processID)
        await closeHandlesAndReader()
        return true
    }

    func retainedProcessIdentifierForInfrastructure() async -> Int32 {
        retainedProcessIdentifier
    }

    func retainedProcessIsRunningForInfrastructure() async -> Bool {
        isRetainedAdapterRunning
    }

    func retainedProcessDispositionForInfrastructure() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition {
        switch processState {
        case .prepared, .launchFailed:
            .notLaunched
        case .launching, .launchedIdentityUnknown:
            .unknown
        case .running:
            isRetainedAdapterRunning ? .running : .unknown
        case .exited:
            .unknown
        case .reaped:
            .exitedAndReaped
        }
    }

    private func installHandlers() {
        process.terminationHandler = { [weak self] _ in
            Task { await self?.recordTermination() }
        }
        let outputHandle = self.outputHandle
        readerTask = Task.detached(priority: .userInitiated) { [weak self, outputHandle] in
            while !Task.isCancelled {
                let data = outputHandle.availableData
                guard !data.isEmpty else {
                    await self?.recordEOF()
                    return
                }
                guard await self?.acceptSequentialRead(data) == true else {
                    return
                }
            }
        }
    }

    private func recordTermination() {
        observedTermination = true
        if case let .running(processID) = processState {
            processState = .exited(processID: processID)
        } else if case let .launchedIdentityUnknown(processID) = processState {
            processState = .exited(processID: processID)
        }
    }

    private func acceptSequentialRead(_ data: Data) -> Bool {
        guard !handlesAreClosed, terminalReadError == nil, !reachedEOF else { return false }

        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: data)
            return true
        }

        let nextCount = pendingReadByteCount.addingReportingOverflow(data.count)
        guard !nextCount.overflow,
              nextCount.partialValue <= Self.maximumUnreadByteCount else {
            terminalReadError = .readBufferOverflow
            pendingReads.removeAll()
            pendingReadByteCount = 0
            return false
        }
        pendingReads.append(data)
        pendingReadByteCount = nextCount.partialValue
        return true
    }

    private func recordEOF() {
        guard !handlesAreClosed, terminalReadError == nil else { return }
        reachedEOF = true
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: nil)
        }
    }

    private func closeHandlesAndReader() async {
        if handlesAreClosed {
            if let readerTask {
                await readerTask.value
                self.readerTask = nil
            }
            return
        }
        handlesAreClosed = true
        inputIsClosed = true
        let readerTask = self.readerTask
        readerTask?.cancel()
        try? inputHandle.close()
        try? outputHandle.close()
        pendingReads.removeAll()
        pendingReadByteCount = 0
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: nil)
        }
        if let readerTask {
            await readerTask.value
        }
        self.readerTask = nil
    }
}

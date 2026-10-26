import Darwin
import Foundation

// LLDB backend adapter, command-session transport and process runner (split out of
// LocalLLDBDebuggerClient.swift so the debugger engine compiles without the app's runtime authorities).


@MainActor
protocol LLDBDebuggerBackendAdapter {
    func shutdown() async
    var capabilities: DebuggerCapabilityReport { get }
    var initialBackendState: DebuggerBackendSessionState { get }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot
    func attach(_ request: DebuggerLocalAttachRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
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
    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
}

extension LLDBDebuggerBackendAdapter {
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
            "Typed logical-breakpoint reconciliation is not supported by this LLDB adapter."
        )
    }

    /// Default step-into / step-out report the unsupported posture, mirroring the
    /// `DebuggerClient` defaults so that pre-existing adapter doubles keep
    /// compiling. The real `XcodeLLDBCommandLineAdapter` overrides both to issue
    /// `thread step-in` / `thread step-out` through the live command session.
    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Step into is not supported for this target.")
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Step out is not supported for this target.")
    }

    /// Default run-to-cursor reports the unsupported posture, mirroring the
    /// step-into/out defaults so that pre-existing adapter doubles keep compiling.
    /// `XcodeLLDBCommandLineAdapter` overrides this to set a temporary one-shot
    /// breakpoint at the cursor and `process continue` through the live session.
    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Run to cursor is not supported for this target.")
    }

    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Register write is not supported for this target.")
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Memory read is not supported for this target.")
    }

    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Memory write is not supported for this target.")
    }

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
            "Variable child expansion is not supported for this LLDB adapter."
        )
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Thread selection is not supported for this target.")
    }

    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Frame selection is not supported for this target.")
    }

    /// Exact local-process attach defaults to unsupported so an adapter must opt
    /// into the identity-bound transaction explicitly.
    func attach(
        _ request: DebuggerLocalAttachRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Exact local-process attach is not supported by this LLDB adapter."
        )
    }

    /// Raw PID attach has no backend transport. It remains only as a temporary
    /// source-compatibility seam for callers that have not adopted exact identity.
    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Raw PID attach is disabled; an exact local-process identity is required."
        )
    }

    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation(
            "Live process-status observation is not supported for this target."
        )
    }

    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation("Detach is not supported for this target.")
    }
}

protocol DebuggerProcessRunning {
    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult
}

struct DebuggerBatchLaunchTranscript: Equatable {
    var targetProcessID: Int32?
    var targetExitStatus: Int32?
    var targetState: DebuggerBatchTargetState
    var diagnosticSummary: String?
}

struct DebuggerLLDBCommandResponse: Equatable {
    var command: String
    var standardOutput: String
    var standardError: String
    var timedOut: Bool

    init(
        command: String,
        standardOutput: String,
        standardError: String = "",
        timedOut: Bool = false
    ) {
        self.command = command
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

protocol DebuggerLLDBCommandSessionTransport: AnyObject {
    func start(_ command: DebuggerExternalCommand) throws
    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse
    func stop()
}

typealias DebuggerLLDBCommandSessionFactory = () -> any DebuggerLLDBCommandSessionTransport

enum DebuggerLLDBCommandSessionError: LocalizedError, Equatable {
    case notStarted
    case startFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "LLDB command session is not running."
        case .startFailed(let reason), .writeFailed(let reason):
            reason
        }
    }
}

final class FoundationLLDBCommandSessionTransport: DebuggerLLDBCommandSessionTransport, @unchecked Sendable {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    /// Signalled by the current process's `terminationHandler`; `stop()` waits on it instead of
    /// `waitUntilExit()`, which would spin the caller's run loop.
    private var exited: DispatchSemaphore?
    private var outputData = Data()
    private var errorData = Data()
    private let lock = NSLock()

    deinit {
        stop()
    }

    func start(_ command: DebuggerExternalCommand) throws {
        stop()

        guard FileManager.default.isExecutableFile(atPath: command.executablePath) else {
            throw DebuggerProcessRunnerError.missingExecutable(command.executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = command.environment
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendOutput(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendError(data)
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw DebuggerLLDBCommandSessionError.startFailed(error.localizedDescription)
        }

        self.process = process
        self.exited = exited
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
    }

    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse {
        guard let process, process.isRunning, let inputPipe else {
            throw DebuggerLLDBCommandSessionError.notStarted
        }

        let marker = "__MACSCOPE_LLDB_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let outputStart = outputCount
        let errorStart = errorCount
        let payload = "\(command)\nscript print(\"\(marker)\")\n"

        guard let payloadData = payload.data(using: .utf8) else {
            throw DebuggerLLDBCommandSessionError.writeFailed("Could not encode LLDB command.")
        }
        inputPipe.fileHandleForWriting.write(payloadData)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let output = outputString(from: outputStart)
            let error = errorString(from: errorStart)
            if output.contains(marker) || error.contains(marker) {
                return DebuggerLLDBCommandResponse(
                    command: command,
                    standardOutput: cleanCommandOutput(output, marker: marker),
                    standardError: cleanCommandOutput(error, marker: marker),
                    timedOut: false
                )
            }

            if !process.isRunning {
                return DebuggerLLDBCommandResponse(
                    command: command,
                    standardOutput: cleanCommandOutput(output, marker: marker),
                    standardError: cleanCommandOutput(error, marker: marker),
                    timedOut: false
                )
            }

            Thread.sleep(forTimeInterval: 0.02)
        }

        return DebuggerLLDBCommandResponse(
            command: command,
            standardOutput: cleanCommandOutput(outputString(from: outputStart), marker: marker),
            standardError: cleanCommandOutput(errorString(from: errorStart), marker: marker),
            timedOut: true
        )
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            if let exited {
                FoundationDebuggerProcessRunner.terminateAndReap(process, finished: exited)
            } else {
                process.terminate()
            }
        }

        process = nil
        exited = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil

        lock.lock()
        outputData.removeAll(keepingCapacity: false)
        errorData.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private var outputCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outputData.count
    }

    private var errorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return errorData.count
    }

    private func appendOutput(_ data: Data) {
        lock.lock()
        outputData.append(data)
        lock.unlock()
    }

    private func appendError(_ data: Data) {
        lock.lock()
        errorData.append(data)
        lock.unlock()
    }

    private func outputString(from offset: Int) -> String {
        lock.lock()
        let data = outputData.dropFirst(min(offset, outputData.count))
        lock.unlock()
        return String(data: Data(data), encoding: .utf8) ?? ""
    }

    private func errorString(from offset: Int) -> String {
        lock.lock()
        let data = errorData.dropFirst(min(offset, errorData.count))
        lock.unlock()
        return String(data: Data(data), encoding: .utf8) ?? ""
    }

    private func cleanCommandOutput(_ text: String, marker: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.contains(marker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DebuggerProcessRunnerError: LocalizedError, Equatable {
    case missingExecutable(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            "No executable exists at \(path)."
        case .launchFailed(let reason):
            reason
        }
    }
}

struct FoundationDebuggerProcessRunner: DebuggerProcessRunning {
    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult {
        guard FileManager.default.isExecutableFile(atPath: command.executablePath) else {
            throw DebuggerProcessRunnerError.missingExecutable(command.executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = command.environment
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        // Installed before run(): a counting semaphore keeps the signal of a child that exits
        // before the first wait, so an early exit is never missed.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            throw DebuggerProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes while the child runs. Reading only after exit deadlocks once
        // the child writes more than the ~64 KB pipe buffer: it blocks in write() and never
        // exits, which surfaced as a spurious timeout with truncated output.
        let outputDrain = DebuggerSubprocessPipeDrain(standardOutput.fileHandleForReading)
        let errorDrain = DebuggerSubprocessPipeDrain(standardError.fileHandleForReading)

        // Every wait here blocks on the termination semaphore and never runs the caller's run
        // loop. `Process.waitUntilExit()` spins the current run loop; on the main thread during
        // a SwiftUI update that re-entered AppKit layout and aborted in AttributeGraph.
        let timeout = DispatchTime.now() + .milliseconds(Int(command.timeoutSeconds * 1000))
        let timedOut = finished.wait(timeout: timeout) == .timedOut
        if timedOut {
            Self.terminateAndReap(process, finished: finished)
        }

        // A descendant that inherited the pipe can hold it open after the child exits; bound
        // the join and keep whatever was read instead of waiting for an EOF that never comes.
        let drainDeadline = DispatchTime.now() + .seconds(5)
        let outputData = outputDrain.finish(deadline: drainDeadline)
        let errorData = errorDrain.finish(deadline: drainDeadline)

        return DebuggerSubprocessResult(
            terminationStatus: timedOut ? -1 : process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self),
            timedOut: timedOut
        )
    }

    /// Terminates a still-running child and waits for its exit on `finished`, the semaphore its
    /// `terminationHandler` signals, without running any run loop. SIGTERM gets a 1 s grace,
    /// then SIGKILL and a further bounded wait; the handler fires only after Foundation has
    /// reaped the child. Returns whether the exit was observed within the bounds.
    @discardableResult
    static func terminateAndReap(
        _ process: Process,
        finished: DispatchSemaphore,
        graceSeconds: Double = 1,
        killWaitSeconds: Double = 5
    ) -> Bool {
        process.terminate()
        if finished.wait(timeout: .now() + graceSeconds) == .success { return true }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        return finished.wait(timeout: .now() + killWaitSeconds) == .success
    }
}

/// Drains without blocking indefinitely on a pipe inherited by a descendant. Capture is
/// bounded independently from draining, so excess output cannot fill either child pipe.
final class DebuggerSubprocessPipeDrain: @unchecked Sendable {
    static let maximumCapturedBytes = 8 * 1_024 * 1_024
    static let truncationMarker = Data("\n[MacScope subprocess output truncated]\n".utf8)
    private let handle: FileHandle
    private let captureLimit: Int
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()
    private var cancelled = false
    private var truncated = false

    init(_ handle: FileHandle, maximumCapturedBytes: Int = DebuggerSubprocessPipeDrain.maximumCapturedBytes) {
        self.handle = handle
        captureLimit = max(0, min(maximumCapturedBytes, Self.maximumCapturedBytes))
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                group.leave()
            }
            readToEndOfFile()
        }
    }

    var isFinished: Bool { group.wait(timeout: .now()) == .success }

    /// The reader owns descriptor closure. Cancellation cannot close a descriptor under a
    /// concurrent read, and the nonblocking reader observes it within one short poll interval.
    func finish(deadline: DispatchTime) -> Data {
        if group.wait(timeout: deadline) == .timedOut {
            lock.lock()
            cancelled = true
            lock.unlock()
            _ = group.wait(timeout: .now() + .milliseconds(100))
        }
        lock.lock()
        defer { lock.unlock() }
        return truncated ? captured + Self.truncationMarker : captured
    }

    private func readToEndOfFile() {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            lock.lock()
            let shouldStop = cancelled
            lock.unlock()
            if shouldStop { return }
            let byteCount = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if byteCount > 0 {
                lock.lock()
                let retainedCount = min(byteCount, captureLimit - captured.count)
                captured.append(contentsOf: buffer.prefix(retainedCount))
                truncated = truncated || retainedCount < byteCount
                lock.unlock()
                continue
            }
            if byteCount == 0 { return }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return }
            var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptorEvent, 1, 20)
            if result < 0, errno != EINTR { return }
        }
    }
}

/// Process-wide memo of the LLDB capability-proof subprocess run, keyed by the exact proof
/// command (executable, arguments, reduced environment, working directory, timeout; the
/// persistent-CLI requirement is part of the arguments).
///
/// The proof used to run synchronously inside every production adapter initializer, which
/// SwiftUI reaches from `EditorSurfaceView`'s `StateObject` autoclosure during a graph update.
/// The app now starts the proof on a background queue at launch (`prewarm`), and each client
/// reads the memoized subprocess result. Only the raw `DebuggerSubprocessResult` is cached;
/// every adapter still parses and publishes it and builds its own capability report, so report
/// content and the per-client authority graph are unchanged.
///
/// A completed run is memoized for the process lifetime. A timed-out run or a runner error is
/// returned to the callers that shared it but not memoized, so a later client retries instead
/// of inheriting a transient failure from a loaded launch. A caller that finds the proof in
/// flight blocks on a condition variable (never a run loop) for at most the runner's own worst
/// case plus a margin, then reports a timeout for itself.
///
/// Only the production adapter initializers use `shared`. Injected-runner constructions pass no
/// cache and run their runner directly, so tests stay deterministic.
final class DebuggerLLDBProofCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: String?
        let timeoutSeconds: TimeInterval

        init(_ command: DebuggerExternalCommand) {
            executablePath = command.executablePath
            arguments = command.arguments
            environment = command.environment
            workingDirectory = command.workingDirectory
            timeoutSeconds = command.timeoutSeconds
        }
    }

    typealias Outcome = Result<DebuggerSubprocessResult, any Error>

    static let shared = DebuggerLLDBProofCache()

    /// Runner worst case beyond the command timeout: 1 s SIGTERM grace, 5 s post-SIGKILL wait,
    /// 5 s pipe-drain join, plus scheduling margin.
    static let inFlightWaitMarginSeconds: TimeInterval = 15

    /// Guarded by `condition`.
    private final class Entry: @unchecked Sendable {
        var outcome: Outcome?
    }

    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    private var runCount = 0

    init() {}

    /// Number of proof runs this cache has started; test observation only.
    var runCountForTesting: Int {
        condition.lock()
        defer { condition.unlock() }
        return runCount
    }

    /// Returns the memoized result for `command`, joins an in-flight run, or runs `run` on the
    /// calling thread when no run exists. Never spins a run loop.
    func result(
        for command: DebuggerExternalCommand,
        run: () throws -> DebuggerSubprocessResult
    ) throws -> DebuggerSubprocessResult {
        let key = Key(command)
        let (entry, isOwner) = begin(key)
        if isOwner {
            let outcome: Outcome
            do {
                outcome = .success(try run())
            } catch {
                outcome = .failure(error)
            }
            complete(entry, key: key, outcome: outcome)
            return try outcome.get()
        }
        let waitBound = max(command.timeoutSeconds, 0) + Self.inFlightWaitMarginSeconds
        return try wait(for: entry, until: Date().addingTimeInterval(waitBound)).get()
    }

    /// Registers the run synchronously, so a client built immediately afterwards joins it, then
    /// performs it on a background queue. A no-op when the command is memoized or in flight.
    func prewarm(
        _ command: DebuggerExternalCommand,
        run: @escaping @Sendable () throws -> DebuggerSubprocessResult
    ) {
        let key = Key(command)
        let (entry, isOwner) = begin(key)
        guard isOwner else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome: Outcome
            do {
                outcome = .success(try run())
            } catch {
                outcome = .failure(error)
            }
            complete(entry, key: key, outcome: outcome)
        }
    }

    private func begin(_ key: Key) -> (Entry, isOwner: Bool) {
        condition.lock()
        defer { condition.unlock() }
        if let existing = entries[key] {
            return (existing, false)
        }
        let entry = Entry()
        entries[key] = entry
        runCount += 1
        return (entry, true)
    }

    private func complete(_ entry: Entry, key: Key, outcome: Outcome) {
        condition.lock()
        entry.outcome = outcome
        let memoize: Bool
        switch outcome {
        case .success(let result): memoize = !result.timedOut
        case .failure: memoize = false
        }
        if !memoize, entries[key] === entry {
            entries[key] = nil
        }
        condition.broadcast()
        condition.unlock()
    }

    private func wait(for entry: Entry, until deadline: Date) -> Outcome {
        condition.lock()
        defer { condition.unlock() }
        while entry.outcome == nil {
            if !condition.wait(until: deadline) { break }
        }
        return entry.outcome ?? .success(DebuggerSubprocessResult(
            terminationStatus: -1,
            standardOutput: "",
            standardError: "",
            timedOut: true
        ))
    }
}

struct XcodeLLDBCommandLineAdapter: LLDBDebuggerBackendAdapter {
    func shutdown() async { await persistentController?.shutdown() }
    static let persistentCapabilityProofMarker = "__MACSCOPE_LLDB_PERSISTENT_READY__"

    static let attachUnsupportedReason =
        "Arbitrary process attach remains disabled until exact-identity UI selection, shared lease authority, production controller wiring, and terminal recovery proof are complete."

    static let batchControlUnsupportedReason =
        "Execution control is disabled in batch mode because LLDB exits after transcript capture; use live launch only when a persistent command-session transport is available."

    let capabilities: DebuggerCapabilityReport
    let initialBackendState: DebuggerBackendSessionState
    private let toolchain: DebuggerLLDBToolchain?
    private let processRunner: any DebuggerProcessRunning
    private let environment: [String: String]
    private let workingDirectory: String
    private let launchTimeoutSeconds: TimeInterval
    /// The production path owns the hardened persistent CLI transport and its typed reducer.
    /// The legacy controller remains available only through the explicit injected-session seam
    /// used by the existing deterministic compatibility tests.
    private let persistentController: PersistentLLDBProductionController?
    private let legacyLiveController: XcodeLLDBLiveCommandController?

    init(inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil) {
        self.init(
            toolchain: XcodeLLDBCommandLineAdapter.discoverLLDBToolchain(),
            processRunner: FoundationDebuggerProcessRunner(),
            usePersistentTransport: true,
            inboundNeedleProbe: inboundNeedleProbe,
            proofCache: .shared
        )
    }

    init(
        debuggerSessionLeaseRegistry: DebuggerSessionLeaseRegistry,
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry? = nil,
        observationPolicyProvider: DebuggerLocalProcessObservationPolicyProvider? = nil,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil
    ) {
        self.init(
            toolchain: XcodeLLDBCommandLineAdapter.discoverLLDBToolchain(),
            processRunner: FoundationDebuggerProcessRunner(),
            usePersistentTransport: true,
            inboundNeedleProbe: inboundNeedleProbe,
            debuggerSessionLeaseRegistry: debuggerSessionLeaseRegistry,
            ownedInfrastructureRegistry: ownedInfrastructureRegistry,
            observationPolicyProvider: observationPolicyProvider,
            proofCache: .shared
        )
    }

    init(
        lldbExecutablePath: String?,
        processRunner: any DebuggerProcessRunning = FoundationDebuggerProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        launchTimeoutSeconds: TimeInterval = 10,
        liveSessionFactory: DebuggerLLDBCommandSessionFactory? = nil,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil,
        debuggerSessionLeaseRegistry: DebuggerSessionLeaseRegistry? = nil,
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry? = nil,
        observationPolicyProvider: DebuggerLocalProcessObservationPolicyProvider? = nil
    ) {
        let toolchain = lldbExecutablePath.map {
            XcodeLLDBCommandLineAdapter.makeToolchain(
                executablePath: $0,
                discoverySource: "explicit",
                candidatePaths: [$0],
                environment: environment
            )
        }
        self.init(
            toolchain: toolchain,
            processRunner: processRunner,
            environment: environment,
            workingDirectory: workingDirectory,
            launchTimeoutSeconds: launchTimeoutSeconds,
            liveSessionFactory: liveSessionFactory,
            usePersistentTransport: false,
            inboundNeedleProbe: inboundNeedleProbe,
            debuggerSessionLeaseRegistry: debuggerSessionLeaseRegistry,
            ownedInfrastructureRegistry: ownedInfrastructureRegistry,
            observationPolicyProvider: observationPolicyProvider
        )
    }

    init(
        toolchain: DebuggerLLDBToolchain?,
        processRunner: any DebuggerProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        launchTimeoutSeconds: TimeInterval = 10,
        liveSessionFactory: DebuggerLLDBCommandSessionFactory? = nil,
        usePersistentTransport: Bool = false,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil,
        debuggerSessionLeaseRegistry: DebuggerSessionLeaseRegistry? = nil,
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry? = nil,
        observationPolicyProvider: DebuggerLocalProcessObservationPolicyProvider? = nil,
        proofCache: DebuggerLLDBProofCache? = nil
    ) {
        self.toolchain = toolchain
        self.processRunner = processRunner
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.launchTimeoutSeconds = launchTimeoutSeconds
        if let toolchain, usePersistentTransport {
            self.persistentController = PersistentLLDBProductionController(
                toolchain: toolchain,
                environment: environment,
                fallbackWorkingDirectory: workingDirectory,
                commandTimeoutSeconds: launchTimeoutSeconds,
                inboundNeedleProbe: inboundNeedleProbe,
                debuggerSessionLeaseRegistry: debuggerSessionLeaseRegistry,
                ownedInfrastructureRegistry: ownedInfrastructureRegistry,
                observationPolicyProvider: observationPolicyProvider
            )
        } else {
            self.persistentController = nil
        }
        if let toolchain, !usePersistentTransport, let liveSessionFactory {
            self.legacyLiveController = XcodeLLDBLiveCommandController(
                toolchain: toolchain,
                sessionFactory: liveSessionFactory,
                environment: environment,
                fallbackWorkingDirectory: workingDirectory,
                commandTimeoutSeconds: launchTimeoutSeconds
            )
        } else {
            self.legacyLiveController = nil
        }

        let proofResult = toolchain.map {
            XcodeLLDBCommandLineAdapter.runProof(
                toolchain: $0,
                processRunner: processRunner,
                environment: environment,
                workingDirectory: workingDirectory,
                requiresPersistentCLIProof: usePersistentTransport,
                proofCache: proofCache
            )
        }
        let capability = XcodeLLDBCommandLineAdapter.makeCapabilityReport(
            toolchain: toolchain,
            proofResult: proofResult,
            liveControlEnabled: persistentController != nil || legacyLiveController != nil,
            persistentAttachAuthorityReady:
                persistentController?.runtimeAuthorityProjectionForTesting
                    .isObservationPolicyAuthorityReady == true,
            persistentLaunchAuthorityUnavailableReason:
                usePersistentTransport && ownedInfrastructureRegistry == nil
                ? PersistentLLDBProductionController
                    .missingOwnedInfrastructureAuthorityReason
                : nil
        )
        self.capabilities = capability

        if let proofResult, proofResult.succeeded {
            let hasLiveTransport = persistentController != nil || legacyLiveController != nil
            self.initialBackendState = .ready(adapterName: hasLiveTransport ? "Xcode LLDB Live" : "Xcode LLDB Batch")
        } else if let proofResult {
            self.initialBackendState = .discovered(
                toolPath: proofResult.toolchain.executablePath
            )
        } else if let toolchain {
            self.initialBackendState = .discovered(
                toolPath: DebuggerPublishedDiagnosticText.project(
                    toolchain.executablePath
                ).text
            )
        } else {
            self.initialBackendState = .unavailable(reason: capability.summary)
        }
    }

    var sessionLeaseAuthorityForTesting: PersistentLLDBSessionLeaseAuthorityProjection? {
        persistentController?.sessionLeaseAuthorityForTesting
    }

    var persistentRuntimeAuthorityProjectionForTesting:
        PersistentLLDBRuntimeAuthorityProjection? {
        persistentController?.runtimeAuthorityProjectionForTesting
    }

    func observationPolicySnapshotForTesting() async
        -> DebuggerLocalProcessResolution<DebuggerLocalProcessObservationPolicySnapshot>?
    {
        await persistentController?.observationPolicySnapshotForTesting()
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        guard let toolchain else {
            throw unavailable("Cannot launch \(configuration.displayName): \(capabilities.launchSupport.unavailableReason ?? capabilities.summary)")
        }

        if let persistentController, capabilities.executionControlSupport.isSupported {
            var liveConfiguration = configuration
            liveConfiguration.initialBreakpoints = []
            return try await persistentController.launch(liveConfiguration)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            var liveConfiguration = configuration
            liveConfiguration.initialBreakpoints = []
            return try await legacyLiveController.launch(liveConfiguration)
        }

        try XcodeLLDBCommandLineAdapter.validateBatchLaunchConfiguration(configuration)
        let breakpointCommands = XcodeLLDBCommandLineAdapter.makeBreakpointCommands(
            for: configuration.initialBreakpoints
        )

        let command = XcodeLLDBCommandLineAdapter.makeBatchLaunchCommand(
            toolchain: toolchain,
            configuration: configuration,
            breakpointCommands: breakpointCommands,
            environment: environment,
            fallbackWorkingDirectory: workingDirectory,
            timeoutSeconds: launchTimeoutSeconds
        )

        do {
            let result = try processRunner.run(command)
            return XcodeLLDBCommandLineAdapter.makeBatchLaunchSnapshot(
                configuration: configuration,
                command: command,
                result: result
            )
        } catch {
            throw DebuggerClientError.backendFailure("LLDB batch launch could not start: \(error.localizedDescription)")
        }
    }

    func attach(
        _ request: DebuggerLocalAttachRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        guard let persistentController, capabilities.attachSupport.isSupported else {
            throw unavailable(
                "Exact local-process attach requires the checked persistent LLDB transport and a complete current attach authority graph."
            )
        }

        return try await persistentController.attach(request)
    }

    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Raw PID attach is disabled; an exact local-process identity is required."
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.continueExecution(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.continueExecution(from: snapshot)
        }

        throw unavailable("Continue is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.runToCursor(request, from: snapshot)
        }

        throw unavailable(
            "Run to cursor requires the checked persistent LLDB transport."
        )
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.stepOver(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.stepOver(from: snapshot)
        }

        throw unavailable("Step over is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.stepInto(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.stepInto(from: snapshot)
        }

        throw unavailable("Step into is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.stepOut(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.stepOut(from: snapshot)
        }

        throw unavailable("Step out is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.pause(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.pause(from: snapshot)
        }

        throw unavailable("Pause is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.detach(from: snapshot)
        }

        throw unavailable(
            "Detach requires an exact attached session on the checked persistent LLDB transport."
        )
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.terminate(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.terminate(from: snapshot)
        }

        throw unavailable("Terminate is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = breakpoints
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Live breakpoint mutation requires a validated logical-breakpoint resolution observation."
        )
    }

    func reconcileLogicalBreakpoints(
        _ request: DebuggerLogicalBreakpointReconcileRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        guard let persistentController else {
            throw unavailable(
                "Typed logical-breakpoint resolution requires the persistent LLDB controller."
            )
        }
        return try await persistentController.reconcileLogicalBreakpoints(
            request,
            from: snapshot
        )
    }

    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.writeRegister(request, from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.writeRegister(request, from: snapshot)
        }

        throw unavailable("Register write is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.readMemory(request, from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.readMemory(request, from: snapshot)
        }

        throw unavailable("Memory read is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func updateWatchpoints(_ request: DebuggerWatchpointRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard let persistentController, capabilities.executionControlSupport.isSupported else {
            throw unavailable("Watchpoints require the persistent LLDB controller.")
        }
        return try await persistentController.updateWatchpoints(request, from: snapshot)
    }

    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.writeMemory(request, from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.writeMemory(request, from: snapshot)
        }

        throw unavailable("Memory write is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.evaluateExpression(request, from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.evaluateExpression(request, from: snapshot)
        }

        throw unavailable("Expression evaluation is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func expandVariableChildren(
        _ request: DebuggerVariableExpansionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.expandVariableChildren(request, from: snapshot)
        }
        throw unavailable(
            "Variable child expansion is unavailable: "
                + (capabilities.executionControlSupport.unavailableReason
                    ?? capabilities.summary)
        )
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.selectThread(request, from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.selectThread(request, from: snapshot)
        }

        throw unavailable("Thread selection is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.selectFrame(request, from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.selectFrame(request, from: snapshot)
        }

        throw unavailable("Frame selection is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.refreshSnapshot(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.refreshSnapshot(from: snapshot)
        }

        throw unavailable("Snapshot refresh is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
    }

    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if let persistentController, capabilities.executionControlSupport.isSupported {
            return try await persistentController.pollProcessStatus(from: snapshot)
        }
        if let legacyLiveController, capabilities.executionControlSupport.isSupported {
            return try await legacyLiveController.pollProcessStatus(from: snapshot)
        }

        throw unavailable("Process-status observation is unavailable for this debugger transport.")
    }

    private func unavailable(_ reason: String) -> DebuggerClientError {
        .backendUnavailable(reason)
    }

    private static func makeCapabilityReport(
        toolchain: DebuggerLLDBToolchain?,
        proofResult: DebuggerLLDBProofResult?,
        liveControlEnabled: Bool = false,
        persistentAttachAuthorityReady: Bool = false,
        persistentLaunchAuthorityUnavailableReason: String? = nil
    ) -> DebuggerCapabilityReport {
        if toolchain != nil, let proofResult {
            let launchLimitation = "Launch uses a bounded Xcode LLDB batch subprocess and returns only a completed transcript, not a live debug session."
            let controlReason = XcodeLLDBCommandLineAdapter.batchControlUnsupportedReason
            let attachReason = XcodeLLDBCommandLineAdapter.attachUnsupportedReason
            let proofCommandLimitation = DebuggerPublishedDiagnosticText.project(
                "Proof command: \(proofResult.command.displayString)"
            ).text

            if proofResult.succeeded {
                if liveControlEnabled {
                    let publishedLaunchAuthorityReason =
                        persistentLaunchAuthorityUnavailableReason.map {
                            DebuggerPublishedDiagnosticText.project($0).text
                        }
                    let launchSupport: DebuggerOperationSupport =
                        publishedLaunchAuthorityReason.map {
                            .unsupported(reason: $0)
                        } ?? .supported
                    let attachSupport: DebuggerOperationSupport =
                        persistentAttachAuthorityReady
                        ? .supported
                        : .unsupported(reason: attachReason)
                    let liveTransportLimitation =
                        publishedLaunchAuthorityReason
                        ?? "Live launch owns a persistent LLDB command session for launch, continue, step-over, interrupt, breakpoint mutation, and stopped-state snapshot refresh commands."
                    let rawLiveAvailabilityDetails =
                        publishedLaunchAuthorityReason.map {
                            "\(proofResult.summary) \($0)"
                        }
                        ?? "\(proofResult.summary) Live launch and execution control are available."
                    let liveAvailabilityDetails = DebuggerPublishedDiagnosticText.project(
                        rawLiveAvailabilityDetails
                    ).text
                    return DebuggerCapabilityReport(
                        backendName: "Local LLDB",
                        isBackendAvailable: true,
                        canLaunch: launchSupport.isSupported,
                        canAttach: attachSupport.isSupported,
                        canControlExecution: true,
                        limitations: [
                            proofResult.summary,
                            proofCommandLimitation,
                            liveTransportLimitation,
                            persistentAttachAuthorityReady
                                ? "Exact local-process attach is available only through identity-bound process selection; raw PID/name attach remains disabled."
                                : "Paused live sessions can read a bounded 64-byte stack window. Attach remains disabled until the exact authority graph is current."
                        ],
                        entitlementNotes: [
                            "Debugging another process requires a signed entitlement and hardened-runtime review.",
                            "The initial proof probe runs only LLDB metadata commands.",
                            persistentAttachAuthorityReady
                                ? "Exact local-process attach requires reducer-admitted identity and non-killing detach; raw PID/name, remote, and wait-for-launch attach remain disabled."
                                : "Live launch starts only the provided executable from a MacScope-owned LLDB subprocess; no attach by pid/name, ptrace attach, or task_for_pid attach path is enabled."
                        ],
                        backendAvailability: .ready(
                            adapterName: "Xcode LLDB Live",
                            details: liveAvailabilityDetails
                        ),
                        launchSupport: launchSupport,
                        attachSupport: attachSupport,
                        executionControlSupport: .supported,
                        lldbProof: proofResult
                    )
                }

                return DebuggerCapabilityReport(
                    backendName: "Local LLDB",
                    isBackendAvailable: true,
                    canLaunch: true,
                    canAttach: false,
                    canControlExecution: false,
                    limitations: [
                        proofResult.summary,
                        proofCommandLimitation,
                        launchLimitation,
                        controlReason
                    ],
                    entitlementNotes: [
                        "Debugging another process requires a signed entitlement and hardened-runtime review.",
                        "The initial proof probe runs only LLDB metadata commands.",
                        "Batch launch starts only the provided executable in a short-lived LLDB subprocess; no attach by pid/name is enabled."
                    ],
                    backendAvailability: .ready(
                        adapterName: "Xcode LLDB Batch",
                        details: DebuggerPublishedDiagnosticText.project(
                            "\(proofResult.summary) Batch launch is available."
                        ).text
                    ),
                    launchSupport: .supported,
                    attachSupport: .unsupported(reason: attachReason),
                    executionControlSupport: .unsupported(reason: controlReason),
                    lldbProof: proofResult
                )
            }

            let details = proofResult.summary
            let probeReason = "LLDB was discovered, but the subprocess proof did not pass."

            return DebuggerCapabilityReport(
                backendName: "Local LLDB",
                isBackendAvailable: false,
                canLaunch: false,
                canAttach: false,
                canControlExecution: false,
                limitations: [
                    details,
                    proofCommandLimitation,
                    probeReason,
                    controlReason
                ],
                entitlementNotes: [
                    "Debugging another process requires a signed entitlement and hardened-runtime review.",
                    "The failed proof probe still performed no attach, ptrace, task_for_pid, process launch, or memory-read calls."
                ],
                backendAvailability: .discovered(
                    toolPath: proofResult.toolchain.executablePath,
                    details: details
                ),
                launchSupport: .unsupported(reason: probeReason),
                attachSupport: .unsupported(reason: attachReason),
                executionControlSupport: .unsupported(reason: controlReason),
                lldbProof: proofResult
            )
        }

        let reason = "No Xcode LLDB executable was found in the selected developer directory or standard Xcode locations."
        return DebuggerCapabilityReport(
            backendName: "Local LLDB",
            isBackendAvailable: false,
            canLaunch: false,
            canAttach: false,
            canControlExecution: false,
            limitations: [
                reason,
                "Launch, attach, stepping, registers, and memory reads are disabled until an LLDB backend adapter is attached."
            ],
            entitlementNotes: [
                "Debugging another process requires a signed entitlement and hardened-runtime review.",
                "This adapter intentionally performs no attach, ptrace, task_for_pid, process launch, or memory-read calls."
            ],
            backendAvailability: .unavailable(reason: reason),
            launchSupport: .unsupported(reason: reason),
            attachSupport: .unsupported(reason: reason),
            executionControlSupport: .unsupported(reason: reason)
        )
    }

    static func discoverLLDBExecutablePath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        discoverLLDBToolchain(fileManager: fileManager, environment: environment)?.executablePath
    }

    static func discoverLLDBToolchain(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DebuggerLLDBToolchain? {
        let candidates = candidateLLDBPaths(environment: environment)
        guard let executablePath = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) else { return nil }

        return makeToolchain(
            executablePath: executablePath,
            discoverySource: discoverySource(for: executablePath, environment: environment),
            candidatePaths: candidates,
            environment: environment
        )
    }

    static func candidateLLDBPaths(environment: [String: String]) -> [String] {
        var candidates: [String] = []

        if let developerDirectory = environment["DEVELOPER_DIR"], !developerDirectory.isEmpty {
            candidates.append(URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/lldb").path)
        }

        candidates.append(contentsOf: [
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/lldb",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb",
            "/usr/bin/lldb"
        ])

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    static func makeProofCommand(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String],
        workingDirectory: String,
        requiresPersistentCLIProof: Bool = false
    ) -> DebuggerExternalCommand {
        var arguments = [
            "--batch",
            "--no-lldbinit",
            "-o",
            "version",
            "-o",
            "platform status",
            "-o",
            "settings show target.default-arch",
        ]
        if requiresPersistentCLIProof {
            arguments += [
                "-o",
                PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand,
                "-o",
                "script r=lldb.SBCommandReturnObject(); lldb.debugger.GetCommandInterpreter().HandleCommand('settings show interpreter.echo-commands', r); __import__('os')._exit(87) if not r.Succeeded() else None; print('\(persistentCapabilityProofMarker)')",
            ]
        }
        return DebuggerExternalCommand(
            executablePath: toolchain.executablePath,
            arguments: arguments,
            environment: makeLLDBCommandEnvironment(toolchain: toolchain, environment: environment),
            workingDirectory: workingDirectory,
            timeoutSeconds: 5
        )
    }

    static func validateBatchLaunchConfiguration(
        _ configuration: DebuggerLaunchConfiguration,
        fileManager: FileManager = .default
    ) throws {
        try validateLaunchConfiguration(
            configuration,
            launchDescription: "LLDB batch launch",
            fileManager: fileManager
        )
    }

    static func validateLiveLaunchConfiguration(
        _ configuration: DebuggerLaunchConfiguration,
        fileManager: FileManager = .default
    ) throws {
        try validateLaunchConfiguration(
            configuration,
            launchDescription: "LLDB live launch",
            fileManager: fileManager
        )
    }

    private static func validateLaunchConfiguration(
        _ configuration: DebuggerLaunchConfiguration,
        launchDescription: String,
        fileManager: FileManager
    ) throws {
        let executablePath = configuration.normalizedExecutablePath
        guard !executablePath.isEmpty else {
            throw DebuggerClientError.invalidConfiguration("Choose an executable before launching \(launchDescription).")
        }

        guard executablePath.hasPrefix("/") else {
            throw DebuggerClientError.invalidConfiguration("\(launchDescription) requires an absolute executable path.")
        }

        guard fileManager.isExecutableFile(atPath: executablePath) else {
            throw DebuggerClientError.invalidConfiguration("No executable file exists at \(executablePath).")
        }

        if let workingDirectory = configuration.normalizedWorkingDirectory {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DebuggerClientError.invalidConfiguration("Working directory does not exist: \(workingDirectory).")
            }
        }

        try Self.validateLaunchArguments(configuration.arguments)
        try Self.validateLaunchEnvironment(configuration.normalizedEnvironment)
        try Self.validateBatchBreakpoints(configuration.initialBreakpoints)
    }

    static func makeBatchLaunchCommand(
        toolchain: DebuggerLLDBToolchain,
        configuration: DebuggerLaunchConfiguration,
        breakpointCommands: [String],
        environment: [String: String],
        fallbackWorkingDirectory: String,
        timeoutSeconds: TimeInterval
    ) -> DebuggerExternalCommand {
        let setupCommands = makeEnvironmentCommand(for: configuration.normalizedEnvironment).map { [$0] } ?? []
        let oneLineArguments = (setupCommands + breakpointCommands).flatMap { ["--one-line", $0] } + [
            "--one-line",
            "run",
            "--one-line",
            "process status",
            "--one-line-on-crash",
            "thread backtrace all"
        ]

        return DebuggerExternalCommand(
            executablePath: toolchain.executablePath,
            arguments: [
                "--batch",
                "--no-lldbinit"
            ] + oneLineArguments + [
                "--",
                configuration.normalizedExecutablePath
            ] + configuration.arguments,
            environment: makeLLDBCommandEnvironment(toolchain: toolchain, environment: environment),
            workingDirectory: configuration.normalizedWorkingDirectory ?? fallbackWorkingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func makeLiveSessionStartCommand(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String],
        workingDirectory: String,
        timeoutSeconds: TimeInterval
    ) -> DebuggerExternalCommand {
        DebuggerExternalCommand(
            executablePath: toolchain.executablePath,
            arguments: [
                "--no-lldbinit"
            ],
            environment: makeLLDBCommandEnvironment(toolchain: toolchain, environment: environment),
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func makeTargetCreateCommand(for configuration: DebuggerLaunchConfiguration) -> String {
        "target create \(quoteLLDBCommandArgument(configuration.normalizedExecutablePath))"
    }

    static func makeRunArgumentsCommand(for arguments: [String]) -> String? {
        guard !arguments.isEmpty else { return nil }
        return "settings set -- target.run-args " + arguments
            .map(quoteLLDBCommandArgument)
            .joined(separator: " ")
    }

    static func makeEnvironmentCommand(for environment: [String: String]) -> String? {
        guard !environment.isEmpty else { return nil }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return quoteLLDBCommandArgument("\(key)=\(value)")
        }
        guard !assignments.isEmpty else { return nil }
        // `--` terminates option parsing so an assignment whose key began with '-'
        // can't be misread as an LLDB flag (matches makeRunArgumentsCommand). The
        // authoring validator also rejects '-'-leading keys, so this is defense in depth.
        return "settings set -- target.env-vars " + assignments.joined(separator: " ")
    }

    nonisolated static let liveProcessStatusCommand = "process status"
    nonisolated static let liveBacktraceCommand = "thread backtrace"

    /// The full ARM64 general-purpose register file: the named control registers
    /// (`pc`/`sp`/`fp`/`lr`/`cpsr`) plus the complete `x0`–`x28` argument/temporary
    /// set.
    nonisolated static let liveGeneralPurposeRegisterNames: [String] =
        ["pc", "sp", "fp", "lr", "cpsr"] + (0...28).map { "x\($0)" }

    /// The floating-point / SIMD register set: the 32 NEON vector registers plus
    /// the FP status/control registers.
    nonisolated static let liveFloatingPointRegisterNames: [String] =
        (0...31).map { "v\($0)" } + ["fpsr", "fpcr"]

    /// The full ARM64 register name list the live register read enumerates. A
    /// single `register read` accepts a heterogeneous name list, so reading the
    /// GPR + SIMD + FP/system set in one command keeps every call site issuing one
    /// transport command (no command-separator quirks). `--format x` (applied
    /// below) renders each register — including the NEON vectors — as a single
    /// scalar hex line the parser already understands, rather than the default
    /// brace-vector form that would span the value across many tokens.
    nonisolated static let liveRegisterReadNames: [String] =
        liveGeneralPurposeRegisterNames + liveFloatingPointRegisterNames

    /// Issues the grouped register read across the full ARM64 register file.
    /// Register names are compile-time constants, so no user string reaches the
    /// command; `--format x` forces a uniform scalar-hex rendering so the SIMD
    /// vectors parse the same way the scalar GPRs do.
    nonisolated static let liveRegisterReadCommand =
        "register read --format x " + liveRegisterReadNames.joined(separator: " ")

    nonisolated static let liveStackMemoryReadCommand = "memory read --format x --size 1 --count 64 $sp"

    /// Builds the `register write <name> <value>` command for an authored
    /// register-write request. Name and value are already validated by
    /// `DebuggerRegisterWriteRequest.parse` to be bare identifier / numeric
    /// tokens, so no quoting is required.
    static func makeRegisterWriteCommand(for request: DebuggerRegisterWriteRequest) -> String {
        "register write \(request.name) \(request.value)"
    }

    /// Builds a bounded `memory read` for an authored memory-read request. Mirrors
    /// the stack-window read format so parsing reuses `parseMemorySummaries`.
    static func makeMemoryReadCommand(for request: DebuggerMemoryReadRequest) -> String {
        "memory read --format x --size 1 --count \(request.byteCount) \(request.address.hexAddress)"
    }

    /// Builds a byte-granular `memory write` for an authored memory-write request.
    /// `--size 1` makes each value token one byte, so the address + value sequence
    /// writes exactly the authored bytes. The value tokens are fixed `0x..`
    /// literals produced from the already-validated `[UInt8]`, so no raw user
    /// string reaches this command; the read-back uses the same `--format x --size 1`
    /// shape as `makeMemoryReadCommand` so parsing reuses `parseMemorySummaries`.
    static func makeMemoryWriteCommand(for request: DebuggerMemoryWriteRequest) -> String {
        "memory write --size 1 \(request.address.hexAddress) "
            + request.lldbValueTokens.joined(separator: " ")
    }

    /// Builds the read-back `memory read` that confirms an authored write landed,
    /// covering exactly the bytes that were written.
    static func makeMemoryWriteReadBackCommand(for request: DebuggerMemoryWriteRequest) -> String {
        "memory read --format x --size 1 --count \(request.byteCount) \(request.address.hexAddress)"
    }

    /// Builds the `expression -- <expr>` command for an authored expression
    /// request. `--` terminates LLDB option parsing so an expression that begins
    /// with `-` cannot be misread as an `expression` flag; the request was already
    /// validated to be free of control characters (so no newline can terminate the
    /// command line early), so the expression body is appended verbatim — quoting
    /// it would change its meaning (LLDB expects a raw expression, not a string).
    static func makeExpressionCommand(for request: DebuggerExpressionRequest) -> String {
        "expression -- \(request.expression)"
    }

    /// Builds the `thread select <index>` command. The index is a validated
    /// positive integer, so no quoting is required.
    static func makeThreadSelectCommand(for request: DebuggerThreadSelectionRequest) -> String {
        "thread select \(request.index)"
    }

    /// Builds the `frame select <index>` command. The index is a validated
    /// non-negative integer (`DebuggerFrameSelectionRequest`, bounds-checked
    /// against the recovered frame count), so no quoting is required.
    static func makeFrameSelectCommand(for request: DebuggerFrameSelectionRequest) -> String {
        "frame select \(request.index)"
    }

    /// Reads the selected frame's local variables; paired with `frame select` so
    /// the panel can show the frame's locals alongside its registers.
    static let liveFrameVariablesCommand = "frame variable"

    static let liveThreadListCommand = "thread list"

    static func makeBreakpointCommands(for breakpoints: [DebuggerBreakpoint]) -> [String] {
        breakpoints
            .filter(\.isEnabled)
            .sorted { $0.address < $1.address }
            .map(makeBreakpointCommand)
    }

    static func makeBreakpointMutationCommands(
        from currentBreakpoints: [DebuggerBreakpoint],
        to desiredBreakpoints: [DebuggerBreakpoint]
    ) throws -> [String] {
        try Self.validateBatchBreakpoints(desiredBreakpoints)

        let currentEnabled = normalizedBreakpointDefinitions(currentBreakpoints)
            .filter(\.isEnabled)
        let desiredEnabled = normalizedBreakpointDefinitions(desiredBreakpoints)
            .filter(\.isEnabled)

        guard !sameLLDBBreakpointDefinitions(currentEnabled, desiredEnabled) else {
            return []
        }

        var commands: [String] = []
        if !currentEnabled.isEmpty {
            commands.append("breakpoint delete --force")
        }
        commands.append(contentsOf: makeBreakpointCommands(for: desiredBreakpoints))
        return commands
    }

    static func makeLiveControlSnapshot(
        previousSnapshot: DebuggerSessionSnapshot?,
        commandDisplay: String,
        response: DebuggerLLDBCommandResponse,
        targetResponse: DebuggerLLDBCommandResponse? = nil,
        snapshotResponse: DebuggerLLDBCommandResponse? = nil,
        fallbackProcessID: Int32?,
        fallbackExecutableName: String,
        breakpoints: [DebuggerBreakpoint],
        successStatus: String,
        timeoutStatus: String,
        defaultStoppedReason: DebuggerPauseReason? = nil
    ) -> DebuggerSessionSnapshot {
        let targetResponse = targetResponse ?? response
        let snapshotResponse = snapshotResponse ?? response
        let combinedOutput = response.standardOutput + "\n" + response.standardError
        let targetOutput = targetResponse.standardOutput + "\n" + targetResponse.standardError
        let snapshotOutput = snapshotResponse.standardOutput + "\n" + snapshotResponse.standardError
        let transcript = parseBatchLaunchTranscript(from: targetOutput)
        let reportedProcessID = transcript.targetProcessID ?? parseRunningProcessID(from: targetOutput)
        let expectedProcessID = previousSnapshot?.liveProcessID ?? fallbackProcessID
        let processMismatchMessage = liveProcessMismatchMessage(
            reportedProcessID: reportedProcessID,
            expectedProcessID: expectedProcessID
        )
        let targetState = processMismatchMessage.map(DebuggerBatchTargetState.error)
            ?? resolvedTargetState(from: transcript, response: targetResponse)
        let processID = reportedProcessID ?? fallbackProcessID
        let runSummary = DebuggerCommandRunSummary(
            commandDisplay: commandDisplay,
            lldbTerminationStatus: response.timedOut ? -1 : 0,
            targetExitStatus: transcript.targetExitStatus,
            targetProcessID: processID,
            targetState: targetState,
            diagnosticSummary: processMismatchMessage ?? parseThreadIdentityDiagnostic(from: snapshotOutput)
                ?? transcript.diagnosticSummary,
            standardOutput: response.standardOutput,
            standardError: response.standardError,
            timedOut: response.timedOut
        )

        let inheritedFrames = previousSnapshot?.frames ?? []
        let inheritedThreads = previousSnapshot?.threads ?? []
        let inheritedRegisters = previousSnapshot?.registers ?? []
        let inheritedMemoryRegions = previousSnapshot?.memoryRegions ?? []
        let parsedThreads = parseThreadSummaries(from: snapshotOutput)
        let parsedFrames = parseFrameSummaries(from: snapshotOutput)
        let parsedRegisters = parseRegisterSummaries(from: snapshotOutput)
        let parsedMemoryRegions = parseMemorySummaries(from: snapshotOutput)
        let statusMessage: String
        let processState: DebuggerProcessState
        let backendState: DebuggerBackendSessionState

        if response.timedOut {
            statusMessage = timeoutStatus
            processState = .unavailable(reason: statusMessage)
            backendState = .failed(reason: statusMessage)
        } else if let processMismatchMessage {
            statusMessage = processMismatchMessage
            processState = .unavailable(reason: statusMessage)
            backendState = .failed(reason: statusMessage)
        } else {
            switch targetState {
            case .stopped(let stoppedProcessID, let reason):
                let resolvedProcessID = stoppedProcessID ?? processID ?? 0
                let resolvedReason = resolvedStoppedReason(reason, defaultReason: defaultStoppedReason)
                statusMessage = "\(successStatus): \(resolvedReason.displayTitle)."
                processState = .paused(processID: resolvedProcessID, reason: resolvedReason)
                backendState = .connected(processID: resolvedProcessID, adapterName: "Xcode LLDB Live")
            case .exited(let code):
                statusMessage = "\(successStatus).\(targetExitStatusSentence(code))"
                processState = .exited(code: code)
                backendState = .ready(adapterName: "Xcode LLDB Live")
            case .error(let message):
                statusMessage = "\(successStatus) reported an error: \(message)"
                processState = .unavailable(reason: statusMessage)
                backendState = .failed(reason: statusMessage)
            case .unknown:
                if let runningProcessID = parseRunningProcessID(from: combinedOutput) ?? processID {
                    statusMessage = successStatus
                    processState = .running(processID: runningProcessID, executableName: fallbackExecutableName)
                    backendState = .connected(processID: runningProcessID, adapterName: "Xcode LLDB Live")
                } else {
                    let detail = transcript.diagnosticSummary
                        ?? firstUsefulLine(in: response.standardError)
                        ?? firstUsefulLine(in: response.standardOutput)
                        ?? "LLDB did not report a target process state."
                    statusMessage = "\(successStatus) could not confirm target state: \(detail)"
                    processState = .unavailable(reason: statusMessage)
                    backendState = .failed(reason: statusMessage)
                }
            }
        }

        return DebuggerSessionSnapshot(
            processState: processState,
            breakpoints: breakpoints,
            threads: parsedThreads.isEmpty && parseThreadIdentityDiagnostic(from: snapshotOutput) == nil
                ? inheritedThreads : parsedThreads,
            frames: parsedFrames.isEmpty ? inheritedFrames : parsedFrames,
            registers: parsedRegisters.isEmpty ? inheritedRegisters : parsedRegisters,
            memoryRegions: parsedMemoryRegions.isEmpty ? inheritedMemoryRegions : parsedMemoryRegions,
            statusMessage: statusMessage,
            backendState: backendState,
            lastCommandRun: runSummary
        )
    }

    static func makeLiveTerminationSnapshot(
        previousSnapshot: DebuggerSessionSnapshot,
        commandDisplay: String,
        response: DebuggerLLDBCommandResponse,
        fallbackProcessID: Int32?,
        breakpoints: [DebuggerBreakpoint],
        successStatus: String,
        timeoutStatus: String
    ) -> DebuggerSessionSnapshot {
        let output = response.standardOutput + "\n" + response.standardError
        let transcript = parseBatchLaunchTranscript(from: output)
        let reportedProcessID = transcript.targetProcessID ?? parseRunningProcessID(from: output)
        let expectedProcessID = previousSnapshot.liveProcessID ?? fallbackProcessID
        let processMismatchMessage = liveProcessMismatchMessage(
            reportedProcessID: reportedProcessID,
            expectedProcessID: expectedProcessID
        )
        let parsedTargetState = processMismatchMessage.map(DebuggerBatchTargetState.error)
            ?? resolvedTargetState(from: transcript, response: response)
        let targetProcessID = reportedProcessID ?? fallbackProcessID

        let statusMessage: String
        let processState: DebuggerProcessState
        let backendState: DebuggerBackendSessionState
        let targetState: DebuggerBatchTargetState
        let diagnosticSummary: String?

        if response.timedOut {
            statusMessage = timeoutStatus
            processState = .unavailable(reason: statusMessage)
            backendState = .failed(reason: statusMessage)
            targetState = .unknown
            diagnosticSummary = statusMessage
        } else if let processMismatchMessage {
            statusMessage = processMismatchMessage
            processState = .unavailable(reason: statusMessage)
            backendState = .failed(reason: statusMessage)
            targetState = .error(message: statusMessage)
            diagnosticSummary = statusMessage
        } else {
            switch parsedTargetState {
            case .exited(let code):
                statusMessage = "\(successStatus).\(targetExitStatusSentence(code))"
                processState = .exited(code: code)
                backendState = .ready(adapterName: "Xcode LLDB Live")
                targetState = .exited(code: code)
                diagnosticSummary = transcript.diagnosticSummary
            case .error(let message):
                statusMessage = "\(successStatus) reported an error: \(message)"
                processState = .unavailable(reason: statusMessage)
                backendState = .failed(reason: statusMessage)
                targetState = .error(message: message)
                diagnosticSummary = message
            case .stopped(_, let reason):
                statusMessage = "\(successStatus) did not complete; target is still stopped: \(reason.displayTitle)."
                processState = .unavailable(reason: statusMessage)
                backendState = .failed(reason: statusMessage)
                targetState = .error(message: statusMessage)
                diagnosticSummary = statusMessage
            case .unknown:
                let processDetail = expectedProcessID.map { " for pid \($0)" } ?? ""
                statusMessage = "\(successStatus) could not confirm target exit\(processDetail)."
                processState = .unavailable(reason: statusMessage)
                backendState = .failed(reason: statusMessage)
                targetState = .error(message: statusMessage)
                diagnosticSummary = statusMessage
            }
        }

        let runSummary = DebuggerCommandRunSummary(
            commandDisplay: commandDisplay,
            lldbTerminationStatus: response.timedOut ? -1 : 0,
            targetExitStatus: transcript.targetExitStatus,
            targetProcessID: targetProcessID,
            targetState: targetState,
            diagnosticSummary: diagnosticSummary,
            standardOutput: response.standardOutput,
            standardError: response.standardError,
            timedOut: response.timedOut
        )

        return DebuggerSessionSnapshot(
            processState: processState,
            breakpoints: breakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: statusMessage,
            backendState: backendState,
            lastCommandRun: runSummary
        )
    }

    private static func liveProcessMismatchMessage(
        reportedProcessID: Int32?,
        expectedProcessID: Int32?
    ) -> String? {
        guard
            let reportedProcessID,
            let expectedProcessID,
            reportedProcessID != expectedProcessID
        else { return nil }

        return "LLDB reported pid \(reportedProcessID), but the active live debugger session owns pid \(expectedProcessID). The live debugger session was marked stale and stopped."
    }

    static func makeBatchLaunchSnapshot(
        configuration: DebuggerLaunchConfiguration,
        command: DebuggerExternalCommand,
        result: DebuggerSubprocessResult
    ) -> DebuggerSessionSnapshot {
        let transcript = parseBatchLaunchTranscript(from: result.standardOutput + "\n" + result.standardError)
        let targetState = resolvedTargetState(from: transcript, result: result)
        let runSummary = DebuggerCommandRunSummary(
            commandDisplay: command.displayString,
            lldbTerminationStatus: result.terminationStatus,
            targetExitStatus: transcript.targetExitStatus,
            targetProcessID: transcript.targetProcessID,
            targetState: targetState,
            diagnosticSummary: transcript.diagnosticSummary,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            timedOut: result.timedOut
        )

        let processState: DebuggerProcessState
        var backendState: DebuggerBackendSessionState
        let statusMessage: String

        if result.timedOut {
            statusMessage = "LLDB batch launch timed out after \(Int(command.timeoutSeconds)) seconds for \(configuration.displayName)."
            processState = .unavailable(reason: statusMessage)
            backendState = .failed(reason: statusMessage)
        } else if result.succeeded {
            backendState = .ready(adapterName: "Xcode LLDB Batch")
            switch targetState {
            case .stopped(let processID, let reason):
                processState = .batchStopped(processID: processID, reason: reason)
                statusMessage = "LLDB batch launch stopped for \(configuration.displayName): \(reason.displayTitle). No live debugger session is attached.\(breakpointStatusSuffix(for: configuration.initialBreakpoints))"
            case .error(let message):
                statusMessage = "LLDB batch launch reported an error for \(configuration.displayName): \(message)"
                processState = .unavailable(reason: statusMessage)
                backendState = .failed(reason: statusMessage)
            case .exited(let code):
                processState = .exited(code: code)
                statusMessage = "LLDB batch launch completed for \(configuration.displayName).\(targetExitStatusSentence(code))\(breakpointStatusSuffix(for: configuration.initialBreakpoints))"
            case .unknown:
                processState = .exited(code: transcript.targetExitStatus)
                statusMessage = "LLDB batch launch completed for \(configuration.displayName).\(targetExitStatusSentence(transcript.targetExitStatus))\(breakpointStatusSuffix(for: configuration.initialBreakpoints))"
            }
        } else {
            let detail = transcript.diagnosticSummary
                ?? firstUsefulLine(in: result.standardError)
                ?? firstUsefulLine(in: result.standardOutput)
            let suffix = detail.map { ": \($0)" } ?? "."
            statusMessage = "LLDB batch launch failed with exit code \(result.terminationStatus) for \(configuration.displayName)\(suffix)"
            processState = .unavailable(reason: statusMessage)
            backendState = .failed(reason: statusMessage)
        }

        return DebuggerSessionSnapshot(
            processState: processState,
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: statusMessage,
            backendState: backendState,
            lastCommandRun: runSummary
        )
    }

    static func parseBatchLaunchTranscript(from text: String) -> DebuggerBatchLaunchTranscript {
        var targetProcessID: Int32?
        var targetExitStatus: Int32?
        var targetState: DebuggerBatchTargetState = .unknown
        var diagnosticSummary = parseThreadIdentityDiagnostic(from: text)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let processID = parseProcessID(in: line) {
                targetProcessID = processID
            }

            if let processID = parseStoppedProcessID(in: line) {
                targetProcessID = processID
                targetState = .stopped(processID: processID, reason: .unknown("Process stopped"))
            }

            if let stopReason = parseStopReason(in: line, transcript: text) {
                targetState = .stopped(processID: targetProcessID, reason: stopReason)
            }

            if let exitStatus = parseTargetExitStatus(in: line) {
                targetExitStatus = exitStatus
                targetState = .exited(code: exitStatus)
            } else if isExitLineWithoutStatus(line) {
                targetState = .exited(code: nil)
            }

            if let diagnostic = diagnosticLine(from: line) {
                if diagnosticSummary == nil {
                    diagnosticSummary = diagnostic
                }
                if isDebuggerPolicyDiagnostic(diagnostic) {
                    targetState = .error(message: diagnostic)
                }
            }
        }

        return DebuggerBatchLaunchTranscript(
            targetProcessID: targetProcessID,
            targetExitStatus: targetExitStatus,
            targetState: targetState,
            diagnosticSummary: diagnosticSummary
        )
    }

    static func parseProofResult(
        toolchain: DebuggerLLDBToolchain,
        command: DebuggerExternalCommand,
        result: DebuggerSubprocessResult,
        requiresPersistentCLIProof: Bool = false
    ) -> DebuggerLLDBProofResult {
        let outputPreview = DebuggerPublishedDiagnosticText.project(result.standardOutput).text
        let errorPreview = DebuggerPublishedDiagnosticText.project(result.standardError).text
        let versionSummary = firstMatchingLine(in: result.standardOutput) {
            $0.hasPrefix("lldb-") || $0.contains("LLDB")
        }.map { DebuggerPublishedDiagnosticText.project($0).text }
        let hostTriple = value(after: "Triple:", in: result.standardOutput)
            .map { DebuggerPublishedDiagnosticText.project($0).text }
        let platformSummary = value(after: "Platform:", in: result.standardOutput)
            .map { DebuggerPublishedDiagnosticText.project($0).text }
        let status: DebuggerLLDBProofResult.Status

        if result.timedOut {
            status = .timedOut
        } else if result.terminationStatus == 0,
                  versionSummary != nil,
                  (!requiresPersistentCLIProof
                    || result.standardOutput.contains(persistentCapabilityProofMarker)) {
            status = .passed
        } else {
            status = .failed(exitCode: result.terminationStatus)
        }

        return DebuggerLLDBProofResult(
            toolchain: publishedProofToolchain(toolchain),
            command: publishedProofCommand(command),
            status: status,
            versionSummary: versionSummary,
            hostTriple: hostTriple,
            platformSummary: platformSummary,
            outputPreview: outputPreview,
            errorPreview: errorPreview
        )
    }

    /// The exact proof command the production initializers (`init(inboundNeedleProbe:)` and
    /// `init(debuggerSessionLeaseRegistry:...)`) run, or nil when no LLDB is installed.
    static func productionProofCommand(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) -> DebuggerExternalCommand? {
        discoverLLDBToolchain(environment: environment).map {
            makeProofCommand(
                toolchain: $0,
                environment: environment,
                workingDirectory: workingDirectory,
                requiresPersistentCLIProof: true
            )
        }
    }

    /// Starts the production capability proof on a background queue at app launch, so the first
    /// editor window reads a memoized result instead of running `lldb` inside a SwiftUI update.
    static func prewarmProductionCapabilityProof(
        cache: DebuggerLLDBProofCache = .shared
    ) {
        guard let command = productionProofCommand() else { return }
        cache.prewarm(command) {
            try FoundationDebuggerProcessRunner().run(command)
        }
    }

    private static func runProof(
        toolchain: DebuggerLLDBToolchain,
        processRunner: any DebuggerProcessRunning,
        environment: [String: String],
        workingDirectory: String,
        requiresPersistentCLIProof: Bool,
        proofCache: DebuggerLLDBProofCache?
    ) -> DebuggerLLDBProofResult {
        let command = makeProofCommand(
            toolchain: toolchain,
            environment: environment,
            workingDirectory: workingDirectory,
            requiresPersistentCLIProof: requiresPersistentCLIProof
        )

        do {
            let result: DebuggerSubprocessResult
            if let proofCache {
                result = try proofCache.result(for: command) {
                    try processRunner.run(command)
                }
            } else {
                result = try processRunner.run(command)
            }
            return parseProofResult(
                toolchain: toolchain,
                command: command,
                result: result,
                requiresPersistentCLIProof: requiresPersistentCLIProof
            )
        } catch {
            let publishedError = DebuggerPublishedDiagnosticText.project(error.localizedDescription).text
            return DebuggerLLDBProofResult(
                toolchain: publishedProofToolchain(toolchain),
                command: publishedProofCommand(command),
                status: .executionFailed(publishedError),
                versionSummary: nil,
                hostTriple: nil,
                platformSummary: nil,
                outputPreview: "",
                errorPreview: publishedError
            )
        }
    }

    private static func publishedProofToolchain(
        _ toolchain: DebuggerLLDBToolchain
    ) -> DebuggerLLDBToolchain {
        DebuggerLLDBToolchain(
            executablePath: DebuggerPublishedDiagnosticText.project(
                toolchain.executablePath
            ).text,
            developerDirectory: toolchain.developerDirectory.map {
                DebuggerPublishedDiagnosticText.project($0).text
            },
            discoverySource: DebuggerPublishedDiagnosticText.project(
                toolchain.discoverySource
            ).text,
            candidatePaths: toolchain.candidatePaths.map {
                DebuggerPublishedDiagnosticText.project($0).text
            }
        )
    }

    private static func publishedProofCommand(
        _ command: DebuggerExternalCommand
    ) -> DebuggerExternalCommand {
        DebuggerExternalCommand(
            executablePath: DebuggerPublishedDiagnosticText.project(
                command.executablePath
            ).text,
            arguments: command.arguments.map {
                DebuggerPublishedDiagnosticText.project($0).text
            },
            environment: [:],
            workingDirectory: command.workingDirectory.map {
                DebuggerPublishedDiagnosticText.project($0).text
            },
            timeoutSeconds: command.timeoutSeconds
        )
    }

    private static func makeLLDBCommandEnvironment(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String]
    ) -> [String: String] {
        var commandEnvironment: [String: String] = [
            "TERM": "dumb",
            "NSUnbufferedIO": "YES"
        ]

        if let developerDirectory = toolchain.developerDirectory {
            commandEnvironment["DEVELOPER_DIR"] = developerDirectory
        } else if let developerDirectory = environment["DEVELOPER_DIR"], !developerDirectory.isEmpty {
            commandEnvironment["DEVELOPER_DIR"] = developerDirectory
        }

        return commandEnvironment
    }

    private static func parseTargetExitStatus(in line: String) -> Int32? {
        let patterns = [
            #"exited with status =\s*(-?\d+)"#,
            #"process exited with status\s*(-?\d+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1 else { continue }
            guard let statusRange = Range(match.range(at: 1), in: line) else { continue }
            return Int32(String(line[statusRange]))
        }

        return nil
    }

    private static func resolvedTargetState(
        from transcript: DebuggerBatchLaunchTranscript,
        result: DebuggerSubprocessResult
    ) -> DebuggerBatchTargetState {
        if result.timedOut {
            return .unknown
        }

        if !result.succeeded, let diagnosticSummary = transcript.diagnosticSummary {
            return .error(message: diagnosticSummary)
        }

        if transcript.targetState != .unknown {
            return transcript.targetState
        }

        if let diagnosticSummary = transcript.diagnosticSummary {
            return .error(message: diagnosticSummary)
        }

        return .unknown
    }

    private static func resolvedTargetState(
        from transcript: DebuggerBatchLaunchTranscript,
        response: DebuggerLLDBCommandResponse
    ) -> DebuggerBatchTargetState {
        if response.timedOut {
            return .unknown
        }

        if transcript.targetState != .unknown {
            return transcript.targetState
        }

        if let diagnosticSummary = transcript.diagnosticSummary {
            return .error(message: diagnosticSummary)
        }

        return .unknown
    }

    private static func resolvedStoppedReason(
        _ reason: DebuggerPauseReason,
        defaultReason: DebuggerPauseReason?
    ) -> DebuggerPauseReason {
        guard case .unknown("Process stopped") = reason, let defaultReason else {
            return reason
        }
        return defaultReason
    }

    private static func targetExitStatusSentence(_ exitStatus: Int32?) -> String {
        exitStatus.map { " Target exited with code \($0)." } ?? ""
    }

    private static func parseRunningProcessID(from text: String) -> Int32? {
        let patterns = [
            #"Process\s+(\d+)\s+(?:resuming|running)"#,
            #"process\s+#?(\d+)\s+is\s+running"#
        ]

        for pattern in patterns {
            if let processID = firstRegexCapture(pattern: pattern, in: text, options: [.caseInsensitive]).flatMap(Int32.init) {
                return processID
            }
        }

        return nil
    }

    private static func parseProcessID(in line: String) -> Int32? {
        firstRegexCapture(
            pattern: #"Process\s+(\d+)\s+(?:launched|stopped|exited)"#,
            in: line,
            options: [.caseInsensitive]
        ).flatMap(Int32.init)
    }

    private static func parseStoppedProcessID(in line: String) -> Int32? {
        firstRegexCapture(
            pattern: #"Process\s+(\d+)\s+stopped"#,
            in: line,
            options: [.caseInsensitive]
        ).flatMap(Int32.init)
    }

    nonisolated private static func parseStopReason(in line: String, transcript: String) -> DebuggerPauseReason? {
        guard let reason = firstRegexCapture(
            pattern: #"stop reason =\s*([^\r\n]+)"#,
            in: line,
            options: [.caseInsensitive]
        ) else { return nil }

        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedReason = normalizedReason.lowercased()

        if lowercasedReason.contains("breakpoint") {
            guard let address = parseStoppedAddress(from: transcript) else {
                return .unknown("Breakpoint hit")
            }
            return .breakpoint(address: address)
        }

        if lowercasedReason.contains("step") {
            return .step
        }

        if lowercasedReason.contains("signal") {
            let signalName = firstRegexCapture(
                pattern: #"signal\s+([A-Za-z0-9_]+)"#,
                in: normalizedReason,
                options: [.caseInsensitive]
            )
            return .signal(signalName ?? normalizedReason)
        }

        return .unknown(normalizedReason)
    }

    nonisolated private static func parseStoppedAddress(from transcript: String) -> UInt64? {
        let patterns = [
            #"frame #\d+:\s*(0x[0-9a-fA-F]+)"#,
            #"->\s*(0x[0-9a-fA-F]+)"#,
            #"\bat\s+(0x[0-9a-fA-F]+)"#
        ]

        for pattern in patterns {
            guard let rawAddress = firstRegexCapture(pattern: pattern, in: transcript) else { continue }
            if let address = parseHexAddress(rawAddress) {
                return address
            }
        }

        return nil
    }

    nonisolated static func parseFrameSummaries(from transcript: String) -> [DebuggerFrameSummary] {
        let pattern = #"frame #(\d+):\s*(0x[0-9a-fA-F]+)(?:\s+([^`\s]+)`([^\r\n]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        return regex.matches(in: transcript, range: range).compactMap { match in
            guard
                match.numberOfRanges >= 3,
                let indexRange = Range(match.range(at: 1), in: transcript),
                let addressRange = Range(match.range(at: 2), in: transcript),
                let index = Int(String(transcript[indexRange])),
                let address = parseHexAddress(String(transcript[addressRange]))
            else { return nil }

            let moduleName: String?
            if match.numberOfRanges > 3, let moduleRange = Range(match.range(at: 3), in: transcript) {
                moduleName = String(transcript[moduleRange])
            } else {
                moduleName = nil
            }

            let symbolText: String?
            if match.numberOfRanges > 4, let symbolRange = Range(match.range(at: 4), in: transcript) {
                symbolText = String(transcript[symbolRange])
            } else {
                symbolText = nil
            }

            let sourceLocation = sourceLocation(from: symbolText)
            let functionName = functionName(from: symbolText)

            return DebuggerFrameSummary(
                index: index,
                address: address,
                functionName: functionName,
                moduleName: moduleName,
                sourceLocation: sourceLocation
            )
        }
    }

    /// Parses thread headers from `thread list` and `thread backtrace` output. LLDB's default
    /// backtrace header uses a comma (`* thread #1, queue = '…', stop reason = …`); `thread list`,
    /// and both commands under the formats `DebuggerLLDBSealedLaunchPlan` installs, use a colon
    /// (`* thread #1: tid = 0x…, 0x…, stop reason = …`). Both are accepted; `*` marks the selected
    /// thread. A `thread list` header's program counter (`tid = …, 0x…`) seeds the top frame for
    /// threads that have no `frame #0` line of their own.
    nonisolated static func parseThreadSummaries(from transcript: String) -> [DebuggerThreadSummary] {
        let threadHeaderPattern = #"^\s*(\*)?\s*thread #(\d+)(?:[,:]\s*(.*))?$"#
        guard let threadHeaderRegex = try? NSRegularExpression(pattern: threadHeaderPattern, options: [.caseInsensitive]) else {
            return []
        }

        let threadIDs = parseStructuralThreadTIDs(from: transcript)
        var summariesByIndex: [Int: DebuggerThreadSummary] = [:]
        var orderedIndexes: [Int] = []
        var currentThreadIndex: Int?

        for rawLine in transcript.components(separatedBy: .newlines) {
            let lineRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            if let match = threadHeaderRegex.firstMatch(in: rawLine, range: lineRange),
               match.numberOfRanges >= 3,
               let indexRange = Range(match.range(at: 2), in: rawLine),
               let index = Int(String(rawLine[indexRange])) {
                let selected = Range(match.range(at: 1), in: rawLine) != nil
                let detail: String?
                if match.numberOfRanges > 3, let detailRange = Range(match.range(at: 3), in: rawLine) {
                    detail = String(rawLine[detailRange])
                } else {
                    detail = nil
                }

                var summary: DebuggerThreadSummary
                if let existingSummary = summariesByIndex[index] {
                    summary = existingSummary
                } else {
                    summary = DebuggerThreadSummary(
                        index: index,
                        queueName: nil,
                        stopReason: nil,
                        isSelected: false,
                        topFrameAddress: nil,
                        topFrameFunctionName: nil
                    )
                    orderedIndexes.append(index)
                }

                summary.isSelected = summary.isSelected || selected
                summary.tid = threadIDs.values[index]
                if let queueName = parseThreadQueueName(from: detail) {
                    summary.queueName = queueName
                }
                if let name = parseThreadName(from: detail) {
                    summary.name = name
                }
                if let stopReason = parseStopReason(in: lineWithoutThreadName(rawLine, detail: detail), transcript: transcript) {
                    summary.stopReason = stopReason
                }
                if summary.topFrameAddress == nil,
                   let headerFrame = parseThreadHeaderTopFrame(from: detail) {
                    summary.topFrameAddress = headerFrame.address
                    summary.topFrameFunctionName = summary.topFrameFunctionName ?? headerFrame.functionName
                }
                summariesByIndex[index] = summary
                currentThreadIndex = index
                continue
            }

            guard let currentThreadIndex else { continue }
            guard let topFrame = parseFrameSummaries(from: rawLine).first(where: { $0.index == 0 }) else { continue }
            guard var summary = summariesByIndex[currentThreadIndex] else { continue }
            summary.topFrameAddress = topFrame.address
            summary.topFrameFunctionName = topFrame.functionName
            summariesByIndex[currentThreadIndex] = summary
        }

        return orderedIndexes.compactMap {
            threadIDs.conflicts.contains($0) ? nil : summariesByIndex[$0]
        }
    }

    /// Reads the program counter (and, under LLDB's default format, the function) that a
    /// `thread list` header prints right after `tid = …`.
    nonisolated private static func parseThreadHeaderTopFrame(
        from detail: String?
    ) -> (address: UInt64, functionName: String?)? {
        guard let detail,
              let regex = try? NSRegularExpression(
                pattern: #"tid\s*=\s*[^,\s]+,\s*(0x[0-9a-fA-F]+)(?:\s+[^`\s,]+`([^\s(,]+))?"#
              ) else { return nil }
        let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
        guard let match = regex.firstMatch(in: detail, range: range),
              let addressRange = Range(match.range(at: 1), in: detail),
              let address = parseHexAddress(String(detail[addressRange])) else { return nil }
        let functionName = Range(match.range(at: 2), in: detail).map { String(detail[$0]) }
        return (address, functionName)
    }

    /// Parses the `thread list` output into `[DebuggerThread]`. LLDB prints one
    /// line per thread, for example:
    ///
    ///   `* thread #1: tid = 0x1f3c, 0x... main, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1`
    ///   `  thread #2: tid = 0x1f40, 0x... 'worker', stop reason = ...`
    ///
    /// The leading `*` marks the currently selected thread. The index, tid, an
    /// optional name (a single-quoted token), and the stop reason are recovered;
    /// everything else is ignored.
    static func parseThreadList(from transcript: String) -> [DebuggerThread] {
        let pattern = #"^\s*(\*)?\s*thread #(\d+)(?::?\s*(.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let threadIDs = parseStructuralThreadTIDs(from: transcript)
        var threadsByIndex: [Int: DebuggerThread] = [:]
        var orderedIndexes: [Int] = []

        for rawLine in transcript.components(separatedBy: .newlines) {
            let lineRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard
                let match = regex.firstMatch(in: rawLine, range: lineRange),
                match.numberOfRanges >= 3,
                let indexRange = Range(match.range(at: 2), in: rawLine),
                let index = Int(String(rawLine[indexRange]))
            else { continue }

            let selected = Range(match.range(at: 1), in: rawLine) != nil
            let detail: String?
            if match.numberOfRanges > 3, let detailRange = Range(match.range(at: 3), in: rawLine) {
                detail = String(rawLine[detailRange])
            } else {
                detail = nil
            }

            var thread: DebuggerThread
            if let existing = threadsByIndex[index] {
                thread = existing
            } else {
                thread = DebuggerThread(index: index)
                orderedIndexes.append(index)
            }

            thread.isSelected = thread.isSelected || selected
            thread.tid = threadIDs.values[index]
            if let name = parseThreadName(from: detail) {
                thread.name = name
            }
            if let stopReason = parseStopReason(in: lineWithoutThreadName(rawLine, detail: detail), transcript: transcript) {
                thread.stopReason = stopReason
            }
            threadsByIndex[index] = thread
        }

        return orderedIndexes.compactMap {
            threadIDs.conflicts.contains($0) ? nil : threadsByIndex[$0]
        }
    }

    /// Parses the `expression --` output into a `DebuggerExpressionResult`. LLDB
    /// prints, for example:
    ///
    ///   `(int) $0 = 42`
    ///   `(const char *) $1 = 0x... "hello"`
    ///   `42` (when no result-variable / type annotation is emitted)
    ///
    /// Returns the value text (right of `=`, or the bare line) plus the optional
    /// parenthesized type. Returns `nil` when no usable value line is present.
    nonisolated static func parseExpressionResult(from transcript: String) -> DebuggerExpressionResult? {
        let lines = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("(lldb)") }

        // Prefer the canonical `(type) $n = value` form; fall back to the last
        // non-empty line (a bare value, e.g. `42`).
        let resultLine = lines.last { line in
            line.range(of: #"\$\d+\s*="#, options: .regularExpression) != nil
        } ?? lines.last

        guard let resultLine else { return nil }

        let type: String?
        var remainder = resultLine
        if resultLine.hasPrefix("("),
           let closing = resultLine.firstIndex(of: ")") {
            let typeBody = String(resultLine[resultLine.index(after: resultLine.startIndex)..<closing])
                .trimmingCharacters(in: .whitespaces)
            type = typeBody.isEmpty ? nil : typeBody
            remainder = String(resultLine[resultLine.index(after: closing)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            type = nil
        }

        let value: String
        if let equalsRange = remainder.range(of: " = ") {
            value = String(remainder[equalsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if let equalsRange = remainder.range(of: "=") {
            value = String(remainder[equalsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            value = remainder
        }

        guard !value.isEmpty else { return nil }
        return DebuggerExpressionResult(value: value, type: type)
    }

    /// Only LLDB's first colon-delimited header field is TID authority. Queue/name text
    /// and subsequent fields are never identity evidence. Conflicts remain sticky for the
    /// whole stopped transcript, even if a third header repeats the original TID.
    nonisolated private static func parseStructuralThreadTIDs(
        from transcript: String
    ) -> (values: [Int: UInt64], conflicts: Set<Int>) {
        let pattern = #"^\s*\*?\s*thread #([0-9]+):[ \t]*tid[ \t]*=[ \t]*(0x[0-9a-fA-F]+|[0-9]+)[ \t]*(?:,|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ([:], [])
        }
        var values: [Int: UInt64] = [:]
        var conflicts: Set<Int> = []
        for line in transcript.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let indexRange = Range(match.range(at: 1), in: line),
                  let tidRange = Range(match.range(at: 2), in: line),
                  let index = Int(line[indexRange]) else { continue }
            let raw = String(line[tidRange])
            let tid = raw.lowercased().hasPrefix("0x")
                ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
            guard let tid, tid > 0 else { continue }
            if let previous = values[index], previous != tid {
                conflicts.insert(index)
            } else {
                values[index] = tid
            }
        }
        return (values, conflicts)
    }

    nonisolated static func parseThreadIdentityDiagnostic(from transcript: String) -> String? {
        let conflicts = parseStructuralThreadTIDs(from: transcript).conflicts.sorted()
        guard !conflicts.isEmpty else { return nil }
        let indexes = conflicts.map { "#\($0)" }.joined(separator: ", ")
        return "Conflicting structural TIDs for thread \(indexes) in one stopped transcript; thread identity unavailable."
    }

    nonisolated private static func parseThreadName(from detail: String?) -> String? {
        threadNameField(in: detail)?.name
    }

    /// The `name = '…'` field of a thread header: the name, and the field's full text. The
    /// debuggee chooses its thread names, so a name may contain `'` or `, stop reason = `: the
    /// match runs to the quote that ends the field (the one followed by `, queue =`,
    /// `, stop reason =` or the end of the line), not to the first quote.
    nonisolated private static func threadNameField(in detail: String?) -> (name: String, field: String)? {
        guard let detail else { return nil }
        let patterns = [
            #"name\s*=\s*'(.*?)'(?=\s*(?:,\s*(?:queue|stop reason)\s*=|$))"#,
            #"name\s*=\s*"(.*?)"(?=\s*(?:,\s*(?:queue|stop reason)\s*=|$))"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
            guard let match = regex.firstMatch(in: detail, range: range),
                  let nameRange = Range(match.range(at: 1), in: detail),
                  let fieldRange = Range(match.range, in: detail) else { continue }
            let trimmed = String(detail[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (trimmed, String(detail[fieldRange])) }
        }
        return nil
    }

    /// The header line with its name field removed, so a name's text can't pose as the stop reason.
    nonisolated private static func lineWithoutThreadName(_ line: String, detail: String?) -> String {
        guard let field = threadNameField(in: detail)?.field else { return line }
        return line.replacingOccurrences(of: field, with: "")
    }

    nonisolated static func parseRegisterSummaries(from transcript: String) -> [DebuggerRegisterSummary] {
        let pattern = #"^[ \t]*([A-Za-z][A-Za-z0-9_]*)[ \t]*=[ \t]*([^ \t\r\n]+)(?:[ \t]+([^\r\n]+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        return regex.matches(in: transcript, range: range).compactMap { match in
            guard
                match.numberOfRanges >= 3,
                let nameRange = Range(match.range(at: 1), in: transcript),
                let valueRange = Range(match.range(at: 2), in: transcript)
            else { return nil }

            let name = String(transcript[nameRange])
            let value = String(transcript[valueRange])
            guard isLikelyRegisterValue(value) else { return nil }

            let detail: String?
            if match.numberOfRanges > 3, let detailRange = Range(match.range(at: 3), in: transcript) {
                detail = String(transcript[detailRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                detail = nil
            }

            return DebuggerRegisterSummary(
                name: name,
                value: value,
                role: registerRole(for: name, detail: detail),
                group: registerGroup(for: name)
            )
        }
    }

    nonisolated static func parseMemorySummaries(from transcript: String) -> [DebuggerMemorySummary] {
        let pattern = #"^[ \t]*(0x[0-9a-fA-F]+):[ \t]+([^\r\n]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        var baseAddress: UInt64?
        var bytes: [UInt8] = []

        for match in regex.matches(in: transcript, range: range) {
            guard
                match.numberOfRanges >= 3,
                let addressRange = Range(match.range(at: 1), in: transcript),
                let bytesRange = Range(match.range(at: 2), in: transcript),
                let address = parseHexAddress(String(transcript[addressRange]))
            else { continue }

            let parsedBytes = parseMemoryBytes(from: String(transcript[bytesRange]))
            guard !parsedBytes.isEmpty else { continue }
            if let base = baseAddress {
                // Only accumulate a CONTIGUOUS run. An authored read that crosses an
                // unmapped/permission boundary can make LLDB emit a gap; merging across
                // it would misattribute the later bytes to the wrong addresses. Stop at
                // the first discontinuity and report the contiguous run from the base.
                guard address == base &+ UInt64(bytes.count) else { break }
            } else {
                baseAddress = address
            }
            bytes.append(contentsOf: parsedBytes)
        }

        guard let baseAddress, !bytes.isEmpty else { return [] }
        return [
            DebuggerMemorySummary(
                address: baseAddress,
                byteCount: bytes.count,
                previewBytes: bytes,
                label: "stack near sp"
            )
        ]
    }

    nonisolated private static func parseHexAddress(_ rawAddress: String) -> UInt64? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        return UInt64(hex, radix: 16)
    }

    private static func isExitLineWithoutStatus(_ line: String) -> Bool {
        line.range(of: #"Process\s+\d+\s+exited\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func diagnosticLine(from line: String) -> String? {
        if line.range(of: #"^error:"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return line
        }

        return isDebuggerPolicyDiagnostic(line) ? line : nil
    }

    private static func isDebuggerPolicyDiagnostic(_ line: String) -> Bool {
        let lowercasedLine = line.lowercased()
        return lowercasedLine.contains("attach failed")
            || lowercasedLine.contains("not allowed to attach")
    }

    nonisolated private static func firstRegexCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func validateBatchBreakpoints(_ breakpoints: [DebuggerBreakpoint]) throws {
        for breakpoint in breakpoints {
            guard breakpoint.ignoreCount >= 0 else {
                throw DebuggerClientError.invalidConfiguration(
                    "Breakpoint at \(breakpoint.address.hexAddress) has an invalid negative ignore count."
                )
            }

            guard let condition = normalizedBreakpointCondition(breakpoint.condition) else { continue }
            guard isSafeLLDBCondition(condition) else {
                throw DebuggerClientError.invalidConfiguration(
                    "Breakpoint condition for \(breakpoint.address.hexAddress) contains unsupported control characters."
                )
            }
        }
    }

    private static func validateLaunchArguments(_ arguments: [String]) throws {
        for (index, argument) in arguments.enumerated() where containsUnsupportedControlCharacters(argument) {
            throw DebuggerClientError.invalidConfiguration(
                "Launch argument \(index + 1) contains unsupported control characters."
            )
        }
    }

    private static func validateLaunchEnvironment(_ environment: [String: String]) throws {
        for key in environment.keys.sorted() {
            guard !key.contains("="), !containsUnsupportedControlCharacters(key) else {
                throw DebuggerClientError.invalidConfiguration(
                    "Environment key \(key) contains unsupported characters."
                )
            }

            if let value = environment[key], containsUnsupportedControlCharacters(value) {
                throw DebuggerClientError.invalidConfiguration(
                    "Environment value for \(key) contains unsupported control characters."
                )
            }
        }
    }

    private static func makeBreakpointCommand(_ breakpoint: DebuggerBreakpoint) -> String {
        var command = "breakpoint set --address \(breakpoint.address.hexAddress)"

        if let condition = normalizedBreakpointCondition(breakpoint.condition) {
            command += " --condition \(quoteLLDBCommandArgument(condition))"
        }

        if breakpoint.ignoreCount > 0 {
            command += " --ignore-count \(breakpoint.ignoreCount)"
        }

        return command
    }

    static func normalizedBreakpointDefinitions(_ breakpoints: [DebuggerBreakpoint]) -> [DebuggerBreakpoint] {
        var normalizedByAddress: [UInt64: DebuggerBreakpoint] = [:]
        for breakpoint in breakpoints {
            normalizedByAddress[breakpoint.address] = breakpoint
        }
        return normalizedByAddress.values.sorted { $0.address < $1.address }
    }

    private static func sameLLDBBreakpointDefinitions(
        _ lhs: [DebuggerBreakpoint],
        _ rhs: [DebuggerBreakpoint]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.address == right.address
                && left.isEnabled == right.isEnabled
                && normalizedBreakpointCondition(left.condition) == normalizedBreakpointCondition(right.condition)
                && left.ignoreCount == right.ignoreCount
        }
    }

    private static func breakpointStatusSuffix(for breakpoints: [DebuggerBreakpoint]) -> String {
        let count = breakpoints.filter(\.isEnabled).count
        guard count > 0 else { return "" }
        return " Configured \(count) breakpoint\(count == 1 ? "" : "s")."
    }

    private static func normalizedBreakpointCondition(_ condition: String?) -> String? {
        guard let condition else { return nil }
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSafeLLDBCondition(_ condition: String) -> Bool {
        !containsUnsupportedControlCharacters(condition)
    }

    private static func containsUnsupportedControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        }
    }

    private static func quoteLLDBCommandArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    nonisolated private static func functionName(from symbolText: String?) -> String {
        guard let symbolText else { return "unknown" }
        var function = symbolText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sourceRange = function.range(of: " at ") {
            function = String(function[..<sourceRange.lowerBound])
        }
        if let offsetRange = function.range(of: " + ") {
            function = String(function[..<offsetRange.lowerBound])
        }
        // Strip the terminal argument list, retaining parentheses in operator names and
        // nested/quoted argument values. Display names never supply identity authority.
        if function.last == ")" {
            var depth = 0
            var argumentStart: String.Index?
            var quote: Character?
            var escaped = false
            for index in function.indices {
                let character = function[index]
                if let delimiter = quote {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == delimiter { quote = nil }
                    continue
                }
                if character == "\"" || character == "'" { quote = character; continue }
                if character == "(" {
                    if depth == 0 { argumentStart = index }
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth < 0 { argumentStart = nil; break }
                }
            }
            if depth == 0, quote == nil, let argumentStart {
                let name = function[..<argumentStart].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !name.hasSuffix("operator") { function = name }
            }
        }
        return function.isEmpty ? "unknown" : function
    }

    nonisolated private static func sourceLocation(from symbolText: String?) -> String? {
        guard let symbolText, let range = symbolText.range(of: " at ") else { return nil }
        let source = symbolText[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? nil : source
    }

    nonisolated private static func parseThreadQueueName(from detail: String?) -> String? {
        guard let detail else { return nil }
        let patterns = [
            #"queue = '([^']+)'"#,
            #"queue = "([^"]+)""#,
            #"queue = ([^,]+)"#
        ]

        for pattern in patterns {
            guard let queueName = firstRegexCapture(pattern: pattern, in: detail) else { continue }
            let trimmed = queueName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    nonisolated private static func isLikelyRegisterValue(_ value: String) -> Bool {
        if value.hasPrefix("0x") {
            return parseHexAddress(value) != nil
        }
        return UInt64(value) != nil
    }

    nonisolated private static func parseMemoryBytes(from text: String) -> [UInt8] {
        let pattern = #"\b(?:0x)?([0-9a-fA-F]{1,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let byteRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return UInt8(String(text[byteRange]), radix: 16)
        }
    }

    /// Buckets a register name into its display group. ARM64 GPRs (`x0`–`x30`,
    /// `w0`–`w30`) and the named control registers (`pc`/`sp`/`fp`/`lr`) are
    /// general-purpose; the NEON vectors (`v`/`q`/`d`/`s`) and FP control/status
    /// registers (`fpsr`/`fpcr`) are floating-point/SIMD; `cpsr` and the exception
    /// state registers (`far`/`esr`) are system state. Anything else falls through
    /// to `.other` so an unexpected register name is still surfaced (just
    /// unclassified) rather than dropped.
    nonisolated static func registerGroup(for name: String) -> DebuggerRegisterGroup {
        let lowered = name.lowercased()
        switch lowered {
        case "pc", "sp", "fp", "lr":
            return .generalPurpose
        case "cpsr", "spsr", "far", "esr", "tpidr", "tpidrro":
            return .system
        case "fpsr", "fpcr":
            return .floatingPoint
        default:
            break
        }

        // x0–x30 / w0–w30 are general-purpose; v/q/d/s + h/b vector lanes are SIMD.
        if let first = lowered.first {
            let rest = lowered.dropFirst()
            let restIsNumeric = !rest.isEmpty && rest.allSatisfy { $0.isNumber }
            if (first == "x" || first == "w"), restIsNumeric {
                return .generalPurpose
            }
            if (first == "v" || first == "q" || first == "d" || first == "s" || first == "h" || first == "b"), restIsNumeric {
                return .floatingPoint
            }
        }

        return .other
    }

    nonisolated private static func registerRole(for name: String, detail: String?) -> String? {
        switch name.lowercased() {
        case "pc":
            return detail.map { "program counter: \($0)" } ?? "program counter"
        case "sp":
            return "stack pointer"
        case "fp":
            return "frame pointer"
        case "lr":
            return detail.map { "link register: \($0)" } ?? "link register"
        default:
            return detail?.isEmpty == false ? detail : nil
        }
    }

    private static func firstUsefulLine(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.first { $0.localizedCaseInsensitiveContains("error") }
            ?? lines.first { !$0.hasPrefix("(lldb)") }
            ?? lines.first
    }

    private static func makeToolchain(
        executablePath: String,
        discoverySource: String,
        candidatePaths: [String],
        environment: [String: String]
    ) -> DebuggerLLDBToolchain {
        DebuggerLLDBToolchain(
            executablePath: executablePath,
            developerDirectory: developerDirectory(for: executablePath, environment: environment),
            discoverySource: discoverySource,
            candidatePaths: candidatePaths
        )
    }

    private static func discoverySource(for executablePath: String, environment: [String: String]) -> String {
        if let developerDirectory = environment["DEVELOPER_DIR"],
           !developerDirectory.isEmpty,
           executablePath == URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/lldb").path {
            return "DEVELOPER_DIR"
        }

        if executablePath.contains("Xcode-beta.app") {
            return "Xcode beta default"
        }

        if executablePath.contains("Xcode.app") {
            return "Xcode default"
        }

        return "system"
    }

    private static func developerDirectory(for executablePath: String, environment: [String: String]) -> String? {
        if let developerDirectory = environment["DEVELOPER_DIR"], !developerDirectory.isEmpty {
            return developerDirectory
        }

        let suffix = "/Contents/Developer/usr/bin/lldb"
        guard executablePath.hasSuffix(suffix) else { return nil }
        let developerPath = String(executablePath.dropLast("/usr/bin/lldb".count))
        return developerPath.isEmpty ? nil : developerPath
    }

    private static func firstMatchingLine(in text: String, where predicate: (String) -> Bool) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && predicate($0) }
    }

    private static func value(after prefix: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

}

@MainActor
private final class XcodeLLDBLiveCommandController {
    private let toolchain: DebuggerLLDBToolchain
    private let sessionFactory: DebuggerLLDBCommandSessionFactory
    private let environment: [String: String]
    private let fallbackWorkingDirectory: String
    private let commandTimeoutSeconds: TimeInterval

    private var session: (any DebuggerLLDBCommandSessionTransport)?
    private var processID: Int32?
    private var executableName: String = "target"
    private var breakpoints: [DebuggerBreakpoint] = []

    init(
        toolchain: DebuggerLLDBToolchain,
        sessionFactory: @escaping DebuggerLLDBCommandSessionFactory,
        environment: [String: String],
        fallbackWorkingDirectory: String,
        commandTimeoutSeconds: TimeInterval
    ) {
        self.toolchain = toolchain
        self.sessionFactory = sessionFactory
        self.environment = environment
        self.fallbackWorkingDirectory = fallbackWorkingDirectory
        self.commandTimeoutSeconds = commandTimeoutSeconds
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        try XcodeLLDBCommandLineAdapter.validateLiveLaunchConfiguration(configuration)

        stopSession()

        let workingDirectory = configuration.normalizedWorkingDirectory ?? fallbackWorkingDirectory
        let startCommand = XcodeLLDBCommandLineAdapter.makeLiveSessionStartCommand(
            toolchain: toolchain,
            environment: environment,
            workingDirectory: workingDirectory,
            timeoutSeconds: commandTimeoutSeconds
        )
        let newSession = sessionFactory()

        do {
            try newSession.start(startCommand)
            session = newSession
            executableName = configuration.displayName
            breakpoints = configuration.initialBreakpoints

            try sendRequiredSetupCommand("settings set use-color false")
            try sendRequiredSetupCommand(XcodeLLDBCommandLineAdapter.makeTargetCreateCommand(for: configuration))
            if let environmentCommand = XcodeLLDBCommandLineAdapter.makeEnvironmentCommand(
                for: configuration.normalizedEnvironment
            ) {
                try sendRequiredSetupCommand(environmentCommand)
            }
            if let argumentsCommand = XcodeLLDBCommandLineAdapter.makeRunArgumentsCommand(for: configuration.arguments) {
                try sendRequiredSetupCommand(argumentsCommand)
            }

            for breakpointCommand in XcodeLLDBCommandLineAdapter.makeBreakpointCommands(for: configuration.initialBreakpoints) {
                try sendRequiredSetupCommand(breakpointCommand)
            }

            let launchResponse = try send("process launch --stop-at-entry")
            let statusResponse = try send("process status")
            let snapshot = try makeLiveControlSnapshotWithStoppedRefresh(
                previousSnapshot: nil,
                commandDisplay: "process launch --stop-at-entry; process status",
                responses: [launchResponse, statusResponse],
                fallbackProcessID: processID,
                fallbackExecutableName: executableName,
                breakpoints: breakpoints,
                successStatus: "LLDB live launch for \(configuration.displayName)",
                timeoutStatus: "LLDB live launch timed out after \(Int(commandTimeoutSeconds)) seconds for \(configuration.displayName).",
                defaultStoppedReason: .unknown("Stopped at entry")
            )
            updateSessionState(from: snapshot)
            return snapshot
        } catch {
            stopSession()
            throw DebuggerClientError.backendFailure("LLDB live launch could not start: \(error.localizedDescription)")
        }
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.processState.isPaused else {
            throw DebuggerClientError.invalidState("Continue requires a paused live debug process.")
        }

        let continueResponse = try send("process continue")
        var statusResponse = try send("process status")
        // A status issued immediately after continue can catch an ultra-short-lived
        // target mid-exit on a loaded host and report "is running". Settle-poll
        // briefly so an exit already underway is observed; a genuinely long-running
        // target still returns promptly with a running snapshot.
        let settleDeadline = Date().addingTimeInterval(2)
        while statusResponse.standardOutput.contains("is running"), Date() < settleDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            statusResponse = try send("process status")
        }
        let nextSnapshot = try makeLiveControlSnapshotWithStoppedRefresh(
            previousSnapshot: snapshot,
            commandDisplay: "process continue; process status",
            responses: [continueResponse, statusResponse],
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Process continued",
            timeoutStatus: "Continue timed out after \(Int(commandTimeoutSeconds)) seconds."
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Run to cursor requires the checked persistent LLDB transport."
        )
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.processState.isPaused else {
            throw DebuggerClientError.invalidState("Step over requires a paused live debug process.")
        }

        let stepResponse = try send("thread step-over")
        let statusResponse = try send("process status")
        let nextSnapshot = try makeLiveControlSnapshotWithStoppedRefresh(
            previousSnapshot: snapshot,
            commandDisplay: "thread step-over; process status",
            responses: [stepResponse, statusResponse],
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Step over completed",
            timeoutStatus: "Step over timed out after \(Int(commandTimeoutSeconds)) seconds.",
            defaultStoppedReason: .step
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.processState.isPaused else {
            throw DebuggerClientError.invalidState("Step into requires a paused live debug process.")
        }

        let stepResponse = try send("thread step-in")
        let statusResponse = try send("process status")
        let nextSnapshot = try makeLiveControlSnapshotWithStoppedRefresh(
            previousSnapshot: snapshot,
            commandDisplay: "thread step-in; process status",
            responses: [stepResponse, statusResponse],
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Step into completed",
            timeoutStatus: "Step into timed out after \(Int(commandTimeoutSeconds)) seconds.",
            defaultStoppedReason: .step
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.processState.isPaused else {
            throw DebuggerClientError.invalidState("Step out requires a paused live debug process.")
        }

        let stepResponse = try send("thread step-out")
        let statusResponse = try send("process status")
        let nextSnapshot = try makeLiveControlSnapshotWithStoppedRefresh(
            previousSnapshot: snapshot,
            commandDisplay: "thread step-out; process status",
            responses: [stepResponse, statusResponse],
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Step out completed",
            timeoutStatus: "Step out timed out after \(Int(commandTimeoutSeconds)) seconds.",
            defaultStoppedReason: .step
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.processState.isRunning else {
            throw DebuggerClientError.invalidState("Pause requires a running live debug process.")
        }

        let interruptResponse = try send("process interrupt")
        let statusResponse = try send("process status")
        let nextSnapshot = try makeLiveControlSnapshotWithStoppedRefresh(
            previousSnapshot: snapshot,
            commandDisplay: "process interrupt; process status",
            responses: [interruptResponse, statusResponse],
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Process interrupted",
            timeoutStatus: "Pause timed out after \(Int(commandTimeoutSeconds)) seconds.",
            defaultStoppedReason: .userRequested
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.hasLiveProcessSession else {
            throw DebuggerClientError.invalidState("Terminate requires a live debug process.")
        }

        let terminateResponse = try send("process kill")
        let nextSnapshot = XcodeLLDBCommandLineAdapter.makeLiveTerminationSnapshot(
            previousSnapshot: snapshot,
            commandDisplay: terminateResponse.command,
            response: terminateResponse,
            fallbackProcessID: processID,
            breakpoints: snapshot.breakpoints,
            successStatus: "Process terminated",
            timeoutStatus: "Terminate timed out after \(Int(commandTimeoutSeconds)) seconds."
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func replaceBreakpoints(_ desiredBreakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.hasLiveProcessSession else {
            throw DebuggerClientError.invalidState("Breakpoint mutation requires a live debug process.")
        }

        let desiredBreakpoints = XcodeLLDBCommandLineAdapter.normalizedBreakpointDefinitions(desiredBreakpoints)
        let commands = try XcodeLLDBCommandLineAdapter.makeBreakpointMutationCommands(
            from: breakpoints,
            to: desiredBreakpoints
        )
        let responses = try commands.map(sendRequiredLiveCommand)
        let response = combinedResponse(
            commandDisplay: commands.isEmpty ? "breakpoint sync" : commands.joined(separator: "; "),
            responses: responses
        )

        breakpoints = desiredBreakpoints
        var nextSnapshot = snapshot
        nextSnapshot.replaceBreakpoints(desiredBreakpoints)
        nextSnapshot.statusMessage = commands.isEmpty
            ? "Breakpoints are already synchronized."
            : "Synchronized \(desiredBreakpoints.filter(\.isEnabled).count) live breakpoint\(desiredBreakpoints.filter(\.isEnabled).count == 1 ? "" : "s")."
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: response.command,
            response: response,
            snapshot: nextSnapshot
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.canWriteRegisterLiveProcess else {
            throw DebuggerClientError.invalidState("Register write requires a paused live debug process.")
        }

        let writeCommand = XcodeLLDBCommandLineAdapter.makeRegisterWriteCommand(for: request)
        let writeResponse = try sendRequiredLiveCommand(writeCommand)
        // Re-read the register file so the mutated value is reflected in the
        // snapshot the panel shows.
        let registerResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)
        let response = combinedResponse(
            commandDisplay: "\(writeCommand); \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            responses: [writeResponse, registerResponse]
        )

        let combinedOutput = response.standardOutput + "\n" + response.standardError
        var nextSnapshot = snapshot
        let registers = XcodeLLDBCommandLineAdapter.parseRegisterSummaries(from: combinedOutput)
        if !registers.isEmpty {
            nextSnapshot.registers = registers
        }
        nextSnapshot.statusMessage = "Wrote register \(request.displayName)."
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: response.command,
            response: response,
            snapshot: nextSnapshot
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.canReadMemoryLiveProcess else {
            throw DebuggerClientError.invalidState("Memory read requires a paused live debug process.")
        }

        let readCommand = XcodeLLDBCommandLineAdapter.makeMemoryReadCommand(for: request)
        let readResponse = try sendRequiredLiveCommand(readCommand)
        let combinedOutput = readResponse.standardOutput + "\n" + readResponse.standardError
        let parsedRegions = XcodeLLDBCommandLineAdapter.parseMemorySummaries(from: combinedOutput)
        let authoredRegions = parsedRegions.map { region in
            DebuggerMemorySummary(
                address: region.address,
                byteCount: region.byteCount,
                previewBytes: region.previewBytes,
                label: "read \(request.byteCount) byte\(request.byteCount == 1 ? "" : "s") at \(request.address.hexAddress)"
            )
        }

        var nextSnapshot = snapshot
        if !authoredRegions.isEmpty {
            nextSnapshot.memoryRegions = mergeMemoryRegions(
                existing: snapshot.memoryRegions,
                authored: authoredRegions
            )
            let readBytes = authoredRegions.reduce(0) { $0 + $1.previewBytes.count }
            nextSnapshot.statusMessage = "Read \(readBytes) byte\(readBytes == 1 ? "" : "s") at \(request.address.hexAddress)."
        } else {
            nextSnapshot.statusMessage = "Memory read at \(request.address.hexAddress) returned no bytes."
        }
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: readResponse.command,
            response: readResponse,
            snapshot: nextSnapshot
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.canWriteMemoryLiveProcess else {
            throw DebuggerClientError.invalidState("Memory write requires a paused live debug process.")
        }

        let writeCommand = XcodeLLDBCommandLineAdapter.makeMemoryWriteCommand(for: request)
        let writeResponse = try sendRequiredLiveCommand(writeCommand)
        // Read the just-written bytes back so the panel reflects the mutated memory
        // rather than trusting the write blindly.
        let readBackCommand = XcodeLLDBCommandLineAdapter.makeMemoryWriteReadBackCommand(for: request)
        let readBackResponse = try sendRequiredLiveCommand(readBackCommand)
        let response = combinedResponse(
            commandDisplay: "\(writeCommand); \(readBackCommand)",
            responses: [writeResponse, readBackResponse]
        )

        let combinedOutput = readBackResponse.standardOutput + "\n" + readBackResponse.standardError
        let parsedRegions = XcodeLLDBCommandLineAdapter.parseMemorySummaries(from: combinedOutput)
        let authoredRegions = parsedRegions.map { region in
            DebuggerMemorySummary(
                address: region.address,
                byteCount: region.byteCount,
                previewBytes: region.previewBytes,
                label: "wrote \(request.byteCount) byte\(request.byteCount == 1 ? "" : "s") at \(request.address.hexAddress)"
            )
        }

        var nextSnapshot = snapshot
        if !authoredRegions.isEmpty {
            nextSnapshot.memoryRegions = mergeMemoryRegions(
                existing: snapshot.memoryRegions,
                authored: authoredRegions
            )
        }
        nextSnapshot.statusMessage = "Wrote \(request.byteCount) byte\(request.byteCount == 1 ? "" : "s") at \(request.address.hexAddress)."
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: response.command,
            response: response,
            snapshot: nextSnapshot
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        guard snapshot.canEvaluateExpressionLiveProcess else {
            throw DebuggerClientError.invalidState("Expression evaluation requires a paused live debug process.")
        }

        let command = XcodeLLDBCommandLineAdapter.makeExpressionCommand(for: request)
        let response = try sendRequiredLiveCommand(command)
        let combinedOutput = response.standardOutput + "\n" + response.standardError
        guard let result = XcodeLLDBCommandLineAdapter.parseExpressionResult(from: combinedOutput) else {
            throw DebuggerClientError.backendFailure(
                "Expression \(request.displayName) did not return a value."
            )
        }
        return result
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.canSelectThreadLiveProcess else {
            throw DebuggerClientError.invalidState("Thread selection requires a paused live debug process.")
        }

        let selectCommand = XcodeLLDBCommandLineAdapter.makeThreadSelectCommand(for: request)
        let selectResponse = try sendRequiredLiveCommand(selectCommand)
        // Re-read this thread's frames + registers so the panel reflects the newly
        // selected thread, and re-list threads so the selection marker moves.
        let threadListResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveThreadListCommand)
        let backtraceResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveBacktraceCommand)
        let registerResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)
        let response = combinedResponse(
            commandDisplay: [
                selectCommand,
                XcodeLLDBCommandLineAdapter.liveThreadListCommand,
                XcodeLLDBCommandLineAdapter.liveBacktraceCommand,
                XcodeLLDBCommandLineAdapter.liveRegisterReadCommand
            ].joined(separator: "; "),
            responses: [selectResponse, threadListResponse, backtraceResponse, registerResponse]
        )

        let combinedOutput = response.standardOutput + "\n" + response.standardError
        var nextSnapshot = snapshot
        let threadSummaries = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: combinedOutput)
        let frames = XcodeLLDBCommandLineAdapter.parseFrameSummaries(from: combinedOutput)
        let registers = XcodeLLDBCommandLineAdapter.parseRegisterSummaries(from: combinedOutput)
        if !threadSummaries.isEmpty
            || XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: combinedOutput) != nil {
            nextSnapshot.threads = threadSummaries
        }
        if !frames.isEmpty {
            nextSnapshot.frames = frames
        }
        if !registers.isEmpty {
            nextSnapshot.registers = registers
        }
        nextSnapshot.statusMessage = "Selected thread #\(request.index)."
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: response.command,
            response: response,
            snapshot: nextSnapshot
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.canSelectFrameLiveProcess else {
            throw DebuggerClientError.invalidState("Frame selection requires a paused live debug process.")
        }

        // Resolve + bounds-check the request against the recovered frames before
        // touching the transport so an out-of-range index never issues a command.
        let selection: DebuggerFrameSelection
        switch DebuggerFrameSelection.resolve(index: request.index, in: snapshot) {
        case .success(let resolved):
            selection = resolved
        case .failure(let error):
            throw DebuggerClientError.invalidState(error.reason)
        }

        let selectCommand = XcodeLLDBCommandLineAdapter.makeFrameSelectCommand(for: request)
        let selectResponse = try sendRequiredLiveCommand(selectCommand)
        // Re-read THIS frame's registers + locals so the panel reflects the chosen
        // frame's context.
        let registerResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)
        let variablesResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveFrameVariablesCommand)
        let response = combinedResponse(
            commandDisplay: [
                selectCommand,
                XcodeLLDBCommandLineAdapter.liveRegisterReadCommand,
                XcodeLLDBCommandLineAdapter.liveFrameVariablesCommand
            ].joined(separator: "; "),
            responses: [selectResponse, registerResponse, variablesResponse]
        )

        let combinedOutput = response.standardOutput + "\n" + response.standardError
        var nextSnapshot = snapshot
        let registers = XcodeLLDBCommandLineAdapter.parseRegisterSummaries(from: combinedOutput)
        if !registers.isEmpty {
            nextSnapshot.registers = registers
        }
        nextSnapshot.statusMessage = "Selected frame #\(request.index) at \(selection.programCounter.hexAddress)."
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: response.command,
            response: response,
            snapshot: nextSnapshot
        )
        updateSessionState(from: nextSnapshot)
        return nextSnapshot
    }

    /// Upserts authored memory reads by base address so the most recent read of a
    /// given address replaces an earlier preview, while keeping other regions
    /// (notably the launch-time stack window) intact.
    private func mergeMemoryRegions(
        existing: [DebuggerMemorySummary],
        authored: [DebuggerMemorySummary]
    ) -> [DebuggerMemorySummary] {
        var byAddress: [UInt64: DebuggerMemorySummary] = [:]
        var order: [UInt64] = []
        for region in existing + authored {
            if byAddress[region.address] == nil {
                order.append(region.address)
            }
            byAddress[region.address] = region
        }
        return order.compactMap { byAddress[$0] }
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.canRefreshStoppedSnapshot else {
            throw DebuggerClientError.invalidState("Snapshot refresh requires a paused live debug process.")
        }

        let statusResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveProcessStatusCommand)
        let statusSnapshot = XcodeLLDBCommandLineAdapter.makeLiveControlSnapshot(
            previousSnapshot: snapshot,
            commandDisplay: statusResponse.command,
            response: statusResponse,
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Debugger status refreshed",
            timeoutStatus: "Snapshot refresh timed out after \(Int(commandTimeoutSeconds)) seconds.",
            defaultStoppedReason: pausedReason(from: snapshot)
        )

        guard statusSnapshot.canRefreshStoppedSnapshot else {
            updateSessionState(from: statusSnapshot)
            return statusSnapshot
        }

        let responses = [statusResponse] + sendOptionalSnapshotRefreshResponses()
        let response = combinedResponse(
            commandDisplay: responses.map(\.command).joined(separator: "; "),
            responses: responses
        )
        let refreshedSnapshot = makeRefreshedSnapshot(from: statusSnapshot, response: response)
        updateSessionState(from: refreshedSnapshot)
        return refreshedSnapshot
    }

    /// Compatibility-only observation for explicitly injected legacy command sessions. Production
    /// status observation is owned by `PersistentLLDBProductionController` and its typed reducer.
    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard snapshot.processState.isRunning else {
            throw DebuggerClientError.invalidState(
                "Process-status observation requires a running live debug process."
            )
        }

        let statusResponse = try sendRequiredLiveCommand(XcodeLLDBCommandLineAdapter.liveProcessStatusCommand)
        let statusSnapshot = XcodeLLDBCommandLineAdapter.makeLiveControlSnapshot(
            previousSnapshot: snapshot,
            commandDisplay: statusResponse.command,
            response: statusResponse,
            fallbackProcessID: processID,
            fallbackExecutableName: executableName,
            breakpoints: snapshot.breakpoints,
            successStatus: "Debugger status observed",
            timeoutStatus: "Process-status observation timed out after \(Int(commandTimeoutSeconds)) seconds.",
            defaultStoppedReason: .unknown("Process stopped")
        )

        guard statusSnapshot.canRefreshStoppedSnapshot else {
            updateSessionState(from: statusSnapshot)
            return statusSnapshot
        }

        let responses = [statusResponse] + sendOptionalSnapshotRefreshResponses()
        let response = combinedResponse(
            commandDisplay: responses.map(\.command).joined(separator: "; "),
            responses: responses
        )
        let refreshedSnapshot = makeRefreshedSnapshot(from: statusSnapshot, response: response)
        updateSessionState(from: refreshedSnapshot)
        return refreshedSnapshot
    }

    private func send(_ command: String) throws -> DebuggerLLDBCommandResponse {
        guard let session else {
            throw DebuggerLLDBCommandSessionError.notStarted
        }
        return try session.send(command, timeoutSeconds: commandTimeoutSeconds)
    }

    private func sendRequiredLiveCommand(_ command: String) throws -> DebuggerLLDBCommandResponse {
        let response = try send(command)
        if response.timedOut {
            throw DebuggerLLDBCommandSessionError.writeFailed("\(command) timed out after \(Int(commandTimeoutSeconds)) seconds.")
        }

        let transcript = XcodeLLDBCommandLineAdapter.parseBatchLaunchTranscript(
            from: response.standardOutput + "\n" + response.standardError
        )
        if let diagnostic = transcript.diagnosticSummary {
            throw DebuggerLLDBCommandSessionError.writeFailed(diagnostic)
        }

        return response
    }

    private func sendRequiredSetupCommand(_ command: String) throws {
        let response = try send(command)
        if response.timedOut {
            throw DebuggerLLDBCommandSessionError.writeFailed("\(command) timed out after \(Int(commandTimeoutSeconds)) seconds.")
        }

        let transcript = XcodeLLDBCommandLineAdapter.parseBatchLaunchTranscript(
            from: response.standardOutput + "\n" + response.standardError
        )
        if let diagnostic = transcript.diagnosticSummary {
            throw DebuggerLLDBCommandSessionError.writeFailed(diagnostic)
        }
    }

    private func updateSessionState(from snapshot: DebuggerSessionSnapshot) {
        switch snapshot.processState {
        case .running(let processID, let executableName):
            self.processID = processID
            self.executableName = executableName
            self.breakpoints = snapshot.breakpoints
        case .paused(let processID, _):
            self.processID = processID
            self.breakpoints = snapshot.breakpoints
        case .exited, .unavailable:
            stopSession()
        case .notAttached, .launching, .detaching, .batchStopped:
            break
        }
    }

    private func makeLiveControlSnapshotWithStoppedRefresh(
        previousSnapshot: DebuggerSessionSnapshot?,
        commandDisplay: String,
        responses: [DebuggerLLDBCommandResponse],
        fallbackProcessID: Int32?,
        fallbackExecutableName: String,
        breakpoints: [DebuggerBreakpoint],
        successStatus: String,
        timeoutStatus: String,
        defaultStoppedReason: DebuggerPauseReason? = nil
    ) throws -> DebuggerSessionSnapshot {
        let baseResponse = combinedResponse(commandDisplay: commandDisplay, responses: responses)
        let baseSnapshot = XcodeLLDBCommandLineAdapter.makeLiveControlSnapshot(
            previousSnapshot: previousSnapshot,
            commandDisplay: baseResponse.command,
            response: baseResponse,
            fallbackProcessID: fallbackProcessID,
            fallbackExecutableName: fallbackExecutableName,
            breakpoints: breakpoints,
            successStatus: successStatus,
            timeoutStatus: timeoutStatus,
            defaultStoppedReason: defaultStoppedReason
        )

        guard baseSnapshot.canRefreshStoppedSnapshot else {
            return baseSnapshot
        }

        let refreshResponses = sendOptionalSnapshotRefreshResponses()
        guard !refreshResponses.isEmpty else {
            return baseSnapshot
        }

        let commandDisplay = ([commandDisplay] + refreshResponses.map(\.command)).joined(separator: "; ")
        let refreshOnlyResponse = combinedResponse(
            commandDisplay: refreshResponses.map(\.command).joined(separator: "; "),
            responses: refreshResponses
        )
        let refreshedResponse = combinedResponse(
            commandDisplay: commandDisplay,
            responses: responses + refreshResponses
        )
        return XcodeLLDBCommandLineAdapter.makeLiveControlSnapshot(
            previousSnapshot: previousSnapshot,
            commandDisplay: refreshedResponse.command,
            response: refreshedResponse,
            targetResponse: baseResponse,
            snapshotResponse: refreshOnlyResponse,
            fallbackProcessID: fallbackProcessID,
            fallbackExecutableName: fallbackExecutableName,
            breakpoints: breakpoints,
            successStatus: successStatus,
            timeoutStatus: timeoutStatus,
            defaultStoppedReason: defaultStoppedReason
        )
    }

    private func sendOptionalSnapshotRefreshResponses() -> [DebuggerLLDBCommandResponse] {
        let commands = [
            XcodeLLDBCommandLineAdapter.liveBacktraceCommand,
            XcodeLLDBCommandLineAdapter.liveRegisterReadCommand,
            XcodeLLDBCommandLineAdapter.liveStackMemoryReadCommand
        ]

        return commands.compactMap { command in
            guard let response = try? send(command), !response.timedOut else { return nil }
            let transcript = XcodeLLDBCommandLineAdapter.parseBatchLaunchTranscript(
                from: response.standardOutput + "\n" + response.standardError
            )
            guard transcript.diagnosticSummary == nil else { return nil }
            return response
        }
    }

    private func makeRefreshedSnapshot(
        from snapshot: DebuggerSessionSnapshot,
        response: DebuggerLLDBCommandResponse
    ) -> DebuggerSessionSnapshot {
        let combinedOutput = response.standardOutput + "\n" + response.standardError
        let threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: combinedOutput)
        let frames = XcodeLLDBCommandLineAdapter.parseFrameSummaries(from: combinedOutput)
        let registers = XcodeLLDBCommandLineAdapter.parseRegisterSummaries(from: combinedOutput)
        let memoryRegions = XcodeLLDBCommandLineAdapter.parseMemorySummaries(from: combinedOutput)
        var nextSnapshot = snapshot
        if !threads.isEmpty
            || XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: combinedOutput) != nil {
            nextSnapshot.threads = threads
        }
        if !frames.isEmpty {
            nextSnapshot.frames = frames
        }
        if !registers.isEmpty {
            nextSnapshot.registers = registers
        }
        if !memoryRegions.isEmpty {
            nextSnapshot.memoryRegions = memoryRegions
        }
        nextSnapshot.statusMessage = "Debugger snapshot refreshed. \(nextSnapshot.frames.count) frame\(nextSnapshot.frames.count == 1 ? "" : "s"), \(nextSnapshot.registers.count) register\(nextSnapshot.registers.count == 1 ? "" : "s"), \(nextSnapshot.memoryRegions.count) memory region\(nextSnapshot.memoryRegions.count == 1 ? "" : "s")."
        nextSnapshot.lastCommandRun = makeLiveCommandRunSummary(
            commandDisplay: response.command,
            response: response,
            snapshot: nextSnapshot
        )
        return nextSnapshot
    }

    private func pausedReason(from snapshot: DebuggerSessionSnapshot) -> DebuggerPauseReason? {
        guard case .paused(_, let reason) = snapshot.processState else {
            return nil
        }
        return reason
    }

    private func makeLiveCommandRunSummary(
        commandDisplay: String,
        response: DebuggerLLDBCommandResponse,
        snapshot: DebuggerSessionSnapshot
    ) -> DebuggerCommandRunSummary {
        let transcript = XcodeLLDBCommandLineAdapter.parseBatchLaunchTranscript(
            from: response.standardOutput + "\n" + response.standardError
        )

        return DebuggerCommandRunSummary(
            commandDisplay: commandDisplay,
            lldbTerminationStatus: response.timedOut ? -1 : 0,
            targetExitStatus: transcript.targetExitStatus,
            targetProcessID: transcript.targetProcessID ?? processID,
            targetState: currentTargetState(from: snapshot),
            diagnosticSummary: transcript.diagnosticSummary,
            standardOutput: response.standardOutput,
            standardError: response.standardError,
            timedOut: response.timedOut
        )
    }

    private func currentTargetState(from snapshot: DebuggerSessionSnapshot) -> DebuggerBatchTargetState {
        switch snapshot.processState {
        case .paused(let processID, let reason):
            return .stopped(processID: processID, reason: reason)
        case .exited(let code):
            return .exited(code: code)
        case .unavailable(let reason):
            return .error(message: reason)
        case .running, .notAttached, .launching, .detaching, .batchStopped:
            return .unknown
        }
    }

    private func stopSession() {
        session?.stop()
        session = nil
        processID = nil
    }

    private func combinedResponse(
        commandDisplay: String,
        responses: [DebuggerLLDBCommandResponse]
    ) -> DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: commandDisplay,
            standardOutput: responses.map(\.standardOutput).filter { !$0.isEmpty }.joined(separator: "\n"),
            standardError: responses.map(\.standardError).filter { !$0.isEmpty }.joined(separator: "\n"),
            timedOut: responses.contains { $0.timedOut }
        )
    }
}

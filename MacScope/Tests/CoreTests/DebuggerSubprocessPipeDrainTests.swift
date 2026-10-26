import Foundation
import Darwin
import XCTest

@testable import MacScope

/// Regression coverage for the pipe-buffer deadlock: a child that writes more than the ~64 KB
/// pipe buffer must not block when the parent waits for exit before collecting output.
final class DebuggerSubprocessPipeDrainTests: XCTestCase {
    private static let stdoutBytes = 1_500_000
    private static let stderrBytes = 1_300_000

    /// Writes all of stdout first, then all of stderr, so either pipe filling alone would wedge
    /// a runner that reads after the wait or reads the two pipes sequentially.
    private static let largeOutputScript =
        "/usr/bin/yes o | /usr/bin/head -c \(stdoutBytes); "
        + "/usr/bin/yes e | /usr/bin/head -c \(stderrBytes) >&2"

    func testFoundationRunnerDrainsMegabytesOfStdoutAndStderrWithoutTimingOut() throws {
        let timeout: TimeInterval = 60
        let started = Date()
        let result = try FoundationDebuggerProcessRunner().run(DebuggerExternalCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", Self.largeOutputScript],
            environment: [:],
            workingDirectory: nil,
            timeoutSeconds: timeout
        ))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertLessThan(elapsed, timeout / 4, "large output must not stall the runner")
        XCTAssertEqual(result.standardOutput.utf8.count, Self.stdoutBytes)
        XCTAssertEqual(result.standardError.utf8.count, Self.stderrBytes)
        XCTAssertTrue(result.standardOutput.utf8.allSatisfy { $0 == UInt8(ascii: "o") || $0 == 0x0A })
        XCTAssertTrue(result.standardError.utf8.allSatisfy { $0 == UInt8(ascii: "e") || $0 == 0x0A })
    }

    func testFoundationRunnerTimeoutTerminatesAndKeepsOutputReadBeforeTimeout() throws {
        let partialBytes = 200_000
        let started = Date()
        let result = try FoundationDebuggerProcessRunner().run(DebuggerExternalCommand(
            executablePath: "/bin/sh",
            // `exec` keeps sleep as the runner's own child, so terminate closes the pipe.
            arguments: ["-c", "/usr/bin/yes o | /usr/bin/head -c \(partialBytes); exec /bin/sleep 60"],
            environment: [:],
            workingDirectory: nil,
            timeoutSeconds: 1
        ))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.terminationStatus, -1)
        XCTAssertLessThan(elapsed, 15, "timeout must terminate and return promptly")
        XCTAssertEqual(result.standardOutput.utf8.count, partialBytes)
    }

    func testDrainDeadlineClosesReaderDespiteInheritedWriterDescriptor() throws {
        let pipe = Pipe()
        let inheritedWriter = Darwin.dup(pipe.fileHandleForWriting.fileDescriptor)
        XCTAssertGreaterThanOrEqual(inheritedWriter, 0)
        defer { if inheritedWriter >= 0 { _ = Darwin.close(inheritedWriter) } }
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready".utf8))
        try pipe.fileHandleForWriting.close()
        let readerDescriptor = pipe.fileHandleForReading.fileDescriptor
        let drain = DebuggerSubprocessPipeDrain(pipe.fileHandleForReading)
        // Under parallel load the utility-QoS reader may not be scheduled before a short
        // deadline; wait (bounded) until it has consumed the bytes so the assertions below test
        // deadline retirement, not scheduling latency. The inherited writer keeps the pipe open,
        // so the reader cannot close its descriptor before cancellation and no EOF can arrive.
        let consumedBy = Date().addingTimeInterval(10)
        while Self.hasPendingInput(readerDescriptor), Date() < consumedBy {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(Self.hasPendingInput(readerDescriptor), "reader never consumed the pipe")
        XCTAssertFalse(drain.isFinished, "the inherited writer must keep the reader without EOF")
        let started = Date()
        let captured = drain.finish(deadline: .now() + .milliseconds(100))
        XCTAssertEqual(captured, Data("ready".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "finish must honour its deadline")
        // finish() waits only a short grace for the cancelled reader; allow a loaded scheduler a
        // bounded margin to run the reader's next poll before requiring that it retired.
        let retiredBy = Date().addingTimeInterval(5)
        while !drain.isFinished, Date() < retiredBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(drain.isFinished, "deadline must retire the worker even without pipe EOF")
    }

    /// True while unread bytes remain in the pipe (no HUP: a writer is still open).
    private static func hasPendingInput(_ descriptor: Int32) -> Bool {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&event, 1, 0) > 0 && event.revents & Int16(POLLIN) != 0
    }

    func testDrainBoundsCaptureButContinuesReadingPastLimit() throws {
        let pipe = Pipe()
        let drain = DebuggerSubprocessPipeDrain(pipe.fileHandleForReading, maximumCapturedBytes: 1_024)
        // This exceeds a pipe buffer: stopping reads at the capture cap would deadlock here.
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 0x61, count: 200_000))
        try pipe.fileHandleForWriting.close()
        let captured = drain.finish(deadline: .now() + .seconds(5))
        XCTAssertTrue(drain.isFinished)
        XCTAssertEqual(captured, Data(repeating: 0x61, count: 1_024)
            + DebuggerSubprocessPipeDrain.truncationMarker)
    }

    func testCoreTestPipeDrainCollectsBothPipesWhenWaitingBeforeJoin() throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.largeOutputScript]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutDrain = CoreTestPipeDrain(stdout)
        let stderrDrain = CoreTestPipeDrain(stderr)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdoutDrain.data().count, Self.stdoutBytes)
        XCTAssertEqual(stderrDrain.data().count, Self.stderrBytes)
    }
}

/// Regression coverage for the AttributeGraph reentrancy abort: the LLDB capability proof ran
/// inside `EditorSurfaceView`'s `StateObject` initializer, and the runner's post-timeout
/// `waitUntilExit()` spun the main run loop, which re-entered `NSHostingView.layout` during the
/// outer SwiftUI update. The runner must wait without running the caller's run loop, and the
/// production proof must be memoized per process so editor construction does not run `lldb`.
final class DebuggerProofRunLoopIsolationTests: XCTestCase {
    private static let okProof = DebuggerSubprocessResult(
        terminationStatus: 0,
        standardOutput: """
        lldb-2103.0.23.6
        Platform: host
        Triple: arm64-apple-macosx
        __MACSCOPE_LLDB_PERSISTENT_READY__
        """,
        standardError: "",
        timedOut: false
    )

    /// The child ignores SIGTERM, so the runner must escalate and wait for the reap. The old
    /// `waitUntilExit()` ran the main run loop for that whole wait and fired this timer; a child
    /// that exits on SIGTERM is reaped before the wait starts and would not show the defect.
    @MainActor
    func testRunnerTimeoutWaitsWithoutRunningTheCallersRunLoop() throws {
        XCTAssertTrue(Thread.isMainThread)
        let fired = DebuggerProofTestFlag()
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in fired.set() }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        let started = Date()
        let result = try FoundationDebuggerProcessRunner().run(DebuggerExternalCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"],
            environment: [:],
            workingDirectory: nil,
            timeoutSeconds: 0.3
        ))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.terminationStatus, -1)
        XCTAssertLessThan(elapsed, 4, "timeout, SIGTERM grace and SIGKILL reap must stay bounded")
        XCTAssertFalse(fired.value, "the runner ran the main run loop while waiting for the child")

        // Prove the timer was live: it fires as soon as the run loop is allowed to spin.
        let deadline = Date().addingTimeInterval(2)
        while !fired.value, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(fired.value, "the control timer never fired; the test proves nothing")
    }

    @MainActor
    func testProductionProofRunsOncePerKeyAcrossAdapterConstructions() {
        let cache = DebuggerLLDBProofCache()
        let runner = DebuggerProofCountingRunner(result: Self.okProof)

        let first = makeAdapter(runner: runner, cache: cache, workingDirectory: "/tmp")
        let second = makeAdapter(runner: runner, cache: cache, workingDirectory: "/tmp")
        XCTAssertEqual(runner.count, 1, "same key must reuse the memoized proof")
        XCTAssertEqual(first.capabilities, second.capabilities)
        XCTAssertEqual(first.capabilities.lldbProof?.status, .passed)

        _ = makeAdapter(runner: runner, cache: cache, workingDirectory: "/private/var/tmp")
        XCTAssertEqual(runner.count, 2, "a different working directory is a different key")
        _ = makeAdapter(
            runner: runner,
            cache: cache,
            workingDirectory: "/tmp",
            usePersistentTransport: false
        )
        XCTAssertEqual(runner.count, 3, "the persistent-CLI requirement changes the proof command")

        // An uncached construction (the injected-runner test seam) always runs its runner.
        _ = makeAdapter(runner: runner, cache: nil, workingDirectory: "/tmp")
        XCTAssertEqual(runner.count, 4)
        XCTAssertEqual(cache.runCountForTesting, 3)
    }

    @MainActor
    func testCachedAndUncachedProofsProduceTheSameCapabilityReport() {
        let cached = makeAdapter(
            runner: DebuggerProofCountingRunner(result: Self.okProof),
            cache: DebuggerLLDBProofCache(),
            workingDirectory: "/tmp"
        )
        let uncached = makeAdapter(
            runner: DebuggerProofCountingRunner(result: Self.okProof),
            cache: nil,
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(cached.capabilities, uncached.capabilities)
        XCTAssertEqual(cached.initialBackendState, uncached.initialBackendState)
    }

    func testConcurrentFirstAccessRunsTheProofOnce() throws {
        let cache = DebuggerLLDBProofCache()
        let count = DebuggerProofTestCounter()
        let command = Self.proofCommand(workingDirectory: "/tmp")
        let okProof = Self.okProof
        let results = DebuggerProofTestResults()
        // @Sendable keeps the work nonisolated whatever isolation XCTestCase carries.
        DispatchQueue.concurrentPerform(iterations: 16) { @Sendable _ in
            let result = try? cache.result(for: command) {
                count.increment()
                Thread.sleep(forTimeInterval: 0.2)
                return okProof
            }
            results.append(result)
        }
        XCTAssertEqual(results.values, Array(repeating: Optional(okProof), count: 16))
        XCTAssertEqual(count.value, 1)
        XCTAssertEqual(cache.runCountForTesting, 1)
    }

    func testPrewarmedProofIsJoinedAndTransientFailuresAreNotMemoized() throws {
        let cache = DebuggerLLDBProofCache()
        let count = DebuggerProofTestCounter()
        let command = Self.proofCommand(workingDirectory: "/tmp")
        let okProof = Self.okProof

        cache.prewarm(command) {
            count.increment()
            Thread.sleep(forTimeInterval: 0.2)
            return okProof
        }
        let joined = try cache.result(for: command) {
            count.increment()
            return okProof
        }
        XCTAssertEqual(joined, okProof)
        XCTAssertEqual(count.value, 1, "a client built during the prewarm joins it")

        let timedOut = DebuggerSubprocessResult(
            terminationStatus: -1,
            standardOutput: "",
            standardError: "",
            timedOut: true
        )
        let other = Self.proofCommand(workingDirectory: "/private/var/tmp")
        XCTAssertEqual(try cache.result(for: other) { timedOut }, timedOut)
        XCTAssertEqual(try cache.result(for: other) { okProof }, okProof, "a timeout is retried")
        XCTAssertThrowsError(try cache.result(for: Self.proofCommand(workingDirectory: "/")) {
            throw DebuggerProcessRunnerError.launchFailed("injected")
        })
        XCTAssertEqual(
            try cache.result(for: Self.proofCommand(workingDirectory: "/")) { okProof },
            okProof,
            "a runner error is retried"
        )
        XCTAssertEqual(try cache.result(for: other) { timedOut }, okProof, "success is memoized")
    }

    private static func proofCommand(workingDirectory: String) -> DebuggerExternalCommand {
        DebuggerExternalCommand(
            executablePath: "/usr/bin/false",
            arguments: ["--batch"],
            environment: ["TERM": "dumb"],
            workingDirectory: workingDirectory,
            timeoutSeconds: 5
        )
    }

    @MainActor
    private func makeAdapter(
        runner: DebuggerProofCountingRunner,
        cache: DebuggerLLDBProofCache?,
        workingDirectory: String,
        usePersistentTransport: Bool = true
    ) -> XcodeLLDBCommandLineAdapter {
        XcodeLLDBCommandLineAdapter(
            toolchain: DebuggerLLDBToolchain(
                executablePath: "/usr/bin/false",
                developerDirectory: nil,
                discoverySource: "test",
                candidatePaths: ["/usr/bin/false"]
            ),
            processRunner: runner,
            environment: [:],
            workingDirectory: workingDirectory,
            usePersistentTransport: usePersistentTransport,
            proofCache: cache
        )
    }
}

private final class DebuggerProofTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.lock()
        isSet = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSet
    }
}

private final class DebuggerProofTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class DebuggerProofTestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DebuggerSubprocessResult?] = []

    func append(_ result: DebuggerSubprocessResult?) {
        lock.lock()
        stored.append(result)
        lock.unlock()
    }

    var values: [DebuggerSubprocessResult?] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class DebuggerProofCountingRunner: DebuggerProcessRunning, @unchecked Sendable {
    private let result: DebuggerSubprocessResult
    private let counter = DebuggerProofTestCounter()

    init(result: DebuggerSubprocessResult) {
        self.result = result
    }

    var count: Int { counter.value }

    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult {
        _ = command
        counter.increment()
        return result
    }
}

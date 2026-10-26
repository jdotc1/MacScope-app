import Darwin
import XCTest

@testable import MacScope

final class Phase2ShellBrokerProcessAdapterTests: XCTestCase {
    func testCloseCannotInvalidateInFlightDuplicatedMasterDescriptor() throws {
        let allocation = try Phase2ShellBrokerPTYAllocator.allocate(initialSize: .defaultInteractive)
        let operationReachedDescriptor = DispatchSemaphore(value: 0)
        let allowOperation = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let operationError = ProcessAdapterErrorBox()
        allocation.masterOperationWillExecute = { _ in
            operationReachedDescriptor.signal()
            _ = allowOperation.wait(timeout: .now() + 5)
        }

        DispatchQueue.global().async {
            do {
                try allocation.resize(Phase2HumanPTYTerminalSize(columns: 132, rows: 43))
            } catch {
                operationError.set(error)
            }
            operationFinished.signal()
        }
        XCTAssertEqual(operationReachedDescriptor.wait(timeout: .now() + 5), .success)

        DispatchQueue.global().async {
            allocation.close()
            closeFinished.signal()
        }
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 5), .success)

        allowOperation.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(operationError.get(), "in-flight operation must retain its own descriptor despite close")
    }

    func testPTYAllocationCreatesNamedSlaveWithInitialSize() throws {
        let allocation = try Phase2ShellBrokerPTYAllocator.allocate(initialSize: .defaultInteractive)
        defer { allocation.close() }

        XCTAssertFalse(allocation.slavePath.isEmpty)
        XCTAssertTrue(allocation.slavePath.hasPrefix("/dev/"))
        XCTAssertEqual(allocation.initialSize, .defaultInteractive)
    }

    func testLaunchBindsProcessOutputToBrokerOwnedPTY() throws {
        let sessionID = processAdapterUUID(10)
        let requestID = processAdapterUUID(11)
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "printf macscope-pty-stdout; printf macscope-pty-stderr >&2; sleep 30"],
            workingDirectoryPath: "/tmp",
            initialSize: Phase2HumanPTYTerminalSize(columns: 100, rows: 24)
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            }
        }

        let output = try waitForPTYOutput(
            from: lease,
            containing: ["macscope-pty-stdout", "macscope-pty-stderr"],
            timeout: 2.0
        )

        XCTAssertEqual(lease.pty.initialSize, Phase2HumanPTYTerminalSize(columns: 100, rows: 24))
        XCTAssertTrue(lease.pty.slavePath.hasPrefix("/dev/"))
        XCTAssertTrue(output.contains("macscope-pty-stdout"), output)
        XCTAssertTrue(output.contains("macscope-pty-stderr"), output)

        let proof = lease.cleanup(timeout: 2.0)
        XCTAssertFalse(lease.isRunning)
        XCTAssertTrue(proof.observedProcessAbsent)
    }

    func testLaunchRunsProcessInExplicitWorkingDirectory() throws {
        let sessionID = processAdapterUUID(12)
        let requestID = processAdapterUUID(13)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-shell-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "pwd; sleep 30"],
            workingDirectoryPath: directoryURL.path,
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            }
        }

        let output = try waitForPTYOutput(
            from: lease,
            containing: [directoryURL.path],
            timeout: 2.0
        )

        XCTAssertTrue(output.contains(directoryURL.path), output)
    }

    func testLaunchCleanupProducesExactLifecycleProofForTestOwnedProcess() throws {
        let sessionID = processAdapterUUID(1)
        let requestID = processAdapterUUID(2)
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            }
        }

        XCTAssertTrue(lease.isRunning)
        XCTAssertEqual(lease.ownedProcess.sessionID, sessionID)
        XCTAssertEqual(lease.ownedProcess.requestID, requestID)
        XCTAssertGreaterThan(lease.ownedProcess.processIdentifier, 0)
        XCTAssertEqual(lease.ownedProcess.executablePath, "/bin/sleep")

        var snapshot = Phase2ShellBrokerLifecycleSnapshot.initial(sessionID: sessionID)
        snapshot = Phase2ShellBrokerLifecycleReducer.prepareLaunch(snapshot, plan: plan)
        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
            snapshot,
            process: lease.ownedProcess
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.requestCleanup(snapshot, reason: .userCancel)
        let proof = lease.cleanup(timeout: 2.0)
        snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(snapshot, proof: proof)

        XCTAssertFalse(lease.isRunning)
        XCTAssertTrue(proof.observedProcessAbsent)
        XCTAssertEqual(snapshot.state, .cleanedUp(
            requestID: requestID,
            processIdentifier: lease.ownedProcess.processIdentifier,
            outcome: .canceled
        ))
        XCTAssertEqual(snapshot.issues, [])
    }

    func testCleanupIsExactlyOnceAndReplaysFirstProof() throws {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: processAdapterUUID(32),
            requestID: processAdapterUUID(33),
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )
        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)

        let first = lease.cleanup(outcome: .canceled, timeout: 1)
        let replay = lease.cleanup(outcome: .outcomeUnknown, timeout: 1)

        XCTAssertEqual(replay, first)
        XCTAssertEqual(replay.outcome, .canceled)
    }

    func testLeaseForwardsHumanInputThroughBrokerOwnedPTY() throws {
        let sessionID = processAdapterUUID(20)
        let requestID = processAdapterUUID(21)
        let marker = "macscope-forwarded-input"
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "IFS= read -r line; printf 'reply:%s\\n' \"$line\"; sleep 30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            }
        }

        let bytesWritten = try lease.writeInput(Array("\(marker)\n".utf8))
        XCTAssertEqual(bytesWritten, marker.utf8.count + 1)

        let output = try waitForPTYOutput(
            from: lease,
            containing: ["reply:\(marker)"],
            timeout: 2.0
        )

        XCTAssertTrue(output.contains("reply:\(marker)"), output)
    }

    func testWriteInputDoesNotBlockWhenChildAppliesBackpressure() throws {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: processAdapterUUID(30),
            requestID: processAdapterUUID(31),
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )
        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer { _ = lease.cleanup(timeout: 0.1) }
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = try? lease.writeInput(Array(repeating: 0x41, count: 4 * 1_024 * 1_024))
            finished.signal()
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 1),
            .success,
            "broker input must fail or complete promptly when the PTY cannot accept more bytes"
        )
    }

    func testBelowWireCapBackpressureReleasesControlForSignalAndExactReaping() throws {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: processAdapterUUID(34), requestID: processAdapterUUID(35),
            executablePath: "/bin/sleep", arguments: ["30"], workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )
        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer { _ = lease.cleanup(timeout: 0.1) }
        // This helper sets and reads back cfmakeraw/VMIN/VTIME after slave open;
        // canonical line discard must not make pressure look like successful delivery.
        try lease.pty.configureSourceExecutionHandshake()
        let finished = DispatchSemaphore(value: 0)
        // Each individual write is below the wire cap; repeated accepted prefixes can still
        // exhaust a nonreading child's input queue. Never retry a partially accepted write.
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                for _ in 0..<256 {
                    _ = try lease.writeInput(Array(repeating: 0x41, count: 4_096))
                }
                XCTFail("Nonreading child unexpectedly accepted all bounded input")
            } catch Phase2ShellBrokerPTYAllocation.IOError.writeFailed(let code, let accepted) {
                XCTAssertTrue(code == EAGAIN || code == EWOULDBLOCK)
                XCTAssertGreaterThanOrEqual(accepted, 0)
                XCTAssertLessThan(accepted, 4_096)
            } catch { XCTFail("Unexpected input failure: \(error)") }
        }
        let completed = finished.wait(timeout: .now() + 1)
        if completed != .success {
            // Keep a regression on the old blocking allocator from hanging test teardown.
            _ = Darwin.kill(-lease.ownedProcess.processIdentifier, SIGKILL)
        }
        XCTAssertEqual(completed, .success)
        guard completed == .success else { return }
        try lease.sendSignal(.terminate)
        let start = Date()
        let proof = lease.cleanup(timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(proof.observedProcessAbsent)
        XCTAssertEqual(proof.processIdentifier, lease.ownedProcess.processIdentifier)
        var status: Int32 = 0
        XCTAssertEqual(Darwin.waitpid(proof.processIdentifier, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "Owned leader must already be reaped exactly once")
    }

    func testInteractiveForegroundJobReceivesInterruptAndCleanup() throws {
        let lease = try Phase2ShellBrokerProcessAdapter().launch(.init(
            sessionID: processAdapterUUID(36), requestID: processAdapterUUID(37),
            executablePath: "/bin/sh", arguments: ["-i"], workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        ))
        defer { _ = lease.cleanup(timeout: 0.2) }
        XCTAssertTrue(try waitForPTYOutput(from: lease, containing: ["$"], timeout: 2).contains("$"))
        func startForegroundSleep() throws -> Int32 {
            _ = try lease.writeInput(Array("sleep 30\n".utf8))
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let group = try lease.pty.foregroundProcessGroup(ownedSessionID: lease.ownedProcess.processIdentifier),
                   group != lease.ownedProcess.processIdentifier { return group }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw NSError(domain: "ForegroundPTYFixture", code: 1)
        }
        let interruptedGroup = try startForegroundSleep()
        XCTAssertEqual(Darwin.getsid(interruptedGroup), lease.ownedProcess.processIdentifier)
        try lease.sendSignal(.interrupt)
        XCTAssertTrue(try waitForPTYOutput(from: lease, containing: ["$"], timeout: 2).contains("$"))
        XCTAssertEqual(Darwin.kill(-interruptedGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let cleanedGroup = try startForegroundSleep()
        let start = Date()
        let proof = lease.cleanup(timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(proof.observedProcessAbsent)
        XCTAssertEqual(Darwin.kill(-cleanedGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(Darwin.waitpid(proof.processIdentifier, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testForegroundInterruptDoesNotInheritLaunchingThreadSignalMask() throws {
        // pthread_sigmask affects only this synchronous caller. Restore it before any PTY waits
        // or assertions outside the launch closure, including when launch throws.
        let lease: Phase2ShellBrokerProcessLease = try {
            var blocked = sigset_t()
            XCTAssertEqual(sigemptyset(&blocked), 0)
            XCTAssertEqual(sigaddset(&blocked, SIGINT), 0)
            XCTAssertEqual(sigaddset(&blocked, SIGTERM), 0)
            var previousMask = sigset_t()
            let status = pthread_sigmask(SIG_BLOCK, &blocked, &previousMask)
            guard status == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
            }
            defer { XCTAssertEqual(pthread_sigmask(SIG_SETMASK, &previousMask, nil), 0) }
            return try Phase2ShellBrokerProcessAdapter().launch(.init(
                sessionID: processAdapterUUID(38), requestID: processAdapterUUID(39),
                executablePath: "/bin/sh", arguments: ["-i"], workingDirectoryPath: "/tmp",
                initialSize: .defaultInteractive
            ))
        }()
        defer { _ = lease.cleanup(timeout: 0.2) }
        XCTAssertTrue(try waitForPTYOutput(from: lease, containing: ["$"], timeout: 2).contains("$"))

        // Read the child's actual thread mask, then preserve it across exec into the foreground
        // sleeper. kinfo_proc's legacy process mask does not establish signal deliverability.
        let command = #"/usr/bin/python3 -c 'import os, signal; blocked = signal.pthread_sigmask(signal.SIG_BLOCK, []); print("MS_SIGNAL_MASK=" + str(sorted(int(value) for value in blocked)), flush=True); os.execv("/bin/sleep", ["sleep", "30"])'"# + "\n"
        _ = try lease.writeInput(Array(command.utf8))
        let output = try waitForPTYOutput(
            from: lease, containing: ["MS_SIGNAL_MASK=[]"], timeout: 5
        )
        XCTAssertTrue(output.contains("MS_SIGNAL_MASK=[]"), output)
        let foreground = try XCTUnwrap(
            lease.pty.foregroundProcessGroup(ownedSessionID: lease.ownedProcess.processIdentifier)
        )
        XCTAssertNotEqual(foreground, lease.ownedProcess.processIdentifier)
        XCTAssertEqual(Darwin.getsid(foreground), lease.ownedProcess.processIdentifier)
        try lease.sendSignal(.interrupt)
        XCTAssertTrue(try waitForPTYOutput(from: lease, containing: ["$"], timeout: 2).contains("$"))
        XCTAssertEqual(Darwin.kill(-foreground, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(lease.isRunning, "Interrupt must leave the interactive parent shell running")
    }

    func testLeaseResizesTerminalAndRejectsInvalidResize() throws {
        let sessionID = processAdapterUUID(22)
        let requestID = processAdapterUUID(23)
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            }
        }

        XCTAssertNoThrow(try lease.resizeTerminal(Phase2HumanPTYTerminalSize(columns: 132, rows: 43)))
        XCTAssertThrowsError(try lease.resizeTerminal(Phase2HumanPTYTerminalSize(columns: 0, rows: 43)))
    }

    func testLeaseSignalsOnlyOwnedProcess() throws {
        let sessionID = processAdapterUUID(24)
        let requestID = processAdapterUUID(25)
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            }
        }

        XCTAssertTrue(lease.isRunning)
        XCTAssertNoThrow(try lease.sendSignal(.terminate))
        XCTAssertTrue(waitForProcessExit(lease, timeout: 2.0))
    }

    func testCleanupTerminatesEntireBrokerOwnedProcessGroup() throws {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: processAdapterUUID(28),
            requestID: processAdapterUUID(29),
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & child=$!; printf 'child:%s\\n' \"$child\"; wait",
            ],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        XCTAssertEqual(Darwin.getpgid(lease.ownedProcess.processIdentifier), lease.ownedProcess.processIdentifier)
        XCTAssertEqual(Darwin.getsid(lease.ownedProcess.processIdentifier), lease.ownedProcess.processIdentifier)
        let output = try waitForPTYOutput(from: lease, containing: ["child:"], timeout: 2.0)
        let childPID = try XCTUnwrap(
            output.split(separator: "\n")
                .first(where: { $0.hasPrefix("child:") })
                .flatMap { Int32($0.dropFirst("child:".count).trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
        defer {
            if processExists(childPID) {
                _ = Darwin.kill(childPID, SIGKILL)
            }
        }

        let proof = lease.cleanup(timeout: 0.1)

        XCTAssertTrue(proof.observedProcessAbsent)
        XCTAssertTrue(
            waitForProcessAbsence(childPID, timeout: 2.0),
            "cleanup must terminate descendants in the broker-owned process group"
        )
    }

    func testLeaseObservesNaturalExitOutcomeWithoutCancelingProcess() throws {
        let sessionID = processAdapterUUID(26)
        let requestID = processAdapterUUID(27)
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "printf macscope-natural-exit; exit 7"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer {
            if lease.isRunning {
                _ = lease.cleanup(timeout: 1.0)
            } else {
                lease.closePTYAfterObservedExit()
            }
        }

        let output = try waitForPTYOutput(
            from: lease,
            containing: ["macscope-natural-exit"],
            timeout: 2.0
        )
        XCTAssertTrue(output.contains("macscope-natural-exit"), output)
        XCTAssertTrue(waitForProcessExit(lease, timeout: 2.0))
        XCTAssertEqual(lease.observedTerminalOutcomeIfExited, .exited(status: 7))
    }

    func testAdapterRejectsInvalidLaunchPlanBeforeSpawning() {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: processAdapterUUID(3),
            requestID: processAdapterUUID(4),
            executablePath: "sleep",
            arguments: ["30"],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        XCTAssertThrowsError(try Phase2ShellBrokerProcessAdapter().launch(plan)) { error in
            XCTAssertEqual(
                error as? Phase2ShellBrokerProcessAdapter.LaunchError,
                .invalidLaunchPlan([.executablePathNotAbsolute("sleep")])
            )
        }
    }

    func testAdapterReportsRunFailureWithoutClaimingOwnership() {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: processAdapterUUID(5),
            requestID: processAdapterUUID(6),
            executablePath: "/tmp/macscope-r2-missing-process-adapter-fixture",
            arguments: [],
            workingDirectoryPath: "/tmp",
            initialSize: .defaultInteractive
        )

        XCTAssertThrowsError(try Phase2ShellBrokerProcessAdapter().launch(plan)) { error in
            guard case .runFailed = error as? Phase2ShellBrokerProcessAdapter.LaunchError else {
                return XCTFail("Expected runFailed, got \(error)")
            }
        }
    }
}

private final class ProcessAdapterErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.withLock { self.error = error }
    }

    func get() -> Error? {
        lock.withLock { error }
    }
}

private func processAdapterUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "22000000-0000-0000-0000-%012llx", value))!
}

private func waitForPTYOutput(
    from lease: Phase2ShellBrokerProcessLease,
    containing requiredFragments: [String],
    timeout: TimeInterval
) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var bytes: [UInt8] = []

    while Date() < deadline {
        bytes.append(contentsOf: lease.readAvailablePTYOutput(timeout: 0.05))
        let output = String(decoding: bytes, as: UTF8.self)
        if requiredFragments.allSatisfy(output.contains) {
            return output
        }
    }

    return String(decoding: bytes, as: UTF8.self)
}

private func waitForProcessExit(
    _ lease: Phase2ShellBrokerProcessLease,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !lease.isRunning {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return !lease.isRunning
}

private func waitForProcessAbsence(_ processIdentifier: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processExists(processIdentifier) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return !processExists(processIdentifier)
}

private func processExists(_ processIdentifier: Int32) -> Bool {
    errno = 0
    if Darwin.kill(processIdentifier, 0) == 0 {
        return true
    }
    return errno == EPERM
}

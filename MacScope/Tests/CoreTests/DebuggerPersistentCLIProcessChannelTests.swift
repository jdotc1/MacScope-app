import Darwin
import Foundation
import XCTest

#if canImport(MacScope)
@testable import MacScope
#endif

final class DebuggerPersistentCLIProcessChannelTests: XCTestCase {
    func testLaunchPlanRequiresSelectedXcodeBundledLLDBAndConfiguresInterpreterStartup() throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = developerDirectory + "/usr/bin/lldb"
        let plan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: lldbPath,
            developerDirectory: developerDirectory,
            environment: ["PATH": "/usr/bin"],
            workingDirectory: "/tmp"
        )

        XCTAssertEqual(plan.executablePath, lldbPath)
        XCTAssertEqual(
            plan.arguments,
            [
                "--no-lldbinit",
                "--one-line",
                "settings set interpreter.echo-commands false",
                "--one-line",
                PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand,
            ]
        )
        XCTAssertEqual(plan.environment["DEVELOPER_DIR"], developerDirectory)
        XCTAssertEqual(plan.workingDirectory, "/tmp")
        XCTAssertTrue(plan.usesMergedOrderedOutput)
    }

    func testLaunchPlanRejectsNonXcodeAndTraversalPaths() {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"

        XCTAssertThrowsError(
            try PersistentLLDBCLIProcessLaunchPlan.make(
                lldbExecutablePath: "/usr/bin/lldb",
                developerDirectory: developerDirectory,
                environment: [:],
                workingDirectory: "/tmp"
            )
        )
        XCTAssertThrowsError(
            try PersistentLLDBCLIProcessLaunchPlan.make(
                lldbExecutablePath: developerDirectory + "/../usr/bin/lldb",
                developerDirectory: developerDirectory,
                environment: [:],
                workingDirectory: "/tmp"
            )
        )
        XCTAssertThrowsError(
            try PersistentLLDBCLIProcessLaunchPlan.make(
                lldbExecutablePath: developerDirectory + "/usr/bin/lldb",
                developerDirectory: "relative/Xcode.app/Contents/Developer",
                environment: [:],
                workingDirectory: "/tmp"
            )
        )
    }

    func testConfiguredProcessUsesOnePipeForCausallyOrderedStdoutAndStderr() throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let plan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: developerDirectory + "/usr/bin/lldb",
            developerDirectory: developerDirectory,
            environment: [:],
            workingDirectory: "/tmp"
        )
        let configured = try FoundationPersistentLLDBCLIProcessChannel.configureProcess(for: plan)

        XCTAssertTrue((configured.process.standardOutput as? Pipe) === configured.outputPipe)
        XCTAssertTrue((configured.process.standardError as? Pipe) === configured.outputPipe)
        XCTAssertTrue((configured.process.standardInput as? Pipe) === configured.inputPipe)
        XCTAssertEqual(configured.process.arguments, plan.arguments)
    }

    func testConfiguredInputSuppressesSIGPIPEAndMapsClosedReaderToInputClosed() throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let plan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: developerDirectory + "/usr/bin/lldb",
            developerDirectory: developerDirectory,
            environment: [:],
            workingDirectory: "/tmp"
        )
        let configured = try FoundationPersistentLLDBCLIProcessChannel.configureProcess(for: plan)
        let writeDescriptor = configured.inputPipe.fileHandleForWriting.fileDescriptor

        XCTAssertEqual(Darwin.fcntl(writeDescriptor, F_GETNOSIGPIPE), 1)
        try configured.inputPipe.fileHandleForReading.close()

        XCTAssertThrowsError(
            try FoundationPersistentLLDBCLIProcessChannel.writeAll(
                Data("closed-reader".utf8),
                to: writeDescriptor
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentLLDBCLIProcessChannelError,
                .inputClosed
            )
        }

        try configured.inputPipe.fileHandleForWriting.close()
        try configured.outputPipe.fileHandleForReading.close()
    }

    func testConcreteChannelBoundsExactTestOwnedLLDBTerminationAndClosesHandles() async throws {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = developerDirectory + "/usr/bin/lldb"
        guard FileManager.default.isExecutableFile(atPath: lldbPath) else {
            throw XCTSkip("The selected Xcode-bundled LLDB is unavailable.")
        }
        let plan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: lldbPath,
            developerDirectory: developerDirectory,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let channel = try await FoundationPersistentLLDBCLIProcessChannel.launch(plan: plan)
        let retainedPID = await channel.retainedProcessIdentifier
        XCTAssertGreaterThan(retainedPID, 0)

        await channel.terminateRetainedAdapter()
        let exited = await channel.waitForExit(maximumDuration: .seconds(2))
        if !exited {
            let sentKill = await channel.killRetainedAdapterIfStillRunning()
            let exitedAfterKill = await channel.waitForExit(maximumDuration: .seconds(2))
            XCTAssertTrue(sentKill)
            XCTAssertTrue(exitedAfterKill)
        }
        let reaped = await channel.reapAndClose()
        await channel.closeInput()
        await channel.closeHandles()

        let isRunning = await channel.isRetainedAdapterRunning
        let finalPID = await channel.retainedProcessIdentifier
        XCTAssertTrue(reaped)
        XCTAssertFalse(isRunning)
        XCTAssertEqual(finalPID, retainedPID)
    }

    func testConcreteChannelPreservesOrderedMultiChunkExchanges() async throws {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = developerDirectory + "/usr/bin/lldb"
        guard FileManager.default.isExecutableFile(atPath: lldbPath) else {
            throw XCTSkip("The selected Xcode-bundled LLDB is unavailable.")
        }
        let plan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: lldbPath,
            developerDirectory: developerDirectory,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory.path
        )
        let channel = try await FoundationPersistentLLDBCLIProcessChannel.launch(plan: plan)
        let epoch = DebuggerSessionEpoch()
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: channel
        )

        do {
            let large = try await adapter.executeCoordinatorSelected(
                request(
                    epoch: epoch,
                    sequence: 1,
                    command: "settings list"
                )
            )
            let settings = try XCTUnwrap(
                large.transcript.semanticCommandTranscripts.first
            )
            XCTAssertGreaterThan(settings.utf8.count, 8_192)
            XCTAssertTrue(settings.contains("target."))

            let next = try await adapter.executeCoordinatorSelected(
                request(epoch: epoch, sequence: 2, command: "version")
            )
            XCTAssertTrue(
                next.transcript.semanticCommandTranscripts.first?
                    .localizedCaseInsensitiveContains("lldb") == true
            )
            _ = await adapter.shutdown()
        } catch {
            _ = await adapter.shutdown()
            throw error
        }
    }

    /// Real-LLDB regression for the retirement orphan: command-free retirement must let LLDB exit
    /// on stdin EOF (killing the inferior it launched) instead of SIGTERMing it first, which left
    /// the launched fixture stopped (state T) and orphaned.
    func testCommandFreeRetirementLeavesNoStoppedLaunchedInferior() async throws {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = developerDirectory + "/usr/bin/lldb"
        guard FileManager.default.isExecutableFile(atPath: lldbPath) else {
            throw XCTSkip("The selected Xcode-bundled LLDB is unavailable.")
        }
        let fixture = TestSourceRoot.url
            .appendingPathComponent("MacScope/Tests/Fixtures/RX01Versioned/rx01_v1")
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
            throw XCTSkip("RX01 fixture is unavailable.")
        }
        let plan = try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: lldbPath,
            developerDirectory: developerDirectory,
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin",
                "TERM": "dumb",
                "NSUnbufferedIO": "YES",
            ],
            workingDirectory: fixture.deletingLastPathComponent().path
        )
        let channel = try await FoundationPersistentLLDBCLIProcessChannel.launch(plan: plan)
        let epoch = DebuggerSessionEpoch()
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: channel
        )
        var inferiorPID: Int32?
        defer {
            // Only the inferior this test launched is ever signalled, and only if it survived.
            if let inferiorPID, kill(inferiorPID, 0) == 0 { kill(inferiorPID, SIGKILL) }
        }

        let quotedPath = "\"" + fixture.path + "\""
        _ = try await adapter.executeCoordinatorSelected(
            request(epoch: epoch, sequence: 1, command: "target create \(quotedPath)")
        )
        let launch = try await adapter.executeCoordinatorSelected(
            request(epoch: epoch, sequence: 2, command: "process launch --stop-at-entry --no-stdio")
        )
        let launchText = launch.transcript.semanticCommandTranscripts.joined(separator: "\n")
        let textPID = launchText.firstMatch(of: /Process (\d+) (?:launched|stopped)/)
            .flatMap { Int32($0.1) }
        guard let pid = launch.transcript.observedProcessID ?? textPID, pid > 0 else {
            _ = await adapter.retireRetainedAdapterWithoutDebuggerCommand()
            throw XCTSkip("This host does not permit LLDB to launch the fixture: \(launchText)")
        }
        inferiorPID = pid
        XCTAssertEqual(kill(pid, 0), 0, "the launched fixture must be alive before retirement")

        let receipt = await adapter.retireRetainedAdapterWithoutDebuggerCommand()

        XCTAssertFalse(receipt.requestedGracefulQuit)
        XCTAssertFalse(receipt.sentTerminate, "LLDB must exit on stdin EOF within the grace period")
        XCTAssertTrue(receipt.didExit)
        XCTAssertTrue(receipt.didReap)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "the launched fixture must not survive retirement")
    }

    private func request(
        epoch: DebuggerSessionEpoch,
        sequence: UInt64,
        command: String
    ) throws -> PersistentLLDBCLIRequest {
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: .initial
        )
        return try PersistentLLDBCLIRequest(
            context: DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: sequence),
                operation: .refreshSnapshot,
                expectedSession: session,
                requiredStop: DebuggerStopCoordinate(
                    session: session,
                    stopRevision: .initial
                )
            ),
            semanticCommands: [command],
            observedPIDRequirement: .optional,
            timeout: .seconds(3)
        )
    }
}

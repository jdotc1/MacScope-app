import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// Real-LLDB regression for the Tier 2b "Launch failed in the correlated LLDB session
/// (adapterInvalidated)" defect. Xcode 27 LLDB pins the interpreter execution context for the whole
/// outer `script` exchange, so the wrapper's in-exchange `process status` after
/// `process launch --stop-at-entry` used to report "Command requires a current process." and the
/// decoder (PID required) invalidated the adapter. This drives the exact production wire and
/// decoder against the selected Xcode LLDB and the RX01 fixture.
final class DebuggerPersistentLLDBLiveLaunchStatusTests: XCTestCase {
    @MainActor
    func testLaunchExchangeObservesTheStoppedProcessInTheSameExchange() throws {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = developerDirectory + "/usr/bin/lldb"
        guard FileManager.default.isExecutableFile(atPath: lldbPath) else {
            throw XCTSkip("Xcode LLDB is unavailable on this host.")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Bound the whole exchange: terminating LLDB closes the pipe and unblocks reads.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer {
            watchdog.cancel()
            // Stdin EOF makes LLDB quit and kill the inferior it launched. SIGTERM would leave the
            // fixture stopped at entry, so it is only the bounded fallback.
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func exchange(
            _ command: String,
            sequence: Int,
            requirement: LLDBCLIObservedPIDRequirement
        ) throws -> LLDBCLITranscriptResult {
            let token = SHA256.hash(data: Data("live-launch-\(sequence)-\(UUID())".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let markers = try LLDBCLIExchangeMarkers(token: token)
            var decoder = LLDBCLITranscriptDecoder(
                markers: markers,
                observedPIDRequirement: requirement,
                requiresSemanticCommandStatus: true,
                expectedSemanticCommandCount: 1
            )
            try input.fileHandleForWriting.write(
                contentsOf: PersistentLLDBCLIAdapter.encodedWirePayload(
                    semanticCommands: [command],
                    markers: markers
                )
            )
            while true {
                let bytes = output.fileHandleForReading.availableData
                guard !bytes.isEmpty else {
                    throw XCTSkip("LLDB exited before answering `\(command)`.")
                }
                if let result = try decoder.append(bytes) { return result }
            }
        }

        let create = try exchange(
            XcodeLLDBCommandLineAdapter.makeTargetCreateCommand(
                for: DebuggerLaunchConfiguration(executablePath: fixture.path)
            ),
            sequence: 1,
            requirement: .optional
        )
        XCTAssertTrue(create.semanticCommandsSucceeded)
        XCTAssertNil(create.observedProcessID)

        let launch = try exchange(
            "process launch --stop-at-entry --no-stdio",
            sequence: 2,
            requirement: .optional
        )
        guard launch.semanticCommandsSucceeded else {
            throw XCTSkip("This host does not permit LLDB to launch the fixture: \(launch.transcript)")
        }
        // Production requires this PID (`.required`); before the fix the launch succeeded but the
        // same-exchange status readback carried no process at all.
        let processID = try XCTUnwrap(launch.observedProcessID, launch.authoritativeStatusTranscript)
        XCTAssertGreaterThan(processID, 0)
        XCTAssertEqual(launch.observedProcessState, .stopped(processID: processID))
    }
}

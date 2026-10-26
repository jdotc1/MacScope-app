import Darwin
import Foundation
import XCTest

@testable import MacScope

/// Serialized live acceptance for the frozen SBValue extractor and canonical Swift decoder.
/// The test builds its own arm64 debug target, launches it only as an LLDB child, and signals a
/// target PID during cleanup only after libproc proves that PID still names the exact fixture.
final class DebuggerVariablesLiveFixtureTests: XCTestCase {
    func testSourceBuiltFixtureTreatsMissingStaticScopeAsEmpty() throws {
        let fileManager = FileManager.default
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let clang = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        let lldb = URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/lldb")
        let sdk = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        guard fileManager.isExecutableFile(atPath: clang.path),
              fileManager.isExecutableFile(atPath: lldb.path),
              fileManager.fileExists(atPath: sdk.path) else {
            throw XCTSkip("The selected Xcode 27 clang/LLDB tools are unavailable.")
        }

        let fixtureSource = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DebuggerVariablesLiveFixture.c")
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MacScopeVariablesEmptyStaticLive-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("variables-empty-static-live-fixture")
        let commandFile = root.appendingPathComponent("variables-empty-static-live.lldb")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        try runTool(clang, arguments: [
            "-arch", "arm64", "-g", "-O0", "-fno-omit-frame-pointer",
            "-isysroot", sdk.path,
            fixtureSource.path, "-o", executable.path,
        ])

        let token = Data(repeating: 0x6b, count: 32)
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        let extractor = LLDBVariableExtractorProgram.current.source
        let python = """
        import lldb
        namespace = {'__builtins__': __builtins__}
        exec(compile(\(pythonLiteral(extractor)), '<macscope-empty-static-variables>', 'exec'), namespace, namespace)
        process = lldb.debugger.GetSelectedTarget().GetProcess()
        thread = process.GetSelectedThread()
        frame = thread.GetFrameAtIndex(1)
        namespace['extract']('\(tokenHex)', process.GetProcessID(), process.GetStopID(), thread.GetThreadID(), 1, frame.GetPC())
        process.Continue()
        """
        let commands = """
        settings set auto-confirm true
        target create \(lldbQuoted(executable.path))
        breakpoint set --name macscope_variables_empty_static_stop
        run empty-static
        script exec(\(pythonLiteral(python)))
        quit
        """
        try Data(commands.utf8).write(to: commandFile, options: .atomic)

        let result = try runTool(lldb, arguments: ["--batch", "--source", commandFile.path])
        let sentinel = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
        let snapshots = result.components(separatedBy: .newlines).filter { $0.hasPrefix(sentinel) }
        XCTAssertEqual(snapshots.count, 1, result)
        let snapshot = try LLDBVariableSnapshotDecoder().decodeSemanticTranscript(
            try XCTUnwrap(snapshots.first) + "\n"
        )
        XCTAssertTrue(snapshot.variables.filter { $0.scope == .staticVariable }.isEmpty)
        let aggregate = try XCTUnwrap(snapshot.variables.first {
            $0.scope == .local && $0.name == "aggregate_local"
        })
        XCTAssertTrue(aggregate.hasChildren)
        XCTAssertEqual(aggregate.childCount, 2)
        try assertNoExactFixtureProcess(snapshot.observedProcessID, executable: executable)
    }

    func testSourceBuiltFixtureExtractsTypedVariablesAndRejectsStaleStopCoordinate() throws {
        let fileManager = FileManager.default
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let clang = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        let lldb = URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/lldb")
        let sdk = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        guard fileManager.isExecutableFile(atPath: clang.path),
              fileManager.isExecutableFile(atPath: lldb.path),
              fileManager.fileExists(atPath: sdk.path) else {
            throw XCTSkip("The selected Xcode 27 clang/LLDB tools are unavailable.")
        }

        let fixtureSource = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DebuggerVariablesLiveFixture.c")
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MacScopeVariablesLive-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("variables-live-fixture")
        let commandFile = root.appendingPathComponent("variables-live.lldb")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        try runTool(clang, arguments: [
            "-arch", "arm64", "-g", "-O0", "-fno-omit-frame-pointer",
            "-isysroot", sdk.path,
            fixtureSource.path, "-o", executable.path,
        ])

        let token = Data(repeating: 0x5a, count: 32)
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        let extractor = LLDBVariableExtractorProgram.current.source
        let python = """
        import lldb
        namespace = {'__builtins__': __builtins__}
        exec(compile(\(pythonLiteral(extractor)), '<macscope-live-variables>', 'exec'), namespace, namespace)
        process = lldb.debugger.GetSelectedTarget().GetProcess()
        thread = process.GetSelectedThread()
        frame = thread.GetFrameAtIndex(1)
        pid = process.GetProcessID()
        stop_id = process.GetStopID()
        thread_id = thread.GetThreadID()
        pc = frame.GetPC()
        namespace['extract']('\(tokenHex)', pid, stop_id, thread_id, 1, pc)
        process.Continue()
        process.GetState()
        try:
            namespace['extract']('\(tokenHex)', pid, stop_id, thread_id, 1, pc)
            print('MACSCOPE_LLDB_STALE_COORDINATE_V1 accepted')
        except Exception:
            print('MACSCOPE_LLDB_STALE_COORDINATE_V1 rejected')
        """
        let commands = """
        settings set auto-confirm true
        target create \(lldbQuoted(executable.path))
        breakpoint set --name macscope_variables_live_stop
        run live-argument
        script exec(\(pythonLiteral(python)))
        quit
        """
        try Data(commands.utf8).write(to: commandFile, options: .atomic)

        let result = try runTool(lldb, arguments: ["--batch", "--source", commandFile.path])
        let sentinel = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
        let snapshots = result.components(separatedBy: .newlines).filter { $0.hasPrefix(sentinel) }
        XCTAssertEqual(snapshots.count, 1, result)
        let snapshot = try LLDBVariableSnapshotDecoder().decodeSemanticTranscript(
            try XCTUnwrap(snapshots.first) + "\n"
        )

        XCTAssertEqual(snapshot.token, token)
        XCTAssertEqual(snapshot.frameIndex, 1)
        XCTAssertGreaterThan(snapshot.observedStopID, 0)
        XCTAssertTrue(result.contains("MACSCOPE_LLDB_STALE_COORDINATE_V1 rejected"), result)

        let argument = try XCTUnwrap(snapshot.variables.first {
            $0.scope == .argument && $0.name == "argument"
        })
        XCTAssertEqual(argument.typeName, "int")
        XCTAssertEqual(argument.value, "7")

        let scalar = try XCTUnwrap(snapshot.variables.first {
            $0.scope == .local && $0.name == "scalar_local"
        })
        XCTAssertEqual(scalar.typeName, "volatile int")
        XCTAssertEqual(scalar.value, "12")

        let aggregate = try XCTUnwrap(snapshot.variables.first {
            $0.scope == .local && $0.name == "aggregate_local"
        })
        XCTAssertTrue(aggregate.typeName.contains("MacScopeVariablePair"))
        XCTAssertTrue(aggregate.hasChildren)
        XCTAssertEqual(aggregate.childCount, 2)

        let staticValue = try XCTUnwrap(snapshot.variables.first {
            $0.scope == .staticVariable && $0.name == "static_local"
        })
        XCTAssertEqual(staticValue.typeName, "volatile int")
        XCTAssertEqual(staticValue.value, "91")

        try assertNoExactFixtureProcess(snapshot.observedProcessID, executable: executable)
    }

    @discardableResult
    private func runTool(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let drain = CoreTestPipeDrain(output)
        process.waitUntilExit()
        let text = drain.text()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DebuggerVariablesLiveFixtureTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }

    private func assertNoExactFixtureProcess(_ pid: Int32, executable: URL) throws {
        guard kill(pid, 0) == 0 else { return }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro and is not imported into Swift.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else {
            return XCTFail("Could not prove identity of residual fixture PID \(pid); no signal sent.")
        }
        let observed = String(cString: buffer)
        guard URL(fileURLWithPath: observed).standardizedFileURL == executable.standardizedFileURL else {
            return XCTFail("PID \(pid) belongs to \(observed), not the test fixture; no signal sent.")
        }
        XCTAssertEqual(kill(pid, SIGKILL), 0, "Exact fixture PID cleanup failed.")
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        XCTFail("LLDB left exact fixture PID \(pid) running; the test cleaned it up safely.")
    }

    private func pythonLiteral(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    private func lldbQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

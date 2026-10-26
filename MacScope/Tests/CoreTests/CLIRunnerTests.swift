import Foundation
import XCTest
@testable import MacScope

final class CLIRunnerTests: XCTestCase {
    func testProductionOutputLimitIsAtLeast64MiB() {
        XCTAssertGreaterThanOrEqual(CLIRunner.Limits.production.maximumOutputBytes, 64 * 1_024 * 1_024)
    }

    @MainActor
    func testTypedReadScriptRecordsCLIProposalAndAppAuthorization() throws {
        let binary = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: binary.path) else { throw XCTSkip("no /bin/ls") }
        let script = Data(#"[{"command":"read-evidence","arguments":{"operation":"workspace.summary"}}]"#.utf8)
        let output = try CLIRunner.execute(scriptData: script, binaryURL: binary)
        let result = try XCTUnwrap(try ScriptValue.decode(output).arrayValue?.first)
        XCTAssertEqual(result["status"]?.stringValue, "accepted")
        XCTAssertEqual(result["proposingPrincipal"]?.stringValue, "cli")
        XCTAssertEqual(result["authorizingPrincipal"]?.stringValue, "app")
        XCTAssertNotNil(result["facts"]?["loadedImageCount"]?.stringValue)
    }

    func testRequestParsing() {
        let parsed = CLIRunner.request(from: ["app", "--run-script", "/tmp/s.json", "/bin/ls"])
        XCTAssertEqual(
            parsed?.script.path,
            URL(fileURLWithPath: "/tmp/s.json").resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(
            parsed?.binary.path,
            URL(fileURLWithPath: "/bin/ls").resolvingSymlinksInPath().standardizedFileURL.path
        )

        XCTAssertNil(CLIRunner.request(from: ["app"]))
        XCTAssertNil(CLIRunner.request(from: ["app", "--run-script"]))             // no paths
        XCTAssertNil(CLIRunner.request(from: ["app", "--run-script", "/tmp/s.json"])) // script but no binary
        XCTAssertNil(CLIRunner.request(from: ["app", "--mcp", "/bin/ls"]))         // different mode
        XCTAssertNil(CLIRunner.request(from: ["app", "x", "--run-script", "s", "b"])) // flag not in the mode slot
        XCTAssertNil(CLIRunner.request(from: ["app", "--run-script", "s", "b", "extra"]))

        // A positional value that looks like another mode's flag stays a positional value
        // (it is NOT reinterpreted): this parses as CLI mode with the "--mcp=…" token as
        // the script path, NOT hijacked into MCP mode.
        let tricky = CLIRunner.request(from: ["app", "--run-script", "--mcp=/etc/passwd", "/bin/ls"])
        XCTAssertNotNil(tricky)
        XCTAssertEqual(
            tricky?.binary.path,
            URL(fileURLWithPath: "/bin/ls").resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(tricky?.script.lastPathComponent, "passwd")
        // ...and the MCP parser refuses to claim that same argv (the anti-hijack guarantee).
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--run-script", "--mcp=/etc/passwd", "/bin/ls"]))
    }

    func testRequestAndLoaderBindCanonicalScriptWithAnExactByteLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-script-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("script.json")
        let alias = directory.appendingPathComponent("alias.json")
        let bytes = Data(#"[{"command":"info"}]"#.utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let request = try XCTUnwrap(CLIRunner.request(from: [
            "app", "--run-script", alias.path, "/bin/ls",
        ]))
        XCTAssertEqual(request.script.path, target.standardizedFileURL.path)
        XCTAssertEqual(try CLIRunner.loadScript(at: request.script, maximumBytes: bytes.count), bytes)
        XCTAssertThrowsError(try CLIRunner.loadScript(at: request.script, maximumBytes: bytes.count - 1)) {
            XCTAssertTrue($0 is CLIRunnerError)
        }
    }

    @MainActor
    func testExecuteRunsBatchScriptAgainstRealBinary() throws {
        // End-to-end: load a real Mach-O and run a multi-step batch script through the
        // same command surface the MCP server uses — the full `--run-script` path minus
        // the file read and process exit.
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }

        let script = #"""
        [
          {"command": "info"},
          {"command": "functions", "arguments": {"limit": 2}}
        ]
        """#
        let output = try CLIRunner.execute(scriptData: Data(script.utf8), binaryURL: lsURL)
        let decoded = try ScriptValue.decode(output)

        // Results come back as an array — one entry per step, in order.
        let results = try XCTUnwrap(decoded.arrayValue)
        XCTAssertEqual(results.count, 2)
        XCTAssertNotNil(results[0]["functionCount"], "first step is `info`")
        let functions = try XCTUnwrap(results[1].arrayValue, "second step is `functions`")
        XCTAssertLessThanOrEqual(functions.count, 2, "limit:2 is honored")
        XCTAssertFalse(functions.isEmpty, "/bin/ls has functions")
    }

    @MainActor
    func testExecuteThrowsOnMalformedScript() throws {
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        // A script must be a JSON array of steps, not an object.
        XCTAssertThrowsError(try CLIRunner.execute(scriptData: Data(#"{"command":"info"}"#.utf8), binaryURL: lsURL))
    }

    @MainActor
    func testExecuteRejectsDuplicateJSONKeysAndDeniedFilesystemCommands() throws {
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let duplicate = Data(#"[{"command":"info","command":"functions"}]"#.utf8)
        XCTAssertThrowsError(try CLIRunner.execute(scriptData: duplicate, binaryURL: lsURL))

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-authority-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let denied = Data(#"[{"command":"save-patched-binary","arguments":{"path":"\#(destination.path)"}}]"#.utf8)
        XCTAssertThrowsError(try CLIRunner.execute(scriptData: denied, binaryURL: lsURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testExecuteBoundsInputOutputAndRejectsLateResults() throws {
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let script = Data(#"[{"command":"info"}]"#.utf8)

        XCTAssertThrowsError(try CLIRunner.execute(
            scriptData: script,
            binaryURL: lsURL,
            limits: .init(
                maximumScriptBytes: script.count - 1,
                maximumOutputBytes: 8_192,
                maximumCommandDurationNanoseconds: 1_000
            )
        )) { XCTAssertTrue($0 is CLIRunnerError) }

        XCTAssertThrowsError(try CLIRunner.execute(
            scriptData: script,
            binaryURL: lsURL,
            limits: .init(
                maximumScriptBytes: 1_024,
                maximumOutputBytes: 8,
                maximumCommandDurationNanoseconds: .max
            )
        )) { XCTAssertEqual($0 as? CLIRunnerError, .outputTooLarge) }

        var ticks: [UInt64] = [10, 12]
        XCTAssertThrowsError(try CLIRunner.execute(
            scriptData: script,
            binaryURL: lsURL,
            limits: .init(
                maximumScriptBytes: 1_024,
                maximumOutputBytes: 8_192,
                maximumCommandDurationNanoseconds: 1
            ),
            monotonicNow: { ticks.removeFirst() }
        )) { error in
            XCTAssertEqual(error as? CLIRunnerError, .commandDeadlineExceeded)
        }
    }
}

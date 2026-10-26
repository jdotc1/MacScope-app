import Foundation
import XCTest
@testable import MacScope

final class MCPLauncherTests: XCTestCase {
    func testRequestedBinaryParsing() {
        let canonicalLS = URL(fileURLWithPath: "/bin/ls")
            .resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(MCPLauncher.requestedBinary(from: ["app", "--mcp", "/bin/ls"])?.path, canonicalLS)
        XCTAssertEqual(MCPLauncher.requestedBinary(from: ["app", "--mcp=/bin/ls"])?.path, canonicalLS)
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app"]))
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--mcp"])) // flag with no path
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--mcp", "/bin/ls", "extra"]))
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--mcp=/bin/ls", "extra"]))
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--mcp="]))
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--other", "x"]))
        // Position-aware: the flag is only honored in the mode slot (argv[1]). A later
        // token — even a literal "--mcp=…" — is a positional value, never a mode selector.
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--other", "--mcp", "/bin/ls"]))
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["app", "--run-script", "--mcp=/etc/passwd", "/bin/ls"]))
    }

    func testRequestedBinaryCanonicalizesSymlinkIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-launch-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let alias = directory.appendingPathComponent("alias")
        try Data("fixture".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertEqual(
            MCPLauncher.requestedBinary(from: ["app", "--mcp", alias.path])?.path,
            target.standardizedFileURL.path
        )
    }

    @MainActor
    func testMakeStoreThrowsOnNonBinary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-binary-\(UUID().uuidString).txt")
        try Data("hello, not a binary".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try MCPLauncher.makeStore(binaryURL: url))
    }

    @MainActor
    func testMakeStoreLoadsRealSystemBinaryAndServesMCP() throws {
        // End-to-end: the headless launcher loads a real Mach-O and the MCP server
        // answers over it — the full `--mcp` path minus the stdio loop.
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: lsURL.path) else { throw XCTSkip("no /bin/ls") }
        let store = try MCPLauncher.makeStore(binaryURL: lsURL)
        XCTAssertEqual(
            store.snapshot.binaries.first?.path,
            lsURL.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertFalse(store.snapshot.functions.isEmpty)
        XCTAssertFalse(store.snapshot.instructions.isEmpty)

        let server = MCPServer(api: WorkspaceScriptingAPI(store: store))
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"info"}}"#
        let response = server.handleLine(line)
        XCTAssertTrue(response?.contains("\"isError\"") ?? false)
        XCTAssertTrue(response?.contains("functionCount") ?? false)
    }

    @MainActor
    func testMakeStoreRejectsBinaryChangedDuringAnalysis() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-changing-binary-\(UUID().uuidString)")
        try Data("original bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try MCPLauncher.makeStore(
            binaryURL: url,
            engine: MutatingMCPAnalysisProvider()
        )) { error in
            XCTAssertTrue(error is MCPLauncherError)
        }
    }
}

private struct MutatingMCPAnalysisProvider: AnalysisProviding {
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        try Data("replacement bytes".utf8).write(to: url)
        return WorkspaceSnapshot(
            binaries: [], functions: [], symbols: [], instructions: [], xrefs: [], hexBytes: Data()
        )
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        fatalError("not used by the synchronous headless launcher")
    }
}

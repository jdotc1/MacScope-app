import Foundation
import XCTest
@testable import MacScope

/// HOP-6: `open-workspace` / `save-workspace` through the scripting API and the MCP server.
@MainActor
final class WorkspaceDocumentScriptingTests: XCTestCase {
    private static let code = Data([
        0x00, 0x00, 0x80, 0x52,         // mov w0, #0
        0x02, 0x00, 0x00, 0x14,         // b .+8
        0xc0, 0x03, 0x5f, 0xd6,         // ret
        0xff, 0x43, 0x00, 0xd1,         // sub sp, sp, #0x10
        0xc0, 0x03, 0x5f, 0xd6,         // ret
    ])

    private func makeScratch() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-hop6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private func analyzedStore() throws -> WorkspaceStore {
        let source = try TinyMachO.make(code: Self.code).write()
        let engine = AnalysisEngine()
        return WorkspaceStore(workspaceName: "hop6", snapshot: try engine.analyze(url: source),
                              engine: engine, autosaveScheduler: nil)
    }

    /// A different, unsaved workspace the package is opened into.
    private func otherStore() -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "other.bin", path: "/tmp/other.bin",
                                   kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_other", startAddress: 0x4000,
                                        endAddress: 0x4004, confidence: 1)],
            symbols: [], instructions: [], xrefs: [], hexBytes: Data()
        )
        return WorkspaceStore(workspaceName: "other", snapshot: snapshot, engine: AnalysisEngine(),
                              autosaveScheduler: nil)
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: ScriptValue]) -> (isError: Bool, text: String) {
        let response = server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": .object(arguments)]),
        ]))
        let result = response?["result"]
        return (result?["isError"]?.boolValue ?? true,
                result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
    }

    func testSaveThenOpenRoundTripKeepsProceduresAndAnnotations() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try analyzedStore()
        let api = WorkspaceScriptingAPI(store: source)
        let first = try XCTUnwrap(source.snapshot.functions.first)
        let address = ScriptValue.string("0x" + String(first.startAddress, radix: 16))
        _ = try api.execute("rename", arguments: .object(["address": address, "name": .string("hop6_entry")]))
        _ = try api.execute("set-comment", arguments: .object(["address": address, "comment": .string("saved by mcp")]))
        let path = scratch.appendingPathComponent("RoundTrip.mscope").path
        let saved = try api.execute("save-workspace", arguments: .object(["path": .string(path)]))
        XCTAssertEqual(saved["ok"], .bool(true))
        XCTAssertEqual(saved["analyzerVersion"], .int(Int64(WorkspaceAnalyzerStamp.currentVersion)))
        XCTAssertEqual(try MacScopeDocumentPackage.readManifest(from: URL(fileURLWithPath: path)).analyzer, .current)
        // A plain save (no path) goes back to the package it was saved to.
        XCTAssertEqual(try api.execute("save-workspace")["ok"], .bool(true))

        let target = otherStore()
        let targetAPI = WorkspaceScriptingAPI(store: target)
        let opened = try targetAPI.execute("open-workspace", arguments: .object(["path": .string(path)]))
        XCTAssertEqual(opened["ok"], .bool(true))
        XCTAssertEqual(opened["functionCount"], .int(Int64(source.snapshot.functions.count)))
        XCTAssertEqual(opened["repairs"], .array([]))
        XCTAssertEqual(target.snapshot.functions.map(\.startAddress), source.snapshot.functions.map(\.startAddress))
        XCTAssertEqual(try targetAPI.execute("name-at", arguments: .object(["address": address])), .string("hop6_entry"))
        let row = try targetAPI.execute("instructions", arguments: .object(["address": address, "count": .int(1)]))
        XCTAssertEqual(row.arrayValue?.first?["comment"], .string("saved by mcp"))
        XCTAssertEqual(target.documentURL?.lastPathComponent, "RoundTrip.mscope")
    }

    func testMCPToolsAdvertiseAndReportTypedErrors() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try analyzedStore()
        let server = MCPServer(api: WorkspaceScriptingAPI(store: source))
        let tools = server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list"),
        ]))?["result"]?["tools"]?.arrayValue ?? []
        let open = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "open-workspace" })
        XCTAssertEqual(open["inputSchema"]?["required"], .array([.string("path")]))
        XCTAssertEqual(open["annotations"]?["destructiveHint"], .bool(true))
        XCTAssertNotNil(tools.first { $0["name"]?.stringValue == "save-workspace" })

        // No saved location yet; a relative path; a missing folder.
        XCTAssertTrue(call(server, "save-workspace", [:]).text.contains("workspace-no-document-path"))
        XCTAssertTrue(call(server, "save-workspace", ["path": .string("relative.mscope")]).text.contains("workspace-invalid-path"))
        XCTAssertTrue(call(server, "save-workspace", ["path": .string(scratch.path + "/x.bin")]).text.contains("workspace-invalid-path"))
        let missingFolder = scratch.appendingPathComponent("absent/W.mscope").path
        XCTAssertTrue(call(server, "save-workspace", ["path": .string(missingFolder)]).text.contains("workspace-path-missing"))

        let path = scratch.appendingPathComponent("Typed.mscope").path
        let saved = call(server, "save-workspace", ["path": .string(path)])
        XCTAssertFalse(saved.isError, saved.text)

        let target = otherStore()
        let targetServer = MCPServer(api: WorkspaceScriptingAPI(store: target))
        let missing = call(targetServer, "open-workspace", ["path": .string(scratch.appendingPathComponent("Nope.mscope").path)])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("workspace-path-missing"), missing.text)

        // A workspace from a newer analyzer is refused and the open workspace is unchanged.
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: URL(fileURLWithPath: path))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let future = WorkspaceAnalyzerStamp.currentVersion + 1
        object["analyzer"] = ["version": future, "features": [["version": future, "name": "future pass"]]]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        let newer = call(targetServer, "open-workspace", ["path": .string(path)])
        XCTAssertTrue(newer.isError)
        XCTAssertTrue(newer.text.contains("workspace-newer-analyzer") && newer.text.contains("future pass"), newer.text)
        XCTAssertEqual(target.snapshot.functions.map(\.name), ["_other"])
        XCTAssertNil(target.documentURL)

        XCTAssertThrowsError(try WorkspaceScriptingAPI(store: target)
            .execute("open-workspace", arguments: .object(["path": .string(path)]))) { error in
            XCTAssertEqual(error as? WorkspaceDocumentScriptingError,
                           .newerAnalyzerVersion(future, missingFeatures: ["future pass"]))
        }
    }
}

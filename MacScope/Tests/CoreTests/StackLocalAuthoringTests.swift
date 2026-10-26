import Foundation
import XCTest
@testable import MacScope

/// DP04 C1: durable stack local rename/retype keyed by entry-SP range.
@MainActor
final class StackLocalAuthoringTests: XCTestCase {
    func testAuthoringRangeParserRejectsInvalidExtentsBeforeConstructingRange() {
        let rejected = [
            "\(Int64.min):\(Int64.max)", "\(Int64.min):0", "-1:\(Int64.max)",
            "0:0", "1:0", "0:4097", "-4097:0", "", "0:", ":1", "0:1:2",
        ]
        for key in rejected {
            XCTAssertNil(MacIRStackStorage.entryRange(forAuthoringKey: key), key)
        }
        let accepted: [Range<Int64>] = [
            0..<4_096, -4_096..<0,
            Int64.min..<(Int64.min + 4_096), (Int64.max - 4_096)..<Int64.max,
        ]
        for range in accepted {
            let key = MacIRStackStorage.authoringKey(for: range)
            XCTAssertEqual(MacIRStackStorage.entryRange(forAuthoringKey: key), range)
        }
    }

    // sub sp; str x0,[sp,#8] (-24:-16); str w1,[sp,#0x14] (-12:-8); reloads; ret
    private let program: [(String, String)] = [
        ("sub", "sp, sp, #0x20"), ("str", "x0, [sp, #0x8]"), ("str", "w1, [sp, #0x14]"),
        ("ldr", "x2, [sp, #0x8]"), ("ldr", "w3, [sp, #0x14]"), ("add", "sp, sp, #0x20"), ("ret", ""),
    ]

    private var rows: [InstructionRow] {
        program.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t.bin", path: "/tmp/t.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x101c, confidence: 1)],
            instructions: rows,
            xrefs: [],
            hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x200, fileOffset: 0x1000, isExecutable: true)]
        )
    }

    func testPrinterAppliesMatchingEditsAndIgnoresOrphansAndInvalidNames() {
        let plain = PseudocodePrinter().print(functionName: "f", startAddress: 0x1000, instructions: rows)
        let wide = plain.localVariables.first { $0.byteWidth == 8 }
        XCTAssertEqual(wide?.stackStorage?.authoringKey, "-24:-16", plain.text)
        let edited = PseudocodePrinter().print(
            functionName: "f", startAddress: 0x1000,
            stackLocalOverrides: [
                "-24:-16": StackLocalOverride(name: "count", typeName: "uint64_t"),
                "-12:-8": StackLocalOverride(name: "1bad", typeName: "int32_t"),
                "-100:-96": StackLocalOverride(name: "orphan"),
            ],
            instructions: rows
        )
        XCTAssertTrue(edited.text.contains("    uint64_t count;"), edited.text)
        XCTAssertFalse(edited.text.contains(wide?.name ?? "<none>"), "the default name is gone\n\(edited.text)")
        let narrow = edited.localVariables.first { $0.byteWidth == 4 }
        XCTAssertEqual(narrow?.type, "int32_t", "the valid type applies")
        XCTAssertNotEqual(narrow?.name, "1bad", "an invalid identifier is not applied")
        XCTAssertFalse(edited.text.contains("orphan"), "an orphan edit never retargets")
        XCTAssertEqual(edited.localVariables.first { $0.byteWidth == 8 }?.name, "count")
    }

    func testEditsSurviveSaveReopenAndOrphansAreKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("locals.sqlite")
        var snapshot = makeSnapshot()
        snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(stackLocals: [
            "-24:-16": StackLocalOverride(name: "count", typeName: "uint64_t"),
            "-100:-96": StackLocalOverride(name: "orphan"),
            "-12:-8": StackLocalOverride(name: "", typeName: ""),
            "bogus": StackLocalOverride(name: "x"),
        ])
        let workspaceID: Int64
        do {
            let database = try WorkspaceDatabase(path: url.path)
            try database.applySchema()
            workspaceID = try XCTUnwrap(try database.saveSnapshot(workspaceName: "locals", snapshot: snapshot).id)
        }
        let reloaded = try XCTUnwrap(try WorkspaceDatabase(path: url.path).loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.stackLocalOverrides(forProcedureAt: 0x1000, in: reloaded.primarySlot), [
            "-24:-16": StackLocalOverride(name: "count", typeName: "uint64_t"),
            "-100:-96": StackLocalOverride(name: "orphan"),
        ], "blank and malformed entries prune; the orphan stays")

        // Package DTO round trip carries the same map.
        let analysis = WorkspacePackageAnalysis(snapshot: reloaded)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: try JSONEncoder().encode(analysis))
        let reconstructed = decoded.snapshot(binaries: reloaded.binaries, hexBytes: reloaded.hexBytes)
        XCTAssertEqual(reconstructed.stackLocalOverrides(forProcedureAt: 0x1000, in: reconstructed.primarySlot).count, 2)
    }

    func testLegacyOverrideWithoutStackLocalsIsUnchanged() throws {
        let legacy = AddressOverride(customName: "f", registerNames: ["x19": "count"])
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("stackLocals"), "no new key without edits")
        XCTAssertEqual(try JSONDecoder().decode(AddressOverride.self, from: data), legacy)
        XCTAssertTrue(AddressOverride(stackLocals: ["-8:0": StackLocalOverride()]).isEmpty)
    }

    func testStoreEditIsUndoableAndScriptingReportsOrphans() throws {
        let store = WorkspaceStore(workspaceName: "locals", snapshot: makeSnapshot(), engine: AnalysisEngine(), autosaveScheduler: nil)
        store.editStackLocal(procedureStart: 0x1000, in: store.snapshot.primarySlot, entryRange: -24 ..< -16,
                             name: "count", typeName: nil)
        XCTAssertEqual(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: store.snapshot.primarySlot)["-24:-16"],
                       StackLocalOverride(name: "count"))
        store.undoManager.undo()
        XCTAssertTrue(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: store.snapshot.primarySlot).isEmpty)
        store.undoManager.redo()

        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("set-stack-local", arguments: .object([
            "function": .string("_main"), "local": .string("-24:-16"), "type": .string("uint64_t"),
        ]))
        _ = try api.execute("set-stack-local", arguments: .object([
            "address": .hex(0x1000), "local": .string("-100:-96"), "name": .string("gone"),
        ]))
        let listed = try api.execute("stack-locals", arguments: .object(["function": .string("_main")]))
        XCTAssertEqual(listed["edits"]?["-24:-16"]?["name"]?.stringValue, "count", "omitted name is kept")
        XCTAssertEqual(listed["edits"]?["-24:-16"]?["type"]?.stringValue, "uint64_t")
        XCTAssertEqual(listed["edits"]?["-24:-16"]?["orphan"], .bool(false))
        XCTAssertEqual(listed["edits"]?["-100:-96"]?["orphan"], .bool(true))
        XCTAssertNotNil(listed["recovered"]?["-12:-8"])
        XCTAssertThrowsError(try api.execute("set-stack-local", arguments: .object([
            "function": .string("_main"), "local": .string("-24:-16"), "name": .string("not valid"),
        ])))
    }

    // MARK: - DP04 C2: MCP

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "locals", snapshot: makeSnapshot(), engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testMCPCatalogExposesStackLocalToolsWithValidatedArguments() throws {
        let names = Set(HeadlessAutomationAuthority.availableCommands.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["set-stack-local", "stack-locals"]))
        let info = try XCTUnwrap(HeadlessAutomationAuthority.availableCommands.first { $0.name == "set-stack-local" })
        XCTAssertEqual(HeadlessAutomationAuthority.inputSchema(for: info)["required"], .array([.string("local")]))
        XCTAssertNoThrow(try HeadlessAutomationAuthority.validate(command: "set-stack-local", arguments: .object([
            "address": .hex(0x1000), "local": .string("-24:-16"), "name": .string("count"),
        ])))
        for bad: ScriptValue in [
            .object(["address": .hex(0x1000), "local": .string("-16:-24"), "name": .string("count")]),
            .object(["address": .hex(0x1000), "local": .string("-24:-16")]),
            .object(["address": .hex(0x1000), "local": .string("-24:-16"), "name": .int(1)]),
            .object(["address": .hex(0x1000), "local": .string("-24:-16"), "name": .string("a"), "extra": .bool(true)]),
        ] {
            XCTAssertThrowsError(try HeadlessAutomationAuthority.validate(command: "set-stack-local", arguments: bad), "\(bad)")
        }
        XCTAssertTrue(MCPAttachExecutor.attachCommands.isSuperset(of: ["set-stack-local", "stack-locals"]))
    }

    func testAttachedEditNeedsTheGrantAndUndoesThroughTheStore() async throws {
        let store = makeStore()
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        let edit: ScriptValue = .object(["function": .string("_main"), "local": .string("-24:-16"), "name": .string("count")])
        do { _ = try await executor.execute("set-stack-local", edit); XCTFail("ran before consent") }
        catch { XCTAssertEqual(error as? MCPAttachExecutor.Failure, .consentPending) }
        executor.setConsent(.allowed)
        var granted = true
        executor.authorize = { granted }
        _ = try await executor.execute("set-stack-local", edit)
        let slot = store.snapshot.primarySlot
        XCTAssertEqual(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot)["-24:-16"]?.name, "count")
        let listed = try await executor.execute("stack-locals", .object(["function": .string("_main")]))
        XCTAssertEqual(listed["edits"]?["-24:-16"]?["orphan"], .bool(false))
        store.undoManager.undo()
        XCTAssertTrue(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot).isEmpty, "undo removes the agent edit")

        granted = false // window closed / document replaced / disconnected
        do { _ = try await executor.execute("set-stack-local", edit); XCTFail("committed after revocation") }
        catch { XCTAssertEqual(error as? MCPAttachExecutor.Failure, .notAuthorized) }
        XCTAssertTrue(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot).isEmpty)
    }

    func testStackLocalsListsRegisterRenamesWithOrphans() throws {
        let store = makeStore()
        store.renameRegister(procedureStart: 0x1000, in: store.snapshot.primarySlot, register: "x2", name: "loaded")
        store.renameRegister(procedureStart: 0x1000, in: store.snapshot.primarySlot, register: "x19", name: "unused")
        let listed = try WorkspaceScriptingAPI(store: store).execute("stack-locals", arguments: .object(["function": .string("_main")]))
        XCTAssertEqual(listed["registers"]?["x2"]?["orphan"], .bool(false))
        XCTAssertEqual(listed["registers"]?["x19"]?["orphan"], .bool(true), "x19 never appears in the function")
        XCTAssertEqual(listed["registers"]?["x19"]?["name"]?.stringValue, "unused")
    }
}

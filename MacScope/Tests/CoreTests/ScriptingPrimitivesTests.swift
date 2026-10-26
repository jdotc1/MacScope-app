import Foundation
import XCTest
@testable import MacScope

/// Residual scripting primitives (PARITY_CONTRACT §6):
///   1. REGISTER RENAME in pseudocode — an override keyed by (procedure start, register id)
///      that renames a register's displayed name in the decompiled body.
///   2. SAVE-PATCHED-BINARY — a scripting wrapper over `MachOPatchWriter`.
///   3. PER-PROCEDURE LOCAL LABELS — a procedure-scoped name override.
///
/// These pin the required behaviors independently of the implementation (correctness over
/// coverage): a rename actually changes `PseudocodePrinter` output (not just the stored map);
/// it survives save/reopen + undo; the patched-binary command round-trips a known patch; and
/// the local label persists.
@MainActor
final class ScriptingPrimitivesTests: XCTestCase {

    // MARK: - Fixtures

    /// A snapshot whose single function reads + increments a callee-saved register (x19), so a
    /// register rename has a real occurrence to change in the pseudocode. The exact decode is
    /// not what's asserted — only that the renamed token replaces the raw register id.
    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t.bin", path: "/tmp/t.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1010, confidence: 1)],
            instructions: [
                // add x19, x19, #1   (0x91000673) — uses x19 as both source and dest
                InstructionRow(address: 0x1000, bytes: "73 06 00 91", mnemonic: "add", operands: "x19, x19, #1", hasBreakpoint: false, comment: nil),
                // mov x0, x19        (0xaa1303e0)
                InstructionRow(address: 0x1004, bytes: "e0 03 13 aa", mnemonic: "mov", operands: "x0, x19", hasBreakpoint: false, comment: nil),
                // ret
                InstructionRow(address: 0x1008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x200, fileOffset: 0x1000, isExecutable: true)]
        )
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "primitives", snapshot: makeSnapshot(), engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func decompiledText(_ store: WorkspaceStore) throws -> String {
        let result = try WorkspaceScriptingAPI(store: store)
            .execute("decompile", arguments: .object(["address": .hex(0x1000)]))
        return try XCTUnwrap(result["pseudocode"]?.stringValue)
    }

    // MARK: - 1. Register rename changes PseudocodePrinter output

    func testRegisterRenameChangesDecompiledOutput() throws {
        let store = makeStore()

        // Baseline: the raw register id appears, the friendly name does not.
        let before = try decompiledText(store)
        XCTAssertTrue(before.contains("x19"), "sanity: the fixture's body references x19\n\(before)")
        XCTAssertFalse(before.contains("counter"))

        store.renameRegister(procedureStart: 0x1000, register: "x19", name: "counter")

        let after = try decompiledText(store)
        XCTAssertTrue(after.contains("counter"), "the renamed name appears in the body\n\(after)")
        // No bare `x19` SSA token survives (the rename is version-agnostic).
        XCTAssertFalse(after.contains("x19_"), "no raw SSA register token remains\n\(after)")
    }

    /// The rename is version-agnostic: a w-form reference (the 32-bit view of the same physical
    /// register) is renamed too. Built directly on the printer so the assertion is about the
    /// substitution rule, not a particular decode.
    func testRegisterRenameAppliesAcrossSsaVersionsAndWidthAlias() {
        let rows = [
            InstructionRow(address: 0x2000, bytes: "73 06 00 91", mnemonic: "add", operands: "x19, x19, #1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2004, bytes: "73 06 00 91", mnemonic: "add", operands: "w19, w19, #1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let doc = PseudocodePrinter().print(
            functionName: "f",
            startAddress: 0x2000,
            registerNameOverrides: ["x19": "total"],
            instructions: rows
        )
        XCTAssertTrue(doc.text.contains("total"), doc.text)
        XCTAssertFalse(doc.text.contains("x19_"), doc.text)
        XCTAssertFalse(doc.text.contains("w19_"), "the w-form alias resolves to the same rename\n\(doc.text)")
    }

    func testRegisterRenameSurvivesSaveAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("regnames.sqlite")

        var snapshot = makeSnapshot()
        snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(registerNames: ["x19": "counter", "x20": "limit"])

        let workspaceID: Int64
        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            let workspace = try database.saveSnapshot(workspaceName: "round", snapshot: snapshot)
            workspaceID = try XCTUnwrap(workspace.id)
        }

        // Reopen the file fresh (proves the rows persisted, not an in-memory cache).
        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        let reloaded = try XCTUnwrap(reopened.loadSnapshot(workspaceID: workspaceID))
        let names = reloaded.registerNameOverrides(forProcedureAt: 0x1000)
        XCTAssertEqual(names["x19"], "counter")
        XCTAssertEqual(names["x20"], "limit")
    }

    func testRegisterRenameRoundTripsThroughPackageAnalysis() throws {
        var snapshot = makeSnapshot()
        snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(registerNames: ["x19": "counter", "x21": ""]) // blank pruned

        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        let names = reconstructed.registerNameOverrides(forProcedureAt: 0x1000)
        XCTAssertEqual(names, ["x19": "counter"], "the blank rename was pruned, the real one survived")
    }

    func testRegisterRenameIsUndoable() throws {
        let store = makeStore()
        store.renameRegister(procedureStart: 0x1000, register: "x19", name: "counter")
        XCTAssertEqual(store.snapshot.registerNameOverrides(forProcedureAt: 0x1000)["x19"], "counter")

        store.undoManager.undo()
        XCTAssertTrue(store.snapshot.registerNameOverrides(forProcedureAt: 0x1000).isEmpty, "undo removed the rename")

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.registerNameOverrides(forProcedureAt: 0x1000)["x19"], "counter", "redo re-applied it")
    }

    func testScriptingRenameClearAndList() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        _ = try api.execute("rename-register", arguments: .object(["address": .hex(0x1004), "register": .string("x19"), "name": .string("counter")]))
        // Resolving by an interior address still keys the procedure start (0x1000).
        var listed = try api.execute("register-names", arguments: .object(["function": .string("_main")]))
        XCTAssertEqual(listed["renames"]?["x19"]?.stringValue, "counter")

        // The rename shows in the decompiled body via scripting.
        XCTAssertTrue(try decompiledText(store).contains("counter"))

        // Clearing restores the raw register and prunes the override entry.
        _ = try api.execute("clear-register-name", arguments: .object(["function": .string("_main"), "register": .string("x19")]))
        listed = try api.execute("register-names", arguments: .object(["function": .string("_main")]))
        XCTAssertNil(listed["renames"]?["x19"], "the rename was cleared")
        XCTAssertTrue(store.snapshot.registerNameOverrides(forProcedureAt: 0x1000).isEmpty)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)], "the now-empty override was pruned")
    }

    func testRegisterRenameDoesNotLeakAcrossProcedures() {
        // Two procedures; a rename at one start must not change the other's rendering.
        let a = WorkspaceSnapshot(
            binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
        )
        var snapshot = a
        snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(registerNames: ["x19": "alpha"])
        XCTAssertEqual(snapshot.registerNameOverrides(forProcedureAt: 0x1000), ["x19": "alpha"])
        XCTAssertTrue(snapshot.registerNameOverrides(forProcedureAt: 0x2000).isEmpty)
    }

    // MARK: - 2. Save patched binary (scripting over MachOPatchWriter)

    func testSavePatchedBinaryRoundTripsAKnownPatchToDisk() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Write a real thin Mach-O to disk and point the snapshot's binary at it.
        let fixture = MachOFixture.makeExecutable()
        let sourceURL = directory.appendingPathComponent("source.bin")
        try fixture.bytes.write(to: sourceURL)

        var snapshot = makeSnapshot()
        let loaded = try MachOBinaryLoader().load(bytes: fixture.bytes, sourceURL: sourceURL)
        snapshot.binaries = [BinaryImage(id: UUID(), name: "source.bin", path: sourceURL.path,
            kind: "Mach-O executable", architecture: "arm64",
            machOSelectedSliceFact: try XCTUnwrap(loaded.machOSelectedSliceFact))]
        snapshot.imageBytes = fixture.bytes // MS-15: export derives from the captured bytes
        // A patch at the entry instruction: the canonical ARM64 NOP.
        let patchBytes: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]
        snapshot.addressOverrides[.primary(fixture.baseAddress)] = AddressOverride(patch: BytePatch(bytes: patchBytes))

        let store = WorkspaceStore(workspaceName: "patch", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)

        let outURL = directory.appendingPathComponent("out.bin")
        let result = try api.execute("save-patched-binary", arguments: .object(["path": .string(outURL.path)]))
        XCTAssertEqual(result["ok"]?.boolValue, true)
        XCTAssertEqual(result["patchCount"]?.intValue, 1)
        XCTAssertEqual(result["unsigned"]?.boolValue, true)

        // Independently verify the written file: the patch landed at the right FILE OFFSET and
        // every other byte is identical to the original (the writer's contract).
        let written = try Data(contentsOf: outURL)
        XCTAssertEqual(written.count, fixture.bytes.count)
        let start = fixture.codeOffset
        XCTAssertEqual(Array(written[start..<(start + patchBytes.count)]), patchBytes)
        let original = Array(fixture.bytes)
        let writtenArray = Array(written)
        for index in 0..<original.count where !(start..<(start + patchBytes.count)).contains(index) {
            XCTAssertEqual(writtenArray[index], original[index], "byte at \(index) changed unexpectedly")
        }
    }

    func testSavePatchedBinaryCanReturnBytesWithoutAPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MachOFixture.makeExecutable()
        let sourceURL = directory.appendingPathComponent("source.bin")
        try fixture.bytes.write(to: sourceURL)

        var snapshot = makeSnapshot()
        let loaded = try MachOBinaryLoader().load(bytes: fixture.bytes, sourceURL: sourceURL)
        snapshot.binaries = [BinaryImage(id: UUID(), name: "source.bin", path: sourceURL.path,
            kind: "Mach-O executable", architecture: "arm64",
            machOSelectedSliceFact: try XCTUnwrap(loaded.machOSelectedSliceFact))]
        snapshot.imageBytes = fixture.bytes // MS-15: export derives from the captured bytes
        snapshot.addressOverrides[.primary(fixture.baseAddress)] = AddressOverride(patch: BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5]))

        let store = WorkspaceStore(workspaceName: "patch", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let result = try WorkspaceScriptingAPI(store: store).execute("save-patched-binary")
        let base64 = try XCTUnwrap(result["bytesBase64"]?.stringValue)
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        // The returned bytes equal the writer's direct output.
        let expected = try MachOPatchWriter().makePatchedData(
            originalData: fixture.bytes,
            patches: [fixture.baseAddress: BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])]
        )
        XCTAssertEqual(decoded, expected)
    }

    func testSavePatchedBinarySurfacesWriterErrors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A non-Mach-O source: the writer's typed `.notMachO` must surface as a scripting error.
        let sourceURL = directory.appendingPathComponent("garbage.bin")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]).write(to: sourceURL)

        var snapshot = makeSnapshot()
        snapshot.binaries = [BinaryImage(id: UUID(), name: "garbage.bin", path: sourceURL.path, kind: "data", architecture: "arm64")]
        snapshot.imageBytes = try Data(contentsOf: sourceURL)
        snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(patch: BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5]))

        let store = WorkspaceStore(workspaceName: "patch", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertThrowsError(try WorkspaceScriptingAPI(store: store).execute("save-patched-binary", arguments: .object(["path": .string(directory.appendingPathComponent("out.bin").path)])))
    }

    // MARK: - 3. Per-procedure local labels

    func testLocalLabelRendersAndPersists() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        _ = try api.execute("set-local-label", arguments: .object(["address": .hex(0x1004), "label": .string("loc_retry")]))
        XCTAssertEqual(store.snapshot.localLabel(at: 0x1004), "loc_retry")

        let listed = try api.execute("local-labels").arrayValue ?? []
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["label"]?.stringValue, "loc_retry")
        XCTAssertEqual(listed.first?["address"]?.stringValue, "0x1004")

        // Clear prunes the override.
        _ = try api.execute("clear-local-label", arguments: .object(["address": .hex(0x1004)]))
        XCTAssertNil(store.snapshot.localLabel(at: 0x1004))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1004)])
    }

    /// Round 4 lane X (b): Set Local Label saved (the sheet prefilled on reopen) but the
    /// listing's label projection and the inspector's Symbol landmark never read local labels.
    func testLocalLabelWriteIsVisibleInListingAndInspectorProjection() throws {
        let store = makeStore()
        store.setLocalLabel(0x1004, label: "loc_retry")

        let rows = DisassemblyListingBuilder.build(snapshot: store.snapshot)
        XCTAssertTrue(
            rows.contains(.label(LabelRow(address: 0x1004, name: "loc_retry", isFunctionStart: false))),
            "the local label renders as a listing label row"
        )
        XCTAssertEqual(DisassemblyListingBuilder.labelNameLookup(snapshot: store.snapshot)[0x1000], "_main",
                       "the function start keeps its global name")

        XCTAssertEqual(AddressDetailReading(address: 0x1004, snapshot: store.snapshot).symbolWithOffset, "loc_retry")
        XCTAssertEqual(AddressDetailReading(address: 0x1008, snapshot: store.snapshot).symbolWithOffset, "loc_retry+0x4")

        // A local label at a function start never displaces the procedure's own label row.
        store.setLocalLabel(0x1000, label: "entry_local")
        XCTAssertEqual(DisassemblyListingBuilder.labelNameLookup(snapshot: store.snapshot)[0x1000], "_main")

        store.setLocalLabel(0x1004, label: nil)
        XCTAssertNil(DisassemblyListingBuilder.labelNameLookup(snapshot: store.snapshot)[0x1004])
    }

    func testLocalLabelIsUndoableAndSurvivesSaveReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("labels.sqlite")

        // Undo path.
        let store = makeStore()
        store.setLocalLabel(0x1004, label: "loc_retry")
        store.undoManager.undo()
        XCTAssertNil(store.snapshot.localLabel(at: 0x1004))
        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.localLabel(at: 0x1004), "loc_retry")

        // Persistence path.
        var snapshot = makeSnapshot()
        snapshot.addressOverrides[.primary(0x1004)] = AddressOverride(localLabel: "loc_retry")
        let workspaceID: Int64
        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            workspaceID = try XCTUnwrap(try database.saveSnapshot(workspaceName: "round", snapshot: snapshot).id)
        }
        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        let reloaded = try XCTUnwrap(reopened.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.localLabel(at: 0x1004), "loc_retry")
    }

    // MARK: - 4. Tag CRUD already present (audit) — scriptable add/remove/list

    func testTagAndColorCrudExistsOnScriptingSurface() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        // Add a free-text tag, then a color tag, then list (the address surfaces through reads).
        _ = try api.execute("set-tag", arguments: .object(["address": .hex(0x1000), "tag": .string("parser")]))
        _ = try api.execute("set-color", arguments: .object(["address": .hex(0x1000), "color": .string("red")]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.tag, "parser")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.colorTag, .red)

        // Remove (empty clears) — the CRUD surface is complete.
        _ = try api.execute("set-tag", arguments: .object(["address": .hex(0x1000), "tag": .string("")]))
        _ = try api.execute("set-color", arguments: .object(["address": .hex(0x1000), "color": .string("")]))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)]?.tag)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)]?.colorTag)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

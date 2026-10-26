import Foundation
import XCTest
@testable import MacScope

/// Track W2-B — segment-override lifecycle. A `SegmentOverride` is a DISPLAY-layer edit
/// (rename + rebase) on a section, workspace-global and keyed by the section's ORIGINAL
/// name. These tests pin the four required behaviors: rename persists + round-trips through
/// save/reopen; rebase shifts displayed addresses without mutating analysis; undo restores;
/// and the override survives a re-analysis (it must not be a derived field that the re-flow
/// drops).
@MainActor
final class SegmentOverrideTests: XCTestCase {

    // MARK: - Fixtures

    /// A snapshot with two sections so rebase/rename can be checked per-section and the
    /// no-override sections prove pass-through.
    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t.bin", path: "/tmp/t.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1008, confidence: 1)],
            instructions: [
                InstructionRow(address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data(),
            sections: [
                SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x200, fileOffset: 0x1000, isExecutable: true),
                SectionSummary(id: UUID(), name: "__DATA,__data", address: 0x4000, size: 0x100, fileOffset: 0x4000, isExecutable: false),
            ]
        )
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "segment", snapshot: makeSnapshot(), engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    // MARK: - Model: rebase math + display projection

    func testRebasedAddressIsTwosComplementWraparoundSafe() {
        let up = SegmentOverride(originalName: "x", rebaseDelta: 0x1000)
        XCTAssertEqual(up.rebased(0x4000), 0x5000)

        // A negative delta near 0 must not trap.
        let down = SegmentOverride(originalName: "x", rebaseDelta: -0x1000)
        XCTAssertEqual(down.rebased(0x4000), 0x3000)
        XCTAssertEqual(down.rebased(0x0500), UInt64(bitPattern: Int64(0x0500 - 0x1000)))

        // A zero delta is a no-op.
        XCTAssertEqual(SegmentOverride(originalName: "x", rebaseDelta: 0).rebased(0x4000), 0x4000)
    }

    func testResolvedNameFallsBackToOriginal() {
        XCTAssertEqual(SegmentOverride(originalName: "orig").resolvedName(default: "orig"), "orig")
        XCTAssertEqual(SegmentOverride(originalName: "orig", displayName: "").resolvedName(default: "orig"), "orig")
        XCTAssertEqual(SegmentOverride(originalName: "orig", displayName: "Code").resolvedName(default: "orig"), "Code")
    }

    func testIsEmptyPrunesNoSignalOverrides() {
        XCTAssertTrue(SegmentOverride(originalName: "x").isEmpty)
        XCTAssertTrue(SegmentOverride(originalName: "x", displayName: "").isEmpty)
        XCTAssertFalse(SegmentOverride(originalName: "x", displayName: "Code").isEmpty)
        XCTAssertFalse(SegmentOverride(originalName: "x", rebaseDelta: 1).isEmpty)
    }

    func testEffectiveSectionsAppliesRenameAndRebaseWithoutTouchingAnalysis() {
        var snapshot = makeSnapshot()
        snapshot.segmentOverrides = [
            SegmentOverride(originalName: "__TEXT,__text", displayName: "Code", rebaseDelta: 0x1000)
        ]

        let effective = snapshot.effectiveSections()
        let text = try? XCTUnwrap(effective.first { $0.name == "Code" })
        XCTAssertEqual(text?.address, 0x2000, "rebase shifted the displayed base 0x1000 -> 0x2000")
        // The non-overridden section passes through unchanged.
        XCTAssertNotNil(effective.first { $0.name == "__DATA,__data" && $0.address == 0x4000 })

        // The UNDERLYING analysis is untouched: original sections + instruction addresses.
        XCTAssertEqual(snapshot.sections.first?.name, "__TEXT,__text")
        XCTAssertEqual(snapshot.sections.first?.address, 0x1000)
        XCTAssertEqual(snapshot.instructions.map(\.address), [0x1000, 0x1004])
    }

    func testDisplayAddressShiftsOnlyWithinRebasedSection() {
        var snapshot = makeSnapshot()
        snapshot.segmentOverrides = [SegmentOverride(originalName: "__TEXT,__text", rebaseDelta: 0x1000)]

        // An address inside __text shifts; one inside the (un-rebased) __data does not.
        XCTAssertEqual(snapshot.displayAddress(for: 0x1004), 0x2004)
        XCTAssertEqual(snapshot.displayAddress(for: 0x4010), 0x4010)
        // An address in no section passes through.
        XCTAssertEqual(snapshot.displayAddress(for: 0x9000), 0x9000)
    }

    func testNoOverridesIsByteIdenticalToSections() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.effectiveSections(), snapshot.sections)
        XCTAssertEqual(snapshot.displayAddress(for: 0x1004), 0x1004)
    }

    // MARK: - Store: mutate + undo

    func testRenameAndRebaseAreAppliedThroughStore() {
        let store = makeStore()
        store.renameSegment(sectionName: "__TEXT,__text", displayName: "Code")
        store.rebaseSegment(sectionName: "__TEXT,__text", delta: 0x1000)

        let override = try? XCTUnwrap(store.snapshot.segmentOverride(for: "__TEXT,__text"))
        XCTAssertEqual(override?.displayName, "Code")
        XCTAssertEqual(override?.rebaseDelta, 0x1000)
        XCTAssertEqual(store.snapshot.displaySectionName(for: "__TEXT,__text"), "Code")
    }

    func testRenameUnknownSectionIsANoOpWithIssue() {
        let store = makeStore()
        store.renameSegment(sectionName: "__NOPE", displayName: "x")
        XCTAssertTrue(store.snapshot.segmentOverrides.isEmpty)
        XCTAssertNotNil(store.lastIssue)
    }

    func testClearingRenameAndRebasePrunesTheOverride() {
        let store = makeStore()
        store.renameSegment(sectionName: "__TEXT,__text", displayName: "Code")
        store.rebaseSegment(sectionName: "__TEXT,__text", delta: 0x1000)
        XCTAssertNotNil(store.snapshot.segmentOverride(for: "__TEXT,__text"))

        // Clearing both fields prunes the (now-empty) override entirely.
        store.renameSegment(sectionName: "__TEXT,__text", displayName: "")
        store.rebaseSegment(sectionName: "__TEXT,__text", delta: 0)
        XCTAssertTrue(store.snapshot.segmentOverrides.isEmpty)
    }

    func testUndoRestoresPriorSegmentOverrideState() {
        let store = makeStore()
        store.renameSegment(sectionName: "__TEXT,__text", displayName: "Code")
        XCTAssertEqual(store.snapshot.segmentOverride(for: "__TEXT,__text")?.displayName, "Code")

        store.undoManager.undo()
        XCTAssertNil(store.snapshot.segmentOverride(for: "__TEXT,__text"), "undo removed the rename")

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.segmentOverride(for: "__TEXT,__text")?.displayName, "Code", "redo re-applied it")
    }

    func testClearSegmentOverrideIsUndoable() {
        let store = makeStore()
        store.rebaseSegment(sectionName: "__TEXT,__text", delta: 0x40)
        store.clearSegmentOverride(sectionName: "__TEXT,__text")
        XCTAssertTrue(store.snapshot.segmentOverrides.isEmpty)

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.segmentOverride(for: "__TEXT,__text")?.rebaseDelta, 0x40)
    }

    // MARK: - Persistence: SQLite save / reopen round-trip

    func testSegmentOverridesRoundTripThroughDatabaseSaveAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("segment.sqlite")

        var snapshot = makeSnapshot()
        snapshot.segmentOverrides = [
            SegmentOverride(originalName: "__TEXT,__text", displayName: "Code", rebaseDelta: 0x1000),
            SegmentOverride(originalName: "__DATA,__data", displayName: nil, rebaseDelta: -0x400),
        ]

        let workspaceID: Int64
        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            let workspace = try database.saveSnapshot(workspaceName: "round", snapshot: snapshot)
            workspaceID = try XCTUnwrap(workspace.id)
        }

        // Reopen the file fresh (proves the rows persisted, not just an in-memory cache).
        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        let reloaded = try XCTUnwrap(reopened.loadSnapshot(workspaceID: workspaceID))
        let overrides = reloaded.segmentOverrides.sorted { $0.originalName < $1.originalName }

        XCTAssertEqual(overrides.count, 2)
        XCTAssertEqual(reloaded.segmentOverride(for: "__TEXT,__text")?.displayName, "Code")
        XCTAssertEqual(reloaded.segmentOverride(for: "__TEXT,__text")?.rebaseDelta, 0x1000)
        // A nil display name + a NEGATIVE rebase delta both survive.
        XCTAssertNil(reloaded.segmentOverride(for: "__DATA,__data")?.displayName)
        XCTAssertEqual(reloaded.segmentOverride(for: "__DATA,__data")?.rebaseDelta, -0x400)
    }

    func testInPlaceReSaveDoesNotCollideOnUniqueIndex() throws {
        // The v23 UNIQUE(workspace_id, original_name) index aborts a plain re-INSERT unless
        // deleteSnapshotContents clears segment_overrides first. Re-saving the same workspace
        // twice must succeed (the same footgun class as overrides/bookmarks).
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        var snapshot = makeSnapshot()
        snapshot.segmentOverrides = [SegmentOverride(originalName: "__TEXT,__text", displayName: "Code")]

        let workspace = try database.saveSnapshot(workspaceName: "ws", snapshot: snapshot)
        let workspaceID = try XCTUnwrap(workspace.id)
        // In-place re-save into the SAME workspace id (delete + re-insert). Without the
        // segment_overrides DELETE in deleteSnapshotContents this aborts on the UNIQUE index.
        XCTAssertNoThrow(try database.replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: "ws",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: false,
            sidebarSearchText: ""
        ))

        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.segmentOverrides.count, 1)
    }

    // MARK: - Persistence: .mscope Codable payload round-trip

    func testSegmentOverridesRoundTripThroughPackageAnalysis() throws {
        var snapshot = makeSnapshot()
        snapshot.segmentOverrides = [
            SegmentOverride(originalName: "__TEXT,__text", displayName: "Code", rebaseDelta: 0x1000),
            SegmentOverride(originalName: "__empty"), // pruned: no signal
        ]

        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        // Empty overrides are pruned and the list is name-sorted for deterministic JSON.
        XCTAssertEqual(analysis.segmentOverrides.map(\.originalName), ["__TEXT,__text"])

        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        XCTAssertEqual(reconstructed.segmentOverride(for: "__TEXT,__text")?.displayName, "Code")
        XCTAssertEqual(reconstructed.segmentOverride(for: "__TEXT,__text")?.rebaseDelta, 0x1000)
    }

    func testOldPackageWithoutSegmentOverridesKeyDecodesEmpty() throws {
        let json = "{\"functions\":[],\"instructions\":[],\"xrefs\":[]}"
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.segmentOverrides.isEmpty)
    }

    // MARK: - Re-analysis preservation

    /// A segment override must survive a re-analysis (mark-as-procedure re-flow). It keys on
    /// the section's original name, which the fresh analysis reproduces, so it re-binds.
    func testSegmentOverrideSurvivesReanalysis() async throws {
        let fixture = TinyMachO.make(code: Self.branchIntoPrologue)
        let url = try fixture.write()
        let engine = AnalysisEngine()
        let snapshot = try engine.analyze(url: url)
        let store = WorkspaceStore(workspaceName: "reanalysis", snapshot: snapshot, engine: engine, autosaveScheduler: nil)

        // Pick a real section name the analysis produced (the executable text section).
        let sectionName = try XCTUnwrap(store.snapshot.sections.first(where: \.isExecutable)?.name)
        store.renameSegment(sectionName: sectionName, displayName: "Code")
        store.rebaseSegment(sectionName: sectionName, delta: 0x1000)

        // Trigger a re-analysis via a structural override (mark-as-procedure at the prologue).
        store.setMarkAsProcedure(fixture.baseAddress + 0x0c, true)
        await store.awaitPendingReanalysis()

        // The structural edit re-flowed the functions; the segment override is preserved.
        XCTAssertEqual(store.snapshot.functions.count, 2, "sanity: the re-flow actually ran")
        let preserved = try XCTUnwrap(store.snapshot.segmentOverride(for: sectionName))
        XCTAssertEqual(preserved.displayName, "Code")
        XCTAssertEqual(preserved.rebaseDelta, 0x1000)
        XCTAssertEqual(store.snapshot.displaySectionName(for: sectionName), "Code")
    }

    // MARK: - Scripting API

    func testScriptingRenameRebaseClearAndList() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())

        _ = try api.execute("rename-segment", arguments: .object(["section": .string("__TEXT,__text"), "name": .string("Code")]))
        _ = try api.execute("rebase-segment", arguments: .object(["section": .string("__TEXT,__text"), "delta": .string("0x1000")]))

        let listed = try api.execute("segment-overrides").arrayValue ?? []
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["section"]?.stringValue, "__TEXT,__text")
        XCTAssertEqual(listed.first?["displayName"]?.stringValue, "Code")
        XCTAssertEqual(listed.first?["rebaseDelta"]?.intValue, 0x1000)

        // The `sections` command reflects the override but keeps the original name.
        let sections = try api.execute("sections").arrayValue ?? []
        let text = try XCTUnwrap(sections.first { $0["originalName"]?.stringValue == "__TEXT,__text" })
        XCTAssertEqual(text["name"]?.stringValue, "Code")
        XCTAssertEqual(text["address"]?.stringValue, "0x2000", "rebased displayed base")

        // A negative delta via the scripting hex form.
        _ = try api.execute("rebase-segment", arguments: .object(["section": .string("__TEXT,__text"), "delta": .string("-0x400")]))
        XCTAssertEqual(try api.execute("segment-overrides").arrayValue?.first?["rebaseDelta"]?.intValue, -0x400)

        // Clearing removes the override.
        _ = try api.execute("clear-segment-override", arguments: .object(["section": .string("__TEXT,__text")]))
        XCTAssertEqual(try api.execute("segment-overrides").arrayValue?.count, 0)
    }

    func testScriptingRebaseAcceptsIntegerAndRejectsGarbage() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        // A bare JSON integer delta (negative) is accepted.
        _ = try api.execute("rebase-segment", arguments: .object(["section": .string("__DATA,__data"), "delta": .int(-16)]))
        XCTAssertEqual(try api.execute("segment-overrides").arrayValue?.first?["rebaseDelta"]?.intValue, -16)

        // A non-numeric delta is rejected.
        XCTAssertThrowsError(try api.execute("rebase-segment", arguments: .object(["section": .string("__DATA,__data"), "delta": .string("xyz")])))
    }

    // MARK: - Helpers

    /// mov ; b .+8 ; ret ; prologue ; ret — one function until Mark-as-Procedure splits it.
    private static let branchIntoPrologue = Data([
        0x00, 0x00, 0x80, 0x52,
        0x02, 0x00, 0x00, 0x14,
        0xc0, 0x03, 0x5f, 0xd6,
        0xff, 0x43, 0x00, 0xd1,
        0xc0, 0x03, 0x5f, 0xd6
    ])

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

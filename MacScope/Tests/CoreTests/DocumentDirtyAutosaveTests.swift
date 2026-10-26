import Foundation
import XCTest
@testable import MacScope

final class DocumentDirtyAutosaveTests: XCTestCase {

    // MARK: - Pure DocumentDirtyTracker

    func testFreshTrackerIsCleanUntilMutated() {
        var tracker = DocumentDirtyTracker()
        XCTAssertFalse(tracker.isDirty)
        tracker.recordMutation()
        XCTAssertTrue(tracker.isDirty)
    }

    func testSaveClearsDirty() {
        var tracker = DocumentDirtyTracker()
        tracker.recordMutation()
        XCTAssertTrue(tracker.isDirty)
        tracker.markSaved()
        XCTAssertFalse(tracker.isDirty)
        // A further edit re-dirties against the new baseline.
        tracker.recordMutation()
        XCTAssertTrue(tracker.isDirty)
    }

    func testUndoBackToSavedPointReadsClean() {
        var tracker = DocumentDirtyTracker()
        let beforeEdit = tracker.token // captured by the undoable edit
        tracker.recordMutation()
        tracker.markSaved() // saved with the edit applied
        XCTAssertFalse(tracker.isDirty)

        // A second edit, then undo back to the saved revision.
        let beforeSecond = tracker.token
        tracker.recordMutation()
        XCTAssertTrue(tracker.isDirty)
        tracker.restore(token: beforeSecond)
        XCTAssertFalse(tracker.isDirty, "undo back to the saved revision is clean")

        // Undoing the FIRST edit too (past the save point) is dirty again.
        tracker.restore(token: beforeEdit)
        XCTAssertTrue(tracker.isDirty)
    }

    func testMarkSavedAtCapturedTokenIgnoresRacingEdit() {
        var tracker = DocumentDirtyTracker()
        tracker.recordMutation()
        let writeBaseline = tracker.token
        // An edit races in during the write.
        tracker.recordMutation()
        // The write completes and marks saved at the baseline it captured.
        tracker.markSaved(at: writeBaseline)
        XCTAssertTrue(tracker.isDirty, "the racing edit keeps the document dirty")
    }

    func testDivergentEditCannotReuseSavedIdentityOrDelayedSaveToken() {
        var tracker = DocumentDirtyTracker()
        let baseline = tracker.token
        tracker.recordMutation()
        let savedBranch = tracker.token
        tracker.markSaved()
        tracker.restore(token: baseline)
        tracker.recordMutation()
        XCTAssertNotEqual(tracker.token, savedBranch)
        XCTAssertTrue(tracker.isDirty)
        tracker.markSaved(at: savedBranch)
        XCTAssertTrue(tracker.isDirty, "a late write from the discarded branch cannot save this edit")
    }

    @MainActor
    func testDivergentNameAfterSaveAndUndoRemainsDirty() throws {
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Divergent-\(UUID()).mscope")
        defer { try? FileManager.default.removeItem(at: url) }
        store.setCustomName(0x1000, name: "A")
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        store.undoManager.undo()
        store.setCustomName(0x1000, name: "B")
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        let (reopened, _) = makeStore()
        XCTAssertTrue(reopened.openDocumentPackage(at: url))
        XCTAssertEqual(reopened.snapshot.addressOverrides[.primary(0x1000)]?.customName, "B")
    }

    @MainActor
    func testIndependentSavedWatchSurvivesNameUndoAndRemainsDirty() throws {
        let (store, _) = makeStore()
        store.setCustomName(0x1000, name: "A")
        let owner = try XCTUnwrap(store.captureSavedWatchOwner())
        let watch = try WorkspaceSavedWatchDefinition(id: UUID(), expression: "counter + 1")
        try store.replaceSavedWatchDefinitions([watch], owner: owner)
        store.undoManager.undo()
        XCTAssertEqual(store.savedWatchCatalog.definitions, [watch])
        XCTAssertTrue(store.isDirty)
    }

    @MainActor
    func testRedoToSavedNameRestoresCleanIdentity() throws {
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RedoSaved-\(UUID()).mscope")
        defer { try? FileManager.default.removeItem(at: url) }
        store.setCustomName(0x1000, name: "A")
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        store.undoManager.undo()
        XCTAssertTrue(store.isDirty)
        store.undoManager.redo()
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Pure AutosavePolicy

    func testPolicySavesWhenDirtyAndNoConflict() {
        XCTAssertEqual(AutosavePolicy.decide(isDirty: true, hasConflict: false), .save)
    }

    func testPolicySkipsWhenClean() {
        XCTAssertEqual(AutosavePolicy.decide(isDirty: false, hasConflict: false), .skipNoChanges)
    }

    func testPolicySkipsWhenConflictedEvenIfDirty() {
        XCTAssertEqual(AutosavePolicy.decide(isDirty: true, hasConflict: true), .skipConflict)
    }

    // MARK: - Store fixtures

    private func row(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
    }

    private func snapshot(
        _ addresses: [UInt64],
        includesBreakpointOwner: Bool = false
    ) -> WorkspaceSnapshot {
        let binaries: [BinaryImage] = includesBreakpointOwner
            ? [
                BinaryImage(
                    id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                    name: "Dirty fixture",
                    path: "/tmp/dirty-fixture",
                    kind: "Mach-O executable",
                    architecture: "arm64",
                    slot: .primary
                ),
            ]
            : []
        return WorkspaceSnapshot(
            binaries: binaries,
            functions: [],
            instructions: addresses.map(row),
            xrefs: [],
            hexBytes: Data()
        )
    }

    @MainActor
    private func makeStore(
        includesBreakpointOwner: Bool = false
    ) -> (WorkspaceStore, ManualAutosaveTrigger) {
        let trigger = ManualAutosaveTrigger()
        let store = WorkspaceStore(
            workspaceName: "Dirty",
            snapshot: snapshot(
                [0x1000, 0x1004, 0x1008],
                includesBreakpointOwner: includesBreakpointOwner
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: trigger
        )
        return (store, trigger)
    }

    // MARK: - Store dirty-state integration

    @MainActor
    func testFreshStoreIsNotDirty() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testOverrideMutationSetsDirty() {
        let (store, _) = makeStore()
        store.setCustomName(0x1000, name: "entry")
        XCTAssertTrue(store.isDirty)
    }

    @MainActor
    func testBreakpointToggleSetsDirty() {
        let (store, _) = makeStore(includesBreakpointOwner: true)
        store.toggleBreakpoint(0x1004)
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.snapshot.instructions.first { $0.address == 0x1004 }?.hasBreakpoint ?? false)
    }

    @MainActor
    func testBreakpointToggleOnUnknownAddressIsNoOp() {
        let (store, _) = makeStore(includesBreakpointOwner: true)
        store.toggleBreakpoint(0xDEAD)
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testUndoOfMutationClearsDirtyWhenSavedBaselineWasClean() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isDirty)
        store.setCustomName(0x1000, name: "entry")
        XCTAssertTrue(store.isDirty)
        store.undoManager.undo()
        XCTAssertFalse(store.isDirty, "undo back to the clean baseline is not dirty")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)])
    }

    @MainActor
    func testRedoReDirties() {
        let (store, _) = makeStore()
        store.setCustomName(0x1000, name: "entry")
        store.undoManager.undo()
        XCTAssertFalse(store.isDirty)
        store.undoManager.redo()
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "entry")
    }

    @MainActor
    func testSaveClearsDirtyAndUndoPastSaveReDirties() throws {
        let (store, _) = makeStore()
        store.setCustomName(0x1000, name: "entry")
        XCTAssertTrue(store.isDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirtyTest-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        XCTAssertFalse(store.isDirty, "a successful save clears dirty")

        // Undoing back past the save point makes it dirty again (the on-disk copy
        // still has the edit, the in-memory doc no longer does).
        store.undoManager.undo()
        XCTAssertTrue(store.isDirty)
    }

    @MainActor
    func testEditAfterSaveReDirties() throws {
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirtyTest-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: url) }
        store.setCustomName(0x1000, name: "entry")
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        XCTAssertFalse(store.isDirty)
        store.setCustomComment(0x1004, comment: "loop")
        XCTAssertTrue(store.isDirty)
    }

    // MARK: - Autosave decision + scheduler

    @MainActor
    func testMutationSchedulesAutosave() {
        let (store, trigger) = makeStore()
        XCTAssertFalse(trigger.isPending)
        store.setCustomName(0x1000, name: "entry")
        XCTAssertTrue(trigger.isPending, "a mutation arms the autosave debounce")
    }

    @MainActor
    func testAutosaveDecisionIsSaveWhenDirty() {
        let (store, _) = makeStore()
        store.setCustomName(0x1000, name: "entry")
        XCTAssertEqual(store.autosaveDecision, .save)
    }

    @MainActor
    func testAutosaveDecisionSkipsWhenClean() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.autosaveDecision, .skipNoChanges)
    }

    @MainActor
    func testHeadlessCompatibilityAutosaveFiresAfterMutationAndWritesPackage() throws {
        let (store, trigger) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirtyTest-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: url) }

        // Establish a known package URL (an explicit Save) so autosave has a target,
        // then make an edit and drive the debounce manually — no wall-clock sleep.
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        XCTAssertFalse(store.isDirty)

        store.setCustomName(0x1000, name: "entry")
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(trigger.firePending(), "the pending autosave fires")
        XCTAssertFalse(store.isDirty, "autosave persisted and cleared dirty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testHeadlessCompatibilityAutosavePreservesDurableIdentity() throws {
        let (store, trigger) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentityAutosave-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        let documentID = store.documentID
        let workspaceID = store.workspaceID

        store.setCustomName(0x1000, name: "autosaved")
        XCTAssertTrue(trigger.firePending())

        let package = try MacScopeDocumentPackage.openPackage(from: url)
        XCTAssertEqual(package.manifest.documentID, documentID)
        XCTAssertEqual(package.manifest.workspaceUUID, workspaceID)
    }

    @MainActor
    func testAutosaveDoesNotFireOnNoOp() {
        let (store, trigger) = makeStore()
        // No mutation occurred, so nothing was scheduled.
        XCTAssertFalse(trigger.firePending(), "a no-op never scheduled an autosave")
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Import resets the document baseline (data-loss regression)

    /// Regression for a CRITICAL data-loss path: after saving workspace A and then
    /// importing a fresh binary into the same window, a stale Cmd-Z from the previous
    /// document must NOT be able to dirty the new document and let autosave overwrite
    /// A's package file. `importBinary` must discard the previous undo history AND the
    /// previous package URL so there is neither a stale closure to fire nor a target
    /// to overwrite.
    @MainActor
    func testImportBinaryDiscardsStaleUndoAndPackageURL() async throws {
        let (store, trigger) = makeStore()

        // Save workspace A — establishes documentURL + a clean baseline.
        let savedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceA-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: savedURL) }
        XCTAssertTrue(store.writeDocumentPackage(to: savedURL))
        XCTAssertEqual(store.documentURL, savedURL)

        // Two edits: the second registers an undo closure whose prior dirty-token > 0,
        // which is exactly the closure that re-dirtied the new tracker in the bug.
        store.setCustomName(0x1000, name: "a")
        store.setCustomComment(0x1004, comment: "b")
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.undoManager.canUndo)

        // Import a fresh binary into the same window.
        let fixture = MachOFixture.makeExecutable()
        let importURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Imported-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: importURL) }
        try fixture.bytes.write(to: importURL)
        await store.importBinary(url: importURL)

        // The window is now a NEW unsaved workspace: clean, no package URL, no history.
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.documentURL, "import drops the previous package URL")
        XCTAssertFalse(store.undoManager.canUndo, "import clears the previous undo history")

        // A stale Cmd-Z can't dirty the imported doc, and a forced autosave has no
        // target — so workspace A's file is never overwritten by the import.
        store.undoManager.undo()
        XCTAssertFalse(store.isDirty, "stale undo cannot dirty the freshly imported document")
        store.performAutosaveIfNeeded()
        trigger.fire()
        XCTAssertNil(store.documentURL, "autosave still has no stale URL to overwrite")
    }

    @MainActor
    func testAutosaveFiringWhileCleanIsSkippedWrite() throws {
        let (store, trigger) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirtyTest-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(store.writeDocumentPackage(to: url))
        // Force-fire the trigger even though the document is clean: the policy gates
        // the write, so dirty-state stays false and nothing is double-persisted.
        XCTAssertFalse(store.isDirty)
        trigger.fire()
        XCTAssertFalse(store.isDirty)
    }
}

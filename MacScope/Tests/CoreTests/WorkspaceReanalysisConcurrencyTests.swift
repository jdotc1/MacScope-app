import Foundation
import XCTest
@testable import MacScope

/// Increment #3 of the engine concurrency track: a structural override (mark-as-code/data/
/// procedure) re-flows analysis OFF the main actor. The override applies instantly + undoably;
/// the derived listing/CFG/functions catch up a beat later, behind the `isReanalyzing` indicator.
///
/// These tests pin the behavior that is easy to regress once the re-flow is asynchronous:
///   1. the override is visible synchronously (the authoring layer never lags),
///   2. the DERIVED data lands only after the background task finishes, and
///   3. the epoch guard makes rapid edits / supersession correct (only the last edit wins).
///
/// The fixture is the same branch-into-prologue shape as the discovery tests: linear sweep sees
/// ONE function; Mark as Procedure at the prologue forces TWO. That makes the re-flow observable
/// purely through `snapshot.functions`, with no reliance on the heavier listing.
@MainActor
final class WorkspaceReanalysisConcurrencyTests: XCTestCase {

    /// mov ; b .+8 (-> 0x0c) ; ret ; 0x0c: sub sp,sp,#0x10 (prologue, the b target) ; ret.
    /// Conservatively one function; Mark as Procedure at 0x0c splits it into two.
    private static let branchIntoPrologue = Data([
        0x00, 0x00, 0x80, 0x52,         // 0x00 mov w0, #0
        0x02, 0x00, 0x00, 0x14,         // 0x04 b .+8   (-> 0x0c)
        0xc0, 0x03, 0x5f, 0xd6,         // 0x08 ret
        0xff, 0x43, 0x00, 0xd1,         // 0x0c sub sp, sp, #0x10   (prologue AND the b target)
        0xc0, 0x03, 0x5f, 0xd6          // 0x10 ret
    ])

    /// Builds a store backed by a REAL on-disk binary (so the re-flow's file-exists guard passes
    /// and `engine.openBinary` can reload it). Autosave disabled so no timer fires mid-test.
    private func makeStoreFromDisk(retainedContainerProvenance: Bool = false) throws -> (store: WorkspaceStore, boundary: UInt64) {
        let fixture = TinyMachO.make(code: Self.branchIntoPrologue)
        let url = try fixture.write()
        let engine = AnalysisEngine()
        var snapshot = try engine.analyze(url: url)
        if retainedContainerProvenance {
            // Seed outer-container presentation independently of this thin test payload.
            // A retained thin image cannot reconstruct bundle/universal display provenance.
            snapshot.binaries[0].kind = "app bundle"
            snapshot.binaries[0].architecture = "arm64 (universal slice 2/2 @ 0x4000)"
        }
        let store = WorkspaceStore(
            workspaceName: "reanalysis", snapshot: snapshot, engine: engine, autosaveScheduler: nil
        )
        return (store, fixture.baseAddress + 0x0c)
    }

    /// The override is synchronous; the derived re-flow is asynchronous and lands only after the
    /// background task completes (observed via `awaitPendingReanalysis`).
    func testMarkAsProcedureAppliesOverrideSyncThenReflowsFunctionsOffMain() async throws {
        let (store, boundary) = try makeStoreFromDisk()
        XCTAssertEqual(store.snapshot.functions.count, 1, "baseline: linear sweep merges the two bodies")
        XCTAssertFalse(store.isReanalyzing)

        store.setMarkAsProcedure(boundary, true)

        // Authoring layer is instant: the override is set and the kick is in flight, BEFORE any
        // derived re-flow has landed.
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(boundary)]?.markAsProcedure, true)
        XCTAssertTrue(store.isReanalyzing, "the re-flow runs in the background behind the indicator")
        XCTAssertEqual(store.snapshot.functions.count, 1, "derived data still shows the pre-re-flow state")

        await store.awaitPendingReanalysis()

        XCTAssertFalse(store.isReanalyzing, "indicator clears when the re-flow lands")
        XCTAssertEqual(store.snapshot.functions.map(\.startAddress).sorted(),
                       [boundary - 0x0c, boundary],
                       "the background re-flow split the function at the forced procedure start")
    }

    /// Undo reverts the override synchronously and re-kicks the (async) re-flow; after it lands the
    /// derived functions are back to one. Proves the undo path threads the same background re-flow.
    func testUndoRevertsOverrideAndReflowsBackToOneFunction() async throws {
        let (store, boundary) = try makeStoreFromDisk()
        store.setMarkAsProcedure(boundary, true)
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.functions.count, 2)

        store.undoManager.undo()
        XCTAssertNil(store.snapshot.addressOverrides[.primary(boundary)], "override reverted synchronously")
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.functions.count, 1, "re-flow after undo restores the merged function")
    }

    /// The epoch guard: two structural edits fired back-to-back must converge on the LAST edit's
    /// result, never a stale earlier re-flow clobbering it. Here the second edit clears the mark,
    /// so the final derived state must be one function regardless of completion ordering.
    func testRapidSupersedingEditsConvergeOnTheLastEdit() async throws {
        let (store, boundary) = try makeStoreFromDisk()

        store.setMarkAsProcedure(boundary, true)   // kick epoch N: would split into two
        store.setMarkAsProcedure(boundary, false)  // kick epoch N+1: clears it, back to one
        await store.awaitPendingReanalysis()

        XCTAssertFalse(store.isReanalyzing)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(boundary)])
        XCTAssertEqual(store.snapshot.functions.count, 1,
                       "only the last edit's re-flow may win; a stale earlier one must not clobber it")
    }

    /// The scripting / headless contract: a mutating command must re-flow SYNCHRONOUSLY, so the
    /// very next query in the same (synchronous) script sees the re-flowed result. No `await` here
    /// on purpose — `WorkspaceScriptingAPI.execute` forces the re-flow inline for mutating commands.
    func testScriptingMutatingCommandReflowsSynchronously() throws {
        let (store, boundary) = try makeStoreFromDisk()
        let api = WorkspaceScriptingAPI(store: store)

        let result = try api.execute("make-procedure", arguments: .object(["address": .hex(boundary)]))
        XCTAssertEqual(result["ok"]?.boolValue, true)

        // Synchronously after the command, the derived listing already reflects the split — the
        // scripted edit is deterministic without the caller awaiting any background work.
        XCTAssertFalse(store.isReanalyzing, "the scripted re-flow completed inline")
        let functions = try api.execute("functions").arrayValue
        XCTAssertEqual(functions?.count, 2, "the scripted Mark as Procedure re-flowed before the next query")
    }

    /// Regression: a NON-structural override edit (rename/comment/tag/...) that lands on the main
    /// actor DURING a background re-flow must survive when the re-flow lands. Such edits don't bump
    /// the epoch (they don't change the derived data), so the in-flight task is not superseded — and
    /// `applyReanalysisResult` must re-adopt the CURRENT override map, not overwrite it with the
    /// kick-time copy (which would silently drop the rename and orphan its undo action).
    func testNonStructuralEditDuringReflowSurvives() async throws {
        let (store, boundary) = try makeStoreFromDisk()
        let renameAddress = boundary - 0x0c   // the entry function start, distinct from the boundary

        store.setMarkAsProcedure(boundary, true)            // kicks the background re-flow
        XCTAssertTrue(store.isReanalyzing, "the re-flow is in flight")
        // A rename lands in the window before the re-flow completes — it must not bump the epoch.
        store.setCustomName(renameAddress, name: "renamed_entry")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(renameAddress)]?.customName, "renamed_entry",
                       "the rename applies synchronously")

        await store.awaitPendingReanalysis()

        XCTAssertEqual(store.snapshot.addressOverrides[.primary(renameAddress)]?.customName, "renamed_entry",
                       "the rename made during the re-flow window survived the landing")
        XCTAssertEqual(store.snapshot.functions.count, 2,
                       "the structural re-flow still applied (the fix didn't desync derived data)")
    }

    /// A rebuild at the original path must not change the bytes owned by an open investigation.
    /// Exercise both the interactive and synchronous scripting reanalysis paths, and require the
    /// requested procedure split so simply skipping the reanalysis cannot satisfy this test.
    func testReanalysisRetainsCapturedImageAfterOriginalSourceChanges() async throws {
        for synchronous in [false, true] {
            let (store, boundary) = try makeStoreFromDisk(retainedContainerProvenance: true)
            let binary = try XCTUnwrap(store.focusedBinary)
            let sourceURL = URL(fileURLWithPath: binary.path)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let capturedBytes = store.snapshot.imageBytes
            let capturedName = binary.name
            let capturedKind = binary.kind
            let capturedArchitecture = binary.architecture
            let capturedIdentity = binary.artifactIdentity
            let entry = boundary - 0x0c
            let fileOffset = try XCTUnwrap(FileAddressMapping.resolvedFileOffset(
                forVirtualAddress: entry, in: store.snapshot.imageByteMappings(in: .primary)
            ))
            let start = try XCTUnwrap(Int(exactly: fileOffset))
            var replacementBytes = capturedBytes
            // Change mov w0, #0 to mov w0, #1, preserving addresses and container metadata.
            replacementBytes.replaceSubrange(start..<(start + 4), with: [0x20, 0x00, 0x80, 0x52])
            XCTAssertNotEqual(replacementBytes, capturedBytes)
            try replacementBytes.write(to: sourceURL, options: .atomic)
            store.setCustomComment(entry, comment: "Evidence from the captured image")

            if synchronous {
                store.withSynchronousReanalysis { store.setMarkAsProcedure(boundary, true) }
                XCTAssertFalse(store.isReanalyzing)
            } else {
                store.setMarkAsProcedure(boundary, true)
            }
            await store.awaitPendingReanalysis()

            XCTAssertEqual(store.snapshot.functions.count, 2)
            XCTAssertEqual(store.snapshot.imageBytes, capturedBytes)
            XCTAssertEqual(store.focusedBinary?.id, binary.id)
            XCTAssertEqual(store.focusedBinary?.name, capturedName)
            XCTAssertEqual(store.focusedBinary?.kind, capturedKind)
            XCTAssertEqual(store.focusedBinary?.architecture, capturedArchitecture)
            XCTAssertEqual(store.focusedBinary?.path, binary.path)
            XCTAssertEqual(store.focusedBinary?.artifactIdentity, capturedIdentity)
            XCTAssertEqual(store.snapshot.addressOverrides[.primary(entry)]?.customComment,
                           "Evidence from the captured image")
        }
    }

}

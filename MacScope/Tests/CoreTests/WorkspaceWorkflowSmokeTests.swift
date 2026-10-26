import XCTest
@testable import MacScope

/// End-to-end workflow smoke test: drives the typed command router + workspace store through
/// a REAL analyzed binary (the same `/bin/ls` the golden harness uses), exercising the staple
/// authoring + navigation workflow steps the stabilization contract lists. This is the
/// application-level equivalent of a UI smoke test (UI automation being fragile): it proves
/// the commands operate on real analyzed data, not just synthetic snapshots. Undo/redo and
/// save→reopen round-tripping are covered by WorkspaceDatabaseTests / authoring tests.
@MainActor
final class WorkspaceWorkflowSmokeTests: XCTestCase {

    private let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")

    private func analyzedStore() throws -> WorkspaceStore {
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls is not readable on this host")
        }
        let snapshot = try AnalysisEngine().analyze(url: systemBinaryURL)
        return WorkspaceStore(workspaceName: "Smoke", snapshot: snapshot, engine: AnalysisEngine())
    }

    func testAuthoringAndNavigationWorkflowOnRealBinary() throws {
        let store = try analyzedStore()
        let address = try XCTUnwrap(store.snapshot.instructions.first?.address,
                                    "analysis produced no instructions")

        // 1. Navigate to an address (goto / select).
        store.selectInstruction(address)
        XCTAssertEqual(store.selectedAddress, address)

        // 2. Add + remove a bookmark via the command router.
        store.perform(.addBookmark)
        XCTAssertNotNil(store.snapshot.bookmark(at: address))
        store.perform(.removeBookmark)
        XCTAssertNil(store.snapshot.bookmark(at: address))

        // 3. Mark a range undefined (toggle) and back.
        store.perform(.markAsUndefined)
        XCTAssertTrue(store.snapshot.isUndefined(at: address))
        store.perform(.markAsUndefined)
        XCTAssertFalse(store.snapshot.isUndefined(at: address))

        // 4. Apply a byte patch (NOP) then clear it.
        store.perform(.replaceWithNOP)
        XCTAssertNotNil(store.snapshot.patch(at: address))
        store.perform(.clearPatch)
        XCTAssertNil(store.snapshot.patch(at: address))

        // 5. Find + Find Next over the real listing, stepping to a hit.
        let outcome = store.runSearch("ret", mode: .text)
        if !outcome.results.isEmpty {
            store.seedSearchCursor(outcome.results, selecting: nil)
            XCTAssertTrue(store.isEnabled(.findNext))
            store.perform(.findNext)
            XCTAssertEqual(store.selectedAddress, store.searchCursor?.current?.address)
        }
    }
}

import XCTest
@testable import MacScope

/// WS-2 Stage 1: menu commands must address the FOCUSED document's store, not broadcast to every
/// open window. The bus carries the target store in `userInfo[commandTargetStoreKey]`; a store
/// ignores a command whose target is a different store (or absent). With one window the focused
/// store is always self, so this is byte-identical to the old broadcast — these tests pin the
/// filtering that makes multi-document windows safe (WS-2 Stage 3).
@MainActor
final class WorkspaceCommandTargetingTests: XCTestCase {
    private func makeStore(_ name: String) -> WorkspaceStore {
        WorkspaceStore(workspaceName: name, snapshot: AnalysisEngine.previewSnapshot(), engine: AnalysisEngine())
    }

    private func command(_ name: Notification.Name, target: WorkspaceStore?, object: Any? = nil) -> Notification {
        let userInfo = target.map { [WorkspaceStore.commandTargetStoreKey: $0] }
        return Notification(name: name, object: object, userInfo: userInfo)
    }

    /// The core guard: a command is for THIS store only when its target IS this store. This is the
    /// RED anchor — neuter `commandTargetsSelf` to `true` and the foreign/absent cases below fail.
    func testCommandTargetsSelfMatchesOnlyTheTargetStore() {
        let storeA = makeStore("A")
        let storeB = makeStore("B")

        XCTAssertTrue(storeA.commandTargetsSelf(command(.macScopeSave, target: storeA)),
                      "a command targeting this store is for it")
        XCTAssertFalse(storeA.commandTargetsSelf(command(.macScopeSave, target: storeB)),
                       "a command targeting a DIFFERENT store must be ignored")
        XCTAssertFalse(storeA.commandTargetsSelf(command(.macScopeSave, target: nil)),
                       "a command with no target (no focused document) is ignored")
        XCTAssertFalse(storeA.commandTargetsSelf(
            Notification(name: .macScopeSave, object: nil, userInfo: ["macScopeTargetStore": "not a store"])),
                       "a malformed target is ignored, never crashes")
    }

    /// End-to-end through a store observer: a foreign-targeted SetEditorMode must NOT mutate this
    /// store, while a self-targeted one does. Proves the guard is actually wired into the observers.
    func testForeignTargetedCommandDoesNotReachStoreObserver() async {
        let storeA = makeStore("A")
        let storeB = makeStore("B")
        let original = storeA.editorMode
        let other: EditorMode = EditorMode.allCases.first { $0 != original } ?? original

        // Foreign target → ignored.
        NotificationCenter.default.post(command(.macScopeSetEditorMode, target: storeB, object: other))
        await settle()
        XCTAssertEqual(storeA.editorMode, original, "storeA must ignore a command targeting storeB")

        // Self target → applied.
        NotificationCenter.default.post(command(.macScopeSetEditorMode, target: storeA, object: other))
        await settle()
        XCTAssertEqual(storeA.editorMode, other, "storeA must apply a command targeting itself")
    }

    /// The typed WorkspaceCommand router (WorkspaceCommandHandlers) owns the mutating authoring
    /// ops. It must apply a command ONLY to the store it targets — a regression guard for the
    /// cross-fire bug where the router discarded the notification and `perform`ed on every window.
    /// This exercises the exact guard-then-perform the router now runs.
    func testTypedCommandRouterAppliesOnlyToTheTargetStore() {
        let storeA = makeStore("A")
        let storeB = makeStore("B")
        // Both windows have a selection, so `addBookmark` is enabled on both — proving the filter,
        // not `isEnabled`, is what confines the mutation.
        storeA.selectedAddress = storeA.snapshot.instructions.first?.address
        storeB.selectedAddress = storeB.snapshot.instructions.first?.address
        XCTAssertNotNil(storeA.selectedAddress)
        XCTAssertTrue(storeA.snapshot.bookmarks.isEmpty)
        XCTAssertTrue(storeB.snapshot.bookmarks.isEmpty)

        let note = Notification(name: WorkspaceCommand.addBookmark.notificationName,
                                object: nil,
                                userInfo: [WorkspaceStore.commandTargetStoreKey: storeA])
        // The EXACT call each window's WorkspaceCommandHandlers makes on receipt.
        storeA.perform(.addBookmark, ifTargetedBy: note)
        storeB.perform(.addBookmark, ifTargetedBy: note)

        XCTAssertEqual(storeA.snapshot.bookmarks.count, 1, "the targeted window gets the bookmark")
        XCTAssertTrue(storeB.snapshot.bookmarks.isEmpty,
                      "a command targeting window A must NOT mutate window B (the cross-fire bug)")
    }

    /// Lets the observers' `Task { @MainActor }` bodies run before asserting.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

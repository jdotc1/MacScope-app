import XCTest
@testable import MacScope

final class WorkspaceRestorationPolicyTests: XCTestCase {
    func testLooseBinaryReplacesPreviouslySavedDocument() {
        var state = WorkspaceRestorationPolicy(documentPath: "/old.mscope", binaryPath: "")
        state.remember(documentPath: nil, binaryPath: "/new.bin")
        XCTAssertEqual(state.documentPath, "")
        XCTAssertEqual(state.binaryPath, "/new.bin")
    }

    func testEmptyInitialStorePreservesRestorationPaths() {
        var state = WorkspaceRestorationPolicy(documentPath: "/saved.mscope", binaryPath: "")
        state.remember(documentPath: nil, binaryPath: nil)
        XCTAssertEqual(state.documentPath, "/saved.mscope")
        XCTAssertEqual(state.binaryPath, "")
    }

    func testSavedDocumentSupersedesRememberedBinary() {
        var state = WorkspaceRestorationPolicy(documentPath: "", binaryPath: "/loose.bin")
        state.remember(documentPath: "/saved.mscope", binaryPath: "/loose.bin")
        XCTAssertEqual(state.documentPath, "/saved.mscope")
        XCTAssertEqual(state.binaryPath, "")
    }

    func testExplicitOpenOrCancellationSuppressesRestorationEvenWhileStoreIsEmpty() {
        XCTAssertTrue(WorkspaceRestorationPolicy.permitsAutomaticOpen(
            isCancelled: false, hasRequestedDocumentOpen: false, hasRequestedBinaryLoad: false))
        XCTAssertFalse(WorkspaceRestorationPolicy.permitsAutomaticOpen(
            isCancelled: true, hasRequestedDocumentOpen: false, hasRequestedBinaryLoad: false))
        XCTAssertFalse(WorkspaceRestorationPolicy.permitsAutomaticOpen(
            isCancelled: false, hasRequestedDocumentOpen: true, hasRequestedBinaryLoad: false))
        XCTAssertFalse(WorkspaceRestorationPolicy.permitsAutomaticOpen(
            isCancelled: false, hasRequestedDocumentOpen: false, hasRequestedBinaryLoad: true))
    }

    @MainActor
    func testBinaryLoadIntentIsVisibleBeforeInspectionFinishes() {
        let store = WorkspaceStore(
            workspaceName: "restoration-admission",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        XCTAssertFalse(store.hasRequestedBinaryLoad)
        // No suspension: the asynchronous inspection cannot finish on MainActor before this
        // assertion. Restoration must already yield, including if that inspection later fails.
        store.beginImport(url: URL(filePath: "/nonexistent-restoration-admission.bin"))
        XCTAssertTrue(store.hasRequestedBinaryLoad)
        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.loaderOptionsRequest)
        store.cancelLoaderOptions()
        XCTAssertTrue(store.hasRequestedBinaryLoad)
    }
}

import XCTest
@testable import MacScope

/// Recents recording: opening or saving a `.mscope` project records it as a recent document
/// (the source for the File ▸ Open Recent menu). Uses an injected spy so the real system
/// recents (`NSDocumentController`) are never touched and the behavior is deterministic.
@MainActor
final class RecentDocumentsTests: XCTestCase {

    @MainActor
    private final class SpyRecents: WorkspaceRecentsRecording {
        var noted: [URL] = []
        private(set) var cleared = false
        func noteRecentDocument(_ url: URL) { noted.append(url) }
        var recentDocumentURLs: [URL] { noted }
        func clearRecentDocuments() { cleared = true; noted.removeAll() }
    }

    private func temporaryPackageURL(_ name: String) throws -> (parent: URL, url: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (parent, parent.appendingPathComponent(name, isDirectory: true))
    }

    func testHeadlessCompatibilitySaveRecordsRecentDocument() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let spy = SpyRecents()
        store.recents = spy
        let (parent, url) = try temporaryPackageURL("Saved.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertTrue(store.writeDocumentPackage(to: url))
        let canonicalURL = try WorkspaceDocumentLocation.canonicalized(from: url).canonicalURL
        XCTAssertEqual(spy.noted, [canonicalURL])
    }

    func testHeadlessCompatibilityOpenRecordsRecentDocument() throws {
        let source = WorkspaceStore.bootstrapForPreviewFixture()
        let (parent, url) = try temporaryPackageURL("Reopen.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: url))

        let target = WorkspaceStore.bootstrapForPreviewFixture()
        let spy = SpyRecents()
        target.recents = spy
        XCTAssertTrue(target.openDocumentPackage(at: url))
        let canonicalURL = try WorkspaceDocumentLocation.canonicalized(from: url).canonicalURL
        XCTAssertEqual(spy.noted, [canonicalURL])
    }

    func testHeadlessCompatibilityFailedOpenDoesNotRecordRecent() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let spy = SpyRecents()
        store.recents = spy
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mscope", isDirectory: true)

        XCTAssertFalse(store.openDocumentPackage(at: missing))
        XCTAssertTrue(spy.noted.isEmpty)
    }
}

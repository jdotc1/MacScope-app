import AppKit

/// An injectable seam for recording and listing recently-opened `.mscope` projects. The real
/// implementation is backed by `NSDocumentController`, so recents persist across launches and
/// integrate with the Dock / Finder "Recent Items"; injecting a fake keeps the store's
/// record-on-open/save behavior unit-testable without touching the user's actual recent items.
@MainActor
protocol WorkspaceRecentsRecording {
    func noteRecentDocument(_ url: URL)
    var recentDocumentURLs: [URL] { get }
    func clearRecentDocuments()
}

/// The real macOS recent-documents list (`NSDocumentController.shared`). MacScope is a
/// SwiftUI (non-`NSDocument`) app, but the shared controller still manages a persistent,
/// deduplicated, system-integrated recents list we can drive directly.
@MainActor
struct SystemDocumentRecents: WorkspaceRecentsRecording {
    func noteRecentDocument(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    var recentDocumentURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

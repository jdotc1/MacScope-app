import Foundation

/// Presentation state for one document window's Open Binary file importer.
///
/// Root cause it guards against (Tier 2 GUI carry-over): File ▸ Open Binary set the window's
/// `fileImporter` flag to `true` while the "Patched Binary Saved" alert sheet was up. SwiftUI
/// cannot attach the importer to a window that already shows a sheet, so it never presented the
/// panel and never wrote the flag back to `false`. Every later Open Binary then wrote `true` onto
/// a flag that was already `true`: no state change, no presentation, until relaunch.
///
/// The gate never raises the flag while the window shows a sheet. A request made under a
/// document alert is queued and replayed once the alert closes; a request made under any other
/// sheet is refused (the window beeps). A flag left `true` with no importer actually on screen
/// is treated as stale and reset before the request is replayed, so the importer cannot wedge.
struct WorkspaceOpenBinaryImporterGate: Equatable {
    /// What the window shows at the moment of a request.
    struct Context: Equatable {
        /// One of the store-driven document alerts (Save Failed, Patched Binary Saved, Debug
        /// Symbols Imported / Could Not Read Debug Symbols) is pending or on screen.
        var documentAlertPending: Bool
        /// The window has an attached sheet of any kind (alert, authoring sheet, importer).
        var windowHasSheet: Bool
        /// The attached sheet is an open panel, i.e. the importer is already on screen.
        var importerVisible: Bool

        static let clear = Context(documentAlertPending: false, windowHasSheet: false, importerVisible: false)
    }

    enum Decision: Equatable {
        /// The flag is now `true`; SwiftUI presents the importer.
        case present
        /// The flag was stale (`true` with nothing on screen) and is now `false`; replay the
        /// request on the next main-queue turn so SwiftUI sees a fresh `false` → `true` edge.
        case replayAfterReset
        /// Queued until the document alert closes.
        case deferredUntilAlertCloses
        /// The importer is already on screen; bring it forward.
        case alreadyVisible
        /// Another sheet blocks the window; refuse visibly.
        case refused
        /// Nothing to do (no queued request).
        case none
        /// The alert closed but its sheet is still leaving the window; try again shortly.
        case retryShortly
    }

    /// How many short retries a queued request waits for the closing alert sheet to detach.
    static let maximumDrainAttempts = 20

    private(set) var isImporterPresented = false
    private(set) var isRequestDeferred = false
    private(set) var drainAttempts = 0

    /// File ▸ Open Binary, the toolbar button, or a replay.
    mutating func request(_ context: Context) -> Decision {
        if context.importerVisible {
            return .alreadyVisible
        }
        if isImporterPresented {
            // Nothing is on screen, so the flag is stale. Clear it and let the caller replay.
            isImporterPresented = false
            return .replayAfterReset
        }
        if context.documentAlertPending {
            isRequestDeferred = true
            drainAttempts = 0
            return .deferredUntilAlertCloses
        }
        if context.windowHasSheet {
            return .refused
        }
        isImporterPresented = true
        return .present
    }

    /// Called when the document alerts clear, and again on each short retry.
    mutating func drainDeferred(_ context: Context) -> Decision {
        guard isRequestDeferred else { return .none }
        if context.documentAlertPending {
            // A second alert replaced the first one; stay queued for it.
            drainAttempts = 0
            return .deferredUntilAlertCloses
        }
        if context.windowHasSheet, !context.importerVisible {
            drainAttempts += 1
            if drainAttempts > Self.maximumDrainAttempts {
                isRequestDeferred = false
                drainAttempts = 0
                return .refused
            }
            return .retryShortly
        }
        isRequestDeferred = false
        drainAttempts = 0
        return request(context)
    }

    /// SwiftUI wrote `false` back through the binding (the importer closed).
    mutating func importerDidDismiss() {
        isImporterPresented = false
    }
}

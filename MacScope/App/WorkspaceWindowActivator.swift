import AppKit

@MainActor
protocol WorkspaceWindowActivating: AnyObject {
    @discardableResult
    func activateWindow(_ windowID: WorkspaceWindowID) -> Bool
}

/// Exact window-identity activation for duplicate document-open requests. Window titles and
/// paths are presentation data and never participate in ownership or activation decisions.
@MainActor
final class WorkspaceWindowActivator: WorkspaceWindowActivating {
    private final class WeakWindowReference {
        weak var window: NSWindow?

        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private var windows: [WorkspaceWindowID: WeakWindowReference] = [:]

    func window(for windowID: WorkspaceWindowID) -> NSWindow? {
        windows[windowID]?.window
    }

    func register(_ window: NSWindow, for windowID: WorkspaceWindowID) {
        windows[windowID] = WeakWindowReference(window)
    }

    func unregister(_ windowID: WorkspaceWindowID, window: NSWindow? = nil) {
        guard let registered = windows[windowID]?.window else {
            windows.removeValue(forKey: windowID)
            return
        }
        if let window, registered !== window { return }
        windows.removeValue(forKey: windowID)
    }

    @discardableResult
    func activateWindow(_ windowID: WorkspaceWindowID) -> Bool {
        guard let window = windows[windowID]?.window else {
            windows.removeValue(forKey: windowID)
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

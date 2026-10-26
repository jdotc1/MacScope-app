import AppKit

/// A window whose key status can be restored after an app-modal panel. `NSWindow` conforms; tests
/// substitute a recorder.
@MainActor
protocol KeyWindowRestorable: AnyObject {
    func makeKeyAndOrderFront(_ sender: Any?)
}

extension NSWindow: KeyWindowRestorable {}

/// Runs an app-modal panel and gives key status back to the window that issued the command.
/// A panel run from a `Task` (after an `await`) rather than from an event doesn't get key status
/// handed back when it closes, so a following result alert had no key window and Return/Escape
/// went nowhere (Tier 2 finding; first fixed for Save Patched Binary in #372).
enum ModalPanelFocus {
    @MainActor
    static func run<Response>(host: KeyWindowRestorable? = NSApp.keyWindow ?? NSApp.mainWindow,
                              _ runModal: () -> Response) -> Response {
        let response = runModal()
        host?.makeKeyAndOrderFront(nil)
        return response
    }
}

import Foundation

/// The front-document registry the live AppleScript (`NSScriptCommand`) shell resolves to
/// find the workspace an Apple event should target. MacScope drives every window from a
/// single shared `WorkspaceStore`, so the app registers it here once; keeping the registry
/// decoupled from the Apple-event machinery makes the resolution unit-testable.
@MainActor
final class ScriptingHost {
    static let shared = ScriptingHost()
    private init() {}

    /// The workspace the next scripting command targets. Weak: the store's lifetime is owned
    /// by the SwiftUI `App`, not by this registry.
    weak var activeStore: WorkspaceStore?

    /// A `WorkspaceScriptingAPI` over the active store, or nil when no document is registered.
    var activeAPI: WorkspaceScriptingAPI? {
        activeStore.map { WorkspaceScriptingAPI(store: $0) }
    }
}

import SwiftUI

private struct DebuggerRuntimeAuthoritiesEnvironmentKey: EnvironmentKey {
    /// Missing app composition is an unavailable authority, never permission to create an
    /// independent per-window authority graph.
    static let defaultValue: DebuggerRuntimeAuthorities? = nil
}

extension EnvironmentValues {
    /// The single authority graph retained by `MacScopeAppRuntimeServices`. Consumers must fail
    /// closed when this is `nil`; previews and isolated views do not acquire debugger authority.
    var debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities? {
        get { self[DebuggerRuntimeAuthoritiesEnvironmentKey.self] }
        set { self[DebuggerRuntimeAuthoritiesEnvironmentKey.self] = newValue }
    }
}

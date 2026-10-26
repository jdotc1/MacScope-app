import SwiftUI

/// Publishes the key window's `WorkspaceStore` as a SwiftUI focused value so the menu-command
/// layer (`MacScopeCommands`) can address the FOCUSED document instead of broadcasting to every
/// open window. This is the ownership seam WS-2 is built on: today there is exactly one window, so
/// the focused store is always the only store (behavior is byte-identical); once multiple document
/// windows exist, a menu command reaches only the front one.
struct WorkspaceStoreFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspaceStore
}

@MainActor
protocol NativeDecompilerWindowCommandRouting: AnyObject {
    var enabledCommands: Set<NativeDecompilerControlCommand> { get }
    func perform(_ command: NativeDecompilerControlCommand)
}

struct NativeDecompilerWindowCommandsFocusedValueKey: FocusedValueKey {
    typealias Value = any NativeDecompilerWindowCommandRouting
}

/// One immutable focused-window command cut. The handlers are the same closures used by the
/// dashboard, so menu dispatch crosses the Root's pending-intent fence rather than mutating the
/// Store or runtime directly.
struct ReconstructionWindowCommandRouting {
    let controls: ReconstructionControlProjection
    let dispatcher: ReconstructionDashboardCommandDispatcher

    func canPerform(_ command: ReconstructionCommandKind) -> Bool {
        controls.availability(for: command).enabled
            && dispatcher.action(for: command) != nil
    }

    func help(for command: ReconstructionCommandKind) -> String {
        let availability = controls.availability(for: command)
        guard availability.enabled else { return availability.help }
        guard dispatcher.action(for: command) != nil else {
            return "The Reconstruction command boundary is unavailable in this window."
        }
        return availability.help
    }

    @discardableResult
    func perform(_ command: ReconstructionCommandKind) -> Bool {
        guard canPerform(command) else { return false }
        return dispatcher.dispatch(command)
    }
}

struct ReconstructionWindowCommandsFocusedValueKey: FocusedValueKey {
    typealias Value = ReconstructionWindowCommandRouting
}

extension FocusedValues {
    var workspaceStore: WorkspaceStore? {
        get { self[WorkspaceStoreFocusedValueKey.self] }
        set { self[WorkspaceStoreFocusedValueKey.self] = newValue }
    }

    var nativeDecompilerCommands: (any NativeDecompilerWindowCommandRouting)? {
        get { self[NativeDecompilerWindowCommandsFocusedValueKey.self] }
        set { self[NativeDecompilerWindowCommandsFocusedValueKey.self] = newValue }
    }

    var reconstructionWindowCommands: ReconstructionWindowCommandRouting? {
        get { self[ReconstructionWindowCommandsFocusedValueKey.self] }
        set { self[ReconstructionWindowCommandsFocusedValueKey.self] = newValue }
    }
}

/// The store a descendant view's context-menu command should target (WS-2). The root view of
/// each window injects ITS store here, so a leaf row (disassembly / pseudocode) can stamp its
/// posted command for that window without threading the store through every value-type row.
/// A command reaches only the window whose store it names, so with multiple document windows a
/// right-click authoring action mutates the right document.
private struct CommandTargetStoreKey: EnvironmentKey {
    static let defaultValue: WorkspaceStore? = nil
}

extension EnvironmentValues {
    var commandTargetStore: WorkspaceStore? {
        get { self[CommandTargetStoreKey.self] }
        set { self[CommandTargetStoreKey.self] = newValue }
    }
}

extension Notification {
    /// Builds the `userInfo` that stamps a command's target document store (WS-2), or nil when
    /// there is no target (an untargeted command is ignored by every store's guard).
    static func commandTargetUserInfo(_ store: WorkspaceStore?) -> [AnyHashable: Any]? {
        store.map { [WorkspaceStore.commandTargetStoreKey: $0] }
    }
}

import SwiftUI
import LumenUI

/// MacScope's layout shortcuts, resolved from the user's editable binding set.
/// Disabled Lumen command families have no shortcut authority in this workspace.
struct DSWorkspaceViewShortcuts {
    let inspector: KeyboardShortcut?
    let panel: KeyboardShortcut?

    init(bindings: KeyBindingSet) {
        inspector = bindings.chord(for: .toggleInspector).keyboardShortcut
        panel = bindings.chord(for: .togglePanel).keyboardShortcut
    }

    var lumenShortcuts: LumenViewShortcuts {
        // U8-0: the window's left toggle answers ⌃⌘S; the panel keeps the user's binding.
        LumenViewShortcuts(
            navigator: LumenShortcuts.navigator,
            panel: panel,
            inspector: inspector,
            previousTab: nil,
            nextTab: nil,
            commandPalette: nil
        )
    }
}

/// The View menu owns layout shortcut registration. Observing the persisted override
/// payload refreshes the resolved shortcuts when the Settings editor rebinds or resets them.
struct DSWorkspaceViewCommands: Commands {
    @AppStorage(KeyBindingSet.storageKey) private var overrides: Data?

    var body: some Commands {
        LumenViewCommands(
            shortcuts: DSWorkspaceViewShortcuts(
                bindings: KeyBindingSet.resolvingOverrides(overrides)
            ).lumenShortcuts,
            commandPalette: false,
            tabNavigation: false,
            sidebarFallback: false
        )
    }
}

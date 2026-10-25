import AppKit
import SwiftUI
import LumenTokens
import LumenUI
import MacScopeShell
import MacScopeTheme

/// MacScope's interface on synthetic data: the workspace window with its navigator, editor modes,
/// inspector and debugger panel, plus the theme settings. Run with `swift run MacScope`.
@main
struct MacScopeApp: App {
    @State private var store: LumenThemeStore

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        let store = LumenThemeStore(
            registry: LumenRegistry(packs: [.core, .code, .macScope]),
            configuration: LumenStoreConfiguration(
                appName: "MacScope",
                themesDirectory: FileManager.default.temporaryDirectory.appending(path: "MacScopeThemes"),
                defaultsSuiteName: "com.macscope.design"))
        LumenThemeStore.install(store, watchesThemesFolder: false)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        Window("MacScope", id: "workspace") {
            MacScopeWorkspace()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .lumenMetrics(.standard)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: MacScopeWorkspace.defaultSize.width, height: MacScopeWorkspace.defaultSize.height)
        .commands {
            LumenViewCommands()
        }

        Settings {
            LumenAppearanceSettings()
                .lumenPaletteRoot(store: store)
                .lumenDensityRoot(store: store)
                .frame(width: 620, height: 460)
        }
    }
}

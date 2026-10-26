import AppKit
import LumenTokens
import LumenUI
import SwiftUI
import Synchronization

/// MacScope naming compatibility over Lumen's observable store. The package owns selection,
/// caches, persistence and file watching; editor-context reads retain MacScope's v5 behavior.
final class DSThemeStore: Sendable {
    static let configuration = LumenStoreConfiguration(appName: "MacScope", defaultThemeID: DSBuiltInThemes.defaultID)
    static let selectionDefaultsKey = configuration.selectionDefaultsKey(for: .window)
    static let editorSelectionDefaultsKey = configuration.selectionDefaultsKey(for: .editor)
    static let systemAccentDefaultsKey = configuration.systemAccentDefaultsKey
    static let didChangeNotification = LumenThemeStore.didChangeNotification
    static var userThemesDirectory: URL { configuration.resolvedThemesDirectory }

    let lumen: LumenThemeStore

    // Tests may inject a nonpersisting store without initializing the app store.
    @TaskLocal static var sharedOverride: DSThemeStore?
    private static let testShared = Mutex<DSThemeStore?>(nil)
    static var shared: DSThemeStore {
        sharedOverride ?? testShared.withLock { $0 } ?? persistentShared
    }

    /// Test-run injection avoids lazy migration through indirect `.active` users.
    /// Installed once and never reset; no watcher or persistent selection writes.
    static func installNonpersistingTestSharedStore() {
        testShared.withLock { store in
            if store == nil { store = DSThemeStore(persistsSelection: false) }
        }
    }
    private static let persistentShared: DSThemeStore = {
        let store = DSThemeStore()
        store.watchThemesDirectory()
        return store
    }()

    /// Call from App.init before any view or color is constructed.
    static func installLumen(_ store: DSThemeStore = .shared, watchesThemesFolder: Bool = true) {
        LumenThemeStore.install(store.lumen, watchesThemesFolder: watchesThemesFolder)
    }

    init(themes: [LumenTheme]? = nil, selectedID: String? = nil, persistsSelection: Bool = true,
         themesDirectory: URL? = nil) {
        if persistsSelection { DSLumenPreferences.migrate(.standard) }
        var configuration = Self.configuration
        configuration.themesDirectory = themesDirectory
        lumen = LumenThemeStore(registry: MacScopeLumen.registry, configuration: configuration,
                                themes: themes, persistsSelection: persistsSelection)
        if let selectedID { lumen.select(selectedID) }
    }

    var theme: LumenTheme { lumen.theme() }
    var themes: [LumenTheme] { lumen.themes }
    var editorTheme: LumenTheme { lumen.theme(for: .editor) }
    var editorMatchesWindow: Bool { lumen.surfaceFollowsWindow(.editor) }
    var editorColorScheme: ColorScheme? { lumen.forcedAppearance(for: .editor) }
    var usesSystemAccent: Bool { lumen.usesSystemAccent }
    var themesDirectory: URL { lumen.themesDirectory }
    var themeFileProblems: [LumenThemeFileProblem] { lumen.themeFileProblems }
    func userThemeFile(for id: LumenTheme.ID) -> URL? { lumen.userThemeFile(for: id) }
    func select(_ id: LumenTheme.ID) { lumen.select(id) }
    func selectEditorTheme(_ id: LumenTheme.ID?) { lumen.select(id, for: .editor) }
    func setUsesSystemAccent(_ enabled: Bool) { lumen.setUsesSystemAccent(enabled) }
    func reloadUserThemes() { lumen.reloadUserThemes() }
    func watchThemesDirectory() { lumen.watchThemesDirectory() }
    func paletteKey() -> LumenPaletteKey { lumen.paletteKey }
    func resolvedPalette() -> LumenResolvedPalette { lumen.resolvedPalette() }
    /// The palette as drawn on the editor surface (code panes): the editor theme for editor roles.
    func resolvedEditorPalette() -> LumenResolvedPalette { lumen.resolvedPalette(on: .editor) }

    func color(_ token: LumenToken, editorSurface: Bool = false) -> Color {
        editorSurface ? Color(nsColor: nsColor(token, editorSurface: true)) : lumen.color(token)
    }

    func nsColor(_ token: LumenToken, editorSurface: Bool = false) -> NSColor {
        guard editorSurface, MacScopeLumen.registry.surface(of: token) != .editor else {
            return lumen.nsColor(token)
        }
        // Lumen's declared token surface cannot express a foreground used on both window
        // chrome and editor rows. Contextual reads use the editor's theme for those roles.
        let theme = editorTheme
        let accent = usesSystemAccent && token.followsSystemAccent
        return NSColor(name: "macscope.editor.\(theme.id).\(token.rawValue)") { appearance in
            let variant = LumenAppearance(appearance)
            guard accent, let system = LumenSystemAccent.current() else {
                return theme.nsColor(token, for: variant)
            }
            var resolved = NSColor.systemBlue
            appearance.performAsCurrentDrawingAppearance {
                resolved = system.usingColorSpace(.sRGB) ?? .systemBlue
            }
            switch token {
            case .accentSubtle:
                return theme.nsColor(.bgCanvas, for: variant).blended(withFraction: 0.18, of: resolved) ?? resolved
            case .accentSoft: return resolved.blended(withFraction: 0.4, of: .white) ?? resolved
            case .fgOnAccent:
                return LumenSystemAccent.textColor(on: LumenColor(red: resolved.redComponent,
                    green: resolved.greenComponent, blue: resolved.blueComponent)).nsColor(in: .sRGB)
            default: return resolved
            }
        }
    }

    private static let activeOverride = Mutex<DSThemeStore?>(nil)
    static var active: DSThemeStore { activeOverride.withLock { $0 } ?? shared }
    static func withActiveStore<T>(_ store: DSThemeStore, _ body: () throws -> T) rethrows -> T {
        let previous = activeOverride.withLock { value -> DSThemeStore? in
            defer { value = store }
            return value
        }
        defer { activeOverride.withLock { $0 = previous } }
        return try LumenThemeStore.withActiveStore(store.lumen, body)
    }
}

enum DS {
    static func editorColor(_ token: LumenToken) -> Color { DSThemeStore.active.color(token, editorSurface: true) }
    static var theme: LumenTheme { DSThemeStore.active.theme }
}

extension View {
    /// Draws on the editor surface. `ownsEveryColor`: the editor theme also supplies the core roles
    /// (accent, status, code), so a listing's selection, program-counter, tag and patch tints follow
    /// the editor theme rather than the window theme.
    func dsEditorSurface(ownsEveryColor: Bool = false, themeStore: DSThemeStore = .active) -> some View {
        lumenSurface(.editor, ownsEveryColor: ownsEveryColor, store: themeStore.lumen)
    }
}


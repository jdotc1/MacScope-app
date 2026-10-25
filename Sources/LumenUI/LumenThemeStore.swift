import AppKit
import LumenTokens
import Observation
import OSLog
import SwiftUI

/// What an app tells its theme store about itself: a name for its preferences and themes
/// folder, and which theme to start from.
public struct LumenStoreConfiguration: Sendable, Hashable {
    /// Prefixes the user-defaults keys (`<appName>.lumen.*`) and names the default themes
    /// folder, `~/Library/Application Support/<appName>/Themes`.
    public var appName: String
    /// The user themes folder, when it isn't the default. Tests pass a temporary folder.
    public var themesDirectory: URL?
    /// The theme a new user starts with, and the one the store falls back to when a selected
    /// theme disappears. `nil` uses the registry's default theme.
    public var defaultThemeID: String?
    /// A user-defaults suite for the saved choices; `nil` is the app's standard defaults. Tests
    /// that exercise persistence use a unique suite and remove it afterwards.
    public var defaultsSuiteName: String?

    public init(appName: String, themesDirectory: URL? = nil, defaultThemeID: String? = nil, defaultsSuiteName: String? = nil) {
        self.appName = appName
        self.themesDirectory = themesDirectory
        self.defaultThemeID = defaultThemeID
        self.defaultsSuiteName = defaultsSuiteName
    }

    public var defaultsKeyPrefix: String { "\(appName).lumen" }

    /// `<appName>.lumen.theme` for the window; `<appName>.lumen.theme.<surface>` for the others.
    public func selectionDefaultsKey(for surface: LumenSurface) -> String {
        surface == .window ? "\(defaultsKeyPrefix).theme" : "\(defaultsKeyPrefix).theme.\(surface.rawValue)"
    }

    public var systemAccentDefaultsKey: String { "\(defaultsKeyPrefix).usesSystemAccent" }
    public var densityDefaultsKey: String { "\(defaultsKeyPrefix).density" }

    /// The folder user themes load from and save to.
    public var resolvedThemesDirectory: URL {
        themesDirectory ?? URL.applicationSupportDirectory.appending(path: "\(appName)/Themes", directoryHint: .isDirectory)
    }

    /// The defaults the saved choices live in.
    public var defaults: UserDefaults {
        defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}

/// The active themes, shared by every window of an app.
///
/// Reads go through Observation: any SwiftUI `body` that asks for a themed color records a
/// dependency on the selection, so switching themes re-renders exactly the views that use one.
/// No root `.id(...)` reset, no view state lost.
///
/// **Surfaces.** Every app has the window surface; a pack can add more, such as a code editor or
/// a document canvas. The user picks a theme per surface, and a surface without its own pick
/// follows the window. Each token resolves through the theme of the surface its spec names
/// (`registry.surface(of:)`), so an editor theme recolors exactly the roles the editor draws.
///
/// Storage sits behind a lock, so off-main callers (attributed-string builders, AppKit text
/// systems) can resolve colors safely.
@Observable
public final class LumenThemeStore: Sendable {
    /// Posted on the main actor after anything that changes resolved colors (selection, system
    /// accent, reload), for AppKit views that cache colors. The object is the store.
    public static let didChangeNotification = Notification.Name("Lumen.LumenThemeStore.didChange")

    struct State {
        var themes: [LumenTheme]
        /// The file each loaded user theme came from, and the files that failed to load.
        var userThemeFiles: [String: URL] = [:]
        var themeFileProblems: [LumenThemeFileProblem] = []
        var reservedIDs: Set<String> = []
        /// Counts reloads; part of the palette key so in-place edits invalidate cached palettes.
        var revision = 0
        /// The window always has an entry; a surface without one follows the window.
        var selections: [LumenSurface: String]
        /// Accent-family roles follow the macOS accent color instead of the theme.
        var usesSystemAccent = false
        var colorCache: [CacheKey: CachedColor] = [:]
        /// Tokens asked for that the registry doesn't know (an app token read through a store built
        /// on another registry); they draw the theme's last-resort color.
        var unknownTokens: Set<LumenToken> = []
        var palettes: [LumenPaletteKey: LumenResolvedPalette] = [:]

        func theme(for surface: LumenSurface, fallback: LumenTheme) -> LumenTheme {
            if surface != .window, let id = selections[surface], let theme = themes.first(where: { $0.id == id }) {
                return theme
            }
            return selections[.window].flatMap { id in themes.first { $0.id == id } } ?? fallback
        }
    }

    struct CacheKey: Hashable {
        var themeID: String
        var token: LumenToken
        var systemAccent: Bool
        /// The token as drawn on a raised ground (`LumenTheme.raisedColor`).
        var raised = false
    }

    /// Both forms are cached: building a SwiftUI `Color` from an `NSColor` on every call adds up
    /// in dense views.
    struct CachedColor {
        let ns: NSColor
        let color: Color
    }

    /// Every token, surface and built-in theme this store resolves against.
    @ObservationIgnored public let registry: LumenRegistry
    @ObservationIgnored public let configuration: LumenStoreConfiguration
    /// Whether choices are written to (and were read from) user defaults. A store that doesn't
    /// persist (tests, previews, snapshots) never reads the user's saved choices either.
    @ObservationIgnored public let persistsSelection: Bool
    /// The folder this store loads user themes from and saves them to.
    @ObservationIgnored public let themesDirectory: URL
    /// The theme a new user starts with and the store falls back to.
    @ObservationIgnored public let defaultThemeID: String
    /// The themes offered besides those in the folder: the registry's gallery themes, or the
    /// `themes` passed to `init`.
    @ObservationIgnored let baseThemes: [LumenTheme]
    @ObservationIgnored let fallbackTheme: LumenTheme
    /// Tokens drawn from the macOS accent while the store follows it (`LumenRegistry.systemAccentTokens`).
    @ObservationIgnored let systemAccentTokens: Set<LumenToken>
    /// Tokens whose color can differ on a raised ground (`LumenRegistry.raisedTokens`).
    @ObservationIgnored let raisedTokens: [LumenToken]
    @ObservationIgnored let state: LumenLock<State>
    @ObservationIgnored let identity = UUID()
    @ObservationIgnored let directoryWatch = LumenLock<LumenThemeDirectoryWatch?>(nil)
    /// Theme files as last seen by the folder watch, so unrelated folder changes don't reload.
    @ObservationIgnored let lastFolderFingerprint = LumenLock<[String]>([])
    /// Serializes saving choices to user defaults, so concurrent changes are saved in the order
    /// they were made. Recursive: a defaults-change observer may make another choice.
    @ObservationIgnored private let persistenceLock = NSRecursiveLock()

    static let log = Logger(subsystem: "Lumen", category: "Theme")

    /// - Parameters:
    ///   - registry: the app's packs (Lumen's core plus its own).
    ///   - configuration: the app's name, themes folder, default theme and defaults suite.
    ///   - themes: the themes to offer; defaults to the registry's gallery themes plus the user
    ///     theme files. When given, the folder is not read until `reloadUserThemes()`, which keeps
    ///     these and adds the folder's themes.
    ///   - persistsSelection: whether choices are saved to user defaults and restored from them.
    public init(registry: LumenRegistry, configuration: LumenStoreConfiguration, themes: [LumenTheme]? = nil,
                persistsSelection: Bool = true) {
        let directory = configuration.resolvedThemesDirectory
        let base = themes ?? registry.galleryThemes
        let library = themes == nil ? LumenThemeLibrary.load(from: directory, registry: registry) : nil
        let available = base + (library?.themes ?? []).filter { theme in !base.contains { $0.id == theme.id } }

        let preferred = configuration.defaultThemeID ?? registry.defaultThemeID
        let defaultID = available.contains { $0.id == preferred } ? preferred : (available.first?.id ?? preferred)
        let fallback = available.first { $0.id == defaultID } ?? registry.theme(id: registry.defaultThemeID) ?? LumenThemes.standard

        // A store that doesn't persist never reads the user's choice. A saved choice whose theme
        // doesn't load right now (a file mid-edit at launch) is kept, as a reload keeps it: it
        // draws the default theme until its file loads again.
        let defaults = persistsSelection ? configuration.defaults : nil
        var selections: [LumenSurface: String] = [.window: defaultID]
        for surface in registry.surfaces {
            if let saved = defaults?.string(forKey: configuration.selectionDefaultsKey(for: surface)) {
                selections[surface] = saved
            }
        }
        var initial = State(themes: available, selections: selections)
        initial.userThemeFiles = library?.files ?? [:]
        initial.themeFileProblems = library?.problems ?? []
        initial.reservedIDs = library?.reservedIDs ?? []
        initial.usesSystemAccent = defaults?.bool(forKey: configuration.systemAccentDefaultsKey) ?? false

        self.registry = registry
        self.configuration = configuration
        self.persistsSelection = persistsSelection
        self.themesDirectory = directory
        self.defaultThemeID = defaultID
        self.baseThemes = base
        self.fallbackTheme = fallback
        self.systemAccentTokens = Set(registry.systemAccentTokens)
        self.raisedTokens = registry.raisedTokens
        self.state = LumenLock(initial)
    }

    // MARK: Observed reads

    /// Identifies everything that decides resolved colors: each surface's theme, the accent
    /// mode, and the reload revision. Reading it records one Observation dependency; every
    /// color-changing mutation goes through it.
    public var paletteKey: LumenPaletteKey {
        access(keyPath: \.paletteKey)
        return state.withLock { paletteKey(in: $0) }
    }

    /// Every theme the user can choose: built-ins first, then user themes.
    public var themes: [LumenTheme] {
        access(keyPath: \.themes)
        return state.withLock { $0.themes }
    }

    /// The theme a surface draws with: its own pick, or the window's.
    public func theme(for surface: LumenSurface = .window) -> LumenTheme {
        access(keyPath: \.paletteKey)
        return state.withLock { $0.theme(for: surface, fallback: fallbackTheme) }
    }

    /// Whether `surface` follows the window theme. Always true for the window itself.
    public func surfaceFollowsWindow(_ surface: LumenSurface) -> Bool {
        access(keyPath: \.paletteKey)
        guard surface != .window else { return true }
        return state.withLock { state in
            state.selections[surface].map { id in !state.themes.contains { $0.id == id } } ?? true
        }
    }

    /// The appearance a surface's subtree must take so system text colors stay legible on its
    /// theme's grounds; `nil` when it can inherit. For the window, the window theme's forced
    /// appearance (an app applies it to its windows); for another surface, `nil` while it follows
    /// the window, else its theme's forced appearance.
    public func forcedAppearance(for surface: LumenSurface) -> ColorScheme? {
        guard surface == .window || !surfaceFollowsWindow(surface) else { return nil }
        return theme(for: surface).forcedColorScheme
    }

    /// Whether `surface`'s theme is a maximum-legibility one (Lumen's Contrast, or a theme that sets
    /// `highContrast`). Components with an Increase Contrast look (icon tiles' deep grounds) draw it
    /// when this or the system's Increase Contrast is on; `LumenResolvedPalette.isHighContrastTheme`
    /// is the same for the palette's surface.
    public func isHighContrastTheme(for surface: LumenSurface = .window) -> Bool {
        theme(for: surface).isHighContrast
    }

    /// Whether accent-family roles follow the macOS accent color (System Settings > Appearance).
    public var usesSystemAccent: Bool {
        access(keyPath: \.paletteKey)
        return state.withLock { $0.usesSystemAccent }
    }

    /// Theme files in `themesDirectory` that could not be loaded, with the reason.
    public var themeFileProblems: [LumenThemeFileProblem] {
        access(keyPath: \.themes)
        return state.withLock { $0.themeFileProblems }
    }

    /// The file a user theme was loaded from; `nil` for built-in themes.
    public func userThemeFile(for id: LumenTheme.ID) -> URL? {
        access(keyPath: \.themes)
        return state.withLock { $0.userThemeFiles[id] }
    }

    /// A SwiftUI color for `token`. It adapts to Light, Dark and Increase Contrast on its own,
    /// and records an Observation dependency on the selection.
    public func color(_ token: LumenToken) -> Color {
        cached(token).color
    }

    /// Tokens drawn through this store that its registry doesn't know, which fall back to a
    /// last-resort color. Checks report them: a view built on an app's tokens needs the app's
    /// registry, or it renders with colors it never meant.
    public var unknownTokens: Set<LumenToken> { state.withLock { $0.unknownTokens } }

    /// The AppKit color for `token`. Dynamic: it resolves against whatever appearance draws it.
    public func nsColor(_ token: LumenToken) -> NSColor {
        cached(token).ns
    }

    /// `token` as `surface`'s theme draws it, whichever surface owns the token: a window role such
    /// as `fg.primary` or `accent.subtle` on a code editor's rows, in the editor's theme.
    public func color(_ token: LumenToken, on surface: LumenSurface) -> Color {
        access(keyPath: \.paletteKey)
        return state.withLock { entry(token, in: &$0, on: surface).color }
    }

    /// The AppKit form of `color(_:on:)`.
    public func nsColor(_ token: LumenToken, on surface: LumenSurface) -> NSColor {
        access(keyPath: \.paletteKey)
        return state.withLock { entry(token, in: &$0, on: surface).ns }
    }

    /// `token` as this store draws it in `appearance`, as a plain value: the selected theme's color,
    /// or, while the store follows the macOS accent, the color derived from it. For components that
    /// compute with a color rather than only draw it (an icon tile picking black or white ink for
    /// its hue, a swatch's rim): reading `theme.color(_:for:in:)` directly misses the system accent.
    ///
    /// - Parameter surface: the surface whose theme to use; `nil` for the surface that owns `token`.
    public func resolvedColor(_ token: LumenToken, for appearance: LumenAppearance, on surface: LumenSurface? = nil) -> LumenColor {
        access(keyPath: \.paletteKey)
        let (theme, systemAccent) = state.withLock { state in
            (state.theme(for: surface ?? registry.surface(of: token), fallback: fallbackTheme),
             state.usesSystemAccent && systemAccentTokens.contains(token))
        }
        guard systemAccent, let accent = Self.systemAccent(in: appearance) else {
            return theme.color(token, for: appearance, in: registry)
        }
        return theme.color(token, for: appearance, in: registry, systemAccent: accent)
    }

    /// Cached per theme id, token and accent mode. A selection change needs no invalidation
    /// (it picks another theme id); a reload clears the cache because a theme may have changed
    /// in place under the same id.
    private func cached(_ token: LumenToken) -> CachedColor {
        access(keyPath: \.paletteKey)
        return state.withLock { entry(token, in: &$0) }
    }

    /// The cached color for `token` under the lock's current state, made on first use. With
    /// `surface`, the token resolves through that surface's theme rather than its owner's; with
    /// `raised`, as drawn on a raised ground (`LumenTheme.raisedColor`).
    func entry(_ token: LumenToken, in state: inout State, on surface: LumenSurface? = nil, raised: Bool = false) -> CachedColor {
        if registry.spec(for: token) == nil { state.unknownTokens.insert(token) }
        let theme = state.theme(for: surface ?? registry.surface(of: token), fallback: fallbackTheme)
        let systemAccent = state.usesSystemAccent && systemAccentTokens.contains(token)
        let key = CacheKey(themeID: theme.id, token: token, systemAccent: systemAccent, raised: raised && !systemAccent)
        if let cached = state.colorCache[key] { return cached }
        let registry = registry
        let ns: NSColor
        if systemAccent {
            ns = Self.systemAccentColor(token, theme: theme, registry: registry)
        } else if key.raised {
            ns = NSColor(name: "lumen.\(theme.id).\(token.rawValue).raised") { appearance in
                theme.raisedColor(token, for: LumenAppearance(appearance), in: registry).nsColor(in: theme.colorSpace)
            }
        } else {
            ns = NSColor(name: "lumen.\(theme.id).\(token.rawValue)") { appearance in
                theme.nsColor(token, for: LumenAppearance(appearance), in: registry)
            }
        }
        let entry = CachedColor(ns: ns, color: Color(nsColor: ns))
        state.colorCache[key] = entry
        return entry
    }

    /// The palette key for the lock's current state.
    func paletteKey(in state: State) -> LumenPaletteKey {
        LumenPaletteKey(store: identity,
                        themeIDs: Dictionary(uniqueKeysWithValues: registry.surfaces.map { ($0, state.theme(for: $0, fallback: fallbackTheme).id) }),
                        usesSystemAccent: state.usesSystemAccent, revision: state.revision)
    }

    /// The System Settings accent in `appearance` (system colors are dynamic), in sRGB; `nil` for
    /// Multicolor.
    static func systemAccent(in appearance: LumenAppearance) -> LumenColor? {
        guard let systemColor = LumenSystemAccent.current() else { return nil }
        let name: NSAppearance.Name = switch (appearance.isDark, appearance.isHighContrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        var accent: NSColor = .systemBlue
        (NSAppearance(named: name) ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            accent = systemColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return LumenColor(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
    }

    /// Accent roles derived from the System Settings accent, resolved at draw time so a change
    /// there shows up without restarting. The rules (`LumenTheme.color(_:for:in:systemAccent:)`)
    /// live in LumenTokens, where the validator checks them for every macOS accent: filled shapes
    /// are a deep tone under white text, tints are thinned until their text reads, the accent as a
    /// line or glyph is moved just far enough to meet its contrast. With Multicolor there is no
    /// user accent and the theme keeps its own.
    static func systemAccentColor(_ token: LumenToken, theme: LumenTheme, registry: LumenRegistry) -> NSColor {
        NSColor(name: "lumen.system-accent.\(theme.id).\(token.rawValue)") { appearance in
            let lumenAppearance = LumenAppearance(appearance)
            guard let accent = systemAccent(in: lumenAppearance) else {
                return theme.nsColor(token, for: lumenAppearance, in: registry)
            }
            let derived = theme.color(token, for: lumenAppearance, in: registry, systemAccent: accent)
            // Drawn in the theme's space, the space the derivation and the validator measure in.
            return derived.nsColor(in: theme.colorSpace)
        }
    }


    // MARK: Mutations

    /// Chooses the theme for `surface`. `nil` makes a non-window surface follow the window; the
    /// window always has a theme, so `nil` is ignored there, as are unknown ids and surfaces the
    /// registry doesn't declare.
    public func select(_ id: LumenTheme.ID?, for surface: LumenSurface = .window) {
        guard registry.surfaces.contains(surface) else { return }
        let changed = withMutation(keyPath: \.paletteKey) {
            state.withLock { state -> Bool in
                if let id {
                    guard state.themes.contains(where: { $0.id == id }) else { return false }
                } else if surface == .window {
                    return false
                }
                guard state.selections[surface] != id else { return false }
                state.selections[surface] = id
                return true
            }
        }
        guard changed else { return }
        persist({ $0.selections[surface] }) { id in
            let key = configuration.selectionDefaultsKey(for: surface)
            if let id {
                configuration.defaults.set(id, forKey: key)
            } else {
                configuration.defaults.removeObject(forKey: key)
            }
        }
        postDidChange()
    }

    public func setUsesSystemAccent(_ enabled: Bool) {
        let changed = withMutation(keyPath: \.paletteKey) {
            state.withLock { state -> Bool in
                guard state.usesSystemAccent != enabled else { return false }
                state.usesSystemAccent = enabled
                return true
            }
        }
        guard changed else { return }
        persist({ $0.usesSystemAccent }) { enabled in
            configuration.defaults.set(enabled, forKey: configuration.systemAccentDefaultsKey)
        }
        postDidChange()
    }

    /// Saves a choice from the state as it is now, not as one caller changed it: two threads choosing
    /// at once each save the latest choice, so what relaunch restores is what the store shows. The
    /// value is read under the state's lock but written outside it: user defaults may notify
    /// observers synchronously, and they may read the store.
    private func persist<Value>(_ read: (State) -> Value, _ write: (Value) -> Void) {
        guard persistsSelection else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        write(state.withLock { read($0) })
    }

    /// Re-reads user theme files. Selections are kept; one whose theme no longer loads draws the
    /// default theme until it does. Runs on its own
    /// when a file in the themes folder changes (see `watchThemesDirectory()`).
    public func reloadUserThemes() {
        let library = LumenThemeLibrary.load(from: themesDirectory, registry: registry)
        let base = baseThemes
        let reloaded = base + library.themes.filter { theme in !base.contains { $0.id == theme.id } }
        withMutation(keyPath: \.themes) {
            withMutation(keyPath: \.paletteKey) {
                state.withLock { state in
                    state.themes = reloaded
                    state.userThemeFiles = library.files
                    state.themeFileProblems = library.problems
                    state.reservedIDs = library.reservedIDs
                    state.revision += 1
                    state.colorCache.removeAll()
                    state.palettes.removeAll()
                    // Selections stay as they are: a theme missing for now (a file mid-edit that
                    // doesn't parse) draws the fallback and comes back when its file loads again.
                }
            }
        }
        // This reload has seen the folder as it is now; the watch needn't reload again for it.
        let fingerprint = LumenThemeLibrary.folderFingerprint(themesDirectory)
        lastFolderFingerprint.withLock { $0 = fingerprint }
        // The selected theme's colors may have changed in place; AppKit color caches must redraw.
        postDidChange()
    }

    /// The macOS accent color changed (System Settings › Appearance). Colors that follow it resolve
    /// at draw time, but SwiftUI keeps what it last drew; a new palette makes every reader redraw.
    public func systemColorsDidChange() {
        guard usesSystemAccent else { return }
        withMutation(keyPath: \.paletteKey) {
            state.withLock { state in
                state.revision += 1
                state.colorCache.removeAll()
                state.palettes.removeAll()
            }
        }
        postDidChange()
    }

    private func postDidChange() {
        Task { @MainActor [self] in
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

// MARK: Global access

extension LumenThemeStore {
    private static let installed = LumenLock<LumenThemeStore?>(nil)
    /// Task-local, so tests and previews running at once each see only their own store.
    @TaskLocal private static var activeOverride: LumenThemeStore?

    /// Used until an app installs its own store: Lumen's core registry and built-in themes. It
    /// never reads or writes user defaults or the disk, so previews and tests are safe with it.
    private static let fallback = LumenThemeStore(
        registry: .core, configuration: LumenStoreConfiguration(appName: "Lumen"),
        themes: LumenRegistry.core.galleryThemes, persistsSelection: false
    )

    /// The app's store: the one passed to `install(_:)`, or a core-only, non-persisting store
    /// before that.
    public static var shared: LumenThemeStore {
        installed.withLock { $0 } ?? fallback
    }

    /// Makes `store` the app's shared store. Call it once at launch, before any view reads a
    /// color (for example in the `App` initializer):
    ///
    /// ```swift
    /// LumenThemeStore.install(LumenThemeStore(registry: AppTheme.registry,
    ///                                         configuration: .init(appName: "MyApp")))
    /// ```
    ///
    /// `Lumen.color(_:)`, `.lumen(_:)` and the default palette read it from then on. With
    /// `watchesThemesFolder`, edits in the themes folder reload on their own.
    public static func install(_ store: LumenThemeStore, watchesThemesFolder: Bool = true) {
        installed.withLock { $0 = store }
        if watchesThemesFolder { store.watchThemesDirectory() }
        // Follow accent color changes in System Settings while the app runs.
        accentObserver.withLock { observer in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                                              queue: .main) { _ in LumenThemeStore.shared.systemColorsDidChange() }
        }
    }

    private static let accentObserver = LumenLock<(any NSObjectProtocol)?>(nil)

    /// The store `Lumen` reads: `shared`, unless a test, preview or snapshot has installed a
    /// scoped override with `withActiveStore(_:_:)`.
    public static var active: LumenThemeStore {
        activeOverride ?? shared
    }

    /// Runs `body` with `store` as the active store, then restores the previous one. Tests and
    /// previews use this to render any theme without changing (or persisting) the user's
    /// selection on `shared`.
    public static func withActiveStore<T>(_ store: LumenThemeStore, _ body: () throws -> T) rethrows -> T {
        try $activeOverride.withValue(store) { try body() }
    }
}

/// The Lumen namespace: colors from the active store, and the fixed scales (see `LumenMetrics`
/// for the per-app ones components use).
public enum Lumen {
    /// A themed SwiftUI color from the active store. Fine for chrome; dense views should read
    /// `@Environment(\.lumenPalette)` instead.
    public static func color(_ token: LumenToken) -> Color { LumenThemeStore.active.color(token) }
    /// A themed, dynamic AppKit color from the active store.
    public static func nsColor(_ token: LumenToken) -> NSColor { LumenThemeStore.active.nsColor(token) }
    /// The theme a surface draws with in the active store.
    public static func theme(for surface: LumenSurface = .window) -> LumenTheme { LumenThemeStore.active.theme(for: surface) }
}

public extension ShapeStyle where Self == Color {
    /// A themed color: `.foregroundStyle(.lumen(.fgSecondary))`, `.background(.lumen(.bgCanvas))`.
    static func lumen(_ token: LumenToken) -> Color { Lumen.color(token) }
}

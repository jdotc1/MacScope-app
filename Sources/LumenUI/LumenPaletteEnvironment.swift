import AppKit
import LumenTokens
import SwiftUI

/// Every registered token, resolved once for the current selection of each surface's theme and
/// the accent mode.
///
/// `Lumen.color(_:)` is fine for chrome, but each call takes the store's lock and records an
/// Observation dependency. Dense views (table rows, cells, graph nodes) should read colors from
/// this value instead: inject it once near the root with `.lumenPaletteRoot()` and read
/// `@Environment(\.lumenPalette)` in rows. A lookup is a dictionary read. The colors stay
/// dynamic, so Light, Dark and Increase Contrast still resolve at draw time, and the value
/// changes (and re-renders its readers) only when the selection changes or themes reload.
public struct LumenResolvedPalette: Sendable, Equatable {
    /// The selection this palette was built for; equality compares only this, so the
    /// environment diff stays cheap.
    public let key: LumenPaletteKey
    private let colors: [LumenToken: Color]
    /// The tokens that change on a raised ground, as drawn there (`LumenTheme.raisedColor`).
    private let raisedColors: [LumenToken: Color]
    /// Whether the palette's theme is a maximum-legibility one (Lumen's Contrast, or a theme file
    /// with `highContrast`): components with an Increase Contrast look draw it when this or the
    /// system's Increase Contrast (`colorSchemeContrast == .increased`) is on.
    public let isHighContrastTheme: Bool
    /// Tells the store a token its registry doesn't know was read, so checks report it as they do
    /// for `LumenThemeStore.color(_:)`.
    private let reportUnknown: (@Sendable (LumenToken) -> Void)?

    /// The color for `token`; `.primary` for a token the registry doesn't know, which the store
    /// records in `unknownTokens`.
    public subscript(token: LumenToken) -> Color {
        if let color = colors[token] { return color }
        reportUnknown?(token)
        return .primary
    }

    /// The fill of a selected sidebar row in an inactive window: `sidebar.rowSelectedInactive`,
    /// which falls back to the quiet `bg.selectedInactive` and is validated against the sidebar's
    /// own text.
    public var sidebarSelectedInactive: Color { self[.sidebarRowSelectedInactive] }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    init(key: LumenPaletteKey, colors: [LumenToken: Color], raisedColors: [LumenToken: Color] = [:],
         isHighContrastTheme: Bool = false,
         reportUnknown: (@Sendable (LumenToken) -> Void)? = nil) {
        self.key = key
        self.colors = colors
        self.raisedColors = raisedColors
        self.isHighContrastTheme = isHighContrastTheme
        self.reportUnknown = reportUnknown
    }

    /// The palette for content on a card, popover, sheet or menu: wells take `bg.insetRaised`,
    /// hover `bg.hoverRaised` and the inactive selection `bg.selectedInactiveRaised`, so in dark
    /// each stays a step lighter than what holds it. Tokens that only follow one of those (a keycap
    /// that falls back to `bg.inset`, a sidebar hover) swap with it; tokens a theme sets itself keep
    /// their value. Decided from the registry and theme when the palette is built, never by
    /// comparing colors.
    public func raised() -> LumenResolvedPalette {
        guard !key.raised else { return self }
        var colors = colors
        colors.merge(raisedColors) { _, raised in raised }
        var key = key
        key.raised = true
        return LumenResolvedPalette(key: key, colors: colors, raisedColors: raisedColors,
                                    isHighContrastTheme: isHighContrastTheme,
                                    reportUnknown: reportUnknown)
    }
}

/// Identifies a store's color-deciding state. See `LumenThemeStore.paletteKey`.
public struct LumenPaletteKey: Hashable, Sendable {
    /// The store it came from: two stores never share a palette.
    var store: UUID
    /// The theme each registered surface draws with.
    public var themeIDs: [LumenSurface: String]
    public var usesSystemAccent: Bool
    /// Bumped when user themes reload, so a theme edited in place (same id) gets a new palette.
    public var revision: Int
    /// The surface every token resolves through, for `resolvedPalette(on:)`; `nil` routes each token
    /// to the surface that owns it.
    public var drawnOn: LumenSurface?
    /// Built for content on a raised ground (`LumenResolvedPalette.raised()`).
    public var raised = false
}

extension LumenThemeStore {
    /// The resolved palette for the current selection, built at most once per selection. Reading
    /// it records one Observation dependency on the selection.
    public func resolvedPalette() -> LumenResolvedPalette { resolvedPalette(drawnOn: nil) }

    /// Every token as `surface`'s theme draws it, window roles included: for content drawn entirely
    /// on that surface, such as a code editor's rows, whose text and selection follow the editor's
    /// theme. While the surface follows the window, it's the window's palette.
    public func resolvedPalette(on surface: LumenSurface) -> LumenResolvedPalette { resolvedPalette(drawnOn: surface) }

    private func resolvedPalette(drawnOn surface: LumenSurface?) -> LumenResolvedPalette {
        access(keyPath: \.paletteKey)
        // One lock for the key and every color, so a selection changing on another thread can't
        // file one theme's colors under another's key.
        return state.withLock { state in
            var key = paletteKey(in: state)
            key.drawnOn = surface
            if let cached = state.palettes[key] { return cached }
            var colors: [LumenToken: Color] = [:]
            for token in registry.tokens where colors[token] == nil {
                colors[token] = entry(token, in: &state, on: surface).color
            }
            var raisedColors: [LumenToken: Color] = [:]
            for token in raisedTokens {
                raisedColors[token] = entry(token, in: &state, on: surface, raised: true).color
            }
            let theme = state.theme(for: surface ?? .window, fallback: fallbackTheme)
            // Weak: the store caches this palette.
            let palette = LumenResolvedPalette(key: key, colors: colors, raisedColors: raisedColors,
                                               isHighContrastTheme: theme.isHighContrast) { [weak self] token in
                self?.state.withLock { _ = $0.unknownTokens.insert(token) }
            }
            if state.palettes.count > 32 { state.palettes.removeAll() }   // user themes come and go; stay small
            state.palettes[key] = palette
            return palette
        }
    }
}

extension Lumen {
    /// The resolved palette for the active store. Prefer `@Environment(\.lumenPalette)` in views.
    public static var palette: LumenResolvedPalette { LumenThemeStore.active.resolvedPalette() }
}

extension EnvironmentValues {
    /// The resolved theme palette. Set by `.lumenPaletteRoot()`; outside it, the active store's.
    @Entry public var lumenPalette: LumenResolvedPalette = LumenThemeStore.active.resolvedPalette()
    /// The store behind `lumenPalette`, for components that resolve more than palette colors (icon
    /// tiles, swatches). Set by `.lumenPaletteRoot()` and `.lumenSurface(_:)`.
    @Entry public var lumenStore: LumenThemeStore = LumenThemeStore.active
}

extension View {
    /// Injects the resolved palette for this subtree, tints native controls with the theme's
    /// accent, gives the subtree the window theme's forced appearance (Midnight and Ultraviolet are
    /// always dark), so system text and controls stay legible, and paints the native title bar with
    /// the theme's glow while the window is active (`.lumenWindowChrome()`). Apply once per window.
    ///
    /// - Parameter windowChrome: `false` keeps the system's plain title bar (a window that draws its
    ///   own top bar with `LumenTopBar` already carries the glow).
    public func lumenPaletteRoot(store: LumenThemeStore = .active, windowChrome: Bool) -> some View {
        modifier(LumenPaletteRootModifier(store: store, windowChrome: windowChrome))
    }

    /// `lumenPaletteRoot(store:windowChrome:)` with the title bar glow.
    public func lumenPaletteRoot(store: LumenThemeStore = .active) -> some View {
        modifier(LumenPaletteRootModifier(store: store, windowChrome: true))
    }

    /// Marks a subtree drawn on a raised ground (a card, popover, sheet or menu): its wells take
    /// `bg.insetRaised`, so in dark they stay lighter than the ground (PRINCIPLES §8). Lumen's own
    /// cards apply it; apply it to a custom one.
    public func lumenRaisedGround() -> some View {
        modifier(LumenRaisedGroundModifier())
    }

    /// Marks a subtree drawn by `surface` (a code editor, a document canvas). It takes that
    /// surface's forced appearance, so system text and controls stay legible on its theme's
    /// grounds, and gets the store's palette (which already routes each token to the theme of the
    /// surface that owns it).
    ///
    /// Only the environment varies, never the subtree's identity: changing a theme preserves
    /// selection, scroll position and any other view-local state.
    ///
    /// With `ownsEveryColor`, window roles in the subtree (`fg.primary`, `accent.subtle`…) also come
    /// from the surface's theme: for content drawn entirely on the surface, such as editor rows.
    ///
    /// - Parameter store: the store to resolve through; `nil` (the default) keeps the one
    ///   `.lumenPaletteRoot(store:)` injected above, or the active store outside a root.
    public func lumenSurface(_ surface: LumenSurface, ownsEveryColor: Bool = false, store: LumenThemeStore? = nil) -> some View {
        modifier(LumenSurfaceModifier(surface: surface, ownsEveryColor: ownsEveryColor, explicitStore: store))
    }
}

private struct LumenPaletteRootModifier: ViewModifier {
    let store: LumenThemeStore
    let windowChrome: Bool
    @Environment(\.colorScheme) private var inheritedColorScheme

    func body(content: Content) -> some View {
        let palette = store.resolvedPalette()
        // Native controls stay native but take the theme's accent: list selection, checkboxes,
        // segmented controls, buttons, progress.
        // The glow reads the palette injected below, so it sits inside the environment modifiers.
        Group {
            if windowChrome { content.lumenWindowChrome() } else { content }
        }
        .environment(\.colorScheme, store.forcedAppearance(for: .window) ?? inheritedColorScheme)
        .environment(\.lumenPalette, palette)
        .environment(\.lumenStore, store)
        .tint(palette[.accent])
    }
}

private struct LumenRaisedGroundModifier: ViewModifier {
    @Environment(\.lumenPalette) private var palette

    func body(content: Content) -> some View {
        content.environment(\.lumenPalette, palette.raised())
    }
}

private struct LumenSurfaceModifier: ViewModifier {
    let surface: LumenSurface
    let ownsEveryColor: Bool
    let explicitStore: LumenThemeStore?
    @Environment(\.colorScheme) private var inheritedColorScheme

    @Environment(\.lumenPalette) private var incoming
    @Environment(\.lumenStore) private var inheritedStore

    func body(content: Content) -> some View {
        let store = explicitStore ?? inheritedStore
        let palette = ownsEveryColor ? store.resolvedPalette(on: surface) : store.resolvedPalette()
        content
            .environment(\.colorScheme, store.forcedAppearance(for: surface) ?? inheritedColorScheme)
            // A code pane inside a sheet or card keeps the raised ground it sits on.
            .environment(\.lumenPalette, incoming.key.raised ? palette.raised() : palette)
            .environment(\.lumenStore, store)
    }
}

extension LumenResolvedPalette {
    /// The quiet ground for a chip or capsule in `tone`: a status color's own background token
    /// (amber for warnings, not the warning color washed into tan), otherwise the color at 15%.
    func toneBackground(_ tone: LumenToken) -> Color {
        switch tone {
        case .statusWarning: self[.statusWarningBackground]
        case .statusSuccess: self[.statusSuccessBackground]
        case .statusDanger: self[.statusDangerBackground]
        case .statusInfo: self[.statusInfoBackground]
        case .statusNeutral, .fgTertiary, .fgSecondary: self[.statusNeutralBackground]
        case .accent: self[.accentSubtle]
        default: self[tone].opacity(0.15)
        }
    }
}

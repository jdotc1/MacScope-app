import AppKit
import SwiftUI
import LumenTokens
import os

/// A System Settings-style icon tile: a symbol on a rounded square, drawn the way macOS 26–27 draws
/// its own system tiles:
///
/// - Light: the hue as the tile, a gentle top-to-bottom gradient, a white symbol.
/// - Dark: a slate tile with the symbol in its hue, as System Settings does in dark mode.
/// - Depth comes from material only: each shape's gentle gradient and a soft hairline rim, lighter
///   at the top. No shadows, sheens or dark edges.
/// - The symbol is an SF Symbol, sized like Apple's (its box is 64% of the tile) and drawn by the
///   system, so it's sharp at every size. A Lumen glyph name (`lumen.disassembly`) uses its SF
///   Symbol equivalent where one exists, and the Lumen glyph otherwise.
///
/// Symbols keep 3:1 against their tile in every hue, theme and appearance. Hues are tokens, so
/// themes recolor tiles like everything else.
public struct LumenIconTile: View {
    public let systemImage: String
    public let hue: LumenToken
    public let size: CGFloat
    private let label: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenStore) private var store
    @Environment(\.lumenIconRole) private var role
    @Environment(\.lumenTileBacklight) private var backlit
    @Environment(\.lumenTileHueGround) private var hueGround
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenToolbarCompact) private var toolbarCompact

    /// The symbol's box as a share of the tile, measured from System Settings' icons.
    static let symbolShare: CGFloat = 0.64
    /// The backlight's strength in dark mode (light mode uses about half): very subtle.
    static let backlightStrength = 0.18
    /// How far past the tile's edge the backlight reaches, as a share of the tile (0.1 = 2.8 pt on a
    /// 28 pt tile): inside the 3–4 pt a tile strip leaves around its tiles.
    static let backlightReach: CGFloat = 0.1

    /// What a tile draws for an app with no icon of its own, and for a name with no symbol.
    static let placeholderSymbol = "square.grid.2x2"

    /// The name a tile draws: `name`, except that the bare rounded-square app symbols ("app",
    /// "app.fill", "app.dashed") read as an empty tile inside the tile, and an unknown SF Symbol
    /// draws nothing, so both draw `placeholderSymbol`.
    static func tileSymbol(for name: String) -> String {
        if ["app", "app.fill", "app.dashed"].contains(name) { return placeholderSymbol }
        if name.hasPrefix("lumen.") { return name }
        // Looked up once per name: tiles redraw in every row of a list.
        if let known = knownSymbols.withLock({ $0[name] }) { return known ? name : placeholderSymbol }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        knownSymbols.withLock { $0[name] = exists }
        return exists ? name : placeholderSymbol
    }

    private static let knownSymbols = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// - Parameters:
    ///   - size: the tile's side in points. Use the role's metric (PRINCIPLES §7): `tileHeader` (28)
    ///     for a pane header, `tileInspectorHeader` (32) for the inspector's, `tileTool` (28) for a tile
    ///     that is a whole control, `tileSection` (28) for section headers, `tileMode` (22) for a mode
    ///     switcher beside its label. Tiles beside text use `tileCompact` (16, never smaller),
    ///     `tileMenu` (18) in one-line menus and rows, `tileRow` (20) in sidebars and `tileRowDetailed`
    ///     (26) in two-line rows; `tileProminent` (32), `tilePaneHeader` (40), `tileHeroCompact` (56),
    ///     `tileHero` (64) and `tileWelcome` (72) carry the larger roles.
    ///   - label: the accessibility label; `nil` hides the tile from VoiceOver (decorative).
    public init(_ systemImage: String, hue: LumenToken, size: CGFloat = 20, label: String? = nil) {
        self.systemImage = systemImage
        self.hue = hue
        self.size = size
        self.label = label
    }

    public var body: some View {
        let colors = LumenTileColors(hue: hue, appearance: LumenAppearance(isDark: colorScheme == .dark,
                                                                          isHighContrast: LumenTileContrast.isHigh(contrast, store: store)),
                                     store: store, hueGround: hueGround)
        let _ = palette   // re-render when the palette (theme selection) changes
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image = LumenGlyph.symbolImage(for: Self.tileSymbol(for: systemImage), filled: true) {
                image
                    .resizable()
                    .scaledToFit()
                    .font(.system(size: size, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .symbolVariant(.fill)   // filled on a colored tile, as Apple pairs them
                    .frame(width: size * Self.symbolShare, height: size * Self.symbolShare)
            } else if let glyph = LumenGlyph.named(systemImage) {
                LumenGlyphView(glyph, size: size * Self.symbolShare, weight: size <= 28 ? .bold : .regular)
                    .environment(\.lumenGlyphTint, colors.tint)
            }
        }
        .foregroundStyle(LinearGradient(colors: [colors.glyphTop, colors.glyph], startPoint: .top, endPoint: .bottom))
        .frame(width: size, height: size)
        .background(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom), in: shape)
        .background {
            if backlit && !toolbarCompact {
                // The backlight: the tile's hue falling softly on the surface just below it. Contained
                //: a radial falloff with no blur, so it ends at a known edge,
                // `backlightReach` of the tile below and beside it, inside the strip's padding and
                // never across the hairline under the strip. Off in the toolbar, whose item bounds
                // could only clip it.
                Rectangle()
                    .fill(EllipticalGradient(colors: [palette[hue].opacity(colorScheme == .dark ? Self.backlightStrength : Self.backlightStrength * 0.55),
                                                      palette[hue].opacity(0)],
                                             center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    // An ellipse centred just above the tile's bottom edge, fading to nothing at
                    // `backlightReach` below it and beside it.
                    .frame(width: size * (1 + 2 * Self.backlightReach), height: size * Self.backlightReach * 3)
                    // No blur: the ellipse's own frame is its extent, `backlightReach` past the tile.
                    .lumenBacklightExtent(blur: 0)
                    .offset(y: size * (0.5 - Self.backlightReach * 0.5))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // The soft rim: a hairline that catches light along the top and fades down the sides.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(LumenTileColors.rimTop), .white.opacity(LumenTileColors.rimTop * 0.25),
                                                       .white.opacity(LumenTileColors.rimTop * 0.12)],
                                              startPoint: .topLeading, endPoint: .bottom),
                               lineWidth: max(0.5, size / 56))
        }
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
        .preference(key: LumenIconScaleKey.self, value: size + 0.5 < role.minimumSize(in: metrics.layout)
                    ? ["\(systemImage) tile is \(Int(size)) pt; \(role == .control ? " control" : role == .section ? " section" : "n inline") tile needs \(Int(role.minimumSize(in: metrics.layout))) pt"] : [])
    }
}

/// Whether tiles draw their Increase Contrast look: the system setting, or the active theme being
/// Lumen's Contrast theme (`colorSchemeContrast` is read-only in SwiftUI, so a theme or a
/// snapshot can't set it). Internal until the theme store exposes its own high-contrast flag;
/// then this reads that.
enum LumenTileContrast {
    @MainActor
    static func isHigh(_ system: ColorSchemeContrast, store: LumenThemeStore) -> Bool {
        system == .increased || store.theme(for: .window).id == LumenThemes.contrastID
    }
}

/// The tile's resolved colors for one appearance.
struct LumenTileColors {
    let top: Color
    let bottom: Color
    let glyph: Color
    /// The symbol's lighter top, for its gentle gradient.
    let glyphTop: Color
    /// A Lumen glyph's tint layer inside the tile (glyphs of 24 pt and up): it deepens the ground
    /// under the marks so they keep their contrast.
    let tint: Color
    /// The resolved values, for checks. `baseValue` is the tile's lighter end, the harder case.
    let baseValue: LumenColor
    let glyphValue: LumenColor
    let tintGroundValue: LumenColor

    static let darkTintAlpha = 0.22
    static let lightTintAlpha = 0.35
    static let rimTop = 0.35
    /// The symbol's contrast on a dark tile under Increase Contrast.
    static let highContrastGlyphRatio = 4.5

    /// - Parameter hueGround: the hue as the ground in dark mode too (color swatches), rather than
    ///   the slate tile.
    init(hue: LumenToken, appearance: LumenAppearance, store: LumenThemeStore, hueGround: Bool = false) {
        let theme = store.theme(for: store.registry.surface(of: hue))
        let base = store.resolvedColor(hue, for: appearance)   // through the store: follows the system accent
        let space = theme.colorSpace
        let white = LumenColor(red: 1, green: 1, blue: 1), black = LumenColor(red: 0, green: 0, blue: 0)
        func color(_ c: LumenColor) -> Color { Color(nsColor: c.nsColor(in: space)) }
        if appearance.isDark && !hueGround {
            // System Settings' dark tiles: slate, the symbol in its hue, lifted until it reads at 3:1.
            let groundTop = appearance.isHighContrast ? LumenColor(red: 0.14, green: 0.15, blue: 0.18) : LumenColor(red: 0.25, green: 0.27, blue: 0.32)
            let groundBottom = appearance.isHighContrast ? LumenColor(red: 0.07, green: 0.07, blue: 0.09) : LumenColor(red: 0.15, green: 0.16, blue: 0.20)
            var ink = base
            var lift = 0.0
            while ink.contrastRatio(against: groundTop) < 3, lift < 0.9 { lift += 0.05; ink = white.composited(alpha: lift, over: base) }
            if appearance.isHighContrast {
                // Increase Contrast darkens the ground; the symbol lifts to 4.5:1 and never ends up
                // dimmer than on the standard dark tile.
                let standard = LumenTileColors(hue: hue, appearance: LumenAppearance(isDark: true, isHighContrast: false), store: store)
                while ink.contrastRatio(against: groundTop) < Self.highContrastGlyphRatio
                        || ink.relativeLuminance < standard.glyphValue.relativeLuminance, lift < 1 {
                    lift = min(1, lift + 0.05); ink = white.composited(alpha: lift, over: base)
                }
            }
            top = color(groundTop); bottom = color(groundBottom)
            glyph = color(ink); glyphTop = color(white.composited(alpha: 0.15, over: ink))
            let tintGround = black.composited(alpha: Self.darkTintAlpha, over: groundTop)
            tint = .black.opacity(Self.darkTintAlpha)
            baseValue = groundTop; glyphValue = ink; tintGroundValue = tintGround
        } else {
            // White, as on System Settings' tiles, whenever it reaches 3:1 on the hue; a near-black
            // symbol only for light hues such as yellow.
            let ink = Self.ink(on: base)
            let whiteGlyph = ink == white
            // The gradient's lighter top: up to 18% white, only as far as a white symbol keeps 3:1.
            let lift = whiteGlyph
                ? stride(from: 0.18, through: 0, by: -0.02).first { white.composited(alpha: $0, over: base).contrastRatio(against: ink) >= 3 } ?? 0
                : 0.18
            let lighter = white.composited(alpha: lift, over: base)
            top = color(lighter); bottom = color(base)
            glyph = whiteGlyph ? .white : Color(white: 0.08)
            glyphTop = whiteGlyph ? .white : Color(white: 0.16)
            tint = whiteGlyph ? .black.opacity(Self.darkTintAlpha) : .white.opacity(Self.lightTintAlpha)
            baseValue = lighter
            glyphValue = ink
            tintGroundValue = whiteGlyph ? black.composited(alpha: Self.darkTintAlpha, over: lighter)
                                         : white.composited(alpha: Self.lightTintAlpha, over: lighter)
        }
    }
}

extension LumenTileColors {
    static let nearBlack = LumenColor(red: 0.08, green: 0.08, blue: 0.08)

    /// Ink for a letter or symbol drawn flat on `base` (avatars, completion kinds): white whenever
    /// it reaches 3:1, as on System Settings' tiles; near-black when it doesn't and black reads better.
    static func ink(on base: LumenColor) -> LumenColor {
        let white = LumenColor(red: 1, green: 1, blue: 1), black = LumenColor(red: 0, green: 0, blue: 0)
        let whiteRatio = base.contrastRatio(against: white)
        return whiteRatio >= 3 || whiteRatio >= base.contrastRatio(against: black) ? white : nearBlack
    }

    /// The minimum contrast for text on a colored ground (pills, capsules): WCAG AA for small text.
    static let textContrast = 4.5

    /// Ink for text drawn flat on `base` (a filled capsule): white when it reaches 4.5:1, otherwise
    /// whichever of white and black reads better (black, not near-black: an orange that gives
    /// near-black 4.4:1 gives black 5:1).
    static func textInk(on base: LumenColor) -> LumenColor {
        let white = LumenColor(red: 1, green: 1, blue: 1), black = LumenColor(red: 0, green: 0, blue: 0)
        let whiteRatio = base.contrastRatio(against: white)
        return whiteRatio >= textContrast || whiteRatio >= base.contrastRatio(against: black) ? white : black
    }

    /// `token` as text on a tinted pill: a fill of `token` at `fillAlpha` over `ground`. The color is
    /// pushed toward white (dark) or black (light) until it reads at 4.5:1 on that fill.
    static func pillText(_ token: LumenToken, fillAlpha: Double, over ground: LumenToken, appearance: LumenAppearance,
                         store: LumenThemeStore) -> (ink: LumenColor, fill: LumenColor) {
        let base = store.resolvedColor(token, for: appearance)
        let fill = base.composited(alpha: fillAlpha, over: store.resolvedColor(ground, for: appearance))
        let toward = appearance.isDark ? LumenColor(red: 1, green: 1, blue: 1) : LumenColor(red: 0, green: 0, blue: 0)
        var ink = base
        var amount = 0.0
        while ink.contrastRatio(against: fill) < textContrast, amount < 1 {
            amount = min(1, amount + 0.05)
            ink = toward.composited(alpha: amount, over: base)
        }
        return (ink, fill)
    }

    /// `hue` resolved as a flat ground, and the ink that reads on it.
    static func flat(_ hue: LumenToken, appearance: LumenAppearance, store: LumenThemeStore) -> (ground: LumenColor, ink: LumenColor) {
        let base = store.resolvedColor(hue, for: appearance)   // through the store: follows the system accent
        return (base, ink(on: base))
    }

    /// The ink for a letter drawn on `palette[hue]`, as a SwiftUI color.
    static func inkColor(on hue: LumenToken, appearance: LumenAppearance, store: LumenThemeStore) -> Color {
        let theme = store.theme(for: store.registry.surface(of: hue))
        return Color(nsColor: flat(hue, appearance: appearance, store: store).ink.nsColor(in: theme.colorSpace))
    }
}

/// A menu label with a Lumen icon tile, for native menus (`Menu`, `.contextMenu`, `CommandMenu`).
///
/// Native menus keep their structure: highlighting, keyboard navigation, submenus, shortcuts and
/// accessibility all stay the system's. Lumen adds only the colored tile, rendered as a
/// non-template image so the menu shows its color.
public struct LumenMenuLabel: View {
    public let title: String
    public let systemImage: String
    public let hue: LumenToken

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    public init(_ title: String, systemImage: String, hue: LumenToken) {
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
    }

    public var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = LumenIconTile.image(systemImage, hue: hue, size: 16, colorScheme: colorScheme, scale: max(displayScale, 2)) {
                Image(nsImage: image)
            } else {
                LumenSymbol(systemImage)
            }
        }
    }
}

public extension LumenIconTile {
    /// The tile rendered as an `NSImage` (not a template), for places that take images: native
    /// menu items, settings tab icons, the Dock tile.
    @MainActor
    static func image(_ systemImage: String, hue: LumenToken, size: CGFloat, colorScheme: ColorScheme,
                      scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: LumenIconTile(systemImage, hue: hue, size: size)
            .environment(\.colorScheme, colorScheme)
            .padding(0.5))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size + 1, height: size + 1))
        image.isTemplate = false
        return image
    }
}

import AppKit
import LumenTokens
import SwiftUI

// Bridges from LumenTokens' plain values to AppKit and SwiftUI.

public extension LumenColor {
    /// The color as AppKit draws it. A Display P3 theme writes its hex values as P3 components,
    /// so the same digits mean a wider color there than in sRGB.
    func nsColor(in space: LumenColorSpace) -> NSColor {
        switch space {
        case .sRGB: NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case .displayP3: NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// The components of `color` in `space`, or `nil` when it can't be converted (pattern
    /// colors, for example). The theme editor stores picked colors this way.
    init?(_ color: NSColor, in space: LumenColorSpace) {
        guard let converted = color.usingColorSpace(space == .displayP3 ? .displayP3 : .sRGB) else { return nil }
        self.init(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent,
                  alpha: converted.alphaComponent)
    }
}

public extension LumenAppearance {
    /// The variant AppKit is drawing: Light or Dark, with or without Increase Contrast.
    init(_ appearance: NSAppearance) {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        self.init(isDark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                  isHighContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua)
    }

    /// The SwiftUI color scheme for this appearance.
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

public extension LumenTheme {
    /// The appearance this theme imposes, or `nil` when it has both variants and follows the
    /// user's Light/Dark/Automatic choice.
    var forcedColorScheme: ColorScheme? {
        forcedAppearanceIsDark.map { $0 ? .dark : .light }
    }

    /// A static AppKit color for `token` in one appearance, in the theme's own color space.
    func nsColor(_ token: LumenToken, for appearance: LumenAppearance, in registry: LumenRegistry) -> NSColor {
        color(token, for: appearance, in: registry).nsColor(in: colorSpace)
    }
}

/// The accent color chosen in System Settings > Appearance, read from the global
/// `AppleAccentColor` preference.
///
/// An app that ships its own global AccentColor asset can't use `NSColor.controlAccentColor` for
/// this: the asset overrides it inside the app, so it reports the brand color, not the user's.
/// Reading the preference works whether or not the app has such an asset.
///
/// Mapping from general knowledge of macOS (not an Apple-documented contract): -1 graphite,
/// 0 red, 1 orange, 2 yellow, 3 green, 4 blue, 5 purple, 6 pink; an absent key is Multicolor.
public enum LumenSystemAccent {
    public static func color(forAppleAccentColor value: Int?) -> NSColor? {
        switch value {
        case nil: nil
        case -1: .systemGray
        case 0: .systemRed
        case 1: .systemOrange
        case 2: .systemYellow
        case 3: .systemGreen
        case 4: .systemBlue
        case 5: .systemPurple
        case 6: .systemPink
        default: .systemBlue
        }
    }

    /// The user's accent, or `nil` for Multicolor (the theme then keeps its own accent).
    public static func current(defaults: UserDefaults = .standard) -> NSColor? {
        color(forAppleAccentColor: defaults.object(forKey: "AppleAccentColor") as? Int)
    }

    /// Black or white, whichever reads better on `accent` (sRGB components).
    public static func textColor(on accent: LumenColor) -> LumenColor {
        accent.contrastRatio(against: "#FFFFFF") >= accent.contrastRatio(against: "#000000") ? "#FFFFFF" : "#000000"
    }
}

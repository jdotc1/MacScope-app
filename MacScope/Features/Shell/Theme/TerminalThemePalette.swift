import AppKit
import LumenTokens
import LumenUI

/// The terminal's colors for the current theme and appearance: default foreground, background
/// and cursor plus the 16 ANSI colors, resolved through the theme store (so the editor theme,
/// Increase Contrast and the system accent all apply), then expanded into the standard
/// 256-color table. Programs can still override any entry with OSC escape codes.
struct TerminalThemePalette: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    var foreground: RGB
    var background: RGB
    var cursor: RGB
    /// ANSI colors 0–15.
    var ansi: [RGB]

    init(foreground: RGB, background: RGB, cursor: RGB, ansi: [RGB]) {
        precondition(ansi.count == 16, "A terminal palette has exactly 16 ANSI colors")
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
    }

    init(store: DSThemeStore = .active, appearance: LumenAppearance) {
        let name: NSAppearance.Name = switch (appearance.isDark, appearance.isHighContrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        let drawing = NSAppearance(named: name) ?? NSAppearance(named: .aqua)!
        var resolved: [LumenToken: RGB] = [:]
        drawing.performAsCurrentDrawingAppearance {
            for token in [.terminalForeground, .terminalBackground, .terminalCursor] + LumenToken.terminalANSI {
                resolved[token] = Self.rgb(store.nsColor(token))
            }
        }
        self.init(
            foreground: resolved[.terminalForeground]!,
            background: resolved[.terminalBackground]!,
            cursor: resolved[.terminalCursor]!,
            ansi: LumenToken.terminalANSI.map { resolved[$0]! }
        )
    }

    /// All 256 entries: the theme's 16 ANSI colors, then xterm's 6×6×6 color cube (16–231) and
    /// 24-step grayscale ramp (232–255), which are fixed by convention.
    var palette256: [RGB] {
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        var table = ansi
        table.reserveCapacity(256)
        for r in levels { for g in levels { for b in levels { table.append(RGB(r: r, g: g, b: b)) } } }
        for step in 0..<24 {
            let value = UInt8(8 + step * 10)
            table.append(RGB(r: value, g: value, b: value))
        }
        return table
    }

    /// Ghostty configuration lines for the full terminal surface.
    var ghosttyConfiguration: String {
        var lines = [
            "foreground = \(foreground.hex)",
            "background = \(background.hex)",
            "cursor-color = \(cursor.hex)",
        ]
        for (index, color) in ansi.enumerated() {
            lines.append("palette = \(index)=\(color.hex)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func rgb(_ color: NSColor) -> RGB {
        // Theme colors are always RGB; a color that cannot convert falls back to black.
        guard let c = color.usingColorSpace(.sRGB) else { return RGB(r: 0, g: 0, b: 0) }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((max(0, min(1, v)) * 255).rounded()) }
        return RGB(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent))
    }
}

/// What the terminal palette depends on besides appearance. Reading it inside a view body
/// subscribes that view to theme changes.
struct TerminalThemeIdentity: Equatable {
    var editorThemeID: String
    var usesSystemAccent: Bool

    static func current(store: DSThemeStore = .active) -> TerminalThemeIdentity {
        TerminalThemeIdentity(editorThemeID: store.editorTheme.id, usesSystemAccent: store.usesSystemAccent)
    }
}

extension NSColor {
    convenience init(themeRGB rgb: TerminalThemePalette.RGB) {
        self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

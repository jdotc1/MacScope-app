import AppKit
import LumenTokens
import LumenUI

/// App-side builder for the plugin theme snapshot. Lives in the app target (not `PluginSDK/`)
/// because the plugin XPC service compiles `PluginSDK/` without the design system.
extension PluginThemeSnapshot {
    /// Resolves every role through `store`, exactly as the app draws it: editor-owned roles from
    /// the editor theme, accent roles from the system accent when that option is on, and the
    /// high-contrast variant when `appearance.isHighContrast`.
    init(store: DSThemeStore = .active, appearance: LumenAppearance) {
        let appearanceName: NSAppearance.Name = switch (appearance.isDark, appearance.isHighContrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        let drawing = NSAppearance(named: appearanceName) ?? NSAppearance(named: .aqua)!
        var colors: [String: String] = [:]
        drawing.performAsCurrentDrawingAppearance {
            for (key, token) in Self.roleKeys {
                if let rgb = store.nsColor(token).usingColorSpace(.sRGB) {
                    colors[key] = Self.hex(rgb)
                }
            }
        }
        let theme = store.theme
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            themeID: theme.id,
            themeName: theme.displayName,
            editorThemeID: store.editorTheme.id,
            appearance: appearance.isDark ? "dark" : "light",
            increasedContrast: appearance.isHighContrast,
            colorSpace: "srgb",
            colors: colors,
            spacing: [
                "s0": Lumen.Space.s0, "s1": Lumen.Space.s1, "s2": Lumen.Space.s2, "s3": Lumen.Space.s3,
                "s4": Lumen.Space.s4, "s5": Lumen.Space.s5, "s6": Lumen.Space.s6, "s7": Lumen.Space.s7,
                "s8": Lumen.Space.s8, "s9": Lumen.Space.s9, "s10": Lumen.Space.s10, "s11": Lumen.Space.s11,
            ].mapValues(Double.init),
            radii: ["xs": Lumen.Radius.xs, "sm": Lumen.Radius.sm, "md": Lumen.Radius.md, "lg": Lumen.Radius.lg, "xl": Lumen.Radius.xl]
                .mapValues(Double.init),
            usesSystemAccent: store.usesSystemAccent
        )
    }

    /// The 110 keys plugins have always received. Roles retired in U5e keep their keys and resolve
    /// to what the app draws in their place.
    static let roleKeys: [(key: String, token: LumenToken)] = LumenToken.allCases.map { token in
        (token == LumenToken.Code.currentLine ? "bg.currentLine" : token.rawValue, token)
    } + [
        ("graph.edge.branch", LumenGraphEdgeKind.macScope(kind: "branch", isConditionalSource: true).token),
        ("graph.edge.call", LumenGraphEdgeKind.macScope(kind: "call", isConditionalSource: false).token),
        ("graph.edge.reference", LumenGraphEdgeKind.macScope(kind: "reference", isConditionalSource: false).token),
        ("graph.edge.fallthrough", LumenGraphEdgeKind.macScope(kind: "fallthrough", isConditionalSource: true).token),
        ("graph.edge.selected", .fgPrimary),
        ("welcome.accent", .accent),
    ]

    private static func hex(_ color: NSColor) -> String {
        func byte(_ component: CGFloat) -> String {
            String(format: "%02X", Int((max(0, min(1, component)) * 255).rounded()))
        }
        let alpha = color.alphaComponent < 1 ? byte(color.alphaComponent) : ""
        return "#" + byte(color.redComponent) + byte(color.greenComponent) + byte(color.blueComponent) + alpha
    }
}

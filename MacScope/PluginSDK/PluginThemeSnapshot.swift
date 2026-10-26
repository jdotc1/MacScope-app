import Foundation

/// The host's current theme, as a plugin sees it: resolved colors and the shared scales, so a
/// plugin's own UI can match MacScope without linking the app's design system.
///
/// Read-only and pushed by the host: plugins that declare the `ui.theme` capability receive it
/// after the handshake and again whenever the user changes theme, appearance or contrast, as the
/// `host.theme.update` command. Foundation only, because this file also compiles into the plugin
/// XPC service.
struct PluginThemeSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// Command identifier the host uses to deliver a snapshot.
    static let commandIdentifier = "host.theme.update"
    /// Capability a plugin declares to receive snapshots.
    static let capability = "ui.theme"

    var schemaVersion: Int
    /// The window theme's identifier and display name.
    var themeID: String
    var themeName: String
    /// The editor theme, which can differ from the window theme.
    var editorThemeID: String
    /// `"light"` or `"dark"`: the appearance the colors were resolved for.
    var appearance: String
    var increasedContrast: Bool
    /// `"srgb"` or `"display-p3"` for the window theme's colors.
    var colorSpace: String
    /// Every role (`"bg.canvas"`, `"syntax.register"`, `"sidebar.rowSelected"`, …) as
    /// `#RRGGBB` or `#RRGGBBAA`. Editor-owned roles come from the editor theme.
    var colors: [String: String]
    /// Spacing steps in points, keyed `"s0"` … `"s11"`.
    var spacing: [String: Double]
    /// Corner radii in points, keyed `"xs"`, `"sm"`, `"md"`, `"lg"`, `"xl"`.
    var radii: [String: Double]
    /// Whether accent roles currently follow the macOS accent color.
    var usesSystemAccent: Bool

    /// A role's color, or `nil` if this host does not define it.
    func color(_ role: String) -> String? { colors[role] }
}

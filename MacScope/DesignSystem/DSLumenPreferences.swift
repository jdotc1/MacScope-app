import Foundation

enum DSLumenPreferences {
    static let completionKey = "MacScope.lumen.legacyPreferencesMigrated"

    /// A migration copies legacy values; it never removes them or overrides a Lumen choice.
    static func migrate(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: completionKey) else { return }
        let keys = [
            ("dsThemeIdentifier", "MacScope.lumen.theme"),
            ("dsEditorThemeIdentifier", "MacScope.lumen.theme.editor"),
            ("dsUsesSystemAccent", "MacScope.lumen.usesSystemAccent"),
            ("dsDensity", "MacScope.lumen.density"),
        ]
        for (legacy, destination) in keys where defaults.object(forKey: destination) == nil {
            if let value = defaults.object(forKey: legacy) { defaults.set(value, forKey: destination) }
        }
        defaults.set(true, forKey: completionKey)
    }
}

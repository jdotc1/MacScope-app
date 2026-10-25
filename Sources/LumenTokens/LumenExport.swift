import Foundation

/// Generated, publishable forms of a registry: the built-in themes as JSON, a JSON Schema for
/// theme files (editors autocomplete from it), and a Markdown token reference.
public enum LumenExport {
    public static let fileNames = (themes: "builtin-themes.json", schema: "theme.schema.json", reference: "token-reference.md")

    /// How an app names its exported files and titles them (MacScope writes `macscope-theme.schema.json`
    /// titled "MacScope theme"). `.lumen` is Lumen's own.
    public struct Brand: Sendable {
        public var themesFile: String
        public var schemaFile: String
        public var referenceFile: String
        public var schemaTitle: String
        public var referenceTitle: String
        /// Export only the themes the app offers (`registry.galleryThemes`) rather than every built-in.
        public var galleryThemesOnly: Bool

        public init(themesFile: String = LumenExport.fileNames.themes, schemaFile: String = LumenExport.fileNames.schema,
                    referenceFile: String = LumenExport.fileNames.reference, schemaTitle: String = "Lumen theme",
                    referenceTitle: String = "Lumen tokens", galleryThemesOnly: Bool = false) {
            self.themesFile = themesFile
            self.schemaFile = schemaFile
            self.referenceFile = referenceFile
            self.schemaTitle = schemaTitle
            self.referenceTitle = referenceTitle
            self.galleryThemesOnly = galleryThemesOnly
        }

        public static let lumen = Brand()

        /// An app's brand: `<app>-theme.schema.json`, "<App> theme", "<App> colors", its gallery themes.
        public static func app(_ name: String) -> Brand {
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            return Brand(schemaFile: "\(slug)-theme.schema.json", schemaTitle: "\(name) theme",
                         referenceTitle: "\(name) colors", galleryThemesOnly: true)
        }
    }

    public static func builtInThemesJSON(_ registry: LumenRegistry) throws -> String {
        try builtInThemesJSON(registry, galleryThemesOnly: false)
    }

    public static func builtInThemesJSON(_ registry: LumenRegistry, galleryThemesOnly: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let themes = galleryThemesOnly ? registry.galleryThemes : registry.builtInThemes
        return String(decoding: try encoder.encode(themes), as: UTF8.self) + "\n"
    }

    public static func themeSchemaJSON(_ registry: LumenRegistry, title: String = "Lumen theme") throws -> String {
        let color: [String: Any] = ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", "description": "#RRGGBB or #RRGGBBAA"]
        var properties: [String: Any] = [:]
        for spec in registry.specs {
            var description = spec.fallback.map { "Component role; defaults to \($0.description)." }
                ?? "Semantic role; every complete variant defines it."
            if spec.surface != .window { description += " Drawn by the \(spec.surface.rawValue) surface." }
            if !spec.summary.isEmpty { description += " \(spec.summary)." }
            properties[spec.token.rawValue] = ["$ref": "#/$defs/color", "description": description]
        }
        for (key, token) in registry.renamedKeys {
            properties[key] = ["$ref": "#/$defs/color", "deprecated": true, "description": "Renamed; loads as \(token.rawValue)."]
        }
        for key in registry.retiredKeys {
            properties[key] = ["$ref": "#/$defs/color", "deprecated": true, "description": "Retired; ignored when loading."]
        }
        let palette: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": ["$ref": "#/$defs/color"]]
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": title,
            "type": "object",
            "required": ["id", "name"],
            "anyOf": [["required": ["inherits"]], ["required": ["light"]], ["required": ["dark"]]],
            "properties": [
                "schemaVersion": ["type": "integer", "minimum": 1, "maximum": LumenTheme.currentSchemaVersion],
                "id": ["type": "string", "minLength": 1, "pattern": "\\S"],
                "name": ["type": "string", "minLength": 1, "pattern": "\\S"],
                "summary": ["type": "string"],
                "colorSpace": ["enum": ["srgb", "display-p3"]],
                "highContrast": ["type": "boolean",
                                 "description": "A maximum-legibility theme: components draw their Increase Contrast look for it."],
                "inherits": ["type": "string", "examples": registry.builtInThemes.map(\.id)],
                "light": ["$ref": "#/$defs/palette"], "dark": ["$ref": "#/$defs/palette"],
                "lightHighContrast": ["$ref": "#/$defs/palette"], "darkHighContrast": ["$ref": "#/$defs/palette"],
            ],
            "$defs": ["color": color, "palette": palette],
        ]
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// One table per group: tier, fallback, surface, and the value in each built-in theme.
    public static func tokenReferenceMarkdown(_ registry: LumenRegistry, title: String = "Lumen tokens") -> String {
        let themes = registry.builtInThemes
        let columns = themes.flatMap { theme in
            theme.supportedAppearances.map { isDark in (theme, isDark, "\(theme.name) \(isDark ? "dark" : "light")") }
        }
        var lines = [
            "# \(title)", "",
            "Generated by `LumenExport` from the registered packs. Do not edit by hand.", "",
            registry.groups.map { "[\($0.title)](#\($0.title.lowercased().replacingOccurrences(of: " ", with: "-")))" }.joined(separator: " · "),
        ]
        for group in registry.groups {
            lines += ["", "## \(group.title)", "",
                      "| Token | Tier | Falls back to | Surface | " + columns.map(\.2).joined(separator: " | ") + " |",
                      "|---|---|---|---|" + String(repeating: "---|", count: columns.count)]
            for token in group.tokens {
                guard let spec = registry.spec(for: token) else { continue }
                let values = columns.map { theme, isDark, _ in theme.color(token, for: LumenAppearance(isDark: isDark), in: registry).hexString }
                lines.append("| `\(token.rawValue)` | \(spec.isComponent ? "component" : "semantic") | "
                             + "\(spec.fallback.map { "`\($0.description)`" } ?? "") | \(spec.surface.rawValue) | "
                             + values.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(_ registry: LumenRegistry, to directory: URL) throws {
        try write(registry, to: directory, brand: .lumen)
    }

    public static func write(_ registry: LumenRegistry, to directory: URL, brand: Brand) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try builtInThemesJSON(registry, galleryThemesOnly: brand.galleryThemesOnly)
            .write(to: directory.appending(path: brand.themesFile), atomically: true, encoding: .utf8)
        try themeSchemaJSON(registry, title: brand.schemaTitle)
            .write(to: directory.appending(path: brand.schemaFile), atomically: true, encoding: .utf8)
        try tokenReferenceMarkdown(registry, title: brand.referenceTitle)
            .write(to: directory.appending(path: brand.referenceFile), atomically: true, encoding: .utf8)
    }
}

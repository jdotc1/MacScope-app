import Foundation
import LumenTokens
import LumenUI

/// Generates the design system's published artifacts from the Swift source of truth:
/// `docs/design/tokens/builtin-themes.json`, `macscope-theme.schema.json` and
/// `token-reference.md`. `DSTokenExportTests` fails when the committed files drift from the
/// code; `Scripts/design/export_tokens.sh` regenerates them without building the app.
enum DSTokenExport {
    static let fileNames = (themes: "builtin-themes.json", schema: "macscope-theme.schema.json", reference: "token-reference.md")

    /// Every built-in theme, exactly as a theme file would encode it.
    static func builtInThemesJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(DSBuiltInThemes.all), as: UTF8.self) + "\n"
    }

    /// JSON Schema (draft 2020-12) for a theme file. Known tokens are listed with descriptions;
    /// unknown keys are allowed so a theme written for a newer MacScope still validates.
    static func themeSchemaJSON() throws -> String {
        let color: [String: Any] = [
            "type": "string",
            "pattern": "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$",
            "description": "#RRGGBB or #RRGGBBAA",
        ]
        var tokenProperties: [String: Any] = [:]
        for token in LumenToken.allCases {
            var description = token.isComponent
                ? "Component role; defaults to \(token.fallbackDescription!)."
                : "Semantic role; every complete variant defines it."
            if token.isEditorOwned { description += " Drawn by the code canvas (editor theme)." }
            tokenProperties[token.rawValue] = ["$ref": "#/$defs/color", "description": description]
        }
        let palette: [String: Any] = [
            "type": "object",
            "properties": tokenProperties,
            "additionalProperties": ["$ref": "#/$defs/color"],
        ]
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://macscope.app/schemas/theme-v\(LumenTheme.currentSchemaVersion).json",
            "title": "MacScope theme",
            "description": "A MacScope theme file (~/Library/Application Support/MacScope/Themes/*.json). Only id and name are required when the theme inherits from another theme.",
            "type": "object",
            "required": ["id", "name"],
            "properties": [
                "schemaVersion": ["type": "integer", "minimum": 1, "maximum": LumenTheme.currentSchemaVersion],
                "id": ["type": "string", "minLength": 1, "description": "Unique, reverse-DNS style; built-in ids are reserved."],
                "name": ["type": "string", "minLength": 1],
                "summary": ["type": "string"],
                "inherits": ["type": "string", "description": "Parent theme id; omitted colors come from the parent chain.", "examples": DSBuiltInThemes.all.map(\.id)],
                "colorSpace": ["enum": [LumenColorSpace.sRGB.rawValue, LumenColorSpace.displayP3.rawValue]],
                "light": ["$ref": "#/$defs/palette"],
                "dark": ["$ref": "#/$defs/palette"],
                "lightHighContrast": ["$ref": "#/$defs/palette"],
                "darkHighContrast": ["$ref": "#/$defs/palette"],
            ] as [String: Any],
            "anyOf": [["required": ["inherits"]], ["required": ["light"]], ["required": ["dark"]]],
            "$defs": ["color": color, "palette": palette],
        ]
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Every token, one table per group (`LumenToken.groups`): tier, fallback, owner, and values.
    static func tokenReferenceMarkdown() -> String {
        var lines = [
            "# MacScope design tokens",
            "",
            "Generated from the pinned Lumen registry and `MacScope/DesignSystem/Lumen/MacScopePack.swift` by `Scripts/design/export_tokens.sh`. Do not edit by hand.",
            "",
            "**Tier:** semantic roles are defined by every complete theme; component roles default to the role shown. "
                + "**Theme:** editor roles come from the editor theme (Settings ▸ Themes ▸ Editor theme), window roles from the window theme.",
            "",
            LumenToken.groups.map { "[\($0.title)](#\($0.title.lowercased().replacingOccurrences(of: " ", with: "-")))" }.joined(separator: " · "),
        ]
        let scope = DSBuiltInThemes.scope, midnight = DSBuiltInThemes.midnight, contrast = DSBuiltInThemes.contrast
        for group in LumenToken.groups {
            lines += [
                "",
                "## \(group.title)",
                "",
                "| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |",
                "|---|---|---|---|---|---|---|---|---|",
            ]
            for token in group.tokens {
                lines.append([
                    "`\(token.rawValue)`",
                    token.isComponent ? "component" : "semantic",
                    token.fallbackDescription.map { "`\($0)`" } ?? "",
                    token.isEditorOwned ? "editor" : "window",
                    scope.hex(token, for: .light).hexString,
                    scope.hex(token, for: .dark).hexString,
                    midnight.hex(token, for: .dark).hexString,
                    contrast.hex(token, for: .light).hexString,
                    contrast.hex(token, for: .dark).hexString,
                ].joined(separator: " | ").wrappedInTableRow)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes all three artifacts into `directory`.
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try builtInThemesJSON().write(to: directory.appending(path: fileNames.themes), atomically: true, encoding: .utf8)
        try themeSchemaJSON().write(to: directory.appending(path: fileNames.schema), atomically: true, encoding: .utf8)
        try tokenReferenceMarkdown().write(to: directory.appending(path: fileNames.reference), atomically: true, encoding: .utf8)
    }
}

private extension String {
    var wrappedInTableRow: String { "| \(self) |" }
}

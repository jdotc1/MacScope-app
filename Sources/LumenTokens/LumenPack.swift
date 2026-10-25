/// One finding from the validator.
public struct LumenIssue: Hashable, Identifiable, Sendable {
    public let severity: LumenSeverity
    public let appearance: LumenAppearance
    public let token: LumenToken?
    public let message: String

    public init(_ severity: LumenSeverity, _ appearance: LumenAppearance, token: LumenToken?, _ message: String) {
        self.severity = severity
        self.appearance = appearance
        self.token = token
        self.message = message
    }

    public var id: String { "\(appearance)|\(token?.rawValue ?? "")|\(message)" }
}

/// A check a pack adds to the validator, beyond the per-token contrast requirements.
public protocol LumenRule: Sendable {
    func issues(in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry) -> [LumenIssue]
}

/// Colors a pack contributes to a theme another pack defines: an app's own tokens, valued for
/// Lumen's built-in themes. Variants the theme doesn't declare are ignored.
public struct LumenThemeValues: Sendable, Hashable {
    public var light: LumenPalette?
    public var dark: LumenPalette?
    public var lightHighContrast: LumenPalette?
    public var darkHighContrast: LumenPalette?

    public init(light: LumenPalette? = nil, dark: LumenPalette? = nil,
                lightHighContrast: LumenPalette? = nil, darkHighContrast: LumenPalette? = nil) {
        self.light = light
        self.dark = dark
        self.lightHighContrast = lightHighContrast
        self.darkHighContrast = darkHighContrast
    }
}

/// A unit of design system: tokens, the values they take in built-in themes, whole themes, and
/// rules. Lumen ships ``LumenPack/core``; each app adds its own pack.
public struct LumenPack: Sendable {
    public var id: String
    public var tokens: [LumenTokenSpec]
    public var surfaces: [LumenSurface]
    /// Whole themes this pack adds, such as an app's branded variants. They usually `inherit` a
    /// core theme.
    public var themes: [LumenTheme]
    /// Values for this pack's tokens in themes defined elsewhere, keyed by theme id.
    public var themeValues: [String: LumenThemeValues]
    public var rules: [any LumenRule]
    /// Built-in themes to leave out of this app's gallery. They still resolve, so themes can
    /// inherit them: an app that brands its own versions of Lumen's themes hides the originals.
    public var hidesThemes: [String]
    /// Moves tokens another pack defines onto one of this app's surfaces. MacScope's editor theme
    /// draws the canvas, so it moves `bg.canvas` onto its editor surface.
    public var surfaceOverrides: [LumenToken: LumenSurface]
    /// Keys theme files used before a role was renamed or moved (an app's legacy names, say), and
    /// the token each now means. Theme files that use them load as the new roles, so users' themes
    /// keep working across a migration.
    public var renamedKeys: [String: LumenToken]
    /// Keys theme files may still carry for roles this app retired with no successor (MacScope's
    /// `graph.edge.*`). Nothing reads them and the validator doesn't flag them, so old files open
    /// quietly. Set it after creating the pack.
    public var retiredKeys: Set<String> = []

    public init(id: String, tokens: [LumenTokenSpec] = [], surfaces: [LumenSurface] = [], themes: [LumenTheme] = [],
                themeValues: [String: LumenThemeValues] = [:], rules: [any LumenRule] = [], hidesThemes: [String] = [],
                surfaceOverrides: [LumenToken: LumenSurface] = [:], renamedKeys: [String: LumenToken] = [:]) {
        self.id = id
        self.tokens = tokens
        self.surfaces = surfaces
        self.themes = themes
        self.themeValues = themeValues
        self.rules = rules
        self.hidesThemes = hidesThemes
        self.surfaceOverrides = surfaceOverrides
        self.renamedKeys = renamedKeys
    }
}

/// Every token, theme and rule an app uses: Lumen's core pack plus the app's packs.
public struct LumenRegistry: Sendable {
    public let packs: [LumenPack]
    /// Tokens in registration order.
    public let tokens: [LumenToken]
    /// The window, then every pack's surfaces in order, each once.
    public let surfaces: [LumenSurface]
    /// Built-in themes with every pack's values merged in, flattened.
    public let builtInThemes: [LumenTheme]
    /// The theme a partial theme falls back to for semantic roles it never defines.
    public let defaultThemeID: String
    public let rules: [any LumenRule]
    /// Every pack's renamed keys: old theme-file key → the token it now means.
    public let renamedKeys: [String: LumenToken]
    /// Every pack's retired keys: old theme-file keys with no successor, ignored without a warning.
    public let retiredKeys: Set<String>
    private let specsByToken: [LumenToken: LumenTokenSpec]
    private let themesByID: [String: LumenTheme]

    public init(packs: [LumenPack], defaultThemeID: String? = nil) {
        var specs: [LumenToken: LumenTokenSpec] = [:]
        var order: [LumenToken] = []
        for pack in packs {
            for spec in pack.tokens {
                precondition(specs[spec.token] == nil, "Token \(spec.token) is registered twice (pack \(pack.id))")
                specs[spec.token] = spec
                order.append(spec.token)
            }
        }
        for pack in packs {
            for (token, surface) in pack.surfaceOverrides {
                precondition(specs[token] != nil, "Pack \(pack.id) moves unknown token \(token) to \(surface)")
                specs[token]?.surface = surface
            }
        }
        for spec in specs.values {
            for base in spec.fallback?.bases ?? [] {
                precondition(specs[base] != nil, "Token \(spec.token) falls back to unregistered \(base)")
            }
        }
        for start in order {
            var seen: Set<LumenToken> = []
            var frontier = [start]
            while let token = frontier.popLast() {
                for base in specs[token]?.fallback?.bases ?? [] {
                    precondition(base != start, "Token \(start)'s fallbacks lead back to itself")
                    if seen.insert(base).inserted { frontier.append(base) }
                }
            }
        }
        var renamed: [String: LumenToken] = [:]
        for pack in packs {
            for (key, token) in pack.renamedKeys {
                precondition(specs[token] != nil, "Pack \(pack.id) renames \(key) to unregistered \(token)")
                precondition(specs[LumenToken(key)] == nil, "Pack \(pack.id) renames \(key), which is still a registered token")
                precondition(renamed[key] == nil || renamed[key] == token, "\(key) is renamed to two tokens")
                renamed[key] = token
            }
        }
        renamedKeys = renamed
        var retired: Set<String> = []
        for pack in packs {
            for key in pack.retiredKeys {
                precondition(specs[LumenToken(key)] == nil, "Pack \(pack.id) retires \(key), which is still a registered token")
                precondition(renamed[key] == nil, "\(key) is both retired and renamed")
                retired.insert(key)
            }
        }
        retiredKeys = retired
        specsByToken = specs
        tokens = order
        // Packs may share a surface (two packs that both draw on the editor): each is listed once.
        var listed: Set<LumenSurface> = []
        surfaces = ([.window] + packs.flatMap(\.surfaces)).filter { listed.insert($0).inserted }
        rules = packs.flatMap(\.rules)
        self.packs = packs

        let declared = packs.flatMap(\.themes)
        // Packs' values for a theme go into the variants it declares (so its children inherit them)
        // and again after flattening (so a variant it inherits gets them too).
        func addingValues(to theme: LumenTheme) -> LumenTheme {
            var theme = theme
            for pack in packs {
                guard let values = pack.themeValues[theme.id] else { continue }
                theme.light = theme.light.map { $0.merging(values.light) }
                theme.dark = theme.dark.map { $0.merging(values.dark) }
                if theme.light != nil { theme.lightHighContrast = theme.lightHighContrast.map { $0.merging(values.lightHighContrast) } ?? values.lightHighContrast }
                if theme.dark != nil { theme.darkHighContrast = theme.darkHighContrast.map { $0.merging(values.darkHighContrast) } ?? values.darkHighContrast }
            }
            return theme
        }
        var raw: [String: LumenTheme] = [:]
        for theme in declared {
            precondition(raw[theme.id] == nil, "Theme \(theme.id) is declared twice")
            raw[theme.id] = addingValues(to: theme)
        }
        builtInThemes = declared.map { theme in
            do {
                return addingValues(to: try raw[theme.id]!.flattened { raw[$0] })
            } catch {
                preconditionFailure("Built-in theme \(theme.id) \(error)")
            }
        }
        themesByID = Dictionary(builtInThemes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.defaultThemeID = defaultThemeID ?? declared.first?.id ?? ""
    }

    /// The built-in themes the app offers: every built-in except those a pack hides.
    public var galleryThemes: [LumenTheme] {
        let hidden = Set(packs.flatMap(\.hidesThemes))
        return builtInThemes.filter { !hidden.contains($0.id) }
    }

    public func spec(for token: LumenToken) -> LumenTokenSpec? { specsByToken[token] }
    public func theme(id: String) -> LumenTheme? { themesByID[id] }
    public func contains(_ token: LumenToken) -> Bool { specsByToken[token] != nil }

    /// `theme` with renamed keys rewritten to the tokens they now mean. A value already set under the
    /// new name wins. Theme loaders call this before using a file.
    public func migratingRenamedKeys(in theme: LumenTheme) -> LumenTheme {
        guard !renamedKeys.isEmpty else { return theme }
        func migrate(_ palette: LumenPalette?) -> LumenPalette? {
            guard let palette else { return nil }
            var colors: [String: LumenColor] = [:]
            for (key, value) in palette.colors where renamedKeys[key] == nil { colors[key] = value }
            for (key, value) in palette.colors {
                if let token = renamedKeys[key], colors[token.rawValue] == nil { colors[token.rawValue] = value }
            }
            return LumenPalette(colors: colors)
        }
        var migrated = theme
        migrated.light = migrate(theme.light)
        migrated.dark = migrate(theme.dark)
        migrated.lightHighContrast = migrate(theme.lightHighContrast)
        migrated.darkHighContrast = migrate(theme.darkHighContrast)
        return migrated
    }

    public var specs: [LumenTokenSpec] { tokens.compactMap { specsByToken[$0] } }
    public var semanticTokens: [LumenToken] { specs.filter { !$0.isComponent }.map(\.token) }

    /// The surface whose theme supplies `token` (the window for unknown tokens).
    public func surface(of token: LumenToken) -> LumenSurface { specsByToken[token]?.surface ?? .window }

    /// Tokens grouped by section, in registration order: the theme editor and the token
    /// reference both use this.
    public var groups: [(title: String, tokens: [LumenToken])] {
        var titles: [String] = []
        var byTitle: [String: [LumenToken]] = [:]
        for spec in specs {
            if byTitle[spec.group] == nil { titles.append(spec.group) }
            byTitle[spec.group, default: []].append(spec.token)
        }
        return titles.map { ($0, byTitle[$0] ?? []) }
    }

    /// Lumen's core pack alone, for apps that only need the shared roles.
    public static let core = LumenRegistry(packs: [.core])
}

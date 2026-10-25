import Foundation

/// The colors of one appearance of a theme. Unknown keys are kept, not rejected, so a theme
/// written for a newer app (or another app's pack) still loads.
public struct LumenPalette: Hashable, Sendable, Codable, ExpressibleByDictionaryLiteral {
    public private(set) var colors: [String: LumenColor]

    public init(colors: [String: LumenColor] = [:]) { self.colors = colors }

    public init(dictionaryLiteral elements: (LumenToken, LumenColor)...) {
        colors = Dictionary(elements.map { ($0.0.rawValue, $0.1) }, uniquingKeysWith: { _, new in new })
    }

    public init(from decoder: any Decoder) throws {
        colors = try decoder.singleValueContainer().decode([String: LumenColor].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(colors)
    }

    public subscript(token: LumenToken) -> LumenColor? {
        get { colors[token.rawValue] }
        set { colors[token.rawValue] = newValue }
    }

    /// This palette with `overrides` laid on top.
    public func merging(_ overrides: LumenPalette?) -> LumenPalette {
        guard let overrides else { return self }
        return LumenPalette(colors: colors.merging(overrides.colors) { _, new in new })
    }
}

/// A theme: an identity plus up to four palettes. Stored as JSON (schema version 1), usually as
/// a short list of overrides on top of an `inherits` parent.
public struct LumenTheme: Identifiable, Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var summary: String
    /// The space the theme's hex values are in. A theme file that doesn't say takes its parent's
    /// (sRGB at the root).
    public var colorSpace: LumenColorSpace {
        get { declaredColorSpace ?? .sRGB }
        set { declaredColorSpace = newValue }
    }
    /// `colorSpace` as written; `nil` when a theme file leaves it out, so it can inherit.
    private var declaredColorSpace: LumenColorSpace?
    /// A maximum-legibility theme (Lumen's Contrast): components that have an Increase Contrast
    /// look (icon tiles' deep grounds, for one) draw it for this theme as they do under the system
    /// setting. A theme file that doesn't say takes its parent's (`false` at the root).
    public var isHighContrast: Bool {
        get { declaredHighContrast ?? false }
        set { declaredHighContrast = newValue }
    }
    /// `isHighContrast` as written (`highContrast` in a theme file); `nil` when left out, so it can inherit.
    private var declaredHighContrast: Bool?
    public var inherits: String?
    public var light: LumenPalette?
    public var dark: LumenPalette?
    public var lightHighContrast: LumenPalette?
    public var darkHighContrast: LumenPalette?

    /// `colorSpace` left out (`nil`) inherits the parent's, as in a theme file; sRGB at the root.
    public init(id: String, name: String, summary: String = "", colorSpace: LumenColorSpace? = nil, isHighContrast: Bool? = nil,
                inherits: String? = nil, light: LumenPalette?, dark: LumenPalette?,
                lightHighContrast: LumenPalette? = nil, darkHighContrast: LumenPalette? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.summary = summary
        declaredColorSpace = colorSpace
        declaredHighContrast = isHighContrast
        self.inherits = inherits
        self.light = light
        self.dark = dark
        self.lightHighContrast = lightHighContrast
        self.darkHighContrast = darkHighContrast
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, summary, colorSpace, inherits, light, dark, lightHighContrast, darkHighContrast
        case highContrast
    }

    /// Only `id` and `name` are required, and the file must satisfy the published schema: a
    /// non-empty id and name, and a palette unless it `inherits`. A newer schema skips these
    /// checks so the loader can report it as needing a newer app.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        declaredColorSpace = try c.decodeIfPresent(LumenColorSpace.self, forKey: .colorSpace)
        declaredHighContrast = try c.decodeIfPresent(Bool.self, forKey: .highContrast)
        inherits = try c.decodeIfPresent(String.self, forKey: .inherits)
        light = try c.decodeIfPresent(LumenPalette.self, forKey: .light)
        dark = try c.decodeIfPresent(LumenPalette.self, forKey: .dark)
        lightHighContrast = try c.decodeIfPresent(LumenPalette.self, forKey: .lightHighContrast)
        darkHighContrast = try c.decodeIfPresent(LumenPalette.self, forKey: .darkHighContrast)
        guard schemaVersion <= Self.currentSchemaVersion else { return }
        guard schemaVersion >= 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "schemaVersion must be 1 or higher")
        }
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "“id” is empty")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "“name” is empty")
        }
        guard inherits != nil || light != nil || dark != nil else {
            throw DecodingError.dataCorruptedError(forKey: .inherits, in: c,
                                                   debugDescription: "a theme needs a “light” or “dark” palette, or “inherits” another theme")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(declaredColorSpace, forKey: .colorSpace)
        try c.encodeIfPresent(declaredHighContrast, forKey: .highContrast)
        try c.encodeIfPresent(inherits, forKey: .inherits)
        try c.encodeIfPresent(light, forKey: .light)
        try c.encodeIfPresent(dark, forKey: .dark)
        try c.encodeIfPresent(lightHighContrast, forKey: .lightHighContrast)
        try c.encodeIfPresent(darkHighContrast, forKey: .darkHighContrast)
    }

    /// Top-level keys in a theme file that aren't theme fields ("darkHighcontrast"): they're
    /// ignored on load, so they're usually typos worth reporting.
    public static func unknownTopLevelKeys(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let known = Set(["$schema"] + [CodingKeys.schemaVersion, .id, .name, .summary, .colorSpace, .inherits, .light, .dark,
                                       .lightHighContrast, .darkHighContrast, .highContrast].map(\.stringValue))
        return object.keys.filter { !known.contains($0) }.sorted()
    }

    // MARK: Inheritance

    /// Why a theme can't be flattened. Each description reads after "it": "it inherits unknown theme x".
    public enum InheritanceError: Error, Equatable, CustomStringConvertible {
        case unknownParent(String)
        case cycle([String])
        case tooDeep

        public var description: String {
            switch self {
            case .unknownParent(let id): "inherits unknown theme \(id)"
            case .cycle(let ids): "has an inheritance cycle, \(ids.joined(separator: " → "))"
            case .tooDeep: "inherits through more than 8 themes"
            }
        }
    }

    /// This theme with its `inherits` chain merged in. Each variant layers this theme's colors over
    /// its parent's. Increase Contrast layers per level: an ancestor's contrast values sit under a
    /// descendant's own colors, so a theme's overrides survive Increase Contrast.
    public func flattened(lookup: (String) -> LumenTheme?) throws -> LumenTheme {
        var chain: [LumenTheme] = [self]
        var seen: Set<String> = [id]
        var next = inherits
        while let parentID = next {
            guard chain.count <= 8 else { throw InheritanceError.tooDeep }
            guard let parent = lookup(parentID) else { throw InheritanceError.unknownParent(parentID) }
            guard seen.insert(parent.id).inserted else { throw InheritanceError.cycle(chain.map(\.id) + [parent.id]) }
            chain.append(parent)
            next = parent.inherits
        }
        func merge(_ path: KeyPath<LumenTheme, LumenPalette?>) -> LumenPalette? {
            chain.reversed().reduce(nil as LumenPalette?) { base, theme in
                guard let layer = theme[keyPath: path] else { return base }
                return base.map { $0.merging(layer) } ?? layer
            }
        }
        func mergeContrast(_ base: KeyPath<LumenTheme, LumenPalette?>, _ contrast: KeyPath<LumenTheme, LumenPalette?>) -> LumenPalette? {
            chain.reversed().reduce(nil as LumenPalette?) { below, theme in
                var layered = below.map { $0.merging(theme[keyPath: base]) }
                if let own = theme[keyPath: contrast] { layered = layered.map { $0.merging(own) } ?? own }
                return layered
            }
        }
        var result = self
        result.inherits = nil
        result.declaredColorSpace = chain.lazy.compactMap(\.declaredColorSpace).first ?? .sRGB
        result.declaredHighContrast = chain.lazy.compactMap(\.declaredHighContrast).first
        result.light = merge(\.light)
        result.dark = merge(\.dark)
        result.lightHighContrast = mergeContrast(\.light, \.lightHighContrast)
        result.darkHighContrast = mergeContrast(\.dark, \.darkHighContrast)
        return result
    }

    // MARK: Lookup

    /// The appearance this theme imposes, or `nil` when it has both variants.
    public var forcedAppearanceIsDark: Bool? {
        switch (light, dark) {
        case (nil, .some): true
        case (.some, nil): false
        default: nil
        }
    }

    /// The appearances the theme declares (`false` = light, `true` = dark).
    public var supportedAppearances: [Bool] {
        [light != nil ? false : nil, dark != nil ? true : nil].compactMap(\.self)
    }

    /// The palette for `appearance`, falling back to the theme's only variant.
    public func palette(for appearance: LumenAppearance) -> LumenPalette {
        let base = (appearance.isDark ? dark : light) ?? dark ?? light ?? LumenPalette()
        guard appearance.isHighContrast else { return base }
        let usesDark = appearance.isDark ? dark != nil : light == nil
        return base.merging(usesDark ? darkHighContrast : lightHighContrast)
    }

    /// The color for `token`: this theme's value; else, for a component token, its fallback in
    /// this same theme (when the theme defines what the fallback is built from); else the
    /// registry's default theme; else black or white. A theme with one variant answers in that
    /// variant whatever the appearance asked for, so a dark-only theme never takes a light value.
    public func color(_ token: LumenToken, for appearance: LumenAppearance, in registry: LumenRegistry) -> LumenColor {
        color(token, for: appearance, in: registry, resolution: LumenResolution())
    }

    /// `color(_:for:in:)` with tokens swapped or derived along the way (raised grounds, the
    /// system accent): see `LumenResolution`.
    func color(_ token: LumenToken, for appearance: LumenAppearance, in registry: LumenRegistry,
               resolution: LumenResolution) -> LumenColor {
        var seen: Set<LumenToken> = []
        return resolve(token, for: normalized(appearance), in: registry, seen: &seen, resolution: resolution)
    }

    /// `appearance` in the variant this theme draws it with.
    func normalized(_ appearance: LumenAppearance) -> LumenAppearance {
        LumenAppearance(isDark: forcedAppearanceIsDark ?? appearance.isDark, isHighContrast: appearance.isHighContrast)
    }

    private func resolve(_ token: LumenToken, for appearance: LumenAppearance, in registry: LumenRegistry,
                         seen: inout Set<LumenToken>, resolution: LumenResolution) -> LumenColor {
        // A substitute already on the path (bg.insetRaised, resolving its own fallback to bg.inset)
        // isn't swapped in again: there the plain token is meant.
        if let substitute = resolution.substitutions[token], !seen.contains(substitute) {
            // Once: the substitute's own fallback (bg.insetRaised → bg.inset) reaches the plain token.
            var narrowed = resolution
            narrowed.substitutions[token] = nil
            return resolve(substitute, for: appearance, in: registry, seen: &seen, resolution: narrowed)
        }
        if let derived = resolution.derive?(token) { return derived }
        let palette = palette(for: appearance)
        if let value = palette[token] { return value }
        let defaultTheme = id != registry.defaultThemeID ? registry.theme(id: registry.defaultThemeID) : nil
        // A fallback cycle (a malformed pack) ends here rather than recursing forever. `seen` holds
        // the tokens on the current path only, so a token two branches share (a composite of a
        // token over itself) resolves in both.
        if !seen.contains(token), let fallback = registry.spec(for: token)?.fallback,
           defaultTheme == nil || defines(fallback.bases, in: palette, registry: registry) {
            seen.insert(token)
            defer { seen.remove(token) }
            switch fallback {
            case .token(let base):
                return resolve(base, for: appearance, in: registry, seen: &seen, resolution: resolution)
            case .composite(let base, let alpha, let over):
                return resolve(base, for: appearance, in: registry, seen: &seen, resolution: resolution)
                    .composited(alpha: alpha, over: resolve(over, for: appearance, in: registry, seen: &seen, resolution: resolution))
            }
        }
        // A partial theme that sets none of a fallback's sources gets the default theme's own value
        // for the token, tuned for its grounds, rather than one derived from borrowed sources.
        if let defaultTheme {
            return defaultTheme.color(token, for: appearance, in: registry, resolution: resolution)
        }
        return appearance.isDark ? "#FFFFFF" : "#000000"
    }

    /// Whether `palette` sets any of `tokens`, directly or through their own fallbacks.
    private func defines(_ tokens: [LumenToken], in palette: LumenPalette, registry: LumenRegistry, depth: Int = 0) -> Bool {
        guard depth < 16 else { return false }
        return tokens.contains { token in
            palette[token] != nil
                || registry.spec(for: token)?.fallback.map { defines($0.bases, in: palette, registry: registry, depth: depth + 1) } == true
        }
    }

    /// Semantic tokens a declared variant leaves undefined. Empty for a complete theme.
    public func missingTokens(in registry: LumenRegistry) -> [(isDark: Bool, token: LumenToken)] {
        supportedAppearances.flatMap { isDark in
            let palette = isDark ? dark : light
            return registry.semanticTokens.filter { palette?[$0] == nil }.map { (isDark, $0) }
        }
    }
}

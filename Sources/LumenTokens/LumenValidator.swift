import Foundation

/// A surface must stay visible against another: by contrast ratio, OKLab distance, or both.
public struct LumenVisibilityRule: LumenRule {
    public var token: LumenToken
    public var ground: LumenToken
    public var minimumContrast: Double?
    public var minimumDistance: Double?
    public var severity: LumenSeverity
    public var message: String

    public init(_ token: LumenToken, against ground: LumenToken, minimumContrast: Double? = nil, minimumDistance: Double? = nil,
                severity: LumenSeverity = .warning, message: String) {
        self.token = token
        self.ground = ground
        self.minimumContrast = minimumContrast
        self.minimumDistance = minimumDistance
        self.severity = severity
        self.message = message
    }

    public func issues(in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry) -> [LumenIssue] {
        let space = theme.colorSpace
        let color = theme.color(token, for: appearance, in: registry)
        // Every backdrop the ground can show over must pass (a floating ground's are unknown).
        let fails = LumenValidator.opaqueGrounds(ground, in: theme, appearance: appearance, registry: registry).contains { b in
            let a = color.over(b)
            let tooLow = minimumContrast.map { a.contrastRatio(against: b, in: space) < $0 } ?? false
            let tooClose = minimumDistance.map { a.perceptualDistance(to: b, in: space) < $0 } ?? false
            return tooLow || tooClose
        }
        return fails ? [LumenIssue(severity, appearance, token: token, message)] : []
    }
}

/// On a dark ground, `token` must be lighter than `ground`: dark interfaces step up as they nest
/// (a well inside a card is lighter than the card), never down into a hole. Light grounds are
/// exempt; there a well is a shade darker than the white it sits on.
public struct LumenLiftRule: LumenRule {
    public var token: LumenToken
    public var ground: LumenToken
    public var severity: LumenSeverity

    public init(_ token: LumenToken, on ground: LumenToken, severity: LumenSeverity = .warning) {
        self.token = token
        self.ground = ground
        self.severity = severity
    }

    public func issues(in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry) -> [LumenIssue] {
        let space = theme.colorSpace
        let b = LumenValidator.opaqueGround(ground, in: theme, appearance: appearance, registry: registry)
        guard b.relativeLuminance(in: space) < 0.18 else { return [] }
        let a = theme.color(token, for: appearance, in: registry).over(b)
        return a.relativeLuminance(in: space) > b.relativeLuminance(in: space) ? [] : [LumenIssue(severity, appearance, token: token,
            "\(token.rawValue) is darker than \(ground.rawValue) it sits on; in dark, nested grounds step lighter")]
    }
}

/// Tokens drawn side by side (object kinds, chart series, edge types) must each look different,
/// as drawn: a translucent one is compared composited over the ground that holds it (the canvas,
/// unless the token says otherwise; see `LumenValidator.opaqueGround`).
public struct LumenDistinctRule: LumenRule {
    public var tokens: [LumenToken]
    public var minimumDistance: Double
    public var severity: LumenSeverity
    /// What the tokens mean, for the message: "kinds", "series".
    public var noun: String

    public init(_ tokens: [LumenToken], minimumDistance: Double = 0.06, severity: LumenSeverity = .warning, noun: String) {
        self.tokens = tokens
        self.minimumDistance = minimumDistance
        self.severity = severity
        self.noun = noun
    }

    public func issues(in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry) -> [LumenIssue] {
        let colors = tokens.map { ($0, LumenValidator.opaqueGround($0, in: theme, appearance: appearance, registry: registry)) }
        var found: [LumenIssue] = []
        for (i, first) in colors.enumerated() {
            for second in colors[(i + 1)...] where first.1.perceptualDistance(to: second.1, in: theme.colorSpace) < minimumDistance {
                found.append(LumenIssue(severity, appearance, token: second.0,
                                        "\(first.0.rawValue) and \(second.0.rawValue) are too alike to tell \(noun) apart"))
            }
        }
        return found
    }
}

/// Contrast requirements for pairs whose foreground another pack owns, such as core text on an
/// app's own panel colors. (A pack can't add requirements to a token it doesn't define.)
public struct LumenContrastPairsRule: LumenRule {
    public var pairs: [(foreground: LumenToken, contrast: LumenContrast)]

    public init(_ pairs: [(foreground: LumenToken, contrast: LumenContrast)]) { self.pairs = pairs }

    /// Every foreground against every ground, at one requirement.
    public init(_ foregrounds: [LumenToken], on grounds: [LumenToken], minimum: Double = 4.5, severity: LumenSeverity = .error) {
        pairs = grounds.flatMap { ground in foregrounds.map { ($0, LumenContrast(on: ground, minimum: minimum, severity: severity)) } }
    }

    public func issues(in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry) -> [LumenIssue] {
        pairs.compactMap { pair in
            LumenValidator.contrastIssue(pair.foreground, pair.contrast, in: theme, appearance: appearance, registry: registry)
        }
    }
}

/// Any other check, as a closure.
public struct LumenCustomRule: LumenRule {
    public let name: String
    private let check: @Sendable (LumenTheme, LumenAppearance, LumenRegistry) -> [LumenIssue]

    public init(_ name: String, _ check: @escaping @Sendable (LumenTheme, LumenAppearance, LumenRegistry) -> [LumenIssue]) {
        self.name = name
        self.check = check
    }

    public func issues(in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry) -> [LumenIssue] {
        check(theme, appearance, registry)
    }
}

/// The checks every theme must pass: each registered token's contrast requirements (on the canvas
/// and, where a role changes there, on raised grounds), every pack's rules, and unknown palette
/// keys. The theme editor, the gallery and import all use it.
///
/// Colors are measured in the theme's color space, and a translucent ground over the ground that
/// holds it (`opaqueGround`).
public enum LumenValidator {
    public static func issues(for theme: LumenTheme, in registry: LumenRegistry) -> [LumenIssue] {
        // Increase Contrast is checked where the theme has its own palette for it; elsewhere it draws
        // the same colors, and checking them again would report every issue twice.
        let appearances = theme.supportedAppearances.flatMap { isDark in
            let hasContrastPalette = (isDark ? theme.darkHighContrast : theme.lightHighContrast) != nil
            return ([false] + (hasContrastPalette ? [true] : [])).map { LumenAppearance(isDark: isDark, isHighContrast: $0) }
        }
        var found = unknownKeyIssues(in: theme, registry: registry)
        let raised = Set(registry.raisedTokens)
        let pairs = registry.specs.flatMap { spec in spec.contrast.map { (foreground: spec.token, contrast: $0) } }
            + registry.rules.compactMap { $0 as? LumenContrastPairsRule }.flatMap(\.pairs)
        for appearance in appearances {
            for spec in registry.specs {
                if spec.isForeground, let issue = opacityIssue(spec.token, in: theme, appearance: appearance, registry: registry) {
                    found.append(issue)
                }
                for requirement in spec.contrast {
                    if let issue = contrastIssue(spec.token, requirement, in: theme, appearance: appearance, registry: registry) {
                        found.append(issue)
                    }
                }
            }
            for rule in registry.rules {
                found += rule.issues(in: theme, appearance: appearance, registry: registry)
            }
            var reported: Set<String> = []
            for pair in pairs where raised.contains(pair.foreground) || raised.contains(pair.contrast.ground) {
                if let issue = raisedContrastIssue(pair.foreground, pair.contrast, in: theme, appearance: appearance, registry: registry),
                   reported.insert(issue.message).inserted {
                    found.append(issue)
                }
            }
        }
        return found
    }

    /// The finding for a foreground and requirement as drawn on a raised ground (a keycap in a card
    /// takes `bg.insetRaised`), or `nil` when it passes there, draws the same as on the canvas, or a
    /// requirement on the raised role itself already covers it.
    static func raisedContrastIssue(_ foreground: LumenToken, _ requirement: LumenContrast, in theme: LumenTheme,
                                    appearance: LumenAppearance, registry: LumenRegistry) -> LumenIssue? {
        if let swapped = LumenTheme.raisedSubstitutions[requirement.ground],
           registry.contrastRequirements(of: foreground).contains(where: { $0.ground == swapped && $0.minimum >= requirement.minimum }) {
            return nil
        }
        let resolution = LumenResolution(substitutions: LumenTheme.raisedSubstitutions)
        let plainInk = theme.color(foreground, for: appearance, in: registry)
        let ink = theme.color(foreground, for: appearance, in: registry, resolution: resolution)
        let plainGrounds = opaqueGrounds(requirement.ground, in: theme, appearance: appearance, registry: registry)
        let grounds = opaqueGrounds(requirement.ground, in: theme, appearance: appearance, registry: registry, resolution: resolution)
        guard ink != plainInk || grounds != plainGrounds else { return nil }
        let ratio = grounds.map { ink.over($0).contrastRatio(against: $0, in: theme.colorSpace) }.min() ?? 21
        guard ratio < requirement.minimum else { return nil }
        return LumenIssue(requirement.severity, appearance, token: foreground,
                          "\(foreground.rawValue) on \(requirement.ground.rawValue) on a raised ground is \(format(ratio)):1; needs \(needed(requirement)):1")
    }

    private static func needed(_ requirement: LumenContrast) -> String {
        format(requirement.minimum, digits: requirement.minimum.rounded() == requirement.minimum ? 0 : 2)
    }

    /// Palette keys no pack registers. They are kept (a theme may target a newer app or another
    /// app's pack) but in a hand-written theme they are usually typos, so name each once and
    /// suggest the token that was probably meant.
    public static func unknownKeyIssues(in theme: LumenTheme, registry: LumenRegistry) -> [LumenIssue] {
        let variants: [(LumenPalette?, LumenAppearance)] = [
            (theme.light, .light), (theme.dark, .dark),
            (theme.lightHighContrast, LumenAppearance(isDark: false, isHighContrast: true)),
            (theme.darkHighContrast, LumenAppearance(isDark: true, isHighContrast: true)),
        ]
        var reported: Set<String> = []
        return variants.flatMap { palette, appearance in
            (palette?.colors.keys.filter { !registry.contains(LumenToken($0)) && !registry.retiredKeys.contains($0) }.sorted() ?? [])
                .filter { reported.insert($0).inserted }
                .map { key in
                    if let renamed = registry.renamedKeys[key] {
                        return LumenIssue(.warning, appearance, token: nil,
                                          "“\(key)” is now “\(renamed.rawValue)”; it loads as that, but rename it in the file")
                    }
                    let suggestion = suggestion(for: key, in: registry)
                    return LumenIssue(.warning, appearance, token: nil,
                                      "“\(key)” is not a color this app knows" + (suggestion.map { "; did you mean “\($0.rawValue)”?" } ?? ""))
                }
        }
    }

    /// The registered token a mistyped key most likely meant: one it's the start or end of
    /// ("canvas" → "bg.canvas"), else the nearest by edit distance, within a few typos.
    static func suggestion(for key: String, in registry: LumenRegistry) -> LumenToken? {
        if let affix = registry.tokens.first(where: { $0.rawValue.hasPrefix(key + ".") || $0.rawValue.hasSuffix("." + key) }) {
            return affix
        }
        let limit = max(1, min(3, key.count / 4))
        return registry.tokens
            .map { ($0, editDistance(key.lowercased(), $0.rawValue.lowercased())) }
            .filter { $0.1 <= limit }
            .min { $0.1 < $1.1 }?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// The finding for a translucent foreground, or `nil` when it is opaque. This also catches
    /// imported theme files, which can carry an alpha byte in any hex value.
    public static func opacityIssue(_ foreground: LumenToken, in theme: LumenTheme, appearance: LumenAppearance,
                                    registry: LumenRegistry) -> LumenIssue? {
        let alpha = theme.color(foreground, for: appearance, in: registry).alpha
        guard alpha < 1 else { return nil }
        return LumenIssue(.error, appearance, token: foreground,
                          "\(foreground.rawValue) must be opaque (it is \(Int((alpha * 100).rounded()))%): contrast can't be established for translucent text")
    }

    /// The finding for one foreground and requirement, or `nil` when it passes. A translucent
    /// foreground (in a pack rule, say) is measured as it actually appears: composited over the ground,
    /// and a translucent ground over every backdrop it can show over (the worst one counts).
    public static func contrastIssue(_ foreground: LumenToken, _ requirement: LumenContrast, in theme: LumenTheme,
                                     appearance: LumenAppearance, registry: LumenRegistry) -> LumenIssue? {
        let ink = theme.color(foreground, for: appearance, in: registry)
        let ratio = opaqueGrounds(requirement.ground, in: theme, appearance: appearance, registry: registry)
            .map { ink.over($0).contrastRatio(against: $0, in: theme.colorSpace) }.min() ?? 21
        guard ratio < requirement.minimum else { return nil }
        return LumenIssue(requirement.severity, appearance, token: foreground,
                          "\(foreground.rawValue) on \(requirement.ground.rawValue) is \(format(ratio)):1; needs \(needed(requirement)):1")
    }

    /// What a translucent ground is drawn over.
    enum Backdrop: Equatable {
        /// The window's own backdrop: plain white in light, black in dark.
        case window
        /// Another ground, itself resolved the same way.
        case ground(LumenToken)
        /// Unknown (a menu floats over whatever is behind it): plain white and plain black both.
        case any
    }

    /// Where Lumen's own grounds sit. Window-level panes sit on the window's backdrop; wells, hover,
    /// selections and tints on the canvas; their raised roles on cards; rows on the sidebar;
    /// highlights and keycaps in menus. A token not listed sits on its composite fallback's ground
    /// (`field.background`: the sidebar), else where its fallback sits (an app's listing that falls
    /// back to `bg.canvas` replaces the canvas), else on the canvas.
    static let backdrops: [LumenToken: Backdrop] = [
        .bgWindow: .window, .bgCanvas: .window, .bgSidebar: .window, .sidebarBackground: .window, .toolbarBackground: .window,
        .inspectorBackground: .window, .panelBackground: .window, .welcomeBackground: .window, .welcomePanel: .window,
        .titlebarActiveTop: .window, .titlebarActiveBottom: .window,
        .bgInsetRaised: .ground(.bgElevated), .bgHoverRaised: .ground(.bgElevated), .bgSelectedInactiveRaised: .ground(.bgElevated),
        .sidebarRowSelected: .ground(.sidebarBackground), .sidebarRowSelectedInactive: .ground(.sidebarBackground), .sidebarRowHover: .ground(.sidebarBackground),
        .menuBackground: .any, .menuHighlight: .ground(.menuBackground), .keycapBackground: .ground(.menuBackground),
        .activityBackground: .ground(.toolbarBackground), .panelGroup: .ground(.panelBackground), .tabActiveFill: .ground(.bgWindow),
    ]

    static func backdrop(of token: LumenToken, in registry: LumenRegistry, depth: Int = 0) -> Backdrop {
        if let listed = backdrops[token] { return listed }
        switch registry.spec(for: token)?.fallback {
        case .composite(_, _, let over)?: return .ground(over)
        case .token(let base)? where depth < 16: return backdrop(of: base, in: registry, depth: depth + 1)
        default: return registry.contains(.bgCanvas) && token != .bgCanvas ? .ground(.bgCanvas) : .window
        }
    }

    /// A ground as it appears: a translucent one (a 10% white selection tint) laid over the ground
    /// that holds it (`backdrops`), down to the window's plain white or black. For a floating ground
    /// (a menu), the composite over the theme's own backdrop; the validator's contrast checks try
    /// every backdrop (`opaqueGrounds`).
    public static func opaqueGround(_ ground: LumenToken, in theme: LumenTheme, appearance: LumenAppearance,
                                    registry: LumenRegistry) -> LumenColor {
        opaqueGrounds(ground, in: theme, appearance: appearance, registry: registry)[0]
    }

    /// `ground` over every backdrop it can show over: one color unless it is translucent and floats
    /// (or sits on a ground that does). The theme's own backdrop comes first.
    static func opaqueGrounds(_ ground: LumenToken, in theme: LumenTheme, appearance: LumenAppearance, registry: LumenRegistry,
                              resolution: LumenResolution = LumenResolution(), depth: Int = 0) -> [LumenColor] {
        let color = theme.color(ground, for: appearance, in: registry, resolution: resolution)
        guard color.alpha < 1 else { return [color] }
        let plain: LumenColor = theme.normalized(appearance).isDark ? "#000000" : "#FFFFFF"
        let unders: [LumenColor]
        switch depth < 8 ? backdrop(of: ground, in: registry) : .window {
        case .window: unders = [plain]
        case .any: unders = [plain, theme.normalized(appearance).isDark ? "#FFFFFF" : "#000000"]
        case .ground(let holder):
            unders = opaqueGrounds(holder, in: theme, appearance: appearance, registry: registry, resolution: resolution, depth: depth + 1)
        }
        var seen: Set<LumenColor> = []
        return unders.map { color.over($0) }.filter { seen.insert($0).inserted }
    }

    static func format(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
}

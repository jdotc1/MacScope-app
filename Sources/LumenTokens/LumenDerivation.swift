import Foundation

// Colors a theme doesn't write down but draws: the same roles on a raised ground (a card, popover,
// sheet or menu), and the accent family taken from the macOS accent color. Both are decided here,
// from the registry and the theme's own values, so the store, the validator and the tests agree.

/// How a resolution swaps or derives tokens on the way: `substitutions` replace a token (and every
/// token that only falls back to it) with another; `derive` answers a token outright.
struct LumenResolution {
    var substitutions: [LumenToken: LumenToken] = [:]
    var derive: ((LumenToken) -> LumenColor?)?
}

// MARK: Raised grounds

public extension LumenTheme {
    /// The roles that change on a raised ground, and what they become there: wells take
    /// `bg.insetRaised`, hover `bg.hoverRaised`, the inactive selection `bg.selectedInactiveRaised`.
    static let raisedSubstitutions: [LumenToken: LumenToken] = [
        .bgInset: .bgInsetRaised, .bgHover: .bgHoverRaised, .bgSelectedInactive: .bgSelectedInactiveRaised,
    ]

    /// `token` as drawn on a raised ground. A token that only falls back to a swapped role (a
    /// keycap that follows `bg.inset`) swaps with it; one the theme sets itself keeps its value.
    /// Decided by where the value comes from, never by comparing colors.
    func raisedColor(_ token: LumenToken, for appearance: LumenAppearance, in registry: LumenRegistry) -> LumenColor {
        color(token, for: appearance, in: registry, resolution: LumenResolution(substitutions: Self.raisedSubstitutions))
    }
}

public extension LumenRegistry {
    /// Tokens whose color can differ on a raised ground: the swapped roles and every token whose
    /// fallbacks reach one. Everything else draws the same on a card as on the canvas.
    var raisedTokens: [LumenToken] {
        let swapped = Set(LumenTheme.raisedSubstitutions.keys)
        return tokens.filter { swapped.contains($0) || reaches(swapped, from: $0) }
    }

    /// Tokens drawn from the macOS accent when the store follows it: those that follow it
    /// (`followsSystemAccent`) and those whose fallbacks reach one (`field.background`, a
    /// sidebar selection that falls back to `bg.selected`) unless a theme sets them itself.
    var systemAccentTokens: [LumenToken] {
        let following = Set(specs.filter(\.followsSystemAccent).map(\.token))
        return tokens.filter { following.contains($0) || reaches(following, from: $0) }
    }

    /// Whether `token`'s fallback chain reaches any of `targets`.
    func reaches(_ targets: Set<LumenToken>, from token: LumenToken) -> Bool {
        var seen: Set<LumenToken> = []
        var frontier = spec(for: token)?.fallback?.bases ?? []
        while let next = frontier.popLast() {
            if targets.contains(next) { return true }
            if seen.insert(next).inserted { frontier += spec(for: next)?.fallback?.bases ?? [] }
        }
        return false
    }

    /// The contrast `token` must reach as a foreground: its own requirements and every pack rule's
    /// pairs that name it.
    func contrastRequirements(of token: LumenToken) -> [LumenContrast] {
        (spec(for: token)?.contrast ?? []) + rules.compactMap { $0 as? LumenContrastPairsRule }
            .flatMap { $0.pairs.filter { $0.foreground == token }.map(\.contrast) }
    }

    /// Every foreground required to read on `ground`, with its requirement.
    func requirements(on ground: LumenToken) -> [(foreground: LumenToken, contrast: LumenContrast)] {
        specs.flatMap { spec in spec.contrast.filter { $0.ground == ground }.map { (spec.token, $0) } }
            + rules.compactMap { $0 as? LumenContrastPairsRule }.flatMap { $0.pairs.filter { $0.contrast.ground == ground } }
    }
}

// MARK: System accent

public extension LumenTheme {
    /// `token` with the accent family taken from `systemAccent` (sRGB) rather than the theme:
    ///
    /// - The accent and its lines, glyphs and bars: the system accent, darkened in light and
    ///   lightened in dark just far enough to meet their contrast requirements (yellow on white).
    /// - `accent.subtle`: the canvas with 18% of the accent. `accent.soft`: the accent toward white.
    /// - Filled shapes (`menu.highlight`, `accent.filled` and what falls back to them): a deep tone
    ///   of the accent under white text, in light and dark (PRINCIPLES §8), deep enough that dimmed
    ///   text and keycaps on it still read.
    /// - The selection (`bg.selected`): the canvas tinted with the accent, as strong as it must be to
    ///   show and no stronger than its text allows.
    /// - Text on any of these: black or white, whichever reads.
    ///
    /// Tokens that don't follow the accent resolve as usual, except that their fallbacks reach the
    /// derived roles.
    func color(_ token: LumenToken, for appearance: LumenAppearance, in registry: LumenRegistry,
               systemAccent: LumenColor) -> LumenColor {
        LumenSystemAccentDerivation(theme: self, appearance: appearance, registry: registry, accent: systemAccent)
            .color(token)
    }

    /// This theme with every system-accent role written out for `light` and `dark` accents: what
    /// the store draws while it follows the macOS accent, as a theme the validator can check.
    func withSystemAccent(light: LumenColor, dark: LumenColor, in registry: LumenRegistry) -> LumenTheme {
        var theme = self
        func derived(_ palette: LumenPalette?, _ appearance: LumenAppearance) -> LumenPalette? {
            guard var palette else { return nil }
            let accent = appearance.isDark ? dark : light
            let derivation = LumenSystemAccentDerivation(theme: self, appearance: appearance, registry: registry, accent: accent)
            for token in registry.systemAccentTokens where registry.spec(for: token)?.followsSystemAccent == true
                || palette[token] == nil {
                palette[token] = derivation.color(token)
            }
            return palette
        }
        theme.light = derived(self.light, .light)
        theme.dark = derived(self.dark, .dark)
        theme.lightHighContrast = derived(lightHighContrast, LumenAppearance(isDark: false, isHighContrast: true))
        theme.darkHighContrast = derived(darkHighContrast, LumenAppearance(isDark: true, isHighContrast: true))
        return theme
    }
}

/// The system-accent rules of `LumenTheme.color(_:for:in:systemAccent:)` for one theme and appearance.
struct LumenSystemAccentDerivation {
    let theme: LumenTheme
    let appearance: LumenAppearance
    let registry: LumenRegistry
    let accent: LumenColor

    /// Everything is measured in the theme's color space, which is also how the store draws derived
    /// colors, so a Display P3 theme is checked as it's drawn.
    private var space: LumenColorSpace { theme.colorSpace }

    private static let white: LumenColor = "#FFFFFF"
    private static let black: LumenColor = "#000000"

    func color(_ token: LumenToken) -> LumenColor {
        theme.color(token, for: appearance, in: registry, resolution: LumenResolution(derive: { derive($0) }))
    }

    /// The theme's own value, with no derivation.
    private func plain(_ token: LumenToken) -> LumenColor { theme.color(token, for: appearance, in: registry) }

    /// A ground as it appears, with the accent roles derived: a translucent one over the ground that
    /// holds it (a sidebar row on the sidebar, a highlight on its menu), as the validator measures it
    /// (`LumenValidator.opaqueGrounds`). A floating ground gives one color per backdrop.
    private func grounds(_ token: LumenToken) -> [LumenColor] {
        LumenValidator.opaqueGrounds(token, in: theme, appearance: appearance, registry: registry,
                                     resolution: LumenResolution(derive: { derive($0) }))
    }

    private func ground(_ token: LumenToken) -> LumenColor { grounds(token)[0] }

    private func derive(_ token: LumenToken) -> LumenColor? {
        guard let spec = registry.spec(for: token) else { return nil }
        if token == .bgSelected { return selection() }
        guard spec.followsSystemAccent else {
            // A tint the theme leaves to its fallback (field.background: 10% of the accent over the
            // sidebar) takes the system accent, thinned if its text would no longer read.
            guard theme.palette(for: theme.normalized(appearance))[token] == nil,
                  case .composite(let base, let alpha, let over)? = spec.fallback else { return nil }
            return tint(color(base), alpha: alpha, over: ground(over), carrying: token)
        }
        switch token {
        case .accentSubtle: return tint(accent, alpha: 0.18, over: plain(.bgCanvas), carrying: token)
        case .accentSoft: return Self.white.composited(alpha: 0.4, over: accent)
        default: break
        }
        if isFilled(token) { return filled() }
        // Text on a solid accent shape (the accent itself, a filled shape): black or white.
        if let onAccent = spec.contrast.first(where: { $0.ground == .accent || isFilled($0.ground) }) {
            return Self.textColor(on: ground(onAccent.ground))
        }
        return adjustedAccent(meeting: registry.contrastRequirements(of: token))
    }

    private func followsAccent(_ token: LumenToken) -> Bool {
        registry.spec(for: token)?.followsSystemAccent == true
            || registry.reaches(Set(registry.specs.filter(\.followsSystemAccent).map(\.token)), from: token)
    }

    private func isFilled(_ token: LumenToken) -> Bool {
        token == .menuHighlight || registry.reaches([.menuHighlight], from: token)
    }

    /// Black or white, whichever reads better on `ground`.
    static func textColor(on ground: LumenColor) -> LumenColor {
        ground.contrastRatio(against: white) >= ground.contrastRatio(against: black) ? white : black
    }

    /// `color` at `alpha` over `ground`, thinned step by step until every foreground required on
    /// `token` (other than the accent family, which adjusts to the tint) reads on it.
    private func tint(_ color: LumenColor, alpha: Double, over ground: LumenColor, carrying token: LumenToken) -> LumenColor {
        let readers = registry.requirements(on: token).filter { !followsAccent($0.foreground) }
            .map { (plain($0.foreground), $0.contrast.minimum) }
        for step in 0...5 {
            let fill = color.composited(alpha: alpha * (1 - Double(step) * 0.2), over: ground)
            if readers.allSatisfy({ $0.0.over(fill).contrastRatio(against: fill, in: space) >= $0.1 }) { return fill }
        }
        return ground
    }

    /// A deep tone of the accent: darkened until white text reads on it, dimmed (82%) and on a
    /// keycap (white at 18% over the fill) included.
    private func filled() -> LumenColor {
        for step in 0...20 {
            let fill = Self.black.composited(alpha: Double(step) * 0.04, over: accent)
            let dimmed = Self.white.composited(alpha: 0.82, over: fill).contrastRatio(against: fill, in: space)
            let keycap = Self.white.composited(alpha: 0.18, over: fill)
            if dimmed >= 4.5, Self.white.contrastRatio(against: keycap, in: space) >= 4.5 { return fill }
        }
        return Self.black.composited(alpha: 0.8, over: accent)
    }

    /// The accent darkened (on light grounds) or lightened (on dark ones) until it meets
    /// `requirements` (grounds resolved with the system accent too). Black and white keep its hue.
    /// The theme's appearance picks the direction tried first; when that can't meet the requirements
    /// (a dark sidebar in a light theme), the other direction is tried, and failing both, the
    /// candidate that comes closest is returned.
    private func adjustedAccent(meeting requirements: [LumenContrast]) -> LumenColor {
        let ink = theme.normalized(appearance).isDark ? Self.white : Self.black
        let pairs = requirements.flatMap { requirement in grounds(requirement.ground).map { ($0, requirement.minimum) } }
        // How far the worst requirement falls short (≤ 1 everywhere means every one is met).
        func shortfall(_ candidate: LumenColor) -> Double {
            pairs.map { $0.1 / candidate.contrastRatio(against: $0.0, in: space) }.max() ?? 0
        }
        var best = (color: ink.composited(alpha: 0.8, over: accent), shortfall: Double.infinity)
        for direction in [ink, ink == Self.white ? Self.black : Self.white] {
            for step in 0...16 {
                let candidate = direction.composited(alpha: Double(step) * 0.05, over: accent)
                let miss = shortfall(candidate)
                if miss <= 1 { return candidate }
                if miss < best.shortfall { best = (candidate, miss) }
            }
        }
        return best.color
    }

    /// The canvas tinted with the accent: the lightest tint that shows against the canvas (1.25:1)
    /// and keeps every foreground required on the selection readable; the theme's own selection if
    /// none does.
    private func selection() -> LumenColor {
        let canvas = plain(.bgCanvas)
        let subtle = color(.accentSubtle)
        let readers = registry.requirements(on: .bgSelected).map { (plain($0.foreground), $0.contrast.minimum) }
        for step in 0...14 {
            let fill = accent.composited(alpha: 0.14 + Double(step) * 0.02, over: canvas)
            guard fill.contrastRatio(against: canvas, in: space) >= 1.25, fill.perceptualDistance(to: subtle, in: space) >= 0.03 else { continue }
            if readers.allSatisfy({ $0.0.contrastRatio(against: fill, in: space) >= $0.1 }) { return fill }
        }
        return plain(.bgSelected)
    }
}

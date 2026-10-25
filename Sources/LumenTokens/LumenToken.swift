/// A named color role, such as `bg.canvas` or `fg.secondary`.
///
/// Tokens are open: Lumen defines the roles every app shares (``LumenToken/bgCanvas`` and
/// friends), and each app adds its own in a ``LumenPack`` (`syntax.keyword`, `listing.selection`,
/// `document.margin`, …). Every token is described by a ``LumenTokenSpec`` in the
/// ``LumenRegistry``, which says what it falls back to, which surface draws it, and what it
/// must contrast with.
public struct LumenToken: RawRepresentable, Hashable, Comparable, Sendable, Codable,
                          ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A part of an app that can use its own theme. Every app has the window; an app can add more,
/// such as MacScope's code editor or a document canvas, and the user can pick a different theme
/// for each. Tokens drawn on a surface resolve through that surface's theme.
public struct LumenSurface: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The app window: sidebars, toolbars, inspectors, sheets.
    public static let window = LumenSurface("window")
}

/// Which variant of a theme applies: the effective appearance plus the system's Increase
/// Contrast setting.
public struct LumenAppearance: Hashable, Sendable, CustomStringConvertible {
    public var isDark: Bool
    public var isHighContrast: Bool

    public init(isDark: Bool, isHighContrast: Bool = false) {
        self.isDark = isDark
        self.isHighContrast = isHighContrast
    }

    public static let light = LumenAppearance(isDark: false)
    public static let dark = LumenAppearance(isDark: true)
    public static let all: [LumenAppearance] = [false, true].flatMap { dark in
        [false, true].map { LumenAppearance(isDark: dark, isHighContrast: $0) }
    }

    public var description: String { (isDark ? "dark" : "light") + (isHighContrast ? "+contrast" : "") }
}

/// How serious a validation finding is. Errors mean something will be hard to read; warnings
/// flag things that are easy to miss.
public enum LumenSeverity: Sendable, Hashable { case error, warning }

/// A contrast requirement for a foreground token on one background.
public struct LumenContrast: Sendable, Hashable {
    public var ground: LumenToken
    public var minimum: Double
    public var severity: LumenSeverity

    public init(on ground: LumenToken, minimum: Double, severity: LumenSeverity = .error) {
        self.ground = ground
        self.minimum = minimum
        self.severity = severity
    }

    /// WCAG AA for text: 4.5:1.
    public static func text(on ground: LumenToken) -> LumenContrast { .init(on: ground, minimum: 4.5) }
    /// WCAG non-text contrast for icons, rules and focus rings: 3:1.
    public static func graphic(on ground: LumenToken, severity: LumenSeverity = .error) -> LumenContrast {
        .init(on: ground, minimum: 3, severity: severity)
    }
}

/// What a component token uses when a theme leaves it out.
public enum LumenFallback: Sendable, Hashable {
    /// Another token's value.
    case token(LumenToken)
    /// Another token laid translucently over a third: the look of a tint, resolved to an opaque
    /// color the validator can check.
    case composite(LumenToken, alpha: Double, over: LumenToken)

    public var base: LumenToken {
        switch self {
        case .token(let token), .composite(let token, _, _): token
        }
    }

    /// Every token the fallback is built from.
    public var bases: [LumenToken] {
        switch self {
        case .token(let token): [token]
        case .composite(let token, _, let over): [token, over]
        }
    }

    public var description: String {
        switch self {
        case .token(let token): token.rawValue
        case .composite(let token, let alpha, let over):
            "\(token.rawValue) at \(Int((alpha * 100).rounded()))% over \(over.rawValue)"
        }
    }
}

/// Everything Lumen knows about one token.
public struct LumenTokenSpec: Sendable, Hashable {
    public var token: LumenToken
    /// The section it is listed under in the theme editor and the token reference.
    public var group: String
    /// `nil` for a semantic role, which every complete theme defines.
    public var fallback: LumenFallback?
    /// The surface whose theme supplies it.
    public var surface: LumenSurface
    /// Contrast this token must reach as a foreground.
    public var contrast: [LumenContrast]
    /// Accent-family roles follow the macOS accent color when the app turns that on.
    public var followsSystemAccent: Bool
    public var summary: String

    public init(_ token: LumenToken, group: String, fallback: LumenFallback? = nil, surface: LumenSurface = .window,
                contrast: [LumenContrast] = [], followsSystemAccent: Bool = false, summary: String = "") {
        self.token = token
        self.group = group
        self.fallback = fallback
        self.surface = surface
        self.contrast = contrast
        self.followsSystemAccent = followsSystemAccent
        self.summary = summary
    }

    public var isComponent: Bool { fallback != nil }

    /// Drawn as text or a glyph over a ground: it has contrast requirements. Such tokens must be
    /// opaque, because a ratio between colors can't establish that translucent glyphs are readable.
    /// The validator rejects translucent values and the theme editor offers no opacity for them.
    public var isForeground: Bool { !contrast.isEmpty }
}

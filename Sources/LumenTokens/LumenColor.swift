import Foundation

/// A color written as `#RRGGBB` or `#RRGGBBAA`, with the math Lumen's checks need: WCAG contrast,
/// OKLab distance and alpha compositing.
public struct LumenColor: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`. The `#` is optional here (code literals); theme files
    /// require it (see `init(from:)`).
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        red = Double((rgb >> 16) & 0xFF) / 255
        green = Double((rgb >> 8) & 0xFF) / 255
        blue = Double(rgb & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }

    public init(stringLiteral value: String) {
        guard let parsed = LumenColor(hex: value) else { preconditionFailure("Invalid color literal \(value)") }
        self = parsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard string.hasPrefix("#"), let parsed = LumenColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected #RRGGBB or #RRGGBBAA, got \(string)")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    public var hexString: String {
        func byte(_ component: Double) -> String { String(format: "%02X", Int((component * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    public var description: String { hexString }

    // MARK: Contrast

    /// The sRGB transfer function, which Display P3 shares; extended to components outside 0…1
    /// (a P3 color converted to sRGB) by mirroring it through zero.
    private static func linear(_ c: Double) -> Double {
        let m = abs(c)
        let value = m <= 0.04045 ? m / 12.92 : pow((m + 0.055) / 1.055, 2.4)
        return c < 0 ? -value : value
    }

    /// Linear-light sRGB components of this color's components read in `space`. Display P3's wider
    /// colors come out below 0 or above 1.
    private func linearSRGB(in space: LumenColorSpace) -> (r: Double, g: Double, b: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        switch space {
        case .sRGB: return (r, g, b)
        case .displayP3:
            // Display P3 (D65) to sRGB (D65), linear light.
            return (1.2249401763 * r - 0.2249401763 * g,
                    -0.0420569547 * r + 1.0420569547 * g,
                    -0.0196375546 * r - 0.0786360456 * g + 1.0982736002 * b)
        }
    }

    /// WCAG 2.x relative luminance, treating the components as sRGB.
    public var relativeLuminance: Double { relativeLuminance(in: .sRGB) }

    /// WCAG 2.x relative luminance of the components as `space` defines them: a Display P3
    /// theme's `#ED0000` is a deeper red than sRGB's, and measures darker.
    public func relativeLuminance(in space: LumenColorSpace) -> Double {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        switch space {
        case .sRGB: return 0.2126 * r + 0.7152 * g + 0.0722 * b
        // The Y row of Display P3's RGB-to-XYZ (D65) matrix.
        case .displayP3: return 0.2289745641 * r + 0.6917385218 * g + 0.0792869141 * b
        }
    }

    /// WCAG 2.x contrast ratio, from 1 to 21, treating both colors as sRGB.
    public func contrastRatio(against other: LumenColor) -> Double { contrastRatio(against: other, in: .sRGB) }

    /// WCAG 2.x contrast ratio with both colors' components in `space`.
    public func contrastRatio(against other: LumenColor, in space: LumenColorSpace) -> Double {
        let a = relativeLuminance(in: space), b = other.relativeLuminance(in: space)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: Perceptual distance

    /// The color in OKLab (L, a, b), treating the components as sRGB.
    public var oklab: (l: Double, a: Double, b: Double) { oklab(in: .sRGB) }

    /// The color in OKLab (L, a, b), with the components in `space`.
    public func oklab(in space: LumenColorSpace) -> (l: Double, a: Double, b: Double) {
        let (r, g, b) = linearSRGB(in: space)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Euclidean distance in OKLab, treating both colors as sRGB. About 0.02 is a just-noticeable
    /// difference; colors that must be told apart at a glance want 0.06 or more.
    public func perceptualDistance(to other: LumenColor) -> Double { perceptualDistance(to: other, in: .sRGB) }

    /// Euclidean distance in OKLab with both colors' components in `space`.
    public func perceptualDistance(to other: LumenColor, in space: LumenColorSpace) -> Double {
        let p = oklab(in: space), q = other.oklab(in: space)
        return ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }

    /// This color at `alpha` (times its own) laid over `background`: what a translucent tint
    /// actually looks like. The result keeps the background's opacity; for a translucent background
    /// use `over(_:)`, which composites coverage too.
    public func composited(alpha: Double, over background: LumenColor) -> LumenColor {
        let a = alpha * self.alpha
        return LumenColor(red: red * a + background.red * (1 - a),
                          green: green * a + background.green * (1 - a),
                          blue: blue * a + background.blue * (1 - a),
                          alpha: background.alpha)
    }

    /// This color, at its own opacity, laid over `background` (Porter–Duff source-over, in the
    /// encoded components as the window server blends them). Over an opaque background the result
    /// is opaque; over a translucent one it keeps the coverage of both.
    public func over(_ background: LumenColor) -> LumenColor {
        // The exact cases first, so an opaque result has an alpha of exactly 1.
        if alpha >= 1 { return self }
        if background.alpha >= 1 { return composited(alpha: 1, over: background) }
        let a = alpha, under = background.alpha * (1 - alpha)
        let out = a + under
        guard out > 0 else { return LumenColor(red: 0, green: 0, blue: 0, alpha: 0) }
        func blend(_ top: Double, _ bottom: Double) -> Double { (top * a + bottom * under) / out }
        return LumenColor(red: blend(red, background.red), green: blend(green, background.green),
                          blue: blend(blue, background.blue), alpha: out)
    }
}

/// The color space a theme's hex values are written in.
public enum LumenColorSpace: String, Codable, Sendable {
    case sRGB = "srgb"
    case displayP3 = "display-p3"
}

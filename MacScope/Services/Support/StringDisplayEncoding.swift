import Foundation

/// How the bytes of a string literal (or a marked string region) are *interpreted and
/// displayed* in the listing. This is a presentation preference — it never changes which
/// bytes are stored or how an instruction is decoded, only how a run of bytes is turned
/// into the human-readable quoted text in a `.asciz`/`.ascii` directive.
///
/// The default is `.utf8`, which reproduces the prior C-string renderer byte-for-byte
/// (printable ASCII shown literally, the standard C escapes for control characters and
/// quotes, `\xNN` for anything else). The other modes reinterpret the same bytes:
/// `.ascii` is strict 7-bit (the high-bit range becomes `\xNN`), `.utf16le` pairs bytes
/// into 16-bit code units, and `.hex` abandons text entirely and shows the raw bytes.
enum StringDisplayEncoding: String, CaseIterable, Identifiable, Codable {
    case utf8
    case ascii
    case utf16le
    case hex

    var id: String { rawValue }

    /// The shipped default. `.utf8` reproduces the historical renderer exactly, so an
    /// un-configured app renders strings unchanged.
    static let `default` = StringDisplayEncoding.utf8

    /// The `UserDefaults`/`@AppStorage` key. One source of truth so Settings and the
    /// rendering path can't drift on the literal.
    static let storageKey = "stringDisplayEncoding"

    var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .ascii: return "ASCII (7-bit)"
        case .utf16le: return "UTF-16 (LE)"
        case .hex: return "Hex bytes"
        }
    }

    /// Resolves the stored raw string into a case, defaulting to `.utf8` for an absent or
    /// unrecognised value (a corrupt/hostile preference can never crash the renderer).
    static func resolve(_ raw: String?) -> StringDisplayEncoding {
        guard let raw, let value = StringDisplayEncoding(rawValue: raw) else { return .default }
        return value
    }

    /// Reads the preference from a `UserDefaults` (a missing key → the default).
    static func read(from defaults: UserDefaults) -> StringDisplayEncoding {
        resolve(defaults.string(forKey: storageKey))
    }

    /// Renders a run of string bytes into the displayed (already-escaped) text under this
    /// encoding. `stopAtNUL` mirrors the C-string contract: a NUL-terminated shape stops at
    /// the first zero byte; a fixed-length shape renders the whole span. Pure and
    /// allocation-light so the whole string path stays unit-testable.
    ///
    /// - `.utf8`/`.ascii`: byte-at-a-time. Printable ASCII (`0x20..<0x7F`) renders
    ///   literally; the standard C escapes cover the common control chars and quotes;
    ///   everything else is `\xNN`. `.ascii` differs only in that `0x80...0xFF` is forced to
    ///   `\xNN` (so a stray high byte never renders as Latin-1 garbage).
    /// - `.utf16le`: consumes two bytes per code unit (little-endian). An odd trailing byte
    ///   renders as `\xNN`. A NUL *code unit* (both bytes zero) terminates when `stopAtNUL`.
    /// - `.hex`: every byte as `NN`, space-separated — no text interpretation at all. NUL is
    ///   shown like any other byte (a hex dump has no concept of a terminator) unless
    ///   `stopAtNUL`, in which case the first `00` ends the run, matching the C-string cap.
    func render(bytes: [UInt8], stopAtNUL: Bool) -> String {
        switch self {
        case .utf8, .ascii:
            return renderByteText(bytes: bytes, stopAtNUL: stopAtNUL, asciiOnly: self == .ascii)
        case .utf16le:
            return renderUTF16LE(bytes: bytes, stopAtNUL: stopAtNUL)
        case .hex:
            return renderHex(bytes: bytes, stopAtNUL: stopAtNUL)
        }
    }

    private func renderByteText(bytes: [UInt8], stopAtNUL: Bool, asciiOnly: Bool) -> String {
        var result = ""
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            if stopAtNUL, byte == 0 { break }
            switch byte {
            case 0x00: result += "\\0"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\"" // "
            case 0x5C: result += "\\\\" // backslash
            case 0x20..<0x7F: result.append(Character(UnicodeScalar(byte)))
            default:
                // `.utf8` mode keeps high bytes as raw `\xNN` too (the historical renderer
                // never decoded multibyte UTF-8 sequences), so utf8 and ascii agree here;
                // the cases are kept distinct for intent and future divergence.
                _ = asciiOnly
                result += "\\x" + Self.hexByte(byte)
            }
        }
        return result
    }

    private func renderUTF16LE(bytes: [UInt8], stopAtNUL: Bool) -> String {
        var result = ""
        result.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            index += 2
            if stopAtNUL, unit == 0 { return result }
            switch unit {
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x20..<0x7F: result.append(Character(UnicodeScalar(UInt8(unit))))
            default:
                if let scalar = UnicodeScalar(unit), unit >= 0x80 {
                    result.append(Character(scalar))
                } else {
                    result += "\\u" + Self.hexUnit(unit)
                }
            }
        }
        // A dangling odd byte (the buffer wasn't an even number of bytes) renders as raw hex.
        if index < bytes.count, !(stopAtNUL && bytes[index] == 0) {
            result += "\\x" + Self.hexByte(bytes[index])
        }
        return result
    }

    private func renderHex(bytes: [UInt8], stopAtNUL: Bool) -> String {
        var parts: [String] = []
        parts.reserveCapacity(bytes.count)
        for byte in bytes {
            if stopAtNUL, byte == 0 { break }
            parts.append(Self.hexByte(byte))
        }
        return parts.joined(separator: " ")
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
    }

    private static func hexUnit(_ unit: UInt16) -> String {
        let digits = Array("0123456789abcdef")
        return String([
            digits[Int((unit >> 12) & 0xf)],
            digits[Int((unit >> 8) & 0xf)],
            digits[Int((unit >> 4) & 0xf)],
            digits[Int(unit & 0xf)]
        ])
    }
}

import Foundation

/// Fast formatting of a raw byte buffer to the space-separated lowercase hex used throughout the
/// listing (`[0xfd, 0x7b] -> "fd 7b"`). This is a hot path: the decode pass materializes the hex
/// `bytes` text for EVERY instruction (168k+ on a large binary), and the idiomatic
/// `bytes.map { String(format: "%02x", $0) }.joined(separator: " ")` is dominated by
/// `String(format:)`'s per-byte NSString/CVarArg overhead. A manual nibble→ASCII fill into one
/// pre-sized buffer is ~10–50× faster and allocates once instead of per byte.
///
/// The output is byte-identical to the `%02x`-join idiom it replaces: lowercase, zero-padded,
/// two digits per byte, single-space separated, no leading/trailing space, empty for empty input.
enum HexByteFormatter {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    /// `"fd 7b bf a9"` — lowercase, space-separated. Empty string for empty input.
    static func spacedHex(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        // Each byte is 2 hex digits; a single space sits between adjacent bytes.
        var ascii = [UInt8]()
        ascii.reserveCapacity(bytes.count * 3 - 1)
        var first = true
        for byte in bytes {
            if first { first = false } else { ascii.append(0x20) /* space */ }
            ascii.append(digits[Int(byte >> 4)])
            ascii.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: ascii, as: UTF8.self)
    }
}

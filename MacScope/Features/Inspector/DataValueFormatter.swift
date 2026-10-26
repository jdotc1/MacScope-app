import Foundation

/// The byte order used to assemble a multi-byte integer/float from raw bytes.
/// Pure model (no SwiftUI) with a stable `rawValue` so a control can persist it.
enum DataByteOrder: String, CaseIterable, Identifiable, Equatable {
    case little
    case big

    var id: String { rawValue }

    /// Human-facing label, e.g. "Little-endian".
    var displayName: String {
        switch self {
        case .little: return "Little-endian"
        case .big: return "Big-endian"
        }
    }

    /// Short label for a compact toggle, e.g. "LE".
    var shortName: String {
        switch self {
        case .little: return "LE"
        case .big: return "BE"
        }
    }
}

/// The numeric base a decoded integer is rendered in.
enum DataRadix: String, CaseIterable, Identifiable, Equatable {
    case hex
    case decimal
    case octal
    case binary

    var id: String { rawValue }

    /// Human-facing label, e.g. "Hexadecimal".
    var displayName: String {
        switch self {
        case .hex: return "Hexadecimal"
        case .decimal: return "Decimal"
        case .octal: return "Octal"
        case .binary: return "Binary"
        }
    }

    /// The `String(_:radix:)` base.
    var base: Int {
        switch self {
        case .hex: return 16
        case .decimal: return 10
        case .octal: return 8
        case .binary: return 2
        }
    }

    /// The conventional literal prefix for the radix (empty for decimal).
    var prefix: String {
        switch self {
        case .hex: return "0x"
        case .decimal: return ""
        case .octal: return "0o"
        case .binary: return "0b"
        }
    }
}

/// Whether an integer interpretation treats the high bit as a sign.
enum DataSignedness: String, CaseIterable, Identifiable, Equatable {
    case signed
    case unsigned

    var id: String { rawValue }

    /// Human-facing label, e.g. "Signed".
    var displayName: String {
        switch self {
        case .signed: return "Signed"
        case .unsigned: return "Unsigned"
        }
    }
}

/// The width (in bytes) of an integer interpretation.
enum DataIntegerWidth: Int, CaseIterable, Identifiable, Equatable {
    case int8 = 1
    case int16 = 2
    case int32 = 4
    case int64 = 8

    var id: Int { rawValue }

    /// The number of bytes the width consumes.
    var byteCount: Int { rawValue }

    /// A bare width label, e.g. "16".
    var bitLabel: String { "\(rawValue * 8)" }

    /// The signed label for a width, e.g. "Int16".
    var signedLabel: String { "Int\(rawValue * 8)" }

    /// The unsigned label for a width, e.g. "UInt16".
    var unsignedLabel: String { "UInt\(rawValue * 8)" }
}

/// The user-chosen value-formatting options applied to the data inspector's
/// multi-width interpretation. A pure value type so the SwiftUI controls just
/// bind to it and the rendering stays unit-testable.
struct DataValueFormatOptions: Equatable {
    var byteOrder: DataByteOrder
    var radix: DataRadix
    var signedness: DataSignedness

    init(
        byteOrder: DataByteOrder = .little,
        radix: DataRadix = .decimal,
        signedness: DataSignedness = .signed
    ) {
        self.byteOrder = byteOrder
        self.radix = radix
        self.signedness = signedness
    }
}

/// Pure, GUI-free rendering of the bytes at an offset into multi-width integer and
/// floating-point interpretations, honoring endianness, radix, and signedness.
///
/// All multi-byte assembly is done with explicit byte shifts (never an unaligned
/// pointer load), and every read is range-checked against the byte count *before*
/// any index arithmetic, so a short or out-of-range window simply yields `nil` for
/// the widths that don't fit rather than trapping. The 64-bit delta math that maps
/// an address to an offset is guarded against `UInt64 -> Int` overflow, matching the
/// hardening in `DataInspectorReading`/`HexNavigationState`.
struct DataValueFormatter: Equatable {
    let bytes: Data
    let offset: Int?
    let options: DataValueFormatOptions

    init(bytes: Data, offset: Int?, options: DataValueFormatOptions) {
        self.bytes = bytes
        self.offset = offset
        self.options = options
    }

    /// Convenience initializer that resolves the byte offset from a base/selected
    /// address pair using the same overflow-guarded arithmetic as
    /// `DataInspectorReading`.
    init(
        bytes: Data,
        baseAddress: UInt64?,
        selectedAddress: UInt64?,
        options: DataValueFormatOptions
    ) {
        self.init(
            bytes: bytes,
            offset: Self.byteOffset(
                byteCount: bytes.count,
                baseAddress: baseAddress,
                selectedAddress: selectedAddress
            ),
            options: options
        )
    }

    /// Maps a base/selected address pair to a byte offset, guarding the 64-bit
    /// subtraction against `Int` overflow and bounding the result to the window.
    static func byteOffset(
        byteCount: Int,
        baseAddress: UInt64?,
        selectedAddress: UInt64?
    ) -> Int? {
        guard byteCount > 0,
              let baseAddress,
              let selectedAddress,
              selectedAddress >= baseAddress
        else { return nil }
        let delta = selectedAddress - baseAddress
        guard delta <= UInt64(Int.max) else { return nil }
        let offset = Int(delta)
        guard offset >= 0, offset < byteCount else { return nil }
        return offset
    }

    var isResolvable: Bool { offset != nil }

    // MARK: - Raw bit-pattern assembly

    /// Assembles `count` bytes starting at the offset into an unsigned 64-bit bit
    /// pattern, honoring the byte order. Returns nil when fewer than `count`
    /// trailing bytes are available.
    func bitPattern(byteCount count: Int) -> UInt64? {
        guard let offset, count > 0, count <= 8 else { return nil }
        // Range-check BEFORE the index math so a short window never traps.
        guard offset >= 0, offset <= bytes.count - count else { return nil }
        let start = bytes.startIndex + offset
        var value: UInt64 = 0
        for index in 0..<count {
            let byte = bytes[start + index]
            let shift: Int
            switch options.byteOrder {
            case .little: shift = 8 * index
            case .big: shift = 8 * (count - 1 - index)
            }
            value |= UInt64(byte) << shift
        }
        return value
    }

    // MARK: - Integer rendering

    /// Renders the integer of `width` under the current options, or nil when the
    /// bytes don't fit.
    func integer(width: DataIntegerWidth) -> String? {
        guard let pattern = bitPattern(byteCount: width.byteCount) else { return nil }
        switch options.signedness {
        case .unsigned:
            // Mask the pattern to the width so a narrow read never shows stray high bits.
            let magnitude = Self.mask(pattern, byteCount: width.byteCount)
            return render(magnitude: magnitude, negative: false)
        case .signed:
            let (negative, magnitude) = Self.signedMagnitude(pattern, byteCount: width.byteCount)
            return render(magnitude: magnitude, negative: negative)
        }
    }

    /// The label/value rows for all four integer widths that fit, labeled per the
    /// current signedness.
    var integerRows: [(label: String, value: String)] {
        guard isResolvable else { return [] }
        var rows: [(label: String, value: String)] = []
        for width in DataIntegerWidth.allCases {
            guard let value = integer(width: width) else { continue }
            let label = options.signedness == .signed ? width.signedLabel : width.unsignedLabel
            rows.append((label: label, value: value))
        }
        return rows
    }

    // MARK: - Floating-point rendering

    /// The 32-bit float decoded from the bit pattern, rendered in its natural
    /// decimal form (radix/signedness do not apply to floats). Nil when the bytes
    /// don't fit.
    var float32: String? {
        bitPattern(byteCount: 4).map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }.map { String($0) }
    }

    /// The 64-bit double decoded from the bit pattern. Nil when the bytes don't fit.
    var double64: String? {
        bitPattern(byteCount: 8).map { Double(bitPattern: $0) }.map { String($0) }
    }

    /// The float/double rows that fit (always rendered decimal).
    var floatingPointRows: [(label: String, value: String)] {
        guard isResolvable else { return [] }
        var rows: [(label: String, value: String)] = []
        if let float32 { rows.append((label: "Float", value: float32)) }
        if let double64 { rows.append((label: "Double", value: double64)) }
        return rows
    }

    /// The full ordered set of decoded rows: integers (per signedness) then floats.
    var rows: [(label: String, value: String)] {
        integerRows + floatingPointRows
    }

    // MARK: - Pure numeric helpers

    /// Masks a 64-bit pattern down to `byteCount` low bytes (8 bytes is a no-op).
    static func mask(_ pattern: UInt64, byteCount: Int) -> UInt64 {
        guard byteCount < 8 else { return pattern }
        let bits = byteCount * 8
        // bits is 8/16/24/.../56 here, so the shift never reaches 64 (no UB).
        let m = (UInt64(1) << bits) - 1
        return pattern & m
    }

    /// Interprets the low `byteCount` bytes of `pattern` as a two's-complement
    /// signed integer and returns its sign + absolute magnitude. The magnitude is a
    /// `UInt64` so the most-negative value (whose magnitude overflows the signed
    /// range) is represented exactly without a trap.
    static func signedMagnitude(_ pattern: UInt64, byteCount: Int) -> (negative: Bool, magnitude: UInt64) {
        let masked = mask(pattern, byteCount: byteCount)
        let bits = byteCount * 8
        let signBit: UInt64 = bits >= 64 ? (UInt64(1) << 63) : (UInt64(1) << (bits - 1))
        let isNegative = (masked & signBit) != 0
        if !isNegative {
            return (false, masked)
        }
        // Two's-complement magnitude: (~masked + 1) masked back to the width.
        // Using wrapping ops so the most-negative value (e.g. 0x80) yields its true
        // magnitude (0x80) rather than trapping.
        let negated = mask((~masked) &+ 1, byteCount: byteCount)
        return (true, negated)
    }

    /// Renders an unsigned magnitude with an optional minus sign in the current
    /// radix, applying the conventional prefix.
    private func render(magnitude: UInt64, negative: Bool) -> String {
        let digits = String(magnitude, radix: options.radix.base, uppercase: false)
        let sign = negative ? "-" : ""
        return "\(sign)\(options.radix.prefix)\(digits)"
    }
}

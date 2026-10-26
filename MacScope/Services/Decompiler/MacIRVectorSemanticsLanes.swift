import Foundation

// MARK: - MacIRNEONLaneOp

/// One Advanced SIMD integer lane operation admitted per decoded row. This is
/// the general per-instruction vocabulary the D06 region path composes; it
/// never describes an instruction mix, register set or function length.
///
/// Arguments are always ordered Vn, Vm (when the form has one), then OLD Vd
/// when `readsDestination` (accumulate, or the preserved low half of a `2`
/// narrowing form). Callers snapshot every input before the destination write.
public struct MacIRNEONLaneOp: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        // Long: wide lanes from two narrow halves.
        case mull, mlal, mlsl, addl, subl, abdl, abal
        // Wide: wide lanes from one wide and one narrow half.
        case addw, subw
        // Shift-left-long (UXTL/SXTL are shift 0).
        case shll
        // Narrowing right shifts of wide lanes.
        case shrn, rshrn, sqshrn, sqrshrn, xtn
        // High-half add/subtract, optionally rounded, from two wide vectors.
        case addhn, raddhn, subhn, rsubhn
        // Same-width forms.
        case add, sub, not, mul, mla, mls, addp, bif
        case cmeq, cmgt, cmge, cmhi, cmhs, cmtst
        case neg, abs
        // Compare each signed lane with zero; true lanes are all ones.
        case cmeqz, cmgez, cmgtz, cmlez, cmltz
        // Variable shift by the signed low byte of each Vm lane.
        case ushl, sshl
        // Immediate logical left / signed rounding right shifts.
        case shl, srshr, sqshlu, ushr, sshr, urshr, usra, ssra, ursra, srsra, sri
        case uzp1, uzp2, zip1, zip2, trn1, trn2
        // Signed saturating doubling multiply returning the high half; sets QC.
        case sqdmulh, sqrdmulh
        // Signed wide lanes to unsigned narrow lanes, saturating; sets QC.
        case sqxtun
        // Broadcast the low lane bits of a general register.
        case dup

        var shape: Shape {
            switch self {
            case .mull, .mlal, .mlsl, .addl, .subl, .abdl, .abal: return .long
            case .addw, .subw: return .wide
            case .shll: return .shiftLong
            case .shrn, .rshrn, .sqshrn, .sqrshrn, .xtn, .sqxtun: return .narrow
            case .addhn, .raddhn, .subhn, .rsubhn: return .binaryNarrow
            case .add, .sub, .not, .mul, .mla, .mls, .addp, .bif, .cmeq, .cmgt, .cmge, .cmhi, .cmhs, .cmtst, .neg, .abs, .cmeqz, .cmgez, .cmgtz, .cmlez, .cmltz,
                 .ushl, .sshl, .shl, .srshr, .sqshlu, .ushr, .sshr, .urshr, .usra, .ssra, .ursra, .srsra, .sri, .uzp1, .uzp2, .zip1, .zip2, .trn1, .trn2, .sqdmulh, .sqrdmulh, .dup: return .same
            }
        }
    }

    enum Shape { case long, wide, shiftLong, narrow, binaryNarrow, same }

    public let kind: Kind
    public let isSigned: Bool
    /// Narrow lane width for long/wide/shift-long/narrow forms; the lane width
    /// for same-width forms.
    public let laneBits: Int
    /// The `2` variant: narrow sources come from, or the narrow result goes to,
    /// the upper 64 bits.
    public let highHalf: Bool
    /// Same-width forms: 8 (upper 64 bits zeroed) or 16. Others are fixed.
    public let activeBytes: Int
    public let shift: Int
    /// By-element forms: every lane uses this lane of Vm.
    public let elementIndex: Int?

    public init?(kind: Kind, isSigned: Bool, laneBits: Int, highHalf: Bool,
                 activeBytes: Int = 16, shift: Int = 0, elementIndex: Int? = nil) {
        if let elementIndex {
            // DUP by element broadcasts one lane of any width; the multiply forms
            // index 16- or 32-bit lanes.
            guard kind == .dup ? [8, 16, 32, 64].contains(laneBits)
                    : [.sqdmulh, .sqrdmulh, .mul, .mla, .mls, .mull, .mlal, .mlsl].contains(kind) && [16, 32].contains(laneBits),
                  (0..<(128 / laneBits)).contains(elementIndex) else { return nil }
        }
        if kind == .sqdmulh || kind == .sqrdmulh { guard [16, 32].contains(laneBits) else { return nil } }
        switch kind.shape {
        case .long, .wide, .shiftLong:
            guard [8, 16, 32].contains(laneBits), activeBytes == 16 else { return nil }
            if kind == .shll {
                guard (0..<laneBits).contains(shift) else { return nil }
            } else if shift != 0 { return nil }
        case .binaryNarrow:
            guard [8, 16, 32].contains(laneBits), !isSigned, activeBytes == 16,
                  shift == 0, elementIndex == nil else { return nil }
        case .narrow:
            // Scalar SQXTUN (`sqxtun b0, h1`) narrows one lane and zeroes the rest.
            let scalarNarrow = kind == .sqxtun && !highHalf && activeBytes * 8 == laneBits
            guard [8, 16, 32].contains(laneBits), !isSigned, activeBytes == 16 || scalarNarrow,
                  (kind == .sqxtun || kind == .xtn) ? shift == 0 : (1...laneBits).contains(shift) else { return nil }
        case .same:
            // Scalar forms write one lane and zero the rest: DUP by element
            // (`mov b0, v1.b[3]`) and SQ(R)DMULH (`sqrdmulh h0, h1, h2|v2.h[i]`).
            let scalarDup = activeBytes * 8 == laneBits
                && (kind == .dup ? elementIndex != nil : [.sqdmulh, .sqrdmulh].contains(kind))
            guard !highHalf, !isSigned, [8, 16].contains(activeBytes) || scalarDup,
                  [8, 16, 32, 64].contains(laneBits),
                  !(laneBits == 64 && activeBytes == 8) || scalarDup,
                  ![.not, .bif].contains(kind) || laneBits == 8,
                  ![.mul, .mla, .mls].contains(kind) || laneBits < 64 else { return nil }
            guard kind == .shl || kind == .sqshlu ? (0..<laneBits).contains(shift)
                : [.srshr, .ushr, .sshr, .urshr, .usra, .ssra, .ursra, .srsra, .sri].contains(kind)
                    ? (1...laneBits).contains(shift) : shift == 0 else { return nil }
        }
        self.kind = kind; self.isSigned = isSigned; self.laneBits = laneBits
        self.highHalf = highHalf; self.activeBytes = activeBytes; self.shift = shift
        self.elementIndex = elementIndex
    }

    /// The instruction updates sticky FPSR.QC when any lane saturates.
    public var setsQC: Bool { [.sqdmulh, .sqrdmulh, .sqxtun, .sqshlu, .sqshrn, .sqrshrn].contains(kind) }

    public var readsDestination: Bool {
        switch kind {
        case .mlal, .mlsl, .abal, .mla, .mls, .bif, .usra, .ssra, .ursra, .srsra, .sri: return true
        case .shrn, .rshrn, .sqshrn, .sqrshrn, .xtn, .sqxtun, .addhn, .raddhn, .subhn, .rsubhn: return highHalf
        default: return false
        }
    }

    public var sourceCount: Int {
        switch kind.shape {
        case .shiftLong, .narrow: return 1
        case .same:
            // DUP from a GPR broadcasts its one source (DP11: was arity 2 vs 1 argument).
            return [.not, .neg, .abs, .cmeqz, .cmgez, .cmgtz, .cmlez, .cmltz, .shl, .srshr, .sqshlu, .ushr, .sshr, .urshr, .usra, .ssra, .ursra, .srsra, .sri, .dup].contains(kind) ? 1 : 2
        case .long, .wide, .binaryNarrow: return 2
        }
    }

    public var arity: Int { sourceCount + (readsDestination ? 1 : 0) }

    /// Self-describing name: mnemonic, then destination and source arrangements,
    /// then what happens to bits the result does not define.
    public var intrinsicName: String {
        func arrangement(_ bits: Int, _ bytes: Int) -> String {
            let suffix = [8: "b", 16: "h", 32: "s", 64: "d"][bits]!
            return "\(bytes * 8 / bits)\(suffix)"
        }
        let narrowBytes = highHalf ? 16 : 8
        let prefix = kind.shape == .same || kind.shape == .narrow || kind.shape == .binaryNarrow ? "" : (isSigned ? "s" : "u")
        let mnemonic = prefix + kind.rawValue + (highHalf ? "2" : "")
        switch kind.shape {
        case .long, .shiftLong:
            let shiftText = kind == .shll ? "_shift\(shift)" : ""
            let lane = elementIndex.map { "_by_lane\($0)" } ?? ""
            return "neon_\(mnemonic)_\(arrangement(laneBits * 2, 16))_from_\(arrangement(laneBits, narrowBytes))\(shiftText)\(lane)"
        case .wide:
            return "neon_\(mnemonic)_\(arrangement(laneBits * 2, 16))_from_\(arrangement(laneBits * 2, 16))_\(arrangement(laneBits, narrowBytes))"
        case .binaryNarrow:
            let mode = highHalf ? "keep_low64" : "zero_high64"
            return "neon_\(mnemonic)_\(arrangement(laneBits, narrowBytes))_from_\(arrangement(laneBits * 2, 16))_\(arrangement(laneBits * 2, 16))_\(mode)"
        case .narrow:
            if activeBytes * 8 == laneBits {
                return "neon_\(mnemonic)_\(arrangement(laneBits, laneBits / 8))_from_\(arrangement(laneBits * 2, laneBits / 4))_zero_upper"
            }
            let mode = highHalf ? "keep_low64" : "zero_high64"
            let shiftText = kind == .sqxtun || kind == .xtn ? "" : "_shift\(shift)"
            return "neon_\(mnemonic)_\(arrangement(laneBits, narrowBytes))_from_\(arrangement(laneBits * 2, 16))\(shiftText)_\(mode)"
        case .same:
            let lane = elementIndex.map { "_by_lane\($0)" } ?? ""
            let amount = [.shl, .srshr, .sqshlu, .ushr, .sshr, .urshr, .usra, .ssra, .ursra, .srsra, .sri].contains(kind) ? "_shift\(shift)" : ""
            return "neon_\(kind.rawValue)_\(arrangement(laneBits, activeBytes))\(lane)\(amount)"
                + (activeBytes == 8 ? "_zero_high64" : activeBytes < 8 ? "_zero_upper" : "")
        }
    }

    public typealias Vector = (low: UInt64, high: UInt64)

    private static func mask(_ bits: Int) -> UInt64 { bits == 64 ? .max : (UInt64(1) << bits) - 1 }

    private static func lane(_ value: Vector, bits: Int, index: Int) -> UInt64 {
        let offset = index * bits
        return ((offset < 64 ? value.low : value.high) >> UInt64(offset % 64)) & mask(bits)
    }

    private static func set(_ value: inout Vector, bits: Int, index: Int, lane: UInt64) {
        let offset = index * bits, position = UInt64(offset % 64)
        let field = (lane & mask(bits)) << position
        let clear = ~(mask(bits) << position)
        if offset < 64 { value.low = (value.low & clear) | field } else { value.high = (value.high & clear) | field }
    }

    /// Extend a narrow lane to Int64 (exact for every admitted width).
    private func extend(_ raw: UInt64, bits: Int) -> Int64 {
        guard isSigned, bits < 64, raw & (UInt64(1) << UInt64(bits - 1)) != 0 else { return Int64(bitPattern: raw) }
        return Int64(bitPattern: raw | ~Self.mask(bits))
    }

    /// Signed wide input shifted with optional round-before-saturate. Splitting
    /// quotient and rounding bit avoids overflowing a 64-bit input plus bias.
    private func signedNarrowInput(_ raw: UInt64) -> Int64 {
        let bits = laneBits * 2
        let signed = bits == 64 || raw & (UInt64(1) << (bits - 1)) == 0
            ? Int64(bitPattern: raw) : Int64(bitPattern: raw | ~Self.mask(bits))
        return (signed >> shift) + (kind == .sqrshrn ? Int64((raw >> (shift - 1)) & 1) : 0)
    }

    public func evaluate(n: Vector, m: Vector = (0, 0), oldDestination d: Vector = (0, 0)) -> Vector {
        let narrowCount = kind.shape == .narrow && activeBytes * 8 == laneBits ? 1 : 64 / laneBits
        let narrowBase = highHalf ? narrowCount : 0
        let wideBits = laneBits * 2
        var result: Vector = (0, 0)
        switch kind.shape {
        case .long, .wide, .shiftLong:
            for i in 0..<narrowCount {
                let b = extend(Self.lane(m, bits: laneBits, index: elementIndex ?? (narrowBase + i)), bits: laneBits)
                let a: Int64 = kind.shape == .wide
                    ? extend(Self.lane(n, bits: wideBits, index: i), bits: wideBits)
                    : extend(Self.lane(n, bits: laneBits, index: narrowBase + i), bits: laneBits)
                let acc = Int64(bitPattern: Self.lane(d, bits: wideBits, index: i))
                // Narrow inputs are at most 32 bits. Wrapping Int64 arithmetic
                // preserves the low wideBits even for unsigned 32-bit products.
                let value: Int64
                switch kind {
                case .mull: value = a &* b
                case .mlal: value = acc &+ (a &* b)
                case .mlsl: value = acc &- (a &* b)
                case .addl, .addw: value = a &+ b
                case .subl, .subw: value = a &- b
                case .abdl: value = a > b ? a &- b : b &- a
                case .abal: value = acc &+ (a > b ? a &- b : b &- a)
                case .shll: value = a << Int64(shift)
                default: value = 0
                }
                Self.set(&result, bits: wideBits, index: i, lane: UInt64(bitPattern: value))
            }
        case .binaryNarrow:
            // Arm ISA_A64 2025-12 ADDHN/RADDHN/SUBHN/RSUBHN Operation:
            // RShr(UInt(Vn.e) +/- UInt(Vm.e), esize, round), then low esize bits.
            // Modulo-2^64 arithmetic is exact after this final truncation even
            // for 64-bit input lanes; carry/borrow above bit 63 is discarded.
            if highHalf { result.low = d.low }
            for i in 0..<narrowCount {
                let a = Self.lane(n, bits: wideBits, index: i)
                let b = Self.lane(m, bits: wideBits, index: i)
                var value = kind == .subhn || kind == .rsubhn ? a &- b : a &+ b
                if kind == .raddhn || kind == .rsubhn {
                    value = value &+ (UInt64(1) << UInt64(laneBits - 1))
                }
                Self.set(&result, bits: laneBits, index: narrowBase + i,
                         lane: value >> UInt64(laneBits))
            }
        case .narrow:
            if highHalf { result.low = d.low }
            for i in 0..<narrowCount {
                let wide = Self.lane(n, bits: wideBits, index: i)
                // floor(x / 2^s) + bit(s-1) == floor((x + 2^(s-1)) / 2^s) without
                // forming the possibly overflowing sum.
                let value: UInt64
                if kind == .sqxtun {
                    // Signed wide lane clamped to [0, 2^laneBits - 1].
                    let top = UInt64(1) << UInt64(wideBits - 1)
                    let negative = wideBits < 64 ? wide & top != 0 : Int64(bitPattern: wide) < 0
                    value = negative ? 0 : min(wide, Self.mask(laneBits))
                } else if kind == .sqshrn || kind == .sqrshrn {
                    let shifted = signedNarrowInput(wide)
                    let minimum = -(Int64(1) << (laneBits - 1))
                    let maximum = (Int64(1) << (laneBits - 1)) - 1
                    value = UInt64(bitPattern: min(max(shifted, minimum), maximum))
                } else {
                    let shifted = wide >> UInt64(shift)
                    value = kind == .rshrn ? shifted &+ ((wide >> UInt64(shift - 1)) & 1) : shifted
                }
                Self.set(&result, bits: laneBits, index: narrowBase + i, lane: value)
            }
        case .same:
            let count = activeBytes * 8 / laneBits, half = count / 2
            let mask = Self.mask(laneBits)
            func signed(_ raw: UInt64) -> Int64 {
                laneBits == 64 || raw & (UInt64(1) << UInt64(laneBits - 1)) == 0
                    ? Int64(bitPattern: raw) : Int64(bitPattern: raw | ~mask)
            }
            for i in 0..<count {
                let a = Self.lane(n, bits: laneBits, index: i)
                let b = Self.lane(m, bits: laneBits, index: elementIndex ?? i)
                let acc = Self.lane(d, bits: laneBits, index: i)
                let value: UInt64
                switch kind {
                case .add: value = a &+ b
                case .sub: value = a &- b
                case .mul: value = a &* b
                case .mla: value = acc &+ (a &* b)
                case .mls: value = acc &- (a &* b)
                case .shl: value = a << UInt64(shift)
                case .sqshlu:
                    // Compare before shifting so a full-width lane needs no wider integer.
                    value = signed(a) < 0 ? 0
                        : a > (mask >> UInt64(shift)) ? mask : a << UInt64(shift)
                case .srshr, .ushr, .sshr, .urshr, .usra, .ssra, .ursra, .srsra:
                    // Arm immediate right shifts: quotient plus the highest
                    // discarded bit is exact rounding without overflowing bias.
                    let signedShift = [.srshr, .sshr, .ssra, .srsra].contains(kind)
                    let rounded = [.srshr, .urshr, .ursra, .srsra].contains(kind)
                    let quotient: UInt64
                    if signedShift {
                        quotient = UInt64(bitPattern: signed(a) >> Int64(min(shift, laneBits - 1)))
                    } else {
                        quotient = shift == laneBits ? 0 : a >> UInt64(shift)
                    }
                    let round = rounded ? (a >> UInt64(shift - 1)) & 1 : 0
                    let shifted = quotient &+ round
                    value = [.usra, .ssra, .ursra, .srsra].contains(kind) ? acc &+ shifted : shifted
                case .sri:
                    // SRI preserves the high shift bits of each old lane.
                    let insertedMask = shift == laneBits ? 0 : mask >> UInt64(shift)
                    value = (acc & ~insertedMask) | (shift == laneBits ? 0 : a >> UInt64(shift))
                case .addp:
                    let source = i < half ? n : m
                    let pair = 2 * (i % half)
                    value = Self.lane(source, bits: laneBits, index: pair)
                        &+ Self.lane(source, bits: laneBits, index: pair + 1)
                case .bif: value = (acc & b) | (a & ~b)
                case .cmeq: value = a == b ? mask : 0
                case .cmgt: value = signed(a) > signed(b) ? mask : 0
                case .cmge: value = signed(a) >= signed(b) ? mask : 0
                case .cmhi: value = a > b ? mask : 0
                case .cmhs: value = a >= b ? mask : 0
                case .cmtst: value = (a & b) != 0 ? mask : 0
                case .neg: value = 0 &- a
                case .abs: value = signed(a) < 0 ? 0 &- a : a
                case .cmeqz: value = a == 0 ? mask : 0
                case .cmgez: value = signed(a) >= 0 ? mask : 0
                case .cmgtz: value = signed(a) > 0 ? mask : 0
                case .cmlez: value = signed(a) <= 0 ? mask : 0
                case .cmltz: value = signed(a) < 0 ? mask : 0
                case .ushl, .sshl:
                    // Only the low byte of Vm's lane is the signed shift count.
                    let amount = Int(Int8(truncatingIfNeeded: b))
                    if amount >= 0 {
                        value = amount >= laneBits ? 0 : a << UInt64(amount)
                    } else if kind == .ushl {
                        value = -amount >= laneBits ? 0 : a >> UInt64(-amount)
                    } else {
                        let shift = min(-amount, laneBits - 1)
                        value = UInt64(bitPattern: signed(a) >> Int64(shift))
                    }
                case .uzp1, .uzp2:
                    let odd = kind == .uzp2 ? 1 : 0
                    value = i < half ? Self.lane(n, bits: laneBits, index: 2 * i + odd)
                                     : Self.lane(m, bits: laneBits, index: 2 * (i - half) + odd)
                case .zip1, .zip2:
                    let source = i / 2 + (kind == .zip2 ? half : 0)
                    value = Self.lane(i % 2 == 0 ? n : m, bits: laneBits, index: source)
                case .trn1, .trn2:
                    let source = (i & ~1) + (kind == .trn2 ? 1 : 0)
                    value = Self.lane(i % 2 == 0 ? n : m, bits: laneBits, index: source)
                case .sqdmulh, .sqrdmulh:
                    // (2 * a * b [+ 2^(laneBits-1)]) >> laneBits; only MIN * MIN
                    // overflows, to MAX. Lanes are at most 32 bits, so the
                    // doubled product plus rounding fits Int64 otherwise.
                    let product = signed(a) &* signed(b)
                    let round: Int64 = kind == .sqrdmulh ? Int64(1) << Int64(laneBits - 1) : 0
                    value = signed(a) == signed(b) && signed(a) == -(Int64(1) << Int64(laneBits - 1))
                        ? mask >> 1 : UInt64(bitPattern: ((product << 1) &+ round) >> Int64(laneBits)) & mask
                case .dup:
                    value = elementIndex.map { Self.lane(n, bits: laneBits, index: $0) } ?? n.low
                default: value = ~a
                }
                Self.set(&result, bits: laneBits, index: i, lane: value)
            }
        }
        return result
    }
}

extension MacIRNEONLaneOp {
    /// Whether any active lane saturates (sets sticky FPSR.QC).
    public func saturates(n: Vector, m: Vector) -> Bool {
        func lane(_ v: Vector, _ index: Int, _ bits: Int) -> UInt64 {
            let offset = index * bits
            let mask = bits == 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1
            return ((offset < 64 ? v.low : v.high) >> UInt64(offset % 64)) & mask
        }
        switch kind {
        case .sqdmulh, .sqrdmulh:
            let minimum = UInt64(1) << UInt64(laneBits - 1)
            return (0..<(activeBytes * 8 / laneBits)).contains { i in
                lane(n, i, laneBits) == minimum && lane(m, elementIndex ?? i, laneBits) == minimum
            }
        case .sqshlu:
            let maximum = Self.mask(laneBits)
            let sign = UInt64(1) << (laneBits - 1)
            return (0..<(activeBytes * 8 / laneBits)).contains { i in
                let raw = lane(n, i, laneBits)
                return raw & sign != 0 || raw > (maximum >> UInt64(shift))
            }
        case .sqshrn, .sqrshrn:
            let minimum = -(Int64(1) << (laneBits - 1))
            let maximum = (Int64(1) << (laneBits - 1)) - 1
            return (0..<(64 / laneBits)).contains { i in
                let shifted = signedNarrowInput(lane(n, i, laneBits * 2))
                return shifted < minimum || shifted > maximum
            }
        case .sqxtun:
            let wideBits = laneBits * 2
            let maximum = laneBits == 64 ? UInt64.max : (UInt64(1) << UInt64(laneBits)) - 1
            return (0..<(activeBytes * 8 == laneBits ? 1 : 64 / laneBits)).contains { i in
                let wide = lane(n, i, wideBits)
                return wide & (UInt64(1) << UInt64(wideBits - 1)) != 0 || wide > maximum
            }
        default:
            return false
        }
    }
}

import XCTest
@testable import MacScope

/// Cross-check the native-IEEE evaluator with independently written integer-only
/// rounding references. These references do not use host floating-point arithmetic,
/// oracle expected results, or any builder helper.
final class MacIRScalarFPReferenceTests: XCTestCase {
    private func mask(_ width: Int) -> UInt64 { width == 64 ? .max : (1 << width) - 1 }
    private func random(_ state: inout UInt64) -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }

    private func toInteger(_ raw: UInt64, sourceWidth: Int, width: Int, signed: Bool,
                           scale: Int, mode: MacIRScalarFP.Rounding) -> UInt64 {
        let fraction = sourceWidth == 32 ? 23 : 52
        let exponentBits = sourceWidth == 32 ? 8 : 11
        let exponentMask = (1 << exponentBits) - 1
        let exponentField = Int((raw >> fraction) & UInt64(exponentMask))
        let negative = raw & (1 << (sourceWidth - 1)) != 0
        let payload = raw & ((1 << fraction) - 1)
        let limit = UInt64(1) << (width - 1)
        func saturated() -> UInt64 { signed ? (negative ? limit : limit - 1) : (negative ? 0 : mask(width)) }
        if exponentField == exponentMask { return payload == 0 ? saturated() : 0 }
        let significand = payload | (exponentField == 0 ? 0 : 1 << fraction)
        if significand == 0 { return 0 }
        let bias = (1 << (exponentBits - 1)) - 1
        let exponent = (exponentField == 0 ? 1 - bias : exponentField - bias) - fraction + scale
        var magnitude: UInt64
        var nonzeroRemainder = false
        var halfComparison = -1
        if exponent >= 0 {
            if exponent >= 64 || 64 - significand.leadingZeroBitCount + exponent > 64 { return saturated() }
            magnitude = significand << exponent
        } else {
            let shift = -exponent
            if shift >= 64 {
                magnitude = 0
                nonzeroRemainder = true
            } else {
                magnitude = significand >> shift
                let remainder = significand & ((1 << shift) - 1)
                nonzeroRemainder = remainder != 0
                let half = UInt64(1) << (shift - 1)
                halfComparison = remainder < half ? -1 : (remainder == half ? 0 : 1)
            }
        }
        let increment: Bool
        switch mode {
        case .nearestEven: increment = halfComparison > 0 || (halfComparison == 0 && magnitude & 1 != 0)
        case .tiesAway: increment = halfComparison >= 0
        case .towardZero: increment = false
        case .plusInfinity: increment = nonzeroRemainder && !negative
        case .minusInfinity: increment = nonzeroRemainder && negative
        }
        if increment {
            let sum = magnitude.addingReportingOverflow(1)
            if sum.overflow { return saturated() }
            magnitude = sum.partialValue
        }
        if signed {
            if magnitude >= limit { return saturated() }
        } else {
            if negative { return 0 }
            if magnitude > mask(width) { return mask(width) }
        }
        return (negative ? 0 &- magnitude : magnitude) & mask(width)
    }

    private func fromInteger(_ raw: UInt64, width: Int, signed: Bool, resultWidth: Int, scale: Int) -> UInt64 {
        let value = raw & mask(width)
        let negative = signed && value & (1 << (width - 1)) != 0
        let magnitude = (negative ? 0 &- value : value) & mask(width)
        if magnitude == 0 { return 0 }
        let fraction = resultWidth == 32 ? 23 : 52
        let bias = resultWidth == 32 ? 127 : 1023
        var exponent = 63 - magnitude.leadingZeroBitCount
        var rounded: UInt64
        if exponent <= fraction {
            rounded = magnitude << (fraction - exponent)
        } else {
            let shift = exponent - fraction
            rounded = magnitude >> shift
            let remainder = magnitude & ((1 << shift) - 1)
            let half = UInt64(1) << (shift - 1)
            if remainder > half || (remainder == half && rounded & 1 != 0) { rounded += 1 }
            if rounded == UInt64(1) << (fraction + 1) { rounded >>= 1; exponent += 1 }
        }
        return (negative ? UInt64(1) << (resultWidth - 1) : 0)
            | UInt64(exponent - scale + bias) << fraction
            | rounded & ((1 << fraction) - 1)
    }

    func testSaturatingFloatToIntegerAgainstIntegerOnlyReference() throws {
        var seed: UInt64 = 0x7fb1eaf456789abc
        let modes: [MacIRScalarFP.Rounding] = [.nearestEven, .plusInfinity, .minusInfinity, .towardZero, .tiesAway]
        var checks = 0
        for source: MacIRScalarType in [.binary32, .binary64] {
            let boundaries: [UInt64] = source == .binary32
                ? [0, 0x80000000, 1, 0x80000001, 0x3f000000, 0xbf000000, 0x4f000000, 0xcf000000, 0x4f800000, 0x5f800000, 0x7f800000, 0xff800000, 0x7fc01234, 0x7f801234]
                : [0, 0x8000000000000000, 1, 0x8000000000000001, 0x3fe0000000000000, 0xbfe0000000000000, 0x41e0000000000000, 0xc1e0000000000000, 0x43e0000000000000, 0x43efffffffffffff, 0x43f0000000000000, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000012, 0x7ff0000000000012]
            let inputs = boundaries + (0..<256).map { _ in random(&seed) & mask(source.bitWidth) }
            for target: MacIRScalarType in [.signed32, .unsigned32, .signed64, .unsigned64] {
                for scale in [0, 1, 17, target.bitWidth] {
                    for mode in modes {
                        let semantics = MacIRScalarFP(operation: .toInteger, inputType: source, resultType: target, rounding: mode, fractionalBits: scale)
                        for bits in inputs {
                            let actual = try A64ScalarFPEvaluator.evaluate(semantics, arguments: [.init(bits: bits, width: source.bitWidth, kind: .float)])
                            let expected = toInteger(bits, sourceWidth: source.bitWidth, width: target.bitWidth, signed: target.isSignedInteger, scale: scale, mode: mode)
                            XCTAssertEqual(actual.bits, expected, "\(source) -> \(target) \(mode) scale \(scale), input \(String(bits, radix: 16))")
                            checks += 1
                        }
                    }
                }
            }
        }
        print("CP7 integer-only reference: \(checks) saturating conversion comparisons")
    }

    func testIntegerToFloatAgainstIntegerOnlyReference() throws {
        var seed: UInt64 = 0xa0761d6478bd642f
        var checks = 0
        let edges: [UInt64] = [0, 1, 2, 0x7fffffff, 0x80000000, 0xffffffff, 0x1000001, 0x1000003, 0x7fffffffffffffff, 0x8000000000000000, UInt64.max]
        let inputs = edges + (0..<512).map { _ in random(&seed) }
        for source: MacIRScalarType in [.signed32, .unsigned32, .signed64, .unsigned64] {
            for target: MacIRScalarType in [.binary32, .binary64] {
                for scale in [0, 1, 17, source.bitWidth] {
                    let semantics = MacIRScalarFP(operation: .fromInteger, inputType: source, resultType: target, fractionalBits: scale)
                    for bits in inputs {
                        let actual = try A64ScalarFPEvaluator.evaluate(semantics, arguments: [.int(bits, width: source.bitWidth, signed: source.isSignedInteger)])
                        XCTAssertEqual(actual.bits, fromInteger(bits, width: source.bitWidth, signed: source.isSignedInteger, resultWidth: target.bitWidth, scale: scale), "\(source) -> \(target) scale \(scale), input \(String(bits, radix: 16))")
                        checks += 1
                    }
                }
            }
        }
        print("CP7 integer-only reference: \(checks) integer-to-float comparisons")
    }
}

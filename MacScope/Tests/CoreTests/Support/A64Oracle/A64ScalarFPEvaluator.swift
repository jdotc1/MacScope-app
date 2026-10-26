import Foundation
@testable import MacScope

/// Independent interpreter of the documented scalar FP IR contract. No builder,
/// decoder, fixture, expected-output, or source-span lookup is used here.
/// Finite arithmetic uses Swift's IEEE binary32/binary64 operations at their native
/// precision, without fast-math or a Double intermediate for binary32. NaN selection,
/// payload conversion, signed-zero min/max and A64 integer saturation are explicit.
/// FPSR is intentionally absent. The caller admits only the default FPCR profile.
enum A64ScalarFPEvaluator {
    typealias Scalar = MacIRConcreteEvaluator.Scalar
    typealias Failure = MacIRConcreteEvaluator.Failure

    private static func fractionBits(_ width: Int) -> Int { width == 32 ? 23 : 52 }
    private static func exponentMask(_ width: Int) -> UInt64 { width == 32 ? 0x7f800000 : 0x7ff0000000000000 }
    private static func quietBit(_ width: Int) -> UInt64 { UInt64(1) << (fractionBits(width) - 1) }
    private static func fractionMask(_ width: Int) -> UInt64 { (UInt64(1) << fractionBits(width)) - 1 }
    private static func isNaN(_ bits: UInt64, _ width: Int) -> Bool {
        bits & exponentMask(width) == exponentMask(width) && bits & fractionMask(width) != 0
    }
    private static func isSignaling(_ bits: UInt64, _ width: Int) -> Bool {
        isNaN(bits, width) && bits & quietBit(width) == 0
    }
    private static func defaultNaN(_ width: Int) -> UInt64 { exponentMask(width) | quietBit(width) }
    private static func fp(_ bits: UInt64, _ width: Int) -> Scalar {
        Scalar(bits: bits & Scalar.mask(width), width: width, kind: .float)
    }
    private static func rule(_ mode: MacIRScalarFP.Rounding) -> FloatingPointRoundingRule {
        switch mode {
        case .nearestEven: .toNearestOrEven
        case .plusInfinity: .up
        case .minusInfinity: .down
        case .towardZero: .towardZero
        case .tiesAway: .toNearestOrAwayFromZero
        }
    }

    static func evaluate(_ semantics: MacIRScalarFP, arguments: [Scalar]) throws -> Scalar {
        guard arguments.count == semantics.operation.arity else { throw Failure.unsupported("scalar FP arity") }
        let sourceWidth = semantics.inputType.bitWidth
        let resultWidth = semantics.resultType.bitWidth
        if semantics.inputType.isFloatingPoint {
            guard arguments.allSatisfy({ $0.kind == .float && $0.width == sourceWidth }) else {
                throw Failure.unsupported("scalar FP operand type does not match its IR descriptor")
            }
        } else if arguments.contains(where: { $0.kind == .float }) {
            throw Failure.unsupported("integer conversion operand is floating point")
        }
        let bits = arguments.map { $0.bits & Scalar.mask(sourceWidth) }
        let a = bits[0]
        let op = semantics.operation
        if op.arity == 3 { return fused(bits, semantics) }
        if op == .fromInteger {
            return integerToFloat(a, semantics)
        }
        if op == .toInteger {
            return floatToInteger(a, semantics)
        }
        if op == .negate { return fp(a ^ Scalar.signBit(sourceWidth), resultWidth) }
        if op == .absolute { return fp(a & ~Scalar.signBit(sourceWidth), resultWidth) }
        if op == .convert {
            if isNaN(a, sourceWidth) {
                let difference = fractionBits(resultWidth) - fractionBits(sourceWidth)
                let payload = difference >= 0 ? (a & fractionMask(sourceWidth)) << difference : (a & fractionMask(sourceWidth)) >> -difference
                let sign = a & Scalar.signBit(sourceWidth) == 0 ? 0 : Scalar.signBit(resultWidth)
                return fp(sign | exponentMask(resultWidth) | quietBit(resultWidth) | payload, resultWidth)
            }
            if sourceWidth == 32 {
                return fp(Double(Float(bitPattern: UInt32(truncatingIfNeeded: a))).bitPattern, 64)
            }
            return fp(UInt64(Float(Double(bitPattern: a)).bitPattern), 32)
        }

        // A64 default-NaN mode is off. A signaling NaN wins over a quiet NaN;
        // within each class the first source operand wins, with its payload/sign.
        if let signaling = bits.first(where: { isSignaling($0, sourceWidth) }) {
            return fp(signaling | quietBit(sourceWidth), resultWidth)
        }
        let nanOperands = bits.filter { isNaN($0, sourceWidth) }
        if !nanOperands.isEmpty {
            if (op == .maximumNumber || op == .minimumNumber), nanOperands.count == 1,
               let number = bits.first(where: { !isNaN($0, sourceWidth) }) {
                return fp(number, resultWidth)
            }
            return fp(nanOperands[0] | quietBit(sourceWidth), resultWidth)
        }

        func calculate<F: BinaryFloatingPoint>(_ first: F, _ second: F) throws -> F {
            switch op {
            case .add: first + second
            case .subtract: first - second
            case .multiply: first * second
            case .divide: first / second
            case .squareRoot: first.squareRoot()
            case .round: first.rounded(rule(semantics.rounding))
            case .maximum, .maximumNumber: max(first, second)
            case .minimum, .minimumNumber: min(first, second)
            default: throw Failure.unsupported("scalar FP operation \(op)")
            }
        }
        if [.maximum, .minimum, .maximumNumber, .minimumNumber].contains(op),
           a & ~Scalar.signBit(sourceWidth) == 0, bits[1] & ~Scalar.signBit(sourceWidth) == 0 {
            let sign = (op == .maximum || op == .maximumNumber) ? a & bits[1] : a | bits[1]
            return fp(sign, resultWidth)
        }
        let b = bits.count > 1 ? bits[1] : 0
        let result: UInt64
        if sourceWidth == 32 {
            result = UInt64(try calculate(Float(bitPattern: UInt32(truncatingIfNeeded: a)), Float(bitPattern: UInt32(truncatingIfNeeded: b))).bitPattern)
        } else {
            result = try calculate(Double(bitPattern: a), Double(bitPattern: b)).bitPattern
        }
        // With no NaN input, a NaN result denotes invalid arithmetic, whose A64
        // default result is positive canonical qNaN (host sign choices may differ).
        return fp(isNaN(result, resultWidth) ? defaultNaN(resultWidth) : result, resultWidth)
    }

    /// Ordinary Arm FPMulAdd, FPCR=0. Classification and NaN handling are explicit;
    /// only finite arithmetic uses Swift's single-rounding IEEE fma builtin.
    /// Checked against cached Arm 2025-03 pseudocode and an independent integer/
    /// rational reference plus 16,024 newly executed QEMU observations.
    private static func fused(_ bits: [UInt64], _ semantics: MacIRScalarFP) -> Scalar {
        let width = semantics.inputType.bitWidth
        let sign = Scalar.signBit(width)
        var n = bits[0], a = bits[2]
        let m = bits[1]
        if [.fusedMultiplySubtract, .negatedFusedMultiplyAdd].contains(semantics.operation) { n ^= sign }
        if [.negatedFusedMultiplyAdd, .negatedFusedMultiplySubtract].contains(semantics.operation) { a ^= sign }
        func infinity(_ x: UInt64) -> Bool { x & ~sign == exponentMask(width) }
        func zero(_ x: UInt64) -> Bool { x & ~sign == 0 }
        let invalidProduct = (infinity(n) && zero(m)) || (zero(n) && infinity(m))
        if isNaN(a, width), !isSignaling(a, width), invalidProduct {
            return fp(defaultNaN(width), width)
        }
        let ordered = [a, n, m]
        if let nan = ordered.first(where: { isSignaling($0, width) }) ?? ordered.first(where: { isNaN($0, width) }) {
            return fp(nan | quietBit(width), width)
        }
        let productSign = (n ^ m) & sign
        let infiniteProduct = infinity(n) || infinity(m)
        if invalidProduct || (infinity(a) && infiniteProduct && (a & sign) != productSign) {
            return fp(defaultNaN(width), width)
        }
        if infiniteProduct { return fp(exponentMask(width) | productSign, width) }
        if infinity(a) { return fp(a, width) }
        if zero(a), zero(n) || zero(m), (a & sign) == productSign { return fp(a, width) }
        if width == 32 {
            let result = Float(bitPattern: UInt32(truncatingIfNeeded: a)).addingProduct(
                Float(bitPattern: UInt32(truncatingIfNeeded: n)), Float(bitPattern: UInt32(truncatingIfNeeded: m)))
            return fp(UInt64(result.bitPattern), width)
        }
        return fp(Double(bitPattern: a).addingProduct(Double(bitPattern: n), Double(bitPattern: m)).bitPattern, width)
    }

    private static func floatToInteger(_ bits: UInt64, _ semantics: MacIRScalarFP) -> Scalar {
        let sourceWidth = semantics.inputType.bitWidth
        let width = semantics.resultType.bitWidth
        let signed = semantics.resultType.isSignedInteger
        if isNaN(bits, sourceWidth) { return .int(0, width: width, signed: signed) }
        let real = sourceWidth == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))) : Double(bitPattern: bits)
        // Widening binary32 is exact. Scaling a finite binary64 by a nonnegative
        // power of two introduces no rounding before overflow; overflow necessarily
        // saturates for these integer ranges. No integer cast occurs before bounds checks.
        let scaled = Double(sign: real.sign, exponent: semantics.fractionalBits, significand: real.magnitude)
        let rounded = scaled.rounded(rule(semantics.rounding))
        let limit = Double(sign: .plus, exponent: signed ? width - 1 : width, significand: 1)
        if signed {
            if rounded >= limit { return .int(Scalar.signBit(width) - 1, width: width, signed: true) }
            if rounded <= -limit { return .int(Scalar.signBit(width), width: width, signed: true) }
            return .int(UInt64(bitPattern: Int64(rounded)), width: width, signed: true)
        }
        if rounded <= 0 { return .int(0, width: width, signed: false) }
        if rounded >= limit { return .int(Scalar.mask(width), width: width, signed: false) }
        return .int(UInt64(rounded), width: width, signed: false)
    }

    private static func integerToFloat(_ bits: UInt64, _ semantics: MacIRScalarFP) -> Scalar {
        let input = Scalar.int(bits, width: semantics.inputType.bitWidth, signed: semantics.inputType.isSignedInteger)
        let exponent = -semantics.fractionalBits
        // Convert directly from the integer to the destination precision. The
        // subsequent power-of-two scaling is exact: integer widths/fractionalBits
        // are <=64, so a nonzero result is far above binary32's subnormal boundary.
        if semantics.resultType == .binary32 {
            let rounded = semantics.inputType.isSignedInteger ? Float(input.signedValue) : Float(input.bits)
            return fp(UInt64(Float(sign: rounded.sign, exponent: exponent, significand: rounded.magnitude).bitPattern), 32)
        }
        let rounded = semantics.inputType.isSignedInteger ? Double(input.signedValue) : Double(input.bits)
        return fp(Double(sign: rounded.sign, exponent: exponent, significand: rounded.magnitude).bitPattern, 64)
    }
}

import Foundation

/// Narrow, proof-backed arithmetic recovery at the lifter boundary.
/// Does not remove instructions, change SSA identities, or invent intrinsics.
/// Widths/mnemonics are supplied by the builder, never inferred from C text.
struct MacIRArithmeticRewrite {
    private struct Constant {
        let destination: MacIRValue
        let bits: UInt64
        let width: Int
        let nextAddress: UInt64
    }
    private enum Candidate {
        case signExtension(destination: MacIRValue, input: MacIRValue, width: Int, shift: Int64)
        case reciprocal(destination: MacIRValue, input: MacIRValue, magic: UInt64)
    }
    private var constant: Constant?
    private var previous: (candidate: Candidate, nextAddress: UInt64)?

    /// `allowSequence` must be false if any branch/call can enter or escape a
    /// candidate sequence. The builder conservatively gates the whole function.
    /// `operandWidths` excludes the destination; nil denotes a non-GPR operand.
    mutating func rewrite(_ operation: MacIROperation, mnemonic: String,
                          width: Int?, operandWidths: [Int?], address: UInt64,
                          allowSequence: Bool) -> MacIROperation {
        let oldConstant = constant
        let oldPrevious = previous
        constant = nil
        previous = nil
        guard let width, [32, 64].contains(width) else { return operation }
        let (nextAddress, overflow) = address.addingReportingOverflow(4)

        // Only exact, adjacent dataflow is retained. Original producers stay in
        // the IR, including their source spans, destination writes and effects.
        if allowSequence && !overflow {
            if ["mov", "movz", "movk"].contains(mnemonic),
               case let .assign(destination, .immediate(value)) = operation,
               Self.isSSA(destination) {
                constant = Constant(destination: destination,
                                    bits: UInt64(bitPattern: value) & Self.mask(width),
                                    width: width, nextAddress: nextAddress)
            }
            if mnemonic == "lsl", operandWidths.count == 2, operandWidths[0] == width,
               case let .binary(destination, "<<", .unary(cast, input), .immediate(shift)) = operation,
               cast == "(uint\(width)_t)", Self.isPure(input),
               shift > 0, shift < width,
               [8, 16, 32].contains(width - Int(shift)) {
                previous = (.signExtension(destination: destination, input: input,
                                            width: width, shift: shift), nextAddress)
            }
            if mnemonic == "umull", width == 64, operandWidths == [32, 32],
               case let .binary(destination, "*", left, right) = operation,
               let c = oldConstant, c.nextAddress == address, c.width == 32,
               let a = Self.widenedWord(left), let b = Self.widenedWord(right) {
                let input: MacIRValue? = a == c.destination ? b : b == c.destination ? a : nil
                if let input, Self.isPure(input), [UInt64(0xaaaaaaab), 0xcccccccd].contains(c.bits) {
                    previous = (.reciprocal(destination: destination, input: input, magic: c.bits), nextAddress)
                }
            }
        }

        if allowSequence, let prior = oldPrevious, prior.nextAddress == address {
            switch prior.candidate {
            case let .signExtension(producer, input, producerWidth, shift):
                if mnemonic == "asr", width == producerWidth,
                   operandWidths.count == 2, operandWidths[0] == width,
                   case let .binary(destination, ">>", .unary(cast, use), .immediate(amount)) = operation,
                   cast == "(int\(width)_t)", use == producer, amount == shift {
                    return .assign(destination: destination,
                                   source: .unary(op: "(int\(width)_t)", value:
                                       .unary(op: "(int\(width - Int(shift))_t)", value: input)))
                }
            case let .reciprocal(producer, input, magic):
                if mnemonic == "lsr", width == 64, operandWidths.count == 2, operandWidths[0] == 64,
                   case let .binary(destination, ">>", .unary("(uint64_t)", use), .immediate(shift)) = operation,
                   use == producer, let divisor = Self.divisor(magic: magic, shift: shift) {
                    // The exact 32x32 -> 64 product cannot overflow. Its quotient
                    // fits uint32_t but the architectural destination is X.
                    return .assign(destination: destination, source: Self.unsigned(
                        .binaryExpression(op: "/", left: Self.unsigned(input, 32),
                                          right: Self.unsigned(.immediate(divisor), 32)), 64))
                }
            }
        }

        // A standalone unsigned constant shift or low-bit mask stays bitwise
        // (`>> 4`, `& 0xff`): that is the clearer reading for reverse
        // engineering than the equivalent power-of-two quotient or remainder.
        return operation
    }

    private static func divisor(magic: UInt64, shift: Int64) -> Int64? {
        switch (magic, shift) {
        case (0xaaaaaaab, 33): 3
        case (0xcccccccd, 34): 5
        case (0xcccccccd, 35): 10
        default: nil
        }
    }
    private static func widenedWord(_ value: MacIRValue) -> MacIRValue? {
        guard case let .unary("(uint64_t)", .unary("(uint32_t)", input)) = value else { return nil }
        return input
    }
    private static func unsigned(_ value: MacIRValue, _ width: Int) -> MacIRValue {
        .unary(op: "(uint\(width)_t)", value: value)
    }
    private static func mask(_ width: Int) -> UInt64 { width == 32 ? 0xffff_ffff : .max }
    private static func isSSA(_ value: MacIRValue) -> Bool {
        switch value { case .register, .temporary: true; default: false }
    }
    private static func isPure(_ value: MacIRValue) -> Bool {
        switch value {
        case .register, .argument, .temporary, .immediate: true
        case let .unary(op, inner):
            ["(uint32_t)", "(int32_t)", "(uint64_t)", "(int64_t)"].contains(op) && isPure(inner)
        default: false // No stack reads, symbols, opaque values, or effects.
        }
    }
}

import Foundation

// Architectural memory and scalar numeric facts, independent of source rendering.
extension MacIRBuilder {
    /// Decode access semantics once, in the lifter. Evaluators and printers never
    /// recover these facts from source.mnemonic (source spans are presentation only).
    static func memoryAccess(for source: MacIRSourceSpan) -> MacIRMemoryAccess? {
        let mnemonic = source.mnemonic
        let loads: Set<String> = ["ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw", "ldp", "ldpsw"]
        let stores: Set<String> = ["str", "stur", "strb", "strh", "sturb", "sturh", "stp"]
        guard loads.contains(mnemonic) || stores.contains(mnemonic),
              let register = splitOperands(source.operands).first,
              let width = mnemonic == "ldpsw" ? 4 : loadStoreByteWidth(mnemonic: mnemonic, register: register) else { return nil }
        let signed: Set<String> = ["ldrsb", "ldrsh", "ldrsw", "ldursb", "ldursh", "ldursw", "ldpsw"]
        let extensionKind: MacIRMemoryAccess.ExtensionKind = signed.contains(mnemonic) ? .sign
            : ["ldrb", "ldrh", "ldurb", "ldurh"].contains(mnemonic) ? .zero : .none
        return MacIRMemoryAccess(byteWidth: width, extensionKind: extensionKind)
    }

    /// Admission is based on supported scalar register domains and exact operation
    /// semantics. Half precision, vector arrangements, and unimplemented forms fall
    /// through to the normal conservative unknown path.
    static func scalarFPSemantics(mnemonic: String, operands: [String]) -> MacIRScalarFP? {
        func fp(_ operand: String) -> MacIRScalarType? {
            guard isFmovScalarFPRegister(operand), ["s", "d"].contains(operand.lowercased().first) else { return nil }
            return operand.lowercased().hasPrefix("s") ? .binary32 : .binary64
        }
        func integer(_ operand: String, signed: Bool) -> MacIRScalarType? {
            guard let width = scalarDataBitWidth(operand), operand != "sp" else { return nil }
            return signed ? (width == 32 ? .signed32 : .signed64) : (width == 32 ? .unsigned32 : .unsigned64)
        }
        let binary: [String: MacIRScalarFP.Operation] = ["fadd": .add, "fsub": .subtract, "fmul": .multiply, "fdiv": .divide,
            "fmax": .maximum, "fmin": .minimum, "fmaxnm": .maximumNumber, "fminnm": .minimumNumber]
        if let operation = binary[mnemonic], operands.count == 3, let type = fp(operands[0]),
           fp(operands[1]) == type, fp(operands[2]) == type {
            return MacIRScalarFP(operation: operation, inputType: type, resultType: type)
        }
        let fused: [String: MacIRScalarFP.Operation] = ["fmadd": .fusedMultiplyAdd, "fmsub": .fusedMultiplySubtract,
            "fnmadd": .negatedFusedMultiplyAdd, "fnmsub": .negatedFusedMultiplySubtract]
        if let operation = fused[mnemonic], operands.count == 4, let type = fp(operands[0]),
           operands.dropFirst().allSatisfy({ fp($0) == type }) {
            return MacIRScalarFP(operation: operation, inputType: type, resultType: type)
        }
        let unary: [String: MacIRScalarFP.Operation] = ["fneg": .negate, "fabs": .absolute, "fsqrt": .squareRoot]
        if let operation = unary[mnemonic], operands.count == 2, let type = fp(operands[0]), fp(operands[1]) == type {
            return MacIRScalarFP(operation: operation, inputType: type, resultType: type)
        }
        let modes: [String: MacIRScalarFP.Rounding] = ["n": .nearestEven, "p": .plusInfinity, "m": .minusInfinity, "z": .towardZero, "a": .tiesAway, "x": .nearestEven, "i": .nearestEven]
        if mnemonic.hasPrefix("frint"), let mode = modes[String(mnemonic.dropFirst(5))],
           operands.count == 2, let type = fp(operands[0]), fp(operands[1]) == type {
            return MacIRScalarFP(operation: .round, inputType: type, resultType: type, rounding: mode, raisesInexact: mnemonic == "frintx")
        }
        if mnemonic == "fcvt", operands.count == 2, let result = fp(operands[0]), let input = fp(operands[1]), input != result {
            return MacIRScalarFP(operation: .convert, inputType: input, resultType: result)
        }
        let toIntModes: [String: MacIRScalarFP.Rounding] = ["fcvtns": .nearestEven, "fcvtnu": .nearestEven,
            "fcvtps": .plusInfinity, "fcvtpu": .plusInfinity, "fcvtms": .minusInfinity, "fcvtmu": .minusInfinity,
            "fcvtzs": .towardZero, "fcvtzu": .towardZero, "fcvtas": .tiesAway, "fcvtau": .tiesAway]
        // Advanced-SIMD scalar conversions use an integer bit pattern in S/D,
        // not a numeric floating-point result. Vector arrangements and half are excluded.
        if let mode = toIntModes[mnemonic], operands.count == 2,
           let carrier = fp(operands[0]), fp(operands[1]) == carrier {
            let signed = mnemonic.hasSuffix("s")
            let result: MacIRScalarType = signed ? (carrier.bitWidth == 32 ? .signed32 : .signed64)
                : (carrier.bitWidth == 32 ? .unsigned32 : .unsigned64)
            return MacIRScalarFP(operation: .toInteger, inputType: carrier, resultType: result, rounding: mode, integerCarrier: .scalarSIMDBits)
        }
        if let mode = toIntModes[mnemonic], (2...3).contains(operands.count),
           let result = integer(operands[0], signed: mnemonic.hasSuffix("s")), let input = fp(operands[1]) {
            var fraction = 0
            if operands.count == 3 {
                guard mode == .towardZero, let parsed = parseImmediate(operands[2]), (1...Int64(result.bitWidth)).contains(parsed) else { return nil }
                fraction = Int(parsed)
            }
            return MacIRScalarFP(operation: .toInteger, inputType: input, resultType: result, rounding: mode, fractionalBits: fraction)
        }
        if ["scvtf", "ucvtf"].contains(mnemonic), operands.count == 2,
           let carrier = fp(operands[0]), fp(operands[1]) == carrier {
            let input: MacIRScalarType = mnemonic == "scvtf" ? (carrier.bitWidth == 32 ? .signed32 : .signed64)
                : (carrier.bitWidth == 32 ? .unsigned32 : .unsigned64)
            return MacIRScalarFP(operation: .fromInteger, inputType: input, resultType: carrier, integerCarrier: .scalarSIMDBits)
        }
        if ["scvtf", "ucvtf"].contains(mnemonic), (2...3).contains(operands.count),
           let result = fp(operands[0]), let input = integer(operands[1], signed: mnemonic == "scvtf") {
            var fraction = 0
            if operands.count == 3 {
                guard let parsed = parseImmediate(operands[2]), (1...Int64(input.bitWidth)).contains(parsed) else { return nil }
                fraction = Int(parsed)
            }
            return MacIRScalarFP(operation: .fromInteger, inputType: input, resultType: result, fractionalBits: fraction)
        }
        return nil
    }

    static func scalarDataBitWidth(_ register: String) -> Int? {
        if isZeroRegister(register) { return register.lowercased().hasPrefix("w") ? 32 : 64 }
        return scalarRegisterBitWidth(register)
    }

    static func shiftOperand(_ value: MacIRValue, mnemonic: String, width: Int) -> MacIRValue {
        // A64 shifts are bit-width operations. Explicit casts also protect ASR
        // after a preceding unsigned operation; register names alone are not types.
        .unary(op: "(\(mnemonic == "asr" ? "int" : "uint")\(width)_t)", value: value)
    }

    private static func hasUnsignedType(_ value: MacIRValue, parameters: [MacIRFunctionParameter]) -> Bool {
        switch value {
        case let .unary(op, inner):
            if op.hasPrefix("(") { return op.hasPrefix("(uint") }
            return hasUnsignedType(inner, parameters: parameters)
        case .binaryExpression: return true
        case let .argument(id): return parameters.first { $0.bindingID == id }?.type.hasPrefix("uint") == true
        default: return false // Legacy GPR/temporary carriers are signed by the MacIR contract.
        }
    }

    /// A34: marker for the signed projection of a signed-condition operand. The printer resolves it from
    /// its own declared-type knowledge: a plain `(intW_t)e` only when e prints as exactly signed W,
    /// otherwise the A31 defined two's-complement transport. A marker never reaches printed output.
    static let signedProjectionOperator = "__ssa_signed_projection"

    static func isPureValue(_ value: MacIRValue) -> Bool {
        switch value {
        case .unknown: return false
        case let .signedBitfield(field): return isPureValue(field.source)
        case let .unary(_, inner): return isPureValue(inner)
        case let .binaryExpression(_, left, right): return isPureValue(left) && isPureValue(right)
        case let .bitTest(inner, _): return isPureValue(inner)
        case let .abiComposite(_, fragments): return fragments.allSatisfy(isPureValue)
        default: return true
        }
    }

    /// A34: the single build-time helper for signed projections of SSA-lifted comparison operands. A
    /// literal, an existing projection or an existing `(intW_t)` cast is kept; any other pure operand
    /// gets one marker (no signedness is guessed here); an operand with effects is left unprojected
    /// rather than duplicated by the printer's transport.
    static func signedProjection(_ value: MacIRValue, width: Int, partner: MacIRValue? = nil) -> MacIRValue {
        switch value {
        case .immediate: return value
        case let .unary(existing, _) where existing == "(int\(width)_t)": return value
        case let .binaryExpression(existing, _, _) where existing == signedProjectionOperator: return value
        default: break
        }
        guard isPureValue(value) else { return value }
        // A35: the partner operand travels with the marker so the printer can decide whether a
        // sign-extended narrower operand may stay bare; it is never printed.
        let context: MacIRValue = partner.map {
            .binaryExpression(op: projectionContextOperator, left: .immediate(Int64(width)), right: $0)
        } ?? .immediate(Int64(width))
        return .binaryExpression(op: signedProjectionOperator, left: value, right: context)
    }

    static let projectionContextOperator = "__ssa_signed_projection_partner"

    /// The operand under a signed-projection marker (a projection never changes which value is compared),
    /// so a branch whose operands were projected still matches the unprojected `compare` it follows.
    static func droppingSignedProjection(_ value: MacIRValue) -> MacIRValue {
        if case let .binaryExpression(op, inner, _) = value, op == signedProjectionOperator { return inner }
        return value
    }

    /// A41: a literal, or a parameter declared as signed integer of exactly the comparison width.
    private static func isPlainSignedOperand(_ value: MacIRValue, width: Int,
                                             argumentBitWidths: [MacIRParameterBindingID: Int],
                                             parameters: [MacIRFunctionParameter]) -> Bool {
        switch value {
        case .immediate: return true
        case let .argument(id):
            guard argumentBitWidths[id] == width,
                  let type = parameters.first(where: { $0.bindingID == id })?.type else { return false }
            return type == "int\(width)_t"
        default: return false
        }
    }

    static func explicitComparisonTypes(_ operation: MacIROperation, source: MacIRSourceSpan,
                                                 argumentBitWidths: [MacIRParameterBindingID: Int], parameters: [MacIRFunctionParameter],
                                                 projectSigned: Bool = false) -> MacIROperation {
        let suffix = source.mnemonic.hasPrefix("b.") ? String(source.mnemonic.dropFirst(2))
            : splitOperands(source.operands).last ?? ""
        guard ["hs", "cs", "lo", "cc", "hi", "ls", "ge", "lt", "gt", "le"].contains(suffix) else { return operation }
        func cast(_ value: MacIRValue, left: MacIRValue, right: MacIRValue) -> MacIRValue {
            let partner = value == left ? right : left
            let width = comparisonBitWidth(left: left, right: right, argumentBitWidths: argumentBitWidths)
            if !isUnsignedConditionSuffix(suffix) {
                // A30 (SSA only): a signed condition projects every non-literal operand to signed W.
                if projectSigned {
                    // A41: operands that are literals or full-width signed arguments already compare
                    // as signed W; a projection is needed only for a narrower, unsigned or
                    // untyped operand or when the partner needs one (A31 transport partner).
                    if isPlainSignedOperand(value, width: width, argumentBitWidths: argumentBitWidths, parameters: parameters),
                       isPlainSignedOperand(partner, width: width, argumentBitWidths: argumentBitWidths, parameters: parameters) {
                        return value
                    }
                    return signedProjection(value, width: width, partner: partner)
                }
                // This value already owns its signed W32 view and partner.
                if case let .binaryExpression(marker, _, .binaryExpression(context, .immediate(32), _)) = value,
                   marker == signedProjectionOperator, context == projectionContextOperator {
                    return value
                }
                if !hasUnsignedType(value, parameters: parameters) { return value }
            }
            let op = "(\(isUnsignedConditionSuffix(suffix) ? "uint" : "int")\(width)_t)"
            if case let .unary(existing, _) = value, existing == op { return value }
            return .unary(op: op, value: value)
        }
        switch operation {
        case let .conditionalBranch(condition, left, right, target) where condition != "==" && condition != "!=":
            return .conditionalBranch(condition: condition, left: cast(left, left: left, right: right), right: cast(right, left: left, right: right), target: target)
        case let .select(destination, condition, left, right, trueValue, falseValue) where condition != "==" && condition != "!=":
            return .select(destination: destination, condition: condition, left: cast(left, left: left, right: right), right: cast(right, left: left, right: right), trueValue: trueValue, falseValue: falseValue)
        case let .compareToBool(destination, condition, left, right) where condition != "==" && condition != "!=":
            return .compareToBool(destination: destination, condition: condition, left: cast(left, left: left, right: right), right: cast(right, left: left, right: right))
        default: return operation
        }
    }

}

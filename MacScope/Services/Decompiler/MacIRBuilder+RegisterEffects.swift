import Foundation

// Register-effect classification helpers for `MacIRBuilder`: which registers
// an instruction reads or writes, writeback-address recognition, the
// register-class predicates, NZCV-writer classification, and the
// unknown-destination rules. Split out of MacIRBuilder.swift (R10.8).
extension MacIRBuilder {
    static func argumentRegisterReads(mnemonic: String, operands: [String]) -> [String] {
        if let fp = scalarFPSemantics(mnemonic: mnemonic, operands: operands) {
            return operands.dropFirst().prefix(fp.operation.arity).flatMap { registerReferences(in: $0) }
        }
        switch mnemonic {
        case "mov", "movz":
            guard operands.count == 2 else { return [] }
            return registerReferences(in: operands[1])

        case "movk":
            guard (operands.count == 2 || operands.count == 3),
                  hasOnlyRound2ScalarGPROperands(operands),
                  isRound2DataRegister(operands[0]) else { return [] }
            return registerReferences(in: operands[0])

        case "fmov":
            guard isFmovScalarGPRFPBitMove(operands) || isFmovScalarFPFPMove(operands) else { return [] }
            return registerReferences(in: operands[1])

        case "add", "sub":
            if operands.count == 4,
               let extend = operands.last?.split(separator: " ").first?.lowercased(),
               ["sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw"].contains(String(extend)),
               hasOnlyRound2ScalarGPROperands(operands) {
                return registerReferences(in: operands[1]) + registerReferences(in: operands[2])
            }
            guard operands.count == 3 else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "subs", "adds", "and", "ands", "orr", "eor", "mul", "sdiv", "udiv", "bic", "bics", "orn", "eon":
            if ["bic", "orn", "eon"].contains(mnemonic),
               operands.count == 4,
               hasOnlyScalarGPROperands(operands) {
                return registerReferences(in: operands[1]) + registerReferences(in: operands[2])
            }
            guard operands.count == 3 else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "umull", "smull":
            guard operands.count == 3 else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "umaddl", "smaddl", "smsubl", "umsubl":
            guard operands.count == 4 else { return [] }
            return registerReferences(in: operands[1])
                + registerReferences(in: operands[2])
                + registerReferences(in: operands[3])

        case "smulh", "umulh":
            guard operands.count == 3,
                  hasOnlyRound2ScalarGPROperands(operands) else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "neg", "negs", "mvn", "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw", "clz", "rbit", "rev", "rev16", "rev32":
            // Two-operand negation/NOT/extension/bit-transform aliases read only operands[1].
            guard operands.count == 2 else { return [] }
            return registerReferences(in: operands[1])

        case "blr", "blraa", "blrab", "blraaz", "blrabz":
            guard hasValidReturningCallOperands(mnemonic: mnemonic, operands: operands) else {
                return []
            }
            // Valid returning indirect calls read the target register and any
            // authenticated PAC-modifier register before the call boundary.
            return operands.flatMap { registerReferences(in: $0) }

        case "br", "braa", "brab", "braaz", "brabz":
            // Indirect branches read the target register (operands[0]); the arm64e
            // authenticated forms additionally read the PAC-modifier register (operands[1]).
            return operands.flatMap { registerReferences(in: $0) }

        case "lsl", "lsr", "asr", "ror":
            // Immediate shifts read only operands[1]. Register-amount lsl/lsr/asr/ror
            // also read operands[2], guarded to scalar GPR/data-register forms.
            guard operands.count == 3 else { return [] }
            if ["lsl", "lsr", "asr", "ror"].contains(mnemonic),
               parseImmediate(operands[2]) == nil,
               hasOnlyRound2ScalarGPROperands(operands),
               operands.allSatisfy(isRound2DataRegister) {
                return registerReferences(in: operands[1]) + registerReferences(in: operands[2])
            }
            return registerReferences(in: operands[1])

        case "ubfx", "sbfx", "ubfiz", "sbfiz":
            // The lsb and width are immediates, so only operands[1] is a source.
            guard operands.count == 4 else { return [] }
            return registerReferences(in: operands[1])

        case "bfi", "bfxil":
            guard operands.count == 4 else { return [] }
            return registerReferences(in: operands[0]) + registerReferences(in: operands[1])

        case "extr":
            guard operands.count == 4 else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "madd", "msub":
            guard operands.count == 4 else { return [] }
            return registerReferences(in: operands[1])
                + registerReferences(in: operands[2])
                + registerReferences(in: operands[3])

        case "mneg":
            guard operands.count == 3 else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursw", "ldursb", "ldursh":
            if operands.count == 3,
               scalarWritebackAddress(operands: operands) != nil,
               hasOnlyScalarGPROperands(operands, allowingMemory: true) {
                return registerReferences(in: operands[1])
            }
            guard operands.count == 2 else { return [] }
            return registerReferences(in: operands[1])

        case "str", "stur", "strb", "strh", "sturb", "sturh":
            if operands.count == 3,
               scalarWritebackAddress(operands: operands) != nil,
               hasOnlyScalarGPROperands(operands, allowingMemory: true) {
                return registerReferences(in: operands[0]) + registerReferences(in: operands[1])
            }
            guard operands.count == 2 else { return [] }
            return registerReferences(in: operands[0]) + registerReferences(in: operands[1])

        case "stp":
            guard operands.count >= 3 else { return [] }
            return registerReferences(in: operands[0])
                + registerReferences(in: operands[1])
                + registerReferences(in: memoryOperand(from: operands))

        case "ldp", "ldpsw":
            guard operands.count >= 3 else { return [] }
            return registerReferences(in: memoryOperand(from: operands))

        case "cmp", "cmn":
            if operands.count == 3,
               isSupportedComparisonRegisterModifier(register: operands[1], modifier: operands[2]),
               hasOnlyRound2ScalarGPROperands(operands) {
                return registerReferences(in: operands[0]) + registerReferences(in: operands[1])
            }
            guard operands.count == 2 else { return [] }
            return registerReferences(in: operands[0]) + registerReferences(in: operands[1])

        case "tst":
            guard operands.count == 2 else { return [] }
            return registerReferences(in: operands[0]) + registerReferences(in: operands[1])

        case "cbz", "cbnz":
            guard let operand = operands.first else { return [] }
            return registerReferences(in: operand)

        case "tbz", "tbnz":
            guard let operand = operands.first else { return [] }
            return registerReferences(in: operand)

        case "csel", "csinc", "csinv", "csneg":
            guard operands.count == 4 else { return [] }
            return registerReferences(in: operands[1]) + registerReferences(in: operands[2])

        case "cinc", "cinv", "cneg":
            guard operands.count == 3 else { return [] }
            return registerReferences(in: operands[1])

        default:
            return []
        }
    }

    /// FP/SIMD-producing scalar mnemonics whose destination register (operands[0])
    /// must be tracked as *written* so it gates a later read of that register.
    /// Without this, a computed/scratch d/s register surfaced by a generic read
    /// path (e.g. `str d0, [x8]` or `fmov d1, d0`) would be fabricated as a
    /// floating-point parameter. Convert-to-integer forms (`fcvtzs`/`fcvtzu`)
    /// are included but only fire when their destination is actually a scalar FP
    /// register — with a GPR destination they contribute nothing here (and never
    /// reach the integer write set, since we gate on an FP destination below).
    /// `ldr`/`ldur` are intentionally omitted: their FP-destination writes are
    /// already tracked by the shared load/writeback case below (which also
    /// handles the post-index writeback base).
    private static let fpDestinationWriteMnemonics: Set<String> = [
        "fmov", "fadd", "fsub", "fmul", "fdiv", "fmadd", "fmsub", "fnmul",
        "fneg", "fabs", "fsqrt", "fcvt", "fcvtzs", "fcvtzu", "scvtf", "ucvtf"
    ]

    static func argumentRegisterWrites(mnemonic: String, operands: [String]) -> [String] {
        if scalarFPSemantics(mnemonic: mnemonic, operands: operands) != nil, let destination = operands.first {
            return isZeroRegister(destination) ? [] : registerReferences(in: destination)
        }
        // FP-producing mnemonics: mark the destination FP register written when
        // (and only when) operands[0] is a scalar FP register. `fmov` with a GPR
        // destination (a GPR<-FP bit move) is left to the general case below so
        // its existing integer-side handling is byte-identical.
        if fpDestinationWriteMnemonics.contains(mnemonic),
           let destination = operands.first,
           isFmovScalarFPRegister(destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return registerReferences(in: destination)
        }

        switch mnemonic {
        case "str", "stur", "strb", "strh", "sturb", "sturh":
            guard let writeback = scalarWritebackAddress(operands: operands) else { return [] }
            return [writeback.base]

        case "mov", "movz", "movk", "movn", "fmov", "add", "sub", "subs", "adds", "and", "ands", "orr", "eor", "mul", "sdiv", "udiv", "neg", "negs", "mvn", "bic", "bics", "orn", "eon", "lsl", "lsr", "asr", "ror", "ubfx", "sbfx", "ubfiz", "sbfiz", "bfi", "bfxil", "extr", "madd", "msub", "mneg", "umull", "smull", "umaddl", "smaddl", "smsubl", "umsubl", "smulh", "umulh", "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursw", "ldursb", "ldursh", "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw", "clz", "rbit", "rev", "rev16", "rev32", "adr", "adrp", "csel", "csinc", "csinv", "csneg", "cinc", "cinv", "cneg", "cset", "csetm":
            if mnemonic == "fmov",
               !isFmovScalarGPRFPBitMove(operands),
               !isFmovScalarFPFPMove(operands),
               operands.first.flatMap(vectorRegisterIndex) == nil {
                return []
            }
            guard let operand = operands.first else { return [] }
            var writes = isZeroRegister(operand) ? [] : registerReferences(in: operand)
            if writes.isEmpty,
               let vectorDestination = conservativeUnknownVectorWrite(
                   mnemonic: mnemonic,
                   operands: operands
               ) {
                writes.append(vectorDestination)
            }
            if let writeback = scalarWritebackAddress(operands: operands) {
                writes.append(writeback.base)
            }
            return writes

        case "stp":
            guard let base = pairWritebackBase(operands: operands),
                  base != "sp" else { return [] }
            return [base]

        case "ldp", "ldpsw":
            guard operands.count >= 2 else { return [] }
            var writes = registerReferences(in: operands[0]) + registerReferences(in: operands[1])
            if let base = pairWritebackBase(operands: operands),
               base != "sp" {
                writes.append(base)
            }
            return writes

        case "bl", "blr", "blraa", "blrab", "blraaz", "blrabz":
            return hasValidReturningCallOperands(mnemonic: mnemonic, operands: operands)
                ? ["x0"]
                : []

        default:
            if let writes = modernISARegisterWrites(mnemonic: mnemonic, operands: operands) {
                return writes
            }
            if let vectorDestination = conservativeUnknownVectorWrite(
                mnemonic: mnemonic,
                operands: operands
            ) {
                return [vectorDestination]
            }
            return conservativeUnknownScalarFPWrite(
                mnemonic: mnemonic,
                operands: operands
            ).map { [$0] } ?? []
        }
    }

    /// Unknown vector/SIMD instructions follow the same conservative
    /// destination convention as scalar-FP instructions: operand zero is a
    /// definite write except for established read-first families. The returned
    /// spelling is used only to tombstone overlapping scalar facts; it does not
    /// claim a vector parameter or manufacture vector SSA semantics.
    private static func conservativeUnknownVectorWrite(
        mnemonic: String,
        operands: [String]
    ) -> String? {
        guard let first = operands.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              vectorRegisterIndex(first) != nil,
              !mnemonic.hasPrefix("b."),
              unknownClaimsFirstOperandWrite(mnemonic: mnemonic) else {
            return nil
        }
        switch mnemonic {
        case "b", "bl", "blr", "br", "braa", "brab", "braaz", "brabz",
             "blraa", "blrab", "blraaz", "blrabz",
             "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab",
             "cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "fcmpe", "fccmp", "fccmpe",
             "cbz", "cbnz", "tbz", "tbnz":
            return nil
        default:
            return first
        }
    }

    /// Unknown scalar-FP instructions overwhelmingly use operand zero as their
    /// destination. Missing a real write can resurrect an incoming parameter,
    /// while conservatively treating an ambiguous read as a write only loses a
    /// heuristic parameter. Exclude the established read-first families and
    /// tombstone every remaining exact s/d destination.
    private static func conservativeUnknownScalarFPWrite(
        mnemonic: String,
        operands: [String]
    ) -> String? {
        guard let first = operands.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              isFmovScalarFPRegister(first),
              !mnemonic.hasPrefix("st"),
              !mnemonic.hasPrefix("fcmp"),
              !mnemonic.hasPrefix("fccmp") else {
            return nil
        }
        return first
    }

    private static func registerReferences(in operand: String) -> [String] {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("!") {
            normalized.removeLast()
        }

        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            let body = String(normalized.dropFirst().dropLast())
            return splitOperands(body).filter { isRegister($0.lowercased()) }
        }

        let lowercased = normalized.lowercased()
        return isRegister(lowercased) ? [lowercased] : []
    }

    struct WritebackAddress {
        var base: String
        var delta: Int64
        var preIndex: Bool
    }

    static func scalarWritebackAddress(operands: [String]) -> WritebackAddress? {
        if operands.count == 3,
           let base = plainBracketedWritebackBase(operands[1]),
           let delta = parseImmediate(operands[2]) {
            return WritebackAddress(base: base, delta: delta, preIndex: false)
        }

        if operands.count == 2,
           let preIndex = preIndexWritebackBaseAndDelta(operands[1]) {
            return WritebackAddress(base: preIndex.base, delta: preIndex.delta, preIndex: true)
        }

        return nil
    }

    private static func plainBracketedWritebackBase(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("["),
              normalized.hasSuffix("]") else {
            return nil
        }

        let body = String(normalized.dropFirst().dropLast())
        let parts = splitOperands(body)
        guard parts.count == 1 else { return nil }
        return writebackBaseRegister(parts[0])
    }

    private static func preIndexWritebackBaseAndDelta(_ operand: String) -> (base: String, delta: Int64)? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasSuffix("!") else { return nil }
        normalized.removeLast()
        guard normalized.hasPrefix("["),
              normalized.hasSuffix("]") else {
            return nil
        }

        let body = String(normalized.dropFirst().dropLast())
        let parts = splitOperands(body)
        guard parts.count == 2,
              let base = writebackBaseRegister(parts[0]),
              let delta = parseImmediate(parts[1]) else {
            return nil
        }
        return (base, delta)
    }

    static func writebackBaseRegister(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isRegister(normalized),
              !isZeroRegister(normalized) else {
            return nil
        }
        return normalized == "fp" ? "x29" : normalized
    }

    /// Finds a base register that is explicitly updated by pre/post-index memory
    /// syntax, regardless of the mnemonic's modeled-lifting whitelist.
    static func explicitMemoryWritebackBase(operands: [String]) -> String? {
        for operand in operands {
            if let preIndexBase = explicitPreIndexMemoryWritebackBase(operand) {
                return preIndexBase
            }
        }

        guard operands.count >= 2 else { return nil }
        for index in 0..<(operands.count - 1) {
            guard let base = plainBracketedMemoryBase(operands[index]) else {
                continue
            }
            let increment = operands[index + 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if parseImmediate(increment) != nil || isScalarGPRRegister(increment) {
                return base
            }
        }
        return nil
    }

    private static func explicitPreIndexMemoryWritebackBase(_ operand: String) -> String? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasSuffix("!") else { return nil }
        normalized.removeLast()
        // FEAT_MOPS writes back a bare register operand: `xN!`.
        guard normalized.hasPrefix("[") else {
            return writebackBaseRegister(normalized)
        }
        guard normalized.hasSuffix("]") else { return nil }
        let parts = splitOperands(String(normalized.dropFirst().dropLast()))
        // `[xN]!` (FEAT_MOPS) or `[xN, #imm]!` (pre-index).
        if parts.count == 1 {
            return memoryBaseRegister(parts[0])
        }
        guard parts.count == 2,
              parseImmediate(parts[1]) != nil else {
            return nil
        }
        return memoryBaseRegister(parts[0])
    }

    private static func plainBracketedMemoryBase(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        let parts = splitOperands(String(normalized.dropFirst().dropLast()))
        guard parts.count == 1 else { return nil }
        return memoryBaseRegister(parts[0])
    }

    /// Memory operations that definitely write their addressed bytes even though
    /// their exact data/result semantics may remain conservatively unmodeled.
    static let unmodeledMemoryWritePrefixes = [
        "st", "swp", "cas",
        "ldadd", "ldclr", "ldeor", "ldset",
        "ldsmax", "ldsmin", "ldumax", "ldumin",
        "rcw",
    ]

    static func isRegister(_ operand: String) -> Bool {
        guard let first = operand.first else { return false }
        guard ["x", "w", "s", "d", "q", "v"].contains(first) || operand == "sp" || operand == "fp" || operand == "lr" else {
            return false
        }
        return operand.dropFirst().allSatisfy(\.isNumber) || ["sp", "fp", "lr"].contains(operand)
    }

    static func hasOnlyRound2ScalarGPROperands(_ operands: [String]) -> Bool {
        operands.allSatisfy { operand in
            let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains(".") || normalized.contains("[") {
                return false
            }
            return normalized
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .allSatisfy { token in
                    if round2OperandModifierTokens.contains(token) {
                        return true
                    }
                    if parseImmediate(token) != nil {
                        return true
                    }
                    return isRound2ScalarGPRRegister(token)
                }
        }
    }

    private static let round2OperandModifierTokens: Set<String> = [
        "lsl", "lsr", "asr", "ror",
        "sxtb", "sxth", "sxtw",
        "uxtb", "uxth", "uxtw", "uxtx"
    ]

    private static func isRound2ScalarGPRRegister(_ operand: String) -> Bool {
        isRound2XDomainRegister(operand) || isRound2WDomainRegister(operand)
    }

    static func isRound2DataRegister(_ operand: String) -> Bool {
        isRound2XDataRegister(operand) || isRound2WDataRegister(operand)
    }

    static func isRound2XDataRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "xzr" {
            return true
        }
        guard normalized.first == "x",
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (0...30).contains(index)
    }

    static func isRound2WDataRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "wzr" {
            return true
        }
        guard normalized.first == "w",
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (0...30).contains(index)
    }

    static func isRound2XDomainRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "sp" || normalized == "xzr" {
            return true
        }
        guard normalized.first == "x",
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (0...30).contains(index)
    }

    private static func isRound2WDomainRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "wsp" || normalized == "wzr" {
            return true
        }
        guard normalized.first == "w",
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (0...30).contains(index)
    }

    /// A single-register load/store whose data register is a scalar GPR or a scalar FP view
    /// (`b`/`h`/`s`/`d`) and whose address operands are GPR/SP only. Writeback forms of the scalar
    /// FP transfers used to miss the writeback path and drop the base update (A64 oracle).
    /// A q transfer copies 16 bytes; it does not perform vector-lane arithmetic.
    static func hasScalarTransferWithGPRAddress(_ operands: [String]) -> Bool {
        guard let data = operands.first else { return false }
        let register = data.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isScalarFPOrSIMD: Bool = {
            guard !register.contains("."), let prefix = register.first, "bhsdq".contains(prefix),
                  let index = Int(register.dropFirst()), String(index) == String(register.dropFirst()) else { return false }
            return (0...31).contains(index)
        }()
        if isScalarFPOrSIMD {
            return hasOnlyScalarGPROperands(Array(operands.dropFirst()), allowingMemory: true)
        }
        return hasOnlyScalarGPROperands(operands, allowingMemory: true)
    }

    static func hasOnlyScalarGPROperands(_ operands: [String], allowingMemory: Bool = false) -> Bool {
        operands.allSatisfy { operand in
            let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains(".") {
                return false
            }
            if normalized.contains("[") {
                guard allowingMemory,
                      normalized.hasPrefix("[") else {
                    return false
                }
                var memory = normalized
                if memory.hasSuffix("!") {
                    memory.removeLast()
                }
                guard memory.hasPrefix("["),
                      memory.hasSuffix("]") else {
                    return false
                }
                let body = String(memory.dropFirst().dropLast())
                return splitOperands(body).allSatisfy { part in
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if trimmed.contains(".") || looksLikeSIMDRegisterOperand(trimmed) {
                        return false
                    }
                    return !isRegister(trimmed) || isScalarGPRRegister(trimmed)
                }
            }
            if looksLikeSIMDRegisterOperand(normalized) {
                return false
            }
            return !isRegister(normalized) || isScalarGPRRegister(normalized)
        }
    }

    private static func looksLikeSIMDRegisterOperand(_ operand: String) -> Bool {
        guard let first = operand.first,
              ["v", "q", "d", "s", "h", "b"].contains(first) else {
            return false
        }
        let rest = operand.dropFirst()
        return rest.first?.isNumber == true || operand.contains(".") || operand.contains("[")
    }

    static func isScalarGPRRegister(_ operand: String) -> Bool {
        isXRegister(operand)
            || isWRegister(operand)
            || operand == "sp"
            || operand == "fp"
            || operand == "lr"
    }

    static func isFmovScalarGPRFPBitMove(_ operands: [String]) -> Bool {
        guard operands.count == 2 else { return false }
        let destination = operands[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = operands[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destinationIsGPR = isFmovGPRRegister(destination)
        let sourceIsGPR = isFmovGPRRegister(source)
        let destinationIsFP = isFmovScalarFPRegister(destination)
        let sourceIsFP = isFmovScalarFPRegister(source)
        return (destinationIsGPR && sourceIsFP) || (destinationIsFP && sourceIsGPR)
    }

    /// `fmov d1, d0` / `fmov s1, s0` — a pure floating-point register-to-register
    /// move (same register class on both sides, no GPR involved, no immediate,
    /// no SIMD-lane form). Conservative: requires matching prefixes so it never
    /// mis-recognizes a mixed-width or lane-indexed `fmov` variant.
    static func isFmovScalarFPFPMove(_ operands: [String]) -> Bool {
        guard operands.count == 2 else { return false }
        let destination = operands[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = operands[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isFmovScalarFPRegister(destination), isFmovScalarFPRegister(source),
              destination.first == source.first else {
            return false
        }
        return true
    }

    private static func isFmovGPRRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.first == "x" || normalized.first == "w",
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (0...30).contains(index)
    }

    static func isFmovScalarFPRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.contains("."),
              !normalized.contains("["),
              let first = normalized.first,
              ["h", "s", "d"].contains(first),
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (0...31).contains(index)
    }

    static func isXRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "xzr" || normalized == "fp" || normalized == "lr" {
            return true
        }
        guard normalized.first == "x" else { return false }
        return normalized.dropFirst().allSatisfy(\.isNumber)
    }

    static func isWRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "wzr" {
            return true
        }
        guard normalized.first == "w" else { return false }
        return normalized.dropFirst().allSatisfy(\.isNumber)
    }

    static func scalarRegisterBitWidth(_ operand: String) -> Int? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "xzr" || normalized == "wzr" {
            return nil
        }
        if isXRegister(normalized) {
            return 64
        }
        if isWRegister(normalized) {
            return 32
        }
        return nil
    }

    static func zeroRegister(matchingWidthOf operand: String) -> String? {
        switch scalarRegisterBitWidth(operand) {
        case 64:
            return "xzr"
        case 32:
            return "wzr"
        default:
            return nil
        }
    }

    static func registerMask(bitWidth: Int) -> UInt64 {
        bitWidth == 64 ? UInt64.max : (UInt64(1) << UInt64(bitWidth)) - 1
    }

    static func isZeroRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "xzr" || normalized == "wzr"
    }

    static func pairElementByteWidth(for register: String) -> Int64? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "fp" || normalized == "lr" {
            return 8
        }

        switch normalized.first {
        case "x", "d":
            return 8
        case "w", "s":
            return 4
        case "q", "v":
            return 16
        default:
            return nil
        }
    }

    static func pairElementByteWidth(mnemonic: String, register: String) -> Int64? {
        if mnemonic == "ldpsw" {
            return 4
        }
        return pairElementByteWidth(for: register)
    }

    static func shouldPromoteStackStore(sourceOperand: String) -> Bool {
        !isFramePointerRegisterName(sourceOperand) && !isLinkRegisterName(sourceOperand)
    }

    static func shouldPromoteStackPairStore(firstOperand: String, secondOperand: String) -> Bool {
        !(isFramePointerRegisterName(firstOperand) && isLinkRegisterName(secondOperand))
    }

    static func shouldPromoteStackPairLoad(firstOperand: String, secondOperand: String) -> Bool {
        !(isFramePointerRegisterName(firstOperand) && isLinkRegisterName(secondOperand))
    }

    private static func isFramePointerRegisterName(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "fp" || normalized == "x29"
    }

    private static func isLinkRegisterName(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "lr" || normalized == "x30"
    }

    static func argumentRegisterInfo(_ register: String) -> ArgumentRegisterInfo? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = normalized.first else { return nil }

        if prefix == "x" || prefix == "w",
           let index = Int(normalized.dropFirst()),
           (0..<8).contains(index) {
            let width = prefix == "x" ? 64 : 32
            return ArgumentRegisterInfo(
                index: index,
                register: "\(prefix)\(index)",
                width: width,
                type: width == 64 ? "int64_t" : "int32_t"
            )
        }

        // FP/SIMD scalar argument registers (AAPCS64 d0-d7 / s0-s7). Kept
        // separate from the integer branch above so integer recovery is
        // byte-identical; callers must key FP results by register number in
        // their own accumulator (see recoverFunctionParameters) since the
        // index namespace here (0..<8) is shared with the integer branch.
        if prefix == "d" || prefix == "s",
           let index = Int(normalized.dropFirst()),
           (0..<8).contains(index) {
            return ArgumentRegisterInfo(
                index: index,
                register: "\(prefix)\(index)",
                width: prefix == "d" ? 64 : 32,
                type: prefix == "d" ? "double" : "float",
                isFloat: true
            )
        }

        return nil
    }

    /// Parses the register number from a scalar FP register name (`d0`/`s7` -> 0/7).
    /// Returns nil for non-FP or malformed names. Used to key FP catalog params by
    /// register number in the FP parameter accumulator.
    static func fpRegisterNumber(_ register: String) -> Int? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = normalized.first, first == "d" || first == "s",
              let number = Int(normalized.dropFirst()),
              (0..<8).contains(number) else {
            return nil
        }
        return number
    }

    private static let vectorArrangementSuffixes: Set<String> = [
        ".8b", ".16b", ".4h", ".8h", ".2s", ".4s", ".1d", ".2d",
    ]

    /// ★ Insight ─────────────────────────────────────
    /// qN and every vN arrangement/lane spelling name the same 128-bit physical
    /// register whose low bits are exposed as dN and sN. Parsing that identity
    /// centrally lets definite vector writes invalidate stale scalar evidence
    /// without pretending that a vector value proves a scalar type or argument.
    /// ─────────────────────────────────────────────────
    static func vectorRegisterIndex(_ register: String) -> Int? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = normalized.first, prefix == "q" || prefix == "v" else {
            return nil
        }

        let body = normalized.dropFirst()
        let digits = body.prefix(while: \.isNumber)
        guard !digits.isEmpty,
              digits == "0" || digits.first != "0",
              let index = Int(digits),
              (0...31).contains(index) else {
            return nil
        }

        let suffix = String(body.dropFirst(digits.count))
        if prefix == "q" {
            return suffix.isEmpty ? index : nil
        }
        if suffix.isEmpty || vectorArrangementSuffixes.contains(suffix) {
            return index
        }

        // Lane destinations such as v0.d[1] still partially overwrite the
        // scalar view, so retaining any prior d0/s0 fact would be unsound.
        guard suffix.hasPrefix("."), suffix.hasSuffix("]") else { return nil }
        let laneSuffix = String(suffix.dropFirst())
        guard let bracket = laneSuffix.firstIndex(of: "[") else { return nil }
        let element = String(laneSuffix[..<bracket])
        let laneStart = laneSuffix.index(after: bracket)
        let laneEnd = laneSuffix.index(before: laneSuffix.endIndex)
        guard laneStart <= laneEnd else { return nil }
        let laneDigits = laneSuffix[laneStart..<laneEnd]
        guard !laneDigits.isEmpty,
              laneDigits.allSatisfy(\.isNumber),
              laneDigits == "0" || laneDigits.first != "0",
              let lane = Int(laneDigits) else {
            return nil
        }
        let laneCount: Int
        switch element {
        case "b": laneCount = 16
        case "h": laneCount = 8
        case "s": laneCount = 4
        case "d": laneCount = 2
        default: return nil
        }
        return (0..<laneCount).contains(lane) ? index : nil
    }

    static func integerRegisterView(_ register: String) -> (index: Int, width: Int)? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = normalized.first, prefix == "x" || prefix == "w" else {
            return nil
        }
        let suffix = normalized.dropFirst()
        guard !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber),
              suffix == "0" || suffix.first != "0",
              let index = Int(suffix),
              (0...30).contains(index) else {
            return nil
        }
        return (index, prefix == "x" ? 64 : 32)
    }

    static func branchCondition(for suffix: String) -> String? {
        switch suffix {
        case "eq":
            return "=="
        case "ne":
            return "!="
        case "lt":
            return "<"
        case "le":
            return "<="
        case "gt":
            return ">"
        case "ge":
            return ">="
        case "hs", "cs":
            return ">="
        case "lo", "cc":
            return "<"
        case "hi":
            return ">"
        case "ls":
            return "<="
        default:
            return nil
        }
    }

    static func isConditionalCompareInstruction(_ mnemonic: String) -> Bool {
        switch mnemonic.lowercased() {
        case "ccmp", "ccmn", "fccmp", "fccmpe":
            return true
        default:
            return false
        }
    }

    /// A26: rows that leave a pending cmp/ccmp live. Conservative allowlist of
    /// flag-neutral scalar ALU/move rows with a general-register destination
    /// that the comparison does not read. Everything else clears it.
    static func preservesPendingComparison(
        mnemonic: String,
        operands: [String],
        adjacent: BuilderComparison?,
        pending: PendingConditionalCompare?,
        destinationValue: MacIRValue?
    ) -> Bool {
        let neutral: Set<String> = [
            "lsl", "lsr", "asr", "ror", "add", "sub", "and", "orr", "eor", "orn", "eon", "bic",
            "mov", "movz", "movk", "mvn", "neg", "mul", "madd", "msub", "mneg", "udiv", "sdiv",
            "sxtw", "sxth", "sxtb", "uxtw", "uxth", "uxtb", "ubfx", "sbfx", "ubfiz", "sbfiz",
            "bfi", "bfxil", "adrp", "adr", "nop"
        ]
        let name = mnemonic.lowercased()
        guard neutral.contains(name), !writesNZCVFlags(name) else { return false }
        if name == "nop" { return true }
        guard let destination = operands.first, let index = generalRegisterIndex(destination) else { return false }
        var read = Set<Int>(), values = Set<MacIRValue>()
        for comparison in [adjacent, pending?.firstComparison].compactMap({ $0 }) {
            collectRegisterIndices(comparison.left, into: &read, values: &values)
            collectRegisterIndices(comparison.right, into: &read, values: &values)
        }
        if let pending {
            collectRegisterIndices(pending.left, into: &read, values: &values)
            collectRegisterIndices(pending.right, into: &read, values: &values)
        }
        // The destination's current value is what the comparison may have read
        // (an argument or earlier SSA value), whatever register named it then.
        if let destinationValue, values.contains(destinationValue) { return false }
        return !read.contains(index)
    }

    private static func generalRegisterIndex(_ operand: String) -> Int? {
        let text = operand.lowercased()
        guard let first = text.first, first == "w" || first == "x",
              let index = Int(text.dropFirst()), (0...30).contains(index) else { return nil }
        return index
    }

    private static func collectRegisterIndices(
        _ value: MacIRValue, into indices: inout Set<Int>, values: inout Set<MacIRValue>
    ) {
        values.insert(value)
        switch value {
        case let .register(name, _):
            if let index = generalRegisterIndex(name) { indices.insert(index) }
        case let .signedBitfield(field):
            collectRegisterIndices(field.source, into: &indices, values: &values)
        case let .bitTest(inner, _), let .unary(_, inner):
            collectRegisterIndices(inner, into: &indices, values: &values)
        case let .binaryExpression(_, left, right):
            collectRegisterIndices(left, into: &indices, values: &values)
            collectRegisterIndices(right, into: &indices, values: &values)
        default:
            break
        }
    }

    static func writesNZCVFlags(_ mnemonic: String) -> Bool {
        switch mnemonic.lowercased() {
        case "cmp", "cmn", "tst", "subs", "adds", "negs",
             "ands", "bics", "adcs", "sbcs", "fcmp", "fcmpe":
            return true
        default:
            return isModernISANZCVWriter(mnemonic.lowercased())
        }
    }

    static func invertedConditionSuffix(for suffix: String) -> String? {
        switch suffix.lowercased() {
        case "eq":
            return "ne"
        case "ne":
            return "eq"
        case "lt":
            return "ge"
        case "le":
            return "gt"
        case "gt":
            return "le"
        case "ge":
            return "lt"
        case "hs", "cs":
            return "lo"
        case "lo", "cc":
            return "hs"
        case "hi":
            return "ls"
        case "ls":
            return "hi"
        default:
            return nil
        }
    }

    static func firstOperandWriteForUnknown(mnemonic: String, operands: [String]) -> String? {
        guard !mnemonic.hasPrefix("b."),
              let first = operands.first else {
            return nil
        }
        let normalizedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isStackPointer = normalizedFirst == "sp" || normalizedFirst == "wsp"
        guard isStackPointer
                || (hasOnlyScalarGPROperands([first]) && scalarRegisterBitWidth(first) != nil) else {
            return nil
        }
        switch mnemonic {
        case "b", "bl", "blr", "br", "braa", "brab", "braaz", "brabz",
             "blraa", "blrab", "blraaz", "blrabz",
             "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab",
             "cmp", "cmn", "tst", "ccmp", "ccmn", "cbz", "cbnz", "tbz", "tbnz":
            return nil
        default:
            return normalizedFirst
        }
    }

    /// Mnemonic families whose FIRST operand is a read even though it is a
    /// scalar GPR: every store form (`st*` — including the status-writing
    /// `stxr`/`stlxr`, sacrificed conservatively, and the result-less LSE
    /// `st<op>` forms), `swp*` and the LSE `ld<op>*` read-modify-writes
    /// (both write their SECOND operand), `cas*` (kept on the bare path
    /// conservatively), the NZCV manipulators `rmif`/`setf8`/`setf16`, and
    /// the `wfet`/`wfit` timeout waits. `firstOperandWriteForUnknown`
    /// over-approximates — safe for cache invalidation, not for claiming an
    /// SSA destination.
    private static let unknownFirstOperandReadPrefixes = [
        "st", "swp", "cas",
        "ldadd", "ldclr", "ldeor", "ldset",
        "ldsmax", "ldsmin", "ldumax", "ldumin",
        "rmif", "setf8", "setf16", "wfet", "wfit",
        "rcw",
    ]

    /// Whether a fall-through-to-`__unknown` mnemonic definitely overwrites
    /// its first scalar-GPR operand, so the lift may claim it as the op's
    /// destination (fresh SSA version + rendered LHS). Claiming a phantom
    /// destination on a first-operand READ would sever true dataflow — the
    /// inverse of the stale-binding bug this predicate exists to fix — so
    /// the read families above always stay on the bare `__unknown` path.
    static func unknownClaimsFirstOperandWrite(mnemonic: String) -> Bool {
        !unknownFirstOperandReadPrefixes.contains(where: mnemonic.hasPrefix)
    }
}

// MARK: - Unknown-instruction read sets (HOP-2)

// What an instruction that falls through to `.unknown` reads, as register
// names. MacIRBuilder binds each name to its pre-instruction SSA value. The
// may/definite split and its contract are documented on
// `MacIRUnknownInputs` (MacIR.swift). Stateless and text-only, like the
// write rules above.
extension MacIRBuilder {
    struct UnknownReadSets: Equatable {
        var mayRead: [String]
        var definiteRead: [String]
        var mayReadNZCV: Bool
        var definitelyReadsNZCV: Bool
    }

    static func unknownInstructionReadSets(mnemonic rawMnemonic: String, operands: [String]) -> UnknownReadSets {
        let mnemonic = rawMnemonic.lowercased()
        var mayRead: [String] = []
        func append(_ names: [String], to list: inout [String]) {
            for name in names where !list.contains(name) {
                list.append(name)
            }
        }

        for (index, operand) in operands.enumerated() {
            if index == 0, unknownFirstOperandIsWriteOnly(mnemonic: mnemonic, operands: operands) { continue }
            if index == 1, unknownSecondOperandIsWriteOnly(mnemonic: mnemonic, operands: operands) { continue }
            append(unknownOperandRegisterReads(operand), to: &mayRead)
        }
        append(unknownImplicitRegisterReads(mnemonic: mnemonic), to: &mayRead)

        var definiteRead: [String] = []
        let precise = argumentRegisterReads(mnemonic: mnemonic, operands: operands)
            .flatMap(unknownOperandRegisterReads)
        append(precise + unknownDefiniteSourceReads(mnemonic: mnemonic, operands: operands), to: &definiteRead)
        definiteRead = definiteRead.filter { mayRead.contains($0) }

        let definitelyReadsNZCV = unknownDefinitelyReadsNZCV(mnemonic: mnemonic, operands: operands)
        let mayReadNZCV = definitelyReadsNZCV
            || ["rmif", "setf8", "setf16"].contains(mnemonic)
            || operands.dropFirst().contains { conditionCodeOperands.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        return UnknownReadSets(
            mayRead: mayRead,
            definiteRead: definiteRead,
            mayReadNZCV: mayReadNZCV,
            definitelyReadsNZCV: definitelyReadsNZCV
        )
    }

    /// Every register named in one operand: plain registers, memory base and
    /// index registers, register lists (`{v0.16b-v3.16b}` expands), and SVE
    /// `z`/`p` registers. Canonicalised by `canonicalUnknownReadRegister`.
    static func unknownOperandRegisterReads(_ operand: String) -> [String] {
        var names: [String] = []
        var token = ""
        func flush() {
            if let name = canonicalUnknownReadRegister(token), !names.contains(name) {
                names.append(name)
            }
            token = ""
        }
        let lowercased = operand.lowercased()
        for character in lowercased {
            if character.isLetter || character.isNumber || character == "_" {
                token.append(character)
            } else {
                flush()
            }
        }
        flush()
        // `{v0.16b-v3.16b}` names v0…v3, not only the endpoints.
        if lowercased.contains("{"), lowercased.contains("-"), names.count == 2,
           let first = names.first?.first, first == names.last?.first, first == "v" || first == "z",
           let low = Int(names[0].dropFirst()), let high = Int(names[1].dropFirst()) {
            let count = (high - low + 32) % 32
            names = (0...count).map { "\(first)\(($0 + low) % 32)" }
        }
        return names
    }

    /// `fp`/`lr` -> `x29`/`x30`, `wsp` -> `sp`, vector suffixes dropped by
    /// the tokenizer; zero registers and non-register tokens -> nil.
    static func canonicalUnknownReadRegister(_ token: String) -> String? {
        switch token {
        case "fp": return "x29"
        case "lr": return "x30"
        case "sp", "wsp": return "sp"
        case "xzr", "wzr": return nil
        default: break
        }
        let prefix = token.hasPrefix("pn") ? "pn" : token.first.map { String($0) } ?? ""
        let digits = token.dropFirst(prefix.count)
        guard !digits.isEmpty,
              digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              digits == "0" || digits.first != "0",
              let index = Int(digits) else {
            return nil
        }
        switch prefix {
        case "x", "w": return index <= 30 ? token : nil
        case "b", "h", "s", "d", "q", "v", "z": return index <= 31 ? token : nil
        case "p", "pn": return index <= 15 ? token : nil
        default: return nil
        }
    }

    /// Whether operand zero is a bare register the instruction only writes.
    /// Read-first families, non-writing compare/branch families,
    /// read-modify-write destinations and anything that is not a bare
    /// register (memory, lists, lanes) stay in the may-read set.
    private static func unknownFirstOperandIsWriteOnly(mnemonic: String, operands: [String]) -> Bool {
        guard let first = operands.first?.trimmingCharacters(in: .whitespaces).lowercased(),
              !first.contains("["), !first.contains("{"),
              unknownOperandRegisterReads(first).count == 1 else {
            return false
        }
        // Exclusive-store status registers are written, never read.
        if exclusiveStoreStatusMnemonics.contains(mnemonic) { return true }
        guard unknownClaimsFirstOperandWrite(mnemonic: mnemonic),
              !mnemonic.hasPrefix("b."), !mnemonic.hasPrefix("bc."),
              !unknownNonWritingMnemonics.contains(mnemonic),
              !unknownReadModifyWriteDestinationMnemonics.contains(mnemonic),
              !mnemonic.hasSuffix("n2"),
              !operands.contains(where: { $0.lowercased().hasSuffix("/m") }) else {
            return false
        }
        return true
    }

    /// `ld<op>`/`swp` and RCW swp/clr/set write their second operand (Xt)
    /// without reading it; the LSE128 pair forms (`ldsetp`, `swpp`, …) read
    /// both. Exclusive/non-temporal pair loads write both destinations.
    private static func unknownSecondOperandIsWriteOnly(mnemonic: String, operands: [String]) -> Bool {
        if ["ldxp", "ldaxp", "ldnp", "ldiapp"].contains(mnemonic) { return true }
        guard operands.count == 3,
              let family = lseResultFamily(mnemonic) else {
            return false
        }
        return !mnemonic.dropFirst(family.count).hasPrefix("p")
    }

    private static func lseResultFamily(_ mnemonic: String) -> String? {
        let families = [
            "ldadd", "ldclr", "ldeor", "ldset", "ldsmax", "ldsmin", "ldumax", "ldumin", "swp",
            "rcwswp", "rcwclr", "rcwset", "rcwsswp", "rcwsclr", "rcwsset",
        ]
        return families.first(where: mnemonic.hasPrefix)
    }

    private static func unknownImplicitRegisterReads(mnemonic: String) -> [String] {
        switch mnemonic {
        case "paciasp", "pacibsp", "autiasp", "autibsp":
            return ["x30", "sp"]
        case "paciaz", "pacibz", "autiaz", "autibz", "xpaclri":
            return ["x30"]
        case "pacia1716", "pacib1716", "autia1716", "autib1716":
            return ["x17", "x16"]
        default:
            return mnemonic.contains("sppc") ? ["x30", "sp"] : []
        }
    }

    /// Source operands the encoding certainly reads, for families the
    /// precise `argumentRegisterReads` table does not list.
    private static func unknownDefiniteSourceReads(mnemonic: String, operands: [String]) -> [String] {
        func reads(_ indexes: [Int]) -> [String] {
            indexes.filter { $0 < operands.count }.flatMap { unknownOperandRegisterReads(operands[$0]) }
        }
        let memory = operands.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .flatMap(unknownOperandRegisterReads)
        switch mnemonic {
        case "fmadd", "fmsub", "fnmadd", "fnmsub":
            return operands.count == 4 ? reads([1, 2, 3]) : []
        case "fadd", "fsub", "fmul", "fdiv", "fnmul", "fmax", "fmin", "fmaxnm", "fminnm", "fabd":
            return operands.count == 3 ? reads([1, 2]) : []
        case "fneg", "fabs", "fsqrt", "fcvt", "scvtf", "ucvtf", "fcvtzs", "fcvtzu",
             "frinta", "frinti", "frintm", "frintn", "frintp", "frintx", "frintz":
            return operands.count >= 2 ? reads([1]) : []
        case "fcmp", "fcmpe", "fccmp", "fccmpe", "ccmp", "ccmn", "chkfeat":
            return reads([0, 1])
        case "fcsel", "adc", "adcs", "sbc", "sbcs":
            return operands.count >= 3 ? reads([1, 2]) : []
        case "ngc", "ngcs":
            return operands.count == 2 ? reads([1]) : []
        case "ldar", "ldarb", "ldarh", "ldapr", "ldaprb", "ldaprh", "ldlar", "ldlarb", "ldlarh",
             "ldxr", "ldxrb", "ldxrh", "ldaxr", "ldaxrb", "ldaxrh", "ldxp", "ldaxp":
            return memory
        case "stlr", "stlrb", "stlrh", "stllr", "stllrb", "stllrh", "stlur", "stlurb", "stlurh":
            return reads([0]) + memory
        default:
            break
        }
        if exclusiveStoreStatusMnemonics.contains(mnemonic) {
            return reads(Array(1..<max(1, operands.count - 1))) + memory
        }
        if mnemonic.hasPrefix("cas") || mnemonic.hasPrefix("rcwcas") || mnemonic.hasPrefix("rcwscas") {
            return reads(Array(0..<max(0, operands.count - 1))) + memory
        }
        if let family = lseResultFamily(mnemonic) {
            let isPair = mnemonic.dropFirst(family.count).hasPrefix("p")
            return reads(isPair ? [0, 1] : [0]) + memory
        }
        if ["stadd", "stclr", "steor", "stset", "stsmax", "stsmin", "stumax", "stumin"].contains(where: mnemonic.hasPrefix) {
            return reads([0]) + memory
        }
        return []
    }

    private static func unknownDefinitelyReadsNZCV(mnemonic: String, operands: [String]) -> Bool {
        if mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.") { return true }
        if mnemonic == "mrs" { return operands.contains { $0.lowercased().contains("nzcv") } }
        return nzcvReadingMnemonics.contains(mnemonic)
    }

    private static let nzcvReadingMnemonics: Set<String> = [
        "adc", "adcs", "sbc", "sbcs", "ngc", "ngcs",
        "csel", "csinc", "csinv", "csneg", "cset", "csetm", "cinc", "cinv", "cneg",
        "ccmp", "ccmn", "fccmp", "fccmpe", "fcsel", "cfinv", "axflag", "xaflag",
    ]

    private static let conditionCodeOperands: Set<String> = [
        "eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le",
    ]

    private static let exclusiveStoreStatusMnemonics: Set<String> = [
        "stxr", "stxrb", "stxrh", "stlxr", "stlxrb", "stlxrh", "stxp", "stlxp",
    ]

    /// Mnemonics whose first register operand is a source: compares,
    /// conditional compares, compare-and-branch and indirect branches.
    private static let unknownNonWritingMnemonics: Set<String> = [
        "b", "bl", "blr", "br", "braa", "brab", "braaz", "brabz", "blraa", "blrab", "blraaz", "blrabz",
        "ret", "retaa", "retab", "cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "fcmpe", "fccmp", "fccmpe",
        "cbz", "cbnz", "tbz", "tbnz", "msr",
    ]

    /// Destinations the instruction reads before writing: bitfield inserts,
    /// `movk`, accumulating/dot-product SIMD, shift-and-insert/accumulate,
    /// bitwise selects, `tbx`, `ins`, and `chkfeat`. Narrowing `…n2` forms
    /// (upper-half writes) and SVE merging predication (`/m`) are matched
    /// by shape in `unknownFirstOperandIsWriteOnly`.
    private static let unknownReadModifyWriteDestinationMnemonics: Set<String> = [
        "bfi", "bfxil", "bfm", "bfc", "movk", "ins", "tbx", "bsl", "bit", "bif", "chkfeat",
        "fmla", "fmls", "mla", "mls", "sdot", "udot", "usdot", "sudot", "bfdot", "fdot",
        "fmlal", "fmlal2", "fmlsl", "fmlsl2", "bfmlalb", "bfmlalt", "bfmmla", "smmla", "ummla", "usmmla",
        "fcmla", "smlal", "smlal2", "smlsl", "smlsl2", "umlal", "umlal2", "umlsl", "umlsl2",
        "sqdmlal", "sqdmlal2", "sqdmlsl", "sqdmlsl2", "sqrdmlah", "sqrdmlsh",
        "saba", "uaba", "sabal", "sabal2", "uabal", "uabal2", "sadalp", "uadalp",
        "ssra", "usra", "srsra", "ursra", "sli", "sri",
    ]
}

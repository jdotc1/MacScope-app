import Foundation

extension ARM64Decoder {
    /// Add/subtract with carry: `sf op S 11010000 Rm 000000 Rn Rd` (ADC, ADCS, SBC, SBCS). SBC/SBCS
    /// with Rn = 31 print as the NGC/NGCS aliases, as LLVM does.
    func decodeAddSubtractWithCarry(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isSubtract = (word & 0x4000_0000) != 0
        let setsFlags = (word & 0x2000_0000) != 0
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        if isSubtract && rn == 31 {
            return instruction(
                address, bytes, setsFlags ? "ngcs" : "ngc",
                "\(register(rd, is64Bit: is64Bit)), \(register(rm, is64Bit: is64Bit))"
            )
        }
        let name = (isSubtract ? "sbc" : "adc") + (setsFlags ? "s" : "")
        return instruction(address, bytes, name, threeRegisters(rd, rn, rm, is64Bit: is64Bit))
    }

    func decodeConditionalCompare(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        // o2 (bit10) and o3 (bit4) are reserved-zero.
        guard (word & 0x0000_0410) == 0 else { return unknownInstruction(address, bytes, word) }
        let is64Bit = (word & 0x8000_0000) != 0
        let isCompare = (word & 0x4000_0000) != 0 // bit30: 1 = ccmp, 0 = ccmn
        let isImmediate = (word & 0x0000_0800) != 0 // bit11
        let condition = Int((word >> 12) & 0xf)
        let rn = Int((word >> 5) & 0x1f)
        let nzcv = UInt64(word & 0xf)
        let mnemonic = isCompare ? "ccmp" : "ccmn"
        let secondOperand: String
        if isImmediate {
            secondOperand = "#\(formatImmediate(UInt64((word >> 16) & 0x1f)))"
        } else {
            secondOperand = register(Int((word >> 16) & 0x1f), is64Bit: is64Bit)
        }
        return instruction(
            address,
            bytes,
            mnemonic,
            "\(register(rn, is64Bit: is64Bit)), \(secondOperand), #\(formatImmediate(nzcv)), \(conditionName(condition))"
        )
    }

    func decodeConditionalSelect(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let op = (word >> 30) & 0x1
        let s = (word >> 29) & 0x1
        let op2 = (word >> 10) & 0x3
        let second = Int((word >> 16) & 0x1f)
        let condition = Int((word >> 12) & 0xf)
        let first = Int((word >> 5) & 0x1f)
        let destination = Int(word & 0x1f)

        guard s == 0 else { return unknownInstruction(address, bytes, word) }
        let rdName = register(destination, is64Bit: is64Bit)
        let rnName = register(first, is64Bit: is64Bit)

        // Alias forms exist only when the condition can be inverted (not AL/NV):
        // cset/csetm when both sources are the zero register, cinc/cinv/cneg when
        // the two sources are the same non-zero register.
        if let inverted = invertedConditionName(condition) {
            switch (op, op2) {
            case (0, 1): // CSINC
                if first == 31 && second == 31 { return instruction(address, bytes, "cset", "\(rdName), \(inverted)") }
                if first == second { return instruction(address, bytes, "cinc", "\(rdName), \(rnName), \(inverted)") }
            case (1, 0): // CSINV
                if first == 31 && second == 31 { return instruction(address, bytes, "csetm", "\(rdName), \(inverted)") }
                if first == second { return instruction(address, bytes, "cinv", "\(rdName), \(rnName), \(inverted)") }
            case (1, 1): // CSNEG
                if first == second { return instruction(address, bytes, "cneg", "\(rdName), \(rnName), \(inverted)") }
            default:
                break
            }
        }

        if let mnemonic = conditionalSelectMnemonic(op: op, op2: op2) {
            return instruction(
                address,
                bytes,
                mnemonic,
                "\(rdName), \(rnName), \(register(second, is64Bit: is64Bit)), \(conditionName(condition))"
            )
        }

        return unknownInstruction(address, bytes, word)
    }

    private func conditionalSelectMnemonic(op: UInt32, op2: UInt32) -> String? {
        switch (op, op2) {
        case (0, 0):
            return "csel"
        case (0, 1):
            return "csinc"
        case (1, 0):
            return "csinv"
        case (1, 1):
            return "csneg"
        default:
            return nil
        }
    }

    // MARK: - Data-processing (register)

    private func threeRegisters(_ rd: Int, _ rn: Int, _ rm: Int, is64Bit: Bool) -> String {
        "\(register(rd, is64Bit: is64Bit)), \(register(rn, is64Bit: is64Bit)), \(register(rm, is64Bit: is64Bit))"
    }

    func decodeSubtractPointer(word: UInt32, bytes: [UInt8], address: UInt64, setsFlags: Bool) -> DecodedInstruction {
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let operands = "\(register(rd, is64Bit: true)), \(register(rn, is64Bit: true, useStackPointer: true)), \(register(rm, is64Bit: true, useStackPointer: true))"
        return instruction(address, bytes, setsFlags ? "subps" : "subp", operands)
    }

    private func decodeInsertRandomTag(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        var operands = "\(register(rd, is64Bit: true, useStackPointer: true)), \(register(rn, is64Bit: true, useStackPointer: true))"
        if rm != 31 {
            operands += ", \(register(rm, is64Bit: true))"
        }
        return instruction(address, bytes, "irg", operands)
    }

    private func decodeTagMaskInsert(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let operands = "\(register(rd, is64Bit: true)), \(register(rn, is64Bit: true, useStackPointer: true)), \(register(rm, is64Bit: true))"
        return instruction(address, bytes, "gmi", operands)
    }

    /// Renders the optional `, <shift> #<amount>` suffix of a shifted-register
    /// data-processing instruction. An amount of zero (LSL #0) renders as empty,
    /// matching disassembler convention. `allowRotate` selects whether the `0b11`
    /// shift type decodes as ROR (logical ops) or is treated as LSL (add/sub,
    /// where ROR is unallocated and should never appear in valid code).
    private func shiftedRegisterSuffix(word: UInt32, allowRotate: Bool) -> String {
        let amount = (word >> 10) & 0x3f
        guard amount != 0 else { return "" }
        let shiftType = (word >> 22) & 0x3
        let name: String
        switch shiftType {
        case 0: name = "lsl"
        case 1: name = "lsr"
        case 2: name = "asr"
        default: name = allowRotate ? "ror" : "lsl"
        }
        return ", \(name) #\(amount)"
    }

    func decodeAddSubtractShiftedRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isSubtract = (word & 0x4000_0000) != 0
        let setsFlags = (word & 0x2000_0000) != 0
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        // shift = 11 (ROR) is reserved for add/sub, and sf=0 allows only amounts 0-31.
        guard (word >> 22) & 0x3 != 0b11, is64Bit || (word & 0x8000) == 0 else {
            return unknownInstruction(address, bytes, word)
        }
        let suffix = shiftedRegisterSuffix(word: word, allowRotate: false)
        let rdName = register(rd, is64Bit: is64Bit)
        let rnName = register(rn, is64Bit: is64Bit)
        let rmName = register(rm, is64Bit: is64Bit)
        let opcode = (isSubtract ? "sub" : "add") + (setsFlags ? "s" : "")
        let shiftKinds: [InstructionOperands.RegisterModifier.Kind] = [.lsl, .lsr, .asr]
        let typedOperands: [InstructionOperands.Operand] = [
            .register(arithmeticRegister(rd, is64Bit: is64Bit)),
            .register(arithmeticRegister(rn, is64Bit: is64Bit)),
            .modifiedRegister(arithmeticRegister(rm, is64Bit: is64Bit),
                .init(shiftKinds[Int((word >> 22) & 0x3)], amount: Int((word >> 10) & 0x3f), omitWhenZero: true)),
        ]
        func sidecar(alias: String? = nil, omitted: [Int] = []) -> InstructionOperands {
            .init(coverage: .complete, opcodeClass: opcode, operands: typedOperands,
                  presentation: .init(mnemonic: opcode, alias: alias, omittedOperandIndices: omitted))
        }

        switch (isSubtract, setsFlags) {
        case (false, false):
            return instruction(address, bytes, "add", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix,
                               structuredOperands: sidecar())
        case (false, true):
            if rd == 31 { return instruction(address, bytes, "cmn", "\(rnName), \(rmName)\(suffix)",
                                             structuredOperands: sidecar(alias: "cmn", omitted: [0])) }
            return instruction(address, bytes, "adds", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix,
                               structuredOperands: sidecar())
        case (true, false):
            if rn == 31 { return instruction(address, bytes, "neg", "\(rdName), \(rmName)\(suffix)",
                                             structuredOperands: sidecar(alias: "neg", omitted: [1])) }
            return instruction(address, bytes, "sub", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix,
                               structuredOperands: sidecar())
        case (true, true):
            if rd == 31 { return instruction(address, bytes, "cmp", "\(rnName), \(rmName)\(suffix)",
                                             structuredOperands: sidecar(alias: "cmp", omitted: [0])) }
            if rn == 31 { return instruction(address, bytes, "negs", "\(rdName), \(rmName)\(suffix)",
                                             structuredOperands: sidecar(alias: "negs", omitted: [1])) }
            return instruction(address, bytes, "subs", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix,
                               structuredOperands: sidecar())
        }
    }

    func decodeAddSubtractExtendedRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isSubtract = (word & 0x4000_0000) != 0
        let setsFlags = (word & 0x2000_0000) != 0
        let rm = Int((word >> 16) & 0x1f)
        let option = (word >> 13) & 0x7
        let imm3 = (word >> 10) & 0x7
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        // Extend amounts above 4 are reserved.
        guard imm3 <= 4 else { return unknownInstruction(address, bytes, word) }

        // The index register is X only for 64-bit uxtx/sxtx (option x11); otherwise W
        // (the 32-bit forms always read Wm, even with uxtx/sxtx).
        let rmName = register(rm, is64Bit: is64Bit && (option & 0x3) == 0x3)

        // The "natural" extend (uxtx for 64-bit, uxtw for 32-bit) prints as `lsl` (or nothing
        // when the amount is zero) only when the stack pointer is involved: Rn = 31, or Rd = 31
        // for the non-flag-setting forms (where Rd is SP). Otherwise every extend prints its
        // name with an optional amount.
        let extendName: String
        switch option {
        case 0b000: extendName = "uxtb"
        case 0b001: extendName = "uxth"
        case 0b010: extendName = "uxtw"
        case 0b011: extendName = "uxtx"
        case 0b100: extendName = "sxtb"
        case 0b101: extendName = "sxth"
        case 0b110: extendName = "sxtw"
        default: extendName = "sxtx"
        }
        let usesStackPointer = rn == 31 || (!setsFlags && rd == 31)
        let isNaturalExtend = usesStackPointer && ((is64Bit && option == 0b011) || (!is64Bit && option == 0b010))
        let suffix: String
        if isNaturalExtend {
            suffix = imm3 == 0 ? "" : ", lsl #\(imm3)"
        } else {
            suffix = imm3 == 0 ? ", \(extendName)" : ", \(extendName) #\(imm3)"
        }

        let rnName = register(rn, is64Bit: is64Bit, useStackPointer: true)
        let opcode = (isSubtract ? "sub" : "add") + (setsFlags ? "s" : "")
        let extendKinds: [InstructionOperands.RegisterModifier.Kind] = [.uxtb, .uxth, .uxtw, .uxtx, .sxtb, .sxth, .sxtw, .sxtx]
        let typedOperands: [InstructionOperands.Operand] = [
            .register(arithmeticRegister(rd, is64Bit: is64Bit, stackPointer: !setsFlags)),
            .register(arithmeticRegister(rn, is64Bit: is64Bit, stackPointer: true)),
            .modifiedRegister(arithmeticRegister(rm, is64Bit: is64Bit && (option & 0x3) == 0x3),
                .init(extendKinds[Int(option)], amount: Int(imm3), omitZeroAmount: true,
                      omitWhenZero: isNaturalExtend, presentationKind: isNaturalExtend ? .lsl : nil)),
        ]
        func sidecar(alias: String? = nil, omitted: [Int] = []) -> InstructionOperands {
            .init(coverage: .complete, opcodeClass: opcode, operands: typedOperands,
                  presentation: .init(mnemonic: opcode, alias: alias, omittedOperandIndices: omitted))
        }

        if setsFlags {
            if rd == 31 {
                return instruction(address, bytes, isSubtract ? "cmp" : "cmn", "\(rnName), \(rmName)\(suffix)",
                                   structuredOperands: sidecar(alias: isSubtract ? "cmp" : "cmn", omitted: [0]))
            }
            return instruction(address, bytes, isSubtract ? "subs" : "adds", "\(register(rd, is64Bit: is64Bit)), \(rnName), \(rmName)\(suffix)",
                               structuredOperands: sidecar())
        }
        let rdName = register(rd, is64Bit: is64Bit, useStackPointer: true)
        return instruction(address, bytes, isSubtract ? "sub" : "add", "\(rdName), \(rnName), \(rmName)\(suffix)",
                           structuredOperands: sidecar())
    }

    func decodeLogicalShiftedRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let opc = (word >> 29) & 0x3
        let negate = (word >> 21) & 0x1
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        // sf=0 allows only shift amounts 0-31.
        guard is64Bit || (word & 0x8000) == 0 else { return unknownInstruction(address, bytes, word) }
        let suffix = shiftedRegisterSuffix(word: word, allowRotate: true)
        let unshifted = ((word >> 10) & 0x3f) == 0 && ((word >> 22) & 0x3) == 0
        let rdName = register(rd, is64Bit: is64Bit)
        let rnName = register(rn, is64Bit: is64Bit)
        let rmName = register(rm, is64Bit: is64Bit)

        switch (opc, negate) {
        case (0b00, 0):
            return instruction(address, bytes, "and", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        case (0b00, 1):
            return instruction(address, bytes, "bic", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        case (0b01, 0):
            // MOV (register) is the preferred alias only with LSL #0.
            if rn == 31 && unshifted { return instruction(address, bytes, "mov", "\(rdName), \(rmName)") }
            return instruction(address, bytes, "orr", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        case (0b01, 1):
            if rn == 31 { return instruction(address, bytes, "mvn", "\(rdName), \(rmName)\(suffix)") }
            return instruction(address, bytes, "orn", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        case (0b10, 0):
            return instruction(address, bytes, "eor", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        case (0b10, 1):
            return instruction(address, bytes, "eon", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        case (0b11, 0):
            if rd == 31 { return instruction(address, bytes, "tst", "\(rnName), \(rmName)\(suffix)") }
            return instruction(address, bytes, "ands", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        default:
            return instruction(address, bytes, "bics", threeRegisters(rd, rn, rm, is64Bit: is64Bit) + suffix)
        }
    }

    func decodeDataProcessingOneSource(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let opcode2 = (word >> 16) & 0x1f
        let opcode = (word >> 10) & 0x3f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // Pointer authentication (pac*/aut*/xpac*) shares this encoding with
        // opcode2 == 0b00001 and always operates on X registers.
        if opcode2 == 0b00001 {
            return decodePointerAuthDataProcessing(word: word, bytes: bytes, address: address, opcode: opcode, rn: rn, rd: rd)
        }

        let mnemonic: String?
        switch (opcode2, opcode) {
        case (0, 0b000000): mnemonic = "rbit"
        case (0, 0b000001): mnemonic = "rev16"
        case (0, 0b000010): mnemonic = is64Bit ? "rev32" : "rev"
        case (0, 0b000011): mnemonic = is64Bit ? "rev" : nil
        case (0, 0b000100): mnemonic = "clz"
        case (0, 0b000101): mnemonic = "cls"
        default: mnemonic = nil
        }
        guard let mnemonic else {
            return unknownInstruction(address, bytes, word)
        }
        return instruction(address, bytes, mnemonic, "\(register(rd, is64Bit: is64Bit)), \(register(rn, is64Bit: is64Bit))")
    }

    func decodeDataProcessingTwoSource(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let setsFlags = (word & 0x2000_0000) != 0
        let opcode = (word >> 10) & 0x3f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String?
        switch opcode {
        case 0b000000:
            guard is64Bit else { return unknownInstruction(address, bytes, word) }
            return decodeSubtractPointer(word: word, bytes: bytes, address: address, setsFlags: setsFlags)
        case 0b000100:
            guard is64Bit && !setsFlags else { return unknownInstruction(address, bytes, word) }
            return decodeInsertRandomTag(word: word, bytes: bytes, address: address)
        case 0b000101:
            guard is64Bit && !setsFlags else { return unknownInstruction(address, bytes, word) }
            return decodeTagMaskInsert(word: word, bytes: bytes, address: address)
        case 0b000010: mnemonic = "udiv"
        case 0b000011: mnemonic = "sdiv"
        case 0b001000: mnemonic = "lsl"
        case 0b001001: mnemonic = "lsr"
        case 0b001010: mnemonic = "asr"
        case 0b001011: mnemonic = "ror"
        case 0b001100:
            // PACGA Xd, Xn, Xm|SP: sf=1 only (Apple rejects `1ac03000`), and Rm=31 is SP.
            guard is64Bit, !setsFlags else { return unknownInstruction(address, bytes, word) }
            return instruction(
                address, bytes, "pacga",
                "\(register(rd, is64Bit: true)), \(register(rn, is64Bit: true)), \(register(rm, is64Bit: true, useStackPointer: true))"
            )
        default: mnemonic = nil
        }
        guard let mnemonic else {
            return unknownInstruction(address, bytes, word)
        }
        return instruction(address, bytes, mnemonic, threeRegisters(rd, rn, rm, is64Bit: is64Bit))
    }

    func decodeDataProcessingThreeSource(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let op31 = (word >> 21) & 0x7
        let o0 = (word >> 15) & 0x1
        let rm = Int((word >> 16) & 0x1f)
        let ra = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        // op54 (bits[30:29]) must be 00, and every op31 other than 000 (madd/msub) is 64-bit only.
        guard (word & 0x6000_0000) == 0, op31 == 0 || is64Bit else {
            return unknownInstruction(address, bytes, word)
        }

        // The "long" multiplies always write an X register and read W sources.
        func wideningTriple() -> String {
            "\(register(rd, is64Bit: true)), \(register(rn, is64Bit: false)), \(register(rm, is64Bit: false))"
        }
        func wideningQuad() -> String {
            "\(wideningTriple()), \(register(ra, is64Bit: true))"
        }

        switch (op31, o0) {
        case (0b000, 0):
            if ra == 31 { return instruction(address, bytes, "mul", threeRegisters(rd, rn, rm, is64Bit: is64Bit)) }
            return instruction(address, bytes, "madd", "\(threeRegisters(rd, rn, rm, is64Bit: is64Bit)), \(register(ra, is64Bit: is64Bit))")
        case (0b000, 1):
            if ra == 31 { return instruction(address, bytes, "mneg", threeRegisters(rd, rn, rm, is64Bit: is64Bit)) }
            return instruction(address, bytes, "msub", "\(threeRegisters(rd, rn, rm, is64Bit: is64Bit)), \(register(ra, is64Bit: is64Bit))")
        case (0b001, 0):
            return instruction(address, bytes, ra == 31 ? "smull" : "smaddl", ra == 31 ? wideningTriple() : wideningQuad())
        case (0b001, 1):
            return instruction(address, bytes, ra == 31 ? "smnegl" : "smsubl", ra == 31 ? wideningTriple() : wideningQuad())
        case (0b010, 0):
            return instruction(address, bytes, "smulh", threeRegisters(rd, rn, rm, is64Bit: true))
        case (0b101, 0):
            return instruction(address, bytes, ra == 31 ? "umull" : "umaddl", ra == 31 ? wideningTriple() : wideningQuad())
        case (0b101, 1):
            return instruction(address, bytes, ra == 31 ? "umnegl" : "umsubl", ra == 31 ? wideningTriple() : wideningQuad())
        case (0b110, 0):
            return instruction(address, bytes, "umulh", threeRegisters(rd, rn, rm, is64Bit: true))
        default:
            return instruction(address, bytes, "unknown", String(format: "0x%08x", word), comment: "ARM64 decoder unavailable for this opcode")
        }
    }
}

private func arithmeticRegister(_ index: Int, is64Bit: Bool, stackPointer: Bool = false) -> InstructionOperands.Register {
    .init(index: index, width: is64Bit ? 64 : 32,
          role: index == 31 ? (stackPointer ? .stackPointer : .zero) : .ordinary)
}

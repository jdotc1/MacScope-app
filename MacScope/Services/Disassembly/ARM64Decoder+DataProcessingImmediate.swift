import Foundation

extension ARM64Decoder {
    func decodePCRelativeAddress(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isPageRelative = (word & 0x8000_0000) != 0
        let destination = Int(word & 0x1f)
        let immediateLow = Int((word >> 29) & 0x3)
        let immediateHigh = Int((word >> 5) & 0x7ffff)
        let signedImmediate = signExtend((immediateHigh << 2) | immediateLow, bitCount: 21)
        let baseAddress = isPageRelative ? address & ~0xfff : address
        let scaledImmediate = isPageRelative ? signedImmediate * 4096 : signedImmediate
        let mnemonic = isPageRelative ? "adrp" : "adr"
        let typedOperands: [InstructionOperands.Operand] = [
            .register(immediateRegister(destination, is64Bit: true)),
            .pcRelative(.init(baseAddress: address, displacement: Int64(scaledImmediate), pageRelative: isPageRelative)),
        ]

        guard let target = addingSignedOffset(scaledImmediate, to: baseAddress) else {
            return instruction(
                address,
                bytes,
                isPageRelative ? "adrp" : "adr",
                "\(register(destination, is64Bit: true)), <address overflow>",
                comment: "PC-relative address overflows the available address space",
                structuredOperands: .init(coverage: .partial, opcodeClass: mnemonic, operands: typedOperands,
                    presentation: .init(mnemonic: mnemonic),
                    legacyText: .init(mnemonic: mnemonic,
                        operands: "\(register(destination, is64Bit: true)), <address overflow>"))
            )
        }

        return instruction(
            address,
            bytes,
            isPageRelative ? "adrp" : "adr",
            "\(register(destination, is64Bit: true)), \(target.hexAddress)",
            comment: isPageRelative ? "Page-relative address" : "PC-relative address",
            structuredOperands: .init(coverage: .complete, opcodeClass: mnemonic, operands: typedOperands)
        )
    }

    func decodeMoveWide(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        // sf=0 allows only hw = 0 or 1 (shift 0 or 16).
        guard is64Bit || (word & 0x0040_0000) == 0 else { return unknownInstruction(address, bytes, word) }
        let opc = (word >> 29) & 0x3
        let destination = Int(word & 0x1f)
        let immediate = UInt64((word >> 5) & 0xffff)
        let shift = UInt64((word >> 21) & 0x3) * 16
        let value = immediate << shift
        let destinationName = register(destination, is64Bit: is64Bit)
        func wideOperands(_ opcode: String, value: InstructionOperands.Immediate.Value) -> InstructionOperands {
            let immediateOperand = InstructionOperands.Immediate(value, encodedWidth: 16,
                                                                 encodedValue: immediate, encodedShift: Int(shift))
            let operand: InstructionOperands.Operand = opcode == "movk"
                ? .modifiedImmediate(immediateOperand, .init(.lsl, amount: Int(shift), omitWhenZero: true))
                : .immediate(immediateOperand)
            return .init(coverage: .complete, opcodeClass: opcode,
                         operands: [.register(immediateRegister(destination, is64Bit: is64Bit)), operand],
                         presentation: .init(mnemonic: opcode, alias: opcode == "movk" ? nil : "mov"))
        }

        switch opc {
        case 0b10: // MOVZ -> MOV alias with the assembled value.
            return instruction(address, bytes, "mov", "\(destinationName), #\(formatImmediate(value))",
                               structuredOperands: wideOperands("movz", value: .unsigned(value)))
        case 0b00: // MOVN -> MOV alias with the inverted value (rendered signed).
            let inverted = is64Bit ? ~value : (~value & 0xffff_ffff)
            let signed = is64Bit
                ? Int(bitPattern: UInt(inverted))
                : Int(Int32(bitPattern: UInt32(truncatingIfNeeded: inverted)))
            return instruction(address, bytes, "mov", "\(destinationName), #\(formatSignedImmediate(signed))",
                               structuredOperands: wideOperands("movn", value: .signed(Int64(signed))))
        case 0b11: // MOVK keeps its keyword and explicit shift (no value folding).
            let shiftSuffix = shift == 0 ? "" : ", lsl #\(shift)"
            return instruction(address, bytes, "movk", "\(destinationName), #\(formatImmediate(immediate))\(shiftSuffix)",
                               structuredOperands: wideOperands("movk", value: .unsigned(immediate)))
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    func decodeBitfield(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        // N must equal sf, opc = 11 is unallocated, and sf=0 allows immr/imms 0-31 only.
        guard ((word >> 22) & 0x1 == 1) == is64Bit, (word >> 29) & 0x3 != 0b11,
              is64Bit || (word & 0x0020_8000) == 0 else {
            return unknownInstruction(address, bytes, word)
        }
        let opc = (word >> 29) & 0x3
        let width = is64Bit ? 64 : 32
        let immr = Int((word >> 16) & 0x3f)
        let imms = Int((word >> 10) & 0x3f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let rdName = register(rd, is64Bit: is64Bit)
        let rnName = register(rn, is64Bit: is64Bit)
        let rnWord = register(rn, is64Bit: false) // sign/zero-extends read a W source

        switch opc {
        case 0b00: // SBFM
            if immr == 0 && imms == 7 { return instruction(address, bytes, "sxtb", "\(rdName), \(rnWord)") }
            if immr == 0 && imms == 15 { return instruction(address, bytes, "sxth", "\(rdName), \(rnWord)") }
            if immr == 0 && imms == 31 && is64Bit { return instruction(address, bytes, "sxtw", "\(rdName), \(rnWord)") }
            if imms == width - 1 { return instruction(address, bytes, "asr", "\(rdName), \(rnName), #\(immr)") }
            if imms < immr {
                let lsb = (width - immr) % width
                return instruction(address, bytes, "sbfiz", "\(rdName), \(rnName), #\(lsb), #\(imms + 1)")
            }
            return instruction(address, bytes, "sbfx", "\(rdName), \(rnName), #\(immr), #\(imms - immr + 1)")
        case 0b10: // UBFM
            if !is64Bit && immr == 0 && imms == 7 { return instruction(address, bytes, "uxtb", "\(rdName), \(rnWord)") }
            if !is64Bit && immr == 0 && imms == 15 { return instruction(address, bytes, "uxth", "\(rdName), \(rnWord)") }
            if imms == width - 1 { return instruction(address, bytes, "lsr", "\(rdName), \(rnName), #\(immr)") }
            if imms + 1 == immr { return instruction(address, bytes, "lsl", "\(rdName), \(rnName), #\(width - 1 - imms)") }
            if imms < immr {
                let lsb = (width - immr) % width
                return instruction(address, bytes, "ubfiz", "\(rdName), \(rnName), #\(lsb), #\(imms + 1)")
            }
            return instruction(address, bytes, "ubfx", "\(rdName), \(rnName), #\(immr), #\(imms - immr + 1)")
        case 0b01: // BFM
            if imms < immr {
                let lsb = (width - immr) % width
                if rn == 31 { return instruction(address, bytes, "bfc", "\(rdName), #\(lsb), #\(imms + 1)") }
                return instruction(address, bytes, "bfi", "\(rdName), \(rnName), #\(lsb), #\(imms + 1)")
            }
            return instruction(address, bytes, "bfxil", "\(rdName), \(rnName), #\(immr), #\(imms - immr + 1)")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    func decodeAddSubtractImmediate(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isSubtract = (word & 0x4000_0000) != 0 // bit30 (op)
        let setsFlags = (word & 0x2000_0000) != 0  // bit29 (S)
        let shift = (word & 0x0040_0000) != 0 ? 12 : 0
        let immediate = UInt64((word >> 10) & 0x0fff) << UInt64(shift)
        let source = Int((word >> 5) & 0x1f)
        let destination = Int(word & 0x1f)
        let immediateText = "#\(formatImmediate(immediate))"
        // Rn can be the stack pointer in every form; Rd is the stack pointer only
        // for the non-flag-setting add/sub.
        let sourceName = register(source, is64Bit: is64Bit, useStackPointer: true)
        let opcode = (isSubtract ? "sub" : "add") + (setsFlags ? "s" : "")
        let typedOperands: [InstructionOperands.Operand] = [
            .register(immediateRegister(destination, is64Bit: is64Bit, stackPointer: !setsFlags)),
            .register(immediateRegister(source, is64Bit: is64Bit, stackPointer: true)),
            .immediate(.init(.unsigned(immediate), encodedWidth: 12,
                             encodedValue: UInt64((word >> 10) & 0x0fff), encodedShift: shift)),
        ]
        func sidecar(alias: String? = nil, omitted: [Int] = []) -> InstructionOperands {
            .init(coverage: .complete, opcodeClass: opcode, operands: typedOperands,
                  presentation: .init(mnemonic: opcode, alias: alias, omittedOperandIndices: omitted))
        }

        if setsFlags {
            // adds/subs; Rd==31 renders as the cmp/cmn alias.
            if destination == 31 {
                return instruction(address, bytes, isSubtract ? "cmp" : "cmn", "\(sourceName), \(immediateText)",
                                   structuredOperands: sidecar(alias: isSubtract ? "cmp" : "cmn", omitted: [0]))
            }
            return instruction(
                address,
                bytes,
                isSubtract ? "subs" : "adds",
                "\(register(destination, is64Bit: is64Bit)), \(sourceName), \(immediateText)",
                structuredOperands: sidecar()
            )
        }

        // MOV (to/from SP): `add Xd|SP, Xn|SP, #0` with no shift is the preferred alias when Rd or
        // Rn is the stack pointer (for add/sub, reg 31 is SP, never xzr). otool renders this alias.
        if !isSubtract && shift == 0 && immediate == 0 && (source == 31 || destination == 31) {
            return instruction(
                address,
                bytes,
                "mov",
                "\(register(destination, is64Bit: is64Bit, useStackPointer: true)), \(sourceName)",
                structuredOperands: sidecar(alias: "mov", omitted: [2])
            )
        }

        return instruction(
            address,
            bytes,
            isSubtract ? "sub" : "add",
            "\(register(destination, is64Bit: is64Bit, useStackPointer: true)), \(sourceName), \(immediateText)",
            structuredOperands: sidecar()
        )
    }

    func decodeAddSubtractImmediateTags(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isSubtract = (word & 0x4000_0000) != 0
        let setsFlags = (word & 0x2000_0000) != 0
        let bit22 = (word >> 22) & 0x1
        let op3 = (word >> 14) & 0x3
        guard is64Bit && !setsFlags && bit22 == 0 && op3 == 0 else {
            return unknownInstruction(address, bytes, word)
        }

        let uimm6 = UInt64((word >> 16) & 0x3f) << 4
        let uimm4 = UInt64((word >> 10) & 0xf)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let operands = "\(register(rd, is64Bit: true, useStackPointer: true)), \(register(rn, is64Bit: true, useStackPointer: true)), #\(formatImmediate(uimm6)), #\(formatImmediate(uimm4))"
        return instruction(address, bytes, isSubtract ? "subg" : "addg", operands)
    }

    // MARK: - Logical (immediate)

    /// Decodes the logical-immediate group: and/orr/eor/ands with a bitmask
    /// immediate, plus the `tst` alias (ands with Rd==31) and the `mov` alias
    /// (orr with Rn==31 when the value is not move-wide expressible).
    /// AND/ORR/EOR (not ANDS) write to SP when Rd==31; ANDS uses xzr/wzr.
    func decodeLogicalImmediate(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let opc = (word >> 29) & 0x3
        let n = (word >> 22) & 0x1
        let immr = Int((word >> 16) & 0x3f)
        let imms = Int((word >> 10) & 0x3f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let width = is64Bit ? 64 : 32

        // A 32-bit logical-immediate with N==1 is reserved.
        guard is64Bit || n == 0 else { return unknownInstruction(address, bytes, word) }
        guard let value = decodeBitMasks(n: n, imms: imms, immr: immr, width: width) else {
            return unknownInstruction(address, bytes, word)
        }
        let immediateText = "#\(formatImmediate(value))"

        switch opc {
        case 0b00: // AND
            return instruction(address, bytes, "and",
                "\(register(rd, is64Bit: is64Bit, useStackPointer: true)), \(register(rn, is64Bit: is64Bit)), \(immediateText)")
        case 0b01: // ORR (+ mov alias)
            if rn == 31 && !isMoveWideExpressible(value, width: width) {
                return instruction(address, bytes, "mov", "\(register(rd, is64Bit: is64Bit, useStackPointer: true)), \(immediateText)")
            }
            return instruction(address, bytes, "orr",
                "\(register(rd, is64Bit: is64Bit, useStackPointer: true)), \(register(rn, is64Bit: is64Bit)), \(immediateText)")
        case 0b10: // EOR
            return instruction(address, bytes, "eor",
                "\(register(rd, is64Bit: is64Bit, useStackPointer: true)), \(register(rn, is64Bit: is64Bit)), \(immediateText)")
        default: // 0b11 ANDS (+ tst alias)
            if rd == 31 {
                return instruction(address, bytes, "tst", "\(register(rn, is64Bit: is64Bit)), \(immediateText)")
            }
            return instruction(address, bytes, "ands",
                "\(register(rd, is64Bit: is64Bit)), \(register(rn, is64Bit: is64Bit)), \(immediateText)")
        }
    }

    /// Implements the ARM `DecodeBitMasks` pseudocode (immediate path): turns the
    /// (N, imms, immr) encoding into the replicated bitmask value across `width`
    /// bits. Returns nil for reserved encodings (length < 1 or all-ones level).
    private func decodeBitMasks(n: UInt32, imms: Int, immr: Int, width: Int) -> UInt64? {
        // len = HighestSetBit(N : NOT(imms)) over 7 bits.
        let control = (Int(n) << 6) | ((~imms) & 0x3f)
        var length = -1
        for bit in stride(from: 6, through: 0, by: -1) where (control & (1 << bit)) != 0 {
            length = bit
            break
        }
        guard length >= 1 else { return nil }

        let esize = 1 << length
        let levels = esize - 1
        let s = imms & levels
        let r = immr & levels
        // An all-ones imms field within the element is not a valid mask.
        guard s != levels else { return nil }

        let elementMask: UInt64 = esize >= 64 ? ~0 : ((UInt64(1) << UInt64(esize)) - 1)
        let welem: UInt64 = (UInt64(1) << UInt64(s + 1)) - 1
        let rotation = r % esize
        let rotated: UInt64
        if rotation == 0 {
            rotated = welem & elementMask
        } else {
            rotated = ((welem >> UInt64(rotation)) | (welem << UInt64(esize - rotation))) & elementMask
        }

        var result: UInt64 = 0
        var shift = 0
        while shift < width {
            result |= rotated << UInt64(shift)
            shift += esize
        }
        if width < 64 {
            result &= (UInt64(1) << UInt64(width)) - 1
        }
        return result
    }

    /// Matches LLVM/otool's MOV-vs-ORR alias choice: ORR(Rn==31) prints as `mov`
    /// only when the immediate is NOT expressible by any move-wide MOVZ/MOVN.
    private func isMoveWideExpressible(_ value: UInt64, width: Int) -> Bool {
        let mask: UInt64 = width >= 64 ? ~0 : ((UInt64(1) << UInt64(width)) - 1)
        let v = value & mask
        return isMoveZeroExpressible(v, width: width) || isMoveZeroExpressible((~v) & mask, width: width)
    }

    /// True if `value` is a single 16-bit field on a halfword boundary (MOVZ).
    private func isMoveZeroExpressible(_ value: UInt64, width: Int) -> Bool {
        let widthMask: UInt64 = width >= 64 ? ~0 : ((UInt64(1) << UInt64(width)) - 1)
        var shift = 0
        while shift < width {
            let fieldMask = ~(UInt64(0xffff) << UInt64(shift)) & widthMask
            if (value & fieldMask) == 0 { return true }
            shift += 16
        }
        return false
    }

    // MARK: - Extract

    func decodeExtract(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let n = (word >> 22) & 0x1
        // The architecture requires N == sf, op21 = 00, o0 = 0, and imms < 32 when sf=0.
        guard (n == 1) == is64Bit, (word & 0x6020_0000) == 0, is64Bit || (word & 0x0000_8000) == 0 else {
            return unknownInstruction(address, bytes, word)
        }
        let rm = Int((word >> 16) & 0x1f)
        let imms = Int((word >> 10) & 0x3f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let rdName = register(rd, is64Bit: is64Bit)
        let rnName = register(rn, is64Bit: is64Bit)

        // ROR (immediate) is the preferred alias when Rn == Rm.
        if rn == rm {
            return instruction(address, bytes, "ror", "\(rdName), \(rnName), #\(imms)")
        }
        return instruction(address, bytes, "extr", "\(rdName), \(rnName), \(register(rm, is64Bit: is64Bit)), #\(imms)")
    }
}

/// The role of register 31 comes from this encoding's operand position, never its display spelling.
private func immediateRegister(_ index: Int, is64Bit: Bool, stackPointer: Bool = false) -> InstructionOperands.Register {
    .init(index: index, width: is64Bit ? 64 : 32,
          role: index == 31 ? (stackPointer ? .stackPointer : .zero) : .ordinary)
}

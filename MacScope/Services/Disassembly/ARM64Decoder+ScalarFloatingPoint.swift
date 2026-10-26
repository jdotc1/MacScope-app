import Foundation

extension ARM64Decoder {
    // MARK: - Scalar floating-point

    /// Maps the 2-bit ftype field (bits[23:22]) to an fpRegister size index:
    /// 00 -> s (2), 01 -> d (3), 11 -> h (1). 10 is reserved.
    private func fpTypeSizeIndex(_ ftype: UInt32) -> Int? {
        switch ftype {
        case 0b00: return 2
        case 0b01: return 3
        case 0b11: return 1
        default: return nil
        }
    }

    /// Routes a scalar-FP word (top byte 0x1e/0x9e) to the correct sub-group.
    /// bit21=0 is the fixed-point conversion subgroup; for bit21=1 the subgroup is
    /// determined by bits[15:10] (the data-processing/compare/select/immediate
    /// groups all share the top byte and only differ in these bits).
    func decodeScalarFloatingPoint(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        if ((word >> 21) & 0x1) == 0 {
            return decodeFPIntegerConversion(word: word, bytes: bytes, address: address)
        }
        // Every group except the FP<->integer conversions (bits[15:10]=000000) requires M (bit31)=0.
        if (word >> 10) & 0x3f != 0, (word & 0x8000_0000) != 0 {
            return unknownInstruction(address, bytes, word)
        }
        switch (word >> 10) & 0x3 {
        case 0b01: return decodeFPConditionalCompare(word: word, bytes: bytes, address: address)
        case 0b10: return decodeFPDataProcessingOneTwoSource(word: word, bytes: bytes, address: address)
        case 0b11: return decodeFPConditionalSelect(word: word, bytes: bytes, address: address)
        default: break // 0b00
        }
        if ((word >> 12) & 0x1) == 1 { return decodeFloatingPointImmediate(word: word, bytes: bytes, address: address) }
        if ((word >> 13) & 0x1) == 1 { return decodeFPCompare(word: word, bytes: bytes, address: address) }
        if ((word >> 14) & 0x1) == 1 { return decodeFPDataProcessingOneTwoSource(word: word, bytes: bytes, address: address) }
        return decodeFPIntegerConversion(word: word, bytes: bytes, address: address)
    }

    private func decodeFPDataProcessingOneTwoSource(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        guard (word & 0x0020_0000) != 0 else { return unknownInstruction(address, bytes, word) }
        let ftype = (word >> 22) & 0x3
        guard let sizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // 1-source: bits[14:10] == 0b10000 (opcode in bits[20:15]).
        if ((word >> 10) & 0x1f) == 0b10000 {
            let opcode = (word >> 15) & 0x3f
            if opcode == 0b000110 {
                guard ftype == 0b01 else { return unknownInstruction(address, bytes, word) }
                return instruction(address, bytes, "bfcvt", "\(fpRegister(rd, sizeIndex: 1)), \(fpRegister(rn, sizeIndex: 2))")
            }
            let rnName = fpRegister(rn, sizeIndex: sizeIndex)
            // fcvt converts between sizes (dest size = bits[16:15]).
            if opcode >= 0b000100 && opcode <= 0b000111 {
                let destField = (word >> 15) & 0x3
                guard let destSizeIndex = fpTypeSizeIndex(destField), destField != ftype else {
                    return unknownInstruction(address, bytes, word)
                }
                return instruction(address, bytes, "fcvt", "\(fpRegister(rd, sizeIndex: destSizeIndex)), \(rnName)")
            }
            let mnemonic: String?
            switch opcode {
            case 0b000000: mnemonic = "fmov"
            case 0b000001: mnemonic = "fabs"
            case 0b000010: mnemonic = "fneg"
            case 0b000011: mnemonic = "fsqrt"
            case 0b001000: mnemonic = "frintn"
            case 0b001001: mnemonic = "frintp"
            case 0b001010: mnemonic = "frintm"
            case 0b001011: mnemonic = "frintz"
            case 0b001100: mnemonic = "frinta"
            case 0b001110: mnemonic = "frintx"
            case 0b001111: mnemonic = "frinti"
            default: mnemonic = nil
            }
            guard let mnemonic else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: sizeIndex)), \(rnName)")
        }

        // 2-source: bits[11:10] == 0b10 (opcode in bits[15:12]).
        if ((word >> 10) & 0x3) == 0b10 {
            let opcode = (word >> 12) & 0xf
            let rm = Int((word >> 16) & 0x1f)
            let mnemonic: String?
            switch opcode {
            case 0b0000: mnemonic = "fmul"
            case 0b0001: mnemonic = "fdiv"
            case 0b0010: mnemonic = "fadd"
            case 0b0011: mnemonic = "fsub"
            case 0b0100: mnemonic = "fmax"
            case 0b0101: mnemonic = "fmin"
            case 0b0110: mnemonic = "fmaxnm"
            case 0b0111: mnemonic = "fminnm"
            case 0b1000: mnemonic = "fnmul"
            default: mnemonic = nil
            }
            guard let mnemonic else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: sizeIndex)), \(fpRegister(rn, sizeIndex: sizeIndex)), \(fpRegister(rm, sizeIndex: sizeIndex))")
        }

        return unknownInstruction(address, bytes, word)
    }

    func decodeFPDataProcessingThreeSource(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let ftype = (word >> 22) & 0x3
        guard let sizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        let o1 = (word >> 21) & 0x1
        let o0 = (word >> 15) & 0x1
        let rm = Int((word >> 16) & 0x1f)
        let ra = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let mnemonic: String
        switch (o1, o0) {
        case (0, 0): mnemonic = "fmadd"
        case (0, 1): mnemonic = "fmsub"
        case (1, 0): mnemonic = "fnmadd"
        default: mnemonic = "fnmsub"
        }
        return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: sizeIndex)), \(fpRegister(rn, sizeIndex: sizeIndex)), \(fpRegister(rm, sizeIndex: sizeIndex)), \(fpRegister(ra, sizeIndex: sizeIndex))")
    }

    private func decodeFPCompare(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let ftype = (word >> 22) & 0x3
        guard let sizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        // op (bits[15:14]) and opcode2[2:0] are reserved-zero.
        guard (word & 0x0000_c007) == 0 else { return unknownInstruction(address, bytes, word) }
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let opcode2 = word & 0x1f
        let mnemonic = (opcode2 & 0x10) != 0 ? "fcmpe" : "fcmp" // bit4 = E
        let rnName = fpRegister(rn, sizeIndex: sizeIndex)
        let secondOperand = (opcode2 & 0x08) != 0 ? "#0.0" : fpRegister(rm, sizeIndex: sizeIndex) // bit3 = Z
        return instruction(address, bytes, mnemonic, "\(rnName), \(secondOperand)")
    }

    private func decodeFPConditionalCompare(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let ftype = (word >> 22) & 0x3
        guard let sizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        let rm = Int((word >> 16) & 0x1f)
        let condition = Int((word >> 12) & 0xf)
        let rn = Int((word >> 5) & 0x1f)
        let mnemonic = (word & 0x10) != 0 ? "fccmpe" : "fccmp"
        let nzcv = UInt64(word & 0xf)
        return instruction(address, bytes, mnemonic, "\(fpRegister(rn, sizeIndex: sizeIndex)), \(fpRegister(rm, sizeIndex: sizeIndex)), #\(formatImmediate(nzcv)), \(conditionName(condition))")
    }

    private func decodeFPConditionalSelect(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let ftype = (word >> 22) & 0x3
        guard let sizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        let rm = Int((word >> 16) & 0x1f)
        let condition = Int((word >> 12) & 0xf)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        return instruction(address, bytes, "fcsel", "\(fpRegister(rd, sizeIndex: sizeIndex)), \(fpRegister(rn, sizeIndex: sizeIndex)), \(fpRegister(rm, sizeIndex: sizeIndex)), \(conditionName(condition))")
    }

    private func decodeFPIntegerConversion(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let sf = (word >> 31) & 0x1
        let ftype = (word >> 22) & 0x3
        let rmode = (word >> 19) & 0x3
        let opcode = (word >> 16) & 0x7
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let is64Bit = sf == 1
        let isFixedPoint = ((word >> 21) & 0x1) == 0

        // Integer conversions fix bits[15:10] to zero; fixed-point forms use them as scale.
        if !isFixedPoint, (word & 0x0000_fc00) != 0 {
            return unknownInstruction(address, bytes, word)
        }

        // Top-half fmov to/from Vn.d[1] (rmode=01, ftype=10) — uses vector syntax,
        // so handle it before the scalar ftype guard.
        if !isFixedPoint, ftype == 0b10, rmode == 0b01 {
            guard is64Bit else { return unknownInstruction(address, bytes, word) }
            if opcode == 0b110 { return instruction(address, bytes, "fmov", "\(register(rd, is64Bit: true)), v\(rn).d[1]") }
            if opcode == 0b111 { return instruction(address, bytes, "fmov", "v\(rd).d[1], \(register(rn, is64Bit: true))") }
            return unknownInstruction(address, bytes, word)
        }

        guard let fpSizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        let gpr = register(rd, is64Bit: is64Bit)
        let gprSrc = register(rn, is64Bit: is64Bit)
        let fpRd = fpRegister(rd, sizeIndex: fpSizeIndex)
        let fpRn = fpRegister(rn, sizeIndex: fpSizeIndex)

        if isFixedPoint {
            // scale = 64 - fbits; a 32-bit general register allows fbits 1...32 only, so sf=0 with
            // scale<32 (bit15=0) is reserved (`1ed801f7` is not `fcvtzs w23, h15, #0x40`).
            if !is64Bit, (word & 0x0000_8000) == 0 { return unknownInstruction(address, bytes, word) }
            let fbits = 64 - Int((word >> 10) & 0x3f)
            let fbitsText = "#\(formatImmediate(UInt64(fbits)))"
            switch (rmode, opcode) {
            case (0b00, 0b010): return instruction(address, bytes, "scvtf", "\(fpRd), \(gprSrc), \(fbitsText)")
            case (0b00, 0b011): return instruction(address, bytes, "ucvtf", "\(fpRd), \(gprSrc), \(fbitsText)")
            case (0b11, 0b000): return instruction(address, bytes, "fcvtzs", "\(gpr), \(fpRn), \(fbitsText)")
            case (0b11, 0b001): return instruction(address, bytes, "fcvtzu", "\(gpr), \(fpRn), \(fbitsText)")
            default: return unknownInstruction(address, bytes, word)
            }
        }

        // FMOV transfers use matching W/S or X/D widths; half-precision permits W or X.
        if rmode == 0, opcode == 0b110 || opcode == 0b111 {
            guard ftype == 0b11 || (ftype == 0b00 && !is64Bit) || (ftype == 0b01 && is64Bit) else {
                return unknownInstruction(address, bytes, word)
            }
        }

        switch (rmode, opcode) {
        case (0b00, 0b000): return instruction(address, bytes, "fcvtns", "\(gpr), \(fpRn)")
        case (0b00, 0b001): return instruction(address, bytes, "fcvtnu", "\(gpr), \(fpRn)")
        case (0b00, 0b010): return instruction(address, bytes, "scvtf", "\(fpRd), \(gprSrc)")
        case (0b00, 0b011): return instruction(address, bytes, "ucvtf", "\(fpRd), \(gprSrc)")
        case (0b00, 0b100): return instruction(address, bytes, "fcvtas", "\(gpr), \(fpRn)")
        case (0b00, 0b101): return instruction(address, bytes, "fcvtau", "\(gpr), \(fpRn)")
        case (0b00, 0b110): return instruction(address, bytes, "fmov", "\(gpr), \(fpRn)")
        case (0b00, 0b111): return instruction(address, bytes, "fmov", "\(fpRd), \(gprSrc)")
        case (0b01, 0b000): return instruction(address, bytes, "fcvtps", "\(gpr), \(fpRn)")
        case (0b01, 0b001): return instruction(address, bytes, "fcvtpu", "\(gpr), \(fpRn)")
        case (0b10, 0b000): return instruction(address, bytes, "fcvtms", "\(gpr), \(fpRn)")
        case (0b10, 0b001): return instruction(address, bytes, "fcvtmu", "\(gpr), \(fpRn)")
        case (0b11, 0b000): return instruction(address, bytes, "fcvtzs", "\(gpr), \(fpRn)")
        case (0b11, 0b001): return instruction(address, bytes, "fcvtzu", "\(gpr), \(fpRn)")
        default: return unknownInstruction(address, bytes, word)
        }
    }

    private func decodeFloatingPointImmediate(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let ftype = (word >> 22) & 0x3
        guard let sizeIndex = fpTypeSizeIndex(ftype) else { return unknownInstruction(address, bytes, word) }
        // imm5 (bits[9:5]) is reserved-zero.
        guard (word & 0x0000_03e0) == 0 else { return unknownInstruction(address, bytes, word) }
        let imm8 = Int((word >> 13) & 0xff)
        let rd = Int(word & 0x1f)
        return instruction(address, bytes, "fmov", "\(fpRegister(rd, sizeIndex: sizeIndex)), \(floatingPointImmediateText(imm8))")
    }

    /// Expands the 8-bit fmov-immediate (VFPExpandImm) to its exact value and
    /// renders it as otool does (fixed 8 fractional digits). The exponent is a
    /// 3-bit value: bit6=1 gives imm8<5:4>-3 (range -3..0); bit6=0 gives
    /// imm8<5:4>+1 (range 1..4). The value is precision-independent.
    private func floatingPointImmediateText(_ imm8: Int) -> String {
        let sign = (imm8 >> 7) & 0x1
        let bit6 = (imm8 >> 6) & 0x1
        let expLow = (imm8 >> 4) & 0x3
        let frac = imm8 & 0xf
        let exponent = bit6 == 1 ? (expLow - 3) : (expLow + 1)
        var value = (1.0 + Double(frac) / 16.0) * pow(2.0, Double(exponent))
        if sign == 1 { value = -value }
        return "#" + String(format: "%.8f", value)
    }
}

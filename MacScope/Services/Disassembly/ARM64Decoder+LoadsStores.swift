import Foundation

extension ARM64Decoder {
    /// Resolves the mnemonic, destination-register width, and access-size scale
    /// (log2 bytes) for a scalar load/store from its `size`/`opc` fields. Returns
    /// nil for the reserved and PRFM encodings. `unscaled` selects the ldur/stur
    /// spelling used by the unscaled-immediate form.
    private func loadStoreScalarForm(size: UInt32, opc: UInt32, unscaled: Bool) -> (mnemonic: String, destIs64: Bool, scaleLog2: Int)? {
        switch (size, opc) {
        case (0, 0): return (unscaled ? "sturb" : "strb", false, 0)
        case (0, 1): return (unscaled ? "ldurb" : "ldrb", false, 0)
        case (0, 2): return (unscaled ? "ldursb" : "ldrsb", true, 0)
        case (0, 3): return (unscaled ? "ldursb" : "ldrsb", false, 0)
        case (1, 0): return (unscaled ? "sturh" : "strh", false, 1)
        case (1, 1): return (unscaled ? "ldurh" : "ldrh", false, 1)
        case (1, 2): return (unscaled ? "ldursh" : "ldrsh", true, 1)
        case (1, 3): return (unscaled ? "ldursh" : "ldrsh", false, 1)
        case (2, 0): return (unscaled ? "stur" : "str", false, 2)
        case (2, 1): return (unscaled ? "ldur" : "ldr", false, 2)
        case (2, 2): return (unscaled ? "ldursw" : "ldrsw", true, 2)
        case (3, 0): return (unscaled ? "stur" : "str", true, 3)
        case (3, 1): return (unscaled ? "ldur" : "ldr", true, 3)
        default: return nil // PRFM / reserved
        }
    }

    private func lrcpcUnscaledForm(size: UInt32, opc: UInt32) -> (mnemonic: String, destIs64: Bool)? {
        switch (size, opc) {
        case (0, 0): return ("stlurb", false)
        case (0, 1): return ("ldapurb", false)
        case (0, 2): return ("ldapursb", true)
        case (0, 3): return ("ldapursb", false)
        case (1, 0): return ("stlurh", false)
        case (1, 1): return ("ldapurh", false)
        case (1, 2): return ("ldapursh", true)
        case (1, 3): return ("ldapursh", false)
        case (2, 0): return ("stlur", false)
        case (2, 1): return ("ldapur", false)
        case (2, 2): return ("ldapursw", true)
        case (3, 0): return ("stlur", true)
        case (3, 1): return ("ldapur", true)
        default: return nil
        }
    }

    func decodeLRCPCLoadAcquireRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let size = (word >> 30) & 0x3
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let mnemonic: String
        let destIs64: Bool
        switch size {
        case 0:
            mnemonic = "ldaprb"; destIs64 = false
        case 1:
            mnemonic = "ldaprh"; destIs64 = false
        case 2:
            mnemonic = "ldapr"; destIs64 = false
        default:
            mnemonic = "ldapr"; destIs64 = true
        }
        let base = register(rn, is64Bit: true, useStackPointer: true)
        return instruction(address, bytes, mnemonic, "\(register(rt, is64Bit: destIs64)), [\(base)]")
    }

    func decodeLRCPCUnscaled(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let size = (word >> 30) & 0x3
        let opc = (word >> 22) & 0x3
        guard let form = lrcpcUnscaledForm(size: size, opc: opc) else {
            return unknownInstruction(address, bytes, word)
        }
        let imm9 = signExtend(Int((word >> 12) & 0x1ff), bitCount: 9)
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let offsetText = imm9 == 0 ? "" : ", #\(formatSignedImmediate(imm9))"
        return instruction(address, bytes, form.mnemonic, "\(register(rt, is64Bit: form.destIs64)), [\(base)\(offsetText)]")
    }

    func decodeLoadStoreRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let size = (word >> 30) & 0x3
        let opc = (word >> 22) & 0x3
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)

        if size == 3, opc == 2 {
            return decodePrefetchRegister(word: word, bytes: bytes, address: address)
        }

        // bit24 selects the scaled unsigned-immediate form.
        if (word & 0x0100_0000) != 0 {
            guard let form = loadStoreScalarForm(size: size, opc: opc, unscaled: false) else {
                return unknownInstruction(address, bytes, word)
            }
            let offset = Int((word >> 10) & 0xfff) << form.scaleLog2
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, form.mnemonic, "\(register(rt, is64Bit: form.destIs64)), [\(base)\(offsetText)]",
                structuredOperands: scalarMemoryOperands(mnemonic: form.mnemonic, registers: [rt],
                    registerWidth: form.destIs64 ? 64 : 32, base: rn, displacement: offset,
                    accessWidth: 8 << form.scaleLog2, isLoad: opc != 0))
        }

        let op2 = (word >> 10) & 0x3
        if (word & 0x0020_0000) != 0 {
            // Register offset (bit21=1, op2=0b10).
            guard op2 == 0b10 else { return unknownInstruction(address, bytes, word) }
            return decodeLoadStoreRegisterOffset(word: word, bytes: bytes, address: address)
        }

        let imm9 = signExtend(Int((word >> 12) & 0x1ff), bitCount: 9)
        switch op2 {
        case 0b00: // unscaled (ldur/stur)
            guard let form = loadStoreScalarForm(size: size, opc: opc, unscaled: true) else {
                return unknownInstruction(address, bytes, word)
            }
            let offsetText = imm9 == 0 ? "" : ", #\(formatSignedImmediate(imm9))"
            return instruction(address, bytes, form.mnemonic, "\(register(rt, is64Bit: form.destIs64)), [\(base)\(offsetText)]",
                structuredOperands: scalarMemoryOperands(mnemonic: form.mnemonic, registers: [rt],
                    registerWidth: form.destIs64 ? 64 : 32, base: rn, displacement: imm9,
                    accessWidth: 8 << form.scaleLog2, isLoad: opc != 0))
        case 0b01: // post-indexed: [Xn], #imm
            guard let form = loadStoreScalarForm(size: size, opc: opc, unscaled: false) else {
                return unknownInstruction(address, bytes, word)
            }
            return instruction(address, bytes, form.mnemonic, "\(register(rt, is64Bit: form.destIs64)), [\(base)], #\(formatSignedImmediate(imm9))",
                structuredOperands: scalarMemoryOperands(mnemonic: form.mnemonic, registers: [rt],
                    registerWidth: form.destIs64 ? 64 : 32, base: rn, displacement: imm9,
                    indexing: .postIndex, accessWidth: 8 << form.scaleLog2, isLoad: opc != 0))
        case 0b11: // pre-indexed: [Xn, #imm]!
            guard let form = loadStoreScalarForm(size: size, opc: opc, unscaled: false) else {
                return unknownInstruction(address, bytes, word)
            }
            return instruction(address, bytes, form.mnemonic, "\(register(rt, is64Bit: form.destIs64)), [\(base), #\(formatSignedImmediate(imm9))]!",
                structuredOperands: scalarMemoryOperands(mnemonic: form.mnemonic, registers: [rt],
                    registerWidth: form.destIs64 ? 64 : 32, base: rn, displacement: imm9,
                    indexing: .preIndex, accessWidth: 8 << form.scaleLog2, isLoad: opc != 0))
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    private func decodePrefetchRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let operation = prefetchOperation(rt)

        if (word & 0x0100_0000) != 0 {
            let offset = Int((word >> 10) & 0xfff) << 3
            let offsetText = offset == 0 ? "" : ", #\(formatPrefetchMemoryImmediate(offset))"
            return instruction(address, bytes, "prfm", "\(operation), [\(base)\(offsetText)]")
        }

        let op2 = (word >> 10) & 0x3
        if (word & 0x0020_0000) != 0 {
            guard op2 == 0b10 else { return unknownInstruction(address, bytes, word) }
            // Rt[4:3]=11 (Rt >= 24) in the register-offset slot is RPRFM (Range Prefetch Memory,
            // ARMv8.6) — a distinct instruction with a different mnemonic and operand form
            // (`rprfm <prfop2|#imm6>, Xm, [Xn|SP]`), NOT prfm. Decode it here rather than the
            // prfm register-offset form. (Scaled/unscaled prfm keep Rt>=24 as a valid unnamed
            // `prfm #imm`; only this register-offset slot is RPRFM.)
            if rt >= 24 {
                return decodeRangePrefetch(word: word, bytes: bytes, address: address)
            }

            let rm = Int((word >> 16) & 0x1f)
            let option = (word >> 13) & 0x7
            let shifted = ((word >> 12) & 0x1) != 0
            let indexIs64 = (option & 0x1) != 0
            let indexRegister = register(rm, is64Bit: indexIs64)

            let suffix: String
            switch option {
            case 0b011:
                suffix = shifted ? ", lsl #3" : ""
            case 0b010, 0b110, 0b111:
                let extend = option == 0b010 ? "uxtw" : (option == 0b110 ? "sxtw" : "sxtx")
                suffix = shifted ? ", \(extend) #3" : ", \(extend)"
            default:
                return unknownInstruction(address, bytes, word)
            }
            return instruction(address, bytes, "prfm", "\(operation), [\(base), \(indexRegister)\(suffix)]")
        }

        guard op2 == 0b00 else { return unknownInstruction(address, bytes, word) }
        let offset = signExtend(Int((word >> 12) & 0x1ff), bitCount: 9)
        let offsetText = offset == 0 ? "" : ", #\(formatPrefetchMemoryImmediate(offset))"
        return instruction(address, bytes, "prfum", "\(operation), [\(base)\(offsetText)]")
    }

    private func formatPrefetchMemoryImmediate(_ value: Int) -> String {
        if value < 0 {
            return String(format: "-0x%x", -value)
        }
        return String(format: "0x%x", value)
    }

    /// RPRFM (Range Prefetch Memory, FEAT_RPRFM / ARMv8.6). Occupies the `prfm`
    /// register-offset slot (size=11, opc=10, bit24=0, bit21=1, bits[11:10]=10) with
    /// Rt[4:3]=11. The 6-bit prefetch operation `prfop2` is assembled from
    /// prfop2 = option[2] : option[0] : S : Rt[2:0]  (imm6[5:3] = option[2],option[0],S;
    /// imm6[2:0] = Rt[2:0]); option[1] (bit14) MUST be 1, else the word is RESERVED.
    /// Operand form is `rprfm <prfop2|#imm6>, Xm, [Xn|SP]` — the index Xm is a plain
    /// 64-bit register with NO extend/lsl (option/S are consumed by prfop2). otool names
    /// only imm6 0/1/4/5 (pldkeep/pstkeep/pldstrm/pststrm); all other values render `#imm6`
    /// (DECIMAL per house style, matching the existing `prfm #6` spelling).
    private func decodeRangePrefetch(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let option = (word >> 13) & 0x7
        // option[1] must be 1; option[1]=0 (option in {0,1,4,5}) is a reserved/undefined slot.
        guard (option & 0x2) != 0 else { return unknownInstruction(address, bytes, word) }

        let s = (word >> 12) & 0x1
        let rt = word & 0x1f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)

        let prfop2 = (((option >> 2) & 0x1) << 5) | ((option & 0x1) << 4) | (s << 3) | (rt & 0x7)
        let opName: String
        switch prfop2 {
        case 0: opName = "pldkeep"
        case 1: opName = "pstkeep"
        case 4: opName = "pldstrm"
        case 5: opName = "pststrm"
        default: opName = "#\(prfop2)"
        }

        let index = register(rm, is64Bit: true)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        return instruction(address, bytes, "rprfm", "\(opName), \(index), [\(base)]")
    }

    private func decodeLoadStoreRegisterOffset(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let size = (word >> 30) & 0x3
        let opc = (word >> 22) & 0x3
        guard let form = loadStoreScalarForm(size: size, opc: opc, unscaled: false) else {
            return unknownInstruction(address, bytes, word)
        }
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let rm = Int((word >> 16) & 0x1f)
        let option = (word >> 13) & 0x7
        let shifted = ((word >> 12) & 0x1) != 0
        let base = register(rn, is64Bit: true, useStackPointer: true)
        // option[0] distinguishes word (uxtw/sxtw -> W index) from doubleword
        // (lsl/sxtx -> X index).
        let indexIs64 = (option & 0x1) != 0
        let indexRegister = register(rm, is64Bit: indexIs64)

        let suffix: String
        let modifier: InstructionOperands.RegisterModifier
        switch option {
        case 0b011: // LSL: only printed when scaled (S=1)
            suffix = shifted ? ", lsl #\(form.scaleLog2)" : ""
            modifier = .init(.lsl, amount: shifted ? form.scaleLog2 : 0, omitWhenZero: !shifted)
        case 0b010, 0b110, 0b111:
            let extend = option == 0b010 ? "uxtw" : (option == 0b110 ? "sxtw" : "sxtx")
            suffix = shifted ? ", \(extend) #\(form.scaleLog2)" : ", \(extend)"
            let kind: InstructionOperands.RegisterModifier.Kind = option == 0b010 ? .uxtw : (option == 0b110 ? .sxtw : .sxtx)
            modifier = .init(kind, amount: shifted ? form.scaleLog2 : 0, omitZeroAmount: !shifted)
        default:
            return unknownInstruction(address, bytes, word)
        }
        return instruction(address, bytes, form.mnemonic, "\(register(rt, is64Bit: form.destIs64)), [\(base), \(indexRegister)\(suffix)]",
            structuredOperands: scalarMemoryOperands(mnemonic: form.mnemonic, registers: [rt],
                registerWidth: form.destIs64 ? 64 : 32, base: rn,
                index: .init(index: rm, width: indexIs64 ? 64 : 32, role: rm == 31 ? .zero : .ordinary),
                modifier: modifier, accessWidth: 8 << form.scaleLog2, isLoad: opc != 0))
    }

    func decodeLoadStorePair(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let opc = (word >> 30) & 0x3
        let isLoad = (word & 0x0040_0000) != 0
        let indexType = (word >> 23) & 0x3
        let rt2 = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        // opc=01 has no non-temporal (bits[24:23]=00) form: there is no LDNPSW.
        guard !(opc == 0b01 && indexType == 0) else { return unknownInstruction(address, bytes, word) }

        let mnemonic: String
        let is64Bit: Bool
        let scaleLog2: Int
        switch opc {
        case 0b00:
            mnemonic = isLoad ? "ldp" : "stp"; is64Bit = false; scaleLog2 = 2
        case 0b01:
            mnemonic = "ldpsw"; is64Bit = true; scaleLog2 = 2
        case 0b10:
            mnemonic = isLoad ? "ldp" : "stp"; is64Bit = true; scaleLog2 = 3
        default:
            return unknownInstruction(address, bytes, word)
        }
        let offset = signExtend(Int((word >> 15) & 0x7f), bitCount: 7) << scaleLog2
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let pair = "\(register(rt, is64Bit: is64Bit)), \(register(rt2, is64Bit: is64Bit))"

        switch indexType {
        case 0b01: // post-indexed
            return instruction(address, bytes, mnemonic, "\(pair), [\(base)], #\(formatSignedImmediate(offset))",
                structuredOperands: scalarMemoryOperands(mnemonic: mnemonic, registers: [rt, rt2],
                    registerWidth: is64Bit ? 64 : 32, base: rn, displacement: offset,
                    indexing: .postIndex, accessWidth: 8 << scaleLog2, isLoad: isLoad))
        case 0b11: // pre-indexed
            return instruction(address, bytes, mnemonic, "\(pair), [\(base), #\(formatSignedImmediate(offset))]!",
                structuredOperands: scalarMemoryOperands(mnemonic: mnemonic, registers: [rt, rt2],
                    registerWidth: is64Bit ? 64 : 32, base: rn, displacement: offset,
                    indexing: .preIndex, accessWidth: 8 << scaleLog2, isLoad: isLoad))
        case 0b10: // signed offset
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, mnemonic, "\(pair), [\(base)\(offsetText)]",
                structuredOperands: scalarMemoryOperands(mnemonic: mnemonic, registers: [rt, rt2],
                    registerWidth: is64Bit ? 64 : 32, base: rn, displacement: offset,
                    indexing: .offset, accessWidth: 8 << scaleLog2, isLoad: isLoad))
        default: // 0b00: non-temporal (stnp/ldnp)
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, isLoad ? "ldnp" : "stnp", "\(pair), [\(base)\(offsetText)]",
                structuredOperands: scalarMemoryOperands(mnemonic: isLoad ? "ldnp" : "stnp", registers: [rt, rt2],
                    registerWidth: is64Bit ? 64 : 32, base: rn, displacement: offset,
                    indexing: .offset, accessWidth: 8 << scaleLog2, isLoad: isLoad))
        }
    }

    /// Typed scalar memory facts use bit widths; displacement is always in bytes.
    /// Pair elements remain separate operands, and LDPSW retains 32-bit access / 64-bit register widths.
    private func scalarMemoryOperands(
        mnemonic: String, registers: [Int], registerWidth: Int, base: Int,
        displacement: Int = 0, indexing: InstructionOperands.Memory.Indexing = .offset,
        index: InstructionOperands.Register? = nil, modifier: InstructionOperands.RegisterModifier? = nil,
        accessWidth: Int, isLoad: Bool
    ) -> InstructionOperands {
        let dataOperands: [InstructionOperands.Operand] = registers.map {
            .register(.init(index: $0, width: registerWidth, role: $0 == 31 ? .zero : .ordinary))
        }
        let memory = InstructionOperands.Memory(
            base: .init(index: base, width: 64, role: base == 31 ? .stackPointer : .ordinary),
            index: index, modifier: modifier, displacement: Int64(displacement),
            indexing: indexing, writeback: indexing != .offset
        )
        return .init(coverage: .complete, opcodeClass: mnemonic,
                     operands: dataOperands + [.memory(memory)],
                     semantics: .init(memoryAccessWidth: accessWidth, memoryAccess: isLoad ? .read : .write))
    }

    func decodeLoadStoreMemoryTag(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let opc = (word >> 22) & 0x3
        let op2 = (word >> 10) & 0x3
        let offset = signExtend(Int((word >> 12) & 0x1ff), bitCount: 9) << 4
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let rtName = register(rt, is64Bit: true)

        func indexed(_ mnemonic: String) -> DecodedInstruction {
            // STG/STZG/ST2G/STZ2G take the tag from Xt|SP: Rt=31 is SP (`d9201bff` is `stg sp, [sp, #0x10]`).
            let rtName = register(rt, is64Bit: true, useStackPointer: true)
            switch op2 {
            case 0b01:
                return instruction(address, bytes, mnemonic, "\(rtName), [\(base)], #\(formatSignedImmediate(offset))")
            case 0b10:
                let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
                return instruction(address, bytes, mnemonic, "\(rtName), [\(base)\(offsetText)]")
            case 0b11:
                return instruction(address, bytes, mnemonic, "\(rtName), [\(base), #\(formatSignedImmediate(offset))]!")
            default:
                return unknownInstruction(address, bytes, word)
            }
        }

        if op2 == 0b00 {
            switch opc {
            case 0b00:
                guard offset == 0 else { return nil }
                return instruction(address, bytes, "stzgm", "\(rtName), [\(base)]")
            case 0b01:
                let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
                return instruction(address, bytes, "ldg", "\(rtName), [\(base)\(offsetText)]")
            case 0b10:
                guard offset == 0 else { return nil }
                return instruction(address, bytes, "stgm", "\(rtName), [\(base)]")
            default:
                guard offset == 0 else { return nil }
                return instruction(address, bytes, "ldgm", "\(rtName), [\(base)]")
            }
        }

        switch opc {
        case 0b00: return indexed("stg")
        case 0b01: return indexed("stzg")
        case 0b10: return indexed("st2g")
        default: return indexed("stz2g")
        }
    }

    func decodeStoreTagPair(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let indexType = (word >> 23) & 0x3
        let offset = signExtend(Int((word >> 15) & 0x7f), bitCount: 7) << 4
        let rt2 = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let pair = "\(register(rt, is64Bit: true)), \(register(rt2, is64Bit: true))"

        switch indexType {
        case 0b01:
            return instruction(address, bytes, "stgp", "\(pair), [\(base)], #\(formatSignedImmediate(offset))")
        case 0b10:
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, "stgp", "\(pair), [\(base)\(offsetText)]")
        case 0b11:
            return instruction(address, bytes, "stgp", "\(pair), [\(base), #\(formatSignedImmediate(offset))]!")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    /// Prefetch operation name for `prfm` (Rt = type[2] : target[2] : policy[1]); `#imm` if reserved.
    private func prefetchOperation(_ rt: Int) -> String {
        let type = (rt >> 3) & 0x3
        let target = (rt >> 1) & 0x3
        let policy = rt & 0x1
        guard type < 3, target < 3 else { return "#\(rt)" }
        return ["pld", "pli", "pst"][type] + "l\(target + 1)" + (policy == 0 ? "keep" : "strm")
    }

    /// Load register (literal): `ldr Wt/Xt/St/Dt/Qt`, `ldrsw Xt`, or `prfm`, PC-relative to a
    /// 19-bit scaled literal. Encoding `opc(2) 011 V(1) 00 imm19 Rt`; the target renders as the
    /// resolved absolute address like `adr`. nil for the reserved opc=11,V=1 slot.
    func decodeLoadLiteral(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let opc = (word >> 30) & 0x3
        let v = (word >> 26) & 0x1
        let imm19 = Int((word >> 5) & 0x7ffff)
        let rt = Int(word & 0x1f)
        guard let target = addingSignedOffset(signExtend(imm19 << 2, bitCount: 21), to: address) else { return nil }
        let targetText = target.hexAddress
        if v == 1 {
            let sizeIndex: Int
            switch opc { case 0: sizeIndex = 2; case 1: sizeIndex = 3; case 2: sizeIndex = 4; default: return nil }
            return instruction(address, bytes, "ldr", "\(fpRegister(rt, sizeIndex: sizeIndex)), \(targetText)", comment: "PC-relative literal")
        }
        switch opc {
        case 0: return instruction(address, bytes, "ldr", "\(register(rt, is64Bit: false)), \(targetText)", comment: "PC-relative literal")
        case 1: return instruction(address, bytes, "ldr", "\(register(rt, is64Bit: true)), \(targetText)", comment: "PC-relative literal")
        case 2: return instruction(address, bytes, "ldrsw", "\(register(rt, is64Bit: true)), \(targetText)", comment: "PC-relative literal")
        default: return instruction(address, bytes, "prfm", "\(prefetchOperation(rt)), \(targetText)", comment: "PC-relative literal")
        }
    }
}

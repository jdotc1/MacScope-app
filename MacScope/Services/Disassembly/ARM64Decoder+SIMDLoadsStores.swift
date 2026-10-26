import Foundation

extension ARM64Decoder {
    // MARK: - FP/SIMD load/store

    /// Names a scalar FP/SIMD register by size index: 0=b, 1=h, 2=s, 3=d, 4=q.
    func fpRegister(_ index: Int, sizeIndex: Int) -> String {
        let prefix: String
        switch sizeIndex {
        case 0: prefix = "b"
        case 1: prefix = "h"
        case 2: prefix = "s"
        case 3: prefix = "d"
        default: prefix = "q"
        }
        return "\(prefix)\(index)"
    }

    func decodeFPLoadStoreRegister(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let size = (word >> 30) & 0x3
        let opc = (word >> 22) & 0x3
        let isLoad = (opc & 0x1) != 0
        // Effective size index = opc[1]:size -> 0=b,1=h,2=s,3=d,4=q. Values >4 are
        // reserved (e.g. opc[1]=1 with size!=0).
        let sizeIndex = Int(((opc >> 1) << 2) | size)
        guard sizeIndex <= 4 else { return unknownInstruction(address, bytes, word) }
        let scaleLog2 = sizeIndex
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let rtName = fpRegister(rt, sizeIndex: sizeIndex)

        if (word & 0x0100_0000) != 0 { // scaled unsigned immediate
            let offset = Int((word >> 10) & 0xfff) << scaleLog2
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, isLoad ? "ldr" : "str", "\(rtName), [\(base)\(offsetText)]")
        }

        let op2 = (word >> 10) & 0x3
        if (word & 0x0020_0000) != 0 { // register offset (bit21=1, op2=0b10)
            guard op2 == 0b10 else { return unknownInstruction(address, bytes, word) }
            let rm = Int((word >> 16) & 0x1f)
            let option = (word >> 13) & 0x7
            let shifted = ((word >> 12) & 0x1) != 0
            let indexIs64 = (option & 0x1) != 0
            let indexRegister = register(rm, is64Bit: indexIs64)
            let suffix: String
            switch option {
            case 0b011:
                suffix = shifted ? ", lsl #\(scaleLog2)" : ""
            case 0b010, 0b110, 0b111:
                let extend = option == 0b010 ? "uxtw" : (option == 0b110 ? "sxtw" : "sxtx")
                suffix = shifted ? ", \(extend) #\(scaleLog2)" : ", \(extend)"
            default:
                return unknownInstruction(address, bytes, word)
            }
            return instruction(address, bytes, isLoad ? "ldr" : "str", "\(rtName), [\(base), \(indexRegister)\(suffix)]")
        }

        let imm9 = signExtend(Int((word >> 12) & 0x1ff), bitCount: 9)
        switch op2 {
        case 0b00: // unscaled (ldur/stur)
            let offsetText = imm9 == 0 ? "" : ", #\(formatSignedImmediate(imm9))"
            return instruction(address, bytes, isLoad ? "ldur" : "stur", "\(rtName), [\(base)\(offsetText)]")
        case 0b01: // post-indexed
            return instruction(address, bytes, isLoad ? "ldr" : "str", "\(rtName), [\(base)], #\(formatSignedImmediate(imm9))")
        case 0b11: // pre-indexed
            return instruction(address, bytes, isLoad ? "ldr" : "str", "\(rtName), [\(base), #\(formatSignedImmediate(imm9))]!")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    func decodeFPLoadStorePair(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let opc = (word >> 30) & 0x3
        let isLoad = (word & 0x0040_0000) != 0
        let indexType = (word >> 23) & 0x3
        let rt2 = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        // opc selects the register size: 00=s (scale 4), 01=d (scale 8), 10=q (16).
        let sizeIndex: Int
        let scaleLog2: Int
        switch opc {
        case 0b00: sizeIndex = 2; scaleLog2 = 2
        case 0b01: sizeIndex = 3; scaleLog2 = 3
        case 0b10: sizeIndex = 4; scaleLog2 = 4
        default: return unknownInstruction(address, bytes, word)
        }
        let offset = signExtend(Int((word >> 15) & 0x7f), bitCount: 7) << scaleLog2
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let pair = "\(fpRegister(rt, sizeIndex: sizeIndex)), \(fpRegister(rt2, sizeIndex: sizeIndex))"

        switch indexType {
        case 0b01:
            return instruction(address, bytes, isLoad ? "ldp" : "stp", "\(pair), [\(base)], #\(formatSignedImmediate(offset))")
        case 0b11:
            return instruction(address, bytes, isLoad ? "ldp" : "stp", "\(pair), [\(base), #\(formatSignedImmediate(offset))]!")
        case 0b10:
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, isLoad ? "ldp" : "stp", "\(pair), [\(base)\(offsetText)]")
        default:
            let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
            return instruction(address, bytes, isLoad ? "ldnp" : "stnp", "\(pair), [\(base)\(offsetText)]")
        }
    }

    /// Decode the Advanced SIMD structure load/store MULTIPLE-structure forms (ld1–4/st1–4 across
    /// 1–4 registers), with the no-offset and post-index (immediate and register) addressing.
    /// Single-structure (lane) forms (bit24==1) are decoded by `decodeSIMDLoadStoreSingleStructure`;
    /// reserved opcodes/arrangements return nil so the caller leaves them `unknown`.
    func decodeSIMDLoadStoreStructure(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        // Bit24=1 is the single-structure (lane) form — handled by a separate dispatch.
        if ((word >> 24) & 0x1) != 0 { return nil }
        // Reserved fields: bit31 and bit21 are 0, and the no-offset form (bit23=0) has Rm = 00000.
        guard (word & 0x8020_0000) == 0, (word & 0x0080_0000) != 0 || (word & 0x001f_0000) == 0 else { return nil }

        let postIndex = ((word >> 23) & 0x1) != 0
        let isLoad = ((word >> 22) & 0x1) != 0
        let opcode = (word >> 12) & 0xf

        // opcode[15:12] selects both the structure mnemonic and the register count.
        let mnemonic: String
        let registerCount: Int
        switch opcode {
        case 0x0: mnemonic = isLoad ? "ld4" : "st4"; registerCount = 4
        case 0x2: mnemonic = isLoad ? "ld1" : "st1"; registerCount = 4
        case 0x4: mnemonic = isLoad ? "ld3" : "st3"; registerCount = 3
        case 0x6: mnemonic = isLoad ? "ld1" : "st1"; registerCount = 3
        case 0x7: mnemonic = isLoad ? "ld1" : "st1"; registerCount = 1
        case 0x8: mnemonic = isLoad ? "ld2" : "st2"; registerCount = 2
        case 0xa: mnemonic = isLoad ? "ld1" : "st1"; registerCount = 2
        default: return nil
        }

        let isQ = ((word >> 30) & 0x1) != 0
        let size = (word >> 10) & 0x3

        // size=3,Q=0 is the `.1d` arrangement: VALID only for LD1/ST1 (a single 64-bit element per
        // structure). LD2/3/4 reject it (their 64-bit form is `.2d`) → leave those `unknown`.
        let arrangement: String
        if size == 3 && !isQ {
            guard mnemonic == "ld1" || mnemonic == "st1" else { return nil }
            arrangement = "1d"
        } else {
            guard let a = simdStructureArrangement(size: size, isQ: isQ) else { return nil }
            arrangement = a
        }

        let rt = Int(word & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rm = Int((word >> 16) & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)

        let registers = (0..<registerCount).map { offset in "v\((rt + offset) & 0x1f).\(arrangement)" }
        let list = "{" + registers.joined(separator: ", ") + "}"

        let addressOperand: String
        if postIndex {
            if rm == 31 {
                let stride = (isQ ? 16 : 8) * registerCount
                addressOperand = "[\(base)], #\(stride)"
            } else {
                addressOperand = "[\(base)], \(register(rm, is64Bit: true))"
            }
        } else {
            addressOperand = "[\(base)]"
        }
        let vectorWidth = isQ ? 128 : 64
        let elementWidth = 8 << Int(size)
        let typedRegisters: [InstructionOperands.Register] = (0..<registerCount).map {
            .init(bank: .simd, index: (rt + $0) & 0x1f, width: vectorWidth,
                  arrangement: .init(elementWidth: elementWidth, laneCount: vectorWidth / elementWidth))
        }
        return instruction(address, bytes, mnemonic, "\(list), \(addressOperand)",
            structuredOperands: simdStructureOperands(mnemonic: mnemonic, registers: typedRegisters,
                base: rn, postIndex: postIndex, offsetRegister: rm,
                immediateStride: (vectorWidth / 8) * registerCount,
                elementWidth: elementWidth, isLoad: isLoad))
    }

    /// Decode the Advanced SIMD SINGLE-structure (one-lane) load/store and the replicate (ld1r–ld4r)
    /// forms. The element size + lane index come from `opcode[2:1]` (scale), `Q`, `S`, and the low
    /// `size` bits; the register count is `(opcode[0]<<1 | R) + 1`. Reserved encodings return nil.
    /// Dispatched when bits[29:24]==0x0d (bit24==1).
    func decodeSIMDLoadStoreSingleStructure(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        // Reserved fields: bit31 is 0, and the no-offset form (bit23=0) has Rm = 00000.
        guard (word & 0x8000_0000) == 0, (word & 0x0080_0000) != 0 || (word & 0x001f_0000) == 0 else { return nil }
        let postIndex = ((word >> 23) & 0x1) != 0
        let isLoad = ((word >> 22) & 0x1) != 0
        let rFlag = (word >> 21) & 0x1
        let opcode3 = (word >> 13) & 0x7

        let scale = (opcode3 >> 1) & 0x3
        let registerCount = Int(((opcode3 & 0x1) << 1) | rFlag) + 1

        let isQ = ((word >> 30) & 0x1) != 0
        let s = (word >> 12) & 0x1
        let sizebits = (word >> 10) & 0x3

        let rt = Int(word & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rm = Int((word >> 16) & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)

        // Replicate (ldNr): scale==0b11, load only, S==0. Element size is `sizebits`; no lane index.
        let isReplicate = scale == 0b11
        if isReplicate && (!isLoad || s != 0) { return nil }

        var elemScale: UInt32 = 0
        var laneIndex = 0
        if !isReplicate {
            switch scale {
            case 0b00:
                elemScale = 0
                laneIndex = Int(((isQ ? 1 : 0) << 3) | (Int(s) << 2) | Int(sizebits))
            case 0b01:
                guard (sizebits & 0x1) == 0 else { return nil }
                elemScale = 1
                laneIndex = Int(((isQ ? 1 : 0) << 2) | (Int(s) << 1) | Int((sizebits >> 1) & 0x1))
            case 0b10:
                guard (sizebits & 0x2) == 0 else { return nil }
                if (sizebits & 0x1) == 0 {
                    elemScale = 2
                    laneIndex = Int(((isQ ? 1 : 0) << 1) | Int(s))
                } else {
                    guard s == 0 else { return nil }
                    elemScale = 3
                    laneIndex = isQ ? 1 : 0
                }
            default:
                return nil
            }
        }

        let mnemonic = isReplicate ? "ld\(registerCount)r" : (isLoad ? "ld" : "st") + String(registerCount)
        let destRegs = (0..<registerCount).map { (rt + $0) & 0x1f }

        let operandList: String
        if isReplicate {
            let arrangement = vectorArrangement(size: sizebits, isQ: isQ)
            operandList = "{" + destRegs.map { "v\($0).\(arrangement)" }.joined(separator: ", ") + "}"
        } else {
            let elem = ["b", "h", "s", "d"][Int(elemScale)]
            operandList = "{" + destRegs.map { "v\($0).\(elem)" }.joined(separator: ", ") + "}[\(laneIndex)]"
        }

        let addressOperand: String
        if postIndex {
            // Post-index. Rm==31 is the immediate form (stride = elementBytes × registerCount, where
            // the element is `sizebits` for replicate and `elemScale` for the lane forms); any other
            // Rm is the register-offset form `[xN], xM`. Both are valid for single-structure/replicate.
            if rm == 31 {
                let elemBytes = UInt32(1) << (isReplicate ? sizebits : elemScale)
                let stride = elemBytes * UInt32(registerCount)
                addressOperand = "[\(base)], #\(stride)"
            } else {
                addressOperand = "[\(base)], \(register(rm, is64Bit: true))"
            }
        } else {
            addressOperand = "[\(base)]"
        }
        let elementWidth = 8 << Int(isReplicate ? sizebits : elemScale)
        let vectorWidth = isReplicate ? (isQ ? 128 : 64) : 128
        let typedRegisters: [InstructionOperands.Register] = destRegs.map {
            .init(bank: .simd, index: $0, width: vectorWidth,
                  arrangement: .init(elementWidth: elementWidth,
                                     laneCount: isReplicate ? vectorWidth / elementWidth : nil),
                  lane: isReplicate ? nil : laneIndex)
        }
        return instruction(address, bytes, mnemonic, "\(operandList), \(addressOperand)",
            structuredOperands: simdStructureOperands(mnemonic: mnemonic, registers: typedRegisters,
                base: rn, postIndex: postIndex, offsetRegister: rm,
                immediateStride: (elementWidth / 8) * registerCount,
                elementWidth: elementWidth, isLoad: isLoad))
    }

    /// Register lists retain individual register identities, including wraparound and lane selectors.
    /// Rm=31 selects the encoded immediate stride, never XZR; all displacements are byte counts.
    private func simdStructureOperands(
        mnemonic: String, registers: [InstructionOperands.Register], base: Int,
        postIndex: Bool, offsetRegister: Int, immediateStride: Int,
        elementWidth: Int, isLoad: Bool
    ) -> InstructionOperands {
        let usesRegisterOffset = postIndex && offsetRegister != 31
        let memory = InstructionOperands.Memory(
            base: .init(index: base, width: 64, role: base == 31 ? .stackPointer : .ordinary),
            index: usesRegisterOffset ? .init(index: offsetRegister, width: 64) : nil,
            displacement: postIndex && !usesRegisterOffset ? Int64(immediateStride) : 0,
            indexing: postIndex ? .postIndex : .offset, writeback: postIndex,
            displacementFormat: .decimal)
        return .init(coverage: .complete, opcodeClass: mnemonic,
                     operands: [.registerList(registers), .memory(memory)],
                     semantics: .init(memoryAccessWidth: elementWidth, memoryAccess: isLoad ? .read : .write))
    }

    /// Maps the SIMD structure load/store `size:Q` fields to the vector arrangement. size=3,Q=0 has
    /// no valid arrangement (returns nil → the caller leaves it `unknown`).
    private func simdStructureArrangement(size: UInt32, isQ: Bool) -> String? {
        switch (size, isQ) {
        case (0, false): return "8b"
        case (0, true):  return "16b"
        case (1, false): return "4h"
        case (1, true):  return "8h"
        case (2, false): return "2s"
        case (2, true):  return "4s"
        case (3, true):  return "2d"
        default: return nil
        }
    }
}

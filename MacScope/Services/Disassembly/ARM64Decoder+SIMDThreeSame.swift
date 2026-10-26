import Foundation

extension ARM64Decoder {
    func decodeSIMDThreeSameFP16(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let a = (word >> 23) & 0x1
        let opcode = (word >> 11) & 0xf
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String?
        switch (u, a, opcode) {
        case (0, 0, 0x0): mnemonic = "fmaxnm"
        case (0, 0, 0x1): mnemonic = "fmla"
        case (0, 0, 0x2): mnemonic = "fadd"
        case (0, 0, 0x3): mnemonic = "fmulx"
        case (0, 0, 0x4): mnemonic = "fcmeq"
        case (0, 0, 0x6): mnemonic = "fmax"
        case (0, 0, 0x7): mnemonic = "frecps"
        case (0, 1, 0x0): mnemonic = "fminnm"
        case (0, 1, 0x1): mnemonic = "fmls"
        case (0, 1, 0x2): mnemonic = "fsub"
        case (0, 1, 0x6): mnemonic = "fmin"
        case (0, 1, 0x7): mnemonic = "frsqrts"
        case (1, 0, 0x0): mnemonic = "fmaxnmp"
        case (1, 0, 0x2): mnemonic = "faddp"
        case (1, 0, 0x3): mnemonic = "fmul"
        case (1, 0, 0x4): mnemonic = "fcmge"
        case (1, 0, 0x5): mnemonic = "facge"
        case (1, 0, 0x6): mnemonic = "fmaxp"
        case (1, 0, 0x7): mnemonic = "fdiv"
        case (1, 1, 0x0): mnemonic = "fminnmp"
        case (1, 1, 0x2): mnemonic = "fabd"
        case (1, 1, 0x4): mnemonic = "fcmgt"
        case (1, 1, 0x5): mnemonic = "facgt"
        case (1, 1, 0x6): mnemonic = "fminp"
        default: mnemonic = nil
        }
        guard let mnemonic else { return unknownInstruction(address, bytes, word) }

        let arrangement = isQ ? "8h" : "4h"
        return instruction(address, bytes, mnemonic, threeVector(rd, rn, rm, arrangement))
    }

    /// Advanced SIMD three-same (dot product): sdot/udot Vd.<4s|2s>, Vn.<16b|8b>, Vm.<16b|8b>.
    func decodeSIMDDotProduct(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let ta = isQ ? "4s" : "2s"
        let tb = isQ ? "16b" : "8b"
        let name = u == 0 ? "sdot" : "udot"
        return instruction(address, bytes, name, "v\(rd).\(ta), v\(rn).\(tb), v\(rm).\(tb)")
    }

    /// Advanced SIMD three-same-extra: RDMA and i8mm vector forms.
    func decodeSIMDThreeSameExtra(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 11) & 0x1f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        switch (u, opcode) {
        case (_, 0b10010):
            return nil
        case (0, 0b10011):
            guard size == 0b10 else { return unknownInstruction(address, bytes, word) }
            let dst = isQ ? "4s" : "2s"
            let src = isQ ? "16b" : "8b"
            return instruction(address, bytes, "usdot", "v\(rd).\(dst), v\(rn).\(src), v\(rm).\(src)")
        case (0, 0b10100):
            guard isQ && size == 0b10 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "smmla", "v\(rd).4s, v\(rn).16b, v\(rm).16b")
        case (0, 0b10101):
            guard isQ && size == 0b10 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "usmmla", "v\(rd).4s, v\(rn).16b, v\(rm).16b")
        case (1, 0b10000):
            guard size == 0b01 || size == 0b10 else { return unknownInstruction(address, bytes, word) }
            let arrangement = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, "sqrdmlah", threeVector(rd, rn, rm, arrangement))
        case (1, 0b10001):
            guard size == 0b01 || size == 0b10 else { return unknownInstruction(address, bytes, word) }
            let arrangement = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, "sqrdmlsh", threeVector(rd, rn, rm, arrangement))
        case (1, 0b10100):
            guard isQ && size == 0b10 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "ummla", "v\(rd).4s, v\(rn).16b, v\(rm).16b")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    /// Advanced SIMD three-same-extra (BFloat16): bfdot/bfmmla/bfmlalb/bfmlalt.
    func decodeSIMDBF16ThreeSameExtra(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isQ = (word & 0x4000_0000) != 0
        let size = (word >> 22) & 0x3
        let opcode = (word >> 11) & 0xf
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        if size == 0b01 && opcode == 0b1111 {
            let dst = isQ ? "4s" : "2s"
            let src = isQ ? "8h" : "4h"
            return instruction(address, bytes, "bfdot", "v\(rd).\(dst), v\(rn).\(src), v\(rm).\(src)")
        }

        if size == 0b01 && opcode == 0b1101 && isQ {
            return instruction(address, bytes, "bfmmla", "v\(rd).4s, v\(rn).8h, v\(rm).8h")
        }

        if size == 0b11 && opcode == 0b1111 {
            let mnemonic = isQ ? "bfmlalt" : "bfmlalb"
            return instruction(address, bytes, mnemonic, "v\(rd).4s, v\(rn).8h, v\(rm).8h")
        }

        return unknownInstruction(address, bytes, word)
    }

    func decodeSIMDThreeSame(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 11) & 0x1f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // Floating-point element-wise ops (opcode in the FP block). The high size
        // bit (bit23) acts as an add/sub-style selector; bit22 picks single/double.
        if opcode >= 0b11000 {
            let a = (word >> 23) & 0x1
            let sz = (word >> 22) & 0x1
            guard sz == 0 || isQ else { return unknownInstruction(address, bytes, word) }
            let fpArrangement = sz == 0 ? (isQ ? "4s" : "2s") : "2d"
            let mnemonic: String?
            switch (u, a, opcode) {
            case (1, 0, 0b11000): mnemonic = "fmaxnmp"
            case (1, 1, 0b11000): mnemonic = "fminnmp"
            case (0, 0, 0b11001): mnemonic = "fmla"
            case (0, 1, 0b11001): mnemonic = "fmls"
            case (1, 1, 0b11010): mnemonic = "fabd"
            case (0, 0, 0b11111): mnemonic = "frecps"
            case (0, 1, 0b11111): mnemonic = "frsqrts"
            case (0, 0, 0b11010): mnemonic = "fadd"
            case (0, 1, 0b11010): mnemonic = "fsub"
            case (1, 0, 0b11010): mnemonic = "faddp"
            case (0, 0, 0b11011): mnemonic = "fmulx"
            case (1, 0, 0b11011): mnemonic = "fmul"
            case (1, 0, 0b11111): mnemonic = "fdiv"
            case (0, 0, 0b11110): mnemonic = "fmax"
            case (0, 1, 0b11110): mnemonic = "fmin"
            case (1, 0, 0b11110): mnemonic = "fmaxp"
            case (1, 1, 0b11110): mnemonic = "fminp"
            case (0, 0, 0b11000): mnemonic = "fmaxnm"
            case (0, 1, 0b11000): mnemonic = "fminnm"
            case (0, 0, 0b11100): mnemonic = "fcmeq"
            case (1, 0, 0b11100): mnemonic = "fcmge"
            case (1, 1, 0b11100): mnemonic = "fcmgt"
            case (1, 0, 0b11101): mnemonic = "facge"
            case (1, 1, 0b11101): mnemonic = "facgt"
            default: mnemonic = nil
            }
            guard let mnemonic else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, mnemonic, threeVector(rd, rn, rm, fpArrangement))
        }

        // Bitwise logical ops select by size; their arrangement is always 8b/16b.
        if opcode == 0b00011 {
            let logical: String
            switch (u, size) {
            case (0, 0): logical = "and"
            case (0, 1): logical = "bic"
            case (0, 2): logical = "orr"
            case (0, 3): logical = "orn"
            case (1, 0): logical = "eor"
            case (1, 1): logical = "bsl"
            case (1, 2): logical = "bit"
            default: logical = "bif"
            }
            return instruction(address, bytes, logical, threeVector(rd, rn, rm, isQ ? "16b" : "8b"))
        }

        let arrangement = vectorArrangement(size: size, isQ: isQ)
        let mnemonic: String?
        switch (u, opcode) {
        case (0, 0b01000): mnemonic = "sshl"
        case (1, 0b01000): mnemonic = "ushl"
        case (0, 0b00110): mnemonic = "cmgt"
        case (1, 0b00110): mnemonic = "cmhi"
        case (0, 0b00111): mnemonic = "cmge"
        case (1, 0b00111): mnemonic = "cmhs"
        case (0, 0b01100): mnemonic = "smax"
        case (1, 0b01100): mnemonic = "umax"
        case (0, 0b01101): mnemonic = "smin"
        case (1, 0b01101): mnemonic = "umin"
        case (0, 0b10000): mnemonic = "add"
        case (1, 0b10000): mnemonic = "sub"
        case (0, 0b10001): mnemonic = "cmtst"
        case (1, 0b10001): mnemonic = "cmeq"
        case (0, 0b10010): mnemonic = "mla"
        case (1, 0b10010): mnemonic = "mls"
        case (0, 0b10011): mnemonic = "mul"
        case (1, 0b10011): mnemonic = "pmul"
        case (0, 0b10100): mnemonic = "smaxp"
        case (1, 0b10100): mnemonic = "umaxp"
        case (0, 0b10101): mnemonic = "sminp"
        case (1, 0b10101): mnemonic = "uminp"
        case (_, 0b10110):
            guard size == 1 || size == 2 else { return unknownInstruction(address, bytes, word) }
            mnemonic = u == 0 ? "sqdmulh" : "sqrdmulh"
        case (0, 0b10111): mnemonic = "addp"
        default: mnemonic = nil
        }
        guard let mnemonic else { return unknownInstruction(address, bytes, word) }
        // Reserved sizes: `.1d` (size=11, Q=0) for every vector op here; size=11 for the
        // multiply and min/max groups (opcodes 01100/01101/10010/10011/10100/10101); PMUL is size=00 only.
        let noDoubleword: Set<UInt32> = [0b01100, 0b01101, 0b10010, 0b10011, 0b10100, 0b10101]
        guard !(size == 3 && !isQ), !(size == 3 && noDoubleword.contains(opcode)),
              !(mnemonic == "pmul" && size != 0) else {
            return unknownInstruction(address, bytes, word)
        }
        let vectorWidth = isQ ? 128 : 64
        let elementWidth = 8 << Int(size)
        let vectorShape = InstructionOperands.VectorArrangement(
            elementWidth: elementWidth, laneCount: vectorWidth / elementWidth)
        let typed: [InstructionOperands.Operand] = [rd, rn, rm].map {
            .register(.init(bank: .simd, index: $0, width: vectorWidth, arrangement: vectorShape))
        }
        return instruction(address, bytes, mnemonic, threeVector(rd, rn, rm, arrangement),
                           structuredOperands: .init(
                            coverage: .complete, opcodeClass: mnemonic, operands: typed,
                            presentation: .init(mnemonic: mnemonic)))
    }

    func decodeSIMDComplex(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let size = (word >> 22) & 0x3
        let opcode = (word >> 11) & 0x1f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        guard size != 0, !(size == 3 && !isQ) else {
            return unknownInstruction(address, bytes, word)
        }

        let mnemonic: String
        let rotation: Int
        if (opcode & 0b11100) == 0b11000 {
            mnemonic = "fcmla"
            rotation = Int(opcode & 0x3) * 90
        } else if (opcode & 0b11101) == 0b11100 {
            mnemonic = "fcadd"
            rotation = (opcode & 0b00010) == 0 ? 90 : 270
        } else {
            return unknownInstruction(address, bytes, word)
        }

        let arrangement = vectorArrangement(size: size, isQ: isQ)
        return instruction(address, bytes, mnemonic, "\(threeVector(rd, rn, rm, arrangement)), #\(rotation)")
    }
}

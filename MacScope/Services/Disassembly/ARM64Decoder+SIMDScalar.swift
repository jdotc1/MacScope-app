import Foundation

extension ARM64Decoder {
    private func simdScalarReg(size: UInt32) -> String {
        switch size { case 0: return "b"; case 1: return "h"; case 2: return "s"; default: return "d" }
    }

    /// Advanced SIMD scalar two-register miscellaneous: scalar unary, compare-zero, narrowing,
    /// FP convert/reciprocal, and FP compare-zero forms for b/h/s/d registers.
    func decodeSIMDScalarTwoRegMisc(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard (word & 0xdf3e_0c00) == 0x5e20_0800 else { return nil }
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 12) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let bit23 = (size >> 1) & 0x1
        let fpSizeIndex = (size & 0x1) == 0 ? 2 : 3

        func unary(_ mnemonic: String, sizeIndex: Int) -> DecodedInstruction {
            instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: sizeIndex)), \(fpRegister(rn, sizeIndex: sizeIndex))")
        }

        func compareZero(_ mnemonic: String, sizeIndex: Int, fp: Bool = false) -> DecodedInstruction {
            let zero = fp ? "#0.0" : "#0"
            return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: sizeIndex)), \(fpRegister(rn, sizeIndex: sizeIndex)), \(zero)")
        }

        func narrow(_ mnemonic: String) -> DecodedInstruction {
            guard size <= 2 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: Int(size))), \(fpRegister(rn, sizeIndex: Int(size + 1)))")
        }

        switch (u, opcode) {
        case (0, 0x03): return unary("suqadd", sizeIndex: Int(size))
        case (1, 0x03): return unary("usqadd", sizeIndex: Int(size))
        case (0, 0x07): return unary("sqabs", sizeIndex: Int(size))
        case (1, 0x07): return unary("sqneg", sizeIndex: Int(size))

        case (0, 0x08):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return compareZero("cmgt", sizeIndex: 3)
        case (1, 0x08):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return compareZero("cmge", sizeIndex: 3)
        case (0, 0x09):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return compareZero("cmeq", sizeIndex: 3)
        case (1, 0x09):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return compareZero("cmle", sizeIndex: 3)
        case (0, 0x0a):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return compareZero("cmlt", sizeIndex: 3)
        case (0, 0x0b):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return unary("abs", sizeIndex: 3)
        case (1, 0x0b):
            guard size == 3 else { return unknownInstruction(address, bytes, word) }
            return unary("neg", sizeIndex: 3)

        case (1, 0x12): return narrow("sqxtun")
        case (0, 0x14): return narrow("sqxtn")
        case (1, 0x14): return narrow("uqxtn")
        case (1, 0x16):
            guard size == 1 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "fcvtxn", "\(fpRegister(rd, sizeIndex: 2)), \(fpRegister(rn, sizeIndex: 3))")

        case (0, 0x0c):
            guard bit23 == 1 else { return unknownInstruction(address, bytes, word) }
            return compareZero("fcmgt", sizeIndex: fpSizeIndex, fp: true)
        case (1, 0x0c):
            guard bit23 == 1 else { return unknownInstruction(address, bytes, word) }
            return compareZero("fcmge", sizeIndex: fpSizeIndex, fp: true)
        case (0, 0x0d):
            guard bit23 == 1 else { return unknownInstruction(address, bytes, word) }
            return compareZero("fcmeq", sizeIndex: fpSizeIndex, fp: true)
        case (1, 0x0d):
            guard bit23 == 1 else { return unknownInstruction(address, bytes, word) }
            return compareZero("fcmle", sizeIndex: fpSizeIndex, fp: true)
        case (0, 0x0e):
            guard bit23 == 1 else { return unknownInstruction(address, bytes, word) }
            return compareZero("fcmlt", sizeIndex: fpSizeIndex, fp: true)

        case (_, 0x1a):
            let mnemonic: String
            switch (u, bit23) {
            case (0, 0): mnemonic = "fcvtns"
            case (1, 0): mnemonic = "fcvtnu"
            case (0, 1): mnemonic = "fcvtps"
            default: mnemonic = "fcvtpu"
            }
            return unary(mnemonic, sizeIndex: fpSizeIndex)
        case (_, 0x1b):
            let mnemonic: String
            switch (u, bit23) {
            case (0, 0): mnemonic = "fcvtms"
            case (1, 0): mnemonic = "fcvtmu"
            case (0, 1): mnemonic = "fcvtzs"
            default: mnemonic = "fcvtzu"
            }
            return unary(mnemonic, sizeIndex: fpSizeIndex)
        case (0, 0x1c):
            guard bit23 == 0 else { return unknownInstruction(address, bytes, word) }
            return unary("fcvtas", sizeIndex: fpSizeIndex)
        case (1, 0x1c):
            guard bit23 == 0 else { return unknownInstruction(address, bytes, word) }
            return unary("fcvtau", sizeIndex: fpSizeIndex)
        case (0, 0x1d):
            return unary(bit23 == 0 ? "scvtf" : "frecpe", sizeIndex: fpSizeIndex)
        case (1, 0x1d):
            return unary(bit23 == 0 ? "ucvtf" : "frsqrte", sizeIndex: fpSizeIndex)
        case (0, 0x1f):
            guard bit23 == 1 else { return unknownInstruction(address, bytes, word) }
            return unary("frecpx", sizeIndex: fpSizeIndex)
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    /// Advanced SIMD scalar two-register miscellaneous FP16 block. The element width is fixed to h;
    /// bit23 selects the FP sub-family instead of being part of a size field.
    func decodeSIMDScalarTwoRegMiscFP16(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard (word & 0xdf7e_0c00) == 0x5e78_0800 else { return nil }
        let u = (word >> 29) & 0x1
        let a = (word >> 23) & 0x1
        let opcode = (word >> 12) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        func unary(_ mnemonic: String) -> DecodedInstruction {
            instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: 1)), \(fpRegister(rn, sizeIndex: 1))")
        }

        func compareZero(_ mnemonic: String) -> DecodedInstruction {
            instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: 1)), \(fpRegister(rn, sizeIndex: 1)), #0.0")
        }

        switch (u, a, opcode) {
        case (0, 0, 0x1a): return unary("fcvtns")
        case (1, 0, 0x1a): return unary("fcvtnu")
        case (0, 0, 0x1b): return unary("fcvtms")
        case (1, 0, 0x1b): return unary("fcvtmu")
        case (0, 1, 0x1a): return unary("fcvtps")
        case (1, 1, 0x1a): return unary("fcvtpu")
        case (0, 1, 0x1b): return unary("fcvtzs")
        case (1, 1, 0x1b): return unary("fcvtzu")
        case (0, 0, 0x1c): return unary("fcvtas")
        case (1, 0, 0x1c): return unary("fcvtau")
        case (0, 0, 0x1d): return unary("scvtf")
        case (1, 0, 0x1d): return unary("ucvtf")
        case (0, 1, 0x1d): return unary("frecpe")
        case (1, 1, 0x1d): return unary("frsqrte")
        case (0, 1, 0x1f): return unary("frecpx")
        case (0, 1, 0x0c): return compareZero("fcmgt")
        case (1, 1, 0x0c): return compareZero("fcmge")
        case (0, 1, 0x0d): return compareZero("fcmeq")
        case (1, 1, 0x0d): return compareZero("fcmle")
        case (0, 1, 0x0e): return compareZero("fcmlt")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    /// Advanced SIMD scalar pairwise: reduce v<n>.2h/.2s/.2d into h/s/d.
    func decodeSIMDScalarPairwise(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard (word & 0xdf3e_0c00) == 0x5e30_0800 else { return nil }
        let u = (word >> 29) & 0x1
        let sz = (word >> 22) & 0x3
        let a = (word >> 23) & 0x1
        let bit22 = sz & 0x1
        let opcode = (word >> 12) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String
        let sizeIndex: Int
        let arrangement: String

        if u == 0, opcode == 0x1b, sz == 0b11 {
            mnemonic = "addp"
            sizeIndex = 3
            arrangement = "2d"
        } else if u == 0 {
            guard bit22 == 0 else { return nil }
            sizeIndex = 1
            arrangement = "2h"
            switch (opcode, a) {
            case (0x0c, 0): mnemonic = "fmaxnmp"
            case (0x0c, 1): mnemonic = "fminnmp"
            case (0x0d, 0): mnemonic = "faddp"
            case (0x0f, 0): mnemonic = "fmaxp"
            case (0x0f, 1): mnemonic = "fminp"
            default: return nil
            }
        } else {
            sizeIndex = bit22 == 0 ? 2 : 3
            arrangement = bit22 == 0 ? "2s" : "2d"
            switch (opcode, a) {
            case (0x0c, 0): mnemonic = "fmaxnmp"
            case (0x0c, 1): mnemonic = "fminnmp"
            case (0x0d, 0): mnemonic = "faddp"
            case (0x0f, 0): mnemonic = "fmaxp"
            case (0x0f, 1): mnemonic = "fminp"
            default: return nil
            }
        }

        return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: sizeIndex)), v\(rn).\(arrangement)")
    }

    /// Advanced SIMD scalar three-same FP16: FP arithmetic/compare on h registers.
    func decodeSIMDScalarThreeSameFP16(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard (word & 0xdf60_8400) == 0x5e40_0400 else { return nil }
        let u = (word >> 29) & 0x1
        let a = (word >> 23) & 0x1
        let opcode = (word >> 11) & 0xf
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String
        switch (u, a, opcode) {
        case (0, 0, 0b0011): mnemonic = "fmulx"
        case (0, 0, 0b0100): mnemonic = "fcmeq"
        case (0, 0, 0b0111): mnemonic = "frecps"
        case (0, 1, 0b0111): mnemonic = "frsqrts"
        case (1, 0, 0b0100): mnemonic = "fcmge"
        case (1, 1, 0b0100): mnemonic = "fcmgt"
        case (1, 0, 0b0101): mnemonic = "facge"
        case (1, 1, 0b0101): mnemonic = "facgt"
        case (1, 1, 0b0010): mnemonic = "fabd"
        default: return nil
        }

        return instruction(address, bytes, mnemonic, "\(fpRegister(rd, sizeIndex: 1)), \(fpRegister(rn, sizeIndex: 1)), \(fpRegister(rm, sizeIndex: 1))")
    }

    /// Advanced SIMD scalar three-different: signed saturating long multiply on h/s sources.
    func decodeSIMDScalarThreeDifferent(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard (word & 0xdf20_0c00) == 0x5e20_0000 else { return nil }
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 12) & 0xf
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String
        switch (u, opcode) {
        case (0, 0b1001): mnemonic = "sqdmlal"
        case (0, 0b1011): mnemonic = "sqdmlsl"
        case (0, 0b1101): mnemonic = "sqdmull"
        default: return nil
        }
        guard size == 0b01 || size == 0b10 else { return nil }

        let dest = simdScalarReg(size: size + 1)
        let source = simdScalarReg(size: size)
        return instruction(address, bytes, mnemonic, "\(dest)\(rd), \(source)\(rn), \(source)\(rm)")
    }

    /// Advanced SIMD scalar three-same: integer (add/sub/cmXX/sqadd/… on b/h/s/d) and FP
    /// (fabd/fmulx/frecps/frsqrts/fcmeq/fcmge/fcmgt/facge/facgt on s/d). Operands are three scalar
    /// registers of the size-selected width. nil for unrecognized opcodes.
    func decodeSIMDScalarThreeSame(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 11) & 0x1f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        if opcode >= 0b11000 {
            let a = (word >> 23) & 0x1
            let sz = (word >> 22) & 0x1
            let r = sz == 0 ? "s" : "d"
            let mnemonic: String?
            switch (u, a, opcode) {
            case (0, 0, 0b11011): mnemonic = "fmulx"
            case (0, 0, 0b11100): mnemonic = "fcmeq"
            case (0, 0, 0b11111): mnemonic = "frecps"
            case (0, 1, 0b11111): mnemonic = "frsqrts"
            case (1, 0, 0b11100): mnemonic = "fcmge"
            case (1, 1, 0b11100): mnemonic = "fcmgt"
            case (1, 0, 0b11101): mnemonic = "facge"
            case (1, 1, 0b11101): mnemonic = "facgt"
            case (1, 1, 0b11010): mnemonic = "fabd"
            default: mnemonic = nil
            }
            guard let mnemonic else { return nil }
            return instruction(address, bytes, mnemonic, "\(r)\(rd), \(r)\(rn), \(r)\(rm)")
        }
        let mnemonic: String
        switch (u, opcode) {
        case (0, 0b00001): mnemonic = "sqadd"
        case (1, 0b00001): mnemonic = "uqadd"
        case (0, 0b00101): mnemonic = "sqsub"
        case (1, 0b00101): mnemonic = "uqsub"
        case (0, 0b00110): mnemonic = "cmgt"
        case (1, 0b00110): mnemonic = "cmhi"
        case (0, 0b00111): mnemonic = "cmge"
        case (1, 0b00111): mnemonic = "cmhs"
        case (0, 0b01000): mnemonic = "sshl"
        case (1, 0b01000): mnemonic = "ushl"
        case (0, 0b01001): mnemonic = "sqshl"
        case (1, 0b01001): mnemonic = "uqshl"
        case (0, 0b01010): mnemonic = "srshl"
        case (1, 0b01010): mnemonic = "urshl"
        case (0, 0b01011): mnemonic = "sqrshl"
        case (1, 0b01011): mnemonic = "uqrshl"
        case (0, 0b10000): mnemonic = "add"
        case (1, 0b10000): mnemonic = "sub"
        case (0, 0b10001): mnemonic = "cmtst"
        case (1, 0b10001): mnemonic = "cmeq"
        case (0, 0b10110): mnemonic = "sqdmulh"    // H or S only
        case (1, 0b10110): mnemonic = "sqrdmulh"
        default: return nil
        }
        switch opcode {
        case 0b00110, 0b00111, 0b01000, 0b01010, 0b10000, 0b10001:
            guard size == 0b11 else { return nil }
        case 0b10110:
            guard size == 0b01 || size == 0b10 else { return nil }
        default:
            break
        }
        let r = simdScalarReg(size: size)
        return instruction(address, bytes, mnemonic, "\(r)\(rd), \(r)\(rn), \(r)\(rm)")
    }

    /// Advanced SIMD scalar three-same-extra: RDMA scalar sqrdmlah/sqrdmlsh (H or S only).
    func decodeSIMDScalarThreeSameExtra(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 11) & 0x1f
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String
        switch (u, opcode) {
        case (1, 0b10000): mnemonic = "sqrdmlah"
        case (1, 0b10001): mnemonic = "sqrdmlsh"
        default: return unknownInstruction(address, bytes, word)
        }

        guard size == 0b01 || size == 0b10 else { return unknownInstruction(address, bytes, word) }
        let r = simdScalarReg(size: size)
        return instruction(address, bytes, mnemonic, "\(r)\(rd), \(r)\(rn), \(r)\(rm)")
    }

    /// Advanced SIMD scalar copy: the scalar DUP-element form, disassembled as `mov <r>d, Vn.<T>[idx]`
    /// (extract one lane into a scalar FP register). imm5 selects element size and index.
    func decodeSIMDScalarCopy(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        // Scalar DUP (element), rendered as MOV, fixes op[29] to zero.
        guard (word & 0x2000_0000) == 0 else { return unknownInstruction(address, bytes, word) }
        let imm5 = (word >> 16) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let elem: String
        let index: Int
        if imm5 & 0b1 != 0 { elem = "b"; index = Int(imm5 >> 1) }
        else if imm5 & 0b10 != 0 { elem = "h"; index = Int(imm5 >> 2) }
        else if imm5 & 0b100 != 0 { elem = "s"; index = Int(imm5 >> 3) }
        else if imm5 & 0b1000 != 0 { elem = "d"; index = Int(imm5 >> 4) }
        else { return nil }
        return instruction(address, bytes, "mov", "\(elem)\(rd), v\(rn).\(elem)[\(index)]")
    }

    /// Advanced SIMD scalar x indexed element: scalar FP/integer multiply lane ops plus RDMA
    /// sqrdmlah/sqrdmlsh. Same index/register-width rules as the vector form.
    func decodeSIMDScalarByElement(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let l = (word >> 21) & 0x1
        let m = (word >> 20) & 0x1
        let rm4 = (word >> 16) & 0xf
        let opcode = (word >> 12) & 0xf
        let h = (word >> 11) & 0x1
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        // FP lane ops: fmla(0001)/fmls(0101)/fmul(1001,U0)/fmulx(1001,U1).
        // size=00 is the FP16 scalar lane class; size=10/11 are the existing S/D forms.
        if opcode == 0b0001 || opcode == 0b0101 || opcode == 0b1001 {
            if size == 0 {
                let mnemonic: String
                switch (u, opcode) {
                case (0, 0b0001): mnemonic = "fmla"
                case (0, 0b0101): mnemonic = "fmls"
                case (0, 0b1001): mnemonic = "fmul"
                case (1, 0b1001): mnemonic = "fmulx"
                default: return nil
                }
                let rm = Int(rm4)
                let index = Int((h << 2) | (l << 1) | m)
                return instruction(address, bytes, mnemonic, "h\(rd), h\(rn), v\(rm).h[\(index)]")
            }
            guard (size >> 1) == 1 else { return nil }
            let sz = size & 1
            guard sz == 0 || l == 0 else { return nil }
            let r = sz == 0 ? "s" : "d"
            let rm = Int((m << 4) | rm4)
            let index = sz == 0 ? Int((h << 1) | l) : Int(h)
            let mnemonic: String
            switch (u, opcode) {
            case (0, 0b0001): mnemonic = "fmla"
            case (0, 0b0101): mnemonic = "fmls"
            case (0, 0b1001): mnemonic = "fmul"
            case (1, 0b1001): mnemonic = "fmulx"
            default: return nil
            }
            return instruction(address, bytes, mnemonic, "\(r)\(rd), \(r)\(rn), v\(rm).\(r)[\(index)]")
        }

        // Long/widening scalar by-element: destination is one element size wider than source.
        if opcode == 0b0011 || opcode == 0b0111 || opcode == 0b1011 {
            guard u == 0 else { return nil }
            let mnemonic: String
            switch opcode {
            case 0b0011: mnemonic = "sqdmlal"
            case 0b0111: mnemonic = "sqdmlsl"
            case 0b1011: mnemonic = "sqdmull"
            default: return nil
            }

            let source: String
            let dest: String
            let index: Int
            let rm: Int
            switch size {
            case 1:
                source = "h"
                dest = "s"
                index = Int((h << 2) | (l << 1) | m)
                rm = Int(rm4)
            case 2:
                source = "s"
                dest = "d"
                index = Int((h << 1) | l)
                rm = Int((m << 4) | rm4)
            default:
                return nil
            }
            return instruction(address, bytes, mnemonic, "\(dest)\(rd), \(source)\(rn), v\(rm).\(source)[\(index)]")
        }

        let mnemonic: String
        switch (u, opcode) {
        case (0, 0b1100): mnemonic = "sqdmulh"
        case (0, 0b1101): mnemonic = "sqrdmulh"
        case (1, 0b1101): mnemonic = "sqrdmlah"
        case (1, 0b1111): mnemonic = "sqrdmlsh"
        default: return nil
        }
        let elem: String
        let index: Int
        let rm: Int
        switch size {
        case 1: elem = "h"; index = Int((h << 2) | (l << 1) | m); rm = Int(rm4)
        case 2: elem = "s"; index = Int((h << 1) | l); rm = Int((m << 4) | rm4)
        default: return nil
        }
        return instruction(address, bytes, mnemonic, "\(elem)\(rd), \(elem)\(rn), v\(rm).\(elem)[\(index)]")
    }

    /// Advanced SIMD scalar shift-by-immediate (shl/sshr/ushr/srshr/urshr/sqshl/… on a scalar D reg).
    /// immh:immb encode the amount: left shifts subtract esize, right shifts subtract from 2*esize.
    func decodeSIMDScalarShiftImm(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let u = (word >> 29) & 0x1
        let immh = (word >> 19) & 0xf
        let immb = (word >> 16) & 0x7
        let opcode = (word >> 11) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        guard let sizeIndex = simdShiftElementSizeIndex(immh: immh) else { return nil }
        let esize = 8 << sizeIndex
        let immhb = Int((immh << 3) | immb)
        // Left-shift opcodes compute (immhb - esize); right-shift opcodes compute (2*esize - immhb).
        let isLeft = (opcode == 0b01010 || opcode == 0b01110 || opcode == 0b01100)
        let shift = isLeft ? (immhb - esize) : (2 * esize - immhb)
        let mnemonic: String
        switch (u, opcode) {
        case (0, 0b00000): mnemonic = "sshr"
        case (1, 0b00000): mnemonic = "ushr"
        case (0, 0b00010): mnemonic = "ssra"
        case (1, 0b00010): mnemonic = "usra"
        case (0, 0b00100): mnemonic = "srshr"
        case (1, 0b00100): mnemonic = "urshr"
        case (0, 0b00110): mnemonic = "srsra"
        case (1, 0b00110): mnemonic = "ursra"
        case (0, 0b01010): mnemonic = "shl"
        case (1, 0b01100): mnemonic = "sqshlu"
        case (0, 0b01110): mnemonic = "sqshl"
        case (1, 0b01110): mnemonic = "uqshl"
        default: return nil
        }
        // Only the saturating left shifts (sqshl/uqshl/sqshlu) have B/H/S scalar forms; every other
        // scalar shift is 64-bit only, so immh=0xxx is reserved (`5f3d166a` is not `ssra s10, …`).
        if sizeIndex != 3, opcode != 0b01100, opcode != 0b01110 {
            return unknownInstruction(address, bytes, word)
        }
        let r = simdScalarReg(size: UInt32(sizeIndex))
        return instruction(address, bytes, mnemonic, "\(r)\(rd), \(r)\(rn), #\(shift)")
    }
}

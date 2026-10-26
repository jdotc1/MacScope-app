import Foundation

extension ARM64Decoder {
    func decodeSIMDByElementFP16(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let l = (word >> 21) & 0x1
        let m = (word >> 20) & 0x1
        let rm = Int((word >> 16) & 0xf)
        let opcode = (word >> 12) & 0xf
        let h = (word >> 11) & 0x1
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        let mnemonic: String?
        switch (u, opcode) {
        case (0, 0b0001): mnemonic = "fmla"
        case (0, 0b0101): mnemonic = "fmls"
        case (0, 0b1001): mnemonic = "fmul"
        case (1, 0b1001): mnemonic = "fmulx"
        default: mnemonic = nil
        }
        guard let mnemonic else { return nil }

        let arrangement = isQ ? "8h" : "4h"
        let index = Int((h << 2) | (l << 1) | m)
        return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement), v\(rm).h[\(index)]")
    }

    /// Advanced SIMD vector x indexed element. The second source is a single lane `Vm.Ts[index]`;
    /// the index and Vm register width depend on the element size (H: index=H:L:M with Vm restricted
    /// to v0-v15; S: index=H:L; D: index=H). Returns nil for unallocated sibling slots.
    func decodeSIMDByElement(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let l = (word >> 21) & 0x1
        let m = (word >> 20) & 0x1
        let rm4 = (word >> 16) & 0xf
        let opcode = (word >> 12) & 0xf
        let h = (word >> 11) & 0x1
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // FP lane ops: opcode 0001=fmla, 0101=fmls, 1001=fmul(U=0)/fmulx(U=1). sz=bit22 selects S/D;
        // bit23 must be 1 (bit23=0 is the FP16 lane form, deferred).
        if opcode == 0b0001 || opcode == 0b0101 || opcode == 0b1001 {
            guard (size >> 1) == 1 else { return nil }
            let sz = size & 1
            guard sz == 0 || (isQ && l == 0) else { return nil }
            let arrangement = sz == 0 ? (isQ ? "4s" : "2s") : (isQ ? "2d" : "1d")
            let elem = sz == 0 ? "s" : "d"
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
            let ops = "v\(rd).\(arrangement), v\(rn).\(arrangement), v\(rm).\(elem)[\(index)]"
            return instruction(address, bytes, mnemonic, ops)
        }

        // Dot-product by element: sdot/udot Vd.<4s|2s>, Vn.<16b|8b>, Vm.4b[index]. index = H:L.
        if opcode == 0b1110 {
            guard size == 0b10 else { return nil }
            let ta = isQ ? "4s" : "2s"
            let tb = isQ ? "16b" : "8b"
            let rm = Int((m << 4) | rm4)
            let index = Int((h << 1) | l)
            let name = u == 0 ? "sdot" : "udot"
            return instruction(address, bytes, name, "v\(rd).\(ta), v\(rn).\(tb), v\(rm).4b[\(index)]")
        }

        // i8mm/BFloat16 by-element: dot-product forms share U=0/opcode=1111 and split by size.
        if u == 0 && opcode == 0b1111 {
            if size == 0b00 || size == 0b10 {
                let ta = isQ ? "4s" : "2s"
                let tb = isQ ? "16b" : "8b"
                let rm = Int((m << 4) | rm4)
                let index = Int((h << 1) | l)
                let mnemonic = size == 0b00 ? "sudot" : "usdot"
                return instruction(address, bytes, mnemonic, "v\(rd).\(ta), v\(rn).\(tb), v\(rm).4b[\(index)]")
            }
            if size == 0b01 {
                let ta = isQ ? "4s" : "2s"
                let tb = isQ ? "8h" : "4h"
                let rm = Int((m << 4) | rm4)
                let index = Int((h << 1) | l)
                return instruction(address, bytes, "bfdot", "v\(rd).\(ta), v\(rn).\(tb), v\(rm).2h[\(index)]")
            }
            if size == 0b11 {
                let rm = Int(rm4)
                let index = Int((h << 2) | (l << 1) | m)
                let mnemonic = isQ ? "bfmlalt" : "bfmlalb"
                return instruction(address, bytes, mnemonic, "v\(rd).4s, v\(rn).8h, v\(rm).h[\(index)]")
            }
            return nil
        }

        // Long/widening by-element: Vd wide, Vn narrow, Vm.<elem>[index] (H or S source only).
        let longName: String?
        switch (u, opcode) {
        case (0, 0b1010): longName = "smull"
        case (1, 0b1010): longName = "umull"
        case (0, 0b1011): longName = "sqdmull"
        case (0, 0b0010): longName = "smlal"
        case (1, 0b0010): longName = "umlal"
        case (0, 0b0011): longName = "sqdmlal"
        case (0, 0b0110): longName = "smlsl"
        case (1, 0b0110): longName = "umlsl"
        case (0, 0b0111): longName = "sqdmlsl"
        default: longName = nil
        }
        if let longName {
            let elem: String
            let index: Int
            let rm: Int
            switch size {
            case 1: elem = "h"; index = Int((h << 2) | (l << 1) | m); rm = Int(rm4)
            case 2: elem = "s"; index = Int((h << 1) | l); rm = Int((m << 4) | rm4)
            default: return nil
            }
            let wide = vectorArrangement(size: size + 1, isQ: true)
            let narrow = vectorArrangement(size: size, isQ: isQ)
            let suffix = isQ ? "2" : ""
            return instruction(address, bytes, longName + suffix, "v\(rd).\(wide), v\(rn).\(narrow), v\(rm).\(elem)[\(index)]")
        }

        // Integer same-width lane ops (H or S only).
        let mnemonic: String
        switch (u, opcode) {
        case (0, 0b1000): mnemonic = "mul"
        case (1, 0b0000): mnemonic = "mla"
        case (1, 0b0100): mnemonic = "mls"
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
        let arrangement = vectorArrangement(size: size, isQ: isQ)
        let ops = "v\(rd).\(arrangement), v\(rn).\(arrangement), v\(rm).\(elem)[\(index)]"
        // DP04 A2 covers the ordinary multiply forms; RDMA siblings stay explicitly unavailable.
        guard u == 0 || opcode == 0b0000 || opcode == 0b0100 else {
            return instruction(address, bytes, mnemonic, ops)
        }
        let vectorWidth = isQ ? 128 : 64
        let elementWidth = 8 << Int(size)
        let vectorShape = InstructionOperands.VectorArrangement(
            elementWidth: elementWidth, laneCount: vectorWidth / elementWidth)
        let typed: [InstructionOperands.Operand] = [
            .register(.init(bank: .simd, index: rd, width: vectorWidth, arrangement: vectorShape)),
            .register(.init(bank: .simd, index: rn, width: vectorWidth, arrangement: vectorShape)),
            // Vm selects a lane from the full 128-bit register regardless of destination Q.
            .register(.init(bank: .simd, index: rm, width: 128,
                            arrangement: .init(elementWidth: elementWidth), lane: index))
        ]
        return instruction(address, bytes, mnemonic, ops, structuredOperands: .init(
            coverage: .complete, opcodeClass: mnemonic, operands: typed,
            presentation: .init(mnemonic: mnemonic)))
    }

    func decodeSIMDComplexByElement(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let size = (word >> 22) & 0x3
        guard size == 1 || size == 2 else {
            return unknownInstruction(address, bytes, word)
        }

        let l = (word >> 21) & 0x1
        let m = (word >> 20) & 0x1
        let rm4 = (word >> 16) & 0xf
        let h = (word >> 11) & 0x1
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let rm = Int((m << 4) | rm4)
        let rotation = Int((word >> 13) & 0x3) * 90

        let arrangement: String
        let element: String
        let index: Int
        switch size {
        case 1:
            guard isQ || h == 0 else { return unknownInstruction(address, bytes, word) }
            arrangement = vectorArrangement(size: size, isQ: isQ)
            element = "h"
            index = Int((h << 1) | l)
        case 2:
            guard isQ, l == 0 else { return unknownInstruction(address, bytes, word) }
            arrangement = "4s"
            element = "s"
            index = Int(h)
        default:
            return unknownInstruction(address, bytes, word)
        }

        return instruction(
            address,
            bytes,
            "fcmla",
            "v\(rd).\(arrangement), v\(rn).\(arrangement), v\(rm).\(element)[\(index)], #\(rotation)"
        )
    }
}

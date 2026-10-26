import Foundation

extension ARM64Decoder {
    // MARK: - Advanced SIMD (vector)

    /// Vector arrangement specifier for element size (0=b,1=h,2=s,3=d) and Q.
    func vectorArrangement(size: UInt32, isQ: Bool) -> String {
        switch size {
        case 0: return isQ ? "16b" : "8b"
        case 1: return isQ ? "8h" : "4h"
        case 2: return isQ ? "4s" : "2s"
        default: return isQ ? "2d" : "1d"
        }
    }

    func simdShiftElementSizeIndex(immh: UInt32) -> UInt32? {
        guard immh != 0 else { return nil }
        if (immh & 0b1000) != 0 { return 3 }
        if (immh & 0b0100) != 0 { return 2 }
        if (immh & 0b0010) != 0 { return 1 }
        return 0
    }

    func threeVector(_ rd: Int, _ rn: Int, _ rm: Int, _ arrangement: String) -> String {
        "v\(rd).\(arrangement), v\(rn).\(arrangement), v\(rm).\(arrangement)"
    }

    func decodeSIMDTwoRegMiscFP16(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let a = (word >> 23) & 0x1
        let opcode = (word >> 12) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let arrangement = isQ ? "8h" : "4h"

        func unary(_ mnemonic: String) -> DecodedInstruction {
            instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement)")
        }

        func compareZero(_ mnemonic: String) -> DecodedInstruction {
            instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement), #0.0")
        }

        switch (u, a, opcode) {
        case (0, 0, 0x18): return unary("frintn")
        case (0, 0, 0x19): return unary("frintm")
        case (0, 0, 0x1a): return unary("fcvtns")
        case (0, 0, 0x1b): return unary("fcvtms")
        case (0, 0, 0x1c): return unary("fcvtas")
        case (0, 0, 0x1d): return unary("scvtf")
        case (1, 0, 0x18): return unary("frinta")
        case (1, 0, 0x19): return unary("frintx")
        case (1, 0, 0x1a): return unary("fcvtnu")
        case (1, 0, 0x1b): return unary("fcvtmu")
        case (1, 0, 0x1c): return unary("fcvtau")
        case (1, 0, 0x1d): return unary("ucvtf")
        case (0, 1, 0x0c): return compareZero("fcmgt")
        case (1, 1, 0x0c): return compareZero("fcmge")
        case (0, 1, 0x0d): return compareZero("fcmeq")
        case (1, 1, 0x0d): return compareZero("fcmle")
        case (0, 1, 0x0e): return compareZero("fcmlt")
        case (0, 1, 0x0f): return unary("fabs")
        case (1, 1, 0x0f): return unary("fneg")
        case (0, 1, 0x18): return unary("frintp")
        case (0, 1, 0x19): return unary("frintz")
        case (1, 1, 0x19): return unary("frinti")
        case (0, 1, 0x1a): return unary("fcvtps")
        case (1, 1, 0x1a): return unary("fcvtpu")
        case (0, 1, 0x1b): return unary("fcvtzs")
        case (1, 1, 0x1b): return unary("fcvtzu")
        case (0, 1, 0x1d): return unary("frecpe")
        case (1, 1, 0x1d): return unary("frsqrte")
        case (1, 1, 0x1f): return unary("fsqrt")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    func decodeSIMDThreeDifferent(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 12) & 0xf
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        guard size < 3 else { return unknownInstruction(address, bytes, word) }

        let wideArrangement = vectorArrangement(size: size + 1, isQ: true)
        let narrowArrangement = vectorArrangement(size: size, isQ: isQ)
        let suffix = isQ ? "2" : ""

        // Integer "three different" forms. Saturating doubling (sqdm*) and
        // polynomial (pmull) forms have extra size rules and stay unknown.
        enum Shape { case long, wide, narrowHigh }
        let table: [UInt32: (String, Shape)] = u == 0
            ? [0x0: ("saddl", .long), 0x1: ("saddw", .wide), 0x2: ("ssubl", .long),
               0x3: ("ssubw", .wide), 0x4: ("addhn", .narrowHigh), 0x5: ("sabal", .long),
               0x6: ("subhn", .narrowHigh), 0x7: ("sabdl", .long), 0x8: ("smlal", .long),
               0xa: ("smlsl", .long), 0xc: ("smull", .long)]
            : [0x0: ("uaddl", .long), 0x1: ("uaddw", .wide), 0x2: ("usubl", .long),
               0x3: ("usubw", .wide), 0x4: ("raddhn", .narrowHigh), 0x5: ("uabal", .long),
               0x6: ("rsubhn", .narrowHigh), 0x7: ("uabdl", .long), 0x8: ("umlal", .long),
               0xa: ("umlsl", .long), 0xc: ("umull", .long)]
        guard let (name, shape) = table[opcode] else { return unknownInstruction(address, bytes, word) }
        let operands: String
        switch shape {
        case .long:
            operands = "v\(rd).\(wideArrangement), v\(rn).\(narrowArrangement), v\(rm).\(narrowArrangement)"
        case .wide:
            operands = "v\(rd).\(wideArrangement), v\(rn).\(wideArrangement), v\(rm).\(narrowArrangement)"
        case .narrowHigh:
            operands = "v\(rd).\(narrowArrangement), v\(rn).\(wideArrangement), v\(rm).\(wideArrangement)"
        }
        return instruction(address, bytes, "\(name)\(suffix)", operands)
    }

    func decodeSIMDTwoRegMisc(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 12) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // Same-width unary: `Vd.T, Vn.T` with T from the size field. The size=3/Q=0 slot is a
        // reserved (.1d) encoding — reject it, matching the existing compare-with-zero cases.
        func sameWidth(_ mnem: String) -> DecodedInstruction {
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let a = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, mnem, "v\(rd).\(a), v\(rn).\(a)")
        }
        // Byte-arrangement unary (cnt/mvn/rbit): always `.8b`/`.16b`.
        func byteWidth(_ mnem: String) -> DecodedInstruction {
            let a = isQ ? "16b" : "8b"
            return instruction(address, bytes, mnem, "v\(rd).\(a), v\(rn).\(a)")
        }
        // Long-pairwise (saddlp/uaddlp/sadalp/uadalp): dest widens one step, half the lanes.
        func widenPairwise(_ mnem: String) -> DecodedInstruction {
            guard size <= 2 else { return unknownInstruction(address, bytes, word) }
            let dst = vectorArrangement(size: size + 1, isQ: isQ)
            let src = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, mnem, "v\(rd).\(dst), v\(rn).\(src)")
        }
        // Narrowing (xtn/sqxtn/uqxtn/sqxtun): dest narrow (`2` high-half on Q), src one step wider.
        func narrow(_ mnem: String) -> DecodedInstruction {
            guard size <= 2 else { return unknownInstruction(address, bytes, word) }
            let dst = vectorArrangement(size: size, isQ: isQ)
            let src = vectorArrangement(size: size + 1, isQ: true)
            return instruction(address, bytes, mnem + (isQ ? "2" : ""), "v\(rd).\(dst), v\(rn).\(src)")
        }
        // FP unary: `Vd.T, Vn.T` with T from sz=bit22; Q=0/sz=1 is the reserved `.1d` slot.
        func fpArrangement() -> String? {
            let sz = (word >> 22) & 1
            if sz == 0 { return isQ ? "4s" : "2s" }
            return isQ ? "2d" : nil
        }
        func fpUnary(_ mnem: String, compareZero: Bool = false) -> DecodedInstruction {
            guard let a = fpArrangement() else { return unknownInstruction(address, bytes, word) }
            let ops = compareZero ? "v\(rd).\(a), v\(rn).\(a), #0.0" : "v\(rd).\(a), v\(rn).\(a)"
            return instruction(address, bytes, mnem, ops)
        }

        switch (u, opcode) {
        // --- integer unary ---
        case (0, 0x00): guard size <= 2 else { return unknownInstruction(address, bytes, word) }; return sameWidth("rev64")
        case (1, 0x00): guard size <= 1 else { return unknownInstruction(address, bytes, word) }; return sameWidth("rev32")
        case (0, 0x01): guard size == 0 else { return unknownInstruction(address, bytes, word) }; return sameWidth("rev16")
        case (0, 0x02): return widenPairwise("saddlp")
        case (1, 0x02): return widenPairwise("uaddlp")
        case (0, 0x03): return sameWidth("suqadd")
        case (1, 0x03): return sameWidth("usqadd")
        case (0, 0x04): guard size <= 2 else { return unknownInstruction(address, bytes, word) }; return sameWidth("cls")
        case (1, 0x04): guard size <= 2 else { return unknownInstruction(address, bytes, word) }; return sameWidth("clz")
        case (0, 0x05): guard size == 0 else { return unknownInstruction(address, bytes, word) }; return byteWidth("cnt")
        case (1, 0x05):
            if size == 0 { return byteWidth("mvn") }
            if size == 1 { return byteWidth("rbit") }
            return unknownInstruction(address, bytes, word)
        case (0, 0x06): return widenPairwise("sadalp")
        case (1, 0x06): return widenPairwise("uadalp")
        case (0, 0x07): return sameWidth("sqabs")
        case (1, 0x07): return sameWidth("sqneg")
        case (0, 0x0b): return sameWidth("abs")
        case (1, 0x0b): return sameWidth("neg")
        case (0, 0x12): return narrow("xtn")
        case (1, 0x12): return narrow("sqxtun")
        case (1, 0x13):
            guard size <= 2 else { return unknownInstruction(address, bytes, word) }
            let dst = vectorArrangement(size: size + 1, isQ: true)
            let src = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, isQ ? "shll2" : "shll", "v\(rd).\(dst), v\(rn).\(src), #\(8 << size)")
        case (0, 0x14): return narrow("sqxtn")
        case (1, 0x14): return narrow("uqxtn")
        // --- FP unary + compare-with-zero (bit23=1 half; bit23=0 is FP16, deferred) ---
        case (0, 0x0c): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fcmgt", compareZero: true)
        case (1, 0x0c): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fcmge", compareZero: true)
        case (0, 0x0d): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fcmeq", compareZero: true)
        case (1, 0x0d): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fcmle", compareZero: true)
        case (0, 0x0e): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fcmlt", compareZero: true)
        case (0, 0x0f): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fabs")
        case (1, 0x0f): guard (size >> 1) == 1 else { return unknownInstruction(address, bytes, word) }; return fpUnary("fneg")
        case (1, 0x1f) where size >= 2: return fpUnary("fsqrt")
        case (_, 0x08):
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let mnemonic = u == 0 ? "cmgt" : "cmge"
            let arrangement = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement), #0")
        case (_, 0x09):
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let mnemonic = u == 0 ? "cmeq" : "cmle"
            let arrangement = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement), #0")
        case (0, 0x0a):
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let arrangement = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, "cmlt", "v\(rd).\(arrangement), v\(rn).\(arrangement), #0")
        case (0, 0x17):
            guard size <= 1 else { return unknownInstruction(address, bytes, word) }
            let sourceArrangement = vectorArrangement(size: size + 1, isQ: isQ)
            let destinationArrangement = vectorArrangement(size: size + 2, isQ: true)
            return instruction(address, bytes, isQ ? "fcvtl2" : "fcvtl", "v\(rd).\(destinationArrangement), v\(rn).\(sourceArrangement)")
        case (0, 0x16):
            if size <= 1 {
                let destinationArrangement = vectorArrangement(size: size + 1, isQ: isQ)
                let sourceArrangement = vectorArrangement(size: size + 2, isQ: true)
                return instruction(address, bytes, isQ ? "fcvtn2" : "fcvtn", "v\(rd).\(destinationArrangement), v\(rn).\(sourceArrangement)")
            }
            if size == 2 {
                let destinationArrangement = vectorArrangement(size: 1, isQ: isQ)
                return instruction(address, bytes, isQ ? "bfcvtn2" : "bfcvtn", "v\(rd).\(destinationArrangement), v\(rn).4s")
            }
            return unknownInstruction(address, bytes, word)
        case (1, 0x16):
            // fcvtxn/fcvtxn2 — narrow FP64 -> FP32 (round to odd); only 2d -> 2s/4s.
            guard size == 1 else { return unknownInstruction(address, bytes, word) }
            let destinationArrangement = vectorArrangement(size: size + 1, isQ: isQ)
            let sourceArrangement = vectorArrangement(size: size + 2, isQ: true)
            return instruction(address, bytes, isQ ? "fcvtxn2" : "fcvtxn", "v\(rd).\(destinationArrangement), v\(rn).\(sourceArrangement)")
        case (_, 0x1e), (_, 0x1f):
            // frint32z/frint32x (0x1e), frint64z/frint64x (0x1f). sz=bit22 selects the element width.
            guard size <= 1 else { return unknownInstruction(address, bytes, word) }
            guard let arrangement = fpArrangement() else { return unknownInstruction(address, bytes, word) }
            let width = opcode == 0x1f ? "frint64" : "frint32"
            let mnemonic = width + (u == 0 ? "z" : "x")
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement)")
        case (_, 0x1d):
            guard let arrangement = fpArrangement() else { return unknownInstruction(address, bytes, word) }
            let bit23 = (size >> 1) & 1
            let mnemonic = bit23 == 0 ? (u == 0 ? "scvtf" : "ucvtf") : (u == 0 ? "frecpe" : "frsqrte")
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement)")
        case (_, 0x1b):
            guard let arrangement = fpArrangement() else { return unknownInstruction(address, bytes, word) }
            let bit23 = (size >> 1) & 1
            let mnemonic = bit23 == 0 ? (u == 0 ? "fcvtms" : "fcvtmu") : (u == 0 ? "fcvtzs" : "fcvtzu")
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement)")
        case (_, 0x18), (_, 0x19), (_, 0x1a), (_, 0x1c):
            guard let arrangement = fpArrangement() else { return unknownInstruction(address, bytes, word) }
            let bit23 = (size >> 1) & 1
            let mnemonic: String?
            switch (u, bit23, opcode) {
            case (0, 0, 0x18): mnemonic = "frintn"
            case (0, 1, 0x18): mnemonic = "frintp"
            case (1, 0, 0x18): mnemonic = "frinta"
            case (0, 0, 0x19): mnemonic = "frintm"
            case (0, 1, 0x19): mnemonic = "frintz"
            case (1, 0, 0x19): mnemonic = "frintx"
            case (1, 1, 0x19): mnemonic = "frinti"
            case (0, 0, 0x1a): mnemonic = "fcvtns"
            case (0, 1, 0x1a): mnemonic = "fcvtps"
            case (1, 0, 0x1a): mnemonic = "fcvtnu"
            case (1, 1, 0x1a): mnemonic = "fcvtpu"
            case (0, 0, 0x1c): mnemonic = "fcvtas"
            case (1, 0, 0x1c): mnemonic = "fcvtau"
            case (0, 1, 0x1c):
                guard (size & 1) == 0 else { return unknownInstruction(address, bytes, word) }
                mnemonic = "urecpe"
            case (1, 1, 0x1c):
                guard (size & 1) == 0 else { return unknownInstruction(address, bytes, word) }
                mnemonic = "ursqrte"
            default:
                mnemonic = nil
            }
            guard let mnemonic else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement)")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    func decodeSIMDShiftImmediate(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let immh = (word >> 19) & 0xf
        let immb = (word >> 16) & 0x7
        guard let size = simdShiftElementSizeIndex(immh: immh) else {
            return unknownInstruction(address, bytes, word)
        }
        let opcode = (word >> 11) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let elementBits = 8 << Int(size)
        let immediate = Int((immh << 3) | immb)

        func sameSize(_ mnemonic: String, shift: Int) -> DecodedInstruction {
            let arrangement = vectorArrangement(size: size, isQ: isQ)
            return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), v\(rn).\(arrangement), #\(formatImmediate(UInt64(shift)))")
        }

        switch opcode {
        case 0x00:
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = (elementBits * 2) - immediate
            guard shift > 0 && shift <= elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize(u == 0 ? "sshr" : "ushr", shift: shift)
        case 0x02:
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = (elementBits * 2) - immediate
            guard shift > 0 && shift <= elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize(u == 0 ? "ssra" : "usra", shift: shift)
        case 0x04:
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = (elementBits * 2) - immediate
            guard shift > 0 && shift <= elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize(u == 0 ? "srshr" : "urshr", shift: shift)
        case 0x06:
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = (elementBits * 2) - immediate
            guard shift > 0 && shift <= elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize(u == 0 ? "srsra" : "ursra", shift: shift)
        case 0x08:
            guard u == 1, !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = (elementBits * 2) - immediate
            guard shift > 0 && shift <= elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize("sri", shift: shift)
        case 0x0a:
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = immediate - elementBits
            guard shift >= 0 && shift < elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize(u == 0 ? "shl" : "sli", shift: shift)
        case 0x0c:
            guard u == 1, !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = immediate - elementBits
            guard shift >= 0 && shift < elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize("sqshlu", shift: shift)
        case 0x0e:
            guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
            let shift = immediate - elementBits
            guard shift >= 0 && shift < elementBits else { return unknownInstruction(address, bytes, word) }
            return sameSize(u == 0 ? "sqshl" : "uqshl", shift: shift)
        case 0x10...0x13:
            guard size < 3 else { return unknownInstruction(address, bytes, word) }
            let shift = (elementBits * 2) - immediate
            guard shift > 0 && shift <= elementBits else { return unknownInstruction(address, bytes, word) }
            let destinationArrangement = vectorArrangement(size: size, isQ: isQ)
            let sourceArrangement = vectorArrangement(size: size + 1, isQ: true)
            let base: String
            switch (u, opcode) {
            case (0, 0x10): base = "shrn"
            case (0, 0x11): base = "rshrn"
            case (1, 0x10): base = "sqshrun"
            case (1, 0x11): base = "sqrshrun"
            case (0, 0x12): base = "sqshrn"
            case (1, 0x12): base = "uqshrn"
            case (0, 0x13): base = "sqrshrn"
            case (1, 0x13): base = "uqrshrn"
            default: return unknownInstruction(address, bytes, word)
            }
            return instruction(address, bytes, isQ ? "\(base)2" : base, "v\(rd).\(destinationArrangement), v\(rn).\(sourceArrangement), #\(formatImmediate(UInt64(shift)))")
        case 0x14:
            guard size < 3 else { return unknownInstruction(address, bytes, word) }
            let shift = immediate - elementBits
            guard shift >= 0 && shift < elementBits else { return unknownInstruction(address, bytes, word) }
            let destinationArrangement = vectorArrangement(size: size + 1, isQ: true)
            let sourceArrangement = vectorArrangement(size: size, isQ: isQ)
            let mnemonic = (u == 0 ? "sshll" : "ushll") + (isQ ? "2" : "")
            return instruction(address, bytes, mnemonic, "v\(rd).\(destinationArrangement), v\(rn).\(sourceArrangement), #\(formatImmediate(UInt64(shift)))")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    func decodeSIMDAcrossLanes(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let u = (word >> 29) & 0x1
        let size = (word >> 22) & 0x3
        let opcode = (word >> 12) & 0x1f
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        guard size <= 2, size != 2 || isQ else { return unknownInstruction(address, bytes, word) }

        let sourceArrangement = vectorArrangement(size: size, isQ: isQ)
        func scalar(_ sizeIndex: UInt32) -> String {
            fpRegister(rd, sizeIndex: Int(sizeIndex))
        }

        let mnemonic: String
        let destination: String
        switch (u, opcode) {
        case (0, 0x1b):
            mnemonic = "addv"; destination = scalar(size)
        case (0, 0x1a):
            mnemonic = "sminv"; destination = scalar(size)
        case (1, 0x1a):
            mnemonic = "uminv"; destination = scalar(size)
        case (0, 0x0a):
            mnemonic = "smaxv"; destination = scalar(size)
        case (1, 0x0a):
            mnemonic = "umaxv"; destination = scalar(size)
        case (0, 0x03):
            mnemonic = "saddlv"; destination = scalar(size + 1)
        case (1, 0x03):
            mnemonic = "uaddlv"; destination = scalar(size + 1)
        default:
            return unknownInstruction(address, bytes, word)
        }

        return instruction(address, bytes, mnemonic, "\(destination), v\(rn).\(sourceArrangement)")
    }

    /// Advanced SIMD copy group. Decodes DUP (general/element), INS (general & element), and the
    /// UMOV/SMOV GPR-extract forms. The `op` bit (29) plus the `imm4` selector (14:11) pick the form;
    /// `imm5` carries the element size (its lowest set bit) and the destination lane index. INS's
    /// `op==1` (element) source lane comes from `imm4 >> size`. Rendered in canonical AArch64
    /// (`ins v0.s[1], w5`, `umov w0, v1.s[0]`), NOT otool's `mov`/`umov`-alias surface syntax. The
    /// per-form `Q`/size validity guards below are ground-truthed against `clang`+`otool`.
    func decodeSIMDCopy(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let op = (word >> 29) & 0x1
        let imm5 = (word >> 16) & 0x1f
        let imm4 = (word >> 11) & 0xf
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // The lowest set bit of imm5 selects the element size (b/h/s/d); the bits above are the index.
        let size: UInt32
        let index: UInt32
        if imm5 & 0x1 != 0 { size = 0; index = imm5 >> 1 }
        else if imm5 & 0x2 != 0 { size = 1; index = imm5 >> 2 }
        else if imm5 & 0x4 != 0 { size = 2; index = imm5 >> 3 }
        else if imm5 & 0x8 != 0 { size = 3; index = imm5 >> 4 }
        else { return unknownInstruction(address, bytes, word) }

        // A 64-bit (d) element requires Q=1 (a `.1d` vector is never a valid copy destination).
        guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
        let arrangement = vectorArrangement(size: size, isQ: isQ)
        let elem = ["b", "h", "s", "d"][Int(size)]

        // INS (element): op==1 is always element-insert. imm4 holds the SOURCE lane in its high bits,
        // so right-shift by the element scale. INS always encodes Q=1 (it touches the full 128 bits).
        if op == 1 {
            guard isQ else { return unknownInstruction(address, bytes, word) }
            let srcIndex = Int(imm4) >> Int(size)
            return instruction(address, bytes, "ins", "v\(rd).\(elem)[\(index)], v\(rn).\(elem)[\(srcIndex)]")
        }

        switch imm4 {
        case 0b0000:
            // DUP (element): replicate one element of Vn across every lane.
            return instruction(address, bytes, "dup", "v\(rd).\(arrangement), v\(rn).\(elem)[\(index)]")
        case 0b0001:
            // DUP (general): replicate a GPR across every lane (Xn for `.2d`, else Wn).
            return instruction(address, bytes, "dup", "v\(rd).\(arrangement), \(register(rn, is64Bit: size == 3))")
        case 0b0011:
            // INS (general): insert a GPR into one element (Xn for `.d`, else Wn). Q=1 always.
            guard isQ else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "ins", "v\(rd).\(elem)[\(index)], \(register(rn, is64Bit: size == 3))")
        case 0b0101:
            // SMOV: sign-extend an element into a GPR. Xd (Q=1) accepts b/h/s; Wd (Q=0) only b/h.
            guard size != 3, !(size == 2 && !isQ) else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "smov", "\(register(rd, is64Bit: isQ)), v\(rn).\(elem)[\(index)]")
        case 0b0111:
            // UMOV: zero-extend an element into a GPR. Q is the dest width and must equal (size==d).
            guard isQ == (size == 3) else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, "umov", "\(register(rd, is64Bit: size == 3)), v\(rn).\(elem)[\(index)]")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }
}

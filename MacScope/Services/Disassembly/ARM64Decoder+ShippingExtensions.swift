import Foundation

// MS-24: AArch64 families that ship in macOS 27 code (dyld shared cache + /Applications prevalence
// instruction-family scan). Every form
// here was `unknown` or misnamed before. The hook is called from ARM64Decoder.decode(word:...) right
// after the SME/SVE hook and returns nil for every word it does not fully decode, so all other
// dispatch is unchanged. Encodings are exact masks checked against Apple LLVM 21 in generic (ELF)
// syntax: Scripts/arm64_golden/generate_arm64_shipping_vectors.py.
extension ARM64Decoder {
    func decodeShippingExtension(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        // System-space names: PAC 1716 hints, BTI, SB, FlagM. Whole-word matches (op1 is fixed).
        if (word & 0xffc0_0000) == 0xd500_0000 {
            if let name = Self.shippingSystemNames[word] {
                let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
                return instruction(address, bytes, parts[0], parts.count > 1 ? parts[1] : "")
            }
            // SB and the FlagM PSTATE forms ignore CRm (LLVM decodes every CRm value to the same name).
            switch word & 0xffff_f0ff {
            case 0xd503_30ff: return instruction(address, bytes, "sb", "")
            case 0xd500_401f: return instruction(address, bytes, "cfinv", "")
            case 0xd500_403f: return instruction(address, bytes, "xaflag", "")
            case 0xd500_405f: return instruction(address, bytes, "axflag", "")
            default: break
            }
            // DC tag and cache maintenance: SYS #op1, C7, Cm, #op2, Xt (op0=0b01, L=0, CRn=7).
            if (word & 0xfff8_f000) == 0xd508_7000 {
                return decodeDataCacheOperation(word: word, bytes: bytes, address: address)
            }
            // MSR TCO, #imm (FEAT_MTE PSTATE.TCO: op1=3, CRn=4, op2=4). LLVM prints every CRm value.
            if (word & 0xffff_f0ff) == 0xd503_409f {
                return instruction(address, bytes, "msr", "TCO, #\(formatImmediate(UInt64((word >> 8) & 0xf)))")
            }
            // MRS/MSR (register) for the MTE and PAuth key system registers, spelled as LLVM prints them.
            if (word & 0xffd0_0000) == 0xd510_0000 {
                return decodeShippingSystemRegisterMove(word: word, bytes: bytes, address: address)
            }
            return nil
        }
        // FlagM RMIF Xn, #shift, #mask (sf=1, op=0, S=1, bits[14:10]=00001, o2=0). It must be dispatched
        // ahead of the load/store-register class, whose broad guard renders these words as a fabricated
        // `str` (ba1f842f -> `str w15, [x1], #-0x8`). The general class-mask fix is MS-23's.
        if (word & 0xffe0_7c10) == 0xba00_0400 {
            let rn = Int((word >> 5) & 0x1f), shift = UInt64((word >> 15) & 0x3f), mask = UInt64(word & 0xf)
            return instruction(
                address, bytes, "rmif",
                "\(register(rn, is64Bit: true)), #\(formatImmediate(shift)), #\(formatImmediate(mask))"
            )
        }
        // FlagM SETF8/SETF16 Wn (sf=0, S=1, sz = bit14, bits[13:10]=0010, o3=0, mask=1101).
        if (word & 0xffff_bc1f) == 0x3a00_080d {
            let name = (word & 0x0000_4000) != 0 ? "setf16" : "setf8"
            return instruction(address, bytes, name, register(Int((word >> 5) & 0x1f), is64Bit: false))
        }
        // CSSC CTZ/CNT/ABS (data-processing 1 source, opcode2=0, opcode 000110/000111/001000).
        switch word & 0x7fff_fc00 {
        case 0x5ac0_1800, 0x5ac0_1c00, 0x5ac0_2000:
            let is64Bit = (word & 0x8000_0000) != 0
            let name = ["ctz", "cnt", "abs"][Int((word >> 10) & 0xf) - 6]
            let rn = Int((word >> 5) & 0x1f), rd = Int(word & 0x1f)
            return instruction(address, bytes, name, "\(register(rd, is64Bit: is64Bit)), \(register(rn, is64Bit: is64Bit))")
        default:
            break
        }
        // LDRAA/LDRAB offset and pre-index forms (FEAT_PAuth).
        if (word & 0xff20_0400) == 0xf820_0400 {
            return decodeLoadRegisterAuthenticated(word: word, bytes: bytes, address: address)
        }
        // FJCVTZS Wd, Dn (FEAT_JSCVT). Writes Wd and NZCV.
        if (word & 0xffff_fc00) == 0x1e7e_0000 {
            let rn = Int((word >> 5) & 0x1f), rd = Int(word & 0x1f)
            return instruction(address, bytes, "fjcvtzs", "\(register(rd, is64Bit: false)), d\(rn)")
        }
        // CRC32{C}{B,H,W,X} (FEAT_CRC32): sf must be 1 exactly for the X (sz=11) forms.
        if (word & 0x7fe0_e000) == 0x1ac0_4000 {
            return decodeCRC32(word: word, bytes: bytes, address: address)
        }
        // CSSC SMAX/UMAX/SMIN/UMIN, register form.
        if (word & 0x7fe0_f000) == 0x1ac0_6000 {
            let is64Bit = (word & 0x8000_0000) != 0
            let rm = Int((word >> 16) & 0x1f), rn = Int((word >> 5) & 0x1f), rd = Int(word & 0x1f)
            let name = Self.csscMinMaxNames[Int((word >> 10) & 0x3)]
            return instruction(
                address, bytes, name,
                "\(register(rd, is64Bit: is64Bit)), \(register(rn, is64Bit: is64Bit)), \(register(rm, is64Bit: is64Bit))"
            )
        }
        // CSSC SMAX/UMAX/SMIN/UMIN, immediate form (opc bits[21:18] 0...3). It sits in the
        // add/sub-immediate-with-tags corridor (bit22=1), which ADDG/SUBG never use.
        if (word & 0x7fc0_0000) == 0x11c0_0000, (word >> 18) & 0xf < 4 {
            let is64Bit = (word & 0x8000_0000) != 0
            let opc = Int((word >> 18) & 0x3)
            let rn = Int((word >> 5) & 0x1f), rd = Int(word & 0x1f)
            let imm8 = Int((word >> 10) & 0xff)
            let immediate = opc & 1 == 0 ? formatSignedImmediate(signExtend(imm8, bitCount: 8)) : formatImmediate(UInt64(imm8))
            return instruction(
                address, bytes, Self.csscMinMaxNames[opc],
                "\(register(rd, is64Bit: is64Bit)), \(register(rn, is64Bit: is64Bit)), #\(immediate)"
            )
        }
        return decodeFP16MultiplyAccumulateLong(word: word, bytes: bytes, address: address)
    }

    /// Whole-word system names. HINT #8/#10/#12/#14 are the 1716 PAC forms (they print as `hint`
    /// otherwise), and HINT #32/#34/#36/#38 are BTI.
    static let shippingSystemNames: [UInt32: String] = [
        0xd503_211f: "pacia1716", 0xd503_215f: "pacib1716",
        0xd503_219f: "autia1716", 0xd503_21df: "autib1716",
        0xd503_241f: "bti", 0xd503_245f: "bti c", 0xd503_249f: "bti j", 0xd503_24df: "bti jc",
    ]

    private static let csscMinMaxNames = ["smax", "umax", "smin", "umin"]

    /// MTE and PAuth key system registers, keyed by o0:op1:CRn:CRm:op2 (word bits 19:5). LLVM spells
    /// them in this case; GMID_EL1 is read-only (a write prints as S3_1_C0_C0_4).
    private static let shippingSystemRegisters: [UInt32: String] = {
        func key(_ op0: UInt32, _ op1: UInt32, _ crn: UInt32, _ crm: UInt32, _ op2: UInt32) -> UInt32 {
            (op0 - 2) << 14 | op1 << 11 | crn << 7 | crm << 3 | op2
        }
        var table: [UInt32: String] = [
            key(3, 3, 4, 2, 7): "TCO", key(3, 0, 1, 0, 6): "GCR_EL1", key(3, 0, 1, 0, 5): "RGSR_EL1",
            key(3, 0, 5, 6, 0): "TFSR_EL1", key(3, 0, 5, 6, 1): "TFSRE0_EL1", key(3, 4, 5, 6, 0): "TFSR_EL2",
            key(3, 5, 5, 6, 0): "TFSR_EL12", key(3, 6, 5, 6, 0): "TFSR_EL3", key(3, 1, 0, 0, 4): "GMID_EL1",
        ]
        for (crm, key2) in [(1, ["APIA", "APIB"]), (2, ["APDA", "APDB"]), (3, ["APGA"])] {
            for (pair, prefix) in key2.enumerated() {
                table[key(3, 0, 2, UInt32(crm), UInt32(pair * 2))] = "\(prefix)KeyLo_EL1"
                table[key(3, 0, 2, UInt32(crm), UInt32(pair * 2 + 1))] = "\(prefix)KeyHi_EL1"
            }
        }
        return table
    }()

    private func decodeShippingSystemRegisterMove(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard let name = Self.shippingSystemRegisters[(word >> 5) & 0x7fff] else { return nil }
        let xt = register(Int(word & 0x1f), is64Bit: true)
        if (word & 0x0020_0000) != 0 { return instruction(address, bytes, "mrs", "\(xt), \(name)") }
        guard name != "GMID_EL1" else { return nil }
        return instruction(address, bytes, "msr", "\(name), \(xt)")
    }

    /// DC operations, keyed by op1 << 7 | CRm << 3 | op2 (CRn=7). Includes the FEAT_MTE tag forms
    /// (JavaScriptCore, libsystem_malloc) and the base cache-maintenance forms that share the space.
    private static let dataCacheOperations: [Int: String] = [
        0 << 7 | 6 << 3 | 1: "ivac", 0 << 7 | 6 << 3 | 2: "isw",
        0 << 7 | 6 << 3 | 3: "igvac", 0 << 7 | 6 << 3 | 4: "igsw",
        0 << 7 | 6 << 3 | 5: "igdvac", 0 << 7 | 6 << 3 | 6: "igdsw",
        0 << 7 | 10 << 3 | 2: "csw", 0 << 7 | 10 << 3 | 4: "cgsw", 0 << 7 | 10 << 3 | 6: "cgdsw",
        0 << 7 | 14 << 3 | 2: "cisw", 0 << 7 | 14 << 3 | 4: "cigsw", 0 << 7 | 14 << 3 | 6: "cigdsw",
        3 << 7 | 4 << 3 | 1: "zva", 3 << 7 | 4 << 3 | 3: "gva", 3 << 7 | 4 << 3 | 4: "gzva",
        3 << 7 | 10 << 3 | 1: "cvac", 3 << 7 | 10 << 3 | 3: "cgvac", 3 << 7 | 10 << 3 | 5: "cgdvac",
        3 << 7 | 11 << 3 | 1: "cvau",
        3 << 7 | 12 << 3 | 1: "cvap", 3 << 7 | 12 << 3 | 3: "cgvap", 3 << 7 | 12 << 3 | 5: "cgdvap",
        3 << 7 | 13 << 3 | 1: "cvadp", 3 << 7 | 13 << 3 | 3: "cgvadp", 3 << 7 | 13 << 3 | 5: "cgdvadp",
        3 << 7 | 14 << 3 | 1: "civac", 3 << 7 | 14 << 3 | 3: "cigvac", 3 << 7 | 14 << 3 | 5: "cigdvac",
    ]

    private func decodeDataCacheOperation(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let op1 = Int((word >> 16) & 0x7), crm = Int((word >> 8) & 0xf), op2 = Int((word >> 5) & 0x7)
        guard let name = Self.dataCacheOperations[op1 << 7 | crm << 3 | op2] else { return nil }
        return instruction(address, bytes, "dc", "\(name), \(register(Int(word & 0x1f), is64Bit: true))")
    }

    /// LDRAA/LDRAB Xt, [Xn|SP{, #simm}]{!}: M (bit23) picks key B, S:imm9 (bits 22, 20:12) is a
    /// signed doubleword offset, W (bit11) is pre-index writeback.
    private func decodeLoadRegisterAuthenticated(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let mnemonic = (word & 0x0080_0000) != 0 ? "ldrab" : "ldraa"
        let raw = Int((word >> 22) & 1) << 9 | Int((word >> 12) & 0x1ff)
        let offset = signExtend(raw, bitCount: 10) << 3
        let writeback = (word & 0x0000_0800) != 0
        let rt = register(Int(word & 0x1f), is64Bit: true)
        let base = register(Int((word >> 5) & 0x1f), is64Bit: true, useStackPointer: true)
        if writeback {
            return instruction(address, bytes, mnemonic, "\(rt), [\(base), #\(formatSignedImmediate(offset))]!")
        }
        let offsetText = offset == 0 ? "" : ", #\(formatSignedImmediate(offset))"
        return instruction(address, bytes, mnemonic, "\(rt), [\(base)\(offsetText)]")
    }

    private func decodeCRC32(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let sf = (word & 0x8000_0000) != 0
        let size = Int((word >> 10) & 0x3)
        guard sf == (size == 3) else { return nil }
        let castagnoli = (word & 0x0000_1000) != 0
        let mnemonic = (castagnoli ? "crc32c" : "crc32") + ["b", "h", "w", "x"][size]
        let rm = Int((word >> 16) & 0x1f), rn = Int((word >> 5) & 0x1f), rd = Int(word & 0x1f)
        return instruction(
            address, bytes, mnemonic,
            "\(register(rd, is64Bit: false)), \(register(rn, is64Bit: false)), \(register(rm, is64Bit: sf))"
        )
    }

    /// FEAT_FHM FMLAL/FMLSL/FMLAL2/FMLSL2, vector and by-element. Adapted from the research
    /// package's AdditionalAppleVectorDecode.swift (FHM part only; SME is RX-18's).
    private func decodeFP16MultiplyAccumulateLong(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let d = Int(word & 0x1f), n = Int((word >> 5) & 0x1f)
        let q = (word & 0x4000_0000) != 0
        let destination = q ? "4s" : "2s", source = q ? "4h" : "2h"
        switch word & 0xbfe0_fc00 {
        case 0x0e20_ec00, 0x0ea0_ec00, 0x2e20_cc00, 0x2ea0_cc00:
            let upper = (word & 0x2000_0000) != 0, subtract = (word & 0x0080_0000) != 0
            let name = (subtract ? "fmlsl" : "fmlal") + (upper ? "2" : "")
            let m = Int((word >> 16) & 0x1f)
            return instruction(address, bytes, name, "v\(d).\(destination), v\(n).\(source), v\(m).\(source)")
        default:
            break
        }
        let name: String
        switch word & 0xbfc0_f400 {
        case 0x0f80_0000: name = "fmlal"
        case 0x0f80_4000: name = "fmlsl"
        case 0x2f80_8000: name = "fmlal2"
        case 0x2f80_c000: name = "fmlsl2"
        default: return nil
        }
        let m = Int((word >> 16) & 0xf)
        let index = Int((word >> 11) & 1) << 2 | Int((word >> 21) & 1) << 1 | Int((word >> 20) & 1)
        return instruction(address, bytes, name, "v\(d).\(destination), v\(n).\(source), v\(m).h[\(index)]")
    }
}

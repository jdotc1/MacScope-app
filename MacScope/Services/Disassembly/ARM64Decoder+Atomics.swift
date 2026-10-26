import Foundation

extension ARM64Decoder {
    /// Decodes the ARMv8.1 LSE atomic read-modify-write instructions. These
    /// include ldadd, ldclr, ldeor, ldset, ldsmax, ldsmin, ldumax, ldumin, and
    /// swp, along with their acquire/release (`a`/`l`/`al`) and size (`b`/`h`)
    /// suffixes. When the result register `Rt` is XZR/WZR, the ld* mnemonics
    /// alias to st* (store-only) forms; swp has no store alias. Unsupported
    /// opcodes fall through to `unknown`.
    ///
    /// - Parameters:
    ///   - word: The 32‑bit instruction word.
    ///   - bytes: The original little‑endian encoding of this instruction.
    ///   - address: The program counter of this instruction.
    func decodeLSEAtomic(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        // Size field (bits31:30): 0=byte, 1=half, 2=word, 3=dword.
        let size = Int((word >> 30) & 0x3)
        // Acquire (A) and Release (R) flags at bits23,22.
        let aFlag = ((word >> 23) & 0x1) != 0
        let rFlag = ((word >> 22) & 0x1) != 0
        // Source register Rs (bits20:16), destination/result register Rt (bits4:0),
        // and address register Rn (bits9:5).
        let rs = Int((word >> 16) & 0x1f)
        let opc = Int((word >> 10) & 0x3f)
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)

        // Determine the base mnemonic from the opc field.
        let base: String
        switch opc {
        case 0b000000: base = "ldadd"
        case 0b000100: base = "ldclr"
        case 0b001000: base = "ldeor"
        case 0b001100: base = "ldset"
        case 0b010000: base = "ldsmax"
        case 0b010100: base = "ldsmin"
        case 0b011000: base = "ldumax"
        case 0b011100: base = "ldumin"
        case 0b100000: base = "swp"
        default:
            return unknownInstruction(address, bytes, word)
        }

        // Determine Acquire/Release suffix.
        let arSuffix: String
        switch (aFlag, rFlag) {
        case (false, false): arSuffix = ""
        case (true, false): arSuffix = "a"
        case (false, true): arSuffix = "l"
        default: arSuffix = "al"
        }

        // Determine size suffix for byte/half; no suffix for word/dword.
        let sizeSuffix: String
        switch size {
        case 0: sizeSuffix = "b"
        case 1: sizeSuffix = "h"
        default: sizeSuffix = ""
        }

        // Choose the register width: 64-bit for size==3; otherwise 32-bit (w).
        let is64 = (size == 3)
        let rsName = register(rs, is64Bit: is64)
        let rtName = register(rt, is64Bit: is64)
        // The atomic address base is [Xn|SP] — Rn==31 is the stack pointer, never XZR.
        let rnName = register(rn, is64Bit: true, useStackPointer: true)

        // Build the mnemonic with suffixes. The order is base + arSuffix + sizeSuffix.
        var mnemonic = base
        if !arSuffix.isEmpty { mnemonic += arSuffix }
        if !sizeSuffix.isEmpty { mnemonic += sizeSuffix }

        // Store aliases apply when Rt is zero (WZR/XZR), the base is not swp, and the form has
        // no acquire (A = bit23 = 0): `ldclrah w19, wzr, [x27]` has no ST alias.
        var operands: String
        var actualMnemonic = mnemonic
        if base != "swp" && rt == 31 && !aFlag {
            // Convert ld* to st* by replacing the ld prefix with st.
            let dropPrefix = base.dropFirst(2) // remove "ld"
            actualMnemonic = "st" + dropPrefix + arSuffix + sizeSuffix
            operands = "\(rsName), [\(rnName)]"
        } else {
            operands = "\(rsName), \(rtName), [\(rnName)]"
        }

        return instruction(address, bytes, actualMnemonic, operands)
    }

    /// Decode compare-and-swap (CAS) and compare-and-swap pair (CASP). Returns nil for the OTHER
    /// load/store-exclusive instructions that share the bits[29:24]=0x08 space (ldxr/stxr/ldar/stlr/
    /// ldxp/stxp) so they are not mis-decoded as CAS — they fall through and stay `unknown`.
    /// Load/store exclusive + ordered (ARM C3.2.6):
    /// `size(2) 001000 o2 L(load) o1(pair) Rs(5) o0 Rt2(5) Rn(5) Rt(5)`.
    /// Covers the non-CAS family; returns nil for any word it can't recognize so a malformed
    /// encoding stays `unknown` rather than mis-decoding. Rn is the base (SP-capable); Rt/Rt2 are
    /// W for byte/half/word and X only for the doubleword size; the exclusive-store status Rs (Ws)
    /// is always 32-bit.
    func decodeLoadStoreExclusive(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let size = (word >> 30) & 0x3
        let ordered = (word >> 23) & 0x1   // o2: 1 = ordered non-exclusive (ldar/stlr/…)
        let load = (word >> 22) & 0x1      // L
        let pair = (word >> 21) & 0x1      // o1
        let rs = Int((word >> 16) & 0x1f)
        let acquireRelease = (word >> 15) & 0x1  // o0
        let rt2 = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let rtIs64 = size == 3

        let sizeSuffix: String
        switch size {
        case 0: sizeSuffix = "b"
        case 1: sizeSuffix = "h"
        default: sizeSuffix = ""
        }

        if ordered == 1 {
            // ldar/stlr/ldlar/stllr: non-pair, with fixed Rs and Rt2 (both 11111).
            guard pair == 0, rs == 0x1f, rt2 == 0x1f else { return nil }
            let mnemonic: String
            switch (load, acquireRelease) {
            case (0, 0): mnemonic = "stllr"
            case (0, 1): mnemonic = "stlr"
            case (1, 0): mnemonic = "ldlar"
            default:     mnemonic = "ldar"
            }
            return instruction(address, bytes, mnemonic + sizeSuffix,
                               "\(register(rt, is64Bit: rtIs64)), [\(base)]")
        }

        if pair == 0 {
            // Exclusive single: ldxr/stxr/ldaxr/stlxr. Rt2 fixed 11111.
            guard rt2 == 0x1f else { return nil }
            if load == 1 {
                guard rs == 0x1f else { return nil }
                let mnemonic = (acquireRelease == 1 ? "ldaxr" : "ldxr") + sizeSuffix
                return instruction(address, bytes, mnemonic, "\(register(rt, is64Bit: rtIs64)), [\(base)]")
            }
            let mnemonic = (acquireRelease == 1 ? "stlxr" : "stxr") + sizeSuffix
            return instruction(address, bytes, mnemonic,
                               "\(register(rs, is64Bit: false)), \(register(rt, is64Bit: rtIs64)), [\(base)]")
        }

        // Exclusive pair: ldxp/stxp/ldaxp/stlxp. Only the word/doubleword sizes are valid.
        guard size >= 2 else { return nil }
        let pairIs64 = size == 3
        if load == 1 {
            guard rs == 0x1f else { return nil }
            let mnemonic = acquireRelease == 1 ? "ldaxp" : "ldxp"
            return instruction(address, bytes, mnemonic,
                               "\(register(rt, is64Bit: pairIs64)), \(register(rt2, is64Bit: pairIs64)), [\(base)]")
        }
        let mnemonic = acquireRelease == 1 ? "stlxp" : "stxp"
        return instruction(address, bytes, mnemonic,
                           "\(register(rs, is64Bit: false)), \(register(rt, is64Bit: pairIs64)), \(register(rt2, is64Bit: pairIs64)), [\(base)]")
    }

    func decodeCAS(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        // The exclusive family is selected by o2 (bit23) and o1 (bit21). Only o1==1 forms are
        // CAS/CASP/LDXP/STXP; CAS proper additionally has o2==1. ldxr/stxr/ldar/stlr have o1==0;
        // ldxp/stxp have o1==1,o2==0 but bit31==1 (CASP has bit31==0). Reject all non-CAS forms.
        let o2 = (word >> 23) & 0x1
        let o1 = (word >> 21) & 0x1
        guard o1 == 1 else { return nil }

        let acquireFlag = ((word >> 22) & 0x1) != 0   // L
        let releaseFlag = ((word >> 15) & 0x1) != 0   // o0
        let rn = Int((word >> 5) & 0x1f)
        let base = register(rn, is64Bit: true, useStackPointer: true)
        let arSuffix: String
        switch (acquireFlag, releaseFlag) {
        case (false, false): arSuffix = ""
        case (true, false): arSuffix = "a"
        case (false, true): arSuffix = "l"
        default: arSuffix = "al"
        }

        if o2 == 0 {
            // CASP (pair): bit31 must be 0 (else this is ldxp/stxp, which we do not decode).
            guard ((word >> 31) & 0x1) == 0 else { return nil }
            // The fixed Rt2 field (bits[14:10]) is 11111, as for CAS.
            guard ((word >> 10) & 0x1f) == 0x1f else { return nil }
            let is64 = ((word >> 30) & 0x1) != 0
            let rt = Int(word & 0x1f)
            let rs = Int((word >> 16) & 0x1f)
            guard (rt & 1) == 0, (rs & 1) == 0 else { return nil }   // pair registers must be even
            let rsName1 = register(rs, is64Bit: is64)
            let rsName2 = register((rs + 1) & 0x1f, is64Bit: is64)
            let rtName1 = register(rt, is64Bit: is64)
            let rtName2 = register((rt + 1) & 0x1f, is64Bit: is64)
            return instruction(address, bytes, "casp" + arSuffix, "\(rsName1), \(rsName2), \(rtName1), \(rtName2), [\(base)]")
        }

        // CAS (non-pair): o2==1, and the fixed Rt2 field (bits[14:10]) is 11111.
        guard ((word >> 10) & 0x1f) == 0x1f else { return nil }
        let size = Int((word >> 30) & 0x3)
        let sizeSuffix: String
        let is64: Bool
        switch size {
        case 0: sizeSuffix = "b"; is64 = false
        case 1: sizeSuffix = "h"; is64 = false
        case 2: sizeSuffix = ""; is64 = false
        default: sizeSuffix = ""; is64 = true
        }
        let rs = Int((word >> 16) & 0x1f)
        let rt = Int(word & 0x1f)
        // Suffix order is base + acquire/release + size (casalb, not casbal) — matching otool and the
        // existing LSE decoder.
        return instruction(address, bytes, "cas" + arSuffix + sizeSuffix, "\(register(rs, is64Bit: is64)), \(register(rt, is64Bit: is64)), [\(base)]")
    }
}

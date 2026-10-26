import Foundation

extension ARM64Decoder {
    func decodeCryptoAES(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        guard (word & 0xffff_cc00) == 0x4e28_4800 else {
            return unknownInstruction(address, bytes, word)
        }
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        let mnemonic: String
        switch (word >> 12) & 0x3 {
        case 0: mnemonic = "aese"
        case 1: mnemonic = "aesd"
        case 2: mnemonic = "aesmc"
        default: mnemonic = "aesimc"
        }
        return instruction(address, bytes, mnemonic, "v\(rd).16b, v\(rn).16b")
    }

    func decodeCryptoSHA(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let rm = Int((word >> 16) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        if (word & 0xffe0_0c00) == 0x5e00_0000 {
            switch (word >> 12) & 0xf {
            case 0x0:
                return instruction(address, bytes, "sha1c", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 2)), v\(rm).4s")
            case 0x1:
                return instruction(address, bytes, "sha1p", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 2)), v\(rm).4s")
            case 0x2:
                return instruction(address, bytes, "sha1m", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 2)), v\(rm).4s")
            case 0x3:
                return instruction(address, bytes, "sha1su0", threeVector(rd, rn, rm, "4s"))
            case 0x4:
                return instruction(address, bytes, "sha256h", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 4)), v\(rm).4s")
            case 0x5:
                return instruction(address, bytes, "sha256h2", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 4)), v\(rm).4s")
            case 0x6:
                return instruction(address, bytes, "sha256su1", threeVector(rd, rn, rm, "4s"))
            default:
                return unknownInstruction(address, bytes, word)
            }
        }

        if (word & 0xff3f_cc00) == 0x5e28_0800 {
            // SHA two-register forms fix size[23:22] to zero.
            guard (word & 0x00c0_0000) == 0 else { return unknownInstruction(address, bytes, word) }
            switch (word >> 12) & 0xf {
            case 0x0:
                return instruction(address, bytes, "sha1h", "\(fpRegister(rd, sizeIndex: 2)), \(fpRegister(rn, sizeIndex: 2))")
            case 0x1:
                return instruction(address, bytes, "sha1su1", "v\(rd).4s, v\(rn).4s")
            case 0x2:
                return instruction(address, bytes, "sha256su0", "v\(rd).4s, v\(rn).4s")
            default:
                return unknownInstruction(address, bytes, word)
            }
        }

        return unknownInstruction(address, bytes, word)
    }

    func decodeCryptoThreeReg512(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let rm = Int((word >> 16) & 0x1f)
        let ra = Int((word >> 10) & 0x1f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // Cryptographic four-register (SHA3): EOR3 (Op0=000) / BCAX (Op0=001). bit15=0 is the only
        // fixed field below bits[20:16]; `Ra` occupies bits[14:10], so the dispatch must NOT constrain
        // bits[11:10] (those are Ra[1:0] — constraining them mis-rejects every Ra whose low bits ≠ the
        // pattern, which dropped most bcax encodings).
        if (word & 0xffe0_8000) == 0xce00_0000 {
            return instruction(address, bytes, "eor3", "v\(rd).16b, v\(rn).16b, v\(rm).16b, v\(ra).16b")
        }
        if (word & 0xffe0_8000) == 0xce20_0000 {
            return instruction(address, bytes, "bcax", "v\(rd).16b, v\(rn).16b, v\(rm).16b, v\(ra).16b")
        }
        if (word & 0xffe0_8000) == 0xce40_0000 {
            return instruction(address, bytes, "sm3ss1", "v\(rd).4s, v\(rn).4s, v\(rm).4s, v\(ra).4s")
        }

        // SM3TT indexed three-register forms. bit14 must remain zero; the bit14=1 half is reserved.
        if (word & 0xffe0_c000) == 0xce40_8000 {
            let imm2 = (word >> 12) & 0x3
            let mnemonic: String
            switch (word >> 10) & 0x3 {
            case 0x0: mnemonic = "sm3tt1a"
            case 0x1: mnemonic = "sm3tt1b"
            case 0x2: mnemonic = "sm3tt2a"
            default: mnemonic = "sm3tt2b"
            }
            return instruction(address, bytes, mnemonic, "v\(rd).4s, v\(rn).4s, v\(rm).s[\(imm2)]")
        }

        // XAR (SHA3 two-register, rotate-by-imm6). bits[31:21]=11001110100; imm6 is bits[15:10].
        if (word & 0xffe0_0000) == 0xce80_0000 {
            let imm6 = (word >> 10) & 0x3f
            return instruction(address, bytes, "xar", "v\(rd).2d, v\(rn).2d, v\(rm).2d, #\(formatImmediate(UInt64(imm6)))")
        }

        if (word & 0xffff_fc00) == 0xcec0_8000 {
            return instruction(address, bytes, "sha512su0", "v\(rd).2d, v\(rn).2d")
        }
        if (word & 0xffff_fc00) == 0xcec0_8400 {
            return instruction(address, bytes, "sm4e", "v\(rd).4s, v\(rn).4s")
        }

        if (word & 0xffe0_0000) == 0xce60_0000 {
            switch (word >> 10) & 0x3f {
            case 0x20:
                return instruction(address, bytes, "sha512h", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 4)), v\(rm).2d")
            case 0x21:
                return instruction(address, bytes, "sha512h2", "\(fpRegister(rd, sizeIndex: 4)), \(fpRegister(rn, sizeIndex: 4)), v\(rm).2d")
            case 0x22:
                return instruction(address, bytes, "sha512su1", threeVector(rd, rn, rm, "2d"))
            case 0x23:
                return instruction(address, bytes, "rax1", threeVector(rd, rn, rm, "2d"))
            case 0x30:
                return instruction(address, bytes, "sm3partw1", threeVector(rd, rn, rm, "4s"))
            case 0x31:
                return instruction(address, bytes, "sm3partw2", threeVector(rd, rn, rm, "4s"))
            case 0x32:
                return instruction(address, bytes, "sm4ekey", threeVector(rd, rn, rm, "4s"))
            default:
                return unknownInstruction(address, bytes, word)
            }
        }

        return unknownInstruction(address, bytes, word)
    }
}

import Foundation

extension ARM64Decoder {
    /// Replicates each bit of imm8 to a byte (AdvSIMDExpandImm, cmode=1110 op=1).
    private func advSIMDExpandByteMask(_ imm8: Int) -> UInt64 {
        var value: UInt64 = 0
        for bit in 0..<8 where (imm8 & (1 << bit)) != 0 {
            value |= UInt64(0xff) << UInt64(bit * 8)
        }
        return value
    }

    /// VFPExpandImm has the same exact value in single and double precision.
    /// Keep the scalar FMOV decoder's fixed-eight-fractional-digit spelling.
    private func simdFloatingPointImmediateText(_ imm8: Int) -> String {
        let sign = (imm8 >> 7) & 0x1
        let bit6 = (imm8 >> 6) & 0x1
        let expLow = (imm8 >> 4) & 0x3
        let fraction = imm8 & 0xf
        let exponent = bit6 == 1 ? (expLow - 3) : (expLow + 1)
        var value = (1.0 + Double(fraction) / 16.0) * pow(2.0, Double(exponent))
        if sign == 1 { value = -value }
        return "#" + String(format: "%.8f", value)
    }

    func decodeSIMDModifiedImmediate(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        // The modified-immediate encoding requires o2 (bit 11) to be zero.
        guard word & 0x0000_0800 == 0 else { return unknownInstruction(address, bytes, word) }
        let isQ = (word & 0x4000_0000) != 0
        let op = (word >> 29) & 0x1
        let cmode = (word >> 12) & 0xf
        let abc = Int((word >> 16) & 0x7)
        let defgh = Int((word >> 5) & 0x1f)
        let imm8 = (abc << 5) | defgh
        let rd = Int(word & 0x1f)
        let mnemonic = op == 0 ? "movi" : "mvni"

        // cmode 1111: floating-point immediate. The double-precision form
        // requires Q=1; o2=1 half-precision forms remain outside this decoder.
        if cmode == 0b1111 {
            guard op == 0 || isQ else { return unknownInstruction(address, bytes, word) }
            let arrangement = op == 1 ? "2d" : (isQ ? "4s" : "2s")
            return instruction(address, bytes, "fmov", "v\(rd).\(arrangement), \(simdFloatingPointImmediateText(imm8))")
        }

        // cmode 1110: per-byte movi, or a 64-bit byte mask in Dd / Vd.2d when op=1.
        if cmode == 0b1110 {
            if op == 1 {
                let destination = isQ ? "v\(rd).2d" : "d\(rd)"
                return instruction(address, bytes, "movi", "\(destination), #\(formatImmediate(advSIMDExpandByteMask(imm8)))")
            }
            return instruction(address, bytes, "movi", "v\(rd).\(isQ ? "16b" : "8b"), #\(formatImmediate(UInt64(imm8)))")
        }

        // cmode 110x fills low bits with ones after shifting the 8-bit immediate.
        if (cmode & 0b1110) == 0b1100 {
            let shift = (cmode & 1) == 0 ? 8 : 16
            return instruction(address, bytes, mnemonic, "v\(rd).\(isQ ? "4s" : "2s"), #\(formatImmediate(UInt64(imm8))), msl #\(shift)")
        }

        // Odd cmodes 0xx1 and 10x1 modify the destination with ORR/BIC.
        // The adjacent even-cmode MOVI/MVNI paths below remain unchanged.
        if (cmode & 0b1001) == 0b0001 || (cmode & 0b1101) == 0b1001 {
            let isHalfword = (cmode & 0b1000) != 0
            let arrangement = isHalfword ? (isQ ? "8h" : "4h") : (isQ ? "4s" : "2s")
            let shift = Int((cmode >> 1) & (isHalfword ? 0x1 : 0x3)) * 8
            let shiftSuffix = shift == 0 ? "" : ", lsl #\(shift)"
            let logicalMnemonic = op == 0 ? "orr" : "bic"
            return instruction(address, bytes, logicalMnemonic, "v\(rd).\(arrangement), #\(formatImmediate(UInt64(imm8)))\(shiftSuffix)")
        }

        let arrangement: String
        let shift: Int
        if (cmode & 0b1001) == 0b0000 { // 0xx0 -> 32-bit
            arrangement = isQ ? "4s" : "2s"
            shift = Int((cmode >> 1) & 0x3) * 8
        } else if (cmode & 0b1101) == 0b1000 { // 10x0 -> 16-bit
            arrangement = isQ ? "8h" : "4h"
            shift = Int((cmode >> 1) & 0x1) * 8
        } else {
            return unknownInstruction(address, bytes, word)
        }
        let shiftSuffix = shift == 0 ? "" : ", lsl #\(shift)"
        return instruction(address, bytes, mnemonic, "v\(rd).\(arrangement), #\(formatImmediate(UInt64(imm8)))\(shiftSuffix)")
    }

    /// Advanced SIMD table lookup. Decodes the TBL and TBX instructions which
    /// perform byte-wise table lookups from one to four 128-bit table
    /// registers. The Q bit chooses the destination and index register
    /// arrangement (.8b or .16b), the len field encodes the number of table
    /// registers minus one, and the op bit selects between `tbl` and `tbx`.
    ///
    /// - Parameters:
    ///   - word: The 32-bit machine instruction.
    ///   - bytes: The original little-endian encoding of this instruction.
    ///   - address: The program counter of this instruction.
    func decodeSIMDTableLookup(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let rm = Int((word >> 16) & 0x1f)
        let len = Int((word >> 13) & 0x3)
        let op = (word >> 12) & 0x1
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // Destination and index register arrangement: .8b when Q=0, .16b when Q=1.
        let destArr = vectorArrangement(size: 0, isQ: isQ)
        let dest = "v\(rd).\(destArr)"
        let index = "v\(rm).\(destArr)"
        // Table registers always use .16b arrangement.
        let tableArr = vectorArrangement(size: 0, isQ: true)
        var tables: [String] = []
        for i in 0...len {
            let reg = (rn + i) & 0x1f
            tables.append("v\(reg).\(tableArr)")
        }
        let tableList = "{\(tables.joined(separator: ", "))}"
        let mnemonic = op == 0 ? "tbl" : "tbx"
        return instruction(address, bytes, mnemonic, "\(dest), \(tableList), \(index)")
    }

    /// Advanced SIMD extract. Decodes the EXT instruction which extracts a
    /// contiguous byte range from the concatenation of two vectors. The Q bit
    /// selects .8b vs .16b; imm4 encodes the byte index. When Q=0 only the
    /// low three bits of imm4 are valid (indices 0–7); other encodings are
    /// reserved and are treated as unknown.
    ///
    /// - Parameters:
    ///   - word: The 32-bit machine instruction.
    ///   - bytes: The original little-endian encoding of this instruction.
    ///   - address: The program counter of this instruction.
    func decodeSIMDExt(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let rm = Int((word >> 16) & 0x1f)
        let imm4 = Int((word >> 11) & 0xf)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        // When Q=0 the high bit of imm4 must be zero (indices 0–7 only).
        if !isQ && (imm4 & 0x8) != 0 {
            return unknownInstruction(address, bytes, word)
        }
        let index = isQ ? imm4 : (imm4 & 0x7)
        let arr = vectorArrangement(size: 0, isQ: isQ)
        let dest = "v\(rd).\(arr)"
        let src1 = "v\(rn).\(arr)"
        let src2 = "v\(rm).\(arr)"
        return instruction(address, bytes, "ext", "\(dest), \(src1), \(src2), #\(index)")
    }

    /// Advanced SIMD permutations: ZIP1/ZIP2, UZP1/UZP2, TRN1/TRN2. These
    /// instructions interleave or deinterleave elements from two source
    /// vectors and write to a destination vector. The Q bit selects
    /// 8-byte vs 16-byte elements, the `size` field selects the element
    /// width (b/h/s/d), and a 6-bit opcode determines the operation. A
    /// combination of size=3 and Q=0 is reserved and treated as unknown.
    func decodeSIMDZipPermute(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isQ = (word & 0x4000_0000) != 0
        let size = (word >> 22) & 0x3
        let rm = Int((word >> 16) & 0x1f)
        let opcode = Int((word >> 10) & 0x3f)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)

        // size=3 with Q=0 is reserved for zip/uzp/trn (a .1d permute does not exist) — reject it
        // explicitly rather than mislabel it as `.1d`. (vectorArrangement returns "1d" for that case,
        // so the previous `arrangement.isEmpty` guard never fired.)
        guard !(size == 3 && !isQ) else { return unknownInstruction(address, bytes, word) }
        let arrangement = vectorArrangement(size: size, isQ: isQ)

        let mnemonic: String
        switch opcode {
        case 0x0e: mnemonic = "zip1"
        case 0x1e: mnemonic = "zip2"
        case 0x06: mnemonic = "uzp1"
        case 0x16: mnemonic = "uzp2"
        case 0x0a: mnemonic = "trn1"
        case 0x1a: mnemonic = "trn2"
        default:
            return unknownInstruction(address, bytes, word)
        }
        return instruction(address, bytes, mnemonic, threeVector(rd, rn, rm, arrangement))
    }
}

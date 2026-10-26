import Foundation

extension ARM64Decoder {
    // MARK: - FEAT_MOPS memory copy / memory set

    /// FEAT_MOPS CPYF*/CPY* (memory copy) and SET*/SETG* (memory set). Encoding
    /// `sz=00 011 o0 01 op1 0 Rs op2 01 Rn Rd` (mask 0xfb20_0c00 == 0x1900_0400): o0 (bit26)
    /// selects CPYF/SET (0) or CPY/SETG (1); op1 (bits[23:22]) is the copy stage
    /// (prologue/main/epilogue) or 0b11 for the set family, whose stage then lives in op2[3:2].
    /// Copies render `[Xd]!, [Xs]!, Xn!` with the read/write option suffixes from op2; sets render
    /// `[Xd]!, Xn!, Xs`. Returns nil, like LLVM, for aliased registers, a destination of 31, a copy
    /// source of 31, and the reserved set stage, so the caller keeps its fall-through decode.
    func decodeMemoryOperation(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isSecondVariant = (word >> 26) & 0x1 == 1
        let op1 = Int((word >> 22) & 0x3)
        let rs = Int((word >> 16) & 0x1f)
        let op2 = Int((word >> 12) & 0xf)
        let rn = Int((word >> 5) & 0x1f)
        let rd = Int(word & 0x1f)
        guard rd != 31, rd != rs, rd != rn, rs != rn else { return nil }
        let stages = ["p", "m", "e"]

        if op1 != 0b11 {
            guard rs != 31 else { return nil }
            let readOption = ["", "wt", "rt", "t"][op2 & 0x3]
            let writeOption = ["", "wn", "rn", "n"][op2 >> 2]
            let mnemonic = (isSecondVariant ? "cpy" : "cpyf") + stages[op1] + readOption + writeOption
            let operands = "[\(register(rd, is64Bit: true))]!, [\(register(rs, is64Bit: true))]!, "
                + "\(register(rn, is64Bit: true))!"
            return instruction(address, bytes, mnemonic, operands)
        }

        let stage = op2 >> 2
        guard stage < stages.count else { return nil }
        let option = ["", "t", "n", "tn"][op2 & 0x3]
        let mnemonic = (isSecondVariant ? "setg" : "set") + stages[stage] + option
        let operands = "[\(register(rd, is64Bit: true))]!, \(register(rn, is64Bit: true))!, "
            + register(rs, is64Bit: true)
        return instruction(address, bytes, mnemonic, operands)
    }
}

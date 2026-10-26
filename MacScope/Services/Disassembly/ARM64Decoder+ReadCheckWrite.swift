import Foundation

extension ARM64Decoder {
    // MARK: - FEAT_THE read-check-write atomics

    /// Acquire/release suffix from A (bit23) and R (bit22): "", "l", "a", "al".
    private func readCheckWriteOrdering(_ word: UInt32) -> String {
        ["", "l", "a", "al"][Int((word >> 22) & 0x3)]
    }

    /// FEAT_THE compare-and-swap and D128 pair forms in the 0x19/0x59 space:
    /// `0 S 011001 A R 1 Rs opc Rn Rt` (mask 0xbf20_0000 == 0x1920_0000). bit21=1 keeps the group
    /// disjoint from LDAPUR/STLUR (bit21=0). opc (bits[15:10]) selects RCW[S]CAS (000010),
    /// RCW[S]CASP (000011, even Rs/Rt register pairs) and the FEAT_D128 RCW[S]CLRP/SWPP/SETP
    /// (100100/101000/101100, Rt and Rt2=Rs not 31). Returns nil for every other opc and for the
    /// register combinations LLVM rejects, so the caller keeps its fall-through decode.
    func decodeReadCheckWriteCompareAndSwap(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let isSoft = (word >> 30) & 0x1 == 1
        let rs = Int((word >> 16) & 0x1f)
        let opc = (word >> 10) & 0x3f
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let prefix = isSoft ? "rcws" : "rcw"
        let ordering = readCheckWriteOrdering(word)
        let base = "[\(register(rn, is64Bit: true, useStackPointer: true))]"

        switch opc {
        case 0b000010:
            let operands = "\(register(rs, is64Bit: true)), \(register(rt, is64Bit: true)), \(base)"
            return instruction(address, bytes, prefix + "cas" + ordering, operands)
        case 0b000011:
            guard rs % 2 == 0, rt % 2 == 0 else { return nil }
            let operands = "\(register(rs, is64Bit: true)), \(register(rs + 1, is64Bit: true)), "
                + "\(register(rt, is64Bit: true)), \(register(rt + 1, is64Bit: true)), \(base)"
            return instruction(address, bytes, prefix + "casp" + ordering, operands)
        case 0b100100, 0b101000, 0b101100:
            guard rt != 31, rs != 31 else { return nil }
            let operation = opc == 0b100100 ? "clr" : (opc == 0b101000 ? "swp" : "set")
            let operands = "\(register(rt, is64Bit: true)), \(register(rs, is64Bit: true)), \(base)"
            return instruction(address, bytes, prefix + operation + "p" + ordering, operands)
        default:
            return nil
        }
    }

    /// FEAT_THE RCW[S]CLR / RCW[S]SWP / RCW[S]SET in the LSE atomic space:
    /// `0 S 111000 A R 1 Rs 1 opc 00 Rn Rt` with opc 001/010/011 (bits[15:10] =
    /// 100100/101000/101100). Always 64-bit `Xs, Xt, [Xn|SP]`.
    func decodeReadCheckWriteAtomic(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let isSoft = (word >> 30) & 0x1 == 1
        let rs = Int((word >> 16) & 0x1f)
        let opc = (word >> 10) & 0x3f
        let rn = Int((word >> 5) & 0x1f)
        let rt = Int(word & 0x1f)
        let operation = opc == 0b100100 ? "clr" : (opc == 0b101000 ? "swp" : "set")
        let mnemonic = (isSoft ? "rcws" : "rcw") + operation + readCheckWriteOrdering(word)
        let operands = "\(register(rs, is64Bit: true)), \(register(rt, is64Bit: true)), "
            + "[\(register(rn, is64Bit: true, useStackPointer: true))]"
        return instruction(address, bytes, mnemonic, operands)
    }
}

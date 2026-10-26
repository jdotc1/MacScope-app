import Foundation

// RX-18: only fully decoded forms claim a word; all others keep existing dispatch.
extension ARM64Decoder {
    func decodeScalableMatrixExtension(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        let d = Int(word & 31)
        let n = Int((word >> 5) & 31)
        if word & 0xffff_f800 == 0x04bf_5800 {
            let raw = Int((word >> 5) & 63)
            let imm = raw >= 32 ? raw - 64 : raw
            let rd = d == 31 ? "xzr" : "x\(d)"
            return instruction(address, bytes, "rdsvl", "\(rd), #\(imm)")
        }

        // Array-vector context load/store. Bit 21 selects store.
        if word & 0xffdf_9c10 == 0xe100_0000 {
            let selector = 12 + Int((word >> 13) & 3)
            let offset = Int(word & 15)
            let base = n == 31 ? "sp" : "x\(n)"
            let mem = offset == 0 ? "[\(base)]" : "[\(base), #\(offset), mul vl]"
            return instruction(address, bytes, word & 0x0020_0000 == 0 ? "ldr" : "str", "za[w\(selector), \(offset)], \(mem)")
        }

        if word & 0xffdf_fc1f == 0xe11f_8000 {
            let base = n == 31 ? "sp" : "x\(n)"
            return instruction(address, bytes, word & 0x0020_0000 == 0 ? "ldr" : "str", "zt0, [\(base)]")
        }

        // One observed widening FMOPA/FMOPS class, not all matrix forms.
        if word & 0xffe0_000c == 0x81a0_0000 {
            let za = Int(word & 3)
            let pn = Int((word >> 10) & 7)
            let pm = Int((word >> 13) & 7)
            let m = Int((word >> 16) & 31)
            return instruction(address, bytes, word & 16 == 0 ? "fmopa" : "fmops", "za\(za).s, p\(pn)/m, p\(pm)/m, z\(n).h, z\(m).h")
        }

        // Single-destination SME2 LUTI2. Size 11 is unallocated.
        if word & 0xfffc_0c00 == 0xc0cc_0000 {
            let size = Int((word >> 12) & 3)
            guard size < 3 else { return nil }
            let suffix = ["b", "h", "s"][size]
            let index = Int((word >> 14) & 15)
            return instruction(address, bytes, "luti2", "z\(d).\(suffix), zt0, z\(n)[\(index)]")
        }

        // Alias spelling for MSR SVCR; the mask-zero form is not this family.
        if word & 0xffff_f8ff == 0xd503_407f {
            let mode = Int((word >> 9) & 3)
            guard mode != 0 else { return nil }
            let enabled = word & 0x100 != 0
            let operand = mode == 1 ? "sm" : mode == 2 ? "za" : ""
            return instruction(address, bytes, enabled ? "smstart" : "smstop", operand)
        }
        // All 256 tile masks are allocated; the all-tiles alias is canonical.
        if word & 0xffff_ff00 == 0xc008_0000 {
            let mask = word & 255
            let tiles: String
            if mask == 255 {
                tiles = "za"
            } else if mask == 0x55 || mask == 0xaa {
                tiles = mask == 0x55 ? "za0.h" : "za1.h"
            } else if mask != 0 && (mask & 15) == (mask >> 4) {
                tiles = (0..<4).filter { mask & (1 << $0) != 0 }.map { "za\($0).s" }.joined(separator: ",")
            } else {
                tiles = (0..<8).filter { mask & (1 << $0) != 0 }.map { "za\($0).d" }.joined(separator: ", ")
            }
            return instruction(address, bytes, "zero", "{\(tiles)}")
        }
        return decodeScalableVectorExtension(word: word, bytes: bytes, address: address)
    }
}

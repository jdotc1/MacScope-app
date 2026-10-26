import Foundation

// Streaming-compatible classes measured in Accelerate. Unsupported classes return nil.
extension ARM64Decoder {
    func decodeScalableVectorExtension(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction? {
        guard word & 0x1e00_0000 == 0x0400_0000 else { return nil }
        let d = Int(word & 31)
        let n = Int((word >> 5) & 31)
        let m = Int((word >> 16) & 31)
        let size = Int((word >> 22) & 3)
        let suffix = ["b", "h", "s", "d"][size]
        if word & 0xff3f_fc10 == 0x2518_e000 {
            let pattern = Int((word >> 5) & 31)
            let names = [0: "pow2", 1: "vl1", 2: "vl2", 3: "vl3", 4: "vl4", 5: "vl5", 6: "vl6", 7: "vl7", 8: "vl8", 9: "vl16", 10: "vl32", 11: "vl64", 12: "vl128", 13: "vl256", 29: "mul4", 30: "mul3", 31: "all"]
            guard let patternName = names[pattern] else { return nil }
            let operand = "p\(d).\(suffix)" + (pattern == 31 ? "" : ", \(patternName)")
            return instruction(address, bytes, "ptrue", operand)
        }
        let whileOpcode = word & 0xff20_ec10
        let whileNames: [UInt32: String] = [0x2520_0400: "whilelt", 0x2520_0c00: "whilelo", 0x2520_0010: "whilegt"]
        if let name = whileNames[whileOpcode] {
            let is64 = word & 0x1000 != 0
            return instruction(address, bytes, name, "p\(d & 15).\(suffix), \(register(n, is64Bit: is64)), \(register(m, is64Bit: is64))")
        }
        let fpOpcode = word & 0xff20_fc00
        let fpNames: [UInt32: String] = [0x6500_0000: "fadd", 0x6500_0400: "fsub", 0x6500_0800: "fmul"]
        if let name = fpNames[fpOpcode], size != 0 {
            return instruction(address, bytes, name, "z\(d).\(suffix), z\(n).\(suffix), z\(m).\(suffix)")
        }
        if word & 0xff20_fc00 == 0x0520_3000 {
            return instruction(address, bytes, "tbl", "z\(d).\(suffix), { z\(n).\(suffix) }, z\(m).\(suffix)")
        }
        if word & 0xff3f_ffe0 == 0x2538_c000 {
            return instruction(address, bytes, "mov", "z\(d).\(suffix), #0x0")
        }
        let memoryOpcode = word & 0xfff0_e000
        if memoryOpcode == 0xa540_a000 || memoryOpcode == 0xe540_e000 {
            let load = memoryOpcode == 0xa540_a000
            let predicate = Int((word >> 10) & 7)
            let rawOffset = Int((word >> 16) & 15)
            let offset = rawOffset >= 8 ? rawOffset - 16 : rawOffset
            let base = n == 31 ? "sp" : "x\(n)"
            let memory = offset == 0 ? "[\(base)]" : "[\(base), #\(offset), mul vl]"
            return instruction(address, bytes, load ? "ld1w" : "st1w", "{ z\(d).s }, p\(predicate)\(load ? "/z" : ""), \(memory)")
        }
        return nil
    }
}

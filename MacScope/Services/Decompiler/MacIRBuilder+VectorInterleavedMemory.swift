import Foundation

extension MacIRBuilder {
    struct NEONInterleavedOperands {
        let effect: MacIRNEONBufferMemory.Effect
        let activeBytes: Int
        let elementBytes: Int
        let structureCount: Int
        let vectors: [String]
        let base: String
        let postIndex: Bool
        let incrementRegister: String?
    }

    struct NEONStructureLaneOperands {
        let effect: MacIRNEONBufferMemory.Effect
        let elementBytes: Int
        let laneIndex: Int
        let structureCount: Int
        let vectors: [String]
        let base: String
        let postIndex: Bool
        let incrementRegister: String?
    }

    static func encodedNEONInterleavedMemory<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        guard let word = neonBufferSequenceWord(row) else { return false }
        // Multiple-structure encoding only. The complete parser below owns
        // reserved opcodes and fields; rejected rows still poison their writes.
        return word & 0xbf00_0000 == 0x0c00_0000
    }

    static func encodedNEONStructureLaneMemory<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        guard let word = neonBufferSequenceWord(row) else { return false }
        return word & 0xbf00_0000 == 0x0d00_0000
    }

    static func neonInterleavedMemory<Row: DecompilerInstructionRow>(_ row: Row) -> NEONInterleavedOperands? {
        guard row.operands.utf8.count <= 160, let word = neonBufferSequenceWord(row),
              encodedNEONInterleavedMemory(row) else { return nil }
        let q = word & 0x4000_0000 != 0
        let load = word & 0x0040_0000 != 0
        let post = word & 0x0080_0000 != 0
        let opcode = Int((word >> 12) & 15)
        let size = Int((word >> 10) & 3)
        let base = Int((word >> 5) & 31)
        let first = Int(word & 31)
        let rm = Int((word >> 16) & 31)
        let active = q ? 16 : 8
        guard post || rm == 0 else { return nil }
        let structureCount: Int
        let registerCount: Int
        switch opcode {
        case 0: structureCount = 4; registerCount = 4
        case 2: structureCount = 1; registerCount = 4
        case 4: structureCount = 3; registerCount = 3
        case 6: structureCount = 1; registerCount = 3
        case 7: structureCount = 1; registerCount = 1
        case 8: structureCount = 2; registerCount = 2
        case 10: structureCount = 1; registerCount = 2
        default: return nil
        }
        guard !(size == 3 && !q && structureCount != 1) else { return nil }
        let elementBytes = 1 << size
        let suffix = ["b", "h", "s", "d"][size]
        let arrangement = "\(active / elementBytes)\(suffix)"
        let mnemonic = "\(load ? "ld" : "st")\(structureCount)"
        guard row.mnemonic.lowercased() == mnemonic else { return nil }
        let exact = UInt32(0x0c00_0000) | (q ? 0x4000_0000 : 0)
            | (load ? 0x0040_0000 : 0) | (post ? 0x0080_0000 : 0)
            | UInt32(rm << 16)
            | UInt32(opcode << 12) | UInt32(size << 10)
            | UInt32(base << 5) | UInt32(first)
        guard word == exact else { return nil }
        let vectors = (0..<registerCount).map { "v\((first + $0) % 32)" }
        let list = vectors.map { "\($0).\(arrangement)" }.joined(separator: ", ")
        let baseName = base == 31 ? "sp" : "x\(base)"
        let increment = post && rm != 31 ? "x\(rm)" : nil
        let expected = "{\(list)}, [\(baseName)]" + (post ? ", \(increment ?? "#\(active * registerCount)")" : "")
        let typed = typedStructureOperandsMatch(
            row, vectorIndices: (0..<registerCount).map { (first + $0) % 32 }, elementBits: elementBytes * 8,
            vectorBits: active * 8, lane: nil, base: base, postIndex: post,
            incrementRegister: post && rm != 31 ? rm : nil, immediateStride: active * registerCount)
        guard typed || row.operands == expected else { return nil }
        return .init(effect: load ? .load : .store, activeBytes: active,
                     elementBytes: elementBytes, structureCount: structureCount,
                     vectors: vectors, base: baseName, postIndex: post,
                     incrementRegister: increment)
    }

    static func neonStructureLaneMemory<Row: DecompilerInstructionRow>(_ row: Row) -> NEONStructureLaneOperands? {
        guard row.operands.utf8.count <= 160, let word = neonBufferSequenceWord(row),
              encodedNEONStructureLaneMemory(row) else { return nil }
        let q = word & 0x4000_0000 != 0
        let load = word & 0x0040_0000 != 0
        let post = word & 0x0080_0000 != 0
        let r = Int((word >> 21) & 1)
        let opcode = Int((word >> 13) & 7)
        let scale = opcode >> 1
        let count = ((opcode & 1) << 1 | r) + 1
        let s = Int((word >> 12) & 1)
        let size = Int((word >> 10) & 3)
        let base = Int((word >> 5) & 31)
        let first = Int(word & 31)
        let rm = Int((word >> 16) & 31)
        // Keep the established LD4/ST3 forms, including SP and register
        // post-index. New ST1/ST2/ST4 stores use an ordinary X base and
        // either no writeback or the encoding's fixed immediate stride.
        // LD1 H selects two bytes, not a Q-width transfer. Keep all other
        // new load counts, element sizes and SP bases outside this admission.
        let singleHalfwordLoad = load && count == 1 && scale == 1 && size & 1 == 0 && base < 31
        guard (load && (count == 4 || singleHalfwordLoad) || !load),
              load || count == 3 || (base < 31 && (!post || rm == 31)),
              post || rm == 0 else { return nil }
        let elementLog2: Int
        let lane: Int
        switch scale {
        case 0:
            elementLog2 = 0; lane = (q ? 8 : 0) | (s << 2) | size
        case 1:
            guard size & 1 == 0 else { return nil }
            elementLog2 = 1; lane = (q ? 4 : 0) | (s << 1) | (size >> 1)
        case 2:
            guard size & 2 == 0 else { return nil }
            if size & 1 == 0 {
                elementLog2 = 2; lane = (q ? 2 : 0) | s
            } else {
                guard s == 0 else { return nil }
                elementLog2 = 3; lane = q ? 1 : 0
            }
        default: return nil
        }
        let exact = UInt32(0x0d00_0000) | (q ? 0x4000_0000 : 0)
            | (load ? 0x0040_0000 : 0) | (post ? 0x0080_0000 : 0)
            | UInt32(r << 21) | UInt32(rm << 16) | UInt32(opcode << 13)
            | UInt32(s << 12) | UInt32(size << 10) | UInt32(base << 5) | UInt32(first)
        guard word == exact else { return nil }
        let vectors = (0..<count).map { "v\((first + $0) % 32)" }
        let suffix = ["b", "h", "s", "d"][elementLog2]
        let list = vectors.map { "\($0).\(suffix)" }.joined(separator: ", ")
        let baseName = base == 31 ? "sp" : "x\(base)"
        let increment = post && rm != 31 ? "x\(rm)" : nil
        let expected = "{\(list)}[\(lane)], [\(baseName)]"
            + (post ? ", \(increment ?? "#\((1 << elementLog2) * count)")" : "")
        let typed = typedStructureOperandsMatch(
            row, vectorIndices: (0..<count).map { (first + $0) % 32 }, elementBits: (1 << elementLog2) * 8,
            vectorBits: nil, lane: lane, base: base, postIndex: post,
            incrementRegister: post && rm != 31 ? rm : nil, immediateStride: (1 << elementLog2) * count)
        guard row.mnemonic.lowercased() == "\(load ? "ld" : "st")\(count)",
              typed || row.operands == expected else { return nil }
        return .init(effect: load ? .load : .store, elementBytes: 1 << elementLog2,
                     laneIndex: lane, structureCount: count, vectors: vectors,
                     base: baseName, postIndex: post, incrementRegister: increment)
    }
}

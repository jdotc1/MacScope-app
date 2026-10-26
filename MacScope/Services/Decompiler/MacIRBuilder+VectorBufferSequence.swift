import Foundation

extension MacIRBuilder {
    struct NEONBufferSequenceOperands {
        let effect: MacIRNEONBufferMemory.Effect
        let mode: MacIRNEONBufferSequence.Mode
        let delta: Int64
        let base: String
        let vectors: [String]
    }
    static func neonBufferSequenceWord<Row: DecompilerInstructionRow>(_ row: Row) -> UInt32? {
        let tokens = row.bytes.split(separator: " ")
        guard tokens.count == 4 else { return nil }
        var word: UInt32 = 0
        for (i, token) in tokens.enumerated() {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
            word |= UInt32(byte) << (i * 8)
        }
        return word
    }
    /// Recognize new-family bytes even when text is missing or misleading. Such
    /// a row must never fall through to31's deliberately text-only base parser.
    static func encodedNEONBufferSequence<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        guard let word = neonBufferSequenceWord(row) else { return false }
        if word & 0xfe000000 == 0xac000000 { return true }
        let mode = (word >> 10) & 3
        return word & 0xffa00000 == 0x3c800000 && (mode == 1 || mode == 3)
    }
    /// Parse only exact decoder-supported Q encodings. Require byte/text
    /// agreement rather than promoting an arbitrary textual pair/writeback.
    static func neonBufferSequence<Row: DecompilerInstructionRow>(_ row: Row) -> NEONBufferSequenceOperands? {
        guard let word = neonBufferSequenceWord(row) else { return nil }
        let n = Int((word >> 5) & 31), t = Int(word & 31)
        guard n < 31 else { return nil }
        let load = word & 0x00400000 != 0
        let mode: MacIRNEONBufferSequence.Mode, delta: Int64, vectors: [String], mnemonic: String
        if word & 0xfe000000 == 0xac000000 {
            switch (word >> 23) & 3 {
            case 1: mode = .postIndex
            case 2: mode = .offset
            case 3: mode = .preIndex
            default: return nil // LDNP/STNP are separate, unqualified families.
            }
            let raw = Int64((word >> 15) & 127)
            delta = (raw >= 64 ? raw - 128 : raw) * 16
            let t2 = Int((word >> 10) & 31)
            guard !load || t != t2 else { return nil }
            vectors = ["q\(t)", "q\(t2)"]; mnemonic = load ? "ldp" : "stp"
        } else if word & 0xffa00000 == 0x3c800000 {
            switch (word >> 10) & 3 {
            case 1: mode = .postIndex
            case 3: mode = .preIndex
            default: return nil
            }
            let raw = Int64((word >> 12) & 511)
            delta = raw >= 256 ? raw - 512 : raw
            vectors = ["q\(t)"]; mnemonic = load ? "ldr" : "str"
        } else { return nil }
        let immediate = delta < 0 ? "-0x" + String(-delta, radix: 16)
            : (delta < 10 ? String(delta) : "0x" + String(delta, radix: 16))
        let base = "x\(n)", address: String
        switch mode {
        case .offset: address = "[\(base)" + (delta == 0 ? "" : ", #\(immediate)") + "]"
        case .preIndex: address = "[\(base), #\(immediate)]!"
        case .postIndex: address = "[\(base)], #\(immediate)"
        }
        guard row.mnemonic.lowercased() == mnemonic,
              row.operands == vectors.joined(separator: ", ") + ", " + address else { return nil }
        return .init(effect: load ? .load : .store, mode: mode, delta: delta, base: base, vectors: vectors)
    }
    static func liftNEONBufferSequence(_ parsed: NEONBufferSequenceOperands, source: MacIRSourceSpan,
                                      firstMemorySequence: Int, state: inout BuilderState) -> [MacIRInstruction] {
        var staged = state
        let oldBase = staged.readRegister(parsed.base)
        // Capture all paired store sources before any destination/base definition.
        let sources = parsed.effect == .store ? parsed.vectors.map { staged.readRegister($0) } : []
        let vectors = parsed.effect == .load ? parsed.vectors.map { staged.writeRegister($0) } : sources
        let newBase = parsed.mode == .offset ? nil : staged.writeRegister(parsed.base)
        guard let sequence = MacIRNEONBufferSequence(effect: parsed.effect, mode: parsed.mode, delta: parsed.delta,
            baseRegister: parsed.base, oldBase: oldBase, vectors: vectors, baseDestination: newBase,
            firstMemorySequence: firstMemorySequence) else {
            return [.init(source: source, operation: .unknown(destination: nil, mnemonic: source.mnemonic, operands: source.operands))]
        }
        state = staged
        return (0..<sequence.effectCount).map { ordinal in
            MacIRInstruction(source: source, operation: sequence.operation(ordinal),
                memoryAccess: ordinal < vectors.count ? .init(byteWidth: 16) : nil,
                neonBufferMemory: ordinal < vectors.count ? sequence.memory(ordinal) : nil,
                neonBufferSequence: .init(sequence: sequence, ordinal: ordinal))
        }
    }
}

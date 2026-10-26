import Foundation

extension BuilderState {
    /// Only enabled after whole-function admission of this exact buffer route.
    /// S/D/B/H and every other path retain their original spelling/ownership.
    func neonBufferCarrier(_ name: String) -> String {
        // The general region plan admits B/H/S/D views only in memory rows and
        // FMOV, so they name the low bytes of the same vN register.
        if permitsNEONScalarViewCarrier, let first = name.first, "bhsd".contains(first),
           let index = Int(name.dropFirst()), (0...31).contains(index), name == "\(first)\(index)" {
            return "v\(index)"
        }
        guard permitsNEONBufferCarrier, let first = name.first, first == "q" || first == "v",
              let index = Int(name.dropFirst()), (0...31).contains(index),
              name == "\(first)\(index)" else { return name }
        return "v\(index)"
    }
}

extension MacIRBuilder {
    static func bitViewRegister(_ name: String, prefixes: String, maximum: Int) -> Int? {
        guard let prefix = name.first, prefixes.contains(prefix),
              let index = Int(name.dropFirst()), (0...maximum).contains(index),
              name == "\(prefix)\(index)" else { return nil }
        return index
    }

    static func hasUnclaimedVectorOperand(_ operands: String) -> Bool {
        operands.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { token in
                guard let prefix = token.first, prefix == "q" || prefix == "v",
                      let index = Int(token.dropFirst()) else { return false }
                return (0...31).contains(index)
            }
    }

    static func bitViewGPR(_ name: String, width: Int) -> Int? {
        let prefix = width == 32 ? "w" : "x"
        if name == prefix + "zr" { return 31 }
        guard name.hasPrefix(prefix), let index = Int(name.dropFirst()),
              (0...30).contains(index), name == "\(prefix)\(index)" else { return nil }
        return index
    }
}

extension BuilderState {
    /// This is not a global overlap lattice. Only32's entire admitted, memory-
    /// free straight-line function shares S/D/Q/V through the existing vN SSA.
    func neonBitViewCarrier(_ name: String) -> String {
        guard permitsNEONBitViewCarrier, let index = MacIRBuilder.bitViewRegister(name, prefixes: "sdqv", maximum: 31) else { return name }
        return "v\(index)"
    }
}


extension MacIRBuilder {
    struct ScalarADDVCarrier {
        let destination: String
        let source: String
        let semantics: MacIRNEONReduction
    }

    /// Integer reductions write a zero-extended physical V value.
    /// Share the byte/text gate with SSA, not a mnemonic allowlist.
    static func integerReductionCarrier(word: UInt32, mnemonic: String,
                                        operandText: String) -> ScalarADDVCarrier? {
        let mnemonic = mnemonic.lowercased()
        let operands = splitOperands(operandText).map { $0.lowercased() }
        let destination = Int(word & 31), source = Int((word >> 5) & 31)
        let kind: MacIRNEONReduction.Kind
        if mnemonic == "addv", word & 0xbf3ffc00 == 0x0e31b800 {
            kind = .addv
        } else if mnemonic == "umaxv", word & 0xfffffc00 == 0x6eb0a800 {
            kind = .umaxv
        } else { return nil }
        let size = Int((word >> 22) & 3)
        let bytes = word & 0x40000000 == 0 ? 8 : 16
        guard size < 3, size != 2 || bytes == 16 else { return nil }
        let bits = 8 << size
        let suffix = ["b", "h", "s"][size]
        guard operands == ["\(suffix)\(destination)", "v\(source).\(bytes * 8 / bits)\(suffix)"],
              let semantics = MacIRNEONReduction(kind: kind, elementBits: bits,
                                                 activeBytes: bytes) else { return nil }
        return .init(destination: "v\(destination)", source: "v\(source)", semantics: semantics)
    }

    static func scalarADDVCarrier<Row: DecompilerInstructionRow>(_ row: Row) -> ScalarADDVCarrier? {
        guard let word = neonBufferSequenceWord(row),
              let carrier = integerReductionCarrier(word: word, mnemonic: row.mnemonic,
                  operandText: row.operands), !carrier.semantics.isExtraction else { return nil }
        return carrier
    }
}

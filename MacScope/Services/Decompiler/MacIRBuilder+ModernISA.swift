import Foundation

// Register and flag effects of the AArch64 families MS-22/MS-24 taught the
// decoder: FEAT_PAuth_LR and the PAC 1716 hints, FEAT_MOPS, FEAT_THE RCW,
// LDRAA/LDRAB, FJCVTZS and CRC32, plus the LSE SWP / LD<op> / CAS / CASP write
// sets. Everything here is stateless classification; MacIRBuilder applies it.
// Spellings follow ARM64Decoder+PointerAuth/+MemoryOperations/+ReadCheckWrite/
// +ShippingExtensions/+System exactly.
extension MacIRBuilder {
    /// PAC mnemonics lifted through the value-transparent PAC intrinsic path
    /// (`.intrinsic(destination: nil, name:, arguments: [])`), alongside the
    /// older `pacibsp`/`autiasp`/... list in the main lift switch.
    static let modernTransparentPACIntrinsicNames: Set<String> = [
        // FEAT_PAuth_LR
        "paciasppc", "pacibsppc", "pacnbiasppc", "pacnbibsppc",
        "autiasppc", "autibsppc", "autiasppcr", "autibsppcr",
        "pacm",
        "pacia171615", "pacib171615", "autia171615", "autib171615",
        // PAC 1716 hint forms
        "pacia1716", "pacib1716", "autia1716", "autib1716",
    ]

    /// Registers a transparent PAC intrinsic still writes. The 1716 and
    /// 171615 forms sign or authenticate x17 in place; the SP/PC forms only
    /// touch LR, which the older `paciasp` family already treats as
    /// value-transparent. `autiasppcr`/`autibsppcr xN` READ xN.
    static func modernPACRegisterWrites(mnemonic: String) -> [String] {
        mnemonic.hasSuffix("1716") || mnemonic.hasSuffix("171615") ? ["x17"] : []
    }

    // MARK: - FEAT_MOPS

    enum MemoryOperationStage { case prologue, main, epilogue }

    /// Every MOPS spelling the decoder emits, with its copy/set kind and stage:
    /// `cpyf|cpy` + `p|m|e` + read option + write option, and
    /// `set|setg` + `p|m|e` + `""|t|n|tn`.
    static let memoryOperationMnemonics: [String: (isCopy: Bool, stage: MemoryOperationStage)] = {
        var table: [String: (isCopy: Bool, stage: MemoryOperationStage)] = [:]
        let stages: [(String, MemoryOperationStage)] = [("p", .prologue), ("m", .main), ("e", .epilogue)]
        for family in ["cpyf", "cpy"] {
            for (letter, stage) in stages {
                for readOption in ["", "wt", "rt", "t"] {
                    for writeOption in ["", "wn", "rn", "n"] {
                        table[family + letter + readOption + writeOption] = (true, stage)
                    }
                }
            }
        }
        for family in ["set", "setg"] {
            for (letter, stage) in stages {
                for option in ["", "t", "n", "tn"] {
                    table[family + letter + option] = (false, stage)
                }
            }
        }
        return table
    }()

    static func isMemoryOperationMnemonic(_ mnemonic: String) -> Bool {
        memoryOperationMnemonics[mnemonic] != nil
    }

    /// Copies render `[Xd]!, [Xs]!, Xn!` and write all three; sets render
    /// `[Xd]!, Xn!, Xs` and write Xd and Xn (Xs is the fill value, a read).
    private static func memoryOperationWrites(isCopy: Bool, operands: [String]) -> [String] {
        let written = isCopy ? operands.prefix(3) : operands.prefix(2)
        return written.compactMap(writebackOperandRegister)
    }

    /// `[xN]!`, `[xN]` or `xN!` → `xN`.
    private static func writebackOperandRegister(_ operand: String) -> String? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix("!") { normalized.removeLast() }
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return memoryBaseRegister(normalized)
    }

    // MARK: - FEAT_THE RCW

    enum ReadCheckWriteKind { case compareAndSwap, compareAndSwapPair, single, pair }

    /// `rcw|rcws` + `cas|casp|clr|swp|set|clrp|swpp|setp` + `""|a|al|l`.
    static let readCheckWriteMnemonics: [String: ReadCheckWriteKind] = {
        var table: [String: ReadCheckWriteKind] = [:]
        let operations: [(String, ReadCheckWriteKind)] = [
            ("cas", .compareAndSwap), ("casp", .compareAndSwapPair),
            ("clr", .single), ("swp", .single), ("set", .single),
            ("clrp", .pair), ("swpp", .pair), ("setp", .pair),
        ]
        for prefix in ["rcw", "rcws"] {
            for (operation, kind) in operations {
                for ordering in ["", "a", "al", "l"] {
                    table[prefix + operation + ordering] = kind
                }
            }
        }
        return table
    }()

    static func isReadCheckWriteMnemonic(_ mnemonic: String) -> Bool {
        readCheckWriteMnemonics[mnemonic] != nil
    }

    // MARK: - Write sets

    /// Registers definitely written by the families above, or nil when the
    /// mnemonic is not one of them (the caller keeps its generic fallback).
    /// - RCW: CAS → Xs; CASP → Xs, Xs+1; CLR/SWP/SET → Xt (Xs is read);
    ///   the D128 `*p` forms → Xt1, Xt2.
    /// - LSE: SWP / LD<op> → Xt; CAS → Xs; CASP → Xs, Xs+1; the LSE128
    ///   SWPP / LDCLRP / LDSETP → Xt1, Xt2.
    /// - MOPS: see `memoryOperationWrites`.
    /// - LDRAA/LDRAB → Xt, plus the base when pre-indexed.
    /// - FJCVTZS and CRC32/CRC32C → Wd.
    static func modernISARegisterWrites(mnemonic: String, operands: [String]) -> [String]? {
        if let kind = readCheckWriteMnemonics[mnemonic] {
            switch kind {
            case .compareAndSwap, .single:
                guard operands.count == 3 else { return [] }
                return scalarRegisterWrites(kind == .compareAndSwap ? [operands[0]] : [operands[1]])
            case .compareAndSwapPair:
                guard operands.count == 5 else { return [] }
                return scalarRegisterWrites(Array(operands.prefix(2)))
            case .pair:
                guard operands.count == 3 else { return [] }
                return scalarRegisterWrites(Array(operands.prefix(2)))
            }
        }
        if let operation = memoryOperationMnemonics[mnemonic] {
            return memoryOperationWrites(isCopy: operation.isCopy, operands: operands)
        }
        if let writes = atomicRegisterWrites(mnemonic: mnemonic, operands: operands) {
            return writes
        }
        switch mnemonic {
        case "ldraa", "ldrab":
            guard operands.count == 2 else { return [] }
            var writes = scalarRegisterWrites([operands[0]])
            if let base = explicitMemoryWritebackBase(operands: operands) {
                writes.append(base)
            }
            return writes
        case "fjcvtzs",
             "crc32b", "crc32h", "crc32w", "crc32x",
             "crc32cb", "crc32ch", "crc32cw", "crc32cx":
            guard let destination = operands.first else { return [] }
            return scalarRegisterWrites([destination])
        default:
            return nil
        }
    }

    private static let atomicLoadOperationPrefixes = [
        "ldadd", "ldclr", "ldeor", "ldset",
        "ldsmax", "ldsmin", "ldumax", "ldumin",
    ]

    private static func atomicRegisterWrites(mnemonic: String, operands: [String]) -> [String]? {
        if mnemonic.hasPrefix("swpp") || mnemonic.hasPrefix("ldclrp") || mnemonic.hasPrefix("ldsetp") {
            guard operands.count == 3 else { return [] }
            return scalarRegisterWrites(Array(operands.prefix(2)))
        }
        if mnemonic.hasPrefix("casp") {
            guard operands.count == 5 else { return [] }
            return scalarRegisterWrites(Array(operands.prefix(2)))
        }
        if mnemonic.hasPrefix("cas") {
            guard operands.count == 3 else { return [] }
            return scalarRegisterWrites([operands[0]])
        }
        if mnemonic.hasPrefix("swp") || atomicLoadOperationPrefixes.contains(where: mnemonic.hasPrefix) {
            guard operands.count == 3 else { return [] }
            return scalarRegisterWrites([operands[1]])
        }
        return nil
    }

    /// Lower-cased scalar GPR spellings, dropping the zero register (a
    /// discarded result is not a write).
    private static func scalarRegisterWrites(_ operands: [String]) -> [String] {
        operands.compactMap { operand in
            let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isScalarGPRRegister(normalized), !isZeroRegister(normalized) else { return nil }
            return normalized
        }
    }

    // MARK: - NZCV

    /// NZCV writers among the families above: every RCW form (the check
    /// reports its result in the flags), the MOPS prologue phases (they pick
    /// the algorithm option in NZCV) and FJCVTZS (Z reports an exact result).
    static func isModernISANZCVWriter(_ mnemonic: String) -> Bool {
        if mnemonic == "fjcvtzs" || readCheckWriteMnemonics[mnemonic] != nil {
            return true
        }
        return memoryOperationMnemonics[mnemonic]?.stage == .prologue
    }
}

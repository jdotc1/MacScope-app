import Foundation

/// Rewrites the direct target of a branch/call row (`bl 0x100000a04`) to the name the workspace
/// knows for that address (`bl _objc_msgSend$alpha`, `bl _printf`, `bl sub_100003f00`).
///
/// The decoders render direct targets as raw hex, and nothing downstream substituted names: the
/// listing drew `row.operands` verbatim, and MacIR's printer only names a callee when the operand
/// already IS a symbol. Stub/import symbols (`StubCallSymbolicator`) therefore only labelled the
/// stub addresses themselves, which are not in the disassembled `__text` stream.
///
/// Pure and `Sendable`. Only the trailing operand is replaced, and only when it parses as a
/// hexadecimal address with a known name, so register/memory operands are never touched.
struct BranchTargetSymbolizer: Sendable {
    let namesByAddress: [UInt64: String]

    init(namesByAddress: [UInt64: String]) {
        self.namesByAddress = namesByAddress
    }

    /// Returning-call mnemonics (ARM64 `bl`, x86-64 `call`). Pseudocode symbolizes only these so
    /// intra-function branch targets stay addresses that MacIR's structurer can resolve.
    static let callMnemonics: Set<String> = ["bl", "call", "callq"]
    /// Direct-branch mnemonics whose last operand is a code address.
    static let branchMnemonics: Set<String> = [
        "b", "cbz", "cbnz", "tbz", "tbnz", "jmp", "jmpq",
    ]

    static func isDirectBranchOrCall(_ mnemonic: String) -> Bool {
        let m = mnemonic.lowercased()
        if callMnemonics.contains(m) || branchMnemonics.contains(m) { return true }
        if m.hasPrefix("b.") { return true }                       // ARM64 b.cond
        if m.count >= 2, m.first == "j" { return true }             // x86 jcc
        return false
    }

    /// The operands with a named trailing target substituted, or nil when nothing applies.
    func symbolizedOperands(mnemonic: String, operands: String, callsOnly: Bool) -> String? {
        let m = mnemonic.lowercased()
        guard callsOnly ? Self.callMnemonics.contains(m) : Self.isDirectBranchOrCall(m) else { return nil }
        let separator = operands.lastIndex(of: ",")
        let tokenStart = separator.map { operands.index(after: $0) } ?? operands.startIndex
        let token = operands[tokenStart...].trimmingCharacters(in: .whitespaces)
        guard let address = Self.parseHexAddress(token),
              let name = namesByAddress[address], !name.isEmpty else { return nil }
        let prefix = separator.map { String(operands[...$0]) + " " } ?? ""
        return prefix + name
    }

    /// Returns `row` with its trailing direct target symbolized (unchanged when nothing applies).
    func symbolized(_ row: InstructionRow, callsOnly: Bool) -> InstructionRow {
        guard let operands = symbolizedOperands(mnemonic: row.mnemonic, operands: row.operands, callsOnly: callsOnly) else {
            return row
        }
        var copy = row
        copy.operands = operands
        return copy
    }

    static func parseHexAddress(_ token: String) -> UInt64? {
        var text = Substring(token)
        if text.hasPrefix("#") { text = text.dropFirst() }
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return nil }
        return UInt64(text.dropFirst(2), radix: 16)
    }
}

extension WorkspaceSnapshot {
    /// Address → display name for every named code address in `slot`: symbols (including the
    /// synthetic stub symbols), then function starts (user overrides win via `displayName`).
    /// - Parameter targets: when non-nil, only these addresses are resolved (one linear pass, no
    ///   per-entry override lookups for the rest) — the per-function pseudocode path uses this.
    func branchTargetNames(in slot: ImageSlot, restrictedTo targets: Set<UInt64>? = nil) -> [UInt64: String] {
        guard let analysis = analysis(in: slot) else { return [:] }
        if let targets, targets.isEmpty { return [:] }
        var names: [UInt64: String] = [:]
        for symbol in analysis.symbols {
            guard let address = symbol.address, !symbol.name.isEmpty,
                  targets?.contains(address) ?? true else { continue }
            names[address] = displayName(at: address, in: slot, default: symbol.name)
        }
        for function in analysis.functions where targets?.contains(function.startAddress) ?? true {
            names[function.startAddress] = displayName(at: function.startAddress, in: slot, default: function.name)
        }
        return names
    }

    /// The direct call targets in `rows` (operands of `bl`/`call`).
    static func directCallTargets(in rows: [InstructionRow]) -> Set<UInt64> {
        var targets: Set<UInt64> = []
        for row in rows where BranchTargetSymbolizer.callMnemonics.contains(row.mnemonic.lowercased()) {
            let token = row.operands.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if let address = BranchTargetSymbolizer.parseHexAddress(token) { targets.insert(address) }
        }
        return targets
    }
}

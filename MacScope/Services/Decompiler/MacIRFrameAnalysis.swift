import Foundation

/// DP04 B1: canonical frame coordinates over the instruction CFG.
///
/// A small forward abstract interpreter tracks SP and every GPR that provably holds a
/// stack address, as `entrySP + constant`, a `dynamic` allocation (alloca-like
/// `sub sp, sp, xN`), or `unknown`. Equal values join exactly; disagreeing values
/// become unknown, so loops terminate without a guessed depth. Each exact stack
/// access is recorded as a half-open byte range in entry-SP coordinates (pairs as
/// two ranges). This pass only reports facts; lowering is unchanged (B2 consumes it).
struct MacIRFrameAnalysis: Sendable {
    enum Base: Hashable, Sendable {
        case entrySP(Int64)
        /// SP after a non-constant allocation at this instruction address.
        case dynamic(UInt64)
        case unknown

        func adding(_ delta: Int64) -> Base {
            switch self {
            case let .entrySP(offset):
                let (sum, overflow) = offset.addingReportingOverflow(delta)
                return overflow ? .unknown : .entrySP(sum)
            case .dynamic, .unknown: return delta == 0 ? self : .unknown
            }
        }
    }

    struct State: Hashable, Sendable {
        var sp: Base = .entrySP(0)
        /// GPR index (0…30, x29 included) → the stack address it holds.
        var aliases: [Int: Base] = [:]

        func value(of register: String) -> Base? {
            let name = register.trimmingCharacters(in: .whitespaces).lowercased()
            if name == "sp" { return sp }
            if name == "fp" { return aliases[29] }
            guard let view = MacIRBuilder.integerRegisterView(name), view.width == 64 else { return nil }
            return aliases[view.index]
        }

        mutating func set(_ register: String, _ value: Base?) {
            let name = register.trimmingCharacters(in: .whitespaces).lowercased()
            if name == "sp" { sp = value ?? .unknown; return }
            let index = name == "fp" ? 29 : MacIRBuilder.integerRegisterView(name)?.index
            guard let index else { return }
            // A 32-bit write never preserves a 64-bit address.
            if let value, name == "fp" || name.first == "x" { aliases[index] = value } else { aliases[index] = nil }
        }

        func joined(with other: State) -> State {
            var result = State(sp: sp == other.sp ? sp : .unknown, aliases: [:])
            for (index, value) in aliases where other.aliases[index] == value { result.aliases[index] = value }
            return result
        }
    }

    struct Access: Hashable, Sendable {
        let address: UInt64
        /// Byte range in entry-SP coordinates.
        let range: Range<Int64>
        let isWrite: Bool
        /// The register transferred to or from the slot.
        var register: String? = nil
    }

    /// The frame state before each row, by address.
    let stateBefore: [UInt64: State]
    let accesses: [Access]
    /// False when the CFG could not be recovered; no facts are reported then.
    let isComplete: Bool

    static func analyze<Row: DecompilerInstructionRow>(rows: [Row], instructions: [MacIRInstruction]) -> Self {
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        guard !cfg.blocks.isEmpty, !cfg.hasUnresolvedTargets else {
            return .init(stateBefore: [:], accesses: [], isComplete: false)
        }
        let rowsByAddress = Dictionary(rows.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        // Rows of each block in order, by their first IR instruction.
        let blockRows: [[Row]] = cfg.blocks.map { block in
            var seen = Set<UInt64>()
            return block.instructionRange.compactMap { index in
                let address = instructions[index].source.address
                guard seen.insert(address).inserted else { return nil }
                return rowsByAddress[address]
            }
        }
        var entry: [Int: State] = [cfg.entryIndex: State()]
        var exit: [Int: State] = [:]
        var worklist = [cfg.entryIndex]
        var visits = 0
        let visitLimit = cfg.blocks.count * 64
        while let blockIndex = worklist.popLast(), visits < visitLimit {
            visits += 1
            guard var state = entry[blockIndex] else { continue }
            var discarded: [Access] = []
            for row in blockRows[blockIndex] { transfer(row, &state, collected: &discarded) }
            guard exit[blockIndex] != state else { continue }
            exit[blockIndex] = state
            for successor in cfg.blocks[blockIndex].successors {
                let incoming = cfg.blocks[successor].predecessors.compactMap { exit[$0] }
                guard var merged = incoming.first else { continue }
                // A predecessor not yet visited (a back edge) is joined when it is.
                for other in incoming.dropFirst() { merged = merged.joined(with: other) }
                if entry[successor] != merged {
                    entry[successor] = merged
                    worklist.append(successor)
                }
            }
        }
        guard visits < visitLimit else { return .init(stateBefore: [:], accesses: [], isComplete: false) }
        var before: [UInt64: State] = [:]
        var accesses: [Access] = []
        for (blockIndex, rows) in blockRows.enumerated() {
            guard var state = entry[blockIndex] else { continue }
            for row in rows {
                before[row.address] = state
                transfer(row, &state, collected: &accesses)
            }
        }
        return .init(stateBefore: before, accesses: accesses, isComplete: true)
    }

    // MARK: - Transfer

    private static let callClobbered = Array(0...18) + [30]
    private static let writesNoRegister: Set<String> = [
        "cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "fcmpe", "b", "br", "cbz", "cbnz", "tbz", "tbnz",
        "ret", "retaa", "retab", "nop", "hint", "bti", "pacibsp", "autibsp", "paciasp", "autiasp",
        "dmb", "dsb", "isb", "prfm", "msr",
    ]

    private static func transfer<Row: DecompilerInstructionRow>(_ row: Row, _ state: inout State,
                                                                collected: inout [Access]) {
        let mnemonic = row.mnemonic.lowercased()
        let operands = MacIRBuilder.splitOperands(row.operands)
        switch mnemonic {
        case "bl", "blr", "blraa", "blrab", "blraaz", "blrabz":
            for index in callClobbered { state.aliases[index] = nil }
            return
        case "add", "sub":
            guard operands.count == 3 else { break }
            if let immediate = MacIRBuilder.parseImmediate(operands[2]) {
                let delta = mnemonic == "add" ? immediate : -immediate
                state.set(operands[0], state.value(of: operands[1])?.adding(delta))
                return
            }
            if operands[0].lowercased() == "sp", operands[1].lowercased() == "sp" {
                // `sub sp, sp, xN`: an alloca-like dynamic allocation.
                state.sp = .dynamic(row.address)
                return
            }
        case "mov":
            guard operands.count == 2 else { break }
            state.set(operands[0], state.value(of: operands[1]))
            return
        default:
            break
        }
        if let memoryIndex = operands.firstIndex(where: { $0.hasPrefix("[") }) {
            memoryTransfer(row, mnemonic: mnemonic, operands: operands, memoryIndex: memoryIndex,
                           state: &state, collected: &collected)
            return
        }
        // Any other instruction: its first operand, when a GPR or SP, is written.
        if writesNoRegister.contains(mnemonic) || mnemonic.hasPrefix("b.") { return }
        if let destination = operands.first { state.set(destination, nil) }
    }

    private static func memoryTransfer<Row: DecompilerInstructionRow>(
        _ row: Row, mnemonic: String, operands: [String], memoryIndex: Int,
        state: inout State, collected: inout [Access]
    ) {
        var memory = operands[memoryIndex].trimmingCharacters(in: .whitespaces)
        let preIndex = memory.hasSuffix("!")
        if preIndex { memory.removeLast() }
        guard memory.hasPrefix("["), memory.hasSuffix("]") else { return }
        let parts = MacIRBuilder.splitOperands(String(memory.dropFirst().dropLast()))
        guard let baseName = parts.first else { return }
        let base = state.value(of: baseName)
        let displacement: Int64? = parts.count == 1 ? 0 : (parts.count == 2 ? MacIRBuilder.parseImmediate(parts[1]) : nil)
        let postIndex = memoryIndex + 1 < operands.count ? MacIRBuilder.parseImmediate(operands[memoryIndex + 1]) : nil
        let registerPostIndex = memoryIndex + 1 < operands.count && postIndex == nil
        let isLoad = mnemonic.hasPrefix("ld")
        let transfers = Array(operands[..<memoryIndex])
        let isPair = ["ldp", "ldpsw", "stp"].contains(mnemonic)
        // Exact accesses: base + displacement (pre-index applied first, post-index after).
        if let displacement, case let .entrySP(offset)? = base {
            let start = offset + (postIndex != nil ? 0 : displacement)
            var cursor = start
            for register in transfers {
                // LDPSW writes 64-bit registers but reads four-byte elements.
                let width = isPair
                    ? MacIRBuilder.pairElementByteWidth(mnemonic: mnemonic, register: register)
                    : MacIRBuilder.loadStoreByteWidth(mnemonic: mnemonic, register: register).map(Int64.init)
                guard let width, width > 0 else { break }
                collected.append(.init(address: row.address, range: cursor..<(cursor + width), isWrite: !isLoad,
                                       register: register.trimmingCharacters(in: .whitespaces).lowercased()))
                cursor += width
            }
        }
        // Loaded registers no longer hold a known stack address.
        if isLoad { for register in transfers { state.set(register, nil) } }
        // Writeback updates the base after the access.
        if preIndex, let displacement {
            state.set(baseName, base?.adding(displacement))
        } else if let postIndex {
            state.set(baseName, base?.adding(postIndex))
        } else if registerPostIndex || preIndex {
            state.set(baseName, baseName.lowercased() == "sp" ? .unknown : nil)
        }
    }
}

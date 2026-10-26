import Foundation

/// Recovers DATA cross-references from decoded instructions by reproducing the
/// ARM64 `adrp`(+`add`/`ldr`) address-formation idiom and classifying each resolved
/// target against already-resolved tables (string literals, Objective-C selector
/// slots, data sections).
///
/// The pass is intentionally PURE and conservative. It tracks a page base per
/// register and applies strict clobber invalidation: any instruction that
/// overwrites a register drops its tracked base.
///
/// Control-flow boundaries are handled by KIND rather than uniformly wiping all
/// state, so a split `adrp xN, page` … (branch) … `ldr/add xN, [xN, #off]` idiom
/// that materializes the address in a SUCCESSOR block is still recovered:
///   * a CONDITIONAL branch (`b.cond`, `cbz`, `cbnz`, `tbz`, `tbnz`) falls through to
///     the next linear instruction — a REAL successor — so its page base is carried
///     across so the successor block's add/ldr that completes the address resolves;
///   * an UNCONDITIONAL `b`/`b.al` and a register-indirect branch (`br`/tail call)
///     clear all state: the next LINEAR instruction is NOT their successor (control
///     went to the target), so carrying a base could fabricate a phantom edge;
///   * a CALL (`bl`/`blr` and the arm64e authenticated variants) drops only the
///     caller-saved (volatile) registers, because the callee may overwrite them,
///     while callee-saved bases (x19–x28) survive — matching AAPCS64;
///   * a RETURN / exception-return / trap (`ret`, `eret`, `svc`, `brk`, `hlt`)
///     ends the flow, so all state is cleared — whatever decodes next is a new
///     region whose reaching facts must not leak in.
/// An edge is emitted ONLY when a resolved target lands in a known table, so a
/// stale register can never imply a phantom reference; carrying a base across a
/// branch cannot manufacture an xref unless a real add/ldr completes it AND the
/// result lands in a known table. Edges carry no UUID — the caller assigns ids —
/// which keeps the resolver deterministic and unit-testable.
struct DataCrossReferenceResolver: Sendable {
    /// One recovered reference: the `from` instruction references the `to` data
    /// address, classified into an `XRefKind`.
    struct Reference: Equatable, Sendable {
        var from: UInt64
        var to: UInt64
        var kind: String
    }

    /// A half-open `[lowerBound, upperBound)` range of a non-executable data section.
    struct DataRange: Sendable {
        var lowerBound: UInt64
        var upperBound: UInt64

        func contains(_ address: UInt64) -> Bool {
            address >= lowerBound && address < upperBound
        }
    }

    func resolve<Row: DecompilerInstructionRow>(
        instructions rows: [Row],
        stringAddresses: Set<UInt64>,
        selectorSlots: Set<UInt64>,
        classSlots: Set<UInt64> = [],
        dataRanges: [DataRange]
    ) -> [Reference] {
        resolveSegment(rows, range: rows.indices, stringAddresses: stringAddresses,
                       selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges)
    }

    /// Parallel equivalent of `resolve` with BYTE-IDENTICAL output. The pass is stateful (it carries
    /// a per-register page base across instructions), so it cannot be chunked arbitrarily — but every
    /// TERMINATOR (`ret`/`eret`, unconditional `b`, `br` tail call, `svc`/`brk`/`hlt`) clears ALL
    /// state, so the instruction right after one is reached by the linear pass with EMPTY state.
    /// Splitting only at those boundaries and resolving each chunk from empty state is therefore
    /// identical to the single linear pass (a chunk is NOT split across a carried page base). Chunks
    /// resolve concurrently and concatenate in order. Below `threshold` it stays sequential.
    ///
    /// `Row: Sendable` because the chunks read `rows` concurrently across threads — the constraint
    /// makes that thread-safety a COMPILER-CHECKED fact rather than a caller's unstated promise.
    /// The sequential `resolve` deliberately stays unconstrained (no concurrency there).
    func resolveParallel<Row: DecompilerInstructionRow & Sendable>(
        instructions rows: [Row],
        stringAddresses: Set<UInt64>,
        selectorSlots: Set<UInt64>,
        classSlots: Set<UInt64> = [],
        dataRanges: [DataRange],
        threshold: Int = 8_192
    ) -> [Reference] {
        guard rows.count >= threshold else {
            return resolveSegment(rows, range: rows.indices, stringAddresses: stringAddresses,
                                  selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges)
        }
        let bounds = Self.terminatorAlignedChunks(
            rows, targetChunks: max(1, ProcessInfo.processInfo.activeProcessorCount) * 4
        )
        let perChunk = ConcurrentMap.map(count: bounds.count, threshold: 1) { index in
            self.resolveSegment(rows, range: bounds[index], stringAddresses: stringAddresses,
                                selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges)
        }
        return perChunk.flatMap { $0 }
    }

    /// The canonical sequential core: resolves the references for `rows[range]` starting from EMPTY
    /// register state. `resolve` runs it over the whole stream; `resolveParallel` runs it over each
    /// terminator-aligned chunk (each of which the linear pass also reaches with empty state).
    private func resolveSegment<Row: DecompilerInstructionRow>(
        _ rows: [Row],
        range: Range<Int>,
        stringAddresses: Set<UInt64>,
        selectorSlots: Set<UInt64>,
        classSlots: Set<UInt64>,
        dataRanges: [DataRange]
    ) -> [Reference] {
        var references: [Reference] = []
        var pageBaseByRegister: [String: UInt64] = [:]

        for index in range {
            let row = rows[index]
            let mnemonic = row.mnemonic.lowercased()
            let operands = Self.splitOperands(row.operands)

            // Control-flow boundaries are handled per KIND so a page base formed
            // before a branch can still complete in a successor block.
            switch Self.controlFlowBoundary(mnemonic) {
            case .none:
                break
            case .branch:
                // A branch does not write any register: the page base is still
                // valid in the successor block. Carry all bases across unchanged.
                continue
            case .call:
                // The callee may clobber the volatile (caller-saved) registers;
                // callee-saved bases (x19–x28, fp) survive across the call.
                for key in pageBaseByRegister.keys where Self.isCallerSaved(key) {
                    pageBaseByRegister.removeValue(forKey: key)
                }
                continue
            case .terminator:
                // Return / exception-return / trap ends the flow; clear all state so
                // a following (new) region can't inherit stale reaching facts.
                pageBaseByRegister.removeAll(keepingCapacity: true)
                continue
            }

            switch mnemonic {
            case "adrp", "adr":
                guard operands.count == 2,
                      let destination = Self.registerKey(operands[0]),
                      let target = Self.parseAddress(operands[1]) else {
                    // Unparseable target (e.g. "<address overflow>"): clobber the dest.
                    clobberFirstRegister(operands, in: &pageBaseByRegister)
                    continue
                }
                pageBaseByRegister[destination] = target
                // `adr` forms a COMPLETE PC-relative address (not a 4 KB page), so it
                // is a reference on its own; `adrp` only a page base — wait for +add.
                if mnemonic == "adr",
                   let reference = Self.classify(
                       from: row.address, to: target,
                       stringAddresses: stringAddresses, selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges
                   ) {
                    references.append(reference)
                }

            case "add":
                // add Xd, Xn, #imm where Xn holds a page base -> Xd = base + imm.
                guard operands.count == 3,
                      let destination = Self.registerKey(operands[0]),
                      let source = Self.registerKey(operands[1]),
                      let base = pageBaseByRegister[source],
                      let immediate = Self.parseImmediate(operands[2]) else {
                    // Not a page-base add: Xd is overwritten with an untracked value.
                    clobberFirstRegister(operands, in: &pageBaseByRegister)
                    continue
                }
                let target = base &+ UInt64(bitPattern: immediate)
                pageBaseByRegister[destination] = target
                if let reference = Self.classify(
                    from: row.address, to: target,
                    stringAddresses: stringAddresses, selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges
                ) {
                    references.append(reference)
                }

            case _ where mnemonic.hasPrefix("ldp") || mnemonic.hasPrefix("ldnp"):
                // Pair load `ldp Xt1, Xt2, [Xn, #off]`: classify the slot when Xn is a
                // page base, then clobber BOTH loaded destinations (each gets a loaded
                // value, not a page base). This case must be reachable on its own — a
                // pair mnemonic never matches the single-load `ldr` prefix below.
                if operands.count >= 3,
                   let memory = Self.memoryComponents(operands[2]),
                   let sourceKey = Self.registerKey(memory.base),
                   let base = pageBaseByRegister[sourceKey] {
                    let slot = base &+ UInt64(bitPattern: memory.offset)
                    if let reference = Self.classify(
                        from: row.address, to: slot,
                        stringAddresses: stringAddresses, selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges
                    ) {
                        references.append(reference)
                    }
                }
                if let first = operands.first.flatMap(Self.registerKey) {
                    pageBaseByRegister.removeValue(forKey: first)
                }
                if operands.count >= 2, let second = Self.registerKey(operands[1]) {
                    pageBaseByRegister.removeValue(forKey: second)
                }

            case _ where mnemonic.hasPrefix("ldr"):
                // ldr Xd, [Xn, #off] where Xn holds a page base -> slot = base + off.
                if let memory = Self.memoryComponents(memoryOperand(operands)),
                   let sourceKey = Self.registerKey(memory.base),
                   let base = pageBaseByRegister[sourceKey] {
                    let slot = base &+ UInt64(bitPattern: memory.offset)
                    if let reference = Self.classify(
                        from: row.address, to: slot,
                        stringAddresses: stringAddresses, selectorSlots: selectorSlots, classSlots: classSlots, dataRanges: dataRanges
                    ) {
                        references.append(reference)
                    }
                }
                // The loaded value replaces the destination: no longer a page base.
                clobberFirstRegister(operands, in: &pageBaseByRegister)

            case _ where Self.isPlainStore(mnemonic) || Self.comparesWriteNoRegister.contains(mnemonic):
                // PLAIN stores READ their first operand and compares write no register,
                // so neither clobbers a tracked base. Exclusive stores (stxr/stlxr…)
                // write a status register in operand 0, so they fall through to the
                // default clobber instead.
                break

            default:
                if let written = ARM64ExplicitRegisterWrites.writes(mnemonic: mnemonic, operands: operands) {
                    // MOPS, RCW, LSE atomics, PAC 1716 and PAuth_LR: clear exactly the
                    // registers they write (not a read-only first operand such as Xs).
                    for key in written.compactMap(Self.registerKey) {
                        pageBaseByRegister.removeValue(forKey: key)
                    }
                } else {
                    // Any other instruction overwrites its destination (first operand).
                    clobberFirstRegister(operands, in: &pageBaseByRegister)
                }
            }
            // A writeback load/store also replaces its base register. Do not
            // carry an old ADRP page into a later memory reference.
            if let base = Self.writebackBaseRegister(mnemonic: mnemonic, operands: operands) {
                pageBaseByRegister.removeValue(forKey: base)
            }
        }

        return references
    }

    private static func writebackBaseRegister(mnemonic: String, operands: [String]) -> String? {
        guard mnemonic.hasPrefix("ld") || mnemonic.hasPrefix("st"),
              let memoryIndex = operands.firstIndex(where: { $0.hasPrefix("[") }) else { return nil }
        let memory = operands[memoryIndex]
        let isPreIndex = memory.hasSuffix("]!")
        let isPostIndex = memory.hasSuffix("]") && memoryIndex + 1 < operands.count
        guard isPreIndex || isPostIndex else { return nil }
        return registerKey(String(memory.dropFirst().prefix { $0 != "," && $0 != "]" }))
    }

    private func clobberFirstRegister(_ operands: [String], in pageBaseByRegister: inout [String: UInt64]) {
        if let destination = operands.first.flatMap(Self.registerKey) {
            pageBaseByRegister.removeValue(forKey: destination)
        }
    }

    /// The memory operand of a load: operand index 1, joining any register-offset
    /// tail (`[x8, x2, lsl #3]`) the bracket-aware split kept together.
    private func memoryOperand(_ operands: [String]) -> String {
        guard operands.count >= 2 else { return "" }
        return operands.dropFirst().joined(separator: ", ")
    }

    private static let comparesWriteNoRegister: Set<String> = ["cmp", "cmn", "tst", "ccmp", "ccmn"]

    /// True for a PLAIN store (writes memory, reads operand 0). Exclusive stores
    /// (`stxr`/`stxp`/`stlxr`/`stlxp`) are NOT plain: they write a status register in
    /// operand 0, so they must fall through to the default clobber.
    private static func isPlainStore(_ mnemonic: String) -> Bool {
        mnemonic.hasPrefix("st") && !mnemonic.hasPrefix("stx") && !mnemonic.hasPrefix("stlx")
    }

    private static func classify(
        from: UInt64,
        to: UInt64,
        stringAddresses: Set<UInt64>,
        selectorSlots: Set<UInt64>,
        classSlots: Set<UInt64>,
        dataRanges: [DataRange]
    ) -> Reference? {
        if stringAddresses.contains(to) { return Reference(from: from, to: to, kind: XRefKind.string) }
        if selectorSlots.contains(to) { return Reference(from: from, to: to, kind: XRefKind.selref) }
        // RX-02a: a class-reference slot is a typed use of that class, not an anonymous data read.
        if classSlots.contains(to) { return Reference(from: from, to: to, kind: XRefKind.classref) }
        if dataRanges.contains(where: { $0.contains(to) }) { return Reference(from: from, to: to, kind: XRefKind.data) }
        return nil
    }

    // MARK: - Operand parsing (bracket-aware, mirrors JumpTableResolver)

    /// Normalizes a general-purpose register operand to an architectural key so a
    /// 32-bit (`w8`) write clobbers the 64-bit (`x8`) page base. `sp`/`fp`/`lr` keep
    /// their names; non-registers return nil.
    private static func registerKey(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = normalized.first else { return nil }
        if normalized == "sp" || normalized == "fp" || normalized == "lr" { return normalized }
        guard first == "x" || first == "w" else { return nil }
        let digits = normalized.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return "x" + digits
    }

    private static func parseAddress(_ operand: String) -> UInt64? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("0x") { return UInt64(normalized.dropFirst(2), radix: 16) }
        guard !normalized.isEmpty, normalized.allSatisfy(\.isNumber) else { return nil }
        return UInt64(normalized)
    }

    private static func parseImmediate(_ operand: String) -> Int64? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") { normalized.removeFirst() }
        let sign: Int64
        if normalized.hasPrefix("-") { sign = -1; normalized.removeFirst() } else { sign = 1 }
        if normalized.hasPrefix("0x") { return Int64(normalized.dropFirst(2), radix: 16).map { sign * $0 } }
        return Int64(normalized).map { sign * $0 }
    }

    /// Parses a `[base, #off]` (or `[base]`) memory operand into its base register
    /// and immediate offset. Register-offset / writeback / pre-index forms return
    /// nil (those are not page-base slot loads).
    private static func memoryComponents(_ operand: String) -> (base: String, offset: Int64)? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.hasSuffix("!"), normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        let parts = splitOperands(String(normalized.dropFirst().dropLast()))
        guard let base = parts.first, registerKey(base) != nil else { return nil }
        switch parts.count {
        case 1: return (base, 0)
        case 2:
            guard let offset = parseImmediate(parts[1]) else { return nil }
            return (base, offset)
        default: return nil
        }
    }

    private static func splitOperands(_ text: String) -> [String] {
        var operands: [String] = []
        var current = ""
        var bracketDepth = 0
        for character in text {
            switch character {
            case "[": bracketDepth += 1; current.append(character)
            case "]": bracketDepth = max(0, bracketDepth - 1); current.append(character)
            case "," where bracketDepth == 0:
                operands.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: true)
            default: current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { operands.append(tail) }
        return operands
    }

    /// How a control-flow instruction affects reaching state.
    private enum BoundaryKind {
        /// Not a control-flow boundary — fall through to normal data-flow handling.
        case none
        /// Plain or conditional branch within the function: writes no register, so
        /// page bases survive into the successor block.
        case branch
        /// A call (`bl`/`blr` + arm64e authenticated variants): clobbers the
        /// caller-saved registers; callee-saved bases survive.
        case call
        /// Return / exception-return / trap, plus the register-indirect branches
        /// (`br`/`braa`/…) that are usually tail calls: ends the flow for this
        /// resolver and all state is cleared. Clearing here is the CONSERVATIVE
        /// choice — it can only DROP a base, never manufacture a phantom edge.
        case terminator
    }

    /// Partitions `[0, rows.count)` into contiguous chunks that each END on a terminator, so the
    /// instruction STARTING the next chunk is one the linear pass reaches with empty register state.
    /// A chunk grows to ~`rows.count / targetChunks`, then extends only as far as the next terminator
    /// (so no chunk boundary ever splits a carried page base). The final chunk may end mid-block — it
    /// has no successor chunk to seed, so its trailing state is simply discarded, exactly as the
    /// linear pass discards it at end-of-stream.
    private static func terminatorAlignedChunks<Row: DecompilerInstructionRow>(
        _ rows: [Row], targetChunks: Int
    ) -> [Range<Int>] {
        let n = rows.count
        guard n > 0 else { return [] }
        let target = max(1, n / max(1, targetChunks))
        var bounds: [Range<Int>] = []
        var start = 0
        while start < n {
            var end = min(start + target, n)
            // Extend until the last included instruction is a terminator (empty state after it), so
            // the NEXT chunk starts fresh. Reaching `n` first makes this the final chunk.
            while end < n, controlFlowBoundary(rows[end - 1].mnemonic.lowercased()) != .terminator {
                end += 1
            }
            bounds.append(start..<end)
            start = end
        }
        return bounds
    }

    private static func controlFlowBoundary(_ mnemonic: String) -> BoundaryKind {
        switch mnemonic {
        // CONDITIONAL branches (incl. `b.nv`, "never", which always falls through):
        // the NEXT LINEAR instruction is the fall-through successor, so the page base
        // is still valid there. These are the splits the cross-boundary fix recovers.
        case "cbz", "cbnz", "tbz", "tbnz", "b.nv":
            return .branch
        // UNCONDITIONAL `b`/`b.al` always transfer control to the TARGET, so the next
        // LINEAR instruction is NOT this block's successor — carrying a base across it
        // would pair it with an unrelated block and could fabricate a PHANTOM edge.
        // Clearing is conservative: it drops at most a rare real edge, never invents
        // one. Traps (svc/brk/hlt) likewise end the straight-line flow.
        case "b", "b.al", "svc", "brk", "hlt":
            return .terminator
        default:
            // Returns first: `ret`/`retaa`/`retab` and exception returns. No
            // non-return mnemonic begins with `ret`/`eret`.
            if mnemonic.hasPrefix("ret") || mnemonic.hasPrefix("eret") {
                return .terminator
            }
            // Calls: `bl`, `blr`, and the authenticated `blraa/blrab` (and the
            // pointer-auth `blraaz/...`). No non-call mnemonic begins with `bl`.
            if mnemonic.hasPrefix("bl") {
                return .call
            }
            // Conditional direct branch `b.<cond>`: a same-function edge, carry state.
            if mnemonic.hasPrefix("b.") {
                return .branch
            }
            // Register-indirect branches `br`/`braa`/`brab`/`braaz`/… are typically
            // tail calls (or authenticated dispatch). Treat them as terminators and
            // clear state: carrying a base across a tail call could fabricate a
            // phantom edge, and dropping it can only cost a (rare) real edge. No
            // non-branch mnemonic begins with `br` (logical ops are bic/bfi/…).
            if mnemonic.hasPrefix("br") {
                return .terminator
            }
            return .none
        }
    }

    /// True if `key` (an architectural `x<N>`/`sp`/`fp`/`lr` register key) is a
    /// caller-saved (volatile) register under AAPCS64: x0–x18 and lr. Callee-saved
    /// x19–x28 and fp (x29) survive a call.
    private static func isCallerSaved(_ key: String) -> Bool {
        if key == "lr" { return true }
        if key == "fp" || key == "sp" { return false }
        guard key.hasPrefix("x"), let number = Int(key.dropFirst()) else {
            // Unknown key form: treat conservatively as volatile (drop on call).
            return true
        }
        return number <= 18
    }
}

// MARK: - Registers written by the families the first-operand rule mis-models

/// General-purpose registers written by the ARM64 families whose destination is NOT simply the
/// first operand: FEAT_MOPS (`cpy*`/`set*`/`setg*`), FEAT_THE (`rcw*`), the LSE `swp`/`ld<op>`/
/// `cas`/`casp` atomics, the PAC `*1716`/`*171615` hints and FEAT_PAuth_LR. The data-xref and
/// jump-table resolvers share it, so both clear the same registers.
enum ARM64ExplicitRegisterWrites {
    /// The written registers as lowercased operand spellings (`x2`, `w3`, `x17`), or nil when
    /// `mnemonic` is not one of these families and the caller's own rule applies.
    ///
    /// - MOPS writes back every `!` operand: `cpy*` `[Xd]!, [Xs]!, Xn!`; `set*` `[Xd]!, Xn!, Xs`
    ///   (Xs, the fill value, is only read).
    /// - RCW: CAS → Xs; CASP → Xs, Xs+1; SWP/CLR/SET → Xt (Xs is only read); `*p` → Xt1, Xt2.
    /// - LSE: `swp`/`ld<op>` → Rt; `cas` → Rs; `casp` → Rs, Rs+1.
    /// - `*1716`/`*171615` write x17. PAuth_LR signing/authentication writes x30 (LR):
    ///   `autiasppcr xN` only READS its modifier xN, and the `ret*sppc*` returns write nothing.
    static func writes(mnemonic: String, operands: [String]) -> [String]? {
        let mnemonic = mnemonic.lowercased()
        let operands = operands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if memoryOperationMnemonics.contains(mnemonic),
           let first = operands.first, first.hasPrefix("["), first.hasSuffix("]!") {
            return operands.filter { $0.hasSuffix("!") }
                .map { String($0.filter { $0 != "[" && $0 != "]" && $0 != "!" }) }
        }
        if let positions = operandWritePositions[mnemonic] {
            return positions.compactMap { operands.indices.contains($0) ? operands[$0] : nil }
        }
        if x17Writers.contains(mnemonic) { return ["x17"] }
        if linkRegisterWriters.contains(mnemonic) { return ["x30"] }
        if pointerAuthLRReturns.contains(mnemonic) { return [] }
        return nil
    }

    private static let orderings = ["", "a", "l", "al"]

    /// FEAT_MOPS spellings: `cpy`/`cpyf` + stage + read option + write option, and `set`/`setg` +
    /// stage + option. The first-operand `[Xd]!` check in `writes` keeps x86 `setp`/`sete` out.
    static let memoryOperationMnemonics: Set<String> = {
        var names: Set<String> = []
        for stage in ["p", "m", "e"] {
            for family in ["cpy", "cpyf"] {
                for read in ["", "wt", "rt", "t"] {
                    for write in ["", "wn", "rn", "n"] { names.insert(family + stage + read + write) }
                }
            }
            for family in ["set", "setg"] {
                for option in ["", "t", "n", "tn"] { names.insert(family + stage + option) }
            }
        }
        return names
    }()

    /// Operand positions written by the LSE and RCW atomics.
    static let operandWritePositions: [String: [Int]] = {
        var positions: [String: [Int]] = [:]
        for ordering in orderings {
            for size in ["", "b", "h"] {
                for base in ["ldadd", "ldclr", "ldeor", "ldset", "ldsmax", "ldsmin", "ldumax", "ldumin", "swp"] {
                    positions[base + ordering + size] = [1]
                }
                positions["cas" + ordering + size] = [0]
            }
            positions["casp" + ordering] = [0, 1]
            for prefix in ["rcw", "rcws"] {
                positions[prefix + "cas" + ordering] = [0]
                positions[prefix + "casp" + ordering] = [0, 1]
                for operation in ["clr", "swp", "set"] {
                    positions[prefix + operation + ordering] = [1]
                    positions[prefix + operation + "p" + ordering] = [0, 1]
                }
            }
        }
        return positions
    }()

    static let x17Writers: Set<String> = [
        "pacia1716", "pacib1716", "autia1716", "autib1716",
        "pacia171615", "pacib171615", "autia171615", "autib171615",
    ]

    static let linkRegisterWriters: Set<String> = [
        "paciasp", "pacibsp", "autiasp", "autibsp",
        "paciaz", "pacibz", "autiaz", "autibz", "xpaclri",
        "paciasppc", "pacibsppc", "pacnbiasppc", "pacnbibsppc",
        "autiasppc", "autibsppc", "autiasppcr", "autibsppcr",
    ]

    static let pointerAuthLRReturns: Set<String> = ["retaasppc", "retabsppc", "retaasppcr", "retabsppcr"]
}

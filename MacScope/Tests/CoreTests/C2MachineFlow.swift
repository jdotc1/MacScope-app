import Foundation
@testable import MacScope

/// Independent architectural reaching definitions. No lifted operation participates in this graph.
/// Address zero denotes the function-entry value, including an ABI parameter or uninitialized input.
struct C2MachineFlow {
    let error: String?
    let indirectBranchSites: [UInt64]
    let rows: [MacIRSourceSpan]
    let successors: [[Int]]
    let predecessors: [[Int]]
    let reachable: Set<Int>
    let writes: [Set<String>]
    let reads: [Set<String>]
    let before: [[String: Set<UInt64>]]
    private let blockOf: [Int]
    private let blockRanges: [Range<Int>]
    private let blockPredecessors: [[Int]]
    private let immediateDominator: [Int]
    private let dominanceEntry: [Int]
    private let dominanceExit: [Int]
    let backedges: [(from: Int, to: Int)]

    init(rows: [MacIRSourceSpan], permitDOnlyCallProjection: Bool = false) {
        self.rows = rows
        let count = rows.count
        var problem: String?
        var indirectSites: [UInt64] = []
        var next = Array(repeating: [Int](), count: count)
        var definitions = Array(repeating: Set<String>(), count: count)
        var references = definitions
        let addresses = Dictionary(rows.enumerated().map { ($0.element.address, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        if addresses.count != count { problem = "duplicate machine instruction address" }
        if rows.contains(where: { $0.address == 0 }) { problem = "machine address collides with entry sentinel" }
        var hasCall = false
        for (index, row) in rows.enumerated() {
            let mnemonic = row.mnemonic.lowercased()
            let operands = Self.operands(row.operands)
            let semantics = Self.semantics(mnemonic, operands)
            definitions[index] = semantics.writes
            references[index] = semantics.reads
            if let reason = semantics.error, problem == nil {
                problem = "0x\(String(row.address, radix: 16)): \(reason)"
            }
            func fallthroughEdge() {
                guard index + 1 < count else { return }
                if rows[index + 1].address != row.address &+ 4, problem == nil {
                    problem = "noncontiguous machine fallthrough at 0x\(String(row.address, radix: 16))"
                }
                next[index].append(index + 1)
            }
            let alwaysBranch = ["b", "b.al", "b.nv"].contains(mnemonic)
            let conditional = (mnemonic.hasPrefix("b.") && !alwaysBranch)
                || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
            if alwaysBranch || conditional {
                if let target = operands.last.flatMap(Self.targetAddress) {
                    if let destination = addresses[target] { next[index].append(destination) }
                    else if let first = rows.first?.address, let last = rows.last?.address,
                            target >= first, target <= last, problem == nil {
                        problem = "branch targets an absent instruction at 0x\(String(target, radix: 16))"
                    }
                } else if problem == nil {
                    problem = "unresolved direct branch at 0x\(String(row.address, radix: 16))"
                }
                if conditional { fallthroughEdge() }
            } else if ["ret", "retaa", "retab"].contains(mnemonic) {
                // Architectural return terminates this function.
            } else if ["br", "braa", "brab", "braaz", "brabz"].contains(mnemonic) {
                indirectSites.append(row.address)
                if problem == nil { problem = "unresolved indirect branch at 0x\(String(row.address, radix: 16))" }
            } else {
                hasCall = hasCall || ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic)
                fallthroughEdge()
            }
            next[index] = Array(Set(next[index])).sorted()
        }
        indirectBranchSites = indirectSites.sorted()
        // AAPCS64 preserves only low 64 bits of v8-v15. This whole-register model must
        // not report those mixed preserved/clobbered values as a full-register fact.
        let partialCallRegisters = Set((8...15).map { "v\($0)" })
        let dOnlyOperands = rows.allSatisfy { row in
            row.operands.lowercased().split(whereSeparator: {
                !$0.isLetter && !$0.isNumber && $0 != "_"
            }).allSatisfy { token in
                guard let bank = Self.canonicalRegister(String(token)),
                      partialCallRegisters.contains(bank) else { return true }
                return String(token) == "d" + bank.dropFirst()
            }
        }
        // Opt-in requires the census to prove the same low64-only view for all IR
        // uses, definitions and phi inputs. No upper-half preservation is inferred.
        if hasCall && references.contains(where: { !$0.isDisjoint(with: partialCallRegisters) }),
           !(permitDOnlyCallProjection && dOnlyOperands), problem == nil {
            problem = "call with v8-v15 use requires partial-register reaching definitions"
        }
        if hasCall && references.contains(where: { !$0.isDisjoint(with: ["fpcr", "fpsr"]) }), problem == nil {
            problem = "call with floating-point system-register use requires bit-level ABI preservation"
        }
        var previous = Array(repeating: [Int](), count: count)
        for index in next.indices { for target in next[index] { previous[target].append(index) } }
        var visited = Set<Int>()
        var pending = count == 0 ? [] : [0]
        while let node = pending.popLast() {
            if visited.insert(node).inserted { pending.append(contentsOf: next[node]) }
        }
        // Unsupported machine semantics are already a coverage refusal. Do not pay
        // for fixed points that the caller is forbidden to use after this failure.
        if problem != nil {
            error = problem
            successors = next
            predecessors = previous
            reachable = visited
            writes = definitions
            reads = references
            before = Array(repeating: [:], count: count)
            backedges = []
            blockOf = []
            blockRanges = []
            blockPredecessors = []
            immediateDominator = []
            dominanceEntry = []
            dominanceExit = []
            return
        }

        let registers = definitions.reduce(into: Set<String>()) { $0.formUnion($1) }
            .union(references.reduce(into: Set<String>()) { $0.formUnion($1) })
        var incoming = Array(repeating: [String: Set<UInt64>](), count: count)
        var deltas = incoming
        var factQueue: [(node: Int, register: String)] = []
        // A fact is accepted once per node/register. Writers kill incoming facts;
        // their own output fact is seeded independently below. Only new deltas
        // traverse successor edges, never a complete unchanged register dictionary.
        func accept(_ sites: Set<UInt64>, at node: Int, register: String) {
            let added = sites.subtracting(incoming[node][register, default: []])
            guard !added.isEmpty else { return }
            incoming[node][register, default: []].formUnion(added)
            guard !definitions[node].contains(register) else { return }
            if deltas[node][register] == nil { factQueue.append((node, register)) }
            deltas[node][register, default: []].formUnion(added)
        }
        if count > 0 {
            for register in registers.sorted() { accept([0], at: 0, register: register) }
        }
        for node in visited.sorted() {
            for register in definitions[node].sorted() {
                for successor in next[node] {
                    accept([rows[node].address], at: successor, register: register)
                }
            }
        }
        var factHead = 0
        while factHead < factQueue.count {
            let event = factQueue[factHead]
            factHead += 1
            let delta = deltas[event.node].removeValue(forKey: event.register) ?? []
            for successor in next[event.node] {
                accept(delta, at: successor, register: event.register)
            }
            // Bound retained consumed queue entries without repeated removeFirst().
            if factHead >= 4096, factHead >= factQueue.count / 2 {
                factQueue.removeFirst(factHead)
                factHead = 0
            }
        }

        // Split at every control transfer and join. Fallthrough-only instructions
        // share one block, so dominance storage scales with blocks rather than N².
        var leaders = count == 0 ? Set<Int>() : Set([0])
        for node in next.indices {
            if next[node] != [node + 1] {
                leaders.formUnion(next[node])
                if node + 1 < count { leaders.insert(node + 1) }
            }
            if previous[node].count != 1 { leaders.insert(node) }
        }
        let starts = leaders.sorted()
        let ranges = starts.enumerated().map { position, start in
            start..<(position + 1 < starts.count ? starts[position + 1] : count)
        }
        var owner = Array(repeating: -1, count: count)
        for (block, range) in ranges.enumerated() { for node in range { owner[node] = block } }
        var blockNext = Array(repeating: [Int](), count: ranges.count)
        var blockPrevious = blockNext
        for (block, range) in ranges.enumerated() {
            blockNext[block] = Array(Set(next[range.upperBound - 1].map { owner[$0] })).sorted()
            for successor in blockNext[block] { blockPrevious[successor].append(block) }
        }

        // Iterative DFS avoids recursion depth depending on the binary's size.
        var seenBlocks = Set<Int>()
        var postorder: [Int] = []
        var traversal: [(block: Int, exit: Bool)] = count == 0 ? [] : [(owner[0], false)]
        while let frame = traversal.popLast() {
            if frame.exit { postorder.append(frame.block); continue }
            guard seenBlocks.insert(frame.block).inserted else { continue }
            traversal.append((frame.block, true))
            for successor in blockNext[frame.block].reversed() where !seenBlocks.contains(successor) {
                traversal.append((successor, false))
            }
        }
        let order = Array(postorder.reversed())
        var rank = Array(repeating: -1, count: ranges.count)
        for (position, block) in order.enumerated() { rank[block] = position }
        var idom = Array(repeating: -1, count: ranges.count)
        if let entry = order.first { idom[entry] = entry }
        // Cooper-Harvey-Kennedy immediate dominators in reverse postorder.
        // Unreachable blocks retain -1 and never enter an intersection.
        func intersect(_ left: Int, _ right: Int) -> Int {
            var a = left, b = right
            while a != b {
                while rank[a] > rank[b] { a = idom[a] }
                while rank[b] > rank[a] { b = idom[b] }
            }
            return a
        }
        var changed = true
        while changed {
            changed = false
            for block in order.dropFirst() {
                let known = blockPrevious[block].filter { idom[$0] >= 0 }
                guard var parent = known.first else { continue }
                for predecessor in known.dropFirst() { parent = intersect(parent, predecessor) }
                if idom[block] != parent { idom[block] = parent; changed = true }
            }
        }
        var children = Array(repeating: [Int](), count: ranges.count)
        for block in order where idom[block] != block { children[idom[block]].append(block) }
        var enter = Array(repeating: -1, count: ranges.count)
        var leave = enter
        var clock = 0
        traversal = order.first.map { [($0, false)] } ?? []
        while let frame = traversal.popLast() {
            if frame.exit { leave[frame.block] = clock; continue }
            enter[frame.block] = clock
            clock += 1
            traversal.append((frame.block, true))
            for child in children[frame.block].reversed() { traversal.append((child, false)) }
        }
        func dominatesInstruction(_ definition: Int, _ use: Int) -> Bool {
            guard visited.contains(definition), visited.contains(use) else { return false }
            let a = owner[definition], b = owner[use]
            if a == b { return definition <= use }
            return enter[a] <= enter[b] && enter[b] < leave[a]
        }
        var edges: [(from: Int, to: Int)] = []
        for node in visited.sorted() {
            for target in next[node] where dominatesInstruction(target, node) { edges.append((node, target)) }
        }
        error = nil
        successors = next
        predecessors = previous
        reachable = visited
        writes = definitions
        reads = references
        before = incoming
        backedges = edges
        blockOf = owner
        blockRanges = ranges
        blockPredecessors = blockPrevious
        immediateDominator = idom
        dominanceEntry = enter
        dominanceExit = leave
    }

    func dominates(_ definition: Int, _ use: Int) -> Bool {
        guard error == nil, reachable.contains(definition), reachable.contains(use) else { return false }
        let a = blockOf[definition], b = blockOf[use]
        if a == b { return definition <= use }
        return dominanceEntry[a] <= dominanceEntry[b] && dominanceEntry[b] < dominanceExit[a]
    }

    func joinDominators(of use: Int) -> [Int] {
        guard error == nil, reachable.contains(use) else { return [] }
        var block = blockOf[use]
        var result: [Int] = []
        while block >= 0 {
            let first = blockRanges[block].lowerBound
            if predecessors[first].filter({ reachable.contains($0) }).count > 1 { result.append(first) }
            let parent = immediateDominator[block]
            if parent == block { break }
            block = parent
        }
        return result.sorted()
    }

    func naturalLoop(from: Int, to: Int) -> Set<Int> {
        guard error == nil, reachable.contains(from), reachable.contains(to),
              successors[from].contains(to), dominates(to, from) else { return [] }
        let header = blockOf[to], latch = blockOf[from]
        var blocks: Set<Int> = [header, latch]
        var pending = header == latch ? [] : [latch]
        while let block = pending.popLast() {
            for predecessor in blockPredecessors[block] where immediateDominator[predecessor] >= 0 {
                if blocks.insert(predecessor).inserted, predecessor != header { pending.append(predecessor) }
            }
        }
        return blocks.reduce(into: Set<Int>()) { $0.formUnion(blockRanges[$1]) }
    }

    // Independent decoded-text effects, not a product-lifter admission. The
    // caller supplies canonical decoded operands; product byte/text agreement
    // remains a separate requirement. LD1 H reads the old 128-bit carrier,
    // replaces just two bytes, and optionally updates the captured X base.
    private static func validHalfwordLaneLoad(_ operands: [String]) -> Bool {
        guard operands.count == 2 || operands.count == 3 else { return false }
        let compact = operands.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard compact[0].range(of: #"^\{\s*v([0-9]|[12][0-9]|3[01])\.h\s*\}\[[0-7]\]$"#,
                               options: .regularExpression) != nil,
              compact[1].range(of: #"^\[x([0-9]|[12][0-9]|30)\]$"#,
                               options: .regularExpression) != nil else { return false }
        if compact.count == 2 { return true }
        return ["#2", "#0x2"].contains(compact[2])
            || compact[2].range(of: #"^x([0-9]|[12][0-9]|30)$"#,
                                options: .regularExpression) != nil
    }

    static func canonicalRegister(_ token: String) -> String? {
        let name = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "sp" || name == "wsp" { return "sp" }
        if name == "fp" { return "x29" }
        if name == "lr" { return "x30" }
        if ["xzr", "wzr"].contains(name) { return nil }
        if ["nzcv", "fpcr", "fpsr"].contains(name) { return name }
        guard let prefix = name.first, let index = Int(name.dropFirst()), index >= 0 else { return nil }
        if (prefix == "x" || prefix == "w"), index <= 30 { return "x\(index)" }
        if "vqbhsd".contains(prefix), index <= 31 { return "v\(index)" }
        return nil
    }

    private static func registers(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .compactMap { canonicalRegister(String($0)) })
    }

    private static func operands(_ text: String) -> [String] {
        let text = text.components(separatedBy: ";")[0].components(separatedBy: "//")[0]
        var result: [String] = [], current = "", depth = 0
        for character in text {
            if character == "[" || character == "{" { depth += 1 }
            if character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(character) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",") {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func targetAddress(_ text: String) -> UInt64? {
        let token = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "<" }).first.map(String.init) ?? ""
        if token.lowercased().hasPrefix("0x") { return UInt64(token.dropFirst(2), radix: 16) }
        return UInt64(token)
    }

    private static func validNarrowRoundOperands(_ mnemonic: String, _ operands: [String]) -> Bool {
        let extract = ["sqxtun", "sqxtun2"].contains(mnemonic)
        guard operands.count == (extract ? 2 : 3) else { return false }
        func arrangement(_ operand: String) -> String? {
            let parts = operand.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].first == "v",
                  let index = Int(parts[0].dropFirst()), (0...31).contains(index),
                  parts[0] == "v\(index)" else { return nil }
            return String(parts[1])
        }
        guard let destination = arrangement(operands[0]), let source = arrangement(operands[1]) else { return false }
        if mnemonic == "smlsl2" {
            return ["8h": "16b", "4s": "8h", "2d": "4s"][destination] == source
                && arrangement(operands[2]) == source
        }
        let high = mnemonic.hasSuffix("2")
        let narrow = high ? ["16b": "8h", "8h": "4s", "4s": "2d"]
                          : ["8b": "8h", "4h": "4s", "2s": "2d"]
        if ["raddhn", "raddhn2", "subhn", "subhn2"].contains(mnemonic) {
            return narrow[destination] == source && arrangement(operands[2]) == source
        }
        if extract { return narrow[destination] == source }
        let bits: Int
        let minimum: Int
        let maximum: Int
        if mnemonic == "sqshlu" {
            guard destination == source,
                  let width = ["8b": 8, "16b": 8, "4h": 16, "8h": 16,
                               "2s": 32, "4s": 32, "2d": 64][destination] else { return false }
            bits = width; minimum = 0; maximum = bits - 1
        } else {
            guard ["rshrn2", "shrn2", "sqshrn2"].contains(mnemonic),
                  narrow[destination] == source,
                  let width = ["16b": 8, "8h": 16, "4s": 32][destination] else { return false }
            bits = width; minimum = 1; maximum = bits
        }
        guard operands[2].hasPrefix("#") else { return false }
        let immediate = operands[2].dropFirst()
        let shift = immediate.hasPrefix("0x") ? Int(immediate.dropFirst(2), radix: 16) : Int(immediate)
        return shift.map { (minimum...maximum).contains($0) } ?? false
    }

    private static func semantics(_ mnemonic: String, _ operands: [String])
        -> (reads: Set<String>, writes: Set<String>, error: String?) {
        let all = operands.reduce(into: Set<String>()) { $0.formUnion(registers($1)) }
        let first = operands.first.map(registers) ?? []
        let rest = operands.dropFirst().reduce(into: Set<String>()) { $0.formUnion(registers($1)) }
        // Arm A64 Operation: smlsl, raddhn, rshrn, shrn, subhn, sqxtun,
        // sqshrn and sqshlu. Independent operand validation, never lifted IR.
        // High-half narrows consume Vd. Saturation preserves the other FPSR bits
        // and its old sticky QC, so this whole-register model reads and writes FPSR.
        if ["smlsl2", "raddhn", "rshrn2", "raddhn2", "subhn", "subhn2",
            "shrn2", "sqxtun", "sqxtun2", "sqshrn2", "sqshlu"].contains(mnemonic) {
            guard validNarrowRoundOperands(mnemonic, operands) else {
                return ([], [], "invalid narrow or wide vector operands")
            }
            var read = mnemonic.hasSuffix("2") ? all : rest
            var written = first
            if ["sqxtun", "sqxtun2", "sqshrn2", "sqshlu"].contains(mnemonic) {
                read.insert("fpsr"); written.insert("fpsr")
            }
            return (read, written, nil)
        }
        if ["nop", "hint", "bti", "dmb", "dsb", "isb", "yield"].contains(mnemonic) { return ([], [], nil) }
        if ["b", "b.al", "b.nv"].contains(mnemonic) { return ([], [], nil) }
        let conditions: Set<String> = ["eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]
        if mnemonic.hasPrefix("b."), conditions.contains(String(mnemonic.dropFirst(2))) { return (["nzcv"], [], nil) }
        if ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) { return (first, [], nil) }
        if ["ret", "retaa", "retab"].contains(mnemonic) {
            let inputs = all.isEmpty ? Set(["x30"]) : all
            return (mnemonic == "ret" ? inputs : inputs.union(["sp"]), [], nil)
        }
        if ["br", "braa", "brab", "braaz", "brabz"].contains(mnemonic) { return (all, [], nil) }
        if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic) {
            // Darwin reserves x18; the volatile general-purpose bank ends at x17.
            var clobbers = Set((0...17).map { "x\($0)" } + ["x30", "nzcv"])
            clobbers.formUnion((0...7).map { "v\($0)" }); clobbers.formUnion((16...31).map { "v\($0)" })
            // Argument consumption is contract-dependent. Operand registers (indirect target and
            // authentication modifier) are certain reads; callers inspect typed arguments separately.
            return (mnemonic == "bl" ? [] : all, clobbers, nil)
        }
        if ["cmp", "cmn", "tst"].contains(mnemonic) { return (all, ["nzcv"], nil) }
        if ["ccmp", "ccmn", "fccmp", "fccmpe"].contains(mnemonic) { return (all.union(["nzcv"]), ["nzcv"], nil) }
        if ["fcmp", "fcmpe"].contains(mnemonic) { return (all, ["nzcv"], nil) }
        if ["mrs", "msr"].contains(mnemonic) {
            guard operands.count == 2, all.contains("nzcv"), !all.contains("fpcr"), !all.contains("fpsr") else {
                return ([], [], "unsupported system register access")
            }
            return (rest, first, nil)
        }
        if ["paciasp", "pacibsp", "autiasp", "autibsp"].contains(mnemonic) { return (["sp", "x30"], ["x30"], nil) }
        if ["xpaclri"].contains(mnemonic) { return (["x30"], ["x30"], nil) }
        let loads: Set<String> = ["ldr", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldur", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw", "ldp", "ldpsw", "ldnp", "ldar", "ldarb", "ldarh"]
        let stores: Set<String> = ["str", "strb", "strh", "stur", "sturb", "sturh", "stp", "stnp", "stlr", "stlrb", "stlrh"]
        let vectorLoad: Set<String> = ["ld1", "ld2", "ld3", "ld4", "ld1r", "ld2r", "ld3r", "ld4r"]
        let vectorStore: Set<String> = ["st1", "st2", "st3", "st4"]
        if loads.contains(mnemonic) || stores.contains(mnemonic) || vectorLoad.contains(mnemonic) || vectorStore.contains(mnemonic) {
            if operands.contains(where: { $0.contains("{") && $0.contains("-") }) {
                return ([], [], "vector register-list range requires expansion")
            }
            guard let memory = operands.firstIndex(where: { $0.hasPrefix("[") }) else {
                // PC-relative literal loads have no base register.
                if loads.contains(mnemonic), operands.count == 2, targetAddress(operands[1]) != nil { return ([], first, nil) }
                return ([], [], "unrecognized memory operand")
            }
            if vectorLoad.contains(mnemonic), operands.prefix(memory).contains(where: { $0.contains("]") }) {
                guard mnemonic == "ld1", validHalfwordLaneLoad(operands) else {
                    return ([], [], "partial vector lane load")
                }
                // A whole-register reaching definition denotes the resulting
                // RMW value, not a claim that untouched lanes were overwritten.
                // all includes old Vd, old Xn and optional old Xm (even Xm==Xn).
                let writeback = operands.count == 3 ? registers(operands[1]) : []
                return (all, first.union(writeback), nil)
            }
            let transferred = operands.prefix(memory).reduce(into: Set<String>()) { $0.formUnion(registers($1)) }
            let addressReads = operands.dropFirst(memory).reduce(into: Set<String>()) { $0.formUnion(registers($1)) }
            let isLoad = loads.contains(mnemonic) || vectorLoad.contains(mnemonic)
            var written = isLoad ? transferred : []
            if operands[memory].contains("!") || memory + 1 < operands.count {
                let baseText = operands[memory].dropFirst().split(separator: ",").first.map(String.init) ?? ""
                let base = registers(baseText)
                guard base.count == 1 else { return ([], [], "unrecognized writeback base") }
                written.formUnion(base)
            }
            return (isLoad ? addressReads : all, written, nil)
        }
        if mnemonic == "prfm" || mnemonic == "prfum" { return (all, [], nil) }
        let unaryAndBinary: Set<String> = [
            "mov", "movz", "movn", "adr", "adrp", "add", "sub", "mul", "madd", "msub", "mneg", "smull", "umull", "smulh", "umulh", "smaddl", "umaddl", "smsubl", "umsubl", "sdiv", "udiv",
            "and", "orr", "eor", "bic", "orn", "eon", "mvn", "neg", "lsl", "lsr", "asr", "ror", "lslv", "lsrv", "asrv", "rorv", "extr", "ubfx", "sbfx", "ubfiz", "sbfiz", "ubfm", "sbfm", "uxtb", "uxth", "uxtw", "sxtb", "sxth", "sxtw", "clz", "cls", "rbit", "rev", "rev16", "rev32",
            "fmov", "fabs", "fneg", "fsqrt", "fadd", "fsub", "fmul", "fdiv", "fmadd", "fmsub", "fnmadd", "fnmsub", "fnmul", "fcvt", "fcvtzs", "fcvtzu", "fcvtns", "fcvtnu", "fcvtms", "fcvtmu", "fcvtps", "fcvtpu", "scvtf", "ucvtf", "fmax", "fmin", "fmaxnm", "fminnm", "frintn", "frintm", "frintp", "frintz", "frinta", "frintx", "frinti",
            "dup", "umov", "smov", "movi", "mvni", "ext", "tbl", "zip1", "zip2", "uzp1", "uzp2", "trn1", "trn2", "cnt", "not", "abs", "sabs", "uaddlp", "saddlp", "uaddlv", "saddlv", "addv", "smax", "umax", "smin", "umin", "smaxv", "umaxv", "sminv", "uminv", "cmeq", "cmge", "cmgt", "cmhi", "cmhs", "cmle", "cmlt", "cmtst", "shl", "sshr", "ushr", "srshr", "urshr", "sli", "sri", "sshl", "ushl", "srshl", "urshl", "sqshl", "uqshl", "sqrshl", "uqrshl", "sqadd", "uqadd", "sqsub", "uqsub", "shadd", "uhadd", "srhadd", "urhadd", "shsub", "uhsub", "sabd", "uabd", "saddl", "uaddl", "ssubl", "usubl", "saddw", "uaddw", "ssubw", "usubw", "sxtl", "uxtl", "sshll", "ushll", "shrn", "rshrn", "sqshrn", "uqshrn", "sqrshrn", "uqrshrn", "sqshrun", "sqrshrun", "xtn", "sqxtn", "uqxtn", "sqxtun", "sqdmulh", "sqrdmulh", "addp", "faddp", "fmaxp", "fminp"
        ]
        let upperHalfAndNarrowing: Set<String> = [
            "ushll2", "sshll2", "smull2", "umull2", "uaddw2", "saddl2", "uxtl2", "sxtl2",
            "usubl2", "ssubl2", "uaddl2", "usubw2", "ssubw2", "saddw2", "addhn"
        ]
        let readModifyWrite: Set<String> = ["movk", "bfi", "bfxil", "bfm", "mla", "mls", "smlal", "umlal", "smlsl", "umlsl", "sabal", "uabal", "sadalp", "uadalp", "ssra", "usra", "srsra", "ursra", "bsl", "bit", "bif", "fmla", "fmls",
            "umlal2", "smlal2", "udot", "sdot", "ins", "addhn2"]
        let conditional: Set<String> = ["csel", "csinc", "csinv", "csneg", "cset", "csetm", "cinc", "cinv", "cneg", "fcsel"]
        let carry: Set<String> = ["adc", "adcs", "sbc", "sbcs", "ngc", "ngcs"]
        let flags: Set<String> = ["adds", "subs", "ands", "bics", "negs", "adcs", "sbcs", "ngcs"]
        if unaryAndBinary.contains(mnemonic) || upperHalfAndNarrowing.contains(mnemonic) || readModifyWrite.contains(mnemonic) || conditional.contains(mnemonic) || carry.contains(mnemonic) || flags.contains(mnemonic) {
            guard !operands.isEmpty else { return ([], [], "missing data operands") }
            if mnemonic != "ins", operands[0].contains("["), !first.isDisjoint(with: Set((0...31).map { "v\($0)" })) {
                return ([], [], "partial vector destination")
            }
            var read = rest
            if readModifyWrite.contains(mnemonic) || ["sli", "sri"].contains(mnemonic) { read.formUnion(first) }
            if conditional.contains(mnemonic) || carry.contains(mnemonic) { read.insert("nzcv") }
            var written = first
            if flags.contains(mnemonic) { written.insert("nzcv") }
            return (read, written, nil)
        }
        return ([], [], "unsupported machine mnemonic \(mnemonic)")
    }
}

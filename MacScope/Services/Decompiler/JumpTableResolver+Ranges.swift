import Foundation

/// A bounded, conservative signed-W interval analysis. Relations are affine
/// modulo 2^32 within a block and through a separately proved affine hull at
/// joins. The hull is formed from all predecessors, never guessed from a loop.
/// SUBS predicates compare the original operands, preserving N != V semantics.
enum JumpTableRangeAnalysis {
    private static let low = Int64(Int32.min), high = Int64(Int32.max)
    private struct Interval: Equatable {
        var lo: Int64; var hi: Int64
        static var top: Self { .init(lo: low, hi: high) }
        func meet(_ other: Self) -> Self? {
            let a = max(lo, other.lo), b = min(hi, other.hi)
            return a <= b ? .init(lo: a, hi: b) : nil
        }
        func shifted(_ delta: Int64) -> Self {
            let a = lo + delta, b = hi + delta
            if a >= low && b <= high { return .init(lo: a, hi: b) }
            if a > high && b <= high + 4_294_967_296 { return .init(lo: a - 4_294_967_296, hi: b - 4_294_967_296) }
            if b < low && a >= low - 4_294_967_296 { return .init(lo: a + 4_294_967_296, hi: b + 4_294_967_296) }
            return .top
        }
    }
    private struct Value: Equatable {
        var range = Interval.top
        var zeroExtended = false
    }
    private struct Local {
        var value: Value
        var origin: Int
        var delta: Int64 = 0
    }
    private struct Comparison {
        var left: Local
        var right: Int64
    }
    private static func register(_ text: String) -> Int? {
        guard text.first == "w" || text.first == "x", let n = Int(text.dropFirst()),
              (0...30).contains(n), text == "\(text.first!)\(n)" else { return nil }
        return n
    }
    private static func operands(_ text: String) -> [String] { MacIRBuilder.splitOperands(text.lowercased()) }
    private static func immediate(_ text: String) -> Int64? { MacIRBuilder.parseImmediate(text) }
    private static func target(_ row: some DecompilerInstructionRow) -> UInt64? {
        guard let text = operands(row.operands).last else { return nil }
        return text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
    private static func condition(_ name: String, bound: Int64, taken: Bool) -> [Interval]? {
        guard (0...high).contains(bound) else { return nil }
        let inverse = ["eq":"ne", "ne":"eq", "lt":"ge", "ge":"lt", "gt":"le", "le":"gt",
                       "hi":"ls", "ls":"hi", "hs":"lo", "cs":"lo", "lo":"hs", "cc":"hs"]
        let name = taken ? name : (inverse[name] ?? "")
        func span(_ a: Int64, _ b: Int64) -> [Interval] { a <= b ? [.init(lo: a, hi: b)] : [] }
        switch name {
        case "eq": return span(bound, bound)
        case "ne": return span(low, bound - 1) + span(bound + 1, high)
        case "lt": return span(low, bound - 1)
        case "le": return span(low, bound)
        case "gt": return span(bound + 1, high)
        case "ge": return span(bound, high)
        case "hi": return span(low, -1) + span(bound + 1, high)
        case "hs", "cs": return span(low, -1) + span(bound, high)
        case "lo", "cc": return span(0, bound - 1)
        case "ls": return span(0, bound)
        default: return nil
        }
    }

    static func prove<Row: DecompilerInstructionRow>(rows: [Row], dispatchIndex: Int,
        jumpTables: [UInt64: [UInt64]]) -> JumpTableSelectorProof? {
        guard (1...1024).contains(rows.count), rows.indices.contains(dispatchIndex),
              rows[dispatchIndex].mnemonic.lowercased() == "br",
              rows.filter({ $0.mnemonic.lowercased() == "br" }).count == 1 else { return nil }
        let addresses = Dictionary(rows.enumerated().map { ($0.element.address, $0.offset) }, uniquingKeysWith: { a, _ in a })
        guard addresses.count == rows.count else { return nil }
        for i in 1..<rows.count { guard rows[i-1].address.isContiguous(to: rows[i].address) else { return nil } }
        // The idiom resolver separately proves base/entry/anchor dataflow.
        // Here locate exactly one indexed load in its straight-line suffix.
        var loads: [(Int, String)] = []
        var cursor = dispatchIndex - 1
        while cursor >= 0 && dispatchIndex - cursor <= 24 {
            let m = rows[cursor].mnemonic.lowercased(), ops = operands(rows[cursor].operands)
            if m == "b" || m.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz", "br", "ret"].contains(m) { break }
            if ["ldr", "ldrb", "ldrh", "ldrsw"].contains(m), ops.count == 2,
               ops[1].hasPrefix("["), ops[1].hasSuffix("]") {
                let memory = operands(String(ops[1].dropFirst().dropLast()))
                if memory.count >= 2, register(memory[1]) != nil { loads.append((cursor, memory[1])) }
            }
            cursor -= 1
        }
        guard loads.count == 1, let load = loads.first, load.0 > 0,
              let indexRegister = register(load.1) else { return nil }
        // No recovered edge may enter the middle of the table setup suffix.
        // Otherwise range bounds alone would not prove the reaching base/anchor.
        let protectedStart = rows[cursor + 1].address
        if jumpTables.values.joined().contains(where: {
            $0 > protectedStart && $0 <= rows[dispatchIndex].address
        }) { return nil }
        var leaders: Set<Int> = [0]
        for (i, row) in rows.enumerated() {
            let m = row.mnemonic.lowercased()
            if m == "b" || m.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(m) {
                guard let address = target(row), let destination = addresses[address] else { return nil }
                leaders.insert(destination); if i + 1 < rows.count { leaders.insert(i + 1) }
            } else if m == "ret" || m == "br" {
                if i + 1 < rows.count { leaders.insert(i + 1) }
                for address in jumpTables[row.address] ?? [] {
                    guard let destination = addresses[address] else { return nil }; leaders.insert(destination)
                }
            } else if m.hasPrefix("br") || m.hasPrefix("bl") || m.hasPrefix("ret") || m.hasPrefix("eret")
                || m.hasPrefix("bc.") || ["unknown", "unavailable", "hint", "svc", "hvc", "smc", "hlt"].contains(m) { return nil }
        }
        let starts = leaders.sorted()
        let blockFor = Dictionary(starts.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var incoming: [Int: [Value]] = [0: Array(repeating: Value(), count: 31)]
        var affineIncoming: [Int: JumpTableAffineState] = [0: JumpTableAffineState()]
        var queue = [0], iterations = 0
        var beforeLoad: Value?
        while !queue.isEmpty {
            iterations += 1; guard iterations <= starts.count * 64 else { return nil }
            let block = queue.removeFirst(), start = starts[block]
            let end = block + 1 < starts.count ? starts[block + 1] : rows.count
            guard let values = incoming[block] else { continue }
            var state = values.enumerated().map { Local(value: $0.element, origin: $0.offset) }
            var affine = affineIncoming[block] ?? JumpTableAffineState()
            var comparison: Comparison?
            func refine(_ name: String, taken: Bool) -> [Value]? {
                guard let comparison, let restrictions = condition(name, bound: comparison.right, taken: taken) else {
                    return state.map(\.value)
                }
                let intersections = restrictions.compactMap { comparison.left.value.range.meet($0) }
                guard let lo = intersections.map(\.lo).min(), let hi = intersections.map(\.hi).max() else { return nil }
                let restricted = Interval(lo: lo, hi: hi)
                var result = state.map(\.value)
                for i in state.indices where state[i].origin == comparison.left.origin {
                    let mapped = restricted.shifted(state[i].delta - comparison.left.delta)
                    guard let range = result[i].range.meet(mapped) else { return nil }
                    result[i].range = range
                }
                return result
            }
            for i in start..<end {
                if i == load.0 { beforeLoad = state[indexRegister].value }
                let row = rows[i], m = row.mnemonic.lowercased(), ops = operands(row.operands)
                let destination = ops.first.flatMap(register)
                let oldState = state
                let oldAffine = affine
                // All other writes are poison, including memory writeback bases.
                for written in JumpTableResolver.rangeWrittenRegisters(row) {
                    if let r = written == "fp" ? 29 : (written == "lr" ? 30 : register(written)) {
                        state[r] = Local(value: Value(range: .top, zeroExtended: written.first == "w"), origin: 31 + i * 31 + r)
                        affine.forget(r)
                    }
                }
                // Transfer only exact, unshifted scalar forms. An X operation
                // proves low32 relations but never by itself proves upper32=0.
                var affineTerms: [(Int, UInt32)]?
                var affineConstant: UInt32 = 0
                if ["add", "sub", "adds", "subs"].contains(m), ops.count == 3,
                   let d = destination, let source = register(ops[1]),
                   ops[0].first == ops[1].first {
                    let subtract = m == "sub" || m == "subs"
                    if let imm = immediate(ops[2]), (0...4095).contains(imm) {
                        affineTerms = [(source, 1)]
                        affineConstant = UInt32(truncatingIfNeeded: subtract ? -imm : imm)
                    } else if let second = register(ops[2]), ops[0].first == ops[2].first {
                        affineTerms = [(source, 1), (second, subtract ? UInt32.max : 1)]
                    }
                    if let terms = affineTerms {
                        affine = oldAffine; affine.assign(d, terms: terms, constant: affineConstant)
                    }
                } else if m == "mov", ops.count == 2, let d = destination {
                    if let source = register(ops[1]), ops[0].first == ops[1].first {
                        affineTerms = [(source, 1)]
                    } else if let imm = immediate(ops[1]), (low...high).contains(imm) {
                        affineTerms = []; affineConstant = UInt32(truncatingIfNeeded: imm)
                    }
                    if let terms = affineTerms {
                        affine = oldAffine; affine.assign(d, terms: terms, constant: affineConstant)
                    }
                }
                if m == "cmp", ops.count == 2, ops[0].first == "w", let r = register(ops[0]), let imm = immediate(ops[1]) {
                    comparison = Comparison(left: oldState[r], right: imm)
                } else if ["add", "sub", "adds", "subs"].contains(m), ops.count == 3,
                          ops[0].first == "w", ops[1].first == "w", let d = destination,
                          let source = register(ops[1]), let imm = immediate(ops[2]), (0...4095).contains(imm) {
                    let delta = (m == "sub" || m == "subs") ? -imm : imm
                    var value = oldState[source]; value.delta += delta
                    value.value.range = value.value.range.shifted(delta); value.value.zeroExtended = true
                    state[d] = value
                    if m == "subs" { comparison = Comparison(left: oldState[source], right: imm) }
                    else if m == "adds" { comparison = nil }
                } else if m == "mov", ops.count == 2, let d = destination {
                    if let source = register(ops[1]), ops[0].first == ops[1].first {
                        state[d] = oldState[source]
                        if ops[0].first == "w" { state[d].value.zeroExtended = true }
                    } else if let imm = immediate(ops[1]), (low...high).contains(imm) {
                        state[d] = Local(value: Value(range: .init(lo: imm, hi: imm), zeroExtended: ops[0].first == "w" || imm >= 0), origin: 31 + i * 31 + d)
                    }
                } else if !["b", "ret", "br", "nop", "adr", "adrp", "add", "sub"].contains(m)
                    && !m.hasPrefix("b.") && !m.hasPrefix("ldr") && !m.hasPrefix("str")
                    && !["ldp", "stp"].contains(m) {
                    // Unknown flags never refine a branch. SIMD rows may be
                    // conservatively forgotten here without affecting soundness.
                    comparison = nil
                }
                if let d = destination, let terms = affineTerms {
                    // An expression equal to r+k modulo 2^32 inherits exactly
                    // the signed interval image of r. This remains valid over
                    // wraparound because shifted() splits or returns top.
                    var range = state[d].value.range
                    if let constant = oldAffine.constant(terms: terms, offset: affineConstant) {
                        let signed = Int64(Int32(bitPattern: constant))
                        range = range.meet(Interval(lo: signed, hi: signed)) ?? .top
                    }
                    for r in oldState.indices {
                        if let delta = oldAffine.constant(terms: terms + [(r, UInt32.max)], offset: affineConstant) {
                            let mapped = oldState[r].value.range.shifted(Int64(Int32(bitPattern: delta)))
                            range = range.meet(mapped) ?? .top
                        }
                    }
                    state[d].value.range = range
                }
            }
            let last = rows[end-1], m = last.mnemonic.lowercased()
            var edges: [(Int, [Value])] = []
            func add(_ instruction: Int, _ values: [Value]?) {
                if let values, let to = blockFor[instruction] { edges.append((to, values)) }
            }
            if m == "b" { add(addresses[target(last)!]!, state.map(\.value)) }
            else if m.hasPrefix("b.") {
                let conditionName = String(m.dropFirst(2))
                add(addresses[target(last)!]!, refine(conditionName, taken: true))
                if end < rows.count { add(end, refine(conditionName, taken: false)) }
            } else if ["cbz", "cbnz", "tbz", "tbnz"].contains(m) {
                add(addresses[target(last)!]!, state.map(\.value)); if end < rows.count { add(end, state.map(\.value)) }
            } else if m == "br" {
                for address in jumpTables[last.address] ?? [] { add(addresses[address]!, state.map(\.value)) }
            } else if m != "ret", end < rows.count { add(end, state.map(\.value)) }
            for (to, new) in edges {
                var joined = new
                var joinedAffine = affineIncoming[to] ?? affine
                let affineChanged = affineIncoming[to] == nil || joinedAffine.join(affine)
                if let old = incoming[to] {
                    for i in joined.indices {
                        var lo = min(old[i].range.lo, new[i].range.lo), hi = max(old[i].range.hi, new[i].range.hi)
                        // Widen only cyclic/reverse-address propagation. Finite
                        // forward joins retain both paths' useful bounds.
                        if to <= block {
                            if lo < old[i].range.lo { lo = low }; if hi > old[i].range.hi { hi = high }
                        }
                        // Low32 affine equality does not prove X upper bits. A
                        // predecessor entering at/before CMP after a W write
                        // must retain its independent zero-extension state.
                        joined[i] = Value(range: .init(lo: lo, hi: hi), zeroExtended: old[i].zeroExtended && new[i].zeroExtended)
                    }
                    if joined == old && !affineChanged { continue }
                }
                affineIncoming[to] = joinedAffine
                incoming[to] = joined; if !queue.contains(to) { queue.append(to) }
            }
        }
        guard let value = beforeLoad, value.range.lo >= 0, value.range.hi < 4096,
              load.1.first == "w" || value.zeroExtended else { return nil }
        return JumpTableSelectorProof(definitionAddress: rows[load.0 - 1].address,
            register: load.1, caseCount: Int(value.range.hi) + 1, guardKind: .boundedRange)
    }
}

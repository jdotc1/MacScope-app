import Foundation

/// New exact-original entry oracle. The source side is the five frozen rows at
/// 0x30150, not a relocated synthetic stream or a general ARM interpreter.
/// SOURCE ONLY / NOT RUN. Candidate numbers come only from parsed emitted C.
enum NativeScalarEntryOracle {
    typealias C = OrdinaryC
    typealias L = OrdinaryCSourceEdgeLedger
    typealias B = NativeScalarOriginalBindings
    enum Role: Hashable { case source, destination, count, data }
    enum Finish: Equatable { case returned, backedges(Int) }
    struct Input {
        let source: UInt64
        let destination: UInt64
        let count: UInt32
        let memory: [UInt64: UInt8]
        var physical: [Int: UInt64] { [1: source, 2: destination, 3: UInt64(count)] }
    }
    struct Write: Equatable {
        let row: Int
        let slot: Int
        let width: Int
        let bits: UInt64
    }
    struct Reference {
        var memory: [UInt64: UInt8]
        var events: [C.Event] = []
        var writes: [Write] = []
        var edges: [C.SourceEdge] = []
        var finish: Finish?
    }
    struct Slot {
        let row: Int
        let ordinal: Int
        let width: Int
        let pc: Int
        let span: C.Span
        let name: String
    }
    struct Route {
        let pcs: [Int]
        let transfers: [C.Transfer]
        let destination: Int
        let edge: C.SourceEdge
    }
    struct Binding {
        let header: Int // First owned row0 operation, not merely the load span.
        let terminal: Int
        let routes: [Route]
        let slots: [Slot]
    }
    struct PrefixObservation {
        let result: C.Result
        let edges: [C.SourceEdge]
        let stopPC: Int
        let occurrence: Int
    }
    private struct Definition {
        let pc: Int
        let span: C.Span
        let row: Int?
        let name: String
        let expression: C.Expression
    }
    static let backedge = C.SourceEdge(fromBlock: 0, toBlock: 0, successorOrdinal: 0)
    static let exitEdge = C.SourceEdge(fromBlock: 0, toBlock: 1, successorOrdinal: 1)

    static func validateOriginal(_ fixture: NativeScalarFixture, bound: B.Bound) throws {
        let expected = [
            ("28 44 40 b8", "ldr", "w8, [x1], #4"),
            ("48 14 00 38", "strb", "w8, [x2], #1"),
            ("63 04 00 71", "subs", "w3, w3, #1"),
            ("a1 ff ff 54", "b.ne", "0x0000000000030150"),
            ("c0 03 5f d6", "ret", "")]
        guard fixture.capture.start == "0x30150", fixture.rows.count == expected.count,
              zip(fixture.rows, expected).allSatisfy({ pair in
                  pair.0.bytes.lowercased() == pair.1.0 && pair.0.mnemonic == pair.1.1 && pair.0.operands == pair.1.2
              }), Set(bound.inputs.map(\.register)) == [1, 2, 3],
              bound.inputs.allSatisfy({ $0.initializedWidth == ($0.register == 3 ? 32 : 64) }),
              bound.inventory.source.origins == [
                L.Origin(edge: backedge, row: 3, role: .taken),
                L.Origin(edge: exitEdge, row: 3, role: .notTaken)],
              bound.inventory.source.returns == [4], bound.inventory.flagWriters == [3: 2],
              case .unavailableReturnContract = bound.manifest.terminal else {
            throw C.Failure.invalidContract("exact30150 original identity/ABI/edge/terminal changed")
        }
    }

    /// Literal recurrence reused from the historical entry test's source-side
    /// algorithm, now independently bound to the fresh original five-row stream.
    /// W3 arithmetic is modulo32; pointer writes are modulo64. No C names or IR
    /// arithmetic values are inputs. Every load reads the current byte memory.
    static func reference(_ input: Input, finish: Finish) throws -> Reference {
        let iterations: Int
        switch finish {
        case .returned:
            guard (1...3).contains(input.count) else { throw C.Failure.invalidContract("first complete entry scope is count1/2/3") }
            iterations = Int(input.count)
        case let .backedges(count):
            guard count == 2 else { throw C.Failure.invalidContract("first entry prefix requires two taken source edges") }
            iterations = count
        }
        var r = Reference(memory: input.memory), source = input.source, destination = input.destination
        var remaining = input.count
        for occurrence in 0..<iterations {
            guard source <= UInt64.max - 3 else { throw C.Failure.invalidContract("reference load crosses address-space end") }
            var loaded: UInt64 = 0
            for offset in 0..<4 {
                guard let byte = r.memory[source + UInt64(offset)] else { throw C.Failure.uninitializedRead("literal source byte") }
                loaded |= UInt64(byte) << (offset * 8)
            }
            r.events.append(.load(.init(row: 0, effectOrdinal: 0), occurrence, source, 4, loaded))
            r.writes.append(.init(row: 0, slot: 0, width: 32, bits: loaded))
            source &+= 4
            r.writes.append(.init(row: 0, slot: 1, width: 64, bits: source))
            let byte = UInt8(truncatingIfNeeded: loaded)
            r.events.append(.store(.init(row: 1, effectOrdinal: 0), occurrence, destination, 1, UInt64(byte)))
            r.memory[destination] = byte
            destination &+= 1
            r.writes.append(.init(row: 1, slot: 0, width: 64, bits: destination))
            remaining &-= 1
            r.writes.append(.init(row: 2, slot: 0, width: 32, bits: UInt64(remaining)))
            let taken = remaining != 0
            r.edges.append(taken ? backedge : exitEdge)
            if !taken {
                guard finish == .returned, occurrence + 1 == iterations else {
                    throw C.Failure.invalidContract("requested prefix returns before its second taken source edge")
                }
                r.finish = .returned
            }
        }
        if case .backedges = finish {
            guard r.edges == [backedge, backedge] else { throw C.Failure.invalidContract("prefix source edges are not both taken") }
            r.finish = finish
        }
        guard r.finish == finish else { throw C.Failure.invalidContract("literal entry did not establish requested observation") }
        return r
    }

    private static func children(_ e: C.Expression) -> [C.Expression] {
        switch e.node {
        case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): return [e]
        case let .binary(_, a, b): return [a, b]
        case let .select(c, a, b): return [c, a, b]
        case let .helper(_, args): return args
        default: return []
        }
    }
    private static func loads(_ e: C.Expression) -> [C.Expression] {
        let own: [C.Expression]
        if case .load = e.node { own = [e] } else { own = [] }
        return own + children(e).flatMap(loads)
    }
    private static func transport(_ e: C.Expression) -> Bool {
        switch e.node { case .name: return true; case let .cast(_, e): return transport(e); default: return false }
    }
    private static func hasUpdate(_ e: C.Expression) -> Bool {
        if case .update = e.node { return true }
        return children(e).contains(where: hasUpdate)
    }
    private static func roles(_ e: C.Expression, names: [String: Set<Role>]) -> Set<Role> {
        switch e.node {
        case let .name(name), let .update(name, _, _): return names[name, default: []]
        case .load: return [.data] // Never confuse the loaded data with its address.
        default: return children(e).reduce(into: Set<Role>()) { $0.formUnion(roles($1, names: names)) }
        }
    }
    private static func sameTransfers(_ a: [C.Transfer], _ b: [C.Transfer]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { pair in
            pair.0.span == pair.1.span && pair.0.sourceRow == pair.1.sourceRow &&
                pair.0.taken == pair.1.taken && pair.0.destination == pair.1.destination
        }
    }

    /// Source-owned output mapping only. All AST definitions, including dead
    /// ones, participate in the role closure. No expected numerical result or
    /// architectural spelling is used to select a LHS or repair ambiguity.
    static func bind(_ program: C.Program, original: B.Bound) throws -> Binding {
        var definitions: [Definition] = [], branchPCs: [Int] = [], terminalPCs: [Int] = []
        var loadDefinitions: [Definition] = [], storePCs: [Int] = []
        for (pc, instruction) in program.code.enumerated() {
            let row = try? program.row(at: instruction.span)
            func append(_ name: String, _ expression: C.Expression, _ span: C.Span) {
                let d = Definition(pc: pc, span: span, row: row, name: name, expression: expression)
                definitions.append(d)
                if !loads(expression).isEmpty { loadDefinitions.append(d) }
            }
            switch instruction.node {
            case let .declaration(name, expression):
                if let expression {
                    guard !hasUpdate(expression) else { throw C.Failure.invalidContract("entry initializer contains an inline write") }
                    append(name, expression, instruction.span)
                }
            case let .assign(left, right):
                guard left.count == 1, right.count == 1 else { throw C.Failure.invalidContract("entry ownership admits scalar statements only") }
                guard !hasUpdate(left[0]), !hasUpdate(right[0]) else { throw C.Failure.invalidContract("entry assignment contains an inline write") }
                switch left[0].node {
                case let .name(name): append(name, right[0], left[0].span)
                case .load: storePCs.append(pc)
                default: throw C.Failure.invalidContract("unknown entry destination")
                }
            case let .update(e):
                guard case let .update(name, _, _) = e.node else { throw C.Failure.invalidContract("entry update is not one scalar write") }
                append(name, e, e.span)
            case let .branch(e, _, _):
                guard !hasUpdate(e) else { throw C.Failure.invalidContract("entry branch contains an inline write") }
                branchPCs.append(pc)
            case .unavailableReturn:
                guard row == 4 else { throw C.Failure.invalidContract("extra entry control/terminal") }
                terminalPCs.append(pc)
            case .nop, .jump: break
            case .call, .returned, .unresolved: throw C.Failure.invalidContract("extra entry control/terminal")
            }
        }
        guard branchPCs.count == 1, terminalPCs.count == 1, loadDefinitions.count == 1, storePCs.count == 1,
              let loaded = loadDefinitions.first, loaded.row == 0,
              let load = loads(loaded.expression).first, loads(loaded.expression).count == 1,
              case let .load(loadType, address) = load.node, loadType.width == 32,
              program.memorySites[load.span] == .init(row: 0, effectOrdinal: 0),
              program.memorySites.count == 2,
              try program.row(at: program.code[storePCs[0]].span) == 1 else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: missing unique original load/store/control sites")
        }
        var names: [String: Set<Role>] = [:]
        for input in original.inputs {
            let role: Role
            switch input.register { case 1: role = .source; case 2: role = .destination; case 3: role = .count
            default: throw C.Failure.invalidContract("entry ownership has an extra external role") }
            names[input.parameter.name] = [role]
        }
        var changed = true
        while changed {
            changed = false
            for d in definitions {
                let joined = names[d.name, default: []].union(roles(d.expression, names: names))
                if joined != names[d.name, default: []] { names[d.name] = joined; changed = true }
            }
        }
        guard roles(address, names: names) == [.source], roles(loaded.expression, names: names) == [.data] else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: load address/data roles are mixed or missing")
        }
        guard case let .assign(storeLeft, storeRight) = program.code[storePCs[0]].node,
              case let .load(storeType, storeAddress) = storeLeft[0].node, storeType.width == 8,
              program.memorySites[storeLeft[0].span] == .init(row: 1, effectOrdinal: 0),
              roles(storeAddress, names: names) == [.destination],
              roles(storeRight[0], names: names) == [.data] else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: store address/data roles are mixed or missing")
        }
        let branch = branchPCs[0], terminal = terminalPCs[0]
        guard case let .branch(condition, yes, no) = program.code[branch].node,
              try program.row(at: condition.span) == 3, roles(condition, names: names) == [.count] else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: latch lacks original count role")
        }
        func slot(row: Int, ordinal: Int, width: Int, role: Role, loading: Bool = false) throws -> Slot {
            let matching = definitions.filter { d in
                d.row == row && roles(d.expression, names: names) == [role] &&
                    (loading ? d.span == loaded.span : !transport(d.expression) && loads(d.expression).isEmpty)
            }
            guard matching.count == 1, let d = matching.first, let symbol = program.symbols[d.name],
                  !symbol.external, !symbol.type.pointer, symbol.type.width == width else {
                throw C.Failure.invalidContract("ENTRY_BINDING_GAP: ambiguous/missing source definition row\(row) slot\(ordinal) width\(width)")
            }
            return .init(row: row, ordinal: ordinal, width: width, pc: d.pc, span: d.span, name: d.name)
        }
        let slots = try [slot(row: 0, ordinal: 0, width: 32, role: .data, loading: true),
                         slot(row: 0, ordinal: 1, width: 64, role: .source),
                         slot(row: 1, ordinal: 0, width: 64, role: .destination),
                         slot(row: 2, ordinal: 0, width: 32, role: .count)]
        let ownedSpans = Set(slots.map(\.span))
        for d in definitions where !ownedSpans.contains(d.span) {
            guard transport(d.expression), roles(d.expression, names: names).count == 1 else {
                throw C.Failure.invalidContract("ENTRY_BINDING_GAP: extra nontransport scalar definition")
            }
        }
        let definitionAt = Dictionary(uniqueKeysWithValues: definitions.map { ($0.pc, $0) })
        func nextOriginal(from start: Int) throws -> Int {
            var pc = start, seen: Set<Int> = []
            while program.code.indices.contains(pc), seen.insert(pc).inserted {
                if pc == terminal { return pc }
                let instruction = program.code[pc], row = try? program.row(at: instruction.span)
                switch instruction.node {
                case .nop: pc += 1
                case let .jump(target): pc = target
                case .declaration, .assign, .update:
                    // Stop before ANY preparation of the next original row0,
                    // including a capture/copy before its actual load.
                    if row == 0 { return pc }
                    guard row == 3, let d = definitionAt[pc], transport(d.expression) else {
                        throw C.Failure.invalidContract("ENTRY_BINDING_GAP: edge contains an unowned original operation")
                    }
                    pc += 1
                default: throw C.Failure.invalidContract("ENTRY_BINDING_GAP: edge contains extra control")
                }
            }
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: edge has no next original row")
        }
        let yesNext = try nextOriginal(from: yes), noNext = try nextOriginal(from: no)
        guard (yesNext == terminal) != (noNext == terminal) else { throw C.Failure.invalidContract("entry latch does not map uniquely to backedge and exit") }
        let header = yesNext == terminal ? noNext : yesNext
        var routes: [Route] = []
        var work: [(Int, [Int], [C.Transfer], Set<Int>)] = [(header, [], [], [])]
        while let (pc, path, transfers, seen) = work.popLast() {
            if !path.isEmpty && (pc == header || pc == terminal) {
                guard path.filter({ $0 == storePCs[0] }).count == 1,
                      slots.allSatisfy({ s in path.filter { $0 == s.pc }.count == 1 }),
                      path.filter({ $0 == branch }).count == 1 else {
                    throw C.Failure.invalidContract("ENTRY_BINDING_GAP: route does not own every original definition/effect once")
                }
                routes.append(.init(pcs: path, transfers: transfers, destination: pc, edge: pc == header ? backedge : exitEdge)); continue
            }
            guard program.code.indices.contains(pc), !seen.contains(pc) else { throw C.Failure.invalidContract("entry route cycles outside original backedge") }
            let instruction = program.code[pc], path = path + [pc], seen = seen.union([pc])
            switch instruction.node {
            case let .branch(e, y, n):
                guard pc == branch else { throw C.Failure.invalidContract("extra entry branch") }
                for (taken, target) in [(true, y), (false, n)] {
                    work.append((target, path, transfers + [.init(span: e.span, sourceRow: 3, taken: taken, destination: target)], seen))
                }
            case let .jump(target):
                work.append((target, path, transfers + [.init(span: instruction.span, sourceRow: try? program.row(at: instruction.span), taken: nil, destination: target)], seen))
            case .returned, .unavailableReturn, .call, .unresolved: throw C.Failure.invalidContract("entry route has premature terminal/control")
            default: work.append((pc + 1, path, transfers, seen))
            }
        }
        guard routes.count == 2, Set(routes.map(\.edge)) == [backedge, exitEdge] else { throw C.Failure.invalidContract("entry route mapping is not singular") }
        // Prelude is executed, never seeded. It must establish locals only by
        // actual scalar transport and reach the first original row without effects.
        var pc = 0, seen: Set<Int> = []
        while pc != header {
            guard program.code.indices.contains(pc), seen.insert(pc).inserted else { throw C.Failure.invalidContract("entry prelude does not reach original row0") }
            switch program.code[pc].node {
            case .nop, .declaration(_, nil): pc += 1
            case .declaration, .assign:
                guard let d = definitionAt[pc], transport(d.expression) else { throw C.Failure.invalidContract("entry prelude contains a source effect") }
                pc += 1
            case let .jump(target): pc = target
            default: throw C.Failure.invalidContract("entry prelude has invented control/effect")
            }
        }
        return .init(header: header, terminal: terminal, routes: routes, slots: slots)
    }

    private struct Trace {
        let binding: Binding
        var started = false
        var path: [Int] = []
        var transferStart = 0
        var edges: [C.SourceEdge] = []
        var stopPC: Int?
        mutating func before(_ pc: Int, transfers: [C.Transfer], stopAfterBackedges: Int?) throws -> Bool {
            if !started {
                guard pc == binding.header else { return false }
                started = true; transferStart = transfers.count
            } else if pc == binding.header || pc == binding.terminal {
                let actual = Array(transfers.dropFirst(transferStart))
                let matching = binding.routes.filter { $0.destination == pc && $0.pcs == path && sameTransfers($0.transfers, actual) }
                guard matching.count == 1 else { throw C.Failure.invalidContract("actual entry path has no singular independently bound route") }
                edges.append(matching[0].edge)
                if let stopAfterBackedges, edges.filter({ $0 == backedge }).count == stopAfterBackedges {
                    guard pc == binding.header, edges.allSatisfy({ $0 == backedge }) else { throw C.Failure.invalidContract("prefix is not a complete taken-edge path") }
                    stopPC = pc; return true
                }
                path = []; transferStart = transfers.count
                if pc == binding.terminal { return false }
            }
            path.append(pc); return false
        }
    }

    static func prefix(program: C.Program, scenario: C.Scenario, binding: Binding, fuel: Int = 10_000) throws -> PrefixObservation {
        var machine = try C.Machine(program: program, scenario: scenario), trace = Trace(binding: binding)
        let result = try machine.execute(fuel: fuel, beforeInstruction: { pc, transfers in
            try trace.before(pc, transfers: transfers, stopAfterBackedges: 2)
        })
        guard trace.stopPC == binding.header, trace.edges == [backedge, backedge],
              !result.returned, !result.reachedRegionBoundary, result.terminal == nil,
              result.unavailableTerminal == nil, result.consumedResponses == 0 else {
            throw C.Failure.invalidContract("missing exact full-entry two-backedge prefix receipt")
        }
        return .init(result: result, edges: trace.edges, stopPC: binding.header, occurrence: 2)
    }

    /// Reconstruct the actual ordinary Machine trace; source numerical decisions
    /// are not consulted. Default whole-function execution remains untouched.
    static func completeEdges(program: C.Program, result: C.Result, binding: Binding) throws -> [C.SourceEdge] {
        guard result.returned, !result.reachedRegionBoundary else { throw C.Failure.invalidContract("not a complete entry observation") }
        var trace = Trace(binding: binding), pc = 0, cursor = 0
        var consumed: [C.Transfer] = []
        let (limit, overflow) = (result.transfers.count + 1).multipliedReportingOverflow(by: program.code.count + 1)
        guard !overflow else { throw C.Failure.invalidContract("entry trace size overflow") }
        for _ in 0..<limit {
            guard program.code.indices.contains(pc) else { throw C.Failure.invalidContract("actual entry trace leaves parsed program") }
            _ = try trace.before(pc, transfers: consumed, stopAfterBackedges: nil)
            let instruction = program.code[pc]
            switch instruction.node {
            case let .branch(e, yes, no):
                guard result.transfers.indices.contains(cursor), let taken = result.transfers[cursor].taken else { throw C.Failure.invalidContract("missing actual entry branch") }
                let t = result.transfers[cursor]
                guard t.span == e.span, t.destination == (taken ? yes : no) else { throw C.Failure.invalidContract("actual entry branch disagrees with parsed CFG") }
                cursor += 1; consumed.append(t); pc = t.destination
            case let .jump(target):
                guard result.transfers.indices.contains(cursor) else { throw C.Failure.invalidContract("missing actual entry jump") }
                let t = result.transfers[cursor]
                guard t.span == instruction.span, t.taken == nil, t.destination == target else { throw C.Failure.invalidContract("actual entry jump disagrees with parsed CFG") }
                cursor += 1; consumed.append(t); pc = target
            case .unavailableReturn:
                guard pc == binding.terminal, try program.row(at: instruction.span) == 4,
                      cursor == result.transfers.count, trace.edges.last == exitEdge else { throw C.Failure.invalidContract("actual entry return has incomplete edge trace") }
                return trace.edges
            case .call, .returned, .unresolved: throw C.Failure.invalidContract("unexpected actual entry control")
            default: pc += 1
            }
        }
        throw C.Failure.invalidContract("actual entry trace cannot reconstruct a complete return")
    }

    /// Mapping is frozen before either run. Compare actual commits in their
    /// observed order, never search for the expected number or final assignment.
    static func observedWrites(_ result: C.Result, binding: Binding) throws -> [Write] {
        let slots = Dictionary(uniqueKeysWithValues: binding.slots.map { ($0.span, $0) })
        return try result.commits.compactMap { commit in
            guard let slot = slots[commit.span] else { return nil } // Proven transport copies, not source definitions.
            guard commit.name == slot.name, commit.sourceRow == slot.row,
                  commit.value.type.width == slot.width, !commit.value.type.pointer, commit.value.origins.isEmpty else {
                throw C.Failure.invalidContract("actual source-owned commit changed its frozen representation/identity")
            }
            return .init(row: slot.row, slot: slot.ordinal, width: slot.width, bits: commit.value.bits)
        }
    }
}

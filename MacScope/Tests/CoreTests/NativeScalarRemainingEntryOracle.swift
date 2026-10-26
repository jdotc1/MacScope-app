import Foundation

/// Exact remaining four original entry sites only. This is not a general ARM
/// decoder, relocated fixture, product-plan evaluator, or complete-corpus acceptance.
/// SOURCE_ONLY / NOT_RUN. Candidate execution is the unchanged ordinary Machine.
enum NativeScalarRemainingEntryOracle {
    typealias C = OrdinaryC
    typealias L = OrdinaryCSourceEdgeLedger
    typealias B = NativeScalarOriginalBindings
    typealias E = NativeScalarEntryOracle
    typealias Write = E.Write
    typealias Finish = E.Finish
    typealias Reference = E.Reference
    typealias Slot = E.Slot
    typealias Route = E.Route
    struct Binding {
        let entry: E.Binding
        /// Only exact LDRB row0 may use unsigned-byte C storage for its W32
        /// architectural write. The static load/type witness is frozen here;
        /// observation may zero-extend its representation, never change bits.
        let byteLoadToW32: C.Span?
        var header: Int { entry.header }
        var terminal: Int { entry.terminal }
        var routes: [Route] { entry.routes }
        var slots: [Slot] { entry.slots }
    }
    enum Role: Hashable { case source, destination, count, context, data, shift }
    enum Site: UInt64, CaseIterable {
        case downscale17c88 = 0x17c88, upscale30134 = 0x30134
        case noscale30630 = 0x30630, noscale30b10 = 0x30b10
        var shifted: Bool { self == .downscale17c88 || self == .upscale30134 }
        var loadBytes: Int { self == .downscale17c88 ? 1 : 4 }
        var storeBytes: Int { shifted ? 1 : 2 }
        var shiftOffset: UInt64 { self == .downscale17c88 ? 0x1d8 : 0x220 }
        var storeRow: Int { shifted ? 3 : 1 }
        var countRow: Int { shifted ? 4 : 2 }
        var branchRow: Int { shifted ? 5 : 3 }
        var terminalRow: Int { shifted ? 6 : 4 }
        var outputRoles: Set<Role> { shifted ? [.data, .shift] : [.data] }
        var label: String { "0x" + String(rawValue, radix: 16) }
    }
    struct Input {
        let source: UInt64
        let destination: UInt64
        let count: UInt32
        let context: UInt64?
        let memory: [UInt64: UInt8]
        var physical: [Int: UInt64] {
            var values: [Int: UInt64] = [1: source, 2: destination, 3: UInt64(count)]
            if let context { values[0] = context }
            return values
        }
    }
    private struct Definition {
        let pc: Int
        let span: C.Span
        let row: Int?
        let name: String
        let expression: C.Expression
    }
    static let backedge = E.backedge, exitEdge = E.exitEdge
    private static let validTransportRoles: Set<Set<Role>> = [
        [.source], [.destination], [.count], [.context], [.data], [.shift], [.data, .shift]]

    /// Literal words and operands fix every numerical operation before either
    /// evaluator runs. Frozen input/ABI transport is checked separately; it is
    /// not weakened or synthesized here to accommodate a candidate spelling.
    static func validateOriginal(_ capture: NativeScalarFixture.Capture, bound: B.Bound, site: Site) throws {
        let expected: [(String, String, String)]
        let branchTarget = String(format: "0x%016llx", site.rawValue)
        switch site {
        case .downscale17c88:
            expected = [("28 14 40 38", "ldrb", "w8, [x1], #1"),
                ("09 d8 41 b9", "ldr", "w9, [x0, #0x1d8]"),
                ("08 25 c9 1a", "lsr", "w8, w8, w9"),
                ("48 14 00 38", "strb", "w8, [x2], #1"),
                ("63 04 00 71", "subs", "w3, w3, #1"),
                ("61 ff ff 54", "b.ne", branchTarget), ("c0 03 5f d6", "ret", "")]
        case .upscale30134:
            expected = [("28 44 40 b8", "ldr", "w8, [x1], #4"),
                ("09 20 42 b9", "ldr", "w9, [x0, #0x220]"),
                ("08 21 c9 1a", "lsl", "w8, w8, w9"),
                ("48 14 00 38", "strb", "w8, [x2], #1"),
                ("63 04 00 71", "subs", "w3, w3, #1"),
                ("61 ff ff 54", "b.ne", branchTarget), ("c0 03 5f d6", "ret", "")]
        case .noscale30630, .noscale30b10:
            expected = [("28 44 40 b8", "ldr", "w8, [x1], #4"),
                ("48 24 00 78", "strh", "w8, [x2], #2"),
                ("63 04 00 71", "subs", "w3, w3, #1"),
                ("a1 ff ff 54", "b.ne", branchTarget), ("c0 03 5f d6", "ret", "")]
        }
        guard capture.start == site.label, capture.input_rows.count == expected.count,
              zip(capture.input_rows, expected).allSatisfy({ pair in
                  pair.0.bytes.lowercased() == pair.1.0 && pair.0.mnemonic == pair.1.1 && pair.0.operands == pair.1.2
              }), Set(bound.inputs.map(\.register)) == (site.shifted ? [0, 1, 2, 3] : [1, 2, 3]),
              bound.inputs.allSatisfy({ $0.initializedWidth == ($0.register == 3 ? 32 : 64) }),
              bound.inventory.source.origins == [
                L.Origin(edge: backedge, row: site.branchRow, role: .taken),
                L.Origin(edge: exitEdge, row: site.branchRow, role: .notTaken)],
              bound.inventory.source.returns == [site.terminalRow],
              bound.inventory.flagWriters == [site.branchRow: site.countRow] else {
            throw C.Failure.invalidContract("remaining-entry literal identity/ABI/edge changed at " + site.label)
        }
        // Missing return evidence never establishes void, so every remaining entry keeps the unresolved marker.
        guard case .unavailableReturnContract = bound.manifest.terminal else {
            throw C.Failure.invalidContract("remaining-entry terminal kind changed at " + site.label)
        }
        switch (site.shifted, bound.manifest.entryEnvelope) {
        case (true, .declaredFormals), (false, .frozenABIInputs): break
        default: throw C.Failure.invalidContract("remaining-entry ABI envelope changed at " + site.label)
        }
    }

    /// Independent recurrence from the literal rows above. W arithmetic is
    /// modulo32 and pointer writeback modulo64. Reads use the current byte map,
    /// so stores can affect a subsequent source or shift-word load. No candidate
    /// AST, product IR, or computed expected number supplies candidate state.
    static func reference(_ input: Input, site: Site, finish: Finish) throws -> Reference {
        guard (input.context != nil) == site.shifted else { throw C.Failure.invalidContract("exact entry context role required") }
        let iterations: Int
        switch finish {
        case .returned:
            guard (1...3).contains(input.count) else { throw C.Failure.invalidContract("complete remaining-entry scope is count1/2/3") }
            iterations = Int(input.count)
        case let .backedges(count):
            guard count == 2 else { throw C.Failure.invalidContract("entry prefix requires two actual taken source edges") }
            iterations = count
        }
        var r = Reference(memory: input.memory), source = input.source, destination = input.destination
        var remaining = input.count
        func load(_ memory: [UInt64: UInt8], address: UInt64, bytes: Int) throws -> UInt64 {
            guard address <= UInt64.max - UInt64(bytes - 1) else { throw C.Failure.invalidContract("literal access crosses address-space end") }
            var value: UInt64 = 0
            for offset in 0..<bytes {
                guard let byte = memory[address + UInt64(offset)] else { throw C.Failure.uninitializedRead("literal entry source byte") }
                value |= UInt64(byte) << (offset * 8)
            }
            return value
        }
        for occurrence in 0..<iterations {
            let loaded = try load(r.memory, address: source, bytes: site.loadBytes)
            r.events.append(.load(.init(row: 0, effectOrdinal: 0), occurrence, source, site.loadBytes, loaded))
            r.writes.append(.init(row: 0, slot: 0, width: 32, bits: loaded))
            source &+= UInt64(site.loadBytes)
            r.writes.append(.init(row: 0, slot: 1, width: 64, bits: source))
            var output = UInt32(truncatingIfNeeded: loaded)
            if site.shifted {
                let address = input.context! &+ site.shiftOffset
                let word = try load(r.memory, address: address, bytes: 4)
                r.events.append(.load(.init(row: 1, effectOrdinal: 0), occurrence, address, 4, word))
                r.writes.append(.init(row: 1, slot: 0, width: 32, bits: word))
                let shift = Int(word & 31)
                output = site == .downscale17c88 ? output >> shift : output << shift
                r.writes.append(.init(row: 2, slot: 0, width: 32, bits: UInt64(output)))
            }
            guard destination <= UInt64.max - UInt64(site.storeBytes - 1) else {
                throw C.Failure.invalidContract("literal store crosses address-space end")
            }
            let stored = UInt64(output) & (site.storeBytes == 1 ? 0xff : 0xffff)
            r.events.append(.store(.init(row: site.storeRow, effectOrdinal: 0), occurrence, destination, site.storeBytes, stored))
            for offset in 0..<site.storeBytes {
                r.memory[destination + UInt64(offset)] = UInt8(truncatingIfNeeded: stored >> (offset * 8))
            }
            destination &+= UInt64(site.storeBytes)
            r.writes.append(.init(row: site.storeRow, slot: 0, width: 64, bits: destination))
            remaining &-= 1
            r.writes.append(.init(row: site.countRow, slot: 0, width: 32, bits: UInt64(remaining)))
            let taken = remaining != 0
            r.edges.append(taken ? backedge : exitEdge)
            if !taken {
                guard finish == .returned, occurrence + 1 == iterations else {
                    throw C.Failure.invalidContract("requested prefix returns before second taken edge")
                }
                r.finish = .returned
            }
        }
        if case .backedges = finish {
            guard r.edges == [backedge, backedge] else { throw C.Failure.invalidContract("literal prefix lacks two taken edges") }
            r.finish = finish
        }
        guard r.finish == finish else { throw C.Failure.invalidContract("literal entry did not establish observation") }
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
    private static func roles(_ e: C.Expression, names: [String: Set<Role>], loadRoles: [C.Span: Role]) -> Set<Role> {
        switch e.node {
        case let .name(name), let .update(name, _, _): return names[name, default: []]
        case .load:
            // Loaded data never inherits its address's source/context role.
            if let role = loadRoles[e.span] { return [role] }
            return []
        default: return children(e).reduce(into: Set<Role>()) { $0.formUnion(roles($1, names: names, loadRoles: loadRoles)) }
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
    static func bind(_ program: C.Program, original: B.Bound, site: Site) throws -> Binding {
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
                guard row == site.terminalRow else { throw C.Failure.invalidContract("entry marker moved from original terminal") }
                terminalPCs.append(pc)
            case .nop, .jump: break
            case .call, .returned, .unresolved: throw C.Failure.invalidContract("extra entry control/terminal")
            }
        }
        guard branchPCs.count == 1, terminalPCs.count == 1,
              loadDefinitions.count == (site.shifted ? 2 : 1), storePCs.count == 1,
              program.memorySites.count == (site.shifted ? 3 : 2),
              try program.row(at: program.code[storePCs[0]].span) == site.storeRow else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: missing unique original load/store/control sites")
        }
        var loadRoles: [C.Span: Role] = [:], loadedByRow: [Int: Definition] = [:]
        for definition in loadDefinitions {
            let expressions = loads(definition.expression)
            guard let row = definition.row, row == 0 || (site.shifted && row == 1),
                  expressions.count == 1, let load = expressions.first,
                  case let .load(type, _) = load.node, type.width == (row == 0 ? site.loadBytes * 8 : 32),
                  program.memorySites[load.span] == .init(row: row, effectOrdinal: 0),
                  loadedByRow.updateValue(definition, forKey: row) == nil else {
                throw C.Failure.invalidContract("ENTRY_BINDING_GAP: ambiguous original data/shift-word load")
            }
            loadRoles[load.span] = row == 0 ? .data : .shift
        }
        var names: [String: Set<Role>] = [:]
        for input in original.inputs {
            let role: Role
            switch input.register { case 0: role = .context; case 1: role = .source; case 2: role = .destination; case 3: role = .count
            default: throw C.Failure.invalidContract("entry ownership has an extra external role") }
            names[input.parameter.name] = [role]
        }
        var changed = true
        while changed {
            changed = false
            for d in definitions {
                let joined = names[d.name, default: []].union(roles(d.expression, names: names, loadRoles: loadRoles))
                if joined != names[d.name, default: []] { names[d.name] = joined; changed = true }
            }
        }
        for (row, definition) in loadedByRow {
            guard let load = loads(definition.expression).first, case let .load(_, address) = load.node,
                  roles(address, names: names, loadRoles: loadRoles) == [row == 0 ? .source : .context],
                  roles(definition.expression, names: names, loadRoles: loadRoles) == [row == 0 ? .data : .shift] else {
                throw C.Failure.invalidContract("ENTRY_BINDING_GAP: load address/data roles are mixed or missing")
            }
        }
        guard case let .assign(storeLeft, storeRight) = program.code[storePCs[0]].node,
              case let .load(storeType, storeAddress) = storeLeft[0].node, storeType.width == site.storeBytes * 8,
              program.memorySites[storeLeft[0].span] == .init(row: site.storeRow, effectOrdinal: 0),
              roles(storeAddress, names: names, loadRoles: loadRoles) == [.destination],
              roles(storeRight[0], names: names, loadRoles: loadRoles) == site.outputRoles else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: store address/data roles are mixed or missing")
        }
        let branch = branchPCs[0], terminal = terminalPCs[0]
        guard case let .branch(condition, yes, no) = program.code[branch].node,
              try program.row(at: condition.span) == site.branchRow, roles(condition, names: names, loadRoles: loadRoles) == [.count] else {
            throw C.Failure.invalidContract("ENTRY_BINDING_GAP: latch lacks original count role")
        }
        func slot(row: Int, ordinal: Int, width: Int, roles expectedRoles: Set<Role>, loading: Bool = false) throws -> Slot {
            let matching = definitions.filter { d in
                d.row == row && roles(d.expression, names: names, loadRoles: loadRoles) == expectedRoles &&
                    (loading ? d.span == loadedByRow[row]?.span : !transport(d.expression) && loads(d.expression).isEmpty)
            }
            guard matching.count == 1, let d = matching.first, let symbol = program.symbols[d.name],
                  !symbol.external, !symbol.type.pointer else {
                throw C.Failure.invalidContract("ENTRY_BINDING_GAP: ambiguous/missing source definition row\(row) slot\(ordinal) width\(width)")
            }
            let exactByteLoad = site == .downscale17c88 && row == 0 && ordinal == 0 && loading && width == 32
                && symbol.type == C.CType(8, true)
            guard symbol.type.width == width || exactByteLoad else {
                throw C.Failure.invalidContract("ENTRY_BINDING_GAP: source/storage width lacks exact unsigned-LDRB witness")
            }
            return .init(row: row, ordinal: ordinal, width: symbol.type.width, pc: d.pc, span: d.span, name: d.name)
        }
        var slots = try [slot(row: 0, ordinal: 0, width: 32, roles: [.data], loading: true),
                         slot(row: 0, ordinal: 1, width: 64, roles: [.source])]
        if site.shifted {
            slots += try [slot(row: 1, ordinal: 0, width: 32, roles: [.shift], loading: true),
                          slot(row: 2, ordinal: 0, width: 32, roles: [.data, .shift])]
        }
        slots += try [slot(row: site.storeRow, ordinal: 0, width: 64, roles: [.destination]),
                      slot(row: site.countRow, ordinal: 0, width: 32, roles: [.count])]
        let ownedSpans = Set(slots.map(\.span))
        for d in definitions where !ownedSpans.contains(d.span) {
            guard transport(d.expression), validTransportRoles.contains(roles(d.expression, names: names, loadRoles: loadRoles)) else {
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
                    guard row == site.branchRow, let d = definitionAt[pc], transport(d.expression) else {
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
                    work.append((target, path, transfers + [.init(span: e.span, sourceRow: site.branchRow, taken: taken, destination: target)], seen))
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
        let byteLoadToW32 = slots.first(where: { $0.row == 0 && $0.ordinal == 0 && $0.width == 8 })?.span
        return .init(entry: .init(header: header, terminal: terminal, routes: routes, slots: slots),
                     byteLoadToW32: byteLoadToW32)
    }

    /// Observe actual commit bits unchanged. The sole narrower representation
    /// is statically certified unsigned-byte storage for exact LDRB's W32 write;
    /// its observed zero high bits justify reporting the architectural width.
    /// No cast, truncation, expected value, or source result repairs a candidate.
    static func observedWrites(_ result: C.Result, binding: Binding) throws -> [Write] {
        let slots = Dictionary(uniqueKeysWithValues: binding.slots.map { ($0.span, $0) })
        return try result.commits.compactMap { commit in
            guard let slot = slots[commit.span] else { return nil }
            guard commit.name == slot.name, commit.sourceRow == slot.row,
                  commit.value.type.width == slot.width, !commit.value.type.pointer, commit.value.origins.isEmpty else {
                throw C.Failure.invalidContract("actual entry source-owned commit changed frozen representation/identity")
            }
            if commit.span == binding.byteLoadToW32 {
                guard slot.row == 0, slot.ordinal == 0, slot.width == 8,
                      commit.value.type == C.CType(8, true), commit.value.bits <= 0xff else {
                    throw C.Failure.invalidContract("unsigned LDRB storage-to-W32 observation lost zero-high proof")
                }
                return .init(row: slot.row, slot: slot.ordinal, width: 32, bits: commit.value.bits)
            }
            return .init(row: slot.row, slot: slot.ordinal, width: slot.width, bits: commit.value.bits)
        }
    }

    /// Reconstruct actual Machine paths, admitting only the frozen terminal
    /// kind. The unavailable marker is observed separately, never evaluated.
    static func completeEdges(program: C.Program, result: C.Result, binding: Binding) throws -> [C.SourceEdge] {
        guard result.returned, !result.reachedRegionBoundary else { throw C.Failure.invalidContract("not a complete entry observation") }
        var pc = 0, cursor = 0, path: [Int] = [], edges: [C.SourceEdge] = []
        var started = false, transferStart = 0
        let (limit, overflow) = (result.transfers.count + 1).multipliedReportingOverflow(by: program.code.count + 1)
        guard !overflow else { throw C.Failure.invalidContract("entry trace size overflow") }
        for _ in 0..<limit {
            guard program.code.indices.contains(pc) else { throw C.Failure.invalidContract("actual entry trace leaves parsed program") }
            if !started, pc == binding.header { started = true; transferStart = cursor }
            else if started && (pc == binding.header || pc == binding.terminal) {
                let actual = Array(result.transfers[transferStart..<cursor])
                let matching = binding.routes.filter {
                    $0.destination == pc && $0.pcs == path && sameTransfers($0.transfers, actual)
                }
                guard matching.count == 1 else { throw C.Failure.invalidContract("actual complete entry path has no unique bound route") }
                edges.append(matching[0].edge); path = []; transferStart = cursor
            }
            if started { path.append(pc) }
            let instruction = program.code[pc]
            switch instruction.node {
            case let .branch(e, yes, no):
                guard result.transfers.indices.contains(cursor), let taken = result.transfers[cursor].taken else { throw C.Failure.invalidContract("missing actual entry branch") }
                let t = result.transfers[cursor]
                guard t.span == e.span, t.destination == (taken ? yes : no) else { throw C.Failure.invalidContract("actual entry branch disagrees with parsed CFG") }
                cursor += 1; pc = t.destination
            case let .jump(target):
                guard result.transfers.indices.contains(cursor) else { throw C.Failure.invalidContract("missing actual entry jump") }
                let t = result.transfers[cursor]
                guard t.span == instruction.span, t.taken == nil, t.destination == target else { throw C.Failure.invalidContract("actual entry jump disagrees with parsed CFG") }
                cursor += 1; pc = target
            case .returned, .unavailableReturn:
                guard pc == binding.terminal, cursor == result.transfers.count, edges.last == exitEdge else {
                    throw C.Failure.invalidContract("actual entry terminal has incomplete edge trace")
                }
                return edges
            case .call, .unresolved: throw C.Failure.invalidContract("unexpected actual entry control")
            default: pc += 1
            }
        }
        throw C.Failure.invalidContract("actual entry trace cannot reconstruct a complete terminal")
    }
}

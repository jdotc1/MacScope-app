import Foundation

/// SOURCE_ONLY / NOT_RUN. Additional color coverage consumes the already parsed
/// actual candidate, never renders another document or replays an old selector.
/// A scoped result proves only the stated boundary contract, not entry reachability.
enum OrdinaryCColorCoverage {
    private typealias C = OrdinaryC
    private typealias O = RegionalSwitchOracle
    struct Report {
        let replacedByExistingFullEntry: [String: String]
        let replacedByAdditionalFullEntry: [String: String]
        let additionalFullEntry: [String]
        let scopedOnly: [String]
        let scopedExecuted: [String]
        let unrepresentable: [String: String]
        let addedMemory: [MemoryPremise]
        let limits: [String]
    }
    struct MemoryPremise {
        let scenario: String
        let address: UInt64
        let bytes: Int
        let bits: UInt64
        let provenance: String
    }
    private struct Layout {
        let first: Int, second: Int, shift: Int, tst: Int, store: Int, stop: Int
        let firstTable: UInt64, countTable: UInt64
        let firstBytes: [UInt8], secondBytes: [UInt8]
        let firstDefault: Int, secondDefault: Int, nullPointer: Int
        init(_ seed: RegionalSwitchSeed) throws {
            switch seed {
            case .jinit:
                first = 144; second = 156; shift = 136; tst = 139; store = 278; stop = 286
                firstTable = 0x59070; countTable = 0x59084
                firstBytes = [0x8e,0,0x91,0x2f,0x32,0x2c,0,0x2f,0x32,0x2c]
                secondBytes = [0x8b,0,0x8e,0x3a,0x3d,0x37,0,0x3a,0x3d,0x37]
                firstDefault = 301; secondDefault = 310; nullPointer = 276
            case .j12init:
                first = 145; second = 157; shift = 137; tst = 140; store = 268; stop = 276
                firstTable = 0x590e8; countTable = 0x590fc
                firstBytes = [0x83,0,0x86,0x2d,0x30,0x2a,0,0x2d,0x30,0x2a]
                secondBytes = [0x80,0,0x83,0x32,0x35,0x2f,0,0x32,0x35,0x2f]
                firstDefault = 291; secondDefault = 300; nullPointer = 266
            case .j16initC4Negative: throw C.Failure.invalidContract("no positive j16 color boundary")
            }
        }
    }
    private enum Kind { case coldOrdinalZero, maskedExtremeGuard, shift(UInt64), highTST }
    private struct Witness { let name: String; let kind: Kind; let start: Int }

    static func verify(candidate: OrdinaryC.Program, source: RegionalSwitchOracle.Program,
                       seed: RegionalSwitchSeed, completedFullEntryNames: Set<String>,
                       observeCompletedFullEntry: ((String, OrdinaryC.Result, RegionalSwitchOracle.Result) throws -> Void)? = nil) throws -> Report {
        let layout = try Layout(seed)
        try verifyInfeasibleExactPremises(source, layout)
        var replacements: [String: String] = [:]
        for first in [true, false] {
            for (value, suffix) in [("5", "below"), ("10", "above")] {
                let side = first ? "first" : "second"
                let full = "callback-default-\(side)-\(suffix)"
                guard completedFullEntryNames.contains(full) else { throw C.Failure.invalidContract("required whole-entry guard was not executed: \(full)") }
                replacements["\(side)-guard-region-\(value)"] = full
            }
        }
        // These new cases enter at the real prologue. Only K86 changes the
        // selector, and the original LDP87/unsigned count load90 read it back.
        // Large out-of-image cells are explicit sparse test memory, NOT captured
        // image bytes or evidence that a real process maps those addresses.
        let (complete, addedMemory) = try additionalFullEntry(seed: seed, layout: layout)
        for scenario in complete {
            let expected = try O.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: candidate.contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: nil, contract: candidate.contract, name: scenario.name)
            if scenario.name.hasPrefix("full-entry-shift-") {
                let producer = try uniqueExpression(candidate, rows: [layout.shift + 1], binary: "<<")
                try observe(actual, expression: producer.expression,
                    expected: try sourceValues(expected, row: layout.shift + 1, register: 9), name: scenario.name)
            }
            // Share this already-completed pair once, after numerical checks.
            // The caller can observe edges without another execution. Scoped
            // counterfactual traces below never enter this whole-entry hook.
            try observeCompletedFullEntry?(scenario.name, actual, expected)
        }
        let witnesses = [Witness(name: "first-cold-ordinal-zero-region", kind: .coldOrdinalZero, start: layout.first),
                         Witness(name: "first-guard-region-80000006", kind: .maskedExtremeGuard, start: layout.first)]
            + [UInt64(0),31,32,63,64,65,70].map { Witness(name: "shift-region-\($0)", kind: .shift($0), start: layout.shift) }
            + [Witness(name: "tst64-high-bit-region", kind: .highTST, start: layout.tst)]
        var scopedExecuted: [String] = [], unrepresentable: [String: String] = [:]
        for witness in witnesses {
            if let proof = try scoped(witness, candidate: candidate, source: source, layout: layout) {
                unrepresentable[witness.name] = proof
            } else { scopedExecuted.append(witness.name) }
        }
        let addedReplacements = ["first-guard-region-ffffffff": "full-entry-first-guard-ffffffff",
                                 "second-guard-region-ffffffff": "full-entry-second-guard-ffffffff",
                                 "second-guard-region-80000006": "full-entry-second-guard-80000006"]
        let historical = try O.ColorScenarios.all(for: seed).filter { $0.startRow != 0 || $0.stopBeforeRow != nil }
        let accounted = Set(replacements.keys).union(addedReplacements.keys).union(witnesses.map(\.name))
        guard historical.count == 17, accounted.count == 17, Set(historical.map(\.name)) == accounted else {
            throw C.Failure.invalidContract("regional color inventory is not exactly accounted for")
        }
        return .init(replacedByExistingFullEntry: replacements, replacedByAdditionalFullEntry: addedReplacements,
            additionalFullEntry: complete.map(\.name),
            scopedOnly: witnesses.map(\.name), scopedExecuted: scopedExecuted,
            unrepresentable: unrepresentable, addedMemory: addedMemory, limits: [
                "Three extreme unsigned guards, the first-selector 0x80000006 mask bypass, and seven shift amounts have full-entry K-relative cases. Shift count reads use exact retained/new bounded file bytes; the huge guard cells are explicitly modeled, not image bytes or mapped-process claims.",
                "Ten exact historical premises are infeasible at whole entry. Each must receive either a scoped execution proving only local arithmetic/control/effects or an explicit static unrepresentability disposition, never whole-entry credit. First-selector 0x80000006 has low6=6 and bypasses the first SUB just like selector6.",
                "A source-infeasible high-bit TST premise may additionally be unrepresentable in parsed uint32-to-uint64 storage. Such a proof earns neither scoped execution nor full-entry credit; storage is never widened to force it.",
                "A missing/ambiguous parsed producer, nonclosed CFG, extra live-in, or unsupported def-use form fails coverage; it is never a skipped success.",
                "No complete source-edge ledger or mutation-matrix credit is implied by this helper."
            ])
    }

    private static func additionalFullEntry(seed: RegionalSwitchSeed, layout: Layout) throws -> ([O.Scenario], [MemoryPremise]) {
        let old = try O.ColorScenarios.all(for: seed)
        guard let base = old.first(where: { $0.name == "callback-default-first-below" }),
              base.startRow == 0, base.stopBeforeRow == nil, base.responses.count == 2,
              base.responses[1].row == 86 else { throw C.Failure.invalidContract("missing frozen full-entry K86 seed") }
        let cases: [(String, Bool, UInt64)] = [true, false].flatMap { first in
            [UInt64(0xffff_ffff),0x8000_0006].map {
                (first && $0 == 0x8000_0006 ? "full-entry-first-mask-bypass-80000006" : "full-entry-\(first ? "first" : "second")-guard-\(String($0, radix: 16))", first, $0)
            }
        } + [UInt64(0),31,32,63,64,65,70].map { ("full-entry-shift-\($0)", true, $0) }
        var premises: [MemoryPremise] = []
        let scenarios = try cases.map { name, first, value in
            var memory = base.memory
            let countAddress = layout.countTable + value * 4
            var cellPremise = "The count load uses retained immutable table bytes."
            if value > 16 {
                // Exactly four bytes, no fabricated giant table. Two jinit
                // extended indices happen to overlap the OTHER seed's retained
                // count range. Preserve those known bytes too, not just the
                // current seed's 68-byte count/20-byte dispatch ranges.
                let bits: UInt64, provenance: String
                switch countAddress {
                case 0x59100: bits = 0xffff_ffff; provenance = "retained j12 count entry1 bytes"
                case 0x59104: bits = 3; provenance = "retained j12 count entry2 bytes"
                // One source-only bounded read of these ten NEW four-byte
                // cells on 2026-10-18. Authority: retained inputs/libjpeg.8.dylib,
                // immutable-tables.json __TEXT(vm=0,fileoff=0,filesize=0x60000).
                // No hash, decoder, renderer, source/candidate evaluator or
                // prior successful byte read was repeated. Addresses below
                // include neighboring j16 data; no j16 function is executed.
                case 0x59178,0x59180,0x59184,0x59188:
                    bits = 0xffff_ffff; provenance = "new bounded exact __TEXT file bytes ff ff ff ff"
                case 0x5917c: bits = 3; provenance = "new bounded exact __TEXT file bytes 03 00 00 00"
                case 0x5919c: bits = 4; provenance = "new bounded exact __TEXT file bytes 04 00 00 00"
                case 0x591f8,0x591fc: bits = 0; provenance = "new bounded exact __TEXT file bytes 00 00 00 00"
                case 0x59200: bits = 0x2b23_009d; provenance = "new bounded exact __TEXT file bytes 9d 00 23 2b"
                case 0x59214: bits = 0x4b42_539f; provenance = "new bounded exact __TEXT file bytes 9f 53 42 4b"
                default:
                    let knownRanges: [Range<UInt64>] = [0x59070..<0x590c8,0x590e8..<0x59140]
                    guard !(0..<4).contains(where: { byte in knownRanges.contains { $0.contains(countAddress + UInt64(byte)) } }) else {
                        throw C.Failure.invalidContract("new sparse premise overlaps unaccounted retained immutable bytes")
                    }
                    bits = 0xa1b2_c3d4; provenance = "explicit modeled readable memory; not observed binary bytes or process mapping"
                }
                try memory.store(.init(address: countAddress, bytes: 4, bits: bits))
                premises.append(.init(scenario: name, address: countAddress, bytes: 4, bits: bits, provenance: provenance))
                cellPremise = provenance
            }
            var responses = base.responses
            responses[1].writes = [.init(address: 0x1003c, bytes: 4, bits: first ? 2 : 1),
                                   .init(address: 0x10040, bytes: 4, bits: value)]
            var result = O.Scenario(name: name, registers: base.registers, memory: memory, responses: responses)
            result.expectedVisits = [23:1,86:1,87:1,90:1,layout.store:1,layout.stop:1]
            result.expectedAbsentRows = [layout.first + 6,layout.first + 8,layout.second + 6,layout.second + 8]
            if name.hasPrefix("full-entry-shift-") {
                result.expectedVisits[layout.shift] = 1; result.expectedVisits[layout.shift + 1] = 1
            }
            if first && (value == 70 || value == 0x8000_0006) {
                result.expectedVisits[layout.nullPointer] = 1
                result.expectedAbsentRows.insert(layout.first)
            }
            else { result.expectedVisits[first ? layout.firstDefault : layout.secondDefault] = 1 }
            result.premises = ["Genuine complete entry with explicit returning K86 writes, original LDP87 reload, and no internal candidate bindings.",
                cellPremise]
            return result
        }
        return (scenarios,premises)
    }

    /// Enumerate every possible incoming edge in the complete decoded stream.
    /// Indirect successors come from literal retained byte tables, not typed
    /// production switch cases. This rules out a hidden predecessor/call that
    /// could invalidate the local reaching-value infeasibility arguments.
    private static func verifyInfeasibleExactPremises(_ source: O.Program, _ l: Layout) throws {
        let rowForAddress = Dictionary(uniqueKeysWithValues: source.rows.enumerated().map { ($0.element.address,$0.offset) })
        var incoming: [Int: Set<Int>] = [:]
        func add(_ from: Int, _ to: Int) throws {
            guard source.code.indices.contains(to) else { throw C.Failure.invalidContract("infeasibility edge leaves capture") }
            incoming[to, default: []].insert(from)
        }
        func literal(_ row: Int, _ mnemonic: String, _ operands: String) throws {
            guard source.rows[row].mnemonic == mnemonic, source.rows[row].operands == operands else {
                throw C.Failure.invalidContract("literal infeasibility premise changed at \(row)")
            }
        }
        for (row, code) in source.code.enumerated() {
            switch code {
            case let .branch(condition, _, address):
                guard let target = rowForAddress[address] else { throw C.Failure.invalidContract("unbound literal source edge") }
                try add(row, target)
                if condition != "always" { try add(row, row + 1) }
            case .indirectBranch:
                let bytes: [UInt8], base: Int, table: UInt64
                if row == l.first + 8 { bytes = l.firstBytes; base = l.first + 9; table = l.firstTable }
                else if row == l.second + 8 { bytes = l.secondBytes; base = l.second + 9; table = l.firstTable + 10 }
                else { throw C.Failure.invalidContract("unreviewed indirect source predecessor") }
                guard case let .page(pageRegister, page) = source.code[row - 5], pageRegister.index == 9, page == 0x59000,
                      case let .relative(baseRegister, address) = source.code[row - 3], baseRegister.index == 10,
                      address == source.rows[base].address else { throw C.Failure.invalidContract("unproven indirect source table/base relation") }
                try literal(row - 4, "add", "x9, x9, #0x\(String(table - 0x59000, radix: 16))")
                try literal(row - 2, "ldrb", "w11, [x9, x8]")
                try literal(row - 1, "add", "x10, x10, x11, lsl #2")
                try literal(row, "br", "x10")
                for byte in bytes { try add(row, base + Int(byte)) }
            case .returned: break
            default: try add(row, row + 1)
            }
        }
        guard incoming[l.shift] == [67,l.shift - 1], incoming[67] == [66],
              incoming[l.shift - 1] == [95], incoming[l.tst] == [l.tst - 1],
              incoming[l.first] == [l.tst + 1,l.tst + 4],
              incoming[l.shift + 1] == [l.shift], incoming[l.tst - 1] == [l.shift + 1],
              incoming[l.tst + 1] == [l.tst], incoming[l.tst + 2] == [l.tst + 1],
              incoming[l.tst + 3] == [l.tst + 2], incoming[l.tst + 4] == [l.tst + 3] else {
            throw C.Failure.invalidContract("complete predecessor inventory no longer proves color infeasibility")
        }
        try literal(66, "mov", "x9, x8")
        try literal(l.shift - 1, "mov", "w9, w8")
        try literal(l.shift, "mov", "w10, #1")
        try literal(l.shift + 1, "lsl", "x9, x10, x9")
        try literal(l.tst - 1, "mov", "w10, #0x10c4")
        try literal(l.tst, "tst", "x9, x10")
        try literal(l.tst + 2, "mov", "w10, #0x144")
        try literal(l.tst + 3, "and", "x9, x9, x10")
        guard case .branch("eq", nil, let equalTarget) = source.code[l.tst + 1],
              equalTarget == source.rows[l.first].address,
              case .branch("cbnz", .some(let tested), let nonzeroTarget) = source.code[l.tst + 4],
              tested.index == 9, tested.width == 64, !tested.zero,
              nonzeroTarget == source.rows[l.nullPointer].address else {
            throw C.Failure.invalidContract("mask-bypass branch predicate/register/target premise changed")
        }
        // Both incoming MOV forms guarantee X9.low6=W8.low6; this sufficient
        // invariant does not assume an unproved high32 value on the X copy.
        // For W8=6 or 0x80000006, 1<<(W8&63) is 0x40, intersects
        // both fixed masks, and bypasses first SUB. TST's X10 is always 0x10c4,
        // never bit63. No call lies in
        // any of the predecessor chains enumerated above.
    }

    private struct Located { let pc: Int; let expression: C.Expression }
    private static func expressions(_ root: C.Expression) -> [C.Expression] {
        let children: [C.Expression]
        switch root.node {
        case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): children = [e]
        case let .binary(_, a, b): children = [a,b]
        case let .select(a,b,c): children = [a,b,c]
        case let .helper(_, args): children = args
        case .literal, .name, .update: children = []
        }
        return [root] + children.flatMap(expressions)
    }
    private static func roots(_ instruction: C.Instruction) -> [C.Expression] {
        switch instruction.node {
        case let .declaration(_, e): return e.map { [$0] } ?? []
        case let .assign(left, right): return left.filter { if case .load = $0.node { return true }; return false } + right
        case let .update(e), let .branch(e, _, _): return [e]
        case let .call(_, _, c, args): return (c.map { [$0] } ?? []) + args
        case let .returned(e): return e.map { [$0] } ?? []
        case .nop, .jump, .unresolved, .unavailableReturn: return []
        }
    }
    private static func uniqueExpression(_ program: C.Program, rows: Set<Int>, binary op: String) throws -> Located {
        var found: [C.Span: Located] = [:]
        for (pc, instruction) in program.code.enumerated() {
            for e in roots(instruction).flatMap(expressions) {
                if case let .binary(actual, _, _) = e.node, actual == op,
                   let row = try? program.row(at: e.span), rows.contains(row) { found[e.span] = .init(pc: pc, expression: e) }
            }
        }
        guard found.count == 1, let result = found.values.first else { throw C.Failure.invalidContract("missing/ambiguous parsed \(op) producer at rows \(rows.sorted())") }
        return result
    }
    private static func names(_ e: C.Expression) -> Set<String> {
        Set(expressions(e).compactMap { item in
            switch item.node { case let .name(name), let .update(name, _, _): return name; default: return nil }
        })
    }
    private static func writes(_ instruction: C.Instruction) -> Set<String> {
        switch instruction.node {
        case let .declaration(name, _): return [name]
        case let .assign(left, _): return Set(left.compactMap { if case let .name(n) = $0.node { return n }; return nil })
        case let .update(e): return names(e)
        default: return []
        }
    }
    private static func sourceValues(_ result: O.Result, row: Int, register: Int) throws -> [UInt64] {
        guard let snapshots = result.afterRows[row], !snapshots.isEmpty else { throw C.Failure.invalidContract("missing source value observation") }
        return try snapshots.map {
            guard let value = $0.registers[register] else { throw C.Failure.invalidContract("source observation uninitialized") }; return value
        }
    }
    private static func observe(_ result: C.Result, expression: C.Expression, expected: [UInt64], name: String) throws {
        let actual = result.evaluations.filter { $0.span == expression.span }.map(\.value.bits)
        guard actual == expected else { throw C.Failure.semanticMismatch("\(name): actual parsed transient producer differs") }
    }

    /// Names in these maps are parsed lexical identifiers only. The graph is
    /// assembled from actual candidate assignments and printed transfers. It
    /// transports symbolic dependency sets, never reference bits or decisions.
    private struct Boundary {
        let entry: Int, stop: Int, allowed: Set<Int>, liveIn: Set<String>
        let before: [Int: [String: Set<String>]]
        func dependencies(_ e: C.Expression, at pc: Int) -> Set<String> {
            OrdinaryCColorCoverage.names(e).reduce(into: Set<String>()) { $0.formUnion(before[pc]?[$1] ?? []) }
        }
    }
    private static func boundary(_ program: C.Program, entry: Int, stop: Int) throws -> Boundary {
        var successors: [Int: [Int]] = [:], postorder: [Int] = [], active: Set<Int> = [], visited: Set<Int> = []
        func visit(_ pc: Int) throws {
            if pc == stop { return }
            guard program.code.indices.contains(pc), !active.contains(pc) else { throw C.Failure.invalidContract("color scoped CFG escapes or cycles") }
            if visited.contains(pc) { return }
            active.insert(pc)
            let next: [Int]
            switch program.code[pc].node {
            case let .branch(_, yes, no): next = [yes,no]
            case let .jump(target): next = [target]
            case .call, .returned, .unavailableReturn, .unresolved: throw C.Failure.invalidContract("scoped color CFG reaches call/return/unresolved transfer")
            default: next = [pc + 1]
            }
            successors[pc] = next
            for target in next { try visit(target) }
            active.remove(pc); visited.insert(pc); postorder.append(pc)
        }
        try visit(entry)
        guard successors.values.contains(where: { $0.contains(stop) }) else { throw C.Failure.invalidContract("scoped CFG has no declared exit") }
        var needed: [Int: Set<String>] = [:]
        for pc in postorder {
            let downstream = successors[pc, default: []].reduce(into: Set<String>()) { $0.formUnion(needed[$1, default: []]) }
            let reads = roots(program.code[pc]).reduce(into: Set<String>()) { $0.formUnion(names($1)) }
            needed[pc] = reads.union(downstream.subtracting(writes(program.code[pc])))
        }
        let live = needed[entry, default: []]
        var before: [Int: [String: Set<String>]] = [entry: Dictionary(uniqueKeysWithValues: live.map { ($0,Set([$0])) })]
        for pc in postorder.reversed() {
            let incoming = before[pc, default: [:]]
            var after = incoming
            func deps(_ e: C.Expression) -> Set<String> { names(e).reduce(into: Set<String>()) { $0.formUnion(incoming[$1, default: []]) } }
            switch program.code[pc].node {
            case let .declaration(name, e): after[name] = e.map(deps) ?? []
            case let .assign(left, right):
                for (lhs,rhs) in zip(left,right) { if case let .name(name) = lhs.node { after[name] = deps(rhs) } }
            case .update: throw C.Failure.invalidContract("unexpected mutable update in acyclic color boundary")
            default: break
            }
            for target in successors[pc, default: []] where target != stop {
                for (name, dependencies) in after { before[target, default: [:]][name, default: []].formUnion(dependencies) }
            }
        }
        return .init(entry: entry, stop: stop, allowed: visited, liveIn: live, before: before)
    }

    /// A deliberately small range proof over parsed types/casts only. This can
    /// explain why a source-infeasible counterfactual has no representation in
    /// the actual native output. It never executes or repairs an expression.
    private static func upperBound(_ e: C.Expression, program: C.Program) -> UInt64? {
        if let type = program.expressionTypes[e.span], !type.pointer, type.unsigned, type.width <= 32 { return type.mask }
        switch e.node {
        case let .literal(value): return value.negative ? nil : value.bits
        case let .cast(type, operand) where type == .u64:
            guard let operandType = program.expressionTypes[operand.span], operandType.unsigned, !operandType.pointer else { return nil }
            return upperBound(operand, program: program)
        default: return nil
        }
    }
    /// nil means an actual scoped differential execution completed. Non-nil is
    /// a specific static unrepresentability proof, NOT a pass or execution.
    private static func scoped(_ witness: Witness, candidate: C.Program, source: O.Program, layout l: Layout) throws -> String? {
        let sub = try uniqueExpression(candidate, rows: [l.first], binary: "-")
        let shift = try uniqueExpression(candidate, rows: [l.shift + 1], binary: "<<")
        let tst = try uniqueExpression(candidate, rows: [l.tst,l.tst + 1], binary: "&")
        let stopSites = candidate.code.enumerated().filter { _, instruction in
            roots(instruction).flatMap(expressions).contains { candidate.memorySites[$0.span] == .init(row: l.stop, effectOrdinal: 0) }
        }
        guard stopSites.count == 1 else { throw C.Failure.invalidContract("missing/ambiguous first shared-exit effect") }
        let entry: Int
        switch witness.kind {
        case .coldOrdinalZero, .maskedExtremeGuard: entry = sub.pc
        case .shift:
            let starts = candidate.code.enumerated().filter { _, i in
                (try? candidate.row(at: i.span)) == l.shift && { if case .assign = i.node { return true }; return false }()
            }
            guard starts.count == 1 else { throw C.Failure.invalidContract("scoped shift needs actual MOV1 assignment boundary") }
            entry = starts[0].offset
        case .highTST: entry = tst.pc
        }
        let bound = try boundary(candidate, entry: entry, stop: stopSites[0].offset)
        guard case let .binary(_, selector, _) = sub.expression.node,
              case let .binary(_, _, amount) = shift.expression.node,
              case let .binary(_, testedLeft, testedRight) = tst.expression.node else { throw C.Failure.invalidContract("lost actual binary operand anchors") }
        if case .highTST = witness.kind {
            for (role, operand) in [("left",testedLeft),("right",testedRight)] {
                if let maximum = upperBound(operand, program: candidate), maximum < 0x8000_0000_0000_0000 {
                    return "Source-infeasible TST \(role) operand has parsed unsigned narrow/cast or literal upper bound 0x\(String(maximum, radix: 16)); bit63 cannot be supplied without changing actual storage/expression. No scoped execution credit."
                }
            }
        }
        let stores = candidate.code.enumerated().flatMap { pc, instruction -> [Located] in
            guard case let .assign(left, _) = instruction.node else { return [] }
            return left.compactMap {
                guard candidate.memorySites[$0.span] == .init(row: l.store, effectOrdinal: 0),
                      case let .load(_, address) = $0.node else { return nil }
                return .init(pc: pc, expression: address)
            }
        }
        guard stores.count == 1 else { throw C.Failure.invalidContract("ambiguous actual common-store address") }
        var bindings: [String: C.Value] = [:]
        func bind(_ expression: C.Expression, at pc: Int, bits: UInt64, width: Int?, role: String) throws {
            let dependencies = bound.dependencies(expression, at: pc)
            guard bound.allowed.contains(pc), dependencies.count == 1, let name = dependencies.first,
                  bound.liveIn.contains(name), bindings[name] == nil,
                  let symbol = candidate.symbols[name], !symbol.external, !symbol.type.pointer,
                  bits & ~symbol.type.mask == 0,
                  width.map({ symbol.type.width == $0 }) ?? [32,64].contains(symbol.type.width) else {
                throw C.Failure.invalidContract("unproven/aliased parsed boundary role: \(role)")
            }
            bindings[name] = .init(bits, symbol.type)
        }
        let selectorBits: UInt64
        switch witness.kind {
        case .coldOrdinalZero: selectorBits = 6
        case .maskedExtremeGuard: selectorBits = 0x8000_0006
        case .shift, .highTST: selectorBits = 7
        }
        try bind(selector, at: sub.pc, bits: selectorBits, width: nil, role: "selector entering SUB")
        try bind(stores[0].expression, at: stores[0].pc, bits: 0x50000, width: 64, role: "deconverter base")
        var registers: [Int: UInt64] = [8:selectorBits,19:0x10000,20:0x50000]
        switch witness.kind {
        case .coldOrdinalZero, .maskedExtremeGuard: break
        case let .shift(value):
            // These seven amounts fit an actual uint32 carrier as well as64.
            // The parsed shift expression itself must still execute at X64
            // width, established by its output observation, not symbol spelling.
            try bind(amount, at: shift.pc, bits: value, width: nil, role: "independent incoming shift amount")
            registers[9] = value
        case .highTST:
            try bind(testedLeft, at: tst.pc, bits: 0x8000_0000_0000_0000, width: 64, role: "TST left")
            try bind(testedRight, at: tst.pc, bits: 0x8000_0000_0000_0000, width: 64, role: "TST right")
            registers[9] = 0x8000_0000_0000_0000; registers[10] = 0x8000_0000_0000_0000
        }
        guard Set(bindings.keys) == bound.liveIn else { throw C.Failure.invalidContract("extra/unbound actual scoped live-ins: \(bound.liveIn.subtracting(bindings.keys).sorted())") }
        var memory = O.Memory(); memory.initialize(0x50000, count: 0x50, byte: 0xa7)
        let needTable: Bool
        switch witness.kind { case .maskedExtremeGuard, .shift(70): needTable = false; default: needTable = true }
        if needTable { for (offset, byte) in l.firstBytes.enumerated() { memory.bytes[l.firstTable + UInt64(offset)] = byte } }
        var reference = O.Scenario(name: witness.name, registers: registers, memory: memory, responses: [])
        reference.startRow = witness.start; reference.stopBeforeRow = l.stop
        reference.expectedVisits = [l.store:1]
        if needTable { reference.expectedVisits[l.first + 6] = 1; reference.expectedVisits[l.first + 8] = 1 }
        else {
            reference.expectedAbsentRows = [l.first + 6,l.first + 8]
            if case .maskedExtremeGuard = witness.kind { reference.expectedVisits[l.firstDefault] = 1 }
        }
        let expected = try O.Machine(program: source, scenario: reference).run()
        // External formals are inert here: liveness proved that every incoming
        // read is one of the independently bound internal role operands above.
        let inputs = Dictionary(uniqueKeysWithValues: candidate.contract.inputs.map { ($0.name,C.Value(0,$0.type)) })
        let scenario = C.Scenario(name: witness.name, inputs: inputs, memory: memory.bytes, responses: [])
        let actual = try C.Machine(program: candidate, scenario: scenario).run(region:
            .init(entryPC: bound.entry, stopPC: bound.stop, incoming: bindings, allowedPCs: bound.allowed))
        try compareScoped(actual, expected, name: witness.name)
        // A dependency relation alone does not establish an operand's value:
        // "root+1" still depends on root. Check the actual evaluated role
        // operands, using independent boundary contracts, before crediting the
        // witness. These observations NEVER populate candidate storage.
        if expected.rowVisits[l.first, default: 0] != 0 {
            try observe(actual, expression: selector, expected: [selectorBits], name: witness.name + ": selector role")
        }
        try observe(actual, expression: stores[0].expression,
            expected: [0x50000 + (l.store == 278 ? 8 : 16)], name: witness.name + ": pointer role")
        switch witness.kind {
        case .coldOrdinalZero, .maskedExtremeGuard: break
        case let .shift(value):
            try observe(actual, expression: amount, expected: [value & 63], name: witness.name + ": masked shift role")
            try observe(actual, expression: shift.expression, expected: sourceValues(expected, row: l.shift + 1, register: 9), name: witness.name)
        case .highTST:
            guard let flags = expected.afterRows[l.tst]?.first?.flags, flags.n, !flags.z else { throw C.Failure.invalidContract("source high-bit TST obligation missing") }
            try observe(actual, expression: testedLeft, expected: [0x8000_0000_0000_0000], name: witness.name + ": TST left role")
            try observe(actual, expression: testedRight, expected: [0x8000_0000_0000_0000], name: witness.name + ": TST right role")
            try observe(actual, expression: tst.expression, expected: [0x8000_0000_0000_0000], name: witness.name)
            let followingAND = try uniqueExpression(candidate, rows: [l.tst + 3], binary: "&")
            try observe(actual, expression: followingAND.expression, expected: [0], name: witness.name + ": non-EQ continuation")
        }
        return nil
    }
    private static func compareScoped(_ actual: C.Result, _ expected: O.Result, name: String) throws {
        guard actual.reachedRegionBoundary, expected.reachedRegionBoundary, !actual.returned, !expected.returned,
              actual.terminal == nil, actual.consumedResponses == 0 else { throw C.Failure.semanticMismatch("\(name): incorrect scoped exit") }
        var counts: [Int: Int] = [:]
        let events: [C.Event] = try expected.events.map { event in
            switch event {
            case let .load(row,address,bytes,bits), let .store(row,address,bytes,bits):
                let occurrence = counts[row, default: 0]; counts[row] = occurrence + 1
                let site = C.SourceSite(row: row,effectOrdinal: 0)
                if case .load = event { return .load(site,occurrence,address,bytes,bits) }
                return .store(site,occurrence,address,bytes,bits)
            case .call: throw C.Failure.invalidContract("unexpected scoped source call")
            }
        }
        guard actual.events == events, actual.memory == expected.memory.bytes else { throw C.Failure.semanticMismatch("\(name): scoped ordered effects/bytes differ") }
    }
}

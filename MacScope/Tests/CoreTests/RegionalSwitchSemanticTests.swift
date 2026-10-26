import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// NEW reconstructed source draft. No selector/parser/renderer has been run.
/// The lost 32bb9c4e draft is historical, not this file's identity or clearance.
/// Original literal references and all17 authored scoped premises are retained.
/// Width sensitivity and the impossible high-bit native TST comparison are OPEN.
final class RegionalSwitchSemanticTests: XCTestCase {
    typealias O = RegionalSwitchOracle
    typealias C = OrdinaryC
    typealias L = OrdinaryCSourceEdgeLedger
    typealias B = OrdinaryCBaselineTransferOrigins
    // Only the original derived printless-call safety unit uses this helper.
    // The actual candidate is always parsed/evaluated by strict ordinary C.
    typealias T = RegionalSwitchTextMachine

    func testJinitEmittedSemanticsIncludingDeclaredRegions() throws { try exercise(.jinit) }
    func testJ12EmittedSemanticsIncludingDeclaredRegions() throws { try exercise(.j12init) }

    private struct Layout {
        let first: Int, second: Int, shift: Int, tst: Int, store: Int, stop: Int, zero: Int
        init(_ seed: RegionalSwitchSeed) throws {
            switch seed {
            case .jinit: first = 144; second = 156; shift = 137; tst = 139; store = 278; stop = 286; zero = 253
            case .j12init: first = 145; second = 157; shift = 138; tst = 140; store = 268; stop = 276; zero = 246
            case .j16initC4Negative: throw C.Failure.invalidContract("no positive j16 adapter")
            }
        }
    }
    private static var scopedNames: Set<String> {
        Set(["first-cold-ordinal-zero-region", "tst64-high-bit-region"]
            + ["first", "second"].flatMap { side in ["5", "10", "ffffffff", "80000006"].map { "\(side)-guard-region-\($0)" } }
            + [0,31,32,63,64,65,70].map { "shift-region-\($0)" })
    }

    private func requireRepair(_ fixture: RegionalSwitchFixture) throws -> C.Program {
        // Schema-two fixture authority is checked before constructing any oracle.
        try fixture.requireCompleteInputAuthority()
        let audit = try OrdinaryCOutputAudit.analyze(document: fixture.document,
            function: fixture.function, baselineText: fixture.baselineText)
        let raw = fixture.document.text.split(separator: "\n").filter { $0.contains("goto 0x") }.count
        let total = fixture.document.text.split(separator: "\n").filter { $0.contains("goto ") }.count
        guard audit.errors.isEmpty, fixture.document.regionTree != nil,
              fixture.document.text.range(of: "rgn_[a-z]+_", options: .regularExpression) == nil,
              raw < fixture.capture.baseline_counts.raw_goto_lines,
              total < fixture.capture.baseline_counts.total_goto_lines else {
            throw C.Failure.unsupportedSyntax("REGIONAL_SWITCH_ORDINARY_PREREQUISITE: actual complete output; no fallback or substituted document: \(audit.errors)")
        }
        let addresses = Set(fixture.rows.map(\.address))
        guard fixture.document.lines.allSatisfy({ $0.sourceAddress.map(addresses.contains) ?? true }),
              fixture.callPayloads.allSatisfy({ $0.after == [$0.baseline] }),
              fixture.document.lines.filter({ $0.text.hasSuffix("// call") }).count == fixture.seed.callRows.count else {
            throw C.Failure.invalidContract("foreign source identity or changed original opaque payload")
        }
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try C.contract(rows: fixture.rows, function: fixture.function, baseline: fixture.baselineText,
            callRows: fixture.seed.callRows, blockAddresses: blocks)
        return try C.Program(lines: C.lines(fixture.document), contract: contract)
    }

    private func exercise(_ seed: RegionalSwitchSeed,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try RegionalSwitchFixture.make(seed)
        try fixture.requireCompleteInputAuthority()
        let source = try O.Program(fixture: fixture)
        let scenarios = try O.ColorScenarios.all(for: seed)
        guard !scenarios.isEmpty, Set(scenarios.map(\.name)).count == scenarios.count else {
            throw O.Failure.invalid("missing or duplicate scenario")
        }
        var references: [String: O.Result] = [:]
        // All original references, including high-bit TST, run unchanged before
        // candidate prerequisites. No output value supplies a source premise.
        for scenario in scenarios {
            let expected = try O.Machine(program: source, scenario: scenario).run()
            references[scenario.name] = expected
            try checkCoverageWitness(scenario, expected, seed: seed, file: file, line: line)
            if scenario.name == "tst64-high-bit-region" {
                let l = try Layout(seed)
                guard expected.afterRows[l.tst]?.last?.flags?.n == true,
                      expected.afterRows[l.tst]?.last?.flags?.z == false,
                      expected.afterRows[l.tst]?.last?.flags?.c == false,
                      expected.afterRows[l.tst]?.last?.flags?.v == false else {
                    throw O.Failure.invalid("unchanged high-bit source reference lost its N/Z/C/V premise")
                }
            }
        }
        let candidate = try requireRepair(fixture), layout = try Layout(seed)
        let literalCFG = try L.source(rows: fixture.rows, color: fixture.capture)
        let topology = try L.analyze(candidate: candidate, source: literalCFG)
        try topology.requireCompleteTopology()
        guard let mapping = B.frozenMapping(for: seed.start) else { throw C.Failure.invalidContract("missing original printed-transfer mapping") }
        let frozen = try B.bind(mapping, baselineText: fixture.baselineText, source: literalCFG)
        let account = try B.account(topology, baseline: frozen)
        try account.requireComplete()
        guard !account.structuredOriginalGotoOrigins.isEmpty else { throw C.Failure.invalidContract("no source-owned structured transfer removal") }
        var scoped: Set<String> = [], executed: Set<String> = [], unavailable: Set<String> = []
        var observedEdges: Set<C.SourceEdge> = []
        for scenario in scenarios {
            guard let expected = references[scenario.name] else { throw O.Failure.invalid("missing cached source result") }
            if scenario.startRow == 0 {
                guard scenario.stopBeforeRow == nil, scenario.regionalBindings.isEmpty else { throw C.Failure.invalidContract("full entry cannot inject internal state") }
                let actual: C.Result
                do { actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: candidate.contract)).run() }
                catch { throw C.Failure.invalidContract("full-entry run of \(scenario.name): \(error)") }
                try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                    returned: expected.returned, terminal: nil, contract: candidate.contract, name: scenario.name)
                try observeTransient(actual, reference: expected, candidate: candidate, source: source, layout: layout)
                let observation = try L.observe(topology, candidate: candidate, actual: actual,
                    referenceBranches: expected.branches, referenceRowVisits: expected.rowVisits,
                    referenceReturned: expected.returned, name: scenario.name)
                observedEdges.formUnion(observation.sourceEdges)
            } else {
                scoped.insert(scenario.name)
                if let reason = try highTSTUnrepresentability(candidate, scenario: scenario, layout: layout) {
                    unavailable.insert(scenario.name)
                    print("ORDINARY_C_SCOPED_OPEN name=\(scenario.name) status=OPEN_NOT_EXECUTED wholeEntryCredit=0 reason=\(reason)")
                    continue
                }
                let bound = try bindScope(candidate, scenario: scenario, layout: layout)
                let actual: C.Result
                do { actual = try runScoped(candidate, scenario: scenario, bound: bound) }
                catch { throw C.Failure.invalidContract("scoped run of \(scenario.name): \(error)") }
                try compareScoped(actual, expected, contract: candidate.contract, name: scenario.name)
                try observeBoundary(actual, bound: bound, scenario: scenario, reference: expected, rows: fixture.rows, layout: layout)
                try observeTransient(actual, reference: expected, candidate: candidate, source: source, layout: layout)
                try observeScopedRegisterWriters(actual, reference: expected, scenario: scenario,
                    candidate: candidate, source: source)
                executed.insert(scenario.name)
                print("ORDINARY_C_SCOPED_COMPARISON name=\(scenario.name) wholeEntryCredit=0")
            }
        }
        guard scoped == Self.scopedNames, executed.count == 16,
              unavailable == ["tst64-high-bit-region"], executed.isDisjoint(with: unavailable),
              executed.union(unavailable) == scoped else { throw C.Failure.invalidContract("all17 historical scoped obligations must be individually accounted") }
        print("ORDINARY_C_SWITCH_EDGES observed=\(observedEdges.count) total=\(Set(literalCFG.origins.map(\.edge)).count); static topology is not whole-entry dynamic coverage")
        try rejectUnsupportedSyntax(fixture, source: source, candidate: candidate, file: file, line: line)
        try mutationChecks(fixture, source: source, candidate: candidate, scenarios: scenarios, references: references)
        try lostShiftMaskRefusal(fixture, candidate: candidate, scenarios: scenarios, references: references, file: file, line: line)
        try implicitPointerConversionRefusal(fixture, candidate: candidate, file: file, line: line)
        try widenedStoreAuthorityRefusal(candidate, layout: layout, file: file, line: line)
        print("ORDINARY_C_SWITCH_OPEN widthNumericalSensitivity=OPEN highBitNativeComparison=OPEN status=SOURCE_DRAFT_INCOMPLETE_UNSTAGED_UNRUN; no complete O1 parity claim")
    }

    private func checkCoverageWitness(_ scenario: O.Scenario, _ result: O.Result,
                                      seed: RegionalSwitchSeed,
                                      file: StaticString, line: UInt) throws {
        let first = seed == .jinit ? 152 : 153, second = seed == .jinit ? 164 : 165
        let firstLoad = first - 2, secondLoad = second - 2
        if scenario.name.hasPrefix("first-ordinal-") || scenario.name.hasPrefix("second-ordinal-") {
            let dispatch = scenario.name.hasPrefix("first-") ? first : second
            let visits = result.rowVisits[dispatch, default: 0]
            XCTAssertEqual(visits, 1, "actual decoded BR reached: \(scenario.name)", file: file, line: line)
            let selected = result.branches.filter { $0.row == dispatch && $0.taken }
            XCTAssertEqual(selected.count, 1, file: file, line: line)
        }
        if scenario.name.contains("default") {
            XCTAssertEqual(result.rowVisits[firstLoad, default: 0], 0, scenario.name, file: file, line: line)
            XCTAssertEqual(result.rowVisits[secondLoad, default: 0], 0, scenario.name, file: file, line: line)
        }
        if scenario.name == "gray-multiple-iterations" || scenario.name == "gray-four-iterations" {
            let row = seed == .jinit ? 253 : 246
            let stores = result.events.compactMap { event -> O.Write? in
                if case let .store(actualRow, address, bytes, bits) = event, actualRow == row {
                    return .init(address: address, bytes: bytes, bits: bits)
                }
                return nil
            }
            let count = scenario.name == "gray-four-iterations" ? 4 : 3
            XCTAssertEqual(stores.count, count, file: file, line: line)
            XCTAssertEqual(stores.map(\.bytes), Array(repeating: 4, count: count), file: file, line: line)
            XCTAssertEqual(stores.map(\.bits), Array(repeating: 0, count: count), file: file, line: line)
            XCTAssertEqual(result.afterRows[row + 2]?.last?.registers[9], 0,
                           "X64 counter reaches zero at actual SUBS/B.NE", file: file, line: line)
        }
    }

    private struct Located { let pc: Int; let expression: C.Expression }
    private func expressions(_ root: C.Expression) -> [C.Expression] {
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
    private func roots(_ instruction: C.Instruction) -> [C.Expression] {
        switch instruction.node {
        case let .declaration(_, e): return e.map { [$0] } ?? []
        case let .assign(left, right): return left.filter { if case .load = $0.node { return true }; return false } + right
        case let .update(e), let .branch(e, _, _): return [e]
        case let .call(_, _, c, args): return (c.map { [$0] } ?? []) + args
        case let .returned(e): return e.map { [$0] } ?? []
        case .nop, .jump, .unresolved, .unavailableReturn: return []
        }
    }
    private func uniqueExpression(_ program: C.Program, rows: Set<Int>, binary op: String) throws -> Located {
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
    private static func expressionNames(_ e: C.Expression) -> Set<String> {
        switch e.node {
        case let .name(name), let .update(name, _, _): return [name]
        case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): return expressionNames(e)
        case let .binary(_, a, b): return expressionNames(a).union(expressionNames(b))
        case let .select(a,b,c): return expressionNames(a).union(expressionNames(b)).union(expressionNames(c))
        case let .helper(_, args): return args.reduce(into: Set<String>()) { $0.formUnion(expressionNames($1)) }
        case .literal: return []
        }
    }
    private func names(_ e: C.Expression) -> Set<String> { Self.expressionNames(e) }
    private func writes(_ instruction: C.Instruction) -> Set<String> {
        switch instruction.node {
        case let .declaration(name, _): return [name]
        case let .assign(left, _): return Set(left.compactMap { if case let .name(n) = $0.node { return n }; return nil })
        case let .update(e): return names(e)
        default: return []
        }
    }
    private func observe(_ result: C.Result, expression: C.Expression, expected: [UInt64], name: String) throws {
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
            RegionalSwitchSemanticTests.expressionNames(e).reduce(into: Set<String>()) { $0.formUnion(before[pc]?[$1] ?? []) }
        }
    }
    private func boundary(_ program: C.Program, entry: Int, stop: Int) throws -> Boundary {
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
    private func upperBound(_ e: C.Expression, program: C.Program) -> UInt64? {
        if let type = program.expressionTypes[e.span], !type.pointer, type.unsigned, type.width <= 32 { return type.mask }
        switch e.node {
        case let .literal(value): return value.negative ? nil : value.bits
        case let .cast(type, operand) where type == .u64:
            guard let operandType = program.expressionTypes[operand.span], operandType.unsigned, !operandType.pointer else { return nil }
            return upperBound(operand, program: program)
        default: return nil
        }
    }
    private struct ScopeBinding {
        let boundary: Boundary
        let incoming: [String: C.Value]
        let selector: Located
        let pointer: Located
        let shiftAmount: Located?
    }
    private func highTSTUnrepresentability(_ candidate: C.Program, scenario: O.Scenario, layout l: Layout) throws -> String? {
        guard scenario.name == "tst64-high-bit-region" else { return nil }
        guard scenario.startRow == l.tst, scenario.registers[9] == 0x8000_0000_0000_0000,
              scenario.registers[10] == 0x8000_0000_0000_0000 else { throw C.Failure.invalidContract("changed historical high-bit premise") }
        let tst = try uniqueExpression(candidate, rows: [l.tst,l.tst + 1], binary: "&")
        guard candidate.expressionTypes[tst.expression.span] == .u64,
              case let .binary(_, a, b) = tst.expression.node else { throw C.Failure.invalidContract("TST64 actual parsed operand missing") }
        for (role, operand) in [("left",a),("right",b)] {
            if let maximum = upperBound(operand, program: candidate), maximum < 0x8000_0000_0000_0000 {
                return "Exact incoming bit63 on TST \(role) cannot inhabit actual unsigned narrow-to-uint64 operand, whose proven upper bound is 0x\(String(maximum, radix:16)); source reference is unchanged, native comparison OPEN, no storage widening and zero execution credit."
            }
        }
        throw C.Failure.invalidContract("high-bit OPEN explanation no longer has its actual type/range proof; needs review")
    }
    private func bindScope(_ candidate: C.Program, scenario: O.Scenario, layout l: Layout) throws -> ScopeBinding {
        guard Self.scopedNames.contains(scenario.name), scenario.name != "tst64-high-bit-region",
              scenario.stopBeforeRow == l.stop, scenario.responses.isEmpty,
              scenario.regionalBindings == Dictionary(uniqueKeysWithValues: scenario.registers.map { ("rgn_regional_r\($0.key)_0", $0.value) }) else {
            throw C.Failure.invalidContract("not one unchanged authored scoped premise")
        }
        let entryRow = scenario.startRow == l.second ? l.second : l.first
        let sub = try uniqueExpression(candidate, rows: [entryRow], binary: "-")
        guard case let .binary(_, selector, _) = sub.expression.node else { throw C.Failure.invalidContract("missing scoped selector") }
        let stop = try unique(candidate.code.enumerated().filter { _, instruction in
            roots(instruction).flatMap(expressions).contains { candidate.memorySites[$0.span] == .init(row: l.stop, effectOrdinal: 0) }
        }.map(\.offset), "actual shared-exit first memory effect")
        let entry: Int
        if scenario.startRow == l.shift - 1 {
            entry = try unique(candidate.code.enumerated().filter { _, i in
                guard (try? candidate.row(at: i.span)) == l.shift - 1 else { return false }
                if case .assign = i.node { return true }; return false
            }.map(\.offset), "actual MOV1 scoped entry")
        } else {
            guard scenario.startRow == entryRow else { throw C.Failure.invalidContract("unreviewed original scope entry") }
            entry = sub.pc
        }
        let bound = try boundary(candidate, entry: entry, stop: stop)
        let pointer = try unique(candidate.code.enumerated().flatMap { pc, i -> [Located] in
            guard case let .assign(left, _) = i.node else { return [] }
            return left.compactMap { lhs in
                guard candidate.memorySites[lhs.span] == .init(row: l.store, effectOrdinal: 0),
                      case let .load(_, address) = lhs.node else { return nil }
                return .init(pc: pc, expression: address)
            }
        }, "actual common-store address")
        var incoming: [String: C.Value] = [:]
        func bind(_ expression: C.Expression, at pc: Int, register: Int, width: Int?) throws {
            let dependencies = bound.dependencies(expression, at: pc)
            guard bound.allowed.contains(pc), dependencies.count == 1, let name = dependencies.first,
                  bound.liveIn.contains(name), incoming[name] == nil,
                  let bits = scenario.registers[register], let symbol = candidate.symbols[name],
                  !symbol.external, !symbol.type.pointer, symbol.type.unsigned,
                  bits & ~symbol.type.mask == 0,
                  width.map({ symbol.type.width == $0 }) ?? [32,64].contains(symbol.type.width) else {
                throw C.Failure.invalidContract("unproven/aliased/unrepresentable original R\(register) lexical live-in role [pc \(pc) allowed \(bound.allowed.contains(pc)) dependencies \(dependencies.sorted()) liveIn \(bound.liveIn.sorted()) types \(dependencies.sorted().map { String(describing: candidate.symbols[$0]?.type) })]")
            }
            incoming[name] = .init(bits, symbol.type)
        }
        try bind(selector, at: sub.pc, register: 8, width: nil)
        try bind(pointer.expression, at: pointer.pc, register: 20, width: 64)
        var shiftAmount: Located?
        if scenario.startRow == l.shift - 1 {
            let shift = try uniqueExpression(candidate, rows: [l.shift], binary: "<<")
            guard case let .binary(_, _, amount) = shift.expression.node else { throw C.Failure.invalidContract("missing actual shift amount") }
            try bind(amount, at: shift.pc, register: 9, width: nil)
            shiftAmount = .init(pc: shift.pc, expression: amount)
        }
        guard Set(incoming.keys) == bound.liveIn else {
            throw C.Failure.invalidContract("closed scoped liveness has extra/unbound inputs: \(bound.liveIn.subtracting(incoming.keys).sorted())")
        }
        return .init(boundary: bound, incoming: incoming,
            selector: .init(pc: sub.pc, expression: selector), pointer: pointer, shiftAmount: shiftAmount)
    }
    private func runScoped(_ candidate: C.Program, scenario: O.Scenario, bound: ScopeBinding) throws -> C.Result {
        // Every used incoming local is bound from the original authored INPUT.
        // Complete liveness above proves these inert external slots are unread.
        let inputs = Dictionary(uniqueKeysWithValues: candidate.contract.inputs.map { ($0.name,C.Value(0,$0.type)) })
        let input = C.Scenario(name: scenario.name, inputs: inputs, memory: scenario.memory.bytes, responses: [])
        return try C.Machine(program: candidate, scenario: input).run(region: .init(
            entryPC: bound.boundary.entry, stopPC: bound.boundary.stop,
            incoming: bound.incoming, allowedPCs: bound.boundary.allowed))
    }
    private func observeBoundary(_ actual: C.Result, bound: ScopeBinding, scenario: O.Scenario,
                                 reference: O.Result, rows: [InstructionRow], layout l: Layout) throws {
        let row = scenario.startRow == l.second ? l.second : l.first
        guard let selector = scenario.registers[8], let pointer = scenario.registers[20] else {
            throw C.Failure.invalidContract("missing unchanged scoped input role")
        }
        try observe(actual, expression: bound.selector.expression,
            expected: Array(repeating: selector, count: reference.rowVisits[row, default: 0]), name: scenario.name + ": incoming selector")
        guard let operand = rows[l.store].structuredOperands?.operands.last,
              case let .memory(memory) = operand,
              let displacement = UInt64(exactly: memory.displacement) else {
            throw C.Failure.invalidContract("missing common-store source displacement")
        }
        try observe(actual, expression: bound.pointer.expression,
            expected: Array(repeating: pointer + displacement, count: reference.rowVisits[l.store, default: 0]), name: scenario.name + ": common-store address")
        if let amount = bound.shiftAmount, let bits = scenario.registers[9] {
            try observe(actual, expression: amount.expression, expected: [bits & 63], name: scenario.name + ": explicit masked shift input")
        }
        for register in [19,20] {
            guard reference.finalRegisters[register] == scenario.registers[register] else {
                throw C.Failure.semanticMismatch("\(scenario.name): original R\(register) abstract frame changed")
            }
        }
    }
    private func compareScoped(_ actual: C.Result, _ expected: O.Result, contract: C.Contract, name: String) throws {
        guard actual.reachedRegionBoundary, expected.reachedRegionBoundary, !actual.returned, !expected.returned,
              actual.terminal == nil, actual.unavailableTerminal == nil, actual.consumedResponses == 0,
              expected.calls.isEmpty, actual.events == (try normalized(expected.events, contract: contract)),
              actual.memory == expected.memory.bytes else { throw C.Failure.semanticMismatch("\(name): scoped boundary/effects/bytes differ") }
    }

    private struct Definition { let pc: Int; let lhs: C.Expression; let rhs: C.Expression; let name: String }
    private func definition(_ candidate: C.Program, row: Int, matching: (C.Expression) -> Bool) throws -> Definition {
        try unique(candidate.code.enumerated().compactMap { pc, i -> Definition? in
            guard case let .assign(left,right) = i.node, left.count == 1, right.count == 1,
                  (try? candidate.row(at: right[0].span)) == row,
                  case let .name(name) = left[0].node, matching(right[0]) else { return nil }
            return .init(pc: pc, lhs: left[0], rhs: right[0], name: name)
        }, "source-bound primary scalar writer at row \(row)")
    }
    private func stripCasts(_ e: C.Expression) -> C.Expression {
        if case let .cast(_, operand) = e.node { return stripCasts(operand) }; return e
    }
    private func literalBits(_ e: C.Expression) -> UInt64? {
        if case let .literal(value) = stripCasts(e).node { return value.bits }; return nil
    }
    /// A page value is the printed literal or the machine's own `__adrp(literal)`
    /// helper, which the machine evaluates to exactly that literal as uint64_t.
    static func pageBits(_ e: C.Expression) -> UInt64? {
        func strip(_ e: C.Expression) -> C.Expression {
            if case let .cast(_, operand) = e.node { return strip(operand) }; return e
        }
        switch strip(e).node {
        case let .literal(value): return value.bits
        case let .helper("__adrp", arguments) where arguments.count == 1:
            if case let .literal(value) = strip(arguments[0]).node { return value.bits }; return nil
        default: return nil
        }
    }
    func testPageHelperIsAcceptedOnlyWithItsExactLiteral() {
        let span = C.Span(first: 0, last: 0)
        let literal = C.Expression(span: span, node: .literal(C.Value(0x59000, .u64)))
        let page = C.Expression(span: span, node: .helper("__adrp", [literal]))
        XCTAssertEqual(Self.pageBits(page), 0x59000)
        XCTAssertEqual(Self.pageBits(literal), 0x59000)
        XCTAssertNil(Self.pageBits(.init(span: span, node: .helper("__a64_sdiv32", [literal]))))
        XCTAssertNil(Self.pageBits(.init(span: span, node: .helper("__adrp", [literal, literal]))))
        XCTAssertNil(Self.pageBits(.init(span: span, node: .helper("__adrp", [.init(span: span, node: .name("x"))]))))
    }
    private func sourceWriter(_ instruction: O.Instruction) -> O.Register? {
        switch instruction {
        case let .move(r,_), let .arithmetic(_,r,_,_,_), let .page(r,_), let .relative(r,_): return r.zero ? nil : r
        case let .memory(op,registers,_) where op.hasPrefix("ld"): return registers.count == 1 ? registers[0] : nil
        default: return nil
        }
    }
    private func primaryDefinition(_ candidate: C.Program, source: O.Program, row: Int) throws -> Definition {
        do { return try primaryDefinitionUnreported(candidate, source: source, row: row) } catch C.Failure.invalidContract(let reason) {
            let near = candidate.code.enumerated().compactMap { pc, i -> String? in
                guard (try? candidate.row(at: i.span)) == row else { return nil }
                let first = i.span.first, last = min(i.span.last, candidate.tokens.count - 1)
                return "pc \(pc): " + candidate.tokens[first...last].map(\.text).joined(separator: " ")
            }
            throw C.Failure.invalidContract("\(reason) [source \(source.code[row]); output \(near)]")
        }
    }
    private func primaryDefinitionUnreported(_ candidate: C.Program, source: O.Program, row: Int) throws -> Definition {
        try definition(candidate, row: row) { rhs in
            switch source.code[row] {
            case let .page(_, value), let .relative(_, value): return Self.pageBits(rhs) == value
            case let .move(_, .immediate(value)): return literalBits(rhs) == value
            case .move(_, .register):
                if case .cast = rhs.node, case .name = stripCasts(rhs).node { return true }; return false
            case let .arithmetic(op,_,_,_,_):
                let binary = ["add":"+", "sub":"-", "subs":"-", "and":"&", "lsl":"<<", "lsr":">>"][op]
                guard let binary else { return false }
                if case let .binary(actual,_,_) = stripCasts(rhs).node { return actual == binary }; return false
            case .memory:
                return expressions(rhs).contains { candidate.memorySites[$0.span] == .init(row: row,effectOrdinal: 0) }
            default: return false
            }
        }
    }
    private func observeDefinition(_ actual: C.Result, reference: O.Result, candidate: C.Program,
                                   source: O.Program, row: Int, register: O.Register) throws -> Definition {
        let writer = try primaryDefinition(candidate, source: source, row: row)
        let snapshots = reference.afterRows[row, default: []]
        let expected = try snapshots.map { snapshot -> UInt64 in
            guard let bits = snapshot.registers[register.index] else { throw C.Failure.invalidContract("uninitialized original writer observation") }; return bits
        }
        let values = actual.evaluations.filter { $0.span == writer.rhs.span }.map(\.value.bits)
        let commits = actual.commits.filter { $0.span == writer.lhs.span && $0.name == writer.name }
        guard values == expected, commits.map(\.value.bits) == expected,
              commits.allSatisfy({ $0.value.type == C.CType(register.width,true) }),
              expected.count == reference.rowVisits[row, default: 0] else {
            throw C.Failure.semanticMismatch("source-bound R\(register.index)/\(register.width) writer or actual destination commit differs at row \(row) [source \(source.code[row]) expected \(expected.map { String($0, radix: 16) }) values \(values.map { String($0, radix: 16) }) commits \(commits.map { "\(String($0.value.bits, radix: 16)):\($0.value.type)" }) visits \(reference.rowVisits[row, default: 0]) writer \(writer.name)]")
        }
        return writer
    }
    private func observeTransient(_ actual: C.Result, reference: O.Result, candidate: C.Program,
                                  source: O.Program, layout l: Layout) throws {
        for row in [l.shift,l.zero + 1] {
            guard let register = sourceWriter(source.code[row]), register.width == 64, register.index == 9 else {
                throw C.Failure.invalidContract("literal X64 shift/counter destination changed")
            }
            _ = try observeDefinition(actual, reference: reference, candidate: candidate, source: source, row: row, register: register)
        }
        let tst = try uniqueExpression(candidate, rows: [l.tst,l.tst + 1], binary: "&")
        let snapshots = reference.afterRows[l.tst, default: []]
        let values = actual.evaluations.filter { $0.span == tst.expression.span }.map(\.value)
        guard values.count == snapshots.count else { throw C.Failure.semanticMismatch("TST64 evaluation count differs") }
        for (value,snapshot) in zip(values,snapshots) {
            guard value.type == .u64, let flags = snapshot.flags,
                  flags.n == (value.bits >> 63 != 0), flags.z == (value.bits == 0), !flags.c, !flags.v else {
                throw C.Failure.semanticMismatch("actual TST64 N/Z/C/V bits differ; no synthetic flag bank")
            }
        }
    }
    private func observeScopedRegisterWriters(_ actual: C.Result, reference: O.Result, scenario: O.Scenario,
                                             candidate: C.Program, source: O.Program) throws {
        var slots: [Int: Set<C.Span>] = [:]
        // Select writers by literal source opcode/destination and source-tagged
        // actual RHS structure, never by expected value or a native identifier.
        for row in reference.rowVisits.keys.sorted() where reference.rowVisits[row, default: 0] > 0 {
            guard let register = sourceWriter(source.code[row]), [8,9,10].contains(register.index) else { continue }
            let writer = try observeDefinition(actual, reference: reference, candidate: candidate,
                source: source, row: row, register: register)
            slots[register.index, default: []].insert(writer.lhs.span)
        }
        for register in [8,9,10] {
            if let writes = slots[register] {
                guard let last = actual.commits.last(where: { writes.contains($0.span) }),
                      last.value.bits == reference.finalRegisters[register] else {
                    throw C.Failure.semanticMismatch("\(scenario.name): source-bound last R\(register) writer differs")
                }
            } else {
                guard reference.finalRegisters[register] == scenario.registers[register] else {
                    throw C.Failure.semanticMismatch("\(scenario.name): unchanged abstract R\(register) frame differs")
                }
                // No executed writer may mean no live native cell. Preserve the
                // old initialized exit assertion as an unchanged source frame,
                // explicitly with no invented native-cell/dynamic-commit credit.
                print("ORDINARY_C_SCOPED_FRAME name=\(scenario.name) register=\(register) initialized=\(scenario.registers[register] != nil) unchangedAbstractFrame=true candidateCommitCredit=0")
            }
        }
    }
    private func mutationChecks(_ fixture: RegionalSwitchFixture, source: O.Program, candidate: C.Program,
                                scenarios: [O.Scenario], references: [String: O.Result]) throws {
        let l = try Layout(fixture.seed)
        try decoded(fixture.rows, at: l.zero, mnemonic: "str", operands: "wzr, [x8], #0x60")
        try decoded(fixture.rows, at: l.zero + 1, mnemonic: "subs", operands: "x9, x9, #1")
        try decoded(fixture.rows, at: l.first + 1, mnemonic: "cmp", operands: "w8, #9")
        try decoded(fixture.rows, at: l.first + 8, mnemonic: "br", operands: "x10")
        guard fixture.rows[l.first + 2].mnemonic == "b.hi", fixture.rows[l.stop + 1].mnemonic == "cbz" else {
            throw C.Failure.invalidContract("original bound/final-join source identity changed")
        }
        let pointer = try definition(candidate, row: l.zero) { rhs in
            guard case let .binary("+",_,offset) = stripCasts(rhs).node else { return false }
            return literalBits(offset) == 0x60 && candidate.expressionTypes[rhs.span] == .u64
        }
        let decrement = try uniqueExpression(candidate, rows: [l.zero + 1], binary: "-")
        guard case let .binary(_,_,step) = decrement.expression.node, literalBits(step) == 1,
              candidate.expressionTypes[decrement.expression.span] == .u64 else { throw C.Failure.invalidContract("actual X64 decrement anchor") }
        let stepLiteral = try unique(expressions(step).filter { if case let .literal(v) = $0.node { return v.bits == 1 }; return false }, "one actual decrement literal")
        let sub = try primaryDefinition(candidate, source: source, row: l.first)
        func equality(_ e: C.Expression, value: UInt64) -> Bool {
            guard case let .binary("==",left,right) = e.node,
                  case let .name(name) = stripCasts(left).node else { return false }
            return name == sub.name && literalBits(right) == value && candidate.expressionTypes[left.span] == .u32
        }
        let group = try unique(candidate.code.flatMap { roots($0).flatMap(expressions) }.filter { e in
            guard (try? candidate.row(at: e.span)) == l.first + 8,
                  case let .binary("||",a,b) = e.node else { return false }
            return equality(a,value: 1) && equality(b,value: 6)
        }, "actual case1/case6 shared-successor predicate")
        guard case let .binary(_, survivingCase, _) = group.node else { throw C.Failure.invalidContract("lost grouped case anchor") }
        let bound = try unique(candidate.code.compactMap { i -> C.Expression? in
            guard case let .branch(e,_,_) = i.node,
                  (try? candidate.row(at: e.span)) == l.first + 2,
                  case let .binary("<=",a,b) = e.node,
                  case let .name(name) = stripCasts(a).node, name == sub.name,
                  candidate.expressionTypes[a.span] == .u32, candidate.expressionTypes[b.span] == .u32,
                  literalBits(b) == 9 else { return nil }
            return b
        }, "actual unsigned first-dispatch <=9 bound tied to original SUB")
        let boundLiteral = try unique(expressions(bound).filter { if case let .literal(v) = $0.node { return v.bits == 9 }; return false }, "one actual unsigned bound literal")
        let finalLoad = try primaryDefinition(candidate, source: source, row: l.stop)
        let final = try unique(candidate.code.compactMap { i -> C.Expression? in
            guard case let .branch(e,_,_) = i.node, (try? candidate.row(at: e.span)) == l.stop + 1,
                  case let .binary("!=",a,b) = e.node,
                  case let .name(name) = stripCasts(a).node, name == finalLoad.name,
                  candidate.expressionTypes[a.span] == .u32, literalBits(b) == 0 else { return nil }
            return e
        }, "actual final low32 predicate tied to original load")
        guard case let .binary(_, finalLeft, finalRight) = final.node else { throw C.Failure.invalidContract("final-join operands") }
        struct Mutation { let name: String; let scenario: String; let row: Int; let lines: [C.TextLine] }
        let cases: [Mutation] = [
            .init(name: "stale-post-index-pointer", scenario: "gray-multiple-iterations", row: l.zero,
                lines: try replacing(candidate, span: pointer.rhs.span, with: "(uint64_t)(0x60094)")),
            .init(name: "counter-decrements-by-two", scenario: "gray-four-iterations", row: l.zero + 1,
                lines: try replacing(candidate, span: stepLiteral.span, with: "0x2")),
            .init(name: "lost-shared-successor-label-six", scenario: "first-ordinal-6", row: l.first + 8,
                lines: try replacing(candidate, span: group.span, with: text(candidate, survivingCase.span))),
            .init(name: "upper-bound-routes-nine-to-default", scenario: "first-ordinal-9", row: l.first + 1,
                lines: try replacing(candidate, span: boundLiteral.span, with: "0x8")),
            .init(name: "final-join-selects-other-predecessor", scenario: "exit-low32-nonzero", row: l.stop + 1,
                lines: try replacing(candidate, span: final.span,
                    with: "((\(text(candidate, finalLeft.span))) == (\(text(candidate, finalRight.span))))"))
        ]
        for mutation in cases {
            let scenario = try unique(scenarios.filter { $0.name == mutation.scenario }, "original numeric mutation scenario")
            guard let expected = references[scenario.name], expected.rowVisits[mutation.row, default: 0] > 0 else {
                throw C.Failure.invalidContract("missing reached original numeric mutation site")
            }
            // Exact same strict manifest, protected calls, memory widths and
            // unchanged original scenario. No rejection is caught as a kill.
            let mutant = try C.Program(lines: mutation.lines, contract: candidate.contract)
            let input = try C.scenario(scenario, contract: candidate.contract)
            let actual: C.Result
            do { actual = try C.Machine(program: mutant, scenario: input).run() }
            catch { throw C.Failure.invalidContract("mutation \(mutation.name) in \(scenario.name): \(error)") }
            let events = try normalized(expected.events, contract: candidate.contract)
            guard expected.returned, actual.returned, !actual.reachedRegionBoundary,
                  actual.terminal == nil, actual.unavailableTerminal == nil,
                  actual.consumedResponses == input.responses.count,
                  calls(actual.events) == calls(events), actual.events != events,
                  actual.memory != expected.memory.bytes else {
                throw C.Failure.semanticMismatch("\(mutation.name): no normal-return exact-K event/byte divergence")
            }
            let stores = writes(actual.events, row: l.zero)
            let namedWitness: Bool
            switch mutation.name {
            case "stale-post-index-pointer":
                namedWitness = stores.map(\.address) == [0x60094,0x60094,0x60094] && stores.map(\.bytes) == [4,4,4]
            case "counter-decrements-by-two":
                namedWitness = stores.map(\.address) == [0x60094,0x600f4] && stores.map(\.bytes) == [4,4]
            case "lost-shared-successor-label-six":
                let before = writes(events,row: l.store), after = writes(actual.events,row: l.store)
                namedWitness = before.count == 1 && after.count == 1 && before[0].bits != after[0].bits
                // Static topology failure is separate evidence, not a numeric
                // receipt or substitute for the concrete selected-store change.
                let graph = try L.analyze(candidate: mutant, source: L.source(rows: fixture.rows, color: fixture.capture))
                XCTAssertThrowsError(try graph.requireCompleteTopology())
                let missingSix = graph.accounts.filter { $0.origin.row == l.first + 8 && $0.origin.role == .tableCase(6) }
                XCTAssertEqual(missingSix.count,1)
                XCTAssertTrue(missingSix.contains { $0.disposition == .unresolved })
                XCTAssertTrue(graph.accounts.contains { $0.origin.row == l.first + 8 && $0.origin.role == .tableCase(1) && $0.disposition != .unresolved })
            case "upper-bound-routes-nine-to-default":
                let before = writes(events,row: l.store), after = writes(actual.events,row: l.store)
                namedWitness = loads(events,row: l.first + 6).count == 1 && loads(actual.events,row: l.first + 6).isEmpty &&
                    before.count == 1 && after.count == 1 && before[0].bits != after[0].bits
            case "final-join-selects-other-predecessor":
                let before = writes(events,row: l.stop + 5), after = writes(actual.events,row: l.stop + 5)
                namedWitness = loads(events,row: l.stop + 4).isEmpty && loads(actual.events,row: l.stop + 4).count == 1 &&
                    before.count == 1 && after.count == 1 && before[0].bits != after[0].bits
            default: throw C.Failure.invalidContract("unknown numerical mutation witness")
            }
            // Fail closed BEFORE printing: an unrelated mismatch or refusal
            // must never earn the named numerical mutation receipt.
            guard namedWitness else { throw C.Failure.semanticMismatch("\(mutation.name): named address/store/load witness absent") }
            print("ORDINARY_C_SWITCH_NUMERICAL_MUTATION name=\(mutation.name) scenario=\(scenario.name) normalReturn=true exactK=true namedWitness=true eventAndByteDivergence=true")
        }
    }
    private func lostShiftMaskRefusal(_ fixture: RegionalSwitchFixture, candidate: C.Program,
                                     scenarios: [O.Scenario], references: [String: O.Result],
                                     file: StaticString, line: UInt) throws {
        let l = try Layout(fixture.seed)
        let scenario = try unique(scenarios.filter { $0.name == "shift-region-64" }, "unchanged shift64 scoped premise")
        guard references[scenario.name]?.rowVisits[l.shift] == 1 else { throw C.Failure.invalidContract("shift refusal reference not reached") }
        let shift = try uniqueExpression(candidate, rows: [l.shift], binary: "<<")
        guard case let .binary(_,_,amount) = shift.expression.node,
              case let .binary("&",raw,mask) = amount.node, literalBits(mask) == 63 else {
            throw C.Failure.invalidContract("actual explicit shift mask missing")
        }
        let mutant = try C.Program(lines: replacing(candidate, span: amount.span, with: text(candidate,raw.span)), contract: candidate.contract)
        let bound = try bindScope(mutant, scenario: scenario, layout: l)
        XCTAssertThrowsError(try runScoped(mutant, scenario: scenario, bound: bound),
            "definedness refusal only, never a numerical kill", file: file, line: line) { error in
            guard case C.Failure.undefinedC("shift count outside promoted-left width") = error else {
                XCTFail("shift-mask refusal failed for unrelated reason: \(error)", file: file, line: line); return
            }
        }
    }
    private func implicitPointerConversionRefusal(_ fixture: RegionalSwitchFixture, candidate: C.Program,
                                                 file: StaticString, line: UInt) throws {
        try decoded(fixture.rows, at: 3, mnemonic: "mov", operands: "x19, x0")
        let parameter = try unique(candidate.contract.inputs.filter { $0.entrySlot == 0 && $0.type.pointer }, "actual original pointer formal")
        let writer = try definition(candidate,row: 3) { e in
            guard case let .cast(type,operand) = e.node, type == .u64,
                  case let .name(name) = operand.node else { return false }; return name == parameter.name
        }
        guard case let .cast(_,operand) = writer.rhs.node else { throw C.Failure.invalidContract("actual explicit pointer conversion missing") }
        let lines = try replacing(candidate, span: writer.rhs.span, with: text(candidate,operand.span))
        XCTAssertThrowsError(try C.Program(lines: lines, contract: candidate.contract),
            "strict pointer representation refusal only, never a numerical kill", file: file, line: line) { error in
            guard case let C.Failure.unsupportedSyntax(reason) = error,
                  ["pointer arithmetic/comparison requires explicit representation cast", "memory requires explicit integer byte address"].contains(reason) else {
                XCTFail("pointer cast refusal failed for unrelated reason: \(error)", file: file, line: line); return
            }
        }
    }
    private func widenedStoreAuthorityRefusal(_ candidate: C.Program, layout l: Layout,
                                             file: StaticString, line: UInt) throws {
        let store = try unique(candidate.code.flatMap { instruction -> [C.Expression] in
            guard case let .assign(left,_) = instruction.node else { return [] }
            return left.filter { candidate.memorySites[$0.span] == .init(row: l.zero,effectOrdinal: 0) }
        }, "original four-byte zero-store AST")
        guard case let .load(type,address) = store.node, type == .u32,
              candidate.contract.memoryEffects[l.zero]?.count == 1,
              candidate.contract.memoryEffects[l.zero]?.first?.bytes == 4,
              candidate.contract.memoryEffects[l.zero]?.first?.loading == false else {
            throw C.Failure.invalidContract("original zero-store width/authority drift")
        }
        let lines = try replacing(candidate, span: store.span, with: "*(uint64_t *)(\(text(candidate,address.span)))")
        XCTAssertThrowsError(try C.Program(lines: lines, contract: candidate.contract),
            "widened-store authority refusal is NOT numerical width sensitivity", file: file, line: line) { error in
            guard case let C.Failure.invalidContract(reason) = error, reason == "memory width/order differs at row \(l.zero), effect 0" else {
                XCTFail("width authority refused for unrelated reason: \(error)", file: file, line: line); return
            }
        }
        // The original case259-261 and its shared detector application287-301
        // with named width/address expectations306-308 remain verbatim archived.
        // Their exact numerical sensitivity is OPEN, not passed by this refusal.
    }
    private func rejectUnsupportedSyntax(_ fixture: RegionalSwitchFixture, source: O.Program, candidate: C.Program,
                                         file: StaticString, line: UInt) throws {
        for kind in [PseudocodeLineKind.instruction, .metadata, .signature, .closingBrace] {
            var changed = fixture.document
            changed.lines.insert(.init(lineNumber: 0, kind: kind, text: "oracle_unknown_helper();"), at: 1)
            XCTAssertThrowsError(try C.Program(lines: C.lines(changed), contract: candidate.contract),
                                 "unknown syntax must not be ignored even as metadata", file: file, line: line)
        }
        for statement in ["if (false) { 1 = 2; }", "switch (1) { default: break; }", "return 0;", "return unresolved_return_contract;",
                          "if (false) { uint032_t noncanonical = 0; }",
                          "if (false) { int00064_t noncanonical = 0; }"] {
            var changed = fixture.document
            changed.lines.insert(.init(lineNumber: 0, text: statement), at: changed.lines.count - 1)
            XCTAssertThrowsError(try C.Program(lines: C.lines(changed), contract: candidate.contract),
                                 "unreachable unsupported source/output cannot disappear: \(statement)", file: file, line: line)
        }
        XCTAssertNil(C.CType.named("uint032_t"), "only canonical fixed-width type names", file: file, line: line)
        XCTAssertNil(C.CType.named("int00064_t"), "only canonical fixed-width type names", file: file, line: line)
        for statement in ["if (false) { *(uint64_t *)((uint64_t)(0x10000)) = 1; }",
                          "if (false) { oracle_hidden = *(uint64_t *)((uint64_t)(0x10000)); }"] {
            var changed = fixture.document
            changed.lines.insert(.init(lineNumber: 0, text: statement), at: changed.lines.count - 1)
            XCTAssertThrowsError(try C.Program(lines: C.lines(changed), contract: candidate.contract),
                                 "unreachable memory is statically source-associated", file: file, line: line) { error in
                guard case let C.Failure.invalidContract(reason) = error, reason.hasPrefix("missing source identity at token ") else {
                    XCTFail("unsourced memory failed for an unrelated reason: \(error)", file: file, line: line)
                    return
                }
            }
        }
        // Explicitly derived refusal contract, not new real-binary coverage.
        // No payload/state from this unit is admitted as a positive fixture.
        guard let retained = source.opaqueSites.values.sorted(by: { $0.row < $1.row }).first,
              let assignment = retained.exactStatement.range(of: " = ") else {
            throw O.Failure.invalid("missing baseline assignment for printless refusal unit")
        }
        let printless = String(retained.exactStatement[assignment.upperBound...])
        let unbound = O.OpaqueSite(row: retained.row, address: retained.address, frame: retained.frame,
                                  exactStatement: printless, printedDestination: nil)
        XCTAssertNil(try T.OpaqueSite(unbound).destination, "printless K has no exposed result", file: file, line: line)
        let fabricated = O.OpaqueSite(row: retained.row, address: retained.address, frame: retained.frame,
                                     exactStatement: "new_result = " + printless, printedDestination: nil)
        XCTAssertThrowsError(try T.OpaqueSite(fabricated), "printless K must not acquire a binding", file: file, line: line)
        let row = fixture.rows[0]
        let bad = InstructionRow(address: row.address, bytes: row.bytes, mnemonic: "oracle_unknown_opcode",
                                 operands: row.operands, hasBreakpoint: row.hasBreakpoint,
                                 comment: row.comment, structuredOperands: row.structuredOperands)
        XCTAssertThrowsError(try O.Program.parse(bad), "source unknown opcode must throw", file: file, line: line)
        for payload in fixture.callPayloads {
            let indices = fixture.document.lines.indices.filter {
                fixture.document.lines[$0].sourceAddress == payload.address &&
                RegionalSwitchFixture.payload(fixture.document.lines[$0].text) == payload.baseline
            }
            guard indices.count == 1, let index = indices.first else { throw O.Failure.invalid("exact call mutation site absent") }
            var changed = fixture.document
            changed.lines[index].text += " changed"
            XCTAssertThrowsError(try C.Program(lines: C.lines(changed), contract: candidate.contract),
                                 "even a call comment is frozen C4 payload", file: file, line: line)
        }
    }

    private func byteRange(_ program: C.Program, _ span: C.Span) throws -> Range<Int> {
        guard span.first < span.last, program.tokens.indices.contains(span.first), program.tokens.indices.contains(span.last - 1) else { throw C.Failure.invalidContract("mutation token span") }
        return program.tokens[span.first].byteOffset..<(program.tokens[span.last - 1].byteOffset + program.tokens[span.last - 1].text.utf8.count)
    }
    private func text(_ program: C.Program, _ span: C.Span) throws -> String {
        let bytes = Array(program.lines.map(\.text).joined(separator: "\n").utf8)
        return String(decoding: bytes[try byteRange(program, span)], as: UTF8.self)
    }
    private func replacing(_ program: C.Program, span: C.Span, with replacement: String) throws -> [C.TextLine] {
        let range = try byteRange(program, span), first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line, !replacement.contains("\n") else { throw C.Failure.invalidContract("mutation requires one actual statement/expression line") }
        let line = first.line - 1
        guard program.lines[line].envelope == .body else { throw C.Failure.invalidContract("mutation touches envelope") }
        let row = program.lines[line].source.flatMap { program.contract.rowsByAddress[$0] }
        guard row != program.contract.terminalRow, row.flatMap({ program.contract.exterior[$0] }) == nil,
              row.flatMap({ program.contract.calls[$0] }) == nil else { throw C.Failure.invalidContract("mutation touches protected payload row") }
        let offset = program.lines.prefix(line).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(program.lines[line].text.utf8)
        bytes.replaceSubrange((range.lowerBound - offset)..<(range.upperBound - offset), with: replacement.utf8)
        var lines = program.lines
        lines[line] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[line].source, envelope: lines[line].envelope)
        return lines
    }
    private func unique<T>(_ values: [T], _ identity: String) throws -> T {
        guard values.count == 1 else { throw C.Failure.invalidContract("missing/ambiguous \(identity): \(values.count)") }; return values[0]
    }
    private func decoded(_ rows: [InstructionRow], at row: Int, mnemonic: String, operands: String) throws {
        guard rows.indices.contains(row), rows[row].mnemonic == mnemonic, rows[row].operands == operands else {
            throw C.Failure.invalidContract("literal mutation anchor differs at original row \(row)")
        }
    }
    private func calls(_ events: [C.Event]) -> [C.CallEvent] {
        events.compactMap { if case let .call(value) = $0 { return value }; return nil }
    }
    private func writes(_ events: [C.Event], row: Int) -> [C.ByteWrite] {
        events.compactMap { if case let .store(site,_,address,bytes,bits) = $0, site.row == row {
            return .init(address: address,bytes: bytes,bits: bits)
        }; return nil }
    }
    private func loads(_ events: [C.Event], row: Int) -> [C.ByteWrite] {
        events.compactMap { if case let .load(site,_,address,bytes,bits) = $0, site.row == row {
            return .init(address: address,bytes: bytes,bits: bits)
        }; return nil }
    }
    private func normalized(_ events: [O.Event], contract: C.Contract) throws -> [C.Event] {
        var counts: [Int:Int] = [:]
        return try events.map { event in
            switch event {
            case let .call(call):
                return .call(.init(row: call.row,occurrence: call.occurrence,target: call.target,
                    control: call.control.map { .init(register: $0.register,width: $0.width,bits: $0.bits) },
                    arguments: call.arguments.map { .init(register: $0.register,width: $0.width,bits: $0.bits) },
                    result: call.result,writes: call.writes.map { .init(address: $0.address,bytes: $0.bytes,bits: $0.bits) }))
            case let .load(row,address,bytes,bits), let .store(row,address,bytes,bits):
                guard let effects = contract.memoryEffects[row], !effects.isEmpty else { throw C.Failure.invalidContract("reference memory effect lacks original manifest") }
                let count = counts[row,default: 0]; counts[row] = count + 1
                let site = C.SourceSite(row: row,effectOrdinal: count % effects.count), occurrence = count / effects.count
                if case .load = event { return .load(site,occurrence,address,bytes,bits) }
                return .store(site,occurrence,address,bytes,bits)
            }
        }
    }
}

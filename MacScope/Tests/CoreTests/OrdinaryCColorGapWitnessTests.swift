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

/// SOURCE_ONLY / NOT_RUN. Exactly 17 genuinely new complete-entry pairs per
/// seed. One actual complete fixture/render per selector, no historical selector
/// or successful scenario replay, and no second evaluator pass for observations.
final class OrdinaryCColorGapWitnessTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias O = RegionalSwitchOracle
    private typealias L = OrdinaryCSourceEdgeLedger
    private typealias W = OrdinaryCColorGapWitnesses

    func testColor26c78GapWitnesses() throws { try run(.jinit) }
    func testColor122893cGapWitnesses() throws { try run(.j12init) }

    private struct Completed {
        let witness: W.Witness
        let actual: C.Result
        let reference: O.Result
    }

    private func run(_ seed: RegionalSwitchSeed) throws {
        let fixture = try RegionalSwitchFixture.make(seed)
        let audit = try OrdinaryCOutputAudit.analyze(document: fixture.document,
            function: fixture.function, baselineText: fixture.baselineText)
        guard audit.errors.isEmpty, !audit.tokens.contains(where: { $0.text.hasPrefix("rgn_regional_") }) else {
            throw C.Failure.unsupportedSyntax("COLOR_GAP_PREREQUISITE: actual complete ordinary output failed: \(audit.errors)")
        }
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try C.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.baselineText, callRows: seed.callRows, blockAddresses: blocks)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try O.Program(fixture: fixture)
        let sourceEdges = try L.source(rows: fixture.rows, color: fixture.capture)
        let report = try L.analyze(candidate: candidate, source: sourceEdges)
        try report.requireCompleteTopology()
        let layout = try W.Layout(seed)
        let witnesses = try W.make(layout)
        try W.requireConditionalNonexecution(source, ledger: sourceEdges, layout: layout, witnesses: witnesses)
        try requireManifest(report, layout: layout, witnesses: witnesses)
        var completed: [Completed] = []
        for witness in witnesses {
            let scenario = witness.scenario
            // Pass the unchanged original-source visits/absences into the source
            // machine. Candidate inputs contain ONLY original entry registers,
            // sparse initial memory and explicit ordered returning-K responses.
            let reference = try O.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: reference.events, memory: reference.memory.bytes,
                returned: reference.returned, terminal: nil, contract: contract, name: scenario.name)
            XCTAssertTrue(reference.returned && actual.returned, scenario.name)
            XCTAssertFalse(reference.reachedRegionBoundary || actual.reachedRegionBoundary, scenario.name)
            XCTAssertNil(actual.terminal, "original color terminal is void, not physical X0")
            let pair = Completed(witness: witness, actual: actual, reference: reference)
            try observeLiteralEffects(pair, layout: layout, source: source, candidate: candidate)
            if witness.id == 10 || witness.id == 11 {
                try observeGrayRecurrence(pair, candidate: candidate, layout: layout)
            }
            completed.append(pair)
        }
        // Reuse exactly these completed pairs. L.observe reconstructs independent
        // source/candidate edge traces from observations; neither machine reruns.
        try observeCoverage(completed, report: report, candidate: candidate, layout: layout)
    }

    private func requireManifest(_ report: L.Report, layout: W.Layout, witnesses: [W.Witness]) throws {
        let edges = W.edges(layout.seed), slots = W.slots(layout.seed)
        XCTAssertEqual(witnesses.map(\.id), Array(1...17))
        XCTAssertEqual(Set(witnesses.map { $0.scenario.name }).count, 17)
        XCTAssertEqual(edges.count, 50)
        XCTAssertEqual(Set(edges.map(\.edge)).count, 50)
        XCTAssertEqual(edges.filter { !$0.witnesses.isEmpty }.count, 46)
        XCTAssertEqual(edges.filter { $0.witnesses.isEmpty }.count, 4)
        XCTAssertEqual(slots.count, 17)
        XCTAssertEqual(Set(slots.map(\.pc)).count, 17)
        XCTAssertEqual(slots.filter { !$0.witnesses.isEmpty }.count, 15)
        XCTAssertEqual(slots.filter { $0.witnesses.isEmpty }.count, 2)
        for item in edges {
            guard report.source.origins.contains(where: { $0.edge == item.edge && $0.row == item.sourceRow }),
                  report.source.blocks[item.edge.toBlock].rows.lowerBound == item.destinationRow else {
                throw C.Failure.invalidContract("color gap edge manifest drift: \(edgeName(item.edge))")
            }
        }
        for item in slots {
            // Freeze the actual residual occurrence, not a source row guessed to
            // imply a goto. Any changed parsed-PC/token/target mapping fails.
            guard report.residualSlots.contains(where: {
                $0.pc == item.pc && $0.span == item.span && $0.target == item.target
            }) else { throw C.Failure.invalidContract("color gap residual manifest drift at PC \(item.pc)") }
        }
        let promised = witnesses.reduce(into: Set<C.SourceEdge>()) { $0.formUnion($1.edges) }
        let promisedSlots = witnesses.reduce(into: Set<Int>()) { $0.formUnion($1.residualPCs) }
        XCTAssertEqual(promised, Set(edges.filter { !$0.witnesses.isEmpty }.map(\.edge)))
        XCTAssertEqual(promisedSlots, Set(slots.filter { !$0.witnesses.isEmpty }.map(\.pc)))
        print("ORDINARY_C_COLOR_GAP_LIMITS seed=\(layout.seed.name) newPairs=17 targetCFGEdges=46 targetResidualPCs=15 conditionalNonexecutionEdges=4 conditionalNonexecutionResidualPCs=2 historicalAmbiguousOccurrencesUnresolved=18; returning-K/frozen-table scope only; no universal equivalence, case-role coverage or historical replay credit")
    }

    private func observeCoverage(_ completed: [Completed], report: L.Report,
                                 candidate: C.Program, layout: W.Layout) throws {
        var edges: Set<C.SourceEdge> = [], slots: Set<C.Span> = []
        var ambiguous = 0
        let slotPC = Dictionary(uniqueKeysWithValues: report.residualSlots.map { ($0.span,$0.pc) })
        for pair in completed {
            let name = pair.witness.scenario.name
            let observation = try L.observe(report, candidate: candidate, actual: pair.actual,
                referenceBranches: pair.reference.branches, referenceRowVisits: pair.reference.rowVisits,
                referenceReturned: pair.reference.returned, name: name)
            let observed = Set(observation.sourceEdges)
            let observedPCs = Set(observation.residualOccurrences.keys.compactMap { slotPC[$0] })
            let missingEdges = pair.witness.edges.subtracting(observed)
            let missingSlots = pair.witness.residualPCs.subtracting(observedPCs)
            let ambiguousGroups = observation.possibleOriginGroups.filter { $0.count > 1 }
            // Never choose an ordinal from a target or scenario label. Each
            // plural possible-role group is printed as ONE unresolved occurrence.
            for (occurrence, group) in ambiguousGroups.enumerated() {
                print("ORDINARY_C_COLOR_GAP_AMBIGUITY scenario=\(name) occurrence=\(occurrence) possibleOrigins=\(group.map(originName).sorted()) exactCaseOrdinal=UNRESOLVED")
            }
            print("ORDINARY_C_COLOR_GAP_PAIR scenario=\(name) promisedEdges=\(pair.witness.edges.map(edgeName).sorted()) missingPromisedEdges=\(missingEdges.map(edgeName).sorted()) promisedResidualPCs=\(pair.witness.residualPCs.sorted()) missingPromisedResidualPCs=\(missingSlots.sorted()) observedResidualPCs=\(observedPCs.sorted()) ambiguousOccurrences=\(ambiguousGroups.count)")
            XCTAssertTrue(missingEdges.isEmpty, "\(name): promised independent edge subset missing: \(missingEdges.map(edgeName).sorted())")
            XCTAssertTrue(missingSlots.isEmpty, "\(name): promised actual residual subset missing: \(missingSlots.sorted())")
            edges.formUnion(observed)
            slots.formUnion(observation.residualOccurrences.keys)
            ambiguous += ambiguousGroups.count
        }
        let plannedEdges = W.edges(layout.seed), plannedSlots = W.slots(layout.seed)
        let targets = Set(plannedEdges.filter { !$0.witnesses.isEmpty }.map(\.edge))
        let exclusions = Set(plannedEdges.filter { $0.witnesses.isEmpty }.map(\.edge))
        let targetSlots = Set(plannedSlots.filter { !$0.witnesses.isEmpty }.map(\.pc))
        let excludedSlots = Set(plannedSlots.filter { $0.witnesses.isEmpty }.map(\.pc))
        let observedPCs = Set(slots.compactMap { slotPC[$0] })
        let missingTargets = targets.subtracting(edges), missingSlots = targetSlots.subtracting(observedPCs)
        let allMissing = Set(report.source.origins.map(\.edge)).subtracting(edges)
        let allMissingSlots = report.residualSlots.filter { !slots.contains($0.span) }.map(\.pc).sorted()
        print("ORDINARY_C_COLOR_GAP_OBSERVATION seed=\(layout.seed.name) completedNewPairs=\(completed.count) observedTargetEdges=\(targets.intersection(edges).count)/46 missingTargetEdges=\(missingTargets.map(edgeName).sorted()) observedTargetResidualPCs=\(targetSlots.intersection(observedPCs).count)/15 missingTargetResidualPCs=\(missingSlots.sorted()) newOnlyUnobservedCFGEdges=\(allMissing.map(edgeName).sorted()) newOnlyUnobservedResidualPCs=\(allMissingSlots) newAmbiguousOccurrences=\(ambiguous) historicalAmbiguousOccurrencesUnresolved=18")
        print("ORDINARY_C_COLOR_GAP_CONDITIONAL_NONEXECUTION edges=\(exclusions.map(edgeName).sorted()) residualPCs=\(excludedSlots.sorted()) coverageCredit=0 premise=unchanged-frozen-instructions-and-dispatch-bytes; arbitrary-table-writing-callbacks-not-covered")
        XCTAssertEqual(completed.count, 17)
        XCTAssertTrue(missingTargets.isEmpty)
        XCTAssertTrue(missingSlots.isEmpty)
        XCTAssertTrue(exclusions.isDisjoint(with: edges), "conditional premise contradicted; do not silently relabel as coverage")
        XCTAssertTrue(excludedSlots.isDisjoint(with: observedPCs), "conditionally excluded residual actually observed")
    }

    private struct Effect: Equatable {
        let row: Int
        let loading: Bool
        let address: UInt64
        let bytes: Int
        let bits: UInt64
    }
    private func effects(_ result: C.Result, row: Int) -> [Effect] {
        result.events.compactMap { event in
            switch event {
            case let .load(site, _, address, bytes, bits) where site.row == row:
                return .init(row: row, loading: true, address: address, bytes: bytes, bits: bits)
            case let .store(site, _, address, bytes, bits) where site.row == row:
                return .init(row: row, loading: false, address: address, bytes: bytes, bits: bits)
            default: return nil
            }
        }
    }
    private func effects(_ result: O.Result, row: Int) -> [Effect] {
        result.events.compactMap { event in
            switch event {
            case let .load(sourceRow, address, bytes, bits) where sourceRow == row:
                return .init(row: row, loading: true, address: address, bytes: bytes, bits: bits)
            case let .store(sourceRow, address, bytes, bits) where sourceRow == row:
                return .init(row: row, loading: false, address: address, bytes: bytes, bits: bits)
            default: return nil
            }
        }
    }
    private func requireEffects(_ pair: Completed, row: Int, _ expected: [Effect]) {
        XCTAssertEqual(effects(pair.reference, row: row), expected, "\(pair.witness.scenario.name): literal source effects row \(row)")
        XCTAssertEqual(effects(pair.actual, row: row), expected, "\(pair.witness.scenario.name): actual-text effects row \(row)")
    }

    private func observeLiteralEffects(_ pair: Completed, layout l: W.Layout, source: O.Program, candidate: C.Program) throws {
        let scenario = pair.witness.scenario, id = pair.witness.id
        let calls = pair.actual.events.compactMap { event -> C.CallEvent? in
            if case let .call(call) = event { return call }; return nil
        }
        XCTAssertEqual(calls.map(\.row), scenario.responses.map(\.row), scenario.name)
        XCTAssertEqual(pair.reference.calls.map(\.row), scenario.responses.map(\.row), scenario.name)
        for (call, response) in zip(calls,scenario.responses) {
            XCTAssertEqual(call.result, response.result)
            XCTAssertEqual(call.arguments.map(\.bits), try XCTUnwrap(response.expectedArguments))
            XCTAssertEqual(call.control.map(\.bits), try XCTUnwrap(response.expectedControl))
            XCTAssertEqual(call.writes, response.writes.map { .init(address: $0.address,bytes: $0.bytes,bits: $0.bits) })
            XCTAssertTrue(call.control.allSatisfy { $0.width == 64 && $0.bits >> 63 == 1 })
        }
        // Check unchanged-byte premises after actual execution, including direct
        // stores. The static proof is not permission to ignore a table mutation.
        for (base, bytes) in [(l.firstTable,l.firstBytes),(l.firstTable + 10,l.secondBytes)] {
            let addresses = Set(bytes.indices.map { base + UInt64($0) })
            for (offset, byte) in bytes.enumerated() {
                XCTAssertEqual(pair.reference.memory.bytes[base + UInt64(offset)], byte)
                XCTAssertEqual(pair.actual.memory[base + UInt64(offset)], byte)
            }
            for event in pair.actual.events {
                if case let .store(_, _, address, width, _) = event {
                    XCTAssertTrue((0..<width).allSatisfy { !addresses.contains(address &+ UInt64($0)) })
                }
            }
        }
        if id == 1 || id == 2 {
            requireEffects(pair, row: 13, [
                .init(row: 13,loading: false,address: W.errorManager + 0x28,bytes: 4,bits: 0x10),
                .init(row: 13,loading: false,address: W.errorManager + 0x2c,bytes: 4,bits: 1)])
            XCTAssertEqual(try pair.reference.memory.load(W.errorManager + 0x2c,bytes: 4), 1,
                           "later four-byte error store must preserve neighboring precision word")
        }
        if id == 2 {
            let row = l.seed == .jinit ? 171 : 172
            requireEffects(pair, row: row, [.init(row: row,loading: true,address: W.context + 0x38,bytes: 4,bits: 5)])
        }
        if id == 8 || id == 9 {
            let ditherRow = l.seed == .jinit ? 123 : 124, inputRow = ditherRow + 1
            requireEffects(pair, row: ditherRow, [.init(row: ditherRow,loading: true,address: W.context + 0x70,bytes: 4,bits: id == 8 ? 1 : 0)])
            requireEffects(pair, row: inputRow, [.init(row: inputRow,loading: true,address: W.context + 0x3c,bytes: 4,bits: 4)])
        }
        if id == 10 || id == 11 {
            let pointer: UInt64 = id == 10 ? W.context - 0x5c : 0x0000_0001_ffff_ff6c
            let stores: [UInt64] = id == 10 ? [0x10038,0x10098,0x100f8] : [0x200000000,0x200000060,0x2000000c0]
            requireEffects(pair, row: l.countLoad, [.init(row: l.countLoad,loading: true,address: W.context + 0x38,bytes: 4,bits: 4)])
            requireEffects(pair, row: l.pointerLoad, [.init(row: l.pointerLoad,loading: true,address: W.context + 0x130,bytes: 8,bits: pointer)])
            requireEffects(pair, row: l.loopStore, stores.map { .init(row: l.loopStore,loading: false,address: $0,bytes: 4,bits: 0) })
            let afterStores = try XCTUnwrap(pair.reference.afterRows[l.loopStore])
            XCTAssertEqual(try afterStores.map { try XCTUnwrap($0.registers[8]) }, stores.map { $0 + 0x60 })
            XCTAssertEqual(try afterStores.map { try XCTUnwrap($0.registers[9]) }, [3,2,1])
            if id == 10 {
                XCTAssertEqual(try pair.reference.memory.load(W.context + 0x38,bytes: 4), 0)
                // Three stores are mandatory despite the first clearing count.
                // Literal adjacent cells additionally expose accidental widening.
                XCTAssertEqual(try pair.reference.memory.load(W.context + 0x3c,bytes: 4), 1)
            } else {
                let callbackRow = l.seed == .jinit ? 234 : 227
                let callIndex = try XCTUnwrap(pair.actual.events.firstIndex { if case let .call(c) = $0 { return c.row == callbackRow }; return false })
                let countIndex = try XCTUnwrap(pair.actual.events.firstIndex { if case let .load(site,_,_,_,_) = $0 { return site.row == l.countLoad }; return false })
                let pointerIndex = try XCTUnwrap(pair.actual.events.firstIndex { if case let .load(site,_,_,_,_) = $0 { return site.row == l.pointerLoad }; return false })
                let storeIndex = try XCTUnwrap(pair.actual.events.firstIndex { if case let .store(site,_,_,_,_) = $0 { return site.row == l.loopStore }; return false })
                XCTAssertLessThan(callIndex,countIndex); XCTAssertLessThan(countIndex,pointerIndex); XCTAssertLessThan(pointerIndex,storeIndex)
            }
        }
        if id == 17 {
            requireEffects(pair, row: 87, [
                .init(row: 87,loading: true,address: W.context + 0x3c,bytes: 4,bits: 3),
                .init(row: 87,loading: true,address: W.context + 0x40,bytes: 4,bits: 5)])
            requireEffects(pair, row: 90, [.init(row: 90,loading: true,address: l.countTable + 5 * 4,bytes: 4,bits: 0xffff_ffff)])
            requireEffects(pair, row: l.pointerTableLoad, [])
            XCTAssertEqual(source.rows[l.pointerGuard].mnemonic, "b.hi")
            XCTAssertEqual(source.rows[l.pointerGuard - 1].mnemonic, "cmp")
            XCTAssertEqual(source.rows[l.pointerGuard - 1].operands, "w8, #9")
            XCTAssertEqual(pair.reference.branches.filter { $0.row == l.pointerGuard },
                           [.init(row: l.pointerGuard,taken: true,target: source.rows[l.pointerFallback].address)])
            let guards = candidate.code.compactMap { instruction -> C.Expression? in
                guard case let .branch(expression,_,_) = instruction.node,
                      (try? candidate.row(at: expression.span)) == l.pointerGuard else { return nil }
                return expression
            }
            guard guards.count == 1, case let .binary(op,left,right) = guards[0].node,
                  op == "<=", candidate.expressionTypes[left.span] == .u32,
                  candidate.expressionTypes[right.span] == .u32,
                  case let .cast(type,bound) = right.node, type == .u32,
                  case let .literal(value) = bound.node, value.bits == 9 else {
                throw C.Failure.invalidContract("W17 requires its actual parsed unsigned direct guard, not a lifted BR-default role")
            }
            XCTAssertEqual(pair.actual.evaluations.filter { $0.span == guards[0].span }.map(\.value.bits), [0],
                           "actual unsigned <=9 guard must choose the fallback for wrapping 5-6")
            for event in pair.actual.events {
                if case let .load(_,_,address,width,_) = event {
                    XCTAssertTrue((0..<width).allSatisfy { !(l.pointerTable..<(l.pointerTable + 80)).contains(address &+ UInt64($0)) },
                                  "direct guard must not read a pointer-table cell")
                }
            }
            if l.seed == .jinit {
                let probe = try XCTUnwrap(calls.first { $0.row == 99 })
                XCTAssertEqual(probe.result, 0x0000_0001_0000_0000)
                XCTAssertEqual(pair.reference.branches.filter { $0.row == 100 }.map(\.taken), [true],
                               "original CBZ reads only low32 of a high64 nonzero result")
            }
        }
        print("ORDINARY_C_COLOR_GAP_EFFECTS scenario=\(scenario.name) orderedCalls=\(calls.map(\.row)) exactEffectsAndWidths=checked originalVoidReturn=checked")
    }

    /// Observe the already completed literal X9 recurrence against the actual
    /// source-mapped AST assignment commits. Nothing is fed into either machine.
    private func observeGrayRecurrence(_ pair: Completed, candidate: C.Program, layout: W.Layout) throws {
        let row = layout.loopStore + 1
        let snapshots = try XCTUnwrap(pair.reference.afterRows[row])
        var matches: [(C.Expression,C.Expression)] = []
        func expressions(_ e: C.Expression) -> [C.Expression] {
            switch e.node {
            case let .cast(_,c), let .unary(_,c), let .load(_,c), let .field(c,_): return [e] + expressions(c)
            case let .binary(_,a,b): return [e] + expressions(a) + expressions(b)
            case let .select(c,a,b): return [e] + expressions(c) + expressions(a) + expressions(b)
            case let .helper(_,args): return [e] + args.flatMap(expressions)
            default: return [e]
            }
        }
        func unit(_ e: C.Expression) -> Bool {
            if case let .literal(value) = e.node { return value.bits == 1 }
            if case let .cast(type,literal) = e.node, type == .u64,
               candidate.expressionTypes[e.span] == .u64, case let .literal(value) = literal.node { return value.bits == 1 }
            return false
        }
        func walk(_ statement: C.Statement) {
            switch statement.node {
            case let .assign(left,right) where left.count == 1 && right.count == 1:
                for e in expressions(right[0]) where (try? candidate.row(at: e.span)) == row {
                    if case let .binary(op,_,rhs) = e.node, op == "-", unit(rhs) { matches.append((left[0],e)) }
                }
            case let .compound(_,body): body.forEach(walk)
            case let .conditional(_,a,b): walk(a); if let b { walk(b) }
            case let .whileLoop(_,body), let .doLoop(body,_), let .label(_,body): walk(body)
            case let .forLoop(initial,_,step,body): if let initial { walk(initial) }; walk(body); if let step { walk(step) }
            default: break
            }
        }
        walk(candidate.root)
        guard matches.count == 1, case let .name(destination) = matches[0].0.node,
              candidate.symbols[destination]?.type == .u64,
              candidate.expressionTypes[matches[0].1.span] == .u64 else {
            throw C.Failure.invalidContract("gap recurrence requires the retained unique source-bound uint64 subtraction; fused shape remains unsupported")
        }
        let expected = try snapshots.map { try XCTUnwrap($0.registers[9]) }
        let commits = pair.actual.commits.filter { $0.span == matches[0].0.span }
        XCTAssertEqual(expected, [2,1,0])
        XCTAssertEqual(commits.map(\.value.bits), expected)
        XCTAssertTrue(commits.allSatisfy { $0.name == destination && $0.value.type == .u64 })
    }

    private func edgeName(_ edge: C.SourceEdge) -> String {
        "\(edge.fromBlock):\(edge.successorOrdinal)->\(edge.toBlock)"
    }
    private func originName(_ origin: L.Origin) -> String {
        "\(edgeName(origin.edge)) row=\(origin.row) role=\(origin.role)"
    }
}

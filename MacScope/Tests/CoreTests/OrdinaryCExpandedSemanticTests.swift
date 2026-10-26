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

/// Five changed-input selectors. Each renders its real fixture exactly once.
/// These integrate the reviewed numerical mutations, color obligation classifier,
/// independent AST/CFG ledger and immutable original color-transfer mappings.
/// They do not invoke historical selectors or the unchanged parser controls.
/// SOURCE_ONLY / NOT_RUN until an execution receipt records otherwise.
final class OrdinaryCExpandedSemanticTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias O = RegionalCallOracle
    private typealias L = OrdinaryCSourceEdgeLedger
    private typealias B = OrdinaryCBaselineTransferOrigins
    private typealias M = OrdinaryCMutationControls
    // Source-reviewed against the retained obsolete-wrapper inventory. Twenty
    // new mutations are not a claim that every old obligation is superseded.
    private static let remainingCoverageLimits = [
        "No explicit upsampler stale-next-call-input alias mutant at buffer call192/136; stale round-result transport is a different obligation.",
        "No explicit upsampler wrong X22 counter-step mutant at row196/140; component-pointer stride is a different obligation.",
        "No actual-color mutants for lost shared label6, upper-bound9, widened zero store, final-join polarity, removed shift mask, or implicit pointer conversion. Positive paths and generic parser checks do not replace their named mutation sensitivities.",
        "No explicit independent comparison of final restored scalar commits; ordered restore loads, exact exterior payloads and memory are checked, but that is not the old per-restore assignment observation.",
        "Jinit CCMP normal-termination numerical mutant remains deferred; fused color decrement observation remains an explicit unsupported shape.",
        "Unobserved CFG edges/residual slots and ambiguous table-case ordinals remain dynamic coverage gaps, even with complete static topology.",
        "Original upsampler/skip printed-transfer source maps are MISSING; no historical raw-removal credit is inferred from topology."
    ]

    func testBaselineGuardTakenAndDispatchDefaultRetainTwoHistoricalIdentities() throws {
        let source = baselineDefaultSource()
        let entries: [B.Entry] = [
            .init(line:1,sourceRow:0,kind:.goto,role:.taken,target:0x101c),
            .init(line:2,sourceRow:6,kind:.goto,role:.tableDefault,target:0x101c)]
        let bindings = try B.bindTransfers(entries, source:source)
        XCTAssertEqual(Set(bindings).count, 2)
        XCTAssertEqual(Set(bindings.map(\.origin)).count, 1, "one physical route observation")
        XCTAssertEqual(bindings.map(\.sourceRow), [0,6])
        XCTAssertEqual(bindings.map(\.role), [.taken,.tableDefault])
        let origin = try XCTUnwrap(bindings.first?.origin)
        let frozen = B.FrozenMapping(start:0x1000,metadataRelativePath:"synthetic",
            metadataSHA256:"",baselineTextSHA256:"",gotos:2,helpers:0,records:"")
        let bound = B.BoundMapping(frozen:frozen,bindings:bindings)
        let span = C.Span(first:0,last:1)
        let dispositions: [L.Disposition] = [.structured,.residual,.mixed,.unresolved]
        for disposition in dispositions {
            let residualSlots: [L.ResidualSlot] = disposition == .residual ?
                [.init(span:span,pc:0,target:1,origins:[origin])] : []
            let report = L.Report(source:source,anchors:[:],anchorRows:[:],entries:[:],printed:[],routes:[],
                accounts:[.init(origin:origin,disposition:disposition,routeIndices:[],residualSpans:[])],
                residualSlots:residualSlots,gaps:[])
            let accounting = try B.account(report, baseline:bound)
            XCTAssertEqual(accounting.originalGotoCount, 2)
            XCTAssertEqual(accounting.structuredOriginalGotoOrigins.count, disposition == .structured ? 2 : 0)
            XCTAssertEqual(accounting.residualOriginalGotoOrigins.count, disposition == .residual ? 2 : 0)
            XCTAssertEqual(accounting.unresolvedOriginalGotoOrigins.count,
                           disposition == .mixed || disposition == .unresolved ? 2 : 0)
            if disposition == .residual {
                XCTAssertEqual(accounting.actualPrintedGotoCount, 1)
                XCTAssertEqual(accounting.residualSlots.first?.originalGotoOrigins.count, 2)
                XCTAssertTrue(try XCTUnwrap(accounting.residualSlots.first).otherTopologyOrigins.isEmpty)
            }
        }
    }

    func testBaselineSharedOriginRejectsDifferentTargetsAndUnverifiedGuard() throws {
        let source = baselineDefaultSource()
        let origin = try XCTUnwrap(source.origins.first)
        let defaultBinding = B.Binding(line:2,sourceRow:6,kind:.goto,role:.tableDefault,target:0x101c,origin:origin)
        let invalidTaken: [B.Binding] = [
            .init(line:1,sourceRow:0,kind:.goto,role:.taken,target:0x1018,origin:origin),
            .init(line:1,sourceRow:1,kind:.goto,role:.taken,target:0x101c,origin:origin)]
        for binding in invalidTaken {
            assertBaselineUniquenessFailure([binding,defaultBinding], source:source)
        }
        let validTaken = B.Binding(line:1,sourceRow:0,kind:.goto,role:.taken,target:0x101c,origin:origin)
        assertBaselineUniquenessFailure([validTaken,defaultBinding], source:baselineDefaultSource(guardMnemonic:"b.lo"))
    }

    func testBaselineSharedOriginRejectsOtherDuplicatePrintedTransfers() throws {
        let source = baselineDefaultSource()
        let origin = try XCTUnwrap(source.origins.first)
        let first = B.Binding(line:1,sourceRow:6,kind:.goto,role:.tableDefault,target:0x101c,origin:origin)
        let duplicate = B.Binding(line:2,sourceRow:6,kind:.goto,role:.tableDefault,target:0x101c,origin:origin)
        assertBaselineUniquenessFailure([first,duplicate], source:source)
        let taken = B.Binding(line:3,sourceRow:0,kind:.goto,role:.taken,target:0x101c,origin:origin)
        assertBaselineUniquenessFailure([first,duplicate,taken], source:source)
    }

    private func assertBaselineUniquenessFailure(_ bindings: [B.Binding], source: L.Source,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try B.requireUniqueOrigins(bindings, source:source), file:file, line:line) { error in
            guard case C.Failure.invalidContract(let message) = error else {
                return XCTFail("expected baseline uniqueness error, got \(error)", file:file, line:line)
            }
            XCTAssertEqual(message, "duplicate baseline origin must not collapse its denominator", file:file, line:line)
        }
    }

    private func baselineDefaultSource(guardMnemonic: String = "b.hi") -> L.Source {
        let rows: [InstructionRow] = (0..<8).map { index -> InstructionRow in
            let address: UInt64 = 0x1000 + UInt64(index * 4)
            let mnemonic: String
            let operands: String
            switch index {
            case 0: mnemonic = guardMnemonic; operands = "0x101c"
            case 6: mnemonic = "br"; operands = "x8"
            case 7: mnemonic = "ret"; operands = ""
            default: mnemonic = "nop"; operands = ""
            }
            return InstructionRow(address:address,bytes:"00 00 00 00",
                mnemonic:mnemonic,operands:operands,hasBreakpoint:false,comment:nil)
        }
        let origin = L.Origin(edge:.init(fromBlock:0,toBlock:2,successorOrdinal:0),row:6,role:.tableDefault)
        return .init(rows:rows,blocks:[.init(index:0,rows:0..<1,successors:[2,1]),
                                      .init(index:1,rows:1..<7,successors:[2]),
                                      .init(index:2,rows:7..<8,successors:[])],
                     blockAtRow:[0:0,1:1,2:1,3:1,4:1,5:1,6:1,7:2],origins:[origin],outgoing:[0:[origin]],
                     dispatches:[6:.init(row:6,targets:[7],defaultRow:7,guardRow:0)],
                     branchTargets:[0:7],returns:[7],backedges:[],naturalLoops:[:])
    }

    func testColor26c78ExpandedOrdinarySemantics() throws { try color(.jinit) }
    func testColor122893cExpandedOrdinarySemantics() throws { try color(.j12init) }
    func testUp3ae18ExpandedOrdinarySemantics() throws { try upsampler(.jinit) }
    func testUp123b774ExpandedOrdinarySemantics() throws { try upsampler(.j12init) }
    func testSkip33418ExpandedOrdinarySemantics() throws {
        let fixture = try OrdinaryCRecordedCallFixture.skipVariable()
        try ordinaryPrerequisite(document: fixture.document, function: fixture.function, baseline: fixture.baselineText)
        let contract = try recordedContract(fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try OrdinaryCSkipSourceOracle.Program(rows: fixture.rows, function: fixture.function)
        let original = try OrdinaryCSkipSourceOracle.Scenarios.all()
        XCTAssertEqual(original.count, 13)
        let high = try changedHighCallees(from: original)
        let scenarios = original + [high.scenario]
        XCTAssertEqual(Set(scenarios.map(\.name)).count, 14)
        var terminals: Set<UInt64> = []
        var completed: [Completed] = []
        var references: [String: M.Reference] = [:]
        for scenario in scenarios {
            let expected = try OrdinaryCSkipSourceOracle.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: expected.returnBits, contract: contract, name: scenario.name)
            terminals.insert(try XCTUnwrap(actual.terminal?.bits))
            references[scenario.name] = M.Reference(expected, terminal: expected.returnBits)
            completed.append(.init(name: scenario.name, actual: actual, reference: expected))
            if scenario.name == high.scenario.name {
                let calls = actual.events.compactMap { event -> C.CallEvent? in
                    if case let .call(call) = event { return call }; return nil
                }
                XCTAssertEqual(calls.map(\.row), [12,21,40,48])
                XCTAssertEqual(calls.map { $0.control.map(\.bits) }, high.targets.map { [$0] })
                XCTAssertTrue(calls.allSatisfy { $0.control.count == 1 && $0.control[0].width == 64 && $0.control[0].bits >> 63 == 1 })
                XCTAssertEqual(expected.calls.map { $0.control.map(\.bits) }, high.targets.map { [$0] })
            }
        }
        XCTAssertEqual(terminals, [0,1], "both original W21 terminal paths remain covered")
        try recordMutations(M.skip(candidate, rows: fixture.rows, scenarios: original, references: references), expected: 1)
        try observeEdges(candidate: candidate, source: L.source(rows: fixture.rows), completed: completed,
                         baselineText: fixture.baselineText)
    }

    private func color(_ seed: RegionalSwitchSeed) throws {
        let fixture = try RegionalSwitchFixture.make(seed)
        try ordinaryPrerequisite(document: fixture.document, function: fixture.function, baseline: fixture.baselineText)
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try C.contract(rows: fixture.rows, function: fixture.function, baseline: fixture.baselineText,
            callRows: seed.callRows, blockAddresses: blocks)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try RegionalSwitchOracle.Program(fixture: fixture)
        let all = try RegionalSwitchOracle.ColorScenarios.all(for: seed)
        let full = all.filter { $0.startRow == 0 && $0.stopBeforeRow == nil && $0.regionalBindings.isEmpty }
        let regional = all.filter { $0.startRow != 0 || $0.stopBeforeRow != nil || !$0.regionalBindings.isEmpty }
        let names = Set(full.map(\.name)), obligations = Set(regional.map(\.name))
        XCTAssertEqual(names.count, full.count)
        XCTAssertEqual(obligations.count, 17, "historical scoped premises are not whole-entry scenarios")
        for required in ["gray-zero-iterations", "gray-one-iteration", "gray-multiple-iterations",
                         "gray-64-bit-pointer", "gray-count-memory-alias"] {
            XCTAssertTrue(names.contains(required), "missing retained full-entry case \(required)")
        }
        var completed: [Completed] = []
        var references: [String: M.Reference] = [:]
        for scenario in full {
            // Pass the original scenario unchanged, including its false-case
            // expectedAbsentRows and expectedVisits. The source machine checks
            // those premises; the candidate must then match its effects/edges.
            let expected = try RegionalSwitchOracle.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: nil, contract: contract, name: scenario.name)
            try observeColorRecurrence(actual, candidate: candidate, reference: expected, seed: seed, name: scenario.name)
            references[scenario.name] = M.Reference(expected)
            completed.append(.init(name: scenario.name, actual: actual, reference: expected))
        }
        try recordMutations(M.color(candidate, seed: seed, rows: fixture.rows,
                                    scenarios: full, references: references), expected: 2)
        var addedNames: Set<String> = []
        let coverage = try OrdinaryCColorCoverage.verify(candidate: candidate, source: source, seed: seed,
            completedFullEntryNames: names) { name, actual, reference in
                guard !names.contains(name), addedNames.insert(name).inserted else {
                    throw C.Failure.invalidContract("duplicate completed color full-entry observation")
                }
                completed.append(.init(name: name, actual: actual, reference: reference))
            }
        let existing = Set(coverage.replacedByExistingFullEntry.keys)
        let additional = Set(coverage.replacedByAdditionalFullEntry.keys)
        let scoped = Set(coverage.scopedOnly)
        XCTAssertEqual(existing.count, 4)
        XCTAssertEqual(additional.count, 3)
        XCTAssertEqual(scoped.count, 10)
        XCTAssertTrue(existing.isDisjoint(with: additional) && existing.isDisjoint(with: scoped) && additional.isDisjoint(with: scoped))
        XCTAssertEqual(existing.union(additional).union(scoped), obligations)
        XCTAssertEqual(coverage.additionalFullEntry.count, 11)
        XCTAssertEqual(addedNames, Set(coverage.additionalFullEntry), "reuse exactly the eleven completed pairs, never rerun for edge counts")
        let executed = Set(coverage.scopedExecuted), unavailable = Set(coverage.unrepresentable.keys)
        XCTAssertTrue(executed.isDisjoint(with: unavailable))
        XCTAssertEqual(executed.union(unavailable), scoped)
        // A genuinely unrepresentable exact counterfactual (e.g. a high mask
        // bit after a W write) remains uncredited, not a fabricated scoped pass.
        print("ORDINARY_C_COLOR_CLASSIFICATION fullAdded=\(addedNames.sorted()) scopedOnly=\(scoped.sorted()) scopedExecuted=\(executed.sorted()) unrepresentable=\(coverage.unrepresentable) limits=\(coverage.limits)")
        try observeEdges(candidate: candidate, source: L.source(rows: fixture.rows, color: fixture.capture),
                         completed: completed, baselineText: fixture.baselineText)
    }

    private func recordedContract(_ fixture: OrdinaryCRecordedCallFixture) throws -> C.Contract {
        guard fixture.function.ssaEnabled else {
            return try C.contract(rows: fixture.rows, function: fixture.function,
                baseline: fixture.baselineText, callRows: fixture.callRows)
        }
        // W/X writes share one SSA cell namespace. Bind frozen payload names to
        // the same defining source rows and widths without rewriting the output.
        let legacy = SSAAlphaEquivalence.legacyFunction(from: fixture.input)
        let frozen = try C.contract(rows: fixture.rows, function: legacy,
            baseline: fixture.baselineText, callRows: fixture.callRows)
        var alpha = SSAAlphaEquivalence(expected: legacy, actual: fixture.function)
        return try frozen.alphaEquivalent(to: fixture.document, using: &alpha)
    }

    func testUp3ae18HighAllocationPhiTransport() throws {
        try highAllocationPhiTransport(.jinit)
    }

    func testUp123b774HighAllocationPhiTransport() throws {
        try highAllocationPhiTransport(.j12init)
    }

    private func highAllocationPhiTransport(_ seed: RegionalCallSeed) throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        try fixtures.requireFullTypedRowOwnership()
        let fixture = fixtures.opaque
        XCTAssertEqual(fixture.function.ssaEnabled, MacIRConfiguration.ssaEnabled,
                       "SSA must not silently fall back to the legacy positive control")
        // These are complete retained byte-backed functions, not a hand-written
        // C replacement for the production emitter. j12init starts at 0x3b774.
        XCTAssertEqual(fixture.rows[25].bytes, "74 3e 41 f9") // ldr x20, [x19, #0x278]
        XCTAssertEqual(fixture.rows[35].bytes, "00 01 3f d6") // blr x8
        XCTAssertEqual(fixture.rows[36].bytes, "f4 03 00 aa") // mov x20, x0
        XCTAssertEqual(fixture.rows[36].address, seed == .jinit ? 0x3aea8 : 0x3b804)
        try ordinaryPrerequisite(document: fixture.document, function: fixture.function, baseline: fixture.baselineText)
        let contract = try recordedContract(fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let scenario = try XCTUnwrap(O.UpsamplerScenarios.all(for: seed).first {
            $0.name == "allocation-high64-return"
        })
        let bits: UInt64 = 0x8000_0000_0005_0000
        XCTAssertEqual(try XCTUnwrap(scenario.responses.first { $0.row == 35 }).result, bits)
        let source = try O.Program(rows: fixture.rows, function: fixture.function)
        let expected = try O.Machine(program: source, scenario: scenario).run()
        let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
        try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
            returned: expected.returned, terminal: nil, contract: contract, name: scenario.name)
        let calls = actual.events.compactMap { event -> C.CallEvent? in
            if case let .call(call) = event { return call }; return nil
        }
        XCTAssertEqual(try XCTUnwrap(calls.first { $0.row == 35 }).result, bits)
        XCTAssertTrue(actual.commits.contains { $0.sourceRow == 36 && $0.value.bits == bits })
        if fixture.function.ssaEnabled {
            let join = fixture.rows[seed == .jinit ? 44 : 45].address
            let phi = try XCTUnwrap(fixture.function.phis.first { $0.cell == 20 && $0.blockAddress == join })
            let printer = PseudocodePrinter(options: .default)
            let names = PseudocodeNameContext(function: fixture.function)
            let name = printer.valueText(for: phi.destination, names: names)
            let copies = actual.commits.filter { $0.name == name }
            XCTAssertFalse(copies.isEmpty, "must execute the actual join, not just observe the call result")
            XCTAssertTrue(copies.allSatisfy { $0.value.bits == bits && $0.value.type == .i64 && $0.value.negative },
                          "defined signed storage must preserve all 64 register bits")
        }
        // The fix is a production boundary conversion, never an oracle waiver.
        XCTAssertThrowsError(try C.converted(.init(bits, .u64), to: .i64))
        XCTAssertThrowsError(try C.binary("+", .init(UInt64(Int64.max), .i64), .init(1, .i64)))
    }

    private func upsampler(_ seed: RegionalCallSeed) throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        try ordinaryPrerequisite(document: fixture.document, function: fixture.function, baseline: fixture.baselineText)
        let contract = try recordedContract(fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try O.Program(rows: fixture.rows, function: fixture.function)
        let scenarios = try O.UpsamplerScenarios.all(for: seed)
        for required in ["zero-bypass-no-call-result", "zero-allocation", "two-returning-prefix-errors",
                         "multiple-distinct-joins-and-call-results", "current-X28-snapshot-and-later-control-reload",
                         "same-execution-CSEL-writer-time-flags"] {
            XCTAssertTrue(scenarios.contains { $0.name == required }, "missing retained case \(required)")
        }
        var completed: [Completed] = []
        var references: [String: M.Reference] = [:]
        for scenario in scenarios {
            let expected = try O.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: nil, contract: contract, name: scenario.name)
            references[scenario.name] = M.Reference(expected)
            completed.append(.init(name: scenario.name, actual: actual, reference: expected))
        }
        try recordMutations(M.upsampler(candidate, seed: seed, rows: fixture.rows,
                                        scenarios: scenarios, references: references), expected: seed == .jinit ? 8 : 7)
        try observeEdges(candidate: candidate, source: L.source(rows: fixture.rows), completed: completed,
                         baselineText: fixture.baselineText)
    }

    private func ordinaryPrerequisite(document: PseudocodeDocument, function: MacIRFunction, baseline: String) throws {
        print("ORDINARY_C_EXPANDED_COVERAGE_LIMITS \(Self.remainingCoverageLimits.joined(separator: " | "))")
        let report = try OrdinaryCOutputAudit.analyze(document: document, function: function, baselineText: baseline)
        let rejectedNames = report.tokens.filter { $0.text.hasPrefix("rgn_regional_") }
        guard report.errors.isEmpty, rejectedNames.isEmpty else {
            XCTFail("ORDINARY_C_EXPANDED_PREREQUISITE: actual complete output violates the ordinary-control contract; numerical equivalence and expanded controls have NOT executed. \(report.errors.joined(separator: "; "))")
            throw C.Failure.unsupportedSyntax("named ordinary-output prerequisite, not a parser-infrastructure or numerical-equivalence RED")
        }
    }

    private struct Completed {
        let name: String
        let actual: C.Result
        let branches: [O.Branch]
        let visits: [Int:Int]
        let returned: Bool
        init(name: String, actual: C.Result, reference: O.Result) {
            self.name = name; self.actual = actual; branches = reference.branches
            visits = reference.rowVisits; returned = reference.returned
        }
        init(name: String, actual: C.Result, reference: RegionalSwitchOracle.Result) {
            self.name = name; self.actual = actual; branches = reference.branches
            visits = reference.rowVisits; returned = reference.returned
        }
    }

    private func observeEdges(candidate: C.Program, source: L.Source, completed: [Completed], baselineText: String) throws {
        let report = try L.analyze(candidate: candidate, source: source)
        try report.requireCompleteTopology()
        for fallback in report.infeasibleFallbacks {
            // A route selecting an actual ordinal must never receive an
            // infeasibility certificate. Reuse the parsed candidate, not a render.
            for ordinal in 0..<10 {
                var selector: String?
                let decisions = try fallback.decisions.map { choice -> L.Choice in
                    guard case let .branch(expression, _, _) = candidate.code[choice.pc].node else { return choice }
                    guard let taken = try L.dispatchPredicate(expression, ordinal: UInt64(ordinal),
                                                              selector: &selector, candidate: candidate) else { return choice }
                    return .init(pc: choice.pc, expression: choice.expression, taken: taken)
                }
                XCTAssertFalse(try L.guardedDispatchFallback(candidate: candidate, source: source,
                    entry: fallback.entry, destination: fallback.destination, decisions: decisions,
                    path: fallback.path, anchors: report.anchors), "A legal case is a feasible source route")
            }
            XCTAssertFalse(try L.guardedDispatchFallback(candidate: candidate, source: source,
                entry: fallback.entry, destination: fallback.entry, decisions: fallback.decisions,
                path: fallback.path, anchors: report.anchors), "A wrong destination cannot be a dispatch fallback")
        }
        for account in report.accounts {
            print("ORDINARY_C_TOPOLOGY_ORIGIN \(originName(account.origin)) disposition=\(account.disposition) routes=\(account.routeIndices)")
        }
        for transfer in report.infeasiblePrintedTransfers {
            print("ORDINARY_C_INFEASIBLE_FALLBACK pc=\(transfer.pc) targetPC=\(transfer.target) physicalOrigins=0 historicalRemovalCredit=0")
        }
        for slot in report.residualSlots {
            print("ORDINARY_C_RESIDUAL_SLOT pc=\(slot.pc) tokens=\(slot.span.first)..<\(slot.span.last) targetPC=\(slot.target) origins=\(slot.origins.map(originName).sorted())")
        }
        var edges: Set<C.SourceEdge> = []
        var observedSlots: Set<C.Span> = []
        var ambiguousObservations = 0
        for pair in completed {
            let observation = try L.observe(report, candidate: candidate, actual: pair.actual,
                referenceBranches: pair.branches, referenceRowVisits: pair.visits,
                referenceReturned: pair.returned, name: pair.name)
            edges.formUnion(observation.sourceEdges)
            observedSlots.formUnion(observation.residualOccurrences.keys)
            // Equal-target cases retain plural possible roles. One occurrence
            // NEVER counts as executing every role in a possibleOriginGroup.
            ambiguousObservations += observation.possibleOriginGroups.filter { $0.count > 1 }.count
        }
        let allEdges = Set(source.origins.map(\.edge))
        let missing = allEdges.subtracting(edges).map(edgeName).sorted()
        let unobservedSlots = report.residualSlots.filter { !observedSlots.contains($0.span) }.map(\.pc).sorted()
        print("ORDINARY_C_EDGE_OBSERVATION scenarios=\(completed.count) observedCFGEdges=\(edges.count) unobservedCFGEdges=\(missing) unobservedResidualPCs=\(unobservedSlots) ambiguousCaseOccurrences=\(ambiguousObservations)")
        // Complete topology is accounting, NOT universal predicate equivalence
        // or complete dynamic case coverage. Only the compared traces are tested.
        let start = try XCTUnwrap(source.rows.first?.address)
        if let mapping = B.frozenMapping(for: start) {
            let bound = try B.bind(mapping, baselineText: baselineText, source: source)
            let account = try B.account(report, baseline: bound)
            try account.requireComplete()
            XCTAssertEqual(account.originalGotoCount, start == 0x26c78 ? 68 : 65)
            XCTAssertEqual(account.structuredOriginalGotoOrigins.count + account.residualOriginalGotoOrigins.count, account.originalGotoCount)
            XCTAssertTrue(account.structuredOriginalGotoOrigins.isDisjoint(with: account.residualOriginalGotoOrigins))
            print("ORDINARY_C_FROZEN_BASELINE_ACCOUNTING originalGotos=\(account.originalGotoCount) printedGotos=\(account.actualPrintedGotoCount) structuredOrigins=\(account.structuredOriginalGotoOrigins.count) residualOrigins=\(account.residualOriginalGotoOrigins.count) helperOrigins=\(account.originalBranchHelperCount)")
        } else {
            guard B.missingOriginalMetadata.contains(start) else { throw C.Failure.invalidContract("unclassified missing historical origin map") }
            print("ORDINARY_C_HISTORICAL_MAP_MISSING start=0x\(String(start, radix:16)); topology/observed traces do not supply historical raw-removal credit")
        }
    }

    private func edgeName(_ edge: C.SourceEdge) -> String {
        "\(edge.fromBlock):\(edge.successorOrdinal)->\(edge.toBlock)"
    }
    private func originName(_ origin: L.Origin) -> String {
        "\(edgeName(origin.edge)) row=\(origin.row) role=\(origin.role)"
    }
    private func recordMutations(_ receipts: [M.Receipt], expected: Int) throws {
        XCTAssertEqual(receipts.count, expected)
        XCTAssertEqual(Set(receipts.map(\.name)).count, expected)
        for receipt in receipts {
            print("ORDINARY_C_NUMERICAL_MUTATION name=\(receipt.name) scenario=\(receipt.scenario) observation=\(receipt.observation)")
        }
    }

    /// New full-entry input, not a changed candidate or imported source state.
    /// Preserve the real four-event script, arguments, results and all original
    /// writes. Only existing callee cells change before their literal loads.
    private func changedHighCallees(from scenarios: [O.Scenario]) throws -> (scenario: O.Scenario, targets: [UInt64]) {
        let base = try XCTUnwrap(scenarios.first { $0.name == "both-refills-return-with-changed-snapshots" })
        guard base.responses.map(\.row) == [12,21,40,48] else { throw C.Failure.invalidContract("high-callee base script changed") }
        let manager = OrdinaryCSkipSourceOracle.Scenarios.manager
        let errors = OrdinaryCSkipSourceOracle.Scenarios.errors
        let targets: [UInt64] = [0x8000_0000_0000_0011, 0xffff_ffff_0000_0021, 0xa777_6666_5555_0040, 0xf666_5555_4444_0048]
        var memory = base.memory, responses = base.responses
        try memory.store(.init(address: manager + 0x18, bytes: 8, bits: targets[0]))
        responses[0].writes.append(.init(address: manager + 0x18, bytes: 8, bits: targets[1]))
        responses[1].writes.append(.init(address: errors + 8, bytes: 8, bits: targets[2]))
        responses[2].writes.append(.init(address: manager + 0x20, bytes: 8, bits: targets[3]))
        for index in responses.indices { responses[index].expectedControl = [targets[index]] }
        return (.init(name: "changed-high64-indirect-callees-at-each-literal-reload", registers: base.registers,
                      memory: memory, responses: responses, expectedVisits: base.expectedVisits), targets)
    }

    private func observeColorRecurrence(_ actual: C.Result, candidate: C.Program,
                                       reference: RegionalSwitchOracle.Result, seed: RegionalSwitchSeed, name: String) throws {
        let row = seed == .jinit ? 254 : 247
        guard let snapshots = reference.afterRows[row], !snapshots.isEmpty else { return }
        var matches: [(C.Expression,C.Expression)] = []
        func expressions(_ e: C.Expression) -> [C.Expression] {
            switch e.node {
            case let .cast(_, child), let .unary(_, child), let .load(_, child), let .field(child, _): return [e] + expressions(child)
            case let .binary(_, a, b): return [e] + expressions(a) + expressions(b)
            case let .select(c, a, b): return [e] + expressions(c) + expressions(a) + expressions(b)
            case let .helper(_, args): return [e] + args.flatMap(expressions)
            default: return [e]
            }
        }
        func walk(_ statement: C.Statement) {
            switch statement.node {
            case let .assign(left, right) where left.count == 1 && right.count == 1:
                for e in expressions(right[0]) where (try? candidate.row(at: e.span)) == row {
                    if case let .binary(op, _, rhs) = e.node, op == "-",
                       recurrenceUnitLiteral(rhs, candidate: candidate) != nil { matches.append((left[0],e)) }
                }
            case let .compound(_, body): body.forEach(walk)
            case let .conditional(_, a, b): walk(a); if let b { walk(b) }
            case let .whileLoop(_, body), let .doLoop(body, _), let .label(_, body): walk(body)
            case let .forLoop(initial, _, step, body): if let initial { walk(initial) }; walk(body); if let step { walk(step) }
            default: break
            }
        }
        walk(candidate.root)
        guard matches.count == 1, case let .name(destination) = matches[0].0.node,
              candidate.symbols[destination]?.type == .u64,
              candidate.expressionTypes[matches[0].1.span] == .u64 else {
            throw C.Failure.invalidContract("color recurrence requires unique source-bound uint64 scalar subtraction; fused updates remain unsupported")
        }
        let commits = actual.commits.filter { $0.span == matches[0].0.span }
        let expected = try snapshots.map { try XCTUnwrap($0.registers[9]) }
        guard commits.allSatisfy({ $0.name == destination && $0.value.type == .u64 }), commits.map(\.value.bits) == expected else {
            throw C.Failure.semanticMismatch("\(name): color X64 recurrence mismatch at row \(row)")
        }
    }
    private func recurrenceUnitLiteral(_ expression: C.Expression, candidate: C.Program) -> C.Expression? {
        if case let .literal(value) = expression.node { return value.bits == 1 ? expression : nil }
        // Retained native-v2 writers have an explicit uint64_t cast around
        // literal one. Recognize exactly that existing AST shape, not arbitrary
        // equivalent expressions, fused updates, or reference-derived values.
        guard case let .cast(type, literal) = expression.node, type == .u64,
              candidate.expressionTypes[expression.span] == .u64,
              case let .literal(value) = literal.node, value.bits == 1 else { return nil }
        return literal
    }

    func testHighAllocationResultSurvivesSSAJoinWithoutUnrepresentableConversion() throws {
        for seed in [RegionalCallSeed.jinit, .j12init] {
            let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
            try fixtures.requireFullTypedRowOwnership()
            let fixture = fixtures.opaque
            XCTAssertEqual(fixture.function.ssaEnabled, MacIRConfiguration.ssaEnabled,
                           "The requested SSA route must not silently use legacy lifting")
            try ordinaryPrerequisite(document: fixture.document, function: fixture.function,
                                     baseline: fixture.baselineText)
            let contract = try recordedContract(fixture)
            let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
            let source = try O.Program(rows: fixture.rows, function: fixture.function)
            let scenario = try XCTUnwrap(O.UpsamplerScenarios.all(for: seed).first {
                $0.name == "allocation-high64-return"
            })
            let allocation = try XCTUnwrap(scenario.responses.first { $0.row == 35 })
            XCTAssertEqual(allocation.result, 0x8000_0000_0005_0000)
            let expected = try O.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate,
                scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                          returned: expected.returned, terminal: nil,
                          contract: contract, name: scenario.name)
        }
    }

    func testMutationCSELMatcherRequiresExactUnsignedWordDomainAndSource() throws {
        for zero in ["0x0", "(uint32_t)0x0"] {
            let (program, expression) = try mutationPredicateUnit(
                declarations: ["uint32_t low = (uint32_t)call_value;"], expression: "low == \(zero)")
            XCTAssertTrue(M.firstWriterLow32Comparison(expression, call: "call_value", in: program))
        }
        let negatives: [([String], String, Int)] = [
            (["int32_t low = 0;"], "low == 0", 109), // two signed32 operands
            (["uint64_t low = call_value;"], "low == 0", 109),
            (["uint32_t low = (uint32_t)call_value;"], "low == (uint64_t)0", 109),
            (["uint32_t low = (uint32_t)unrelated;"], "low == 0", 109),
            (["uint32_t low = (uint32_t)call_value;"], "low == 1", 109),
            (["uint32_t low = (uint32_t)call_value;"], "low != 0", 109),
            (["uint32_t low = (uint32_t)call_value;"], "low == 0", 108)
        ]
        for (declarations, text, row) in negatives {
            let (program, expression) = try mutationPredicateUnit(declarations: declarations, expression: text, row: row)
            XCTAssertFalse(M.firstWriterLow32Comparison(expression, call: "call_value", in: program), text)
        }
        // The parser itself refuses pointer equality in the integer contract;
        // the locator must never turn that infrastructure refusal into a site.
        XCTAssertThrowsError(try mutationPredicateUnit(declarations: [], expression: "call_value == unrelated",
                                                       inputType: .jpegPointer))
    }

    func testMutationCCMPMatcherRequiresUnsignedWordDomainAndExactDefinitions() throws {
        for (left, right, accepted) in [("uint32_t", "uint32_t", true),
                                       ("int32_t", "uint32_t", true),
                                       ("uint32_t", "int32_t", true),
                                       ("int32_t", "int32_t", false),
                                       ("uint64_t", "uint32_t", false),
                                       ("uint32_t", "uint64_t", false),
                                       ("int64_t", "uint32_t", false)] {
            let (program, expression) = try mutationPredicateUnit(
                declarations: ["\(left) left = 0;", "\(right) right = 0;"], expression: "left != right", row: 94)
            XCTAssertEqual(M.word32Inequality(expression, lhs: "left", rhs: "right", in: program), accepted)
            XCTAssertFalse(M.word32Inequality(expression, lhs: "other_definition", rhs: "right", in: program))
        }
        let (program, expression) = try mutationPredicateUnit(
            declarations: ["uint32_t left = 0;", "uint32_t right = 0;"], expression: "left == right", row: 94)
        XCTAssertFalse(M.word32Inequality(expression, lhs: "left", rhs: "right", in: program))
        XCTAssertThrowsError(try mutationPredicateUnit(declarations: [], expression: "call_value != unrelated",
                                                       row: 94, inputType: .jpegPointer))
    }

    // Synthetic parser/type negatives, not binary-coverage credit. The original
    // full upsampler selectors retain their actual mutation kill requirements.
    private func mutationPredicateUnit(declarations: [String], expression: String, row: Int = 109,
                                       inputType: C.CType = .u64) throws -> (C.Program, C.Expression) {
        let inputSpelling = inputType == .jpegPointer ? "struct jpeg_decompress_struct *" : "uint64_t "
        let signature = "void mutation_site(\(inputSpelling)call_value, \(inputSpelling)unrelated) {"
        let terminal = "return; // return"
        var rows: [UInt64: Int] = [:]
        var lines: [C.TextLine] = [.init(text: signature, source: nil, envelope: .signature)]
        for (index, declaration) in declarations.enumerated() {
            let address = UInt64(0x1000 + index * 4)
            rows[address] = index
            lines.append(.init(text: declaration, source: address, envelope: .body))
        }
        rows[0x2000] = row
        lines.append(.init(text: "candidate = \(expression);", source: 0x2000, envelope: .body))
        rows[0x3000] = 999
        lines.append(.init(text: terminal, source: 0x3000, envelope: .body))
        lines.append(.init(text: "}", source: nil, envelope: .closingBrace))
        let contract = C.Contract(signature: signature,
            inputs: [.init(name: "call_value", type: inputType, entrySlot: 0),
                     .init(name: "unrelated", type: inputType, entrySlot: 1)],
            fields: [], calls: [:], exterior: [:], terminalRow: 999, terminalPayload: terminal,
            terminalName: nil, returnType: nil, rowsByAddress: rows, allowedLabels: [],
            memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        let program = try C.Program(lines: lines, contract: contract)
        guard case let .compound(_, statements) = program.root.node else {
            throw C.Failure.invalidContract("mutation predicate unit body")
        }
        let expressions = statements.compactMap { statement -> C.Expression? in
            guard (try? program.row(at: statement.span)) == row,
                  case let .assign(_, values) = statement.node, values.count == 1 else { return nil }
            return values[0]
        }
        XCTAssertEqual(expressions.count, 1)
        return (program, try XCTUnwrap(expressions.first))
    }

    func testLiteralSSAFlagTemporarySelectFindsUniqueReachingDefinition() throws {
        // Exact supplied ancestor spelling, not a newly rendered capture.
        // The same supplied flag/label/select now includes actual protected
        // call bindings and predecessor108 so edge authority is proved.
        let program = try incomingFlagProgram(twoReachingDefinitions: false)
        let select = try literalSelection(program)
        let mutation = try M.cselWidthMutation(in: program, selection: select, call: "x0_9")
        XCTAssertEqual(mutation.replacement, "((uint64_t)(x0_9) == 0x0)")
        XCTAssertLessThan(mutation.span.last, select.span.first)
        XCTAssertEqual(program.phiEdge(at: mutation.span)?.blockAddress, 0x3afcc)
    }

    func testLiteralSSASignedBooleanTransportRequiresEqualPureCopies() throws {
        let bits = "(uint32_t)(((uint32_t)(x0_9) == 0x0))"
        let transported = "((\(bits) & 0x80000000) == 0 ? (int32_t)\(bits) : -1 - (int32_t)(uint32_t)~\(bits))"
        func program(_ rhs: String) throws -> C.Program {
            try incomingFlagProgram(twoReachingDefinitions: false, customSelectedRHS: rhs)
        }
        let original = try program(transported)
        let mutation = try M.cselWidthMutation(in: original, selection: literalSelection(original), call: "x0_9")
        XCTAssertTrue(original.representationCasts.contains(mutation.span))
        XCTAssertEqual(mutation.replacement, "((uint64_t)(x0_9) == 0x0)")
        let mismatched = try program(transported.replacingOccurrences(of: "~\(bits)",
            with: "~(uint32_t)(((uint32_t)(x0_9) == 0x1))"))
        XCTAssertThrowsError(try M.cselWidthMutation(in: mismatched, selection: literalSelection(mismatched), call: "x0_9"))
        func selectedFlagRHS(_ candidate: C.Program) throws -> C.Expression {
            let values = candidate.code.compactMap { instruction -> C.Expression? in
                guard candidate.phiEdge(at: instruction.span)?.predecessorAddress == 0x3afc8,
                      case let .assign(_, rhs) = instruction.node, rhs.count == 1 else { return nil }
                return rhs[0]
            }
            XCTAssertEqual(values.count, 1)
            return try XCTUnwrap(values.first)
        }
        let certified = try selectedFlagRHS(original)
        XCTAssertNotNil(RegionalCallRowOwnership.transportedBooleanComparison(certified, in: original))
        XCTAssertNil(RegionalCallRowOwnership.transportedBooleanComparison(try selectedFlagRHS(mismatched), in: mismatched))
        let wideBits = "(uint64_t)(((uint32_t)(x0_9) == 0x0))"
        let wide = try program("((\(wideBits) & 0x8000000000000000) == 0 ? (int64_t)\(wideBits) : -1 - (int64_t)(uint64_t)~\(wideBits))")
        let wideRHS = try selectedFlagRHS(wide)
        XCTAssertTrue(wide.representationCasts.contains(wideRHS.span))
        XCTAssertNil(RegionalCallRowOwnership.transportedBooleanComparison(wideRHS, in: wide))
        // A forged sign test is not representation transport, even with equal data copies.
        let forged = try program(transported.replacingOccurrences(of: "0x80000000", with: "0x40000000"))
        let forgedRHS = try selectedFlagRHS(forged)
        XCTAssertFalse(forged.representationCasts.contains(forgedRHS.span))
        XCTAssertNil(RegionalCallRowOwnership.transportedBooleanComparison(forgedRHS, in: forged))
        XCTAssertThrowsError(try M.cselWidthMutation(in: forged, selection: literalSelection(forged), call: "x0_9"))
    }

    func testLiteralSSAPositiveCCMPRequiresSourceBoundArmOrientation() throws {
        for (condition, yesRow, noRow, expected) in [
            ("(tmp37 == tmp30) && (tmp29 == tmp31)", 112, 95, "||"),
            ("(tmp37 != tmp30) || (tmp29 != tmp31)", 95, 112, "&&"),
            // V5's first-source landmark rejection was an unsupported
            // presentation constraint, not source predicate identity.
            ("(tmp37 == tmp30) && (tmp29 == tmp31)", 95, 112, "||"),
            ("(tmp37 == tmp30) || (tmp29 == tmp31)", 112, 95, ""),
            ("(tmp37 == tmp30) && (tmp37 == tmp31)", 112, 95, "")
        ] {
            let program = try literalMutationProgram([
                ("uint32_t tmp37 = 2;", 91), ("uint32_t tmp30 = 2;", 77),
                ("int32_t tmp29 = 1;", 76), ("uint32_t tmp31 = 2;", 78),
                ("if (\(condition)) {", 94), ("taken = 1;", yesRow),
                ("} else {", 94), ("fallthrough = 0;", noRow), ("}", 94)
            ])
            let conditions = program.code.compactMap { instruction -> C.Expression? in
                if case let .branch(e, _, _) = instruction.node, (try? program.row(at: e.span)) == 94 { return e }
                return nil
            }
            XCTAssertEqual(conditions.count, 1)
            let result = M.ccmpMutationOperator(try XCTUnwrap(conditions.first), lhs: "tmp37", rhs: "tmp30",
                secondLHS: "tmp29", secondRHS: "tmp31", in: program)
            XCTAssertEqual(result, expected.isEmpty ? nil : expected)
        }
    }

    func testLiteralSSAFlagDefinitionRefusesRedefinitionAndBypass() throws {
        let definition = "flag_3afcc_eq_0 = (uint32_t)(x0_9) == 0x0;"
        let select = "tmp46 = (flag_3afcc_eq_0 != 0x0) ? x10_9 : x9_28;"
        let bodies: [[(String, Int)]] = [
            // Undefined entry is not a definition.
            [(select, 109)],
            // Two assignments, even when their predicates are identical.
            [(definition, 109), (definition, 109), (select, 109)],
            // A valid definition does not dominate the false incoming path.
            [("if (x0_9 != 0) {", 101), (definition, 109), ("}", 101), (select, 109)],
            // A source-looking definition can be bypassed through a real label.
            [("if (x0_9 != 0) goto L_3afcc;", 101), (definition, 109), ("L_3afcc:", 109), (select, 109)],
            // Post-definition scalar update is a second writer.
            [(definition, 109), ("flag_3afcc_eq_0++;", 108), (select, 109)],
            // Source ownership remains required even for a dominating definition.
            [(definition, 108), (select, 109)]
        ]
        for body in bodies {
            let program = try literalMutationProgram([("int32_t flag_3afcc_eq_0;", 0)] + body)
            XCTAssertThrowsError(try M.cselWidthMutation(in: program, selection: literalSelection(program), call: "x0_9"))
        }
    }

    private func literalSelection(_ program: C.Program) throws -> C.Expression {
        let candidates = program.code.compactMap { instruction -> C.Expression? in
            guard case let .assign(_, values) = instruction.node, values.count == 1,
                  (try? program.row(at: values[0].span)) == 109,
                  case .select = values[0].node else { return nil }
            return values[0]
        }
        XCTAssertEqual(candidates.count, 1)
        return try XCTUnwrap(candidates.first)
    }

    // Literal AST fixtures: no production renderer, IR builder or binary decoder.
    // Full byte-backed selectors above continue to require numerical kills.
    private func literalMutationProgram(_ body: [(String, Int)], phiDefinition: Int? = nil) throws -> C.Program {
        let signature = "void literal_mutation(uint64_t x0_9, uint64_t x10_9, uint64_t x9_28) {"
        let terminal = "return; // return"
        var rows: [UInt64: Int] = [0x3afcc: 109, 0x3afc8: 108]
        var lines: [C.TextLine] = [.init(text: signature, source: nil, envelope: .signature)]
        for (index, item) in body.enumerated() {
            let address = UInt64(0x1000 + index * 4); rows[address] = item.1
            lines.append(.init(text: item.0, source: index == phiDefinition ? nil : address, envelope: .body,
                phiEdge: index == phiDefinition ? .init(blockAddress: 0x3afcc, predecessorAddress: 0x3afc8) : nil))
        }
        rows[0x3000] = 999
        lines.append(.init(text: terminal, source: 0x3000, envelope: .body))
        lines.append(.init(text: "}", source: nil, envelope: .closingBrace))
        let contract = C.Contract(signature: signature,
            inputs: [.init(name: "x0_9", type: .u64, entrySlot: 0),
                     .init(name: "x10_9", type: .u64, entrySlot: 1),
                     .init(name: "x9_28", type: .u64, entrySlot: 2)],
            fields: [], calls: [:], exterior: [:], terminalRow: 999, terminalPayload: terminal,
            terminalName: nil, returnType: nil, rowsByAddress: rows, allowedLabels: ["L_3afcc"],
            memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        return try C.Program(lines: lines, contract: contract)
    }

    func testCCMPMutationPolarityIgnoresIncidentalFirstSourceRows() throws {
        for (condition, expected) in [("(tmp37 == tmp30) && (tmp29 == tmp31)", "||"),
                                       ("(tmp37 != tmp30) || (tmp29 != tmp31)", "&&")] {
            let program = try diagnosticCCMPProgram([condition])
            let selected = try M.ccmpCondition(in: program, lhs: "tmp37", rhs: "tmp30", secondLHS: "tmp29", secondRHS: "tmp31")
            XCTAssertEqual(M.ccmpMutationOperator(selected, lhs: "tmp37", rhs: "tmp30",
                secondLHS: "tmp29", secondRHS: "tmp31", in: program), expected)
        }
    }
    func testMutationASTGapReportsRejectedAndDuplicateConditions() throws {
        let wrong = "(tmp37 == tmp30) || (tmp29 == tmp31)"
        let positive = "(tmp37 == tmp30) && (tmp29 == tmp31)"
        for (conditions, reason) in [([wrong], "requires both terms !="),
                                     ([positive, positive], "found 2, expected exactly1")] {
            let program = try diagnosticCCMPProgram(conditions)
            do {
                _ = try M.ccmpCondition(in: program, lhs: "tmp37", rhs: "tmp30", secondLHS: "tmp29", secondRHS: "tmp31")
                XCTFail("invalid or ambiguous condition must refuse")
            } catch {
                let message = String(describing: error)
                XCTAssertTrue(message.contains("mutation AST gap"), message)
                XCTAssertTrue(message.contains(conditions[0]), message)
                XCTAssertTrue(message.contains(reason), message)
                XCTAssertTrue(message.contains("candidate row=94"), message)
                XCTAssertTrue(message.contains("diagnostic first arm rows"), message)
            }
        }
    }
    private func diagnosticCCMPProgram(_ conditions: [String]) throws -> C.Program {
        var body: [(String, Int)] = [("uint32_t tmp37 = 2;", 91), ("uint32_t tmp30 = 2;", 77),
            ("int32_t tmp29 = 1;", 76), ("uint32_t tmp31 = 2;", 78)]
        for (index, condition) in conditions.enumerated() {
            body += [("if (\(condition)) {", 94), ("taken\(index) = 1;", 113),
                     ("} else {", 94), ("fallthrough\(index) = 0;", 96), ("}", 94)]
        }
        return try literalMutationProgram(body)
    }

    func testFlagMutationUsesOnlyProvenRow102IncomingEdge() throws {
        for transported in [false, true] {
            let program = try incomingFlagProgram(twoReachingDefinitions: false, transported: transported)
            let selected = try literalSelection(program)
            let mutation = try M.cselWidthMutation(in: program, selection: selected, call: "x0_9")
            XCTAssertEqual(program.phiEdge(at: mutation.span)?.blockAddress, 0x3afcc)
            XCTAssertEqual(program.phiEdge(at: mutation.span)?.predecessorAddress, 0x3afc8)
            let line = program.lines[program.tokens[mutation.span.first].line - 1].text
            XCTAssertTrue(line.contains("x0_9"), line)
            XCTAssertFalse(line.contains("x0_18"), line)
            XCTAssertEqual(mutation.replacement, "((uint64_t)(x0_9) == 0x0)")
            XCTAssertTrue(program.lines.contains { $0.text == "flag_3afcc_eq_0 = (uint32_t)(x0_18) == 0x0;" })
        }
    }
    func testFlagMutationRefusesTwoDefinitionsReachingSelectedEdgeUse() throws {
        // This literal is identical under both suite modes: either actual
        // assignment can reach the use AFTER predecessor108, so it must refuse.
        let program = try incomingFlagProgram(twoReachingDefinitions: true)
        do {
            _ = try M.cselWidthMutation(in: program, selection: literalSelection(program), call: "x0_9")
            XCTFail("two reaching definitions on selected incoming edge must refuse")
        } catch {
            let message = String(describing: error)
            XCTAssertEqual(message.components(separatedBy: "\n").first, "invalidContract: mutation AST gap: CSEL flag definition (no redefinitions), found 2, expected exactly1", message)
            XCTAssertTrue(message.contains("x0_9"), message)
            XCTAssertTrue(message.contains("x0_18"), message)
            XCTAssertTrue(message.contains("edge not proven uniquely row102-dependent"), message)
        }
    }
    private func incomingFlagProgram(twoReachingDefinitions: Bool, transported: Bool = false, customSelectedRHS: String? = nil) throws -> C.Program {
        let signature = "void incoming_flag(uint64_t route, uint64_t arg, uint64_t yes, uint64_t no) {"
        let terminal = "return; // return"
        let first = C.FrozenCall(row: 102, payload: "x0_9 = _jsimd_set_h1v2_fancy_upsample(arg); // call",
            target: "_jsimd_set_h1v2_fancy_upsample", resultName: "x0_9", control: nil,
            arguments: [.init(register: 0, width: 64)])
        let other = C.FrozenCall(row: 159, payload: "x0_18 = _jsimd_set_h2v2_fancy_upsample(arg); // call",
            target: "_jsimd_set_h2v2_fancy_upsample", resultName: "x0_18", control: nil,
            arguments: [.init(register: 0, width: 64)])
        var body: [(String, Int, UInt64?)] = [("int32_t flag_3afcc_eq_0;", 0, nil)]
        if twoReachingDefinitions {
            body += [(first.payload, 102, nil), (other.payload, 159, nil),
                     ("edge_value = 0;", 108, nil), ("if (route != 0) {", 90, nil)]
        } else {
            body += [("if (route != 0) {", 90, nil), (first.payload, 102, nil), ("edge_value = 0;", 108, nil)]
        }
        let bits = "(uint32_t)(((uint32_t)(x0_9) == 0x0))"
        let rhs = customSelectedRHS ?? (transported ? "((\(bits) & 0x80000000) == 0 ? (int32_t)\(bits) : -1 - (int32_t)(uint32_t)~\(bits))"
            : "(uint32_t)(x0_9) == 0x0")
        body += [("flag_3afcc_eq_0 = \(rhs);", 108, 0x3afc8), ("} else {", 90, nil)]
        if !twoReachingDefinitions { body.append((other.payload, 159, nil)) }
        body += [("flag_3afcc_eq_0 = (uint32_t)(x0_18) == 0x0;", 166, 0x3b0b0),
                 ("}", 90, nil), ("L_3afcc:", 109, nil),
                 ("tmp46 = (flag_3afcc_eq_0 != 0x0) ? yes : no;", 109, nil)]
        // Flag provenance is the real CMP, independent of the copy's incoming edge.
        // row104 @3afb8 and row161 @3b09c both carry bytes 1f 00 00 71 (CMP W0,#0).
        var rows: [UInt64: Int] = [0x3afb8: 104, 0x3b09c: 161,
            0x3afc8: 108, 0x3afcc: 109, 0x3b0b0: 166, 0x3000: 999]
        var lines: [C.TextLine] = [.init(text: signature, source: nil, envelope: .signature)]
        for (index, item) in body.enumerated() {
            let address = UInt64(0x1000 + index * 4); rows[address] = item.1
            let flagSource: UInt64? = item.2.map { $0 == 0x3afc8 ? 0x3afb8 : 0x3b09c }
            lines.append(.init(text: item.0, source: flagSource ?? address, envelope: .body,
                phiEdge: item.2.map { .init(blockAddress: 0x3afcc, predecessorAddress: $0) }))
        }
        lines.append(.init(text: terminal, source: 0x3000, envelope: .body))
        lines.append(.init(text: "}", source: nil, envelope: .closingBrace))
        let contract = C.Contract(signature: signature,
            inputs: [.init(name: "route", type: .u64, entrySlot: 0), .init(name: "arg", type: .u64, entrySlot: 1),
                     .init(name: "yes", type: .u64, entrySlot: 2), .init(name: "no", type: .u64, entrySlot: 3)],
            fields: [], calls: [102: first, 159: other], exterior: [:], terminalRow: 999, terminalPayload: terminal,
            terminalName: nil, returnType: nil, rowsByAddress: rows, allowedLabels: ["L_3afcc"],
            memoryEffects: [:], helpers: [:], deadResults: [],
            permissions: [.init(callRow: 102, sinkRow: 109, role: .selectionCondition),
                          .init(callRow: 159, sinkRow: 109, role: .selectionCondition),
                          // The deliberately uncertified negative is still an ordinary selection
                          // at its own flag-defining CMP; parsing must not hide matcher refusal.
                          .init(callRow: 102, sinkRow: 104, role: .selectionCondition),
                          .init(callRow: 159, sinkRow: 161, role: .selectionCondition)])
        return try C.Program(lines: lines, contract: contract)
    }
}

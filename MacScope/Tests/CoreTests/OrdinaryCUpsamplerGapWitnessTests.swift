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

/// SOURCE_ONLY / NOT_RUN until these two distinct selectors receive their own
/// first focused receipt. Product: 9784dcdde313f110d9dc2359004d56f63b0bee80.
/// Inputs: ordinary-c-native-v2-upsampler-dynamic-gap-triage.{md,json}.
/// Each selector audits the full typed fixture and executes one new complete-entry
/// source/text pair on its explicitly certified opaque derivative. No retained
/// 42-scenario suite is replayed.
final class OrdinaryCUpsamplerGapWitnessTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias O = RegionalCallOracle
    private typealias L = OrdinaryCSourceEdgeLedger
    private static let context: UInt64 = 0x10000
    private static let controller: UInt64 = 0x20000
    private static let errors: UInt64 = 0x30000
    private static let upsampler: UInt64 = 0x50000
    private static let components: UInt64 = 0x60000
    private static let stack: UInt64 = 0x80000
    private static let errorTarget: UInt64 = 0xf123_0000_0000_0100
    private static let sentinel: UInt64 = 0xa5a5_a5a5_a5a5_a5a5
    private static let remainingLimits = [
        "Retained 42-per-seed scenarios and 15 numerical mutation receipts are reused, not replayed.",
        "Returning-K/frozen-input scope only; even combined all-edge observation is not universal equivalence.",
        "No new stale-next-call-input-alias sensitivity at buffer192/136 or wrong-X22-counter-step sensitivity at196/140; stride/round-result controls are different obligations.",
        "Jinit CCMP normal-termination numerical mutant remains deferred; restoration scalar commits have separate new controls and are not duplicated here.",
        "Actual-color lost-shared-label6, upper-bound9, widened-zero-store, final-join-polarity, removed-shift-mask and implicit-pointer-conversion mutation sensitivities remain separate; positive paths do not replace them.",
        "Color frozen-table conditional nonexecution retains zero coverage credit, equal-target case ordinals remain ambiguous, and fused decrement writer observations remain unsupported.",
        "Exact ownerC2 census and broader authority/permission obligations are not established by these two traces.",
        "Original upsampler/skip printed-transfer maps remain missing; ADD-origin residual PC225 is a newly printed transfer, not historical goto-removal credit."
    ]

    func testUp3ae18NarrowFancyAndVerticalRemainderGapWitness() throws { try run(.jinit) }
    func testUp123b774NarrowFancyAndVerticalRemainderGapWitness() throws { try run(.j12init) }

    private struct Completed {
        let scenario: O.Scenario
        let actual: C.Result
        let reference: O.Result
    }
    private struct Edge {
        let edge: C.SourceEdge
        let row: Int
        let destinationRow: Int
        let role: L.Role
        var origin: L.Origin { .init(edge: edge, row: row, role: role) }
    }
    private struct Slot {
        let pc: Int
        let target: Int
        let destinationRow: Int
        let origin: L.Origin
        let occurrences: Int
        let newlyTargeted: Bool
    }
    private struct BoundSlot {
        let witness: Slot
        let span: C.Span?
        let pc: Int
        let target: Int
    }
    private struct Effect: Equatable {
        let row: Int
        let loading: Bool
        let address: UInt64
        let bytes: Int
        let bits: UInt64
    }

    private func run(_ seed: RegionalCallSeed) throws {
        guard seed == .jinit || seed == .j12init else {
            throw C.Failure.invalidContract("upsampler gap witness is bounded to two original void functions")
        }
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        let audit = try OrdinaryCOutputAudit.analyze(document: fixtures.full.document,
            function: fixtures.full.function, baselineText: fixtures.full.baselineText)
        guard audit.errors.isEmpty, !audit.tokens.contains(where: { $0.text.hasPrefix("rgn_regional_") }) else {
            throw C.Failure.unsupportedSyntax("UPSAMPLER_GAP_ORDINARY_PREREQUISITE: \(audit.errors)")
        }
        let contract = try C.contract(for: fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try O.Program(rows: fixture.rows, function: fixture.function)
        let sourceEdges = try L.source(rows: fixture.rows)
        let report = try L.analyze(candidate: candidate, source: sourceEdges)
        try report.requireCompleteTopology()
        let slots = try bindSlots(candidate, report: report, seed: seed)
        try requireManifest(report, slots: slots, seed: seed)

        // Only independent original entry registers, sparse memory and the
        // explicit returning-K script enter either machine. No expected output,
        // candidate temporary, source result or regional binding is an input.
        let scenario = try newScenario(seed)
        let reference = try O.Machine(program: source, scenario: scenario).run()
        let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
        try C.compare(actual, events: reference.events, memory: reference.memory.bytes,
            returned: reference.returned, terminal: reference.returnBits, contract: contract, name: scenario.name)
        XCTAssertTrue(reference.returned && actual.returned, scenario.name)
        XCTAssertFalse(actual.reachedRegionBoundary, scenario.name)
        XCTAssertNil(reference.returnBits, "original upsampler RET is void, not physical X0")
        XCTAssertNil(actual.terminal)
        XCTAssertEqual(actual.consumedResponses, scenario.responses.count)
        let pair = Completed(scenario: scenario, actual: actual, reference: reference)
        try observeCallsAndEffects(pair, seed: seed)
        try observeVerticalRemainder(pair, candidate: candidate, source: source, seed: seed,
            ssaEnabled: fixture.function.ssaEnabled)
        try observeBranches(pair, seed: seed)
        // Reuse precisely this completed pair. Neither machine nor renderer is
        // called again for coverage, residual observations or literal assertions.
        try observeCoverage(pair, candidate: candidate, report: report, slots: slots, seed: seed)
        print("ORDINARY_C_UPSAMPLER_GAP_LIMITS seed=\(seed.name) newPairs=1 \(Self.remainingLimits.joined(separator: " | "))")
    }

    private func newScenario(_ seed: RegionalCallSeed) throws -> O.Scenario {
        // Tuples contain only input (h, v, width). Both scales are 2, as is the
        // denominator; maxH=maxV=4. Width is an independent source field.
        let inputs: [(UInt64, UInt64, UInt64)] = seed == .jinit
            ? [(2,4,2),(2,4,3),(2,2,2),(1,3,7)]
            : [(2,4,2),(2,2,2),(1,3,7)]
        var memory = O.Memory()
        for (address, count) in canaryRegions(inputs.count) {
            memory.initialize(address, count: count, byte: 0xa5)
        }
        func put(_ address: UInt64, _ bits: UInt64, _ bytes: Int = 4) throws {
            try memory.store(.init(address: address, bytes: bytes, bits: bits))
        }
        try put(Self.context, Self.errors, 8)
        try put(Self.context + 0x238, Self.controller, 8)
        try put(Self.context + 0x278, Self.upsampler, 8)
        try put(Self.context + 0x130, Self.components, 8)
        try put(Self.context + 0x128, seed == .jinit ? 8 : 12)
        try put(Self.context + 0x18c, 0)
        try put(Self.context + 0x64, 1)
        try put(Self.context + 0x1a0, 2)
        try put(Self.context + 0x38, UInt64(inputs.count))
        try put(Self.context + 0x198, 4)
        try put(Self.context + 0x19c, 4)
        try put(Self.controller + 0x14, 0)
        try put(Self.controller + 0x70, 1)
        try put(Self.errors, Self.errorTarget, 8)
        for (index, input) in inputs.enumerated() {
            let base = Self.components + UInt64(index * 0x60)
            try put(base + 8, input.0); try put(base + 12, input.1)
            try put(base + 0x24, 2); try put(base + 0x2c, input.2); try put(base + 0x34, 1)
        }
        // No blanket object initialization, stack frame prefill, allocator,
        // C+8, C+0x88 or unscripted call default. Undefined loads must fail.
        for address in [Self.context + 8, Self.context + 0x88, UInt64(0x40000), Self.stack - 1] {
            XCTAssertNil(memory.bytes[address])
        }
        var registers: [Int: UInt64] = [0: Self.context, 31: Self.stack]
        for register in 19...30 { registers[register] = 0x8000_0000_1234_0000 | UInt64(register) }
        var responses: [O.Response] = []
        if seed == .jinit {
            responses = [
                .init(row: 129, result: 0x8000_0000_0000_0001, expectedArguments: [Self.context], expectedControl: []),
                .init(row: 122, result: 0x8000_0000_0000_0001, expectedArguments: [Self.context], expectedControl: []),
                .init(row: 168, result: 0x8000_0000_0000_0000, expectedArguments: [Self.context], expectedControl: [])
            ]
        }
        responses.append(.init(row: seed == .jinit ? 149 : 159,
            result: seed == .jinit ? 0x8123_4567_0000_0003 : 0x8123_4567_0000_0002,
            expectedArguments: [Self.context], expectedControl: [Self.errorTarget]))
        let n = inputs.count
        let visits = seed == .jinit ? [71:n,195:n,196:n,197:n,209:1,215:1] : [72:n,139:n,140:n,141:n,181:1,187:1]
        return .init(name: "new-full-entry-narrow-fancy-and-vertical-remainder-\(String(seed.start, radix: 16))",
            registers: registers, memory: memory, responses: responses, expectedVisits: visits)
    }

    private func canaryRegions(_ count: Int) -> [(UInt64, Int)] {
        [(Self.upsampler + 0x38, 24 + count * 8),
         (Self.upsampler + 0x90, 16 + count * 8),
         (Self.upsampler + 0xe8, 16 + count * 4),
         (Self.errors + 0x20, 20), (Self.stack - 0x68, 8), (Self.stack, 8)]
    }

    private func edge(_ from: Int, _ ordinal: Int, _ to: Int, _ row: Int,
                      _ destination: Int, _ role: L.Role) -> Edge {
        .init(edge: .init(fromBlock: from, toBlock: to, successorOrdinal: ordinal),
              row: row, destinationRow: destination, role: role)
    }
    private func targetedEdges(_ seed: RegionalCallSeed) -> [Edge] {
        seed == .jinit ? [
            edge(24,0,27,120,128,.taken), edge(25,1,26,124,125,.notTaken),
            edge(26,0,41,127,179,.unconditional), edge(31,1,32,143,144,.notTaken),
            edge(35,0,37,157,167,.taken), edge(37,0,40,170,177,.taken),
            edge(40,0,41,178,179,.fallthrough)
        ] : [
            edge(24,0,26,115,120,.taken), edge(35,1,36,153,154,.notTaken),
            edge(38,0,40,164,169,.taken)
        ]
    }
    private func relevantSlots(_ seed: RegionalCallSeed) -> [Slot] {
        if seed == .jinit {
            return [
                .init(pc: 187, target: 275, destinationRow: 180,
                      origin: edge(32,0,42,150,180,.unconditional).origin, occurrences: 1, newlyTargeted: false),
                .init(pc: 225, target: 273, destinationRow: 179,
                      origin: edge(40,0,41,178,179,.fallthrough).origin, occurrences: 1, newlyTargeted: true),
                .init(pc: 248, target: 273, destinationRow: 179,
                      origin: edge(26,0,41,127,179,.unconditional).origin, occurrences: 1, newlyTargeted: true),
                .init(pc: 298, target: 307, destinationRow: 195,
                      origin: edge(42,0,45,182,195,.taken).origin, occurrences: 4, newlyTargeted: false)
            ]
        }
        return [
            .init(pc: 179, target: 228, destinationRow: 124,
                  origin: edge(36,0,28,160,124,.unconditional).origin, occurrences: 1, newlyTargeted: false),
            .init(pc: 200, target: 226, destinationRow: 123,
                  origin: edge(40,0,27,172,123,.unconditional).origin, occurrences: 1, newlyTargeted: false),
            .init(pc: 251, target: 260, destinationRow: 139,
                  origin: edge(28,0,31,126,139,.taken).origin, occurrences: 3, newlyTargeted: false)
        ]
    }

    // pc/target in Slot are stable historical witness IDs, never indices into this mode.
    private func bindSlots(_ candidate: C.Program, report: L.Report,
                           seed: RegionalCallSeed) throws -> [BoundSlot] {
        var jumps: [(C.Statement, String)] = [], labels: [(String, C.Statement, C.Statement)] = []
        func walk(_ statement: C.Statement) {
            switch statement.node {
            case let .compound(_, children): children.forEach(walk)
            case let .conditional(_, yes, no): walk(yes); if let no { walk(no) }
            case let .whileLoop(_, body), let .doLoop(body, _): walk(body)
            case let .forLoop(initial, _, step, body):
                if let initial { walk(initial) }; walk(body); if let step { walk(step) }
            case let .label(name, body): labels.append((name, statement, body)); walk(body)
            case let .jump(name): jumps.append((statement, name))
            default: break
            }
        }
        walk(candidate.root)
        func owned(_ span: C.Span, address: UInt64) -> Bool {
            guard candidate.tokens.indices.contains(span.first) else { return false }
            let token = candidate.tokens[span.first], line = token.line - 1
            return candidate.lines.indices.contains(line) && candidate.lines[line].envelope == .body &&
                candidate.lines[line].phiEdge == nil && token.source == address
        }
        func site(_ span: C.Span) throws -> Int {
            let matches = candidate.code.indices.filter { candidate.code[$0].span == span }
            guard matches.count == 1 else { throw C.Failure.invalidContract("upsampler gap ambiguous compiled statement") }
            return matches[0]
        }
        return try relevantSlots(seed).map { witness in
            let source = report.source, origin = witness.origin
            guard source.rows.indices.contains(origin.row), source.rows.indices.contains(witness.destinationRow),
                  source.origins.contains(origin), source.blocks.indices.contains(origin.edge.toBlock),
                  source.blocks[origin.edge.toBlock].rows.lowerBound == witness.destinationRow else {
                throw C.Failure.invalidContract("upsampler gap source identity drift at witness \(witness.pc)")
            }
            let from = source.rows[origin.row].address, to = source.rows[witness.destinationRow].address
            let name = "L_" + String(to, radix: 16)
            let landings = labels.filter { $0.0 == name && owned($0.1.span, address: to) }
            guard landings.count == 1 else { throw C.Failure.invalidContract("upsampler gap target label drift at witness \(witness.pc)") }
            let landing = try site(landings[0].2.span)
            let transfers = jumps.filter { owned($0.0.span, address: from) }
            if transfers.count == 1 {
                let statement = transfers[0].0, pc = try site(statement.span)
                guard transfers[0].1 == name, case let .jump(target) = candidate.code[pc].node,
                      target == landing else {
                    throw C.Failure.invalidContract("upsampler gap transfer target drift at witness \(witness.pc)")
                }
                return .init(witness: witness, span: statement.span, pc: pc, target: landing)
            }
            // The only authorized non-printed witness is this original ADD fallthrough.
            guard transfers.isEmpty, seed == .jinit, witness.pc == 225,
                  origin == edge(40,0,41,178,179,.fallthrough).origin,
                  source.blocks[40].successors == [41] else {
                throw C.Failure.invalidContract("upsampler gap missing printed transfer at witness \(witness.pc)")
            }
            let row = source.rows[178]
            let successor = source.rows[source.blocks[41].rows.lowerBound].address
            try requireFallthroughEdge(address: row.address, bytes: row.bytes, mnemonic: row.mnemonic,
                                       successor: successor, label: to)
            let anchors = candidate.code.indices.filter { owned(candidate.code[$0].span, address: from) }
            guard anchors.count == 1, case .assign = candidate.code[anchors[0]].node,
                  try fallthroughCopies(candidate, predecessor: anchors[0], landing: landing,
                                        labelSpan: landings[0].1.span, from: from, to: to) else {
                throw C.Failure.invalidContract("upsampler gap missing printed transfer at witness 225: intervening statement or label")
            }
            try requireFallthroughControls(candidate, predecessor: anchors[0], landing: landing,
                                           labelSpan: landings[0].1.span, from: from, to: to)
            return .init(witness: witness, span: nil, pc: anchors[0], target: landing)
        }
    }

    private func requireFallthroughEdge(address: UInt64, bytes: String, mnemonic: String,
                                        successor: UInt64, label: UInt64) throws {
        guard address == 0x3b0e0, bytes.lowercased().split(whereSeparator: { $0.isWhitespace }).joined() == "29411791",
              mnemonic.lowercased() == "add", successor == address + 4,
              successor == label, label == 0x3b0e4 else {
            throw C.Failure.invalidContract("upsampler gap missing printed transfer at witness 225: ADD successor/label binding")
        }
    }

    private func fallthroughCopies(_ candidate: C.Program, predecessor: Int, landing: Int,
                                   labelSpan: C.Span, from: UInt64, to: UInt64,
                                   lines override: [C.TextLine]? = nil) throws -> Bool {
        let lines = override ?? candidate.lines
        guard predecessor + 1 < landing, candidate.code.indices.contains(landing),
              candidate.tokens.indices.contains(labelSpan.first) else { return false }
        let firstLine = candidate.tokens[candidate.code[predecessor].span.last - 1].line
        let labelLine = candidate.tokens[labelSpan.first].line - 1
        guard firstLine < labelLine, labelLine < lines.count else { return false }
        func copyValue(_ value: C.Expression) -> Bool {
            switch value.node {
            case .name, .literal: return true
            case let .cast(_, child): return copyValue(child)
            case let .select(_, positive, _):
                guard candidate.representationCasts.contains(value.span),
                      case let .cast(_, normalized) = positive.node else { return false }
                return copyValue(normalized)
            default: return false
            }
        }
        var copyLines: Set<Int> = []
        for pc in (predecessor + 1)..<landing {
            let instruction = candidate.code[pc]
            guard case let .assign(left, right) = instruction.node, left.count == 1, right.count == 1,
                  case .name = left[0].node, copyValue(right[0]) else { return false }
            let start = candidate.tokens[instruction.span.first].line - 1
            let end = candidate.tokens[instruction.span.last - 1].line - 1
            guard start == end, (firstLine..<labelLine).contains(start), lines.indices.contains(start) else { return false }
            // A same-line label emits no instruction of its own; require the
            // assignment to own every token on its line, not just its code node.
            let lineTokens = candidate.tokens.indices.filter { candidate.tokens[$0].line == start + 1 }
            guard lineTokens.first == instruction.span.first,
                  lineTokens.last == instruction.span.last - 1 else { return false }
            let line = lines[start]
            guard line.envelope == .body, line.source == nil,
                  line.phiEdge == C.PhiEdgeSource(blockAddress: to, predecessorAddress: from),
                  line.text == candidate.lines[start].text else { return false }
            copyLines.insert(start)
        }
        return copyLines == Set(firstLine..<labelLine)
    }

    private func requireFallthroughControls(_ candidate: C.Program, predecessor: Int, landing: Int,
                                            labelSpan: C.Span, from: UInt64, to: UInt64) throws {
        let line = candidate.tokens[candidate.code[predecessor].span.last - 1].line
        for text in ["unexpected_scalar = 0x0;", "L_3b0e0:;"] {
            var changed = candidate.lines
            changed.insert(.init(text: text, source: from, envelope: .body), at: line)
            XCTAssertFalse(try fallthroughCopies(candidate, predecessor: predecessor, landing: landing,
                                                labelSpan: labelSpan, from: from, to: to, lines: changed),
                           "intervening executable statement/label must require a printed transfer")
        }
        // Coherent candidate: an allowed, otherwise unused label prefixes the
        // real first copy. Labels add no code instruction, but must not vanish
        // from the window proof. A parse refusal is not this control's success.
        let extraLabel = "L_" + String(from - 4, radix: 16)
        guard candidate.contract.allowedLabels.contains(extraLabel),
              !candidate.tokens.contains(where: { $0.text == extraLabel }) else {
            throw C.Failure.invalidContract("upsampler gap inline-label control lacks unused source label")
        }
        var changed = candidate.lines
        let original = changed[line]
        changed[line] = .init(text: extraLabel + ": " + original.text, source: original.source,
                              envelope: original.envelope, phiEdge: original.phiEdge)
        let relabeled = try C.Program(lines: changed, contract: candidate.contract)
        XCTAssertEqual(relabeled.code.count, candidate.code.count, "label-only mutant must reach copy-window proof")
        let targetName = "L_" + String(to, radix: 16)
        let markers = relabeled.tokens.indices.filter { index in
            relabeled.tokens[index].text == targetName && index + 1 < relabeled.tokens.count &&
                relabeled.tokens[index + 1].text == ":"
        }
        guard markers.count == 1 else { throw C.Failure.invalidContract("upsampler gap mutated landing label is not unique") }
        XCTAssertFalse(try fallthroughCopies(relabeled, predecessor: predecessor, landing: landing,
            labelSpan: .init(first: markers[0], last: markers[0] + 2), from: from, to: to),
            "same-line label must require a printed transfer despite emitting no extra instruction")

    }

    private func requireManifest(_ report: L.Report, slots: [BoundSlot], seed: RegionalCallSeed) throws {
        let targets = targetedEdges(seed)
        XCTAssertEqual(targets.count, seed == .jinit ? 7 : 3)
        XCTAssertEqual(Set(targets.map(\.edge)).count, targets.count)
        XCTAssertEqual(report.source.origins.count, seed == .jinit ? 72 : 63)
        for item in targets {
            guard report.source.origins.contains(item.origin),
                  report.source.blocks[item.edge.toBlock].rows.lowerBound == item.destinationRow else {
                throw C.Failure.invalidContract("upsampler gap source edge/ordinal/role drift: \(edgeName(item.edge))")
            }
        }
        for slot in slots {
            if let span = slot.span {
                guard report.residualSlots.contains(where: {
                    $0.pc == slot.pc && $0.span == span && $0.target == slot.target && $0.origins == [slot.witness.origin]
                }) else { throw C.Failure.invalidContract("upsampler gap actual residual slot drift at witness \(slot.witness.pc)") }
            } else {
                guard report.accounts.contains(where: { $0.origin == slot.witness.origin && $0.disposition == .structured }),
                      !report.residualSlots.contains(where: { $0.origins.contains(slot.witness.origin) }) else {
                    throw C.Failure.invalidContract("upsampler gap structured fallthrough drift at witness 225")
                }
            }
        }
        if seed == .jinit {
            let row = report.source.rows[178]
            XCTAssertThrowsError(try requireFallthroughEdge(address: row.address, bytes: row.bytes, mnemonic: row.mnemonic,
                                                           successor: report.source.rows[180].address,
                                                           label: report.source.rows[179].address)) { error in
                XCTAssertEqual(String(describing: error), "invalidContract: upsampler gap missing printed transfer at witness 225: ADD successor/label binding")
            }
        }
        XCTAssertEqual(relevantSlots(seed).filter(\.newlyTargeted).map(\.pc), seed == .jinit ? [225,248] : [])
    }

    private func observeCoverage(_ pair: Completed, candidate: C.Program,
                                 report: L.Report, slots: [BoundSlot], seed: RegionalCallSeed) throws {
        let observation = try L.observe(report, candidate: candidate, actual: pair.actual,
            referenceBranches: pair.reference.branches, referenceRowVisits: pair.reference.rowVisits,
            referenceReturned: pair.reference.returned, name: pair.scenario.name)
        XCTAssertEqual(observation.sourceEdges, observation.candidateEdges)
        XCTAssertTrue(observation.possibleOriginGroups.allSatisfy { $0.count == 1 }, "never award plural possible-origin coverage")
        for item in targetedEdges(seed) {
            let visits = observation.sourceEdges.filter { $0 == item.edge }.count
            XCTAssertEqual(visits, 1, "missing/duplicated targeted source ordinal \(edgeName(item.edge))")
            print("ORDINARY_C_UPSAMPLER_GAP_EDGE scenario=\(pair.scenario.name) edge=\(edgeName(item.edge)) row=\(item.row) role=\(item.role) visits=\(visits)")
        }
        for slot in slots {
            if let span = slot.span {
                let groups = observation.residualOccurrences[span] ?? []
                XCTAssertEqual(groups.count, slot.witness.occurrences, "actual residual witness \(slot.witness.pc)")
                XCTAssertTrue(groups.allSatisfy { $0 == [slot.witness.origin] }, "residual origin remains exact, not inferred from target")
                print("ORDINARY_C_UPSAMPLER_GAP_RESIDUAL witness=\(slot.witness.pc)->\(slot.witness.target) pc=\(slot.pc) tokens=\(span.first)..<\(span.last) targetPC=\(slot.target) visits=\(groups.count) newlyTargeted=\(slot.witness.newlyTargeted)")
            } else {
                let routes = observation.observedRouteIndices.map { report.routes[$0] }.filter { $0.origins.contains(slot.witness.origin) }
                XCTAssertEqual(routes.count, slot.witness.occurrences, "structured witness225 retains its one predecessor visit")
                XCTAssertTrue(routes.allSatisfy { $0.destinationPC == slot.target && $0.executedPCs.contains(slot.pc) && $0.residualSpans.isEmpty })
                XCTAssertEqual(observation.candidateEdges.filter { $0 == slot.witness.origin.edge }.count, 1)
                print("ORDINARY_C_UPSAMPLER_GAP_STRUCTURED witness=225->\(slot.witness.target) predecessorPC=\(slot.pc) targetPC=\(slot.target) visits=\(routes.count) newlyTargeted=true; no printed-transfer credit")
            }
        }
        let observed = Set(observation.sourceEdges)
        let missing = Set(report.source.origins.map(\.edge)).subtracting(observed)
        let missingSlots = report.residualSlots.filter { observation.residualOccurrences[$0.span] == nil }.map(\.pc).sorted()
        print("ORDINARY_C_UPSAMPLER_GAP_OBSERVATION seed=\(seed.name) newPairs=1 targetedEdges=\(targetedEdges(seed).map { edgeName($0.edge) }) newOnlyObservedEdges=\(observed.count) newOnlyUnobservedEdges=\(missing.map(edgeName).sorted()) newOnlyUnobservedResidualPCs=\(missingSlots); no universal-equivalence or historical-removal inference")
    }

    private func effects(_ result: O.Result, row: Int? = nil) -> [Effect] {
        result.events.compactMap { event in
            switch event {
            case let .load(r, address, bytes, bits) where row == nil || row == r:
                return .init(row: r, loading: true, address: address, bytes: bytes, bits: bits)
            case let .store(r, address, bytes, bits) where row == nil || row == r:
                return .init(row: r, loading: false, address: address, bytes: bytes, bits: bits)
            default: return nil
            }
        }
    }
    private func effects(_ result: C.Result, row: Int? = nil) -> [Effect] {
        result.events.compactMap { event in
            switch event {
            case let .load(site, _, address, bytes, bits) where row == nil || row == site.row:
                return .init(row: site.row, loading: true, address: address, bytes: bytes, bits: bits)
            case let .store(site, _, address, bytes, bits) where row == nil || row == site.row:
                return .init(row: site.row, loading: false, address: address, bytes: bytes, bits: bits)
            default: return nil
            }
        }
    }
    private func requireEffects(_ pair: Completed, row: Int, _ expected: [Effect]) {
        XCTAssertEqual(effects(pair.reference, row: row), expected, "literal source effects row \(row)")
        XCTAssertEqual(effects(pair.actual, row: row), expected, "actual-text effects row \(row)")
    }

    private func observeCallsAndEffects(_ pair: Completed, seed: RegionalCallSeed) throws {
        let calls = pair.actual.events.compactMap { event -> C.CallEvent? in
            if case let .call(call) = event { return call }; return nil
        }
        let rows = seed == .jinit ? [129,122,168,149] : [159]
        let targets = seed == .jinit ? ["_jsimd_set_h2v1_upsample","_jsimd_set_h2v1_fancy_upsample","_jsimd_set_h2v2_upsample","(*x8)"] : ["(*x8)"]
        let results: [UInt64] = seed == .jinit
            ? [0x8000_0000_0000_0001,0x8000_0000_0000_0001,0x8000_0000_0000_0000,0x8123_4567_0000_0003]
            : [0x8123_4567_0000_0002]
        XCTAssertEqual(calls.map(\.row), rows); XCTAssertEqual(pair.reference.calls.map(\.row), rows)
        XCTAssertEqual(calls.map(\.target), targets); XCTAssertEqual(pair.reference.calls.map(\.target), targets)
        XCTAssertEqual(calls.map(\.result), results); XCTAssertEqual(pair.reference.calls.map(\.result), results)
        XCTAssertEqual(calls.map { $0.result & 0xffff_ffff }, seed == .jinit ? [1,1,0,3] : [2])
        XCTAssertTrue(calls.allSatisfy { $0.result >> 63 == 1 && $0.occurrence == 0 && $0.writes.isEmpty })
        for call in calls {
            XCTAssertEqual(call.arguments, [.init(register: 0, width: 64, bits: Self.context)])
            XCTAssertEqual(call.control, call.target == "(*x8)" ? [.init(register: 8, width: 64, bits: Self.errorTarget)] : [])
        }
        let pointers: [UInt64] = seed == .jinit ? [0x57f50,0x58018,0x3b5d0] : [0x3bc8c,0x3beb8]
        let rowgroups: [UInt64] = seed == .jinit ? [4,4,2,3] : [4,2,3]
        let functionRow = seed == .jinit ? 179 : 123, rowgroupRow = seed == .jinit ? 79 : 80
        requireEffects(pair, row: functionRow, pointers.enumerated().map {
            .init(row: functionRow, loading: false, address: Self.upsampler + 0x98 + UInt64($0.offset * 8), bytes: 8, bits: $0.element)
        })
        requireEffects(pair, row: rowgroupRow, rowgroups.enumerated().map {
            .init(row: rowgroupRow, loading: false, address: Self.upsampler + 0xf0 + UInt64($0.offset * 4), bytes: 4, bits: $0.element)
        })
        let errorStore = seed == .jinit ? 146 : 156
        requireEffects(pair, row: errorStore, [.init(row: errorStore, loading: false, address: Self.errors + 0x28, bytes: 4, bits: 0x27)])
        for (index, value) in (pointers + [Self.sentinel]).enumerated() {
            let address = Self.upsampler + 0x98 + UInt64(index * 8)
            XCTAssertEqual(try pair.reference.memory.load(address, bytes: 8), value, "component \(index) pointer or preserved fractional sentinel")
            XCTAssertEqual(try O.Memory(bytes: pair.actual.memory).load(address, bytes: 8), value,
                           "actual component \(index) pointer or preserved fractional sentinel")
        }
        // The final fractional component has no method-pointer store at all.
        let sentinelAddress = Self.upsampler + 0x98 + UInt64(pointers.count * 8)
        XCTAssertFalse(effects(pair.actual).contains { !$0.loading && $0.address < sentinelAddress + 8 && $0.address + UInt64($0.bytes) > sentinelAddress })

        // Only these literal output cells may change pre-existing memory. Stack
        // writes create exactly the original frame; all unlisted bytes stay absent.
        var changed: Set<UInt64> = []
        for item in effects(pair.reference, row: functionRow) + effects(pair.reference, row: rowgroupRow) + effects(pair.reference, row: errorStore) {
            changed.formUnion((0..<item.bytes).map { item.address + UInt64($0) })
        }
        for (address, byte) in pair.scenario.memory.bytes where !changed.contains(address) {
            XCTAssertEqual(pair.reference.memory.bytes[address], byte)
            XCTAssertEqual(pair.actual.memory[address], byte)
        }
        let frame = Set((0..<0x60).map { Self.stack - 0x60 + UInt64($0) })
        XCTAssertEqual(Set(pair.actual.memory.keys), Set(pair.scenario.memory.bytes.keys).union(frame))
        XCTAssertEqual(try pair.reference.memory.load(Self.upsampler + 0x40, bytes: 4), 0xa5a5_a5a5,
                       "narrow paths must not acquire the fancy H2V2 needs-context write")

        let errorCall = seed == .jinit ? 149 : 159
        let controllerRow = seed == .jinit ? 180 : 124, bypassRow = seed == .jinit ? 181 : 125
        let countRow = seed == .jinit ? 197 : 141
        let callIndex = try XCTUnwrap(pair.actual.events.firstIndex { if case let .call(c) = $0 { return c.row == errorCall }; return false })
        let suffix = Array(pair.actual.events.dropFirst(callIndex + 1).prefix(3))
        XCTAssertEqual(suffix.count, 3)
        let expected: [Effect] = [
            .init(row: controllerRow, loading: true, address: Self.context + 0x238, bytes: 8, bits: Self.controller),
            .init(row: bypassRow, loading: true, address: Self.controller + 0x70, bytes: 4, bits: 1),
            .init(row: countRow, loading: true, address: Self.context + 0x38, bytes: 4, bits: UInt64(rowgroups.count))
        ]
        let observed = suffix.compactMap { event -> Effect? in
            if case let .load(site, _, address, bytes, bits) = event {
                return .init(row: site.row, loading: true, address: address, bytes: bytes, bits: bits)
            }; return nil
        }
        XCTAssertEqual(observed, expected, "returning error must rejoin, bypass allocation and finish the final loop visit")
    }

    // SDIV's signed helper result is inferred for the SSA single-definition
    // quotient; native/default output declares its W-view carrier uint32_t.
    // MSUB is explicitly unsigned modular arithmetic in both outputs.
    private func verticalRemainderTypeMatches(_ type: C.CType, mnemonic: String,
                                               ssaEnabled: Bool) -> Bool {
        let expected: C.CType
        switch mnemonic {
        case "sdiv": expected = ssaEnabled ? .i32 : .u32
        case "msub": expected = .u32
        default: return false
        }
        return type == expected
    }

    private func observeVerticalRemainder(_ pair: Completed, candidate: C.Program,
                                          source: O.Program, seed: RegionalCallSeed,
                                          ssaEnabled: Bool) throws {
        let first = seed == .jinit ? 138 : 148
        let facts: [(Int, String, UInt64)] = [(first,"sdiv",4),(first + 1,"msub",0),(first + 3,"sdiv",1),(first + 4,"msub",1)]
        // Literal row ownership, not temporary spelling, identifies the scalar
        // observations. These outputs are checked only after execution finished.
        for (row, mnemonic, bits) in facts {
            XCTAssertEqual(source.rows[row].mnemonic, mnemonic)
            XCTAssertEqual(pair.reference.rowVisits[row], 1)
            let commits = pair.actual.commits.filter { $0.sourceRow == row }
            XCTAssertEqual(commits.count, 1, "unique remainder scalar at row \(row)")
            let commit = try XCTUnwrap(commits.first)
            XCTAssertEqual(try candidate.row(at: commit.span), row)
            XCTAssertTrue(verticalRemainderTypeMatches(commit.value.type,
                mnemonic: mnemonic, ssaEnabled: ssaEnabled), "exact source-bound remainder type at row \(row)")
            XCTAssertEqual(commit.value.bits, bits, "horizontal exact then vertical-only remainder")
            // Literal type-only adversaries exercise the same predicate; they
            // do not execute another machine or modify the observed bits.
            let unsigned = !(ssaEnabled && mnemonic == "sdiv")
            for wrongWidth in [16, 64] {
                XCTAssertFalse(verticalRemainderTypeMatches(C.CType(wrongWidth, unsigned),
                    mnemonic: mnemonic, ssaEnabled: ssaEnabled), "wrong width at row \(row)")
            }
            XCTAssertFalse(verticalRemainderTypeMatches(.jpegPointer,
                mnemonic: mnemonic, ssaEnabled: ssaEnabled), "pointer is not an integer remainder at row \(row)")
            XCTAssertFalse(verticalRemainderTypeMatches(C.CType(32, !unsigned),
                mnemonic: mnemonic, ssaEnabled: ssaEnabled), "wrong signedness at row \(row)")
        }
        XCTAssertEqual(pair.reference.branches.filter { $0.row == first + 2 }.map(\.taken), [false])
        XCTAssertEqual(pair.reference.branches.filter { $0.row == first + 5 }.map(\.taken), [false])
    }

    private func observeBranches(_ pair: Completed, seed: RegionalCallSeed) throws {
        let predictions: [[Int: Bool]] = seed == .jinit ? [
            [85:true,93:true,117:false,120:true,131:false,182:true,199:true],
            [85:true,93:true,117:false,120:false,124:false,182:true,199:true],
            [85:true,93:false,100:true,137:true,154:false,157:true,170:true,182:true,199:true],
            [85:true,93:false,100:true,137:false,140:false,143:false,182:true,199:false]
        ] : [
            [86:true,94:true,112:false,115:true,126:true,143:true],
            [86:true,94:false,101:true,147:true,161:false,164:true,126:true,143:true],
            [86:true,94:false,101:true,147:false,150:false,153:false,126:true,143:false]
        ]
        let loopStart = seed == .jinit ? 71 : 72, loopEnd = seed == .jinit ? 199 : 143
        var groups: [[O.Branch]] = [], pending: [O.Branch] = []
        for branch in pair.reference.branches where branch.row >= loopStart && groups.count < predictions.count {
            pending.append(branch)
            if branch.row == loopEnd { groups.append(pending); pending = [] }
        }
        XCTAssertEqual(groups.count, predictions.count)
        XCTAssertTrue(pending.isEmpty)
        for (index, prediction) in predictions.enumerated() {
            let group = try XCTUnwrap(groups.indices.contains(index) ? groups[index] : nil)
            for (row, taken) in prediction {
                XCTAssertEqual(group.filter { $0.row == row }.map(\.taken), [taken], "component \(index), branch row \(row)")
            }
        }
        let errorReturn = seed == .jinit ? 150 : 160
        XCTAssertEqual(pair.reference.branches.filter { $0.row == errorReturn }.map(\.taken), [true])
        let absent = seed == .jinit ? [21,35,51,102,159,187,192] : [21,35,52,131,136]
        for row in absent { XCTAssertEqual(pair.reference.rowVisits[row, default: 0], 0, "unplanned callback row \(row)") }
    }

    private func edgeName(_ edge: C.SourceEdge) -> String {
        "\(edge.fromBlock):\(edge.successorOrdinal)->\(edge.toBlock)"
    }
}

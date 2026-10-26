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

/// New selectors: one changed candidate render per real fixture, independent
/// literal-source execution, then actual-text execution. Historical labelled
/// dialect selectors/receipts are never invoked or reclassified as acceptance.
/// SOURCE_ONLY / NOT_RUN until the parent records the first focused execution.
final class OrdinaryCSemanticTests: XCTestCase {
    private typealias C = OrdinaryC
    func testColor26c78OrdinaryCandidateWholeFunctionSemantics() throws { try color(.jinit) }
    func testColor122893cOrdinaryCandidateWholeFunctionSemantics() throws { try color(.j12init) }
    func testUp3ae18OrdinaryCandidateWholeFunctionSemantics() throws { try upsampler(.jinit) }
    func testUp123b774OrdinaryCandidateWholeFunctionSemantics() throws { try upsampler(.j12init) }
    func testSkip33418OrdinaryCandidateWholeFunctionSemantics() throws {
        let fixture = try OrdinaryCRecordedCallFixture.skipVariable()
        try ordinaryPrerequisite(document: fixture.document, function: fixture.function, baseline: fixture.baselineText)
        let contract = try C.contract(for: fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try OrdinaryCSkipSourceOracle.Program(rows: fixture.rows, function: fixture.function)
        let scenarios = try OrdinaryCSkipSourceOracle.Scenarios.all()
        XCTAssertEqual(scenarios.count, 13, "explicit newly-authored skip scenario inventory")
        var terminals: Set<UInt64> = []
        for scenario in scenarios {
            let expected = try OrdinaryCSkipSourceOracle.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: expected.returnBits, contract: contract, name: scenario.name)
            terminals.insert(try XCTUnwrap(actual.terminal?.bits))
        }
        XCTAssertEqual(terminals, [0,1], "both original W21-origin terminal paths")
        try assertDeadResultReadRejected(candidate)
        try assertSkipTerminalRoleRejected(candidate)
    }
    private func ordinaryPrerequisite(document: PseudocodeDocument, function: MacIRFunction, baseline: String) throws {
        let report = try OrdinaryCOutputAudit.analyze(document: document, function: function, baselineText: baseline)
        let oldNames = report.tokens.filter { $0.text.hasPrefix("rgn_regional_") }
        guard report.errors.isEmpty, oldNames.isEmpty else {
            XCTFail("ORDINARY_C_SEMANTIC_PREREQUISITE: actual complete output still uses rejected control/state dialect; candidate equivalence has NOT run. \(report.errors.joined(separator: "; "))")
            throw C.Failure.unsupportedSyntax("named ordinary-control prerequisite, not a source-oracle or parser-infrastructure RED")
        }
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
        let scenarios = all.filter { $0.startRow == 0 && $0.stopBeforeRow == nil && $0.regionalBindings.isEmpty }
        let regional = all.filter { $0.startRow != 0 || $0.stopBeforeRow != nil || !$0.regionalBindings.isEmpty }
        XCTAssertEqual(regional.count, 17, "historical regional cases explicitly inventoried, NOT counted as full-entry equivalence")
        let names = Set(scenarios.map(\.name))
        for required in ["gray-zero-iterations", "gray-one-iteration", "gray-multiple-iterations", "gray-64-bit-pointer", "gray-count-memory-alias"] {
            XCTAssertTrue(names.contains(required), "missing required full-entry scenario \(required)")
        }
        var references: [String: RegionalSwitchOracle.Result] = [:]
        for scenario in scenarios {
            let expected = try RegionalSwitchOracle.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: nil, contract: contract, name: scenario.name)
            try observeColorRecurrence(actual, program: candidate, expected: expected, seed: seed, name: scenario.name)
            references[scenario.name] = expected
        }
        try assertDeadResultReadRejected(candidate)
        try assertAlphaRenaming(candidate, scenario: C.scenario(try XCTUnwrap(scenarios.first { $0.name == "gray-multiple-iterations" }), contract: contract))
        try colorCounterMutation(candidate, seed: seed, scenarios: scenarios, references: references)
        // Deliberately no claim here that regional-only guard/shift/TST witnesses
        // have been ported. The uncovered obligation is recorded in the separate explicit manifest.
    }
    private func upsampler(_ seed: RegionalCallSeed) throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        try ordinaryPrerequisite(document: fixture.document, function: fixture.function, baseline: fixture.baselineText)
        let contract = try C.contract(for: fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try RegionalCallOracle.Program(rows: fixture.rows, function: fixture.function)
        let scenarios = try RegionalCallOracle.UpsamplerScenarios.all(for: seed)
        for required in ["zero-bypass-no-call-result", "zero-allocation", "two-returning-prefix-errors", "multiple-distinct-joins-and-call-results",
                         "current-X28-snapshot-and-later-control-reload", "same-execution-CSEL-writer-time-flags"] {
            XCTAssertTrue(scenarios.contains { $0.name == required }, "missing retained scenario \(required)")
        }
        for scenario in scenarios {
            let expected = try RegionalCallOracle.Machine(program: source, scenario: scenario).run()
            let actual = try C.Machine(program: candidate, scenario: C.scenario(scenario, contract: contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: nil, contract: contract, name: scenario.name)
        }
        try assertDeadResultReadRejected(candidate)
        try assertAlphaRenaming(candidate, scenario: C.scenario(try XCTUnwrap(scenarios.first { $0.name == "multiple-distinct-joins-and-call-results" }), contract: contract))
        if seed == .jinit { try assertCSELDataRoleRejected(candidate) }
    }
    private func observeColorRecurrence(_ actual: C.Result, program: C.Program, expected: RegionalSwitchOracle.Result,
                                        seed: RegionalSwitchSeed, name: String) throws {
        let writer = seed == .jinit ? 254 : 247
        guard let snapshots = expected.afterRows[writer], !snapshots.isEmpty else { return }
        let expectedValues = try snapshots.map { try XCTUnwrap($0.registers[9]) }
        // Source identity selects already-executed parsed commits; no reference
        // snapshot is imported into the candidate environment. The parsed
        // producer is selected structurally before its numerical values are read.
        let arithmetic = expressions(program.root).filter { e in
            guard (try? program.row(at: e.span)) == writer else { return false }
            if case let .binary(op, _, right) = e.node, op == "-" { return recurrenceUnitLiteral(right, program: program) != nil }
            return false
        }
        guard arithmetic.count == 1 else { throw C.Failure.invalidContract("unique parsed recurrence producer missing") }
        let producers = assignments(program.root).compactMap { statement -> C.Expression? in
            guard case let .assign(left, right) = statement.node, left.count == 1, right.count == 1,
                  right[0].span.first <= arithmetic[0].span.first, right[0].span.last >= arithmetic[0].span.last else { return nil }
            return left[0]
        }
        guard producers.count == 1, case let .name(name) = producers[0].node,
              program.symbols[name]?.type == .u64,
              program.expressionTypes[arithmetic[0].span] == .u64 else {
            throw C.Failure.invalidContract("recurrence needs one source-bound uint64 scalar lhs and uint64 subtraction expression")
        }
        let commits = actual.commits.filter { $0.span == producers[0].span }
        guard commits.allSatisfy({ $0.name == name && $0.value.type == .u64 }),
              commits.map(\.value.bits) == expectedValues else { throw C.Failure.semanticMismatch("\(name): actual parsed X64 writer differs at \(writer)") }
    }
    private func recurrenceUnitLiteral(_ expression: C.Expression, program: C.Program) -> C.Expression? {
        if case let .literal(value) = expression.node { return value.bits == 1 ? expression : nil }
        // Actual native-v2 text uses (uint64_t)(0x1). This is already parsed
        // syntax, not a fused update or constant-folding license. Preserve its
        // cast and select only its literal token for the counter mutation.
        guard case let .cast(type, literal) = expression.node, type == .u64,
              program.expressionTypes[expression.span] == .u64,
              case let .literal(value) = literal.node, value.bits == 1 else { return nil }
        return literal
    }
    private func assertDeadResultReadRejected(_ original: C.Program) throws {
        guard let row = original.contract.deadResults.sorted().first, let name = original.contract.calls[row]?.resultName else {
            throw C.Failure.invalidContract("no frozen dead result available for authority control")
        }
        var lines = original.lines
        // Unreachable after the original return, still before the function close.
        // Full AST checking must reject the read, even though it cannot execute.
        lines.insert(.init(text: "    tmp_900001 = \(name);", source: nil, envelope: .body), at: lines.count - 1)
        expectFailure(.authority) { _ = try C.Program(lines: lines, contract: original.contract) }
    }
    private func assertSkipTerminalRoleRejected(_ original: C.Program) throws {
        guard let live = original.contract.calls[12]?.resultName else { throw C.Failure.invalidContract("missing live refill result") }
        let statements = assignments(original.root).filter { statement in
            // Original W21=1 is the authorized success-result producer. Change
            // only its unprotected parsed scalar RHS, not any call/export/return.
            (try? original.row(at: statement.span)) == 37
        }
        guard statements.count == 1, case let .assign(_, right) = statements[0].node, right.count == 1 else { throw C.Failure.invalidContract("unique actual W21 success producer missing") }
        let mutated = try replaced(original, span: right[0].span, with: "(uint64_t)(\(live))")
        expectFailure(.authority) { _ = try C.Program(lines: mutated, contract: original.contract) }
    }
    private func assertCSELDataRoleRejected(_ original: C.Program) throws {
        let expressions = expressions(original.root).filter { e in
            guard (try? original.row(at: e.span)) == 109 else { return false }
            if case .select = e.node { return true }; return false
        }
        guard expressions.count == 1, case let .select(_, yes, _) = expressions[0].node,
              let result = original.contract.calls[102]?.resultName else { throw C.Failure.invalidContract("unique actual CSEL arm not available") }
        let lines = try replaced(original, span: yes.span, with: result)
        expectFailure(.authority) { _ = try C.Program(lines: lines, contract: original.contract) }
    }
    private func assertAlphaRenaming(_ original: C.Program, scenario: C.Scenario) throws {
        let eligible = original.symbols.keys.filter { !original.protectedNames.contains($0) }.sorted()
        guard !eligible.isEmpty else { throw C.Failure.invalidContract("no nonprotected scalar for alpha-renaming") }
        let map = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($0.element, "renamed_local_\($0.offset)") })
        var lines = original.lines
        for lineIndex in lines.indices {
            let tokens = try C.lex(lines[lineIndex].text)
            var bytes = Array(lines[lineIndex].text.utf8)
            for token in tokens.reversed() {
                if let name = map[token.text] { bytes.replaceSubrange(token.byteOffset..<(token.byteOffset + token.text.utf8.count), with: name.utf8) }
            }
            lines[lineIndex] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[lineIndex].source, envelope: lines[lineIndex].envelope)
        }
        let renamed = try C.Program(lines: lines, contract: original.contract)
        let a = try C.Machine(program: original, scenario: scenario).run(), b = try C.Machine(program: renamed, scenario: scenario).run()
        XCTAssertEqual(a.events, b.events); XCTAssertEqual(a.memory, b.memory); XCTAssertEqual(a.terminal, b.terminal)
    }
    private func colorCounterMutation(_ original: C.Program, seed: RegionalSwitchSeed,
                                      scenarios: [RegionalSwitchOracle.Scenario], references: [String: RegionalSwitchOracle.Result]) throws {
        let writer = seed == .jinit ? 254 : 247
        let candidates = expressions(original.root).filter { e in
            guard (try? original.row(at: e.span)) == writer else { return false }
            if case let .binary(op, _, rhs) = e.node, op == "-" { return recurrenceUnitLiteral(rhs, program: original) != nil }
            return false
        }
        guard candidates.count == 1, case let .binary(_, _, right) = candidates[0].node,
              let one = recurrenceUnitLiteral(right, program: original) else {
            throw C.Failure.invalidContract("unique actual counter-step AST missing; mutation not silently skipped")
        }
        // Count5 produces four original stores; subtract2 still reaches zero
        // normally. Fuel exhaustion/error is not a successful semantic kill.
        let name = "gray-four-iterations"
        let sourceScenario = try XCTUnwrap(scenarios.first { $0.name == name }), expected = try XCTUnwrap(references[name])
        let mutant = try C.Program(lines: replaced(original, span: one.span, with: "0x2"), contract: original.contract)
        let result = try C.Machine(program: mutant, scenario: C.scenario(sourceScenario, contract: original.contract)).run()
        XCTAssertTrue(result.returned)
        expectFailure(.semantic) {
            try C.compare(result, events: expected.events, memory: expected.memory.bytes, returned: expected.returned,
                          terminal: nil, contract: original.contract, name: "wrong-color-counter-step")
        }
    }
    private enum ExpectedFailure { case authority, semantic }
    private func expectFailure(_ expected: ExpectedFailure, file: StaticString = #filePath, line: UInt = #line, _ action: () throws -> Void) {
        do { try action(); XCTFail("expected named failure", file: file, line: line) }
        catch let error as C.Failure {
            switch (expected, error) {
            case (.authority, .callAuthorityViolation), (.semantic, .semanticMismatch): break
            default: XCTFail("wrong failure category: \(error)", file: file, line: line)
            }
        } catch { XCTFail("infrastructure error, not expected failure: \(error)", file: file, line: line) }
    }
    private func replaced(_ program: C.Program, span: C.Span, with replacement: String) throws -> [C.TextLine] {
        guard span.first < span.last, program.tokens.indices.contains(span.first), program.tokens.indices.contains(span.last - 1) else { throw C.Failure.invalidContract("invalid mutation span") }
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line else { throw C.Failure.invalidContract("mutation needs one actual expression line") }
        let line = first.line - 1, offset = program.lines.prefix(line).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(program.lines[line].text.utf8)
        bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset - offset + last.text.utf8.count), with: replacement.utf8)
        var lines = program.lines
        lines[line] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[line].source, envelope: lines[line].envelope)
        return lines
    }
    private func assignments(_ root: C.Statement) -> [C.Statement] {
        var result: [C.Statement] = []
        func walk(_ s: C.Statement) {
            switch s.node {
            case .assign: result.append(s)
            case let .compound(_, body): body.forEach(walk)
            case let .conditional(_, a, b): walk(a); if let b { walk(b) }
            case let .whileLoop(_, b), let .doLoop(b, _), let .label(_, b): walk(b)
            case let .forLoop(i, _, step, b): if let i { walk(i) }; walk(b); if let step { walk(step) }
            default: break
            }
        }
        walk(root); return result
    }
    private func expressions(_ root: C.Statement) -> [C.Expression] {
        var result: [C.Expression] = []
        func expression(_ e: C.Expression) {
            result.append(e)
            switch e.node {
            case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): expression(e)
            case let .binary(_, a, b): expression(a); expression(b)
            case let .select(c, a, b): expression(c); expression(a); expression(b)
            case let .helper(_, args): args.forEach(expression)
            default: break
            }
        }
        func statement(_ s: C.Statement) {
            switch s.node {
            case let .compound(_, body): body.forEach(statement)
            case let .declaration(_, _, e), let .returned(e): if let e { expression(e) }
            case let .assign(lhs, rhs): lhs.forEach(expression); rhs.forEach(expression)
            case let .update(e): expression(e)
            case let .conditional(e, a, b): expression(e); statement(a); if let b { statement(b) }
            case let .whileLoop(e, b), let .doLoop(b, e): expression(e); statement(b)
            case let .forLoop(i, e, step, b): if let i { statement(i) }; if let e { expression(e) }; if let step { statement(step) }; statement(b)
            case let .label(_, s): statement(s)
            case let .call(_, _, c, args): if let c { expression(c) }; args.forEach(expression)
            default: break
            }
        }
        statement(root); return result
    }
}

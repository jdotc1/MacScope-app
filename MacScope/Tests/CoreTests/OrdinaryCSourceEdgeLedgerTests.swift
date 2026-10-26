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

/// New, bounded observer regression. SOURCE_ONLY / NOT_RUN until recorded.
/// One real complete decoded input, including its retained render metadata,
/// supplies the positive AST. Mutants change only that actual predicate text.
/// Static topology proves neither numerical execution nor dynamic case coverage.
final class OrdinaryCSourceEdgeLedgerTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias L = OrdinaryCSourceEdgeLedger

    func testRealColorBooleanZeroTestsKeepOriginsAndRejectWrongRoutes() throws {
        let fixture = try RegionalSwitchFixture.make(.j12init)
        XCTAssertEqual(fixture.input.instructions, fixture.capture.input_rows)
        try fixture.requireCompleteInputAuthority()
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try C.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.baselineText, callRows: fixture.seed.callRows, blockAddresses: blocks)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try L.source(rows: fixture.rows, color: fixture.capture)
        let report = try L.analyze(candidate: candidate, source: source)
        try report.requireCompleteTopology()
        try requireOriginalOrigins(report)

        // Locate the actual native singleton predicate at each original BR row.
        // Neither variable spelling nor production structuring plans is an oracle.
        let dispatchRows = source.dispatches.keys.sorted()
        XCTAssertEqual(dispatchRows.count, 2)
        func conditions(_ row: Int) -> [C.Expression] {
            candidate.code.compactMap { instruction in
                guard case let .branch(expression, _, _) = instruction.node,
                      (try? candidate.row(at: expression.span)) == row else { return nil }
                return expression
            }
        }
        func singleton(_ row: Int) throws -> (outer: C.Expression, predicate: C.Expression, selector: C.Expression, name: String) {
            let expression = try XCTUnwrap(conditions(row).first)
            let predicate: C.Expression
            if case let .binary("!=", child, zero) = expression.node,
               case let .literal(outerZero) = zero.node, outerZero.bits == 0 {
                predicate = child
            } else if fixture.function.ssaEnabled {
                // SSA recovery prints a direct unsigned equality; exercise its nested wrapper below.
                predicate = expression
            } else {
                throw C.Failure.invalidContract("actual dispatch lost its nested singleton zero-test witness")
            }
            guard case let .binary("==", selector, value) = predicate.node,
                  case let .literal(innerZero) = value.node, innerZero.bits == 0 else {
                throw C.Failure.invalidContract("actual dispatch lost its singleton zero-test witness")
            }
            let name: String
            if case let .name(raw) = selector.node {
                name = raw
            } else if fixture.function.ssaEnabled,
                      case let .cast(type, child) = selector.node, type == .u32,
                      case let .name(raw) = child.node {
                name = raw
            } else {
                throw C.Failure.invalidContract("actual singleton lost its selector witness")
            }
            return (expression, predicate, selector, name)
        }
        let first = try singleton(dispatchRows[0]), other = try singleton(dispatchRows[1])
        XCTAssertNotEqual(first.name, other.name)
        let predicate = try text(candidate, first.predicate.span)
        let firstSelector = fixture.function.ssaEnabled ? try text(candidate, first.selector.span) : first.name
        let otherSelector = fixture.function.ssaEnabled ? try text(candidate, other.selector.span) : other.name
        let variants = [
            "nested-child-nonzero-test": "((\(predicate)) != 0x0)",
            "reversed-zero-operands": "(0x0 != (\(predicate)))",
            "inverted-child-equals-zero": "((!(\(predicate))) == 0x0)"
        ]
        for (name, replacement) in variants {
            let changed = try C.Program(lines: replacing(candidate, first.outer.span, replacement), contract: contract)
            let mapped = try L.analyze(candidate: changed, source: source)
            try mapped.requireCompleteTopology()
            try requireOriginalOrigins(mapped)
            XCTAssertEqual(Set(mapped.accounts.map(\.origin)), Set(report.accounts.map(\.origin)), name)
        }

        let negatives = [
            "inverted-outer-polarity": "((\(predicate)) == 0x0)",
            "nonzero-boolean-wrapper": "((\(predicate)) != 0x1)",
            "wrong-case-literal": "((\(firstSelector) == 0x2) != 0x0)",
            "non-predicate-arithmetic-child": "(((\(predicate)) + 0x0) != 0x0)",
            "unsupported-ordering-predicate": "((\(firstSelector) < 0x1) != 0x0)",
            "wrong-selector": "((\(otherSelector) == 0x0) != 0x0)",
            "mixed-selector-composition": "((\(predicate)) || (\(otherSelector) == 0x1))"
        ]
        for (name, replacement) in negatives {
            try requireTopologyRefusal(candidate, source: source, span: first.outer.span,
                                       replacement: replacement, name: name)
        }

        // Cases 1 and 6 share one target/CFG successor but remain two source
        // origins. Removing only 6 must not be hidden by target reachability.
        let grouped = try XCTUnwrap(conditions(dispatchRows[0]).dropFirst().first)
        guard case .binary("||", _, _) = grouped.node else {
            throw C.Failure.invalidContract("actual dispatch lost its grouped case witness")
        }
        let caseOne = try XCTUnwrap(source.origins.first { $0.row == dispatchRows[0] && $0.role == .tableCase(1) })
        let caseSix = try XCTUnwrap(source.origins.first { $0.row == dispatchRows[0] && $0.role == .tableCase(6) })
        XCTAssertEqual(caseOne.edge, caseSix.edge)
        let missing = try requireTopologyRefusal(candidate, source: source, span: grouped.span,
            replacement: "(\(firstSelector) == 0x1)", name: "removed-shared-case-six",
            expectedGap: "unaccounted-source-origin")
        // Case1 still maps. Deleting case6 now enters the exhaustive final
        // real-case arm, whose goto retains its own valid origins; only the
        // distinct case6 source origin is missing. Test an unbacked goto below.
        XCTAssertEqual(missing.gaps.map(\.kind), ["unaccounted-source-origin"])
        XCTAssertEqual(Set(missing.accounts.filter { $0.disposition == .unresolved }.map(\.origin)), [caseSix])
        let surviving = try XCTUnwrap(missing.accounts.first { $0.origin == caseOne })
        XCTAssertFalse(surviving.routeIndices.isEmpty)
        XCTAssertNotEqual(surviving.disposition, .unresolved)
    }

    func testByteBackedOriginlessGotoRefusesExactlyInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalSwitchSeed.jinit, .j12init] {
                    let fixture = try RegionalSwitchFixture.make(seed)
                    try fixture.requireCompleteInputAuthority()
                    let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
                    let contract = try C.contract(rows: fixture.rows, function: fixture.function,
                        baseline: fixture.baselineText, callRows: fixture.seed.callRows, blockAddresses: blocks)
                    let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
                    let source = try L.source(rows: fixture.rows, color: fixture.capture)
                    let original = try L.analyze(candidate: candidate, source: source)
                    try original.requireCompleteTopology()
                    try requireOriginalOrigins(original)
                    let slot = try XCTUnwrap(original.residualSlots.first { slot in
                        let token = candidate.tokens[slot.span.first]
                        return token.text == "goto" && candidate.lines[token.line - 1].envelope == .body
                    }, "a real residual goto to an existing parsed label")
                    let line = candidate.tokens[slot.span.first].line - 1
                    // Tokens exclude the real line's trailing comment. Source nil
                    // prevents the new dead arm from borrowing an original identity.
                    let transfer = candidate.tokens[slot.span.first..<slot.span.last].map(\.text).joined(separator: " ")
                    var lines = candidate.lines
                    lines.insert(.init(text: "    if (false) { \(transfer) }", source: nil, envelope: .body), at: line)
                    let changed = try C.Program(lines: lines, contract: contract)
                    let injected = changed.code.indices.filter { pc in
                        guard case .jump = changed.code[pc].node else { return false }
                        let token = changed.tokens[changed.code[pc].span.first]
                        return token.line == line + 1 && token.text == "goto"
                    }
                    XCTAssertEqual(injected.count, 1)
                    let pc = try XCTUnwrap(injected.first)
                    let report = try L.analyze(candidate: changed, source: source)
                    XCTAssertEqual(report.gaps, [.init(kind: "unexplained-printed-goto", detail: "PC \(pc)")])
                    XCTAssertEqual(report.residualSlots.filter { $0.origins.isEmpty }.map(\.pc), [pc])
                    XCTAssertEqual(Set(report.accounts.map(\.origin)), source.origins)
                    XCTAssertTrue(report.accounts.allSatisfy { $0.disposition != .unresolved && $0.disposition != .mixed })
                    XCTAssertThrowsError(try report.requireCompleteTopology()) { error in
                        guard case let C.Failure.invalidContract(reason) = error else {
                            return XCTFail("unrelated originless-goto refusal: \(error)")
                        }
                        XCTAssertEqual(reason, "SOURCE_EDGE_COVERAGE_GAP: unexplained-printed-goto: PC \(pc)")
                    }
                }
            }
        }
    }

    private func requireOriginalOrigins(_ report: L.Report) throws {
        XCTAssertEqual(Set(report.accounts.map(\.origin)), report.source.origins)
        XCTAssertTrue(report.accounts.allSatisfy { $0.disposition != .unresolved && $0.disposition != .mixed })
        XCTAssertTrue(report.residualSlots.allSatisfy { !$0.origins.isEmpty })
        XCTAssertTrue(report.rawAccountingStatus.hasPrefix("UNBOUND:"), "topology cannot invent historical raw-origin credit")
        for row in report.source.dispatches.keys {
            let accounts = report.accounts.filter { $0.origin.row == row }
            XCTAssertEqual(accounts.count, 11, "all ten original case ordinals plus frozen default remain distinct")
            for pair in [(1, 6), (3, 7), (4, 8), (5, 9)] {
                let first = try XCTUnwrap(accounts.first { $0.origin.role == .tableCase(pair.0) })
                let second = try XCTUnwrap(accounts.first { $0.origin.role == .tableCase(pair.1) })
                XCTAssertEqual(first.origin.edge, second.origin.edge)
                XCTAssertFalse(first.routeIndices.isEmpty)
                XCTAssertEqual(first.routeIndices, second.routeIndices,
                               "same-target case roles must remain jointly possible, not guessed from numeric observations")
                for index in first.routeIndices {
                    XCTAssertTrue(report.routes[index].origins.contains(first.origin))
                    XCTAssertTrue(report.routes[index].origins.contains(second.origin))
                }
            }
        }
    }

    @discardableResult
    private func requireTopologyRefusal(_ original: C.Program, source: L.Source, span: C.Span,
                                        replacement: String, name: String,
                                        expectedGap: String = "unmapped-source-route") throws -> L.Report {
        // Parse/type/envelope failures do not count as this observer's kill.
        let changed = try C.Program(lines: replacing(original, span, replacement), contract: original.contract)
        let report = try L.analyze(candidate: changed, source: source)
        XCTAssertTrue(report.gaps.contains { $0.kind == expectedGap }, name)
        XCTAssertTrue(report.accounts.contains { $0.disposition == .unresolved }, name)
        do {
            try report.requireCompleteTopology()
            XCTFail("\(name): incorrect dispatch received complete topology")
        } catch let C.Failure.invalidContract(message) {
            XCTAssertTrue(message.hasPrefix("SOURCE_EDGE_COVERAGE_GAP:"), name)
        }
        return report
    }

    private func text(_ program: C.Program, _ span: C.Span) throws -> String {
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line else { throw C.Failure.invalidContract("predicate witness crosses lines") }
        let bytes = Array(program.lines.map(\.text).joined(separator: "\n").utf8)
        return String(decoding: bytes[first.byteOffset..<(last.byteOffset + last.text.utf8.count)], as: UTF8.self)
    }

    private func replacing(_ program: C.Program, _ span: C.Span, _ replacement: String) throws -> [C.TextLine] {
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line, !replacement.contains("\n") else {
            throw C.Failure.invalidContract("predicate mutation must preserve actual source lines")
        }
        let index = first.line - 1, line = program.lines[index]
        guard line.envelope == .body, let address = line.source,
              let row = program.contract.rowsByAddress[address],
              row != program.contract.terminalRow, program.contract.exterior[row] == nil,
              program.contract.calls[row] == nil else {
            throw C.Failure.invalidContract("predicate mutation touches protected envelope or payload")
        }
        let offset = program.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(line.text.utf8)
        bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset + last.text.utf8.count - offset),
                              with: replacement.utf8)
        var lines = program.lines
        lines[index] = .init(text: String(decoding: bytes, as: UTF8.self), source: address, envelope: line.envelope)
        return lines
    }
}

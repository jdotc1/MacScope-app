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

/// Distinct ordinary-era obligation, not a replay of a rejected-dialect selector.
/// Each selector audits full typed output, then runs one new full-entry scenario
/// on the certified opaque derivative. Observations are actual parsed scalar commits, not
/// load-event proxies or register names inferred from identifier spelling.
/// SOURCE_ONLY / NOT_RUN until its own first focused execution is recorded.
final class OrdinaryCRestoredRegisterCommitTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias Source = RegionalCallOracle

    func testUp3ae18LateCallbackRestoresEveryParsedRegisterCommit() throws {
        try check(.jinit)
    }

    func testUp123b774LateCallbackRestoresEveryParsedRegisterCommit() throws {
        try check(.j12init)
    }

    private struct Destination {
        let register: Int
        let lhs: C.Expression
        let name: String
    }

    private struct Restore {
        let row: Int
        let destinations: [Destination]
        let right: [C.Expression]
        let hasWriteback: Bool
    }

    private func check(_ seed: RegionalCallSeed) throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        let audit = try OrdinaryCOutputAudit.analyze(document: fixtures.full.document,
            function: fixtures.full.function, baselineText: fixtures.full.baselineText)
        guard audit.errors.isEmpty,
              !audit.tokens.contains(where: { $0.text.hasPrefix("rgn_regional_") }) else {
            throw C.Failure.unsupportedSyntax("RESTORE_COMMIT_ORDINARY_PREREQUISITE: \(audit.errors.joined(separator: "; "))")
        }
        let contract = try C.contract(for: fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try Source.Program(rows: fixture.rows, function: fixture.function)

        // Freeze the correspondence before either execution. Exact original
        // exterior ownership and LDP tuple order, not value matching or spelling,
        // bind each candidate lhs span to its decoded architectural destination.
        let restores = try bindRestores(candidate, source: source, seed: seed)
        let scenario = try lateCallbackScenario(seed)
        let expected = try Source.Machine(program: source, scenario: scenario).run()
        let actual = try C.Machine(program: candidate,
            scenario: C.scenario(scenario, contract: contract)).run()
        try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
            returned: expected.returned, terminal: expected.returnBits,
            contract: contract, name: scenario.name)
        XCTAssertNil(expected.returnBits, "the original upsampler terminal remains void")
        XCTAssertEqual(actual.consumedResponses, scenario.responses.count,
            "the complete shared ordered K script must be consumed")
        XCTAssertEqual(expected.calls.map(\.row), scenario.responses.map(\.row))
        try compareRestores(actual, expected: expected, restores: restores, name: scenario.name)

        // Every saved register differs from its entry snapshot. This fixture
        // therefore distinguishes current stack memory from cached entry values;
        // the source's SP writeback must still recover the original high address.
        for register in 19...30 {
            XCTAssertNotEqual(try XCTUnwrap(expected.finalRegisters[register]),
                try XCTUnwrap(scenario.registers[register]), "new callback sentinel for register \(register)")
        }
        XCTAssertEqual(expected.finalRegisters[31], scenario.registers[31])

        // Both actual restore loads and SP writeback are immutable exterior
        // payloads. A numerical text mutant cannot pass the original contract.
        // These real-corpus controls establish only exact-payload sensitivity;
        // they are NOT parse/return numerical mutation kills. Never weaken the
        // contract, modify a source-result record, or fake an executed commit.
        try rejectProtectedRestoreMutation(candidate, restore: try XCTUnwrap(restores.first), rhs: 0)
        let writeback = try XCTUnwrap(restores.first(where: \.hasWriteback))
        try rejectProtectedRestoreMutation(candidate, restore: writeback, rhs: writeback.right.count - 1)
    }

    private func lateCallbackScenario(_ seed: RegionalCallSeed) throws -> Source.Scenario {
        // New full-entry input: two completed buffer callbacks overwrite all
        // saved slots twice, then late partial stores cross saved-slot boundaries.
        // No source row, decoded instruction, call payload or terminal is changed.
        let stack: UInt64 = 0x0000_0004_0080_0000
        let frame = stack - 0x60
        let callback = seed == .jinit ? 192 : 136
        return try Source.UpsamplerScenarios.make(seed: seed,
            name: "ordinary-late-two-callback-all-restores-overlapping-high-stack",
            paths: [.h2v1, .h2v1], allocate: true, simdResults: [0, 1], change: { scenario in
                scenario.registers[31] = stack
                for register in 19...30 {
                    scenario.registers[register] = 0x9345_6789_abcd_0000 | UInt64(register)
                }
                let callbacks = scenario.responses.indices.filter { scenario.responses[$0].row == callback }
                guard callbacks.count == 2, callbacks.last == scenario.responses.indices.last else {
                    throw C.Failure.invalidContract("new restore scenario requires exactly two buffer callbacks, the second last in K")
                }
                for (occurrence, responseIndex) in callbacks.enumerated() {
                    let pattern: UInt64 = occurrence == 0 ? 0x8123_4567_89ab_c000 : 0xfedc_ba98_7654_1000
                    scenario.responses[responseIndex].writes = (0..<12).map { slot in
                        .init(address: frame + UInt64(slot * 8), bytes: 8, bits: pattern | UInt64(slot))
                    }
                }
                let last = callbacks[1]
                scenario.responses[last].writes += [
                    .init(address: frame + 7, bytes: 4, bits: 0x89ab_cdef),
                    .init(address: frame + 0x2f, bytes: 2, bits: 0x8123),
                    .init(address: frame + 0x5f, bytes: 1, bits: 0x93)
                ]
            })
    }

    private func bindRestores(_ candidate: C.Program, source: Source.Program,
                              seed: RegionalCallSeed) throws -> [Restore] {
        let assignments = assignmentStatements(candidate.root)
        var restores: [Restore] = []
        for row in seed.suffixStart..<(seed.rowCount - 1) {
            guard case let .memory(op, registers, address) = source.code[row], op == "ldp",
                  registers.count == 2, registers.allSatisfy({ $0.width == 64 && !$0.zero }),
                  address.base.index == 31, address.base.width == 64,
                  candidate.contract.exterior[row] != nil else {
                throw C.Failure.invalidContract("original restore tuple or immutable ownership missing at row \(row)")
            }
            let matching = assignments.filter { (try? candidate.row(at: $0.span)) == row }
            guard matching.count == 1, case let .assign(left, right) = matching[0].node else {
                throw C.Failure.invalidContract("unique actual parsed restore assignment missing at row \(row)")
            }
            var architectural = registers.map(\.index)
            let writeback = address.update != .none
            if writeback { architectural.append(address.base.index) }
            guard left.count == architectural.count, right.count == architectural.count else {
                throw C.Failure.invalidContract("actual restore tuple arity differs at row \(row)")
            }
            var destinations: [Destination] = []
            for (ordinal, lhs) in left.enumerated() {
                guard case let .name(name) = lhs.node,
                      candidate.symbols[name]?.type == .u64,
                      try candidate.row(at: lhs.span) == row else {
                    throw C.Failure.invalidContract("restore destination is not a source-owned uint64 scalar")
                }
                if ordinal < registers.count {
                    guard case let .load(type, _) = right[ordinal].node, type == .u64,
                          candidate.memorySites[right[ordinal].span] == C.SourceSite(row: row, effectOrdinal: ordinal) else {
                        throw C.Failure.invalidContract("actual restore RHS does not own the original ordered load")
                    }
                } else {
                    guard candidate.expressionTypes[right[ordinal].span] == .u64 else {
                        throw C.Failure.invalidContract("SP writeback lacks original uint64 representation")
                    }
                }
                destinations.append(.init(register: architectural[ordinal], lhs: lhs, name: name))
            }
            restores.append(.init(row: row, destinations: destinations, right: right, hasWriteback: writeback))
        }
        let destinations = restores.flatMap(\.destinations)
        guard restores.count == 6, restores.filter(\.hasWriteback).count == 1,
              destinations.count == 13, Set(destinations.map(\.register)) == Set(19...31),
              Set(destinations.map(\.name)).count == destinations.count else {
            throw C.Failure.invalidContract("the six original restores must uniquely own twelve GPRs and SP writeback")
        }
        return restores
    }

    private func compareRestores(_ actual: C.Result, expected: Source.Result,
                                 restores: [Restore], name: String) throws {
        let rows = Set(restores.map(\.row))
        let suffixCommits = actual.commits.filter { $0.sourceRow.map(rows.contains) == true }
        let destinations = restores.flatMap(\.destinations)
        let orderedRows = restores.flatMap { restore in restore.destinations.map { _ in Optional(restore.row) } }
        guard suffixCommits.count == destinations.count,
              suffixCommits.map(\.sourceRow) == orderedRows,
              suffixCommits.map(\.span) == destinations.map({ $0.lhs.span }),
              suffixCommits.map(\.name) == destinations.map(\.name) else {
            throw C.Failure.semanticMismatch("RESTORED_REGISTER_COMMIT: \(name), complete suffix commit count/order differs")
        }
        for restore in restores {
            guard expected.rowVisits[restore.row] == 1 else {
                throw C.Failure.invalidContract("new full-entry scenario must visit each original restore exactly once")
            }
            let commits = actual.commits.filter { $0.sourceRow == restore.row }
            guard commits.count == restore.destinations.count,
                  commits.map(\.span) == restore.destinations.map({ $0.lhs.span }),
                  commits.map(\.name) == restore.destinations.map(\.name),
                  commits.allSatisfy({ $0.value.type == .u64 }) else {
                throw C.Failure.semanticMismatch("RESTORED_REGISTER_COMMIT: \(name), row \(restore.row), missing/duplicated/reordered actual destination commits")
            }
            for (ordinal, destination) in restore.destinations.enumerated() {
                guard let sourceBits = expected.finalRegisters[destination.register] else {
                    throw C.Failure.invalidContract("decoded source lacks final restored register \(destination.register)")
                }
                guard commits[ordinal].value.bits == sourceBits else {
                    throw C.Failure.semanticMismatch("RESTORED_REGISTER_COMMIT: \(name), row \(restore.row), destination \(ordinal), decoded register \(destination.register)")
                }
            }
        }
    }

    private func rejectProtectedRestoreMutation(_ original: C.Program, restore: Restore, rhs: Int) throws {
        // Change one actual parsed RHS in the complete real candidate. Keep the
        // original source tag and immutable contract, including all calls/return.
        let changed = try replacing(original, span: restore.right[rhs].span, with: "(uint64_t)(0x0)")
        do {
            _ = try C.Program(lines: changed, contract: original.contract)
            XCTFail("RESTORE_EXACT_PAYLOAD_REJECTION: changed restore row \(restore.row) was admitted")
        } catch let C.Failure.invalidContract(reason) {
            XCTAssertEqual(reason, "missing/duplicated protected row \(restore.row)",
                "RESTORE_EXACT_PAYLOAD_REJECTION must be the exact exterior guard, not another parser failure")
        } catch {
            XCTFail("RESTORE_EXACT_PAYLOAD_REJECTION: wrong failure category: \(error)")
        }
    }

    private func replacing(_ program: C.Program, span: C.Span, with text: String) throws -> [C.TextLine] {
        guard span.first < span.last, program.tokens.indices.contains(span.first),
              program.tokens.indices.contains(span.last - 1) else {
            throw C.Failure.invalidContract("invalid actual restore RHS span")
        }
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line else { throw C.Failure.invalidContract("restore RHS must occupy one actual line") }
        let index = first.line - 1
        let offset = program.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(program.lines[index].text.utf8)
        bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset - offset + last.text.utf8.count), with: text.utf8)
        var lines = program.lines
        lines[index] = .init(text: String(decoding: bytes, as: UTF8.self),
                            source: lines[index].source, envelope: lines[index].envelope)
        return lines
    }

    private func assignmentStatements(_ root: C.Statement) -> [C.Statement] {
        var result: [C.Statement] = []
        func walk(_ statement: C.Statement) {
            switch statement.node {
            case .assign: result.append(statement)
            case let .compound(_, body): body.forEach(walk)
            case let .conditional(_, yes, no): walk(yes); if let no { walk(no) }
            case let .whileLoop(_, body), let .doLoop(body, _), let .label(_, body): walk(body)
            case let .forLoop(initial, _, step, body):
                if let initial { walk(initial) }; walk(body); if let step { walk(step) }
            default: break
            }
        }
        walk(root)
        return result
    }
}

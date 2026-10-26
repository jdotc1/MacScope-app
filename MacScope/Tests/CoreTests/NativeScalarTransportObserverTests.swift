import Foundation
import XCTest

/// Real 0x3854 observer regression. Static certificate refusals and the
/// normal-completing wrong-formal numerical control are reported separately.
final class NativeScalarTransportObserverTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias N = NativeScalarNoCallContract
    private typealias A = NativeScalarSourceAnchors
    private typealias L = OrdinaryCSourceEdgeLedger
    private typealias O = NativeScalarScalarOracle

    private func replacing(_ program: C.Program, span: C.Span, with replacement: String,
                           manifest: N.FrozenManifest) throws -> C.Program {
        guard span.first < span.last, program.tokens.indices.contains(span.first),
              program.tokens.indices.contains(span.last - 1) else {
            throw C.Failure.invalidContract("transport mutation has no exact expression span")
        }
        let first = program.tokens[span.first], last = program.tokens[span.last - 1], index = first.line - 1
        guard first.line == last.line, program.lines.indices.contains(index),
              program.lines[index].envelope == .body, program.lines[index].source != nil else {
            throw C.Failure.invalidContract("transport mutation leaves one original body line")
        }
        let offset = program.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
        let range = (first.byteOffset - offset)..<(last.byteOffset + last.text.utf8.count - offset)
        var bytes = Array(program.lines[index].text.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw C.Failure.invalidContract("transport mutation has an invalid byte range")
        }
        bytes.replaceSubrange(range, with: replacement.utf8)
        var lines = program.lines
        lines[index] = .init(text: String(decoding: bytes, as: UTF8.self),
            source: lines[index].source, envelope: lines[index].envelope)
        // A parser/type failure is not the requested certificate refusal.
        let result = try N.program(lines: lines, manifest: manifest)
        guard result.memorySites.count == program.memorySites.count,
              Set(result.memorySites.values) == Set(program.memorySites.values),
              result.symbols.mapValues(\.type) == program.symbols.mapValues(\.type),
              result.code.count == program.code.count else {
            throw C.Failure.invalidContract("transport mutation changed another effect or storage type")
        }
        return result
    }

    func testOriginal3854ABITransportsRetainWidthSourceAndEntryPhase() throws {
        let fixture = try NativeScalarFixture.make(.interleavedRGB8)
        let bound = try NativeScalarOriginalBindings.make(fixture)
        try O.validateOriginal(fixture, bound: bound)
        let program = try N.program(lines: fixture.textLines, manifest: bound.manifest)
        let anchors = try A.make(candidate: program, inventory: bound.inventory)
        let topology = try L.analyzeNativeScalar(anchors)
        try topology.requireCompleteTopology()
        func formal(_ register: Int) throws -> String {
            let matches = bound.inputs.filter { $0.register == register }
            XCTAssertEqual(matches.count, 1)
            return try XCTUnwrap(matches.first?.parameter.name)
        }
        let arg1 = try formal(1), arg3 = try formal(3), arg4 = try formal(4)
        func copy(_ name: String) throws -> (C.Expression, String) {
            let matches = anchors.administrativeCopies.compactMap { pc -> (C.Expression, String)? in
                guard (try? program.row(at: program.code[pc].span)) == 2,
                      case let .assign(left, right) = program.code[pc].node,
                      left.count == 1, right.count == 1, case let .name(destination) = left[0].node,
                      case let .cast(_, child) = right[0].node,
                      case let .name(sourceName) = child.node, sourceName == name else { return nil }
                return (right[0], destination)
            }
            XCTAssertEqual(matches.count, 1)
            return try XCTUnwrap(matches.first)
        }
        let pointer = try copy(arg1), index = try copy(arg3)
        for (expression, replacement) in [
            (pointer.0, "(uint32_t)(\(arg1))"),
            (pointer.0, "(int64_t)(\(arg1))"),
            (pointer.0, "(uint64_t)((uint64_t)(\(arg1)))"),
            (pointer.0, "(uint64_t)(\(arg1) + (int64_t)(0))"),
            (pointer.0, "(uint64_t)(\(pointer.1))"),
            // Signed32 -> unsigned64 is an extension, not a representation copy.
            (pointer.0, "(uint64_t)(\(arg3))"),
            (pointer.0, "(uint64_t)((int64_t)(\(arg3)))"),
            // Explicit unsigned32 -> unsigned64 zero extension also stays out.
            (pointer.0, "(uint64_t)((uint32_t)(\(arg3)))")
        ] {
            let mutant = try replacing(program, span: expression.span, with: replacement, manifest: bound.manifest)
            XCTAssertThrowsError(try A.make(candidate: mutant, inventory: bound.inventory)) { error in
                guard case let C.Failure.invalidContract(reason) = error else { return XCTFail("not a certificate refusal: \(error)") }
                XCTAssertEqual(reason, "administrative edge operation is not one pure exact-type name transport")
            }
        }
        let backedgeCopies = anchors.administrativeCopies.filter {
            (try? program.row(at: program.code[$0].span)) == 24
        }
        XCTAssertEqual(backedgeCopies.count, 1)
        let backedge = program.code[try XCTUnwrap(backedgeCopies.first)]
        guard case let .assign(_, right) = backedge.node, right.count == 1 else {
            throw C.Failure.invalidContract("real outer backedge copy disappeared")
        }
        let nonEntry = try replacing(program, span: right[0].span,
            with: "(uint32_t)(\(arg4))", manifest: bound.manifest)
        XCTAssertThrowsError(try A.make(candidate: nonEntry, inventory: bound.inventory)) { error in
            guard case let C.Failure.invalidContract(reason) = error else { return XCTFail("not a certificate refusal: \(error)") }
            XCTAssertEqual(reason, "signed ABI representation transport is not on an acyclic entry edge")
        }

        // Same-width wrong-formal transport is deliberately shape-valid. Its
        // failure must come from actual committed source values, not a name bank.
        let scenario = O.Scenario(width: 0, rows: 2, index: 7)
        let expected = try O.reference(scenario, seed: .interleavedRGB8)
        let input = try N.scenario(name: "wrong W3 entry formal, zero-width two-row path",
            inputs: bound.candidateInputs(originalGPRValues: scenario.physical),
            memory: scenario.memory, manifest: bound.manifest)
        func committedIndex(_ result: C.Result, program: C.Program, anchors: A.Certificate) throws -> [UInt64] {
            let pcs = anchors.operations.filter { $0.value.row == 21 && $0.value.kind == .scalarDefinition }.map(\.key)
            guard pcs.count == 1, case let .assign(left, _) = program.code[pcs[0]].node,
                  left.count == 1, case let .name(name) = left[0].node,
                  program.symbols[name]?.type == .u32 else {
                throw C.Failure.invalidContract("original W3 ADD lacks its unique typed source commit")
            }
            let commits = result.commits.filter { $0.span == left[0].span }
            guard commits.allSatisfy({ $0.sourceRow == 21 && $0.name == name && $0.value.type == .u32 }) else {
                throw C.Failure.invalidContract("source W3 commit binding changed")
            }
            return commits.map { $0.value.bits }
        }
        let actual = try C.Machine(program: program, scenario: input).run()
        try N.requireTerminal(actual, manifest: bound.manifest)
        XCTAssertEqual(actual.events, expected.events)
        XCTAssertEqual(actual.memory, expected.memory)
        let expectedIndex = expected.writes.filter { $0.row == 21 && $0.slot == 0 }.map(\.bits)
        func requireIndexEquivalence(_ values: [UInt64]) throws {
            guard values == expectedIndex else {
                throw C.Failure.semanticMismatch("wrong source value in original W3 committed writes")
            }
        }
        try requireIndexEquivalence(committedIndex(actual, program: program, anchors: anchors))
        _ = try L.observe(topology, candidate: program, actual: actual,
            referenceBranches: expected.branches, referenceRowVisits: expected.rowVisits,
            referenceReturned: expected.returned, name: "unchanged transport control")
        let wrong = try replacing(program, span: index.0.span, with: "(uint32_t)(\(arg4))", manifest: bound.manifest)
        let wrongAnchors = try A.make(candidate: wrong, inventory: bound.inventory)
        let wrongTopology = try L.analyzeNativeScalar(wrongAnchors)
        let changed = try C.Machine(program: wrong, scenario: input).run()
        try N.requireTerminal(changed, manifest: bound.manifest)
        XCTAssertEqual(changed.events, expected.events)
        XCTAssertEqual(changed.memory, expected.memory)
        _ = try L.observe(wrongTopology, candidate: wrong, actual: changed,
            referenceBranches: expected.branches, referenceRowVisits: expected.rowVisits,
            referenceReturned: expected.returned, name: "wrong-formal same control path")
        let changedIndex = try committedIndex(changed, program: wrong, anchors: wrongAnchors)
        XCTAssertEqual(changedIndex, [3, 4])
        XCTAssertEqual(expectedIndex, [8, 9])
        XCTAssertNotEqual(changedIndex, expectedIndex, "wrong source is a normally completed numerical source-write mismatch")
        XCTAssertThrowsError(try requireIndexEquivalence(changedIndex)) { error in
            guard case let C.Failure.semanticMismatch(reason) = error else {
                return XCTFail("parse/type/fuel/ownership refusal is not a wrong-source numerical kill: \(error)")
            }
            XCTAssertEqual(reason, "wrong source value in original W3 committed writes")
        }
    }

    func testOriginal3704SXTWRequiresExactDestinationAndWriterExpression() throws {
        // Excluded native subject: real refusal and exact captured39a output assertions.
        // The original contract remains preserved evidence, not numerical PASS credit.
        let fixture = try RegionalSchema2Bindings39A.make(function: "_null_convert", start: 0x3704)
        try ExcludedNullFallback39A.requireCaptured(fixture)
    }
}

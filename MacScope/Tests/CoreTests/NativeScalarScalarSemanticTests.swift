import Foundation
import XCTest

/// New exact3854/3704 numerical selectors, separate from presentation RED and
/// unchanged historical tests. Literal reference math never sees candidate names.
/// SOURCE ONLY / NOT RUN until the parent's frozen selectors are executed.
final class NativeScalarScalarSemanticTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias N = NativeScalarNoCallContract
    private typealias O = NativeScalarScalarOracle
    private typealias A = NativeScalarSourceAnchors
    private typealias L = OrdinaryCSourceEdgeLedger
    private struct Slot {
        let row: Int
        let ordinal: Int
        let width: Int
        let span: C.Span
        let name: String
    }
    private struct Prepared {
        let seed: NativeScalarSeed
        let bound: NativeScalarOriginalBindings.Bound
        let program: C.Program
        let topology: L.Report
        let slots: [C.Span: Slot]
        let copies: Set<C.Span>
    }
    private func prepare(_ seed: NativeScalarSeed) throws -> Prepared {
        let fixture = try NativeScalarFixture.make(seed)
        let bound = try NativeScalarOriginalBindings.make(fixture)
        try O.validateOriginal(fixture, bound: bound)
        let program = try N.program(lines: fixture.textLines, manifest: bound.manifest)
        let anchors = try A.make(candidate: program, inventory: bound.inventory)
        let topology = try L.analyzeNativeScalar(anchors)
        try topology.requireCompleteTopology()
        var slots: [C.Span: Slot] = [:], copies: Set<C.Span> = []
        for (pc, operation) in anchors.operations {
            switch operation.kind {
            case .load, .scalarDefinition, .writeback:
                guard case let .assign(left, right) = program.code[pc].node,
                      left.count == 1, right.count == 1, case let .name(name) = left[0].node,
                      let symbol = program.symbols[name], !symbol.external, !symbol.type.pointer, symbol.type.unsigned else {
                    throw C.Failure.invalidContract("source write slot lacks an actual unsigned native assignment")
                }
                let access = try NativeScalarOriginalBindings.literalAccess(fixture.rows[operation.row])
                let width: Int
                if operation.kind == .writeback {
                    guard let write = access.writes.last else { throw C.Failure.invalidContract("writeback slot has no original destination") }
                    width = write.width
                } else {
                    let index = operation.kind == .load ? operation.ordinal : 0
                    guard access.writes.indices.contains(index) else { throw C.Failure.invalidContract("source write ordinal has no original destination") }
                    width = access.writes[index].width
                }
                let narrowLoad = operation.kind == .load && width == 32 &&
                    bound.inventory.memoryEffects[operation.row]?[operation.ordinal].bytes == symbol.type.width / 8
                guard symbol.type.width == width || (narrowLoad && [8, 16].contains(symbol.type.width)),
                      slots[left[0].span] == nil else {
                    throw C.Failure.invalidContract("source write representation loses committed bits or duplicates its actual site")
                }
                slots[left[0].span] = .init(row: operation.row, ordinal: operation.ordinal,
                    width: width, span: left[0].span, name: name)
            case .store, .condition, .terminal: break
            }
        }
        for pc in anchors.administrativeCopies {
            guard case let .assign(left, _) = program.code[pc].node, left.count == 1 else {
                throw C.Failure.invalidContract("lost actual edge-copy assignment")
            }
            copies.insert(left[0].span)
        }
        return .init(seed: seed, bound: bound, program: program, topology: topology, slots: slots, copies: copies)
    }
    private func writes(_ actual: C.Result, prepared: Prepared) throws -> [O.Write] {
        var result: [O.Write] = []
        for commit in actual.commits {
            if let slot = prepared.slots[commit.span] {
                guard commit.sourceRow == slot.row, commit.name == slot.name, commit.value.type.unsigned,
                      commit.value.type.width <= slot.width else {
                    throw C.Failure.invalidContract("actual commit contradicts its independently bound source slot")
                }
                // A uint8/16 load is zero-extended to its original W32 write.
                // Do not require a synthetic physical uint64 storage variable.
                result.append(.init(row: slot.row, slot: slot.ordinal, width: slot.width, bits: commit.value.bits))
            } else if !prepared.copies.contains(commit.span) {
                throw C.Failure.invalidContract("actual scalar definition is neither an original write nor an edge-owned transport")
            }
        }
        return result
    }
    private func compare(_ scenario: O.Scenario, prepared: Prepared,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        // Static ownership, exact external names/types and terminal contract are
        // fixed before either numerical evaluation. Neither side seeds locals.
        let expected = try O.reference(scenario, seed: prepared.seed)
        let input = try N.scenario(name: scenario.label,
            inputs: prepared.bound.candidateInputs(originalGPRValues: scenario.physical),
            memory: scenario.memory, manifest: prepared.bound.manifest)
        let actual = try C.Machine(program: prepared.program, scenario: input).run()
        try N.requireTerminal(actual, manifest: prepared.bound.manifest)
        XCTAssertEqual(actual.events, expected.events, scenario.label, file: file, line: line)
        XCTAssertEqual(actual.memory, expected.memory, scenario.label, file: file, line: line)
        XCTAssertEqual(try writes(actual, prepared: prepared), expected.writes, scenario.label, file: file, line: line)
        _ = try L.observe(prepared.topology, candidate: prepared.program, actual: actual,
            referenceBranches: expected.branches, referenceRowVisits: expected.rowVisits,
            referenceReturned: expected.returned, name: scenario.label)
        XCTAssertTrue(actual.returned, scenario.label, file: file, line: line)
        XCTAssertEqual(actual.unavailableTerminal, .unresolvedReturnContract, scenario.label, file: file, line: line)
        XCTAssertNil(actual.terminal, scenario.label, file: file, line: line)
    }

    func testOriginalExtrgbRGB8WholeEntryMatchesLiteralSourceAndNestedEdges() throws {
        let p = try prepare(.interleavedRGB8)
        for rows: UInt32 in [0, 1, 2, 0x8000_0000, 0xffff_ffff] {
            for width: UInt32 in [0, 1, 3] { try compare(.init(width: width, rows: rows), prepared: p) }
        }
        for alias in [O.Scenario.Alias.sameSample, .nextSample, .nextRowPointer, .addressWrap, .signedBoundary] {
            try compare(.init(width: 3, rows: 2, index: .max, alias: alias), prepared: p)
        }
    }
    func testOriginalNullRGB8AllArmsMatchLiteralSourceAndNestedEdges() throws {
        // Excluded native subject: real refusal and exact captured39a output assertions.
        // The original contract remains preserved evidence, not numerical PASS credit.
        let fixture = try RegionalSchema2Bindings39A.make(function: "_null_convert", start: 0x3704)
        try ExcludedNullFallback39A.requireCaptured(fixture)
    }
}

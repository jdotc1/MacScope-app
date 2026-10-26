import Foundation
import XCTest

/// New real-cohort selectors at original 0x30150 using the complete fresh main
/// fixture. No historical selector is changed or replayed. Setup/static binding
/// refusals are not numerical kills; these tests are unrun source until gated.
final class NativeScalarEntrySemanticTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias N = NativeScalarNoCallContract
    private typealias O = NativeScalarEntryOracle
    private typealias B = NativeScalarOriginalBindings
    private struct Prepared {
        let original: B.Bound
        let program: C.Program
        let binding: O.Binding
    }
    private func prepare() throws -> Prepared {
        let fixture = try NativeScalarFixture.make(.entryNoscale8)
        let original = try B.make(fixture)
        try O.validateOriginal(fixture, bound: original)
        let program = try N.program(lines: fixture.textLines, manifest: original.manifest)
        let binding = try O.bind(program, original: original)
        return .init(original: original, program: program, binding: binding)
    }
    private func input(count: UInt32, source: UInt64 = 0x8000_0001_0000_4000,
                       destination: UInt64 = 0x9000_0002_0000_6000) -> O.Input {
        var memory: [UInt64: UInt8] = [:]
        let words: [UInt32] = [0xa1b2_c3d4, 0x0102_037e, 0xfedc_ba09]
        for (index, word) in words.enumerated() {
            let address = source &+ UInt64(index * 4)
            for offset in 0..<4 { memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: word >> (offset * 8)) }
        }
        for offset in 0..<5 {
            let address = destination &+ UInt64(offset)
            if memory[address] == nil { memory[address] = 0x55 }
        }
        return .init(source: source, destination: destination, count: count, memory: memory)
    }
    private func scenario(_ input: O.Input, prepared: Prepared, name: String) throws -> C.Scenario {
        try N.scenario(name: name, inputs: prepared.original.candidateInputs(originalGPRValues: input.physical),
                       memory: input.memory, manifest: prepared.original.manifest)
    }
    private func complete(_ input: O.Input, prepared: Prepared, name: String,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        // All input and source-slot permissions were frozen before either run.
        let expected = try O.reference(input, finish: .returned)
        let actual = try C.Machine(program: prepared.program,
            scenario: scenario(input, prepared: prepared, name: name)).run()
        try N.requireTerminal(actual, manifest: prepared.original.manifest)
        XCTAssertEqual(actual.events, expected.events, name, file: file, line: line)
        XCTAssertEqual(actual.memory, expected.memory, name, file: file, line: line)
        XCTAssertEqual(try O.completeEdges(program: prepared.program, result: actual, binding: prepared.binding),
                       expected.edges, name, file: file, line: line)
        // This is a separate output-commit observation, not an input to either
        // numerical evaluator or a name/value heuristic for selecting a write.
        XCTAssertEqual(try O.observedWrites(actual, binding: prepared.binding), expected.writes,
                       name, file: file, line: line)
        XCTAssertNil(actual.terminal, name, file: file, line: line)
        XCTAssertEqual(actual.unavailableTerminal, .unresolvedReturnContract, name, file: file, line: line)
    }
    private func prefix(_ input: O.Input, prepared: Prepared, name: String,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try O.reference(input, finish: .backedges(2))
        let actual = try O.prefix(program: prepared.program,
            scenario: scenario(input, prepared: prepared, name: name), binding: prepared.binding)
        XCTAssertEqual(actual.edges, [O.backedge, O.backedge], name, file: file, line: line)
        XCTAssertEqual(actual.edges, expected.edges, name, file: file, line: line)
        XCTAssertEqual(actual.occurrence, 2, name, file: file, line: line)
        XCTAssertEqual(actual.stopPC, prepared.binding.header, name, file: file, line: line)
        XCTAssertEqual(actual.result.events, expected.events, name, file: file, line: line)
        XCTAssertEqual(actual.result.memory, expected.memory, name, file: file, line: line)
        XCTAssertEqual(try O.observedWrites(actual.result, binding: prepared.binding), expected.writes,
                       name, file: file, line: line)
        XCTAssertFalse(actual.result.returned, name, file: file, line: line)
        XCTAssertFalse(actual.result.reachedRegionBoundary, name, file: file, line: line)
        XCTAssertThrowsError(try N.requireTerminal(actual.result, manifest: prepared.original.manifest),
                             name, file: file, line: line)
    }

    func testOriginalNoscaleCountsOneTwoThreeMatchLiteralSource() throws {
        let p = try prepare()
        for count: UInt32 in [1, 2, 3] { try complete(input(count: count), prepared: p, name: "noscale count\(count), high pointers") }
    }
    func testOriginalNoscalePointerWrapAndSignedBoundaryMatchLiteralSource() throws {
        let p = try prepare()
        try complete(input(count: 3, source: UInt64.max - 3), prepared: p, name: "source writeback wraps64 between aligned loads")
        try complete(input(count: 3, destination: UInt64.max), prepared: p, name: "destination byte writeback wraps64")
        try complete(input(count: 3, source: UInt64(Int64.max) - 3), prepared: p, name: "source crosses signed64 boundary without narrowing")
    }
    func testOriginalNoscaleAliasingStoresAffectOnlySubsequentLoads() throws {
        let p = try prepare(), source: UInt64 = 0x8000_0001_0000_4000
        try complete(input(count: 3, source: source, destination: source), prepared: p, name: "equal source/destination values retain distinct roles")
        try complete(input(count: 3, source: source, destination: source &+ 4), prepared: p, name: "first byte store changes next load32")
    }
    func testOriginalNoscaleZeroAndHighCountsTakeTwoFullEntryBackedges() throws {
        let p = try prepare()
        for count: UInt32 in [0, 0x8000_0000, 0xffff_ffff] {
            try prefix(input(count: count), prepared: p, name: "W3=\(count), two actual original taken edges")
        }
    }
    func testOriginalNoscalePrefixPreservesWrappingAndAliasingOrder() throws {
        let p = try prepare()
        try prefix(input(count: 0, source: UInt64.max - 3, destination: UInt64.max), prepared: p,
                   name: "zero-count prefix with source/destination wrap and current-load alias")
        let source: UInt64 = 0x8000_0001_0000_4000
        try prefix(input(count: 0xffff_ffff, source: source, destination: source &+ 4), prepared: p,
                   name: "high-count prefix must reload the word changed by first store")
    }
    func testOriginalNoscalePrefixRejectsEarlyReturnAndFuelExhaustion() throws {
        let p = try prepare()
        for count: UInt32 in [1, 2] {
            let i = input(count: count)
            XCTAssertThrowsError(try O.reference(i, finish: .backedges(2)))
            XCTAssertThrowsError(try O.prefix(program: p.program,
                scenario: scenario(i, prepared: p, name: "too few taken edges"), binding: p.binding))
        }
        XCTAssertThrowsError(try O.prefix(program: p.program,
            scenario: scenario(input(count: 0), prepared: p, name: "fuel is failure"), binding: p.binding, fuel: 1)) { error in
            switch error {
            case C.Failure.fuelExhausted: break
            default: XCTFail("fuel failure acquired another classification: \(error)")
            }
        }
    }
}

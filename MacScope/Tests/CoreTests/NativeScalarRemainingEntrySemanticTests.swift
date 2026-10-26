import Foundation
import XCTest

/// New numerical inputs at four exact remaining entry sites, not relocated
/// authored fixtures. SOURCE_ONLY / NOT_RUN. Existing six original30150 selectors
/// and ten successful parser controls are neither changed nor replayed here.
final class NativeScalarRemainingEntrySemanticTests: XCTestCase {
    private typealias C = OrdinaryC
    private typealias N = NativeScalarNoCallContract
    private typealias E = NativeScalarEntryOracle
    private typealias O = NativeScalarRemainingEntryOracle
    private typealias B = NativeScalarOriginalBindings
    private struct Prepared {
        let site: O.Site
        let original: B.Bound
        let program: C.Program
        let binding: O.Binding
    }
    private func prepare(_ site: O.Site) throws -> Prepared {
        let seed: NativeScalarSeed
        switch site {
        case .downscale17c88: seed = .entryDownscale17c88
        case .upscale30134: seed = .entryUpscale30134
        case .noscale30630: seed = .entryNoscale30630
        case .noscale30b10: seed = .entryNoscale30b10
        }
        let fixture = try NativeScalarFixture.make(seed)
        let original = try B.make(fixture)
        try O.validateOriginal(fixture.capture, bound: original, site: site)
        let program = try N.program(lines: fixture.textLines, manifest: original.manifest)
        let binding = try O.bind(program, original: original, site: site)
        return .init(site: site, original: original, program: program, binding: binding)
    }
    private func input(_ site: O.Site, count: UInt32,
                       source: UInt64 = 0x8000_0001_0000_4000,
                       destination: UInt64 = 0x9000_0002_0000_6000,
                       shiftWord: UInt32 = 1, context: UInt64 = 0xa000_0003_0000_8000) -> O.Input {
        var memory: [UInt64: UInt8] = [:]
        let words: [UInt32] = site.loadBytes == 1 ? [0xe7, 0x83, 0x5d] : [0xa1b2_c3d4, 0x0102_037e, 0xfedc_ba09]
        for (index, word) in words.enumerated() {
            let address = source &+ UInt64(index * site.loadBytes)
            for offset in 0..<site.loadBytes {
                memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: word >> (offset * 8))
            }
        }
        if site.shifted {
            let address = context &+ site.shiftOffset
            for offset in 0..<4 {
                memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: shiftWord >> (offset * 8))
            }
        }
        for offset in 0..<(site.storeBytes * 3 + 2) {
            let address = destination &+ UInt64(offset)
            if memory[address] == nil { memory[address] = 0x55 }
        }
        return .init(source: source, destination: destination, count: count,
                     context: site.shifted ? context : nil, memory: memory)
    }
    private func scenario(_ input: O.Input, prepared: Prepared, name: String) throws -> C.Scenario {
        try N.scenario(name: name, inputs: prepared.original.candidateInputs(originalGPRValues: input.physical),
                       memory: input.memory, manifest: prepared.original.manifest)
    }
    @discardableResult
    private func complete(_ input: O.Input, prepared: Prepared, name: String,
                          file: StaticString = #filePath, line: UInt = #line) throws -> O.Reference {
        let expected = try O.reference(input, site: prepared.site, finish: .returned)
        let actual = try C.Machine(program: prepared.program,
            scenario: scenario(input, prepared: prepared, name: name)).run()
        try N.requireTerminal(actual, manifest: prepared.original.manifest)
        let edges = try O.completeEdges(program: prepared.program, result: actual, binding: prepared.binding)
        let writes = try O.observedWrites(actual, binding: prepared.binding)
        XCTAssertEqual(actual.events, expected.events, name, file: file, line: line)
        XCTAssertEqual(actual.memory, expected.memory, name, file: file, line: line)
        XCTAssertEqual(edges, expected.edges, name, file: file, line: line)
        XCTAssertEqual(writes, expected.writes, name, file: file, line: line)
        XCTAssertNil(actual.terminal, name, file: file, line: line)
        XCTAssertEqual(actual.unavailableTerminal, .unresolvedReturnContract, name, file: file, line: line)
        // A mutation may use this already-evaluated reference only after the
        // unchanged candidate has actually matched; no confidence rerun occurs.
        guard actual.events == expected.events, actual.memory == expected.memory,
              edges == expected.edges, writes == expected.writes else {
            throw C.Failure.semanticMismatch("unchanged entry candidate differs at " + name)
        }
        return expected
    }
    private func prefix(_ input: O.Input, prepared: Prepared, name: String,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try O.reference(input, site: prepared.site, finish: .backedges(2))
        let actual = try E.prefix(program: prepared.program,
            scenario: scenario(input, prepared: prepared, name: name), binding: prepared.binding.entry)
        XCTAssertEqual(actual.edges, expected.edges, name, file: file, line: line)
        XCTAssertEqual(actual.edges, [O.backedge, O.backedge], name, file: file, line: line)
        XCTAssertEqual(actual.occurrence, 2, name, file: file, line: line)
        XCTAssertEqual(actual.stopPC, prepared.binding.header, name, file: file, line: line)
        XCTAssertEqual(actual.result.events, expected.events, name, file: file, line: line)
        XCTAssertEqual(actual.result.memory, expected.memory, name, file: file, line: line)
        XCTAssertEqual(try O.observedWrites(actual.result, binding: prepared.binding), expected.writes,
                       name, file: file, line: line)
        XCTAssertFalse(actual.result.returned, name, file: file, line: line)
        XCTAssertFalse(actual.result.reachedRegionBoundary, name, file: file, line: line)
        XCTAssertNil(actual.result.terminal, name, file: file, line: line)
        XCTAssertNil(actual.result.unavailableTerminal, name, file: file, line: line)
        XCTAssertThrowsError(try N.requireTerminal(actual.result, manifest: prepared.original.manifest),
                             name, file: file, line: line)
    }
    private func countsAndStrideMutations(_ site: O.Site) throws {
        let p = try prepare(site)
        for count: UInt32 in [1, 2, 3] {
            let i = input(site, count: count), name = "\(site.label) count\(count), high pointers"
            let expected = try complete(i, prepared: p, name: name)
            if count == 3 {
                // Same input/reference; run only changed candidates after the
                // required original observation. Parse/ownership/UB/fuel failures
                // are never counted as numerical mutation kills.
                try requireStrideKills(input: i, prepared: p, expected: expected)
            }
        }
    }
    func testOriginalDownscale17c88CountsAndStrideMutations() throws {
        try countsAndStrideMutations(.downscale17c88)
    }
    func testOriginalUpscale30134CountsAndStrideMutations() throws {
        try countsAndStrideMutations(.upscale30134)
    }
    func testOriginalNoscale30630CountsAndStrideMutations() throws {
        try countsAndStrideMutations(.noscale30630)
    }
    func testOriginalNoscale30b10CountsAndStrideMutations() throws {
        try countsAndStrideMutations(.noscale30b10)
    }
    func testOriginalFourEntryPointerWrapAndAliasingOrder() throws {
        for site in O.Site.allCases {
            let p = try prepare(site), source: UInt64 = 0x8000_0001_0000_4000
            try complete(input(site, count: 3, source: UInt64.max - UInt64(site.loadBytes - 1)),
                         prepared: p, name: "\(site.label) source postindex wraps64 between aligned accesses")
            try complete(input(site, count: 3, destination: UInt64.max - UInt64(site.storeBytes - 1)),
                         prepared: p, name: "\(site.label) destination postindex wraps64 between accesses")
            try complete(input(site, count: 3, source: UInt64(Int64.max) - UInt64(site.loadBytes - 1)),
                         prepared: p, name: "\(site.label) source crosses signed64 boundary")
            try complete(input(site, count: 3, source: source, destination: source),
                         prepared: p, name: "\(site.label) equal pointer bits retain distinct roles and current load before store")
            try complete(input(site, count: 3, source: source, destination: source &+ UInt64(site.loadBytes)),
                         prepared: p, name: "\(site.label) store changes next source load")
        }
    }
    func testOriginalFourEntryZeroAndHighCountsHaveTwoFullBackedges() throws {
        for site in O.Site.allCases {
            let p = try prepare(site)
            for count: UInt32 in [0, 0x8000_0000, 0xffff_ffff] {
                try prefix(input(site, count: count), prepared: p,
                           name: "\(site.label) W3=\(count), two complete taken edges and modulo32 decrements")
            }
        }
    }
    func testOriginalFourEntryPrefixWrapAndAliasingOrder() throws {
        for site in O.Site.allCases {
            let p = try prepare(site), source: UInt64 = 0x8000_0001_0000_4000
            try prefix(input(site, count: 0, source: UInt64.max - UInt64(site.loadBytes - 1),
                             destination: UInt64.max - UInt64(site.storeBytes - 1)),
                       prepared: p, name: "\(site.label) zero-count prefix with pointer wrap and current-load alias")
            try prefix(input(site, count: 0xffff_ffff, source: source, destination: source &+ UInt64(site.loadBytes)),
                       prepared: p, name: "\(site.label) high-count prefix must reload bytes changed by first store")
        }
    }
    func testOriginalShiftedEntriesMaskWidthBoundaryShiftWords() throws {
        for site: O.Site in [.downscale17c88, .upscale30134] {
            let p = try prepare(site)
            for shiftWord: UInt32 in [0, 31, 32, 33, 0x8000_0001, 0xffff_ffff] {
                try complete(input(site, count: 3, shiftWord: shiftWord), prepared: p,
                             name: "\(site.label) shift word\(shiftWord), explicit W32 count mask and logical unsigned source")
            }
        }
    }
    func testOriginalShiftedEntriesReloadShiftWordAfterAliasingStore() throws {
        for site: O.Site in [.downscale17c88, .upscale30134] {
            let p = try prepare(site), context: UInt64 = 0xa000_0003_0000_8000
            let destination = context &+ site.shiftOffset
            try complete(input(site, count: 3, destination: destination, shiftWord: 1, context: context),
                         prepared: p, name: "\(site.label) byte store changes low shift-word byte before next reload")
            try prefix(input(site, count: 0, destination: destination, shiftWord: 1, context: context),
                       prepared: p, name: "\(site.label) zero-count shift-word alias prefix includes second current-memory reload")
        }
    }
    func testOriginalShiftedEntriesWrapContextAddressAt64Bits() throws {
        for site: O.Site in [.downscale17c88, .upscale30134] {
            let p = try prepare(site)
            try complete(input(site, count: 3, shiftWord: 33, context: 0 &- site.shiftOffset),
                         prepared: p, name: "\(site.label) context plus literal offset wraps to address0")
        }
    }
    func testOriginalFourEntryPrefixesRejectEarlyTerminalAndFuel() throws {
        for site in O.Site.allCases {
            let p = try prepare(site)
            for count: UInt32 in [1, 2] {
                let i = input(site, count: count)
                XCTAssertThrowsError(try O.reference(i, site: site, finish: .backedges(2)))
                XCTAssertThrowsError(try E.prefix(program: p.program,
                    scenario: scenario(i, prepared: p, name: "too few taken edges"), binding: p.binding.entry))
            }
            XCTAssertThrowsError(try E.prefix(program: p.program,
                scenario: scenario(input(site, count: 0), prepared: p, name: "fuel is failure"), binding: p.binding.entry, fuel: 1)) { error in
                switch error {
                case C.Failure.fuelExhausted: break
                default: XCTFail("fuel failure acquired another classification: \(error)")
                }
            }
        }
    }

    /// Two deliberately bounded numerical controls: source and destination
    /// writeback strides. Ownership is resolved before mutation from actual AST
    /// slots, not textual architectural names. No newly initialized local exists.
    private func requireStrideKills(input: O.Input, prepared p: Prepared, expected: O.Reference) throws {
        for (row, ordinal, delta) in [(0, 1, p.site.loadBytes), (p.site.storeRow, 0, p.site.storeBytes)] {
            let slots = p.binding.slots.filter { $0.row == row && $0.ordinal == ordinal }
            guard slots.count == 1, let slot = slots.first else { throw C.Failure.invalidContract("mutation missing frozen writeback slot") }
            let rhs: C.Expression
            switch p.program.code[slot.pc].node {
            case let .assign(_, values):
                guard values.count == 1 else { throw C.Failure.invalidContract("mutation writeback assignment is not scalar") }
                rhs = values[0]
            case let .declaration(_, value):
                guard let value else { throw C.Failure.invalidContract("mutation writeback is uninitialized") }
                rhs = value
            default: throw C.Failure.invalidContract("mutation gap: writeback is not a scalar RHS")
            }
            let additions = descendants(rhs).filter { expression in
                guard case let .binary(op, _, right) = expression.node, op == "+" else { return false }
                return literalBits(right) == UInt64(delta)
            }
            guard additions.count == 1, case let .binary(_, _, amount) = additions[0].node else {
                throw C.Failure.invalidContract("mutation gap: expected unique source-bound writeback delta")
            }
            let lines = try replacing(p.program, span: amount.span, with: "(uint64_t)0")
            let program = try N.program(lines: lines, manifest: p.original.manifest)
            let binding = try O.bind(program, original: p.original, site: p.site)
            let actual = try C.Machine(program: program,
                scenario: scenario(input, prepared: p, name: "zero writeback delta row\(row)")).run()
            try N.requireTerminal(actual, manifest: p.original.manifest)
            let edges = try O.completeEdges(program: program, result: actual, binding: binding)
            let writes = try O.observedWrites(actual, binding: binding)
            // Normal original terminal and edge count must remain valid. The
            // observed writeback and later actual memory address must differ.
            guard edges == expected.edges, writes != expected.writes,
                  actual.events != expected.events else {
                throw C.Failure.semanticMismatch("stride mutation survived at \(p.site.label) row\(row)")
            }
            let expectedAddresses = addresses(expected.events, row: row, loading: row == 0)
            let actualAddresses = addresses(actual.events, row: row, loading: row == 0)
            guard expectedAddresses.count == 3, actualAddresses.count == 3,
                  expectedAddresses[0] == actualAddresses[0], expectedAddresses[1] != actualAddresses[1] else {
                throw C.Failure.semanticMismatch("stride mutation lacks second-access address witness")
            }
        }
    }
    private func addresses(_ events: [C.Event], row: Int, loading: Bool) -> [UInt64] {
        events.compactMap { event in
            switch event {
            case let .load(site, _, address, _, _) where loading && site.row == row: return address
            case let .store(site, _, address, _, _) where !loading && site.row == row: return address
            default: return nil
            }
        }
    }
    private func descendants(_ expression: C.Expression) -> [C.Expression] {
        let children: [C.Expression]
        switch expression.node {
        case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): children = [e]
        case let .binary(_, a, b): children = [a, b]
        case let .select(c, a, b): children = [c, a, b]
        case let .helper(_, values): children = values
        default: children = []
        }
        return [expression] + children.flatMap(descendants)
    }
    private func literalBits(_ expression: C.Expression) -> UInt64? {
        switch expression.node {
        case let .literal(value): return value.bits
        case let .cast(_, child): return literalBits(child)
        default: return nil
        }
    }
    private func replacing(_ program: C.Program, span: C.Span, with replacement: String) throws -> [C.TextLine] {
        guard span.first < span.last, program.tokens.indices.contains(span.first),
              program.tokens.indices.contains(span.last - 1) else { throw C.Failure.invalidContract("mutation token span is invalid") }
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line, !replacement.contains("\n") else { throw C.Failure.invalidContract("mutation crosses statement lines") }
        let index = first.line - 1
        guard program.lines.indices.contains(index), program.lines[index].envelope == .body,
              let source = program.lines[index].source, let row = program.contract.rowsByAddress[source],
              row != program.contract.terminalRow else { throw C.Failure.invalidContract("mutation touches frozen envelope/terminal") }
        let offset = program.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
        let range = (first.byteOffset - offset)..<(last.byteOffset + last.text.utf8.count - offset)
        var bytes = Array(program.lines[index].text.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw C.Failure.invalidContract("mutation byte range is invalid") }
        bytes.replaceSubrange(range, with: replacement.utf8)
        var lines = program.lines
        lines[index] = .init(text: String(decoding: bytes, as: UTF8.self), source: source, envelope: .body)
        return lines
    }
}

import Foundation
import XCTest
@testable import MacScope

final class DarwinX86_64VariadicABITests: XCTestCase {
    private typealias X = DarwinX86_64Variadic

    /// The `va_arg` source each caller location must produce in the callee.
    private func expectedSource(_ location: X.CallLocation) -> X.VaArgSource {
        switch location {
        case let .gpr(index): .registerSaveArea(byteOffset: index * 8, byteCount: 8)
        case let .gprPair(first): .registerSaveArea(byteOffset: first * 8, byteCount: 16)
        case let .xmm(index): .registerSaveArea(byteOffset: 48 + index * 16, byteCount: 8)
        case let .stack(offset, count): .overflowArea(byteOffset: offset, byteCount: count)
        }
    }

    private func assertCalleeMirrorsCaller(
        namedGPRs: Int, namedVectorRegisters: Int, namedStackByteCount: UInt64 = 0, tail: [X.ArgumentClass],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let plan = try X.callPlan(namedGPRs: namedGPRs, namedVectorRegisters: namedVectorRegisters,
                                  namedStackByteCount: namedStackByteCount, tail: tail)
        var state = try X.VaListState(namedGPRs: namedGPRs, namedVectorRegisters: namedVectorRegisters,
                                      namedStackByteCount: namedStackByteCount)
        let sources = try tail.map { try state.next($0) }
        XCTAssertEqual(sources, plan.locations.map(expectedSource), file: file, line: line)
    }

    func testVaListIsTheTwentyFourByteSysVRecord() {
        XCTAssertEqual(X.vaListByteCount, 24)
        XCTAssertEqual(X.vaListAlignment, 8)
        XCTAssertEqual(X.vaListFields.map(\.name), ["gp_offset", "fp_offset", "overflow_arg_area", "reg_save_area"])
        XCTAssertEqual(X.vaListFields.map(\.byteOffset), [0, 4, 8, 16])
        XCTAssertEqual(X.vaListFields.map { $0.byteOffset + $0.byteCount }.last, X.vaListByteCount)
        XCTAssertEqual(X.registerSaveAreaByteCount, X.generalRegisterCount * 8 + X.vectorRegisterCount * 16)
        XCTAssertNotEqual(X.vaListByteCount, DarwinARM64Variadic.vaListByteCount)
    }

    func testPrintfTailUsesRegistersAndLongDoubleGoesToMemory() throws {
        let arguments = try XCTUnwrap(FormatStringParser.arguments(of: "%d %f %s %Lf %.3lf", flavor: .printf))
        let classes = arguments.map(X.argumentClass(of:))
        XCTAssertEqual(classes, [.integer, .sse, .integer, .x87, .sse])
        let plan = try X.callPlan(namedGPRs: 1, namedVectorRegisters: 0, tail: classes)
        XCTAssertEqual(plan.locations, [.gpr(index: 1), .xmm(index: 0), .gpr(index: 2),
                                        .stack(byteOffset: 0, byteCount: 16), .xmm(index: 1)])
        XCTAssertEqual(plan.vectorRegistersUsed, 2)
        XCTAssertEqual(plan.outgoingStackByteCount, 16)
        XCTAssertFalse(plan.admits(observedAL: 1))
        XCTAssertTrue(plan.admits(observedAL: 2))
        XCTAssertTrue(plan.admits(observedAL: 8))
        XCTAssertFalse(plan.admits(observedAL: 9))
    }

    func testALCountsNamedVectorArgumentsToo() throws {
        let plan = try X.callPlan(namedGPRs: 1, namedVectorRegisters: 1, tail: [.integer])
        XCTAssertEqual(plan.vectorRegistersUsed, 1)
        XCTAssertFalse(plan.admits(observedAL: 0))
        XCTAssertTrue(try X.callPlan(namedGPRs: 1, namedVectorRegisters: 0, tail: [.integer]).admits(observedAL: 0))
    }

    func testFieldWidthAndPrecisionArgumentsAreIntegers() throws {
        let arguments = try XCTUnwrap(FormatStringParser.arguments(of: "%*.*Lf %{public}Lf %lc", flavor: .osLog))
        XCTAssertEqual(arguments.map(X.argumentClass(of:)), [.integer, .integer, .x87, .x87, .integer])
    }

    func testAnArgumentThatDoesNotFitSpillsWholeAndLaterOnesStillUseRegisters() throws {
        let pair = try X.callPlan(namedGPRs: 5, namedVectorRegisters: 0, tail: [.integerPair, .integer, .integerPair])
        XCTAssertEqual(pair.locations, [.stack(byteOffset: 0, byteCount: 16), .gpr(index: 5),
                                        .stack(byteOffset: 16, byteCount: 16)])
        let sse = try X.callPlan(namedGPRs: 1, namedVectorRegisters: 0, tail: Array(repeating: .sse, count: 9))
        XCTAssertEqual(sse.locations.last, .stack(byteOffset: 0, byteCount: 8))
        XCTAssertEqual(sse.vectorRegistersUsed, 8)
        let stack = try X.callPlan(namedGPRs: 6, namedVectorRegisters: 0, tail: [.integer, .x87, .integer])
        XCTAssertEqual(stack.locations, [.stack(byteOffset: 0, byteCount: 8), .stack(byteOffset: 16, byteCount: 16),
                                         .stack(byteOffset: 32, byteCount: 8)])
        XCTAssertEqual(stack.outgoingStackByteCount, 40)
    }

    func testVaStartOffsetsFollowTheNamedPrefix() throws {
        let state = try X.VaListState(namedGPRs: 2, namedVectorRegisters: 3, namedStackByteCount: 12)
        XCTAssertEqual(state.gpOffset, 16)
        XCTAssertEqual(state.fpOffset, 48 + 48)
        XCTAssertEqual(state.overflowAreaByteOffset, 16)
        let full = try X.VaListState(namedGPRs: 6, namedVectorRegisters: 8)
        XCTAssertEqual([full.gpOffset, full.fpOffset], [48, 176])
    }

    func testCalleeVaArgMirrorsTheCallerLocations() throws {
        try assertCalleeMirrorsCaller(namedGPRs: 1, namedVectorRegisters: 0,
                                      tail: [.integer, .sse, .integer, .x87, .sse])
        try assertCalleeMirrorsCaller(namedGPRs: 5, namedVectorRegisters: 0, tail: [.integerPair, .integer, .integerPair])
        try assertCalleeMirrorsCaller(namedGPRs: 2, namedVectorRegisters: 7, namedStackByteCount: 8,
                                      tail: [.sse, .sse, .x87, .integer, .integer, .integer, .integer, .integer])
        try assertCalleeMirrorsCaller(namedGPRs: 0, namedVectorRegisters: 0,
                                      tail: Array(repeating: .integer, count: 7) + Array(repeating: .sse, count: 9))
    }

    /// Apple clang 21 (`-arch x86_64 -O0`, run under Rosetta) on this Mac: `va_list` state
    /// at `va_start` and after each `va_arg`, as `docs/abi/darwin-varargs/witness/varargs_witness.c`
    /// printed it (gp_offset, fp_offset, overflow_arg_area from the incoming argument area),
    /// and the `al` its `-O1` caller loads.
    func testAppleClangWitnessVaListStates() throws {
        struct Case {
            let gprs: Int, vectors: Int, stack: UInt64, tail: [X.ArgumentClass]
            let states: [[UInt64]], al: UInt8
        }
        let cases = [
            Case(gprs: 1, vectors: 0, stack: 0, tail: [.integer, .sse, .integer, .x87, .sse],
                 states: [[8, 48, 0], [16, 48, 0], [16, 64, 0], [24, 64, 0], [24, 64, 16], [24, 80, 16]], al: 2),
            Case(gprs: 6, vectors: 0, stack: 48, tail: [.integer], states: [[48, 48, 48], [48, 48, 56]], al: 0),
            Case(gprs: 1, vectors: 0, stack: 0, tail: [.integer, .integerPair, .integer, .integerPair],
                 states: [[8, 48, 0], [16, 48, 0], [32, 48, 0], [40, 48, 0], [40, 48, 16]], al: 0),
            Case(gprs: 5, vectors: 0, stack: 0, tail: [.integerPair, .integer, .integerPair],
                 states: [[40, 48, 0], [40, 48, 16], [48, 48, 16], [48, 48, 32]], al: 0),
            Case(gprs: 6, vectors: 0, stack: 8, tail: [.integer, .x87, .integer],
                 states: [[48, 48, 8], [48, 48, 16], [48, 48, 32], [48, 48, 40]], al: 0),
            Case(gprs: 1, vectors: 0, stack: 0, tail: [.integer, .integer, .sse, .integer],
                 states: [[8, 48, 0], [16, 48, 0], [24, 48, 0], [24, 64, 0], [32, 64, 0]], al: 1),
            Case(gprs: 1, vectors: 0, stack: 0, tail: Array(repeating: .sse, count: 9),
                 states: [[8, 48, 0]] + (1...8).map { [8, UInt64(48 + 16 * $0), 0] } + [[8, 176, 8]], al: 8),
            Case(gprs: 0, vectors: 1, stack: 0, tail: [.integer], states: [[0, 64, 0], [8, 64, 0]], al: 1),
        ]
        for (index, item) in cases.enumerated() {
            var state = try X.VaListState(namedGPRs: item.gprs, namedVectorRegisters: item.vectors,
                                          namedStackByteCount: item.stack)
            var observed = [[UInt64(state.gpOffset), UInt64(state.fpOffset), state.overflowAreaByteOffset]]
            for argumentClass in item.tail {
                _ = try state.next(argumentClass)
                observed.append([UInt64(state.gpOffset), UInt64(state.fpOffset), state.overflowAreaByteOffset])
            }
            XCTAssertEqual(observed, item.states, "case \(index)")
            let plan = try X.callPlan(namedGPRs: item.gprs, namedVectorRegisters: item.vectors,
                                      namedStackByteCount: item.stack, tail: item.tail)
            XCTAssertEqual(plan.vectorRegistersUsed, Int(item.al), "case \(index)")
            XCTAssertTrue(plan.admits(observedAL: item.al), "case \(index)")
        }
    }

    func testVaCopyIsIndependent() throws {
        var original = try X.VaListState(namedGPRs: 5, namedVectorRegisters: 0)
        var copy = original
        XCTAssertEqual(try original.next(.integer), .registerSaveArea(byteOffset: 40, byteCount: 8))
        XCTAssertEqual(try original.next(.integer), .overflowArea(byteOffset: 0, byteCount: 8))
        XCTAssertEqual(copy.gpOffset, 40)
        XCTAssertEqual(try copy.next(.integer), .registerSaveArea(byteOffset: 40, byteCount: 8))
    }

    func testMalformedNamedStateAndOversizedTailsAreRefused() {
        XCTAssertThrowsError(try X.callPlan(namedGPRs: 7, namedVectorRegisters: 0, tail: [])) {
            XCTAssertEqual($0 as? X.Fault, .invalidNamedState)
        }
        XCTAssertThrowsError(try X.VaListState(namedGPRs: 0, namedVectorRegisters: 9)) {
            XCTAssertEqual($0 as? X.Fault, .invalidNamedState)
        }
        XCTAssertThrowsError(try X.callPlan(namedGPRs: 0, namedVectorRegisters: 0,
                                            tail: Array(repeating: .integer, count: 65))) {
            XCTAssertEqual($0 as? X.Fault, .tooManyArguments)
        }
    }
}

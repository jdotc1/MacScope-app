import Foundation
import XCTest
@testable import MacScope

/// Apple arm64 call rules inside general vector regions (#661 audit): one test
/// per rule, each through `buildGeneralVectorRegion` on a small admitted CFG.
/// Post-call memory uses callee-saved x19 so only the rule under test decides.
final class D06RegionCallRulesTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        .init(address: address, bytes: "00000000", mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil)
    }

    private func decoded(_ word: UInt32, at address: UInt64, _ expected: String) -> InstructionRow {
        let bytes = withUnsafeBytes(of: word.littleEndian) { Data($0) }
        let item = ARM64Decoder().decode(bytes, baseAddress: address, maxInstructionCount: 1)[0]
        XCTAssertEqual("\(item.mnemonic) \(item.operands)", expected)
        return .init(address: address, bytes: item.byteText, mnemonic: item.mnemonic,
                     operands: item.operands, hasBreakpoint: false, comment: item.comment)
    }

    private func ld4(at address: UInt64) -> InstructionRow {
        decoded(0x4cdf_0500, at: address, "ld4 {v0.8h, v1.8h, v2.8h, v3.8h}, [x8], #64")
    }

    private func region(_ rows: [InstructionRow], file: StaticString = #filePath,
                        line: UInt = #line) throws -> MacIRFunction {
        try XCTUnwrap(MacIRBuilder().buildGeneralVectorRegion(name: "call_rules",
            startAddress: rows[0].address, rows: rows, initialState: BuilderState(),
            hasExternalFacts: false, isVariadic: false), "region refused", file: file, line: line)
    }

    private func operation(_ function: MacIRFunction, at address: UInt64) throws -> MacIROperation {
        try XCTUnwrap(function.instructions.last { $0.source.address == address }?.operation)
    }

    private func isUnknown(_ operation: MacIROperation) -> Bool {
        if case .unknown = operation { return true }
        return false
    }

    func testCallClobbersCallerSavedGPRsAndPreservesCalleeSaved() throws {
        func function(calls: Bool) throws -> MacIRFunction {
            try region([
                row(0x0, "cbz", "x2, 0x24"), ld4(at: 0x4),
                row(0x8, "mov", "x9, #0x5"), row(0xc, "mov", "x16, #0x6"),
                row(0x10, "mov", "x19, #0x7"),
                calls ? row(0x14, "bl", "_callee") : row(0x14, "nop", ""),
                row(0x18, "add", "x0, x9, x19"), row(0x1c, "add", "x1, x16, x19"),
                row(0x20, "ret", ""), row(0x24, "bl", "___stack_chk_fail"),
            ])
        }
        func reads(_ text: String, _ register: String, _ value: Int) -> Bool {
            // MacIR values describe as `x19_12` (SSA register) or `0x7` (immediate).
            text.contains("0x\(value)") || text.contains(" \(register)_")
        }
        let control = try function(calls: false)
        XCTAssertTrue(reads("\(try operation(control, at: 0x18))", "x9", 5), "control reads x9")
        XCTAssertTrue(reads("\(try operation(control, at: 0x1c))", "x16", 6), "control reads x16")
        let called = try function(calls: true)
        let first = "\(try operation(called, at: 0x18))"
        let second = "\(try operation(called, at: 0x1c))"
        XCTAssertFalse(reads(first, "x9", 5), first)
        XCTAssertFalse(reads(second, "x16", 6), second)
        XCTAssertTrue(reads(first, "x19", 7), "callee-saved x19 survives the call: \(first)")
    }

    func testCallInvalidatesFlagsBeforeConditionalBranch() throws {
        func branch(calls: Bool) throws -> String {
            let function = try region([
                row(0x0, "cbz", "x2, 0x1c"), ld4(at: 0x4),
                row(0x8, "cmp", "x1, #0x3"),
                calls ? row(0xc, "bl", "_callee") : row(0xc, "nop", ""),
                row(0x10, "b.eq", "0x18"), row(0x14, "mov", "x0, #0x1"),
                row(0x18, "ret", ""), row(0x1c, "bl", "___stack_chk_fail"),
            ])
            return "\(try operation(function, at: 0x10))"
        }
        func usesCompare(_ text: String) -> Bool {
            text.contains("0x3") || text.contains(" x1_")
        }
        let control = try branch(calls: false)
        XCTAssertTrue(usesCompare(control), "control branch uses the compare: \(control)")
        let called = try branch(calls: true)
        XCTAssertFalse(usesCompare(called), "NZCV from before the call must not decide the branch: \(called)")
    }

    func testCallClobbersCallerSavedVectorsAndUpperHalfOfCalleeSaved() throws {
        func function(calls: Bool) throws -> MacIRFunction {
            try region([
                row(0x0, "cbz", "x2, 0x20"),
                decoded(0x4f00_e429, at: 0x4, "movi v9.16b, #1"),
                decoded(0x4f00_e454, at: 0x8, "movi v20.16b, #2"),
                calls ? row(0xc, "bl", "_callee") : row(0xc, "nop", ""),
                decoded(0x4c00_7274, at: 0x10, "st1 {v20.16b}, [x19]"),
                decoded(0x4c00_7269, at: 0x14, "st1 {v9.16b}, [x19]"),
                decoded(0xfd00_0269, at: 0x18, "str d9, [x19]"),
                row(0x1c, "ret", ""), row(0x20, "bl", "___stack_chk_fail"),
            ])
        }
        let control = try function(calls: false)
        for address: UInt64 in [0x10, 0x14, 0x18] {
            XCTAssertFalse(isUnknown(try operation(control, at: address)), "control store \(address)")
        }
        let called = try function(calls: true)
        XCTAssertTrue(isUnknown(try operation(called, at: 0x10)), "v20 is caller-saved")
        XCTAssertTrue(isUnknown(try operation(called, at: 0x14)),
                      "only the low 64 bits of v9 survive a call")
        let low = try operation(called, at: 0x18)
        XCTAssertFalse(isUnknown(low), "d9 is callee-saved")
        XCTAssertFalse("\(low)".contains("unavailable"), "\(low)")
    }

    func testJoinAfterCallOnOnePathDoesNotForwardPreCallVector() throws {
        func rows(calls: Bool) -> [InstructionRow] {
            [decoded(0x4f00_e429, at: 0x0, "movi v9.16b, #1"),
             row(0x4, "cbz", "x1, 0x18"), row(0x8, "cbz", "x0, 0x10"),
             calls ? row(0xc, "bl", "_callee") : row(0xc, "nop", ""),
             decoded(0x4c00_7269, at: 0x10, "st1 {v9.16b}, [x19]"),
             row(0x14, "ret", ""), row(0x18, "bl", "___stack_chk_fail")]
        }
        let control = try region(rows(calls: false))
        XCTAssertFalse(isUnknown(try operation(control, at: 0x10)), "control: v9 reaches the join")
        let called = try region(rows(calls: true))
        let store = try operation(called, at: 0x10)
        XCTAssertTrue(isUnknown(store) || "\(store)".contains("unavailable"),
                      "one calling predecessor makes the joined q9 unavailable: \(store)")
    }

    func testCallInvalidatesHeapAndStackMemoryFacts() throws {
        let function = try region([
            row(0x0, "cbz", "x2, 0x24"), ld4(at: 0x4),
            row(0x8, "ldr", "x9, [x19]"), row(0xc, "str", "x9, [sp, #0x8]"),
            row(0x10, "bl", "_callee"),
            row(0x14, "ldr", "x10, [x19]"), row(0x18, "ldr", "x11, [sp, #0x8]"),
            row(0x1c, "add", "x0, x10, x11"),
            row(0x20, "ret", ""), row(0x24, "bl", "___stack_chk_fail"),
        ])
        let heap = try operation(function, at: 0x14)
        if case .load = heap {} else { XCTFail("heap reload after a call must load: \(heap)") }
        let stack = "\(try operation(function, at: 0x18))"
        XCTAssertFalse(stack.contains(" x9_"),
                       "a stack slot stored before a call must not forward: \(stack)")
    }

    func testMidFunctionStackCheckFailureIsATerminalExit() throws {
        let function = try region([
            row(0x0, "cbz", "x0, 0x8"), row(0x4, "bl", "___stack_chk_fail"),
            ld4(at: 0x8), row(0xc, "subs", "x1, x1, #0x1"),
            row(0x10, "b.ne", "0x8"), row(0x14, "ret", ""),
        ])
        let fatal = try operation(function, at: 0x4)
        guard case let .call(frame, result) = fatal else { return XCTFail("\(fatal)") }
        XCTAssertEqual(frame.target, "___stack_chk_fail")
        XCTAssertNil(result)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let index = try XCTUnwrap(function.instructions.lastIndex { $0.source.address == 0x4 })
        let block = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(index) })
        XCTAssertTrue(block.successors.isEmpty, "no fallthrough from a no-return call into the loop")
    }
}

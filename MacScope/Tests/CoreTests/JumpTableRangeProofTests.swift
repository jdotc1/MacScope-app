import Foundation
import XCTest
@testable import MacScope

final class JumpTableRangeProofTests: XCTestCase {
    private func rows(_ assembly: [(String, String)]) -> [InstructionRow] {
        assembly.enumerated().map { i, a in InstructionRow(address: 0x1000 + UInt64(i * 4),
            bytes: "", mnemonic: a.0, operands: a.1, hasBreakpoint: false, comment: nil) }
    }
    private func signedGuard() -> [InstructionRow] {
        rows([("cmp", "w0, #16"), ("b.ge", "0x102c"),
              ("subs", "w1, w0, #1"), ("b.lt", "0x102c"),
              ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"), ("adr", "x10, 0x1028"),
              ("ldrb", "w11, [x9, x1]"), ("add", "x10, x10, x11, lsl #2"),
              ("br", "x10"), ("nop", ""), ("ret", "")])
    }
    private func resolve(_ rows: [InstructionRow]) -> [UInt64: [UInt64]] {
        JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
            guard address >= 0x2000, address < 0x200f, count == 1 else { return nil }
            return Data([0])
        }, codeRange: .init(lowerBound: 0x1000, upperBound: rows.last!.address + 4))
    }
    func testSignedSubtractGuardUsesOverflowAwareComparison() throws {
        let input = signedGuard()
        let proof = try XCTUnwrap(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
        XCTAssertEqual(proof.caseCount, 15)
        XCTAssertEqual(proof.register, "x1")
        XCTAssertEqual(resolve(input)[0x1024], Array(repeating: 0x1028, count: 15))
        // INT32_MIN - 1 has N=0,V=1: B.LT is taken. The range is
        // obtained from signed original-input >= 1, not result-sign >= 0.
        let original = Int64(Int32.min)
        let wrapped = Int32(truncatingIfNeeded: original - 1)
        let n = wrapped < 0, v = original - 1 < Int64(Int32.min)
        XCTAssertTrue(n != v)
    }
    func testCompareProvenanceSurvivesMoveOverComparedRegister() throws {
        let input = rows([("sub", "w1, w0, #16"), ("cmp", "w0, #31"),
            ("mov", "w0, w1"), ("b.hi", "0x1030"),
            ("subs", "w1, w1, #1"), ("b.lt", "0x1030"),
            ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"), ("adr", "x10, 0x1030"),
            ("ldrb", "w11, [x9, x1]"), ("add", "x10, x10, x11, lsl #2"),
            ("br", "x10"), ("ret", "")])
        XCTAssertEqual(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 11, jumpTables: [:])?.caseCount, 15)
        XCTAssertEqual(resolve(input)[0x102c]?.count, 15)
    }
    func testUnknownFlagsWritesAndUpperBitsRefuse() {
        var input = signedGuard()
        input[2].mnemonic = "adds"
        XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
        input = signedGuard(); input[2].operands = "x1, x0, #1"
        XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
        input = signedGuard(); input[5].mnemonic = "ldr"; input[5].operands = "x1, [x2]"
        XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
    }
    func testAliasWritesInvalidateCanonicalRegisterBounds() {
        for (alias, number) in [("fp", 29), ("lr", 30)] {
            var input = signedGuard()
            input[2].operands = "w\(number), w0, #1"
            input[7].operands = "w11, [x9, x\(number)]"
            XCTAssertNotNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
            input[5].mnemonic = "mov"; input[5].operands = "\(alias), x0"
            XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
        }
    }

    func testRecoveredEdgeCannotBypassTableSetup() {
        let input = signedGuard()
        XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9,
            jumpTables: [0x1024: Array(repeating: 0x1014, count: 15)]))
    }
    func testImmediateDefinitionCannotAliasAnEarlierUnknownWrite() {
        let input = rows([("ldp", "w0, w1, [x2]"), ("mov", "w0, #7"),
            ("cmp", "w0, #16"), ("b.ge", "0x1034"),
            ("subs", "w1, w1, #1"), ("b.lt", "0x1034"),
            ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"), ("adr", "x10, 0x1030"),
            ("ldrb", "w11, [x9, x1]"), ("add", "x10, x10, x11, lsl #2"),
            ("br", "x10"), ("nop", ""), ("ret", "")])
        XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 11, jumpTables: [:]))
    }

    func testIndependentLoadPairDefinitionsDoNotShareRangeIdentity() {
        var input = signedGuard()
        input[0].mnemonic = "ldp"; input[0].operands = "w0, w1, [x2]"
        input[1].mnemonic = "cmp"; input[1].operands = "w0, #16"
        input[2].mnemonic = "b.ge"; input[2].operands = "0x102c"
        input[3].mnemonic = "nop"; input[3].operands = ""
        XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 9, jumpTables: [:]))
    }
}

extension JumpTableRangeProofTests {
    /// DP12 #672: a direct entry at the CMP bypasses the W definition that zero-extends the
    /// X index, so the W compare does not bound the X-indexed load.
    func testEntryAtCompareBypassesTheZeroExtendingWDefinition() {
        func site(entry: String) -> [InstructionRow] {
            rows([("cbz", "x2, \(entry)"), ("nop", ""), ("mov", "w0, w1"),
                  ("cmp", "w0, #3"), ("b.hi", "0x1030"),
                  ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"),
                  ("ldr", "x10, [x9, x0, lsl #3]"), ("br", "x10"),
                  ("nop", ""), ("nop", ""), ("nop", ""), ("ret", "")])
        }
        // Controls: entries outside the protected run, or at the W definition itself.
        XCTAssertEqual(JumpTableResolver.proveRegionSelector(rows: site(entry: "0x1030"), dispatchIndex: 8,
                                                              jumpTables: [:])?.caseCount, 4)
        XCTAssertNotNil(JumpTableResolver.proveRegionSelector(rows: site(entry: "0x1008"), dispatchIndex: 8, jumpTables: [:]))
        // An entry exactly at the CMP skips `mov w0, w1`: x0's upper bits are unknown.
        XCTAssertNil(JumpTableResolver.proveRegionSelector(rows: site(entry: "0x100c"), dispatchIndex: 8, jumpTables: [:]))
    }
}

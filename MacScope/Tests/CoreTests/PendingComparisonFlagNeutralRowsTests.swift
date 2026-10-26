import XCTest
@testable import MacScope

/// A26: under SSA a pending cmp/ccmp stays live across flag-neutral rows of the
/// same block. Flag-off MacIR is unchanged.
final class PendingComparisonFlagNeutralRowsTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func text(ssa: Bool, _ rows: [InstructionRow]) -> String {
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_pending", instructions: rows)
        return PseudocodePrinter().print(function: function).text
    }

    private func sequence(_ middle: [InstructionRow]) -> [InstructionRow] {
        var rows = [row(0x1000, "cmp", "w0, #0x1")]
        rows += middle
        let next = 0x1004 + UInt64(middle.count) * 4
        rows += [row(next, "ccmp", "w2, #0x3, #0x0, ne"), row(next + 4, "cset", "w15, eq"), row(next + 8, "ret", "")]
        return rows
    }

    func testCmpLslCcmpCsetLiftsCompoundConditionUnderSSA() {
        let rows = sequence([row(0x1004, "lsl", "w14, w1, #0x2")])
        let on = text(ssa: true, rows)
        XCTAssertFalse(on.contains("__unknown(\"cset\""), on)
        XCTAssertFalse(on.contains("__unknown(\"ccmp\""), on)
        // Flag-off keeps the legacy account byte for byte.
        let off = text(ssa: false, rows)
        XCTAssertTrue(off.contains("__unknown(\"cset\""), off)
    }

    func testInterveningWriteToComparedRegisterClearsPendingComparison() {
        let on = text(ssa: true, sequence([row(0x1004, "lsl", "w0, w1, #0x2")]))
        XCTAssertTrue(on.contains("__unknown(\"cset\""), on)
    }

    func testInterveningNZCVWriterClearsPendingComparison() {
        // adds starts its own comparison: the original cmp operand is not used.
        let on = text(ssa: true, sequence([row(0x1004, "adds", "w14, w1, #0x2")]))
        XCTAssertFalse(on.contains("arg0 != 0x1"), on)
        XCTAssertTrue(on.contains("arg1"), on)
    }

    func testBlockBoundaryBetweenCmpAndCsetClearsPendingComparison() {
        let rows = [
            row(0x1000, "cbz", "w5, 0x100c"),
            row(0x1004, "cmp", "w0, #0x1"),
            row(0x1008, "lsl", "w14, w1, #0x2"),
            row(0x100c, "ccmp", "w2, #0x3, #0x0, ne"),
            row(0x1010, "cset", "w15, eq"),
            row(0x1014, "ret", ""),
        ]
        let on = text(ssa: true, rows)
        XCTAssertTrue(on.contains("__unknown(\"cset\""), on)
    }

    func testCmpAcrossAddressMaterializationLiftsCselUnderSSA() {
        let rows = [
            row(0x1000, "cmp", "w0, #0x0"),
            row(0x1004, "adrp", "x9, 0x0000000000058000"),
            row(0x1008, "add", "x9, x9, #0xd8"),
            row(0x100c, "adrp", "x10, 0x000000000003b000"),
            row(0x1010, "add", "x10, x10, #0x3f4"),
            row(0x1014, "csel", "x9, x10, x9, eq"),
            row(0x1018, "ret", ""),
        ]
        let on = text(ssa: true, rows)
        XCTAssertFalse(on.contains("__unknown(\"csel\""), on)
    }
}

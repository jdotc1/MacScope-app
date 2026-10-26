import XCTest
@testable import MacScope

/// A27: flag consumers lift through an SSA NZCV phi at joins only when every
/// incoming edge carries a recorded comparison (design s3 :207).
final class FlagsPhiJoinTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func text(ssa: Bool = true, _ rows: [InstructionRow]) -> String {
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_join", instructions: rows)
        return PseudocodePrinter().print(function: function).text
    }

    private let twoPredecessors: [InstructionRow] = [
        InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "cbz", operands: "w5, 0x1010", hasBreakpoint: false, comment: nil),
        InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cmp", operands: "w0, #0x1", hasBreakpoint: false, comment: nil),
        InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
        InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
        InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cmp", operands: "w1, #0x2", hasBreakpoint: false, comment: nil),
    ]

    func testTwoPredecessorJoinLiftsCselFromTwoComparisons() {
        let out = text(twoPredecessors + [row(0x1014, "csel", "x9, x2, x3, eq"), row(0x1018, "ret", "")])
        XCTAssertFalse(out.contains("__unknown(\"csel\""), out)
        XCTAssertTrue(out.contains("in_w0 == 0x1"), out)
        XCTAssertTrue(out.contains("in_w1 == 0x2"), out)
    }

    func testTwoPredecessorJoinLiftsConditionalBranch() {
        let out = text(twoPredecessors + [
            row(0x1014, "b.eq", "0x101c"), row(0x1018, "mov", "x0, #0x1"), row(0x101c, "ret", "")])
        XCTAssertFalse(out.contains("branch_eq"), out)
        XCTAssertTrue(out.contains("in_w0 == 0x1"), out)
        XCTAssertTrue(out.contains("in_w1 == 0x2"), out)
    }

    private func threePredecessors(third: InstructionRow) -> [InstructionRow] {
        [
            row(0x1000, "cbz", "w5, 0x1010"),
            row(0x1004, "cmp", "w0, #0x1"),
            row(0x1008, "b", "0x1020"),
            row(0x100c, "nop", ""),
            row(0x1010, "cbz", "w6, 0x101c"),
            row(0x1014, "cmp", "w1, #0x2"),
            row(0x1018, "b", "0x1020"),
            third,
            row(0x1020, "csel", "x9, x3, x4, eq"),
            row(0x1024, "ret", ""),
        ]
    }

    func testThreePredecessorJoinWithAllIncomingsRecordedLifts() {
        let out = text(threePredecessors(third: row(0x101c, "cmp", "w2, #0x3")))
        XCTAssertFalse(out.contains("__unknown(\"csel\""), out)
        XCTAssertFalse(out.contains("__compare("), out)
        for (name, literal) in [("0", "0x1"), ("1", "0x2"), ("2", "0x3")] {
            XCTAssertTrue(out.contains("arg\(name) == \(literal)") || out.contains("in_w\(name) == \(literal)"), out)
        }
    }

    func testIncomingFromCallClobberKeepsRefusal() {
        var rows = twoPredecessors
        rows[1] = row(0x1004, "cmp", "w0, #0x1")
        rows[2] = row(0x1008, "bl", "_f")
        rows[3] = row(0x100c, "b", "0x1014")
        let out = text(rows + [row(0x1014, "csel", "x9, x2, x3, eq"), row(0x1018, "ret", "")])
        XCTAssertTrue(out.contains("__unknown(\"csel\""), out)
    }

    func testIncomingFromUnknownEffectsFlagWriterKeepsRefusal() {
        var rows = twoPredecessors
        rows[1] = row(0x1004, "cfinv", "")
        let out = text(rows + [row(0x1014, "csel", "x9, x2, x3, eq"), row(0x1018, "ret", "")])
        XCTAssertTrue(out.contains("__unknown(\"csel\""), out)
    }

    func testLoopHeaderWithUnestablishedBackEdgeFlagsKeepsRefusal() {
        let out = text([
            row(0x1000, "cmp", "w0, #0x1"),
            row(0x1004, "csel", "x9, x2, x3, eq"),
            row(0x1008, "add", "x2, x2, #0x1"),
            row(0x100c, "cmp", "w2, #0x9"),
            row(0x1010, "b.ne", "0x1004"),
            row(0x1014, "ret", ""),
        ])
        XCTAssertTrue(out.contains("__unknown(\"csel\""), out)
    }

    func testThreePredecessorJoinWithOneIncomingMissingKeepsRefusal() {
        let out = text(threePredecessors(third: row(0x101c, "nop", "")))
        XCTAssertTrue(out.contains("__unknown(\"csel\""), out)
    }

    func testFlagOffKeepsRefusalAtJoin() {
        let out = text(ssa: false, twoPredecessors + [row(0x1014, "csel", "x9, x2, x3, eq"), row(0x1018, "ret", "")])
        XCTAssertFalse(out.contains("flag_"), out)
    }
}

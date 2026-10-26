import Foundation
import LumenUI
import XCTest
@testable import MacScope

/// Branch lanes in the disassembly listing (U6c): jumps inside a function, grouped per function.
final class DisassemblyBranchLanesTests: XCTestCase {
    private func insn(_ address: UInt64, _ mnemonic: String = "nop") -> ListingRow {
        .instruction(InstructionRow(address: address, bytes: "1f2003d5", mnemonic: mnemonic, operands: "",
                                    hasBreakpoint: false, comment: nil))
    }

    private func edge(_ from: UInt64, _ to: UInt64, _ kind: String) -> ControlFlowEdge {
        ControlFlowEdge(id: UUID(), from: from, to: to, kind: kind)
    }

    private func function(_ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(), name: "f_\(start)", startAddress: start, endAddress: end, confidence: 1)
    }

    /// Rows: 0 label f, 1 b.eq →0x100c, 2 nop, 3 comment, 4 b →0x1000, 5 ret, 6 label g, 7 b →0x1004 (other function), 8 bl.
    private var rows: [ListingRow] {
        [.label(LabelRow(address: 0x1000, name: "f", isFunctionStart: true)), insn(0x1000, "b.eq"), insn(0x1004),
         .prefixComment(PrefixCommentRow(address: 0x1008, text: "loop back\nwrapped")), insn(0x1008, "b"), insn(0x100c, "ret"),
         .label(LabelRow(address: 0x2000, name: "g", isFunctionStart: true)), insn(0x2000, "b"), insn(0x2004, "bl")]
    }

    private var lanes: DisassemblyBranchLanes {
        DisassemblyBranchLanes.build(
            rows: rows,
            edges: [edge(0x1000, 0x100c, "branch"), edge(0x1000, 0x1004, "fallthrough"),
                    edge(0x1008, 0x1000, "branch"), edge(0x2000, 0x1004, "branch"), edge(0x2004, 0x1000, "call")],
            functions: [function(0x1000, 0x1010), function(0x2000, 0x2008)]
        )
    }

    func testOnlyJumpsWithinOneFunctionBecomeLanesAndConditionalOnesAreTaken() {
        XCTAssertEqual(lanes.groups, [[
            .init(fromRow: 1, toRow: 5, isConditional: true),
            .init(fromRow: 4, toRow: 1, isConditional: false),
        ]], "Fall-throughs, calls and the jump into another function are not lanes")
    }

    func testRowsBelongToTheFunctionOfTheInstructionAboveThem() {
        XCTAssertEqual(lanes.groupByRow, [-1, 0, 0, 0, 0, 0, 0, -1, -1],
                       "A comment inside f draws f's lanes; g has none")
        XCTAssertEqual(lanes.endpointRows, [0x1000: 1, 0x100c: 5, 0x1008: 4])
    }

    func testEachRowDrawsItsFunctionsLanesWithTheSelectionHighlighted() {
        let atComment = lanes.lumenLanes(atRow: 3, selectedRow: 4)
        XCTAssertEqual(atComment.map(\.kind), [.taken, .unconditional])
        XCTAssertEqual(atComment.map(\.isHighlighted), [false, true], "Only the jump from or to the selected row")
        XCTAssertEqual(lanes.lumenLanes(atRow: 0, selectedRow: nil), [], "The label above the first jump draws nothing")
        XCTAssertEqual(lanes.lumenLanes(atRow: 7, selectedRow: nil), [])
        XCTAssertEqual(lanes.lumenLanes(atRow: 99, selectedRow: nil), [])
    }

    @MainActor
    func testAnImageWithoutJumpsReservesNoGutter() {
        let none = DisassemblyBranchLanes.build(rows: rows, edges: [edge(0x1000, 0x1004, "fallthrough")],
                                                functions: [function(0x1000, 0x1010)])
        XCTAssertTrue(none.groups.isEmpty)
        XCTAssertEqual(DisassemblyBranchLanes.gutterWidth, LumenBranchLanes.width(columns: 4))
    }
}

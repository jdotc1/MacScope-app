import XCTest
@testable import MacScope

final class DecompilerLoopSecondaryExitTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func function(_ name: String, _ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func print(_ name: String, _ rows: [InstructionRow]) -> PseudocodeDocument {
        PseudocodePrinter().print(function: function(name, rows))
    }

    private func diagnostics(_ rows: [InstructionRow]) -> RegionTree.Diagnostics {
        let function = function("_diagnostics", rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        return RegionTree
            .buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
            .diagnostics
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func regions(in node: PseudocodeRegionNode?, kind: PseudocodeRegionNode.Kind) -> [PseudocodeRegionNode] {
        guard let node else { return [] }
        var matches = node.kind == kind ? [node] : []
        for child in node.children {
            matches.append(contentsOf: regions(in: child, kind: kind))
        }
        return matches
    }

    func testTableScanTerminalSecondaryExitStructuresInsideLoop() {
        let document = print("_terminal_secondary_table_scan", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1030", "primary loop exit"),
            row(0x1008, "cbz", "x1, 0x1020", "terminal not-found arm"),
            row(0x100c, "nop", "", "scan body"),
            row(0x1010, "b", "0x1000", "back-edge"),
            row(0x1020, "mov", "x0, #0x0", "terminal default"),
            row(0x1024, "ret", ""),
            row(0x1030, "mov", "x0, #0x1", "primary result"),
            row(0x1034, "ret", "")
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
        XCTAssertTrue(document.text.contains("while ("))
        XCTAssertGreaterThanOrEqual(regions(in: document.regionTree, kind: .gotoLeaf).count, 1)
        XCTAssertEqual(occurrenceCount(of: "terminal default", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "scan body", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "primary result", in: document.text), 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1008).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x100c).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1020).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1030).count, 1)
    }

    func testNonTerminalSecondaryExitStaysVetoed() {
        let rows = [
            row(0x2000, "cmp", "x0, #0x0"),
            row(0x2004, "b.eq", "0x2030", "primary exit"),
            row(0x2008, "cbz", "x1, 0x2020", "rejoining secondary"),
            row(0x200c, "nop", "", "body"),
            row(0x2010, "b", "0x2000", "back-edge"),
            row(0x2020, "mov", "x0, #0x2", "secondary rejoins"),
            row(0x2024, "b", "0x2030", "secondary to primary"),
            row(0x2030, "mov", "x0, #0x1", "primary tail"),
            row(0x2034, "ret", "")
        ]

        let result = diagnostics(rows)
        XCTAssertEqual(result.fatalVeto, .loopSecondaryExitNotInContinuation)
        XCTAssertEqual(result.siteCounts[.loopSecondaryExitNotInContinuation], 1)
    }

    func testSecondaryArmWithBackedgeStaysVetoed() {
        let rows = [
            row(0x3000, "cmp", "x0, #0x0"),
            row(0x3004, "b.eq", "0x3040", "primary exit"),
            row(0x3008, "cbz", "x1, 0x3020", "secondary with cycle"),
            row(0x300c, "nop", "", "body"),
            row(0x3010, "b", "0x3000", "back-edge"),
            row(0x3020, "cbz", "x2, 0x302c", "leaf exit test"),
            row(0x3024, "nop", "", "leaf cycle body"),
            row(0x3028, "b", "0x3020", "leaf back-edge"),
            row(0x302c, "ret", ""),
            row(0x3040, "ret", "")
        ]

        let result = diagnostics(rows)
        XCTAssertEqual(result.fatalVeto, .loopSecondaryExitNotInContinuation)
        XCTAssertEqual(result.siteCounts[.loopSecondaryExitNotInContinuation], 1)
    }

    func testSecondaryArmReachableFromOutsideLoopStaysVetoed() {
        let rows = [
            row(0x4000, "cbz", "x3, 0x4020", "outside reaches terminal arm"),
            row(0x4004, "cmp", "x0, #0x0"),
            row(0x4008, "b.eq", "0x4040", "primary exit"),
            row(0x400c, "cbz", "x1, 0x4020", "loop reaches terminal arm"),
            row(0x4010, "nop", "", "body"),
            row(0x4014, "b", "0x4004", "back-edge"),
            row(0x4020, "mov", "x0, #0x0", "shared terminal"),
            row(0x4024, "ret", ""),
            row(0x4040, "ret", "")
        ]

        let result = diagnostics(rows)
        XCTAssertEqual(result.fatalVeto, .loopSecondaryExitNotInContinuation)
        XCTAssertEqual(result.siteCounts[.loopSecondaryExitNotInContinuation], 1)
    }

    func testPrimaryExitAbsenceKeepsLoopVeto() {
        let rows = [
            row(0x5000, "cbz", "x0, 0x5008", "internal header guard"),
            row(0x5004, "nop", "", "header fallthrough"),
            row(0x5008, "cbz", "x1, 0x5020", "secondary one"),
            row(0x500c, "cbz", "x2, 0x5030", "secondary two"),
            row(0x5010, "nop", "", "body"),
            row(0x5014, "b", "0x5000", "back-edge"),
            row(0x5020, "ret", ""),
            row(0x5030, "ret", "")
        ]

        let result = diagnostics(rows)
        XCTAssertEqual(result.fatalVeto, .loopMultipleExitTargets)
        XCTAssertEqual(result.siteCounts[.loopMultipleExitTargets], 1)
    }

    func testExistingSingleExitWhileAndDoWhileRenderByteIdentical() {
        let whileDocument = print("_single_exit_while_regression", [
            row(0x6000, "cmp", "x0, #0x0"),
            row(0x6004, "b.eq", "0x6010", "exit"),
            row(0x6008, "nop", "", "body"),
            row(0x600c, "b", "0x6000"),
            row(0x6010, "ret", "")
        ])
        XCTAssertEqual(
            whileDocument.text,
            """
            int64_t _single_exit_while_regression(int64_t arg0) {
                // entry 0x0000000000006000; no stack frame; calls none
                while (arg0 != 0x0) { // exit; conditional branch
                    __nop(); // body
                }
                return unresolved_return_contract; // return
            }
            """
        )

        let doWhileDocument = print("_single_exit_do_while_regression", [
            row(0x6100, "nop", "", "body"),
            row(0x6104, "cmp", "x0, #0x0"),
            row(0x6108, "b.ne", "0x6100", "back-edge"),
            row(0x610c, "ret", "")
        ])
        XCTAssertEqual(
            doWhileDocument.text,
            """
            int64_t _single_exit_do_while_regression(int64_t arg0) {
                // entry 0x0000000000006100; no stack frame; calls none
                do {
                    __nop(); // body
                } while (arg0 != 0x0); // back-edge; conditional branch
                return unresolved_return_contract; // return
            }
            """
        )
    }

    func testPrimaryBreakAndTerminalSecondaryExitBothStructure() {
        let document = print("_primary_break_with_terminal_secondary", [
            row(0x7000, "cmp", "x0, #0x0"),
            row(0x7004, "b.eq", "0x7040", "primary header exit"),
            row(0x7008, "cbz", "x1, 0x7030", "terminal not-found arm"),
            row(0x700c, "cbz", "x2, 0x7040", "primary body break"),
            row(0x7010, "nop", "", "scan body"),
            row(0x7014, "b", "0x7000", "back-edge"),
            row(0x7030, "mov", "x0, #0x0", "terminal default"),
            row(0x7034, "ret", ""),
            row(0x7040, "ret", "")
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertTrue(document.text.contains("while ("))
        XCTAssertTrue(document.text.contains("break;"))
        XCTAssertEqual(occurrenceCount(of: "terminal default", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "primary body break", in: document.text), 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x7008).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x700c).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x7030).count, 1)
    }
}

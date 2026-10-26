import XCTest
@testable import MacScope

final class DecompilerStructuringLoopTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func function(_ name: String, _ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func print(_ name: String, _ rows: [InstructionRow]) -> PseudocodeDocument {
        let lifted = function(name, rows)
        if name == "_same_target_loop_exits" { SSARenderExpectation.assertEntryBackedgeRefusal(lifted) }
        return PseudocodePrinter().print(function: lifted)
    }

    private func gotoCount(_ document: PseudocodeDocument) -> Int {
        document.lines.reduce(0) { count, line in
            count + (line.text.contains("goto") ? 1 : 0)
        }
    }

    func testRegionTreeDiagnosticsAttributeDistinctLoopExitTargets() {
        let function = function("_distinct_loop_exits", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1020", "header exit"),
            row(0x1008, "cbz", "x1, 0x1028", "body exit"),
            row(0x100c, "nop", "", "body"),
            row(0x1010, "b", "0x1000", "back-edge"),
            row(0x1020, "ret", ""),
            row(0x1028, "ret", "")
        ])
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(
            cfg: cfg,
            instructions: function.instructions,
            collectDiagnostics: true
        )

        XCTAssertFalse(containsIrreducible(result.region), "terminal secondary loop exit should now structure")
        XCTAssertNil(result.diagnostics.fatalVeto)
        XCTAssertNil(result.diagnostics.siteCounts[.loopMultipleExitTargets])
    }

    func testSameTargetLoopExitBranchesRenderAsBreaks() {
        let document = print("_same_target_loop_exits", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1020", "header exit"),
            row(0x1008, "cbz", "x1, 0x1020", "body exit"),
            row(0x100c, "nop", "", "body"),
            row(0x1010, "b", "0x1000", "back-edge"),
            row(0x1020, "ret", "")
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
        XCTAssertEqual(gotoCount(document), 0)
        XCTAssertEqual(
            document.text,
            """
            int64_t _same_target_loop_exits(int64_t arg0, int64_t arg1) {
                // entry 0x0000000000001000; no stack frame; calls none
                while (arg0 != 0x0) { // header exit; conditional branch
                    if (!arg1) { // body exit; conditional branch
                        break;
                    }
                    __nop(); // body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x1008).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x100c).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1020).count, 1)
    }

    func testDistinctLoopExitTargetsStillFallBack() {
        let document = print("_distinct_loop_exits", [
            row(0x2000, "cmp", "x0, #0x0"),
            row(0x2004, "b.eq", "0x2020", "header exit"),
            row(0x2008, "cbz", "x1, 0x2028", "body exit"),
            row(0x200c, "nop", "", "body"),
            row(0x2010, "b", "0x2000", "back-edge"),
            row(0x2020, "ret", ""),
            row(0x2028, "ret", "")
        ])

        XCTAssertNotNil(document.regionTree)
        XCTAssertNil(document.structureFallback)
        XCTAssertTrue(document.text.contains("while ("))
        XCTAssertEqual(document.lines(sourcedAt: 0x2008).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x2028).count, 1)
    }

    func testLoopExitBreakWithNonAdjacentCompareStillFallsBack() {
        let document = print("_non_adjacent_break_condition", [
            row(0x3000, "cbz", "x0, 0x3020", "header exit"),
            row(0x3004, "cmp", "x1, #0x0"),
            row(0x3008, "nop", "", "between compare and branch"),
            row(0x300c, "b.eq", "0x3020", "body exit"),
            row(0x3010, "nop", "", "body"),
            row(0x3014, "b", "0x3000", "back-edge"),
            row(0x3020, "ret", "")
        ])

        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unsupportedRegion.rawValue)
        XCTAssertFalse(document.text.contains("break;"))
        XCTAssertTrue(document.text.contains("// between compare and branch"))
        XCTAssertTrue(document.text.contains("// body"))
    }

    private func containsIrreducible(_ region: Region?) -> Bool {
        guard let region else { return true }
        switch region {
        case .irreducible:
            return true
        case let .sequence(items):
            return items.contains(where: { containsIrreducible($0) })
        case let .ifThen(_, body, _, _):
            return containsIrreducible(body)
        case let .ifThenElse(_, then, els, _):
            return containsIrreducible(then) || containsIrreducible(els)
        case let .whileLoop(_, body, _), let .doWhileLoop(body, _), let .naturalLoop(body, _):
            return containsIrreducible(body)
        default:
            return false
        }
    }
}

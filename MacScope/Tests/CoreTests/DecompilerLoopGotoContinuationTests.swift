import XCTest
@testable import MacScope

final class DecompilerLoopGotoContinuationTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func function(_ name: String, _ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func print(_ name: String, _ rows: [InstructionRow], ssaEnabled: Bool? = nil) -> PseudocodeDocument {
        let lifted = MacIRBuilder(ssaEnabled: ssaEnabled).buildFunction(name: name, instructions: rows)
        if name == "_label_only_when_needed" { SSARenderExpectation.assertEntryBackedgeRefusal(lifted) }
        return PseudocodePrinter().print(function: lifted)
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

    private func labelCount(_ label: String, in document: PseudocodeDocument) -> Int {
        document.lines.filter {
            let text = $0.text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":;", with: ":")
            guard text.hasSuffix(":") else { return false }
            let name = String(text.dropLast())
            let digits = name.hasPrefix("L_") ? String(name.dropFirst(2)) : name
            return UInt64(digits.replacingOccurrences(of: "0x", with: ""), radix: 16)
                == UInt64(label.replacingOccurrences(of: "0x", with: ""), radix: 16)
        }.count
    }

    private func gotoCount(_ document: PseudocodeDocument) -> Int {
        document.lines.reduce(0) { count, line in
            count + (line.text.contains("goto") ? 1 : 0)
        }
    }

    func testSharedRetScanLoopRendersContinuationGotoAndSingleLabel() {
        let document = print("_shared_ret_scan_loop", [
            row(0x1000, "nop", "", "scan body"),
            row(0x1004, "cbz", "x1, 0x1018", "secondary shared ret"),
            row(0x1008, "add", "x0, x0, #0x1", "advance"),
            row(0x100c, "cmp", "x0, #0x8"),
            row(0x1010, "b.ne", "0x1000", "back-edge"),
            row(0x1014, "mov", "x0, x1", "primary continuation"),
            row(0x1018, "ret", "")
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
        XCTAssertTrue(document.text.contains("do {"))
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x1018, condition: "arg1 == 0x0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        XCTAssertEqual(labelCount("0x1018", in: document), 1)
        XCTAssertEqual(occurrenceCount(of: "scan body", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "advance", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "primary continuation", in: document.text), 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1004).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1014).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1018).count, 1)
    }

    func testSecondaryTargetNotInContinuationKeepsNewVeto() {
        let result = diagnostics([
            row(0x2000, "cmp", "x0, #0x0"),
            row(0x2004, "b.eq", "0x2020", "primary exit"),
            row(0x2008, "cbz", "x1, 0x2030", "secondary not in continuation"),
            row(0x200c, "nop", "", "body"),
            row(0x2010, "b", "0x2000", "back-edge"),
            row(0x2020, "ret", ""),
            row(0x2030, "mov", "x0, #0x2", "secondary rejoins primary"),
            row(0x2034, "b", "0x2020")
        ])

        XCTAssertEqual(result.fatalVeto, .loopSecondaryExitNotInContinuation)
        XCTAssertEqual(result.siteCounts[.loopSecondaryExitNotInContinuation], 1)
    }

    func testLE1TerminalSecondaryExitStillStructures() {
        let document = print("_terminal_secondary_still_structures", [
            row(0x2100, "cmp", "x0, #0x0"),
            row(0x2104, "b.eq", "0x2130", "primary loop exit"),
            row(0x2108, "cbz", "x1, 0x2120", "terminal not-found arm"),
            row(0x210c, "nop", "", "scan body"),
            row(0x2110, "b", "0x2100", "back-edge"),
            row(0x2120, "mov", "x0, #0x0", "terminal default"),
            row(0x2124, "ret", ""),
            row(0x2130, "mov", "x0, #0x1", "primary result"),
            row(0x2134, "ret", "")
        ], ssaEnabled: false)

        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
        XCTAssertTrue(document.text.contains("while ("))
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x2120)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        XCTAssertEqual(occurrenceCount(of: "terminal default", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "primary result", in: document.text), 1)
    }

    func testSingleExitLoopsRemainByteIdentical() {
        let whileDocument = print("_le2_single_exit_while_regression", [
            row(0x2200, "cmp", "x0, #0x0"),
            row(0x2204, "b.eq", "0x2210", "exit"),
            row(0x2208, "nop", "", "body"),
            row(0x220c, "b", "0x2200"),
            row(0x2210, "ret", "")
        ])
        XCTAssertEqual(
            whileDocument.text,
            """
            int64_t _le2_single_exit_while_regression(int64_t arg0) {
                // entry 0x0000000000002200; no stack frame; calls none
                while (arg0 != 0x0) { // exit; conditional branch
                    __nop(); // body
                }
                return unresolved_return_contract; // return
            }
            """
        )

        let doWhileDocument = print("_le2_single_exit_do_while_regression", [
            row(0x2300, "nop", "", "body"),
            row(0x2304, "cmp", "x0, #0x0"),
            row(0x2308, "b.ne", "0x2300", "back-edge"),
            row(0x230c, "ret", "")
        ])
        XCTAssertEqual(
            doWhileDocument.text,
            """
            int64_t _le2_single_exit_do_while_regression(int64_t arg0) {
                // entry 0x0000000000002300; no stack frame; calls none
                do {
                    __nop(); // body
                } while (arg0 != 0x0); // back-edge; conditional branch
                return unresolved_return_contract; // return
            }
            """
        )
    }

    func testTwoSecondaryExitsToDistinctContinuationTargetsRenderOnceEach() {
        let document = print("_two_continuation_gotos", [
            row(0x3000, "cbz", "x1, 0x3020", "secondary first continuation"),
            row(0x3004, "cbz", "x2, 0x3024", "secondary second continuation"),
            row(0x3008, "add", "x0, x0, #0x1", "advance"),
            row(0x300c, "cmp", "x0, #0x4"),
            row(0x3010, "b.ne", "0x3000", "back-edge"),
            row(0x3014, "mov", "x0, #0x1", "primary continuation"),
            row(0x3018, "b", "0x3020"),
            row(0x3020, "mov", "x0, #0x2", "first continuation target"),
            row(0x3024, "mov", "x0, #0x3", "second continuation target"),
            row(0x3028, "ret", "")
        ])

        XCTAssertNil(document.structureFallback)
        // 3 gotos: the two secondary continuation-gotos PLUS the primary continuation's own
        // unconditional `b 0x3020`, which renders as an explicit (faithful) goto — the
        // authoring pass assumed fall-through suppression that the printer does not do.
        XCTAssertEqual(gotoCount(document), 3)
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x3020)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x3024)
        XCTAssertEqual(labelCount("0x3020", in: document), 1)
        XCTAssertEqual(labelCount("0x3024", in: document), 1)
        XCTAssertEqual(occurrenceCount(of: "first continuation target", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "second continuation target", in: document.text), 1)
    }

    func testOnlyGotoTargetsReceiveLabels() {
        let document = print("_label_only_when_needed", [
            row(0x4000, "cbz", "x1, 0x4018", "secondary shared ret"),
            row(0x4004, "add", "x0, x0, #0x1", "advance"),
            row(0x4008, "cmp", "x0, #0x3"),
            row(0x400c, "b.ne", "0x4000", "back-edge"),
            row(0x4010, "mov", "x0, #0x7", "primary continuation"),
            row(0x4018, "ret", "")
        ])

        // Pins the REAL pipeline render: loop-carried registers display as SSA versions
        // (x0_1/x0_2), the standing per-block SSA convention — the in-sandbox authoring pass
        // guessed argument-name propagation (driver-corrected, same class as CS-1's pin).
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x4018, condition: "arg1 == 0x0")
        XCTAssertEqual(labelCount("0x4010", in: document), 0)
        XCTAssertEqual(labelCount("0x4018", in: document), 1)
    }

    func testPrimaryBreakAndContinuationGotoInteract() {
        let document = print("_primary_break_with_continuation_goto", [
            row(0x5000, "cmp", "x0, #0x0"),
            row(0x5004, "b.eq", "0x5020", "primary header exit"),
            row(0x5008, "cbz", "x1, 0x5024", "secondary shared ret"),
            row(0x500c, "cbz", "x2, 0x5020", "primary body break"),
            row(0x5010, "nop", "", "scan body"),
            row(0x5014, "b", "0x5000", "back-edge"),
            row(0x5020, "mov", "x0, #0x1", "primary continuation"),
            row(0x5024, "ret", "")
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertTrue(document.text.contains("while ("))
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x5024)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        XCTAssertTrue(document.text.contains("break;"))
        XCTAssertEqual(labelCount("0x5024", in: document), 1)
        XCTAssertEqual(occurrenceCount(of: "primary body break", in: document.text), 1)
        XCTAssertEqual(occurrenceCount(of: "primary continuation", in: document.text), 1)
    }

    func testMissingStatementBoundaryForContinuationLabelFallsBack() {
        let document = print("_continuation_label_absorbed_header_fallback", [
            row(0x6000, "cbz", "x1, 0x6020", "secondary to continuation header"),
            row(0x6004, "add", "x0, x0, #0x1", "advance"),
            row(0x6008, "cmp", "x0, #0x4"),
            row(0x600c, "b.ne", "0x6000", "back-edge"),
            row(0x6010, "mov", "x0, #0x9", "primary continuation preface"),
            row(0x6020, "cbz", "x2, 0x602c", "absorbed continuation header"),
            row(0x6024, "mov", "x0, #0x1", "then arm"),
            row(0x6028, "b", "0x6030"),
            row(0x602c, "mov", "x0, #0x2", "else arm"),
            row(0x6030, "ret", "")
        ])

        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unsupportedRegion.rawValue)
        XCTAssertNil(document.regionTree)
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x6020)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testContinuationGotoTargetsDoNotLeakAcrossPrints() {
        let printer = PseudocodePrinter()
        let first = printer.print(function: function("_first_has_continuation_goto", [
            row(0x7000, "cbz", "x1, 0x7018", "secondary shared ret"),
            row(0x7004, "add", "x0, x0, #0x1", "advance"),
            row(0x7008, "cmp", "x0, #0x3"),
            row(0x700c, "b.ne", "0x7000", "back-edge"),
            row(0x7010, "mov", "x0, #0x7", "primary continuation"),
            row(0x7018, "ret", "")
        ]))
        let second = printer.print(function: function("_second_plain_function", [
            row(0x7018, "mov", "x0, #0x1", "same address no label"),
            row(0x701c, "ret", "")
        ]))

        XCTAssertNil(first.structureFallback)
        XCTAssertEqual(labelCount("0x7018", in: first), 1)
        XCTAssertNil(second.structureFallback)
        XCTAssertEqual(labelCount("0x7018", in: second), 0)
        GotoLabelWellFormednessTests.assertWellFormed(second.text)
    }
}

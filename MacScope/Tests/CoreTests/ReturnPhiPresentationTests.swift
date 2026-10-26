import XCTest
@testable import MacScope

final class ReturnPhiPresentationTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "",
                     _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: comment)
    }

    // Derived from the explicit CFG emitter: taken edges retain their labels
    // and gotos, while lexical successor edges fall through without a goto.
    private func expectedText(name: String, rejoiningComments: Bool = false) -> String {
        """
        int64_t \(name)(int64_t arg0, int64_t arg1, int64_t arg2) {
            // entry 0x0000000000008200; no stack frame; calls none
            if (arg0 == 0x0) { // else arm
                goto L_820c;
            }
            __nop(); // then private
            goto L_821c;\(rejoiningComments ? " // then to shared head" : "")
            L_820c:
            if (arg1 == 0x0) {\(rejoiningComments ? " // else skips shared" : "")
                goto L_8228;
            }
            if (arg2 == 0x0) {\(rejoiningComments ? " // else enters shared middle" : "")
                goto L_8220;
            }
            __nop();\(rejoiningComments ? " // else private\n    // else to shared head" : "")
            L_821c:
            __nop(); // shared head
            L_8220:
            x0_73 = 0x3; // \(rejoiningComments ? "shared middle double entry\n    // rejoin" : "shared middle")
            L_8228:
            return unresolved_return_contract;
        }
        """
    }

    func testRejoiningReturnPrunePreservesEveryControlLine() {
        let rows = [
            row(0x8200, "cbz", "x0, 0x820c", "else arm"),
            row(0x8204, "nop", "", "then private"),
            row(0x8208, "b", "0x821c", "then to shared head"),
            row(0x820c, "cbz", "x1, 0x8228", "else skips shared"),
            row(0x8210, "cbz", "x2, 0x8220", "else enters shared middle"),
            row(0x8214, "nop", "", "else private"),
            row(0x8218, "b", "0x821c", "else to shared head"),
            row(0x821c, "nop", "", "shared head"),
            row(0x8220, "mov", "x0, #0x3", "shared middle double entry"),
            row(0x8224, "b", "0x8228", "rejoin"),
            row(0x8228, "ret")
        ]
        // This contract covers legacy phi pruning, independent of the ambient SSA preference.
        let function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_rejoining_return", instructions: rows)
        let document = PseudocodePrinter().print(function: function)

        XCTAssertTrue(function.phis.isEmpty)
        XCTAssertTrue(function.retainsPhiControlPresentation)
        XCTAssertEqual(function.returnValue,
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertNil(document.regionTree)
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(document.text, expectedText(name: "_rejoining_return", rejoiningComments: true))
    }

    func testSharedReturnPrunePreservesControlAndBypassesRecoveryCapture() {
        let function = MacIRBuilder().buildFunction(
            name: "_shared_return", instructions: DecompilerStructuringRecoveryTests.sharedTail)
        let capture = CP6RecoveryTextCheck.Capture()
        var printer = PseudocodePrinter(options: .recoveryOn)
        printer.bypassRecoveryReadabilityForTesting = true
        printer.recoveryTextCheckCapture = capture
        let document = printer.print(function: function)

        XCTAssertTrue(function.phis.isEmpty)
        XCTAssertTrue(function.retainsPhiControlPresentation)
        XCTAssertEqual(function.returnValue,
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertNil(capture.snapshot)
        XCTAssertNil(document.regionTree)
        XCTAssertNil(document.structureFallback)
        XCTAssertTrue(document.text.contains("goto L_8228;"))
        XCTAssertEqual(document.text, expectedText(name: "_shared_return"))
    }

    func testSourceCommentsAreSanitizedAndMappedWithoutChangingControl() {
        var function = MacIRBuilder().buildFunction(
            name: "_comment_mapping", instructions: DecompilerStructuringRecoveryTests.sharedTail)
        for index in function.instructions.indices {
            function.instructions[index].source.comment = nil
        }
        let printer = PseudocodePrinter()
        let original = printer.print(function: function)
        XCTAssertTrue(function.retainsPhiControlPresentation)
        for index in function.instructions.indices {
            function.instructions[index].source.comment = "  source_\(index)\r\ncontinued  "
        }
        let document = printer.print(function: function)
        for (index, instruction) in function.instructions.enumerated() {
            let comment = "source_\(index)  continued"
            let matching = document.lines.filter { $0.text.contains(comment) }
            XCTAssertEqual(matching.count, 1, comment)
            XCTAssertEqual(matching.first?.sourceAddress, instruction.source.address)
            XCTAssertTrue(matching.first?.tokens.contains {
                $0.kind == .comment && $0.text.contains(comment)
            } == true, comment)
        }
        let controlLines = document.lines.compactMap { line -> String? in
            if line.text.trimmingCharacters(in: .whitespaces).hasPrefix("// source_") {
                return nil
            }
            return line.text.components(separatedBy: " // source_").first
        }
        XCTAssertEqual(controlLines, original.lines.map(\.text))
    }
}

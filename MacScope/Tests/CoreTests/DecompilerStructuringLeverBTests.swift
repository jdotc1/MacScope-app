import XCTest
@testable import MacScope

final class DecompilerStructuringLeverBTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func print(_ name: String, _ rows: [InstructionRow], ssaEnabled: Bool? = nil) -> PseudocodeDocument {
        let function = MacIRBuilder(ssaEnabled: ssaEnabled).buildFunction(name: name, instructions: rows)
        return PseudocodePrinter().print(function: function)
    }

    private func print(_ name: String, _ instructions: [MacIRInstruction]) -> PseudocodeDocument {
        let function = MacIRFunction(name: name, startAddress: instructions.first?.source.address ?? 0, instructions: instructions)
        return PseudocodePrinter().print(function: function)
    }

    private func irInstruction(
        _ address: UInt64,
        mnemonic: String,
        operands: String = "",
        _ operation: MacIROperation,
        comment: String? = nil
    ) -> MacIRInstruction {
        MacIRInstruction(
            source: MacIRSourceSpan(
                address: address,
                byteText: "00 00 00 00",
                mnemonic: mnemonic,
                operands: operands,
                comment: comment
            ),
            operation: operation
        )
    }

    private func gotoCount(_ document: PseudocodeDocument) -> Int {
        document.lines.reduce(0) { count, line in
            count + (line.text.contains("goto") ? 1 : 0)
        }
    }

    private func regions(in node: PseudocodeRegionNode?, kind: PseudocodeRegionNode.Kind) -> [PseudocodeRegionNode] {
        guard let node else { return [] }
        var matches: [PseudocodeRegionNode] = node.kind == kind ? [node] : []
        for child in node.children {
            matches.append(contentsOf: regions(in: child, kind: kind))
        }
        return matches
    }

    func testThreeWayCompareSharedCompareSecondBranchStructuresWithoutGoto() {
        let document = print("sub_0x1000008ec", [
            row(0x1000008fc, "cmp", "x8, x9"),
            row(0x100000900, "b.le", "0x10000090c", "first compare arm"),
            row(0x100000904, "mov", "w0, #0x1", "x8 greater"),
            row(0x100000908, "ret", ""),
            row(0x10000090c, "b.ge", "0x100000918", "second compare arm"),
            row(0x100000910, "mov", "w0, #0x2", "x8 less"),
            row(0x100000914, "ret", ""),
            row(0x100000918, "add", "x0, x0, #0x68", "tail setup"),
            row(0x10000091c, "b", "0x200000000", "tail call")
        ], ssaEnabled: false)

        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
        XCTAssertEqual(gotoCount(document), 0)
        // No unstructured conditional-branch intrinsic placeholder (`__branch_<suffix>`). The
        // out-of-function tail call legitimately renders as `__branch(0x…)` (Lever A) — asserted
        // at the end — so this guard must match the suffixed form only, not a bare `__branch`.
        XCTAssertFalse(document.text.contains("__branch_"))

        let ifNodes = regions(in: document.regionTree, kind: .ifThen)
        XCTAssertEqual(ifNodes.map(\.condition), ["x8_0 > x9_0", "x8_0 < x9_0"])
        XCTAssertEqual(ifNodes.map(\.conditionSourceAddress), [0x100000900, 0x10000090c])
        XCTAssertTrue(document.text.contains("if (x8_0 > x9_0) {"))
        XCTAssertTrue(document.text.contains("if (x8_0 < x9_0) {"))
        XCTAssertTrue(document.text.contains("// x8 greater"))
        XCTAssertTrue(document.text.contains("// x8 less"))
        XCTAssertTrue(document.text.contains("// tail setup"))
        XCTAssertTrue(document.text.contains("__branch(0x200000000); // tail call; unconditional branch"))
    }

    func testBranchSuffixIntrinsicStillVetoesRegionStructuring() {
        let document = print("_branch_suffix_guard", [
            irInstruction(
                0x1000,
                mnemonic: "b.ge",
                operands: "0x1008",
                .intrinsic(destination: nil, name: "branch_ge", arguments: [.immediate(0x1008)])
            ),
            irInstruction(0x1004, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "fallthrough"),
            irInstruction(0x1008, mnemonic: "ret", .returnValue(nil))
        ])

        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unsupportedRegion.rawValue)
        XCTAssertTrue(document.text.contains("__branch_ge(0x1008); // conditional branch"))
        XCTAssertFalse(document.text.contains("if ("))
    }

    func testLoopHeaderWithNonAdjacentCompareStillFallsBackToLegacy() {
        let document = print("_non_adjacent_loop", [
            row(0x1000, "cmp", "x8, x9"),
            row(0x1004, "b", "0x1008", "enter loop"),
            row(0x1008, "b.ge", "0x1014", "loop exit"),
            row(0x100c, "nop", "", "loop body"),
            row(0x1010, "b", "0x1008", "back-edge"),
            row(0x1014, "ret", "")
        ])

        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unsupportedRegion.rawValue)
        XCTAssertFalse(document.text.contains("while ("))
        XCTAssertFalse(document.text.contains("do {"))
        XCTAssertGreaterThan(gotoCount(document), 0)
        XCTAssertTrue(document.text.contains("// loop body"))
    }
}

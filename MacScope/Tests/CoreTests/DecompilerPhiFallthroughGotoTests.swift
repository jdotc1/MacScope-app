import XCTest
@testable import MacScope

/// DOT-G1: derived from the supplied dump's explicit L_<address> phi-CFG
/// listings, not from a new binary run. Preserve every edge-copy sequence.
final class DecompilerPhiFallthroughGotoTests: XCTestCase {
    private func instruction(_ address: UInt64, _ operation: MacIROperation) -> MacIRInstruction {
        MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "00 00 00 00",
            mnemonic: "nop", operands: ""), operation: operation)
    }
    private func branch(_ address: UInt64, _ target: Int64) -> MacIRInstruction {
        instruction(address, .intrinsic(destination: nil, name: "branch", arguments: [.immediate(target)]))
    }
    private func guardRow(_ address: UInt64, _ target: Int64) -> MacIRInstruction {
        instruction(address, .conditionalBranch(condition: "==", left: .register(name: "x0", version: 0),
            right: .immediate(0), target: .immediate(target)))
    }
    private func effect(_ address: UInt64, _ name: String) -> MacIRInstruction {
        instruction(address, .intrinsic(destination: nil, name: name, arguments: []))
    }
    private func phi(_ address: UInt64, _ predecessors: [UInt64]) -> MacIRPhi {
        MacIRPhi(blockAddress: address, destination: .register(name: "x1", version: 9), bitWidth: 64,
            incoming: predecessors.enumerated().map { index, predecessor in
                .init(predecessorAddress: predecessor, value: .immediate(Int64(index + 1)))
            })
    }
    private func text(_ rows: [MacIRInstruction], _ phis: [MacIRPhi]) -> String {
        PseudocodePrinter().print(function: MacIRFunction(name: "_phi_fallthrough", startAddress: 0x1000,
            instructions: rows, phis: phis)).text
    }
    private func successorFixture() -> String {
        text([guardRow(0x1000, 0x1010), effect(0x1004, "first_effect"), branch(0x1008, 0x100c),
              effect(0x100c, "second_effect"), instruction(0x1010, .returnValue(.immediate(7)))],
             [phi(0x1010, [0x1000, 0x100c])])
    }
    func testConditionalFallthroughOmitsOnlyLexicalSuccessorGoto() {
        let output = successorFixture()
        XCTAssertFalse(output.contains("goto L_1004;"))
        XCTAssertTrue(output.contains("goto L_1010;"), "The taken arm still needs its jump past the other edge")
        // 0x1004 is entered only by lexical fallthrough; no emitted goto names L_1004, so the label is dead and G1b suppresses it. The block itself must still be emitted in order.
        XCTAssertFalse(output.contains("L_1004:"), "Dead label: only a lexical-fallthrough edge enters 0x1004")
        XCTAssertTrue(output.contains("__first_effect()"), "The fallthrough block is still emitted")
    }
    func testUnconditionalNextBlockGotoIsOmitted() {
        XCTAssertFalse(successorFixture().contains("goto L_100c;"))
    }
    func testOrdinaryFallthroughOmitsGotoAfterPhiCopies() {
        let output = successorFixture()
        XCTAssertEqual(output.components(separatedBy: "goto L_1010;").count - 1, 1)
        XCTAssertTrue(output.contains("__edge_2_3_0"), "The fallthrough phi copy must not be dropped")
        XCTAssertTrue(output.contains("__edge_0_3_0"), "The taken phi copy must not be dropped")
    }
    func testIrreducibleCycleRetainsNonlexicalGotos() {
        let rows = [guardRow(0x1000, 0x1008), branch(0x1004, 0x100c), branch(0x1008, 0x100c),
                    guardRow(0x100c, 0x1004), instruction(0x1010, .returnValue(.immediate(7)))]
        let cfg = CFGBuilder.buildCFG(instructions: rows)
        XCTAssertFalse(cfg.irreducibleBlocks.isEmpty)
        let output = text(rows, [phi(0x100c, [0x1004, 0x1008])])
        XCTAssertTrue(output.contains("goto L_1004;"))
        XCTAssertTrue(output.contains("goto L_100c;"))
        XCTAssertTrue(output.contains("goto L_1008;"))
    }
    func testSharedSideEffectsAreNotDuplicatedOrReordered() {
        let output = text([guardRow(0x1000, 0x100c), effect(0x1004, "private_effect"), branch(0x1008, 0x1010),
                           effect(0x100c, "other_effect"), effect(0x1010, "shared_effect"),
                           instruction(0x1014, .returnValue(.immediate(7)))],
                          [phi(0x1010, [0x1008, 0x100c])])
        XCTAssertTrue(output.contains("goto L_1010;"), "Skipping the other side effect is mandatory")
        for marker in ["private_effect", "other_effect", "shared_effect"] {
            XCTAssertEqual(output.components(separatedBy: "__\(marker)()").count - 1, 1)
        }
        let other = output.range(of: "__other_effect()")!
        let shared = output.range(of: "__shared_effect()")!
        XCTAssertLessThan(other.lowerBound, shared.lowerBound)
    }
}

import XCTest
@testable import MacScope

/// Synthetic reductions of existing e04d53b2b dump shapes; no binary is loaded.
final class DecompilerDeadLabelTests: XCTestCase {
    private func row(_ address: UInt64, _ operation: MacIROperation) -> MacIRInstruction {
        MacIRInstruction(source: .init(address: address, byteText: "00 00 00 00",
            mnemonic: "nop", operands: ""), operation: operation)
    }
    private func effect(_ address: UInt64, _ name: String) -> MacIRInstruction {
        row(address, .intrinsic(destination: nil, name: name, arguments: []))
    }
    private func guardRow(_ address: UInt64, _ target: Int64) -> MacIRInstruction {
        row(address, .conditionalBranch(condition: "!=", left: .register(name: "x0", version: 0),
            right: .immediate(0), target: .immediate(target)))
    }
    private func phi(_ address: UInt64, _ predecessors: [UInt64]) -> MacIRPhi {
        MacIRPhi(blockAddress: address, destination: .register(name: "x1", version: 9), bitWidth: 64,
            incoming: predecessors.enumerated().map {
                .init(predecessorAddress: $0.element, value: .immediate(Int64($0.offset + 1)))
            })
    }
    private func text(_ rows: [MacIRInstruction], _ phis: [MacIRPhi]) -> String {
        PseudocodePrinter().print(function: MacIRFunction(name: "_dead_labels", startAddress: 0x1000,
            instructions: rows, phis: phis)).text
    }
    // _quantize_float: entry falls into a loop; the back edge still names the header.
    private func loop() -> String {
        text([effect(0x1000, "entry_effect"), effect(0x1004, "loop_effect"),
              guardRow(0x1008, 0x1004), row(0x100c, .returnValue(.immediate(7)))],
             [phi(0x1004, [0x1000, 0x1008])])
    }
    func testLexicalFallthroughHasNoLabel() {
        let output = text([guardRow(0x1000, 0x100c), effect(0x1004, "fallthrough_effect"),
                           effect(0x1008, "next_effect"), row(0x100c, .returnValue(.immediate(7)))],
                          [phi(0x100c, [0x1000, 0x1008])])
        XCTAssertFalse(output.contains("goto L_1004;"))
        XCTAssertFalse(output.contains("L_1004:"), output)
        XCTAssertTrue(output.contains("__fallthrough_effect()"), output)
    }
    func testBackwardGotoKeepsLoopLabel() {
        let output = loop()
        XCTAssertTrue(output.contains("goto L_1004;"), output)
        XCTAssertTrue(output.contains("L_1004:"), output)
        XCTAssertTrue(output.contains("__loop_effect()"), output)
    }
    func testGotoAndFallthroughKeepSharedLabel() {
        let output = text([guardRow(0x1000, 0x1008), effect(0x1004, "fallthrough_effect"),
                           effect(0x1008, "shared_effect"), row(0x100c, .returnValue(.immediate(7)))],
                          [phi(0x1008, [0x1000, 0x1004])])
        XCTAssertEqual(output.components(separatedBy: "goto L_1008;").count - 1, 1, output)
        XCTAssertTrue(output.contains("L_1008:"), output)
        XCTAssertTrue(output.contains("__shared_effect()"), output)
    }
    // _convsamp L_739c / _quantize_float L_6c80: entry labels were already dead before G1.
    func testPreexistingDeadEntryLabelIsRemoved() {
        let output = loop()
        XCTAssertFalse(output.contains("goto L_1000;"))
        XCTAssertFalse(output.contains("L_1000:"), output)
        XCTAssertTrue(output.contains("__entry_effect()"), output)
    }
}

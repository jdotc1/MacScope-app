import XCTest
@testable import MacScope

final class LegacyPhiIdentityRegressionTests: XCTestCase {
    // Five-row diamond with a live phi return. Keep cfg nil so the printer
    // derives the same compatibility CFG for both legacy and SSA presentation.
    private func diamond(takenValue: Int64 = 2, ssaEnabled: Bool = false,
                         vector: Bool = false) -> MacIRFunction {
        let register = vector ? "v8" : "x8"
        let fall = MacIRValue.register(name: register, version: 1)
        let taken = MacIRValue.register(name: register, version: 2)
        let joined = MacIRValue.register(name: register, version: 3)
        func row(_ address: UInt64, _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address,
                byteText: "00 00 00 00", mnemonic: "nop", operands: ""), operation: operation)
        }
        let rows = [
            row(0x1000, .conditionalBranch(condition: "==", left: .register(name: "x0", version: 0),
                right: .immediate(0), target: .immediate(0x100c))),
            row(0x1004, .assign(destination: fall, source: .immediate(1))),
            row(0x1008, .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1010)])),
            row(0x100c, .assign(destination: taken, source: .immediate(takenValue))),
            row(0x1010, .returnValue(joined))
        ]
        let phi = MacIRPhi(blockAddress: 0x1010, destination: joined, bitWidth: vector ? 128 : 64,
            incoming: [.init(predecessorAddress: 0x1008, value: fall),
                       .init(predecessorAddress: 0x100c, value: taken)],
            scalarView: .integer, cell: vector ? 40 : 8)
        var function = MacIRFunction(name: "legacy_phi_identity", startAddress: 0x1000,
            instructions: rows, phis: [phi])
        function.ssaEnabled = ssaEnabled
        return function
    }

    private func text(_ function: MacIRFunction) -> String {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        return PseudocodePrinter(options: options).print(function: function).text
    }

    private func assertLegacyCopies(_ output: String, type: String, register: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (predecessor, version) in [(1, 1), (2, 2)] {
            let snapshot = "__edge_\(predecessor)_3_0"
            XCTAssertTrue(output.contains("        const \(type) \(snapshot) = \(register)_\(version);"),
                output, file: file, line: line)
            XCTAssertTrue(output.contains("        \(register)_3 = \(snapshot);"),
                output, file: file, line: line)
        }
        XCTAssertFalse(output.contains("__unavailable_cfg_phi"), output, file: file, line: line)
    }

    func testLegacyPositivePhiKeepsSignedDeclaration() {
        let output = text(diamond())
        XCTAssertTrue(output.components(separatedBy: "\n").contains("    int64_t x8_3;"), output)
        XCTAssertFalse(output.contains("uint64_t x8_3;"), output)
        assertLegacyCopies(output, type: "int64_t", register: "x8")
    }

    func testLegacyNegativePhiKeepsSignedDeclaration() {
        let output = text(diamond(takenValue: -1))
        XCTAssertTrue(output.components(separatedBy: "\n").contains("    int64_t x8_3;"), output)
        XCTAssertTrue(output.contains("x8_2 = -0x1;"), output)
        assertLegacyCopies(output, type: "int64_t", register: "x8")
    }

    func testSSAPositivePhiRetainsUnsignedInference() {
        let output = text(diamond(ssaEnabled: true))
        XCTAssertTrue(output.components(separatedBy: "\n").contains("    uint64_t x8_3;"), output)
        XCTAssertFalse(output.contains("    int64_t x8_3;"), output)
        XCTAssertFalse(output.contains("__unavailable_cfg_phi"), output)
    }

    func testLegacyVectorPhiRetains128BitDeclaration() {
        let output = text(diamond(vector: true))
        XCTAssertTrue(output.components(separatedBy: "\n").contains("    __uint128_t v8_3;"), output)
        assertLegacyCopies(output, type: "__uint128_t", register: "v8")
    }
}

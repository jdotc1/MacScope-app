import Foundation
import XCTest
@testable import MacScope

final class MacIRFPEnvironmentTests: XCTestCase {
    private struct Witness: Decodable {
        struct Expected: Decodable {
            let bits: String
            let fpcr: UInt32
            let fpsr: UInt32
            let raised: UInt32
        }
        struct Observation: Decodable {
            struct Inputs: Decodable { let fpcr: UInt32; let fpsr: UInt32 }
            let inputs: Inputs
        }
        let id: String
        let op: String
        let width: Int
        let expected: Expected
        let observation: Observation
    }

    func testFAddCarriesSeparateArchitecturalInputsAndStatusOutput() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/a64-fp-environment-ir/add.json")
        let witnesses = try JSONDecoder().decode([Witness].self, from: Data(contentsOf: file))
        XCTAssertEqual(witnesses.count, 2)
        for witness in witnesses {
            XCTAssertEqual(witness.op, "add", witness.id)
            XCTAssertNotEqual(witness.observation.inputs.fpcr, 0, witness.id)
            XCTAssertNotEqual(witness.expected.raised, 0, witness.id)
            XCTAssertEqual(witness.expected.fpcr, witness.observation.inputs.fpcr, witness.id)
            XCTAssertEqual(witness.expected.fpsr,
                           witness.observation.inputs.fpsr | witness.expected.raised, witness.id)
            XCTAssertEqual(witness.expected.bits.count, witness.width / 4, witness.id)

            let lane = witness.width == 32 ? "s" : "d"
            let row = InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "fadd",
                                     operands: "\(lane)0, \(lane)1, \(lane)2",
                                     hasBreakpoint: false, comment: nil)
            var function = try XCTUnwrap(MacIRFPEnvironmentLifter.liftSingleFAdd(
                name: "cp14_\(witness.width)", instruction: row,
                fpcrInput: .immediate(Int64(witness.observation.inputs.fpcr)),
                fpsrInput: .immediate(Int64(witness.observation.inputs.fpsr))))
            let instruction = try XCTUnwrap(function.instructions.first)
            let effect = try XCTUnwrap(instruction.fpEnvironment)
            XCTAssertEqual(effect.operation, .add)
            XCTAssertEqual(effect.statusUpdate, .stickyOROfRaisedExceptions)
            XCTAssertEqual(effect.type.bitWidth, witness.width)
            XCTAssertEqual(effect.fpcrInput, .immediate(Int64(witness.observation.inputs.fpcr)))
            XCTAssertEqual(effect.fpsrInput, .immediate(Int64(witness.observation.inputs.fpsr)))
            XCTAssertEqual(effect.fpsrOutput, .register(name: "fpsr", version: 1))
            XCTAssertNil(instruction.scalarFP, "Default-FPCR numeric semantics must not be reused")
            guard case let .intrinsic(destination?, name, arguments) = instruction.operation else {
                return XCTFail("Expected environment-aware intrinsic")
            }
            XCTAssertEqual(destination, effect.numericResult)
            XCTAssertEqual(name, effect.intrinsicName)
            XCTAssertEqual(arguments, [effect.left, effect.right, effect.fpcrInput, effect.fpsrInput])

            // Rendering must use the typed effect after source diagnostics are
            // removed and must expose both the numeric and status outputs.
            function.instructions[0].source.mnemonic = "redacted"
            function.instructions[0].source.operands = ""
            let text = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(text.contains("__\(effect.intrinsicName)(&"), text)
            XCTAssertTrue(text.contains("&fpsr_1"), text)
            XCTAssertTrue(text.contains("0x\(String(witness.observation.inputs.fpcr, radix: 16)), 0x\(String(witness.observation.inputs.fpsr, radix: 16))"), text)
        }
        let refused = InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "fmul",
                                     operands: "s0, s1, s2", hasBreakpoint: false, comment: nil)
        XCTAssertNil(MacIRFPEnvironmentLifter.liftSingleFAdd(name: "refused", instruction: refused))
    }
}

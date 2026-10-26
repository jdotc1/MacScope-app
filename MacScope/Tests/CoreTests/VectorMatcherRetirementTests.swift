import XCTest
@testable import MacScope

final class VectorMatcherRetirementTests: XCTestCase {
    func testUnclaimedVectorRowsRemainUnknownWhileScalarReturnSurvives() {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "20 00 c0 3d", mnemonic: "ldr",
                operands: "q0, [x1]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "01 1c a0 4e", mnemonic: "orr",
                operands: "v1.16b, v0.16b, v0.16b", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "c0 03 5f d6", mnemonic: "ret",
                operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "retired_vector_matcher", instructions: rows)
        XCTAssertEqual(function.instructions.count, 3)
        guard case let .load(vector, _) = function.instructions[0].operation,
              case let .intrinsic(destination, _, arguments) = function.instructions[1].operation else {
            return XCTFail("expected modeled Q load and vector logical operation")
        }
        XCTAssertEqual(vector, .register(name: "v0", version: 1))
        XCTAssertEqual(function.instructions[0].memoryAccess?.byteWidth, 16)
        XCTAssertEqual(destination, .register(name: "v1", version: 1))
        XCTAssertEqual(arguments, [vector, vector])
        XCTAssertNotNil(function.instructions[1].neonLogical)
        if case .returnValue = function.instructions[2].operation {} else {
            XCTFail("the scalar return must remain intact")
        }
    }

    func testRefusedVectorWritebackCannotFeedLaterScalarAddress() {
        let rows = [
            InstructionRow(address: 0x2000, bytes: "", mnemonic: "mov",
                operands: "x1, #4096", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2004, bytes: "", mnemonic: "ldr",
                operands: "q0, [x1], #16", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2008, bytes: "", mnemonic: "ldr",
                operands: "x2, [x1]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x200c, bytes: "", mnemonic: "ret",
                operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "refused_q_writeback", instructions: rows)
        guard case let .assign(oldBase, _) = function.instructions[0].operation,
              case let .loadWriteback(vector, newBase, sourceBase, delta, preIndex) = function.instructions[1].operation,
              case let .load(_, laterAddress) = function.instructions[2].operation else {
            return XCTFail("expected scalar definition, modeled Q writeback, and later scalar load")
        }
        XCTAssertEqual(vector, .register(name: "v0", version: 1))
        XCTAssertEqual(sourceBase, oldBase)
        XCTAssertEqual(delta, 16)
        XCTAssertFalse(preIndex)
        XCTAssertEqual(function.instructions[1].memoryAccess?.byteWidth, 16)
        XCTAssertEqual(laterAddress, newBase)
        XCTAssertNotEqual(laterAddress, oldBase)

        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        let oldListBase = state.writeRegister("x1")
        let oldFirst = state.writeRegister("v0")
        let oldSecond = state.writeRegister("v1")
        let listLoad = InstructionRow(address: 0x3000, bytes: "", mnemonic: "ld1",
            operands: "{v0.16b, v1.16b}, [x1], #32", hasBreakpoint: false, comment: nil)
        _ = MacIRBuilder().generalVectorRefusal(listLoad, state: &state)
        XCTAssertNotEqual(state.readRegister("x1"), oldListBase)
        XCTAssertNotEqual(state.readRegister("v0"), oldFirst)
        XCTAssertNotEqual(state.readRegister("v1"), oldSecond)
    }
}

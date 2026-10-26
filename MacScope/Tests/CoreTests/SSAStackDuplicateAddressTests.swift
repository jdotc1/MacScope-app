import XCTest
@testable import MacScope

final class SSAStackDuplicateAddressTests: XCTestCase {
    private func rows(_ assembly: [(UInt64, String, String)]) -> [InstructionRow] {
        assembly.map { address, mnemonic, operands in
            InstructionRow(address: address, bytes: "", mnemonic: mnemonic,
                           operands: operands, hasBreakpoint: false, comment: nil)
        }
    }

    private func lift(_ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder(ssaEnabled: true).buildFunction(name: "stack_address_lookup",
            authoritativeReturnLocation: .void, instructions: rows)
    }

    func testDuplicateNopAddressesDoNotTrap() throws {
        let function = lift(rows([(0x100, "nop", ""), (0x100, "nop", ""), (0x104, "ret", "")]))
        let info = try XCTUnwrap(function.ssaInfo)
        XCTAssertTrue(function.ssaEnabled)
        XCTAssertEqual(info.sourceAddresses, [0x100, 0x100, 0x104])
        XCTAssertEqual(info.plan.rowReadBindings.count, 3)
        XCTAssertEqual(info.plan.rowWriteBindings.count, 3)
        XCTAssertEqual(function.instructions.map(\.source.address), [0x100, 0x100, 0x104])
        XCTAssertTrue(function.refusals.isEmpty)
    }

    func testUniqueNopAddressesKeepExistingResult() throws {
        let function = lift(rows([(0x100, "nop", ""), (0x104, "nop", ""), (0x108, "ret", "")]))
        let info = try XCTUnwrap(function.ssaInfo)
        XCTAssertTrue(function.ssaEnabled)
        XCTAssertEqual(info.sourceAddresses, [0x100, 0x104, 0x108])
        XCTAssertEqual(info.plan.rowReadBindings.count, 3)
        XCTAssertEqual(info.plan.rowWriteBindings.count, 3)
        XCTAssertTrue(function.refusals.isEmpty)
        XCTAssertTrue(info.plan.refusals.isEmpty)
        // Literal instruction golden from the pinned NOP/RET lifting paths.
        XCTAssertEqual(function.instructions, [
            MacIRInstruction(source: .init(address: 0x100, byteText: "", mnemonic: "nop", operands: ""),
                             operation: .intrinsic(destination: nil, name: "nop", arguments: [])),
            MacIRInstruction(source: .init(address: 0x104, byteText: "", mnemonic: "nop", operands: ""),
                             operation: .intrinsic(destination: nil, name: "nop", arguments: [])),
            MacIRInstruction(source: .init(address: 0x108, byteText: "", mnemonic: "ret", operands: ""),
                             operation: .returnValue(nil))
        ])
    }

    func testRepeatedStackDefinitionUsesFirstRowBindings() throws {
        let function = lift(rows([(0x100, "sub", "sp, sp, #16"),
                                  (0x100, "sub", "sp, sp, #16"), (0x104, "ret", "")]))
        let info = try XCTUnwrap(function.ssaInfo)
        let first = try XCTUnwrap(info.plan.rowWriteBindings[0][31])
        let second = try XCTUnwrap(info.plan.rowWriteBindings[1][31])
        XCTAssertNotEqual(first, second, "Repeated source addresses must retain distinct row definitions")
        XCTAssertEqual(info.plan.definitions[first].origin, .instruction(0x100))
        XCTAssertEqual(info.plan.definitions[second].origin, .instruction(0x100))
        XCTAssertEqual(info.stackOffsets[first], -16)
        XCTAssertEqual(info.stackOffsets[second], -16, "Both origins use the first row's entry-SP binding")
        XCTAssertEqual(info.sourceAddresses, [0x100, 0x100, 0x104])
        XCTAssertEqual(info.plan.rowWriteBindings.count, 3)
        XCTAssertEqual(function.instructions.map(\.source.address), [0x100, 0x100, 0x104])
    }

    func testUniqueStackDefinitionsAccumulateOffsets() throws {
        let function = lift(rows([(0x100, "sub", "sp, sp, #16"),
                                  (0x104, "sub", "sp, sp, #16"), (0x108, "ret", "")]))
        let info = try XCTUnwrap(function.ssaInfo)
        let first = try XCTUnwrap(info.plan.rowWriteBindings[0][31])
        let second = try XCTUnwrap(info.plan.rowWriteBindings[1][31])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(info.plan.rowReadBindings[1][31], first)
        XCTAssertEqual(info.plan.definitions[first].origin, .instruction(0x100))
        XCTAssertEqual(info.plan.definitions[second].origin, .instruction(0x104))
        XCTAssertEqual(info.stackOffsets[first], -16)
        XCTAssertEqual(info.stackOffsets[second], -32)
        XCTAssertEqual(info.sourceAddresses, [0x100, 0x104, 0x108])
    }
}

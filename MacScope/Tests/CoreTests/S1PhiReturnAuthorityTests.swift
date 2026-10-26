import Foundation
import XCTest
@testable import MacScope

final class S1PhiReturnAuthorityTests: XCTestCase {
    // These words were assembled and disassembled with retained Linux LLVM.
    // This is not an Apple llvm-objdump claim. No decoder changes are required.
    private let entryLoop: [UInt32] = [
        0x4f00e4e0, 0x14000001, 0xb4000060, 0x6e201c00, 0x17fffffe, 0xd65f03c0
    ]
    private let straight: [UInt32] = [0x4f00e4e0, 0xaa0003e9, 0x6e201c00, 0xd65f03c0]

    private func rows(_ words: [UInt32], mnemonics: [String],
                      file: StaticString = #filePath, line: UInt = #line) -> [InstructionRow] {
        let bytes = words.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: 0x1000,
                                             maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count, file: file, line: line)
        XCTAssertEqual(decoded.map(\.mnemonic), mnemonics, file: file, line: line)
        for (index, row) in decoded.enumerated() {
            XCTAssertEqual(row.address, 0x1000 + UInt64(index * 4), file: file, line: line)
            XCTAssertEqual(row.bytes, Array(bytes[(index * 4)..<(index * 4 + 4)]), file: file, line: line)
        }
        return decoded.map {
            InstructionRow(address: $0.address, bytes: $0.byteText, mnemonic: $0.mnemonic,
                           operands: $0.operands, hasBreakpoint: false, comment: $0.comment)
        }
    }

    private func x0Phis(_ function: MacIRFunction) -> [MacIRPhi] {
        function.phis.filter {
            if case .register(name: "x0", version: _) = $0.destination { return true }
            return false
        }
    }

    private func returned(_ function: MacIRFunction,
                          file: StaticString = #filePath, line: UInt = #line) throws -> MacIRValue? {
        let instruction = try XCTUnwrap(function.instructions.last, file: file, line: line)
        guard case let .returnValue(value) = instruction.operation else {
            XCTFail("fixture must retain its final RET", file: file, line: line)
            return nil
        }
        XCTAssertEqual(function.returnValue, value, file: file, line: line)
        return value
    }

    private func entryOnlyLoop(width: MacIRCallerReturnEvidence.Width? = nil,
                               file: StaticString = #filePath, line: UInt = #line) throws -> MacIRFunction {
        let decoded = rows(entryLoop, mnemonics: ["movi", "b", "cbz", "eor", "b", "ret"],
                           file: file, line: line)
        XCTAssertEqual(decoded[2].operands, "x0, 0x0000000000001014", file: file, line: line)
        XCTAssertEqual(decoded[4].operands, "0x0000000000001008", file: file, line: line)
        let function = MacIRBuilder().buildFunction(name: "entry_only_loop",
            callerReturnWidth: width, instructions: decoded)
        let phi = try XCTUnwrap(x0Phis(function).first, file: file, line: line)
        XCTAssertEqual(phi.blockAddress, 0x1008, file: file, line: line)
        XCTAssertEqual(phi.incoming.count, 2, file: file, line: line)
        XCTAssertTrue(phi.incoming.contains { $0.value == .argument(bindingID: .gpr(0)) },
                      file: file, line: line)
        XCTAssertTrue(phi.incoming.contains { $0.value == phi.destination }, file: file, line: line)
        XCTAssertNotNil(function.instructions.first { $0.source.address == 0x100c }?.neonLogical,
                        "fixture must activate the actual vector CFG route", file: file, line: line)
        return function
    }

    private func assertEntryOnlyRefusal(file: StaticString = #filePath, line: UInt = #line) throws {
        let function = try entryOnlyLoop(file: file, line: line)
        XCTAssertEqual(try returned(function, file: file, line: line),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
                       "an entry-only phi is not an x0 producer", file: file, line: line)
    }

    func testUntouchedLoopRetainsPassThroughPolicyWithAndWithoutCallerWidth() throws {
        let straightRows = rows(straight, mnemonics: ["movi", "mov", "eor", "ret"])
        let plain = MacIRBuilder().buildFunction(name: "entry_only_straight", instructions: straightRows)
        XCTAssertTrue(plain.phis.isEmpty)
        XCTAssertEqual(try returned(plain),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        try assertEntryOnlyRefusal()

        for width: MacIRCallerReturnEvidence.Width in [.x0, .w0] {
            let loop = try entryOnlyLoop(width: width)
            let phi = try XCTUnwrap(x0Phis(loop).first)
            let expected: MacIRValue = width == .w0
                ? .unary(op: "(uint32_t)", value: phi.destination) : phi.destination
            XCTAssertEqual(try returned(loop), expected)
            let leaf = MacIRBuilder().buildFunction(name: "entry_only_straight",
                callerReturnWidth: width, instructions: straightRows)
            let argument = MacIRValue.argument(bindingID: .gpr(0))
            XCTAssertEqual(try returned(leaf), width == .w0
                ? .unary(op: "(uint32_t)", value: argument) : argument)
            if width == .w0 {
                XCTAssertEqual(loop.returnType, "uint32_t")
                XCTAssertEqual(leaf.returnType, "uint32_t")
            }
        }
    }

    func testOneRealX0IncomingNeedsReturnContract() throws {
        let decoded = rows([0x4f00e4e0, 0x14000001, 0xb4000080, 0x6e201c00,
                            0xd28000e0, 0x17fffffd, 0xd65f03c0],
                           mnemonics: ["movi", "b", "cbz", "eor", "mov", "b", "ret"])
        let function = MacIRBuilder().buildFunction(name: "real_x0_incoming", instructions: decoded)
        let phi = try XCTUnwrap(x0Phis(function).first)
        let move = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
        guard case let .assign(destination, .immediate(7)) = move.operation else {
            return XCTFail("control must contain a real x0 write")
        }
        XCTAssertTrue(phi.incoming.contains { $0.value == .argument(bindingID: .gpr(0)) })
        XCTAssertTrue(phi.incoming.contains { $0.value == destination })
        XCTAssertEqual(try returned(function),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        // A real incoming write proves data flow, not a result contract.
        // Entry-only joins must remain unresolved as well.
        try assertEntryOnlyRefusal()
    }

    func testNestedEntryOnlyPhiCyclesDoNotEstablishProducer() throws {
        let decoded = rows([0x4f00e4e0, 0x14000001, 0xb40000c0, 0x14000001,
                            0xb4000061, 0x6e201c00, 0x17fffffe, 0xb5ffff62, 0xd65f03c0],
                           mnemonics: ["movi", "b", "cbz", "b", "cbz", "eor", "b", "cbnz", "ret"])
        let function = MacIRBuilder().buildFunction(name: "nested_entry_phis", instructions: decoded)
        let phis = x0Phis(function)
        XCTAssertGreaterThanOrEqual(phis.count, 2)
        let destinations = Set(phis.map(\.destination))
        XCTAssertTrue(phis.flatMap(\.incoming).allSatisfy {
            $0.value == .argument(bindingID: .gpr(0)) || destinations.contains($0.value)
        })
        XCTAssertNotNil(function.instructions.first { $0.source.address == 0x1014 }?.neonLogical)
        XCTAssertEqual(try returned(function),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testW0BackedgeWriteNeedsReturnContractAfterResolution() throws {
        let decoded = rows([0x4f00e4e0, 0x14000001, 0xb4000080, 0x6e201c00,
                            0x528000e0, 0x17fffffd, 0xd65f03c0],
                           mnemonics: ["movi", "b", "cbz", "eor", "mov", "b", "ret"])
        let function = MacIRBuilder().buildFunction(name: "real_w0_backedge", instructions: decoded)
        let phi = try XCTUnwrap(x0Phis(function).first)
        let move = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
        guard case let .assign(destination, .immediate(7)) = move.operation,
              case .register(name: "w0", version: _) = destination else {
            return XCTFail("only the backedge must define the physical return register, via w0")
        }
        XCTAssertEqual(phi.incoming.first { $0.machineAddress == 0x1014 }?.value,
                       .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: destination)))
        XCTAssertEqual(phi.incoming.first { $0.machineAddress == 0x1004 }?.value,
                       .argument(bindingID: .gpr(0)))
        XCTAssertEqual(try returned(function),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        // The backedge write proves data flow, not a result contract.
        // Keep the entry-only refusal paired with the real-write case.
        try assertEntryOnlyRefusal()
    }

    func testReverseAddressRetDoesNotGuessUnavailableBackedgeProducer() throws {
        let decoded = rows([0x4f00e4e0, 0x14000002, 0xd65f03c0, 0xb4ffffe0,
                            0x6e201c00, 0x528000e0, 0xb5ffffa1, 0xd65f03c0],
                           mnemonics: ["movi", "b", "ret", "cbz", "eor", "mov", "cbnz", "ret"])
        XCTAssertEqual(decoded[1].operands, "0x000000000000100c")
        XCTAssertEqual(decoded[3].operands, "x0, 0x0000000000001008")
        let function = MacIRBuilder().buildFunction(name: "reverse_address_ret", instructions: decoded)
        let early = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
        guard case let .returnValue(value) = early.operation else {
            return XCTFail("early RET must remain an explicit return operation")
        }
        // Existing source-order composition has no outgoing state for the
        // later-address predecessor here. Preserve its unavailable-state
        // refusal; nil is NOT a new proof of void or a resolved return contract.
        // The two-file producer filter does not retroactively revisit this RET.
        XCTAssertEqual(value, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        let write = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1014 })
        guard case let .assign(destination, .immediate(7)) = write.operation else {
            return XCTFail("late block must retain its actual w0 write")
        }
        XCTAssertEqual(try returned(function), .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertFalse(x0Phis(function).isEmpty)
        // Paired regression supplies this selector's genuine behavioral red.
        try assertEntryOnlyRefusal()
    }

    func testUnprovenPhiWithoutBoundX0IsUnresolvedNotVoid() throws {
        let noParameters = try XCTUnwrap(MacIRAuthoritativeParameterPlan(parameters: [], isVariadic: false))
        let decoded = rows(entryLoop, mnemonics: ["movi", "b", "cbz", "eor", "b", "ret"])
        for width: MacIRCallerReturnEvidence.Width? in [nil, .x0, .w0] {
            let function = MacIRBuilder().buildFunction(name: "unbound_entry_phi",
                authoritativeParameterPlan: noParameters, callerReturnWidth: width, instructions: decoded)
            XCTAssertTrue(function.parameters.isEmpty, "the filter must not invent an x0 parameter")
            let phi = try XCTUnwrap(x0Phis(function).first)
            XCTAssertTrue(phi.incoming.contains { $0.value == .register(name: "x0", version: 0) })
            XCTAssertTrue(phi.incoming.contains { $0.value == phi.destination })
            XCTAssertEqual(try returned(function),
                           .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
                           "rejecting a synthetic producer is not proof of void")
            XCTAssertNotEqual(function.returnType, "void")
        }

        // A supplied return contract remains authoritative without inventing
        // a formal parameter, and explicit void remains a distinct outcome.
        let authored = MacIRBuilder().buildFunction(name: "authored_unbound_phi",
            authoritativeParameterPlan: noParameters,
            authoritativeReturnLocation: .single(.gpr(index: 0, carrierWidth: 64)), instructions: decoded)
        XCTAssertEqual(try returned(authored), try XCTUnwrap(x0Phis(authored).first).destination)
        let void = MacIRBuilder().buildFunction(name: "authored_void_phi",
            authoritativeParameterPlan: noParameters, authoritativeReturnLocation: .void, instructions: decoded)
        XCTAssertNil(try returned(void))

        let realRows = rows([0x4f00e4e0, 0x14000001, 0xb4000080, 0x6e201c00,
                             0xd28000e0, 0x17fffffd, 0xd65f03c0],
                            mnemonics: ["movi", "b", "cbz", "eor", "mov", "b", "ret"])
        let real = MacIRBuilder().buildFunction(name: "unbound_real_producer",
            authoritativeParameterPlan: noParameters, instructions: realRows)
        XCTAssertTrue(real.parameters.isEmpty)
        XCTAssertEqual(try returned(real),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        // Earlier unavailable/unmodeled handling is outside this narrow case.
        var unavailable = BuilderState()
        unavailable.recordUnmodeledDefiniteWrite(for: "x0")
        XCTAssertEqual(unavailable.preferredReturnValue(), .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }
}

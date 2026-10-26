import XCTest
@testable import MacScope

/// Synthetic return joins require an enclosing result contract.
final class SyntheticPhiReturnContractTests: XCTestCase {
    private let phi = MacIRValue.register(name: "x0", version: 7)

    private func joinedState(realIncomingWrite: Bool) -> BuilderState {
        var state = BuilderState()
        state.currentIntegerDefinitionByIndex[0] = IntegerRegisterDefinition(
            value: phi, width: 64, isSyntheticReturnPhi: true)
        state.registerVersions["x0"] = 7
        if realIncomingWrite { state.resolvedX0PhiReturnProducers.insert(phi) }
        return state
    }

    func testCallerConfirmedValuePhiKeepsValueAndWidth() {
        for width: MacIRCallerReturnEvidence.Width in [.x0, .w0] {
            var state = joinedState(realIncomingWrite: true)
            state.callerReturnWidth = width
            let expected: MacIRValue = width == .w0
                ? .unary(op: "(uint32_t)", value: phi) : phi
            XCTAssertEqual(state.preferredReturnValue(), expected)
            if width == .w0 {
                XCTAssertEqual(state.returnType, "uint32_t")
                XCTAssertEqual(state.valueTypeHints[expected], "uint32_t")
            }
        }
    }

    func testSeededPhiDoesNotEstablishOwnReturnContract() {
        // An incoming write seeds the existing producer summary. That summary
        // establishes data flow, not the enclosing function's return contract.
        var state = joinedState(realIncomingWrite: true)
        XCTAssertEqual(state.preferredReturnValue(),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testEntryOnlyPhiKeepsExistingUnresolvedPolicy() {
        var state = joinedState(realIncomingWrite: false)
        XCTAssertEqual(state.preferredReturnValue(),
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testAuthoritativeVoidAndValueContractsWin() {
        var value = joinedState(realIncomingWrite: true)
        value.authoritativeReturnLocation = .single(.gpr(index: 0, carrierWidth: 64))
        value.callerReturnWidth = .w0
        XCTAssertEqual(value.preferredReturnValue(), phi)
        var void = joinedState(realIncomingWrite: true)
        void.authoritativeReturnLocation = .void
        void.callerReturnWidth = .x0
        XCTAssertNil(void.preferredReturnValue())
    }

    func testConcreteWriteAfterPhiRemainsTheResult() throws {
        for register in ["x0", "w0"] {
            var state = joinedState(realIncomingWrite: true)
            let written = state.writeRegister(register)
            XCTAssertFalse(try XCTUnwrap(state.currentIntegerDefinitionByIndex[0]).isSyntheticReturnPhi)
            XCTAssertEqual(state.preferredReturnValue(), .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        }
    }

    func testAuthoritativeConcreteWriteAfterPhiRemainsTheResult() {
        for register in ["x0", "w0"] {
            var state = joinedState(realIncomingWrite: true)
            state.authoritativeReturnLocation = .single(.gpr(index: 0, carrierWidth: register == "w0" ? 32 : 64))
            let written = state.writeRegister(register)
            XCTAssertEqual(state.preferredReturnValue(), written)
        }
    }

    func testActualMixedEntryAndRealWriteVectorCFGNeedsContract() throws {
        // Same control-flow shape as S1PhiReturnAuthorityTests' real-x0
        // backedge fixture, using instruction rows rather than another decode.
        let source: [(String, String)] = [
            ("movi", "v0.16b, #0x7"), ("b", "0x1008"),
            ("cbz", "x0, 0x1018"), ("eor", "v0.16b, v0.16b, v0.16b"),
            ("mov", "x0, #0x7"), ("b", "0x1008"), ("ret", ""),
        ]
        let rows = source.enumerated().map { index, instruction in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00000000",
                mnemonic: instruction.0, operands: instruction.1,
                hasBreakpoint: false, comment: nil)
        }
        let builder = MacIRBuilder()
        let unresolved = builder.buildFunction(name: "mixed_join", instructions: rows)
        XCTAssertNotNil(unresolved.instructions.first { $0.source.address == 0x100c }?.neonLogical)
        let join = try XCTUnwrap(unresolved.phis.first {
            if case .register(name: "x0", version: _) = $0.destination { return true }
            return false
        })
        XCTAssertTrue(join.incoming.contains { $0.value == .argument(bindingID: .gpr(0)) })
        XCTAssertTrue(join.incoming.contains { $0.value != join.destination &&
            $0.value != .argument(bindingID: .gpr(0)) })
        XCTAssertEqual(unresolved.returnValue,
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        let witnessed = builder.buildFunction(name: "mixed_join",
            callerReturnWidth: .x0, instructions: rows)
        XCTAssertEqual(witnessed.returnValue, join.destination)
        let value = builder.buildFunction(name: "mixed_join",
            authoritativeReturnLocation: .single(.gpr(index: 0, carrierWidth: 64)),
            authoritativeReturnType: "uint64_t", instructions: rows)
        XCTAssertEqual(value.returnValue, join.destination)
        let void = builder.buildFunction(name: "mixed_join",
            authoritativeReturnLocation: .void, authoritativeReturnType: "void", instructions: rows)
        XCTAssertNil(void.returnValue)
        for instruction in void.instructions {
            if case let .returnValue(result) = instruction.operation { XCTAssertNil(result) }
        }
    }

    func testVectorLoopWithConcreteWriteAfterPhiKeepsResult() throws {
        let source: [(String, String)] = [
            ("movi", "v0.16b, #0x7"), ("b", "0x1008"),
            ("cbz", "x0, 0x1018"), ("eor", "v0.16b, v0.16b, v0.16b"),
            ("mov", "x0, #0x7"), ("b", "0x1008"),
            ("mov", "x0, #0x9"), ("ret", ""),
        ]
        let rows = source.enumerated().map { index, instruction in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00000000",
                mnemonic: instruction.0, operands: instruction.1,
                hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "concrete_after_join", instructions: rows)
        XCTAssertTrue(function.phis.contains {
            if case .register(name: "x0", version: _) = $0.destination { return true }
            return false
        })
        let write = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1018 })
        guard case let .assign(destination, .immediate(9)) = write.operation else {
            return XCTFail("terminal block must retain its concrete x0 write")
        }
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

}

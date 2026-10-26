import XCTest
@testable import MacScope

/// Fresh original55 admission witnesses only; no dynamic-post or composition route.
final class MacIRNEONContiguousGroupFormalAuthorityTests: XCTestCase {
    private func formal(_ index: Int, width: Int, row: String = "formal") throws -> MacIRFunctionParameter {
        try XCTUnwrap(MacIRFunctionParameter(id: .init(rawValue: row), bindingID: .gpr(index),
            sourcePosition: 0, abiLocation: .gpr(index: index, carrierWidth: width),
            type: width == 64 ? "uint64_t" : "uint32_t", evidence: .authoritativeUser))
    }

    private func copy(parameters: [MacIRFunctionParameter] = [], fixedPost: Bool,
                      loadBase: MacIRValue = .register(name: "x1", version: 0),
                      storeBase: MacIRValue = .register(name: "x2", version: 0),
                      reuseUpdatedLoadBase: Bool = false) throws -> MacIRFunction {
        var instructions: [MacIRInstruction] = []
        var sequence = 0
        func append(_ effect: MacIRNEONBufferMemory.Effect, base: String, old: MacIRValue,
                    vectorVersion: Int, baseVersion: Int) throws {
            let frame = try XCTUnwrap(MacIRNEONContiguousGroup(effect: effect, activeBytes: 8,
                baseRegister: base, oldBase: old, vectors: [.register(name: "v0", version: vectorVersion)],
                baseDestination: fixedPost ? .register(name: base, version: baseVersion) : nil,
                frameSequence: sequence, firstByteSequence: sequence * 8))
            let source = MacIRSourceSpan(address: 4096 + UInt64(sequence * 4), byteText: "",
                mnemonic: "erased", operands: "")
            for ordinal in 0..<frame.effectCount {
                instructions.append(.init(source: source, operation: frame.operation(ordinal),
                    memoryAccess: ordinal < frame.groupCount ? .init(byteWidth: 8) : nil,
                    neonContiguousGroup: .init(frame: frame, ordinal: ordinal)))
            }
            sequence += 1
        }
        try append(.load, base: "x1", old: loadBase, vectorVersion: 1, baseVersion: 1)
        try append(.store, base: "x2", old: storeBase, vectorVersion: 1, baseVersion: 1)
        if reuseUpdatedLoadBase {
            try append(.load, base: "x1", old: .register(name: "x1", version: 1),
                vectorVersion: 2, baseVersion: 2)
        }
        instructions.append(.init(source: .init(address: 4096 + UInt64(sequence * 4), byteText: "",
            mnemonic: "erased", operands: ""), operation: .returnValue(nil),
            returnTarget: .register(name: "x30", version: 0)))
        return MacIRFunction(name: "original55-formal-authority", startAddress: 4096,
            parameters: parameters, instructions: instructions)
    }

    private func machine() throws -> A64MachineState {
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        state.x[1] = 0x1000
        state.x[2] = 0x2000
        state.v[0] = .init(low: 0xaaaa, high: 0xbbbb)
        state.setByte(0x71, at: 0x1000)
        state.setByte(0x92, at: 0x2000)
        return state
    }

    func testNarrowPhysicalLoadAndLaterStoreRefuseBeforePayload() throws {
        for fixedPost in [false, true] {
            for index in [1, 2] {
                let parameter = try formal(index, width: 32)
                XCTAssertEqual(parameter.register, "w\(index)")
                let function = try copy(parameters: [parameter], fixedPost: fixedPost)
                let initial = try machine()
                var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
                XCTAssertThrowsError(try evaluator.run(function.instructions)) { error in
                    guard case MacIRConcreteEvaluator.Failure.unsupported("contiguous group current base/formal") = error else {
                        return XCTFail("Expected original55 physical formal refusal, got \(error)")
                    }
                }
                // Index 2 is the later store: even the earlier load must not run.
                XCTAssertEqual(evaluator.state, initial)
                XCTAssertTrue(evaluator.ssa.isEmpty)
                XCTAssertTrue(evaluator.writtenGPRs.isEmpty)
                XCTAssertTrue(evaluator.writtenVectors.isEmpty)
            }
        }
    }

    func testUnboundRawBasesAndUnique64BitArgumentsRemainAdmitted() throws {
        for fixedPost in [false, true] {
            let raw = try copy(fixedPost: fixedPost)
            let rawEvaluator = MacIRConcreteEvaluator(function: raw, state: try machine())
            XCTAssertNoThrow(try rawEvaluator.validateNEONContiguousGroup(raw.instructions))
            let projected = try copy(parameters: [formal(1, width: 64), formal(2, width: 64, row: "store")],
                fixedPost: fixedPost, loadBase: .argument(bindingID: .gpr(1)),
                storeBase: .argument(bindingID: .gpr(2)))
            let evaluator = MacIRConcreteEvaluator(function: projected, state: try machine())
            XCTAssertNoThrow(try evaluator.validateNEONContiguousGroup(projected.instructions))
        }
    }

    func testCurrentPostUpdateBaseRemainsAdmittedWithFormal() throws {
        let function = try copy(parameters: [formal(1, width: 64)], fixedPost: true,
            loadBase: .argument(bindingID: .gpr(1)), reuseUpdatedLoadBase: true)
        let evaluator = MacIRConcreteEvaluator(function: function, state: try machine())
        XCTAssertNoThrow(try evaluator.validateNEONContiguousGroup(function.instructions))
    }

    func testNarrowAndDuplicateArgumentProjectionsRemainRefused() throws {
        let narrow = try formal(1, width: 32)
        let wide = try formal(1, width: 64)
        for parameters in [[narrow], [wide, try formal(1, width: 64, row: "duplicate")]] {
            let function = try copy(parameters: parameters, fixedPost: false,
                loadBase: .argument(bindingID: .gpr(1)))
            let evaluator = MacIRConcreteEvaluator(function: function, state: try machine())
            XCTAssertThrowsError(try evaluator.validateNEONContiguousGroup(function.instructions))
        }
    }
}

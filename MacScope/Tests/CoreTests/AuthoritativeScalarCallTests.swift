import XCTest
@testable import MacScope

final class AuthoritativeScalarCallTests: XCTestCase {
    private func contract(_ result: String, _ types: [String]) -> FunctionSignatureOverride {
        FunctionSignatureOverride(returnType: result,
            parameterList: .authoritative(types.enumerated().map { index, type in
                ArgOverride(rowToken: "parameter-\(index)", name: "arg\(index)",
                            type: type, provenance: .user)
            }), variadicState: .fixed)
    }

    private func build(_ operations: [(String, String)], start: UInt64,
                       target: String, signature: FunctionSignatureOverride) -> MacIRFunction {
        let rows = operations.enumerated().map { index, operation in
            InstructionRow(address: start + UInt64(index * 4), bytes: "",
                mnemonic: operation.0, operands: operation.1,
                hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
            name: "_scalar_call_fixture", startAddress: start,
            authoredCallSignaturesByTarget: [target: signature], instructions: rows)
    }

    // Retained render L44: x0_5 = _jinit_memory_mgr(x0_4).
    // Official src/jmemmgr.c:1193-1196 defines void jinit_memory_mgr(cinfo).
    // Retained listing 0xd7c MOV x0,x19; 0xd80 BL _jinit_memory_mgr.
    func testImportedVoidScalarContractSuppressesOnlyTheInventedResult() throws {
        let function = build([("mov", "x0, x19"), ("bl", "_jinit_memory_mgr"), ("ret", "")],
            start: 0xd7c, target: "_jinit_memory_mgr", signature: contract("void", ["void *"]))
        let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0xd80 })
        guard case let .call(frame, result) = call.operation else {
            return XCTFail("expected preserved call")
        }
        XCTAssertNil(result)
        XCTAssertEqual(frame.knownSignature?.returnType, "void")
        XCTAssertEqual(frame.denseFixedRenderValues().count, 1)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_jinit_memory_mgr("), text)
        XCTAssertFalse(text.contains("= _jinit_memory_mgr("), text)
    }

    // Retained finish_pass_gather_phuff 0x1ceb8 renders two arguments to
    // jpeg_alloc_huff_table, although src/jcomapi.c:234-235 declares exactly one.
    // The x1 load before 0x1cf50 is a table lookup, not a second source argument.
    // Retained render L40800 supplies that stale second argument. This fixture
    // minimizes the setup: synthetic MOV x1,x20 replaces the real LDR/CBNZ,
    // while MOV x0,x19 and BL at 0x1cf4c/0x1cf50 retain their exact addresses.
    func testFixedArityRejectsStaleExtraRegisterWithoutDroppingRealResult() throws {
        let function = build([("mov", "x1, x20"), ("mov", "x0, x19"),
                              ("bl", "_jpeg_alloc_huff_table"), ("ret", "")],
            start: 0x1cf48, target: "_jpeg_alloc_huff_table",
            signature: contract("void *", ["void *"]))
        let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1cf50 })
        guard case let .call(frame, result) = call.operation else {
            return XCTFail("expected preserved call")
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(frame.knownSignature?.parameters.count, 1)
        XCTAssertEqual(frame.denseFixedRenderValues().count, 1)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("= _jpeg_alloc_huff_table("), text)
    }

    func testIndependentIntegerAndFloatingRegisterBanks() throws {
        var state = BuilderState()
        state.authoredCallSignaturesByTarget["_mixed"] = contract("double", ["int32_t", "double", "void *", "float"])
        let signature = try XCTUnwrap(state.authoredScalarCallSignature(target: "_mixed"))
        XCTAssertEqual(signature.parameters.map(\.register), ["w0", "d0", "x1", "s1"])
    }

    func testUnspecifiedVariadicAggregateAndStackShapesRemainUnchanged() {
        var state = BuilderState()
        state.authoredCallSignaturesByTarget["_unspecified"] = FunctionSignatureOverride(returnType: "void")
        var variadic = contract("int32_t", ["void *"])
        variadic.variadicState = .variadic
        state.authoredCallSignaturesByTarget["_variadic"] = variadic
        state.authoredCallSignaturesByTarget["_aggregate"] = contract("struct opaque", ["void *"])
        state.authoredCallSignaturesByTarget["_stack"] = contract("void", Array(repeating: "uint64_t", count: 9))
        state.authoredCallSignaturesByTarget["_noncanonical"] = contract(" void ", [])
        state.authoredCallSignaturesByTarget["_unknown_parameter"] = contract("void", ["unresolved_type"])
        state.authoredCallSignaturesByTarget["_aggregate_parameter"] = contract("void", ["struct opaque"])
        state.authoredCallSignaturesByTarget["_fp_stack"] = contract("void", Array(repeating: "double", count: 9))
        for target in ["_unspecified", "_variadic", "_aggregate", "_stack", "_noncanonical", "_unknown_parameter", "_aggregate_parameter", "_fp_stack", "_absent"] {
            XCTAssertNil(state.authoredScalarCallSignature(target: target), target)
        }
    }

    func testFixedEmptyListIsNotUnspecified() throws {
        var state = BuilderState()
        state.authoredCallSignaturesByTarget["_empty"] = contract("void", [])
        let signature = try XCTUnwrap(state.authoredScalarCallSignature(target: "_empty"))
        XCTAssertTrue(signature.parameters.isEmpty)
        XCTAssertTrue(signature.returnsVoid)
    }

    func testExplicitFixedOverridePrecedesCatalog() throws {
        // User-authored authority intentionally differs from the existing memcpy catalog.
        let function = build([("bl", "_memcpy"), ("ret", "")], start: 0x1000,
            target: "_memcpy", signature: contract("uint64_t", ["uint64_t"]))
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
        guard case let .call(frame, result) = instruction.operation else { return XCTFail() }
        XCTAssertNotNil(result)
        XCTAssertEqual(frame.knownSignature?.returnType, "uint64_t")
        XCTAssertEqual(frame.denseFixedRenderValues().count, 1)
    }
}

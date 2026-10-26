import XCTest
@testable import MacScope

final class RuntimeStackFailureSignatureTests: XCTestCase {
    // Apple Libc-1439.40.11 sys/OpenBSD/stack_protector.c:49.
    // Retained consume_data 0x2c48c and other protector epilogues must not
    // synthesize stale GPR arguments or a value from this void(void) helper.
    func testStackFailureRuntimeContractHasNoArgumentsAndNoValue() throws {
        let signature = try XCTUnwrap(CallSignatureCatalog.standard.signature(for: "___stack_chk_fail"))
        XCTAssertEqual(signature.returnType, "void")
        XCTAssertTrue(signature.parameters.isEmpty)
        XCTAssertFalse(signature.isVariadic)
        XCTAssertNil(CallSignatureCatalog.standard.signature(for: "___stack_chk_fail_suffix"))
    }

    func testStackFailureLoweringRetainsCallWithoutStaleArgumentOrValue() throws {
        // Exact observed helper call in _flush_bits at 0x16dc0; the two MOVs
        // are a minimized stale-register setup, not a claimed listing excerpt.
        let operations = [("mov", "x0, x19"), ("mov", "x1, x20"),
                          ("bl", "___stack_chk_fail"), ("ret", "")]
        let rows = operations.enumerated().map { index, operation in
            InstructionRow(address: 0x16db8 + UInt64(index * 4), bytes: "",
                mnemonic: operation.0, operands: operation.1,
                hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
            name: "_runtime_call_fixture", startAddress: 0x16db8, instructions: rows)
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x16dc0 })
        guard case let .call(frame, result) = instruction.operation else { return XCTFail("call was dropped") }
        XCTAssertNil(result)
        XCTAssertTrue(frame.denseFixedRenderValues().isEmpty)
        XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains("___stack_chk_fail();"))
    }

}

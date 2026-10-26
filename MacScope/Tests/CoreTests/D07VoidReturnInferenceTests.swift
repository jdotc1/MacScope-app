import XCTest
@testable import MacScope

/// DP17 B8: body-only X0 preservation cannot distinguish void from a pointer
/// pass-through return. Signature authority resolves the ambiguous contract.
final class D07VoidReturnInferenceTests: XCTestCase {
    private func row(_ offset: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        .init(address: 0x9000 + offset, bytes: "00000000", mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil)
    }

    private func build(_ rows: [InstructionRow]) -> (MacIRFunction, String) {
        let function = MacIRBuilder().buildFunction(name: "leaf", startAddress: 0x9000, instructions: rows)
        return (function, PseudocodePrinter().print(function: function).text)
    }

    func testUnwrittenX0InVectorRegionRetainsUnresolvedContract() {
        let rows = [row(0, "ldr", "x8, [x0]"), row(4, "str", "x8, [x1]"),
                    row(8, "add", "v2.8h, v2.8h, v3.8h"), row(12, "ret", "")]
        XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(rows))
        let (function, text) = build(rows)
        XCTAssertNotNil(function.instructions.first { $0.source.address == 0x9008 }?.neonLaneOp)
        XCTAssertNotEqual(function.returnType, "void", text)
        XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        XCTAssertTrue(text.contains("return unresolved_return_contract;"), text)
        XCTAssertFalse(text.contains("return arg0"), text)
    }

    func testWrittenX0IsStillReturned() {
        let (function, text) = build([row(0, "add", "x0, x0, #0x1"), row(4, "ret", "")])
        XCTAssertNotEqual(function.returnType, "void", text)
        XCTAssertNotNil(function.returnValue)
    }

    func testCallResultIsStillReturned() {
        let (function, text) = build([
            row(0, "stp", "x29, x30, [sp, #-0x10]!"), row(4, "bl", "_compute"),
            row(8, "ldp", "x29, x30, [sp], #0x10"), row(12, "ret", ""),
        ])
        XCTAssertNotEqual(function.returnType, "void", text)
    }

    /// Source twins: void copy(p, out) and uint64_t *copy_return(p, out)
    /// can both compile to ldr x8,[x0]; str x8,[x1]; ret.
    func testCopyLeafPreservesUncertaintyAndAuthoritativePointerResult() {
        let rows = [row(0, "ldr", "x8, [x0]"), row(4, "str", "x8, [x1]"), row(8, "ret", "")]
        let (unknown, text) = build(rows)
        XCTAssertNotEqual(unknown.returnType, "void", text)
        XCTAssertEqual(unknown.returnValue, .unknown("unresolved_return_contract"), text)
        XCTAssertFalse(text.contains("return arg0"), text)
        XCTAssertTrue(text.contains("unresolved_return_contract"), text)

        let arguments = [ArgOverride(rowToken: "p", name: "p", type: "uint64_t *", provenance: .script),
                         ArgOverride(rowToken: "out", name: "out", type: "uint64_t *", provenance: .script)]
        let pointer = PseudocodePrinter().buildFunction(
            functionName: "copy_return", startAddress: 0x9000,
            signatureOverrides: [0x9000: FunctionSignatureOverride(returnType: "uint64_t *", args: arguments)],
            instructions: rows)
        XCTAssertEqual(pointer.returnType, "uint64_t *")
        XCTAssertEqual(pointer.returnValue, .argument(bindingID: .gpr(0)))
        XCTAssertTrue(PseudocodePrinter().print(function: pointer).text.contains("return p;"))
        let void = PseudocodePrinter().buildFunction(
            functionName: "copy", startAddress: 0x9000,
            signatureOverrides: [0x9000: FunctionSignatureOverride(returnType: "void", args: arguments)],
            instructions: rows)
        XCTAssertEqual(void.returnType, "void")
        XCTAssertNil(void.returnValue)
    }

}

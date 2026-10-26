import XCTest
@testable import MacScope

/// A30 (D-SIGNW class): SSA-lifted comparisons project operands to the condition's signedness.
final class SignednessProjectionTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func text(ssa: Bool = true, _ rows: [InstructionRow]) -> String {
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_sign", instructions: rows)
        return PseudocodePrinter().print(function: function).text
    }

    func testCsetGtOverUnsignedLoadProjectsSigned32() {
        let out = text([row(0x1000, "ldr", "w0, [x1]"), row(0x1004, "cmp", "w0, #0x1"),
                        row(0x1008, "cset", "w2, gt"), row(0x100c, "ret", "")])
        XCTAssertTrue(out.contains("& 0x80000000) == 0 ? (int32_t)"), out)
        XCTAssertTrue(out.contains(": -1 - (int32_t)(uint32_t)~"), out)
        XCTAssertFalse(out.contains("(int32_t)(int32_t)"), out)
    }

    func testBhiOverSignedValueProjectsUnsigned32() {
        let out = text([row(0x1000, "cmp", "w0, w1"), row(0x1004, "b.hi", "0x100c"),
                        row(0x1008, "ret", ""), row(0x100c, "ret", "")])
        XCTAssertTrue(out.contains("(uint32_t)"), out)
        XCTAssertFalse(out.contains("(int32_t)"), out)
        XCTAssertFalse(out.contains("0x80000000"), out)
    }

    func testSixtyFourBitLtProjectsSigned64() {
        let out = text([row(0x1000, "ldr", "x0, [x1]"), row(0x1004, "cmp", "x0, x2"),
                        row(0x1008, "cset", "w3, lt"), row(0x100c, "ret", "")])
        XCTAssertTrue(out.contains("& 0x8000000000000000) == 0 ? (int64_t)"), out)
        XCTAssertTrue(out.contains(": -1 - (int64_t)(uint64_t)~"), out)
    }

    func testFlagsPhiSignedConditionProjectsEachIncoming() {
        let out = text([
            row(0x1000, "cbz", "w5, 0x1020"),
            row(0x1004, "ldr", "w0, [x1]"),
            row(0x1008, "cmp", "w0, #0x1"),
            row(0x100c, "b", "0x1040"),
            row(0x1020, "ldr", "w3, [x1]"),
            row(0x1024, "cmp", "w3, #0x4"),
            row(0x1028, "b", "0x1040"),
            row(0x1040, "csel", "x9, x2, x4, gt"),
            row(0x1044, "ret", ""),
        ])
        XCTAssertFalse(out.contains("__unknown(\"csel\""), out)
        let projected = out.components(separatedBy: "& 0x80000000) == 0 ? (int32_t)").count - 1
        XCTAssertGreaterThanOrEqual(projected, 2, out)
        XCTAssertFalse(out.contains("(int32_t)(int32_t)"), out)
    }

    func testEqNeKeepNoCast() {
        let out = text([row(0x1000, "ldr", "w0, [x1]"), row(0x1004, "cmp", "w0, #0x1"),
                        row(0x1008, "cset", "w2, eq"), row(0x100c, "ret", "")])
        XCTAssertFalse(out.contains("(int32_t)"), out)
        XCTAssertFalse(out.contains("(uint32_t)"), out)
    }

    func testAlreadySignedOperandGetsNoDoubleCast() {
        let out = text([row(0x1000, "ldr", "w0, [x1]"), row(0x1004, "cmp", "w0, w2"),
                        row(0x1008, "cset", "w3, gt"), row(0x100c, "cmp", "w0, w2"),
                        row(0x1010, "cset", "w4, ge"), row(0x1014, "ret", "")])
        XCTAssertFalse(out.contains("(int32_t)(int32_t)"), out)
    }

    func testFlagOffTextUnchanged() {
        let out = text(ssa: false, [row(0x1000, "ldr", "w0, [x1]"), row(0x1004, "cmp", "w0, #0x1"),
                                    row(0x1008, "cset", "w2, gt"), row(0x100c, "ret", "")])
        XCTAssertFalse(out.contains("(int32_t)"), out)
    }

    func testEffectfulOperandIsNeverDuplicated() {
        let effectful = MacIRValue.unary(op: "(uint32_t)", value: .unknown("effect()"))
        XCTAssertEqual(MacIRBuilder.signedProjection(effectful, width: 32), effectful)
    }

    func testPureOperandGetsExactlyOneMarkerWithoutSignednessGuess() {
        for operand in [MacIRValue.register(name: "x1", version: 1),
                        .unary(op: "(uint32_t)", value: .register(name: "x1", version: 1))] {
            guard case let .binaryExpression(op, left, right) = MacIRBuilder.signedProjection(operand, width: 32) else {
                return XCTFail("expected marker")
            }
            XCTAssertEqual(op, MacIRBuilder.signedProjectionOperator)
            XCTAssertEqual(left, operand)
            XCTAssertEqual(right, .immediate(32))
        }
        let marker = MacIRBuilder.signedProjection(.register(name: "x1", version: 1), width: 32)
        XCTAssertEqual(MacIRBuilder.signedProjection(marker, width: 32), marker)
        XCTAssertEqual(MacIRBuilder.signedProjection(.immediate(4), width: 32), .immediate(4))
    }

    // MARK: A34 printer-side resolution

    private func resolve(_ operand: MacIRValue, type: String?, width: Int = 32) -> String {
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "_resolve", instructions: [row(0x1000, "ret", "")])
        var names = PseudocodeNameContext(function: function)
        if let type { names.valueTypes[operand] = type }
        let printer = PseudocodePrinter()
        let marker = MacIRBuilder.signedProjection(operand, width: width)
        let printed = printer.valueText(for: marker, names: names)
        XCTAssertFalse(printed.contains(MacIRBuilder.signedProjectionOperator), printed)
        return printed
    }

    private let x22 = MacIRValue.register(name: "x22", version: 2)

    func testPhiUnsignedJoinOperandUsesTransport() {
        let out = resolve(x22, type: "uint64_t", width: 64)
        XCTAssertTrue(out.contains("& 0x8000000000000000) == 0 ? (int64_t)"), out)
        XCTAssertTrue(out.contains(": -1 - (int64_t)(uint64_t)~"), out)
    }

    func testDeclaredSignedOperandOfExactWidthUsesPlainCast() {
        XCTAssertEqual(resolve(x22, type: "int32_t"), "(int32_t)(x22_2)")
    }

    func testSignedOperandOfOtherWidthAndUnknownTypeUseTransport() {
        XCTAssertTrue(resolve(x22, type: "int64_t").contains("0x80000000) == 0 ? (int32_t)"))
        XCTAssertTrue(resolve(x22, type: nil).contains(": -1 - (int32_t)(uint32_t)~"))
    }

    func testPointerOperandIsRefusedBare() {
        XCTAssertEqual(resolve(x22, type: "struct node *"), "x22_2")
    }

    // MARK: A35 sign-extended narrower operands

    private func signExtendedLoad(_ mnemonic: String) -> (PseudocodePrinter, PseudocodeNameContext, MacIRValue) {
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "_narrow", instructions: [row(0x1000, mnemonic, "x0, [x1]"), row(0x1004, "ret", "")])
        var names = PseudocodeNameContext(function: function)
        var loaded: MacIRValue?
        for instruction in function.instructions { if case let .load(destination, _) = instruction.operation { loaded = destination } }
        let value = try! XCTUnwrap(loaded)
        names.valueTypes[value] = mnemonic == "ldrsw" ? "int32_t" : "uint32_t"
        return (PseudocodePrinter(), names, value)
    }

    func testSignExtendedNarrowerOperandStaysBareAgainstSignedPartner() {
        let (printer, names, value) = signExtendedLoad("ldrsw")
        let partner = MacIRValue.register(name: "x2", version: 1)
        let out = printer.signedProjectionText(of: value, partner: partner, width: 64, names: names)
        XCTAssertEqual(out, printer.valueText(for: value, names: names))
    }

    func testZeroExtendingLoadInSixtyFourBitSignedCompareIsRefusedForm() {
        let (printer, names, value) = signExtendedLoad("ldr")
        let out = printer.signedProjectionText(of: value, partner: .register(name: "x2", version: 1), width: 64, names: names)
        XCTAssertTrue(out.contains("& 0x8000000000000000) == 0 ? (int64_t)"), out)
    }

    func testSignExtendedOperandWithUnprojectedOrPointerPartnerKeepsTransport() {
        let (printer, names, value) = signExtendedLoad("ldrsw")
        for partner in [MacIRValue.unknown("effect()"), .immediate(1 << 40)] {
            let out = printer.signedProjectionText(of: value, partner: partner, width: 64, names: names)
            XCTAssertTrue(out.contains("& 0x8000000000000000) == 0 ? (int64_t)"), out)
        }
        var pointer = names
        let other = MacIRValue.register(name: "x2", version: 1)
        pointer.valueTypes[other] = "struct node *"
        XCTAssertTrue(printer.signedProjectionText(of: value, partner: other, width: 64, names: pointer).contains("0x8000000000000000"))
    }

    func testNarrowerOperandFlagOffUnchanged() {
        let out = text(ssa: false, [row(0x1000, "ldrsw", "x0, [x1]"), row(0x1004, "cmp", "x0, x2"),
                                    row(0x1008, "cset", "w3, gt"), row(0x100c, "ret", "")])
        XCTAssertFalse(out.contains("0x8000000000000000"), out)
    }

    // MARK: A36 proof extension

    func testProofAcceptsOnlyMachineRowSignExtensionDefinitions() {
        XCTAssertTrue(RegionalCallRowOwnership.allSignExtend([("ldrsw", "x8", 8)], narrow: 32))
        XCTAssertTrue(RegionalCallRowOwnership.allSignExtend([("ldrsw", "x8", 8), ("sxtw", "x8", 8)], narrow: 32))
        // Mixed ldrsw / zero-extending ldr w definitions, a narrower width mismatch, a W destination and no definitions.
        XCTAssertFalse(RegionalCallRowOwnership.allSignExtend([("ldrsw", "x8", 8), ("ldr", "w8", 8)], narrow: 32))
        XCTAssertFalse(RegionalCallRowOwnership.allSignExtend([("ldrsh", "x8", 8)], narrow: 32))
        XCTAssertFalse(RegionalCallRowOwnership.allSignExtend([("ldrsw", "w8", 8)], narrow: 32))
        XCTAssertFalse(RegionalCallRowOwnership.allSignExtend([], narrow: 32))
    }
}

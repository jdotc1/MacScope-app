import XCTest
@testable import MacScope

final class MacIRLiftingBreadthRound6Tests: XCTestCase {
    private func row(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String = "",
        comment: String? = nil
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func lift(_ rows: [InstructionRow], name: String = "_round6") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ function: MacIRFunction) -> String {
        PseudocodePrinter().print(function: function).text
    }

    private func parameterRegisters(_ function: MacIRFunction) -> [String] {
        function.parameters.map(\.register)
    }

    private func renderedLine(
        in function: MacIRFunction,
        at address: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let lines = PseudocodePrinter().print(function: function).lines(sourcedAt: address)
        XCTAssertEqual(lines.count, 1, file: file, line: line)
        return try XCTUnwrap(lines.first?.text, file: file, line: line)
    }

    private func assertUnknown(
        _ function: MacIRFunction,
        index: Int,
        mnemonic: String,
        operands: String,
        // A destination-writing unknown claims its SSA register (UD-1); pass it for such forms.
        destination: MacIRValue? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            function.instructions[index].operation.withoutUnknownInputs,
            .unknown(destination: destination, mnemonic: mnemonic, operands: operands),
            file: file,
            line: line
        )
    }

    private func assertHonestUnknown(
        _ function: MacIRFunction,
        at address: UInt64,
        mnemonic: String,
        staleNeedle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rendered = text(function)
        let lineText = try renderedLine(in: function, at: address, file: file, line: line)
        XCTAssertTrue(lineText.contains("__unknown(\"\(mnemonic)\""), rendered, file: file, line: line)
        XCTAssertFalse(lineText.contains(staleNeedle), rendered, file: file, line: line)
    }

    func testTstRegisterAndMultiBitImmediateRecordLogicalResultComparison() throws {
        let regReg = lift([
            row(0x1000, "tst", "w0, w1", comment: "register mask"),
            row(0x1004, "cset", "w2, eq", comment: "fresh logical predicate"),
            row(0x1008, "ret")
        ], name: "_tst_reg_reg")
        let regRegText = text(regReg)

        XCTAssertTrue(regRegText.contains("(int32_t)((uint32_t)(arg0) & arg1) == 0x0"), regRegText)
        XCTAssertFalse(regRegText.contains("__unknown(\"tst\""), regRegText)
        XCTAssertFalse(regRegText.contains("__unknown(\"cset\""), regRegText)

        let multiBit = lift([
            row(0x1010, "tst", "x0, #0xff", comment: "multi-bit mask"),
            row(0x1014, "b.eq", "0x2000", comment: "branch on logical result"),
            row(0x1018, "ret")
        ], name: "_tst_multibit")
        let multiBitText = text(multiBit)

        XCTAssertTrue(multiBitText.contains("(int64_t)((uint64_t)(arg0) & 0xff) == 0x0"), multiBitText)
        XCTAssertFalse(multiBitText.contains("__unknown(\"tst\""), multiBitText)
        XCTAssertFalse(multiBitText.contains("__branch_eq"), multiBitText)
    }

    func testTstSingleBitRegressionAndBit63LogicalFlags() throws {
        let singleBit = lift([
            row(0x1020, "tst", "x0, #0x8", comment: "single-bit mask"),
            row(0x1024, "ret")
        ], name: "_tst_single_bit")

        XCTAssertEqual(
            singleBit.instructions[0].operation,
            .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [
                    .unary(op: "(int64_t)", value: .binaryExpression(op: "&",
                        left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                        right: .immediate(8))),
                    .immediate(0)
                ]
            )
        )

        let bit63 = lift([
            row(0x1030, "cmp", "w8, #0x2"),
            row(0x1034, "tst", "x0, #0x8000000000000000", comment: "bit 63 mask"),
            row(0x1038, "cset", "w2, eq", comment: "must not reuse stale cmp"),
            row(0x103c, "ret")
        ], name: "_tst_bit63")

        // Arm ISA_A64 2025-12, TST_ANDS_log_imm / ANDS_log_imm Operation:
        // AND at datasize, then N=result<63>, Z=IsZeroBit(result), C=V=0.
        // The high-bit mask is legal and replaces the preceding CMP flags.
        let expected = MacIRValue.unary(op: "(int64_t)", value: .binaryExpression(op: "&",
            left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
            right: .unary(op: "(uint64_t)", value: .immediate(Int64.min))))
        guard case let .intrinsic(nil, name, arguments) = bit63.instructions[1].operation else {
            return XCTFail("expected a logical result comparison for high-bit TST")
        }
        XCTAssertEqual(name, "compare")
        XCTAssertTrue(arguments == [expected, .immediate(0)], "TST must retain the full signed-width result")
        guard case let .compareToBool(_, condition, left, right) = bit63.instructions[2].operation else {
            return XCTFail("CSET must consume the fresh TST flags")
        }
        XCTAssertEqual(condition, "==")
        XCTAssertTrue(left == expected, "CSET must use TST rather than the preceding CMP")
        XCTAssertEqual(right, .immediate(0))
    }

    func testLogicalResultUnsignedSuffixesStayHonest() throws {
        let csetHS = lift([
            row(0x1040, "tst", "w0, w1", comment: "logical flags"),
            row(0x1044, "cset", "w2, hs", comment: "unsigned suffix"),
            row(0x1048, "ret")
        ], name: "_logical_hs_cset")
        try assertHonestUnknown(csetHS, at: 0x1044, mnemonic: "cset", staleNeedle: "arg0 & arg1")

        let branchHS = lift([
            row(0x1050, "tst", "w0, w1", comment: "logical flags"),
            row(0x1054, "b.hs", "0x2000", comment: "unsigned suffix"),
            row(0x1058, "ret")
        ], name: "_logical_hs_branch")
        let branchText = text(branchHS)
        XCTAssertTrue(branchText.contains("__branch_hs(0x2000)"), branchText)
        XCTAssertFalse(branchText.contains("arg0 & arg1 >= 0x0"), branchText)

        let ccmp = lift([
            row(0x1060, "tst", "w0, w1", comment: "logical flags"),
            row(0x1064, "ccmp", "w2, #0x0, #0x0, lo", comment: "bad guard suffix"),
            row(0x1068, "b.eq", "0x2000", comment: "must not compound-fold"),
            row(0x106c, "ret")
        ], name: "_logical_ccmp_lo")
        let ccmpText = text(ccmp)
        // IR-7: the ccmp LINE is now an intrinsic; the point of this test is that the unsigned
        // guard suffix still prevents a compound fold (asserted below).
        if case let .intrinsic(_, name, _) = ccmp.instructions[1].operation {
            XCTAssertEqual(name, "conditional_compare_lo")
        } else {
            XCTFail("expected conditional_compare intrinsic, got \(ccmp.instructions[1].operation)")
        }
        XCTAssertTrue(ccmpText.contains("__branch_eq(0x2000)"), ccmpText)
        XCTAssertFalse(ccmpText.contains("&&"), ccmpText)
    }

    func testThreeOperandCmpAndCmnExtendedShiftedRecordSubtractionComparison() throws {
        let signed = lift([
            row(0x1070, "cmp", "x0, w1, sxtw", comment: "signed extension"),
            row(0x1074, "cset", "w2, eq", comment: "signed predicate"),
            row(0x1078, "ret")
        ], name: "_cmp_sxtw")
        let signedText = text(signed)
        XCTAssertTrue(signedText.contains("arg0 == (int32_t)(arg1)"), signedText)
        XCTAssertFalse(signedText.contains("__unknown(\"cmp\""), signedText)
        XCTAssertFalse(signedText.contains("__unknown(\"cset\""), signedText)

        let unsigned = lift([
            row(0x1080, "cmp", "x0, w1, uxtw", comment: "unsigned extension"),
            row(0x1084, "cset", "w2, eq", comment: "unsigned predicate"),
            row(0x1088, "ret")
        ], name: "_cmp_uxtw")
        let unsignedText = text(unsigned)
        XCTAssertTrue(unsignedText.contains("arg0 == (uint32_t)(arg1)"), unsignedText)
        XCTAssertFalse(unsignedText.contains("__unknown(\"cmp\""), unsignedText)

        let cmn = lift([
            row(0x1090, "cmn", "x0, x1, lsl #1", comment: "negated composed rhs"),
            row(0x1094, "cset", "w2, lt", comment: "cmn predicate"),
            row(0x1098, "ret")
        ], name: "_cmn_shifted")
        let cmnText = text(cmn)
        // CMN LT is N != V for addition, including a shifted addend equal to MIN; pin the exact predicate IR.
        let a = MacIRValue.unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0)))
        let b = MacIRValue.unary(op: "(uint64_t)", value: .binaryExpression(op: "<<",
            left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))), right: .immediate(1)))
        let sum = MacIRValue.unary(op: "(uint64_t)", value: .binaryExpression(op: "+", left: a, right: b))
        let overflow = MacIRValue.binaryExpression(op: "&",
            left: .unary(op: "~", value: .binaryExpression(op: "^", left: a, right: b)),
            right: .binaryExpression(op: "^", left: a, right: sum))
        let predicate = MacIRValue.binaryExpression(op: "&",
            left: .binaryExpression(op: "^", left: sum, right: overflow),
            right: .unary(op: "(uint64_t)", value: .immediate(Int64.min)))
        XCTAssertEqual(cmn.instructions[1].operation, .compareToBool(
            destination: .register(name: "w2", version: 1), condition: "!=", left: predicate, right: .immediate(0)))
        XCTAssertFalse(cmnText.contains("__unknown(\"cmn\""), cmnText)
        XCTAssertFalse(cmnText.contains("__unknown(\"cset\""), cmnText)
    }


    func testCmnSignedLessThanUsesAdditionNZCVAtBoundariesInBothModes() throws {
        // Arm AddWithCarry(a,b,0): columns are width, a, unshifted source, expected NZCV.
        let vectors: [(Int, UInt64, UInt64, UInt8)] = [
            (64, 0, 0x4000000000000000, 0b1000),
            (64, 0x8000000000000000, 0x4000000000000000, 0b0111),
            (64, 0x7fffffffffffffff, 1, 0b1001),
            (64, 0x8000000000000000, 0x7fffffffffffffff, 0b0011),
            (64, 0xfffffffffffffffe, 1, 0b0110),
            (64, 0xfffffffffffffffd, 1, 0b1000),
            (32, 0, 0x40000000, 0b1000),
            (32, 0x80000000, 0x40000000, 0b0111),
            (32, 0x7fffffff, 1, 0b1001),
            (32, 0x80000000, 0x7fffffff, 0b0011),
            (32, 0xfffffffe, 1, 0b0110),
            (32, 0xfffffffd, 1, 0b1000),
        ]
        func evaluate(_ value: MacIRValue, registers: [String: UInt64]) throws -> UInt64 {
            switch value {
            case let .immediate(bits): return UInt64(bitPattern: bits)
            case let .register(name, _): return try XCTUnwrap(registers[name])
            case let .unary(op, inner):
                let bits = try evaluate(inner, registers: registers)
                switch op {
                case "(uint32_t)": return bits & 0xffffffff
                case "(uint64_t)": return bits
                case "~": return ~bits
                default: XCTFail("unexpected unary \(op)"); return 0
                }
            case let .binaryExpression(op, left, right):
                let a = try evaluate(left, registers: registers), b = try evaluate(right, registers: registers)
                switch op {
                case "+": return a &+ b
                case "^": return a ^ b
                case "&": return a & b
                case "<<": return a << b
                default: XCTFail("unexpected binary \(op)"); return 0
                }
            default: XCTFail("unexpected value \(value)"); return 0
            }
        }
        for ssa in [false, true] {
            for (width, a, source, nzcv) in vectors {
                let prefix = width == 32 ? "w" : "x"
                var state = BuilderState()
                state.registerVersions["\(prefix)8"] = 0
                state.registerVersions["\(prefix)9"] = 0
                let builder = MacIRBuilder(ssaEnabled: ssa)
                _ = builder.operation(for: .init(address: 0x1200, byteText: "", mnemonic: "cmn",
                    operands: "\(prefix)8, \(prefix)9, lsl #1"), state: &state)
                let operation = builder.operation(for: .init(address: 0x1204, byteText: "", mnemonic: "cset",
                    operands: "w10, lt"), state: &state)
                guard case let .compareToBool(_, condition, left, right) = operation else {
                    XCTFail("CMN LT must lower in mode \(ssa)"); continue
                }
                XCTAssertEqual(condition, "!=")
                XCTAssertEqual(right, .immediate(0))
                let bits = try evaluate(left, registers: ["\(prefix)8": a, "\(prefix)9": source])
                let expected = ((nzcv >> 3) & 1) != (nzcv & 1)
                XCTAssertEqual(bits != 0, expected, "W\(width), a=\(a), source=\(source), NZCV=\(nzcv), SSA=\(ssa)")
            }
        }
    }

    func testAndsAndBicsThreeOperandLiftAndRecordFreshComparison() throws {
        let ands = lift([
            row(0x10a0, "ands", "w9, w0, w1", comment: "logical set flags"),
            row(0x10a4, "cset", "w2, eq", comment: "fresh predicate"),
            row(0x10a8, "ret")
        ], name: "_ands_cset")
        let andsText = text(ands)
        // w9 is a dead store (never read after the ands), so the printer names it `tmp0`, not
        // `w9_1` — assert the RHS, not the register LHS (the documented dead-store trap).
        XCTAssertTrue(andsText.contains("= arg0 & arg1;"), andsText)
        XCTAssertTrue(andsText.contains("(arg0 & arg1) == 0x0"), andsText)
        XCTAssertFalse(andsText.contains("__unknown(\"ands\""), andsText)
        XCTAssertFalse(andsText.contains("__unknown(\"cset\""), andsText)

        let bics = lift([
            row(0x10b0, "bics", "x9, x0, x1", comment: "bit clear set flags"),
            row(0x10b4, "cset", "w2, ne", comment: "fresh predicate"),
            row(0x10b8, "ret")
        ], name: "_bics_cset")
        let bicsText = text(bics)
        XCTAssertTrue(bicsText.contains("= arg0 & ~(arg1);"), bicsText)
        XCTAssertTrue(bicsText.contains("(arg0 & ~(arg1)) != 0x0"), bicsText)
        XCTAssertFalse(bicsText.contains("__unknown(\"bics\""), bicsText)

        let shifted = lift([
            row(0x10c0, "cmp", "w0, #0x7"),
            row(0x10c4, "ands", "x0, x1, x2, lsl #3", comment: "shifted stays unknown"),
            row(0x10c8, "cset", "w3, eq", comment: "must not reuse stale cmp"),
            row(0x10cc, "ret")
        ], name: "_ands_shifted_unknown")

        // 4-op shifted ands is NOT lifted (stays unknown) but WRITES x0 → UD-1 claims x0_1;
        // it still poisons (writesNZCVFlags), so the following cset stays honest, not stale.
        assertUnknown(shifted, index: 1, mnemonic: "ands", operands: "x0, x1, x2, lsl #3",
                      destination: .register(name: "x0", version: 1))
        try assertHonestUnknown(shifted, at: 0x10c8, mnemonic: "cset", staleNeedle: "== 0x7")
    }

    func testSbfxLiftsWithArithmeticSignExtension() throws {
        let function = lift([
            row(0x10d0, "sbfx", "x0, x1, #4, #4", comment: "signed extract"),
            row(0x10d4, "ret")
        ], name: "_sbfx")
        let rendered = text(function)

        XCTAssertTrue(rendered.contains("mscope_sbfx_bits_u64(in_x1, 4, 4)"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"sbfx\""), rendered)
    }

    func testFmovScalarImmediateEchoesDecoderTextAndSIMDArrangementStaysUnknown() throws {
        let scalar = lift([
            row(0x10e0, "fmov", "d1, #-1.00000000", comment: "scalar fp immediate"),
            row(0x10e4, "ret")
        ], name: "_fmov_scalar_imm")
        let scalarText = text(scalar)

        XCTAssertTrue(scalarText.contains("d1_1 = -1.00000000"), scalarText)
        XCTAssertFalse(scalarText.contains("__unknown(\"fmov\""), scalarText)

        let simd = lift([
            row(0x10f0, "fmov", "v0.2d, #1.00000000", comment: "simd arrangement"),
            row(0x10f4, "ret")
        ], name: "_fmov_simd_imm")

        assertUnknown(simd, index: 0, mnemonic: "fmov", operands: "v0.2d, #1.00000000")
    }

    func testRound6SignatureRecoveryTables() throws {
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "tst", operands: ["w0", "w1"])),
            Set(["w0", "w1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "tst", operands: ["x0", "#0xff"])),
            Set(["x0"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "cmp", operands: ["x0", "w1", "sxtw"])),
            Set(["x0", "w1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "cmn", operands: ["x2", "x3", "lsl #1"])),
            Set(["x2", "x3"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "ands", operands: ["w9", "w0", "w1"])),
            Set(["w0", "w1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterWrites(mnemonic: "ands", operands: ["w9", "w0", "w1"])),
            Set(["w9"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "bics", operands: ["wzr", "w0", "w1"])),
            Set(["w0", "w1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterWrites(mnemonic: "bics", operands: ["wzr", "w0", "w1"])),
            Set<String>()
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "sbfx", operands: ["x0", "x1", "#4", "#4"])),
            Set(["x1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterWrites(mnemonic: "sbfx", operands: ["x0", "x1", "#4", "#4"])),
            Set(["x0"])
        )

        let signature = lift([
            row(0x1100, "tst", "x0, x1"),
            row(0x1104, "cmp", "x2, w3, sxtw"),
            row(0x1108, "ands", "x4, x5, x6"),
            row(0x110c, "sbfx", "x7, x0, #1, #2"),
            row(0x1110, "ret")
        ], name: "_round6_signature")

        XCTAssertEqual(Set(parameterRegisters(signature)), Set(["x0", "x1", "x2", "w3", "x5", "x6"]))
    }
}

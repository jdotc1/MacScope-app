import XCTest
@testable import MacScope

final class MacIRLiftingBreadthTests: XCTestCase {
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

    private func lift(_ rows: [InstructionRow], name: String = "_f") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ function: MacIRFunction) -> String {
        PseudocodePrinter().print(function: function).text
    }

    private func sourcedLines(_ function: MacIRFunction, at address: UInt64) -> [String] {
        PseudocodePrinter().print(function: function).lines(sourcedAt: address).map(\.text)
    }

    private func assertUnknown(
        _ function: MacIRFunction,
        index: Int = 0,
        mnemonic: String,
        operands: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Destination-agnostic: UD-1 claims an SSA destination on definite
        // first-operand writers; these pins only assert the form stays an
        // honest __unknown with this exact mnemonic + operand text.
        guard case let .unknown(_, _, actualMnemonic, actualOperands) = function.instructions[index].operation else {
            XCTFail(
                "expected __unknown at index \(index), got \(function.instructions[index].operation)",
                file: file,
                line: line
            )
            return
        }
        XCTAssertEqual(actualMnemonic, mnemonic, file: file, line: line)
        XCTAssertEqual(actualOperands, operands, file: file, line: line)
    }

    private func assertEquivalentLift(
        aliasRows: [InstructionRow],
        canonicalRows: [InstructionRow],
        index: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alias = lift(aliasRows, name: "_alias")
        let canonical = lift(canonicalRows, name: "_canonical")
        XCTAssertEqual(alias.instructions[index].operation, canonical.instructions[index].operation, file: file, line: line)
    }

    private func expectedAssign(_ destination: MacIRValue, _ source: MacIRValue) -> MacIROperation {
        .assign(destination: destination, source: source)
    }

    func testPACIntrinsicsLiftToElidableIntrinsicAndTrapsStayVisible() throws {
        let function = lift([
            row(0x1000_1000, "pacibsp"),
            row(0x1000_1004, "autibsp"),
            row(0x1000_1008, "paciza"),
            row(0x1000_100c, "udf", "#0", comment: "trap"),
            row(0x1000_1010, "brk", "#1", comment: "breakpoint"),
            row(0x1000_1014, "ret")
        ], name: "_pac_and_traps")

        XCTAssertEqual(function.instructions[0].operation, .intrinsic(destination: nil, name: "pacibsp", arguments: []))
        XCTAssertEqual(function.instructions[1].operation, .intrinsic(destination: nil, name: "autibsp", arguments: []))
        XCTAssertEqual(function.instructions[2].operation, .intrinsic(destination: nil, name: "paciza", arguments: []))
        assertUnknown(function, index: 3, mnemonic: "udf", operands: "#0")
        // Round 3 (IR-3): brk now lifts to a VISIBLE trap intrinsic (never elidable);
        // udf remains __unknown (out of that round's scope).
        XCTAssertEqual(function.instructions[4].operation, .intrinsic(destination: nil, name: "brk", arguments: [.immediate(1)]))

        // PAC elision is opt-in via nopElision (same policy as `nop` — see
        // PACIntrinsicElisionTests on main). The DEFAULT printer renders them.
        let shown = text(function)
        XCTAssertTrue(shown.contains("__pacibsp()"), "default must render PAC intrinsics")
        XCTAssertTrue(shown.contains("__autibsp()"))
        XCTAssertTrue(shown.contains("__paciza()"))
        XCTAssertTrue(shown.contains("__unknown(\"udf\", \"#0\"); // trap"))
        XCTAssertTrue(shown.contains("__brk(") && !shown.contains("__unknown(\"brk\""), "brk lifts to a visible __brk(...) trap intrinsic")

        var elide = DecompilerOptions.default
        elide.nopElision = true
        let elided = PseudocodePrinter(options: elide).print(function: function).text
        XCTAssertFalse(elided.contains("pacibsp"), "nopElision must drop PAC intrinsic lines")
        XCTAssertFalse(elided.contains("autibsp"))
        XCTAssertFalse(elided.contains("paciza"))
        XCTAssertTrue(elided.contains("__unknown(\"udf\", \"#0\"); // trap"), "traps are NEVER elided")
        XCTAssertTrue(elided.contains("__brk("), "brk trap intrinsic is NEVER elided")
    }

    func testMovkFoldsOnlyTrackedMoveWideImmediateChain() throws {
        let function = lift([
            row(0x1000_2000, "movz", "x0, #0x0, lsl #0", comment: "seed"),
            row(0x1000_2004, "movk", "x0, #0xcdef, lsl #0", comment: "low"),
            row(0x1000_2008, "movk", "x0, #0x89ab, lsl #16", comment: "mid low"),
            row(0x1000_200c, "movk", "x0, #0x4567, lsl #32", comment: "mid high"),
            row(0x1000_2010, "movk", "x0, #0x0123, lsl #48", comment: "high"),
            row(0x1000_2014, "ret")
        ], name: "_constant")

        XCTAssertEqual(
            function.instructions[4].operation,
            .assign(destination: .register(name: "x0", version: 5), source: .immediate(0x0123_4567_89ab_cdef))
        )
        XCTAssertEqual(sourcedLines(function, at: 0x1000_2010), [
            "    x0_5 = 0x123456789abcdef; // high"
        ])
        XCTAssertFalse(text(function).contains("__unknown(\"movk\""))

        // Round 3 (IR-3): a standalone (untracked) movk no longer stays __unknown — it lifts to
        // a read-modify-write assignment (keep-other-bits semantics). The tracked movz+movk
        // chain above still folds to the immediate. Exact RMW IR pinned by Round3 tests.
        let unfolded = lift([
            row(0x1000_2020, "movk", "x0, #0x1, lsl #16", comment: "untracked"),
            row(0x1000_2024, "ret")
        ], name: "_unfolded_movk")
        if case .unknown = unfolded.instructions[0].operation {
            XCTFail("standalone movk should lift to a read-modify-write assignment, not __unknown")
        }
        XCTAssertFalse(text(unfolded).contains("__unknown(\"movk\""))
    }

    func testAdrLiftsResolvedAddressAssignment() throws {
        let function = lift([
            row(0x1000_2100, "adr", "x0, 0x100020000", comment: "literal address"),
            row(0x1000_2104, "ret")
        ], name: "_adr")

        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(destination: .register(name: "x0", version: 1), source: .immediate(0x1000_20000))
        )
        XCTAssertEqual(sourcedLines(function, at: 0x1000_2100), [
            "    x0_1 = 0x100020000; // literal address"
        ])
    }

    func testConditionalSelectAliasesMatchCanonicalDealiasedIR() throws {
        let compare = row(0x1000_3000, "cmp", "x2, #0")
        let ret = row(0x1000_3010, "ret")

        assertEquivalentLift(
            aliasRows: [compare, row(0x1000_3004, "cinc", "x0, x1, eq", comment: "alias"), ret],
            canonicalRows: [compare, row(0x1000_3004, "csinc", "x0, x1, x1, ne", comment: "canonical"), ret]
        )
        assertEquivalentLift(
            aliasRows: [compare, row(0x1000_3004, "cinv", "x0, x1, eq"), ret],
            canonicalRows: [compare, row(0x1000_3004, "csinv", "x0, x1, x1, ne"), ret]
        )
        assertEquivalentLift(
            aliasRows: [compare, row(0x1000_3004, "cneg", "x0, x1, eq"), ret],
            canonicalRows: [compare, row(0x1000_3004, "csneg", "x0, x1, x1, ne"), ret]
        )
        assertEquivalentLift(
            aliasRows: [compare, row(0x1000_3004, "csetm", "x0, eq"), ret],
            canonicalRows: [compare, row(0x1000_3004, "csinv", "x0, xzr, xzr, ne"), ret]
        )

        let function = lift([
            compare,
            row(0x1000_3004, "cinc", "x0, x1, eq", comment: "alias"),
            ret
        ], name: "_cinc")
        XCTAssertEqual(
            function.instructions[1].operation,
            .select(
                destination: .register(name: "x0", version: 1),
                condition: "!=",
                left: .argument(bindingID: .gpr(2)),
                right: .immediate(0),
                trueValue: .argument(bindingID: .gpr(1)),
                falseValue: .binaryExpression(op: "+", left: .argument(bindingID: .gpr(1)), right: .immediate(1))
            )
        )
        XCTAssertEqual(sourcedLines(function, at: 0x1000_3004), [
            "    x0_1 = (in_x2 != 0x0) ? in_x1 : in_x1 + 0x1; // alias; conditional select"
        ])
    }

    func testBitfieldAliasesRenderIndependentShiftMaskExpansion() throws {
        let ubfiz = lift([
            row(0x1000_4000, "ubfiz", "x0, x1, #4, #8", comment: "insert zero"),
            row(0x1000_4004, "ret")
        ], name: "_ubfiz")
        XCTAssertEqual(
            ubfiz.instructions[0].operation,
            expectedAssign(
                .register(name: "x0", version: 1),
                .binaryExpression(
                    op: "<<",
                    left: .binaryExpression(op: "&", left: .argument(bindingID: .gpr(1)), right: .immediate(0xff)),
                    right: .immediate(4)
                )
            )
        )
        XCTAssertEqual(sourcedLines(ubfiz, at: 0x1000_4000), [
            "    x0_1 = (in_x1 & 0xff) << 0x4; // insert zero"
        ])

        let sbfiz = lift([
            row(0x1000_4010, "sbfiz", "x0, x1, #4, #8", comment: "signed insert zero"),
            row(0x1000_4014, "ret")
        ], name: "_sbfiz")
        XCTAssertEqual(
            sbfiz.instructions[0].operation,
            expectedAssign(
                .register(name: "x0", version: 1),
                .signedBitfield(try XCTUnwrap(MacIRSignedBitfield(
                    source: .argument(bindingID: .gpr(1)), operandBits: 64,
                    sourceLSB: 0, fieldBits: 8, insertLSB: 4,
                    origin: .init(functionName: "_sbfiz", functionStart: 0x1000_4010,
                        instructionAddress: 0x1000_4010, mnemonic: "sbfiz",
                        sourceRegister: "x1", destinationRegister: "x0",
                        definition: .argument(bindingID: .gpr(1)), definitionBits: 64))))
            )
        )
        XCTAssertEqual(sourcedLines(sbfiz, at: 0x1000_4010), [
            "    x0_1 = mscope_sbfiz_bits_u64(in_x1, 4, 8); // signed insert zero"
        ])

        let bfi = lift([
            row(0x1000_4020, "bfi", "w0, w1, #8, #8", comment: "insert field"),
            row(0x1000_4024, "ret")
        ], name: "_bfi")
        XCTAssertEqual(
            bfi.instructions[0].operation,
            expectedAssign(
                .register(name: "w0", version: 1),
                .binaryExpression(
                    op: "|",
                    left: .binaryExpression(op: "&", left: .argument(bindingID: .gpr(0)), right: .immediate(0xffff_00ff)),
                    right: .binaryExpression(
                        op: "&",
                        left: .binaryExpression(op: "<<", left: .argument(bindingID: .gpr(1)), right: .immediate(8)),
                        right: .immediate(0xff00)
                    )
                )
            )
        )
        XCTAssertEqual(sourcedLines(bfi, at: 0x1000_4020), [
            "    w0_1 = (arg0 & 0xffff00ff) | ((arg1 << 0x8) & 0xff00); // insert field"
        ])

        let bfxil = lift([
            row(0x1000_4030, "bfxil", "w0, w1, #8, #8", comment: "extract low"),
            row(0x1000_4034, "ret")
        ], name: "_bfxil")
        XCTAssertEqual(
            bfxil.instructions[0].operation,
            expectedAssign(
                .register(name: "w0", version: 1),
                .binaryExpression(
                    op: "|",
                    left: .binaryExpression(op: "&", left: .argument(bindingID: .gpr(0)), right: .immediate(0xffff_ff00)),
                    right: .binaryExpression(
                        op: "&",
                        left: .binaryExpression(op: ">>", left: .argument(bindingID: .gpr(1)), right: .immediate(8)),
                        right: .immediate(0xff)
                    )
                )
            )
        )
        XCTAssertEqual(sourcedLines(bfxil, at: 0x1000_4030), [
            "    w0_1 = (arg0 & 0xffffff00) | ((arg1 >> 0x8) & 0xff); // extract low"
        ])
    }

    func testExtractAndRotateRenderShiftOrExpansion() throws {
        let extr = lift([
            row(0x1000_4100, "extr", "x0, x1, x2, #8", comment: "extract pair"),
            row(0x1000_4104, "ret")
        ], name: "_extr")
        XCTAssertEqual(
            extr.instructions[0].operation,
            expectedAssign(
                .register(name: "x0", version: 1),
                .binaryExpression(
                    op: "|",
                    left: .binaryExpression(op: ">>", left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(2))), right: .immediate(8)),
                    right: .binaryExpression(op: "<<", left: .argument(bindingID: .gpr(1)), right: .immediate(56))
                )
            )
        )
        XCTAssertEqual(sourcedLines(extr, at: 0x1000_4100), [
            "    x0_1 = ((uint64_t)(in_x2) >> 0x8) | (in_x1 << 0x38); // extract pair"
        ])

        let ror = lift([
            row(0x1000_4110, "ror", "x0, x1, #8", comment: "rotate"),
            row(0x1000_4114, "ret")
        ], name: "_ror")
        XCTAssertEqual(
            ror.instructions[0].operation,
            expectedAssign(
                .register(name: "x0", version: 1),
                .binaryExpression(
                    op: "|",
                    left: .binaryExpression(op: ">>", left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))), right: .immediate(8)),
                    right: .binaryExpression(op: "<<", left: .argument(bindingID: .gpr(1)), right: .immediate(56))
                )
            )
        )
        XCTAssertEqual(sourcedLines(ror, at: 0x1000_4110), [
            "    x0_1 = ((uint64_t)(in_x1) >> 0x8) | (in_x1 << 0x38); // rotate"
        ])
    }

    func testWideningMultiplyUsesExplicitCastsAndRejectsVectorOperands() throws {
        let umull = lift([
            row(0x1000_5000, "umull", "x0, w1, w2", comment: "unsigned widen"),
            row(0x1000_5004, "ret")
        ], name: "_umull")
        XCTAssertEqual(
            umull.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "*",
                left: .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: .argument(bindingID: .gpr(1)))),
                right: .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: .argument(bindingID: .gpr(2))))
            )
        )
        XCTAssertEqual(sourcedLines(umull, at: 0x1000_5000), [
            "    x0_1 = (uint64_t)((uint32_t)(in_w1)) * (uint64_t)((uint32_t)(in_w2)); // unsigned widen"
        ])

        let smull = lift([
            row(0x1000_5010, "smull", "x0, w1, w2", comment: "signed widen"),
            row(0x1000_5014, "ret")
        ], name: "_smull")
        XCTAssertEqual(sourcedLines(smull, at: 0x1000_5010), [
            "    x0_1 = (int64_t)((int32_t)(in_w1)) * (int64_t)((int32_t)(in_w2)); // signed widen"
        ])

        let umaddl = lift([
            row(0x1000_5020, "umaddl", "x0, w1, w2, x3", comment: "unsigned add long"),
            row(0x1000_5024, "ret")
        ], name: "_umaddl")
        XCTAssertEqual(sourcedLines(umaddl, at: 0x1000_5020), [
            "    x0_1 = in_x3 + ((uint64_t)((uint32_t)(in_w1)) * (uint64_t)((uint32_t)(in_w2))); // unsigned add long"
        ])

        let vectorUmull = lift([
            row(0x1000_5030, "umull", "v0.4s, v1.4h, v2.h[3]", comment: "vector by-element"),
            row(0x1000_5034, "ret")
        ], name: "_vector_umull")
        XCTAssertEqual(vectorUmull.instructions[0].operation, .intrinsic(destination: .register(name: "v0", version: 1), name: "neon_umull_4s_from_4h_by_lane3", arguments: [.register(name: "v1", version: 0), .register(name: "v2", version: 0)]))
        XCTAssertTrue(text(vectorUmull).contains("__neon_umull_4s_from_4h_by_lane3(v1_0, v2_0); // vector by-element"))

        let vectorSmull = lift([
            row(0x1000_5040, "smull", "v0.4s, v1.4h, v2.h[3]", comment: "vector by-element"),
            row(0x1000_5044, "ret")
        ], name: "_vector_smull")
        XCTAssertEqual(vectorSmull.instructions[0].operation, .intrinsic(destination: .register(name: "v0", version: 1), name: "neon_smull_4s_from_4h_by_lane3", arguments: [.register(name: "v1", version: 0), .register(name: "v2", version: 0)]))
        XCTAssertTrue(text(vectorSmull).contains("__neon_smull_4s_from_4h_by_lane3(v1_0, v2_0); // vector by-element"))
    }

    func testUnscaledByteHalfwordVariantsMatchSizedBaseLoadsAndStores() throws {
        let sturb = lift([
            row(0x1000_6000, "sturb", "w0, [sp, #0]", comment: "byte spill"),
            row(0x1000_6004, "ret")
        ], name: "_sturb")
        let strb = lift([
            row(0x1000_6000, "strb", "w0, [sp, #0]", comment: "byte spill"),
            row(0x1000_6004, "ret")
        ], name: "_strb")
        XCTAssertEqual(sturb.instructions[0].operation, strb.instructions[0].operation)
        XCTAssertEqual(sturb.localVariables.map(\.byteWidth), [1])

        let sturh = lift([
            row(0x1000_6010, "sturh", "w0, [sp, #2]", comment: "half spill"),
            row(0x1000_6014, "ret")
        ], name: "_sturh")
        let strh = lift([
            row(0x1000_6010, "strh", "w0, [sp, #2]", comment: "half spill"),
            row(0x1000_6014, "ret")
        ], name: "_strh")
        XCTAssertEqual(sturh.instructions[0].operation, strh.instructions[0].operation)
        XCTAssertEqual(sturh.localVariables.map(\.byteWidth), [2])

        let ldurb = lift([
            row(0x1000_6020, "ldurb", "w0, [x1]", comment: "byte reload"),
            row(0x1000_6024, "ret")
        ], name: "_ldurb")
        let ldrb = lift([
            row(0x1000_6020, "ldrb", "w0, [x1]", comment: "byte reload"),
            row(0x1000_6024, "ret")
        ], name: "_ldrb")
        XCTAssertEqual(ldurb.instructions[0].operation, ldrb.instructions[0].operation)
        XCTAssertEqual(sourcedLines(ldurb, at: 0x1000_6020), [
            "    w0_1 = *(uint8_t *)(in_x1); // byte reload"
        ])

        let ldurh = lift([
            row(0x1000_6030, "ldurh", "w0, [x1]", comment: "half reload"),
            row(0x1000_6034, "ret")
        ], name: "_ldurh")
        let ldrh = lift([
            row(0x1000_6030, "ldrh", "w0, [x1]", comment: "half reload"),
            row(0x1000_6034, "ret")
        ], name: "_ldrh")
        XCTAssertEqual(ldurh.instructions[0].operation, ldrh.instructions[0].operation)
    }

    func testBannedAndSIMDFormsStayUnknown() throws {
        let function = lift([
            row(0x1000_7000, "sub.4h", "v0.4h, v1.4h, v2.4h", comment: "simd suffix"),
            row(0x1000_7004, "adc", "x0, x1, x2", comment: "carry"),
            row(0x1000_7008, "sbc", "x0, x1, x2", comment: "borrow"),
            row(0x1000_700c, "ccmp", "x2, x3, #0x0, eq", comment: "conditional compare"),
            row(0x1000_7010, "ccmn", "x2, #0x1, #0x4, lt", comment: "conditional compare negative"),
            row(0x1000_7014, "sbfx", "x0, x1, #4, #4", comment: "driver pin"),
            row(0x1000_7018, "ret")
        ], name: "_unknown_guards")

        assertUnknown(function, index: 0, mnemonic: "sub.4h", operands: "v0.4h, v1.4h, v2.4h")
        assertUnknown(function, index: 1, mnemonic: "adc", operands: "x0, x1, x2")
        assertUnknown(function, index: 2, mnemonic: "sbc", operands: "x0, x1, x2")
        // IR-7: ccmp/ccmn now emit a faithful flag-effect intrinsic (they write no GPR), so they
        // are no longer __unknown. The SIMD/banned forms below must still be.
        assertConditionalCompareIntrinsic(function, index: 3, suffix: "eq")
        assertConditionalCompareIntrinsic(function, index: 4, suffix: "lt")
        // SBFX selects bits 7:4 and sign-fills from bit 7; the unsigned helper avoids signed-shift assumptions.
        let rendered = text(function)
        XCTAssertFalse(rendered.contains("__unknown(\"sbfx\""), rendered)
        XCTAssertTrue(rendered.contains("mscope_sbfx_bits_u64(in_x1, 4, 4)"), rendered)
        XCTAssertTrue(rendered.contains("__unknown(\"sub.4h\", \"v0.4h, v1.4h, v2.4h\"); // simd suffix"))
        XCTAssertTrue(rendered.contains("__unknown(\"adc\", \"x0, x1, x2\"); // carry"))
        XCTAssertTrue(rendered.contains("__unknown(\"sbc\", \"x0, x1, x2\"); // borrow"))
        XCTAssertTrue(rendered.contains("__conditional_compare_eq("), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ccmp\""), rendered)
        XCTAssertTrue(rendered.contains("__conditional_compare_lt("), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ccmn\""), rendered)
    }

    func testSignedBitfieldExtractMatchesArchitecturalSignExtensionInBothModes() throws {
        // SBFX X0,X1,#4,#4 aliases SBFM with immr=4, imms=7: result[3:0]
        // is source[7:4], and result[63:4] repeats source[7], not source[63].
        let cases: [(UInt64, UInt64)] = [
            (0, 0), (0x70, 7), (0x80, 0xffff_ffff_ffff_fff8),
            (0xf0, UInt64.max), (0x8000_0000_0000_0070, 7),
            (0xffff_ffff_ffff_ff0f, 0),
        ]
        for ssa in [false, true] {
            let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(
                name: "signed_field", instructions: [
                    row(0x1000_7100, "sbfx", "x0, x1, #4, #4"),
                    row(0x1000_7104, "ret"),
                ])
            guard case let .assign(_, .signedBitfield(field)) = function.instructions[0].operation else {
                XCTFail("expected a typed signed bitfield in mode \(ssa)")
                continue
            }
            XCTAssertEqual(field.operandBits, 64)
            XCTAssertEqual(field.sourceLSB, 4)
            XCTAssertEqual(field.fieldBits, 4)
            XCTAssertEqual(field.insertLSB, 0)
            for (source, expected) in cases {
                XCTAssertEqual(field.evaluatedBits(sourceBits: source), expected,
                               "source \(source), SSA \(ssa)")
            }
            XCTAssertTrue(text(function).contains("mscope_sbfx_bits_u64(in_x1, 4, 4)"))
        }
    }

    /// IR-7: `ccmp`/`ccmn` render `__conditional_compare_<suffix>(...)` rather than `__unknown`.
    func assertConditionalCompareIntrinsic(
        _ function: MacIRFunction,
        index: Int,
        suffix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .intrinsic(destination, name, _) = function.instructions[index].operation else {
            XCTFail("expected conditional_compare intrinsic, got \(function.instructions[index].operation)", file: file, line: line)
            return
        }
        XCTAssertNil(destination, file: file, line: line)
        XCTAssertEqual(name, "conditional_compare_\(suffix)", file: file, line: line)
    }
}

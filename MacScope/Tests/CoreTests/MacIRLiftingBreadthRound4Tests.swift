import XCTest
@testable import MacScope

final class MacIRLiftingBreadthRound4Tests: XCTestCase {
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

    private func lift(_ rows: [InstructionRow], name: String = "_round4") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ function: MacIRFunction) -> String {
        PseudocodePrinter().print(function: function).text
    }

    private func assertUnknown(
        _ function: MacIRFunction,
        index: Int,
        mnemonic: String,
        operands: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            function.instructions[index].operation.withoutUnknownInputs,
            .unknown(mnemonic: mnemonic, operands: operands),
            file: file,
            line: line
        )
    }

    func testNonContiguousConditionalCompareBranchesRenderHonestMarker() throws {
        // RED proof: reverting the `sawConditionalCompareSinceComparison` branch guard
        // makes these render stale `if (cmp0)` branches instead of `__branch_*`.
        let cases: [(name: String, mnemonic: String, operands: String, branch: String, wrongCondition: String, marker: String)] = [
            (
                "ccmp",
                "ccmp",
                "w9, #0x0, #0x0, hi",
                "b.eq",
                "if (w8_0 == 0x16)",
                "__branch_eq(0x1014);"
            ),
            (
                "ccmn",
                "ccmn",
                "w9, #0x1, #0x0, hi",
                "b.eq",
                "if (w8_0 == 0x16)",
                "__branch_eq(0x1014);"
            ),
            (
                "fccmp",
                "fccmp",
                "d2, d3, #0x0, eq",
                "b.lt",
                "if (arg0 < 0x5)",
                "__branch_lt(0x2014);"
            ),
            (
                "fccmpe",
                "fccmpe",
                "d2, d3, #0x0, eq",
                "b.lt",
                "if (arg0 < 0x5)",
                "__branch_lt(0x2014);"
            )
        ]

        for entry in cases {
            let isFP = entry.mnemonic.hasPrefix("f")
            let base: UInt64 = isFP ? 0x2000 : 0x1000
            let function = lift([
                row(base, "cmp", isFP ? "x0, #0x5" : "w8, #0x16"),
                row(base + 0x4, "mov", "x10, #0x1", comment: "breaks adjacency"),
                row(base + 0x8, entry.mnemonic, entry.operands),
                row(base + 0xc, entry.branch, isFP ? "0x2014" : "0x1014", comment: "skip"),
                row(base + 0x10, "mov", "x0, #0x1", comment: "body"),
                row(base + 0x14, "ret")
            ], name: "_round4_noncontig_\(entry.name)")
            let rendered = text(function)

            // IR-7: ccmp/ccmn retain a flag-effect intrinsic. fccmp/fccmpe
            // remain unknown; only SSA's proved neutral carry earns a compound
            // branch below. Legacy and unsupported FP branches retain markers.
            if entry.mnemonic == "ccmp" || entry.mnemonic == "ccmn" {
                if case let .intrinsic(_, name, _) = function.instructions[2].operation {
                    XCTAssertTrue(name.hasPrefix("conditional_compare_"), name)
                } else {
                    XCTFail("expected conditional_compare intrinsic, got \(function.instructions[2].operation)")
                }
            } else {
                assertUnknown(function, index: 2, mnemonic: entry.mnemonic, operands: entry.operands)
            }
            if function.ssaEnabled && !isFP {
                // def6ce77c352/4e4180754d7d retain same-block NZCV across the
                // unrelated MOV. The fallback NZCV=0 has Z=0, so EQ is exactly
                // (uint32(W8)>22) && (W9==0), or W9==-1 for CCMN #1.
                let second = entry.mnemonic == "ccmn"
                    ? "((uint32_t)(w9_0) == (uint32_t)(-0x1))"
                    : "(w9_0 == 0x0)"
                XCTAssertTrue(rendered.contains("if (((uint32_t)(w8_0) > (uint32_t)(0x16)) && \(second))"), rendered)
                XCTAssertFalse(rendered.contains(entry.marker), rendered)
            } else {
                XCTAssertTrue(rendered.contains(entry.marker), rendered)
            }
            XCTAssertFalse(rendered.contains(entry.wrongCondition), rendered)
        }
    }

    // A source-register write is not flag-neutral for the carried snapshot:
    // the old conservative marker remains required in this changed input.
    func testConditionalCompareSourceMutationStillRequiresMarkerInBothModes() {
        for ssa in [false, true] {
            let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_ccmp_source_mutation", instructions: [
                row(0x6000, "cmp", "w8, #0x16"),
                row(0x6004, "mov", "w8, #0x1"),
                row(0x6008, "ccmp", "w9, #0x0, #0x0, hi"),
                row(0x600c, "b.eq", "0x6014"),
                row(0x6010, "mov", "x0, #0x1"),
                row(0x6014, "ret")
            ])
            XCTAssertEqual(function.ssaEnabled, ssa)
            let rendered = text(function)
            XCTAssertTrue(rendered.contains("__branch_eq(0x6014);"), rendered)
            XCTAssertFalse(rendered.contains("if (((uint32_t)(w8_0)"), rendered)
            XCTAssertFalse(rendered.contains("if (((uint32_t)(w8_1)"), rendered)
        }
    }

    func testContiguousConditionalCompareStillUsesCompoundCondition() throws {
        let function = lift([
            row(0x3000, "cmp", "x0, #0x0"),
            row(0x3004, "ccmp", "x1, #0x0, #0x0, ne"),
            row(0x3008, "b.eq", "0x3010", comment: "body"),
            row(0x300c, "ret"),
            row(0x3010, "mov", "x0, #0x1", comment: "then"),
            row(0x3014, "b", "0x300c")
        ], name: "_round4_contiguous_ccmp")
        let rendered = text(function)

        XCTAssertTrue(rendered.contains("if ((arg0 != 0x0) && (x1_0 == 0x0))"), rendered)
        XCTAssertFalse(rendered.contains("__branch_eq"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ccmp\""), rendered)
    }

    func testFmovScalarGPRFPBitMovesRenderVisibleIntrinsic() throws {
        // RED proof: without the `fmov` scalar GPR<->FP branch, every row below
        // rendered as `__unknown("fmov", ...)`.
        let function = lift([
            row(0x4000, "fmov", "d0, x0"),
            row(0x4004, "fmov", "x8, d0"),
            row(0x4008, "fmov", "w8, s0"),
            row(0x400c, "fmov", "s0, w12"),
            row(0x4010, "ret")
        ], name: "_round4_fmov")
        let rendered = text(function)

        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: .register(name: "d0", version: 1),
                name: "fmov",
                arguments: [.argument(bindingID: .gpr(0))]
            )
        )
        XCTAssertTrue(rendered.contains(" = __fmov(arg0);"), rendered)
        if function.ssaEnabled {
            // e656c8771d24 introduced physical SIMD views: S0 is the low32 of
            // D0, not an unrelated unavailable register. Bitcasts preserve bits;
            // the W12 mask enforces the source's architectural 32-bit width.
            XCTAssertTrue(rendered.contains(" = __fmov(__bitcast_f64(d0_1));"), rendered)
            XCTAssertTrue(rendered.contains(" = __fmov(__bitcast_f32((uint32_t)(d0_1)));"), rendered)
            XCTAssertTrue(rendered.contains(" = __fmov(w12_0 & 0xffffffff);"), rendered)
        } else {
            XCTAssertTrue(rendered.contains(" = __fmov(d0_1);"), rendered)
            XCTAssertTrue(rendered.contains(" = __fmov(unavailable_s0);"), rendered)
            XCTAssertTrue(rendered.contains(" = __fmov(w12_0);"), rendered)
        }
    }

    func testFmovIncomingScalarCopiesCarryTypedBindingsWhileOtherFormsStayConservative() throws {
        let function = lift([
            row(0x4100, "fmov", "d0, d1", comment: "FP copy"),
            row(0x4104, "fmov", "s0, s1", comment: "FP copy"),
            row(0x4108, "fmov", "d1, #-1.0", comment: "FP immediate"),
            row(0x410c, "fmov", "v0.2d, v1.2d", comment: "arrangement"),
            row(0x4110, "fmov", "s0, v1.s[0]", comment: "lane"),
            row(0x4114, "ret")
        ], name: "_round4_fmov_negatives")

        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "d0", version: 1),
                source: .argument(bindingID: .simd(1))
            )
        )
        if function.ssaEnabled {
            // e656c8771d24 gives the recovered D1 input a physical low-half
            // identity. Reading S1 extracts its low32 bits, without converting
            // the numeric double or changing NaN payloads.
            XCTAssertEqual(function.instructions[1].operation,
                .assign(destination: .register(name: "s0", version: 2),
                    source: .unary(op: "__ssa_bitcast_f32", value:
                        .unary(op: "(uint32_t)", value:
                            .unary(op: "__ssa_bitcast_u64", value: .argument(bindingID: .simd(1)))))))
        } else {
            // Legacy recovery has no cross-view physical-cell proof.
            assertUnknown(function, index: 1, mnemonic: "fmov", operands: "s0, s1")
        }
        // index 2: `fmov d1, #-1.0` — IR-6 (round 6) lifts the scalar FP-immediate form to a
        // float-literal assignment (SIMD arrangements/lanes stay unknown).
        XCTAssertFalse(text(function).contains("__unknown(\"fmov\", \"d1, #-1.0\")"), text(function))
        XCTAssertTrue(text(function).contains("= -1.0;"), text(function))
        assertUnknown(function, index: 3, mnemonic: "fmov", operands: "v0.2d, v1.2d")
        assertUnknown(function, index: 4, mnemonic: "fmov", operands: "s0, v1.s[0]")
    }

    func testShiftedBitClearStyleFormsRenderParenthesizedComplement() throws {
        // RED proof: before the 4-op shifted bic/orn/eon branch, these rendered
        // as `__unknown`; before the landed printer fix, the RHS would lack `~(...)`.
        let function = lift([
            row(0x5000, "bic", "x0, x1, x2, asr #63"),
            row(0x5004, "orn", "x3, x4, x5, lsl #1"),
            row(0x5008, "eon", "x6, x7, x8, lsr #2"),
            row(0x500c, "ret")
        ], name: "_round4_shifted_bitclear")
        let rendered = text(function)

        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "&",
                left: .argument(bindingID: .gpr(1)),
                right: .unary(
                    op: "~",
                    value: .binaryExpression(
                        op: ">>",
                        left: .unary(op: "(int64_t)", value: .argument(bindingID: .gpr(2))),
                        right: .immediate(63)
                    )
                )
            )
        )
        XCTAssertTrue(rendered.contains(" = in_x1 & ~((int64_t)(in_x2) >> 0x3f);"), rendered)
        XCTAssertTrue(rendered.contains(" = in_x4 | ~((uint64_t)(in_x5) << 0x1);"), rendered)
        XCTAssertTrue(rendered.contains(" = in_x7 ^ ~((uint64_t)(x8_0) >> 0x2);"), rendered)
        XCTAssertFalse(rendered.contains("~in_x2 >> 0x3f"), rendered)
    }

    func testShiftedBitClearStyleNegativesStayUnknown() throws {
        let function = lift([
            row(0x5104, "bic", "x0, x1, v2.4s, asr #3", comment: "SIMD token"),
            row(0x5108, "ret")
        ], name: "_round4_shifted_bitclear_negatives")

        assertUnknown(function, index: 0, mnemonic: "bic", operands: "x0, x1, v2.4s, asr #3")
    }

    /// C5 (vim decompile sweep): a rotated register operand lifts to the same rotate the
    /// standalone `ror` uses, `(Xm >> s) | (Xm << (width - s))`, inside the complement.
    func testShiftedBitClearStyleRotateIsLifted() throws {
        let function = lift([
            row(0x5100, "bic", "x0, x1, x2, ror #3"),
            row(0x5104, "ret")
        ], name: "_round4_shifted_bitclear_rotate")

        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "&",
                left: .argument(bindingID: .gpr(1)),
                right: .unary(
                    op: "~",
                    value: .binaryExpression(
                        op: "|",
                        left: .binaryExpression(op: ">>", left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(2))), right: .immediate(3)),
                        right: .binaryExpression(op: "<<", left: .argument(bindingID: .gpr(2)), right: .immediate(61))
                    )
                )
            )
        )
    }
}

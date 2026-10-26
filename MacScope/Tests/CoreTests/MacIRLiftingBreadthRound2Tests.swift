import XCTest
@testable import MacScope

final class MacIRLiftingBreadthRound2Tests: XCTestCase {
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

    private func lift(_ rows: [InstructionRow], name: String = "_round2") -> MacIRFunction {
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

    private func parameterRegisters(_ function: MacIRFunction) -> [String] {
        function.parameters.map(\.register)
    }

    func testTierAExtendedAddSubCoversExplicitCastsAndReadSet() throws {
        let arg1 = MacIRValue.argument(bindingID: .gpr(1))
        let arg2 = MacIRValue.argument(bindingID: .gpr(2))
        let cases: [(String, String)] = [
            ("sxtb", "(int8_t)"),
            ("sxth", "(int16_t)"),
            ("sxtw", "(int32_t)"),
            ("uxtb", "(uint8_t)"),
            ("uxth", "(uint16_t)"),
            ("uxtw", "(uint32_t)")
        ]

        for (offset, entry) in cases.enumerated() {
            let extend = entry.0
            let cast = entry.1
            let function = lift([
                row(0x1000_0000 + UInt64(offset * 8), "add", "x9, x1, w2, \(extend)"),
                row(0x1000_0004 + UInt64(offset * 8), "ret")
            ], name: "_add_\(extend)")

            XCTAssertEqual(parameterRegisters(function), ["x1", "w2"])
            XCTAssertEqual(
                function.instructions[0].operation,
                .binary(
                    destination: .register(name: "x9", version: 1),
                    op: "+",
                    left: arg1,
                    right: .unary(op: cast, value: arg2)
                )
            )
        }

        let sub = lift([
            row(0x1000_0100, "sub", "x10, x1, w2, sxtw"),
            row(0x1000_0104, "ret")
        ], name: "_sub_sxtw")
        XCTAssertEqual(parameterRegisters(sub), ["x1", "w2"])
        XCTAssertEqual(
            sub.instructions[0].operation,
            .binary(
                destination: .register(name: "x10", version: 1),
                op: "-",
                left: arg1,
                right: .unary(op: "(int32_t)", value: arg2)
            )
        )
    }

    func testTierAExtendedShiftUsesDestinationWidthBeforeShift() throws {
        let function = lift([
            row(0x1000_0200, "add", "x9, x1, w2, uxtw #4"),
            row(0x1000_0204, "sub", "x10, x1, w2, sxtw #4"),
            row(0x1000_0208, "ret")
        ], name: "_extended_shift")
        let arg1 = MacIRValue.argument(bindingID: .gpr(1))
        let arg2 = MacIRValue.argument(bindingID: .gpr(2))

        XCTAssertEqual(parameterRegisters(function), ["x1", "w2"])
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x9", version: 1),
                op: "+",
                left: arg1,
                right: .binaryExpression(
                    op: "<<",
                    left: .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: arg2)),
                    right: .immediate(4)
                )
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .binary(
                destination: .register(name: "x10", version: 1),
                op: "-",
                left: arg1,
                right: .binaryExpression(
                    op: "<<",
                    left: .unary(op: "(int64_t)", value: .unary(op: "(int32_t)", value: arg2)),
                    right: .immediate(4)
                )
            )
        )

        let rendered = text(function)
        // The destination register is dead (written, never read before ret), so the printer
        // names it a temp; the IR-equality above pins the destination, so assert only the RHS.
        XCTAssertTrue(
            rendered.contains("/* ABI inputs: x1:int64_t in_x1, w2:int32_t in_w2 */"),
            rendered
        )
        XCTAssertTrue(rendered.contains(" = in_x1 + ((uint64_t)((uint32_t)(in_w2)) << 0x4);"), rendered)
        XCTAssertTrue(rendered.contains(" = in_x1 - ((int64_t)((int32_t)(in_w2)) << 0x4);"), rendered)
    }

    func testTierAUxtwAliasRendersExplicitUint32Cast() throws {
        let function = lift([
            row(0x1000_0300, "uxtw", "x9, w2"),
            row(0x1000_0304, "ret")
        ], name: "_uxtw_alias")

        XCTAssertEqual(parameterRegisters(function), ["w2"])
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x9", version: 1),
                source: .unary(
                    op: "(uint32_t)",
                    value: .argument(bindingID: .gpr(2))
                )
            )
        )
        let rendered = text(function)
        XCTAssertTrue(rendered.contains("/* ABI inputs: w2:int32_t in_w2 */"), rendered)
        XCTAssertTrue(rendered.contains(" = (uint32_t)(in_w2);"), rendered)
    }

    func testTierANegativesStayUnknown() throws {
        let function = lift([
            row(0x1000_0400, "adds", "x0, x1, w2, sxtw", comment: "sets flags"),
            row(0x1000_0404, "subs", "x0, x1, w2, sxtw", comment: "sets flags"),
            row(0x1000_0408, "cmp", "x1, w2, sxtw", comment: "comparison seam"),
            row(0x1000_040c, "adc", "x0, x1, x2", comment: "carry"),
            row(0x1000_0410, "sbc", "x0, x1, x2", comment: "borrow"),
            row(0x1000_0414, "ccmp", "x1, x2, #0x0, eq", comment: "conditional compare"),
            row(0x1000_0418, "add", "v0.4s, v1.4s, v2.4s", comment: "simd suffix"),
            row(0x1000_041c, "add", "x0, x1, v2.4s, uxtw", comment: "vector operand"),
            row(0x1000_0420, "ret")
        ], name: "_tier_a_negatives")

        assertUnknown(function, index: 0, mnemonic: "adds", operands: "x0, x1, w2, sxtw")
        assertUnknown(function, index: 1, mnemonic: "subs", operands: "x0, x1, w2, sxtw")
        // index 2: `cmp x1, w2, sxtw` — IR-6 (round 6) lifts the 3-op extended-register compare
        // (adds/subs flag-setting variants remain unknown; only cmp/cmn 3-op are IR-6 scope).
        XCTAssertFalse(text(function).contains("__unknown(\"cmp\""), text(function))
        XCTAssertTrue(text(function).contains("(int32_t)"), text(function))
        assertUnknown(function, index: 3, mnemonic: "adc", operands: "x0, x1, x2")
        assertUnknown(function, index: 4, mnemonic: "sbc", operands: "x0, x1, x2")
        // IR-7: ccmp now renders a flag-effect intrinsic (writes no GPR), not __unknown.
        if case let .intrinsic(_, name, _) = function.instructions[5].operation {
            XCTAssertEqual(name, "conditional_compare_eq")
        } else {
            XCTFail("expected conditional_compare intrinsic, got \(function.instructions[5].operation)")
        }
        assertUnknown(function, index: 6, mnemonic: "add", operands: "v0.4s, v1.4s, v2.4s")
        assertUnknown(function, index: 7, mnemonic: "add", operands: "x0, x1, v2.4s, uxtw")
    }

    func testTierBRegisterAmountLsrAsrLiftAndReadSet() throws {
        let function = lift([
            row(0x1000_0500, "lsr", "x9, x1, x2"),
            row(0x1000_0504, "asr", "x10, x3, x4"),
            row(0x1000_0508, "ret")
        ], name: "_tier_b_register_shift")

        XCTAssertEqual(parameterRegisters(function), ["x1", "x2", "x3", "x4"])
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x9", version: 1),
                op: ">>",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))),
                right: .binaryExpression(op: "&", left: .argument(bindingID: .gpr(2)), right: .immediate(63))
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .binary(
                destination: .register(name: "x10", version: 1),
                op: ">>",
                left: .unary(op: "(int64_t)", value: .argument(bindingID: .gpr(3))),
                right: .binaryExpression(op: "&", left: .argument(bindingID: .gpr(4)), right: .immediate(63))
            )
        )

        let rendered = text(function)
        XCTAssertTrue(
            rendered.contains(
                "/* ABI inputs: x1:int64_t in_x1, x2:int64_t in_x2, x3:int64_t in_x3, x4:int64_t in_x4 */"
            ),
            rendered
        )
        XCTAssertTrue(rendered.contains(" = (uint64_t)(in_x1) >> (in_x2 & 0x3f);"), rendered)
        XCTAssertTrue(rendered.contains(" = (int64_t)(in_x3) >> (in_x4 & 0x3f);"), rendered)
    }

    func testSIMDShiftFormsStayUnknownAndRegisterLSLLifts() throws {
        // Round 3 (IR-3) lifted register-amount lsl; SIMD/vector shift operands still stay
        // __unknown (SIMD-leak guard). Exact register-lsl IR is pinned by Round3 tests.
        let function = lift([
            row(0x1000_0600, "lsl", "x0, x1, x2", comment: "register form now lifts"),
            row(0x1000_0604, "lsr", "v0.4s, v1.4s, v2.4s", comment: "simd suffix"),
            row(0x1000_0608, "asr", "x0, x1, v2.4s", comment: "vector operand"),
            row(0x1000_060c, "ret")
        ], name: "_tier_b_negatives")

        if case .unknown = function.instructions[0].operation {
            XCTFail("register-amount lsl should lift in Round 3, not stay __unknown")
        }
        assertUnknown(function, index: 1, mnemonic: "lsr", operands: "v0.4s, v1.4s, v2.4s")
        assertUnknown(function, index: 2, mnemonic: "asr", operands: "x0, x1, v2.4s")
    }

    func testTierCShiftedLogicalFormsLiftWithParenthesizedComplement() throws {
        // Round 4 (IR-4): shifted bic/orn/eon lift to `Xn OP ~(Xm SHIFT s)`; the landed printer
        // paren fix keeps the ~ over the whole shift. Exact IR pinned by Round4 tests.
        let function = lift([
            row(0x1000_0700, "bic", "x0, x1, x2, asr #63", comment: "bic asr"),
            row(0x1000_0704, "orn", "x0, x1, x2, lsl #1", comment: "orn lsl"),
            row(0x1000_0708, "eon", "x0, x1, x2, lsr #2", comment: "eon lsr"),
            row(0x1000_070c, "ret")
        ], name: "_tier_c_shifted")

        for i in 0..<3 {
            if case .unknown = function.instructions[i].operation {
                XCTFail("shifted logical form at index \(i) should lift, not stay __unknown")
            }
        }
        let text = self.text(function)
        XCTAssertTrue(text.contains("/* ABI inputs: x1:int64_t in_x1, x2:int64_t in_x2 */"), text)
        XCTAssertTrue(text.contains("~((int64_t)(in_x2) >> 0x3f)"), text)   // bic asr #63
        XCTAssertTrue(text.contains("~((uint64_t)(in_x2) << 0x1)"), text)    // orn lsl #1
        XCTAssertTrue(text.contains("~((uint64_t)(in_x2) >> 0x2)"), text)    // eon lsr #2
        XCTAssertFalse(text.contains("__unknown(\"bic\""))
    }

    func testTierDHighMultiplyRendersVisibleIntrinsicAndReadSet() throws {
        let function = lift([
            row(0x1000_0800, "smulh", "x9, x1, x2"),
            row(0x1000_0804, "umulh", "x10, x3, x4"),
            row(0x1000_0808, "ret")
        ], name: "_tier_d_high_multiply")

        XCTAssertEqual(parameterRegisters(function), ["x1", "x2", "x3", "x4"])
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: .register(name: "x9", version: 1),
                name: "smulh",
                arguments: [
                    .argument(bindingID: .gpr(1)),
                    .argument(bindingID: .gpr(2))
                ]
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .intrinsic(
                destination: .register(name: "x10", version: 1),
                name: "umulh",
                arguments: [
                    .argument(bindingID: .gpr(3)),
                    .argument(bindingID: .gpr(4))
                ]
            )
        )

        let rendered = text(function)
        XCTAssertTrue(
            rendered.contains(
                "/* ABI inputs: x1:int64_t in_x1, x2:int64_t in_x2, x3:int64_t in_x3, x4:int64_t in_x4 */"
            ),
            rendered
        )
        XCTAssertTrue(rendered.contains(" = __smulh(in_x1, in_x2);"), rendered)
        XCTAssertTrue(rendered.contains(" = __umulh(in_x3, in_x4);"), rendered)
    }

    func testTierDHighMultiplySIMDFormsStayUnknown() throws {
        let function = lift([
            row(0x1000_0900, "smulh", "v0.2d, v1.2d, v2.2d", comment: "simd suffix"),
            row(0x1000_0904, "umulh", "x0, x1, v2.2d", comment: "vector operand"),
            row(0x1000_0908, "ret")
        ], name: "_tier_d_negatives")

        assertUnknown(function, index: 0, mnemonic: "smulh", operands: "v0.2d, v1.2d, v2.2d")
        assertUnknown(function, index: 1, mnemonic: "umulh", operands: "x0, x1, v2.2d")
    }

    func testBrkLiftsToVisibleTrapIntrinsic() throws {
        // Round 3 (IR-3): brk lifts to a visible, non-elidable __brk(...) trap intrinsic.
        let function = lift([
            row(0x1000_0a00, "brk", "#1", comment: "breakpoint"),
            row(0x1000_0a04, "ret")
        ], name: "_brk_lifted")

        XCTAssertEqual(function.instructions[0].operation, .intrinsic(destination: nil, name: "brk", arguments: [.immediate(1)]))
        XCTAssertTrue(text(function).contains("__brk(") && !text(function).contains("__unknown(\"brk\""))
    }
}

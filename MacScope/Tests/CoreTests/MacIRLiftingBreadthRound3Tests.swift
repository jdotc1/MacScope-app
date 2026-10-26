import XCTest
@testable import MacScope

final class MacIRLiftingBreadthRound3Tests: XCTestCase {
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

    private func lift(_ rows: [InstructionRow], name: String = "_round3") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ function: MacIRFunction, nopElision: Bool = false) -> String {
        var options = DecompilerOptions.default
        options.nopElision = nopElision
        return PseudocodePrinter(options: options).print(function: function).text
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

    func testTierBRKTrapRendersVisibleWithAndWithoutNopElision() throws {
        let function = lift([
            row(0x1000_0000, "brk", "#0xc471"),
            row(0x1000_0004, "ret")
        ], name: "_brk_visible")

        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: nil, name: "brk", arguments: [.immediate(0xc471)])
        )

        let defaultText = text(function, nopElision: false)
        let elidedText = text(function, nopElision: true)
        XCTAssertTrue(defaultText.contains("__brk(0xc471);"), defaultText)
        XCTAssertTrue(elidedText.contains("__brk(0xc471);"), elidedText)
    }

    func testTierBRKTrapDoesNotChangeMidBlockFlowShape() throws {
        let function = lift([
            row(0x1000_0100, "mov", "x8, x0"),
            row(0x1000_0104, "brk", "#0x1"),
            row(0x1000_0108, "add", "x9, x8, #0x2"),
            row(0x1000_010c, "ret")
        ], name: "_brk_midblock")

        XCTAssertEqual(
            function.instructions[1].operation,
            .intrinsic(destination: nil, name: "brk", arguments: [.immediate(1)])
        )

        let rendered = text(function)
        XCTAssertTrue(rendered.contains("int64_t _brk_midblock(int64_t arg0) {"), rendered)
        XCTAssertTrue(rendered.contains(" = arg0;"), rendered)
        XCTAssertTrue(rendered.contains("__brk(0x1);"), rendered)
        XCTAssertTrue(rendered.contains(" = tmp0 + 0x2;"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"brk\""), rendered)
    }

    func testTierBRKNegativesStayUnknown() throws {
        let function = lift([
            row(0x1000_0200, "brk", "x0", comment: "brk takes an immediate"),
            row(0x1000_0204, "udf", "#0x0", comment: "out of scope"),
            row(0x1000_0208, "ret")
        ], name: "_brk_negatives")

        assertUnknown(function, index: 0, mnemonic: "brk", operands: "x0")
        assertUnknown(function, index: 1, mnemonic: "udf", operands: "#0x0")
    }

    func testRegisterAmountShiftsAndRotatesMaskTheAmountByRegisterWidth() throws {
        // A64 takes a register shift/rotate amount modulo the register width (A64 oracle:
        // `lsl w0, w1, w2` with w2 = 33 shifts by 1); C leaves ≥ width undefined.
        let shift = lift([row(0x1000_0350, "lsl", "w9, w1, w2"), row(0x1000_0354, "ret")], name: "_w_lsl")
        guard case let .binary(_, op, _, right) = shift.instructions[0].operation else {
            return XCTFail("\(shift.instructions[0].operation)")
        }
        XCTAssertEqual(op, "<<")
        guard case .binaryExpression("&", _, let mask) = right else { return XCTFail("\(right)") }
        XCTAssertEqual(mask, .immediate(31))

        let rotate = lift([row(0x1000_0360, "ror", "x9, x1, x2"), row(0x1000_0364, "ret")], name: "_ror_register")
        let amount = MacIRValue.binaryExpression(op: "&", left: .argument(bindingID: .gpr(2)), right: .immediate(63))
        XCTAssertEqual(
            rotate.instructions[0].operation,
            .assign(destination: .register(name: "x9", version: 1), source: .binaryExpression(
                op: "|",
                left: .binaryExpression(op: ">>", left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))), right: amount),
                right: .binaryExpression(op: "<<", left: .argument(bindingID: .gpr(1)), right: .binaryExpression(
                    op: "&", left: .binaryExpression(op: "-", left: .immediate(64), right: amount), right: .immediate(63)))
            ))
        )
    }

    func testTierLSLRegisterAmountLiftsLikeLSRAndASRWithParameterRecovery() throws {
        let cases: [(mnemonic: String, op: String)] = [
            ("lsl", "<<"),
            ("lsr", ">>"),
            ("asr", ">>")
        ]

        for entry in cases {
            let function = lift([
                row(0x1000_0300, entry.mnemonic, "x9, x1, x2"),
                row(0x1000_0304, "ret")
            ], name: "_\(entry.mnemonic)_register_amount")

            XCTAssertEqual(parameterRegisters(function), ["x1", "x2"], entry.mnemonic)
            XCTAssertEqual(
                function.instructions[0].operation,
                .binary(
                    destination: .register(name: "x9", version: 1),
                    op: entry.op,
                    left: .unary(op: entry.mnemonic == "asr" ? "(int64_t)" : "(uint64_t)", value: .argument(bindingID: .gpr(1))),
                    // A64 takes the amount modulo 64; the mask keeps the C defined (A64 oracle).
                    right: .binaryExpression(op: "&", left: .argument(bindingID: .gpr(2)), right: .immediate(63))
                ),
                entry.mnemonic
            )

            let rendered = text(function)
            XCTAssertTrue(rendered.contains(" = \(entry.mnemonic == "asr" ? "(int64_t)" : "(uint64_t)")(in_x1) \(entry.op) (in_x2 & 0x3f);"), rendered)
        }
    }

    func testTierLSLImmediatePathStillLiftsAsImmediateShift() throws {
        let function = lift([
            row(0x1000_0400, "lsl", "x9, x1, #0x3"),
            row(0x1000_0404, "ret")
        ], name: "_lsl_immediate")

        XCTAssertEqual(parameterRegisters(function), ["x1"])
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x9", version: 1),
                op: "<<",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))),
                right: .immediate(3)
            )
        )

        let rendered = text(function)
        XCTAssertTrue(rendered.contains(" = (uint64_t)(in_x1) << 0x3;"), rendered)
    }

    func testTierLSLSIMDFormsStayUnknown() throws {
        let function = lift([
            row(0x1000_0500, "lsl", "v0.4s, v1.4s, v2.4s", comment: "simd suffix"),
            row(0x1000_0504, "lsl", "x0, x1, v2.4s", comment: "vector operand"),
            row(0x1000_0508, "lsl", "x0, x1, v2.s[0]", comment: "lane operand"),
            row(0x1000_050c, "ret")
        ], name: "_lsl_simd_negatives")

        assertUnknown(function, index: 0, mnemonic: "lsl", operands: "v0.4s, v1.4s, v2.4s")
        assertUnknown(function, index: 1, mnemonic: "lsl", operands: "x0, x1, v2.4s")
        assertUnknown(function, index: 2, mnemonic: "lsl", operands: "x0, x1, v2.s[0]")
    }

    func testTierMOVKStandaloneReadsOldDestinationAndInsertsHalfword() throws {
        let function = lift([
            row(0x1000_0600, "movk", "x0, #0xabcd, lsl #16"),
            row(0x1000_0604, "ret")
        ], name: "_movk_standalone")

        XCTAssertEqual(parameterRegisters(function), ["x0"])
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .binaryExpression(
                    op: "|",
                    left: .binaryExpression(
                        op: "&",
                        left: .argument(bindingID: .gpr(0)),
                        right: .immediate(Int64(bitPattern: 0xffff_ffff_0000_ffff))
                    ),
                    right: .immediate(0xabcd_0000)
                )
            )
        )

        let rendered = text(function)
        XCTAssertTrue(rendered.contains(" = (arg0 & -0xffff0001) | 0xabcd0000;"), rendered)
    }

    func testTierMOVKFoldedMaterializedImmediateChainStillFolds() throws {
        let function = lift([
            row(0x1000_0700, "movz", "x9, #0x1234"),
            row(0x1000_0704, "movk", "x9, #0xabcd, lsl #16"),
            row(0x1000_0708, "ret")
        ], name: "_movk_folded")

        XCTAssertEqual(
            function.instructions[1].operation,
            .assign(
                destination: .register(name: "x9", version: 2),
                source: .immediate(0xabcd_1234)
            )
        )
    }

    func testTierMOVKNegativesStayUnknown() throws {
        let function = lift([
            row(0x1000_0800, "movk", "v0.2d, #0x1", comment: "simd suffix"),
            row(0x1000_0804, "movk", "x0, x1", comment: "immediate required"),
            row(0x1000_0808, "movk", "sp, #0x1", comment: "not a data register"),
            row(0x1000_080c, "ret")
        ], name: "_movk_negatives")

        assertUnknown(function, index: 0, mnemonic: "movk", operands: "v0.2d, #0x1")
        assertUnknown(function, index: 1, mnemonic: "movk", operands: "x0, x1")
        assertUnknown(function, index: 2, mnemonic: "movk", operands: "sp, #0x1")
    }
}

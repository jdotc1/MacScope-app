import XCTest
@testable import MacScope

final class MacIRLiftingBreadthRound5Tests: XCTestCase {
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

    private func lift(_ rows: [InstructionRow], name: String = "_round5") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ function: MacIRFunction) -> String {
        PseudocodePrinter().print(function: function).text
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

    func testPostIndexLoadsRenderAccessAndBaseUpdate() throws {
        let function = lift([
            row(0x1000, "ldr", "x0, [x20], #0x8"),
            row(0x1004, "ldrb", "w1, [x2], #0x1"),
            row(0x1008, "ret")
        ])
        let rendered = text(function)

        XCTAssertTrue(rendered.contains("*("), rendered)
        XCTAssertTrue(rendered.contains("x20_0 + 0x8"), rendered)
        XCTAssertTrue(rendered.contains("in_x2 + 0x1"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ldr\""), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ldrb\""), rendered)
    }

    func testPostIndexStoresRenderStoreAndBaseUpdate() throws {
        let function = lift([
            row(0x1100, "strb", "w9, [x20], #0x1"),
            row(0x1104, "str", "x0, [x21], #0x8"),
            row(0x1108, "ret")
        ])
        let rendered = text(function)

        XCTAssertTrue(rendered.contains("*(uint8_t *)(x20_0), x20_1 = w9_0"), rendered)
        XCTAssertTrue(rendered.contains("x20_0 + 0x1"), rendered)
        XCTAssertTrue(rendered.contains("*(uint64_t *)(x21_0), x21_1 = arg0"), rendered)
        XCTAssertTrue(rendered.contains("x21_0 + 0x8"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"strb\""), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"str\""), rendered)
    }

    func testPreIndexLoadsAndStoresRenderDroppedWriteback() throws {
        // RED before this fix: `ldr x0, [x20, #0x8]!` rendered only
        // `x0_1 = *(x20_0 + 0x8);`, and `str x0, [x20, #0x8]!` rendered only
        // `*(x20_0 + 0x8) = arg0;`. Both hid the base-register writeback.
        let loadFunction = lift([
            row(0x1200, "ldr", "x0, [x20, #0x8]!"),
            row(0x1204, "ret")
        ], name: "_round5_pre_load")
        let storeFunction = lift([
            row(0x1300, "str", "x0, [x20, #0x8]!"),
            row(0x1304, "ret")
        ], name: "_round5_pre_store")
        let loadText = text(loadFunction)
        let storeText = text(storeFunction)

        XCTAssertTrue(loadText.contains("x0_1, x20_1 = *(uint64_t *)(x20_0 + 0x8), x20_0 + 0x8"), loadText)
        XCTAssertTrue(storeText.contains("*(uint64_t *)(x20_0 + 0x8), x20_1 = arg0, x20_0 + 0x8"), storeText)
        XCTAssertFalse(loadText.contains("__unknown(\"ldr\""), loadText)
        XCTAssertFalse(storeText.contains("__unknown(\"str\""), storeText)
    }

    func testNegativePostIndexDeltaRendersFoldedHexSign() throws {
        let function = lift([
            row(0x1400, "ldr", "x0, [x20], #-0x10"),
            row(0x1404, "ret")
        ])
        let rendered = text(function)

        XCTAssertTrue(rendered.contains("x20_0 - 0x10"), rendered)
        XCTAssertFalse(rendered.contains("+ -"), rendered)
    }

    func testQPostIndexCopiesBytesButNEONLaneOperationsStayUnknown() throws {
        let function = lift([
            row(0x1500, "str", "q0, [x19], #0x10"),
            row(0x1504, "ld1", "{v0.16b}, [x0], #0x10"),
            row(0x1508, "ret")
        ])
        let rendered = text(function)

        XCTAssertEqual(function.instructions[0].operation, .storeWriteback(source: .register(name: "v0", version: 0), baseDestination: .register(name: "x19", version: 1), baseSource: .register(name: "x19", version: 0), delta: 16, preIndex: false))
        assertUnknown(function, index: 1, mnemonic: "ld1", operands: "{v0.16b}, [x0], #0x10")
        XCTAssertFalse(rendered.contains("__unknown(\"str\""), rendered)
        XCTAssertTrue(rendered.contains("__unknown(\"ld1\", \"{v0.16b}, [x0], #0x10\")"), rendered)
    }

    func testAddedUnscaledSignedLoadWidthTables() throws {
        XCTAssertEqual(MacIRBuilder.loadStoreByteWidth(mnemonic: "ldursw", register: "x0"), 4)
        XCTAssertEqual(MacIRBuilder.sizedAccessElementType(mnemonic: "ldursw"), "int32_t")
        XCTAssertEqual(MacIRBuilder.loadStoreByteWidth(mnemonic: "ldursb", register: "x0"), 1)
        XCTAssertEqual(MacIRBuilder.sizedAccessElementType(mnemonic: "ldursb"), "int8_t")
        // C5 D4 (vim sweep): the halfword form was missing.
        XCTAssertEqual(MacIRBuilder.loadStoreByteWidth(mnemonic: "ldursh", register: "x0"), 2)
        XCTAssertEqual(MacIRBuilder.sizedAccessElementType(mnemonic: "ldursh"), "int16_t")
    }

    func testWritebackReadWriteProjectionsIncludeBaseOnlyWhereAppropriate() throws {
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "ldr", operands: ["x0", "[x1]", "#0x8"])),
            Set(["x1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterWrites(mnemonic: "ldr", operands: ["x0", "[x1]", "#0x8"])),
            Set(["x0", "x1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "str", operands: ["x2", "[x1]", "#0x8"])),
            Set(["x2", "x1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterWrites(mnemonic: "str", operands: ["x2", "[x1]", "#0x8"])),
            Set(["x1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterReads(mnemonic: "str", operands: ["x2", "[x1, #0x8]!"])),
            Set(["x2", "x1"])
        )
        XCTAssertEqual(
            Set(MacIRBuilder.argumentRegisterWrites(mnemonic: "str", operands: ["x2", "[x1, #0x8]!"])),
            Set(["x1"])
        )

        let function = lift([
            row(0x1600, "ldr", "x0, [x1], #0x8"),
            row(0x1604, "ret")
        ])
        let operation = function.instructions[0].operation
        XCTAssertTrue(PseudocodePrinter().writesRegister("x0", operation: operation))
        XCTAssertTrue(PseudocodePrinter().writesRegister("x1", operation: operation))
    }

    func testStackBaseWritebacksAreExplicitAndNonStackPairsAreUnknown() throws {
        let spPost = lift([
            row(0x1700, "ldr", "x0, [sp], #0x10"),
            row(0x1704, "ret")
        ], name: "_round5_sp_post")
        let spPre = lift([
            row(0x1710, "ldr", "x0, [sp, #0x10]!"),
            row(0x1714, "ret")
        ], name: "_round5_sp_pre")
        let stackPair = lift([
            row(0x1720, "stp", "x29, x30, [sp, #-0x10]!"),
            row(0x1724, "ret")
        ], name: "_round5_sp_pair")
        let nonStackPair = lift([
            row(0x1730, "ldp", "x0, x1, [x2], #0x10"),
            row(0x1734, "ret")
        ], name: "_round5_non_sp_pair")

        XCTAssertEqual(spPost.instructions[0].operation, .loadWriteback(destination: .register(name: "x0", version: 1), baseDestination: .register(name: "sp", version: 1), baseSource: .register(name: "sp", version: 0), delta: 16, preIndex: false))
        XCTAssertEqual(spPre.instructions[0].operation, .loadWriteback(destination: .register(name: "x0", version: 1), baseDestination: .register(name: "sp", version: 1), baseSource: .register(name: "sp", version: 0), delta: 16, preIndex: true))
        XCTAssertTrue(text(spPre).contains("sp_0 + 0x10"), text(spPre))
        XCTAssertTrue(text(stackPair).contains("*(uint64_t *)(sp_0 + -0x10), *(uint64_t *)((sp_0 + -0x10) + 0x8), sp_1 = x29_0, x30_0, sp_0 - 0x10"), text(stackPair))
        assertUnknown(nonStackPair, mnemonic: "ldp", operands: "x0, x1, [x2], #0x10")
        XCTAssertTrue(text(nonStackPair).contains("__unknown(\"ldp\", \"x0, x1, [x2], #0x10\")"), text(nonStackPair))
    }

    func testMissingSignedUnscaledAndPairMnemonicsLiftConservatively() throws {
        let function = lift([
            row(0x1800, "ldursw", "x0, [x20, #0x4]"),
            row(0x1804, "ldursb", "x1, [x20]"),
            row(0x1808, "ldpsw", "x2, x3, [x20, #0x8]"),
            row(0x180c, "ldursh", "x10, [x22, #-0x24]"),
            row(0x1810, "ret")
        ])
        let rendered = text(function)

        XCTAssertFalse(rendered.contains("__unknown(\"ldursh\""), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ldursw\""), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ldursb\""), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ldpsw\""), rendered)
        XCTAssertTrue(rendered.contains("*(int32_t *)(x20_0 + 0x4)"), rendered)
        XCTAssertTrue(rendered.contains("x2_1, x3_1 = *(int32_t *)(x20_0 + 0x8), *(int32_t *)((x20_0 + 0x8) + 0x4)"), rendered)
    }
}

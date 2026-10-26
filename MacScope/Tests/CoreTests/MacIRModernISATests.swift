import XCTest
@testable import MacScope

/// MS-22 / MS-24 MacIR register effects for the AArch64 families the decoder
/// learned (FEAT_PAuth_LR, PAC 1716, FEAT_MOPS, FEAT_THE RCW, LDRAA/LDRAB,
/// FJCVTZS, CRC32) and the LSE SWP / LD<op> / CAS / CASP write gap. Each
/// "written" case seeds the register with a known constant first: a missed
/// write would let the later read fold back to that constant.
final class MacIRModernISATests: XCTestCase {
    private func row(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String = ""
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }

    private func rows(_ instructions: [(String, String)]) -> [InstructionRow] {
        instructions.enumerated().map { index, instruction in
            row(0x1000 + UInt64(index) * 4, instruction.0, instruction.1)
        }
    }

    private func lift(_ instructions: [(String, String)]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: "_modern_isa", instructions: rows(instructions))
    }

    private func text(_ instructions: [(String, String)]) -> String {
        PseudocodePrinter().print(function: lift(instructions)).text
    }

    private func operation(_ function: MacIRFunction, _ mnemonic: String) -> MacIROperation? {
        function.instructions.first { $0.source.mnemonic == mnemonic }?.operation
    }

    private func isCompareToBool(_ operation: MacIROperation?) -> Bool {
        if case .compareToBool = operation { return true }
        return false
    }

    // MARK: - FEAT_PAuth_LR and PAC 1716

    func testRetaasppcrTerminatesWithoutWritingItsModifier() {
        let function = lift([
            ("add", "x0, x5, #0x1"),
            ("retaasppcr", "x5"),
        ])
        guard case .returnValue = function.instructions.last?.operation else {
            return XCTFail("retaasppcr must lift as a return: \(String(describing: function.instructions.last?.operation))")
        }
        let output = PseudocodePrinter().print(function: function).text
        XCTAssertFalse(output.contains("x5_1"), output)
        XCTAssertFalse(output.contains("unavailable_x5"), output)
    }

    func testAutiasppcrReadsItsModifierAndLeavesItUnchanged() {
        let function = lift([
            ("mov", "x5, #0x7"),
            ("autiasppcr", "x5"),
            ("mov", "x0, x5"),
            ("ret", ""),
        ])
        XCTAssertEqual(
            operation(function, "autiasppcr"),
            .intrinsic(destination: nil, name: "autiasppcr", arguments: [])
        )
        let output = PseudocodePrinter().print(function: function).text
        XCTAssertFalse(output.contains("unavailable_x5"), output)
        XCTAssertFalse(output.contains("x5_2"), output)
        XCTAssertFalse(output.contains("__unknown(\"autiasppcr\""), output)
    }

    func testPacia1716WritesX17() {
        for mnemonic in ["pacia1716", "autib1716", "pacia171615", "autib171615"] {
            let function = lift([
                ("mov", "x17, #0x5"),
                (mnemonic, ""),
                ("mov", "x0, x17"),
                ("ret", ""),
            ])
            XCTAssertEqual(
                operation(function, mnemonic),
                .intrinsic(destination: nil, name: mnemonic, arguments: [])
            )
            let output = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(output.contains("unavailable_x17"), "\(mnemonic): \(output)")
        }
    }

    // PAC writes X17, not its modifier registers. Refusal definitions do not
    // allocate a named SSA version, so a subsequent explicit X17 write is v2.
    // These literal encodings are supplied as source bytes, not decoder receipts.
    func testPACImplicitWritePreservesModifiersAndAllowsFreshDefinitionInBothModes() {
        let cases = [
            ("pacia1716", "1f 21 03 d5"), ("pacib1716", "5f 21 03 d5"),
            ("autia1716", "9f 21 03 d5"), ("autib1716", "df 21 03 d5"),
            ("pacia171615", "fe 8b c1 da"), ("pacib171615", "fe 8f c1 da"),
            ("autia171615", "fe bb c1 da"), ("autib171615", "fe bf c1 da")
        ]
        for ssa in [false, true] {
            for (mnemonic, bytes) in cases {
                let source = [
                    ("b1 00 80 d2", "mov", "x17, #0x5"),
                    ("d0 00 80 d2", "mov", "x16, #0x6"),
                    ("ef 00 80 d2", "mov", "x15, #0x7"),
                    (bytes, mnemonic, ""),
                    ("e0 03 11 aa", "mov", "x0, x17"),
                    ("e1 03 10 aa", "mov", "x1, x16"),
                    ("e2 03 0f aa", "mov", "x2, x15"),
                    ("31 01 80 d2", "mov", "x17, #0x9"),
                    ("e0 03 11 aa", "mov", "x0, x17"),
                    ("c0 03 5f d6", "ret", "")
                ].enumerated().map { index, entry in
                    InstructionRow(address: 0x1000 + UInt64(index) * 4, bytes: entry.0,
                        mnemonic: entry.1, operands: entry.2, hasBreakpoint: false, comment: nil)
                }
                let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_pac_clobber", instructions: source)
                XCTAssertEqual(function.ssaEnabled, ssa)
                let effect = MacIRBuilder.ssaEffects(for: function.instructions[3].source)
                // This is the conservative may-read union: legacy1716 may
                // consume X15 when PAuth_LR and PACM apply; no feature evidence
                // here permits dropping that dependency.
                let expectedReads = [15, 16, 17]
                XCTAssertEqual(effect.reads.cells, expectedReads)
                XCTAssertEqual(effect.readViews,
                    Dictionary(uniqueKeysWithValues: expectedReads.map { ($0, MacIRSSA.ScalarView.integer) }))
                XCTAssertEqual(effect.writes, [MacIRSSA.Write(cell: 17, bitWidth: 64, view: .integer,
                    origin: .refusal(.unknownEffects, 0x100c))])
                XCTAssertEqual(function.instructions[4].operation,
                    .assign(destination: .register(name: "x0", version: 1), source: .unknown("unavailable_x17")))
                XCTAssertEqual(function.instructions[5].operation,
                    .assign(destination: .register(name: "x1", version: 1), source: .register(name: "x16", version: 1)))
                XCTAssertEqual(function.instructions[6].operation,
                    .assign(destination: .register(name: "x2", version: 1), source: .register(name: "x15", version: 1)))
                XCTAssertEqual(function.instructions[7].operation,
                    .assign(destination: .register(name: "x17", version: 2), source: .immediate(9)))
                XCTAssertEqual(function.instructions[8].operation,
                    .assign(destination: .register(name: "x0", version: 2), source: .register(name: "x17", version: 2)))
            }
        }
    }

    // MARK: - FEAT_THE RCW

    func testRcwswpWritesXtAndInvalidatesTheComparison() {
        let function = lift([
            ("mov", "x2, #0x5"),
            ("cmp", "x3, #0x1"),
            ("rcwswp", "x1, x2, [x0]"),
            ("cset", "w0, eq"),
            ("add", "x0, x0, x2"),
            ("ret", ""),
        ])
        XCTAssertFalse(isCompareToBool(operation(function, "cset")), "\(function.instructions)")
        let output = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(output.contains("unavailable_x2"), output)
        // Xs is only read for SWP: no claimed destination, x1 keeps its version.
        XCTAssertFalse(output.contains("= __unknown(\"rcwswp\""), output)
        XCTAssertFalse(output.contains("unavailable_x1"), output)
    }

    func testRcwCompareAndSwapWritesXs() {
        let output = text([
            ("mov", "x1, #0x5"),
            ("rcwcasal", "x1, x2, [x0]"),
            ("mov", "x0, x1"),
            ("ret", ""),
        ])
        XCTAssertTrue(output.contains("unavailable_x1"), output)
    }

    // MARK: - FEAT_MOPS

    // MacIR proves a register stack-derived only for the frame pointer
    // (`add x29, sp, #imm`), the same rule the unmodeled-store path uses.
    private func stackSlotProgram(_ middle: [(String, String)]) -> [(String, String)] {
        [
            ("sub", "sp, sp, #0x20"),
            ("mov", "x8, #0x5"),
            ("str", "x8, [sp, #0x8]"),
            ("add", "x29, sp, #0x10"),
        ] + middle + [
            ("ldr", "x0, [sp, #0x8]"),
            ("add", "sp, sp, #0x20"),
            ("ret", ""),
        ]
    }

    func testMemorySetOnStackDerivedDestinationInvalidatesTheStackSlot() {
        let control = lift(stackSlotProgram([("nop", "")]))
        let controlLoad = operation(control, "ldr")
        guard case .stackSlotRead? = controlLoad else {
            return XCTFail("control must forward the stored slot: \(String(describing: controlLoad))")
        }
        for mnemonic in ["setp", "setm", "sete"] {
            let function = lift(stackSlotProgram([(mnemonic, "[x29]!, x1!, x2")]))
            XCTAssertNotEqual(operation(function, "ldr"), controlLoad, "\(mnemonic) must invalidate the slot")
            let output = PseudocodePrinter().print(function: function).text
            XCTAssertFalse(output.contains("recovered stack[0x8]"), output)
        }
    }

    func testMemoryCopyWritesDestinationSourceAndCount() {
        let output = text([
            ("mov", "x1, #0x5"),
            ("mov", "x2, #0x6"),
            ("cpyfp", "[x0]!, [x1]!, x2!"),
            ("add", "x0, x1, x2"),
            ("ret", ""),
        ])
        XCTAssertTrue(output.contains("unavailable_x1"), output)
        XCTAssertTrue(output.contains("unavailable_x2"), output)
    }

    // MARK: - LSE write gap

    func testAtomicSwapCompareAndSwapAndPairWriteTheirResultRegisters() {
        let cases: [(String, String, [String])] = [
            ("swpal", "x1, x2, [x0]", ["x2"]),
            ("ldaddl", "x1, x2, [x0]", ["x2"]),
            ("casa", "x2, x3, [x0]", ["x2"]),
            ("casp", "x2, x3, x4, x5, [x0]", ["x2", "x3"]),
        ]
        for (mnemonic, operands, written) in cases {
            let output = text([
                ("mov", "x2, #0x5"),
                ("mov", "x3, #0x6"),
                (mnemonic, operands),
                ("add", "x0, x2, x3"),
                ("ret", ""),
            ])
            for register in written {
                XCTAssertTrue(output.contains("unavailable_\(register)"), "\(mnemonic): \(output)")
            }
            XCTAssertFalse(output.contains("= __unknown(\"\(mnemonic)\""), output)
        }
    }

    // MARK: - FJCVTZS, CRC32, LDRAA

    func testFjcvtzsIsAnIntrinsicThatInvalidatesTheComparison() {
        let function = lift([
            ("cmp", "x1, #0x1"),
            ("fjcvtzs", "w0, d0"),
            ("cset", "w2, eq"),
            ("add", "w0, w0, w2"),
            ("ret", ""),
        ])
        guard case let .intrinsic(destination, name, _)? = operation(function, "fjcvtzs") else {
            return XCTFail("\(function.instructions)")
        }
        XCTAssertEqual(name, "fjcvtzs")
        XCTAssertNotNil(destination)
        XCTAssertFalse(isCompareToBool(operation(function, "cset")), "\(function.instructions)")
    }

    func testCrc32IsANamedIntrinsicWithAWResult() {
        let function = lift([
            ("crc32cx", "w0, w1, x2"),
            ("ret", ""),
        ])
        guard case let .intrinsic(destination, name, arguments)? = operation(function, "crc32cx") else {
            return XCTFail("\(function.instructions)")
        }
        XCTAssertEqual(name, "crc32cx")
        XCTAssertEqual(destination, .register(name: "w0", version: 1))
        XCTAssertEqual(arguments.count, 2)
    }

    func testLdraaPreIndexWritesTheDestinationAndTheBase() {
        let output = text([
            ("mov", "x1, #0x40"),
            ("ldraa", "x0, [x1, #0x8]!"),
            ("add", "x0, x0, x1"),
            ("ret", ""),
        ])
        XCTAssertTrue(output.contains("= __unknown(\"ldraa\""), output)
        XCTAssertTrue(output.contains("unavailable_x1"), output)
    }
}

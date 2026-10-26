import XCTest
@testable import MacScope

/// UD-1: a destination-writing `.unknown` op must claim its destination —
/// bump the SSA version and render as `w0_1 = __unknown(...)` — so downstream
/// reads bind to the (unknown-valued) result instead of the stale prior
/// version. Without the claim, `cset w0, eq; ret` renders `return arg0;`
/// (or a mis-inferred void `return;` when w0 was never read), i.e. code
/// computing a different value than the instruction stream.
///
/// The claim must stay strictly narrower than `firstOperandWriteForUnknown`:
/// that helper over-approximates (safe for its cache-invalidation job), but
/// store-family / `swp*` / LSE `ld<op>*` mnemonics READ their first operand,
/// and claiming a phantom destination there would sever true dataflow the
/// other way.
final class MacIRUnknownDestinationTests: XCTestCase {
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

    private func lift(_ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: "_ud1", instructions: rows)
    }

    private func text(_ rows: [InstructionRow]) -> String {
        PseudocodePrinter().print(function: lift(rows)).text
    }

    // The /bin/zsh 0x100020998 shape: w0 never read before the unknown write,
    // so the missing SSA bump also mis-inferred a void return (`return;`).
    func testDestinationWritingUnknownRendersAssignmentAndReturnsResult() {
        let output = text([
            row(0x1000, "cset", "w0, eq"),
            row(0x1004, "ret"),
        ])
        XCTAssertTrue(output.contains("w0_1 = __unknown(\"cset\", \"w0, eq\");"), output)
        XCTAssertTrue(output.contains("return w0_1;"), output)
    }

    // The clang-fixture shape: w0 read earlier (arg0 synthesized), so the
    // stale binding rendered `return arg0;` even though cset overwrote w0.
    func testDownstreamReadBindsToUnknownResultNotPriorVersion() {
        let output = text([
            row(0x1000, "add", "w1, w0, #0x1"),
            row(0x1004, "cset", "w0, eq"),
            row(0x1008, "ret"),
        ])
        XCTAssertTrue(output.contains("w0_1 = __unknown(\"cset\", \"w0, eq\");"), output)
        XCTAssertTrue(output.contains("return w0_1;"), output)
        XCTAssertFalse(output.contains("return arg0;"), output)
    }

    // Store-family unknowns READ their first operand: no LHS, no version bump.
    // (The truncated operand string keeps this strb on the unknown path.)
    func testStoreLikeUnknownDoesNotClaimDestination() {
        let output = text([
            row(0x1000, "mov", "w0, #0x5"),
            row(0x1004, "strb", "w0"),
            row(0x1008, "ret"),
        ])
        XCTAssertTrue(output.contains("__unknown(\"strb\", \"w0\");"), output)
        XCTAssertFalse(output.contains("= __unknown(\"strb\""), output)
        XCTAssertFalse(output.contains("w0_2"), output)
    }

    // The IR op itself carries the claimed destination (fresh SSA version),
    // and the two-argument factory still builds the bare destination-less form.
    func testUnknownOpCarriesClaimedDestinationInIR() {
        let function = lift([
            row(0x1000, "cset", "w0, eq"),
            row(0x1004, "ret"),
        ])
        XCTAssertEqual(
            function.instructions.first?.operation.withoutUnknownInputs,
            .unknown(
                destination: .register(name: "w0", version: 1),
                mnemonic: "cset",
                operands: "w0, eq"
            )
        )
        XCTAssertEqual(
            MacIROperation.unknown(mnemonic: "cset", operands: "w0, eq"),
            .unknown(destination: nil, mnemonic: "cset", operands: "w0, eq")
        )
    }

    // LSE swp writes its SECOND operand; the first is the stored value (a read).
    // (The w1 write itself is invalidated now; MacIRModernISATests pins that.)
    func testAtomicSwapUnknownDoesNotClaimDestination() {
        let output = text([
            row(0x1000, "swpal", "w0, w1, [x2]"),
            row(0x1004, "ret"),
        ])
        XCTAssertTrue(output.contains("__unknown(\"swpal\", \"w0, w1, [x2]\");"), output)
        XCTAssertFalse(output.contains("= __unknown(\"swpal\""), output)
        XCTAssertFalse(output.contains("w0_1"), output)
    }

    // The NZCV manipulators read their first GPR operand (rmif sets flags
    // FROM the register), as do the wfet/wfit timeout waits.
    func testFlagManipulatorAndTimeoutWaitUnknownsDoNotClaimDestination() {
        for (mnemonic, operands) in [("rmif", "x0, #0x1, #0x2"), ("setf8", "w0"), ("wfet", "x0")] {
            let output = text([
                row(0x1000, mnemonic, operands),
                row(0x1004, "ret"),
            ])
            XCTAssertFalse(output.contains("= __unknown(\"\(mnemonic)\""), output)
            XCTAssertTrue(output.contains("__unknown(\"\(mnemonic)\", \"\(operands)\");"), output)
        }
    }

    // The for-loop only-writer guard is the ONLY caller of `writesRegister`, and
    // `writesRegister` ends in `default: return false` — so a newly destination-carrying
    // op that forgets its arm fails SILENTLY (an in-body `__unknown` clobbering the
    // induction register would be folded into an unsound `for (init; cond; step)`).
    // Pin both directions directly on the guard, mirroring the IR-5 writeback test.
    func testWritesRegisterSeesTheClaimedUnknownDestination() {
        let printer = PseudocodePrinter()

        let claimed = MacIROperation.unknown(
            destination: .register(name: "x8", version: 1),
            mnemonic: "csel",
            operands: "x8, x9, x10, eq"
        )
        XCTAssertTrue(printer.writesRegister("x8", operation: claimed))
        XCTAssertFalse(printer.writesRegister("x9", operation: claimed))

        // A destination-less (read-family) unknown must still report no write.
        let bare = MacIROperation.unknown(mnemonic: "strb", operands: "w0, [x1]")
        XCTAssertFalse(printer.writesRegister("w0", operation: bare))
    }

    // MARK: - HOP-2: the reads of an unknown

    private func unknownInputs(_ function: MacIRFunction, at index: Int = 0) throws -> MacIRUnknownInputs {
        try XCTUnwrap(
            function.instructions[index].operation.unknownInputs,
            "instruction \(index) must lift to .unknown: \(function.instructions[index].operation)"
        )
    }

    /// Output neutrality: printing with the read sets stripped gives the
    /// same text, so recording reads never changes pseudocode.
    private func assertPrintedTextIgnoresInputs(
        _ function: MacIRFunction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var stripped = function
        stripped.instructions = function.instructions.map {
            MacIRInstruction(source: $0.source, operation: $0.operation.withoutUnknownInputs)
        }
        XCTAssertNotEqual(stripped.instructions, function.instructions, "fixture records no reads", file: file, line: line)
        XCTAssertEqual(
            PseudocodePrinter().print(function: function).text,
            PseudocodePrinter().print(function: stripped).text,
            file: file,
            line: line
        )
    }

    func testHalfFmaddRecordsItsThreeSourcesAndNotItsDestination() throws {
        let function = lift([
            row(0x1000, "fmadd", "h0, h1, h2, h3"),
            row(0x1004, "ret"),
        ])
        let inputs = try unknownInputs(function)
        XCTAssertEqual(inputs.mayReadRegisters, ["h1", "h2", "h3"])
        XCTAssertEqual(inputs.definiteReadRegisters, ["h1", "h2", "h3"])
        XCTAssertFalse(inputs.mayReadNZCV)
        XCTAssertTrue(PseudocodePrinter().print(function: function).text
            .contains("__unknown(\"fmadd\", \"h0, h1, h2, h3\")"))
        assertPrintedTextIgnoresInputs(function)
    }

    // fccmp reads both FP operands and the flags (its condition), and writes NZCV.
    func testFccmpRecordsBothOperandsAndTheFlagsItTests() throws {
        let function = lift([
            row(0x1000, "fccmp", "s0, s1, #0x0, eq"),
            row(0x1004, "ret"),
        ])
        let inputs = try unknownInputs(function)
        XCTAssertEqual(inputs.mayReadRegisters, ["s0", "s1"])
        XCTAssertEqual(inputs.definiteReadRegisters, ["s0", "s1"])
        XCTAssertTrue(inputs.mayReadNZCV)
        XCTAssertTrue(inputs.definitelyReadsNZCV)
        assertPrintedTextIgnoresInputs(function)
    }

    // adc/sbc read both sources and the carry flag; the destination is write-only.
    func testAddAndSubtractWithCarryReadSourcesAndCarryFlag() throws {
        for (mnemonic, operands, sources) in [
            ("adc", "x0, x1, x2", ["x1", "x2"]),
            ("sbc", "w0, w1, w2", ["w1", "w2"]),
            ("adcs", "x3, x3, x4", ["x3", "x4"]),
        ] {
            let function = lift([
                row(0x1000, mnemonic, operands),
                row(0x1004, "ret"),
            ])
            let inputs = try unknownInputs(function)
            XCTAssertEqual(inputs.mayReadRegisters, sources, mnemonic)
            XCTAssertEqual(inputs.definiteReadRegisters, sources, mnemonic)
            XCTAssertTrue(inputs.definitelyReadsNZCV, mnemonic)
            assertPrintedTextIgnoresInputs(function)
        }
    }

    // LSE ld<op>/swp read Xs and the base and write Xt without reading it;
    // cas reads the compare value, the new value and the base.
    func testLSEAtomicsReadSourceAndBaseRegister() throws {
        for (mnemonic, operands, reads) in [
            ("ldadd", "w0, w1, [x2]", ["w0", "x2"]),
            ("ldaddal", "x3, x4, [sp]", ["x3", "sp"]),
            ("swp", "w5, w6, [x7]", ["w5", "x7"]),
            ("cas", "x0, x1, [x2]", ["x0", "x1", "x2"]),
            ("casal", "w8, w9, [x10]", ["w8", "w9", "x10"]),
        ] {
            let function = lift([
                row(0x1000, mnemonic, operands),
                row(0x1004, "ret"),
            ])
            let inputs = try unknownInputs(function)
            XCTAssertEqual(inputs.mayReadRegisters, reads, mnemonic)
            XCTAssertEqual(inputs.definiteReadRegisters, reads, mnemonic)
            XCTAssertFalse(inputs.mayReadNZCV, mnemonic)
            assertPrintedTextIgnoresInputs(function)
        }
    }

    // `ldaxr x0, [x1]` names x0 but only writes it: x0 is in neither read
    // set, and the definite reads add no parameter.
    func testWriteOnlyDestinationIsNotARead() throws {
        let function = lift([
            row(0x1000, "ldaxr", "x0, [x1]"),
            row(0x1004, "ret"),
        ])
        let inputs = try unknownInputs(function)
        XCTAssertEqual(inputs.mayReadRegisters, ["x1"])
        XCTAssertEqual(inputs.definiteReadRegisters, ["x1"])
        XCTAssertFalse(function.parameters.contains { $0.register == "x0" })
    }

    // Reads bind to the SSA value live before the instruction: an argument
    // read only by an unknown lands in the binding audit's use list, and a
    // register redefined earlier binds to the redefinition.
    func testReadsBindToLiveValuesAndEnterTheUseList() throws {
        let function = lift([
            row(0x1000, "add", "x9, x1, #0x1"),
            row(0x1004, "add", "x2, x9, x9"),
            row(0x1008, "adc", "x0, x1, x2"),
            row(0x100c, "ret"),
        ])
        let inputs = try unknownInputs(function, at: 2)
        let x1 = try XCTUnwrap(inputs.mayRead.first { $0.register == "x1" })
        guard case .argument = x1.value else {
            return XCTFail("x1 must bind to its entry argument: \(x1.value)")
        }
        let x2 = try XCTUnwrap(inputs.mayRead.first { $0.register == "x2" })
        XCTAssertNotEqual(x2.value, .register(name: "x2", version: 0))
        let audit = function.parameterBindingAudit()
        XCTAssertTrue(
            audit.records.contains { $0.bodyUses.contains { $0.address == 0x1008 } },
            "\(audit.records)"
        )
        XCTAssertTrue(audit.danglingBodyUses.isEmpty)
    }

    // A malformed-operand fallback unknown records its reads too, and the
    // zero register is never a read.
    func testFallbackUnknownRecordsReadsAndSkipsZeroRegister() throws {
        let inputs = MacIRBuilder.unknownInstructionReadSets(mnemonic: "madd", operands: ["x0", "x1"])
        XCTAssertEqual(inputs.mayRead, ["x1"])
        let zero = MacIRBuilder.unknownInstructionReadSets(mnemonic: "ldadd", operands: ["xzr", "x1", "[x2]"])
        XCTAssertEqual(zero.mayRead, ["x2"])
        let list = MacIRBuilder.unknownInstructionReadSets(mnemonic: "st1", operands: ["{v0.16b-v2.16b}", "[x0]"])
        XCTAssertEqual(list.mayRead, ["v0", "v1", "v2", "x0"])
        let accumulate = MacIRBuilder.unknownInstructionReadSets(mnemonic: "fmla", operands: ["v0.4s", "v1.4s", "v2.s[1]"])
        XCTAssertEqual(accumulate.mayRead, ["v0", "v1", "v2"])
        XCTAssertEqual(accumulate.definiteRead, [])
    }
}

extension MacIROperation {
    /// Test projection: the operation with its `.unknown` read sets cleared,
    /// for assertions about destination, mnemonic and operands only. The
    /// read sets themselves are pinned by the HOP-2 tests above.
    var withoutUnknownInputs: MacIROperation {
        guard case let .unknown(destination, _, mnemonic, operands) = self else { return self }
        return .unknown(destination: destination, mnemonic: mnemonic, operands: operands)
    }
}

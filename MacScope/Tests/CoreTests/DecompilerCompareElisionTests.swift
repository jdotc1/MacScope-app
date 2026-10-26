import XCTest
@testable import MacScope

final class DecompilerCompareElisionTests: XCTestCase {
    func testDeepFallthroughAndLoopDecisionsWithIterativeTraversal() throws {
        let left = MacIRValue.register(name: "w8", version: 0)
        let start: UInt64 = 0x1000
        var instructions: [MacIRInstruction] = []
        func append(_ mnemonic: String, _ operation: MacIROperation) {
            instructions.append(MacIRInstruction(source: MacIRSourceSpan(
                address: start + UInt64(instructions.count) * 4,
                byteText: "00 00 00 00", mnemonic: mnemonic, operands: ""), operation: operation))
        }
        append("cmp", .intrinsic(destination: nil, name: "compare", arguments: [left, .immediate(0)]))
        for _ in 0..<200_000 {
            append("mov", .assign(destination: .register(name: "x12", version: 1), source: .immediate(1)))
        }
        append("b.eq", .conditionalBranch(condition: "==", left: left, right: .immediate(0),
                                          target: .immediate(0)))
        append("ret", .returnValue(nil))
        let function = MacIRFunction(name: "_deep_fallthrough", startAddress: start, instructions: instructions)
        let decisions = PseudocodePrinter(options: .default).compareElisionDecision(function: function,
            names: PseudocodeNameContext(function: function))
        XCTAssertEqual(decisions, [0: .elide])

        // Preserve the established loop fixture's decisions: alias writes make
        // the old flags stale, while unrelated writes permit compare elision.
        XCTAssertEqual(try rejection(loopProof(writtenRegister: "x8")).reason, .loopStaleVersion)
        let loop = loopProof(writtenRegister: "x12")
        XCTAssertEqual(PseudocodePrinter(options: .default).compareElisionDecision(function: loop,
            names: PseudocodeNameContext(function: loop)), [0: .elide])
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func render(_ name: String, _ rows: [InstructionRow]) -> PseudocodeDocument {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        return PseudocodePrinter(options: options).print(
            function: MacIRBuilder().buildFunction(name: name, instructions: rows)
        )
    }

    // Independent literal expectation, not a call back into the production renderer.
    private func signedWordExpectation(_ name: String) -> String {
        "(((\(name) & 0x80000000) == 0 ? (int32_t)\(name) : -1 - (int32_t)(uint32_t)~\(name)))"
    }

    private func sourceText(_ document: PseudocodeDocument, _ address: UInt64) -> [String] {
        document.lines(sourcedAt: address).map(\.text)
    }

    // Evaluate the actual lifted expression with the existing defined-C arithmetic
    // oracle. This is not a second implementation of the architectural operation.
    private func multiplyBoundary(_ mnemonic: String, width: Int,
                                  a: UInt64, b: UInt64, c: UInt64 = 0,
                                  expected: UInt64) throws {
        typealias C = OrdinaryC
        let prefix = width == 32 ? "w" : "x"
        let operands = "\(prefix)11, \(prefix)8, \(prefix)9" + (mnemonic == "madd" ? ", \(prefix)10" : "")
        let function = MacIRBuilder().buildFunction(name: "_multiply_boundary", instructions: [
            row(0x1000, "sdiv", "\(prefix)8, \(prefix)12, \(prefix)13"),
            row(0x1004, "sdiv", "\(prefix)9, \(prefix)14, \(prefix)15"),
            row(0x1008, "sdiv", "\(prefix)10, \(prefix)16, \(prefix)17"),
            row(0x100c, mnemonic, operands), row(0x1010, "ret")
        ])
        XCTAssertEqual(function.ssaEnabled, MacIRConfiguration.ssaEnabled,
                       "a requested SSA check must not pass through a legacy fallback")
        let operation = try XCTUnwrap(function.instructions.first { $0.source.address == 0x100c }).operation
        let expression: MacIRValue
        switch operation {
        case let .binary(_, op, left, right): expression = .binaryExpression(op: op, left: left, right: right)
        case let .assign(_, source): expression = source
        default: return XCTFail("multiply was not lifted")
        }
        let signed: C.CType = width == 32 ? .i32 : .i64
        let unsigned: C.CType = width == 32 ? .u32 : .u64
        func evaluate(_ value: MacIRValue) throws -> C.Value {
            switch value {
            case let .register(name, _):
                let inputs: [String: UInt64] = ["\(prefix)8": a, "\(prefix)9": b, "\(prefix)10": c]
                return .init(try XCTUnwrap(inputs[name]), signed)
            case let .immediate(number): return .init(UInt64(bitPattern: number), .i32)
            case let .unary(op, child):
                let inner = try evaluate(child)
                if op == "(uint\(width)_t)" { return try C.converted(inner, to: unsigned) }
                if op == "-" { return try C.binary("-", .init(0, signed), inner) }
                throw C.Failure.unsupportedSyntax("unexpected cast in multiply test")
            case let .binaryExpression(op, left, right):
                return try C.binary(op, evaluate(left), evaluate(right))
            default: throw C.Failure.unsupportedSyntax("unexpected multiply operand")
            }
        }
        if function.ssaEnabled {
            let result = try evaluate(expression)
            XCTAssertEqual(result.type, unsigned)
            XCTAssertEqual(result.bits, expected)
        } else {
            // Preserve and expose the legacy signed-overflow behavior, not silently
            // bless its mathematical result or broaden this SSA-only fix.
            XCTAssertThrowsError(try evaluate(expression)) { error in
                guard case C.Failure.undefinedC = error else { return XCTFail("expected signed overflow, got \(error)") }
            }
        }
    }

    func testMADDWordMinProductBoundary() throws {
        // MIN * -1 = 2^31; +0 wraps to MIN bits.
        try multiplyBoundary("madd", width: 32, a: 0x80000000, b: 0xffffffff, expected: 0x80000000)
    }
    func testMADDWordMaxSumBoundary() throws {
        // MAX * 1 + 1 = 2^31: product fits but outer addition does not.
        try multiplyBoundary("madd", width: 32, a: 0x7fffffff, b: 1, c: 1, expected: 0x80000000)
    }
    func testMADDXMinProductBoundary() throws {
        try multiplyBoundary("madd", width: 64, a: 0x8000000000000000, b: 0xffffffffffffffff, expected: 0x8000000000000000)
    }
    func testMADDXMaxSumBoundary() throws {
        try multiplyBoundary("madd", width: 64, a: 0x7fffffffffffffff, b: 1, c: 1, expected: 0x8000000000000000)
    }
    func testMNEGWordMinNegationBoundary() throws {
        // MIN * 1 fits; its negation wraps back to MIN.
        try multiplyBoundary("mneg", width: 32, a: 0x80000000, b: 1, expected: 0x80000000)
    }
    func testMNEGWordMaxProductBoundary() throws {
        // MAX * 2 = 2^32-2; negation modulo 2^32 is 2.
        try multiplyBoundary("mneg", width: 32, a: 0x7fffffff, b: 2, expected: 2)
    }
    func testMNEGXMinNegationBoundary() throws {
        try multiplyBoundary("mneg", width: 64, a: 0x8000000000000000, b: 1, expected: 0x8000000000000000)
    }
    func testMNEGXMaxProductBoundary() throws {
        try multiplyBoundary("mneg", width: 64, a: 0x7fffffffffffffff, b: 2, expected: 2)
    }
    func testMULWordMinProductBoundary() throws {
        try multiplyBoundary("mul", width: 32, a: 0x80000000, b: 0xffffffff, expected: 0x80000000)
    }
    func testMULWordMaxProductBoundary() throws {
        try multiplyBoundary("mul", width: 32, a: 0x7fffffff, b: 2, expected: 0xfffffffe)
    }
    func testMULXMinProductBoundary() throws {
        try multiplyBoundary("mul", width: 64, a: 0x8000000000000000, b: 0xffffffffffffffff, expected: 0x8000000000000000)
    }
    func testMULXMaxProductBoundary() throws {
        try multiplyBoundary("mul", width: 64, a: 0x7fffffffffffffff, b: 2, expected: 0xfffffffffffffffe)
    }

    func testLinearNotEqualBranchDropsCompareAndPreservesCondition() {
        let document = render("_linear_ne", [
            row(0x1000, "cmp", "x8, x9"),
            row(0x1004, "b.ne", "0x9000"),
            row(0x1008, "ret")
        ])
        XCTAssertFalse(document.text.contains("__compare("), document.text)
        XCTAssertEqual(sourceText(document, 0x1000), [])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0x1004).joined(separator: "\n"), target: 0x9000, condition: "x8_0 != x9_0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testSingleSelectDropsCompareAndPreservesSelect() {
        let document = render("_single_select", [
            row(0x2000, "cmp", "x8, x9"),
            row(0x2004, "csel", "x0, x10, x11, eq"),
            row(0x2008, "ret")
        ])
        XCTAssertFalse(document.text.contains("__compare("), document.text)
        XCTAssertEqual(sourceText(document, 0x2004), [
            "    x0_1 = (x8_0 == x9_0) ? x10_0 : x11_0; // conditional select"
        ])
    }

    func testTwoSelectReadersBothRestateComparison() {
        let document = render("_two_selects", [
            row(0x2100, "cmp", "x8, x9"),
            row(0x2104, "csel", "x10, x11, x12, eq"),
            row(0x2108, "csel", "x0, x13, x14, ne"),
            row(0x210c, "ret")
        ])
        XCTAssertFalse(document.text.contains("__compare("), document.text)
        XCTAssertEqual(sourceText(document, 0x2104), [
            "    tmp0 = (x8_0 == x9_0) ? x11_0 : x12_0; // conditional select"
        ])
        XCTAssertEqual(sourceText(document, 0x2108), [
            "    x0_1 = (x8_0 != x9_0) ? x13_0 : x14_0; // conditional select"
        ])
    }

    func testOperandRegisterRedefinedBeforeLaterReaderDropsCompareAndKeepsOriginalVersion() {
        let document = render("_redefined_operand", [
            row(0x3000, "cmp", "x8, x9"),
            row(0x3004, "mov", "x8, #0x1"),
            row(0x3008, "b.eq", "0x9000"),
            row(0x300c, "ret")
        ])
        XCTAssertEqual(sourceText(document, 0x3000), [])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0x3008).joined(separator: "\n"), target: 0x9000, condition: "x8_0 == x9_0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testSignedAndUnsignedConditionsKeepTheirOriginalWidthAndSignedness() {
        let signed = render("_signed_branch", [
            row(0x4000, "cmp", "w8, w9"),
            row(0x4004, "b.lt", "0x9000"),
            row(0x4008, "ret")
        ])
        let unsigned = render("_unsigned_branch", [
            row(0x4100, "cmp", "w8, w9"),
            row(0x4104, "b.lo", "0x9000"),
            row(0x4108, "ret")
        ])
        XCTAssertFalse(signed.text.contains("__compare("), signed.text)
        XCTAssertFalse(unsigned.text.contains("__compare("), unsigned.text)
        // SSA explicitly projects signed W comparisons; the legacy spelling remains unchanged.
        GotoLabelWellFormednessTests.assertTransfer(sourceText(signed, 0x4004).joined(separator: "\n"), target: 0x9000, condition: MacIRConfiguration.ssaEnabled ? "\(signedWordExpectation("w8_0")) < \(signedWordExpectation("w9_0"))" : "w8_0 < w9_0")
        GotoLabelWellFormednessTests.assertWellFormed(signed.text)
        GotoLabelWellFormednessTests.assertTransfer(sourceText(unsigned, 0x4104).joined(separator: "\n"), target: 0x9000, condition: "(uint32_t)(w8_0) < (uint32_t)(w9_0)")
        GotoLabelWellFormednessTests.assertWellFormed(unsigned.text)
    }

    func testConditionalCompareReaderKeepsInitialCompareAndIntrinsic() {
        let document = render("_conditional_compare_chain", [
            row(0x5000, "cmp", "x8, #0x0"),
            row(0x5004, "ccmp", "x9, #0x0, #0x0, ne"),
            row(0x5008, "b.eq", "0x9000"),
            row(0x500c, "ret")
        ])
        // SSA consumes the complete CMP/CCMP chain; legacy retains its diagnostic intrinsics.
        XCTAssertEqual(sourceText(document, 0x5000), MacIRConfiguration.ssaEnabled ? [] : [
            "    __compare(x8_0, 0x0); // sets condition flags"
        ])
        XCTAssertEqual(sourceText(document, 0x5004), MacIRConfiguration.ssaEnabled ? [] : [
            "    __conditional_compare_ne(x9_0, 0x0, 0x0);"
        ])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0x5008).joined(separator: "\n"), target: 0x9000, condition: "(x8_0 != 0x0) && (x9_0 == 0x0)")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testUnreadFlagsKeepExactExistingOutput() {
        let document = render("_unread_flags", [
            row(0x6000, "cmp", "x8, x9"),
            row(0x6004, "mov", "x0, #0x1"),
            row(0x6008, "ret")
        ])
        // Existing output is derived from the unmodified printer: unread compare
        // intrinsics are retained, and the explicit x0 assignment supplies return.
        XCTAssertEqual(document.text, """
        int64_t _unread_flags(void) {
            // entry 0x0000000000006000; no stack frame; calls none
            __compare(x8_0, x9_0); // sets condition flags
            x0_1 = 0x1;
            return x0_1; // return
        }
        """)
    }

    func testExplicitSelectAndUnexpressibleCarryReaderKeepCompare() {
        let document = render("_mixed_flag_readers", [
            row(0x7000, "cmp", "x8, x9"),
            row(0x7004, "csel", "x10, x11, x12, eq"),
            row(0x7008, "adc", "x0, x13, x14"),
            row(0x700c, "ret")
        ])
        XCTAssertEqual(sourceText(document, 0x7000), [
            "    __compare(x8_0, x9_0); // sets condition flags"
        ])
        XCTAssertEqual(sourceText(document, 0x7004), [
            "    tmp0 = (x8_0 == x9_0) ? x11_0 : x12_0; // conditional select"
        ])
        XCTAssertTrue(document.text.contains("__unknown(\"adc\", \"x0, x13, x14\")"), document.text)
    }

    func testLaterBranchWithUnrelatedWriteDropsCompare() {
        let document = render("_stable_later_reader", [
            row(0x8000, "cmp", "x8, x9"),
            row(0x8004, "mov", "x10, #0x1"),
            row(0x8008, "b.eq", "0x9000"),
            row(0x800c, "ret")
        ])
        XCTAssertFalse(document.text.contains("__compare("), document.text)
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0x8008).joined(separator: "\n"), target: 0x9000, condition: "x8_0 == x9_0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testOperandWriteOnOneIncomingPathDropsCompareWhenReaderUsesOriginalVersion() {
        let left = MacIRValue.register(name: "x8", version: 0)
        let right = MacIRValue.register(name: "x9", version: 0)
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "00 00 00 00",
                                                     mnemonic: mnemonic, operands: operands),
                             operation: operation)
        }
        // cbz bypasses the operand write on one edge; the fallthrough edge writes x8.
        // Both edges reach the same explicit flag reader using the original SSA values.
        let function = MacIRFunction(name: "_path_operand_write", startAddress: 0xa000, instructions: [
            instruction(0xa000, "cmp", "x8, x9",
                        .intrinsic(destination: nil, name: "compare", arguments: [left, right])),
            instruction(0xa004, "cbz", "x10, 0xa00c",
                        .conditionalBranch(condition: "==", left: .register(name: "x10", version: 0),
                                           right: .immediate(0), target: .immediate(0xa00c))),
            instruction(0xa008, "mov", "x8, #0x1",
                        .assign(destination: .register(name: "x8", version: 1), source: .immediate(1))),
            instruction(0xa00c, "b.eq", "0x9000",
                        .conditionalBranch(condition: "==", left: left, right: right,
                                           target: .immediate(0x9000))),
            instruction(0xa010, "ret", "", .returnValue(nil))
        ])
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let document = PseudocodePrinter(options: options).print(function: function)
        XCTAssertEqual(sourceText(document, 0xa000), [])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0xa00c).joined(separator: "\n"), target: 0x9000, condition: "x8_0 == x9_0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testDistinctRegistersSharingPrintedNameKeepCompareAfterWrite() {
        let function = MacIRBuilder().buildFunction(name: "_printed_name_clobber", instructions: [
            row(0xb000, "cmp", "x8, x9"),
            row(0xb004, "mov", "x10, #0x1"),
            row(0xb008, "b.eq", "0x9000"),
            row(0xb00c, "ret")
        ])
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let document = PseudocodePrinter(options: options).print(
            function: function, registerNameOverrides: ["x8": "shared", "x10": "shared"]
        )
        XCTAssertEqual(sourceText(document, 0xb000), [
            "    __compare(shared, x9_0); // sets condition flags"
        ])
        XCTAssertEqual(sourceText(document, 0xb004), ["    shared = 0x1;"])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0xb008).joined(separator: "\n"), target: 0x9000, condition: "shared == x9_0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testZeroCheckBranchDoesNotReadCompareFlags() {
        let document = render("_zero_check_only", [
            row(0xc000, "cmp", "x8, x9"),
            row(0xc004, "cbz", "x10, 0x9000"),
            row(0xc008, "ret")
        ])
        XCTAssertEqual(sourceText(document, 0xc000), [
            "    __compare(x8_0, x9_0); // sets condition flags"
        ])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0xc004).joined(separator: "\n"), target: 0x9000, condition: "x10_0 == 0x0")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testSubtractNewWVersionDropsCompareAndReaderKeepsOriginalVersion() {
        let document = render("_subtract_original_operand", [
            row(0xd000, "cmp", "w4, #0x1"),
            row(0xd004, "sub", "w4, w4, #0x1"),
            row(0xd008, "b.hs", "0x9000"),
            row(0xd00c, "ret")
        ])
        XCTAssertEqual(sourceText(document, 0xd000), [])
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0xd008).joined(separator: "\n"), target: 0x9000, condition: "(uint32_t)(in_w4) >= (uint32_t)(0x1)")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testXWriteAfterWCompareDropsCompareAndKeepsOriginalVersion() {
        let document = render("_alias_original_operand", [
            row(0xd100, "cmp", "w27, #0xf"),
            row(0xd104, "mov", "x27, #0x1"),
            row(0xd108, "b.gt", "0x9000"),
            row(0xd10c, "ret")
        ])
        XCTAssertEqual(sourceText(document, 0xd100), [])
        // SSA explicitly projects signed W comparisons; the legacy spelling remains unchanged.
        GotoLabelWellFormednessTests.assertTransfer(sourceText(document, 0xd108).joined(separator: "\n"), target: 0x9000, condition: MacIRConfiguration.ssaEnabled ? "\(signedWordExpectation("w27_0")) > 0xf" : "w27_0 > 0xf")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testScalarDivisionsAfterSelectDropCompare() {
        for (mnemonic, registers, intrinsic) in [
            ("udiv", "w12, w13, w14", "a64_udiv32"),
            ("sdiv", "w12, w13, w14", "a64_sdiv32"),
            ("udiv", "x12, x13, x14", "a64_udiv64"),
            ("sdiv", "x12, x13, x14", "a64_sdiv64")
        ] {
            let function = MacIRBuilder().buildFunction(name: "_division", instructions: [
                row(0xd200, "cmp", "x8, x9"),
                row(0xd204, "csel", "x0, x10, x11, eq"),
                row(0xd208, mnemonic, registers),
                row(0xd20c, "ret")
            ])
            guard case let .intrinsic(destination?, name, _) = function.instructions[2].operation else {
                XCTFail("Expected destination-bearing scalar division"); continue
            }
            XCTAssertEqual(name, intrinsic)
            XCTAssertNotEqual(destination, .register(name: "x8", version: 0))
            XCTAssertTrue(suppressed(function).contains(0), intrinsic)
        }
    }

    func testDivisionPrintedNameCollisionKeepsCompare() {
        let function = MacIRBuilder().buildFunction(name: "_division_collision", instructions: [
            row(0xd300, "cmp", "x8, x9"),
            row(0xd304, "udiv", "x10, x11, x12"),
            row(0xd308, "b.eq", "0x9000"),
            row(0xd30c, "ret")
        ])
        XCTAssertFalse(suppressed(function, overrides: ["x8": "shared", "x10": "shared"]).contains(0))
    }

    func testRestorePairWritebackAfterSelectDropsCompareAndUsesBuilderLayout() {
        let function = MacIRBuilder().buildFunction(name: "_restore_tail", instructions: [
            row(0xd400, "cmp", "x8, x9"),
            row(0xd404, "csel", "x0, x10, x11, eq"),
            row(0xd408, "ldp", "x19, x20, [sp], #0x20"),
            row(0xd40c, "ret")
        ])
        XCTAssertEqual(function.instructions[2].operation, .intrinsic(
            destination: nil, name: "restore_pair_writeback", arguments: [
                .register(name: "x19", version: 1), .register(name: "x20", version: 1),
                .register(name: "sp", version: 0), .register(name: "sp", version: 1),
                .immediate(0x20), .immediate(0)
            ]))
        XCTAssertTrue(suppressed(function).contains(0))
    }

    func testRestorePairWritebackTracksBothRestoredDestinationsAndUpdatedBase() {
        for operand in ["x19", "x20", "sp"] {
            let function = MacIRBuilder().buildFunction(name: "_restore_collision", instructions: [
                row(0xd500, "cmp", "\(operand), x9"),
                row(0xd504, "ldp", "x19, x20, [sp], #0x20"),
                row(0xd508, "b.eq", "0x9000"),
                row(0xd50c, "ret")
            ])
            XCTAssertFalse(suppressed(function, overrides: [operand: "shared"]).contains(0), operand)
        }
    }

    func testSavePairWritebackLayoutAndUpdatedBaseEffect() {
        let function = MacIRBuilder().buildFunction(name: "_save_base", instructions: [
            row(0xd600, "cmp", "sp, x9"),
            row(0xd604, "stp", "x19, x20, [sp, #-0x20]!"),
            row(0xd608, "b.eq", "0x9000"),
            row(0xd60c, "ret")
        ])
        XCTAssertEqual(function.instructions[1].operation, .intrinsic(
            destination: nil, name: "save_pair_writeback", arguments: [
                .register(name: "x19", version: 0), .register(name: "x20", version: 0),
                .register(name: "sp", version: 0), .register(name: "sp", version: 1),
                .immediate(-0x20), .immediate(1)
            ]))
        XCTAssertTrue(suppressed(function).contains(0))
        XCTAssertFalse(suppressed(function, overrides: ["sp": "shared"]).contains(0))
    }

    func testSavePairWritebackKeepsMemoryOperandCompare() {
        let function = proofFunction(left: .stackSlot(offset: 0x10), intervening: .intrinsic(
            destination: nil, name: "save_pair_writeback", arguments: pairArguments))
        XCTAssertFalse(suppressed(function).contains(0))
    }

    func testMalformedPairWritebackRemainsOpaque() {
        for name in ["save_pair_writeback", "restore_pair_writeback"] {
            for arguments in [Array(pairArguments.prefix(5)), Array(pairArguments.prefix(4)) + [.immediate(32), .immediate(2)]] {
                let function = proofFunction(left: .register(name: "x8", version: 0),
                    intervening: .intrinsic(destination: nil, name: name, arguments: arguments))
                XCTAssertFalse(suppressed(function).contains(0), name)
            }
        }
    }

    func testAuditedNEONBetweenCompareAndReaderDropsCompare() {
        let function = proofFunction(left: .register(name: "x8", version: 0), intervening:
            .intrinsic(destination: .register(name: "v0", version: 1), name: "neon_dup_8h",
                       arguments: [.register(name: "w10", version: 0)]))
        XCTAssertTrue(suppressed(function).contains(0))
    }

    func testNonAdmittedSaturatingNEONKeepsCompare() {
        let function = proofFunction(left: .register(name: "x8", version: 0), intervening:
            .intrinsic(destination: .register(name: "v0", version: 1), name: "neon_sqrdmulh_8h",
                       arguments: [.register(name: "v1", version: 0), .register(name: "v2", version: 0)]))
        XCTAssertFalse(suppressed(function).contains(0))
    }

    func testArgumentRegisterWriteDropsCompareUnlessPrintedNamesCollide() {
        let function = proofFunction(left: .argument(bindingID: .gpr(4)), intervening:
            .assign(destination: .register(name: "x4", version: 1), source: .immediate(1)))
        XCTAssertTrue(suppressed(function).contains(0))
        XCTAssertFalse(suppressed(function, overrides: ["x4": MacIRParameterBindingID.gpr(4).placeholderName]).contains(0))
    }

    func testExactSSAValueWriteStillKeepsCompare() {
        let value = MacIRValue.register(name: "x8", version: 0)
        let function = proofFunction(left: value, intervening: .assign(destination: value, source: .immediate(1)))
        XCTAssertFalse(suppressed(function).contains(0))
    }

    func testDecisionReportsFirstOperandAndOpaqueReaderGuards() throws {
        let unknown = proofFunction(left: .unknown("unavailable"), intervening:
            .intrinsic(destination: nil, name: "opaque", arguments: []))
        XCTAssertEqual(try rejection(unknown).reason, .unknownOperand)
        XCTAssertEqual(try rejection(unknown).address, 0xe000)

        let conditional = MacIRBuilder().buildFunction(name: "_ccmp_reason", instructions: [
            row(0xf000, "cmp", "x8, #0"), row(0xf004, "ccmp", "x9, #0, #0, ne"),
            row(0xf008, "b.eq", "0x9000"), row(0xf00c, "ret")
        ])
        XCTAssertEqual(try rejection(conditional).reason, .ccmp)
        let unknownReader = proofFunction(left: .register(name: "x8", version: 0), intervening:
            .unknown(destination: nil, inputs: .init(mayReadNZCV: true), mnemonic: "adc", operands: ""))
        XCTAssertEqual(try rejection(unknownReader).reason, .unknownReader)
        let opaque = proofFunction(left: .register(name: "x8", version: 0), intervening:
            .intrinsic(destination: nil, name: "opaque", arguments: []))
        XCTAssertEqual(try rejection(opaque).reason, .nonFlagIndependentIntrinsic("opaque"))
    }

    func testDecisionDistinguishesDeferredDirtyCauses() throws {
        let value = MacIRValue.register(name: "x8", version: 0)
        let exact = proofFunction(left: value, intervening: .assign(destination: value, source: .immediate(1)))
        XCTAssertEqual(try rejection(exact).reason, .dirtyExactValue)
        XCTAssertEqual(try rejection(exact).address, 0xe008, "The reader rejects, not the earlier write")
        XCTAssertTrue(try rejection(exact).detail.contains("first dirty at 0xe004"))
        let name = proofFunction(left: value, intervening:
            .assign(destination: .register(name: "x10", version: 1), source: .immediate(1)))
        XCTAssertEqual(try rejection(name, overrides: ["x8": "shared", "x10": "shared"]).reason, .dirtyPrintedName)
        let unknown = proofFunction(left: value, intervening:
            .unknown(destination: value, inputs: .none, mnemonic: "opaque", operands: ""))
        XCTAssertEqual(try rejection(unknown).reason, .dirtyUnknownOp, "Unknown dirtiness precedes exact definitions")
        let memory = proofFunction(left: .stackSlot(offset: 16), intervening:
            .intrinsic(destination: nil, name: "save_pair_writeback", arguments: pairArguments))
        XCTAssertEqual(try rejection(memory).reason, .memoryOperand)
        let memoryWithoutWrite = proofFunction(left: .stackSlot(offset: 16), intervening:
            .intrinsic(destination: nil, name: "nop", arguments: []))
        XCTAssertTrue(suppressed(memoryWithoutWrite).contains(0), "Memory alone is not a rejection")
        var phi = proofFunction(left: value, intervening: .intrinsic(destination: nil, name: "nop", arguments: []))
        phi.phis = [.init(blockAddress: 0xe008, destination: value, bitWidth: 64, incoming: [])]
        XCTAssertEqual(try rejection(phi).reason, .phiClobber)
    }

    func testDecisionPreservesDirtyBoundaryAndFirstVisitedPath() throws {
        let value = MacIRValue.register(name: "x8", version: 0)
        var function = proofFunction(left: value, intervening: .assign(destination: value, source: .immediate(1)))
        function.instructions[2].operation = .returnValue(nil)
        XCTAssertEqual(try rejection(function).reason, .noReader, "Dirtiness must not reject before a reader")
        // Fallthrough is pushed last and inspected before the explicit target.
        function.instructions[1].source.mnemonic = "cbz"
        function.instructions[1].operation = .conditionalBranch(condition: "==", left: value,
            right: .immediate(0), target: .immediate(0xe00c))
        function.instructions[2].operation = .intrinsic(destination: nil, name: "fallthrough", arguments: [])
        function.instructions[3].operation = .intrinsic(destination: nil, name: "taken", arguments: [])
        XCTAssertEqual(try rejection(function).reason, .nonFlagIndependentIntrinsic("fallthrough"))
    }

    func testDecisionReportsRestatementAndEdgeGuards() throws {
        let value = MacIRValue.register(name: "x8", version: 0)
        var function = proofFunction(left: value, intervening: .intrinsic(destination: nil, name: "nop", arguments: []))
        function.instructions[2].operation = .conditionalBranch(condition: "==", left: .immediate(1),
            right: .immediate(0), target: .immediate(0x9000))
        XCTAssertEqual(try rejection(function).reason, .notRestated("conditionalBranch"))
        function.instructions[1].operation = .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0xe006)])
        XCTAssertEqual(try rejection(function).reason, .unresolvedInteriorEdge)
        function.instructions[1].operation = .switchDispatch(index: value, cases: [], defaultTarget: nil)
        XCTAssertEqual(try rejection(function).reason, .switchWithoutDefault)
    }

    func testTypedIntegerIntrinsicContractsAdmitOnlyMatchingProducers() throws {
        for (mnemonic, operands) in [("movi", "v0.8h, #1"), ("mvni", "v0.4s, #2"),
                                    ("movi", "v1.8h, #0xc0, lsl #8"),
                                    ("clz", "w10, w11"), ("rbit", "x10, x11"),
                                    ("rev", "w10, w11"), ("rev16", "x10, x11"),
                                    ("smulh", "x10, x11, x12")] {
            var function = try typedIntrinsicProof(mnemonic, operands)
            XCTAssertTrue(suppressed(function).contains(0), mnemonic)
            function.instructions[1].source.mnemonic = "opaque"
            guard case .nonFlagIndependentIntrinsic = try rejection(function).reason else {
                return XCTFail("A name without its matching source contract was admitted: \(mnemonic)")
            }
        }
    }

    func testIntegerConstantRequiresMatchingTypedMetadata() throws {
        var function = try typedIntrinsicProof("movi", "v0.8h, #1")
        let original = function.instructions[1]
        function.instructions[1].neonImmediate = nil
        XCTAssertEqual(try rejection(function).reason, .nonFlagIndependentIntrinsic("neon_integer_constant"))
        function.instructions[1] = original
        function.instructions[1].neonImmediate = MacIRNEONImmediate(kind: .movi, laneBits: 16,
            activeBytes: 16, immediate: 2, shift: 0)
        XCTAssertEqual(try rejection(function).reason, .nonFlagIndependentIntrinsic("neon_integer_constant"))
        function.instructions[1] = original
        function.instructions[1].operation = .intrinsic(destination: .register(name: "v1", version: 1),
                                                        name: "neon_integer_constant", arguments: [])
        XCTAssertEqual(try rejection(function).reason, .nonFlagIndependentIntrinsic("neon_integer_constant"))
    }

    private func typedIntrinsicProof(_ mnemonic: String, _ operands: String) throws -> MacIRFunction {
        var function = MacIRBuilder().buildFunction(name: "_typed_intrinsic", instructions: [
            row(0xf000, "cmp", "x8, x9"), row(0xf004, "nop"),
            row(0xf008, "b.eq", "0x9000"), row(0xf00c, "ret")
        ])
        // The external branch declines whole-function vector admission. Lift the
        // real producer as a supported leaf fragment, then test its complete row
        // against the comparison walk, independently of region admission.
        let producer = MacIRBuilder().buildFunction(name: "_typed_producer", instructions: [
            row(0xf004, mnemonic, operands)
        ])
        XCTAssertEqual(producer.instructions.count, 1)
        let instruction = try XCTUnwrap(producer.instructions.first)
        let isConstant = mnemonic == "movi" || mnemonic == "mvni"
        let destination = String(operands.prefix { $0 != "," && $0 != "." })
        let arguments: [MacIRValue] = isConstant ? [] : MacIRBuilder.splitOperands(operands)
            .dropFirst().map { .register(name: $0, version: 0) }
        XCTAssertEqual(instruction.operation, .intrinsic(destination: .register(name: destination, version: 1),
            name: isConstant ? "neon_integer_constant" : mnemonic, arguments: arguments))
        if isConstant {
            let expected: MacIRNEONImmediate?
            if mnemonic == "mvni" {
                expected = MacIRNEONImmediate(kind: .mvni, laneBits: 32, activeBytes: 16, immediate: 2, shift: 0)
            } else if destination == "v1" {
                // _quantize_float at 0x6c90 in the retained census.
                expected = MacIRNEONImmediate(kind: .movi, laneBits: 16, activeBytes: 16, immediate: 0xc0, shift: 8)
            } else {
                expected = MacIRNEONImmediate(kind: .movi, laneBits: 16, activeBytes: 16, immediate: 1, shift: 0)
            }
            XCTAssertEqual(instruction.neonImmediate, try XCTUnwrap(expected))
        }
        XCTAssertEqual(function.instructions[2].operation, .conditionalBranch(condition: "==",
            left: .register(name: "x8", version: 0), right: .register(name: "x9", version: 0),
            target: .immediate(0x9000)))
        function.instructions[1] = instruction
        return function
    }

    func testScalarIntrinsicRejectsWidthAndArityMismatches() throws {
        for (name, operands, arguments) in [
            ("clz", "w10, x11", [MacIRValue.register(name: "x11", version: 0)]),
            ("smulh", "w10, w11, w12", [.register(name: "w11", version: 0), .register(name: "w12", version: 0)]),
            ("rev16", "w10", [])
        ] {
            var function = proofFunction(left: .register(name: "x8", version: 0), intervening:
                .intrinsic(destination: .register(name: "w10", version: 1), name: name, arguments: arguments))
            function.instructions[1].source.mnemonic = name
            function.instructions[1].source.operands = operands
            XCTAssertEqual(try rejection(function).reason, .nonFlagIndependentIntrinsic(name))
        }
    }

    func testUnsignedImmediateRestatementRequiresEveryTypeCondition() throws {
        let inner = MacIRValue.register(name: "w8", version: 0)
        let left = MacIRValue.unary(op: "(uint32_t)", value: inner)
        func function(_ mnemonic: String, _ condition: String, _ value: Int64,
                      compareLeft: MacIRValue, readerLeft: MacIRValue) -> MacIRFunction {
            var f = proofFunction(left: compareLeft, intervening: .intrinsic(destination: nil, name: "nop", arguments: []))
            f.instructions[0].operation = .intrinsic(destination: nil, name: "compare", arguments: [compareLeft, .immediate(value)])
            f.instructions[2].source.mnemonic = mnemonic
            f.instructions[2].operation = .conditionalBranch(condition: condition, left: readerLeft,
                                                             right: .immediate(value), target: .immediate(0x9000))
            return f
        }
        for (mnemonic, condition) in [("b.hi", ">"), ("b.lo", "<"), ("b.hs", ">="), ("b.ls", "<=")] {
            for value in [Int64(0), 31, Int64(Int32.max)] {
                XCTAssertTrue(suppressed(function(mnemonic, condition, value, compareLeft: left, readerLeft: left)).contains(0))
            }
        }
        for (mnemonic, condition, value, compareLeft, readerLeft) in [
            ("b.lt", "<", Int64(31), left, left),
            ("b.hi", "<", 31, left, left),
            ("b.hi", ">", -1, left, left),
            ("b.hi", ">", Int64(Int32.max) + 1, left, left),
            ("b.hi", ">", 31, inner, inner),
            ("b.hi", ">", 31, left, MacIRValue.unary(op: "(uint32_t)", value: .register(name: "w8", version: 1)))
        ] {
            XCTAssertEqual(try rejection(function(mnemonic, condition, value,
                compareLeft: compareLeft, readerLeft: readerLeft)).reason, .notRestated("conditionalBranch"))
        }
    }

    private func loopProof(writtenRegister: String, backEdge: Bool = true) -> MacIRFunction {
        let left = MacIRValue.register(name: "w8", version: 0)
        let ops: [(String, MacIROperation)] = [
            ("cmp", .intrinsic(destination: nil, name: "compare", arguments: [left, .immediate(0)])),
            ("cbz", .conditionalBranch(condition: "==", left: .register(name: "x10", version: 0),
                                       right: .immediate(0), target: .immediate(0xf010))),
            ("mov", .assign(destination: .register(name: writtenRegister, version: 1), source: .immediate(1))),
            ("b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(backEdge ? 0xf004 : 0xf010)])),
            ("b.eq", .conditionalBranch(condition: "==", left: left, right: .immediate(0), target: .immediate(0x9000))),
            ("ret", .returnValue(nil))
        ]
        return MacIRFunction(name: "_loop_stale_version", startAddress: 0xf000, instructions: ops.enumerated().map {
            MacIRInstruction(source: MacIRSourceSpan(address: 0xf000 + UInt64($0.offset * 4), byteText: "00 00 00 00",
                mnemonic: $0.element.0, operands: ""), operation: $0.element.1)
        })
    }

    func testLoopPhysicalOperandRedefinitionKeepsCompareAfterBackEdge() throws {
        // The exit can be taken after arbitrarily many back edges. W/X aliases
        // share storage even though the reader retains the old SSA version.
        for register in ["w8", "x8"] {
            XCTAssertEqual(try rejection(loopProof(writtenRegister: register)).reason, .loopStaleVersion)
        }
    }

    func testLoopWithoutOperandWritesPreservesElision() {
        XCTAssertTrue(suppressed(loopProof(writtenRegister: "x12")).contains(0))
    }

    func testStraightLinePhysicalRedefinitionPreservesF1bI1Elision() {
        XCTAssertTrue(suppressed(loopProof(writtenRegister: "x8", backEdge: false)).contains(0))
    }

    func testFreshCompareOnLoopBackEdgeEndsOldFlagLifetime() {
        var function = loopProof(writtenRegister: "x8")
        function.instructions[3].operation = .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0xf000)])
        XCTAssertTrue(suppressed(function).contains(0))
    }

    private func rejection(_ function: MacIRFunction, overrides: [String: String] = [:]) throws -> CompareElisionRejection {
        let decision = try XCTUnwrap(PseudocodePrinter(options: .default).compareElisionDecision(function: function,
            names: PseudocodeNameContext(function: function, registerNameOverrides: overrides))[0])
        guard case let .keep(reason) = decision else {
            XCTFail("Expected retained compare, got \(decision)")
            throw NSError(domain: "CompareElisionDecisionTest", code: 1)
        }
        return reason
    }

    private var pairArguments: [MacIRValue] {
        [.register(name: "x19", version: 1), .register(name: "x20", version: 1),
         .register(name: "sp", version: 0), .register(name: "sp", version: 1),
         .immediate(0x20), .immediate(0)]
    }

    private func proofFunction(left: MacIRValue, intervening: MacIROperation) -> MacIRFunction {
        let operations: [(String, MacIROperation)] = [
            ("cmp", .intrinsic(destination: nil, name: "compare", arguments: [left, .immediate(0)])),
            ("nop", intervening),
            ("b.eq", .conditionalBranch(condition: "==", left: left, right: .immediate(0), target: .immediate(0x9000))),
            ("ret", .returnValue(nil))
        ]
        return MacIRFunction(name: "_effects_proof", startAddress: 0xe000, instructions:
            operations.enumerated().map { index, entry in
                MacIRInstruction(source: MacIRSourceSpan(address: 0xe000 + UInt64(index * 4),
                    byteText: "00 00 00 00", mnemonic: entry.0, operands: ""), operation: entry.1)
            })
    }

    private func suppressed(_ function: MacIRFunction, overrides: [String: String] = [:]) -> Set<Int> {
        PseudocodePrinter(options: .default).redundantCompareIndices(function: function,
            names: PseudocodeNameContext(function: function, registerNameOverrides: overrides))
    }
}

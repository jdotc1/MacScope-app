import XCTest
@testable import MacScope

final class DecompilerCoreTests: XCTestCase {
    func testIRCreationFromPreviewInstructions() throws {
        let snapshot = AnalysisEngine.previewSnapshot()
        let function = MacIRBuilder().buildFunction(name: "_main", instructions: snapshot.instructions)
        let legacy = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_main", instructions: snapshot.instructions)
        var alpha = SSAAlphaEquivalence(expected: legacy, actual: function)

        XCTAssertEqual(function.name, "_main")
        XCTAssertEqual(function.startAddress, 0x1000_00000)
        XCTAssertEqual(function.endAddress, 0x1000_00028)
        XCTAssertEqual(function.parameters, [])
        XCTAssertEqual(function.stackFrameSize, 0x20)
        XCTAssertEqual(function.callTargets, ["_analyze_macho"])
        if SSAPropertyAssertions.enabled {
            alpha.assertEquivalent([String(describing: function.returnValue)],
                [String(describing: Optional(MacIRValue.register(name: "w0", version: 1)))])
        } else {
            XCTAssertEqual(function.returnValue, .register(name: "w0", version: 1))
        }
        XCTAssertEqual(function.instructions.count, snapshot.instructions.count)
        XCTAssertEqual(function.instructions.map(\.source.address), snapshot.instructions.map(\.address))
        XCTAssertEqual(function.instructions.first?.source.comment, "Stack frame")

        XCTAssertEqual(
            function.instructions.first?.operation,
            .intrinsic(destination: .register(name: "sp", version: 1), name: "stack_alloc", arguments: [.immediate(0x20)])
        )
        XCTAssertEqual(
            function.instructions[5].operation,
            .call(
                frame: try unknownDirectCallFrame(
                    target: "_analyze_macho",
                    gprValues: [0: .register(name: "x0", version: 1)]
                ),
                result: .register(name: "x0", version: 2)
            )
        )
        XCTAssertEqual(
            function.instructions[7].operation,
            .stackSlotPairRead(
                firstDestination: .register(name: "x29", version: 2),
                firstSlot: .stackSlot(offset: 0x10),
                firstValue: .register(name: "x29", version: 0),
                secondDestination: .register(name: "x30", version: 1),
                secondSlot: .stackSlot(offset: 0x18),
                secondValue: .register(name: "x30", version: 0)
            )
        )
        if SSAPropertyAssertions.enabled {
            alpha.assertEquivalent([String(describing: function.instructions.last?.operation)],
                [String(describing: Optional(MacIROperation.returnValue(.register(name: "w0", version: 1))))])
        } else {
            XCTAssertEqual(
                function.instructions.last?.operation,
                .returnValue(.register(name: "w0", version: 1))
            )
        }
    }

    func testUnknownInstructionIsPreservedInIRAndPseudocode() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00040,
                bytes: "00 00 00 00",
                mnemonic: "udf",
                operands: "#0",
                hasBreakpoint: false,
                comment: "Deliberate undefined instruction"
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_trap", instructions: rows)
        XCTAssertEqual(function.instructions.first?.operation.withoutUnknownInputs, .unknown(mnemonic: "udf", operands: "#0"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            SSAPropertyAssertions.enabled
                ? SSARenderExpectation.withoutRefusalAnnotations(document, function: function, expected: [(.undecodableRow, .row(0x1000_00040))])
                : document.text,
            """
            int64_t _trap(void) {
                // entry 0x0000000100000040; no stack frame; calls none
                __unknown("udf", "#0"); // Deliberate undefined instruction
            }
            """
        )

        let sourceLine = try XCTUnwrap(document.lines.first { $0.source?.address == 0x1000_00040 })
        XCTAssertEqual(sourceLine.kind, .instruction)
        XCTAssertEqual(sourceLine.source?.comment, "Deliberate undefined instruction")
        XCTAssertTrue(sourceLine.tokens.contains { $0.kind == .unknown && $0.text == "__unknown" })
        XCTAssertTrue(sourceLine.tokens.contains { $0.kind == .comment && $0.text == "// Deliberate undefined instruction" })
    }

    /// arm64e authenticated indirect call (`blraa`) and authenticated return (`retaa`) must LIFT to
    /// a call and a return — not fall through to `.unknown`. On arm64e (every macOS-27 app) these
    /// are the call/epilogue instructions, so leaving them unlifted drops calls out of the
    /// pseudocode and leaves the function with no real return.
    func testAuthenticatedCallAndReturnAreLifted() throws {
        let rows = [
            InstructionRow(address: 0x1000_00000, bytes: "e8 03 00 aa", mnemonic: "mov", operands: "x8, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00004, bytes: "01 11 3f d7", mnemonic: "blraa", operands: "x8, x17", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00008, bytes: "ff 0b 5f d6", mnemonic: "retaa", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let function = MacIRBuilder().buildFunction(name: "_authcall", instructions: rows)

        // Neither authenticated instruction may remain `.unknown`.
        let unknowns = function.instructions.filter {
            if case .unknown = $0.operation { return true }; return false
        }
        XCTAssertTrue(unknowns.isEmpty, "blraa/retaa must lift, not stay .unknown: \(unknowns.map(\.operation))")

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("(*x8)"), "blraa must render as an indirect call through x8; got:\n\(text)")
        XCTAssertTrue(text.contains("return"), "retaa must render as a return; got:\n\(text)")
    }

    /// FEAT_PAuth_LR returns (`retaasppc`/`retabsppc` and the register forms) end a function exactly
    /// like `retaa`/`retab`. Before the decoder knew them, `retaasppcr` was misread as `retaa` and
    /// lifted as a return; decoding them correctly must not lose that return.
    func testPAuthLRReturnsAreLiftedAsReturns() throws {
        for (bytes, mnemonic, operands) in [
            ("e0 0b 5f d6", "retaasppcr", "x0"),
            ("f1 0f 5f d6", "retabsppcr", "x17"),
            ("1f 00 00 00", "retaasppc", "0x0000000100000000"),
            ("1f 00 00 00", "retabsppc", "0x0000000100000000"),
        ] {
            let rows = [
                InstructionRow(address: 0x1000_00000, bytes: "e0 03 1f aa", mnemonic: "mov", operands: "x0, xzr", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1000_00004, bytes: bytes, mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil),
            ]
            let function = MacIRBuilder().buildFunction(name: "_\(mnemonic)", instructions: rows)
            let unknowns = function.instructions.filter {
                if case .unknown = $0.operation { return true }; return false
            }
            XCTAssertTrue(unknowns.isEmpty, "\(mnemonic) must lift, not stay .unknown: \(unknowns.map(\.operation))")
            let text = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(text.contains("return"), "\(mnemonic) must render as a return; got:\n\(text)")
        }
    }

    func testPreviewPseudocodePrintingIsDeterministicAndCarriesLineMetadata() throws {
        let snapshot = AnalysisEngine.previewSnapshot()
        let document = PseudocodePrinter().print(functionName: "_main", instructions: snapshot.instructions)

        let expectedText =
            """
            int64_t _main(void) {
                // entry 0x0000000100000000; stack frame 0x20 bytes; calls _analyze_macho
                sp_1 = __stack_alloc(0x20); // Stack frame; allocates 0x20 stack bytes
                __save_pair(x29_0, x30_0, stack[0x10]); // saves register pair
                x29_1 = sp_1 + 0x10;
                tmp0 = __adrp(0x100002000); // Page-relative address
                x0_1 = *(tmp0);
                x0_2 = _analyze_macho(x0_1); // Call analysis entry; call
                w0_1 = 0x0;
                x29_2, x30_1 = x29_0, x30_0; // restores register pair; recovered stack[0x10], stack[0x18]
                sp_2 = __stack_free(0x20); // releases 0x20 stack bytes
                return w0_1; // return
            }
            """
        if SSAPropertyAssertions.enabled {
            let function = MacIRBuilder().buildFunction(name: "_main", instructions: snapshot.instructions)
            let legacy = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_main", instructions: snapshot.instructions)
            var alpha = SSAAlphaEquivalence(expected: legacy, actual: function)
            alpha.assertEquivalent([document.text], [expectedText])
        } else {
            XCTAssertEqual(document.text, expectedText)
        }

        XCTAssertEqual(document.entryAddress, 0x1000_00000)
        XCTAssertEqual(document.parameters, [])
        XCTAssertEqual(document.stackFrameSize, 0x20)
        XCTAssertEqual(document.callTargets, ["_analyze_macho"])
        XCTAssertEqual(document.lines.map(\.lineNumber), Array(1...13))
        XCTAssertEqual(document.lines.map(\.kind), [
            .signature,
            .metadata,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .instruction,
            .closingBrace
        ])
        XCTAssertNil(document.lines.first?.source)
        XCTAssertNil(document.lines.last?.source)
        XCTAssertEqual(document.lines[2].source?.address, 0x1000_00000)
        XCTAssertEqual(document.lines[11].source?.address, 0x1000_00024)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_00014).map(\.lineNumber), [8])

        let callLine = try XCTUnwrap(document.lines.first { $0.kind == .instruction && $0.text.contains("_analyze_macho") })
        XCTAssertEqual(callLine.source?.address, 0x1000_00014)
        XCTAssertEqual(callLine.addressText, "0x0000000100000014")
        XCTAssertTrue(callLine.tokens.contains { $0.kind == .identifier && $0.text == "_analyze_macho" })
        XCTAssertTrue(callLine.tokens.contains { $0.kind == .comment && $0.text == "// Call analysis entry; call" })
        XCTAssertTrue(callLine.tokens.allSatisfy { $0.lineNumber == callLine.lineNumber })
    }

    func testPseudocodeRenamesCallTargetsViaNameOverrides() throws {
        let snapshot = AnalysisEngine.previewSnapshot()
        let document = PseudocodePrinter().print(
            functionName: "_main",
            nameOverrides: ["_analyze_macho": "decodeMachO"],
            instructions: snapshot.instructions
        )

        // The user's custom name renders in both the call expression and the
        // metadata "calls" list, and the parsed name disappears from the text.
        XCTAssertTrue(document.text.contains("x0_2 = decodeMachO(x0_1);"), document.text)
        XCTAssertTrue(document.text.contains("calls decodeMachO"), document.text)
        XCTAssertFalse(document.text.contains("_analyze_macho"), document.text)
        let renamedCall = try XCTUnwrap(document.lines.first { $0.kind == .instruction && $0.text.contains("decodeMachO(") })
        XCTAssertTrue(renamedCall.tokens.contains { $0.kind == .identifier && $0.text == "decodeMachO" })

        // The structured call-target data stays the raw parsed symbol — overrides
        // only affect display, never the address-keyed analysis model.
        XCTAssertEqual(document.callTargets, ["_analyze_macho"])
    }

    func testPseudocodeWithoutOverridesIsUnchangedByEmptyRenameMap() {
        let snapshot = AnalysisEngine.previewSnapshot()
        let baseline = PseudocodePrinter().print(functionName: "_main", instructions: snapshot.instructions)
        let withEmptyMap = PseudocodePrinter().print(
            functionName: "_main",
            nameOverrides: [:],
            instructions: snapshot.instructions
        )
        XCTAssertEqual(baseline.text, withEmptyMap.text)
    }

    func testSimpleStackStoreAndMultiArgumentCallAreDeterministic() throws {
        let rows = [
            InstructionRow(address: 0x1000_01000, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01004, bytes: "20 00 80 d2", mnemonic: "mov", operands: "x0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01008, bytes: "e0 07 00 f9", mnemonic: "str", operands: "x0, [sp, #0x8]", hasBreakpoint: false, comment: "spill argument"),
            InstructionRow(address: 0x1000_0100c, bytes: "e1 07 40 f9", mnemonic: "ldr", operands: "x1, [sp, #0x8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01010, bytes: "42 00 80 d2", mnemonic: "mov", operands: "x2, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01014, bytes: "00 00 00 94", mnemonic: "bl", operands: "_callee", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01018, bytes: "e0 03 1f 2a", mnemonic: "mov", operands: "w0, wzr", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0101c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01020, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_wrapper", instructions: rows)
        XCTAssertEqual(function.stackFrameSize, 0x10)
        XCTAssertEqual(function.callTargets, ["_callee"])
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "int64_t", byteWidth: 8)]
        )
        XCTAssertEqual(
            function.nameBindings,
            [
                MacIRNameBinding(
                    target: .stackSlot(offset: 0x8),
                    name: "local_8",
                    type: "int64_t",
                    kind: .stackLocal
                )
            ]
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .store(source: .register(name: "x0", version: 1), address: .stackSlot(offset: 0x8))
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .stackSlotRead(
                destination: .register(name: "x1", version: 1),
                slot: .stackSlot(offset: 0x8),
                value: .register(name: "x0", version: 1)
            )
        )
        XCTAssertEqual(
            function.instructions[5].operation,
            .call(
                frame: try unknownDirectCallFrame(
                    target: "_callee",
                    gprValues: [
                        0: .register(name: "x0", version: 1),
                        1: .register(name: "x1", version: 1),
                        2: .register(name: "x2", version: 1)
                    ]
                ),
                result: .register(name: "x0", version: 2)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        let expectedText =
            """
            int64_t _wrapper(void) {
                // entry 0x0000000100001000; stack frame 0x10 bytes; calls _callee
                int64_t local_8;
                sp_1 = __stack_alloc(0x10); // allocates 0x10 stack bytes
                x0_1 = 0x1;
                local_8 = x0_1; // spill argument; stack store
                x1_1 = local_8; // recovered stack[0x8]
                x2_1 = 0x2;
                x0_2 = _callee(x0_1, x1_1, x2_1); // call
                w0_1 = 0x0;
                sp_2 = __stack_free(0x10); // releases 0x10 stack bytes
                return w0_1; // return
            }
            """
        if SSAPropertyAssertions.enabled {
            let legacy = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_wrapper", instructions: rows)
            var alpha = SSAAlphaEquivalence(expected: legacy, actual: function)
            alpha.assertEquivalent([document.text], [expectedText])
        } else {
            XCTAssertEqual(document.text, expectedText)
        }
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.nameBindings, function.nameBindings)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    int64_t local_8;")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01008).single?.text, "    local_8 = x0_1; // spill argument; stack store")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0100c).single?.text, "    x1_1 = local_8; // recovered stack[0x8]")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01014).single?.addressText, "0x0000000100001014")

        let localDeclaration = try XCTUnwrap(document.lines.first { $0.kind == .declaration })
        XCTAssertTrue(localDeclaration.tokens.contains { $0.kind == .type && $0.text == "int64_t" })
        XCTAssertTrue(localDeclaration.tokens.contains { $0.kind == .identifier && $0.text == "local_8" })
    }

    func testScratchRegisterRenamesAreStableAndPreserveTokenSpans() throws {
        let rows = [
            InstructionRow(address: 0x1000_01100, bytes: "08 04 00 91", mnemonic: "add", operands: "x8, x0, #0x1", hasBreakpoint: false, comment: "seed temp"),
            InstructionRow(address: 0x1000_01104, bytes: "09 7d 01 9b", mnemonic: "mul", operands: "x9, x8, x1", hasBreakpoint: false, comment: "combine temp"),
            InstructionRow(address: 0x1000_01108, bytes: "e0 03 09 aa", mnemonic: "mov", operands: "x0, x9", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0110c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_scratch_math", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.nameBindings,
            [
                MacIRNameBinding(
                    target: .register(name: "x8", version: 1),
                    name: "tmp0",
                    type: "int64_t",
                    kind: .registerTemporary
                ),
                MacIRNameBinding(
                    target: .register(name: "x9", version: 1),
                    name: "tmp1",
                    type: "int64_t",
                    kind: .registerTemporary
                )
            ]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x8", version: 1),
                op: "+",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(1)
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .binary(
                destination: .register(name: "x9", version: 1),
                op: "*",
                left: .register(name: "x8", version: 1),
                right: .argument(bindingID: .gpr(1))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.nameBindings, function.nameBindings)
        XCTAssertEqual(
            document.text,
            """
            int64_t _scratch_math(int64_t arg0, int64_t arg1) {
                // entry 0x0000000100001100; no stack frame; calls none
                tmp0 = arg0 + 0x1; // seed temp
                tmp1 = tmp0 * arg1; // combine temp
                x0_1 = tmp1;
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("x8_1"), document.text)
        XCTAssertFalse(document.text.contains("x9_1"), document.text)

        let firstTempLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_01100).single)
        let tmp0Token = try XCTUnwrap(firstTempLine.tokens.first { $0.text == "tmp0" })
        XCTAssertEqual(tmp0Token.kind, .identifier)
        XCTAssertEqual(tmp0Token.range, 4..<8)
        XCTAssertEqual(tmp0Token.sourceAddress, 0x1000_01100)
        XCTAssertTrue(firstTempLine.tokens.allSatisfy { $0.lineNumber == firstTempLine.lineNumber })

        let secondTempLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_01104).single)
        XCTAssertTrue(secondTempLine.tokens.contains { $0.kind == .identifier && $0.text == "tmp1" })
        XCTAssertTrue(secondTempLine.tokens.contains { $0.kind == .identifier && $0.text == "tmp0" })
    }

    func testStackLocalDeclarationUsesStoreWidthTypeHint() throws {
        let rows = [
            InstructionRow(address: 0x1000_01200, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01204, bytes: "40 00 80 52", mnemonic: "mov", operands: "w0, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01208, bytes: "e0 0f 00 b9", mnemonic: "str", operands: "w0, [sp, #0xc]", hasBreakpoint: false, comment: "narrow spill"),
            InstructionRow(address: 0x1000_0120c, bytes: "e1 0f 40 b9", mnemonic: "ldr", operands: "w1, [sp, #0xc]", hasBreakpoint: false, comment: "narrow reload"),
            InstructionRow(address: 0x1000_01210, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01214, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_narrow_local", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0xc, type: "int32_t", byteWidth: 4)]
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    int32_t local_c;")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01208).single?.text, "    *(uint32_t *)&(local_c) = w0_1; // narrow spill; stack store")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0120c).single?.text, "    w1_1 = local_c; // narrow reload; recovered stack[0xc]")

        let declaration = try XCTUnwrap(document.lines.first { $0.kind == .declaration })
        XCTAssertTrue(declaration.tokens.contains { $0.kind == .type && $0.text == "int32_t" })
        XCTAssertTrue(declaration.tokens.contains { $0.kind == .identifier && $0.text == "local_c" })
    }

    func testIncomingRegisterArgumentRecoveryFeedsSignatureAndCalls() throws {
        let rows = [
            InstructionRow(address: 0x1000_01400, bytes: "e1 03 00 aa", mnemonic: "mov", operands: "x1, x0", hasBreakpoint: false, comment: "forward incoming pointer"),
            InstructionRow(address: 0x1000_01404, bytes: "00 00 00 94", mnemonic: "bl", operands: "_consume_pair", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01408, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_forward_arg", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x1", version: 1),
                source: .argument(bindingID: .gpr(0))
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .call(
                frame: try unknownDirectCallFrame(
                    target: "_consume_pair",
                    gprValues: [
                        0: .argument(bindingID: .gpr(0)),
                        1: .register(name: "x1", version: 1)
                    ]
                ),
                result: .register(name: "x0", version: 1)
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.parameters, function.parameters)
        XCTAssertEqual(
            document.text,
            """
            int64_t _forward_arg(int64_t arg0) {
                // entry 0x0000000100001400; no stack frame; calls _consume_pair
                x1_1 = arg0; // forward incoming pointer
                x0_1 = _consume_pair(arg0, x1_1); // call
                return unresolved_return_contract; // return
            }
            """
        )

        let signatureLine = try XCTUnwrap(document.lines.first)
        XCTAssertTrue(signatureLine.tokens.contains { $0.kind == .type && $0.text == "int64_t" })
        XCTAssertTrue(signatureLine.tokens.contains { $0.kind == .identifier && $0.text == "arg0" })
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01404).single?.text, "    x0_1 = _consume_pair(arg0, x1_1); // call")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01408).single?.text, "    return unresolved_return_contract; // return")
    }

    func testSignatureOverrideRemapsSignatureLineAndBodyArgReferences() {
        // A function that reads an incoming argument register (x0 -> recovered arg0).
        let rows = [
            InstructionRow(address: 0x1000_01400, bytes: "e1 03 00 aa", mnemonic: "mov", operands: "x1, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01404, bytes: "00 00 00 94", mnemonic: "bl", operands: "_consume_pair", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01408, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let override = FunctionSignatureOverride(
            returnType: "MyResult",
            args: [ArgOverride(index: 0, name: "obj", type: "Object*")],
            isNoReturn: true
        )
        let document = PseudocodePrinter().print(
            functionName: "_forward_arg",
            startAddress: 0x1000_01400,
            signatureOverrides: [0x1000_01400: override],
            instructions: rows
        )

        // Signature line reflects the override (incl. noreturn qualifier).
        XCTAssertTrue(document.text.contains("noreturn MyResult _forward_arg(Object* obj) {"), document.text)
        // Body argument references remap from the recovered arg0 to the override
        // name — signature line and body share one source of truth.
        XCTAssertTrue(document.text.contains("x1_1 = obj;"), document.text)
        XCTAssertTrue(document.text.contains("_consume_pair(obj,"), document.text)
        XCTAssertFalse(document.text.contains("arg0"), document.text)
        // Structured signature data is unaffected by the display override.
        XCTAssertEqual(document.callTargets, ["_consume_pair"])
    }

    func testSignatureOverrideNoReturnTriStatePreservesClearsAndSetsRecoveredQualifier() {
        let recovered = MacIRFunction(
            name: "_fatal",
            startAddress: 0x1000_01400,
            isNoReturn: true,
            instructions: []
        )

        let preserved = PseudocodePrinter.applying(
            FunctionSignatureOverride(returnType: "Never", noReturnState: .unspecified),
            to: recovered
        )
        XCTAssertEqual(preserved.returnType, "Never", "the otherwise-active override must still apply")
        XCTAssertTrue(preserved.isNoReturn, "unspecified authority must preserve the recovered qualifier")

        let cleared = PseudocodePrinter.applying(
            FunctionSignatureOverride(noReturnState: .returns),
            to: preserved
        )
        XCTAssertFalse(cleared.isNoReturn, "explicit returns authority must clear the qualifier")

        let set = PseudocodePrinter.applying(
            FunctionSignatureOverride(noReturnState: .noReturn),
            to: cleared
        )
        XCTAssertTrue(set.isNoReturn, "explicit no-return authority must set the qualifier")
    }

    func testSignatureOverrideDerivesDenseBindingsFromSourceOrder() {
        // Schema-v2 array order is source order; ABI bindings are derived rather
        // than loaded from legacy persisted indices.
        let rows = [
            InstructionRow(address: 0x1000_0c000, bytes: "04 08 01 9b", mnemonic: "madd", operands: "x4, x0, x1, x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0c004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let override = FunctionSignatureOverride(returnType: "size_t", args: [
            ArgOverride(rowToken: "base", name: "base", type: "int64_t", provenance: .user),
            ArgOverride(rowToken: "stride", name: "stride", type: "int64_t", provenance: .user),
            ArgOverride(rowToken: "offset", name: "offset", type: "int64_t", provenance: .user)
        ])
        let document = PseudocodePrinter().print(
            functionName: "_madd_index",
            startAddress: 0x1000_0c000,
            signatureOverrides: [0x1000_0c000: override],
            instructions: rows
        )

        XCTAssertTrue(document.text.contains("size_t _madd_index(int64_t base, int64_t stride, int64_t offset) {"), document.text)
        // madd x4,x0,x1,x2 -> x2 + x0*x1 -> offset + base*stride.
        XCTAssertTrue(document.text.contains("x4_1 = offset + (base * stride);"), document.text)
        XCTAssertFalse(document.text.contains("arg0"), document.text)
        XCTAssertFalse(document.text.contains("arg2"), document.text)
    }

    func testPseudocodeWithEmptySignatureOverridesIsByteIdentical() {
        let snapshot = AnalysisEngine.previewSnapshot()
        let baseline = PseudocodePrinter().print(functionName: "_main", startAddress: 0x1000_00000, instructions: snapshot.instructions)
        let withEmpty = PseudocodePrinter().print(
            functionName: "_main",
            startAddress: 0x1000_00000,
            signatureOverrides: [:],
            instructions: snapshot.instructions
        )
        XCTAssertEqual(baseline.text, withEmpty.text)
    }

    func testInPlaceArithmeticReadsPreviousRegisterVersion() throws {
        let rows = [
            InstructionRow(address: 0x1000_01500, bytes: "00 04 00 91", mnemonic: "add", operands: "x0, x0, #0x1", hasBreakpoint: false, comment: "increment incoming value"),
            InstructionRow(address: 0x1000_01504, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_increment", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "+",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(1)
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _increment(int64_t arg0) {
                // entry 0x0000000100001500; no stack frame; calls none
                x0_1 = arg0 + 0x1; // increment incoming value
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
    }

    func testLogicalArm64OperationsProduceStableValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_01520, bytes: "08 fc 40 92", mnemonic: "and", operands: "x8, x0, #0xff", hasBreakpoint: false, comment: "mask low byte"),
            InstructionRow(address: 0x1000_01524, bytes: "e9 03 08 aa", mnemonic: "orr", operands: "x9, xzr, x8", hasBreakpoint: false, comment: "copy masked value"),
            InstructionRow(address: 0x1000_01528, bytes: "2a 01 00 ca", mnemonic: "eor", operands: "x10, x9, x0", hasBreakpoint: false, comment: "mix original"),
            InstructionRow(address: 0x1000_0152c, bytes: "40 7d 02 9b", mnemonic: "mul", operands: "x0, x10, x2", hasBreakpoint: false, comment: "scale result"),
            InstructionRow(address: 0x1000_01530, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_logical_mix", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 2, register: "x2", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x8", version: 1),
                op: "&",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0xff)
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .assign(
                destination: .register(name: "x9", version: 1),
                source: .register(name: "x8", version: 1)
            )
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .binary(
                destination: .register(name: "x10", version: 1),
                op: "^",
                left: .register(name: "x9", version: 1),
                right: .argument(bindingID: .gpr(0))
            )
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "*",
                left: .register(name: "x10", version: 1),
                right: .argument(bindingID: .gpr(2))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _logical_mix(/* ABI inputs: x0:int64_t in_x0, x2:int64_t in_x2 */) {
                // entry 0x0000000100001520; no stack frame; calls none
                tmp0 = in_x0 & 0xff; // mask low byte
                tmp1 = tmp0; // copy masked value
                tmp2 = tmp1 ^ in_x0; // mix original
                x0_1 = tmp2 * in_x2; // scale result
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01524).single?.text, "    tmp1 = tmp0; // copy masked value")
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMultiplyAddFusesIntoArithmeticValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_0c000, bytes: "20 0c 02 9b", mnemonic: "madd", operands: "x0, x1, x2, x3", hasBreakpoint: false, comment: "index base plus offset"),
            InstructionRow(address: 0x1000_0c004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_madd_index", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t"),
                MacIRFunctionParameter(index: 2, register: "x2", type: "int64_t"),
                MacIRFunctionParameter(index: 3, register: "x3", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "+",
                left: .argument(bindingID: .gpr(3)),
                right: .binaryExpression(
                    op: "*",
                    left: .argument(bindingID: .gpr(1)),
                    right: .argument(bindingID: .gpr(2))
                )
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _madd_index(/* ABI inputs: x1:int64_t in_x1, x2:int64_t in_x2, x3:int64_t in_x3 */) {
                // entry 0x000000010000c000; no stack frame; calls none
                x0_1 = in_x3 + (in_x1 * in_x2); // index base plus offset
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMultiplySubtractFusesIntoArithmeticValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_0c100, bytes: "28 80 02 9b", mnemonic: "msub", operands: "x8, x1, x2, x0", hasBreakpoint: false, comment: "remainder step"),
            InstructionRow(address: 0x1000_0c104, bytes: "e0 03 08 aa", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0c108, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_msub_remainder", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x8", version: 1),
                op: "-",
                left: .argument(bindingID: .gpr(0)),
                right: .binaryExpression(
                    op: "*",
                    left: .argument(bindingID: .gpr(1)),
                    right: .argument(bindingID: .gpr(2))
                )
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _msub_remainder(int64_t arg0, int64_t arg1, int64_t arg2) {
                // entry 0x000000010000c100; no stack frame; calls none
                tmp0 = arg0 - (arg1 * arg2); // remainder step
                x0_1 = tmp0;
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMultiplyNegateProducesNegatedProduct() throws {
        let rows = [
            InstructionRow(address: 0x1000_0c200, bytes: "20 fc 02 9b", mnemonic: "mneg", operands: "x0, x1, x2", hasBreakpoint: false, comment: "negate product"),
            InstructionRow(address: 0x1000_0c204, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_mneg_product", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t"),
                MacIRFunctionParameter(index: 2, register: "x2", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(
                    op: "-",
                    value: .binaryExpression(
                        op: "*",
                        left: .argument(bindingID: .gpr(1)),
                        right: .argument(bindingID: .gpr(2))
                    )
                )
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _mneg_product(/* ABI inputs: x1:int64_t in_x1, x2:int64_t in_x2 */) {
                // entry 0x000000010000c200; no stack frame; calls none
                x0_1 = -(in_x1 * in_x2); // negate product
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMultiplyAddReadsIncomingRegisterVersionForInPlaceAccumulate() throws {
        let rows = [
            InstructionRow(address: 0x1000_0c300, bytes: "00 00 01 9b", mnemonic: "madd", operands: "x0, x0, x1, x0", hasBreakpoint: false, comment: "fused in place"),
            InstructionRow(address: 0x1000_0c304, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_madd_in_place", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "+",
                left: .argument(bindingID: .gpr(0)),
                right: .binaryExpression(
                    op: "*",
                    left: .argument(bindingID: .gpr(0)),
                    right: .argument(bindingID: .gpr(1))
                )
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = arg0 + (arg0 * arg1);"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
    }

    func testMalformedMultiplyAccumulateFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0c400, bytes: "00 00 00 00", mnemonic: "madd", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0c404, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_madd_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(mnemonic: "madd", operands: "x0, x1")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"madd\", \"x0, x1\")"), document.text)
    }

    func testCallReturnValuePropagatesIntoReturnedCallExpression() throws {
        let rows = [
            InstructionRow(address: 0x1000_01600, bytes: "00 00 00 94", mnemonic: "bl", operands: "_make_value", hasBreakpoint: false, comment: "factory"),
            InstructionRow(address: 0x1000_01604, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_call_return", instructions: rows)
        XCTAssertEqual(function.callTargets, ["_make_value"])
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertEqual(
            function.instructions[0].operation,
            .call(
                frame: try unknownDirectCallFrame(target: "_make_value", gprValues: [:]),
                result: .register(name: "x0", version: 1)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _call_return(void) {
                // entry 0x0000000100001600; no stack frame; calls _make_value
                x0_1 = _make_value(); // factory; call
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01600).single?.text, "    x0_1 = _make_value(); // factory; call")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01604).single?.text, "    return unresolved_return_contract; // return")

        let returnLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_01600).single)
        XCTAssertFalse(returnLine.tokens.contains { $0.kind == .keyword && $0.text == "return" })
        XCTAssertTrue(returnLine.tokens.contains { $0.kind == .identifier && $0.text == "_make_value" })
    }

    func testKnownImportedCallSignaturePropagatesArgumentAndReturnType() throws {
        let rows = [
            InstructionRow(address: 0x1000_01620, bytes: "00 00 00 94", mnemonic: "bl", operands: "_strlen", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01624, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let expectedSignature = MacIRCallSignature(
            target: "_strlen",
            returnType: "size_t",
            parameters: [
                MacIRCallParameter(index: 0, register: "x0", type: "const char *", name: "s")
            ]
        )

        let function = MacIRBuilder().buildFunction(name: "_wrap_strlen", instructions: rows)
        XCTAssertEqual(function.returnType, "int64_t")
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "const char *")]
        )
        XCTAssertEqual(function.callTargets, ["_strlen"])
        XCTAssertEqual(function.callSignatures, [expectedSignature])
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertEqual(
            function.instructions[0].operation,
            .call(
                frame: try knownCallFrame(
                    signature: expectedSignature,
                    fixedValues: [0: .argument(bindingID: .gpr(0))]
                ),
                result: .register(name: "x0", version: 1)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.returnType, "int64_t")
        XCTAssertEqual(document.callSignatures, [expectedSignature])
        XCTAssertEqual(
            document.text,
            """
            int64_t _wrap_strlen(const char * arg0) {
                // entry 0x0000000100001620; no stack frame; calls _strlen
                x0_1 = _strlen(arg0); // call; signature size_t _strlen(const char * s)
                return unresolved_return_contract; // return
            }
            """
        )

        let signatureLine = try XCTUnwrap(document.lines.first)
        XCTAssertTrue(signatureLine.tokens.contains { $0.kind == .type && $0.text == "int64_t" })
        XCTAssertTrue(signatureLine.tokens.contains { $0.kind == .type && $0.text == "const" })
        XCTAssertTrue(signatureLine.tokens.contains { $0.kind == .type && $0.text == "char" })

        let callLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_01620).single)
        XCTAssertFalse(callLine.tokens.contains { $0.kind == .keyword && $0.text == "return" })
        XCTAssertTrue(callLine.tokens.contains { $0.kind == .comment && $0.text == "// call; signature size_t _strlen(const char * s)" })
    }

    func testKnownVoidImportedCallSignatureDoesNotInventReturnValue() throws {
        let rows = [
            InstructionRow(address: 0x1000_01640, bytes: "00 00 00 94", mnemonic: "bl", operands: "_free", hasBreakpoint: false, comment: "release storage"),
            InstructionRow(address: 0x1000_01644, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let expectedSignature = MacIRCallSignature(
            target: "_free",
            returnType: "void",
            parameters: [
                MacIRCallParameter(index: 0, register: "x0", type: "void *", name: "ptr")
            ]
        )

        let function = MacIRBuilder().buildFunction(name: "_release_pointer", instructions: rows)
        XCTAssertEqual(function.returnType, "void")
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "void *")]
        )
        XCTAssertEqual(function.callSignatures, [expectedSignature])
        XCTAssertNil(function.returnValue)
        XCTAssertEqual(
            function.instructions[0].operation,
            .call(
                frame: try knownCallFrame(
                    signature: expectedSignature,
                    fixedValues: [0: .argument(bindingID: .gpr(0))]
                ),
                result: nil
            )
        )
        XCTAssertEqual(function.instructions[1].operation, .returnValue(nil))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.returnType, "void")
        XCTAssertEqual(
            document.text,
            """
            void _release_pointer(void * arg0) {
                // entry 0x0000000100001640; no stack frame; calls _free
                _free(arg0); // release storage; call; signature void _free(void * ptr)
                return; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("return arg0"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01640).single?.text, "    _free(arg0); // release storage; call; signature void _free(void * ptr)")
    }

    func testFramePointerRelativeStackReloadRecoversStoredValue() throws {
        let rows = [
            InstructionRow(address: 0x1000_01800, bytes: "ff 83 00 d1", mnemonic: "sub", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01804, bytes: "fd 83 00 91", mnemonic: "add", operands: "x29, sp, #0x20", hasBreakpoint: false, comment: "frame pointer"),
            InstructionRow(address: 0x1000_01808, bytes: "a0 00 80 d2", mnemonic: "mov", operands: "x0, #0x5", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0180c, bytes: "a0 83 1f f8", mnemonic: "stur", operands: "x0, [x29, #-0x8]", hasBreakpoint: false, comment: "local spill"),
            InstructionRow(address: 0x1000_01810, bytes: "e1 0f 40 f9", mnemonic: "ldr", operands: "x1, [sp, #0x18]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01814, bytes: "20 00 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01818, bytes: "ff 83 00 91", mnemonic: "add", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0181c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_fp_spill", instructions: rows)
        XCTAssertEqual(function.stackFrameSize, 0x20)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x18, type: "int64_t", byteWidth: 8)]
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .store(source: .register(name: "x0", version: 1), address: .stackSlot(offset: 0x18))
        )
        XCTAssertEqual(
            function.instructions[4].operation,
            .stackSlotRead(
                destination: .register(name: "x1", version: 1),
                slot: .stackSlot(offset: 0x18),
                value: .register(name: "x0", version: 1)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.lines(sourcedAt: 0x1000_0180c).single?.text,
            "    local_18 = x0_1; // local spill; stack store"
        )
        XCTAssertEqual(
            document.lines(sourcedAt: 0x1000_01810).single?.text,
            "    x1_1 = local_18; // recovered stack[0x18]"
        )
    }

    func testFramePointerRelativeUnscaledLoadRecoversStoredValue() throws {
        let rows = [
            InstructionRow(address: 0x1000_01900, bytes: "ff 83 00 d1", mnemonic: "sub", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01904, bytes: "fd 83 00 91", mnemonic: "add", operands: "x29, sp, #0x20", hasBreakpoint: false, comment: "frame pointer"),
            InstructionRow(address: 0x1000_01908, bytes: "e0 00 80 d2", mnemonic: "mov", operands: "x0, #0x7", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0190c, bytes: "a0 83 1f f8", mnemonic: "stur", operands: "x0, [x29, #-0x8]", hasBreakpoint: false, comment: "local spill"),
            InstructionRow(address: 0x1000_01910, bytes: "a1 83 5f f8", mnemonic: "ldur", operands: "x1, [x29, #-0x8]", hasBreakpoint: false, comment: "unscaled reload"),
            InstructionRow(address: 0x1000_01914, bytes: "20 00 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01918, bytes: "ff 83 00 91", mnemonic: "add", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0191c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_fp_unscaled_reload", instructions: rows)
        XCTAssertEqual(function.stackFrameSize, 0x20)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x18, type: "int64_t", byteWidth: 8)]
        )
        XCTAssertEqual(
            function.instructions[4].operation,
            .stackSlotRead(
                destination: .register(name: "x1", version: 1),
                slot: .stackSlot(offset: 0x18),
                value: .register(name: "x0", version: 1)
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _fp_unscaled_reload(void) {
                // entry 0x0000000100001900; stack frame 0x20 bytes; calls none
                int64_t local_18;
                sp_1 = __stack_alloc(0x20); // allocates 0x20 stack bytes
                x29_1 = sp_1 + 0x20; // frame pointer
                x0_1 = 0x7;
                local_18 = x0_1; // local spill; stack store
                x1_1 = local_18; // unscaled reload; recovered stack[0x18]
                x0_2 = x1_1;
                sp_2 = __stack_free(0x20); // releases 0x20 stack bytes
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01910).single?.text, "    x1_1 = local_18; // unscaled reload; recovered stack[0x18]")
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testPairStackStoreSeedsScalarReloadValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_01a00, bytes: "ff 83 00 d1", mnemonic: "sub", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01a04, bytes: "e0 07 01 a9", mnemonic: "stp", operands: "x0, x1, [sp, #0x10]", hasBreakpoint: false, comment: "spill pair"),
            InstructionRow(address: 0x1000_01a08, bytes: "e2 0b 40 f9", mnemonic: "ldr", operands: "x2, [sp, #0x10]", hasBreakpoint: false, comment: "reload first"),
            InstructionRow(address: 0x1000_01a0c, bytes: "e3 0f 40 f9", mnemonic: "ldr", operands: "x3, [sp, #0x18]", hasBreakpoint: false, comment: "reload second"),
            InstructionRow(address: 0x1000_01a10, bytes: "40 00 03 8b", mnemonic: "add", operands: "x0, x2, x3", hasBreakpoint: false, comment: "combine reloaded pair"),
            InstructionRow(address: 0x1000_01a14, bytes: "ff 83 00 91", mnemonic: "add", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01a18, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_pair_spill", instructions: rows)
        XCTAssertEqual(function.stackFrameSize, 0x20)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.localVariables,
            [
                MacIRLocalVariable(offset: 0x10, type: "int64_t", byteWidth: 8),
                MacIRLocalVariable(offset: 0x18, type: "int64_t", byteWidth: 8)
            ]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .intrinsic(
                destination: nil,
                name: "save_pair",
                arguments: [
                    .argument(bindingID: .gpr(0)),
                    .argument(bindingID: .gpr(1)),
                    .stackSlot(offset: 0x10),
                    .stackSlot(offset: 0x18)
                ]
            )
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .stackSlotRead(
                destination: .register(name: "x2", version: 1),
                slot: .stackSlot(offset: 0x10),
                value: .argument(bindingID: .gpr(0))
            )
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .stackSlotRead(
                destination: .register(name: "x3", version: 1),
                slot: .stackSlot(offset: 0x18),
                value: .argument(bindingID: .gpr(1))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _pair_spill(int64_t arg0, int64_t arg1) {
                // entry 0x0000000100001a00; stack frame 0x20 bytes; calls none
                int64_t local_10;
                int64_t local_18;
                sp_1 = __stack_alloc(0x20); // allocates 0x20 stack bytes
                local_10, local_18 = arg0, arg1; // spill pair; saves register pair
                x2_1 = local_10; // reload first; recovered stack[0x10]
                x3_1 = local_18; // reload second; recovered stack[0x18]
                x0_1 = x2_1 + x3_1; // combine reloaded pair
                sp_2 = __stack_free(0x20); // releases 0x20 stack bytes
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01a08).single?.text, "    x2_1 = local_10; // reload first; recovered stack[0x10]")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_01a0c).single?.text, "    x3_1 = local_18; // reload second; recovered stack[0x18]")
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testPairedStackReloadRecoversSavedRegisterValues() throws {
        let rows = [
            InstructionRow(address: 0x1000_01b00, bytes: "ff 83 00 d1", mnemonic: "sub", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01b04, bytes: "e0 07 01 a9", mnemonic: "stp", operands: "x0, x1, [sp, #0x10]", hasBreakpoint: false, comment: "spill pair"),
            InstructionRow(address: 0x1000_01b08, bytes: "e2 0b 41 a9", mnemonic: "ldp", operands: "x2, x3, [sp, #0x10]", hasBreakpoint: false, comment: "reload pair"),
            InstructionRow(address: 0x1000_01b0c, bytes: "40 00 03 8b", mnemonic: "add", operands: "x0, x2, x3", hasBreakpoint: false, comment: "combine"),
            InstructionRow(address: 0x1000_01b10, bytes: "ff 83 00 91", mnemonic: "add", operands: "sp, sp, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_01b14, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_pair_reload", instructions: rows)
        XCTAssertEqual(function.stackFrameSize, 0x20)
        XCTAssertEqual(
            function.localVariables,
            [
                MacIRLocalVariable(offset: 0x10, type: "int64_t", byteWidth: 8),
                MacIRLocalVariable(offset: 0x18, type: "int64_t", byteWidth: 8)
            ]
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .stackSlotPairRead(
                firstDestination: .register(name: "x2", version: 1),
                firstSlot: .stackSlot(offset: 0x10),
                firstValue: .argument(bindingID: .gpr(0)),
                secondDestination: .register(name: "x3", version: 1),
                secondSlot: .stackSlot(offset: 0x18),
                secondValue: .argument(bindingID: .gpr(1))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _pair_reload(int64_t arg0, int64_t arg1) {
                // entry 0x0000000100001b00; stack frame 0x20 bytes; calls none
                int64_t local_10;
                int64_t local_18;
                sp_1 = __stack_alloc(0x20); // allocates 0x20 stack bytes
                local_10, local_18 = arg0, arg1; // spill pair; saves register pair
                x2_1, x3_1 = local_10, local_18; // reload pair; restores register pair; recovered stack[0x10], stack[0x18]
                x0_1 = x2_1 + x3_1; // combine
                sp_2 = __stack_free(0x20); // releases 0x20 stack bytes
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(
            document.lines(sourcedAt: 0x1000_01b08).single?.text,
            "    x2_1, x3_1 = local_10, local_18; // reload pair; restores register pair; recovered stack[0x10], stack[0x18]"
        )
        XCTAssertFalse(document.text.contains("__restore_pair"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testConditionalBranchesUseComparisonContextAndZeroChecks() throws {
        let rows = [
            InstructionRow(address: 0x1000_02000, bytes: "60 00 80 d2", mnemonic: "mov", operands: "x0, #0x3", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_02004, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_02008, bytes: "80 00 00 54", mnemonic: "b.eq", operands: "0x100002018", hasBreakpoint: false, comment: "zero path"),
            InstructionRow(address: 0x1000_0200c, bytes: "a0 00 00 b5", mnemonic: "cbnz", operands: "x0, 0x100002020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_02010, bytes: "20 00 80 52", mnemonic: "mov", operands: "w0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_02014, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_branchy", instructions: rows)
        XCTAssertEqual(
            function.instructions[2].operation,
            .conditionalBranch(
                condition: "==",
                left: .register(name: "x0", version: 1),
                right: .immediate(0),
                target: .immediate(0x1000_02018)
            )
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .conditionalBranch(
                condition: "!=",
                left: .register(name: "x0", version: 1),
                right: .immediate(0),
                target: .immediate(0x1000_02020)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        GotoLabelWellFormednessTests.assertTransfer(document.lines(sourcedAt: 0x1000_02008).map(\.text).joined(separator: "\n"), target: 0x100002018, condition: "== 0x0")
        GotoLabelWellFormednessTests.assertTransfer(document.lines(sourcedAt: 0x1000_0200c).map(\.text).joined(separator: "\n"), target: 0x100002020, condition: "!= 0x0")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_02000).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_02010).count, 1)
        XCTAssertTrue(document.text.contains("unresolved_return_contract"))

        let branchLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_02008).single)
        XCTAssertTrue(branchLine.tokens.contains { $0.kind == .keyword && $0.text == "if" })
        XCTAssertFalse(branchLine.tokens.contains { $0.kind == .keyword && $0.text == "goto" })
        XCTAssertTrue(branchLine.tokens.contains { $0.kind == .comment && $0.text == "// zero path; conditional branch" })
    }

    func testSubtractionCompareAliasFeedsStructuredBranchRecovery() throws {
        let rows = [
            InstructionRow(address: 0x1000_0a000, bytes: "1f 00 01 eb", mnemonic: "subs", operands: "xzr, x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0a004, bytes: "4a 00 00 54", mnemonic: "b.ge", operands: "0x10000a00c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0a008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "less-than body"),
            InstructionRow(address: 0x1000_0a00c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_subs_compare_alias", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [
                    .argument(bindingID: .gpr(0)),
                    .argument(bindingID: .gpr(1))
                ]
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: ">=",
                left: .argument(bindingID: .gpr(0)),
                right: .argument(bindingID: .gpr(1)),
                target: .immediate(0x1000_0a00c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _subs_compare_alias(int64_t arg0, int64_t arg1) {
                // entry 0x000000010000a000; no stack frame; calls none
                if (arg0 < arg1) { // conditional branch
                    __nop(); // less-than body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0a000), [])
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0a004).single?.text, "    if (arg0 < arg1) { // conditional branch")
    }

    func testFlagSettingSubtractionFeedsFollowingConditionalBranch() throws {
        let rows = [
            InstructionRow(address: 0x1000_0a100, bytes: "08 04 00 f1", mnemonic: "subs", operands: "x8, x0, #0x1", hasBreakpoint: false, comment: "decrement and set flags"),
            InstructionRow(address: 0x1000_0a104, bytes: "81 00 00 54", mnemonic: "b.ne", operands: "0x10000a120", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0a108, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_subs_flags", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x8", version: 1),
                op: "-",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(1)
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "!=",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(1),
                target: .immediate(0x1000_0a120)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        GotoLabelWellFormednessTests.assertTransfer(document.lines(sourcedAt: 0x1000_0a104).map(\.text).joined(separator: "\n"), target: 0x10000a120, condition: "arg0 != 0x1")
        XCTAssertTrue(document.lines(sourcedAt: 0x1000_0a100).contains { $0.text.contains("arg0 - 0x1") })
        XCTAssertTrue(document.text.contains("unresolved_return_contract"))
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testCompareBranchOverFallthroughPrintsStructuredIfWithoutGoto() throws {
        let rows = [
            InstructionRow(address: 0x1000_04000, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_04004, bytes: "40 00 00 54", mnemonic: "b.eq", operands: "0x10000400c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_04008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "fallthrough work"),
            InstructionRow(address: 0x1000_0400c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_branch_over_fallthrough", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_0400c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _branch_over_fallthrough(int64_t arg0) {
                // entry 0x0000000100004000; no stack frame; calls none
                if (arg0 != 0x0) { // conditional branch
                    __nop(); // fallthrough work
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__compare"), document.text)

        let ifLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_04004).single)
        XCTAssertTrue(ifLine.tokens.contains { $0.kind == .keyword && $0.text == "if" })
        XCTAssertFalse(ifLine.tokens.contains { $0.kind == .keyword && $0.text == "goto" })
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_04008).single?.text, "        __nop(); // fallthrough work")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0400c).single?.text, "    return unresolved_return_contract; // return")
    }

    func testCompareGuardedBackEdgePrintsStructuredWhileWithoutGoto() throws {
        let rows = [
            InstructionRow(address: 0x1000_09000, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_09004, bytes: "60 00 00 54", mnemonic: "b.eq", operands: "0x100009010", hasBreakpoint: false, comment: "exit when zero"),
            InstructionRow(address: 0x1000_09008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "loop body"),
            InstructionRow(address: 0x1000_0900c, bytes: "fd ff ff 17", mnemonic: "b", operands: "0x100009000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_09010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_guarded_loop", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_09010)
            )
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1000_09000)])
        )

        SSARenderExpectation.assertEntryBackedgeRefusal(function)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _guarded_loop(int64_t arg0) {
                // entry 0x0000000100009000; no stack frame; calls none
                while (arg0 != 0x0) { // exit when zero; conditional branch
                    __nop(); // loop body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__compare"), document.text)
        XCTAssertFalse(document.text.contains("__branch"), document.text)

        let whileLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_09004).single)
        XCTAssertTrue(whileLine.tokens.contains { $0.kind == .keyword && $0.text == "while" })
        XCTAssertFalse(whileLine.tokens.contains { $0.kind == .keyword && $0.text == "goto" })
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_09008).single?.text, "        __nop(); // loop body")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0900c), [])
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_09010).single?.text, "    return unresolved_return_contract; // return")
    }

    func testCompareBranchToElsePrintsStructuredIfElseWithoutGoto() throws {
        let rows = [
            InstructionRow(address: 0x1000_04400, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_04404, bytes: "60 00 00 54", mnemonic: "b.eq", operands: "0x100004410", hasBreakpoint: false, comment: "zero alternative"),
            InstructionRow(address: 0x1000_04408, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "nonzero body"),
            InstructionRow(address: 0x1000_0440c, bytes: "02 00 00 14", mnemonic: "b", operands: "0x100004414", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_04410, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "zero body"),
            InstructionRow(address: 0x1000_04414, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_branch_to_else", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_04410)
            )
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1000_04414)])
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _branch_to_else(int64_t arg0) {
                // entry 0x0000000100004400; no stack frame; calls none
                if (arg0 != 0x0) { // zero alternative; conditional branch
                    __nop(); // nonzero body
                } else {
                    __nop(); // zero body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__compare"), document.text)
        XCTAssertFalse(document.text.contains("__branch"), document.text)

        let ifLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_04404).single)
        XCTAssertTrue(ifLine.tokens.contains { $0.kind == .keyword && $0.text == "if" })
        XCTAssertFalse(ifLine.tokens.contains { $0.kind == .keyword && $0.text == "goto" })
        let elseLine = try XCTUnwrap(document.lines.first { $0.text == "    } else {" })
        XCTAssertNil(elseLine.source)
        XCTAssertTrue(elseLine.tokens.contains { $0.kind == .keyword && $0.text == "else" })
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_04408).single?.text, "        __nop(); // nonzero body")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_04410).single?.text, "        __nop(); // zero body")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_04414).single?.text, "    return unresolved_return_contract; // return")
    }

    func testZeroCheckBranchOverFallthroughPrintsStructuredIfWithoutGoto() throws {
        let cbzRows = [
            InstructionRow(address: 0x1000_05000, bytes: "60 00 00 b4", mnemonic: "cbz", operands: "x0, 0x10000500c", hasBreakpoint: false, comment: "skip zero path"),
            InstructionRow(address: 0x1000_05004, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "nonzero body"),
            InstructionRow(address: 0x1000_05008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0500c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let cbzFunction = MacIRBuilder().buildFunction(name: "_cbz_skip", instructions: cbzRows)
        XCTAssertEqual(
            legacyParameterShape(cbzFunction.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            cbzFunction.instructions[0].operation,
            .conditionalBranch(
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_0500c)
            )
        )

        let cbzDocument = PseudocodePrinter().print(function: cbzFunction)
        XCTAssertEqual(
            cbzDocument.text,
            """
            int64_t _cbz_skip(int64_t arg0) {
                // entry 0x0000000100005000; no stack frame; calls none
                if (arg0) { // skip zero path; conditional branch
                    __nop(); // nonzero body
                    __nop();
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(cbzDocument.text.contains("goto"), cbzDocument.text)
        XCTAssertFalse(cbzDocument.text.contains("__compare"), cbzDocument.text)
        let cbzIfLine = try XCTUnwrap(cbzDocument.lines(sourcedAt: 0x1000_05000).single)
        XCTAssertTrue(cbzIfLine.tokens.contains { $0.kind == .keyword && $0.text == "if" })
        XCTAssertEqual(cbzDocument.lines(sourcedAt: 0x1000_05004).single?.text, "        __nop(); // nonzero body")

        let cbnzRows = [
            InstructionRow(address: 0x1000_05200, bytes: "60 00 00 b5", mnemonic: "cbnz", operands: "x0, 0x10000520c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_05204, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "zero body"),
            InstructionRow(address: 0x1000_05208, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0520c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let cbnzFunction = MacIRBuilder().buildFunction(name: "_cbnz_skip", instructions: cbnzRows)
        XCTAssertEqual(
            cbnzFunction.instructions[0].operation,
            .conditionalBranch(
                condition: "!=",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_0520c)
            )
        )

        let cbnzDocument = PseudocodePrinter().print(function: cbnzFunction)
        XCTAssertEqual(
            cbnzDocument.text,
            """
            int64_t _cbnz_skip(int64_t arg0) {
                // entry 0x0000000100005200; no stack frame; calls none
                if (!arg0) { // conditional branch
                    __nop(); // zero body
                    __nop();
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(cbnzDocument.text.contains("goto"), cbnzDocument.text)
        XCTAssertFalse(cbnzDocument.text.contains("__compare"), cbnzDocument.text)
        XCTAssertEqual(cbnzDocument.lines(sourcedAt: 0x1000_05200).single?.text, "    if (!arg0) { // conditional branch")
        XCTAssertEqual(cbnzDocument.lines(sourcedAt: 0x1000_05204).single?.text, "        __nop(); // zero body")
    }

    func testZeroCheckGuardedBackEdgePrintsBooleanWhileCondition() throws {
        let rows = [
            InstructionRow(address: 0x1000_08400, bytes: "60 00 00 b4", mnemonic: "cbz", operands: "x0, 0x10000840c", hasBreakpoint: false, comment: "exit when zero"),
            InstructionRow(address: 0x1000_08404, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "loop body"),
            InstructionRow(address: 0x1000_08408, bytes: "fe ff ff 17", mnemonic: "b", operands: "0x100008400", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0840c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_cbz_loop", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .conditionalBranch(
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_0840c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _cbz_loop(int64_t arg0) {
                // entry 0x0000000100008400; no stack frame; calls none
                while (arg0) { // exit when zero; conditional branch
                    __nop(); // loop body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__branch"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08400).single?.text, "    while (arg0) { // exit when zero; conditional branch")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08404).single?.text, "        __nop(); // loop body")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08408), [])
    }

    func testBitTestBranchOverFallthroughPrintsStructuredIfWithoutGoto() throws {
        let tbzRows = [
            InstructionRow(address: 0x1000_07000, bytes: "60 00 10 36", mnemonic: "tbz", operands: "x0, #0x2, 0x10000700c", hasBreakpoint: false, comment: "skip clear bit"),
            InstructionRow(address: 0x1000_07004, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "set-bit body"),
            InstructionRow(address: 0x1000_07008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0700c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let tbzFunction = MacIRBuilder().buildFunction(name: "_tbz_skip", instructions: tbzRows)
        XCTAssertEqual(
            legacyParameterShape(tbzFunction.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            tbzFunction.instructions[0].operation,
            .conditionalBranch(
                condition: "==",
                left: .bitTest(
                    value: .argument(bindingID: .gpr(0)),
                    bit: 2
                ),
                right: .immediate(0),
                target: .immediate(0x1000_0700c)
            )
        )

        let tbzDocument = PseudocodePrinter().print(function: tbzFunction)
        XCTAssertEqual(
            tbzDocument.text,
            """
            int64_t _tbz_skip(int64_t arg0) {
                // entry 0x0000000100007000; no stack frame; calls none
                if (((arg0 >> 0x2) & 0x1) != 0x0) { // skip clear bit; conditional branch
                    __nop(); // set-bit body
                    __nop();
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(tbzDocument.text.contains("goto"), tbzDocument.text)
        XCTAssertFalse(tbzDocument.text.contains("__compare"), tbzDocument.text)
        XCTAssertEqual(tbzDocument.lines(sourcedAt: 0x1000_07000).single?.text, "    if (((arg0 >> 0x2) & 0x1) != 0x0) { // skip clear bit; conditional branch")
        XCTAssertEqual(tbzDocument.lines(sourcedAt: 0x1000_07004).single?.text, "        __nop(); // set-bit body")

        let tbnzRows = [
            InstructionRow(address: 0x1000_07200, bytes: "20 00 08 37", mnemonic: "tbnz", operands: "w0, #0x1, 0x100007208", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_07204, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "clear-bit body"),
            InstructionRow(address: 0x1000_07208, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let tbnzFunction = MacIRBuilder().buildFunction(name: "_tbnz_skip", instructions: tbnzRows)
        XCTAssertEqual(
            legacyParameterShape(tbnzFunction.parameters),
            [MacIRFunctionParameter(index: 0, register: "w0", type: "int32_t")]
        )
        XCTAssertEqual(
            tbnzFunction.instructions[0].operation,
            .conditionalBranch(
                condition: "!=",
                left: .bitTest(
                    value: .argument(bindingID: .gpr(0)),
                    bit: 1
                ),
                right: .immediate(0),
                target: .immediate(0x1000_07208)
            )
        )

        let tbnzDocument = PseudocodePrinter().print(function: tbnzFunction)
        XCTAssertEqual(
            tbnzDocument.text,
            """
            int64_t _tbnz_skip(int32_t arg0) {
                // entry 0x0000000100007200; no stack frame; calls none
                if (((arg0 >> 0x1) & 0x1) == 0x0) { // conditional branch
                    __nop(); // clear-bit body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(tbnzDocument.text.contains("goto"), tbnzDocument.text)
        XCTAssertFalse(tbnzDocument.text.contains("__compare"), tbnzDocument.text)
        XCTAssertEqual(tbnzDocument.lines(sourcedAt: 0x1000_07200).single?.text, "    if (((arg0 >> 0x1) & 0x1) == 0x0) { // conditional branch")
        XCTAssertEqual(tbnzDocument.lines(sourcedAt: 0x1000_07204).single?.text, "        __nop(); // clear-bit body")
    }

    func testTestBitImmediateFeedsStructuredBranchRecovery() throws {
        let rows = [
            InstructionRow(address: 0x1000_07400, bytes: "1f 00 40 f2", mnemonic: "tst", operands: "x0, #0x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_07404, bytes: "40 00 00 54", mnemonic: "b.eq", operands: "0x10000740c", hasBreakpoint: false, comment: "skip clear flag"),
            InstructionRow(address: 0x1000_07408, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "flag set body"),
            InstructionRow(address: 0x1000_0740c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_tst_flag_branch", instructions: rows)
        let testedBit = MacIRValue.unary(op: "(int64_t)", value: .binaryExpression(op: "&",
            left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
            right: .immediate(8)))
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: nil, name: "compare", arguments: [testedBit, .immediate(0)])
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "==",
                left: testedBit,
                right: .immediate(0),
                target: .immediate(0x1000_0740c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _tst_flag_branch(int64_t arg0) {
                // entry 0x0000000100007400; no stack frame; calls none
                if ((int64_t)((uint64_t)(arg0) & 0x8) != 0x0) { // skip clear flag; conditional branch
                    __nop(); // flag set body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__compare"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_07400), [])
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_07404).single?.text, "    if ((int64_t)((uint64_t)(arg0) & 0x8) != 0x0) { // skip clear flag; conditional branch")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_07408).single?.text, "        __nop(); // flag set body")
    }

    func testTestBitImmediateFeedsConditionalSelectRecovery() throws {
        let rows = [
            InstructionRow(address: 0x1000_07600, bytes: "1f 00 00 72", mnemonic: "tst", operands: "w0, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_07604, bytes: "20 10 82 1a", mnemonic: "csel", operands: "w0, w1, w2, ne", hasBreakpoint: false, comment: "choose bit state"),
            InstructionRow(address: 0x1000_07608, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_tst_flag_select", instructions: rows)
        let testedBit = MacIRValue.unary(op: "(int32_t)", value: .binaryExpression(op: "&",
            left: .unary(op: "(uint32_t)", value: .argument(bindingID: .gpr(0))),
            right: .immediate(2)))
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "w0", type: "int32_t"),
                MacIRFunctionParameter(index: 1, register: "w1", type: "int32_t"),
                MacIRFunctionParameter(index: 2, register: "w2", type: "int32_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: nil, name: "compare", arguments: [testedBit, .immediate(0)])
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .select(
                destination: .register(name: "w0", version: 1),
                condition: "!=",
                left: testedBit,
                right: .immediate(0),
                trueValue: .argument(bindingID: .gpr(1)),
                falseValue: .argument(bindingID: .gpr(2))
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _tst_flag_select(int32_t arg0, int32_t arg1, int32_t arg2) {
                // entry 0x0000000100007600; no stack frame; calls none
                w0_1 = ((int32_t)((uint32_t)(arg0) & 0x2) != 0x0) ? arg1 : arg2; // choose bit state; conditional select
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_07604).single?.text, "    w0_1 = ((int32_t)((uint32_t)(arg0) & 0x2) != 0x0) ? arg1 : arg2; // choose bit state; conditional select")
    }

    func testCompareSetMaterializesBooleanPredicate() throws {
        let rows = [
            InstructionRow(address: 0x1000_07800, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_07804, bytes: "e0 07 9f 1a", mnemonic: "cset", operands: "w0, ne", hasBreakpoint: false, comment: "materialize predicate"),
            InstructionRow(address: 0x1000_07808, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_is_nonzero", instructions: rows)
        XCTAssertEqual(function.returnType, "BOOL")
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .compareToBool(
                destination: .register(name: "w0", version: 1),
                condition: "!=",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0)
            )
        )
        XCTAssertEqual(function.returnValue, .register(name: "w0", version: 1))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            BOOL _is_nonzero(int64_t arg0) {
                // entry 0x0000000100007800; no stack frame; calls none
                w0_1 = arg0 != 0x0; // materialize predicate; compare to bool
                return w0_1; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__compare"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_07800), [])
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_07804).single?.text, "    w0_1 = arg0 != 0x0; // materialize predicate; compare to bool")
    }

    func testCompareBranchOverReturnPrintsStructuredEarlyReturnWithoutGoto() throws {
        let rows = [
            InstructionRow(address: 0x1000_08000, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_08004, bytes: "61 00 00 54", mnemonic: "b.ne", operands: "0x100008010", hasBreakpoint: false, comment: "skip zero return"),
            InstructionRow(address: 0x1000_08008, bytes: "00 00 80 52", mnemonic: "mov", operands: "w0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0800c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_08010, bytes: "20 00 80 52", mnemonic: "mov", operands: "w0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_08014, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_compare_early_return", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "!=",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_08010)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _compare_early_return(int64_t arg0) {
                // entry 0x0000000100008000; no stack frame; calls none
                if (arg0 == 0x0) { // skip zero return; conditional branch
                    w0_1 = 0x0;
                    return w0_1; // return
                }
                w0_2 = 0x1;
                return w0_2; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__compare"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08004).single?.text, "    if (arg0 == 0x0) { // skip zero return; conditional branch")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0800c).single?.text, "        return w0_1; // return")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08010).single?.text, "    w0_2 = 0x1;")
    }

    func testZeroCheckBranchOverReturnPrintsStructuredEarlyReturnWithoutGoto() throws {
        let rows = [
            InstructionRow(address: 0x1000_08200, bytes: "80 00 00 b5", mnemonic: "cbnz", operands: "x0, 0x10000820c", hasBreakpoint: false, comment: "nonzero continues"),
            InstructionRow(address: 0x1000_08204, bytes: "00 00 80 52", mnemonic: "mov", operands: "w0, #0x0", hasBreakpoint: false, comment: "zero result"),
            InstructionRow(address: 0x1000_08208, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0820c, bytes: "20 00 80 52", mnemonic: "mov", operands: "w0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_08210, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_zero_check_early_return", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .conditionalBranch(
                condition: "!=",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                target: .immediate(0x1000_0820c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _zero_check_early_return(int64_t arg0) {
                // entry 0x0000000100008200; no stack frame; calls none
                if (!arg0) { // nonzero continues; conditional branch
                    w0_1 = 0x0; // zero result
                    return w0_1; // return
                }
                w0_2 = 0x1;
                return w0_2; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08200).single?.text, "    if (!arg0) { // nonzero continues; conditional branch")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08204).single?.text, "        w0_1 = 0x0; // zero result")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_08208).single?.text, "        return w0_1; // return")
    }

    func testUnsupportedConditionalBranchSuffixKeepsIntrinsicFallback() throws {
        let rows = [
            InstructionRow(address: 0x1000_03000, bytes: "02 00 00 54", mnemonic: "b.hs", operands: "0x100003010", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_carry_branch", instructions: rows)
        XCTAssertEqual(
            function.instructions.first?.operation,
            .intrinsic(destination: nil, name: "branch_hs", arguments: [.immediate(0x1000_03010)])
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__branch_hs(0x100003010); // conditional branch"), document.text)
    }

    func testUnsignedCompareBranchSuffixUsesComparisonContext() throws {
        let rows = [
            InstructionRow(address: 0x1000_03200, bytes: "1f 00 01 eb", mnemonic: "cmp", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_03204, bytes: "42 00 00 54", mnemonic: "b.hs", operands: "0x10000320c", hasBreakpoint: false, comment: "skip when above or same"),
            InstructionRow(address: 0x1000_03208, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "below body"),
            InstructionRow(address: 0x1000_0320c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_unsigned_below", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: ">=",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                right: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))),
                target: .immediate(0x1000_0320c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _unsigned_below(int64_t arg0, int64_t arg1) {
                // entry 0x0000000100003200; no stack frame; calls none
                if ((uint64_t)(arg0) < (uint64_t)(arg1)) { // skip when above or same; conditional branch
                    __nop(); // below body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__branch_hs"), document.text)
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_03204).single?.text, "    if ((uint64_t)(arg0) < (uint64_t)(arg1)) { // skip when above or same; conditional branch")
    }

    func testConditionalSelectUsesComparisonContextForValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_06000, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_06004, bytes: "20 00 82 9a", mnemonic: "csel", operands: "x0, x1, x2, eq", hasBreakpoint: false, comment: "choose zero/nonzero"),
            InstructionRow(address: 0x1000_06008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_select_zero", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t"),
                MacIRFunctionParameter(index: 2, register: "x2", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .select(
                destination: .register(name: "x0", version: 1),
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(0),
                trueValue: .argument(bindingID: .gpr(1)),
                falseValue: .argument(bindingID: .gpr(2))
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _select_zero(int64_t arg0, int64_t arg1, int64_t arg2) {
                // entry 0x0000000100006000; no stack frame; calls none
                x0_1 = (arg0 == 0x0) ? arg1 : arg2; // choose zero/nonzero; conditional select
                return unresolved_return_contract; // return
            }
            """
        )

        let selectLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_06004).single)
        XCTAssertTrue(selectLine.tokens.contains { $0.kind == .identifier && $0.text == "arg1" })
        XCTAssertTrue(selectLine.tokens.contains { $0.kind == .comment && $0.text == "// choose zero/nonzero; conditional select" })
    }

    func testUnsignedConditionalSelectUsesComparisonContextForValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_06200, bytes: "1f 00 01 eb", mnemonic: "cmp", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_06204, bytes: "62 30 82 9a", mnemonic: "csel", operands: "x2, x3, x4, lo", hasBreakpoint: false, comment: "choose lower value"),
            InstructionRow(address: 0x1000_06208, bytes: "40 00 02 aa", mnemonic: "mov", operands: "x0, x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0620c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_select_unsigned_lower", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t"),
                MacIRFunctionParameter(index: 3, register: "x3", type: "int64_t"),
                MacIRFunctionParameter(index: 4, register: "x4", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .select(
                destination: .register(name: "x2", version: 1),
                condition: "<",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                right: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))),
                trueValue: .argument(bindingID: .gpr(3)),
                falseValue: .argument(bindingID: .gpr(4))
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _select_unsigned_lower(/* ABI inputs: x0:int64_t in_x0, x1:int64_t in_x1, x3:int64_t in_x3, x4:int64_t in_x4 */) {
                // entry 0x0000000100006200; no stack frame; calls none
                x2_1 = ((uint64_t)(in_x0) < (uint64_t)(in_x1)) ? in_x3 : in_x4; // choose lower value; conditional select
                x0_1 = x2_1;
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_06204).single?.text, "    x2_1 = ((uint64_t)(in_x0) < (uint64_t)(in_x1)) ? in_x3 : in_x4; // choose lower value; conditional select")
    }

    func testConditionalSelectVariantsRenderTransformedFalseArmConservatively() throws {
        // Conservative recovery: csinc/csinv/csneg share csel's condition context, but only
        // the false arm is transformed because that is the architectural behavior.
        let rows = [
            InstructionRow(address: 0x1000_06400, bytes: "1f 00 01 eb", mnemonic: "cmp", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_06404, bytes: "62 34 84 9a", mnemonic: "csinc", operands: "x2, x3, x4, lo", hasBreakpoint: false, comment: "increment false arm"),
            InstructionRow(address: 0x1000_06408, bytes: "c5 a0 87 da", mnemonic: "csinv", operands: "x5, x6, x7, ge", hasBreakpoint: false, comment: "invert false arm"),
            InstructionRow(address: 0x1000_0640c, bytes: "40 14 85 da", mnemonic: "csneg", operands: "x0, x2, x5, ne", hasBreakpoint: false, comment: "negate false arm"),
            InstructionRow(address: 0x1000_06410, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_select_variants", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [
                MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t"),
                MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t"),
                MacIRFunctionParameter(index: 3, register: "x3", type: "int64_t"),
                MacIRFunctionParameter(index: 4, register: "x4", type: "int64_t"),
                MacIRFunctionParameter(index: 6, register: "x6", type: "int64_t"),
                MacIRFunctionParameter(index: 7, register: "x7", type: "int64_t")
            ]
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .select(
                destination: .register(name: "x2", version: 1),
                condition: "<",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                right: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))),
                trueValue: .argument(bindingID: .gpr(3)),
                falseValue: .binaryExpression(
                    op: "+",
                    left: .argument(bindingID: .gpr(4)),
                    right: .immediate(1)
                )
            )
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .select(
                destination: .register(name: "x5", version: 1),
                condition: ">=",
                left: .argument(bindingID: .gpr(0)),
                right: .argument(bindingID: .gpr(1)),
                trueValue: .argument(bindingID: .gpr(6)),
                falseValue: .unary(
                    op: "~",
                    value: .argument(bindingID: .gpr(7))
                )
            )
        )
        XCTAssertEqual(
            function.instructions[3].operation,
            .select(
                destination: .register(name: "x0", version: 1),
                condition: "!=",
                left: .argument(bindingID: .gpr(0)),
                right: .argument(bindingID: .gpr(1)),
                trueValue: .register(name: "x2", version: 1),
                falseValue: .unary(op: "-", value: .register(name: "x5", version: 1))
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _select_variants(/* ABI inputs: x0:int64_t in_x0, x1:int64_t in_x1, x3:int64_t in_x3, x4:int64_t in_x4, x6:int64_t in_x6, x7:int64_t in_x7 */) {
                // entry 0x0000000100006400; no stack frame; calls none
                x2_1 = ((uint64_t)(in_x0) < (uint64_t)(in_x1)) ? in_x3 : in_x4 + 0x1; // increment false arm; conditional select
                x5_1 = (in_x0 >= in_x1) ? in_x6 : ~(in_x7); // invert false arm; conditional select
                x0_1 = (in_x0 != in_x1) ? x2_1 : -(x5_1); // negate false arm; conditional select
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_06404).single?.text, "    x2_1 = ((uint64_t)(in_x0) < (uint64_t)(in_x1)) ? in_x3 : in_x4 + 0x1; // increment false arm; conditional select")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_06408).single?.text, "    x5_1 = (in_x0 >= in_x1) ? in_x6 : ~(in_x7); // invert false arm; conditional select")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0640c).single?.text, "    x0_1 = (in_x0 != in_x1) ? x2_1 : -(x5_1); // negate false arm; conditional select")
    }

    func testLogicalShiftLeftRecoversScaledValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d000, bytes: "00 08 7d d3", mnemonic: "lsl", operands: "x0, x0, #3", hasBreakpoint: false, comment: "scale index"),
            InstructionRow(address: 0x1000_0d004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_scale_index", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "<<",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                right: .immediate(3)
            )
        )
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _scale_index(int64_t arg0) {
                // entry 0x000000010000d000; no stack frame; calls none
                x0_1 = (uint64_t)(arg0) << 0x3; // scale index
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        // In-place lsl x0, x0 reads the incoming arg0, not the freshly written version.
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
    }

    func testLogicalShiftRightRecoversValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d100, bytes: "08 fc 44 d3", mnemonic: "lsr", operands: "x8, x0, #4", hasBreakpoint: false, comment: "high nibble"),
            InstructionRow(address: 0x1000_0d104, bytes: "e0 03 08 aa", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d108, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_high_nibble", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x8", version: 1),
                op: ">>",
                left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                right: .immediate(4)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        // x8 is a scratch register, so it is renamed tmp0.
        XCTAssertTrue(document.text.contains("tmp0 = (uint64_t)(arg0) >> 0x4; // high nibble"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testArithmeticShiftRightRendersAsRightShift() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d200, bytes: "20 fc 41 93", mnemonic: "asr", operands: "x0, x1, #1", hasBreakpoint: false, comment: "halve signed"),
            InstructionRow(address: 0x1000_0d204, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_halve_signed", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 1, register: "x1", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: ">>",
                left: .unary(op: "(int64_t)", value: .argument(bindingID: .gpr(1))),
                right: .immediate(1)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = (int64_t)(in_x1) >> 0x1; // halve signed"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testRegisterAmountShiftLiftsToShiftExpression() throws {
        // Round 3 (IR-3): the register-amount lsl (lslv alias) now lifts to a shift
        // expression, like the register-amount lsr/asr forms. The exact IR + parameter
        // recovery is pinned by MacIRLiftingBreadthRound3Tests; here we assert only that it
        // no longer falls back to __unknown and renders a `<<`.
        let rows = [
            InstructionRow(address: 0x1000_0d300, bytes: "20 20 c2 9a", mnemonic: "lsl", operands: "x0, x1, x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d304, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_register_shift", instructions: rows)
        if case .unknown = function.instructions[0].operation {
            XCTFail("register-amount lsl should lift, not fall back to __unknown")
        }

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("<<"), document.text)
        XCTAssertFalse(document.text.contains("__unknown(\"lsl\""), document.text)
    }

    func testMalformedShiftFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d400, bytes: "00 00 00 00", mnemonic: "lsr", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d404, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_malformed_shift", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "lsr", operands: "x0, x1")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"lsr\", \"x0, x1\")"), document.text)
    }

    func testUnsignedBitfieldExtractRecoversShiftAndMaskValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e000, bytes: "00 0c 44 d3", mnemonic: "ubfx", operands: "x0, x0, #4, #4", hasBreakpoint: false, comment: "extract nibble"),
            InstructionRow(address: 0x1000_0e004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_extract_nibble", instructions: rows)
        XCTAssertEqual(
            legacyParameterShape(function.parameters),
            [MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t")]
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .binaryExpression(
                    op: "&",
                    left: .binaryExpression(
                        op: ">>",
                        left: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(0))),
                        right: .immediate(4)
                    ),
                    right: .immediate(0xf)
                )
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _extract_nibble(int64_t arg0) {
                // entry 0x000000010000e000; no stack frame; calls none
                x0_1 = ((uint64_t)(arg0) >> 0x4) & 0xf; // extract nibble
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
    }

    func testZeroLsbBitfieldExtractDropsRedundantShift() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e100, bytes: "08 1c 40 d3", mnemonic: "ubfx", operands: "x8, x0, #0, #8", hasBreakpoint: false, comment: "low byte"),
            InstructionRow(address: 0x1000_0e104, bytes: "e0 03 08 aa", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e108, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_low_byte", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x8", version: 1),
                source: .binaryExpression(
                    op: "&",
                    left: .argument(bindingID: .gpr(0)),
                    right: .immediate(0xff)
                )
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("tmp0 = arg0 & 0xff; // low byte"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testSignedBitfieldExtractLiftsWithArithmeticShift() throws {
        // The signed operation retains its source identity and explicit field width.
        let rows = [
            InstructionRow(address: 0x1000_0e200, bytes: "00 0c 44 93", mnemonic: "sbfx", operands: "x0, x0, #4, #4", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e204, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_signed_field", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("__unknown(\"sbfx\""), document.text)
        XCTAssertTrue(document.text.contains("mscope_sbfx_bits_u64(arg0, 4, 4)"), document.text)
    }

    func testMalformedBitfieldExtractFallsBackToUnknown() throws {
        // Conservatism guard: the width operand is missing, so the faithful
        // low-level rendering is preserved.
        let rows = [
            InstructionRow(address: 0x1000_0e300, bytes: "00 00 00 00", mnemonic: "ubfx", operands: "x0, x1, #4", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e304, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_malformed_field", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "ubfx", operands: "x0, x1, #4")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"ubfx\", \"x0, x1, #4\")"), document.text)
    }

    func testAdrpAddPageOffsetPairFoldsIntoNamedGlobalAddress() throws {
        // The canonical Apple Silicon `adrp _sym@PAGE` / `add _sym@PAGEOFF`
        // pair computes the runtime address of a named global; the printer
        // collapses the certain pair into a single `dst = &_sym` assignment.
        let rows = [
            InstructionRow(address: 0x1000_0f000, bytes: "00 00 00 00", mnemonic: "adrp", operands: "x8, _g_counter@PAGE", hasBreakpoint: false, comment: "page of global"),
            InstructionRow(address: 0x1000_0f004, bytes: "00 00 00 00", mnemonic: "add", operands: "x8, x8, _g_counter@PAGEOFF", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f008, bytes: "00 00 00 00", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f00c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_take_global", instructions: rows)
        // The adrp result (x8 v1) renames to tmp0; the add destination (x8 v2)
        // renames to tmp1, which is what the folded line names.
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: .register(name: "x8", version: 1),
                name: "adrp",
                arguments: [.symbol("_g_counter@PAGE")]
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .binary(
                destination: .register(name: "x8", version: 2),
                op: "+",
                left: .register(name: "x8", version: 1),
                right: .symbol("_g_counter@PAGEOFF")
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _take_global(void) {
                // entry 0x000000010000f000; no stack frame; calls none
                tmp1 = &_g_counter; // global address
                x0_1 = tmp1;
                return unresolved_return_contract; // return
            }
            """
        )

        // The fold collapses the two source addresses into the single line
        // attributed to the add (0xf004); the adrp line is suppressed.
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0f004).single?.text, "    tmp1 = &_g_counter; // global address")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_0f000), [])
        XCTAssertFalse(document.text.contains("__adrp"), document.text)
        XCTAssertFalse(document.text.contains("@PAGE"), document.text)
        XCTAssertFalse(document.text.contains("+ _g_counter"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)

        let foldedLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_0f004).single)
        XCTAssertTrue(foldedLine.tokens.contains { $0.kind == .identifier && $0.text == "_g_counter" })
        XCTAssertTrue(foldedLine.tokens.contains { $0.kind == .punctuation && $0.text == "&" })
    }

    func testAdrpAddMismatchedSymbolDoesNotFold() throws {
        // Conservatism guard: the add references a different base symbol than
        // the adrp, so the certain-pair precondition fails and the faithful
        // two-line rendering is preserved.
        let rows = [
            InstructionRow(address: 0x1000_0f000, bytes: "00 00 00 00", mnemonic: "adrp", operands: "x8, _g_counter@PAGE", hasBreakpoint: false, comment: "page of global"),
            InstructionRow(address: 0x1000_0f004, bytes: "00 00 00 00", mnemonic: "add", operands: "x8, x8, _other@PAGEOFF", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f008, bytes: "00 00 00 00", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f00c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_take_global", instructions: rows)
        XCTAssertEqual(
            function.instructions[1].operation,
            .binary(
                destination: .register(name: "x8", version: 2),
                op: "+",
                left: .register(name: "x8", version: 1),
                right: .symbol("_other@PAGEOFF")
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__adrp"), document.text)
        XCTAssertFalse(document.text.contains("&_g_counter"), document.text)
        XCTAssertFalse(document.text.contains("= &"), document.text)
    }

    func testAdrpAddNonAdjacentDoesNotFold() throws {
        // Conservatism guard: an unrelated instruction sits between the adrp
        // and the add, so `source.address + 4` no longer matches the add and
        // the fold is rejected.
        let rows = [
            InstructionRow(address: 0x1000_0f000, bytes: "00 00 00 00", mnemonic: "adrp", operands: "x8, _g_counter@PAGE", hasBreakpoint: false, comment: "page of global"),
            InstructionRow(address: 0x1000_0f004, bytes: "00 00 00 00", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f008, bytes: "00 00 00 00", mnemonic: "add", operands: "x8, x8, _g_counter@PAGEOFF", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f00c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f010, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_take_global", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("= &_g_counter"), document.text)
        XCTAssertTrue(document.text.contains("__adrp"), document.text)
    }

    func testAdrpAddBrokenDataFlowDoesNotFold() throws {
        // Conservatism guard: the add reads a register other than the one the
        // adrp wrote, so the data-flow link is broken and the fold is rejected.
        let rows = [
            InstructionRow(address: 0x1000_0f000, bytes: "00 00 00 00", mnemonic: "adrp", operands: "x8, _g@PAGE", hasBreakpoint: false, comment: "page of global"),
            InstructionRow(address: 0x1000_0f004, bytes: "00 00 00 00", mnemonic: "add", operands: "x0, x9, _g@PAGEOFF", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f008, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_take_global", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("= &_g"), document.text)
        XCTAssertTrue(document.text.contains("__adrp"), document.text)
    }

    // MARK: - Recursive (nested) structuring

    func testNestedIfInsideIfStructuresAtDepthTwoWithoutGoto() throws {
        // Outer zero-check guard on arg0 spans the whole region; its body
        // contains a second zero-check guard on arg1 whose own body is a single
        // nop. The inner if's join lands on a nop that stays inside the outer
        // body (a closed region), so both levels structure and the nop nests at
        // depth 2 (12 spaces).
        let rows = [
            InstructionRow(address: 0x1000_20000, bytes: "80 00 00 b4", mnemonic: "cbz", operands: "x0, 0x100020010", hasBreakpoint: false, comment: "outer guard"),
            InstructionRow(address: 0x1000_20004, bytes: "81 00 00 b4", mnemonic: "cbz", operands: "x1, 0x10002000c", hasBreakpoint: false, comment: "inner guard"),
            InstructionRow(address: 0x1000_20008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "inner body"),
            InstructionRow(address: 0x1000_2000c, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "after inner"),
            InstructionRow(address: 0x1000_20010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_if_in_if", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _if_in_if(int64_t arg0, int64_t arg1) {
                // entry 0x0000000100020000; no stack frame; calls none
                if (arg0) { // outer guard; conditional branch
                    if (arg1) { // inner guard; conditional branch
                        __nop(); // inner body
                    }
                    __nop(); // after inner
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_20008).single?.text, "            __nop(); // inner body")
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_2000c).single?.text, "        __nop(); // after inner")
    }

    func testInductionForLoopStructuresWithInitConditionAndStep() throws {
        // init (mov w8,#0) precedes a guarded back-edge loop whose condition
        // tests the induction register w8 and whose last body statement steps
        // w8 by +1. All three (init dest, condition var, step dest/left) resolve
        // to the same hardware register, so the loop renders as a single for.
        let rows = [
            InstructionRow(address: 0x1000_30000, bytes: "08 00 80 52", mnemonic: "mov", operands: "w8, #0x0", hasBreakpoint: false, comment: "init"),
            InstructionRow(address: 0x1000_30004, bytes: "1f 29 00 71", mnemonic: "cmp", operands: "w8, #0xa", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30008, bytes: "aa 00 00 54", mnemonic: "b.ge", operands: "0x100030018", hasBreakpoint: false, comment: "exit"),
            InstructionRow(address: 0x1000_3000c, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_30010, bytes: "08 05 00 11", mnemonic: "add", operands: "w8, w8, #0x1", hasBreakpoint: false, comment: "step"),
            InstructionRow(address: 0x1000_30014, bytes: "fc ff ff 17", mnemonic: "b", operands: "0x100030004", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30018, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_for_count", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        if SSAPropertyAssertions.enabled {
            guard let phi = SSAPropertyAssertions.phi(function, block: 0x1000_30004, cell: 8, width: 32,
                incoming: [(0x1000_30000, 0x1000_30000), (0x1000_30014, 0x1000_30010)]) else { return }
            guard case let .binary(_, _, left, _) = function.instructions[4].operation else {
                return XCTFail("the induction step must read the loop-header value")
            }
            SSAPropertyAssertions.assertView(left, of: phi, width: 32)
            SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
            XCTAssertFalse(document.text.contains("unavailable_w8"), document.text)
        } else {
            XCTAssertEqual(
                document.text,
                """
                int64_t _for_count(void) {
                    // entry 0x0000000100030000; no stack frame; calls none
                    tmp0 = 0x0; // init
                    while (unavailable_w8 < 0xa) { // exit; conditional branch
                        __nop(); // body
                        tmp1 = unavailable_w8 + 0x1; // step
                    }
                    return unresolved_return_contract; // return
                }
                """
            )
        }
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertTrue(document.text.contains("while (") || document.text.contains("for ("), document.text)
        XCTAssertFalse(document.text.contains("__branch"), document.text)
        let forLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_30008).single)
        XCTAssertTrue((forLine.text.contains("while (") || forLine.text.contains("for (")) && !forLine.text.contains("tmp0 < 0xa"), forLine.text)
        // A while loop preserves the init and step source rows; a future merged
        // for loop may consume them into its header.
        XCTAssertTrue(document.text.contains("for (") || document.lines(sourcedAt: 0x1000_30000).single?.text == "    tmp0 = 0x0; // init", document.text)
        XCTAssertTrue(document.text.contains("for (") || document.lines(sourcedAt: 0x1000_30010).contains { $0.text.contains(" + 0x1; // step") && !$0.text.contains("tmp0 +") }, document.text)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000_3000c).single?.text, "        __nop(); // body")
    }

    func testTailIncrementOfUnrelatedRegisterStaysWhileLoop() throws {
        // Same guarded back-edge loop, but the trailing step increments w9, a
        // register unrelated to the condition variable w8. The for-loop matcher
        // rejects (step register != condition register), so the loop renders as
        // a plain while with the increment emitted as an ordinary body statement.
        let rows = [
            InstructionRow(address: 0x1000_33000, bytes: "08 00 80 52", mnemonic: "mov", operands: "w8, #0x0", hasBreakpoint: false, comment: "init"),
            InstructionRow(address: 0x1000_33004, bytes: "1f 29 00 71", mnemonic: "cmp", operands: "w8, #0xa", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_33008, bytes: "aa 00 00 54", mnemonic: "b.ge", operands: "0x100033018", hasBreakpoint: false, comment: "exit"),
            InstructionRow(address: 0x1000_3300c, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_33010, bytes: "29 05 00 11", mnemonic: "add", operands: "w9, w9, #0x1", hasBreakpoint: false, comment: "unrelated step"),
            InstructionRow(address: 0x1000_33014, bytes: "fc ff ff 17", mnemonic: "b", operands: "0x100033004", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_33018, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_unrelated_step", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("for ("), document.text)
        XCTAssertTrue(document.text.contains("while ("), document.text)
        XCTAssertFalse(document.text.contains("goto"), document.text)
        // The unrelated increment stays an ordinary statement in the while body.
        XCTAssertTrue(document.lines(sourcedAt: 0x1000_33010).contains { $0.text.contains(" + 0x1; // unrelated step") && !$0.text.contains("w9_0") }, document.text)
    }

    func testBottomTestedBackEdgeStructuresAsDoWhile() throws {
        // A straight-line body falls through to a trailing compare+branch whose
        // taken target is the body top. There is no top guard, so it is a
        // bottom-tested loop rendered as do/while with the RAW (non-inverted)
        // back-edge condition.
        let rows = [
            InstructionRow(address: 0x1000_31000, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body1"),
            InstructionRow(address: 0x1000_31004, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body2"),
            InstructionRow(address: 0x1000_31008, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_3100c, bytes: "81 ff ff 54", mnemonic: "b.ne", operands: "0x100031000", hasBreakpoint: false, comment: "back-edge"),
            InstructionRow(address: 0x1000_31010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_do_loop", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _do_loop(int64_t arg0) {
                // entry 0x0000000100031000; no stack frame; calls none
                do {
                    __nop(); // body1
                    __nop(); // body2
                } while (arg0 != 0x0); // back-edge; conditional branch
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__branch"), document.text)
        let doLine = try XCTUnwrap(document.lines.first { $0.text == "    do {" })
        XCTAssertNil(doLine.source)
        let whileLine = try XCTUnwrap(document.lines(sourcedAt: 0x1000_3100c).single)
        XCTAssertTrue(whileLine.text.contains("} while (arg0 != 0x0)"), whileLine.text)
    }

    func testZeroCheckBottomTestedBackEdgeUsesRawTakenCondition() throws {
        // cbnz back-edge at the bottom repeats while the register is nonzero, so
        // the rendered condition is the raw truthiness test (arg0), confirming
        // the do/while polarity is NOT inverted like a top-guard while.
        let rows = [
            InstructionRow(address: 0x1000_34000, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_34004, bytes: "80 ff ff b5", mnemonic: "cbnz", operands: "x0, 0x100034000", hasBreakpoint: false, comment: "back-edge"),
            InstructionRow(address: 0x1000_34008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_do_zero", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _do_zero(int64_t arg0) {
                // entry 0x0000000100034000; no stack frame; calls none
                do {
                    __nop(); // body
                } while (arg0); // back-edge; conditional branch
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("!arg0"), document.text)
    }

    func testTwoCompareBranchesFoldIntoLogicalAnd() throws {
        // Two adjacent compare+branch guards both exit to the same join and the
        // fall-through after the second is the shared body. They fold into a
        // single short-circuit `if (a && b)`.
        let rows = [
            InstructionRow(address: 0x1000_32000, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_32004, bytes: "80 00 00 54", mnemonic: "b.eq", operands: "0x100032014", hasBreakpoint: false, comment: "first"),
            InstructionRow(address: 0x1000_32008, bytes: "3f 00 00 f1", mnemonic: "cmp", operands: "x1, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_3200c, bytes: "40 00 00 54", mnemonic: "b.eq", operands: "0x100032014", hasBreakpoint: false, comment: "second"),
            InstructionRow(address: 0x1000_32010, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_32014, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_and_fold", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _and_fold(int64_t arg0, int64_t arg1) {
                // entry 0x0000000100032000; no stack frame; calls none
                if (arg0 != 0x0 && arg1 != 0x0) { // first; conditional branch
                    __nop(); // body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("__compare"), document.text)
        XCTAssertEqual(document.text.components(separatedBy: "if (").count - 1, 1)
        XCTAssertTrue(document.text.contains("&&"), document.text)
    }

    func testTwoCompareBranchesWithDifferentTargetsDoNotFold() throws {
        // The two compare+branch guards target different joins, so the
        // short-circuit fold bails and the leading guard renders as an ordinary
        // single-condition if; no `&&` fold is produced.
        let rows = [
            InstructionRow(address: 0x1000_35000, bytes: "1f 00 00 f1", mnemonic: "cmp", operands: "x0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_35004, bytes: "60 00 00 54", mnemonic: "b.eq", operands: "0x10003500c", hasBreakpoint: false, comment: "first"),
            InstructionRow(address: 0x1000_35008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_3500c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_no_fold", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("&&"), document.text)
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertTrue(document.text.contains("if (arg0 != 0x0) {"), document.text)
    }

    func testLongerClosedIfBodyStructuresUnderRaisedDistanceCap() throws {
        // A zero-check guard skips a six-instruction straight-line body (branch
        // distance 7, beyond the old cap of 4). The closed-region check accepts
        // it, so it structures into a single if with all six body statements at
        // depth one and no goto, demonstrating the raised distance bound.
        let rows = [
            InstructionRow(address: 0x1000_36000, bytes: "c0 00 00 b4", mnemonic: "cbz", operands: "x0, 0x10003601c", hasBreakpoint: false, comment: "guard"),
            InstructionRow(address: 0x1000_36004, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "b0"),
            InstructionRow(address: 0x1000_36008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "b1"),
            InstructionRow(address: 0x1000_3600c, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "b2"),
            InstructionRow(address: 0x1000_36010, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "b3"),
            InstructionRow(address: 0x1000_36014, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "b4"),
            InstructionRow(address: 0x1000_36018, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "b5"),
            InstructionRow(address: 0x1000_3601c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_long_body", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _long_body(int64_t arg0) {
                // entry 0x0000000100036000; no stack frame; calls none
                if (arg0) { // guard; conditional branch
                    __nop(); // b0
                    __nop(); // b1
                    __nop(); // b2
                    __nop(); // b3
                    __nop(); // b4
                    __nop(); // b5
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("goto"), document.text)
    }

    func testEscapingConditionalBranchInBodyKeepsOuterUnstructured() throws {
        // The outer guard's body contains an inner conditional branch whose
        // target lands at the outer join (idx 4), i.e. OUTSIDE the outer body
        // region. The closed-region escape check rejects the outer match, so we
        // conservatively fall back to the flat goto rendering rather than emit
        // unsound nesting.
        let rows = [
            InstructionRow(address: 0x1000_21000, bytes: "80 00 00 b4", mnemonic: "cbz", operands: "x0, 0x100021010", hasBreakpoint: false, comment: "outer guard"),
            InstructionRow(address: 0x1000_21004, bytes: "81 00 00 b4", mnemonic: "cbz", operands: "x1, 0x100021010", hasBreakpoint: false, comment: "escapes outward"),
            InstructionRow(address: 0x1000_21008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_2100c, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_21010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_escape_cond", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("if (arg0 && arg1)"), document.text)
        XCTAssertEqual(document.text.components(separatedBy: "if (").count - 1, 1)
        XCTAssertFalse(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("            __nop"), document.text)
    }

    func testEscapingUnconditionalBranchInBodyKeepsOuterUnstructured() throws {
        // Same conservatism guard, but the escaping transfer is an
        // unconditional branch intrinsic. Its target leaves the outer body, so
        // the closed-region check rejects the outer construct and the
        // unstructured branch intrinsic is preserved.
        let rows = [
            InstructionRow(address: 0x1000_22000, bytes: "80 00 00 b4", mnemonic: "cbz", operands: "x0, 0x100022010", hasBreakpoint: false, comment: "outer guard"),
            InstructionRow(address: 0x1000_22004, bytes: "03 00 00 14", mnemonic: "b", operands: "0x100022010", hasBreakpoint: false, comment: "escapes outward"),
            InstructionRow(address: 0x1000_22008, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "body"),
            InstructionRow(address: 0x1000_2200c, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_22010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_escape_branch", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x100022010)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        XCTAssertFalse(document.text.contains("            __nop"), document.text)
    }

    func testEarlyReturnInsideIfBodyIsLeftUnstructuredConservatively() throws {
        // The outer if body contains a nested early-return whose `return` the
        // per-index closed-region scan sees at a non-permitted index. Returns
        // are only allowed at the construct's own trailing slot, so the outer
        // match is rejected and we fall back to flat rendering. This locks the
        // conservative default: a body whose internal return cannot be
        // attributed must never structure into unsound nesting.
        let rows = [
            InstructionRow(address: 0x1000_23000, bytes: "80 00 00 b4", mnemonic: "cbz", operands: "x0, 0x100023014", hasBreakpoint: false, comment: "outer guard"),
            InstructionRow(address: 0x1000_23004, bytes: "61 00 00 54", mnemonic: "b.ne", operands: "0x100023010", hasBreakpoint: false, comment: "inner skip"),
            InstructionRow(address: 0x1000_23008, bytes: "00 00 80 52", mnemonic: "mov", operands: "w0, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_2300c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_23010, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_23014, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_early_return_in_if", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("goto"), document.text)
        XCTAssertFalse(document.text.contains("            return"), document.text)
    }

    // MARK: - neg

    func testNegateProducesUnaryNegationOfSource() throws {
        let rows = [
            InstructionRow(address: 0x1000_30000, bytes: "e0 03 01 cb", mnemonic: "neg", operands: "x0, x1", hasBreakpoint: false, comment: "negate arg"),
            InstructionRow(address: 0x1000_30004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_neg_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(op: "-", value: .argument(bindingID: .gpr(1)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = -(in_x1); // negate arg"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testNegateInPlaceReadsIncomingRegisterVersion() throws {
        let rows = [
            InstructionRow(address: 0x1000_30040, bytes: "e0 03 00 cb", mnemonic: "neg", operands: "x0, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30044, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_neg_in_place", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(op: "-", value: .argument(bindingID: .gpr(0)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = -(arg0);"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = -x0_1"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedNegateFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30080, bytes: "00 00 00 00", mnemonic: "neg", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30084, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_neg_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "neg", operands: "x0")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"neg\", \"x0\")"), document.text)
    }

    // MARK: - negs

    func testFlagSettingNegateProducesUnaryNegationValueFlow() throws {
        let rows = [
            InstructionRow(address: 0x1000_30100, bytes: "e0 03 01 eb", mnemonic: "negs", operands: "x0, x1", hasBreakpoint: false, comment: "negate and set flags"),
            InstructionRow(address: 0x1000_30104, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_negs_value", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(op: "-", value: .argument(bindingID: .gpr(1)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = -(in_x1); // negate and set flags"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testFlagSettingNegateFlagsOnlyFeedsStructuredBranch() throws {
        let rows = [
            InstructionRow(address: 0x1000_30140, bytes: "1f 00 00 eb", mnemonic: "negs", operands: "xzr, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30144, bytes: "4a 00 00 54", mnemonic: "b.ge", operands: "0x10003014c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30148, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "negative body"),
            InstructionRow(address: 0x1000_3014c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_negs_flags", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [.immediate(0), .argument(bindingID: .gpr(0))]
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: ">=",
                left: .immediate(0),
                right: .argument(bindingID: .gpr(0)),
                target: .immediate(0x1000_3014c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("0x0 < arg0"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedFlagSettingNegateFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30180, bytes: "00 00 00 00", mnemonic: "negs", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30184, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_negs_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "negs", operands: "x0")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"negs\", \"x0\")"), document.text)
    }

    // MARK: - mvn

    func testBitwiseNotProducesUnaryComplementOfSource() throws {
        let rows = [
            InstructionRow(address: 0x1000_30200, bytes: "e0 03 21 aa", mnemonic: "mvn", operands: "x0, x1", hasBreakpoint: false, comment: "complement"),
            InstructionRow(address: 0x1000_30204, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_mvn_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(op: "~", value: .argument(bindingID: .gpr(1)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = ~(in_x1); // complement"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testUnaryComplementParenthesizesBitwiseShiftOperand() throws {
        // `~(x >> s)` MUST render with parens — otherwise C precedence reads it as `(~x) >> s`.
        // A bare register/immediate operand of `~` stays unparenthesized. Enables the shifted
        // bic/orn/eon lift (`Xn & ~(Xm asr #s)`) to render faithfully.
        let function = MacIRFunction(
            name: "_not_shift",
            startAddress: 0x1000,
            instructions: [
                MacIRInstruction(
                    source: MacIRSourceSpan(address: 0x1000, byteText: "00 00 00 00", mnemonic: "synthetic", operands: "", comment: nil),
                    operation: .assign(
                        destination: .register(name: "x0", version: 1),
                        source: .unary(
                            op: "~",
                            value: .binaryExpression(
                                op: ">>",
                                left: .argument(bindingID: .gpr(1)),
                                right: .immediate(0x3f)
                            )
                        )
                    )
                )
            ]
        )
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("~(in_x1 >> 0x3f)"), text)
        XCTAssertFalse(text.contains("~in_x1 >> 0x3f"), text)
    }

    func testBitwiseNotInPlaceReadsIncomingRegisterVersion() throws {
        let rows = [
            InstructionRow(address: 0x1000_30240, bytes: "e0 03 20 aa", mnemonic: "mvn", operands: "x0, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30244, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_mvn_in_place", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = ~(arg0);"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = ~x0_1"), document.text)
    }

    func testShiftedBitwiseNotFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30280, bytes: "00 00 00 00", mnemonic: "mvn", operands: "x0, x1, lsl #2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30284, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_mvn_shifted", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "mvn", operands: "x0, x1, lsl #2")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"mvn\", \"x0, x1, lsl #2\")"), document.text)
    }

    // MARK: - bic / orn / eon

    func testBitClearProducesAndWithComplementedRight() throws {
        let rows = [
            InstructionRow(address: 0x1000_30300, bytes: "20 00 22 8a", mnemonic: "bic", operands: "x0, x1, x2", hasBreakpoint: false, comment: "clear bits"),
            InstructionRow(address: 0x1000_30304, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_bic_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "&",
                left: .argument(bindingID: .gpr(1)),
                right: .unary(op: "~", value: .argument(bindingID: .gpr(2)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = in_x1 & ~(in_x2); // clear bits"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testBitClearWithImmediateMaskInPlace() throws {
        let rows = [
            InstructionRow(address: 0x1000_30340, bytes: "00 0c 40 92", mnemonic: "bic", operands: "x0, x0, #0xf", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30344, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_bic_immediate", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "&",
                left: .argument(bindingID: .gpr(0)),
                right: .unary(op: "~", value: .immediate(0xf))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = arg0 & ~(0xf);"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
    }

    func testMalformedBitClearFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30380, bytes: "00 00 00 00", mnemonic: "bic", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30384, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_bic_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "bic", operands: "x0, x1")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"bic\", \"x0, x1\")"), document.text)
    }

    func testOrNotProducesOrWithComplementedRight() throws {
        let rows = [
            InstructionRow(address: 0x1000_30400, bytes: "20 00 22 aa", mnemonic: "orn", operands: "x0, x1, x2", hasBreakpoint: false, comment: "or not"),
            InstructionRow(address: 0x1000_30404, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_orn_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "|",
                left: .argument(bindingID: .gpr(1)),
                right: .unary(op: "~", value: .argument(bindingID: .gpr(2)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = in_x1 | ~(in_x2); // or not"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testOrNotInPlaceReadsIncomingRegisterVersion() throws {
        let rows = [
            InstructionRow(address: 0x1000_30440, bytes: "00 00 21 aa", mnemonic: "orn", operands: "x0, x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30444, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_orn_in_place", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = arg0 | ~(arg1);"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
    }

    func testShiftedOrNotLiftsToParenthesizedComplement() throws {
        // Round 4 (IR-4): shifted orn lifts to `Xn | ~(Xm SHIFT s)` (the printer paren fix keeps
        // the complement over the whole shift). Exact IR pinned by MacIRLiftingBreadthRound4Tests.
        let rows = [
            InstructionRow(address: 0x1000_30480, bytes: "00 00 00 00", mnemonic: "orn", operands: "x0, x1, x2, lsl #1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30484, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_orn_shifted", instructions: rows)
        if case .unknown = function.instructions[0].operation {
            XCTFail("shifted orn should lift, not fall back to __unknown")
        }

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("~((uint64_t)(in_x2) << 0x1)"), document.text)
        XCTAssertFalse(document.text.contains("__unknown(\"orn\""), document.text)
    }

    func testExclusiveOrNotProducesXorWithComplementedRight() throws {
        let rows = [
            InstructionRow(address: 0x1000_30500, bytes: "20 00 22 ca", mnemonic: "eon", operands: "x0, x1, x2", hasBreakpoint: false, comment: "xor not"),
            InstructionRow(address: 0x1000_30504, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_eon_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "^",
                left: .argument(bindingID: .gpr(1)),
                right: .unary(op: "~", value: .argument(bindingID: .gpr(2)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = in_x1 ^ ~(in_x2); // xor not"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testExclusiveOrNotWithImmediate() throws {
        let rows = [
            InstructionRow(address: 0x1000_30540, bytes: "20 00 00 d2", mnemonic: "eon", operands: "x0, x1, #0x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30544, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_eon_immediate", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "^",
                left: .argument(bindingID: .gpr(1)),
                right: .unary(op: "~", value: .immediate(0))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = in_x1 ^ ~(0x0);"), document.text)
    }

    func testMalformedExclusiveOrNotFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30580, bytes: "00 00 00 00", mnemonic: "eon", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30584, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_eon_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "eon", operands: "x0")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"eon\", \"x0\")"), document.text)
    }

    // MARK: - sdiv / udiv

    func testSignedDivideProducesFaithfulDivision() throws {
        let rows = [
            InstructionRow(address: 0x1000_30600, bytes: "00 0c c1 9a", mnemonic: "sdiv", operands: "x0, x0, x1", hasBreakpoint: false, comment: "divide"),
            InstructionRow(address: 0x1000_30604, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sdiv_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: .register(name: "x0", version: 1), name: "a64_sdiv64", arguments: [.argument(bindingID: .gpr(0)), .argument(bindingID: .gpr(1))])
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = __a64_sdiv64(arg0, arg1); // divide"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = x0_1"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testSignedDivideToScratchRegisterRenamesTemporary() throws {
        let rows = [
            InstructionRow(address: 0x1000_30640, bytes: "08 0c c1 9a", mnemonic: "sdiv", operands: "x8, x0, x1", hasBreakpoint: false, comment: "quotient"),
            InstructionRow(address: 0x1000_30644, bytes: "e0 03 08 aa", mnemonic: "mov", operands: "x0, x8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30648, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sdiv_scratch", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("tmp0 = __a64_sdiv64(arg0, arg1);"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedSignedDivideFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30680, bytes: "00 00 00 00", mnemonic: "sdiv", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30684, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sdiv_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "sdiv", operands: "x0, x1")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"sdiv\", \"x0, x1\")"), document.text)
    }

    func testUnsignedDivideProducesFaithfulDivision() throws {
        let rows = [
            InstructionRow(address: 0x1000_30700, bytes: "20 08 c2 9a", mnemonic: "udiv", operands: "x0, x1, x2", hasBreakpoint: false, comment: "udiv"),
            InstructionRow(address: 0x1000_30704, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_udiv_basic", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: .register(name: "x0", version: 1), name: "a64_udiv64", arguments: [.argument(bindingID: .gpr(1)), .argument(bindingID: .gpr(2))])
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = __a64_udiv64(in_x1, in_x2); // udiv"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testSignedAndUnsignedDivideRenderDistinctHelpers() throws {
        let signedRows = [
            InstructionRow(address: 0x1000_30740, bytes: "20 0c c2 9a", mnemonic: "sdiv", operands: "x0, x1, x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30744, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let unsignedRows = [
            InstructionRow(address: 0x1000_30740, bytes: "20 08 c2 9a", mnemonic: "udiv", operands: "x0, x1, x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30744, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let signedFunction = MacIRBuilder().buildFunction(name: "_div_signedness", instructions: signedRows)
        let unsignedFunction = MacIRBuilder().buildFunction(name: "_div_signedness", instructions: unsignedRows)
        let signedDocument = PseudocodePrinter().print(function: signedFunction)
        let unsignedDocument = PseudocodePrinter().print(function: unsignedFunction)
        XCTAssertNotEqual(signedDocument.text, unsignedDocument.text)
        XCTAssertTrue(signedDocument.text.contains("x0_1 = __a64_sdiv64(in_x1, in_x2);"), signedDocument.text)
    }

    func testMalformedUnsignedDivideFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30780, bytes: "00 00 00 00", mnemonic: "udiv", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30784, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_udiv_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "udiv", operands: "x0")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"udiv\", \"x0\")"), document.text)
    }

    // MARK: - movn

    func testMoveNotZeroFoldsToNegativeOneConstant() throws {
        let rows = [
            InstructionRow(address: 0x1000_30800, bytes: "00 00 80 92", mnemonic: "movn", operands: "x0, #0", hasBreakpoint: false, comment: "all ones"),
            InstructionRow(address: 0x1000_30804, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_movn_zero", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(destination: .register(name: "x0", version: 1), source: .immediate(-1))
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = -0x1; // all ones"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMoveNotImmediateFoldsToComplementConstant() throws {
        let rows = [
            InstructionRow(address: 0x1000_30840, bytes: "40 01 80 92", mnemonic: "movn", operands: "x0, #0xa", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30844, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_movn_immediate", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(destination: .register(name: "x0", version: 1), source: .immediate(-11))
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = -0xb;"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testShiftedMoveNotFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30880, bytes: "20 00 a0 92", mnemonic: "movn", operands: "x0, #0x1, lsl #16", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30884, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_movn_shifted", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "movn", operands: "x0, #0x1, lsl #16")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"movn\", \"x0, #0x1, lsl #16\")"), document.text)
    }

    func testMoveNotNonImmediateFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_308c0, bytes: "00 00 00 00", mnemonic: "movn", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_308c4, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_movn_register", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(destination: .register(name: "x0", version: 1), mnemonic: "movn", operands: "x0, x1")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"movn\", \"x0, x1\")"), document.text)
    }

    // MARK: - cmn

    func testCompareNegativeUnsignedCarryAtZeroBoundary() throws {
        // CMN x21, x27 followed by B.LO at 0x46d30/0x46d34: 0 + 0 has C=0.
        let rows = [
            InstructionRow(address: 0x46d30, bytes: "", mnemonic: "cmn", operands: "x21, x27", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x46d34, bytes: "", mnemonic: "b.lo", operands: "0x46d50", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x46d38, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x46d50, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        // Unstructured output keeps the branch's own predicate; structuring may print its negation.
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let document = PseudocodePrinter(options: options).print(function:
            MacIRBuilder().buildFunction(name: "_carry_boundary", instructions: rows))
        let branch = try XCTUnwrap(document.lines(sourcedAt: 0x46d34).single?.text)
        XCTAssertTrue(branch.contains("~") && branch.contains("<="), branch)
    }

    func testSignedBitfieldInsertRetainsHighSignBits() throws {
        // Signed helpers intentionally use unsigned storage to preserve sign bits without signed shifts.
        // SBFIZ x2, x9, #3, #32 appears at 0x1d42c, 0x1dbdc,
        // 0x1e38c, 0x30e94, 0x3157c, and 0x31c64.
        // SBFIZ x9, x25, #9, #32 appears at 0x47bec and 0x48844.
        // SBFIZ #1, #32 appears at 0x48628; SBFX #6, #26 at 0x4a854/0x4afcc.
        let cases: [(UInt64, String, String, String)] = [
            (0x1d42c, "sbfiz", "x2, x9, #3, #32", "mscope_sbfiz_bits_u64(tmp0, 3, 32)"),
            (0x1dbdc, "sbfiz", "x2, x9, #3, #32", "mscope_sbfiz_bits_u64(tmp0, 3, 32)"),
            (0x1e38c, "sbfiz", "x2, x9, #3, #32", "mscope_sbfiz_bits_u64(tmp0, 3, 32)"),
            (0x30e94, "sbfiz", "x2, x9, #3, #32", "mscope_sbfiz_bits_u64(tmp0, 3, 32)"),
            (0x3157c, "sbfiz", "x2, x9, #3, #32", "mscope_sbfiz_bits_u64(tmp0, 3, 32)"),
            (0x31c64, "sbfiz", "x2, x9, #3, #32", "mscope_sbfiz_bits_u64(tmp0, 3, 32)"),
            (0x47bec, "sbfiz", "x9, x25, #9, #32", "mscope_sbfiz_bits_u64(x25_1, 9, 32)"),
            (0x48628, "sbfiz", "x3, x11, #1, #32", "mscope_sbfiz_bits_u64(tmp0, 1, 32)"),
            (0x48844, "sbfiz", "x9, x25, #9, #32", "mscope_sbfiz_bits_u64(x25_1, 9, 32)"),
            (0x4a854, "sbfx", "x15, x15, #6, #26", "mscope_sbfx_bits_u64(tmp0, 6, 26)"),
            (0x4afcc, "sbfx", "x10, x8, #6, #26", "mscope_sbfx_bits_u64(tmp0, 6, 26)")
        ]
        for (address, mnemonic, operands, expectedCall) in cases {
            let source = operands.split(separator: ",")[1].trimmingCharacters(in: .whitespaces)
            let rows = [
                InstructionRow(address: address - 4, bytes: "", mnemonic: "mov", operands: "\(source), x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil),
                InstructionRow(address: address + 4, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
            ]
            let document = PseudocodePrinter().print(function:
                MacIRBuilder(ssaEnabled: false).buildFunction(name: "_signed_field", instructions: rows))
            let rendered = try XCTUnwrap(document.lines(sourcedAt: address).single?.text)
            print("0x\(String(address, radix: 16)): \(rendered)")
            XCTAssertTrue(rendered.contains(expectedCall), "0x\(String(address, radix: 16)): \(rendered)")
            XCTAssertFalse(rendered.contains("<<") || rendered.contains(">>"), "0x\(String(address, radix: 16)): \(rendered)")
        }
        for (address, mnemonic, operands, _) in cases where address == 0x1d42c || address == 0x4a854 {
            let rows = [
                InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil),
                InstructionRow(address: address + 4, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
            ]
            let document = PseudocodePrinter().print(function:
                MacIRBuilder(ssaEnabled: false).buildFunction(name: "_unowned_signed_field", instructions: rows))
            let rendered = try XCTUnwrap(document.lines(sourcedAt: address).single?.text)
            XCTAssertTrue(rendered.contains("__unknown("), "0x\(String(address, radix: 16)): \(rendered)")
            XCTAssertFalse(rendered.contains("<<") || rendered.contains(">>"), "0x\(String(address, radix: 16)): \(rendered)")
        }
    }

    func testCompareNegativeStandaloneSeedsNegatedComparison() throws {
        let rows = [
            InstructionRow(address: 0x1000_30900, bytes: "1f 00 01 ab", mnemonic: "cmn", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30904, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_cmn_standalone", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [
                    .argument(bindingID: .gpr(0)),
                    .unary(op: "(uint64_t)", value: .binaryExpression(op: "-",
                        left: .unary(op: "(uint64_t)", value: .immediate(0)),
                        right: .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1)))))
                ]
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.lines(sourcedAt: 0x1000_30900).single?.text,
            "    __compare(arg0, (uint64_t)((uint64_t)(0x0) - (uint64_t)(arg1))); // sets condition flags"
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testCompareNegativeImmediateFeedsStructuredBranch() throws {
        let rows = [
            InstructionRow(address: 0x1000_30940, bytes: "1f 04 00 b1", mnemonic: "cmn", operands: "x0, #1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30944, bytes: "4a 00 00 54", mnemonic: "b.ge", operands: "0x10003094c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30948, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: "less body"),
            InstructionRow(address: 0x1000_3094c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_cmn_immediate", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [.argument(bindingID: .gpr(0)), .immediate(-1)]
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: ">=",
                left: .argument(bindingID: .gpr(0)),
                right: .immediate(-1),
                target: .immediate(0x1000_3094c)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("arg0 < -0x1"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedCompareNegativeFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_30980, bytes: "00 00 00 00", mnemonic: "cmn", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_30984, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_cmn_malformed", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation.withoutUnknownInputs,
            .unknown(mnemonic: "cmn", operands: "x0")
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"cmn\", \"x0\")"), document.text)
    }

    // MARK: - Wave 3: blr (indirect call)

    func testIndirectCallThroughRegisterRendersAsPointerCall() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d000, bytes: "00 00 80 d2", mnemonic: "mov", operands: "x0, #0x1", hasBreakpoint: false, comment: "first arg"),
            InstructionRow(address: 0x1000_0d004, bytes: "00 01 3f d6", mnemonic: "blr", operands: "x8", hasBreakpoint: false, comment: "indirect dispatch"),
            InstructionRow(address: 0x1000_0d008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_indirect_call", instructions: rows)
        XCTAssertEqual(
            function.instructions[1].operation,
            .call(
                frame: try unknownIndirectCallFrame(
                    targetRegister: 8,
                    targetValue: .register(name: "x8", version: 0),
                    gprValues: [0: .register(name: "x0", version: 1)]
                ),
                result: .register(name: "x0", version: 2)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _indirect_call(void) {
                // entry 0x000000010000d000; no stack frame; calls (*x8)
                x0_1 = 0x1; // first arg
                x0_2 = (*x8)(x0_1); // indirect dispatch; call
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.callTargets, ["(*x8)"])
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedIndirectCallFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d100, bytes: "00 00 00 00", mnemonic: "blr", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d104, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_blr_malformed", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(mnemonic: "blr", operands: ""))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"blr\", \"\")"), document.text)
    }

    // MARK: - Wave 3: br (indirect branch)

    func testIndirectBranchRendersAsOpaqueComputedBranch() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d200, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]

        let function = MacIRBuilder().buildFunction(name: "_tail_dispatch", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: nil, name: "branch_register", arguments: [.register(name: "x8", version: 0)])
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            SSAPropertyAssertions.enabled
                ? SSARenderExpectation.withoutRefusalAnnotations(document, function: function, expected: [(.unresolvedIndirectBranch, .row(0x1000_0d200))])
                : document.text,
            """
            int64_t _tail_dispatch(void) {
                // entry 0x000000010000d200; no stack frame; calls none
                __branch_register(x8_0); // jump table dispatch; indirect branch
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
        XCTAssertFalse(document.text.contains("goto"), document.text)
    }

    func testMalformedIndirectBranchFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0d300, bytes: "00 00 00 00", mnemonic: "br", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_br_malformed", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(mnemonic: "br", operands: ""))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"br\", \"\")"), document.text)
    }

    // MARK: - Wave 3: adds (flag-setting add)

    func testFlagSettingAddProducesSumAndSeedsComparison() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e000, bytes: "20 00 02 ab", mnemonic: "adds", operands: "x0, x1, x2", hasBreakpoint: false, comment: "sum with flags"),
            InstructionRow(address: 0x1000_0e004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_adds_sum", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .binary(
                destination: .register(name: "x0", version: 1),
                op: "+",
                left: .argument(bindingID: .gpr(1)),
                right: .argument(bindingID: .gpr(2))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _adds_sum(/* ABI inputs: x1:int64_t in_x1, x2:int64_t in_x2 */) {
                // entry 0x000000010000e000; no stack frame; calls none
                x0_1 = in_x1 + in_x2; // sum with flags
                return unresolved_return_contract; // return
            }
            """
        )
    }

    func testAddsToZeroRegisterSeedsConditionalBranch() throws {
        // The b.eq targets an address outside this row set, so no structured-if
        // matcher fires and the seeded comparison renders as a bare guard.
        let rows = [
            InstructionRow(address: 0x1000_0e100, bytes: "1f 00 01 ab", mnemonic: "adds", operands: "xzr, x0, x1", hasBreakpoint: false, comment: "flags only"),
            InstructionRow(address: 0x1000_0e104, bytes: "00 00 00 54", mnemonic: "b.eq", operands: "0x100099999", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e108, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_adds_flags", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [
                    .argument(bindingID: .gpr(0)),
                    .unary(op: "-", value: .argument(bindingID: .gpr(1)))
                ]
            )
        )
        XCTAssertEqual(
            function.instructions[1].operation,
            .conditionalBranch(
                condition: "==",
                left: .argument(bindingID: .gpr(0)),
                right: .unary(op: "-", value: .argument(bindingID: .gpr(1))),
                target: .immediate(0x10009_9999)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        // adds xzr, x0, x1 sets flags for x0 + x1, i.e. it compares x0 against
        // -x1 (the cmn alias), so the seeded guard renders with the negated operand.
        XCTAssertTrue(document.text.contains("if (arg0 == -(arg1)"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedAddsFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e200, bytes: "00 00 00 00", mnemonic: "adds", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e204, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_adds_malformed", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(destination: .register(name: "x0", version: 1), mnemonic: "adds", operands: "x0, x1"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"adds\", \"x0, x1\")"), document.text)
    }

    // MARK: - Wave 3: adc / sbc (carry arithmetic -> __unknown)

    func testAddWithCarryFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e300, bytes: "20 00 02 9a", mnemonic: "adc", operands: "x0, x1, x2", hasBreakpoint: false, comment: "carry add"),
            InstructionRow(address: 0x1000_0e304, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_adc_carry", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(destination: .register(name: "x0", version: 1), mnemonic: "adc", operands: "x0, x1, x2"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            SSAPropertyAssertions.enabled
                ? SSARenderExpectation.withoutRefusalAnnotations(document, function: function, expected: [(.unknownEffects, .row(0x1000_0e300))])
                : document.text,
            """
            int64_t _adc_carry(void) {
                // entry 0x000000010000e300; no stack frame; calls none
                x0_1 = __unknown("adc", "x0, x1, x2"); // carry add
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertTrue(document.text.contains("__unknown(\"adc\", \"x0, x1, x2\")"), document.text)
    }

    func testSubtractWithCarryFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e380, bytes: "20 00 02 da", mnemonic: "sbc", operands: "x0, x1, x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e384, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sbc_borrow", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(destination: .register(name: "x0", version: 1), mnemonic: "sbc", operands: "x0, x1, x2"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"sbc\", \"x0, x1, x2\")"), document.text)
    }

    // MARK: - Wave 3: ccmp / ccmn (IR-7: conditional compare -> flag-effect intrinsic)

    func testConditionalCompareRendersFlagEffectIntrinsic() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e400, bytes: "20 00 41 fa", mnemonic: "ccmp", operands: "x1, x1, #0x0, ne", hasBreakpoint: false, comment: "chained condition"),
            InstructionRow(address: 0x1000_0e404, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        // IR-7: ccmp writes no GPR, so it renders a faithful flag-effect intrinsic (the `cmp`
        // precedent, which emits `__compare(...)`), not an opaque __unknown.
        let function = MacIRBuilder().buildFunction(name: "_ccmp_chain", instructions: rows)
        guard case let .intrinsic(destination, name, arguments) = function.instructions[0].operation else {
            return XCTFail("expected intrinsic, got \(function.instructions[0].operation)")
        }
        XCTAssertNil(destination)
        XCTAssertEqual(name, "conditional_compare_ne")
        XCTAssertEqual(arguments.count, 3)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__conditional_compare_ne("), document.text)
        XCTAssertFalse(document.text.contains("__unknown(\"ccmp\""), document.text)
    }

    func testConditionalCompareSeedsFaithfulCompoundBranch() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e500, bytes: "1f 00 01 eb", mnemonic: "cmp", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e504, bytes: "40 00 43 fa", mnemonic: "ccmp", operands: "x2, x3, #0x0, eq", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e508, bytes: "00 00 00 54", mnemonic: "b.eq", operands: "0x10000e510", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e50c, bytes: "00 00 80 d2", mnemonic: "mov", operands: "x0, #0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e510, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ccmp_preserve", instructions: rows)
        // IR-7 Part 1 changes ONLY the ccmp line's own render. The compound `b.cond` fusion
        // below (Part 1's most dangerous claim) must be byte-for-byte unchanged.
        if case let .intrinsic(_, name, _) = function.instructions[1].operation {
            XCTAssertEqual(name, "conditional_compare_eq")
        } else {
            XCTFail("expected conditional_compare intrinsic, got \(function.instructions[1].operation)")
        }
        XCTAssertEqual(
            function.instructions[2].operation,
            .conditionalBranch(
                condition: "!=",
                left: .binaryExpression(
                    op: "&&",
                    left: .binaryExpression(
                        op: "==",
                        left: .argument(bindingID: .gpr(0)),
                        right: .argument(bindingID: .gpr(1))
                    ),
                    right: .binaryExpression(
                        op: "==",
                        left: .register(name: "x2", version: 0),
                        right: .register(name: "x3", version: 0)
                    )
                ),
                right: .immediate(0),
                target: .immediate(0x1000_0e510)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertNil(document.structureFallback)
        XCTAssertFalse(document.text.contains("__unknown(\"ccmp\""), document.text)
        XCTAssertTrue(document.text.contains("if ((arg0 != arg1) || (x2_0 != x3_0))"), document.text)
    }

    func testConditionalCompareNegativeVariantRendersNegatedIntrinsic() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e600, bytes: "00 08 41 ba", mnemonic: "ccmn", operands: "x0, #0x1, #0x4, lt", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e604, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        // IR-7: `ccmn Rn, #imm` compares Rn against the NEGATED operand (the 2-op `cmn`
        // convention). Pin the negation — getting it backwards is a silent wrong-value bug.
        let function = MacIRBuilder().buildFunction(name: "_ccmn_chain", instructions: rows)
        guard case let .intrinsic(_, name, arguments) = function.instructions[0].operation else {
            return XCTFail("expected intrinsic, got \(function.instructions[0].operation)")
        }
        XCTAssertEqual(name, "conditional_compare_lt")
        XCTAssertEqual(arguments[1], .immediate(-1), "ccmn must negate its second operand")

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__conditional_compare_lt("), document.text)
        XCTAssertFalse(document.text.contains("__unknown(\"ccmn\""), document.text)
    }

    // MARK: - Wave 3: sign/zero extends

    func testSignExtendByteRendersAsCast() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f000, bytes: "20 1c 00 13", mnemonic: "sxtb", operands: "x0, w1", hasBreakpoint: false, comment: "narrow to signed byte"),
            InstructionRow(address: 0x1000_0f004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sxtb_cast", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(op: "(int8_t)", value: .argument(bindingID: .gpr(1)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _sxtb_cast(/* ABI inputs: w1:int32_t in_w1 */) {
                // entry 0x000000010000f000; no stack frame; calls none
                x0_1 = (int8_t)(in_w1); // narrow to signed byte
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testUnsignedExtendHalfwordRendersAsCast() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f100, bytes: "00 3c 00 53", mnemonic: "uxth", operands: "w0, w1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f104, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_uxth_cast", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "w0", version: 1),
                source: .unary(op: "(uint16_t)", value: .argument(bindingID: .gpr(1)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("w0_1 = (uint16_t)(in_w1);"), document.text)
    }

    func testSignExtendWordReadsIncomingVersion() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f200, bytes: "00 7c 40 93", mnemonic: "sxtw", operands: "x0, w0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f204, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sxtw_inplace", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .assign(
                destination: .register(name: "x0", version: 1),
                source: .unary(op: "(int32_t)", value: .argument(bindingID: .gpr(0)))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = (int32_t)(arg0);"), document.text)
        XCTAssertFalse(document.text.contains("x0_1 = (int32_t)x0_1"), document.text)
    }

    func testMalformedSignExtendFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f300, bytes: "00 00 00 00", mnemonic: "sxtb", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f304, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sxtb_malformed", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(destination: .register(name: "x0", version: 1), mnemonic: "sxtb", operands: "x0"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"sxtb\", \"x0\")"), document.text)
    }

    // MARK: - Wave 3: sized loads

    func testByteLoadFromPointerRendersAsDereference() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f400, bytes: "00 00 40 39", mnemonic: "ldrb", operands: "w0, [x1]", hasBreakpoint: false, comment: "load byte"),
            InstructionRow(address: 0x1000_0f404, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrb_load", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .load(
                destination: .register(name: "w0", version: 1),
                address: .argument(bindingID: .gpr(1))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _ldrb_load(/* ABI inputs: x1:int64_t in_x1 */) {
                // entry 0x000000010000f400; no stack frame; calls none
                w0_1 = *(uint8_t *)(in_x1); // load byte
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testHalfwordStackLoadRecoversNarrowLocal() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f500, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f504, bytes: "e0 00 80 52", mnemonic: "mov", operands: "w0, #0x7", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f508, bytes: "e0 1b 00 79", mnemonic: "strh", operands: "w0, [sp, #0xe]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f50c, bytes: "e1 1b 40 79", mnemonic: "ldrh", operands: "w1, [sp, #0xe]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f510, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f514, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrh_stack", instructions: rows)
        // The strh spills a 2-byte slot, so the recovered local is byte-width 2.
        // Its declared type follows the source w-register (int32_t) per the
        // existing register type-hint policy.
        XCTAssertEqual(function.localVariables.first?.byteWidth, 2)
        XCTAssertEqual(function.localVariables.first?.type, "int32_t")

        let document = PseudocodePrinter().print(function: function)
        let localName = try XCTUnwrap(function.localVariables.first?.name)
        XCTAssertTrue(document.text.contains("w1_1 = *(uint16_t *)&(\(localName));"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testSignedWordLoadRendersLikeLoad() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f600, bytes: "00 80 80 b9", mnemonic: "ldrsw", operands: "x0, [x1]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f604, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrsw_load", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .load(
                destination: .register(name: "x0", version: 1),
                address: .argument(bindingID: .gpr(1))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = *(int32_t *)(in_x1);"), document.text)
    }

    func testMalformedSizedLoadFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f700, bytes: "00 00 00 00", mnemonic: "ldrb", operands: "w0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f704, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrb_malformed", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(destination: .register(name: "w0", version: 1), mnemonic: "ldrb", operands: "w0"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"ldrb\", \"w0\")"), document.text)
    }

    // MARK: - Wave 3: sized stores

    func testByteStoreToPointerRendersAsDereferenceAssignment() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f800, bytes: "20 00 00 39", mnemonic: "strb", operands: "w0, [x1]", hasBreakpoint: false, comment: "store byte"),
            InstructionRow(address: 0x1000_0f804, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_strb_store", instructions: rows)
        XCTAssertEqual(
            function.instructions[0].operation,
            .store(
                source: .argument(bindingID: .gpr(0)),
                address: .argument(bindingID: .gpr(1))
            )
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(
            document.text,
            """
            int64_t _strb_store(int32_t arg0, int64_t arg1) {
                // entry 0x000000010000f800; no stack frame; calls none
                *(uint8_t *)(arg1) = arg0; // store byte
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testHalfwordStackStoreRecoversNarrowLocal() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f900, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f904, bytes: "a0 00 80 52", mnemonic: "mov", operands: "w0, #0x5", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f908, bytes: "e0 1b 00 79", mnemonic: "strh", operands: "w0, [sp, #0xe]", hasBreakpoint: false, comment: "spill halfword"),
            InstructionRow(address: 0x1000_0f90c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f910, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_strh_stack", instructions: rows)
        // The strh spills a 2-byte slot; the recovered local is byte-width 2 and
        // declared int32_t following the source w-register type-hint policy.
        XCTAssertEqual(function.localVariables.first?.byteWidth, 2)
        XCTAssertEqual(function.localVariables.first?.type, "int32_t")

        let document = PseudocodePrinter().print(function: function)
        let localName = try XCTUnwrap(function.localVariables.first?.name)
        XCTAssertTrue(document.text.contains("    int32_t \(localName);"), document.text)
        XCTAssertTrue(document.text.contains("*(uint16_t *)&(\(localName)) = w0_1; // spill halfword; stack store"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedSizedStoreFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0fa00, bytes: "00 00 00 00", mnemonic: "strb", operands: "w0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0fa04, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_strb_malformed", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(mnemonic: "strb", operands: "w0"))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__unknown(\"strb\", \"w0\")"), document.text)
    }

    // MARK: - Wave 4: sized signed/unsigned local typing

    func testSignedByteStackLoadRecoversSignedNarrowLocal() throws {
        // A ldrsb that creates the stack local (no prior store) sign-extends one
        // byte, so the recovered local is int8_t, not the default unsigned byte.
        let rows = [
            InstructionRow(address: 0x1000_10000, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10004, bytes: "e0 1f 80 39", mnemonic: "ldrsb", operands: "w0, [sp, #0x7]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10008, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_1000c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrsb_stack", instructions: rows)
        XCTAssertEqual(function.localVariables.first?.byteWidth, 1)
        XCTAssertEqual(function.localVariables.first?.type, "int8_t")

        let document = PseudocodePrinter().print(function: function)
        let localName = try XCTUnwrap(function.localVariables.first?.name)
        XCTAssertTrue(document.text.contains("    int8_t \(localName);"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testSignedHalfwordStackLoadRecoversSignedNarrowLocal() throws {
        // A ldrsh that creates the stack local sign-extends two bytes, so the
        // recovered local is int16_t.
        let rows = [
            InstructionRow(address: 0x1000_10100, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10104, bytes: "e0 1b 80 79", mnemonic: "ldrsh", operands: "w0, [sp, #0xe]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10108, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_1010c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrsh_stack", instructions: rows)
        XCTAssertEqual(function.localVariables.first?.byteWidth, 2)
        XCTAssertEqual(function.localVariables.first?.type, "int16_t")

        let document = PseudocodePrinter().print(function: function)
        let localName = try XCTUnwrap(function.localVariables.first?.name)
        XCTAssertTrue(document.text.contains("    int16_t \(localName);"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testUnsignedByteStackLoadRecoversUnsignedNarrowLocal() throws {
        // A ldrb that creates the stack local zero-extends one byte, so the
        // recovered local stays uint8_t (the unsigned counterpart to ldrsb).
        let rows = [
            InstructionRow(address: 0x1000_10200, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10204, bytes: "e0 1f 40 39", mnemonic: "ldrb", operands: "w0, [sp, #0x7]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10208, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_1020c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrb_stack", instructions: rows)
        XCTAssertEqual(function.localVariables.first?.byteWidth, 1)
        XCTAssertEqual(function.localVariables.first?.type, "uint8_t")

        let document = PseudocodePrinter().print(function: function)
        let localName = try XCTUnwrap(function.localVariables.first?.name)
        XCTAssertTrue(document.text.contains("    uint8_t \(localName);"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testSignedWordStackLoadRecoversInt32Local() throws {
        // A ldrsw that creates the stack local sign-extends four bytes, so the
        // recovered local is int32_t (signed), matching the register-width form.
        let rows = [
            InstructionRow(address: 0x1000_10300, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10304, bytes: "e0 13 80 b9", mnemonic: "ldrsw", operands: "x0, [sp, #0x10]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10308, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_1030c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ldrsw_stack", instructions: rows)
        XCTAssertEqual(function.localVariables.first?.byteWidth, 4)
        XCTAssertEqual(function.localVariables.first?.type, "int32_t")

        let document = PseudocodePrinter().print(function: function)
        let localName = try XCTUnwrap(function.localVariables.first?.name)
        XCTAssertTrue(document.text.contains("    int32_t \(localName);"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testRegisterSpilledHalfwordKeepsRegisterTypeOverSizedHint() throws {
        // Guard: a strh that spills a w-register, then a ldrh reload, keeps the
        // register-derived int32_t type. The sized-access element hint must only
        // fill in when there is no typed source value, so a spilled register
        // wins over the encoding width. (Mirrors the existing strh/ldrh tests;
        // added to lock the back-off path that the Wave 4 hint introduced.)
        let rows = [
            InstructionRow(address: 0x1000_10400, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10404, bytes: "e0 00 80 52", mnemonic: "mov", operands: "w0, #0x7", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10408, bytes: "e0 1b 00 79", mnemonic: "strh", operands: "w0, [sp, #0xe]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_1040c, bytes: "e1 1b 40 79", mnemonic: "ldrh", operands: "w1, [sp, #0xe]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10410, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_10414, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_strh_reload", instructions: rows)
        XCTAssertEqual(function.localVariables.first?.byteWidth, 2)
        XCTAssertEqual(function.localVariables.first?.type, "int32_t")
    }

    func testCountLeadingZerosAndBitByteReversalsRenderAsIntrinsics() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f000, bytes: "20 10 c0 da", mnemonic: "clz", operands: "x0, x1", hasBreakpoint: false, comment: "leading zeros"),
            InstructionRow(address: 0x1000_0f004, bytes: "20 00 c0 da", mnemonic: "rbit", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f008, bytes: "20 0c c0 da", mnemonic: "rev", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f00c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_bit_transforms", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("x0_1 = __clz(in_x1); // leading zeros"), document.text)
        XCTAssertTrue(document.text.contains("= __rbit(in_x1);"), document.text)
        XCTAssertTrue(document.text.contains("= __rev(in_x1);"), document.text)
        XCTAssertFalse(document.text.contains("__unknown"), document.text)
    }

    func testMalformedBitTransformFallsBackToUnknown() throws {
        let rows = [
            InstructionRow(address: 0x1000_0f100, bytes: "00 00 00 00", mnemonic: "clz", operands: "x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0f104, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_bad_clz", instructions: rows)
        XCTAssertEqual(function.instructions[0].operation.withoutUnknownInputs, .unknown(destination: .register(name: "x0", version: 1), mnemonic: "clz", operands: "x0"))
        XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains("__unknown(\"clz\", \"x0\")"))
    }

    // MARK: - Wave 5: call-signature DB expansion

    func testKnownMemmoveCallSignatureRenders() throws {
        let rows = [
            InstructionRow(address: 0x1000_50000, bytes: "00 00 00 94", mnemonic: "bl", operands: "_memmove", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let expectedSignature = MacIRCallSignature(
            target: "_memmove",
            returnType: "void *",
            parameters: [
                MacIRCallParameter(index: 0, register: "x0", type: "void *", name: "dst"),
                MacIRCallParameter(index: 1, register: "x1", type: "const void *", name: "src"),
                MacIRCallParameter(index: 2, register: "x2", type: "size_t", name: "count")
            ]
        )

        let function = MacIRBuilder().buildFunction(name: "_wrap_memmove", instructions: rows)
        XCTAssertEqual(function.callSignatures, [expectedSignature])
        XCTAssertEqual(function.callSignatures.first?.parameters.count, 3)
        XCTAssertEqual(function.callSignatures.first?.isVariadic, false)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("call; signature void * _memmove(void * dst, const void * src, size_t count)"), document.text)
    }

    func testKnownReallocCallSignatureReturnsVoidStar() throws {
        let rows = [
            InstructionRow(address: 0x1000_50020, bytes: "00 00 00 94", mnemonic: "bl", operands: "_realloc", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50024, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_wrap_realloc", instructions: rows)
        XCTAssertEqual(function.callSignatures.first?.returnType, "void *")
        XCTAssertEqual(function.callSignatures.first?.parameters.count, 2)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("call; signature void * _realloc(void * ptr, size_t size)"), document.text)
    }

    func testUnknownSimilarlyNamedTargetStillSweeps() throws {
        let rows = [
            InstructionRow(address: 0x1000_50040, bytes: "00 00 00 94", mnemonic: "bl", operands: "_memmove_custom", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50044, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_wrap_custom", instructions: rows)
        XCTAssertTrue(function.callSignatures.isEmpty)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("signature"), document.text)
        XCTAssertTrue(document.text.contains("_memmove_custom("), document.text)
    }

    func testKnownNSLogCallRendersVariadicSignature() throws {
        let rows = [
            InstructionRow(address: 0x1000_50060, bytes: "00 00 00 94", mnemonic: "bl", operands: "_NSLog", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50064, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_wrap_nslog", instructions: rows)
        XCTAssertEqual(function.callSignatures.first?.isVariadic, true)
        XCTAssertEqual(function.callSignatures.first?.returnType, "void")

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("call; signature void _NSLog(NSString * format, ...)"), document.text)
    }

    func testKnownSnprintfVariadicSignature() throws {
        let rows = [
            InstructionRow(address: 0x1000_50080, bytes: "00 00 00 94", mnemonic: "bl", operands: "_snprintf", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50084, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_wrap_snprintf", instructions: rows)
        XCTAssertEqual(function.callSignatures.first?.isVariadic, true)
        XCTAssertEqual(function.callSignatures.first?.parameters.count, 3)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("call; signature int32_t _snprintf(char * str, size_t size, const char * format, ...)"), document.text)
    }

    func testGenericVariadicTargetKeepsOnlyProvenFixedArgument() throws {
        let rows = [
            InstructionRow(address: 0x1000_500a0, bytes: "00 00 80 d2", mnemonic: "mov", operands: "x0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500a4, bytes: "21 00 80 d2", mnemonic: "mov", operands: "x1, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500a8, bytes: "42 00 80 d2", mnemonic: "mov", operands: "x2, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500ac, bytes: "63 00 80 d2", mnemonic: "mov", operands: "x3, #0x3", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500b0, bytes: "00 00 00 94", mnemonic: "bl", operands: "_NSLog", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500b4, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_log_several", instructions: rows)
        let frame = try firstCallFrame(in: function)
        XCTAssertEqual(frame.knownSignature?.target, "_NSLog")
        XCTAssertEqual(frame.knownSignature?.isVariadic, true)
        XCTAssertNil(frame.tailCountEvidence)
        XCTAssertEqual(frame.arguments.count, 1)
        XCTAssertEqual(
            frame.arguments.fixedArgument(at: 0),
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .fixed(sourcePosition: 0),
                value: .register(name: "x0", version: 1)
            )
        )
        XCTAssertFalse(frame.arguments.observationScope.observes(.gpr(index: 0, carrierWidth: 64)))
        XCTAssertFalse(frame.arguments.observationScope.observes(.gpr(index: 1, carrierWidth: 64)))

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_NSLog(x0_1)"), text)
        XCTAssertFalse(text.contains("_NSLog(x0_1, x1_1"), text)
    }

    func testKnownObjcReleaseVoidSignature() throws {
        let rows = [
            InstructionRow(address: 0x1000_500c0, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_release", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500c4, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_drop_object", instructions: rows)
        XCTAssertEqual(function.callSignatures.first?.returnType, "void")
        XCTAssertNil(function.returnValue)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("call; signature void _objc_release(id obj)"), document.text)
    }

    func testKnownObjcMsgSendSuperVariadicShape() throws {
        let rows = [
            InstructionRow(address: 0x1000_500e0, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSendSuper", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_500e4, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_call_super", instructions: rows)
        XCTAssertEqual(function.callSignatures.first?.isVariadic, true)

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("call; signature id _objc_msgSendSuper(struct objc_super * super, SEL selector, ...)"), document.text)
    }

    func testObjcMsgSendSelectorStaysGeneric() throws {
        let rows = [
            InstructionRow(address: 0x1000_50100, bytes: "00 00 00 90", mnemonic: "adrp", operands: "x1, _sel_doThing@PAGE", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50104, bytes: "21 00 00 91", mnemonic: "add", operands: "x1, x1, _sel_doThing@PAGEOFF", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50108, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_5010c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_send_message", instructions: rows)
        let document = PseudocodePrinter().print(function: function)
        // Conservative back-off: the selector argument is rendered generically,
        // never as a quoted selector string like "doThing".
        XCTAssertFalse(document.text.contains("\"doThing\""), document.text)
        XCTAssertFalse(document.text.contains("@selector"), document.text)
        XCTAssertTrue(document.text.contains("call; signature id _objc_msgSend(id receiver, SEL selector, ...)"), document.text)
    }

    func testNonContiguousArgumentRegistersRetainEvidenceButRenderOnlySafePrefix() throws {
        // Unknown-target evidence remains keyed to its physical registers. The
        // missing x1 stops ordinary rendering without deleting the x2 record.
        let rows = [
            InstructionRow(address: 0x1000_50120, bytes: "00 00 80 d2", mnemonic: "mov", operands: "x0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50124, bytes: "42 00 80 d2", mnemonic: "mov", operands: "x2, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_50128, bytes: "00 00 00 94", mnemonic: "bl", operands: "_gapped_target", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_5012c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_gap_caller", instructions: rows)
        let frame = try firstCallFrame(in: function)
        XCTAssertNil(frame.knownSignature)
        XCTAssertEqual(frame.arguments.count, 2)
        XCTAssertEqual(
            frame.arguments.argument(at: .gpr(index: 0)),
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .unknown,
                value: .register(name: "x0", version: 1)
            )
        )
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 1)))
        XCTAssertEqual(
            frame.arguments.argument(at: .gpr(index: 2)),
            MacIRCallArgument(
                location: .gpr(index: 2, carrierWidth: 64),
                role: .unknown,
                value: .register(name: "x2", version: 1)
            )
        )
        XCTAssertTrue(frame.arguments.observationScope.observes(.gpr(index: 1, carrierWidth: 64)))

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_gapped_target(x0_1)"), text)
        XCTAssertFalse(text.contains("_gapped_target(x0_1, x2_1)"), text)
    }

    // MARK: - Jump-table switch recovery (decompiler-side seam)

    func testJumpTableDispatchRecoversStructuredSwitch() throws {
        // cmp + b.hi default + adrp/add base + indexed load + add + br dispatch.
        let rows = [
            InstructionRow(address: 0x1000_0d100, bytes: "1f 09 00 71", mnemonic: "cmp", operands: "w0, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d104, bytes: "08 00 00 54", mnemonic: "b.hi", operands: "0x10000d300", hasBreakpoint: false, comment: "default"),
            InstructionRow(address: 0x1000_0d108, bytes: "08 00 00 90", mnemonic: "adrp", operands: "x8, _jt@PAGE", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d10c, bytes: "08 01 00 91", mnemonic: "add", operands: "x8, x8, _jt@PAGEOFF", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d110, bytes: "09 59 a0 b8", mnemonic: "ldrsw", operands: "x9, [x8, w0, lsl #2]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d114, bytes: "08 01 09 8b", mnemonic: "add", operands: "x8, x8, x9", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d118, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_switch3",
            jumpTables: [0x1000_0d118: [0x1000_0d210, 0x1000_0d220, 0x1000_0d230]],
            instructions: rows
        )

        XCTAssertEqual(
            function.instructions[6].operation,
            .switchDispatch(
                index: .argument(bindingID: .gpr(0)),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(0x1000_0d210)),
                    MacIRSwitchCase(value: 1, target: .immediate(0x1000_0d220)),
                    MacIRSwitchCase(value: 2, target: .immediate(0x1000_0d230))
                ],
                defaultTarget: .immediate(0x1000_0d300)
            )
        )

        let document = PseudocodePrinter().print(function: function)
        let text = document.text
        XCTAssertTrue(text.contains("    switch (arg0) { // jump table dispatch; jump table"))
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x10000d210, condition: "case 0x0:")
        GotoLabelWellFormednessTests.assertWellFormed(text)
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x10000d220, condition: "case 0x1:")
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x10000d230, condition: "case 0x2:")
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x10000d300, condition: "default:")
        XCTAssertFalse(text.contains("__branch_register"))
    }

    func testManualSwitchHintDrivesPseudocodeSwitchReconstruction() throws {
        // A `br` whose dispatch idiom the auto-resolver can't recover: the user's
        // manual switch hint resolves the table from hexBytes and feeds the same
        // recoverSwitchDispatches seam, so the pseudocode emits a structured switch.
        let brAddress = 0x1_0000_0000 as UInt64
        let rows = [
            InstructionRow(address: brAddress, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]
        // hexBytes anchored at brAddress: [br|pad][entry0=0x100000100][entry1=0x100000200].
        var hex: [UInt8] = [0x00, 0x01, 0x1f, 0xd6, 0, 0, 0, 0]
        hex += [0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00] // 0x100000100
        hex += [0x00, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00] // 0x100000200

        var snapshot = WorkspaceSnapshot(binaries: [], functions: [], instructions: rows, xrefs: [], hexBytes: Data(hex))
        snapshot.addressOverrides[.primary(brAddress)] = AddressOverride(
            switchHint: SwitchHintOverride(tableBase: 0x1_0000_0008, entryCount: 2, entryStride: 8, isRelativeToBase: false)
        )

        let resolved = snapshot.resolvedJumpTables(in: .primary)
        XCTAssertEqual(resolved[brAddress], [0x1_0000_0100, 0x1_0000_0200])

        let function = MacIRBuilder().buildFunction(name: "_dispatch", jumpTables: resolved, instructions: rows)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("switch ("))
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x100000100)
        GotoLabelWellFormednessTests.assertWellFormed(text)
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x100000200)
        XCTAssertFalse(text.contains("__branch_register"))
    }

    // MARK: - Data cross-reference resolver

    private func dxrefRow(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    func testDataXRefResolverRecoversStringReferenceViaAdrpAdd() {
        let rows = [
            dxrefRow(0x1000, "adrp", "x0, 0x4000"),
            dxrefRow(0x1004, "add", "x0, x0, #0x10")
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: []
        )
        XCTAssertEqual(refs, [.init(from: 0x1004, to: 0x4010, kind: "string")])
    }

    func testDataXRefResolverRecoversSelectorReferenceViaAdrpLdr() {
        let rows = [
            dxrefRow(0x1000, "adrp", "x8, 0x8000"),
            dxrefRow(0x1004, "ldr", "x1, [x8, #0x40]")
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [0x8040], dataRanges: []
        )
        XCTAssertEqual(refs, [.init(from: 0x1004, to: 0x8040, kind: "selref")])
    }

    func testDataXRefResolverRecoversDataReferenceInDataSection() {
        let rows = [
            dxrefRow(0x1000, "adrp", "x9, 0xC000"),
            dxrefRow(0x1004, "add", "x9, x9, #0x8")
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [],
            dataRanges: [.init(lowerBound: 0xC000, upperBound: 0xD000)]
        )
        XCTAssertEqual(refs, [.init(from: 0x1004, to: 0xC008, kind: "data")])
    }

    func testDataXRefResolverDropsEdgeWhenBaseRegisterIsClobbered() {
        // An intervening write to the page-base register invalidates it — the most
        // important correctness guard against phantom edges.
        let rows = [
            dxrefRow(0x1000, "adrp", "x0, 0x4000"),
            dxrefRow(0x1004, "mov", "x0, #0"),        // clobbers x0
            dxrefRow(0x1008, "add", "x0, x0, #0x10")  // x0 no longer a page base
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: []
        )
        XCTAssertTrue(refs.isEmpty)
    }

    func testDataXRefResolverCarriesBaseAcrossConditionalBranch() {
        // Tier 1.6 cross-boundary fix: a CONDITIONAL branch falls through to the next
        // linear instruction (a real successor) and writes no register, so the adrp page
        // base is still valid there and the split adrp…(cond branch)…add must RECOVER the
        // reference (previously this state was wiped at every CFG boundary, dropping it).
        // An UNCONDITIONAL `b` does NOT carry — its next linear row is not a successor —
        // see DataXRefCFGBoundaryTests' phantom guard.
        let rows = [
            dxrefRow(0x1000, "adrp", "x0, 0x4000"),
            dxrefRow(0x1004, "cbz", "x1, 0x2000"),    // conditional: fall-through carries the base
            dxrefRow(0x1008, "add", "x0, x0, #0x10")
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: []
        )
        XCTAssertEqual(refs.first?.to, 0x4010)
    }

    func testDataXRefResolverKeepsBaseAcrossInterveningStore() {
        // A store READS its first operand, so even `str x0, [...]` must not clobber
        // x0's tracked page base — otherwise the later add would lose the edge.
        let rows = [
            dxrefRow(0x1000, "adrp", "x0, 0x4000"),
            dxrefRow(0x1004, "str", "x0, [sp, #0x8]"),
            dxrefRow(0x1008, "add", "x0, x0, #0x10")
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: []
        )
        XCTAssertEqual(refs.first?.to, 0x4010)
    }

    func testDataXRefResolverIgnoresUnresolvableAndUntrackedReferences() {
        let rows = [
            dxrefRow(0x1000, "adrp", "x0, <address overflow>"), // unparseable -> no base
            dxrefRow(0x1004, "add", "x0, x0, #0x10"),           // x0 untracked -> no edge
            dxrefRow(0x1008, "add", "x1, x2, #0x4")             // neither tracked -> no edge
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x4010, 0x14], selectorSlots: [], dataRanges: []
        )
        XCTAssertTrue(refs.isEmpty)
    }

    func testDataXRefResolverClearsStateAcrossPointerAuthenticatedCall() {
        // arm64e PAC transfers (blraa/braa/retaa…) must be control-flow boundaries —
        // a page base must not leak across them into a phantom edge.
        for boundary in ["blraa x8, x16", "braa x8, x16", "retaa", "blrab x9, x10"] {
            let parts = boundary.split(separator: " ", maxSplits: 1)
            let rows = [
                dxrefRow(0x1000, "adrp", "x0, 0x4000"),
                dxrefRow(0x1004, String(parts[0]), parts.count > 1 ? String(parts[1]) : ""),
                dxrefRow(0x1008, "add", "x0, x0, #0x10")
            ]
            let refs = DataCrossReferenceResolver().resolve(
                instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: []
            )
            XCTAssertTrue(refs.isEmpty, "page base leaked across \(boundary)")
        }
    }

    func testDataXRefResolverClobbersBothPairLoadDestinations() {
        // ldp loads TWO registers; a stale base in the SECOND must not survive.
        let rows = [
            dxrefRow(0x1000, "adrp", "x2, 0x8000"),
            dxrefRow(0x1004, "ldp", "x0, x2, [x9]"),     // x2 is overwritten by the load
            dxrefRow(0x1008, "add", "x3, x2, #0x40")     // x2 no longer the page base
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x8040], selectorSlots: [], dataRanges: []
        )
        XCTAssertTrue(refs.isEmpty)
    }

    func testDataXRefResolverClobbersExclusiveStoreStatusRegister() {
        // `stxr Ws, Xt, [Xn]` WRITES Ws (operand 0); a stale base there must clear.
        let rows = [
            dxrefRow(0x1000, "adrp", "x0, 0x4000"),
            dxrefRow(0x1004, "stxr", "w0, x1, [x2]"),    // overwrites x0 with the status
            dxrefRow(0x1008, "add", "x0, x0, #0x10")
        ]
        let refs = DataCrossReferenceResolver().resolve(
            instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: []
        )
        XCTAssertTrue(refs.isEmpty)
    }

    func testJumpTableDispatchWithoutTableKeepsOpaqueBranch() throws {
        // Same dispatch block, but no table data supplied: the seam is inert and
        // the br stays an opaque __branch_register (existing behavior).
        let rows = [
            InstructionRow(address: 0x1000_0d400, bytes: "1f 09 00 71", mnemonic: "cmp", operands: "w0, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d404, bytes: "08 00 00 54", mnemonic: "b.hi", operands: "0x1000d600", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d408, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]

        let function = MacIRBuilder().buildFunction(name: "_switch_no_table", instructions: rows)
        XCTAssertEqual(
            function.instructions[2].operation,
            .intrinsic(destination: nil, name: "branch_register", arguments: [.register(name: "x8", version: 0)])
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("__branch_register(x8_0)"), document.text)
        XCTAssertFalse(document.text.contains("switch ("), document.text)
    }

    func testJumpTableDispatchWithEmptyTargetArrayKeepsOpaqueBranch() throws {
        // An empty target array for the br address is treated as "no table".
        let rows = [
            InstructionRow(address: 0x1000_0d700, bytes: "1f 09 00 71", mnemonic: "cmp", operands: "w0, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d704, bytes: "08 00 00 54", mnemonic: "b.hi", operands: "0x1000d800", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d708, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_switch_empty",
            jumpTables: [0x1000_0d708: []],
            instructions: rows
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .intrinsic(destination: nil, name: "branch_register", arguments: [.register(name: "x8", version: 0)])
        )
        XCTAssertFalse(PseudocodePrinter().print(function: function).text.contains("switch ("))
    }

    func testJumpTableDispatchWithBoundsTableMismatchKeepsOpaqueBranch() throws {
        // cmp bounds N=1 implies at most 2 in-range cases, but 3 targets are
        // supplied: the idiom and table disagree, so stay conservative.
        let rows = [
            InstructionRow(address: 0x1000_0d900, bytes: "1f 05 00 71", mnemonic: "cmp", operands: "w0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d904, bytes: "08 00 00 54", mnemonic: "b.hi", operands: "0x1000da00", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0d908, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_switch_mismatch",
            jumpTables: [0x1000_0d908: [0x1000_0db00, 0x1000_0db10, 0x1000_0db20]],
            instructions: rows
        )
        XCTAssertEqual(
            function.instructions[2].operation,
            .intrinsic(destination: nil, name: "branch_register", arguments: [.register(name: "x8", version: 0)])
        )
    }

    func testJumpTableDispatchWithWrongAddressKeyKeepsOpaqueBranch() throws {
        // The table is keyed at an address that is not the dispatching br, so the
        // exact-address keying misses and the br stays opaque.
        let rows = [
            InstructionRow(address: 0x1000_0dc00, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "jump table dispatch")
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_switch_wrong_key",
            jumpTables: [0x1000_0dc04: [0x1000_0dd00, 0x1000_0dd10]],
            instructions: rows
        )
        XCTAssertEqual(
            function.instructions[0].operation,
            .intrinsic(destination: nil, name: "branch_register", arguments: [.register(name: "x8", version: 0)])
        )
    }

    func testJumpTableDispatchWithoutSelectorProofKeepsEdgesButAbstainsFromSelector() throws {
        // No guard or indexed load precedes the br (for example a manual switch hint):
        // the supplied table still yields the case edges, but x8 holds the computed
        // TARGET, not the table index, so naming it as the selector would be wrong.
        let rows = [
            InstructionRow(address: 0x1000_0de00, bytes: "00 01 1f d6", mnemonic: "br", operands: "x8", hasBreakpoint: false, comment: "computed jump")
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_switch_no_bounds",
            jumpTables: [0x1000_0de00: [0x1000_0df00, 0x1000_0df10]],
            instructions: rows
        )

        XCTAssertEqual(
            function.instructions[0].operation,
            .switchDispatch(
                index: .unknown("unproven_switch_selector"),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(0x1000_0df00)),
                    MacIRSwitchCase(value: 1, target: .immediate(0x1000_0df10))
                ],
                defaultTarget: nil
            )
        )

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("    switch (unproven_switch_selector) {"), text)
        XCTAssertFalse(text.contains("switch (x8"), text)
        XCTAssertTrue(text.contains("        default: break;"))
        XCTAssertFalse(text.contains("__branch_register"))
    }

    // MARK: - Jump-table switch selector identity

    private func selectorRow(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    /// The SSA value an instruction defines, for asserting a selector against its exact definition.
    private func definedValue(_ operation: MacIROperation) -> MacIRValue? {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _), let .load(destination, _),
             let .select(destination, _, _, _, _, _), let .compareToBool(destination, _, _, _):
            return destination
        case let .intrinsic(destination, _, _):
            return destination
        case let .unknown(destination, _, _, _):
            return destination
        default:
            return nil
        }
    }

    private func switchSelector(_ operation: MacIROperation) -> MacIRValue? {
        guard case let .switchDispatch(index, _, _) = operation else { return nil }
        return index
    }

    private func switchDefault(_ operation: MacIROperation) -> MacIRValue?? {
        guard case let .switchDispatch(_, _, defaultTarget) = operation else { return nil }
        return .some(defaultTarget)
    }

    func testJumpTableSwitchSelectorIsTheGuardedDefinitionWhenIndexRegisterIsReused() throws {
        // clang's common signed-offset dispatch reuses the index register for the loaded
        // entry and then for the computed target: at the br, w8 holds (uint32_t)x8_2, the
        // TARGET ADDRESS. The selector must be the w8 definition the cmp guarded.
        let rows = [
            selectorRow(0x2000, "sub", "w8, w0, #0x1"),
            selectorRow(0x2004, "cmp", "w8, #0x2"),
            selectorRow(0x2008, "b.hi", "0x2100"),
            selectorRow(0x200c, "adrp", "x9, 0x3000"),
            selectorRow(0x2010, "add", "x9, x9, #0x0"),
            selectorRow(0x2014, "ldrsw", "x8, [x9, x8, lsl #2]"),
            selectorRow(0x2018, "add", "x8, x9, x8"),
            selectorRow(0x201c, "br", "x8")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_reused_index",
            jumpTables: [0x201c: [0x2040, 0x2050, 0x2060]],
            instructions: rows
        )

        let guarded = try XCTUnwrap(definedValue(function.instructions[0].operation))
        XCTAssertEqual(guarded, .register(name: "w8", version: 1))
        let dispatch = function.instructions[7].operation
        XCTAssertEqual(switchSelector(dispatch), guarded)
        XCTAssertEqual(switchDefault(dispatch), .some(.immediate(0x2100)))
        // Never the value the reused register holds at the dispatch.
        let atDispatch = try XCTUnwrap(definedValue(function.instructions[6].operation))
        XCTAssertNotEqual(switchSelector(dispatch), atDispatch)
        XCTAssertNotEqual(
            switchSelector(dispatch),
            .unary(op: "(uint32_t)", value: atDispatch)
        )

        let text = PseudocodePrinter().print(function: function).text
        let header = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("switch (") }, text)
        XCTAssertFalse(header.contains("switch (x8") || header.contains("switch ((uint32_t)x8"),
                       "the selector must not render the reused x8: \(header)")
        XCTAssertFalse(text.contains("unproven_switch_selector"), text)
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x2060, condition: "case 0x2:")
        GotoLabelWellFormednessTests.assertWellFormed(text)
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x2100, condition: "default:")
    }

    func testJumpTableSwitchAbstainsWhenIndexIsRedefinedBetweenGuardAndLoad() throws {
        // The bound proves 0...2 for the ORIGINAL w0; the table is indexed by w0 + 1.
        // Neither value is provably "the" selector of cases 0...2, so abstain.
        let rows = [
            selectorRow(0x2200, "cmp", "w0, #0x2"),
            selectorRow(0x2204, "b.hi", "0x2300"),
            selectorRow(0x2208, "add", "w0, w0, #0x1"),
            selectorRow(0x220c, "adrp", "x8, 0x3000"),
            selectorRow(0x2210, "add", "x8, x8, #0x0"),
            selectorRow(0x2214, "ldr", "x9, [x8, x0, lsl #3]"),
            selectorRow(0x2218, "br", "x9")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_redefined_index",
            jumpTables: [0x2218: [0x2240, 0x2250, 0x2260]],
            instructions: rows
        )
        let dispatch = function.instructions[6].operation
        XCTAssertEqual(switchSelector(dispatch), .unknown("unproven_switch_selector"))
        XCTAssertEqual(switchDefault(dispatch), .some(.immediate(0x2300)), "case edges and default are unchanged")
    }

    func testJumpTableSwitchAbstainsWhenGuardComparesAnUnrelatedRegister() throws {
        // The bounds pair compares w1 but the table is indexed by w0: w1 is not the selector.
        let rows = [
            selectorRow(0x2400, "cmp", "w1, #0x2"),
            selectorRow(0x2404, "b.hi", "0x2500"),
            selectorRow(0x2408, "adrp", "x8, 0x3000"),
            selectorRow(0x240c, "add", "x8, x8, #0x0"),
            selectorRow(0x2410, "ldrsw", "x9, [x8, w0, lsl #2]"),
            selectorRow(0x2414, "add", "x8, x8, x9"),
            selectorRow(0x2418, "br", "x8")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_unrelated_guard",
            jumpTables: [0x2418: [0x2440, 0x2450, 0x2460]],
            instructions: rows
        )
        XCTAssertEqual(switchSelector(function.instructions[6].operation), .unknown("unproven_switch_selector"))
        XCTAssertFalse(PseudocodePrinter().print(function: function).text.contains("switch (arg1)"))
    }

    func testJumpTableSwitchAbstainsWhenGuardedWValueIsUsedAsUnextendedXIndex() throws {
        // cmp w0 proves only the low word. The upper half of x0 can still change the
        // address used by an X-width indexed load, so no selector is named.
        let rows = [
            selectorRow(0x2500, "cmp", "w0, #0x2"),
            selectorRow(0x2504, "b.hi", "0x25f0"),
            selectorRow(0x2508, "adrp", "x8, 0x3000"),
            selectorRow(0x250c, "add", "x8, x8, #0x0"),
            selectorRow(0x2510, "ldrsw", "x9, [x8, x0, lsl #2]"),
            selectorRow(0x2514, "add", "x8, x8, x9"),
            selectorRow(0x2518, "br", "x8")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_mixed_width_index",
            jumpTables: [0x2518: [0x2540, 0x2550, 0x2560]],
            instructions: rows)
        XCTAssertEqual(switchSelector(function.instructions[6].operation), .unknown("unproven_switch_selector"))
        XCTAssertEqual(switchDefault(function.instructions[6].operation), .some(.immediate(0x25f0)))
    }

    func testJumpTableClampAbstainsWhenWGuardSelectsUnboundedXValue() throws {
        let rows = [
            selectorRow(0x2700, "cmp", "w16, #0x2"),
            selectorRow(0x2704, "csel", "x16, x16, xzr, ls"),
            selectorRow(0x2708, "adrp", "x17, 0x3000"),
            selectorRow(0x270c, "add", "x17, x17, #0x0"),
            selectorRow(0x2710, "ldr", "x16, [x17, x16, lsl #3]"),
            selectorRow(0x2714, "br", "x16")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_mixed_width_clamp",
            jumpTables: [0x2714: [0x2740, 0x2750, 0x2760]],
            instructions: rows)
        XCTAssertEqual(switchSelector(function.instructions[5].operation), .unknown("unproven_switch_selector"))
    }

    func testJumpTableSwitchAbstainsWhenGuardIsBypassedByABranchIntoTheDispatchRun() throws {
        // A direct branch from elsewhere reaches the indexed load without the guard.
        let rows = [
            selectorRow(0x2600, "cmp", "w0, #0x2"),
            selectorRow(0x2604, "b.hi", "0x2700"),
            selectorRow(0x2608, "adrp", "x8, 0x3000"),
            selectorRow(0x260c, "add", "x8, x8, #0x0"),
            selectorRow(0x2610, "ldrsw", "x9, [x8, w0, lsl #2]"),
            selectorRow(0x2614, "add", "x8, x8, x9"),
            selectorRow(0x2618, "br", "x8"),
            selectorRow(0x261c, "b", "0x2608")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_guard_bypass",
            jumpTables: [0x2618: [0x2640, 0x2650, 0x2660]],
            instructions: rows
        )
        XCTAssertEqual(switchSelector(function.instructions[6].operation), .unknown("unproven_switch_selector"))
    }

    func testJumpTableSwitchSelectorIsTheClampedValueForClampOnlyBounds() throws {
        // arm64e clamp with no bounds branch: `cmp x16, #2 ; csel x16, x16, xzr, ls` maps
        // every out-of-range index to 0, so the clamped x16 IS the selector and there is
        // no default exit. At the br, x16 holds the loaded target instead.
        let rows = [
            selectorRow(0x2800, "cmp", "x16, #0x2"),
            selectorRow(0x2804, "csel", "x16, x16, xzr, ls"),
            selectorRow(0x2808, "adrp", "x17, 0x3000"),
            selectorRow(0x280c, "add", "x17, x17, #0x0"),
            selectorRow(0x2810, "ldr", "x16, [x17, x16, lsl #3]"),
            selectorRow(0x2814, "br", "x16")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_clamp_only",
            jumpTables: [0x2814: [0x2840, 0x2850, 0x2860]],
            instructions: rows
        )

        let clamped = try XCTUnwrap(definedValue(function.instructions[1].operation))
        let loaded = try XCTUnwrap(definedValue(function.instructions[4].operation))
        XCTAssertNotEqual(clamped, loaded)
        let dispatch = function.instructions[5].operation
        XCTAssertEqual(switchSelector(dispatch), clamped)
        XCTAssertNotEqual(switchSelector(dispatch), loaded)
        XCTAssertEqual(switchDefault(dispatch), .some(nil), "a clamp has no out-of-range exit")

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertFalse(text.contains("unproven_switch_selector"), text)
        GotoLabelWellFormednessTests.assertTransfer(text, target: 0x2860, condition: "case 0x2:")
        GotoLabelWellFormednessTests.assertWellFormed(text)
    }

    func testJumpTableSwitchSelectorSurvivesArm64eReclampOfTheGuardedIndex() throws {
        // arm64e hardened dispatch: b.hi guards w0, then the mov-aliased x16 is re-clamped
        // to the same range (the identity on 0...2) and x16 is reused for the loaded entry.
        let rows = [
            selectorRow(0x2a00, "cmp", "w0, #0x2"),
            selectorRow(0x2a04, "b.hi", "0x2b00"),
            selectorRow(0x2a08, "mov", "w16, w0"),
            selectorRow(0x2a0c, "cmp", "x16, #0x2"),
            selectorRow(0x2a10, "csel", "x16, x16, xzr, ls"),
            selectorRow(0x2a14, "adrp", "x17, 0x3000"),
            selectorRow(0x2a18, "add", "x17, x17, #0x0"),
            selectorRow(0x2a1c, "ldr", "x16, [x17, x16, lsl #3]"),
            selectorRow(0x2a20, "br", "x16")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_arm64e_reclamp",
            jumpTables: [0x2a20: [0x2a40, 0x2a50, 0x2a60]],
            instructions: rows
        )
        let dispatch = function.instructions[8].operation
        XCTAssertEqual(switchSelector(dispatch), .argument(bindingID: .gpr(0)))
        XCTAssertEqual(switchDefault(dispatch), .some(.immediate(0x2b00)))
    }

    func testJumpTableSwitchAbstainsWhenReclampIsTighterThanTheGuard() throws {
        // b.hi admits 0...2 but the clamp maps 2 to 0: the guarded w0 no longer indexes
        // the table one-to-one, so it is not the selector of cases 0...2.
        let rows = [
            selectorRow(0x2c00, "cmp", "w0, #0x2"),
            selectorRow(0x2c04, "b.hi", "0x2d00"),
            selectorRow(0x2c08, "mov", "w16, w0"),
            selectorRow(0x2c0c, "cmp", "x16, #0x1"),
            selectorRow(0x2c10, "csel", "x16, x16, xzr, ls"),
            selectorRow(0x2c14, "adrp", "x17, 0x3000"),
            selectorRow(0x2c18, "add", "x17, x17, #0x0"),
            selectorRow(0x2c1c, "ldr", "x16, [x17, x16, lsl #3]"),
            selectorRow(0x2c20, "br", "x16")
        ]
        let function = MacIRBuilder().buildFunction(
            name: "_switch_tighter_reclamp",
            jumpTables: [0x2c20: [0x2c40, 0x2c50, 0x2c60]],
            instructions: rows
        )
        XCTAssertEqual(switchSelector(function.instructions[8].operation), .unknown("unproven_switch_selector"))
    }

    // MARK: - Objective-C selector resolution

    func testObjcMsgSendResolvesSelectorFromSelrefSlot() throws {
        // adrp/ldr selref idiom feeding x1, with a receiver in x0. The selref
        // slot 0x100008000 + 0x10 == 0x100008010 maps to "viewDidLoad".
        let rows = [
            InstructionRow(address: 0x1000_60000, bytes: "00 00 00 90", mnemonic: "adrp", operands: "x0, 0x100009000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_60004, bytes: "00 00 40 f9", mnemonic: "ldr", operands: "x0, [x0]", hasBreakpoint: false, comment: "receiver"),
            InstructionRow(address: 0x1000_60008, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6000c, bytes: "21 08 40 f9", mnemonic: "ldr", operands: "x1, [x1, #0x10]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_60010, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_60014, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_send_view_did_load",
            objcSelectors: [0x1000_08010: "viewDidLoad"],
            instructions: rows
        )
        let frame = try firstCallFrame(in: function)
        XCTAssertEqual(frame.target, "_objc_msgSend")
        XCTAssertEqual(frame.knownSignature?.target, "_objc_msgSend")
        let selector = try XCTUnwrap(frame.arguments.argument(at: .gpr(index: 1)))
        XCTAssertEqual(selector.location, .gpr(index: 1, carrierWidth: 64))
        XCTAssertEqual(selector.role, .fixed(sourcePosition: 1))
        XCTAssertEqual(selector.value, .register(name: "x1", version: 2))
        XCTAssertEqual(
            selector.selectorEvidence,
            MacIRCallSelectorEvidence(name: "viewDidLoad", selrefAddress: 0x1000_08010)
        )
        XCTAssertEqual(frame.tailCountEvidence, .objectiveCSelectorColonCount(0))
        XCTAssertFalse(frame.arguments.canonicalPhysicalEntriesForAudit.contains {
            $0.tailOrdinal != nil
        })

        let document = PseudocodePrinter().print(function: function)
        let text = document.text
        // The resolved no-argument selector renders as an Objective-C bracket
        // message on the receiver.
        XCTAssertTrue(text.contains("[x0_2 viewDidLoad]"))
        XCTAssertFalse(text.contains("__branch_register"))
    }

    func testObjcMsgSendResolvesSelectorFromAdrpAddLdrVariant() throws {
        // adrp + add + ldr [base] variant: the slot base is materialized by an
        // add before a zero-offset load. Slot 0x100008000 + 0x20 == 0x100008020.
        let rows = [
            InstructionRow(address: 0x1000_61000, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_61004, bytes: "21 80 00 91", mnemonic: "add", operands: "x1, x1, #0x20", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_61008, bytes: "21 00 40 f9", mnemonic: "ldr", operands: "x1, [x1]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_6100c, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_61010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let document = PseudocodePrinter().print(
            functionName: "_send_alloc",
            objcSelectors: [0x1000_08020: "alloc"],
            instructions: rows
        )
        // Resolved as a bracket message; the selector is no longer a quoted arg.
        XCTAssertTrue(document.text.contains("alloc]"), document.text)
        XCTAssertFalse(document.text.contains("\"alloc\""), document.text)
    }

    func testObjcMsgSendResolvesOnlySelectorArgumentNotReceiver() throws {
        // A receiver derives from its own adrp/ldr in x0, and the selector from a
        // separate selref load in x1. Only arg1 is rewritten; arg0 stays the
        // receiver SSA value, and the rest of the document is byte-identical to
        // the same run with an empty selector map.
        let rows = [
            InstructionRow(address: 0x1000_62000, bytes: "00 00 00 90", mnemonic: "adrp", operands: "x0, 0x10000a000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_62004, bytes: "00 08 40 f9", mnemonic: "ldr", operands: "x0, [x0, #0x10]", hasBreakpoint: false, comment: "receiver"),
            InstructionRow(address: 0x1000_62008, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6200c, bytes: "21 00 40 f9", mnemonic: "ldr", operands: "x1, [x1]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_62010, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_62014, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let resolved = PseudocodePrinter().print(
            functionName: "_send_keep_receiver",
            objcSelectors: [0x1000_08000: "init", 0x1000_0a010: "doNotPickThis"],
            instructions: rows
        ).text
        // Receiver came from slot 0x10000a010 which is also mapped, but the
        // receiver is x0 (arg0) — it must NOT be turned into a string; only the
        // SEL (x1) is. So "doNotPickThis" never appears.
        XCTAssertTrue(resolved.contains("[x0_2 init]"))
        XCTAssertFalse(resolved.contains("doNotPickThis"))
    }

    func testObjcMsgSendKeywordSelectorRetainsEvidenceButAbstainsWithoutMethodABI() throws {
        // Selector arity alone cannot prove the explicit arguments' types or
        // one-register-per-source-position mapping.
        let rows = [
            InstructionRow(address: 0x1000_64000, bytes: "00 00 00 90", mnemonic: "adrp", operands: "x0, 0x10000b000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_64004, bytes: "00 00 40 f9", mnemonic: "ldr", operands: "x0, [x0]", hasBreakpoint: false, comment: "receiver"),
            InstructionRow(address: 0x1000_64008, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6400c, bytes: "21 00 40 f9", mnemonic: "ldr", operands: "x1, [x1]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_64010, bytes: "22 00 80 d2", mnemonic: "mov", operands: "x2, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_64014, bytes: "43 00 80 d2", mnemonic: "mov", operands: "x3, #0x2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_64018, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6401c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(
            name: "_send_set_object",
            objcSelectors: [0x1000_08000: "setObject:forKey:"],
            instructions: rows
        )
        let frame = try firstCallFrame(in: function)
        XCTAssertEqual(frame.target, "_objc_msgSend")
        XCTAssertEqual(frame.knownSignature?.target, "_objc_msgSend")
        let selector = try XCTUnwrap(frame.arguments.argument(at: .gpr(index: 1)))
        XCTAssertEqual(selector.role, .fixed(sourcePosition: 1))
        XCTAssertEqual(selector.value, .register(name: "x1", version: 2))
        XCTAssertEqual(
            selector.selectorEvidence,
            MacIRCallSelectorEvidence(name: "setObject:forKey:", selrefAddress: 0x1000_08000)
        )
        XCTAssertEqual(frame.tailCountEvidence, .objectiveCSelectorColonCount(2))
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 2)))
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 3)))
        XCTAssertNil(frame.completeKnownVariadicRenderValues())
        XCTAssertFalse(frame.arguments.observationScope.observes(.gpr(index: 2, carrierWidth: 64)))
        XCTAssertFalse(frame.arguments.observationScope.observes(.gpr(index: 3, carrierWidth: 64)))
        XCTAssertFalse(frame.arguments.observationScope.observes(.gpr(index: 0, carrierWidth: 64)))
        XCTAssertFalse(frame.arguments.observationScope.observes(.gpr(index: 1, carrierWidth: 64)))

        let document = PseudocodePrinter().print(function: function)
        XCTAssertFalse(document.text.contains("[x0_2 setObject:"), document.text)
        let callLine = try XCTUnwrap(
            document.text.split(separator: "\n").first { $0.contains("_objc_msgSend(") }
        )
        XCTAssertTrue(callLine.contains("_objc_msgSend(x0_2, \"setObject:forKey:\")"))
        XCTAssertFalse(callLine.contains("x2_1"))
        XCTAssertFalse(callLine.contains("x3_1"))
    }

    func testObjcMsgSendWithEmptySelectorMapKeepsOpaqueRendering() throws {
        // Identical rows to the positive case but with an empty map: the seam is
        // inert and the rendering is byte-identical to today's opaque output.
        let rows = [
            InstructionRow(address: 0x1000_63000, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_63004, bytes: "21 08 40 f9", mnemonic: "ldr", operands: "x1, [x1, #0x10]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_63008, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6300c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let baseline = PseudocodePrinter().print(functionName: "_send_empty", instructions: rows).text
        let withEmptyMap = PseudocodePrinter().print(
            functionName: "_send_empty",
            objcSelectors: [:],
            instructions: rows
        ).text
        XCTAssertEqual(baseline, withEmptyMap)
        XCTAssertFalse(withEmptyMap.contains("\"viewDidLoad\""))
    }

    func testObjcMsgSendWithSlotMissKeepsOpaqueRendering() throws {
        // A non-empty map whose key does NOT match the computed slot address: the
        // exact-key gate misses and the SEL argument stays opaque.
        let rows = [
            InstructionRow(address: 0x1000_64000, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_64004, bytes: "21 08 40 f9", mnemonic: "ldr", operands: "x1, [x1, #0x10]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_64008, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6400c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let baseline = PseudocodePrinter().print(functionName: "_send_miss", instructions: rows).text
        let withWrongKey = PseudocodePrinter().print(
            functionName: "_send_miss",
            objcSelectors: [0x1000_08099: "viewDidLoad"],
            instructions: rows
        ).text
        XCTAssertEqual(baseline, withWrongKey)
        XCTAssertFalse(withWrongKey.contains("\"viewDidLoad\""))
    }

    func testObjcMsgSendWithClobberedSelectorRegisterKeepsOpaqueRendering() throws {
        // x1 is overwritten by a `mov` after the selref load, so the call's 2nd
        // argument is a different SSA version with no provenance entry — no
        // resolution, even though the slot itself is mapped.
        let rows = [
            InstructionRow(address: 0x1000_65000, bytes: "01 00 00 90", mnemonic: "adrp", operands: "x1, 0x100008000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_65004, bytes: "21 08 40 f9", mnemonic: "ldr", operands: "x1, [x1, #0x10]", hasBreakpoint: false, comment: "selref"),
            InstructionRow(address: 0x1000_65008, bytes: "e1 03 00 aa", mnemonic: "mov", operands: "x1, x0", hasBreakpoint: false, comment: "clobber selector"),
            InstructionRow(address: 0x1000_6500c, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_65010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let text = PseudocodePrinter().print(
            functionName: "_send_clobbered",
            objcSelectors: [0x1000_08010: "viewDidLoad"],
            instructions: rows
        ).text
        XCTAssertFalse(text.contains("\"viewDidLoad\""))
    }

    func testObjcMsgSendNonSelrefStackLoadKeepsStackBehavior() throws {
        // A plain stack load feeding x1: the base is sp (not an adrp page base),
        // so no slot is ever computed and the stack-slot behavior is preserved.
        let rows = [
            InstructionRow(address: 0x1000_66000, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_66004, bytes: "e1 0b 40 f9", mnemonic: "ldr", operands: "x1, [sp, #0x8]", hasBreakpoint: false, comment: "stack load"),
            InstructionRow(address: 0x1000_66008, bytes: "00 00 00 94", mnemonic: "bl", operands: "_objc_msgSend", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_6600c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_66010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let text = PseudocodePrinter().print(
            functionName: "_send_stack",
            objcSelectors: [0x1000_08010: "viewDidLoad"],
            instructions: rows
        ).text
        XCTAssertFalse(text.contains("\"viewDidLoad\""))
    }

    // MARK: - Type propagation into stack-local declarations (Wave 5)

    // A BOOL recovered from `cset` propagates through a pure `mov` copy and,
    // when the copy is spilled to a stack slot, surfaces as the recovered
    // local's declared type (BOOL) instead of the register-width default.
    func testBoolTypePropagatesThroughPureMovIntoStackLocalDeclaration() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e000, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e004, bytes: "1f 00 00 71", mnemonic: "cmp", operands: "w0, #0x0", hasBreakpoint: false, comment: "test arg"),
            InstructionRow(address: 0x1000_0e008, bytes: "e8 17 9f 1a", mnemonic: "cset", operands: "w8, eq", hasBreakpoint: false, comment: "flag equals"),
            InstructionRow(address: 0x1000_0e00c, bytes: "e9 03 08 2a", mnemonic: "mov", operands: "w9, w8", hasBreakpoint: false, comment: "copy flag"),
            InstructionRow(address: 0x1000_0e010, bytes: "e9 0f 00 b9", mnemonic: "str", operands: "w9, [sp, #0xc]", hasBreakpoint: false, comment: "spill flag"),
            InstructionRow(address: 0x1000_0e014, bytes: "ea 0f 40 b9", mnemonic: "ldr", operands: "w10, [sp, #0xc]", hasBreakpoint: false, comment: "reload flag"),
            InstructionRow(address: 0x1000_0e018, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e01c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_bool_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0xc, type: "BOOL", byteWidth: 4)]
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    BOOL local_c;")
        let declaration = try XCTUnwrap(document.lines.first { $0.kind == .declaration })
        XCTAssertTrue(declaration.tokens.contains { $0.kind == .type && $0.text == "BOOL" })
        XCTAssertTrue(declaration.tokens.contains { $0.kind == .identifier && $0.text == "local_c" })
    }

    // A `void *` recovered from a known `malloc` return propagates through a
    // pure `mov` copy and surfaces as the spilled local's declared type.
    func testMallocPointerTypePropagatesThroughPureMovIntoStackLocalDeclaration() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e100, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e104, bytes: "00 02 80 d2", mnemonic: "mov", operands: "x0, #0x10", hasBreakpoint: false, comment: "size"),
            InstructionRow(address: 0x1000_0e108, bytes: "00 00 00 94", mnemonic: "bl", operands: "_malloc", hasBreakpoint: false, comment: "allocate"),
            InstructionRow(address: 0x1000_0e10c, bytes: "f3 03 00 aa", mnemonic: "mov", operands: "x19, x0", hasBreakpoint: false, comment: "keep pointer"),
            InstructionRow(address: 0x1000_0e110, bytes: "f3 07 00 f9", mnemonic: "str", operands: "x19, [sp, #0x8]", hasBreakpoint: false, comment: "spill pointer"),
            InstructionRow(address: 0x1000_0e114, bytes: "f4 07 40 f9", mnemonic: "ldr", operands: "x20, [sp, #0x8]", hasBreakpoint: false, comment: "reload pointer"),
            InstructionRow(address: 0x1000_0e118, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e11c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_malloc_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "void *", byteWidth: 8)]
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    void * local_8;")
        let declaration = try XCTUnwrap(document.lines.first { $0.kind == .declaration })
        XCTAssertTrue(declaration.tokens.contains { $0.kind == .type && $0.text == "void" })
    }

    // NEGATIVE: arithmetic on a recovered `void *` (here `add`) breaks the
    // pure-copy chain, so the spilled local must fall back to the
    // register-width default (int64_t) rather than inheriting the pointer type.
    func testArithmeticOnRecoveredPointerBlocksPropagationIntoStackLocal() throws {
        let rows = [
            InstructionRow(address: 0x1000_0e200, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e204, bytes: "00 02 80 d2", mnemonic: "mov", operands: "x0, #0x10", hasBreakpoint: false, comment: "size"),
            InstructionRow(address: 0x1000_0e208, bytes: "00 00 00 94", mnemonic: "bl", operands: "_malloc", hasBreakpoint: false, comment: "allocate"),
            InstructionRow(address: 0x1000_0e20c, bytes: "13 20 00 91", mnemonic: "add", operands: "x19, x0, #0x8", hasBreakpoint: false, comment: "advance pointer"),
            InstructionRow(address: 0x1000_0e210, bytes: "f3 07 00 f9", mnemonic: "str", operands: "x19, [sp, #0x8]", hasBreakpoint: false, comment: "spill offset pointer"),
            InstructionRow(address: 0x1000_0e214, bytes: "f4 07 40 f9", mnemonic: "ldr", operands: "x20, [sp, #0x8]", hasBreakpoint: false, comment: "reload"),
            InstructionRow(address: 0x1000_0e218, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0e21c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_malloc_arith_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "int64_t", byteWidth: 8)]
        )

        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    int64_t local_8;")
        XCTAssertFalse(document.text.contains("void * local_8"), document.text)
    }

    // MARK: - Typed local-variable recovery (LocalTypeInferencePass)

    // A load-only byte slot accessed BOTH unsigned (ldrb) and signed (ldrsb) at
    // the same width is a HARD-vs-HARD signedness conflict. Correctness over
    // coverage: the meet resolves to unknown and the builder's seed (uint8_t, from
    // the first sized access) is kept verbatim — the pass never renders a
    // possibly-wrong signedness from an irreconcilable conflict.
    func testConflictingByteSignednessKeepsBuilderUInt8() throws {
        let rows = [
            InstructionRow(address: 0x1000_40000, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40004, bytes: "e0 1f 40 39", mnemonic: "ldrb", operands: "w0, [sp, #0x7]", hasBreakpoint: false, comment: "unsigned load"),
            InstructionRow(address: 0x1000_40008, bytes: "e1 1f 80 39", mnemonic: "ldrsb", operands: "w1, [sp, #0x7]", hasBreakpoint: false, comment: "signed load"),
            InstructionRow(address: 0x1000_4000c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sb_load", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x7, type: "uint8_t", byteWidth: 1)]
        )
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    uint8_t local_7;")
    }

    // An unsigned-byte load-only access keeps the uint8_t element type.
    func testUnsignedByteLoadKeepsUInt8Local() throws {
        let rows = [
            InstructionRow(address: 0x1000_40100, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40104, bytes: "e0 1f 40 39", mnemonic: "ldrb", operands: "w0, [sp, #0x6]", hasBreakpoint: false, comment: "unsigned load"),
            InstructionRow(address: 0x1000_40108, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_4010c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_ub_load", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x6, type: "uint8_t", byteWidth: 1)]
        )
    }

    // A load-only halfword slot accessed BOTH unsigned (ldrh) and signed (ldrsh)
    // at the same width is a HARD-vs-HARD signedness conflict; the builder's seed
    // (uint16_t) is kept and the pass renders no wrong signedness.
    func testConflictingHalfwordSignednessKeepsBuilderUInt16() throws {
        let rows = [
            InstructionRow(address: 0x1000_40200, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40204, bytes: "e0 1b 40 79", mnemonic: "ldrh", operands: "w0, [sp, #0xe]", hasBreakpoint: false, comment: "unsigned load"),
            InstructionRow(address: 0x1000_40208, bytes: "e1 1b 80 79", mnemonic: "ldrsh", operands: "w1, [sp, #0xe]", hasBreakpoint: false, comment: "signed load"),
            InstructionRow(address: 0x1000_4020c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40210, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sh_load", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0xe, type: "uint16_t", byteWidth: 2)]
        )
    }

    // A spilled pointer consumed as strlen's `const char *` argument refines the
    // originating slot to `const char *` via the one-hop store-map trace.
    func testStrlenArgumentRefinesSpilledSlotToConstCharPointer() throws {
        let rows = [
            InstructionRow(address: 0x1000_40300, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40304, bytes: "e0 07 00 f9", mnemonic: "str", operands: "x0, [sp, #0x8]", hasBreakpoint: false, comment: "spill string"),
            InstructionRow(address: 0x1000_40308, bytes: "e0 07 40 f9", mnemonic: "ldr", operands: "x0, [sp, #0x8]", hasBreakpoint: false, comment: "reload string"),
            InstructionRow(address: 0x1000_4030c, bytes: "00 00 00 94", mnemonic: "bl", operands: "_strlen", hasBreakpoint: false, comment: "measure"),
            InstructionRow(address: 0x1000_40310, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40314, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_strlen_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "const char *", byteWidth: 8)]
        )
        let document = PseudocodePrinter().print(function: function)
        XCTAssertEqual(document.localVariables, function.localVariables)
        XCTAssertEqual(document.lines.first { $0.kind == .declaration }?.text, "    const char * local_8;")
    }

    // udiv quotient spilled to a slot refines that slot to uint64_t.
    func testUnsignedDivideQuotientSpillRefinesLocalToUInt64() throws {
        let rows = [
            InstructionRow(address: 0x1000_40400, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40404, bytes: "00 08 c1 9a", mnemonic: "udiv", operands: "x0, x0, x1", hasBreakpoint: false, comment: "unsigned divide"),
            InstructionRow(address: 0x1000_40408, bytes: "e0 07 00 f9", mnemonic: "str", operands: "x0, [sp, #0x8]", hasBreakpoint: false, comment: "spill quotient"),
            InstructionRow(address: 0x1000_4040c, bytes: "e2 07 40 f9", mnemonic: "ldr", operands: "x2, [sp, #0x8]", hasBreakpoint: false, comment: "reload"),
            InstructionRow(address: 0x1000_40410, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40414, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_udiv_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "uint64_t", byteWidth: 8)]
        )
    }

    // sdiv quotient spilled to a slot leaves the signed int64_t default in place
    // (the builder default already matches, so no rewrite occurs).
    func testSignedDivideQuotientSpillKeepsInt64() throws {
        let rows = [
            InstructionRow(address: 0x1000_40500, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40504, bytes: "00 0c c1 9a", mnemonic: "sdiv", operands: "x0, x0, x1", hasBreakpoint: false, comment: "signed divide"),
            InstructionRow(address: 0x1000_40508, bytes: "e0 07 00 f9", mnemonic: "str", operands: "x0, [sp, #0x8]", hasBreakpoint: false, comment: "spill quotient"),
            InstructionRow(address: 0x1000_4050c, bytes: "e2 07 40 f9", mnemonic: "ldr", operands: "x2, [sp, #0x8]", hasBreakpoint: false, comment: "reload"),
            InstructionRow(address: 0x1000_40510, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40514, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_sdiv_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "int64_t", byteWidth: 8)]
        )
    }

    // CONFLICT: a byte store then a signed-word reload of the SAME slot is an
    // irreconcilable width conflict. The builder recovers the wider int32_t; the
    // pass must NOT narrow it to a byte even though byte evidence exists. The
    // width-match write-back gate keeps the builder's original recovered type.
    func testConflictingByteStoreThenSignedWordReloadKeepsBuilderType() throws {
        let rows = [
            InstructionRow(address: 0x1000_40600, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40604, bytes: "e0 0b 00 39", mnemonic: "strb", operands: "w0, [sp, #0x8]", hasBreakpoint: false, comment: "byte store"),
            InstructionRow(address: 0x1000_40608, bytes: "e1 0b 80 b9", mnemonic: "ldrsw", operands: "x1, [sp, #0x8]", hasBreakpoint: false, comment: "signed word reload"),
            InstructionRow(address: 0x1000_4060c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40610, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_conflict_slot", instructions: rows)
        let slot = try XCTUnwrap(function.localVariables.first(where: { $0.offset == 0x8 }))
        XCTAssertEqual(slot.byteWidth, 4)
        XCTAssertEqual(slot.type, "int32_t")
    }

    // A generic width-only x-register spill keeps int64_t — there is no positive
    // signedness signal, so the pass must not invent unsigned.
    func testGenericWidthOnlySlotKeepsInt64() throws {
        let rows = [
            InstructionRow(address: 0x1000_40700, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40704, bytes: "20 00 80 d2", mnemonic: "mov", operands: "x0, #0x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40708, bytes: "e0 07 00 f9", mnemonic: "str", operands: "x0, [sp, #0x8]", hasBreakpoint: false, comment: "plain spill"),
            InstructionRow(address: 0x1000_4070c, bytes: "e1 07 40 f9", mnemonic: "ldr", operands: "x1, [sp, #0x8]", hasBreakpoint: false, comment: "plain reload"),
            InstructionRow(address: 0x1000_40710, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40714, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_generic_spill", instructions: rows)
        XCTAssertEqual(
            function.localVariables,
            [MacIRLocalVariable(offset: 0x8, type: "int64_t", byteWidth: 8)]
        )
    }

    // cset materializes a boolean predicate into a scratch register; the
    // register-temporary name binding is typed BOOL.
    func testCsetRegisterTemporaryNameBindingIsBool() throws {
        let rows = [
            InstructionRow(address: 0x1000_40800, bytes: "1f 00 00 71", mnemonic: "cmp", operands: "w0, #0x0", hasBreakpoint: false, comment: "test"),
            InstructionRow(address: 0x1000_40804, bytes: "e8 17 9f 1a", mnemonic: "cset", operands: "w8, eq", hasBreakpoint: false, comment: "predicate"),
            InstructionRow(address: 0x1000_40808, bytes: "e0 03 08 2a", mnemonic: "mov", operands: "w0, w8", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_4080c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let function = MacIRBuilder().buildFunction(name: "_cset_temp", instructions: rows)
        let binding = try XCTUnwrap(function.nameBindings.first { $0.kind == .registerTemporary })
        XCTAssertEqual(binding.type, "BOOL")
    }

    // IDEMPOTENCY: running the pass a second time on its own output is a no-op.
    func testLocalTypeInferenceIsIdempotent() throws {
        let rows = [
            InstructionRow(address: 0x1000_40900, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_40904, bytes: "e0 1f 00 39", mnemonic: "strb", operands: "w0, [sp, #0x7]", hasBreakpoint: false, comment: "spill byte"),
            InstructionRow(address: 0x1000_40908, bytes: "e1 1f 80 39", mnemonic: "ldrsb", operands: "w1, [sp, #0x7]", hasBreakpoint: false, comment: "signed reload"),
            InstructionRow(address: 0x1000_4090c, bytes: "00 08 c1 9a", mnemonic: "udiv", operands: "x2, x0, x1", hasBreakpoint: false, comment: "divide"),
            InstructionRow(address: 0x1000_40910, bytes: "e2 0b 00 f9", mnemonic: "str", operands: "x2, [sp, #0x8]", hasBreakpoint: false, comment: "spill quotient"),
            InstructionRow(address: 0x1000_40914, bytes: "e3 0b 40 f9", mnemonic: "ldr", operands: "x3, [sp, #0x8]", hasBreakpoint: false, comment: "reload"),
            InstructionRow(address: 0x1000_40918, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_4091c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let once = MacIRBuilder().buildFunction(name: "_idem", instructions: rows)
        let twice = LocalTypeInferencePass.infer(function: once)
        XCTAssertEqual(once.localVariables, twice.localVariables)
        XCTAssertEqual(once.nameBindings, twice.nameBindings)
        XCTAssertEqual(once, twice)
    }

    // CONFLICT (signedness): a byte slot seeded unsigned (ldrb / strb) and ALSO
    // read signed (ldrsb) at the SAME width is an irreconcilable HARD-vs-HARD
    // signedness conflict. Neither hard fact can be trusted to override the other,
    // so the meet must resolve to unknown and the pass keeps the builder's
    // ORIGINAL type rather than rendering a possibly-WRONG signedness. The slot
    // here is seeded uint8_t by the unsigned reload and stays uint8_t.
    func testConflictingHardSignednessKeepsBuilderType() throws {
        let rows = [
            InstructionRow(address: 0x1000_41000, bytes: "ff 43 00 d1", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_41004, bytes: "e0 1f 40 39", mnemonic: "ldrb", operands: "w0, [sp, #0x5]", hasBreakpoint: false, comment: "unsigned load"),
            InstructionRow(address: 0x1000_41008, bytes: "e1 1f 80 39", mnemonic: "ldrsb", operands: "w1, [sp, #0x5]", hasBreakpoint: false, comment: "signed load"),
            InstructionRow(address: 0x1000_4100c, bytes: "ff 43 00 91", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_41010, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        // The builder seeds the slot uint8_t from the first sized (ldrb) access.
        let builder = MacIRBuilder().buildFunction(name: "_sign_conflict", instructions: rows)
        let seeded = try XCTUnwrap(builder.localVariables.first(where: { $0.offset == 0x5 }))
        XCTAssertEqual(seeded.type, "uint8_t", "builder seed precondition")

        // After inference the conflicting hard signed evidence must NOT flip the
        // type; the original (uint8_t) is preserved, no wrong signedness rendered.
        let inferred = LocalTypeInferencePass.infer(function: builder)
        let slot = try XCTUnwrap(inferred.localVariables.first(where: { $0.offset == 0x5 }))
        XCTAssertEqual(slot.type, "uint8_t")
        XCTAssertEqual(slot.byteWidth, 1)
    }

    // ORDER-INDEPENDENCE of meet: meet(a, b) must equal meet(b, a) for every
    // pair. The builder's seed is itself order-sensitive, so this asserts the
    // lattice directly via the test hook.
    func testLocalTypeInferenceMeetIsOrderIndependent() throws {
        // Two HARD facts, same width, conflicting signedness -> unknown either way.
        let hardSigned = InferredLocalTypeFact(lattice: .integer(bits: 8, signed: true), confidence: true)
        let hardUnsigned = InferredLocalTypeFact(lattice: .integer(bits: 8, signed: false), confidence: true)
        XCTAssertEqual(
            LocalTypeInferencePass.meetForTesting(hardSigned, hardUnsigned),
            LocalTypeInferencePass.meetForTesting(hardUnsigned, hardSigned)
        )
        XCTAssertEqual(
            LocalTypeInferencePass.meetForTesting(hardSigned, hardUnsigned).lattice,
            .unknown,
            "hard-vs-hard signedness conflict resolves to unknown"
        )

        // Same lattice, DIFFERENT exact spellings ("size_t" vs bare uint64_t):
        // the result must not depend on order (finding: order-dependent exact
        // string). Both orderings must agree, dropping to the lattice default.
        let sizeT = InferredLocalTypeFact(lattice: .integer(bits: 64, signed: false), confidence: true, exactTypeString: "size_t")
        let bareU64 = InferredLocalTypeFact(lattice: .integer(bits: 64, signed: false), confidence: true)
        XCTAssertEqual(
            LocalTypeInferencePass.meetForTesting(sizeT, bareU64),
            LocalTypeInferencePass.meetForTesting(bareU64, sizeT)
        )

        // Two DIFFERENT exact spellings of the same lattice ("size_t" vs another
        // named 64-bit unsigned spelling) drop the unjustifiable exact string,
        // identically in both orders.
        let namedU64 = InferredLocalTypeFact(lattice: .integer(bits: 64, signed: false), confidence: true, exactTypeString: "uintptr_t")
        let forward = LocalTypeInferencePass.meetForTesting(sizeT, namedU64)
        let backward = LocalTypeInferencePass.meetForTesting(namedU64, sizeT)
        XCTAssertEqual(forward, backward)
        XCTAssertNil(forward.exactTypeString, "conflicting exact spellings drop to the lattice default")

        // A hard-vs-soft signedness conflict still lets the hard side win, in
        // either order.
        let softSigned = InferredLocalTypeFact(lattice: .integer(bits: 32, signed: true), confidence: false)
        let hardUnsigned32 = InferredLocalTypeFact(lattice: .integer(bits: 32, signed: false), confidence: true)
        XCTAssertEqual(
            LocalTypeInferencePass.meetForTesting(softSigned, hardUnsigned32),
            LocalTypeInferencePass.meetForTesting(hardUnsigned32, softSigned)
        )
        XCTAssertEqual(
            LocalTypeInferencePass.meetForTesting(softSigned, hardUnsigned32),
            hardUnsigned32,
            "hard side wins a hard-vs-soft conflict"
        )
    }

    /// Decompiler-readability increment 1: a `[base, #offset]` memory operand should
    /// lower to a structured `base + offset` address so the printer renders a readable
    /// `*(base + 0x60)` dereference instead of the raw machine `*([x1, #0x60])` form.
    func testOffsetMemoryLoadRendersAsBasePlusOffset() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "20 30 40 f9",
                mnemonic: "ldr",
                operands: "x0, [x1, #0x60]",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_load", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertTrue(
            text.contains("+ 0x60"),
            "offset load should render as a base+offset dereference; got:\n\(text)"
        )
        XCTAssertFalse(
            text.contains("[x1, #0x60]"),
            "the raw machine bracket form must not leak into pseudocode; got:\n\(text)"
        )
    }

    /// Decompiler-readability increment 2: a scaled register-index load
    /// `[base, index, lsl #shift]` (the array[i] idiom) should render as a readable
    /// `*(base + (index << shift))` instead of the raw machine `*([x8, x9, lsl #3])`.
    func testScaledIndexMemoryLoadRendersAsShiftedAddition() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "00 79 69 f8",
                mnemonic: "ldr",
                operands: "x0, [x8, x9, lsl #3]",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_index", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertTrue(
            text.contains("<< 0x3"),
            "the scale should render as a shift `(index << shift)` (immediates are hex); got:\n\(text)"
        )
        XCTAssertTrue(
            text.contains(" + ("),
            "the address should read as `base + (scaled index)`; got:\n\(text)"
        )
        XCTAssertFalse(
            text.contains("lsl"),
            "the raw machine shift keyword must not leak into pseudocode; got:\n\(text)"
        )
        XCTAssertFalse(
            text.contains("[x8"),
            "the raw machine bracket form must not leak into pseudocode; got:\n\(text)"
        )
    }

    /// Increment 2, plain register-offset form: `[base, index]` should render as
    /// `*(base + index)`.
    func testRegisterOffsetMemoryLoadRendersAsAddition() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "00 69 69 f8",
                mnemonic: "ldr",
                operands: "x0, [x8, x9]",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_regoff", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertTrue(
            text.contains(" + "),
            "register-offset load should render as `base + index`; got:\n\(text)"
        )
        XCTAssertFalse(
            text.contains("[x8"),
            "the raw machine bracket form must not leak into pseudocode; got:\n\(text)"
        )
    }

    /// Decompiler-readability, shifted-register data-processing: `add xd, xn, xm, lsl #s`
    /// should lift to `xd = xn + (xm << s)` instead of `__unknown("add", …)`.
    func testShiftedRegisterAddIsLifted() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "20 0d 0a 8b",
                mnemonic: "add",
                operands: "x0, x9, x10, lsl #3",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_shadd", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertTrue(
            text.contains(" + ("),
            "shifted add should lift to `xn + (xm << s)`; got:\n\(text)"
        )
        XCTAssertTrue(text.contains("<< 0x3"), "the shift should render; got:\n\(text)")
        XCTAssertFalse(text.contains("__unknown"), "the op must be lifted, not opaque; got:\n\(text)")
        XCTAssertFalse(text.contains("lsl"), "the raw shift keyword must not leak; got:\n\(text)")
    }

    /// Shifted-register logical form: `eor xd, xn, xm, lsl #s` → `xd = xn ^ (xm << s)`.
    func testShiftedRegisterEorIsLifted() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "20 05 0a ca",
                mnemonic: "eor",
                operands: "x0, x9, x10, lsl #1",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_sheor", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertTrue(text.contains(" ^ ("), "shifted eor should lift to `xn ^ (xm << s)`; got:\n\(text)")
        XCTAssertTrue(text.contains("<< 0x1"), "the shift should render; got:\n\(text)")
        XCTAssertFalse(text.contains("__unknown"), "the op must be lifted, not opaque; got:\n\(text)")
    }

    /// C5 (vim decompile sweep): SHA-style `eor wd, wn, wm, ror #s` lifts to
    /// `wn ^ ((wm >> s) | (wm << (32 - s)))` instead of an opaque `__unknown`.
    func testShiftedRegisterEorWithRotateIsLifted() throws {
        let rows = [
            InstructionRow(address: 0x1000_00000, bytes: "29 2d d6 4a", mnemonic: "eor",
                           operands: "w9, w9, w22, ror #11", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00004, bytes: "c0 03 5f d6", mnemonic: "ret",
                           operands: "", hasBreakpoint: false, comment: nil),
        ]

        let function = MacIRBuilder().buildFunction(name: "_sheor_ror", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertFalse(text.contains("__unknown"), "the rotate must be lifted, not opaque; got:\n\(text)")
        XCTAssertTrue(text.contains(">> 0xb"), "the right part of the rotate should render; got:\n\(text)")
        XCTAssertTrue(text.contains("<< 0x15"), "the left part uses 32 - 11 = 21; got:\n\(text)")
        XCTAssertFalse(text.contains("ror #"), "the raw rotate keyword must not leak; got:\n\(text)")
    }

    /// Decompiler-readability increment 3: `*(argN + off)` where argN has an applied
    /// pointer-to-struct signature type, and a field starts at `off`, should render as
    /// `argN->field` — reading like C struct access instead of pointer arithmetic.
    func testStructPointerArgumentDereferenceRendersFieldAccess() throws {
        // struct Foo { int64_t first; int64_t second; } → first@0x0, second@0x8
        let foo = TypeDefinition(kind: .struct, name: "Foo", fields: [
            FieldDef(name: "first", type: "int64_t"),
            FieldDef(name: "second", type: "int64_t")
        ])
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "00 04 40 f9",
                mnemonic: "ldr",
                operands: "x0, [x0, #0x8]",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        var function = MacIRBuilder().buildFunction(name: "_getsecond", instructions: rows)
        // Apply a signature so arg0 is `struct Foo *` (the real set-signature path).
        function.parameters = [MacIRFunctionParameter(index: 0, register: "x0", type: "struct Foo *", name: "foo")]

        let text = PseudocodePrinter().print(function: function, types: [foo]).text

        XCTAssertTrue(
            text.contains("foo->second"),
            "a struct-pointer arg deref at a field offset should render `arg->field`; got:\n\(text)"
        )
        XCTAssertFalse(
            text.contains("+ 0x8"),
            "the raw offset dereference must not leak once field access applies; got:\n\(text)"
        )
    }

    /// Without an applied struct-pointer type, the dereference stays the plain
    /// `*(base + off)` form — field sugar must be opt-in via the type catalog.
    func testUntypedArgumentDereferenceStaysRawOffset() throws {
        let rows = [
            InstructionRow(
                address: 0x1000_00000,
                bytes: "00 04 40 f9",
                mnemonic: "ldr",
                operands: "x0, [x0, #0x8]",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1000_00004,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]

        let function = MacIRBuilder().buildFunction(name: "_raw", instructions: rows)
        let text = PseudocodePrinter().print(function: function).text

        XCTAssertTrue(text.contains("+ 0x8"), "no applied type → raw offset deref; got:\n\(text)")
        XCTAssertFalse(text.contains("->"), "no field sugar without a type; got:\n\(text)")
    }

    /// Decompiler-readability increment 4 (locals): a struct-pointer field type propagates
    /// through loads, so `tmp = a->next; *(tmp + off)` — where `tmp` is a register, not an
    /// argument — also renders as `tmp->field` (the pointer-chase idiom).
    func testStructPointerTypePropagatesThroughFieldLoads() throws {
        // struct Node { int64_t value; struct Node * next; }  → value@0x0, next@0x8
        let node = TypeDefinition(kind: .struct, name: "Node", fields: [
            FieldDef(name: "value", type: "int64_t"),
            FieldDef(name: "next", type: "struct Node *")
        ])
        let rows = [
            InstructionRow(
                address: 0x1000_00000, bytes: "01 04 40 f9", mnemonic: "ldr",
                operands: "x1, [x0, #0x8]", hasBreakpoint: false, comment: nil   // x1 = a->next
            ),
            InstructionRow(
                address: 0x1000_00004, bytes: "20 04 40 f9", mnemonic: "ldr",
                operands: "x0, [x1, #0x8]", hasBreakpoint: false, comment: nil   // x0 = x1->next (propagated)
            ),
            InstructionRow(
                address: 0x1000_00008, bytes: "c0 03 5f d6", mnemonic: "ret",
                operands: "", hasBreakpoint: false, comment: nil
            )
        ]

        var function = MacIRBuilder().buildFunction(name: "_walk", instructions: rows)
        function.parameters = [MacIRFunctionParameter(index: 0, register: "x0", type: "struct Node *", name: "a")]

        let text = PseudocodePrinter().print(function: function, types: [node]).text

        let hops = text.components(separatedBy: "->next").count - 1
        XCTAssertEqual(hops, 2, "both the argument hop AND the propagated-register hop should sugar; got:\n\(text)")
        XCTAssertFalse(text.contains("+ 0x8"), "no raw offset dereference should remain; got:\n\(text)")
    }

    /// Increment 4 through the real-world reachable path: the full public print overload with
    /// a signature override (as scripting/the editor use it) AND a scratch register (x8, which
    /// gets a `tmp` display binding) as the propagated base — mirrors /bin/ls sub_0x…071c.
    func testStructPointerPropagationThroughPublicOverloadAndTempRegister() throws {
        // struct S { … mid@0x30 … target@0x60 : struct S * }  (13 int64_t-width fields)
        let s = TypeDefinition(kind: .struct, name: "S", fields: (0..<13).map { i in
            FieldDef(name: i == 6 ? "mid" : (i == 12 ? "target" : "f\(i)"), type: i == 12 ? "struct S *" : "int64_t")
        })
        let rows = [
            InstructionRow(address: 0x1000_00000, bytes: "28 00 40 f9", mnemonic: "ldr", operands: "x8, [x1, #0x60]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00004, bytes: "0a 01 40 f9", mnemonic: "ldr", operands: "x10, [x8, #0x30]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00008, bytes: "0b 01 40 f9", mnemonic: "ldr", operands: "x11, [x8, #0x38]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0000c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let sig = FunctionSignatureOverride(
            returnType: "int",
            args: [ArgOverride(index: 0, name: "a", type: "struct S *"), ArgOverride(index: 1, name: "b", type: "struct S *")],
            isNoReturn: false
        )
        let text = PseudocodePrinter().print(
            functionName: "_r",
            startAddress: 0x1000_00000,
            signatureOverrides: [0x1000_00000: sig],
            types: [s],
            instructions: rows
        ).text

        // x8 is consumed as the address base of the next two loads. Record-pointer
        // consumer collection therefore preserves its pointer representation in SSA
        // as well as legacy; an integer-only consumer would still require the cast.
        let loaded = "= b->target"
        XCTAssertTrue(text.contains(loaded), "argument field access; got:\n\(text)")
        XCTAssertTrue(text.contains("->mid"), "propagated field access through the loaded pointer; got:\n\(text)")
        XCTAssertFalse(text.contains("+ 0x30"), "no raw offset dereference should remain for the propagated base; got:\n\(text)")
    }

    /// Decompiler-readability increment 5: a bare `*(base)` deref (offset 0) of a struct
    /// pointer renders as `base->firstField` — the first field never got sugar before because
    /// increment 1 collapses `[base, #0]` to a bare `base` (no `+ offset` expression).
    func testStructPointerFirstFieldDereferenceRendersFieldAccess() throws {
        // struct S { int64_t head; int64_t tail; }  → head@0x0, tail@0x8
        let s = TypeDefinition(kind: .struct, name: "S", fields: [
            FieldDef(name: "head", type: "int64_t"),
            FieldDef(name: "tail", type: "int64_t")
        ])
        let rows = [
            InstructionRow(
                address: 0x1000_00000, bytes: "00 00 40 f9", mnemonic: "ldr",
                operands: "x0, [x0]", hasBreakpoint: false, comment: nil   // x0 = a->head (offset 0)
            ),
            InstructionRow(
                address: 0x1000_00004, bytes: "c0 03 5f d6", mnemonic: "ret",
                operands: "", hasBreakpoint: false, comment: nil
            )
        ]

        var function = MacIRBuilder().buildFunction(name: "_head", instructions: rows)
        function.parameters = [MacIRFunctionParameter(index: 0, register: "x0", type: "struct S *", name: "a")]

        let text = PseudocodePrinter().print(function: function, types: [s]).text

        XCTAssertTrue(text.contains("a->head"), "offset-0 deref should render first-field access; got:\n\(text)")
        XCTAssertFalse(text.contains("*(a)"), "the bare pointer dereference should not remain; got:\n\(text)")
    }
}

private func unknownDirectCallFrame(
    target: String,
    gprValues: [Int: MacIRValue]
) throws -> MacIRCallFrame {
    try unknownCallFrame(
        target: target,
        controlInputs: .none,
        eligibleGPRIndices: Set(0..<8),
        gprValues: gprValues
    )
}

private func unknownIndirectCallFrame(
    targetRegister: Int,
    targetValue: MacIRValue,
    gprValues: [Int: MacIRValue]
) throws -> MacIRCallFrame {
    let targetControl = MacIRCallControlInput(
        role: .indirectTarget,
        register: .gpr(index: targetRegister),
        value: targetValue
    )
    let controlInputs = try XCTUnwrap(MacIRCallControlInputs([targetControl]))
    var eligibleGPRIndices = Set(0..<8)
    eligibleGPRIndices.remove(targetRegister)
    return try unknownCallFrame(
        target: "(*x\(targetRegister))",
        controlInputs: controlInputs,
        eligibleGPRIndices: eligibleGPRIndices,
        gprValues: gprValues
    )
}

private func unknownCallFrame(
    target: String,
    controlInputs: MacIRCallControlInputs,
    eligibleGPRIndices: Set<Int>,
    gprValues: [Int: MacIRValue]
) throws -> MacIRCallFrame {
    let observationScope = try XCTUnwrap(
        MacIRCallArgumentObservationScope(gprIndices: eligibleGPRIndices)
    )
    let arguments = gprValues.map { index, value in
        MacIRCallArgument(
            location: .gpr(index: index, carrierWidth: 64),
            role: .unknown,
            value: value
        )
    }
    let validatedArguments = try XCTUnwrap(
        MacIRCallArguments(arguments, observationScope: observationScope)
    )
    return try XCTUnwrap(
        MacIRCallFrame(
            target: target,
            knownSignature: nil,
            controlInputs: controlInputs,
            arguments: validatedArguments
        )
    )
}

private func knownCallFrame(
    signature: MacIRCallSignature,
    fixedValues: [Int: MacIRValue]
) throws -> MacIRCallFrame {
    let arguments = try fixedValues.map { sourcePosition, value in
        let parameter = try XCTUnwrap(
            signature.parameters.first { $0.index == sourcePosition }
        )
        let location = try XCTUnwrap(MacIRCallArgumentLocation(register: parameter.register))
        return MacIRCallArgument(
            location: location,
            role: .fixed(sourcePosition: sourcePosition),
            value: value
        )
    }
    let validatedArguments = try XCTUnwrap(MacIRCallArguments(arguments))
    return try XCTUnwrap(
        MacIRCallFrame(
            target: signature.target,
            knownSignature: signature,
            controlInputs: .none,
            arguments: validatedArguments
        )
    )
}

private func firstCallFrame(in function: MacIRFunction) throws -> MacIRCallFrame {
    let frames = function.instructions.compactMap { instruction -> MacIRCallFrame? in
        if case let .call(frame, _) = instruction.operation {
            return frame
        }
        return nil
    }
    return try XCTUnwrap(frames.first)
}

/// The pre-WS14 decompiler assertions in this file pin the recovered register
/// slot and type. Row identity, source ordering, naming policy, and evidence are
/// covered by the dedicated parameter-identity suites.
private func legacyParameterShape(
    _ parameters: [MacIRFunctionParameter]
) -> [MacIRFunctionParameter] {
    parameters.map {
        MacIRFunctionParameter(index: $0.index, register: $0.register, type: $0.type)
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}

// DP11: these guard tests used to sit inside `private extension Array`, where
// XCTest never discovered them.
extension DecompilerCoreTests {
    /// ADR03-N01: a call that receives a stack slot's address may write the
    /// slot, so a reload after the call must not forward the pre-call value.
    func testCallReceivingStackAddressInvalidatesCachedSlot() {
        func rows(passAddress: Bool) -> [InstructionRow] {
            var text: [(String, String)] = [("sub", "sp, sp, #0x20"), ("str", "x0, [sp, #0x8]")]
            text.append(passAddress ? ("add", "x0, sp, #0x8") : ("mov", "x0, x2"))
            text += [("bl", "_writer"), ("ldr", "x1, [sp, #0x8]"), ("mov", "x0, x1"),
                     ("add", "sp, sp, #0x20"), ("ret", "")]
            return text.enumerated().map { index, pair in
                InstructionRow(address: 0x1000_0f000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                               operands: pair.1, hasBreakpoint: false, comment: nil)
            }
        }
        func reload(_ function: MacIRFunction) -> MacIROperation? {
            function.instructions.first { $0.source.address == 0x1000_0f010 }?.operation
        }
        let control = MacIRBuilder().buildFunction(name: "no_escape", instructions: rows(passAddress: false))
        guard case .stackSlotRead = reload(control) else {
            return XCTFail("control: a slot whose address never escapes still forwards: \(String(describing: reload(control)))")
        }
        let escaped = MacIRBuilder().buildFunction(name: "escape", instructions: rows(passAddress: true))
        if case .stackSlotRead = reload(escaped) {
            XCTFail("reload after a call that received &slot forwarded the pre-call value")
        }
        // Same through the frame pointer: `sub x0, x29, #0x8` passes &slot.
        func framed(passAddress: Bool) -> [InstructionRow] {
            var text: [(String, String)] = [("stp", "x29, x30, [sp, #-0x10]!"), ("mov", "x29, sp"),
                                            ("sub", "sp, sp, #0x20"), ("stur", "x0, [x29, #-0x8]")]
            text.append(passAddress ? ("sub", "x0, x29, #0x8") : ("mov", "x0, x2"))
            text += [("bl", "_writer"), ("ldur", "x1, [x29, #-0x8]"), ("mov", "x0, x1"),
                     ("mov", "sp, x29"), ("ldp", "x29, x30, [sp], #0x10"), ("ret", "")]
            return text.enumerated().map { index, pair in
                InstructionRow(address: 0x1000_0f100 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                               operands: pair.1, hasBreakpoint: false, comment: nil)
            }
        }
        func framedReload(_ function: MacIRFunction) -> MacIROperation? {
            function.instructions.first { $0.source.address == 0x1000_0f118 }?.operation
        }
        // x29-relative slots are not cached as stack slots today, so only the
        // escaped case is asserted (it must never forward).
        let framedEscape = MacIRBuilder().buildFunction(name: "fp_escape", instructions: framed(passAddress: true))
        if case .stackSlotRead = framedReload(framedEscape) {
            XCTFail("reload through x29 after a call that received &slot forwarded the pre-call value")
        }
    }

    /// A stack address stored to memory has escaped: any later call may write
    /// the slot through it, so a reload after the call must not forward.
    func testStackAddressEscapingThroughMemoryInvalidatesSlotAtLaterCall() {
        func rows(storePointer: Bool) -> [InstructionRow] {
            var text: [(String, String)] = [("sub", "sp, sp, #0x20"), ("str", "x0, [sp, #0x8]"),
                                            ("add", "x9, sp, #0x8")]
            text.append(storePointer ? ("str", "x9, [x1]") : ("mov", "x10, x1"))
            text += [("mov", "x9, #0x0"), ("bl", "_writer"), ("ldr", "x2, [sp, #0x8]"),
                     ("mov", "x0, x2"), ("add", "sp, sp, #0x20"), ("ret", "")]
            return text.enumerated().map { index, pair in
                InstructionRow(address: 0x1000_0f200 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                               operands: pair.1, hasBreakpoint: false, comment: nil)
            }
        }
        func reload(_ function: MacIRFunction) -> MacIROperation? {
            function.instructions.first { $0.source.address == 0x1000_0f218 }?.operation
        }
        let control = MacIRBuilder().buildFunction(name: "kept", instructions: rows(storePointer: false))
        guard case .stackSlotRead = reload(control) else {
            return XCTFail("control: an address that never escapes keeps forwarding: \(String(describing: reload(control)))")
        }
        let escaped = MacIRBuilder().buildFunction(name: "escaped", instructions: rows(storePointer: true))
        if case .stackSlotRead = reload(escaped) {
            XCTFail("a stack address stored to memory escaped; the call may write the slot")
        }
    }

    /// DP01 #633: an extended W index is extended to 64 bits before the shift.
    func testExtendedWIndexExtendsBeforeShift() {
        func address(_ operands: String) -> MacIRValue? {
            let rows = [InstructionRow(address: 0x1000_0f300, bytes: "", mnemonic: "ldr", operands: operands,
                                       hasBreakpoint: false, comment: nil),
                        InstructionRow(address: 0x1000_0f304, bytes: "", mnemonic: "ret", operands: "",
                                       hasBreakpoint: false, comment: nil)]
            let function = MacIRBuilder().buildFunction(name: "index", instructions: rows)
            guard case let .load(_, address)? = function.instructions.first?.operation else { return nil }
            return address
        }
        guard case let .binaryExpression("+", _, .binaryExpression("<<", index, .immediate(3)))? =
                address("x0, [x1, w2, uxtw #3]"),
              case .unary("(uint64_t)", .unary("(uint32_t)", _)) = index else {
            return XCTFail("uxtw extends to 64 bits before shifting: \(address("x0, [x1, w2, uxtw #3]"))")
        }
        guard case let .binaryExpression("+", _, .binaryExpression("<<", signed, .immediate(2)))? =
                address("w0, [x1, w2, sxtw #2]"),
              case .unary("(int64_t)", .unary("(int32_t)", _)) = signed else {
            return XCTFail("sxtw sign-extends before shifting: \(address("w0, [x1, w2, sxtw #2]"))")
        }
        // The DP01 witness: an SP-based Q load (region path since #633).
        guard case let .binaryExpression("+", _, .binaryExpression("<<", qIndex, .immediate(4)))? =
                address("q0, [sp, w9, uxtw #4]"),
              case .unary("(uint64_t)", .unary("(uint32_t)", _)) = qIndex else {
            return XCTFail("SP+W Q load extends before shifting: \(String(describing: address("q0, [sp, w9, uxtw #4]")))")
        }
        // An X index with LSL needs no extension.
        guard case let .binaryExpression("+", _, .binaryExpression("<<", xIndex, .immediate(3)))? =
                address("x0, [x1, x2, lsl #3]") else {
            return XCTFail("lsl keeps the X index: \(String(describing: address("x0, [x1, x2, lsl #3]")))")
        }
        if case .unary = xIndex { XCTFail("an X index with lsl gains no extension cast: \(xIndex)") }
    }
}


/// Snapshot adapters retain all statement text and inspect only typed annotations.
enum SSARenderExpectation {
    static func withoutRefusalAnnotations(_ document: PseudocodeDocument, function: MacIRFunction,
        expected: [(MacIRRefusal.Reason, MacIRRefusal.Scope)],
        file: StaticString = #filePath, line: UInt = #line) -> String {
        let annotations = document.lines.filter { $0.refusal != nil }
        XCTAssertEqual(annotations.count, expected.count, file: file, line: line)
        XCTAssertEqual(function.refusals.count, expected.count, file: file, line: line)
        for (reason, scope) in expected {
            let matching = function.refusals.filter { $0.reason == reason && $0.scope == scope }
            XCTAssertEqual(matching.count, 1, file: file, line: line)
            guard let refusal = matching.first else { continue }
            let emitted = annotations.filter { $0.refusal == refusal }
            XCTAssertEqual(emitted.count, 1, file: file, line: line)
            guard let annotation = emitted.first else { continue }
            XCTAssertEqual(annotation.kind, .metadata, file: file, line: line)
            XCTAssertEqual(annotation.text.trimmingCharacters(in: .whitespaces),
                "// refusal: " + (refusal.detail ?? reason.rawValue), file: file, line: line)
            switch scope {
            case let .row(address), let .cell(_, address):
                XCTAssertEqual(annotation.source?.address, address, file: file, line: line)
            default: break
            }
            XCTAssertNil(annotation.sourceAddress, "an annotation is not an extra machine statement", file: file, line: line)
        }
        return document.lines.filter { $0.refusal == nil }.map(\.text).joined(separator: "\n")
    }

    static func assertEntryBackedgeRefusal(_ function: MacIRFunction,
        file: StaticString = #filePath, line: UInt = #line) {
        guard SSAPropertyAssertions.enabled else { return }
        let refusals = function.refusals.filter { $0.detail == "entry block has an in-graph predecessor" }
        XCTAssertEqual(refusals.count, 1, file: file, line: line)
        XCTAssertEqual(refusals.first?.scope, .function, file: file, line: line)
        XCTAssertEqual(refusals.first?.reason, .unknownEffects, file: file, line: line)
        XCTAssertNil(function.ssaInfo, file: file, line: line)
    }
}

extension SSARenderExpectation {
    static func assertRejoiningPhi(_ function: MacIRFunction, block: UInt64,
        entryPredecessor: UInt64, definingPredecessor: UInt64, definitionAddress: UInt64,
        file: StaticString = #filePath, line: UInt = #line) {
        let phis = function.phis.filter {
            $0.blockAddress == block && SSAPropertyAssertions.physicalCell($0.destination) == 0
        }
        XCTAssertEqual(phis.count, 1, file: file, line: line)
        guard let phi = phis.first else { return }
        XCTAssertEqual(phi.bitWidth, 64, file: file, line: line)
        XCTAssertEqual(phi.incoming.map(\.machineAddress), [entryPredecessor, definingPredecessor], file: file, line: line)
        guard phi.incoming.count == 2 else { return }
        let parameter = function.parameters.first { $0.bindingID == .gpr(0) }
        XCTAssertNotNil(parameter, file: file, line: line)
        XCTAssertEqual(phi.incoming[0].value, .argument(bindingID: .gpr(0)), file: file, line: line)
        let definitions = function.instructions.filter { $0.source.address == definitionAddress }
            .flatMap { SSAPropertyAssertions.definitions($0.operation) }
            .filter { SSAPropertyAssertions.physicalCell($0) == 0 }
        XCTAssertEqual(definitions.count, 1, file: file, line: line)
        XCTAssertEqual(phi.incoming[1].value, definitions.first, file: file, line: line)
        SSAPropertyAssertions.assertOrdinaryUsesDominated(function, file: file, line: line)
    }

    /// Resolve the raw parallel-copy snapshots and compare each predecessor's
    /// final expression with the structured edge copy, independently of labels.
    static func assertEdgeCopyAgreement(_ structured: PseudocodeDocument, _ raw: PseudocodeDocument,
        function: MacIRFunction, file: StaticString = #filePath, line: UInt = #line) {
        func expression(_ document: PseudocodeDocument, identity: MacIRPhiEdgeIdentity) -> [String]? {
            let copies = document.lines.filter { $0.syntheticPhiEdge == identity && $0.kind == .instruction }
            XCTAssertFalse(copies.isEmpty, "each incoming needs its own edge copy", file: file, line: line)
            var snapshots: [String: [String]] = [:]
            var last: [String]?
            for copy in copies {
                XCTAssertNil(copy.sourceAddress, file: file, line: line)
                // c9ed0a1ee: the flat renderer's taken-edge stub label and its
                // trailing goto carry the edge identity as synthetic control;
                // only the assignments between them are phi copies.
                let trimmed = copy.text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(":") || trimmed.hasPrefix("goto ") { continue }
                guard let tokens = try? OrdinaryC.lex(copy.text).map(\.text),
                      let equal = tokens.firstIndex(of: "="), equal > 0,
                      tokens.last == ";" else {
                    XCTFail("edge copy must remain an assignment: \(copy.text)", file: file, line: line)
                    continue
                }
                let rhs = tokens[(equal + 1)..<(tokens.count - 1)].flatMap { snapshots[$0] ?? [$0] }
                snapshots[tokens[equal - 1]] = rhs
                last = rhs
            }
            return last
        }
        for phi in function.phis where SSAPropertyAssertions.physicalCell(phi.destination) != nil {
            for incoming in phi.incoming {
                let identity = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                    predecessor: incoming.predecessor, destination: phi.destination)
                XCTAssertEqual(expression(structured, identity: identity), expression(raw, identity: identity),
                    "structured and raw forms must copy the same predecessor value", file: file, line: line)
            }
        }
    }
}

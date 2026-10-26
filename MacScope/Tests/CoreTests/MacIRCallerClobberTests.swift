import XCTest
@testable import MacScope

/// WS-13: returning calls are physical-state barriers. These tests intentionally
/// assert direct MacIR so dead-store rewriting and printer formatting cannot hide
/// a stale value, a fabricated parameter, or a phantom SSA definition.
final class MacIRCallerClobberTests: XCTestCase {
    func testKnownEntryCallsSeedRealFormalsBeforeSuppressingPostCallFormals() throws {
        let integer = build([
            row(0x1000, "bl", "_strlen"),
            row(0x1004, "mov", "x8, x1"),
            row(0x1008, "ret"),
        ])

        XCTAssertEqual(integer.parameters.map(\.register), ["x0"])
        XCTAssertEqual(integer.parameters.map(\.type), ["const char *"])
        let strlen = try callPayload(in: integer, target: "_strlen")
        assertFixedArgument(
            strlen.frame,
            at: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            value: .argument(bindingID: .gpr(0))
        )
        XCTAssertEqual(strlen.frame.arguments.denseFixedPrefixValues(), [
            .argument(bindingID: .gpr(0)),
        ])
        XCTAssertEqual(strlen.result, .register(name: "x0", version: 1))
        assertAssignSource(integer, at: 1, equals: .unknown("unavailable_x1"))

        let floating = build([
            row(0x2000, "bl", "_sin"),
            row(0x2004, "fmov", "x8, d1"),
            row(0x2008, "ret"),
        ])

        XCTAssertEqual(floating.parameters.map(\.register), ["d0"])
        XCTAssertEqual(floating.parameters.map(\.type), ["double"])
        let sin = try callPayload(in: floating, target: "_sin")
        XCTAssertEqual(sin.frame.arguments.count, 1)
        let sinInput = try XCTUnwrap(sin.frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(sinInput.location, .simd(index: 0, scalarWidth: 64))
        guard case let .argument(bindingID) = sinInput.value else {
            return XCTFail("expected the known _sin input to remain a recovered pre-call formal")
        }
        XCTAssertEqual(bindingID, .simd(0))
        XCTAssertEqual(sin.result, .register(name: "d0", version: 1))
        assertIntrinsicArgument(floating, at: 1, equals: .unknown("unavailable_d1"))
    }

    func testUnknownCallCapturesOnlyPreCallStateAndProjectsFreshX0Result() throws {
        let function = build([
            row(0x1000, "mov", "w0, #7"),
            row(0x1004, "bl", "_opaque"),
            row(0x1008, "mov", "x8, x1"),
            row(0x100c, "mov", "w9, w0"),
            row(0x1010, "ret"),
        ])

        XCTAssertTrue(function.parameters.isEmpty)
        let call = try callPayload(in: function, target: "_opaque")
        assertUnknownArgument(
            call.frame,
            at: .gpr(index: 0),
            location: .gpr(index: 0, carrierWidth: 32),
            value: .register(name: "w0", version: 1)
        )
        XCTAssertEqual(
            call.frame.arguments.denseUnknownGPRPrefixValues(),
            [.register(name: "w0", version: 1)]
        )
        if SSAPropertyAssertions.enabled {
            let result = try assertFreshCallResult(function, target: "_opaque", width: 64)
            let projected = MacIRValue.unary(op: "(uint32_t)", value: result)
            assertAssignSource(function, at: 3, equals: projected)
            XCTAssertEqual(PseudocodePrinter().valueText(for: projected,
                names: PseudocodeNameContext(function: function)), "(uint32_t)(\(result))")
        } else {
            XCTAssertEqual(call.result, .register(name: "x0", version: 1))
            assertAssignSource(
                function,
                at: 3,
                equals: .unary(op: "(uint32_t)", value: .register(name: "x0", version: 1))
            )
        }
        assertAssignSource(function, at: 2, equals: .unknown("unavailable_x1"))
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testVariadicCallCannotAcquireRetroactivePostCallArgument() throws {
        let function = build([
            row(0x1000, "mov", "x0, #0x1000"),
            row(0x1004, "bl", "_printf"),
            row(0x1008, "mov", "x8, x1"),
            row(0x100c, "mov", "x9, x0"),
            row(0x1010, "ret"),
        ])

        XCTAssertTrue(function.parameters.isEmpty)
        let call = try callPayload(in: function, target: "_printf")
        assertFixedArgument(
            call.frame,
            at: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            value: .register(name: "x0", version: 1)
        )
        XCTAssertEqual(call.frame.arguments.denseFixedPrefixValues(), [
            .register(name: "x0", version: 1),
        ])
        XCTAssertNil(call.frame.tailCountEvidence?.expectedTailCount)
        if SSAPropertyAssertions.enabled {
            let result = try assertFreshCallResult(function, target: "_printf", width: 32)
            let projected = MacIRValue.unary(op: "(uint64_t)",
                value: .unary(op: "(uint32_t)", value: result))
            assertAssignSource(function, at: 3, equals: projected)
            XCTAssertEqual(PseudocodePrinter().valueText(for: projected,
                names: PseudocodeNameContext(function: function)), "(uint64_t)((uint32_t)(\(result)))")
            XCTAssertEqual(call.frame.arguments.canonicalPhysicalEntriesForAudit.map(\.value),
                [.register(name: "x0", version: 1)],
                "the complete argument list contains only the pre-call format value")
        } else {
            XCTAssertEqual(call.result, .register(name: "w0", version: 1))
            assertAssignSource(
                function,
                at: 3,
                equals: .unary(
                    op: "(uint64_t)",
                    value: .unary(op: "(uint32_t)", value: .register(name: "w0", version: 1))
                )
            )
        }
        assertAssignSource(function, at: 2, equals: .unknown("unavailable_x1"))
    }

    func testIntegerBoundaryInvalidatesX0ThroughX18AndPreservesX19ThroughX28() {
        for index in 0...18 {
            let register = "x\(index)"
            let function = build([
                row(0x1000, "mov", "\(register), #\(index + 1)"),
                row(0x1004, "bl", "_arc4random_stir"),
                row(0x1008, "mov", "x19, \(register)"),
                row(0x100c, "ret"),
            ])
            assertAssignSource(
                function,
                at: 2,
                equals: .unknown("unavailable_\(register)"),
                message: "Apple call boundary must invalidate \(register)"
            )
        }

        for index in 19...28 {
            let register = "x\(index)"
            let function = build([
                row(0x2000, "mov", "\(register), #\(index + 1)"),
                row(0x2004, "bl", "_arc4random_stir"),
                row(0x2008, "mov", "x0, \(register)"),
                row(0x200c, "ret"),
            ])
            assertAssignSource(
                function,
                at: 2,
                equals: .register(name: register, version: 1),
                message: "Apple call boundary must preserve \(register)"
            )
        }
    }

    func testCallTombstonesBothIntegerWidthsWithoutConsumingSSAVersion() {
        let function = build([
            row(0x1000, "mov", "x1, #1"),
            row(0x1004, "bl", "_arc4random_stir"),
            row(0x1008, "mov", "x19, x1"),
            row(0x100c, "mov", "w20, w1"),
            row(0x1010, "mov", "x1, #2"),
            row(0x1014, "mov", "w21, w1"),
            row(0x1018, "ret"),
        ])

        assertAssignSource(function, at: 2, equals: .unknown("unavailable_x1"))
        assertAssignSource(function, at: 3, equals: .unknown("unavailable_w1"))
        XCTAssertEqual(
            function.instructions[4].operation,
            .assign(destination: .register(name: "x1", version: 2), source: .immediate(2))
        )
        assertAssignSource(
            function,
            at: 5,
            equals: .unary(op: "(uint32_t)", value: .register(name: "x1", version: 2))
        )
    }

    func testLinkRegisterIsUnavailableButFramePointerAndSPRemainLive() {
        let function = build([
            row(0x1000, "mov", "lr, #0x1234"),
            row(0x1004, "mov", "fp, sp"),
            row(0x1008, "bl", "_arc4random_stir"),
            row(0x100c, "mov", "x0, lr"),
            row(0x1010, "mov", "x1, x30"),
            row(0x1014, "mov", "w2, w30"),
            row(0x1018, "mov", "x3, fp"),
            row(0x101c, "mov", "w4, w29"),
            row(0x1020, "mov", "x5, sp"),
            row(0x1024, "ret"),
        ])

        assertAssignSource(function, at: 3, equals: .unknown("unavailable_lr"))
        assertAssignSource(function, at: 4, equals: .unknown("unavailable_x30"))
        assertAssignSource(function, at: 5, equals: .unknown("unavailable_w30"))
        assertAssignSource(function, at: 6, equals: .register(name: "fp", version: 1))
        assertAssignSource(
            function,
            at: 7,
            equals: .unary(op: "(uint32_t)", value: .register(name: "fp", version: 1))
        )
        assertAssignSource(function, at: 8, equals: .register(name: "sp", version: 0))
    }

    func testLinkRegisterResurrectionUsesNextRealVersionAndFeedsX30Views() {
        let function = build([
            row(0x1000, "mov", "lr, #1"),
            row(0x1004, "bl", "_arc4random_stir"),
            row(0x1008, "mov", "x19, lr"),
            row(0x100c, "mov", "lr, #2"),
            row(0x1010, "mov", "x20, x30"),
            row(0x1014, "mov", "w21, w30"),
            row(0x1018, "ret"),
        ])

        assertAssignSource(function, at: 2, equals: .unknown("unavailable_lr"))
        XCTAssertEqual(
            function.instructions[3].operation,
            .assign(destination: .register(name: "lr", version: 2), source: .immediate(2))
        )
        assertAssignSource(function, at: 4, equals: .register(name: "lr", version: 2))
        assertAssignSource(
            function,
            at: 5,
            equals: .unary(op: "(uint32_t)", value: .register(name: "lr", version: 2))
        )
    }

    func testKnownVoidCallExposesNoStaleResult() throws {
        let function = build([
            row(0x1000, "mov", "x0, #0x1000"),
            row(0x1004, "bl", "_free"),
            row(0x1008, "mov", "x8, x0"),
            row(0x100c, "mov", "w9, w0"),
            row(0x1010, "ret"),
        ])

        let call = try callPayload(in: function, target: "_free")
        assertFixedArgument(
            call.frame,
            at: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            value: .register(name: "x0", version: 1)
        )
        XCTAssertEqual(call.frame.arguments.denseFixedPrefixValues(), [
            .register(name: "x0", version: 1),
        ])
        XCTAssertNil(call.result)
        assertAssignSource(function, at: 2, equals: .unknown("unavailable_x0"))
        assertAssignSource(function, at: 3, equals: .unknown("unavailable_w0"))
        XCTAssertNil(function.returnValue)
        XCTAssertEqual(function.instructions.last?.operation, .returnValue(nil))
    }

    func testKnownIntegerResultDoesNotResurrectScalarFPResultState() throws {
        let function = build([
            row(0x1000, "mov", "x0, #0x1000"),
            row(0x1004, "fmov", "d0, #2.0"),
            row(0x1008, "bl", "_strlen"),
            row(0x100c, "fmov", "x8, d0"),
            row(0x1010, "ret"),
        ])

        XCTAssertEqual(
            try callPayload(in: function, target: "_strlen").result,
            .register(name: "x0", version: 2)
        )
        assertIntrinsicArgument(function, at: 3, equals: .unknown("unavailable_d0"))
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testKnownScalarFPResultsResurrectOnlyTheirExactView() throws {
        let cases: [(target: String, input: String, outputGPR: String, sibling: String, siblingGPR: String)] = [
            ("_sin", "d0", "x8", "s0", "w9"),
            ("_sinf", "s0", "w8", "d0", "x9"),
        ]

        for testCase in cases {
            let function = build([
                row(0x1000, "mov", "x0, #7"),
                row(0x1004, "fmov", "\(testCase.input), #2.0"),
                row(0x1008, "bl", testCase.target),
                row(0x100c, "mov", "x10, x0"),
                row(0x1010, "fmov", "\(testCase.outputGPR), \(testCase.input)"),
                row(0x1014, "fmov", "\(testCase.siblingGPR), \(testCase.sibling)"),
                row(0x1018, "ret"),
            ])

            let expectedResult = MacIRValue.register(name: testCase.input, version: 2)
            XCTAssertEqual(try callPayload(in: function, target: testCase.target).result, expectedResult)
            assertAssignSource(function, at: 3, equals: .unknown("unavailable_x0"))
            assertIntrinsicArgument(function, at: 4, equals: expectedResult)
            assertIntrinsicArgument(
                function,
                at: 5,
                equals: .unknown("unavailable_\(testCase.sibling)")
            )
        }
    }

    func testScalarFPBoundaryPinsExactVolatileAndPreservedEdges() {
        for index in [7, 16, 31] {
            let double = build([
                row(0x1000, "fmov", "d\(index), #1.0"),
                row(0x1004, "bl", "_arc4random_stir"),
                row(0x1008, "fmov", "x19, d\(index)"),
                row(0x100c, "ret"),
            ])
            assertIntrinsicArgument(double, at: 2, equals: .unknown("unavailable_d\(index)"))

            let single = build([
                row(0x1100, "fmov", "s\(index), #2.0"),
                row(0x1104, "bl", "_arc4random_stir"),
                row(0x1108, "fmov", "w20, s\(index)"),
                row(0x110c, "ret"),
            ])
            assertIntrinsicArgument(single, at: 2, equals: .unknown("unavailable_s\(index)"))
        }

        for index in [8, 15] {
            let double = build([
                row(0x2000, "fmov", "d\(index), #1.0"),
                row(0x2004, "bl", "_arc4random_stir"),
                row(0x2008, "fmov", "x19, d\(index)"),
                row(0x200c, "ret"),
            ])
            assertIntrinsicArgument(double, at: 2, equals: .register(name: "d\(index)", version: 1))

            let single = build([
                row(0x2100, "fmov", "s\(index), #2.0"),
                row(0x2104, "bl", "_arc4random_stir"),
                row(0x2108, "fmov", "w20, s\(index)"),
                row(0x210c, "ret"),
            ])
            assertIntrinsicArgument(single, at: 2, equals: .register(name: "s\(index)", version: 1))
        }
    }

    func testOrdinaryPostCallScalarFPWriteResurrectsOnlyItsExactView() {
        let function = build([
            row(0x1000, "fmov", "d7, #1.0"),
            row(0x1004, "bl", "_arc4random_stir"),
            row(0x1008, "fmov", "d7, #2.0"),
            row(0x100c, "fmov", "x19, d7"),
            row(0x1010, "fmov", "w20, s7"),
            row(0x1014, "ret"),
        ])

        XCTAssertEqual(
            function.instructions[2].operation,
            .assign(destination: .register(name: "d7", version: 2), source: .symbol("2.0"))
        )
        assertIntrinsicArgument(function, at: 3, equals: .register(name: "d7", version: 2))
        assertIntrinsicArgument(function, at: 4, equals: .unknown("unavailable_s7"))
    }

    func testAllReturningCallMnemonicsSuppressPostCallParameterRecovery() throws {
        let cases: [(mnemonic: String, operands: String, setup: [(String, String)], target: String)] = [
            ("bl", "_opaque", [], "_opaque"),
            ("blr", "x9", [("mov", "x9, #0x4000")], "(*x9)"),
            ("blraa", "x9, x10", [("mov", "x9, #0x4000"), ("mov", "x10, #0x5000")], "(*x9)"),
            ("blrab", "x9, x10", [("mov", "x9, #0x4000"), ("mov", "x10, #0x5000")], "(*x9)"),
            ("blraaz", "x9", [("mov", "x9, #0x4000")], "(*x9)"),
            ("blrabz", "x9", [("mov", "x9, #0x4000")], "(*x9)"),
        ]

        for testCase in cases {
            var rows: [InstructionRow] = []
            var address: UInt64 = 0x1000
            for instruction in testCase.setup {
                rows.append(row(address, instruction.0, instruction.1))
                address += 4
            }
            let callIndex = rows.count
            rows.append(row(address, testCase.mnemonic, testCase.operands))
            address += 4
            rows.append(row(address, "mov", "x8, x1"))
            rows.append(row(address + 4, "fmov", "x10, d1"))
            rows.append(row(address + 8, "ret"))

            let function = build(rows)
            XCTAssertTrue(function.parameters.isEmpty, testCase.mnemonic)
            let call = try callPayload(in: function, target: testCase.target)
            XCTAssertTrue(call.frame.arguments.isEmpty, testCase.mnemonic)
            XCTAssertEqual(
                call.frame.arguments.denseUnknownGPRPrefixValues(),
                [],
                testCase.mnemonic
            )
            XCTAssertEqual(call.result, .register(name: "x0", version: 1), testCase.mnemonic)
            assertAssignSource(
                function,
                at: callIndex + 1,
                equals: .unknown("unavailable_x1"),
                message: testCase.mnemonic
            )
            assertIntrinsicArgument(
                function,
                at: callIndex + 2,
                equals: .unknown("unavailable_d1")
            )
        }
    }

    func testIndirectAndAuthenticatedCallsCaptureInputsBeforeBoundary() throws {
        let cases: [(mnemonic: String, operands: String)] = [
            ("blr", "x9"),
            ("blraa", "x9, x10"),
            ("blraa", "x9, sp"),
            ("blrab", "x9, x10"),
            ("blrab", "x9, sp"),
            ("blraaz", "x9"),
            ("blrabz", "x9"),
        ]

        for testCase in cases {
            let function = build([
                row(0x1000, "mov", "x9, #0x4000"),
                row(0x1004, "mov", "x10, #0x5000"),
                row(0x1008, "mov", "x1, #7"),
                row(0x100c, testCase.mnemonic, testCase.operands),
                row(0x1010, "mov", "x19, x1"),
                row(0x1014, "mov", "x20, x9"),
                row(0x1018, "ret"),
            ])

            let call = try callPayload(in: function, target: "(*x9)")
            XCTAssertEqual(
                call.frame.controlInputs.indirectTarget?.register,
                .gpr(index: 9),
                testCase.mnemonic
            )
            XCTAssertEqual(
                call.frame.controlInputs.indirectTarget?.value,
                .register(name: "x9", version: 1),
                testCase.mnemonic
            )
            let expectedModifierRegister: MacIRCallControlRegister? = switch testCase.mnemonic {
            case "blraa", "blrab":
                testCase.operands.hasSuffix(", sp") ? .stackPointer : .gpr(index: 10)
            default:
                nil
            }
            XCTAssertEqual(
                call.frame.controlInputs.pointerAuthenticationModifier?.register,
                expectedModifierRegister,
                testCase.mnemonic
            )
            assertUnknownArgument(
                call.frame,
                at: .gpr(index: 1),
                location: .gpr(index: 1, carrierWidth: 64),
                value: .register(name: "x1", version: 1),
                message: testCase.mnemonic
            )
            XCTAssertEqual(
                call.frame.arguments.denseUnknownGPRPrefixValues(),
                [],
                testCase.mnemonic
            )
            XCTAssertEqual(call.result, .register(name: "x0", version: 1), testCase.mnemonic)
            assertAssignSource(function, at: 4, equals: .unknown("unavailable_x1"), message: testCase.mnemonic)
            assertAssignSource(function, at: 5, equals: .unknown("unavailable_x9"), message: testCase.mnemonic)
        }
    }

    func testMalformedIndirectAndAuthenticatedFormsDoNotApplyReturningCallBoundary() {
        let malformed: [(mnemonic: String, operands: String)] = [
            ("bl", ""),
            ("bl", "#0x4000"),
            ("bl", "x0"),
            ("bl", "w0"),
            ("bl", "d0"),
            ("bl", "q0"),
            ("bl", "sp"),
            ("bl", "xzr"),
            ("bl", "[x9]"),
            ("bl", "_callee, _other"),
            ("blr", "#0x4000"),
            ("blr", "w9"),
            ("blr", "d0"),
            ("blr", "s0"),
            ("blr", "q0"),
            ("blr", "v0"),
            ("blr", "sp"),
            ("blr", "xzr"),
            ("blr", "x31"),
            ("blr", "x999"),
            ("blr", "x01"),
            ("blr", "x9, x10"),
            ("blraaz", "w9"),
            ("blraaz", "x9, x10"),
            ("blrabz", "sp"),
            ("blrabz", "x9, x10"),
            ("blraa", "x9"),
            ("blraa", "w9, x10"),
            ("blraa", "x9, d0"),
            ("blraa", "x9, xzr"),
            ("blraa", "x9, x31"),
            ("blraa", "x9, x010"),
            ("blraa", "x9, x10, x11"),
            ("blrab", "x9"),
            ("blrab", "x9, w10"),
            ("blrab", "x9, v0"),
            ("blrab", "x9, x999"),
            ("blrab", "x9, x10, x11"),
        ]

        for testCase in malformed {
            let function = build([
                row(0x1000, "mov", "x0, #7"),
                row(0x1004, testCase.mnemonic, testCase.operands),
                row(0x1008, "mov", "x19, x0"),
                row(0x100c, "mov", "x20, x1"),
                row(0x1010, "ret"),
            ])

            guard case .unknown = function.instructions[1].operation else {
                XCTFail("malformed \(testCase.mnemonic) \(testCase.operands) must retain its non-call fallback")
                continue
            }
            let context = "\(testCase.mnemonic) \(testCase.operands)"
            XCTAssertTrue(function.callTargets.isEmpty, context)
            XCTAssertEqual(function.parameters.map(\.register), ["x1"], context)
            assertAssignSource(
                function,
                at: 2,
                equals: .register(name: "x0", version: 1),
                message: context
            )
            assertAssignSource(
                function,
                at: 3,
                equals: .argument(bindingID: .gpr(1)),
                message: context
            )
        }
    }

    func testDecodedAuthenticatedSPModifierAppliesReturningCallBoundary() throws {
        let bytes = Data([0x3f, 0x09, 0x3f, 0xd7]) // blraa x9, sp
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x1000)
        XCTAssertEqual(decoded.map(\.operands), ["x9, sp"])

        let function = build(decoded.map { row($0.address, $0.mnemonic, $0.operands) })
        let call = try callPayload(in: function, target: "(*x9)")
        XCTAssertEqual(call.frame.controlInputs.indirectTarget?.register, .gpr(index: 9))
        XCTAssertEqual(
            call.frame.controlInputs.pointerAuthenticationModifier?.register,
            .stackPointer
        )
        XCTAssertTrue(call.frame.arguments.isEmpty)
        XCTAssertEqual(call.result, .register(name: "x0", version: 1))
        XCTAssertTrue(function.parameters.isEmpty)
    }

    func testAuthenticatedCallModifierIsRecoveredAsAnIncomingFormalBeforeTheBoundary() throws {
        for mnemonic in ["blraa", "blrab"] {
            let function = build([
                row(0x1000, "mov", "x9, #0x4000"),
                row(0x1004, mnemonic, "x9, x1"),
                row(0x1008, "ret"),
            ])

            XCTAssertEqual(function.parameters.map(\.register), ["x1"], mnemonic)
            XCTAssertEqual(function.parameters.map(\.type), ["int64_t"], mnemonic)
            let call = try callPayload(in: function, target: "(*x9)")
            XCTAssertEqual(
                call.frame.controlInputs.indirectTarget,
                MacIRCallControlInput(
                    role: .indirectTarget,
                    register: .gpr(index: 9),
                    value: .register(name: "x9", version: 1)
                ),
                mnemonic
            )
            let incomingModifier = MacIRValue.argument(bindingID: .gpr(1))
            XCTAssertEqual(
                call.frame.controlInputs.pointerAuthenticationModifier,
                MacIRCallControlInput(
                    role: .pointerAuthenticationModifier,
                    register: .gpr(index: 1),
                    value: incomingModifier
                ),
                mnemonic
            )
            XCTAssertNil(call.frame.arguments.argument(at: .gpr(index: 1)), mnemonic)
            XCTAssertFalse(
                call.frame.arguments.observationScope.observes(
                    .gpr(index: 1, carrierWidth: 64)
                ),
                mnemonic
            )
            XCTAssertEqual(
                call.frame.bindingValues,
                [.register(name: "x9", version: 1), incomingModifier],
                "the incoming formal remains a binding through explicit control evidence: \(mnemonic)"
            )
            XCTAssertEqual(call.result, .register(name: "x0", version: 1), mnemonic)
        }
    }

    func testAuthenticatedSameRegisterTargetAndModifierRetainIdenticalControlValues() throws {
        for mnemonic in ["blraa", "blrab"] {
            let function = build([
                row(0x1000, mnemonic, "x1, x1"),
                row(0x1004, "ret"),
            ])

            XCTAssertEqual(function.parameters.map(\.register), ["x1"], mnemonic)
            let call = try callPayload(in: function, target: "(*x1)")
            let target = try XCTUnwrap(call.frame.controlInputs.indirectTarget, mnemonic)
            let modifier = try XCTUnwrap(
                call.frame.controlInputs.pointerAuthenticationModifier,
                mnemonic
            )
            XCTAssertEqual(target.register, .gpr(index: 1), mnemonic)
            XCTAssertEqual(modifier.register, .gpr(index: 1), mnemonic)
            XCTAssertEqual(target.value, .argument(bindingID: .gpr(1)), mnemonic)
            XCTAssertEqual(
                target.value,
                modifier.value,
                "one physical source register must retain one identical pre-call value: \(mnemonic)"
            )
            XCTAssertNil(call.frame.arguments.argument(at: .gpr(index: 1)), mnemonic)
            XCTAssertFalse(
                call.frame.arguments.observationScope.observes(
                    .gpr(index: 1, carrierWidth: 64)
                ),
                mnemonic
            )
            XCTAssertEqual(
                call.frame.bindingValues,
                [target.value, target.value],
                "both encoded control occurrences must remain visible: \(mnemonic)"
            )
        }
    }

    func testConsecutiveCallsCarryFreshResultButNotPreFirstCallVolatileInputs() throws {
        let function = build([
            row(0x1000, "mov", "x0, #1"),
            row(0x1004, "mov", "w1, #2"),
            row(0x1008, "bl", "_opaqueA"),
            row(0x100c, "bl", "_opaqueB"),
            row(0x1010, "ret"),
        ])

        let first = try callPayload(in: function, target: "_opaqueA")
        XCTAssertEqual(first.frame.arguments.canonicalPhysicalEntriesForAudit, [
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .unknown,
                value: .register(name: "x0", version: 1)
            ),
            MacIRCallArgument(
                location: .gpr(index: 1, carrierWidth: 32),
                role: .unknown,
                value: .register(name: "w1", version: 1)
            ),
        ])
        XCTAssertEqual(first.frame.arguments.denseUnknownGPRPrefixValues(), [
            .register(name: "x0", version: 1),
            .register(name: "w1", version: 1),
        ])
        XCTAssertEqual(first.result, .register(name: "x0", version: 2))

        let second = try callPayload(in: function, target: "_opaqueB")
        assertUnknownArgument(
            second.frame,
            at: .gpr(index: 0),
            location: .gpr(index: 0, carrierWidth: 64),
            value: .register(name: "x0", version: 2)
        )
        XCTAssertEqual(second.frame.arguments.denseUnknownGPRPrefixValues(), [
            .register(name: "x0", version: 2),
        ])
        XCTAssertEqual(second.result, .register(name: "x0", version: 3))
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testCallClearsNZCVForBranchCsetAndCselConsumers() {
        let branch = build([
            row(0x1000, "cmp", "x19, #0"),
            row(0x1004, "bl", "_opaque"),
            row(0x1008, "b.eq", "0x1010"),
            row(0x100c, "nop"),
            row(0x1010, "ret"),
        ])
        XCTAssertEqual(
            branch.instructions[2].operation,
            .intrinsic(destination: nil, name: "branch_eq", arguments: [.immediate(0x1010)])
        )

        let cset = build([
            row(0x2000, "cmp", "x19, #0"),
            row(0x2004, "bl", "_opaque"),
            row(0x2008, "cset", "w20, eq"),
            row(0x200c, "ret"),
        ])
        guard case .unknown = cset.instructions[2].operation else {
            return XCTFail("cset must not reuse pre-call NZCV")
        }

        let csel = build([
            row(0x3000, "cmp", "x19, #0"),
            row(0x3004, "bl", "_opaque"),
            row(0x3008, "csel", "x20, x21, x22, eq"),
            row(0x300c, "ret"),
        ])
        guard case .unknown = csel.instructions[2].operation else {
            return XCTFail("csel must not reuse pre-call NZCV")
        }
    }

    func testFreshPostCallComparisonRestoresConditionalLifting() {
        let function = build([
            row(0x1000, "cmp", "x19, #0"),
            row(0x1004, "bl", "_opaque"),
            row(0x1008, "cmp", "x19, #1"),
            row(0x100c, "b.eq", "0x1014"),
            row(0x1010, "nop"),
            row(0x1014, "ret"),
        ])

        XCTAssertEqual(
            function.instructions[3].operation,
            .conditionalBranch(
                condition: "==",
                left: .register(name: "x19", version: 0),
                right: .immediate(1),
                target: .immediate(0x1014)
            )
        )
    }

    func testVolatileSelectorProvenanceDiesAndCalleeSavedADRPProvenanceSurvives() throws {
        let selectors: [UInt64: String] = [0x1000_08010: "viewDidLoad"]
        let volatile = build([
            row(0x1000, "adrp", "x1, 0x100008000"),
            row(0x1004, "bl", "_arc4random_stir"),
            row(0x1008, "mov", "x0, #1"),
            row(0x100c, "ldr", "x1, [x1, #0x10]"),
            row(0x1010, "bl", "_objc_msgSend"),
            row(0x1014, "ret"),
        ], objcSelectors: selectors)

        let volatileCall = try callPayload(in: volatile, target: "_objc_msgSend")
        assertFixedArgument(
            volatileCall.frame,
            at: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            value: .register(name: "x0", version: 1)
        )
        assertFixedArgument(
            volatileCall.frame,
            at: 1,
            location: .gpr(index: 1, carrierWidth: 64),
            value: .register(name: "x1", version: 2)
        )
        XCTAssertNil(volatileCall.frame.arguments.fixedArgument(at: 1)?.selectorEvidence)
        XCTAssertNil(volatileCall.frame.tailCountEvidence?.expectedTailCount)
        XCTAssertFalse(PseudocodePrinter().print(function: volatile).text.contains("viewDidLoad"))

        let preserved = build([
            row(0x2000, "adrp", "x19, 0x100008000"),
            row(0x2004, "bl", "_arc4random_stir"),
            row(0x2008, "mov", "x0, #1"),
            row(0x200c, "ldr", "x1, [x19, #0x10]"),
            row(0x2010, "bl", "_objc_msgSend"),
            row(0x2014, "ret"),
        ], objcSelectors: selectors)

        let preservedCall = try callPayload(in: preserved, target: "_objc_msgSend")
        assertFixedArgument(
            preservedCall.frame,
            at: 0,
            location: .gpr(index: 0, carrierWidth: 64),
            value: .register(name: "x0", version: 1)
        )
        let selector = try XCTUnwrap(preservedCall.frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(selector.location, .gpr(index: 1, carrierWidth: 64))
        XCTAssertEqual(selector.value, .register(name: "x1", version: 1))
        XCTAssertEqual(selector.selectorEvidence?.name, "viewDidLoad")
        XCTAssertEqual(selector.selectorEvidence?.selrefAddress, 0x1000_08010)
        XCTAssertEqual(preservedCall.frame.tailCountEvidence?.expectedTailCount, 0)
        XCTAssertEqual(
            preservedCall.frame.arguments.denseFixedPrefixValues(),
            [.register(name: "x0", version: 1), .register(name: "x1", version: 1)]
        )
        XCTAssertEqual(
            preservedCall.frame.denseFixedRenderValues(),
            [.register(name: "x0", version: 1), .symbol("\"viewDidLoad\"")]
        )
    }

    func testCallClearsVolatileButPreservesCalleeSavedMaterializedImmediate() {
        let volatile = build([
            row(0x1000, "mov", "x1, #1"),
            row(0x1004, "bl", "_arc4random_stir"),
            row(0x1008, "movk", "x1, #2, lsl #16"),
            row(0x100c, "ret"),
        ])
        guard case let .assign(_, volatileSource) = volatile.instructions[2].operation else {
            return XCTFail("expected volatile movk to remain a read-modify-write assignment")
        }
        XCTAssertTrue(containsUnknown(volatileSource, named: "unavailable_x1"), "\(volatileSource)")
        XCTAssertNotEqual(volatileSource, .immediate(0x20001))

        let preserved = build([
            row(0x2000, "mov", "x19, #1"),
            row(0x2004, "bl", "_arc4random_stir"),
            row(0x2008, "movk", "x19, #2, lsl #16"),
            row(0x200c, "ret"),
        ])
        XCTAssertEqual(
            preserved.instructions[2].operation,
            .assign(destination: .register(name: "x19", version: 2), source: .immediate(0x20001))
        )
    }

    private func assertFreshCallResult(
        _ function: MacIRFunction, target: String, width: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> MacIRValue {
        let info = try XCTUnwrap(function.ssaInfo, file: file, line: line)
        let beforeRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x1000), file: file, line: line)
        let callRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x1004), file: file, line: line)
        let useRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x100c), file: file, line: line)
        let beforeID = try XCTUnwrap(info.plan.rowWriteBindings[beforeRow][0], file: file, line: line)
        let resultID = try XCTUnwrap(info.plan.rowWriteBindings[callRow][0], file: file, line: line)
        let readID = try XCTUnwrap(info.plan.rowReadBindings[useRow][0], file: file, line: line)
        let definition = info.plan.definitions[resultID]
        XCTAssertEqual(definition.cell, 0, file: file, line: line)
        XCTAssertEqual(definition.bitWidth, width, file: file, line: line)
        XCTAssertEqual(definition.origin, .callResult(target: target), file: file, line: line)
        XCTAssertNotEqual(info.plan.canonicalID(beforeID), info.plan.canonicalID(resultID), file: file, line: line)
        XCTAssertEqual(info.plan.canonicalID(readID), info.plan.canonicalID(resultID), file: file, line: line)
        let result = try XCTUnwrap(info.values[resultID], file: file, line: line)
        let before = try XCTUnwrap(info.values[beforeID], file: file, line: line)
        let call = try callPayload(in: function, target: target)
        XCTAssertEqual(call.result, result, file: file, line: line)
        guard case let .register(resultName, resultVersion) = result,
              case let .register(_, beforeVersion) = before else {
            XCTFail("pre-call and call-result definitions must be registers", file: file, line: line)
            return result
        }
        XCTAssertEqual(resultName, width == 32 ? "w0" : "x0", file: file, line: line)
        XCTAssertNotEqual(resultVersion, beforeVersion,
            "different architectural definitions cannot reuse a cell version", file: file, line: line)
        return result
    }

    private func build(
        _ rows: [InstructionRow],
        objcSelectors: [UInt64: String] = [:]
    ) -> MacIRFunction {
        MacIRBuilder().buildFunction(
            name: "caller_clobber",
            objcSelectors: objcSelectors,
            instructions: rows
        )
    }

    private func row(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String = ""
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }

    private func callPayload(
        in function: MacIRFunction,
        target: String
    ) throws -> (frame: MacIRCallFrame, result: MacIRValue?) {
        for instruction in function.instructions {
            guard case let .call(frame, result) = instruction.operation,
                  frame.target == target else {
                continue
            }
            return (frame, result)
        }
        throw TestFailure.missingCall(target)
    }

    private func assertFixedArgument(
        _ frame: MacIRCallFrame,
        at sourcePosition: Int,
        location expectedLocation: MacIRCallArgumentLocation,
        value expectedValue: MacIRValue,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let argument = frame.arguments.fixedArgument(at: sourcePosition) else {
            return XCTFail(
                "missing fixed source position \(sourcePosition): \(message)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            argument.role,
            .fixed(sourcePosition: sourcePosition),
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(argument.location, expectedLocation, message, file: file, line: line)
        XCTAssertEqual(argument.value, expectedValue, message, file: file, line: line)
    }

    private func assertUnknownArgument(
        _ frame: MacIRCallFrame,
        at physicalKey: MacIRCallArgumentPhysicalKey,
        location expectedLocation: MacIRCallArgumentLocation,
        value expectedValue: MacIRValue,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let argument = frame.arguments.argument(at: physicalKey) else {
            return XCTFail(
                "missing unknown physical argument \(physicalKey): \(message)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(argument.role, .unknown, message, file: file, line: line)
        XCTAssertEqual(argument.location, expectedLocation, message, file: file, line: line)
        XCTAssertEqual(argument.value, expectedValue, message, file: file, line: line)
        XCTAssertEqual(
            frame.arguments.canonicalPhysicalEntriesForAudit,
            [argument],
            message,
            file: file,
            line: line
        )
    }

    private func assertAssignSource(
        _ function: MacIRFunction,
        at index: Int,
        equals expected: MacIRValue,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .assign(_, source) = function.instructions[index].operation else {
            return XCTFail("expected assignment at index \(index): \(message)", file: file, line: line)
        }
        XCTAssertEqual(source, expected, message, file: file, line: line)
    }

    private func assertIntrinsicArgument(
        _ function: MacIRFunction,
        at index: Int,
        equals expected: MacIRValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .intrinsic(_, _, arguments) = function.instructions[index].operation else {
            return XCTFail("expected intrinsic at index \(index)", file: file, line: line)
        }
        XCTAssertEqual(arguments, [expected], file: file, line: line)
    }

    private func containsUnknown(_ value: MacIRValue, named name: String) -> Bool {
        switch value {
        case let .unknown(candidate):
            return candidate == name
        case let .signedBitfield(field):
            return containsUnknown(field.source, named: name)
        case let .unary(_, nested), let .bitTest(nested, _):
            return containsUnknown(nested, named: name)
        case let .binaryExpression(_, left, right):
            return containsUnknown(left, named: name) || containsUnknown(right, named: name)
        default:
            return false
        }
    }

    private enum TestFailure: Error {
        case missingCall(String)
    }
}

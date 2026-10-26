import XCTest
@testable import MacScope

/// Adversarial WS-15 coverage for evidence that is individually plausible but
/// cannot safely establish a source position, selector, or variadic tail.
final class MacIRCallArgumentAdversarialTests: XCTestCase {
    func testSparseLaterFixedArgumentRefinesOnlyItsExactSourcePosition() throws {
        let signature = MacIRCallSignature(
            target: "_frexp",
            returnType: "double",
            parameters: [
                MacIRCallParameter(index: 0, register: "d0", type: "double"),
                MacIRCallParameter(index: 1, register: "x0", type: "int *"),
            ]
        )
        let reloadedPointer = MacIRValue.register(name: "x0", version: 1)
        let arguments = try XCTUnwrap(MacIRCallArguments([
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: reloadedPointer
            ),
        ]))
        let frame = try XCTUnwrap(MacIRCallFrame(
            target: signature.target,
            knownSignature: signature,
            controlInputs: .none,
            arguments: arguments
        ))
        XCTAssertNil(frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(frame.arguments.fixedArgument(at: 1)?.location, .gpr(index: 0, carrierWidth: 64))

        let function = MacIRFunction(
            name: "_sparse_inference",
            startAddress: 0x1000,
            localVariables: [MacIRLocalVariable(offset: 8, type: "int64_t", byteWidth: 8)],
            callTargets: [signature.target],
            callSignatures: [signature],
            instructions: [
                instruction(
                    0x1000,
                    mnemonic: "str",
                    operation: .store(source: reloadedPointer, address: .stackSlot(offset: 8))
                ),
                instruction(
                    0x1004,
                    mnemonic: "bl",
                    operands: signature.target,
                    operation: .call(frame: frame, result: .register(name: "d0", version: 1))
                ),
            ]
        )

        let inferred = LocalTypeInferencePass.infer(function: function)
        XCTAssertEqual(
            inferred.localVariables,
            [MacIRLocalVariable(offset: 8, type: "int *", byteWidth: 8)],
            "the physical first record is source position one and must receive only row one's pointer type"
        )
    }

    func testFrameRejectsExactCarrierAndScalarWidthMismatches() throws {
        let cases: [(declaredRegister: String, actualLocation: MacIRCallArgumentLocation)] = [
            ("x0", .gpr(index: 0, carrierWidth: 32)),
            ("w0", .gpr(index: 0, carrierWidth: 64)),
            ("d0", .simd(index: 0, scalarWidth: 32)),
            ("s0", .simd(index: 0, scalarWidth: 64)),
        ]

        for (ordinal, testCase) in cases.enumerated() {
            let target = "_width_mismatch_\(ordinal)"
            let signature = MacIRCallSignature(
                target: target,
                returnType: "void",
                parameters: [
                    MacIRCallParameter(
                        index: 0,
                        register: testCase.declaredRegister,
                        type: "opaque"
                    ),
                ]
            )
            let arguments = try XCTUnwrap(MacIRCallArguments([
                MacIRCallArgument(
                    location: testCase.actualLocation,
                    role: .fixed(sourcePosition: 0),
                    value: .unknown("value")
                ),
            ]))

            XCTAssertNil(
                MacIRCallFrame(
                    target: target,
                    knownSignature: signature,
                    controlInputs: .none,
                    arguments: arguments
                ),
                "\(testCase.declaredRegister) must reject \(testCase.actualLocation)"
            )
        }
    }

    func testSelectorProvenanceInX2CannotFillMissingX1() throws {
        let selectorAddress: UInt64 = 0x1_0000_8010
        let function = build(
            [
                row(0x2000, "bl", "_arc4random_stir"),
                row(0x2004, "mov", "x0, #1"),
                row(0x2008, "adrp", "x2, 0x100008000"),
                row(0x200c, "ldr", "x2, [x2, #0x10]"),
                row(0x2010, "bl", "_objc_msgSend"),
                row(0x2014, "ret"),
            ],
            objcSelectors: [selectorAddress: "setObject:"]
        )

        let frame = try callFrame(in: function, target: "_objc_msgSend")
        XCTAssertNotNil(frame.arguments.fixedArgument(at: 0))
        XCTAssertNil(frame.arguments.fixedArgument(at: 1))
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 2)))
        XCTAssertNil(frame.tailCountEvidence)
        XCTAssertFalse(frame.arguments.canonicalPhysicalEntriesForAudit.contains {
            $0.selectorEvidence != nil
        })

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_objc_msgSend(x0_1)"), text)
        XCTAssertFalse(text.contains("setObject:"), text)
        XCTAssertFalse(text.contains("[x0_1"), text)
    }

    func testSelectorEvidenceDoesNotPropagateThroughRegisterCopies() throws {
        let selectorAddress: UInt64 = 0x1_0000_8018
        let function = build(
            [
                row(0x2800, "mov", "x0, #1"),
                row(0x2804, "adrp", "x1, 0x100008000"),
                row(0x2808, "ldr", "x1, [x1, #0x18]"),
                row(0x280c, "mov", "x2, x1"),
                row(0x2810, "mov", "x1, x2"),
                row(0x2814, "bl", "_objc_msgSend"),
                row(0x2818, "ret"),
            ],
            objcSelectors: [selectorAddress: "description"]
        )

        let frame = try callFrame(in: function, target: "_objc_msgSend")
        let copiedSelector = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(copiedSelector.value, .register(name: "x1", version: 3))
        XCTAssertNil(copiedSelector.selectorEvidence)
        XCTAssertNil(frame.tailCountEvidence)

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_objc_msgSend(x0_1, x1_3)"), text)
        XCTAssertFalse(text.contains("description"), text)
        XCTAssertFalse(text.contains("[x0_1"), text)
    }

    func testRealX1SelectorSurvivesMissingX0ButBracketRenderingAbstains() throws {
        let selectorAddress: UInt64 = 0x1_0000_8020
        let function = build(
            [
                row(0x3000, "bl", "_arc4random_stir"),
                row(0x3004, "adrp", "x1, 0x100008000"),
                row(0x3008, "ldr", "x1, [x1, #0x20]"),
                row(0x300c, "bl", "_objc_msgSend"),
                row(0x3010, "ret"),
            ],
            objcSelectors: [selectorAddress: "description"]
        )

        let frame = try callFrame(in: function, target: "_objc_msgSend")
        XCTAssertNil(frame.arguments.fixedArgument(at: 0))
        let selector = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(selector.location, .gpr(index: 1, carrierWidth: 64))
        XCTAssertEqual(selector.value, .register(name: "x1", version: 2))
        XCTAssertEqual(
            selector.selectorEvidence,
            MacIRCallSelectorEvidence(name: "description", selrefAddress: selectorAddress)
        )
        XCTAssertEqual(frame.expectedTailCount, 0)
        XCTAssertNil(frame.completeKnownVariadicRenderValues())

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_objc_msgSend()"), text)
        XCTAssertFalse(text.contains("["), text)
    }

    func testLiveScalarFPEvidenceForcesObjectiveCTailAbstention() throws {
        let selectorAddress: UInt64 = 0x1_0000_8030
        let function = build(
            [
                row(0x4000, "mov", "x0, #1"),
                row(0x4004, "adrp", "x1, 0x100008000"),
                row(0x4008, "ldr", "x1, [x1, #0x30]"),
                row(0x400c, "mov", "x2, #2"),
                row(0x4010, "fmov", "d0, #1.0"),
                row(0x4014, "bl", "_objc_msgSend"),
                row(0x4018, "ret"),
            ],
            objcSelectors: [selectorAddress: "setObject:"]
        )

        let frame = try callFrame(in: function, target: "_objc_msgSend")
        XCTAssertEqual(frame.expectedTailCount, 1)
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 2)))
        XCTAssertFalse(
            frame.arguments.observationScope.observes(.gpr(index: 2, carrierWidth: 64))
        )
        XCTAssertNil(frame.completeKnownVariadicRenderValues())

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_objc_msgSend("), text)
        XCTAssertFalse(text.contains("[x0_1 setObject:"), text)
        XCTAssertFalse(text.contains("setObject:x2_1"), text)
    }

    func testOneColonSelectorArityDoesNotClassifyDenseX2AsAnAnonymousTail() throws {
        let selectorAddress: UInt64 = 0x1_0000_8040
        let function = build(
            [
                row(0x5000, "mov", "x0, #1"),
                row(0x5004, "adrp", "x1, 0x100008000"),
                row(0x5008, "ldr", "x1, [x1, #0x40]"),
                row(0x500c, "mov", "x2, #2"),
                row(0x5010, "bl", "_objc_msgSend"),
                row(0x5014, "ret"),
            ],
            objcSelectors: [selectorAddress: "setObject:"]
        )

        let frame = try callFrame(in: function, target: "_objc_msgSend")
        XCTAssertEqual(frame.expectedTailCount, 1)
        let selector = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(
            selector.selectorEvidence,
            MacIRCallSelectorEvidence(name: "setObject:", selrefAddress: selectorAddress)
        )
        XCTAssertNil(
            frame.arguments.argument(at: .gpr(index: 2)),
            "selector arity alone cannot prove x2 is one complete source argument"
        )
        XCTAssertFalse(
            frame.arguments.observationScope.observes(.gpr(index: 2, carrierWidth: 64))
        )
        XCTAssertNil(frame.completeKnownVariadicRenderValues())
        XCTAssertEqual(frame.arguments.denseFixedPrefixValues(), [
            .register(name: "x0", version: 1),
            .register(name: "x1", version: 2),
        ])

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_objc_msgSend(x0_1, \"setObject:\")"), text)
        XCTAssertFalse(text.contains("[x0_1 setObject:"), text)
        XCTAssertFalse(text.contains("setObject:x2_1"), text)
        XCTAssertFalse(text.contains("_objc_msgSend(x0_1, \"setObject:\", x2_1)"), text)
    }

    func testSelectorEvidenceRejectsCRNULAndAdditionalControlScalars() {
        for scalar in ["\r", "\u{0}", "\u{7f}"] {
            XCTAssertNil(
                MacIRCallSelectorEvidence(
                    name: "set\(scalar)Object:",
                    selrefAddress: 0x1_0000
                ),
                "unexpectedly accepted selector control scalar \(scalar.debugDescription)"
            )
        }
    }

    func testUnsafeZeroColonSelectorTextFallsBackToQuotedPlainCall() throws {
        let unsafeSelectors = [
            "description];fake()",
            "bad;name",
            "bad(name)",
            "bad\u{00a0}name",
            "9lives",
            "bad-name",
            "bad]name",
        ]

        for (index, selectorName) in unsafeSelectors.enumerated() {
            let selectorAddress = UInt64(0x1_0000_9000 + index * 8)
            let function = build(
                [
                    row(0x6000, "mov", "x0, #1"),
                    row(0x6004, "adrp", "x1, 0x100009000"),
                    row(0x6008, "ldr", "x1, [x1, #0x\(String(index * 8, radix: 16))]"),
                    row(0x600c, "bl", "_objc_msgSend"),
                    row(0x6010, "ret"),
                ],
                objcSelectors: [selectorAddress: selectorName]
            )

            let frame = try callFrame(in: function, target: "_objc_msgSend")
            XCTAssertEqual(frame.expectedTailCount, 0)
            XCTAssertEqual(
                frame.completeKnownVariadicRenderValues(),
                [.register(name: "x0", version: 1), .symbol("\"\(selectorName)\"")]
            )

            let text = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(
                text.contains("_objc_msgSend(x0_1, \"\(selectorName)\")"),
                text
            )
            XCTAssertFalse(text.contains("[x0_1"), text)
        }
    }

    func testSelectorEvidenceRequiresCanonical64BitMaterializationRegisters() throws {
        let selectorAddress: UInt64 = 0x1_0000_A018
        let malformedMaterializations: [(
            label: String,
            adrpDestination: String,
            loadDestination: String,
            loadBase: String
        )] = [
            ("w adrp destination and base", "w1", "x1", "w1"),
            ("scalar FP adrp destination and base", "d1", "x1", "d1"),
            ("vector adrp destination and base", "v1", "x1", "v1"),
            ("unbounded adrp destination and base", "x31", "x1", "x31"),
            ("w load destination", "x2", "w1", "x2"),
            ("scalar FP load destination", "x2", "d1", "x2"),
            ("vector load destination", "x2", "v1", "x2"),
            ("unbounded load destination", "x2", "x31", "x2"),
        ]

        for malformed in malformedMaterializations {
            let function = build(
                [
                    row(0x6800, "mov", "x0, #1"),
                    row(
                        0x6804,
                        "adrp",
                        "\(malformed.adrpDestination), 0x10000a000"
                    ),
                    row(
                        0x6808,
                        "ldr",
                        "\(malformed.loadDestination), [\(malformed.loadBase), #0x18]"
                    ),
                    row(0x680c, "bl", "_objc_msgSend"),
                    row(0x6810, "ret"),
                ],
                objcSelectors: [selectorAddress: "description"]
            )

            let frame = try callFrame(in: function, target: "_objc_msgSend")
            XCTAssertNil(
                frame.arguments.fixedArgument(at: 1)?.selectorEvidence,
                malformed.label
            )
            XCTAssertNil(frame.tailCountEvidence, malformed.label)
        }

        let canonical = build(
            [
                row(0x6900, "mov", "x0, #1"),
                row(0x6904, "adrp", "x1, 0x10000a000"),
                row(0x6908, "ldr", "x1, [x1, #0x18]"),
                row(0x690c, "bl", "_objc_msgSend"),
                row(0x6910, "ret"),
            ],
            objcSelectors: [selectorAddress: "description"]
        )
        let canonicalFrame = try callFrame(in: canonical, target: "_objc_msgSend")
        XCTAssertEqual(
            canonicalFrame.arguments.fixedArgument(at: 1)?.selectorEvidence,
            MacIRCallSelectorEvidence(name: "description", selrefAddress: selectorAddress)
        )
        XCTAssertEqual(canonicalFrame.expectedTailCount, 0)
    }

    func testSelectorEvidenceRejectsNegativeAndOverflowingSelrefOffsets() throws {
        let negative = build(
            [
                row(0x6a00, "mov", "x0, #1"),
                row(0x6a04, "adrp", "x1, 0x0"),
                row(0x6a08, "ldr", "x1, [x1, #-0x10]"),
                row(0x6a0c, "bl", "_objc_msgSend"),
                row(0x6a10, "ret"),
            ],
            objcSelectors: [UInt64.max - 0xF: "description"]
        )
        let negativeFrame = try callFrame(in: negative, target: "_objc_msgSend")
        XCTAssertNil(negativeFrame.arguments.fixedArgument(at: 1)?.selectorEvidence)
        XCTAssertNil(negativeFrame.tailCountEvidence)

        // Two individually bounded materializations can place the base at max-1;
        // the final +2 load offset must still reject unsigned-address overflow.
        let overflowing = build(
            [
                row(0x6b00, "mov", "x0, #1"),
                row(0x6b04, "adrp", "x2, 0x7fffffffffffffff"),
                row(0x6b08, "add", "x2, x2, #0x7fffffffffffffff"),
                row(0x6b0c, "ldr", "x1, [x2, #0x2]"),
                row(0x6b10, "bl", "_objc_msgSend"),
                row(0x6b14, "ret"),
            ],
            objcSelectors: [0: "description"]
        )
        let overflowingFrame = try callFrame(in: overflowing, target: "_objc_msgSend")
        XCTAssertNil(overflowingFrame.arguments.fixedArgument(at: 1)?.selectorEvidence)
        XCTAssertNil(overflowingFrame.tailCountEvidence)
    }

    func testInferredVectorWritesSuppressScalarCallValuesWithoutRewritingFunctionParameters() throws {
        let cases: [(
            label: String,
            writer: InstructionRow,
            target: String,
            expectedRegister: String
        )] = [
            ("q load before double call", row(0x7000, "ldr", "q0, [x19]"), "_sin", "d0"),
            (
                "arranged v write before float call",
                row(0x7100, "movi", "v0.16b, #0"),
                "_sinf",
                "s0"
            ),
        ]

        for testCase in cases {
            let function = build([
                testCase.writer,
                row(testCase.writer.address + 4, "bl", testCase.target),
                row(testCase.writer.address + 8, "ret"),
            ])

            XCTAssertTrue(
                function.parameters.contains { $0.bindingID == .simd(0) },
                "the WS-15 call tombstone must not rewrite function-parameter recovery: \(testCase.label)"
            )
            let frame = try callFrame(in: function, target: testCase.target)
            XCTAssertEqual(frame.knownSignature?.parameters.first?.register, testCase.expectedRegister)
            XCTAssertNil(
                frame.arguments.fixedArgument(at: 0),
                "a vector-overwritten V0 cannot be recovered as a stale scalar argument: \(testCase.label)"
            )
            XCTAssertNil(frame.arguments.argument(at: .simd(index: 0)), testCase.label)
        }

        let frozenNonCallParameterUse = build([
            row(0x71f0, "movi", "v0.2s, #3"),
            row(0x71f4, "str", "d0, [x19]"),
            row(0x71f8, "ret"),
        ])
        XCTAssertTrue(
            frozenNonCallParameterUse.parameters.contains { $0.bindingID == .simd(0) },
            "call-only vector tombstones must preserve frozen non-call parameter recovery"
        )
        guard case let .store(source, _) = frozenNonCallParameterUse.instructions[1].operation else {
            return XCTFail("expected the frozen scalar store to remain modeled")
        }
        XCTAssertEqual(
            source,
            .register(name: "v0", version: 1),
            "the scalar store must read the low bits of the modeled MOVI result"
        )
    }

    func testAuthoritativeVectorWritesTombstoneOverlappingScalarCallArguments() throws {
        let cases: [(
            label: String,
            writer: InstructionRow,
            target: String,
            scalarWidth: Int,
            type: String
        )] = [
            ("q0 overwrites d0", row(0x7200, "ldr", "q0, [x19]"), "_sin", 64, "double"),
            (
                "v0 overwrites s0",
                row(0x7300, "movi", "v0.16b, #0"),
                "_sinf",
                32,
                "float"
            ),
        ]

        for testCase in cases {
            let parameter = try XCTUnwrap(MacIRFunctionParameter(
                id: .init(rawValue: "authoritative:simd0:\(testCase.scalarWidth)"),
                bindingID: .simd(0),
                sourcePosition: 0,
                abiLocation: .simd(index: 0, scalarWidth: testCase.scalarWidth),
                type: testCase.type,
                name: "input",
                evidence: .authoritativeUser
            ))
            let plan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(
                parameters: [parameter],
                isVariadic: false
            ))
            let function = build(
                [
                    testCase.writer,
                    row(testCase.writer.address + 4, "bl", testCase.target),
                    row(testCase.writer.address + 8, "ret"),
                ],
                authoritativeParameterPlan: plan
            )

            XCTAssertEqual(function.parameters.map(\.bindingID), [.simd(0)], testCase.label)
            let frame = try callFrame(in: function, target: testCase.target)
            XCTAssertNil(frame.arguments.fixedArgument(at: 0), testCase.label)
            XCTAssertNil(frame.arguments.argument(at: .simd(index: 0)), testCase.label)
        }
    }

    func testVectorTombstonePreservesUnrelatedLaneAndFreshScalarRewrite() throws {
        let d1 = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "authoritative:simd1"),
            bindingID: .simd(1),
            sourcePosition: 0,
            abiLocation: .simd(index: 1, scalarWidth: 64),
            type: "double",
            name: "otherLane",
            evidence: .authoritativeUser
        ))
        let d1Plan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(
            parameters: [d1],
            isVariadic: false
        ))
        let unrelated = build(
            [
                row(0x7400, "ldr", "q0, [x19]"),
                row(0x7404, "bl", "_pow"),
                row(0x7408, "ret"),
            ],
            authoritativeParameterPlan: d1Plan
        )
        let powFrame = try callFrame(in: unrelated, target: "_pow")
        XCTAssertNil(powFrame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(
            powFrame.arguments.fixedArgument(at: 1),
            MacIRCallArgument(
                location: .simd(index: 1, scalarWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: .argument(bindingID: .simd(1))
            ),
            "a V0 write must not tombstone the unrelated V1 scalar lane"
        )

        // Q0 reserves low-half definition 1 before its late refusal; the fresh D0 write
        // is definition 2 in SSA. The legacy spelling counter has not yet written d0.
        let rewritten = build([
            row(0x7500, "ldr", "q0, [x19]"),
            row(0x7504, "fmov", "d0, #1.0"),
            row(0x7508, "bl", "_sin"),
            row(0x750c, "ret"),
        ])
        let sinFrame = try callFrame(in: rewritten, target: "_sin")
        XCTAssertEqual(
            sinFrame.arguments.fixedArgument(at: 0),
            MacIRCallArgument(
                location: .simd(index: 0, scalarWidth: 64),
                role: .fixed(sourcePosition: 0),
                value: .register(name: "d0", version: SSAPropertyAssertions.enabled ? 2 : 1)
            ),
            "an exact later d0 write must replace the vector tombstone"
        )
    }

    func testVectorCallTombstoneDoesNotEstablishReturnAuthority() throws {
        let modeledVectorWrite = build([
            row(0x7580, "mov", "x0, #7"),
            row(0x7584, "ldr", "q0, [x19]"),
            row(0x7588, "ret"),
        ])

        XCTAssertEqual(
            modeledVectorWrite.returnValue,
            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
            "constant 7 does not establish an integer return contract"
        )

        let unmodeledVectorWrite = build([
            row(0x7590, "mov", "w0, #7"),
            row(0x7594, "movi", "v0.16b, #0"),
            row(0x7598, "ret"),
        ])

        XCTAssertEqual(
            unmodeledVectorWrite.returnValue,
            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
            "a vector write does not turn constant 7 into an admitted return producer"
        )

        let scalarFPThenVector = build([
            row(0x75a0, "fmov", "d0, #1.0"),
            row(0x75a4, "ldr", "q0, [x19]"),
            row(0x75a8, "ret"),
        ])

        XCTAssertEqual(
            scalarFPThenVector.returnValue,
            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
            "a scalar-FP producer without return authority remains unresolved"
        )

        let scalarFPThenUnmodeledVector = build([
            row(0x75b0, "fmov", "s0, #1.0"),
            row(0x75b4, "movi", "v0.16b, #0"),
            row(0x75b8, "ret"),
        ])

        XCTAssertEqual(
            scalarFPThenUnmodeledVector.returnValue,
            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
            "vector writes do not establish authority for a scalar-FP result"
        )

        let entryStackParameter = try XCTUnwrap(MacIRFunctionParameter(
            id: .init(rawValue: "auth:0:stack:0"),
            bindingID: nil,
            sourcePosition: 0,
            abiLocation: .entryStack(byteOffset: 0, size: 8, alignment: 8),
            type: "uint64_t",
            name: "stackValue",
            evidence: .authoritativeUser
        ))
        let entryStackPlan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(
            parameters: [entryStackParameter],
            isVariadic: false
        ))
        let integerEntryStackResult = build(
            [
                row(0x75c0, "ldr", "x0, [sp]"),
                row(0x75c4, "ldr", "q0, [x19]"),
                row(0x75c8, "ret"),
            ],
            authoritativeParameterPlan: entryStackPlan
        )
        XCTAssertEqual(
            integerEntryStackResult.returnValue,
            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
            "an entry-stack load alone does not establish a return contract"
        )

        let scalarFPEntryStackResult = build(
            [
                row(0x75d0, "ldr", "d0, [sp]"),
                row(0x75d4, "ldr", "q0, [x19]"),
                row(0x75d8, "ret"),
            ],
            authoritativeParameterPlan: entryStackPlan
        )
        XCTAssertEqual(
            scalarFPEntryStackResult.returnValue,
            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker),
            "parameter authority does not establish scalar-FP return authority"
        )
    }

    func testMalformedVectorSpellingsDoNotTombstoneScalarLanes() throws {
        let malformedWriters = [
            row(0x7600, "ldr", "q32, [x19]"),
            row(0x7700, "movi", "v01.16b, #0"),
            row(0x7800, "movi", "v-1.16b, #0"),
            row(0x7900, "movi", "v0.bad, #0"),
        ]

        for writer in malformedWriters {
            let function = build([
                writer,
                row(writer.address + 4, "bl", "_sin"),
                row(writer.address + 8, "ret"),
            ])
            let frame = try callFrame(in: function, target: "_sin")
            XCTAssertEqual(
                frame.arguments.fixedArgument(at: 0)?.value,
                .argument(bindingID: .simd(0)),
                "malformed or out-of-range vector text is not physical alias evidence: \(writer.operands)"
            )
        }
    }

    func testMalformedVectorRefusalPreservesCarrierWhileValidDestinationInvalidatesIt() {
        for (operand, isValid) in [("v0.bad", false), ("v0.16b", true)] {
            var state = BuilderState(parameters: [])
            state.permitsNEONBufferCarrier = true
            state.permitsNEONScalarViewCarrier = true
            let prior = state.writeRegister("d0")
            let refusal = MacIRBuilder().generalVectorRefusal(
                row(0x7a00, "movi", "\(operand), #0"), state: &state
            )
            guard case .unknown = refusal.operation else {
                return XCTFail("refusal must retain the unknown instruction: \(operand)")
            }
            XCTAssertEqual(state.callUnavailableRegisterValues.contains("v0"), isValid)
            XCTAssertEqual(state.unavailableRegisterValues.contains("v0"), isValid)
            XCTAssertEqual(
                state.readRegister("d0"),
                isValid ? .unknown("unavailable_v0") : prior,
                operand
            )
        }
    }

    private func build(
        _ rows: [InstructionRow],
        objcSelectors: [UInt64: String] = [:],
        authoritativeParameterPlan: MacIRAuthoritativeParameterPlan? = nil
    ) -> MacIRFunction {
        MacIRBuilder().buildFunction(
            name: "_ws15_adversarial",
            objcSelectors: objcSelectors,
            authoritativeParameterPlan: authoritativeParameterPlan,
            instructions: rows
        )
    }

    private func callFrame(
        in function: MacIRFunction,
        target: String
    ) throws -> MacIRCallFrame {
        for instruction in function.instructions {
            guard case let .call(frame, _) = instruction.operation,
                  frame.target == target else {
                continue
            }
            return frame
        }
        throw TestFailure.missingCall(target)
    }

    private func instruction(
        _ address: UInt64,
        mnemonic: String,
        operands: String = "",
        operation: MacIROperation
    ) -> MacIRInstruction {
        MacIRInstruction(
            source: MacIRSourceSpan(
                address: address,
                byteText: "",
                mnemonic: mnemonic,
                operands: operands
            ),
            operation: operation
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

    private enum TestFailure: Error {
        case missingCall(String)
    }
}

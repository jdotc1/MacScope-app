import XCTest
@testable import MacScope

/// WS-15 integration coverage for the builder-owned call-frame recovery seam.
/// These tests assert the structured payload directly so renderer compatibility
/// projections cannot hide physical-slot compaction or lost control evidence.
final class MacIRCallArgumentRecoveryTests: XCTestCase {
    func testKnownMixedBankRecoveryRetainsSparseSourcePositionsAndLocations() throws {
        let function = build([
            row(0x1000, "bl", "_arc4random_stir"),
            row(0x1004, "fmov", "d0, #1.0"),
            row(0x1008, "mov", "x0, #7"),
            row(0x100c, "bl", "_remquo"),
            row(0x1010, "ret"),
        ])

        let frame = try callFrame(in: function, target: "_remquo")
        XCTAssertEqual(frame.knownSignature?.parameters.map(\.register), ["d0", "d1", "x0"])

        let first = try XCTUnwrap(frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(first.location, .simd(index: 0, scalarWidth: 64))
        XCTAssertEqual(first.role, .fixed(sourcePosition: 0))
        XCTAssertEqual(first.value, .register(name: "d0", version: 1))

        XCTAssertNil(frame.arguments.fixedArgument(at: 1))

        let third = try XCTUnwrap(frame.arguments.fixedArgument(at: 2))
        XCTAssertEqual(third.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(third.role, .fixed(sourcePosition: 2))
        XCTAssertEqual(third.value, .register(name: "x0", version: 1))

        XCTAssertEqual(
            frame.arguments.canonicalPhysicalEntriesForAudit.map(\.role),
            [.fixed(sourcePosition: 2), .fixed(sourcePosition: 0)],
            "physical canonicalization must not rewrite source positions"
        )
        XCTAssertEqual(
            frame.arguments.denseFixedPrefixValues(),
            [.register(name: "d0", version: 1)],
            "ordinary rendering must stop at the missing source position one"
        )
    }

    func testGenericCVariadicRecoveryKeepsOnlyKnownFixedRows() throws {
        let function = build([
            row(0x2000, "mov", "x0, #0x1000"),
            row(0x2004, "mov", "x1, #1"),
            row(0x2008, "mov", "x2, #2"),
            row(0x200c, "bl", "_printf"),
            row(0x2010, "ret"),
        ])

        let frame = try callFrame(in: function, target: "_printf")
        XCTAssertEqual(frame.knownSignature?.isVariadic, true)
        XCTAssertNil(frame.tailCountEvidence)
        XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit, [
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .fixed(sourcePosition: 0),
                value: .register(name: "x0", version: 1)
            ),
        ])
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 1)))
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 2)))
        XCTAssertEqual(
            frame.arguments.denseFixedPrefixValues(),
            [.register(name: "x0", version: 1)]
        )
    }

    func testUnknownDirectCallRetainsSparseExactGPREvidenceAndDenseRenderStopsAtGap() throws {
        let function = build([
            row(0x3000, "mov", "w0, #1"),
            row(0x3004, "mov", "x2, #3"),
            row(0x3008, "bl", "_opaque"),
            row(0x300c, "ret"),
        ])

        let frame = try callFrame(in: function, target: "_opaque")
        XCTAssertNil(frame.knownSignature)
        XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit, [
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 32),
                role: .unknown,
                value: .register(name: "w0", version: 1)
            ),
            MacIRCallArgument(
                location: .gpr(index: 2, carrierWidth: 64),
                role: .unknown,
                value: .register(name: "x2", version: 1)
            ),
        ])
        XCTAssertTrue(
            frame.arguments.observationScope.observes(.gpr(index: 1, carrierWidth: 64)),
            "the missing x1 slot must remain an observed gap"
        )
        XCTAssertEqual(
            frame.arguments.denseUnknownGPRPrefixValues(),
            [.register(name: "w0", version: 1)]
        )
    }

    func testIndirectAndAuthenticatedControlsAreCapturedAndExcludedFromArguments() throws {
        let cases: [(
            mnemonic: String,
            operands: String,
            modifier: MacIRCallControlInput?
        )] = [
            ("blr", "x1", nil),
            (
                "blraa",
                "x1, x2",
                MacIRCallControlInput(
                    role: .pointerAuthenticationModifier,
                    register: .gpr(index: 2),
                    value: .register(name: "x2", version: 1)
                )
            ),
        ]

        for testCase in cases {
            let function = build([
                row(0x4000, "mov", "x0, #1"),
                row(0x4004, "mov", "x1, #0x4000"),
                row(0x4008, "mov", "x2, #2"),
                row(0x400c, testCase.mnemonic, testCase.operands),
                row(0x4010, "ret"),
            ])

            let frame = try callFrame(in: function, target: "(*x1)")
            XCTAssertEqual(
                frame.controlInputs.indirectTarget,
                MacIRCallControlInput(
                    role: .indirectTarget,
                    register: .gpr(index: 1),
                    value: .register(name: "x1", version: 1)
                ),
                testCase.mnemonic
            )
            XCTAssertEqual(
                frame.controlInputs.pointerAuthenticationModifier,
                testCase.modifier,
                testCase.mnemonic
            )
            XCTAssertEqual(
                frame.arguments.argument(at: .gpr(index: 0)),
                MacIRCallArgument(
                    location: .gpr(index: 0, carrierWidth: 64),
                    role: .unknown,
                    value: .register(name: "x0", version: 1)
                ),
                testCase.mnemonic
            )
            XCTAssertNil(frame.arguments.argument(at: .gpr(index: 1)), testCase.mnemonic)
            XCTAssertFalse(
                frame.arguments.observationScope.observes(.gpr(index: 1, carrierWidth: 64)),
                testCase.mnemonic
            )
            if testCase.modifier != nil {
                XCTAssertNil(frame.arguments.argument(at: .gpr(index: 2)), testCase.mnemonic)
                XCTAssertFalse(
                    frame.arguments.observationScope.observes(
                        .gpr(index: 2, carrierWidth: 64)
                    ),
                    testCase.mnemonic
                )
            } else {
                XCTAssertEqual(
                    frame.arguments.argument(at: .gpr(index: 2))?.value,
                    .register(name: "x2", version: 1),
                    testCase.mnemonic
                )
            }
        }
    }

    func testAuthenticatedSameRegisterOperandsRetainEqualValueTwice() throws {
        let function = build([
            row(0x5000, "mov", "x1, #0x4000"),
            row(0x5004, "blraa", "x1, x1"),
            row(0x5008, "ret"),
        ])

        let frame = try callFrame(in: function, target: "(*x1)")
        let target = try XCTUnwrap(frame.controlInputs.indirectTarget)
        let modifier = try XCTUnwrap(frame.controlInputs.pointerAuthenticationModifier)
        XCTAssertEqual(target.register, .gpr(index: 1))
        XCTAssertEqual(modifier.register, .gpr(index: 1))
        XCTAssertEqual(target.value, .register(name: "x1", version: 1))
        XCTAssertEqual(modifier.value, target.value)
        XCTAssertEqual(frame.bindingValues, [target.value, target.value])
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 1)))
        XCTAssertFalse(
            frame.arguments.observationScope.observes(.gpr(index: 1, carrierWidth: 64))
        )
    }

    func testObjCSelectorEvidenceRetainsSSAAndSelrefButDenseGPRTailAbstains() throws {
        let complete = build(
            objcRows(includeSecondTail: true),
            objcSelectors: [0x1000_08010: "setObject:forKey:"]
        )
        let completeFrame = try callFrame(in: complete, target: "_objc_msgSend")
        let selector = try XCTUnwrap(completeFrame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(selector.location, .gpr(index: 1, carrierWidth: 64))
        XCTAssertEqual(selector.value, .register(name: "x1", version: 2))
        XCTAssertEqual(
            selector.selectorEvidence,
            MacIRCallSelectorEvidence(
                name: "setObject:forKey:",
                selrefAddress: 0x1000_08010
            )
        )
        XCTAssertNil(completeFrame.arguments.argument(at: .gpr(index: 2)))
        XCTAssertNil(completeFrame.arguments.argument(at: .gpr(index: 3)))
        XCTAssertEqual(completeFrame.expectedTailCount, 2)
        XCTAssertNil(completeFrame.completeKnownVariadicRenderValues())
        let completeText = PseudocodePrinter().print(function: complete).text
        XCTAssertFalse(completeText.contains("[x0_1 setObject:"))
        let completeCallLine = try XCTUnwrap(
            completeText.split(separator: "\n").first { $0.contains("_objc_msgSend(") }
        )
        XCTAssertTrue(completeCallLine.contains("_objc_msgSend(x0_1, \"setObject:forKey:\")"))
        XCTAssertFalse(completeCallLine.contains("x2_1"))
        XCTAssertFalse(completeCallLine.contains("x3_1"))

        let incomplete = build(
            objcRows(includeSecondTail: false),
            objcSelectors: [0x1000_08010: "setObject:forKey:"]
        )
        let incompleteFrame = try callFrame(in: incomplete, target: "_objc_msgSend")
        XCTAssertNil(incompleteFrame.arguments.argument(at: .gpr(index: 2)))
        XCTAssertNil(incompleteFrame.arguments.argument(at: .gpr(index: 3)))
        XCTAssertNil(incompleteFrame.completeKnownVariadicRenderValues())
        let incompleteText = PseudocodePrinter().print(function: incomplete).text
        XCTAssertFalse(incompleteText.contains("[x0_1 setObject:"))
        XCTAssertFalse(incompleteText.contains("forKey:x3_1"))
        let fallbackCallLine = try XCTUnwrap(
            incompleteText.split(separator: "\n").first { $0.contains("_objc_msgSend(") }
        )
        XCTAssertFalse(
            fallbackCallLine.contains("x2_1"),
            "an incomplete anonymous tail must not leak into ordinary rendering"
        )
    }

    private func objcRows(includeSecondTail: Bool) -> [InstructionRow] {
        var rows = [
            row(0x6000, "adrp", "x1, 0x100008000"),
            row(0x6004, "ldr", "x1, [x1, #0x10]"),
            row(0x6008, "mov", "x0, #1"),
            row(0x600c, "mov", "x2, #2"),
        ]
        if includeSecondTail {
            rows.append(row(0x6010, "mov", "x3, #3"))
        }
        let callAddress: UInt64 = includeSecondTail ? 0x6014 : 0x6010
        rows.append(row(callAddress, "bl", "_objc_msgSend"))
        rows.append(row(callAddress + 4, "ret"))
        return rows
    }

    private func build(
        _ rows: [InstructionRow],
        objcSelectors: [UInt64: String] = [:]
    ) -> MacIRFunction {
        MacIRBuilder().buildFunction(
            name: "ws15_call_recovery",
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

    private enum TestFailure: Error {
        case missingCall(String)
    }
}

import XCTest
@testable import MacScope

final class MacIRRegisterAliasTests: XCTestCase {
    func testIntegerRegisterViewAcceptsCanonicalBoundsAndRejectsSpecialOrMalformedNames() {
        let x0 = MacIRBuilder.integerRegisterView("x0")
        XCTAssertEqual(x0?.index, 0)
        XCTAssertEqual(x0?.width, 64)

        let w30 = MacIRBuilder.integerRegisterView("w30")
        XCTAssertEqual(w30?.index, 30)
        XCTAssertEqual(w30?.width, 32)

        for (register, index, width) in [
            ("x29", 29, 64),
            ("w29", 29, 32),
            ("x30", 30, 64),
        ] {
            let view = MacIRBuilder.integerRegisterView(register)
            XCTAssertEqual(view?.index, index)
            XCTAssertEqual(view?.width, width)
        }

        for invalid in [
            "sp", "fp", "xzr", "wzr", "x31", "w31", "x01",
            "x-1", "w+1", "", "x1junk",
        ] {
            XCTAssertNil(
                MacIRBuilder.integerRegisterView(invalid),
                "expected canonical integer-register parser to reject \(invalid.debugDescription)"
            )
        }
    }

    func testRepeatedSameWidthWritesPreserveLatestExactSSAVersion() {
        let fn = build([
            row(0x1000, "mov", "x7, #1"),
            row(0x1004, "mov", "x7, #2"),
            row(0x1008, "mov", "x8, x7"),
            row(0x100c, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x8", version: 1),
                source: .register(name: "x7", version: 2)
            )
        )
    }

    func testKnownVariadicCallUsesFixedCatalogLocationAndProjectsLatestPhysicalWrite() throws {
        // SSA counts x0 and w0 as one physical cell: the second MOV is definition 2 in each fixture.
        let laterW = build([
            row(0x1000, "mov", "x0, #1"),
            row(0x1004, "mov", "w0, #2"),
            row(0x1008, "bl", "_printf"),
            row(0x100c, "ret", ""),
        ])
        let laterWFrame = try XCTUnwrap(callFrame(in: laterW, target: "_printf"))
        XCTAssertEqual(laterWFrame.knownSignature?.target, "_printf")
        XCTAssertEqual(laterWFrame.knownSignature?.isVariadic, true)
        XCTAssertNil(laterWFrame.tailCountEvidence)
        let laterWArgument = try XCTUnwrap(laterWFrame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(laterWArgument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(laterWArgument.role, .fixed(sourcePosition: 0))
        let projectedWValue = MacIRValue.unary(
            op: "(uint64_t)",
            value: .unary(
                op: "(uint32_t)",
                value: .register(name: "w0", version: SSAPropertyAssertions.enabled ? 2 : 1)
            )
        )
        XCTAssertEqual(laterWArgument.value, projectedWValue)
        XCTAssertEqual(
            laterWFrame.arguments.denseFixedPrefixValues(),
            [projectedWValue]
        )

        let laterX = build([
            row(0x2000, "mov", "w0, #1"),
            row(0x2004, "mov", "x0, #2"),
            row(0x2008, "bl", "_printf"),
            row(0x200c, "ret", ""),
        ])
        let laterXFrame = try XCTUnwrap(callFrame(in: laterX, target: "_printf"))
        XCTAssertEqual(laterXFrame.knownSignature?.target, "_printf")
        XCTAssertEqual(laterXFrame.knownSignature?.isVariadic, true)
        XCTAssertNil(laterXFrame.tailCountEvidence)
        let laterXArgument = try XCTUnwrap(laterXFrame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(laterXArgument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(laterXArgument.role, .fixed(sourcePosition: 0))
        XCTAssertEqual(laterXArgument.value, .register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1))
        XCTAssertEqual(
            laterXFrame.arguments.denseFixedPrefixValues(),
            [.register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1)]
        )
    }

    func testUpperBoundX30AndW30ProjectAcrossPhysicalViews() {
        // SSA shares counters across views: x30 then w30 define cell 30 twice; w0 then x0 define cell 0 twice.
        let fn = build([
            row(0x1000, "mov", "x30, #0x100000001"),
            row(0x1004, "mov", "w0, w30"),
            row(0x1008, "mov", "w30, #2"),
            row(0x100c, "mov", "x0, x30"),
            row(0x1010, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[1].operation,
            .assign(
                destination: .register(name: "w0", version: 1),
                source: .unary(
                    op: "(uint32_t)",
                    value: .register(name: "x30", version: 1)
                )
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1),
                source: .unary(
                    op: "(uint64_t)",
                    value: .unary(
                        op: "(uint32_t)",
                        value: .register(name: "w30", version: SSAPropertyAssertions.enabled ? 2 : 1)
                    )
                )
            )
        )
    }

    func testXReadAfterLaterWWriteUsesZeroExtendedPhysicalValue() {
        // SSA counts the preceding x0 MOV and this w0 MOV in the same physical cell.
        let fn = build([
            row(0x1000, "mov", "x0, #0x111"),
            row(0x1004, "mov", "w0, #0x222"),
            row(0x1008, "mov", "x1, x0"),
            row(0x100c, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x1", version: 1),
                source: .unary(
                    op: "(uint64_t)",
                    value: .unary(
                        op: "(uint32_t)",
                        value: .register(name: "w0", version: SSAPropertyAssertions.enabled ? 2 : 1)
                    )
                )
            )
        )
    }

    func testWReadAfterLaterXWriteUsesLowThirtyTwoBits() {
        // SSA counts the preceding w0 MOV and this x0 MOV in the same physical cell.
        let fn = build([
            row(0x1000, "mov", "w0, #1"),
            row(0x1004, "mov", "x0, #0x100000002"),
            row(0x1008, "mov", "w1, w0"),
            row(0x100c, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "w1", version: 1),
                source: .unary(
                    op: "(uint32_t)",
                    value: .register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1)
                )
            )
        )
    }

    func testKnownXWidthCallUsesLaterWDefinition() throws {
        // The fixed X argument projects the second physical-cell definition, written through W in SSA.
        let fn = build([
            row(0x1000, "mov", "x0, #0x111"),
            row(0x1004, "mov", "w0, #0x222"),
            row(0x1008, "bl", "_strlen"),
            row(0x100c, "ret", ""),
        ])

        let frame = try XCTUnwrap(callFrame(in: fn, target: "_strlen"))
        XCTAssertEqual(frame.knownSignature?.target, "_strlen")
        let argument = try XCTUnwrap(frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(argument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(argument.role, .fixed(sourcePosition: 0))
        let expectedValue = MacIRValue.unary(
            op: "(uint64_t)",
            value: .unary(
                op: "(uint32_t)",
                value: .register(name: "w0", version: SSAPropertyAssertions.enabled ? 2 : 1)
            )
        )
        XCTAssertEqual(argument.value, expectedValue)
        XCTAssertEqual(frame.arguments.denseFixedPrefixValues(), [expectedValue])
    }

    func testKnownWWidthCallUsesLaterXDefinition() throws {
        // The fixed W argument projects the second physical-cell definition, written through X in SSA.
        let fn = build([
            row(0x1000, "mov", "w0, #1"),
            row(0x1004, "mov", "x0, #0x100000002"),
            row(0x1008, "bl", "_abs"),
            row(0x100c, "ret", ""),
        ])

        let frame = try XCTUnwrap(callFrame(in: fn, target: "_abs"))
        XCTAssertEqual(frame.knownSignature?.target, "_abs")
        let argument = try XCTUnwrap(frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(argument.location, .gpr(index: 0, carrierWidth: 32))
        XCTAssertEqual(argument.role, .fixed(sourcePosition: 0))
        let expectedValue = MacIRValue.unary(
            op: "(uint32_t)",
            value: .register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1)
        )
        XCTAssertEqual(argument.value, expectedValue)
        XCTAssertEqual(frame.arguments.denseFixedPrefixValues(), [expectedValue])
    }

    func testUnknownCallUsesExactSpellingAndLocationOfLatestPhysicalWrite() throws {
        // Each fixture writes cell 0 twice; SSA uses one counter while the legacy path counts each spelling.
        let laterW = build([
            row(0x1000, "mov", "x0, #1"),
            row(0x1004, "mov", "w0, #2"),
            row(0x1008, "bl", "_opaque"),
            row(0x100c, "ret", ""),
        ])
        let laterWFrame = try XCTUnwrap(callFrame(in: laterW, target: "_opaque"))
        XCTAssertNil(laterWFrame.knownSignature)
        let laterWArgument = try XCTUnwrap(
            laterWFrame.arguments.argument(at: .gpr(index: 0))
        )
        XCTAssertEqual(laterWArgument.location, .gpr(index: 0, carrierWidth: 32))
        XCTAssertEqual(laterWArgument.role, .unknown)
        XCTAssertEqual(laterWArgument.value, .register(name: "w0", version: SSAPropertyAssertions.enabled ? 2 : 1))
        XCTAssertEqual(
            laterWFrame.arguments.denseUnknownGPRPrefixValues(),
            [.register(name: "w0", version: SSAPropertyAssertions.enabled ? 2 : 1)]
        )

        let laterX = build([
            row(0x2000, "mov", "w0, #1"),
            row(0x2004, "mov", "x0, #2"),
            row(0x2008, "bl", "_opaque"),
            row(0x200c, "ret", ""),
        ])
        let laterXFrame = try XCTUnwrap(callFrame(in: laterX, target: "_opaque"))
        XCTAssertNil(laterXFrame.knownSignature)
        let laterXArgument = try XCTUnwrap(
            laterXFrame.arguments.argument(at: .gpr(index: 0))
        )
        XCTAssertEqual(laterXArgument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(laterXArgument.role, .unknown)
        XCTAssertEqual(laterXArgument.value, .register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1))
        XCTAssertEqual(
            laterXFrame.arguments.denseUnknownGPRPrefixValues(),
            [.register(name: "x0", version: SSAPropertyAssertions.enabled ? 2 : 1)]
        )
    }

    func testHighRegisterAliasReadUsesLatestPhysicalWrite() {
        // The two MOVs define physical cell 8 twice in SSA, regardless of the X/W spelling.
        let fn = build([
            row(0x1000, "mov", "x8, #1"),
            row(0x1004, "mov", "w8, #2"),
            row(0x1008, "mov", "x9, x8"),
            row(0x100c, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x9", version: 1),
                source: .unary(
                    op: "(uint64_t)",
                    value: .unary(
                        op: "(uint32_t)",
                        value: .register(name: "w8", version: SSAPropertyAssertions.enabled ? 2 : 1)
                    )
                )
            )
        )
    }

    func testWWriteInvalidatesSiblingXRegisterADRPProvenance() {
        let rows = [
            row(0x1000, "adrp", "x1, 0x100008000"),
            row(0x1004, "mov", "w1, #0"),
            row(0x1008, "ldr", "x1, [x1, #0x10]"),
            row(0x100c, "bl", "_objc_msgSend"),
            row(0x1010, "ret", ""),
        ]

        let document = PseudocodePrinter().print(
            functionName: "alias_clobbered_selector",
            objcSelectors: [0x1000_08010: "viewDidLoad"],
            instructions: rows
        )
        XCTAssertFalse(document.text.contains("viewDidLoad"))
        XCTAssertTrue(document.text.contains("_objc_msgSend"))
    }

    func testWReadProjectsRecoveredXParameterToLowThirtyTwoBits() {
        let fn = build([
            row(0x1000, "mov", "x8, x0"),
            row(0x1004, "mov", "w9, w0"),
            row(0x1008, "ret", ""),
        ])

        XCTAssertEqual(fn.parameters.map(\.register), ["x0"])
        XCTAssertEqual(
            fn.instructions[1].operation,
            .assign(
                destination: .register(name: "w9", version: 1),
                source: .unary(
                    op: "(uint32_t)",
                    value: .argument(bindingID: .gpr(0))
                )
            )
        )
    }

    func testUnknownCallProjectsRecoveredWParameterToObservedXView() throws {
        let fn = build([
            row(0x1000, "mov", "w8, w0"),
            row(0x1004, "bl", "_opaque"),
            row(0x1008, "ret", ""),
        ])

        XCTAssertEqual(fn.parameters.map(\.register), ["w0"])
        let frame = try XCTUnwrap(callFrame(in: fn, target: "_opaque"))
        XCTAssertNil(frame.knownSignature)
        let argument = try XCTUnwrap(frame.arguments.argument(at: .gpr(index: 0)))
        XCTAssertEqual(argument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(argument.role, .unknown)
        let expectedValue = MacIRValue.unary(
            op: "(uint64_t)",
            value: .unary(
                op: "(uint32_t)",
                value: .argument(bindingID: .gpr(0))
            )
        )
        XCTAssertEqual(argument.value, expectedValue)
        XCTAssertEqual(
            frame.arguments.denseUnknownGPRPrefixValues(),
            [expectedValue]
        )
    }

    func testZeroExtendedXProjectionKeepsUnsignedComparisonAtSixtyFourBits() {
        let fn = build([
            row(0x1000, "mov", "w0, #1"),
            row(0x1004, "cmp", "x0, x1"),
            row(0x1008, "b.hs", "0x1010"),
            row(0x100c, "nop", ""),
            row(0x1010, "ret", ""),
        ])

        guard case let .conditionalBranch(condition, left, right, target) = fn.instructions[2].operation else {
            return XCTFail("expected a structured unsigned conditional branch")
        }
        XCTAssertEqual(condition, ">=")
        XCTAssertEqual(target, .immediate(0x1010))
        guard case let .unary(projectedWidth, _) = left else {
            return XCTFail("expected the x0 value to retain its 64-bit projection: \(left)")
        }
        XCTAssertEqual(projectedWidth, "(uint64_t)")
        XCTAssertEqual(right, .unary(op: "(uint64_t)", value: .argument(bindingID: .gpr(1))))

        let text = PseudocodePrinter().print(function: fn).text
        XCTAssertTrue(text.contains("if ((uint64_t)"), text)
        XCTAssertFalse(text.contains("if ((uint32_t)"), text)
    }

    func testUnmodeledPairStoreWritebackTombstonesBothIntegerViews() {
        let fn = build([
            row(0x1000, "mov", "x1, #0x1000"),
            row(0x1004, "stp", "x2, x3, [x1], #16"),
            row(0x1008, "mov", "x4, x1"),
            row(0x100c, "mov", "w5, w1"),
            row(0x1010, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x4", version: 1),
                source: .unknown("unavailable_x1")
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "w5", version: 1),
                source: .unknown("unavailable_w1")
            )
        )
    }

    func testModeledWWriteResurrectsTombstonedPhysicalRegisterAndProjectsToX() {
        // SSA reserves cell 1 definitions for MOV, implicit STP writeback, then fresh MOV; refusal does not recycle names.
        let fn = build([
            row(0x1000, "mov", "x1, #0x1000"),
            row(0x1004, "stp", "x2, x3, [x1], #16"),
            row(0x1008, "mov", "w1, #7"),
            row(0x100c, "mov", "w4, w1"),
            row(0x1010, "mov", "x5, x1"),
            row(0x1014, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "w4", version: 1),
                source: .register(name: "w1", version: SSAPropertyAssertions.enabled ? 3 : 1)
            )
        )
        XCTAssertEqual(
            fn.instructions[4].operation,
            .assign(
                destination: .register(name: "x5", version: 1),
                source: .unary(
                    op: "(uint64_t)",
                    value: .unary(
                        op: "(uint32_t)",
                        value: .register(name: "w1", version: SSAPropertyAssertions.enabled ? 3 : 1)
                    )
                )
            )
        )
    }

    func testUnmodeledPairLoadWritebackKeepsOnlyMaterializedDestinationCurrent() {
        let fn = build([
            row(0x1000, "mov", "x1, #0x1000"),
            row(0x1004, "mov", "x2, #2"),
            row(0x1008, "mov", "x3, #3"),
            row(0x100c, "ldp", "x2, x3, [x1], #16"),
            row(0x1010, "mov", "x4, x1"),
            row(0x1014, "mov", "x5, x2"),
            row(0x1018, "mov", "x6, x3"),
            row(0x101c, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[4].operation,
            .assign(destination: .register(name: "x4", version: 1), source: .unknown("unavailable_x1"))
        )
        XCTAssertEqual(
            fn.instructions[5].operation,
            .assign(destination: .register(name: "x5", version: 1), source: .register(name: "x2", version: 2))
        )
        XCTAssertEqual(
            fn.instructions[6].operation,
            .assign(destination: .register(name: "x6", version: 1), source: .unknown("unavailable_x3"))
        )
    }

    func testUnmodeledPairFirstMaterializedWDestinationProjectsThroughXSibling() {
        let fn = build([
            row(0x1000, "mov", "x1, #0x1000"),
            row(0x1004, "mov", "w2, #2"),
            row(0x1008, "mov", "w3, #3"),
            row(0x100c, "ldp", "w2, w3, [x1], #8"),
            row(0x1010, "mov", "x4, x2"),
            row(0x1014, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[4].operation,
            .assign(
                destination: .register(name: "x4", version: 1),
                source: .unary(
                    op: "(uint64_t)",
                    value: .unary(
                        op: "(uint32_t)",
                        value: .register(name: "w2", version: 2)
                    )
                )
            )
        )
    }

    func testSIMDStorePostIndexPreservesUpdatedIntegerViewsOfBase() {
        let fn = build([
            row(0x1000, "mov", "x19, #0x1000"),
            row(0x1004, "str", "q0, [x19], #16"),
            row(0x1008, "mov", "x20, x19"),
            row(0x100c, "mov", "w21, w19"),
            row(0x1010, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x20", version: 1),
                source: .register(name: "x19", version: 2)
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "w21", version: 1),
                source: .unary(op: "(uint32_t)", value: .register(name: "x19", version: 2))
            )
        )
    }

    func testScalarWritebackThroughX29InvalidatesStaleFrameFact() {
        let fn = build([
            row(0x1000, "mov", "x29, sp"),
            row(0x1004, "ldr", "x0, [x29], #8"),
            row(0x1008, "mov", "x1, x29"),
            row(0x100c, "mov", "w2, w29"),
            row(0x1010, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[1].operation,
            .loadWriteback(
                destination: .register(name: "x0", version: 1),
                baseDestination: .register(name: "x29", version: 2),
                baseSource: .register(name: "x29", version: 1),
                delta: 8,
                preIndex: false
            )
        )
        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x1", version: 1),
                source: .register(name: "x29", version: 2)
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "w2", version: 1),
                source: .unary(op: "(uint32_t)", value: .register(name: "x29", version: 2))
            )
        )
    }

    func testPairWritebackThroughX29InvalidatesStaleFrameFact() {
        let fn = build([
            row(0x1000, "mov", "x29, sp"),
            row(0x1004, "stp", "x0, x1, [x29], #16"),
            row(0x1008, "mov", "x2, x29"),
            row(0x100c, "mov", "w3, w29"),
            row(0x1010, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x2", version: 1),
                source: .unknown("unavailable_x29")
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "w3", version: 1),
                source: .unknown("unavailable_w29")
            )
        )
    }

    func testScalarWritebackThroughTextualFPUsesLiveSourceAndInstallsPhysicalX29() {
        // SSA maps fp and x29 to cell 29: initial MOV is definition 1 and load writeback is definition 2.
        let fn = build([
            row(0x1000, "mov", "fp, sp"),
            row(0x1004, "ldr", "x0, [fp], #8"),
            row(0x1008, "ldr", "x1, [fp]"),
            row(0x100c, "mov", "w2, w29"),
            row(0x1010, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[1].operation,
            .loadWriteback(
                destination: .register(name: "x0", version: 1),
                baseDestination: .register(name: "x29", version: SSAPropertyAssertions.enabled ? 2 : 1),
                baseSource: .register(name: "fp", version: 1),
                delta: 8,
                preIndex: false
            )
        )
        XCTAssertEqual(
            fn.instructions[2].operation,
            .load(
                destination: .register(name: "x1", version: 1),
                address: .register(name: "x29", version: SSAPropertyAssertions.enabled ? 2 : 1)
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "w2", version: 1),
                source: .unary(op: "(uint32_t)", value: .register(name: "x29", version: SSAPropertyAssertions.enabled ? 2 : 1))
            )
        )
    }

    func testPairWritebackThroughTextualFPTombstonesPhysicalSlot29() {
        let fn = build([
            row(0x1000, "mov", "fp, sp"),
            row(0x1004, "stp", "x0, x1, [fp], #16"),
            row(0x1008, "mov", "x2, fp"),
            row(0x100c, "mov", "x3, x29"),
            row(0x1010, "mov", "w4, w29"),
            row(0x1014, "ret", ""),
        ])

        XCTAssertEqual(
            fn.instructions[2].operation,
            .assign(
                destination: .register(name: "x2", version: 1),
                source: .unknown("unavailable_fp")
            )
        )
        XCTAssertEqual(
            fn.instructions[3].operation,
            .assign(
                destination: .register(name: "x3", version: 1),
                source: .unknown("unavailable_x29")
            )
        )
        XCTAssertEqual(
            fn.instructions[4].operation,
            .assign(
                destination: .register(name: "w4", version: 1),
                source: .unknown("unavailable_w29")
            )
        )
    }

    func testW29ClobberStopsFrameSlotClassification() {
        // SSA maps x29 and w29 to cell 29; the clobber is its second definition, not a new spelling counter.
        let fn = build([
            row(0x1000, "mov", "x29, sp"),
            row(0x1004, "mov", "w29, #0"),
            row(0x1008, "ldr", "x0, [x29, #8]"),
            row(0x100c, "ret", ""),
        ])

        XCTAssertTrue(fn.localVariables.isEmpty)
        XCTAssertEqual(
            fn.instructions[2].operation,
            .load(
                destination: .register(name: "x0", version: 1),
                address: .binaryExpression(
                    op: "+",
                    left: .unary(
                        op: "(uint64_t)",
                        value: .unary(
                            op: "(uint32_t)",
                            value: .register(name: "w29", version: SSAPropertyAssertions.enabled ? 2 : 1)
                        )
                    ),
                    right: .immediate(8)
                )
            )
        )
    }

    private func build(_ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: "alias_state", instructions: rows)
    }

    private func callFrame(in function: MacIRFunction, target: String) -> MacIRCallFrame? {
        function.instructions.compactMap { instruction -> MacIRCallFrame? in
            guard case let .call(frame, _) = instruction.operation,
                  frame.target == target else {
                return nil
            }
            return frame
        }.first
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }
}

import XCTest
@testable import MacScope

/// WS-14 recovery/runtime contract. Parameter source order, ABI location, and
/// body identity are deliberately asserted independently so a passing renderer
/// cannot conceal a binding error.
final class MacIRParameterRecoveryIdentityTests: XCTestCase {
    func testDenseGPRPrefixGetsSourceOrderWithoutLosingExactViews() {
        let function = build([
            row(0x1000, "add", "x8, x0, w1, uxtw"),
            row(0x1004, "mov", "x9, x2"),
            row(0x1008, "ret"),
        ])

        assertParameters(
            function,
            expected: [
                .gpr(0): (0, .gpr(index: 0, carrierWidth: 64), "arg0"),
                .gpr(1): (1, .gpr(index: 1, carrierWidth: 32), "arg1"),
                .gpr(2): (2, .gpr(index: 2, carrierWidth: 64), "arg2"),
            ]
        )
        XCTAssertEqual(bodyArgumentBindings(in: function), Set([.gpr(0), .gpr(1), .gpr(2)]))
        XCTAssertTrue(function.parameters.allSatisfy { $0.evidence == .heuristicEntryRead })
    }

    func testDenseSIMDPrefixGetsSourceOrderWithoutLosingExactViews() {
        let function = build([
            row(0x1000, "fmov", "w8, s0"),
            row(0x1004, "fmov", "x9, d1"),
            row(0x1008, "ret"),
        ])

        assertParameters(
            function,
            expected: [
                .simd(0): (0, .simd(index: 0, scalarWidth: 32), "arg0"),
                .simd(1): (1, .simd(index: 1, scalarWidth: 64), "arg1"),
            ]
        )
        XCTAssertEqual(bodyArgumentBindings(in: function), Set([.simd(0), .simd(1)]))
    }

    func testSIMDBindingDoesNotMoveWhenAnUnrelatedGPRAppears() {
        let simdOnly = build([
            row(0x1000, "fmov", "x8, d0"),
            row(0x1004, "ret"),
        ])
        let mixed = build([
            row(0x2000, "mov", "x8, x0"),
            row(0x2004, "fmov", "x9, d0"),
            row(0x2008, "ret"),
        ])

        XCTAssertEqual(parameter(.simd(0), in: simdOnly)?.id, .recovered(.simd(0)))
        XCTAssertEqual(parameter(.simd(0), in: mixed)?.id, .recovered(.simd(0)))
        XCTAssertTrue(bodyArgumentBindings(in: simdOnly).contains(.simd(0)))
        XCTAssertTrue(bodyArgumentBindings(in: mixed).contains(.simd(0)))
    }

    func testSparseGPRRemainsABIOnly() {
        let function = build([
            row(0x1000, "mov", "x9, x1"),
            row(0x1004, "ret"),
        ])

        assertParameters(
            function,
            expected: [.gpr(1): (nil, .gpr(index: 1, carrierWidth: 64), "in_x1")]
        )
        XCTAssertEqual(bodyArgumentBindings(in: function), Set([.gpr(1)]))
    }

    func testGPRHoleMakesTheWholeRecoveredSetABIOnly() {
        let function = build([
            row(0x1000, "add", "x9, x0, x2"),
            row(0x1004, "ret"),
        ])

        assertParameters(
            function,
            expected: [
                .gpr(0): (nil, .gpr(index: 0, carrierWidth: 64), "in_x0"),
                .gpr(2): (nil, .gpr(index: 2, carrierWidth: 64), "in_x2"),
            ]
        )
    }

    func testMixedRecoveredBanksDoNotInventSourceOrder() {
        let function = build([
            row(0x1000, "mov", "x8, x0"),
            row(0x1004, "fmov", "x9, d0"),
            row(0x1008, "ret"),
        ])

        assertParameters(
            function,
            expected: [
                .gpr(0): (nil, .gpr(index: 0, carrierWidth: 64), "in_x0"),
                .simd(0): (nil, .simd(index: 0, scalarWidth: 64), "in_d0"),
            ]
        )
    }

    func testABIOnlyFallbackNamesPreserveWXSAndDViews() {
        let cases: [(register: String, instruction: (String, String), binding: MacIRParameterBindingID, location: MacIRABIParameterLocation, name: String)] = [
            ("w1", ("mov", "w9, w1"), .gpr(1), .gpr(index: 1, carrierWidth: 32), "in_w1"),
            ("x1", ("mov", "x9, x1"), .gpr(1), .gpr(index: 1, carrierWidth: 64), "in_x1"),
            ("s1", ("fmov", "w9, s1"), .simd(1), .simd(index: 1, scalarWidth: 32), "in_s1"),
            ("d1", ("fmov", "x9, d1"), .simd(1), .simd(index: 1, scalarWidth: 64), "in_d1"),
        ]

        for testCase in cases {
            let function = build([
                row(0x1000, testCase.instruction.0, testCase.instruction.1),
                row(0x1004, "ret"),
            ])
            let recovered = parameter(testCase.binding, in: function)
            XCTAssertEqual(recovered?.sourcePosition, nil, testCase.register)
            XCTAssertEqual(recovered?.abiLocation, testCase.location, testCase.register)
            XCTAssertEqual(recovered?.name, testCase.name, testCase.register)
        }
    }

    func testKnownCalleeTypesDoNotFabricateCallerFormalNames() throws {
        let function = build([
            // The direct x0 read first introduces a generic heuristic row;
            // _frexp then refines it to int *. Its d0 row is catalog-introduced.
            row(0x1000, "mov", "x8, x0"),
            row(0x1004, "bl", "_frexp"),
            row(0x1008, "ret"),
        ])

        assertParameters(
            function,
            expected: [
                .gpr(0): (nil, .gpr(index: 0, carrierWidth: 64), "in_x0"),
                .simd(0): (nil, .simd(index: 0, scalarWidth: 64), "in_d0"),
            ]
        )
        XCTAssertEqual(parameter(.gpr(0), in: function)?.type, "int *")
        XCTAssertEqual(parameter(.simd(0), in: function)?.type, "double")
        XCTAssertEqual(parameter(.gpr(0), in: function)?.evidence, .knownCallTypeConstraint)
        XCTAssertEqual(parameter(.simd(0), in: function)?.evidence, .knownCallTypeConstraint)
        XCTAssertTrue(Set(function.parameters.map(\.name)).isDisjoint(with: ["value", "exp"]))
        XCTAssertEqual(
            try callArguments(target: "_frexp", in: function),
            [.argument(bindingID: .simd(0)), .argument(bindingID: .gpr(0))]
        )
    }

    func testLocalGPRWriteTakesPrecedenceOverAuthoritativeIncomingBinding() {
        let function = build(
            [
                row(0x1000, "mov", "x1, #7"),
                row(0x1004, "mov", "x9, x1"),
                row(0x1008, "ret"),
            ],
            plan: plan([
                authoritativeGPR(0, sourcePosition: 0, name: "leading"),
                authoritativeGPR(1, sourcePosition: 1, name: "value"),
            ])
        )

        XCTAssertEqual(assignSource(at: 1, in: function), .register(name: "x1", version: 1))
        XCTAssertFalse(argumentBindings(in: assignSource(at: 1, in: function)).contains(.gpr(1)))
    }

    func testLocalSIMDWriteTakesPrecedenceOverAuthoritativeIncomingBinding() {
        let function = build(
            [
                row(0x1000, "fmov", "d1, #2.0"),
                row(0x1004, "fmov", "x9, d1"),
                row(0x1008, "ret"),
            ],
            plan: plan([
                authoritativeSIMD(0, sourcePosition: 0, name: "leading"),
                authoritativeSIMD(1, sourcePosition: 1, name: "value"),
            ])
        )

        XCTAssertEqual(intrinsicArguments(at: 1, in: function), [.register(name: "d1", version: 1)])
        XCTAssertFalse(
            intrinsicArguments(at: 1, in: function)
                .flatMap { argumentBindings(in: $0) }
                .contains(.simd(1))
        )
    }

    func testScalarFPProducerReplacesNonzeroAuthoritativeBinding() {
        let function = build(
            [
                row(0x1000, "fadd", "d1, d1, d1"),
                row(0x1004, "fmov", "x9, d1"),
                row(0x1008, "ret"),
            ],
            plan: plan([
                authoritativeSIMD(0, sourcePosition: 0, name: "leading"),
                authoritativeSIMD(1, sourcePosition: 1, name: "value"),
            ])
        )

        XCTAssertEqual(intrinsicArguments(at: 1, in: function), [.register(name: "d1", version: 1)])
    }

    func testScalarFPRoundingReplacesNonzeroAuthoritativeBinding() {
        let function = build(
            [
                row(0x1000, "frintn", "d1, d1"),
                row(0x1004, "fmov", "x9, d1"),
                row(0x1008, "ret"),
            ],
            plan: plan([
                authoritativeSIMD(0, sourcePosition: 0, name: "leading"),
                authoritativeSIMD(1, sourcePosition: 1, name: "value"),
            ])
        )

        XCTAssertEqual(intrinsicArguments(at: 1, in: function), [.register(name: "d1", version: 1)])
    }

    func testCallTombstonesPreventIncomingGPRAndSIMDResurrection() {
        let function = build(
            [
                row(0x1000, "bl", "_arc4random_stir"),
                row(0x1004, "mov", "x9, x1"),
                row(0x1008, "fmov", "x10, d1"),
                row(0x100c, "ret"),
            ],
            plan: plan([
                authoritativeGPR(0, sourcePosition: 0, name: "leadingInteger"),
                authoritativeSIMD(0, sourcePosition: 1, name: "leadingFloating"),
                authoritativeGPR(1, sourcePosition: 2, name: "integerValue"),
                authoritativeSIMD(1, sourcePosition: 3, name: "floatingValue"),
            ])
        )

        XCTAssertEqual(assignSource(at: 1, in: function), .unknown("unavailable_x1"))
        XCTAssertEqual(intrinsicArguments(at: 2, in: function), [.unknown("unavailable_d1")])
    }

    func testAuthoritativeMetadataDoesNotChangeLinearBranchOperationsOrLocalValues() {
        let rows = [
            row(0x1000, "cbz", "x0, 0x1008"),
            row(0x1004, "mov", "x1, #7"),
            row(0x1008, "mov", "x9, x1"),
            row(0x100c, "ret"),
        ]
        let automatic = build(rows)
        let authoritative = build(
            rows,
            plan: plan([
                authoritativeGPR(0, sourcePosition: 0, name: "condition"),
            ])
        )

        XCTAssertEqual(authoritative.instructions.map(\.source), automatic.instructions.map(\.source))
        // Authored GPR formals are entry facts: both builds take the same
        // predecessor-aware CFG path, with identical operations and phis.
        XCTAssertEqual(authoritative.instructions.map(\.operation), automatic.instructions.map(\.operation))
        XCTAssertEqual(authoritative.phis, automatic.phis)
        XCTAssertEqual(authoritative.localVariables, automatic.localVariables)
        XCTAssertEqual(authoritative.callTargets, automatic.callTargets)
        // The join's x1 is the CFG phi in both builds, not the last textual writer.
        let joined = assignSource(at: 2, in: authoritative)
        XCTAssertEqual(joined, assignSource(at: 2, in: automatic))
        XCTAssertTrue(authoritative.phis.contains { $0.destination == joined })

        // Variadic metadata does not change predecessor-specific SSA dataflow.
        let variadic = MacIRAuthoritativeParameterPlan(
            parameters: [authoritativeGPR(0, sourcePosition: 0, name: "condition")], isVariadic: true)
        let linear = build(rows, plan: variadic)
        if SSAPropertyAssertions.enabled {
            let matches = linear.phis.filter { $0.blockAddress == 0x1008 && $0.cell == 1 }
            XCTAssertEqual(matches.count, 1)
            guard let phi = matches.first, let info = linear.ssaInfo else {
                return XCTFail("variadic join requires persisted SSA provenance")
            }
            XCTAssertEqual(phi.bitWidth, 64)
            XCTAssertEqual(phi.incoming.map(\.machineAddress), [0x1000, 0x1004])
            guard phi.incoming.count == 2 else { return }
            XCTAssertEqual(assignSource(at: 2, in: linear), phi.destination)
            let planned = info.plan.phis.filter { $0.cell == 1 }
            XCTAssertEqual(planned.count, 1)
            guard let join = planned.first else { return }
            XCTAssertEqual(join.incoming.map(\.machineAddress), [0x1000, 0x1004])
            XCTAssertEqual(join.incoming.map { info.plan.definitions[info.plan.canonicalID($0.definition)].origin },
                           [.entry, .instruction(0x1004)])
            XCTAssertEqual(phi.incoming.map(\.value), join.incoming.map {
                info.values[info.plan.canonicalID($0.definition)]
            }.compactMap { $0 })
            let writes = linear.instructions.filter { $0.source.address == 0x1004 }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?.operation,
                           .assign(destination: phi.incoming[1].value, source: .immediate(7)))
        } else {
            XCTAssertTrue(linear.phis.isEmpty)
            XCTAssertEqual(assignSource(at: 2, in: linear), .unknown("unavailable_x1"))
        }
    }

    func testSIMDViewRecoveryIsWidestAndIndependentOfObservationOrder() {
        let observationOrders = [
            [
                row(0x1000, "fmov", "x8, d1"),
                row(0x1004, "fmov", "w9, s1"),
            ],
            [
                row(0x2000, "fmov", "w9, s1"),
                row(0x2004, "fmov", "x8, d1"),
            ],
        ]

        for rows in observationOrders {
            let function = build(rows + [row(rows.last!.address + 4, "ret")])
            let recovered = parameter(.simd(1), in: function)
            XCTAssertEqual(recovered?.abiLocation, .simd(index: 1, scalarWidth: 64))
            XCTAssertEqual(recovered?.type, "double")
            XCTAssertEqual(recovered?.name, "in_d1")
            XCTAssertEqual(recovered?.evidence, .heuristicEntryRead)
        }
    }

    func testAuthoritativeEntryStackLocationWithoutBodyAccessStaysUnbound() {
        let function = build(
            [row(0x1000, "ret")],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertEqual(ninth?.abiLocation, .entryStack(byteOffset: 0, size: 8, alignment: 8))
        XCTAssertNil(ninth?.bindingID, "a declaration location alone must not invent a body use")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testProvenEntrySPAccessBindsTheAuthoritativeStackParameter() {
        let function = build(
            [
                row(0x1000, "ldr", "x9, [sp]"),
                row(0x1004, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertEqual(ninth?.bindingID, .entryStack(byteOffset: 0))
        XCTAssertTrue(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testPostPrologueLocalSPAccessDoesNotBindEntryStackParameter() {
        let function = build(
            [
                row(0x1000, "sub", "sp, sp, #0x10"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "add", "sp, sp, #0x10"),
                row(0x100c, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertNil(ninth?.bindingID, "post-prologue [sp] is a local slot, not entry SP")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testPairWritebackPrologueInvalidatesEntrySPBinding() {
        let function = build(
            [
                row(0x1000, "stp", "x29, x30, [sp, #-16]!"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertNil(ninth?.bindingID, "pair writeback moves SP away from its entry value")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testUnmodeledStackPointerDestinationInvalidatesEntrySPBinding() {
        let function = build(
            [
                row(0x1000, "addg", "sp, sp, #0, #0"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertNil(ninth?.bindingID, "an unmodeled definite SP write destroys entry-SP provenance")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testUnmodeledEntrySPStoreInvalidatesStackParameterValueProvenance() {
        let function = build(
            [
                row(0x1000, "stlr", "x10, [sp]"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertNil(ninth?.bindingID, "a store to the incoming slot destroys its formal value")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testUnmodeledEntrySPStoreCannotResurrectACachedStackParameterValue() {
        let function = build(
            [
                row(0x1000, "ldr", "x9, [sp]"),
                row(0x1004, "str", "x9, [sp]"),
                row(0x1008, "stlr", "x10, [sp]"),
                row(0x100c, "ldr", "x11, [sp]"),
                row(0x1010, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        XCTAssertEqual(
            function.instructions[3].operation,
            .load(
                destination: .register(name: "x11", version: 1),
                address: .stackSlot(offset: 0)
            ),
            "the unknown overwrite must discard the earlier stack-slot value fact"
        )
        XCTAssertFalse(
            values(in: function.instructions[3].operation)
                .flatMap { argumentBindings(in: $0) }
                .contains(.entryStack(byteOffset: 0))
        )
    }

    func testModeledHalfwordStoreInvalidatesOverlappingPackedStackFormals() {
        let function = build(
            [
                row(0x1000, "strh", "w10, [sp]"),
                row(0x1004, "ldrb", "w9, [sp, #1]"),
                row(0x1008, "ret"),
            ],
            plan: tenCharParameterPlan()
        )

        let tenth = function.parameters.first { $0.sourcePosition == 9 }
        XCTAssertNil(tenth?.bindingID, "the halfword store overwrites packed byte offset 1")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 1)))
    }

    func testModeledHalfwordStoreCannotResurrectAnOverlappingCachedValueRange() {
        let function = build(
            [
                row(0x1000, "ldr", "x9, [sp]"),
                row(0x1004, "str", "x9, [sp, #1]"),
                row(0x1008, "strh", "w10, [sp]"),
                row(0x100c, "ldr", "x11, [sp, #1]"),
                row(0x1010, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        XCTAssertEqual(
            function.instructions[3].operation,
            .load(
                destination: .register(name: "x11", version: 1),
                address: .stackSlot(offset: 1)
            ),
            "a two-byte write at offset zero must discard an eight-byte fact starting at offset one"
        )
        XCTAssertFalse(
            values(in: function.instructions[3].operation)
                .flatMap { argumentBindings(in: $0) }
                .contains(.entryStack(byteOffset: 0))
        )
    }

    func testNarrowStackStoreDoesNotForwardAnUnmodeledTruncation() {
        let function = build([
            row(0x1000, "mov", "w9, #0x12345"),
            row(0x1004, "strb", "w9, [sp]"),
            row(0x1008, "ldrb", "w10, [sp]"),
            row(0x100c, "ret"),
        ])

        XCTAssertEqual(
            function.instructions[2].operation,
            .load(
                destination: .register(name: "w10", version: 1),
                address: .stackSlot(offset: 0)
            ),
            "without an explicit truncate/extend value, a byte spill must not forward the full w-register"
        )
    }

    func testStackValueCacheDoesNotForwardAcrossIntegerAndScalarFPViews() {
        let function = build([
            row(0x1000, "mov", "x9, #1"),
            row(0x1004, "str", "x9, [sp]"),
            row(0x1008, "ldr", "d0, [sp]"),
            row(0x100c, "ret"),
        ])

        XCTAssertEqual(
            function.instructions[2].operation,
            .load(
                destination: .register(name: "d0", version: 1),
                address: .stackSlot(offset: 0)
            ),
            "an integer value requires an explicit bit-view operation before a scalar-FP reload can use it"
        )
    }

    func testModeledRegisterIndexedEntrySPStoreInvalidatesAllStackFormalProvenance() {
        let function = build(
            [
                row(0x1000, "str", "x10, [sp, x11]"),
                row(0x1004, "ldr", "x9, [sp, #8]"),
                row(0x1008, "ret"),
            ],
            plan: tenIntegerParameterPlan()
        )

        let tenth = function.parameters.first { $0.sourcePosition == 9 }
        XCTAssertNil(tenth?.bindingID, "an unknown indexed store may alias any stack formal")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 8)))
    }

    func testScalarSPWritebackInvalidatesEntrySPForPreAndPostIndexForms() {
        let cases: [[InstructionRow]] = [
            [
                row(0x1000, "ldr", "x10, [sp, #0x10]!"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "ret"),
            ],
            [
                row(0x2000, "str", "x10, [sp], #0x10"),
                row(0x2004, "ldr", "x9, [sp]"),
                row(0x2008, "ret"),
            ],
        ]

        for rows in cases {
            let function = build(rows, plan: nineIntegerParameterPlan())
            let ninth = function.parameters.first { $0.sourcePosition == 8 }
            XCTAssertNil(ninth?.bindingID, "SP writeback moves the base away from entry SP")
            XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
        }
    }

    func testUnmodeledMTEWritebackInvalidatesEntrySPBinding() {
        let function = build(
            [
                row(0x1000, "stg", "x10, [sp, #0x10]!"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        let ninth = function.parameters.first { $0.sourcePosition == 8 }
        XCTAssertNil(ninth?.bindingID, "unmodeled MTE writeback must invalidate entry SP")
        XCTAssertFalse(bodyArgumentBindings(in: function).contains(.entryStack(byteOffset: 0)))
    }

    func testStackPointerWritebackCannotResurrectACachedStackParameterValue() {
        let function = build(
            [
                row(0x1000, "ldr", "x9, [sp]"),
                row(0x1004, "str", "x9, [sp]"),
                row(0x1008, "stg", "x10, [sp, #0x10]!"),
                row(0x100c, "ldr", "x11, [sp]"),
                row(0x1010, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        XCTAssertEqual(
            function.instructions[3].operation,
            .load(
                destination: .register(name: "x11", version: 1),
                address: .stackSlot(offset: 0)
            ),
            "moving SP must discard stack-slot facts recorded in the old coordinate system"
        )
        XCTAssertFalse(
            values(in: function.instructions[3].operation)
                .flatMap { argumentBindings(in: $0) }
                .contains(.entryStack(byteOffset: 0))
        )
    }

    func testScalarStoreWritebackThroughFrameAliasCannotResurrectCachedStackParameter() {
        let function = build(
            [
                row(0x1000, "mov", "x29, sp"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "str", "x9, [sp]"),
                row(0x100c, "str", "x10, [x29], #8"),
                row(0x1010, "ldr", "x11, [sp]"),
                row(0x1014, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        XCTAssertEqual(
            function.instructions[4].operation,
            .load(
                destination: .register(name: "x11", version: 1),
                address: .stackSlot(offset: 0)
            ),
            "a store through a proven FP alias overwrites the entry-stack cache before moving the alias"
        )
        XCTAssertFalse(
            values(in: function.instructions[4].operation)
                .flatMap { argumentBindings(in: $0) }
                .contains(.entryStack(byteOffset: 0))
        )
    }

    func testPairStoreWritebackThroughFrameAliasCannotResurrectCachedStackParameter() {
        let function = build(
            [
                row(0x1000, "mov", "x29, sp"),
                row(0x1004, "ldr", "x9, [sp]"),
                row(0x1008, "str", "x9, [sp]"),
                row(0x100c, "stp", "x10, x12, [x29], #16"),
                row(0x1010, "ldr", "x11, [sp]"),
                row(0x1014, "ret"),
            ],
            plan: nineIntegerParameterPlan()
        )

        XCTAssertEqual(
            function.instructions[4].operation,
            .load(
                destination: .register(name: "x11", version: 1),
                address: .stackSlot(offset: 0)
            ),
            "pair-store writeback through a proven FP alias must invalidate every possibly overwritten stack fact"
        )
        XCTAssertFalse(
            values(in: function.instructions[4].operation)
                .flatMap { argumentBindings(in: $0) }
                .contains(.entryStack(byteOffset: 0))
        )
    }

    func testRegisterIndexedStoreThroughFrameAliasCannotResurrectCachedStackParameter() {
        let function = build(
            [
                row(0x1000, "mov", "x29, sp"),
                row(0x1004, "ldr", "x9, [sp, #8]"),
                row(0x1008, "str", "x9, [sp, #8]"),
                row(0x100c, "str", "x10, [x29, x11]"),
                row(0x1010, "ldr", "x12, [sp, #8]"),
                row(0x1014, "ret"),
            ],
            plan: tenIntegerParameterPlan()
        )

        XCTAssertEqual(
            function.instructions[4].operation,
            .load(
                destination: .register(name: "x12", version: 1),
                address: .stackSlot(offset: 8)
            ),
            "an indexed store through a proven FP alias may overwrite any cached entry-stack slot"
        )
        XCTAssertFalse(
            values(in: function.instructions[4].operation)
                .flatMap { argumentBindings(in: $0) }
                .contains(.entryStack(byteOffset: 8))
        )
    }

    func testUnmodeledSIMDPostIndexTombstonesTheWrittenBaseRegister() {
        let function = build(
            [
                row(0x1000, "ld1", "{v0.16b}, [x0], #0x10"),
                row(0x1004, "mov", "x9, x0"),
                row(0x1008, "ret"),
            ],
            plan: plan([
                authoritativeGPR(0, sourcePosition: 0, name: "buffer"),
            ])
        )

        XCTAssertEqual(assignSource(at: 1, in: function), .unknown("unavailable_x0"))
        XCTAssertFalse(argumentBindings(in: assignSource(at: 1, in: function)).contains(.gpr(0)))
    }

    func testPairLoadFallbackKeepsTheArchitecturalSecondStackSlot() {
        let function = build([
            row(0x1000, "sub", "sp, sp, #0x50"),
            row(0x1004, "str", "q0, [sp, #0x30]"),
            row(0x1008, "str", "x12, [sp, #0x40]"),
            row(0x100c, "str", "x10, [sp, x11]"),
            row(0x1010, "ldp", "w10, w9, [sp, #0x30]"),
            row(0x1014, "ret"),
        ])

        XCTAssertEqual(
            function.instructions[4].operation,
            .intrinsic(
                destination: nil,
                name: "restore_pair",
                arguments: [
                    .register(name: "w10", version: 1),
                    .register(name: "w9", version: 1),
                    .stackSlot(offset: 0x30),
                    .stackSlot(offset: 0x34),
                ]
            ),
            "pair fallback must carry the decoded element width instead of deriving it from an overlapping wider local"
        )

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("= *(uint32_t *)&(local_30), *(uint32_t *)&(local_34)"), text)
        XCTAssertFalse(text.contains("= local_30, local_40"), text)
    }

    func testPairStoreFallbackKeepsTheArchitecturalSecondStackSlot() {
        let function = build([
            row(0x1000, "sub", "sp, sp, #0x50"),
            row(0x1004, "str", "q0, [sp, #0x30]"),
            row(0x1008, "str", "x12, [sp, #0x40]"),
            row(0x100c, "stp", "w10, w9, [sp, #0x30]"),
            row(0x1010, "ret"),
        ])

        XCTAssertEqual(
            function.instructions[3].operation,
            .intrinsic(
                destination: nil,
                name: "save_pair",
                arguments: [
                    .register(name: "w10", version: 0),
                    .register(name: "w9", version: 0),
                    .stackSlot(offset: 0x30),
                    .stackSlot(offset: 0x34),
                ]
            )
        )

        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("*(uint32_t *)&(local_30), *(uint32_t *)&(local_34) ="), text)
        XCTAssertFalse(text.contains("local_30, local_40 ="), text)
    }

    func testAuthoritativePlanRejectsPreboundEntryStackDeclaration() {
        var parameters = (0..<8).map { index in
            authoritativeGPR(index, sourcePosition: index, name: "value\(index)")
        }
        parameters.append(MacIRFunctionParameter(
            id: .init(rawValue: "auth:8:stack:prebound"),
            bindingID: .entryStack(byteOffset: 0),
            sourcePosition: 8,
            abiLocation: .entryStack(byteOffset: 0, size: 8, alignment: 8),
            type: "int64_t",
            name: "value8",
            evidence: .authoritativeUser
        )!)

        XCTAssertNil(
            MacIRAuthoritativeParameterPlan(parameters: parameters, isVariadic: false),
            "an ABI location is declaration metadata, not proof of a body binding"
        )
    }

    private func build(
        _ rows: [InstructionRow],
        plan: MacIRAuthoritativeParameterPlan? = nil
    ) -> MacIRFunction {
        MacIRBuilder().buildFunction(
            name: "parameter_identity",
            authoritativeParameterPlan: plan,
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

    private func plan(_ parameters: [MacIRFunctionParameter]) -> MacIRAuthoritativeParameterPlan {
        guard let plan = MacIRAuthoritativeParameterPlan(parameters: parameters, isVariadic: false) else {
            preconditionFailure("authoritative test fixture must have contiguous source positions and unique bindings")
        }
        return plan
    }

    private func authoritativeGPR(
        _ index: Int,
        sourcePosition: Int?,
        name: String,
        type: String = "int64_t"
    ) -> MacIRFunctionParameter {
        MacIRFunctionParameter(
            id: .init(rawValue: "auth:\(sourcePosition.map(String.init) ?? "abi"):gpr:\(index)"),
            bindingID: .gpr(index),
            sourcePosition: sourcePosition,
            abiLocation: .gpr(index: index, carrierWidth: 64),
            type: type,
            name: name,
            evidence: .authoritativeUser
        )!
    }

    private func authoritativeSIMD(
        _ index: Int,
        sourcePosition: Int?,
        name: String,
        type: String = "double"
    ) -> MacIRFunctionParameter {
        MacIRFunctionParameter(
            id: .init(rawValue: "auth:\(sourcePosition.map(String.init) ?? "abi"):simd:\(index)"),
            bindingID: .simd(index),
            sourcePosition: sourcePosition,
            abiLocation: .simd(index: index, scalarWidth: 64),
            type: type,
            name: name,
            evidence: .authoritativeUser
        )!
    }

    private func nineIntegerParameterPlan() -> MacIRAuthoritativeParameterPlan {
        var parameters = (0..<8).map { index in
            authoritativeGPR(index, sourcePosition: index, name: "value\(index)")
        }
        parameters.append(MacIRFunctionParameter(
            id: .init(rawValue: "auth:8:stack:0"),
            bindingID: nil,
            sourcePosition: 8,
            abiLocation: .entryStack(byteOffset: 0, size: 8, alignment: 8),
            type: "int64_t",
            name: "value8",
            evidence: .authoritativeUser
        )!)
        return plan(parameters)
    }

    private func tenIntegerParameterPlan() -> MacIRAuthoritativeParameterPlan {
        var parameters = (0..<8).map { index in
            authoritativeGPR(index, sourcePosition: index, name: "value\(index)")
        }
        for stackIndex in 0..<2 {
            parameters.append(MacIRFunctionParameter(
                id: .init(rawValue: "auth:\(stackIndex + 8):stack:\(stackIndex * 8)"),
                bindingID: nil,
                sourcePosition: stackIndex + 8,
                abiLocation: .entryStack(byteOffset: stackIndex * 8, size: 8, alignment: 8),
                type: "int64_t",
                name: "value\(stackIndex + 8)",
                evidence: .authoritativeUser
            )!)
        }
        return plan(parameters)
    }

    private func tenCharParameterPlan() -> MacIRAuthoritativeParameterPlan {
        var parameters = (0..<8).map { index in
            MacIRFunctionParameter(
                id: .init(rawValue: "auth:\(index):gpr:\(index)"),
                bindingID: .gpr(index),
                sourcePosition: index,
                abiLocation: .gpr(index: index, carrierWidth: 32),
                type: "char",
                name: "value\(index)",
                evidence: .authoritativeUser
            )!
        }
        for stackIndex in 0..<2 {
            parameters.append(MacIRFunctionParameter(
                id: .init(rawValue: "auth:\(stackIndex + 8):stack:\(stackIndex)"),
                bindingID: nil,
                sourcePosition: stackIndex + 8,
                abiLocation: .entryStack(byteOffset: stackIndex, size: 1, alignment: 1),
                type: "char",
                name: "value\(stackIndex + 8)",
                evidence: .authoritativeUser
            )!)
        }
        return plan(parameters)
    }

    private func parameter(
        _ bindingID: MacIRParameterBindingID,
        in function: MacIRFunction
    ) -> MacIRFunctionParameter? {
        function.parameters.first { $0.bindingID == bindingID }
    }

    private func assertParameters(
        _ function: MacIRFunction,
        expected: [MacIRParameterBindingID: (Int?, MacIRABIParameterLocation, String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(function.parameters.count, expected.count, file: file, line: line)
        XCTAssertEqual(Set(function.parameters.compactMap(\.bindingID)), Set(expected.keys), file: file, line: line)
        for (bindingID, expectation) in expected {
            let recovered = parameter(bindingID, in: function)
            XCTAssertEqual(recovered?.sourcePosition, expectation.0, "\(bindingID)", file: file, line: line)
            XCTAssertEqual(recovered?.abiLocation, expectation.1, "\(bindingID)", file: file, line: line)
            XCTAssertEqual(recovered?.name, expectation.2, "\(bindingID)", file: file, line: line)
        }
    }

    private func callArguments(target: String, in function: MacIRFunction) throws -> [MacIRValue] {
        for instruction in function.instructions {
            if case let .call(frame, _) = instruction.operation, frame.target == target {
                return frame.arguments.denseFixedPrefixValues()
            }
        }
        throw TestFailure.missingCall(target)
    }

    private func assignSource(at index: Int, in function: MacIRFunction) -> MacIRValue {
        guard case let .assign(_, source) = function.instructions[index].operation else {
            XCTFail("expected assignment at instruction \(index)")
            return .unknown("missing_assignment")
        }
        return source
    }

    private func intrinsicArguments(at index: Int, in function: MacIRFunction) -> [MacIRValue] {
        guard case let .intrinsic(_, _, arguments) = function.instructions[index].operation else {
            XCTFail("expected intrinsic at instruction \(index)")
            return []
        }
        return arguments
    }

    private func bodyArgumentBindings(in function: MacIRFunction) -> Set<MacIRParameterBindingID> {
        Set(
            function.instructions
                .flatMap { values(in: $0.operation) }
                .flatMap { argumentBindings(in: $0) }
        )
    }

    private func argumentBindings(in value: MacIRValue) -> [MacIRParameterBindingID] {
        switch value {
        case let .argument(bindingID):
            [bindingID]
        case let .abiComposite(_, fragments):
            fragments.flatMap { argumentBindings(in: $0) }
        case .argumentFragment:
            []
        case let .bitTest(value, _), let .unary(_, value):
            argumentBindings(in: value)
        case let .binaryExpression(_, left, right):
            argumentBindings(in: left) + argumentBindings(in: right)
        case let .signedBitfield(field):
            argumentBindings(in: field.source)
        case .register, .immediate, .stackSlot, .symbol, .temporary, .unknown:
            []
        }
    }

    private func values(in operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, source):
            [destination, source]
        case let .binary(destination, _, left, right):
            [destination, left, right]
        case let .load(destination, address):
            [destination, address]
        case let .store(source, address):
            [source, address]
        case let .loadWriteback(destination, baseDestination, baseSource, delta: _, preIndex: _):
            [destination, baseDestination, baseSource]
        case let .storeWriteback(source, baseDestination, baseSource, delta: _, preIndex: _):
            [source, baseDestination, baseSource]
        case let .stackSlotRead(destination, slot, value):
            [destination, slot, value]
        case let .stackSlotPairRead(firstDestination, firstSlot, firstValue, secondDestination, secondSlot, secondValue):
            [firstDestination, firstSlot, firstValue, secondDestination, secondSlot, secondValue]
        case let .call(frame, result):
            frame.bindingValues + [result].compactMap { $0 }
        case let .conditionalBranch(_, left, right, target):
            [left, right, target]
        case let .select(destination, _, left, right, trueValue, falseValue):
            [destination, left, right, trueValue, falseValue]
        case let .compareToBool(destination, _, left, right):
            [destination, left, right]
        case let .returnValue(value):
            [value].compactMap { $0 }
        case let .intrinsic(destination, _, arguments):
            [destination].compactMap { $0 } + arguments
        case let .switchDispatch(index, cases, defaultTarget):
            [index] + cases.map(\.target) + [defaultTarget].compactMap { $0 }
        case let .unknown(destination, _, _, _):
            [destination].compactMap { $0 }
        }
    }

    private enum TestFailure: Error {
        case missingCall(String)
    }
}

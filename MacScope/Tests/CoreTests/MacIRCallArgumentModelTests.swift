import XCTest
@testable import MacScope

/// WS-15 Phase A: physical call location, fixed source position, anonymous-tail
/// order, and rendering order are separate namespaces. The runtime migration is
/// implemented and full CoreTests validation is complete under the golden policy.
final class MacIRCallArgumentModelTests: XCTestCase {
    private func requireHashableAndSendableModelTypes() {
        requireHashableAndSendable(MacIRCallArgumentPhysicalKey.self)
        requireHashableAndSendable(MacIRCallArgumentLocation.self)
        requireHashableAndSendable(MacIRCallArgumentRole.self)
        requireHashableAndSendable(MacIRCallSelectorEvidence.self)
        requireHashableAndSendable(MacIRCallArgument.self)
        requireHashableAndSendable(MacIRCallArgumentObservationScope.self)
        requireHashableAndSendable(MacIRCallArguments.self)
        requireHashableAndSendable(MacIRCallControlInputRole.self)
        requireHashableAndSendable(MacIRCallControlRegister.self)
        requireHashableAndSendable(MacIRCallControlInput.self)
        requireHashableAndSendable(MacIRCallControlInputs.self)
        requireHashableAndSendable(MacIRCallTailCountEvidence.self)
        requireHashableAndSendable(MacIRCallFrame.self)
    }

    func testRegisterLocationsNormalizeAliasesWhileRetainingExactView() throws {
        let x0 = try XCTUnwrap(MacIRCallArgumentLocation(register: "x0"))
        let w0 = try XCTUnwrap(MacIRCallArgumentLocation(register: "W0"))
        let d0 = try XCTUnwrap(MacIRCallArgumentLocation(register: "d0"))
        let s0 = try XCTUnwrap(MacIRCallArgumentLocation(register: "S0"))

        XCTAssertEqual(x0.physicalKey, .gpr(index: 0))
        XCTAssertEqual(w0.physicalKey, .gpr(index: 0))
        XCTAssertEqual(d0.physicalKey, .simd(index: 0))
        XCTAssertEqual(s0.physicalKey, .simd(index: 0))
        XCTAssertNotEqual(x0.physicalKey, d0.physicalKey)
        XCTAssertEqual(x0.registerName, "x0")
        XCTAssertEqual(w0.registerName, "w0")
        XCTAssertEqual(d0.registerName, "d0")
        XCTAssertEqual(s0.registerName, "s0")

        XCTAssertEqual(
            try XCTUnwrap(MacIRCallArgumentLocation(register: "x7")),
            .gpr(index: 7, carrierWidth: 64)
        )
        XCTAssertEqual(
            try XCTUnwrap(MacIRCallArgumentLocation(register: "w7")),
            .gpr(index: 7, carrierWidth: 32)
        )
        XCTAssertEqual(
            try XCTUnwrap(MacIRCallArgumentLocation(register: "d7")),
            .simd(index: 7, scalarWidth: 64)
        )
        XCTAssertEqual(
            try XCTUnwrap(MacIRCallArgumentLocation(register: "s7")),
            .simd(index: 7, scalarWidth: 32)
        )
    }

    func testRegisterLocationParserRejectsMalformedAndOutOfDomainSpellings() {
        for spelling in [
            "x8", "w8", "d8", "s8", "x-1", "x+1", "x01", "q0", "v0",
            "sp", "xzr", "wzr", " x0", "x0 ", "x0junk", "x", "",
        ] {
            XCTAssertNil(
                MacIRCallArgumentLocation(register: spelling),
                "unexpectedly accepted \(spelling.debugDescription)"
            )
        }

        for location in [
            MacIRCallArgumentLocation.gpr(index: 8, carrierWidth: 64),
            .gpr(index: 0, carrierWidth: 16),
            .simd(index: -1, scalarWidth: 64),
            .simd(index: 0, scalarWidth: 128),
        ] {
            XCTAssertNil(location.physicalKey)
            XCTAssertNil(location.registerName)
        }
    }

    func testCallStackLocationRequiresAlignedNonoverflowingRange() {
        let valid: [(MacIRCallArgumentLocation, MacIRCallArgumentPhysicalKey)] = [
            (.callStack(byteOffset: 0, size: 8, alignment: 8), .callStack(byteOffset: 0)),
            (.callStack(byteOffset: 1, size: 1, alignment: 1), .callStack(byteOffset: 1)),
            (.callStack(byteOffset: 16, size: 16, alignment: 16), .callStack(byteOffset: 16)),
        ]
        for (location, key) in valid {
            XCTAssertEqual(location.physicalKey, key)
            XCTAssertNil(location.registerName)
        }

        for location in [
            MacIRCallArgumentLocation.callStack(byteOffset: -1, size: 8, alignment: 8),
            .callStack(byteOffset: 0, size: 0, alignment: 1),
            .callStack(byteOffset: 0, size: -1, alignment: 1),
            .callStack(byteOffset: 0, size: 1, alignment: 0),
            .callStack(byteOffset: 0, size: 1, alignment: -1),
            .callStack(byteOffset: 0, size: 1, alignment: 3),
            .callStack(byteOffset: 2, size: 8, alignment: 8),
            .callStack(byteOffset: Int.max - 3, size: 8, alignment: 1),
        ] {
            XCTAssertNil(location.physicalKey)
        }
    }

    func testArgumentRolesExposeOnlyTheirOwnOrdinalNamespace() {
        XCTAssertEqual(MacIRCallArgumentRole.fixed(sourcePosition: 3).sourcePosition, 3)
        XCTAssertNil(MacIRCallArgumentRole.fixed(sourcePosition: 3).tailOrdinal)
        XCTAssertNil(MacIRCallArgumentRole.anonymousVariadic(tailOrdinal: 2).sourcePosition)
        XCTAssertEqual(MacIRCallArgumentRole.anonymousVariadic(tailOrdinal: 2).tailOrdinal, 2)
        XCTAssertNil(MacIRCallArgumentRole.unknown.sourcePosition)
        XCTAssertNil(MacIRCallArgumentRole.unknown.tailOrdinal)

        let record = gprArgument(0, role: .fixed(sourcePosition: 4), value: "fixed")
        XCTAssertEqual(record.sourcePosition, 4)
        XCTAssertNil(record.tailOrdinal)
    }

    func testSelectorEvidenceIsAdditivePresentationMetadata() throws {
        for invalidName in [
            "",
            "set\"Object:",
            "set\\Object:",
            "set\nObject:",
            "set\u{2028}Object:",
            "set\u{2029}Object:",
        ] {
            XCTAssertNil(
                MacIRCallSelectorEvidence(name: invalidName, selrefAddress: 0x1000),
                "unexpectedly accepted selector \(invalidName.debugDescription)"
            )
        }
        let evidence = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "setObject:forKey:", selrefAddress: 0x1000)
        )
        let original = MacIRValue.register(name: "x1", version: 3)
        let record = MacIRCallArgument(
            location: .gpr(index: 1, carrierWidth: 64),
            role: .fixed(sourcePosition: 1),
            value: original,
            selectorEvidence: evidence
        )
        let frame = try arguments([record])

        XCTAssertEqual(frame.fixedArgument(at: 1)?.value, original)
        XCTAssertEqual(frame.fixedArgument(at: 1)?.selectorEvidence, evidence)
        XCTAssertEqual(frame.bindingValues, [original])

        XCTAssertNil(MacIRCallArguments([
            MacIRCallArgument(
                location: .gpr(index: 2, carrierWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: original,
                selectorEvidence: evidence
            ),
        ]))
        XCTAssertNil(MacIRCallArguments([
            MacIRCallArgument(
                location: .gpr(index: 1, carrierWidth: 64),
                role: .fixed(sourcePosition: 0),
                value: original,
                selectorEvidence: evidence
            ),
        ]))
    }

    func testObservationScopeCanonicalizesAndPreservesExactCoverage() throws {
        let left = try scope(
            gprs: [7, 0, 2],
            simd: [3, 1],
            stack: [16..<24, 0..<8, 8..<16]
        )
        let right = try scope(
            gprs: [2, 7, 0],
            simd: [1, 3],
            stack: [8..<16, 16..<24, 0..<8]
        )

        XCTAssertEqual(left, right)
        XCTAssertEqual(Set([left, right]).count, 1)
        XCTAssertEqual(left.canonicalGPRIndicesForAudit, [0, 2, 7])
        XCTAssertEqual(left.canonicalScalarSIMDIndicesForAudit, [1, 3])
        XCTAssertEqual(left.canonicalCallStackRangesForAudit, [0..<8, 8..<16, 16..<24])
        XCTAssertTrue(left.observes(.gpr(index: 0, carrierWidth: 32)))
        XCTAssertTrue(left.observes(.simd(index: 3, scalarWidth: 64)))
        XCTAssertFalse(left.observes(.gpr(index: 1, carrierWidth: 64)))
        XCTAssertFalse(MacIRCallArgumentObservationScope.none.observes(
            .gpr(index: 0, carrierWidth: 64)
        ))
    }

    func testObservationScopeRejectsInvalidOrOverlappingCoverage() throws {
        XCTAssertNil(MacIRCallArgumentObservationScope(gprIndices: [-1]))
        XCTAssertNil(MacIRCallArgumentObservationScope(gprIndices: [8]))
        XCTAssertNil(MacIRCallArgumentObservationScope(scalarSIMDIndices: [-1]))
        XCTAssertNil(MacIRCallArgumentObservationScope(scalarSIMDIndices: [8]))
        XCTAssertNil(MacIRCallArgumentObservationScope(callStackRanges: [-1..<8]))
        XCTAssertNil(MacIRCallArgumentObservationScope(callStackRanges: [0..<0]))
        XCTAssertNil(MacIRCallArgumentObservationScope(callStackRanges: [0..<8, 0..<8]))
        XCTAssertNil(MacIRCallArgumentObservationScope(callStackRanges: [0..<8, 4..<12]))

        let adjacent = try scope(stack: [0..<8, 8..<16])
        XCTAssertTrue(adjacent.observes(.callStack(byteOffset: 0, size: 8, alignment: 8)))
        XCTAssertTrue(adjacent.observes(.callStack(byteOffset: 8, size: 8, alignment: 8)))
        XCTAssertFalse(adjacent.observes(.callStack(byteOffset: 0, size: 16, alignment: 8)))
        XCTAssertFalse(adjacent.observes(.callStack(byteOffset: 0, size: 0, alignment: 1)))
        XCTAssertFalse(adjacent.observes(.gpr(index: 0, carrierWidth: 16)))
    }

    func testContainerRejectsInvalidLocationsAliasesAndOverlappingStackArguments() throws {
        XCTAssertNil(MacIRCallArguments([
            gprArgument(8, role: .fixed(sourcePosition: 0), value: "invalid"),
        ]))
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, width: 64, role: .fixed(sourcePosition: 0), value: "x0"),
            gprArgument(0, width: 32, role: .fixed(sourcePosition: 1), value: "w0"),
        ]))
        XCTAssertNil(MacIRCallArguments([
            simdArgument(0, width: 64, role: .fixed(sourcePosition: 0), value: "d0"),
            simdArgument(0, width: 32, role: .fixed(sourcePosition: 1), value: "s0"),
        ]))
        XCTAssertNil(MacIRCallArguments([
            stackArgument(offset: 0, size: 8, alignment: 8, role: .fixed(sourcePosition: 0), value: "a"),
            stackArgument(offset: 4, size: 4, alignment: 4, role: .fixed(sourcePosition: 1), value: "b"),
        ]))

        XCTAssertNotNil(MacIRCallArguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "gpr"),
            simdArgument(0, role: .fixed(sourcePosition: 1), value: "simd"),
            stackArgument(offset: 0, size: 8, alignment: 8, role: .fixed(sourcePosition: 2), value: "stack0"),
            stackArgument(offset: 8, size: 8, alignment: 8, role: .fixed(sourcePosition: 3), value: "stack8"),
        ]))
    }

    func testContainerRejectsInvalidDuplicateOrdinalsAndRoleFamilyMixing() throws {
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .fixed(sourcePosition: -1), value: "negative"),
        ]))
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "first"),
            gprArgument(1, role: .fixed(sourcePosition: 0), value: "duplicate"),
        ]))
        let gprScope = try scope(gprs: [0, 1])
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .anonymousVariadic(tailOrdinal: -1), value: "negative"),
        ], observationScope: gprScope))
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .anonymousVariadic(tailOrdinal: 0), value: "first"),
            gprArgument(1, role: .anonymousVariadic(tailOrdinal: 0), value: "duplicate"),
        ], observationScope: gprScope))
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .unknown, value: "unknown"),
            gprArgument(1, role: .fixed(sourcePosition: 0), value: "fixed"),
        ], observationScope: gprScope))
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .unknown, value: "unknown"),
            gprArgument(1, role: .anonymousVariadic(tailOrdinal: 0), value: "tail"),
        ], observationScope: gprScope))

        XCTAssertNotNil(MacIRCallArguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed"),
            gprArgument(1, role: .anonymousVariadic(tailOrdinal: 0), value: "tail"),
        ], observationScope: gprScope))
    }

    func testUnknownAndAnonymousRequireExactObservationButFixedDoesNot() throws {
        XCTAssertNil(MacIRCallArguments([
            gprArgument(0, role: .unknown, value: "unknown"),
        ]))
        XCTAssertNil(MacIRCallArguments([
            simdArgument(0, role: .anonymousVariadic(tailOrdinal: 0), value: "tail"),
        ], observationScope: try scope(gprs: [0])))
        XCTAssertNil(MacIRCallArguments([
            stackArgument(
                offset: 0,
                size: 8,
                alignment: 8,
                role: .anonymousVariadic(tailOrdinal: 0),
                value: "tail"
            ),
        ], observationScope: try scope(stack: [0..<4])))

        XCTAssertNotNil(MacIRCallArguments([
            gprArgument(0, role: .unknown, value: "unknown"),
        ], observationScope: try scope(gprs: [0])))
        XCTAssertNotNil(MacIRCallArguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed"),
        ]))
    }

    func testContainerCanonicalizationIsPermutationIndependent() throws {
        let records = [
            stackArgument(offset: 8, size: 8, alignment: 8, role: .fixed(sourcePosition: 2), value: "stack"),
            simdArgument(1, role: .fixed(sourcePosition: 1), value: "simd"),
            gprArgument(2, role: .fixed(sourcePosition: 0), value: "gpr"),
        ]
        let first = try arguments(records)
        let second = try arguments(records.reversed())

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
        XCTAssertEqual(first.canonicalPhysicalEntriesForAudit.map(\.location), [
            .gpr(index: 2, carrierWidth: 64),
            .simd(index: 1, scalarWidth: 64),
            .callStack(byteOffset: 8, size: 8, alignment: 8),
        ])
        var traversed: [MacIRCallArgumentLocation] = []
        first.forEachPhysicalArgument { traversed.append($0.location) }
        XCTAssertEqual(traversed, first.canonicalPhysicalEntriesForAudit.map(\.location))
    }

    func testSparsePhysicalLookupRetainsGPRZeroAndGPRTwoWithoutCompaction() throws {
        let frame = try arguments([
            gprArgument(2, role: .unknown, value: "x2"),
            gprArgument(0, role: .unknown, value: "x0"),
        ], scope: try scope(gprs: [0, 1, 2]))

        XCTAssertEqual(frame.argument(at: .gpr(index: 0))?.value, value("x0"))
        XCTAssertNil(frame.argument(at: .gpr(index: 1)))
        XCTAssertEqual(frame.argument(at: .gpr(index: 2))?.value, value("x2"))
        XCTAssertNil(frame.argument(at: .gpr(index: 8)))
        XCTAssertNil(frame.argument(at: .gpr(index: 2))?.sourcePosition)
        XCTAssertEqual(frame.count, 2)
    }

    func testFixedLookupAndDensePrefixUseSourcePositionNotPhysicalOrder() throws {
        let complete = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 1), value: "source1"),
            simdArgument(0, role: .fixed(sourcePosition: 0), value: "source0"),
        ])
        XCTAssertEqual(complete.fixedArgument(at: 0)?.location, .simd(index: 0, scalarWidth: 64))
        XCTAssertEqual(complete.fixedArgument(at: 1)?.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(complete.denseFixedPrefixValues(), [value("source0"), value("source1")])

        let sparse = try arguments([
            gprArgument(2, role: .fixed(sourcePosition: 2), value: "source2"),
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "source0"),
        ])
        XCTAssertEqual(sparse.fixedArgument(at: 2)?.value, value("source2"))
        XCTAssertEqual(sparse.denseFixedPrefixValues(), [value("source0")])
    }

    func testDenseUnknownProjectionStopsAtFirstGapWithoutDroppingEvidence() throws {
        let sparse = try arguments([
            gprArgument(0, role: .unknown, value: "x0"),
            gprArgument(2, role: .unknown, value: "x2"),
        ], scope: try scope(gprs: Set(0..<8)))
        XCTAssertEqual(sparse.denseUnknownGPRPrefixValues(), [value("x0")])
        XCTAssertEqual(sparse.argument(at: .gpr(index: 2))?.value, value("x2"))

        let observedUnavailable = try arguments([], scope: try scope(gprs: Set(0..<8)))
        XCTAssertEqual(observedUnavailable.denseUnknownGPRPrefixValues(), [])

        let unobservedZero = try arguments([], scope: try scope(gprs: [1, 2]))
        XCTAssertNil(unobservedZero.denseUnknownGPRPrefixValues())
        let unobservedZeroWithValue = try arguments([
            gprArgument(1, role: .unknown, value: "x1"),
        ], scope: try scope(gprs: [1]))
        XCTAssertNil(unobservedZeroWithValue.denseUnknownGPRPrefixValues())
        XCTAssertNil(try arguments([]).denseUnknownGPRPrefixValues())
        XCTAssertNil(try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed"),
        ]).denseUnknownGPRPrefixValues())
        XCTAssertNil(try arguments([
            simdArgument(0, role: .unknown, value: "simd"),
        ], scope: try scope(simd: [0])).denseUnknownGPRPrefixValues())
        XCTAssertNil(try arguments([
            gprArgument(0, role: .unknown, value: "x0"),
        ], scope: try scope(gprs: [0], simd: [0])).denseUnknownGPRPrefixValues())
        XCTAssertNil(try arguments([
            gprArgument(0, role: .unknown, value: "x0"),
        ], scope: try scope(gprs: [0], stack: [0..<8])).denseUnknownGPRPrefixValues())
    }

    func testKnownVariadicProjectionRejectsAnonymousRowsAndCompletesOnlyZeroTail() throws {
        let objcSignature = signature(
            target: "_objc_msgSend",
            parameters: [(0, "x0"), (1, "x1")],
            isVariadic: true
        )
        let twoColonSelector = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "setObject:forKey:", selrefAddress: 0x1800)
        )
        let selectorArgument = MacIRCallArgument(
            location: .gpr(index: 1, carrierWidth: 64),
            role: .fixed(sourcePosition: 1),
            value: value("selector"),
            selectorEvidence: twoColonSelector
        )
        let completeArguments = try arguments([
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "tail1"),
            selectorArgument,
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail0"),
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
        ], scope: try scope(gprs: [2, 3]))
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: completeArguments
        ), "Phase A has no per-call method ABI authority for anonymous rows")

        let zeroColonSelector = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "description", selrefAddress: 0x1808)
        )
        let fixedOnlyArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            MacIRCallArgument(
                location: .gpr(index: 1, carrierWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: value("selector"),
                selectorEvidence: zeroColonSelector
            ),
        ])
        let fixedOnlyFrame = try XCTUnwrap(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(0),
            controlInputs: .none,
            arguments: fixedOnlyArguments
        ))
        XCTAssertEqual(fixedOnlyFrame.expectedTailCount, 0)
        XCTAssertEqual(
            fixedOnlyArguments.completeKnownVariadicValues(
                fixedCount: 2,
                expectedTailCount: 0
            ),
            [value("receiver"), value("selector")],
            "the low-level completeness projection must remain raw"
        )
        XCTAssertEqual(
            fixedOnlyFrame.completeKnownVariadicRenderValues(),
            [value("receiver"), .symbol("\"description\"")]
        )

        let fixedGapArguments = try arguments([
            selectorArgument,
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail0"),
        ], scope: try scope(gprs: [2]))
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: fixedGapArguments
        ))

        let tailGapArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            selectorArgument,
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "tail1"),
        ], scope: try scope(gprs: [3]))
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: tailGapArguments
        ))

        let unevidencedVariadicFrame = try XCTUnwrap(MacIRCallFrame(
            target: "_printf",
            knownSignature: signature(
                target: "_printf",
                parameters: [(0, "x0")],
                isVariadic: true
            ),
            controlInputs: .none,
            arguments: try arguments([
                gprArgument(0, role: .fixed(sourcePosition: 0), value: "format"),
            ])
        ))
        XCTAssertNil(unevidencedVariadicFrame.expectedTailCount)
        XCTAssertNil(unevidencedVariadicFrame.completeKnownVariadicRenderValues())
    }

    func testLowLevelKnownVariadicProjectionRequiresExactFixedAndTailDomains() throws {
        let complete = try arguments([
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "tail1"),
            simdArgument(0, role: .fixed(sourcePosition: 1), value: "fixed1"),
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail0"),
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed0"),
        ], scope: try scope(gprs: [2, 3]))
        XCTAssertEqual(
            complete.completeKnownVariadicValues(fixedCount: 2, expectedTailCount: 2),
            [value("fixed0"), value("fixed1"), value("tail0"), value("tail1")]
        )

        let missingFixedPosition = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed0"),
            simdArgument(0, role: .fixed(sourcePosition: 2), value: "fixed2"),
        ])
        XCTAssertNil(missingFixedPosition.completeKnownVariadicValues(
            fixedCount: 2,
            expectedTailCount: 0
        ))

        let missingTailOrdinal = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed0"),
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail0"),
            gprArgument(4, role: .anonymousVariadic(tailOrdinal: 2), value: "tail2"),
        ], scope: try scope(gprs: [2, 4]))
        XCTAssertNil(missingTailOrdinal.completeKnownVariadicValues(
            fixedCount: 1,
            expectedTailCount: 2
        ))

        let extraFixed = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed0"),
            simdArgument(0, role: .fixed(sourcePosition: 1), value: "fixed1"),
        ])
        XCTAssertNil(extraFixed.completeKnownVariadicValues(
            fixedCount: 1,
            expectedTailCount: 0
        ))

        let extraTail = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed0"),
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail0"),
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "tail1"),
        ], scope: try scope(gprs: [2, 3]))
        XCTAssertNil(extraTail.completeKnownVariadicValues(
            fixedCount: 1,
            expectedTailCount: 1
        ))
        XCTAssertNil(extraTail.completeKnownVariadicValues(
            fixedCount: 1,
            expectedTailCount: 0
        ), "zero tail is complete only when no anonymous row exists")

        XCTAssertNil(complete.completeKnownVariadicValues(
            fixedCount: -1,
            expectedTailCount: 2
        ))
        XCTAssertNil(complete.completeKnownVariadicValues(
            fixedCount: 2,
            expectedTailCount: -1
        ))
    }

    func testSelectorPresentationFlowsOnlyThroughSafeRenderProjections() throws {
        let evidence = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "valueForKey:", selrefAddress: 0x2000)
        )
        let selectorValue = MacIRValue.register(name: "x1", version: 2)
        let callArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            MacIRCallArgument(
                location: .gpr(index: 1, carrierWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: selectorValue,
                selectorEvidence: evidence
            ),
        ])
        let frame = try XCTUnwrap(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: signature(
                target: "_objc_msgSend",
                parameters: [(0, "x0"), (1, "x1")],
                isVariadic: true
            ),
            tailCountEvidence: .objectiveCSelectorColonCount(1),
            controlInputs: .none,
            arguments: callArguments
        ))

        XCTAssertEqual(frame.arguments.argument(at: .gpr(index: 1))?.value, selectorValue)
        XCTAssertEqual(frame.bindingValues, [value("receiver"), selectorValue])
        XCTAssertEqual(
            frame.denseFixedRenderValues(),
            [value("receiver"), .symbol("\"valueForKey:\"")]
        )
        XCTAssertEqual(frame.expectedTailCount, 1)
        XCTAssertNil(frame.completeKnownVariadicRenderValues())
    }

    func testControlRegisterParserIsStrictAndOnlyArgumentBankProjects() throws {
        let accepted: [(String, MacIRCallControlRegister, String?, MacIRCallArgumentPhysicalKey?)] = [
            ("x0", .gpr(index: 0), "x0", .gpr(index: 0)),
            ("X7", .gpr(index: 7), "x7", .gpr(index: 7)),
            ("x8", .gpr(index: 8), "x8", nil),
            ("X30", .gpr(index: 30), "x30", nil),
            ("SP", .stackPointer, "sp", nil),
        ]
        for (spelling, expected, name, key) in accepted {
            let register = try XCTUnwrap(MacIRCallControlRegister(register: spelling))
            XCTAssertEqual(register, expected)
            XCTAssertEqual(register.registerName, name)
            XCTAssertEqual(register.argumentPhysicalKey, key)
        }

        for spelling in [
            "w0", "x31", "xzr", "wzr", "wsp", "fp", "lr", "d0", "x01",
            " x0", "x0 ", "x-1", "x0junk", "",
        ] {
            XCTAssertNil(MacIRCallControlRegister(register: spelling))
        }
        XCTAssertNil(MacIRCallControlRegister.gpr(index: 31).registerName)
        XCTAssertNil(MacIRCallControlRegister.gpr(index: -1).argumentPhysicalKey)
    }

    func testControlInputsValidateRolesAndCanonicalizeWithoutInventingModifier() throws {
        let target = control(.indirectTarget, register: .gpr(index: 9), value: "target")
        let modifier = control(
            .pointerAuthenticationModifier,
            register: .stackPointer,
            value: "modifier"
        )
        let canonicalControls = try controls([modifier, target])
        XCTAssertEqual(canonicalControls.indirectTarget, target)
        XCTAssertEqual(canonicalControls.pointerAuthenticationModifier, modifier)
        XCTAssertEqual(canonicalControls.canonicalControlInputsForAudit, [target, modifier])
        XCTAssertEqual(canonicalControls.bindingValues, [value("target"), value("modifier")])

        XCTAssertEqual(try controls([]), .none)
        XCTAssertNotNil(MacIRCallControlInputs([target]))
        XCTAssertNil(MacIRCallControlInputs([modifier]))
        XCTAssertNil(MacIRCallControlInputs([target, target]))
        XCTAssertNil(MacIRCallControlInputs([
            target,
            control(.indirectTarget, register: .gpr(index: 10), value: "duplicate"),
        ]))
        XCTAssertNil(MacIRCallControlInputs([
            target,
            control(.pointerAuthenticationModifier, register: .gpr(index: 1), value: "one"),
            control(.pointerAuthenticationModifier, register: .gpr(index: 2), value: "two"),
        ]))
        XCTAssertNil(MacIRCallControlInputs([
            control(.indirectTarget, register: .stackPointer, value: "sp-target"),
        ]))
        XCTAssertNil(MacIRCallControlInputs([
            control(.indirectTarget, register: .gpr(index: 31), value: "invalid"),
        ]))

        XCTAssertNil(MacIRCallControlInputs([
            control(.indirectTarget, register: .gpr(index: 1), value: "target"),
            control(.pointerAuthenticationModifier, register: .gpr(index: 1), value: "modifier"),
        ]), "one physical register cannot carry two different pre-call values")

        let sharedValueControls = try controls([
            control(.indirectTarget, register: .gpr(index: 1), value: "shared"),
            control(.pointerAuthenticationModifier, register: .gpr(index: 1), value: "shared"),
        ])
        XCTAssertEqual(
            sharedValueControls.bindingValues,
            [value("shared"), value("shared")],
            "the two explicit operand roles retain two binding occurrences"
        )
    }

    func testControlInputExclusionsAreExact() throws {
        let excludedControls = try controls([
            control(.pointerAuthenticationModifier, register: .gpr(index: 9), value: "modifier"),
            control(.indirectTarget, register: .gpr(index: 0), value: "target"),
        ])
        XCTAssertEqual(excludedControls.excludedArgumentKeys, [.gpr(index: 0)])

        let argumentBank = try controls([
            control(.indirectTarget, register: .gpr(index: 7), value: "target"),
            control(.pointerAuthenticationModifier, register: .gpr(index: 1), value: "modifier"),
        ])
        XCTAssertEqual(argumentBank.excludedArgumentKeys, [.gpr(index: 1), .gpr(index: 7)])
    }

    func testCallFrameRejectsControlArgumentAndObservationCollisions() throws {
        let x0Target = try controls([
            control(.indirectTarget, register: .gpr(index: 0), value: "target"),
        ])
        let x0Argument = try arguments([
            gprArgument(0, role: .unknown, value: "argument"),
        ], scope: try scope(gprs: [0]))
        XCTAssertNil(MacIRCallFrame(
            target: "(*x0)",
            knownSignature: nil,
            controlInputs: x0Target,
            arguments: x0Argument
        ))

        let observedX0 = try arguments([], scope: try scope(gprs: [0]))
        XCTAssertNil(MacIRCallFrame(
            target: "(*x0)",
            knownSignature: nil,
            controlInputs: x0Target,
            arguments: observedX0
        ))

        let observedX1 = try arguments([
            gprArgument(1, role: .unknown, value: "argument"),
        ], scope: try scope(gprs: [1]))
        let valid = try XCTUnwrap(MacIRCallFrame(
            target: "(*x0)",
            knownSignature: nil,
            controlInputs: x0Target,
            arguments: observedX1
        ))
        XCTAssertEqual(valid.controlInputs, x0Target)
        XCTAssertEqual(valid.arguments, observedX1)
        XCTAssertEqual(valid.bindingValues, [value("target"), value("argument")])

        let sharedControlRegister = try controls([
            control(.pointerAuthenticationModifier, register: .gpr(index: 1), value: "shared"),
            control(.indirectTarget, register: .gpr(index: 1), value: "shared"),
        ])
        let x2Argument = try arguments([
            gprArgument(2, role: .unknown, value: "x2"),
        ], scope: try scope(gprs: [2]))
        let sharedFrame = try XCTUnwrap(MacIRCallFrame(
            target: "(*x1)",
            knownSignature: nil,
            controlInputs: sharedControlRegister,
            arguments: x2Argument
        ))
        XCTAssertEqual(
            sharedFrame.bindingValues,
            [value("shared"), value("shared"), value("x2")]
        )

        XCTAssertNotNil(MacIRCallFrame(
            target: "_emptyUnknown",
            knownSignature: nil,
            controlInputs: .none,
            arguments: try arguments([])
        ))
    }

    func testCallFrameRequiresExactIndirectTargetAndControlConsistency() throws {
        let x9Target = try controls([
            control(.indirectTarget, register: .gpr(index: 9), value: "target"),
        ])
        let noArguments = try arguments([])

        let valid = try XCTUnwrap(MacIRCallFrame(
            target: "(*x9)",
            knownSignature: nil,
            controlInputs: x9Target,
            arguments: noArguments
        ))
        XCTAssertEqual(valid.target, "(*x9)")
        XCTAssertEqual(valid.controlInputs, x9Target)

        for mismatchedTarget in ["(*x8)", "(*X9)", "_direct"] {
            XCTAssertNil(MacIRCallFrame(
                target: mismatchedTarget,
                knownSignature: nil,
                controlInputs: x9Target,
                arguments: noArguments
            ), "unexpectedly accepted mismatched indirect target \(mismatchedTarget)")
        }

        XCTAssertNil(MacIRCallFrame(
            target: "(*x9)",
            knownSignature: nil,
            controlInputs: .none,
            arguments: noArguments
        ), "a computed target requires a matching captured indirect control")

        for malformedReservedTarget in ["(*", "(*x9)junk"] {
            XCTAssertNil(MacIRCallFrame(
                target: malformedReservedTarget,
                knownSignature: nil,
                controlInputs: .none,
                arguments: noArguments
            ), "the reserved computed-target prefix requires an exact captured control")
        }

        XCTAssertNil(MacIRCallFrame(
            target: "(*x9)",
            knownSignature: signature(target: "(*x9)"),
            controlInputs: x9Target,
            arguments: noArguments
        ), "an indirect target cannot claim a known direct-call signature")
    }

    func testCallFrameOwnsTargetSignatureTailEvidenceControlsAndArguments() throws {
        let objcSignature = signature(
            target: "_objc_msgSend",
            parameters: [(0, "x0"), (1, "x1")],
            isVariadic: true
        )
        let selectorEvidence = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "setObject:forKey:", selrefAddress: 0x4000)
        )
        let callArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            MacIRCallArgument(
                location: .gpr(index: 1, carrierWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: value("selector"),
                selectorEvidence: selectorEvidence
            ),
        ])
        let tailEvidence = MacIRCallTailCountEvidence.objectiveCSelectorColonCount(2)
        let frame = try XCTUnwrap(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: tailEvidence,
            controlInputs: .none,
            arguments: callArguments
        ))

        XCTAssertEqual(frame.target, "_objc_msgSend")
        XCTAssertEqual(frame.knownSignature, objcSignature)
        XCTAssertEqual(frame.tailCountEvidence, tailEvidence)
        XCTAssertEqual(frame.tailCountEvidence?.expectedTailCount, 2)
        XCTAssertEqual(frame.expectedTailCount, 2)
        XCTAssertEqual(frame.controlInputs, .none)
        XCTAssertEqual(frame.arguments, callArguments)
        XCTAssertNil(frame.completeKnownVariadicRenderValues())
    }

    func testCallFrameRejectsRoleFamilyThatContradictsSignatureKnowledge() throws {
        let fixedArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed"),
        ])
        XCTAssertNil(MacIRCallFrame(
            target: "_unknown",
            knownSignature: nil,
            controlInputs: .none,
            arguments: fixedArguments
        ), "fixed roles require a known signature")

        let knownSignature = signature(target: "_known", parameters: [(0, "x0")])
        let unknownArguments = try arguments([
            gprArgument(0, role: .unknown, value: "unknown"),
        ], scope: try scope(gprs: [0]))
        XCTAssertNil(MacIRCallFrame(
            target: "_known",
            knownSignature: knownSignature,
            controlInputs: .none,
            arguments: unknownArguments
        ), "unknown roles cannot claim a known-signature frame")
    }

    func testCallFrameRejectsSignatureTargetAndFixedLocationMismatches() throws {
        let signatureForOtherTarget = signature(
            target: "_declared",
            parameters: [(0, "x0")]
        )
        let matchingFixedArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "fixed"),
        ])
        XCTAssertNil(MacIRCallFrame(
            target: "_actual",
            knownSignature: signatureForOtherTarget,
            controlInputs: .none,
            arguments: matchingFixedArguments
        ))

        let knownSignature = signature(
            target: "_known",
            parameters: [(0, "x0"), (1, "d0")]
        )
        let wrongPhysicalLocation = try arguments([
            gprArgument(1, role: .fixed(sourcePosition: 0), value: "wrong"),
        ])
        XCTAssertNil(MacIRCallFrame(
            target: "_known",
            knownSignature: knownSignature,
            controlInputs: .none,
            arguments: wrongPhysicalLocation
        ))

        let nonexistentSourcePosition = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 2), value: "wrong"),
        ])
        XCTAssertNil(MacIRCallFrame(
            target: "_known",
            knownSignature: knownSignature,
            controlInputs: .none,
            arguments: nonexistentSourcePosition
        ))
    }

    func testCallFrameValidatesCanonicalSignatureLayoutWithoutPoisoningHoles() throws {
        let noArguments = try arguments([])
        for invalidSignature in [
            signature(target: "_known", parameters: [(1, "x1"), (0, "x0")]),
            signature(target: "_known", parameters: [(0, "x0"), (2, "x1")]),
            signature(target: "_known", parameters: [(0, "x0"), (1, "w0")]),
        ] {
            XCTAssertNil(MacIRCallFrame(
                target: "_known",
                knownSignature: invalidSignature,
                controlInputs: .none,
                arguments: noArguments
            ))
        }

        let signatureWithHole = signature(
            target: "_known",
            parameters: [(0, "x8"), (1, "d0")]
        )
        let laterFixedArgument = try arguments([
            simdArgument(0, role: .fixed(sourcePosition: 1), value: "later"),
        ])
        let frame = try XCTUnwrap(MacIRCallFrame(
            target: "_known",
            knownSignature: signatureWithHole,
            controlInputs: .none,
            arguments: laterFixedArgument
        ))
        XCTAssertTrue(frame.arguments.denseFixedPrefixValues().isEmpty)
        XCTAssertEqual(frame.arguments.fixedArgument(at: 1)?.value, value("later"))
        XCTAssertEqual(
            frame.arguments.fixedArgument(at: 1)?.location,
            .simd(index: 0, scalarWidth: 64)
        )
    }

    func testCallFrameRejectsGenericVariadicAnonymousArgumentsWithoutCallEvidence() throws {
        let variadicSignature = signature(
            target: "_printf",
            parameters: [(0, "x0")],
            isVariadic: true
        )
        let callArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "format"),
            gprArgument(1, role: .anonymousVariadic(tailOrdinal: 0), value: "anonymous"),
        ], scope: try scope(gprs: [1]))

        XCTAssertNil(MacIRCallFrame(
            target: "_printf",
            knownSignature: variadicSignature,
            controlInputs: .none,
            arguments: callArguments
        ))
        XCTAssertNil(MacIRCallFrame(
            target: "_printf",
            knownSignature: variadicSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(1),
            controlInputs: .none,
            arguments: callArguments
        ), "Objective-C selector evidence cannot authorize a generic variadic tail")
    }

    func testCallFrameRejectsInvalidObjectiveCSelectorTailEvidence() throws {
        let objcSignature = signature(
            target: "_objc_msgSend",
            parameters: [(0, "x0"), (1, "x1")],
            isVariadic: true
        )
        let twoColonSelector = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "setObject:forKey:", selrefAddress: 0x5000)
        )
        let selectorArgument = MacIRCallArgument(
            location: .gpr(index: 1, carrierWidth: 64),
            role: .fixed(sourcePosition: 1),
            value: value("selector"),
            selectorEvidence: twoColonSelector
        )
        let completeArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            selectorArgument,
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "object"),
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "key"),
        ], scope: try scope(gprs: [2, 3]))

        let selectorOnlyArguments = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            selectorArgument,
        ])
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            controlInputs: .none,
            arguments: selectorOnlyArguments
        ), "selector presentation evidence requires matching tail-count authority")

        let nonObjectiveCSignature = signature(
            target: "_known",
            parameters: [(0, "x0"), (1, "x1")]
        )
        XCTAssertNil(MacIRCallFrame(
            target: "_known",
            knownSignature: nonObjectiveCSignature,
            controlInputs: .none,
            arguments: selectorOnlyArguments
        ), "selector presentation evidence is exclusive to canonical objc_msgSend")

        for invalidCount in [-1, 1, 3] {
            XCTAssertNil(MacIRCallFrame(
                target: "_objc_msgSend",
                knownSignature: objcSignature,
                tailCountEvidence: .objectiveCSelectorColonCount(invalidCount),
                controlInputs: .none,
                arguments: completeArguments
            ), "unexpectedly accepted selector-tail count \(invalidCount)")
        }

        let incompleteOrdinals = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            selectorArgument,
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "key"),
        ], scope: try scope(gprs: [3]))
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: incompleteOrdinals
        ), "Phase A rejects every anonymous row, including sparse evidence")

        let evidencedWithoutAnonymousRows = try XCTUnwrap(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: selectorOnlyArguments
        ))
        XCTAssertEqual(evidencedWithoutAnonymousRows.expectedTailCount, 2)
        XCTAssertNil(evidencedWithoutAnonymousRows.completeKnownVariadicRenderValues())

        let unauthorizedScopes = [
            try scope(gprs: [2]),
            try scope(simd: [0]),
            try scope(stack: [0..<8]),
        ]
        for unauthorizedScope in unauthorizedScopes {
            let selectorCoverageOnlyArguments = try arguments([
                gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
                selectorArgument,
            ], scope: unauthorizedScope)
            XCTAssertNil(MacIRCallFrame(
                target: "_objc_msgSend",
                knownSignature: objcSignature,
                tailCountEvidence: .objectiveCSelectorColonCount(2),
                controlInputs: .none,
                arguments: selectorCoverageOnlyArguments
            ), "selector arity cannot authorize observation coverage in any ABI bank")
        }

        let oneColonSelector = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "setObject:", selrefAddress: 0x5008)
        )
        let receiverArgument = gprArgument(
            0,
            role: .fixed(sourcePosition: 0),
            value: "receiver"
        )
        let oneColonSelectorArgument = MacIRCallArgument(
            location: .gpr(index: 1, carrierWidth: 64),
            role: .fixed(sourcePosition: 1),
            value: value("selector"),
            selectorEvidence: oneColonSelector
        )
        let invalidClassifierArguments: [MacIRCallArguments] = [
            try arguments([
                receiverArgument,
                oneColonSelectorArgument,
                gprArgument(3, role: .anonymousVariadic(tailOrdinal: 0), value: "wrong-gpr"),
            ], scope: try scope(gprs: [3])),
            try arguments([
                receiverArgument,
                oneColonSelectorArgument,
                simdArgument(0, role: .anonymousVariadic(tailOrdinal: 0), value: "simd"),
            ], scope: try scope(simd: [0])),
            try arguments([
                receiverArgument,
                oneColonSelectorArgument,
                stackArgument(
                    offset: 0,
                    size: 8,
                    alignment: 8,
                    role: .anonymousVariadic(tailOrdinal: 0),
                    value: "stack"
                ),
            ], scope: try scope(stack: [0..<8])),
            try arguments([
                receiverArgument,
                oneColonSelectorArgument,
                gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail"),
            ], scope: try scope(gprs: [2], simd: [0])),
            try arguments([
                receiverArgument,
                oneColonSelectorArgument,
                gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail"),
            ], scope: try scope(gprs: [2], stack: [0..<8])),
            try arguments([
                receiverArgument,
                oneColonSelectorArgument,
                gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "tail"),
            ], scope: try scope(gprs: [2, 3])),
        ]
        for invalidArguments in invalidClassifierArguments {
            XCTAssertNil(MacIRCallFrame(
                target: "_objc_msgSend",
                knownSignature: objcSignature,
                tailCountEvidence: .objectiveCSelectorColonCount(1),
                controlInputs: .none,
                arguments: invalidArguments
            ))
        }

        let outOfBoundsOrdinal = try arguments([
            receiverArgument,
            oneColonSelectorArgument,
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "invalid"),
        ], scope: try scope(gprs: [3]))
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(1),
            controlInputs: .none,
            arguments: outOfBoundsOrdinal
        ), "a tail ordinal must be strictly less than the independently proven count")

        let missingSelectorEvidence = try arguments([
            gprArgument(0, role: .fixed(sourcePosition: 0), value: "receiver"),
            gprArgument(1, role: .fixed(sourcePosition: 1), value: "selector"),
            gprArgument(2, role: .anonymousVariadic(tailOrdinal: 0), value: "object"),
            gprArgument(3, role: .anonymousVariadic(tailOrdinal: 1), value: "key"),
        ], scope: try scope(gprs: [2, 3]))
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: objcSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: missingSelectorEvidence
        ), "selector-derived evidence requires selector provenance at fixed GPR1")

        let superSignature = signature(
            target: "_objc_msgSendSuper",
            parameters: [(0, "x0"), (1, "x1")],
            isVariadic: true
        )
        XCTAssertNil(MacIRCallFrame(
            target: "_objc_msgSendSuper",
            knownSignature: superSignature,
            tailCountEvidence: .objectiveCSelectorColonCount(2),
            controlInputs: .none,
            arguments: completeArguments
        ), "plain objc_msgSend evidence cannot authorize a different dispatch target")
    }

    private func value(_ label: String) -> MacIRValue {
        .unknown(label)
    }

    private func argument(
        _ location: MacIRCallArgumentLocation,
        _ role: MacIRCallArgumentRole,
        value label: String
    ) -> MacIRCallArgument {
        MacIRCallArgument(location: location, role: role, value: value(label))
    }

    private func gprArgument(
        _ index: Int,
        width: Int = 64,
        role: MacIRCallArgumentRole,
        value label: String
    ) -> MacIRCallArgument {
        argument(.gpr(index: index, carrierWidth: width), role, value: label)
    }

    private func simdArgument(
        _ index: Int,
        width: Int = 64,
        role: MacIRCallArgumentRole,
        value label: String
    ) -> MacIRCallArgument {
        argument(.simd(index: index, scalarWidth: width), role, value: label)
    }

    private func stackArgument(
        offset: Int,
        size: Int,
        alignment: Int,
        role: MacIRCallArgumentRole,
        value label: String
    ) -> MacIRCallArgument {
        argument(
            .callStack(byteOffset: offset, size: size, alignment: alignment),
            role,
            value: label
        )
    }

    private func scope(
        gprs: Set<Int> = [],
        simd: Set<Int> = [],
        stack: [Range<Int>] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MacIRCallArgumentObservationScope {
        try XCTUnwrap(
            MacIRCallArgumentObservationScope(
                gprIndices: gprs,
                scalarSIMDIndices: simd,
                callStackRanges: stack
            ),
            file: file,
            line: line
        )
    }

    private func arguments(
        _ entries: [MacIRCallArgument],
        scope: MacIRCallArgumentObservationScope = .none,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MacIRCallArguments {
        try XCTUnwrap(
            MacIRCallArguments(entries, observationScope: scope),
            file: file,
            line: line
        )
    }

    private func control(
        _ role: MacIRCallControlInputRole,
        register: MacIRCallControlRegister,
        value label: String
    ) -> MacIRCallControlInput {
        MacIRCallControlInput(role: role, register: register, value: value(label))
    }

    private func controls(
        _ entries: [MacIRCallControlInput],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MacIRCallControlInputs {
        try XCTUnwrap(MacIRCallControlInputs(entries), file: file, line: line)
    }

    private func signature(
        target: String,
        parameters: [(index: Int, register: String)] = [],
        isVariadic: Bool = false
    ) -> MacIRCallSignature {
        MacIRCallSignature(
            target: target,
            returnType: "id",
            parameters: parameters.map {
                MacIRCallParameter(
                    index: $0.index,
                    register: $0.register,
                    type: "id"
                )
            },
            isVariadic: isVariadic,
            source: "test"
        )
    }

    private func requireHashableAndSendable<T: Hashable & Sendable>(_: T.Type) {}
}

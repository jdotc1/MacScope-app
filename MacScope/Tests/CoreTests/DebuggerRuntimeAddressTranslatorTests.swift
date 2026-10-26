import XCTest
@testable import MacScope

final class DebuggerRuntimeAddressTranslatorTests: XCTestCase {
    func testPositiveZeroNegativeAndNonuniformDisplacementsTranslateExactly() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let ranges = [
            try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1_0000, runtimeStart: 0x3_0000, byteCount: 0x100),
            try makeRange(instanceID: instanceID, ordinal: 1, staticStart: 0x4_0000, runtimeStart: 0x4_0000, byteCount: 0x100),
            try makeRange(instanceID: instanceID, ordinal: 2, staticStart: 0x8_0000, runtimeStart: 0x7_0000, byteCount: 0x100),
        ]
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: ranges)]
        )

        XCTAssertEqual(
            resolvedStatic(
                DebuggerRuntimeAddressTranslator.staticAddress(
                    forRuntimeAddress: 0x3_002A,
                    in: projection,
                    requiring: key
                )
            )?.imageAddress,
            ImageAddress(slot: .primary, address: 0x1_002A)
        )
        XCTAssertEqual(
            resolvedStatic(
                DebuggerRuntimeAddressTranslator.staticAddress(
                    forRuntimeAddress: 0x4_002A,
                    in: projection,
                    requiring: key
                )
            )?.imageAddress.address,
            0x4_002A
        )
        XCTAssertEqual(
            resolvedStatic(
                DebuggerRuntimeAddressTranslator.staticAddress(
                    forRuntimeAddress: 0x7_002A,
                    in: projection,
                    requiring: key
                )
            )?.imageAddress.address,
            0x8_002A
        )
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.displacementSummary(
                for: instanceID,
                in: projection,
                requiring: key
            ),
            .nonuniform
        )
    }

    func testUniformDisplacementSummariesRetainUnsignedDirectionAndMagnitude() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)

        let cases: [(UInt64, UInt64, DebuggerRuntimeAddressDisplacementSummary)] = [
            (0x1000, 0x3000, .uniform(.runtimeAboveStatic(0x2000))),
            (0x3000, 0x3000, .uniform(.unchanged)),
            (0x5000, 0x3000, .uniform(.runtimeBelowStatic(0x2000))),
        ]
        for (index, fixture) in cases.enumerated() {
            let instanceID = makeInstanceID(key: key, ordinal: UInt32(index))
            let range = try makeRange(
                instanceID: instanceID,
                ordinal: 0,
                staticStart: fixture.0,
                runtimeStart: fixture.1,
                byteCount: 0x80
            )
            let projection = makeProjection(
                key: key,
                modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: [range])]
            )
            XCTAssertEqual(
                DebuggerRuntimeAddressTranslator.displacementSummary(
                    for: instanceID,
                    in: projection,
                    requiring: key
                ),
                fixture.2
            )
        }
    }

    func testHalfOpenContainmentIncludesBothBytesAtMaxAndExcludesGapsAndUpperBoundary() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let ranges = [
            try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x5000, byteCount: 2),
            try makeRange(instanceID: instanceID, ordinal: 1, staticStart: .max, runtimeStart: .max, byteCount: 1),
        ]
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: ranges)]
        )

        XCTAssertNotNil(resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: 0x5000,
            in: projection,
            requiring: key
        )))
        XCTAssertNotNil(resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: 0x5001,
            in: projection,
            requiring: key
        )))
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x5002,
                in: projection,
                requiring: key
            ),
            .unresolved(.unmapped)
        )
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x4FFF,
                in: projection,
                requiring: key
            ),
            .unresolved(.unmapped)
        )
        XCTAssertEqual(
            resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: .max,
                in: projection,
                requiring: key
            ))?.imageAddress.address,
            .max
        )
    }

    func testZeroLengthAndOverflowingLastBytesAreRejectedBeforeTranslation() {
        let key = makeKey()
        let instanceID = makeInstanceID(key: key, ordinal: 0)

        XCTAssertNil(DebuggerRuntimeMappedRange(
            moduleInstanceID: instanceID,
            sourceSectionOrdinal: 0,
            segmentName: "__TEXT",
            staticStart: 0x1000,
            runtimeStart: 0x2000,
            byteCount: 0,
            permissions: 5
        ))
        XCTAssertNil(DebuggerRuntimeMappedRange(
            moduleInstanceID: instanceID,
            sourceSectionOrdinal: 0,
            segmentName: "__TEXT",
            staticStart: .max,
            runtimeStart: 0x2000,
            byteCount: 2,
            permissions: 5
        ))
        XCTAssertNil(DebuggerRuntimeMappedRange(
            moduleInstanceID: instanceID,
            sourceSectionOrdinal: 0,
            segmentName: "__TEXT",
            staticStart: 0x1000,
            runtimeStart: .max,
            byteCount: 2,
            permissions: 5
        ))
    }

    func testIndependentMappedSpansTranslateWhileUnmappedHeaderAndGapDoNot() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(
                instanceID: instanceID,
                coordinate: coordinate,
                ranges: [
                    try makeRange(instanceID: instanceID, ordinal: 0, segmentName: "__TEXT", staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100, permissions: 5),
                    try makeRange(instanceID: instanceID, ordinal: 1, segmentName: "__DATA", staticStart: 0x3000, runtimeStart: 0xB000, byteCount: 0x100, permissions: 3),
                ]
            )]
        )

        for (runtime, expectedStatic) in [(UInt64(0x9040), UInt64(0x1040)), (0xB040, 0x3040)] {
            XCTAssertEqual(
                resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
                    forRuntimeAddress: runtime,
                    in: projection,
                    requiring: key
                ))?.imageAddress.address,
                expectedStatic
            )
        }
        for runtime in [UInt64(0x8FFF), 0xA000, 0xB100] {
            XCTAssertEqual(
                DebuggerRuntimeAddressTranslator.staticAddress(
                    forRuntimeAddress: runtime,
                    in: projection,
                    requiring: key
                ),
                .unresolved(.unmapped)
            )
        }
    }

    func testAgreeingAliasesDeduplicateButDisagreeingOverlapIsAmbiguous() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let agreeing = makeProjection(
            key: key,
            modules: [makeModule(
                instanceID: instanceID,
                coordinate: coordinate,
                ranges: [
                    try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                    try makeRange(instanceID: instanceID, ordinal: 1, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                ]
            )]
        )
        XCTAssertNotNil(resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: 0x9040,
            in: agreeing,
            requiring: key
        )))

        let disagreeing = makeProjection(
            key: key,
            modules: [makeModule(
                instanceID: instanceID,
                coordinate: coordinate,
                ranges: [
                    try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                    try makeRange(instanceID: instanceID, ordinal: 1, staticStart: 0x2000, runtimeStart: 0x9000, byteCount: 0x100),
                ]
            )]
        )
        guard case let .ambiguous(results) = DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: 0x9040,
            in: disagreeing,
            requiring: key
        ) else {
            return XCTFail("Expected disagreeing overlap ambiguity")
        }
        XCTAssertEqual(results.map(\.imageAddress.address), [0x1040, 0x2040])
    }

    func testOverlappingModulesRemainAmbiguousEvenWhenQualifiedResultsAgree() throws {
        let key = makeKey()
        let coordinateA = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let coordinateB = try makeCoordinate(binaryID: binaryB, slot: ImageSlot(rawValue: 1))
        let instanceA = makeInstanceID(key: key, ordinal: 0)
        let instanceB = makeInstanceID(key: key, ordinal: 1)
        let projection = makeProjection(
            key: key,
            modules: [
                makeModule(instanceID: instanceA, coordinate: coordinateA, ranges: [
                    try makeRange(instanceID: instanceA, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                ]),
                makeModule(instanceID: instanceB, coordinate: coordinateB, ranges: [
                    try makeRange(instanceID: instanceB, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                ]),
            ]
        )

        guard case let .ambiguous(results) = DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: 0x9010,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Distinct module instances must remain ambiguous")
        }
        XCTAssertEqual(results.map(\.imageAddress.slot), [.primary, ImageSlot(rawValue: 1)])
        XCTAssertNotEqual(results[0].moduleInstanceID, results[1].moduleInstanceID)
    }

    func testSamePreferredVAInTwoSlotsResolvesBothDirectionsToExactOwner() throws {
        let key = makeKey()
        let coordinateA = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let coordinateB = try makeCoordinate(binaryID: binaryB, slot: ImageSlot(rawValue: 1))
        let instanceA = makeInstanceID(key: key, ordinal: 0)
        let instanceB = makeInstanceID(key: key, ordinal: 1)
        let projection = makeProjection(
            key: key,
            modules: [
                makeModule(instanceID: instanceA, coordinate: coordinateA, ranges: [
                    try makeRange(instanceID: instanceA, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                ]),
                makeModule(instanceID: instanceB, coordinate: coordinateB, ranges: [
                    try makeRange(instanceID: instanceB, ordinal: 0, staticStart: 0x1000, runtimeStart: 0xA000, byteCount: 0x100),
                ]),
            ]
        )

        XCTAssertEqual(
            resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x9020,
                in: projection,
                requiring: key
            ))?.imageAddress,
            ImageAddress(slot: .primary, address: 0x1020)
        )
        XCTAssertEqual(
            resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0xA020,
                in: projection,
                requiring: key
            ))?.imageAddress,
            ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x1020)
        )

        guard case let .resolved(runtimeA) = DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: ImageAddress(slot: .primary, address: 0x1020),
            coordinate: coordinateA,
            in: projection,
            requiring: key
        ), case let .resolved(runtimeB) = DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x1020),
            coordinate: coordinateB,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Each slot-qualified static address must resolve to its exact owner")
        }
        XCTAssertEqual(runtimeA.map(\.runtimeAddress), [0x9020])
        XCTAssertEqual(runtimeB.map(\.runtimeAddress), [0xA020])
        XCTAssertEqual(runtimeA.map(\.workspaceCoordinate), [coordinateA])
        XCTAssertEqual(runtimeB.map(\.workspaceCoordinate), [coordinateB])
    }

    func testSameInstanceStaticOverlapReturnsVectorAndScalarAmbiguity() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(
                instanceID: instanceID,
                coordinate: coordinate,
                ranges: [
                    try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
                    try makeRange(instanceID: instanceID, ordinal: 1, staticStart: 0x1000, runtimeStart: 0xA000, byteCount: 0x100),
                ]
            )]
        )
        let imageAddress = ImageAddress(slot: .primary, address: 0x1040)

        guard case let .resolved(vector) = DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: imageAddress,
            coordinate: coordinate,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Disagreeing static overlap must preserve both runtime results")
        }
        XCTAssertEqual(vector.map(\.moduleInstanceID), [instanceID, instanceID])
        XCTAssertEqual(vector.map(\.runtimeAddress), [0x9040, 0xA040])

        guard case let .ambiguous(scalar) = DebuggerRuntimeAddressTranslator.scalarRuntimeAddress(
            forStaticAddress: imageAddress,
            coordinate: coordinate,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Scalar translation must not select one overlapping runtime result")
        }
        XCTAssertEqual(scalar, vector)
    }

    func testStaticTranslationReturnsEveryLoadInstanceSortedAndScalarNeverChoosesFirst() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let laterOrdinal = makeInstanceID(key: key, ordinal: 9)
        let earlierOrdinal = makeInstanceID(key: key, ordinal: 2)
        let projection = makeProjection(
            key: key,
            modules: [
                makeModule(instanceID: laterOrdinal, coordinate: coordinate, ranges: [
                    try makeRange(instanceID: laterOrdinal, ordinal: 0, staticStart: 0x1000, runtimeStart: 0xD000, byteCount: 0x100),
                ]),
                makeModule(instanceID: earlierOrdinal, coordinate: coordinate, ranges: [
                    try makeRange(instanceID: earlierOrdinal, ordinal: 0, staticStart: 0x1000, runtimeStart: 0xB000, byteCount: 0x100),
                    try makeRange(instanceID: earlierOrdinal, ordinal: 1, staticStart: 0x1000, runtimeStart: 0xB000, byteCount: 0x100),
                ]),
            ]
        )
        let imageAddress = ImageAddress(slot: .primary, address: 0x1040)

        guard case let .resolved(results) = DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: imageAddress,
            coordinate: coordinate,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Expected both load instances")
        }
        XCTAssertEqual(results.map(\.moduleInstanceID.ordinal), [2, 9])
        XCTAssertEqual(results.map(\.runtimeAddress), [0xB040, 0xD040])

        guard case let .ambiguous(scalarResults) = DebuggerRuntimeAddressTranslator.scalarRuntimeAddress(
            forStaticAddress: imageAddress,
            coordinate: coordinate,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Scalar translation must preserve multiplicity as ambiguity")
        }
        XCTAssertEqual(scalarResults, results)
    }

    func testEveryProjectionKeyCoordinateAndOwnerComponentFencesTranslation() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary, ownerRevision: 3)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: [
                try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
            ])]
        )

        let staleKeys = [
            makeKey(stopRevision: 99),
            makeKey(processID: 99),
            makeKey(authorityRevision: 99),
            makeKey(inventoryRevision: 99),
            makeKey(catalogRevision: 99),
        ]
        for staleKey in staleKeys {
            XCTAssertEqual(
                DebuggerRuntimeAddressTranslator.staticAddress(
                    forRuntimeAddress: 0x9010,
                    in: projection,
                    requiring: staleKey
                ),
                .unresolved(.projectionKeyMismatch)
            )
        }

        let wrongOwner = try makeCoordinate(binaryID: binaryB, slot: .primary, ownerRevision: 4)
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.runtimeAddresses(
                forStaticAddress: ImageAddress(slot: .primary, address: 0x1010),
                coordinate: wrongOwner,
                in: projection,
                requiring: key
            ),
            .unresolved(.unmapped)
        )
    }

    func testUnloadRemapAndInvalidRangeOwnershipFailClosed() throws {
        let oldKey = makeKey(authorityRevision: 7, inventoryRevision: 3)
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let oldID = makeInstanceID(key: oldKey, ordinal: 0)
        let oldProjection = makeProjection(
            key: oldKey,
            modules: [makeModule(instanceID: oldID, coordinate: coordinate, ranges: [
                try makeRange(instanceID: oldID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
            ])]
        )
        let newKey = makeKey(authorityRevision: 8, inventoryRevision: 4)
        let newID = makeInstanceID(key: newKey, ordinal: 0)
        let unloaded = makeProjection(key: newKey, modules: [])
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x9010,
                in: unloaded,
                requiring: newKey
            ),
            .unresolved(.unmapped)
        )
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.runtimeAddresses(
                forStaticAddress: ImageAddress(slot: .primary, address: 0x1010),
                coordinate: coordinate,
                in: unloaded,
                requiring: newKey
            ),
            .unresolved(.unmapped)
        )
        let remapped = makeProjection(
            key: newKey,
            modules: [makeModule(instanceID: newID, coordinate: coordinate, ranges: [
                try makeRange(instanceID: newID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0xA000, byteCount: 0x100),
            ])]
        )

        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x9010,
                in: remapped,
                requiring: newKey
            ),
            .unresolved(.unmapped)
        )
        XCTAssertEqual(
            resolvedStatic(DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0xA010,
                in: remapped,
                requiring: newKey
            ))?.imageAddress.address,
            0x1010
        )
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x9010,
                in: oldProjection,
                requiring: newKey
            ),
            .unresolved(.projectionKeyMismatch)
        )

        let invalidOwnership = makeProjection(
            key: oldKey,
            modules: [makeModule(instanceID: oldID, coordinate: coordinate, ranges: [
                try makeRange(instanceID: newID, ordinal: 0, staticStart: 0x1000, runtimeStart: 0x9000, byteCount: 0x100),
            ])]
        )
        XCTAssertEqual(
            DebuggerRuntimeAddressTranslator.staticAddress(
                forRuntimeAddress: 0x9010,
                in: invalidOwnership,
                requiring: oldKey
            ),
            .unresolved(.invalidProjection)
        )
    }

    func testStaticRuntimeRoundTripsAreExact() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: [
                try makeRange(instanceID: instanceID, ordinal: 0, staticStart: 0x1234_5000, runtimeStart: 0xFEDC_0000, byteCount: 0x1000),
            ])]
        )
        let originalStatic = ImageAddress(slot: .primary, address: 0x1234_5ABC)

        guard case let .resolved(runtimeResults) = DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: originalStatic,
            coordinate: coordinate,
            in: projection,
            requiring: key
        ), let runtime = runtimeResults.only else {
            return XCTFail("Expected one runtime result")
        }
        guard case let .resolved(staticResult) = DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: runtime.runtimeAddress,
            in: projection,
            requiring: key
        ) else {
            return XCTFail("Expected exact reverse translation")
        }
        XCTAssertEqual(staticResult.imageAddress, originalStatic)
        XCTAssertEqual(staticResult.runtimeAddress, runtime.runtimeAddress)
        XCTAssertEqual(staticResult.workspaceCoordinate, coordinate)
    }

    func testSecurityEvidenceTrailJoinsSelectedStoppedFrameAndRoundTripsExport() throws {
        let key = makeKey()
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 4)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: [
                try makeRange(
                    instanceID: instanceID,
                    ordinal: 0,
                    staticStart: 0x1000,
                    runtimeStart: 0x9000,
                    byteCount: 0x100
                ),
            ])]
        )
        let finding = SecurityTriageFinding(
            rule: .r3NonconstantFormat,
            confidence: .likely,
            evidenceAddresses: [0x1010],
            reason: "format input is not proven constant"
        )
        let function = SecurityTriageFunctionReport(
            functionName: "render_message",
            functionStartAddress: 0x1000,
            findings: [finding]
        )
        let question = try XCTUnwrap(DebuggerSecurityUnresolvedQuestion(
            "Does every caller constrain the format input?"
        ))
        let staticTrail = try DebuggerSecurityEvidenceTrailBuilder.staticTrail(
            function: function,
            finding: finding,
            callSiteAddress: 0x1010,
            coordinate: coordinate,
            recordedAtUnixNanoseconds: 1_200_000_000,
            unresolvedQuestions: [question]
        ).get()
        let trail = try DebuggerSecurityEvidenceTrailBuilder.observingSelectedStoppedFrame(
            DebuggerStoppedFrame(
                identifier: 2,
                address: 0x9010,
                functionName: "render_message",
                moduleName: "Sample",
                sourceLocation: "sample.c:12"
            ),
            at: 1_234_567_890,
            in: projection,
            requiring: key,
            appendingTo: staticTrail
        ).get()

        XCTAssertEqual(trail.staticEvidence.label, .staticInference)
        XCTAssertEqual(trail.runtimeEvidence?.label, .observedRuntimeBehavior)
        XCTAssertEqual(trail.unresolvedQuestions.map(\.label), [.unresolvedQuestion])
        XCTAssertEqual(trail.runtimeEvidence?.process.observedProcessID, 44)
        XCTAssertEqual(trail.runtimeEvidence?.runtimeAddress, 0x9010)
        XCTAssertEqual(trail.runtimeEvidence?.staticAddress, 0x1010)
        XCTAssertEqual(trail.runtimeEvidence?.addressDisplacement, .runtimeAboveStatic(0x8000))
        XCTAssertEqual(trail.runtimeEvidence?.moduleSlide, .runtimeAboveStatic(0x8000))
        XCTAssertEqual(
            try DebuggerSecurityEvidenceNavigator.staticTarget(
                for: trail,
                requiring: coordinate
            ).get(),
            ImageAddress(slot: .primary, address: 0x1010)
        )
        XCTAssertEqual(
            try DebuggerSecurityEvidenceNavigator.currentRuntimeTarget(
                for: trail,
                in: projection,
                requiring: key
            ).get(),
            0x9010
        )

        let exported = try DebuggerSecurityEvidenceExport.encode(trail)
        let reopened = try DebuggerSecurityEvidenceExport.decode(exported).get()
        XCTAssertEqual(reopened, trail)
    }

    func testSecurityEvidenceTrailRefusesDifferentProcessIdentityAfterReopen() throws {
        let key = makeKey(processID: 44)
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: coordinate, ranges: [
                try makeRange(
                    instanceID: instanceID,
                    ordinal: 0,
                    staticStart: 0x1000,
                    runtimeStart: 0x9000,
                    byteCount: 0x100
                ),
            ])]
        )
        let trail = try makeSecurityTrail(
            coordinate: coordinate,
            frameAddress: 0x9010,
            projection: projection,
            key: key
        )
        let otherKey = makeKey(processID: 55)
        let otherInstanceID = makeInstanceID(key: otherKey, ordinal: 0)
        let otherProjection = makeProjection(
            key: otherKey,
            modules: [makeModule(instanceID: otherInstanceID, coordinate: coordinate, ranges: [
                try makeRange(
                    instanceID: otherInstanceID,
                    ordinal: 0,
                    staticStart: 0x1000,
                    runtimeStart: 0x9000,
                    byteCount: 0x100
                ),
            ])]
        )

        XCTAssertEqual(
            DebuggerSecurityEvidenceNavigator.currentRuntimeTarget(
                for: trail,
                in: otherProjection,
                requiring: otherKey
            ),
            .failure(.processIdentityMismatch)
        )
    }

    func testSecurityEvidenceTrailRefusesDifferentBinaryAndDifferentStaticCallSite() throws {
        let key = makeKey()
        let findingCoordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let runtimeCoordinate = try makeCoordinate(binaryID: binaryB, slot: .primary)
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let projection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: runtimeCoordinate, ranges: [
                try makeRange(
                    instanceID: instanceID,
                    ordinal: 0,
                    staticStart: 0x1000,
                    runtimeStart: 0x9000,
                    byteCount: 0x100
                ),
            ])]
        )
        let finding = SecurityTriageFinding(
            rule: .r1UnboundedCopy,
            confidence: .definite,
            evidenceAddresses: [0x1010],
            reason: "unbounded copy"
        )
        let staticTrail = try DebuggerSecurityEvidenceTrailBuilder.staticTrail(
            function: SecurityTriageFunctionReport(
                functionName: "copy_input",
                functionStartAddress: 0x1000,
                findings: [finding]
            ),
            finding: finding,
            callSiteAddress: 0x1010,
            coordinate: findingCoordinate,
            recordedAtUnixNanoseconds: 1
        ).get()
        let matchingFrame = DebuggerStoppedFrame(
            identifier: 0,
            address: 0x9010,
            functionName: "copy_input",
            moduleName: "OtherSample",
            sourceLocation: nil
        )
        XCTAssertEqual(
            DebuggerSecurityEvidenceTrailBuilder.observingSelectedStoppedFrame(
                matchingFrame,
                at: 10,
                in: projection,
                requiring: key,
                appendingTo: staticTrail
            ),
            .failure(.imageIdentityMismatch)
        )

        let matchingCoordinateProjection = makeProjection(
            key: key,
            modules: [makeModule(instanceID: instanceID, coordinate: findingCoordinate, ranges: [
                try makeRange(
                    instanceID: instanceID,
                    ordinal: 0,
                    staticStart: 0x1000,
                    runtimeStart: 0x9000,
                    byteCount: 0x100
                ),
            ])]
        )
        let differentCallSiteFrame = DebuggerStoppedFrame(
            identifier: 0,
            address: 0x9020,
            functionName: "copy_input",
            moduleName: "Sample",
            sourceLocation: nil
        )
        XCTAssertEqual(
            DebuggerSecurityEvidenceTrailBuilder.observingSelectedStoppedFrame(
                differentCallSiteFrame,
                at: 10,
                in: matchingCoordinateProjection,
                requiring: key,
                appendingTo: staticTrail
            ),
            .failure(.staticAddressMismatch)
        )
    }

    func testSecurityEvidenceStaticTrailRequiresExactFindingAndEvidenceSite() throws {
        let coordinate = try makeCoordinate(binaryID: binaryA, slot: .primary)
        let finding = SecurityTriageFinding(
            rule: .r4UncheckedAllocation,
            confidence: .needsReview,
            evidenceAddresses: [0x1010],
            reason: "allocation result may be unchecked"
        )
        let function = SecurityTriageFunctionReport(
            functionName: "allocate",
            functionStartAddress: 0x1000,
            findings: []
        )
        XCTAssertEqual(
            DebuggerSecurityEvidenceTrailBuilder.staticTrail(
                function: function,
                finding: finding,
                callSiteAddress: 0x1010,
                coordinate: coordinate,
                recordedAtUnixNanoseconds: 1
            ),
            .failure(.findingNotInFunctionReport)
        )
        XCTAssertEqual(
            DebuggerSecurityEvidenceTrailBuilder.staticTrail(
                function: SecurityTriageFunctionReport(
                    functionName: "allocate",
                    functionStartAddress: 0x1000,
                    findings: [finding]
                ),
                finding: finding,
                callSiteAddress: 0x1020,
                coordinate: coordinate,
                recordedAtUnixNanoseconds: 1
            ),
            .failure(.callSiteNotInFinding)
        )
    }

    private func makeSecurityTrail(
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        frameAddress: UInt64,
        projection: DebuggerRuntimeMappingProjection,
        key: DebuggerRuntimeMappingProjectionKey
    ) throws -> DebuggerSecurityEvidenceTrail {
        let finding = SecurityTriageFinding(
            rule: .r3NonconstantFormat,
            confidence: .likely,
            evidenceAddresses: [0x1010],
            reason: "format input is not proven constant"
        )
        let staticTrail = try DebuggerSecurityEvidenceTrailBuilder.staticTrail(
            function: SecurityTriageFunctionReport(
                functionName: "render_message",
                functionStartAddress: 0x1000,
                findings: [finding]
            ),
            finding: finding,
            callSiteAddress: 0x1010,
            coordinate: coordinate,
            recordedAtUnixNanoseconds: 1
        ).get()
        return try DebuggerSecurityEvidenceTrailBuilder.observingSelectedStoppedFrame(
            DebuggerStoppedFrame(
                identifier: 0,
                address: frameAddress,
                functionName: "render_message",
                moduleName: "Sample",
                sourceLocation: nil
            ),
            at: 10,
            in: projection,
            requiring: key,
            appendingTo: staticTrail
        ).get()
    }

    private let binaryA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let binaryB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeKey(
        stopRevision: UInt64 = 3,
        processID: Int32 = 44,
        authorityRevision: UInt64 = 7,
        inventoryRevision: UInt64 = 5,
        catalogRevision: UInt64 = 9
    ) -> DebuggerRuntimeMappingProjectionKey {
        DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: DebuggerStopCoordinate(
                session: DebuggerSessionCoordinate(
                    epoch: DebuggerSessionEpoch(
                        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
                    ),
                    lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
                ),
                stopRevision: DebuggerStopRevision(rawValue: stopRevision)
            ),
            observedPID: processID,
            authorityRevision: DebuggerRuntimeModuleAuthorityRevision(rawValue: authorityRevision),
            inventoryRevision: DebuggerRuntimeModuleInventoryRevision(rawValue: inventoryRevision),
            workspaceCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision(rawValue: catalogRevision)
        )
    }

    private func makeInstanceID(
        key: DebuggerRuntimeMappingProjectionKey,
        ordinal: UInt32
    ) -> DebuggerRuntimeModuleInstanceID {
        DebuggerRuntimeModuleInstanceID(
            processID: key.observedPID,
            stop: key.stopCoordinate,
            inventoryRevision: key.inventoryRevision,
            ordinal: ordinal
        )
    }

    private func makeCoordinate(
        binaryID: UUID,
        slot: ImageSlot,
        ownerRevision: UInt64 = 1
    ) throws -> DebuggerWorkspaceArtifactCoordinate {
        DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: slot,
            artifactIdentity: try MachOSliceArtifactIdentity(
                uuid: UUID(uuidString: "99999999-9999-9999-9999-999999999999"),
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "a", count: 64),
                selectedSliceByteCount: 0x20_000
            ),
            ownerRevision: DebuggerWorkspaceArtifactOwnerRevision(rawValue: ownerRevision)
        )
    }

    private func makeRange(
        instanceID: DebuggerRuntimeModuleInstanceID,
        ordinal: UInt32,
        segmentName: String = "__TEXT",
        staticStart: UInt64,
        runtimeStart: UInt64,
        byteCount: UInt64,
        permissions: UInt8 = 5
    ) throws -> DebuggerRuntimeMappedRange {
        try XCTUnwrap(DebuggerRuntimeMappedRange(
            moduleInstanceID: instanceID,
            sourceSectionOrdinal: ordinal,
            segmentName: segmentName,
            staticStart: staticStart,
            runtimeStart: runtimeStart,
            byteCount: byteCount,
            permissions: permissions
        ))
    }

    private func makeModule(
        instanceID: DebuggerRuntimeModuleInstanceID,
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        ranges: [DebuggerRuntimeMappedRange]
    ) -> DebuggerCorrelatedRuntimeModule {
        DebuggerCorrelatedRuntimeModule(
            instanceID: instanceID,
            coordinate: coordinate,
            mappedRanges: ranges
        )
    }

    private func makeProjection(
        key: DebuggerRuntimeMappingProjectionKey,
        modules: [DebuggerCorrelatedRuntimeModule]
    ) -> DebuggerRuntimeMappingProjection {
        DebuggerRuntimeMappingProjection(key: key, modules: modules)
    }

    private func resolvedStatic(
        _ result: DebuggerRuntimeToStaticTranslation
    ) -> DebuggerResolvedStaticAddress? {
        guard case let .resolved(address) = result else { return nil }
        return address
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

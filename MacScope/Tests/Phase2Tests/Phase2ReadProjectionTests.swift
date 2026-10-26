import XCTest
@testable import MacScope

final class Phase2ReadProjectionTests: XCTestCase {
    func testWorkspaceSummaryProjectsFocusedImageFacts() throws {
        let fixture = ProjectionFixture()
        let authorization = try fixture.authorization(
            operation: .workspaceSummary,
            effects: [.a1],
            subject: .workspace(fixture.workspace),
            image: fixture.primaryImage
        )

        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(currentImage: fixture.primaryImage, focusedImageSlot: .primary)
        )

        XCTAssertEqual(candidate.operationID, .workspaceSummary)
        XCTAssertEqual(candidate.producingPrincipal, .app)
        XCTAssertEqual(candidate.data.field("workspaceName"), .text("Projection Fixture"))
        XCTAssertEqual(candidate.data.field("loadedImageCount"), .unsignedInteger(2))
        XCTAssertEqual(candidate.data.field("focusedImage")?.field("name"), .text("primary"))
        XCTAssertEqual(candidate.data.field("focusedImage")?.field("functionCount"), .unsignedInteger(1))
    }

    func testSelectionExplainUsesAuthorizedSameVASiblingOwner() throws {
        let fixture = ProjectionFixture()
        let location = Phase2ReadStaticLocation(
            image: fixture.siblingImage,
            domain: .imageVirtualAddress,
            address: 0x1000
        )
        let authorization = try fixture.authorization(
            operation: .selectionExplain,
            effects: [.a1],
            subject: .staticLocation(location),
            image: fixture.siblingImage
        )

        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(currentImage: fixture.siblingImage, focusedImageSlot: .primary)
        )

        XCTAssertEqual(candidate.data.field("location"), .staticLocation(location))
        XCTAssertEqual(
            candidate.data.field("instruction")?.firstListItem?.field("mnemonic"),
            .text("sibling-op")
        )
    }

    func testFunctionReviewRequiresExactRangeAndReportsDeterministicTruncation() throws {
        let fixture = ProjectionFixture()
        let range = Phase2ReadFunctionRange(
            image: fixture.siblingImage,
            start: 0x1000,
            endExclusive: 0x1010
        )
        let authorization = try fixture.authorization(
            operation: .functionReview,
            effects: [.a1, .a2],
            subject: .functionRange(range),
            image: fixture.siblingImage,
            limits: fixture.limits(pageItems: 2)
        )

        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(currentImage: fixture.siblingImage, focusedImageSlot: .primary)
        )

        XCTAssertEqual(candidate.data.field("start"), .unsignedInteger(0x1000))
        XCTAssertEqual(candidate.data.field("instructionPage")?.field("totalCount"), .unsignedInteger(3))
        XCTAssertEqual(candidate.data.field("instructionPage")?.field("returnedCount"), .unsignedInteger(2))
        XCTAssertEqual(candidate.data.field("instructionPage")?.field("omittedCount"), .unsignedInteger(1))
        XCTAssertEqual(
            candidate.data.field("instructionPage")?.field("items")?.listCount,
            2
        )
    }

    func testApplicationGraphSummaryProjectsFocusedImageDependencyFacts() throws {
        let fixture = ProjectionFixture()
        let authorization = try fixture.authorization(
            operation: .applicationGraphSummary,
            effects: [.a1],
            subject: .workspace(fixture.workspace),
            image: fixture.primaryImage,
            facets: [.workspaceTopology, .loaderMetadata],
            strictWholeWorkspace: true,
            limits: fixture.limits(pageItems: 2)
        )

        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(currentImage: fixture.primaryImage, focusedImageSlot: .primary)
        )

        XCTAssertEqual(candidate.operationID, .applicationGraphSummary)
        XCTAssertEqual(candidate.data.field("focusedImage")?.field("name"), .text("primary"))
        XCTAssertEqual(candidate.data.field("loadedImageCount"), .unsignedInteger(2))
        XCTAssertEqual(candidate.data.field("declaredDependencyCount"), .unsignedInteger(3))
        XCTAssertEqual(candidate.data.field("resolvedWorkspaceDependencyCount"), .unsignedInteger(1))
        XCTAssertEqual(candidate.data.field("externalDependencyCount"), .unsignedInteger(1))
        XCTAssertEqual(candidate.data.field("unresolvedDependencyCount"), .unsignedInteger(1))
        XCTAssertEqual(candidate.data.field("dependencyPage")?.field("totalCount"), .unsignedInteger(3))
        XCTAssertEqual(candidate.data.field("dependencyPage")?.field("returnedCount"), .unsignedInteger(2))
        XCTAssertEqual(candidate.data.field("dependencyPage")?.field("omittedCount"), .unsignedInteger(1))
        XCTAssertEqual(
            candidate.data.field("dependencyPage")?.field("items")?.firstListItem?.field("target"),
            .text("sibling")
        )
        XCTAssertEqual(
            candidate.data.field("dependencyPage")?.field("items")?.firstListItem?.field("resolution"),
            .text("resolved-workspace-image:1")
        )
    }

    func testProjectionAbstainsWhenAuthorizedOwnerIsMissing() throws {
        let fixture = ProjectionFixture()
        let location = Phase2ReadStaticLocation(
            image: fixture.siblingImage,
            domain: .imageVirtualAddress,
            address: 0x1000
        )
        let authorization = try fixture.authorization(
            operation: .selectionExplain,
            effects: [.a1],
            subject: .staticLocation(location),
            image: fixture.siblingImage
        )
        let empty = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])

        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: .init(
                workspaceName: "Empty",
                snapshot: empty,
                currentState: fixture.current(image: fixture.siblingImage),
                focusedImageSlot: nil
            )
        )

        XCTAssertEqual(candidate.data, .unavailable(.unresolvedOwner))
    }

    func testNativeDecompilerProjectionPublishesBoundedReadyAndTruncatedEvidence() throws {
        let fixture = ProjectionFixture()
        let range = fixture.siblingRange
        let authorization = try fixture.authorization(
            operation: .decompilerNativeResult,
            effects: [.a1],
            subject: .functionRange(range),
            image: fixture.siblingImage,
            limits: fixture.limits(pageItems: 16, stringBytes: 32)
        )

        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(
                currentImage: fixture.siblingImage,
                focusedImageSlot: fixture.siblingImage.slot,
                nativeDecompilerState: fixture.nativeState(
                    text: "int sibling_fn(void) { return 12345678901234567890; }"
                )
            )
        )

        XCTAssertEqual(candidate.data.field("source"), .text("native"))
        XCTAssertEqual(candidate.data.field("status"), .text("truncated"))
        XCTAssertEqual(candidate.data.field("pseudocode")?.field("isTruncated"), .boolean(true))
        guard case let .text(text) = candidate.data.field("pseudocode")?.field("text") else {
            return XCTFail("Expected bounded native pseudocode text")
        }
        XCTAssertLessThanOrEqual(text.utf8.count, 32)
        XCTAssertEqual(candidate.data.field("authenticationSummary")?.field("totalCount"), .unsignedInteger(0))
    }

    func testNativeDecompilerProjectionReturnsTypedUnavailableAndStaleEvidence() throws {
        let fixture = ProjectionFixture()
        let authorization = try fixture.authorization(
            operation: .decompilerNativeResult,
            effects: [.a1],
            subject: .functionRange(fixture.siblingRange),
            image: fixture.siblingImage
        )

        let unavailable = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(
                currentImage: fixture.siblingImage,
                focusedImageSlot: fixture.siblingImage.slot,
                nativeDecompilerState: .idle
            )
        )
        XCTAssertEqual(unavailable.data, .unavailable(.unavailable))

        let stale = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(
                currentImage: fixture.siblingImage,
                focusedImageSlot: fixture.siblingImage.slot,
                nativeDecompilerState: .analyzing(fixture.nativeCoordinate(ownerBinaryID: projectionID(99)))
            )
        )
        XCTAssertEqual(stale.data, .unavailable(.unresolvedOwner))
    }

    func testNativeAuthenticationSummaryUsesStructuredEffectsAndExactImageRanges() throws {
        let fixture = ProjectionFixture()
        let source = NativeDecompilerWireSourceRange(imageID: "fixture-image",
            startAddress: .init(0x1000), endAddressExclusive: .init(0x1004))
        func operation(_ id: String, _ name: String,
                       _ effect: NativeDecompilerWireAuthenticationEffect) -> NativeDecompilerWireOperationRecord {
            .init(id: id, blockID: "block", sequence: .init(0), opcode: .callother,
                outputVarnodeID: effect.kind == .transformedOutput ? "output" : nil,
                inputVarnodeIDs: [], directTargetAddress: nil, sourceRanges: [source],
                userOperationName: name, authenticationEffect: effect)
        }
        let operations = [operation("op0", "pacia", .init(kind: .transformedOutput, outputSSAValueID: "ssa-output")),
            operation("op1", "AuthDA", .init(kind: .authenticatedMemoryAccessWithoutTransformedAddress)),
            operation("op2", "AuthIA", .init(kind: .authenticatedControlTransferWithoutTransformedTarget)),
            operation("op3", "unknown-userop", .none)]
        for pageItems in [1, 16] {
            let authorization = try fixture.authorization(operation: .decompilerNativeResult,
                effects: [.a1], subject: .functionRange(fixture.siblingRange), image: fixture.siblingImage,
                limits: fixture.limits(pageItems: pageItems))
            let candidate = Phase2ReadProjector.project(authorization: authorization,
                input: fixture.input(currentImage: fixture.siblingImage, focusedImageSlot: fixture.siblingImage.slot,
                    nativeDecompilerState: fixture.nativeState(text: "AuthIA unknown-userop fake PAC", operations: operations)))
            let summary = try XCTUnwrap(candidate.data.field("authenticationSummary"))
            XCTAssertEqual(summary.field("totalCount"), .unsignedInteger(3))
            XCTAssertEqual(summary.field("returnedCount"), .unsignedInteger(UInt64(min(pageItems, 3))))
            XCTAssertEqual(summary.field("truncated"), .boolean(pageItems == 1))
            for key in ["transformedOutputCount", "incompleteAddressCount", "incompleteTargetCount"] {
                XCTAssertEqual(summary.field(key), .unsignedInteger(1))
            }
            guard case let .list(samples) = summary.field("samples") else { return XCTFail("Expected bounded samples") }
            XCTAssertEqual(samples[0].field("operationID"), .text("op0"))
            XCTAssertEqual(samples[0].field("outputSSAValueID"), .text("ssa-output"))
            XCTAssertEqual(samples[0].field("outputSSAProvidesRecoveredAddressOrTarget"), .boolean(false))
            guard case let .list(ranges) = samples[0].field("sourceRanges") else { return XCTFail("Expected ranges") }
            XCTAssertEqual(ranges[0].field("imageID"), .text("fixture-image"))
            XCTAssertEqual(ranges[0].field("binaryID"), .text(fixture.siblingImage.binaryID.uuidString.lowercased()))
            XCTAssertEqual(ranges[0].field("imageSlot"), .signedInteger(Int64(fixture.siblingImage.slot.rawValue)))
            if pageItems > 1 {
                XCTAssertEqual(samples[1].field("transformedAddressUnavailable"), .boolean(true))
                XCTAssertNil(samples[1].field("outputSSAValueID"))
                XCTAssertEqual(samples[2].field("transformedTargetUnavailable"), .boolean(true))
            }
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(summary).count, 32 * 1_024)
        }
    }

    func testNativeAuthenticationSummaryCapsEncodedBodyAndRangesWithoutTruncatingIDs() throws {
        let fixture = ProjectionFixture()
        let source = NativeDecompilerWireSourceRange(imageID: "fixture-image",
            startAddress: .init(0x1000), endAddressExclusive: .init(0x1004))
        let operations = (0..<40).map { index in
            NativeDecompilerWireOperationRecord(id: "op-\(index)-" + String(repeating: "x", count: 800),
                blockID: "block", sequence: .init(UInt64(index)), opcode: .callother,
                outputVarnodeID: "output", inputVarnodeIDs: [], directTargetAddress: nil,
                sourceRanges: Array(repeating: source, count: 10), userOperationName: "pacia",
                authenticationEffect: .init(kind: .transformedOutput, outputSSAValueID: "ssa-output"))
        }
        let authorization = try fixture.authorization(operation: .decompilerNativeResult, effects: [.a1],
            subject: .functionRange(fixture.siblingRange), image: fixture.siblingImage,
            limits: fixture.limits(pageItems: 100))
        let candidate = Phase2ReadProjector.project(authorization: authorization,
            input: fixture.input(currentImage: fixture.siblingImage, focusedImageSlot: fixture.siblingImage.slot,
                nativeDecompilerState: fixture.nativeState(text: "AuthIA is merely rendered text", operations: operations)))
        let summary = try XCTUnwrap(candidate.data.field("authenticationSummary"))
        XCTAssertEqual(summary.field("totalCount"), .unsignedInteger(40))
        XCTAssertEqual(summary.field("truncated"), .boolean(true))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(summary).count, 32 * 1_024)
        guard case let .list(samples) = summary.field("samples") else { return XCTFail("Expected samples") }
        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThan(samples.count, 32, "Encoded budget bounds the complete summary body")
        XCTAssertEqual(samples[0].field("operationID"), .text(operations[0].id))
        XCTAssertEqual(samples[0].field("sourceRangeCount"), .unsignedInteger(10))
        XCTAssertEqual(samples[0].field("sourceRangesTruncated"), .boolean(true))
        guard case let .list(ranges) = samples[0].field("sourceRanges") else { return XCTFail("Expected ranges") }
        XCTAssertEqual(ranges.count, 8)
    }

    func testMacScopeAndComparisonProjectionsUseFrozenFunctionEvidence() throws {
        let fixture = ProjectionFixture()
        let macScopeAuthorization = try fixture.authorization(
            operation: .decompilerMacScopeResult,
            effects: [.a1],
            subject: .functionRange(fixture.siblingRange),
            image: fixture.siblingImage
        )
        let comparisonAuthorization = try fixture.authorization(
            operation: .decompilerCompare,
            effects: [.a1],
            subject: .functionRange(fixture.siblingRange),
            image: fixture.siblingImage
        )
        let input = fixture.input(
            currentImage: fixture.siblingImage,
            focusedImageSlot: fixture.siblingImage.slot,
            nativeDecompilerState: fixture.nativeState(text: "int sibling_fn(void) { return 7; }")
        )

        let macScope = Phase2ReadProjector.project(
            authorization: macScopeAuthorization,
            input: input
        )
        XCTAssertEqual(macScope.data.field("source"), .text("macscope"))
        XCTAssertEqual(macScope.data.field("functionName"), .text("sibling_fn"))
        XCTAssertEqual(macScope.data.field("start"), .unsignedInteger(0x1000))

        let comparison = Phase2ReadProjector.project(
            authorization: comparisonAuthorization,
            input: input
        )
        XCTAssertEqual(comparison.data.field("source"), .text("comparison"))
        XCTAssertEqual(comparison.data.field("status"), .text("ready"))
        XCTAssertEqual(comparison.data.field("start"), .unsignedInteger(0x1000))
        XCTAssertEqual(comparison.data.field("endExclusive"), .unsignedInteger(0x1010))
        XCTAssertEqual(
            comparison.data.field("normalizerID"),
            .text("NativeDecompilerComparisonNormalizer.v1")
        )
        let instructions = comparison.data.field("categories")?.firstListItem
        XCTAssertEqual(instructions?.field("category"), .text("instructions"))
        XCTAssertEqual(instructions?.field("matchedCount"), .unsignedInteger(0))
        XCTAssertEqual(instructions?.field("nativeOnlyCount"), .unsignedInteger(0))
        XCTAssertEqual(instructions?.field("macScopeOnlyCount"), .unsignedInteger(3))
        XCTAssertEqual(instructions?.field("comparableUnionDenominator"), .unsignedInteger(3))
        XCTAssertEqual(instructions?.field("qualificationDenominator"), .unsignedInteger(3))
        XCTAssertEqual(instructions?.field("coverage"), .text("complete"))
        XCTAssertEqual(instructions?.field("correspondence"), .text("divergent"))
        XCTAssertNil(comparison.data.field("nativeInstructionCount"))
        XCTAssertNil(comparison.data.field("mismatchCategories"))
        XCTAssertNil(comparison.data.field("native"))
        XCTAssertNil(comparison.data.field("macScope"))
        XCTAssertEqual(comparison.citations.count, 2)
        XCTAssertTrue(comparison.citations.allSatisfy {
            $0.target == .functionRange(fixture.siblingRange)
        })
    }

    func testComparisonProjectionReturnsExplicitUnavailableWhenNativeSourceIsAbsent() throws {
        let fixture = ProjectionFixture()
        let authorization = try fixture.authorization(
            operation: .decompilerCompare,
            effects: [.a1],
            subject: .functionRange(fixture.siblingRange),
            image: fixture.siblingImage
        )

        let comparison = Phase2ReadProjector.project(
            authorization: authorization,
            input: fixture.input(
                currentImage: fixture.siblingImage,
                focusedImageSlot: fixture.siblingImage.slot,
                nativeDecompilerState: .idle
            )
        )

        XCTAssertEqual(comparison.data, .unavailable(.unavailable))
    }

    func testComparisonProjectionPreservesPartialExactDivergentAndEmptySemantics() throws {
        struct Scenario {
            let siblingInstructions: [UInt64]
            let nativeInstructions: [UInt64]
            let expectedCoverage: String
            let expectedCorrespondence: String
            let expectedMatched: UInt64
            let expectedNativeOnly: UInt64
            let expectedMacScopeOnly: UInt64
            let expectedUncomparableNative: UInt64
        }

        let scenarios = [
            Scenario(
                siblingInstructions: [0x1000],
                nativeInstructions: [0x1000, 0x2000],
                expectedCoverage: "partial",
                expectedCorrespondence: "exact",
                expectedMatched: 1,
                expectedNativeOnly: 0,
                expectedMacScopeOnly: 0,
                expectedUncomparableNative: 1
            ),
            Scenario(
                siblingInstructions: [0x1000, 0x1008],
                nativeInstructions: [0x1000, 0x1004, 0x2000],
                expectedCoverage: "partial",
                expectedCorrespondence: "divergent",
                expectedMatched: 1,
                expectedNativeOnly: 1,
                expectedMacScopeOnly: 1,
                expectedUncomparableNative: 1
            ),
            Scenario(
                siblingInstructions: [],
                nativeInstructions: [],
                expectedCoverage: "none",
                expectedCorrespondence: "noComparableRecords",
                expectedMatched: 0,
                expectedNativeOnly: 0,
                expectedMacScopeOnly: 0,
                expectedUncomparableNative: 0
            ),
        ]

        for scenario in scenarios {
            let fixture = ProjectionFixture(
                siblingInstructionAddresses: scenario.siblingInstructions
            )
            let authorization = try fixture.authorization(
                operation: .decompilerCompare,
                effects: [.a1],
                subject: .functionRange(fixture.siblingRange),
                image: fixture.siblingImage
            )
            let comparison = Phase2ReadProjector.project(
                authorization: authorization,
                input: fixture.input(
                    currentImage: fixture.siblingImage,
                    focusedImageSlot: fixture.siblingImage.slot,
                    nativeDecompilerState: fixture.nativeState(
                        text: "int sibling_fn(void) { return 7; }",
                        instructionAddresses: scenario.nativeInstructions
                    )
                )
            )
            let instructions = comparison.data.field("categories")?.firstListItem

            XCTAssertEqual(instructions?.field("matchedCount"), .unsignedInteger(scenario.expectedMatched))
            XCTAssertEqual(instructions?.field("nativeOnlyCount"), .unsignedInteger(scenario.expectedNativeOnly))
            XCTAssertEqual(instructions?.field("macScopeOnlyCount"), .unsignedInteger(scenario.expectedMacScopeOnly))
            XCTAssertEqual(
                instructions?.field("uncomparableNativeCount"),
                .unsignedInteger(scenario.expectedUncomparableNative)
            )
            XCTAssertEqual(instructions?.field("coverage"), .text(scenario.expectedCoverage))
            XCTAssertEqual(
                instructions?.field("correspondence"),
                .text(scenario.expectedCorrespondence)
            )
        }
    }
}

private extension Phase2ReadCandidateData {
    func field(_ name: String) -> Phase2ReadFactValue? {
        guard case let .value(value) = self else { return nil }
        return value.field(name)
    }
}

private extension Phase2ReadFactValue {
    func field(_ name: String) -> Phase2ReadFactValue? {
        guard case let .object(fields) = self else { return nil }
        return fields.first { $0.name == name }?.value
    }

    var firstListItem: Phase2ReadFactValue? {
        guard case let .list(values) = self else { return nil }
        return values.first
    }

    var listCount: Int? {
        guard case let .list(values) = self else { return nil }
        return values.count
    }
}

private struct ProjectionFixture {
    let workspace = Phase2ReadWorkspaceIdentity(
        document: .init(instanceID: projectionID(1)),
        instanceID: projectionID(2)
    )
    let primaryImage: Phase2ReadImageIdentity
    let siblingImage: Phase2ReadImageIdentity
    let snapshot: WorkspaceSnapshot

    var siblingRange: Phase2ReadFunctionRange {
        .init(image: siblingImage, start: 0x1000, endExclusive: 0x1010)
    }

    init(siblingInstructionAddresses: [UInt64] = [0x1008, 0x1000, 0x1004]) {
        primaryImage = Self.image(slot: .primary, binaryID: projectionID(10))
        siblingImage = Self.image(slot: .init(rawValue: 1), binaryID: projectionID(11))
        let primaryBinary = BinaryImage(
            id: primaryImage.binaryID,
            name: "primary",
            path: "/ignored/primary",
            kind: "Mach-O",
            architecture: "arm64",
            selectedSliceIndex: 0,
            artifactIdentity: Self.artifactIdentity(uuid: projectionID(40)),
            slot: .primary
        )
        let siblingBinary = BinaryImage(
            id: siblingImage.binaryID,
            name: "sibling",
            path: "/ignored/sibling",
            kind: "Mach-O",
            architecture: "arm64",
            selectedSliceIndex: 0,
            artifactIdentity: Self.artifactIdentity(uuid: projectionID(41)),
            slot: .init(rawValue: 1)
        )
        let primaryFunction = FunctionSummary(
            id: projectionID(20),
            name: "primary_fn",
            startAddress: 0x1000,
            endAddress: 0x1010,
            confidence: 1
        )
        let siblingFunction = FunctionSummary(
            id: projectionID(21),
            name: "sibling_fn",
            startAddress: 0x1000,
            endAddress: 0x1010,
            confidence: 0.9
        )
        var primaryAnalysis = ImageAnalysis(
            functions: [primaryFunction],
            instructions: [Self.instruction(0x1000, "primary-op")],
            analysisInputFingerprint: Self.fingerprint(
                image: primaryImage,
                name: "primary",
                path: "/ignored/primary",
                artifactIdentity: primaryBinary.artifactIdentity
            )
        )
        primaryAnalysis.machOMetadata = Self.metadata([
            Self.dependency(path: "/ignored/sibling", ordinal: 1),
            Self.dependency(path: "/usr/lib/libSystem.B.dylib", ordinal: 2),
            Self.dependency(path: "@rpath/Missing.framework/Missing", ordinal: 3),
        ])
        let siblingAnalysis = ImageAnalysis(
            functions: [siblingFunction],
            instructions: siblingInstructionAddresses.enumerated().map { index, address in
                Self.instruction(address, address == 0x1000 ? "sibling-op" : "sibling-op-\(index)")
            },
            analysisInputFingerprint: Self.fingerprint(
                image: siblingImage,
                name: "sibling",
                path: "/ignored/sibling",
                artifactIdentity: siblingBinary.artifactIdentity
            )
        )
        snapshot = .init(
            binaries: [primaryBinary, siblingBinary],
            analysisBySlot: [.primary: primaryAnalysis, .init(rawValue: 1): siblingAnalysis]
        )
    }

    func authorization(
        operation: Phase2ReadOperationID,
        effects: Set<Phase2EffectClass>,
        subject: Phase2ReadSubject,
        image: Phase2ReadImageIdentity,
        facets: [Phase2ReadFacet] = [.symbols],
        strictWholeWorkspace: Bool = false,
        limits: Phase2ReadLimits = .maximum
    ) throws -> Phase2ReadAuthorization {
        let descriptor = Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: operation,
            operationVersion: .v1,
            effects: effects
        )
        let request = Phase2ReadRequest(
            requestID: projectionID(30),
            invocationID: projectionID(UInt8(31 + image.slot.rawValue)),
            sequence: 1,
            proposingPrincipal: .model,
            descriptor: descriptor,
            subject: subject,
            precondition: precondition(
                image: image,
                facets: facets,
                strictWholeWorkspace: strictWholeWorkspace
            ),
            limits: limits
        )
        guard case let .authorized(result) = TypedReadRegistry().authorize(
            request,
            authorizingPrincipal: .app
        ) else {
            throw ProjectionTestError.authorizationRejected
        }
        return result
    }

    func input(
        currentImage: Phase2ReadImageIdentity,
        focusedImageSlot: ImageSlot?,
        nativeDecompilerState: NativeDecompilerPresentationState = .idle
    ) -> Phase2ReadProjectionInput {
        .init(
            workspaceName: "Projection Fixture",
            snapshot: snapshot,
            currentState: current(image: currentImage),
            focusedImageSlot: focusedImageSlot,
            nativeDecompilerState: nativeDecompilerState
        )
    }

    func nativeCoordinate(ownerBinaryID: UUID? = nil) -> NativeDecompilerPresentationCoordinate {
        .init(
            imageSlot: siblingImage.slot,
            ownerBinaryID: ownerBinaryID ?? siblingImage.binaryID,
            artifactUUID: projectionID(41),
            imageID: "fixture-image",
            functionID: projectionID(21).uuidString.lowercased(),
            requestSHA256: String(repeating: "a", count: 64),
            analysisInputFingerprintSHA256: String(repeating: "c", count: 64)
        )
    }

    func nativeState(
        text: String,
        instructionAddresses: [UInt64] = [],
        operations: [NativeDecompilerWireOperationRecord] = []
    ) -> NativeDecompilerPresentationState {
        let coordinate = nativeCoordinate()
        let result = NativeDecompilerWireStructuredResult(
            requestID: projectionID(50),
            requestSHA256: coordinate.requestSHA256,
            image: .init(
                imageID: coordinate.imageID,
                uuid: coordinate.artifactUUID,
                preferredLoadAddress: .init(0x1000)
            ),
            function: .init(
                functionID: coordinate.functionID,
                name: "sibling_fn",
                entryAddress: .init(0x1000),
                endAddressExclusive: .init(0x1010)
            ),
            addressSpaces: [],
            types: [],
            instructions: instructionAddresses.enumerated().map { index, address in
                NativeDecompilerWireInstructionRecord(
                    id: "instruction-\(index)",
                    address: .init(address),
                    bytes: Data([0x1f, 0x20, 0x03, 0xd5]),
                    mnemonic: "nop",
                    body: "",
                    operationIDs: [],
                    sourceRanges: []
                )
            },
            varnodes: [], operations: operations,
            blocks: [], edges: [], ssaValues: [], ssaBindings: [], phis: [],
            memoryVersions: [], memoryPhis: [], memoryEffects: [], variables: [], calls: [],
            regions: [], tokens: [],
            pseudocodeDocument: .init(
                text: text,
                language: "c",
                isComplete: true,
                isTruncated: false
            ),
            warnings: []
        )
        let capabilities = NativeDecompilerWireBackendCapabilities(
            nativeDecompilerHeritage: false,
            completeRegisterSSA: false,
            memorySSA: false,
            recoveredVariables: false,
            recoveredTypes: false,
            structuredControlFlow: false,
            tokenizedPseudocode: false,
            imageQualifiedSourceRanges: true
        )
        let availability = NativeDecompilerWireBackendAvailability(
            available: true,
            reasonCode: "ready",
            runtimeIdentity: .init(
                backendID: "native",
                engineVersion: "12.1.2",
                engineRevision: String(repeating: "b", count: 40),
                wrapperVersion: "1",
                wrapperRevision: String(repeating: "d", count: 40),
                packageManifestSHA256: String(repeating: "e", count: 64),
                packageTreeSHA256: String(repeating: "f", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
            ),
            capabilities: capabilities
        )
        return .ready(
            coordinate: coordinate,
            success: .init(availability: availability, result: result)
        )
    }

    func precondition(
        image: Phase2ReadImageIdentity,
        facets: [Phase2ReadFacet],
        strictWholeWorkspace: Bool
    ) -> Phase2ReadPrecondition {
        .init(
            workspace: workspace,
            workspaceRevision: 1,
            strictWholeWorkspace: strictWholeWorkspace,
            image: image,
            dependencies: facets.map { dependency(image: image, facet: $0) }
        )
    }

    func current(image: Phase2ReadImageIdentity) -> Phase2ReadCurrentState {
        .init(
            workspace: workspace,
            workspaceRevision: 1,
            image: image,
            facetRevisions: [
                .init(
                    scope: .workspace(workspace),
                    facet: .workspaceTopology,
                    revision: 1
                ),
                .init(
                    scope: .image(image.owner),
                    facet: .symbols,
                    revision: image.analysisRevision
                ),
                .init(
                    scope: .image(image.owner),
                    facet: .loaderMetadata,
                    revision: image.analysisRevision
                ),
            ]
        )
    }

    func limits(pageItems: Int, stringBytes: Int = 65_536) -> Phase2ReadLimits {
        .init(
            encodedRequestBytes: 65_536,
            encodedResultBytes: 1_048_576,
            structuralNesting: 12,
            objectMembers: 64,
            arrayItems: 1_024,
            stringBytes: stringBytes,
            pageItems: pageItems
        )
    }

    private func dependency(
        image: Phase2ReadImageIdentity,
        facet: Phase2ReadFacet
    ) -> Phase2ReadFacetDependency {
        if facet == .workspaceTopology {
            return .init(
                scope: .workspace(workspace),
                facet: facet,
                requiredRevision: 1
            )
        }
        return .init(
            scope: .image(image.owner),
            facet: facet,
            requiredRevision: image.analysisRevision
        )
    }

    private static func image(slot: ImageSlot, binaryID: UUID) -> Phase2ReadImageIdentity {
        .init(
            owner: .init(
                slot: slot,
                binaryID: binaryID,
                architecture: "arm64",
                sliceIndex: 0,
                ownerGeneration: 1
            ),
            analysisRevision: 1
        )
    }

    private static func instruction(_ address: UInt64, _ mnemonic: String) -> InstructionRow {
        .init(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )
    }

    private static func artifactIdentity(uuid: UUID) -> MachOSliceArtifactIdentity {
        try! .init(
            uuid: uuid,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 16
        )
    }

    private static func fingerprint(
        image: Phase2ReadImageIdentity,
        name: String,
        path: String,
        artifactIdentity: MachOSliceArtifactIdentity?
    ) -> AnalysisInputFingerprint {
        try! .init(
            imageSlot: image.slot,
            binaryID: image.binaryID,
            binaryName: name,
            binaryPath: path,
            selectedSliceIndex: 0,
            artifactIdentity: artifactIdentity,
            imageByteCount: 16,
            imageBytesSHA256: String(repeating: "b", count: 64),
            facets: [],
            overallSHA256: String(repeating: "c", count: 64)
        )
    }

    private static func metadata(
        _ dependencies: [MachOLoadMetadata.DependentDylib]
    ) -> MachOLoadMetadata {
        MachOLoadMetadata(
            codeSignature: nil,
            importedSymbols: [],
            dependentDylibs: dependencies
        )
    }

    private static func dependency(
        path: String,
        kind: String = "required",
        ordinal: Int
    ) -> MachOLoadMetadata.DependentDylib {
        MachOLoadMetadata.DependentDylib(
            path: path,
            kind: kind,
            currentVersion: "1.0.0",
            compatibilityVersion: "1.0.0",
            ordinal: ordinal
        )
    }
}

private enum ProjectionTestError: Error {
    case authorizationRejected
}

private func projectionID(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}

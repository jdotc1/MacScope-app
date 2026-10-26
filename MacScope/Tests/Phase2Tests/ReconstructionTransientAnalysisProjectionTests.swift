import XCTest

@testable import MacScope

final class ReconstructionTransientAnalysisProjectionTests: XCTestCase {
    func testRealAuthoredCatalogProjectsStableIDsWithoutMutatingDetachedAnalysis() async throws {
        let fixture = try ReconstructionRealHeadlessTestFixture.make()
        defer { fixture.remove() }
        let executor = ReconstructionHeadlessAnalysisExecutor(pool: try ReconstructionAnalysisProviderPool(
            factory: ReconstructionDefaultAnalysisProviderFactory(),
            budget: .init(maximumActiveAnalyses: 1, estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0), processorCount: 1, physicalMemory: 1))
        let result = try await executor.execute(.init(source: fixture.source,
            artifact: fixture.artifact, image: nil, functionID: nil, overrides: [:],
            imageAuthorityIntent: .initialLoad), cancellation: ReconstructionCancellation())
        let detached = result.detached
        let original = try XCTUnwrap(detached.workspace.analysis(in: detached.image.imageSlot))
        XCTAssertFalse(original.functions.isEmpty)
        let image = try ReconstructionImageCoordinate(artifact: detached.artifact,
            image: detached.image, analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256)
        var projectedCatalog: [FunctionSummary] = []
        for kind in [ReconstructionTaskKind.loadBinary, .indexImage, .enumerateFunctions] {
            for subject in [ReconstructionSubjectCoordinate.artifact(detached.artifact), .image(image)] {
                let task = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
                    taskID: UUID(), jobID: UUID(), kind: kind, subject: subject,
                    dependencyTaskIDs: [], operationContractIdentity: "reconstruction.\(kind.rawValue).v1"),
                    state: .pending, diagnostic: nil)
                let projection = try ReconstructionTransientAnalysisProjection.project(task: task,
                    detached: detached)
                XCTAssertEqual(projection.functionCatalog.count, original.functions.count)
                XCTAssertFalse(projection.functionCatalogWasTruncated)
                for function in projection.functionCatalog {
                    let source = try XCTUnwrap(original.functions.first {
                        $0.startAddress == function.startAddress && $0.endAddress == function.endAddress
                    })
                    XCTAssertEqual(function.id, ReconstructionStableImageAuthority.stableFunctionID(
                        image: detached.image,
                        analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
                        startAddress: source.startAddress, endAddressExclusive: source.endAddress,
                        boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion))
                    XCTAssertNotEqual(function.id, source.id)
                    XCTAssertEqual(function.name, source.name)
                    XCTAssertEqual(function.confidence, source.confidence)
                }
                if projectedCatalog.isEmpty { projectedCatalog = projection.functionCatalog }
                else { XCTAssertEqual(projection.functionCatalog, projectedCatalog) }
            }
        }
        let unchanged = try XCTUnwrap(detached.workspace.analysis(in: detached.image.imageSlot))
        XCTAssertEqual(unchanged.functions, original.functions)
        XCTAssertEqual(unchanged.basicBlocks, original.basicBlocks)
        XCTAssertEqual(unchanged.analysisInputFingerprint, original.analysisInputFingerprint)
        // Direct constructors retain their input IDs. Synthetic invalid catalog IDs must still
        // reach and fail the planner's identity validator instead of being repaired implicitly.
        let direct = try ReconstructionTransientAnalysisProjection(taskID: UUID(), taskKind: .enumerateFunctions,
            artifact: detached.artifact, image: detached.image,
            analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
            functionCatalog: original.functions, function: nil, macScopePseudocode: nil)
        XCTAssertEqual(Set(direct.functionCatalog.map(\.id)), Set(original.functions.map(\.id)))
        await executor.retire()
    }

    func testProjectsReopenedReboundFunctionWithNilUUIDHint() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let initial = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: fixture.image,
            provider: ReconstructionFixedAnalysisProvider(result: fixture.workspace),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )
        let freshFunction = try XCTUnwrap(
            initial.workspace.analysis(in: initial.image.imageSlot)?.functions.first
        )
        let coordinate = try projectionCoordinate(
            detached: initial,
            function: freshFunction,
            functionUUIDHint: nil
        )
        let rebound = try ReconstructionStableImageAuthority.bindFunction(
            coordinate,
            artifact: fixture.artifact,
            in: .init(
                image: initial.image,
                workspace: initial.workspace,
                analysisInputFingerprintSHA256: initial.analysisInputFingerprintSHA256
            )
        )
        let reboundDetached = ReconstructionDetachedAnalysisSnapshot(
            artifact: fixture.artifact,
            image: rebound.snapshot.image,
            workspace: rebound.snapshot.workspace,
            analysisInputFingerprintSHA256: rebound.snapshot.analysisInputFingerprintSHA256
        )
        let task = try projectionTask(
            kind: .decompileMacScope,
            coordinate: coordinate,
            value: 700
        )

        let projection = try ReconstructionTransientAnalysisProjection.project(
            task: task,
            detached: reboundDetached
        )

        XCTAssertNil(coordinate.functionUUIDHint)
        XCTAssertNotEqual(rebound.functionID, freshFunction.id)
        XCTAssertEqual(projection.function?.id, rebound.functionID)
        XCTAssertEqual(projection.function?.startAddress, coordinate.startAddress)
        XCTAssertEqual(projection.function?.endAddress, coordinate.endAddressExclusive)
        XCTAssertNotNil(projection.macScopePseudocode)
    }

    func testRefusesZeroAmbiguousImageFingerprintRangeAndBoundaryDrift() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let initial = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: fixture.image,
            provider: ReconstructionFixedAnalysisProvider(result: fixture.workspace),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )
        let freshFunction = try XCTUnwrap(
            initial.workspace.analysis(in: initial.image.imageSlot)?.functions.first
        )
        let coordinate = try projectionCoordinate(
            detached: initial,
            function: freshFunction,
            functionUUIDHint: projectionID(799)
        )
        let rebound = try ReconstructionStableImageAuthority.bindFunction(
            coordinate,
            artifact: fixture.artifact,
            in: .init(
                image: initial.image,
                workspace: initial.workspace,
                analysisInputFingerprintSHA256: initial.analysisInputFingerprintSHA256
            )
        )
        let reboundDetached = ReconstructionDetachedAnalysisSnapshot(
            artifact: fixture.artifact,
            image: rebound.snapshot.image,
            workspace: rebound.snapshot.workspace,
            analysisInputFingerprintSHA256: rebound.snapshot.analysisInputFingerprintSHA256
        )

        let zeroCandidate = try ReconstructionFunctionCoordinate(
            artifact: coordinate.artifact,
            image: coordinate.image,
            analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
            startAddress: coordinate.startAddress + 4,
            endAddressExclusive: coordinate.endAddressExclusive + 4,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: rebound.functionID,
            symbolHint: nil
        )
        XCTAssertThrowsError(try ReconstructionTransientAnalysisProjection.project(
            task: projectionTask(kind: .decompileNative, coordinate: zeroCandidate, value: 701),
            detached: reboundDetached
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionTransientAnalysisProjectionError,
                .missingExactFunction
            )
        }

        var ambiguousWorkspace = rebound.snapshot.workspace
        ambiguousWorkspace.mutateAnalysis(in: rebound.snapshot.image.imageSlot) { analysis in
            analysis.functions.append(.init(
                id: projectionID(798),
                name: "same_structural_range",
                startAddress: coordinate.startAddress,
                endAddress: coordinate.endAddressExclusive,
                confidence: 0.5
            ))
        }
        let ambiguousDetached = ReconstructionDetachedAnalysisSnapshot(
            artifact: fixture.artifact,
            image: rebound.snapshot.image,
            workspace: ambiguousWorkspace,
            analysisInputFingerprintSHA256: rebound.snapshot.analysisInputFingerprintSHA256
        )
        XCTAssertThrowsError(try ReconstructionTransientAnalysisProjection.project(
            task: projectionTask(kind: .decompileNative, coordinate: coordinate, value: 702),
            detached: ambiguousDetached
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionTransientAnalysisProjectionError,
                .missingExactFunction
            )
        }

        let driftedImage = ReconstructionImageBinding(
            binaryID: projectionID(797),
            imageSlot: coordinate.image.imageSlot,
            selectedSliceIndex: coordinate.image.selectedSliceIndex,
            architecture: coordinate.image.architecture,
            machOIdentity: coordinate.image.machOIdentity
        )
        let authorityDrifts = [
            try ReconstructionFunctionCoordinate(
                artifact: coordinate.artifact,
                image: driftedImage,
                analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
                startAddress: coordinate.startAddress,
                endAddressExclusive: coordinate.endAddressExclusive,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
                functionUUIDHint: rebound.functionID,
                symbolHint: nil
            ),
            try ReconstructionFunctionCoordinate(
                artifact: coordinate.artifact,
                image: coordinate.image,
                analysisFingerprintSHA256: projectionDigest(796),
                startAddress: coordinate.startAddress,
                endAddressExclusive: coordinate.endAddressExclusive,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
                functionUUIDHint: rebound.functionID,
                symbolHint: nil
            ),
            try ReconstructionFunctionCoordinate(
                artifact: coordinate.artifact,
                image: coordinate.image,
                analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
                startAddress: coordinate.startAddress,
                endAddressExclusive: coordinate.endAddressExclusive,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion + 1,
                functionUUIDHint: rebound.functionID,
                symbolHint: nil
            ),
        ]
        for (index, drifted) in authorityDrifts.enumerated() {
            XCTAssertThrowsError(try ReconstructionTransientAnalysisProjection.project(
                task: projectionTask(
                    kind: .decompileNative,
                    coordinate: drifted,
                    value: 710 + index
                ),
                detached: reboundDetached
            )) { error in
                XCTAssertEqual(
                    error as? ReconstructionTransientAnalysisProjectionError,
                    .invalidAuthority
                )
            }
        }
    }

    func testBoundsFunctionNamesAndAggregateCatalogAtScalarBoundaries() throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let oversizedName = String(
            repeating: "a",
            count: ReconstructionTransientAnalysisProjection.maximumFunctionNameUTF8Bytes
        ) + "é-tail"
        let entryCount =
            ReconstructionTransientAnalysisProjection.maximumFunctionCatalogNameUTF8Bytes
            / ReconstructionTransientAnalysisProjection.maximumFunctionNameUTF8Bytes
            + 2
        let functions = (0..<entryCount).map { index in
            FunctionSummary(
                id: projectionID(index + 1),
                name: oversizedName,
                startAddress: 0x1000 + UInt64(index * 4),
                endAddress: 0x1004 + UInt64(index * 4),
                confidence: 1
            )
        }

        let catalog = try ReconstructionTransientAnalysisProjection(
            taskID: projectionID(80),
            taskKind: .enumerateFunctions,
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: projectionDigest(80),
            functionCatalog: functions,
            function: nil,
            macScopePseudocode: nil
        )

        let retainedNameBytes = catalog.functionCatalog.reduce(0) {
            $0 + $1.name.utf8.count
        }
        XCTAssertEqual(
            retainedNameBytes,
            ReconstructionTransientAnalysisProjection.maximumFunctionCatalogNameUTF8Bytes
        )
        XCTAssertTrue(catalog.functionCatalog.allSatisfy {
            $0.name.utf8.count
                <= ReconstructionTransientAnalysisProjection.maximumFunctionNameUTF8Bytes
                && !$0.name.contains("�")
        })
        XCTAssertTrue(catalog.functionCatalogWasTruncated)
        XCTAssertTrue(catalog.functionNamesWereTruncated)

        let exact = try ReconstructionTransientAnalysisProjection(
            taskID: projectionID(81),
            taskKind: .decompileNative,
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: projectionDigest(81),
            functionCatalog: [],
            function: .init(
                id: projectionID(82),
                name: oversizedName,
                startAddress: 0x2000,
                endAddress: 0x2004,
                confidence: 1
            ),
            macScopePseudocode: nil
        )
        XCTAssertEqual(
            exact.function?.name.utf8.count,
            ReconstructionTransientAnalysisProjection.maximumFunctionNameUTF8Bytes
        )
        XCTAssertTrue(exact.functionNamesWereTruncated)
    }

    func testNormalizesCatalogOrderCountAndMacScopeTextAtScalarBoundaries() throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }

        let functions = (0...ReconstructionTransientAnalysisProjection.maximumFunctionCount)
            .reversed()
            .map { index in
                FunctionSummary(
                    id: projectionID(index + 1),
                    name: "function_\(index)",
                    startAddress: 0x1000 + UInt64(index * 4),
                    endAddress: 0x1004 + UInt64(index * 4),
                    confidence: 1
                )
            }
        let imageProjection = try ReconstructionTransientAnalysisProjection(
            taskID: projectionID(90),
            taskKind: .enumerateFunctions,
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: projectionDigest(1),
            functionCatalog: functions,
            function: nil,
            macScopePseudocode: nil
        )

        XCTAssertEqual(
            imageProjection.functionCatalog.count,
            ReconstructionTransientAnalysisProjection.maximumFunctionCount
        )
        XCTAssertTrue(imageProjection.functionCatalogWasTruncated)
        XCTAssertEqual(imageProjection.functionCatalog.first?.startAddress, 0x1000)
        XCTAssertEqual(
            imageProjection.functionCatalog.last?.startAddress,
            0x1000 + UInt64(
                (ReconstructionTransientAnalysisProjection.maximumFunctionCount - 1) * 4
            )
        )

        let exactFunction = try XCTUnwrap(fixture.workspace.functions.first)
        let oversizedText = String(
            repeating: "a",
            count: ReconstructionTransientAnalysisProjection.maximumMacScopePseudocodeUTF8Bytes - 1
        ) + "é-tail"
        let functionProjection = try ReconstructionTransientAnalysisProjection(
            taskID: projectionID(91),
            taskKind: .compareDecompilers,
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: projectionDigest(2),
            functionCatalog: [],
            function: exactFunction,
            macScopePseudocode: oversizedText
        )

        let boundedText = try XCTUnwrap(functionProjection.macScopePseudocode)
        XCTAssertEqual(
            boundedText.utf8.count,
            ReconstructionTransientAnalysisProjection.maximumMacScopePseudocodeUTF8Bytes - 1
        )
        XCTAssertTrue(functionProjection.macScopePseudocodeWasTruncated)
        XCTAssertFalse(boundedText.contains("�"))
        XCTAssertEqual(functionProjection.function?.id, fixture.functionID)

        for outcome in [
            ReconstructionTerminalTaskOutcome.failed,
            .cancelled,
            .staleAuthority,
        ] {
            let terminal = ReconstructionTerminalTaskResult(
                jobID: projectionID(92),
                taskID: functionProjection.taskID,
                checkpointID: projectionID(93),
                checkpointRevision: 1,
                corpusManifestSHA256: projectionDigest(3),
                outcome: outcome,
                analysisProjection: functionProjection,
                nativeResult: .cancelled
            )
            XCTAssertNil(terminal.analysisProjection)
            XCTAssertNil(terminal.nativeResult)
        }
    }

    func testExactFunctionRenderInputDoesNotFallBackToSameAddressSibling() throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        var workspace = fixture.workspace
        let siblingID = projectionID(42)
        workspace.mutateAnalysis(in: fixture.image.imageSlot) { analysis in
            analysis.functions = [
                .init(
                    id: siblingID,
                    name: "same_address_sibling",
                    startAddress: 0x1000,
                    endAddress: 0x1004,
                    confidence: 1
                ),
                .init(
                    id: fixture.functionID,
                    name: "exact_target",
                    startAddress: 0x1000,
                    endAddress: 0x1008,
                    confidence: 1
                ),
            ]
            analysis.instructions = [
                .init(
                    address: 0x1000,
                    bytes: "c0 03 5f d6",
                    mnemonic: "ret",
                    operands: "",
                    hasBreakpoint: false,
                    comment: nil
                ),
            ]
        }

        let exact = try XCTUnwrap(workspace.pseudocodeRenderInput(
            exactFunctionID: fixture.functionID,
            in: fixture.image.imageSlot
        ))
        XCTAssertEqual(exact.functionName, "exact_target")
        XCTAssertEqual(exact.startAddress, 0x1000)
        XCTAssertEqual(exact.instructions.map(\.address), [0x1000])
    }

    func testDuplicateFunctionUUIDFailsClosedForRenderAndProjection() throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        var workspace = fixture.workspace
        workspace.mutateAnalysis(in: fixture.image.imageSlot) { analysis in
            analysis.functions = [
                .init(
                    id: fixture.functionID,
                    name: "first_claim",
                    startAddress: 0x1000,
                    endAddress: 0x1008,
                    confidence: 1
                ),
                .init(
                    id: fixture.functionID,
                    name: "conflicting_claim",
                    startAddress: 0x2000,
                    endAddress: 0x2008,
                    confidence: 0.5
                ),
            ]
        }

        XCTAssertNil(workspace.pseudocodeRenderInput(
            exactFunctionID: fixture.functionID,
            in: fixture.image.imageSlot
        ))

        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: projectionDigest(8),
            startAddress: 0x1000,
            endAddressExclusive: 0x1008,
            boundarySchemaVersion: 1,
            functionUUIDHint: fixture.functionID,
            symbolHint: "first_claim"
        )
        let task = ReconstructionTaskRecord(
            identity: try .init(
                taskID: projectionID(94),
                jobID: projectionID(95),
                kind: .decompileMacScope,
                subject: .function(coordinate),
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.decompileMacScope.v1",
                canonicalSHA256: projectionDigest(9)
            ),
            state: .pending,
            diagnostic: nil
        )
        let detached = ReconstructionDetachedAnalysisSnapshot(
            artifact: fixture.artifact,
            image: fixture.image,
            workspace: workspace,
            analysisInputFingerprintSHA256: projectionDigest(8)
        )

        XCTAssertThrowsError(try ReconstructionTransientAnalysisProjection.project(
            task: task,
            detached: detached
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionTransientAnalysisProjectionError,
                .invalidAuthority
            )
        }
    }
}

private func projectionID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "b0000000-0000-4000-8000-%012d", value))!
}

private func projectionDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}

private func projectionCoordinate(
    detached: ReconstructionDetachedAnalysisSnapshot,
    function: FunctionSummary,
    functionUUIDHint: UUID?
) throws -> ReconstructionFunctionCoordinate {
    try .init(
        artifact: detached.artifact,
        image: detached.image,
        analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
        startAddress: function.startAddress,
        endAddressExclusive: function.endAddress,
        boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
        functionUUIDHint: functionUUIDHint,
        symbolHint: function.name
    )
}

private func projectionTask(
    kind: ReconstructionTaskKind,
    coordinate: ReconstructionFunctionCoordinate,
    value: Int
) throws -> ReconstructionTaskRecord {
    .init(
        identity: try .init(
            taskID: projectionID(value),
            jobID: projectionID(value + 1_000),
            kind: kind,
            subject: .function(coordinate),
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.\(kind.rawValue).v1",
            canonicalSHA256: projectionDigest(value)
        ),
        state: .pending,
        diagnostic: nil
    )
}

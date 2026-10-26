import XCTest

@testable import MacScope

final class ReconstructionHeadlessAnalysisExecutorTests: XCTestCase {
    func testForwardsPauseResumeAndTerminalRetirementToProviderPool() async throws {
        let pool = try ReconstructionAnalysisProviderPool(
            factory: ReconstructionHeadlessLifecycleProviderFactory(),
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 1
        )
        let executor: any ReconstructionHeadlessAnalysisExecuting =
            ReconstructionHeadlessAnalysisExecutor(pool: pool)

        await executor.pause()
        let paused = await pool.snapshot()
        XCTAssertEqual(paused.lifecycle, .paused)

        await executor.resume()
        let active = await pool.snapshot()
        XCTAssertEqual(active.lifecycle, .active)

        await executor.retire()
        await executor.resume()
        let retired = await pool.snapshot()
        XCTAssertEqual(retired.lifecycle, .retired)
    }

    func testComputesFreshFingerprintAndBindsFunctionByDurableCoordinate() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let provider = ReconstructionFixedAnalysisProvider(result: fixture.workspace)
        let pool = try ReconstructionAnalysisProviderPool(
            factory: ReconstructionFixedAnalysisProviderFactory(provider: provider),
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            )
        )
        let executor = ReconstructionHeadlessAnalysisExecutor(pool: pool)

        let first = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: fixture.artifact,
                image: fixture.image,
                functionID: nil,
                overrides: [:]
            ),
            cancellation: ReconstructionCancellation()
        )
        let firstFunction = try XCTUnwrap(
            first.detached.workspace.analysis(in: fixture.image.imageSlot)?.functions.first
        )
        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: first.detached.analysisInputFingerprintSHA256,
            startAddress: firstFunction.startAddress,
            endAddressExclusive: firstFunction.endAddress,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: firstFunction.id,
            symbolHint: firstFunction.name
        )
        let result = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: fixture.artifact,
                image: fixture.image,
                functionID: firstFunction.id,
                overrides: [:],
                functionCoordinate: coordinate
            ),
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result.detached.workspace.binaries.count, 1)
        let projection = try XCTUnwrap(result.projection)
        let expectedFunctionID = ReconstructionStableImageAuthority.stableFunctionID(
            image: fixture.image,
            analysisFingerprintSHA256: first.detached.analysisInputFingerprintSHA256,
            startAddress: firstFunction.startAddress,
            endAddressExclusive: firstFunction.endAddress,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion
        )
        XCTAssertEqual(projection.functionID, expectedFunctionID)
        XCTAssertEqual(
            projection.analysisInputFingerprintSHA256,
            first.detached.analysisInputFingerprintSHA256
        )

        let missingCoordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: first.detached.analysisInputFingerprintSHA256,
            startAddress: 0x2000,
            endAddressExclusive: 0x2008,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: fixture.functionID,
            symbolHint: nil
        )
        do {
            _ = try await executor.execute(
                .init(
                    source: fixture.source,
                    artifact: fixture.artifact,
                    image: fixture.image,
                    functionID: fixture.functionID,
                    overrides: [:],
                    functionCoordinate: missingCoordinate
                ),
                cancellation: ReconstructionCancellation()
            )
            XCTFail("A function outside the detached snapshot must not gain native authority")
        } catch let error as ReconstructionDetachedAnalysisError {
            XCTAssertEqual(error, .analysisAuthorityMismatch)
        }
    }

    func testNilExpectedImageIsRejectedOutsideInitialLoadIntent() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let provider = ReconstructionFixedAnalysisProvider(result: fixture.workspace)
        let executor = ReconstructionHeadlessAnalysisExecutor(
            pool: try ReconstructionAnalysisProviderPool(
                factory: ReconstructionFixedAnalysisProviderFactory(provider: provider),
                budget: .init(
                    maximumActiveAnalyses: 1,
                    estimatedResidentBytesPerAnalysis: 1,
                    reservedHostBytes: 0
                )
            )
        )

        do {
            _ = try await executor.execute(
                .init(
                    source: fixture.source,
                    artifact: fixture.artifact,
                    image: nil,
                    functionID: nil,
                    overrides: [:]
                ),
                cancellation: ReconstructionCancellation()
            )
            XCTFail("Only initial load may establish a missing image binding")
        } catch let error as ReconstructionDetachedAnalysisError {
            XCTAssertEqual(error, .analysisAuthorityMismatch)
        }
    }

    func testDefaultAnalysisEngineFirstLoadReopenAndDecompilerProjectionUsesStableAuthority()
        async throws
    {
        let fixture = try ReconstructionRealHeadlessTestFixture.make(
            occurrenceID: UUID(uuidString: "91000000-0000-4000-8000-000000000091")!
        )
        defer { fixture.remove() }
        let executor = ReconstructionHeadlessAnalysisExecutor(
            pool: try makeDefaultProviderPool()
        )

        let initial = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: fixture.artifact,
                image: nil,
                functionID: nil,
                overrides: [:],
                imageAuthorityIntent: .initialLoad
            ),
            cancellation: ReconstructionCancellation()
        )
        let expectedImageID = ReconstructionStableImageAuthority.stableBinaryID(
            occurrenceID: fixture.artifact.occurrenceID,
            selectedSliceIndex: initial.detached.image.selectedSliceIndex
        )
        XCTAssertEqual(initial.detached.image.binaryID, expectedImageID)
        XCTAssertEqual(initial.detached.image.imageSlot, .primary)
        XCTAssertEqual(initial.detached.image.architecture, .arm64)
        XCTAssertNotNil(initial.detached.image.machOIdentity)

        let firstFunction = try XCTUnwrap(
            initial.detached.workspace
                .analysis(in: initial.detached.image.imageSlot)?
                .functions.first
        )
        let initialOwnedBlocks = initial.detached.workspace
            .analysis(in: initial.detached.image.imageSlot)?
            .basicBlocks.filter { $0.functionID == firstFunction.id } ?? []
        XCTAssertFalse(initialOwnedBlocks.isEmpty)
        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: initial.detached.image,
            analysisFingerprintSHA256: initial.detached.analysisInputFingerprintSHA256,
            startAddress: firstFunction.startAddress,
            endAddressExclusive: firstFunction.endAddress,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: firstFunction.id,
            symbolHint: firstFunction.name
        )

        let reopened = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: fixture.artifact,
                image: initial.detached.image,
                functionID: firstFunction.id,
                overrides: [:],
                functionCoordinate: coordinate
            ),
            cancellation: ReconstructionCancellation()
        )
        let projection = try XCTUnwrap(reopened.projection)
        let expectedFunctionID = ReconstructionStableImageAuthority.stableFunctionID(
            image: initial.detached.image,
            analysisFingerprintSHA256: initial.detached.analysisInputFingerprintSHA256,
            startAddress: firstFunction.startAddress,
            endAddressExclusive: firstFunction.endAddress,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion
        )
        XCTAssertEqual(projection.functionID, expectedFunctionID)
        XCTAssertNotEqual(projection.functionID, firstFunction.id)
        XCTAssertEqual(
            reopened.detached.analysisInputFingerprintSHA256,
            initial.detached.analysisInputFingerprintSHA256
        )
        let reopenedAnalysis = try XCTUnwrap(
            reopened.detached.workspace.analysis(in: reopened.detached.image.imageSlot)
        )
        XCTAssertTrue(reopenedAnalysis.functions.contains { $0.id == expectedFunctionID })
        let ownedBlockRanges = Set(initialOwnedBlocks.map {
            "\($0.startAddress):\($0.endAddress)"
        })
        let reopenedOwnedBlocks = reopenedAnalysis.basicBlocks.filter {
            ownedBlockRanges.contains("\($0.startAddress):\($0.endAddress)")
        }
        XCTAssertEqual(reopenedOwnedBlocks.count, initialOwnedBlocks.count)
        XCTAssertTrue(reopenedOwnedBlocks.allSatisfy {
            $0.functionID == expectedFunctionID
        })

        let reopenedAgain = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: fixture.artifact,
                image: initial.detached.image,
                functionID: nil,
                overrides: [:],
                functionCoordinate: coordinate
            ),
            cancellation: ReconstructionCancellation()
        )
        XCTAssertEqual(reopenedAgain.projection?.functionID, expectedFunctionID)
        XCTAssertEqual(
            reopenedAgain.detached.analysisInputFingerprintSHA256,
            initial.detached.analysisInputFingerprintSHA256
        )
    }

    func testDuplicateArtifactOccurrencesReceiveDifferentStableImageOwners() async throws {
        let firstOccurrence = UUID(uuidString: "92000000-0000-4000-8000-000000000092")!
        let secondOccurrence = UUID(uuidString: "93000000-0000-4000-8000-000000000093")!
        let fixture = try ReconstructionRealHeadlessTestFixture.make(
            occurrenceID: firstOccurrence
        )
        defer { fixture.remove() }
        let executor = ReconstructionHeadlessAnalysisExecutor(
            pool: try makeDefaultProviderPool()
        )
        let secondArtifact = fixture.artifact(occurrenceID: secondOccurrence)

        let first = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: fixture.artifact,
                image: nil,
                functionID: nil,
                overrides: [:],
                imageAuthorityIntent: .initialLoad
            ),
            cancellation: ReconstructionCancellation()
        )
        let second = try await executor.execute(
            .init(
                source: fixture.source,
                artifact: secondArtifact,
                image: nil,
                functionID: nil,
                overrides: [:],
                imageAuthorityIntent: .initialLoad
            ),
            cancellation: ReconstructionCancellation()
        )

        XCTAssertNotEqual(first.detached.image.binaryID, second.detached.image.binaryID)
        XCTAssertEqual(first.detached.image.machOIdentity, second.detached.image.machOIdentity)
        XCTAssertEqual(first.detached.image.imageSlot, .primary)
        XCTAssertEqual(second.detached.image.imageSlot, .primary)
    }
}

private func makeDefaultProviderPool() throws -> ReconstructionAnalysisProviderPool {
    try ReconstructionAnalysisProviderPool(
        factory: ReconstructionDefaultAnalysisProviderFactory(),
        budget: .init(
            maximumActiveAnalyses: 1,
            estimatedResidentBytesPerAnalysis: 1,
            reservedHostBytes: 0
        ),
        processorCount: 1,
        physicalMemory: 1
    )
}

private struct ReconstructionHeadlessLifecycleProviderFactory:
    ReconstructionAnalysisProviderFactory
{
    func makeProvider() -> any AnalysisProviding {
        ReconstructionHeadlessLifecycleProvider()
    }
}

private struct ReconstructionHeadlessLifecycleProvider: AnalysisProviding {
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("lifecycle forwarding does not execute provider analysis")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        fatalError("lifecycle forwarding does not execute provider analysis")
    }
}

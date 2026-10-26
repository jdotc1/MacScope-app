import XCTest

@testable import MacScope

final class ReconstructionBatchTaskExecutorTests: XCTestCase {
    func testLifecycleForwardsToHeadlessPoolAndNativeAdmission() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let resolver = FixedBatchRequestResolver(request: .init(
            source: fixture.source,
            artifact: fixture.artifact,
            image: fixture.image,
            functionID: nil,
            overrides: [:]
        ))
        let headless = RejectingHeadlessExecutor()
        let native = RejectingNativeDecompiler()
        let executor = ReconstructionBatchTaskExecutor(
            resolver: resolver,
            headless: headless,
            native: native
        )

        await executor.pause()
        await executor.resume()
        await executor.retire()

        let headlessLifecycle = await headless.lifecycleCounts
        let nativeLifecycle = await native.lifecycleCounts
        XCTAssertEqual(headlessLifecycle.pause, 1)
        XCTAssertEqual(headlessLifecycle.resume, 1)
        XCTAssertEqual(headlessLifecycle.retire, 1)
        XCTAssertEqual(nativeLifecycle.cancel, 1)
        XCTAssertEqual(nativeLifecycle.retire, 1)
    }

    func testCommittedCorpusTasksDoNotTriggerDetachedAnalysisOrNativeDecompiler() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let jobID = UUID()
        let authority = try ReconstructionBatchAuthority(
            jobID: jobID,
            checkpointID: UUID(),
            checkpointRevision: 1,
            corpusManifestSHA256: String(repeating: "a", count: 64)
        )
        let request = ReconstructionHeadlessAnalysisRequest(
            source: fixture.source,
            artifact: fixture.artifact,
            image: fixture.image,
            functionID: nil,
            overrides: [:]
        )
        let resolver = FixedBatchRequestResolver(request: request)
        let headless = RejectingHeadlessExecutor()
        let native = RejectingNativeDecompiler()
        let executor = ReconstructionBatchTaskExecutor(
            resolver: resolver,
            headless: headless,
            native: native
        )

        for kind in [
            ReconstructionTaskKind.ingest,
            .classify,
            .discoverRelations,
        ] {
            let task = try batchExecutorTask(
                kind: kind,
                jobID: jobID,
                artifact: fixture.artifact
            )
            let result = await executor.execute(
                task: task,
                authority: authority,
                cancellation: ReconstructionCancellation()
            )
            XCTAssertEqual(result.outcome, .completed)
        }

        let headlessCount = await headless.executionCount
        let nativeCount = await native.decompileCount
        XCTAssertEqual(headlessCount, 0)
        XCTAssertEqual(nativeCount, 0)
    }

    func testCompareDecompilersPublishesMacScopeAndNativeResultsFromOneExactAuthority() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let jobID = UUID()
        let authority = try ReconstructionBatchAuthority(
            jobID: jobID,
            checkpointID: UUID(),
            checkpointRevision: 9,
            corpusManifestSHA256: String(repeating: "a", count: 64)
        )
        let stableFunctionID = ReconstructionStableImageAuthority.stableFunctionID(
            image: fixture.image,
            analysisFingerprintSHA256: String(repeating: "b", count: 64),
            startAddress: 0x1000,
            endAddressExclusive: 0x1008,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion
        )
        var workspace = fixture.workspace
        workspace.mutateAnalysis(in: fixture.image.imageSlot) { analysis in
            analysis.functions = [FunctionSummary(
                id: stableFunctionID,
                name: "entry",
                startAddress: 0x1000,
                endAddress: 0x1008,
                confidence: 1
            )]
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
        let request = ReconstructionHeadlessAnalysisRequest(
            source: fixture.source,
            artifact: fixture.artifact,
            image: fixture.image,
            functionID: fixture.functionID,
            overrides: [:]
        )
        let headlessResult = ReconstructionHeadlessAnalysisResult(
            detached: .init(
                artifact: fixture.artifact,
                image: fixture.image,
                workspace: workspace,
                analysisInputFingerprintSHA256: String(repeating: "b", count: 64)
            ),
            projection: try NativeDecompilerProjectionRequest(
                workspace: workspace,
                imageSlot: fixture.image.imageSlot,
                functionID: stableFunctionID,
                analysisInputFingerprintSHA256: String(repeating: "b", count: 64)
            )
        )
        let resolver = FixedBatchRequestResolver(request: request)
        let headless = FixedSuccessfulHeadlessExecutor(result: headlessResult)
        let native = RecordingCompletedNativeDecompiler(
            execution: makeExecutorNativeExecution(functionID: stableFunctionID)
        )
        let executor = ReconstructionBatchTaskExecutor(
            resolver: resolver,
            headless: headless,
            native: native
        )
        let task = try batchExecutorFunctionTask(
            kind: .compareDecompilers,
            jobID: jobID,
            fixture: fixture
        )

        let result = await executor.execute(
            task: task,
            authority: authority,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result.jobID, jobID)
        XCTAssertEqual(result.taskID, task.identity.taskID)
        XCTAssertEqual(result.outcome, .completed)
        let projection = try XCTUnwrap(result.analysisProjection)
        XCTAssertEqual(projection.taskID, task.identity.taskID)
        XCTAssertEqual(projection.taskKind, .compareDecompilers)
        XCTAssertEqual(projection.function?.id, stableFunctionID)
        XCTAssertTrue(try XCTUnwrap(projection.macScopePseudocode).contains("entry"))
        guard case .completed(let nativeSuccess)? = result.nativeResult else {
            return XCTFail("compare must retain one completed native result")
        }
        XCTAssertEqual(nativeSuccess.taskID, task.identity.taskID)
        XCTAssertEqual(nativeSuccess.checkpointID, authority.checkpointID)
        XCTAssertEqual(nativeSuccess.checkpointRevision, authority.checkpointRevision)
        XCTAssertEqual(nativeSuccess.corpusManifestSHA256, authority.corpusManifestSHA256)
        let requests = await native.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].taskID, task.identity.taskID)
        XCTAssertEqual(
            requests[0].projection.analysisInputFingerprintSHA256,
            projection.analysisFingerprintSHA256
        )
        XCTAssertEqual(requests[0].projection.functionID, projection.function?.id)

        let mismatchedNative = RecordingCompletedNativeDecompiler(
            execution: makeExecutorNativeExecution(functionID: stableFunctionID)
        )
        let mismatchedHeadless = FixedSuccessfulHeadlessExecutor(
            result: ReconstructionHeadlessAnalysisResult(
                detached: headlessResult.detached,
                projection: try NativeDecompilerProjectionRequest(
                    workspace: workspace,
                    imageSlot: fixture.image.imageSlot,
                    functionID: UUID(),
                    analysisInputFingerprintSHA256: String(repeating: "b", count: 64)
                )
            )
        )
        let mismatchedExecutor = ReconstructionBatchTaskExecutor(
            resolver: resolver,
            headless: mismatchedHeadless,
            native: mismatchedNative
        )

        let mismatchedResult = await mismatchedExecutor.execute(
            task: task,
            authority: authority,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(mismatchedResult.outcome, .failed)
        XCTAssertNil(mismatchedResult.analysisProjection)
        XCTAssertNil(mismatchedResult.nativeResult)
        let mismatchedRequests = await mismatchedNative.requests
        XCTAssertTrue(mismatchedRequests.isEmpty)

        // Mutation RED recipe: remove the `nativeProjection.functionID == exactFunctionID` guard
        // in ReconstructionBatchTaskExecutor. This selector must fail because the mismatched
        // native request is dispatched and its completed payload is incorrectly published.

        // D13: a native decompiler that fails closed no longer fails the task. The comparison
        // completes on its MacIR projection, without native bytes, and records the reason.
        let failingNative = RejectingNativeDecompiler()
        let fallbackResult = await ReconstructionBatchTaskExecutor(
            resolver: resolver, headless: headless, native: failingNative
        ).execute(task: task, authority: authority, cancellation: ReconstructionCancellation())
        XCTAssertEqual(fallbackResult.outcome, .completed)
        XCTAssertNil(fallbackResult.nativeResult)
        XCTAssertEqual(fallbackResult.decompileFallbackReason, "native-failed: providerUnavailable")
        XCTAssertTrue(try XCTUnwrap(fallbackResult.analysisProjection?.macScopePseudocode).contains("entry"))
        let failingCount = await failingNative.decompileCount
        XCTAssertEqual(failingCount, 1)
    }
}

private struct FixedBatchRequestResolver: ReconstructionHeadlessAnalysisRequestResolving {
    let request: ReconstructionHeadlessAnalysisRequest
    func request(
        for task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority
    ) async throws -> ReconstructionHeadlessAnalysisRequest { request }
}

private actor RejectingHeadlessExecutor: ReconstructionHeadlessAnalysisExecuting {
    private(set) var executionCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var retireCount = 0
    var lifecycleCounts: (pause: Int, resume: Int, retire: Int) {
        (pauseCount, resumeCount, retireCount)
    }
    func execute(
        _ request: ReconstructionHeadlessAnalysisRequest,
        cancellation: ReconstructionCancellation
    ) async throws -> ReconstructionHeadlessAnalysisResult {
        executionCount += 1
        throw CancellationError()
    }

    func pause() async { pauseCount += 1 }
    func resume() async { resumeCount += 1 }
    func retire() async { retireCount += 1 }
}

private actor FixedSuccessfulHeadlessExecutor: ReconstructionHeadlessAnalysisExecuting {
    let result: ReconstructionHeadlessAnalysisResult

    init(result: ReconstructionHeadlessAnalysisResult) {
        self.result = result
    }

    func execute(
        _ request: ReconstructionHeadlessAnalysisRequest,
        cancellation: ReconstructionCancellation
    ) async throws -> ReconstructionHeadlessAnalysisResult {
        try cancellation.check()
        return result
    }

    func pause() async {}
    func resume() async {}
    func retire() async {}
}

private actor RejectingNativeDecompiler: ReconstructionNativeTaskDecompiling {
    private(set) var decompileCount = 0
    private(set) var cancelCount = 0
    private(set) var retireCount = 0
    var lifecycleCounts: (cancel: Int, retire: Int) { (cancelCount, retireCount) }
    func decompile(
        _ request: ReconstructionNativeDecompilationRequest,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionNativeTaskResult {
        decompileCount += 1
        return .failed(.providerUnavailable)
    }
    func cancelOutstanding() async { cancelCount += 1 }
    func retire() async { retireCount += 1 }
}

private actor RecordingCompletedNativeDecompiler: ReconstructionNativeTaskDecompiling {
    let execution: NativeDecompilerValidatedExecution
    private(set) var requests: [ReconstructionNativeDecompilationRequest] = []

    init(execution: NativeDecompilerValidatedExecution) {
        self.execution = execution
    }

    func decompile(
        _ request: ReconstructionNativeDecompilationRequest,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionNativeTaskResult {
        requests.append(request)
        do {
            try cancellation.check()
            return .completed(.init(
                taskID: request.taskID,
                checkpointID: request.checkpointID,
                checkpointRevision: request.checkpointRevision,
                corpusManifestSHA256: request.corpusManifestSHA256,
                execution: execution
            ))
        } catch {
            return .cancelled
        }
    }

    func cancelOutstanding() async {}
    func retire() async {}
}

private func batchExecutorTask(
    kind: ReconstructionTaskKind,
    jobID: UUID,
    artifact: ReconstructionArtifactCoordinate
) throws -> ReconstructionTaskRecord {
    .init(
        identity: try .init(
            taskID: UUID(), jobID: jobID, kind: kind, subject: .artifact(artifact),
            dependencyTaskIDs: [], operationContractIdentity: "reconstruction.\(kind.rawValue).v1",
            canonicalSHA256: String(repeating: "b", count: 64)
        ),
        state: .pending,
        diagnostic: nil
    )
}

private func batchExecutorFunctionTask(
    kind: ReconstructionTaskKind,
    jobID: UUID,
    fixture: ReconstructionHeadlessTestFixture
) throws -> ReconstructionTaskRecord {
    let subject = try ReconstructionFunctionCoordinate(
        artifact: fixture.artifact,
        image: fixture.image,
        analysisFingerprintSHA256: String(repeating: "b", count: 64),
        startAddress: 0x1000,
        endAddressExclusive: 0x1008,
        boundarySchemaVersion: 1,
        functionUUIDHint: fixture.functionID,
        symbolHint: "entry"
    )
    return .init(
        identity: try .init(
            taskID: UUID(),
            jobID: jobID,
            kind: kind,
            subject: .function(subject),
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.\(kind.rawValue).v1",
            canonicalSHA256: String(repeating: "c", count: 64)
        ),
        state: .pending,
        diagnostic: nil
    )
}

private func makeExecutorNativeExecution(
    functionID: UUID
) -> NativeDecompilerValidatedExecution {
    let requestSHA256 = String(repeating: "d", count: 64)
    let image = NativeDecompilerWireImageIdentity(
        imageID: "image:fixture",
        uuid: UUID(),
        preferredLoadAddress: .init(0x1000)
    )
    let function = NativeDecompilerWireFunctionIdentity(
        functionID: functionID.uuidString.lowercased(),
        name: "entry",
        entryAddress: .init(0x1000),
        endAddressExclusive: .init(0x1008)
    )
    let success = NativeDecompilerWireSuccess(
        availability: .init(
            available: true,
            reasonCode: "available",
            runtimeIdentity: .init(
                backendID: "native-decompiler",
                engineVersion: "12.1.2",
                engineRevision: String(repeating: "1", count: 40),
                wrapperVersion: "dcp05c-v3",
                wrapperRevision: String(repeating: "2", count: 40),
                packageManifestSHA256: String(repeating: "3", count: 64),
                packageTreeSHA256: String(repeating: "4", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon",
                compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: String(repeating: "5", count: 64)
            ),
            capabilities: .init(
                nativeDecompilerHeritage: true,
                completeRegisterSSA: false,
                memorySSA: false,
                recoveredVariables: false,
                recoveredTypes: false,
                structuredControlFlow: true,
                tokenizedPseudocode: false,
                imageQualifiedSourceRanges: true
            )
        ),
        result: .init(
            requestID: UUID(),
            requestSHA256: requestSHA256,
            image: image,
            function: function,
            addressSpaces: [],
            types: [],
            instructions: [],
            varnodes: [],
            operations: [],
            blocks: [],
            edges: [],
            ssaValues: [],
            ssaBindings: [],
            phis: [],
            memoryVersions: [],
            memoryPhis: [],
            memoryEffects: [],
            variables: [],
            calls: [],
            regions: [],
            tokens: [],
            warnings: []
        )
    )
    return .init(
        requestSHA256: requestSHA256,
        analysisInputFingerprintSHA256: String(repeating: "b", count: 64),
        imageSlot: .primary,
        functionID: functionID,
        success: success,
        source: .validatedCache
    )
}

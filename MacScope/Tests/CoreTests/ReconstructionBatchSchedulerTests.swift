import XCTest

@testable import MacScope

final class ReconstructionBatchSchedulerTests: XCTestCase {
    func testCanonicalTaskOrderingIsIndependentOfInputCollectionOrder() throws {
        let jobID = batchID(1)
        let planner = ReconstructionTaskPlanner()
        let first = try batchTask(jobID: jobID, value: 1, digest: batchDigest(2))
        let second = try batchTask(jobID: jobID, value: 2, digest: batchDigest(1))

        let lhs = try planner.readyTasks(from: [first, second], jobID: jobID, maximumTasks: 2)
        let rhs = try planner.readyTasks(from: [second, first], jobID: jobID, maximumTasks: 2)

        XCTAssertEqual(lhs.map(\.identity.taskID), rhs.map(\.identity.taskID))
        XCTAssertEqual(lhs.map(\.identity.taskID), [second.identity.taskID, first.identity.taskID])
    }

    func testInteractiveAndReconstructionWorkShareFairGlobalAdmission() async throws {
        typealias Lane = FairSingleLaneWorkScheduler<String, String, String>
        let lane = Lane(maximumQueuedEntries: 8)
        let gate = BatchAsyncGate()
        let starts = BatchStartRecorder()

        let reconstructionFirst = Task {
            try await lane.submit(owner: "reconstruction-job", key: "r1") {
                await starts.record("r1")
                try await gate.wait()
                return "r1"
            }
        }
        await waitUntilBatch { await starts.values == ["r1"] }
        let reconstructionSecond = Task {
            try await lane.submit(owner: "reconstruction-job", key: "r2") {
                await starts.record("r2")
                return "r2"
            }
        }
        let interactive = Task {
            try await lane.submit(owner: "interactive-window", key: "i1") {
                await starts.record("i1")
                return "i1"
            }
        }
        await waitUntilBatch { await lane.snapshot().queuedEntryCount == 2 }

        await gate.open()
        _ = try await reconstructionFirst.value
        _ = try await interactive.value
        _ = try await reconstructionSecond.value

        let recordedStarts = await starts.values
        XCTAssertEqual(recordedStarts, ["r1", "i1", "r2"])
    }

    func testPartialFailureContinuesUnrelatedArtifactsAndProducesTerminalReceipts() async throws {
        let jobID = batchID(2)
        let authority = try batchAuthority(jobID: jobID)
        let first = try batchTask(jobID: jobID, value: 1, digest: batchDigest(1))
        let second = try batchTask(jobID: jobID, value: 2, digest: batchDigest(2))
        let executor = RecordingBatchExecutor(failingTaskID: first.identity.taskID)
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        let results = try await scheduler.executeReadyTasks(
            [second, first],
            authority: authority,
            budget: .init(maximumTasks: 2, maximumConcurrentTasks: 1)
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first(where: { $0.taskID == first.identity.taskID })?.outcome, .failed)
        XCTAssertEqual(results.first(where: { $0.taskID == second.identity.taskID })?.outcome, .completed)
        let executedTaskIDs = await executor.executedTaskIDs
        XCTAssertEqual(Set(executedTaskIDs), Set([first.identity.taskID, second.identity.taskID]))
    }

    func testIngestionStageRetainsDependencyGraphWithoutExecutingReadyIndexingWork() async throws {
        let jobID = batchID(3)
        let authority = try batchAuthority(jobID: jobID)
        let firstIngest = try batchTask(jobID: jobID, value: 1, digest: batchDigest(1))
        let completed = ReconstructionTaskRecord(
            identity: firstIngest.identity, state: .completed, diagnostic: nil
        )
        let pendingIngest = try batchTask(jobID: jobID, value: 2, digest: batchDigest(2))
        let classify = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity(
                taskID: batchID(13), jobID: jobID, kind: .classify, subject: nil,
                dependencyTaskIDs: [completed.identity.taskID],
                operationContractIdentity: "reconstruction.classify.v1",
                canonicalSHA256: batchDigest(3)
            ),
            state: .pending, diagnostic: nil
        )
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID, executor: RecordingBatchExecutor()
        )
        let graph = [classify, pendingIngest, completed]
        let ingested = try await scheduler.executeReadyTasks(
            graph, authority: authority,
            budget: .init(maximumTasks: 3, maximumConcurrentTasks: 1),
            allowedTaskKinds: [.ingest]
        )
        XCTAssertEqual(ingested.map(\.taskID), [pendingIngest.identity.taskID])
        XCTAssertEqual(ingested.map(\.outcome), [.completed])
        let indexed = try await scheduler.executeReadyTasks(
            graph.map {
                $0.identity.taskID == pendingIngest.identity.taskID
                    ? ReconstructionTaskRecord(identity: $0.identity, state: .completed, diagnostic: nil)
                    : $0
            },
            authority: authority,
            budget: .init(maximumTasks: 3, maximumConcurrentTasks: 1)
        )
        XCTAssertEqual(indexed.map(\.taskID), [classify.identity.taskID])
        XCTAssertEqual(indexed.map(\.outcome), [.completed])
    }

    func testLoadBinaryAcceptsMatchingBoundedTransientProjection() async throws {
        let jobID = batchID(6)
        let authority = try batchAuthority(jobID: jobID)
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: batchID(60)),
            contentIdentity: try .init(
                algorithm: .sha256,
                digest: batchDigest(60),
                byteCount: 4
            )
        )
        let image = ReconstructionImageBinding(
            binaryID: batchID(61),
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let task = try batchTask(
            jobID: jobID,
            value: 6,
            digest: batchDigest(6),
            kind: .loadBinary,
            subject: .artifact(artifact)
        )
        let projection = try ReconstructionTransientAnalysisProjection(
            taskID: task.identity.taskID,
            taskKind: .loadBinary,
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: batchDigest(61),
            functionCatalog: [
                .init(
                    id: batchID(62),
                    name: "entry",
                    startAddress: 0x1000,
                    endAddress: 0x1004,
                    confidence: 1
                ),
            ],
            function: nil,
            macScopePseudocode: nil
        )
        let executor = RecordingBatchExecutor(resultProjection: projection)
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        let results = try await scheduler.executeReadyTasks(
            [task],
            authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .completed)
        XCTAssertEqual(results[0].analysisProjection, projection)
        XCTAssertEqual(results[0].analysisProjection?.functionCatalog.map(\.name), ["entry"])
        XCTAssertNil(results[0].nativeResult)
    }

    func testFunctionProjectionAcceptsStructuralReboundIDWithNilHint() async throws {
        let jobID = batchID(7)
        let authority = try batchAuthority(jobID: jobID)
        let artifact = try batchArtifact(value: 70)
        let image = batchImage(value: 71)
        let coordinate = try batchFunctionCoordinate(
            artifact: artifact,
            image: image,
            fingerprint: batchDigest(72),
            functionUUIDHint: nil
        )
        let task = try batchTask(
            jobID: jobID,
            value: 7,
            digest: batchDigest(7),
            kind: .decompileMacScope,
            subject: .function(coordinate)
        )
        let projection = try batchFunctionProjection(
            task: task,
            coordinate: coordinate
        )
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: RecordingBatchExecutor(resultProjection: projection)
        )

        let results = try await scheduler.executeReadyTasks(
            [task],
            authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )

        XCTAssertNil(coordinate.functionUUIDHint)
        XCTAssertEqual(results.map(\.outcome), [.completed])
        XCTAssertEqual(results.first?.analysisProjection, projection)
        XCTAssertEqual(
            results.first?.analysisProjection?.function?.id,
            ReconstructionStableImageAuthority.stableFunctionID(
                image: image,
                analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
                startAddress: coordinate.startAddress,
                endAddressExclusive: coordinate.endAddressExclusive,
                boundarySchemaVersion: coordinate.boundarySchemaVersion
            )
        )
    }

    func testFunctionProjectionRejectsImageFingerprintRangeBoundaryAndIDDrift() async throws {
        let jobID = batchID(8)
        let authority = try batchAuthority(jobID: jobID)
        let artifact = try batchArtifact(value: 80)
        let image = batchImage(value: 81)
        let coordinate = try batchFunctionCoordinate(
            artifact: artifact,
            image: image,
            fingerprint: batchDigest(82),
            functionUUIDHint: batchID(899)
        )
        let baseTask = try batchTask(
            jobID: jobID,
            value: 8,
            digest: batchDigest(8),
            kind: .decompileMacScope,
            subject: .function(coordinate)
        )
        let foreignImage = batchImage(value: 83)
        let driftedBoundary = try batchFunctionCoordinate(
            artifact: artifact,
            image: image,
            fingerprint: coordinate.analysisFingerprintSHA256,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion + 1,
            functionUUIDHint: coordinate.functionUUIDHint
        )
        let boundaryTask = try batchTask(
            jobID: jobID,
            value: 9,
            digest: batchDigest(9),
            kind: .decompileMacScope,
            subject: .function(driftedBoundary)
        )
        let projections = [
            try batchFunctionProjection(
                task: baseTask,
                coordinate: coordinate,
                image: foreignImage
            ),
            try batchFunctionProjection(
                task: baseTask,
                coordinate: coordinate,
                fingerprint: batchDigest(84)
            ),
            try batchFunctionProjection(
                task: baseTask,
                coordinate: coordinate,
                startAddress: coordinate.startAddress + 4,
                endAddress: coordinate.endAddressExclusive + 4
            ),
            try batchFunctionProjection(
                task: baseTask,
                coordinate: coordinate,
                functionID: batchID(898)
            ),
        ]

        for projection in projections {
            let scheduler = ReconstructionBatchScheduler(
                durableJobID: jobID,
                executor: RecordingBatchExecutor(resultProjection: projection)
            )
            let results = try await scheduler.executeReadyTasks(
                [baseTask],
                authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTAssertEqual(results.map(\.outcome), [.staleAuthority])
            XCTAssertNil(results.first?.analysisProjection)
        }

        let boundaryProjection = try batchFunctionProjection(
            task: boundaryTask,
            coordinate: driftedBoundary,
            functionID: ReconstructionStableImageAuthority.stableFunctionID(
                image: driftedBoundary.image,
                analysisFingerprintSHA256: driftedBoundary.analysisFingerprintSHA256,
                startAddress: driftedBoundary.startAddress,
                endAddressExclusive: driftedBoundary.endAddressExclusive,
                boundarySchemaVersion: driftedBoundary.boundarySchemaVersion
            )
        )
        let boundaryScheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: RecordingBatchExecutor(resultProjection: boundaryProjection)
        )
        let boundaryResults = try await boundaryScheduler.executeReadyTasks(
            [boundaryTask],
            authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )
        XCTAssertEqual(boundaryResults.map(\.outcome), [.staleAuthority])
    }

    func testPauseCancelSettlesActiveWorkAndRejectsLateRevisionMismatchedResults() async throws {
        let jobID = batchID(3)
        let authority = try batchAuthority(jobID: jobID)
        let task = try batchTask(jobID: jobID, value: 1, digest: batchDigest(1))
        let executor = RecordingBatchExecutor(
            resultRevision: authority.checkpointRevision + 1,
            gate: BatchAsyncGate()
        )
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        let active = Task {
            try await scheduler.executeReadyTasks(
                [task], authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
        }
        await waitUntilBatch { await executor.executedTaskIDs.count == 1 }
        await scheduler.pause(jobID: jobID)
        await executor.openGate()
        let stale = try await active.value
        XCTAssertEqual(stale.map(\.outcome), [.staleAuthority])

        do {
            _ = try await scheduler.executeReadyTasks(
                [task], authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTFail("paused work must require explicit resume")
        } catch let error as ReconstructionBatchSchedulerError {
            XCTAssertEqual(error, .jobPaused(jobID))
        }

        await scheduler.resume(jobID: jobID)
        let afterResume = try await scheduler.executeReadyTasks(
            [task], authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )
        XCTAssertEqual(afterResume.map(\.outcome), [.staleAuthority])

        await scheduler.retire(jobID: jobID)
        await scheduler.retire(jobID: jobID)
        do {
            _ = try await scheduler.executeReadyTasks(
                [task], authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTFail("retired work must fail closed")
        } catch let error as ReconstructionBatchSchedulerError {
            XCTAssertEqual(error, .jobRetired(jobID))
        }

        let cancelCount = await executor.cancelCount
        let resumeCount = await executor.resumeCount
        let retireCount = await executor.retireCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(retireCount, 1)
    }

    func testExecutesOnlyClosedBatchDomainAndLeavesReadModelAndCheckpointTasksUntouched() async throws {
        let jobID = batchID(4)
        let authority = try batchAuthority(jobID: jobID)
        let batch = try batchTask(
            jobID: jobID,
            value: 1,
            digest: batchDigest(1),
            kind: .ingest
        )
        let read = try batchTask(
            jobID: jobID,
            value: 2,
            digest: batchDigest(2),
            kind: .retrieveEvidence
        )
        let model = try batchTask(
            jobID: jobID,
            value: 3,
            digest: batchDigest(3),
            kind: .modelRound
        )
        let checkpoint = try batchTask(
            jobID: jobID,
            value: 4,
            digest: batchDigest(4),
            kind: .checkpoint
        )
        let executor = RecordingBatchExecutor()
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        let results = try await scheduler.executeReadyTasks(
            [checkpoint, model, read, batch],
            authority: authority,
            budget: .init(maximumTasks: 4, maximumConcurrentTasks: 4)
        )

        XCTAssertEqual(results.map(\.taskID), [batch.identity.taskID])
        let executed = await executor.executedTaskIDs
        XCTAssertEqual(executed, [batch.identity.taskID])
    }

    func testForeignDurableJobResultIsStaleEvenWhenEveryOtherFenceMatches() async throws {
        let jobID = batchID(5)
        let authority = try batchAuthority(jobID: jobID)
        let task = try batchTask(jobID: jobID, value: 1, digest: batchDigest(1))
        let executor = RecordingBatchExecutor(resultJobID: batchID(999))
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        let results = try await scheduler.executeReadyTasks(
            [task],
            authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].jobID, jobID)
        XCTAssertEqual(results[0].taskID, task.identity.taskID)
        XCTAssertEqual(results[0].outcome, .staleAuthority)
        XCTAssertNil(results[0].analysisProjection)
        XCTAssertNil(results[0].nativeResult)
    }
}

private actor RecordingBatchExecutor: ReconstructionBatchTaskExecuting {
    private let failingTaskID: UUID?
    private let resultRevision: UInt64?
    private let resultJobID: UUID?
    private let resultProjection: ReconstructionTransientAnalysisProjection?
    private let gate: BatchAsyncGate?
    private(set) var executedTaskIDs: [UUID] = []
    private(set) var cancelCount = 0
    private(set) var resumeCount = 0
    private(set) var retireCount = 0

    init(
        failingTaskID: UUID? = nil,
        resultRevision: UInt64? = nil,
        resultJobID: UUID? = nil,
        resultProjection: ReconstructionTransientAnalysisProjection? = nil,
        gate: BatchAsyncGate? = nil
    ) {
        self.failingTaskID = failingTaskID
        self.resultRevision = resultRevision
        self.resultJobID = resultJobID
        self.resultProjection = resultProjection
        self.gate = gate
    }

    func execute(
        task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionTerminalTaskResult {
        executedTaskIDs.append(task.identity.taskID)
        if let gate { await gate.waitIgnoringCancellation() }
        return .init(
            jobID: resultJobID ?? authority.jobID,
            taskID: task.identity.taskID,
            checkpointID: authority.checkpointID,
            checkpointRevision: resultRevision ?? authority.checkpointRevision,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: task.identity.taskID == failingTaskID ? .failed : .completed,
            analysisProjection: resultProjection
        )
    }

    func pause() async { cancelCount += 1 }
    func resume() async { resumeCount += 1 }
    func retire() async { retireCount += 1 }
    func openGate() async { await gate?.open() }
}

private actor BatchAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        try Task.checkCancellation()
        await waitIgnoringCancellation()
        try Task.checkCancellation()
    }

    func waitIgnoringCancellation() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor BatchStartRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private func waitUntilBatch(
    _ predicate: @Sendable @escaping () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200_000 {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("batch condition did not settle", file: file, line: line)
}

private func batchAuthority(jobID: UUID) throws -> ReconstructionBatchAuthority {
    try .init(
        jobID: jobID,
        checkpointID: batchID(90),
        checkpointRevision: 7,
        corpusManifestSHA256: batchDigest(9)
    )
}

private func batchTask(
    jobID: UUID,
    value: Int,
    digest: String,
    kind: ReconstructionTaskKind = .ingest,
    subject: ReconstructionSubjectCoordinate? = nil
) throws -> ReconstructionTaskRecord {
    .init(
        identity: try .init(
            taskID: batchID(value + 10),
            jobID: jobID,
            kind: kind,
            subject: subject,
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.\(kind.rawValue).v1",
            canonicalSHA256: digest
        ),
        state: .pending,
        diagnostic: nil
    )
}

private func batchID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "90000000-0000-4000-8000-%012d", value))!
}

private func batchDigest(_ value: Int) -> String { String(format: "%064x", value) }

private func batchArtifact(value: Int) throws -> ReconstructionArtifactCoordinate {
    .init(
        occurrenceID: .init(rawValue: batchID(value)),
        contentIdentity: try .init(
            algorithm: .sha256,
            digest: batchDigest(value),
            byteCount: 8
        )
    )
}

private func batchImage(value: Int) -> ReconstructionImageBinding {
    .init(
        binaryID: batchID(value),
        imageSlot: .primary,
        selectedSliceIndex: nil,
        architecture: .arm64,
        machOIdentity: nil
    )
}

private func batchFunctionCoordinate(
    artifact: ReconstructionArtifactCoordinate,
    image: ReconstructionImageBinding,
    fingerprint: String,
    boundarySchemaVersion: Int = ReconstructionFunctionCoordinate.schemaVersion,
    functionUUIDHint: UUID?
) throws -> ReconstructionFunctionCoordinate {
    try .init(
        artifact: artifact,
        image: image,
        analysisFingerprintSHA256: fingerprint,
        startAddress: 0x1000,
        endAddressExclusive: 0x1008,
        boundarySchemaVersion: boundarySchemaVersion,
        functionUUIDHint: functionUUIDHint,
        symbolHint: "entry"
    )
}

private func batchFunctionProjection(
    task: ReconstructionTaskRecord,
    coordinate: ReconstructionFunctionCoordinate,
    image: ReconstructionImageBinding? = nil,
    fingerprint: String? = nil,
    functionID: UUID? = nil,
    startAddress: UInt64? = nil,
    endAddress: UInt64? = nil
) throws -> ReconstructionTransientAnalysisProjection {
    let projectedImage = image ?? coordinate.image
    let projectedFingerprint = fingerprint ?? coordinate.analysisFingerprintSHA256
    let projectedFunctionID = functionID
        ?? ReconstructionStableImageAuthority.stableFunctionID(
            image: coordinate.image,
            analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
            startAddress: coordinate.startAddress,
            endAddressExclusive: coordinate.endAddressExclusive,
            boundarySchemaVersion: coordinate.boundarySchemaVersion
        )
    return try .init(
        taskID: task.identity.taskID,
        taskKind: task.identity.kind,
        artifact: coordinate.artifact,
        image: projectedImage,
        analysisFingerprintSHA256: projectedFingerprint,
        functionCatalog: [],
        function: .init(
            id: projectedFunctionID,
            name: "entry",
            startAddress: startAddress ?? coordinate.startAddress,
            endAddress: endAddress ?? coordinate.endAddressExclusive,
            confidence: 1
        ),
        macScopePseudocode: "void entry(void) {}"
    )
}

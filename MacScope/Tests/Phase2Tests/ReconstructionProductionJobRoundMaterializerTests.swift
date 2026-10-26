import XCTest

@testable import MacScope

final class ReconstructionProductionJobRoundMaterializerTests: XCTestCase {
    func testRejectsCutWhoseCommittedAuthorityIsStale() throws {
        let snapshot = productionMaterializerSnapshot()
        let stale = snapshot.withCurrentAuthority(
            corpusManifestSHA256: String(repeating: "e", count: 64),
            evidenceFrontierSHA256: snapshot.evidenceFrontierSHA256
        )

        XCTAssertThrowsError(try ReconstructionProductionJobRoundMaterializer
            .validateCommittedAuthority(stale, against: snapshot)) { error in
                XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .malformedOutput)
            }
    }

    func testRejectsPlanWithoutDurableMutation() throws {
        let snapshot = productionMaterializerSnapshot()
        let inert = ReconstructionJobCommitPlan(
            successorRevision: snapshot.checkpointRevision + 1,
            acceptedEvidenceCount: 0,
            disposition: .continue,
            mutation: nil
        )

        XCTAssertThrowsError(try ReconstructionProductionJobRoundMaterializer
            .validateDurablePlan(inert, against: snapshot)) { error in
                XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .invalidCommitPlan)
            }
    }

    func testPrepareAndEveryPlanPathUseImmutableCutAndReturnDurableMutations() async throws {
        let fixture = try ProductionMaterializerFixture()
        let provider = RecordingCommittedCutProvider(cut: fixture.modelCut)
        let builder = RecordingRoundPlanBuilder()
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: provider,
            planBuilder: builder
        )

        var prepared = try preparedModel(
            await materializer.prepare(snapshot: fixture.snapshot)
        )
        _ = try await materializer.makeCommitPlan(
            snapshot: fixture.snapshot,
            prepared: prepared,
            lease: fixture.lease,
            requestAuthority: fixture.roundRequestAuthority,
            inference: fixture.inference,
            executions: []
        )
        prepared = try preparedModel(
            await materializer.prepare(snapshot: fixture.snapshot)
        )
        _ = try await materializer.makeFailedModelPlan(
            snapshot: fixture.snapshot,
            prepared: prepared,
            lease: fixture.lease,
            requestAuthority: fixture.roundRequestAuthority,
            reason: .modelUnavailable
        )
        prepared = try preparedModel(
            await materializer.prepare(snapshot: fixture.snapshot)
        )
        let final = try await materializer.makeFinalCommitPlan(
            snapshot: fixture.snapshot,
            prepared: prepared,
            lease: fixture.lease,
            requestAuthority: fixture.finalRequestAuthority,
            synthesis: fixture.synthesis
        )
        let recovery = try await materializer.makeRecoveryPlan(
            snapshot: fixture.snapshot,
            transitions: [fixture.transition]
        )
        let control = try await materializer.makeControlPlan(
            snapshot: fixture.snapshot,
            reason: .pausedByUser
        )

        XCTAssertEqual(final.disposition, .completed)
        XCTAssertEqual(recovery.disposition, .continue)
        XCTAssertEqual(control.disposition, .paused(.pausedByUser))
        XCTAssertNotNil(final.mutation)
        XCTAssertNotNil(recovery.mutation)
        XCTAssertNotNil(control.mutation)
        let captureCount = await provider.captureCount()
        let calls = await builder.calls()
        let batchCounts = await builder.observedBatchResultCounts()
        let observedLeases = await builder.observedLeases()
        XCTAssertEqual(captureCount, 5)
        XCTAssertEqual(
            calls,
            [.preInference, .normal, .preInference, .failed, .preInference, .final,
             .recovery, .control]
        )
        XCTAssertEqual(batchCounts, Array(repeating: 0, count: 8))
        XCTAssertEqual(observedLeases, [fixture.lease, fixture.lease, fixture.lease])
    }

    func testPrepareReturnsDirectCommitForDeterministicBatchProgress() async throws {
        let fixture = try ProductionMaterializerFixture()
        let builder = RecordingRoundPlanBuilder(commitPreInference: true)
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: RecordingCommittedCutProvider(cut: fixture.cut),
            planBuilder: builder
        )

        let preparation = try await materializer.prepare(snapshot: fixture.snapshot)

        guard case .commit(let plan) = preparation else {
            return XCTFail("Batch terminal progress must commit before model inference")
        }
        XCTAssertEqual(plan.disposition, .continue)
        XCTAssertNotNil(plan.mutation)
        let calls = await builder.calls()
        let batchResultCounts = await builder.observedBatchResultCounts()
        XCTAssertEqual(calls, [.preInference])
        XCTAssertEqual(batchResultCounts, [1])
    }

    func testPrepareRejectsModelBranchWhileBatchProgressRemainsUncommitted() async throws {
        let fixture = try ProductionMaterializerFixture()
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: RecordingCommittedCutProvider(cut: fixture.cut),
            planBuilder: RecordingRoundPlanBuilder()
        )

        do {
            _ = try await materializer.prepare(snapshot: fixture.snapshot)
            XCTFail("Uncommitted batch results must never cross into model inference")
        } catch {
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .invalidCommitPlan)
        }
    }

    func testPrepareDiscardsBuilderAuthorityWhenCapturedCutFailsValidation() async throws {
        let fixture = try ProductionMaterializerFixture()
        let staleRequest = fixture.snapshot.withCurrentAuthority(
            corpusManifestSHA256: String(repeating: "e", count: 64),
            evidenceFrontierSHA256: fixture.snapshot.evidenceFrontierSHA256
        )
        let builder = RecordingRoundPlanBuilder()
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: RecordingCommittedCutProvider(cut: fixture.modelCut),
            planBuilder: builder
        )

        do {
            _ = try await materializer.prepare(snapshot: staleRequest)
            XCTFail("Expected stale captured authority to be rejected")
        } catch {
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .malformedOutput)
        }
        let discardedRoundIDs = await builder.discardedRoundIDs()
        XCTAssertEqual(discardedRoundIDs, [fixture.modelCut.prepared.roundID])
    }

    func testDiscardedPreparedRoundCanBeRetriedAtTheSameDurableCut() async throws {
        let fixture = try ProductionMaterializerFixture()
        let builder = RecordingRoundPlanBuilder()
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: RecordingCommittedCutProvider(cut: fixture.modelCut),
            planBuilder: builder
        )
        let first = try preparedModel(
            await materializer.prepare(snapshot: fixture.snapshot)
        )

        await materializer.discardPreparedRound(
            snapshot: fixture.snapshot,
            prepared: first
        )

        let retried = try preparedModel(
            await materializer.prepare(snapshot: fixture.snapshot)
        )
        XCTAssertEqual(retried.roundID, first.roundID)
        let discardedRoundIDs = await builder.discardedRoundIDs()
        XCTAssertEqual(discardedRoundIDs, [first.roundID])
    }

    func testPrepareRejectsTerminalResultFromDifferentJob() async throws {
        let fixture = try ProductionMaterializerFixture()
        let result = try XCTUnwrap(fixture.cut.batchTerminalResults.first)
        let foreignResult = ReconstructionTerminalTaskResult(
            jobID: UUID(uuidString: "b0000000-0000-0000-0000-00000000000b")!,
            taskID: result.taskID,
            checkpointID: result.checkpointID,
            checkpointRevision: result.checkpointRevision,
            corpusManifestSHA256: result.corpusManifestSHA256,
            outcome: result.outcome
        )
        let foreignCut = ReconstructionProductionCommittedRoundCut(
            snapshot: fixture.cut.snapshot,
            parentCheckpointID: fixture.cut.parentCheckpointID,
            parentCheckpointSHA256: fixture.cut.parentCheckpointSHA256,
            prepared: fixture.cut.prepared,
            batchTerminalResults: [foreignResult]
        )
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: RecordingCommittedCutProvider(cut: foreignCut),
            planBuilder: RecordingRoundPlanBuilder()
        )

        do {
            _ = try await materializer.prepare(snapshot: fixture.snapshot)
            XCTFail("expected a foreign-job terminal result to be rejected")
        } catch {
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .malformedOutput)
        }
    }

    func testDynamicTasksRejectHiddenOrCrossJobAuthority() throws {
        let snapshot = productionMaterializerSnapshot()
        let crossJob = try productionTask(
            jobID: UUID(),
            taskID: UUID(),
            dependencyTaskIDs: []
        )
        XCTAssertThrowsError(try ReconstructionProductionJobRoundMaterializer
            .validateNewTasks([crossJob], against: snapshot))

        let unknownDependency = try productionTask(
            jobID: snapshot.jobID,
            taskID: UUID(),
            dependencyTaskIDs: [UUID()]
        )
        XCTAssertThrowsError(try ReconstructionProductionJobRoundMaterializer
            .validateNewTasks([unknownDependency], against: snapshot))
    }

    func testEveryDispositionBindsTheExactDurableCheckpointAuthority() throws {
        let fixture = try ProductionMaterializerFixture()
        let dispositions: [ReconstructionJobCoordinatorDisposition] = [
            .continue,
            .completed,
            .paused(.pausedByUser),
            .paused(.modelUnavailable),
            .paused(.inferenceBusy),
            .paused(.frontierMismatch),
            .paused(.evidenceStalled),
            .cancelled,
            .failed,
        ]

        for disposition in dispositions {
            let plan = try productionPlan(cut: fixture.cut, disposition: disposition)
            XCTAssertNoThrow(
                try ReconstructionProductionJobRoundMaterializer.validateDurablePlan(
                    plan,
                    against: fixture.snapshot
                ),
                "Valid durable authority was rejected for \(disposition)"
            )
        }
    }

    func testExplicitPhaseRejectsIllegalHopsAndLegalHopWithoutItsTaskFrontier() throws {
        let fixture = try ProductionMaterializerFixture()
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: productionDigest("a"), byteCount: 8)
        )
        var tasks: [ReconstructionTaskRecord] = []
        for kind in [ReconstructionTaskKind.ingest, .classify, .discoverRelations] {
            tasks.append(ReconstructionTaskRecord(
                identity: try .make(
                    taskID: UUID(), jobID: fixture.snapshot.jobID, kind: kind,
                    subject: .artifact(artifact),
                    dependencyTaskIDs: tasks.last.map { [$0.identity.taskID] } ?? [],
                    operationContractIdentity: "reconstruction.\(kind.rawValue).v1"
                ),
                state: .pending, diagnostic: nil
            ))
        }
        try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            tasks, jobID: fixture.snapshot.jobID, maximumTasks: 3
        )
        let snapshot = try replacingSnapshotDurableAuthority(
            fixture.snapshot, state: .retrieving, pauseContext: nil, tasks: tasks
        )
        let cut = ReconstructionProductionCommittedRoundCut(
            snapshot: snapshot, parentCheckpointID: fixture.cut.parentCheckpointID,
            parentCheckpointSHA256: fixture.cut.parentCheckpointSHA256,
            prepared: fixture.cut.prepared, batchTerminalResults: []
        )
        for phase in [ReconstructionJobState.indexing, .awaitingModel, .acceptingEvidence,
                      .completed, .retrieving] {
            let plan = try productionPlan(cut: cut, disposition: .advancePhase(phase))
            assertInvalidDurablePlan(plan, snapshot: snapshot)
        }
        // Existing continue still cannot disguise a legal forward hop as same-state progress.
        let sameState = try productionPlan(cut: cut, disposition: .continue)
        XCTAssertNoThrow(try ReconstructionProductionJobRoundMaterializer.validateDurablePlan(
            sameState, against: snapshot
        ))
        let disguised = try replacingDurableAuthority(
            sameState, coordinatorState: .awaitingModel, terminalReason: nil, pauseContext: nil
        )
        assertInvalidDurablePlan(disguised, snapshot: snapshot)
    }

    func testPausedSnapshotMayCancelOrFailButCannotComplete() throws {
        let fixture = try ProductionMaterializerFixture()
        let pausedSnapshot = try replacingSnapshotDurableAuthority(
            fixture.snapshot,
            state: .paused,
            pauseContext: ReconstructionJobPauseContext(
                cause: .pausedByUser,
                resumeTarget: .retrieving
            )
        )
        let pausedCut = ReconstructionProductionCommittedRoundCut(
            snapshot: pausedSnapshot,
            parentCheckpointID: fixture.cut.parentCheckpointID,
            parentCheckpointSHA256: fixture.cut.parentCheckpointSHA256,
            prepared: fixture.cut.prepared,
            batchTerminalResults: fixture.cut.batchTerminalResults
        )

        for disposition in [
            ReconstructionJobCoordinatorDisposition.cancelled,
            .failed,
        ] {
            XCTAssertNoThrow(try ReconstructionProductionJobRoundMaterializer.validateDurablePlan(
                productionPlan(cut: pausedCut, disposition: disposition),
                against: pausedSnapshot
            ))
        }
        assertInvalidDurablePlan(
            try productionPlan(cut: pausedCut, disposition: .completed),
            snapshot: pausedSnapshot
        )
    }

    func testDispositionValidationRejectsEachOneAxisAuthorityDrift() throws {
        let fixture = try ProductionMaterializerFixture()
        let validPause = try productionPlan(
            cut: fixture.cut,
            disposition: .paused(.modelUnavailable)
        )
        let pauseMutation = try XCTUnwrap(validPause.mutation)
        let pauseContext = try XCTUnwrap(pauseMutation.successorPauseContext)
        let pauseCheckpoint = pauseMutation.successorCheckpoint
        XCTAssertNoThrow(try ReconstructionProductionJobRoundMaterializer.validateDurablePlan(
            validPause,
            against: fixture.snapshot
        ))

        let pauseDrifts = try [
            replacingDurableAuthority(
                validPause,
                coordinatorState: .retrieving,
                terminalReason: pauseCheckpoint.terminalReason,
                pauseContext: pauseContext
            ),
            replacingDurableAuthority(
                validPause,
                coordinatorState: pauseCheckpoint.coordinatorState,
                terminalReason: pauseCheckpoint.terminalReason,
                pauseContext: nil
            ),
            replacingDurableAuthority(
                validPause,
                coordinatorState: pauseCheckpoint.coordinatorState,
                terminalReason: pauseCheckpoint.terminalReason,
                pauseContext: ReconstructionJobPauseContext(
                    cause: .inferenceBusy,
                    resumeTarget: pauseContext.resumeTarget
                )
            ),
            replacingDurableAuthority(
                validPause,
                coordinatorState: pauseCheckpoint.coordinatorState,
                terminalReason: pauseCheckpoint.terminalReason,
                pauseContext: ReconstructionJobPauseContext(
                    cause: pauseContext.cause,
                    resumeTarget: .awaitingModel
                )
            ),
            replacingDurableAuthority(
                validPause,
                coordinatorState: pauseCheckpoint.coordinatorState,
                terminalReason: .sanitizing("Pause must not carry a terminal diagnostic."),
                pauseContext: pauseContext
            ),
        ]
        for drift in pauseDrifts {
            assertInvalidDurablePlan(drift, snapshot: fixture.snapshot)
        }

        for disposition in [
            ReconstructionJobCoordinatorDisposition.cancelled,
            .failed,
        ] {
            let validTerminal = try productionPlan(cut: fixture.cut, disposition: disposition)
            let terminalMutation = try XCTUnwrap(validTerminal.mutation)
            let terminalCheckpoint = terminalMutation.successorCheckpoint
            XCTAssertNoThrow(try ReconstructionProductionJobRoundMaterializer.validateDurablePlan(
                validTerminal,
                against: fixture.snapshot
            ))
            assertInvalidDurablePlan(
                try replacingDurableAuthority(
                    validTerminal,
                    coordinatorState: terminalCheckpoint.coordinatorState,
                    terminalReason: nil,
                    pauseContext: nil
                ),
                snapshot: fixture.snapshot
            )
            assertInvalidDurablePlan(
                try replacingDurableAuthority(
                    validTerminal,
                    coordinatorState: terminalCheckpoint.coordinatorState,
                    terminalReason: terminalCheckpoint.terminalReason,
                    pauseContext: ReconstructionJobPauseContext(
                        cause: .pausedByUser,
                        resumeTarget: .retrieving
                    )
                ),
                snapshot: fixture.snapshot
            )
            assertInvalidDurablePlan(
                try replacingDurableAuthority(
                    validTerminal,
                    coordinatorState: .paused,
                    terminalReason: terminalCheckpoint.terminalReason,
                    pauseContext: nil
                ),
                snapshot: fixture.snapshot
            )
        }
    }

    func testFailedModelDispositionMappingIsExhaustiveAndFailClosed() throws {
        XCTAssertEqual(
            try ReconstructionProductionJobRoundMaterializer.failedModelDisposition(
                for: .retryableProviderFailure("overallDeadlineExceeded")
            ), .paused(.modelUnavailable)
        )
        XCTAssertEqual(
            try ReconstructionProductionJobRoundMaterializer.failedModelDisposition(
                for: .modelUnavailable
            ),
            .paused(.modelUnavailable)
        )
        XCTAssertEqual(
            try ReconstructionProductionJobRoundMaterializer.failedModelDisposition(
                for: .inferenceBusy
            ),
            .paused(.inferenceBusy)
        )
        XCTAssertEqual(
            try ReconstructionProductionJobRoundMaterializer.failedModelDisposition(
                for: .malformedOutput
            ),
            .failed
        )
        for rejected in [
            ReconstructionJobCoordinatorFailure.invalidCommitPlan,
            .jobNotFound,
            .checkpointConflict,
        ] {
            XCTAssertThrowsError(
                try ReconstructionProductionJobRoundMaterializer.failedModelDisposition(
                    for: rejected
                )
            ) { error in
                XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .invalidCommitPlan)
            }
        }
    }

    func testControlReasonMappingSeparatesFivePausesFromTwoTerminalResults() {
        let expected: [ReconstructionJobPauseReason: (
            disposition: ReconstructionJobCoordinatorDisposition,
            cause: ReconstructionJobPauseCause?
        )] = [
            .pausedByUser: (.paused(.pausedByUser), .pausedByUser),
            .modelUnavailable: (.paused(.modelUnavailable), .modelUnavailable),
            .inferenceBusy: (.paused(.inferenceBusy), .inferenceBusy),
            .frontierMismatch: (.paused(.frontierMismatch), .frontierMismatch),
            .evidenceStalled: (.paused(.evidenceStalled), .evidenceStalled),
            .cancelled: (.cancelled, nil),
            .failed: (.failed, nil),
        ]

        XCTAssertEqual(expected.count, 7)
        for (reason, authority) in expected {
            XCTAssertEqual(
                reason.controlDisposition,
                authority.disposition,
                "Control drift for \(reason)"
            )
            XCTAssertEqual(
                reason.durablePauseCause,
                authority.cause,
                "Pause-cause drift for \(reason)"
            )
        }
    }
}

private enum MaterializerCall: Equatable, Sendable {
    case preInference, normal, failed, final, recovery, control
}

private actor RecordingCommittedCutProvider: ReconstructionProductionCommittedRoundCutProviding {
    private let cut: ReconstructionProductionCommittedRoundCut
    private var count = 0
    init(cut: ReconstructionProductionCommittedRoundCut) { self.cut = cut }
    func capture(snapshot: ReconstructionJobOrchestrationSnapshot) async throws
        -> ReconstructionProductionCommittedRoundCut {
        count += 1
        return cut
    }
    func captureCount() -> Int { count }
}

private actor RecordingRoundPlanBuilder: ReconstructionProductionRoundPlanBuilding {
    private let commitPreInference: Bool
    private var recordedCalls: [MaterializerCall] = []
    private var batchCounts: [Int] = []
    private var leases: [Phase2ReadyInferenceLease] = []
    private var discardedRounds: [UUID] = []

    init(commitPreInference: Bool = false) {
        self.commitPreInference = commitPreInference
    }

    func makePreInferenceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut
    ) async throws -> ReconstructionJobCommitPlan? {
        record(.preInference, cut)
        return commitPreInference
            ? try productionPlan(cut: cut, disposition: .continue)
            : nil
    }

    func makeCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan {
        record(.normal, cut)
        leases.append(lease)
        return try productionPlan(cut: cut, disposition: .continue)
    }
    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        record(.failed, cut)
        leases.append(lease)
        return try productionPlan(
            cut: cut,
            disposition: ReconstructionProductionJobRoundMaterializer.failedModelDisposition(
                for: reason
            )
        )
    }
    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        record(.final, cut)
        leases.append(lease)
        return try productionPlan(cut: cut, disposition: .completed)
    }
    func makeRecoveryPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        record(.recovery, cut)
        return try productionPlan(cut: cut, disposition: .continue)
    }
    func makeControlPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        record(.control, cut)
        return try productionPlan(cut: cut, disposition: reason.controlDisposition)
    }
    func discardPreparedRound(
        cut: ReconstructionProductionCommittedRoundCut
    ) async {
        discardedRounds.append(cut.prepared.roundID)
    }
    func calls() -> [MaterializerCall] { recordedCalls }
    func observedBatchResultCounts() -> [Int] { batchCounts }
    func observedLeases() -> [Phase2ReadyInferenceLease] { leases }
    func discardedRoundIDs() -> [UUID] { discardedRounds }
    private func record(_ call: MaterializerCall, _ cut: ReconstructionProductionCommittedRoundCut) {
        recordedCalls.append(call)
        batchCounts.append(cut.batchTerminalResults.count)
    }
}

private struct ProductionMaterializerFixture {
    let snapshot: ReconstructionJobOrchestrationSnapshot
    let cut: ReconstructionProductionCommittedRoundCut
    let modelCut: ReconstructionProductionCommittedRoundCut
    let lease: Phase2ReadyInferenceLease
    let inference: ReconstructionInferenceExecutionResult
    let roundRequestAuthority: ReconstructionModelTerminalRequestAuthority
    let synthesis: ReconstructionFinalSynthesisExecutionResult
    let finalRequestAuthority: ReconstructionModelTerminalRequestAuthority
    let transition: ReconstructionTaskTransition

    init() throws {
        let jobID = UUID(uuidString: "a0000000-0000-0000-0000-00000000000a")!
        let task = try productionTask(jobID: jobID, taskID: UUID(), dependencyTaskIDs: [])
        let manifestDraft = try ReconstructionCorpusManifest(
            reconstructionProjectID: UUID(), artifacts: [], relations: [],
            canonicalSHA256: productionDigest("1")
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: manifestDraft.reconstructionProjectID,
            artifacts: [], relations: [],
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: manifestDraft)
        )
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [], projectedClassificationsByEvidenceID: [:], relations: [], gaps: [],
            checkpointRevisionsByID: [:]
        )
        let evidenceCut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [], relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: [:], checkpointRevisionsByID: [:]
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: jobID, jobCreationOrder: 1, checkpointID: UUID(), checkpointRevision: 4,
            checkpointCorpusManifestSHA256: manifest.canonicalSHA256,
            checkpointEvidenceFrontierSHA256: frontier,
            currentCorpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier,
            currentDurableJobState: .retrieving,
            pauseContext: nil,
            maximumRoundsWithoutEvidence: 3,
            tasks: [task], terminalReceiptStatesByTaskID: [:]
        )
        let roundID = UUID()
        let projection = try ReconstructionToolProjectorInput.canonicalProjectionFrontierSHA256(
            projectedItemsByOperation: [:], staleOperations: [], tasks: [task], receipts: [],
            producersByOperation: [:], evidenceAuthorityCutsByOperation: [:]
        )
        let authority = try ReconstructionToolAuthorityCut(
            jobID: jobID, checkpointRevision: 4, roundID: roundID,
            corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, projectionFrontierSHA256: projection
        )
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: manifest.canonicalSHA256, subject: nil,
            operationIDs: [.corpusSummary], classifications: [.acceptedCurrent], cursor: nil,
            maximumRecords: 1, maximumEncodedBytes: 4_096
        )
        let projector = try ReconstructionToolProjectorInput(
            authority: authority, corpusManifest: manifest, evidenceCut: evidenceCut,
            tasks: [task], receipts: [], producersByOperation: [:],
            projectedItemsByOperation: [:], staleOperations: [], evidenceAuthorityCutsByOperation: [:]
        )
        let prepared = ReconstructionPreparedModelRound(
            roundID: roundID, evidenceCut: evidenceCut, retrievalQuery: query,
            allowedGapSubjects: [], allowedGapCategories: [], authority: authority,
            requests: [], projectorInput: projector
        )
        let checkpointID = UUID()
        self.snapshot = snapshot
        self.cut = .init(
            snapshot: snapshot, parentCheckpointID: checkpointID,
            parentCheckpointSHA256: productionDigest("2"), prepared: prepared,
            batchTerminalResults: [.init(
                jobID: jobID,
                taskID: task.identity.taskID, checkpointID: checkpointID,
                checkpointRevision: 4, corpusManifestSHA256: manifest.canonicalSHA256,
                outcome: .completed
            )]
        )
        self.modelCut = .init(
            snapshot: snapshot,
            parentCheckpointID: checkpointID,
            parentCheckpointSHA256: productionDigest("2"),
            prepared: prepared,
            batchTerminalResults: []
        )
        self.lease = Phase2ReadyInferenceLease(
            providerRevision: 9,
            configuration: try Phase2AIProviderConfiguration(
                profileID: UUID(uuidString: "a1000000-0000-0000-0000-00000000000a")!,
                generation: 1,
                endpointOrigin: "http://127.0.0.1:1234",
                model: "fixture-model",
                maximumTokens: 1_024,
                requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 60_000
            ),
            observedModelInventorySHA256: String(repeating: "a", count: 64)
        )
        let requestID = UUID()
        let inference = ReconstructionInferenceExecutionResult(
            candidate: .init(
                jobID: jobID, checkpointRevision: 4, roundID: roundID,
                selectedHandleIDs: [], disposition: .continue, unresolvedGaps: []
            ),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: .init(
                requestID: requestID, jobID: jobID, checkpointRevision: 4,
                roundID: roundID, status: .completed
            )
        )
        self.inference = inference
        self.roundRequestAuthority = try .make(
            expectedRequestID: inference.terminalReceipt.requestID,
            request: .round(.init(
                protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
                jobID: jobID,
                checkpointRevision: 4,
                roundID: roundID,
                corpusManifestSHA256: manifest.canonicalSHA256,
                evidenceFrontierSHA256: frontier,
                registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
                    .toolRegistry.identity.sha256,
                context: .init(
                    canonicalBytes: Data("{}".utf8),
                    canonicalSHA256: productionDigest("3"),
                    evidenceIDs: []
                ),
                handles: []
            )),
            terminalReceipt: inference.terminalReceipt
        )
        let synthesis = ReconstructionFinalSynthesisExecutionResult(
            candidate: .init(kind: .synthesis, text: "done", evidenceIDs: []),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: .init(
                requestID: UUID(), jobID: jobID, checkpointRevision: 4,
                roundID: nil, status: .completed
            )
        )
        self.synthesis = synthesis
        self.finalRequestAuthority = try .make(
            expectedRequestID: synthesis.terminalReceipt.requestID,
            request: .finalSynthesis(.init(
                jobID: jobID,
                checkpointRevision: 4,
                corpusManifestSHA256: manifest.canonicalSHA256,
                evidenceFrontierSHA256: frontier,
                acceptedEvidenceIDs: [],
                context: .init(
                    canonicalBytes: Data("{}".utf8),
                    canonicalSHA256: productionDigest("3"),
                    evidenceIDs: []
                )
            )),
            terminalReceipt: synthesis.terminalReceipt
        )
        self.transition = .init(
            taskID: task.identity.taskID, expectedState: .pending,
            successorState: .completed, diagnostic: nil
        )
    }
}

private func preparedModel(
    _ preparation: ReconstructionRoundPreparation
) throws -> ReconstructionPreparedModelRound {
    guard case .model(let prepared) = preparation else {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    return prepared
}

private func productionMaterializerSnapshot() -> ReconstructionJobOrchestrationSnapshot {
    .init(
        jobID: UUID(uuidString: "a0000000-0000-0000-0000-00000000000a")!,
        jobCreationOrder: 1,
        checkpointID: UUID(uuidString: "a0000000-0000-0000-0000-00000000000b")!,
        checkpointRevision: 4,
        checkpointCorpusManifestSHA256: String(repeating: "a", count: 64),
        checkpointEvidenceFrontierSHA256: String(repeating: "b", count: 64),
        currentCorpusManifestSHA256: String(repeating: "a", count: 64),
        evidenceFrontierSHA256: String(repeating: "b", count: 64),
        currentDurableJobState: .retrieving,
        pauseContext: nil,
        maximumRoundsWithoutEvidence: 3,
        tasks: [],
        terminalReceiptStatesByTaskID: [:]
    )
}

private func productionTask(
    jobID: UUID,
    taskID: UUID,
    dependencyTaskIDs: [UUID]
) throws -> ReconstructionTaskRecord {
    .init(
        identity: try .init(
            taskID: taskID, jobID: jobID, kind: .checkpoint, subject: nil,
            dependencyTaskIDs: dependencyTaskIDs,
            operationContractIdentity: "reconstruction.checkpoint.v1",
            canonicalSHA256: productionDigest("7")
        ),
        state: .pending,
        diagnostic: nil
    )
}

private func productionPlan(
    cut: ReconstructionProductionCommittedRoundCut,
    disposition: ReconstructionJobCoordinatorDisposition
) throws -> ReconstructionJobCommitPlan {
    let snapshot = cut.snapshot
    let authority = try productionDispositionAuthority(
        disposition,
        snapshot: snapshot
    )
    let successor = try ReconstructionCheckpoint.make(
        checkpointID: UUID(), jobID: snapshot.jobID,
        revision: snapshot.checkpointRevision + 1,
        parentCheckpointID: cut.parentCheckpointID,
        parentCheckpointSHA256: cut.parentCheckpointSHA256,
        corpusManifestSHA256: snapshot.currentCorpusManifestSHA256,
        evidenceFrontierSHA256: snapshot.evidenceFrontierSHA256,
        pendingTaskIDs: snapshot.tasks.filter { $0.state == .pending }.map(\.identity.taskID),
        runningTaskIDs: [], completedTaskIDs: [], failedTaskIDs: [], blockedTaskIDs: [],
        unresolvedEvidenceGapSHA256: productionDigest("8"),
        modelReceiptIDs: [], toolReceiptIDs: [],
        coordinatorState: authority.state,
        terminalReason: authority.terminalReason
    )
    let freshness = try ReconstructionFreshnessAuthority(
        corpusManifestSHA256: snapshot.currentCorpusManifestSHA256,
        currentArtifacts: [], currentImages: [], currentFacetFingerprints: [:]
    )
    let mutation = ReconstructionCheckpointMutation(
        jobID: snapshot.jobID,
        expectedParentCheckpointID: cut.parentCheckpointID,
        expectedParentCheckpointSHA256: cut.parentCheckpointSHA256,
        expectedParentRevision: snapshot.checkpointRevision,
        evidence: [], evidenceRelations: [], toolReceipts: [], modelReceipts: [],
        taskTransitions: [], freshnessAuthority: freshness,
        successorCheckpoint: successor,
        successorPauseContext: authority.pauseContext
    )
    return .init(
        successorRevision: snapshot.checkpointRevision + 1,
        acceptedEvidenceCount: 0,
        disposition: disposition,
        mutation: mutation
    )
}

private func productionDispositionAuthority(
    _ disposition: ReconstructionJobCoordinatorDisposition,
    snapshot: ReconstructionJobOrchestrationSnapshot
) throws -> (
    state: ReconstructionJobState,
    pauseContext: ReconstructionJobPauseContext?,
    terminalReason: ReconstructionDiagnostic?
) {
    switch disposition {
    case .advancePhase(let phase):
        return (phase, nil, nil)
    case .continue:
        guard let activeState = snapshot.currentDurableActiveState else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return (activeState, nil, nil)
    case .completed:
        return (.completed, nil, nil)
    case .paused(let reason):
        guard let cause = reason.durablePauseCause,
              let activeState = snapshot.currentDurableActiveState else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return (
            .paused,
            try ReconstructionJobPauseContext(cause: cause, resumeTarget: activeState),
            nil
        )
    case .cancelled:
        return (
            .cancelled,
            nil,
            .sanitizing("Reconstruction job was cancelled.")
        )
    case .failed:
        return (
            .failed,
            nil,
            .sanitizing("Reconstruction job failed.")
        )
    }
}

private func replacingDurableAuthority(
    _ plan: ReconstructionJobCommitPlan,
    coordinatorState: ReconstructionJobState,
    terminalReason: ReconstructionDiagnostic?,
    pauseContext: ReconstructionJobPauseContext?
) throws -> ReconstructionJobCommitPlan {
    guard let mutation = plan.mutation else {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    let checkpoint = mutation.successorCheckpoint
    let replacement = try ReconstructionCheckpoint.make(
        checkpointID: checkpoint.checkpointID,
        schemaVersion: checkpoint.schemaVersion,
        jobID: checkpoint.jobID,
        revision: checkpoint.revision,
        parentCheckpointID: checkpoint.parentCheckpointID,
        parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
        corpusManifestSHA256: checkpoint.corpusManifestSHA256,
        evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
        pendingTaskIDs: checkpoint.pendingTaskIDs,
        runningTaskIDs: checkpoint.runningTaskIDs,
        completedTaskIDs: checkpoint.completedTaskIDs,
        failedTaskIDs: checkpoint.failedTaskIDs,
        blockedTaskIDs: checkpoint.blockedTaskIDs,
        unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
        modelReceiptIDs: checkpoint.modelReceiptIDs,
        toolReceiptIDs: checkpoint.toolReceiptIDs,
        coordinatorState: coordinatorState,
        terminalReason: terminalReason
    )
    return .init(
        successorRevision: plan.successorRevision,
        acceptedEvidenceCount: plan.acceptedEvidenceCount,
        disposition: plan.disposition,
        mutation: ReconstructionCheckpointMutation(
            jobID: mutation.jobID,
            expectedParentCheckpointID: mutation.expectedParentCheckpointID,
            expectedParentCheckpointSHA256: mutation.expectedParentCheckpointSHA256,
            expectedParentRevision: mutation.expectedParentRevision,
            evidence: mutation.evidence,
            evidenceRelations: mutation.evidenceRelations,
            evidenceGaps: mutation.evidenceGaps,
            toolReceipts: mutation.toolReceipts,
            modelReceipts: mutation.modelReceipts,
            newTasks: mutation.newTasks,
            taskTransitions: mutation.taskTransitions,
            freshnessAuthority: mutation.freshnessAuthority,
            successorCheckpoint: replacement,
            successorPauseContext: pauseContext
        )
    )
}

private func replacingSnapshotDurableAuthority(
    _ snapshot: ReconstructionJobOrchestrationSnapshot,
    state: ReconstructionJobState,
    pauseContext: ReconstructionJobPauseContext?,
    tasks: [ReconstructionTaskRecord]? = nil
) throws -> ReconstructionJobOrchestrationSnapshot {
    guard (state == .paused) == (pauseContext != nil) else {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    return .init(
        jobID: snapshot.jobID,
        jobCreationOrder: snapshot.jobCreationOrder,
        checkpointID: snapshot.checkpointID,
        checkpointRevision: snapshot.checkpointRevision,
        checkpointCorpusManifestSHA256: snapshot.checkpointCorpusManifestSHA256,
        checkpointEvidenceFrontierSHA256: snapshot.checkpointEvidenceFrontierSHA256,
        currentCorpusManifestSHA256: snapshot.currentCorpusManifestSHA256,
        evidenceFrontierSHA256: snapshot.evidenceFrontierSHA256,
        currentDurableJobState: state,
        pauseContext: pauseContext,
        maximumRoundsWithoutEvidence: snapshot.maximumRoundsWithoutEvidence,
        tasks: tasks ?? snapshot.tasks,
        terminalReceiptStatesByTaskID: snapshot.terminalReceiptStatesByTaskID
    )
}

private func assertInvalidDurablePlan(
    _ plan: ReconstructionJobCommitPlan,
    snapshot: ReconstructionJobOrchestrationSnapshot,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(
        try ReconstructionProductionJobRoundMaterializer.validateDurablePlan(
            plan,
            against: snapshot
        ),
        file: file,
        line: line
    ) { error in
        XCTAssertEqual(
            error as? ReconstructionJobCoordinatorFailure,
            .invalidCommitPlan,
            file: file,
            line: line
        )
    }
}

private func productionDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

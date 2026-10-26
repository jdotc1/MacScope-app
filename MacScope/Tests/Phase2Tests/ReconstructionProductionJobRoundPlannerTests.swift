import XCTest

@testable import MacScope

@MainActor
final class ReconstructionProductionJobRoundPlannerTests: XCTestCase {
    func testPreparedAuthorityMustMatchEveryDurableRoundFence() throws {
        let snapshot = plannerSnapshot()
        let roundID = UUID(uuidString: "81000000-0000-0000-0000-000000000081")!
        let matching = try plannerAuthority(snapshot: snapshot, roundID: roundID)

        XCTAssertNoThrow(try ReconstructionProductionJobRoundPlanner.validatePreparedAuthority(
            matching,
            roundID: roundID,
            snapshot: snapshot
        ))

        let wrongJob = try ReconstructionToolAuthorityCut(
            jobID: UUID(),
            checkpointRevision: snapshot.checkpointRevision,
            roundID: roundID,
            corpusManifestSHA256: snapshot.currentCorpusManifestSHA256,
            evidenceFrontierSHA256: snapshot.evidenceFrontierSHA256,
            projectionFrontierSHA256: plannerDigest(4)
        )
        XCTAssertThrowsError(try ReconstructionProductionJobRoundPlanner.validatePreparedAuthority(
            wrongJob,
            roundID: roundID,
            snapshot: snapshot
        )) { error in
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .malformedOutput)
        }
    }

    func testRecoveryAndControlDelegateWithoutChangingCommitAuthority() async throws {
        let snapshot = plannerSnapshot()
        let materializer = RecordingProductionRoundMaterializer()
        let planner = await makePlanner(materializer: materializer)
        let transition = ReconstructionTaskTransition(
            taskID: UUID(uuidString: "82000000-0000-0000-0000-000000000082")!,
            expectedState: .running,
            successorState: .pending,
            diagnostic: nil
        )

        let recovery = try await planner.planRecovery(
            from: snapshot,
            transitions: [transition]
        )
        let control = try await planner.planControl(from: snapshot, reason: .pausedByUser)

        XCTAssertEqual(recovery.successorRevision, snapshot.checkpointRevision + 1)
        XCTAssertEqual(recovery.disposition, .continue)
        XCTAssertEqual(control.successorRevision, snapshot.checkpointRevision + 1)
        XCTAssertEqual(control.disposition, .paused(.pausedByUser))
        let recordedTransitions = await materializer.recoveryTransitions
        let recordedReasons = await materializer.controlReasons
        XCTAssertEqual(recordedTransitions, [[transition]])
        XCTAssertEqual(recordedReasons, [.pausedByUser])
    }

    func testDirectDurableCommitBypassesInferenceEntirely() async throws {
        let snapshot = plannerSnapshot()
        let directPlan = plannerCommit(snapshot: snapshot, disposition: .continue)
        let materializer = RecordingProductionRoundMaterializer(directPlan: directPlan)
        let inference = RecordingReadyInferenceCoordinator()
        let planner = makePlanner(materializer: materializer, inference: inference)

        let plan = try await planner.planRound(from: snapshot)

        XCTAssertEqual(plan.successorRevision, directPlan.successorRevision)
        XCTAssertEqual(plan.disposition, directPlan.disposition)
        XCTAssertEqual(inference.runCallCount, 0)
        XCTAssertEqual(inference.synthesisCallCount, 0)
    }

    func testCancelInterruptsTheActiveRoundTaskForOnlyThatJob() async throws {
        let snapshot = plannerSnapshot()
        let materializer = RecordingProductionRoundMaterializer(suspendPrepare: true)
        let planner = await makePlanner(materializer: materializer)
        let running = Task { try await planner.planRound(from: snapshot) }
        await materializer.waitUntilPrepareEntered()

        await planner.cancel(jobID: snapshot.jobID)

        do {
            _ = try await running.value
            XCTFail("Cancelling the durable job must interrupt its active round")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancelAfterPreparationDiscardsTheExactCachedRound() async throws {
        let fixture = try PlannerModelFixture()
        let materializer = RecordingProductionRoundMaterializer(
            preparedRound: fixture.prepared
        )
        let runEntered = expectation(description: "prepared round entered inference")
        let inference = SuspendingReadyInferenceCoordinator(runEntered: runEntered)
        let planner = makePlanner(materializer: materializer, inference: inference)
        let running = Task { try await planner.planRound(from: fixture.snapshot) }
        await fulfillment(of: [runEntered], timeout: 1.0)

        await planner.cancel(jobID: fixture.snapshot.jobID)

        do {
            _ = try await running.value
            XCTFail("Cancelling after cut preparation must interrupt inference")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let discardCount = await materializer.discardCount
        XCTAssertEqual(discardCount, 1)
    }

    private func makePlanner(
        materializer: RecordingProductionRoundMaterializer,
        inference: any ReconstructionReadyInferenceCoordinating = UnusedReadyInferenceCoordinator()
    ) -> ReconstructionProductionJobRoundPlanner {
        ReconstructionProductionJobRoundPlanner(
            materializer: materializer,
            inference: inference,
            projectors: []
        )
    }
}

private actor RecordingProductionRoundMaterializer: ReconstructionJobRoundMaterializing {
    private let suspendPrepare: Bool
    private let directPlan: ReconstructionJobCommitPlan?
    private let preparedRound: ReconstructionPreparedModelRound?
    private var prepareEntered = false
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var recoveryTransitions: [[ReconstructionTaskTransition]] = []
    private(set) var controlReasons: [ReconstructionJobPauseReason] = []
    private(set) var discardCount = 0

    init(
        suspendPrepare: Bool = false,
        directPlan: ReconstructionJobCommitPlan? = nil,
        preparedRound: ReconstructionPreparedModelRound? = nil
    ) {
        self.suspendPrepare = suspendPrepare
        self.directPlan = directPlan
        self.preparedRound = preparedRound
    }

    func prepare(
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionRoundPreparation {
        prepareEntered = true
        prepareWaiters.forEach { $0.resume() }
        prepareWaiters.removeAll()
        if suspendPrepare {
            try await Task.sleep(for: .seconds(30))
        }
        if let directPlan {
            return .commit(directPlan)
        }
        if let preparedRound {
            return .model(preparedRound)
        }
        throw ReconstructionJobCoordinatorFailure.malformedOutput
    }

    func discardPreparedRound(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound
    ) async {
        discardCount += 1
    }

    func waitUntilPrepareEntered() async {
        if prepareEntered { return }
        await withCheckedContinuation { prepareWaiters.append($0) }
    }

    func makeCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan {
        plannerCommit(snapshot: snapshot, disposition: .continue)
    }

    func makeFailedModelPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        plannerCommit(snapshot: snapshot, disposition: .paused(.modelUnavailable))
    }

    func makeFinalCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        plannerCommit(snapshot: snapshot, disposition: .completed)
    }

    func makeRecoveryPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        recoveryTransitions.append(transitions)
        return plannerCommit(snapshot: snapshot, disposition: .continue)
    }

    func makeControlPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        controlReasons.append(reason)
        return plannerCommit(snapshot: snapshot, disposition: reason.controlDisposition)
    }
}

@MainActor
private final class RecordingReadyInferenceCoordinator: ReconstructionReadyInferenceCoordinating {
    private(set) var runCallCount = 0
    private(set) var synthesisCallCount = 0

    func run(
        request: ReconstructionInferenceRoundRequest
    ) async -> ReconstructionReadyInferenceExecutionResult {
        runCallCount += 1
        return .busy
    }

    func synthesize(
        request: ReconstructionFinalSynthesisRequest
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        synthesisCallCount += 1
        return .busy
    }
}

@MainActor
private final class SuspendingReadyInferenceCoordinator: ReconstructionReadyInferenceCoordinating {
    private let runEntered: XCTestExpectation

    init(runEntered: XCTestExpectation) {
        self.runEntered = runEntered
    }

    func run(
        request: ReconstructionInferenceRoundRequest
    ) async -> ReconstructionReadyInferenceExecutionResult {
        runEntered.fulfill()
        do {
            try await Task.sleep(for: .seconds(30))
            return .busy
        } catch {
            return .failedWithoutTerminalAuthority(.cancelled)
        }
    }

    func synthesize(
        request: ReconstructionFinalSynthesisRequest
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        .busy
    }
}

@MainActor
private final class UnusedReadyInferenceCoordinator: ReconstructionReadyInferenceCoordinating {
    func run(
        request: ReconstructionInferenceRoundRequest
    ) async -> ReconstructionReadyInferenceExecutionResult {
        .busy
    }

    func synthesize(
        request: ReconstructionFinalSynthesisRequest
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        .busy
    }
}

private func plannerSnapshot() -> ReconstructionJobOrchestrationSnapshot {
    .init(
        jobID: UUID(uuidString: "80000000-0000-0000-0000-000000000080")!,
        jobCreationOrder: 1,
        checkpointID: UUID(uuidString: "80000000-0000-0000-0000-000000000081")!,
        checkpointRevision: 7,
        checkpointCorpusManifestSHA256: plannerDigest(1),
        checkpointEvidenceFrontierSHA256: plannerDigest(2),
        currentCorpusManifestSHA256: plannerDigest(1),
        evidenceFrontierSHA256: plannerDigest(2),
        currentDurableJobState: .retrieving,
        pauseContext: nil,
        maximumRoundsWithoutEvidence: 3,
        tasks: [],
        terminalReceiptStatesByTaskID: [:]
    )
}

private func plannerAuthority(
    snapshot: ReconstructionJobOrchestrationSnapshot,
    roundID: UUID
) throws -> ReconstructionToolAuthorityCut {
    try .init(
        jobID: snapshot.jobID,
        checkpointRevision: snapshot.checkpointRevision,
        roundID: roundID,
        corpusManifestSHA256: snapshot.currentCorpusManifestSHA256,
        evidenceFrontierSHA256: snapshot.evidenceFrontierSHA256,
        projectionFrontierSHA256: plannerDigest(4)
    )
}

private struct PlannerModelFixture {
    let snapshot: ReconstructionJobOrchestrationSnapshot
    let prepared: ReconstructionPreparedModelRound

    init() throws {
        let jobID = UUID(uuidString: "83000000-0000-0000-0000-000000000083")!
        let manifestDraft = try ReconstructionCorpusManifest(
            reconstructionProjectID: UUID(),
            artifacts: [],
            relations: [],
            canonicalSHA256: plannerDigest(1)
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: manifestDraft.reconstructionProjectID,
            artifacts: [],
            relations: [],
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(
                of: manifestDraft
            )
        )
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: [],
            checkpointRevisionsByID: [:]
        )
        let evidenceCut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            relations: [],
            gaps: [],
            frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: [:],
            checkpointRevisionsByID: [:]
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: jobID,
            jobCreationOrder: 1,
            checkpointID: UUID(),
            checkpointRevision: 3,
            checkpointCorpusManifestSHA256: manifest.canonicalSHA256,
            checkpointEvidenceFrontierSHA256: frontier,
            currentCorpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier,
            currentDurableJobState: .awaitingModel,
            pauseContext: nil,
            maximumRoundsWithoutEvidence: 3,
            tasks: [],
            terminalReceiptStatesByTaskID: [:]
        )
        let roundID = UUID(uuidString: "84000000-0000-0000-0000-000000000084")!
        let projectionFrontier = try ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: [:],
                staleOperations: [],
                tasks: [],
                receipts: [],
                producersByOperation: [:],
                evidenceAuthorityCutsByOperation: [:]
            )
        let authority = try ReconstructionToolAuthorityCut(
            jobID: jobID,
            checkpointRevision: snapshot.checkpointRevision,
            roundID: roundID,
            corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier,
            projectionFrontierSHA256: projectionFrontier
        )
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: manifest.canonicalSHA256,
            subject: nil,
            operationIDs: [.corpusSummary],
            classifications: [.acceptedCurrent],
            cursor: nil,
            maximumRecords: 1,
            maximumEncodedBytes: 4_096
        )
        let projectorInput = try ReconstructionToolProjectorInput(
            authority: authority,
            corpusManifest: manifest,
            evidenceCut: evidenceCut,
            tasks: [],
            receipts: [],
            producersByOperation: [:],
            projectedItemsByOperation: [:],
            staleOperations: [],
            evidenceAuthorityCutsByOperation: [:]
        )
        self.snapshot = snapshot
        prepared = ReconstructionPreparedModelRound(
            roundID: roundID,
            evidenceCut: evidenceCut,
            retrievalQuery: query,
            allowedGapSubjects: [],
            allowedGapCategories: [],
            authority: authority,
            requests: [ReconstructionToolRequest(
                operationID: .corpusSummary,
                taskID: UUID(uuidString: "85000000-0000-0000-0000-000000000085")!,
                subject: nil,
                retrievalQuery: nil,
                offset: 0,
                maximumRecords: 1,
                maximumEncodedBytes: 4_096
            )],
            projectorInput: projectorInput
        )
    }
}

private func plannerCommit(
    snapshot: ReconstructionJobOrchestrationSnapshot,
    disposition: ReconstructionJobCoordinatorDisposition
) -> ReconstructionJobCommitPlan {
    .init(
        successorRevision: snapshot.checkpointRevision + 1,
        acceptedEvidenceCount: 0,
        disposition: disposition,
        mutation: nil
    )
}

private func plannerDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}

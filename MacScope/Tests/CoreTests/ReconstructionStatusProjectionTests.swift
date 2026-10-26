import XCTest
@testable import MacScope

final class ReconstructionStatusProjectionTests: XCTestCase {
    func testEveryJobStateHasAStablePresentationAndCentralControlMapping() throws {
        for state in ReconstructionJobState.allCases {
            let projection = ReconstructionStatusProjection.controlProjection(
                state: state,
                readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model"),
                pauseContext: state == .paused
                    ? try ReconstructionJobPauseContext(
                        cause: .pausedByUser,
                        resumeTarget: .retrieving
                    )
                    : nil
            )

            XCTAssertFalse(projection.stateTitle.isEmpty, "Missing title for \(state)")
            XCTAssertFalse(projection.stateDetail.isEmpty, "Missing detail for \(state)")
            XCTAssertEqual(
                projection.controls.canPause,
                ReconstructionJobState.activeStates.contains(state),
                "Pause drift for \(state)"
            )
            XCTAssertEqual(
                projection.controls.canCancel,
                ReconstructionJobState.activeStates.contains(state) || state == .paused,
                "Cancel drift for \(state)"
            )
        }
    }

    func testStartRequiresCreatedStateAndReadyModel() {
        XCTAssertTrue(
            ReconstructionStatusProjection.controlProjection(
                state: .created,
                readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model")
            ).controls.canStart
        )
        XCTAssertFalse(
            ReconstructionStatusProjection.controlProjection(
                state: .created,
                readiness: .unavailable(title: "Provider unavailable", detail: "Retry discovery.")
            ).controls.canStart
        )
        XCTAssertFalse(
            ReconstructionStatusProjection.controlProjection(
                state: .ingesting,
                readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model")
            ).controls.canStart
        )
    }

    func testPausedModelUnavailableRemainsVisibleAndResumableWhenReadinessReturns() throws {
        let unavailable = ReconstructionStatusProjection.controlProjection(
            state: .paused,
            readiness: .unavailable(
                title: "Provider unavailable",
                detail: "The selected model is not currently reachable."
            ),
            pauseContext: try ReconstructionJobPauseContext(
                cause: .modelUnavailable,
                resumeTarget: .awaitingModel
            )
        )
        XCTAssertTrue(unavailable.controls.hasResumePath)
        XCTAssertFalse(unavailable.controls.canResume)
        XCTAssertEqual(
            unavailable.controls.resumeBlockedReason,
            "Current local-model authority is not executable."
        )
        XCTAssertEqual(unavailable.controls.pauseCause, .modelUnavailable)
        XCTAssertEqual(unavailable.controls.resumeTarget, .awaitingModel)

        let ready = ReconstructionStatusProjection.controlProjection(
            state: .paused,
            readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model"),
            pauseContext: try ReconstructionJobPauseContext(
                cause: .modelUnavailable,
                resumeTarget: .awaitingModel
            )
        )
        XCTAssertTrue(ready.controls.hasResumePath)
        XCTAssertTrue(ready.controls.canResume)
        XCTAssertNil(ready.controls.resumeBlockedReason)
    }

    func testPausedAndTerminalJobsCannotCancel() throws {
        let paused = ReconstructionStatusProjection.controlProjection(
            state: .paused,
            readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model"),
            pauseContext: try ReconstructionJobPauseContext(
                cause: .pausedByUser,
                resumeTarget: .retrieving
            )
        )
        XCTAssertTrue(paused.controls.canCancel)
        XCTAssertNil(paused.controls.cancel.disabledReason)

        for terminalState in [ReconstructionJobState.completed, .cancelled, .failed] {
            let terminal = ReconstructionStatusProjection.controlProjection(
                state: terminalState,
                readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model")
            )
            XCTAssertFalse(terminal.controls.canCancel, "Cancel leaked into \(terminalState)")
        }
    }

    func testWorkspaceProjectionDerivesExactResumeAuthorityFromDurableJobContext() throws {
        let context = try ReconstructionJobPauseContext(
            cause: .frontierMismatch,
            resumeTarget: .awaitingModel
        )
        let workspace = try pausedWorkspace(context: context)

        let projection = ReconstructionStatusProjection.project(
            workspace: workspace,
            selectedJobID: nil,
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete
        )

        XCTAssertEqual(projection.state, .paused)
        XCTAssertEqual(projection.controls.pauseCause, .frontierMismatch)
        XCTAssertEqual(projection.controls.resumeTarget, .awaitingModel)
        XCTAssertTrue(projection.controls.hasResumePath)
        XCTAssertFalse(projection.controls.canResume)
    }

    func testEveryProviderReadinessCaseProjectsTruthfully() throws {
        let configuration = try Phase2AIProviderConfiguration(
            profileID: UUID(),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "local-model",
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 10_000
        )
        let readinessCases: [Phase2LocalAIProviderReadiness] = [
            .endpointMissing, .inventoryRequired, .authenticationRequired, .unavailable,
            .incompatible, .reconciliationRequired, .selectionRequired,
            .selectionIdentityMismatch, .selectedModelMissing, .selectedModelNotLanguage,
            .loadRequired(modelKey: "local-model"), .ready(configuration)
        ]

        for readiness in readinessCases {
            let projection = ReconstructionModelReadinessProjection(readiness)
            XCTAssertFalse(projection.title.isEmpty, "Missing readiness title for \(readiness)")
            XCTAssertFalse(projection.detail.isEmpty, "Missing readiness detail for \(readiness)")
            XCTAssertEqual(projection.isReady, readiness.isReadyForAssistant)
        }

        let ready = ReconstructionModelReadinessProjection(.ready(configuration))
        XCTAssertEqual(ready.endpoint, "http://127.0.0.1:1234")
        XCTAssertEqual(ready.model, "local-model")
    }

    func testEmptyWorkspaceProjectsOneImmutableEmptyCut() {
        let projection = ReconstructionStatusProjection.project(
            workspace: .empty,
            selectedJobID: nil,
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete
        )

        XCTAssertNil(projection.projectName)
        XCTAssertNil(projection.objective)
        XCTAssertEqual(projection.corpus.occurrenceCount, 0)
        XCTAssertEqual(projection.progress.totalTaskCount, 0)
        XCTAssertEqual(projection.evidence.totalCount, 0)
        XCTAssertNil(projection.checkpointRevision)
        XCTAssertEqual(projection.currentGap.status, .none)
        XCTAssertTrue(projection.isEmpty)
    }

    func testEvidenceClassificationCountsAreExhaustiveAndNonoverlapping() {
        let summary = ReconstructionStatusProjection.evidenceSummary(
            classifications: ReconstructionEvidenceClassification.allCases
        )

        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.historicalCount, 1)
        XCTAssertEqual(summary.staleCount, 2)
        XCTAssertEqual(summary.unavailableCount, 5)
        XCTAssertEqual(summary.totalCount, ReconstructionEvidenceClassification.allCases.count)
    }

    private func pausedWorkspace(
        context: ReconstructionJobPauseContext
    ) throws -> ReconstructionWorkspaceState {
        let projectID = UUID(uuidString: "3a000000-0000-0000-0000-000000000001")!
        let jobID = UUID(uuidString: "3a000000-0000-0000-0000-000000000002")!
        let checkpointID = UUID(uuidString: "3a000000-0000-0000-0000-000000000003")!
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: checkpointID,
            jobID: jobID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: digestA,
            evidenceFrontierSHA256: digestB,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: digestA,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .paused,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: jobID,
            reconstructionProjectID: projectID,
            objective: "Recover the selected corpus",
            objectiveSHA256: digestA,
            creationCorpusManifestSHA256: digestA,
            state: .paused,
            currentCheckpointID: checkpointID,
            terminalReason: nil,
            budget: try ReconstructionJobBudget(
                maxRounds: 2,
                maxTasks: 4,
                maxEvidenceRecords: 8,
                maxEncodedBytes: 1_024
            ),
            creationOrdinal: 1,
            pauseContext: context
        )
        return try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Projection Fixture",
                    currentCorpusManifestSHA256: nil
                ),
            ],
            corpusManifests: [],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [job],
            tasks: [],
            checkpoints: [checkpoint],
            toolReceipts: [],
            modelReceipts: []
        )
    }
}

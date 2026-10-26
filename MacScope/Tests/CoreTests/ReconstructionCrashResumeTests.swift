import XCTest

@testable import MacScope

final class ReconstructionCrashResumeTests: XCTestCase {
    func testProductionLoadPreservesHistoricalFailureRevisionDuringRunningRetry() async throws {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let state = try productionRetryState(binaryID: database.binaryID)
        try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID, state: state)
        let owner = ReconstructionDatabaseOwner(database: database.database)
        let snapshot = try await ReconstructionDatabaseJobPersistence(workspaceID: database.workspaceUUID,
            owner: owner).load(jobID: try XCTUnwrap(state.jobs.first).jobID)
        let model = try XCTUnwrap(state.tasks.first { $0.identity.kind == .modelRound })
        XCTAssertEqual(snapshot.terminalReceiptCheckpointRevisionsByTaskID[model.identity.taskID], 1)
        XCTAssertEqual(snapshot.checkpointRevision, 3)
        guard case .recover(let transitions) = ReconstructionCrashRecovery.plan(snapshot: snapshot) else {
            return XCTFail("Expected interrupted retry recovery.")
        }
        XCTAssertTrue(transitions.allSatisfy { $0.successorState == .pending })
        await owner.revoke()
    }

    func testProductionLoadAcceptsSuccessfulRetryAfterHistoricalFailedReceipt() async throws {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let state = try productionRetryState(binaryID: database.binaryID, successfulRetry: true)
        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
        try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID, state: state)
        let owner = ReconstructionDatabaseOwner(database: database.database)
        let snapshot = try await ReconstructionDatabaseJobPersistence(workspaceID: database.workspaceUUID,
            owner: owner).load(jobID: try XCTUnwrap(state.jobs.first).jobID)
        let model = try XCTUnwrap(state.tasks.first { $0.identity.kind == .modelRound })
        XCTAssertEqual(snapshot.terminalReceiptStatesByTaskID[model.identity.taskID], .completed)
        XCTAssertEqual(snapshot.terminalReceiptCheckpointRevisionsByTaskID[model.identity.taskID], 3)
        XCTAssertEqual(snapshot.consecutiveModelRoundsWithoutEvidence, 1)
        await owner.revoke()
    }

    func testProductionLoadAcceptsHistoricalNoEvidenceCountBeyondAutomaticPauseBound() async throws {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let state = try productionRetryState(binaryID: database.binaryID, completedRounds: 2)
        try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID, state: state)
        let owner = ReconstructionDatabaseOwner(database: database.database)
        let snapshot = try await ReconstructionDatabaseJobPersistence(workspaceID: database.workspaceUUID,
            owner: owner).load(jobID: try XCTUnwrap(state.jobs.first).jobID)
        XCTAssertEqual(snapshot.maximumRoundsWithoutEvidence, 1)
        XCTAssertEqual(snapshot.consecutiveModelRoundsWithoutEvidence, 2)
        await owner.revoke()
    }
    func testInjectedPrecommitInterruptionReopensAndRecoversWithoutDuplicateTerminalPublication()
        async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionCrashResume-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("workspace.sqlite", isDirectory: false)
        let workspaceID = recoveryID(100)
        let snapshot = AnalysisEngine.previewSnapshot()
        let binaryID = try XCTUnwrap(snapshot.binaries.first?.id)
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: binaryID
        )
        let running = try runningFoundation(from: foundation)
        let interruptedTerminalMutation = try ReconstructionDatabaseTestFixtures.makeMutation(
            from: running,
            transitionExpectedState: .running
        )

        var interruptedDatabase: WorkspaceDatabase? = try WorkspaceDatabase(
            path: databaseURL.path
        )
        do {
            let liveDatabase = try XCTUnwrap(interruptedDatabase)
            try liveDatabase.applySchema()
            _ = try liveDatabase.saveSnapshot(
                workspaceUUID: workspaceID,
                workspaceName: "Durable crash recovery",
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_788_000_000)
            )
            try liveDatabase.replaceReconstructionState(
                workspaceID: workspaceID,
                state: running.state
            )
            liveDatabase.setReconstructionMutationFailureForTesting(
                after: .insertedToolReceipts
            )
            XCTAssertThrowsError(
                try liveDatabase.commitReconstructionCheckpoint(
                    workspaceID: workspaceID,
                    mutation: interruptedTerminalMutation
                )
            ) { error in
                XCTAssertEqual(
                    error as? WorkspaceDatabase.DatabaseError,
                    .reconstructionInjectedFailure("insertedToolReceipts")
                )
            }
            XCTAssertEqual(
                try liveDatabase.loadReconstructionState(workspaceID: workspaceID),
                running.state,
                "the injected pre-commit interruption must roll back every terminal row"
            )
        }
        interruptedDatabase = nil

        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        try reopened.applySchema()
        let stateBeforeRecovery = try reopened.loadReconstructionState(workspaceID: workspaceID)
        XCTAssertEqual(stateBeforeRecovery, running.state)
        XCTAssertEqual(stateBeforeRecovery.tasks, [running.task])
        XCTAssertTrue(stateBeforeRecovery.toolReceipts.isEmpty)
        XCTAssertTrue(stateBeforeRecovery.modelReceipts.isEmpty)
        XCTAssertEqual(stateBeforeRecovery.checkpoints, [running.checkpoint])

        let recoveryMutation = try pendingRecoveryMutation(from: running)
        let recoveryPlan = ReconstructionJobCommitPlan(
            successorRevision: recoveryMutation.successorCheckpoint.revision,
            acceptedEvidenceCount: 0,
            disposition: .continue,
            mutation: recoveryMutation
        )
        let owner = ReconstructionDatabaseOwner(database: reopened)
        let persistence = ReconstructionDatabaseJobPersistence(
            workspaceID: workspaceID,
            owner: owner
        )
        let planner = DurableCrashRecoveryPlanner(plan: recoveryPlan)
        let publisher = DurableCrashRecoveryPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )
        await publisher.bind(coordinator)

        await coordinator.start(jobID: running.job.jobID)

        let expectedTransition = ReconstructionTaskTransition(
            taskID: running.task.identity.taskID,
            expectedState: .running,
            successorState: .pending,
            diagnostic: nil
        )
        let recoveryTransitions = await planner.recoveryTransitions
        let roundPlanCount = await planner.roundPlanCount
        let controlPlanCount = await planner.controlPlanCount
        XCTAssertEqual(recoveryTransitions, [[expectedTransition]])
        XCTAssertEqual(roundPlanCount, 0)
        XCTAssertEqual(controlPlanCount, 0)

        let recoveredState = try await owner.load(workspaceID: workspaceID)
        let recoveredTask = try XCTUnwrap(recoveredState.tasks.first)
        let recoveredJob = try XCTUnwrap(recoveredState.jobs.first)
        XCTAssertEqual(recoveredTask.state, .pending)
        XCTAssertTrue(recoveredState.toolReceipts.isEmpty)
        XCTAssertTrue(recoveredState.modelReceipts.isEmpty)
        XCTAssertTrue(recoveredState.evidence.isEmpty)
        XCTAssertEqual(recoveredState.checkpoints.first, running.checkpoint)
        XCTAssertEqual(recoveredState.checkpoints.last, recoveryMutation.successorCheckpoint)
        XCTAssertEqual(
            recoveredJob.currentCheckpointID,
            recoveryMutation.successorCheckpoint.checkpointID
        )

        let publications = await publisher.receipts
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.checkpointRevision, 1)
        XCTAssertEqual(publications.first?.disposition, .continue)
        for _ in 0..<3 { await Task.yield() }
        let publicationsAfterYield = await publisher.receipts
        XCTAssertEqual(
            publicationsAfterYield.count,
            1,
            "recovery suspension must prevent a late round or duplicate terminal publication"
        )

        // Mandatory mutation RED: remove the `.insertedToolReceipts` failure injection. The
        // reopened pre-recovery state then contains terminal receipts and the exact rollback
        // assertions fail. Separately, change the recovery transition to `.completed`; the
        // reopened durable pending-task assertion fails after production coordinator recovery.
        await publisher.unbind()
        await owner.revoke()
    }

    func testRunningTaskWithoutTerminalReceiptReturnsToPending() throws {
        let task = try recoveryTask(id: 1, state: .running)
        let snapshot = recoverySnapshot(tasks: [task], terminalReceiptTaskIDs: [])

        let plan = ReconstructionCrashRecovery.plan(snapshot: snapshot)

        XCTAssertEqual(plan, .recover([
            .init(
                taskID: task.identity.taskID,
                expectedState: .running,
                successorState: .pending,
                diagnostic: nil
            )
        ]))
    }

    func testRunningTaskWithTerminalReceiptRecoversToTerminalAndDoesNotReplay() throws {
        let task = try recoveryTask(id: 2, state: .running)
        let snapshot = recoverySnapshot(
            tasks: [task],
            terminalReceiptTaskIDs: [task.identity.taskID]
        )

        XCTAssertEqual(ReconstructionCrashRecovery.plan(snapshot: snapshot), .recover([
            .init(
                taskID: task.identity.taskID,
                expectedState: .running,
                successorState: .completed,
                diagnostic: nil
            )
        ]))
    }

    func testCrashRecoveryRejectsConflictingToolReceiptsInBothReceiptIDOrders() throws {
        let task = try recoveryTask(id: 20, state: .running)
        let producer = try ReconstructionDatabaseTestFixtures.makeProducer(
            operationID: ReconstructionOperationID.evidenceQuery.rawValue
        )
        let lowerReceiptID = recoveryID(21)
        let higherReceiptID = recoveryID(22)
        func receipt(
            id: UUID,
            terminalState: ReconstructionReceiptTerminalState
        ) throws -> ReconstructionToolReceipt {
            try ReconstructionReceiptAuthority.makeToolReceipt(
                receiptID: id,
                jobID: task.identity.jobID,
                taskID: task.identity.taskID,
                checkpointRevision: 5,
                requestIdentitySHA256: recoveryDigest(id == lowerReceiptID ? 21 : 22),
                producer: producer,
                terminalState: terminalState,
                outputEvidenceIDs: [],
                diagnostic: nil
            )
        }
        let receiptOrders = [
            [
                try receipt(id: lowerReceiptID, terminalState: .completed),
                try receipt(id: higherReceiptID, terminalState: .failed),
            ],
            [
                try receipt(id: lowerReceiptID, terminalState: .failed),
                try receipt(id: higherReceiptID, terminalState: .completed),
            ],
        ]

        for toolReceipts in receiptOrders {
            XCTAssertThrowsError(
                try ReconstructionDatabaseJobPersistence.terminalReceiptStates(
                    toolReceipts: toolReceipts,
                    modelReceipts: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionJobCoordinatorFailure,
                    .invalidCommitPlan
                )
            }
        }

        // Mandatory mutation RED: replace the checked `updateValue` guard in
        // `terminalReceiptStates` with blind assignment. Both calls stop throwing and this test
        // fails, proving receipt UUID order can no longer choose the recovered terminal state.
    }

    func testCorpusOrEvidenceFrontierMismatchPausesBeforeWork() {
        var snapshot = recoverySnapshot(tasks: [], terminalReceiptTaskIDs: [])
        snapshot = snapshot.withCurrentAuthority(
            corpusManifestSHA256: recoveryDigest(9),
            evidenceFrontierSHA256: recoveryDigest(8)
        )

        XCTAssertEqual(
            ReconstructionCrashRecovery.plan(snapshot: snapshot),
            .pause(.frontierMismatch)
        )
    }

    func testProductionPersistenceDetectsSiblingJobEvidenceFrontierAdvance() async throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: foundation.state
        )
        let owner = ReconstructionDatabaseOwner(database: databaseFixture.database)
        let siblingJobID = recoveryID(130)
        let sibling = try await owner.commitInitialJob(
            workspaceID: databaseFixture.workspaceUUID,
            mutation: ReconstructionInitialJobMutation(
                jobID: siblingJobID,
                projectID: foundation.project.projectID,
                selectedOccurrenceIDs: [foundation.occurrence.occurrenceID],
                objective: "Retain the pre-sibling frontier",
                budget: try ReconstructionJobBudget(
                    maxRounds: 4,
                    maxTasks: 64,
                    maxEvidenceRecords: 128,
                    maxEncodedBytes: 1_048_576
                )
            )
        )
        _ = try await owner.commit(
            ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        )

        let snapshot = try await ReconstructionDatabaseJobPersistence(
            workspaceID: databaseFixture.workspaceUUID,
            owner: owner
        ).load(jobID: siblingJobID)

        XCTAssertEqual(
            snapshot.checkpointEvidenceFrontierSHA256,
            sibling.checkpoint.evidenceFrontierSHA256
        )
        XCTAssertNotEqual(
            snapshot.evidenceFrontierSHA256,
            snapshot.checkpointEvidenceFrontierSHA256,
            "a sibling commit must advance the current project frontier independently"
        )
        XCTAssertEqual(
            ReconstructionCrashRecovery.plan(snapshot: snapshot),
            .pause(.frontierMismatch)
        )

        // Mandatory mutation RED: restore the former load-time assignment that copies the
        // sibling checkpoint digest into `evidenceFrontierSHA256`. The inequality and exact
        // frontierMismatch disposition both fail before any round planner can run.
        await owner.revoke()
    }

    func testOnlyUncommittedRunningTaskIsRecoveredWhenCompletedReceiptExists() throws {
        let committed = try recoveryTask(id: 3, state: .completed)
        let uncommitted = try recoveryTask(id: 4, state: .running)
        let snapshot = recoverySnapshot(
            tasks: [committed, uncommitted],
            terminalReceiptTaskIDs: [committed.identity.taskID]
        )

        guard case .recover(let transitions) = ReconstructionCrashRecovery.plan(snapshot: snapshot)
        else { return XCTFail("Expected recovery") }
        XCTAssertEqual(transitions.map(\.taskID), [uncommitted.identity.taskID])
    }
}

private enum ReconstructionCrashResumeTestError: Error {
    case unexpectedPlannerPath
}

/// Writes a complete admitted checkpoint chain, then exercises the real database capture/load
/// path. Failed provider attempts and later task activations are deliberately separate commits.
private func productionRetryState(binaryID: UUID, successfulRetry: Bool = false,
    completedRounds: Int = 0) throws -> ReconstructionWorkspaceState {
    let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: binaryID)
    let root = ReconstructionTaskRecord(identity: foundation.task.identity, state: .completed, diagnostic: nil)
    let roundCount = max(1, completedRounds)
    var trios: [[ReconstructionTaskRecord]] = []
    var dependency = root.identity.taskID
    for _ in 0..<roundCount {
        let retrieve = ReconstructionTaskRecord(identity: try .make(taskID: UUID(),
            jobID: foundation.job.jobID, kind: .retrieveEvidence, subject: nil,
            dependencyTaskIDs: [dependency], operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery),
            state: completedRounds > 0 || successfulRetry ? .completed : .running, diagnostic: nil)
        let model = ReconstructionTaskRecord(identity: try .make(taskID: UUID(),
            jobID: foundation.job.jobID, kind: .modelRound, subject: nil,
            dependencyTaskIDs: [retrieve.identity.taskID], operationContractIdentity: ReconstructionProductionTaskContract.modelRound),
            state: retrieve.state, diagnostic: nil)
        let checkpoint = ReconstructionTaskRecord(identity: try .make(taskID: UUID(),
            jobID: foundation.job.jobID, kind: .checkpoint, subject: nil,
            dependencyTaskIDs: [model.identity.taskID], operationContractIdentity: ReconstructionProductionTaskContract.checkpoint),
            state: retrieve.state == .completed ? .completed : .pending, diagnostic: nil)
        trios.append([retrieve, model, checkpoint])
        dependency = checkpoint.identity.taskID
    }
    let producer = try ReconstructionDatabaseTestFixtures.makeProducer(operationID: ReconstructionProductionTaskContract.modelRound)
    var receipts: [ReconstructionModelReceipt] = []
    if completedRounds == 0 {
        receipts.append(try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: UUID(),
            jobID: foundation.job.jobID, taskID: trios[0][1].identity.taskID,
            checkpointRevision: 1, requestIdentitySHA256: recoveryDigest(1), producer: producer,
            terminalState: .failed, selectedHandleIDs: [], acceptedEvidenceIDs: [], diagnostic: nil))
    }
    if completedRounds > 0 || successfulRetry {
        for (index, trio) in trios.enumerated() {
            receipts.append(try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: UUID(),
                jobID: foundation.job.jobID, taskID: trio[1].identity.taskID,
                checkpointRevision: successfulRetry ? 3 : UInt64(index + 1),
                requestIdentitySHA256: recoveryDigest(index + 2), producer: producer,
                terminalState: .completed, selectedHandleIDs: [], acceptedEvidenceIDs: [], diagnostic: nil))
        }
    }
    let tasks = [root] + trios.flatMap { $0 }
    let finalRevision = completedRounds > 0 ? completedRounds : 3
    var checkpoints: [ReconstructionCheckpoint] = []
    for revision in 0...finalRevision {
        var completedIDs = [root.identity.taskID]
        var runningIDs: [UUID] = []
        var pendingIDs: [UUID] = []
        for (index, trio) in trios.enumerated() {
            let completionRevision = successfulRetry ? 3 : index + 1
            if (successfulRetry || completedRounds > 0) && revision >= completionRevision {
                completedIDs.append(contentsOf: trio.map { $0.identity.taskID })
            } else if completedRounds == 0 && !successfulRetry && revision == 3 {
                runningIDs.append(contentsOf: trio.prefix(2).map { $0.identity.taskID })
                pendingIDs.append(trio[2].identity.taskID)
            } else {
                pendingIDs.append(contentsOf: trio.map { $0.identity.taskID })
            }
        }
        let parent = checkpoints.last
        checkpoints.append(try ReconstructionCheckpoint.make(
            checkpointID: revision == 0 ? foundation.checkpoint.checkpointID : UUID(),
            jobID: foundation.job.jobID, revision: UInt64(revision),
            parentCheckpointID: parent?.checkpointID, parentCheckpointSHA256: parent?.canonicalSHA256,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: pendingIDs, runningTaskIDs: runningIDs, completedTaskIDs: completedIDs,
            failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: receipts.filter { $0.checkpointRevision <= UInt64(revision) }.map { $0.receiptID },
            toolReceiptIDs: [], coordinatorState: .awaitingModel, terminalReason: nil))
    }
    let current = try XCTUnwrap(checkpoints.last)
    let job = try ReconstructionJobRecord(jobID: foundation.job.jobID,
        reconstructionProjectID: foundation.project.projectID,
        objective: foundation.job.objective, objectiveSHA256: foundation.job.objectiveSHA256,
        creationCorpusManifestSHA256: foundation.manifest.canonicalSHA256,
        state: .awaitingModel, currentCheckpointID: current.checkpointID, terminalReason: nil,
        budget: try .init(maxRounds: 1, maxTasks: 64, maxEvidenceRecords: 128, maxEncodedBytes: 1_048_576),
        creationOrdinal: 1)
    return try ReconstructionWorkspaceState(projects: foundation.state.projects,
        corpusManifests: foundation.state.corpusManifests, evidence: foundation.state.evidence,
        evidenceRelations: foundation.state.evidenceRelations, evidenceGaps: foundation.state.evidenceGaps,
        jobs: [job], tasks: tasks, checkpoints: checkpoints, toolReceipts: [], modelReceipts: receipts)
}

private actor DurableCrashRecoveryPlanner: ReconstructionJobRoundPlanning {
    let plan: ReconstructionJobCommitPlan
    private(set) var recoveryTransitions: [[ReconstructionTaskTransition]] = []
    private(set) var roundPlanCount = 0
    private(set) var controlPlanCount = 0

    init(plan: ReconstructionJobCommitPlan) {
        self.plan = plan
    }

    func planRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        roundPlanCount += 1
        throw ReconstructionCrashResumeTestError.unexpectedPlannerPath
    }

    func planRecovery(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        recoveryTransitions.append(transitions)
        return plan
    }

    func planControl(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        controlPlanCount += 1
        throw ReconstructionCrashResumeTestError.unexpectedPlannerPath
    }

    func cancel(jobID: UUID) async {}
}

private actor DurableCrashRecoveryPublisher: ReconstructionJobStatusPublishing {
    private var coordinator: ReconstructionJobCoordinator?
    private(set) var receipts: [ReconstructionJobCommitReceipt] = []

    func bind(_ coordinator: ReconstructionJobCoordinator) {
        self.coordinator = coordinator
    }

    func unbind() {
        coordinator = nil
    }

    func publish(_ receipt: ReconstructionJobCommitReceipt) async {
        receipts.append(receipt)
        await coordinator?.suspendWithoutDurableDisposition(jobID: receipt.jobID)
    }
}

private func runningFoundation(
    from foundation: ReconstructionDatabaseTestFixtures.StateFixture
) throws -> ReconstructionDatabaseTestFixtures.StateFixture {
    let task = ReconstructionTaskRecord(
        identity: foundation.task.identity,
        state: .running,
        diagnostic: nil
    )
    let checkpoint = try ReconstructionCheckpoint.make(
        checkpointID: foundation.checkpoint.checkpointID,
        schemaVersion: foundation.checkpoint.schemaVersion,
        jobID: foundation.checkpoint.jobID,
        revision: foundation.checkpoint.revision,
        parentCheckpointID: foundation.checkpoint.parentCheckpointID,
        parentCheckpointSHA256: foundation.checkpoint.parentCheckpointSHA256,
        corpusManifestSHA256: foundation.checkpoint.corpusManifestSHA256,
        evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
        pendingTaskIDs: [],
        runningTaskIDs: [task.identity.taskID],
        completedTaskIDs: [],
        failedTaskIDs: [],
        blockedTaskIDs: [],
        unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
        modelReceiptIDs: [],
        toolReceiptIDs: [],
        coordinatorState: .retrieving,
        terminalReason: nil
    )
    let job = try ReconstructionJobRecord(
        jobID: foundation.job.jobID,
        reconstructionProjectID: foundation.job.reconstructionProjectID,
        objective: foundation.job.objective,
        objectiveSHA256: foundation.job.objectiveSHA256,
        creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256,
        state: .retrieving,
        currentCheckpointID: checkpoint.checkpointID,
        terminalReason: nil,
        budget: foundation.job.budget,
        creationOrdinal: try XCTUnwrap(foundation.job.creationOrdinal),
        pauseContext: nil
    )
    let state = try ReconstructionWorkspaceState(
        schemaVersion: foundation.state.schemaVersion,
        projects: foundation.state.projects,
        corpusManifests: foundation.state.corpusManifests,
        evidence: foundation.state.evidence,
        evidenceRelations: foundation.state.evidenceRelations,
        evidenceGaps: foundation.state.evidenceGaps,
        jobs: [job],
        tasks: [task],
        checkpoints: [checkpoint],
        toolReceipts: [],
        modelReceipts: [],
        finalResults: foundation.state.finalResults
    )
    return .init(
        state: state,
        project: foundation.project,
        manifest: foundation.manifest,
        occurrence: foundation.occurrence,
        job: job,
        task: task,
        checkpoint: checkpoint
    )
}

private func pendingRecoveryMutation(
    from running: ReconstructionDatabaseTestFixtures.StateFixture
) throws -> ReconstructionCheckpointMutation {
    let successor = try ReconstructionCheckpoint.make(
        checkpointID: recoveryID(101),
        schemaVersion: running.checkpoint.schemaVersion,
        jobID: running.job.jobID,
        revision: running.checkpoint.revision + 1,
        parentCheckpointID: running.checkpoint.checkpointID,
        parentCheckpointSHA256: running.checkpoint.canonicalSHA256,
        corpusManifestSHA256: running.checkpoint.corpusManifestSHA256,
        evidenceFrontierSHA256: running.checkpoint.evidenceFrontierSHA256,
        pendingTaskIDs: [running.task.identity.taskID],
        runningTaskIDs: [],
        completedTaskIDs: [],
        failedTaskIDs: [],
        blockedTaskIDs: [],
        unresolvedEvidenceGapSHA256: running.checkpoint.unresolvedEvidenceGapSHA256,
        modelReceiptIDs: [],
        toolReceiptIDs: [],
        coordinatorState: .retrieving,
        terminalReason: nil
    )
    return ReconstructionCheckpointMutation(
        jobID: running.job.jobID,
        expectedParentCheckpointID: running.checkpoint.checkpointID,
        expectedParentCheckpointSHA256: running.checkpoint.canonicalSHA256,
        expectedParentRevision: running.checkpoint.revision,
        evidence: [],
        evidenceRelations: [],
        evidenceGaps: [],
        toolReceipts: [],
        modelReceipts: [],
        finalResults: [],
        newTasks: [],
        taskTransitions: [
            ReconstructionTaskTransition(
                taskID: running.task.identity.taskID,
                expectedState: .running,
                successorState: .pending,
                diagnostic: nil
            ),
        ],
        freshnessAuthority: try ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
            from: running
        ),
        successorCheckpoint: successor
    )
}

private func recoverySnapshot(
    tasks: [ReconstructionTaskRecord],
    terminalReceiptTaskIDs: Set<UUID>
) -> ReconstructionJobOrchestrationSnapshot {
    .init(
        jobID: recoveryID(1),
        jobCreationOrder: 1,
        checkpointID: recoveryID(99),
        checkpointRevision: 5,
        checkpointCorpusManifestSHA256: recoveryDigest(1),
        checkpointEvidenceFrontierSHA256: recoveryDigest(2),
        currentCorpusManifestSHA256: recoveryDigest(1),
        evidenceFrontierSHA256: recoveryDigest(2),
        currentDurableJobState: .retrieving,
        pauseContext: nil,
        maximumRoundsWithoutEvidence: 3,
        tasks: tasks,
        terminalReceiptStatesByTaskID: Dictionary(
            uniqueKeysWithValues: terminalReceiptTaskIDs.map { ($0, .completed) }
        )
    )
}

private func recoveryTask(id: Int, state: ReconstructionTaskState) throws -> ReconstructionTaskRecord {
    let identity = try ReconstructionTaskIdentity(
        taskID: recoveryID(id),
        jobID: recoveryID(1),
        kind: .retrieveEvidence,
        subject: nil,
        dependencyTaskIDs: [],
        operationContractIdentity: ReconstructionOperationID.evidenceQuery.rawValue,
        canonicalSHA256: recoveryDigest(id)
    )
    return .init(identity: identity, state: state, diagnostic: nil)
}

private func recoveryID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "54000000-0000-4000-8000-%012d", value))!
}

private func recoveryDigest(_ value: Int) -> String { String(format: "%064x", value) }

import XCTest

@testable import MacScope

final class ReconstructionJobCoordinatorTests: XCTestCase {
    func testMaxRoundsOneAllowsCommittedRefreshBatchBeforeNoProgressPause() async throws {
        let snapshot = try coordinatorRefreshSnapshot()
        XCTAssertEqual(snapshot.maximumRoundsWithoutEvidence, 1)
        XCTAssertEqual(snapshot.consecutiveModelRoundsWithoutEvidence, 1)
        let persistence = CoordinatorPersistence(snapshot: snapshot)
        // A batch terminal failure remains a truthful pause. The coordinator must allow the
        // planner to execute that batch instead of pausing before its first attempt.
        let planner = CoordinatorPlanner(plans: [coordinatorPlan(revision: 1, accepted: 0,
            disposition: .paused(.evidenceStalled))])
        let coordinator = ReconstructionJobCoordinator(persistence: persistence,
            planner: planner, publisher: CoordinatorPublisher())
        await coordinator.start(jobID: snapshot.jobID)
        let rounds = await planner.roundCount
        let controls = await planner.controlReasons
        XCTAssertEqual(rounds, 1)
        XCTAssertTrue(controls.isEmpty)
    }

    func testRefreshDeferralEndsAtTerminalResultAndRejectsUnboundTasks() throws {
        for terminal in [ReconstructionTaskState.completed, .failed, .cancelled] {
            XCTAssertFalse(try ReconstructionJobCoordinator.hasPendingAuthorizedAnalysisRefresh(
                coordinatorRefreshSnapshot(refreshState: terminal)))
        }
        XCTAssertTrue(try ReconstructionJobCoordinator.hasPendingAuthorizedAnalysisRefresh(
            coordinatorRefreshSnapshot()))
        XCTAssertFalse(try ReconstructionJobCoordinator.hasPendingAuthorizedAnalysisRefresh(
            coordinatorRefreshSnapshot(bindCheckpoint: false)))
        XCTAssertFalse(try ReconstructionJobCoordinator.hasPendingAuthorizedAnalysisRefresh(
            coordinatorRefreshSnapshot(completedModelReceipt: false)))
    }

    func testResumeCannotTurnExhaustedSuccessorBudgetIntoFailureAndCancelStillWorks() async throws {
        let jobID = coordinatorID(42)
        let tasks = try coordinatorPendingRegularTasks(jobID: jobID).map { task in
            ReconstructionTaskRecord(identity: task.identity, state: .completed,
                diagnostic: task.identity.kind == .checkpoint
                    ? .sanitizing(ReconstructionTaskBudgetPause.diagnostic) : nil)
        }
        let snapshot = coordinatorSnapshot(jobID: jobID, tasks: tasks,
            currentDurableJobState: .paused,
            pauseContext: try .init(cause: .evidenceStalled, resumeTarget: .retrieving))
        let persistence = CoordinatorPersistence(snapshot: snapshot)
        let coordinator = ReconstructionJobCoordinator(persistence: persistence,
            planner: CoordinatorPlanner(), publisher: CoordinatorPublisher())
        let resumed = await coordinator.resume(jobID: jobID, authority: coordinatorAuthority(snapshot))
        let commitsAfterResume = await persistence.commitCount
        XCTAssertFalse(resumed)
        XCTAssertEqual(commitsAfterResume, 0)
        let cancelled = await coordinator.cancel(jobID: jobID, authority: coordinatorAuthority(snapshot))
        XCTAssertTrue(cancelled)
    }
    func testCrashDuringRetryIgnoresPreviousAttemptTerminalReceipt() throws {
        let jobID = coordinatorID(41)
        let tasks = try coordinatorPendingRegularTasks(jobID: jobID).map { task in
            ReconstructionTaskRecord(identity: task.identity,
                state: task.identity.kind == .checkpoint ? .pending : .running, diagnostic: nil)
        }
        let model = try XCTUnwrap(tasks.first { $0.identity.kind == .modelRound })
        let original = coordinatorSnapshot(jobID: jobID)
        for oldState in [ReconstructionTaskState.failed, .cancelled] {
            let snapshot = ReconstructionJobOrchestrationSnapshot(
                jobID: jobID, jobCreationOrder: 1, checkpointID: original.checkpointID,
                checkpointRevision: 3,
                checkpointCorpusManifestSHA256: original.checkpointCorpusManifestSHA256,
                checkpointEvidenceFrontierSHA256: original.checkpointEvidenceFrontierSHA256,
                currentCorpusManifestSHA256: original.currentCorpusManifestSHA256,
                evidenceFrontierSHA256: original.evidenceFrontierSHA256,
                currentDurableJobState: .awaitingModel, pauseContext: nil,
                maximumRoundsWithoutEvidence: 3, tasks: tasks,
                terminalReceiptStatesByTaskID: [model.identity.taskID: oldState],
                terminalReceiptCheckpointRevisionsByTaskID: [model.identity.taskID: 1]
            )
            guard case .recover(let transitions) = ReconstructionCrashRecovery.plan(snapshot: snapshot) else {
                return XCTFail("Running retry must return to pending after a crash.")
            }
            XCTAssertEqual(transitions.count, 2)
            XCTAssertTrue(transitions.allSatisfy { $0.successorState == .pending })
        }
    }
    func testControlDuringAutomaticPausePublicationSettlesOnRunExit() async {
        let jobID = coordinatorID(40)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let cancellationGate = CoordinatorGate()
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .paused(.modelUnavailable)),
            coordinatorPlan(revision: 2, accepted: 0, disposition: .completed),
        ], cancellationGate: cancellationGate)
        let gate = CoordinatorGate()
        let coordinator = ReconstructionJobCoordinator(persistence: persistence,
            planner: planner, publisher: CoordinatorGatedPublisher(gate: gate))
        let running = Task { await coordinator.start(jobID: jobID) }
        await gate.waitUntilEntered()
        let cancelling = Task { await coordinator.cancel(jobID: jobID) }
        await planner.waitUntilCancelled()
        await gate.open()
        await running.value
        // Run exit has removed/rejected the pending control, but its cancellation
        // continuation is still held. Resuming it must not schedule another start.
        let unexpectedLoad = expectation(description: "Settled control starts no new run")
        unexpectedLoad.isInverted = true
        await persistence.forbidFurtherLoads(unexpectedLoad)
        await cancellationGate.open()
        await cancelling.value
        await fulfillment(of: [unexpectedLoad], timeout: 0.2)
        // An already committed successor invalidates the old control cut. It must settle,
        // then a fresh durable command can cancel the paused job.
        let count = await persistence.commitCount
        let rounds = await planner.roundCount
        let controls = await planner.controlReasons
        XCTAssertEqual(count, 1)
        XCTAssertEqual(rounds, 1)
        XCTAssertTrue(controls.isEmpty)
    }

    func testConsumedPauseControlDoesNotRestartAfterHeldCancellationReturns() async {
        let jobID = coordinatorID(43)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let roundGate = CoordinatorGate()
        let cancellationGate = CoordinatorGate()
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .continue),
            coordinatorPlan(revision: 2, accepted: 0, disposition: .completed),
        ], gate: roundGate, cancellationGate: cancellationGate)
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(persistence: persistence,
            planner: planner, publisher: publisher)
        let running = Task { await coordinator.start(jobID: jobID) }
        await roundGate.waitUntilEntered()
        let pausing = Task { await coordinator.pause(jobID: jobID,
            authority: coordinatorAuthority(coordinatorSnapshot(jobID: jobID))) }
        await planner.waitUntilCancelled()
        await roundGate.open()
        await running.value

        // The active run consumed and committed Pause while cancel remains suspended.
        // A successful completion must stay successful without resuming paused work.
        let unexpectedLoad = expectation(description: "Consumed pause starts no new run")
        unexpectedLoad.isInverted = true
        await persistence.forbidFurtherLoads(unexpectedLoad)
        await cancellationGate.open()
        let accepted = await pausing.value
        await fulfillment(of: [unexpectedLoad], timeout: 0.2)

        let commits = await persistence.commitCount
        let rounds = await planner.roundCount
        let controls = await planner.controlReasons
        let publications = await publisher.revisions
        let disposition = await publisher.lastDisposition
        XCTAssertTrue(accepted)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(rounds, 1)
        XCTAssertEqual(controls, [.pausedByUser])
        XCTAssertEqual(publications, [1])
        XCTAssertEqual(disposition, .paused(.pausedByUser))
    }
    func testSnapshotAdvancementCarriesExactDurablePauseAndTerminalTruth() throws {
        let active = coordinatorSnapshot(jobID: coordinatorID(11))
        let paused = try active.advancing(
            to: 1,
            disposition: .paused(.frontierMismatch)
        )
        XCTAssertEqual(paused.currentDurableJobState, .paused)
        XCTAssertEqual(paused.pauseContext?.cause, .frontierMismatch)
        XCTAssertEqual(paused.pauseContext?.resumeTarget, .retrieving)

        let cancelled = try paused.advancing(to: 2, disposition: .cancelled)
        XCTAssertEqual(cancelled.currentDurableJobState, .cancelled)
        XCTAssertNil(cancelled.pauseContext)

        let failed = try active.advancing(to: 1, disposition: .failed)
        XCTAssertEqual(failed.currentDurableJobState, .failed)
        XCTAssertNil(failed.pauseContext)
        XCTAssertThrowsError(
            try active.advancing(to: 1, disposition: .paused(.failed))
        )
    }

    func testInferenceBusyRetriesWithBoundedExponentialBackoffThenPauses() async {
        let jobID = coordinatorID(7)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(steps: Array(
            repeating: .failure(.inferenceBusy),
            count: 4
        ))
        let publisher = CoordinatorPublisher()
        let delays = CoordinatorDelayRecorder()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher,
            inferenceBusyBackoff: .init(
                initialDelayNanoseconds: 10,
                maximumDelayNanoseconds: 40,
                maximumAttempts: 3,
                maximumElapsedNanoseconds: 1_000
            ),
            sleep: { delay in await delays.record(delay) }
        )

        await coordinator.start(jobID: jobID)

        let recordedDelays = await delays.values
        let roundCount = await planner.roundCount
        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        XCTAssertEqual(recordedDelays, [10, 20, 40])
        XCTAssertEqual(roundCount, 4)
        XCTAssertEqual(controlReasons, [.inferenceBusy])
        XCTAssertEqual(disposition, .paused(.inferenceBusy))
    }

    func testInferenceBusyPausesWhenElapsedBackoffCeilingWouldBeExceeded() async {
        let jobID = coordinatorID(10)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(steps: Array(
            repeating: .failure(.inferenceBusy),
            count: 11
        ))
        let publisher = CoordinatorPublisher()
        let delays = CoordinatorDelayRecorder()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher,
            inferenceBusyBackoff: .init(
                initialDelayNanoseconds: 10,
                maximumDelayNanoseconds: 40,
                maximumAttempts: 10,
                maximumElapsedNanoseconds: 25
            ),
            sleep: { delay in await delays.record(delay) }
        )

        await coordinator.start(jobID: jobID)

        let recordedDelays = await delays.values
        let roundCount = await planner.roundCount
        let disposition = await publisher.lastDisposition
        XCTAssertEqual(recordedDelays, [10])
        XCTAssertEqual(roundCount, 2)
        XCTAssertEqual(disposition, .paused(.inferenceBusy))
    }

    func testInferenceBusyBackoffResetsAfterSuccessfulCommittedRound() async {
        let jobID = coordinatorID(8)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(steps: [
            .failure(.inferenceBusy),
            .plan(coordinatorPlan(revision: 1, accepted: 1, disposition: .continue)),
            .failure(.inferenceBusy),
            .failure(.inferenceBusy),
        ])
        let publisher = CoordinatorPublisher()
        let delays = CoordinatorDelayRecorder()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher,
            inferenceBusyBackoff: .init(
                initialDelayNanoseconds: 5,
                maximumDelayNanoseconds: 5,
                maximumAttempts: 1,
                maximumElapsedNanoseconds: 5
            ),
            sleep: { delay in await delays.record(delay) }
        )

        await coordinator.start(jobID: jobID)

        let recordedDelays = await delays.values
        let roundCount = await planner.roundCount
        let revisions = await publisher.revisions
        let disposition = await publisher.lastDisposition
        XCTAssertEqual(recordedDelays, [5, 5])
        XCTAssertEqual(roundCount, 4)
        XCTAssertEqual(revisions, [1, 2])
        XCTAssertEqual(disposition, .paused(.inferenceBusy))
    }

    func testCancellationInterruptsInferenceBusyBackoffAndCommitsCancellation() async {
        let jobID = coordinatorID(9)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(steps: [.failure(.inferenceBusy)])
        let publisher = CoordinatorPublisher()
        let sleeper = CoordinatorSleepProbe()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher,
            inferenceBusyBackoff: .init(
                initialDelayNanoseconds: 60_000_000_000,
                maximumDelayNanoseconds: 60_000_000_000,
                maximumAttempts: 3,
                maximumElapsedNanoseconds: 180_000_000_000
            ),
            sleep: { delay in
                await sleeper.recordStart()
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    await sleeper.recordCancellation()
                    throw error
                }
            }
        )
        let running = Task { await coordinator.start(jobID: jobID) }
        await sleeper.waitUntilStarted()

        await coordinator.cancel(jobID: jobID)
        await running.value

        let wasCancelled = await sleeper.wasCancelled
        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(controlReasons, [.cancelled])
        XCTAssertEqual(disposition, .cancelled)
    }

    func testCancellingDurablyPausedJobStartsATerminalControlCommit() async throws {
        let jobID = coordinatorID(12)
        let pauseContext = try ReconstructionJobPauseContext(
            cause: .pausedByUser,
            resumeTarget: .retrieving
        )
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(
            jobID: jobID,
            currentDurableJobState: .paused,
            pauseContext: pauseContext
        ))
        let planner = CoordinatorPlanner()
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )

        await coordinator.cancel(jobID: jobID)

        let reasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        let commitCount = await persistence.commitCount
        XCTAssertEqual(reasons, [.cancelled])
        XCTAssertEqual(disposition, .cancelled)
        XCTAssertEqual(commitCount, 1)
    }

    func testAutomaticRoundsPublishOnlyAfterCommitAndStopOnCompletion() async throws {
        let jobID = coordinatorID(1)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 1, disposition: .continue),
            coordinatorPlan(revision: 2, accepted: 0, disposition: .completed),
        ])
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )

        await coordinator.start(jobID: jobID)

        let events = await persistence.events
        let publications = await publisher.revisions
        let roundCount = await planner.roundCount
        XCTAssertEqual(events, ["load:0", "commit:1", "load:1", "commit:2"])
        XCTAssertEqual(publications, [1, 2])
        XCTAssertEqual(roundCount, 2)
    }

    func testReopenedJobAtDurableNoEvidenceBoundPausesBeforePendingRound() async throws {
        let jobID = coordinatorID(2)
        let persistence = CoordinatorPersistence(
            snapshot: coordinatorSnapshot(
                jobID: jobID,
                maximumRoundsWithoutEvidence: 2,
                tasks: try coordinatorPendingRegularTasks(jobID: jobID),
                consecutiveModelRoundsWithoutEvidence: 2
            )
        )
        let planner = CoordinatorPlanner()
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )

        await coordinator.start(jobID: jobID)

        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        let roundCount = await planner.roundCount
        XCTAssertEqual(controlReasons, [.evidenceStalled])
        XCTAssertEqual(disposition, .paused(.evidenceStalled))
        XCTAssertEqual(roundCount, 0)
    }

    func testModelUnavailableCommitsPauseWithoutPublishingUncommittedRound() async {
        let jobID = coordinatorID(3)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(error: .modelUnavailable)
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )

        await coordinator.start(jobID: jobID)

        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        let commitCount = await persistence.commitCount
        XCTAssertEqual(controlReasons, [.modelUnavailable])
        XCTAssertEqual(disposition, .paused(.modelUnavailable))
        XCTAssertEqual(commitCount, 1)
    }

    func testCancellationCommitsOneTerminalCheckpointAndDiscardsLatePlan() async {
        let jobID = coordinatorID(4)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let gate = CoordinatorGate()
        let planner = CoordinatorPlanner(
            plans: [coordinatorPlan(revision: 1, accepted: 1, disposition: .continue)],
            gate: gate
        )
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )
        let running = Task { await coordinator.start(jobID: jobID) }
        await gate.waitUntilEntered()

        let cancelling = Task { await coordinator.cancel(jobID: jobID) }
        await planner.waitUntilCancelled()
        await gate.open()
        await cancelling.value
        await running.value

        let commitCount = await persistence.commitCount
        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(controlReasons, [.cancelled])
        XCTAssertEqual(disposition, .cancelled)
    }

    func testPauseCancelsActivePlannerButCommitsPausedDisposition() async {
        let jobID = coordinatorID(13)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorCancellablePlanner()
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )
        let running = Task { await coordinator.start(jobID: jobID) }
        await planner.waitUntilRoundEntered()

        await coordinator.pause(jobID: jobID)
        await running.value

        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        let commitCount = await persistence.commitCount
        XCTAssertEqual(controlReasons, [.pausedByUser])
        XCTAssertEqual(disposition, .paused(.pausedByUser))
        XCTAssertEqual(commitCount, 1)
    }

    func testPauseControlSurvivesQueuedRestorationStartWinningActorScheduling() async throws {
        let jobID = coordinatorID(130)
        let snapshot = coordinatorSnapshot(jobID: jobID)
        let persistence = CoordinatorPersistence(snapshot: snapshot)
        let restartGate = CoordinatorGate()
        let decisionGate = CoordinatorGate()
        let queuedStartLoadGate = CoordinatorGate()
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .completed),
        ])
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher,
            controlRestartTestHook: { stage in
                switch stage {
                case .beforeRestart: await restartGate.enterAndWait()
                case .afterDecision: await decisionGate.enterAndWait()
                }
            }
        )

        let pause = Task {
            await coordinator.pause(jobID: jobID, authority: coordinatorAuthority(snapshot))
        }
        await restartGate.waitUntilEntered()

        // This start represents the already-admitted restoration call. Stop it after it owns
        // the coordinator token but before it can consume the queued Pause.
        await persistence.holdNextLoad(queuedStartLoadGate)
        let restorationStart = Task {
            await coordinator.start(jobID: jobID, authority: coordinatorAuthority(snapshot))
        }
        await queuedStartLoadGate.waitUntilEntered()

        // The control's redundant restart now observes the restoration token and must leave its
        // control installed for that run. The gate on the winning run makes the old bug exact.
        await restartGate.open()
        await decisionGate.waitUntilEntered()
        await queuedStartLoadGate.open()

        let pauseAccepted = await pause.value
        let startAccepted = await restorationStart.value
        let commitCount = await persistence.commitCount
        let controls = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        XCTAssertTrue(pauseAccepted)
        XCTAssertTrue(startAccepted)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(controls, [.pausedByUser])
        XCTAssertEqual(disposition, .paused(.pausedByUser))
        await decisionGate.open()
    }

    func testTransientSuspensionCancelsActivePlannerWithoutDurableDisposition() async {
        let jobID = coordinatorID(14)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorCancellablePlanner()
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )
        let running = Task { await coordinator.start(jobID: jobID) }
        await planner.waitUntilRoundEntered()

        await coordinator.suspendWithoutDurableDisposition(jobID: jobID)
        await running.value

        let controlReasons = await planner.controlReasons
        let publications = await publisher.revisions
        let commitCount = await persistence.commitCount
        XCTAssertTrue(controlReasons.isEmpty)
        XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(commitCount, 0)
    }

    func testUnexpectedPlannerErrorCommitsFailedCheckpoint() async {
        let jobID = coordinatorID(5)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(untypedError: true)
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )

        await coordinator.start(jobID: jobID)

        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        let commitCount = await persistence.commitCount
        XCTAssertEqual(controlReasons, [.failed])
        XCTAssertEqual(disposition, .failed)
        XCTAssertEqual(commitCount, 1)
    }

    func testCancellationRemainsTerminalWhenPauseArrivesBeforeRestart() async {
        let jobID = coordinatorID(6)
        let persistence = CoordinatorPersistence(snapshot: coordinatorSnapshot(jobID: jobID))
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .completed),
        ])
        let publisher = CoordinatorPublisher()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: publisher
        )

        await coordinator.cancel(jobID: jobID)
        await coordinator.pause(jobID: jobID)
        await coordinator.start(jobID: jobID)

        let controlReasons = await planner.controlReasons
        let disposition = await publisher.lastDisposition
        XCTAssertEqual(controlReasons, [.cancelled])
        XCTAssertEqual(disposition, .cancelled)
    }

    func testExactCommandAuthorityComparesAllSixPersistedBasisFieldsBeforeDispatch() async {
        let jobID = coordinatorID(31)
        let snapshot = coordinatorSnapshot(jobID: jobID)
        let exact = coordinatorAuthority(snapshot)
        let mismatches: [ReconstructionJobCommandAuthority] = [
            coordinatorAuthority(snapshot, jobID: coordinatorID(32)),
            coordinatorAuthority(snapshot, state: .indexing),
            coordinatorAuthority(snapshot, checkpointID: coordinatorID(33)),
            coordinatorAuthority(snapshot, checkpointRevision: 7),
            coordinatorAuthority(snapshot, corpusManifestSHA256: coordinatorDigest(91)),
            coordinatorAuthority(snapshot, evidenceFrontierSHA256: coordinatorDigest(92)),
        ]

        for authority in mismatches {
            let persistence = CoordinatorPersistence(snapshot: snapshot)
            let planner = CoordinatorPlanner(plans: [
                coordinatorPlan(revision: 1, accepted: 0, disposition: .completed),
            ])
            let coordinator = ReconstructionJobCoordinator(
                persistence: persistence,
                planner: planner,
                publisher: CoordinatorPublisher()
            )

            let accepted = await coordinator.start(jobID: jobID, authority: authority)

            let roundCount = await planner.roundCount
            let commitCount = await persistence.commitCount
            XCTAssertFalse(accepted, "accepted stale authority: \(authority)")
            XCTAssertEqual(roundCount, 0)
            XCTAssertEqual(commitCount, 0)
        }

        let persistence = CoordinatorPersistence(snapshot: snapshot)
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .completed),
        ])
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: CoordinatorPublisher()
        )
        let exactAccepted = await coordinator.start(jobID: jobID, authority: exact)
        XCTAssertTrue(exactAccepted)
        let exactCommitCount = await persistence.commitCount
        XCTAssertEqual(exactCommitCount, 1)
    }

    func testCheckpointCASLossRejectsCommandWithoutRetryingNewerSnapshot() async {
        let jobID = coordinatorID(34)
        let snapshot = coordinatorSnapshot(jobID: jobID)
        let persistence = CoordinatorPersistence(
            snapshot: snapshot,
            commitFailure: .checkpointConflict
        )
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .completed),
        ])
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: CoordinatorPublisher()
        )

        let accepted = await coordinator.start(
            jobID: jobID,
            authority: coordinatorAuthority(snapshot)
        )

        let events = await persistence.events
        let commitCount = await persistence.commitCount
        XCTAssertFalse(accepted)
        XCTAssertEqual(events, ["load:0", "commit:1"])
        XCTAssertEqual(commitCount, 1)
    }

    func testPendingControlRejectsStaleAuthorityBeforePlannerOrCommit() async {
        let jobID = coordinatorID(37)
        let snapshot = coordinatorSnapshot(jobID: jobID)
        let persistence = CoordinatorPersistence(snapshot: snapshot)
        let planner = CoordinatorPlanner()
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: CoordinatorPublisher()
        )
        let stale = coordinatorAuthority(
            snapshot,
            checkpointRevision: snapshot.checkpointRevision + 1
        )

        let accepted = await coordinator.pause(jobID: jobID, authority: stale)

        let controlReasons = await planner.controlReasons
        let commitCount = await persistence.commitCount
        XCTAssertFalse(accepted)
        XCTAssertTrue(controlReasons.isEmpty)
        XCTAssertEqual(commitCount, 0)
    }

    func testTransientRetirementPermanentlyRejectsLateStartForSessionOwnedCoordinator() async {
        let jobID = coordinatorID(35)
        let snapshot = coordinatorSnapshot(jobID: jobID)
        let persistence = CoordinatorPersistence(snapshot: snapshot)
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .completed),
        ])
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: CoordinatorPublisher()
        )

        await coordinator.suspendWithoutDurableDisposition(jobID: jobID)
        let accepted = await coordinator.start(
            jobID: jobID,
            authority: coordinatorAuthority(snapshot)
        )

        let events = await persistence.events
        let roundCount = await planner.roundCount
        XCTAssertFalse(accepted)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(roundCount, 0)
    }

    func testResumeAtPersistedNoEvidenceBoundAllowsExplicitRetry() async throws {
        let jobID = coordinatorID(36)
        let pauseContext = try ReconstructionJobPauseContext(
            cause: .evidenceStalled,
            resumeTarget: .retrieving
        )
        let snapshot = coordinatorSnapshot(
            jobID: jobID,
            maximumRoundsWithoutEvidence: 2,
            tasks: try coordinatorPendingRegularTasks(jobID: jobID),
            currentDurableJobState: .paused,
            pauseContext: pauseContext,
            consecutiveModelRoundsWithoutEvidence: 2
        )
        let persistence = CoordinatorPersistence(snapshot: snapshot)
        let planner = CoordinatorPlanner(plans: [
            coordinatorPlan(revision: 1, accepted: 0, disposition: .continue),
            coordinatorPlan(revision: 2, accepted: 0, disposition: .completed),
        ])
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence,
            planner: planner,
            publisher: CoordinatorPublisher()
        )

        let accepted = await coordinator.resume(
            jobID: jobID,
            authority: coordinatorAuthority(snapshot)
        )

        let commitCount = await persistence.commitCount
        let controlReasons = await planner.controlReasons
        XCTAssertTrue(accepted)
        XCTAssertEqual(commitCount, 2)
        XCTAssertTrue(controlReasons.isEmpty)
    }
}

private enum CoordinatorUntypedError: Error { case failed }

private enum CoordinatorPlannerStep: Sendable {
    case plan(ReconstructionJobCommitPlan)
    case failure(ReconstructionJobCoordinatorFailure)
}

private actor CoordinatorPersistence: ReconstructionJobOrchestrationPersisting {
    private var snapshot: ReconstructionJobOrchestrationSnapshot
    private let commitFailure: ReconstructionJobCoordinatorFailure?
    private var unexpectedLoad: XCTestExpectation?
    private var nextLoadGate: CoordinatorGate?
    private(set) var events: [String] = []
    private(set) var commitCount = 0

    init(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        commitFailure: ReconstructionJobCoordinatorFailure? = nil
    ) {
        self.snapshot = snapshot
        self.commitFailure = commitFailure
    }

    func load(jobID: UUID) async throws -> ReconstructionJobOrchestrationSnapshot {
        if let nextLoadGate {
            self.nextLoadGate = nil
            await nextLoadGate.enterAndWait()
        }
        if let unexpectedLoad {
            self.unexpectedLoad = nil
            unexpectedLoad.fulfill()
        }
        events.append("load:\(snapshot.checkpointRevision)")
        return snapshot
    }

    func forbidFurtherLoads(_ expectation: XCTestExpectation) {
        unexpectedLoad = expectation
    }

    func holdNextLoad(_ gate: CoordinatorGate) {
        nextLoadGate = gate
    }

    func commit(
        _ plan: ReconstructionJobCommitPlan,
        for snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitReceipt {
        commitCount += 1
        events.append("commit:\(plan.successorRevision)")
        if let commitFailure { throw commitFailure }
        self.snapshot = try self.snapshot.advancing(
            to: plan.successorRevision,
            disposition: plan.disposition
        )
        return .init(
            jobID: snapshot.jobID,
            checkpointRevision: plan.successorRevision,
            evidenceFrontierSHA256: self.snapshot.evidenceFrontierSHA256,
            disposition: plan.disposition
        )
    }
}

private actor CoordinatorPlanner: ReconstructionJobRoundPlanning {
    private var plans: [ReconstructionJobCommitPlan]
    private var steps: [CoordinatorPlannerStep]
    private let error: ReconstructionJobCoordinatorFailure?
    private let untypedError: Bool
    private let gate: CoordinatorGate?
    private let cancellationGate: CoordinatorGate?
    private var cancelled = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var roundCount = 0
    private(set) var controlReasons: [ReconstructionJobPauseReason] = []

    init(
        plans: [ReconstructionJobCommitPlan] = [],
        steps: [CoordinatorPlannerStep] = [],
        error: ReconstructionJobCoordinatorFailure? = nil,
        untypedError: Bool = false,
        gate: CoordinatorGate? = nil,
        cancellationGate: CoordinatorGate? = nil
    ) {
        self.plans = plans
        self.steps = steps
        self.error = error
        self.untypedError = untypedError
        self.gate = gate
        self.cancellationGate = cancellationGate
    }

    func planRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        roundCount += 1
        if let gate { await gate.enterAndWait() }
        if !steps.isEmpty {
            switch steps.removeFirst() {
            case .plan(let plan): return plan
            case .failure(let failure): throw failure
            }
        }
        if let error { throw error }
        if untypedError { throw CoordinatorUntypedError.failed }
        return plans.removeFirst()
    }

    func planRecovery(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        coordinatorPlan(revision: snapshot.checkpointRevision + 1, accepted: 0, disposition: .continue)
    }

    func planControl(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        controlReasons.append(reason)
        return coordinatorPlan(
            revision: snapshot.checkpointRevision + 1,
            accepted: 0,
            disposition: reason.controlDisposition
        )
    }

    func cancel(jobID: UUID) async {
        cancelled = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
        if let cancellationGate { await cancellationGate.enterAndWait() }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

private actor CoordinatorCancellablePlanner: ReconstructionJobRoundPlanning {
    private var activeTask: Task<ReconstructionJobCommitPlan, Error>?
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var controlReasons: [ReconstructionJobPauseReason] = []

    func planRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        recordRoundEntered()
        let task = Task { () throws -> ReconstructionJobCommitPlan in
            try await Task.sleep(for: .seconds(30))
            return coordinatorPlan(
                revision: snapshot.checkpointRevision + 1,
                accepted: 0,
                disposition: .continue
            )
        }
        activeTask = task
        defer { activeTask = nil }
        return try await task.value
    }

    func planRecovery(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        coordinatorPlan(
            revision: snapshot.checkpointRevision + 1,
            accepted: 0,
            disposition: .continue
        )
    }

    func planControl(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        controlReasons.append(reason)
        return coordinatorPlan(
            revision: snapshot.checkpointRevision + 1,
            accepted: 0,
            disposition: reason.controlDisposition
        )
    }

    func cancel(jobID: UUID) async {
        activeTask?.cancel()
    }

    func waitUntilRoundEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    private func recordRoundEntered() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }
}

private actor CoordinatorDelayRecorder {
    private(set) var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
}

private actor CoordinatorSleepProbe {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func recordStart() {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func recordCancellation() {
        wasCancelled = true
    }
}

private actor CoordinatorPublisher: ReconstructionJobStatusPublishing {
    private(set) var revisions: [UInt64] = []
    private(set) var lastDisposition: ReconstructionJobCoordinatorDisposition?
    func publish(_ receipt: ReconstructionJobCommitReceipt) async {
        revisions.append(receipt.checkpointRevision)
        lastDisposition = receipt.disposition
    }
}

private struct CoordinatorGatedPublisher: ReconstructionJobStatusPublishing {
    let gate: CoordinatorGate
    func publish(_ receipt: ReconstructionJobCommitReceipt) async {
        await gate.enterAndWait()
    }
}

private actor CoordinatorGate {
    private var entered = false
    private var openState = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if openState { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() {
        openState = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}

private func coordinatorSnapshot(
    jobID: UUID,
    checkpointID: UUID = coordinatorID(900),
    maximumRoundsWithoutEvidence: Int = 3,
    tasks: [ReconstructionTaskRecord] = [],
    terminalReceiptTaskIDs: Set<UUID> = [],
    currentDurableJobState: ReconstructionJobState = .retrieving,
    pauseContext: ReconstructionJobPauseContext? = nil,
    consecutiveModelRoundsWithoutEvidence: Int = 0
) -> ReconstructionJobOrchestrationSnapshot {
    .init(
        jobID: jobID,
        jobCreationOrder: 1,
        checkpointID: checkpointID,
        checkpointRevision: 0,
        checkpointCorpusManifestSHA256: coordinatorDigest(1),
        checkpointEvidenceFrontierSHA256: coordinatorDigest(2),
        currentCorpusManifestSHA256: coordinatorDigest(1),
        evidenceFrontierSHA256: coordinatorDigest(2),
        currentDurableJobState: currentDurableJobState,
        pauseContext: pauseContext,
        maximumRoundsWithoutEvidence: maximumRoundsWithoutEvidence,
        tasks: tasks,
        terminalReceiptStatesByTaskID: Dictionary(
            uniqueKeysWithValues: terminalReceiptTaskIDs.map { ($0, .completed) }
        ),
        consecutiveModelRoundsWithoutEvidence: consecutiveModelRoundsWithoutEvidence
    )
}

private func coordinatorRefreshSnapshot(
    refreshState: ReconstructionTaskState = .pending,
    bindCheckpoint: Bool = true,
    completedModelReceipt: Bool = true
) throws -> ReconstructionJobOrchestrationSnapshot {
    let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: UUID())
    let jobID = foundation.job.jobID
    let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
        contentIdentity: foundation.occurrence.contentIdentity)
    let image = ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
        selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
    let function = try ReconstructionFunctionCoordinate(artifact: artifact, image: image,
        analysisFingerprintSHA256: coordinatorDigest(3), startAddress: 0x1000,
        endAddressExclusive: 0x1010, boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
        functionUUIDHint: nil, symbolHint: nil)
    let prior = try coordinatorPendingRegularTasks(jobID: jobID).map {
        ReconstructionTaskRecord(identity: $0.identity, state: .completed, diagnostic: nil)
    }
    let checkpoint = try XCTUnwrap(prior.first { $0.identity.kind == .checkpoint })
    let model = try XCTUnwrap(prior.first { $0.identity.kind == .modelRound })
    let enumeration = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
        taskID: UUID(), jobID: jobID, kind: .enumerateFunctions,
        subject: .image(try ReconstructionImageCoordinate(artifact: artifact, image: image,
            analysisFingerprintSHA256: function.analysisFingerprintSHA256)),
        dependencyTaskIDs: [], operationContractIdentity: "reconstruction.enumerateFunctions.v1"),
        state: .completed, diagnostic: nil)
    let refresh = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
        taskID: UUID(), jobID: jobID, kind: .decompileMacScope, subject: .function(function),
        dependencyTaskIDs: [enumeration.identity.taskID, bindCheckpoint ? checkpoint.identity.taskID : UUID()],
        operationContractIdentity: "reconstruction.decompileMacScope.v1"),
        state: refreshState, diagnostic: nil)
    var successor = try coordinatorPendingRegularTasks(jobID: jobID)
    let retrieve = successor[0]
    successor[0] = .init(identity: try ReconstructionTaskIdentity.make(
        taskID: retrieve.identity.taskID, jobID: jobID, kind: .retrieveEvidence, subject: nil,
        dependencyTaskIDs: [checkpoint.identity.taskID, refresh.identity.taskID],
        operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery),
        state: .pending, diagnostic: nil)
    return coordinatorSnapshot(jobID: jobID, maximumRoundsWithoutEvidence: 1,
        tasks: prior + [enumeration, refresh] + successor,
        terminalReceiptTaskIDs: completedModelReceipt ? [model.identity.taskID] : [],
        consecutiveModelRoundsWithoutEvidence: 1)
}

private func coordinatorAuthority(
    _ snapshot: ReconstructionJobOrchestrationSnapshot,
    jobID: UUID? = nil,
    state: ReconstructionJobState? = nil,
    checkpointID: UUID? = nil,
    checkpointRevision: UInt64? = nil,
    corpusManifestSHA256: String? = nil,
    evidenceFrontierSHA256: String? = nil
) -> ReconstructionJobCommandAuthority {
    ReconstructionJobCommandAuthority(
        jobID: jobID ?? snapshot.jobID,
        expectedJobState: state ?? snapshot.currentDurableJobState,
        checkpointID: checkpointID ?? snapshot.checkpointID,
        checkpointRevision: checkpointRevision ?? snapshot.checkpointRevision,
        corpusManifestSHA256: corpusManifestSHA256
            ?? snapshot.currentCorpusManifestSHA256,
        evidenceFrontierSHA256: evidenceFrontierSHA256
            ?? snapshot.evidenceFrontierSHA256
    )
}

private func coordinatorPendingRegularTasks(
    jobID: UUID
) throws -> [ReconstructionTaskRecord] {
    let retrieveID = UUID()
    let modelID = UUID()
    return [
        ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: retrieveID,
                jobID: jobID,
                kind: .retrieveEvidence,
                subject: nil,
                dependencyTaskIDs: [UUID()],
                operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery
            ),
            state: .pending,
            diagnostic: nil
        ),
        ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: modelID,
                jobID: jobID,
                kind: .modelRound,
                subject: nil,
                dependencyTaskIDs: [retrieveID],
                operationContractIdentity: ReconstructionProductionTaskContract.modelRound
            ),
            state: .pending,
            diagnostic: nil
        ),
        ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: UUID(),
                jobID: jobID,
                kind: .checkpoint,
                subject: nil,
                dependencyTaskIDs: [modelID],
                operationContractIdentity: ReconstructionProductionTaskContract.checkpoint
            ),
            state: .pending,
            diagnostic: nil
        ),
    ]
}

private func coordinatorPlan(
    revision: UInt64,
    accepted: Int,
    disposition: ReconstructionJobCoordinatorDisposition
) -> ReconstructionJobCommitPlan {
    .init(
        successorRevision: revision,
        acceptedEvidenceCount: accepted,
        disposition: disposition,
        mutation: nil
    )
}

private func coordinatorID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "53000000-0000-4000-8000-%012d", value))!
}

private func coordinatorDigest(_ value: Int) -> String { String(format: "%064x", value) }

import Foundation
import XCTest
@testable import MacScope

private func jobSessionAuthority(
    _ jobID: UUID,
    state: ReconstructionJobState = .retrieving
) -> ReconstructionJobCommandAuthority {
    ReconstructionJobCommandAuthority(
        jobID: jobID,
        expectedJobState: state,
        checkpointID: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
        checkpointRevision: 1,
        corpusManifestSHA256: String(repeating: "a", count: 64),
        evidenceFrontierSHA256: String(repeating: "b", count: 64)
    )
}

final class ReconstructionJobSessionTests: XCTestCase {
    func testSettledResumeRejectsDuplicateCutButAllowsNewPausedCheckpoint() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(durableJobID: jobID,
            coordinator: coordinator, scheduler: JobSessionSchedulerProbe(events: events))
        let first = jobSessionAuthority(jobID, state: .paused)
        let second = ReconstructionJobCommandAuthority(jobID: first.jobID,
            expectedJobState: .paused, checkpointID: first.checkpointID,
            checkpointRevision: first.checkpointRevision + 1,
            corpusManifestSHA256: first.corpusManifestSHA256,
            evidenceFrontierSHA256: first.evidenceFrontierSHA256)
        let accepted = await session.resume(authority: first)
        let duplicate = await session.resume(authority: first)
        let resumedNewCheckpoint = await session.resume(authority: second)
        XCTAssertTrue(accepted)
        XCTAssertFalse(duplicate)
        XCTAssertTrue(resumedNewCheckpoint)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.resumeIDs, [jobID, jobID])
    }
    func testCompletedActivationReleasesLifecycleForAutomaticPauseResume() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: JobSessionSchedulerProbe(events: events)
        )
        let started = await session.start(authority: jobSessionAuthority(jobID))
        let resumed = await session.resume(authority: jobSessionAuthority(jobID, state: .paused))
        XCTAssertTrue(started)
        XCTAssertTrue(resumed)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.resumeIDs, [jobID])
    }
    func testEveryControlRemainsBoundToItsCapturedDurableJobIdentity() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events)
        let firstScheduler = JobSessionSchedulerProbe(events: events)
        let secondScheduler = JobSessionSchedulerProbe(events: events)
        let firstJobID = UUID()
        let secondJobID = UUID()
        let first = ReconstructionJobSession(
            durableJobID: firstJobID,
            coordinator: coordinator,
            scheduler: firstScheduler
        )
        let second = ReconstructionJobSession(
            durableJobID: secondJobID,
            coordinator: coordinator,
            scheduler: secondScheduler
        )

        await first.start(authority: jobSessionAuthority(firstJobID))
        await first.pause(authority: jobSessionAuthority(firstJobID))
        await first.resume(authority: jobSessionAuthority(firstJobID, state: .paused))
        await first.cancel(authority: jobSessionAuthority(firstJobID))
        await second.retire()

        let coordinatorSnapshot = await coordinator.snapshot()
        let firstSchedulerSnapshot = await firstScheduler.snapshot()
        let secondSchedulerSnapshot = await secondScheduler.snapshot()
        XCTAssertEqual(
            coordinatorSnapshot.startIDs,
            [firstJobID]
        )
        XCTAssertEqual(coordinatorSnapshot.pauseIDs, [firstJobID])
        XCTAssertEqual(coordinatorSnapshot.resumeIDs, [firstJobID])
        XCTAssertEqual(coordinatorSnapshot.cancelIDs, [firstJobID])
        XCTAssertEqual(coordinatorSnapshot.suspendIDs, [secondJobID])
        XCTAssertEqual(firstSchedulerSnapshot.pauseIDs, [firstJobID])
        XCTAssertEqual(firstSchedulerSnapshot.resumeIDs, [firstJobID])
        XCTAssertEqual(firstSchedulerSnapshot.retireIDs, [firstJobID])
        XCTAssertEqual(secondSchedulerSnapshot.retireIDs, [secondJobID])
    }

    func testPauseWaitsForDurableCoordinatorRunBeforeSchedulerQuiescence() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events, blockStarts: true)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let start = Task { await session.start(authority: jobSessionAuthority(jobID)) }
        await coordinator.waitUntilStartEntered()
        let pause = Task { await session.pause(authority: jobSessionAuthority(jobID)) }
        await coordinator.waitUntilPauseEntered()
        let schedulerBeforeDurablePause = await scheduler.snapshot()
        XCTAssertTrue(schedulerBeforeDurablePause.pauseIDs.isEmpty)

        await coordinator.releaseStarts()
        _ = await start.value
        await pause.value

        let entries = await events.snapshot()
        XCTAssertEqual(
            entries,
            ["coordinator.start", "coordinator.pause", "coordinator.start.finished", "scheduler.pause"]
        )
    }

    func testRetireUsesTransientSuspensionAndIsIdempotent() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        await session.retire()
        await session.retire()
        await session.cancel(authority: jobSessionAuthority(jobID))
        await session.start(authority: jobSessionAuthority(jobID))
        await session.pause(authority: jobSessionAuthority(jobID))
        await session.resume(authority: jobSessionAuthority(jobID, state: .paused))

        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertEqual(coordinatorSnapshot.suspendIDs, [jobID])
        XCTAssertTrue(coordinatorSnapshot.cancelIDs.isEmpty)
        XCTAssertTrue(coordinatorSnapshot.startIDs.isEmpty)
        XCTAssertTrue(coordinatorSnapshot.pauseIDs.isEmpty)
        XCTAssertTrue(coordinatorSnapshot.resumeIDs.isEmpty)
        XCTAssertEqual(schedulerSnapshot.retireIDs, [jobID])
    }

    func testFreshSessionResumesDurablyPausedJobWithoutPreexistingSchedulerChild() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        await session.resume(authority: jobSessionAuthority(jobID, state: .paused))
        await coordinator.waitUntilResumeEntered()
        await session.resume(authority: jobSessionAuthority(jobID, state: .paused))

        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertEqual(coordinatorSnapshot.resumeIDs, [jobID])
        XCTAssertTrue(schedulerSnapshot.resumeIDs.isEmpty)
        XCTAssertTrue(schedulerSnapshot.retireIDs.isEmpty)
    }

    func testCancelCommitsDurableControlBeforeSchedulerRetirement() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events, blockCancels: true)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let cancellation = Task {
            await session.cancel(authority: jobSessionAuthority(jobID))
        }
        await coordinator.waitUntilCancelEntered()
        let schedulerBeforeDurableCancel = await scheduler.snapshot()
        XCTAssertTrue(schedulerBeforeDurableCancel.retireIDs.isEmpty)

        await coordinator.releaseCancels()
        await cancellation.value

        let entries = await events.snapshot()
        XCTAssertEqual(
            entries,
            ["coordinator.cancel", "coordinator.cancel.finished", "scheduler.retire"]
        )
    }

    func testImmediateStartThenRetireCannotLeaveALateRunOrSchedulerAuthority() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events, blockStarts: true)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let start = Task { await session.start(authority: jobSessionAuthority(jobID)) }
        await coordinator.waitUntilStartEntered()
        let retirement = Task { await session.retire() }
        await coordinator.waitUntilSuspendEntered()
        await coordinator.releaseStarts()

        let accepted = await start.value
        await retirement.value
        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinatorSnapshot.startIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.suspendIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.retireIDs, [jobID])
        let lateStartAccepted = await session.start(authority: jobSessionAuthority(jobID))
        XCTAssertFalse(lateStartAccepted)
    }

    func testImmediateFreshResumeThenRetireCannotLeaveALateRunOrSchedulerAuthority() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events, blockResumes: true)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let resume = Task {
            await session.resume(authority: jobSessionAuthority(jobID, state: .paused))
        }
        await coordinator.waitUntilResumeEntered()
        let retirement = Task { await session.retire() }
        await coordinator.waitUntilSuspendEntered()
        await coordinator.releaseResumes()

        let accepted = await resume.value
        await retirement.value
        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinatorSnapshot.resumeIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.suspendIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.retireIDs, [jobID])
        XCTAssertTrue(schedulerSnapshot.resumeIDs.isEmpty)
    }

    func testRejectedResumeRequiescesExistingSchedulerAndRemainsPaused() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(events: events, resumeResult: false)
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )
        _ = await session.start(authority: jobSessionAuthority(jobID))
        _ = await session.pause(authority: jobSessionAuthority(jobID))

        let accepted = await session.resume(
            authority: jobSessionAuthority(jobID, state: .paused)
        )

        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertFalse(accepted)
        XCTAssertEqual(schedulerSnapshot.resumeIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.pauseIDs, [jobID, jobID])
        let secondAccepted = await session.resume(
            authority: jobSessionAuthority(jobID, state: .paused)
        )
        XCTAssertFalse(secondAccepted, "rejection must restore the paused lifecycle")
    }

    func testRetireAfterRejectedInFlightCancelStillSuspendsAndRetiresExactlyOnce() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(
            events: events,
            blockCancels: true,
            cancelResult: false
        )
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let cancellation = Task {
            await session.cancel(authority: jobSessionAuthority(jobID))
        }
        await coordinator.waitUntilCancelEntered()
        let retirement = Task { await session.retire() }
        await coordinator.releaseCancels()

        let cancelled = await cancellation.value
        await retirement.value
        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(coordinatorSnapshot.cancelIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.suspendIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.retireIDs, [jobID])
        let lateStart = await session.start(authority: jobSessionAuthority(jobID))
        XCTAssertFalse(lateStart)
    }

    func testStartWaitingOnRejectedCancelRestoresThePriorReadyLifecycle() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(
            events: events,
            blockCancels: true,
            cancelResult: false
        )
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let cancellation = Task {
            await session.cancel(authority: jobSessionAuthority(jobID))
        }
        await coordinator.waitUntilCancelEntered()
        let start = Task {
            await session.start(authority: jobSessionAuthority(jobID))
        }
        await coordinator.releaseCancels()

        let cancelled = await cancellation.value
        let started = await start.value
        XCTAssertFalse(cancelled)
        XCTAssertTrue(started)
        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertEqual(coordinatorSnapshot.cancelIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.startIDs, [jobID])
        XCTAssertTrue(coordinatorSnapshot.suspendIDs.isEmpty)
        XCTAssertTrue(schedulerSnapshot.retireIDs.isEmpty)
    }

    func testResumeContinuesAfterRejectedCancelRestoresItsRunningAdmission() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(
            events: events,
            blockCancels: true,
            cancelResult: false
        )
        let scheduler = JobSessionSchedulerProbe(events: events, blockResumes: true)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )
        _ = await session.start(authority: jobSessionAuthority(jobID))
        _ = await session.pause(authority: jobSessionAuthority(jobID))

        let resume = Task {
            await session.resume(authority: jobSessionAuthority(jobID, state: .paused))
        }
        await scheduler.waitUntilResumeEntered()
        let cancellation = Task {
            await session.cancel(authority: jobSessionAuthority(jobID, state: .paused))
        }
        await coordinator.waitUntilCancelEntered()
        await scheduler.releaseResumes()
        await coordinator.releaseCancels()

        let cancelled = await cancellation.value
        let resumed = await resume.value
        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertFalse(cancelled)
        XCTAssertTrue(resumed)
        XCTAssertEqual(coordinatorSnapshot.cancelIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.resumeIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.resumeIDs, [jobID])
        XCTAssertEqual(
            schedulerSnapshot.pauseIDs,
            [jobID],
            "the initial durable pause is the only scheduler pause"
        )
    }

    func testPauseContinuesAfterRejectedCancelRestoresItsPausingAdmission() async {
        let events = JobSessionEventLog()
        let coordinator = JobSessionCoordinatorProbe(
            events: events,
            blockPauses: true,
            blockCancels: true,
            cancelResult: false
        )
        let scheduler = JobSessionSchedulerProbe(events: events)
        let jobID = UUID()
        let session = ReconstructionJobSession(
            durableJobID: jobID,
            coordinator: coordinator,
            scheduler: scheduler
        )

        let pause = Task {
            await session.pause(authority: jobSessionAuthority(jobID))
        }
        await coordinator.waitUntilPauseEntered()
        let cancellation = Task {
            await session.cancel(authority: jobSessionAuthority(jobID))
        }
        await coordinator.waitUntilCancelEntered()
        await coordinator.releasePauses()
        await coordinator.releaseCancels()

        let cancelled = await cancellation.value
        let paused = await pause.value
        let resumed = await session.resume(
            authority: jobSessionAuthority(jobID, state: .paused)
        )
        let coordinatorSnapshot = await coordinator.snapshot()
        let schedulerSnapshot = await scheduler.snapshot()
        XCTAssertFalse(cancelled)
        XCTAssertTrue(paused)
        XCTAssertTrue(resumed, "the session must not remain stranded in .pausing")
        XCTAssertEqual(coordinatorSnapshot.cancelIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.pauseIDs, [jobID])
        XCTAssertEqual(coordinatorSnapshot.resumeIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.pauseIDs, [jobID])
        XCTAssertEqual(schedulerSnapshot.resumeIDs, [jobID])
    }
}

private actor JobSessionEventLog {
    private var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }

    func snapshot() -> [String] { entries }
}

private struct JobSessionCoordinatorSnapshot: Sendable {
    let startIDs: [UUID]
    let pauseIDs: [UUID]
    let resumeIDs: [UUID]
    let cancelIDs: [UUID]
    let suspendIDs: [UUID]
}

private actor JobSessionCoordinatorProbe: ReconstructionJobSessionCoordinating {
    private let events: JobSessionEventLog
    private let blockStarts: Bool
    private let blockPauses: Bool
    private let blockResumes: Bool
    private let blockCancels: Bool
    private let resumeResult: Bool
    private let cancelResult: Bool
    private var startsReleased = false
    private var pausesReleased = false
    private var cancelsReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var startEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var startIDs: [UUID] = []
    private var pauseIDs: [UUID] = []
    private var resumeIDs: [UUID] = []
    private var cancelIDs: [UUID] = []
    private var suspendIDs: [UUID] = []

    init(
        events: JobSessionEventLog,
        blockStarts: Bool = false,
        blockPauses: Bool = false,
        blockResumes: Bool = false,
        blockCancels: Bool = false,
        resumeResult: Bool = true,
        cancelResult: Bool = true
    ) {
        self.events = events
        self.blockStarts = blockStarts
        self.blockPauses = blockPauses
        self.blockResumes = blockResumes
        self.blockCancels = blockCancels
        self.resumeResult = resumeResult
        self.cancelResult = cancelResult
    }

    func start(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        startIDs.append(jobID)
        await events.append("coordinator.start")
        startEnteredWaiters.forEach { $0.resume() }
        startEnteredWaiters.removeAll()
        if blockStarts, !startsReleased {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        await events.append("coordinator.start.finished")
        return true
    }

    func pause(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        pauseIDs.append(jobID)
        await events.append("coordinator.pause")
        pauseEnteredWaiters.forEach { $0.resume() }
        pauseEnteredWaiters.removeAll()
        if blockPauses, !pausesReleased {
            await withCheckedContinuation { pauseWaiters.append($0) }
        }
        return true
    }

    func resume(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        resumeIDs.append(jobID)
        await events.append("coordinator.resume")
        resumeEnteredWaiters.forEach { $0.resume() }
        resumeEnteredWaiters.removeAll()
        if blockResumes {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        await events.append("coordinator.resume.finished")
        return resumeResult
    }

    func cancel(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        cancelIDs.append(jobID)
        await events.append("coordinator.cancel")
        cancelEnteredWaiters.forEach { $0.resume() }
        cancelEnteredWaiters.removeAll()
        if blockCancels, !cancelsReleased {
            await withCheckedContinuation { cancelWaiters.append($0) }
        }
        await events.append("coordinator.cancel.finished")
        return cancelResult
    }

    func suspendWithoutDurableDisposition(jobID: UUID) async {
        suspendIDs.append(jobID)
        await events.append("coordinator.suspend")
        suspendEnteredWaiters.forEach { $0.resume() }
        suspendEnteredWaiters.removeAll()
    }

    func waitUntilStartEntered() async {
        if !startIDs.isEmpty { return }
        await withCheckedContinuation { startEnteredWaiters.append($0) }
    }

    func waitUntilPauseEntered() async {
        if !pauseIDs.isEmpty { return }
        await withCheckedContinuation { pauseEnteredWaiters.append($0) }
    }

    func waitUntilCancelEntered() async {
        if !cancelIDs.isEmpty { return }
        await withCheckedContinuation { cancelEnteredWaiters.append($0) }
    }

    func waitUntilResumeEntered() async {
        if !resumeIDs.isEmpty { return }
        await withCheckedContinuation { resumeEnteredWaiters.append($0) }
    }

    func waitUntilSuspendEntered() async {
        if !suspendIDs.isEmpty { return }
        await withCheckedContinuation { suspendEnteredWaiters.append($0) }
    }

    func releaseStarts() {
        startsReleased = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func releaseResumes() {
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }

    func releasePauses() {
        pausesReleased = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
    }

    func releaseCancels() {
        cancelsReleased = true
        cancelWaiters.forEach { $0.resume() }
        cancelWaiters.removeAll()
    }

    func snapshot() -> JobSessionCoordinatorSnapshot {
        .init(
            startIDs: startIDs,
            pauseIDs: pauseIDs,
            resumeIDs: resumeIDs,
            cancelIDs: cancelIDs,
            suspendIDs: suspendIDs
        )
    }
}

private struct JobSessionSchedulerSnapshot: Sendable {
    let pauseIDs: [UUID]
    let resumeIDs: [UUID]
    let retireIDs: [UUID]
}

private actor JobSessionSchedulerProbe: ReconstructionJobSessionScheduling {
    private let events: JobSessionEventLog
    private let blockResumes: Bool
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseIDs: [UUID] = []
    private var resumeIDs: [UUID] = []
    private var retireIDs: [UUID] = []

    init(events: JobSessionEventLog, blockResumes: Bool = false) {
        self.events = events
        self.blockResumes = blockResumes
    }

    func pause(jobID: UUID) async {
        pauseIDs.append(jobID)
        await events.append("scheduler.pause")
    }

    func resume(jobID: UUID) async {
        resumeIDs.append(jobID)
        await events.append("scheduler.resume")
        resumeEnteredWaiters.forEach { $0.resume() }
        resumeEnteredWaiters.removeAll()
        if blockResumes {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
    }

    func retire(jobID: UUID) async {
        retireIDs.append(jobID)
        await events.append("scheduler.retire")
    }

    func snapshot() -> JobSessionSchedulerSnapshot {
        .init(pauseIDs: pauseIDs, resumeIDs: resumeIDs, retireIDs: retireIDs)
    }

    func waitUntilResumeEntered() async {
        if !resumeIDs.isEmpty { return }
        await withCheckedContinuation { resumeEnteredWaiters.append($0) }
    }

    func releaseResumes() {
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

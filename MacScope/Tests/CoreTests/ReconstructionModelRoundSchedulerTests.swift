#if MACSCOPE_MODEL_ROUND_SCHEDULER_STANDALONE
import Foundation
#else
import XCTest

@testable import MacScope
#endif

#if !MACSCOPE_MODEL_ROUND_SCHEDULER_STANDALONE
final class ReconstructionModelRoundSchedulerTests: XCTestCase {
    func testQueuedRoundsUseCreationOrderThenCheckpointRevisionAndNeverOverlap() async throws {
        let scheduler = ReconstructionModelRoundScheduler()
        let gate = SchedulerGate()
        let recorder = SchedulerRecorder()

        let active = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(9), jobCreationOrder: 0, checkpointRevision: 0)
            ) {
                await recorder.begin("active")
                await gate.wait()
                await recorder.end("active")
            }
        }
        await recorder.waitForBegins(1)

        let later = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(2), jobCreationOrder: 2, checkpointRevision: 1)
            ) {
                await recorder.begin("later")
                await recorder.end("later")
            }
        }
        let earlierRevision = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(1), jobCreationOrder: 1, checkpointRevision: 2)
            ) {
                await recorder.begin("early-r2")
                await recorder.end("early-r2")
            }
        }
        let earlier = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(1), jobCreationOrder: 1, checkpointRevision: 1)
            ) {
                await recorder.begin("early-r1")
                await recorder.end("early-r1")
            }
        }

        await scheduler.waitUntilQueuedAdmissionCount(3)
        await gate.open()
        _ = try await (active.value, later.value, earlierRevision.value, earlier.value)

        let events = await recorder.events
        let maximumConcurrent = await recorder.maximumConcurrent
        XCTAssertEqual(
            events,
            ["begin:active", "end:active", "begin:early-r1", "end:early-r1",
             "begin:early-r2", "end:early-r2", "begin:later", "end:later"]
        )
        XCTAssertEqual(maximumConcurrent, 1)
    }

    func testCancelledQueuedRoundNeverRuns() async throws {
        let scheduler = ReconstructionModelRoundScheduler()
        let gate = SchedulerGate()
        let recorder = SchedulerRecorder()
        let active = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(1), jobCreationOrder: 1, checkpointRevision: 0)
            ) {
                await recorder.begin("active")
                await gate.wait()
                await recorder.end("active")
            }
        }
        await recorder.waitForBegins(1)
        let cancelled = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(2), jobCreationOrder: 2, checkpointRevision: 0)
            ) {
                await recorder.begin("cancelled")
                await recorder.end("cancelled")
            }
        }
        cancelled.cancel()
        await gate.open()
        _ = try await active.value
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let events = await recorder.events
        XCTAssertFalse(events.contains("begin:cancelled"))
    }

    func testCancellationAfterGrantBeforeOperationLeavesNoTombstoneAndReleasesLease()
        async throws
    {
        let result = try await ReconstructionModelRoundSchedulerCancellationAfterGrantProbe.run()

        XCTAssertEqual(
            result.events,
            ["begin:active", "end:active", "begin:successor", "end:successor"]
        )
        XCTAssertFalse(result.cancelledOperationRan)
        XCTAssertEqual(
            result.snapshot,
            .init(
                activeLeaseCount: 0,
                queuedAdmissionCount: 0,
                pendingEnqueueCount: 0,
                cancelledWaiterTombstoneCount: 0
            )
        )
    }
}
#endif

struct ReconstructionModelRoundSchedulerCancellationAfterGrantProbe {
    struct Result: Equatable, Sendable {
        let events: [String]
        let cancelledOperationRan: Bool
        let snapshot: ReconstructionModelRoundSchedulerSnapshot
    }

    static func run() async throws -> Result {
        let cancelledJobID = schedulerID(2)
        let grantBarrier = SchedulerAdmissionGrantBarrier(targetJobID: cancelledJobID)
        let scheduler = ReconstructionModelRoundScheduler { admission in
            await grantBarrier.pauseIfTarget(admission.jobID)
        }
        let activeGate = SchedulerGate()
        let recorder = SchedulerRecorder()

        let active = Task {
            try await scheduler.withAdmission(
                .init(jobID: schedulerID(1), jobCreationOrder: 1, checkpointRevision: 0)
            ) {
                await recorder.begin("active")
                await activeGate.wait()
                await recorder.end("active")
            }
        }
        await recorder.waitForBegins(1)

        let cancelled = Task {
            try await scheduler.withAdmission(
                .init(jobID: cancelledJobID, jobCreationOrder: 2, checkpointRevision: 0)
            ) {
                await recorder.begin("cancelled")
                await recorder.end("cancelled")
            }
        }
        await scheduler.waitUntilQueuedAdmissionCount(1)
        await activeGate.open()
        try await active.value
        await grantBarrier.waitUntilPaused()

        cancelled.cancel()
        await scheduler.waitUntilCancellationObservationCount(1)
        await grantBarrier.open()
        do {
            try await cancelled.value
            throw SchedulerProbeError.cancelledOperationRan
        } catch is CancellationError {}

        try await scheduler.withAdmission(
            .init(jobID: schedulerID(3), jobCreationOrder: 3, checkpointRevision: 0)
        ) {
            await recorder.begin("successor")
            await recorder.end("successor")
        }
        let events = await recorder.events
        return .init(
            events: events,
            cancelledOperationRan: events.contains("begin:cancelled"),
            snapshot: await scheduler.snapshot()
        )
    }
}

private actor SchedulerGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if openState { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        openState = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor SchedulerAdmissionGrantBarrier {
    private let targetJobID: UUID
    private var isPaused = false
    private var isOpen = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var blockedAdmissions: [CheckedContinuation<Void, Never>] = []

    init(targetJobID: UUID) {
        self.targetJobID = targetJobID
    }

    func pauseIfTarget(_ jobID: UUID) async {
        guard jobID == targetJobID else { return }
        isPaused = true
        pauseObservers.forEach { $0.resume() }
        pauseObservers.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { blockedAdmissions.append($0) }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseObservers.append($0) }
    }

    func open() {
        isOpen = true
        blockedAdmissions.forEach { $0.resume() }
        blockedAdmissions.removeAll()
    }
}

private actor SchedulerRecorder {
    private(set) var events: [String] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    private var beginWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func begin(_ value: String) {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        events.append("begin:\(value)")
        let ready = beginWaiters.filter { events.filter { $0.hasPrefix("begin:") }.count >= $0.0 }
        beginWaiters.removeAll { events.filter { $0.hasPrefix("begin:") }.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func end(_ value: String) {
        events.append("end:\(value)")
        concurrent -= 1
    }
    func waitForBegins(_ count: Int) async {
        if events.filter({ $0.hasPrefix("begin:") }).count >= count { return }
        await withCheckedContinuation { beginWaiters.append((count, $0)) }
    }
}

private func schedulerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "52000000-0000-4000-8000-%012d", value))!
}

private enum SchedulerProbeError: Error {
    case cancelledOperationRan
}

#if MACSCOPE_MODEL_ROUND_SCHEDULER_STANDALONE
@main
private enum ReconstructionModelRoundSchedulerStandaloneProof {
    static func main() async throws {
        let result = try await ReconstructionModelRoundSchedulerCancellationAfterGrantProbe.run()
        guard result.events
                == ["begin:active", "end:active", "begin:successor", "end:successor"],
              !result.cancelledOperationRan,
              result.snapshot == .init(
                activeLeaseCount: 0,
                queuedAdmissionCount: 0,
                pendingEnqueueCount: 0,
                cancelledWaiterTombstoneCount: 0
              ) else {
            throw SchedulerProbeError.cancelledOperationRan
        }
        print("scheduler cancel-after-grant proof: passed")
    }
}
#endif

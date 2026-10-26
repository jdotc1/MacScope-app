import Synchronization
import XCTest

@testable import MacScope

// MARK: - Test support

/// A flag an injected operation can spin on without suspending. Used to prove that the scheduler
/// runs submitted work off its own executor; nothing else in the suite needs shared memory.
private final class AtomicFlag: Sendable {
    private let storage = Atomic<Bool>(false)

    var isSet: Bool { storage.load(ordering: .acquiring) }

    func set() { storage.store(true, ordering: .releasing) }
}

/// A controllable suspension point for injected operations.
///
/// Operations park here instead of sleeping, so every ordering assertion in this suite is driven
/// by an explicit release rather than by elapsed time. `enter()` is cancellation-cooperative: it
/// throws `CancellationError` when the awaiting task is cancelled, which is what lets the tests
/// exercise the scheduler's cancellation and shutdown paths against work that actually unwinds.
private actor AsyncGate {
    private var isOpen = false
    private var arrivalCount = 0
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeSuspension: Set<Int> = []
    private var arrivalWatchers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextWaiterID = 0

    /// Records an arrival, then suspends until `open()` or cancellation.
    func enter() async throws {
        arrivalCount += 1
        releaseArrivalWatchers()
        if isOpen { return }

        nextWaiterID += 1
        let waiterID = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeSuspension.remove(waiterID) != nil {
                    continuation.resume(throwing: CancellationError())
                } else if isOpen {
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }

    /// Suspends until at least `count` operations have reached `enter()`.
    func waitForArrivals(_ count: Int) async {
        if arrivalCount >= count { return }
        await withCheckedContinuation { continuation in
            arrivalWatchers.append((count, continuation))
        }
    }

    private func cancelWaiter(_ waiterID: Int) {
        if let continuation = waiters.removeValue(forKey: waiterID) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeSuspension.insert(waiterID)
        }
    }

    private func releaseArrivalWatchers() {
        var stillWaiting: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for watcher in arrivalWatchers {
            if arrivalCount >= watcher.threshold {
                watcher.continuation.resume()
            } else {
                stillWaiting.append(watcher)
            }
        }
        arrivalWatchers = stillWaiting
    }
}

/// A suspension point that deliberately keeps a cancelled operation parked until the test opens
/// it. This models cooperative cleanup that has observed cancellation but still needs time to
/// drain before the single-capacity lane may start its successor.
private actor UncancellableGate {
    private var isOpen = false
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWatchers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enter() async {
        arrivalCount += 1
        releaseArrivalWatchers()
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitForArrivals(_ count: Int) async {
        if arrivalCount >= count { return }
        await withCheckedContinuation { continuation in
            arrivalWatchers.append((count, continuation))
        }
    }

    private func releaseArrivalWatchers() {
        var stillWaiting: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for watcher in arrivalWatchers {
            if arrivalCount >= watcher.threshold {
                watcher.continuation.resume()
            } else {
                stillWaiting.append(watcher)
            }
        }
        arrivalWatchers = stillWaiting
    }
}

/// Synchronous admission capture for the scheduler's synchronous `@Sendable` callback.
private final class AdmissionRecorder: Sendable {
    private let storage = Mutex<[FairSingleLaneSubmissionAdmission]>([])

    var admissions: [FairSingleLaneSubmissionAdmission] {
        storage.withLock { $0 }
    }

    func record(_ admission: FairSingleLaneSubmissionAdmission) {
        storage.withLock { $0.append(admission) }
    }
}

/// Ordered log of operation lifecycle events.
private actor EventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}

/// Observes how many injected operations are ever in flight simultaneously.
private actor ConcurrencyProbe {
    private var inFlight = 0
    private(set) var peak = 0

    func begin() {
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func end() {
        inFlight -= 1
    }
}

private struct TestOperationFailure: Error, Equatable {
    let label: String
}

final class FairSingleLaneWorkSchedulerTests: XCTestCase {
    private typealias TestScheduler = FairSingleLaneWorkScheduler<String, String, String>
    private typealias SubmissionTask = Task<Result<String, any Error>, Never>

    // MARK: - Harness

    /// Launches a submission and hands back its terminal outcome without letting the task throw,
    /// so a test can inspect a cancelled or rejected submission the same way it inspects a success.
    private func submit(
        _ scheduler: TestScheduler,
        owner: String,
        key: String,
        queuedWeight: UInt64 = 0,
        admissionRecorder: AdmissionRecorder? = nil,
        operation: @escaping @Sendable () async throws -> String
    ) -> SubmissionTask {
        Task {
            do {
                return .success(
                    try await scheduler.submit(
                        owner: owner,
                        key: key,
                        queuedWeight: queuedWeight,
                        admission: { admissionRecorder?.record($0) },
                        operation: operation
                    )
                )
            } catch {
                return .failure(error)
            }
        }
    }

    /// Barrier that suspends until the scheduler reports the expected occupancy.
    ///
    /// This yields the cooperative pool rather than sleeping, so it carries no wall-clock
    /// assumption: every state this suite waits for belongs to a transition that has already been
    /// scheduled, so the wait converges. The iteration bound exists only so that a scheduler defect
    /// surfaces as a test failure instead of an indefinite hang.
    private func waitForScheduler(
        _ scheduler: TestScheduler,
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @Sendable @escaping (FairSingleLaneSchedulerSnapshot) -> Bool
    ) async {
        for _ in 0..<200_000 {
            if predicate(await scheduler.snapshot()) { return }
            await Task.yield()
        }
        XCTFail("Scheduler never reached the expected state", file: file, line: line)
    }

    /// Submits work that is expected to queue, and waits until it has actually been registered.
    /// Registering one entry at a time is what makes queue position — and therefore the fairness
    /// assertions below — deterministic without relying on task start order.
    @discardableResult
    private func enqueue(
        _ scheduler: TestScheduler,
        owner: String,
        key: String,
        expectingQueueDepth depth: Int,
        queuedWeight: UInt64 = 0,
        admissionRecorder: AdmissionRecorder? = nil,
        operation: @escaping @Sendable () async throws -> String
    ) async -> SubmissionTask {
        let task = submit(
            scheduler,
            owner: owner,
            key: key,
            queuedWeight: queuedWeight,
            admissionRecorder: admissionRecorder,
            operation: operation
        )
        await waitForScheduler(scheduler) { $0.queuedEntryCount == depth }
        return task
    }

    /// An operation that logs its start, optionally parks on `gate`, then returns `name`.
    private func gatedOperation(
        recorder: EventRecorder,
        gate: AsyncGate?,
        name: String
    ) -> @Sendable () async throws -> String {
        {
            await recorder.record(name)
            if let gate {
                try await gate.enter()
            }
            return name
        }
    }

    private func assertSchedulerError(
        _ result: Result<String, any Error>,
        _ expected: FairSingleLaneSchedulerError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTFail("Expected \(expected), got success(\(value))", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error as? FairSingleLaneSchedulerError, expected, file: file, line: line)
        }
    }

    private func assertCancelled(
        _ result: Result<String, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTFail("Expected CancellationError, got success(\(value))", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    private func assertSuccess(
        _ result: Result<String, any Error>,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTAssertEqual(value, expected, file: file, line: line)
        case .failure(let error):
            XCTFail("Expected success(\(expected)), got failure(\(error))", file: file, line: line)
        }
    }

    private func assertIdentifierSpaceExhausted(
        _ result: Result<String, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTFail("Expected identifier exhaustion, got success(\(value))", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(
                error is FairSingleLaneIdentifierExhaustionError,
                "Expected FairSingleLaneIdentifierExhaustionError, got \(error)",
                file: file,
                line: line
            )
        }
    }

    /// How many times an operation reached a given lifecycle event. The sample is taken before the
    /// assertion because `XCTAssertEqual`'s autoclosure cannot carry an `await`.
    private func assertRecordCount(
        _ recorder: EventRecorder,
        _ event: String,
        _ expected: Int,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await recorder.count(of: event)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    /// Every test ends here: no waiter, no queued entry, and no active entry may survive.
    private func assertDrained(
        _ scheduler: TestScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.waiterCount, 0, "leaked waiters", file: file, line: line)
        XCTAssertEqual(snapshot.queuedEntryCount, 0, "leaked queued entries", file: file, line: line)
        XCTAssertEqual(snapshot.queuedWeight, 0, "leaked queued weight", file: file, line: line)
        XCTAssertFalse(snapshot.hasActiveEntry, "leaked active entry", file: file, line: line)
    }

    // MARK: - 1. One operation active at a time

    func testRunsAtMostOneOperationAtATime() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 64)
        let probe = ConcurrencyProbe()

        var tasks: [SubmissionTask] = []
        for index in 0..<24 {
            tasks.append(
                submit(scheduler, owner: "owner-\(index % 4)", key: "key-\(index)") {
                    await probe.begin()
                    // Several suspensions widen the window in which an overlapping operation
                    // would be observed if the lane ever admitted two.
                    for _ in 0..<8 { await Task.yield() }
                    await probe.end()
                    return "key-\(index)"
                }
            )
        }

        for task in tasks {
            _ = await task.value
        }

        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "The lane admitted more than one concurrent operation")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 2. FIFO within one owner

    func testPreservesFIFOOrderWithinAnOwner() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let first = submit(scheduler, owner: "A", key: "A1", operation: gatedOperation(recorder: recorder, gate: gate, name: "A1"))
        await gate.waitForArrivals(1)

        let second = await enqueue(scheduler, owner: "A", key: "A2", expectingQueueDepth: 1,
                                   operation: gatedOperation(recorder: recorder, gate: nil, name: "A2"))
        let third = await enqueue(scheduler, owner: "A", key: "A3", expectingQueueDepth: 2,
                                  operation: gatedOperation(recorder: recorder, gate: nil, name: "A3"))

        await gate.open()
        assertSuccess(await first.value, "A1")
        assertSuccess(await second.value, "A2")
        assertSuccess(await third.value, "A3")

        let events = await recorder.events
        XCTAssertEqual(events, ["A1", "A2", "A3"])
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 3. Round-robin across owners

    func testRotatesRoundRobinAcrossOwners() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 16)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let a1 = submit(scheduler, owner: "A", key: "A1", operation: gatedOperation(recorder: recorder, gate: gate, name: "A1"))
        await gate.waitForArrivals(1)

        // Registered one at a time so that queue position and ring order are both deterministic.
        let a2 = await enqueue(scheduler, owner: "A", key: "A2", expectingQueueDepth: 1,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "A2"))
        let b1 = await enqueue(scheduler, owner: "B", key: "B1", expectingQueueDepth: 2,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "B1"))
        let c1 = await enqueue(scheduler, owner: "C", key: "C1", expectingQueueDepth: 3,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "C1"))
        let b2 = await enqueue(scheduler, owner: "B", key: "B2", expectingQueueDepth: 4,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "B2"))
        let c2 = await enqueue(scheduler, owner: "C", key: "C2", expectingQueueDepth: 5,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "C2"))

        await gate.open()
        for task in [a1, a2, b1, c1, b2, c2] {
            _ = await task.value
        }

        // A held the lane, so the rotation serves B and C before A's own second entry.
        let events = await recorder.events
        XCTAssertEqual(events, ["A1", "B1", "C1", "A2", "B2", "C2"])
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 4. A newcomer beats the busy owner's backlog

    func testNewOwnerRunsBeforeTheActiveOwnersNextEntry() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let a1 = submit(scheduler, owner: "A", key: "A1", operation: gatedOperation(recorder: recorder, gate: gate, name: "A1"))
        await gate.waitForArrivals(1)

        // A2 is registered strictly before B1, so plain FIFO would run it first.
        let a2 = await enqueue(scheduler, owner: "A", key: "A2", expectingQueueDepth: 1,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "A2"))
        let b1 = await enqueue(scheduler, owner: "B", key: "B1", expectingQueueDepth: 2,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "B1"))

        await gate.open()
        for task in [a1, a2, b1] {
            _ = await task.value
        }

        let events = await recorder.events
        XCTAssertEqual(events, ["A1", "B1", "A2"])
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 5. Duplicate queued key

    func testDuplicateQueuedKeyExecutesOnceAndSharesOneResult() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active", operation: gatedOperation(recorder: recorder, gate: gate, name: "active"))
        await gate.waitForArrivals(1)

        let firstWaiter = await enqueue(scheduler, owner: "A", key: "shared", expectingQueueDepth: 1,
                                        operation: gatedOperation(recorder: recorder, gate: nil, name: "shared-first"))

        // A different owner submitting the same key must not create a second entry, and its own
        // closure must be ignored in favour of the authoritative first submission.
        let secondWaiter = submit(scheduler, owner: "B", key: "shared") {
            await recorder.record("shared-second")
            return "shared-second"
        }
        await waitForScheduler(scheduler) { $0.waiterCount == 3 }
        let queued = await scheduler.snapshot()
        XCTAssertEqual(queued.queuedEntryCount, 1, "A duplicate key must not add a queued entry")

        await gate.open()
        assertSuccess(await active.value, "active")
        assertSuccess(await firstWaiter.value, "shared-first")
        assertSuccess(await secondWaiter.value, "shared-first")

        let events = await recorder.events
        await assertRecordCount(recorder, "shared-first", 1)
        await assertRecordCount(recorder, "shared-second", 0, "The later duplicate's closure must be ignored")
        XCTAssertEqual(events, ["active", "shared-first"])
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 6. Duplicate active key

    func testDuplicateActiveKeyExecutesOnceAndSharesOneResult() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let first = submit(scheduler, owner: "A", key: "shared", operation: gatedOperation(recorder: recorder, gate: gate, name: "shared"))
        await gate.waitForArrivals(1)

        let second = submit(scheduler, owner: "B", key: "shared") {
            await recorder.record("second-closure")
            return "second-closure"
        }
        await waitForScheduler(scheduler) { $0.waiterCount == 2 }
        let occupancy = await scheduler.snapshot()
        XCTAssertEqual(occupancy.queuedEntryCount, 0, "Joining the active entry must not queue anything")
        XCTAssertTrue(occupancy.hasActiveEntry)

        await gate.open()
        assertSuccess(await first.value, "shared")
        assertSuccess(await second.value, "shared")
        await assertRecordCount(recorder, "second-closure", 0)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 7. Cancelling one duplicate waiter

    func testCancellingOneDuplicateWaiterLeavesTheOperationAndSiblingIntact() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let keeper = submit(scheduler, owner: "A", key: "shared") {
            await recorder.record("shared")
            try await gate.enter()
            // Reached only if the operation was never cancelled.
            await recorder.record("shared-completed")
            return "shared"
        }
        await gate.waitForArrivals(1)

        let doomed = submit(scheduler, owner: "B", key: "shared") { "ignored" }
        await waitForScheduler(scheduler) { $0.waiterCount == 2 }

        doomed.cancel()
        assertCancelled(await doomed.value)

        // The operation still has a waiter, so it must keep running.
        await waitForScheduler(scheduler) { $0.waiterCount == 1 }
        let stillActive = await scheduler.snapshot()
        XCTAssertTrue(stillActive.hasActiveEntry)

        await gate.open()
        assertSuccess(await keeper.value, "shared")
        await assertRecordCount(recorder, "shared-completed", 1, "The operation must not have been cancelled")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 8. Cancelling the final queued waiter

    func testCancellingTheFinalQueuedWaiterRemovesTheEntry() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active", operation: gatedOperation(recorder: recorder, gate: gate, name: "active"))
        await gate.waitForArrivals(1)

        let doomed = await enqueue(scheduler, owner: "B", key: "queued", expectingQueueDepth: 1,
                                   operation: gatedOperation(recorder: recorder, gate: nil, name: "queued"))

        doomed.cancel()
        assertCancelled(await doomed.value)
        await waitForScheduler(scheduler) { $0.queuedEntryCount == 0 }

        await gate.open()
        assertSuccess(await active.value, "active")

        let events = await recorder.events
        XCTAssertEqual(events, ["active"], "The abandoned entry must never execute")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 9. Cancelling the final active waiter

    func testCancellingTheFinalActiveWaiterCancelsTheOperationThenAdvances() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let activeGate = AsyncGate()

        let doomed = submit(scheduler, owner: "A", key: "active") {
            await recorder.record("active-started")
            do {
                try await activeGate.enter()
            } catch {
                await recorder.record("active-cancelled")
                throw error
            }
            await recorder.record("active-completed")
            return "active"
        }
        await activeGate.waitForArrivals(1)

        let successor = await enqueue(scheduler, owner: "B", key: "next", expectingQueueDepth: 1,
                                      operation: gatedOperation(recorder: recorder, gate: nil, name: "next"))

        doomed.cancel()
        assertCancelled(await doomed.value)

        // Losing its last waiter cancels the operation; the lane then advances on its own.
        assertSuccess(await successor.value, "next")

        let events = await recorder.events
        XCTAssertEqual(events, ["active-started", "active-cancelled", "next"])
        await assertRecordCount(recorder, "active-completed", 0)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 10. Queue bound

    func testQueueBoundCountsUniqueEntriesAndRejectsOnlyTheNewSubmission() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 1)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active", operation: gatedOperation(recorder: recorder, gate: gate, name: "active"))
        await gate.waitForArrivals(1)

        let queued = await enqueue(scheduler, owner: "A", key: "queued", expectingQueueDepth: 1,
                                   operation: gatedOperation(recorder: recorder, gate: nil, name: "queued"))

        // Duplicates of the queued and the active key add waiters, not entries, so the bound
        // must not reject either of them.
        let duplicateOfQueued = submit(scheduler, owner: "B", key: "queued") { "ignored" }
        let duplicateOfActive = submit(scheduler, owner: "C", key: "active") { "ignored" }
        await waitForScheduler(scheduler) { $0.waiterCount == 4 }

        // A genuinely new unique entry has nowhere to go.
        let rejected = submit(scheduler, owner: "D", key: "overflow") {
            await recorder.record("overflow")
            return "overflow"
        }
        assertSchedulerError(await rejected.value, .queueLimitReached(limit: 1))

        await gate.open()
        assertSuccess(await active.value, "active")
        assertSuccess(await duplicateOfActive.value, "active")
        assertSuccess(await queued.value, "queued")
        assertSuccess(await duplicateOfQueued.value, "queued")
        await assertRecordCount(recorder, "overflow", 0)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testZeroBoundRunsImmediatelyWhenIdleAndRejectsWorkThatWouldQueue() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 0)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        // An idle lane never queues, so a zero bound still admits work.
        let active = submit(scheduler, owner: "A", key: "active", operation: gatedOperation(recorder: recorder, gate: gate, name: "active"))
        await gate.waitForArrivals(1)

        let rejected = submit(scheduler, owner: "B", key: "queued") { "queued" }
        assertSchedulerError(await rejected.value, .queueLimitReached(limit: 0))

        await gate.open()
        assertSuccess(await active.value, "active")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - Weighted admission

    func testReportsStartedQueuedJoinedActiveAndJoinedQueued() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8, maximumQueuedWeight: 32)
        let recorder = EventRecorder()
        let gate = AsyncGate()
        let startedAdmission = AdmissionRecorder()
        let queuedAdmission = AdmissionRecorder()
        let joinedActiveAdmission = AdmissionRecorder()
        let joinedQueuedAdmission = AdmissionRecorder()

        let active = submit(
            scheduler,
            owner: "A",
            key: "active",
            queuedWeight: 31,
            admissionRecorder: startedAdmission,
            operation: gatedOperation(recorder: recorder, gate: gate, name: "active")
        )
        await gate.waitForArrivals(1)

        let queued = await enqueue(
            scheduler,
            owner: "B",
            key: "queued",
            expectingQueueDepth: 1,
            queuedWeight: 7,
            admissionRecorder: queuedAdmission,
            operation: gatedOperation(recorder: recorder, gate: nil, name: "queued")
        )
        let joinedActive = submit(
            scheduler,
            owner: "C",
            key: "active",
            queuedWeight: .max,
            admissionRecorder: joinedActiveAdmission
        ) { "ignored-active-duplicate" }
        await waitForScheduler(scheduler) { $0.waiterCount == 3 }

        let joinedQueued = submit(
            scheduler,
            owner: "D",
            key: "queued",
            queuedWeight: .max,
            admissionRecorder: joinedQueuedAdmission
        ) { "ignored-queued-duplicate" }
        await waitForScheduler(scheduler) { $0.waiterCount == 4 }

        XCTAssertEqual(
            startedAdmission.admissions,
            [.init(disposition: .started, queuedEntryCount: 0, queuedWeight: 0)]
        )
        XCTAssertEqual(
            queuedAdmission.admissions,
            [.init(disposition: .queued, queuedEntryCount: 1, queuedWeight: 7)]
        )
        XCTAssertEqual(
            joinedActiveAdmission.admissions,
            [.init(disposition: .joinedActive, queuedEntryCount: 1, queuedWeight: 7)]
        )
        XCTAssertEqual(
            joinedQueuedAdmission.admissions,
            [.init(disposition: .joinedQueued, queuedEntryCount: 1, queuedWeight: 7)]
        )

        await gate.open()
        assertSuccess(await active.value, "active")
        assertSuccess(await joinedActive.value, "active")
        assertSuccess(await queued.value, "queued")
        assertSuccess(await joinedQueued.value, "queued")

        // Each accepted waiter receives one callback, never a second callback at completion.
        XCTAssertEqual(startedAdmission.admissions.count, 1)
        XCTAssertEqual(queuedAdmission.admissions.count, 1)
        XCTAssertEqual(joinedActiveAdmission.admissions.count, 1)
        XCTAssertEqual(joinedQueuedAdmission.admissions.count, 1)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testQueuedWeightAcceptsExactLimitAndRejectsLimitPlusOne() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8, maximumQueuedWeight: .max)
        let gate = AsyncGate()
        let exactAdmission = AdmissionRecorder()
        let rejectedAdmission = AdmissionRecorder()

        let active = submit(scheduler, owner: "A", key: "active") {
            try await gate.enter()
            return "active"
        }
        await gate.waitForArrivals(1)

        let exact = await enqueue(
            scheduler,
            owner: "B",
            key: "exact-limit",
            expectingQueueDepth: 1,
            queuedWeight: .max,
            admissionRecorder: exactAdmission
        ) { "exact-limit" }
        let rejected = submit(
            scheduler,
            owner: "C",
            key: "limit-plus-one",
            queuedWeight: 1,
            admissionRecorder: rejectedAdmission
        ) { "limit-plus-one" }

        assertSchedulerError(await rejected.value, .queuedWeightLimitReached(limit: .max))
        XCTAssertTrue(rejectedAdmission.admissions.isEmpty, "Rejected waiters must not receive admission")
        XCTAssertEqual(
            exactAdmission.admissions,
            [.init(disposition: .queued, queuedEntryCount: 1, queuedWeight: .max)]
        )
        let atLimit = await scheduler.snapshot()
        XCTAssertEqual(atLimit.queuedEntryCount, 1)
        XCTAssertEqual(atLimit.queuedWeight, .max)

        await gate.open()
        assertSuccess(await active.value, "active")
        assertSuccess(await exact.value, "exact-limit")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testDuplicateActiveAndQueuedKeysAddZeroQueuedWeight() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8, maximumQueuedWeight: 5)
        let gate = AsyncGate()
        let joinedActiveAdmission = AdmissionRecorder()
        let joinedQueuedAdmission = AdmissionRecorder()

        let active = submit(scheduler, owner: "A", key: "active", queuedWeight: .max) {
            try await gate.enter()
            return "active"
        }
        await gate.waitForArrivals(1)

        let queued = await enqueue(
            scheduler,
            owner: "B",
            key: "queued",
            expectingQueueDepth: 1,
            queuedWeight: 5
        ) { "queued" }
        let joinedActive = submit(
            scheduler,
            owner: "C",
            key: "active",
            queuedWeight: .max,
            admissionRecorder: joinedActiveAdmission
        ) { "ignored-active-duplicate" }
        await waitForScheduler(scheduler) { $0.waiterCount == 3 }
        let joinedQueued = submit(
            scheduler,
            owner: "D",
            key: "queued",
            queuedWeight: .max,
            admissionRecorder: joinedQueuedAdmission
        ) { "ignored-queued-duplicate" }
        await waitForScheduler(scheduler) { $0.waiterCount == 4 }

        let afterDuplicates = await scheduler.snapshot()
        XCTAssertEqual(afterDuplicates.queuedEntryCount, 1)
        XCTAssertEqual(afterDuplicates.queuedWeight, 5)
        XCTAssertEqual(
            joinedActiveAdmission.admissions,
            [.init(disposition: .joinedActive, queuedEntryCount: 1, queuedWeight: 5)]
        )
        XCTAssertEqual(
            joinedQueuedAdmission.admissions,
            [.init(disposition: .joinedQueued, queuedEntryCount: 1, queuedWeight: 5)]
        )

        // The aggregate is still exactly at the limit; one genuinely new unit must be rejected.
        let rejected = submit(scheduler, owner: "E", key: "new", queuedWeight: 1) { "new" }
        assertSchedulerError(await rejected.value, .queuedWeightLimitReached(limit: 5))

        await gate.open()
        assertSuccess(await active.value, "active")
        assertSuccess(await joinedActive.value, "active")
        assertSuccess(await queued.value, "queued")
        assertSuccess(await joinedQueued.value, "queued")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testFinalActiveWaiterCancellationUnpublishesKeyForFreshSuccessor() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8, maximumQueuedWeight: 8)
        let cancellationGate = AsyncGate()
        let drainGate = UncancellableGate()
        let successorGate = AsyncGate()
        let recorder = EventRecorder()
        let successorAdmission = AdmissionRecorder()
        let joinedSuccessorAdmission = AdmissionRecorder()

        let first = submit(scheduler, owner: "A", key: "shared") {
            await recorder.record("first-started")
            do {
                try await cancellationGate.enter()
            } catch {
                await recorder.record("first-observed-cancellation")
                await drainGate.enter()
                await recorder.record("first-finished-draining")
                throw error
            }
            return "unexpected-first-success"
        }
        await cancellationGate.waitForArrivals(1)

        first.cancel()
        assertCancelled(await first.value)
        // The operation has observed cancellation but intentionally still owns the lane.
        await drainGate.waitForArrivals(1)

        let successor = submit(
            scheduler,
            owner: "B",
            key: "shared",
            queuedWeight: 4,
            admissionRecorder: successorAdmission
        ) {
            await recorder.record("successor-started")
            try await successorGate.enter()
            return "successor"
        }
        await waitForScheduler(scheduler) {
            $0.hasActiveEntry && $0.queuedEntryCount == 1 && $0.queuedWeight == 4
        }

        XCTAssertEqual(
            successorAdmission.admissions,
            [.init(disposition: .queued, queuedEntryCount: 1, queuedWeight: 4)]
        )
        await assertRecordCount(
            recorder,
            "successor-started",
            0,
            "A same-key successor must not overlap the cancelled operation while it drains"
        )

        await drainGate.open()
        await successorGate.waitForArrivals(1)

        // The old operation has now completed and the successor is active. Its stale cleanup must
        // not remove the successor's publication for this key: a third waiter still joins the
        // active successor, and its distinct closure remains ignored.
        let joinedSuccessor = submit(
            scheduler,
            owner: "C",
            key: "shared",
            queuedWeight: 3,
            admissionRecorder: joinedSuccessorAdmission
        ) {
            await recorder.record("third-closure-started")
            return "third"
        }
        await waitForScheduler(scheduler) { _ in
            !joinedSuccessorAdmission.admissions.isEmpty
        }
        XCTAssertEqual(
            joinedSuccessorAdmission.admissions,
            [.init(disposition: .joinedActive, queuedEntryCount: 0, queuedWeight: 0)]
        )
        let joinedSnapshot = await scheduler.snapshot()
        XCTAssertTrue(joinedSnapshot.hasActiveEntry)
        XCTAssertEqual(joinedSnapshot.queuedEntryCount, 0)
        XCTAssertEqual(joinedSnapshot.queuedWeight, 0)
        XCTAssertEqual(joinedSnapshot.waiterCount, 2)
        await assertRecordCount(recorder, "third-closure-started", 0)

        await successorGate.open()
        assertSuccess(await successor.value, "successor")
        assertSuccess(await joinedSuccessor.value, "successor")
        await assertRecordCount(recorder, "first-started", 1)
        await assertRecordCount(recorder, "first-observed-cancellation", 1)
        await assertRecordCount(recorder, "first-finished-draining", 1)
        await assertRecordCount(recorder, "successor-started", 1)
        await assertRecordCount(
            recorder,
            "third-closure-started",
            0,
            "Stale completion must preserve the successor mapping and ignore a later closure"
        )
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testQueuedWeightReleasesAfterCancellationCompletionAndShutdown() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8, maximumQueuedWeight: 6)
        let activeGate = AsyncGate()
        let dispatchedGate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active", queuedWeight: .max) {
            try await activeGate.enter()
            return "active"
        }
        await activeGate.waitForArrivals(1)

        let cancelled = await enqueue(
            scheduler,
            owner: "B",
            key: "cancelled",
            expectingQueueDepth: 1,
            queuedWeight: 2
        ) { "cancelled" }
        let dispatched = await enqueue(
            scheduler,
            owner: "C",
            key: "dispatched",
            expectingQueueDepth: 2,
            queuedWeight: 3
        ) {
            try await dispatchedGate.enter()
            return "dispatched"
        }
        let shutdownRemainder = await enqueue(
            scheduler,
            owner: "D",
            key: "shutdown-remainder",
            expectingQueueDepth: 3,
            queuedWeight: 1
        ) { "shutdown-remainder" }
        let beforeCancellation = await scheduler.snapshot()
        XCTAssertEqual(beforeCancellation.queuedEntryCount, 3)
        XCTAssertEqual(beforeCancellation.queuedWeight, 6)

        cancelled.cancel()
        assertCancelled(await cancelled.value)
        await waitForScheduler(scheduler) {
            $0.queuedEntryCount == 2 && $0.queuedWeight == 4
        }
        let afterCancellation = await scheduler.snapshot()
        XCTAssertEqual(afterCancellation.queuedEntryCount, 2)
        XCTAssertEqual(afterCancellation.queuedWeight, 4)

        await activeGate.open()
        assertSuccess(await active.value, "active")
        await dispatchedGate.waitForArrivals(1)

        // Dispatch subtracts exactly its three-unit charge while the independent one-unit entry
        // remains queued. Resetting the aggregate to zero would fail this assertion.
        let afterDispatch = await scheduler.snapshot()
        XCTAssertTrue(afterDispatch.hasActiveEntry)
        XCTAssertEqual(afterDispatch.queuedEntryCount, 1)
        XCTAssertEqual(afterDispatch.queuedWeight, 1)

        let beforeShutdown = await scheduler.snapshot()
        XCTAssertEqual(beforeShutdown.queuedEntryCount, 1)
        XCTAssertEqual(beforeShutdown.queuedWeight, 1)

        await scheduler.shutdown()
        assertSchedulerError(await dispatched.value, .shutDown)
        assertSchedulerError(await shutdownRemainder.value, .shutDown)
        await assertDrained(scheduler)
    }

    // MARK: - 11. Shutdown with active and queued work

    func testShutdownFailsEveryOutstandingWaiterWithShutDown() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active", operation: gatedOperation(recorder: recorder, gate: gate, name: "active"))
        await gate.waitForArrivals(1)

        let queuedA = await enqueue(scheduler, owner: "A", key: "A2", expectingQueueDepth: 1,
                                    operation: gatedOperation(recorder: recorder, gate: nil, name: "A2"))
        let queuedB = await enqueue(scheduler, owner: "B", key: "B1", expectingQueueDepth: 2,
                                    operation: gatedOperation(recorder: recorder, gate: nil, name: "B1"))
        let duplicate = submit(scheduler, owner: "C", key: "A2") { "ignored" }
        let activeDuplicate = submit(scheduler, owner: "D", key: "active") { "ignored" }
        await waitForScheduler(scheduler) { $0.waiterCount == 5 }

        await scheduler.shutdown()

        // Every waiter — active, queued, and duplicates of both — settles on `.shutDown`. A second
        // resume on any of these continuations would trap inside `CheckedContinuation`.
        assertSchedulerError(await active.value, .shutDown)
        assertSchedulerError(await activeDuplicate.value, .shutDown)
        assertSchedulerError(await queuedA.value, .shutDown)
        assertSchedulerError(await duplicate.value, .shutDown)
        assertSchedulerError(await queuedB.value, .shutDown)

        let events = await recorder.events
        XCTAssertEqual(events, ["active"], "No queued operation may start during or after shutdown")
        await assertDrained(scheduler)
    }

    // MARK: - 12. Completion accepted before shutdown

    func testCompletionAcceptedBeforeShutdownKeepsTheOperationResult() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active", operation: gatedOperation(recorder: recorder, gate: gate, name: "active"))
        await gate.waitForArrivals(1)
        await gate.open()

        // The terminal result is accepted by the scheduler before shutdown is even called, so the
        // waiter must keep it rather than being retroactively failed.
        let result = await active.value
        await scheduler.shutdown()
        assertSuccess(result, "active")
        await assertDrained(scheduler)
    }

    // MARK: - 13. Shutdown awaits the active operation

    func testShutdownAwaitsTheActiveOperationAndStartsNoReplacementWork() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active") {
            await recorder.record("active-started")
            do {
                try await gate.enter()
            } catch {
                // Cooperative unwind: shutdown must not return before this lands.
                await recorder.record("active-terminated")
                throw error
            }
            return "active"
        }
        await gate.waitForArrivals(1)

        let queued = await enqueue(scheduler, owner: "B", key: "queued", expectingQueueDepth: 1,
                                   operation: gatedOperation(recorder: recorder, gate: nil, name: "queued"))

        await scheduler.shutdown()

        // Sampled immediately after shutdown returns: the operation's terminal state is already
        // recorded, which is only possible if shutdown awaited the task.
        let eventsAtReturn = await recorder.events
        XCTAssertEqual(eventsAtReturn, ["active-started", "active-terminated"])

        assertSchedulerError(await active.value, .shutDown)
        assertSchedulerError(await queued.value, .shutDown)
        await assertRecordCount(recorder, "queued", 0, "Shutdown must not start replacement work")
        await assertDrained(scheduler)
    }

    // MARK: - 14. Idempotent shutdown

    func testRepeatedAndConcurrentShutdownIsIdempotent() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active") {
            await recorder.record("active-started")
            try await gate.enter()
            return "active"
        }
        await gate.waitForArrivals(1)

        // Concurrent callers must all observe the same terminal state.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await scheduler.shutdown() }
            }
        }
        // And a later, sequential call must still be safe.
        await scheduler.shutdown()
        await scheduler.shutdown()

        assertSchedulerError(await active.value, .shutDown)

        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.isShutDown)

        let late = submit(scheduler, owner: "B", key: "late") {
            await recorder.record("late")
            return "late"
        }
        assertSchedulerError(await late.value, .shutDown)
        await assertRecordCount(recorder, "late", 0)
        await assertDrained(scheduler)
    }

    // MARK: - 15. Identifier exhaustion

    func testWaiterIdentifierExhaustionFailsClosedWhileAcceptedWaitersSettle() async {
        let scheduler = TestScheduler(
            maximumQueuedEntries: 8,
            maximumEntryIDValue: 8,
            maximumWaiterIDValue: 2
        )
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let first = submit(scheduler, owner: "A", key: "shared") {
            await recorder.record("shared-started")
            try await gate.enter()
            return "shared"
        }
        await gate.waitForArrivals(1)

        let second = submit(scheduler, owner: "B", key: "shared") {
            await recorder.record("duplicate-closure-started")
            return "ignored"
        }
        await waitForScheduler(scheduler) { $0.waiterCount == 2 }

        let exhausted = submit(scheduler, owner: "C", key: "new-after-bound") {
            await recorder.record("exhausted-closure-started")
            return "unexpected"
        }
        assertIdentifierSpaceExhausted(await exhausted.value)

        // Exhaustion is a permanent admission fence, including for work that would otherwise
        // coalesce without creating another entry.
        let lateDuplicate = submit(scheduler, owner: "D", key: "shared") {
            await recorder.record("late-duplicate-closure-started")
            return "unexpected"
        }
        assertIdentifierSpaceExhausted(await lateDuplicate.value)

        let beforeCompletion = await scheduler.snapshot()
        XCTAssertTrue(beforeCompletion.hasActiveEntry)
        XCTAssertEqual(beforeCompletion.waiterCount, 2)
        XCTAssertEqual(beforeCompletion.queuedEntryCount, 0)

        await gate.open()
        assertSuccess(await first.value, "shared")
        assertSuccess(await second.value, "shared")
        await assertRecordCount(recorder, "shared-started", 1)
        await assertRecordCount(recorder, "duplicate-closure-started", 0)
        await assertRecordCount(recorder, "exhausted-closure-started", 0)
        await assertRecordCount(recorder, "late-duplicate-closure-started", 0)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testEntryIdentifierExhaustionRejectsWithoutQueueLeakAndPreservesCancellation() async {
        let scheduler = TestScheduler(
            maximumQueuedEntries: 8,
            maximumQueuedWeight: 8,
            maximumEntryIDValue: 1,
            maximumWaiterIDValue: 8
        )
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let active = submit(scheduler, owner: "A", key: "active") {
            await recorder.record("active-started")
            try await gate.enter()
            return "active"
        }
        await gate.waitForArrivals(1)

        let exhausted = submit(
            scheduler,
            owner: "B",
            key: "cannot-mint-entry",
            queuedWeight: 7
        ) {
            await recorder.record("exhausted-entry-closure-started")
            return "unexpected"
        }
        assertIdentifierSpaceExhausted(await exhausted.value)

        // The failed entry allocation must not leave behind the precomputed queue charge, an
        // entry, or a waiter. The already-running entry remains independently cancellable.
        let afterExhaustion = await scheduler.snapshot()
        XCTAssertTrue(afterExhaustion.hasActiveEntry)
        XCTAssertEqual(afterExhaustion.waiterCount, 1)
        XCTAssertEqual(afterExhaustion.queuedEntryCount, 0)
        XCTAssertEqual(afterExhaustion.queuedWeight, 0)

        let late = submit(scheduler, owner: "C", key: "late") {
            await recorder.record("late-closure-started")
            return "unexpected"
        }
        assertIdentifierSpaceExhausted(await late.value)

        active.cancel()
        assertCancelled(await active.value)
        await waitForScheduler(scheduler) { !$0.hasActiveEntry && $0.waiterCount == 0 }
        await assertRecordCount(recorder, "active-started", 1)
        await assertRecordCount(recorder, "exhausted-entry-closure-started", 0)
        await assertRecordCount(recorder, "late-closure-started", 0)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 16. Cancellation racing registration

    func testCancellationRacingRegistrationNeverLeaksOrDoubleResumesAWaiter() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 512)
        let recorder = EventRecorder()

        // Cancelling immediately after launch lands anywhere from before the continuation exists
        // to after the work has already completed. Whichever side wins, the waiter must settle
        // exactly once — a double resume would trap inside `CheckedContinuation`.
        for index in 0..<400 {
            let task = submit(scheduler, owner: "owner-\(index % 4)", key: "key-\(index)") {
                await recorder.record("ran-\(index)")
                return "value-\(index)"
            }
            task.cancel()

            switch await task.value {
            case .success(let value):
                XCTAssertEqual(value, "value-\(index)")
            case .failure(let error):
                XCTAssertTrue(
                    error is CancellationError || error is FairSingleLaneSchedulerError,
                    "Unexpected terminal error \(error)"
                )
            }
        }

        await waitForScheduler(scheduler) { !$0.hasActiveEntry && $0.waiterCount == 0 }
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 17. Ring repair

    func testRemovingAnOwnersFinalEntryPreservesRotationForTheRest() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 16)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let a1 = submit(scheduler, owner: "A", key: "A1", operation: gatedOperation(recorder: recorder, gate: gate, name: "A1"))
        await gate.waitForArrivals(1)

        let a2 = await enqueue(scheduler, owner: "A", key: "A2", expectingQueueDepth: 1,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "A2"))
        let b1 = await enqueue(scheduler, owner: "B", key: "B1", expectingQueueDepth: 2,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "B1"))
        let c1 = await enqueue(scheduler, owner: "C", key: "C1", expectingQueueDepth: 3,
                               operation: gatedOperation(recorder: recorder, gate: nil, name: "C1"))

        // B leaves the ring entirely; A and C must keep their relative rotation.
        b1.cancel()
        assertCancelled(await b1.value)
        await waitForScheduler(scheduler) { $0.queuedEntryCount == 2 }

        await gate.open()
        for task in [a1, a2, c1] {
            _ = await task.value
        }

        let events = await recorder.events
        XCTAssertEqual(events, ["A1", "C1", "A2"])
        await assertRecordCount(recorder, "B1", 0)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 18. Broadcast of success and failure

    func testSuccessIsBroadcastToEveryRemainingDuplicateWaiter() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let recorder = EventRecorder()
        let gate = AsyncGate()

        let first = submit(scheduler, owner: "A", key: "shared", operation: gatedOperation(recorder: recorder, gate: gate, name: "shared"))
        await gate.waitForArrivals(1)
        let second = submit(scheduler, owner: "B", key: "shared") { "ignored" }
        let third = submit(scheduler, owner: "C", key: "shared") { "ignored" }
        await waitForScheduler(scheduler) { $0.waiterCount == 3 }

        await gate.open()
        assertSuccess(await first.value, "shared")
        assertSuccess(await second.value, "shared")
        assertSuccess(await third.value, "shared")
        await assertRecordCount(recorder, "shared", 1)
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    func testThrownErrorIsBroadcastToEveryRemainingDuplicateWaiter() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 8)
        let gate = AsyncGate()
        let failure = TestOperationFailure(label: "operation-failed")

        let first = submit(scheduler, owner: "A", key: "shared") {
            try await gate.enter()
            throw failure
        }
        await gate.waitForArrivals(1)
        let second = submit(scheduler, owner: "B", key: "shared") { "ignored" }
        let third = submit(scheduler, owner: "C", key: "shared") { "ignored" }
        await waitForScheduler(scheduler) { $0.waiterCount == 3 }

        // One waiter walks away; the remaining two must both receive the operation's own error.
        third.cancel()
        assertCancelled(await third.value)
        await waitForScheduler(scheduler) { $0.waiterCount == 2 }

        await gate.open()
        for result in [await first.value, await second.value] {
            switch result {
            case .success(let value):
                XCTFail("Expected \(failure), got success(\(value))")
            case .failure(let error):
                XCTAssertEqual(error as? TestOperationFailure, failure)
            }
        }
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 20. The injected operation must not hold actor isolation

    func testInjectedOperationDoesNotRunUnderActorIsolation() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 4)
        let reachedSynchronousSection = AtomicFlag()
        let mayFinish = AtomicFlag()

        let task = submit(scheduler, owner: "A", key: "spin") {
            reachedSynchronousSection.set()
            // Synchronous work ahead of the operation's first suspension. If the scheduler
            // executed this closure under its own isolation, the loop would block every other
            // message to the actor — including the `snapshot()` below, which is the only thing
            // that can release it. The iteration cap turns that deadlock into a clean failure.
            var iterations = 0
            while !mayFinish.isSet {
                iterations &+= 1
                if iterations > 400_000_000 { return "blocked-the-actor" }
            }
            return "spin"
        }

        while !reachedSynchronousSection.isSet {
            await Task.yield()
        }

        // The actor answers while the operation is mid-spin on a pool thread.
        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.hasActiveEntry)
        mayFinish.set()

        assertSuccess(await task.value, "spin")
        await assertDrained(scheduler)
        await scheduler.shutdown()
    }

    // MARK: - 19. Stress

    func testStressAcrossOwnersDuplicatesCancellationsSuccessesAndFailures() async {
        let scheduler = TestScheduler(maximumQueuedEntries: 4096)
        let probe = ConcurrencyProbe()
        let ownerCount = 8
        let keyCount = 24
        let submissionCount = 600

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<submissionCount {
                group.addTask {
                    let key = "key-\(index % keyCount)"
                    // Submitted inline rather than through the `submit` helper: the helper is an
                    // instance method, and capturing the non-Sendable XCTestCase in a child task
                    // is exactly the kind of sharing Swift 6 rejects.
                    let task = Task { () -> Result<String, any Error> in
                        do {
                            let value = try await scheduler.submit(
                                owner: "owner-\(index % ownerCount)",
                                key: key
                            ) {
                                await probe.begin()
                                for _ in 0..<3 { await Task.yield() }
                                await probe.end()
                                // A deterministic slice of the keys fails, so both broadcast paths
                                // run under contention alongside coalescing and cancellation.
                                if index % keyCount % 5 == 0 {
                                    throw TestOperationFailure(label: key)
                                }
                                return key
                            }
                            return .success(value)
                        } catch {
                            return .failure(error)
                        }
                    }
                    // Roughly a quarter of the callers walk away mid-flight.
                    if index % 4 == 3 {
                        task.cancel()
                    }
                    switch await task.value {
                    case .success(let value):
                        XCTAssertEqual(value, key)
                    case .failure(let error):
                        XCTAssertTrue(
                            error is CancellationError
                                || error is TestOperationFailure
                                || error is FairSingleLaneSchedulerError,
                            "Unexpected terminal error \(error)"
                        )
                    }
                }
            }
        }

        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "The lane admitted more than one concurrent operation under load")
        await waitForScheduler(scheduler) { !$0.hasActiveEntry && $0.waiterCount == 0 }
        await assertDrained(scheduler)
        await scheduler.shutdown()

        // Shutdown drained everything and left the lane closed.
        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.isShutDown)
        XCTAssertEqual(snapshot.waiterCount, 0)
    }
}

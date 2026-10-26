import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import NativeDecompilerSchedulerCore
#endif

final class NativeDecompilerServiceSchedulingTests: XCTestCase {
    func testCancellationObserverRegisteredAfterCancellationFiresExactlyOnce() {
        let state = NativeDecompilerCancellationState()
        XCTAssertTrue(state.cancel())
        let callbacks = NativeDecompilerCancellationObserverProbe()

        let registration = state.observeCancellation(callbacks.record)

        XCTAssertEqual(callbacks.count, 1)
        XCTAssertFalse(state.cancel())
        registration.invalidate()
        XCTAssertEqual(callbacks.count, 1)
    }

    func testCancellationObserverRegistrationRacingCancellationFiresExactlyOnce() {
        for iteration in 0..<100 {
            let state = NativeDecompilerCancellationState()
            let callbacks = NativeDecompilerCancellationObserverProbe()
            let gate = DispatchSemaphore(value: 0)
            let race = DispatchGroup()
            let registration = NativeDecompilerCancellationRegistrationProbe()

            race.enter()
            DispatchQueue.global().async {
                gate.wait()
                registration.store(state.observeCancellation(callbacks.record))
                race.leave()
            }
            race.enter()
            DispatchQueue.global().async {
                gate.wait()
                _ = state.cancel()
                race.leave()
            }
            gate.signal()
            gate.signal()

            XCTAssertEqual(race.wait(timeout: .now() + 1), .success, "iteration \(iteration)")
            XCTAssertEqual(callbacks.count, 1, "iteration \(iteration)")
            registration.invalidate()
        }
    }

    func testInvalidatingCancellationObserverWaitsForInFlightCallbackAndPreventsLaterUse() {
        let state = NativeDecompilerCancellationState()
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let invalidationReturned = DispatchSemaphore(value: 0)
        let registration = state.observeCancellation {
            callbackStarted.signal()
            releaseCallback.wait()
        }

        DispatchQueue.global().async { _ = state.cancel() }
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            registration.invalidate()
            invalidationReturned.signal()
        }

        XCTAssertEqual(invalidationReturned.wait(timeout: .now() + 0.05), .timedOut)
        releaseCallback.signal()
        XCTAssertEqual(invalidationReturned.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(state.cancel())
    }

    func testCancellationObserverCanInvalidateItsOwnRegistrationWithoutDeadlock() {
        for iteration in 0..<100 {
            let state = NativeDecompilerCancellationState()
            let registration = NativeDecompilerCancellationRegistrationProbe()
            let callbackReturned = DispatchSemaphore(value: 0)
            registration.store(state.observeCancellation {
                registration.invalidate()
                callbackReturned.signal()
            })

            let cancelReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = state.cancel()
                cancelReturned.signal()
            }

            XCTAssertEqual(
                callbackReturned.wait(timeout: .now() + 1),
                .success,
                "callback iteration \(iteration)"
            )
            XCTAssertEqual(
                cancelReturned.wait(timeout: .now() + 1),
                .success,
                "cancel iteration \(iteration)"
            )
        }
    }

    func testActiveCancellationObserverCanReenterSchedulerWithoutDeadlock() {
        for iteration in 0..<100 {
            let scheduler = NativeDecompilerRequestScheduler(
                label: "\(#function).\(iteration)"
            )
            let requestID = UUID()
            let operationStarted = DispatchSemaphore(value: 0)
            let observerCompleted = DispatchSemaphore(value: 0)
            let operationMayFinish = DispatchSemaphore(value: 0)
            let completionReturned = DispatchSemaphore(value: 0)

            XCTAssertEqual(
                scheduler.submit(
                    requestID: requestID,
                    payload: Data(),
                    operation: { _, _, cancellationState, completion in
                        let registration = cancellationState.observeCancellation {
                            _ = scheduler.snapshot
                            observerCompleted.signal()
                        }
                        operationStarted.signal()
                        guard operationMayFinish.wait(timeout: .now() + 1) == .success else {
                            registration.invalidate()
                            completion(.failure(.internalFailure))
                            return
                        }
                        registration.invalidate()
                        completion(.failure(.cancelled))
                    },
                    completion: { _ in completionReturned.signal() }
                ),
                .started
            )
            XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

            let cancelReturned = DispatchSemaphore(value: 0)
            let cancellationDisposition = NativeDecompilerCancellationDispositionProbe()
            DispatchQueue.global().async {
                cancellationDisposition.store(scheduler.cancel(requestID: requestID))
                cancelReturned.signal()
            }

            XCTAssertEqual(observerCompleted.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(cancelReturned.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(cancellationDisposition.value, .activeSignaled)
            operationMayFinish.signal()
            XCTAssertEqual(completionReturned.wait(timeout: .now() + 1), .success)
        }
    }

    func testOneActiveOneQueuedAndThirdRequestFailsBusy() {
        let scheduler = NativeDecompilerRequestScheduler(label: #function)
        let operations = NativeDecompilerSchedulingOperationHarness()
        let completions = NativeDecompilerSchedulingCompletionHarness()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: first,
                payload: Data([0x01]),
                operation: operations.operation(for: first),
                completion: completions.completion(for: first)
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(first))

        XCTAssertEqual(
            scheduler.submit(
                requestID: second,
                payload: Data([0x02]),
                operation: operations.operation(for: second),
                completion: completions.completion(for: second)
            ),
            .queued
        )
        XCTAssertEqual(
            scheduler.submit(
                requestID: third,
                payload: Data([0x03]),
                operation: operations.operation(for: third),
                completion: completions.completion(for: third)
            ),
            .rejected(.busy)
        )

        XCTAssertEqual(completions.results(for: third), [.failure(.busy)])
        XCTAssertEqual(operations.startedRequestIDs, [first])

        operations.finish(first, with: .success(Data([0x11])))
        XCTAssertTrue(operations.waitUntilStarted(second))
        operations.finish(second, with: .success(Data([0x22])))
        XCTAssertTrue(completions.waitForCount(1, requestID: first))
        XCTAssertTrue(completions.waitForCount(1, requestID: second))
    }

    func testCancellingQueuedRequestCompletesExactlyOnceWithoutExecutingIt() {
        let scheduler = NativeDecompilerRequestScheduler(label: #function)
        let operations = NativeDecompilerSchedulingOperationHarness()
        let completions = NativeDecompilerSchedulingCompletionHarness()
        let active = UUID()
        let queued = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: active,
                payload: Data(),
                operation: operations.operation(for: active),
                completion: completions.completion(for: active)
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(active))
        XCTAssertEqual(
            scheduler.submit(
                requestID: queued,
                payload: Data(),
                operation: operations.operation(for: queued),
                completion: completions.completion(for: queued)
            ),
            .queued
        )

        XCTAssertEqual(scheduler.cancel(requestID: queued), .queuedCancelled)
        XCTAssertEqual(scheduler.cancel(requestID: queued), .notFound)
        XCTAssertEqual(completions.results(for: queued), [.failure(.cancelled)])

        operations.finish(active, with: .success(Data()))
        XCTAssertTrue(completions.waitForCount(1, requestID: active))
        XCTAssertFalse(operations.waitUntilStarted(queued, timeout: 0.05))
        XCTAssertEqual(completions.results(for: queued), [.failure(.cancelled)])
    }

    func testCancellingActiveRequestSignalsLifetimeStableTokenAndSuppressesSuccess() {
        let scheduler = NativeDecompilerRequestScheduler(label: #function)
        let operations = NativeDecompilerSchedulingOperationHarness()
        let completions = NativeDecompilerSchedulingCompletionHarness()
        let requestID = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: requestID,
                payload: Data(),
                operation: operations.operation(for: requestID),
                completion: completions.completion(for: requestID)
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(requestID))
        guard let token = operations.cancellationState(for: requestID) else {
            XCTFail("The active operation must receive its cancellation state.")
            return
        }
        XCTAssertFalse(token.isCancelled)

        XCTAssertEqual(scheduler.cancel(requestID: requestID), .activeSignaled)
        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(scheduler.cancel(requestID: requestID), .activeAlreadySignaled)
        XCTAssertTrue(completions.results(for: requestID).isEmpty)

        operations.finish(requestID, with: .success(Data([0xAA])))
        XCTAssertTrue(completions.waitForCount(1, requestID: requestID))
        XCTAssertEqual(completions.results(for: requestID), [.failure(.cancelled)])
    }

    func testDuplicateInFlightRequestIDFailsClosedWithoutReplacingOriginal() {
        let scheduler = NativeDecompilerRequestScheduler(label: #function)
        let operations = NativeDecompilerSchedulingOperationHarness()
        let originalCompletions = NativeDecompilerSchedulingCompletionHarness()
        let duplicateCompletions = NativeDecompilerSchedulingCompletionHarness()
        let requestID = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: requestID,
                payload: Data([0x01]),
                operation: operations.operation(for: requestID),
                completion: originalCompletions.completion(for: requestID)
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(requestID))

        XCTAssertEqual(
            scheduler.submit(
                requestID: requestID,
                payload: Data([0x02]),
                operation: { _, _, _, completion in completion(.success(Data())) },
                completion: duplicateCompletions.completion(for: requestID)
            ),
            .rejected(.duplicateRequestID)
        )
        XCTAssertEqual(duplicateCompletions.results(for: requestID), [.failure(.duplicateRequestID)])

        operations.finish(requestID, with: .success(Data([0x0A])))
        XCTAssertTrue(originalCompletions.waitForCount(1, requestID: requestID))
        XCTAssertEqual(originalCompletions.results(for: requestID), [.success(Data([0x0A]))])
    }

    func testDuplicateAndLateCallbacksAreIgnoredAndPromoteQueueOnlyOnce() {
        let scheduler = NativeDecompilerRequestScheduler(label: #function)
        let operations = NativeDecompilerSchedulingOperationHarness()
        let completions = NativeDecompilerSchedulingCompletionHarness()
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: first,
                payload: Data(),
                operation: operations.operation(for: first),
                completion: completions.completion(for: first)
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(first))
        XCTAssertEqual(
            scheduler.submit(
                requestID: second,
                payload: Data(),
                operation: operations.operation(for: second),
                completion: completions.completion(for: second)
            ),
            .queued
        )

        operations.finish(first, with: .success(Data([0x01])))
        operations.finish(first, with: .failure(.internalFailure))
        XCTAssertTrue(operations.waitUntilStarted(second))
        XCTAssertEqual(operations.startedRequestIDs.filter { $0 == second }.count, 1)
        XCTAssertEqual(completions.results(for: first), [.success(Data([0x01]))])

        operations.finish(second, with: .success(Data([0x02])))
        operations.finish(second, with: .success(Data([0x03])))
        XCTAssertTrue(completions.waitForCount(1, requestID: second))
        XCTAssertEqual(completions.results(for: second), [.success(Data([0x02]))])
    }

    func testConcurrentQueuedCancellationAndActiveFinishRemainBoundedAndExactlyOnce() {
        for iteration in 0..<50 {
            let scheduler = NativeDecompilerRequestScheduler(label: "\(#function).\(iteration)")
            let operations = NativeDecompilerSchedulingOperationHarness(autoFinishAfterStart: true)
            let completions = NativeDecompilerSchedulingCompletionHarness()
            let active = UUID()
            let queued = UUID()

            XCTAssertEqual(
                scheduler.submit(
                    requestID: active,
                    payload: Data(),
                    operation: operations.operation(for: active, autoFinish: false),
                    completion: completions.completion(for: active)
                ),
                .started
            )
            XCTAssertTrue(operations.waitUntilStarted(active))
            XCTAssertEqual(
                scheduler.submit(
                    requestID: queued,
                    payload: Data(),
                    operation: operations.operation(for: queued),
                    completion: completions.completion(for: queued)
                ),
                .queued
            )

            let startGate = DispatchSemaphore(value: 0)
            let race = DispatchGroup()
            race.enter()
            DispatchQueue.global().async {
                startGate.wait()
                operations.finish(active, with: .success(Data()))
                race.leave()
            }
            race.enter()
            DispatchQueue.global().async {
                startGate.wait()
                _ = scheduler.cancel(requestID: queued)
                race.leave()
            }
            startGate.signal()
            startGate.signal()
            XCTAssertEqual(race.wait(timeout: .now() + 1), .success)
            XCTAssertTrue(completions.waitForCount(1, requestID: active))
            XCTAssertTrue(completions.waitForCount(1, requestID: queued))
            XCTAssertEqual(completions.results(for: active).count, 1)
            XCTAssertEqual(completions.results(for: queued).count, 1)
            XCTAssertLessThanOrEqual(operations.startedRequestIDs.filter { $0 == queued }.count, 1)
            XCTAssertEqual(scheduler.snapshot.activeCount, 0)
            XCTAssertEqual(scheduler.snapshot.queuedCount, 0)
        }
    }

    func testConcurrentActiveCancellationAndFinishCompletesExactlyOnce() {
        for iteration in 0..<50 {
            let scheduler = NativeDecompilerRequestScheduler(label: "\(#function).\(iteration)")
            let operations = NativeDecompilerSchedulingOperationHarness()
            let completions = NativeDecompilerSchedulingCompletionHarness()
            let requestID = UUID()

            XCTAssertEqual(
                scheduler.submit(
                    requestID: requestID,
                    payload: Data(),
                    operation: operations.operation(for: requestID),
                    completion: completions.completion(for: requestID)
                ),
                .started
            )
            XCTAssertTrue(operations.waitUntilStarted(requestID))

            let startGate = DispatchSemaphore(value: 0)
            let race = DispatchGroup()
            race.enter()
            DispatchQueue.global().async {
                startGate.wait()
                operations.finish(requestID, with: .success(Data([0x7F])))
                race.leave()
            }
            race.enter()
            DispatchQueue.global().async {
                startGate.wait()
                _ = scheduler.cancel(requestID: requestID)
                race.leave()
            }
            startGate.signal()
            startGate.signal()

            XCTAssertEqual(race.wait(timeout: .now() + 1), .success)
            XCTAssertTrue(completions.waitForCount(1, requestID: requestID))
            let results = completions.results(for: requestID)
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(
                results == [.success(Data([0x7F]))] || results == [.failure(.cancelled)],
                "The terminal race may resolve before or after cancellation, but exactly once."
            )
            XCTAssertEqual(scheduler.snapshot.activeCount, 0)
            XCTAssertEqual(scheduler.snapshot.queuedCount, 0)
            XCTAssertEqual(scheduler.cancel(requestID: requestID), .notFound)
        }
    }

    func testActiveHardDeadlineTerminatesOnlyTheExactConfiguredServiceProcess() {
        let deadlines = NativeDecompilerHardDeadlineSchedulerProbe()
        let terminations = NativeDecompilerProcessTerminationProbe()
        let expectedProcessID: Int32 = 42_424
        let scheduler = NativeDecompilerRequestScheduler(
            label: #function,
            serviceProcessID: expectedProcessID,
            scheduleHardDeadline: deadlines.schedule,
            terminateServiceProcess: terminations.terminate
        )
        let operations = NativeDecompilerSchedulingOperationHarness()
        let requestID = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: requestID,
                payload: Data(),
                hardDeadlineMilliseconds: 750,
                operation: operations.operation(for: requestID),
                completion: { _ in XCTFail("unresponsive native work must not complete") }
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(requestID))
        XCTAssertEqual(deadlines.delays, [750])

        deadlines.fireOnlyDeadline()

        XCTAssertEqual(terminations.processIDs, [expectedProcessID])
        XCTAssertEqual(scheduler.snapshot.activeCount, 1)
    }

    func testCompletedRequestCancelsHardDeadlineAndLateFireCannotTerminateService() {
        let deadlines = NativeDecompilerHardDeadlineSchedulerProbe()
        let terminations = NativeDecompilerProcessTerminationProbe()
        let scheduler = NativeDecompilerRequestScheduler(
            label: #function,
            serviceProcessID: 42_425,
            scheduleHardDeadline: deadlines.schedule,
            terminateServiceProcess: terminations.terminate
        )
        let operations = NativeDecompilerSchedulingOperationHarness()
        let completions = NativeDecompilerSchedulingCompletionHarness()
        let requestID = UUID()

        XCTAssertEqual(
            scheduler.submit(
                requestID: requestID,
                payload: Data(),
                hardDeadlineMilliseconds: 750,
                operation: operations.operation(for: requestID),
                completion: completions.completion(for: requestID)
            ),
            .started
        )
        XCTAssertTrue(operations.waitUntilStarted(requestID))
        operations.finish(requestID, with: .success(Data()))
        XCTAssertTrue(completions.waitForCount(1, requestID: requestID))

        XCTAssertEqual(deadlines.cancellationCount, 1)
        deadlines.fireOnlyDeadline()
        XCTAssertTrue(terminations.processIDs.isEmpty)
    }
}

private final class NativeDecompilerCancellationObserverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func record() {
        lock.withLock { recordedCount += 1 }
    }
}

private final class NativeDecompilerCancellationRegistrationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var registration: NativeDecompilerCancellationRegistration?

    func store(_ registration: NativeDecompilerCancellationRegistration) {
        lock.withLock { self.registration = registration }
    }

    func invalidate() {
        lock.withLock { registration }?.invalidate()
    }
}

private final class NativeDecompilerCancellationDispositionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: NativeDecompilerCancellationDisposition?

    var value: NativeDecompilerCancellationDisposition? {
        lock.withLock { storedValue }
    }

    func store(_ value: NativeDecompilerCancellationDisposition) {
        lock.withLock { storedValue = value }
    }
}

private final class NativeDecompilerSchedulingOperationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [UUID] = []
    private var states: [UUID: NativeDecompilerCancellationState] = [:]
    private var callbacks: [UUID: @Sendable (NativeDecompilerScheduledResult) -> Void] = [:]
    private let autoFinishAfterStart: Bool

    init(autoFinishAfterStart: Bool = false) {
        self.autoFinishAfterStart = autoFinishAfterStart
    }

    var startedRequestIDs: [UUID] {
        lock.withLock { started }
    }

    func operation(
        for requestID: UUID,
        autoFinish: Bool? = nil
    ) -> NativeDecompilerRequestScheduler.Operation {
        { [self] receivedRequestID, _, cancellationState, completion in
            precondition(receivedRequestID == requestID)
            lock.withLock {
                started.append(requestID)
                states[requestID] = cancellationState
                callbacks[requestID] = completion
            }
            if autoFinish ?? autoFinishAfterStart {
                completion(.success(Data()))
            }
        }
    }

    func finish(_ requestID: UUID, with result: NativeDecompilerScheduledResult) {
        let callback = lock.withLock { callbacks[requestID] }
        callback?(result)
    }

    func cancellationState(for requestID: UUID) -> NativeDecompilerCancellationState? {
        lock.withLock { states[requestID] }
    }

    func waitUntilStarted(_ requestID: UUID, timeout: TimeInterval = 1) -> Bool {
        waitUntil(timeout: timeout) {
            self.lock.withLock { self.started.contains(requestID) }
        }
    }
}

private final class NativeDecompilerSchedulingCompletionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UUID: [NativeDecompilerScheduledResult]] = [:]

    func completion(for requestID: UUID) -> NativeDecompilerRequestScheduler.Completion {
        { [self] result in
            lock.withLock {
                recorded[requestID, default: []].append(result)
            }
        }
    }

    func results(for requestID: UUID) -> [NativeDecompilerScheduledResult] {
        lock.withLock { recorded[requestID] ?? [] }
    }

    func waitForCount(_ count: Int, requestID: UUID, timeout: TimeInterval = 1) -> Bool {
        waitUntil(timeout: timeout) {
            self.lock.withLock { (self.recorded[requestID]?.count ?? 0) >= count }
        }
    }
}

private final class NativeDecompilerHardDeadlineSchedulerProbe: @unchecked Sendable {
    private struct ScheduledDeadline {
        let delayMilliseconds: UInt64
        let action: @Sendable () -> Void
        let cancellation: NativeDecompilerHardDeadlineCancellation
    }

    private let lock = NSLock()
    private var scheduled: [ScheduledDeadline] = []
    private var cancellations = 0

    var delays: [UInt64] {
        lock.withLock { scheduled.map(\.delayMilliseconds) }
    }

    var cancellationCount: Int { lock.withLock { cancellations } }

    func schedule(
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> NativeDecompilerHardDeadlineCancellation {
        let cancellation = NativeDecompilerHardDeadlineCancellation { [weak self] in
            self?.lock.withLock { self?.cancellations += 1 }
        }
        lock.withLock {
            scheduled.append(
                ScheduledDeadline(
                    delayMilliseconds: delayMilliseconds,
                    action: action,
                    cancellation: cancellation
                )
            )
        }
        return cancellation
    }

    func fireOnlyDeadline() {
        let deadline = lock.withLock { scheduled.count == 1 ? scheduled[0] : nil }
        deadline?.action()
    }
}

private final class NativeDecompilerProcessTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []

    var processIDs: [Int32] { lock.withLock { recorded } }

    func terminate(_ processID: Int32) {
        lock.withLock { recorded.append(processID) }
    }
}

private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.001)
    } while Date() < deadline
    return condition()
}

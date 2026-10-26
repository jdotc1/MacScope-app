import XCTest

@testable import MacScope

final class ReconstructionAnalysisProviderPoolTests: XCTestCase {
    func testOneProviderPerActiveAnalysisAndBudgetBoundedWidth() async throws {
        let factory = CountingAnalysisProviderFactory()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: factory,
            budget: .init(
                maximumActiveAnalyses: 6,
                estimatedResidentBytesPerAnalysis: 2_000,
                reservedHostBytes: 2_000
            ),
            processorCount: 8,
            physicalMemory: 6_000
        )
        let gate = AnalysisConcurrencyGate()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await pool.withProvider { _ in
                        await gate.enterAndWait()
                        return true
                    }
                }
            }
            await waitUntilAnalysisProviderPool {
                let snapshot = await pool.snapshot()
                return await gate.activeCount == 2 && snapshot.queuedWaiterCount == 2
            }

            let width = await pool.width
            let maximumActive = await gate.maximumActive
            XCTAssertEqual(width, 2)
            XCTAssertEqual(factory.count, 2)
            XCTAssertEqual(maximumActive, 2)
            await gate.open()
        }

        let settled = await pool.snapshot()
        XCTAssertEqual(settled.activeProviderCount, 0)
        XCTAssertEqual(settled.idleProviderCount, 2)
    }

    func testPauseDrainsQueuedWaitersAndWaitsForActiveLeaseBeforeResume() async throws {
        let factory = CountingAnalysisProviderFactory()
        let pool = try makeAnalysisProviderPool(factory: factory, width: 1)
        let activeGate = AnalysisConcurrencyGate()
        let queuedOperation = AnalysisProviderPoolCounter()
        let queuedSettlement = AnalysisProviderPoolCounter()
        let pauseCompletion = AnalysisProviderPoolCounter()

        let active = Task {
            try await pool.withProvider { _ in
                await activeGate.enterAndWait()
                return "active"
            }
        }
        await waitUntilAnalysisProviderPool { await activeGate.activeCount == 1 }

        let queued = Task {
            do {
                let value = try await pool.withProvider { _ in
                    await queuedOperation.increment()
                    return "queued"
                }
                await queuedSettlement.increment()
                return value
            } catch {
                await queuedSettlement.increment()
                throw error
            }
        }
        await waitUntilAnalysisProviderPool {
            await pool.snapshot().queuedWaiterCount == 1
        }

        let pause = Task {
            await pool.pause()
            await pauseCompletion.increment()
        }
        await waitUntilAnalysisProviderPool {
            await pool.snapshot().lifecycle == .paused
        }
        let pausedSnapshot = await pool.snapshot()
        XCTAssertEqual(pausedSnapshot.queuedWaiterCount, 0)
        let queuedWasSettled = await waitUntilAnalysisProviderPool {
            await queuedSettlement.value == 1
        }
        guard pausedSnapshot.queuedWaiterCount == 0, queuedWasSettled else {
            queued.cancel()
            await activeGate.open()
            _ = try? await queued.value
            _ = try? await active.value
            await pause.value
            return
        }

        do {
            _ = try await queued.value
            XCTFail("Pause must fail queued provider acquisition immediately.")
        } catch let error as ReconstructionAnalysisProviderPoolAdmissionError {
            XCTAssertEqual(error, .paused)
        }
        let queuedOperationCount = await queuedOperation.value
        let incompletePauseCount = await pauseCompletion.value
        XCTAssertEqual(queuedOperationCount, 0)
        XCTAssertEqual(incompletePauseCount, 0)

        do {
            _ = try await pool.withProvider { _ in "unexpected" }
            XCTFail("Pause must reject fresh provider acquisition.")
        } catch let error as ReconstructionAnalysisProviderPoolAdmissionError {
            XCTAssertEqual(error, .paused)
        }

        await activeGate.open()
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")
        await pause.value
        let completedPauseCount = await pauseCompletion.value
        XCTAssertEqual(completedPauseCount, 1)

        await pool.resume()
        let resumedValue = try await pool.withProvider { _ in "resumed" }
        XCTAssertEqual(resumedValue, "resumed")
        let resumed = await pool.snapshot()
        XCTAssertEqual(resumed.lifecycle, .active)
        XCTAssertEqual(resumed.providerCount, 1)
        XCTAssertEqual(resumed.activeProviderCount, 0)
        XCTAssertEqual(resumed.idleProviderCount, 1)
    }

    func testConcurrentResumeCannotReopenBeforePauseCallCompletes() async throws {
        let factory = CountingAnalysisProviderFactory()
        let activeGate = AnalysisConcurrencyGate()
        let pauseCompletionGate = AnalysisConcurrencyGate()
        let resumeCompletion = AnalysisProviderPoolCounter()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: factory,
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 1,
            hooks: .init(beforePauseCompletion: {
                await pauseCompletionGate.enterAndWait()
            })
        )

        let active = Task {
            try await pool.withProvider { _ in
                await activeGate.enterAndWait()
                return "active"
            }
        }
        await waitUntilAnalysisProviderPool { await activeGate.activeCount == 1 }

        let pause = Task { await pool.pause() }
        await waitUntilAnalysisProviderPool {
            let snapshot = await pool.snapshot()
            return snapshot.lifecycle == .paused && snapshot.pendingPauseCallCount == 1
        }

        let resume = Task {
            await pool.resume()
            await resumeCompletion.increment()
        }
        await waitUntilAnalysisProviderPool {
            await pool.snapshot().pendingResumeCallCount == 1
        }

        await activeGate.open()
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")
        await waitUntilAnalysisProviderPool {
            await pauseCompletionGate.activeCount == 1
        }

        let heldAtPauseCompletion = await pool.snapshot()
        XCTAssertEqual(heldAtPauseCompletion.lifecycle, .paused)
        XCTAssertEqual(heldAtPauseCompletion.activeProviderCount, 0)
        XCTAssertEqual(heldAtPauseCompletion.pendingPauseCallCount, 1)
        XCTAssertEqual(heldAtPauseCompletion.pendingResumeCallCount, 1)

        await pauseCompletionGate.open()
        await pause.value
        let resumeWasSettled = await waitUntilAnalysisProviderPool {
            await resumeCompletion.value == 1
        }
        guard resumeWasSettled else {
            await pool.retire()
            await resume.value
            return
        }
        await resume.value

        let resumed = await pool.snapshot()
        XCTAssertEqual(resumed.lifecycle, .active)
        XCTAssertEqual(resumed.pendingPauseCallCount, 0)
        XCTAssertEqual(resumed.pendingResumeCallCount, 0)
    }

    func testRetirementDrainsWaitersRejectsFutureAcquireAndDropsReturningProvider() async throws {
        let factory = TrackingAnalysisProviderFactory()
        let pool = try makeAnalysisProviderPool(factory: factory, width: 1)
        let activeGate = AnalysisConcurrencyGate()
        let queuedOperation = AnalysisProviderPoolCounter()
        let queuedSettlement = AnalysisProviderPoolCounter()

        let active = Task {
            try await pool.withProvider { _ in
                await activeGate.enterAndWait()
                return "active"
            }
        }
        await waitUntilAnalysisProviderPool { await activeGate.activeCount == 1 }

        let queued = Task {
            do {
                let value = try await pool.withProvider { _ in
                    await queuedOperation.increment()
                    return "queued"
                }
                await queuedSettlement.increment()
                return value
            } catch {
                await queuedSettlement.increment()
                throw error
            }
        }
        await waitUntilAnalysisProviderPool {
            await pool.snapshot().queuedWaiterCount == 1
        }

        await pool.retire()
        await pool.retire()

        let didSettleQueued = await waitUntilAnalysisProviderPool {
            await queuedSettlement.value == 1
        }
        guard didSettleQueued else {
            queued.cancel()
            await activeGate.open()
            _ = try? await queued.value
            _ = try? await active.value
            return
        }

        do {
            _ = try await queued.value
            XCTFail("Retirement must fail queued provider acquisition immediately.")
        } catch let error as ReconstructionAnalysisProviderPoolAdmissionError {
            XCTAssertEqual(error, .retired)
        }
        let queuedOperationCount = await queuedOperation.value
        XCTAssertEqual(queuedOperationCount, 0)

        let retiring = await pool.snapshot()
        XCTAssertEqual(retiring.lifecycle, .retired)
        XCTAssertEqual(retiring.providerCount, 1)
        XCTAssertEqual(retiring.activeProviderCount, 1)
        XCTAssertEqual(retiring.idleProviderCount, 0)

        await activeGate.open()
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")
        await waitUntilAnalysisProviderPool {
            await pool.snapshot().providerCount == 0
        }

        let retired = await pool.snapshot()
        XCTAssertEqual(retired.lifecycle, .retired)
        XCTAssertEqual(retired.providerCount, 0)
        XCTAssertEqual(retired.activeProviderCount, 0)
        XCTAssertEqual(retired.idleProviderCount, 0)
        XCTAssertEqual(factory.deinitializedProviderCount, 1)

        do {
            _ = try await pool.withProvider { _ in "unexpected" }
            XCTFail("Retirement is terminal and must reject fresh acquisition.")
        } catch let error as ReconstructionAnalysisProviderPoolAdmissionError {
            XCTAssertEqual(error, .retired)
        }
    }

    func testRetirementWakesResumeWithoutWaitingForActiveLeaseOrPauseCompletion() async throws {
        let factory = CountingAnalysisProviderFactory()
        let activeGate = AnalysisConcurrencyGate()
        let pauseCompletionGate = AnalysisConcurrencyGate()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: factory,
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 1,
            hooks: .init(beforePauseCompletion: {
                await pauseCompletionGate.enterAndWait()
            })
        )
        let pauseCompletion = AnalysisProviderPoolCounter()
        let resumeCompletion = AnalysisProviderPoolCounter()

        let active = Task {
            try await pool.withProvider { _ in
                await activeGate.enterAndWait()
                return "active"
            }
        }
        await waitUntilAnalysisProviderPool { await activeGate.activeCount == 1 }

        let pause = Task {
            await pool.pause()
            await pauseCompletion.increment()
        }
        await waitUntilAnalysisProviderPool {
            let snapshot = await pool.snapshot()
            return snapshot.lifecycle == .paused && snapshot.pendingPauseCallCount == 1
        }

        let resume = Task {
            await pool.resume()
            await resumeCompletion.increment()
        }
        await waitUntilAnalysisProviderPool {
            await pool.snapshot().pendingResumeCallCount == 1
        }

        await pool.retire()
        let resumeWasWoken = await waitUntilAnalysisProviderPool {
            let resumedCount = await resumeCompletion.value
            let activePauseCount = await pauseCompletionGate.activeCount
            return resumedCount == 1 && activePauseCount == 1
        }
        let terminal = await pool.snapshot()
        XCTAssertTrue(resumeWasWoken)
        XCTAssertEqual(terminal.lifecycle, .retired)
        XCTAssertEqual(terminal.activeProviderCount, 1)
        XCTAssertEqual(terminal.pendingPauseCallCount, 1)
        XCTAssertEqual(terminal.pendingResumeCallCount, 0)

        guard resumeWasWoken else {
            await pauseCompletionGate.open()
            await activeGate.open()
            _ = try? await active.value
            await pause.value
            await resume.value
            return
        }

        await pauseCompletionGate.open()
        await pause.value
        let completedPauseCount = await pauseCompletion.value
        XCTAssertEqual(completedPauseCount, 1)
        await activeGate.open()
        _ = try await active.value
        await resume.value
        let settled = await pool.snapshot()
        XCTAssertEqual(settled.providerCount, 0)
        XCTAssertEqual(settled.activeProviderCount, 0)
    }

    func testRetirementDropsIdleProviderReferencesImmediately() async throws {
        let factory = TrackingAnalysisProviderFactory()
        let pool = try makeAnalysisProviderPool(factory: factory, width: 1)

        let completedValue = try await pool.withProvider { _ in "complete" }
        XCTAssertEqual(completedValue, "complete")
        let idle = await pool.snapshot()
        XCTAssertEqual(idle.providerCount, 1)
        XCTAssertEqual(idle.idleProviderCount, 1)

        await pool.retire()

        let retired = await pool.snapshot()
        XCTAssertEqual(retired.lifecycle, .retired)
        XCTAssertEqual(retired.providerCount, 0)
        XCTAssertEqual(retired.idleProviderCount, 0)
        XCTAssertEqual(factory.deinitializedProviderCount, 1)
    }
}

private func makeAnalysisProviderPool(
    factory: any ReconstructionAnalysisProviderFactory,
    width: Int
) throws -> ReconstructionAnalysisProviderPool {
    try ReconstructionAnalysisProviderPool(
        factory: factory,
        budget: .init(
            maximumActiveAnalyses: width,
            estimatedResidentBytesPerAnalysis: 1,
            reservedHostBytes: 0
        ),
        processorCount: width,
        physicalMemory: UInt64(width)
    )
}

private final class CountingAnalysisProviderFactory:
    ReconstructionAnalysisProviderFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { lock.withLock { storedCount } }

    func makeProvider() -> any AnalysisProviding {
        lock.withLock { storedCount += 1 }
        return UnusedAnalysisProvider()
    }
}

private struct UnusedAnalysisProvider: AnalysisProviding {
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot { fatalError("not used") }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot { fatalError("not used") }
}

private actor AnalysisConcurrencyGate {
    private var active = 0
    private(set) var maximumActive = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var activeCount: Int { active }

    func enterAndWait() async {
        active += 1
        maximumActive = max(maximumActive, active)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        active -= 1
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class TrackingAnalysisProviderFactory:
    ReconstructionAnalysisProviderFactory,
    @unchecked Sendable
{
    private let deinitialization = AnalysisProviderPoolLockedCounter()

    var deinitializedProviderCount: Int { deinitialization.value }

    func makeProvider() -> any AnalysisProviding {
        TrackingAnalysisProvider(deinitialization: deinitialization)
    }
}

private final class TrackingAnalysisProvider: AnalysisProviding, @unchecked Sendable {
    private let deinitialization: AnalysisProviderPoolLockedCounter

    init(deinitialization: AnalysisProviderPoolLockedCounter) {
        self.deinitialization = deinitialization
    }

    deinit { deinitialization.increment() }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot { fatalError("not used") }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot { fatalError("not used") }
}

private final class AnalysisProviderPoolLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private actor AnalysisProviderPoolCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

@discardableResult
private func waitUntilAnalysisProviderPool(
    _ predicate: @Sendable @escaping () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Bool {
    for _ in 0..<200_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    XCTFail("provider-pool condition did not settle", file: file, line: line)
    return false
}

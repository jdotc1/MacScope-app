import XCTest
@testable import MacScope

@MainActor
final class ReconstructionResourceAdmissionTests: XCTestCase {
    func testAggregateCPUCostBoundsPoolWidth() throws {
        let budget = ReconstructionAnalysisProviderPoolBudget(maximumActiveAnalyses: 6,
            estimatedResidentBytesPerAnalysis: 2, reservedHostBytes: 4, maximumInnerParallelism: 3)
        XCTAssertEqual(try budget.width(processorCount: 10, physicalMemory: 32), 3)
        XCTAssertEqual(try budget.width(processorCount: 2, physicalMemory: 32), 1)
        XCTAssertThrowsError(try budget.width(processorCount: 10, physicalMemory: 5))
    }

    func testRuntimeHeadroomBlocksThenResourceEventResumesWithoutChangingResult() async throws {
        let enqueued = CPUAsyncLatch()
        let pool = try makePool(initial: snapshot(available: 5), enqueue: { _ in await enqueued.open() })
        let task = Task { try await pool.withProvider { _ in Data([1, 2, 3, 4]) } }
        await enqueued.wait()
        // Event may precede actual enqueue; the enqueue path re-evaluates the current snapshot.
        await pool.resourcesDidChange(snapshot(available: 20))
        let result = try await task.value
        XCTAssertEqual(result, Data([1, 2, 3, 4]))
        let state = await pool.snapshot()
        XCTAssertEqual(state.activeProviderCount, 0)
        XCTAssertEqual(state.queuedWaiterCount, 0)
    }

    func testCriticalPressureDrainsActiveWorkAndOnlyGatesNewAdmission() async throws {
        let started = CPUAsyncLatch()
        let finish = CPUAsyncLatch()
        let queued = CPUAsyncLatch()
        let pool = try makePool(initial: snapshot(available: 20), enqueue: { _ in await queued.open() })
        let first = Task { try await pool.withProvider { _ in
            await started.open(); await finish.wait(); return "accepted-result"
        } }
        await started.wait()
        await pool.resourcesDidChange(snapshot(available: 20, pressure: .critical))
        let second = Task { try await pool.withProvider { _ in "later-result" } }
        await queued.wait()
        await finish.open()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "accepted-result")
        let held = await pool.snapshot()
        XCTAssertEqual(held.effectiveAdmissionLimit, 0)
        await pool.resourcesDidChange(snapshot(available: 20))
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, "later-result")
    }

    func testCancellingResourceWaiterCannotCancelAcceptedWork() async throws {
        let started = CPUAsyncLatch()
        let finish = CPUAsyncLatch()
        let queued = CPUAsyncLatch()
        let pool = try makePool(initial: snapshot(available: 20), enqueue: { _ in await queued.open() })
        let accepted = Task { try await pool.withProvider { _ in
            await started.open(); await finish.wait(); return 42
        } }
        await started.wait()
        await pool.resourcesDidChange(snapshot(available: 0))
        let cancelled = Task { try await pool.withProvider { _ in XCTFail("Cancelled operation started"); return 0 } }
        await queued.wait()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        await finish.open()
        let value = try await accepted.value
        XCTAssertEqual(value, 42)
    }

    func testGlobalAdmissionCapsIndependentOwnersAndPauseUnblocksOnlyItsQueuedOwner() async throws {
        let waiting = CPUAsyncLatch()
        let global = ReconstructionGlobalAnalysisAdmission(maximumActive: 1,
            onWaiterEnqueue: { Task { await waiting.open() } })
        let accepted = CPUAsyncLatch()
        let finish = CPUAsyncLatch()
        let ownerA = ReconstructionAnalysisAdmissionOwner()
        let ownerB = ReconstructionAnalysisAdmissionOwner()
        let first = Task { try await global.withPermit(owner: ownerA) {
            await accepted.open(); await finish.wait(); return "first"
        } }
        await accepted.wait()
        // The owner cell closes enqueue/cancel races without polling global queue state.
        let second = Task {
            return try await global.withPermit(owner: ownerB) { XCTFail("Paused owner ran"); return "second" }
        }
        await waiting.wait()
        ownerB.set(.paused)
        await global.ownerStateChanged(ownerB)
        do { _ = try await second.value; XCTFail("Expected paused admission") }
        catch let error as ReconstructionAnalysisProviderPoolAdmissionError { XCTAssertEqual(error, .paused) }
        await finish.open()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "first")
        ownerB.set(.active)
        let resumed = try await global.withPermit(owner: ownerB) { "resumed" }
        XCTAssertEqual(resumed, "resumed")
    }

    func testResourceRecoveryPreservesFIFOAndBoundedQueue() async throws {
        let firstQueued = CPUAsyncLatch()
        let secondQueued = CPUAsyncLatch()
        let notifications = CPUQueueNotifications(first: firstQueued, second: secondQueued)
        let starts = CPUStarts()
        let pool = try ReconstructionAnalysisProviderPool(factory: CPUResourceProviderFactory(),
            budget: .init(maximumActiveAnalyses: 1, estimatedResidentBytesPerAnalysis: 4, reservedHostBytes: 4),
            processorCount: 10, physicalMemory: 20,
            hooks: .init(afterWaiterEnqueue: { _ in notifications.enqueued() }),
            initialResourceSnapshot: snapshot(available: 0), maximumQueuedWaiters: 2)
        let first = Task { try await pool.withProvider { _ in await starts.append(1); return 1 } }
        await firstQueued.wait()
        let second = Task { try await pool.withProvider { _ in await starts.append(2); return 2 } }
        await secondQueued.wait()
        do {
            _ = try await pool.withProvider { _ in XCTFail("Full queue admitted work"); return 3 }
            XCTFail("Expected bounded queue rejection")
        } catch let error as ReconstructionAnalysisProviderPoolAdmissionError {
            XCTAssertEqual(error, .queueCapacityExceeded)
        }
        await pool.resourcesDidChange(snapshot(available: 20))
        let firstValue = try await first.value
        let secondValue = try await second.value
        let ordering = await starts.values
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(ordering, [1, 2])
    }

    func testUnknownHeadroomAndCriticalThermalDoNotMintProviders() async throws {
        let queued = CPUAsyncLatch()
        let pool = try makePool(initial: .init(availableMemoryBytes: nil,
            thermalState: .nominal, lowPowerMode: false, memoryPressure: .normal),
            enqueue: { _ in await queued.open() })
        let waiting = Task { try await pool.withProvider { _ in true } }
        await queued.wait()
        let unknown = await pool.snapshot()
        XCTAssertEqual(unknown.providerCount, 0)
        await pool.resourcesDidChange(.init(availableMemoryBytes: 20,
            thermalState: .critical, lowPowerMode: false, memoryPressure: .normal))
        let critical = await pool.snapshot()
        XCTAssertEqual(critical.effectiveAdmissionLimit, 0)
        await pool.retire()
        do { _ = try await waiting.value; XCTFail("Expected retired admission") }
        catch let error as ReconstructionAnalysisProviderPoolAdmissionError { XCTAssertEqual(error, .retired) }
    }

    private func makePool(initial: AnalysisHostResourceSnapshot,
        enqueue: @escaping @Sendable (UUID) async -> Void) throws -> ReconstructionAnalysisProviderPool {
        try .init(factory: CPUResourceProviderFactory(),
            budget: .init(maximumActiveAnalyses: 2, estimatedResidentBytesPerAnalysis: 4, reservedHostBytes: 4),
            processorCount: 10, physicalMemory: 20,
            hooks: .init(beforeWaiterEnqueue: enqueue), initialResourceSnapshot: initial)
    }

    private func snapshot(available: UInt64, pressure: AnalysisMemoryPressure = .normal) -> AnalysisHostResourceSnapshot {
        .init(availableMemoryBytes: available, thermalState: .nominal,
            lowPowerMode: false, memoryPressure: pressure)
    }
}

private actor CPUAsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct CPUResourceProviderFactory: ReconstructionAnalysisProviderFactory {
    func makeProvider() -> any AnalysisProviding { AnalysisEngine() }
}

private actor CPUStarts {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private final class CPUQueueNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let first: CPUAsyncLatch
    private let second: CPUAsyncLatch
    init(first: CPUAsyncLatch, second: CPUAsyncLatch) { self.first = first; self.second = second }
    func enqueued() {
        let next = lock.withLock { count += 1; return count }
        let latch = next == 1 ? first : second
        Task { await latch.open() }
    }
}

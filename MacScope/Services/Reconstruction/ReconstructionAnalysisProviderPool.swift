import Foundation

protocol ReconstructionAnalysisProviderFactory: Sendable {
    func makeProvider() -> any AnalysisProviding
}

struct ReconstructionDefaultAnalysisProviderFactory: ReconstructionAnalysisProviderFactory {
    let resourceBudget: AnalysisResourceBudget

    init(resourceBudget: AnalysisResourceBudget = .interactive) { self.resourceBudget = resourceBudget }

    func makeProvider() -> any AnalysisProviding {
        AnalysisProviderFactory.makeDefault(resourceBudget: resourceBudget)
    }
}

enum ReconstructionAnalysisProviderPoolBudgetError: Error, Equatable, Sendable {
    case insufficientHostMemory
    case capacityOverflow
}

enum ReconstructionAnalysisProviderPoolLifecycle: Equatable, Sendable {
    case active
    case paused
    case retired
}

enum ReconstructionAnalysisProviderPoolAdmissionError: Error, Equatable, Sendable {
    case paused
    case retired
    case queueCapacityExceeded
}

struct ReconstructionAnalysisProviderPoolBudget: Equatable, Sendable {
    let maximumActiveAnalyses: Int
    let estimatedResidentBytesPerAnalysis: UInt64
    let reservedHostBytes: UInt64
    let maximumInnerParallelism: Int

    init(
        maximumActiveAnalyses: Int,
        estimatedResidentBytesPerAnalysis: UInt64,
        reservedHostBytes: UInt64,
        maximumInnerParallelism: Int = 1
    ) {
        precondition(maximumActiveAnalyses > 0)
        precondition(estimatedResidentBytesPerAnalysis > 0)
        precondition((1...64).contains(maximumInnerParallelism))
        self.maximumInnerParallelism = maximumInnerParallelism
        self.maximumActiveAnalyses = maximumActiveAnalyses
        self.estimatedResidentBytesPerAnalysis = estimatedResidentBytesPerAnalysis
        self.reservedHostBytes = reservedHostBytes
    }

    func width(
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws -> Int {
        guard physicalMemory > reservedHostBytes else {
            throw ReconstructionAnalysisProviderPoolBudgetError.insufficientHostMemory
        }
        let usableMemory = physicalMemory - reservedHostBytes
        let memoryBound = usableMemory / estimatedResidentBytesPerAnalysis
        guard memoryBound > 0 else {
            throw ReconstructionAnalysisProviderPoolBudgetError.insufficientHostMemory
        }

        let policyBound = UInt64(maximumActiveAnalyses)
        let computeBound = UInt64(max(1, processorCount / maximumInnerParallelism))
        let selectedWidth = min(policyBound, computeBound, memoryBound)
        guard let exactWidth = Int(exactly: selectedWidth), exactWidth > 0 else {
            throw ReconstructionAnalysisProviderPoolBudgetError.capacityOverflow
        }
        return exactWidth
    }
}

struct ReconstructionAnalysisProviderPoolHooks: Sendable {
    let beforeWaiterEnqueue: (@Sendable (UUID) async -> Void)?
    let beforeWaiterCancellationRemoval: (@Sendable (UUID) async -> Void)?
    let beforePauseCompletion: (@Sendable () async -> Void)?
    let afterWaiterEnqueue: (@Sendable (UUID) -> Void)?

    init(
        beforeWaiterEnqueue: (@Sendable (UUID) async -> Void)? = nil,
        beforeWaiterCancellationRemoval: (@Sendable (UUID) async -> Void)? = nil,
        beforePauseCompletion: (@Sendable () async -> Void)? = nil,
        afterWaiterEnqueue: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.beforeWaiterEnqueue = beforeWaiterEnqueue
        self.beforeWaiterCancellationRemoval = beforeWaiterCancellationRemoval
        self.beforePauseCompletion = beforePauseCompletion
        self.afterWaiterEnqueue = afterWaiterEnqueue
    }

    static let none = Self()
}

struct ReconstructionAnalysisProviderPoolSnapshot: Equatable, Sendable {
    let width: Int
    let lifecycle: ReconstructionAnalysisProviderPoolLifecycle
    let effectiveAdmissionLimit: Int
    let resourceSnapshot: AnalysisHostResourceSnapshot?
    let providerCount: Int
    let activeProviderCount: Int
    let idleProviderCount: Int
    let queuedWaiterCount: Int
    let pendingPauseCallCount: Int
    let pendingResumeCallCount: Int
}

actor ReconstructionAnalysisProviderPool {
    private struct Waiter {
        let id: UUID
        let cancellation: ReconstructionProviderWaiterCancellation
        let continuation: CheckedContinuation<any AnalysisProviding, Error>
    }

    private let factory: any ReconstructionAnalysisProviderFactory
    private let hooks: ReconstructionAnalysisProviderPoolHooks
    private let budget: ReconstructionAnalysisProviderPoolBudget
    private let resourceMonitor: AnalysisHostResourceMonitor?
    private let maximumQueuedWaiters: Int
    private let globalAdmission: ReconstructionGlobalAnalysisAdmission?
    private let globalOwner = ReconstructionAnalysisAdmissionOwner()
    private var observingResources = false
    private var resourceSnapshot: AnalysisHostResourceSnapshot?
    let width: Int
    private var lifecycle: ReconstructionAnalysisProviderPoolLifecycle = .active
    private var idle: [any AnalysisProviding] = []
    private var providerCount = 0
    private var activeProviderCount = 0
    private var waiters: [Waiter] = []
    private var activeLeaseSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingPauseCallCount = 0
    private var pendingResumeCallCount = 0
    private var pauseCallSettlementWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        factory: any ReconstructionAnalysisProviderFactory,
        budget: ReconstructionAnalysisProviderPoolBudget,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        hooks: ReconstructionAnalysisProviderPoolHooks = .none,
        resourceMonitor: AnalysisHostResourceMonitor? = nil,
        initialResourceSnapshot: AnalysisHostResourceSnapshot? = nil,
        maximumQueuedWaiters: Int = 256,
        globalAdmission: ReconstructionGlobalAnalysisAdmission? = nil
    ) throws {
        precondition(maximumQueuedWaiters > 0)
        self.globalAdmission = globalAdmission
        self.budget = budget
        self.resourceMonitor = resourceMonitor
        self.maximumQueuedWaiters = maximumQueuedWaiters
        self.resourceSnapshot = initialResourceSnapshot ?? resourceMonitor?.snapshot()
        self.factory = factory
        self.hooks = hooks
        let selectedWidth = try budget.width(
            processorCount: processorCount,
            physicalMemory: physicalMemory
        )
        width = selectedWidth
    }

    func withProvider<T: Sendable>(
        _ operation: @Sendable (any AnalysisProviding) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let provider = try await acquire()
        defer { release(provider) }
        try Task.checkCancellation()
        if let globalAdmission {
            return try await globalAdmission.withPermit(owner: globalOwner) {
                try await operation(provider)
            }
        }
        return try await operation(provider)
    }

    func snapshot() -> ReconstructionAnalysisProviderPoolSnapshot {
        .init(
            width: width,
            lifecycle: lifecycle,
            effectiveAdmissionLimit: effectiveLimit(),
            resourceSnapshot: resourceSnapshot,
            providerCount: providerCount,
            activeProviderCount: activeProviderCount,
            idleProviderCount: idle.count,
            queuedWaiterCount: waiters.count,
            pendingPauseCallCount: pendingPauseCallCount,
            pendingResumeCallCount: pendingResumeCallCount
        )
    }

    /// Closes admission and immediately settles queued acquisitions. Existing leases are allowed
    /// to return through their ordinary defer path; pause itself does not invent provider teardown
    /// or interrupt an `AnalysisProviding` operation behind the caller's cancellation authority.
    func pause() async {
        switch lifecycle {
        case .active:
            lifecycle = .paused
            globalOwner.set(.paused)
            drainWaiters(with: .paused)
        case .paused:
            break
        case .retired:
            return
        }
        pendingPauseCallCount += 1
        if let globalAdmission { await globalAdmission.ownerStateChanged(globalOwner) }
        await waitForActiveLeasesToSettle()
        if let beforePauseCompletion = hooks.beforePauseCompletion {
            await beforePauseCompletion()
        }
        pendingPauseCallCount -= 1
        settlePauseCallWaitersIfNeeded()
    }

    /// Reopens admission only after every lease that predated pause has returned. Retirement wins
    /// any race with resume and remains terminal.
    func resume() async {
        guard lifecycle == .paused else { return }
        pendingResumeCallCount += 1
        defer { pendingResumeCallCount -= 1 }
        await waitForActiveLeasesToSettle()
        guard lifecycle == .paused else { return }
        await waitForPauseCallsToSettle()
        guard lifecycle == .paused else { return }
        lifecycle = .active
        globalOwner.set(.active)
        refreshResources()
        admitQueuedWaiters()
    }

    /// Permanently closes admission. The provider protocol has no teardown contract, so retirement
    /// drops idle references now and returning active references through `release` later.
    func retire() async {
        guard lifecycle != .retired else { return }
        lifecycle = .retired
        globalOwner.set(.retired)
        drainWaiters(with: .retired)
        providerCount -= idle.count
        idle.removeAll(keepingCapacity: false)
        // Retirement supersedes both pause and resume. Wake lifecycle waiters immediately so a
        // raced resume cannot remain suspended behind a non-cooperative provider or a paused call
        // that no longer needs to establish resumable state. Active providers are still counted
        // and discarded only when their ordinary lease defer returns.
        resumeAndClear(&activeLeaseSettlementWaiters)
        resumeAndClear(&pauseCallSettlementWaiters)
        if let globalAdmission { await globalAdmission.ownerStateChanged(globalOwner) }
    }

    private func acquire() async throws -> any AnalysisProviding {
        try validateActiveAdmission()
        startResourceObservationIfNeeded()
        refreshResources()
        // Never bypass older waiters, including across a resource recovery.
        admitQueuedWaiters()
        if waiters.isEmpty, activeProviderCount < effectiveLimit() {
            return takeProvider()
        }
        guard waiters.count < maximumQueuedWaiters else {
            throw ReconstructionAnalysisProviderPoolAdmissionError.queueCapacityExceeded
        }

        let waiterID = UUID()
        let cancellation = ReconstructionProviderWaiterCancellation()
        return try await withTaskCancellationHandler {
            if let beforeWaiterEnqueue = hooks.beforeWaiterEnqueue {
                await beforeWaiterEnqueue(waiterID)
            }
            return try await withCheckedThrowingContinuation { continuation in
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do { try validateActiveAdmission() }
                catch { continuation.resume(throwing: error); return }
                // A hook may suspend long enough for other callers to fill the queue.
                guard waiters.count < maximumQueuedWaiters else {
                    continuation.resume(throwing: ReconstructionAnalysisProviderPoolAdmissionError.queueCapacityExceeded)
                    return
                }
                waiters.append(.init(id: waiterID, cancellation: cancellation, continuation: continuation))
                hooks.afterWaiterEnqueue?(waiterID)
                refreshResources()
                admitQueuedWaiters()
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func takeProvider() -> any AnalysisProviding {
        activeProviderCount += 1
        if let provider = idle.popLast() { return provider }
        precondition(providerCount < width)
        providerCount += 1
        return factory.makeProvider()
    }

    private func startResourceObservationIfNeeded() {
        guard !observingResources, let resourceMonitor else { return }
        observingResources = true
        resourceMonitor.observe { [weak self] snapshot in
            Task { await self?.resourcesDidChange(snapshot) }
        }
    }

    private func refreshResources() {
        if let resourceMonitor { resourceSnapshot = resourceMonitor.snapshot() }
    }

    /// Testable event ingress. Admission never interrupts active work; a shrinking limit only
    /// prevents another lease until active leases drain beneath that limit.
    func resourcesDidChange(_ snapshot: AnalysisHostResourceSnapshot) {
        guard lifecycle != .retired else { return }
        // Actor hops can reorder callback tasks: live consumers resample current state.
        resourceSnapshot = resourceMonitor?.snapshot() ?? snapshot
        admitQueuedWaiters()
    }

    private func effectiveLimit() -> Int {
        guard let snapshot = resourceSnapshot else { return width }
        guard snapshot.memoryPressure != .critical,
              snapshot.thermalState != .critical,
              let available = snapshot.availableMemoryBytes,
              available > budget.reservedHostBytes else { return 0 }
        var computeLimit = width
        if snapshot.lowPowerMode || snapshot.thermalState == .fair { computeLimit = max(1, width / 2) }
        if snapshot.thermalState == .serious || snapshot.memoryPressure == .warning { computeLimit = 1 }
        // Reserve the full estimate for every active lease against this sample, even if some
        // resident pages already appear in VM usage. This deliberately conservative double
        // accounting prevents delayed worker allocations from spending one sample twice.
        let memoryLimit = (available - budget.reservedHostBytes) / budget.estimatedResidentBytesPerAnalysis
        return min(computeLimit, Int(min(UInt64(width), memoryLimit)))
    }

    private func admitQueuedWaiters() {
        guard lifecycle == .active else { return }
        // Freeze one sample's reservation count for this drain: recomputing after each mint
        // would incorrectly grant the same observed free bytes repeatedly.
        let limit = effectiveLimit()
        while !waiters.isEmpty {
            let waiter = waiters[0]
            if waiter.cancellation.isCancelled {
                waiters.removeFirst().continuation.resume(throwing: CancellationError())
                continue
            }
            guard activeProviderCount < limit else { return }
            waiters.removeFirst().continuation.resume(returning: takeProvider())
        }
    }

    private func cancelWaiter(_ waiterID: UUID) async {
        if let beforeWaiterCancellationRemoval = hooks.beforeWaiterCancellationRemoval {
            await beforeWaiterCancellationRemoval(waiterID)
        }
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        admitQueuedWaiters()
    }

    private func release(_ provider: any AnalysisProviding) {
        precondition(activeProviderCount > 0)
        activeProviderCount -= 1
        switch lifecycle {
        case .active, .paused:
            idle.append(provider)
        case .retired:
            providerCount -= 1
        }
        refreshResources()
        admitQueuedWaiters()
        settleActiveLeaseWaitersIfNeeded()
    }

    private func validateActiveAdmission() throws {
        switch lifecycle {
        case .active:
            break
        case .paused:
            throw ReconstructionAnalysisProviderPoolAdmissionError.paused
        case .retired:
            throw ReconstructionAnalysisProviderPoolAdmissionError.retired
        }
    }

    private func drainWaiters(with error: ReconstructionAnalysisProviderPoolAdmissionError) {
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in current {
            if waiter.cancellation.isCancelled {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func waitForActiveLeasesToSettle() async {
        guard activeProviderCount > 0 else { return }
        await withCheckedContinuation { continuation in
            activeLeaseSettlementWaiters.append(continuation)
        }
    }

    private func settleActiveLeaseWaitersIfNeeded() {
        guard activeProviderCount == 0 else { return }
        let current = activeLeaseSettlementWaiters
        activeLeaseSettlementWaiters.removeAll(keepingCapacity: false)
        current.forEach { $0.resume() }
    }

    private func waitForPauseCallsToSettle() async {
        guard pendingPauseCallCount > 0 else { return }
        await withCheckedContinuation { continuation in
            pauseCallSettlementWaiters.append(continuation)
        }
    }

    private func settlePauseCallWaitersIfNeeded() {
        guard pendingPauseCallCount == 0 else { return }
        resumeAndClear(&pauseCallSettlementWaiters)
    }

    private func resumeAndClear(
        _ continuations: inout [CheckedContinuation<Void, Never>]
    ) {
        let current = continuations
        continuations.removeAll(keepingCapacity: false)
        current.forEach { $0.resume() }
    }
}

private final class ReconstructionProviderWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

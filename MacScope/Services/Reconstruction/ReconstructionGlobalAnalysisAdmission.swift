import Foundation

/// A shared CPU lease across production job/cut pools. Per-pool resource admission remains
/// stricter when memory or thermal headroom is low. No job can multiply the host outer budget.
actor ReconstructionGlobalAnalysisAdmission {
    static let shared = ReconstructionGlobalAnalysisAdmission(maximumActive: AnalysisHostResourcePolicy
        .reconstructionParallelism(processorCount: ProcessInfo.processInfo.activeProcessorCount).outer)

    private struct Waiter {
        let id: UUID
        let owner: ReconstructionAnalysisAdmissionOwner
        let cancellation: ReconstructionGlobalWaiterCancellation
        let continuation: CheckedContinuation<Void, Error>
    }
    private let maximumActive: Int
    private let maximumQueued: Int
    private let onWaiterEnqueue: (@Sendable () -> Void)?
    private var active = 0
    private var waiters: [Waiter] = []

    init(maximumActive: Int, maximumQueued: Int = 256,
         onWaiterEnqueue: (@Sendable () -> Void)? = nil) {
        precondition(maximumActive > 0 && maximumQueued > 0)
        self.maximumActive = maximumActive
        self.maximumQueued = maximumQueued
        self.onWaiterEnqueue = onWaiterEnqueue
    }

    func withPermit<T: Sendable>(owner: ReconstructionAnalysisAdmissionOwner,
        _ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(owner: owner)
        defer { active -= 1; admitWaiters() }
        try Task.checkCancellation()
        try owner.validate()
        return try await operation()
    }

    /// Owner state is set synchronously by the pool before this actor hop, closing the
    /// enqueue/drain race. Queued work fails; work with an accepted permit finishes normally.
    func ownerStateChanged(_ owner: ReconstructionAnalysisAdmissionOwner) {
        admitWaiters()
    }

    private func acquire(owner: ReconstructionAnalysisAdmissionOwner) async throws {
        try Task.checkCancellation()
        try owner.validate()
        admitWaiters()
        if waiters.isEmpty, active < maximumActive { active += 1; return }
        guard waiters.count < maximumQueued else {
            throw ReconstructionAnalysisProviderPoolAdmissionError.queueCapacityExceeded
        }
        let id = UUID()
        let cancellation = ReconstructionGlobalWaiterCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                do { try owner.validate() }
                catch { continuation.resume(throwing: error); return }
                waiters.append(.init(id: id, owner: owner, cancellation: cancellation, continuation: continuation))
                onWaiterEnqueue?()
                admitWaiters()
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        admitWaiters()
    }

    private func admitWaiters() {
        // Remove invalid waiters everywhere, even behind a different owner's valid FIFO head.
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            do {
                if waiter.cancellation.isCancelled { throw CancellationError() }
                try waiter.owner.validate()
                index += 1
            } catch {
                waiters.remove(at: index).continuation.resume(throwing: error)
            }
        }
        while active < maximumActive, !waiters.isEmpty {
            active += 1
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// Lock audit: owner state crosses pool/global actors through this one locked cell. It carries
/// no analysis bytes, does not cancel an accepted operation and has no retained global registry.
final class ReconstructionAnalysisAdmissionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycle: ReconstructionAnalysisProviderPoolLifecycle = .active
    func set(_ state: ReconstructionAnalysisProviderPoolLifecycle) { lock.withLock { lifecycle = state } }
    func validate() throws {
        try lock.withLock {
            switch lifecycle {
            case .active: break
            case .paused: throw ReconstructionAnalysisProviderPoolAdmissionError.paused
            case .retired: throw ReconstructionAnalysisProviderPoolAdmissionError.retired
            }
        }
    }
}

private final class ReconstructionGlobalWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

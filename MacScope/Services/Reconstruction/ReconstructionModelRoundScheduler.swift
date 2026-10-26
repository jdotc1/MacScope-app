import Foundation

struct ReconstructionModelRoundAdmission: Hashable, Sendable {
    let jobID: UUID
    let jobCreationOrder: UInt64
    let checkpointRevision: UInt64
}

actor ReconstructionModelRoundScheduler {
    typealias AfterQueuedAdmissionGranted = @Sendable (
        ReconstructionModelRoundAdmission
    ) async -> Void

    private struct Lease: Hashable, Sendable { let id: UUID }
    private struct Waiter {
        let id: UUID
        let admission: ReconstructionModelRoundAdmission
        let sequence: UInt64
        let continuation: CheckedContinuation<Lease, Error>
    }

    private var activeLease: Lease?
    private var waiters: [Waiter] = []
    private var queueObservationWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var cancellationObservationWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private let afterQueuedAdmissionGranted: AfterQueuedAdmissionGranted?
    private var pendingEnqueueWaiterIDs: Set<UUID> = []
    private var cancelledWaiterIDs: Set<UUID> = []
    private var cancellationObservationCount = 0
    private var nextSequence: UInt64 = 0

    init(
        afterQueuedAdmissionGranted: AfterQueuedAdmissionGranted? = nil
    ) {
        self.afterQueuedAdmissionGranted = afterQueuedAdmissionGranted
    }

    /// Internal condition seam used by deterministic concurrency tests. It observes only queued
    /// admissions and does not participate in ordering or lease ownership.
    func waitUntilQueuedAdmissionCount(_ count: Int) async {
        if waiters.count >= count { return }
        await withCheckedContinuation { continuation in
            queueObservationWaiters.append((count, continuation))
        }
    }

    /// Internal condition seam used only to make cancellation races deterministic in tests.
    func waitUntilCancellationObservationCount(_ count: Int) async {
        if cancellationObservationCount >= count { return }
        await withCheckedContinuation { continuation in
            cancellationObservationWaiters.append((count, continuation))
        }
    }

    func snapshot() -> ReconstructionModelRoundSchedulerSnapshot {
        .init(
            activeLeaseCount: activeLease == nil ? 0 : 1,
            queuedAdmissionCount: waiters.count,
            pendingEnqueueCount: pendingEnqueueWaiterIDs.count,
            cancelledWaiterTombstoneCount: cancelledWaiterIDs.count
        )
    }

    func withAdmission<Value: Sendable>(
        _ admission: ReconstructionModelRoundAdmission,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire(admission)
        defer { release(lease) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(
        _ admission: ReconstructionModelRoundAdmission
    ) async throws -> Lease {
        try Task.checkCancellation()
        if activeLease == nil, waiters.isEmpty {
            let lease = Lease(id: UUID())
            activeLease = lease
            return lease
        }
        let waiterID = UUID()
        pendingEnqueueWaiterIDs.insert(waiterID)
        return try await withTaskCancellationHandler {
            let lease = try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    id: waiterID,
                    admission: admission,
                    continuation: continuation
                )
            }
            if let afterQueuedAdmissionGranted {
                await afterQueuedAdmissionGranted(admission)
            }
            return lease
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func enqueue(
        id: UUID,
        admission: ReconstructionModelRoundAdmission,
        continuation: CheckedContinuation<Lease, Error>
    ) {
        precondition(pendingEnqueueWaiterIDs.remove(id) != nil)
        if cancelledWaiterIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        let sequence = nextSequence
        nextSequence &+= 1
        waiters.append(.init(
            id: id,
            admission: admission,
            sequence: sequence,
            continuation: continuation
        ))
        let ready = queueObservationWaiters.filter { waiters.count >= $0.count }
        queueObservationWaiters.removeAll { waiters.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        cancellationObservationCount &+= 1
        let observations = cancellationObservationWaiters.filter {
            cancellationObservationCount >= $0.count
        }
        cancellationObservationWaiters.removeAll {
            cancellationObservationCount >= $0.count
        }
        observations.forEach { $0.continuation.resume() }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else if pendingEnqueueWaiterIDs.contains(id) {
            cancelledWaiterIDs.insert(id)
        }
    }

    private func release(_ lease: Lease) {
        guard activeLease == lease else { return }
        activeLease = nil
        while !waiters.isEmpty {
            let index = waiters.indices.min { left, right in
                Self.precedes(waiters[left], waiters[right])
            }!
            let waiter = waiters.remove(at: index)
            if cancelledWaiterIDs.remove(waiter.id) != nil {
                waiter.continuation.resume(throwing: CancellationError())
                continue
            }
            let next = Lease(id: waiter.id)
            activeLease = next
            waiter.continuation.resume(returning: next)
            return
        }
    }

    private static func precedes(_ lhs: Waiter, _ rhs: Waiter) -> Bool {
        if lhs.admission.jobCreationOrder != rhs.admission.jobCreationOrder {
            return lhs.admission.jobCreationOrder < rhs.admission.jobCreationOrder
        }
        if lhs.admission.checkpointRevision != rhs.admission.checkpointRevision {
            return lhs.admission.checkpointRevision < rhs.admission.checkpointRevision
        }
        if lhs.admission.jobID != rhs.admission.jobID {
            return lhs.admission.jobID.uuidString < rhs.admission.jobID.uuidString
        }
        return lhs.sequence < rhs.sequence
    }
}

struct ReconstructionModelRoundSchedulerSnapshot: Equatable, Sendable {
    let activeLeaseCount: Int
    let queuedAdmissionCount: Int
    let pendingEnqueueCount: Int
    let cancelledWaiterTombstoneCount: Int
}

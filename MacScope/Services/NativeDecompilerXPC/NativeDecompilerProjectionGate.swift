import Foundation

struct NativeDecompilerProjectionGateConfiguration: Equatable, Sendable {
    let maximumQueuedEntries: Int
    let maximumQueuedWeight: UInt64

    init(
        maximumQueuedEntries: Int = 8,
        maximumQueuedWeight: UInt64 = 32 * 1_048_576
    ) {
        precondition(maximumQueuedEntries >= 0)
        self.maximumQueuedEntries = maximumQueuedEntries
        self.maximumQueuedWeight = maximumQueuedWeight
    }
}

/// Stable structural coordinate for projection work. Authored semantic inputs are intentionally
/// outside the analysis fingerprint, so this value alone is not complete coalescing authority.
struct NativeDecompilerProjectionKey: Hashable, Sendable {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID
    let analysisInputFingerprintSHA256: String
    let functionID: UUID
}

enum NativeDecompilerProjectionGateError: Error, Equatable, Sendable {
    case attemptIdentifierExhausted
}

private struct NativeDecompilerProjectionWorkKey: Hashable, Sendable {
    let coordinate: NativeDecompilerProjectionKey
    let attemptIdentifier: UInt64
}

/// Bounded, owner-fair gate for eager snapshot projection. Projection finishes before a request
/// can consume native process-lane capacity, and its synchronous builder runs off actor isolation
/// through `FairSingleLaneWorkScheduler`'s concurrent operation runner.
actor NativeDecompilerProjectionGate {
    typealias ProjectionOperation = @Sendable () async throws
        -> NativeDecompilerSnapshotProjection

    private let scheduler:
        FairSingleLaneWorkScheduler<UUID, NativeDecompilerProjectionWorkKey,
            NativeDecompilerSnapshotProjection>
    private var attemptIdentifier: UInt64 = 0

    init(configuration: NativeDecompilerProjectionGateConfiguration = .init()) {
        scheduler = FairSingleLaneWorkScheduler(
            maximumQueuedEntries: configuration.maximumQueuedEntries,
            maximumQueuedWeight: configuration.maximumQueuedWeight
        )
    }

    func project(
        owner: UUID,
        key: NativeDecompilerProjectionKey,
        queuedWeight: UInt64,
        operation: @escaping ProjectionOperation
    ) async throws -> NativeDecompilerSnapshotProjection {
        guard attemptIdentifier < .max else {
            throw NativeDecompilerProjectionGateError.attemptIdentifierExhausted
        }
        attemptIdentifier += 1
        return try await scheduler.submit(
            owner: owner,
            key: NativeDecompilerProjectionWorkKey(
                coordinate: key,
                attemptIdentifier: attemptIdentifier
            ),
            queuedWeight: queuedWeight,
            operation: operation
        )
    }

    func snapshot() async -> FairSingleLaneSchedulerSnapshot {
        await scheduler.snapshot()
    }

    func shutdown() async {
        await scheduler.shutdown()
    }
}

import Foundation

protocol DyldCacheAnalysisTransport: Sendable {
    func sendDyldCacheInspection(requestID: UUID, payload: Data) async throws -> Data
    func cancelDyldCacheInspection(requestID: UUID)
    /// A deadline means the serial worker may still be executing uncooperative vendor code.
    /// Retire that connection and complete every continuation attached to it before reuse.
    func retireDyldCacheConnection(requestID: UUID)
}

/// Deterministic transport fake used by client lifecycle tests. Production transport wiring lives
/// in `NSXPCConnectionTransport`; this fake never opens a connection or reads a source artifact.
final class MockDyldCacheAnalysisTransport: DyldCacheAnalysisTransport, @unchecked Sendable {
    indirect enum Outcome: Sendable {
        case reply(Data)
        case interrupt
        case invalidate
        case hang
        case delay(nanoseconds: UInt64, then: Outcome)
    }

    struct Call: Equatable, Sendable {
        let requestID: UUID
        let payload: Data
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var recordedCalls: [Call] = []
    private var recordedCancellations: [UUID] = []
    private var recordedRetirements: [UUID] = []
    private var cancellationsBeforeSuspension: Set<UUID> = []
    private var hungContinuations: [UUID: CheckedContinuation<Data, Error>] = [:]

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    var calls: [Call] { withLock { recordedCalls } }
    var cancelledRequestIDs: [UUID] { withLock { recordedCancellations } }
    var retiredRequestIDs: [UUID] { withLock { recordedRetirements } }

    func enqueue(_ outcome: Outcome) {
        withLock { outcomes.append(outcome) }
    }

    func sendDyldCacheInspection(requestID: UUID, payload: Data) async throws -> Data {
        let outcome: Outcome = withLock {
            recordedCalls.append(Call(requestID: requestID, payload: payload))
            return outcomes.isEmpty ? .hang : outcomes.removeFirst()
        }
        return try await resolve(outcome, requestID: requestID)
    }

    func cancelDyldCacheInspection(requestID: UUID) {
        let continuation: CheckedContinuation<Data, Error>? = withLock {
            recordedCancellations.append(requestID)
            if let continuation = hungContinuations.removeValue(forKey: requestID) {
                return continuation
            }
            cancellationsBeforeSuspension.insert(requestID)
            return nil
        }
        continuation?.resume(throwing: AnalysisCancelled())
    }

    func retireDyldCacheConnection(requestID: UUID) {
        withLock { recordedRetirements.append(requestID) }
        cancelDyldCacheInspection(requestID: requestID)
    }

    private func resolve(_ outcome: Outcome, requestID: UUID) async throws -> Data {
        switch outcome {
        case let .reply(data):
            return data
        case .interrupt:
            throw AnalysisTransportError.interrupted(reason: "scripted dyld-cache interruption")
        case .invalidate:
            throw AnalysisTransportError.invalidated(reason: "scripted dyld-cache invalidation")
        case .hang:
            return try await withCheckedThrowingContinuation { continuation in
                let wasCancelled: Bool = withLock {
                    if cancellationsBeforeSuspension.remove(requestID) != nil {
                        return true
                    }
                    hungContinuations[requestID] = continuation
                    return false
                }
                if wasCancelled {
                    continuation.resume(throwing: AnalysisCancelled())
                }
            }
        case let .delay(nanoseconds, then):
            try await Task.sleep(nanoseconds: nanoseconds)
            return try await resolve(then, requestID: requestID)
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

import Foundation

/// Tracks cooperative cancellation, the HOP-3 budget and the latest progress for analyses
/// dispatched concurrently by the worker service.
///
/// A cancellation can reach the XPC service before its matching `handle` call begins. Unknown IDs
/// are therefore retained in `cancelledBeforeRegistration` and consumed by `register(requestID:)`,
/// which returns a token whose state has already been cancelled. A progress poll for an unknown or
/// finished ID answers nil and records nothing.
final class AnalysisWorkerCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeStates: [UUID: RequestState] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    /// Registers a fresh token for `requestID`, applying any cancellation that arrived early. The
    /// budget's clock starts here; the token reports each phase straight to this request's state.
    func register(requestID: UUID, budget: AnalysisBudget = .unlimited) -> AnalysisCancellationToken {
        let state = RequestState()

        lock.lock()
        if cancelledBeforeRegistration.remove(requestID) != nil {
            state.cancel()
        }
        activeStates[requestID] = state
        lock.unlock()

        return .budgeted(isCancelled: { state.isCancelled }, budget: budget,
                         progress: { state.record($0) })
    }

    /// Cancels the active token, or records the intent when registration has not happened yet.
    func cancel(requestID: UUID) {
        lock.lock()
        if let state = activeStates[requestID] {
            state.cancel()
        } else {
            cancelledBeforeRegistration.insert(requestID)
        }
        lock.unlock()
    }

    /// The latest phase the request reported, or nil when it is unknown, finished, or hasn't
    /// reached its first phase. Never inserts anything.
    func progress(requestID: UUID) -> AnalysisProgress? {
        lock.lock()
        let state = activeStates[requestID]
        lock.unlock()
        return state?.latestProgress
    }

    /// Removes only the token installed by the matching `handle` invocation.
    func deregister(requestID: UUID) {
        lock.lock()
        activeStates.removeValue(forKey: requestID)
        lock.unlock()
    }
}

private final class RequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var progress: AnalysisProgress?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var latestProgress: AnalysisProgress? {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func record(_ progress: AnalysisProgress) {
        lock.lock()
        self.progress = progress
        lock.unlock()
    }
}

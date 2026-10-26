import Foundation

/// Opaque byte transport used by `XPCAnalysisProvider`.
///
/// Band 2 supplies the real `NSXPCConnection` implementation. Keeping that detail out of this
/// protocol makes the connection state machine deterministic and exhaustively fault-testable.
protocol AnalysisTransport: Sendable {
    func send(requestID: UUID, payload: Data) async throws -> Data
    func sendPinned(requestID: UUID, payload: Data, source: FileHandle) async throws -> Data
    /// MS-18: package rehydrate on the analysis channel; `cancel(requestID:)` applies.
    func sendRehydrate(requestID: UUID, payload: Data) async throws -> Data
    /// PERF-C: rehydrate with the image bytes on a sealed descriptor; `cancel(requestID:)` applies.
    func sendRehydratePinned(requestID: UUID, payload: Data, imageSource: FileHandle) async throws -> Data
    func cancel(requestID: UUID)
    /// HOP-3: the latest phase the worker reports for `requestID`, or nil when it can't say
    /// (unknown or finished request, no live connection, no answer in time).
    func progress(requestID: UUID) async -> AnalysisProgress?
}

extension AnalysisTransport {
    /// Scripted and injected transports report no progress.
    func progress(requestID: UUID) async -> AnalysisProgress? { nil }

    func sendPinned(requestID: UUID, payload: Data, source: FileHandle) async throws -> Data {
        throw AnalysisTransportError.invalidated(reason: "pinned descriptor transport is unavailable")
    }

    func sendRehydrate(requestID: UUID, payload: Data) async throws -> Data {
        throw AnalysisTransportError.invalidated(reason: "rehydrate transport is unavailable")
    }

    func sendRehydratePinned(requestID: UUID, payload: Data, imageSource: FileHandle) async throws -> Data {
        throw AnalysisTransportError.invalidated(reason: "pinned rehydrate transport is unavailable")
    }
}

/// Events a real transport reports from its NSXPCConnection handlers.
enum AnalysisTransportError: Error, Equatable {
    case interrupted(reason: String)
    case invalidated(reason: String)
}

/// Lock-protected, scriptable transport for exercising the client lifecycle without a service.
final class MockAnalysisTransport: AnalysisTransport, @unchecked Sendable {
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
    private var hungContinuations: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var recordedHungResolutions: [UUID] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    var calls: [Call] {
        withLock { recordedCalls }
    }

    var cancelledRequestIDs: [UUID] {
        withLock { recordedCancellations }
    }

    var resolvedHungRequestIDs: [UUID] {
        withLock { recordedHungResolutions }
    }

    func enqueue(_ outcome: Outcome) {
        withLock { outcomes.append(outcome) }
    }

    func send(requestID: UUID, payload: Data) async throws -> Data {
        let outcome = takeOutcomeAndRecordCall(requestID: requestID, payload: payload)
        return try await resolve(outcome, requestID: requestID)
    }

    /// Scripted exactly like `send`; the call is recorded in the same list.
    func sendRehydrate(requestID: UUID, payload: Data) async throws -> Data {
        try await send(requestID: requestID, payload: payload)
    }

    /// Scripted exactly like `send`; the call is recorded in the same list.
    func sendRehydratePinned(requestID: UUID, payload: Data, imageSource: FileHandle) async throws -> Data {
        try await send(requestID: requestID, payload: payload)
    }

    func cancel(requestID: UUID) {
        let continuation: CheckedContinuation<Data, Error>? = withLock {
            recordedCancellations.append(requestID)
            return hungContinuations.removeValue(forKey: requestID)
        }
        continuation?.resume(throwing: AnalysisCancelled())
    }

    /// Delivers a reply to a request scripted as `.hang`. Returns false when the request is no
    /// longer pending (for example, because the provider already forwarded cancellation).
    @discardableResult
    func resolveHungRequest(requestID: UUID, with reply: Data) -> Bool {
        let continuation: CheckedContinuation<Data, Error>? = withLock {
            guard let continuation = hungContinuations.removeValue(forKey: requestID) else {
                return nil
            }
            recordedHungResolutions.append(requestID)
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: reply)
        return true
    }

    private func resolve(_ outcome: Outcome, requestID: UUID) async throws -> Data {
        switch outcome {
        case .reply(let data):
            return data
        case .interrupt:
            throw AnalysisTransportError.interrupted(reason: "connection interrupted")
        case .invalidate:
            throw AnalysisTransportError.invalidated(reason: "connection invalidated")
        case .hang:
            return try await withCheckedThrowingContinuation { continuation in
                installHungContinuation(continuation, requestID: requestID)
            }
        case .delay(let nanoseconds, let delayedOutcome):
            try await Task.sleep(nanoseconds: nanoseconds)
            return try await resolve(delayedOutcome, requestID: requestID)
        }
    }

    private func takeOutcomeAndRecordCall(requestID: UUID, payload: Data) -> Outcome {
        withLock {
            recordedCalls.append(Call(requestID: requestID, payload: payload))
            guard !outcomes.isEmpty else {
                return .invalidate
            }
            return outcomes.removeFirst()
        }
    }

    private func installHungContinuation(
        _ continuation: CheckedContinuation<Data, Error>,
        requestID: UUID
    ) {
        let installation: (wasAlreadyCancelled: Bool, displaced: CheckedContinuation<Data, Error>?) = withLock {
            if recordedCancellations.contains(requestID) {
                return (true, nil)
            }
            return (false, hungContinuations.updateValue(continuation, forKey: requestID))
        }
        if installation.wasAlreadyCancelled {
            continuation.resume(throwing: AnalysisCancelled())
            return
        }
        installation.displaced?.resume(
            throwing: AnalysisTransportError.invalidated(reason: "duplicate request identifier")
        )
    }

    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

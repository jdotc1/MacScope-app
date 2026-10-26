import Foundation

/// `AnalysisProviding` proxy that isolates connection lifecycle from the concrete XPC transport.
/// Its serialization seam is `AnalysisClientWireCodec` (defined in `AnalysisWireCodec.swift`); the
/// proxy knows neither the payload's fields nor its encoding — only request lifecycle and error
/// mapping.
final class XPCAnalysisProvider: PinnedAnalysisInputProviding, @unchecked Sendable {
    enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case analyzing(UUID)
        case interrupted
        case invalidated
    }

    private let requestedResourceBudget: AnalysisResourceBudget?
    private let hostResourceBudget: @Sendable () -> AnalysisResourceBudget
    var resourceBudget: AnalysisResourceBudget {
        let current = hostResourceBudget()
        return requestedResourceBudget?.clamped(to: current) ?? current
    }
    let transport: any AnalysisTransport
    private let codec: any AnalysisClientWireCodec
    private let stateLock = NSLock()
    private var state: ConnectionState = .idle
    private var invalidationReason: String?

    init(transport: any AnalysisTransport, codec: any AnalysisClientWireCodec,
         resourceBudget: AnalysisResourceBudget? = nil,
         hostResourceBudget: @escaping @Sendable () -> AnalysisResourceBudget = { .interactive }) {
        self.requestedResourceBudget = resourceBudget
        self.hostResourceBudget = hostResourceBudget
        self.transport = transport
        self.codec = codec
    }

    var connectionState: ConnectionState {
        withStateLock { state }
    }

    /// Clears a sticky invalidation after an external owner has made a new service available.
    /// Ordinary requests never call this automatically: invalidation remains a terminal state
    /// until the application explicitly establishes that recovery is appropriate.
    func resetConnection() {
        withStateLock {
            state = .idle
            invalidationReason = nil
        }
    }

    /// Synchronous protocol bridge used by scripting/headless callers.
    ///
    /// Work starts in a detached task so it cannot inherit an actor (especially MainActor) whose
    /// thread the caller then blocks. A semaphore preserves the protocol's synchronous completion
    /// contract, and `BlockingResultBox` transfers the identical async result/error back safely.
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        try analyze(
            url: url,
            selection: .machOSlice(requestedSliceIndex),
            overrides: overrides,
            cancellation: cancellation
        )
    }

    func analyze(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = BlockingResultBox<WorkspaceSnapshot>()

        Task.detached { [self] in
            let result: Result<WorkspaceSnapshot, Error>
            do {
                result = .success(
                    try await performAnalysis(
                        url: url,
                        selection: selection,
                        overrides: overrides,
                        cancellation: cancellation
                    )
                )
            } catch {
                result = .failure(error)
            }
            resultBox.store(result)
            semaphore.signal()
        }

        semaphore.wait()
        return try resultBox.take().get()
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try await openBinary(
            url: url,
            selection: .machOSlice(requestedSliceIndex),
            overrides: overrides,
            cancellation: cancellation
        )
    }

    func openPinnedBinary(
        url: URL,
        source: FileHandle,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        if Task.isCancelled || cancellation.isCancelled { throw AnalysisCancelled() }
        let requestID = UUID()
        try beginRequest(requestID: requestID)
        let payload = codec.encodeRequest(url: url, selection: selection, overrides: overrides, requestID: requestID,
                                          resourceBudget: resourceBudget, analysisBudget: Self.wireBudget(cancellation))
        do {
            let reply = try await awaitPinnedReply(
                requestID: requestID, payload: payload, source: source, cancellation: cancellation
            )
            finishRequest(requestID: requestID, state: .idle)
            do {
                // PERF-C2: the reply may name the image bytes as a range of `source`; the codec
                // reads them from this (the client's own) handle and verifies their SHA-256.
                return try codec.decodeReply(reply, pinnedSource: source)
            } catch is AnalysisCancelled {
                throw AnalysisCancelled()
            } catch let failure as RemoteAnalysisFailure {
                throw failure
            } catch let error as AnalysisWorkerError {
                if case .versionMismatch = error { throw error }
                throw AnalysisWorkerError.malformedReply(reason: String(describing: error))
            } catch {
                throw AnalysisWorkerError.malformedReply(reason: String(describing: error))
            }
        } catch is AnalysisCancelled {
            finishRequest(requestID: requestID, state: .idle)
            throw AnalysisCancelled()
        } catch let failure as AnalysisTransportError {
            switch failure {
            case .interrupted(let reason):
                finishRequest(requestID: requestID, state: .interrupted)
                throw AnalysisWorkerError.workerCrashed(reason: reason)
            case .invalidated(let reason):
                recordInvalidation(requestID: requestID, reason: reason)
                throw AnalysisWorkerError.workerUnavailable(reason: reason)
            }
        } catch is CancellationError {
            finishRequest(requestID: requestID, state: .idle)
            throw AnalysisCancelled()
        } catch {
            finishRequest(requestID: requestID, state: .idle)
            throw error
        }
    }

    private func awaitPinnedReply(
        requestID: UUID,
        payload: Data,
        source: FileHandle,
        cancellation: AnalysisCancellationToken
    ) async throws -> Data {
        let completion = OneShotCompletion<Data>()
        let relay = RequestCancellationRelay(requestID: requestID, transport: transport, completion: completion)
        Task { [transport] in
            do {
                completion.resolve(.success(try await transport.sendPinned(
                    requestID: requestID,
                    payload: payload,
                    source: source
                )))
            }
            catch { completion.resolve(.failure(error)) }
        }
        let monitor = Task {
            while !Task.isCancelled {
                if cancellation.isCancelled { relay.cancel(); return }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let progress = progressRelay(requestID: requestID, cancellation: cancellation)
        return try await withTaskCancellationHandler {
            defer { monitor.cancel(); progress.cancel() }
            return try await completion.value()
        } onCancel: { relay.cancel() }
    }

    func openBinary(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try await performAnalysis(
            url: url,
            selection: selection,
            overrides: overrides,
            cancellation: cancellation
        )
    }

    private func performAnalysis(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        if Task.isCancelled || cancellation.isCancelled {
            throw AnalysisCancelled()
        }

        let requestID = UUID()
        try beginRequest(requestID: requestID)
        let payload = codec.encodeRequest(
            url: url,
            selection: selection,
            overrides: overrides,
            requestID: requestID,
            resourceBudget: resourceBudget,
            analysisBudget: Self.wireBudget(cancellation)
        )

        do {
            let reply = try await awaitReply(
                requestID: requestID,
                payload: payload,
                cancellation: cancellation
            )
            finishRequest(requestID: requestID, state: .idle)

            do {
                return try codec.decodeReply(reply)
            } catch is AnalysisCancelled {
                // A worker cancelled-reply is benign, not a malformed one.
                throw AnalysisCancelled()
            } catch let failure as RemoteAnalysisFailure {
                // The analysis RAN and failed (e.g. unreadable file) — surface its message, not
                // a "malformed reply". The store shows this exactly like an in-process throw.
                throw failure
            } catch let error as AnalysisWorkerError {
                if case .versionMismatch = error {
                    throw error
                }
                throw AnalysisWorkerError.malformedReply(reason: String(describing: error))
            } catch {
                throw AnalysisWorkerError.malformedReply(reason: String(describing: error))
            }
        } catch is AnalysisCancelled {
            finishRequest(requestID: requestID, state: .idle)
            throw AnalysisCancelled()
        } catch let failure as AnalysisTransportError {
            switch failure {
            case .interrupted(let reason):
                finishRequest(requestID: requestID, state: .interrupted)
                throw AnalysisWorkerError.workerCrashed(reason: reason)
            case .invalidated(let reason):
                recordInvalidation(requestID: requestID, reason: reason)
                throw AnalysisWorkerError.workerUnavailable(reason: reason)
            }
        } catch let error as AnalysisWorkerError {
            throw error
        } catch is CancellationError {
            finishRequest(requestID: requestID, state: .idle)
            throw AnalysisCancelled()
        } catch {
            let reason = String(describing: error)
            recordInvalidation(requestID: requestID, reason: reason)
            throw AnalysisWorkerError.workerUnavailable(reason: reason)
        }
    }

    private func awaitReply(
        requestID: UUID,
        payload: Data,
        cancellation: AnalysisCancellationToken
    ) async throws -> Data {
        let completion = OneShotCompletion<Data>()
        let cancellationRelay = RequestCancellationRelay(
            requestID: requestID,
            transport: transport,
            completion: completion
        )

        Task { [transport] in
            do {
                completion.resolve(.success(try await transport.send(requestID: requestID, payload: payload)))
            } catch {
                completion.resolve(.failure(error))
            }
        }

        let tokenMonitor = Task {
            while !Task.isCancelled {
                if cancellation.isCancelled {
                    cancellationRelay.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let progress = progressRelay(requestID: requestID, cancellation: cancellation)
        return try await withTaskCancellationHandler {
            defer { tokenMonitor.cancel(); progress.cancel() }
            return try await completion.value()
        } onCancel: {
            cancellationRelay.cancel()
        }
    }

    /// HOP-3: the token's budget for the request, nil when unlimited (the wire's absent form).
    private static func wireBudget(_ cancellation: AnalysisCancellationToken) -> AnalysisBudget? {
        cancellation.budget == .unlimited ? nil : cancellation.budget
    }

    /// HOP-3: polls the worker for the request's phase about every 250 ms and passes each new one
    /// to the token, so the caller's progress handler sees the out-of-process analysis advance.
    /// An unanswered poll (an older worker, a busy connection) just reports nothing; the final
    /// reply stays authoritative.
    private func progressRelay(requestID: UUID, cancellation: AnalysisCancellationToken) -> Task<Void, Never> {
        Task { [transport] in
            var last: AnalysisProgress?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                // A poll can answer up to a second late; never report after the request finished.
                if let progress = await transport.progress(requestID: requestID), !Task.isCancelled, progress != last {
                    last = progress
                    cancellation.report(progress)
                }
            }
        }
    }

    /// MS-18 rehydrate admission: refuses only a sticky invalidation (rehydrate is not single-flight).
    func rehydrateAdmission() throws {
        try withStateLock {
            if state == .invalidated {
                throw AnalysisWorkerError.workerUnavailable(reason: invalidationReason ?? "connection invalidated")
            }
        }
    }

    func recordRehydrateInvalidation(reason: String) {
        withStateLock {
            invalidationReason = reason
            state = .invalidated
        }
    }

    private func beginRequest(requestID: UUID) throws {
        try withStateLock {
            switch state {
            case .invalidated:
                throw AnalysisWorkerError.workerUnavailable(
                    reason: invalidationReason ?? "connection invalidated"
                )
            case .analyzing, .connecting:
                throw AnalysisWorkerError.workerUnavailable(reason: "another analysis is already in flight")
            case .idle, .interrupted:
                state = .connecting
                state = .analyzing(requestID)
            }
        }
    }

    private func finishRequest(requestID: UUID, state newState: ConnectionState) {
        withStateLock {
            guard state == .analyzing(requestID) else { return }
            state = newState
        }
    }

    private func recordInvalidation(requestID: UUID, reason: String) {
        withStateLock {
            guard state == .analyzing(requestID) else { return }
            invalidationReason = reason
            state = .invalidated
        }
    }

    @discardableResult
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}

/// Sends cancel at most once even when task cancellation and the cooperative token race.
private final class RequestCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let requestID: UUID
    private let transport: any AnalysisTransport
    private let completion: OneShotCompletion<Data>
    private var didCancel = false

    init(
        requestID: UUID,
        transport: any AnalysisTransport,
        completion: OneShotCompletion<Data>
    ) {
        self.requestID = requestID
        self.transport = transport
        self.completion = completion
    }

    func cancel() {
        let shouldCancel: Bool = withLock {
            guard !didCancel else { return false }
            didCancel = true
            return true
        }
        guard shouldCancel else { return }
        transport.cancel(requestID: requestID)
        completion.resolve(.failure(AnalysisCancelled()))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A continuation that accepts exactly one terminal event and tolerates that event arriving just
/// before or just after the awaiting continuation is installed.
private final class OneShotCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Value, Error>? = withLock {
                if let pendingResult {
                    self.pendingResult = nil
                    return pendingResult
                }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = withLock {
            guard !isResolved else { return nil }
            isResolved = true
            if let continuation = self.continuation {
                self.continuation = nil
                return continuation
            }
            pendingResult = result
            return nil
        }
        continuation?.resume(with: result)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class BlockingResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        precondition(result != nil, "semaphore signalled without a result")
        return result!
    }
}

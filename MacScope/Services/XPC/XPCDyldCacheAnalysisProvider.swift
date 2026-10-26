import Foundation

final class XPCDyldCacheAnalysisProvider: DyldCacheAnalysisProviding, @unchecked Sendable {
    enum ConnectionState: Equatable, Sendable {
        case idle
        case inspecting(requestID: UUID, generation: UInt64)
        case interrupted
        case invalidated
    }

    private let transport: any DyldCacheAnalysisTransport
    private let codec: any DyldCacheAnalysisClientWireCodec
    private let makeRequestID: @Sendable () -> UUID
    private let stateLock = NSLock()
    private var state: ConnectionState = .idle
    private var invalidationReason: String?

    init(
        transport: any DyldCacheAnalysisTransport,
        codec: any DyldCacheAnalysisClientWireCodec,
        makeRequestID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.transport = transport
        self.codec = codec
        self.makeRequestID = makeRequestID
    }

    var connectionState: ConnectionState { withStateLock { state } }

    func resetConnection() {
        withStateLock {
            state = .idle
            invalidationReason = nil
        }
    }

    func inspectCache(
        at url: URL,
        expectedSourceIdentity: DyldCacheFileIdentity,
        subject: DyldCacheAnalysisSubjectIdentity,
        categories: [DyldCacheAnalysisCategory],
        limits: DyldCacheAnalysisLimits = .default,
        cancellation: AnalysisCancellationToken = .never
    ) async throws -> DyldCacheAnalysisResult {
        if Task.isCancelled || cancellation.isCancelled { throw AnalysisCancelled() }

        let request = try DyldCacheAnalysisRequest(
            url: url,
            expectedSourceIdentity: expectedSourceIdentity,
            subject: subject,
            categories: categories,
            limits: limits,
            requestID: makeRequestID()
        ).validated()
        try beginRequest(request)
        defer { finishRequest(request, as: .idle) }

        do {
            let payload = try codec.encodeRequest(request)
            let data = try await awaitReply(
                request: request,
                payload: payload,
                cancellation: cancellation
            )
            let decoded = try codec.decodeReply(data)
            // Classify a peer/provider-identity violation at the XPC boundary before the
            // request validator collapses it into generic provider-rejected input. Source,
            // subject, and generation drift remain typed by `request.validate(result:)`.
            guard decoded.provider == .machOKit0522 else {
                throw AnalysisWorkerError.malformedReply(
                    reason: "dyld cache provider identity mismatch"
                )
            }
            return try request.validate(result: decoded)
        } catch is AnalysisCancelled {
            throw AnalysisCancelled()
        } catch let error as DyldCacheAnalysisProviderError {
            if error == .timeout {
                invalidate(request, reason: "dyld-cache inspection timed out")
            }
            throw error
        } catch let error as AnalysisTransportError {
            switch error {
            case let .interrupted(reason):
                finishRequest(request, as: .interrupted)
                throw AnalysisWorkerError.workerCrashed(reason: reason)
            case let .invalidated(reason):
                invalidate(request, reason: reason)
                throw AnalysisWorkerError.workerUnavailable(reason: reason)
            }
        } catch let error as AnalysisWorkerError {
            throw error
        } catch let error as RemoteDyldCacheAnalysisFailure {
            throw error
        } catch is CancellationError {
            throw AnalysisCancelled()
        } catch {
            // Do not expose decoder internals, source paths, or vendor diagnostics to callers.
            throw AnalysisWorkerError.malformedReply(reason: "invalid dyld cache reply")
        }
    }

    private func awaitReply(
        request: DyldCacheAnalysisRequest,
        payload: Data,
        cancellation: AnalysisCancellationToken
    ) async throws -> Data {
        let completion = DyldCacheOneShotCompletion<Data>()
        let relay = DyldCacheRequestRelay(
            requestID: request.requestID,
            transport: transport,
            completion: completion
        )
        let duration = UInt64(request.limits.maximumDurationMilliseconds)
        let (durationNanoseconds, durationOverflow) = duration.multipliedReportingOverflow(
            by: 1_000_000
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, deadlineOverflow) = now.addingReportingOverflow(durationNanoseconds)
        guard !durationOverflow, !deadlineOverflow else {
            throw DyldCacheAnalysisProviderError.timeout
        }

        Task { [transport] in
            do {
                let data = try await transport.sendDyldCacheInspection(
                    requestID: request.requestID,
                    payload: payload
                )
                relay.resolve(.success(data))
            } catch {
                relay.resolve(.failure(error))
            }
        }

        let monitor = Task {
            while !Task.isCancelled {
                if cancellation.isCancelled {
                    relay.terminate(with: AnalysisCancelled())
                    return
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    relay.timeout()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        return try await withTaskCancellationHandler {
            defer { monitor.cancel() }
            return try await completion.value()
        } onCancel: {
            relay.terminate(with: AnalysisCancelled())
        }
    }

    private func beginRequest(_ request: DyldCacheAnalysisRequest) throws {
        try withStateLock {
            switch state {
            case .invalidated:
                throw AnalysisWorkerError.workerUnavailable(
                    reason: invalidationReason ?? "connection invalidated"
                )
            case .inspecting:
                throw AnalysisWorkerError.workerUnavailable(
                    reason: "another dyld cache inspection is already in flight"
                )
            case .idle, .interrupted:
                state = .inspecting(
                    requestID: request.requestID,
                    generation: request.subject.analysisGeneration
                )
            }
        }
    }

    private func finishRequest(
        _ request: DyldCacheAnalysisRequest,
        as newState: ConnectionState
    ) {
        withStateLock {
            guard state == .inspecting(
                requestID: request.requestID,
                generation: request.subject.analysisGeneration
            ) else { return }
            state = newState
        }
    }

    private func invalidate(_ request: DyldCacheAnalysisRequest, reason: String) {
        withStateLock {
            guard state == .inspecting(
                requestID: request.requestID,
                generation: request.subject.analysisGeneration
            ) else { return }
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

/// Serializes transport completion, task/token cancellation, and deadline expiry. Only the first
/// terminal event may resolve the request or send a cancellation to the worker.
private final class DyldCacheRequestRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let requestID: UUID
    private let transport: any DyldCacheAnalysisTransport
    private let completion: DyldCacheOneShotCompletion<Data>
    private var finished = false

    init(
        requestID: UUID,
        transport: any DyldCacheAnalysisTransport,
        completion: DyldCacheOneShotCompletion<Data>
    ) {
        self.requestID = requestID
        self.transport = transport
        self.completion = completion
    }

    func resolve(_ result: Result<Data, Error>) {
        let shouldResolve: Bool = withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldResolve else { return }
        completion.resolve(result)
    }

    func terminate(with error: Error) {
        let shouldTerminate: Bool = withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldTerminate else { return }
        transport.cancelDyldCacheInspection(requestID: requestID)
        completion.resolve(.failure(error))
    }

    func timeout() {
        let shouldTerminate: Bool = withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldTerminate else { return }
        transport.retireDyldCacheConnection(requestID: requestID)
        completion.resolve(.failure(DyldCacheAnalysisProviderError.timeout))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class DyldCacheOneShotCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var resolved = false

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Value, Error>? = withLock {
                if let pending {
                    self.pending = nil
                    return pending
                }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = withLock {
            guard !resolved else { return nil }
            resolved = true
            if let continuation = self.continuation {
                self.continuation = nil
                return continuation
            }
            pending = result
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

import Foundation

enum NativeDecompilerXPCClientFailure: String, CaseIterable, Error, Equatable, Sendable,
    LocalizedError
{
    case requestTooLarge
    case requestEncodingFailed
    case responseTooLarge
    case malformedReply
    case replyRequestMismatch
    case duplicateRequestIdentifier
    case cancelled
    case timedOut
    case interrupted
    case invalidated
    case connectionFailure
    case connectionUnavailable

    var errorDescription: String? {
        switch self {
        case .requestTooLarge:
            "Native decompiler request exceeds the transport limit."
        case .requestEncodingFailed:
            "Native decompiler request could not be encoded."
        case .responseTooLarge:
            "Native decompiler response exceeds the transport limit."
        case .malformedReply:
            "Native decompiler reply is malformed."
        case .replyRequestMismatch:
            "Native decompiler reply identity does not match."
        case .duplicateRequestIdentifier:
            "Native decompiler request identity is already active."
        case .cancelled:
            "Native decompiler request was cancelled."
        case .timedOut:
            "Native decompiler request timed out."
        case .interrupted:
            "Native decompiler connection was interrupted."
        case .invalidated:
            "Native decompiler connection was invalidated."
        case .connectionFailure:
            "Native decompiler connection failed."
        case .connectionUnavailable:
            "Native decompiler connection is unavailable."
        }
    }
}

struct NativeDecompilerXPCClientConfiguration: Equatable, Sendable {
    static let requestCeiling = 32 * 1_024 * 1_024
    static let responseCeiling = 64 * 1_024 * 1_024

    let maximumRequestBytes: Int
    let maximumResponseBytes: Int
    let defaultWatchdog: Duration
    let cooperativeGrace: Duration

    init(
        maximumRequestBytes: Int = Self.requestCeiling,
        maximumResponseBytes: Int = Self.responseCeiling,
        defaultWatchdog: Duration = .seconds(15),
        cooperativeGrace: Duration = .milliseconds(500)
    ) {
        precondition(maximumRequestBytes >= 0)
        precondition(maximumResponseBytes >= 0)
        precondition(defaultWatchdog >= .zero)
        precondition(cooperativeGrace >= .zero)
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.defaultWatchdog = defaultWatchdog
        self.cooperativeGrace = cooperativeGrace
    }
}

struct NativeDecompilerXPCClientSnapshot: Equatable, Sendable {
    let connectionGeneration: UInt64
    let hasConnection: Bool
    let pendingRequestCount: Int
}

final class NativeDecompilerXPCClient: @unchecked Sendable {
    typealias ConnectionFactory = @Sendable () throws -> any NativeDecompilerXPCConnecting
    typealias ConnectionLifecycleHandler = @Sendable (
        _ event: NativeDecompilerXPCConnectionEvent,
        _ generation: UInt64
    ) async -> Void
    private struct ConnectionRecord {
        let generation: UInt64
        let connection: any NativeDecompilerXPCConnecting
    }

    private struct PendingRequest {
        let generation: UInt64
        let connection: any NativeDecompilerXPCConnecting
        let continuation: CheckedContinuation<NativeDecompilerWireReplyEnvelope, Error>
        let watchdogDelay: Duration
        let expectedBinding: NativeDecompilerWireExpectedRequestBinding
        var dispatched = false
        var cancellationReason: NativeDecompilerXPCClientFailure?
        var cancelSent = false
        var watchdog: (any NativeDecompilerXPCClientScheduledAction)?
        var grace: (any NativeDecompilerXPCClientScheduledAction)?
    }

    private enum DispatchPlan {
        case watchdog(Duration)
        case cancellation(NativeDecompilerXPCClientFailure)
    }

    private struct Completion {
        let continuation: CheckedContinuation<NativeDecompilerWireReplyEnvelope, Error>
        let result: Result<NativeDecompilerWireReplyEnvelope, Error>
        let watchdog: (any NativeDecompilerXPCClientScheduledAction)?
        let grace: (any NativeDecompilerXPCClientScheduledAction)?
    }

    private let lock = NSLock()
    private let wireCodec = NativeDecompilerWireCodec()
    private let configuration: NativeDecompilerXPCClientConfiguration
    private let connectionFactory: ConnectionFactory
    private let timerScheduler: any NativeDecompilerXPCClientTimerScheduling
    /// A synchronization-only observer for focused race tests. It receives no payload, binding,
    /// decoder, or result and therefore cannot weaken or replace canonical wire validation.
    private let replyDecodeWillBegin: @Sendable () -> Void
    private var nextGeneration: UInt64 = 0
    private var connectionRecord: ConnectionRecord?
    private var pending: [UUID: PendingRequest] = [:]
    private var lifecycleCompletions: [UInt64: [Completion]] = [:]
    private var connectionLifecycleHandler: ConnectionLifecycleHandler?
    private var isShutDown = false
    private var shutdownTask: Task<Void, Never>?

    init(
        configuration: NativeDecompilerXPCClientConfiguration = .init(),
        connectionFactory: @escaping ConnectionFactory = {
            NativeDecompilerFoundationXPCConnection()
        },
        timerScheduler: any NativeDecompilerXPCClientTimerScheduling =
            NativeDecompilerXPCClientMonotonicTimer(),
        replyDecodeWillBegin: @escaping @Sendable () -> Void = {}
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
        self.timerScheduler = timerScheduler
        self.replyDecodeWillBegin = replyDecodeWillBegin
    }

    var snapshot: NativeDecompilerXPCClientSnapshot {
        lock.withLock {
            NativeDecompilerXPCClientSnapshot(
                connectionGeneration: nextGeneration,
                hasConnection: connectionRecord != nil,
                pendingRequestCount: pending.count
            )
        }
    }

    /// Installs the app-process lifecycle fence. The callback fires only when an event retires the
    /// current connection generation; stale events from an already replaced connection are ignored.
    func setConnectionLifecycleHandler(_ handler: ConnectionLifecycleHandler?) {
        lock.withLock { connectionLifecycleHandler = handler }
    }

    func shutdown() async {
        let task: Task<Void, Never> = lock.withLock {
            if let shutdownTask { return shutdownTask }
            isShutDown = true
            connectionLifecycleHandler = nil
            let connection = connectionRecord?.connection
            let dispatched = pending.compactMap { requestID, request in
                request.dispatched ? (requestID, request.connection) : nil
            }
            for requestID in pending.keys {
                guard var request = pending[requestID] else { continue }
                request.cancellationReason = .invalidated
                request.cancelSent = request.dispatched
                pending[requestID] = request
            }
            let grace = configuration.cooperativeGrace
            let task = Task { [weak self] in
                for (requestID, requestConnection) in dispatched {
                    requestConnection.cancel(requestID: requestID)
                }
                if !dispatched.isEmpty, grace > .zero {
                    try? await Task.sleep(for: grace)
                }
                self?.finishTerminalShutdown(connection: connection)
            }
            shutdownTask = task
            return task
        }
        await task.value
    }

    func decompile(
        request: NativeDecompilerPreencodedDispatchRequest,
        elapsedTimeBudget: Duration? = nil
    ) async throws -> NativeDecompilerWireReplyEnvelope {
        let requestID = request.requestID
        let expectedBinding = request.expectedBinding
        let payload = request.payload

        guard payload.count <= configuration.maximumRequestBytes else {
            throw NativeDecompilerXPCClientFailure.requestTooLarge
        }

        let cancellationRelay = NativeDecompilerXPCClientCancellationRelay()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !cancellationRelay.isCancelled else {
                    continuation.resume(throwing: NativeDecompilerXPCClientFailure.cancelled)
                    return
                }

                guard let ticket = register(
                    requestID: requestID,
                    payload: payload,
                    elapsedTimeBudget: elapsedTimeBudget,
                    expectedBinding: expectedBinding,
                    continuation: continuation
                ) else {
                    return
                }

                cancellationRelay.install { [weak self] in
                    self?.beginCancellation(
                        requestID: requestID,
                        generation: ticket.generation,
                        reason: .cancelled
                    )
                }
                dispatch(ticket)
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }

    private struct DispatchTicket: Sendable {
        let requestID: UUID
        let generation: UInt64
        let connection: any NativeDecompilerXPCConnecting
        let payload: Data
    }

    private func register(
        requestID: UUID,
        payload: Data,
        elapsedTimeBudget: Duration?,
        expectedBinding: NativeDecompilerWireExpectedRequestBinding,
        continuation: CheckedContinuation<NativeDecompilerWireReplyEnvelope, Error>
    ) -> DispatchTicket? {
        var failure: NativeDecompilerXPCClientFailure?
        var ticket: DispatchTicket?

        lock.lock()
        if isShutDown {
            failure = .invalidated
        } else if pending[requestID] != nil {
            failure = .duplicateRequestIdentifier
        } else {
            do {
                let record = try activeConnectionLocked()
                let watchdogDelay = clampedWatchdog(elapsedTimeBudget)
                pending[requestID] = PendingRequest(
                    generation: record.generation,
                    connection: record.connection,
                    continuation: continuation,
                    watchdogDelay: watchdogDelay,
                    expectedBinding: expectedBinding
                )
                ticket = DispatchTicket(
                    requestID: requestID,
                    generation: record.generation,
                    connection: record.connection,
                    payload: payload
                )
            } catch {
                failure = .connectionUnavailable
            }
        }
        lock.unlock()

        if let failure {
            continuation.resume(throwing: failure)
        }
        return ticket
    }

    private func activeConnectionLocked() throws -> ConnectionRecord {
        guard !isShutDown else { throw NativeDecompilerXPCClientFailure.invalidated }
        if let connectionRecord { return connectionRecord }

        guard nextGeneration < .max else {
            isShutDown = true
            throw NativeDecompilerXPCClientFailure.connectionUnavailable
        }
        nextGeneration += 1
        let generation = nextGeneration
        let connection = try connectionFactory()
        connection.setEventHandler { [weak self] event in
            self?.handleConnectionEvent(event, generation: generation)
        }
        let record = ConnectionRecord(generation: generation, connection: connection)
        connectionRecord = record
        return record
    }

    private func dispatch(_ ticket: DispatchTicket) {
        ticket.connection.resume()
        guard isPending(ticket) else { return }
        ticket.connection.decompile(
            requestID: ticket.requestID,
            payload: ticket.payload
        ) { [weak self] reply in
            self?.handleReply(
                reply,
                requestID: ticket.requestID,
                generation: ticket.generation
            )
        }

        let plan: DispatchPlan? = lock.withLock {
            guard var request = pending[ticket.requestID],
                  request.generation == ticket.generation else {
                return nil
            }
            request.dispatched = true
            let plan: DispatchPlan
            if let reason = request.cancellationReason {
                guard !request.cancelSent else {
                    pending[ticket.requestID] = request
                    return nil
                }
                request.cancelSent = true
                plan = .cancellation(reason)
            } else {
                plan = .watchdog(request.watchdogDelay)
            }
            pending[ticket.requestID] = request
            return plan
        }
        execute(plan, ticket: ticket)
    }

    private func isPending(_ ticket: DispatchTicket) -> Bool {
        lock.withLock {
            pending[ticket.requestID]?.generation == ticket.generation
        }
    }

    private func execute(_ plan: DispatchPlan?, ticket: DispatchTicket) {
        guard let plan else { return }
        switch plan {
        case .watchdog(let delay):
            let action = timerScheduler.schedule(after: delay) { [weak self] in
                self?.beginCancellation(
                    requestID: ticket.requestID,
                    generation: ticket.generation,
                    reason: .timedOut
                )
            }
            install(
                action,
                kind: .watchdog,
                requestID: ticket.requestID,
                generation: ticket.generation
            )
        case .cancellation:
            ticket.connection.cancel(requestID: ticket.requestID)
            scheduleGrace(for: ticket)
        }
    }

    private enum ScheduledActionKind {
        case watchdog
        case grace
    }

    private func install(
        _ action: any NativeDecompilerXPCClientScheduledAction,
        kind: ScheduledActionKind,
        requestID: UUID,
        generation: UInt64
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard var request = pending[requestID], request.generation == generation else {
                return true
            }
            switch kind {
            case .watchdog:
                guard request.cancellationReason == nil else { return true }
                request.watchdog?.cancel()
                request.watchdog = action
            case .grace:
                guard request.cancellationReason != nil else { return true }
                request.grace?.cancel()
                request.grace = action
            }
            pending[requestID] = request
            return false
        }
        if shouldCancel { action.cancel() }
    }

    private func beginCancellation(
        requestID: UUID,
        generation: UInt64,
        reason: NativeDecompilerXPCClientFailure
    ) {
        var ticket: DispatchTicket?
        var watchdog: (any NativeDecompilerXPCClientScheduledAction)?

        lock.lock()
        if var request = pending[requestID], request.generation == generation {
            if request.cancellationReason == nil {
                request.cancellationReason = reason
                watchdog = request.watchdog
                request.watchdog = nil
            }
            if request.dispatched, !request.cancelSent {
                request.cancelSent = true
                ticket = DispatchTicket(
                    requestID: requestID,
                    generation: generation,
                    connection: request.connection,
                    payload: Data()
                )
            }
            pending[requestID] = request
        }
        lock.unlock()

        watchdog?.cancel()
        if let ticket {
            ticket.connection.cancel(requestID: requestID)
            scheduleGrace(for: ticket)
        }
    }

    private func scheduleGrace(for ticket: DispatchTicket) {
        let action = timerScheduler.schedule(after: configuration.cooperativeGrace) { [weak self] in
            self?.graceExpired(
                requestID: ticket.requestID,
                generation: ticket.generation,
                connection: ticket.connection
            )
        }
        install(
            action,
            kind: .grace,
            requestID: ticket.requestID,
            generation: ticket.generation
        )
    }

    private func graceExpired(
        requestID: UUID,
        generation: UInt64,
        connection: any NativeDecompilerXPCConnecting
    ) {
        var completions: [Completion] = []
        var shouldInvalidate = false

        lock.lock()
        if let target = pending[requestID],
           target.generation == generation,
           let reason = target.cancellationReason {
            let requestIDs = pending.compactMap { key, value in
                value.generation == generation ? key : nil
            }
            for pendingID in requestIDs {
                guard let request = pending.removeValue(forKey: pendingID) else { continue }
                let failure: NativeDecompilerXPCClientFailure = pendingID == requestID
                    ? reason
                    : (request.cancellationReason ?? .invalidated)
                completions.append(Completion(
                    continuation: request.continuation,
                    result: .failure(failure),
                    watchdog: request.watchdog,
                    grace: request.grace
                ))
            }
            if connectionRecord?.generation == generation {
                connectionRecord = nil
            }
            shouldInvalidate = true
        }
        lock.unlock()

        finish(completions)
        if shouldInvalidate { connection.invalidate() }
    }

    private func handleReply(_ reply: Data, requestID: UUID, generation: UInt64) {
        let requestState = lock.withLock {
            guard let request = pending[requestID], request.generation == generation else {
                return nil as (
                    cancellationReason: NativeDecompilerXPCClientFailure?,
                    expectedBinding: NativeDecompilerWireExpectedRequestBinding
                )?
            }
            return (request.cancellationReason, request.expectedBinding)
        }
        guard let requestState else { return }
        if let cancellationReason = requestState.cancellationReason {
            complete(requestID: requestID, generation: generation, with: .failure(cancellationReason))
            return
        }

        guard reply.count <= configuration.maximumResponseBytes else {
            complete(requestID: requestID, generation: generation, with: .failure(.responseTooLarge))
            return
        }

        do {
            replyDecodeWillBegin()
            let decoded = try wireCodec.decodeReply(
                reply,
                matching: requestState.expectedBinding
            )
            complete(requestID: requestID, generation: generation, with: .success(decoded))
        } catch NativeDecompilerWireCodecError.responseTooLarge {
            complete(requestID: requestID, generation: generation, with: .failure(.responseTooLarge))
        } catch NativeDecompilerWireCodecError.requestIDMismatch,
                NativeDecompilerWireCodecError.requestBindingMismatch {
            complete(
                requestID: requestID,
                generation: generation,
                with: .failure(.replyRequestMismatch)
            )
        } catch {
            complete(requestID: requestID, generation: generation, with: .failure(.malformedReply))
        }
    }

    private func complete(
        requestID: UUID,
        generation: UInt64,
        with result: Result<NativeDecompilerWireReplyEnvelope, NativeDecompilerXPCClientFailure>
    ) {
        let completion: Completion? = lock.withLock {
            guard let request = pending[requestID], request.generation == generation else {
                return nil
            }
            pending.removeValue(forKey: requestID)
            let terminalResult: Result<NativeDecompilerWireReplyEnvelope, NativeDecompilerXPCClientFailure>
            if let cancellationReason = request.cancellationReason {
                terminalResult = .failure(cancellationReason)
            } else {
                terminalResult = result
            }
            return Completion(
                continuation: request.continuation,
                result: terminalResult.mapError { $0 as Error },
                watchdog: request.watchdog,
                grace: request.grace
            )
        }
        if let completion { finish([completion]) }
    }

    private func handleConnectionEvent(
        _ event: NativeDecompilerXPCConnectionEvent,
        generation: UInt64
    ) {
        let failure: NativeDecompilerXPCClientFailure
        switch event {
        case .interrupted: failure = .interrupted
        case .invalidated: failure = .invalidated
        case .connectionFailure: failure = .connectionFailure
        }

        var completions: [Completion] = []
        var connectionToInvalidate: (any NativeDecompilerXPCConnecting)?
        var lifecycleHandler: ConnectionLifecycleHandler?
        lock.lock()
        if let record = connectionRecord, record.generation == generation {
            connectionRecord = nil
            lifecycleHandler = connectionLifecycleHandler
            if event != .invalidated { connectionToInvalidate = record.connection }
            let requestIDs = pending.compactMap { key, value in
                value.generation == generation ? key : nil
            }
            for requestID in requestIDs {
                guard let request = pending.removeValue(forKey: requestID) else { continue }
                completions.append(Completion(
                    continuation: request.continuation,
                    result: .failure(request.cancellationReason ?? failure),
                    watchdog: request.watchdog,
                    grace: request.grace
                ))
            }
            if lifecycleHandler != nil {
                lifecycleCompletions[generation] = completions
                completions.removeAll(keepingCapacity: false)
            }
        }
        lock.unlock()

        let retiredConnection = connectionToInvalidate
        let settle = { [self] in
            finish(takeLifecycleCompletions(generation: generation))
            retiredConnection?.invalidate()
        }
        if let lifecycleHandler {
            Task {
                await lifecycleHandler(event, generation)
                settle()
            }
        } else {
            finish(completions)
            settle()
        }
    }

    private func takeLifecycleCompletions(generation: UInt64) -> [Completion] {
        lock.withLock { lifecycleCompletions.removeValue(forKey: generation) ?? [] }
    }

    private func finishTerminalShutdown(
        connection: (any NativeDecompilerXPCConnecting)?
    ) {
        var completions: [Completion] = []
        lock.lock()
        connectionRecord = nil
        for request in pending.values {
            completions.append(Completion(
                continuation: request.continuation,
                result: .failure(NativeDecompilerXPCClientFailure.invalidated),
                watchdog: request.watchdog,
                grace: request.grace
            ))
        }
        pending.removeAll(keepingCapacity: false)
        for batch in lifecycleCompletions.values { completions.append(contentsOf: batch) }
        lifecycleCompletions.removeAll(keepingCapacity: false)
        lock.unlock()
        connection?.invalidate()
        finish(completions)
    }

    private func finish(_ completions: [Completion]) {
        for completion in completions {
            completion.watchdog?.cancel()
            completion.grace?.cancel()
            completion.continuation.resume(with: completion.result)
        }
    }

    private func clampedWatchdog(_ elapsedTimeBudget: Duration?) -> Duration {
        guard let elapsedTimeBudget else { return configuration.defaultWatchdog }
        return min(configuration.defaultWatchdog, max(.zero, elapsedTimeBudget))
    }
}

private final class NativeDecompilerXPCClientCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancellationRequested = false
    private var action: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { isCancellationRequested } }

    func install(_ action: @escaping @Sendable () -> Void) {
        let invokeNow = lock.withLock { () -> Bool in
            if isCancellationRequested { return true }
            self.action = action
            return false
        }
        if invokeNow { action() }
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !isCancellationRequested else { return nil }
            isCancellationRequested = true
            return self.action
        }
        action?()
    }
}

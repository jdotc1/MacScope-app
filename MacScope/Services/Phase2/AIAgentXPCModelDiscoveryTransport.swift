import Foundation

protocol Phase2AIWorkerModelDiscoveryTransport: Sendable {
    func discover(requestData: Data, requestID: UUID) async throws -> Data
    func cancel(requestID: UUID) async
    func reset() async
}

final class NSXPCAIWorkerModelDiscoveryTransport: Phase2AIWorkerModelDiscoveryTransport,
    @unchecked Sendable
{
    private static let serviceName = "org.macscope.app.AIAgentWorker"

    private let lock = NSLock()
    private let handshakeTimeoutNanoseconds: UInt64
    private let waitForHandshakeDeadline: @Sendable (UInt64) async throws -> Void
    private var connection: NSXPCConnection?
    private var proxy: Phase2AIWorkerXPCProtocol?
    private var pending: [UUID: Phase2ModelDiscoveryOneShot] = [:]
    private var handshake: Phase2ModelDiscoveryOneShot?
    private var handshakeDeadlineTask: Task<Void, Never>?
    private var connectionEpoch = UUID()
    private var preparingConnection = false
    private var activeRequestID: UUID?
    private var activeOperationToken: UUID?
    private var cancelledOperationTokens: Set<UUID> = []
    private let pauseBeforePendingRegistration: (@Sendable () async -> Void)?

    init(
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000,
        waitForHandshakeDeadline: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        pauseBeforePendingRegistration: (@Sendable () async -> Void)? = nil
    ) {
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.waitForHandshakeDeadline = waitForHandshakeDeadline
        self.pauseBeforePendingRegistration = pauseBeforePendingRegistration
    }

    func discover(requestData: Data, requestID: UUID) async throws -> Data {
        let operationToken = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard activeRequestID == nil else { return false }
            activeRequestID = requestID
            activeOperationToken = operationToken
            return true
        }
        guard accepted else {
            throw AIAgentXPCTransportError.unavailable("model discovery transport busy")
        }

        do {
            let data = try await withTaskCancellationHandler {
                let (proxy, epoch) = try await preparedProxy()
                try Task.checkCancellation()
                if let pauseBeforePendingRegistration {
                    await pauseBeforePendingRegistration()
                }
                return try await withCheckedThrowingContinuation { continuation in
                    let once = Phase2ModelDiscoveryOneShot(continuation)
                    var cancelled = false
                    let registered = lock.withLock { () -> Bool in
                        if cancelledOperationTokens.contains(operationToken) {
                            cancelled = true
                            return false
                        }
                        guard connection != nil,
                              connectionEpoch == epoch,
                              activeRequestID == requestID,
                              activeOperationToken == operationToken,
                              pending[requestID] == nil
                        else { return false }
                        pending[requestID] = once
                        return true
                    }
                    guard registered else {
                        once.resume(.failure(cancelled
                            ? CancellationError()
                            : AIAgentXPCTransportError.unavailable(
                                "model discovery transport unavailable"
                            )))
                        return
                    }
                    proxy.discoverModels(requestData: requestData, requestID: requestID) {
                        [weak self] data in
                        guard let self else {
                            once.resume(.failure(AIAgentXPCTransportError.invalidated(
                                "model discovery transport released"
                            )))
                            return
                        }
                        let current = self.lock.withLock {
                            () -> Phase2ModelDiscoveryOneShot? in
                            guard self.connectionEpoch == epoch,
                                  self.pending[requestID] === once
                            else { return nil }
                            return self.pending.removeValue(forKey: requestID)
                        }
                        current?.resume(.success(data))
                    }
                }
            } onCancel: { [weak self] in
                self?.cancelSynchronously(requestID: requestID)
            }
            clearActiveRequest(requestID, operationToken: operationToken)
            return data
        } catch {
            clearActiveRequest(requestID, operationToken: operationToken)
            throw error
        }
    }

    func cancel(requestID: UUID) async {
        cancelSynchronously(requestID: requestID)
    }

    func reset() async {
        invalidate(reason: "model discovery connection reset")
    }

    private func preparedProxy() async throws -> (Phase2AIWorkerXPCProtocol, UUID) {
        let preparation = lock.withLock { () -> (Phase2AIWorkerXPCProtocol?, UUID)? in
            if let existing = proxy, connection != nil, !preparingConnection, handshake == nil {
                return (existing, connectionEpoch)
            }
            guard connection == nil, !preparingConnection else { return nil }
            preparingConnection = true
            return (nil, connectionEpoch)
        }
        guard let preparation else {
            throw AIAgentXPCTransportError.unavailable(
                "model discovery connection preparation already in progress"
            )
        }
        if let existing = preparation.0 { return (existing, preparation.1) }
        let epoch = preparation.1

        let connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: Phase2AIWorkerXPCProtocol.self)
        connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)
        connection.interruptionHandler = { [weak self] in
            self?.invalidate(epoch: epoch, reason: "AI worker interrupted during model discovery")
        }
        connection.invalidationHandler = { [weak self] in
            self?.invalidate(epoch: epoch, reason: "AI worker invalidated during model discovery")
        }
        connection.resume()

        guard let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.invalidate(epoch: epoch, reason: "AI worker proxy failed during model discovery")
        }) as? Phase2AIWorkerXPCProtocol else {
            connection.invalidate()
            lock.withLock {
                if connectionEpoch == epoch { preparingConnection = false }
            }
            throw AIAgentXPCTransportError.unavailable("AI worker proxy unavailable")
        }

        let installed = lock.withLock { () -> Bool in
            guard self.connection == nil,
                  self.connectionEpoch == epoch,
                  self.preparingConnection
            else { return false }
            self.connection = connection
            proxy = remote
            return true
        }
        guard installed else {
            connection.invalidate()
            throw AIAgentXPCTransportError.unavailable("model discovery connection race")
        }

        do {
            try await performHandshake(proxy: remote, epoch: epoch)
            let ready = lock.withLock { () -> Bool in
                guard connectionEpoch == epoch, self.connection === connection else {
                    return false
                }
                preparingConnection = false
                return true
            }
            guard ready else {
                throw AIAgentXPCTransportError.invalidated(
                    "model discovery connection changed during handshake"
                )
            }
            return (remote, epoch)
        } catch {
            invalidate(epoch: epoch, reason: "AI worker model discovery handshake failed")
            throw error
        }
    }

    private func performHandshake(
        proxy: Phase2AIWorkerXPCProtocol,
        epoch: UUID
    ) async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = Phase2ModelDiscoveryOneShot(continuation)
            let registered = lock.withLock { () -> Bool in
                guard connection != nil,
                      connectionEpoch == epoch,
                      preparingConnection,
                      handshake == nil
                else { return false }
                handshake = once
                return true
            }
            guard registered else {
                once.resume(.failure(AIAgentXPCTransportError.unavailable(
                    "model discovery handshake unavailable"
                )))
                return
            }
            installHandshakeDeadline(once: once, epoch: epoch)
            proxy.handshake { [weak self] data in
                guard let self else {
                    once.resume(.failure(AIAgentXPCTransportError.invalidated(
                        "model discovery transport released"
                    )))
                    return
                }
                let current = self.lock.withLock {
                    () -> (Phase2ModelDiscoveryOneShot?, Task<Void, Never>?) in
                    guard self.connectionEpoch == epoch, self.handshake === once else {
                        return (nil, nil)
                    }
                    self.handshake = nil
                    let deadline = self.handshakeDeadlineTask
                    self.handshakeDeadlineTask = nil
                    return (once, deadline)
                }
                current.1?.cancel()
                current.0?.resume(.success(data))
            }
        }
        try Phase2AIWorkerProductionHandshakeAuthority.validate(data)
    }

    private func installHandshakeDeadline(once: Phase2ModelDiscoveryOneShot, epoch: UUID) {
        let timeout = handshakeTimeoutNanoseconds
        let task = Task { [weak self, waitForHandshakeDeadline] in
            do {
                try await waitForHandshakeDeadline(timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireHandshake(once: once, epoch: epoch)
        }
        let accepted = lock.withLock { () -> Bool in
            guard connectionEpoch == epoch, handshake === once else { return false }
            handshakeDeadlineTask = task
            return true
        }
        if !accepted { task.cancel() }
    }

    private func expireHandshake(once: Phase2ModelDiscoveryOneShot, epoch: UUID) {
        let expired = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard connectionEpoch == epoch, handshake === once else { return (false, nil) }
            handshake = nil
            let deadline = handshakeDeadlineTask
            handshakeDeadlineTask = nil
            return (true, deadline)
        }
        guard expired.0 else { return }
        expired.1?.cancel()
        let reason = "AI worker model discovery handshake timed out"
        // Retire before resuming the caller so an immediate retry receives a fresh connection.
        invalidate(epoch: epoch, reason: reason)
        once.resume(.failure(AIAgentXPCTransportError.unavailable(reason)))
    }

    private func cancelSynchronously(requestID: UUID) {
        let state = lock.withLock { () -> (
            Phase2AIWorkerXPCProtocol?, Phase2ModelDiscoveryOneShot?, UUID?
        ) in
            guard activeRequestID == requestID else { return (nil, nil, nil) }
            if let activeOperationToken { cancelledOperationTokens.insert(activeOperationToken) }
            let once = pending.removeValue(forKey: requestID)
            // Discovery connections are one-shot. Always invalidating closes both cancellation
            // gaps: before continuation registration and after registration but before the
            // outbound selector is enqueued. A stale proxy therefore cannot start useful work.
            return (proxy, once, connectionEpoch)
        }
        state.0?.cancelModelDiscovery(requestID: requestID)
        state.1?.resume(.failure(CancellationError()))
        if let epoch = state.2 {
            invalidate(
                epoch: epoch,
                reason: "model discovery cancelled during connection preparation"
            )
        }
    }

    private func clearActiveRequest(_ requestID: UUID, operationToken: UUID) {
        lock.withLock {
            cancelledOperationTokens.remove(operationToken)
            if activeRequestID == requestID, activeOperationToken == operationToken {
                activeRequestID = nil
                activeOperationToken = nil
            }
        }
    }

    private func invalidate(epoch expectedEpoch: UUID? = nil, reason: String) {
        let state = lock.withLock { () -> (
            NSXPCConnection?, [Phase2ModelDiscoveryOneShot], Phase2ModelDiscoveryOneShot?,
            Task<Void, Never>?
        ) in
            // Queued failures belong to the connection that installed the callback, even if
            // the service has already reset and started a newer discovery request.
            guard expectedEpoch == nil || expectedEpoch == connectionEpoch else {
                return (nil, [], nil, nil)
            }
            let value = (connection, Array(pending.values), handshake, handshakeDeadlineTask)
            connection = nil
            proxy = nil
            pending.removeAll()
            handshake = nil
            handshakeDeadlineTask = nil
            preparingConnection = false
            activeRequestID = nil
            activeOperationToken = nil
            connectionEpoch = UUID()
            return value
        }
        state.3?.cancel()
        state.0?.interruptionHandler = nil
        state.0?.invalidationHandler = nil
        state.0?.invalidate()
        let error = AIAgentXPCTransportError.invalidated(reason)
        for once in state.1 { once.resume(.failure(error)) }
        state.2?.resume(.failure(error))
    }
}

private final class Phase2ModelDiscoveryOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Data, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

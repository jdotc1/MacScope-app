import Foundation

enum Phase2AIWorkerModelLifecycleTransportError: Error, Equatable, Sendable {
    case unavailableBeforeDispatch
    case cancelledBeforeDispatch
    case reconciliationRequired
}

protocol Phase2AIWorkerModelLifecycleTransport: Sendable {
    func perform(requestData: Data, requestID: UUID) async throws -> Data
    func cancel(requestID: UUID) async
    func reset() async
}

protocol Phase2AIWorkerModelLifecycleXPCConnection: AnyObject, Sendable {
    var interruptionHandler: (@Sendable () -> Void)? { get set }
    var invalidationHandler: (@Sendable () -> Void)? { get set }

    func resume()
    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> Phase2AIWorkerXPCProtocol?
    func invalidate()
}

/// Fresh, signed, one-operation lifecycle transport. Cancellation is classified by whether the
/// mutating selector may have been enqueued; connection teardown never rewrites that distinction.
final class NSXPCAIWorkerModelLifecycleTransport: Phase2AIWorkerModelLifecycleTransport,
    @unchecked Sendable
{
    private static let serviceName = "org.macscope.app.AIAgentWorker"

    private struct Pending {
        let once: Phase2ModelLifecycleOneShot
        let operationToken: UUID
        var mayHaveDispatched: Bool
    }

    private struct CancellationState {
        let explicitlyCancelled: Bool
        let mayHaveDispatched: Bool
    }

    private let lock = NSLock()
    private let makeConnection: @Sendable () -> any Phase2AIWorkerModelLifecycleXPCConnection
    private let handshakeTimeoutNanoseconds: UInt64
    private let waitForHandshakeDeadline: @Sendable (UInt64) async throws -> Void
    private var connection: (any Phase2AIWorkerModelLifecycleXPCConnection)?
    private var proxy: Phase2AIWorkerXPCProtocol?
    private var pending: [UUID: Pending] = [:]
    private var handshake: Phase2ModelLifecycleOneShot?
    private var handshakeDeadlineTask: Task<Void, Never>?
    private var connectionEpoch = UUID()
    private var preparingConnection = false
    private var activeRequestID: UUID?
    private var activeOperationToken: UUID?
    private var cancelledTokens: [UUID: CancellationState] = [:]

    init(
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000,
        waitForHandshakeDeadline: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        makeConnection: @escaping @Sendable () -> any Phase2AIWorkerModelLifecycleXPCConnection = {
            Phase2AIWorkerModelLifecycleNSXPCConnection(
                serviceName: NSXPCAIWorkerModelLifecycleTransport.serviceName
            )
        }
    ) {
        self.makeConnection = makeConnection
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.waitForHandshakeDeadline = waitForHandshakeDeadline
    }

    func perform(requestData: Data, requestID: UUID) async throws -> Data {
        let operationToken = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard activeRequestID == nil else { return false }
            activeRequestID = requestID
            activeOperationToken = operationToken
            return true
        }
        guard accepted else {
            throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        }

        do {
            let (data, epoch) = try await withTaskCancellationHandler {
                let (proxy, epoch) = try await preparedProxy()
                try Task.checkCancellation()
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    let once = Phase2ModelLifecycleOneShot(continuation)
                    var cancellation: CancellationState?
                    let registered = lock.withLock { () -> Bool in
                        if let state = cancelledTokens[operationToken] {
                            cancellation = state
                            return false
                        }
                        guard connection != nil,
                              connectionEpoch == epoch,
                              activeRequestID == requestID,
                              activeOperationToken == operationToken,
                              pending[requestID] == nil
                        else { return false }
                        pending[requestID] = .init(
                            once: once,
                            operationToken: operationToken,
                            mayHaveDispatched: false
                        )
                        return true
                    }
                    guard registered else {
                        once.resume(.failure(cancellation?.mayHaveDispatched == true
                            ? Phase2AIWorkerModelLifecycleTransportError.reconciliationRequired
                            : Phase2AIWorkerModelLifecycleTransportError.cancelledBeforeDispatch))
                        return
                    }

                    let dispatchReserved = lock.withLock { () -> Bool in
                        guard var state = pending[requestID],
                              state.once === once,
                              state.operationToken == operationToken,
                              connectionEpoch == epoch
                        else { return false }
                        state.mayHaveDispatched = true
                        pending[requestID] = state
                        return true
                    }
                    guard dispatchReserved else { return }

                    proxy.performModelLifecycle(
                        requestData: requestData,
                        requestID: requestID
                    ) { [weak self] data in
                        guard let self else {
                            once.resume(.failure(
                                Phase2AIWorkerModelLifecycleTransportError.reconciliationRequired
                            ))
                            return
                        }
                        let current = self.lock.withLock { () -> Phase2ModelLifecycleOneShot? in
                            guard self.connectionEpoch == epoch,
                                  self.pending[requestID]?.once === once
                            else { return nil }
                            return self.pending.removeValue(forKey: requestID)?.once
                        }
                        current?.resume(.success(data))
                    }
                }
                return (data, epoch)
            } onCancel: { [weak self] in
                self?.cancelSynchronously(requestID: requestID)
            }
            invalidate(epoch: epoch)
            clearActiveRequest(requestID, operationToken: operationToken)
            return data
        } catch {
            let cancellation = lock.withLock { () -> CancellationState in
                cancelledTokens[operationToken]
                    ?? .init(
                        explicitlyCancelled: false,
                        mayHaveDispatched: pending[requestID]?.mayHaveDispatched ?? false
                    )
            }
            clearActiveRequest(requestID, operationToken: operationToken)
            if cancellation.mayHaveDispatched {
                throw Phase2AIWorkerModelLifecycleTransportError.reconciliationRequired
            }
            if cancellation.explicitlyCancelled || Task.isCancelled {
                throw Phase2AIWorkerModelLifecycleTransportError.cancelledBeforeDispatch
            }
            if let classified = error as? Phase2AIWorkerModelLifecycleTransportError {
                throw classified
            }
            throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        }
    }

    func cancel(requestID: UUID) async {
        cancelSynchronously(requestID: requestID)
    }

    func reset() async {
        invalidate()
    }

    private func preparedProxy() async throws -> (Phase2AIWorkerXPCProtocol, UUID) {
        let preparation = lock.withLock { () -> (Phase2AIWorkerXPCProtocol?, UUID)? in
            if let proxy, connection != nil, !preparingConnection, handshake == nil {
                return (proxy, connectionEpoch)
            }
            guard connection == nil, !preparingConnection else { return nil }
            preparingConnection = true
            return (nil, connectionEpoch)
        }
        guard let preparation else {
            throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        }
        if let existing = preparation.0 { return (existing, preparation.1) }
        let epoch = preparation.1

        let connection = makeConnection()
        connection.interruptionHandler = { [weak self] in self?.invalidate(epoch: epoch) }
        connection.invalidationHandler = { [weak self] in self?.invalidate(epoch: epoch) }
        connection.resume()

        guard let remote = connection.remoteObjectProxy(errorHandler: { [weak self] _ in
            self?.invalidate(epoch: epoch)
        }) else {
            connection.invalidate()
            lock.withLock { if connectionEpoch == epoch { preparingConnection = false } }
            throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        }

        let installed = lock.withLock { () -> Bool in
            guard self.connection == nil,
                  connectionEpoch == epoch,
                  preparingConnection
            else { return false }
            self.connection = connection
            proxy = remote
            return true
        }
        guard installed else {
            connection.invalidate()
            throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        }

        do {
            try await performHandshake(proxy: remote, epoch: epoch)
            let ready = lock.withLock { () -> Bool in
                guard connectionEpoch == epoch, self.connection === connection else { return false }
                preparingConnection = false
                return true
            }
            guard ready else {
                throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
            }
            return (remote, epoch)
        } catch {
            invalidate(epoch: epoch)
            throw error
        }
    }

    private func performHandshake(
        proxy: Phase2AIWorkerXPCProtocol,
        epoch: UUID
    ) async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = Phase2ModelLifecycleOneShot(continuation)
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
                once.resume(.failure(
                    Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
                ))
                return
            }
            installHandshakeDeadline(once: once, epoch: epoch)
            proxy.handshake { [weak self] data in
                guard let self else {
                    once.resume(.failure(
                        Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
                    ))
                    return
                }
                let current = self.lock.withLock {
                    () -> (Phase2ModelLifecycleOneShot?, Task<Void, Never>?) in
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
        do {
            try Phase2AIWorkerProductionHandshakeAuthority.validate(data)
        } catch {
            throw Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        }
    }

    private func installHandshakeDeadline(once: Phase2ModelLifecycleOneShot, epoch: UUID) {
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

    private func expireHandshake(once: Phase2ModelLifecycleOneShot, epoch: UUID) {
        let expired = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard connectionEpoch == epoch, handshake === once else { return (false, nil) }
            handshake = nil
            let deadline = handshakeDeadlineTask
            handshakeDeadlineTask = nil
            return (true, deadline)
        }
        guard expired.0 else { return }
        expired.1?.cancel()
        // Retire before resuming the caller so an immediate retry receives a fresh connection.
        invalidate(epoch: epoch)
        once.resume(.failure(Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch))
    }

    private func cancelSynchronously(requestID: UUID) {
        let state = lock.withLock { () -> (
            Phase2AIWorkerXPCProtocol?, Phase2ModelLifecycleOneShot?, Bool, UUID?
        ) in
            guard activeRequestID == requestID,
                  let operationToken = activeOperationToken
            else { return (nil, nil, false, nil) }
            let pendingState = pending.removeValue(forKey: requestID)
            let mayHaveDispatched = pendingState?.mayHaveDispatched ?? false
            cancelledTokens[operationToken] = .init(
                explicitlyCancelled: true,
                mayHaveDispatched: mayHaveDispatched
            )
            return (proxy, pendingState?.once, mayHaveDispatched, connectionEpoch)
        }
        state.0?.cancelModelLifecycle(requestID: requestID)
        state.1?.resume(.failure(state.2
            ? Phase2AIWorkerModelLifecycleTransportError.reconciliationRequired
            : Phase2AIWorkerModelLifecycleTransportError.cancelledBeforeDispatch))
        if let epoch = state.3 { invalidate(epoch: epoch) }
    }

    private func clearActiveRequest(_ requestID: UUID, operationToken: UUID) {
        lock.withLock {
            cancelledTokens.removeValue(forKey: operationToken)
            if activeRequestID == requestID, activeOperationToken == operationToken {
                activeRequestID = nil
                activeOperationToken = nil
            }
        }
    }

    private func invalidate(epoch expectedEpoch: UUID? = nil) {
        let state = lock.withLock { () -> (
            (any Phase2AIWorkerModelLifecycleXPCConnection)?, [Pending],
            Phase2ModelLifecycleOneShot?, Task<Void, Never>?
        ) in
            // A retired connection can deliver a queued failure after its successor starts.
            // Compare under the same lock that replaces the connection, before touching state.
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
        for pending in state.1 {
            pending.once.resume(.failure(pending.mayHaveDispatched
                ? Phase2AIWorkerModelLifecycleTransportError.reconciliationRequired
                : Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch))
        }
        state.2?.resume(.failure(
            Phase2AIWorkerModelLifecycleTransportError.unavailableBeforeDispatch
        ))
    }
}

private final class Phase2AIWorkerModelLifecycleNSXPCConnection:
    Phase2AIWorkerModelLifecycleXPCConnection, @unchecked Sendable
{
    private let connection: NSXPCConnection

    init(serviceName: String) {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: Phase2AIWorkerXPCProtocol.self)
        connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)
        self.connection = connection
    }

    var interruptionHandler: (@Sendable () -> Void)? {
        get { connection.interruptionHandler }
        set { connection.interruptionHandler = newValue }
    }

    var invalidationHandler: (@Sendable () -> Void)? {
        get { connection.invalidationHandler }
        set { connection.invalidationHandler = newValue }
    }

    func resume() {
        connection.resume()
    }

    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> Phase2AIWorkerXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler) as? Phase2AIWorkerXPCProtocol
    }

    func invalidate() {
        connection.invalidate()
    }
}

private final class Phase2ModelLifecycleOneShot: @unchecked Sendable {
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

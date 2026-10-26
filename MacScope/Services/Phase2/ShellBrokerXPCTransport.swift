import Foundation

enum ShellBrokerXPCTransportError: Error, Equatable, Sendable {
    case unavailable(String)
    case invalidated(String)
    case malformedReply
    case protocolMismatch
}

struct ShellBrokerXPCProcessReceipt: Hashable, Sendable {
    let processIdentifier: Int32
    let connectionIdentity: UUID
    let wireProtocol: String
    let supportedCommands: [Phase2ShellBrokerCommandKind]
}

protocol ShellBrokerXPCTransport: Sendable {
    func handshake() async throws -> Phase2ShellBrokerHandshake
    func perform(_ request: Phase2ShellBrokerCommandRequest) async throws -> Phase2ShellBrokerCommandResponse
    func prepareBrokerProcessReceipt() async throws -> ShellBrokerXPCProcessReceipt
    func revalidateBrokerProcessReceipt(_ receipt: ShellBrokerXPCProcessReceipt) async -> Bool
    func executeSource(_ request: Phase2SourceExecutionRequest) async throws -> Phase2SourceExecutionResponse
    func reset() async
}


extension ShellBrokerXPCTransport {
    func executeSource(_ request: Phase2SourceExecutionRequest) async throws -> Phase2SourceExecutionResponse {
        throw ShellBrokerXPCTransportError.unavailable("Source execution capability unavailable")
    }
}

final class NSXPCShellBrokerTransport: ShellBrokerXPCTransport, @unchecked Sendable {
    private let endpoint: Phase2ShellBrokerEndpoint
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var connectionGeneration = UUID()
    private var invalidationReason: String?
    private var pending: [UUID: ShellBrokerPendingOperation] = [:]
    private var preparedHandshake: Phase2ShellBrokerHandshake?
    private var preparedGeneration: UUID?

    init(endpoint: Phase2ShellBrokerEndpoint = Phase2ShellBrokerLaunchAgentRegistration.endpoint) {
        self.endpoint = endpoint
    }

    func handshake() async throws -> Phase2ShellBrokerHandshake {
        let (_, proxy, generation) = try connectionAndProxy()
        return try await verifyHandshake(proxy: proxy, generation: generation)
    }

    func perform(_ request: Phase2ShellBrokerCommandRequest) async throws -> Phase2ShellBrokerCommandResponse {
        let (_, proxy, generation) = try connectionAndProxy()
        _ = try await verifyHandshake(proxy: proxy, generation: generation)
        let requestData = try Phase2ShellBrokerWireCodec.encodeCommandRequest(request)
        guard requestData.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
            throw ShellBrokerXPCTransportError.malformedReply
        }

        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let operation = ShellBrokerPendingOperation { error in
                    continuation.resume(throwing: error)
                }
                guard registerPendingOperation(operation, id: operationID, generation: generation) else {
                    operation.fail(ShellBrokerXPCTransportError.invalidated("stale ShellBroker command"))
                    return
                }
                if Task.isCancelled {
                    cancelPendingOperation(id: operationID, generation: generation)
                    return
                }
                proxy.performCommand(requestData) { [weak self] data in
                    guard let self else {
                        operation.fail(ShellBrokerXPCTransportError.invalidated("ShellBroker transport released"))
                        return
                    }
                    guard let claimed = self.claimPendingOperation(id: operationID, generation: generation),
                          claimed === operation,
                          operation.complete()
                    else { return }
                    do {
                        guard data.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
                            throw ShellBrokerXPCTransportError.malformedReply
                        }
                        let response = try Phase2ShellBrokerWireCodec.decodeCommandResponse(data)
                        guard response.commandID == request.commandID,
                              response.command == request.command
                        else {
                            throw ShellBrokerXPCTransportError.malformedReply
                        }
                        continuation.resume(returning: response)
                    } catch {
                        continuation.resume(throwing: ShellBrokerXPCTransportError.malformedReply)
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.cancelPendingOperation(id: operationID, generation: generation)
        }
    }

    /// Cancellation keeps the reply alive until the broker returns actual terminal cleanup authority.
    func executeSource(_ request: Phase2SourceExecutionRequest) async throws -> Phase2SourceExecutionResponse {
        let (_, proxy, generation) = try connectionAndProxy()
        let handshake = try await verifyHandshake(proxy: proxy, generation: generation)
        guard handshake.sourceExecutionProtocol == Phase2SourceExecutionWireCodec.protocolIdentity else {
            throw ShellBrokerXPCTransportError.protocolMismatch
        }
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(request)
        let operationID = UUID()
        let cancellation = ShellBrokerSourceCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pendingOperation = ShellBrokerPendingOperation { error in
                    continuation.resume(throwing: error)
                }
                guard registerPendingOperation(pendingOperation, id: operationID, generation: generation) else {
                    pendingOperation.fail(ShellBrokerXPCTransportError.invalidated("stale source execution")); return
                }
                // Always dispatch the execute request once registered, even if cancellation races it.
                // The broker handles cancel-before-execute with one bounded request-bound tombstone.
                proxy.executeSource(bytes) { [weak self] data in
                    guard let self else {
                        pendingOperation.fail(ShellBrokerXPCTransportError.invalidated("source transport released")); return
                    }
                    guard let claimed = self.claimPendingOperation(id: operationID, generation: generation),
                          claimed === pendingOperation, pendingOperation.complete() else { return }
                    do {
                        let response = try Phase2SourceExecutionWireCodec.decodeResponse(data)
                        guard response.requestID == request.requestID, response.sessionID == request.sessionID,
                              response.operation == request.operation else {
                            throw ShellBrokerXPCTransportError.malformedReply
                        }
                        continuation.resume(returning: response)
                    } catch { continuation.resume(throwing: ShellBrokerXPCTransportError.malformedReply) }
                }
                cancellation.started {
                    proxy.cancelSource(bytes) { _ in }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func prepareBrokerProcessReceipt() async throws -> ShellBrokerXPCProcessReceipt {
        let (connection, proxy, generation) = try connectionAndProxy()
        let handshake = try await verifyHandshake(proxy: proxy, generation: generation)
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 1 else {
            throw ShellBrokerXPCTransportError.malformedReply
        }
        return try lock.withLock {
            guard self.connection === connection,
                  connectionGeneration == generation,
                  preparedGeneration == generation,
                  invalidationReason == nil,
                  connection.processIdentifier == processIdentifier
            else {
                throw ShellBrokerXPCTransportError.invalidated("stale ShellBroker process receipt")
            }
            return ShellBrokerXPCProcessReceipt(
                processIdentifier: processIdentifier,
                connectionIdentity: generation,
                wireProtocol: handshake.wireProtocol,
                supportedCommands: handshake.supportedCommands.compactMap(Phase2ShellBrokerCommandKind.init(rawValue:))
            )
        }
    }

    func revalidateBrokerProcessReceipt(_ receipt: ShellBrokerXPCProcessReceipt) async -> Bool {
        lock.withLock {
            guard let connection,
                  self.connection === connection,
                  invalidationReason == nil,
                  connectionGeneration == receipt.connectionIdentity,
                  preparedGeneration == receipt.connectionIdentity,
                  receipt.processIdentifier > 1,
                  connection.processIdentifier == receipt.processIdentifier,
                  receipt.wireProtocol == Phase2ShellBrokerProtocolIdentity.wireProtocol,
                  receipt.supportedCommands == Phase2ShellBrokerCommandKind.allCases
            else { return false }
            return true
        }
    }

    func reset() async {
        let (oldConnection, remote, activePending) = lock.withLock {
            () -> (NSXPCConnection?, Phase2ShellBrokerXPCProtocol?, [ShellBrokerPendingOperation]) in
            let old = connection
            let remote = old.flatMap {
                try? remoteProxy(for: $0, generation: connectionGeneration)
            }
            let pending = Array(pending.values)
            connection = nil
            connectionGeneration = UUID()
            invalidationReason = nil
            preparedHandshake = nil
            preparedGeneration = nil
            self.pending.removeAll()
            return (old, remote, pending)
        }
        activePending.forEach {
            $0.fail(ShellBrokerXPCTransportError.invalidated("ShellBroker connection reset"))
        }
        remote?.invalidate()
        oldConnection?.invalidate()
    }

    private func connectionAndProxy() throws -> (NSXPCConnection, Phase2ShellBrokerXPCProtocol, UUID) {
        try lock.withLock {
            if let invalidationReason {
                throw ShellBrokerXPCTransportError.invalidated(invalidationReason)
            }
            if let connection {
                return (connection, try remoteProxy(for: connection, generation: connectionGeneration), connectionGeneration)
            }

            let connection: NSXPCConnection
            switch endpoint {
            case .embeddedApplicationService:
                connection = NSXPCConnection(
                    serviceName: Phase2ShellBrokerProtocolIdentity.embeddedServiceName
                )
            case .persistentLaunchAgent:
                connection = NSXPCConnection(
                    machServiceName: Phase2ShellBrokerProtocolIdentity.persistentMachServiceName,
                    options: []
                )
            }
            connection.remoteObjectInterface = NSXPCInterface(with: Phase2ShellBrokerXPCProtocol.self)
            connection.setCodeSigningRequirement(
                endpoint == .persistentLaunchAgent
                    ? Phase2ShellBrokerPeerRequirement.launchAgent
                    : Phase2ShellBrokerPeerRequirement.broker
            )
            let generation = connectionGeneration
            connection.interruptionHandler = { [weak self] in
                self?.invalidate(generation: generation, reason: "ShellBroker interrupted")
            }
            connection.invalidationHandler = { [weak self] in
                self?.invalidate(generation: generation, reason: "ShellBroker invalidated")
            }
            connection.resume()
            self.connection = connection
            return (connection, try remoteProxy(for: connection, generation: generation), generation)
        }
    }

    private func remoteProxy(
        for connection: NSXPCConnection,
        generation: UUID
    ) throws -> Phase2ShellBrokerXPCProtocol {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.invalidate(generation: generation, reason: String(describing: error))
        }) as? Phase2ShellBrokerXPCProtocol else {
            throw ShellBrokerXPCTransportError.unavailable("ShellBroker proxy unavailable")
        }
        return proxy
    }

    private func verifyHandshake(
        proxy: Phase2ShellBrokerXPCProtocol,
        generation: UUID
    ) async throws -> Phase2ShellBrokerHandshake {
        if let cached = lock.withLock({ preparedGeneration == generation ? preparedHandshake : nil }) {
            return cached
        }
        let handshakeID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let operation = ShellBrokerPendingOperation { error in
                    continuation.resume(throwing: error)
                }
                guard registerPendingOperation(operation, id: handshakeID, generation: generation) else {
                    operation.fail(ShellBrokerXPCTransportError.invalidated("stale ShellBroker handshake"))
                    return
                }
                if Task.isCancelled {
                    cancelPendingOperation(id: handshakeID, generation: generation)
                    return
                }
                proxy.handshake { [weak self] data in
                    guard let self else {
                        operation.fail(ShellBrokerXPCTransportError.invalidated("ShellBroker transport released"))
                        return
                    }
                    let result: Result<Phase2ShellBrokerHandshake, ShellBrokerXPCTransportError>
                    do {
                        guard data.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
                            throw ShellBrokerXPCTransportError.malformedReply
                        }
                        let handshake = try Phase2ShellBrokerWireCodec.decodeHandshake(data)
                        guard handshake.schemaVersion == Phase2ShellBrokerProtocolIdentity.schemaVersion,
                              handshake.serviceIdentifier == Phase2ShellBrokerProtocolIdentity.serviceIdentifier,
                              handshake.wireProtocol == Phase2ShellBrokerProtocolIdentity.wireProtocol,
                              handshake.status == .boundaryReady,
                              handshake.maximumMessageBytes == Phase2ShellBrokerProtocolIdentity.maximumMessageBytes,
                              handshake.supportedCommands == Phase2ShellBrokerCommandKind.allCases.map(\.rawValue)
                        else {
                            throw ShellBrokerXPCTransportError.protocolMismatch
                        }
                        result = .success(handshake)
                    } catch let error as ShellBrokerXPCTransportError {
                        result = .failure(error)
                    } catch {
                        result = .failure(.malformedReply)
                    }

                    let claimed = self.lock.withLock { () -> ShellBrokerPendingOperation? in
                        guard self.connectionGeneration == generation,
                              self.connection != nil,
                              self.invalidationReason == nil,
                              let claimed = self.pending.removeValue(forKey: handshakeID),
                              claimed === operation
                        else { return nil }
                        if case .success(let handshake) = result {
                            self.preparedHandshake = handshake
                            self.preparedGeneration = generation
                        }
                        return claimed
                    }
                    guard let claimed, claimed.complete() else { return }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelPendingOperation(id: handshakeID, generation: generation)
        }
    }

    private func registerPendingOperation(
        _ operation: ShellBrokerPendingOperation,
        id: UUID,
        generation: UUID
    ) -> Bool {
        lock.withLock {
            guard connectionGeneration == generation,
                  connection != nil,
                  invalidationReason == nil
            else { return false }
            pending[id] = operation
            return true
        }
    }

    private func claimPendingOperation(id: UUID, generation: UUID) -> ShellBrokerPendingOperation? {
        lock.withLock {
            guard connectionGeneration == generation,
                  connection != nil,
                  invalidationReason == nil
            else { return nil }
            return pending.removeValue(forKey: id)
        }
    }

    private func cancelPendingOperation(id: UUID, generation: UUID) {
        let operation = lock.withLock { () -> ShellBrokerPendingOperation? in
            guard connectionGeneration == generation else { return nil }
            return pending.removeValue(forKey: id)
        }
        operation?.fail(CancellationError())
    }

    private func invalidate(generation: UUID, reason: String) {
        let activePending = lock.withLock { () -> [ShellBrokerPendingOperation] in
            guard generation == connectionGeneration else { return [] }
            invalidationReason = reason
            connection = nil
            preparedHandshake = nil
            preparedGeneration = nil
            let active = Array(pending.values)
            pending.removeAll()
            return active
        }
        activePending.forEach {
            $0.fail(ShellBrokerXPCTransportError.invalidated(reason))
        }
    }
}

private final class ShellBrokerPendingOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var failBlock: ((Error) -> Void)?

    init(onFailure: @escaping (Error) -> Void) {
        failBlock = onFailure
    }

    func complete() -> Bool {
        lock.withLock {
            guard failBlock != nil else { return false }
            failBlock = nil
            return true
        }
    }

    func fail(_ error: Error) {
        let block = lock.withLock { () -> ((Error) -> Void)? in
            defer { failBlock = nil }
            return failBlock
        }
        block?(error)
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}


/// The state lock permits cancellation before registration without abandoning terminal cleanup.
private final class ShellBrokerSourceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var send: (() -> Void)?
    func started(_ operation: @escaping () -> Void) {
        let shouldSend = lock.withLock { () -> Bool in
            if cancelled { return true }
            send = operation; return false
        }
        if shouldSend { operation() }
    }
    func cancel() {
        let operation = lock.withLock { () -> (() -> Void)? in
            cancelled = true; defer { send = nil }; return send
        }
        operation?()
    }
}

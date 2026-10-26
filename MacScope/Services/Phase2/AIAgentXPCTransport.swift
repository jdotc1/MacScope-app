import Foundation

enum AIAgentXPCTransportError: Error, Equatable, Sendable {
    case unavailable(String)
    case invalidated(String)
    case malformedReply
    case protocolMismatch
    case terminalProtocolMismatch(AIAgentXPCTransportTerminal)
}

enum Phase2AIWorkerProductionHandshakeAuthority {
    static func validate(
        _ data: Data,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle =
            Phase2AIWorkerProductionProtocol.assistantR4
    ) throws {
        let handshake: Phase2AIWorkerHandshake
        do {
            handshake = try Phase2AIWorkerWireCodec().decodeHandshake(data)
        } catch {
            throw AIAgentXPCTransportError.malformedReply
        }
        guard handshake.status == .ready,
              handshake.wireProtocol == expectedProtocolBundle.wireIdentity,
              handshake.inferenceProtocol == expectedProtocolBundle.inferenceIdentity,
              handshake.manifestIdentity == expectedProtocolBundle.manifestIdentity
        else {
            throw AIAgentXPCTransportError.protocolMismatch
        }
    }
}

protocol AIAgentXPCTransport: Sendable {
    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws

    func cancel(requestID: UUID) async
    func reset() async

    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt
    func revalidateWorkerProcessReceipt(_ receipt: AIAgentXPCWorkerProcessReceipt) async -> Bool
}

/// Opt-in transport capability that retains the signed worker's exact terminal. Requiring this
/// capability prevents a legacy or test transport from synthesizing terminal authority merely
/// because its event stream returned normally.
protocol AIAgentXPCTerminalPreservingTransport: AIAgentXPCTransport {
    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal

    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal
}

struct AIAgentXPCTransportTerminal: Equatable, Sendable {
    let requestID: UUID
    let wireProtocol: String
    let protocolVersion: Int
    let phase: Phase2AIWorkerWirePhase?
    let negotiatedProtocolManifestDigest: String
    let status: Phase2AIWorkerTerminal.Status
    let reason: Phase2AIWorkerTerminal.Reason?
    let semanticRequestAccepted: Bool

    init(
        requestID: UUID,
        status: Phase2AIWorkerTerminal.Status,
        reason: Phase2AIWorkerTerminal.Reason?,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            Phase2AIWorkerProductionProtocol.reconstructionR1,
        phase: Phase2AIWorkerWirePhase? = .finalization,
        semanticRequestAccepted: Bool? = nil
    ) {
        self.init(
            requestID: requestID,
            wireProtocol: protocolBundle.wireIdentity,
            protocolVersion: protocolBundle.inferenceVersion,
            phase: phase,
            negotiatedProtocolManifestDigest: protocolBundle.manifestDigest,
            status: status,
            reason: reason,
            semanticRequestAccepted: semanticRequestAccepted
                ?? (status == .completed || status == .awaitingTools)
        )
    }

    init(
        requestID: UUID,
        wireProtocol: String,
        protocolVersion: Int,
        phase: Phase2AIWorkerWirePhase?,
        negotiatedProtocolManifestDigest: String,
        status: Phase2AIWorkerTerminal.Status,
        reason: Phase2AIWorkerTerminal.Reason?,
        semanticRequestAccepted: Bool
    ) {
        self.requestID = requestID
        self.wireProtocol = wireProtocol
        self.protocolVersion = protocolVersion
        self.phase = phase
        self.negotiatedProtocolManifestDigest = negotiatedProtocolManifestDigest
        self.status = status
        self.reason = reason
        self.semanticRequestAccepted = semanticRequestAccepted
    }

    func validated(
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase
    ) throws -> Self {
        guard wireProtocol == expectedProtocolBundle.wireIdentity,
              protocolVersion == expectedProtocolBundle.inferenceVersion,
              negotiatedProtocolManifestDigest == expectedProtocolBundle.manifestDigest,
              phase == expectedPhase
        else {
            throw AIAgentXPCTransportError.terminalProtocolMismatch(self)
        }
        return self
    }
}

struct AIAgentXPCWorkerProcessReceipt: Hashable, Sendable {
    let processIdentifier: Int32
    let connectionIdentity: UUID
    let profileID: UUID
    let configurationGeneration: UInt64
    let protocolManifestDigest: String
}

extension AIAgentXPCTransport {
    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt {
        throw AIAgentXPCTransportError.unavailable(
            "AI worker process receipt unavailable"
        )
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: AIAgentXPCWorkerProcessReceipt
    ) async -> Bool {
        _ = receipt
        return false
    }
}

extension AIAgentXPCTerminalPreservingTransport {
    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            receive: receive
        ).validated(
            expectedProtocolBundle: expectedProtocolBundle,
            expectedPhase: expectedPhase
        )
    }
}

/// Internal connection seam: the production constructor always installs the signed XPC
/// requirement, while focused tests can exercise timeout and cancellation state without a
/// live worker process. It is intentionally not part of the transport protocol or product API.
protocol AIAgentXPCConnecting: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var interruptionHandler: (@Sendable () -> Void)? { get set }
    var invalidationHandler: (@Sendable () -> Void)? { get set }

    func resume()
    func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> Phase2AIWorkerXPCProtocol?
    func invalidate()
}

final class NSXPCAIAgentTransport: AIAgentXPCTerminalPreservingTransport, @unchecked Sendable {
    private static let serviceName = "org.macscope.app.AIAgentWorker"
    static let defaultProtocolBundle = Phase2AIWorkerProductionProtocol.assistantR4

    private let codec: Phase2AIWorkerWireCodec
    private let configuration: Phase2AIProviderConfiguration
    private let configurationCodec: Phase2AIWorkerConfigurationAppCodec
    let protocolBundle: Phase2AIWorkerProductionProtocolBundle
    private let lock = NSLock()
    private let makeConnection: @Sendable () -> any AIAgentXPCConnecting
    #if DEBUG
    private let testBeforeRequestFinish: (@Sendable (UUID, UUID) -> Void)?
    private let testPreparationWaitRegistered: (@Sendable (UUID) -> Void)?
    #endif
    private var connection: (any AIAgentXPCConnecting)?
    private var connectionGeneration = UUID()
    private var invalidationReason: String?
    private var proxy: Phase2AIWorkerXPCProtocol?
    private var sinks: [UUID: PendingSink] = [:]
    private var handshakes: [UUID: PendingHandshake] = [:]
    private var preparation: PendingPreparation?
    private var preparationWaits: [UUID: PendingPreparationWait] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    /// A request ID may be retried immediately after reset. The UUID alone is therefore not
    /// sufficient authority for delayed cancellation, deadline, or deferred-cleanup work.
    private var activeRequestTokens: [UUID: UUID] = [:]
    private var cancelledRequestTokens: [UUID: UUID] = [:]
    private var preparedGeneration: UUID?

    private struct PendingSink {
        let sink: Phase2AIWorkerClientEventSink
        let generation: UUID
        let requestToken: UUID
    }

    private struct PendingHandshake {
        let once: Phase2AIWorkerOneShot
        let generation: UUID
    }

    private struct PendingPreparation {
        let token: UUID
        let generation: UUID
        let task: Task<Void, Error>
    }

    private struct PendingPreparationWait {
        let once: Phase2AIWorkerOneShot
        let generation: UUID
        let requestToken: UUID
    }

    /// NSXPC remote proxies are immutable communication handles whose invocations are
    /// dispatched by NSXPCConnection. Keep the unchecked boundary local to the one shared
    /// preparation task instead of widening the Objective-C product protocol to Sendable.
    private final class PreparationProxyReference: @unchecked Sendable {
        let value: Phase2AIWorkerXPCProtocol

        init(_ value: Phase2AIWorkerXPCProtocol) {
            self.value = value
        }
    }

    init(
        configuration: Phase2AIProviderConfiguration,
        codec: Phase2AIWorkerWireCodec = .init(),
        configurationCodec: Phase2AIWorkerConfigurationAppCodec = .init(),
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            NSXPCAIAgentTransport.defaultProtocolBundle
    ) {
        self.configuration = configuration
        self.codec = codec
        self.configurationCodec = configurationCodec
        self.protocolBundle = protocolBundle
        #if DEBUG
        testBeforeRequestFinish = nil
        testPreparationWaitRegistered = nil
        #endif
        makeConnection = {
            AIAgentNSXPCConnection(serviceName: NSXPCAIAgentTransport.serviceName)
        }
    }

    #if DEBUG
    /// Debug/test-only transport construction. Release product authority has no injectable
    /// connection path: every Release connection is constructed above with code-sign admission
    /// installed before its interface is exposed or resumed.
    init(
        configuration: Phase2AIProviderConfiguration,
        codec: Phase2AIWorkerWireCodec = .init(),
        configurationCodec: Phase2AIWorkerConfigurationAppCodec = .init(),
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            NSXPCAIAgentTransport.defaultProtocolBundle,
        testConnectionFactory: @escaping @Sendable () -> any AIAgentXPCConnecting,
        testBeforeRequestFinish: (@Sendable (UUID, UUID) -> Void)? = nil,
        testPreparationWaitRegistered: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.codec = codec
        self.configurationCodec = configurationCodec
        self.protocolBundle = protocolBundle
        self.testBeforeRequestFinish = testBeforeRequestFinish
        self.testPreparationWaitRegistered = testPreparationWaitRegistered
        makeConnection = testConnectionFactory
    }
    #endif

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let terminal = try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            receive: receive
        )
        switch terminal.status {
        case .completed, .awaitingTools:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            if terminal.reason == .outputLimitExceeded {
                throw Phase2ProviderOutputLimitReached()
            }
            throw AIAgentXPCTransportError.unavailable(
                terminal.reason.map(Self.safeFailureMessage) ?? "AI worker failed"
            )
        }
    }

    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            expectedProtocolBundle: protocolBundle,
            expectedPhase: nil,
            receive: receive
        )
    }

    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            expectedProtocolBundle: expectedProtocolBundle,
            expectedPhase: Optional(expectedPhase),
            receive: receive
        )
    }

    private func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase?,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        guard expectedProtocolBundle == protocolBundle else {
            throw AIAgentXPCTransportError.protocolMismatch
        }
        let requestToken = UUID()
        let requestDeadline = ContinuousClock.now.advanced(by:
            .milliseconds(configuration.resourceTimeoutMilliseconds))
        let accepted = lock.withLock { () -> Bool in
            guard activeRequestTokens[requestID] == nil else { return false }
            activeRequestTokens[requestID] = requestToken
            return true
        }
        guard accepted else {
            throw AIAgentXPCTransportError.unavailable("duplicate AI worker request")
        }
        defer { finishRequest(requestID: requestID, requestToken: requestToken) }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (connection, proxy, generation) = try connectionAndProxy()
            try await prepareConnection(
                proxy: proxy,
                generation: generation,
                requestID: requestID,
                requestToken: requestToken
            )
            try Task.checkCancellation()
            guard ContinuousClock.now < requestDeadline else {
                throw AIAgentXPCTransportError.unavailable("AI worker terminal timed out")
            }
            return try await awaitTerminal(
                requestID: requestID,
                requestToken: requestToken,
                requestData: requestData,
                requestDeadline: requestDeadline,
                expectedProtocolBundle: expectedProtocolBundle,
                expectedPhase: expectedPhase,
                proxy: proxy,
                connection: connection,
                generation: generation,
                receive: receive
            )
        } onCancel: { [weak self] in
            self?.cancelSynchronously(requestID: requestID, requestToken: requestToken)
        }
    }

    private static func safeFailureMessage(
        _ reason: Phase2AIWorkerTerminal.Reason
    ) -> String {
        switch reason {
        case .workerNotConfigured: "worker not configured"
        case .requestIdentityMismatch: "request identity mismatch"
        case .duplicateRequest: "duplicate request"
        case .invalidRequest: "invalid request"
        case .workerHandlerFailed: "worker handler failed"
        case .outputLimitExceeded: "model output limit reached; result incomplete"
        case .contextBudgetExceeded: "model context budget exceeded"
        case .overallDeadlineExceeded: "AI worker overall deadline exceeded"
        case .streamInactivityTimeout: "AI worker model progress timed out"
        }
    }

    func cancel(requestID: UUID) async {
        cancelSynchronously(requestID: requestID)
    }

    func reset() async {
        let (oldConnection, activeSinks, activeHandshakes, preparationWaits, deadlines) = lock.withLock {
            () -> ((any AIAgentXPCConnecting)?, [Phase2AIWorkerClientEventSink], [Phase2AIWorkerOneShot], [Phase2AIWorkerOneShot], [Task<Void, Never>]) in
            let old = connection
            let active = sinks.values.map(\.sink)
            let pending = handshakes.values.map(\.once)
            let deadlines = Array(deadlineTasks.values)
            connection = nil
            proxy = nil
            connectionGeneration = UUID()
            preparedGeneration = nil
            invalidationReason = nil
            sinks.removeAll()
            handshakes.removeAll()
            preparation = nil
            let preparationWaitSnapshots = preparationWaits.values.map(\.once)
            preparationWaits.removeAll()
            deadlineTasks.removeAll()
            // Reset starts a new request-identity epoch. Stale deferred cleanup carries the
            // former token and therefore cannot erase a same-ID retry admitted below.
            activeRequestTokens.removeAll()
            cancelledRequestTokens.removeAll()
            return (old, active, pending, preparationWaitSnapshots, deadlines)
        }
        deadlines.forEach { $0.cancel() }
        let error = AIAgentXPCTransportError.invalidated("AI worker connection reset")
        activeSinks.forEach { $0.fail(error) }
        activeHandshakes.forEach { $0.resume(.failure(error)) }
        preparationWaits.forEach { $0.resume(.failure(error)) }
        oldConnection?.invalidate()
    }

    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt {
        let (connection, proxy, generation) = try connectionAndProxy()
        try await prepareConnection(proxy: proxy, generation: generation, requestID: nil)
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 1 else {
            throw AIAgentXPCTransportError.malformedReply
        }
        return try lock.withLock {
            guard self.connection === connection,
                  connectionGeneration == generation,
                  preparedGeneration == generation,
                  invalidationReason == nil,
                  connection.processIdentifier == processIdentifier
            else {
                throw AIAgentXPCTransportError.invalidated(
                    "stale AI worker process receipt"
                )
            }
            return AIAgentXPCWorkerProcessReceipt(
                processIdentifier: processIdentifier,
                connectionIdentity: generation,
                profileID: configuration.profileID,
                configurationGeneration: configuration.generation,
                protocolManifestDigest: protocolBundle.manifestDigest
            )
        }
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: AIAgentXPCWorkerProcessReceipt
    ) async -> Bool {
        lock.withLock {
            guard let connection,
                  self.connection === connection,
                  invalidationReason == nil,
                  connectionGeneration == receipt.connectionIdentity,
                  preparedGeneration == receipt.connectionIdentity,
                  receipt.profileID == configuration.profileID,
                  receipt.configurationGeneration == configuration.generation,
                  receipt.protocolManifestDigest == protocolBundle.manifestDigest,
                  receipt.processIdentifier > 1,
                  connection.processIdentifier == receipt.processIdentifier
            else { return false }
            return true
        }
    }

    private func connectionAndProxy() throws -> (
        any AIAgentXPCConnecting, Phase2AIWorkerXPCProtocol, UUID
    ) {
        try lock.withLock {
            if let invalidationReason {
                throw AIAgentXPCTransportError.invalidated(invalidationReason)
            }
            if let connection {
                guard let proxy else {
                    throw AIAgentXPCTransportError.unavailable("AI worker proxy unavailable")
                }
                return (connection, proxy, connectionGeneration)
            }

            let connection = makeConnection()
            let generation = connectionGeneration
            connection.interruptionHandler = { [weak self] in
                self?.invalidate(generation: generation, reason: "AI worker interrupted")
            }
            connection.invalidationHandler = { [weak self] in
                self?.invalidate(generation: generation, reason: "AI worker invalidated")
            }
            connection.resume()
            self.connection = connection
            guard let proxy = connection.remoteProxy(errorHandler: { [weak self] error in
                self?.invalidate(generation: generation, reason: String(describing: error))
            }) else {
                self.connection = nil
                connection.invalidate()
                throw AIAgentXPCTransportError.unavailable("AI worker proxy unavailable")
            }
            self.proxy = proxy
            return (connection, proxy, generation)
        }
    }

    private func prepareConnection(
        proxy: Phase2AIWorkerXPCProtocol,
        generation: UUID,
        requestID: UUID?,
        requestToken: UUID? = nil
    ) async throws {
        if lock.withLock({ preparedGeneration == generation }) { return }
        let sharedPreparation = lock.withLock { () -> PendingPreparation in
            if let preparation, preparation.generation == generation {
                return preparation
            }
            let preparationToken = UUID()
            let proxyReference = PreparationProxyReference(proxy)
            let task = Task { [weak self, proxyReference] in
                guard let self else {
                    throw AIAgentXPCTransportError.invalidated("transport released")
                }
                defer { self.finishPreparation(generation: generation, preparationToken: preparationToken) }
                try await self.verifyHandshake(proxy: proxyReference.value, generation: generation)
                try await self.configureConnection(proxy: proxyReference.value, generation: generation)
            }
            let preparation = PendingPreparation(
                token: preparationToken,
                generation: generation,
                task: task
            )
            self.preparation = preparation
            return preparation
        }
        guard let requestID, let requestToken else {
            return try await sharedPreparation.task.value
        }
        try await awaitPreparation(
            sharedPreparation,
            requestID: requestID,
            requestToken: requestToken
        )
    }

    private func configureConnection(
        proxy: Phase2AIWorkerXPCProtocol,
        generation: UUID
    ) async throws {
        let payload = try configurationCodec.encodeConfiguration(
            configuration,
            protocolBundle: protocolBundle
        )
        let operationID = UUID()
        try await withDeadlineContinuation(
            operationID: operationID,
            generation: generation,
            timeoutMessage: "AI worker configuration timed out"
        ) { once in
            proxy.configure(configurationData: payload) { [weak self, configuration, configurationCodec] data in
                guard let self else {
                    once.resume(.failure(AIAgentXPCTransportError.invalidated("transport released")))
                    return
                }
                do {
                    let acknowledgement = try configurationCodec.decodeAcknowledgement(data)
                    guard acknowledgement.status == .accepted,
                          acknowledgement.profileID == configuration.profileID,
                          acknowledgement.generation == configuration.generation,
                          acknowledgement.protocolManifestDigest
                            == self.protocolBundle.manifestDigest
                    else { throw AIAgentXPCTransportError.malformedReply }
                    let ready = self.lock.withLock { () -> Bool in
                        guard self.connectionGeneration == generation else { return false }
                        self.preparedGeneration = generation
                        return true
                    }
                    self.resolveHandshake(
                        operationID: operationID,
                        generation: generation,
                        result: ready
                            ? .success(())
                            : .failure(AIAgentXPCTransportError.invalidated("stale AI worker configuration"))
                    )
                } catch let error as AIAgentXPCTransportError {
                    self.resolveHandshake(operationID: operationID, generation: generation, result: .failure(error))
                } catch {
                    self.resolveHandshake(
                        operationID: operationID,
                        generation: generation,
                        result: .failure(AIAgentXPCTransportError.malformedReply)
                    )
                }
            }
        }
    }

    /// Each connection generation owns one preparation task. Individual request waiters are
    /// removed and resumed independently, so cancellation cannot retire shared XPC authority.
    private func awaitPreparation(
        _ sharedPreparation: PendingPreparation,
        requestID: UUID,
        requestToken: UUID
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let once = Phase2AIWorkerOneShot(continuation)
            let registered = lock.withLock { () -> Bool in
                guard connectionGeneration == sharedPreparation.generation,
                      activeRequestTokens[requestID] == requestToken,
                      cancelledRequestTokens[requestID] != requestToken
                else { return false }
                preparationWaits[requestID] = .init(
                    once: once,
                    generation: sharedPreparation.generation,
                    requestToken: requestToken
                )
                return true
            }
            guard registered else {
                once.resume(.failure(CancellationError()))
                return
            }
            #if DEBUG
            // Observe the actual admission boundary, outside the lock. Seeing a remote
            // handshake alone does not prove that either local waiter has registered.
            testPreparationWaitRegistered?(requestID)
            #endif
            Task { [weak self] in
                do {
                    try await sharedPreparation.task.value
                    self?.resolvePreparationWait(
                        requestID: requestID,
                        requestToken: requestToken,
                        generation: sharedPreparation.generation,
                        result: .success(())
                    )
                } catch {
                    self?.resolvePreparationWait(
                        requestID: requestID,
                        requestToken: requestToken,
                        generation: sharedPreparation.generation,
                        result: .failure(error)
                    )
                }
            }
        }
    }

    private func finishPreparation(generation: UUID, preparationToken: UUID) {
        lock.withLock {
            guard preparation?.generation == generation,
                  preparation?.token == preparationToken
            else { return }
            preparation = nil
        }
    }

    private func resolvePreparationWait(
        requestID: UUID,
        requestToken: UUID,
        generation: UUID,
        result: Result<Void, Error>
    ) {
        let once = lock.withLock { () -> Phase2AIWorkerOneShot? in
            guard let pending = preparationWaits[requestID],
                  pending.requestToken == requestToken,
                  pending.generation == generation
            else { return nil }
            preparationWaits.removeValue(forKey: requestID)
            return pending.once
        }
        once?.resume(result)
    }

    private func verifyHandshake(
        proxy: Phase2AIWorkerXPCProtocol,
        generation: UUID
    ) async throws {
        let handshakeID = UUID()
        try await withDeadlineContinuation(
            operationID: handshakeID,
            generation: generation,
            timeoutMessage: "AI worker handshake timed out"
        ) { once in
            let receiveHandshake: @Sendable (Data) -> Void = { [weak self, codec] data in
                guard let self else {
                    once.resume(.failure(AIAgentXPCTransportError.invalidated("transport released")))
                    return
                }
                do {
                    let handshake = try codec.decodeHandshake(data)
                    guard handshake.wireProtocol == self.protocolBundle.wireIdentity,
                          handshake.inferenceProtocol
                            == self.protocolBundle.inferenceIdentity,
                          handshake.manifestIdentity
                            == self.protocolBundle.manifestIdentity
                    else { throw AIAgentXPCTransportError.protocolMismatch }
                    self.resolveHandshake(operationID: handshakeID, generation: generation, result: .success(()))
                } catch let error as Phase2AIWorkerWireError {
                    if case .unsupportedProtocolVersion = error {
                        self.resolveHandshake(operationID: handshakeID, generation: generation, result: .failure(AIAgentXPCTransportError.protocolMismatch))
                    } else {
                        self.resolveHandshake(operationID: handshakeID, generation: generation, result: .failure(AIAgentXPCTransportError.malformedReply))
                    }
                } catch {
                    self.resolveHandshake(operationID: handshakeID, generation: generation, result: .failure(AIAgentXPCTransportError.malformedReply))
                }
            }
            if protocolBundle == Self.defaultProtocolBundle {
                proxy.handshake(with: receiveHandshake)
            } else {
                guard proxy.responds(to: #selector(
                    Phase2AIWorkerXPCProtocol.handshake(
                        protocolManifestIdentity:with:
                    )
                )) else {
                    resolveHandshake(operationID: handshakeID, generation: generation, result: .failure(AIAgentXPCTransportError.protocolMismatch))
                    return
                }
                proxy.handshake?(
                    protocolManifestIdentity: protocolBundle.manifestIdentity,
                    with: receiveHandshake
                )
            }
        }
    }

    private func awaitTerminal(
        requestID: UUID,
        requestToken: UUID,
        requestData: Data,
        requestDeadline: ContinuousClock.Instant,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase?,
        proxy: Phase2AIWorkerXPCProtocol,
        connection: any AIAgentXPCConnecting,
        generation: UUID,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        try await withCheckedThrowingContinuation { continuation in
            let sink = Phase2AIWorkerClientEventSink(
                requestID: requestID,
                codec: codec,
                protocolBundle: expectedProtocolBundle,
                expectedPhase: expectedPhase,
                receive: receive
            ) { [weak self] result in
                self?.removeSink(requestID: requestID, requestToken: requestToken)
                continuation.resume(with: result)
            }
            let registered = lock.withLock { () -> Bool in
                guard connectionGeneration == generation,
                      self.connection === connection,
                      activeRequestTokens[requestID] == requestToken,
                      cancelledRequestTokens[requestID] != requestToken,
                      sinks[requestID] == nil
                else { return false }
                sinks[requestID] = .init(
                    sink: sink,
                    generation: generation,
                    requestToken: requestToken
                )
                return true
            }
            guard registered else {
                continuation.resume(throwing: CancellationError())
                return
            }
            installDeadline(
                operationID: requestID,
                generation: generation,
                message: "AI worker terminal timed out",
                timeout: max(.zero, ContinuousClock.now.duration(to: requestDeadline))
            ) { [weak self] in
                self?.timeoutSink(
                    requestID: requestID,
                    requestToken: requestToken,
                    generation: generation
                )
            }
            proxy.run(requestData: requestData, requestID: requestID, eventSink: sink)
        }
    }

    private func withDeadlineContinuation(
        operationID: UUID,
        generation: UUID,
        timeoutMessage: String,
        invoke: (Phase2AIWorkerOneShot) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let once = Phase2AIWorkerOneShot(continuation)
            let registered = lock.withLock { () -> Bool in
                guard connectionGeneration == generation, connection != nil else { return false }
                handshakes[operationID] = .init(
                    once: once,
                    generation: generation
                )
                return true
            }
            guard registered else {
                once.resume(.failure(AIAgentXPCTransportError.invalidated("stale AI worker operation")))
                return
            }
            installDeadline(
                operationID: operationID,
                generation: generation,
                message: timeoutMessage,
                timeout: .milliseconds(configuration.inferencePolicy == nil
                    ? configuration.resourceTimeoutMilliseconds
                    : min(configuration.requestTimeoutMilliseconds,
                        configuration.resourceTimeoutMilliseconds))
            ) { [weak self] in
                self?.timeoutHandshake(
                    operationID: operationID,
                    generation: generation,
                    message: timeoutMessage
                )
            }
            invoke(once)
        }
    }

    private func installDeadline(
        operationID: UUID,
        generation: UUID,
        message: String,
        timeout: Duration? = nil,
        fire: @escaping @Sendable () -> Void
    ) {
        let timeout = timeout ?? .milliseconds(configuration.resourceTimeoutMilliseconds)
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            fire()
            _ = self
        }
        let accepted = lock.withLock { () -> Bool in
            guard connectionGeneration == generation,
                  (handshakes[operationID] != nil || sinks[operationID] != nil)
            else { return false }
            deadlineTasks[operationID] = task
            return true
        }
        if !accepted { task.cancel() }
        _ = message
    }

    private func resolveHandshake(
        operationID: UUID,
        generation: UUID,
        result: Result<Void, Error>
    ) {
        let resolved = lock.withLock { () -> (Phase2AIWorkerOneShot?, Task<Void, Never>?) in
            guard let pending = handshakes[operationID], pending.generation == generation else {
                return (nil, nil)
            }
            handshakes.removeValue(forKey: operationID)
            return (pending.once, deadlineTasks.removeValue(forKey: operationID))
        }
        resolved.1?.cancel()
        resolved.0?.resume(result)
    }

    private func timeoutHandshake(operationID: UUID, generation: UUID, message: String) {
        let timedOut = lock.withLock { () -> (Phase2AIWorkerOneShot, Task<Void, Never>?)? in
            guard let pending = handshakes[operationID],
                  pending.generation == generation
            else { return nil }
            handshakes.removeValue(forKey: operationID)
            return (pending.once, deadlineTasks.removeValue(forKey: operationID))
        }
        guard let timedOut else { return }
        timedOut.1?.cancel()
        // Retire the exact connection before publishing the timeout. A caller that has observed
        // the terminal error must never still observe the timed-out generation as live.
        retire(generation: generation, reason: message, recoverable: true)
        timedOut.0.resume(.failure(AIAgentXPCTransportError.unavailable(message)))
    }

    private func timeoutSink(requestID: UUID, requestToken: UUID, generation: UUID) {
        let timedOut = lock.withLock { () -> (PendingSink, Task<Void, Never>?, Phase2AIWorkerXPCProtocol?)? in
            guard let pending = sinks[requestID],
                  pending.generation == generation,
                  pending.requestToken == requestToken,
                  activeRequestTokens[requestID] == requestToken
            else { return nil }
            sinks.removeValue(forKey: requestID)
            return (pending, deadlineTasks.removeValue(forKey: requestID), proxy)
        }
        guard let timedOut else { return }
        timedOut.1?.cancel()
        // Local terminal authority is removed before a synchronous worker terminal can arrive.
        timedOut.0.sink.fail(AIAgentXPCTransportError.unavailable("AI worker terminal timed out"))
        timedOut.2?.cancel(requestID: requestID)
    }

    private func cancelSynchronously(requestID: UUID, requestToken: UUID? = nil) {
        let cancellation = lock.withLock { () -> (
            Phase2AIWorkerXPCProtocol?, PendingPreparationWait?, PendingSink?, Task<Void, Never>?, UUID?
        ) in
            guard let activeToken = activeRequestTokens[requestID],
                  requestToken.map({ $0 == activeToken }) ?? true
            else { return (nil, nil, nil, nil, nil) }
            cancelledRequestTokens[requestID] = activeToken
            let wait = preparationWaits[requestID].flatMap { pending in
                pending.requestToken == activeToken
                    ? preparationWaits.removeValue(forKey: requestID)
                    : nil
            }
            let sink = sinks.removeValue(forKey: requestID)
            let deadline = sink.map { _ in deadlineTasks.removeValue(forKey: requestID) } ?? nil
            let hasUnrelatedActiveRequest = activeRequestTokens.contains {
                $0.key != requestID || $0.value != activeToken
            }
            let retireGeneration = wait != nil && !hasUnrelatedActiveRequest
                ? wait?.generation
                : nil
            return (proxy, wait, sink, deadline, retireGeneration)
        }
        cancellation.3?.cancel()
        cancellation.1?.once.resume(.failure(CancellationError()))
        if let sink = cancellation.2 {
            sink.sink.cancelLocally()
        }
        // A lone cancelled preparation has no remaining caller to preserve. Retiring it keeps a
        // later request from inheriting a cancelled, still-silent handshake. With any sibling
        // admission present, preparation remains shared and is never retired by this request.
        if let generation = cancellation.4 {
            retire(
                generation: generation,
                reason: "AI worker request cancelled",
                recoverable: true
            )
        }
        // Tear down local authority first; a synchronous remote terminal reply must never
        // race cancellation into resuming the pending continuation with success.
        cancellation.0?.cancel(requestID: requestID)
    }

    private func finishRequest(requestID: UUID, requestToken: UUID) {
        #if DEBUG
        testBeforeRequestFinish?(requestID, requestToken)
        #endif
        let deadline = lock.withLock { () -> Task<Void, Never>? in
            guard activeRequestTokens[requestID] == requestToken else { return nil }
            activeRequestTokens.removeValue(forKey: requestID)
            if cancelledRequestTokens[requestID] == requestToken {
                cancelledRequestTokens.removeValue(forKey: requestID)
            }
            if preparationWaits[requestID]?.requestToken == requestToken {
                preparationWaits.removeValue(forKey: requestID)
            }
            if sinks[requestID]?.requestToken == requestToken {
                sinks.removeValue(forKey: requestID)
            }
            return deadlineTasks.removeValue(forKey: requestID)
        }
        deadline?.cancel()
    }

    private func removeSink(requestID: UUID, requestToken: UUID) {
        let deadline = lock.withLock { () -> Task<Void, Never>? in
            guard sinks[requestID]?.requestToken == requestToken else { return nil }
            sinks.removeValue(forKey: requestID)
            return deadlineTasks.removeValue(forKey: requestID)
        }
        deadline?.cancel()
    }

    private func invalidate(generation: UUID, reason: String) {
        retire(generation: generation, reason: reason, recoverable: false)
    }

    private func retire(generation: UUID, reason: String, recoverable: Bool) {
        let state = lock.withLock { () -> (
            (any AIAgentXPCConnecting)?, [Phase2AIWorkerClientEventSink],
            [Phase2AIWorkerOneShot], [Phase2AIWorkerOneShot], [Task<Void, Never>]
        ) in
            guard generation == connectionGeneration else { return (nil, [], [], [], []) }
            let old = connection
            let active = sinks.values.map(\.sink)
            let pending = handshakes.values.map(\.once)
            let preparationWaits = preparationWaits.values.map(\.once)
            let deadlines = Array(deadlineTasks.values)
            connection = nil
            proxy = nil
            preparedGeneration = nil
            invalidationReason = recoverable ? nil : reason
            connectionGeneration = UUID()
            sinks.removeAll()
            handshakes.removeAll()
            preparation = nil
            self.preparationWaits.removeAll()
            deadlineTasks.removeAll()
            activeRequestTokens.removeAll()
            cancelledRequestTokens.removeAll()
            return (old, active, pending, preparationWaits, deadlines)
        }
        state.4.forEach { $0.cancel() }
        state.0?.interruptionHandler = nil
        state.0?.invalidationHandler = nil
        state.0?.invalidate()
        let error = AIAgentXPCTransportError.invalidated(reason)
        state.1.forEach { $0.fail(error) }
        state.2.forEach { $0.resume(.failure(error)) }
        state.3.forEach { $0.resume(.failure(error)) }
    }
}

/// The only production construction path for the transport connection. Signing admission is
/// configured before the interface is exposed or the connection is resumed.
private final class AIAgentNSXPCConnection: AIAgentXPCConnecting, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        let connection = NSXPCConnection(serviceName: serviceName)
        let interface = NSXPCInterface(with: Phase2AIWorkerXPCProtocol.self)
        interface.setInterface(
            NSXPCInterface(with: Phase2AIWorkerEventSinkXPCProtocol.self),
            for: #selector(Phase2AIWorkerXPCProtocol.run(requestData:requestID:eventSink:)),
            argumentIndex: 2,
            ofReply: false
        )
        connection.remoteObjectInterface = interface
        connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)
        self.connection = connection
    }

    var processIdentifier: Int32 { connection.processIdentifier }

    var interruptionHandler: (@Sendable () -> Void)? {
        get { connection.interruptionHandler }
        set { connection.interruptionHandler = newValue }
    }

    var invalidationHandler: (@Sendable () -> Void)? {
        get { connection.invalidationHandler }
        set { connection.invalidationHandler = newValue }
    }

    func resume() { connection.resume() }

    func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> Phase2AIWorkerXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler) as? Phase2AIWorkerXPCProtocol
    }

    func invalidate() { connection.invalidate() }
}

private final class Phase2AIWorkerClientEventSink: NSObject,
    Phase2AIWorkerEventSinkXPCProtocol,
    @unchecked Sendable
{
    private let requestID: UUID
    private let codec: Phase2AIWorkerWireCodec
    private let protocolBundle: Phase2AIWorkerProductionProtocolBundle
    private let expectedPhase: Phase2AIWorkerWirePhase?
    private let receiveEvent: @Sendable (Data) async throws -> Void
    private let lock = NSLock()
    private var completion: ((Result<AIAgentXPCTransportTerminal, Error>) -> Void)?

    init(
        requestID: UUID,
        codec: Phase2AIWorkerWireCodec,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle,
        expectedPhase: Phase2AIWorkerWirePhase?,
        receive: @escaping @Sendable (Data) async throws -> Void,
        completion: @escaping (Result<AIAgentXPCTransportTerminal, Error>) -> Void
    ) {
        self.requestID = requestID
        self.codec = codec
        self.protocolBundle = protocolBundle
        self.expectedPhase = expectedPhase
        receiveEvent = receive
        self.completion = completion
    }

    func receive(eventData: Data, with reply: @escaping (Bool) -> Void) {
        let acknowledgement = Phase2AIWorkerAcknowledgement(reply)
        guard lock.withLock({ completion != nil }) else {
            acknowledgement.send(false)
            return
        }
        Task {
            do {
                try await receiveEvent(eventData)
                acknowledgement.send(lock.withLock { completion != nil })
            } catch {
                acknowledgement.send(false)
                finish(.failure(error))
            }
        }
    }

    func finish(resultData: Data) {
        do {
            let terminal = try codec.decodeTerminal(resultData)
            guard terminal.requestID == requestID else {
                return finish(.failure(AIAgentXPCTransportError.malformedReply))
            }
            let preserved = AIAgentXPCTransportTerminal(
                requestID: terminal.requestID,
                wireProtocol: terminal.wireProtocol,
                protocolVersion: terminal.protocolVersion,
                phase: terminal.phase,
                negotiatedProtocolManifestDigest: protocolBundle.manifestDigest,
                status: terminal.status,
                reason: terminal.reason,
                semanticRequestAccepted: Self.semanticRequestWasAccepted(terminal)
            )
            guard terminal.wireProtocol == protocolBundle.wireIdentity,
                  terminal.protocolVersion == protocolBundle.inferenceVersion,
                  expectedPhase.map({ terminal.phase == $0 }) ?? true
            else {
                return finish(.failure(
                    AIAgentXPCTransportError.terminalProtocolMismatch(preserved)
                ))
            }
            finish(.success(preserved))
        } catch {
            finish(.failure(AIAgentXPCTransportError.malformedReply))
        }
    }

    private static func semanticRequestWasAccepted(
        _ terminal: Phase2AIWorkerTerminal
    ) -> Bool {
        switch terminal.status {
        case .completed, .awaitingTools, .cancelled:
            return true
        case .failed:
            guard let reason = terminal.reason else { return false }
            return [.workerHandlerFailed, .outputLimitExceeded, .contextBudgetExceeded,
                .overallDeadlineExceeded, .streamInactivityTimeout].contains(reason)
        }
    }

    func cancelLocally() { finish(.failure(CancellationError())) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<AIAgentXPCTransportTerminal, Error>) {
        let callback = lock.withLock {
            () -> ((Result<AIAgentXPCTransportTerminal, Error>) -> Void)? in
            defer { completion = nil }
            return completion
        }
        callback?(result)
    }
}

private final class Phase2AIWorkerAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Bool) -> Void)?

    init(_ reply: @escaping (Bool) -> Void) {
        self.reply = reply
    }

    func send(_ accepted: Bool) {
        let callback = lock.withLock { () -> ((Bool) -> Void)? in
            defer { reply = nil }
            return reply
        }
        callback?(accepted)
    }
}

private final class Phase2AIWorkerOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

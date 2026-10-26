import Foundation

/// App-side adapter from the provider-neutral inference contract to the dedicated AI worker.
/// The actor owns request lifecycle so cancellation and late-event suppression remain exact even
/// when task cancellation races an XPC callback.
actor AIAgentXPCInferenceProvider:
    Phase2InferenceProviding,
    Phase2InferenceDispatchReceiptProviding,
    Phase2InferenceWorkerProcessReceiptProviding
{
    enum ConnectionState: Equatable, Sendable {
        case idle
        case running(UUID)
        case invalidated(String)
    }

    private let transport: any AIAgentXPCTransport
    private let codec: Phase2AIWorkerAppCodec
    private var state: ConnectionState = .idle
    private var connectionGeneration: UInt64 = 0
    private var cancelledRequestIDs: Set<UUID> = []
    private var isPreparingWorkerProcessReceipt = false
    private var preparedWorkerReceipt: Phase2InferenceWorkerProcessReceipt?
    private var providerConnectionValidator: ProviderConnectionValidator?
    private var providerDispatchValidator:
        (@MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool)?
    private var activeDispatchObserver:
        (@Sendable (Phase2InferenceDispatchReceipt) -> Void)?
    private var acceptedProviderDispatchRequestID: UUID?
    private var acceptedProviderConnection: (requestID: UUID, connectionIdentity: UUID)?
    private var isValidatingProviderConnection = false

    init(configuration: Phase2AIProviderConfiguration, codec: Phase2AIWorkerAppCodec = .init()) {
        transport = NSXPCAIAgentTransport(configuration: configuration)
        self.codec = codec
    }

    init(transport: any AIAgentXPCTransport, codec: Phase2AIWorkerAppCodec = .init()) {
        self.transport = transport
        self.codec = codec
    }

    var connectionState: ConnectionState { state }

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        try await runImpl(request: request, onDispatched: nil, emit: emit)
    }

    func run(
        request: Phase2InferenceRequest,
        onDispatched: @escaping @Sendable (Phase2InferenceDispatchReceipt) -> Void,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        try await runImpl(
            request: request,
            onDispatched: onDispatched,
            emit: emit
        )
    }

    private func runImpl(
        request: Phase2InferenceRequest,
        onDispatched: (@Sendable (Phase2InferenceDispatchReceipt) -> Void)?,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        guard !isPreparingWorkerProcessReceipt else {
            throw AIAgentXPCTransportError.unavailable(
                "AI worker process receipt preparation is in progress"
            )
        }
        switch state {
        case .idle:
            break
        case .running:
            throw AIAgentXPCTransportError.unavailable("another inference request is already in flight")
        case .invalidated(let reason):
            throw AIAgentXPCTransportError.invalidated(reason)
        }

        let payload = try codec.encodeRequest(request)
        cancelledRequestIDs.remove(request.requestID)
        state = .running(request.requestID)
        activeDispatchObserver = onDispatched
        let runGeneration = connectionGeneration

        do {
            try await withTaskCancellationHandler {
                let receive: @Sendable (Data) async throws -> Void = { [weak self] eventData in
                    guard let self else { return }
                    try await self.accept(
                        eventData: eventData,
                        request: request,
                        emit: emit
                    )
                }
                try await transport.run(
                    requestID: request.requestID,
                    requestData: payload,
                    receive: receive
                )
            } onCancel: { [weak self] in
                Task { await self?.cancel(requestID: request.requestID) }
            }
            finish(requestID: request.requestID)
        } catch let error as AIAgentXPCTransportError {
            if connectionGeneration == runGeneration,
               state == .running(request.requestID) {
                if case .invalidated(let reason) = error {
                    state = .invalidated(reason)
                } else {
                    finish(requestID: request.requestID)
                }
            }
            throw error
        } catch {
            if connectionGeneration == runGeneration {
                finish(requestID: request.requestID)
            }
            throw error
        }
    }

    func cancel(requestID: UUID) async {
        guard cancelledRequestIDs.insert(requestID).inserted else { return }
        if state == .running(requestID) {
            clearRequestScopedControlState()
            state = .idle
        }
        await transport.cancel(requestID: requestID)
    }

    /// Sticky invalidation is cleared only by an explicit app-owned recovery decision.
    func resetConnection() async {
        connectionGeneration &+= 1
        cancelledRequestIDs.removeAll(keepingCapacity: true)
        isPreparingWorkerProcessReceipt = false
        preparedWorkerReceipt = nil
        providerConnectionValidator = nil
        providerDispatchValidator = nil
        activeDispatchObserver = nil
        acceptedProviderDispatchRequestID = nil
        acceptedProviderConnection = nil
        isValidatingProviderConnection = false
        state = .idle
        await transport.reset()
    }

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt {
        guard state == .idle, !isPreparingWorkerProcessReceipt else {
            throw AIAgentXPCTransportError.unavailable(
                "AI worker is not idle for process receipt preparation"
            )
        }
        let providerGeneration = connectionGeneration
        isPreparingWorkerProcessReceipt = true
        do {
            let transportReceipt = try await transport.prepareWorkerProcessReceipt()
            guard connectionGeneration == providerGeneration,
                  state == .idle,
                  isPreparingWorkerProcessReceipt
            else {
                throw AIAgentXPCTransportError.invalidated(
                    "stale AI worker process receipt"
                )
            }
            isPreparingWorkerProcessReceipt = false
            let receipt = try Phase2InferenceWorkerProcessReceipt(
                processIdentifier: transportReceipt.processIdentifier,
                providerGeneration: providerGeneration,
                connectionIdentity: transportReceipt.connectionIdentity,
                profileID: transportReceipt.profileID,
                configurationGeneration: transportReceipt.configurationGeneration,
                protocolManifestDigest: transportReceipt.protocolManifestDigest
            )
            preparedWorkerReceipt = receipt
            return receipt
        } catch {
            if connectionGeneration == providerGeneration {
                isPreparingWorkerProcessReceipt = false
            }
            throw error
        }
    }

    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool {
        guard state == .idle,
              !isPreparingWorkerProcessReceipt,
              preparedWorkerReceipt == workerReceipt,
              providerConnectionValidator == nil,
              acceptedProviderConnection == nil,
              !isValidatingProviderConnection
        else { return false }
        providerConnectionValidator = validator
        return true
    }

    func bindProviderDispatchValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping @MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool
    ) async -> Bool {
        guard state == .idle,
              !isPreparingWorkerProcessReceipt,
              preparedWorkerReceipt == workerReceipt,
              providerDispatchValidator == nil,
              acceptedProviderDispatchRequestID == nil
        else { return false }
        providerDispatchValidator = validator
        return true
    }

    func acceptedProviderConnectionReceipt(
        requestID: UUID,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        guard state == .idle,
              !isPreparingWorkerProcessReceipt,
              !isValidatingProviderConnection,
              preparedWorkerReceipt == workerReceipt,
              let acceptedProviderConnection
        else { return false }
        return acceptedProviderConnection.requestID == requestID
            && acceptedProviderConnection.connectionIdentity
                == workerReceipt.connectionIdentity
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        let providerGeneration = connectionGeneration
        guard state == .idle,
              !isPreparingWorkerProcessReceipt,
              receipt.providerGeneration == providerGeneration
        else { return false }
        let remainsValid = await transport.revalidateWorkerProcessReceipt(
            AIAgentXPCWorkerProcessReceipt(
                processIdentifier: receipt.processIdentifier,
                connectionIdentity: receipt.connectionIdentity,
                profileID: receipt.profileID,
                configurationGeneration: receipt.configurationGeneration,
                protocolManifestDigest: receipt.protocolManifestDigest
            )
        )
        guard remainsValid,
              connectionGeneration == providerGeneration,
              receipt.providerGeneration == connectionGeneration,
              state == .idle,
              !isPreparingWorkerProcessReceipt
        else { return false }
        return true
    }

    private func accept(
        eventData: Data,
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        guard state == .running(request.requestID),
              !cancelledRequestIDs.contains(request.requestID)
        else {
            return
        }
        switch try codec.decodeWorkerEvent(eventData) {
        case .inference(let event):
            try await emit(event)
        case .providerConnection(let requestID, let phase, let receipt):
            guard requestID == request.requestID,
                  phase == request.phase,
                  acceptedProviderConnection == nil,
                  !isValidatingProviderConnection
            else { throw AIAgentXPCTransportError.malformedReply }
            guard let providerConnectionValidator, let preparedWorkerReceipt else {
                // Ordinary inference does not install Gate authority. The signed control receipt
                // is intentionally invisible to its semantic event stream.
                return
            }
            isValidatingProviderConnection = true
            let accepted = await providerConnectionValidator(receipt)
            isValidatingProviderConnection = false
            guard accepted,
                  state == .running(request.requestID),
                  !cancelledRequestIDs.contains(request.requestID)
            else { throw AIAgentXPCTransportError.malformedReply }
            acceptedProviderConnection = (
                request.requestID,
                preparedWorkerReceipt.connectionIdentity
            )
        case .providerDispatch(let requestID, let phase):
            guard requestID == request.requestID,
                  phase == request.phase,
                  acceptedProviderDispatchRequestID == nil
            else { throw AIAgentXPCTransportError.malformedReply }
            let receipt = Phase2InferenceDispatchReceipt(requestID: requestID)
            if let providerDispatchValidator {
                guard await providerDispatchValidator(receipt),
                      state == .running(request.requestID),
                      !cancelledRequestIDs.contains(request.requestID)
                else { throw AIAgentXPCTransportError.malformedReply }
            }
            acceptedProviderDispatchRequestID = requestID
            activeDispatchObserver?(receipt)
        }
    }

    private func finish(requestID: UUID) {
        guard state == .running(requestID) else { return }
        clearRequestScopedControlState()
        state = .idle
    }

    private func clearRequestScopedControlState() {
        activeDispatchObserver = nil
        // Qualification binds a fresh provider instance and retains accepted evidence for the
        // coordinator's post-run checks. Ordinary inference installs no Gate validators, so its
        // signed control receipts are request-scoped and must not poison a later request that
        // intentionally reuses this provider connection.
        if providerDispatchValidator == nil {
            acceptedProviderDispatchRequestID = nil
        }
        if providerConnectionValidator == nil {
            acceptedProviderConnection = nil
        }
    }
}

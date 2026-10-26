import Foundation

enum ReconstructionXPCInferenceProviderError: Error, Equatable, Sendable {
    case duplicateRequest
    case invalidEventSequence
    case missingCompletion
    case terminalWithoutSemanticRequestAuthority(AIAgentXPCTransportTerminal)
}

/// Qualification-only capability for binding reconstruction inference to the exact signed worker
/// process and provider connection that served its request. There is deliberately no fallback:
/// callers that require this authority must reject providers that do not conform.
protocol ReconstructionInferenceWorkerProcessReceiptProviding: Sendable {
    typealias ProviderConnectionValidator = @MainActor @Sendable (
        Phase2InferenceProviderConnectionReceipt
    ) -> Bool

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt
    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool
    func bindProviderDispatchValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping @MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool
    ) async -> Bool
    func acceptedProviderConnectionReceipt(
        requestID: UUID,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool
    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool
}

actor ReconstructionXPCInferenceProvider:
    ReconstructionInferenceWorkerProcessReceiptProviding, ReconstructionReplayAttestationProviding
{
    static let protocolBundle = Phase2AIWorkerProductionProtocol.reconstructionR1

    private let selectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle
    private let transport: any AIAgentXPCTerminalPreservingTransport
    private let codec = ReconstructionAIWorkerAppCodec()
    private let controlCodec = Phase2AIWorkerAppCodec()
    private var activeRequestIDs: Set<UUID> = []
    private var cancellationSent: Set<UUID> = []
    private var isPreparingWorkerProcessReceipt = false
    private var preparedWorkerReceipt: Phase2InferenceWorkerProcessReceipt?
    private var providerConnectionValidator: ProviderConnectionValidator?
    private var providerDispatchValidator:
        (@MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool)?
    private var acceptedProviderConnection: (requestID: UUID, connectionIdentity: UUID)?
    private var historicalConnectionReceipt: Phase2InferenceProviderConnectionReceipt?
    private var acceptedProviderDispatchRequestID: UUID?
    private var isValidatingProviderConnection = false

    init(transport: any AIAgentXPCTerminalPreservingTransport,
         protocolBundle: Phase2AIWorkerProductionProtocolBundle = Phase2AIWorkerProductionProtocol.reconstructionR1) {
        self.transport = transport
        self.selectedProtocolBundle = protocolBundle
    }

    init(configuration: Phase2AIProviderConfiguration,
         protocolBundle: Phase2AIWorkerProductionProtocolBundle = Phase2AIWorkerProductionProtocol.reconstructionR2) {
        self.selectedProtocolBundle = protocolBundle
        self.transport = NSXPCAIAgentTransport(
            configuration: configuration,
            protocolBundle: protocolBundle
        )
    }

    func runRound(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await run(
            requestID: requestID,
            request: .round(request),
            authority: .round(request),
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            emit: emit
        )
    }

    func runFinalSynthesis(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await run(
            requestID: requestID,
            request: .finalSynthesis(request),
            authority: .finalSynthesis(request),
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: nil,
            emit: emit
        )
    }

    func runSourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await run(requestID: requestID, request: .sourceRevision(request), authority: .sourceRevision(request),
            jobID: request.jobID, checkpointRevision: request.checkpointRevision, roundID: request.roundID, emit: emit)
    }

    func runRoundR2(
        requestID: UUID, request: ReconstructionInferenceRoundRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await run(requestID: requestID, request: .roundR2(request),
            authority: .roundR2(request), jobID: request.request.jobID,
            checkpointRevision: request.request.checkpointRevision,
            roundID: request.request.roundID, emit: emit)
    }

    func runFinalSynthesisR2(
        requestID: UUID, request: ReconstructionFinalSynthesisRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await run(requestID: requestID, request: .finalSynthesisR2(request),
            authority: .finalSynthesisR2(request), jobID: request.request.jobID,
            checkpointRevision: request.request.checkpointRevision,
            roundID: nil, emit: emit)
    }

    func cancel(requestID: UUID) async {
        guard activeRequestIDs.contains(requestID),
              cancellationSent.insert(requestID).inserted
        else { return }
        await transport.cancel(requestID: requestID)
    }

    func finishRequest() async {
        guard activeRequestIDs.isEmpty else { return }
        await transport.reset()
        preparedWorkerReceipt = nil
        providerConnectionValidator = nil
        providerDispatchValidator = nil
        acceptedProviderConnection = nil
        historicalConnectionReceipt = nil
        acceptedProviderDispatchRequestID = nil
    }

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt {
        guard activeRequestIDs.isEmpty,
              !isPreparingWorkerProcessReceipt,
              preparedWorkerReceipt == nil
        else {
            throw AIAgentXPCTransportError.unavailable(
                "reconstruction worker is not idle for process receipt preparation"
            )
        }
        isPreparingWorkerProcessReceipt = true
        do {
            let transportReceipt = try await transport.prepareWorkerProcessReceipt()
            guard activeRequestIDs.isEmpty, isPreparingWorkerProcessReceipt else {
                throw AIAgentXPCTransportError.invalidated(
                    "stale reconstruction worker process receipt"
                )
            }
            guard transportReceipt.protocolManifestDigest == selectedProtocolBundle.manifestDigest
            else { throw AIAgentXPCTransportError.protocolMismatch }
            let receipt = try Phase2InferenceWorkerProcessReceipt(
                processIdentifier: transportReceipt.processIdentifier,
                providerGeneration: 0,
                connectionIdentity: transportReceipt.connectionIdentity,
                profileID: transportReceipt.profileID,
                configurationGeneration: transportReceipt.configurationGeneration,
                protocolManifestDigest: transportReceipt.protocolManifestDigest
            )
            isPreparingWorkerProcessReceipt = false
            preparedWorkerReceipt = receipt
            return receipt
        } catch {
            isPreparingWorkerProcessReceipt = false
            throw error
        }
    }

    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool {
        guard activeRequestIDs.isEmpty,
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
        guard activeRequestIDs.isEmpty,
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
        guard activeRequestIDs.isEmpty,
              !isPreparingWorkerProcessReceipt,
              !isValidatingProviderConnection,
              preparedWorkerReceipt == workerReceipt,
              acceptedProviderDispatchRequestID == requestID,
              let acceptedProviderConnection
        else { return false }
        return acceptedProviderConnection.requestID == requestID
            && acceptedProviderConnection.connectionIdentity
                == workerReceipt.connectionIdentity
    }

    func replayAttestation(requestID: UUID) async throws -> ReconstructionReplayAttestation {
        guard let worker = preparedWorkerReceipt else { return .notRequired }
        guard await acceptedProviderConnectionReceipt(requestID: requestID, workerReceipt: worker),
              let connection = historicalConnectionReceipt else {
            throw ReconstructionReplayError.missingOriginalAttestation
        }
        return .init(worker: .init(worker), connection: .init(connection),
            dispatchRequestID: acceptedProviderDispatchRequestID, connectionWasAttested: true)
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        guard activeRequestIDs.isEmpty,
              !isPreparingWorkerProcessReceipt,
              !isValidatingProviderConnection,
              preparedWorkerReceipt == receipt,
              receipt.providerGeneration == 0,
              receipt.protocolManifestDigest == selectedProtocolBundle.manifestDigest
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
        return remainsValid
            && activeRequestIDs.isEmpty
            && !isPreparingWorkerProcessReceipt
            && !isValidatingProviderConnection
            && preparedWorkerReceipt == receipt
    }

    private func run(
        requestID: UUID,
        request: ReconstructionAIWorkerRequest,
        authority: ReconstructionAIWorkerAuthority,
        jobID: UUID,
        checkpointRevision: UInt64,
        roundID: UUID?,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        guard !isPreparingWorkerProcessReceipt,
              (preparedWorkerReceipt == nil
                  && providerConnectionValidator == nil
                  && providerDispatchValidator == nil
                || preparedWorkerReceipt != nil
                  && providerConnectionValidator != nil
                  && providerDispatchValidator != nil),
              acceptedProviderConnection == nil,
              acceptedProviderDispatchRequestID == nil
        else {
            throw AIAgentXPCTransportError.unavailable(
                "incomplete or stale reconstruction worker authority"
            )
        }
        guard (try request.protocolBundle) == selectedProtocolBundle else {
            throw AIAgentXPCTransportError.protocolMismatch
        }
        guard activeRequestIDs.insert(requestID).inserted else {
            throw ReconstructionXPCInferenceProviderError.duplicateRequest
        }
        cancellationSent.remove(requestID)
        let state = ReconstructionXPCInferenceRunState(requestID: requestID)
        defer {
            activeRequestIDs.remove(requestID)
            cancellationSent.remove(requestID)
        }
        let requestData = try codec.encode(request, requestID: requestID)

        do {
            let terminal = try await withTaskCancellationHandler {
                try await transport.runPreservingTerminal(
                    requestID: requestID,
                    requestData: requestData,
                    expectedProtocolBundle: selectedProtocolBundle,
                    expectedPhase: .finalization
                ) {
                    data in
                    try await self.accept(
                        eventData: data,
                        authority: authority,
                        state: state,
                        requestID: requestID,
                        emit: emit
                    )
                }
            } onCancel: {
                Task { await self.cancel(requestID: requestID) }
            }
            guard terminal.requestID == requestID else {
                throw AIAgentXPCTransportError.malformedReply
            }
            guard terminal.semanticRequestAccepted else {
                throw ReconstructionXPCInferenceProviderError
                    .terminalWithoutSemanticRequestAuthority(terminal)
            }
            let status: ReconstructionTerminalStatus
            switch terminal.status {
            case .completed:
                guard await state.completed else {
                    throw ReconstructionXPCInferenceProviderError.missingCompletion
                }
                status = .completed
            case .cancelled:
                status = .cancelled
            case .failed:
                status = .failed
            case .awaitingTools:
                throw ReconstructionXPCInferenceProviderError.missingCompletion
            }
            return .init(
                requestID: requestID,
                jobID: jobID,
                checkpointRevision: checkpointRevision,
                roundID: roundID,
                status: status,
                providerFailureReason: terminal.reason
            )
        } catch is CancellationError {
            await cancel(requestID: requestID)
            throw CancellationError()
        }
    }

    private func accept(
        eventData: Data,
        authority: ReconstructionAIWorkerAuthority,
        state: ReconstructionXPCInferenceRunState,
        requestID: UUID,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws {
        if let control = try? controlCodec.decodeWorkerEvent(eventData) {
            try await acceptControlEvent(control, requestID: requestID)
            return
        }
        if providerDispatchValidator != nil,
           acceptedProviderDispatchRequestID != requestID
        {
            throw AIAgentXPCTransportError.malformedReply
        }
        let event = try codec.decodeEvent(eventData, authority: authority)
        try await state.accept(event)
        try await emit(event)
    }

    private func acceptControlEvent(
        _ event: Phase2AIWorkerAppDecodedEvent,
        requestID: UUID
    ) async throws {
        guard activeRequestIDs.contains(requestID),
              !cancellationSent.contains(requestID)
        else { throw AIAgentXPCTransportError.malformedReply }
        switch event {
        case .inference:
            throw AIAgentXPCTransportError.malformedReply
        case .providerConnection(let eventRequestID, let phase, let receipt):
            guard eventRequestID == requestID, phase == .finalization else {
                throw AIAgentXPCTransportError.malformedReply
            }
            guard providerConnectionValidator != nil else {
                // Provider controls are transport metadata, not reconstruction semantics.
                // Ordinary production runs consume a well-formed envelope without exposing
                // it to the semantic event stream. Qualification runs continue below and
                // bind the exact receipt to the prepared worker process.
                return
            }
            guard
                  acceptedProviderConnection == nil,
                  !isValidatingProviderConnection,
                  let providerConnectionValidator,
                  let preparedWorkerReceipt
            else { throw AIAgentXPCTransportError.malformedReply }
            isValidatingProviderConnection = true
            let accepted = await providerConnectionValidator(receipt)
            isValidatingProviderConnection = false
            guard accepted,
                  activeRequestIDs.contains(requestID),
                  !cancellationSent.contains(requestID)
            else { throw AIAgentXPCTransportError.malformedReply }
            historicalConnectionReceipt = receipt
            acceptedProviderConnection = (
                requestID,
                preparedWorkerReceipt.connectionIdentity
            )
        case .providerDispatch(let eventRequestID, let phase):
            guard eventRequestID == requestID, phase == .finalization else {
                throw AIAgentXPCTransportError.malformedReply
            }
            guard providerDispatchValidator != nil else {
                // See providerConnection above: ordinary mode consumes control metadata;
                // qualification mode retains its exact validator and acceptance checks.
                return
            }
            guard
                  acceptedProviderDispatchRequestID == nil,
                  let providerDispatchValidator
            else { throw AIAgentXPCTransportError.malformedReply }
            let receipt = Phase2InferenceDispatchReceipt(requestID: requestID)
            guard await providerDispatchValidator(receipt),
                  activeRequestIDs.contains(requestID),
                  !cancellationSent.contains(requestID)
            else { throw AIAgentXPCTransportError.malformedReply }
            acceptedProviderDispatchRequestID = requestID
        }
    }
}

private actor ReconstructionXPCInferenceRunState {
    let requestID: UUID
    private var nextSequence: UInt64 = 1
    private(set) var completed = false

    init(requestID: UUID) { self.requestID = requestID }

    func accept(_ event: ReconstructionAIWorkerEvent) throws {
        guard !completed,
              event.requestID == requestID,
              event.sequence == nextSequence
        else { throw ReconstructionXPCInferenceProviderError.invalidEventSequence }
        nextSequence += 1
        if case .completed = event.body { completed = true }
    }
}

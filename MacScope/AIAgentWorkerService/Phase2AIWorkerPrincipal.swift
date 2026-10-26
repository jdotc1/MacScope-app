import Foundation
import OSLog
import XPC
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

/// An incoming XPC message's automatic transaction ends when its handler returns. Inference
/// continues asynchronously, so each admitted request owns a balanced manual transaction.
final class Phase2InferenceXPCActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var end: (@Sendable () -> Void)?

    init(begin: @Sendable () -> Void, end: @escaping @Sendable () -> Void) {
        self.end = end
        begin()
    }

    func finish() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { end = nil }
            return end
        }
        action?()
    }

    deinit { finish() }
}

/// Exported object for one AI-worker XPC connection.
///
/// The principal owns request-local delivery state. It serializes event delivery through the
/// sink's acknowledgement callback, reserves a terminal outcome exactly once, and suppresses all
/// traffic after cancellation or termination.
final class Phase2AIWorkerPrincipal: NSObject, Phase2AIWorkerXPCProtocol, @unchecked Sendable {
    private static let failureLogger = Logger(subsystem: "org.macscope.MacScope", category: "AIWorker")
    private enum ConnectionRole: Equatable {
        case unassigned
        case inference
        case discovery
        case lifecycle
    }

    private struct RequestState {
        let sink: Phase2AIWorkerEventSinkXPCProtocol
        let phase: Phase2AIWorkerWirePhase?
        let protocolBundle: Phase2AIWorkerProductionProtocolBundle
        let activity: Phase2InferenceXPCActivity
        var task: Task<Void, Never>?
        var acknowledgement: Phase2WorkerAcknowledgementOneShot?
    }

    private struct ModelDiscoveryState {
        let request: Phase2AIWorkerModelDiscoveryRequest
        let reply: (Data) -> Void
        var task: Task<Void, Never>?
    }

    private enum ModelLifecycleDispatchState: Equatable {
        case reserved
        case mayHaveDispatched
    }

    private struct ModelLifecycleState {
        let request: Phase2AIWorkerModelLifecycleRequest
        let reply: (Data) -> Void
        var dispatchState: ModelLifecycleDispatchState
        var task: Task<Void, Never>?
    }

    private let codec: Phase2AIWorkerWireCodec
    private let configurationCodec: Phase2AIWorkerConfigurationWireCodec
    private let handler: any Phase2AIWorkerHandling
    private let reconstructionHandler: Phase2ReconstructionAIWorkerHandler
    private let reconstructionCodec: Phase2ReconstructionAIWorkerWireCodec
    private let modelDiscoveryHandler: any Phase2AIWorkerModelDiscoveryHandling
    private let modelLifecycleHandler: any Phase2AIWorkerModelLifecycleHandling
    private let beginInferenceActivity: @Sendable () -> Void
    private let endInferenceActivity: @Sendable () -> Void
    private let lock = NSLock()
    private var requests: [UUID: RequestState] = [:]
    private var modelDiscoveries: [UUID: ModelDiscoveryState] = [:]
    private var modelLifecycles: [UUID: ModelLifecycleState] = [:]
    private var configuration: Phase2AIWorkerConfigurationWire?
    private var selectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle?
    private var connectionRole: ConnectionRole = .unassigned
    private var isConnectionInvalidated = false

    init(
        codec: Phase2AIWorkerWireCodec = Phase2AIWorkerWireCodec(),
        configurationCodec: Phase2AIWorkerConfigurationWireCodec = .init(),
        handler: any Phase2AIWorkerHandling = Phase2LiveInferenceHandler(),
        reconstructionHandler: Phase2ReconstructionAIWorkerHandler = .init(),
        reconstructionCodec: Phase2ReconstructionAIWorkerWireCodec = .init(),
        modelDiscoveryHandler: any Phase2AIWorkerModelDiscoveryHandling =
            Phase2LiveModelDiscoveryHandler(),
        modelLifecycleHandler: any Phase2AIWorkerModelLifecycleHandling =
            Phase2LiveModelLifecycleHandler(),
        beginInferenceActivity: @escaping @Sendable () -> Void = { xpc_transaction_begin() },
        endInferenceActivity: @escaping @Sendable () -> Void = { xpc_transaction_end() }
    ) {
        self.codec = codec
        self.configurationCodec = configurationCodec
        self.handler = handler
        self.reconstructionHandler = reconstructionHandler
        self.reconstructionCodec = reconstructionCodec
        self.modelDiscoveryHandler = modelDiscoveryHandler
        self.modelLifecycleHandler = modelLifecycleHandler
        self.beginInferenceActivity = beginInferenceActivity
        self.endInferenceActivity = endInferenceActivity
        super.init()
    }

    deinit { cancelAllForConnectionInvalidation() }

    func handshake(with reply: @escaping (Data) -> Void) {
        handshake(
            selecting: Phase2AIWorkerProductionProtocol.assistantR4,
            reply: reply
        )
    }

    func handshake(
        protocolManifestIdentity: String,
        with reply: @escaping (Data) -> Void
    ) {
        guard let bundle = Self.bundle(manifestIdentity: protocolManifestIdentity) else {
            reply(Data())
            return
        }
        handshake(selecting: bundle, reply: reply)
    }

    private func handshake(
        selecting bundle: Phase2AIWorkerProductionProtocolBundle,
        reply: @escaping (Data) -> Void
    ) {
        guard lock.withLock({ !isConnectionInvalidated }) else {
            reply(Data())
            return
        }
        let selected = lock.withLock { () -> Bool in
            guard !isConnectionInvalidated else { return false }
            if let selectedProtocolBundle { return selectedProtocolBundle == bundle }
            selectedProtocolBundle = bundle
            return true
        }
        guard selected else { reply(Data()); return }
        let handshake = Phase2AIWorkerHandshake(
            wireProtocol: bundle.wireIdentity,
            inferenceProtocol: bundle.inferenceIdentity,
            manifestIdentity: bundle.manifestIdentity,
            status: .ready
        )
        reply((try? codec.encodeHandshake(handshake)) ?? Data())
    }

    func configure(configurationData: Data, with reply: @escaping (Data) -> Void) {
        guard let candidate = try? configurationCodec.decodeConfiguration(configurationData) else {
            reply(Data())
            return
        }
        let accepted = lock.withLock { () -> Bool in
            guard !isConnectionInvalidated else { return false }
            // Legacy nil-policy wires decode for compatibility but never grant
            // production provider authority or silently become MTPLX.
            guard candidate.inferencePolicy?.isValid == true else { return false }
            guard let candidateBundle = Self.bundle(manifestDigest: candidate.protocolManifestDigest)
            else { return false }
            if let selectedProtocolBundle {
                guard selectedProtocolBundle == candidateBundle else { return false }
            } else {
                selectedProtocolBundle = candidateBundle
            }
            switch connectionRole {
            case .unassigned:
                connectionRole = .inference
                configuration = candidate
                return true
            case .inference:
                return configuration == candidate
            case .discovery, .lifecycle:
                return false
            }
        }
        let acknowledgement = Phase2AIWorkerConfigurationAcknowledgement(
            schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
            profileID: candidate.profileID,
            generation: candidate.generation,
            protocolManifestDigest: candidate.protocolManifestDigest,
            status: accepted ? .accepted : .rejected
        )
        reply((try? configurationCodec.encodeAcknowledgement(acknowledgement)) ?? Data())
    }

    func discoverModels(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        let claimed = lock.withLock { () -> Bool in
            guard !isConnectionInvalidated, connectionRole == .unassigned else { return false }
            connectionRole = .discovery
            return true
        }
        guard claimed else {
            reply(Data())
            return
        }

        let request: Phase2AIWorkerModelDiscoveryRequest
        do {
            request = try Phase2AIWorkerModelDiscoveryWireCodec().decodeRequest(requestData)
            guard request.requestID == requestID else {
                reply(Data())
                return
            }
        } catch {
            reply(Data())
            return
        }

        guard request.inferencePolicy?.isValid == true else {
            let rejected = Phase2AIWorkerModelDiscoveryReply(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: request.requestID, profileID: request.profileID,
                generation: request.generation, status: .incompatible, inventory: nil
            )
            reply((try? Phase2AIWorkerModelDiscoveryWireCodec().encodeReply(rejected)) ?? Data())
            return
        }

        let registered = lock.withLock { () -> Bool in
            guard !isConnectionInvalidated, connectionRole == .discovery else { return false }
            guard modelDiscoveries[requestID] == nil else { return false }
            modelDiscoveries[requestID] = .init(request: request, reply: reply, task: nil)
            return true
        }
        guard registered else {
            reply(Data())
            return
        }

        let task = Task { [weak self, modelDiscoveryHandler] in
            guard let self else { return }
            let result = await modelDiscoveryHandler.discoverModels(request: request)
            self.finishModelDiscovery(requestID: requestID, result: result)
        }
        let installed = lock.withLock { () -> Bool in
            guard var state = modelDiscoveries[requestID] else { return false }
            state.task = task
            modelDiscoveries[requestID] = state
            return true
        }
        if !installed { task.cancel() }
    }

    func cancelModelDiscovery(requestID: UUID) {
        guard let state = lock.withLock({ modelDiscoveries.removeValue(forKey: requestID) }) else {
            return
        }
        state.task?.cancel()
        let cancelled = Phase2AIWorkerModelDiscoveryReply(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: state.request.requestID,
            profileID: state.request.profileID,
            generation: state.request.generation,
            status: .cancelled,
            inventory: nil
        )
        state.reply((try? Phase2AIWorkerModelDiscoveryWireCodec().encodeReply(cancelled)) ?? Data())
    }

    func performModelLifecycle(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        // Claim the one-shot role before decoding. Invalid input must not leave a reusable
        // connection that can subsequently acquire inference or discovery authority.
        let claimed = lock.withLock { () -> Bool in
            guard !isConnectionInvalidated, connectionRole == .unassigned else { return false }
            connectionRole = .lifecycle
            return true
        }
        guard claimed else {
            reply(Data())
            return
        }

        let request: Phase2AIWorkerModelLifecycleRequest
        do {
            request = try Phase2AIWorkerModelLifecycleWireCodec().decodeRequest(requestData)
            guard request.effectID == requestID else {
                reply(Data())
                return
            }
        } catch {
            reply(Data())
            return
        }

        let registered = lock.withLock { () -> Bool in
            guard !isConnectionInvalidated,
                  connectionRole == .lifecycle,
                  modelLifecycles.isEmpty
            else { return false }
            modelLifecycles[requestID] = .init(
                request: request,
                reply: reply,
                dispatchState: .reserved,
                task: nil
            )
            return true
        }
        guard registered else {
            reply(Data())
            return
        }

        let task = Task { [weak self, modelLifecycleHandler] in
            guard let self else { return }
            let result = await modelLifecycleHandler.performModelLifecycle(
                request: request,
                reserveDispatch: { [weak self] in
                    self?.reserveModelLifecycleDispatch(requestID: requestID) ?? false
                }
            )
            self.finishModelLifecycle(requestID: requestID, result: result)
        }
        let installed = lock.withLock { () -> Bool in
            guard var state = modelLifecycles[requestID] else { return false }
            state.task = task
            modelLifecycles[requestID] = state
            return true
        }
        if !installed { task.cancel() }
    }

    func cancelModelLifecycle(requestID: UUID) {
        finishModelLifecycleForCancellation(requestID: requestID)
    }

    func run(
        requestData: Data,
        requestID: UUID,
        eventSink: Phase2AIWorkerEventSinkXPCProtocol
    ) {
        let connectionState = lock.withLock { () -> (
            Phase2AIWorkerConfigurationWire?, Phase2AIWorkerProductionProtocolBundle
        ) in
            (
                isConnectionInvalidated ? nil : configuration,
                selectedProtocolBundle ?? Phase2AIWorkerProductionProtocol.assistantR4
            )
        }
        guard let configuration = connectionState.0 else {
            sendTerminalDirect(
                requestID: requestID,
                protocolBundle: connectionState.1,
                status: .failed,
                reason: .workerNotConfigured,
                sink: eventSink
            )
            return
        }
        if configuration.protocolManifestDigest
            == Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
            || configuration.protocolManifestDigest
                == Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest
            || configuration.protocolManifestDigest == Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest
        {
            runReconstruction(
                requestData: requestData,
                requestID: requestID,
                eventSink: eventSink,
                configuration: configuration
            )
            return
        }
        let request: Phase2AIWorkerWireRequest

        do {
            request = try codec.decodeRequest(requestData)
            guard request.requestID == requestID else {
                sendTerminalDirect(
                    requestID: requestID,
                    status: .failed,
                    reason: .requestIdentityMismatch,
                    sink: eventSink
                )
                return
            }
            guard register(
                requestID: requestID,
                phase: request.phase,
                protocolBundle: Self.bundle(manifestDigest: configuration.protocolManifestDigest)!,
                sink: eventSink
            ) else {
                sendTerminalDirect(
                    requestID: requestID,
                    status: .failed,
                    reason: .duplicateRequest,
                    sink: eventSink
                )
                return
            }
        } catch {
            sendTerminalDirect(
                requestID: requestID,
                status: .failed,
                reason: .invalidRequest,
                sink: eventSink
            )
            return
        }

        let task = Task { [weak self, handler] in
            guard let self else { return }
            do {
                try await handler.run(
                    request: request,
                    configuration: configuration
                ) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.send(event, requestID: requestID, sink: eventSink)
                }
                self.finish(
                    requestID: requestID,
                    status: request.phase == .toolSelection ? .awaitingTools : .completed,
                    reason: nil
                )
            } catch is CancellationError {
                self.finish(requestID: requestID, status: .cancelled, reason: nil)
            } catch Phase2OpenAIChatHTTPClientError.totalDeadlineExceeded {
                self.finish(requestID: requestID, status: .failed, reason: .overallDeadlineExceeded)
            } catch Phase2OpenAIChatHTTPClientError.inactivityTimeout {
                self.finish(requestID: requestID, status: .failed, reason: .streamInactivityTimeout)
            } catch Phase2OpenAIChatHTTPClientError.outputLimitExceeded {
                self.finish(requestID: requestID, status: .failed, reason: .outputLimitExceeded)
            } catch Phase2OpenAIChatRequestEncodingError.contextBudgetExceeded {
                self.finish(requestID: requestID, status: .failed, reason: .contextBudgetExceeded)
            } catch {
                Self.failureLogger.error("MacScopeAIWorker failure category=\(Self.failureDiagnosticCategory(error), privacy: .public)")
                self.finish(requestID: requestID, status: .failed, reason: .workerHandlerFailed)
            }
        }
        let installed = lock.withLock { () -> Bool in
            guard var state = requests[requestID] else { return false }
            state.task = task
            requests[requestID] = state
            return true
        }
        if !installed { task.cancel() }
    }

    func cancel(requestID: UUID) {
        let state = lock.withLock {
            requests.removeValue(forKey: requestID)
        }
        guard let state else { return }
        defer { state.activity.finish() }
        state.acknowledgement?.resume(.failure(CancellationError()))
        state.task?.cancel()
        sendTerminalDirect(
            requestID: requestID,
            phase: state.phase,
            protocolBundle: state.protocolBundle,
            status: .cancelled,
            reason: nil,
            sink: state.sink
        )
    }

    private func register(
        requestID: UUID,
        phase: Phase2AIWorkerWirePhase?,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle,
        sink: Phase2AIWorkerEventSinkXPCProtocol
    ) -> Bool {
        lock.withLock {
            guard !isConnectionInvalidated else { return false }
            guard requests[requestID] == nil else { return false }
            requests[requestID] = RequestState(
                sink: sink,
                phase: phase,
                protocolBundle: protocolBundle,
                activity: Phase2InferenceXPCActivity(begin: beginInferenceActivity,
                    end: endInferenceActivity),
                task: nil,
                acknowledgement: nil
            )
            return true
        }
    }

    private func send(
        _ event: Phase2AIWorkerWireEvent,
        requestID: UUID,
        sink: Phase2AIWorkerEventSinkXPCProtocol
    ) async throws {
        try Task.checkCancellation()
        guard isActive(requestID: requestID) else { throw CancellationError() }
        let eventData: Data
        do {
            eventData = try codec.encodeEvent(event)
        } catch {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Phase2WorkerAcknowledgementOneShot(continuation)
            let registered = lock.withLock { () -> Bool in
                guard var state = requests[requestID] else { return false }
                state.acknowledgement = once
                requests[requestID] = state
                return true
            }
            guard registered else {
                once.resume(.failure(CancellationError()))
                return
            }
            sink.receive(eventData: eventData) { [weak self] accepted in
                guard let self else {
                    once.resume(.failure(CancellationError()))
                    return
                }
                self.lock.withLock {
                    guard var state = self.requests[requestID],
                          state.acknowledgement === once else { return }
                    state.acknowledgement = nil
                    self.requests[requestID] = state
                }
                once.resume(accepted ? .success(()) : .failure(CancellationError()))
            }
        }
    }

    private func sendReconstruction(
        _ event: ReconstructionAIWorkerEvent,
        authority: ReconstructionAIWorkerAuthority,
        requestID: UUID,
        sink: Phase2AIWorkerEventSinkXPCProtocol
    ) async throws {
        let eventData = try reconstructionCodec.encodeEvent(event, authority: authority)
        try await sendEncoded(eventData, requestID: requestID, sink: sink)
    }

    private func sendEncoded(
        _ eventData: Data,
        requestID: UUID,
        sink: Phase2AIWorkerEventSinkXPCProtocol
    ) async throws {
        try Task.checkCancellation()
        guard isActive(requestID: requestID) else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Phase2WorkerAcknowledgementOneShot(continuation)
            let registered = lock.withLock { () -> Bool in
                guard var state = requests[requestID] else { return false }
                state.acknowledgement = once
                requests[requestID] = state
                return true
            }
            guard registered else {
                once.resume(.failure(CancellationError()))
                return
            }
            sink.receive(eventData: eventData) { [weak self] accepted in
                guard let self else {
                    once.resume(.failure(CancellationError()))
                    return
                }
                self.lock.withLock {
                    guard var state = self.requests[requestID],
                          state.acknowledgement === once else { return }
                    state.acknowledgement = nil
                    self.requests[requestID] = state
                }
                once.resume(accepted ? .success(()) : .failure(CancellationError()))
            }
        }
    }

    func cancelAllForConnectionInvalidation() {
        let (states, discoveries, lifecycles) = lock.withLock { () -> (
            [RequestState], [ModelDiscoveryState], [ModelLifecycleState]
        ) in
            isConnectionInvalidated = true
            defer {
                requests.removeAll()
                modelDiscoveries.removeAll()
                modelLifecycles.removeAll()
            }
            return (
                Array(requests.values),
                Array(modelDiscoveries.values),
                Array(modelLifecycles.values)
            )
        }
        for state in states {
            state.acknowledgement?.resume(.failure(CancellationError()))
            state.task?.cancel()
            state.activity.finish()
        }
        for discovery in discoveries { discovery.task?.cancel() }
        for lifecycle in lifecycles {
            lifecycle.task?.cancel()
            deliverModelLifecycleTerminal(
                for: lifecycle,
                status: lifecycle.dispatchState == .reserved
                    ? .cancelledBeforeDispatch
                    : .reconciliationRequired
            )
        }
    }

    private func finishModelDiscovery(
        requestID: UUID,
        result: Phase2AIWorkerModelDiscoveryReply
    ) {
        guard let state = lock.withLock({ modelDiscoveries.removeValue(forKey: requestID) }) else {
            return
        }
        guard result.requestID == state.request.requestID,
              result.profileID == state.request.profileID,
              result.generation == state.request.generation
        else {
            state.reply(Data())
            return
        }
        state.reply((try? Phase2AIWorkerModelDiscoveryWireCodec().encodeReply(result)) ?? Data())
    }

    private func reserveModelLifecycleDispatch(requestID: UUID) -> Bool {
        lock.withLock {
            guard !isConnectionInvalidated,
                  var state = modelLifecycles[requestID],
                  state.dispatchState == .reserved
            else { return false }
            state.dispatchState = .mayHaveDispatched
            modelLifecycles[requestID] = state
            return true
        }
    }

    private func finishModelLifecycleForCancellation(requestID: UUID) {
        guard let state = lock.withLock({ modelLifecycles.removeValue(forKey: requestID) }) else {
            return
        }
        state.task?.cancel()
        deliverModelLifecycleTerminal(
            for: state,
            status: state.dispatchState == .reserved
                ? .cancelledBeforeDispatch
                : .reconciliationRequired
        )
    }

    private func finishModelLifecycle(
        requestID: UUID,
        result: Phase2AIWorkerModelLifecycleReply
    ) {
        guard let state = lock.withLock({ modelLifecycles.removeValue(forKey: requestID) }) else {
            return
        }

        let exactIdentity = result.effectID == state.request.effectID
            && result.profileID == state.request.profileID
            && result.generation == state.request.generation
            && result.operationKind == modelLifecycleOperationKind(for: state.request)
        let statusIsCompatibleWithDispatch: Bool
        switch state.dispatchState {
        case .reserved:
            switch result.status {
            case .unavailableBeforeDispatch, .incompatibleBeforeDispatch,
                 .cancelledBeforeDispatch:
                statusIsCompatibleWithDispatch = true
            case .succeeded, .authenticationRequired, .rejected, .reconciliationRequired:
                statusIsCompatibleWithDispatch = false
            }
        case .mayHaveDispatched:
            switch result.status {
            case .succeeded, .authenticationRequired, .rejected, .reconciliationRequired:
                statusIsCompatibleWithDispatch = true
            case .unavailableBeforeDispatch, .incompatibleBeforeDispatch,
                 .cancelledBeforeDispatch:
                statusIsCompatibleWithDispatch = false
            }
        }

        if exactIdentity,
           statusIsCompatibleWithDispatch,
           let encoded = try? Phase2AIWorkerModelLifecycleWireCodec().encodeReply(result)
        {
            state.reply(encoded)
            return
        }

        deliverModelLifecycleTerminal(
            for: state,
            status: state.dispatchState == .reserved
                ? .incompatibleBeforeDispatch
                : .reconciliationRequired
        )
    }

    private func deliverModelLifecycleTerminal(
        for state: ModelLifecycleState,
        status: Phase2AIWorkerModelLifecycleReply.Status
    ) {
        let terminal = Phase2AIWorkerModelLifecycleReply(
            schemaVersion: Phase2AIWorkerModelLifecycleWireCodec.schemaVersion,
            effectID: state.request.effectID,
            profileID: state.request.profileID,
            generation: state.request.generation,
            operationKind: modelLifecycleOperationKind(for: state.request),
            status: status,
            receipt: nil
        )
        state.reply(
            (try? Phase2AIWorkerModelLifecycleWireCodec().encodeReply(terminal)) ?? Data()
        )
    }

    private func modelLifecycleOperationKind(
        for request: Phase2AIWorkerModelLifecycleRequest
    ) -> Phase2AIWorkerModelLifecycleOperationKindWire {
        switch request.operation {
        case .load:
            return .load
        case .unload:
            return .unload
        }
    }

    private func isActive(requestID: UUID) -> Bool {
        lock.withLock { requests[requestID] != nil }
    }

    private func finish(
        requestID: UUID,
        status: Phase2AIWorkerTerminal.Status,
        reason: Phase2AIWorkerTerminal.Reason?
    ) {
        let state = lock.withLock {
            requests.removeValue(forKey: requestID)
        }
        guard let state else { return }
        defer { state.activity.finish() }
        sendTerminalDirect(
            requestID: requestID,
            phase: state.phase,
            protocolBundle: state.protocolBundle,
            status: status,
            reason: reason,
            sink: state.sink
        )
    }

    private func sendTerminalDirect(
        requestID: UUID,
        phase: Phase2AIWorkerWirePhase? = nil,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            Phase2AIWorkerProductionProtocol.assistantR4,
        status: Phase2AIWorkerTerminal.Status,
        reason: Phase2AIWorkerTerminal.Reason?,
        sink: Phase2AIWorkerEventSinkXPCProtocol
    ) {
        let terminal = Phase2AIWorkerTerminal(
            wireProtocol: protocolBundle.wireIdentity,
            protocolVersion: protocolBundle.inferenceVersion,
            phase: phase,
            requestID: requestID,
            status: status,
            reason: reason
        )
        sink.finish(resultData: (try? codec.encodeTerminal(terminal)) ?? Data())
    }

    private func runReconstruction(
        requestData: Data,
        requestID: UUID,
        eventSink: Phase2AIWorkerEventSinkXPCProtocol,
        configuration: Phase2AIWorkerConfigurationWire
    ) {
        let semantic: ReconstructionAIWorkerRequest
        let authority: ReconstructionAIWorkerAuthority
        do {
            switch try reconstructionCodec.decodeRequest(requestData) {
            case .sourceRevision(let decodedID, let request):
                guard decodedID == requestID else { throw ReconstructionAIWorkerWireError.invalidAuthority }
                semantic = .sourceRevision(request)
                authority = .sourceRevision(request)
            case .roundR2(let decodedID, let request):
                guard decodedID == requestID else { throw ReconstructionAIWorkerWireError.invalidAuthority }
                semantic = .roundR2(request)
                authority = .roundR2(request)
            case .finalSynthesisR2(let decodedID, let request):
                guard decodedID == requestID else { throw ReconstructionAIWorkerWireError.invalidAuthority }
                semantic = .finalSynthesisR2(request)
                authority = .finalSynthesisR2(request)
            case .round(let decodedID, let request):
                guard decodedID == requestID else { throw ReconstructionAIWorkerWireError.invalidAuthority }
                semantic = .round(request)
                authority = .round(request)
            case .finalSynthesis(let decodedID, let request):
                guard decodedID == requestID else { throw ReconstructionAIWorkerWireError.invalidAuthority }
                semantic = .finalSynthesis(request)
                authority = .finalSynthesis(request)
            }
            guard configuration.protocolManifestDigest == (try semantic.protocolBundle).manifestDigest else {
                throw ReconstructionAIWorkerWireError.invalidAuthority
            }
            guard register(
                requestID: requestID,
                phase: .finalization,
                protocolBundle: (try semantic.protocolBundle),
                sink: eventSink
            ) else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        } catch {
            sendTerminalDirect(
                requestID: requestID,
                protocolBundle: configuration.protocolManifestDigest == Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest
                    ? Phase2AIWorkerProductionProtocol.reconstructionSourceV10 : configuration.protocolManifestDigest
                    == Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest
                    ? Phase2AIWorkerProductionProtocol.reconstructionR2
                    : Phase2AIWorkerProductionProtocol.reconstructionR1,
                status: .failed,
                reason: .invalidRequest,
                sink: eventSink
            )
            return
        }

        let task = Task { [weak self, reconstructionHandler] in
            guard let self else { return }
            do {
                try await reconstructionHandler.run(
                    requestID: requestID,
                    request: semantic,
                    configuration: configuration,
                    emitControl: { [weak self] event in
                        guard let self else { throw CancellationError() }
                        let eventData = try self.codec.encodeEvent(event)
                        try await self.sendEncoded(
                            eventData,
                            requestID: requestID,
                            sink: eventSink
                        )
                    }
                ) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.sendReconstruction(
                        event,
                        authority: authority,
                        requestID: requestID,
                        sink: eventSink
                    )
                }
                self.finish(requestID: requestID, status: .completed, reason: nil)
            } catch is CancellationError {
                self.finish(requestID: requestID, status: .cancelled, reason: nil)
            } catch Phase2OpenAIChatHTTPClientError.totalDeadlineExceeded {
                self.finish(requestID: requestID, status: .failed, reason: .overallDeadlineExceeded)
            } catch Phase2OpenAIChatHTTPClientError.inactivityTimeout {
                self.finish(requestID: requestID, status: .failed, reason: .streamInactivityTimeout)
            } catch Phase2OpenAIChatHTTPClientError.outputLimitExceeded {
                self.finish(requestID: requestID, status: .failed, reason: .outputLimitExceeded)
            } catch Phase2OpenAIChatRequestEncodingError.contextBudgetExceeded {
                self.finish(requestID: requestID, status: .failed, reason: .contextBudgetExceeded)
            } catch {
                Self.failureLogger.error("MacScopeAIWorker failure category=\(Self.failureDiagnosticCategory(error), privacy: .public)")
                self.finish(requestID: requestID, status: .failed, reason: .workerHandlerFailed)
            }
        }
        let installed = lock.withLock { () -> Bool in
            guard var state = requests[requestID] else { return false }
            state.task = task
            requests[requestID] = state
            return true
        }
        if !installed { task.cancel() }
    }

    /// Failure categories only. Never interpolate NSError descriptions, provider output,
    /// prompt contents, evidence, request identities, or unknown associated values into logs.
    static func failureDiagnosticCategory(_ error: Error) -> String {
        if let value = error as? Phase2OpenAIChatHTTPClientError {
            return "http." + String(describing: value)
        }
        if let value = error as? Phase2GroundedFinalDecodingError {
            return "groundedFinal." + String(describing: value)
        }
        if let value = error as? Phase2LiveInferenceHandlerError {
            switch value {
            case .invalidToolSelection: return "handler.invalidToolSelection"
            case .invalidFinalization: return "handler.invalidFinalization"
            case .unsupportedInferenceProtocol: return "handler.unsupportedInferenceProtocol"
            case .providerConnectionUnavailable: return "handler.providerConnectionUnavailable"
            }
        }
        if let value = error as? Phase2ReconstructionAIWorkerHandlerError {
            return "reconstructionHandler." + String(describing: value)
        }
        if let value = error as? Phase2ReconstructionRoundAccumulatorError {
            return "reconstructionOutput." + String(describing: value)
        }
        return "unclassified"
    }

    private static func bundle(
        manifestIdentity: String
    ) -> Phase2AIWorkerProductionProtocolBundle? {
        allBundles.first { $0.manifestIdentity == manifestIdentity }
    }

    private static func bundle(
        manifestDigest: String
    ) -> Phase2AIWorkerProductionProtocolBundle? {
        allBundles.first { $0.manifestDigest == manifestDigest }
    }

    private static let allBundles = [
        Phase2AIWorkerProductionProtocol.standard,
        Phase2AIWorkerProductionProtocol.assistantR2,
        Phase2AIWorkerProductionProtocol.assistantR3,
        Phase2AIWorkerProductionProtocol.assistantR4,
        Phase2AIWorkerProductionProtocol.reconstructionR1,
        Phase2AIWorkerProductionProtocol.reconstructionR2,
        Phase2AIWorkerProductionProtocol.reconstructionSourceV10,
    ]
}

protocol Phase2AIWorkerModelDiscoveryHandling: Sendable {
    func discoverModels(
        request: Phase2AIWorkerModelDiscoveryRequest
    ) async -> Phase2AIWorkerModelDiscoveryReply
}

struct Phase2LiveModelDiscoveryHandler: Phase2AIWorkerModelDiscoveryHandling, Sendable {
    func discoverModels(
        request: Phase2AIWorkerModelDiscoveryRequest
    ) async -> Phase2AIWorkerModelDiscoveryReply {
        guard let policy = request.inferencePolicy, policy.isValid else {
            return .init(schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: request.requestID, profileID: request.profileID,
                generation: request.generation, status: .incompatible, inventory: nil)
        }
        let status: Phase2AIWorkerModelDiscoveryReply.Status
        let inventory: Phase2AIWorkerModelInventoryWire?

        do {
            let endpoint = try Phase2LoopbackEndpoint(validating: request.endpointOrigin)
            let client = Phase2NativeModelDiscoveryHTTPClient(
                requestTimeout: TimeInterval(min(request.requestTimeoutMilliseconds, 5_000)) / 1_000,
                resourceTimeout: TimeInterval(min(request.resourceTimeoutMilliseconds, 15_000)) / 1_000
            )
            let catalog = try await client.discover(at: endpoint, provider: policy.provider)
            status = .success
            inventory = .init(models: catalog.models.map(Self.makeWireModel))
        } catch Phase2NativeModelDiscoveryHTTPClientError.authRequired {
            status = .authenticationRequired
            inventory = nil
        } catch Phase2NativeModelDiscoveryHTTPClientError.cancelled {
            status = .cancelled
            inventory = nil
        } catch Phase2NativeModelDiscoveryHTTPClientError.incompatible {
            status = .incompatible
            inventory = nil
        } catch is CancellationError {
            status = .cancelled
            inventory = nil
        } catch {
            status = .unavailable
            inventory = nil
        }

        return .init(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: request.requestID,
            profileID: request.profileID,
            generation: request.generation,
            status: status,
            inventory: inventory
        )
    }

    private static func makeWireModel(_ model: Phase2NativeModel) -> Phase2AIWorkerModelWire {
        .init(
            type: model.kind == .llm ? .llm : .embedding,
            publisher: model.publisher,
            key: model.key,
            displayName: model.displayName,
            architecture: model.architecture,
            quantization: model.quantization.map {
                .init(name: $0.name, bitsPerWeight: $0.bitsPerWeight)
            },
            sizeBytes: model.sizeBytes,
            parameters: model.parameters,
            loadedInstances: model.loadedInstances.map {
                .init(
                    id: $0.id,
                    configuration: .init(
                        contextLength: $0.configuration.contextLength,
                        evaluationBatchSize: $0.configuration.evaluationBatchSize,
                        parallelPredictions: $0.configuration.parallelPredictions,
                        flashAttention: $0.configuration.flashAttention,
                        expertCount: $0.configuration.expertCount,
                        offloadsKVCacheToGPU: $0.configuration.offloadsKVCacheToGPU
                    )
                )
            },
            maximumContextLength: model.maximumContextLength,
            format: model.format.map { $0 == .gguf ? .gguf : .mlx },
            capabilities: model.capabilities.map {
                .init(
                    vision: $0.supportsVision,
                    trainedForToolUse: $0.trainedForToolUse,
                    reasoning: $0.reasoning.map {
                        .init(
                            allowedOptions: $0.allowedOptions.map(\.rawValue),
                            defaultOption: $0.defaultOption.rawValue
                        )
                    }
                )
            },
            summary: model.description,
            variants: model.variants ?? [],
            selectedVariant: model.selectedVariant
        )
    }
}

private final class Phase2WorkerAcknowledgementOneShot: @unchecked Sendable {
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

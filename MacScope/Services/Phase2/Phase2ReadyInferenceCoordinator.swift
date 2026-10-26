import Combine
import Foundation

enum Phase2ReadyInferenceExecutionResult: Equatable, Sendable {
    case notReady(Phase2LocalAIProviderReadiness)
    case busy
    case invalidRequest
    case providerAuthorityChanged
    case finished(lease: Phase2ReadyInferenceLease, outcome: Phase2InferenceOutcome)
}

extension Phase2ReadyInferenceCoordinator: ReconstructionReadyInferenceCoordinating {}

/// Qualification-only proof that controlled cancellation crossed the exact frozen injection
/// point: after request-specific HTTP response headers and before any provider event is admitted
/// to inference state. Missing, duplicate, stale, or out-of-order signals fail closed.
final class Phase2ControlledCancellationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let requestID: UUID
    private var dispatchReceived = false
    private var cancellationIssued = false
    private var providerFinished = false
    private var invalid = false
    private var dispatchWaiter: CheckedContinuation<Bool, Never>?
    private var eventWaiters: [CheckedContinuation<Void, Never>] = []

    init(requestID: UUID) {
        self.requestID = requestID
    }

    var hasProvenDispatchBeforeCancellation: Bool {
        lock.withLock {
            dispatchReceived && cancellationIssued && !invalid
        }
    }

    func waitForProviderDispatch() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if dispatchReceived, !invalid {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            if invalid || cancellationIssued || providerFinished {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            guard dispatchWaiter == nil else {
                invalid = true
                let existing = dispatchWaiter
                dispatchWaiter = nil
                let events = eventWaiters
                eventWaiters.removeAll()
                lock.unlock()
                existing?.resume(returning: false)
                events.forEach { $0.resume() }
                continuation.resume(returning: false)
                return
            }
            dispatchWaiter = continuation
            lock.unlock()
        }
    }

    func waitForCancellationBeforeRejectingProviderEvent() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard dispatchReceived, !invalid else {
                invalid = true
                let dispatch = dispatchWaiter
                dispatchWaiter = nil
                let events = eventWaiters
                eventWaiters.removeAll()
                lock.unlock()
                dispatch?.resume(returning: false)
                events.forEach { $0.resume() }
                continuation.resume()
                return
            }
            if cancellationIssued || providerFinished {
                lock.unlock()
                continuation.resume()
                return
            }
            eventWaiters.append(continuation)
            lock.unlock()
        }
    }

    func providerDidDispatch(_ receipt: Phase2InferenceDispatchReceipt) {
        lock.lock()
        guard receipt.requestID == requestID,
              receipt.boundary == .httpResponseHeaders,
              !dispatchReceived,
              !cancellationIssued,
              !providerFinished,
              !invalid
        else {
            invalid = true
            let dispatch = dispatchWaiter
            dispatchWaiter = nil
            let events = eventWaiters
            eventWaiters.removeAll()
            lock.unlock()
            dispatch?.resume(returning: false)
            events.forEach { $0.resume() }
            return
        }
        dispatchReceived = true
        let dispatch = dispatchWaiter
        dispatchWaiter = nil
        lock.unlock()
        dispatch?.resume(returning: true)
    }

    func providerDidFinish() {
        lock.lock()
        providerFinished = true
        if !dispatchReceived || !cancellationIssued {
            invalid = true
        }
        let dispatch = dispatchWaiter
        dispatchWaiter = nil
        let events = eventWaiters
        eventWaiters.removeAll()
        lock.unlock()
        dispatch?.resume(returning: false)
        events.forEach { $0.resume() }
    }

    fileprivate func cancellationHandlerDidRun() {
        lock.lock()
        guard dispatchReceived, !cancellationIssued, !providerFinished, !invalid else {
            invalid = true
            let dispatch = dispatchWaiter
            dispatchWaiter = nil
            let events = eventWaiters
            eventWaiters.removeAll()
            lock.unlock()
            dispatch?.resume(returning: false)
            events.forEach { $0.resume() }
            return
        }
        cancellationIssued = true
        let events = eventWaiters
        eventWaiters.removeAll()
        lock.unlock()
        events.forEach { $0.resume() }
    }

    fileprivate func admissionDeclined() {
        lock.lock()
        invalid = true
        providerFinished = true
        let dispatch = dispatchWaiter
        dispatchWaiter = nil
        let events = eventWaiters
        eventWaiters.removeAll()
        lock.unlock()
        dispatch?.resume(returning: false)
        events.forEach { $0.resume() }
    }
}

private final class Phase2InferenceTurnCancellationControl: @unchecked Sendable {
    private let lock = NSLock()
    private let phase: Phase2InferencePhase
    private let observer: (any Phase2InferenceMeasurementObserving)?
    private let barrier: Phase2ControlledCancellationBarrier?
    private var task: Task<Phase2InferenceOutcome, Never>?
    private var cancellationDelivered = false

    init(
        phase: Phase2InferencePhase,
        observer: (any Phase2InferenceMeasurementObserving)?,
        barrier: Phase2ControlledCancellationBarrier?
    ) {
        self.phase = phase
        self.observer = observer
        self.barrier = barrier
    }

    func install(_ task: Task<Phase2InferenceOutcome, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationDelivered
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        guard !cancellationDelivered else {
            lock.unlock()
            return
        }
        cancellationDelivered = true
        let task = self.task
        lock.unlock()

        observer?.cancellationBegan(phase: phase)
        barrier?.cancellationHandlerDidRun()
        task?.cancel()
    }
}

/// Qualification-only authority for the concrete worker process serving each fresh provider.
/// The callback runs after the provider has prepared its active XPC connection and before
/// admission, so process-scoped measurement can bind the exact worker rather than a spare or
/// caller-asserted process. Ordinary inference does not install this authority.
@MainActor
protocol Phase2InferenceWorkerProcessReceiptObserving: AnyObject {
    func acceptWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool
    func acceptProviderConnectionReceipt(
        _ receipt: Phase2InferenceProviderConnectionReceipt,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool
    func acceptProviderDispatchReceipt(
        _ receipt: Phase2InferenceDispatchReceipt,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool
}

/// Gate-owned bridge used by the closed production live executor. Its sampler is a deferred,
/// thread-safe proxy: the first worker receipt binds exact app/worker/provider roles before the
/// coordinator announces admission and before the first resident-set sample.
@MainActor
protocol Phase2ProductionLiveQualificationProcessAuthorizing:
    Phase2InferenceWorkerProcessReceiptObserving
{
    var residentSetSampler: any Phase2QualificationBoundResidentSetSampling { get }
    func finishRuntimeProvenance(
        for execution: Phase2LiveQualificationExecution
    ) throws -> Phase2QualificationRuntimeProvenance
}

/// App-global execution boundary between provider readiness and one transient inference turn.
///
/// The coordinator owns admission and revision-qualified authority only. The inference runner
/// remains the sole owner of provider event validation and provider cancellation.
@MainActor
final class Phase2ReadyInferenceCoordinator: ObservableObject {
    private enum ReconstructionTaskFailure: Error {
        case withoutTerminalAuthority(ReconstructionReadyInferenceFailure)
        case withTerminalAuthority(ReconstructionInferenceRunnerTerminalFailure)
    }

    private enum ReconstructionWorkerAuthorityPreparation {
        case notRequired
        case prepared(
            provider: any ReconstructionInferenceWorkerProcessReceiptProviding,
            receipt: Phase2InferenceWorkerProcessReceipt
        )
        case rejected
    }

    typealias ProviderFactory = @MainActor (Phase2AIProviderConfiguration)
        -> any Phase2InferenceProviding
    typealias ReconstructionProviderFactory = @MainActor (Phase2AIProviderConfiguration)
        -> any ReconstructionInferenceProviding

    private struct ActiveTurn {
        let id: UUID
        let controllerID: ObjectIdentifier
        let lease: Phase2ReadyInferenceLease
        let cancel: @MainActor () -> Void
    }

    private let controller: Phase2LocalAIProviderController
    private let providerFactory: ProviderFactory
    private let reconstructionProviderFactory: ReconstructionProviderFactory
    private let reconstructionR2ProviderFactory: ReconstructionProviderFactory
    private let reconstructionSourceProviderFactory: ReconstructionProviderFactory
    private let reconstructionInferenceRunner: ReconstructionInferenceRunner
    private let workerProcessReceiptObserver:
        (any Phase2InferenceWorkerProcessReceiptObserving)?
    private static var activeTurn: ActiveTurn?
    private static var admissionReservation: UUID?
    private var snapshotObservation: AnyCancellable?

    init(
        controller: Phase2LocalAIProviderController,
        workerProcessReceiptObserver:
            (any Phase2InferenceWorkerProcessReceiptObserving)? = nil,
        providerFactory: @escaping ProviderFactory = { configuration in
            AIAgentXPCInferenceProvider(configuration: configuration)
        },
        reconstructionProviderFactory: @escaping ReconstructionProviderFactory = {
            configuration in
            ReconstructionXPCInferenceProvider(configuration: configuration,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR1)
        },
        reconstructionR2ProviderFactory: @escaping ReconstructionProviderFactory = {
            configuration in
            ReconstructionXPCInferenceProvider(configuration: configuration,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        },
        reconstructionSourceProviderFactory: @escaping ReconstructionProviderFactory = { configuration in
            ReconstructionXPCInferenceProvider(configuration: configuration,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        },
        reconstructionInferenceRunner: ReconstructionInferenceRunner = .init()
    ) {
        self.controller = controller
        self.workerProcessReceiptObserver = workerProcessReceiptObserver
        self.providerFactory = providerFactory
        self.reconstructionProviderFactory = reconstructionProviderFactory
        self.reconstructionR2ProviderFactory = reconstructionR2ProviderFactory
        self.reconstructionSourceProviderFactory = reconstructionSourceProviderFactory
        self.reconstructionInferenceRunner = reconstructionInferenceRunner
        snapshotObservation = controller.$snapshot
            .map(\.revision)
            .removeDuplicates()
            .sink { [weak self] revision in
                MainActor.assumeIsolated {
                    self?.providerRevisionDidChange(to: revision)
                }
            }
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        await run(request: request, measurementObserver: nil)
    }

    func refreshProviderIfNotReady() async {
        guard Self.activeTurn == nil, Self.admissionReservation == nil else { return }
        await controller.refreshIfNotReady()
    }

    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?
    ) async -> Phase2ReadyInferenceExecutionResult {
        await runImpl(
            request: request,
            measurementObserver: measurementObserver,
            controlledCancellationBarrier: nil
        )
    }

    func run(
        request: ReconstructionInferenceRoundRequest
    ) async -> ReconstructionReadyInferenceExecutionResult {
        await run(request: request, objective: nil)
    }

    func proposeSourceRevision(
        request: ReconstructionSourceRevisionRequest
    ) async -> ReconstructionReadySourceRevisionExecutionResult {
        let validationRequestID = UUID()
        let semanticRequest = ReconstructionAIWorkerRequest.sourceRevision(request)
        guard (try? ReconstructionAIWorkerAppCodec().encode(
            semanticRequest, requestID: validationRequestID
        )) != nil else {
            return .invalidRequest
        }
        guard !Task.isCancelled else {
            return .failedWithoutTerminalAuthority(.cancelled)
        }
        guard Self.activeTurn == nil, Self.admissionReservation == nil else {
            return .busy
        }
        let reservation = UUID()
        Self.admissionReservation = reservation
        defer {
            if Self.admissionReservation == reservation {
                Self.admissionReservation = nil
            }
        }
        if controller.snapshot.endpoint?.providerKind == .mtplx {
            // Re-observe loaded identity, engine mode, and capacity at every new inference lease.
            _ = try? await controller.refresh()
        }
        guard let lease = controller.captureReadyInferenceLease() else {
            return .notReady(controller.snapshot.readiness)
        }
        let replay: ReconstructionReplaySession?
        let protocolBundle: Phase2AIWorkerProductionProtocolBundle
        do {
            protocolBundle = try semanticRequest.protocolBundle
            replay = try await .begin(request: semanticRequest, lease: lease, inventory: controller.snapshot.inventory)
        } catch { return .failedWithoutTerminalAuthority(.replayAdmission(error)) }
        let provider: any ReconstructionInferenceProviding = replay?.provider
            ?? reconstructionSourceProviderFactory(lease.configuration)
        let workerAuthority: ReconstructionWorkerAuthorityPreparation = replay?.isReplay == true
            ? .notRequired : await prepareReconstructionWorkerAuthority(
            for: provider,
            lease: lease,
            protocolBundle: protocolBundle
        )
        if case .rejected = workerAuthority {
            await provider.finishRequest()
            return .providerAuthorityChanged
        }
        guard controller.isCurrent(lease) else {
            await provider.finishRequest()
            return .providerAuthorityChanged
        }
        let result = await runReconstructionSourceRevision(
            request: request,
            semanticRequest: semanticRequest,
            lease: lease,
            provider: provider,
            workerAuthority: workerAuthority,
            replay: replay
        )
        await provider.finishRequest()
        return result
    }

    private func runReconstructionSourceRevision(
        request: ReconstructionSourceRevisionRequest,
        semanticRequest: ReconstructionAIWorkerRequest,
        lease: Phase2ReadyInferenceLease,
        provider: any ReconstructionInferenceProviding,
        workerAuthority: ReconstructionWorkerAuthorityPreparation,
        replay: ReconstructionReplaySession?
    ) async -> ReconstructionReadySourceRevisionExecutionResult {
        guard controller.isCurrent(lease) else { return .providerAuthorityChanged }

        let requestID = replay?.requestID ?? UUID()
        let turnID = UUID()
        let task = Task {
            do {
                return Result<ReconstructionSourceRevisionExecutionResult,
                    ReconstructionTaskFailure>.success(
                    try await reconstructionInferenceRunner.runSourceRevision(
                        requestID: requestID,
                        request: request,
                        provider: provider
                    )
                )
            } catch let failure as ReconstructionInferenceRunnerTerminalFailure {
                return .failure(.withTerminalAuthority(failure))
            } catch is CancellationError {
                // The provider may acknowledge cancellation before returning a
                // terminal receipt without cancelling this coordinator task.
                return .failure(.withoutTerminalAuthority(.cancelled))
            } catch let error as ReconstructionInferenceRunnerError {
                return .failure(.withoutTerminalAuthority(.runner(error)))
            } catch let error as AIAgentXPCTransportError {
                switch error {
                case .unavailable, .invalidated:
                    return .failure(.withoutTerminalAuthority(.retryableProviderFailure(nil)))
                case .malformedReply, .protocolMismatch, .terminalProtocolMismatch:
                    return .failure(.withoutTerminalAuthority(.providerFailure))
                }
            } catch ReconstructionXPCInferenceProviderError
                .terminalWithoutSemanticRequestAuthority(let terminal) {
                return .failure(.withoutTerminalAuthority(
                    .providerFailure(reason: terminal.reason)
                ))
            } catch {
                return .failure(.withoutTerminalAuthority(.providerFailure))
            }
        }
        let roundWatchdog: Task<Void, Never>? = replay.map { session in
            let seconds = ReconstructionBudgetPolicy.forProcess().roundSeconds(
                isColdFirstRound: ReconstructionColdRoundTracker.shared.isColdRound(session))
            return Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                task.cancel()
                await provider.cancel(requestID: requestID)
            }
        }
        defer { roundWatchdog?.cancel() }
        Self.activeTurn = .init(
            id: turnID,
            controllerID: ObjectIdentifier(controller),
            lease: lease,
            cancel: {
                task.cancel()
                Task { await provider.cancel(requestID: requestID) }
            }
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { await provider.cancel(requestID: requestID) }
        }
        defer {
            if Self.activeTurn?.id == turnID { Self.activeTurn = nil }
        }
        let requiresAcceptedConnection: Bool
        if case .failure(.withoutTerminalAuthority(.cancelled)) = result {
            requiresAcceptedConnection = false
        } else {
            requiresAcceptedConnection = true
        }
        guard await reconstructionWorkerAuthorityRemainsValid(
            workerAuthority,
            lease: lease,
            requestID: requestID,
            requiresAcceptedConnection: requiresAcceptedConnection
        ) else { return .providerAuthorityChanged }
        guard controller.isCurrent(lease) else { return .providerAuthorityChanged }
        switch result {
        case .success(let outcome):
            guard var authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: semanticRequest,
                terminalReceipt: outcome.terminalReceipt
            ) else {
                return .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
            }
            if let replay {
                do { authority = try await replay.publish(authority: authority,
                    candidate: .source(outcome.candidate), usage: outcome.usage, provider: provider) }
                catch { return .failedWithoutTerminalAuthority(.retryableProviderFailure(nil)) }
            }
            return .finished(
                lease: lease,
                requestAuthority: authority,
                outcome: outcome
            )
        case .failure(.withTerminalAuthority(let terminal)):
            guard let authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: semanticRequest,
                terminalReceipt: terminal.terminalReceipt
            ) else {
                return .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
            }
            return .failedWithTerminalAuthority(
                lease: lease,
                requestAuthority: authority,
                failure: terminal.failure
            )
        case .failure(.withoutTerminalAuthority(let failure)):
            return .failedWithoutTerminalAuthority(failure)
        }
    }

    func run(
        request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?
    ) async -> ReconstructionReadyInferenceExecutionResult {
        let validationRequestID = UUID()
        let semanticRequest: ReconstructionAIWorkerRequest
        if let objective {
            semanticRequest = .roundR2(.init(protocolVersion: 9, objective: objective, request: request))
        } else {
            semanticRequest = .round(request)
        }
        guard (try? ReconstructionAIWorkerAppCodec().encode(
            semanticRequest, requestID: validationRequestID
        )) != nil else {
            return .invalidRequest
        }
        guard !Task.isCancelled else {
            return .failedWithoutTerminalAuthority(.cancelled)
        }
        guard Self.activeTurn == nil, Self.admissionReservation == nil else {
            return .busy
        }
        let reservation = UUID()
        Self.admissionReservation = reservation
        defer {
            if Self.admissionReservation == reservation {
                Self.admissionReservation = nil
            }
        }
        if controller.snapshot.endpoint?.providerKind == .mtplx {
            // Re-observe loaded identity, engine mode, and capacity at every new inference lease.
            _ = try? await controller.refresh()
        }
        guard let lease = controller.captureReadyInferenceLease() else {
            return .notReady(controller.snapshot.readiness)
        }
        let replay: ReconstructionReplaySession?
        let protocolBundle: Phase2AIWorkerProductionProtocolBundle
        do {
            protocolBundle = try semanticRequest.protocolBundle
            replay = try await .begin(request: semanticRequest, lease: lease, inventory: controller.snapshot.inventory)
        } catch { return .failedWithoutTerminalAuthority(.replayAdmission(error)) }
        let provider: any ReconstructionInferenceProviding = replay?.provider
            ?? (objective == nil ? reconstructionProviderFactory(lease.configuration)
                : reconstructionR2ProviderFactory(lease.configuration))
        let workerAuthority: ReconstructionWorkerAuthorityPreparation = replay?.isReplay == true
            ? .notRequired : await prepareReconstructionWorkerAuthority(
            for: provider,
            lease: lease,
            protocolBundle: protocolBundle
        )
        if case .rejected = workerAuthority {
            await provider.finishRequest()
            return .providerAuthorityChanged
        }
        guard controller.isCurrent(lease) else {
            await provider.finishRequest()
            return .providerAuthorityChanged
        }
        let result = await runReconstructionRound(
            request: request,
            objective: objective,
            semanticRequest: semanticRequest,
            lease: lease,
            provider: provider,
            workerAuthority: workerAuthority,
            replay: replay
        )
        await provider.finishRequest()
        return result
    }

    private func runReconstructionRound(
        request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?,
        semanticRequest: ReconstructionAIWorkerRequest,
        lease: Phase2ReadyInferenceLease,
        provider: any ReconstructionInferenceProviding,
        workerAuthority: ReconstructionWorkerAuthorityPreparation,
        replay: ReconstructionReplaySession?
    ) async -> ReconstructionReadyInferenceExecutionResult {
        guard controller.isCurrent(lease) else { return .providerAuthorityChanged }

        let requestID = replay?.requestID ?? UUID()
        let turnID = UUID()
        let task = Task {
            do {
                return Result<ReconstructionInferenceExecutionResult,
                    ReconstructionTaskFailure>.success(
                    try await reconstructionInferenceRunner.run(
                        requestID: requestID,
                        request: request,
                        provider: provider,
                        objective: objective
                    )
                )
            } catch let failure as ReconstructionInferenceRunnerTerminalFailure {
                return .failure(.withTerminalAuthority(failure))
            } catch is CancellationError {
                // The provider may acknowledge cancellation before returning a
                // terminal receipt without cancelling this coordinator task.
                return .failure(.withoutTerminalAuthority(.cancelled))
            } catch let error as ReconstructionInferenceRunnerError {
                return .failure(.withoutTerminalAuthority(.runner(error)))
            } catch let error as AIAgentXPCTransportError {
                switch error {
                case .unavailable, .invalidated:
                    return .failure(.withoutTerminalAuthority(.retryableProviderFailure(nil)))
                case .malformedReply, .protocolMismatch, .terminalProtocolMismatch:
                    return .failure(.withoutTerminalAuthority(.providerFailure))
                }
            } catch ReconstructionXPCInferenceProviderError
                .terminalWithoutSemanticRequestAuthority(let terminal) {
                return .failure(.withoutTerminalAuthority(
                    .providerFailure(reason: terminal.reason)
                ))
            } catch {
                return .failure(.withoutTerminalAuthority(.providerFailure))
            }
        }
        let roundWatchdog: Task<Void, Never>? = replay.map { session in
            let seconds = ReconstructionBudgetPolicy.forProcess().roundSeconds(
                isColdFirstRound: ReconstructionColdRoundTracker.shared.isColdRound(session))
            return Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                task.cancel()
                await provider.cancel(requestID: requestID)
            }
        }
        defer { roundWatchdog?.cancel() }
        Self.activeTurn = .init(
            id: turnID,
            controllerID: ObjectIdentifier(controller),
            lease: lease,
            cancel: {
                task.cancel()
                Task { await provider.cancel(requestID: requestID) }
            }
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { await provider.cancel(requestID: requestID) }
        }
        defer {
            if Self.activeTurn?.id == turnID { Self.activeTurn = nil }
        }
        let requiresAcceptedConnection: Bool
        if case .failure(.withoutTerminalAuthority(.cancelled)) = result {
            requiresAcceptedConnection = false
        } else {
            requiresAcceptedConnection = true
        }
        guard await reconstructionWorkerAuthorityRemainsValid(
            workerAuthority,
            lease: lease,
            requestID: requestID,
            requiresAcceptedConnection: requiresAcceptedConnection
        ) else { return .providerAuthorityChanged }
        guard controller.isCurrent(lease) else { return .providerAuthorityChanged }
        switch result {
        case .success(let outcome):
            guard var authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: semanticRequest,
                terminalReceipt: outcome.terminalReceipt
            ) else {
                return .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
            }
            if let replay {
                do { authority = try await replay.publish(authority: authority,
                    candidate: .round(outcome.candidate), usage: outcome.usage, provider: provider) }
                catch { return .failedWithoutTerminalAuthority(.retryableProviderFailure(nil)) }
            }
            return .finished(
                lease: lease,
                requestAuthority: authority,
                outcome: outcome
            )
        case .failure(.withTerminalAuthority(let terminal)):
            guard let authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: semanticRequest,
                terminalReceipt: terminal.terminalReceipt
            ) else {
                return .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
            }
            return .failedWithTerminalAuthority(
                lease: lease,
                requestAuthority: authority,
                failure: terminal.failure
            )
        case .failure(.withoutTerminalAuthority(let failure)):
            return .failedWithoutTerminalAuthority(failure)
        }
    }

    func synthesize(
        request: ReconstructionFinalSynthesisRequest
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        await synthesize(request: request, objective: nil)
    }

    func synthesize(
        request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        let validationRequestID = UUID()
        let semanticRequest: ReconstructionAIWorkerRequest
        if let objective {
            semanticRequest = .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: request))
        } else {
            semanticRequest = .finalSynthesis(request)
        }
        guard (try? ReconstructionAIWorkerAppCodec().encode(
            semanticRequest, requestID: validationRequestID
        )) != nil else {
            return .invalidRequest
        }
        guard !Task.isCancelled else {
            return .failedWithoutTerminalAuthority(.cancelled)
        }
        guard Self.activeTurn == nil, Self.admissionReservation == nil else {
            return .busy
        }
        let reservation = UUID()
        Self.admissionReservation = reservation
        defer {
            if Self.admissionReservation == reservation {
                Self.admissionReservation = nil
            }
        }
        if controller.snapshot.endpoint?.providerKind == .mtplx {
            // Re-observe loaded identity, engine mode, and capacity at every new inference lease.
            _ = try? await controller.refresh()
        }
        guard let lease = controller.captureReadyInferenceLease() else {
            return .notReady(controller.snapshot.readiness)
        }
        let replay: ReconstructionReplaySession?
        let protocolBundle: Phase2AIWorkerProductionProtocolBundle
        do {
            protocolBundle = try semanticRequest.protocolBundle
            replay = try await .begin(request: semanticRequest, lease: lease, inventory: controller.snapshot.inventory)
        } catch { return .failedWithoutTerminalAuthority(.replayAdmission(error)) }
        let provider: any ReconstructionInferenceProviding = replay?.provider
            ?? (objective == nil ? reconstructionProviderFactory(lease.configuration)
                : reconstructionR2ProviderFactory(lease.configuration))
        let workerAuthority: ReconstructionWorkerAuthorityPreparation = replay?.isReplay == true
            ? .notRequired : await prepareReconstructionWorkerAuthority(
            for: provider,
            lease: lease,
            protocolBundle: protocolBundle
        )
        if case .rejected = workerAuthority {
            await provider.finishRequest()
            return .providerAuthorityChanged
        }
        guard controller.isCurrent(lease) else {
            await provider.finishRequest()
            return .providerAuthorityChanged
        }
        let result = await runReconstructionFinalSynthesis(
            request: request,
            objective: objective,
            semanticRequest: semanticRequest,
            lease: lease,
            provider: provider,
            workerAuthority: workerAuthority,
            replay: replay
        )
        await provider.finishRequest()
        return result
    }

    private func runReconstructionFinalSynthesis(
        request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?,
        semanticRequest: ReconstructionAIWorkerRequest,
        lease: Phase2ReadyInferenceLease,
        provider: any ReconstructionInferenceProviding,
        workerAuthority: ReconstructionWorkerAuthorityPreparation,
        replay: ReconstructionReplaySession?
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        guard controller.isCurrent(lease) else { return .providerAuthorityChanged }

        let requestID = replay?.requestID ?? UUID()
        let turnID = UUID()
        let task = Task {
            do {
                return Result<ReconstructionFinalSynthesisExecutionResult,
                    ReconstructionTaskFailure>.success(
                    try await reconstructionInferenceRunner.synthesize(
                        requestID: requestID,
                        request: request,
                        provider: provider,
                        objective: objective
                    )
                )
            } catch let failure as ReconstructionInferenceRunnerTerminalFailure {
                return .failure(.withTerminalAuthority(failure))
            } catch is CancellationError {
                return .failure(.withoutTerminalAuthority(.cancelled))
            } catch let error as ReconstructionInferenceRunnerError {
                return .failure(.withoutTerminalAuthority(.runner(error)))
            } catch let error as AIAgentXPCTransportError {
                switch error {
                case .unavailable, .invalidated:
                    return .failure(.withoutTerminalAuthority(.retryableProviderFailure(nil)))
                case .malformedReply, .protocolMismatch, .terminalProtocolMismatch:
                    return .failure(.withoutTerminalAuthority(.providerFailure))
                }
            } catch ReconstructionXPCInferenceProviderError
                .terminalWithoutSemanticRequestAuthority(let terminal) {
                return .failure(.withoutTerminalAuthority(
                    .providerFailure(reason: terminal.reason)
                ))
            } catch {
                return .failure(.withoutTerminalAuthority(.providerFailure))
            }
        }
        let roundWatchdog: Task<Void, Never>? = replay.map { session in
            let seconds = ReconstructionBudgetPolicy.forProcess().roundSeconds(
                isColdFirstRound: ReconstructionColdRoundTracker.shared.isColdRound(session))
            return Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                task.cancel()
                await provider.cancel(requestID: requestID)
            }
        }
        defer { roundWatchdog?.cancel() }
        Self.activeTurn = .init(
            id: turnID,
            controllerID: ObjectIdentifier(controller),
            lease: lease,
            cancel: {
                task.cancel()
                Task { await provider.cancel(requestID: requestID) }
            }
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { await provider.cancel(requestID: requestID) }
        }
        defer {
            if Self.activeTurn?.id == turnID { Self.activeTurn = nil }
        }
        let requiresAcceptedConnection: Bool
        if case .failure(.withoutTerminalAuthority(.cancelled)) = result {
            requiresAcceptedConnection = false
        } else {
            requiresAcceptedConnection = true
        }
        guard await reconstructionWorkerAuthorityRemainsValid(
            workerAuthority,
            lease: lease,
            requestID: requestID,
            requiresAcceptedConnection: requiresAcceptedConnection
        ) else { return .providerAuthorityChanged }
        guard controller.isCurrent(lease) else { return .providerAuthorityChanged }
        switch result {
        case .success(let outcome):
            guard var authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: semanticRequest,
                terminalReceipt: outcome.terminalReceipt
            ) else {
                return .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
            }
            if let replay {
                do { authority = try await replay.publish(authority: authority,
                    candidate: .final(outcome.candidate), usage: outcome.usage, provider: provider) }
                catch { return .failedWithoutTerminalAuthority(.retryableProviderFailure(nil)) }
            }
            return .finished(
                lease: lease,
                requestAuthority: authority,
                outcome: outcome
            )
        case .failure(.withTerminalAuthority(let terminal)):
            guard let authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: semanticRequest,
                terminalReceipt: terminal.terminalReceipt
            ) else {
                return .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
            }
            return .failedWithTerminalAuthority(
                lease: lease,
                requestAuthority: authority,
                failure: terminal.failure
            )
        case .failure(.withoutTerminalAuthority(let failure)):
            return .failedWithoutTerminalAuthority(failure)
        }
    }

    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?,
        controlledCancellationBarrier: Phase2ControlledCancellationBarrier
    ) async -> Phase2ReadyInferenceExecutionResult {
        await runImpl(
            request: request,
            measurementObserver: measurementObserver,
            controlledCancellationBarrier: controlledCancellationBarrier
        )
    }

    private func runImpl(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?,
        controlledCancellationBarrier: Phase2ControlledCancellationBarrier?
    ) async -> Phase2ReadyInferenceExecutionResult {
        guard Phase2InferenceRunner.requestIsValid(request) else {
            declineAdmission(
                request.phase,
                observer: measurementObserver,
                barrier: controlledCancellationBarrier
            )
            return .invalidRequest
        }
        guard !Task.isCancelled else {
            declineAdmission(
                request.phase,
                observer: measurementObserver,
                barrier: controlledCancellationBarrier
            )
            return .providerAuthorityChanged
        }
        guard Self.activeTurn == nil, Self.admissionReservation == nil else {
            declineAdmission(
                request.phase,
                observer: measurementObserver,
                barrier: controlledCancellationBarrier
            )
            return .busy
        }
        let admissionReservation = UUID()
        Self.admissionReservation = admissionReservation
        defer {
            if Self.admissionReservation == admissionReservation {
                Self.admissionReservation = nil
            }
        }
        if controller.snapshot.endpoint?.providerKind == .mtplx {
            // Re-observe loaded identity, engine mode, and capacity at every new inference lease.
            _ = try? await controller.refresh()
        }
        guard let lease = controller.captureReadyInferenceLease() else {
            declineAdmission(
                request.phase,
                observer: measurementObserver,
                barrier: controlledCancellationBarrier
            )
            return .notReady(controller.snapshot.readiness)
        }
        guard let configuration = try? request.boundedProviderConfiguration(lease.configuration) else {
            declineAdmission(
                request.phase,
                observer: measurementObserver,
                barrier: controlledCancellationBarrier
            )
            return .invalidRequest
        }
        let provider = providerFactory(configuration)
        var workerProcessReceipt: Phase2InferenceWorkerProcessReceipt?
        if let workerProcessReceiptObserver {
            guard let receiptProvider = provider
                as? any Phase2InferenceWorkerProcessReceiptProviding,
                  let receipt = try? await receiptProvider.prepareWorkerProcessReceipt(),
                  !Task.isCancelled,
                  controller.isCurrent(lease),
                  Self.workerReceipt(
                    receipt,
                    matches: lease,
                    expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol
                        .assistantR4.manifestDigest
                  ),
                  workerProcessReceiptObserver.acceptWorkerProcessReceipt(receipt),
                  !Task.isCancelled,
                  controller.isCurrent(lease),
                  await receiptProvider.bindProviderConnectionValidator(
                    workerReceipt: receipt,
                    validator: { [weak workerProcessReceiptObserver] connectionReceipt in
                        workerProcessReceiptObserver?.acceptProviderConnectionReceipt(
                            connectionReceipt,
                            workerReceipt: receipt
                        ) ?? false
                    }
                  ),
                  !Task.isCancelled,
                  controller.isCurrent(lease),
                  await receiptProvider.bindProviderDispatchValidator(
                    workerReceipt: receipt,
                    validator: { [weak workerProcessReceiptObserver] dispatchReceipt in
                        workerProcessReceiptObserver?.acceptProviderDispatchReceipt(
                            dispatchReceipt,
                            workerReceipt: receipt
                        ) ?? false
                    }
                  ),
                  !Task.isCancelled,
                  controller.isCurrent(lease)
            else {
                declineAdmission(
                    request.phase,
                    observer: measurementObserver,
                    barrier: controlledCancellationBarrier
                )
                return .providerAuthorityChanged
            }
            workerProcessReceipt = receipt
        }
        guard controller.isCurrent(lease) else {
            declineAdmission(
                request.phase,
                observer: measurementObserver,
                barrier: controlledCancellationBarrier
            )
            return .providerAuthorityChanged
        }
        measurementObserver?.admitted(phase: request.phase)
        let turnID = UUID()
        let cancellationControl = Phase2InferenceTurnCancellationControl(
            phase: request.phase,
            observer: measurementObserver,
            barrier: controlledCancellationBarrier
        )

        let outcome = await withTaskCancellationHandler {
            let task = Task {
                return await Phase2InferenceRunner().run(
                    request: request,
                    provider: provider,
                    measurementObserver: measurementObserver,
                    controlledCancellationBarrier: controlledCancellationBarrier
                )
            }
            cancellationControl.install(task)
            Self.activeTurn = .init(
                id: turnID,
                controllerID: ObjectIdentifier(controller),
                lease: lease,
                cancel: { cancellationControl.cancel() }
            )
            return await task.value
        } onCancel: {
            cancellationControl.cancel()
        }

        defer {
            if Self.activeTurn?.id == turnID {
                Self.activeTurn = nil
            }
        }

        if let controlledCancellationBarrier,
           !controlledCancellationBarrier.hasProvenDispatchBeforeCancellation
        {
            return .providerAuthorityChanged
        }

        if let workerProcessReceipt {
            guard let receiptProvider = provider
                as? any Phase2InferenceWorkerProcessReceiptProviding
            else { return .providerAuthorityChanged }
            let acceptedProviderConnection: Bool
            if outcome.disposition == .cancelled {
                acceptedProviderConnection = true
            } else {
                acceptedProviderConnection = await receiptProvider
                    .acceptedProviderConnectionReceipt(
                    requestID: request.requestID,
                    workerReceipt: workerProcessReceipt
                )
            }
            guard acceptedProviderConnection,
                  await receiptProvider.revalidateWorkerProcessReceipt(workerProcessReceipt)
            else {
                return .providerAuthorityChanged
            }
        }
        guard controller.isCurrent(lease) else {
            return .providerAuthorityChanged
        }
        return .finished(lease: lease, outcome: outcome)
    }

    private func declineAdmission(
        _ phase: Phase2InferencePhase,
        observer: (any Phase2InferenceMeasurementObserving)?,
        barrier: Phase2ControlledCancellationBarrier?
    ) {
        (observer as? any Phase2InferenceAdmissionResolutionObserving)?
            .admissionDeclined(phase: phase)
        barrier?.admissionDeclined()
    }

    private func prepareReconstructionWorkerAuthority(
        for provider: any ReconstructionInferenceProviding,
        lease: Phase2ReadyInferenceLease,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle
    ) async -> ReconstructionWorkerAuthorityPreparation {
        guard let workerProcessReceiptObserver else { return .notRequired }
        guard let receiptProvider = provider
            as? any ReconstructionInferenceWorkerProcessReceiptProviding,
              let receipt = try? await receiptProvider.prepareWorkerProcessReceipt(),
              !Task.isCancelled,
              controller.isCurrent(lease),
              Self.workerReceipt(
                receipt,
                matches: lease,
                expectedProtocolManifestDigest: protocolBundle.manifestDigest
              ),
              workerProcessReceiptObserver.acceptWorkerProcessReceipt(receipt),
              !Task.isCancelled,
              controller.isCurrent(lease),
              await receiptProvider.bindProviderConnectionValidator(
                workerReceipt: receipt,
                validator: { [weak workerProcessReceiptObserver] connectionReceipt in
                    workerProcessReceiptObserver?.acceptProviderConnectionReceipt(
                        connectionReceipt,
                        workerReceipt: receipt
                    ) ?? false
                }
              ),
              !Task.isCancelled,
              controller.isCurrent(lease),
              await receiptProvider.bindProviderDispatchValidator(
                workerReceipt: receipt,
                validator: { [weak workerProcessReceiptObserver] dispatchReceipt in
                    workerProcessReceiptObserver?.acceptProviderDispatchReceipt(
                        dispatchReceipt,
                        workerReceipt: receipt
                    ) ?? false
                }
              ),
              !Task.isCancelled,
              controller.isCurrent(lease)
        else { return .rejected }
        return .prepared(provider: receiptProvider, receipt: receipt)
    }

    private func reconstructionWorkerAuthorityRemainsValid(
        _ preparation: ReconstructionWorkerAuthorityPreparation,
        lease: Phase2ReadyInferenceLease,
        requestID: UUID,
        requiresAcceptedConnection: Bool
    ) async -> Bool {
        switch preparation {
        case .notRequired:
            return true
        case .rejected:
            return false
        case .prepared(let provider, let receipt):
            guard [Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest,
                   Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                   Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest]
                .contains(receipt.protocolManifestDigest), Self.workerReceipt(
                receipt,
                matches: lease,
                expectedProtocolManifestDigest: receipt.protocolManifestDigest
            ) else { return false }
            if requiresAcceptedConnection,
               !(await provider.acceptedProviderConnectionReceipt(
                    requestID: requestID,
                    workerReceipt: receipt
               ))
            {
                return false
            }
            return await provider.revalidateWorkerProcessReceipt(receipt)
        }
    }

    private static func workerReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt,
        matches lease: Phase2ReadyInferenceLease,
        expectedProtocolManifestDigest: String
    ) -> Bool {
        receipt.profileID == lease.configuration.profileID
            && receipt.configurationGeneration == lease.configuration.generation
            && receipt.protocolManifestDigest == expectedProtocolManifestDigest
    }

    private func providerRevisionDidChange(to revision: UInt64) {
        guard let activeTurn = Self.activeTurn,
              activeTurn.controllerID == ObjectIdentifier(controller),
              activeTurn.lease.providerRevision != revision
        else { return }
        activeTurn.cancel()
    }
}

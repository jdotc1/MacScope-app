import CryptoKit
import Foundation

/// Payload-free qualification timing seam. Implementations must be nonthrowing and must never
/// influence inference admission, event validation, provider cancellation, or the returned outcome.
protocol Phase2InferenceMeasurementObserving: Sendable {
    func admitted(phase: Phase2InferencePhase)
    func generationBegan(phase: Phase2InferencePhase)
    func acceptedSemantic(phase: Phase2InferencePhase)
    func acceptedEvent(phase: Phase2InferencePhase)
    func usageAccepted(phase: Phase2InferencePhase, usage: Phase2ProviderUsage)
    func cancellationBegan(phase: Phase2InferencePhase)
    func providerDrained(phase: Phase2InferencePhase)
}

/// Optional admission handshake used only by controlled qualification cancellation. It lets the
/// app wait for exact provider admission without sleeps, retries, or payload authority.
protocol Phase2InferenceAdmissionResolutionObserving:
    Phase2InferenceMeasurementObserving
{
    func admissionDeclined(phase: Phase2InferencePhase)
}

struct Phase2InferenceRunner: Sendable {
    private let acceptedProtocolVersion: Phase2InferenceProtocolVersion

    init(
        acceptedProtocolVersion: Phase2InferenceProtocolVersion = .init(
            rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
        )
    ) {
        self.acceptedProtocolVersion = acceptedProtocolVersion
    }

    func run(
        request: Phase2InferenceRequest,
        provider: any Phase2InferenceProviding,
        measurementObserver: (any Phase2InferenceMeasurementObserving)? = nil,
        controlledCancellationBarrier: Phase2ControlledCancellationBarrier? = nil
    ) async -> Phase2InferenceOutcome {
        guard Self.requestIsValid(
            request,
            acceptedProtocolVersion: acceptedProtocolVersion
        ) else {
            return .init(
                disposition: .protocolViolation,
                previewDeltas: [],
                toolProposals: [],
                shellProposals: [],
                finalCandidate: nil,
                providerUsage: nil,
                violation: .invalidRequest,
                acceptedEventCount: 0,
                cumulativeEventBytes: 0
            )
        }

        let cancellation = Phase2InferenceCancellationLatch()
        let state = Phase2InferenceState(
            request: request,
            cancellation: cancellation,
            measurementObserver: measurementObserver
        )
        let (signals, signalContinuation) = AsyncStream.makeStream(
            of: Phase2InferenceProviderSignal.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        measurementObserver?.generationBegan(phase: request.phase)
        let providerTask = Task {
            defer { controlledCancellationBarrier?.providerDidFinish() }
            do {
                if let controlledCancellationBarrier {
                    guard let dispatchingProvider = provider
                        as? any Phase2InferenceDispatchReceiptProviding
                    else {
                        throw Phase2InferenceControlledCancellationError
                            .dispatchReceiptUnavailable
                    }
                    try await dispatchingProvider.run(
                        request: request,
                        onDispatched: { receipt in
                            controlledCancellationBarrier.providerDidDispatch(receipt)
                        },
                        emit: { event in
                            await controlledCancellationBarrier
                                .waitForCancellationBeforeRejectingProviderEvent()
                            throw CancellationError()
                        }
                    )
                } else {
                    try await provider.run(request: request) { event in
                        try await state.accept(event)
                    }
                }
                signalContinuation.yield(.returned)
            } catch is Phase2ProviderOutputLimitReached {
                signalContinuation.yield(.outputLimitReached)
            } catch {
                signalContinuation.yield(.failed)
            }
            signalContinuation.finish()
        }

        let signal = await withTaskCancellationHandler {
            var iterator = signals.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            guard cancellation.begin() else { return }
            measurementObserver?.cancellationBegan(phase: request.phase)
            providerTask.cancel()
            signalContinuation.yield(.cancelled)
            signalContinuation.finish()
        }

        if Task.isCancelled || cancellation.isCancelled || signal == .cancelled {
            if cancellation.begin() {
                measurementObserver?.cancellationBegan(phase: request.phase)
                providerTask.cancel()
            }
            await state.cancel()
            await provider.cancel(requestID: request.requestID)
            await providerTask.value
            measurementObserver?.providerDrained(phase: request.phase)
            return await state.outcome()
        }

        switch signal {
        case .returned:
            await state.providerReturned()
        case .outputLimitReached:
            await state.providerReachedOutputLimit()
        case .failed, .none:
            await state.providerFailed()
        case .cancelled:
            break
        }

        await providerTask.value
        measurementObserver?.providerDrained(phase: request.phase)
        return await state.outcome()
    }

    static func requestIsValid(_ request: Phase2InferenceRequest) -> Bool {
        requestIsValid(
            request,
            acceptedProtocolVersion: .init(
                rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
            )
        )
    }

    private static func requestIsValid(
        _ request: Phase2InferenceRequest,
        acceptedProtocolVersion: Phase2InferenceProtocolVersion
    ) -> Bool {
        let protocolIsAccepted = switch request.phase {
        case .shellContinuation: request.protocolVersion == .v6
        case .toolSelection, .finalization: request.protocolVersion == acceptedProtocolVersion
        }
        guard protocolIsAccepted,
              request.workspace.document == request.document,
              request.limits.isValid,
              !request.userGoal.isEmpty,
              request.userGoal.utf8.count <= request.limits.maximumGoalBytes,
              request.groundedContext.records.count <= Phase2GroundedContextLimits.maximum.maximumRecords,
              request.groundedContext.canonicalBytes.count <= Phase2GroundedContextLimits.maximum.maximumCanonicalBytes,
              request.toolHandles.count <= request.limits.maximumToolHandles,
              Set(request.toolHandles.map(\.handleID)).count == request.toolHandles.count,
              Set(request.toolHandles.filter { $0.operationID != .reaResultsGet }.map(\.operationID)).count
                == request.toolHandles.filter { $0.operationID != .reaResultsGet }.count,
              request.toolHandles.allSatisfy({
                  Phase2ReadOperationID.allProviderVisible.contains($0.operationID)
              })
        else {
            return false
        }

        switch request.phase {
        case .toolSelection:
            guard !request.toolHandles.isEmpty,
                  request.shellContinuationCoordinate == nil else { return false }
        case .finalization:
            guard request.toolHandles.isEmpty,
                  request.shellContinuationCoordinate == nil else { return false }
        case .shellContinuation:
            guard request.toolHandles.isEmpty,
                  let coordinate = request.shellContinuationCoordinate,
                  coordinate.isIntegrityValid,
                  coordinate.workspaceID == request.workspace.instanceID,
                  coordinate.conversationID == request.sessionID,
                  coordinate.inferenceTurnID == request.turnID,
                  coordinate.continuationRequestID == request.requestID,
                  coordinate.productionManifestIdentity
                    == Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity
            else { return false }
        }

        let evidenceIDs = request.groundedContext.records.map(\.evidenceID)
        guard Set(evidenceIDs).count == evidenceIDs.count,
              request.groundedContext.records.allSatisfy({
                  $0.precondition.workspace == request.workspace
              }),
              let manifest = try? JSONDecoder().decode(
                  Phase2GroundedContextManifest.self,
                  from: request.groundedContext.canonicalBytes
              ),
              manifest.records == request.groundedContext.records,
              manifest.omissions == request.groundedContext.omissions
        else {
            return false
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let canonicalBytes = try? encoder.encode(manifest),
              canonicalBytes == request.groundedContext.canonicalBytes
        else {
            return false
        }

        let digest = SHA256.hash(data: canonicalBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == request.groundedContext.digest
    }
}

private enum Phase2InferenceControlledCancellationError: Error {
    case dispatchReceiptUnavailable
}

private enum Phase2InferenceProviderSignal: Sendable {
    case returned
    case outputLimitReached
    case failed
    case cancelled
}

private final class Phase2InferenceCancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        cancelled = true
        return true
    }
}

private actor Phase2InferenceState {
    private let request: Phase2InferenceRequest
    private let cancellation: Phase2InferenceCancellationLatch
    private let knownEvidenceIDs: Set<UUID>
    private let knownOperationsByHandleID: [UUID: Phase2ReadOperationID]
    private let measurementObserver: (any Phase2InferenceMeasurementObserving)?

    private var nextSequence: UInt64 = 1
    private var acceptedEventCount = 0
    private var cumulativeEventBytes = 0
    private var previewDeltas: [String] = []
    private var toolProposals: [Phase2InferenceToolProposal] = []
    private var shellProposals: [Phase2AIShellCommandProposal] = []
    private var shellProposalIDs: Set<UUID> = []
    private var debuggerActionProposals: [Phase2AIDebuggerActionProposal] = []
    private var debuggerActionProposalIDs: Set<UUID> = []
    private var callIDs: Set<Phase2ProviderToolCallID> = []
    private var usedHandleIDs: Set<UUID> = []
    private var finalCandidate: Phase2InferenceFinalCandidate?
    private var providerUsage: Phase2ProviderUsage?
    private var terminal: (Phase2InferenceDisposition, Phase2InferenceViolation?)?

    init(
        request: Phase2InferenceRequest,
        cancellation: Phase2InferenceCancellationLatch,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?
    ) {
        self.request = request
        self.cancellation = cancellation
        self.measurementObserver = measurementObserver
        knownEvidenceIDs = Set(request.groundedContext.records.map(\.evidenceID))
        knownOperationsByHandleID = Dictionary(
            uniqueKeysWithValues: request.toolHandles.map { ($0.handleID, $0.operationID) }
        )
    }

    func accept(_ event: Phase2InferenceEvent) throws {
        guard terminal == nil else {
            throw Phase2InferenceViolation.postTerminalEvent
        }
        guard !cancellation.isCancelled else {
            terminal = (.cancelled, nil)
            throw Phase2InferenceViolation.postTerminalEvent
        }

        guard event.protocolVersion == request.protocolVersion,
              event.sessionID == request.sessionID,
              event.turnID == request.turnID,
              event.requestID == request.requestID,
              event.document == request.document,
              event.workspace == request.workspace,
              event.lifecycleRevision == request.lifecycleRevision
        else {
            try reject(.identityMismatch)
        }
        guard event.phase == request.phase else {
            try reject(.phaseMismatch)
        }

        guard event.sequence == nextSequence else {
            try reject(.sequenceMismatch(expected: nextSequence, actual: event.sequence))
        }
        guard event.estimatedBytes <= request.limits.maximumEventBytes else {
            try reject(.eventTooLarge, disposition: .limitExceeded)
        }
        guard acceptedEventCount < request.limits.maximumEvents else {
            try reject(.eventCountLimitExceeded, disposition: .limitExceeded)
        }
        guard cumulativeEventBytes + event.estimatedBytes <= request.limits.maximumCumulativeEventBytes else {
            try reject(.cumulativeEventLimitExceeded, disposition: .limitExceeded)
        }

        switch (request.phase, event.body) {
        case (.toolSelection, .contentDelta),
             (.toolSelection, .finalCandidate),
             (.toolSelection, .shellProposal),
             (.toolSelection, .debuggerActionProposal),
             (.toolSelection, .completed),
             (.finalization, .toolProposal),
             (.finalization, .awaitingTools),
             (.shellContinuation, .contentDelta),
             (.shellContinuation, .toolProposal),
             (.shellContinuation, .shellProposal),
             (.shellContinuation, .debuggerActionProposal),
             (.shellContinuation, .awaitingTools):
            try reject(.eventNotAllowedInPhase(request.phase))

        case (.finalization, .contentDelta(let text)):
            guard providerUsage == nil else {
                try reject(.semanticOutputAfterProviderUsage)
            }
            previewDeltas.append(text)

        case (.toolSelection, .toolProposal(let proposal)):
            guard providerUsage == nil else {
                try reject(.semanticOutputAfterProviderUsage)
            }
            guard toolProposals.count < request.limits.maximumToolProposals else {
                try reject(.toolProposalLimitExceeded, disposition: .limitExceeded)
            }
            guard callIDs.insert(proposal.callID).inserted else {
                try reject(.duplicateCallID)
            }
            guard let offeredOperation = knownOperationsByHandleID[proposal.handleID] else {
                try reject(.unknownToolHandle(proposal.handleID))
            }
            guard offeredOperation == proposal.operationID else {
                try reject(.toolOperationMismatch(proposal.handleID, proposal.operationID))
            }
            guard Self.functionName(for: proposal.operationID) == proposal.functionName else {
                try reject(.toolFunctionMismatch(proposal.functionName, proposal.operationID))
            }
            guard usedHandleIDs.insert(proposal.handleID).inserted else {
                try reject(.repeatedToolHandle(proposal.handleID))
            }
            toolProposals.append(proposal)

        case (.finalization, .shellProposal(let proposal)):
            guard [.v4, .v5, .v6].contains(request.protocolVersion) else {
                try reject(.eventNotAllowedInProtocolVersion(request.protocolVersion))
            }
            guard providerUsage == nil else {
                try reject(.semanticOutputAfterProviderUsage)
            }
            guard shellProposals.count < request.limits.maximumToolProposals else {
                try reject(.shellProposalLimitExceeded, disposition: .limitExceeded)
            }
            guard shellProposalIDs.insert(proposal.proposalID).inserted else {
                try reject(.duplicateShellProposal)
            }
            guard Phase2AIShellProposalValidator.validate(proposal).isAccepted else {
                try reject(.invalidShellProposal)
            }
            shellProposals.append(proposal)

        case (.finalization, .debuggerActionProposal(let proposal)):
            guard [.v4, .v5, .v6].contains(request.protocolVersion) else {
                try reject(.eventNotAllowedInProtocolVersion(request.protocolVersion))
            }
            guard providerUsage == nil else {
                try reject(.semanticOutputAfterProviderUsage)
            }
            guard debuggerActionProposals.count < request.limits.maximumToolProposals else {
                try reject(.debuggerActionProposalLimitExceeded, disposition: .limitExceeded)
            }
            guard debuggerActionProposalIDs.insert(proposal.proposalID).inserted else {
                try reject(.duplicateDebuggerActionProposal)
            }
            guard Phase2AIDebuggerProposalValidator.validate(proposal).isAccepted else {
                try reject(.invalidDebuggerActionProposal)
            }
            debuggerActionProposals.append(proposal)

        case (.finalization, .finalCandidate(let candidate)),
             (.shellContinuation, .finalCandidate(let candidate)):
            guard providerUsage == nil else {
                try reject(.semanticOutputAfterProviderUsage)
            }
            guard finalCandidate == nil else {
                try reject(.duplicateFinalCandidate)
            }
            let kindMaximumTextBytes = switch candidate.kind {
            case .answer: 60_000
            case .insufficientEvidence: 4_096
            }
            guard !candidate.text.isEmpty,
                  candidate.text.utf8.count <= min(
                      request.limits.maximumFinalTextBytes,
                      kindMaximumTextBytes
                  ),
                  candidate.evidenceIDs.count <= request.limits.maximumEvidenceReferences
            else {
                try reject(.invalidFinalCandidate)
            }
            switch candidate.kind {
            case .answer:
                guard !candidate.evidenceIDs.isEmpty else {
                    try reject(.invalidFinalCandidate)
                }
            case .insufficientEvidence:
                guard candidate.evidenceIDs.isEmpty else {
                    try reject(.invalidFinalCandidate)
                }
            }
            var seenEvidenceIDs: Set<UUID> = []
            for evidenceID in candidate.evidenceIDs {
                guard seenEvidenceIDs.insert(evidenceID).inserted else {
                    try reject(.duplicateEvidenceID(evidenceID))
                }
                guard knownEvidenceIDs.contains(evidenceID) else {
                    try reject(.unknownEvidenceID(evidenceID))
                }
            }
            finalCandidate = candidate

        case (.toolSelection, .usage(let usage)):
            guard request.protocolVersion.requiresProviderUsage else {
                try reject(.eventNotAllowedInProtocolVersion(request.protocolVersion))
            }
            guard !toolProposals.isEmpty else {
                try reject(.usageBeforeSemanticOutput)
            }
            guard providerUsage == nil else {
                try reject(.duplicateProviderUsage)
            }
            providerUsage = usage

        case (.finalization, .usage(let usage)),
             (.shellContinuation, .usage(let usage)):
            guard request.protocolVersion.requiresProviderUsage else {
                try reject(.eventNotAllowedInProtocolVersion(request.protocolVersion))
            }
            guard finalCandidate != nil else {
                try reject(.usageBeforeSemanticOutput)
            }
            guard providerUsage == nil else {
                try reject(.duplicateProviderUsage)
            }
            providerUsage = usage

        case (.toolSelection, .awaitingTools):
            guard !toolProposals.isEmpty else {
                try reject(.completionBeforeToolProposal)
            }
            guard !request.protocolVersion.requiresProviderUsage || providerUsage != nil else {
                try reject(.completionBeforeProviderUsage)
            }

        case (.finalization, .completed),
             (.shellContinuation, .completed):
            guard finalCandidate != nil else {
                try reject(.completionBeforeFinal)
            }
            guard !request.protocolVersion.requiresProviderUsage || providerUsage != nil else {
                try reject(.completionBeforeProviderUsage)
            }
        }

        acceptedEventCount += 1
        cumulativeEventBytes += event.estimatedBytes
        nextSequence += 1

        switch event.body {
        case .contentDelta(let text) where !text.isEmpty:
            measurementObserver?.acceptedSemantic(phase: request.phase)
        case .toolProposal, .shellProposal, .debuggerActionProposal, .finalCandidate:
            measurementObserver?.acceptedSemantic(phase: request.phase)
        case .contentDelta:
            break
        case .usage(let usage):
            measurementObserver?.usageAccepted(phase: request.phase, usage: usage)
        case .awaitingTools, .completed:
            break
        }
        measurementObserver?.acceptedEvent(phase: request.phase)

        if case .awaitingTools = event.body {
            terminal = (.awaitingTools, nil)
        } else if case .completed = event.body {
            terminal = (.completed, nil)
        }
    }

    func providerReturned() {
        guard terminal == nil else { return }
        terminal = (.interrupted, .providerReturnedWithoutCompletion)
    }

    func providerFailed() {
        guard terminal == nil else { return }
        terminal = (.providerFailed, nil)
    }

    func providerReachedOutputLimit() {
        guard terminal == nil else { return }
        terminal = (.limitExceeded, .providerOutputLimitReached)
    }

    func cancel() {
        guard terminal == nil else { return }
        terminal = (.cancelled, nil)
    }

    func outcome() -> Phase2InferenceOutcome {
        let resolvedTerminal = terminal ?? (.interrupted, .providerReturnedWithoutCompletion)
        return .init(
            disposition: resolvedTerminal.0,
            previewDeltas: previewDeltas,
            toolProposals: toolProposals,
            shellProposals: shellProposals,
            debuggerActionProposals: debuggerActionProposals,
            finalCandidate: finalCandidate,
            providerUsage: providerUsage,
            violation: resolvedTerminal.1,
            acceptedEventCount: acceptedEventCount,
            cumulativeEventBytes: cumulativeEventBytes
        )
    }

    private func reject(
        _ violation: Phase2InferenceViolation,
        disposition: Phase2InferenceDisposition = .protocolViolation
    ) throws -> Never {
        terminal = (disposition, violation)
        throw violation
    }

    private static func functionName(for operation: Phase2ReadOperationID) -> String? {
        switch operation {
        case .workspaceSummary: "macscope_workspace_summary_v1"
        case .selectionExplain: "macscope_selection_explain_v1"
        case .functionReview: "macscope_function_review_v1"
        case .applicationGraphSummary: "macscope_application_graph_summary_v1"
        case .decompilerNativeResult: "macscope_native_decompilation_v1"
        case .decompilerMacScopeResult: "macscope_decompilation_v1"
        case .decompilerCompare: "macscope_decompiler_compare_v1"
        case .reaResultsList: "macscope_rea_results_list_v1"
        case .reaResultsGet: "macscope_rea_results_get_v1"
        default: nil
        }
    }
}

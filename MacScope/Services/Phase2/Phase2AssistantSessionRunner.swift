import CryptoKit
import Foundation

enum Phase2AssistantIntent: String, CaseIterable, Hashable, Sendable {
    case askMacScope
    case explainSelection
    case reviewFunction

    var title: String {
        switch self {
        case .askMacScope: "Ask MacScope"
        case .explainSelection: "Explain Selection"
        case .reviewFunction: "Review Function"
        }
    }

    var operation: Phase2ReadOperationID {
        switch self {
        case .askMacScope: .workspaceSummary
        case .explainSelection: .selectionExplain
        case .reviewFunction: .functionReview
        }
    }

    var requiredOperations: [Phase2ReadOperationID] {
        [operation]
    }

    var supplementalOperations: [Phase2ReadOperationID] {
        switch self {
        case .askMacScope:
            return [.applicationGraphSummary]
        case .reviewFunction:
            return [.functionCallSites]
        case .explainSelection:
            return []
        }
    }

    func defaultGoal(userGoal: String) -> String {
        let trimmed = userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        switch self {
        case .askMacScope:
            return "Answer using only the current MacScope workspace evidence."
        case .explainSelection:
            return "Explain the current selection using only cited MacScope evidence."
        case .reviewFunction:
            return "Review the current function using only cited MacScope evidence."
        }
    }
}

enum Phase2AssistantSessionFailure: Equatable, Sendable {
    case readUnavailable(operation: Phase2ReadOperationID, reason: Phase2ReadUnavailableReason)
    case readRejected(operation: Phase2ReadOperationID, disposition: Phase2ReadDisposition)
    case evidenceRejected(operation: Phase2ReadOperationID, disposition: Phase2ReadDisposition)
    case groundedContextUnavailable
    case groundedContextFailed(String)
    case inferenceNotReady(Phase2LocalAIProviderReadiness)
    case inferenceBusy
    case inferenceInvalidRequest
    case providerAuthorityChanged
}

/// Payload-free rejection context. Stage labels describe the observed app branch, not a
/// claim about whether an earlier phase dispatched or produced provider output.
struct Phase2AssistantRequestRejection: Equatable, Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case turnPreparation = "turn preparation"
        case toolPlanning = "tool planning"
        case toolSelectionAdmission = "tool-selection admission"
        case toolSelectionOutcome = "tool-selection outcome"
        case nativeReadResolution = "native read resolution"
        case finalizationPreparation = "finalization preparation"
        case finalizationAdmission = "finalization admission"
        case finalizationOutcome = "finalization outcome"
    }
    let stage: Stage
    let reasonCode: String

    static func toolPlan(_ error: Error) -> Self {
        guard let error = error as? Phase2AssistantToolSelectionPlanError else {
            return .init(stage: .toolPlanning, reasonCode: "unclassifiedPlanError")
        }
        let code: String
        switch error {
        case .noToolOperations: code = "noToolOperations"
        case .unsupportedOperation: code = "unsupportedOperation"
        case .duplicateOperation: code = "duplicateOperation"
        case .invalidHandle: code = "invalidHandle"
        case .duplicateHandle: code = "duplicateHandle"
        case .registryProjectionFailed: code = "registryProjectionFailed"
        }
        return .init(stage: .toolPlanning, reasonCode: code)
    }

    static func outcome(stage: Stage, _ outcome: Phase2InferenceOutcome) -> Self {
        // Only the closed enum case name is retained. Associated IDs, function names and text
        // are deliberately excluded from this diagnostic channel.
        let violation = outcome.violation.map(violationTag) ?? "none"
        return .init(stage: stage,
            reasonCode: "disposition=\(outcome.disposition); violation=\(violation)")
    }

    private static func violationTag(_ violation: Phase2InferenceViolation) -> String {
        switch violation {
        case .invalidRequest: "invalidRequest"
        case .identityMismatch: "identityMismatch"
        case .sequenceMismatch: "sequenceMismatch"
        case .eventTooLarge: "eventTooLarge"
        case .cumulativeEventLimitExceeded: "cumulativeEventLimitExceeded"
        case .eventCountLimitExceeded: "eventCountLimitExceeded"
        case .phaseMismatch: "phaseMismatch"
        case .eventNotAllowedInPhase: "eventNotAllowedInPhase"
        case .eventNotAllowedInProtocolVersion: "eventNotAllowedInProtocolVersion"
        case .duplicateCallID: "duplicateCallID"
        case .unknownToolHandle: "unknownToolHandle"
        case .toolOperationMismatch: "toolOperationMismatch"
        case .toolFunctionMismatch: "toolFunctionMismatch"
        case .repeatedToolHandle: "repeatedToolHandle"
        case .toolProposalLimitExceeded: "toolProposalLimitExceeded"
        case .shellProposalLimitExceeded: "shellProposalLimitExceeded"
        case .duplicateShellProposal: "duplicateShellProposal"
        case .invalidShellProposal: "invalidShellProposal"
        case .debuggerActionProposalLimitExceeded: "debuggerActionProposalLimitExceeded"
        case .duplicateDebuggerActionProposal: "duplicateDebuggerActionProposal"
        case .invalidDebuggerActionProposal: "invalidDebuggerActionProposal"
        case .duplicateFinalCandidate: "duplicateFinalCandidate"
        case .usageBeforeSemanticOutput: "usageBeforeSemanticOutput"
        case .semanticOutputAfterProviderUsage: "semanticOutputAfterProviderUsage"
        case .duplicateProviderUsage: "duplicateProviderUsage"
        case .invalidFinalCandidate: "invalidFinalCandidate"
        case .unknownEvidenceID: "unknownEvidenceID"
        case .duplicateEvidenceID: "duplicateEvidenceID"
        case .completionBeforeFinal: "completionBeforeFinal"
        case .completionBeforeToolProposal: "completionBeforeToolProposal"
        case .completionBeforeProviderUsage: "completionBeforeProviderUsage"
        case .duplicateCompletion: "duplicateCompletion"
        case .postTerminalEvent: "postTerminalEvent"
        case .providerReturnedWithoutCompletion: "providerReturnedWithoutCompletion"
        case .providerOutputLimitReached: "providerOutputLimitReached"
        }
    }
}

struct Phase2AssistantContextOptions: Equatable, Sendable {
    var includeApplicationGraphContext: Bool
    var useProviderVisibleToolSelection: Bool
    var shellExecutionID: UUID?
    var debuggerExecutionID: UUID?

    init(
        includeApplicationGraphContext: Bool = true,
        useProviderVisibleToolSelection: Bool = false,
        shellExecutionID: UUID? = nil,
        debuggerExecutionID: UUID? = nil
    ) {
        self.includeApplicationGraphContext = includeApplicationGraphContext
        self.useProviderVisibleToolSelection = useProviderVisibleToolSelection
        self.shellExecutionID = shellExecutionID
        self.debuggerExecutionID = debuggerExecutionID
    }

    static let `default` = Self()
}

struct Phase2AssistantConversationTurnContext: Equatable, Sendable {
    let conversationID: UUID
    let sessionID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let priorTurns: [Phase2AssistantProviderVisiblePriorTurn]
}

struct Phase2AssistantSessionResult: Sendable {
    let intent: Phase2AssistantIntent
    let toolSelectionRequest: Phase2InferenceRequest?
    let toolSelectionOutcome: Phase2InferenceOutcome?
    let request: Phase2InferenceRequest?
    let groundedContext: Phase2GroundedContext?
    let readExecution: Phase2ReadExecution?
    let readExecutions: [Phase2ReadExecution]
    let inferenceOutcome: Phase2InferenceOutcome?
    /// Exact provider authority revision that produced the accepted finalization outcome.
    /// Same-turn continuation freezes this value; it is never resampled from mutable readiness.
    let providerRevision: UInt64?
    let failure: Phase2AssistantSessionFailure?
    let requestRejection: Phase2AssistantRequestRejection?
    /// Addresses the final answer quotes that the accepted evidence does not support, left
    /// after one repair turn. A non-empty list means the answer is not fully grounded.
    let unverifiedAddresses: [String]

    init(
        intent: Phase2AssistantIntent,
        toolSelectionRequest: Phase2InferenceRequest? = nil,
        toolSelectionOutcome: Phase2InferenceOutcome? = nil,
        request: Phase2InferenceRequest?,
        groundedContext: Phase2GroundedContext?,
        readExecution: Phase2ReadExecution?,
        readExecutions: [Phase2ReadExecution],
        inferenceOutcome: Phase2InferenceOutcome?,
        providerRevision: UInt64? = nil,
        failure: Phase2AssistantSessionFailure?,
        unverifiedAddresses: [String] = [],
        requestRejection: Phase2AssistantRequestRejection? = nil
    ) {
        self.intent = intent
        self.toolSelectionRequest = toolSelectionRequest
        self.unverifiedAddresses = unverifiedAddresses
        self.toolSelectionOutcome = toolSelectionOutcome
        self.request = request
        self.groundedContext = groundedContext
        self.readExecution = readExecution
        self.readExecutions = readExecutions
        self.inferenceOutcome = inferenceOutcome
        self.providerRevision = providerRevision
        self.failure = failure
        self.requestRejection = requestRejection
    }

    var isAcceptedFinalAnswer: Bool {
        guard failure == nil,
              inferenceOutcome?.disposition == .completed,
              let candidate = inferenceOutcome?.finalCandidate,
              !candidate.evidenceIDs.isEmpty,
              let groundedContext
        else { return false }

        let knownEvidenceIDs = Set(groundedContext.records.map(\.evidenceID))
        return Set(candidate.evidenceIDs).isSubset(of: knownEvidenceIDs)
    }

    /// An accepted answer whose every quoted address is backed by the accepted evidence.
    /// Only such an answer may stage proposals.
    var isFullyGrounded: Bool {
        isAcceptedFinalAnswer && unverifiedAddresses.isEmpty
    }
}

@MainActor
protocol Phase2AssistantInferenceCoordinating: AnyObject {
    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult
    /// Brings provider readiness up to date before the user runs a turn.
    func prepareProviderForAssistant() async
}

extension Phase2AssistantInferenceCoordinating {
    func prepareProviderForAssistant() async {}
}

extension Phase2ReadyInferenceCoordinator: Phase2AssistantInferenceCoordinating {
    func prepareProviderForAssistant() async {
        await refreshProviderIfNotReady()
    }
}

/// App-owned R1 composition for one finalization-only assistant turn.
///
/// The runner executes the native read plan selected by the user intent, compiles accepted
/// evidence into grounded context, and then dispatches a finalization request with no
/// provider-visible tool handles. Supplemental reads can enrich broad Ask turns without making
/// provider-visible tool selection broader. The runner owns no persistence, provider lifecycle,
/// XPC, debugger, or workspace mutation authority.
@MainActor
struct Phase2AssistantSessionRunner {
    private let sessionIDProvider: @MainActor () -> UUID
    private let turnIDProvider: @MainActor () -> UUID
    private let requestIDProvider: @MainActor () -> UUID
    private let conversationIDProvider: @MainActor () -> UUID

    init(
        sessionIDProvider: @escaping @MainActor () -> UUID = { UUID() },
        turnIDProvider: @escaping @MainActor () -> UUID = { UUID() },
        requestIDProvider: @escaping @MainActor () -> UUID = { UUID() },
        conversationIDProvider: @escaping @MainActor () -> UUID = { UUID() }
    ) {
        self.sessionIDProvider = sessionIDProvider
        self.turnIDProvider = turnIDProvider
        self.requestIDProvider = requestIDProvider
        self.conversationIDProvider = conversationIDProvider
    }

    func run(
        intent: Phase2AssistantIntent,
        userGoal: String,
        store: WorkspaceStore,
        coordinator: any Phase2AssistantInferenceCoordinating,
        turnContext: Phase2AssistantConversationTurnContext,
        contextOptions: Phase2AssistantContextOptions = .default,
        nativeDecompilerState: NativeDecompilerPresentationState = .idle,
        readLimits: Phase2ReadLimits = .maximum,
        contextLimits: Phase2GroundedContextLimits = .maximum,
        inferenceLimits: Phase2InferenceLimits = .assistantMaximum
    ) async -> Phase2AssistantSessionResult {
        await run(
            intent: intent,
            userGoal: userGoal,
            store: store,
            coordinator: coordinator,
            conversationID: turnContext.conversationID,
            sessionID: turnContext.sessionID,
            inferenceTurnID: turnContext.inferenceTurnID,
            turnSequence: turnContext.turnSequence,
            priorTurns: turnContext.priorTurns,
            contextOptions: contextOptions,
            nativeDecompilerState: nativeDecompilerState,
            readLimits: readLimits,
            contextLimits: contextLimits,
            inferenceLimits: inferenceLimits
        )
    }

    func run(
        intent: Phase2AssistantIntent,
        userGoal: String,
        store: WorkspaceStore,
        coordinator: any Phase2AssistantInferenceCoordinating,
        conversationID explicitConversationID: UUID? = nil,
        sessionID explicitSessionID: UUID? = nil,
        inferenceTurnID explicitInferenceTurnID: UUID? = nil,
        turnSequence: UInt64 = 1,
        priorTurns: [Phase2AssistantProviderVisiblePriorTurn] = [],
        contextOptions: Phase2AssistantContextOptions = .default,
        nativeDecompilerState: NativeDecompilerPresentationState = .idle,
        readLimits: Phase2ReadLimits = .maximum,
        contextLimits: Phase2GroundedContextLimits = .maximum,
        inferenceLimits: Phase2InferenceLimits = .assistantMaximum
    ) async -> Phase2AssistantSessionResult {
        let conversationID = explicitConversationID ?? conversationIDProvider()
        let sessionID = explicitSessionID ?? sessionIDProvider()
        let turnID = explicitInferenceTurnID ?? turnIDProvider()
        guard Self.isValidTurnAuthority(
            conversationID: conversationID,
            sessionID: sessionID,
            turnID: turnID,
            turnSequence: turnSequence,
            priorTurns: priorTurns
        ) else {
            return failedResult(
                intent: intent,
                toolSelectionRequest: nil,
                toolSelectionOutcome: nil,
                executions: [],
                failure: .inferenceInvalidRequest,
                requestRejection: .init(stage: .turnPreparation, reasonCode: "invalidTurnIdentity")
            )
        }
        guard store.beginPhase2AssistantTurn(conversationID: conversationID) else {
            return failedResult(
                intent: intent,
                toolSelectionRequest: nil,
                toolSelectionOutcome: nil,
                executions: [],
                failure: .inferenceBusy
            )
        }
        defer { store.endPhase2AssistantTurn(conversationID: conversationID) }
        var executions: [Phase2ReadExecution] = []
        var acceptedInvocationIDs: [UUID] = []
        var acceptedDebuggerReads: [Phase2DebuggerReadOperationResult] = []
        var toolSelectionRequest: Phase2InferenceRequest?
        var toolSelectionOutcome: Phase2InferenceOutcome?
        var toolSelectionProviderLease: Phase2ReadyInferenceLease?
        var toolSelectionRequestID: UUID?
        let debuggerReadPlan = intent == .askMacScope
            ? store.phase2DebuggerReadEvidenceSnapshot.flatMap {
                Phase2DebuggerReadOperationPlan(evidence: $0)
            }
            : nil

        let requiredReads: [SelectedRead]
        if contextOptions.useProviderVisibleToolSelection {
            let selectionRequestID = requestIDProvider()
            guard Self.isValidRequestID(
                selectionRequestID,
                excluding: [conversationID, sessionID, turnID]
            ) else {
                return failedResult(
                    intent: intent,
                    toolSelectionRequest: nil,
                    toolSelectionOutcome: nil,
                    executions: [],
                    failure: .inferenceInvalidRequest,
                    requestRejection: .init(stage: .toolPlanning, reasonCode: "invalidSelectionRequestIdentity")
                )
            }
            toolSelectionRequestID = selectionRequestID
            let decision = await runProviderVisibleToolSelection(
                intent: intent,
                userGoal: userGoal,
                store: store,
                coordinator: coordinator,
                sessionID: sessionID,
                turnID: turnID,
                requestID: selectionRequestID,
                contextLimits: contextLimits,
                inferenceLimits: inferenceLimits,
                debuggerPlan: debuggerReadPlan,
                readLimits: readLimits
            )
            toolSelectionRequest = decision.request
            toolSelectionOutcome = decision.outcome
            toolSelectionProviderLease = decision.providerLease
            switch decision.result {
            case .selected(let operations):
                requiredReads = (intent.requiredOperations.map { SelectedRead(operation: $0, selector: nil) } + operations).reduce(into: []) {
                    if !$0.contains($1) { $0.append($1) }
                }
            case .failed(let failure):
                return .init(
                    intent: intent,
                    toolSelectionRequest: toolSelectionRequest,
                    toolSelectionOutcome: toolSelectionOutcome,
                    request: nil,
                    groundedContext: nil,
                    readExecution: nil,
                    readExecutions: [],
                    inferenceOutcome: nil,
                    failure: failure,
                    requestRejection: decision.requestRejection
                )
            }
        } else {
            requiredReads = intent.requiredOperations.map { SelectedRead(operation: $0, selector: nil) }
        }

        for read in requiredReads {
            let operation = read.operation
            if let debuggerOperation = Phase2DebuggerReadOperationID(rawValue: operation.rawValue) {
                guard let debuggerReadPlan else {
                    return failedResult(
                        intent: intent,
                        toolSelectionRequest: toolSelectionRequest,
                        toolSelectionOutcome: toolSelectionOutcome,
                        executions: executions,
                        failure: .inferenceInvalidRequest,
                        requestRejection: .init(stage: .nativeReadResolution, reasonCode: "missingDebuggerPlan")
                    )
                }
                guard let handle = debuggerReadPlan.handles.first(where: {
                    $0.operation == debuggerOperation
                }) else {
                    return failedResult(
                        intent: intent,
                        toolSelectionRequest: toolSelectionRequest,
                        toolSelectionOutcome: toolSelectionOutcome,
                        executions: executions,
                        failure: .inferenceInvalidRequest,
                        requestRejection: .init(stage: .nativeReadResolution, reasonCode: "missingDebuggerHandle")
                    )
                }
                let result = debuggerReadPlan.resolve(
                    .init(handleID: handle.id, operation: debuggerOperation),
                    against: store.phase2DebuggerReadEvidenceSnapshot
                )
                guard case .value = result.outcome else {
                    return failedResult(
                        intent: intent,
                        toolSelectionRequest: toolSelectionRequest,
                        toolSelectionOutcome: toolSelectionOutcome,
                        executions: executions,
                        failure: .inferenceInvalidRequest,
                        requestRejection: .init(stage: .nativeReadResolution, reasonCode: "debuggerReadNotValue")
                    )
                }
                acceptedDebuggerReads.append(result)
                continue
            }
            switch executeAssistantRead(
                operation: operation,
                isSupplemental: false,
                reaResultRead: read.selector,
                store: store,
                limits: readLimits,
                nativeDecompilerState: nativeDecompilerState
            ) {
            case .accepted(let execution, let accepted):
                executions.append(execution)
                acceptedInvocationIDs.append(accepted.invocationID)
            case .skipped:
                break
            case .failed(let failure, let execution):
                return .init(
                    intent: intent,
                    toolSelectionRequest: toolSelectionRequest,
                    toolSelectionOutcome: toolSelectionOutcome,
                    request: nil,
                    groundedContext: nil,
                    readExecution: execution,
                    readExecutions: appending(execution, to: executions),
                    inferenceOutcome: nil,
                    failure: failure
                )
            }
        }

        // Reuse the existing compiler result when the optional call-site record fits.
        // No await occurs between this check and finalization request construction.
        var callSiteContext: Phase2GroundedContext? = nil
        for operation in intent.supplementalOperations(contextOptions: contextOptions) {
            // Optional reads must not displace selected pages when the compiler sorts by evidence identity.
            let recordBudget = min(contextLimits.maximumRecords, inferenceLimits.maximumEvidenceReferences)
            guard acceptedInvocationIDs.count + acceptedDebuggerReads.count < recordBudget else { break }
            switch executeAssistantRead(
                operation: operation,
                isSupplemental: true,
                store: store,
                limits: readLimits,
                nativeDecompilerState: nativeDecompilerState
            ) {
            case .accepted(let execution, let accepted):
                if operation == .functionCallSites {
                    // Record count alone is insufficient: canonical byte trimming sorts
                    // by evidence ID and could otherwise displace a required read.
                    guard let proposed = try? store.compilePhase2GroundedContext(
                        invocationIDs: acceptedInvocationIDs + [accepted.invocationID],
                        limits: contextLimits
                    ), proposed.omissions.isEmpty else { continue }
                    callSiteContext = proposed
                } else {
                    callSiteContext = nil
                }
                executions.append(execution)
                acceptedInvocationIDs.append(accepted.invocationID)
            case .skipped:
                continue
            case .failed(let failure, let execution):
                return .init(
                    intent: intent,
                    toolSelectionRequest: toolSelectionRequest,
                    toolSelectionOutcome: toolSelectionOutcome,
                    request: nil,
                    groundedContext: nil,
                    readExecution: executions.first ?? execution,
                    readExecutions: appending(execution, to: executions),
                    inferenceOutcome: nil,
                    failure: failure
                )
            }
        }

        let context: Phase2GroundedContext
        do {
            if let callSiteContext {
                context = callSiteContext
            } else {
                context = try store.compilePhase2GroundedContext(
                    invocationIDs: acceptedInvocationIDs,
                    limits: contextLimits
                )
            }
        } catch let error as Phase2GroundedContextError {
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: nil,
                groundedContext: nil,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .groundedContextFailed(String(describing: error))
            )
        } catch {
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: nil,
                groundedContext: nil,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .groundedContextFailed(String(describing: error))
            )
        }

        guard let firstRecord = context.records.first else {
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: nil,
                groundedContext: context,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .groundedContextUnavailable
            )
        }

        let goalComposition = finalizationGoal(
            intent: intent,
            userGoal: userGoal,
            context: context,
            store: store,
            limits: inferenceLimits,
            contextOptions: contextOptions,
            debuggerReads: acceptedDebuggerReads
        )
        let finalizationRequestID = requestIDProvider()
        let reservedRequestIdentities = [
            conversationID,
            sessionID,
            turnID,
            firstRecord.precondition.workspace.document.instanceID,
            firstRecord.precondition.workspace.instanceID,
        ] + (toolSelectionRequestID.map { [$0] } ?? [])
        guard Self.isValidRequestID(
            finalizationRequestID,
            excluding: reservedRequestIdentities
        ) else {
            return failedResult(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                executions: executions,
                failure: .inferenceInvalidRequest,
                requestRejection: .init(stage: .finalizationPreparation, reasonCode: "invalidFinalizationRequestIdentity")
            )
        }
        let request = Phase2InferenceRequest(
            protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
            phase: .finalization,
            sessionID: sessionID,
            turnID: turnID,
            requestID: finalizationRequestID,
            document: firstRecord.precondition.workspace.document,
            workspace: firstRecord.precondition.workspace,
            lifecycleRevision: firstRecord.precondition.workspaceRevision,
            userGoal: goalComposition.text,
            groundedContext: context,
            toolHandles: [],
            conversationContext: conversationContext(
                conversationID: sessionID,
                priorTurns: priorTurns
            ),
            limits: inferenceLimits
        )

        switch await coordinator.run(request: request) {
        case .finished(let lease, let outcome):
            guard lease.providerRevision > 0,
                  toolSelectionProviderLease.map({
                      // Each MTPLX phase obtains fresh readiness, which advances the controller
                      // revision even when executable provider authority is unchanged. Per-turn
                      // exact-revision validation remains the coordinator's responsibility.
                      $0.configuration == lease.configuration
                          && $0.observedModelInventorySHA256 == lease.observedModelInventorySHA256
                  }) ?? true else {
                return .init(
                    intent: intent,
                    toolSelectionRequest: toolSelectionRequest,
                    toolSelectionOutcome: toolSelectionOutcome,
                    request: request,
                    groundedContext: context,
                    readExecution: executions.first,
                    readExecutions: executions,
                    inferenceOutcome: nil,
                    providerRevision: nil,
                    failure: .providerAuthorityChanged
                )
            }
            guard conversationID == sessionID
                    || !outcome.shellProposals.contains(where: {
                        $0.executionSurface == .restrictedOneShotJob
                    }) else {
                return .init(
                    intent: intent,
                    toolSelectionRequest: toolSelectionRequest,
                    toolSelectionOutcome: toolSelectionOutcome,
                    request: request,
                    groundedContext: context,
                    readExecution: executions.first,
                    readExecutions: executions,
                    inferenceOutcome: nil,
                    providerRevision: nil,
                    failure: .inferenceInvalidRequest,
                    requestRejection: .init(stage: .finalizationOutcome, reasonCode: "restrictedShellIdentityMismatch")
                )
            }
            for consumption in goalComposition.debuggerAuthorityConsumptions {
                _ = store.recordPhase2DebuggerReadOnlyRuntimeAuthorityConsumption(consumption)
            }
            let checked = await addressCheckedFinalization(
                request: request,
                lease: lease,
                outcome: outcome,
                coordinator: coordinator,
                reservedRequestIdentities: reservedRequestIdentities + [finalizationRequestID]
            )
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: checked.request,
                groundedContext: context,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: checked.outcome,
                providerRevision: checked.providerRevision,
                failure: nil,
                unverifiedAddresses: checked.unverifiedAddresses
            )
        case .notReady(let readiness):
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: request,
                groundedContext: context,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .inferenceNotReady(readiness)
            )
        case .busy:
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: request,
                groundedContext: context,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .inferenceBusy
            )
        case .invalidRequest:
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: request,
                groundedContext: context,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .inferenceInvalidRequest,
                requestRejection: .init(stage: .finalizationAdmission, reasonCode: "coordinatorDeclinedRequest")
            )
        case .providerAuthorityChanged:
            return .init(
                intent: intent,
                toolSelectionRequest: toolSelectionRequest,
                toolSelectionOutcome: toolSelectionOutcome,
                request: request,
                groundedContext: context,
                readExecution: executions.first,
                readExecutions: executions,
                inferenceOutcome: nil,
                failure: .providerAuthorityChanged
            )
        }
    }

    /// Checks the answer's addresses against the accepted evidence and, when any is
    /// unsupported, asks the model once to answer again using only evidence addresses.
    private func addressCheckedFinalization(
        request: Phase2InferenceRequest,
        lease: Phase2ReadyInferenceLease,
        outcome: Phase2InferenceOutcome,
        coordinator: any Phase2AssistantInferenceCoordinating,
        reservedRequestIdentities: [UUID]
    ) async -> (
        request: Phase2InferenceRequest,
        outcome: Phase2InferenceOutcome,
        providerRevision: UInt64,
        unverifiedAddresses: [String]
    ) {
        let check = Phase2AssistantAddressCheck(context: request.groundedContext)
        let unsupported = Self.unsupportedAddresses(in: outcome, check: check)
        let unrepaired = (request, outcome, lease.providerRevision, unsupported)
        guard !unsupported.isEmpty else { return unrepaired }

        let repairRequestID = requestIDProvider()
        guard Self.isValidRequestID(repairRequestID, excluding: reservedRequestIdentities) else {
            return unrepaired
        }
        let repairRequest = Phase2InferenceRequest(
            protocolVersion: request.protocolVersion,
            phase: request.phase,
            sessionID: request.sessionID,
            turnID: request.turnID,
            requestID: repairRequestID,
            document: request.document,
            workspace: request.workspace,
            lifecycleRevision: request.lifecycleRevision,
            userGoal: Self.addressRepairGoal(
                originalGoal: request.userGoal,
                unsupported: unsupported,
                evidenceAddresses: check.evidenceAddresses,
                maximumBytes: request.limits.maximumGoalBytes
            ),
            groundedContext: request.groundedContext,
            toolHandles: request.toolHandles,
            conversationContext: request.conversationContext,
            limits: request.limits
        )
        guard case .finished(let repairLease, let repairOutcome) = await coordinator.run(
                  request: repairRequest
              ),
              repairLease.providerRevision > 0,
              repairLease.configuration == lease.configuration,
              repairLease.observedModelInventorySHA256 == lease.observedModelInventorySHA256,
              repairOutcome.disposition == .completed,
              repairOutcome.finalCandidate != nil
        else { return unrepaired }
        return (
            repairRequest,
            repairOutcome,
            repairLease.providerRevision,
            Self.unsupportedAddresses(in: repairOutcome, check: check)
        )
    }

    private static func unsupportedAddresses(
        in outcome: Phase2InferenceOutcome,
        check: Phase2AssistantAddressCheck
    ) -> [String] {
        guard outcome.disposition == .completed,
              let candidate = outcome.finalCandidate,
              candidate.kind == .answer
        else { return [] }
        let prose = Phase2AssistantAuthoringProposalDraft.extract(from: candidate.text).answer
        return check.unsupportedAddresses(in: prose).map(\.text)
    }

    static let maximumRepairAddressesListed = 64

    static func addressRepairGoal(
        originalGoal: String,
        unsupported: [String],
        evidenceAddresses: [UInt64],
        maximumBytes: Int
    ) -> String {
        let listed = evidenceAddresses.prefix(maximumRepairAddressesListed)
            .map(Phase2AssistantAddressCheck.hex)
        let allowed = listed.isEmpty
            ? "grounded_context names no addresses, so quote none."
            : "Addresses in the evidence: \(listed.joined(separator: ", "))."
        let note = "Address check: your previous answer quoted addresses that are not in "
            + "grounded_context: \(unsupported.prefix(16).joined(separator: ", ")). "
            + "Answer again, quoting only addresses that appear in grounded_context or operands "
            + "shown in its instructions; never compute, convert or offset an address. "
            + allowed + "\n\n"
        var goal = note
        for character in originalGoal {
            guard goal.utf8.count + String(character).utf8.count <= maximumBytes else { break }
            goal.append(character)
        }
        return goal
    }

    private struct SelectedRead: Equatable {
        let operation: Phase2ReadOperationID
        let selector: REAResultReadSelector?
    }

    private struct ToolSelectionDecision {
        enum Result {
            case selected([SelectedRead])
            case failed(Phase2AssistantSessionFailure)
        }

        let request: Phase2InferenceRequest?
        let outcome: Phase2InferenceOutcome?
        let providerRevision: UInt64?
        let result: Result
        var providerLease: Phase2ReadyInferenceLease? = nil
        var requestRejection: Phase2AssistantRequestRejection? = nil
    }

    private func runProviderVisibleToolSelection(
        intent: Phase2AssistantIntent,
        userGoal: String,
        store: WorkspaceStore,
        coordinator: any Phase2AssistantInferenceCoordinating,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        contextLimits: Phase2GroundedContextLimits,
        inferenceLimits: Phase2InferenceLimits,
        debuggerPlan: Phase2DebuggerReadOperationPlan?,
        readLimits: Phase2ReadLimits
    ) async -> ToolSelectionDecision {
        let additionalReadBudget = max(0, contextLimits.maximumRecords - intent.requiredOperations.count)
        let plan: Phase2AssistantToolSelectionPlan
        do {
            plan = try Phase2AssistantToolSelectionPlan(
                operations: intent.providerVisibleToolOperations + (store.reaResultEvidence.records.isEmpty ? [] : [.reaResultsList, .reaResultsGet]),
                debuggerPlan: debuggerPlan,
                reaStore: store.reaResultEvidence,
                reaWorkspaceID: store.workspaceID,
                readLimits: readLimits,
                maximumHandles: inferenceLimits.maximumToolHandles,
                maximumAdditionalReads: min(inferenceLimits.maximumToolProposals, additionalReadBudget)
            )
        } catch {
            return .init(
                request: nil,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.inferenceInvalidRequest),
                requestRejection: .toolPlan(error)
            )
        }

        // Every plan, not only REA pages, may offer more tools than fit beside the mandatory
        // reads (Review Function offers three decompiler reads with room for two). The provider
        // is told the budget and an over-budget selection is reported without executing reads.
        let selectionBudgetIsBounded = !plan.reaSelectors.isEmpty
            || additionalReadBudget < inferenceLimits.maximumToolProposals
        let selectionLimits: Phase2InferenceLimits
        if selectionBudgetIsBounded {
            guard additionalReadBudget > 0 else {
                return .init(request: nil, outcome: nil, providerRevision: nil,
                    result: .failed(.groundedContextFailed("No additional reads fit the context budget after mandatory workspace reads.")))
            }
            selectionLimits = .init(maximumGoalBytes: inferenceLimits.maximumGoalBytes,
                maximumEventBytes: inferenceLimits.maximumEventBytes,
                maximumCumulativeEventBytes: inferenceLimits.maximumCumulativeEventBytes,
                maximumEvents: inferenceLimits.maximumEvents,
                maximumToolHandles: inferenceLimits.maximumToolHandles,
                maximumToolProposals: min(inferenceLimits.maximumToolProposals, additionalReadBudget),
                maximumFinalTextBytes: inferenceLimits.maximumFinalTextBytes,
                maximumEvidenceReferences: inferenceLimits.maximumEvidenceReferences)
        } else { selectionLimits = inferenceLimits }

        let selectionContext: Phase2GroundedContext
        do {
            selectionContext = try Phase2GroundedContextCompiler().compile(
                records: [],
                currentStateByEvidenceID: [:],
                limits: contextLimits
            )
        } catch {
            return .init(
                request: nil,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.groundedContextFailed(String(describing: error)))
            )
        }

        let workspace = store.phase2ReadLedger.workspace
        let reservedIDs = [
            sessionID,
            turnID,
            requestID,
            workspace.document.instanceID,
            workspace.instanceID,
        ]
        guard Self.identifiersAreDistinctAndNonzero(reservedIDs),
              plan.handles.allSatisfy({
                  $0.handleID != Phase2AssistantShellTurnIdentity.zeroUUID
                      && !reservedIDs.contains($0.handleID)
              }) else {
            return .init(
                request: nil,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.inferenceInvalidRequest),
                requestRejection: .init(stage: .toolPlanning, reasonCode: "invalidSelectionHandleIdentity")
            )
        }
        let request = Phase2InferenceRequest(
            protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
            phase: .toolSelection,
            sessionID: sessionID,
            turnID: turnID,
            requestID: requestID,
            document: workspace.document,
            workspace: workspace,
            lifecycleRevision: store.phase2ReadLedger.workspaceRevision,
            userGoal: intent.defaultGoal(userGoal: userGoal) + (plan.reaPageCoverage.isEmpty
                ? (selectionBudgetIsBounded
                    ? "\nSelect at most \(selectionLimits.maximumToolProposals) additional reads." : "")
                : "\nApp-issued REA page choices:\n" + plan.reaPageCoverage),
            groundedContext: selectionContext,
            toolHandles: plan.handles,
            conversationContext: .init(turns: [], omittedTurnCount: 0),
            limits: selectionLimits
        )

        switch await coordinator.run(request: request) {
        case .finished(let lease, let outcome):
            if selectionBudgetIsBounded, outcome.violation == .toolProposalLimitExceeded {
                return .init(request: request, outcome: outcome, providerRevision: lease.providerRevision,
                    result: .failed(.groundedContextFailed("The provider exceeded the selection budget of \(selectionLimits.maximumToolProposals) additional reads. No selected evidence was dropped or executed.")))
            }
            guard lease.providerRevision > 0,
                  outcome.disposition == .awaitingTools,
                  outcome.violation == nil,
                  let selectedOperations = selectedOperations(
                    from: outcome.toolProposals,
                    plan: plan,
                    maximumProposals: inferenceLimits.maximumToolProposals
                  )
            else {
                return .init(
                    request: request,
                    outcome: outcome,
                    providerRevision: nil,
                    result: .failed(.inferenceInvalidRequest),
                    requestRejection: .outcome(stage: .toolSelectionOutcome, outcome)
                )
            }
            let totalReads = selectedOperations.count + intent.requiredOperations.filter { operation in
                !selectedOperations.contains { $0.operation == operation && $0.selector == nil }
            }.count
            guard totalReads <= contextLimits.maximumRecords,
                  selectedOperations.count <= selectionLimits.maximumToolProposals else {
                let failure: Phase2AssistantSessionFailure = selectedOperations.count <= selectionLimits.maximumToolProposals
                    ? .inferenceInvalidRequest
                    : .groundedContextFailed("The provider selected \(selectedOperations.count) reads; only \(selectionLimits.maximumToolProposals) additional reads fit after mandatory workspace reads. No selected evidence was dropped or executed.")
                return .init(request: request, outcome: outcome, providerRevision: lease.providerRevision,
                    result: .failed(failure),
                    requestRejection: .init(stage: .toolSelectionOutcome,
                        reasonCode: "selectedReads=\(totalReads); recordLimit=\(contextLimits.maximumRecords); proposals=\(selectedOperations.count); proposalLimit=\(selectionLimits.maximumToolProposals)"))
            }
            return .init(
                request: request,
                outcome: outcome,
                providerRevision: lease.providerRevision,
                result: .selected(selectedOperations),
                providerLease: lease
            )
        case .notReady(let readiness):
            return .init(
                request: request,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.inferenceNotReady(readiness))
            )
        case .busy:
            return .init(
                request: request,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.inferenceBusy)
            )
        case .invalidRequest:
            return .init(
                request: request,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.inferenceInvalidRequest),
                requestRejection: .init(stage: .toolSelectionAdmission, reasonCode: "coordinatorDeclinedRequest")
            )
        case .providerAuthorityChanged:
            return .init(
                request: request,
                outcome: nil,
                providerRevision: nil,
                result: .failed(.providerAuthorityChanged)
            )
        }
    }

    private func selectedOperations(
        from proposals: [Phase2InferenceToolProposal],
        plan: Phase2AssistantToolSelectionPlan,
        maximumProposals: Int
    ) -> [SelectedRead]? {
        guard !proposals.isEmpty,
              proposals.count <= maximumProposals,
              proposals.count <= plan.handles.count else { return nil }

        let handlesByID = Dictionary(uniqueKeysWithValues: plan.handles.map { ($0.handleID, $0) })
        let projectedToolsByHandleID = Dictionary(uniqueKeysWithValues: plan.projectedTools.flatMap { tool in tool.acceptedHandleIDs.map { ($0, tool) } })
        var seenCallIDs: Set<Phase2ProviderToolCallID> = []
        var seenHandleIDs: Set<UUID> = []
        var seenOperations: Set<Phase2ReadOperationID> = []
        var operations: [SelectedRead] = []

        for proposal in proposals {
            guard seenCallIDs.insert(proposal.callID).inserted,
                  seenHandleIDs.insert(proposal.handleID).inserted,
                  (seenOperations.insert(proposal.operationID).inserted || proposal.operationID == .reaResultsGet),
                  let handle = handlesByID[proposal.handleID],
                  let projectedTool = projectedToolsByHandleID[proposal.handleID],
                  handle.operationID == proposal.operationID,
                  projectedTool.operationID == proposal.operationID.rawValue,
                  projectedTool.functionName == proposal.functionName
            else {
                return nil
            }
            operations.append(.init(operation: proposal.operationID, selector: plan.reaSelectors[proposal.handleID]))
        }

        return operations
    }

    private func conversationContext(
        conversationID: UUID,
        priorTurns: [Phase2AssistantProviderVisiblePriorTurn]
    ) -> Phase2InferenceConversationContext {
        let ordered = priorTurns
            .sorted { lhs, rhs in lhs.turnSequence < rhs.turnSequence }
            .map {
                Phase2InferenceConversationTurn(
                    conversationID: conversationID,
                    inferenceTurnID: $0.inferenceTurnID,
                    turnSequence: UInt64($0.turnSequence),
                    user: $0.userMessage,
                    assistant: $0.assistantMessage
                )
            }
        return Phase2InferenceConversationContext.retainingNewest(from: ordered)
    }

    private static func isValidTurnAuthority(
        conversationID: UUID,
        sessionID: UUID,
        turnID: UUID,
        turnSequence: UInt64,
        priorTurns: [Phase2AssistantProviderVisiblePriorTurn]
    ) -> Bool {
        guard turnSequence > 0,
              conversationID != Phase2AssistantShellTurnIdentity.zeroUUID,
              sessionID != Phase2AssistantShellTurnIdentity.zeroUUID,
              turnID != Phase2AssistantShellTurnIdentity.zeroUUID,
              turnID != conversationID,
              turnID != sessionID else { return false }

        var sequences: Set<UInt64> = []
        var turnIDs: Set<UUID> = []
        for prior in priorTurns {
            guard let sequence = UInt64(exactly: prior.turnSequence),
                  sequence > 0,
                  sequence < turnSequence,
                  prior.inferenceTurnID != Phase2AssistantShellTurnIdentity.zeroUUID,
                  prior.inferenceTurnID != turnID,
                  turnIDs.insert(prior.inferenceTurnID).inserted,
                  sequences.insert(sequence).inserted,
                  !prior.userMessage.isEmpty,
                  !prior.assistantMessage.isEmpty,
                  !prior.userMessage.utf8.contains(0),
                  !prior.assistantMessage.utf8.contains(0) else { return false }
        }
        return true
    }

    private static func isValidRequestID(
        _ requestID: UUID,
        excluding reserved: [UUID]
    ) -> Bool {
        requestID != Phase2AssistantShellTurnIdentity.zeroUUID
            && !reserved.contains(requestID)
    }

    private static func identifiersAreDistinctAndNonzero(_ identifiers: [UUID]) -> Bool {
        !identifiers.contains(Phase2AssistantShellTurnIdentity.zeroUUID)
            && Set(identifiers).count == identifiers.count
    }

    private enum AssistantReadStepResult {
        case accepted(Phase2ReadExecution, Phase2AcceptedEvidence)
        case skipped
        case failed(Phase2AssistantSessionFailure, Phase2ReadExecution?)
    }

    private func executeAssistantRead(
        operation: Phase2ReadOperationID,
        isSupplemental: Bool,
        reaResultRead: REAResultReadSelector? = nil,
        store: WorkspaceStore,
        limits: Phase2ReadLimits,
        nativeDecompilerState: NativeDecompilerPresentationState
    ) -> AssistantReadStepResult {
        switch store.preparePhase2Read(
            operation: operation,
            proposingPrincipal: .model,
            limits: limits,
            nativeDecompilerState: nativeDecompilerState,
            reaResultRead: reaResultRead
        ) {
        case .prepared(let prepared):
            let execution = store.executePhase2Read(prepared)
            if isSupplemental, operation == .functionCallSites,
               execution.disposition == .limitExceeded { return .skipped }
            guard execution.disposition == .accepted,
                  let accepted = execution.acceptedEvidence
            else {
                return .failed(
                    .evidenceRejected(operation: operation, disposition: execution.disposition),
                    execution
                )
            }
            if isSupplemental, case .unavailable = execution.candidate.data {
                return .skipped
            }
            return .accepted(execution, accepted)

        case .unavailable(let reason):
            return isSupplemental
                ? .skipped
                : .failed(.readUnavailable(operation: operation, reason: reason), nil)

        case .rejected(let disposition):
            // Capacity of this optional projection must not block the existing review.
            // Freshness/owner/authorization failures retain their existing failure path.
            if isSupplemental, operation == .functionCallSites,
               disposition == .limitExceeded { return .skipped }
            return .failed(.readRejected(operation: operation, disposition: disposition), nil)
        }
    }

    private func appending(
        _ execution: Phase2ReadExecution?,
        to executions: [Phase2ReadExecution]
    ) -> [Phase2ReadExecution] {
        guard let execution else { return executions }
        return executions + [execution]
    }

    private struct FinalizationGoalComposition {
        let text: String
        let debuggerAuthorityConsumptions: [Phase2DebuggerReadOnlyRuntimeAuthorityConsumption]
    }

    private func finalizationGoal(
        intent: Phase2AssistantIntent,
        userGoal: String,
        context: Phase2GroundedContext,
        store: WorkspaceStore,
        limits: Phase2InferenceLimits,
        contextOptions: Phase2AssistantContextOptions,
        debuggerReads: [Phase2DebuggerReadOperationResult]
    ) -> FinalizationGoalComposition {
        var composedGoal = intent.defaultGoal(userGoal: userGoal)
        var debuggerAuthorityConsumptions: [Phase2DebuggerReadOnlyRuntimeAuthorityConsumption] = []
        let proposalInstruction = store.phase2AssistantAuthoringProposalAnchor(in: context).flatMap {
            intent.authoringProposalInstruction(evidenceID: $0.evidenceID, address: $0.target.address)
        }
        composedGoal = appendFinalizationEvidenceSection(
            header: Phase2GroundedPromptCatalog.authoringProposalSectionHeader,
            evidence: proposalInstruction.map {
                $0 + "\n" + Phase2GroundedPromptCatalog.authoringProposalSectionEnd
            },
            to: composedGoal,
            limits: limits
        )
        let shellEvidenceBudget = availableEvidenceBytes(after: composedGoal, limits: limits, preferred: 8_192)
        composedGoal = appendFinalizationEvidenceSection(
            header: "[MacScope app-reviewed provider-visible shell execution evidence]",
            evidence: shellEvidenceBudget > 0
                ? store.phase2ProviderVisibleShellExecutionEvidenceText(
                    maximumUTF8Bytes: shellEvidenceBudget,
                    executionID: contextOptions.shellExecutionID
                )
                : nil,
            to: composedGoal,
            limits: limits
        )
        if !debuggerReads.isEmpty {
            let debuggerTypedHeader = "[MacScope provider-selected typed debugger evidence]"
            let sectionBudget = availableEvidenceBytes(
                after: composedGoal,
                limits: limits,
                preferred: 8_192
            )
            let debuggerTypedBudget = max(
                0,
                sectionBudget - debuggerTypedHeader.utf8.count - 1
            )
            var remainingBudget = debuggerTypedBudget
            var evidenceParts: [String] = []
            for read in debuggerReads where remainingBudget > 0 {
                let separatorBytes = evidenceParts.isEmpty ? 0 : 2
                guard remainingBudget > separatorBytes,
                      let provenance = read.provenance,
                      let evidence = read.providerVisibleEvidenceText(
                        maximumUTF8Bytes: min(2_048, remainingBudget - separatorBytes)
                      ),
                      !evidence.isEmpty
                else { continue }
                evidenceParts.append(evidence)
                remainingBudget -= separatorBytes + evidence.utf8.count
                if let consumption = store.phase2DebuggerReadOnlyRuntimeAuthorityConsumption(
                    provenance: provenance
                ) {
                    debuggerAuthorityConsumptions.append(consumption)
                }
            }
            let evidence = evidenceParts.joined(separator: "\n\n")
            composedGoal = appendFinalizationEvidenceSection(
                header: debuggerTypedHeader,
                evidence: evidence.isEmpty ? nil : evidence,
                to: composedGoal,
                limits: limits
            )
        }
        let debuggerControlEvidenceBudget = availableEvidenceBytes(
            after: composedGoal,
            limits: limits,
            preferred: 4_096
        )
        let debuggerControlEvidence: String? = contextOptions.debuggerExecutionID.flatMap { executionID in
            guard debuggerControlEvidenceBudget > 0 else { return nil }
            return store.phase2ProviderVisibleDebuggerControlEvidenceText(
                maximumUTF8Bytes: debuggerControlEvidenceBudget,
                executionID: executionID
            )
        }
        composedGoal = appendFinalizationEvidenceSection(
            header: "[MacScope app-reviewed debugger control evidence]",
            evidence: debuggerControlEvidence,
            to: composedGoal,
            limits: limits
        )
        return FinalizationGoalComposition(
            text: Phase2AIShellOneShotExecutionResult.truncatedUTF8(
                composedGoal,
                maximumBytes: limits.maximumGoalBytes
            ),
            debuggerAuthorityConsumptions: debuggerAuthorityConsumptions
        )
    }

    private func failedResult(
        intent: Phase2AssistantIntent,
        toolSelectionRequest: Phase2InferenceRequest?,
        toolSelectionOutcome: Phase2InferenceOutcome?,
        executions: [Phase2ReadExecution],
        failure: Phase2AssistantSessionFailure,
        requestRejection: Phase2AssistantRequestRejection? = nil
    ) -> Phase2AssistantSessionResult {
        .init(
            intent: intent,
            toolSelectionRequest: toolSelectionRequest,
            toolSelectionOutcome: toolSelectionOutcome,
            request: nil,
            groundedContext: nil,
            readExecution: executions.first,
            readExecutions: executions,
            inferenceOutcome: nil,
            failure: failure,
            requestRejection: requestRejection
        )
    }

    private func appendFinalizationEvidenceSection(
        header: String,
        evidence: String?,
        to goal: String,
        limits: Phase2InferenceLimits
    ) -> String {
        guard let evidence, !evidence.isEmpty else {
            return Phase2AIShellOneShotExecutionResult.truncatedUTF8(
                goal,
                maximumBytes: limits.maximumGoalBytes
            )
        }
        let composedGoal = goal + "\n\n" + header + "\n" + evidence
        return Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            composedGoal,
            maximumBytes: limits.maximumGoalBytes
        )
    }

    private func availableEvidenceBytes(
        after goal: String,
        limits: Phase2InferenceLimits,
        preferred: Int
    ) -> Int {
        max(0, min(preferred, limits.maximumGoalBytes - goal.utf8.count - 2))
    }

}

@MainActor
extension Phase2AssistantSessionResult {
    /// Publishes inert provider proposals only after the caller has accepted the same
    /// workspace-publication token used for the visible Assistant result.
    func stageAcceptedProviderProposals(in store: WorkspaceStore) {
        let currentWorkspace = store.phase2ReadLedger.workspace
        guard failure == nil,
              unverifiedAddresses.isEmpty,
              let request,
              request.phase == .finalization,
              request.workspace == currentWorkspace,
              request.document == currentWorkspace.document,
              request.lifecycleRevision == store.phase2ReadLedger.workspaceRevision,
              request.groundedContext == groundedContext,
              let outcome = inferenceOutcome,
              outcome.disposition == .completed,
              outcome.violation == nil,
              outcome.shellProposals.count <= request.limits.maximumToolProposals,
              outcome.debuggerActionProposals.count <= request.limits.maximumToolProposals
        else { return }
        if let proposal = outcome.shellProposals.first {
            store.stagePhase2AIShellProposalForReview(proposal)
        }
        if let proposal = outcome.debuggerActionProposals.first {
            store.stagePhase2AIDebuggerProposalForReview(proposal)
        }
    }
}

private extension Phase2AssistantIntent {
    func supplementalOperations(
        contextOptions: Phase2AssistantContextOptions
    ) -> [Phase2ReadOperationID] {
        supplementalOperations.filter { operation in
            switch operation {
            case .applicationGraphSummary:
                contextOptions.includeApplicationGraphContext
            default:
                true
            }
        }
    }
}

// MARK: - Same-turn restricted shell continuation

@MainActor
protocol Phase2AssistantShellContinuationCheckpointing: AnyObject {
    func persistAssistantShellContinuation(
        _ machine: Phase2AssistantShellContinuationMachine
    ) async throws
}

struct Phase2AssistantShellContinuationExecutionEnvelope: Sendable {
    let authorityJoin: Phase2AssistantShellExecutionAuthorityJoin
    let coordinate: Phase2AssistantShellContinuationCoordinate
    let executionResult: Phase2AIShellOneShotExecutionResult
}

@MainActor
protocol Phase2AssistantShellContinuationExecuting: AnyObject {
    func executeRestrictedOneShot(
        proposal: Phase2AIShellCommandProposal,
        reservedExecutionID: UUID
    ) async -> Phase2AssistantShellContinuationExecutionEnvelope?
}

enum Phase2AssistantShellProviderContinuationResult: Sendable {
    case completed(Phase2InferenceOutcome)
    case failed
}

@MainActor
protocol Phase2AssistantShellContinuationDispatching: AnyObject {
    func dispatchShellContinuation(
        coordinate: Phase2AssistantShellContinuationCoordinate,
        executionResult: Phase2AIShellOneShotExecutionResult
    ) async -> Phase2AssistantShellProviderContinuationResult
}

enum Phase2AssistantShellContinuationOrchestrationFailure: Error, Equatable, Sendable {
    case rejected(Phase2AssistantShellContinuationRejection)
    case checkpointWriteFailed
    case executionFailed
    case continuationFailed
    case conversationBusy
}

enum Phase2AssistantShellContinuationDurablePhase: Equatable, Sendable {
    case runningApprovedCommand
    case preparingShellResult
    case continuingAssistant

    var presentationPhase: Phase2AssistantSameTurnShellPresentationPhase {
        switch self {
        case .runningApprovedCommand: .runningApprovedCommand
        case .preparingShellResult: .preparingShellResult
        case .continuingAssistant: .continuingAssistant
        }
    }
}

@MainActor
extension WorkspaceStore {
    /// Production entry point invoked by the explicit restricted one-shot Run action. It keeps
    /// admission for the originating conversation until execution and automatic continuation are
    /// durably terminal; ordinary turns and PTY/debugger actions retain their existing admission.
    func runApprovedPhase2AssistantShellContinuation(
        machine: Phase2AssistantShellContinuationMachine,
        proposal: Phase2AIShellCommandProposal,
        approval: Phase2AssistantShellApproval,
        continuationRequestID: UUID,
        productionManifestIdentity: String,
        providerRevision: UInt64,
        checkpoint: any Phase2AssistantShellContinuationCheckpointing,
        dispatcher: any Phase2AssistantShellContinuationDispatching,
        phaseObserver: (@MainActor @Sendable (Phase2AssistantShellContinuationDurablePhase) -> Void)? = nil,
        oneShotExecutor: any Phase2AIShellOneShotExecuting = Phase2AIShellOneShotExecutor()
    ) async -> Phase2AssistantShellContinuationOrchestrationResult {
        let irreversibleBoundaryIDs = machine.turnIdentity.correlationIdentifiers + [
            proposal.proposalID,
            approval.reservedExecutionID,
            continuationRequestID,
        ]
        let exactDocumentDigest = Phase2AssistantWorkspaceDocumentIdentity.digest(
            documentID: documentID,
            workspaceID: workspaceID
        )
        guard machine.turnIdentity.workspaceID == workspaceID,
              machine.turnIdentity.workspaceDocumentIdentityDigest == exactDocumentDigest,
              machine.turnIdentity.isStructurallyValid,
              providerRevision > 0,
              productionManifestIdentity
                == Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
              !irreversibleBoundaryIDs.contains(Phase2AssistantShellTurnIdentity.zeroUUID),
              Set(irreversibleBoundaryIDs).count == irreversibleBoundaryIDs.count
        else {
            return .init(
                machine: machine,
                outcome: nil,
                failure: .rejected(.invalidCoordinate)
            )
        }
        guard beginPhase2AssistantTurn(conversationID: machine.turnIdentity.conversationID) else {
            return .init(machine: machine, outcome: nil, failure: .conversationBusy)
        }
        defer { endPhase2AssistantTurn(conversationID: machine.turnIdentity.conversationID) }
        let executor = Phase2WorkspaceStoreAssistantShellContinuationExecutor(
            store: self,
            turnIdentity: machine.turnIdentity,
            expectedDocumentID: documentID,
            continuationRequestID: continuationRequestID,
            productionManifestIdentity: productionManifestIdentity,
            providerRevision: providerRevision,
            oneShotExecutor: oneShotExecutor
        )
        return await Phase2AssistantShellContinuationOrchestrator().executeApprovedAndContinue(
            machine: machine,
            proposal: proposal,
            approval: approval,
            checkpoint: checkpoint,
            executor: executor,
            dispatcher: dispatcher,
            phaseObserver: phaseObserver
        )
    }
}

@MainActor
private final class Phase2WorkspaceStoreAssistantShellContinuationExecutor:
    Phase2AssistantShellContinuationExecuting {
    private unowned let store: WorkspaceStore
    private let turnIdentity: Phase2AssistantShellTurnIdentity
    private let expectedDocumentID: UUID
    private let continuationRequestID: UUID
    private let productionManifestIdentity: String
    private let providerRevision: UInt64
    private let oneShotExecutor: any Phase2AIShellOneShotExecuting

    init(
        store: WorkspaceStore,
        turnIdentity: Phase2AssistantShellTurnIdentity,
        expectedDocumentID: UUID,
        continuationRequestID: UUID,
        productionManifestIdentity: String,
        providerRevision: UInt64,
        oneShotExecutor: any Phase2AIShellOneShotExecuting
    ) {
        self.store = store
        self.turnIdentity = turnIdentity
        self.expectedDocumentID = expectedDocumentID
        self.continuationRequestID = continuationRequestID
        self.productionManifestIdentity = productionManifestIdentity
        self.providerRevision = providerRevision
        self.oneShotExecutor = oneShotExecutor
    }

    func executeRestrictedOneShot(
        proposal: Phase2AIShellCommandProposal,
        reservedExecutionID: UUID
    ) async -> Phase2AssistantShellContinuationExecutionEnvelope? {
        // This comparison and the call below execute in one uninterrupted MainActor segment.
        // It prevents an approved ID from authorizing different staged command content before
        // the one-shot executor crosses the irreversible process-launch boundary.
        guard hasExactStoreIdentity,
              store.phase2AIShellProposalReview.proposal == proposal else { return nil }
        let result = await store.executeApprovedPhase2AIShellProposalOneShot(
            expectedProposal: proposal,
            reservedExecutionID: reservedExecutionID,
            executor: oneShotExecutor
        )
        guard hasExactStoreIdentity,
              result.id == reservedExecutionID,
              result.schemaVersion == Phase2AIShellOneShotExecutionResult.schemaVersion,
              result.proposalID == proposal.proposalID,
              result.executablePath == proposal.executablePath,
              result.arguments == proposal.arguments,
              result.workingDirectoryPath == proposal.workingDirectoryPath,
              result.timeoutMilliseconds == proposal.timeoutMilliseconds,
              result.maximumOutputBytes == proposal.maximumOutputBytes,
              result.disposition == .completed,
              result.terminationStatus == 0,
              result.startedAt <= result.completedAt,
              Self.outputIsBounded(result)
        else { return nil }
        let authorities = store.phase2RuntimeAuthorityRecords.filter {
            $0.sessionID == reservedExecutionID
        }
        guard authorities.count == 1,
              let authority = authorities.first,
              authority.workspaceUUID == turnIdentity.workspaceID,
              authority.documentID == expectedDocumentID else { return nil }
        let proposalDigest = Phase2AssistantShellProposalCanonicalizer.digest(proposal)
        let resultDigest = Phase2AssistantShellExecutionResultCanonicalizer.digest(result)
        let authorityDigest = Self.digest(authority)
        guard let coordinate = Phase2AssistantShellContinuationCoordinate(
            workspaceID: turnIdentity.workspaceID,
            workspaceDocumentIdentityDigest: turnIdentity.workspaceDocumentIdentityDigest,
            conversationID: turnIdentity.conversationID,
            inferenceTurnID: turnIdentity.inferenceTurnID,
            turnSequence: turnIdentity.turnSequence,
            originatingFinalizationRequestID: turnIdentity.originatingFinalizationRequestID,
            shellProposalID: proposal.proposalID,
            shellExecutionID: reservedExecutionID,
            runtimeAuthorityRecordID: authority.id,
            shellProposalDigest: proposalDigest,
            shellExecutionResultDigest: resultDigest,
            runtimeAuthorityRecordDigest: authorityDigest,
            productionManifestIdentity: productionManifestIdentity,
            providerRevision: providerRevision,
            continuationRequestID: continuationRequestID
        ) else { return nil }
        let join = Phase2AssistantShellExecutionAuthorityJoin(
            turnIdentity: turnIdentity,
            proposalID: proposal.proposalID,
            proposalDigest: proposalDigest,
            executionID: reservedExecutionID,
            executionProposalID: result.proposalID,
            executionResultDigest: resultDigest,
            executionDisposition: result.disposition,
            runtimeAuthorityRecordID: authority.id,
            runtimeAuthoritySessionID: authority.sessionID,
            runtimeAuthorityRecordDigest: authorityDigest,
            runtimeAuthoritySurfaces: authority.surfaces,
            providerVisibleShellExecutionEnabled: authority.providerVisibleShellExecutionEnabled,
            productionManifestIdentity: productionManifestIdentity,
            providerRevision: providerRevision,
            wasAlreadyConsumed: false,
            continuationRequestID: continuationRequestID
        )
        return .init(
            authorityJoin: join,
            coordinate: coordinate,
            executionResult: result
        )
    }

    private var hasExactStoreIdentity: Bool {
        store.workspaceID == turnIdentity.workspaceID
            && store.documentID == expectedDocumentID
            && Phase2AssistantWorkspaceDocumentIdentity.digest(
                documentID: store.documentID,
                workspaceID: store.workspaceID
            ) == turnIdentity.workspaceDocumentIdentityDigest
    }

    private static func outputIsBounded(
        _ result: Phase2AIShellOneShotExecutionResult
    ) -> Bool {
        let (combined, overflow) = result.standardOutput.utf8.count.addingReportingOverflow(
            result.standardError.utf8.count
        )
        return !overflow && combined <= result.maximumOutputBytes
    }

    private static func digest(
        _ authority: WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord
    ) -> String {
        let canonical = [
            authority.id.uuidString.lowercased(), authority.workspaceUUID.uuidString.lowercased(),
            authority.documentID.uuidString.lowercased(), authority.sessionID.uuidString.lowercased(),
            authority.surfaces.map(\.rawValue).sorted().joined(separator: ","),
            authority.terminalBackend.rawValue, authority.ptyReusePolicy.rawValue,
            String(describing: authority.debuggerAuthorityPolicy),
            authority.providerVisibleShellExecutionEnabled ? "true" : "false",
            String(authority.recordSchemaVersion),
        ].joined(separator: "\n")
        return sha256(Data(canonical.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct Phase2AssistantShellContinuationOrchestrationResult: Sendable {
    let machine: Phase2AssistantShellContinuationMachine
    let outcome: Phase2InferenceOutcome?
    let failure: Phase2AssistantShellContinuationOrchestrationFailure?
}

/// Drives only the post-review restricted one-shot path. The initial Assistant runner, debugger
/// actions, and ShellBroker PTY remain independent. Every irreversible boundary is preceded by a
/// durable state write supplied by the persistence adapter.
@MainActor
struct Phase2AssistantShellContinuationOrchestrator {
    func executeApprovedAndContinue(
        machine initialMachine: Phase2AssistantShellContinuationMachine,
        proposal: Phase2AIShellCommandProposal,
        approval: Phase2AssistantShellApproval,
        checkpoint: any Phase2AssistantShellContinuationCheckpointing,
        executor: any Phase2AssistantShellContinuationExecuting,
        dispatcher: any Phase2AssistantShellContinuationDispatching,
        phaseObserver: (@MainActor @Sendable (Phase2AssistantShellContinuationDurablePhase) -> Void)? = nil
    ) async -> Phase2AssistantShellContinuationOrchestrationResult {
        var machine = initialMachine
        guard !Task.isCancelled else {
            return failed(machine, .continuationFailed)
        }
        guard let staged = machine.proposal,
              proposal.executionSurface == .restrictedOneShotJob,
              proposal.proposalID == staged.proposalID,
              Phase2AssistantShellProposalCanonicalizer.digest(proposal) == staged.proposalDigest,
              approval.proposalID == staged.proposalID,
              approval.proposalDigest == staged.proposalDigest
        else {
            return failed(machine, .rejected(.invalidProposalProvenance))
        }
        if let rejection = apply(.approveAndReserveExecution(approval), to: &machine) {
            return failed(machine, .rejected(rejection))
        }
        guard await persist(machine, with: checkpoint) else {
            return failed(machine, .checkpointWriteFailed)
        }
        guard !Task.isCancelled else {
            _ = machine.apply(.recordExecutionFailure(machine.turnIdentity))
            _ = await persist(machine, with: checkpoint)
            return failed(machine, .executionFailed)
        }
        phaseObserver?(.runningApprovedCommand)

        guard let envelope = await executor.executeRestrictedOneShot(
            proposal: proposal,
            reservedExecutionID: approval.reservedExecutionID
        ) else {
            _ = machine.apply(.recordExecutionFailure(machine.turnIdentity))
            _ = await persist(machine, with: checkpoint)
            return failed(machine, .executionFailed)
        }
        if let rejection = apply(
            .sealCompletedExecution(envelope.authorityJoin, envelope.coordinate),
            to: &machine
        ) {
            _ = machine.apply(.recordExecutionFailure(machine.turnIdentity))
            _ = await persist(machine, with: checkpoint)
            return failed(machine, .rejected(rejection))
        }
        guard await persist(machine, with: checkpoint) else {
            return failed(machine, .checkpointWriteFailed)
        }
        guard !Task.isCancelled else {
            return failed(machine, .continuationFailed)
        }
        phaseObserver?(.preparingShellResult)

        if let rejection = apply(.reserveContinuation(envelope.coordinate), to: &machine) {
            return failed(machine, .rejected(rejection))
        }
        guard await persist(machine, with: checkpoint) else {
            return failed(machine, .checkpointWriteFailed)
        }
        guard !Task.isCancelled else {
            _ = machine.apply(.recordContinuationFailure(envelope.coordinate))
            _ = await persist(machine, with: checkpoint)
            return failed(machine, .continuationFailed)
        }
        phaseObserver?(.continuingAssistant)

        switch await dispatcher.dispatchShellContinuation(
            coordinate: envelope.coordinate,
            executionResult: envelope.executionResult
        ) {
        case .completed(let outcome):
            guard outcome.disposition == .completed,
                  outcome.violation == nil,
                  outcome.finalCandidate != nil,
                  outcome.toolProposals.isEmpty,
                  outcome.shellProposals.isEmpty,
                  outcome.debuggerActionProposals.isEmpty
            else {
                _ = machine.apply(.recordContinuationFailure(envelope.coordinate))
                _ = await persist(machine, with: checkpoint)
                return failed(machine, .continuationFailed)
            }
            if let rejection = apply(.acceptContinuationFinal(envelope.coordinate), to: &machine) {
                return failed(machine, .rejected(rejection))
            }
            guard await persist(machine, with: checkpoint) else {
                return failed(machine, .checkpointWriteFailed)
            }
            return .init(machine: machine, outcome: outcome, failure: nil)
        case .failed:
            _ = machine.apply(.recordContinuationFailure(envelope.coordinate))
            _ = await persist(machine, with: checkpoint)
            return failed(machine, .continuationFailed)
        }
    }

    private func apply(
        _ action: Phase2AssistantShellContinuationAction,
        to machine: inout Phase2AssistantShellContinuationMachine
    ) -> Phase2AssistantShellContinuationRejection? {
        if case .failure(let rejection) = machine.apply(action) { return rejection }
        return nil
    }

    private func persist(
        _ machine: Phase2AssistantShellContinuationMachine,
        with checkpoint: any Phase2AssistantShellContinuationCheckpointing
    ) async -> Bool {
        do {
            try await checkpoint.persistAssistantShellContinuation(machine)
            return true
        } catch {
            return false
        }
    }

    private func failed(
        _ machine: Phase2AssistantShellContinuationMachine,
        _ failure: Phase2AssistantShellContinuationOrchestrationFailure
    ) -> Phase2AssistantShellContinuationOrchestrationResult {
        .init(machine: machine, outcome: nil, failure: failure)
    }
}

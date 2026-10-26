import CryptoKit
import Combine
import Foundation

struct Phase2AssistantCompletionIdentity: Equatable, Sendable {
    let workspaceID: UUID
    let documentID: UUID
    let sessionID: UUID
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: Int
    let originatingRequestID: UUID

    init(
        workspaceID: UUID,
        documentID: UUID,
        sessionID: UUID,
        conversationID: UUID,
        inferenceTurnID: UUID,
        turnSequence: Int,
        originatingRequestID: UUID
    ) {
        self.workspaceID = workspaceID
        self.documentID = documentID
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.inferenceTurnID = inferenceTurnID
        self.turnSequence = turnSequence
        self.originatingRequestID = originatingRequestID
    }

    init?(
        workspaceID: UUID,
        documentID: UUID,
        requestSessionID: UUID,
        requestTurnID: UUID,
        originatingRequestID: UUID,
        turnContext: Phase2AssistantConversationTurnContext
    ) {
        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        guard ![
                  workspaceID, documentID, requestSessionID, requestTurnID,
                  originatingRequestID, turnContext.conversationID,
              ].contains(zeroUUID),
              requestSessionID == turnContext.sessionID,
              requestTurnID == turnContext.inferenceTurnID,
              turnContext.turnSequence > 0,
              turnContext.turnSequence <= UInt64(Int.max)
        else { return nil }
        self.init(
            workspaceID: workspaceID,
            documentID: documentID,
            sessionID: requestSessionID,
            conversationID: turnContext.conversationID,
            inferenceTurnID: requestTurnID,
            turnSequence: Int(turnContext.turnSequence),
            originatingRequestID: originatingRequestID
        )
    }

    init?(
        request: Phase2InferenceRequest,
        turnContext: Phase2AssistantConversationTurnContext
    ) {
        self.init(
            workspaceID: request.workspace.instanceID,
            documentID: request.document.instanceID,
            requestSessionID: request.sessionID,
            requestTurnID: request.turnID,
            originatingRequestID: request.requestID,
            turnContext: turnContext
        )
    }

    func authorizesPresentation(
        workspaceID: UUID,
        documentID: UUID,
        activeConversationID: UUID?,
        activeInferenceTurnID: UUID?,
        activeTurnSequence: Int?
    ) -> Bool {
        self.workspaceID == workspaceID
            && self.documentID == documentID
            && conversationID == activeConversationID
            && inferenceTurnID == activeInferenceTurnID
            && turnSequence == activeTurnSequence
    }
}

struct Phase2AssistantContinuationPublicationToken: Equatable, Sendable {
    let ownerRevision: UUID
    let identity: Phase2AssistantCompletionIdentity

    func isCurrent(
        ownerRevision: UUID,
        workspaceID: UUID,
        documentID: UUID
    ) -> Bool {
        self.ownerRevision == ownerRevision
            && identity.workspaceID == workspaceID
            && identity.documentID == documentID
    }
}

enum Phase2AssistantContinuationStagingDisposition: Equatable {
    case notEligible
    case staged
    case rejected(Phase2AssistantSheetState)

    var ownsProviderProposals: Bool {
        switch self {
        case .notEligible: false
        case .staged, .rejected: true
        }
    }

    var immediateFinalState: Phase2AssistantSheetState? {
        if case .rejected(let state) = self { state } else { nil }
    }
}

/// Document-window owner for one durable provider-visible restricted-shell continuation.
/// It freezes the accepted originating request and keeps the checkpoint database alive across
/// Assistant sheet dismissal/re-presentation.
@MainActor
final class Phase2AssistantLiveContinuationController: ObservableObject {
    enum TerminalAction: Equatable, Sendable {
        case reject
        case dismiss
        case cancel
    }

    typealias DurableTerminalFinalizer = @MainActor @Sendable (
        _ action: TerminalAction,
        _ machine: Phase2AssistantShellContinuationMachine,
        _ recordID: UUID,
        _ owner: Phase2AssistantContinuationDatabaseOwner
    ) async throws -> Phase2AssistantShellContinuationMachine

    @Published private(set) var presentation: Phase2AssistantSameTurnShellPresentation?
    @Published private(set) var completionRevision: UUID?
    @Published private(set) var completionIdentity: Phase2AssistantCompletionIdentity?
    @Published private(set) var presentationIdentity: Phase2AssistantCompletionIdentity?
    @Published private(set) var recoveryProjections: [
        Phase2AssistantContinuationDatabaseOwner.RecoveryProjection
    ] = []

    private unowned let store: WorkspaceStore
    private let coordinator: (any Phase2AssistantInferenceCoordinating)?
    private var databaseOwner: Phase2AssistantContinuationDatabaseOwner?
    private var frozen: FrozenTurn?
    private var machine: Phase2AssistantShellContinuationMachine?
    private var approval: Phase2AssistantShellApproval?
    private var recordID: UUID?
    private var originatingResult: Phase2AssistantSessionResult?
    private(set) var completedDisplayState: Phase2AssistantSheetState?
    private var runTask: Task<Void, Never>?
    private var terminalizationTask: Task<Void, Never>?
    private let durableTerminalFinalizer: DurableTerminalFinalizer?
    private let continuationDatabaseBaseDirectoryURL: URL?
    private var recoveredOwnerIdentity: OwnerIdentity?
    private var ownerRevision = UUID()
    private var requiresDurableRecovery = false

    var currentDatabaseOwnerIdentity: (workspaceID: UUID, documentID: UUID)? {
        databaseOwner.map { ($0.workspaceUUID, $0.documentID) }
    }

    init(
        store: WorkspaceStore,
        coordinator: (any Phase2AssistantInferenceCoordinating)?,
        continuationDatabaseBaseDirectoryURL: URL? = nil,
        durableTerminalFinalizer: DurableTerminalFinalizer? = nil
    ) {
        self.store = store
        self.coordinator = coordinator
        self.durableTerminalFinalizer = durableTerminalFinalizer
        self.continuationDatabaseBaseDirectoryURL = continuationDatabaseBaseDirectoryURL
    }

    func refreshDatabaseOwnerForCurrentStoreIdentity() {
        do {
            if requiresDurableRecovery {
                retireCurrentOwnerPresentation()
            }
            _ = try ensureCurrentDatabaseOwner(recover: true)
        } catch {
            requiresDurableRecovery = true
            presentation = .init(phase: .recoveryBlocked(
                detail: "Assistant continuation recovery storage could not be opened safely."
            ))
        }
    }

    deinit {
        runTask?.cancel()
        terminalizationTask?.cancel()
    }

    /// Claims eligible accepted proposals for this path, including fail-closed identity or
    /// admission failures that must never downgrade to legacy execution.
    func stageAcceptedResult(
        _ result: Phase2AssistantSessionResult,
        turnContext: Phase2AssistantConversationTurnContext
    ) -> Phase2AssistantContinuationStagingDisposition {
        guard result.failure == nil,
              result.unverifiedAddresses.isEmpty,
              let request = result.request,
              let outcome = result.inferenceOutcome,
              request.phase == .finalization,
              request.shellContinuationCoordinate == nil,
              outcome.disposition == .completed,
              outcome.violation == nil,
              let providerRevision = result.providerRevision,
              providerRevision > 0,
              outcome.shellProposals.count == 1,
              let proposal = outcome.shellProposals.first,
              proposal.executionSurface == .restrictedOneShotJob,
              Phase2AIShellProposalValidator.validate(proposal).isAccepted
        else { return .notEligible }

        // An eligible same-turn proposal must never fall through to the legacy proposal path.
        // Admission or identity failures are consumed fail-closed by this controller.
        guard !requiresDurableRecovery else {
            return .rejected(.failed(
                title: "Shell continuation recovery required",
                detail: "The prior same-turn shell continuation must be reconciled durably before another can start."
            ))
        }
        guard Self.admitsNewContinuation(
            existingState: machine?.state,
            runInFlight: runTask != nil,
            requiresDurableRecovery: false
        ) else {
            return .rejected(.failed(
                title: "Shell continuation unavailable",
                detail: "Another same-turn shell continuation is still active in this document window."
            ))
        }

        guard let completionIdentity = Phase2AssistantCompletionIdentity(
                  request: request,
                  turnContext: turnContext
              ),
              completionIdentity.workspaceID == store.workspaceID,
              completionIdentity.documentID == store.documentID
        else {
            presentationIdentity = nil
            presentation = .init(phase: .failed(
                stage: .authorityValidation,
                detail: "The Assistant request no longer matched its exact document, session, and turn identity."
            ))
            return .rejected(.failed(
                title: "Shell continuation identity rejected",
                detail: "The Assistant request no longer matched its exact document, session, and turn identity."
            ))
        }

        guard let owner = try? ensureCurrentDatabaseOwner(recover: true) else {
            presentationIdentity = completionIdentity
            presentation = .init(phase: .failed(
                stage: .recovery,
                detail: "The pending Assistant turn could not open durable storage safely."
            ))
            return .rejected(.failed(
                title: "Shell continuation storage unavailable",
                detail: "The pending Assistant turn could not open durable storage safely."
            ))
        }

        presentationIdentity = completionIdentity
        completedDisplayState = nil
        self.completionIdentity = nil
        completionRevision = nil

        let documentDigest = Self.documentIdentityDigest(request: request)
        let identity = Phase2AssistantShellTurnIdentity(
            workspaceID: request.workspace.instanceID,
            workspaceDocumentIdentityDigest: documentDigest,
            conversationID: turnContext.conversationID,
            inferenceTurnID: request.turnID,
            turnSequence: turnContext.turnSequence,
            originatingFinalizationRequestID: request.requestID
        )
        guard var next = Phase2AssistantShellContinuationMachine(turnIdentity: identity),
              case .success = next.apply(.beginToolSelection(identity)),
              case .success = next.apply(.beginFinalization(identity))
        else {
            presentation = .init(phase: .failed(
                stage: .authorityValidation,
                detail: "The exact Assistant shell turn identity could not be staged safely."
            ))
            return .rejected(.failed(
                title: "Shell continuation identity rejected",
                detail: "The exact Assistant shell turn identity could not be staged safely."
            ))
        }
        let proposalDigest = Phase2AssistantShellProposalCanonicalizer.digest(proposal)
        let provenance = Phase2AssistantShellProposalProvenance(
            turnIdentity: identity,
            proposalID: proposal.proposalID,
            proposalDigest: proposalDigest,
            executionSurface: proposal.executionSurface,
            isLegacy: false
        )
        guard case .success = next.apply(.stageProposal(provenance)) else {
            presentation = .init(phase: .failed(
                stage: .authorityValidation,
                detail: "The exact Assistant shell proposal provenance could not be staged safely."
            ))
            return .rejected(.failed(
                title: "Shell proposal provenance rejected",
                detail: "The exact Assistant shell proposal provenance could not be staged safely."
            ))
        }

        do {
            let terminalDigest = Self.terminalDigest(
                request: request,
                proposalDigest: proposalDigest,
                outcome: outcome
            )
            let id = try store.seedPhase2AssistantShellContinuation(
                machine: next,
                proposal: proposal,
                intent: result.intent,
                userGoal: request.userGoal,
                initialTerminalEventDigest: terminalDigest,
                in: owner
            )
            databaseOwner = owner
            frozen = .init(
                request: request,
                proposal: proposal,
                providerRevision: providerRevision,
                turnIdentity: identity,
                workspaceDocumentIdentityDigest: documentDigest,
                completionIdentity: completionIdentity
            )
            machine = next
            approval = nil
            recordID = id
            originatingResult = result
            store.stagePhase2AIShellProposalForReview(proposal)
            presentation = .init(phase: .awaitingReview)
            return .staged
        } catch {
            presentation = .init(phase: .failed(
                stage: .recovery,
                detail: "The pending Assistant turn could not be checkpointed safely."
            ))
            // The proposal was eligible for the durable path; never downgrade it to the legacy
            // execution flow merely because persistence failed.
            return .rejected(.failed(
                title: "Shell continuation checkpoint failed",
                detail: "The pending Assistant turn could not be checkpointed safely."
            ))
        }
    }

    func approve() {
        guard (try? ensureCurrentDatabaseOwner(recover: true)) != nil else {
            requiresDurableRecovery = true
            presentation = .init(phase: .recoveryBlocked(
                detail: "The pending Assistant turn could not reopen durable storage safely."
            ))
            return
        }
        guard approval == nil, let frozen, machine?.state == .awaitingShellReview else { return }
        let reservedExecutionID = UUID()
        let candidate = Phase2AssistantShellApproval(
            turnIdentity: frozen.turnIdentity,
            proposalID: frozen.proposal.proposalID,
            proposalDigest: Phase2AssistantShellProposalCanonicalizer.digest(frozen.proposal),
            reservedExecutionID: reservedExecutionID
        )
        // Validate the reservation against a copy; the orchestrator remains the sole mutator.
        var validation = machine!
        guard case .success = validation.apply(.approveAndReserveExecution(candidate)) else { return }
        approval = candidate
        store.approvePhase2AIShellProposalForFutureOneShot(
            proposalID: frozen.proposal.proposalID
        )
        presentation = .init(phase: .approvedAwaitingRun)
    }

    func run() {
        guard let currentOwner = try? ensureCurrentDatabaseOwner(recover: true) else {
            requiresDurableRecovery = true
            presentation = .init(phase: .recoveryBlocked(
                detail: "The approved Assistant turn could not reopen durable storage safely."
            ))
            return
        }
        guard runTask == nil,
              let coordinator,
              let frozen,
              let machine,
              let approval,
              let owner = databaseOwner,
              owner === currentOwner,
              let recordID
        else { return }
        guard let checkpoint = try? owner.checkpointAdapter(recordID: recordID) else {
            requiresDurableRecovery = true
            presentation = .init(phase: .recoveryBlocked(
                detail: "The approved Assistant turn could not reopen its durable checkpoint safely."
            ))
            return
        }
        let publicationToken = Phase2AssistantContinuationPublicationToken(
            ownerRevision: ownerRevision,
            identity: frozen.completionIdentity
        )
        runTask = Task { [weak self] in
            guard let self else { return }
            let dispatcher = Phase2AssistantShellContinuationDispatchAdapter(
                coordinator: coordinator,
                context: { [weak self] coordinate in
                    guard let self,
                          self.isCurrent(
                              publicationToken,
                              owner: owner,
                              recordID: recordID
                          )
                    else { return nil }
                    return Self.dispatchContext(for: coordinate, frozen: frozen)
                }
            )
            let result = await self.store.runApprovedPhase2AssistantShellContinuation(
                machine: machine,
                proposal: frozen.proposal,
                approval: approval,
                continuationRequestID: UUID(),
                productionManifestIdentity:
                    Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
                providerRevision: frozen.providerRevision,
                checkpoint: PreterminalCheckpoint(base: checkpoint),
                dispatcher: dispatcher,
                phaseObserver: { [weak self] phase in
                    guard let self,
                          self.isCurrent(
                              publicationToken,
                              owner: owner,
                              recordID: recordID
                          )
                    else { return }
                    self.presentation = .init(phase: phase.presentationPhase)
                }
            )
            guard !Task.isCancelled,
                  self.isCurrent(
                      publicationToken,
                      owner: owner,
                      recordID: recordID
                  )
            else { return }
            self.machine = result.machine
            do {
                let seal = try self.terminalSeal(
                    for: result,
                    recordID: recordID,
                    owner: owner
                )
                _ = try await owner.sealTerminal(recordID: recordID, seal: seal)
                guard !Task.isCancelled,
                      self.isCurrent(
                          publicationToken,
                          owner: owner,
                          recordID: recordID
                      )
                else { return }
                try self.store.projectPhase2AssistantShellContinuation(
                    recordID: recordID,
                    from: owner
                )
                if !result.machine.state.isTerminal {
                    // The durable seal is authoritative for early orchestration failures that do
                    // not have a matching in-memory failure transition.
                    self.machine = nil
                }
            } catch {
                guard !Task.isCancelled,
                      self.isCurrent(
                          publicationToken,
                          owner: owner,
                          recordID: recordID
                      )
                else { return }
                self.presentation = .init(phase: .recoveryBlocked(
                    detail: "The Assistant result could not be sealed durably."
                ))
                self.requiresDurableRecovery = true
                self.runTask = nil
                return
            }
            var terminalPresentation = Self.presentation(
                for: result,
                identity: frozen.completionIdentity
            )
            let finalState: Phase2AssistantSheetState
            if let outcome = result.outcome,
               let completionEvidence = Self.completionEvidence(
                   for: result,
                   identity: frozen.completionIdentity
               ),
               let originatingResult {
                let completedResult = Phase2AssistantSessionResult(
                    intent: originatingResult.intent,
                    toolSelectionRequest: originatingResult.toolSelectionRequest,
                    toolSelectionOutcome: originatingResult.toolSelectionOutcome,
                    request: originatingResult.request,
                    groundedContext: originatingResult.groundedContext,
                    readExecution: originatingResult.readExecution,
                    readExecutions: originatingResult.readExecutions,
                    inferenceOutcome: outcome,
                    providerRevision: frozen.providerRevision,
                    failure: nil
                )
                finalState = Phase2AssistantDisplayMapper.state(
                    for: completedResult,
                    sameTurnShellEvidence: completionEvidence
                )
                if case .completed = finalState {
                    // Keep the truthful completed presentation produced from the sealed
                    // continuation coordinate.
                } else {
                    terminalPresentation = .init(phase: .failed(
                        stage: .authorityValidation,
                        detail: "The final Assistant answer did not match the accepted evidence authority."
                    ))
                }
            } else {
                finalState = .failed(
                    title: terminalPresentation.title,
                    detail: terminalPresentation.detail
                )
            }
            self.publishCompletion(finalState, identity: frozen.completionIdentity)
            self.presentation = terminalPresentation
            self.requiresDurableRecovery = false
            self.runTask = nil
        }
    }

    func reject() {
        terminalize(.reject, presentationPhase: .rejected)
    }

    func dismiss() {
        terminalize(.dismiss, presentationPhase: .dismissed)
    }

    func cancel() {
        guard runTask == nil, approval != nil else { return }
        terminalize(.cancel, presentationPhase: .cancelled)
    }

    private func terminalize(
        _ action: TerminalAction,
        presentationPhase: Phase2AssistantSameTurnShellPresentationPhase
    ) {
        guard (try? ensureCurrentDatabaseOwner(recover: true)) != nil else {
            requiresDurableRecovery = true
            presentation = .init(phase: .recoveryBlocked(
                detail: "The Assistant turn could not reopen durable storage for retirement."
            ))
            return
        }
        guard terminalizationTask == nil,
              let finalizer = durableTerminalFinalizer,
              let machine,
              !machine.state.isTerminal,
              let recordID,
              let owner = databaseOwner,
              let frozen
        else { return }
        let publicationToken = Phase2AssistantContinuationPublicationToken(
            ownerRevision: ownerRevision,
            identity: frozen.completionIdentity
        )

        terminalizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let terminal = try await finalizer(action, machine, recordID, owner)
                guard !Task.isCancelled,
                      self.isCurrent(
                          publicationToken,
                          owner: owner,
                          recordID: recordID
                      )
                else { return }
                guard terminal.state.isTerminal else { throw TerminalizationError.nonterminalResult }
                self.machine = terminal
                self.runTask = nil
                let terminalPresentation = Phase2AssistantSameTurnShellPresentation(
                    phase: presentationPhase
                )
                let finalState: Phase2AssistantSheetState
                switch action {
                case .reject:
                    finalState = .cancelled(
                        title: "Shell proposal rejected",
                        detail: "The reviewed command was rejected and was not executed."
                    )
                case .dismiss:
                    finalState = .cancelled(
                        title: "Shell proposal dismissed",
                        detail: "The reviewed command was dismissed and was not executed."
                    )
                case .cancel:
                    finalState = .cancelled(
                        title: "Assistant turn cancelled",
                        detail: "The approved command was cancelled before execution began."
                    )
                }
                self.publishCompletion(finalState, identity: frozen.completionIdentity)
                self.presentation = terminalPresentation
                self.requiresDurableRecovery = false
            } catch {
                guard !Task.isCancelled,
                      self.isCurrent(
                          publicationToken,
                          owner: owner,
                          recordID: recordID
                      )
                else { return }
                self.presentation = .init(phase: .recoveryBlocked(
                    detail: "The Assistant turn could not be closed durably."
                ))
                self.requiresDurableRecovery = true
            }
            if self.isCurrent(publicationToken, owner: owner, recordID: recordID) {
                self.terminalizationTask = nil
            }
        }
    }

    private func isCurrent(
        _ token: Phase2AssistantContinuationPublicationToken,
        owner: Phase2AssistantContinuationDatabaseOwner,
        recordID: UUID
    ) -> Bool {
        if databaseOwner === owner,
           (store.workspaceID != owner.workspaceUUID || store.documentID != owner.documentID) {
            retireCurrentOwnerPresentation()
            return false
        }
        return token.isCurrent(
            ownerRevision: ownerRevision,
            workspaceID: store.workspaceID,
            documentID: store.documentID
        )
            && databaseOwner === owner
            && self.recordID == recordID
            && frozen?.completionIdentity == token.identity
            && presentationIdentity == token.identity
    }

    private func publishCompletion(
        _ state: Phase2AssistantSheetState,
        identity: Phase2AssistantCompletionIdentity
    ) {
        completedDisplayState = state
        completionIdentity = identity
        completionRevision = UUID()
    }

    private func retireCurrentOwnerPresentation() {
        ownerRevision = UUID()
        runTask?.cancel()
        runTask = nil
        terminalizationTask?.cancel()
        terminalizationTask = nil
        databaseOwner = nil
        frozen = nil
        machine = nil
        approval = nil
        recordID = nil
        originatingResult = nil
        completedDisplayState = nil
        completionIdentity = nil
        completionRevision = nil
        presentationIdentity = nil
        presentation = nil
        recoveryProjections = []
        recoveredOwnerIdentity = nil
        requiresDurableRecovery = false
    }

    @discardableResult
    private func ensureCurrentDatabaseOwner(
        recover: Bool
    ) throws -> Phase2AssistantContinuationDatabaseOwner {
        let identity = OwnerIdentity(workspaceID: store.workspaceID, documentID: store.documentID)
        if let owner = databaseOwner,
           owner.workspaceUUID == identity.workspaceID,
           owner.documentID == identity.documentID {
            if recover, recoveredOwnerIdentity != identity {
                try self.recover(owner, identity: identity)
            }
            return owner
        }

        retireCurrentOwnerPresentation()
        let owner = try store.makePhase2AssistantContinuationDatabaseOwner(
            baseDirectoryURL: continuationDatabaseBaseDirectoryURL
        )
        databaseOwner = owner
        recoveredOwnerIdentity = nil
        if recover { try self.recover(owner, identity: identity) }
        return owner
    }

    private func recover(
        _ owner: Phase2AssistantContinuationDatabaseOwner,
        identity: OwnerIdentity
    ) throws {
        let recovered = try store.recoverPhase2AssistantShellContinuations(from: owner)
        requiresDurableRecovery = false
        recoveredOwnerIdentity = identity
        recoveryProjections = recovered
        if !recovered.isEmpty {
            presentation = .init(phase: .failed(
                stage: .recovery,
                detail: "A previously interrupted Assistant shell turn was closed safely without re-execution."
            ))
        }
    }

    static func productionTerminalFinalizer(
        store: WorkspaceStore
    ) -> DurableTerminalFinalizer {
        { action, machine, recordID, owner in
            guard store.workspaceID == owner.workspaceUUID,
                  store.documentID == owner.documentID
            else { throw TerminalizationError.retiredOwner }
            try Task.checkCancellation()
            let expectedState = machine.state
            var terminal = machine
            let disposition: Phase2AssistantShellContinuationTerminalSeal.Disposition
            switch action {
            case .reject:
                try terminal.apply(.rejectProposal(machine.turnIdentity)).get()
                disposition = .rejected(diagnostic: "The user rejected the reviewed shell proposal.")
            case .dismiss, .cancel:
                try terminal.apply(.cancel(machine.turnIdentity)).get()
                disposition = .cancelled
            }
            guard terminal.state.isTerminal else {
                throw TerminalizationError.nonterminalResult
            }
            let digest = terminalEventDigest(
                identity: machine.turnIdentity,
                kind: action == .reject ? "rejected" : "cancelled",
                content: action == .reject
                    ? "The user rejected the reviewed shell proposal."
                    : ""
            )
            _ = try await owner.sealTerminal(
                recordID: recordID,
                seal: .init(
                    expectedLogicalState: expectedState,
                    disposition: disposition,
                    terminalEventDigest: digest,
                    completedAt: Date()
                )
            )
            try Task.checkCancellation()
            guard store.workspaceID == owner.workspaceUUID,
                  store.documentID == owner.documentID
            else { throw TerminalizationError.retiredOwner }
            try store.projectPhase2AssistantShellContinuation(recordID: recordID, from: owner)
            return terminal
        }
    }

    private func terminalSeal(
        for result: Phase2AssistantShellContinuationOrchestrationResult,
        recordID: UUID,
        owner: Phase2AssistantContinuationDatabaseOwner
    ) throws -> Phase2AssistantShellContinuationTerminalSeal {
        guard let record = try owner.assistantRecord(id: recordID),
              let rawState = record.continuationCheckpoint?.logicalState,
              let expectedState = Phase2AssistantShellContinuationState(rawValue: rawState),
              !expectedState.isTerminal
        else { throw TerminalizationError.missingPreterminalCheckpoint }

        let disposition: Phase2AssistantShellContinuationTerminalSeal.Disposition
        let kind: String
        let content: String
        if Self.isCompletedContinuationResult(result),
           let answer = result.outcome?.finalCandidate?.text,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            disposition = .completed(answer: answer)
            kind = "completed"
            content = answer
        } else if case .rejected(let rejection) = result.failure {
            content = "Continuation rejected: \(String(describing: rejection))"
            disposition = .rejected(diagnostic: content)
            kind = "rejected"
        } else {
            content = Self.failureDiagnostic(result.failure)
            disposition = .failed(diagnostic: content)
            kind = "failed"
        }
        return .init(
            expectedLogicalState: expectedState,
            disposition: disposition,
            terminalEventDigest: Self.terminalEventDigest(
                identity: result.machine.turnIdentity,
                kind: kind,
                content: content
            ),
            completedAt: Date()
        )
    }

    private static func failureDiagnostic(
        _ failure: Phase2AssistantShellContinuationOrchestrationFailure?
    ) -> String {
        switch failure {
        case .executionFailed: "Restricted shell execution failed."
        case .continuationFailed: "Provider continuation failed."
        case .checkpointWriteFailed: "Continuation checkpoint write failed."
        case .conversationBusy: "The originating conversation was busy."
        case .rejected(let rejection): "Continuation rejected: \(String(describing: rejection))"
        case nil: "Continuation ended without a valid terminal result."
        }
    }

    private static func completionEvidence(
        for result: Phase2AssistantShellContinuationOrchestrationResult,
        identity: Phase2AssistantCompletionIdentity
    ) -> Phase2AssistantSameTurnShellCompletionEvidence? {
        guard isCompletedContinuationResult(result),
              let coordinate = result.machine.coordinate,
              coordinate.workspaceID == identity.workspaceID,
              coordinate.conversationID == identity.conversationID,
              coordinate.inferenceTurnID == identity.inferenceTurnID,
              coordinate.turnSequence == UInt64(identity.turnSequence),
              coordinate.originatingFinalizationRequestID == identity.originatingRequestID
        else { return nil }
        return .init(
            workspaceID: identity.workspaceID,
            documentID: identity.documentID,
            sessionID: identity.sessionID,
            conversationID: identity.conversationID,
            inferenceTurnID: identity.inferenceTurnID,
            turnSequence: identity.turnSequence,
            originatingRequestID: identity.originatingRequestID,
            proposalID: coordinate.shellProposalID,
            executionID: coordinate.shellExecutionID,
            executionResultDigest: coordinate.shellExecutionResultDigest,
            continuationRequestID: coordinate.continuationRequestID,
            providerRevision: coordinate.providerRevision
        )
    }

    private static func isCompletedContinuationResult(
        _ result: Phase2AssistantShellContinuationOrchestrationResult
    ) -> Bool {
        guard result.failure == nil,
              result.machine.state == .completed,
              let coordinate = result.machine.coordinate,
              coordinate.isIntegrityValid,
              let outcome = result.outcome,
              outcome.disposition == .completed,
              outcome.violation == nil,
              let candidate = outcome.finalCandidate,
              !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              outcome.toolProposals.isEmpty,
              outcome.shellProposals.isEmpty,
              outcome.debuggerActionProposals.isEmpty
        else { return false }
        return true
    }

    static func terminalEventDigest(
        identity: Phase2AssistantShellTurnIdentity,
        kind: String,
        content: String
    ) -> String {
        digest([
            "phase2-terminal-result-v1",
            identity.workspaceID.uuidString.lowercased(),
            identity.conversationID.uuidString.lowercased(),
            identity.inferenceTurnID.uuidString.lowercased(),
            String(identity.turnSequence),
            identity.originatingFinalizationRequestID.uuidString.lowercased(),
            kind,
            content,
        ].joined(separator: "\0"))
    }

    private static func dispatchContext(
        for coordinate: Phase2AssistantShellContinuationCoordinate,
        frozen: FrozenTurn
    ) -> Phase2AssistantShellContinuationDispatchContext? {
        guard coordinate.turnIdentity == frozen.turnIdentity,
              coordinate.providerRevision == frozen.providerRevision
        else { return nil }
        let request = frozen.request
        return .init(
            documentID: request.document.instanceID,
            workspaceID: request.workspace.instanceID,
            workspaceDocumentIdentityDigest: frozen.workspaceDocumentIdentityDigest,
            lifecycleRevision: request.lifecycleRevision,
            providerRevision: frozen.providerRevision,
            originalUserGoal: request.userGoal,
            groundedContext: request.groundedContext,
            conversationContext: request.conversationContext
                ?? .init(turns: [], omittedTurnCount: 0),
            limits: request.limits
        )
    }

    private static func presentation(
        for result: Phase2AssistantShellContinuationOrchestrationResult,
        identity: Phase2AssistantCompletionIdentity
    ) -> Phase2AssistantSameTurnShellPresentation {
        if let evidence = completionEvidence(for: result, identity: identity) {
            return .init(phase: .completed(evidence: evidence))
        }
        switch result.failure {
        case .executionFailed:
            return .init(phase: .failed(stage: .execution, detail: "The approved command did not complete."))
        case .continuationFailed:
            return .init(phase: .failed(stage: .continuation, detail: "The provider continuation did not complete."))
        case .checkpointWriteFailed:
            return .init(phase: .failed(stage: .recovery, detail: "The durable continuation checkpoint failed."))
        case .rejected:
            return .init(phase: .failed(stage: .authorityValidation, detail: "The approved authority no longer matched the frozen proposal."))
        case .conversationBusy:
            return .init(phase: .failed(stage: .recovery, detail: "The originating conversation is already active."))
        case nil:
            return .init(phase: .failed(stage: .recovery, detail: "The continuation ended without a terminal result."))
        }
    }

    private static func documentIdentityDigest(request: Phase2InferenceRequest) -> String {
        digest("phase2-document-identity-v1\0\(request.document.instanceID.uuidString.lowercased())\0\(request.workspace.instanceID.uuidString.lowercased())")
    }

    static func admitsNewContinuation(
        existingState: Phase2AssistantShellContinuationState?,
        runInFlight: Bool,
        requiresDurableRecovery: Bool = false
    ) -> Bool {
        !requiresDurableRecovery
            && !runInFlight
            && (existingState == nil || existingState?.isTerminal == true)
    }

    private static func terminalDigest(
        request: Phase2InferenceRequest,
        proposalDigest: String,
        outcome: Phase2InferenceOutcome
    ) -> String {
        digest([
            "phase2-initial-terminal-v1",
            request.requestID.uuidString.lowercased(),
            request.groundedContext.digest,
            proposalDigest,
            outcome.finalCandidate?.text ?? "",
            outcome.finalCandidate?.evidenceIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",") ?? "",
        ].joined(separator: "\0"))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct FrozenTurn {
        let request: Phase2InferenceRequest
        let proposal: Phase2AIShellCommandProposal
        let providerRevision: UInt64
        let turnIdentity: Phase2AssistantShellTurnIdentity
        let workspaceDocumentIdentityDigest: String
        let completionIdentity: Phase2AssistantCompletionIdentity
    }

    private enum TerminalizationError: Error {
        case nonterminalResult
        case missingPreterminalCheckpoint
        case retiredOwner
    }

    private struct OwnerIdentity: Equatable {
        let workspaceID: UUID
        let documentID: UUID
    }

    @MainActor
    private final class PreterminalCheckpoint: Phase2AssistantShellContinuationCheckpointing {
        private let base: any Phase2AssistantShellContinuationCheckpointing

        init(base: any Phase2AssistantShellContinuationCheckpointing) {
            self.base = base
        }

        func persistAssistantShellContinuation(
            _ machine: Phase2AssistantShellContinuationMachine
        ) async throws {
            guard !machine.state.isTerminal else { return }
            try await base.persistAssistantShellContinuation(machine)
        }
    }
}

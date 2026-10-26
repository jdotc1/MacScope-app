import AppKit
import SwiftUI
import LumenUI
import UniformTypeIdentifiers

enum Phase2AssistantRunPolicy {
    static func defaultContextOptions(
        includeApplicationGraphContext: Bool
    ) -> Phase2AssistantContextOptions {
        Phase2AssistantContextOptions(
            includeApplicationGraphContext: includeApplicationGraphContext,
            useProviderVisibleToolSelection: true
        )
    }
}

struct Phase2AssistantShellContinuationDraft: Equatable, Sendable {
    let executionID: UUID
    let intent: Phase2AssistantIntent
    let userGoal: String

    init?(result: Phase2AIShellOneShotExecutionResult) {
        guard result.disposition == .completed else { return nil }
        executionID = result.id
        intent = .askMacScope
        userGoal = "Explain the result of app-reviewed shell execution \(result.id.uuidString)."
    }
}

struct Phase2AssistantSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var nativeDecompilerPresentation: NativeDecompilerPresentationModel
    let coordinator: (any Phase2AssistantInferenceCoordinating)?
    let readiness: Phase2LocalAIProviderReadiness
    private let shellContinuationController: Phase2AssistantLiveContinuationController?
    let sameTurnShellPresentation: Phase2AssistantSameTurnShellPresentation?
    let approveSameTurnShellAction: () -> Void
    let runSameTurnShellAction: () -> Void
    let rejectSameTurnShellAction: () -> Void
    let dismissSameTurnShellAction: () -> Void
    let cancelSameTurnShellAction: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIntent: Phase2AssistantIntent = .askMacScope
    @State private var userGoal = ""
    @State private var includeApplicationGraphContext = true
    @State private var state: Phase2AssistantSheetState = .idle
    @State private var history = Phase2AssistantHistoryState()
    @State private var historyFilterText = ""
    @State private var conversations: Phase2AssistantConversationPresentation
    @State private var activeTask: Task<Void, Never>?
    @State private var activeTurnContext: Phase2AssistantConversationTurnContext?
    @State private var activePublicationToken: Phase2AssistantPublicationToken?
    @State private var shellContinuationDraft: Phase2AssistantShellContinuationDraft?

    init(
        store: WorkspaceStore,
        nativeDecompilerPresentation: NativeDecompilerPresentationModel = .init(),
        coordinator: (any Phase2AssistantInferenceCoordinating)?,
        readiness: Phase2LocalAIProviderReadiness,
        shellContinuationController: Phase2AssistantLiveContinuationController? = nil,
        sameTurnShellPresentation: Phase2AssistantSameTurnShellPresentation? = nil,
        approveSameTurnShellAction: @escaping () -> Void = {},
        runSameTurnShellAction: @escaping () -> Void = {},
        rejectSameTurnShellAction: @escaping () -> Void = {},
        dismissSameTurnShellAction: @escaping () -> Void = {},
        cancelSameTurnShellAction: @escaping () -> Void = {}
    ) {
        self.store = store
        self.nativeDecompilerPresentation = nativeDecompilerPresentation
        self.coordinator = coordinator
        self.readiness = readiness
        self.shellContinuationController = shellContinuationController
        self.sameTurnShellPresentation = sameTurnShellPresentation
        self.approveSameTurnShellAction = approveSameTurnShellAction
        self.runSameTurnShellAction = runSameTurnShellAction
        self.rejectSameTurnShellAction = rejectSameTurnShellAction
        self.dismissSameTurnShellAction = dismissSameTurnShellAction
        self.cancelSameTurnShellAction = cancelSameTurnShellAction
        let initialConversations = Self.makeConversationPresentation(
            records: store.phase2AssistantSessionHistory
        )
        _history = State(
            initialValue: Phase2AssistantHistoryState(
                persistenceRecords: store.phase2AssistantSessionHistory.filter(\.isLegacy)
            )
        )
        _conversations = State(initialValue: initialConversations)
        _state = State(initialValue: initialConversations.activeState)
    }

    private var scopedSameTurnShellPresentation: Phase2AssistantSameTurnShellPresentation? {
        guard let sameTurnShellPresentation else { return nil }
        guard let identity = shellContinuationController?.presentationIdentity else {
            return sameTurnShellPresentation
        }
        let activeTurn = conversations.activeConversation?.turns.last
        return identity.authorizesPresentation(
            workspaceID: store.workspaceID,
            documentID: store.documentID,
            activeConversationID: conversations.activeConversationID,
            activeInferenceTurnID: activeTurn?.inferenceTurnID,
            activeTurnSequence: activeTurn?.turnSequence
        ) ? sameTurnShellPresentation : nil
    }

    private var showsShellProposalReview: Bool {
        guard sameTurnShellPresentation?.isTerminal == false else { return true }
        guard let identity = shellContinuationController?.presentationIdentity else { return true }
        let activeTurn = conversations.activeConversation?.turns.last
        return identity.authorizesPresentation(
            workspaceID: store.workspaceID,
            documentID: store.documentID,
            activeConversationID: conversations.activeConversationID,
            activeInferenceTurnID: activeTurn?.inferenceTurnID,
            activeTurnSequence: activeTurn?.turnSequence
        )
    }

    var body: some View {
        HSplitView {
            Phase2AssistantConversationSidebar(
                presentation: conversations,
                isRunning: activeTask != nil,
                newConversationAction: newConversation,
                resumeConversationAction: resumeConversation,
                deleteConversationAction: deleteConversation,
                exportConversationAction: exportConversation
            )
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 250)

            VStack(spacing: 0) {
            Phase2AnalystFindingAcceptanceView(store: store)
            Phase2AssistantSheetLayout(
            selectedIntent: $selectedIntent,
            userGoal: $userGoal,
            includeApplicationGraphContext: $includeApplicationGraphContext,
            historyFilterText: $historyFilterText,
            state: state,
            conversation: conversations.activeConversation,
            history: history.entries,
            authoringProposalReview: store.phase2AssistantAuthoringProposalReview,
            shellProposalReview: store.phase2AIShellProposalReview,
            showsShellProposalReview: showsShellProposalReview,
            shellContinuationDraft: shellContinuationDraft,
            sameTurnShellPresentation: scopedSameTurnShellPresentation,
            debuggerProposalReview: store.phase2AIDebuggerProposalReview,
            readiness: readiness,
            runAction: runSelectedIntent,
            cancelAction: cancelRun,
            clearHistoryAction: clearHistory,
            reuseHistoryEntryAction: reuseHistoryEntry,
            deleteHistoryEntryAction: deleteHistoryEntry,
            acceptAuthoringProposalAction: { store.acceptPhase2AssistantAuthoringProposal() },
            rejectAuthoringProposalAction: store.rejectPhase2AssistantAuthoringProposal,
            dismissAuthoringProposalAction: store.dismissPhase2AssistantAuthoringProposalReview,
            dismissShellProposalAction: dismissShellProposalReview,
            approveShellProposalAction: approveShellProposalForFutureOneShot,
            approveShellBrokerPTYProposalAction: approveShellProposalForFutureShellBrokerPTY,
            executeShellProposalAction: executeShellProposalOneShot,
            continueWithShellResultAction: continueWithShellResult,
            approveSameTurnShellAction: approveSameTurnShellAction,
            runSameTurnShellAction: runSameTurnShellAction,
            rejectSameTurnShellAction: rejectSameTurnShellAction,
            dismissSameTurnShellAction: dismissSameTurnShellAction,
            cancelSameTurnShellAction: cancelSameTurnShellAction,
            executeShellBrokerPTYProposalAction: executeShellProposalShellBrokerPTY,
            rejectShellProposalAction: rejectShellProposalByUser,
            dismissDebuggerProposalAction: dismissDebuggerProposalReview,
            approveDebuggerProposalAction: approveDebuggerProposalForFutureControl,
            executeDebuggerProposalAction: executeDebuggerProposalControl,
            rejectDebuggerProposalAction: rejectDebuggerProposalByUser,
            closeAction: { dismiss() },
            citationAction: navigateToCitation
            )
            }
            .frame(minWidth: 620)
        }
        .frame(width: 900, height: 760)
        .onAppear {
            shellContinuationController?.refreshDatabaseOwnerForCurrentStoreIdentity()
        }
        .task {
            // After launch, or after MTPLX switches models, the inventory is stale;
            // refresh it over loopback instead of requiring Settings > Refresh Models.
            guard !readiness.isReadyForAssistant else { return }
            await coordinator?.prepareProviderForAssistant()
        }
        .onChange(of: shellContinuationController?.completionRevision) { _, revision in
            guard revision != nil,
                  let finalState = shellContinuationController?.completedDisplayState,
                  let identity = shellContinuationController?.completionIdentity
            else { return }
            guard identity.workspaceID == store.workspaceID,
                  identity.documentID == store.documentID,
                  let becameActive = try? conversations.applyCompletion(
                      finalState,
                      identity: identity
                  )
            else { return }
            if becameActive { state = finalState }
        }
        .onDisappear(perform: cancelSilently)
    }

    private func runSelectedIntent() {
        runAssistant(
            intent: selectedIntent,
            prompt: userGoal,
            contextOptions: Phase2AssistantRunPolicy.defaultContextOptions(
                includeApplicationGraphContext: includeApplicationGraphContext
            )
        )
    }

    private func runAssistant(
        intent: Phase2AssistantIntent,
        prompt: String,
        contextOptions: Phase2AssistantContextOptions
    ) {
        let effectiveGoal = intent.defaultGoal(userGoal: prompt)
        guard activeTask == nil else { return }
        guard readiness.isReadyForAssistant else {
            publishFinalState(.readinessBlocked(readiness), intent: intent, prompt: effectiveGoal)
            return
        }
        guard let coordinator else {
            publishFinalState(.readinessBlocked(.unavailable), intent: intent, prompt: effectiveGoal)
            return
        }

        let conversationID = ensureActiveConversation()
        guard let conversation = conversations.activeConversation,
              conversation.canSubmitTurn
        else {
            state = .failed(
                title: "Conversation already running",
                detail: "Wait for or retire the existing Assistant turn before starting another turn in this conversation."
            )
            return
        }
        let turnContext = store.preparePhase2AssistantConversationTurn(conversationID: conversationID)
        let turnSequence = Int(turnContext.turnSequence)
        let inferenceTurnID = turnContext.inferenceTurnID
        var updatedConversation = conversation
        do {
            try updatedConversation.appendTurn(
                Phase2AssistantConversationTurn(
                    inferenceTurnID: inferenceTurnID,
                    turnSequence: turnSequence,
                    intent: intent,
                    userMessage: effectiveGoal,
                    state: .running(intent),
                    createdAt: Date()
                )
            )
            try conversations.replaceConversation(updatedConversation)
        } catch {
            state = .failed(
                title: "Conversation identity conflict",
                detail: "MacScope refused to start a turn whose identity collided with the current conversation transcript."
            )
            return
        }

        let publicationToken = Phase2AssistantPublicationToken.capture(
            intent: intent,
            store: store
        )
        store.dismissPendingAnalystFinding()
        store.dismissPhase2AssistantAuthoringProposalReview()
        state = .running(intent)
        activeTurnContext = turnContext
        activePublicationToken = publicationToken
        activeTask = Task {
            let result = await Phase2AssistantSessionRunner().run(
                intent: intent,
                userGoal: effectiveGoal,
                store: store,
                coordinator: coordinator,
                turnContext: turnContext,
                contextOptions: contextOptions,
                nativeDecompilerState: nativeDecompilerPresentation.state
            )
            guard !Task.isCancelled else { return }
            guard publicationToken.isCurrent(in: store) else {
                publishFinalState(
                    Phase2AssistantDisplayMapper.staleResultState,
                    intent: intent,
                    prompt: effectiveGoal,
                    conversationID: conversationID,
                    turnSequence: turnSequence,
                    inferenceTurnID: inferenceTurnID,
                    turnContext: turnContext,
                    publicationToken: publicationToken
                )
                activeTurnContext = nil
                activePublicationToken = nil
                activeTask = nil
                return
            }
            store.stageAnalystFinding(from: result, publicationToken: publicationToken)
            store.stagePhase2AssistantAuthoringProposal(from: result)
            let stagingDisposition = shellContinuationController?.stageAcceptedResult(
                result,
                turnContext: turnContext
            ) ?? .notEligible
            if !stagingDisposition.ownsProviderProposals {
                result.stageAcceptedProviderProposals(in: store)
            }
            let immediateFinalState: Phase2AssistantSheetState?
            if let rejectedState = stagingDisposition.immediateFinalState {
                immediateFinalState = rejectedState
            } else if case .staged = stagingDisposition {
                immediateFinalState = nil
            } else {
                immediateFinalState = Phase2AssistantDisplayMapper.state(for: result)
            }
            if let immediateFinalState {
                publishFinalState(
                    immediateFinalState,
                    intent: intent,
                    prompt: effectiveGoal,
                    conversationID: conversationID,
                    turnSequence: turnSequence,
                    inferenceTurnID: result.request?.turnID ?? inferenceTurnID,
                    turnContext: turnContext,
                    publicationToken: publicationToken
                )
            }
            activeTurnContext = nil
            activePublicationToken = nil
            activeTask = nil
        }
    }

    private func cancelRun() {
        guard activeTask != nil else { return }
        let intent = selectedIntent
        let prompt = intent.defaultGoal(userGoal: userGoal)
        activeTask?.cancel()
        activeTask = nil
        let turnContext = activeTurnContext
        let publicationToken = activePublicationToken
        activeTurnContext = nil
        activePublicationToken = nil
        publishFinalState(
            .cancelled(
                title: "Assistant run cancelled",
                detail: "The active Assistant run was cancelled before a final answer was accepted."
            ),
            intent: intent,
            prompt: prompt,
            conversationID: turnContext?.conversationID,
            turnSequence: Int(turnContext?.turnSequence ?? 1),
            inferenceTurnID: turnContext?.inferenceTurnID,
            turnContext: turnContext,
            publicationToken: publicationToken
        )
    }

    private func cancelSilently() {
        guard activeTask != nil else { return }
        let turnContext = activeTurnContext
        activeTask?.cancel()
        activeTask = nil
        activeTurnContext = nil
        activePublicationToken = nil
        guard let turnContext,
              var conversation = conversations.conversations.first(where: {
                  $0.id == turnContext.conversationID
              })
        else { return }
        let cancelled = Phase2AssistantSheetState.cancelled(
            title: "Assistant run retired",
            detail: "The sheet closed before a final answer was accepted."
        )
        do {
            try conversation.updateTurnState(
                inferenceTurnID: turnContext.inferenceTurnID,
                state: cancelled
            )
            try conversations.replaceConversation(conversation)
        } catch {
            return
        }
        if conversations.activeConversationID == turnContext.conversationID {
            state = cancelled
        }
    }

    private func clearHistory() {
        guard activeTask == nil else { return }
        let legacyIDs = store.phase2AssistantSessionHistory.filter(\.isLegacy).map(\.id)
        history.clear()
        for id in legacyIDs {
            store.deletePhase2AssistantSessionHistoryEntry(id: id)
        }
    }

    private func reuseHistoryEntry(_ draft: Phase2AssistantHistoryDraft) {
        guard activeTask == nil else { return }
        selectedIntent = draft.intent
        userGoal = draft.userGoal
        state = .idle
    }

    private func deleteHistoryEntry(_ entryID: UUID) {
        guard activeTask == nil else { return }
        history.removeEntry(id: entryID)
        store.deletePhase2AssistantSessionHistoryEntry(id: entryID)
    }

    private func dismissShellProposalReview() {
        let review = store.phase2AIShellProposalReview
        store.dismissPhase2AIShellProposalReview()
        history.recordShellProposalReview(review, event: .dismissed)
    }

    private func approveShellProposalForFutureOneShot() {
        let review = store.approvePhase2AIShellProposalForFutureOneShot()
        history.recordShellProposalReview(review, event: .approvedForFutureOneShot)
    }

    private func approveShellProposalForFutureShellBrokerPTY() {
        let review = store.approvePhase2AIShellProposalForFutureShellBrokerPTY()
        history.recordShellProposalReview(review, event: .approvedForFutureShellBrokerPTY)
    }

    private func executeShellProposalOneShot() {
        guard store.phase2AIShellProposalReview.canExecute else { return }
        let proposalID = store.phase2AIShellProposalReview.proposal?.proposalID
        Task {
            let result = await store.executeApprovedPhase2AIShellProposalOneShot(proposalID: proposalID)
            shellContinuationDraft = Phase2AssistantShellContinuationDraft(result: result)
        }
    }

    private func continueWithShellResult() {
        guard let draft = shellContinuationDraft else { return }
        selectedIntent = draft.intent
        userGoal = draft.userGoal
        runAssistant(
            intent: draft.intent,
            prompt: draft.userGoal,
            contextOptions: Phase2AssistantContextOptions(
                includeApplicationGraphContext: includeApplicationGraphContext,
                useProviderVisibleToolSelection: true,
                shellExecutionID: draft.executionID
            )
        )
    }

    private func executeShellProposalShellBrokerPTY() {
        guard store.phase2AIShellProposalReview.canExecuteShellBrokerPTY else { return }
        let proposalID = store.phase2AIShellProposalReview.proposal?.proposalID
        Task {
            _ = await store.executeApprovedPhase2AIShellProposalShellBrokerPTY(proposalID: proposalID)
        }
    }

    private func rejectShellProposalByUser() {
        let review = store.rejectPhase2AIShellProposalReviewByUser()
        history.recordShellProposalReview(review, event: .rejectedByUser)
    }

    private func dismissDebuggerProposalReview() {
        store.dismissPhase2AIDebuggerProposalReview()
    }

    private func approveDebuggerProposalForFutureControl() {
        _ = store.approvePhase2AIDebuggerProposalForFutureControl()
    }

    private func executeDebuggerProposalControl() {
        let proposalID = store.phase2AIDebuggerProposalReview.proposal?.proposalID
        Task {
            _ = await store.executeApprovedPhase2AIDebuggerProposalControl(proposalID: proposalID)
        }
    }

    private func rejectDebuggerProposalByUser() {
        _ = store.rejectPhase2AIDebuggerProposalReviewByUser()
    }

    private func navigateToCitation(_ citation: Phase2AssistantCitationDisplay) {
        guard citation.isNavigable else { return }
        _ = store.navigateToPhase2Citation(citation.target)
    }

    private func publishFinalState(
        _ finalState: Phase2AssistantSheetState,
        intent: Phase2AssistantIntent,
        prompt: String,
        conversationID: UUID? = nil,
        turnSequence: Int = 1,
        inferenceTurnID: UUID? = nil,
        turnContext: Phase2AssistantConversationTurnContext? = nil,
        publicationToken: Phase2AssistantPublicationToken? = nil
    ) {
        state = finalState
        if let conversationID,
           let inferenceTurnID,
           var conversation = conversations.conversations.first(where: { $0.id == conversationID }) {
            try? conversation.updateTurnState(inferenceTurnID: inferenceTurnID, state: finalState)
            try? conversations.replaceConversation(conversation)
        } else {
            history.record(finalState, intent: intent, userGoal: prompt)
        }
        if let turnContext, let publicationToken {
            store.recordPhase2AssistantTerminalState(
                finalState,
                intent: intent,
                userGoal: prompt,
                turnContext: turnContext,
                publicationToken: publicationToken
            )
        } else {
            store.recordPhase2AssistantTerminalState(
                finalState,
                intent: intent,
                userGoal: prompt,
                conversationID: conversationID,
                turnSequence: turnSequence,
                inferenceTurnID: inferenceTurnID
            )
        }
    }

    private func ensureActiveConversation() -> UUID {
        if let id = conversations.activeConversationID { return id }
        return conversations.newConversation()
    }

    private func newConversation() {
        guard activeTask == nil else { return }
        _ = conversations.newConversation()
        state = .idle
        userGoal = ""
    }

    private func resumeConversation(_ id: UUID) {
        guard activeTask == nil else { return }
        try? conversations.resumeConversation(id: id)
        state = conversations.activeState
    }

    private func deleteConversation(_ id: UUID) {
        guard activeTask == nil,
              let conversation = conversations.conversations.first(where: { $0.id == id }) else { return }
        let recordIDs = store.phase2AssistantSessionHistory
            .filter { $0.conversationID == conversation.id && !$0.isLegacy }
            .map(\.id)
        for recordID in recordIDs {
            store.deletePhase2AssistantSessionHistoryEntry(id: recordID)
        }
        _ = conversations.deleteConversation(id: id)
        state = conversations.activeState
    }

    private func exportConversation(_ id: UUID) {
        guard let conversation = conversations.conversations.first(where: { $0.id == id }),
              let snapshot = Phase2AssistantConversationExportSnapshot(conversation: conversation) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(snapshot.suggestedFilename).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? snapshot.text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func makeConversationPresentation(
        records: [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord]
    ) -> Phase2AssistantConversationPresentation {
        let legacyRecords = records.filter(\.isLegacy)
        let legacy = Phase2AssistantHistoryState(persistenceRecords: legacyRecords).entries
        let grouped = Dictionary(grouping: records.filter { !$0.isLegacy }, by: \.conversationID)
        let conversations = grouped.map { conversationID, records in
            let ordered = records.sorted { $0.turnSequence < $1.turnSequence }
            let turns = ordered.compactMap { record -> Phase2AssistantConversationTurn? in
                guard let entry = Phase2AssistantHistoryState(persistenceRecords: [record], limit: 1).entries.first else {
                    return nil
                }
                return Phase2AssistantConversationTurn(
                    inferenceTurnID: record.inferenceTurnID,
                    turnSequence: record.turnSequence,
                    intent: entry.intent,
                    userMessage: record.userGoal,
                    state: entry.state,
                    createdAt: record.createdAt
                )
            }
            let firstPrompt = ordered.first?.userGoal.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = firstPrompt.isEmpty ? "Conversation" : String(firstPrompt.prefix(42))
            return Phase2AssistantConversation(
                conversationID: conversationID,
                title: title,
                createdAt: ordered.first?.createdAt ?? Date(),
                turns: turns
            )
        }
        let activeID = conversations.sorted { $0.lastActivityAt > $1.lastActivityAt }.first?.id
        return Phase2AssistantConversationPresentation(
            conversations: conversations,
            activeConversationID: activeID,
            legacyRuns: legacy
        )
    }
}

extension Phase2AssistantConversationPresentation {
    @discardableResult
    mutating func applyCompletion(
        _ state: Phase2AssistantSheetState,
        identity: Phase2AssistantCompletionIdentity
    ) throws -> Bool {
        guard var conversation = conversations.first(where: {
            $0.conversationID == identity.conversationID
        }),
        conversation.turns.contains(where: {
            $0.inferenceTurnID == identity.inferenceTurnID
                && $0.turnSequence == identity.turnSequence
        }) else {
            throw Phase2AssistantConversationMutationError.turnNotFound
        }
        try conversation.updateTurnState(
            inferenceTurnID: identity.inferenceTurnID,
            state: state
        )
        try replaceConversation(conversation)
        let activeTurn = activeConversation?.turns.last
        return activeConversationID == identity.conversationID
            && activeTurn?.inferenceTurnID == identity.inferenceTurnID
            && activeTurn?.turnSequence == identity.turnSequence
    }
}

private struct Phase2AssistantSheetLayout: View {
    @Binding var selectedIntent: Phase2AssistantIntent
    @Binding var userGoal: String
    @Binding var includeApplicationGraphContext: Bool
    @Binding var historyFilterText: String
    let state: Phase2AssistantSheetState
    let conversation: Phase2AssistantConversation?
    let history: [Phase2AssistantHistoryEntry]
    let authoringProposalReview: Phase2AssistantAuthoringProposalReviewState
    let shellProposalReview: Phase2AIShellProposalReviewState
    let showsShellProposalReview: Bool
    let shellContinuationDraft: Phase2AssistantShellContinuationDraft?
    let sameTurnShellPresentation: Phase2AssistantSameTurnShellPresentation?
    let debuggerProposalReview: Phase2AIDebuggerProposalReviewState
    let readiness: Phase2LocalAIProviderReadiness
    let runAction: () -> Void
    let cancelAction: () -> Void
    let clearHistoryAction: () -> Void
    let reuseHistoryEntryAction: (Phase2AssistantHistoryDraft) -> Void
    let deleteHistoryEntryAction: (UUID) -> Void
    let acceptAuthoringProposalAction: () -> Void
    let rejectAuthoringProposalAction: () -> Void
    let dismissAuthoringProposalAction: () -> Void
    let dismissShellProposalAction: () -> Void
    let approveShellProposalAction: () -> Void
    let approveShellBrokerPTYProposalAction: () -> Void
    let executeShellProposalAction: () -> Void
    let continueWithShellResultAction: () -> Void
    let approveSameTurnShellAction: () -> Void
    let runSameTurnShellAction: () -> Void
    let rejectSameTurnShellAction: () -> Void
    let dismissSameTurnShellAction: () -> Void
    let cancelSameTurnShellAction: () -> Void
    let executeShellBrokerPTYProposalAction: () -> Void
    let rejectShellProposalAction: () -> Void
    let dismissDebuggerProposalAction: () -> Void
    let approveDebuggerProposalAction: () -> Void
    let executeDebuggerProposalAction: () -> Void
    let rejectDebuggerProposalAction: () -> Void
    let closeAction: () -> Void
    let citationAction: (Phase2AssistantCitationDisplay) -> Void

    private var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    private var isComposerBlocked: Bool {
        isRunning
            || conversation?.canSubmitTurn == false
            || sameTurnShellPresentation?.blocksComposer == true
    }

    private var isDirectRunRunning: Bool {
        isRunning && sameTurnShellPresentation?.blocksComposer != true
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: Lumen.Space.s7) {
            Phase2AssistantHeader()

            Phase2AssistantReadinessBanner(readiness: readiness)

            Phase2AssistantIntentPicker(
                selectedIntent: $selectedIntent,
                isDisabled: isComposerBlocked
            )

            Phase2AssistantPromptField(
                selectedIntent: selectedIntent,
                userGoal: $userGoal,
                isDisabled: isComposerBlocked
            )

            Phase2AssistantContextOptionsView(
                selectedIntent: selectedIntent,
                includeApplicationGraphContext: $includeApplicationGraphContext,
                isDisabled: isComposerBlocked
            )

            Phase2AssistantContextDisclosureView(
                title: "Context",
                disclosure: Phase2AssistantDisplayMapper.contextPreview(
                    intent: selectedIntent,
                    options: Phase2AssistantRunPolicy.defaultContextOptions(
                        includeApplicationGraphContext: includeApplicationGraphContext
                    )
                )
            )

            Phase2AssistantAuthoringProposalReviewCard(
                review: authoringProposalReview,
                acceptAction: acceptAuthoringProposalAction,
                rejectAction: rejectAuthoringProposalAction,
                dismissAction: dismissAuthoringProposalAction,
                citationAction: citationAction
            )

            if showsShellProposalReview {
                Phase2AIShellProposalReviewCard(
                    review: shellProposalReview,
                    dismissAction: dismissShellProposalAction,
                    approveAction: approveShellProposalAction,
                    approveShellBrokerPTYAction: approveShellBrokerPTYProposalAction,
                    executeAction: executeShellProposalAction,
                    executeShellBrokerPTYAction: executeShellBrokerPTYProposalAction,
                    rejectAction: rejectShellProposalAction,
                    showsActions: sameTurnShellPresentation == nil
                )
            }

            if let sameTurnShellPresentation {
                Phase2AssistantSameTurnShellStatusCard(
                    presentation: sameTurnShellPresentation,
                    approveAction: approveSameTurnShellAction,
                    runAction: runSameTurnShellAction,
                    rejectAction: rejectSameTurnShellAction,
                    dismissAction: dismissSameTurnShellAction,
                    cancelAction: cancelSameTurnShellAction
                )
            }

            if shellContinuationDraft != nil,
               sameTurnShellPresentation?.showsManualShellResultContinuation != false {
                Button("Continue with Shell Result", action: continueWithShellResultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isComposerBlocked)
            }

            Phase2AIDebuggerProposalReviewCard(
                review: debuggerProposalReview,
                dismissAction: dismissDebuggerProposalAction,
                approveAction: approveDebuggerProposalAction,
                executeAction: executeDebuggerProposalAction,
                rejectAction: rejectDebuggerProposalAction
            )

            Phase2AssistantTranscript(
                conversation: conversation,
                citationAction: citationAction
            )

            if conversation?.turns.last?.state != state {
                Phase2AssistantResultPanel(
                    state: state,
                    citationAction: citationAction,
                    retryAction: runAction
                )
            }

            Phase2AssistantHistoryPanel(
                history: history,
                filterText: $historyFilterText,
                clearAction: clearHistoryAction,
                reuseEntryAction: reuseHistoryEntryAction,
                deleteEntryAction: deleteHistoryEntryAction
            )
                .environment(\.isEnabled, !isComposerBlocked)

            Phase2AssistantFooter(
                isRunning: isDirectRunRunning,
                isRunEnabled: readiness.isReadyForAssistant && !isComposerBlocked,
                runAction: runAction,
                cancelAction: cancelAction,
                closeAction: closeAction
            )
        }
        .padding(Lumen.Space.s8)
        }
        .workbenchPaneBackground(.inspector)
    }
}

private struct Phase2AssistantConversationSidebar: View {
    let presentation: Phase2AssistantConversationPresentation
    let isRunning: Bool
    let newConversationAction: () -> Void
    let resumeConversationAction: (UUID) -> Void
    let deleteConversationAction: (UUID) -> Void
    let exportConversationAction: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            HStack {
                Text("Conversations")
                    .font(.headline)
                    .lumenNeverTruncates("Conversations")
                Spacer()
                Button(action: newConversationAction) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isRunning)
                .help("New Assistant conversation")
                .accessibilityLabel("New Assistant conversation")
            }
            .padding(.horizontal, Lumen.Space.s5)

            List(selection: Binding(
                get: { presentation.activeConversationID },
                set: { id in if let id { resumeConversationAction(id) } }
            )) {
                ForEach(presentation.resumableConversations) { conversation in
                    VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                        Text(conversation.title)
                            .lineLimit(2)
                        Text("\(conversation.turns.count) turn\(conversation.turns.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Export…") { exportConversationAction(conversation.id) }
                            .disabled(conversation.turns.isEmpty)
                        Divider()
                        Button("Delete", role: .destructive) { deleteConversationAction(conversation.id) }
                            .disabled(isRunning)
                    }
                }

                if !presentation.legacyRuns.isEmpty {
                    Section("Legacy Runs · Read Only") {
                        ForEach(presentation.legacyRuns) { entry in
                            VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                                Text(entry.title)
                                Text(entry.status)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .help("Legacy runs are retained for review but never sent to the provider.")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(.top, Lumen.Space.s6)
        .workbenchPaneBackground(.sidebar)
    }
}

private struct Phase2AssistantTranscript: View {
    let conversation: Phase2AssistantConversation?
    let citationAction: (Phase2AssistantCitationDisplay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Conversation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let conversation, !conversation.turns.isEmpty {
                let projection = conversation.transcriptProjection()
                if projection.omittedTurnCount > 0 {
                    Text(
                        "Showing the newest \(projection.turns.count) turns; "
                            + "\(projection.omittedTurnCount) older turns remain available in the conversation export."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(projection.omittedTurnCount) older Assistant conversation turns are omitted from this bounded transcript view"
                    )
                }
                LazyVStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    ForEach(projection.turns) { turn in
                        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                            Text("You")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(turn.userMessage)
                                .textSelection(.enabled)
                            Divider()
                            Text("MacScope")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Phase2AssistantResultContent(
                                state: turn.state,
                                citationAction: citationAction,
                                retryAction: {}
                            )
                        }
                        .padding(Lumen.Space.s6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.lumen(.bgElevated),
                            in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                        )
                    }
                }
            } else {
                Phase2AssistantEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "Start a conversation",
                    detail: "Ask a grounded question about the current workspace. Completed turns can provide bounded context to the next turn."
                )
                .padding(Lumen.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.lumen(.bgElevated),
                    in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                )
            }
        }
    }
}

private struct Phase2AssistantContextOptionsView: View {
    let selectedIntent: Phase2AssistantIntent
    @Binding var includeApplicationGraphContext: Bool
    let isDisabled: Bool

    var body: some View {
        if selectedIntent == .askMacScope {
            Toggle("Include dependency graph context", isOn: $includeApplicationGraphContext)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(isDisabled)
                .help("Adds a read-only summary of the focused image's declared and external dependencies to the grounded context.")
        }
    }
}

private struct Phase2AssistantContextDisclosureView: View {
    let title: String
    let disclosure: Phase2AssistantContextDisclosureDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                Phase2AssistantContextOperationLine(
                    label: "Sent",
                    operations: disclosure.actualOperations.isEmpty
                        ? disclosure.plannedOperations
                        : disclosure.actualOperations
                )

                if !disclosure.excludedOperations.isEmpty {
                    Phase2AssistantContextOperationLine(
                        label: "Excluded",
                        operations: disclosure.excludedOperations
                    )
                }

                if !disclosure.omittedEvidence.isEmpty {
                    Text("Omitted evidence: \(disclosure.omittedEvidence.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let canonicalByteCount = disclosure.canonicalByteCount,
                   let digest = disclosure.digest {
                    Text("\(canonicalByteCount) canonical bytes · \(String(digest.prefix(12)))…")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("\(disclosure.authoritySummary) \(disclosure.retentionSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Lumen.Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous)
                    .stroke(Color.lumen(.borderDefault))
            }
        }
    }
}

private struct Phase2AssistantContextOperationLine: View {
    let label: String
    let operations: [Phase2AssistantContextOperationDisplay]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            FlowingContextOperations(operations: operations)
        }
    }
}

private struct FlowingContextOperations: View {
    let operations: [Phase2AssistantContextOperationDisplay]

    var body: some View {
        HStack(spacing: Lumen.Space.s4) {
            ForEach(operations) { operation in
                Text(operation.id)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, Lumen.Space.s4)
                    .padding(.vertical, Lumen.Space.s1)
                    .background(Color.lumen(.bgCanvas), in: Capsule())
                    .help(operation.detail)
            }
        }
    }
}

private struct Phase2AssistantHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Label("Ask MacScope", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Text("Runs one grounded Phase 2 read, then asks the selected local model for a cited final answer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Phase2AssistantReadinessBanner: View {
    let readiness: Phase2LocalAIProviderReadiness

    var body: some View {
        HStack(alignment: .top, spacing: Lumen.Space.s5) {
            Image(systemName: readiness.isReadyForAssistant ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(readiness.isReadyForAssistant ? Color.lumen(.statusSuccess) : Color.lumen(.statusWarning))
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                Text(readiness.assistantTitle)
                    .font(.headline)
                Text(readiness.assistantDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Lumen.Space.s6)
        .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                .stroke(Color.lumen(.borderDefault))
        }
    }
}

private struct Phase2AssistantAuthoringProposalReviewCard: View {
    let review: Phase2AssistantAuthoringProposalReviewState
    let acceptAction: () -> Void
    let rejectAction: () -> Void
    let dismissAction: () -> Void
    let citationAction: (Phase2AssistantCitationDisplay) -> Void

    var body: some View {
        if let proposal = review.proposal {
            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
                    Text("Assistant Proposal · \(proposal.operation.title)")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: Lumen.Space.s5)
                    Text(review.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Dismiss", action: dismissAction)
                        .controlSize(.small)
                }

                Text("This is an inert, evidence-bound suggestion. Accept applies one existing undoable workspace edit; Reject changes nothing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Phase2AIShellProposalFactRow(label: "Image/address", value: proposal.imageAddressLabel)
                Phase2AIShellProposalFactRow(label: "Instruction", value: proposal.instructionSpanLabel)
                Phase2AIShellProposalFactRow(label: "Evidence", value: proposal.evidenceID.uuidString)

                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    Text("Diff")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("− \(proposal.originalDisplayValue)\n+ \(proposal.value)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Lumen.Space.s4)
                .background(Color.lumen(.bgCanvas), in: RoundedRectangle(cornerRadius: Lumen.Radius.md, style: .continuous))

                if !proposal.citationDisplays.isEmpty {
                    HStack(spacing: Lumen.Space.s4) {
                        Text("Evidence links")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(proposal.citationDisplays) { citation in
                            Button(citation.detail) { citationAction(citation) }
                                .buttonStyle(.link)
                                .controlSize(.small)
                                .disabled(!citation.isNavigable)
                        }
                    }
                }

                HStack(spacing: Lumen.Space.s5) {
                    Button("Accept", action: acceptAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!review.canDecide)
                    Button("Reject", action: rejectAction)
                        .controlSize(.small)
                        .disabled(!review.canDecide)
                }
            }
            .padding(Lumen.Space.s5)
            .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                    .stroke(Color.lumen(.borderDefault))
            }
        }
    }
}

private struct Phase2AIShellProposalReviewCard: View {
    let review: Phase2AIShellProposalReviewState
    let dismissAction: () -> Void
    let approveAction: () -> Void
    let approveShellBrokerPTYAction: () -> Void
    let executeAction: () -> Void
    let executeShellBrokerPTYAction: () -> Void
    let rejectAction: () -> Void
    let showsActions: Bool

    var body: some View {
        if review.isActive {
            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
                    Text(review.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(review.isStaged ? .primary : .secondary)
                    Spacer(minLength: Lumen.Space.s5)
                    Button("Dismiss", action: dismissAction)
                        .controlSize(.small)
                        .disabled(!review.canDismiss)
                }

                Text(review.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Phase2AIShellProposalFactRow(label: "Decision", value: review.humanDecisionSummary)
                if let argvPreview = review.argvPreview {
                    Phase2AIShellProposalFactRow(label: "Command", value: argvPreview)
                }
                if let workingDirectoryPreview = review.workingDirectoryPreview {
                    Phase2AIShellProposalFactRow(label: "Working directory", value: workingDirectoryPreview)
                }
                if let limitsPreview = review.limitsPreview {
                    Phase2AIShellProposalFactRow(label: "Limits", value: limitsPreview)
                }
                Phase2AIShellProposalFactRow(label: "Authority", value: review.authoritySummary)

                if !review.environmentPreview.isEmpty {
                    DisclosureGroup("Environment (\(review.environmentPreview.count))") {
                        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                            ForEach(review.environmentPreview, id: \.self) { entry in
                                Text(entry)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if !review.issueSummaries.isEmpty {
                    DisclosureGroup("Validation issues (\(review.issueSummaries.count))") {
                        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                            ForEach(review.issueSummaries, id: \.self) { issue in
                                Text("• \(issue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: Lumen.Space.s5) {
                    if showsActions {
                        Button("Approve Future", action: approveAction)
                            .controlSize(.small)
                            .disabled(!review.canApproveForFutureOneShot)
                            .accessibilityLabel("Approve shell proposal for future one-shot execution")
                            .accessibilityHint("Approves the reviewed command but does not execute it")
                        Button("Approve PTY", action: approveShellBrokerPTYAction)
                            .controlSize(.small)
                            .disabled(!review.canApproveForFutureShellBrokerPTY)
                            .accessibilityLabel("Approve shell proposal for future PTY transport")
                            .accessibilityHint("Approves the reviewed command but does not send it")
                        Button("Execute", action: executeAction)
                            .controlSize(.small)
                            .disabled(!review.canExecute)
                            .accessibilityLabel("Execute approved restricted one-shot command")
                        Button("Send to PTY", action: executeShellBrokerPTYAction)
                            .controlSize(.small)
                            .disabled(!review.canExecuteShellBrokerPTY)
                            .accessibilityLabel("Send approved command to ShellBroker PTY")
                        Button("Reject", action: rejectAction)
                            .controlSize(.small)
                            .disabled(!review.canRejectByUser)
                    }
                    Button("Copy Review", action: copyReview)
                        .controlSize(.small)
                        .disabled(!review.canCopyReview || review.reviewPlainTextExport == nil)
                    Button("Copy JSON", action: copyReviewJSON)
                        .controlSize(.small)
                        .disabled(!review.canCopyReviewJSON || review.reviewJSONExport == nil)
                    Button("Copy argv", action: copyArgv)
                        .controlSize(.small)
                        .disabled(!review.canCopyArgv || review.argvPreview == nil)
                    Text(showsActions
                        ? (review.canExecute || review.canExecuteShellBrokerPTY ? "Approved execution available." : "Approval required before execution.")
                        : "Same-turn execution status appears below.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Lumen.Space.s5)
            .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                    .stroke(Color.lumen(.borderDefault))
            }
        }
    }

    private func copyArgv() {
        guard review.canCopyArgv,
              let argvPreview = review.argvPreview
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(argvPreview, forType: .string)
    }

    private func copyReview() {
        guard review.canCopyReview,
              let reviewText = review.reviewPlainTextExport
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reviewText, forType: .string)
    }

    private func copyReviewJSON() {
        guard review.canCopyReviewJSON,
              let reviewJSON = review.reviewJSONExport
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reviewJSON, forType: .string)
    }
}

private struct Phase2AssistantSameTurnShellStatusCard: View {
    let presentation: Phase2AssistantSameTurnShellPresentation
    let approveAction: () -> Void
    let runAction: () -> Void
    let rejectAction: () -> Void
    let dismissAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Lumen.Space.s5) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: presentation.statusSystemImage)
                    .foregroundStyle(
                        presentation.statusSystemImage == "terminal"
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)

                if let evidence = presentation.completionEvidence {
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        ForEach(evidence.facts) { fact in
                            Phase2AssistantEvidenceFactRow(fact: fact)
                        }
                    }
                    .padding(.top, Lumen.Space.s4)
                    .accessibilityElement(children: .contain)
                }
            }

            Spacer(minLength: Lumen.Space.s5)

            if presentation.showsApproveAction {
                Button("Approve", action: approveAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approve same-turn shell proposal")
                    .accessibilityHint("Reserves the exact reviewed command but does not run it")
            }
            if presentation.showsRejectAction {
                Button("Reject", action: rejectAction)
                    .accessibilityLabel("Reject same-turn shell proposal")
            }
            if presentation.showsDismissAction {
                Button("Dismiss", action: dismissAction)
                    .accessibilityLabel("Dismiss same-turn shell proposal")
                    .accessibilityHint("Ends this Assistant turn without executing the command")
            }
            if presentation.showsRunAction {
                Button("Run", action: runAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Run approved same-turn shell command")
                    .accessibilityHint("Executes the exact approved restricted command once")
            }
            if presentation.showsCancelAction {
                Button("Cancel", action: cancelAction)
                    .accessibilityLabel("Cancel approved same-turn shell command")
                    .accessibilityHint("Cancels before restricted execution begins")
            }
        }
        .padding(Lumen.Space.s6)
        .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                .stroke(Color.lumen(.borderDefault))
        }
    }
}

private struct Phase2AIDebuggerProposalReviewCard: View {
    let review: Phase2AIDebuggerProposalReviewState
    let dismissAction: () -> Void
    let approveAction: () -> Void
    let executeAction: () -> Void
    let rejectAction: () -> Void

    var body: some View {
        if review.isActive {
            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
                    Text(review.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(review.isStaged ? .primary : .secondary)
                    Spacer(minLength: Lumen.Space.s5)
                    Button("Dismiss", action: dismissAction)
                        .controlSize(.small)
                }

                Text("Provider requested an inert debugger run-control action. MacScope records the exact runtime coordinate for review; the model cannot execute LLDB commands directly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let proposal = review.proposal {
                    Phase2AIShellProposalFactRow(label: "Action", value: proposal.action.title)
                    Phase2AIShellProposalFactRow(label: "Session", value: proposal.sessionID.uuidString)
                    Phase2AIShellProposalFactRow(
                        label: "Revisions",
                        value: "lifecycle \(proposal.lifecycleRevision), stop \(proposal.stopRevision.map(String.init) ?? "none"), event \(proposal.eventSequence.map(String.init) ?? "none")"
                    )
                    Phase2AIShellProposalFactRow(
                        label: "Authority",
                        value: proposal.requestedAuthority.rawValue
                    )
                }
                Phase2AIShellProposalFactRow(label: "Decision", value: debuggerDecisionSummary)
                Phase2AIShellProposalFactRow(label: "Boundary", value: review.authoritySummary)

                if !review.validationResult.issues.isEmpty {
                    DisclosureGroup("Validation issues (\(review.validationResult.issues.count))") {
                        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                            ForEach(review.validationResult.issues.map(\.displaySummary), id: \.self) { issue in
                                Text("• \(issue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: Lumen.Space.s5) {
                    Button("Approve", action: approveAction)
                        .controlSize(.small)
                        .disabled(!review.canApproveForFutureDebuggerControl)
                    Button("Run", action: executeAction)
                        .controlSize(.small)
                        .disabled(!review.canExecuteDebuggerControl)
                    Button("Reject", action: rejectAction)
                        .controlSize(.small)
                        .disabled(!review.isActive)
                    Button("Copy Review", action: copyReview)
                        .controlSize(.small)
                        .disabled(review.reviewPlainTextExport == nil)
                    Text(review.canExecuteDebuggerControl ? "Run dispatches through MacScope's existing debugger controls." : "No debugger action will run from this card.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Lumen.Space.s5)
            .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                    .stroke(Color.lumen(.borderDefault))
            }
        }
    }

    private var debuggerDecisionSummary: String {
        switch review.humanDecision {
        case .none: "none"
        case .pendingReview: "pending review"
        case .approvedForFutureDebuggerControl: "approved for future debugger control"
        case .rejectedByUser: "rejected by user"
        case .blockedByValidation: "blocked by validation"
        }
    }

    private func copyReview() {
        guard let reviewText = review.reviewPlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reviewText, forType: .string)
    }
}

private struct Phase2AIShellProposalFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct Phase2AssistantIntentPicker: View {
    @Binding var selectedIntent: Phase2AssistantIntent
    let isDisabled: Bool

    var body: some View {
        Picker("Assistant action", selection: $selectedIntent) {
            ForEach(Phase2AssistantIntent.allCases, id: \.self) { intent in
                Text(intent.title).tag(intent)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isDisabled)
    }
}

private struct Phase2AssistantPromptField: View {
    let selectedIntent: Phase2AssistantIntent
    @Binding var userGoal: String
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("Prompt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $userGoal)
                .font(.body)
                .frame(minHeight: 86, maxHeight: 120)
                .padding(Lumen.Space.s4)
                .background(Color.lumen(.bgCanvas), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if userGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(selectedIntent.defaultGoal(userGoal: ""))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Lumen.Space.s5)
                            .padding(.vertical, Lumen.Space.s5)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(isDisabled)
        }
    }
}

private struct Phase2AssistantResultPanel: View {
    let state: Phase2AssistantSheetState
    let citationAction: (Phase2AssistantCitationDisplay) -> Void
    let retryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Phase2AssistantResultContent(
                state: state,
                citationAction: citationAction,
                retryAction: retryAction
            )
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                .padding(Lumen.Space.s6)
                .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                        .stroke(Color.lumen(.borderDefault))
                }
        }
    }
}

private struct Phase2AssistantResultContent: View {
    let state: Phase2AssistantSheetState
    let citationAction: (Phase2AssistantCitationDisplay) -> Void
    let retryAction: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Phase2AssistantEmptyState(
                systemImage: "text.bubble",
                title: "No assistant run yet",
                detail: "Choose an action and run a grounded finalization pass."
            )
        case .running(let intent):
            HStack(spacing: Lumen.Space.s5) {
                ProgressView()
                Text("Running \(intent.title)…")
                    .foregroundStyle(.secondary)
            }
        case .readinessBlocked(let readiness):
            Phase2AssistantStoppedResult(
                systemImage: "exclamationmark.triangle",
                title: readiness.assistantTitle,
                detail: readiness.assistantDetail,
                activity: state.stopActivity,
                isRetryable: state.isRetryableTerminalState,
                retryAction: retryAction
            )
        case .failed(let title, let detail):
            Phase2AssistantStoppedResult(
                systemImage: "xmark.octagon",
                title: title,
                detail: detail,
                activity: state.stopActivity,
                isRetryable: state.isRetryableTerminalState,
                retryAction: retryAction
            )
        case .cancelled(let title, let detail):
            Phase2AssistantStoppedResult(
                systemImage: "stop.circle",
                title: title,
                detail: detail,
                activity: state.stopActivity,
                isRetryable: state.isRetryableTerminalState,
                retryAction: retryAction
            )
        case .completed(let display):
            Phase2AssistantCompletedResult(
                display: display,
                citationAction: citationAction
            )
        }
    }
}

private struct Phase2AssistantStoppedResult: View {
    let systemImage: String
    let title: String
    let detail: String
    let activity: Phase2AssistantActivityDisplay?
    let isRetryable: Bool
    let retryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            HStack(alignment: .top, spacing: Lumen.Space.s6) {
                Phase2AssistantEmptyState(
                    systemImage: systemImage,
                    title: title,
                    detail: detail
                )

                Spacer(minLength: Lumen.Space.s6)

                Button("Retry", action: retryAction)
                    .controlSize(.small)
                    .disabled(!isRetryable)
            }

            if let activity {
                Divider()
                Phase2AssistantActivityCard(activity: activity)
            }
        }
    }
}

private struct Phase2AssistantHistoryPanel: View {
    let history: [Phase2AssistantHistoryEntry]
    @Binding var filterText: String
    let clearAction: () -> Void
    let reuseEntryAction: (Phase2AssistantHistoryDraft) -> Void
    let deleteEntryAction: (UUID) -> Void

    private var visibleHistory: [Phase2AssistantHistoryEntry] {
        history.filter { $0.matchesHistoryFilter(filterText) }
    }

    private var visibleHistoryClipboardText: String? {
        historyExportSnapshot?.text
    }

    private var historyExportSnapshot: Phase2AssistantHistoryExportSnapshot? {
        Phase2AssistantHistoryExportSnapshot(entries: history, filterText: filterText)
    }

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if !history.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    HStack(spacing: Lumen.Space.s4) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter history", text: $filterText)
                            .textFieldStyle(.plain)
                        if isFiltering {
                            Button("Clear") {
                                filterText = ""
                            }
                            .controlSize(.small)
                            .help("Clear Assistant history filter")
                        }
                    }
                    .padding(.horizontal, Lumen.Space.s5)
                    .padding(.vertical, Lumen.Space.s4)
                    .background(
                        Color.lumen(.bgCanvas),
                        in: RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous)
                    )

                    if visibleHistory.isEmpty {
                        Text("No Assistant history entries match this filter.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Lumen.Space.s4)
                    } else {
                        ForEach(visibleHistory) { entry in
                            Phase2AssistantHistoryRow(
                                entry: entry,
                                reuseAction: { reuseEntryAction(entry.draft) },
                                deleteAction: { deleteEntryAction(entry.id) }
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: Lumen.Space.s5) {
                    Text(historyCountLabel)
                    Spacer(minLength: Lumen.Space.s5)
                    Button("Copy All") {
                        copyAllHistory()
                    }
                    .controlSize(.small)
                    .disabled(visibleHistoryClipboardText == nil)
                    .help(
                        isFiltering
                            ? "Copy filtered Assistant session history entries"
                            : "Copy all visible Assistant session history entries"
                    )
                    Button("Save Visible…") {
                        saveVisibleHistory()
                    }
                    .controlSize(.small)
                    .disabled(historyExportSnapshot == nil)
                    .help(
                        isFiltering
                            ? "Save filtered Assistant session history entries"
                            : "Save all visible Assistant session history entries"
                    )
                    Button("Clear") {
                        clearAction()
                    }
                    .controlSize(.small)
                    .help("Clear persisted Assistant history for this workspace")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var historyCountLabel: String {
        if isFiltering {
            return "Session history (\(visibleHistory.count) of \(history.count))"
        }
        return "Session history (\(history.count))"
    }

    private func copyAllHistory() {
        guard let historyClipboardText = visibleHistoryClipboardText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyClipboardText, forType: .string)
    }

    private func saveVisibleHistory() {
        guard let snapshot = historyExportSnapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(snapshot.suggestedFilename).txt"
        panel.message = snapshot.isFiltered
            ? "Save the currently filtered Assistant history as UTF-8 text."
            : "Save the visible Assistant history as UTF-8 text."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshot.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not save Assistant history"
            alert.informativeText = "MacScope could not save \(url.lastPathComponent): \(error.localizedDescription)"
            alert.runModal()
        }
    }
}

private struct Phase2AssistantHistoryRow: View {
    let entry: Phase2AssistantHistoryEntry
    let reuseAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Lumen.Space.s5) {
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                HStack(spacing: Lumen.Space.s4) {
                    Text(entry.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(entry.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Lumen.Space.s5)
            Menu("Copy") {
                Button("Entry", action: copyEntry)
                Button("Citations", action: copyCitations)
                    .disabled(entry.citationPlainTextExport == nil)
                Button("Evidence", action: copyEvidence)
                    .disabled(entry.evidencePlainTextExport == nil)
                Button("Context", action: copyContext)
                    .disabled(entry.contextPlainTextExport == nil)
            }
            .controlSize(.small)
            .help("Copy this Assistant session entry, citations, evidence, or context")

            Button("Use", action: reuseAction)
                .controlSize(.small)
                .disabled(!entry.canReuseDraft)
                .help("Use this Assistant session entry as the current prompt")

            Button("Delete", action: deleteAction)
                .controlSize(.small)
                .help("Delete this Assistant session entry")
        }
        .padding(Lumen.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lumen(.bgCanvas), in: RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous))
    }

    private func copyEntry() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.plainTextExport, forType: .string)
    }

    private func copyCitations() {
        guard let citationText = entry.citationPlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(citationText, forType: .string)
    }

    private func copyEvidence() {
        guard let evidenceText = entry.evidencePlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(evidenceText, forType: .string)
    }

    private func copyContext() {
        guard let contextText = entry.contextPlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contextText, forType: .string)
    }
}

private struct Phase2AssistantCompletedResult: View {
    let display: Phase2AssistantDisplayResult
    let citationAction: (Phase2AssistantCitationDisplay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.answer)
                    .font(.body)
                    .textSelection(.enabled)
                Spacer(minLength: Lumen.Space.s6)
                Menu("Copy") {
                    Button("Result", action: copyResult)
                    Button("Citations", action: copyCitations)
                        .disabled(display.citationPlainTextExport == nil)
                    Button("Evidence", action: copyEvidence)
                        .disabled(display.evidencePlainTextExport == nil)
                    Button("Context", action: copyContext)
                        .disabled(display.contextPlainTextExport == nil)
                }
                .controlSize(.small)
                .help("Copy the Assistant result, citations, evidence, or context")
            }

            if let groundingWarning = display.groundingWarning {
                Label(groundingWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.lumen(.statusWarning))
                    .accessibilityIdentifier("assistant.result.unverified-addresses")
            }

            if !display.citations.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                    Text("Citations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(display.citations) { citation in
                        Phase2AssistantCitationRow(
                            citation: citation,
                            citationAction: citationAction
                        )
                    }
                }
            }

            if let activity = display.activity {
                Divider()
                Phase2AssistantActivityCard(activity: activity)
            }

            if let contextDisclosure = display.contextDisclosure {
                Divider()
                Phase2AssistantContextDisclosureView(
                    title: "Context sent",
                    disclosure: contextDisclosure
                )
            }

            if !display.evidenceSummaries.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    Text("Evidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(display.evidenceSummaries) { evidence in
                        Phase2AssistantEvidenceCard(
                            evidence: evidence,
                            citationAction: citationAction
                        )
                    }
                }
            }
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(display.plainTextExport, forType: .string)
    }

    private func copyCitations() {
        guard let citationText = display.citationPlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(citationText, forType: .string)
    }

    private func copyEvidence() {
        guard let evidenceText = display.evidencePlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(evidenceText, forType: .string)
    }

    private func copyContext() {
        guard let contextText = display.contextPlainTextExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contextText, forType: .string)
    }
}

private struct Phase2AssistantActivityCard: View {
    let activity: Phase2AssistantActivityDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Lumen.Space.s5)
                Text(activity.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                ForEach(activity.facts) { fact in
                    Phase2AssistantEvidenceFactRow(fact: fact)
                }
            }
        }
        .padding(Lumen.Space.s5)
        .background(Color.lumen(.bgCanvas), in: RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous)
                .stroke(Color.lumen(.borderDefault))
        }
    }
}

private struct Phase2AssistantEvidenceCard: View {
    let evidence: Phase2AssistantEvidenceDisplay
    let citationAction: (Phase2AssistantCitationDisplay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text(evidence.title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: Lumen.Space.s5)
                Text(evidence.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !evidence.facts.isEmpty {
                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    ForEach(evidence.facts) { fact in
                        Phase2AssistantEvidenceFactRow(fact: fact)
                    }
                }
            }

            if evidence.hiddenFactCount > 0 {
                DisclosureGroup("Show all facts (\(evidence.allFacts.count))") {
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        ForEach(evidence.allFacts) { fact in
                            Phase2AssistantEvidenceFactRow(fact: fact)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !evidence.identityFacts.isEmpty || !evidence.citations.isEmpty {
                DisclosureGroup("Accepted record") {
                    VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                        if !evidence.identityFacts.isEmpty {
                            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                                ForEach(evidence.identityFacts) { fact in
                                    Phase2AssistantEvidenceFactRow(fact: fact)
                                }
                            }
                        }

                        if !evidence.citations.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                                Text("Citation targets")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(evidence.citations) { citation in
                                    Phase2AssistantCitationRow(
                                        citation: citation,
                                        citationAction: citationAction
                                    )
                                }
                            }
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Lumen.Space.s5)
        .background(Color.lumen(.bgCanvas), in: RoundedRectangle(cornerRadius: Lumen.Radius.sm, style: .continuous))
    }
}

private struct Phase2AssistantEvidenceFactRow: View {
    let fact: Phase2AssistantEvidenceFactDisplay

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Text(fact.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 164, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(fact.value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct Phase2AssistantCitationRow: View {
    let citation: Phase2AssistantCitationDisplay
    let citationAction: (Phase2AssistantCitationDisplay) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                Text(citation.title)
                    .font(.caption.weight(.semibold))
                Text(citation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Lumen.Space.s5)
            if citation.isNavigable {
                Button("Go") {
                    citationAction(citation)
                }
                .controlSize(.small)
                .accessibilityLabel("Go to citation \(citation.title)")
                .accessibilityHint(citation.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Phase2AssistantEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Phase2AssistantFooter: View {
    let isRunning: Bool
    let isRunEnabled: Bool
    let runAction: () -> Void
    let cancelAction: () -> Void
    let closeAction: () -> Void

    var body: some View {
        HStack {
            Button("Close", action: closeAction)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if isRunning {
                Button("Cancel", action: cancelAction)
            }
            Button(isRunning ? "Running…" : "Run", action: runAction)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || !isRunEnabled)
        }
    }
}

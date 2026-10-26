import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantSameTurnShellPresentationTests: XCTestCase {
    private let workspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let sessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let conversationID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    private let turnID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
    private let requestID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!

    func testHumanReviewAndRunRemainSeparateExplicitActions() {
        let review = Phase2AssistantSameTurnShellPresentation(phase: .awaitingReview)
        XCTAssertTrue(review.showsApproveAction)
        XCTAssertTrue(review.showsRejectAction)
        XCTAssertTrue(review.showsDismissAction)
        XCTAssertFalse(review.showsCancelAction)
        XCTAssertFalse(review.showsRunAction)
        XCTAssertTrue(review.blocksComposer)
        XCTAssertFalse(review.showsProgress)
        XCTAssertFalse(review.showsManualShellResultContinuation)

        let approved = Phase2AssistantSameTurnShellPresentation(phase: .approvedAwaitingRun)
        XCTAssertFalse(approved.showsApproveAction)
        XCTAssertTrue(approved.showsRunAction)
        XCTAssertTrue(approved.showsCancelAction)
        XCTAssertFalse(approved.showsRejectAction)
        XCTAssertFalse(approved.showsDismissAction)
        XCTAssertTrue(approved.blocksComposer)
        XCTAssertFalse(approved.showsProgress)
        XCTAssertFalse(approved.showsManualShellResultContinuation)
    }

    func testAutomaticPostRunPhasesUseFrozenTranscriptLabelsAndBlockComposer() {
        let phases: [(Phase2AssistantSameTurnShellPresentationPhase, String)] = [
            (.runningApprovedCommand, "Running approved command"),
            (.preparingShellResult, "Preparing shell result"),
            (.continuingAssistant, "Continuing Assistant")
        ]

        for (phase, expectedTitle) in phases {
            let presentation = Phase2AssistantSameTurnShellPresentation(phase: phase)
            XCTAssertEqual(presentation.title, expectedTitle)
            XCTAssertTrue(presentation.showsProgress)
            XCTAssertTrue(presentation.blocksComposer)
            XCTAssertFalse(presentation.showsApproveAction)
            XCTAssertFalse(presentation.showsRunAction)
            XCTAssertFalse(presentation.showsCancelAction)
            XCTAssertFalse(presentation.isTerminal)
            XCTAssertEqual(presentation.retryPolicy, .unavailable)
            XCTAssertFalse(presentation.showsManualShellResultContinuation)
        }
    }

    func testTerminalHumanOutcomesStopProgressAndRequireNewTurnForAnotherAttempt() {
        for phase in [
            Phase2AssistantSameTurnShellPresentationPhase.rejected,
            .dismissed,
            .cancelled
        ] {
            let presentation = Phase2AssistantSameTurnShellPresentation(phase: phase)
            XCTAssertFalse(presentation.showsProgress)
            XCTAssertFalse(presentation.blocksComposer)
            XCTAssertTrue(presentation.isTerminal)
            XCTAssertFalse(presentation.showsRejectAction)
            XCTAssertFalse(presentation.showsDismissAction)
            XCTAssertFalse(presentation.showsCancelAction)
            XCTAssertEqual(presentation.retryPolicy, .startNewTurn)
            XCTAssertFalse(presentation.showsManualShellResultContinuation)
        }
    }

    func testSuccessfulContinuationHasDistinctTruthfulTerminalPresentationAndEvidence() throws {
        let evidence = completionEvidence()
        let presentation = Phase2AssistantSameTurnShellPresentation(
            phase: .completed(evidence: evidence)
        )

        XCTAssertEqual(presentation.title, "Shell-assisted turn completed")
        XCTAssertTrue(presentation.detail.contains("sealed shell result"))
        XCTAssertEqual(presentation.statusSystemImage, "checkmark.circle")
        XCTAssertEqual(presentation.completionEvidence, evidence)
        XCTAssertTrue(presentation.isTerminal)
        XCTAssertFalse(presentation.blocksComposer)
        XCTAssertFalse(presentation.showsProgress)
        XCTAssertEqual(presentation.retryPolicy, .unavailable)

        let display = Phase2AssistantDisplayResult(
            answer: "Bounded answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil,
            sameTurnShellEvidence: evidence
        )
        let export = try XCTUnwrap(display.evidencePlainTextExport)
        XCTAssertTrue(export.contains(evidence.proposalID.uuidString))
        XCTAssertTrue(export.contains(evidence.executionID.uuidString))
        XCTAssertTrue(export.contains(evidence.executionResultDigest))
        XCTAssertTrue(export.contains(evidence.continuationRequestID.uuidString))
        XCTAssertTrue(export.contains(evidence.documentID.uuidString))
        XCTAssertTrue(export.contains(evidence.sessionID.uuidString))
        XCTAssertTrue(export.contains(evidence.originatingRequestID.uuidString))
    }

    func testUnsealedRecoveryFailureRemainsNonterminalAndFailClosed() {
        let blocked = Phase2AssistantSameTurnShellPresentation(
            phase: .recoveryBlocked(detail: "Durable retirement is still required.")
        )

        XCTAssertFalse(blocked.isTerminal)
        XCTAssertTrue(blocked.blocksComposer)
        XCTAssertFalse(blocked.showsProgress)
        XCTAssertEqual(blocked.retryPolicy, .unavailable)
        XCTAssertEqual(blocked.statusSystemImage, "exclamationmark.triangle")
        XCTAssertTrue(blocked.accessibilityValue.contains("Durable retirement is still required."))

        let failed = Phase2AssistantSameTurnShellPresentation(
            phase: .failed(stage: .execution, detail: "Command failed.")
        )
        XCTAssertEqual(failed.statusSystemImage, "xmark.octagon")
        XCTAssertTrue(failed.accessibilityValue.contains("Command failed."))
    }

    func testCompletionIdentityRejectsMixedSessionOrTurnAndScopesVisiblePublication() throws {
        let context = Phase2AssistantConversationTurnContext(
            conversationID: conversationID,
            sessionID: sessionID,
            inferenceTurnID: turnID,
            turnSequence: 7,
            priorTurns: []
        )
        let identity = try XCTUnwrap(Phase2AssistantCompletionIdentity(
            workspaceID: workspaceID,
            documentID: documentID,
            requestSessionID: sessionID,
            requestTurnID: turnID,
            originatingRequestID: requestID,
            turnContext: context
        ))

        XCTAssertTrue(identity.authorizesPresentation(
            workspaceID: workspaceID,
            documentID: documentID,
            activeConversationID: conversationID,
            activeInferenceTurnID: turnID,
            activeTurnSequence: 7
        ))
        XCTAssertFalse(identity.authorizesPresentation(
            workspaceID: UUID(),
            documentID: documentID,
            activeConversationID: conversationID,
            activeInferenceTurnID: turnID,
            activeTurnSequence: 7
        ))
        XCTAssertFalse(identity.authorizesPresentation(
            workspaceID: workspaceID,
            documentID: documentID,
            activeConversationID: UUID(),
            activeInferenceTurnID: turnID,
            activeTurnSequence: 7
        ))
        XCTAssertFalse(identity.authorizesPresentation(
            workspaceID: workspaceID,
            documentID: documentID,
            activeConversationID: conversationID,
            activeInferenceTurnID: UUID(),
            activeTurnSequence: 8
        ))
        XCTAssertNil(Phase2AssistantCompletionIdentity(
            workspaceID: workspaceID,
            documentID: documentID,
            requestSessionID: UUID(),
            requestTurnID: turnID,
            originatingRequestID: requestID,
            turnContext: context
        ))
        XCTAssertNil(Phase2AssistantCompletionIdentity(
            workspaceID: workspaceID,
            documentID: documentID,
            requestSessionID: sessionID,
            requestTurnID: UUID(),
            originatingRequestID: requestID,
            turnContext: context
        ))
    }

    func testRetiredPublicationTokenRejectsRevisionAndDocumentChanges() throws {
        let identity = try XCTUnwrap(Phase2AssistantCompletionIdentity(
            workspaceID: workspaceID,
            documentID: documentID,
            requestSessionID: sessionID,
            requestTurnID: turnID,
            originatingRequestID: requestID,
            turnContext: .init(
                conversationID: conversationID,
                sessionID: sessionID,
                inferenceTurnID: turnID,
                turnSequence: 7,
                priorTurns: []
            )
        ))
        let revision = UUID()
        let token = Phase2AssistantContinuationPublicationToken(
            ownerRevision: revision,
            identity: identity
        )

        XCTAssertTrue(token.isCurrent(
            ownerRevision: revision,
            workspaceID: workspaceID,
            documentID: documentID
        ))
        XCTAssertFalse(token.isCurrent(
            ownerRevision: UUID(),
            workspaceID: workspaceID,
            documentID: documentID
        ))
        XCTAssertFalse(token.isCurrent(
            ownerRevision: revision,
            workspaceID: workspaceID,
            documentID: UUID()
        ))
    }

    func testEligibleStagingDispositionNeverFallsThroughToLegacyOrPublishesProvisionalFinal() {
        XCTAssertFalse(Phase2AssistantContinuationStagingDisposition.notEligible.ownsProviderProposals)
        XCTAssertNil(Phase2AssistantContinuationStagingDisposition.notEligible.immediateFinalState)
        XCTAssertTrue(Phase2AssistantContinuationStagingDisposition.staged.ownsProviderProposals)
        XCTAssertNil(Phase2AssistantContinuationStagingDisposition.staged.immediateFinalState)

        let failure = Phase2AssistantSheetState.failed(
            title: "Exact continuation rejected",
            detail: "Identity mismatch"
        )
        let rejected = Phase2AssistantContinuationStagingDisposition.rejected(failure)
        XCTAssertTrue(rejected.ownsProviderProposals)
        XCTAssertEqual(rejected.immediateFinalState, failure)
    }

    func testEveryFailureStageIsFiniteAndNeverOffersSameTurnRetry() {
        let stages: [Phase2AssistantSameTurnShellPresentationPhase.FailureStage] = [
            .execution,
            .authorityValidation,
            .continuation,
            .recovery
        ]

        for stage in stages {
            let presentation = Phase2AssistantSameTurnShellPresentation(
                phase: .failed(stage: stage, detail: "Bounded diagnostic")
            )
            XCTAssertEqual(presentation.detail, "Bounded diagnostic")
            XCTAssertFalse(presentation.showsProgress)
            XCTAssertFalse(presentation.blocksComposer)
            XCTAssertTrue(presentation.isTerminal)
            XCTAssertEqual(presentation.retryPolicy, .startNewTurn)
        }
    }

    func testCompletionTargetsFrozenConversationAfterSidebarSwitch() throws {
        let originConversationID = UUID()
        let originTurnID = UUID()
        let otherConversationID = UUID()
        let otherTurnID = UUID()
        let running = Phase2AssistantSheetState.running(.askMacScope)
        var presentation = Phase2AssistantConversationPresentation(
            conversations: [
                .init(conversationID: originConversationID, turns: [
                    .init(
                        inferenceTurnID: originTurnID, turnSequence: 7,
                        intent: .askMacScope, userMessage: "origin", state: running,
                        createdAt: Date(timeIntervalSince1970: 1)
                    ),
                ]),
                .init(conversationID: otherConversationID, turns: [
                    .init(
                        inferenceTurnID: otherTurnID, turnSequence: 1,
                        intent: .askMacScope, userMessage: "other", state: .idle,
                        createdAt: Date(timeIntervalSince1970: 2)
                    ),
                ]),
            ],
            activeConversationID: otherConversationID
        )
        let completed = Phase2AssistantSheetState.completed(.init(
            answer: "exact continuation", citations: [], evidenceSummaries: [],
            activity: nil, contextDisclosure: nil
        ))

        let becameActive = try presentation.applyCompletion(
            completed,
            identity: .init(
                workspaceID: workspaceID,
                documentID: documentID,
                sessionID: sessionID,
                conversationID: originConversationID,
                inferenceTurnID: originTurnID,
                turnSequence: 7,
                originatingRequestID: requestID
            )
        )

        XCTAssertFalse(becameActive)
        XCTAssertEqual(presentation.activeConversationID, otherConversationID)
        XCTAssertEqual(
            presentation.conversations.first { $0.id == originConversationID }?.turns.first?.state,
            completed
        )
        XCTAssertEqual(
            presentation.conversations.first { $0.id == otherConversationID }?.turns.first?.state,
            .idle
        )
    }

    func testOlderCompletionNeverReplacesVisibleStateForLaterTurnInSameConversation() throws {
        let originTurnID = UUID()
        let laterTurnID = UUID()
        let conversation = Phase2AssistantConversation(conversationID: conversationID, turns: [
            .init(
                inferenceTurnID: originTurnID, turnSequence: 7,
                intent: .askMacScope, userMessage: "origin", state: .idle,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            .init(
                inferenceTurnID: laterTurnID, turnSequence: 8,
                intent: .reviewFunction, userMessage: "later", state: .running(.reviewFunction),
                createdAt: Date(timeIntervalSince1970: 2)
            ),
        ])
        var presentation = Phase2AssistantConversationPresentation(
            conversations: [conversation],
            activeConversationID: conversationID
        )
        let completed = Phase2AssistantSheetState.completed(.init(
            answer: "older completion", citations: [], evidenceSummaries: [],
            activity: nil, contextDisclosure: nil
        ))

        let becameActive = try presentation.applyCompletion(
            completed,
            identity: .init(
                workspaceID: workspaceID,
                documentID: documentID,
                sessionID: sessionID,
                conversationID: conversationID,
                inferenceTurnID: originTurnID,
                turnSequence: 7,
                originatingRequestID: requestID
            )
        )

        XCTAssertFalse(becameActive)
        XCTAssertEqual(presentation.activeConversation?.turns.last?.inferenceTurnID, laterTurnID)
        XCTAssertEqual(
            presentation.activeConversation?.turns.first?.state,
            completed
        )
    }

    func testSecondStageIsRejectedUntilExistingContinuationIsTerminal() {
        XCTAssertTrue(Phase2AssistantLiveContinuationController.admitsNewContinuation(
            existingState: nil, runInFlight: false
        ))
        for state in Phase2AssistantShellContinuationState.allCases where !state.isTerminal {
            XCTAssertFalse(Phase2AssistantLiveContinuationController.admitsNewContinuation(
                existingState: state, runInFlight: false
            ), "Unexpected admission while \(state.rawValue) is nonterminal")
        }
        XCTAssertFalse(Phase2AssistantLiveContinuationController.admitsNewContinuation(
            existingState: .completed, runInFlight: true
        ))
        XCTAssertTrue(Phase2AssistantLiveContinuationController.admitsNewContinuation(
            existingState: .completed, runInFlight: false
        ))
        XCTAssertFalse(Phase2AssistantLiveContinuationController.admitsNewContinuation(
            existingState: .completed,
            runInFlight: false,
            requiresDurableRecovery: true
        ))
    }

    func testTerminalEventDigestIsDeterministicLowercaseSHA256AndContentBound() throws {
        let identity = Phase2AssistantShellTurnIdentity(
            workspaceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            workspaceDocumentIdentityDigest: String(repeating: "a", count: 64),
            conversationID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            inferenceTurnID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            turnSequence: 7,
            originatingFinalizationRequestID:
                UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        )
        let first = Phase2AssistantLiveContinuationController.terminalEventDigest(
            identity: identity,
            kind: "completed",
            content: "answer"
        )
        let retry = Phase2AssistantLiveContinuationController.terminalEventDigest(
            identity: identity,
            kind: "completed",
            content: "answer"
        )
        let changed = Phase2AssistantLiveContinuationController.terminalEventDigest(
            identity: identity,
            kind: "completed",
            content: "different answer"
        )

        XCTAssertEqual(first, retry)
        XCTAssertNotEqual(first, changed)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        })
    }

    private func completionEvidence() -> Phase2AssistantSameTurnShellCompletionEvidence {
        Phase2AssistantSameTurnShellCompletionEvidence(
            workspaceID: workspaceID,
            documentID: documentID,
            sessionID: sessionID,
            conversationID: conversationID,
            inferenceTurnID: turnID,
            turnSequence: 7,
            originatingRequestID: requestID,
            proposalID: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            executionID: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
            executionResultDigest: String(repeating: "a", count: 64),
            continuationRequestID: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
            providerRevision: 12
        )
    }
}

import XCTest
@testable import MacScope

final class Phase2AssistantConversationPresentationTests: XCTestCase {
    func testNewConversationBecomesActiveAndResumeUsesMostRecentActivityGrouping() throws {
        let olderID = uuid(1)
        let newerID = uuid(2)
        var presentation = Phase2AssistantConversationPresentation()

        presentation.newConversation(
            id: olderID,
            title: "Older",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        presentation.newConversation(
            id: newerID,
            title: "Newer",
            createdAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(presentation.activeConversationID, newerID)
        XCTAssertEqual(presentation.resumableConversations.map(\.id), [newerID, olderID])

        try presentation.resumeConversation(id: olderID)
        XCTAssertEqual(presentation.activeConversationID, olderID)
        XCTAssertEqual(presentation.activeConversation?.title, "Older")
    }

    func testConversationAllowsOnlyOneInFlightTurn() throws {
        var conversation = Phase2AssistantConversation(conversationID: uuid(10))
        try conversation.appendTurn(
            turn(id: uuid(11), ordinal: 1, state: .running(.askMacScope))
        )

        XCTAssertTrue(conversation.hasInFlightTurn)
        XCTAssertFalse(conversation.canSubmitTurn)
        XCTAssertThrowsError(
            try conversation.appendTurn(
                turn(id: uuid(12), ordinal: 2, state: .running(.reviewFunction))
            )
        ) { error in
            XCTAssertEqual(error as? Phase2AssistantConversationMutationError, .turnAlreadyInFlight)
        }

        try conversation.updateTurnState(
            inferenceTurnID: uuid(11),
            state: .completed(result(answer: "Finished"))
        )
        try conversation.appendTurn(
            turn(id: uuid(12), ordinal: 2, state: .running(.reviewFunction))
        )
        XCTAssertEqual(conversation.turns.map(\.turnSequence), [1, 2])
    }

    func testProviderHistoryIncludesOnlyCompletedNonEmptyExchanges() throws {
        var conversation = Phase2AssistantConversation(conversationID: uuid(20))
        try conversation.appendTurn(
            turn(id: uuid(21), ordinal: 1, user: "first", state: .completed(result(answer: "one")))
        )
        try conversation.appendTurn(
            turn(id: uuid(22), ordinal: 2, user: "failed", state: .failed(title: "No", detail: "evidence"))
        )
        try conversation.appendTurn(
            turn(id: uuid(23), ordinal: 3, user: "running", state: .running(.askMacScope))
        )
        try conversation.appendTurn(
            turn(id: uuid(24), ordinal: 4, user: "empty answer", state: .completed(result(answer: "  ")))
        )

        let selected = conversation.providerVisiblePriorTurns()
        XCTAssertEqual(selected.map(\.turnSequence), [1])
        XCTAssertEqual(selected.first?.userMessage, "first")
        XCTAssertEqual(selected.first?.assistantMessage, "one")
    }

    func testProviderHistoryKeepsNewestEightWholePairsInChronologicalOrder() throws {
        var conversation = Phase2AssistantConversation(conversationID: uuid(30))
        for ordinal in 1...10 {
            try conversation.appendTurn(
                turn(
                    id: uuid(30 + ordinal),
                    ordinal: ordinal,
                    user: "user-\(ordinal)",
                    state: .completed(result(answer: "assistant-\(ordinal)"))
                )
            )
        }

        let selected = conversation.providerVisiblePriorTurns()
        XCTAssertEqual(selected.map(\.turnSequence), Array(3...10))
    }

    func testProviderHistoryByteLimitNeverSplitsOrSkipsNewestPair() throws {
        var conversation = Phase2AssistantConversation(conversationID: uuid(50))
        try conversation.appendTurn(
            turn(id: uuid(51), ordinal: 1, user: "1234", state: .completed(result(answer: "5678")))
        )
        try conversation.appendTurn(
            turn(id: uuid(52), ordinal: 2, user: "abc", state: .completed(result(answer: "def")))
        )

        XCTAssertEqual(
            conversation.providerVisiblePriorTurns(maximumUTF8Bytes: 7).map(\.turnSequence),
            [2]
        )
        XCTAssertTrue(
            conversation.providerVisiblePriorTurns(maximumUTF8Bytes: 5).isEmpty,
            "An oversized newest pair must produce an empty suffix instead of skipping to older context."
        )
    }

    func testTranscriptProjectionKeepsOnlyNewestWholeTurnsWithinRenderLimit() throws {
        var conversation = Phase2AssistantConversation(conversationID: uuid(80))
        for ordinal in 1...70 {
            try conversation.appendTurn(
                turn(
                    id: uuid(80 + ordinal),
                    ordinal: ordinal,
                    user: "user-\(ordinal)",
                    state: .completed(result(answer: "assistant-\(ordinal)"))
                )
            )
        }

        let projection = conversation.transcriptProjection(maximumTurnCount: 3)
        XCTAssertEqual(projection.turns.map(\.turnSequence), [68, 69, 70])
        XCTAssertEqual(projection.omittedTurnCount, 67)
        XCTAssertEqual(conversation.turns.count, 70, "Render bounding must not discard transcript authority.")
    }

    func testActiveStateAndSubmissionAuthorityFollowPersistedInFlightTurn() throws {
        let conversationID = uuid(160)
        var conversation = Phase2AssistantConversation(conversationID: conversationID)
        try conversation.appendTurn(
            turn(id: uuid(161), ordinal: 9, state: .running(.reviewFunction))
        )
        let presentation = Phase2AssistantConversationPresentation(
            conversations: [conversation],
            activeConversationID: conversationID
        )

        XCTAssertEqual(presentation.activeState, .running(.reviewFunction))
        XCTAssertFalse(presentation.canSubmitActiveTurn)
    }

    func testPersistedNonterminalContinuationReopensAsRunningNotFailed() {
        for state in Phase2AssistantShellContinuationState.allCases where !state.isTerminal {
            XCTAssertEqual(
                Phase2AssistantSheetState.nonterminalContinuationState(
                    intent: .askMacScope,
                    logicalState: state.rawValue
                ),
                .running(.askMacScope)
            )
        }
        XCTAssertNil(Phase2AssistantSheetState.nonterminalContinuationState(
            intent: .askMacScope,
            logicalState: Phase2AssistantShellContinuationState.completed.rawValue
        ))
        XCTAssertNil(Phase2AssistantSheetState.nonterminalContinuationState(
            intent: .askMacScope,
            logicalState: "foreign"
        ))
    }

    func testDeletionDoesNotRenumberTurnsAndExportPreservesOrdinals() throws {
        var conversation = Phase2AssistantConversation(conversationID: uuid(60), title: "Stable IDs")
        try conversation.appendTurn(
            turn(id: uuid(61), ordinal: 4, user: "four", state: .completed(result(answer: "answer four")))
        )
        try conversation.appendTurn(
            turn(id: uuid(62), ordinal: 9, user: "nine", state: .cancelled(title: "Stopped", detail: "User"))
        )
        try conversation.appendTurn(
            turn(id: uuid(63), ordinal: 12, user: "twelve", state: .completed(result(answer: "answer twelve")))
        )

        XCTAssertTrue(conversation.deleteTurn(inferenceTurnID: uuid(62)))
        XCTAssertEqual(conversation.turns.map(\.turnSequence), [4, 12])
        XCTAssertEqual(conversation.nextTurnOrdinal, 13)

        let export = try XCTUnwrap(Phase2AssistantConversationExportSnapshot(conversation: conversation))
        XCTAssertEqual(export.turnCount, 2)
        XCTAssertTrue(export.text.contains("Turn 4"))
        XCTAssertTrue(export.text.contains("Turn 12"))
        XCTAssertFalse(export.text.contains("Turn 9"))
    }

    func testLegacyRunsRemainASeparateArchiveAndConversationDeletionSelectsAnotherConversation() {
        let legacy = Phase2AssistantHistoryEntry(
            id: uuid(70),
            sequence: 42,
            intent: .askMacScope,
            userGoal: "legacy",
            state: .completed(result(answer: "archived")),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let firstID = uuid(71)
        let secondID = uuid(72)
        var presentation = Phase2AssistantConversationPresentation(legacyRuns: [legacy])
        presentation.newConversation(id: firstID, createdAt: Date(timeIntervalSince1970: 2))
        presentation.newConversation(id: secondID, createdAt: Date(timeIntervalSince1970: 3))

        XCTAssertTrue(presentation.deleteConversation(id: secondID))
        XCTAssertEqual(presentation.activeConversationID, firstID)
        XCTAssertEqual(presentation.legacyRuns.map(\.sequence), [42])
        XCTAssertEqual(presentation.conversations.map(\.id), [firstID])
    }

    private func turn(
        id: UUID,
        ordinal: Int,
        user: String = "question",
        state: Phase2AssistantSheetState
    ) -> Phase2AssistantConversationTurn {
        Phase2AssistantConversationTurn(
            inferenceTurnID: id,
            turnSequence: ordinal,
            intent: .askMacScope,
            userMessage: user,
            state: state,
            createdAt: Date(timeIntervalSince1970: TimeInterval(ordinal))
        )
    }

    private func result(answer: String) -> Phase2AssistantDisplayResult {
        Phase2AssistantDisplayResult(
            answer: answer,
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

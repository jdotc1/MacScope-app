import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantContinuationDatabaseOwnerTests: XCTestCase {
    func testPendingCheckpointSurvivesOwnerRecreationAndProjectsToStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(name: "Continuation owner")
        let identity = continuationIdentity(for: store, turnSequence: 1)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(),
            executablePath: "/usr/bin/true",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024
        )
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
        _ = machine.apply(.beginToolSelection(identity))
        _ = machine.apply(.beginFinalization(identity))
        _ = machine.apply(.stageProposal(.init(
            turnIdentity: identity,
            proposalID: proposal.proposalID,
            proposalDigest: Phase2AssistantShellProposalCanonicalizer.digest(proposal),
            executionSurface: .restrictedOneShotJob,
            isLegacy: false
        )))

        var owner: Phase2AssistantContinuationDatabaseOwner? = try store
            .makePhase2AssistantContinuationDatabaseOwner(baseDirectoryURL: directory)
        let recordID = try store.seedPhase2AssistantShellContinuation(
            machine: machine,
            proposal: proposal,
            intent: .askMacScope,
            userGoal: "Run the approved command.",
            initialTerminalEventDigest: String(repeating: "b", count: 64),
            in: try XCTUnwrap(owner),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        owner = nil // Simulates process-owned DB connection loss without graceful cleanup.

        let reopened = try store.makePhase2AssistantContinuationDatabaseOwner(
            baseDirectoryURL: directory
        )
        let restored = try XCTUnwrap(reopened.assistantRecord(id: recordID))
        XCTAssertEqual(restored.id, identity.inferenceTurnID)
        XCTAssertEqual(restored.workspaceUUID, store.workspaceID)
        XCTAssertEqual(restored.documentID, store.documentID)
        XCTAssertEqual(restored.continuationCheckpoint?.logicalState, "awaitingShellReview")
        XCTAssertEqual(restored.continuationCheckpoint?.shellProposalID, proposal.proposalID)
        XCTAssertEqual(
            try store.projectPhase2AssistantShellContinuation(recordID: recordID, from: reopened),
            restored
        )
        try reopened.retire()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.databaseURL.path))
    }

    func testFinalAnswerPublicationReplacesPendingTurnAndPreservesCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        let identity = continuationIdentity(for: store, turnSequence: 1)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(), executablePath: "/usr/bin/true",
            timeoutMilliseconds: 1_000, maximumOutputBytes: 1_024
        )
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
        _ = machine.apply(.beginToolSelection(identity))
        _ = machine.apply(.beginFinalization(identity))
        _ = machine.apply(.stageProposal(.init(
            turnIdentity: identity, proposalID: proposal.proposalID,
            proposalDigest: Phase2AssistantShellProposalCanonicalizer.digest(proposal),
            executionSurface: .restrictedOneShotJob, isLegacy: false
        )))
        let owner = try store.makePhase2AssistantContinuationDatabaseOwner(
            baseDirectoryURL: directory
        )
        let recordID = try store.seedPhase2AssistantShellContinuation(
            machine: machine, proposal: proposal, intent: .askMacScope,
            userGoal: "Run", initialTerminalEventDigest: String(repeating: "b", count: 64),
            in: owner
        )
        let finalState = Phase2AssistantSheetState.completed(.init(
            answer: "Continuation answer", citations: [], evidenceSummaries: [],
            activity: nil, contextDisclosure: nil
        ))

        _ = store.recordPhase2AssistantTerminalState(
            finalState, intent: .askMacScope, userGoal: "Run",
            conversationID: identity.conversationID,
            turnSequence: Int(identity.turnSequence),
            inferenceTurnID: identity.inferenceTurnID,
            id: recordID
        )

        let matching = store.phase2AssistantSessionHistory.filter { $0.id == recordID }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.answerText, "Continuation answer")
        XCTAssertEqual(
            matching.first?.continuationCheckpoint?.logicalState,
            Phase2AssistantShellContinuationState.awaitingShellReview.rawValue
        )
        try owner.retire()
    }

    func testOwnerRejectsCrossWorkspaceProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeStore(name: "First")
        let second = makeStore(name: "Second")
        let owner = try first.makePhase2AssistantContinuationDatabaseOwner(
            baseDirectoryURL: directory
        )

        XCTAssertThrowsError(
            try second.projectPhase2AssistantShellContinuation(recordID: UUID(), from: owner)
        ) { error in
            XCTAssertEqual(
                error as? Phase2AssistantContinuationDatabaseOwner.OwnerError,
                .identityMismatch
            )
        }
        try owner.retire()
    }

    func testOwnerRejectsWorkspaceRowRebindingAndUnknownCheckpointRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(name: "Owner binding")
        let owner = try store.makePhase2AssistantContinuationDatabaseOwner(
            baseDirectoryURL: directory
        )
        let rowID = try XCTUnwrap(owner.workspaceRowID)

        XCTAssertNoThrow(try owner.bindWorkspaceRowID(
            rowID,
            workspaceUUID: store.workspaceID,
            documentID: store.documentID
        ))
        XCTAssertThrowsError(try owner.bindWorkspaceRowID(
            rowID + 1,
            workspaceUUID: store.workspaceID,
            documentID: store.documentID
        )) { error in
            XCTAssertEqual(
                error as? Phase2AssistantContinuationDatabaseOwner.OwnerError,
                .identityMismatch
            )
        }
        XCTAssertThrowsError(try owner.checkpointAdapter(recordID: UUID())) { error in
            XCTAssertEqual(
                error as? Phase2AssistantContinuationDatabaseOwner.OwnerError,
                .identityMismatch
            )
        }
        try owner.retire()
    }

    func testDurableReopenRecoversEveryNonterminalCheckpointByFailingClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(name: "Recovery")
        let owner = try store.makePhase2AssistantContinuationDatabaseOwner(
            baseDirectoryURL: directory
        )
        let states: [Phase2AssistantShellContinuationState] = [
            .awaitingShellReview, .executingShell, .awaitingShellContinuation, .continuingShell,
        ]
        var recordIDs: [UUID] = []
        for (index, state) in states.enumerated() {
            let identity = continuationIdentity(
                for: store,
                turnSequence: UInt64(index + 1)
            )
            let proposal = Phase2AIShellCommandProposal(
                proposalID: UUID(), executablePath: "/usr/bin/true",
                timeoutMilliseconds: 1_000, maximumOutputBytes: 1_024
            )
            var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
            _ = machine.apply(.beginToolSelection(identity))
            _ = machine.apply(.beginFinalization(identity))
            _ = machine.apply(.stageProposal(.init(
                turnIdentity: identity, proposalID: proposal.proposalID,
                proposalDigest: Phase2AssistantShellProposalCanonicalizer.digest(proposal),
                executionSurface: .restrictedOneShotJob, isLegacy: false
            )))
            let recordID = try store.seedPhase2AssistantShellContinuation(
                machine: machine, proposal: proposal, intent: .askMacScope,
                userGoal: "Recover \(state.rawValue)",
                initialTerminalEventDigest: String(repeating: "b", count: 64), in: owner
            )
            var record = try XCTUnwrap(owner.assistantRecord(id: recordID))
            record.continuationCheckpoint?.logicalState = state.rawValue
            record.contentSHA256 = record.calculatedContentSHA256()
            try owner.database.upsertPhase2AssistantSessionRecord(record)
            recordIDs.append(recordID)
        }

        let recoveredAt = Date(timeIntervalSince1970: 500)
        let projections = try store.recoverPhase2AssistantShellContinuations(
            from: owner, now: recoveredAt
        )

        XCTAssertEqual(Set(projections.map(\.priorLogicalState)), Set(states.map(\.rawValue)))
        XCTAssertEqual(projections.count, states.count)
        for id in recordIDs {
            let record = try XCTUnwrap(owner.assistantRecord(id: id))
            XCTAssertEqual(record.status, .failed)
            XCTAssertEqual(record.completedAt, recoveredAt)
            XCTAssertEqual(record.continuationCheckpoint?.logicalState, "failed")
            XCTAssertEqual(record.continuationCheckpoint?.continuationDispatchState, "recovery_failed_closed")
            XCTAssertTrue(record.continuationCheckpoint?.finalProvenanceJSON?.contains(
                "failed_closed_without_provider_or_shell_dispatch"
            ) == true)
            XCTAssertNotNil(store.phase2AssistantSessionHistory.first { $0.id == id })
        }
        XCTAssertTrue(try store.recoverPhase2AssistantShellContinuations(from: owner).isEmpty)
    }

    func testLiveControllerInitializationConsumesDurableRecoveryProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(name: "Controller recovery")
        let identity = continuationIdentity(for: store, turnSequence: 1)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(), executablePath: "/usr/bin/true",
            timeoutMilliseconds: 1_000, maximumOutputBytes: 1_024
        )
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
        _ = machine.apply(.beginToolSelection(identity))
        _ = machine.apply(.beginFinalization(identity))
        _ = machine.apply(.stageProposal(.init(
            turnIdentity: identity, proposalID: proposal.proposalID,
            proposalDigest: Phase2AssistantShellProposalCanonicalizer.digest(proposal),
            executionSurface: .restrictedOneShotJob, isLegacy: false
        )))
        var owner: Phase2AssistantContinuationDatabaseOwner? = try store
            .makePhase2AssistantContinuationDatabaseOwner(baseDirectoryURL: directory)
        let recordID = try store.seedPhase2AssistantShellContinuation(
            machine: machine, proposal: proposal, intent: .askMacScope, userGoal: "Recover",
            initialTerminalEventDigest: String(repeating: "b", count: 64), in: try XCTUnwrap(owner)
        )
        owner = nil

        let controller = Phase2AssistantLiveContinuationController(
            store: store, coordinator: nil,
            continuationDatabaseBaseDirectoryURL: directory
        )
        controller.refreshDatabaseOwnerForCurrentStoreIdentity()

        XCTAssertEqual(controller.recoveryProjections.map(\.record.id), [recordID])
        XCTAssertNotNil(controller.presentation)
        XCTAssertEqual(
            store.phase2AssistantSessionHistory.first { $0.id == recordID }?.status,
            .failed
        )
    }

    func testLiveControllerRotatesDatabaseOwnerAfterWorkspaceIdentityFork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(name: "Controller owner rotation")
        let controller = Phase2AssistantLiveContinuationController(
            store: store,
            coordinator: nil,
            continuationDatabaseBaseDirectoryURL: directory
        )

        XCTAssertNil(controller.currentDatabaseOwnerIdentity)
        controller.refreshDatabaseOwnerForCurrentStoreIdentity()
        let original = try XCTUnwrap(controller.currentDatabaseOwnerIdentity)
        XCTAssertEqual(original.workspaceID, store.workspaceID)
        XCTAssertEqual(original.documentID, store.documentID)

        let fork = store.forkWorkspaceIdentity()
        controller.refreshDatabaseOwnerForCurrentStoreIdentity()
        let rotated = try XCTUnwrap(controller.currentDatabaseOwnerIdentity)
        XCTAssertEqual(rotated.workspaceID, fork.workspaceID)
        XCTAssertEqual(rotated.documentID, fork.documentID)
        XCTAssertNotEqual(rotated.workspaceID, original.workspaceID)
        XCTAssertNotEqual(rotated.documentID, original.documentID)
    }

    private func makeStore(name: String = "Continuation") -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: name,
            snapshot: .init(
                binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    private func continuationIdentity(
        for store: WorkspaceStore,
        turnSequence: UInt64
    ) -> Phase2AssistantShellTurnIdentity {
        Phase2AssistantShellTurnIdentity(
            workspaceID: store.workspaceID,
            workspaceDocumentIdentityDigest: Phase2AssistantWorkspaceDocumentIdentity.digest(
                documentID: store.documentID,
                workspaceID: store.workspaceID
            ),
            conversationID: UUID(),
            inferenceTurnID: UUID(),
            turnSequence: turnSequence,
            originatingFinalizationRequestID: UUID()
        )
    }
}

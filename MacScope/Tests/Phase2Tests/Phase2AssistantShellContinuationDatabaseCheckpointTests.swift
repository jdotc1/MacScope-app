import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantShellContinuationDatabaseCheckpointTests: XCTestCase {
    func testTerminalSuccessIsSealedBeforeProjectionAndIsIdempotent() async throws {
        let fixture = try Fixture()
        let (db, recordID) = try continuationDatabase(fixture: fixture, state: .continuingShell)
        let completedAt = Date(timeIntervalSince1970: 50)
        let terminalDigest = Phase2AssistantShellTerminalEventCanonicalizer.digest(
            turnIdentity: fixture.identity,
            kind: "completed",
            content: "The command succeeded."
        )
        let adapter = Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: db, assistantSessionRecordID: recordID
        )
        let seal = Phase2AssistantShellContinuationTerminalSeal(
            expectedLogicalState: .continuingShell,
            disposition: .completed(answer: "The command succeeded."),
            terminalEventDigest: terminalDigest,
            completedAt: completedAt
        )

        let first = try await adapter.sealTerminal(seal)
        let second = try await adapter.sealTerminal(seal)

        XCTAssertEqual(second, first)
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(first.answerText, "The command succeeded.")
        XCTAssertEqual(first.completedAt, completedAt)
        XCTAssertEqual(first.continuationCheckpoint?.logicalState, "completed")
        XCTAssertEqual(first.continuationCheckpoint?.continuationDispatchState, "terminal_received")
        XCTAssertEqual(
            first.continuationCheckpoint?.continuationTerminalEventDigest,
            terminalDigest
        )
        let provenance = try XCTUnwrap(first.continuationCheckpoint?.finalProvenanceJSON)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(provenance.utf8)) as? [String: AnyHashable]
        )
        XCTAssertEqual(decoded["conversation_id"], fixture.identity.conversationID.uuidString.lowercased())
        XCTAssertEqual(decoded["disposition"], "completed")
        XCTAssertEqual(decoded["inference_turn_id"], fixture.identity.inferenceTurnID.uuidString.lowercased())
        XCTAssertEqual(decoded["terminal_event_digest"], terminalDigest)
        XCTAssertEqual(decoded["turn_sequence"], 1)
        let recanonicalized = try JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys])
        XCTAssertEqual(provenance, String(decoding: recanonicalized, as: UTF8.self))
        XCTAssertEqual(try db.phase2AssistantSessionRecord(id: recordID), first)
    }

    func testTerminalFailureSealsExplicitDispositionWithoutErasingAuditFields() async throws {
        let fixture = try Fixture()
        let (db, recordID) = try continuationDatabase(fixture: fixture, state: .executingShell)
        let before = try XCTUnwrap(db.phase2AssistantSessionRecord(id: recordID))
        let adapter = Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: db, assistantSessionRecordID: recordID
        )
        let diagnostic = "shell execution failed"

        let sealed = try await adapter.sealTerminal(.init(
            expectedLogicalState: .executingShell,
            disposition: .failed(diagnostic: diagnostic),
            terminalEventDigest: Phase2AssistantShellTerminalEventCanonicalizer.digest(
                turnIdentity: fixture.identity,
                kind: "failed",
                content: diagnostic
            ),
            completedAt: Date(timeIntervalSince1970: 51)
        ))

        XCTAssertEqual(sealed.status, .failed)
        XCTAssertNil(sealed.answerText)
        XCTAssertEqual(sealed.continuationCheckpoint?.logicalState, "failed")
        XCTAssertEqual(sealed.transcriptText, before.transcriptText)
        XCTAssertEqual(sealed.promptText, before.promptText)
        XCTAssertEqual(sealed.createdAt, before.createdAt)
        XCTAssertTrue(sealed.continuationCheckpoint?.finalProvenanceJSON?.contains(
            "\"diagnostic\":\"shell execution failed\""
        ) == true)
    }

    func testTerminalSealRejectsStaleOrConflictingWinner() async throws {
        let fixture = try Fixture()
        let (db, recordID) = try continuationDatabase(fixture: fixture, state: .continuingShell)
        let adapter = Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: db, assistantSessionRecordID: recordID
        )
        let first = Phase2AssistantShellContinuationTerminalSeal(
            expectedLogicalState: .continuingShell,
            disposition: .cancelled,
            terminalEventDigest: Phase2AssistantShellTerminalEventCanonicalizer.digest(
                turnIdentity: fixture.identity,
                kind: "cancelled",
                content: ""
            ),
            completedAt: Date(timeIntervalSince1970: 52)
        )
        _ = try await adapter.sealTerminal(first)

        do {
            _ = try await adapter.sealTerminal(.init(
                expectedLogicalState: .continuingShell,
                disposition: .rejected(diagnostic: "late rejection"),
                terminalEventDigest: Phase2AssistantShellTerminalEventCanonicalizer.digest(
                    turnIdentity: fixture.identity,
                    kind: "rejected",
                    content: "late rejection"
                ),
                completedAt: Date(timeIntervalSince1970: 53)
            ))
            XCTFail("Expected conflicting terminal seal to fail closed")
        } catch {
            XCTAssertEqual(
                error as? Phase2AssistantShellContinuationDatabaseCheckpoint.PersistenceError,
                .staleTransition
            )
        }
    }

    func testTerminalSealRejectsDigestFromForeignTurnBeforeMutation() async throws {
        let fixture = try Fixture()
        let (db, recordID) = try continuationDatabase(fixture: fixture, state: .continuingShell)
        let adapter = Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: db,
            assistantSessionRecordID: recordID
        )
        let answer = "Bound answer"
        let foreign = Phase2AssistantShellTurnIdentity(
            workspaceID: fixture.identity.workspaceID,
            workspaceDocumentIdentityDigest: fixture.identity.workspaceDocumentIdentityDigest,
            conversationID: UUID(),
            inferenceTurnID: fixture.identity.inferenceTurnID,
            turnSequence: fixture.identity.turnSequence,
            originatingFinalizationRequestID: fixture.identity.originatingFinalizationRequestID
        )

        do {
            _ = try await adapter.sealTerminal(.init(
                expectedLogicalState: .continuingShell,
                disposition: .completed(answer: answer),
                terminalEventDigest: Phase2AssistantShellTerminalEventCanonicalizer.digest(
                    turnIdentity: foreign,
                    kind: "completed",
                    content: answer
                ),
                completedAt: Date(timeIntervalSince1970: 53)
            ))
            XCTFail("Expected foreign terminal digest rejection")
        } catch {
            XCTAssertEqual(
                error as? Phase2AssistantShellContinuationDatabaseCheckpoint.PersistenceError,
                .invalidTerminalSeal
            )
        }
        XCTAssertEqual(
            try db.phase2AssistantSessionRecord(id: recordID)?.status,
            .outcomeUnknown
        )
    }

    func testTerminalSealRejectsOversizedDiagnostic() async throws {
        let fixture = try Fixture()
        let (db, recordID) = try continuationDatabase(fixture: fixture, state: .continuingShell)
        let adapter = Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: db,
            assistantSessionRecordID: recordID
        )
        let diagnostic = String(repeating: "x", count: 4_097)

        do {
            _ = try await adapter.sealTerminal(.init(
                expectedLogicalState: .continuingShell,
                disposition: .failed(diagnostic: diagnostic),
                terminalEventDigest: Phase2AssistantShellTerminalEventCanonicalizer.digest(
                    turnIdentity: fixture.identity,
                    kind: "failed",
                    content: diagnostic
                ),
                completedAt: Date(timeIntervalSince1970: 53)
            ))
            XCTFail("Expected oversized terminal diagnostic rejection")
        } catch {
            XCTAssertEqual(
                error as? Phase2AssistantShellContinuationDatabaseCheckpoint.PersistenceError,
                .invalidTerminalSeal
            )
        }
    }

    func testExecutingCheckpointUsesDurableCompareAndTransition() async throws {
        let fixture = try Fixture()
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceUUID: fixture.identity.workspaceID,
            workspaceName: "Continuation adapter",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 10)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let recordID = fixture.identity.inferenceTurnID
        let checkpoint = Phase2AssistantContinuationCheckpointRecord(
            logicalState: Phase2AssistantShellContinuationState.awaitingShellReview.rawValue,
            initialRequestID: fixture.identity.originatingFinalizationRequestID,
            initialTerminalEventDigest: String(repeating: "f", count: 64),
            shellProposalID: fixture.proposalID,
            shellProposalJSON: "{\"command\":\"true\"}",
            shellProposalSHA256: fixture.proposalDigest,
            humanDecision: nil,
            approvalConsumedAt: nil,
            approvalState: nil,
            shellExecutionID: nil,
            completedExecutionReference: nil,
            shellExecutionSHA256: nil,
            runtimeAuthorityRecordID: nil,
            runtimeAuthoritySHA256: nil,
            continuationCoordinate: nil,
            continuationOrdinal: nil,
            continuationRequestID: nil,
            continuationDispatchState: nil,
            continuationTerminalEventDigest: nil,
            finalProvenanceJSON: nil
        )
        try db.upsertPhase2AssistantSessionRecord(.init(
            id: recordID,
            workspaceID: workspaceID,
            workspaceUUID: fixture.identity.workspaceID,
            documentID: fixture.documentID,
            sequence: 1,
            conversationID: fixture.identity.conversationID,
            turnSequence: Int(fixture.identity.turnSequence),
            inferenceTurnID: fixture.identity.inferenceTurnID,
            intentID: "assistant.ask_macscope",
            userGoal: "Run true",
            status: .outcomeUnknown,
            promptText: "prompt",
            answerText: nil,
            transcriptText: "pending",
            contextDigest: fixture.identity.workspaceDocumentIdentityDigest,
            canonicalByteCount: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            continuationCheckpoint: checkpoint
        ))
        var machine = fixture.machine
        XCTAssertNoThrow(try machine.apply(.approveAndReserveExecution(fixture.approval)).get())
        let adapter = Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: db,
            assistantSessionRecordID: recordID,
            now: { Date(timeIntervalSince1970: 11) }
        )

        try await adapter.persistAssistantShellContinuation(machine)
        let stored = try XCTUnwrap(db.phase2AssistantSessionRecord(id: recordID)?.continuationCheckpoint)
        XCTAssertEqual(stored.logicalState, Phase2AssistantShellContinuationState.executingShell.rawValue)
        XCTAssertEqual(stored.shellExecutionID, fixture.executionID)
        XCTAssertEqual(stored.approvalState, "consumed")
        do {
            try await adapter.persistAssistantShellContinuation(machine)
            XCTFail("Expected stale predecessor rejection")
        } catch {
            XCTAssertEqual(
                error as? Phase2AssistantShellContinuationDatabaseCheckpoint.PersistenceError,
                .invalidState
            )
        }
    }

    func testCoordinateMappingIsExactAndIntegrityChecked() throws {
        let fixture = try Fixture()
        let mapped = try XCTUnwrap(
            Phase2AssistantShellContinuationDatabaseCheckpoint.persistenceCoordinate(from: fixture.coordinate)
        )
        XCTAssertEqual(mapped.workspaceID, fixture.coordinate.workspaceID)
        XCTAssertEqual(mapped.workspaceDocumentIdentityDigest, fixture.coordinate.workspaceDocumentIdentityDigest)
        XCTAssertEqual(mapped.conversationID, fixture.coordinate.conversationID)
        XCTAssertEqual(mapped.inferenceTurnID, fixture.coordinate.inferenceTurnID)
        XCTAssertEqual(mapped.turnSequence, Int(fixture.coordinate.turnSequence))
        XCTAssertEqual(mapped.originatingFinalizationRequestID, fixture.coordinate.originatingFinalizationRequestID)
        XCTAssertEqual(mapped.shellProposalID, fixture.coordinate.shellProposalID)
        XCTAssertEqual(mapped.shellExecutionID, fixture.coordinate.shellExecutionID)
        XCTAssertEqual(mapped.runtimeAuthorityRecordID, fixture.coordinate.runtimeAuthorityRecordID)
        XCTAssertEqual(mapped.shellProposalDigest, fixture.coordinate.shellProposalDigest)
        XCTAssertEqual(mapped.shellExecutionResultDigest, fixture.coordinate.shellExecutionResultDigest)
        XCTAssertEqual(mapped.runtimeAuthorityRecordDigest, fixture.coordinate.runtimeAuthorityRecordDigest)
        XCTAssertEqual(mapped.productionManifestIdentity, fixture.coordinate.productionManifestIdentity)
        XCTAssertEqual(mapped.providerRevision, String(fixture.coordinate.providerRevision))
        XCTAssertEqual(mapped.continuationOrdinal, Int(fixture.coordinate.continuationOrdinal))
        XCTAssertEqual(mapped.continuationRequestID, fixture.coordinate.continuationRequestID)
        XCTAssertEqual(mapped.integrityDigest, fixture.coordinate.integrityDigest)
        XCTAssertTrue(mapped.isStructurallyValid)

        var tampered = mapped
        tampered.providerRevision = "8"
        XCTAssertFalse(tampered.isStructurallyValid)
    }

    func testDirectPackageReopenAndRewritePreserveCheckpoint() throws {
        let fixture = try Fixture()
        let documentID = fixture.documentID
        let checkpoint = reviewCheckpoint(fixture: fixture)
        let record = packageRecord(
            fixture: fixture,
            documentID: documentID,
            sequence: 1,
            checkpoint: checkpoint
        )
        let manifest = WorkspacePackageManifest(
            documentID: documentID,
            workspaceUUID: fixture.identity.workspaceID,
            workspaceName: "Continuation reopen",
            createdAt: Date(timeIntervalSince1970: 20),
            modifiedAt: Date(timeIntervalSince1970: 21),
            binaries: [],
            session: nil,
            assistantSessionRecords: [record]
        )
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-continuation-\(UUID().uuidString)", isDirectory: true)
        let packageURL = parent.appendingPathComponent("Source.mscope", isDirectory: true)
        let rewriteURL = parent.appendingPathComponent("Rewrite.mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)

        let reopened = try WorkspaceStore.restoredPackage(
            from: packageURL,
            scheduleDurableRecovery: false
        )
        XCTAssertEqual(reopened.phase2AssistantSessionHistory.first?.continuationCheckpoint, checkpoint)
        XCTAssertTrue(reopened.writeDocumentPackage(to: rewriteURL, now: Date(timeIntervalSince1970: 22)))
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: rewriteURL)
                .manifest.assistantSessionRecords.first?.continuationCheckpoint,
            checkpoint
        )
    }

    func testPackageAndDatabaseRejectCrossCategoryAuthorityIDCollision() throws {
        let fixture = try Fixture()
        let documentID = fixture.documentID
        let firstCheckpoint = reviewCheckpoint(fixture: fixture)
        let secondIdentity = Phase2AssistantShellTurnIdentity(
            workspaceID: fixture.identity.workspaceID,
            workspaceDocumentIdentityDigest: fixture.identity.workspaceDocumentIdentityDigest,
            conversationID: UUID(),
            inferenceTurnID: UUID(),
            turnSequence: 2,
            originatingFinalizationRequestID: UUID()
        )
        let secondFixture = try Fixture(identity: secondIdentity)
        var secondCheckpoint = reviewCheckpoint(fixture: secondFixture)
        secondCheckpoint.logicalState = Phase2AssistantShellContinuationState.executingShell.rawValue
        secondCheckpoint.humanDecision = "approved"
        secondCheckpoint.approvalConsumedAt = Date(timeIntervalSince1970: 31)
        secondCheckpoint.approvalState = "consumed"
        secondCheckpoint.shellExecutionID = firstCheckpoint.shellProposalID
        XCTAssertTrue(secondCheckpoint.isStructurallyValid)

        let firstPackageRecord = packageRecord(
            fixture: fixture,
            documentID: documentID,
            sequence: 1,
            checkpoint: firstCheckpoint
        )
        let secondPackageRecord = packageRecord(
            fixture: secondFixture,
            documentID: documentID,
            sequence: 2,
            checkpoint: secondCheckpoint
        )
        let manifest = WorkspacePackageManifest(
            documentID: documentID,
            workspaceUUID: fixture.identity.workspaceID,
            workspaceName: "Collision",
            createdAt: Date(timeIntervalSince1970: 30),
            modifiedAt: Date(timeIntervalSince1970: 31),
            binaries: [],
            session: nil,
            assistantSessionRecords: [firstPackageRecord, secondPackageRecord]
        )
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validateManifest(
                manifest,
                in: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .duplicateAssistantShellExecutionID(firstCheckpoint.shellProposalID)
            )
        }

        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceUUID: fixture.identity.workspaceID,
            workspaceName: "Collision",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 30)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try db.upsertPhase2AssistantSessionRecord(databaseRecord(
            fixture: fixture,
            documentID: documentID,
            workspaceID: workspaceID,
            sequence: 1,
            checkpoint: firstCheckpoint
        ))
        XCTAssertThrowsError(try db.upsertPhase2AssistantSessionRecord(databaseRecord(
            fixture: secondFixture,
            documentID: documentID,
            workspaceID: workspaceID,
            sequence: 2,
            checkpoint: secondCheckpoint
        )))
    }

    func testVersion35WithCompleteV36AssistantShapeConvergesThroughV37() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("DROP TABLE phase2_assistant_session_records;")
        try db.executeRawForTesting("""
            CREATE TABLE phase2_assistant_session_records (
              id TEXT PRIMARY KEY, workspace_id INTEGER NOT NULL, workspace_uuid TEXT NOT NULL,
              document_id TEXT NOT NULL, sequence INTEGER NOT NULL, conversation_id TEXT NOT NULL,
              turn_sequence INTEGER NOT NULL, inference_turn_id TEXT NOT NULL,
              is_legacy INTEGER NOT NULL, intent_id TEXT NOT NULL, user_goal TEXT NOT NULL,
              status TEXT NOT NULL, prompt_text TEXT NOT NULL, answer_text TEXT,
              transcript_text TEXT NOT NULL, context_digest TEXT, canonical_byte_count INTEGER,
              provider_tool_count INTEGER NOT NULL, record_schema_version INTEGER NOT NULL,
              created_at TEXT NOT NULL, completed_at TEXT, content_sha256 TEXT NOT NULL
            );
            CREATE UNIQUE INDEX idx_phase2_assistant_sessions_workspace_sequence
              ON phase2_assistant_session_records(workspace_id, sequence);
            CREATE UNIQUE INDEX idx_phase2_assistant_sessions_workspace_conversation_turn
              ON phase2_assistant_session_records(workspace_id, conversation_id, turn_sequence);
            CREATE UNIQUE INDEX idx_phase2_assistant_sessions_workspace_inference_turn
              ON phase2_assistant_session_records(workspace_id, inference_turn_id);
            CREATE INDEX idx_phase2_assistant_sessions_workspace_created
              ON phase2_assistant_session_records(workspace_id, created_at DESC, id);
            """)
        try db.setUserVersionForTesting(35)

        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(
            try db.columnNames(in: "phase2_assistant_session_records")
                .contains("continuation_checkpoint_json")
        )
        XCTAssertEqual(try db.integrityCheck(), ["ok"])
    }

    private func reviewCheckpoint(fixture: Fixture) -> Phase2AssistantContinuationCheckpointRecord {
        Phase2AssistantContinuationCheckpointRecord(
            logicalState: Phase2AssistantShellContinuationState.awaitingShellReview.rawValue,
            initialRequestID: fixture.identity.originatingFinalizationRequestID,
            initialTerminalEventDigest: String(repeating: "f", count: 64),
            shellProposalID: fixture.proposalID,
            shellProposalJSON: "{\"command\":\"true\"}",
            shellProposalSHA256: fixture.proposalDigest,
            humanDecision: nil,
            approvalConsumedAt: nil,
            approvalState: nil,
            shellExecutionID: nil,
            completedExecutionReference: nil,
            shellExecutionSHA256: nil,
            runtimeAuthorityRecordID: nil,
            runtimeAuthoritySHA256: nil,
            continuationCoordinate: nil,
            continuationOrdinal: nil,
            continuationRequestID: nil,
            continuationDispatchState: nil,
            continuationTerminalEventDigest: nil,
            finalProvenanceJSON: nil
        )
    }

    private func continuationDatabase(
        fixture: Fixture,
        state: Phase2AssistantShellContinuationState
    ) throws -> (WorkspaceDatabase, UUID) {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceUUID: fixture.identity.workspaceID,
            workspaceName: "Terminal seal",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 40)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let recordID = fixture.identity.inferenceTurnID
        var checkpoint = reviewCheckpoint(fixture: fixture)
        checkpoint.logicalState = state.rawValue
        checkpoint.humanDecision = "approved"
        checkpoint.approvalConsumedAt = Date(timeIntervalSince1970: 41)
        checkpoint.approvalState = "consumed"
        checkpoint.shellExecutionID = fixture.executionID
        checkpoint.completedExecutionReference = fixture.executionID.uuidString
        checkpoint.shellExecutionSHA256 = fixture.coordinate.shellExecutionResultDigest
        checkpoint.runtimeAuthorityRecordID = fixture.coordinate.runtimeAuthorityRecordID
        checkpoint.runtimeAuthoritySHA256 = fixture.coordinate.runtimeAuthorityRecordDigest
        checkpoint.continuationCoordinate = Phase2AssistantShellContinuationDatabaseCheckpoint
            .persistenceCoordinate(from: fixture.coordinate)
        checkpoint.continuationOrdinal = Int(fixture.coordinate.continuationOrdinal)
        checkpoint.continuationRequestID = fixture.coordinate.continuationRequestID
        checkpoint.continuationDispatchState = state == .continuingShell ? "dispatched" : nil
        try db.upsertPhase2AssistantSessionRecord(databaseRecord(
            fixture: fixture,
            documentID: fixture.documentID,
            workspaceID: workspaceID,
            sequence: 1,
            checkpoint: checkpoint,
            recordID: recordID
        ))
        return (db, recordID)
    }

    private func packageRecord(
        fixture: Fixture,
        documentID: UUID,
        sequence: Int,
        checkpoint: Phase2AssistantContinuationCheckpointRecord
    ) -> WorkspacePackageAssistantSessionRecord {
        var record = WorkspacePackageAssistantSessionRecord(
            id: fixture.identity.inferenceTurnID,
            sequence: sequence,
            conversationID: fixture.identity.conversationID,
            turnSequence: Int(fixture.identity.turnSequence),
            inferenceTurnID: fixture.identity.inferenceTurnID,
            intentID: "assistant.ask_macscope",
            userGoal: "Run true",
            status: WorkspaceDatabase.Phase2AssistantPersistedSessionStatus.outcomeUnknown.rawValue,
            promptText: "prompt",
            answerText: nil,
            transcriptText: "pending",
            contextDigest: fixture.identity.workspaceDocumentIdentityDigest,
            canonicalByteCount: nil,
            providerToolCount: 0,
            createdAt: Date(timeIntervalSince1970: 30 + Double(sequence)),
            completedAt: nil,
            continuationCheckpoint: checkpoint,
            contentSHA256: ""
        )
        record.contentSHA256 = record.calculatedContentSHA256(
            workspaceUUID: fixture.identity.workspaceID,
            documentID: documentID
        )
        return record
    }

    private func databaseRecord(
        fixture: Fixture,
        documentID: UUID,
        workspaceID: Int64,
        sequence: Int,
        checkpoint: Phase2AssistantContinuationCheckpointRecord,
        recordID: UUID? = nil
    ) -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord {
        .init(
            id: recordID ?? fixture.identity.inferenceTurnID,
            workspaceID: workspaceID,
            workspaceUUID: fixture.identity.workspaceID,
            documentID: documentID,
            sequence: sequence,
            conversationID: fixture.identity.conversationID,
            turnSequence: Int(fixture.identity.turnSequence),
            inferenceTurnID: fixture.identity.inferenceTurnID,
            intentID: "assistant.ask_macscope",
            userGoal: "Run true",
            status: .outcomeUnknown,
            promptText: "prompt",
            answerText: nil,
            transcriptText: "pending",
            contextDigest: fixture.identity.workspaceDocumentIdentityDigest,
            canonicalByteCount: nil,
            createdAt: Date(timeIntervalSince1970: 30 + Double(sequence)),
            continuationCheckpoint: checkpoint
        )
    }
}

private struct Fixture {
    let documentID: UUID
    let identity: Phase2AssistantShellTurnIdentity
    let proposalID: UUID
    let proposalDigest: String
    let executionID: UUID
    let approval: Phase2AssistantShellApproval
    let coordinate: Phase2AssistantShellContinuationCoordinate
    let machine: Phase2AssistantShellContinuationMachine

    init(
        identity: Phase2AssistantShellTurnIdentity? = nil,
        documentID: UUID = UUID()
    ) throws {
        let workspaceID = identity?.workspaceID ?? UUID()
        let identity = identity ?? Phase2AssistantShellTurnIdentity(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: Phase2AssistantWorkspaceDocumentIdentity.digest(
                documentID: documentID,
                workspaceID: workspaceID
            ),
            conversationID: UUID(), inferenceTurnID: UUID(), turnSequence: 1,
            originatingFinalizationRequestID: UUID()
        )
        let proposalID = UUID()
        let proposalDigest = String(repeating: "b", count: 64)
        let executionID = UUID()
        let authorityID = UUID()
        let requestID = UUID()
        let coordinate = try XCTUnwrap(Phase2AssistantShellContinuationCoordinate(
            workspaceID: identity.workspaceID,
            workspaceDocumentIdentityDigest: identity.workspaceDocumentIdentityDigest,
            conversationID: identity.conversationID,
            inferenceTurnID: identity.inferenceTurnID,
            turnSequence: identity.turnSequence,
            originatingFinalizationRequestID: identity.originatingFinalizationRequestID,
            shellProposalID: proposalID,
            shellExecutionID: executionID,
            runtimeAuthorityRecordID: authorityID,
            shellProposalDigest: proposalDigest,
            shellExecutionResultDigest: String(repeating: "c", count: 64),
            runtimeAuthorityRecordDigest: String(repeating: "d", count: 64),
            productionManifestIdentity: "sha256:" + String(repeating: "e", count: 64),
            providerRevision: 7,
            continuationRequestID: requestID
        ))
        let approval = Phase2AssistantShellApproval(
            turnIdentity: identity, proposalID: proposalID, proposalDigest: proposalDigest,
            reservedExecutionID: executionID
        )
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
        _ = machine.apply(.beginToolSelection(identity))
        _ = machine.apply(.beginFinalization(identity))
        _ = machine.apply(.stageProposal(.init(
            turnIdentity: identity, proposalID: proposalID, proposalDigest: proposalDigest,
            executionSurface: .restrictedOneShotJob, isLegacy: false
        )))
        self.documentID = documentID
        self.identity = identity
        self.proposalID = proposalID
        self.proposalDigest = proposalDigest
        self.executionID = executionID
        self.approval = approval
        self.coordinate = coordinate
        self.machine = machine
    }
}

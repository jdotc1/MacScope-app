import XCTest
import SQLite3
@testable import MacScope

final class WorkspaceDatabaseTests: XCTestCase {
    func testSavedWatchDatabaseRejectsHostileOversizedBlobBeforeCanonicalDecode() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.createWorkspaceState(
            workspaceName: "Hostile watches", snapshot: previewSnapshotWithMetadata(),
            selectedSidebarItemID: nil, selectedAddress: nil, selectedTool: .project,
            editorMode: .disassembly, isInspectorPresented: true, sidebarSearchText: "")
        let workspaceID = try XCTUnwrap(saved.workspace.id)
        try database.executeRawForTesting("PRAGMA ignore_check_constraints = ON;")
        try database.executeRawForTesting("UPDATE saved_watch_catalogs SET catalog_blob = zeroblob(1048576);")
        XCTAssertThrowsError(try database.loadWorkspaceState(workspaceID: workspaceID)) { error in
            XCTAssertTrue(error is WorkspaceSavedWatchValidationError)
        }
        try database.executeRawForTesting("UPDATE saved_watch_catalogs SET catalog_blob = 'wrong storage';")
        XCTAssertThrowsError(try database.loadWorkspaceState(workspaceID: workspaceID)) { error in
            XCTAssertTrue(error is WorkspaceSavedWatchValidationError)
        }
    }
    @MainActor
    func testSavedWatchOwnerInvalidatesOnSameIdentityRestoreAndFork() throws {
        let store = WorkspaceStore(workspaceName: "Installation", snapshot: previewSnapshotWithMetadata(),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try store.saveWorkspace(to: database)
        let original = try XCTUnwrap(store.captureSavedWatchOwner())
        let installation = store.documentInstallationID
        store.restoreWorkspace(saved)
        XCTAssertEqual(store.workspaceID, original.workspaceID)
        XCTAssertEqual(store.documentID, original.documentID)
        XCTAssertNotEqual(store.documentInstallationID, installation)
        XCTAssertFalse(store.isCurrentSavedWatchOwner(original))
        XCTAssertThrowsError(try store.replaceSavedWatchDefinitions([], owner: original))
        let restored = try XCTUnwrap(store.captureSavedWatchOwner())
        XCTAssertTrue(store.isCurrentSavedWatchOwner(restored))
        _ = store.forkWorkspaceIdentity()
        XCTAssertFalse(store.isCurrentSavedWatchOwner(restored))
        XCTAssertThrowsError(try store.replaceSavedWatchDefinitions([], owner: restored))
    }
    @MainActor
    func testSavedWatchesRoundTripPackageAndDatabaseWithoutRuntimeValues() throws {
        let store = WorkspaceStore(workspaceName: "Watches", snapshot: previewSnapshotWithMetadata(),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let owner = try XCTUnwrap(store.captureSavedWatchOwner())
        let definition = try WorkspaceSavedWatchDefinition(id: UUID(), expression: "counter + 1")
        try store.replaceSavedWatchDefinitions([definition], owner: owner)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try store.saveWorkspace(to: database)
        XCTAssertEqual(saved.snapshot.savedWatchCatalog.definitions, [definition])
        let reloaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: saved.workspace.id!))
        XCTAssertEqual(reloaded.snapshot.savedWatchCatalog, store.savedWatchCatalog)
        XCTAssertEqual(reloaded.snapshot.functions, store.snapshot.functions)
        let analysis = WorkspacePackageAnalysis(snapshot: reloaded.snapshot)
        let bytes = try JSONEncoder().encode(analysis)
        let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(from: bytes)
        XCTAssertEqual(decoded.savedWatchCatalog.definitions, [definition])
        XCTAssertEqual(decoded.snapshot(binaries: [], hexBytes: Data()).savedWatchCatalog,
                       store.savedWatchCatalog)
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }
        _ = try database.writePackage(workspaceID: try XCTUnwrap(saved.workspace.id),
                                      documentID: store.documentID, to: packageURL)
        let destination = try WorkspaceDatabase.inMemory()
        try destination.applySchema()
        let reopened = try destination.importPackage(from: packageURL)
        XCTAssertEqual(reopened.snapshot.savedWatchCatalog, store.savedWatchCatalog)
        XCTAssertEqual(reopened.snapshot.bookmarks, saved.snapshot.bookmarks)
        try database.executeRawForTesting("UPDATE saved_watch_catalogs SET catalog_sha256 = 'bad';")
        XCTAssertThrowsError(try database.loadWorkspaceState(workspaceID: try XCTUnwrap(saved.workspace.id)))
        let sibling = WorkspaceStore(workspaceName: "Other", snapshot: previewSnapshotWithMetadata(),
                                     engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertThrowsError(try sibling.replaceSavedWatchDefinitions([definition], owner: owner))
        store.retireDocumentSessionWriter()
        XCTAssertThrowsError(try store.replaceSavedWatchDefinitions([], owner: owner))
    }

    func testSavedWatchesV41MigrationPreservesRecordsAndDefaultsEmpty() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.createWorkspaceState(
            workspaceName: "Legacy", snapshot: previewSnapshotWithMetadata(), selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "")
        try database.executeRawForTesting("DROP TABLE saved_watch_catalogs;")
        try database.setUserVersionForTesting(41)
        try database.applySchema()
        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        let loaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspace.workspace.id!))
        XCTAssertEqual(loaded.snapshot.savedWatchCatalog, .empty)
        XCTAssertEqual(loaded.snapshot.functions, workspace.snapshot.functions)
        XCTAssertEqual(loaded.snapshot.launchProfileCatalog, workspace.snapshot.launchProfileCatalog)
        XCTAssertEqual(try WorkspacePackageAnalysis.decodeStrictPackageJSON(from: Data("{}".utf8))
            .savedWatchCatalog, .empty)
    }

    func testSavedWatchesRejectDuplicateOversizedMalformedAndLossyPayloads() throws {
        let definition = try WorkspaceSavedWatchDefinition(id: UUID(), expression: "x")
        XCTAssertThrowsError(try WorkspaceSavedWatchCatalog(definitions: [definition, definition]))
        XCTAssertThrowsError(try WorkspaceSavedWatchCatalog(definitions: (0..<17).map { _ in
            try WorkspaceSavedWatchDefinition(id: UUID(), expression: "x")
        }))
        XCTAssertThrowsError(try WorkspaceSavedWatchDefinition(id: UUID(), expression: "x\ny"))
        XCTAssertThrowsError(try WorkspaceSavedWatchDefinition(id: UUID(), expression: String(repeating: "é", count: 513)))
        let catalog = try WorkspaceSavedWatchCatalog(definitions: [definition])
        XCTAssertEqual(try WorkspaceSavedWatchCatalog.decodeCanonicalBytes(catalog.canonicalBytes()), catalog)
        let lossy = Data("{\"definitions\":[],\"values\":[\"secret\"],\"version\":1}".utf8)
        XCTAssertThrowsError(try WorkspaceSavedWatchCatalog.decodeCanonicalBytes(lossy))
        XCTAssertThrowsError(try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data("{\"savedWatchCatalog\":null}".utf8)))
        let base64 = try catalog.canonicalBytes().base64EncodedString()
        XCTAssertThrowsError(try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data("{\"savedWatchCatalog\":\"\(base64)\",\"savedWatchCatalog\":\"\(base64)\"}".utf8)))
    }

    func testSavedWatchesMigrationRejectsMalformedTableWithoutVersionAdvance() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        try database.executeRawForTesting("DROP TABLE saved_watch_catalogs;")
        try database.executeRawForTesting("CREATE TABLE saved_watch_catalogs (workspace_id INTEGER);")
        try database.setUserVersionForTesting(41)
        XCTAssertThrowsError(try database.applySchema())
        XCTAssertEqual(try database.userVersion(), 41)
        XCTAssertEqual(try database.columnNames(in: "saved_watch_catalogs"), ["workspace_id"])
    }
    private static let currentSourceLineColumns = [
        "id", "binary_id", "address", "file", "line", "column", "is_end_sequence",
        "debug_artifact_uuid", "debug_artifact_macho_sha256",
        "debug_artifact_macho_byte_count", "line_program_unit_offset", "file_table_index",
        "table_path_kind", "table_path",
    ]

    func testFreshSchemaCreatesPhase2AssistantSessionRecordsTable() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try db.tableNames().contains("phase2_assistant_session_records"))
        XCTAssertTrue(try db.tableNames().contains("phase2_runtime_authority_records"))
        XCTAssertTrue(try db.tableNames().contains("phase2_shell_sessions"))
        XCTAssertEqual(
            try db.columnNames(in: "phase2_assistant_session_records"),
            [
                "id", "workspace_id", "workspace_uuid", "document_id", "sequence",
                "conversation_id", "turn_sequence", "inference_turn_id", "is_legacy",
                "intent_id", "user_goal", "status", "prompt_text", "answer_text", "transcript_text",
                "context_digest", "canonical_byte_count", "provider_tool_count",
                "continuation_checkpoint_json", "shell_proposal_id", "shell_execution_id",
                "continuation_ordinal", "continuation_request_id",
                "record_schema_version", "created_at", "completed_at", "content_sha256",
            ]
        )
        XCTAssertEqual(
            try db.indexColumns(of: "idx_phase2_assistant_sessions_workspace_sequence"),
            ["workspace_id", "sequence"]
        )
        XCTAssertEqual(
            try db.indexColumns(of: "idx_phase2_assistant_sessions_workspace_conversation_turn"),
            ["workspace_id", "conversation_id", "turn_sequence"]
        )
        XCTAssertEqual(
            try db.indexColumns(of: "idx_phase2_assistant_sessions_workspace_inference_turn"),
            ["workspace_id", "inference_turn_id"]
        )
        XCTAssertEqual(
            try db.indexColumns(of: "idx_phase2_assistant_sessions_workspace_created"),
            ["workspace_id", "created_at", "id"]
        )
        XCTAssertEqual(
            try db.columnNames(in: "phase2_runtime_authority_records"),
            [
                "id", "workspace_id", "workspace_uuid", "document_id", "session_id", "surfaces_json",
                "terminal_backend", "pty_reuse_policy", "debugger_authority_policy_json",
                "provider_visible_shell_execution_enabled", "record_schema_version", "created_at",
            ]
        )
        XCTAssertEqual(
            try db.indexColumns(of: "idx_phase2_runtime_authority_workspace_created"),
            ["workspace_id", "created_at", "id"]
        )
        XCTAssertEqual(
            try db.columnNames(in: "phase2_shell_sessions"),
            [
                "workspace_id", "workspace_uuid", "document_id", "shell_session_json",
                "record_schema_version", "updated_at",
            ]
        )
    }

    func testMigrationV31ToCurrentAddsPhase2AssistantSessionRecordsTable() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("DROP TABLE IF EXISTS phase2_assistant_session_records;")
        try db.setUserVersionForTesting(31)

        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try db.tableNames().contains("phase2_assistant_session_records"))
        XCTAssertTrue(try db.tableNames().contains("phase2_runtime_authority_records"))
        XCTAssertTrue(try db.tableNames().contains("phase2_shell_sessions"))
        XCTAssertNoThrow(try db.applySchema())
    }

    func testMigrationV34ToCurrentAddsPhase2ShellSessionsTable() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("DROP TABLE IF EXISTS phase2_shell_sessions;")
        try db.executeRawForTesting("DROP TABLE IF EXISTS phase2_assistant_session_records;")
        try db.executeRawForTesting("""
            CREATE TABLE phase2_assistant_session_records (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              workspace_uuid TEXT NOT NULL,
              document_id TEXT NOT NULL,
              sequence INTEGER NOT NULL CHECK(sequence > 0),
              intent_id TEXT NOT NULL,
              user_goal TEXT NOT NULL,
              status TEXT NOT NULL,
              prompt_text TEXT NOT NULL,
              answer_text TEXT,
              transcript_text TEXT NOT NULL,
              context_digest TEXT,
              canonical_byte_count INTEGER CHECK(canonical_byte_count IS NULL OR canonical_byte_count >= 0),
              provider_tool_count INTEGER NOT NULL DEFAULT 0 CHECK(provider_tool_count BETWEEN 0 AND 64),
              record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 1),
              created_at TEXT NOT NULL,
              completed_at TEXT,
              content_sha256 TEXT NOT NULL
            );
            CREATE UNIQUE INDEX idx_phase2_assistant_sessions_workspace_sequence
              ON phase2_assistant_session_records(workspace_id, sequence);
            CREATE INDEX idx_phase2_assistant_sessions_workspace_created
              ON phase2_assistant_session_records(workspace_id, created_at DESC, id);
            """)
        try db.setUserVersionForTesting(34)

        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try db.tableNames().contains("phase2_shell_sessions"))
        XCTAssertNoThrow(try db.applySchema())
    }

    func testPersistsPhase2ShellSessionRecordScopedToWorkspace() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let firstWorkspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000033")!,
            workspaceName: "Shell Session One",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 5_500)
        )
        let secondWorkspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000034")!,
            workspaceName: "Shell Session Two",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 5_600)
        )
        let firstWorkspaceID = try XCTUnwrap(firstWorkspace.id)
        let secondWorkspaceID = try XCTUnwrap(secondWorkspace.id)
        let firstDocumentID = UUID(uuidString: "20000000-0000-0000-0000-000000000033")!
        let secondDocumentID = UUID(uuidString: "20000000-0000-0000-0000-000000000034")!
        let firstShell = workspacePackagePhase2ShellSession(
            sessionID: UUID(uuidString: "30000000-0000-0000-0000-000000000033")!,
            requestID: UUID(uuidString: "40000000-0000-0000-0000-000000000033")!,
            processIdentifier: 933,
            columns: 132,
            rows: 44
        )
        let secondShell = workspacePackagePhase2ShellSession(
            sessionID: UUID(uuidString: "30000000-0000-0000-0000-000000000034")!,
            requestID: UUID(uuidString: "40000000-0000-0000-0000-000000000034")!,
            processIdentifier: 934,
            columns: 100,
            rows: 28
        )

        try db.upsertPhase2ShellSessionRecord(.init(
            workspaceID: firstWorkspaceID,
            workspaceUUID: firstWorkspace.uuid,
            documentID: firstDocumentID,
            shellSession: firstShell,
            updatedAt: Date(timeIntervalSince1970: 5_700)
        ))
        try db.upsertPhase2ShellSessionRecord(.init(
            workspaceID: secondWorkspaceID,
            workspaceUUID: secondWorkspace.uuid,
            documentID: secondDocumentID,
            shellSession: secondShell,
            updatedAt: Date(timeIntervalSince1970: 5_800)
        ))

        XCTAssertEqual(try db.phase2ShellSessionRecord(workspaceID: firstWorkspaceID)?.shellSession, firstShell)
        XCTAssertEqual(try db.phase2ShellSessionRecord(workspaceID: secondWorkspaceID)?.shellSession, secondShell)

        let updatedShell = workspacePackagePhase2ShellSession(
            sessionID: firstShell.sessionID,
            requestID: firstShell.runningRequestID!,
            processIdentifier: 935,
            columns: 140,
            rows: 50
        )
        try db.replacePhase2ShellSessionRecord(
            workspaceID: firstWorkspaceID,
            record: .init(
                workspaceID: firstWorkspaceID,
                workspaceUUID: firstWorkspace.uuid,
                documentID: firstDocumentID,
                shellSession: updatedShell,
                updatedAt: Date(timeIntervalSince1970: 5_900)
            )
        )
        XCTAssertEqual(try db.phase2ShellSessionRecord(workspaceID: firstWorkspaceID)?.shellSession, updatedShell)

        try db.deleteWorkspace(id: firstWorkspaceID)
        XCTAssertNil(try db.phase2ShellSessionRecord(workspaceID: firstWorkspaceID))
        XCTAssertEqual(try db.phase2ShellSessionRecord(workspaceID: secondWorkspaceID)?.shellSession, secondShell)
    }

    func testPersistsPhase2RuntimeAuthorityRecordsNewestFirstAndScopedToWorkspace() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let firstWorkspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000030")!,
            workspaceName: "Runtime Authority One",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 5_000)
        )
        let secondWorkspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000031")!,
            workspaceName: "Runtime Authority Two",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 5_100)
        )
        let firstWorkspaceID = try XCTUnwrap(firstWorkspace.id)
        let secondWorkspaceID = try XCTUnwrap(secondWorkspace.id)
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000030")!
        let older = WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000030")!,
            workspaceID: firstWorkspaceID,
            workspaceUUID: firstWorkspace.uuid,
            documentID: documentID,
            sessionID: UUID(uuidString: "40000000-0000-0000-0000-000000000030")!,
            surfaces: [.providerVisibleShellExecution],
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .disabled,
            debuggerAuthorityPolicy: .disabled,
            providerVisibleShellExecutionEnabled: true,
            createdAt: Date(timeIntervalSince1970: 5_200)
        )
        let newer = WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000031")!,
            workspaceID: firstWorkspaceID,
            workspaceUUID: firstWorkspace.uuid,
            documentID: documentID,
            sessionID: UUID(uuidString: "40000000-0000-0000-0000-000000000031")!,
            surfaces: [.terminalEmulation, .shellBrokerPTYReuse, .debuggerReadOnly],
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .shellBrokerSession,
            debuggerAuthorityPolicy: .readOnlyInspection,
            providerVisibleShellExecutionEnabled: false,
            createdAt: Date(timeIntervalSince1970: 5_300)
        )
        let otherWorkspace = WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000032")!,
            workspaceID: secondWorkspaceID,
            workspaceUUID: secondWorkspace.uuid,
            documentID: UUID(uuidString: "20000000-0000-0000-0000-000000000031")!,
            sessionID: UUID(uuidString: "40000000-0000-0000-0000-000000000032")!,
            surfaces: [.providerVisibleShellExecution],
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .disabled,
            debuggerAuthorityPolicy: .disabled,
            providerVisibleShellExecutionEnabled: false,
            createdAt: Date(timeIntervalSince1970: 5_400)
        )

        try db.upsertPhase2RuntimeAuthorityRecord(older)
        try db.upsertPhase2RuntimeAuthorityRecord(newer)
        try db.upsertPhase2RuntimeAuthorityRecord(otherWorkspace)

        XCTAssertEqual(try db.phase2RuntimeAuthorityRecords(workspaceID: firstWorkspaceID), [newer, older])
        XCTAssertEqual(try db.phase2RuntimeAuthorityRecords(workspaceID: firstWorkspaceID, limit: 1), [newer])
        XCTAssertEqual(try db.phase2RuntimeAuthorityRecords(workspaceID: secondWorkspaceID), [otherWorkspace])

        var updated = older
        updated.providerVisibleShellExecutionEnabled = false
        updated.surfaces = [.providerVisibleShellExecution, .terminalEmulation]
        try db.upsertPhase2RuntimeAuthorityRecord(updated)
        XCTAssertEqual(try db.phase2RuntimeAuthorityRecords(workspaceID: firstWorkspaceID).map(\.id), [newer.id, updated.id])
        XCTAssertEqual(
            try db.phase2RuntimeAuthorityRecords(workspaceID: firstWorkspaceID).first { $0.id == updated.id },
            updated
        )

        try db.deleteWorkspace(id: firstWorkspaceID)
        XCTAssertEqual(try db.phase2RuntimeAuthorityRecords(workspaceID: firstWorkspaceID), [])
        XCTAssertEqual(try db.phase2RuntimeAuthorityRecords(workspaceID: secondWorkspaceID), [otherWorkspace])
    }

    func testPersistsPhase2AssistantSessionRecordsNewestFirstAndScopedToWorkspace() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let firstWorkspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            workspaceName: "Assistant One",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 2_000)
        )
        let secondWorkspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            workspaceName: "Assistant Two",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 2_100)
        )
        let firstWorkspaceID = try XCTUnwrap(firstWorkspace.id)
        let secondWorkspaceID = try XCTUnwrap(secondWorkspace.id)
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

        let older = phase2AssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            workspaceID: firstWorkspaceID,
            workspaceUUID: firstWorkspace.uuid,
            documentID: documentID,
            sequence: 1,
            status: .completed,
            answerText: "answer one",
            createdAt: Date(timeIntervalSince1970: 2_200)
        )
        let newer = phase2AssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            workspaceID: firstWorkspaceID,
            workspaceUUID: firstWorkspace.uuid,
            documentID: documentID,
            sequence: 2,
            status: .failed,
            answerText: nil,
            createdAt: Date(timeIntervalSince1970: 2_300)
        )
        let otherWorkspace = phase2AssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            workspaceID: secondWorkspaceID,
            workspaceUUID: secondWorkspace.uuid,
            documentID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            sequence: 1,
            status: .readinessBlocked,
            answerText: nil,
            createdAt: Date(timeIntervalSince1970: 2_400)
        )

        try db.upsertPhase2AssistantSessionRecord(older)
        try db.upsertPhase2AssistantSessionRecord(newer)
        try db.upsertPhase2AssistantSessionRecord(otherWorkspace)

        XCTAssertEqual(try db.phase2AssistantSessionRecord(id: older.id), older)
        XCTAssertEqual(
            try db.phase2AssistantSessionRecords(workspaceID: firstWorkspaceID).map(\.id),
            [newer.id, older.id]
        )
        XCTAssertEqual(
            try db.phase2AssistantSessionRecords(workspaceID: firstWorkspaceID, limit: 1),
            [newer]
        )
        XCTAssertEqual(
            try db.phase2AssistantSessionRecords(workspaceID: secondWorkspaceID),
            [otherWorkspace]
        )

        var updated = older
        updated.answerText = "updated answer"
        updated.transcriptText = "updated transcript"
        updated.contentSHA256 = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord.contentSHA256(
            id: updated.id,
            workspaceUUID: updated.workspaceUUID,
            documentID: updated.documentID,
            sequence: updated.sequence,
            conversationID: updated.conversationID,
            turnSequence: updated.turnSequence,
            inferenceTurnID: updated.inferenceTurnID,
            isLegacy: updated.isLegacy,
            intentID: updated.intentID,
            userGoal: updated.userGoal,
            status: updated.status,
            promptText: updated.promptText,
            answerText: updated.answerText,
            transcriptText: updated.transcriptText,
            contextDigest: updated.contextDigest,
            canonicalByteCount: updated.canonicalByteCount,
            providerToolCount: updated.providerToolCount,
            recordSchemaVersion: updated.recordSchemaVersion,
            createdAt: updated.createdAt,
            completedAt: updated.completedAt
        )
        try db.upsertPhase2AssistantSessionRecord(updated)
        XCTAssertEqual(try db.phase2AssistantSessionRecord(id: older.id), updated)
    }

    func testPhase2AssistantSessionRecordsAllowBoundedProviderToolCountsAndCascadeDelete() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            workspaceName: "Assistant Authority",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let valid = phase2AssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            sequence: 1,
            status: .completed,
            answerText: "answer",
            createdAt: Date(timeIntervalSince1970: 3_000)
        )

        try db.upsertPhase2AssistantSessionRecord(valid)
        var bounded = valid
        bounded.id = UUID(uuidString: "30000000-0000-0000-0000-000000000011")!
        bounded.sequence = 2
        bounded.conversationID = bounded.id
        bounded.inferenceTurnID = bounded.id
        bounded.providerToolCount = 1
        bounded.contentSHA256 = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord.contentSHA256(
            id: bounded.id,
            workspaceUUID: bounded.workspaceUUID,
            documentID: bounded.documentID,
            sequence: bounded.sequence,
            conversationID: bounded.conversationID,
            turnSequence: bounded.turnSequence,
            inferenceTurnID: bounded.inferenceTurnID,
            isLegacy: bounded.isLegacy,
            intentID: bounded.intentID,
            userGoal: bounded.userGoal,
            status: bounded.status,
            promptText: bounded.promptText,
            answerText: bounded.answerText,
            transcriptText: bounded.transcriptText,
            contextDigest: bounded.contextDigest,
            canonicalByteCount: bounded.canonicalByteCount,
            providerToolCount: bounded.providerToolCount,
            recordSchemaVersion: bounded.recordSchemaVersion,
            createdAt: bounded.createdAt,
            completedAt: bounded.completedAt
        )
        try db.upsertPhase2AssistantSessionRecord(bounded)

        var invalid = bounded
        invalid.id = UUID(uuidString: "30000000-0000-0000-0000-000000000012")!
        invalid.sequence = 3
        invalid.conversationID = invalid.id
        invalid.inferenceTurnID = invalid.id
        invalid.providerToolCount = WorkspacePackageAssistantSessionRecord.providerToolCountRange.upperBound + 1
        invalid.contentSHA256 = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord.contentSHA256(
            id: invalid.id,
            workspaceUUID: invalid.workspaceUUID,
            documentID: invalid.documentID,
            sequence: invalid.sequence,
            conversationID: invalid.conversationID,
            turnSequence: invalid.turnSequence,
            inferenceTurnID: invalid.inferenceTurnID,
            isLegacy: invalid.isLegacy,
            intentID: invalid.intentID,
            userGoal: invalid.userGoal,
            status: invalid.status,
            promptText: invalid.promptText,
            answerText: invalid.answerText,
            transcriptText: invalid.transcriptText,
            contextDigest: invalid.contextDigest,
            canonicalByteCount: invalid.canonicalByteCount,
            providerToolCount: invalid.providerToolCount,
            recordSchemaVersion: invalid.recordSchemaVersion,
            createdAt: invalid.createdAt,
            completedAt: invalid.completedAt
        )
        XCTAssertThrowsError(try db.upsertPhase2AssistantSessionRecord(invalid))

        try db.deleteWorkspace(id: workspaceID)
        XCTAssertNil(try db.phase2AssistantSessionRecord(id: valid.id))
        XCTAssertNil(try db.phase2AssistantSessionRecord(id: bounded.id))
    }

    func testPhase2AssistantSessionRecordsRoundTripThroughWorkspacePackage() throws {
        let sourceDB = try WorkspaceDatabase.inMemory()
        try sourceDB.applySchema()
        let workspace = try sourceDB.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000020")!,
            workspaceName: "Assistant Package",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 4_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000020")!
        let first = phase2AssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000020")!,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: documentID,
            sequence: 1,
            status: .completed,
            answerText: "package answer",
            createdAt: Date(timeIntervalSince1970: 4_100)
        )
        let second = phase2AssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000021")!,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: documentID,
            sequence: 2,
            status: .outcomeUnknown,
            answerText: nil,
            createdAt: Date(timeIntervalSince1970: 4_200)
        )
        try sourceDB.upsertPhase2AssistantSessionRecord(second)
        try sourceDB.upsertPhase2AssistantSessionRecord(first)

        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let manifest = try sourceDB.writePackage(
            workspaceID: workspaceID,
            documentID: documentID,
            to: packageURL
        )

        XCTAssertEqual(manifest.assistantSessionRecords.map(\.id), [first.id, second.id])
        XCTAssertEqual(manifest.assistantSessionRecords.map(\.providerToolCount), [0, 0])
        let reopenedPackage = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(reopenedPackage.manifest.assistantSessionRecords, manifest.assistantSessionRecords)

        let importedDB = try WorkspaceDatabase.inMemory()
        try importedDB.applySchema()
        let imported = try importedDB.importPackage(from: packageURL)
        let importedWorkspaceID = try XCTUnwrap(imported.workspace.id)
        XCTAssertEqual(imported.workspace.uuid, workspace.uuid)
        XCTAssertEqual(
            try importedDB.phase2AssistantSessionRecords(workspaceID: importedWorkspaceID).map(\.id),
            [second.id, first.id]
        )
        XCTAssertEqual(
            try importedDB.phase2AssistantSessionRecord(id: first.id),
            WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
                id: first.id,
                workspaceID: importedWorkspaceID,
                workspaceUUID: workspace.uuid,
                documentID: documentID,
                sequence: first.sequence,
                intentID: first.intentID,
                userGoal: first.userGoal,
                status: first.status,
                promptText: first.promptText,
                answerText: first.answerText,
                transcriptText: first.transcriptText,
                contextDigest: first.contextDigest,
                canonicalByteCount: first.canonicalByteCount,
                createdAt: first.createdAt,
                completedAt: first.completedAt
            )
        )
    }

    func testPhase2RuntimeAuthorityRecordsRoundTripThroughWorkspacePackage() throws {
        let sourceDB = try WorkspaceDatabase.inMemory()
        try sourceDB.applySchema()
        let workspace = try sourceDB.saveSnapshot(
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000026")!,
            workspaceName: "Runtime Authority Package",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 4_400)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000026")!
        let shellRecord = WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000026")!,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: documentID,
            sessionID: UUID(uuidString: "40000000-0000-0000-0000-000000000026")!,
            surfaces: [.providerVisibleShellExecution],
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .disabled,
            debuggerAuthorityPolicy: .disabled,
            providerVisibleShellExecutionEnabled: true,
            createdAt: Date(timeIntervalSince1970: 4_500)
        )
        let debuggerRecord = WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000027")!,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: documentID,
            sessionID: UUID(uuidString: "40000000-0000-0000-0000-000000000027")!,
            surfaces: [.debuggerReadOnly],
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .disabled,
            debuggerAuthorityPolicy: .readOnlyInspection,
            providerVisibleShellExecutionEnabled: false,
            createdAt: Date(timeIntervalSince1970: 4_600)
        )
        try sourceDB.upsertPhase2RuntimeAuthorityRecord(debuggerRecord)
        try sourceDB.upsertPhase2RuntimeAuthorityRecord(shellRecord)

        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let manifest = try sourceDB.writePackage(
            workspaceID: workspaceID,
            documentID: documentID,
            to: packageURL
        )

        XCTAssertEqual(manifest.runtimeAuthorityRecords.map(\.id), [shellRecord.id, debuggerRecord.id])
        XCTAssertEqual(manifest.runtimeAuthorityRecords.map(\.sessionID), [shellRecord.sessionID, debuggerRecord.sessionID])
        XCTAssertEqual(manifest.runtimeAuthorityRecords.map(\.surfaces), [
            [.providerVisibleShellExecution],
            [.debuggerReadOnly],
        ])
        XCTAssertEqual(manifest.runtimeAuthorityRecords.map(\.debuggerAuthorityPolicy), [
            .disabled,
            .readOnlyInspection,
        ])
        XCTAssertEqual(manifest.runtimeAuthorityRecords.map(\.providerVisibleShellExecutionEnabled), [
            true,
            false,
        ])
        let reopenedPackage = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(reopenedPackage.manifest.runtimeAuthorityRecords, manifest.runtimeAuthorityRecords)

        let importedDB = try WorkspaceDatabase.inMemory()
        try importedDB.applySchema()
        let imported = try importedDB.importPackage(from: packageURL)
        let importedWorkspaceID = try XCTUnwrap(imported.workspace.id)
        XCTAssertEqual(
            try importedDB.phase2RuntimeAuthorityRecords(workspaceID: importedWorkspaceID).map(\.id),
            [debuggerRecord.id, shellRecord.id]
        )
        let importedRecords = try importedDB.phase2RuntimeAuthorityRecords(workspaceID: importedWorkspaceID)
        XCTAssertEqual(importedRecords.map(\.workspaceID), [importedWorkspaceID, importedWorkspaceID])
        XCTAssertEqual(importedRecords.map(\.workspaceUUID), [workspace.uuid, workspace.uuid])
        XCTAssertEqual(importedRecords.map(\.documentID), [documentID, documentID])
        XCTAssertEqual(importedRecords.map(\.surfaces), [
            [.debuggerReadOnly],
            [.providerVisibleShellExecution],
        ])
        XCTAssertTrue(importedRecords.allSatisfy { $0.authorityRecord.isStructurallyValid })
    }

    func testWorkspacePackageRejectsOutOfRangeAssistantSessionProviderToolCount() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let record = WorkspacePackageAssistantSessionRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000030")!,
            sequence: 1,
            intentID: "assistant.ask_macscope",
            userGoal: "Summarize the current workspace.",
            status: WorkspaceDatabase.Phase2AssistantPersistedSessionStatus.completed.rawValue,
            promptText: "Prompt text",
            answerText: "answer",
            transcriptText: "transcript",
            contextDigest: String(repeating: "b", count: 64),
            canonicalByteCount: 128,
            providerToolCount: WorkspacePackageAssistantSessionRecord.providerToolCountRange.upperBound + 1,
            createdAt: Date(timeIntervalSince1970: 4_300),
            completedAt: Date(timeIntervalSince1970: 4_301),
            contentSHA256: String(repeating: "c", count: 64)
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "20000000-0000-0000-0000-000000000030")!,
            workspaceUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000030")!,
            workspaceName: "Invalid Assistant Authority",
            createdAt: Date(timeIntervalSince1970: 4_300),
            modifiedAt: Date(timeIntervalSince1970: 4_301),
            binaries: [],
            session: nil,
            assistantSessionRecords: [record]
        )

        XCTAssertThrowsError(try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .invalidAssistantSessionProviderToolCount(
                    record.id,
                    WorkspacePackageAssistantSessionRecord.providerToolCountRange.upperBound + 1
                )
            )
        }
    }

    @MainActor
    func testPhase2AssistantContinuationCheckpointRoundTripsAndTransitionsOnce() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspaceUUID = UUID(uuidString: "10000000-0000-0000-0000-000000000091")!
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000091")!
        let workspace = try db.saveSnapshot(
            workspaceUUID: workspaceUUID,
            workspaceName: "Continuation",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 9_100)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000091")!
        let requestID = UUID(uuidString: "40000000-0000-0000-0000-000000000091")!
        let initialRequestID = UUID(uuidString: "50000000-0000-0000-0000-000000000091")!
        let executionID = UUID(uuidString: "60000000-0000-0000-0000-000000000091")!
        let authorityID = UUID(uuidString: "70000000-0000-0000-0000-000000000091")!
        let conversationID = UUID(uuidString: "90000000-0000-0000-0000-000000000091")!
        let inferenceTurnID = UUID(uuidString: "A0000000-0000-0000-0000-000000000091")!
        let coordinate = try XCTUnwrap(Phase2AssistantShellContinuationCoordinate(
            workspaceID: workspaceUUID,
            workspaceDocumentIdentityDigest: String(repeating: "5", count: 64),
            conversationID: conversationID,
            inferenceTurnID: inferenceTurnID,
            turnSequence: 1,
            originatingFinalizationRequestID: initialRequestID,
            shellProposalID: proposalID,
            shellExecutionID: executionID,
            runtimeAuthorityRecordID: authorityID,
            shellProposalDigest: String(repeating: "2", count: 64),
            shellExecutionResultDigest: String(repeating: "3", count: 64),
            runtimeAuthorityRecordDigest: String(repeating: "4", count: 64),
            productionManifestIdentity: "sha256:" + String(repeating: "6", count: 64),
            providerRevision: 6,
            continuationRequestID: requestID
        ))
        let checkpoint = Phase2AssistantContinuationCheckpointRecord(
            logicalState: "awaitingShellContinuation",
            initialRequestID: initialRequestID,
            initialTerminalEventDigest: String(repeating: "1", count: 64),
            shellProposalID: proposalID,
            shellProposalJSON: "{\"command\":\"pwd\"}",
            shellProposalSHA256: String(repeating: "2", count: 64),
            humanDecision: "approved",
            approvalConsumedAt: Date(timeIntervalSince1970: 9_101),
            approvalState: "consumed",
            shellExecutionID: executionID,
            completedExecutionReference: executionID.uuidString,
            shellExecutionSHA256: String(repeating: "3", count: 64),
            runtimeAuthorityRecordID: authorityID,
            runtimeAuthoritySHA256: String(repeating: "4", count: 64),
            continuationCoordinate: try XCTUnwrap(
                Phase2AssistantShellContinuationDatabaseCheckpoint.persistenceCoordinate(from: coordinate)
            ),
            continuationOrdinal: 1,
            continuationRequestID: requestID,
            continuationDispatchState: "reserved",
            continuationTerminalEventDigest: nil,
            finalProvenanceJSON: nil
        )
        let record = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000091")!,
            workspaceID: workspaceID,
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sequence: 1,
            conversationID: conversationID,
            turnSequence: 1,
            inferenceTurnID: inferenceTurnID,
            intentID: "assistant.ask_macscope",
            userGoal: "Run pwd and continue.",
            status: .outcomeUnknown,
            promptText: "prompt",
            answerText: nil,
            transcriptText: "pending",
            contextDigest: nil,
            canonicalByteCount: nil,
            createdAt: Date(timeIntervalSince1970: 9_100),
            continuationCheckpoint: checkpoint
        )
        try db.upsertPhase2AssistantSessionRecord(record)

        XCTAssertEqual(try db.phase2AssistantSessionRecord(id: record.id), record)
        XCTAssertEqual(try db.phase2AssistantSessionRecord(continuationRequestID: requestID), record)

        var transitioned = record
        transitioned.continuationCheckpoint?.logicalState = "continuingShell"
        transitioned.contentSHA256 = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord.contentSHA256(
            id: transitioned.id, workspaceUUID: transitioned.workspaceUUID, documentID: transitioned.documentID,
            sequence: transitioned.sequence, conversationID: transitioned.conversationID,
            turnSequence: transitioned.turnSequence, inferenceTurnID: transitioned.inferenceTurnID,
            isLegacy: transitioned.isLegacy, intentID: transitioned.intentID, userGoal: transitioned.userGoal,
            status: transitioned.status, promptText: transitioned.promptText, answerText: transitioned.answerText,
            transcriptText: transitioned.transcriptText, contextDigest: transitioned.contextDigest,
            canonicalByteCount: transitioned.canonicalByteCount, providerToolCount: transitioned.providerToolCount,
            recordSchemaVersion: transitioned.recordSchemaVersion, createdAt: transitioned.createdAt,
            completedAt: transitioned.completedAt, continuationCheckpoint: transitioned.continuationCheckpoint
        )
        XCTAssertTrue(try db.transitionPhase2AssistantSessionRecord(
            id: record.id, expectedStatus: .outcomeUnknown,
            expectedLogicalState: "awaitingShellContinuation", to: transitioned
        ))
        XCTAssertFalse(try db.transitionPhase2AssistantSessionRecord(
            id: record.id, expectedStatus: .outcomeUnknown,
            expectedLogicalState: "awaitingShellContinuation", to: transitioned
        ))
    }

    // MARK: - BUG-001: persistence must not page assistant history

    /// Builds `count` sequential assistant records with deterministic identifiers.
    private func assistantHistoryFixture(
        count: Int,
        workspaceID: Int64,
        workspaceUUID: UUID,
        documentID: UUID
    ) -> [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord] {
        (1...count).map { sequence in
            phase2AssistantSessionRecord(
                id: UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", sequence))!,
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID,
                documentID: documentID,
                sequence: sequence,
                status: .completed,
                answerText: "answer \(sequence)",
                createdAt: Date(timeIntervalSince1970: 9_000 + TimeInterval(sequence))
            )
        }
    }

    func testAssistantSessionDurableRoundTripPreservesHistoryBeyondPagedDefault() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceName: "Assistant history depth",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 9_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let records = assistantHistoryFixture(
            count: 53,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: UUID(uuidString: "20000000-0000-0000-0000-000000000040")!
        )
        for record in records {
            try db.upsertPhase2AssistantSessionRecord(record)
        }

        // The reopen path must see every row, not the newest paged window.
        let reloaded = try XCTUnwrap(db.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.assistantSessionRecords.count, 53)

        // Reopen-then-save is delete-then-reinsert; a paged read here is what
        // silently destroyed rows 51+ before the dedicated persistence query.
        try db.replacePhase2AssistantSessionRecords(
            workspaceID: workspaceID,
            records: reloaded.assistantSessionRecords
        )
        let survivors = try db.allPhase2AssistantSessionRecords(workspaceID: workspaceID)
        XCTAssertEqual(survivors.count, 53)
        XCTAssertTrue(survivors.contains { $0.id == records.first!.id }, "oldest record must survive")
        XCTAssertTrue(survivors.contains { $0.id == records.last!.id }, "newest record must survive")

        // Control: the paged UI query keeps its default and honors explicit limits.
        XCTAssertEqual(try db.phase2AssistantSessionRecords(workspaceID: workspaceID).count, 50)
        let page = try db.phase2AssistantSessionRecords(workspaceID: workspaceID, limit: 7)
        XCTAssertEqual(page.count, 7)
        XCTAssertEqual(page.first?.id, records.last!.id)
    }

    func testPackageRoundTripPreservesHistoryBeyondPagedDefault() throws {
        let sourceDB = try WorkspaceDatabase.inMemory()
        try sourceDB.applySchema()
        let workspace = try sourceDB.saveSnapshot(
            workspaceName: "Assistant package depth",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            now: Date(timeIntervalSince1970: 9_500)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000041")!
        let records = assistantHistoryFixture(
            count: 53,
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid,
            documentID: documentID
        )
        for record in records.shuffled() {
            try sourceDB.upsertPhase2AssistantSessionRecord(record)
        }

        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let manifest = try sourceDB.writePackage(
            workspaceID: workspaceID,
            documentID: documentID,
            to: packageURL
        )

        XCTAssertEqual(manifest.assistantSessionRecords.count, 53)
        XCTAssertEqual(
            manifest.assistantSessionRecords.map(\.sequence),
            Array(1...53),
            "package ordering must be deterministic and complete"
        )

        let importedDB = try WorkspaceDatabase.inMemory()
        try importedDB.applySchema()
        let imported = try importedDB.importPackage(from: packageURL)
        let importedWorkspaceID = try XCTUnwrap(imported.workspace.id)
        let importedRecords = try importedDB.allPhase2AssistantSessionRecords(workspaceID: importedWorkspaceID)
        XCTAssertEqual(importedRecords.count, 53)
        XCTAssertTrue(importedRecords.contains { $0.id == records.first!.id })
        XCTAssertTrue(importedRecords.contains { $0.id == records.last!.id })
    }

    // MARK: - BUG-002: direct-entry migrations 31–34 must be atomic

    private func assertMigrationRollback(
        _ db: WorkspaceDatabase,
        stays version: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(try db.applySchema(), file: file, line: line) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError else {
                return XCTFail("expected DatabaseError, got \(error)", file: file, line: line)
            }
            if case .migrationRollbackFailed = databaseError {
                XCTFail("savepoint rollback itself failed: \(databaseError)", file: file, line: line)
            }
        }
        XCTAssertEqual(try db.userVersion(), version, file: file, line: line)
    }

    func testMigrationV31RollsBackAtomicallyWhenIndexCreationFails() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        // A v31 database with a nonstandard assistant table: the v1 table CREATE
        // is skipped (IF NOT EXISTS), the first index creation succeeds — the
        // schema mutation — and the second fails on the missing created_at column.
        try db.executeRawForTesting("""
            DROP TABLE phase2_assistant_session_records;
            CREATE TABLE phase2_assistant_session_records (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER NOT NULL,
              sequence INTEGER NOT NULL
            );
            INSERT INTO phase2_assistant_session_records (id, workspace_id, sequence)
            VALUES ('fixture-row', 7, 1);
            """)
        try db.setUserVersionForTesting(31)

        try assertMigrationRollback(db, stays: 31)
        XCTAssertEqual(
            try db.scalarIntForTesting(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_phase2_assistant_sessions_workspace_sequence';"
            ),
            0,
            "the partially created index must have been rolled back"
        )
        XCTAssertEqual(
            try db.scalarIntForTesting(
                "SELECT COUNT(*) FROM phase2_assistant_session_records WHERE id = 'fixture-row';"
            ),
            1
        )

        // Removing the injected cause lets an unmodified applySchema complete.
        try db.executeRawForTesting("DROP TABLE phase2_assistant_session_records;")
        try db.applySchema()
        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
    }

    func testMigrationV32RebuildRollsBackWhenARowViolatesRebuildConstraints() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        // A v32-era table shape (no CHECK constraints, so the poison row can
        // exist) with one well-formed row and one row whose schema version
        // violates the rebuilt table's CHECK — the failure lands mid-rebuild,
        // after the rename, drops, and create have already mutated the schema.
        try db.executeRawForTesting("""
            DROP TABLE phase2_assistant_session_records;
            CREATE TABLE phase2_assistant_session_records (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER NOT NULL,
              workspace_uuid TEXT NOT NULL,
              document_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              intent_id TEXT NOT NULL,
              user_goal TEXT NOT NULL,
              status TEXT NOT NULL,
              prompt_text TEXT NOT NULL,
              answer_text TEXT,
              transcript_text TEXT NOT NULL,
              context_digest TEXT,
              canonical_byte_count INTEGER,
              provider_tool_count INTEGER NOT NULL DEFAULT 0,
              record_schema_version INTEGER NOT NULL,
              created_at TEXT NOT NULL,
              completed_at TEXT,
              content_sha256 TEXT NOT NULL
            );
            CREATE UNIQUE INDEX idx_phase2_assistant_sessions_workspace_sequence
              ON phase2_assistant_session_records(workspace_id, sequence);
            INSERT INTO phase2_assistant_session_records (
              id, workspace_id, workspace_uuid, document_id, sequence, intent_id,
              user_goal, status, prompt_text, transcript_text,
              record_schema_version, created_at, content_sha256
            ) VALUES
              ('good-row', 7, 'u', 'd', 1, 'i', 'g', 'completed', 'p', 't', 1, 'now', 'sha'),
              ('poison-row', 7, 'u', 'd', 2, 'i', 'g', 'completed', 'p', 't', 2, 'now', 'sha');
            """)
        try db.setUserVersionForTesting(32)

        try assertMigrationRollback(db, stays: 32)
        XCTAssertFalse(try db.tableNames().contains("phase2_assistant_session_records_v32"),
                       "the rename must have been rolled back")
        XCTAssertEqual(
            try db.scalarIntForTesting("SELECT COUNT(*) FROM phase2_assistant_session_records;"),
            2,
            "both fixture rows must survive the rolled-back rebuild"
        )

        // Removing the injected cause lets an unmodified applySchema complete.
        try db.executeRawForTesting("DELETE FROM phase2_assistant_session_records;")
        try db.applySchema()
        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
    }

    /// Downgrades the assistant table to an empty v1 (18-column) shape so a
    /// fixture entering the chain at 33/34 reaches `migrateVersion35To36` on
    /// its legacy-rebuild path; leaving the current v3 table in place trips
    /// that migration's v2 forward-convergence validation instead.
    private func downgradeAssistantTableToV1Shape(_ db: WorkspaceDatabase) throws {
        try db.executeRawForTesting("""
            DROP TABLE phase2_assistant_session_records;
            CREATE TABLE phase2_assistant_session_records (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER NOT NULL,
              workspace_uuid TEXT NOT NULL,
              document_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              intent_id TEXT NOT NULL,
              user_goal TEXT NOT NULL,
              status TEXT NOT NULL,
              prompt_text TEXT NOT NULL,
              answer_text TEXT,
              transcript_text TEXT NOT NULL,
              context_digest TEXT,
              canonical_byte_count INTEGER,
              provider_tool_count INTEGER NOT NULL DEFAULT 0,
              record_schema_version INTEGER NOT NULL,
              created_at TEXT NOT NULL,
              completed_at TEXT,
              content_sha256 TEXT NOT NULL
            );
            """)
    }

    func testMigrationV33RollsBackWhenRuntimeAuthorityIndexNameIsOccupied() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        // The runtime-authority table CREATE succeeds — the schema mutation —
        // and the index creation then fails because a table occupies its name.
        try downgradeAssistantTableToV1Shape(db)
        try db.executeRawForTesting("""
            DROP TABLE phase2_runtime_authority_records;
            CREATE TABLE idx_phase2_runtime_authority_workspace_created (x INTEGER);
            """)
        try db.setUserVersionForTesting(33)

        try assertMigrationRollback(db, stays: 33)
        XCTAssertFalse(try db.tableNames().contains("phase2_runtime_authority_records"),
                       "the partially created table must have been rolled back")

        try db.executeRawForTesting("DROP TABLE idx_phase2_runtime_authority_workspace_created;")
        try db.applySchema()
        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try db.tableNames().contains("phase2_runtime_authority_records"))
    }

    func testMigrationV34CompletesAtomicallyFromDirectEntry() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        // This migration is a single `CREATE TABLE IF NOT EXISTS` plus the
        // version stamp, and SQLite's IF NOT EXISTS suppresses even cross-kind
        // name collisions (verified empirically with an occupying view), so no
        // mid-body failure can be injected here at all. Direct entry at v34 —
        // previously uncovered — is exercised on its success path; the
        // stamp-coupling atomicity is inherited from the shared savepoint
        // helper proven by the v31–v33 failure cases above.
        try downgradeAssistantTableToV1Shape(db)
        try db.executeRawForTesting("DROP TABLE phase2_shell_sessions;")
        try db.setUserVersionForTesting(34)

        try db.applySchema()
        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try db.tableNames().contains("phase2_shell_sessions"))
        XCTAssertTrue(try db.tableNames().contains("phase2_assistant_session_records"))
    }

    private func phase2AssistantSessionRecord(
        id: UUID,
        workspaceID: Int64,
        workspaceUUID: UUID,
        documentID: UUID,
        sequence: Int,
        status: WorkspaceDatabase.Phase2AssistantPersistedSessionStatus,
        answerText: String?,
        createdAt: Date
    ) -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord {
        WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
            id: id,
            workspaceID: workspaceID,
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sequence: sequence,
            intentID: "assistant.ask_macscope",
            userGoal: "Summarize the current workspace.",
            status: status,
            promptText: "Prompt text",
            answerText: answerText,
            transcriptText: "MacScope Assistant Session Entry",
            contextDigest: String(repeating: "a", count: 64),
            canonicalByteCount: 128,
            createdAt: createdAt,
            completedAt: createdAt.addingTimeInterval(1)
        )
    }

    private func workspacePackagePhase2ShellSession(
        sessionID: UUID,
        requestID: UUID,
        processIdentifier: Int32,
        columns: Int,
        rows: Int
    ) -> WorkspacePackagePhase2ShellSession {
        WorkspacePackagePhase2ShellSession(
            sessionID: sessionID,
            launchPlan: WorkspacePackagePhase2ShellLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                arguments: ["-l"],
                environment: ["TERM": "xterm-256color"],
                workingDirectoryPath: "/tmp",
                columns: columns,
                rows: rows,
                transcriptMaximumEvents: 128,
                transcriptMaximumEventBytes: 4_096,
                transcriptMaximumCumulativeBytes: 65_536
            ),
            terminalOutcome: .outcomeUnknown,
            transcriptEvents: [
                WorkspacePackagePhase2ShellTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: Phase2HumanPTYEventSource.human.rawValue,
                    payload: .input(Data("pwd\n".utf8))
                ),
            ],
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .shellBrokerSession,
            debuggerAuthorityPolicy: .disabled,
            runningRequestID: requestID,
            runningProcessIdentifier: processIdentifier,
            nextTranscriptSequence: 2
        )
    }

    // WS-5: reopening a workspace must restore dSYM source lines, so they are persisted in a new
    // per-binary_id table added by schema v28. Migration jumps to the current schema through
    // ensureImageAwareSchema, matching every prior version bump.
    func testMigrationV27ToCurrentAddsSourceLinesTable() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        // Simulate a pre-v28 database: remove the table and stamp v27.
        try db.executeRawForTesting("DROP TABLE IF EXISTS source_lines;")
        try db.setUserVersionForTesting(27)

        XCTAssertNoThrow(try db.applySchema())        // migrates v27 directly to current
        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try db.tableNames().contains("source_lines"))
        XCTAssertEqual(
            try db.columnNames(in: "source_lines"),
            Self.currentSourceLineColumns
        )
        // Idempotent: re-applying at current version is a no-op that still leaves the table.
        XCTAssertNoThrow(try db.applySchema())
        XCTAssertTrue(try db.tableNames().contains("source_lines"))
    }

    func testSourceLinesSortDecodedAddressesUnsignedAndPreserveEqualAddressInsertionOrder() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()

        let lowerBoundaryAddress: UInt64 = 0x7fff_ffff_ffff_fff0
        let upperBoundaryAddress: UInt64 = 0x8000_0000_0000_0010
        let highestAddress: UInt64 = 0xffff_ffff_ffff_fff0
        var analysis = ImageAnalysis()
        analysis.sourceLines = [
            SourceLineEntry(address: highestAddress, file: "/src/highest.c", line: 50, column: 1, endSequence: false),
            SourceLineEntry(address: upperBoundaryAddress, file: "/src/upper-first.c", line: 30, column: 1, endSequence: false),
            SourceLineEntry(address: lowerBoundaryAddress, file: "/src/lower.c", line: 10, column: 1, endSequence: false),
            SourceLineEntry(address: upperBoundaryAddress, file: "/src/upper-second.c", line: 40, column: 1, endSequence: false),
        ]
        let workspace = try db.saveSnapshot(
            workspaceName: "Unsigned source line addresses",
            snapshot: WorkspaceSnapshot(
                binaries: [
                    BinaryImage(
                        id: UUID(),
                        name: "unsigned-source-lines",
                        path: "/tmp/unsigned-source-lines",
                        kind: "Mach-O executable",
                        architecture: "arm64",
                        slot: .primary
                    )
                ],
                analysisBySlot: [.primary: analysis]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let binaryID = try XCTUnwrap(try db.binaries(workspaceID: workspaceID).first?.id)

        let sourceLines = try db.sourceLines(binaryID: binaryID)
        XCTAssertEqual(sourceLines.map(\.address), [
            lowerBoundaryAddress,
            upperBoundaryAddress,
            upperBoundaryAddress,
            highestAddress,
        ])
        XCTAssertEqual(sourceLines.map(\.file), [
            "/src/lower.c",
            "/src/upper-first.c",
            "/src/upper-second.c",
            "/src/highest.c",
        ])

        let reloaded = try XCTUnwrap(try db.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.sourceLine(at: lowerBoundaryAddress)?.file, "/src/lower.c")
        XCTAssertEqual(reloaded.sourceLine(at: upperBoundaryAddress)?.file, "/src/upper-second.c")
        XCTAssertEqual(reloaded.sourceLine(at: highestAddress)?.file, "/src/highest.c")
    }

    func testMigrationV28RepairsWorkspaceScopedSourceLinesWithoutLosingRows() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()

        let legacyBinary = BinaryImage(
            id: UUID(),
            name: "legacy-source-lines",
            path: "/tmp/legacy-source-lines",
            kind: "Mach-O executable",
            architecture: "arm64",
            slot: .primary
        )
        let legacyWorkspace = try db.saveSnapshot(
            workspaceName: "Legacy source lines",
            snapshot: WorkspaceSnapshot(
                binaries: [legacyBinary],
                analysisBySlot: [.primary: ImageAnalysis()]
            )
        )
        let workspaceID = try XCTUnwrap(legacyWorkspace.id)
        let binaryID = try XCTUnwrap(try db.binaries(workspaceID: workspaceID).first?.id)

        // Reproduce the source_lines shape emitted by the original v27 -> v28
        // convergence path. Its required workspace_id was absent from every
        // production insert, so a current-version no-op could not save dSYM rows.
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE SOURCE_LINES (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              file TEXT,
              line INTEGER NOT NULL,
              column INTEGER NOT NULL,
              is_end_sequence INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX idx_source_lines_binary_id ON source_lines(binary_id);
            INSERT INTO source_lines (
              workspace_id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              \(workspaceID), \(binaryID), 4096, '/src/legacy.c', 42, 3, 0
            );
            """)
        try db.setUserVersionForTesting(28)

        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try db.columnNames(in: "source_lines"),
            Self.currentSourceLineColumns
        )
        XCTAssertEqual(
            try db.sourceLines(binaryID: binaryID),
            [SourceLineEntry(address: 0x1000, file: "/src/legacy.c", line: 42, column: 3, endSequence: false)]
        )
        try db.executeRawForTesting("DELETE FROM binaries WHERE id = \(binaryID);")
        XCTAssertTrue(try db.sourceLines(binaryID: binaryID).isEmpty)

        var repairedAnalysis = ImageAnalysis()
        repairedAnalysis.sourceLines = [
            SourceLineEntry(address: 0x2000, file: "/src/repaired.c", line: 7, column: 1, endSequence: true)
        ]
        let repairedWorkspace = try db.saveSnapshot(
            workspaceName: "Repaired source lines",
            snapshot: WorkspaceSnapshot(
                binaries: [
                    BinaryImage(
                        id: UUID(),
                        name: "repaired-source-lines",
                        path: "/tmp/repaired-source-lines",
                        kind: "Mach-O executable",
                        architecture: "arm64",
                        slot: .primary
                    )
                ],
                analysisBySlot: [.primary: repairedAnalysis]
            )
        )
        let reloaded = try XCTUnwrap(
            try db.loadSnapshot(workspaceID: try XCTUnwrap(repairedWorkspace.id))
        )
        XCTAssertEqual(reloaded.analysis(in: .primary)?.sourceLines, repairedAnalysis.sourceLines)
    }

    func testMigrationV28RebuildsCanonicalNamedSourceLinesWithMissingConstraints() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()

        let workspace = try db.saveSnapshot(
            workspaceName: "Malformed canonical source lines",
            snapshot: WorkspaceSnapshot(
                binaries: [
                    BinaryImage(
                        id: UUID(),
                        name: "malformed-source-lines",
                        path: "/tmp/malformed-source-lines",
                        kind: "Mach-O executable",
                        architecture: "arm64",
                        slot: .primary
                    )
                ],
                analysisBySlot: [.primary: ImageAnalysis()]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let binaryID = try XCTUnwrap(try db.binaries(workspaceID: workspaceID).first?.id)

        // Column names alone are not a schema contract. Reproduce an exact-name
        // v28 table with no NOT NULL/default/FK constraints and a wrong same-name
        // index; migration must rebuild it instead of blessing it as current.
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER,
              address INTEGER,
              file TEXT,
              line INTEGER,
              column INTEGER,
              is_end_sequence INTEGER
            );
            CREATE INDEX idx_source_lines_binary_id ON source_lines(address);
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              41, \(binaryID), 12288, '/src/malformed.c', 9, 2, 1
            ), (
              99, \(binaryID), 12292, NULL, 10, 0, 0
            );
            """)
        try db.setUserVersionForTesting(28)

        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(try db.indexColumns(of: "idx_source_lines_binary_id"), ["binary_id"])
        XCTAssertEqual(
            try db.sourceLines(binaryID: binaryID),
            [
                SourceLineEntry(address: 0x3000, file: "/src/malformed.c", line: 9, column: 2, endSequence: true),
                SourceLineEntry(address: 0x3004, file: nil, line: 10, column: 0, endSequence: false),
            ]
        )
        try db.executeRawForTesting("DELETE FROM source_lines WHERE id = 41;")
        XCTAssertEqual(
            try db.sourceLines(binaryID: binaryID),
            [SourceLineEntry(address: 0x3004, file: nil, line: 10, column: 0, endSequence: false)]
        )
        XCTAssertNoThrow(try db.applySchema())
        XCTAssertEqual(try db.indexColumns(of: "idx_source_lines_binary_id"), ["binary_id"])
        try db.executeRawForTesting("DELETE FROM binaries WHERE id = \(binaryID);")
        XCTAssertTrue(try db.sourceLines(binaryID: binaryID).isEmpty)
    }

    func testMigrationV28CreatesMissingSourceLinesTableAndIndex() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("DROP TABLE source_lines;")
        try db.setUserVersionForTesting(28)

        try db.applySchema()

        XCTAssertEqual(try db.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try db.columnNames(in: "source_lines"),
            Self.currentSourceLineColumns
        )
        XCTAssertEqual(try db.indexColumns(of: "idx_source_lines_binary_id"), ["binary_id"])
        XCTAssertNoThrow(try db.applySchema())
    }

    func testMigrationV28RollsBackKnownShapeWhenCanonicalCopyFails() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER,
              address INTEGER,
              file TEXT,
              line INTEGER,
              column INTEGER,
              is_end_sequence INTEGER
            );
            CREATE INDEX idx_source_lines_binary_id ON source_lines(binary_id);
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              71, 999999, 16384, '/src/orphan.c', 12, 4, 1
            );
            """)
        try db.setUserVersionForTesting(28)

        XCTAssertThrowsError(try db.applySchema()) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError,
                  case .stepFailed = databaseError else {
                return XCTFail("expected SQLite FK failure, got \(error)")
            }
        }

        XCTAssertEqual(try db.userVersion(), 28)
        XCTAssertFalse(try db.tableNames().contains("source_lines_v29"))
        XCTAssertEqual(
            try db.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM source_lines
                WHERE id = 71 AND binary_id = 999999 AND address = 16384
                  AND file = '/src/orphan.c' AND line = 12 AND column = 4
                  AND is_end_sequence = 1;
                """
            ),
            1
        )
    }

    func testMigrationV28RejectsUnknownDependenciesBeforeRebuild() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()

        var analysis = ImageAnalysis()
        analysis.sourceLines = [
            SourceLineEntry(address: 0x4800, file: "/src/dependent.c", line: 13, column: 5, endSequence: false)
        ]
        let workspace = try db.saveSnapshot(
            workspaceName: "Dependent source lines",
            snapshot: WorkspaceSnapshot(
                binaries: [
                    BinaryImage(
                        id: UUID(),
                        name: "dependent-source-lines",
                        path: "/tmp/dependent-source-lines",
                        kind: "Mach-O executable",
                        architecture: "arm64",
                        slot: .primary
                    )
                ],
                analysisBySlot: [.primary: analysis]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let binaryID = try XCTUnwrap(try db.binaries(workspaceID: workspaceID).first?.id)
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              file TEXT,
              line INTEGER NOT NULL,
              column INTEGER NOT NULL,
              is_end_sequence INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              1, \(binaryID), 18432, '/src/dependent.c', 13, 5, 0
            );
            CREATE TABLE source_line_audit (source_line_id INTEGER NOT NULL);
            CREATE TABLE source_line_notes (
              source_line_id INTEGER NOT NULL REFERENCES SOURCE_LINES(id) ON DELETE CASCADE
            );
            INSERT INTO source_line_notes (source_line_id)
            SELECT id FROM source_lines LIMIT 1;
            CREATE INDEX custom_source_line_file_idx ON SOURCE_LINES(file);
            CREATE VIEW source_line_files AS SELECT file FROM source_lines;
            CREATE TRIGGER source_lines_audit_trigger
            AFTER INSERT ON SOURCE_LINES
            BEGIN
              INSERT INTO source_line_audit (source_line_id) VALUES (NEW.id);
            END;
            """)
        try db.setUserVersionForTesting(28)

        XCTAssertThrowsError(try db.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .incompatibleSourceLinesDependencies(
                    objects: [
                        "foreign-key:source_line_notes",
                        "index:custom_source_line_file_idx",
                        "trigger:source_lines_audit_trigger",
                        "view:source_line_files",
                    ]
                )
            )
        }

        XCTAssertEqual(try db.userVersion(), 28)
        XCTAssertFalse(try db.tableNames().contains("source_lines_v29"))
        XCTAssertEqual(
            try db.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM source_lines
                WHERE binary_id = \(binaryID) AND address = 18432
                  AND file = '/src/dependent.c' AND line = 13 AND column = 5
                  AND is_end_sequence = 0;
                """
            ),
            1
        )
    }

    func testMigrationV28RejectsNullSourceLineIDRatherThanRenumberingRow() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER,
              binary_id INTEGER,
              address INTEGER,
              file TEXT,
              line INTEGER,
              column INTEGER,
              is_end_sequence INTEGER
            );
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              NULL, 654321, 18944, '/src/null-id.c', 15, 7, 0
            );
            """)
        try db.setUserVersionForTesting(28)

        XCTAssertThrowsError(try db.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .incompatibleSourceLinesData(reasons: ["null-id"])
            )
        }

        XCTAssertEqual(try db.userVersion(), 28)
        XCTAssertFalse(try db.tableNames().contains("source_lines_v29"))
        XCTAssertEqual(
            try db.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM source_lines
                WHERE id IS NULL AND binary_id = 654321 AND address = 18944
                  AND file = '/src/null-id.c' AND line = 15 AND column = 7
                  AND is_end_sequence = 0;
                """
            ),
            1
        )
    }

    func testMigrationV28RejectsTextSourceLineIDRatherThanCoercingIdentity() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceName: "Text source-line identity",
            snapshot: AnalysisEngine.previewSnapshot()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let binaryID = try XCTUnwrap(try db.binaries(workspaceID: workspaceID).first?.id)
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id TEXT,
              binary_id INTEGER,
              address INTEGER,
              file TEXT,
              line INTEGER,
              column INTEGER,
              is_end_sequence INTEGER
            );
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              '001', \(binaryID), 19200, '/src/text-id.c', 16, 8, 0
            );
            """)
        try db.setUserVersionForTesting(28)

        XCTAssertThrowsError(try db.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .incompatibleSourceLinesData(reasons: ["non-integer-id"])
            )
        }

        XCTAssertEqual(try db.userVersion(), 28)
        XCTAssertFalse(try db.tableNames().contains("source_lines_v29"))
        XCTAssertEqual(
            try db.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM source_lines
                WHERE typeof(id) = 'text' AND id = '001' AND binary_id = \(binaryID)
                  AND address = 19200 AND file = '/src/text-id.c'
                  AND line = 16 AND column = 8 AND is_end_sequence = 0;
                """
            ),
            1
        )
    }

    func testMigrationV28RejectsGeneratedSourceLineColumnWithoutDroppingSchema() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        let workspace = try db.saveSnapshot(
            workspaceName: "Generated source-line column",
            snapshot: AnalysisEngine.previewSnapshot()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let binaryID = try XCTUnwrap(try db.binaries(workspaceID: workspaceID).first?.id)
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER,
              address INTEGER,
              file TEXT,
              line INTEGER,
              column INTEGER,
              is_end_sequence INTEGER,
              derived_file TEXT GENERATED ALWAYS AS (coalesce(file, '')) VIRTUAL
            );
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence
            ) VALUES (
              81, \(binaryID), 19456, '/src/generated.c', 17, 9, 1
            );
            """)
        try db.setUserVersionForTesting(28)

        XCTAssertThrowsError(try db.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .incompatibleSourceLinesSchema(
                    columns: [
                        "id", "binary_id", "address", "file", "line", "column",
                        "is_end_sequence", "derived_file",
                    ]
                )
            )
        }

        XCTAssertEqual(try db.userVersion(), 28)
        XCTAssertFalse(try db.tableNames().contains("source_lines_v29"))
        XCTAssertNoThrow(try db.executeRawForTesting("SELECT derived_file FROM source_lines;"))
        XCTAssertEqual(
            try db.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM source_lines
                WHERE id = 81 AND binary_id = \(binaryID) AND address = 19456
                  AND file = '/src/generated.c' AND derived_file = '/src/generated.c'
                  AND line = 17 AND column = 9 AND is_end_sequence = 1;
                """
            ),
            1
        )
    }

    func testMigrationV28RejectsUnknownSourceLinesShapeWithoutAdvancingVersion() throws {
        let db = try WorkspaceDatabase.inMemory()
        try db.applySchema()
        try db.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER NOT NULL,
              address INTEGER NOT NULL,
              file TEXT,
              line INTEGER NOT NULL,
              column INTEGER NOT NULL,
              is_end_sequence INTEGER NOT NULL DEFAULT 0,
              unexpected_payload BLOB
            );
            INSERT INTO source_lines (
              id, binary_id, address, file, line, column, is_end_sequence, unexpected_payload
            ) VALUES (
              73, 123456, 20480, '/src/sentinel.c', 14, 6, 0, X'CAFE'
            );
            """)
        try db.setUserVersionForTesting(28)

        XCTAssertThrowsError(try db.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .incompatibleSourceLinesSchema(
                    columns: [
                        "id", "binary_id", "address", "file", "line", "column",
                        "is_end_sequence", "unexpected_payload",
                    ]
                )
            )
        }
        XCTAssertEqual(try db.userVersion(), 28)
        XCTAssertEqual(
            try db.columnNames(in: "source_lines"),
            [
                "id", "binary_id", "address", "file", "line", "column",
                "is_end_sequence", "unexpected_payload",
            ]
        )
        XCTAssertEqual(
            try db.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM source_lines
                WHERE id = 73 AND binary_id = 123456 AND address = 20480
                  AND file = '/src/sentinel.c' AND line = 14 AND column = 6
                  AND is_end_sequence = 0 AND unexpected_payload = X'CAFE';
                """
            ),
            1
        )
    }

    func testAppliesSchemaToInMemoryDatabase() throws {
        let database = try WorkspaceDatabase.inMemory()

        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try database.tableNames(),
            // 57d34f431 added imported_function_prototypes (per-image header prototypes); schema list updated.
            [
                "address_overrides",
                "basic_blocks",
                "binaries",
                "bookmarks",
                "constant_cfstrings",
                "control_flow_edges",
                "exports",
                "functions",
                "imported_function_prototypes",
                "imports",
                "indirect_symbols",
                "instructions",
                "launch_profile_catalogs",
                "logical_breakpoint_catalogs",
                "logical_breakpoints",
                "manual_xrefs",
                "phase2_assistant_session_records",
                "phase2_runtime_authority_records",
                "phase2_shell_sessions",
                "plugin_external_runs",
                "plugin_trust_decisions",
                "reconstruction_artifact_contents",
                "reconstruction_artifact_occurrences",
                "reconstruction_artifact_relations",
                "reconstruction_artifact_roles",
                "reconstruction_checkpoint_tasks",
                "reconstruction_checkpoints",
                "reconstruction_evidence",
                "reconstruction_evidence_citations",
                "reconstruction_evidence_relations",
                "reconstruction_final_results",
                "reconstruction_jobs",
                "reconstruction_model_receipts",
                "reconstruction_projects",
                "reconstruction_tasks",
                "reconstruction_tool_receipts",
                "saved_watch_catalogs",
                "segment_overrides",
                "source_lines",
                "source_link_states",
                "string_literals",
                "symbols",
                "type_definitions",
                "workspace_document_autosave_decisions",
                "workspace_documents",
                "workspace_sessions",
                "workspaces",
                "xrefs"
            ]
        )
        XCTAssertEqual(
            try database.columnNames(in: "symbols"),
            ["id", "uuid", "binary_id", "name", "address", "kind", "library_name", "raw_linkage_name"]
        )
        XCTAssertEqual(
            try database.columnNames(in: "source_lines"),
            [
                "id", "binary_id", "address", "file", "line", "column", "is_end_sequence",
                "debug_artifact_uuid", "debug_artifact_macho_sha256",
                "debug_artifact_macho_byte_count", "line_program_unit_offset",
                "file_table_index", "table_path_kind", "table_path",
            ]
        )
    }

    func testApplySchemaIsIdempotentForCurrentFileBackedDatabase() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            try database.applySchema()
            XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
            XCTAssertTrue(try database.tableNames().contains("workspaces"))
        }

        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        try reopened.applySchema()
        XCTAssertEqual(try reopened.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try reopened.tableNames().contains("workspace_sessions"))
    }

    func testApplySchemaConvergesEmptyVersionSevenDatabase() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let staleVersion = 7
        try writeSQLiteUserVersion(staleVersion, to: databaseURL)

        let database = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertNoThrow(try database.applySchema())
        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try database.tableNames().contains("logical_breakpoint_catalogs"))
    }

    func testApplySchemaMigratesVersion8DatabaseByAddingWorkspaceDocuments() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_workspace_document_autosave_decisions_workspace_id;
            DROP INDEX IF EXISTS idx_workspace_document_autosave_decisions_decided_at;
            DROP TABLE IF EXISTS workspace_document_autosave_decisions;
            DROP INDEX IF EXISTS idx_workspace_documents_last_opened_at;
            DROP TABLE IF EXISTS workspace_documents;
            PRAGMA user_version = 8;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("workspace_documents"))
        XCTAssertTrue(try migrated.tableNames().contains("workspace_document_autosave_decisions"))

        let workspace = try migrated.saveSnapshot(
            workspaceName: "Migrated Documents",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let document = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: workspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            packagePath: "/tmp/Migrated.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_120),
            lastSavedAt: nil,
            isDirty: false
        )

        XCTAssertEqual(try migrated.upsertWorkspaceDocument(document), document)
        let migratedDocument = try XCTUnwrap(migrated.workspaceDocument(workspaceID: workspaceID))
        XCTAssertEqual(migratedDocument, document)
        XCTAssertEqual(migratedDocument.inputCopyingDecision, .copyInputsIntoPackage)
        XCTAssertEqual(migratedDocument.bookmarkResolutionDecision, .resolveStoredBookmarks)
        XCTAssertNil(migratedDocument.bookmarkResolutionError)
        XCTAssertEqual(migratedDocument.recentDocumentState, .available)
        XCTAssertNil(migratedDocument.recentDocumentStateUpdatedAt)
    }

    func testApplySchemaMigratesVersion9WorkspaceDocumentsWithLifecycleMetadata() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_workspace_document_autosave_decisions_workspace_id;
            DROP INDEX IF EXISTS idx_workspace_document_autosave_decisions_decided_at;
            DROP TABLE IF EXISTS workspace_document_autosave_decisions;
            DROP INDEX IF EXISTS idx_workspace_documents_conflict_detected_at;
            DROP INDEX IF EXISTS idx_workspace_documents_last_opened_at;
            DROP TABLE IF EXISTS workspace_documents;
            CREATE TABLE workspace_documents (
              workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
              document_id TEXT NOT NULL,
              package_path TEXT NOT NULL,
              last_opened_at TEXT NOT NULL,
              last_saved_at TEXT,
              is_dirty INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_workspace_documents_last_opened_at ON workspace_documents(last_opened_at DESC);
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
            VALUES (
              1,
              '11111111-1111-1111-1111-111111111111',
              'Version 9 Workspace',
              '2027-01-15T08:00:00.000Z',
              '2027-01-15T08:05:00.000Z'
            );
            INSERT INTO workspace_documents (
              workspace_id,
              document_id,
              package_path,
              last_opened_at,
              last_saved_at,
              is_dirty
            )
            VALUES (
              1,
              'dddddddd-dddd-dddd-dddd-dddddddddddd',
              '/tmp/Version9.mscope',
              '2027-01-15T08:10:00.000Z',
              '2027-01-15T08:05:00.000Z',
              0
            );
            PRAGMA user_version = 9;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("workspace_document_autosave_decisions"))
        let document = try XCTUnwrap(migrated.workspaceDocument(workspaceID: 1))
        XCTAssertEqual(document.documentID, UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)
        XCTAssertEqual(document.packagePath, "/tmp/Version9.mscope")
        XCTAssertFalse(document.isDirty)
        XCTAssertNil(document.fileVersionIdentifier)
        XCTAssertNil(document.conflictDetectedAt)
        XCTAssertNil(document.conflictReason)
        XCTAssertEqual(document.inputCopyingDecision, .copyInputsIntoPackage)
        XCTAssertEqual(document.bookmarkResolutionDecision, .resolveStoredBookmarks)
        XCTAssertNil(document.bookmarkResolutionError)
        XCTAssertEqual(document.recentDocumentState, .available)
        XCTAssertNil(document.recentDocumentStateUpdatedAt)

        let conflictAt = Date(timeIntervalSince1970: 1_800_000_240)
        let dirtyDocument = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: 1,
            documentID: document.documentID,
            packagePath: document.packagePath,
            lastOpenedAt: document.lastOpenedAt,
            lastSavedAt: document.lastSavedAt,
            isDirty: true,
            fileVersionIdentifier: "version-9-upgraded",
            conflictDetectedAt: conflictAt,
            conflictReason: "Package changed on disk after the workspace was opened."
        )

        XCTAssertEqual(try migrated.upsertWorkspaceDocument(dirtyDocument), dirtyDocument)
        XCTAssertEqual(try migrated.workspaceDocument(workspaceID: 1), dirtyDocument)
    }

    func testApplySchemaMigratesVersion11WorkspaceDocumentsWithInputAndRecentState() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_workspace_documents_recent_document_state;
            DROP INDEX IF EXISTS idx_workspace_documents_conflict_detected_at;
            DROP INDEX IF EXISTS idx_workspace_documents_last_opened_at;
            DROP TABLE IF EXISTS workspace_documents;
            CREATE TABLE workspace_documents (
              workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
              document_id TEXT NOT NULL,
              package_path TEXT NOT NULL,
              last_opened_at TEXT NOT NULL,
              last_saved_at TEXT,
              is_dirty INTEGER NOT NULL DEFAULT 0,
              file_version_identifier TEXT,
              conflict_detected_at TEXT,
              conflict_reason TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_workspace_documents_last_opened_at ON workspace_documents(last_opened_at DESC);
            CREATE INDEX IF NOT EXISTS idx_workspace_documents_conflict_detected_at ON workspace_documents(conflict_detected_at DESC);
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
            VALUES (
              1,
              '11111111-1111-1111-1111-111111111111',
              'Version 11 Workspace',
              '2027-01-15T08:00:00.000Z',
              '2027-01-15T08:05:00.000Z'
            );
            INSERT INTO workspace_documents (
              workspace_id,
              document_id,
              package_path,
              last_opened_at,
              last_saved_at,
              is_dirty,
              file_version_identifier,
              conflict_detected_at,
              conflict_reason
            )
            VALUES (
              1,
              'dddddddd-dddd-dddd-dddd-dddddddddddd',
              '/tmp/Version11.mscope',
              '2027-01-15T08:10:00.000Z',
              '2027-01-15T08:05:00.000Z',
              0,
              'version-11-file',
              NULL,
              NULL
            );
            PRAGMA user_version = 11;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        let document = try XCTUnwrap(migrated.workspaceDocument(workspaceID: 1))
        XCTAssertEqual(document.documentID, UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)
        XCTAssertEqual(document.fileVersionIdentifier, "version-11-file")
        XCTAssertEqual(document.inputCopyingDecision, .copyInputsIntoPackage)
        XCTAssertEqual(document.bookmarkResolutionDecision, .resolveStoredBookmarks)
        XCTAssertNil(document.bookmarkResolutionError)
        XCTAssertEqual(document.recentDocumentState, .available)
        XCTAssertNil(document.recentDocumentStateUpdatedAt)
    }

    func testApplySchemaMigratesVersion10ByAddingAutosaveDecisionRecords() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_workspace_document_autosave_decisions_workspace_id;
            DROP INDEX IF EXISTS idx_workspace_document_autosave_decisions_decided_at;
            DROP TABLE IF EXISTS workspace_document_autosave_decisions;
            PRAGMA user_version = 10;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("workspace_document_autosave_decisions"))

        let workspace = try migrated.saveSnapshot(
            workspaceName: "Autosave Decision Migration",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let document = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: workspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            packagePath: "/tmp/Autosave Decision Migration.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_060),
            lastSavedAt: Date(timeIntervalSince1970: 1_800_000_060),
            isDirty: false,
            fileVersionIdentifier: "migrated-version"
        )
        try migrated.upsertWorkspaceDocument(document)

        let decision = try migrated.recordWorkspaceDocumentAutosaveDecision(
            workspaceID: workspaceID,
            decision: .skippedNoChanges,
            reason: "No unsaved document changes are pending.",
            decidedAt: Date(timeIntervalSince1970: 1_800_000_120)
        )

        XCTAssertEqual(decision.documentID, document.documentID)
        XCTAssertEqual(decision.packagePath, document.packagePath)
        XCTAssertEqual(decision.fileVersionIdentifier, "migrated-version")
        let migratedDocument = try XCTUnwrap(migrated.workspaceDocument(workspaceID: workspaceID))
        XCTAssertEqual(migratedDocument.inputCopyingDecision, .copyInputsIntoPackage)
        XCTAssertEqual(migratedDocument.bookmarkResolutionDecision, .resolveStoredBookmarks)
        XCTAssertEqual(migratedDocument.recentDocumentState, .available)
        XCTAssertEqual(try migrated.workspaceDocumentAutosaveDecisions(workspaceID: workspaceID), [decision])
    }

    func testApplySchemaRejectsFutureDatabaseVersion() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try writeSQLiteUserVersion(WorkspaceDatabase.schemaVersion + 1, to: databaseURL)

        let database = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertThrowsError(try database.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .unsupportedSchemaVersion(stored: WorkspaceDatabase.schemaVersion + 1, supported: WorkspaceDatabase.schemaVersion)
            )
        }
        XCTAssertEqual(try database.tableNames(), [])
    }

    func testPersistsPluginTrustDecisions() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let identifier = "org.macscope.app.plugins.sample"
        let initial = WorkspaceDatabase.PluginTrustRecord(
            identifier: identifier,
            decision: .allowExternal,
            manifestHash: "0123456789abcdef",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(try database.upsertPluginTrustDecision(initial), initial)
        XCTAssertEqual(try database.pluginTrustDecision(identifier: identifier), initial)

        let updated = WorkspaceDatabase.PluginTrustRecord(
            identifier: identifier,
            decision: .deny,
            manifestHash: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_120)
        )

        try database.upsertPluginTrustDecision(updated)
        XCTAssertEqual(try database.pluginTrustDecisions(), [updated])

        try database.deletePluginTrustDecision(identifier: identifier)
        XCTAssertNil(try database.pluginTrustDecision(identifier: identifier))
        XCTAssertEqual(try database.pluginTrustDecisions(), [])
    }

    func testPersistsPluginExternalRunRecords() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_030)
        let started = PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: "org.macscope.app.plugins.sample",
            displayName: "Sample Importer",
            executablePath: "/tmp/sample-plugin.sh",
            manifestHash: "sample-hash",
            status: .started,
            startedAt: startedAt,
            completedAt: nil,
            terminationStatus: nil,
            stdout: "",
            stderr: "",
            log: "started",
            errorMessage: nil
        )

        XCTAssertEqual(try database.upsertPluginExternalRun(started), started)
        XCTAssertEqual(try database.pluginExternalRun(requestID: requestID), started)

        let failed = PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: "org.macscope.app.plugins.sample",
            displayName: "Sample Importer",
            executablePath: "/tmp/sample-plugin.sh",
            manifestHash: "sample-hash",
            status: .failed,
            startedAt: startedAt,
            completedAt: completedAt,
            terminationStatus: 7,
            stdout: #"{"status":"error"}"#,
            stderr: "stderr failure\n",
            log: "started\nfailed",
            errorMessage: "External plugin exited with status 7."
        )

        try database.upsertPluginExternalRun(failed)
        XCTAssertEqual(try database.pluginExternalRun(requestID: requestID), failed)
        XCTAssertEqual(
            try database.pluginExternalRuns(pluginIdentifier: "org.macscope.app.plugins.sample"),
            [failed]
        )
        XCTAssertEqual(try database.pluginExternalRuns(), [failed])

        try database.deletePluginExternalRun(requestID: requestID)
        XCTAssertNil(try database.pluginExternalRun(requestID: requestID))
        XCTAssertEqual(try database.pluginExternalRuns(), [])
    }

    func testPersistsWorkspaceSessionRecords() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Session Records",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        let initial = WorkspaceDatabase.WorkspaceSessionRecord(
            workspaceID: workspaceID,
            selectedSidebarItemID: "function:33333333-3333-3333-3333-333333333333",
            selectedAddress: 0x1000_01000,
            selectedTool: .symbols,
            editorMode: .graph,
            isInspectorPresented: false,
            sidebarSearchText: "render",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_120)
        )

        XCTAssertEqual(try database.upsertWorkspaceSession(initial), initial)
        XCTAssertEqual(try database.workspaceSession(workspaceID: workspaceID), initial)

        let updated = WorkspaceDatabase.WorkspaceSessionRecord(
            workspaceID: workspaceID,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .debug,
            editorMode: .hex,
            isInspectorPresented: true,
            sidebarSearchText: "",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_180)
        )

        try database.upsertWorkspaceSession(updated)
        XCTAssertEqual(try database.workspaceSession(workspaceID: workspaceID), updated)
    }

    func testPersistsWorkspaceDocumentRecordsAndRecentOrdering() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let firstWorkspace = try database.saveSnapshot(
            workspaceName: "First Document",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let emptySnapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [],
            xrefs: [],
            hexBytes: Data()
        )
        let secondWorkspace = try database.saveSnapshot(
            workspaceName: "Second Document",
            snapshot: emptySnapshot,
            now: Date(timeIntervalSince1970: 1_800_000_060)
        )
        let firstWorkspaceID = try XCTUnwrap(firstWorkspace.id)
        let secondWorkspaceID = try XCTUnwrap(secondWorkspace.id)

        let firstDocument = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: firstWorkspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            packagePath: "/tmp/First.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_120),
            lastSavedAt: Date(timeIntervalSince1970: 1_800_000_180),
            isDirty: false,
            fileVersionIdentifier: "first-version"
        )
        let secondDocument = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: secondWorkspaceID,
            documentID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            packagePath: "/tmp/Second.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_240),
            lastSavedAt: nil,
            isDirty: true,
            fileVersionIdentifier: "second-version",
            conflictDetectedAt: Date(timeIntervalSince1970: 1_800_000_250),
            conflictReason: "Package changed on disk after the workspace was opened.",
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .promptForMissingInputs,
            bookmarkResolutionError: "Security-scoped bookmark was stale.",
            recentDocumentState: .conflicted,
            recentDocumentStateUpdatedAt: Date(timeIntervalSince1970: 1_800_000_250)
        )

        XCTAssertEqual(try database.upsertWorkspaceDocument(firstDocument), firstDocument)
        XCTAssertEqual(try database.upsertWorkspaceDocument(secondDocument), secondDocument)
        XCTAssertEqual(try database.workspaceDocument(workspaceID: firstWorkspaceID), firstDocument)
        let reloadedSecondDocument = try XCTUnwrap(database.workspaceDocument(workspaceID: secondWorkspaceID))
        XCTAssertEqual(reloadedSecondDocument, secondDocument)
        XCTAssertEqual(reloadedSecondDocument.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(reloadedSecondDocument.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(reloadedSecondDocument.bookmarkResolutionError, "Security-scoped bookmark was stale.")
        XCTAssertEqual(reloadedSecondDocument.recentDocumentState, .conflicted)
        XCTAssertFalse(reloadedSecondDocument.allowsAutosave)
        XCTAssertEqual(try database.workspaceDocuments(), [secondDocument, firstDocument])
        XCTAssertEqual(try database.recentWorkspaceDocuments(limit: 1), [secondDocument])
        XCTAssertEqual(try database.recentWorkspaceDocuments(limit: 0), [])

        let updatedFirstDocument = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: firstWorkspaceID,
            documentID: firstDocument.documentID,
            packagePath: "/tmp/First Saved As.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_300),
            lastSavedAt: Date(timeIntervalSince1970: 1_800_000_300),
            isDirty: false,
            fileVersionIdentifier: "first-version-saved-as",
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .usePackageAttachmentsOnly,
            recentDocumentState: .available,
            recentDocumentStateUpdatedAt: Date(timeIntervalSince1970: 1_800_000_300)
        )

        try database.upsertWorkspaceDocument(updatedFirstDocument)
        XCTAssertEqual(try database.workspaceDocument(workspaceID: firstWorkspaceID), updatedFirstDocument)
        XCTAssertEqual(try database.workspaceDocuments(), [updatedFirstDocument, secondDocument])

        try database.deleteWorkspace(id: firstWorkspaceID)
        XCTAssertNil(try database.workspaceDocument(workspaceID: firstWorkspaceID))
        XCTAssertEqual(try database.workspaceDocuments(), [secondDocument])
    }

    func testWorkspaceDocumentBookmarkAndRecentStateTransitions() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Recent State Document",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let document = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: workspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            packagePath: "/tmp/Recent State.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_060),
            lastSavedAt: Date(timeIntervalSince1970: 1_800_000_060),
            isDirty: false
        )
        try database.upsertWorkspaceDocument(document)

        let bookmarkUpdated = try database.markWorkspaceDocumentBookmarkResolution(
            workspaceID: workspaceID,
            decision: .promptForMissingInputs,
            errorMessage: "Original input bookmark could not be resolved."
        )
        XCTAssertEqual(bookmarkUpdated.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(bookmarkUpdated.bookmarkResolutionError, "Original input bookmark could not be resolved.")

        let stateUpdatedAt = Date(timeIntervalSince1970: 1_800_000_120)
        let missing = try database.markWorkspaceDocumentRecentState(
            workspaceID: workspaceID,
            state: .missing,
            updatedAt: stateUpdatedAt
        )
        XCTAssertEqual(missing.recentDocumentState, .missing)
        XCTAssertEqual(missing.recentDocumentStateUpdatedAt, stateUpdatedAt)
        XCTAssertFalse(missing.allowsAutosave)

        let reopenedAt = Date(timeIntervalSince1970: 1_800_000_180)
        let reopened = try database.markWorkspaceDocumentOpened(
            workspaceID: workspaceID,
            openedAt: reopenedAt
        )
        XCTAssertEqual(reopened.recentDocumentState, .available)
        XCTAssertEqual(reopened.recentDocumentStateUpdatedAt, reopenedAt)
        XCTAssertTrue(reopened.allowsAutosave)
    }

    func testWorkspaceDocumentDirtyAndSavedTransitionsTrackConflictMetadata() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Lifecycle Document",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let document = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: workspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            packagePath: "/tmp/Lifecycle.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_120),
            lastSavedAt: Date(timeIntervalSince1970: 1_800_000_180),
            isDirty: false,
            fileVersionIdentifier: "clean-version"
        )
        try database.upsertWorkspaceDocument(document)

        let conflictAt = Date(timeIntervalSince1970: 1_800_000_240)
        let dirtyDocument = try database.markWorkspaceDocumentDirty(
            workspaceID: workspaceID,
            conflictDetectedAt: conflictAt,
            conflictReason: "Package changed on disk after the workspace was opened."
        )

        XCTAssertTrue(dirtyDocument.isDirty)
        XCTAssertEqual(dirtyDocument.fileVersionIdentifier, "clean-version")
        XCTAssertEqual(dirtyDocument.conflictDetectedAt, conflictAt)
        XCTAssertEqual(dirtyDocument.conflictReason, "Package changed on disk after the workspace was opened.")
        XCTAssertEqual(dirtyDocument.recentDocumentState, .conflicted)
        XCTAssertEqual(dirtyDocument.recentDocumentStateUpdatedAt, conflictAt)
        XCTAssertFalse(dirtyDocument.allowsAutosave)

        let savedAt = Date(timeIntervalSince1970: 1_800_000_300)
        let savedDocument = try database.markWorkspaceDocumentSaved(
            workspaceID: workspaceID,
            savedAt: savedAt,
            fileVersionIdentifier: "saved-version"
        )

        XCTAssertFalse(savedDocument.isDirty)
        XCTAssertEqual(savedDocument.lastSavedAt, savedAt)
        XCTAssertEqual(savedDocument.fileVersionIdentifier, "saved-version")
        XCTAssertNil(savedDocument.conflictDetectedAt)
        XCTAssertNil(savedDocument.conflictReason)
        XCTAssertNil(savedDocument.bookmarkResolutionError)
        XCTAssertEqual(savedDocument.recentDocumentState, .available)
        XCTAssertEqual(savedDocument.recentDocumentStateUpdatedAt, savedAt)
        XCTAssertTrue(savedDocument.allowsAutosave)
    }

    func testWorkspaceDocumentMetadataSupportsRecentOpenAndAutosavePolicy() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let firstWorkspace = try database.saveSnapshot(
            workspaceName: "First Workspace",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let secondWorkspace = try database.saveSnapshot(
            workspaceName: "Second Workspace",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            now: Date(timeIntervalSince1970: 1_800_000_060)
        )
        let firstWorkspaceID = try XCTUnwrap(firstWorkspace.id)
        let secondWorkspaceID = try XCTUnwrap(secondWorkspace.id)
        let firstURL = URL(fileURLWithPath: "/tmp/First.mscope", isDirectory: true)
        let secondURL = URL(fileURLWithPath: "/tmp/Second.mscope", isDirectory: true)
        let conflictReason = "Package changed on disk after the workspace was opened."

        try database.upsertWorkspaceDocument(
            WorkspaceDatabase.WorkspaceDocumentRecord(
                workspaceID: firstWorkspaceID,
                documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
                packagePath: firstURL.standardizedFileURL.path,
                lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_120),
                lastSavedAt: Date(timeIntervalSince1970: 1_800_000_120),
                isDirty: false,
                fileVersionIdentifier: "first-version"
            )
        )
        try database.upsertWorkspaceDocument(
            WorkspaceDatabase.WorkspaceDocumentRecord(
                workspaceID: secondWorkspaceID,
                documentID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                packagePath: secondURL.standardizedFileURL.path,
                lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_180),
                lastSavedAt: Date(timeIntervalSince1970: 1_800_000_120),
                isDirty: true,
                fileVersionIdentifier: "second-version",
                conflictDetectedAt: Date(timeIntervalSince1970: 1_800_000_210),
                conflictReason: conflictReason,
                inputCopyingDecision: .referenceOriginalInputs,
                bookmarkResolutionDecision: .promptForMissingInputs,
                bookmarkResolutionError: "Prompt required for stale original input bookmark.",
                recentDocumentState: .conflicted,
                recentDocumentStateUpdatedAt: Date(timeIntervalSince1970: 1_800_000_210)
            )
        )

        let firstMetadata = try XCTUnwrap(database.workspaceDocumentMetadata(packageURL: firstURL))
        XCTAssertEqual(firstMetadata.workspaceID, firstWorkspaceID)
        XCTAssertEqual(firstMetadata.workspaceName, "First Workspace")
        XCTAssertEqual(firstMetadata.packageDisplayName, "First")
        XCTAssertEqual(firstMetadata.packageURL.path, firstURL.standardizedFileURL.path)
        XCTAssertEqual(firstMetadata.lifecycleState, .clean)
        XCTAssertEqual(firstMetadata.inputCopyingDecision, .copyInputsIntoPackage)
        XCTAssertEqual(firstMetadata.bookmarkResolutionDecision, .resolveStoredBookmarks)
        XCTAssertNil(firstMetadata.bookmarkResolutionError)
        XCTAssertEqual(firstMetadata.recentDocumentState, .available)
        XCTAssertTrue(firstMetadata.allowsAutosave)

        let secondMetadata = try XCTUnwrap(database.workspaceDocumentMetadata(workspaceID: secondWorkspaceID))
        XCTAssertEqual(secondMetadata.workspaceID, secondWorkspaceID)
        XCTAssertEqual(secondMetadata.workspaceName, "Second Workspace")
        XCTAssertEqual(secondMetadata.packageDisplayName, "Second")
        XCTAssertEqual(secondMetadata.lifecycleState, .conflicted(reason: conflictReason))
        XCTAssertEqual(secondMetadata.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(secondMetadata.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(secondMetadata.bookmarkResolutionError, "Prompt required for stale original input bookmark.")
        XCTAssertEqual(secondMetadata.recentDocumentState, .conflicted)
        XCTAssertFalse(secondMetadata.allowsAutosave)

        XCTAssertEqual(
            try database.recentWorkspaceDocumentMetadata(limit: 2).map(\.workspaceID),
            [secondWorkspaceID, firstWorkspaceID]
        )

        let reopenedURL = URL(fileURLWithPath: "/tmp/First Reopened.mscope", isDirectory: true)
        let reopenedAt = Date(timeIntervalSince1970: 1_800_000_300)
        let reopened = try database.markWorkspaceDocumentOpened(
            workspaceID: firstWorkspaceID,
            packageURL: reopenedURL,
            openedAt: reopenedAt
        )

        XCTAssertEqual(reopened.packagePath, reopenedURL.standardizedFileURL.path)
        XCTAssertEqual(reopened.lastOpenedAt, reopenedAt)
        XCTAssertEqual(
            try database.recentWorkspaceDocumentMetadata(limit: 2).map(\.workspaceID),
            [firstWorkspaceID, secondWorkspaceID]
        )
        XCTAssertEqual(
            try database.workspaceDocumentMetadata(packageURL: reopenedURL)?.workspaceID,
            firstWorkspaceID
        )
    }

    func testPersistsWorkspaceDocumentAutosaveDecisionRecords() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Autosave Decisions",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let document = WorkspaceDatabase.WorkspaceDocumentRecord(
            workspaceID: workspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            packagePath: "/tmp/Autosave Decisions.mscope",
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_060),
            lastSavedAt: Date(timeIntervalSince1970: 1_800_000_060),
            isDirty: false,
            fileVersionIdentifier: "clean-version"
        )
        try database.upsertWorkspaceDocument(document)

        let skipped = try database.recordWorkspaceDocumentAutosaveDecision(
            workspaceID: workspaceID,
            decision: .skippedNoChanges,
            reason: "No unsaved document changes are pending.",
            decidedAt: Date(timeIntervalSince1970: 1_800_000_120),
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let conflict = try database.recordWorkspaceDocumentAutosaveDecision(
            workspaceID: workspaceID,
            decision: .skippedConflict,
            reason: "Autosave is paused until the package conflict is resolved.",
            decidedAt: Date(timeIntervalSince1970: 1_800_000_180),
            uuid: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let failed = try database.recordWorkspaceDocumentAutosaveDecision(
            workspaceID: workspaceID,
            decision: .failed,
            reason: "Package write failed.",
            decidedAt: Date(timeIntervalSince1970: 1_800_000_240),
            completedAt: Date(timeIntervalSince1970: 1_800_000_250),
            errorMessage: "The destination volume is read-only.",
            uuid: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        )

        XCTAssertEqual(skipped.documentID, document.documentID)
        XCTAssertEqual(skipped.packagePath, document.packagePath)
        XCTAssertEqual(skipped.fileVersionIdentifier, "clean-version")
        XCTAssertNil(skipped.errorMessage)
        XCTAssertEqual(conflict.decision, .skippedConflict)
        XCTAssertEqual(failed.completedAt, Date(timeIntervalSince1970: 1_800_000_250))
        XCTAssertEqual(failed.errorMessage, "The destination volume is read-only.")
        XCTAssertEqual(
            try database.workspaceDocumentAutosaveDecisions(workspaceID: workspaceID),
            [failed, conflict, skipped]
        )
        XCTAssertEqual(try database.recentWorkspaceDocumentAutosaveDecisions(limit: 2), [failed, conflict])
        XCTAssertEqual(try database.recentWorkspaceDocumentAutosaveDecisions(limit: 0), [])

        try database.deleteWorkspace(id: workspaceID)
        XCTAssertEqual(try database.workspaceDocumentAutosaveDecisions(workspaceID: workspaceID), [])
        XCTAssertEqual(try database.recentWorkspaceDocumentAutosaveDecisions(limit: 3), [])
    }

    func testWorkspaceDocumentAutosaveDecisionFailuresAreReported() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        XCTAssertThrowsError(
            try database.recordWorkspaceDocumentAutosaveDecision(
                workspaceID: 404,
                decision: .skippedNoChanges,
                reason: "No document lifecycle row exists.",
                decidedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .notFound)
        }

        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        do {
            let fileBacked = try WorkspaceDatabase(path: databaseURL.path)
            try fileBacked.applySchema()
            let workspace = try fileBacked.saveSnapshot(
                workspaceName: "Invalid Autosave Decision",
                snapshot: AnalysisEngine.previewSnapshot(),
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            let workspaceID = try XCTUnwrap(workspace.id)
            try fileBacked.upsertWorkspaceDocument(
                WorkspaceDatabase.WorkspaceDocumentRecord(
                    workspaceID: workspaceID,
                    documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
                    packagePath: "/tmp/Invalid Autosave Decision.mscope",
                    lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_060),
                    lastSavedAt: Date(timeIntervalSince1970: 1_800_000_060),
                    isDirty: false
                )
            )
        }

        try executeSQLiteStatements(
            """
            INSERT INTO workspace_document_autosave_decisions (
              uuid,
              workspace_id,
              document_id,
              package_path,
              decision,
              reason,
              file_version_identifier,
              decided_at,
              completed_at,
              error_message
            )
            VALUES (
              'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
              1,
              'dddddddd-dddd-dddd-dddd-dddddddddddd',
              '/tmp/Invalid Autosave Decision.mscope',
              'paused_for_unknown_reason',
              NULL,
              NULL,
              '2027-01-15T08:00:00.000Z',
              NULL,
              NULL
            );
            """,
            to: databaseURL
        )

        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        try reopened.applySchema()
        XCTAssertThrowsError(try reopened.workspaceDocumentAutosaveDecisions(workspaceID: 1)) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .invalidWorkspaceDocumentAutosaveDecision("paused_for_unknown_reason")
            )
        }
    }

    func testInsertsAndReadsWorkspaceRecords() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_060)
        let workspace = try database.insertWorkspace(
            WorkspaceDatabase.WorkspaceRecord(
                id: nil,
                uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Persistence Test",
                createdAt: createdAt,
                modifiedAt: modifiedAt
            )
        )
        let binary = try database.insertBinary(
            WorkspaceDatabase.BinaryRecord(
                id: nil,
                uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                workspaceID: try XCTUnwrap(workspace.id),
                name: "TestBinary",
                path: "/tmp/TestBinary",
                originalPathBookmark: Data([0x62, 0x6f, 0x6f, 0x6b]),
                kind: "binary",
                architecture: "arm64",
                fileHash: "abc123",
                fileSize: 4,
                hexBytes: Data([0xff, 0x83, 0x00, 0xd1]),
                isBundle: false
            )
        )
        let function = try database.insertFunction(
            WorkspaceDatabase.FunctionRecord(
                id: nil,
                uuid: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                binaryID: try XCTUnwrap(binary.id),
                startAddress: 0x1000_00000,
                endAddress: 0x1000_00008,
                symbolName: "_main",
                demangledName: nil,
                confidence: 0.9
            )
        )
        _ = try database.insertInstruction(
            WorkspaceDatabase.InstructionRecord(
                id: nil,
                functionID: try XCTUnwrap(function.id),
                address: 0x1000_00000,
                bytes: Data([0xff, 0x83, 0x00, 0xd1]),
                mnemonic: "sub",
                operands: "sp, sp, #0x20",
                hasBreakpoint: true,
                comment: "Stack frame",
                irJSON: Data(#"{"op":"sub"}"#.utf8)
            )
        )
        let basicBlock = try database.insertBasicBlock(
            WorkspaceDatabase.BasicBlockRecord(
                id: nil,
                uuid: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                functionID: try XCTUnwrap(function.id),
                startAddress: 0x1000_00000,
                endAddress: 0x1000_00008,
                instructionCount: 2
            )
        )
        _ = try database.insertXRef(
            WorkspaceDatabase.XRefRecord(
                id: nil,
                uuid: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                binaryID: try XCTUnwrap(binary.id),
                fromAddress: 0x1000_00000,
                toAddress: 0x1000_00008,
                kind: "fallthrough"
            )
        )
        let indirectSymbol = try database.insertIndirectSymbol(
            WorkspaceDatabase.IndirectSymbolRecord(
                id: nil,
                uuid: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                binaryID: try XCTUnwrap(binary.id),
                kind: "symbolStub",
                sourceSection: "__TEXT,__stubs",
                address: 0x1000_01000,
                entrySize: 12,
                tableIndex: 0,
                rawSymbolIndex: 0,
                symbolIndex: 0,
                symbolName: "_puts",
                libraryOrdinal: 1,
                libraryName: "/usr/lib/libSystem.B.dylib",
                isLocal: false,
                isAbsolute: false
            )
        )
        let controlFlowEdge = try database.insertControlFlowEdge(
            WorkspaceDatabase.ControlFlowEdgeRecord(
                id: nil,
                uuid: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                binaryID: try XCTUnwrap(binary.id),
                fromAddress: 0x1000_00000,
                toAddress: 0x1000_00008,
                kind: "fallthrough"
            )
        )

        XCTAssertEqual(try database.workspace(id: try XCTUnwrap(workspace.id))?.name, "Persistence Test")
        XCTAssertEqual(try database.binaries(workspaceID: try XCTUnwrap(workspace.id)), [binary])
        XCTAssertEqual(try database.functions(binaryID: try XCTUnwrap(binary.id)), [function])

        let instructions = try database.instructions(functionID: try XCTUnwrap(function.id))
        XCTAssertEqual(instructions.count, 1)
        XCTAssertEqual(instructions.first?.address, 0x1000_00000)
        XCTAssertEqual(instructions.first?.bytes, Data([0xff, 0x83, 0x00, 0xd1]))
        XCTAssertEqual(instructions.first?.hasBreakpoint, true)
        XCTAssertEqual(instructions.first?.comment, "Stack frame")
        XCTAssertEqual(instructions.first?.irJSON, Data(#"{"op":"sub"}"#.utf8))

        XCTAssertEqual(try database.basicBlocks(functionID: try XCTUnwrap(function.id)), [basicBlock])
        XCTAssertEqual(try database.indirectSymbols(binaryID: try XCTUnwrap(binary.id)), [indirectSymbol])

        let xrefs = try database.xrefs(binaryID: try XCTUnwrap(binary.id))
        XCTAssertEqual(xrefs.map(\.kind), ["fallthrough"])
        XCTAssertEqual(xrefs.first?.fromAddress, 0x1000_00000)
        XCTAssertEqual(xrefs.first?.toAddress, 0x1000_00008)

        XCTAssertEqual(try database.controlFlowEdges(binaryID: try XCTUnwrap(binary.id)), [controlFlowEdge])
    }

    func testSnapshotRoundTripMapsCurrentWorkspaceModels() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = AnalysisEngine.previewSnapshot()

        let workspace = try database.saveSnapshot(
            workspaceName: "Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))

        XCTAssertEqual(reloaded.binaries, snapshot.binaries)
        XCTAssertEqual(reloaded.functions, snapshot.functions)
        XCTAssertEqual(reloaded.symbols, snapshot.symbols)
        XCTAssertEqual(reloaded.imports, snapshot.imports)
        XCTAssertEqual(reloaded.indirectSymbols, snapshot.indirectSymbols)
        XCTAssertEqual(reloaded.exports, snapshot.exports)
        XCTAssertEqual(reloaded.stringLiterals, snapshot.stringLiterals)
        XCTAssertEqual(reloaded.basicBlocks, snapshot.basicBlocks)
        XCTAssertEqual(reloaded.instructions, snapshot.instructions)
        XCTAssertEqual(reloaded.xrefs, snapshot.xrefs)
        XCTAssertEqual(reloaded.controlFlowEdges, snapshot.controlFlowEdges)
        XCTAssertEqual(reloaded.hexBytes, snapshot.hexBytes)
    }

    func testObjcSelectorsAreNotPersistedThroughPackageAnalysis() throws {
        // objcSelectors mirrors jumpTables: a derived, non-Codable field that is
        // dropped on the WorkspacePackageAnalysis round-trip, so a reloaded
        // snapshot has no resolved selectors (conservative pre-existing behavior).
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.objcSelectors = [0x1000_08010: "viewDidLoad"]

        let reconstructed = WorkspacePackageAnalysis(snapshot: snapshot)
            .snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        XCTAssertTrue(reconstructed.objcSelectors.isEmpty)
    }

    func testAddressOverridesArePersistedThroughPackageAnalysis() throws {
        // Unlike the derived objcSelectors/jumpTables seams, user-authored address
        // overrides ARE persisted through the WorkspacePackageAnalysis round-trip
        // (JSON encode/decode) so renames and comments survive save/reload. Empty
        // overrides are pruned and entries are address-sorted.
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", customComment: "entry"),
            .primary(0x1_0000_1000): AddressOverride(customComment: "hot loop"),
            .primary(0x1_0000_2000): AddressOverride() // empty -> dropped
        ]

        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        XCTAssertEqual(reconstructed.addressOverrides[.primary(0x1_0000_0000)], AddressOverride(customName: "decodeFrame", customComment: "entry"))
        XCTAssertEqual(reconstructed.addressOverrides[.primary(0x1_0000_1000)], AddressOverride(customComment: "hot loop"))
        XCTAssertNil(reconstructed.addressOverrides[.primary(0x1_0000_2000)])
        XCTAssertEqual(reconstructed.addressOverrides.count, 2)
        XCTAssertEqual(analysis.addressOverrides.map(\.address), [0x1_0000_0000, 0x1_0000_1000])
    }

    func testPackageAnalysisWithoutOverridesKeyDecodesEmpty() throws {
        // Backward compatibility: a pre-override manifest (no addressOverrides key)
        // decodes with an empty override set.
        let json = "{\"functions\":[],\"instructions\":[],\"xrefs\":[]}"
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.addressOverrides.isEmpty)
        XCTAssertTrue(decoded.snapshot(binaries: [], hexBytes: Data()).addressOverrides.isEmpty)
        // The v22 manual-xref/bookmark keys also default to empty for an old manifest.
        XCTAssertTrue(decoded.manualXRefs.isEmpty)
        XCTAssertTrue(decoded.bookmarks.isEmpty)
    }

    func testManualXRefsAndBookmarksRoundTripThroughPackageAnalysis() throws {
        // The v22 manual xref / bookmark lists survive the .mscope Codable round-trip,
        // sorted for deterministic JSON.
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.manualXRefs = [
            ManualXRef(from: 0x1_0000_1000, to: 0x1_0000_2000, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 0x1_0000_0000, to: 0x1_0000_3000, kind: XRefKind.data, isSuppression: true),
        ]
        snapshot.bookmarks = [
            Bookmark(address: 0x1_0000_2000, name: "second"),
            Bookmark(address: 0x1_0000_0000, name: "first"),
        ]
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(isUndefined: true, patch: BytePatch.arm64NOP),
        ]

        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        // Address/endpoint-sorted for deterministic JSON.
        XCTAssertEqual(analysis.manualXRefs.map(\.from), [0x1_0000_0000, 0x1_0000_1000])
        XCTAssertEqual(analysis.bookmarks.map(\.address), [0x1_0000_0000, 0x1_0000_2000])

        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        XCTAssertEqual(reconstructed.manualXRefs.count, 2)
        XCTAssertEqual(reconstructed.bookmark(at: 0x1_0000_0000)?.name, "first")
        XCTAssertTrue(reconstructed.isUndefined(at: 0x1_0000_0000))
        XCTAssertEqual(reconstructed.patch(at: 0x1_0000_0000), BytePatch.arm64NOP)
    }

    func testApplySchemaMigratesVersion12To13AddingAddressOverrides() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll back to a v12 database by dropping the v13 table.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            PRAGMA user_version = 12;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.tableNames().contains("address_overrides"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("address_overrides"))
    }

    func testAddressOverridesSurviveSaveSnapshotAndLoad() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", customComment: "entry"),
            .primary(0x1_0000_0014): AddressOverride(customComment: "loop body"),
            .primary(0x1_0000_0020): AddressOverride() // empty -> not persisted
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Overrides Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0000)], AddressOverride(customName: "decodeFrame", customComment: "entry"))
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0014)], AddressOverride(customComment: "loop body"))
        XCTAssertNil(reloaded.addressOverrides[.primary(0x1_0000_0020)])
        XCTAssertEqual(reloaded.addressOverrides.count, 2)
    }

    func testMarkAsProcedureOverrideSurvivesSaveSnapshotAndLoad() throws {
        // The v20 mark_as_procedure column round-trips through SQLite save/reload.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(markAsProcedure: true),
            .primary(0x1_0000_0014): AddressOverride(customName: "helper", markAsProcedure: true),
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Procedure Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0000)]?.markAsProcedure, true)
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0014)], AddressOverride(customName: "helper", markAsProcedure: true))
    }

    func testDataShapeOverridesSurviveSaveSnapshotAndLoad() throws {
        // The v21 data_shape_json column round-trips Make Array/Alignment/String.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(dataShape: DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 16)),
            .primary(0x1_0000_0014): AddressOverride(dataShape: DataShapeOverride(kind: .alignment, alignment: 8)),
            .primary(0x1_0000_0020): AddressOverride(customName: "msg", dataShape: DataShapeOverride(kind: .string, isNullTerminated: true)),
            .primary(0x1_0000_0024): AddressOverride(dataShape: DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: 12)),
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Data Shape Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))

        XCTAssertEqual(reloaded.dataShape(at: 0x1_0000_0000),
                       DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 16))
        XCTAssertEqual(reloaded.dataShape(at: 0x1_0000_0014)?.alignment, 8)
        XCTAssertEqual(reloaded.dataShape(at: 0x1_0000_0020)?.kind, .string)
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0020)]?.customName, "msg")
        XCTAssertEqual(reloaded.dataShape(at: 0x1_0000_0024)?.stringLength, 12)
        // A shaped span reads as data on reload (drives code-analysis exclusion).
        XCTAssertTrue(reloaded.isData(at: 0x1_0000_0000))
        XCTAssertEqual(reloaded.addressOverrides.count, 4)
    }

    func testDataShapeSurvivesSaveReopenSaveWithoutUniqueAbort() throws {
        // CRITICAL FOOTGUN: a second save of a shape-bearing workspace must not collide
        // with the UNIQUE(workspace_id, address) index (the dataShape rows ride the
        // workspace-scoped address_overrides table) and abort the whole save. This
        // exercises a genuine save → reopen(SAME file) → save, which also crosses the
        // global binaries.uuid index — the reopen re-saves into the workspace's stable
        // id (ID-based identity, never a display-name lookup), so it stays idempotent.
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var snapshot = previewSnapshotWithMetadata()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(dataShape: DataShapeOverride(kind: .array, elementType: "uint8_t", elementCount: 4)),
            .primary(0x1_0000_0014): AddressOverride(dataShape: DataShapeOverride(kind: .alignment, alignment: 16)),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func save() throws -> WorkspaceDatabase.PersistedWorkspace {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            // Mirror the app's reopen→save: a package holds a single workspace, so on
            // reopen we re-save into its stable id; the first save creates it.
            if let existing = try database.workspaces().first, let existingID = existing.id {
                return try database.saveWorkspaceState(
                    workspaceID: existingID,
                    workspaceName: "Shapes",
                    snapshot: snapshot,
                    selectedSidebarItemID: nil,
                    selectedAddress: nil,
                    selectedTool: .project,
                    editorMode: .disassembly,
                    isInspectorPresented: true,
                    sidebarSearchText: "",
                    now: now
                )
            }
            return try database.createWorkspaceState(
                workspaceName: "Shapes",
                snapshot: snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                now: now
            )
        }

        _ = try save()              // first save into the file
        let resaved = try save()    // reopen the SAME file and save again — must not abort

        let database = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertEqual(try database.workspaces().count, 1) // idempotent: no duplicate row
        let resavedID = try XCTUnwrap(resaved.workspace.id)
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: resavedID))
        XCTAssertEqual(reloaded.dataShape(at: 0x1_0000_0000)?.elementCount, 4)
        XCTAssertEqual(reloaded.dataShape(at: 0x1_0000_0014)?.alignment, 16)
        XCTAssertEqual(reloaded.addressOverrides.count, 2)
    }

    func testBinaryBearingSnapshotSurvivesSaveReopenSaveIntoSameFile() throws {
        // A persistent serialization database must support save → reopen(SAME file) →
        // save of the same binary (same uuid) without aborting on the GLOBAL
        // binaries.uuid UNIQUE index. On reopen the app re-saves into the workspace's
        // stable id (ID-based identity), and replaceWorkspaceState delete-then-inserts —
        // deleting the prior binary rows first — so the re-save is idempotent instead of
        // inserting a duplicate workspace whose re-inserted binary (and every child
        // row — functions/symbols/imports/… all carry global-UNIQUE uuids) collides.
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        // Built ONCE: previewSnapshot() assigns the binary a fresh random UUID per call,
        // so both saves must share the same snapshot value to exercise the duplicate-uuid
        // path. Carry an authoring override too, to prove workspace-scoped state survives.
        var snapshot = previewSnapshotWithMetadata()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", colorTag: .blue)
        ]
        let binaryID = try XCTUnwrap(snapshot.binaries.first?.id)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func save() throws -> WorkspaceDatabase.PersistedWorkspace {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema() // no-op migrate on reopen
            // Reopen→save by stable id; the first save creates the workspace.
            if let existing = try database.workspaces().first, let existingID = existing.id {
                return try database.saveWorkspaceState(
                    workspaceID: existingID,
                    workspaceName: "Persistent",
                    snapshot: snapshot,
                    selectedSidebarItemID: nil,
                    selectedAddress: nil,
                    selectedTool: .project,
                    editorMode: .disassembly,
                    isInspectorPresented: true,
                    sidebarSearchText: "",
                    now: now
                )
            }
            return try database.createWorkspaceState(
                workspaceName: "Persistent",
                snapshot: snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                now: now
            )
        }

        _ = try save()              // first save into the file
        let resaved = try save()    // reopen the SAME file and save again — must not abort

        // Idempotent: the re-save reuses the prior workspace row instead of piling up a
        // second one per save.
        let database = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertEqual(try database.workspaces().count, 1)

        let resavedID = try XCTUnwrap(resaved.workspace.id)
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: resavedID))
        XCTAssertEqual(reloaded.binaries.count, 1)
        XCTAssertEqual(reloaded.binaries.first?.id, binaryID)
        XCTAssertEqual(reloaded.functions.count, snapshot.functions.count)
        XCTAssertEqual(reloaded.symbols.count, snapshot.symbols.count)
        XCTAssertEqual(reloaded.imports.count, snapshot.imports.count)
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0000)],
                       AddressOverride(customName: "decodeFrame", colorTag: .blue))
        XCTAssertEqual(reloaded.addressOverrides.count, 1)
    }

    func testTwoWorkspacesWithSameDisplayNameStayIndependent() throws {
        // Identity is the stable workspace id, NOT the display name: two workspaces may
        // legally share a name, and saving into one by id must never touch the other.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func create(_ overrides: [ImageAddress: AddressOverride]) throws -> WorkspaceDatabase.PersistedWorkspace {
            // Minimal snapshots (no binary/symbols) so two can coexist in one DB without
            // tripping the global symbols.uuid/binaries.uuid indexes — this test is about
            // workspace identity, not child-row content.
            var snapshot = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
            snapshot.addressOverrides = overrides
            return try database.createWorkspaceState(
                workspaceName: "Duplicate", snapshot: snapshot, selectedSidebarItemID: nil,
                selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
                isInspectorPresented: true, sidebarSearchText: "", now: now
            )
        }

        let w1 = try create([.primary(0x1000): AddressOverride(customName: "first")])
        let w2 = try create([.primary(0x2000): AddressOverride(customName: "second")])
        let id1 = try XCTUnwrap(w1.workspace.id)
        let id2 = try XCTUnwrap(w2.workspace.id)
        XCTAssertNotEqual(id1, id2)                       // distinct identity despite shared name
        XCTAssertEqual(try database.workspaces().count, 2)

        // Re-save w1 by id; w2 must be untouched (name is not the overwrite key).
        var edited = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        edited.addressOverrides = [.primary(0x1000): AddressOverride(customName: "first-edited")]
        _ = try database.saveWorkspaceState(
            workspaceID: id1, workspaceName: "Duplicate", snapshot: edited, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        )
        XCTAssertEqual(try database.workspaces().count, 2) // no duplicate, no overwrite of w2
        let r1 = try XCTUnwrap(database.loadSnapshot(workspaceID: id1))
        let r2 = try XCTUnwrap(database.loadSnapshot(workspaceID: id2))
        XCTAssertEqual(r1.addressOverrides[.primary(0x1000)]?.customName, "first-edited")
        XCTAssertEqual(r2.addressOverrides[.primary(0x2000)]?.customName, "second")
    }

    func testForeignKeysEnabledAndIntegrityCheckPasses() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        XCTAssertTrue(try database.foreignKeysEnabled())

        var snapshot = previewSnapshotWithMetadata()
        snapshot.addressOverrides = [.primary(0x1000): AddressOverride(customName: "x")]
        snapshot.bookmarks = [Bookmark(address: 0x1000, name: "bm")]
        snapshot.manualXRefs = [ManualXRef(from: 0x1000, to: 0x2000, kind: XRefKind.call, isSuppression: false)]
        _ = try database.saveWorkspaceState(
            workspaceName: "Integrity", snapshot: snapshot, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(try database.integrityCheck(), ["ok"])
    }

    func testReplaceWorkspaceRollsBackOnInjectedFailure() throws {
        // A save that fails partway must roll back the WHOLE transaction, leaving the
        // target workspace's prior authoring state intact rather than half-wiped. The
        // injected failure: re-saving wB with a snapshot whose symbols carry the same
        // global-UNIQUE uuids as wA's already-stored symbols, so insertSnapshotContents
        // aborts AFTER wB's own rows were deleted in the same transaction.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // wA: a full preview snapshot — its symbols occupy global-UNIQUE symbols.uuid rows.
        let wA = try database.createWorkspaceState(
            workspaceName: "A", snapshot: previewSnapshotWithMetadata(), selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        )
        XCTAssertNotNil(wA.workspace.id)

        // wB: minimal + an authoring override (no symbols, so it creates cleanly).
        var snapB = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapB.addressOverrides = [.primary(0x1000): AddressOverride(customName: "keepMe")]
        let wB = try database.createWorkspaceState(
            workspaceName: "B", snapshot: snapB, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        )
        let idB = try XCTUnwrap(wB.workspace.id)

        // Re-save wB with a second preview snapshot — its symbols reuse wA's uuids, so the
        // insert collides on symbols.uuid AFTER wB's rows are deleted in the transaction.
        var colliding = previewSnapshotWithMetadata()
        colliding.addressOverrides = [.primary(0x1000): AddressOverride(customName: "shouldNotPersist")]
        XCTAssertThrowsError(try database.saveWorkspaceState(
            workspaceID: idB, workspaceName: "B", snapshot: colliding, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        ))

        // Rolled back: wB keeps its ORIGINAL override, not the failed write, and the row
        // count is unchanged. Integrity holds.
        let reloadedB = try XCTUnwrap(database.loadSnapshot(workspaceID: idB))
        XCTAssertEqual(reloadedB.addressOverrides[.primary(0x1000)]?.customName, "keepMe")
        XCTAssertEqual(try database.workspaces().count, 2)
        XCTAssertEqual(try database.integrityCheck(), ["ok"])
    }

    func testApplySchemaMigratesVersion20To21AddingDataShapeColumn() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll address_overrides back to a v20 shape (no data_shape_json), seed a row,
        // and mark the database as v20.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0,
              signature_json TEXT,
              applied_type_name TEXT,
              switch_hint_json TEXT,
              operand_format TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL,
              mark_as_procedure INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX idx_address_overrides_workspace_address
              ON address_overrides(workspace_id, address);
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '20000000-0000-0000-0000-000000000020', 'V20', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 20;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("data_shape_json"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("data_shape_json"))

        // The pre-existing v20 row survives the ALTER with a NULL shape.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.customName, "legacyName")
        XCTAssertNil(record.dataShapeJSON)
    }

    func testApplySchemaMigratesVersion22To23AddingSegmentOverridesTable() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll the database back to a v22 shape: drop the v23 segment_overrides table, seed a
        // workspace, and mark it v22. The migration must (re)create segment_overrides via the
        // shared ALTER path and reach the current schema version.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_segment_overrides_workspace_name;
            DROP TABLE IF EXISTS segment_overrides;
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '22000000-0000-0000-0000-000000000022', 'V22', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 22;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.tableNames().contains("segment_overrides"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("segment_overrides"))
        // The new table is usable post-migration (insert + read round-trips).
        try migrated.insertSegmentOverride(
            WorkspaceDatabase.SegmentOverrideRecord(
                id: UUID(), workspaceID: 1, originalName: "__TEXT,__text",
                displayName: "Code", rebaseDelta: 0x1000,
                createdAt: Date(), modifiedAt: Date()
            )
        )
        let stored = try migrated.segmentOverrides(workspaceID: 1)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.displayName, "Code")
        XCTAssertEqual(stored.first?.rebaseDelta, 0x1000)
    }

    // MARK: - v23 -> v24: register renames + local labels (address_overrides columns)

    func testApplySchemaMigratesVersion23To24AddingRegisterNamesAndLocalLabelColumns() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll address_overrides back to a v23 shape (no register_names_json / local_label),
        // seed a row, and mark the database v23. The migration must ADD the two new columns via
        // the shared ALTER path, preserve the existing row, and reach the current schema version.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0,
              signature_json TEXT,
              applied_type_name TEXT,
              switch_hint_json TEXT,
              operand_format TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL,
              mark_as_procedure INTEGER NOT NULL DEFAULT 0,
              data_shape_json TEXT,
              is_undefined INTEGER NOT NULL DEFAULT 0,
              patch_json TEXT
            );
            CREATE UNIQUE INDEX idx_address_overrides_workspace_address
              ON address_overrides(workspace_id, address);
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '23000000-0000-0000-0000-000000000023', 'V23', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 23;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("register_names_json"))
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("local_label"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("register_names_json"))
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("local_label"))

        // The pre-existing v23 row survives the ALTER with NULL new columns.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.customName, "legacyName")
        XCTAssertNil(record.registerNamesJSON)
        XCTAssertNil(record.localLabel)
    }

    func testRegisterNameAndLocalLabelSurviveSaveReopenSaveWithoutUniqueAbort() throws {
        // CRITICAL FOOTGUN: a second save (through a FRESH serialization DB, the production write
        // path) of a register-rename / local-label-bearing workspace must NOT abort on the
        // address_overrides UNIQUE index (the v24 increment rides the existing override table, so
        // the existing delete-before-reinsert in deleteSnapshotContents already covers it — this
        // pins that it actually does).
        var snapshot = previewSnapshotWithMetadata()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(registerNames: ["x19": "counter"]),
            .primary(0x1_0000_0014): AddressOverride(localLabel: "loc_retry"),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let firstURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: firstURL) }
        let workspaceID: Int64
        do {
            let database = try WorkspaceDatabase(path: firstURL.path)
            try database.applySchema()
            workspaceID = try XCTUnwrap(try database.saveSnapshot(workspaceName: "v24", snapshot: snapshot, now: now).id)
        }

        // Re-save into the SAME workspace id (delete + re-insert). Must not throw.
        do {
            let database = try WorkspaceDatabase(path: firstURL.path)
            XCTAssertNoThrow(try database.replaceWorkspaceState(
                workspaceID: workspaceID,
                workspaceName: "v24",
                snapshot: snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: false,
                sidebarSearchText: ""
            ))
        }

        let reopened = try WorkspaceDatabase(path: firstURL.path)
        let reloaded = try XCTUnwrap(reopened.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.registerNameOverrides(forProcedureAt: 0x1_0000_0000)["x19"], "counter")
        XCTAssertEqual(reloaded.localLabel(at: 0x1_0000_0014), "loc_retry")
    }

    // MARK: - v22: Mark-as-Undefined + Patch-Bytes + Manual XRefs + Bookmarks

    func testUndefinedAndPatchOverridesSurviveSaveSnapshotAndLoad() throws {
        // The v22 is_undefined + patch_json columns round-trip Mark-as-Undefined / Patch.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(isUndefined: true),
            .primary(0x1_0000_0014): AddressOverride(customName: "patched", patch: BytePatch.arm64NOP),
            .primary(0x1_0000_0020): AddressOverride(patch: BytePatch(bytes: [0xaa, 0xbb, 0xcc, 0xdd])),
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Undefined/Patch Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertTrue(reloaded.isUndefined(at: 0x1_0000_0000))
        XCTAssertEqual(reloaded.patch(at: 0x1_0000_0014), BytePatch.arm64NOP)
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0014)]?.customName, "patched")
        XCTAssertEqual(reloaded.patch(at: 0x1_0000_0020)?.bytes, [0xaa, 0xbb, 0xcc, 0xdd])
        XCTAssertEqual(reloaded.addressOverrides.count, 3)
    }

    func testUndefinedAndPatchSurviveSaveReopenSaveWithoutUniqueAbort() throws {
        // CRITICAL FOOTGUN: a second save (through a FRESH serialization DB, the production
        // write path) of an undefined/patch-bearing workspace must not abort on the
        // address_overrides UNIQUE index.
        var snapshot = previewSnapshotWithMetadata()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(isUndefined: true),
            .primary(0x1_0000_0014): AddressOverride(patch: BytePatch.arm64NOP),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let firstURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: firstURL) }
        do {
            let database = try WorkspaceDatabase(path: firstURL.path)
            try database.applySchema()
            _ = try database.saveWorkspaceState(
                workspaceName: "UP", snapshot: snapshot, selectedSidebarItemID: nil,
                selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
                isInspectorPresented: true, sidebarSearchText: "", now: now
            )
        }

        let secondURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: secondURL) }
        let database = try WorkspaceDatabase(path: secondURL.path)
        try database.applySchema()
        let resaved = try database.saveWorkspaceState(
            workspaceName: "UP", snapshot: snapshot, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(resaved.workspace.id)))
        XCTAssertTrue(reloaded.isUndefined(at: 0x1_0000_0000))
        XCTAssertEqual(reloaded.patch(at: 0x1_0000_0014), BytePatch.arm64NOP)
        XCTAssertEqual(reloaded.addressOverrides.count, 2)
    }

    func testManualXRefsSurviveSaveSnapshotAndLoad() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.manualXRefs = [
            ManualXRef(from: 0x1_0000_0000, to: 0x1_0000_0040, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 0x1_0000_0008, to: 0x1_0000_0050, kind: XRefKind.data, isSuppression: true),
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Manual XRefs", snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.manualXRefs.count, 2)
        XCTAssertTrue(reloaded.manualXRefs.contains { $0.from == 0x1_0000_0000 && $0.to == 0x1_0000_0040 && !$0.isSuppression })
        XCTAssertTrue(reloaded.manualXRefs.contains { $0.from == 0x1_0000_0008 && $0.isSuppression && $0.kind == XRefKind.data })
    }

    func testBookmarksSurviveSaveSnapshotAndLoad() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.bookmarks = [
            Bookmark(address: 0x1_0000_0000, name: "entry"),
            Bookmark(address: 0x1_0000_0040, name: ""), // bare marker
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Bookmarks", snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.bookmarks.count, 2)
        XCTAssertEqual(reloaded.bookmark(at: 0x1_0000_0000)?.name, "entry")
        XCTAssertEqual(reloaded.bookmark(at: 0x1_0000_0040)?.name, "")
    }

    func testManualXRefsAndBookmarksSurviveReopenSaveWithoutUniqueAbort() throws {
        // FOOTGUN: a second save through a FRESH serialization DB of a workspace carrying
        // manual xrefs + bookmarks must not abort on their UNIQUE indexes.
        var snapshot = previewSnapshotWithMetadata()
        snapshot.manualXRefs = [
            ManualXRef(from: 0x1_0000_0000, to: 0x1_0000_0040, kind: XRefKind.call, isSuppression: false),
        ]
        snapshot.bookmarks = [Bookmark(address: 0x1_0000_0000, name: "entry")]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let secondURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: secondURL) }
        let database = try WorkspaceDatabase(path: secondURL.path)
        try database.applySchema()
        let resaved = try database.saveWorkspaceState(
            workspaceName: "MB", snapshot: snapshot, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        )
        let workspaceID = try XCTUnwrap(resaved.workspace.id)
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.manualXRefs.count, 1)
        XCTAssertEqual(reloaded.bookmark(at: 0x1_0000_0000)?.name, "entry")

        // Now exercise the IN-PLACE re-save path: replaceWorkspaceState runs
        // deleteSnapshotContents (which must DELETE from manual_xrefs + bookmarks) and
        // then re-INSERTs. A regression that dropped either DELETE would abort here on the
        // UNIQUE index, or leak stale rows. Re-save the SAME snapshot and assert counts
        // stay exactly 1 (no duplicate, no abort).
        _ = try database.replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: "MB", snapshot: snapshot, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: true, sidebarSearchText: "", now: now
        )
        let rereloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(rereloaded.manualXRefs.count, 1)
        XCTAssertEqual(rereloaded.bookmarks.count, 1)
        XCTAssertEqual(rereloaded.bookmark(at: 0x1_0000_0000)?.name, "entry")
    }

    func testApplySchemaMigratesVersion21To22() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll back to a v21 shape: drop the v22 columns/tables and mark user_version 21.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            DROP TABLE IF EXISTS manual_xrefs;
            DROP TABLE IF EXISTS bookmarks;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0,
              signature_json TEXT,
              applied_type_name TEXT,
              switch_hint_json TEXT,
              operand_format TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL,
              mark_as_procedure INTEGER NOT NULL DEFAULT 0,
              data_shape_json TEXT
            );
            CREATE UNIQUE INDEX idx_address_overrides_workspace_address
              ON address_overrides(workspace_id, address);
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '21000000-0000-0000-0000-000000000021', 'V21', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 21;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("is_undefined"))
        XCTAssertFalse(try migrated.tableNames().contains("bookmarks"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("is_undefined"))
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("patch_json"))
        XCTAssertTrue(try migrated.tableNames().contains("manual_xrefs"))
        XCTAssertTrue(try migrated.tableNames().contains("bookmarks"))

        // The pre-existing v21 row survives the ALTER with NULL new columns.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.customName, "legacyName")
        XCTAssertFalse(record.isUndefined)
        XCTAssertNil(record.patchJSON)
    }

    func testTagAndColorOverridesSurviveSaveSnapshotAndLoad() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", tag: "parser", colorTag: .blue),
            .primary(0x1_0000_0014): AddressOverride(colorTag: .red), // color-only override persists
            .primary(0x1_0000_0020): AddressOverride(tag: "TODO")     // tag-only override persists
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Tag/Color Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))

        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0000)],
                       AddressOverride(customName: "decodeFrame", tag: "parser", colorTag: .blue))
        XCTAssertEqual(reloaded.colorTag(at: 0x1_0000_0014), .red)
        XCTAssertEqual(reloaded.tag(at: 0x1_0000_0020), "TODO")
        XCTAssertEqual(reloaded.addressOverrides.count, 3)
    }

    func testApplySchemaMigratesVersion13To14AddingTagAndColorColumns() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll the address_overrides table back to its v13 shape (no tag/color),
        // seed a workspace + one override row, and mark the database as v13.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '13000000-0000-0000-0000-000000000013', 'V13', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, custom_comment, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', 'legacyComment', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 13;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("tag"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        let columns = Set(try migrated.columnNames(in: "address_overrides"))
        XCTAssertTrue(columns.contains("tag"))
        XCTAssertTrue(columns.contains("color_tag"))
        // The v13 path jumps straight to the current version, so it must add EVERY
        // later column too (a v13 DB previously reached v15 without is_data).
        XCTAssertTrue(columns.contains("is_data"))

        // The pre-existing v13 row survives the ALTER TABLE ADD COLUMN with NULL
        // tag/color and is_data defaulting to false — migration adds columns
        // without dropping authoring.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.address, 0x1_0000_0000)
        XCTAssertEqual(record.customName, "legacyName")
        XCTAssertNil(record.tag)
        XCTAssertNil(record.colorTag)
        XCTAssertFalse(record.isData)
    }

    func testReplaceWorkspaceStateReSavesOverridesWithoutUniqueCollision() throws {
        // Regression: the in-place re-save (second save of a workspace) must clear
        // existing address_overrides before re-inserting, or it collides with the
        // UNIQUE(workspace_id, address) index and aborts the save. Iterative
        // tag/color authoring makes repeated saves of override-bearing workspaces
        // the normal case.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = previewSnapshotWithMetadata()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", colorTag: .blue),
            .primary(0x1_0000_0014): AddressOverride(tag: "hot loop"),   // tag-only
            .primary(0x1_0000_0020): AddressOverride(colorTag: .red)      // color-only
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let persisted = try database.saveWorkspaceState(
            workspaceName: "Overrides",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: now
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        // The second save goes through replaceWorkspaceState — this previously threw
        // on the UNIQUE collision and aborted; it must now succeed.
        _ = try database.replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: "Overrides",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: now
        )

        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.addressOverrides[.primary(0x1_0000_0000)],
                       AddressOverride(customName: "decodeFrame", colorTag: .blue))
        XCTAssertEqual(reloaded.tag(at: 0x1_0000_0014), "hot loop")
        XCTAssertEqual(reloaded.colorTag(at: 0x1_0000_0020), .red)
        XCTAssertEqual(reloaded.addressOverrides.count, 3)
    }

    func testDataMarkSurvivesSaveSnapshotAndLoadAndPackageAnalysis() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", isData: false),
            .primary(0x1_0000_0014): AddressOverride(isData: true) // data-only override persists
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Data Mark Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertTrue(reloaded.isData(at: 0x1_0000_0014))
        XCTAssertFalse(reloaded.isData(at: 0x1_0000_0000))
        XCTAssertEqual(reloaded.addressOverrides.count, 2)

        // And through the .mscope package Codable round-trip.
        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: try JSONEncoder().encode(analysis))
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        XCTAssertTrue(reconstructed.isData(at: 0x1_0000_0014))
    }

    func testSignatureOverrideSurvivesSaveLoadAndPackageAnalysis() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let signature = FunctionSignatureOverride(
            returnType: "size_t",
            args: [ArgOverride(index: 0, name: "ctx", type: "Context*"), ArgOverride(index: 1, name: "len", type: "int")],
            isNoReturn: false
        )
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decode", signature: signature)
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Signature Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.signatureOverride(at: 0x1_0000_0000), signature)

        // And through the .mscope package JSON round-trip.
        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: try JSONEncoder().encode(analysis))
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        XCTAssertEqual(reconstructed.signatureOverride(at: 0x1_0000_0000), signature)
    }

    func testUnspecifiedAndAuthoritativeEmptySignatureListsRemainDistinctAcrossPersistence() throws {
        let returnOnlyAddress: UInt64 = 0x1_0000_0000
        let explicitVoidAddress: UInt64 = 0x1_0000_0014
        let returnOnly = FunctionSignatureOverride(returnType: "size_t")
        let explicitVoid = FunctionSignatureOverride.authoritative(
            returnType: "int",
            args: [],
            variadicState: .fixed
        )

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(returnOnlyAddress): AddressOverride(signature: returnOnly),
            .primary(explicitVoidAddress): AddressOverride(signature: explicitVoid),
        ]

        func assertListPresence(in restored: WorkspaceSnapshot) throws {
            let restoredReturnOnly = try XCTUnwrap(restored.signatureOverride(at: returnOnlyAddress))
            guard case .unspecified = restoredReturnOnly.parameterList else {
                return XCTFail("a return-only override must preserve an unspecified parameter list")
            }
            XCTAssertEqual(restoredReturnOnly.returnType, "size_t")
            XCTAssertEqual(restoredReturnOnly.variadicState, .unspecified)

            let restoredExplicitVoid = try XCTUnwrap(restored.signatureOverride(at: explicitVoidAddress))
            guard case let .authoritative(rows) = restoredExplicitVoid.parameterList else {
                return XCTFail("an encoded empty parameterList must remain authoritative")
            }
            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(restoredExplicitVoid.returnType, "int")
            XCTAssertEqual(restoredExplicitVoid.variadicState, .fixed)
        }

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Signature List Presence",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try assertListPresence(
            in: XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        )

        let packageData = try JSONEncoder().encode(WorkspacePackageAnalysis(snapshot: snapshot))
        let packageAnalysis = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: packageData)
        try assertListPresence(
            in: packageAnalysis.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        )
    }

    func testSignatureRowsVariadicStateAndQuarantineRoundTripExactlyThroughDatabaseAndPackage() throws {
        let address: UInt64 = 0x1_0000_0000
        let rows = [
            ArgOverride(rowToken: "row-z", name: "ratio", type: "double", provenance: .debug),
            ArgOverride(rowToken: "row-a", name: "context", type: "const int *", provenance: .script),
            ArgOverride(rowToken: "row-m", name: "count", type: "size_t", provenance: .user),
        ]
        let quarantine = [
            LegacyArgOverride(originalIndex: 4, originalOrder: 0, name: "legacyRatio", type: "double"),
            LegacyArgOverride(originalIndex: 0, originalOrder: 1, name: "legacyCount", type: "int"),
        ]
        let signature = FunctionSignatureOverride(
            returnType: "ssize_t",
            parameterList: .authoritative(rows),
            variadicState: .variadic,
            quarantinedLegacyArgs: quarantine
        )

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(address): AddressOverride(customName: "consume", signature: signature)
        ]

        func assertExactSignature(in restored: WorkspaceSnapshot) throws {
            let restored = try XCTUnwrap(restored.signatureOverride(at: address))
            XCTAssertEqual(restored, signature)
            XCTAssertEqual(restored.args.map(\.index), [0, 1, 2])
            XCTAssertEqual(restored.args.map(\.rowToken), ["row-z", "row-a", "row-m"])
            XCTAssertEqual(restored.args.map(\.name), ["ratio", "context", "count"])
            XCTAssertEqual(restored.args.map(\.type), ["double", "const int *", "size_t"])
            XCTAssertEqual(restored.args.map(\.provenance), [.debug, .script, .user])
            XCTAssertEqual(restored.variadicState, .variadic)
            XCTAssertEqual(restored.quarantinedLegacyArgs, quarantine)
        }

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Exact Signature Identity",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let storedRecord = try XCTUnwrap(database.addressOverrides(workspaceID: workspaceID).first)
        let storedJSON = try XCTUnwrap(storedRecord.signatureJSON)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? [String: Any]
        )
        let storedRows = try XCTUnwrap(storedObject["parameterList"] as? [[String: Any]])
        XCTAssertEqual(storedRows.map { $0["rowToken"] as? String }, ["row-z", "row-a", "row-m"])
        XCTAssertEqual(storedRows.map { $0["provenance"] as? String }, ["debug", "script", "user"])
        XCTAssertTrue(storedRows.allSatisfy { $0["index"] == nil })
        XCTAssertEqual(storedObject["variadicState"] as? String, "variadic")

        try assertExactSignature(
            in: XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        )

        let packageData = try JSONEncoder().encode(WorkspacePackageAnalysis(snapshot: snapshot))
        let packageAnalysis = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: packageData)
        try assertExactSignature(
            in: packageAnalysis.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        )
    }

    func testQuarantineOnlySignaturePersistsButIsExcludedFromAnalysisProjection() throws {
        let address: UInt64 = 0x1_0000_0000
        let signature = FunctionSignatureOverride(quarantinedLegacyArgs: [
            LegacyArgOverride(originalIndex: 3, originalOrder: 0, name: "ratio", type: "double"),
            LegacyArgOverride(originalIndex: 0, originalOrder: 1, name: "count", type: "int"),
        ])
        XCTAssertTrue(signature.hasPersistedPayload)
        XCTAssertFalse(signature.hasAnalysisEffect)

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(address): AddressOverride(signature: signature)
        ]

        func assertPersistedButInert(in restored: WorkspaceSnapshot) throws {
            XCTAssertEqual(restored.signatureOverride(at: address), signature)
            XCTAssertNil(restored.functionSignatureOverrides(in: .primary)[address])
        }

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Quarantined Signature",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        XCTAssertNotNil(try database.addressOverrides(workspaceID: workspaceID).first?.signatureJSON)
        try assertPersistedButInert(
            in: XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        )

        let packageData = try JSONEncoder().encode(WorkspacePackageAnalysis(snapshot: snapshot))
        let packageAnalysis = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: packageData)
        XCTAssertEqual(packageAnalysis.addressOverrides.count, 1)
        try assertPersistedButInert(
            in: packageAnalysis.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        )
    }

    func testMalformedNestedSignatureDropsLocallyWhileSiblingOverrideFieldsSurvive() throws {
        let address: UInt64 = 0x1_0000_0000
        let validSignature = FunctionSignatureOverride.authoritative(
            args: [ArgOverride(rowToken: "row-0", name: "value", type: "int", provenance: .user)]
        )
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(address): AddressOverride(
                customName: "decode",
                customComment: "keep this comment",
                tag: "parser",
                isData: true,
                signature: validSignature
            )
        ]

        func assertSiblingsSurvive(in restored: WorkspaceSnapshot) throws {
            let override = try XCTUnwrap(restored.addressOverrides[.primary(address)])
            XCTAssertEqual(override.customName, "decode")
            XCTAssertEqual(override.customComment, "keep this comment")
            XCTAssertEqual(override.tag, "parser")
            XCTAssertTrue(override.isData)
            XCTAssertNil(override.signature)
        }

        let malformedSignature =
            #"{"schemaVersion":2,"parameterList":[{"rowToken":"row-0","name":"value","type":17,"provenance":"user"}],"variadicState":"fixed","isNoReturn":false}"#

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Malformed Nested Signature",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting(
            "UPDATE address_overrides SET signature_json = '\(malformedSignature)' WHERE workspace_id = \(workspaceID);"
        )
        try assertSiblingsSurvive(
            in: XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        )

        let packageJSON =
            """
            {
              "addressOverrides": [
                {
                  "address": \(address),
                  "override": {
                    "customName": "decode",
                    "customComment": "keep this comment",
                    "tag": "parser",
                    "isData": true,
                    "signature": \(malformedSignature)
                  }
                }
              ]
            }
            """
        let packageAnalysis = try JSONDecoder().decode(
            WorkspacePackageAnalysis.self,
            from: Data(packageJSON.utf8)
        )
        try assertSiblingsSurvive(
            in: packageAnalysis.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        )
    }

    func testApplySchemaMigratesVersion15To16AddingSignatureColumn() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll the table back to its v15 shape (no signature_json), seed a workspace
        // + one override row, and mark the database as v15.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '15000000-0000-0000-0000-000000000015', 'V15', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, is_data, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 15;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("signature_json"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("signature_json"))

        // The pre-existing v15 row survives with signature_json NULL.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.customName, "legacyName")
        XCTAssertNil(record.signatureJSON)
    }

    func testTypeDefinitionsAndAppliedTypeSurviveSaveSnapshotAndLoad() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let header = TypeDefinition(kind: .struct, name: "Header", fields: [
            FieldDef(name: "magic", type: "uint32_t"),
            FieldDef(name: "next", type: "Header*")
        ])
        let tag = TypeDefinition(kind: .enum, name: "Tag", fields: [FieldDef(name: "first", type: "")])
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [header, tag]
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decode", appliedTypeName: "Header")
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Type Catalog Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))

        XCTAssertEqual(reloaded.typeDefinitions.sorted { $0.name < $1.name }, [header, tag])
        XCTAssertEqual(reloaded.appliedType(at: 0x1_0000_0000), header)
    }

    func testTypeDefinitionsPersistThroughPackageAnalysis() throws {
        let header = TypeDefinition(kind: .struct, name: "Header", fields: [FieldDef(name: "magic", type: "uint32_t")])
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [header]
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(appliedTypeName: "Header")
        ]

        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: try JSONEncoder().encode(analysis))
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        XCTAssertEqual(reconstructed.typeDefinitions, [header])
        XCTAssertEqual(reconstructed.appliedType(at: 0x1_0000_0000), header)
    }

    func testPackageAnalysisWithoutTypeDefinitionsKeyDecodesEmpty() throws {
        // Backward compatibility: a pre-type-catalog manifest (no typeDefinitions
        // key) decodes with an empty catalog.
        let json = "{\"functions\":[],\"instructions\":[],\"xrefs\":[]}"
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.typeDefinitions.isEmpty)
        XCTAssertTrue(decoded.snapshot(binaries: [], hexBytes: Data()).typeDefinitions.isEmpty)
    }

    func testApplySchemaMigratesVersion16To17AddingTypeDefinitions() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll back to a v16 database by dropping the v17 catalog table and seeding a
        // workspace + one override row, then mark the database as v16.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_type_definitions_workspace_name;
            DROP TABLE IF EXISTS type_definitions;
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '16000000-0000-0000-0000-000000000016', 'V16', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, is_data, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 16;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.tableNames().contains("type_definitions"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("type_definitions"))
        // The pre-existing override row is untouched by the catalog migration.
        XCTAssertEqual(try migrated.addressOverrides(workspaceID: 1).first?.customName, "legacyName")
    }

    func testReplaceWorkspaceStateReSavesTypeDefinitionsWithoutUniqueCollision() throws {
        // Regression mirror of the address_overrides re-save: type_definitions has a
        // UNIQUE(workspace_id, name) index, so the in-place re-save must clear the
        // catalog before re-inserting or the second save aborts on the collision.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = previewSnapshotWithMetadata()
        snapshot.typeDefinitions = [
            TypeDefinition(kind: .struct, name: "Header", fields: [FieldDef(name: "magic", type: "uint32_t")]),
            TypeDefinition(kind: .union, name: "Word", fields: [FieldDef(name: "raw", type: "uint64_t")])
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let persisted = try database.saveWorkspaceState(
            workspaceName: "Types",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: now
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        _ = try database.replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: "Types",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: now
        )

        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(Set(reloaded.typeDefinitions.map(\.name)), ["Header", "Word"])
        XCTAssertEqual(reloaded.typeDefinitions.count, 2)
    }

    func testSaveSnapshotToleratesDuplicateTypeNamesWithoutAborting() throws {
        // Defense-in-depth: the authoring layer enforces unique names, but a
        // hand-edited/legacy .mscope could carry two catalog entries with distinct
        // ids and the SAME name. UNIQUE(workspace_id, name) must NOT abort the whole
        // snapshot-write transaction — INSERT OR REPLACE keeps the last writer.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [
            TypeDefinition(kind: .struct, name: "Header", fields: [FieldDef(name: "a", type: "int32_t")]),
            TypeDefinition(kind: .union, name: "Header", fields: [FieldDef(name: "b", type: "int64_t")])
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Dup Names",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.typeDefinitions.count, 1)
        XCTAssertEqual(reloaded.typeDefinitions.first?.name, "Header")
    }

    func testSwitchHintSurvivesSaveLoadAndPackageAnalysis() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let hint = SwitchHintOverride(tableBase: 0x1_0000_2000, entryCount: 4, entryStride: 8, isRelativeToBase: false)
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "dispatch", switchHint: hint)
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Switch Hint Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.switchHint(at: 0x1_0000_0000), hint)

        // And through the .mscope package JSON round-trip (rides AddressOverride).
        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: try JSONEncoder().encode(analysis))
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        XCTAssertEqual(reconstructed.switchHint(at: 0x1_0000_0000), hint)
    }

    func testApplySchemaMigratesVersion17To18AddingSwitchHintColumn() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll the table back to its v17 shape (no switch_hint_json), seed a workspace
        // + one override row, and mark the database as v17.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0,
              signature_json TEXT,
              applied_type_name TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '17000000-0000-0000-0000-000000000017', 'V17', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, is_data, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 17;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("switch_hint_json"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("switch_hint_json"))

        // The pre-existing v17 row survives with switch_hint_json NULL.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.customName, "legacyName")
        XCTAssertNil(records.first?.switchHintJSON)
    }

    func testDataXRefKindsRoundTripThroughSaveSnapshotAndLoad() throws {
        // Data xrefs are materialized into snapshot.xrefs (not derived), so the new
        // kinds must survive the SQLite save/load like any other xref.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.xrefs = [
            XRef(id: UUID(), from: 0x1_0000_0000, to: 0x1_0000_1000, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1_0000_0004, to: 0x1_0000_4010, kind: XRefKind.string),
            XRef(id: UUID(), from: 0x1_0000_0008, to: 0x1_0000_8040, kind: XRefKind.selref),
            XRef(id: UUID(), from: 0x1_0000_000c, to: 0x1_0000_c008, kind: XRefKind.data)
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "XRef Kinds Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(Set(reloaded.xrefs.map(\.kind)), ["call", "string", "selref", "data"])
        XCTAssertEqual(reloaded.xrefs(to: 0x1_0000_4010).first?.kind, XRefKind.string)
        XCTAssertEqual(reloaded.xrefs(from: 0x1_0000_0008).first?.kind, XRefKind.selref)
    }

    func testOperandFormatSurvivesSaveLoadAndPackageAnalysis() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decode", operandFormat: .character)
        ]

        let workspace = try database.saveSnapshot(
            workspaceName: "Operand Format Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.operandFormat(at: 0x1_0000_0000), .character)

        // And through the .mscope package JSON round-trip (rides AddressOverride).
        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: try JSONEncoder().encode(analysis))
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)
        XCTAssertEqual(reconstructed.operandFormat(at: 0x1_0000_0000), .character)
    }

    func testApplySchemaMigratesVersion18To19AddingOperandFormatColumn() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll the table back to its v18 shape (switch_hint_json present, no
        // operand_format), seed a workspace + one override row, mark the DB v18.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0,
              signature_json TEXT,
              applied_type_name TEXT,
              switch_hint_json TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '18000000-0000-0000-0000-000000000018', 'V18', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, is_data, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 18;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("operand_format"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("operand_format"))

        // The pre-existing v18 row survives with operand_format NULL.
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.customName, "legacyName")
        XCTAssertNil(records.first?.operandFormat)
    }

    func testApplySchemaMigratesVersion14To15AddingIsDataColumn() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
        }

        // Roll the table back to its v14 shape (tag/color but no is_data), seed a
        // workspace + one override row, and mark the database as v14.
        try executeSQLiteStatements(
            """
            DROP INDEX IF EXISTS idx_address_overrides_workspace_address;
            DROP TABLE IF EXISTS address_overrides;
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              tag TEXT,
              color_tag TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '14000000-0000-0000-0000-000000000014', 'V14', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO address_overrides (workspace_id, address, custom_name, custom_comment, created_at, modified_at)
              VALUES (1, 4294967296, 'legacyName', NULL, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 14;
            """,
            to: databaseURL
        )

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertFalse(try migrated.columnNames(in: "address_overrides").contains("is_data"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.columnNames(in: "address_overrides").contains("is_data"))

        // The pre-existing v14 row survives, defaulting is_data to 0 (code).
        let records = try migrated.addressOverrides(workspaceID: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.customName, "legacyName")
        XCTAssertFalse(record.isData)
    }

    func testTagAndColorPersistThroughPackageAnalysis() throws {
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(customName: "decodeFrame", tag: "parser", colorTag: .green)
        ]

        let analysis = WorkspacePackageAnalysis(snapshot: snapshot)
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
        let reconstructed = decoded.snapshot(binaries: snapshot.binaries, hexBytes: snapshot.hexBytes)

        XCTAssertEqual(reconstructed.addressOverrides[.primary(0x1_0000_0000)],
                       AddressOverride(customName: "decodeFrame", tag: "parser", colorTag: .green))
    }

    func testPackageAnalysisDecodesUnknownColorTagAsNil() throws {
        // Forward compatibility: a colorTag this build doesn't recognize (e.g. a
        // palette entry added by a newer version) degrades to nil rather than
        // throwing and failing the entire package load.
        let json = """
        {"functions":[],"instructions":[],"xrefs":[],"addressOverrides":[\
        {"address":4294967296,"override":{"customName":"decodeFrame","colorTag":"chartreuse"}}]}
        """
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: Data(json.utf8))
        let override = try XCTUnwrap(decoded.addressOverrides.first?.override)
        XCTAssertEqual(override.customName, "decodeFrame")
        XCTAssertNil(override.colorTag)
    }

    func testPackageAnalysisDecodesOverrideWithoutTagOrColorKeys() throws {
        // Backward compatibility: a pre-tag/color manifest entry (only customName)
        // decodes with nil tag/color rather than failing.
        let json = """
        {"functions":[],"instructions":[],"xrefs":[],"addressOverrides":[\
        {"address":4294967296,"override":{"customName":"decodeFrame"}}]}
        """
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: Data(json.utf8))
        let override = try XCTUnwrap(decoded.addressOverrides.first?.override)
        XCTAssertEqual(override.customName, "decodeFrame")
        XCTAssertNil(override.tag)
        XCTAssertNil(override.colorTag)
    }

    func testWorkspaceStateRoundTripIncludesSessionState() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = previewSnapshotWithMetadata()
        let functionID = try XCTUnwrap(snapshot.functions.last?.id)
        let selectedSidebarItemID = "function:\(functionID.uuidString)"
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let persisted = try database.saveWorkspaceState(
            workspaceName: "State Round Trip",
            snapshot: snapshot,
            selectedSidebarItemID: selectedSidebarItemID,
            selectedAddress: 0x1000_02000,
            selectedTool: .xrefs,
            editorMode: .pseudocode,
            isInspectorPresented: false,
            sidebarSearchText: "main",
            now: now
        )
        let loaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(persisted.workspace.id)))

        XCTAssertEqual(loaded.workspace.name, "State Round Trip")
        XCTAssertEqual(loaded.session.workspaceID, try XCTUnwrap(persisted.workspace.id))
        XCTAssertEqual(loaded.session.selectedSidebarItemID, selectedSidebarItemID)
        XCTAssertEqual(loaded.session.selectedAddress, 0x1000_02000)
        XCTAssertEqual(loaded.session.selectedTool, .xrefs)
        XCTAssertEqual(loaded.session.editorMode, .pseudocode)
        XCTAssertEqual(loaded.session.isInspectorPresented, false)
        XCTAssertEqual(loaded.session.sidebarSearchText, "main")
        XCTAssertEqual(loaded.session.updatedAt, now)
        XCTAssertEqual(loaded.snapshot.binaries, snapshot.binaries)
        XCTAssertEqual(loaded.snapshot.functions, snapshot.functions)
        XCTAssertEqual(loaded.snapshot.symbols, snapshot.symbols)
        XCTAssertEqual(loaded.snapshot.imports, snapshot.imports)
        XCTAssertEqual(loaded.snapshot.indirectSymbols, snapshot.indirectSymbols)
        XCTAssertEqual(loaded.snapshot.exports, snapshot.exports)
        XCTAssertEqual(loaded.snapshot.stringLiterals, snapshot.stringLiterals)
        XCTAssertEqual(loaded.snapshot.basicBlocks, snapshot.basicBlocks)
        XCTAssertEqual(loaded.snapshot.instructions, snapshot.instructions)
        XCTAssertEqual(loaded.snapshot.xrefs, snapshot.xrefs)
        XCTAssertEqual(loaded.snapshot.controlFlowEdges, snapshot.controlFlowEdges)
        XCTAssertEqual(loaded.snapshot.hexBytes, snapshot.hexBytes)
    }

    func testReplaceWorkspaceStateUpdatesExistingWorkspaceInPlace() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let initialSnapshot = previewSnapshotWithMetadata()
        let replacementSnapshot = AnalysisEngine.previewSnapshot()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_120)

        let persisted = try database.saveWorkspaceState(
            workspaceName: "Initial Workspace",
            snapshot: initialSnapshot,
            selectedSidebarItemID: "binary:\(initialSnapshot.binaries[0].id.uuidString)",
            selectedAddress: initialSnapshot.instructions.first?.address,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: createdAt
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        let replaced = try database.replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: "Updated Workspace",
            snapshot: replacementSnapshot,
            selectedSidebarItemID: "function:\(replacementSnapshot.functions[1].id.uuidString)",
            selectedAddress: replacementSnapshot.functions[1].startAddress,
            selectedTool: .symbols,
            editorMode: .pseudocode,
            isInspectorPresented: false,
            sidebarSearchText: "analyze",
            now: modifiedAt
        )
        let reloaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))

        XCTAssertEqual(try database.workspaces().count, 1)
        XCTAssertEqual(replaced.workspace.id, workspaceID)
        XCTAssertEqual(replaced.workspace.uuid, persisted.workspace.uuid)
        XCTAssertEqual(replaced.workspace.name, "Updated Workspace")
        XCTAssertEqual(replaced.workspace.createdAt, createdAt)
        XCTAssertEqual(replaced.workspace.modifiedAt, modifiedAt)
        XCTAssertEqual(reloaded.workspace, replaced.workspace)
        XCTAssertEqual(reloaded.snapshot.binaries, replacementSnapshot.binaries)
        XCTAssertEqual(reloaded.snapshot.functions, replacementSnapshot.functions)
        XCTAssertEqual(reloaded.snapshot.indirectSymbols, replacementSnapshot.indirectSymbols)
        XCTAssertEqual(reloaded.snapshot.instructions, replacementSnapshot.instructions)
        XCTAssertEqual(reloaded.session.selectedSidebarItemID, "function:\(replacementSnapshot.functions[1].id.uuidString)")
        XCTAssertEqual(reloaded.session.selectedAddress, replacementSnapshot.functions[1].startAddress)
        XCTAssertEqual(reloaded.session.selectedTool, .symbols)
        XCTAssertEqual(reloaded.session.editorMode, .pseudocode)
        XCTAssertEqual(reloaded.session.isInspectorPresented, false)
        XCTAssertEqual(reloaded.session.sidebarSearchText, "analyze")
        XCTAssertEqual(try database.binaries(workspaceID: workspaceID).count, replacementSnapshot.binaries.count)
    }

    func testFileBackedWorkspaceStateSurvivesDatabaseReopen() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = previewSnapshotWithMetadata()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selectedXRefID = try XCTUnwrap(snapshot.xrefs.first?.id)
        let workspaceID: Int64

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            let persisted = try database.saveWorkspaceState(
                workspaceName: "File Backed",
                snapshot: snapshot,
                selectedSidebarItemID: "xref:\(selectedXRefID.uuidString)",
                selectedAddress: 0x1000_00014,
                selectedTool: .xrefs,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "analyze",
                now: now
            )
            workspaceID = try XCTUnwrap(persisted.workspace.id)
        }

        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        try reopened.applySchema()
        let loaded = try XCTUnwrap(reopened.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(loaded.workspace.name, "File Backed")
        XCTAssertEqual(loaded.session.selectedTool, .xrefs)
        XCTAssertEqual(loaded.session.selectedAddress, 0x1000_00014)
        XCTAssertEqual(loaded.session.sidebarSearchText, "analyze")
        XCTAssertEqual(loaded.snapshot.symbols, snapshot.symbols)
        XCTAssertEqual(loaded.snapshot.imports, snapshot.imports)
        XCTAssertEqual(loaded.snapshot.indirectSymbols, snapshot.indirectSymbols)
        XCTAssertEqual(loaded.snapshot.exports, snapshot.exports)
        XCTAssertEqual(loaded.snapshot.stringLiterals, snapshot.stringLiterals)
        XCTAssertEqual(loaded.snapshot.instructions, snapshot.instructions)
        XCTAssertEqual(loaded.snapshot.hexBytes, snapshot.hexBytes)
    }

    func testDocumentPackageAttachmentPathsAreStableAndPackageRelative() throws {
        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let originalPath = "/tmp/../Analyze: Demo\t.bin"

        let relativePath = MacScopeDocumentPackage.attachmentRelativePath(
            for: binaryID,
            originalPath: originalPath
        )

        XCTAssertEqual(
            relativePath,
            "attachments/22222222-2222-2222-2222-222222222222/Analyze_ Demo_.bin"
        )
        XCTAssertEqual(
            relativePath,
            MacScopeDocumentPackage.attachmentRelativePath(for: binaryID, originalPath: originalPath)
        )
        XCTAssertFalse(relativePath.hasPrefix("/"))
        XCTAssertFalse(relativePath.split(separator: "/").contains(".."))

        let packageURL = URL(fileURLWithPath: "/tmp/Workspace.mscope", isDirectory: true)
        XCTAssertEqual(
            MacScopeDocumentPackage.attachmentURL(
                in: packageURL,
                for: binaryID,
                originalPath: originalPath
            ).path,
            "/tmp/Workspace.mscope/\(relativePath)"
        )
    }

    func testWorkspacePackageManifestRoundTripUsesDatabaseSourceOfTruth() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let documentID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var snapshot = previewSnapshotWithMetadata()
        snapshot.binaries = [
            BinaryImage(
                id: binaryID,
                name: "Analyze Demo",
                path: "/tmp/Analyze: Demo\t.bin",
                kind: "synthetic fixture",
                architecture: "arm64"
            )
        ]
        installPreviewLogicalBreakpointCatalog(in: &snapshot)
        let selectedFunctionID = try XCTUnwrap(snapshot.functions.first?.id)
        let selectedAddress = try XCTUnwrap(snapshot.instructions.first?.address)

        let persisted = try database.saveWorkspaceState(
            workspaceName: "Package Source",
            snapshot: snapshot,
            selectedSidebarItemID: "function:\(selectedFunctionID.uuidString)",
            selectedAddress: selectedAddress,
            selectedTool: .symbols,
            editorMode: .graph,
            isInspectorPresented: false,
            sidebarSearchText: "_main",
            now: now
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        let manifest = try XCTUnwrap(
            database.packageManifest(
                workspaceID: workspaceID,
                documentID: documentID,
                inputCopyingDecision: .referenceOriginalInputs,
                bookmarkResolutionDecision: .promptForMissingInputs
            )
        )

        XCTAssertEqual(manifest.formatIdentifier, MacScopeDocumentPackage.formatIdentifier)
        XCTAssertEqual(manifest.formatVersion, WorkspacePackageManifest.currentFormatVersion)
        XCTAssertEqual(manifest.documentID, documentID)
        XCTAssertEqual(manifest.workspaceUUID, persisted.workspace.uuid)
        XCTAssertEqual(manifest.workspaceName, "Package Source")
        XCTAssertEqual(manifest.createdAt, now)
        XCTAssertEqual(manifest.modifiedAt, now)
        XCTAssertEqual(manifest.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(manifest.bookmarkResolutionDecision, .promptForMissingInputs)

        XCTAssertEqual(manifest.binaries.count, 1)
        let manifestBinary = try XCTUnwrap(manifest.binaries.first)
        XCTAssertEqual(manifestBinary.id, binaryID)
        XCTAssertEqual(manifestBinary.displayName, "Analyze Demo")
        XCTAssertEqual(manifestBinary.originalPath, "/tmp/Analyze: Demo\t.bin")
        XCTAssertEqual(
            manifestBinary.attachmentRelativePath,
            "attachments/22222222-2222-2222-2222-222222222222/Analyze_ Demo_.bin"
        )
        XCTAssertEqual(manifestBinary.kind, "synthetic fixture")
        XCTAssertEqual(manifestBinary.architecture, "arm64")
        XCTAssertEqual(manifestBinary.fileHash, MacScopeDocumentPackage.fileHash(for: snapshot.hexBytes))
        XCTAssertEqual(manifestBinary.fileSize, Int64(snapshot.hexBytes.count))

        let manifestSession = try XCTUnwrap(manifest.session)
        XCTAssertEqual(manifestSession.selectedSidebarItemID, "function:\(selectedFunctionID.uuidString)")
        XCTAssertEqual(manifestSession.selectedAddress, selectedAddress)
        XCTAssertEqual(manifestSession.selectedTool, .symbols)
        XCTAssertEqual(manifestSession.editorMode, .graph)
        XCTAssertEqual(manifestSession.isInspectorPresented, false)
        XCTAssertEqual(manifestSession.sidebarSearchText, "_main")
        XCTAssertEqual(manifestSession.updatedAt, now)

        let analysis = try XCTUnwrap(manifest.analysis)
        XCTAssertEqual(analysis.functions, snapshot.functions)
        XCTAssertEqual(analysis.symbols, snapshot.symbols)
        XCTAssertEqual(analysis.imports, snapshot.imports)
        XCTAssertEqual(analysis.indirectSymbols, snapshot.indirectSymbols)
        XCTAssertEqual(analysis.exports, snapshot.exports)
        XCTAssertEqual(analysis.stringLiterals, snapshot.stringLiterals)
        XCTAssertEqual(analysis.basicBlocks, snapshot.basicBlocks)
        XCTAssertEqual(analysis.instructions, snapshot.instructions)
        XCTAssertEqual(analysis.xrefs, snapshot.xrefs)
        XCTAssertEqual(analysis.controlFlowEdges, snapshot.controlFlowEdges)

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: MacScopeDocumentPackage.manifestURL(in: packageURL).path)
        )
        XCTAssertEqual(try MacScopeDocumentPackage.readManifest(from: packageURL), manifest)
    }

    func testWorkspaceDatabaseWritePackageUsesDatabaseAttachmentSourceOfTruth() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let documentID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        var snapshot = previewSnapshotWithMetadata()
        snapshot.binaries = [
            BinaryImage(
                id: binaryID,
                name: "Analyze Demo",
                path: "/tmp/Analyze Demo.bin",
                kind: "synthetic fixture",
                architecture: "arm64"
            )
        ]
        installPreviewLogicalBreakpointCatalog(in: &snapshot)
        snapshot.hexBytes = Data([0xca, 0xfe, 0xba, 0xbe])
        // The DB attachment is the exact-slice PAYLOAD (imageBytes); the hex window is a derived
        // prefix of it. Set both to the sentinel so the fixture is internally consistent with the
        // payload model (window == payload here) and the persisted attachment is this sentinel.
        snapshot.imageBytes = Data([0xca, 0xfe, 0xba, 0xbe])
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let persisted = try database.saveWorkspaceState(
            workspaceName: "Package Write",
            snapshot: snapshot,
            selectedSidebarItemID: "binary:\(binaryID.uuidString)",
            selectedAddress: snapshot.instructions.first?.address,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: now
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        let manifest = try database.writePackage(
            workspaceID: workspaceID,
            documentID: documentID,
            to: packageURL,
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .usePackageAttachmentsOnly
        )
        let manifestBinary = try XCTUnwrap(manifest.binaries.first)
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: manifestBinary.attachmentRelativePath
        )

        XCTAssertEqual(manifest.documentID, documentID)
        XCTAssertEqual(manifest.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(manifest.bookmarkResolutionDecision, .usePackageAttachmentsOnly)
        XCTAssertEqual(manifestBinary.fileSize, Int64(snapshot.hexBytes.count))
        XCTAssertEqual(manifestBinary.fileHash, MacScopeDocumentPackage.fileHash(for: snapshot.hexBytes))
        XCTAssertEqual(try Data(contentsOf: attachmentURL), snapshot.hexBytes)
        // Since T1 (#436) every save canonicalises to v4 with an instruction sidecar, and
        // writePackage returns exactly the manifest it wrote (§4.77).
        XCTAssertEqual(manifest.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
        XCTAssertNotNil(manifest.instructionSidecar)
        XCTAssertEqual(
            try MacScopeDocumentPackage.readManifest(from: packageURL, requireAttachments: true),
            manifest
        )

        let document = try XCTUnwrap(database.workspaceDocument(workspaceID: workspaceID))
        XCTAssertEqual(document.workspaceID, workspaceID)
        XCTAssertEqual(document.documentID, documentID)
        XCTAssertEqual(document.packagePath, packageURL.standardizedFileURL.path)
        XCTAssertEqual(document.lastOpenedAt, now)
        XCTAssertEqual(document.lastSavedAt, now)
        XCTAssertFalse(document.isDirty)
        XCTAssertNil(document.fileVersionIdentifier)
        XCTAssertNil(document.conflictDetectedAt)
        XCTAssertNil(document.conflictReason)
        XCTAssertEqual(document.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(document.bookmarkResolutionDecision, .usePackageAttachmentsOnly)
        XCTAssertNil(document.bookmarkResolutionError)
        XCTAssertEqual(document.recentDocumentState, .available)
        XCTAssertEqual(document.recentDocumentStateUpdatedAt, now)
    }

    func testWorkspacePackageWriteStagesReplacementAndRemovesStaleAttachments() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let oldBinaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let newBinaryID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let oldData = Data([0xca, 0xfe, 0xba, 0xbe])
        let newData = Data([0xde, 0xad, 0xfa, 0xce, 0x01])

        func manifest(binaryID: UUID, workspaceName: String, originalPath: String, data: Data) -> WorkspacePackageManifest {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            return WorkspacePackageManifest(
                documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
                workspaceUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                workspaceName: workspaceName,
                createdAt: now,
                modifiedAt: now,
                binaries: [
                    WorkspacePackageBinary(
                        id: binaryID,
                        displayName: URL(fileURLWithPath: originalPath).deletingPathExtension().lastPathComponent,
                        originalPath: originalPath,
                        attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                            for: binaryID,
                            originalPath: originalPath
                        ),
                        kind: "synthetic fixture",
                        architecture: "arm64",
                        fileHash: MacScopeDocumentPackage.fileHash(for: data),
                        fileSize: Int64(data.count)
                    )
                ],
                session: WorkspacePackageSession(
                    selectedSidebarItemID: "binary:\(binaryID.uuidString)",
                    selectedAddress: 0x1000_00000,
                    selectedTool: .project,
                    editorMode: .disassembly,
                    isInspectorPresented: true,
                    sidebarSearchText: "",
                    updatedAt: now
                )
            )
        }

        // Since T1 (#436) writePackage stores every legacy manifest as v4 plus an instruction
        // sidecar, so the on-disk manifest is the canonical v4 form of what was written.
        func savedForm(_ manifest: WorkspacePackageManifest) throws -> WorkspacePackageManifest {
            try MacScopeDocumentPackage.preparedInstructionStorage(
                MacScopeDocumentPackage.preparedManifest(manifest, reconstructionState: .empty)
            ).manifest
        }

        let oldManifest = manifest(
            binaryID: oldBinaryID,
            workspaceName: "Original Package",
            originalPath: "/tmp/Original Demo.bin",
            data: oldData
        )
        try MacScopeDocumentPackage.writePackage(
            oldManifest,
            attachmentsByBinaryID: [oldBinaryID: oldData],
            to: packageURL
        )

        let oldBinary = try XCTUnwrap(oldManifest.binaries.first)
        let oldAttachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: oldBinary.attachmentRelativePath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAttachmentURL.path))

        let newManifest = manifest(
            binaryID: newBinaryID,
            workspaceName: "Replacement Package",
            originalPath: "/tmp/Replacement Demo.bin",
            data: newData
        )

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                newManifest,
                attachmentsByBinaryID: [:],
                to: packageURL
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .missingAttachment(newManifest.binaries[0].attachmentRelativePath)
            )
        }
        XCTAssertEqual(
            try MacScopeDocumentPackage.readManifest(from: packageURL, requireAttachments: true),
            try savedForm(oldManifest)
        )
        XCTAssertEqual(try Data(contentsOf: oldAttachmentURL), oldData)

        try MacScopeDocumentPackage.writePackage(
            newManifest,
            attachmentsByBinaryID: [newBinaryID: newData],
            to: packageURL
        )

        let newBinary = try XCTUnwrap(newManifest.binaries.first)
        let newAttachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: newBinary.attachmentRelativePath
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAttachmentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAttachmentURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: newAttachmentURL), newData)
        XCTAssertEqual(
            try MacScopeDocumentPackage.readManifest(from: packageURL, requireAttachments: true),
            try savedForm(newManifest)
        )
    }

    func testOriginalPathBookmarkSurvivesDatabasePackageAndImportRoundTrip() throws {
        let sourceDatabase = try WorkspaceDatabase.inMemory()
        try sourceDatabase.applySchema()
        let destinationDatabase = try WorkspaceDatabase.inMemory()
        try destinationDatabase.applySchema()
        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let originalPathBookmark = Data([0x6d, 0x73, 0x63, 0x6f, 0x70, 0x65])
        var snapshot = previewSnapshotWithMetadata()
        snapshot.binaries = [
            BinaryImage(
                id: binaryID,
                name: "Analyze Demo",
                path: "/Users/example/Fixtures/Analyze Demo.bin",
                kind: "synthetic fixture",
                architecture: "arm64",
                originalPathBookmark: originalPathBookmark
            )
        ]
        snapshot.hexBytes = Data([0xca, 0xfe, 0xba, 0xbe])
        // The DB attachment is the exact-slice PAYLOAD (imageBytes); the hex window is a derived
        // prefix of it. Set both to the sentinel so the fixture is internally consistent with the
        // payload model (window == payload here) and the persisted attachment is this sentinel.
        snapshot.imageBytes = Data([0xca, 0xfe, 0xba, 0xbe])

        let persisted = try sourceDatabase.saveWorkspaceState(
            workspaceName: "Bookmark Package",
            snapshot: snapshot,
            selectedSidebarItemID: "binary:\(binaryID.uuidString)",
            selectedAddress: snapshot.instructions.first?.address,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let sourceWorkspaceID = try XCTUnwrap(persisted.workspace.id)
        let loaded = try XCTUnwrap(sourceDatabase.loadWorkspaceState(workspaceID: sourceWorkspaceID))
        XCTAssertEqual(loaded.snapshot.binaries.first?.originalPathBookmark, originalPathBookmark)

        let manifest = try sourceDatabase.writePackage(
            workspaceID: sourceWorkspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            to: packageURL,
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .promptForMissingInputs
        )
        XCTAssertEqual(manifest.binaries.first?.originalPathBookmark, originalPathBookmark)

        let openedPackage = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(openedPackage.snapshot.binaries.first?.originalPathBookmark, originalPathBookmark)

        let imported = try destinationDatabase.importPackage(from: packageURL)
        let importedWorkspaceID = try XCTUnwrap(imported.workspace.id)
        let importedBinary = try XCTUnwrap(destinationDatabase.binaries(workspaceID: importedWorkspaceID).first)
        XCTAssertEqual(imported.snapshot.binaries.first?.originalPathBookmark, originalPathBookmark)
        XCTAssertEqual(importedBinary.originalPathBookmark, originalPathBookmark)
    }

    func testWorkspaceDatabaseImportPackageRestoresAnalysisSessionAndAttachments() throws {
        let sourceDatabase = try WorkspaceDatabase.inMemory()
        try sourceDatabase.applySchema()
        let destinationDatabase = try WorkspaceDatabase.inMemory()
        try destinationDatabase.applySchema()
        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        var snapshot = previewSnapshotWithMetadata()
        snapshot.binaries = [
            BinaryImage(
                id: binaryID,
                name: "Analyze Demo",
                path: "/tmp/Analyze Demo.bin",
                kind: "synthetic fixture",
                architecture: "arm64"
            )
        ]
        snapshot.hexBytes = Data([0xca, 0xfe, 0xba, 0xbe])
        // The DB attachment is the exact-slice PAYLOAD (imageBytes); the hex window is a derived
        // prefix of it. Set both to the sentinel so the fixture is internally consistent with the
        // payload model (window == payload here) and the persisted attachment is this sentinel.
        snapshot.imageBytes = Data([0xca, 0xfe, 0xba, 0xbe])
        let selectedFunction = try XCTUnwrap(snapshot.functions.last)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let persisted = try sourceDatabase.saveWorkspaceState(
            workspaceName: "Package Import",
            snapshot: snapshot,
            selectedSidebarItemID: "function:\(selectedFunction.id.uuidString)",
            selectedAddress: selectedFunction.startAddress,
            selectedTool: .symbols,
            editorMode: .graph,
            isInspectorPresented: false,
            sidebarSearchText: "render",
            now: now
        )
        let sourceWorkspaceID = try XCTUnwrap(persisted.workspace.id)
        let manifest = try sourceDatabase.writePackage(
            workspaceID: sourceWorkspaceID,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            to: packageURL,
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .promptForMissingInputs
        )
        let openedAt = Date(timeIntervalSince1970: 1_800_000_240)

        let imported = try destinationDatabase.importPackage(from: packageURL, openedAt: openedAt)
        let importedWorkspaceID = try XCTUnwrap(imported.workspace.id)
        let loaded = try XCTUnwrap(destinationDatabase.loadWorkspaceState(workspaceID: importedWorkspaceID))
        let importedBinary = try XCTUnwrap(destinationDatabase.binaries(workspaceID: importedWorkspaceID).first)
        let importedDocument = try XCTUnwrap(destinationDatabase.workspaceDocument(workspaceID: importedWorkspaceID))

        XCTAssertEqual(imported.workspace.uuid, manifest.workspaceUUID)
        XCTAssertEqual(imported.workspace.name, "Package Import")
        XCTAssertEqual(imported.workspace.createdAt, now)
        XCTAssertEqual(imported.workspace.modifiedAt, now)
        XCTAssertEqual(imported.session.selectedSidebarItemID, "function:\(selectedFunction.id.uuidString)")
        XCTAssertEqual(imported.session.selectedAddress, selectedFunction.startAddress)
        XCTAssertEqual(imported.session.selectedTool, .symbols)
        XCTAssertEqual(imported.session.editorMode, .graph)
        XCTAssertEqual(imported.session.isInspectorPresented, false)
        XCTAssertEqual(imported.session.sidebarSearchText, "render")
        XCTAssertEqual(imported.session.updatedAt, now)
        XCTAssertEqual(importedDocument.documentID, manifest.documentID)
        XCTAssertEqual(importedDocument.packagePath, packageURL.standardizedFileURL.path)
        XCTAssertEqual(importedDocument.lastOpenedAt, openedAt)
        XCTAssertEqual(importedDocument.lastSavedAt, manifest.modifiedAt)
        XCTAssertFalse(importedDocument.isDirty)
        XCTAssertNil(importedDocument.fileVersionIdentifier)
        XCTAssertNil(importedDocument.conflictDetectedAt)
        XCTAssertNil(importedDocument.conflictReason)
        XCTAssertEqual(importedDocument.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(importedDocument.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(importedDocument.recentDocumentState, .available)
        XCTAssertEqual(importedDocument.recentDocumentStateUpdatedAt, openedAt)

        XCTAssertEqual(importedBinary.uuid, binaryID)
        XCTAssertEqual(importedBinary.fileHash, MacScopeDocumentPackage.fileHash(for: snapshot.hexBytes))
        XCTAssertEqual(importedBinary.fileSize, Int64(snapshot.hexBytes.count))
        XCTAssertEqual(importedBinary.hexBytes, snapshot.hexBytes)
        XCTAssertEqual(loaded.snapshot.binaries, snapshot.binaries)
        XCTAssertEqual(loaded.snapshot.functions, snapshot.functions)
        XCTAssertEqual(loaded.snapshot.symbols, snapshot.symbols)
        XCTAssertEqual(loaded.snapshot.imports, snapshot.imports)
        XCTAssertEqual(loaded.snapshot.indirectSymbols, snapshot.indirectSymbols)
        XCTAssertEqual(loaded.snapshot.exports, snapshot.exports)
        XCTAssertEqual(loaded.snapshot.stringLiterals, snapshot.stringLiterals)
        XCTAssertEqual(loaded.snapshot.basicBlocks, snapshot.basicBlocks)
        XCTAssertEqual(loaded.snapshot.instructions, snapshot.instructions)
        XCTAssertEqual(loaded.snapshot.xrefs, snapshot.xrefs)
        XCTAssertEqual(loaded.snapshot.controlFlowEdges, snapshot.controlFlowEdges)
        XCTAssertEqual(loaded.snapshot.hexBytes, snapshot.hexBytes)

        let reimported = try destinationDatabase.importPackage(from: packageURL)
        let reimportedWorkspaceID = try XCTUnwrap(reimported.workspace.id)
        let reimportedBinary = try XCTUnwrap(destinationDatabase.binaries(workspaceID: reimportedWorkspaceID).first)
        let reimportedSelectedFunction = try XCTUnwrap(reimported.snapshot.functions.last)
        let reimportedFunctionIDs = Set(reimported.snapshot.functions.map(\.id))

        XCTAssertNotEqual(reimported.workspace.uuid, manifest.workspaceUUID)
        XCTAssertNotEqual(reimportedBinary.uuid, binaryID)
        XCTAssertEqual(reimportedBinary.hexBytes, snapshot.hexBytes)
        XCTAssertEqual(reimported.snapshot.hexBytes, snapshot.hexBytes)
        XCTAssertEqual(reimported.snapshot.binaries.first?.id, reimportedBinary.uuid)
        XCTAssertFalse(reimported.snapshot.functions.map(\.id).contains(selectedFunction.id))
        XCTAssertFalse(reimported.snapshot.indirectSymbols.map(\.id).contains(snapshot.indirectSymbols[0].id))
        XCTAssertEqual(reimported.snapshot.indirectSymbols.first?.address, snapshot.indirectSymbols.first?.address)
        XCTAssertEqual(reimported.snapshot.indirectSymbols.first?.symbolName, "_puts")
        XCTAssertEqual(reimportedSelectedFunction.startAddress, selectedFunction.startAddress)
        XCTAssertEqual(reimported.session.selectedSidebarItemID, "function:\(reimportedSelectedFunction.id.uuidString)")
        XCTAssertEqual(reimported.session.selectedAddress, selectedFunction.startAddress)
        XCTAssertTrue(reimported.snapshot.basicBlocks.allSatisfy { reimportedFunctionIDs.contains($0.functionID) })
        XCTAssertEqual(try destinationDatabase.workspaces().count, 2)
    }

    func testWorkspaceDatabaseImportAndExportPreserveReconstructionVersion3State() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-database-v3-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = parent.appendingPathComponent("Source.mscope", isDirectory: true)
        let exportedURL = parent.appendingPathComponent("Exported.mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fixture = try reconstructionPackageFixture(in: parent)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachmentsByBinaryID,
            reconstructionState: fixture.state,
            reconstructionAttachmentSources: fixture.sources,
            to: sourceURL
        )

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let imported = try database.importPackage(from: sourceURL)
        let importedWorkspaceRowID = try XCTUnwrap(imported.workspace.id)

        XCTAssertEqual(imported.reconstructionState, fixture.state)
        XCTAssertEqual(
            try database.loadReconstructionState(workspaceID: imported.workspace.uuid),
            fixture.state
        )

        let exportedManifest = try database.writePackage(
            workspaceID: importedWorkspaceRowID,
            documentID: fixture.manifest.documentID,
            to: exportedURL
        )
        let exported = try MacScopeDocumentPackage.openPackage(from: exportedURL)

        XCTAssertEqual(
            exportedManifest.formatVersion,
            WorkspacePackageManifest.instructionSidecarFormatVersion
        )
        XCTAssertEqual(
            exportedManifest.analysisFormatVersion,
            WorkspacePackageManifest.reconstructionFormatVersion
        )
        // The reader mints fresh IDs for empty debugger catalogs, so compare the written v4
        // storage identity (format + sidecar descriptor) rather than whole-value equality.
        let storedManifest = try MacScopeDocumentPackage.readManifest(from: exportedURL, requireAttachments: true)
        XCTAssertEqual(exportedManifest.formatVersion, storedManifest.formatVersion)
        XCTAssertEqual(exportedManifest.instructionSidecar, storedManifest.instructionSidecar)
        XCTAssertNotNil(exportedManifest.instructionSidecar)
        XCTAssertEqual(exported.reconstructionState, fixture.state)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(
                exported.reconstructionAttachmentSources.first?.verifiedURL
            )),
            fixture.corpusBytes
        )
    }

    func testWorkspaceDatabaseRejectsCollidingVersion3ImportWithoutAddingRows() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-database-v3-collision-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = parent.appendingPathComponent("Source.mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fixture = try reconstructionPackageFixture(in: parent)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachmentsByBinaryID,
            reconstructionState: fixture.state,
            reconstructionAttachmentSources: fixture.sources,
            to: sourceURL
        )

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let firstImport = try database.importPackage(from: sourceURL)
        let workspaceCountBeforeCollision = try database.workspaces().count
        let reconstructionRowsBeforeCollision = try reconstructionRowCounts(in: database)

        XCTAssertThrowsError(try database.importPackage(from: sourceURL)) { error in
            guard case WorkspaceDatabase.DatabaseError.reconstructionIdentityConflict = error else {
                return XCTFail("Expected reconstructionIdentityConflict, got \(error)")
            }
        }

        XCTAssertEqual(try database.workspaces().count, workspaceCountBeforeCollision)
        XCTAssertEqual(
            try reconstructionRowCounts(in: database),
            reconstructionRowsBeforeCollision
        )
        XCTAssertEqual(
            try database.loadReconstructionState(workspaceID: firstImport.workspace.uuid),
            fixture.state
        )
    }

    func testWorkspaceDatabaseExportRejectsMissingReconstructionByteAuthority() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-database-v3-source-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = parent.appendingPathComponent("Source.mscope", isDirectory: true)
        let exportedURL = parent.appendingPathComponent("Exported.mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fixture = try reconstructionPackageFixture(in: parent)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachmentsByBinaryID,
            reconstructionState: fixture.state,
            reconstructionAttachmentSources: fixture.sources,
            to: sourceURL
        )

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let imported = try database.importPackage(from: sourceURL)
        let importedWorkspaceRowID = try XCTUnwrap(imported.workspace.id)
        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertThrowsError(
            try database.writePackage(
                workspaceID: importedWorkspaceRowID,
                documentID: fixture.manifest.documentID,
                to: exportedURL
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionAttachmentSourcesUnavailable
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportedURL.path))
    }

    func testWorkspacePackageReadManifestRejectsInvalidFormatAndAttachmentPaths() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        var manifest = sampleWorkspacePackageManifest()
        manifest.formatIdentifier = "com.example.invalid-package"
        try writePackageManifestData(manifest, to: packageURL)

        XCTAssertThrowsError(try MacScopeDocumentPackage.readManifest(from: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .invalidFormatIdentifier("com.example.invalid-package")
            )
        }

        manifest = sampleWorkspacePackageManifest()
        manifest.formatVersion = 3
        try writePackageManifestData(manifest, to: packageURL)

        XCTAssertThrowsError(try MacScopeDocumentPackage.readManifest(from: packageURL)) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .noncanonicalManifest("manifest.json")
            )
        }

        manifest = sampleWorkspacePackageManifest()
        manifest.binaries[0].attachmentRelativePath = "attachments/\(manifest.binaries[0].id.uuidString.lowercased())/../escape.bin"
        try writePackageManifestData(manifest, to: packageURL)

        XCTAssertThrowsError(try MacScopeDocumentPackage.readManifest(from: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .invalidAttachmentRelativePath(manifest.binaries[0].attachmentRelativePath)
            )
        }
    }

    func testWorkspacePackageAnalysisDecodesLegacyManifestMissingIndirectSymbols() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let attachmentData = WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            uuid: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            segments: [
                .init(
                    name: "__TEXT",
                    vmAddress: 0x1000_00000,
                    vmSize: 0x1_000,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x5
                )
            ],
            byteCount: 0x100
        )
        let expectedFunction = FunctionSummary(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "_main",
            startAddress: 0x1000_00000,
            endAddress: 0x1000_00004,
            confidence: 0.9
        )
        let expectedImport = ImportSummary(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            name: "_puts",
            libraryName: "/usr/lib/libSystem.B.dylib",
            libraryOrdinal: 1
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            workspaceUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workspaceName: "Legacy Package",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            binaries: [
                WorkspacePackageBinary(
                    id: binaryID,
                    displayName: "Analyze Demo",
                    originalPath: "/tmp/Analyze Demo.bin",
                    attachmentRelativePath: "attachments/\(binaryID.uuidString.lowercased())/Analyze Demo.bin",
                    kind: "Mach-O executable",
                    architecture: "arm64",
                    fileHash: MacScopeDocumentPackage.fileHash(for: attachmentData),
                    fileSize: Int64(attachmentData.count)
                )
            ],
            analysis: WorkspacePackageAnalysis(
                functions: [expectedFunction],
                imports: [expectedImport],
                instructions: [
                    InstructionRow(
                        address: 0x1000_00000,
                        bytes: "c0 03 5f d6",
                        mnemonic: "ret",
                        operands: "",
                        hasBreakpoint: false,
                        comment: nil
                    )
                ]
            ),
            session: nil
        )

        // writePackage now always saves v4 (T1 #436), whose closed key structure rightly rejects
        // a removed key; write a genuine v1 manifest on disk so this exercises legacy open.
        XCTAssertEqual(manifest.formatVersion, WorkspacePackageManifest.currentFormatVersion)
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)
        try attachmentData.write(to: MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: manifest.binaries[0].attachmentRelativePath
        ))
        try removeIndirectSymbolsKeyFromPackageManifest(at: packageURL)

        let decodedManifest = try MacScopeDocumentPackage.readManifest(from: packageURL)
        XCTAssertEqual(decodedManifest.analysis?.indirectSymbols, [])
        XCTAssertEqual(decodedManifest.analysis?.functions, [expectedFunction])
        XCTAssertEqual(decodedManifest.analysis?.imports, [expectedImport])

        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(opened.snapshot.indirectSymbols, [])
        XCTAssertEqual(opened.snapshot.functions, [expectedFunction])
        XCTAssertEqual(opened.snapshot.imports, [expectedImport])
        XCTAssertEqual(opened.snapshot.hexBytes, attachmentData)
    }

    func testWorkspacePackageWriteCreatesDeterministicAttachmentDirectories() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let manifest = sampleWorkspacePackageManifest()
        let binary = try XCTUnwrap(manifest.binaries.first)

        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: binary.attachmentRelativePath
        )
        let attachmentDirectory = attachmentURL.deletingLastPathComponent()
        isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            attachmentURL.path,
            packageURL
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(binary.id.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("Analyze Demo.bin", isDirectory: false)
                .path
        )

        try Data([0xca, 0xfe, 0xba, 0xbe]).write(to: attachmentURL)
        XCTAssertEqual(
            try MacScopeDocumentPackage.readManifest(from: packageURL, requireAttachments: true),
            manifest
        )
    }

    func testWorkspacePackageReadManifestRejectsAttachmentHashMismatch() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let manifest = sampleWorkspacePackageManifest()
        let binary = try XCTUnwrap(manifest.binaries.first)
        let tamperedData = Data([0xde, 0xad, 0xbe, 0xef])

        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: binary.attachmentRelativePath
        )
        try tamperedData.write(to: attachmentURL)

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.readManifest(from: packageURL, requireAttachments: true)
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .attachmentHashMismatch(
                    binary.attachmentRelativePath,
                    expected: binary.fileHash,
                    actual: MacScopeDocumentPackage.fileHash(for: tamperedData)
                )
            )
        }
    }

    func testWorkspacePackageReadManifestCanRequireAttachments() throws {
        let packageURL = temporaryPackageURL()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let manifest = sampleWorkspacePackageManifest()
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.readManifest(from: packageURL, requireAttachments: true)
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .missingAttachment(manifest.binaries[0].attachmentRelativePath)
            )
        }
    }

    func testPreviewSnapshotBasicBlocksAndControlFlowEdgesSurviveReload() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = AnalysisEngine.previewSnapshot()
        XCTAssertFalse(snapshot.basicBlocks.isEmpty)
        XCTAssertFalse(snapshot.controlFlowEdges.isEmpty)

        let workspace = try database.saveSnapshot(
            workspaceName: "Graph Round Trip",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let reloaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))

        XCTAssertEqual(reloaded.basicBlocks, snapshot.basicBlocks)
        XCTAssertEqual(reloaded.controlFlowEdges, snapshot.controlFlowEdges)
        XCTAssertEqual(reloaded.basicBlocks.map(\.functionID), snapshot.basicBlocks.map(\.functionID))
        XCTAssertEqual(reloaded.controlFlowEdges.map(\.kind), ["call"])
    }

    func testWorkspaceUpdateAndDeleteCascade() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Old Name",
            snapshot: AnalysisEngine.previewSnapshot(),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        try database.updateWorkspaceName(
            id: workspaceID,
            name: "Renamed",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_120)
        )
        XCTAssertEqual(try database.workspace(id: workspaceID)?.name, "Renamed")

        try database.deleteWorkspace(id: workspaceID)
        XCTAssertNil(try database.workspace(id: workspaceID))
        XCTAssertEqual(try database.binaries(workspaceID: workspaceID), [])
    }

    func testFreshSchemaV41CreatesLayoutRulesColumnAndWritesNonNullDefault() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try database.columnNames(in: "type_definitions"),
            [
                "id", "workspace_id", "kind", "name", "fields_json",
                "layout_rules_json", "created_at", "modified_at",
            ]
        )

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [
            TypeDefinition(
                id: UUID(uuidString: "39000000-0000-0000-0000-000000000001")!,
                kind: .struct,
                name: "DefaultLayout",
                fields: [
                    FieldDef(
                        name: "value",
                        type: "uint32_t",
                        declaratorSemanticsV1: .ordinary
                    ),
                ]
            ),
        ]
        _ = try database.saveSnapshot(
            workspaceName: "Fresh v39",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_039_001)
        )

        let stored = try XCTUnwrap(
            database.scalarTextForTesting(
                "SELECT layout_rules_json FROM type_definitions WHERE name = 'DefaultLayout';"
            )
        )
        XCTAssertEqual(
            stored,
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null}"#
        )
        XCTAssertEqual(
            try WorkspaceTypeDefinitionDatabaseCodec.decodeLayoutRules(stored),
            .default
        )
    }

    func testLayoutCodecEncodesCompleteDefaultAndRejectsEmptyObject() throws {
        XCTAssertEqual(
            try WorkspaceTypeDefinitionDatabaseCodec.encodeLayoutRules(.default),
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null}"#
        )
        XCTAssertThrowsError(
            try WorkspaceTypeDefinitionDatabaseCodec.decodeLayoutRules("{}")
        )
    }

    func testV39RoundTripPreservesCompleteLayoutAndFieldProvenance() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let definition = completePersistenceDefinition()
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [definition]

        let persisted = try database.saveSnapshot(
            workspaceName: "Complete type authority",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_039_002)
        )
        let workspaceID = try XCTUnwrap(persisted.id)
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))

        XCTAssertEqual(restored.snapshot.typeDefinitions, [definition])
        XCTAssertEqual(restored.typeCatalogLoadDiagnostics, [])
        XCTAssertNotNil(
            try database.scalarTextForTesting(
                "SELECT layout_rules_json FROM type_definitions WHERE name = 'Complete';"
            )
        )
    }

    func testV39RoundTripPreservesUnnamedZeroWidthBitFieldBarriersAndOrder() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let definition = TypeDefinition(
            id: UUID(uuidString: "39000000-0000-0000-0000-000000000003")!,
            kind: .struct,
            name: "ZeroWidthBarriers",
            fields: [
                FieldDef(name: "head", type: "uint8_t", declaratorSemanticsV1: .ordinary),
                FieldDef(
                    name: "",
                    type: "unsigned int",
                    declaratorSemanticsV1: .ordinary,
                    bitWidth: 0
                ),
                FieldDef(
                    name: "nested",
                    type: "anonymous struct",
                    declaratorSemanticsV1: .ordinary,
                    inlineAggregateKind: .struct,
                    inlineFields: [
                        FieldDef(name: "left", type: "uint16_t", declaratorSemanticsV1: .ordinary),
                        FieldDef(
                            name: "",
                            type: "unsigned int",
                            declaratorSemanticsV1: .ordinary,
                            bitWidth: 0
                        ),
                        FieldDef(name: "right", type: "uint32_t", declaratorSemanticsV1: .ordinary),
                    ]
                ),
                FieldDef(name: "tail", type: "uint64_t", declaratorSemanticsV1: .ordinary),
            ]
        )
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [definition]

        let persisted = try database.saveSnapshot(
            workspaceName: "Zero-width bit-field barriers",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_039_003)
        )
        let workspaceID = try XCTUnwrap(persisted.id)
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))

        XCTAssertEqual(restored.snapshot.typeDefinitions, [definition])
        XCTAssertEqual(restored.typeCatalogLoadDiagnostics, [])
    }

    func testMalformedNonNullLayoutJSONFailsTypeCatalogRestore() throws {
        let fixture = try persistedTypeDefinitionFixture(name: "MalformedLayout")
        try fixture.database.executeRawForTesting(
            "UPDATE type_definitions SET layout_rules_json = '{' WHERE id = '\(fixture.typeID.uuidString)';"
        )

        assertCorruptTypeCatalogRestore(
            in: fixture.database,
            workspaceID: fixture.workspaceID,
            typeID: fixture.typeID,
            field: "layout_rules_json"
        )
    }

    func testWrongShapeControlBearingAndOutOfRangeLayoutJSONFailRestore() throws {
        let malformedAuthorities = [
            "[]",
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null,"note":"bad\u0000value"}"#,
            #"{"isPacked":false,"minimumAlignment":1048577,"packAlignment":null}"#,
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":0}"#,
            "null",
        ]

        for (index, json) in malformedAuthorities.enumerated() {
            let fixture = try persistedTypeDefinitionFixture(name: "BadLayout\(index)")
            try fixture.database.executeRawForTesting(
                "UPDATE type_definitions SET layout_rules_json = '\(json)' WHERE id = '\(fixture.typeID.uuidString)';"
            )
            assertCorruptTypeCatalogRestore(
                in: fixture.database,
                workspaceID: fixture.workspaceID,
                typeID: fixture.typeID,
                field: "layout_rules_json"
            )
        }
    }

    func testMalformedFieldsJSONFailsInsteadOfDecodingEmptyArray() throws {
        let fixture = try persistedTypeDefinitionFixture(name: "MalformedFields")
        try fixture.database.executeRawForTesting(
            "UPDATE type_definitions SET fields_json = '[{' WHERE id = '\(fixture.typeID.uuidString)';"
        )

        assertCorruptTypeCatalogRestore(
            in: fixture.database,
            workspaceID: fixture.workspaceID,
            typeID: fixture.typeID,
            field: "fields_json"
        )
    }

    func testInvalidTypeKindFailsInsteadOfDroppingRow() throws {
        let fixture = try persistedTypeDefinitionFixture(name: "InvalidKind")
        try fixture.database.executeRawForTesting(
            "UPDATE type_definitions SET kind = 'class' WHERE id = '\(fixture.typeID.uuidString)';"
        )

        assertCorruptTypeCatalogRestore(
            in: fixture.database,
            workspaceID: fixture.workspaceID,
            typeID: fixture.typeID,
            field: "kind"
        )
    }

    func testV38ToV39MigrationUsesSavepointAndMapsOnlySQLNullToLegacyDefault() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let typeID = UUID(uuidString: "38000000-0000-0000-0000-000000000001")!
        let fieldsJSON: String
        let workspaceID: Int64

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            var snapshot = AnalysisEngine.previewSnapshot()
            snapshot.typeDefinitions = [
                TypeDefinition(
                    id: typeID,
                    kind: .struct,
                    name: "LegacyDefault",
                    fields: [
                        FieldDef(
                            name: "value",
                            type: "uint32_t",
                            declaratorSemanticsV1: .ordinary
                        ),
                    ]
                ),
            ]
            let persisted = try database.saveSnapshot(
                workspaceName: "v38 migration",
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_800_038_001)
            )
            workspaceID = try XCTUnwrap(persisted.id)
            fieldsJSON = try XCTUnwrap(
                database.scalarTextForTesting(
                    "SELECT fields_json FROM type_definitions WHERE id = '\(typeID.uuidString)';"
                )
            )
        }

        try replaceTypeDefinitionsWithV38Shape(at: databaseURL)
        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertEqual(try migrated.userVersion(), 38)
        XCTAssertFalse(try migrated.columnNames(in: "type_definitions").contains("layout_rules_json"))

        try migrated.applySchema()

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try migrated.scalarTextForTesting(
                "SELECT fields_json FROM type_definitions WHERE id = '\(typeID.uuidString)';"
            ),
            fieldsJSON
        )
        XCTAssertNil(
            try migrated.scalarTextForTesting(
                "SELECT layout_rules_json FROM type_definitions WHERE id = '\(typeID.uuidString)';"
            )
        )
        let restored = try XCTUnwrap(migrated.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(restored.snapshot.typeDefinitions.first?.layoutRules, .default)
        XCTAssertEqual(
            restored.typeCatalogLoadDiagnostics,
            [.legacyDefaultLayoutSubstitution(typeName: "LegacyDefault")]
        )
        XCTAssertNoThrow(try migrated.applySchema())
    }

    func testEveryPriorMigrationChainContinuesThroughV41() throws {
        // Every pre-v30 path already converges through the literal v30 stamp. Exercise every
        // distinct surviving tail entry, including v40, so none can stop before the v41 step.
        for legacyVersion in 30...40 {
            let database = try WorkspaceDatabase.inMemory()
            try database.applySchema()
            try database.setUserVersionForTesting(legacyVersion)

            try database.applySchema()

            XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion, "legacy v\(legacyVersion)")
            XCTAssertTrue(
                try database.columnNames(in: "type_definitions").contains("layout_rules_json"),
                "legacy v\(legacyVersion)"
            )
            XCTAssertTrue(
                try database.columnNames(in: "binaries").contains("binary_metadata_json"),
                "legacy v\(legacyVersion)"
            )
        }
    }

    func testMigratedV38RowReportsIrrecoverableLegacyDefaultSubstitution() throws {
        let databaseURL = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let workspaceID: Int64

        do {
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            var snapshot = AnalysisEngine.previewSnapshot()
            snapshot.typeDefinitions = [
                TypeDefinition(
                    id: UUID(uuidString: "38000000-0000-0000-0000-000000000002")!,
                    kind: .struct,
                    name: "HistoricallyLossy",
                    fields: [
                        FieldDef(
                            name: "value",
                            type: "uint64_t",
                            declaratorSemanticsV1: .ordinary
                        ),
                    ]
                ),
            ]
            workspaceID = try XCTUnwrap(
                database.saveSnapshot(
                    workspaceName: "v38 diagnostic",
                    snapshot: snapshot,
                    now: Date(timeIntervalSince1970: 1_800_038_002)
                ).id
            )
        }

        try replaceTypeDefinitionsWithV38Shape(at: databaseURL)
        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()
        let restored = try XCTUnwrap(migrated.loadWorkspaceState(workspaceID: workspaceID))

        XCTAssertEqual(
            restored.typeCatalogLoadDiagnostics,
            [.legacyDefaultLayoutSubstitution(typeName: "HistoricallyLossy")]
        )
    }

    func testV38ToV39MigrationAcceptsEarlyConvergedLayoutColumnWithoutDuplicateAlter() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let definition = TypeDefinition(
            id: UUID(uuidString: "38000000-0000-0000-0000-000000000003")!,
            kind: .struct,
            name: "EarlyConverged",
            fields: [
                FieldDef(
                    name: "value",
                    type: "uint32_t",
                    declaratorSemanticsV1: .ordinary
                ),
            ],
            layoutRules: AggregateLayoutRules(
                isPacked: true,
                packAlignment: 2,
                minimumAlignment: 8
            )
        )
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [definition]
        let workspaceID = try XCTUnwrap(
            database.saveSnapshot(
                workspaceName: "Early converged v38",
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_800_038_003)
            ).id
        )
        let layoutJSON = try XCTUnwrap(
            database.scalarTextForTesting(
                "SELECT layout_rules_json FROM type_definitions WHERE name = 'EarlyConverged';"
            )
        )
        try database.setUserVersionForTesting(38)

        XCTAssertNoThrow(try database.applySchema())

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try database.scalarTextForTesting(
                "SELECT layout_rules_json FROM type_definitions WHERE name = 'EarlyConverged';"
            ),
            layoutJSON
        )
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(restored.snapshot.typeDefinitions, [definition])
        XCTAssertEqual(restored.typeCatalogLoadDiagnostics, [])
    }

    private struct PersistedTypeDefinitionFixture {
        let database: WorkspaceDatabase
        let workspaceID: Int64
        let typeID: UUID
    }

    private func completePersistenceDefinition() -> TypeDefinition {
        TypeDefinition(
            id: UUID(uuidString: "39000000-0000-0000-0000-000000000002")!,
            kind: .struct,
            name: "Complete",
            fields: [
                FieldDef(
                    name: "ordinaryBits",
                    type: "uint32_t",
                    declaratorSemanticsV1: .ordinary,
                    bitWidth: 3,
                    minimumAlignment: 8
                ),
                FieldDef(
                    name: "alignedByType",
                    type: "uint32_t",
                    declaratorSemanticsV1: .ordinary,
                    minimumAlignmentType: "uint64_t"
                ),
                FieldDef(
                    name: "callback",
                    type: "void *",
                    declaratorSemanticsV1: .functionPointerCarrier
                ),
                FieldDef(
                    name: "matrix",
                    type: "uint32_t *",
                    declaratorSemanticsV1: .pointerToArrayCarrier
                ),
                FieldDef(
                    name: "callbacks",
                    type: "void *[3]",
                    declaratorSemanticsV1: .arrayOfFunctionPointerCarrier
                ),
                FieldDef(
                    name: "legacyUnknown",
                    type: "uint8_t"
                ),
                FieldDef(
                    name: "",
                    type: "anonymous union",
                    declaratorSemanticsV1: .ordinary,
                    minimumAlignment: 16,
                    inlineAggregateKind: .union,
                    inlineFields: [
                        FieldDef(
                            name: "wide",
                            type: "uint64_t",
                            declaratorSemanticsV1: .ordinary
                        ),
                        FieldDef(
                            name: "narrow",
                            type: "uint16_t",
                            declaratorSemanticsV1: .ordinary,
                            bitWidth: 7
                        ),
                    ],
                    inlineAggregateLayoutRules: AggregateLayoutRules(
                        isPacked: true,
                        packAlignment: 1,
                        minimumAlignment: 8
                    ),
                    promotesInlineFields: true
                ),
            ],
            layoutRules: AggregateLayoutRules(
                isPacked: true,
                packAlignment: 2,
                minimumAlignment: 16
            )
        )
    }

    private func persistedTypeDefinitionFixture(
        name: String
    ) throws -> PersistedTypeDefinitionFixture {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let typeID = UUID()
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [
            TypeDefinition(
                id: typeID,
                kind: .struct,
                name: name,
                fields: [
                    FieldDef(
                        name: "value",
                        type: "uint32_t",
                        declaratorSemanticsV1: .ordinary
                    ),
                ]
            ),
        ]
        let workspaceID = try XCTUnwrap(
            database.saveSnapshot(
                workspaceName: name,
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_800_039_100)
            ).id
        )
        return PersistedTypeDefinitionFixture(
            database: database,
            workspaceID: workspaceID,
            typeID: typeID
        )
    }

    private func assertCorruptTypeCatalogRestore(
        in database: WorkspaceDatabase,
        workspaceID: Int64,
        typeID: UUID,
        field: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try database.loadWorkspaceState(workspaceID: workspaceID),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .corruptRow(
                    table: "type_definitions",
                    rowIdentity: typeID.uuidString,
                    field: field
                ),
                file: file,
                line: line
            )
        }
    }

    private func replaceTypeDefinitionsWithV38Shape(at databaseURL: URL) throws {
        try executeSQLiteStatements(
            """
            PRAGMA foreign_keys = OFF;
            BEGIN IMMEDIATE;
            DROP INDEX IF EXISTS idx_type_definitions_workspace_name;
            ALTER TABLE type_definitions RENAME TO type_definitions_v39;
            CREATE TABLE type_definitions (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              name TEXT NOT NULL,
              fields_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO type_definitions (
              id, workspace_id, kind, name, fields_json, created_at, modified_at
            )
            SELECT id, workspace_id, kind, name, fields_json, created_at, modified_at
            FROM type_definitions_v39;
            DROP TABLE type_definitions_v39;
            CREATE UNIQUE INDEX idx_type_definitions_workspace_name
              ON type_definitions(workspace_id, name);
            PRAGMA user_version = 38;
            COMMIT;
            PRAGMA foreign_keys = ON;
            """,
            to: databaseURL
        )
    }

    private func previewSnapshotWithMetadata() -> WorkspaceSnapshot {
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.symbols = [
            SymbolSummary(
                id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                name: "_exported_entry",
                address: 0x1000_00000,
                kind: "export",
                libraryName: nil
            ),
            SymbolSummary(
                id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                name: "_puts",
                address: nil,
                kind: "import",
                libraryName: "/usr/lib/libSystem.B.dylib"
            )
        ]
        snapshot.imports = [
            ImportSummary(
                id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                name: "_puts",
                libraryName: "/usr/lib/libSystem.B.dylib",
                libraryOrdinal: 1
            )
        ]
        snapshot.indirectSymbols = [
            IndirectSymbolSummary(
                id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                kind: "lazySymbolPointer",
                sourceSection: "__DATA,__la_symbol_ptr",
                address: 0x1000_04000,
                entrySize: 8,
                tableIndex: 1,
                rawSymbolIndex: 0,
                symbolIndex: 0,
                symbolName: "_puts",
                libraryOrdinal: 1,
                libraryName: "/usr/lib/libSystem.B.dylib",
                isLocal: false,
                isAbsolute: false
            )
        ]
        snapshot.exports = [
            ExportSummary(
                id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                name: "_exported_entry",
                address: 0x1000_00000,
                source: "LC_SYMTAB"
            )
        ]
        snapshot.stringLiterals = [
            StringLiteralSummary(
                id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                value: "Usage: MacScope <binary>",
                address: 0x1000_03000,
                sourceSection: "__TEXT,__cstring",
                byteLength: 25
            )
        ]
        return snapshot
    }

    private func installPreviewLogicalBreakpointCatalog(in snapshot: inout WorkspaceSnapshot) {
        guard let binary = snapshot.binaries.first else { return }
        let specification = try! DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(
                rawValue: UUID(uuidString: "91000000-0000-0000-0000-000000000091")!
            ),
            revision: DebuggerLogicalBreakpointRevision(rawValue: 1)!,
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: binary.slot,
                    binaryID: binary.id,
                    artifactIdentity: binary.artifactIdentity
                ),
                preferredVA: 0x1000_00004
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
        snapshot.logicalBreakpointCatalog = try! DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "92000000-0000-0000-0000-000000000092")!,
            revision: 1,
            specifications: [specification]
        )
    }

    private struct ReconstructionPackageFixture {
        let manifest: WorkspacePackageManifest
        let attachmentsByBinaryID: [UUID: Data]
        let state: ReconstructionWorkspaceState
        let sources: [ReconstructionAttachmentSource]
        let corpusBytes: Data
    }

    private func reconstructionPackageFixture(in directory: URL) throws
        -> ReconstructionPackageFixture {
        var manifest = sampleWorkspacePackageManifest()
        manifest.binaries[0].kind = "Raw data"
        let binary = try XCTUnwrap(manifest.binaries.first)
        let binaryBytes = Data([0xca, 0xfe, 0xba, 0xbe])
        let corpusBytes = Data("database-owned immutable corpus".utf8)
        let corpusSourceURL = directory.appendingPathComponent("database-corpus.bin")
        try corpusBytes.write(to: corpusSourceURL)
        let contentIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: MacScopeDocumentPackage.fileHash(for: corpusBytes),
            byteCount: UInt64(corpusBytes.count)
        )
        let projectID = UUID()
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
            contentIdentity: contentIdentity,
            kind: .opaque,
            roles: [.primaryTarget],
            executableMode: false,
            originalName: corpusSourceURL.lastPathComponent,
            diagnostic: nil
        )
        let corpusManifestSHA256 = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: []
        )
        let corpusManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: [],
            canonicalSHA256: corpusManifestSHA256
        )
        let state = try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Database package reconstruction",
                    currentCorpusManifestSHA256: corpusManifest.canonicalSHA256
                ),
            ],
            corpusManifests: [corpusManifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
        return ReconstructionPackageFixture(
            manifest: manifest,
            attachmentsByBinaryID: [binary.id: binaryBytes],
            state: state,
            sources: [
                ReconstructionAttachmentSource(
                    contentIdentity: contentIdentity,
                    verifiedURL: corpusSourceURL
                ),
            ],
            corpusBytes: corpusBytes
        )
    }

    private func reconstructionRowCounts(in database: WorkspaceDatabase) throws
        -> [String: Int] {
        try Dictionary(
            uniqueKeysWithValues: database.tableNames()
                .filter { $0.hasPrefix("reconstruction_") }
                .sorted()
                .map { table in
                    (table, try database.scalarIntForTesting("SELECT COUNT(*) FROM \(table);"))
                }
        )
    }

    private func temporarySQLiteURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func temporaryPackageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
    }

    private func sampleWorkspacePackageManifest() -> WorkspacePackageManifest {
        let binaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let attachmentData = Data([0xca, 0xfe, 0xba, 0xbe])
        return WorkspacePackageManifest(
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            workspaceUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workspaceName: "Package Fixture",
            createdAt: now,
            modifiedAt: now,
            binaries: [
                WorkspacePackageBinary(
                    id: binaryID,
                    displayName: "Analyze Demo",
                    originalPath: "/tmp/Analyze Demo.bin",
                    attachmentRelativePath: "attachments/\(binaryID.uuidString.lowercased())/Analyze Demo.bin",
                    kind: "Mach-O executable",
                    architecture: "arm64",
                    fileHash: MacScopeDocumentPackage.fileHash(for: attachmentData),
                    fileSize: Int64(attachmentData.count)
                )
            ],
            session: WorkspacePackageSession(
                selectedSidebarItemID: "binary:\(binaryID.uuidString)",
                selectedAddress: 0x1000_00000,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                updatedAt: now
            )
        )
    }

    private func writePackageManifestData(
        _ manifest: WorkspacePackageManifest,
        to packageURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try packageManifestData(manifest).write(to: MacScopeDocumentPackage.manifestURL(in: packageURL))
    }

    private func removeIndirectSymbolsKeyFromPackageManifest(at packageURL: URL) throws {
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: packageURL)
        let data = try Data(contentsOf: manifestURL)
        guard var manifestObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var analysisObject = manifestObject["analysis"] as? [String: Any]
        else {
            XCTFail("Expected package manifest with an analysis object")
            return
        }

        analysisObject.removeValue(forKey: "indirectSymbols")
        manifestObject["analysis"] = analysisObject
        let updatedData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: manifestURL, options: [.atomic])
    }

    private func packageManifestData(_ manifest: WorkspacePackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(manifest)
    }

    private func writeSQLiteUserVersion(
        _ userVersion: Int,
        to url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var handle: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(openStatus, SQLITE_OK, file: file, line: line)

        let connection = try XCTUnwrap(handle, file: file, line: line)
        defer { sqlite3_close(connection) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(connection, "PRAGMA user_version = \(userVersion);", nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
        sqlite3_free(errorMessage)
        XCTAssertEqual(status, SQLITE_OK, message, file: file, line: line)
    }

    private func executeSQLiteStatements(
        _ sql: String,
        to url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var handle: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(openStatus, SQLITE_OK, file: file, line: line)

        let connection = try XCTUnwrap(handle, file: file, line: line)
        defer { sqlite3_close(connection) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
        sqlite3_free(errorMessage)
        XCTAssertEqual(status, SQLITE_OK, message, file: file, line: line)
    }

    /// Lane AG: the instruction insert's address → function resolver must return exactly what the
    /// former ordered linear scan returned (first containing range in function order, else the
    /// first function), for disjoint ranges (binary search) and overlapping or open-ended ones.
    func testFunctionRangeIndexMatchesOrderedLinearScan() {
        func record(_ start: UInt64, _ end: UInt64?) -> WorkspaceDatabase.FunctionRecord {
            WorkspaceDatabase.FunctionRecord(
                id: nil, uuid: UUID(), binaryID: 1, startAddress: start, endAddress: end,
                symbolName: nil, demangledName: nil, confidence: 1
            )
        }
        func linear(_ ranges: [(record: WorkspaceDatabase.FunctionRecord, id: Int64)], _ address: UInt64) -> Int64? {
            ranges.first { address >= $0.record.startAddress && address < ($0.record.endAddress ?? .max) }?.id
                ?? ranges.first?.id
        }
        var generator = SystemRandomNumberGenerator()
        let layouts: [[(UInt64, UInt64?)]] = [
            [],
            [(0x100, 0x200)],
            [(0x300, 0x400), (0x100, 0x200), (0x200, 0x300), (0x500, nil)],   // disjoint, unsorted
            [(0x100, 0x400), (0x200, 0x300), (0x380, 0x500)],                  // overlapping
            [(0x100, 0x100), (0x100, 0x180), (0x400, 0x300), (0x180, nil)],   // empty, inverted, open
            (0..<300).map { index in
                let start = UInt64.random(in: 0..<0x4000, using: &generator)
                return (start, start + UInt64.random(in: 0..<0x80, using: &generator))
            },
            (0..<300).map { (UInt64($0) * 0x40, UInt64($0) * 0x40 + 0x20) }.shuffled(using: &generator),
        ]
        for layout in layouts {
            let ranges = layout.enumerated().map { (record: record($0.element.0, $0.element.1), id: Int64($0.offset + 1)) }
            let index = WorkspaceDatabase.FunctionRangeIndex(ranges)
            var addresses: [UInt64] = [0, 0xFF, 0x100, 0x1FF, 0x200, 0x380, 0x4FF, 0x500, .max]
            addresses += layout.flatMap { [$0.0, $0.0 &- 1, $0.1 ?? 0, ($0.1 ?? 1) &- 1] }
            addresses += (0..<200).map { _ in UInt64.random(in: 0..<0x5000, using: &generator) }
            for address in addresses {
                XCTAssertEqual(index.functionID(for: address), linear(ranges, address), "\(layout) @ \(address)")
            }
        }
    }
}

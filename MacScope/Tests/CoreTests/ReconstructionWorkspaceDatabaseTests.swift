import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionWorkspaceDatabaseTests: XCTestCase {
    func testVersion37MigrationPreservesExistingRowsAndCreatesExactReconstructionSchema() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeVersion37Database()

        XCTAssertEqual(try fixture.database.userVersion(), 37)
        XCTAssertEqual(try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"), 1)
        XCTAssertGreaterThan(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM binaries;"),
            0
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM phase2_assistant_session_records;"
            ),
            1
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM phase2_shell_sessions;"),
            1
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM logical_breakpoint_catalogs;"),
            1
        )

        try fixture.database.applySchema()

        XCTAssertEqual(try fixture.database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            Set(try fixture.database.tableNames().filter { $0.hasPrefix("reconstruction_") }),
            ReconstructionDatabaseTestFixtures.reconstructionTableNames
        )
        XCTAssertEqual(try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"), 1)
        XCTAssertGreaterThan(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM binaries;"),
            0
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM phase2_assistant_session_records;"
            ),
            1
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM phase2_shell_sessions;"),
            1
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM logical_breakpoint_catalogs;"),
            1
        )
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
            .empty
        )
    }

    func testMalformedPartialVersion38SchemaRollsBackWithoutStampingOrChangingRows() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeVersion37Database()
        try fixture.database.executeRawForTesting(
            """
            CREATE TABLE reconstruction_projects (
              workspace_uuid TEXT NOT NULL,
              malformed_payload TEXT NOT NULL
            );
            INSERT INTO reconstruction_projects (workspace_uuid, malformed_payload)
              VALUES ('\(fixture.workspaceUUID.uuidString)', 'preserve-me');
            """
        )
        let beforeTables = try fixture.database.tableNames()
        let beforeSchema = try fixture.database.scalarTextForTesting(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'reconstruction_projects';"
        )

        XCTAssertThrowsError(try fixture.database.applySchema()) { error in
            guard case WorkspaceDatabase.DatabaseError.reconstructionSchemaInvalid = error else {
                return XCTFail("Expected reconstructionSchemaInvalid, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.database.userVersion(), 37)
        XCTAssertEqual(try fixture.database.tableNames(), beforeTables)
        XCTAssertEqual(
            try fixture.database.scalarTextForTesting(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'reconstruction_projects';"
            ),
            beforeSchema
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_projects WHERE malformed_payload = 'preserve-me';"
            ),
            1
        )
    }

    func testSameColumnMalformedVersion38SchemaRollsBackWithoutStampingOrChangingRows() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeVersion37Database()
        try fixture.database.executeRawForTesting(
            """
            CREATE TABLE reconstruction_projects (
              workspace_uuid TEXT NOT NULL,
              project_id TEXT NOT NULL,
              current_manifest_sha256 TEXT,
              record_json BLOB NOT NULL,
              state_json BLOB NOT NULL,
              PRIMARY KEY (project_id)
            );
            INSERT INTO reconstruction_projects (
              workspace_uuid, project_id, current_manifest_sha256, record_json, state_json
            ) VALUES (
              '\(fixture.workspaceUUID.uuidString)',
              '38000000-0000-0000-0000-000000000040', NULL, X'01', X'02'
            );
            """
        )
        let beforeTables = try fixture.database.tableNames()
        let beforeSchema = try fixture.database.scalarTextForTesting(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'reconstruction_projects';"
        )

        XCTAssertThrowsError(try fixture.database.applySchema()) { error in
            guard case WorkspaceDatabase.DatabaseError.reconstructionSchemaInvalid = error else {
                return XCTFail("Expected reconstructionSchemaInvalid, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.database.userVersion(), 37)
        XCTAssertEqual(try fixture.database.tableNames(), beforeTables)
        XCTAssertEqual(
            try fixture.database.scalarTextForTesting(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'reconstruction_projects';"
            ),
            beforeSchema
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_projects WHERE record_json = X'01';"
            ),
            1
        )
    }

    func testFreshSchemaUsesStableReconstructionKeysAndNoSQLiteRelationRowIDs() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            Set(try database.tableNames().filter { $0.hasPrefix("reconstruction_") }),
            ReconstructionDatabaseTestFixtures.reconstructionTableNames
        )
        XCTAssertEqual(
            try database.columnNames(in: "reconstruction_artifact_relations"),
            [
                "workspace_uuid", "project_id", "relation_id", "kind",
                "source_occurrence_id", "target_occurrence_id", "canonical_sha256",
                "record_json",
            ]
        )
        XCTAssertEqual(
            try database.columnNames(in: "reconstruction_evidence_relations"),
            [
                "workspace_uuid", "relation_id", "kind", "source_evidence_id",
                "target_evidence_id", "record_json",
            ]
        )
        XCTAssertEqual(
            try database.columnNames(in: "reconstruction_checkpoint_tasks"),
            ["workspace_uuid", "checkpoint_id", "task_id", "state_bucket", "ordinal"]
        )
        XCTAssertEqual(
            try database.columnNames(in: "reconstruction_final_results"),
            [
                "workspace_uuid", "result_id", "job_id", "task_id", "checkpoint_id",
                "checkpoint_revision", "request_id", "request_identity_sha256", "kind",
                "payload_byte_count", "payload_sha256", "producer_canonical_sha256",
                "model_receipt_id", "canonical_sha256", "record_json",
            ]
        )
        for table in [
            "reconstruction_artifact_relations",
            "reconstruction_evidence_relations",
            "reconstruction_checkpoint_tasks",
            "reconstruction_final_results",
        ] {
            let columns = try database.columnNames(in: table)
            XCTAssertFalse(columns.contains("id"), "\(table) must not borrow a SQLite row ID")
            XCTAssertFalse(columns.contains(where: { $0.hasSuffix("_row_id") }))
        }
    }

    func testReconstructionStateRoundTripsThroughCompositeWorkspaceProjection() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let state = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID
        )

        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: state
        )

        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
            state
        )
        let persisted = try XCTUnwrap(
            fixture.database.loadWorkspaceState(workspaceID: fixture.workspaceRowID)
        )
        XCTAssertEqual(persisted.reconstructionState, state)
    }

    func testDatabaseAdmissionRejectsDuplicateToolReceiptTaskBinding() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let rich = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID
        )
        let original = try XCTUnwrap(rich.toolReceipts.first)
        let duplicate = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: UUID(uuidString: "38000000-0000-4000-8000-000000000201")!,
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointRevision: original.checkpointRevision,
            requestIdentitySHA256: ReconstructionDatabaseTestFixtures.digest("9"),
            producer: original.producer,
            terminalState: .failed,
            outputEvidenceIDs: [],
            diagnostic: .sanitizing(
                "A second terminal outcome must not bind the same task."
            )
        )
        let hostile = try ReconstructionWorkspaceState(
            schemaVersion: rich.schemaVersion,
            projects: rich.projects,
            corpusManifests: rich.corpusManifests,
            evidence: rich.evidence,
            evidenceRelations: rich.evidenceRelations,
            evidenceGaps: rich.evidenceGaps,
            jobs: rich.jobs,
            tasks: rich.tasks,
            checkpoints: rich.checkpoints,
            toolReceipts: rich.toolReceipts + [duplicate],
            modelReceipts: rich.modelReceipts,
            finalResults: rich.finalResults
        )

        XCTAssertThrowsError(
            try fixture.database.replaceReconstructionState(
                workspaceID: fixture.workspaceUUID,
                state: hostile
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid(
                    "package-v3 graph: duplicate tool receipt task binding"
                )
            )
        }
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
            .empty
        )
    }

    func testObjectiveDigestMismatchIsRejectedAtDatabaseAdmission() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        let invalidState = try state(
            foundation.state,
            replacing: job(foundation.job, objectiveSHA256: ReconstructionDatabaseTestFixtures.digest("8"))
        )

        XCTAssertThrowsError(
            try fixture.database.replaceReconstructionState(
                workspaceID: fixture.workspaceUUID,
                state: invalidState
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("job objective digest")
            )
        }
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
            .empty
        )
    }

    func testObjectiveDigestMismatchIsRejectedWhenLoadingAuthoritativeDatabaseRows() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let invalidJob = try job(
            foundation.job,
            objectiveSHA256: ReconstructionDatabaseTestFixtures.digest("8")
        )
        let invalidState = try state(foundation.state, replacing: invalidJob)
        let stateBlob = blobLiteral(try ReconstructionCanonicalJSON.encode(invalidState))
        let jobBlob = blobLiteral(try ReconstructionCanonicalJSON.encode(invalidJob))
        try fixture.database.executeRawForTesting(
            """
            UPDATE reconstruction_projects SET state_json = \(stateBlob);
            UPDATE reconstruction_jobs SET record_json = \(jobBlob);
            """
        )

        XCTAssertThrowsError(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("job objective digest")
            )
        }
    }

    func testForgedCheckpointCanonicalIdentityIsRejectedAtAdmissionAndAuthoritativeLoad() throws {
        let admissionFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: admissionFixture.binaryID
        )
        let checkpoint = foundation.checkpoint
        let forgedCheckpoint = try ReconstructionCheckpoint(
            checkpointID: checkpoint.checkpointID,
            schemaVersion: checkpoint.schemaVersion,
            jobID: checkpoint.jobID,
            revision: checkpoint.revision,
            parentCheckpointID: checkpoint.parentCheckpointID,
            parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: checkpoint.pendingTaskIDs,
            runningTaskIDs: checkpoint.runningTaskIDs,
            completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs,
            blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: checkpoint.modelReceiptIDs,
            toolReceiptIDs: checkpoint.toolReceiptIDs,
            coordinatorState: checkpoint.coordinatorState,
            terminalReason: checkpoint.terminalReason,
            canonicalEncodedByteCount: checkpoint.canonicalEncodedByteCount + 1,
            canonicalSHA256: checkpoint.canonicalSHA256
        )
        let forgedState = try ReconstructionWorkspaceState(
            schemaVersion: foundation.state.schemaVersion,
            projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests,
            evidence: foundation.state.evidence,
            evidenceRelations: foundation.state.evidenceRelations,
            evidenceGaps: foundation.state.evidenceGaps,
            jobs: foundation.state.jobs,
            tasks: foundation.state.tasks,
            checkpoints: [forgedCheckpoint],
            toolReceipts: foundation.state.toolReceipts,
            modelReceipts: foundation.state.modelReceipts,
            finalResults: foundation.state.finalResults
        )

        assertDatabaseGraphRejected(
            {
                try admissionFixture.database.replaceReconstructionState(
                    workspaceID: admissionFixture.workspaceUUID,
                    state: forgedState
                )
            },
            name: "database admission accepted forged checkpoint canonical identity"
        )
        XCTAssertEqual(
            try admissionFixture.database.loadReconstructionState(
                workspaceID: admissionFixture.workspaceUUID
            ),
            .empty
        )

        let loadFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        try loadFixture.database.replaceReconstructionState(
            workspaceID: loadFixture.workspaceUUID,
            state: foundation.state
        )
        try loadFixture.database.executeRawForTesting(
            "UPDATE reconstruction_projects SET state_json = "
                + blobLiteral(try ReconstructionCanonicalJSON.encode(forgedState))
                + ";"
        )
        assertDatabaseGraphRejected(
            {
                _ = try loadFixture.database.loadReconstructionState(
                    workspaceID: loadFixture.workspaceUUID
                )
            },
            name: "database load accepted forged checkpoint canonical identity"
        )
    }

    func testSchemaV38AdmissionAndPersistedLoadMatchPackageV3InvalidGraphMatrix() throws {
        let seedFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let validState = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: seedFixture.binaryID
        )

        for testCase in invalidGraphParityCases() {
            let invalidState = try mutatedState(validState, using: testCase.mutation)

            XCTAssertThrowsError(
                try ReconstructionPackageCodec.encode(invalidState),
                "Package v3 accepted invalid graph: \(testCase.name)"
            ) { error in
                guard case ReconstructionPackageValidationError.stateGraphInvalid = error else {
                    return XCTFail(
                        "Expected package graph rejection for \(testCase.name), got \(error)"
                    )
                }
            }

            let admissionFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            assertDatabaseGraphRejected(
                {
                    try admissionFixture.database.replaceReconstructionState(
                        workspaceID: admissionFixture.workspaceUUID,
                        state: invalidState
                    )
                },
                name: "schema-v38 admission accepted \(testCase.name)"
            )
            XCTAssertEqual(
                try admissionFixture.database.loadReconstructionState(
                    workspaceID: admissionFixture.workspaceUUID
                ),
                .empty,
                "Failed admission partially persisted \(testCase.name)"
            )

            let loadFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            try loadFixture.database.replaceReconstructionState(
                workspaceID: loadFixture.workspaceUUID,
                state: validState
            )
            let invalidStateBlob = blobLiteral(
                try ReconstructionCanonicalJSON.encode(invalidState)
            )
            try loadFixture.database.executeRawForTesting(
                "UPDATE reconstruction_projects SET state_json = \(invalidStateBlob);"
            )
            assertDatabaseGraphRejected(
                {
                    _ = try loadFixture.database.loadReconstructionState(
                        workspaceID: loadFixture.workspaceUUID
                    )
                },
                name: "schema-v38 authoritative load accepted \(testCase.name)"
            )
        }
    }

    func testSharedGraphParityPreservesCancelledFrontierCumulativeReceiptsAndOpaqueDigests() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let richState = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID
        )
        let job = try XCTUnwrap(richState.jobs.first)
        let replay = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: richState,
            receipt: try XCTUnwrap(richState.toolReceipts.first)
        )
        let replayedJob = try ReconstructionJobRecord(
            jobID: job.jobID,
            reconstructionProjectID: job.reconstructionProjectID,
            objective: job.objective,
            objectiveSHA256: job.objectiveSHA256,
            creationCorpusManifestSHA256: job.creationCorpusManifestSHA256,
            state: replay.successorCheckpoint.coordinatorState,
            currentCheckpointID: replay.successorCheckpoint.checkpointID,
            terminalReason: replay.successorCheckpoint.terminalReason,
            budget: job.budget,
            creationOrdinal: try XCTUnwrap(job.creationOrdinal),
            pauseContext: job.pauseContext
        )
        let replayedState = try ReconstructionWorkspaceState(
            projects: richState.projects,
            corpusManifests: richState.corpusManifests,
            evidence: richState.evidence,
            evidenceRelations: richState.evidenceRelations,
            evidenceGaps: richState.evidenceGaps,
            jobs: [replayedJob],
            tasks: richState.tasks,
            checkpoints: richState.checkpoints + [replay.successorCheckpoint],
            toolReceipts: richState.toolReceipts,
            modelReceipts: richState.modelReceipts
        )
        let acceptedState = try mutatedState(replayedState) { object in
            var tasks = try objectArray("tasks", in: object)
            var task = try XCTUnwrap(tasks.first)
            task["state"] = ReconstructionTaskState.cancelled.rawValue
            tasks[0] = task
            object["tasks"] = tasks

            var checkpoints = try objectArray("checkpoints", in: object)
            let tailIndex = try checkpointIndex(revision: 2, in: checkpoints)
            var tail = checkpoints[tailIndex]
            let taskID = try XCTUnwrap(
                (task["identity"] as? [String: Any])?["taskID"] as? String
            )
            tail["completedTaskIDs"] = []
            tail["failedTaskIDs"] = [taskID]
            checkpoints[tailIndex] = tail
            object["checkpoints"] = checkpoints
        }

        XCTAssertNoThrow(try ReconstructionPackageCodec.encode(acceptedState))
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: acceptedState
        )
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
            acceptedState
        )
    }

    func testLoadingRejectsDivergentCanonicalAndIndexedProjectionRows() throws {
        let corruptions = [
            "UPDATE reconstruction_projects SET state_json = state_json || X'20';",
            "UPDATE reconstruction_jobs SET job_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';",
            "UPDATE reconstruction_artifact_roles SET role = 'auxiliary', ordinal = 8;",
            "UPDATE reconstruction_checkpoint_tasks SET state_bucket = 'running', ordinal = 9 WHERE state_bucket = 'pending';",
            "UPDATE reconstruction_evidence SET classification = 'failed';",
        ]

        for corruption in corruptions {
            let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            let state = try ReconstructionDatabaseTestFixtures.makeRichState(
                workspaceBinaryID: fixture.binaryID
            )
            try fixture.database.replaceReconstructionState(
                workspaceID: fixture.workspaceUUID,
                state: state
            )
            try fixture.database.executeRawForTesting(corruption)

            XCTAssertThrowsError(
                try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
                "Projection corruption was accepted: \(corruption)"
            ) { error in
                guard case WorkspaceDatabase.DatabaseError.reconstructionIdentityConflict = error else {
                    return XCTFail("Expected reconstructionIdentityConflict, got \(error)")
                }
            }
        }
    }

    func testDeletingWorkspaceCascadesEveryReconstructionProjectionTable() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let state = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: state
        )

        // Mutation RED (2026-08-23): removing this structural row seed made the assertion below
        // fail with "Fixture must exercise the reconstruction_final_results cascade". The rich
        // semantic fixture intentionally has no terminal synthesis, so this test alone supplies a
        // constraint-valid child row to exercise the schema's workspace deletion edge.
        let job = try XCTUnwrap(state.jobs.first)
        let task = try XCTUnwrap(state.tasks.first)
        let modelReceipt = try XCTUnwrap(state.modelReceipts.first)
        let checkpoint = try XCTUnwrap(
            state.checkpoints.first { $0.revision == modelReceipt.checkpointRevision }
        )
        let structuralResultID = UUID(
            uuidString: "38000000-0000-0000-0000-000000000098"
        )!
        let structuralPayload = Data("cascade".utf8)
        try fixture.database.executeRawForTesting(
            """
            INSERT INTO reconstruction_final_results (
              workspace_uuid, result_id, job_id, task_id, checkpoint_id,
              checkpoint_revision, request_id, request_identity_sha256, kind,
              payload_byte_count, payload_sha256, producer_canonical_sha256,
              model_receipt_id, canonical_sha256, record_json
            ) VALUES (
              '\(fixture.workspaceUUID.uuidString)', '\(structuralResultID.uuidString)',
              '\(job.jobID.uuidString)', '\(task.identity.taskID.uuidString)',
              '\(checkpoint.checkpointID.uuidString)', \(checkpoint.revision),
              '\(modelReceipt.receiptID.uuidString)',
              '\(modelReceipt.requestIdentitySHA256)', 'synthesis',
              \(structuralPayload.count),
              '\(ReconstructionDatabaseTestFixtures.sha256(structuralPayload))',
              '\(modelReceipt.producer.canonicalSHA256)',
              '\(modelReceipt.receiptID.uuidString)',
              '\(ReconstructionDatabaseTestFixtures.digest("f"))',
              \(blobLiteral(Data("{}".utf8)))
            );
            """
        )

        for table in ReconstructionDatabaseTestFixtures.reconstructionTableNames.sorted() {
            XCTAssertGreaterThan(
                try fixture.database.scalarIntForTesting(
                    "SELECT COUNT(*) FROM \(table) WHERE workspace_uuid = '\(fixture.workspaceUUID.uuidString)';"
                ),
                0,
                "Fixture must exercise the \(table) cascade"
            )
        }

        try fixture.database.executeRawForTesting(
            "DELETE FROM workspaces WHERE uuid = '\(fixture.workspaceUUID.uuidString)';"
        )

        for table in ReconstructionDatabaseTestFixtures.reconstructionTableNames.sorted() {
            XCTAssertEqual(
                try fixture.database.scalarIntForTesting(
                    "SELECT COUNT(*) FROM \(table) WHERE workspace_uuid = '\(fixture.workspaceUUID.uuidString)';"
                ),
                0,
                "\(table) retained orphaned workspace rows"
            )
        }
    }

    func testReplacingBinarySnapshotPreservesDurableEvidenceAndProjectsFreshnessExternally()
        throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let initial = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID,
            evidenceSubjectUsesImageBinding: true
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: initial
        )

        let replaced = try fixture.database.replaceWorkspaceState(
            workspaceID: fixture.workspaceRowID,
            workspaceName: "Replaced",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: Date(timeIntervalSince1970: 1_900_000_100)
        )

        XCTAssertEqual(replaced.reconstructionState.evidence, initial.evidence)
        XCTAssertEqual(
            Set(replaced.reconstructionState.evidence.map(\.classification)),
            [.acceptedCurrent]
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_evidence;"
            ),
            initial.evidence.count
        )
        XCTAssertEqual(
            replaced.reconstructionState.evidence.map(\.subject),
            initial.evidence.map(\.subject)
        )
        let manifest = try XCTUnwrap(initial.corpusManifests.first)
        let staleAuthority = try ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
            manifest: manifest,
            authoritativeSubjects: initial.evidence.map(\.subject),
            includesCurrentAnalysis: false
        )
        let currentAuthority = try ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
            manifest: manifest,
            authoritativeSubjects: initial.evidence.map(\.subject),
            includesCurrentAnalysis: true
        )
        XCTAssertEqual(
            Set(try ReconstructionEvidenceProjector().project(
                records: replaced.reconstructionState.evidence,
                relations: replaced.reconstructionState.evidenceRelations,
                authority: staleAuthority
            ).records.map(\.classification)),
            [.staleAnalysis]
        )
        XCTAssertEqual(
            Set(try ReconstructionEvidenceProjector().project(
                records: replaced.reconstructionState.evidence,
                relations: replaced.reconstructionState.evidenceRelations,
                authority: currentAuthority
            ).records.map(\.classification)),
            [.acceptedCurrent]
        )
    }

    func testReplacingBinarySnapshotPreservesTerminalEvidenceClassificationMatrix() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let initial = try ReconstructionDatabaseTestFixtures.makeStateWithEveryEvidenceClassification(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: initial
        )

        let replaced = try fixture.database.replaceWorkspaceState(
            workspaceID: fixture.workspaceRowID,
            workspaceName: "Classification Matrix",
            snapshot: WorkspaceSnapshot(
                binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
            ),
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            now: Date(timeIntervalSince1970: 1_900_000_200)
        )

        let before = Dictionary(uniqueKeysWithValues: initial.evidence.map {
            ($0.evidenceID, $0.classification)
        })
        let after = Dictionary(uniqueKeysWithValues: replaced.reconstructionState.evidence.map {
            ($0.evidenceID, $0.classification)
        })
        XCTAssertEqual(after.count, ReconstructionEvidenceClassification.allCases.count)
        for (evidenceID, classification) in before {
            XCTAssertEqual(
                after[evidenceID],
                classification,
                "Workspace replacement rewrote durable \(classification) evidence"
            )
        }
    }

    func testProductionRoundBasisRejectsStalePersistedImageFingerprint() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID,
            evidenceSubjectUsesImageBinding: true
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = temporaryRoot.appendingPathComponent("source.bin")
        let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: sourceURL, options: .atomic)
        fixture.database.configureReconstructionAttachmentVault(rootURL: vaultURL)
        _ = try fixture.database.publishDurableReconstructionAttachmentSources(
            [ReconstructionAttachmentSource(
                contentIdentity: foundation.occurrence.contentIdentity,
                verifiedURL: sourceURL
            )],
            for: foundation.manifest
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )

        let rows = try fixture.database.captureReconstructionProductionRoundRows(
            workspaceID: fixture.workspaceUUID,
            jobID: foundation.job.jobID
        )
        let basis = try ReconstructionProductionRoundBasis(rows: rows)
        XCTAssertEqual(basis.checkpoint, foundation.checkpoint)
        XCTAssertEqual(basis.freshnessAuthority.currentImages.count, 1)

        try ReconstructionDatabaseTestFixtures.replacePersistedAnalysisFingerprint(
            in: fixture,
            overallSHA256: ReconstructionDatabaseTestFixtures.digest("4")
        )
        XCTAssertThrowsError(try fixture.database.captureReconstructionProductionRoundRows(
            workspaceID: fixture.workspaceUUID,
            jobID: foundation.job.jobID
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionCheckpointConflict("workspace analysis authority changed")
            )
        }
    }

    func testFutureSchemaVersionRemainsRejected() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.setUserVersionForTesting(WorkspaceDatabase.schemaVersion + 1)

        XCTAssertThrowsError(try database.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .unsupportedSchemaVersion(
                    stored: WorkspaceDatabase.schemaVersion + 1,
                    supported: WorkspaceDatabase.schemaVersion
                )
            )
        }
        XCTAssertEqual(try database.tableNames(), [])
    }

    private struct InvalidGraphParityCase {
        let name: String
        let mutation: (inout [String: Any]) throws -> Void
    }

    private func invalidGraphParityCases() -> [InvalidGraphParityCase] {
        let unknownJobID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let peerTaskID = "39000000-0000-0000-0000-000000000001"

        return [
            InvalidGraphParityCase(name: "orphan checkpoint") { object in
                var checkpoints = try self.objectArray("checkpoints", in: object)
                checkpoints[0]["jobID"] = unknownJobID
                object["checkpoints"] = checkpoints
            },
            InvalidGraphParityCase(name: "task dependency cycle") { object in
                let firstTaskID = try self.addCompletedPeerTask(
                    peerTaskID,
                    to: &object
                )
                var tasks = try self.objectArray("tasks", in: object)
                var first = tasks[0]
                var firstIdentity = try XCTUnwrap(first["identity"] as? [String: Any])
                firstIdentity["dependencyTaskIDs"] = [peerTaskID]
                first["identity"] = firstIdentity
                tasks[0] = first
                var peer = tasks[1]
                var peerIdentity = try XCTUnwrap(peer["identity"] as? [String: Any])
                peerIdentity["dependencyTaskIDs"] = [firstTaskID]
                peer["identity"] = peerIdentity
                tasks[1] = peer
                object["tasks"] = tasks
            },
            InvalidGraphParityCase(name: "non-tail current checkpoint") { object in
                let checkpoints = try self.objectArray("checkpoints", in: object)
                let rootIndex = try self.checkpointIndex(revision: 0, in: checkpoints)
                let rootID = try XCTUnwrap(checkpoints[rootIndex]["checkpointID"] as? String)
                var jobs = try self.objectArray("jobs", in: object)
                jobs[0]["currentCheckpointID"] = rootID
                object["jobs"] = jobs
            },
            InvalidGraphParityCase(name: "incomplete authoritative task frontier") { object in
                var checkpoints = try self.objectArray("checkpoints", in: object)
                let tailIndex = try self.checkpointIndex(revision: 1, in: checkpoints)
                checkpoints[tailIndex]["completedTaskIDs"] = []
                object["checkpoints"] = checkpoints
            },
            InvalidGraphParityCase(name: "cancelled task in completed bucket") { object in
                var tasks = try self.objectArray("tasks", in: object)
                tasks[0]["state"] = ReconstructionTaskState.cancelled.rawValue
                object["tasks"] = tasks
            },
            InvalidGraphParityCase(name: "job and tail state mismatch") { object in
                var jobs = try self.objectArray("jobs", in: object)
                jobs[0]["state"] = ReconstructionJobState.awaitingModel.rawValue
                object["jobs"] = jobs
            },
            InvalidGraphParityCase(name: "job and tail terminal mismatch") { object in
                var jobs = try self.objectArray("jobs", in: object)
                jobs[0]["state"] = ReconstructionJobState.failed.rawValue
                jobs[0]["terminalReason"] = "job failed"
                object["jobs"] = jobs
                var checkpoints = try self.objectArray("checkpoints", in: object)
                let tailIndex = try self.checkpointIndex(revision: 1, in: checkpoints)
                checkpoints[tailIndex]["coordinatorState"] = ReconstructionJobState.failed.rawValue
                checkpoints[tailIndex]["terminalReason"] = "checkpoint failed"
                object["checkpoints"] = checkpoints
            },
            InvalidGraphParityCase(name: "evidence payload digest mismatch") { object in
                var evidence = try self.objectArray("evidence", in: object)
                evidence[0]["payloadSHA256"] = String(repeating: "8", count: 64)
                object["evidence"] = evidence
            },
            InvalidGraphParityCase(name: "evidence payload byte-count mismatch") { object in
                var evidence = try self.objectArray("evidence", in: object)
                let byteCount = try XCTUnwrap(evidence[0]["payloadByteCount"] as? NSNumber)
                evidence[0]["payloadByteCount"] = byteCount.uint64Value + 1
                object["evidence"] = evidence
            },
            InvalidGraphParityCase(name: "tool receipt foreign job") { object in
                var receipts = try self.objectArray("toolReceipts", in: object)
                receipts[0]["jobID"] = unknownJobID
                object["toolReceipts"] = receipts
            },
            InvalidGraphParityCase(name: "model receipt foreign job") { object in
                var receipts = try self.objectArray("modelReceipts", in: object)
                receipts[0]["jobID"] = unknownJobID
                object["modelReceipts"] = receipts
            },
            InvalidGraphParityCase(name: "tool receipt task mismatch") { object in
                _ = try self.addCompletedPeerTask(peerTaskID, to: &object)
                var receipts = try self.objectArray("toolReceipts", in: object)
                receipts[0]["taskID"] = peerTaskID
                object["toolReceipts"] = receipts
            },
            InvalidGraphParityCase(name: "model receipt task mismatch") { object in
                _ = try self.addCompletedPeerTask(peerTaskID, to: &object)
                var receipts = try self.objectArray("modelReceipts", in: object)
                receipts[0]["taskID"] = peerTaskID
                object["modelReceipts"] = receipts
            },
            InvalidGraphParityCase(name: "tool evidence revision mismatch") { object in
                let checkpoints = try self.objectArray("checkpoints", in: object)
                let rootIndex = try self.checkpointIndex(revision: 0, in: checkpoints)
                let rootID = try XCTUnwrap(checkpoints[rootIndex]["checkpointID"] as? String)
                var evidence = try self.objectArray("evidence", in: object)
                evidence[0]["creatingCheckpointID"] = rootID
                object["evidence"] = evidence
            },
            InvalidGraphParityCase(name: "model evidence revision mismatch") { object in
                let checkpoints = try self.objectArray("checkpoints", in: object)
                let rootIndex = try self.checkpointIndex(revision: 0, in: checkpoints)
                let rootID = try XCTUnwrap(checkpoints[rootIndex]["checkpointID"] as? String)
                var evidence = try self.objectArray("evidence", in: object)
                evidence[1]["creatingCheckpointID"] = rootID
                object["evidence"] = evidence
            },
            InvalidGraphParityCase(name: "tool evidence omits receipt membership") { object in
                var receipts = try self.objectArray("toolReceipts", in: object)
                receipts[0]["outputEvidenceIDs"] = []
                object["toolReceipts"] = receipts
            },
            InvalidGraphParityCase(name: "model evidence omits receipt membership") { object in
                var receipts = try self.objectArray("modelReceipts", in: object)
                receipts[0]["acceptedEvidenceIDs"] = []
                object["modelReceipts"] = receipts
            },
            InvalidGraphParityCase(name: "tool receipt lacks evidence backlink") { object in
                var evidence = try self.objectArray("evidence", in: object)
                evidence[0].removeValue(forKey: "toolReceiptID")
                object["evidence"] = evidence
            },
            InvalidGraphParityCase(name: "model receipt lacks evidence backlink") { object in
                var evidence = try self.objectArray("evidence", in: object)
                evidence[1].removeValue(forKey: "modelReceiptID")
                object["evidence"] = evidence
            },
        ]
    }

    private func mutatedState(
        _ state: ReconstructionWorkspaceState,
        using mutation: (inout [String: Any]) throws -> Void
    ) throws -> ReconstructionWorkspaceState {
        let data = try ReconstructionCanonicalJSON.encode(state)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try mutation(&object)
        let mutatedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(
            ReconstructionWorkspaceState.self,
            from: mutatedData
        )
        let checkpoints = try decoded.checkpoints.map { checkpoint in
            try ReconstructionCheckpoint.make(
                checkpointID: checkpoint.checkpointID,
                schemaVersion: checkpoint.schemaVersion,
                jobID: checkpoint.jobID,
                revision: checkpoint.revision,
                parentCheckpointID: checkpoint.parentCheckpointID,
                parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
                corpusManifestSHA256: checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
                pendingTaskIDs: checkpoint.pendingTaskIDs,
                runningTaskIDs: checkpoint.runningTaskIDs,
                completedTaskIDs: checkpoint.completedTaskIDs,
                failedTaskIDs: checkpoint.failedTaskIDs,
                blockedTaskIDs: checkpoint.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: checkpoint.modelReceiptIDs,
                toolReceiptIDs: checkpoint.toolReceiptIDs,
                coordinatorState: checkpoint.coordinatorState,
                terminalReason: checkpoint.terminalReason
            )
        }
        return try ReconstructionWorkspaceState(
            schemaVersion: decoded.schemaVersion,
            projects: decoded.projects,
            corpusManifests: decoded.corpusManifests,
            evidence: decoded.evidence,
            evidenceRelations: decoded.evidenceRelations,
            evidenceGaps: decoded.evidenceGaps,
            jobs: decoded.jobs,
            tasks: decoded.tasks,
            checkpoints: checkpoints,
            toolReceipts: decoded.toolReceipts,
            modelReceipts: decoded.modelReceipts
        )
    }

    private func objectArray(
        _ key: String,
        in object: [String: Any]
    ) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]], "Missing object array: \(key)")
    }

    private func checkpointIndex(
        revision: UInt64,
        in checkpoints: [[String: Any]]
    ) throws -> Int {
        try XCTUnwrap(checkpoints.firstIndex {
            ($0["revision"] as? NSNumber)?.uint64Value == revision
        })
    }

    @discardableResult
    private func addCompletedPeerTask(
        _ peerTaskID: String,
        to object: inout [String: Any]
    ) throws -> String {
        var tasks = try objectArray("tasks", in: object)
        let first = try XCTUnwrap(tasks.first)
        let firstIdentity = try XCTUnwrap(first["identity"] as? [String: Any])
        let firstTaskID = try XCTUnwrap(firstIdentity["taskID"] as? String)
        var peer = first
        var peerIdentity = firstIdentity
        peerIdentity["taskID"] = peerTaskID
        peerIdentity["dependencyTaskIDs"] = []
        peer["identity"] = peerIdentity
        tasks.append(peer)
        object["tasks"] = tasks

        var checkpoints = try objectArray("checkpoints", in: object)
        let tailIndex = try checkpointIndex(revision: 1, in: checkpoints)
        var completedTaskIDs = try XCTUnwrap(
            checkpoints[tailIndex]["completedTaskIDs"] as? [String]
        )
        completedTaskIDs.append(peerTaskID)
        checkpoints[tailIndex]["completedTaskIDs"] = completedTaskIDs.sorted()
        object["checkpoints"] = checkpoints
        return firstTaskID
    }

    private func assertDatabaseGraphRejected(
        _ operation: () throws -> Void,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail(name, file: file, line: line)
        } catch let error as WorkspaceDatabase.DatabaseError {
            guard case .reconstructionStateInvalid = error else {
                return XCTFail(
                    "Expected reconstructionStateInvalid for \(name), got \(error)",
                    file: file,
                    line: line
                )
            }
        } catch {
            XCTFail(
                "Expected WorkspaceDatabase.DatabaseError for \(name), got \(error)",
                file: file,
                line: line
            )
        }
    }

    private func job(
        _ job: ReconstructionJobRecord,
        objectiveSHA256: String
    ) throws -> ReconstructionJobRecord {
        try ReconstructionJobRecord(
            jobID: job.jobID,
            reconstructionProjectID: job.reconstructionProjectID,
            objective: job.objective,
            objectiveSHA256: objectiveSHA256,
            creationCorpusManifestSHA256: job.creationCorpusManifestSHA256,
            state: job.state,
            currentCheckpointID: job.currentCheckpointID,
            terminalReason: job.terminalReason,
            budget: job.budget,
            creationOrdinal: try XCTUnwrap(job.creationOrdinal),
            pauseContext: job.pauseContext
        )
    }

    private func state(
        _ state: ReconstructionWorkspaceState,
        replacing job: ReconstructionJobRecord
    ) throws -> ReconstructionWorkspaceState {
        try ReconstructionWorkspaceState(
            projects: state.projects,
            corpusManifests: state.corpusManifests,
            evidence: state.evidence,
            evidenceRelations: state.evidenceRelations,
            evidenceGaps: state.evidenceGaps,
            jobs: [job],
            tasks: state.tasks,
            checkpoints: state.checkpoints,
            toolReceipts: state.toolReceipts,
            modelReceipts: state.modelReceipts
        )
    }

    private func blobLiteral(_ data: Data) -> String {
        "X'\(data.map { String(format: "%02x", $0) }.joined())'"
    }
}

final class ReconstructionDeterministicEvidenceEmitterTests: XCTestCase {
    private static let outputEnvironment = "MACSCOPE_DETERMINISTIC_EVIDENCE_OUTPUT_ROOT"

    /// Qualification-only, deterministic wire shape for the complete evidence cut.
    ///
    /// `ReconstructionEvidenceCut` deliberately models its two lookup tables as UUID-keyed
    /// dictionaries. Foundation encodes those dictionaries as unkeyed arrays whose order follows
    /// randomized hash iteration, so directly encoding the cut is not stable across fresh
    /// processes. This projection preserves every cut field while giving both maps an explicit,
    /// UUID-sorted representation. It does not define scenarios or change the product model.
    private struct EvidenceFrontierArtifact: Encodable {
        let cut: ReconstructionEvidenceCut

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case domain
            case corpusManifestSHA256
            case records
            case relations
            case gaps
            case frontierSHA256
            case projectedClassifications
            case checkpointRevisions
        }

        private enum ProjectedClassificationKeys: String, CodingKey {
            case evidenceID
            case classification
        }

        private enum CheckpointRevisionKeys: String, CodingKey {
            case checkpointID
            case revision
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(1, forKey: .schemaVersion)
            try container.encode(
                "reconstruction.deterministic-evidence-frontier.v1",
                forKey: .domain
            )
            try container.encode(cut.corpusManifestSHA256, forKey: .corpusManifestSHA256)
            try container.encode(cut.records, forKey: .records)
            try container.encode(cut.relations, forKey: .relations)
            try container.encode(cut.gaps, forKey: .gaps)
            try container.encode(cut.frontierSHA256, forKey: .frontierSHA256)

            var projectedClassifications = container.nestedUnkeyedContainer(
                forKey: .projectedClassifications
            )
            for evidenceID in cut.projectedClassificationsByEvidenceID.keys.sorted(by: {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }) {
                var entry = projectedClassifications.nestedContainer(
                    keyedBy: ProjectedClassificationKeys.self
                )
                try entry.encode(evidenceID, forKey: .evidenceID)
                try entry.encode(
                    cut.projectedClassificationsByEvidenceID[evidenceID],
                    forKey: .classification
                )
            }

            var checkpointRevisions = container.nestedUnkeyedContainer(
                forKey: .checkpointRevisions
            )
            for checkpointID in cut.checkpointRevisionsByID.keys.sorted(by: {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }) {
                var entry = checkpointRevisions.nestedContainer(
                    keyedBy: CheckpointRevisionKeys.self
                )
                try entry.encode(checkpointID, forKey: .checkpointID)
                try entry.encode(cut.checkpointRevisionsByID[checkpointID], forKey: .revision)
            }
        }
    }

    func testEmitsCanonicalDeterministicEvidenceArtifacts() throws {
        let workspaceBinaryID = try XCTUnwrap(
            UUID(uuidString: "38000000-0000-0000-0000-000000000038")
        )
        let state = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: workspaceBinaryID
        )
        let manifest = try XCTUnwrap(state.corpusManifests.first)
        let checkpoint = try XCTUnwrap(state.checkpoints.max { $0.revision < $1.revision })
        let receipt = try XCTUnwrap(state.toolReceipts.first)
        let projectedClassifications = Dictionary(
            uniqueKeysWithValues: state.evidence.map { ($0.evidenceID, $0.classification) }
        )
        let checkpointsByID = Dictionary(
            uniqueKeysWithValues: state.checkpoints.map { ($0.checkpointID, $0) }
        )
        let checkpointRevisions = try Dictionary(
            uniqueKeysWithValues: Set(state.evidence.map(\.creatingCheckpointID)).map { checkpointID in
                (checkpointID, try XCTUnwrap(checkpointsByID[checkpointID]).revision)
            }
        )
        let frontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: state.evidence,
            projectedClassificationsByEvidenceID: projectedClassifications,
            relations: state.evidenceRelations,
            gaps: state.evidenceGaps,
            checkpointRevisionsByID: checkpointRevisions
        )
        XCTAssertEqual(frontierSHA256, checkpoint.evidenceFrontierSHA256)
        let cut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: state.evidence,
            relations: state.evidenceRelations,
            gaps: state.evidenceGaps,
            frontierSHA256: frontierSHA256,
            projectedClassificationsByEvidenceID: projectedClassifications,
            checkpointRevisionsByID: checkpointRevisions
        )
        let operations = try Set(state.evidence.map { record in
            try XCTUnwrap(MacScopeAnalysisCore.ReconstructionOperationID(rawValue: record.operationID))
        }).sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.rawValue < $1.rawValue
        }
        let classifications = Set(projectedClassifications.values).sorted {
            $0.rawValue < $1.rawValue
        }
        let job = try XCTUnwrap(state.jobs.first)
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: manifest.canonicalSHA256,
            subject: nil,
            operationIDs: operations,
            classifications: classifications,
            cursor: nil,
            maximumRecords: max(1, state.evidence.count),
            maximumEncodedBytes: Int(job.budget.maxEncodedBytes)
        )
        let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        XCTAssertFalse(packet.canonicalBytes.isEmpty)

        let artifactBytes: [(String, Data)] = [
            ("corpus-manifest.json", try ReconstructionCanonicalJSON.encode(manifest)),
            (
                "evidence-frontier.json",
                try ReconstructionCanonicalJSON.encode(EvidenceFrontierArtifact(cut: cut))
            ),
            ("retrieval-packet.json", packet.canonicalBytes),
            ("tool-receipt.json", try ReconstructionCanonicalJSON.encode(receipt)),
            ("checkpoint.json", try ReconstructionCanonicalJSON.encode(checkpoint)),
        ]
        XCTAssertTrue(artifactBytes.allSatisfy { !$0.1.isEmpty })

        guard let outputPath = ProcessInfo.processInfo.environment[Self.outputEnvironment] else {
            return
        }
        let requestedOutputRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
        let values = try requestedOutputRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        XCTAssertEqual(values.isDirectory, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
        let outputRoot = requestedOutputRoot.resolvingSymlinksInPath().standardizedFileURL
        for (relativePath, bytes) in artifactBytes {
            let destination = outputRoot.appendingPathComponent(relativePath, isDirectory: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try bytes.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }
    }
}

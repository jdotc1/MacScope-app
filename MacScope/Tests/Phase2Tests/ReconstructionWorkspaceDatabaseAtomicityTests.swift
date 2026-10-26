import Darwin
import Foundation
import XCTest

@testable import MacScope

final class ReconstructionWorkspaceDatabaseAtomicityTests: XCTestCase {
    func testAdmittedSourceOracleCheckpointCommitsAndReloadsThroughPackageGraph() throws {
        try exerciseSourceOraclePersistence(unknownOperation: false)
    }

    func testUnknownSourceOperationRollsBackCheckpointAndEvidence() throws {
        try exerciseSourceOraclePersistence(unknownOperation: true)
    }

    /// Uses real admitted oracle bytes and the same receipt/evidence publication shape, with a
    /// small valid database history. The production author’s synthetic cp12 fixture is tested
    /// separately; this control exercises the persistence consumer it previously omitted.
    private func exerciseSourceOraclePersistence(unknownOperation: Bool) throws {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: database.binaryID, evidenceSubjectUsesFunction: true)
        guard case .function(let function)? = foundation.task.identity.subject else {
            return XCTFail("Expected function authority")
        }
        let seedTaskID = UUID(), seedEvidenceID = UUID(), seedReceiptID = UUID()
        let sourceTask = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
            taskID: foundation.task.identity.taskID, jobID: foundation.job.jobID,
            kind: .executeSource, subject: .function(function), dependencyTaskIDs: [seedTaskID],
            operationContractIdentity: ReconstructionSourceExecutionTaskContract.oracle), state: .pending, diagnostic: nil)
        let seedTask = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
            taskID: seedTaskID, jobID: foundation.job.jobID, kind: .decompileNative,
            subject: .function(function), dependencyTaskIDs: [],
            operationContractIdentity: foundation.task.identity.operationContractIdentity), state: .completed, diagnostic: nil)
        let seedProducer = try ReconstructionDatabaseTestFixtures.makeProducer(operationID: ReconstructionOperationID.evidenceQuery.rawValue)
        let seedBytes = Data("Committed original function context".utf8)
        let seedReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: seedReceiptID,
            jobID: foundation.job.jobID, taskID: seedTaskID, checkpointRevision: 0,
            requestIdentitySHA256: String(repeating: "b", count: 64), producer: seedProducer,
            terminalState: .completed, outputEvidenceIDs: [seedEvidenceID], diagnostic: nil)
        let seed = try ReconstructionEvidenceRecord(evidenceID: seedEvidenceID, subject: .function(function),
            operationID: ReconstructionOperationID.evidenceQuery.rawValue, payloadKind: .text, payload: seedBytes,
            payloadByteCount: UInt64(seedBytes.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(seedBytes),
            facetDependencies: [], producer: seedProducer,
            citations: [try .init(citationID: UUID(), sourceEvidenceID: nil, subject: .function(function), locator: nil)],
            creatingJobID: foundation.job.jobID, creatingTaskID: seedTaskID,
            creatingCheckpointID: foundation.checkpoint.checkpointID, modelReceiptID: nil,
            toolReceiptID: seedReceiptID, classification: .acceptedCurrent, supersedesEvidenceID: nil,
            supersededByEvidenceID: nil, diagnostic: nil)
        let freshness = try ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
            from: foundation, includesCurrentAnalysis: false)
        func frontier(_ records: [ReconstructionEvidenceRecord], revisions: [UUID: UInt64]) throws -> String {
            let projection = try ReconstructionEvidenceProjector().project(records: records, relations: [], authority: freshness)
            return try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: foundation.manifest.canonicalSHA256, records: records,
                projectedClassificationsByEvidenceID: Dictionary(uniqueKeysWithValues: projection.records.map {
                    ($0.record.evidenceID, $0.classification)
                }), relations: [], gaps: foundation.state.evidenceGaps, checkpointRevisionsByID: revisions)
        }
        let parent = try ReconstructionCheckpoint.make(checkpointID: foundation.checkpoint.checkpointID,
            jobID: foundation.job.jobID, revision: 0, parentCheckpointID: nil, parentCheckpointSHA256: nil,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier([seed], revisions: [foundation.checkpoint.checkpointID: 0]),
            pendingTaskIDs: [sourceTask.identity.taskID], runningTaskIDs: [], completedTaskIDs: [seedTaskID],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [], toolReceiptIDs: [seedReceiptID], coordinatorState: .retrieving, terminalReason: nil)
        let initialState = try ReconstructionWorkspaceState(projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests, evidence: [seed], evidenceRelations: [],
            evidenceGaps: foundation.state.evidenceGaps, jobs: foundation.state.jobs,
            tasks: [sourceTask, seedTask], checkpoints: [parent], toolReceipts: [seedReceipt], modelReceipts: [])
        try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID, state: initialState)
        let baseline = try database.database.loadReconstructionState(workspaceID: database.workspaceUUID)
        let operation = unknownOperation ? "reconstruction.source.unregistered" : ReconstructionSourceOracleEvidence.operationID
        let producer = try ReconstructionDatabaseTestFixtures.makeProducer(operationID: operation)
        let hash = String(repeating: "a", count: 64)
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let oracle = try ReconstructionSourceOracleEvidence.admit(authority: .init(
            projectID: foundation.project.projectID, jobID: foundation.job.jobID, function: function,
            execution: .init(originalImageSHA256: function.artifact.contentIdentity.digest,
                originalExecutableSHA256: function.artifact.contentIdentity.digest, originalSourceSHA256: nil,
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: hash, sdkIdentitySHA256: hash, compileProfileSHA256: hash,
                compileArgumentsSHA256: hash, executionArgumentsSHA256: hash,
                producerSHA256: producer.canonicalSHA256,
                standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8),
                sessionID: UUID(), requestID: UUID(), processIdentifier: 123,
                sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true),
            evidenceIDs: [seedEvidenceID]))
        let bytes = try ReconstructionSourceOracleEvidence.encode(oracle)
        let evidenceID = UUID(), receiptID = UUID(), checkpointID = UUID()
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: receiptID,
            jobID: foundation.job.jobID, taskID: foundation.task.identity.taskID,
            checkpointRevision: 1, requestIdentitySHA256: hash, producer: producer,
            terminalState: .completed, outputEvidenceIDs: [evidenceID], diagnostic: nil)
        let record = try ReconstructionEvidenceRecord(evidenceID: evidenceID, subject: .function(function),
            operationID: operation, payloadKind: .structuredJSON, payload: bytes,
            payloadByteCount: UInt64(bytes.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes),
            facetDependencies: [], producer: producer,
            citations: [try .init(citationID: seedEvidenceID, sourceEvidenceID: seedEvidenceID, subject: nil, locator: nil)], creatingJobID: foundation.job.jobID,
            creatingTaskID: foundation.task.identity.taskID, creatingCheckpointID: checkpointID,
            modelReceiptID: nil, toolReceiptID: receiptID, classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let evidenceFrontier = try frontier([seed, record], revisions: [parent.checkpointID: 0, checkpointID: 1])
        let successor = try ReconstructionCheckpoint.make(checkpointID: checkpointID,
            jobID: foundation.job.jobID, revision: 1, parentCheckpointID: foundation.checkpoint.checkpointID,
            parentCheckpointSHA256: parent.canonicalSHA256,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256, evidenceFrontierSHA256: evidenceFrontier,
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [sourceTask.identity.taskID, seedTaskID],
            failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [], toolReceiptIDs: [seedReceiptID, receiptID], coordinatorState: .retrieving, terminalReason: nil)
        if !unknownOperation {
            let completedSourceTask = ReconstructionTaskRecord(identity: sourceTask.identity, state: .completed, diagnostic: nil)
            XCTAssertEqual(try ReconstructionSourceOracleEvidence.make(evidenceID: evidenceID, context: .init(
                authority: .init(projectID: oracle.projectID, jobID: oracle.jobID, function: function,
                    execution: oracle.execution, evidenceIDs: oracle.evidenceIDs),
                task: completedSourceTask, checkpoint: successor, toolReceipt: receipt,
                expectedRequestIdentitySHA256: hash, expectedProducer: producer,
                committedEvidenceCut: baseline.evidence)), record)
        }
        let mutation = ReconstructionCheckpointMutation(jobID: foundation.job.jobID,
            expectedParentCheckpointID: foundation.checkpoint.checkpointID,
            expectedParentCheckpointSHA256: parent.canonicalSHA256,
            expectedParentRevision: 0, evidence: [record], evidenceRelations: [],
            toolReceipts: [receipt], modelReceipts: [],
            taskTransitions: [.init(taskID: foundation.task.identity.taskID, expectedState: .pending,
                successorState: .completed, diagnostic: nil)], freshnessAuthority: freshness,
            successorCheckpoint: successor)
        if unknownOperation {
            XCTAssertThrowsError(try database.database.commitReconstructionCheckpoint(
                workspaceID: database.workspaceUUID, mutation: mutation)) { error in
                XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError,
                    .reconstructionStateInvalid("package-v3 graph: evidence operation ID"))
            }
            XCTAssertEqual(try database.database.loadReconstructionState(workspaceID: database.workspaceUUID), baseline)
        } else {
            let committed = try database.database.commitReconstructionCheckpoint(
                workspaceID: database.workspaceUUID, mutation: mutation)
            let loaded = try database.database.loadReconstructionState(workspaceID: database.workspaceUUID)
            XCTAssertEqual(loaded, committed.state)
            try ReconstructionPackageCodec.validateGraph(loaded)
            XCTAssertEqual(Set(loaded.toolReceipts), Set([seedReceipt, receipt]))
            XCTAssertEqual(Set(loaded.evidence), Set([seed, record]))
            XCTAssertEqual(try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(
                payload: XCTUnwrap(loaded.evidence.first { $0.evidenceID == evidenceID }).payload), oracle)
            XCTAssertEqual(oracle.outputs.count, 37)
        }
    }

    // MARK: - Reconstruction sidecar binding atomicity

    func testBootstrapAtomicallyCreatesExactWorkspaceAndDocumentBinding() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()

        let workspaceRowID = try fixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Reconstruction Sidecar",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )

        XCTAssertEqual(try fixture.database.workspaces(), [
            WorkspaceDatabase.WorkspaceRecord(
                id: workspaceRowID,
                uuid: Self.workspaceUUID,
                name: "Reconstruction Sidecar",
                createdAt: Self.now,
                modifiedAt: Self.now
            ),
        ])
        XCTAssertEqual(
            try fixture.database.workspaceDocument(workspaceID: workspaceRowID),
            WorkspaceDatabase.WorkspaceDocumentRecord(
                workspaceID: workspaceRowID,
                documentID: Self.documentID,
                packagePath: Self.packagePath,
                lastOpenedAt: Self.now,
                lastSavedAt: nil,
                isDirty: false,
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .usePackageAttachmentsOnly,
                recentDocumentState: .available,
                recentDocumentStateUpdatedAt: Self.now
            )
        )
        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .matched(workspaceRowID: workspaceRowID)
        )
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: Self.workspaceUUID),
            .empty
        )
    }

    func testBootstrapCanonicalizesSubmillisecondTimeBeforeExactIdentityVerification() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()

        let suppliedNow = Date(timeIntervalSince1970: 1_787_000_000.123_456)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let persistedNowText = formatter.string(from: suppliedNow)
        let persistedNow = try XCTUnwrap(formatter.date(from: persistedNowText))
        XCTAssertNotEqual(suppliedNow, persistedNow)

        let workspaceRowID = try fixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Submillisecond Sidecar",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: suppliedNow
        )

        XCTAssertEqual(try fixture.database.workspaces(), [
            WorkspaceDatabase.WorkspaceRecord(
                id: workspaceRowID,
                uuid: Self.workspaceUUID,
                name: "Submillisecond Sidecar",
                createdAt: persistedNow,
                modifiedAt: persistedNow
            ),
        ])
        XCTAssertEqual(
            try fixture.database.workspaceDocument(workspaceID: workspaceRowID),
            WorkspaceDatabase.WorkspaceDocumentRecord(
                workspaceID: workspaceRowID,
                documentID: Self.documentID,
                packagePath: Self.packagePath,
                lastOpenedAt: persistedNow,
                lastSavedAt: nil,
                isDirty: false,
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .usePackageAttachmentsOnly,
                recentDocumentState: .available,
                recentDocumentStateUpdatedAt: persistedNow
            )
        )
        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .matched(workspaceRowID: workspaceRowID)
        )
    }

    func testInjectedBootstrapFailureRollsBackWorkspaceAndDocumentRows() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        fixture.database.setReconstructionSidecarBootstrapFailureForTesting(
            after: .insertedWorkspace
        )

        XCTAssertThrowsError(
            try fixture.database.bootstrapReconstructionWorkspaceSidecar(
                workspaceUUID: Self.workspaceUUID,
                workspaceName: "Must Roll Back",
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath,
                now: Self.now
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionInjectedFailure("sidecar-insertedWorkspace")
            )
        }

        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"),
            0
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM workspace_documents;"
            ),
            0
        )
        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .emptyCurrentSchema
        )
    }

    func testRollbackFailureReportsBothDiagnosticsPoisonsConnectionAndPreservesRows() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        fixture.database.setReconstructionSidecarBootstrapFailureForTesting(
            after: .insertedWorkspace
        )
        fixture.database.setTransactionRollbackFailureForTesting(true)

        XCTAssertThrowsError(
            try fixture.database.bootstrapReconstructionWorkspaceSidecar(
                workspaceUUID: Self.workspaceUUID,
                workspaceName: "Rollback Failure Must Poison",
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath,
                now: Self.now
            )
        ) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError,
                  case let .transactionRollbackFailed(original, rollback) = databaseError else {
                return XCTFail("Expected explicit transaction rollback failure, got \(error)")
            }
            XCTAssertTrue(original.contains("sidecar-insertedWorkspace"))
            XCTAssertTrue(rollback.contains("Injected transaction rollback failure"))
        }

        XCTAssertThrowsError(try fixture.database.userVersion()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .openFailed("Database connection is closed.")
            )
        }

        let reopened = try WorkspaceDatabase(path: fixture.databaseURL.path)
        try reopened.applySchema()
        XCTAssertEqual(
            try reopened.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"),
            0,
            "closing the poisoned handle must leave the failed transaction uncommitted"
        )
    }

    func testPinnedVaultReopenScavengesExactCrashStageWithoutTouchingPublishedDigest() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: Self.workspaceBinaryID
        )
        let sourceURL = fixture.rootURL.appendingPathComponent("source.bin", isDirectory: false)
        let vaultURL = fixture.rootURL.appendingPathComponent("vault", isDirectory: true)
        let sourceBytes = Data("test".utf8)
        try sourceBytes.write(to: sourceURL)
        try FileManager.default.createDirectory(
            at: vaultURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        // Seed the immutable digest object, then drop the owning database to model a process that
        // died after a later writer created its staging leaf but before that leaf could be renamed.
        do {
            let interrupted = try WorkspaceDatabase(path: fixture.databaseURL.path)
            let firstDescriptor = try openDirectoryDescriptor(vaultURL)
            do {
                _ = try interrupted.configureReconstructionAttachmentVault(
                    rootURL: vaultURL,
                    pinnedRootDescriptor: firstDescriptor
                )
            } catch {
                _ = Darwin.close(firstDescriptor)
                throw error
            }
            _ = Darwin.close(firstDescriptor)
            let initialPublished = try interrupted.publishDurableReconstructionAttachmentSources(
                [ReconstructionAttachmentSource(
                    contentIdentity: foundation.occurrence.contentIdentity,
                    verifiedURL: sourceURL
                )],
                for: foundation.manifest
            )
            XCTAssertEqual(initialPublished.count, 1)
        }

        let shardName = String(foundation.occurrence.contentIdentity.digest.prefix(2))
        let shardURL = vaultURL.appendingPathComponent(shardName, isDirectory: true)
        let stageURL = shardURL.appendingPathComponent(
            ".stage-11111111-1111-1111-1111-111111111111",
            isDirectory: false
        )
        try Data("orphaned staging bytes".utf8).write(to: stageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageURL.path))

        let reopened = try WorkspaceDatabase(path: fixture.databaseURL.path)
        let reopenedDescriptor = try openDirectoryDescriptor(vaultURL)
        do {
            _ = try reopened.configureReconstructionAttachmentVault(
                rootURL: vaultURL,
                pinnedRootDescriptor: reopenedDescriptor
            )
        } catch {
            _ = Darwin.close(reopenedDescriptor)
            throw error
        }
        _ = Darwin.close(reopenedDescriptor)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stageURL.path),
            "exclusive sidecar reopening must scavenge the exact crash-stage leaf immediately"
        )
        let recoveredPublished = try reopened.publishDurableReconstructionAttachmentSources(
            [ReconstructionAttachmentSource(
                contentIdentity: foundation.occurrence.contentIdentity,
                verifiedURL: sourceURL
            )],
            for: foundation.manifest
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
        XCTAssertEqual(recoveredPublished.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveredPublished[0].verifiedURL), sourceBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: shardURL.appendingPathComponent(
                    foundation.occurrence.contentIdentity.digest,
                    isDirectory: false
                ).path
            )
        )
    }

    func testPreflightIsReadOnlyAndDistinguishesEveryBindingMismatch() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        let workspaceRowID = try fixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Bound Sidecar",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )
        let bytesBefore = try Data(contentsOf: fixture.databaseURL)

        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .matched(workspaceRowID: workspaceRowID)
        )
        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.otherWorkspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .workspaceMismatch
        )
        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.otherDocumentID,
                canonicalPackagePath: Self.packagePath
            ),
            .documentMismatch
        )
        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: "/private/tmp/Other.mscope"
            ),
            .canonicalPackagePathMismatch
        )

        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), bytesBefore)
        XCTAssertEqual(try fixture.database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"),
            1
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM workspace_documents;"
            ),
            1
        )
    }

    func testPreflightRecognizesOnlyCleanUninitializedAndEmptyCurrentDatabases() throws {
        let uninitialized = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: uninitialized.rootURL) }
        let uninitializedBytes = try Data(contentsOf: uninitialized.databaseURL)
        XCTAssertEqual(
            try uninitialized.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .uninitialized
        )
        XCTAssertEqual(try Data(contentsOf: uninitialized.databaseURL), uninitializedBytes)

        let emptyCurrent = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: emptyCurrent.rootURL) }
        try emptyCurrent.database.applySchema()
        let emptyCurrentBytes = try Data(contentsOf: emptyCurrent.databaseURL)
        XCTAssertEqual(
            try emptyCurrent.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .emptyCurrentSchema
        )
        XCTAssertEqual(try Data(contentsOf: emptyCurrent.databaseURL), emptyCurrentBytes)
    }

    func testPreflightAndBootstrapRejectGloballyNonemptyCurrentSchema() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        try fixture.database.executeRawForTesting(
            """
            INSERT INTO plugin_trust_decisions (
              plugin_identifier, decision, manifest_hash, updated_at
            ) VALUES ('unexpected.sidecar.row', 'denied', NULL, '2026-08-23T00:00:00.000Z');
            """
        )

        XCTAssertThrowsError(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("sidecar empty schema contains durable rows")
            )
        }
        XCTAssertThrowsError(
            try fixture.database.bootstrapReconstructionWorkspaceSidecar(
                workspaceUUID: Self.workspaceUUID,
                workspaceName: "Must Not Bootstrap",
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath,
                now: Self.now
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid(
                    "sidecar bootstrap requires globally empty current schema"
                )
            )
        }
        XCTAssertEqual(try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"), 0)
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM plugin_trust_decisions;"
            ),
            1
        )
    }

    func testPreflightAndBootstrapRejectForeignKeyOrphansAcrossGlobalWorkspaceScope() throws {
        let emptyFixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: emptyFixture.rootURL) }
        try emptyFixture.database.applySchema()
        try insertForeignReconstructionProject(
            into: emptyFixture.database,
            workspaceUUID: Self.otherWorkspaceUUID,
            projectID: "a1000000-0000-0000-0000-000000000081"
        )

        for operation in [
            {
                _ = try emptyFixture.database.preflightReconstructionSidecarBinding(
                    workspaceUUID: Self.workspaceUUID,
                    documentID: Self.documentID,
                    canonicalPackagePath: Self.packagePath
                )
            },
            {
                _ = try emptyFixture.database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: Self.workspaceUUID,
                    workspaceName: "Must Not Bootstrap",
                    documentID: Self.documentID,
                    canonicalPackagePath: Self.packagePath,
                    now: Self.now
                )
            },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error as? WorkspaceDatabase.DatabaseError,
                    .reconstructionStateInvalid("sidecar foreign key integrity")
                )
            }
        }

        let matchedFixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: matchedFixture.rootURL) }
        try matchedFixture.database.applySchema()
        _ = try matchedFixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Bound Sidecar",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )
        try insertForeignReconstructionProject(
            into: matchedFixture.database,
            workspaceUUID: Self.otherWorkspaceUUID,
            projectID: "a1000000-0000-0000-0000-000000000082"
        )

        XCTAssertThrowsError(
            try matchedFixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("sidecar foreign key integrity")
            )
        }
    }

    func testSQLiteMainFileIdentityRemainsPinnedAcrossReadOnlyPreflight() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        XCTAssertFalse(try fixture.database.reconstructionMainDatabaseFileHasMoved())

        XCTAssertEqual(
            try fixture.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .emptyCurrentSchema
        )
        XCTAssertFalse(try fixture.database.reconstructionMainDatabaseFileHasMoved())
    }

    func testSQLiteMainFileIdentityTreatsInMemoryDatabaseAsUnmovable() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        XCTAssertFalse(try database.reconstructionMainDatabaseFileHasMoved())
    }

    func testPreflightRejectsPartialOrStaleDatabaseWithoutMutation() throws {
        let partial = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: partial.rootURL) }
        try partial.database.applySchema()
        _ = try partial.database.insertWorkspace(WorkspaceDatabase.WorkspaceRecord(
            id: nil,
            uuid: Self.workspaceUUID,
            name: "Partial",
            createdAt: Self.now,
            modifiedAt: Self.now
        ))
        let partialBytes = try Data(contentsOf: partial.databaseURL)
        XCTAssertEqual(
            try partial.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            ),
            .documentMismatch
        )
        XCTAssertEqual(try Data(contentsOf: partial.databaseURL), partialBytes)

        let stale = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: stale.rootURL) }
        try stale.database.applySchema()
        try stale.database.setUserVersionForTesting(38)
        let staleBytes = try Data(contentsOf: stale.databaseURL)
        XCTAssertThrowsError(
            try stale.database.preflightReconstructionSidecarBinding(
                workspaceUUID: Self.workspaceUUID,
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .migrationRequired(stored: 38, supported: WorkspaceDatabase.schemaVersion)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stale.databaseURL), staleBytes)
        XCTAssertEqual(try stale.database.userVersion(), 38)
    }

    // MARK: - Checkpoint budget authority

    func testCheckpointRevisionMayExceedConsecutiveModelRoundBudget() throws {
        let databaseFixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: databaseFixture.rootURL) }
        try databaseFixture.database.applySchema()
        _ = try databaseFixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Checkpoint Budget",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: Self.workspaceBinaryID
        )
        let budget = try ReconstructionJobBudget(
            maxRounds: 1,
            maxTasks: foundation.job.budget.maxTasks,
            maxEvidenceRecords: foundation.job.budget.maxEvidenceRecords,
            maxEncodedBytes: foundation.job.budget.maxEncodedBytes
        )
        let boundedJob = try ReconstructionJobRecord(
            jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID,
            objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256,
            state: foundation.job.state,
            currentCheckpointID: foundation.job.currentCheckpointID,
            terminalReason: foundation.job.terminalReason,
            budget: budget,
            creationOrdinal: try XCTUnwrap(foundation.job.creationOrdinal),
            pauseContext: foundation.job.pauseContext
        )
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: Self.workspaceUUID,
            state: try ReconstructionWorkspaceState(
                projects: foundation.state.projects,
                corpusManifests: foundation.state.corpusManifests,
                evidence: foundation.state.evidence,
                evidenceRelations: foundation.state.evidenceRelations,
                evidenceGaps: foundation.state.evidenceGaps,
                jobs: [boundedJob],
                tasks: foundation.state.tasks,
                checkpoints: foundation.state.checkpoints,
                toolReceipts: foundation.state.toolReceipts,
                modelReceipts: foundation.state.modelReceipts,
                finalResults: foundation.state.finalResults
            )
        )
        let freshnessAuthority = try ReconstructionDatabaseTestFixtures
            .makeFreshnessAuthority(from: foundation)

        func successor(
            checkpointID: UUID,
            parent: ReconstructionCheckpoint
        ) throws -> ReconstructionCheckpoint {
            try ReconstructionCheckpoint.make(
                checkpointID: checkpointID,
                jobID: boundedJob.jobID,
                revision: parent.revision + 1,
                parentCheckpointID: parent.checkpointID,
                parentCheckpointSHA256: parent.canonicalSHA256,
                corpusManifestSHA256: parent.corpusManifestSHA256,
                evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                pendingTaskIDs: [],
                runningTaskIDs: [],
                completedTaskIDs: [foundation.task.identity.taskID],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: parent.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: [],
                toolReceiptIDs: [],
                coordinatorState: .retrieving,
                terminalReason: nil
            )
        }

        let firstCheckpoint = try successor(
            checkpointID: Self.budgetCheckpointOneID,
            parent: foundation.checkpoint
        )
        _ = try databaseFixture.database.commitReconstructionCheckpoint(
            workspaceID: Self.workspaceUUID,
            mutation: ReconstructionCheckpointMutation(
                jobID: boundedJob.jobID,
                expectedParentCheckpointID: foundation.checkpoint.checkpointID,
                expectedParentCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
                expectedParentRevision: foundation.checkpoint.revision,
                evidence: [],
                evidenceRelations: [],
                toolReceipts: [],
                modelReceipts: [],
                taskTransitions: [
                    ReconstructionTaskTransition(
                        taskID: foundation.task.identity.taskID,
                        expectedState: .pending,
                        successorState: .completed,
                        diagnostic: nil
                    ),
                ],
                freshnessAuthority: freshnessAuthority,
                successorCheckpoint: firstCheckpoint
            )
        )

        let secondCheckpoint = try successor(
            checkpointID: Self.budgetCheckpointTwoID,
            parent: firstCheckpoint
        )
        let committed = try databaseFixture.database.commitReconstructionCheckpoint(
            workspaceID: Self.workspaceUUID,
            mutation: ReconstructionCheckpointMutation(
                jobID: boundedJob.jobID,
                expectedParentCheckpointID: firstCheckpoint.checkpointID,
                expectedParentCheckpointSHA256: firstCheckpoint.canonicalSHA256,
                expectedParentRevision: firstCheckpoint.revision,
                evidence: [],
                evidenceRelations: [],
                toolReceipts: [],
                modelReceipts: [],
                taskTransitions: [],
                freshnessAuthority: freshnessAuthority,
                successorCheckpoint: secondCheckpoint
            )
        )

        XCTAssertGreaterThan(committed.checkpoint.revision, UInt64(budget.maxRounds))
        XCTAssertLessThanOrEqual(
            committed.state.tasks.filter { $0.identity.jobID == boundedJob.jobID }.count,
            budget.maxTasks
        )
        XCTAssertLessThanOrEqual(
            committed.state.evidence.filter { $0.creatingJobID == boundedJob.jobID }.count,
            budget.maxEvidenceRecords
        )
        XCTAssertLessThanOrEqual(
            committed.checkpoint.canonicalEncodedByteCount,
            budget.maxEncodedBytes
        )
    }

    func testReplaceRejectsModelReceiptIntroducedAfterTaskFirstCompletedCheckpoint() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        _ = try fixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Late Receipt Admission",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )

        XCTAssertThrowsError(
            try fixture.database.replaceReconstructionState(
                workspaceID: Self.workspaceUUID,
                state: try makeLateModelReceiptIntroductionState()
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid(
                    "package-v3 graph: model receipt task completion revision"
                )
            )
        }
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: Self.workspaceUUID),
            .empty
        )
    }

    // MARK: - Durable final-result schema and commit atomicity

    func testProductionRuntimeValidatesVersion38IdentityBeforeMigrationThenRepreflightsVersion40()
        async throws
    {
        let base = try makeRuntimeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let packagePath = base.appendingPathComponent("Version38.mscope").path
        let binding = ReconstructionWorkspaceStateBinding(
            workspaceID: Self.workspaceUUID,
            documentID: Self.documentID,
            canonicalPackagePath: packagePath
        )
        var expectedWorkspaceRowID: Int64?
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .DatabaseOpenInterpositionForTesting { operation in
                let database = try operation()
                try database.applySchema()
                expectedWorkspaceRowID = try database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: binding.workspaceID,
                    workspaceName: "Version 38 Sidecar",
                    documentID: binding.documentID,
                    canonicalPackagePath: binding.canonicalPackagePath,
                    now: Self.now
                )
                try database.executeRawForTesting(
                    """
                    PRAGMA foreign_keys = OFF;
                    BEGIN IMMEDIATE;
                    DROP INDEX idx_type_definitions_workspace_name;
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
                    DROP TABLE reconstruction_final_results;
                    PRAGMA user_version = 38;
                    COMMIT;
                    PRAGMA foreign_keys = ON;
                    """
                )
                return database
            }

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base,
            databaseOpenInterpositionForTesting: interposition
        )
        XCTAssertEqual(runtime.reconciliationDisposition, .equal)
        let workspaceRowID = try XCTUnwrap(expectedWorkspaceRowID)
        let migrated = try WorkspaceDatabase(path: runtime.databaseURL.path)
        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(
            try migrated.columnNames(in: "type_definitions").contains("layout_rules_json")
        )
        XCTAssertTrue(try migrated.tableNames().contains("reconstruction_final_results"))
        XCTAssertEqual(
            try migrated.preflightReconstructionSidecarBinding(
                workspaceUUID: binding.workspaceID,
                documentID: binding.documentID,
                canonicalPackagePath: binding.canonicalPackagePath
            ),
            .matched(workspaceRowID: workspaceRowID)
        )
        await runtime.close()
    }

    func testProductionRuntimeValidatesVersion39IdentityBeforeMigrationThenRepreflightsVersion40()
        async throws
    {
        let base = try makeRuntimeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let packagePath = base.appendingPathComponent("Version39.mscope").path
        let binding = ReconstructionWorkspaceStateBinding(
            workspaceID: Self.workspaceUUID,
            documentID: Self.documentID,
            canonicalPackagePath: packagePath
        )
        var preparedVersion39 = false
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .DatabaseOpenInterpositionForTesting { operation in
                let database = try operation()
                try database.applySchema()
                _ = try database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: binding.workspaceID,
                    workspaceName: "Version 39 Sidecar",
                    documentID: binding.documentID,
                    canonicalPackagePath: binding.canonicalPackagePath,
                    now: Self.now
                )
                try database.executeRawForTesting(
                    "DROP TABLE reconstruction_final_results; PRAGMA user_version = 39;"
                )
                preparedVersion39 = true
                return database
            }

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base,
            databaseOpenInterpositionForTesting: interposition
        )
        XCTAssertTrue(preparedVersion39)
        XCTAssertEqual(runtime.reconciliationDisposition, .equal)
        let migrated = try WorkspaceDatabase(path: runtime.databaseURL.path)
        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try migrated.tableNames().contains("reconstruction_final_results"))
        XCTAssertEqual(
            try migrated.preflightReconstructionSidecarBinding(
                workspaceUUID: binding.workspaceID,
                documentID: binding.documentID,
                canonicalPackagePath: binding.canonicalPackagePath
            ),
            .matched(workspaceRowID: 1)
        )
        await runtime.close()
    }

    func testProductionRuntimeAcceptsVersion39IdentityWithCosmeticallyDifferentDDL()
        async throws
    {
        let base = try makeRuntimeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let packagePath = base.appendingPathComponent("Version39-QuotedDDL.mscope").path
        let binding = ReconstructionWorkspaceStateBinding(
            workspaceID: Self.workspaceUUID,
            documentID: Self.documentID,
            canonicalPackagePath: packagePath
        )
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .DatabaseOpenInterpositionForTesting { operation in
                let database = try operation()
                try database.applySchema()
                _ = try database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: binding.workspaceID,
                    workspaceName: "Version 39 Quoted DDL Sidecar",
                    documentID: binding.documentID,
                    canonicalPackagePath: binding.canonicalPackagePath,
                    now: Self.now
                )
                try database.executeRawForTesting(
                    """
                    PRAGMA foreign_keys = OFF;
                    BEGIN IMMEDIATE;
                    DROP INDEX idx_workspace_documents_last_opened_at;
                    DROP INDEX idx_workspace_documents_conflict_detected_at;
                    DROP INDEX idx_workspace_documents_recent_document_state;
                    ALTER TABLE workspace_documents RENAME TO workspace_documents_v40;
                    CREATE TABLE "workspace_documents" (
                      "workspace_id" INTEGER PRIMARY KEY REFERENCES "workspaces"("id")
                        ON DELETE CASCADE,
                      "document_id" TEXT NOT NULL,
                      "package_path" TEXT NOT NULL,
                      "last_opened_at" TEXT NOT NULL,
                      "last_saved_at" TEXT,
                      "is_dirty" INTEGER NOT NULL DEFAULT 0,
                      "file_version_identifier" TEXT,
                      "conflict_detected_at" TEXT,
                      "conflict_reason" TEXT,
                      "input_copying_decision" TEXT NOT NULL DEFAULT 'copy_inputs_into_package',
                      "bookmark_resolution_decision" TEXT NOT NULL
                        DEFAULT 'resolve_stored_bookmarks',
                      "bookmark_resolution_error" TEXT,
                      "recent_document_state" TEXT NOT NULL DEFAULT 'available',
                      "recent_document_state_updated_at" TEXT
                    );
                    INSERT INTO workspace_documents (
                      workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                      is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                      input_copying_decision, bookmark_resolution_decision,
                      bookmark_resolution_error, recent_document_state,
                      recent_document_state_updated_at
                    )
                    SELECT workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                           is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                           input_copying_decision, bookmark_resolution_decision,
                           bookmark_resolution_error, recent_document_state,
                           recent_document_state_updated_at
                    FROM workspace_documents_v40;
                    DROP TABLE workspace_documents_v40;
                    CREATE INDEX idx_workspace_documents_last_opened_at
                      ON "workspace_documents"("last_opened_at" DESC);
                    CREATE INDEX idx_workspace_documents_conflict_detected_at
                      ON "workspace_documents"("conflict_detected_at" DESC);
                    CREATE INDEX idx_workspace_documents_recent_document_state
                      ON "workspace_documents"("recent_document_state");
                    DROP TABLE reconstruction_final_results;
                    PRAGMA user_version = 39;
                    COMMIT;
                    PRAGMA foreign_keys = ON;
                    """
                )
                return database
            }

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base,
            databaseOpenInterpositionForTesting: interposition
        )
        XCTAssertEqual(runtime.reconciliationDisposition, .equal)
        let migrated = try WorkspaceDatabase(path: runtime.databaseURL.path)
        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try migrated.preflightReconstructionSidecarBinding(
                workspaceUUID: binding.workspaceID,
                documentID: binding.documentID,
                canonicalPackagePath: binding.canonicalPackagePath
            ),
            .matched(workspaceRowID: 1)
        )
        await runtime.close()

        // Mutation RED: compare ReconstructionSchemaTable with synthesized Equatable instead of
        // hasEquivalentStructuralAuthority. The quoted sqlite_master CREATE text rejects v39.
    }

    func testProductionRuntimeRefusesVersion39IdentityMismatchWithoutMigrating() throws {
        let base = try makeRuntimeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let packagePath = base.appendingPathComponent("Version39-Mismatch.mscope").path
        let binding = ReconstructionWorkspaceStateBinding(
            workspaceID: Self.workspaceUUID,
            documentID: Self.documentID,
            canonicalPackagePath: packagePath
        )
        var preparedDatabase: WorkspaceDatabase?
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .DatabaseOpenInterpositionForTesting { operation in
                let database = try operation()
                try database.applySchema()
                _ = try database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: binding.workspaceID,
                    workspaceName: "Wrong Version 39 Sidecar",
                    documentID: Self.otherDocumentID,
                    canonicalPackagePath: binding.canonicalPackagePath,
                    now: Self.now
                )
                try database.executeRawForTesting(
                    "DROP TABLE reconstruction_final_results; PRAGMA user_version = 39;"
                )
                preparedDatabase = database
                return database
            }

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base,
                databaseOpenInterpositionForTesting: interposition
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .documentIdentityMismatch
            )
        }
        let database = try XCTUnwrap(preparedDatabase)
        XCTAssertEqual(try database.userVersion(), 39)
        XCTAssertFalse(try database.tableNames().contains("reconstruction_final_results"))
    }

    func testProductionRuntimeRefusesVersion39WeakenedIdentityDDLWithoutStampingCurrent()
        throws
    {
        let base = try makeRuntimeBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let packagePath = base.appendingPathComponent("Version39-WeakIdentity.mscope").path
        let binding = ReconstructionWorkspaceStateBinding(
            workspaceID: Self.workspaceUUID,
            documentID: Self.documentID,
            canonicalPackagePath: packagePath
        )
        var preparedDatabase: WorkspaceDatabase?
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .DatabaseOpenInterpositionForTesting { operation in
                let database = try operation()
                try database.applySchema()
                _ = try database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: binding.workspaceID,
                    workspaceName: "Weakened Version 39 Sidecar",
                    documentID: binding.documentID,
                    canonicalPackagePath: binding.canonicalPackagePath,
                    now: Self.now
                )
                try database.executeRawForTesting(
                    """
                    PRAGMA foreign_keys = OFF;
                    BEGIN IMMEDIATE;
                    DROP INDEX idx_workspace_documents_last_opened_at;
                    DROP INDEX idx_workspace_documents_conflict_detected_at;
                    DROP INDEX idx_workspace_documents_recent_document_state;
                    ALTER TABLE workspace_documents RENAME TO workspace_documents_v40;
                    CREATE TABLE workspace_documents (
                      workspace_id INTEGER NOT NULL,
                      document_id TEXT NOT NULL,
                      package_path TEXT NOT NULL,
                      last_opened_at TEXT NOT NULL,
                      last_saved_at TEXT,
                      is_dirty INTEGER NOT NULL DEFAULT 0,
                      file_version_identifier TEXT,
                      conflict_detected_at TEXT,
                      conflict_reason TEXT,
                      input_copying_decision TEXT NOT NULL DEFAULT 'copy_inputs_into_package',
                      bookmark_resolution_decision TEXT NOT NULL DEFAULT 'resolve_stored_bookmarks',
                      bookmark_resolution_error TEXT,
                      recent_document_state TEXT NOT NULL DEFAULT 'available',
                      recent_document_state_updated_at TEXT
                    );
                    INSERT INTO workspace_documents (
                      workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                      is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                      input_copying_decision, bookmark_resolution_decision,
                      bookmark_resolution_error, recent_document_state,
                      recent_document_state_updated_at
                    )
                    SELECT workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                           is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                           input_copying_decision, bookmark_resolution_decision,
                           bookmark_resolution_error, recent_document_state,
                           recent_document_state_updated_at
                    FROM workspace_documents_v40;
                    DROP TABLE workspace_documents_v40;
                    CREATE INDEX idx_workspace_documents_last_opened_at
                      ON workspace_documents(last_opened_at DESC);
                    CREATE INDEX idx_workspace_documents_conflict_detected_at
                      ON workspace_documents(conflict_detected_at DESC);
                    CREATE INDEX idx_workspace_documents_recent_document_state
                      ON workspace_documents(recent_document_state);
                    DROP TABLE reconstruction_final_results;
                    PRAGMA user_version = 39;
                    COMMIT;
                    PRAGMA foreign_keys = ON;
                    """
                )
                preparedDatabase = database
                return database
            }

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base,
                databaseOpenInterpositionForTesting: interposition
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionSchemaInvalid(
                    "sidecar identity structural contract differs for table=workspace_documents"
                )
            )
        }
        let database = try XCTUnwrap(preparedDatabase)
        XCTAssertEqual(try database.userVersion(), 39)
        XCTAssertFalse(try database.tableNames().contains("reconstruction_final_results"))

        // Mandatory mutation RED: remove the preflight identity-schema validation. The runtime
        // accepts the weakened table, applies the v39-to-current migration, and both assertions
        // above fail because the database is stamped current and gains reconstruction_final_results.
    }

    func testVersion39MigrationAddsOnlyTheEmptyFinalResultTable() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        _ = try fixture.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Preserved v39 Workspace",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )
        try fixture.database.executeRawForTesting(
            "DROP TABLE reconstruction_final_results; PRAGMA user_version = 39;"
        )

        try fixture.database.applySchema()

        XCTAssertEqual(try fixture.database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(
            try fixture.database.tableNames().contains("reconstruction_final_results")
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_final_results;"
            ),
            0
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting("SELECT COUNT(*) FROM workspaces;"),
            1
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM workspace_documents;"
            ),
            1
        )
    }

    func testMalformedVersion39FinalResultTableRollsBackWithoutStampingOrRepairing() throws {
        let fixture = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try fixture.database.applySchema()
        try fixture.database.executeRawForTesting(
            """
            DROP TABLE reconstruction_final_results;
            CREATE TABLE reconstruction_final_results (
              workspace_uuid TEXT NOT NULL,
              malformed_payload TEXT NOT NULL
            );
            INSERT INTO reconstruction_final_results (workspace_uuid, malformed_payload)
              VALUES ('\(Self.workspaceUUID.uuidString)', 'preserve-me');
            PRAGMA user_version = 39;
            """
        )
        let schemaBefore = try fixture.database.scalarTextForTesting(
            """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = 'reconstruction_final_results';
            """
        )

        XCTAssertThrowsError(try fixture.database.applySchema()) { error in
            guard case WorkspaceDatabase.DatabaseError.reconstructionSchemaInvalid = error else {
                return XCTFail("Expected reconstructionSchemaInvalid, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.database.userVersion(), 39)
        XCTAssertEqual(
            try fixture.database.scalarTextForTesting(
                """
                SELECT sql FROM sqlite_master
                WHERE type = 'table' AND name = 'reconstruction_final_results';
                """
            ),
            schemaBefore
        )
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM reconstruction_final_results
                WHERE malformed_payload = 'preserve-me';
                """
            ),
            1
        )
    }

    func testFinalResultCheckpointCommitPersistsExactCanonicalRowAndReloads() throws {
        let fixture = try makeFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }

        let committed = try fixture.databaseFixture.database.commitReconstructionCheckpoint(
            workspaceID: Self.workspaceUUID,
            mutation: fixture.mutation
        )

        XCTAssertEqual(committed.state.finalResults, [fixture.result])
        XCTAssertEqual(
            try fixture.databaseFixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_final_results;"
            ),
            1
        )
        XCTAssertEqual(
            try fixture.databaseFixture.database.scalarTextForTesting(
                "SELECT canonical_sha256 FROM reconstruction_final_results;"
            ),
            fixture.result.canonicalSHA256
        )
        XCTAssertEqual(
            try fixture.databaseFixture.database.loadReconstructionState(
                workspaceID: Self.workspaceUUID
            ),
            committed.state
        )
    }

    func testFinalResultReplaceAndLoadPreserveEveryCanonicalField() throws {
        let source = try makeFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: source.databaseFixture.rootURL) }
        let committed = try source.databaseFixture.database.commitReconstructionCheckpoint(
            workspaceID: Self.workspaceUUID,
            mutation: source.mutation
        )

        let destination = try makeDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: destination.rootURL) }
        try destination.database.applySchema()
        _ = try destination.database.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: Self.workspaceUUID,
            workspaceName: "Final Result Replacement",
            documentID: Self.documentID,
            canonicalPackagePath: Self.packagePath,
            now: Self.now
        )
        try destination.database.replaceReconstructionState(
            workspaceID: Self.workspaceUUID,
            state: committed.state
        )

        XCTAssertEqual(
            try destination.database.loadReconstructionState(workspaceID: Self.workspaceUUID),
            committed.state
        )
        XCTAssertEqual(
            try destination.database.reconstructionProjectionSnapshotForTesting(
                workspaceID: Self.workspaceUUID
            ),
            try source.databaseFixture.database.reconstructionProjectionSnapshotForTesting(
                workspaceID: Self.workspaceUUID
            )
        )
    }

    func testFinalResultTableEnforcesUniqueForeignKeyAndCanonicalShapeConstraints() throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        let database = fixture.databaseFixture.database
        let schema = try XCTUnwrap(database.scalarTextForTesting(
            """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = 'reconstruction_final_results';
            """
        ))
        for requiredFragment in [
            "UNIQUE (workspace_uuid, job_id)",
            "UNIQUE (workspace_uuid, model_receipt_id)",
            "CHECK(request_id = model_receipt_id)",
            "FOREIGN KEY (workspace_uuid, job_id)",
            "FOREIGN KEY (workspace_uuid, task_id)",
            "FOREIGN KEY (workspace_uuid, checkpoint_id)",
            "FOREIGN KEY (workspace_uuid, model_receipt_id)",
            "payload_byte_count > 0 AND payload_byte_count <= 1048576",
            "request_identity_sha256 = lower(request_identity_sha256)",
            "payload_sha256 = lower(payload_sha256)",
            "producer_canonical_sha256 = lower(producer_canonical_sha256)",
            "canonical_sha256 = lower(canonical_sha256)",
        ] {
            XCTAssertTrue(schema.contains(requiredFragment), requiredFragment)
        }

        assertSQLiteStepRejected {
            try database.executeRawForTesting(
                """
                INSERT INTO reconstruction_final_results (
                  workspace_uuid, result_id, job_id, task_id, checkpoint_id,
                  checkpoint_revision, request_id, request_identity_sha256, kind,
                  payload_byte_count, payload_sha256, producer_canonical_sha256,
                  model_receipt_id, canonical_sha256, record_json
                )
                SELECT workspace_uuid, '\(Self.duplicateFinalResultID.uuidString)', job_id,
                       task_id, checkpoint_id, checkpoint_revision, request_id,
                       request_identity_sha256, kind, payload_byte_count, payload_sha256,
                       producer_canonical_sha256, model_receipt_id, canonical_sha256, record_json
                FROM reconstruction_final_results;
                """
            )
        }
        assertSQLiteStepRejected {
            try database.executeRawForTesting(
                """
                UPDATE reconstruction_final_results
                SET checkpoint_id = '\(Self.unknownCheckpointID.uuidString)';
                """
            )
        }
        assertSQLiteStepRejected {
            try database.executeRawForTesting(
                """
                UPDATE reconstruction_final_results
                SET payload_sha256 = '\(String(repeating: "A", count: 64))';
                """
            )
        }
    }

    func testInjectedFailureAfterFinalResultInsertRollsBackWholeCheckpointMutation() throws {
        let fixture = try makeFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        let database = fixture.databaseFixture.database
        let projectionBefore = try database.reconstructionProjectionSnapshotForTesting(
            workspaceID: Self.workspaceUUID
        )
        database.setReconstructionFinalResultMutationFailureForTesting(
            after: .insertedFinalResults
        )
        defer {
            database.setReconstructionFinalResultMutationFailureForTesting(after: nil)
        }

        XCTAssertThrowsError(
            try database.commitReconstructionCheckpoint(
                workspaceID: Self.workspaceUUID,
                mutation: fixture.mutation
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionInjectedFailure("final-result-insertedFinalResults")
            )
        }

        XCTAssertEqual(
            try database.loadReconstructionState(workspaceID: Self.workspaceUUID),
            fixture.persistedFoundation
        )
        XCTAssertEqual(
            try database.reconstructionProjectionSnapshotForTesting(
                workspaceID: Self.workspaceUUID
            ),
            projectionBefore
        )
        XCTAssertEqual(
            try database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_final_results;"
            ),
            0
        )
    }

    func testMissingFinalResultProjectionRowIsRejectedOnReload() throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        try fixture.databaseFixture.database.executeRawForTesting(
            "DELETE FROM reconstruction_final_results;"
        )

        assertFinalResultProjectionRejected(fixture.databaseFixture.database)
    }

    func testFinalResultPayloadHashProjectionDriftIsRejectedOnReload() throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        let driftedHash = ReconstructionDatabaseTestFixtures.digest("a")
        XCTAssertNotEqual(driftedHash, fixture.result.payloadSHA256)
        try fixture.databaseFixture.database.executeRawForTesting(
            """
            UPDATE reconstruction_final_results
            SET payload_sha256 = '\(driftedHash)';
            """
        )

        assertFinalResultProjectionRejected(fixture.databaseFixture.database)
    }

    func testFinalResultCitedEvidenceDriftIsRejectedOnReload() throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        let driftedEvidenceID = Self.driftedEvidenceID.uuidString
        try fixture.databaseFixture.database.executeRawForTesting(
            """
            UPDATE reconstruction_final_results
            SET record_json = CAST(REPLACE(
              CAST(record_json AS TEXT),
              '"citedEvidenceIDs":[]',
              '"citedEvidenceIDs":["\(driftedEvidenceID)"]'
            ) AS BLOB);
            """
        )
        XCTAssertEqual(
            try fixture.databaseFixture.database.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM reconstruction_final_results
                WHERE INSTR(CAST(record_json AS TEXT), '\(driftedEvidenceID)') > 0;
                """
            ),
            1
        )

        assertFinalResultProjectionRejected(fixture.databaseFixture.database)
    }

    func testFinalResultCheckpointAnchorDriftIsRejectedOnReload() throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        try fixture.databaseFixture.database.executeRawForTesting(
            """
            UPDATE reconstruction_final_results
            SET checkpoint_id = '\(fixture.foundation.checkpoint.checkpointID.uuidString)';
            """
        )

        assertFinalResultProjectionRejected(fixture.databaseFixture.database)
    }

    func testFinalResultReceiptAnchorDriftIsRejectedOnReload() throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        let original = fixture.result.modelReceiptID.uuidString
        let drifted = Self.driftedReceiptID.uuidString
        try fixture.databaseFixture.database.executeRawForTesting(
            """
            UPDATE reconstruction_final_results
            SET record_json = CAST(REPLACE(
              CAST(record_json AS TEXT),
              '"modelReceiptID":"\(original)"',
              '"modelReceiptID":"\(drifted)"'
            ) AS BLOB);
            """
        )
        XCTAssertEqual(
            try fixture.databaseFixture.database.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM reconstruction_final_results
                WHERE INSTR(CAST(record_json AS TEXT), '\(drifted)') > 0;
                """
            ),
            1
        )

        assertFinalResultProjectionRejected(fixture.databaseFixture.database)
    }

    func testForgedFinalResultCanonicalIdentityIsRejectedAtAdmissionAndAuthoritativeLoad()
        throws {
        let fixture = try makeCommittedFinalResultFixture()
        defer { try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL) }
        let database = fixture.databaseFixture.database
        let validState = try database.loadReconstructionState(workspaceID: Self.workspaceUUID)
        let result = fixture.result
        let forgedDigest = ReconstructionDatabaseTestFixtures.digest("a")
        XCTAssertNotEqual(forgedDigest, result.canonicalSHA256)
        let forgedResult = try ReconstructionFinalResultRecord(
            resultID: result.resultID,
            schemaVersion: result.schemaVersion,
            jobID: result.jobID,
            taskID: result.taskID,
            checkpointID: result.checkpointID,
            checkpointRevision: result.checkpointRevision,
            requestID: result.requestID,
            requestIdentitySHA256: result.requestIdentitySHA256,
            kind: result.kind,
            payloadUTF8: result.payloadUTF8,
            payloadByteCount: result.payloadByteCount,
            payloadSHA256: result.payloadSHA256,
            citedEvidenceIDs: result.citedEvidenceIDs,
            producer: result.producer,
            modelReceiptID: result.modelReceiptID,
            canonicalSHA256: forgedDigest
        )
        let forgedState = try ReconstructionWorkspaceState(
            schemaVersion: validState.schemaVersion,
            projects: validState.projects,
            corpusManifests: validState.corpusManifests,
            evidence: validState.evidence,
            evidenceRelations: validState.evidenceRelations,
            evidenceGaps: validState.evidenceGaps,
            jobs: validState.jobs,
            tasks: validState.tasks,
            checkpoints: validState.checkpoints,
            toolReceipts: validState.toolReceipts,
            modelReceipts: validState.modelReceipts,
            finalResults: [forgedResult]
        )

        XCTAssertThrowsError(
            try database.replaceReconstructionState(
                workspaceID: Self.workspaceUUID,
                state: forgedState
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("package-v3 graph: final result")
            )
        }
        XCTAssertEqual(
            try database.loadReconstructionState(workspaceID: Self.workspaceUUID),
            validState
        )

        try database.executeRawForTesting(
            "UPDATE reconstruction_projects SET state_json = "
                + blobLiteral(try ReconstructionCanonicalJSON.encode(forgedState))
                + ";"
        )
        XCTAssertThrowsError(
            try database.loadReconstructionState(workspaceID: Self.workspaceUUID)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("package-v3 graph: final result")
            )
        }
    }

    private struct DatabaseFixture {
        let rootURL: URL
        let databaseURL: URL
        let database: WorkspaceDatabase
    }

    private struct FinalResultFixture {
        let databaseFixture: DatabaseFixture
        let foundation: ReconstructionDatabaseTestFixtures.StateFixture
        let persistedFoundation: ReconstructionWorkspaceState
        let mutation: ReconstructionCheckpointMutation
        let result: ReconstructionFinalResultRecord
    }

    private func makeDatabaseFixture() throws -> DatabaseFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionWorkspaceAtomicity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = root.appendingPathComponent("Reconstruction.sqlite3")
        return DatabaseFixture(
            rootURL: root,
            databaseURL: databaseURL,
            database: try WorkspaceDatabase(path: databaseURL.path)
        )
    }

    private func openDirectoryDescriptor(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        return descriptor
    }

    private func makeRuntimeBaseDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionWorkspaceRuntimeAtomicity-\(UUID().uuidString)",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func insertForeignReconstructionProject(
        into database: WorkspaceDatabase,
        workspaceUUID: UUID,
        projectID: String
    ) throws {
        try database.executeRawForTesting(
            """
            PRAGMA foreign_keys = OFF;
            INSERT INTO reconstruction_projects (
              workspace_uuid, project_id, current_manifest_sha256, record_json, state_json
            ) VALUES (
              '\(workspaceUUID.uuidString)', '\(projectID)', NULL, X'7b7d', X'7b7d'
            );
            PRAGMA foreign_keys = ON;
            """
        )
    }

    private func makeLateModelReceiptIntroductionState() throws
        -> ReconstructionWorkspaceState {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: Self.workspaceBinaryID
        )
        let retrieve = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: Self.lateRetrieveTaskID,
                jobID: foundation.job.jobID,
                kind: .retrieveEvidence,
                subject: nil,
                dependencyTaskIDs: [],
                operationContractIdentity: ReconstructionOperationID.evidenceQuery.rawValue
            ),
            state: .completed,
            diagnostic: nil
        )
        let model = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: Self.lateModelTaskID,
                jobID: foundation.job.jobID,
                kind: .modelRound,
                subject: nil,
                dependencyTaskIDs: [retrieve.identity.taskID],
                operationContractIdentity: "reconstruction.modelRound.v1"
            ),
            state: .completed,
            diagnostic: nil
        )
        let checkpointTask = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: Self.lateCheckpointTaskID,
                jobID: foundation.job.jobID,
                kind: .checkpoint,
                subject: nil,
                dependencyTaskIDs: [model.identity.taskID],
                operationContractIdentity: "reconstruction.checkpoint.v1"
            ),
            state: .completed,
            diagnostic: nil
        )
        let taskIDs = [
            retrieve.identity.taskID,
            model.identity.taskID,
            checkpointTask.identity.taskID,
        ]
        let root = try ReconstructionCheckpoint.make(
            checkpointID: Self.lateRootCheckpointID,
            jobID: foundation.job.jobID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: taskIDs,
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: foundation.checkpoint
                .unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: Self.lateModelReceiptID,
            jobID: foundation.job.jobID,
            taskID: model.identity.taskID,
            checkpointRevision: 1,
            requestIdentitySHA256: ReconstructionDatabaseTestFixtures.digest("7"),
            producer: try ReconstructionDatabaseTestFixtures.makeProducer(
                operationID: model.identity.operationContractIdentity
            ),
            terminalState: .completed,
            selectedHandleIDs: [],
            acceptedEvidenceIDs: [],
            diagnostic: nil,
            finalResultCommitment: nil
        )
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: Self.lateSuccessorCheckpointID,
            jobID: foundation.job.jobID,
            revision: 1,
            parentCheckpointID: root.checkpointID,
            parentCheckpointSHA256: root.canonicalSHA256,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: taskIDs,
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: foundation.checkpoint
                .unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [receipt.receiptID],
            toolReceiptIDs: [],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID,
            objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256,
            state: .retrieving,
            currentCheckpointID: successor.checkpointID,
            terminalReason: nil,
            budget: foundation.job.budget,
            creationOrdinal: try XCTUnwrap(foundation.job.creationOrdinal)
        )
        return try ReconstructionWorkspaceState(
            projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests,
            evidence: foundation.state.evidence,
            evidenceRelations: foundation.state.evidenceRelations,
            evidenceGaps: foundation.state.evidenceGaps,
            jobs: [job],
            tasks: [retrieve, model, checkpointTask],
            checkpoints: [root, successor],
            toolReceipts: [],
            modelReceipts: [receipt],
            finalResults: []
        )
    }

    private func makeFinalResultFixture() throws -> FinalResultFixture {
        let databaseFixture = try makeDatabaseFixture()
        do {
            try databaseFixture.database.applySchema()
            _ = try databaseFixture.database.bootstrapReconstructionWorkspaceSidecar(
                workspaceUUID: Self.workspaceUUID,
                workspaceName: "Final Result Sidecar",
                documentID: Self.documentID,
                canonicalPackagePath: Self.packagePath,
                now: Self.now
            )
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: Self.workspaceBinaryID
            )
            try databaseFixture.database.replaceReconstructionState(
                workspaceID: Self.workspaceUUID,
                state: foundation.state
            )
            let persistedFoundation = try databaseFixture.database.loadReconstructionState(
                workspaceID: Self.workspaceUUID
            )

            let finalTaskIdentity = try ReconstructionTaskIdentity.make(
                taskID: Self.finalTaskID,
                jobID: foundation.job.jobID,
                kind: .modelRound,
                subject: nil,
                dependencyTaskIDs: [foundation.task.identity.taskID],
                operationContractIdentity: "reconstruction.finalSynthesis.v1"
            )
            let finalTask = ReconstructionTaskRecord(
                identity: finalTaskIdentity,
                state: .pending,
                diagnostic: nil
            )
            let producer = try ReconstructionDatabaseTestFixtures.makeProducer(
                operationID: finalTask.identity.operationContractIdentity
            )
            let requestIdentitySHA256 = ReconstructionDatabaseTestFixtures.digest("f")
            let result = try ReconstructionReceiptAuthority.makeFinalResult(
                resultID: Self.finalResultID,
                jobID: foundation.job.jobID,
                taskID: Self.finalTaskID,
                checkpointID: Self.finalCheckpointID,
                checkpointRevision: foundation.checkpoint.revision + 1,
                requestID: Self.finalRequestID,
                requestIdentitySHA256: requestIdentitySHA256,
                kind: .synthesis,
                payloadUTF8: Data("final synthesis".utf8),
                citedEvidenceIDs: [],
                producer: producer,
                modelReceiptID: Self.finalRequestID
            )
            let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
                receiptID: Self.finalRequestID,
                jobID: foundation.job.jobID,
                taskID: Self.finalTaskID,
                checkpointRevision: foundation.checkpoint.revision + 1,
                requestIdentitySHA256: requestIdentitySHA256,
                producer: producer,
                terminalState: .completed,
                selectedHandleIDs: [],
                acceptedEvidenceIDs: result.citedEvidenceIDs,
                diagnostic: nil,
                finalResultCommitment: try ReconstructionFinalResultCommitment(
                    resultID: result.resultID,
                    canonicalSHA256: result.canonicalSHA256
                )
            )
            let successor = try ReconstructionCheckpoint.make(
                checkpointID: Self.finalCheckpointID,
                jobID: foundation.job.jobID,
                revision: foundation.checkpoint.revision + 1,
                parentCheckpointID: foundation.checkpoint.checkpointID,
                parentCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
                corpusManifestSHA256: foundation.checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
                pendingTaskIDs: [],
                runningTaskIDs: [],
                completedTaskIDs: [foundation.task.identity.taskID, Self.finalTaskID],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: foundation.checkpoint
                    .unresolvedEvidenceGapSHA256,
                modelReceiptIDs: [receipt.receiptID],
                toolReceiptIDs: [],
                coordinatorState: .completed,
                terminalReason: nil
            )
            let mutation = ReconstructionCheckpointMutation(
                jobID: foundation.job.jobID,
                expectedParentCheckpointID: foundation.checkpoint.checkpointID,
                expectedParentCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
                expectedParentRevision: foundation.checkpoint.revision,
                evidence: [],
                evidenceRelations: [],
                toolReceipts: [],
                modelReceipts: [receipt],
                finalResults: [result],
                newTasks: [finalTask],
                taskTransitions: [
                    ReconstructionTaskTransition(
                        taskID: foundation.task.identity.taskID,
                        expectedState: .pending,
                        successorState: .completed,
                        diagnostic: nil
                    ),
                    ReconstructionTaskTransition(
                        taskID: finalTask.identity.taskID,
                        expectedState: .pending,
                        successorState: .completed,
                        diagnostic: nil
                    ),
                ],
                freshnessAuthority: try ReconstructionDatabaseTestFixtures
                    .makeFreshnessAuthority(from: foundation),
                successorCheckpoint: successor
            )
            return FinalResultFixture(
                databaseFixture: databaseFixture,
                foundation: foundation,
                persistedFoundation: persistedFoundation,
                mutation: mutation,
                result: result
            )
        } catch {
            try? FileManager.default.removeItem(at: databaseFixture.rootURL)
            throw error
        }
    }

    private func makeCommittedFinalResultFixture() throws -> FinalResultFixture {
        let fixture = try makeFinalResultFixture()
        do {
            _ = try fixture.databaseFixture.database.commitReconstructionCheckpoint(
                workspaceID: Self.workspaceUUID,
                mutation: fixture.mutation
            )
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: fixture.databaseFixture.rootURL)
            throw error
        }
    }

    private func assertFinalResultProjectionRejected(
        _ database: WorkspaceDatabase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try database.loadReconstructionState(workspaceID: Self.workspaceUUID),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionIdentityConflict(
                    "reconstruction_final_results projected rows"
                ),
                file: file,
                line: line
            )
        }
    }

    private func assertSQLiteStepRejected(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case WorkspaceDatabase.DatabaseError.stepFailed(_) = error else {
                return XCTFail("Expected SQLite step failure, got \(error)", file: file, line: line)
            }
        }
    }

    private func blobLiteral(_ data: Data) -> String {
        "X'\(data.map { String(format: "%02x", $0) }.joined())'"
    }

    private static let workspaceUUID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000001"
    )!
    private static let otherWorkspaceUUID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000002"
    )!
    private static let documentID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000003"
    )!
    private static let otherDocumentID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000004"
    )!
    private static let workspaceBinaryID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000005"
    )!
    private static let finalTaskID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000006"
    )!
    private static let finalCheckpointID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000007"
    )!
    private static let finalRequestID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000008"
    )!
    private static let finalResultID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000009"
    )!
    private static let driftedEvidenceID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000010"
    )!
    private static let driftedReceiptID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000011"
    )!
    private static let duplicateFinalResultID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000012"
    )!
    private static let unknownCheckpointID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000013"
    )!
    private static let budgetCheckpointOneID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000014"
    )!
    private static let budgetCheckpointTwoID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000015"
    )!
    private static let lateRetrieveTaskID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000016"
    )!
    private static let lateModelTaskID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000017"
    )!
    private static let lateCheckpointTaskID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000018"
    )!
    private static let lateRootCheckpointID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000019"
    )!
    private static let lateSuccessorCheckpointID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000020"
    )!
    private static let lateModelReceiptID = UUID(
        uuidString: "a1000000-0000-0000-0000-000000000021"
    )!
    private static let packagePath = "/private/tmp/MacScope-Atomicity.mscope"
    private static let now = Date(timeIntervalSince1970: 1_787_000_000)
}

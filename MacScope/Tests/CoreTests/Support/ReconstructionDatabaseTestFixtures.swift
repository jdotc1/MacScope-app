import CryptoKit
import Foundation
import XCTest
@testable import MacScope

// Reconstruction workspace-database fixtures shared by tests in several bundles (split out of
// ReconstructionWorkspaceDatabaseTests.swift so CoreTests and Phase2Tests can both compile them).

enum ReconstructionDatabaseTestFixtures {
    static let reconstructionTableNames: Set<String> = [
        "reconstruction_projects",
        "reconstruction_artifact_contents",
        "reconstruction_artifact_occurrences",
        "reconstruction_artifact_roles",
        "reconstruction_artifact_relations",
        "reconstruction_evidence",
        "reconstruction_evidence_citations",
        "reconstruction_evidence_relations",
        "reconstruction_tool_receipts",
        "reconstruction_model_receipts",
        "reconstruction_jobs",
        "reconstruction_tasks",
        "reconstruction_checkpoints",
        "reconstruction_checkpoint_tasks",
        "reconstruction_final_results",
    ]

    struct DatabaseFixture {
        let database: WorkspaceDatabase
        let workspaceUUID: UUID
        let workspaceRowID: Int64
        let binaryID: UUID
    }

    struct StateFixture {
        let state: ReconstructionWorkspaceState
        let project: ReconstructionProjectRecord
        let manifest: ReconstructionCorpusManifest
        let occurrence: ReconstructionArtifactOccurrenceRecord
        let job: ReconstructionJobRecord
        let task: ReconstructionTaskRecord
        let checkpoint: ReconstructionCheckpoint
    }

    static let workspaceUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000038")!
    static let documentUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000039")!
    static let projectUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000040")!
    static let occurrenceUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000041")!
    static let jobUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000042")!
    static let taskUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000043")!
    static let checkpointZeroUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000044")!
    static let checkpointOneUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000045")!
    static let checkpointTwoUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000046")!
    static let evidenceOneUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000047")!
    static let evidenceTwoUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000048")!
    static let citationUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000049")!
    static let evidenceRelationUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000050")!
    static let toolReceiptUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000051")!
    static let modelReceiptUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000052")!
    static let gapUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000053")!
    static let artifactRelationUUID = UUID(uuidString: "38000000-0000-0000-0000-000000000054")!
    static let subjectCitationUUID = UUID(
        uuidString: "38000000-0000-0000-0000-000000000056"
    )!

    static func digest(_ scalar: Character) -> String {
        String(repeating: String(scalar), count: 64)
    }

    static func makeCurrentDatabase() throws -> DatabaseFixture {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        var snapshot = AnalysisEngine.previewSnapshot()
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let analysis = try XCTUnwrap(snapshot.analysis(in: binary.slot))
        let fingerprint = try AnalysisInputFingerprint(
            imageSlot: binary.slot,
            binaryID: binary.id,
            binaryName: binary.name,
            binaryPath: binary.path,
            selectedSliceIndex: binary.selectedSliceIndex,
            artifactIdentity: binary.artifactIdentity,
            imageByteCount: UInt64(analysis.imageBytes.count),
            imageBytesSHA256: sha256(analysis.imageBytes),
            facets: [],
            overallSHA256: digest("3")
        )
        snapshot.mutateAnalysis(in: binary.slot) {
            $0.analysisInputFingerprint = fingerprint
        }
        let workspace = try database.saveSnapshot(
            workspaceUUID: workspaceUUID,
            workspaceName: "Reconstruction Fixture",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        return DatabaseFixture(
            database: database,
            workspaceUUID: workspaceUUID,
            workspaceRowID: try XCTUnwrap(workspace.id),
            binaryID: try XCTUnwrap(snapshot.binaries.first?.id)
        )
    }

    static func replacePersistedAnalysisFingerprint(
        in fixture: DatabaseFixture,
        overallSHA256: String
    ) throws {
        let persisted = try XCTUnwrap(
            fixture.database.loadWorkspaceState(workspaceID: fixture.workspaceRowID)
        )
        var snapshot = persisted.snapshot
        let binary = try XCTUnwrap(snapshot.binaries.first { $0.id == fixture.binaryID })
        let analysis = try XCTUnwrap(snapshot.analysis(in: binary.slot))
        let current = try XCTUnwrap(analysis.analysisInputFingerprint)
        let successor = try AnalysisInputFingerprint(
            schemaVersion: current.schemaVersion,
            imageSlot: current.imageSlot,
            binaryID: current.binaryID,
            binaryName: current.binaryName,
            binaryPath: current.binaryPath,
            selectedSliceIndex: current.selectedSliceIndex,
            artifactIdentity: current.artifactIdentity,
            imageByteCount: current.imageByteCount,
            imageBytesSHA256: current.imageBytesSHA256,
            facets: current.facets,
            overallSHA256: overallSHA256
        )
        snapshot.mutateAnalysis(in: binary.slot) {
            $0.analysisInputFingerprint = successor
        }
        _ = try fixture.database.replaceWorkspaceState(
            workspaceID: fixture.workspaceRowID,
            workspaceName: persisted.workspace.name,
            snapshot: snapshot,
            selectedSidebarItemID: persisted.session.selectedSidebarItemID,
            selectedAddress: persisted.session.selectedAddress,
            selectedTool: persisted.session.selectedTool,
            editorMode: persisted.session.editorMode,
            isInspectorPresented: persisted.session.isInspectorPresented,
            sidebarSearchText: persisted.session.sidebarSearchText,
            focusedImageSlot: persisted.session.focusedImageSlot,
            now: persisted.workspace.modifiedAt
        )
    }

    static func makeVersion37Database() throws -> DatabaseFixture {
        let fixture = try makeCurrentDatabase()
        let workspaceUUIDString = fixture.workspaceUUID.uuidString
        try fixture.database.executeRawForTesting(
            """
            INSERT INTO phase2_assistant_session_records (
              id, workspace_id, workspace_uuid, document_id, sequence,
              conversation_id, turn_sequence, inference_turn_id, is_legacy,
              intent_id, user_goal, status, prompt_text, answer_text, transcript_text,
              context_digest, canonical_byte_count, provider_tool_count,
              continuation_checkpoint_json, shell_proposal_id, shell_execution_id,
              continuation_ordinal, continuation_request_id,
              record_schema_version, created_at, completed_at, content_sha256
            ) VALUES (
              '38000000-0000-0000-0000-000000000060', \(fixture.workspaceRowID),
              '\(workspaceUUIDString)', '\(documentUUID.uuidString)', 1,
              '38000000-0000-0000-0000-000000000061', 1,
              '38000000-0000-0000-0000-000000000062', 0,
              'fixture.intent', 'fixture goal', 'completed', 'prompt', 'answer', 'transcript',
              NULL, 10, 0, NULL, NULL, NULL, NULL, NULL, 3,
              '2026-08-09T00:00:00.000Z', '2026-08-09T00:00:01.000Z', '\(digest("a"))'
            );
            INSERT INTO phase2_shell_sessions (
              workspace_id, workspace_uuid, document_id, shell_session_json,
              record_schema_version, updated_at
            ) VALUES (
              \(fixture.workspaceRowID), '\(workspaceUUIDString)', '\(documentUUID.uuidString)',
              '{}', 1, '2026-08-09T00:00:00.000Z'
            );
            """
        )
        try dropReconstructionTables(from: fixture.database)
        try fixture.database.setUserVersionForTesting(37)
        return fixture
    }

    static func dropReconstructionTables(from database: WorkspaceDatabase) throws {
        for table in [
            "reconstruction_final_results",
            "reconstruction_checkpoint_tasks",
            "reconstruction_checkpoints",
            "reconstruction_model_receipts",
            "reconstruction_tool_receipts",
            "reconstruction_evidence_relations",
            "reconstruction_evidence_citations",
            "reconstruction_evidence",
            "reconstruction_tasks",
            "reconstruction_jobs",
            "reconstruction_artifact_relations",
            "reconstruction_artifact_roles",
            "reconstruction_artifact_occurrences",
            "reconstruction_artifact_contents",
            "reconstruction_projects",
        ] {
            try database.executeRawForTesting("DROP TABLE IF EXISTS \(table);")
        }
    }

    static func makeFoundationState(
        workspaceBinaryID: UUID,
        evidenceSubjectUsesImageBinding: Bool = false,
        evidenceSubjectUsesFunction: Bool = false
    ) throws -> StateFixture {
        let contentBytes = Data("test".utf8)
        let content = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: sha256(contentBytes),
            byteCount: UInt64(contentBytes.count)
        )
        let occurrenceID = ReconstructionArtifactOccurrenceID(rawValue: occurrenceUUID)
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: occurrenceID,
            contentIdentity: content,
            kind: .machOImage,
            roles: [.primaryTarget],
            executableMode: true,
            originalName: "fixture.bin",
            diagnostic: nil
        )
        let relationDraft = try ReconstructionArtifactRelationRecord(
            relationID: artifactRelationUUID,
            kind: .references,
            sourceOccurrenceID: occurrenceID,
            targetOccurrenceID: occurrenceID,
            unresolvedLocator: nil,
            evidenceSource: .loader,
            canonicalSHA256: digest("0")
        )
        let artifactRelation = try ReconstructionArtifactRelationRecord(
            relationID: relationDraft.relationID,
            kind: relationDraft.kind,
            sourceOccurrenceID: relationDraft.sourceOccurrenceID,
            targetOccurrenceID: relationDraft.targetOccurrenceID,
            unresolvedLocator: relationDraft.unresolvedLocator,
            evidenceSource: relationDraft.evidenceSource,
            canonicalSHA256: ReconstructionRelationDiscoverer().canonicalDigest(
                for: relationDraft
            )
        )
        let manifestDraft = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectUUID,
            artifacts: [occurrence],
            relations: [artifactRelation],
            canonicalSHA256: digest("2")
        )
        let manifest = try ReconstructionCorpusManifest(
            schemaVersion: manifestDraft.schemaVersion,
            reconstructionProjectID: manifestDraft.reconstructionProjectID,
            artifacts: manifestDraft.artifacts,
            relations: manifestDraft.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(
                of: manifestDraft
            )
        )
        let project = try ReconstructionProjectRecord(
            projectID: projectUUID,
            name: "Reconstruction Fixture",
            currentCorpusManifestSHA256: manifest.canonicalSHA256
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: occurrenceID,
            contentIdentity: content
        )
        let subject: ReconstructionSubjectCoordinate
        if evidenceSubjectUsesFunction {
            subject = .function(try ReconstructionFunctionCoordinate(
                artifact: artifact,
                image: ReconstructionImageBinding(binaryID: workspaceBinaryID,
                    imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64,
                    machOIdentity: nil),
                analysisFingerprintSHA256: digest("3"), startAddress: 0x1000,
                endAddressExclusive: 0x1010, boundarySchemaVersion: 1,
                functionUUIDHint: nil, symbolHint: nil
            ))
        } else if evidenceSubjectUsesImageBinding {
            subject = .image(
                try ReconstructionImageCoordinate(
                    artifact: artifact,
                    image: ReconstructionImageBinding(
                        binaryID: workspaceBinaryID,
                        imageSlot: .primary,
                        selectedSliceIndex: nil,
                        architecture: .arm64,
                        machOIdentity: nil
                    ),
                    analysisFingerprintSHA256: digest("3")
                )
            )
        } else {
            subject = .artifact(artifact)
        }
        let taskIdentity = try ReconstructionTaskIdentity.make(
            taskID: taskUUID,
            jobID: jobUUID,
            kind: .decompileNative,
            subject: subject,
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.\(ReconstructionTaskKind.decompileNative.rawValue).v1"
        )
        let task = ReconstructionTaskRecord(identity: taskIdentity, state: .pending, diagnostic: nil)
        let gap = try makeGap(
            gapID: gapUUID,
            subject: subject,
            operationID: ReconstructionOperationID.evidenceQuery.rawValue,
            reason: .sanitizing("pending evidence")
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: checkpointZeroUUID,
            jobID: jobUUID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: manifest.canonicalSHA256,
                records: [],
                projectedClassificationsByEvidenceID: [:],
                relations: [],
                gaps: [gap],
                checkpointRevisionsByID: [:]
            ),
            pendingTaskIDs: [taskUUID],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier.canonicalSHA256(
                for: [gap]
            ),
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let objective = "Recover the supplied fixture"
        let job = try ReconstructionJobRecord(
            jobID: jobUUID,
            reconstructionProjectID: projectUUID,
            objective: objective,
            objectiveSHA256: sha256(Data(objective.utf8)),
            creationCorpusManifestSHA256: manifest.canonicalSHA256,
            state: .retrieving,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil,
            budget: try ReconstructionJobBudget(
                maxRounds: 4,
                maxTasks: 64,
                maxEvidenceRecords: 128,
                maxEncodedBytes: 1_048_576
            )
        )
        let state = try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [manifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [gap],
            jobs: [job],
            tasks: [task],
            checkpoints: [checkpoint],
            toolReceipts: [],
            modelReceipts: []
        )
        return StateFixture(
            state: state,
            project: project,
            manifest: manifest,
            occurrence: occurrence,
            job: job,
            task: task,
            checkpoint: checkpoint
        )
    }

    static func makeRichState(
        workspaceBinaryID: UUID,
        evidenceSubjectUsesImageBinding: Bool = false,
        evidenceSubjectUsesFunction: Bool = false
    ) throws -> ReconstructionWorkspaceState {
        let foundation = try makeFoundationState(
            workspaceBinaryID: workspaceBinaryID,
            evidenceSubjectUsesImageBinding: evidenceSubjectUsesImageBinding,
            evidenceSubjectUsesFunction: evidenceSubjectUsesFunction
        )
        let mutation = try makeMutation(from: foundation)
        let completedTask = ReconstructionTaskRecord(
            identity: foundation.task.identity,
            state: .completed,
            diagnostic: nil
        )
        let advancedJob = try ReconstructionJobRecord(
            jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID,
            objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256,
            state: mutation.successorCheckpoint.coordinatorState,
            currentCheckpointID: mutation.successorCheckpoint.checkpointID,
            terminalReason: mutation.successorCheckpoint.terminalReason,
            budget: foundation.job.budget,
            creationOrdinal: try XCTUnwrap(foundation.job.creationOrdinal),
            pauseContext: foundation.job.pauseContext
        )
        return try ReconstructionWorkspaceState(
            projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests,
            evidence: mutation.evidence,
            evidenceRelations: mutation.evidenceRelations,
            evidenceGaps: foundation.state.evidenceGaps,
            jobs: [advancedJob],
            tasks: [completedTask],
            checkpoints: [foundation.checkpoint, mutation.successorCheckpoint],
            toolReceipts: mutation.toolReceipts,
            modelReceipts: mutation.modelReceipts
        )
    }

    static func makeStateWithEveryEvidenceClassification(
        workspaceBinaryID: UUID
    ) throws -> ReconstructionWorkspaceState {
        let rich = try makeRichState(
            workspaceBinaryID: workspaceBinaryID,
            evidenceSubjectUsesImageBinding: true
        )
        let template = try XCTUnwrap(rich.evidence.first)
        let evidence = try ReconstructionEvidenceClassification.allCases.enumerated().map {
            index, classification in
            let id: UUID
            switch index {
            case 0: id = evidenceOneUUID
            case 1: id = evidenceTwoUUID
            default:
                id = try XCTUnwrap(
                    UUID(uuidString: String(format: "38000000-0000-0000-0000-%012d", 70 + index))
                )
            }
            return try ReconstructionEvidenceRecord(
                evidenceID: id,
                schemaVersion: template.schemaVersion,
                subject: template.subject,
                operationID: template.operationID,
                payloadKind: template.payloadKind,
                payload: template.payload,
                payloadByteCount: template.payloadByteCount,
                payloadSHA256: template.payloadSHA256,
                facetDependencies: template.facetDependencies,
                producer: template.producer,
                citations: [
                    try ReconstructionEvidenceCitation(
                        citationID: try XCTUnwrap(
                            UUID(uuidString: String(
                                format: "38000000-0000-0000-0000-%012d",
                                100 + index
                            ))
                        ),
                        sourceEvidenceID: nil,
                        subject: template.subject,
                        locator: nil
                    ),
                ],
                creatingJobID: template.creatingJobID,
                creatingTaskID: template.creatingTaskID,
                creatingCheckpointID: template.creatingCheckpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptUUID,
                classification: classification,
                supersedesEvidenceID: nil,
                supersededByEvidenceID: nil,
                diagnostic: template.diagnostic
            )
        }
        let toolReceiptTemplate = try XCTUnwrap(rich.toolReceipts.first)
        let toolReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: toolReceiptTemplate.receiptID,
            jobID: toolReceiptTemplate.jobID,
            taskID: toolReceiptTemplate.taskID,
            checkpointRevision: toolReceiptTemplate.checkpointRevision,
            requestIdentitySHA256: toolReceiptTemplate.requestIdentitySHA256,
            producer: toolReceiptTemplate.producer,
            terminalState: toolReceiptTemplate.terminalState,
            outputEvidenceIDs: evidence.map(\.evidenceID),
            diagnostic: toolReceiptTemplate.diagnostic
        )
        let modelReceiptTemplate = try XCTUnwrap(rich.modelReceipts.first)
        let modelReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: modelReceiptTemplate.receiptID,
            jobID: modelReceiptTemplate.jobID,
            taskID: modelReceiptTemplate.taskID,
            checkpointRevision: modelReceiptTemplate.checkpointRevision,
            requestIdentitySHA256: modelReceiptTemplate.requestIdentitySHA256,
            producer: modelReceiptTemplate.producer,
            terminalState: modelReceiptTemplate.terminalState,
            selectedHandleIDs: modelReceiptTemplate.selectedHandleIDs,
            acceptedEvidenceIDs: [],
            diagnostic: modelReceiptTemplate.diagnostic
        )
        let projectedClassifications = Dictionary(uniqueKeysWithValues: evidence.map {
            ($0.evidenceID, $0.classification)
        })
        let checkpoints = try rich.checkpoints.map { checkpoint in
            guard checkpoint.checkpointID == checkpointOneUUID else { return checkpoint }
            return try ReconstructionCheckpoint.make(
                checkpointID: checkpoint.checkpointID,
                schemaVersion: checkpoint.schemaVersion,
                jobID: checkpoint.jobID,
                revision: checkpoint.revision,
                parentCheckpointID: checkpoint.parentCheckpointID,
                parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
                corpusManifestSHA256: checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: try ReconstructionEvidenceFrontier.canonicalSHA256(
                    corpusManifestSHA256: checkpoint.corpusManifestSHA256,
                    records: evidence,
                    projectedClassificationsByEvidenceID: projectedClassifications,
                    relations: [],
                    gaps: rich.evidenceGaps,
                    checkpointRevisionsByID: [checkpointOneUUID: checkpoint.revision]
                ),
                pendingTaskIDs: checkpoint.pendingTaskIDs,
                runningTaskIDs: checkpoint.runningTaskIDs,
                completedTaskIDs: checkpoint.completedTaskIDs,
                failedTaskIDs: checkpoint.failedTaskIDs,
                blockedTaskIDs: checkpoint.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                    .canonicalSHA256(for: rich.evidenceGaps),
                modelReceiptIDs: checkpoint.modelReceiptIDs,
                toolReceiptIDs: checkpoint.toolReceiptIDs,
                coordinatorState: checkpoint.coordinatorState,
                terminalReason: checkpoint.terminalReason
            )
        }
        return try ReconstructionWorkspaceState(
            projects: rich.projects,
            corpusManifests: rich.corpusManifests,
            evidence: evidence,
            evidenceRelations: [],
            evidenceGaps: rich.evidenceGaps,
            jobs: rich.jobs,
            tasks: rich.tasks,
            checkpoints: checkpoints,
            toolReceipts: [toolReceipt],
            modelReceipts: [modelReceipt]
        )
    }

    static func makeMutation(
        from foundation: StateFixture,
        unknownCitationSource: Bool = false,
        unknownRelationTarget: Bool = false,
        unknownToolTask: Bool = false,
        transitionExpectedState: ReconstructionTaskState = .pending,
        wrongParentDigest: Bool = false
    ) throws -> ReconstructionCheckpointMutation {
        let subject = try XCTUnwrap(foundation.task.identity.subject)
        let operationID = ReconstructionOperationID.evidenceQuery.rawValue
        let producer = try makeProducer(operationID: operationID)
        let firstPayload = Data("first evidence".utf8)
        let secondPayload = Data("second evidence".utf8)
        let subjectCitation = try ReconstructionEvidenceCitation(
            citationID: subjectCitationUUID,
            sourceEvidenceID: nil,
            subject: subject,
            locator: nil
        )
        let firstEvidence = try ReconstructionEvidenceRecord(
            evidenceID: evidenceOneUUID,
            subject: subject,
            operationID: operationID,
            payloadKind: .text,
            payload: firstPayload,
            payloadByteCount: UInt64(firstPayload.count),
            payloadSHA256: sha256(firstPayload),
            facetDependencies: [],
            producer: producer,
            citations: [subjectCitation],
            creatingJobID: foundation.job.jobID,
            creatingTaskID: foundation.task.identity.taskID,
            creatingCheckpointID: checkpointOneUUID,
            modelReceiptID: nil,
            toolReceiptID: toolReceiptUUID,
            classification: .acceptedCurrent,
            supersedesEvidenceID: nil,
            supersededByEvidenceID: nil,
            diagnostic: nil
        )
        let citation = try ReconstructionEvidenceCitation(
            citationID: citationUUID,
            sourceEvidenceID: unknownCitationSource
                ? UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
                : evidenceOneUUID,
            subject: nil,
            locator: "fixture:second"
        )
        let secondEvidence = try ReconstructionEvidenceRecord(
            evidenceID: evidenceTwoUUID,
            subject: subject,
            operationID: operationID,
            payloadKind: .text,
            payload: secondPayload,
            payloadByteCount: UInt64(secondPayload.count),
            payloadSHA256: sha256(secondPayload),
            facetDependencies: [],
            producer: producer,
            citations: [citation],
            creatingJobID: foundation.job.jobID,
            creatingTaskID: foundation.task.identity.taskID,
            creatingCheckpointID: checkpointOneUUID,
            modelReceiptID: modelReceiptUUID,
            toolReceiptID: nil,
            classification: .acceptedCurrent,
            supersedesEvidenceID: nil,
            supersededByEvidenceID: nil,
            diagnostic: nil
        )
        let evidenceRelation = ReconstructionEvidenceRelation(
            relationID: evidenceRelationUUID,
            kind: .supports,
            sourceEvidenceID: evidenceOneUUID,
            targetEvidenceID: unknownRelationTarget
                ? UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
                : evidenceTwoUUID
        )
        let toolReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: toolReceiptUUID,
            jobID: foundation.job.jobID,
            taskID: unknownToolTask
                ? UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
                : foundation.task.identity.taskID,
            checkpointRevision: 1,
            requestIdentitySHA256: digest("b"),
            producer: producer,
            terminalState: .completed,
            outputEvidenceIDs: [evidenceOneUUID],
            diagnostic: nil
        )
        let modelReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: modelReceiptUUID,
            jobID: foundation.job.jobID,
            taskID: foundation.task.identity.taskID,
            checkpointRevision: 1,
            requestIdentitySHA256: digest("d"),
            producer: producer,
            terminalState: .completed,
            selectedHandleIDs: ["handle.fixture"],
            acceptedEvidenceIDs: [evidenceTwoUUID],
            diagnostic: nil
        )
        let parentDigest = wrongParentDigest ? digest("0") : foundation.checkpoint.canonicalSHA256
        let evidenceRecords = [firstEvidence, secondEvidence]
        let evidenceRelations = [evidenceRelation]
        let projectedClassifications = Dictionary(uniqueKeysWithValues: evidenceRecords.map {
            ($0.evidenceID, $0.classification)
        })
        let freshnessAuthority = try makeFreshnessAuthority(from: foundation)
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: checkpointOneUUID,
            jobID: foundation.job.jobID,
            revision: 1,
            parentCheckpointID: foundation.checkpoint.checkpointID,
            parentCheckpointSHA256: parentDigest,
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: foundation.manifest.canonicalSHA256,
                records: evidenceRecords,
                projectedClassificationsByEvidenceID: projectedClassifications,
                relations: evidenceRelations,
                gaps: foundation.state.evidenceGaps,
                checkpointRevisionsByID: [checkpointOneUUID: 1]
            ),
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [foundation.task.identity.taskID],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier.canonicalSHA256(
                for: foundation.state.evidenceGaps
            ),
            modelReceiptIDs: [modelReceiptUUID],
            toolReceiptIDs: [toolReceiptUUID],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        return ReconstructionCheckpointMutation(
            jobID: foundation.job.jobID,
            expectedParentCheckpointID: foundation.checkpoint.checkpointID,
            expectedParentCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
            expectedParentRevision: foundation.checkpoint.revision,
            evidence: evidenceRecords,
            evidenceRelations: evidenceRelations,
            toolReceipts: [toolReceipt],
            modelReceipts: [modelReceipt],
            taskTransitions: [
                ReconstructionTaskTransition(
                    taskID: foundation.task.identity.taskID,
                    expectedState: transitionExpectedState,
                    successorState: .completed,
                    diagnostic: nil
                )
            ],
            freshnessAuthority: freshnessAuthority,
            successorCheckpoint: successor
        )
    }

    static func makeReplayMutation(
        from committedState: ReconstructionWorkspaceState,
        receipt: ReconstructionToolReceipt,
        freshnessAuthority suppliedFreshnessAuthority: ReconstructionFreshnessAuthority? = nil,
        evidenceRelations appendedEvidenceRelations: [ReconstructionEvidenceRelation] = []
    ) throws -> ReconstructionCheckpointMutation {
        let parent = try XCTUnwrap(committedState.checkpoints.last)
        let job = try XCTUnwrap(committedState.jobs.first)
        let task = try XCTUnwrap(committedState.tasks.first)
        let manifest = try XCTUnwrap(committedState.corpusManifests.first {
            $0.canonicalSHA256 == job.creationCorpusManifestSHA256
        })
        let projectJobIDs = Set(committedState.jobs.filter {
            $0.reconstructionProjectID == job.reconstructionProjectID
        }.map(\.jobID))
        let projectOccurrenceIDs = Set(committedState.corpusManifests.filter {
            $0.reconstructionProjectID == job.reconstructionProjectID
        }.flatMap { $0.artifacts.map(\.occurrenceID) })
        func subjectOccurrenceID(
            _ subject: ReconstructionSubjectCoordinate
        ) -> ReconstructionArtifactOccurrenceID {
            switch subject {
            case .artifact(let artifact): artifact.occurrenceID
            case .image(let image): image.artifact.occurrenceID
            case .function(let function): function.artifact.occurrenceID
            }
        }
        let projectEvidence = committedState.evidence.filter {
            projectJobIDs.contains($0.creatingJobID)
                && projectOccurrenceIDs.contains(subjectOccurrenceID($0.subject))
        }
        let projectGaps = committedState.evidenceGaps.filter {
            projectOccurrenceIDs.contains(subjectOccurrenceID($0.subject))
        }
        let projectEvidenceIDs = Set(projectEvidence.map(\.evidenceID))
        let projectGapIDs = Set(projectGaps.map(\.gapID))
        let completeRelations = committedState.evidenceRelations + appendedEvidenceRelations
        let projectRelations = completeRelations.filter { relation in
            projectEvidenceIDs.contains(relation.sourceEvidenceID)
                && (relation.kind == .resolvesGap
                    ? projectGapIDs.contains(relation.targetEvidenceID)
                    : projectEvidenceIDs.contains(relation.targetEvidenceID))
        }
        let freshnessAuthority: ReconstructionFreshnessAuthority
        if let suppliedFreshnessAuthority {
            freshnessAuthority = suppliedFreshnessAuthority
        } else {
            freshnessAuthority = try makeFreshnessAuthority(
                manifest: manifest,
                authoritativeSubjects: projectEvidence.map(\.subject),
                includesCurrentAnalysis: true
            )
        }
        let projection = try ReconstructionEvidenceProjector().project(
            records: projectEvidence,
            relations: projectRelations.filter { $0.kind != .resolvesGap },
            authority: freshnessAuthority
        )
        let projectedClassifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        let checkpointIDs = Set(projectEvidence.map(\.creatingCheckpointID))
        let checkpointRevisions = Dictionary(uniqueKeysWithValues: committedState.checkpoints
            .filter { checkpointIDs.contains($0.checkpointID) }
            .map { ($0.checkpointID, $0.revision) })
        let gapProjection = try ReconstructionGapProjector().project(
            gaps: projectGaps,
            records: projectEvidence,
            relations: projectRelations,
            projectedClassificationsByEvidenceID: projectedClassifications
        )
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: checkpointTwoUUID,
            jobID: job.jobID,
            revision: parent.revision + 1,
            parentCheckpointID: parent.checkpointID,
            parentCheckpointSHA256: parent.canonicalSHA256,
            corpusManifestSHA256: parent.corpusManifestSHA256,
            evidenceFrontierSHA256: try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: job.creationCorpusManifestSHA256,
                records: projectEvidence,
                projectedClassificationsByEvidenceID: projectedClassifications,
                relations: projectRelations,
                gaps: projectGaps,
                checkpointRevisionsByID: checkpointRevisions
            ),
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [task.identity.taskID],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: gapProjection.unresolvedGapFrontierSHA256,
            modelReceiptIDs: parent.modelReceiptIDs,
            toolReceiptIDs: parent.toolReceiptIDs,
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        return ReconstructionCheckpointMutation(
            jobID: job.jobID,
            expectedParentCheckpointID: parent.checkpointID,
            expectedParentCheckpointSHA256: parent.canonicalSHA256,
            expectedParentRevision: parent.revision,
            evidence: [],
            evidenceRelations: appendedEvidenceRelations,
            toolReceipts: [receipt],
            modelReceipts: [],
            taskTransitions: [],
            freshnessAuthority: freshnessAuthority,
            successorCheckpoint: successor
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func makeProducer(operationID: String) throws -> ReconstructionProducerIdentity {
        func producer(canonicalSHA256: String) throws -> ReconstructionProducerIdentity {
            try ReconstructionProducerIdentity(
                macScopeBuildIdentity: "MacScope-fixture",
                macScopeSourceIdentity: "source-fixture",
                operationIdentity: operationID,
                registryIdentity: "reconstruction.v1",
                protocolIdentity: "reconstructionR1",
                canonicalSHA256: canonicalSHA256
            )
        }

        let draft = try producer(canonicalSHA256: digest("0"))
        return try producer(
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(draft)
        )
    }

    static func makeGap(
        gapID: UUID,
        subject: ReconstructionSubjectCoordinate,
        operationID: String,
        reason: ReconstructionDiagnostic
    ) throws -> ReconstructionEvidenceGap {
        func gap(canonicalSHA256: String) throws -> ReconstructionEvidenceGap {
            try ReconstructionEvidenceGap(
                gapID: gapID,
                subject: subject,
                operationID: operationID,
                reason: reason,
                canonicalSHA256: canonicalSHA256
            )
        }

        let draft = try gap(canonicalSHA256: digest("0"))
        return try gap(canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalGapSHA256(draft))
    }

    static func makeFreshnessAuthority(
        from foundation: StateFixture,
        includesCurrentAnalysis: Bool = true
    ) throws -> ReconstructionFreshnessAuthority {
        try makeFreshnessAuthority(
            manifest: foundation.manifest,
            authoritativeSubjects: foundation.task.identity.subject.map { [$0] } ?? [],
            includesCurrentAnalysis: includesCurrentAnalysis
        )
    }

    static func makeFreshnessAuthority(
        manifest: ReconstructionCorpusManifest,
        authoritativeSubjects: [ReconstructionSubjectCoordinate],
        includesCurrentAnalysis: Bool
    ) throws -> ReconstructionFreshnessAuthority {
        let currentArtifacts = manifest.artifacts.map {
            ReconstructionArtifactCoordinate(
                occurrenceID: $0.occurrenceID,
                contentIdentity: $0.contentIdentity
            )
        }
        var currentImages = Set<ReconstructionImageCoordinate>()
        if includesCurrentAnalysis {
            for subject in authoritativeSubjects {
                switch subject {
                case .artifact:
                    break
                case .image(let image):
                    currentImages.insert(image)
                case .function(let function):
                    currentImages.insert(try ReconstructionImageCoordinate(
                        artifact: function.artifact,
                        image: function.image,
                        analysisFingerprintSHA256: function.analysisFingerprintSHA256
                    ))
                }
            }
        }
        return try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: manifest.canonicalSHA256,
            currentArtifacts: currentArtifacts,
            currentImages: Array(currentImages),
            currentFacetFingerprints: [:]
        )
    }
}

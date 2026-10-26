import Foundation
import XCTest
@testable import MacScope

final class ReconstructionCorpusHistoryTests: XCTestCase {
    func testRetainedManifestDigestIsRecomputedBeforeDurableAdmission() throws {
        let history = try HistoryFixture.make()
        let forgedDigest = String(repeating: "f", count: 64)
        let forgedManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: history.currentManifest.reconstructionProjectID,
            artifacts: history.currentManifest.artifacts,
            relations: history.currentManifest.relations,
            canonicalSHA256: forgedDigest
        )
        let forgedProject = try ReconstructionProjectRecord(
            projectID: history.project.projectID,
            name: history.project.name,
            currentCorpusManifestSHA256: forgedDigest
        )
        let state = try minimalState(
            project: forgedProject,
            manifests: [history.historicalManifest, forgedManifest]
        )

        XCTAssertThrowsError(try ReconstructionPackageCodec.encode(state)) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("manifest digest disagreement")
            )
        }
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        XCTAssertThrowsError(
            try databaseFixture.database.replaceReconstructionState(
                workspaceID: databaseFixture.workspaceUUID,
                state: state
            )
        )
        XCTAssertEqual(
            try databaseFixture.database.loadReconstructionState(
                workspaceID: databaseFixture.workspaceUUID
            ),
            .empty
        )
    }

    func testDatabaseReplaceAndLoadRetainBothManifestsAndHistoricalEvidence() throws {
        let history = try HistoryFixture.make()
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()

        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: history.state
        )
        let loaded = try databaseFixture.database.loadReconstructionState(
            workspaceID: databaseFixture.workspaceUUID
        )

        XCTAssertEqual(loaded.projects.count, 1)
        XCTAssertEqual(
            loaded.projects.first?.currentCorpusManifestSHA256,
            history.currentManifest.canonicalSHA256
        )
        XCTAssertEqual(loaded.corpusManifests.count, 2)
        XCTAssertEqual(
            Set(loaded.corpusManifests.map(\.canonicalSHA256)),
            [
                history.historicalManifest.canonicalSHA256,
                history.currentManifest.canonicalSHA256,
            ]
        )
        XCTAssertEqual(loaded.evidence, [history.historicalEvidence])

        let loadedHistoricalManifest = try XCTUnwrap(loaded.corpusManifests.first {
            $0.canonicalSHA256 == history.historicalManifest.canonicalSHA256
        })
        let loadedCurrentManifest = try XCTUnwrap(loaded.corpusManifests.first {
            $0.canonicalSHA256 == history.currentManifest.canonicalSHA256
        })
        XCTAssertEqual(
            try XCTUnwrap(loadedHistoricalManifest.artifacts.first {
                $0.occurrenceID == history.currentOccurrence.occurrenceID
            }),
            try XCTUnwrap(loadedCurrentManifest.artifacts.first {
                $0.occurrenceID == history.currentOccurrence.occurrenceID
            }),
            "An unchanged occurrence ID may be retained only as the same full record."
        )
        XCTAssertEqual(
            Set(loadedHistoricalManifest.artifacts.map(\.occurrenceID)),
            [history.historicalOccurrence.occurrenceID, history.currentOccurrence.occurrenceID]
        )
        XCTAssertEqual(
            loadedCurrentManifest.artifacts.map(\.occurrenceID),
            [history.currentOccurrence.occurrenceID]
        )
    }

    func testPackageEncodeAndOpenRetainBothManifestsAndBothAttachmentContents() throws {
        let history = try HistoryFixture.make()

        let encoded = try ReconstructionPackageCodec.encode(history.state)
        XCTAssertEqual(encoded.contents.count, 2)
        XCTAssertEqual(
            encoded.contents.map(\.contentIdentity.digest),
            [
                "093dd9d21c7c0708e20c5a7028be5f2406f4e9eeb03b8df743d065b15253e217",
                "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            ]
        )
        let decoded = try ReconstructionPackageCodec.decode(
            descriptor: encoded.descriptor,
            corpusData: encoded.corpusData,
            evidenceData: encoded.evidenceData,
            checkpointData: encoded.checkpointData
        )
        XCTAssertEqual(decoded.corpusManifests.count, 2)
        XCTAssertEqual(decoded.evidence, [history.historicalEvidence])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReconstructionCorpusHistoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let historicalSourceURL = root.appendingPathComponent("historical.bin")
        let currentSourceURL = root.appendingPathComponent("current.bin")
        try history.historicalBytes.write(to: historicalSourceURL)
        try history.currentBytes.write(to: currentSourceURL)
        let packageURL = root.appendingPathComponent("History.mscope", isDirectory: true)

        try MacScopeDocumentPackage.writePackage(
            WorkspacePackageManifest(
                documentID: UUID(uuidString: "54000000-0000-0000-0000-000000000011")!,
                workspaceUUID: UUID(uuidString: "54000000-0000-0000-0000-000000000012")!,
                workspaceName: "Retained corpus history",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2),
                binaries: [],
                analysis: WorkspacePackageAnalysis(),
                session: nil
            ),
            attachmentsByBinaryID: [:],
            reconstructionState: history.state,
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: history.historicalOccurrence.contentIdentity,
                    verifiedURL: historicalSourceURL
                ),
                ReconstructionAttachmentSource(
                    contentIdentity: history.currentOccurrence.contentIdentity,
                    verifiedURL: currentSourceURL
                ),
            ],
            to: packageURL
        )
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)

        XCTAssertEqual(opened.reconstructionState.corpusManifests.count, 2)
        XCTAssertEqual(
            opened.reconstructionState.projects.first?.currentCorpusManifestSHA256,
            history.currentManifest.canonicalSHA256
        )
        XCTAssertEqual(opened.reconstructionState.evidence, [history.historicalEvidence])
        XCTAssertEqual(opened.reconstructionAttachmentSources.count, 2)
        let openedBytesByDigest = try Dictionary(uniqueKeysWithValues:
            opened.reconstructionAttachmentSources.map { source in
                (source.contentIdentity.digest, try Data(contentsOf: source.verifiedURL))
            }
        )
        let expectedBytesByDigest: [String: Data] = [
            "093dd9d21c7c0708e20c5a7028be5f2406f4e9eeb03b8df743d065b15253e217":
                Data("historical corpus bytes\n".utf8),
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08":
                Data("test".utf8),
        ]
        XCTAssertEqual(openedBytesByDigest, expectedBytesByDigest)
    }

    func testPackageReopenAdmitsHistoricalImageAndFunctionEvidenceWithoutFreshnessProjection()
        throws {
        for historicalSubjectKind in [
            HistoricalSubjectKind.image,
            .function,
        ] {
            let history = try HistoryFixture.make(historicalSubjectKind: historicalSubjectKind)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ReconstructionHistoricalSubject-\(historicalSubjectKind)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let historicalSourceURL = root.appendingPathComponent("historical.bin")
            let currentSourceURL = root.appendingPathComponent("current.bin")
            try history.historicalBytes.write(to: historicalSourceURL)
            try history.currentBytes.write(to: currentSourceURL)
            let packageURL = root.appendingPathComponent("History.mscope", isDirectory: true)

            try MacScopeDocumentPackage.writePackage(
                WorkspacePackageManifest(
                    documentID: UUID(uuidString: "54000000-0000-0000-0000-000000000031")!,
                    workspaceUUID: UUID(uuidString: "54000000-0000-0000-0000-000000000032")!,
                    workspaceName: "Historical image and function evidence",
                    createdAt: Date(timeIntervalSince1970: 1),
                    modifiedAt: Date(timeIntervalSince1970: 2),
                    binaries: [],
                    analysis: WorkspacePackageAnalysis(),
                    session: nil
                ),
                attachmentsByBinaryID: [:],
                reconstructionState: history.state,
                reconstructionAttachmentSources: [
                    ReconstructionAttachmentSource(
                        contentIdentity: history.historicalOccurrence.contentIdentity,
                        verifiedURL: historicalSourceURL
                    ),
                    ReconstructionAttachmentSource(
                        contentIdentity: history.currentOccurrence.contentIdentity,
                        verifiedURL: currentSourceURL
                    ),
                ],
                to: packageURL
            )

            let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
            XCTAssertEqual(opened.reconstructionState.evidence, [history.historicalEvidence])
            XCTAssertEqual(
                opened.reconstructionState.evidence.first?.classification,
                .acceptedCurrent,
                "Durable acceptance is immutable; freshness is projected by the caller."
            )
            XCTAssertEqual(
                opened.reconstructionState.projects.first?.currentCorpusManifestSHA256,
                history.currentManifest.canonicalSHA256
            )
        }
    }

    func testSelectedCurrentManifestProjectsOldCoordinateStaleWithoutMutatingEvidence() throws {
        let history = try HistoryFixture.make()
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: history.state
        )
        let persistedBeforeProjection = try databaseFixture.database.loadReconstructionState(
            workspaceID: databaseFixture.workspaceUUID
        )
        let persistedEvidence = try XCTUnwrap(persistedBeforeProjection.evidence.first)
        let selectedManifestSHA256 = try XCTUnwrap(
            persistedBeforeProjection.projects.first?.currentCorpusManifestSHA256
        )
        let selectedManifest = try XCTUnwrap(persistedBeforeProjection.corpusManifests.first {
            $0.canonicalSHA256 == selectedManifestSHA256
        })
        let authority = ReconstructionAuthorityCut(
            corpusManifest: selectedManifest,
            authoritativeSubjects: [persistedEvidence.subject],
            facetFingerprints: [:],
            creatingJobID: persistedEvidence.creatingJobID,
            creatingTaskID: persistedEvidence.creatingTaskID,
            creatingCheckpointID: persistedEvidence.creatingCheckpointID,
            checkpointRevision: history.checkpoint.revision,
            operationID: .corpusArtifactDescribe,
            toolReceiptID: nil,
            modelReceiptID: nil,
            producer: persistedEvidence.producer,
            evidence: [persistedEvidence]
        )

        let projected = try ReconstructionEvidenceProjector().project(
            records: persistedBeforeProjection.evidence,
            relations: persistedBeforeProjection.evidenceRelations,
            gaps: [],
            against: authority
        )

        XCTAssertEqual(projected.corpusManifestSHA256, history.currentManifest.canonicalSHA256)
        XCTAssertEqual(projected.records.count, 1)
        XCTAssertEqual(
            projected.projectedClassificationsByEvidenceID[persistedEvidence.evidenceID],
            .staleArtifact
        )
        XCTAssertEqual(projected.records.first?.evidenceID, persistedEvidence.evidenceID)
        XCTAssertEqual(projected.records.first?.subject, persistedEvidence.subject)
        XCTAssertEqual(projected.records.first?.payload, Data("historical evidence".utf8))
        XCTAssertEqual(persistedEvidence.classification, .acceptedCurrent)
        XCTAssertEqual(
            try databaseFixture.database.loadReconstructionState(
                workspaceID: databaseFixture.workspaceUUID
            ).evidence,
            [persistedEvidence]
        )
    }

    func testEvidencePrimarySubjectMustBelongToCreatingJobCreationManifest() throws {
        let history = try HistoryFixture.make()
        let originalJob = try XCTUnwrap(history.state.jobs.first)
        let originalCheckpoint = try XCTUnwrap(history.state.checkpoints.first)
        let job = try ReconstructionJobRecord(
            jobID: originalJob.jobID,
            reconstructionProjectID: originalJob.reconstructionProjectID,
            objective: originalJob.objective,
            objectiveSHA256: originalJob.objectiveSHA256,
            creationCorpusManifestSHA256: history.currentManifest.canonicalSHA256,
            state: originalJob.state,
            currentCheckpointID: originalJob.currentCheckpointID,
            terminalReason: originalJob.terminalReason,
            budget: originalJob.budget,
            creationOrdinal: try XCTUnwrap(originalJob.creationOrdinal),
            pauseContext: originalJob.pauseContext
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: originalCheckpoint.checkpointID,
            schemaVersion: originalCheckpoint.schemaVersion,
            jobID: originalCheckpoint.jobID,
            revision: originalCheckpoint.revision,
            parentCheckpointID: originalCheckpoint.parentCheckpointID,
            parentCheckpointSHA256: originalCheckpoint.parentCheckpointSHA256,
            corpusManifestSHA256: history.currentManifest.canonicalSHA256,
            evidenceFrontierSHA256: originalCheckpoint.evidenceFrontierSHA256,
            pendingTaskIDs: originalCheckpoint.pendingTaskIDs,
            runningTaskIDs: originalCheckpoint.runningTaskIDs,
            completedTaskIDs: originalCheckpoint.completedTaskIDs,
            failedTaskIDs: originalCheckpoint.failedTaskIDs,
            blockedTaskIDs: originalCheckpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: originalCheckpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: originalCheckpoint.modelReceiptIDs,
            toolReceiptIDs: originalCheckpoint.toolReceiptIDs,
            coordinatorState: originalCheckpoint.coordinatorState,
            terminalReason: originalCheckpoint.terminalReason
        )
        let state = try ReconstructionWorkspaceState(
            projects: history.state.projects,
            corpusManifests: history.state.corpusManifests,
            evidence: history.state.evidence,
            evidenceRelations: history.state.evidenceRelations,
            evidenceGaps: history.state.evidenceGaps,
            jobs: [job],
            tasks: history.state.tasks,
            checkpoints: [checkpoint],
            toolReceipts: history.state.toolReceipts,
            modelReceipts: history.state.modelReceipts
        )

        XCTAssertThrowsError(try ReconstructionPackageCodec.encode(state)) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("evidence subject corpus ownership")
            )
        }
    }

    func testDuplicateManifestDigestWithDifferentRecordsFailsClosed() throws {
        let history = try HistoryFixture.make()
        let conflictingManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: history.project.projectID,
            artifacts: [history.historicalOccurrence],
            relations: [],
            canonicalSHA256: history.currentManifest.canonicalSHA256
        )
        let state = try minimalState(
            project: history.project,
            manifests: [history.currentManifest, conflictingManifest]
        )

        try assertPackageAndDatabaseReject(state)
    }

    func testSameOccurrenceIDDifferentRecordAcrossManifestsFailsClosed() throws {
        let history = try HistoryFixture.make()
        let changedRecord = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: history.currentOccurrence.occurrenceID,
            contentIdentity: history.historicalOccurrence.contentIdentity,
            kind: history.currentOccurrence.kind,
            roles: history.currentOccurrence.roles,
            executableMode: history.currentOccurrence.executableMode,
            originalName: "changed-content.bin",
            diagnostic: history.currentOccurrence.diagnostic
        )
        let historicalManifest = try Self.manifest(
            projectID: history.project.projectID,
            artifacts: [changedRecord],
            relations: []
        )
        XCTAssertNotEqual(
            historicalManifest.canonicalSHA256,
            history.currentManifest.canonicalSHA256
        )
        let state = try minimalState(
            project: history.project,
            manifests: [historicalManifest, history.currentManifest]
        )

        try assertPackageAndDatabaseReject(state)
    }

    func testCurrentManifestDigestMustSelectARetainedManifest() throws {
        let history = try HistoryFixture.make()
        let projectWithoutSelectedManifest = try ReconstructionProjectRecord(
            projectID: history.project.projectID,
            name: history.project.name,
            currentCorpusManifestSHA256:
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        )
        let state = try minimalState(
            project: projectWithoutSelectedManifest,
            manifests: [history.historicalManifest, history.currentManifest]
        )

        try assertPackageAndDatabaseReject(state)
    }

    func testResolvesGapRequiresEvidenceSourceAndDurableGapTarget() throws {
        let history = try HistoryFixture.make()
        let gap = try XCTUnwrap(history.state.evidenceGaps.first)
        let validRelation = ReconstructionEvidenceRelation(
            relationID: UUID(uuidString: "54000000-0000-0000-0000-000000000021")!,
            kind: .resolvesGap,
            sourceEvidenceID: history.historicalEvidence.evidenceID,
            targetEvidenceID: gap.gapID
        )
        let validState = try state(
            history.state,
            evidenceRelations: [validRelation]
        )

        XCTAssertNoThrow(try ReconstructionPackageCodec.encode(validState))
        let validDatabase = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        try validDatabase.database.replaceReconstructionState(
            workspaceID: validDatabase.workspaceUUID,
            state: validState
        )
        XCTAssertEqual(
            try validDatabase.database.loadReconstructionState(
                workspaceID: validDatabase.workspaceUUID
            ).evidenceRelations,
            [validRelation]
        )

        let missingGapRelation = ReconstructionEvidenceRelation(
            relationID: UUID(uuidString: "54000000-0000-0000-0000-000000000022")!,
            kind: .resolvesGap,
            sourceEvidenceID: history.historicalEvidence.evidenceID,
            targetEvidenceID: UUID(
                uuidString: "54000000-0000-0000-0000-000000000023"
            )!
        )
        let missingGapState = try state(
            history.state,
            evidenceRelations: [missingGapRelation]
        )

        try assertPackageAndDatabaseReject(missingGapState)
    }

    private func assertPackageAndDatabaseReject(
        _ state: ReconstructionWorkspaceState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.encode(state),
            file: file,
            line: line
        )
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        XCTAssertThrowsError(
            try databaseFixture.database.replaceReconstructionState(
                workspaceID: databaseFixture.workspaceUUID,
                state: state
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try databaseFixture.database.loadReconstructionState(
                workspaceID: databaseFixture.workspaceUUID
            ),
            .empty,
            "Rejected history must not partially persist.",
            file: file,
            line: line
        )
    }
}

private extension ReconstructionCorpusHistoryTests {
    enum HistoricalSubjectKind: String {
        case artifact
        case image
        case function
    }

    struct HistoryFixture {
        let state: ReconstructionWorkspaceState
        let project: ReconstructionProjectRecord
        let historicalManifest: ReconstructionCorpusManifest
        let currentManifest: ReconstructionCorpusManifest
        let historicalOccurrence: ReconstructionArtifactOccurrenceRecord
        let currentOccurrence: ReconstructionArtifactOccurrenceRecord
        let historicalEvidence: ReconstructionEvidenceRecord
        let checkpoint: ReconstructionCheckpoint
        let historicalBytes: Data
        let currentBytes: Data

        static func make(historicalSubjectKind: HistoricalSubjectKind = .artifact) throws -> Self {
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: UUID(
                    uuidString: "54000000-0000-0000-0000-000000000001"
                )!
            )
            let currentManifest = try ReconstructionCorpusHistoryTests.manifest(
                projectID: foundation.project.projectID,
                artifacts: [foundation.occurrence],
                relations: foundation.manifest.relations
            )
            let historicalBytes = Data("historical corpus bytes\n".utf8)
            let currentBytes = Data("test".utf8)
            let historicalOccurrence = try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: ReconstructionArtifactOccurrenceID(
                    rawValue: UUID(uuidString: "54000000-0000-0000-0000-000000000002")!
                ),
                contentIdentity: try ReconstructionContentIdentity(
                    algorithm: .sha256,
                    digest:
                        "093dd9d21c7c0708e20c5a7028be5f2406f4e9eeb03b8df743d065b15253e217",
                    byteCount: 24
                ),
                kind: .machOImage,
                roles: [.referenceSource],
                executableMode: false,
                originalName: "historical.bin",
                diagnostic: nil
            )
            let historicalManifest = try ReconstructionCorpusHistoryTests.manifest(
                projectID: foundation.project.projectID,
                artifacts: [historicalOccurrence, foundation.occurrence],
                relations: []
            )
            let project = try ReconstructionProjectRecord(
                projectID: foundation.project.projectID,
                name: foundation.project.name,
                currentCorpusManifestSHA256: currentManifest.canonicalSHA256
            )
            let job = try ReconstructionJobRecord(
                jobID: foundation.job.jobID,
                reconstructionProjectID: foundation.job.reconstructionProjectID,
                objective: foundation.job.objective,
                objectiveSHA256: foundation.job.objectiveSHA256,
                creationCorpusManifestSHA256: historicalManifest.canonicalSHA256,
                state: foundation.job.state,
                currentCheckpointID: foundation.job.currentCheckpointID,
                terminalReason: foundation.job.terminalReason,
                budget: foundation.job.budget,
                creationOrdinal: try XCTUnwrap(foundation.job.creationOrdinal),
                pauseContext: foundation.job.pauseContext
            )
            let toolReceiptID = UUID(
                uuidString: "54000000-0000-0000-0000-000000000004"
            )!
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: foundation.checkpoint.checkpointID,
                schemaVersion: foundation.checkpoint.schemaVersion,
                jobID: foundation.checkpoint.jobID,
                revision: foundation.checkpoint.revision,
                parentCheckpointID: foundation.checkpoint.parentCheckpointID,
                parentCheckpointSHA256: foundation.checkpoint.parentCheckpointSHA256,
                corpusManifestSHA256: historicalManifest.canonicalSHA256,
                evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
                pendingTaskIDs: foundation.checkpoint.pendingTaskIDs,
                runningTaskIDs: foundation.checkpoint.runningTaskIDs,
                completedTaskIDs: foundation.checkpoint.completedTaskIDs,
                failedTaskIDs: foundation.checkpoint.failedTaskIDs,
                blockedTaskIDs: foundation.checkpoint.blockedTaskIDs,
                unresolvedEvidenceGapSHA256:
                    foundation.checkpoint.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: foundation.checkpoint.modelReceiptIDs,
                toolReceiptIDs: foundation.checkpoint.toolReceiptIDs + [toolReceiptID],
                coordinatorState: foundation.checkpoint.coordinatorState,
                terminalReason: foundation.checkpoint.terminalReason
            )
            func producer(canonicalSHA256: String) throws -> ReconstructionProducerIdentity {
                try ReconstructionProducerIdentity(
                    macScopeBuildIdentity: "history-test-build",
                    macScopeSourceIdentity: "history-test-source",
                    operationIdentity: "reconstruction.corpus.artifact.describe",
                    registryIdentity: "reconstruction-operation-registry-v1",
                    protocolIdentity: "reconstruction-evidence-v1",
                    canonicalSHA256: canonicalSHA256
                )
            }
            let draftProducer = try producer(
                canonicalSHA256: ReconstructionDatabaseTestFixtures.digest("0")
            )
            let producer = try producer(
                canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(
                    draftProducer
                )
            )
            let historicalPayload = Data("historical evidence".utf8)
            let historicalArtifact = ReconstructionArtifactCoordinate(
                occurrenceID: historicalOccurrence.occurrenceID,
                contentIdentity: historicalOccurrence.contentIdentity
            )
            let historicalImageBinding = ReconstructionImageBinding(
                binaryID: UUID(uuidString: "54000000-0000-0000-0000-000000000006")!,
                imageSlot: ImageSlot(rawValue: 1),
                selectedSliceIndex: 0,
                architecture: .arm64,
                machOIdentity: nil
            )
            let historicalAnalysisFingerprint =
                ReconstructionDatabaseTestFixtures.digest("c")
            let historicalSubject: ReconstructionSubjectCoordinate
            switch historicalSubjectKind {
            case .artifact:
                historicalSubject = .artifact(historicalArtifact)
            case .image:
                historicalSubject = .image(try ReconstructionImageCoordinate(
                    artifact: historicalArtifact,
                    image: historicalImageBinding,
                    analysisFingerprintSHA256: historicalAnalysisFingerprint
                ))
            case .function:
                historicalSubject = .function(try ReconstructionFunctionCoordinate(
                    artifact: historicalArtifact,
                    image: historicalImageBinding,
                    analysisFingerprintSHA256: historicalAnalysisFingerprint,
                    startAddress: 0x1000,
                    endAddressExclusive: 0x1010,
                    boundarySchemaVersion: 1,
                    functionUUIDHint: UUID(
                        uuidString: "54000000-0000-0000-0000-000000000007"
                    ),
                    symbolHint: "historical_function"
                ))
            }
            let historicalEvidenceID = UUID(
                uuidString: "54000000-0000-0000-0000-000000000003"
            )!
            let historicalEvidence = try ReconstructionEvidenceRecord(
                evidenceID: historicalEvidenceID,
                subject: historicalSubject,
                operationID: "reconstruction.corpus.artifact.describe",
                payloadKind: .text,
                payload: historicalPayload,
                payloadByteCount: 19,
                payloadSHA256:
                    "8a65274de52255f11e1ff61564ab906de9d7a52431b3bbb771518e09088533b4",
                facetDependencies: [],
                producer: producer,
                citations: [
                    try ReconstructionEvidenceCitation(
                        citationID: UUID(
                            uuidString: "54000000-0000-0000-0000-000000000005"
                        )!,
                        sourceEvidenceID: nil,
                        subject: historicalSubject,
                        locator: nil
                    ),
                ],
                creatingJobID: foundation.job.jobID,
                creatingTaskID: foundation.task.identity.taskID,
                creatingCheckpointID: checkpoint.checkpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptID,
                classification: .acceptedCurrent,
                supersedesEvidenceID: nil,
                supersededByEvidenceID: nil,
                diagnostic: nil
            )
            let toolReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
                receiptID: toolReceiptID,
                jobID: foundation.job.jobID,
                taskID: foundation.task.identity.taskID,
                checkpointRevision: checkpoint.revision,
                requestIdentitySHA256: ReconstructionDatabaseTestFixtures.digest("a"),
                producer: producer,
                terminalState: .completed,
                outputEvidenceIDs: [historicalEvidenceID],
                diagnostic: nil
            )
            let state = try ReconstructionWorkspaceState(
                projects: [project],
                corpusManifests: [historicalManifest, currentManifest],
                evidence: [historicalEvidence],
                evidenceRelations: [],
                evidenceGaps: foundation.state.evidenceGaps,
                jobs: [job],
                tasks: [foundation.task],
                checkpoints: [checkpoint],
                toolReceipts: [toolReceipt],
                modelReceipts: []
            )
            return Self(
                state: state,
                project: project,
                historicalManifest: historicalManifest,
                currentManifest: currentManifest,
                historicalOccurrence: historicalOccurrence,
                currentOccurrence: foundation.occurrence,
                historicalEvidence: historicalEvidence,
                checkpoint: checkpoint,
                historicalBytes: historicalBytes,
                currentBytes: currentBytes
            )
        }
    }

    static func manifest(
        projectID: UUID,
        artifacts: [ReconstructionArtifactOccurrenceRecord],
        relations: [ReconstructionArtifactRelationRecord]
    ) throws -> ReconstructionCorpusManifest {
        let canonicalSHA256 = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: relations
        )
        return try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: relations,
            canonicalSHA256: canonicalSHA256
        )
    }

    func minimalState(
        project: ReconstructionProjectRecord,
        manifests: [ReconstructionCorpusManifest]
    ) throws -> ReconstructionWorkspaceState {
        try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: manifests,
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
    }

    func state(
        _ base: ReconstructionWorkspaceState,
        evidenceRelations: [ReconstructionEvidenceRelation]
    ) throws -> ReconstructionWorkspaceState {
        try ReconstructionWorkspaceState(
            schemaVersion: base.schemaVersion,
            projects: base.projects,
            corpusManifests: base.corpusManifests,
            evidence: base.evidence,
            evidenceRelations: evidenceRelations,
            evidenceGaps: base.evidenceGaps,
            jobs: base.jobs,
            tasks: base.tasks,
            checkpoints: base.checkpoints,
            toolReceipts: base.toolReceipts,
            modelReceipts: base.modelReceipts
        )
    }
}

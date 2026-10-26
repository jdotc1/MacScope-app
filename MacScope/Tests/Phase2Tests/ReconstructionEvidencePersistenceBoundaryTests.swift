import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionEvidencePersistenceBoundaryTests: XCTestCase {
    func testEveryRegisteredOperationPassesPackageAndDatabaseAdmission() throws {
        XCTAssertEqual(ReconstructionOperationID.allCases.count, 19)
        // This fixture publishes generic tool-receipt JSON. Durable source operations use
        // dedicated authenticated graphs, exercised by source package and commit tests.
        let ordinaryToolOperations = ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }
        XCTAssertEqual(ordinaryToolOperations.count, 16)

        let databaseFixture = try DatabaseFixture.make()
        let fixture = try Fixture(binaryID: databaseFixture.binaryID)
        for operation in ordinaryToolOperations {
            let state = try fixture.singleEvidenceState(
                operationID: operation.rawValue,
                gapOperationID: operation.rawValue
            )

            XCTAssertNoThrow(
                try ReconstructionPackageCodec.encode(state),
                operation.rawValue
            )
            try databaseFixture.database.replaceReconstructionState(
                workspaceID: databaseFixture.workspaceUUID,
                state: state
            )
            XCTAssertEqual(
                try databaseFixture.database.loadReconstructionState(
                    workspaceID: databaseFixture.workspaceUUID
                ),
                state,
                operation.rawValue
            )
        }
    }

    func testUnknownEvidenceAndGapOperationsFailPackageDatabaseReplaceAndDatabaseLoad() throws {
        let unknownOperationID = "reconstruction.unregistered.persistence-boundary"

        for location in UnknownOperationLocation.allCases {
            let admissionDatabase = try DatabaseFixture.make()
            let admissionFixture = try Fixture(binaryID: admissionDatabase.binaryID)
            let invalidState = try location.state(
                fixture: admissionFixture,
                unknownOperationID: unknownOperationID
            )
            assertSharedAdmissionRejects(
                invalidState,
                database: admissionDatabase,
                scenario: "unknown \(location.rawValue) operation"
            )

            let loadDatabase = try DatabaseFixture.make()
            let loadFixture = try Fixture(binaryID: loadDatabase.binaryID)
            let validState = try loadFixture.singleEvidenceState()
            let invalidLoadState = try location.state(
                fixture: loadFixture,
                unknownOperationID: unknownOperationID
            )
            try loadDatabase.database.replaceReconstructionState(
                workspaceID: loadDatabase.workspaceUUID,
                state: validState
            )
            try replaceAuthoritativeStateForLoadTest(
                invalidLoadState,
                location: location,
                in: loadDatabase.database
            )

            XCTAssertThrowsError(
                try loadDatabase.database.loadReconstructionState(
                    workspaceID: loadDatabase.workspaceUUID
                ),
                "Authoritative database load accepted unknown \(location.rawValue) operation"
            ) { error in
                guard case WorkspaceDatabase.DatabaseError.reconstructionStateInvalid = error else {
                    return XCTFail("Expected reconstructionStateInvalid, got \(error)")
                }
            }
        }
    }

    func testSharedAdmissionRecomputesEvidenceIntegrityAndRequiresAcceptorStructure() throws {
        typealias StateFactory = (Fixture) throws -> ReconstructionWorkspaceState
        let scenarios: [(String, StateFactory)] = [
            ("producer canonical SHA", { fixture in
                try fixture.singleEvidenceState(
                    producerCanonicalSHA256: Fixture.rawSHA256(
                        Data("tampered producer digest".utf8)
                    )
                )
            }),
            ("gap canonical SHA", { fixture in
                try fixture.singleEvidenceState(
                    gapCanonicalSHA256: Fixture.rawSHA256(Data("tampered gap digest".utf8))
                )
            }),
            ("producer operation identity", { fixture in
                try fixture.singleEvidenceState(
                    operationID: ReconstructionOperationID.functionReview.rawValue,
                    producerOperationID: ReconstructionOperationID.evidenceGet.rawValue
                )
            }),
            ("producer durable identity", { fixture in
                try fixture.singleEvidenceState(macScopeBuildIdentity: "build-pid=4217")
            }),
            ("payload digest", { fixture in
                try fixture.singleEvidenceState(
                    payloadSHA256: Fixture.rawSHA256(Data("different payload".utf8))
                )
            }),
            ("missing citation", { fixture in
                try fixture.singleEvidenceState(citationKind: .none)
            }),
            ("locator-only citation", { fixture in
                try fixture.singleEvidenceState(citationKind: .locatorOnly)
            }),
            ("missing receipt provenance", { fixture in
                try fixture.singleEvidenceState(includesToolReceipt: false)
            }),
        ]

        for (name, makeState) in scenarios {
            let databaseFixture = try DatabaseFixture.make()
            let fixture = try Fixture(binaryID: databaseFixture.binaryID)
            assertSharedAdmissionRejects(
                try makeState(fixture),
                database: databaseFixture,
                scenario: name
            )
        }
    }

    func testSharedAdmissionRequiresOneSuccessorAndExactPointerRelationAgreement() throws {
        for validShape in [
            SupersessionShape.immutablePredecessor,
            .agreeingLegacyReversePointer,
        ] {
            let fixture = try Fixture(binaryID: Fixture.uuid(900))
            XCTAssertNoThrow(
                try ReconstructionPackageCodec.encode(fixture.supersessionState(validShape)),
                validShape.rawValue
            )
        }

        for invalidShape in [
            SupersessionShape.twoSuccessors,
            .missingSuccessorRelation,
            .wrongLegacyReversePointer,
        ] {
            let fixture = try Fixture(binaryID: Fixture.uuid(900))
            XCTAssertThrowsError(
                try ReconstructionPackageCodec.encode(fixture.supersessionState(invalidShape)),
                invalidShape.rawValue
            ) { error in
                guard case ReconstructionPackageValidationError.stateGraphInvalid = error else {
                    return XCTFail("Expected stateGraphInvalid, got \(error)")
                }
            }
        }
    }

    func testAcceptorOutputWithDistinctCitationLocatorsPassesPackageAdmission() throws {
        let fixture = try Fixture(binaryID: Fixture.uuid(900))
        let producer = try fixture.producerIdentity()
        let citations = [
            try ReconstructionEvidenceCitation(
                citationID: Fixture.uuid(601),
                sourceEvidenceID: nil,
                subject: fixture.subject,
                locator: "function-entry"
            ),
            try ReconstructionEvidenceCitation(
                citationID: Fixture.uuid(602),
                sourceEvidenceID: nil,
                subject: fixture.subject,
                locator: "function-exit"
            ),
        ]
        let accepted = try fixture.acceptor.validate(
            fixture.candidate(producer: producer, citations: citations),
            against: fixture.authorityCut(producer: producer)
        )
        let state = try fixture.packageState(
            evidence: [accepted],
            evidenceRelations: [],
            producer: producer
        )

        let encoded = try ReconstructionPackageCodec.encode(state)
        XCTAssertEqual(
            try ReconstructionPackageCodec.decode(
                descriptor: encoded.descriptor,
                corpusData: encoded.corpusData,
                evidenceData: encoded.evidenceData,
                checkpointData: encoded.checkpointData
            ),
            state
        )
    }

    func testAcceptorSupersessionWithImmutablePredecessorPassesPackageAndProjection() throws {
        let fixture = try Fixture(binaryID: Fixture.uuid(900))
        let producer = try fixture.producerIdentity()
        let predecessor = try fixture.evidenceRecord(
            id: Fixture.predecessorID,
            producer: producer
        )
        let successor = try fixture.acceptor.validate(
            fixture.candidate(
                evidenceID: Fixture.firstSuccessorID,
                producer: producer,
                supersedesEvidenceID: predecessor.evidenceID
            ),
            against: fixture.authorityCut(producer: producer, evidence: [predecessor])
        )
        let relation = ReconstructionEvidenceRelation(
            relationID: Fixture.uuid(21),
            kind: .supersedes,
            sourceEvidenceID: successor.evidenceID,
            targetEvidenceID: predecessor.evidenceID
        )
        let state = try fixture.packageState(
            evidence: [predecessor, successor],
            evidenceRelations: [relation],
            producer: producer
        )

        XCTAssertNil(predecessor.supersededByEvidenceID)
        XCTAssertNoThrow(try ReconstructionPackageCodec.encode(state))
        let projection = try ReconstructionEvidenceProjector().project(
            records: state.evidence,
            relations: state.evidenceRelations,
            authority: fixture.freshnessAuthority()
        )
        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        XCTAssertEqual(classifications[predecessor.evidenceID], .superseded)
        XCTAssertEqual(classifications[successor.evidenceID], .acceptedCurrent)
        XCTAssertNil(predecessor.supersededByEvidenceID)
    }

    func testPackageRejectsEvidenceSelfEdgeThatProjectorRejects() throws {
        let fixture = try Fixture(binaryID: Fixture.uuid(900))
        let producer = try fixture.producerIdentity()
        let record = try fixture.evidenceRecord(id: Fixture.evidenceID, producer: producer)
        let relation = ReconstructionEvidenceRelation(
            relationID: Fixture.uuid(31),
            kind: .supports,
            sourceEvidenceID: record.evidenceID,
            targetEvidenceID: record.evidenceID
        )
        let state = try fixture.packageState(
            evidence: [record],
            evidenceRelations: [relation],
            producer: producer
        )

        XCTAssertThrowsError(
            try ReconstructionEvidenceProjector().validateRelationGraph(
                records: state.evidence,
                relations: state.evidenceRelations
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionEvidenceProjectionError, .selfRelation)
        }
        assertPackageRejects(state, scenario: "evidence self relation")
    }

    func testPackageRejectsDependencyCyclesThatProjectorRejects() throws {
        for kind in [
            ReconstructionEvidenceRelationKind.derivedFrom,
            .summarizes,
            .supersedes,
        ] {
            let fixture = try Fixture(binaryID: Fixture.uuid(900))
            let producer = try fixture.producerIdentity()
            let first = try fixture.evidenceRecord(
                id: Fixture.firstSuccessorID,
                producer: producer,
                supersedesEvidenceID: kind == .supersedes ? Fixture.secondSuccessorID : nil,
                supersededByEvidenceID: kind == .supersedes ? Fixture.secondSuccessorID : nil
            )
            let second = try fixture.evidenceRecord(
                id: Fixture.secondSuccessorID,
                producer: producer,
                supersedesEvidenceID: kind == .supersedes ? Fixture.firstSuccessorID : nil,
                supersededByEvidenceID: kind == .supersedes ? Fixture.firstSuccessorID : nil
            )
            let relations = [
                ReconstructionEvidenceRelation(
                    relationID: Fixture.uuid(41),
                    kind: kind,
                    sourceEvidenceID: first.evidenceID,
                    targetEvidenceID: second.evidenceID
                ),
                ReconstructionEvidenceRelation(
                    relationID: Fixture.uuid(42),
                    kind: kind,
                    sourceEvidenceID: second.evidenceID,
                    targetEvidenceID: first.evidenceID
                ),
            ]
            let state = try fixture.packageState(
                evidence: [first, second],
                evidenceRelations: relations,
                producer: producer
            )

            XCTAssertThrowsError(
                try ReconstructionEvidenceProjector().validateRelationGraph(
                    records: state.evidence,
                    relations: state.evidenceRelations
                ),
                kind.rawValue
            ) {
                XCTAssertEqual($0 as? ReconstructionEvidenceProjectionError, .cycleDetected)
            }
            assertPackageRejects(state, scenario: "\(kind.rawValue) cycle")
        }
    }

    func testRemovingAndRestoringLiveImageDoesNotRewriteAcceptedTerminalClassification() throws {
        let databaseFixture = try DatabaseFixture.make()
        let fixture = try Fixture(binaryID: databaseFixture.binaryID)
        let authoritativeState = try fixture.singleEvidenceState()
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: authoritativeState
        )

        var withoutLiveImage = databaseFixture.snapshot
        withoutLiveImage.removeImage(in: .primary)
        let removed = try databaseFixture.replaceWorkspace(snapshot: withoutLiveImage)

        XCTAssertEqual(removed.reconstructionState, authoritativeState)
        XCTAssertEqual(
            try databaseFixture.database.loadReconstructionState(
                workspaceID: databaseFixture.workspaceUUID
            ),
            authoritativeState,
            "Removing a live image must not persist a derived stale classification"
        )

        let restored = try databaseFixture.replaceWorkspace(snapshot: databaseFixture.snapshot)
        XCTAssertEqual(restored.reconstructionState, authoritativeState)

        let projection = try ReconstructionEvidenceProjector().project(
            records: restored.reconstructionState.evidence,
            relations: restored.reconstructionState.evidenceRelations,
            authority: try fixture.freshnessAuthority()
        )
        XCTAssertEqual(
            projection.currentRecords.map(\.evidenceID),
            authoritativeState.evidence.map(\.evidenceID),
            "The same immutable authority must project the accepted record current again"
        )
    }
}

private extension ReconstructionEvidencePersistenceBoundaryTests {
    enum UnknownOperationLocation: String, CaseIterable {
        case evidence
        case gap

        func state(
            fixture: Fixture,
            unknownOperationID: String
        ) throws -> ReconstructionWorkspaceState {
            switch self {
            case .evidence:
                return try fixture.singleEvidenceState(
                    operationID: unknownOperationID,
                    producerOperationID: unknownOperationID
                )
            case .gap:
                return try fixture.singleEvidenceState(gapOperationID: unknownOperationID)
            }
        }
    }

    enum CitationKind {
        case subject
        case none
        case locatorOnly
    }

    enum SupersessionShape: String {
        case immutablePredecessor
        case agreeingLegacyReversePointer
        case twoSuccessors
        case missingSuccessorRelation
        case wrongLegacyReversePointer
    }

    func assertPackageRejects(
        _ state: ReconstructionWorkspaceState,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.encode(state),
            "Package admission accepted \(scenario)",
            file: file,
            line: line
        ) { error in
            guard case ReconstructionPackageValidationError.stateGraphInvalid = error else {
                return XCTFail(
                    "Expected stateGraphInvalid for \(scenario), got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    func assertSharedAdmissionRejects(
        _ state: ReconstructionWorkspaceState,
        database: DatabaseFixture,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.encode(state),
            "Package admission accepted \(scenario)",
            file: file,
            line: line
        ) { error in
            guard case ReconstructionPackageValidationError.stateGraphInvalid = error else {
                return XCTFail(
                    "Expected stateGraphInvalid for \(scenario), got \(error)",
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertThrowsError(
            try database.database.replaceReconstructionState(
                workspaceID: database.workspaceUUID,
                state: state
            ),
            "Database admission accepted \(scenario)",
            file: file,
            line: line
        ) { error in
            guard case WorkspaceDatabase.DatabaseError.reconstructionStateInvalid = error else {
                return XCTFail(
                    "Expected reconstructionStateInvalid for \(scenario), got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    func replaceAuthoritativeStateForLoadTest(
        _ state: ReconstructionWorkspaceState,
        location: UnknownOperationLocation,
        in database: WorkspaceDatabase
    ) throws {
        let stateBlob = blobLiteral(try ReconstructionCanonicalJSON.encode(state))
        var statements = [
            "UPDATE reconstruction_projects SET state_json = \(stateBlob);",
        ]
        if location == .evidence {
            let evidence = try XCTUnwrap(state.evidence.first)
            let receipt = try XCTUnwrap(state.toolReceipts.first)
            statements.append(
                "UPDATE reconstruction_evidence SET record_json = \(blobLiteral(try ReconstructionCanonicalJSON.encode(evidence)));"
            )
            statements.append(
                "UPDATE reconstruction_tool_receipts SET canonical_sha256 = '\(receipt.canonicalSHA256)', record_json = \(blobLiteral(try ReconstructionCanonicalJSON.encode(receipt)));"
            )
        } else {
            let checkpoint = try XCTUnwrap(state.checkpoints.first)
            statements.append(
                "UPDATE reconstruction_checkpoints SET record_json = \(blobLiteral(try ReconstructionCanonicalJSON.encode(checkpoint)));"
            )
        }
        try database.executeRawForTesting(statements.joined(separator: "\n"))
    }

    func blobLiteral(_ data: Data) -> String {
        "X'\(data.map { String(format: "%02x", $0) }.joined())'"
    }

    struct DatabaseFixture {
        let database: WorkspaceDatabase
        let workspaceUUID: UUID
        let workspaceRowID: Int64
        let binaryID: UUID
        let snapshot: WorkspaceSnapshot

        static func make() throws -> Self {
            let database = try WorkspaceDatabase.inMemory()
            try database.applySchema()
            let snapshot = AnalysisEngine.previewSnapshot()
            let workspaceUUID = Fixture.uuid(900)
            let workspace = try database.saveSnapshot(
                workspaceUUID: workspaceUUID,
                workspaceName: "Evidence persistence boundary",
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_900_000_000)
            )
            return Self(
                database: database,
                workspaceUUID: workspaceUUID,
                workspaceRowID: try XCTUnwrap(workspace.id),
                binaryID: try XCTUnwrap(snapshot.binaries.first?.id),
                snapshot: snapshot
            )
        }

        func replaceWorkspace(snapshot: WorkspaceSnapshot) throws
            -> WorkspaceDatabase.PersistedWorkspace {
            try database.replaceWorkspaceState(
                workspaceID: workspaceRowID,
                workspaceName: "Evidence persistence boundary",
                snapshot: snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                focusedImageSlot: .primary,
                now: Date(timeIntervalSince1970: 1_900_000_100)
            )
        }
    }

    struct Fixture {
        static let projectID = uuid(4)
        static let occurrenceID = ReconstructionArtifactOccurrenceID(rawValue: uuid(3))
        static let jobID = uuid(6)
        static let taskID = uuid(7)
        static let checkpointID = uuid(8)
        static let toolReceiptID = uuid(9)
        static let evidenceID = uuid(1)
        static let predecessorID = uuid(11)
        static let firstSuccessorID = uuid(12)
        static let secondSuccessorID = uuid(14)
        static let gapID = uuid(15)
        static let payload = Data("evidence".utf8)

        let artifact: ReconstructionArtifactCoordinate
        let image: ReconstructionImageCoordinate
        let subject: ReconstructionSubjectCoordinate
        let occurrence: ReconstructionArtifactOccurrenceRecord
        let manifest: ReconstructionCorpusManifest
        let project: ReconstructionProjectRecord

        init(binaryID: UUID) throws {
            let artifactBytes = Data("artifact-current".utf8)
            let contentIdentity = try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: Self.rawSHA256(artifactBytes),
                byteCount: UInt64(artifactBytes.count)
            )
            let artifact = ReconstructionArtifactCoordinate(
                occurrenceID: Self.occurrenceID,
                contentIdentity: contentIdentity
            )
            let image = try ReconstructionImageCoordinate(
                artifact: artifact,
                image: ReconstructionImageBinding(
                    binaryID: binaryID,
                    imageSlot: .primary,
                    selectedSliceIndex: 0,
                    architecture: .arm64,
                    machOIdentity: nil
                ),
                analysisFingerprintSHA256: Self.rawSHA256(Data("analysis-current".utf8))
            )
            let occurrence = try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: artifact.occurrenceID,
                contentIdentity: artifact.contentIdentity,
                kind: .machOImage,
                roles: [.primaryTarget],
                executableMode: true,
                originalName: "fixture",
                diagnostic: nil
            )
            let manifest = try Self.manifest(artifacts: [occurrence])

            self.artifact = artifact
            self.image = image
            subject = .image(image)
            self.occurrence = occurrence
            self.manifest = manifest
            project = try ReconstructionProjectRecord(
                projectID: Self.projectID,
                name: "Evidence persistence boundary",
                currentCorpusManifestSHA256: manifest.canonicalSHA256
            )
        }

        func singleEvidenceState(
            operationID: String = ReconstructionOperationID.functionReview.rawValue,
            gapOperationID: String = ReconstructionOperationID.functionReview.rawValue,
            producerOperationID: String? = nil,
            macScopeBuildIdentity: String = "macscope-build-acceptor-boundary",
            producerCanonicalSHA256: String? = nil,
            gapCanonicalSHA256: String? = nil,
            payloadSHA256: String? = nil,
            citationKind: CitationKind = .subject,
            includesToolReceipt: Bool = true
        ) throws -> ReconstructionWorkspaceState {
            let producer = try Self.producer(
                operationID: producerOperationID ?? operationID,
                macScopeBuildIdentity: macScopeBuildIdentity,
                canonicalSHA256: producerCanonicalSHA256
            )
            let record = try evidence(
                id: Self.evidenceID,
                operationID: operationID,
                producer: producer,
                payloadSHA256: payloadSHA256,
                citationKind: citationKind,
                toolReceiptID: includesToolReceipt ? Self.toolReceiptID : nil,
                supersedesEvidenceID: nil,
                supersededByEvidenceID: nil
            )
            let gap = try evidenceGap(
                operationID: gapOperationID,
                canonicalSHA256: gapCanonicalSHA256
            )
            return try state(
                evidence: [record],
                evidenceRelations: [],
                gaps: [gap],
                receiptProducer: producer,
                includesToolReceipt: includesToolReceipt
            )
        }

        func supersessionState(
            _ shape: SupersessionShape
        ) throws -> ReconstructionWorkspaceState {
            let operationID = ReconstructionOperationID.functionReview.rawValue
            let producer = try Self.producer(operationID: operationID)
            let predecessorSuccessorID: UUID?
            switch shape {
            case .agreeingLegacyReversePointer:
                predecessorSuccessorID = Self.firstSuccessorID
            case .immutablePredecessor, .twoSuccessors, .missingSuccessorRelation:
                predecessorSuccessorID = nil
            case .wrongLegacyReversePointer:
                predecessorSuccessorID = Self.secondSuccessorID
            }
            let predecessor = try evidence(
                id: Self.predecessorID,
                operationID: operationID,
                producer: producer,
                citationKind: .subject,
                toolReceiptID: Self.toolReceiptID,
                supersedesEvidenceID: nil,
                supersededByEvidenceID: predecessorSuccessorID
            )
            let firstSuccessor = try evidence(
                id: Self.firstSuccessorID,
                operationID: operationID,
                producer: producer,
                citationKind: .subject,
                toolReceiptID: Self.toolReceiptID,
                supersedesEvidenceID: Self.predecessorID,
                supersededByEvidenceID: nil
            )
            var evidence = [predecessor, firstSuccessor]
            var relations: [ReconstructionEvidenceRelation] = shape == .missingSuccessorRelation
                ? []
                : [
                    ReconstructionEvidenceRelation(
                        relationID: Self.uuid(21),
                        kind: .supersedes,
                        sourceEvidenceID: Self.firstSuccessorID,
                        targetEvidenceID: Self.predecessorID
                    ),
                ]
            if shape == .twoSuccessors {
                evidence.append(try self.evidence(
                    id: Self.secondSuccessorID,
                    operationID: operationID,
                    producer: producer,
                    citationKind: .subject,
                    toolReceiptID: Self.toolReceiptID,
                    supersedesEvidenceID: Self.predecessorID,
                    supersededByEvidenceID: nil
                ))
                relations.append(ReconstructionEvidenceRelation(
                    relationID: Self.uuid(22),
                    kind: .supersedes,
                    sourceEvidenceID: Self.secondSuccessorID,
                    targetEvidenceID: Self.predecessorID
                ))
            } else if shape == .wrongLegacyReversePointer {
                evidence.append(try self.evidence(
                    id: Self.secondSuccessorID,
                    operationID: operationID,
                    producer: producer,
                    citationKind: .subject,
                    toolReceiptID: Self.toolReceiptID,
                    supersedesEvidenceID: nil,
                    supersededByEvidenceID: nil
                ))
            }
            return try state(
                evidence: evidence,
                evidenceRelations: relations,
                gaps: [try evidenceGap(operationID: operationID)],
                receiptProducer: producer,
                includesToolReceipt: true
            )
        }

        var acceptor: ReconstructionEvidenceAcceptor {
            ReconstructionEvidenceAcceptor(
                maximumPayloadBytes: 1_024,
                maximumDiagnosticUTF8Bytes: 1_024
            )
        }

        func producerIdentity() throws -> ReconstructionProducerIdentity {
            try Self.producer(operationID: ReconstructionOperationID.functionReview.rawValue)
        }

        func candidate(
            evidenceID: UUID = Self.evidenceID,
            producer: ReconstructionProducerIdentity,
            citations: [ReconstructionEvidenceCitation]? = nil,
            supersedesEvidenceID: UUID? = nil
        ) throws -> ReconstructionEvidenceCandidate {
            try ReconstructionEvidenceCandidate(
                evidenceID: evidenceID,
                subject: subject,
                operationID: .functionReview,
                payloadKind: .structuredJSON,
                payload: Self.payload,
                payloadByteCount: UInt64(Self.payload.count),
                payloadSHA256: Self.rawSHA256(Self.payload),
                facetDependencies: [],
                producer: producer,
                citations: try citations ?? [
                    ReconstructionEvidenceCitation(
                        citationID: Self.citationID(for: evidenceID),
                        sourceEvidenceID: nil,
                        subject: subject,
                        locator: nil
                    ),
                ],
                creatingJobID: Self.jobID,
                creatingTaskID: Self.taskID,
                creatingCheckpointID: Self.checkpointID,
                modelReceiptID: nil,
                toolReceiptID: Self.toolReceiptID,
                supersedesEvidenceID: supersedesEvidenceID,
                diagnostic: nil
            )
        }

        func authorityCut(
            producer: ReconstructionProducerIdentity,
            evidence: [ReconstructionEvidenceRecord] = []
        ) -> ReconstructionAuthorityCut {
            ReconstructionAuthorityCut(
                corpusManifest: manifest,
                authoritativeSubjects: [subject],
                facetFingerprints: [:],
                creatingJobID: Self.jobID,
                creatingTaskID: Self.taskID,
                creatingCheckpointID: Self.checkpointID,
                checkpointRevision: 0,
                operationID: .functionReview,
                toolReceiptID: Self.toolReceiptID,
                modelReceiptID: nil,
                producer: producer,
                evidence: evidence
            )
        }

        func evidenceRecord(
            id: UUID,
            producer: ReconstructionProducerIdentity,
            supersedesEvidenceID: UUID? = nil,
            supersededByEvidenceID: UUID? = nil
        ) throws -> ReconstructionEvidenceRecord {
            try evidence(
                id: id,
                operationID: ReconstructionOperationID.functionReview.rawValue,
                producer: producer,
                citationKind: .subject,
                toolReceiptID: Self.toolReceiptID,
                supersedesEvidenceID: supersedesEvidenceID,
                supersededByEvidenceID: supersededByEvidenceID
            )
        }

        func packageState(
            evidence: [ReconstructionEvidenceRecord],
            evidenceRelations: [ReconstructionEvidenceRelation],
            producer: ReconstructionProducerIdentity
        ) throws -> ReconstructionWorkspaceState {
            try state(
                evidence: evidence,
                evidenceRelations: evidenceRelations,
                gaps: [],
                receiptProducer: producer,
                includesToolReceipt: true
            )
        }

        func freshnessAuthority() throws -> ReconstructionFreshnessAuthority {
            try ReconstructionFreshnessAuthority(
                corpusManifestSHA256: manifest.canonicalSHA256,
                currentArtifacts: [artifact],
                currentImages: [image],
                currentFacetFingerprints: [:]
            )
        }

        private func evidence(
            id: UUID,
            operationID: String,
            producer: ReconstructionProducerIdentity,
            payloadSHA256: String? = nil,
            citationKind: CitationKind,
            toolReceiptID: UUID?,
            supersedesEvidenceID: UUID?,
            supersededByEvidenceID: UUID?
        ) throws -> ReconstructionEvidenceRecord {
            let citations: [ReconstructionEvidenceCitation]
            switch citationKind {
            case .subject:
                citations = [
                    try ReconstructionEvidenceCitation(
                        citationID: Self.citationID(for: id),
                        sourceEvidenceID: nil,
                        subject: subject,
                        locator: nil
                    ),
                ]
            case .none:
                citations = []
            case .locatorOnly:
                citations = [
                    try ReconstructionEvidenceCitation(
                        citationID: Self.citationID(for: id),
                        sourceEvidenceID: nil,
                        subject: nil,
                        locator: "fixture-only"
                    ),
                ]
            }
            return try ReconstructionEvidenceRecord(
                evidenceID: id,
                subject: subject,
                operationID: operationID,
                payloadKind: .structuredJSON,
                payload: Self.payload,
                payloadByteCount: UInt64(Self.payload.count),
                payloadSHA256: payloadSHA256 ?? Self.rawSHA256(Self.payload),
                facetDependencies: [],
                producer: producer,
                citations: citations,
                creatingJobID: Self.jobID,
                creatingTaskID: Self.taskID,
                creatingCheckpointID: Self.checkpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptID,
                classification: .acceptedCurrent,
                supersedesEvidenceID: supersedesEvidenceID,
                supersededByEvidenceID: supersededByEvidenceID,
                diagnostic: nil
            )
        }

        private func evidenceGap(
            operationID: String,
            canonicalSHA256: String? = nil
        ) throws -> ReconstructionEvidenceGap {
            let reason = ReconstructionDiagnostic.sanitizing("missing review evidence")
            let preimage = GapDigestPreimage(
                schemaVersion: ReconstructionEvidenceGap.schemaVersion,
                gapID: Self.gapID,
                subject: subject,
                operationID: operationID,
                reason: reason
            )
            return try ReconstructionEvidenceGap(
                gapID: preimage.gapID,
                subject: preimage.subject,
                operationID: preimage.operationID,
                reason: preimage.reason,
                canonicalSHA256: try canonicalSHA256
                    ?? ReconstructionCanonicalJSON.sha256(of: preimage)
            )
        }

        private func state(
            evidence: [ReconstructionEvidenceRecord],
            evidenceRelations: [ReconstructionEvidenceRelation],
            gaps: [ReconstructionEvidenceGap],
            receiptProducer: ReconstructionProducerIdentity,
            includesToolReceipt: Bool
        ) throws -> ReconstructionWorkspaceState {
            let taskIdentity = try ReconstructionTaskIdentity.make(
                taskID: Self.taskID,
                jobID: Self.jobID,
                kind: .retrieveEvidence,
                subject: subject,
                dependencyTaskIDs: [],
                operationContractIdentity: ReconstructionOperationID.functionReview.rawValue
            )
            let task = ReconstructionTaskRecord(
                identity: taskIdentity,
                state: .completed,
                diagnostic: nil
            )
            let toolReceipts: [ReconstructionToolReceipt]
            if includesToolReceipt {
                toolReceipts = [try Self.toolReceipt(
                    producer: receiptProducer,
                    outputEvidenceIDs: evidence.map(\.evidenceID)
                )]
            } else {
                toolReceipts = []
            }
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: Self.checkpointID,
                jobID: Self.jobID,
                revision: 0,
                parentCheckpointID: nil,
                parentCheckpointSHA256: nil,
                corpusManifestSHA256: manifest.canonicalSHA256,
                evidenceFrontierSHA256: Self.rawSHA256(Data("evidence-frontier".utf8)),
                pendingTaskIDs: [],
                runningTaskIDs: [],
                completedTaskIDs: [Self.taskID],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                    .canonicalSHA256(for: gaps),
                modelReceiptIDs: [],
                toolReceiptIDs: toolReceipts.map(\.receiptID),
                coordinatorState: .retrieving,
                terminalReason: nil
            )
            let objective = "Preserve accepted reconstruction evidence"
            let job = try ReconstructionJobRecord(
                jobID: Self.jobID,
                reconstructionProjectID: Self.projectID,
                objective: objective,
                objectiveSHA256: Self.rawSHA256(Data(objective.utf8)),
                creationCorpusManifestSHA256: manifest.canonicalSHA256,
                state: .retrieving,
                currentCheckpointID: checkpoint.checkpointID,
                terminalReason: nil,
                budget: try ReconstructionJobBudget(
                    maxRounds: 2,
                    maxTasks: 8,
                    maxEvidenceRecords: 16,
                    maxEncodedBytes: 65_536
                )
            )
            return try ReconstructionWorkspaceState(
                projects: [project],
                corpusManifests: [manifest],
                evidence: evidence,
                evidenceRelations: evidenceRelations,
                evidenceGaps: gaps,
                jobs: [job],
                tasks: [task],
                checkpoints: [checkpoint],
                toolReceipts: toolReceipts,
                modelReceipts: []
            )
        }

        private static func producer(
            operationID: String,
            macScopeBuildIdentity: String = "macscope-build-acceptor-boundary",
            canonicalSHA256: String? = nil
        ) throws -> ReconstructionProducerIdentity {
            let preimage = ProducerDigestPreimage(
                schemaVersion: ReconstructionProducerIdentity.schemaVersion,
                macScopeBuildIdentity: macScopeBuildIdentity,
                macScopeSourceIdentity: "source-build-acceptor-boundary",
                operationIdentity: operationID,
                registryIdentity: "reconstruction-operation-registry-v1",
                protocolIdentity: "reconstruction-evidence-v1",
                nativeProviderIdentity: "macscope-native",
                nativeCapabilityIdentities: ["function-review-v1"],
                modelKey: nil,
                endpointOrigin: nil,
                observedModelInventorySHA256: nil,
                observedConfigurationSHA256: nil,
                toolchainIdentity: "xcode-27-swift-6"
            )
            return try ReconstructionProducerIdentity(
                schemaVersion: preimage.schemaVersion,
                macScopeBuildIdentity: preimage.macScopeBuildIdentity,
                macScopeSourceIdentity: preimage.macScopeSourceIdentity,
                operationIdentity: preimage.operationIdentity,
                registryIdentity: preimage.registryIdentity,
                protocolIdentity: preimage.protocolIdentity,
                nativeProviderIdentity: preimage.nativeProviderIdentity,
                nativeCapabilityIdentities: preimage.nativeCapabilityIdentities,
                modelKey: preimage.modelKey,
                endpointOrigin: preimage.endpointOrigin,
                observedModelInventorySHA256: preimage.observedModelInventorySHA256,
                observedConfigurationSHA256: preimage.observedConfigurationSHA256,
                toolchainIdentity: preimage.toolchainIdentity,
                canonicalSHA256: try canonicalSHA256
                    ?? ReconstructionCanonicalJSON.sha256(of: preimage)
            )
        }

        private static func manifest(
            artifacts: [ReconstructionArtifactOccurrenceRecord]
        ) throws -> ReconstructionCorpusManifest {
            let preimage = CorpusManifestDigestPreimage(
                schemaVersion: ReconstructionCorpusManifest.schemaVersion,
                reconstructionProjectID: Self.projectID,
                artifacts: artifacts.sorted {
                    $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString
                },
                relations: []
            )
            return try ReconstructionCorpusManifest(
                schemaVersion: preimage.schemaVersion,
                reconstructionProjectID: preimage.reconstructionProjectID,
                artifacts: preimage.artifacts,
                relations: preimage.relations,
                canonicalSHA256: ReconstructionCanonicalJSON.sha256(of: preimage)
            )
        }

        private static func toolReceipt(
            producer: ReconstructionProducerIdentity,
            outputEvidenceIDs: [UUID]
        ) throws -> ReconstructionToolReceipt {
            try ReconstructionReceiptAuthority.makeToolReceipt(
                receiptID: Self.toolReceiptID,
                jobID: Self.jobID,
                taskID: Self.taskID,
                checkpointRevision: 0,
                requestIdentitySHA256: Self.rawSHA256(Data("tool-request".utf8)),
                producer: producer,
                terminalState: .completed,
                outputEvidenceIDs: outputEvidenceIDs,
                diagnostic: nil
            )
        }

        static func rawSHA256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        static func uuid(_ value: Int) -> UUID {
            UUID(
                uuidString: String(
                    format: "52000000-0000-0000-0000-%012d",
                    value
                )
            )!
        }

        private static func citationID(for evidenceID: UUID) -> UUID {
            uuid(500 + (Int(evidenceID.uuidString.suffix(4)) ?? 0))
        }

        private struct ProducerDigestPreimage: Encodable {
            let schemaVersion: Int
            let macScopeBuildIdentity: String
            let macScopeSourceIdentity: String
            let operationIdentity: String
            let registryIdentity: String
            let protocolIdentity: String
            let nativeProviderIdentity: String?
            let nativeCapabilityIdentities: [String]
            let modelKey: String?
            let endpointOrigin: String?
            let observedModelInventorySHA256: String?
            let observedConfigurationSHA256: String?
            let toolchainIdentity: String?
        }

        private struct CorpusManifestDigestPreimage: Encodable {
            let schemaVersion: Int
            let reconstructionProjectID: UUID
            let artifacts: [ReconstructionArtifactOccurrenceRecord]
            let relations: [ReconstructionArtifactRelationRecord]
        }

        private struct GapDigestPreimage: Encodable {
            let schemaVersion: Int
            let gapID: UUID
            let subject: ReconstructionSubjectCoordinate
            let operationID: String
            let reason: ReconstructionDiagnostic
        }

    }
}

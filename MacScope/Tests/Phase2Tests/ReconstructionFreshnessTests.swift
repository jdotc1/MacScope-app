import Foundation
import XCTest
@testable import MacScope

final class ReconstructionFreshnessTests: XCTestCase {
    func testContentReplacementProjectsStaleArtifactWithoutMutatingDurableRecord() throws {
        let occurrenceID = occurrence(1)
        let historicalArtifact = try artifact(
            occurrenceID: occurrenceID,
            contentDigest: digest("a")
        )
        let replacementArtifact = try artifact(
            occurrenceID: occurrenceID,
            contentDigest: digest("b")
        )
        let record = try evidence(
            id: id(101),
            subject: .artifact(historicalArtifact),
            classification: .acceptedCurrent
        )
        let originalPayload = record.payload
        let authority = try freshnessAuthority(
            currentArtifacts: [replacementArtifact],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [record],
            relations: [],
            authority: authority
        )

        let projected = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(projected.record.evidenceID, id(101))
        XCTAssertEqual(projected.classification, .staleArtifact)
        XCTAssertEqual(projected.record.payload, originalPayload)
        XCTAssertEqual(record.classification, .acceptedCurrent)
        XCTAssertEqual(record.subject, .artifact(historicalArtifact))
    }

    func testExactImageAndFacetFingerprintsRemainCurrent() throws {
        let artifact = try artifact(occurrenceID: occurrence(2), contentDigest: digest("a"))
        let function = try function(artifact: artifact, fingerprint: digest("c"), start: 0x1000)
        let subject = ReconstructionSubjectCoordinate.function(function)
        let record = try evidence(
            id: id(102),
            subject: subject,
            classification: .acceptedCurrent,
            facets: [
                try ReconstructionFacetDependency(
                    facetIdentity: "control-flow.v1",
                    fingerprintSHA256: digest("d")
                )
            ]
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [try imageCoordinate(for: function)],
            currentFacetFingerprints: [subject: ["control-flow.v1": digest("d")]]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [record],
            relations: [],
            authority: authority
        )

        XCTAssertEqual(projection.records.map(\.classification), [.acceptedCurrent])
        XCTAssertEqual(projection.currentRecords.map(\.evidenceID), [id(102)])
    }

    func testFacetAuthorityRequiresExactStoredDependencyKeySet() throws {
        let artifact = try artifact(occurrenceID: occurrence(14), contentDigest: digest("a"))
        let function = try function(artifact: artifact, fingerprint: digest("c"), start: 0x1400)
        let subject = ReconstructionSubjectCoordinate.function(function)
        let missingRequiredFacet = try evidence(
            id: id(901),
            subject: subject,
            facets: [
                try ReconstructionFacetDependency(
                    facetIdentity: "control-flow.v1",
                    fingerprintSHA256: digest("d")
                )
            ]
        )
        let exactFacetSet = try evidence(
            id: id(902),
            subject: subject,
            facets: [
                try ReconstructionFacetDependency(
                    facetIdentity: "control-flow.v1",
                    fingerprintSHA256: digest("d")
                ),
                try ReconstructionFacetDependency(
                    facetIdentity: "types.v1",
                    fingerprintSHA256: digest("e")
                ),
            ]
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [try imageCoordinate(for: function)],
            currentFacetFingerprints: [
                subject: [
                    "control-flow.v1": digest("d"),
                    "types.v1": digest("e"),
                ]
            ]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [missingRequiredFacet, exactFacetSet],
            relations: [],
            authority: authority
        )

        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        XCTAssertEqual(classifications[missingRequiredFacet.evidenceID], .staleAnalysis)
        XCTAssertEqual(classifications[exactFacetSet.evidenceID], .acceptedCurrent)
        XCTAssertEqual(projection.currentRecords.map(\.evidenceID), [exactFacetSet.evidenceID])
    }

    func testMatchingAuthorityDoesNotPromoteAcceptedHistoricalEvidenceBackToCurrent() throws {
        let artifact = try artifact(occurrenceID: occurrence(10), contentDigest: digest("a"))
        let record = try evidence(
            id: id(105),
            subject: .artifact(artifact),
            classification: .acceptedHistorical
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [record],
            relations: [],
            authority: authority
        )

        XCTAssertEqual(projection.records.map(\.classification), [.acceptedHistorical])
        XCTAssertTrue(projection.currentRecords.isEmpty)
        XCTAssertEqual(record.classification, .acceptedHistorical)
    }

    func testFreshnessProjectionPreservesNonacceptedTerminalClassifications() throws {
        let artifact = try artifact(occurrenceID: occurrence(17), contentDigest: digest("a"))
        let classifications: [ReconstructionEvidenceClassification] = [
            .unavailable,
            .failed,
            .cancelled,
            .truncated,
        ]
        let records = try classifications.enumerated().map { index, classification in
            try evidence(
                id: id(930 + index),
                subject: .artifact(artifact),
                classification: classification
            )
        }
        let authority = try freshnessAuthority(
            currentArtifacts: [],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: records,
            relations: [],
            authority: authority
        )
        let projectedByEvidenceID = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })

        for record in records {
            XCTAssertEqual(
                projectedByEvidenceID[record.evidenceID],
                record.classification
            )
        }
    }

    func testSupersessionClassificationPrecedesArtifactStaleness() throws {
        let artifact = try artifact(occurrenceID: occurrence(18), contentDigest: digest("a"))
        let predecessorID = id(940)
        let successorID = id(941)
        let predecessor = try evidence(
            id: predecessorID,
            subject: .artifact(artifact)
        )
        let successor = try evidence(
            id: successorID,
            subject: .artifact(artifact),
            supersedes: predecessorID
        )
        let supersedes = relation(
            id: id(942),
            kind: .supersedes,
            source: successorID,
            target: predecessorID
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [predecessor, successor],
            relations: [supersedes],
            authority: authority
        )
        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })

        XCTAssertEqual(classifications[predecessorID], .superseded)
        XCTAssertEqual(classifications[successorID], .staleArtifact)
    }

    func testImageFingerprintDriftProjectsStaleAnalysisWithoutChangingStoredSubject() throws {
        let artifact = try artifact(occurrenceID: occurrence(3), contentDigest: digest("a"))
        let historicalImage = try image(artifact: artifact, fingerprint: digest("c"))
        let currentImage = try image(artifact: artifact, fingerprint: digest("d"))
        let record = try evidence(
            id: id(103),
            subject: .image(historicalImage),
            classification: .acceptedCurrent
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [currentImage],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [record],
            relations: [],
            authority: authority
        )

        XCTAssertEqual(projection.records.map(\.classification), [.staleAnalysis])
        XCTAssertEqual(record.classification, .acceptedCurrent)
        XCTAssertEqual(record.subject, .image(historicalImage))
    }

    func testFacetFingerprintDriftProjectsStaleAnalysisWithoutRewritingPayload() throws {
        let artifact = try artifact(occurrenceID: occurrence(4), contentDigest: digest("a"))
        let function = try function(artifact: artifact, fingerprint: digest("c"), start: 0x2000)
        let subject = ReconstructionSubjectCoordinate.function(function)
        let record = try evidence(
            id: id(104),
            subject: subject,
            classification: .acceptedCurrent,
            payload: Data("immutable payload".utf8),
            facets: [
                try ReconstructionFacetDependency(
                    facetIdentity: "types.v1",
                    fingerprintSHA256: digest("d")
                )
            ]
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [try imageCoordinate(for: function)],
            currentFacetFingerprints: [subject: ["types.v1": digest("e")]]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [record],
            relations: [],
            authority: authority
        )

        let projected = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(projected.classification, .staleAnalysis)
        XCTAssertEqual(projected.record.payload, Data("immutable payload".utf8))
        XCTAssertEqual(record.classification, .acceptedCurrent)
    }

    func testSupersessionSelectsSuccessorAndRetainsOriginalAndContradiction() throws {
        let artifact = try artifact(occurrenceID: occurrence(5), contentDigest: digest("a"))
        let originalID = id(201)
        let successorID = id(202)
        let contradictionID = id(203)
        let original = try evidence(
            id: originalID,
            subject: .artifact(artifact),
            classification: .acceptedCurrent,
            supersededBy: successorID
        )
        let successor = try evidence(
            id: successorID,
            subject: .artifact(artifact),
            classification: .acceptedCurrent,
            supersedes: originalID
        )
        let contradiction = try evidence(
            id: contradictionID,
            subject: .artifact(artifact),
            classification: .acceptedCurrent
        )
        let supersedes = relation(
            id: id(301),
            kind: .supersedes,
            source: successorID,
            target: originalID
        )
        let contradicts = relation(
            id: id(302),
            kind: .contradicts,
            source: contradictionID,
            target: successorID
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [contradiction, original, successor],
            relations: [contradicts, supersedes],
            authority: authority
        )

        let classificationsByEvidenceID = Dictionary(
            uniqueKeysWithValues: projection.records.map {
                ($0.record.evidenceID, $0.classification)
            }
        )
        XCTAssertEqual(projection.records.count, 3)
        XCTAssertEqual(classificationsByEvidenceID[originalID], .superseded)
        XCTAssertEqual(classificationsByEvidenceID[successorID], .acceptedCurrent)
        XCTAssertEqual(classificationsByEvidenceID[contradictionID], .acceptedCurrent)
        XCTAssertEqual(
            Set(projection.currentRecords.map(\.evidenceID)),
            Set([successorID, contradictionID])
        )
        XCTAssertEqual(Set(projection.relations), Set([supersedes, contradicts]))
        XCTAssertEqual(original.classification, .acceptedCurrent)
        XCTAssertEqual(original.supersededByEvidenceID, successorID)
    }

    func testSupersessionDerivesPredecessorClassificationWithoutReversePointer() throws {
        let artifact = try artifact(occurrenceID: occurrence(13), contentDigest: digest("a"))
        let predecessorID = id(801)
        let successorID = id(802)
        let predecessorWithoutReciprocalPointer = try evidence(
            id: predecessorID,
            subject: .artifact(artifact)
        )
        let successor = try evidence(
            id: successorID,
            subject: .artifact(artifact),
            supersedes: predecessorID
        )
        let supersedes = relation(
            id: id(803),
            kind: .supersedes,
            source: successorID,
            target: predecessorID
        )
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [predecessorWithoutReciprocalPointer, successor],
            relations: [supersedes],
            authority: authority
        )
        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })

        XCTAssertEqual(classifications[predecessorID], .superseded)
        XCTAssertEqual(classifications[successorID], .acceptedCurrent)
        XCTAssertNil(predecessorWithoutReciprocalPointer.supersededByEvidenceID)
    }

    func testMultipleSupersedingSuccessorsForOnePredecessorFailClosed() throws {
        let artifact = try artifact(occurrenceID: occurrence(14), contentDigest: digest("a"))
        let predecessorID = id(811)
        let firstSuccessorID = id(812)
        let secondSuccessorID = id(813)
        let predecessor = try evidence(
            id: predecessorID,
            subject: .artifact(artifact),
            supersededBy: firstSuccessorID
        )
        let firstSuccessor = try evidence(
            id: firstSuccessorID,
            subject: .artifact(artifact),
            supersedes: predecessorID
        )
        let secondSuccessor = try evidence(
            id: secondSuccessorID,
            subject: .artifact(artifact),
            supersedes: predecessorID
        )
        let relations = [
            relation(
                id: id(814),
                kind: .supersedes,
                source: firstSuccessorID,
                target: predecessorID
            ),
            relation(
                id: id(815),
                kind: .supersedes,
                source: secondSuccessorID,
                target: predecessorID
            ),
        ]
        let authority = try freshnessAuthority(
            currentArtifacts: [artifact],
            currentImages: [],
            currentFacetFingerprints: [:]
        )

        XCTAssertThrowsError(
            try ReconstructionEvidenceProjector().project(
                records: [predecessor, firstSuccessor, secondSuccessor],
                relations: relations,
                authority: authority
            )
        ) {
            XCTAssertEqual(
                $0 as? ReconstructionEvidenceProjectionError,
                .inconsistentSupersession
            )
        }
    }

    func testCompatibilityProjectionRetainsHistoricalSubjectWithCompleteCheckpointFrontier() throws {
        let historicalArtifact = try artifact(
            occurrenceID: occurrence(15),
            contentDigest: digest("a")
        )
        let currentArtifact = try artifact(
            occurrenceID: occurrence(16),
            contentDigest: digest("b")
        )
        let historicalCheckpointID = id(821)
        let currentCheckpointID = id(822)
        let historical = try evidence(
            id: id(823),
            subject: .artifact(historicalArtifact),
            checkpointID: historicalCheckpointID
        )
        let current = try evidence(
            id: id(824),
            subject: .artifact(currentArtifact),
            checkpointID: currentCheckpointID
        )
        let projectID = id(825)
        let currentOccurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: currentArtifact.occurrenceID,
            contentIdentity: currentArtifact.contentIdentity,
            kind: .opaque,
            roles: [.primaryTarget],
            executableMode: false,
            originalName: "current.bin",
            diagnostic: nil
        )
        let manifestDigest = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: [currentOccurrence],
            relations: []
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [currentOccurrence],
            relations: [],
            canonicalSHA256: manifestDigest
        )
        let authority = ReconstructionAuthorityCut(
            corpusManifest: manifest,
            authoritativeSubjects: [historical.subject, current.subject],
            facetFingerprints: [:],
            creatingJobID: id(910),
            creatingTaskID: id(911),
            creatingCheckpointID: currentCheckpointID,
            checkpointRevision: 7,
            operationID: .functionReview,
            toolReceiptID: id(913),
            modelReceiptID: nil,
            producer: try producer(),
            evidence: [historical, current]
        )

        XCTAssertThrowsError(
            try ReconstructionEvidenceProjector().project(
                records: [historical, current],
                relations: [],
                gaps: [],
                against: authority
            )
        ) {
            XCTAssertEqual(
                $0 as? ReconstructionEvidenceProjectionError,
                .incompleteCheckpointRevisions
            )
        }

        let cut = try ReconstructionEvidenceProjector().project(
            records: [historical, current],
            relations: [],
            gaps: [],
            against: authority,
            checkpointRevisionsByID: [
                historicalCheckpointID: 2,
                currentCheckpointID: 7,
            ]
        )

        XCTAssertEqual(
            cut.projectedClassificationsByEvidenceID[historical.evidenceID],
            .staleArtifact
        )
        XCTAssertEqual(
            cut.projectedClassificationsByEvidenceID[current.evidenceID],
            .acceptedCurrent
        )
        XCTAssertEqual(
            cut.checkpointRevisionsByID,
            [historicalCheckpointID: 2, currentCheckpointID: 7]
        )
    }

    func testDerivedSummaryAndSupersessionRelationsRejectCycles() throws {
        let artifact = try artifact(occurrenceID: occurrence(6), contentDigest: digest("a"))
        let first = try evidence(id: id(401), subject: .artifact(artifact))
        let second = try evidence(id: id(402), subject: .artifact(artifact))
        let projector = ReconstructionEvidenceProjector()

        for kind in [
            ReconstructionEvidenceRelationKind.derivedFrom,
            .summarizes,
            .supersedes,
        ] {
            let relations = [
                relation(id: id(411), kind: kind, source: first.evidenceID, target: second.evidenceID),
                relation(id: id(412), kind: kind, source: second.evidenceID, target: first.evidenceID),
            ]

            XCTAssertThrowsError(
                try projector.validateRelationGraph(records: [first, second], relations: relations),
                "\(kind) cycles must fail closed"
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionEvidenceProjectionError,
                    ReconstructionEvidenceProjectionError.cycleDetected
                )
            }
        }
    }

    func testSupportContradictionAndComparisonRelationsAllowCycles() throws {
        let artifact = try artifact(occurrenceID: occurrence(7), contentDigest: digest("a"))
        let first = try evidence(id: id(501), subject: .artifact(artifact))
        let second = try evidence(id: id(502), subject: .artifact(artifact))
        let projector = ReconstructionEvidenceProjector()

        for kind in [
            ReconstructionEvidenceRelationKind.supports,
            .contradicts,
            .compares,
        ] {
            let relations = [
                relation(id: id(511), kind: kind, source: first.evidenceID, target: second.evidenceID),
                relation(id: id(512), kind: kind, source: second.evidenceID, target: first.evidenceID),
            ]

            XCTAssertNoThrow(
                try projector.validateRelationGraph(records: [first, second], relations: relations),
                "\(kind) is not a DAG edge"
            )
        }
    }

    func testResolvesGapIsExcludedFromEvidenceDAGAndGapAndResolverAreRetained() throws {
        let artifact = try artifact(occurrenceID: occurrence(8), contentDigest: digest("a"))
        let resolver = try evidence(id: id(601), subject: .artifact(artifact))
        let gap = try ReconstructionEvidenceGap(
            gapID: id(602),
            subject: .artifact(artifact),
            operationID: "reconstruction.function.review",
            reason: .sanitizing("missing review evidence"),
            canonicalSHA256: digest("c")
        )
        let resolvesGap = relation(
            id: id(603),
            kind: .resolvesGap,
            source: resolver.evidenceID,
            target: gap.gapID
        )

        XCTAssertNoThrow(
            try ReconstructionEvidenceProjector().validateRelationGraph(
                records: [resolver],
                relations: [resolvesGap]
            )
        )
        let projections = try ReconstructionGapProjector().project(
            gaps: [gap],
            records: [resolver],
            relations: [resolvesGap]
        )

        let projected = try XCTUnwrap(projections.first)
        XCTAssertEqual(projected.gap, gap)
        XCTAssertTrue(projected.isResolved)
        XCTAssertEqual(projected.resolvingEvidence.map(\.evidenceID), [resolver.evidenceID])
        XCTAssertEqual(projected.currentResolvingEvidence.map(\.evidenceID), [resolver.evidenceID])
    }

    func testEqualUUIDAcrossEvidenceAndGapIdentityDomainsResolvesGap() throws {
        let artifact = try artifact(occurrenceID: occurrence(17), contentDigest: digest("a"))
        let sharedIdentity = id(604)
        let resolver = try evidence(id: sharedIdentity, subject: .artifact(artifact))
        let gap = try ReconstructionEvidenceGap(
            gapID: sharedIdentity,
            subject: .artifact(artifact),
            operationID: ReconstructionOperationID.functionReview.rawValue,
            reason: .sanitizing("missing review evidence"),
            canonicalSHA256: digest("c")
        )
        let resolvesGap = relation(
            id: id(605),
            kind: .resolvesGap,
            source: sharedIdentity,
            target: sharedIdentity
        )

        XCTAssertNoThrow(
            try ReconstructionEvidenceProjector().validateRelationGraph(
                records: [resolver],
                relations: [resolvesGap]
            )
        )
        let projections = try ReconstructionGapProjector().project(
            gaps: [gap],
            records: [resolver],
            relations: [resolvesGap]
        )

        let projected = try XCTUnwrap(projections.first)
        XCTAssertEqual(projected.gap.gapID, sharedIdentity)
        XCTAssertEqual(projected.resolvingEvidence.map(\.evidenceID), [sharedIdentity])
        XCTAssertTrue(projected.isResolved)
    }

    func testCutProjectionRejectsResolutionTargetingMissingGap() throws {
        let artifact = try artifact(occurrenceID: occurrence(19), contentDigest: digest("a"))
        let checkpointID = id(820)
        let resolver = try evidence(
            id: id(821),
            subject: .artifact(artifact),
            checkpointID: checkpointID
        )
        let invalidResolution = relation(
            id: id(822),
            kind: .resolvesGap,
            source: resolver.evidenceID,
            target: id(823)
        )
        let authority = try projectionAuthority(
            artifact: artifact,
            records: [resolver],
            checkpointID: checkpointID
        )

        XCTAssertThrowsError(
            try ReconstructionEvidenceProjector().project(
                records: [resolver],
                relations: [invalidResolution],
                gaps: [],
                against: authority,
                checkpointRevisionsByID: [checkpointID: 0]
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionEvidenceProjectionError,
                .relationEndpointMissing
            )
        }
    }

    func testCutProjectionAllowsEqualUUIDAcrossEvidenceAndGapDomains() throws {
        let artifact = try artifact(occurrenceID: occurrence(20), contentDigest: digest("a"))
        let checkpointID = id(824)
        let sharedID = id(825)
        let resolver = try evidence(
            id: sharedID,
            subject: .artifact(artifact),
            checkpointID: checkpointID
        )
        let gap = try ReconstructionEvidenceGap(
            gapID: sharedID,
            subject: resolver.subject,
            operationID: resolver.operationID,
            reason: .sanitizing("missing exact evidence"),
            canonicalSHA256: digest("c")
        )
        let resolution = relation(
            id: id(826),
            kind: .resolvesGap,
            source: sharedID,
            target: sharedID
        )
        let authority = try projectionAuthority(
            artifact: artifact,
            records: [resolver],
            checkpointID: checkpointID
        )

        let cut = try ReconstructionEvidenceProjector().project(
            records: [resolver],
            relations: [resolution],
            gaps: [gap],
            against: authority,
            checkpointRevisionsByID: [checkpointID: 0]
        )

        XCTAssertEqual(cut.records.map(\.evidenceID), [sharedID])
        XCTAssertEqual(cut.relations, [resolution])
        XCTAssertEqual(cut.gaps, [gap])
    }

    func testEqualEvidenceEndpointsRemainSelfRelationsForEvidenceKinds() throws {
        let artifact = try artifact(occurrenceID: occurrence(18), contentDigest: digest("a"))
        let record = try evidence(id: id(606), subject: .artifact(artifact))
        let projector = ReconstructionEvidenceProjector()
        let evidenceRelationKinds = ReconstructionEvidenceRelationKind.allCases.filter {
            $0 != .resolvesGap
        }

        for (index, kind) in evidenceRelationKinds.enumerated() {
            let selfRelation = relation(
                id: id(610 + index),
                kind: kind,
                source: record.evidenceID,
                target: record.evidenceID
            )
            XCTAssertThrowsError(
                try projector.validateRelationGraph(
                    records: [record],
                    relations: [selfRelation]
                ),
                "\(kind) must retain evidence self-relation rejection"
            ) {
                XCTAssertEqual($0 as? ReconstructionEvidenceProjectionError, .selfRelation)
            }
        }
    }

    func testGapProjectionRetainsSupersededResolverWhileSelectingCurrentResolver() throws {
        let artifact = try artifact(occurrenceID: occurrence(9), contentDigest: digest("a"))
        let historicalID = id(701)
        let currentID = id(702)
        let historical = try evidence(
            id: historicalID,
            subject: .artifact(artifact),
            operationID: ReconstructionOperationID.evidenceGet.rawValue,
            classification: .superseded,
            supersededBy: currentID
        )
        let current = try evidence(
            id: currentID,
            subject: .artifact(artifact),
            operationID: ReconstructionOperationID.evidenceGet.rawValue,
            classification: .acceptedCurrent,
            supersedes: historicalID
        )
        let gap = try ReconstructionEvidenceGap(
            gapID: id(703),
            subject: .artifact(artifact),
            operationID: "reconstruction.evidence.get",
            reason: .sanitizing("exact evidence was unavailable"),
            canonicalSHA256: digest("d")
        )
        let relations = [
            relation(id: id(704), kind: .resolvesGap, source: historicalID, target: gap.gapID),
            relation(id: id(705), kind: .resolvesGap, source: currentID, target: gap.gapID),
            relation(id: id(706), kind: .supersedes, source: currentID, target: historicalID),
        ]

        let projections = try ReconstructionGapProjector().project(
            gaps: [gap],
            records: [current, historical],
            relations: relations
        )

        let projected = try XCTUnwrap(projections.first)
        XCTAssertEqual(projected.gap.gapID, id(703))
        XCTAssertEqual(
            Set(projected.resolvingEvidence.map(\.evidenceID)),
            Set([historicalID, currentID])
        )
        XCTAssertEqual(projected.currentResolvingEvidence.map(\.evidenceID), [currentID])
        XCTAssertTrue(projected.isResolved)
    }

    func testGapProjectionRejectsEvidenceRecordAsResolutionTarget() throws {
        let artifact = try artifact(occurrenceID: occurrence(11), contentDigest: digest("a"))
        let resolver = try evidence(id: id(711), subject: .artifact(artifact))
        let mistakenTarget = try evidence(id: id(712), subject: .artifact(artifact))
        let gap = try ReconstructionEvidenceGap(
            gapID: id(713),
            subject: .artifact(artifact),
            operationID: ReconstructionOperationID.functionReview.rawValue,
            reason: .sanitizing("missing review evidence"),
            canonicalSHA256: digest("e")
        )
        let invalidResolution = relation(
            id: id(714),
            kind: .resolvesGap,
            source: resolver.evidenceID,
            target: mistakenTarget.evidenceID
        )

        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [mistakenTarget, resolver],
                relations: [invalidResolution]
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionGapProjectionError,
                ReconstructionGapProjectionError.missingResolutionTarget
            )
        }
    }

    func testGapProjectionRejectsResolutionTargetingMissingGap() throws {
        let artifact = try artifact(occurrenceID: occurrence(12), contentDigest: digest("a"))
        let resolver = try evidence(id: id(721), subject: .artifact(artifact))
        let invalidResolution = relation(
            id: id(722),
            kind: .resolvesGap,
            source: resolver.evidenceID,
            target: id(723)
        )

        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [],
                records: [resolver],
                relations: [invalidResolution]
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionGapProjectionError,
                ReconstructionGapProjectionError.missingResolutionTarget
            )
        }
    }
}

private func freshnessAuthority(
    currentArtifacts: [ReconstructionArtifactCoordinate],
    currentImages: [ReconstructionImageCoordinate],
    currentFacetFingerprints: [ReconstructionSubjectCoordinate: [String: String]]
) throws -> ReconstructionFreshnessAuthority {
    try ReconstructionFreshnessAuthority(
        corpusManifestSHA256: digest("f"),
        currentArtifacts: currentArtifacts,
        currentImages: currentImages,
        currentFacetFingerprints: currentFacetFingerprints
    )
}

private func projectionAuthority(
    artifact: ReconstructionArtifactCoordinate,
    records: [ReconstructionEvidenceRecord],
    checkpointID: UUID
) throws -> ReconstructionAuthorityCut {
    let projectID = id(980)
    let occurrence = try ReconstructionArtifactOccurrenceRecord(
        occurrenceID: artifact.occurrenceID,
        contentIdentity: artifact.contentIdentity,
        kind: .opaque,
        roles: [.primaryTarget],
        executableMode: false,
        originalName: "fixture.bin",
        diagnostic: nil
    )
    let manifestDigest = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
        reconstructionProjectID: projectID,
        artifacts: [occurrence],
        relations: []
    )
    let manifest = try ReconstructionCorpusManifest(
        reconstructionProjectID: projectID,
        artifacts: [occurrence],
        relations: [],
        canonicalSHA256: manifestDigest
    )
    return ReconstructionAuthorityCut(
        corpusManifest: manifest,
        authoritativeSubjects: records.map(\.subject),
        facetFingerprints: [:],
        creatingJobID: id(910),
        creatingTaskID: id(911),
        creatingCheckpointID: checkpointID,
        checkpointRevision: 0,
        operationID: .functionReview,
        toolReceiptID: id(913),
        modelReceiptID: nil,
        producer: try producer(),
        evidence: records
    )
}

private func artifact(
    occurrenceID: ReconstructionArtifactOccurrenceID,
    contentDigest: String
) throws -> ReconstructionArtifactCoordinate {
    ReconstructionArtifactCoordinate(
        occurrenceID: occurrenceID,
        contentIdentity: try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: contentDigest,
            byteCount: 64
        )
    )
}

private func image(
    artifact: ReconstructionArtifactCoordinate,
    fingerprint: String
) throws -> ReconstructionImageCoordinate {
    try ReconstructionImageCoordinate(
        artifact: artifact,
        image: imageBinding(),
        analysisFingerprintSHA256: fingerprint
    )
}

private func function(
    artifact: ReconstructionArtifactCoordinate,
    fingerprint: String,
    start: UInt64
) throws -> ReconstructionFunctionCoordinate {
    try ReconstructionFunctionCoordinate(
        artifact: artifact,
        image: imageBinding(),
        analysisFingerprintSHA256: fingerprint,
        startAddress: start,
        endAddressExclusive: start + 0x40,
        boundarySchemaVersion: 1,
        functionUUIDHint: nil,
        symbolHint: nil
    )
}

private func imageCoordinate(
    for function: ReconstructionFunctionCoordinate
) throws -> ReconstructionImageCoordinate {
    try ReconstructionImageCoordinate(
        artifact: function.artifact,
        image: function.image,
        analysisFingerprintSHA256: function.analysisFingerprintSHA256
    )
}

private func imageBinding() -> ReconstructionImageBinding {
    ReconstructionImageBinding(
        binaryID: id(900),
        imageSlot: ImageSlot(rawValue: 1),
        selectedSliceIndex: 0,
        architecture: .arm64,
        machOIdentity: nil
    )
}

private func evidence(
    id evidenceID: UUID,
    subject: ReconstructionSubjectCoordinate,
    operationID: String = ReconstructionOperationID.functionReview.rawValue,
    classification: ReconstructionEvidenceClassification = .acceptedCurrent,
    payload: Data = Data("evidence".utf8),
    facets: [ReconstructionFacetDependency] = [],
    supersedes: UUID? = nil,
    supersededBy: UUID? = nil,
    checkpointID: UUID = id(912)
) throws -> ReconstructionEvidenceRecord {
    try ReconstructionEvidenceRecord(
        evidenceID: evidenceID,
        subject: subject,
        operationID: operationID,
        payloadKind: .structuredJSON,
        payload: payload,
        payloadByteCount: UInt64(payload.count),
        payloadSHA256: digest("e"),
        facetDependencies: facets,
        producer: producer(),
        citations: [],
        creatingJobID: id(910),
        creatingTaskID: id(911),
        creatingCheckpointID: checkpointID,
        modelReceiptID: nil,
        toolReceiptID: id(913),
        classification: classification,
        supersedesEvidenceID: supersedes,
        supersededByEvidenceID: supersededBy,
        diagnostic: nil
    )
}

private func producer() throws -> ReconstructionProducerIdentity {
    try ReconstructionProducerIdentity(
        macScopeBuildIdentity: "build-v1",
        macScopeSourceIdentity: "source-v1",
        operationIdentity: "reconstruction.function.review@1",
        registryIdentity: "reconstruction.v1",
        protocolIdentity: "reconstructionR1",
        canonicalSHA256: digest("b")
    )
}

private func relation(
    id relationID: UUID,
    kind: ReconstructionEvidenceRelationKind,
    source: UUID,
    target: UUID
) -> ReconstructionEvidenceRelation {
    ReconstructionEvidenceRelation(
        relationID: relationID,
        kind: kind,
        sourceEvidenceID: source,
        targetEvidenceID: target
    )
}

private func occurrence(_ value: Int) -> ReconstructionArtifactOccurrenceID {
    ReconstructionArtifactOccurrenceID(rawValue: id(value))
}

private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func id(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

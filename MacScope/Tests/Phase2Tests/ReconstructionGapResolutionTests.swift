import Foundation
import XCTest
@testable import MacScope

final class ReconstructionGapResolutionTests: XCTestCase {
    func testFreshnessReclassificationControlsResolutionWithoutMutatingDurableRecord() throws {
        let occurrenceID = gapResolutionOccurrence(1)
        let historicalArtifact = try gapResolutionArtifact(
            occurrenceID: occurrenceID,
            contentDigest: gapResolutionDigest("a")
        )
        let replacementArtifact = try gapResolutionArtifact(
            occurrenceID: occurrenceID,
            contentDigest: gapResolutionDigest("b")
        )
        let resolver = try gapResolutionEvidence(
            id: gapResolutionID(101),
            subject: .artifact(historicalArtifact),
            classification: .acceptedCurrent
        )
        let gap = try gapResolutionGap(
            id: gapResolutionID(201),
            subject: resolver.subject,
            digestCharacter: "c"
        )
        let resolution = gapResolutionRelation(
            id: gapResolutionID(301),
            source: resolver.evidenceID,
            target: gap.gapID
        )
        let authority = try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: gapResolutionDigest("d"),
            currentArtifacts: [replacementArtifact],
            currentImages: [],
            currentFacetFingerprints: [:]
        )
        let freshness = try ReconstructionEvidenceProjector().project(
            records: [resolver],
            relations: [resolution],
            authority: authority
        )
        let classifications = Dictionary(uniqueKeysWithValues: freshness.records.map {
            ($0.record.evidenceID, $0.classification)
        })

        let projection = try ReconstructionGapProjector().project(
            gaps: [gap],
            records: [resolver],
            relations: [resolution],
            projectedClassificationsByEvidenceID: classifications
        )

        XCTAssertEqual(classifications[resolver.evidenceID], .staleArtifact)
        XCTAssertEqual(resolver.classification, .acceptedCurrent)
        XCTAssertFalse(try XCTUnwrap(projection.first).isResolved)
        XCTAssertEqual(projection.unresolvedGaps, [gap])
        XCTAssertEqual(
            projection.unresolvedGapFrontierSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [gap])
        )
        XCTAssertEqual(projection.projectedClassificationsByEvidenceID, classifications)
    }

    func testProjectedClassificationAloneResolvesAndUnresolvesSameDurableRows() throws {
        let subject = try gapResolutionSubject(2)
        let resolver = try gapResolutionEvidence(
            id: gapResolutionID(102),
            subject: subject,
            classification: .acceptedHistorical
        )
        let gap = try gapResolutionGap(
            id: gapResolutionID(202),
            subject: subject,
            digestCharacter: "e"
        )
        let resolution = gapResolutionRelation(
            id: gapResolutionID(302),
            source: resolver.evidenceID,
            target: gap.gapID
        )
        let projector = ReconstructionGapProjector()

        let resolved = try projector.project(
            gaps: [gap],
            records: [resolver],
            relations: [resolution],
            projectedClassificationsByEvidenceID: [resolver.evidenceID: .acceptedCurrent]
        )
        let unresolved = try projector.project(
            gaps: [gap],
            records: [resolver],
            relations: [resolution],
            projectedClassificationsByEvidenceID: [resolver.evidenceID: .staleAnalysis]
        )

        XCTAssertTrue(try XCTUnwrap(resolved.first).isResolved)
        XCTAssertTrue(resolved.unresolvedGaps.isEmpty)
        XCTAssertEqual(
            resolved.unresolvedGapFrontierSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [])
        )
        XCTAssertFalse(try XCTUnwrap(unresolved.first).isResolved)
        XCTAssertEqual(unresolved.unresolvedGaps, [gap])
        XCTAssertEqual(
            unresolved.unresolvedGapFrontierSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [gap])
        )
        XCTAssertNotEqual(
            resolved.unresolvedGapFrontierSHA256,
            unresolved.unresolvedGapFrontierSHA256
        )
        XCTAssertEqual(resolver.classification, .acceptedHistorical)
    }

    func testMultipleResolverHistoryIsRetainedButOnlyProjectedCurrentResolverResolves() throws {
        let subject = try gapResolutionSubject(3)
        let superseded = try gapResolutionEvidence(
            id: gapResolutionID(103),
            subject: subject,
            classification: .acceptedCurrent
        )
        let stale = try gapResolutionEvidence(
            id: gapResolutionID(104),
            subject: subject,
            classification: .acceptedCurrent
        )
        let failed = try gapResolutionEvidence(
            id: gapResolutionID(105),
            subject: subject,
            classification: .failed
        )
        let current = try gapResolutionEvidence(
            id: gapResolutionID(106),
            subject: subject,
            classification: .acceptedHistorical
        )
        let gap = try gapResolutionGap(
            id: gapResolutionID(203),
            subject: subject,
            digestCharacter: "f"
        )
        let relations = [
            gapResolutionRelation(
                id: gapResolutionID(306),
                source: current.evidenceID,
                target: gap.gapID
            ),
            gapResolutionRelation(
                id: gapResolutionID(303),
                source: superseded.evidenceID,
                target: gap.gapID
            ),
            gapResolutionRelation(
                id: gapResolutionID(305),
                source: failed.evidenceID,
                target: gap.gapID
            ),
            gapResolutionRelation(
                id: gapResolutionID(304),
                source: stale.evidenceID,
                target: gap.gapID
            ),
        ]
        let classifications: [UUID: ReconstructionEvidenceClassification] = [
            superseded.evidenceID: .superseded,
            stale.evidenceID: .staleAnalysis,
            failed.evidenceID: .failed,
            current.evidenceID: .acceptedCurrent,
        ]

        let projection = try ReconstructionGapProjector().project(
            gaps: [gap],
            records: [current, failed, stale, superseded],
            relations: relations,
            projectedClassificationsByEvidenceID: classifications
        )

        let projected = try XCTUnwrap(projection.first)
        XCTAssertEqual(
            projected.resolvingEvidence.map(\.evidenceID),
            [superseded.evidenceID, stale.evidenceID, failed.evidenceID, current.evidenceID]
        )
        XCTAssertEqual(projected.currentResolvingEvidence.map(\.evidenceID), [current.evidenceID])
        XCTAssertTrue(projected.isResolved)
        XCTAssertEqual(projection.evidence.map(\.evidenceID), projected.resolvingEvidence.map(\.evidenceID))
        XCTAssertEqual(Set(projection.relations), Set(relations))
    }

    func testAcceptedCurrentResolverRequiresExactGapSubjectAndOperation() throws {
        let gapSubject = try gapResolutionSubject(4)
        let wrongSubject = try gapResolutionSubject(5)
        let subjectMismatch = try gapResolutionEvidence(
            id: gapResolutionID(107),
            subject: wrongSubject
        )
        let operationMismatch = try gapResolutionEvidence(
            id: gapResolutionID(108),
            subject: gapSubject,
            operationID: "reconstruction.evidence.get"
        )
        let gap = try gapResolutionGap(
            id: gapResolutionID(204),
            subject: gapSubject,
            digestCharacter: "1"
        )
        let relations = [
            gapResolutionRelation(
                id: gapResolutionID(307),
                source: subjectMismatch.evidenceID,
                target: gap.gapID
            ),
            gapResolutionRelation(
                id: gapResolutionID(308),
                source: operationMismatch.evidenceID,
                target: gap.gapID
            ),
        ]

        let projection = try ReconstructionGapProjector().project(
            gaps: [gap],
            records: [operationMismatch, subjectMismatch],
            relations: relations,
            projectedClassificationsByEvidenceID: [
                subjectMismatch.evidenceID: .acceptedCurrent,
                operationMismatch.evidenceID: .acceptedCurrent,
            ]
        )

        let projected = try XCTUnwrap(projection.first)
        XCTAssertEqual(
            projected.resolvingEvidence.map(\.evidenceID),
            [subjectMismatch.evidenceID, operationMismatch.evidenceID]
        )
        XCTAssertTrue(projected.currentResolvingEvidence.isEmpty)
        XCTAssertFalse(projected.isResolved)
        XCTAssertEqual(projection.unresolvedGaps, [gap])
    }

    func testProjectedClassificationKeysMustExactlyMatchEvidenceIDs() throws {
        let subject = try gapResolutionSubject(6)
        let resolver = try gapResolutionEvidence(id: gapResolutionID(109), subject: subject)
        let gap = try gapResolutionGap(
            id: gapResolutionID(205),
            subject: subject,
            digestCharacter: "2"
        )
        let resolution = gapResolutionRelation(
            id: gapResolutionID(309),
            source: resolver.evidenceID,
            target: gap.gapID
        )
        let invalidMaps: [[UUID: ReconstructionEvidenceClassification]] = [
            [:],
            [
                resolver.evidenceID: .acceptedCurrent,
                gapResolutionID(999): .acceptedCurrent,
            ],
        ]

        for classifications in invalidMaps {
            XCTAssertThrowsError(
                try ReconstructionGapProjector().project(
                    gaps: [gap],
                    records: [resolver],
                    relations: [resolution],
                    projectedClassificationsByEvidenceID: classifications
                )
            ) {
                XCTAssertEqual(
                    $0 as? ReconstructionGapProjectionError,
                    .projectedClassificationKeyMismatch
                )
            }
        }
    }

    func testMissingResolutionSourceAndTargetFailClosed() throws {
        let subject = try gapResolutionSubject(7)
        let resolver = try gapResolutionEvidence(id: gapResolutionID(110), subject: subject)
        let gap = try gapResolutionGap(
            id: gapResolutionID(206),
            subject: subject,
            digestCharacter: "3"
        )

        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [resolver],
                relations: [
                    gapResolutionRelation(
                        id: gapResolutionID(310),
                        source: gapResolutionID(998),
                        target: gap.gapID
                    )
                ],
                projectedClassificationsByEvidenceID: [resolver.evidenceID: .acceptedCurrent]
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionGapProjectionError, .missingResolutionSource)
        }

        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [resolver],
                relations: [
                    gapResolutionRelation(
                        id: gapResolutionID(311),
                        source: resolver.evidenceID,
                        target: gapResolutionID(997)
                    )
                ],
                projectedClassificationsByEvidenceID: [resolver.evidenceID: .acceptedCurrent]
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionGapProjectionError, .missingResolutionTarget)
        }
    }

    func testDuplicateInputIDsAndSemanticResolutionEdgesFailClosed() throws {
        let subject = try gapResolutionSubject(8)
        let resolver = try gapResolutionEvidence(id: gapResolutionID(111), subject: subject)
        let gap = try gapResolutionGap(
            id: gapResolutionID(207),
            subject: subject,
            digestCharacter: "4"
        )
        let resolution = gapResolutionRelation(
            id: gapResolutionID(312),
            source: resolver.evidenceID,
            target: gap.gapID
        )
        let classifications = [resolver.evidenceID: ReconstructionEvidenceClassification.acceptedCurrent]

        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap, gap],
                records: [resolver],
                relations: [resolution],
                projectedClassificationsByEvidenceID: classifications
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionGapProjectionError, .duplicateGapID)
        }
        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [resolver, resolver],
                relations: [resolution],
                projectedClassificationsByEvidenceID: classifications
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionGapProjectionError, .duplicateEvidenceID)
        }
        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [resolver],
                relations: [resolution, resolution],
                projectedClassificationsByEvidenceID: classifications
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionGapProjectionError, .duplicateRelationID)
        }
        XCTAssertThrowsError(
            try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [resolver],
                relations: [
                    resolution,
                    gapResolutionRelation(
                        id: gapResolutionID(313),
                        source: resolver.evidenceID,
                        target: gap.gapID
                    ),
                ],
                projectedClassificationsByEvidenceID: classifications
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionGapProjectionError, .duplicateResolutionEdge)
        }
    }

    func testDifferentResolversAndDifferentTargetsRemainDistinctCanonicalEdges() throws {
        let subject = try gapResolutionSubject(9)
        let firstResolver = try gapResolutionEvidence(id: gapResolutionID(112), subject: subject)
        let secondResolver = try gapResolutionEvidence(id: gapResolutionID(113), subject: subject)
        let firstGap = try gapResolutionGap(
            id: gapResolutionID(208),
            subject: subject,
            digestCharacter: "5"
        )
        let secondGap = try gapResolutionGap(
            id: gapResolutionID(209),
            subject: subject,
            digestCharacter: "6"
        )
        let relations = [
            gapResolutionRelation(
                id: gapResolutionID(314),
                source: firstResolver.evidenceID,
                target: firstGap.gapID
            ),
            gapResolutionRelation(
                id: gapResolutionID(315),
                source: secondResolver.evidenceID,
                target: firstGap.gapID
            ),
            gapResolutionRelation(
                id: gapResolutionID(316),
                source: firstResolver.evidenceID,
                target: secondGap.gapID
            ),
        ]

        let projection = try ReconstructionGapProjector().project(
            gaps: [secondGap, firstGap],
            records: [secondResolver, firstResolver],
            relations: relations,
            projectedClassificationsByEvidenceID: [
                firstResolver.evidenceID: .acceptedCurrent,
                secondResolver.evidenceID: .acceptedCurrent,
            ]
        )

        XCTAssertEqual(projection.gaps.map(\.gap.gapID), [firstGap.gapID, secondGap.gapID])
        XCTAssertEqual(projection.gaps[0].resolvingEvidence.count, 2)
        XCTAssertEqual(projection.gaps[1].resolvingEvidence.map(\.evidenceID), [firstResolver.evidenceID])
        XCTAssertTrue(projection.unresolvedGaps.isEmpty)
    }

    func testProjectionOrderingAndUnresolvedFrontierAreDeterministicAndRetainAllGaps() throws {
        let subject = try gapResolutionSubject(10)
        let resolver = try gapResolutionEvidence(id: gapResolutionID(114), subject: subject)
        let firstGap = try gapResolutionGap(
            id: gapResolutionID(210),
            subject: subject,
            digestCharacter: "7"
        )
        let resolvedGap = try gapResolutionGap(
            id: gapResolutionID(211),
            subject: subject,
            digestCharacter: "8"
        )
        let lastGap = try gapResolutionGap(
            id: gapResolutionID(212),
            subject: subject,
            digestCharacter: "9"
        )
        let resolution = gapResolutionRelation(
            id: gapResolutionID(317),
            source: resolver.evidenceID,
            target: resolvedGap.gapID
        )
        let expectedUnresolved = [firstGap, lastGap]
        let expectedDigest = try ReconstructionEvidenceGapFrontier.canonicalSHA256(
            for: expectedUnresolved
        )
        let projector = ReconstructionGapProjector()

        let forward = try projector.project(
            gaps: [lastGap, resolvedGap, firstGap],
            records: [resolver],
            relations: [resolution],
            projectedClassificationsByEvidenceID: [resolver.evidenceID: .acceptedCurrent]
        )
        let reversed = try projector.project(
            gaps: [firstGap, resolvedGap, lastGap],
            records: [resolver],
            relations: [resolution],
            projectedClassificationsByEvidenceID: [resolver.evidenceID: .acceptedCurrent]
        )

        XCTAssertEqual(forward.gaps.map(\.gap), [firstGap, resolvedGap, lastGap])
        XCTAssertEqual(forward.unresolvedGaps, expectedUnresolved)
        XCTAssertEqual(forward.unresolvedGapFrontierSHA256, expectedDigest)
        XCTAssertEqual(forward, reversed)
        XCTAssertNotEqual(
            forward.unresolvedGapFrontierSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(
                for: [firstGap, resolvedGap, lastGap]
            )
        )
        XCTAssertEqual(forward.gaps.count, 3, "resolved durable gaps remain in audit output")
        XCTAssertEqual(forward.evidence, [resolver])
        XCTAssertEqual(forward.relations, [resolution])
    }

    func testCancelledProjectionThrowsBeforePublishingHashedFrontier() async throws {
        let subject = try gapResolutionSubject(11)
        let resolver = try gapResolutionEvidence(id: gapResolutionID(115), subject: subject)
        let gap = try gapResolutionGap(
            id: gapResolutionID(213),
            subject: subject,
            digestCharacter: "0"
        )
        let resolution = gapResolutionRelation(
            id: gapResolutionID(318),
            source: resolver.evidenceID,
            target: gap.gapID
        )
        let projection = Task { () throws -> ReconstructionGapProjection in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReconstructionGapProjector().project(
                gaps: [gap],
                records: [resolver],
                relations: [resolution],
                projectedClassificationsByEvidenceID: [resolver.evidenceID: .acceptedCurrent]
            )
        }

        do {
            _ = try await projection.value
            XCTFail("A cancelled projection must not publish a frontier")
        } catch is CancellationError {
            // Expected: cancellation is observed by the pure projector.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}

private func gapResolutionArtifact(
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

private func gapResolutionSubject(_ value: Int) throws -> ReconstructionSubjectCoordinate {
    .artifact(
        try gapResolutionArtifact(
            occurrenceID: gapResolutionOccurrence(value),
            contentDigest: gapResolutionDigest("a")
        )
    )
}

private func gapResolutionEvidence(
    id evidenceID: UUID,
    subject: ReconstructionSubjectCoordinate,
    operationID: String = "reconstruction.function.review",
    classification: ReconstructionEvidenceClassification = .acceptedCurrent
) throws -> ReconstructionEvidenceRecord {
    let payload = Data("gap resolver".utf8)
    return try ReconstructionEvidenceRecord(
        evidenceID: evidenceID,
        subject: subject,
        operationID: operationID,
        payloadKind: .structuredJSON,
        payload: payload,
        payloadByteCount: UInt64(payload.count),
        payloadSHA256: gapResolutionDigest("b"),
        facetDependencies: [],
        producer: gapResolutionProducer(),
        citations: [],
        creatingJobID: gapResolutionID(901),
        creatingTaskID: gapResolutionID(902),
        creatingCheckpointID: gapResolutionID(903),
        modelReceiptID: nil,
        toolReceiptID: gapResolutionID(904),
        classification: classification,
        supersedesEvidenceID: nil,
        supersededByEvidenceID: nil,
        diagnostic: nil
    )
}

private func gapResolutionProducer() throws -> ReconstructionProducerIdentity {
    try ReconstructionProducerIdentity(
        macScopeBuildIdentity: "build-v1",
        macScopeSourceIdentity: "source-v1",
        operationIdentity: "reconstruction.function.review@1",
        registryIdentity: "reconstruction.v1",
        protocolIdentity: "reconstructionR1",
        canonicalSHA256: gapResolutionDigest("c")
    )
}

private func gapResolutionGap(
    id gapID: UUID,
    subject: ReconstructionSubjectCoordinate,
    operationID: String = "reconstruction.function.review",
    digestCharacter: Character
) throws -> ReconstructionEvidenceGap {
    try ReconstructionEvidenceGap(
        gapID: gapID,
        subject: subject,
        operationID: operationID,
        reason: .sanitizing("exact evidence is missing"),
        canonicalSHA256: gapResolutionDigest(digestCharacter)
    )
}

private func gapResolutionRelation(
    id relationID: UUID,
    source: UUID,
    target: UUID
) -> ReconstructionEvidenceRelation {
    ReconstructionEvidenceRelation(
        relationID: relationID,
        kind: .resolvesGap,
        sourceEvidenceID: source,
        targetEvidenceID: target
    )
}

private func gapResolutionOccurrence(_ value: Int) -> ReconstructionArtifactOccurrenceID {
    ReconstructionArtifactOccurrenceID(rawValue: gapResolutionID(value))
}

private func gapResolutionDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func gapResolutionID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

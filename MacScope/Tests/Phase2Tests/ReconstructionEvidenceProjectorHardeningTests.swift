import Foundation
import XCTest
@testable import MacScope

final class ReconstructionEvidenceProjectorHardeningTests: XCTestCase {
    func testLongCanonicalDependencyChainIsStackBoundedAndCycleStillFailsClosed() throws {
        let fixture = try hardeningDependencyChain(count: 16_384)
        let projector = ReconstructionEvidenceProjector()

        XCTAssertNoThrow(
            try projector.validateRelationGraph(
                records: fixture.records,
                relations: fixture.relations
            )
        )

        let closingEdge = ReconstructionEvidenceRelation(
            relationID: hardeningID(900_001),
            kind: .derivedFrom,
            sourceEvidenceID: fixture.records.last!.evidenceID,
            targetEvidenceID: fixture.records.first!.evidenceID
        )
        XCTAssertThrowsError(
            try projector.validateRelationGraph(
                records: fixture.records,
                relations: fixture.relations + [closingEdge]
            )
        ) {
            XCTAssertEqual(
                $0 as? ReconstructionEvidenceProjectionError,
                .cycleDetected
            )
        }
    }

    func testCancelledLongDependencyTraversalThrowsCancellationError() async throws {
        let fixture = try hardeningDependencyChain(count: 16_384)
        let validation = Task {
            try ReconstructionEvidenceProjector().validateRelationGraph(
                records: fixture.records,
                relations: fixture.relations
            )
        }
        validation.cancel()

        do {
            try await validation.value
            XCTFail("Cancelled relation traversal completed instead of observing cancellation")
        } catch is CancellationError {
            // Expected: the throwing traversal polls cooperative cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testFreshnessAuthorityRejectsConflictingFingerprintsForOneImageBinding() throws {
        let artifact = try hardeningArtifact(occurrence: 20)
        let first = try hardeningImage(artifact: artifact, fingerprint: hardeningDigest("b"))
        let conflicting = try hardeningImage(
            artifact: artifact,
            fingerprint: hardeningDigest("c")
        )

        XCTAssertThrowsError(
            try ReconstructionFreshnessAuthority(
                corpusManifestSHA256: hardeningDigest("f"),
                currentArtifacts: [artifact],
                currentImages: [first, conflicting],
                currentFacetFingerprints: [:]
            )
        ) {
            XCTAssertEqual(
                $0 as? ReconstructionValidationError,
                .duplicateValue(field: "freshness image bindings")
            )
        }
    }

    func testFunctionRequiresExactSubjectAuthorityAndAcceptsAuthorizedEmptyFacetMap() throws {
        let artifact = try hardeningArtifact(occurrence: 30)
        let historicalFunction = try hardeningFunction(
            artifact: artifact,
            fingerprint: hardeningDigest("c"),
            start: 0x1000
        )
        let currentFunction = try hardeningFunction(
            artifact: artifact,
            fingerprint: hardeningDigest("c"),
            start: 0x2000
        )
        let historical = try hardeningEvidence(
            id: hardeningID(30_001),
            subject: .function(historicalFunction)
        )
        let current = try hardeningEvidence(
            id: hardeningID(30_002),
            subject: .function(currentFunction)
        )
        let currentSubject = ReconstructionSubjectCoordinate.function(currentFunction)
        let authority = try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: hardeningDigest("f"),
            currentArtifacts: [artifact],
            currentImages: [try hardeningImageCoordinate(for: currentFunction)],
            currentFacetFingerprints: [currentSubject: [:]]
        )

        let projection = try ReconstructionEvidenceProjector().project(
            records: [current, historical],
            relations: [],
            authority: authority
        )
        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })

        XCTAssertEqual(classifications[historical.evidenceID], .staleAnalysis)
        XCTAssertEqual(classifications[current.evidenceID], .acceptedCurrent)
        XCTAssertEqual(projection.currentRecords.map(\.evidenceID), [current.evidenceID])
        XCTAssertEqual(historical.classification, .acceptedCurrent)
        XCTAssertEqual(current.classification, .acceptedCurrent)
    }
}

private func hardeningDependencyChain(
    count: Int
) throws -> (records: [ReconstructionEvidenceRecord], relations: [ReconstructionEvidenceRelation]) {
    precondition(count > 1)
    let artifact = try hardeningArtifact(occurrence: 1)
    let producer = try hardeningProducer()
    let records = try (0..<count).map { index in
        try hardeningEvidence(
            id: hardeningID(index + 1),
            subject: .artifact(artifact),
            producer: producer
        )
    }
    let relations = (0..<(count - 1)).map { index in
        ReconstructionEvidenceRelation(
            relationID: hardeningID(100_000 + index),
            kind: .derivedFrom,
            sourceEvidenceID: records[index].evidenceID,
            targetEvidenceID: records[index + 1].evidenceID
        )
    }
    return (records, relations)
}

private func hardeningArtifact(
    occurrence: Int
) throws -> ReconstructionArtifactCoordinate {
    ReconstructionArtifactCoordinate(
        occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: hardeningID(occurrence)),
        contentIdentity: try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: hardeningDigest("a"),
            byteCount: 64
        )
    )
}

private func hardeningImage(
    artifact: ReconstructionArtifactCoordinate,
    fingerprint: String
) throws -> ReconstructionImageCoordinate {
    try ReconstructionImageCoordinate(
        artifact: artifact,
        image: hardeningImageBinding(),
        analysisFingerprintSHA256: fingerprint
    )
}

private func hardeningFunction(
    artifact: ReconstructionArtifactCoordinate,
    fingerprint: String,
    start: UInt64
) throws -> ReconstructionFunctionCoordinate {
    try ReconstructionFunctionCoordinate(
        artifact: artifact,
        image: hardeningImageBinding(),
        analysisFingerprintSHA256: fingerprint,
        startAddress: start,
        endAddressExclusive: start + 0x40,
        boundarySchemaVersion: 1,
        functionUUIDHint: nil,
        symbolHint: nil
    )
}

private func hardeningImageCoordinate(
    for function: ReconstructionFunctionCoordinate
) throws -> ReconstructionImageCoordinate {
    try ReconstructionImageCoordinate(
        artifact: function.artifact,
        image: function.image,
        analysisFingerprintSHA256: function.analysisFingerprintSHA256
    )
}

private func hardeningImageBinding() -> ReconstructionImageBinding {
    ReconstructionImageBinding(
        binaryID: hardeningID(800_001),
        imageSlot: ImageSlot(rawValue: 1),
        selectedSliceIndex: 0,
        architecture: .arm64,
        machOIdentity: nil
    )
}

private func hardeningEvidence(
    id evidenceID: UUID,
    subject: ReconstructionSubjectCoordinate,
    producer: ReconstructionProducerIdentity? = nil
) throws -> ReconstructionEvidenceRecord {
    let payload = Data("evidence".utf8)
    return try ReconstructionEvidenceRecord(
        evidenceID: evidenceID,
        subject: subject,
        operationID: "reconstruction.function.review",
        payloadKind: .structuredJSON,
        payload: payload,
        payloadByteCount: UInt64(payload.count),
        payloadSHA256: hardeningDigest("e"),
        facetDependencies: [],
        producer: try producer ?? hardeningProducer(),
        citations: [],
        creatingJobID: hardeningID(810_001),
        creatingTaskID: hardeningID(810_002),
        creatingCheckpointID: hardeningID(810_003),
        modelReceiptID: nil,
        toolReceiptID: hardeningID(810_004),
        classification: .acceptedCurrent,
        supersedesEvidenceID: nil,
        supersededByEvidenceID: nil,
        diagnostic: nil
    )
}

private func hardeningProducer() throws -> ReconstructionProducerIdentity {
    try ReconstructionProducerIdentity(
        macScopeBuildIdentity: "hardening-build-v1",
        macScopeSourceIdentity: "hardening-source-v1",
        operationIdentity: "reconstruction.function.review@1",
        registryIdentity: "reconstruction.v1",
        protocolIdentity: "reconstructionR1",
        canonicalSHA256: hardeningDigest("b")
    )
}

private func hardeningDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func hardeningID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

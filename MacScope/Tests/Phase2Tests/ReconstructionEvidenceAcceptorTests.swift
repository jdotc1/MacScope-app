import Foundation
import XCTest
@testable import MacScope

final class ReconstructionEvidenceAcceptorTests: XCTestCase {
    func testOperationRegistryFreezesRawValuesAndDeclarationPriority() {
        let expected: [(ReconstructionOperationID, String, Int)] = [
            (.corpusSummary, "reconstruction.corpus.summary", 0),
            (.corpusArtifactsPage, "reconstruction.corpus.artifacts.page", 1),
            (.corpusArtifactDescribe, "reconstruction.corpus.artifact.describe", 2),
            (.corpusRelationsPage, "reconstruction.corpus.relations.page", 3),
            (.corpusSearch, "reconstruction.corpus.search", 4),
            (.imagesPage, "reconstruction.images.page", 5),
            (.functionsPage, "reconstruction.functions.page", 6),
            (.functionReview, "reconstruction.function.review", 7),
            (.decompilerNative, "reconstruction.decompiler.native", 8),
            (.decompilerMacScope, "reconstruction.decompiler.macscope", 9),
            (.decompilerCompare, "reconstruction.decompiler.compare", 10),
            (.evidenceQuery, "reconstruction.evidence.query", 11),
            (.evidenceGet, "reconstruction.evidence.get", 12),
            (.gapsPage, "reconstruction.gaps.page", 13),
            (.checkpointStatus, "reconstruction.checkpoint.status", 14),
            (.analysisMacScopeRefresh, "reconstruction.analysis.macscope.refresh", 15),
            (.sourceRevision, "reconstruction.source.revision", 16),
            (.sourceOracle, "reconstruction.source.oracle", 17),
            (.sourceEvaluate, "reconstruction.source.evaluate", 18),
        ]

        XCTAssertEqual(ReconstructionOperationID.allCases, expected.map(\.0))
        XCTAssertEqual(ReconstructionOperationID.allCases.map(\.rawValue), expected.map(\.1))
        XCTAssertEqual(ReconstructionOperationID.allCases.map(\.priority), expected.map(\.2))
    }

    func testExactArtifactCandidateIsAcceptedButPayloadDigestMismatchIsRejected() throws {
        let fixture = try Fixture()
        let acceptor = ReconstructionEvidenceAcceptor(
            maximumPayloadBytes: 8,
            maximumDiagnosticUTF8Bytes: 1_024
        )

        let accepted = try acceptor.validate(fixture.candidate, against: fixture.authorityCut)

        XCTAssertEqual(accepted.evidenceID, Fixture.evidenceID)
        XCTAssertEqual(accepted.subject, fixture.subject)
        XCTAssertEqual(accepted.operationID, "reconstruction.corpus.artifact.describe")
        XCTAssertEqual(accepted.payloadKind, .structuredJSON)
        XCTAssertEqual(accepted.payload, Data("12345678".utf8))
        XCTAssertEqual(accepted.payloadByteCount, 8)
        XCTAssertEqual(
            accepted.payloadSHA256,
            "ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f"
        )
        XCTAssertEqual(accepted.producer, fixture.producer)
        XCTAssertEqual(accepted.citations, [fixture.citation])
        XCTAssertEqual(accepted.creatingJobID, Fixture.jobID)
        XCTAssertEqual(accepted.creatingTaskID, Fixture.taskID)
        XCTAssertEqual(accepted.creatingCheckpointID, Fixture.checkpointID)
        XCTAssertEqual(accepted.toolReceiptID, Fixture.toolReceiptID)
        XCTAssertNil(accepted.modelReceiptID)
        XCTAssertEqual(accepted.classification, .acceptedCurrent)
        XCTAssertNil(accepted.supersedesEvidenceID)
        XCTAssertNil(accepted.supersededByEvidenceID)

        let mismatched = try fixture.candidate(
            payloadSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        XCTAssertThrowsError(try acceptor.validate(mismatched, against: fixture.authorityCut)) {
            XCTAssertEqual(
                $0 as? ReconstructionEvidenceAcceptanceError,
                .payloadDigestMismatch
            )
        }
    }

    func testMatchingTamperedProducerDigestsCannotPassByEquality() throws {
        let fixture = try Fixture()
        let acceptor = ReconstructionEvidenceAcceptor(
            maximumPayloadBytes: 8,
            maximumDiagnosticUTF8Bytes: 1_024
        )
        let tamperedProducer = try Fixture.makeProducer(
            canonicalSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        let candidate = try fixture.candidate(
            payloadSHA256: "ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f",
            producer: tamperedProducer
        )
        let equallyTamperedAuthority = fixture.cut(producer: tamperedProducer)

        XCTAssertThrowsError(
            try acceptor.validate(candidate, against: equallyTamperedAuthority)
        ) {
            XCTAssertEqual(
                $0 as? ReconstructionEvidenceAcceptanceError,
                .producerDigestMismatch
            )
        }
    }

    func testTamperedAuthorityCorpusManifestDigestIsRejected() throws {
        let fixture = try Fixture()
        let acceptor = ReconstructionEvidenceAcceptor(
            maximumPayloadBytes: 8,
            maximumDiagnosticUTF8Bytes: 1_024
        )
        let tamperedManifest = try fixture.makeManifest(
            canonicalSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )

        XCTAssertThrowsError(
            try acceptor.validate(
                fixture.candidate,
                against: fixture.cut(corpusManifest: tamperedManifest)
            )
        ) {
            XCTAssertEqual(
                $0 as? ReconstructionEvidenceAcceptanceError,
                .corpusManifestDigestMismatch
            )
        }
    }
}

private extension ReconstructionEvidenceAcceptorTests {
    struct Fixture {
        static let evidenceID = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
        static let citationID = UUID(uuidString: "51000000-0000-0000-0000-000000000002")!
        static let occurrenceUUID = UUID(uuidString: "51000000-0000-0000-0000-000000000003")!
        static let projectID = UUID(uuidString: "51000000-0000-0000-0000-000000000004")!
        static let jobID = UUID(uuidString: "51000000-0000-0000-0000-000000000005")!
        static let taskID = UUID(uuidString: "51000000-0000-0000-0000-000000000006")!
        static let checkpointID = UUID(uuidString: "51000000-0000-0000-0000-000000000007")!
        static let toolReceiptID = UUID(uuidString: "51000000-0000-0000-0000-000000000008")!

        let subject: ReconstructionSubjectCoordinate
        let producer: ReconstructionProducerIdentity
        let citation: ReconstructionEvidenceCitation
        let occurrence: ReconstructionArtifactOccurrenceRecord
        let manifest: ReconstructionCorpusManifest
        let candidate: ReconstructionEvidenceCandidate
        let authorityCut: ReconstructionAuthorityCut

        init() throws {
            let content = try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                byteCount: 4_096
            )
            let artifact = ReconstructionArtifactCoordinate(
                occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: Self.occurrenceUUID),
                contentIdentity: content
            )
            subject = .artifact(artifact)
            producer = try Self.makeProducer()
            citation = try ReconstructionEvidenceCitation(
                citationID: Self.citationID,
                sourceEvidenceID: nil,
                subject: subject,
                locator: nil
            )
            candidate = try Self.makeCandidate(
                subject: subject,
                producer: producer,
                citation: citation,
                payloadSHA256: "ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f"
            )
            occurrence = try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: artifact.occurrenceID,
                contentIdentity: content,
                kind: .objectFile,
                roles: [.primaryTarget],
                executableMode: false,
                originalName: "fixture.o",
                diagnostic: nil
            )
            manifest = try Self.makeManifest(occurrence: occurrence)
            authorityCut = ReconstructionAuthorityCut(
                corpusManifest: manifest,
                authoritativeSubjects: [subject],
                facetFingerprints: [:],
                creatingJobID: Self.jobID,
                creatingTaskID: Self.taskID,
                creatingCheckpointID: Self.checkpointID,
                checkpointRevision: 7,
                operationID: .corpusArtifactDescribe,
                toolReceiptID: Self.toolReceiptID,
                modelReceiptID: nil,
                producer: producer,
                evidence: []
            )
        }

        func candidate(
            payloadSHA256: String,
            producer overrideProducer: ReconstructionProducerIdentity? = nil
        ) throws -> ReconstructionEvidenceCandidate {
            try Self.makeCandidate(
                subject: subject,
                producer: overrideProducer ?? producer,
                citation: citation,
                payloadSHA256: payloadSHA256
            )
        }

        func cut(
            corpusManifest: ReconstructionCorpusManifest? = nil,
            producer overrideProducer: ReconstructionProducerIdentity? = nil
        ) -> ReconstructionAuthorityCut {
            ReconstructionAuthorityCut(
                corpusManifest: corpusManifest ?? manifest,
                authoritativeSubjects: [subject],
                facetFingerprints: [:],
                creatingJobID: Self.jobID,
                creatingTaskID: Self.taskID,
                creatingCheckpointID: Self.checkpointID,
                checkpointRevision: 7,
                operationID: .corpusArtifactDescribe,
                toolReceiptID: Self.toolReceiptID,
                modelReceiptID: nil,
                producer: overrideProducer ?? producer,
                evidence: []
            )
        }

        func makeManifest(canonicalSHA256: String) throws -> ReconstructionCorpusManifest {
            try Self.makeManifest(
                occurrence: occurrence,
                canonicalSHA256: canonicalSHA256
            )
        }

        static func makeProducer(
            canonicalSHA256 overrideDigest: String? = nil
        ) throws -> ReconstructionProducerIdentity {
            let preimage = ProducerDigestPreimage(
                schemaVersion: ReconstructionProducerIdentity.schemaVersion,
                macScopeBuildIdentity: "macscope-build-510",
                macScopeSourceIdentity: "source-510",
                operationIdentity: "reconstruction.corpus.artifact.describe",
                registryIdentity: "reconstruction-operation-registry-v1",
                protocolIdentity: "reconstruction-evidence-v1",
                nativeProviderIdentity: "macscope-native",
                nativeCapabilityIdentities: ["artifact-describe-v1"],
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
                canonicalSHA256: overrideDigest
                    ?? ReconstructionCanonicalJSON.sha256(of: preimage)
            )
        }

        private static func makeManifest(
            occurrence: ReconstructionArtifactOccurrenceRecord,
            canonicalSHA256 overrideDigest: String? = nil
        ) throws -> ReconstructionCorpusManifest {
            let preimage = CorpusManifestDigestPreimage(
                schemaVersion: ReconstructionCorpusManifest.schemaVersion,
                reconstructionProjectID: projectID,
                artifacts: [occurrence],
                relations: []
            )
            return try ReconstructionCorpusManifest(
                schemaVersion: preimage.schemaVersion,
                reconstructionProjectID: preimage.reconstructionProjectID,
                artifacts: preimage.artifacts,
                relations: preimage.relations,
                canonicalSHA256: overrideDigest
                    ?? ReconstructionCanonicalJSON.sha256(of: preimage)
            )
        }

        private static func makeCandidate(
            subject: ReconstructionSubjectCoordinate,
            producer: ReconstructionProducerIdentity,
            citation: ReconstructionEvidenceCitation,
            payloadSHA256: String
        ) throws -> ReconstructionEvidenceCandidate {
            try ReconstructionEvidenceCandidate(
                evidenceID: evidenceID,
                subject: subject,
                operationID: .corpusArtifactDescribe,
                payloadKind: .structuredJSON,
                payload: Data("12345678".utf8),
                payloadByteCount: 8,
                payloadSHA256: payloadSHA256,
                facetDependencies: [],
                producer: producer,
                citations: [citation],
                creatingJobID: jobID,
                creatingTaskID: taskID,
                creatingCheckpointID: checkpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptID,
                supersedesEvidenceID: nil,
                diagnostic: nil
            )
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
    }
}

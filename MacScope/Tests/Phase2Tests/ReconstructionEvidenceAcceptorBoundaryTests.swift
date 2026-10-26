import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionEvidenceAcceptorBoundaryTests: XCTestCase {
    func testExactImageAndFunctionSubjectsAreAccepted() throws {
        let fixture = try Fixture()
        let acceptor = fixture.acceptor
        let subjects: [ReconstructionSubjectCoordinate] = [
            .image(fixture.currentImage),
            .function(fixture.currentFunction),
        ]

        for subject in subjects {
            let accepted = try acceptor.validate(
                fixture.candidate(subject: subject),
                against: fixture.cut(authoritativeSubjects: [subject])
            )

            XCTAssertEqual(accepted.subject, subject)
            XCTAssertEqual(accepted.facetDependencies, [fixture.facetDependency])
            XCTAssertEqual(accepted.classification, .acceptedCurrent)
        }
    }

    func testSubjectAuthorityRequiresExactArtifactImageRangeAndFingerprintIdentity() throws {
        struct Scenario {
            let name: String
            let authoritative: ReconstructionSubjectCoordinate
            let candidate: ReconstructionSubjectCoordinate
        }

        let fixture = try Fixture()
        let artifactSubject = ReconstructionSubjectCoordinate.artifact(fixture.currentArtifact)
        let imageSubject = ReconstructionSubjectCoordinate.image(fixture.currentImage)
        let functionSubject = ReconstructionSubjectCoordinate.function(fixture.currentFunction)
        let changedOccurrence = try fixture.artifact(
            occurrenceID: Fixture.uuid(101),
            bytes: Fixture.artifactBytes
        )
        let changedContent = try fixture.artifact(
            occurrenceID: Fixture.occurrenceUUID,
            bytes: Data("artifact-replaced".utf8)
        )
        let changedImageID = try fixture.image(binaryID: Fixture.uuid(102))
        let changedImageSlot = try fixture.image(imageSlot: ImageSlot(rawValue: 4))
        let changedSlice = try fixture.image(selectedSliceIndex: 2)
        let changedArchitecture = try fixture.image(architecture: .arm64e)
        let changedImageFingerprint = try fixture.image(
            fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(
                Data("analysis-replaced".utf8)
            )
        )
        let changedRange = try fixture.function(endAddressExclusive: 0x1_080)
        let changedBoundarySchema = try fixture.function(boundarySchemaVersion: 2)
        let changedFunctionFingerprint = try fixture.function(
            fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(
                Data("function-analysis-replaced".utf8)
            )
        )
        let changedFunctionArtifact = try fixture.function(artifact: changedContent)
        let changedFunctionImage = try fixture.function(
            image: fixture.image(binaryID: Fixture.uuid(104)).image
        )

        let scenarios = [
            Scenario(
                name: "artifact occurrence",
                authoritative: artifactSubject,
                candidate: .artifact(changedOccurrence)
            ),
            Scenario(
                name: "artifact content",
                authoritative: artifactSubject,
                candidate: .artifact(changedContent)
            ),
            Scenario(
                name: "image binary identity",
                authoritative: imageSubject,
                candidate: .image(changedImageID)
            ),
            Scenario(
                name: "image slot",
                authoritative: imageSubject,
                candidate: .image(changedImageSlot)
            ),
            Scenario(
                name: "selected slice",
                authoritative: imageSubject,
                candidate: .image(changedSlice)
            ),
            Scenario(
                name: "image architecture",
                authoritative: imageSubject,
                candidate: .image(changedArchitecture)
            ),
            Scenario(
                name: "image analysis fingerprint",
                authoritative: imageSubject,
                candidate: .image(changedImageFingerprint)
            ),
            Scenario(
                name: "function range",
                authoritative: functionSubject,
                candidate: .function(changedRange)
            ),
            Scenario(
                name: "function artifact content",
                authoritative: functionSubject,
                candidate: .function(changedFunctionArtifact)
            ),
            Scenario(
                name: "function image binding",
                authoritative: functionSubject,
                candidate: .function(changedFunctionImage)
            ),
            Scenario(
                name: "function boundary schema",
                authoritative: functionSubject,
                candidate: .function(changedBoundarySchema)
            ),
            Scenario(
                name: "function analysis fingerprint",
                authoritative: functionSubject,
                candidate: .function(changedFunctionFingerprint)
            ),
        ]

        for scenario in scenarios {
            assertRejects(
                .subjectNotAuthoritative,
                candidate: try fixture.candidate(subject: scenario.candidate),
                against: fixture.cut(authoritativeSubjects: [scenario.authoritative]),
                using: fixture.acceptor,
                scenario: scenario.name
            )
        }
    }

    func testAuthorizedSubjectsStillRequireCurrentArtifactOccurrenceAndContent() throws {
        let fixture = try Fixture()
        let staleContent = try fixture.artifact(
            occurrenceID: Fixture.occurrenceUUID,
            bytes: Data("artifact-stale".utf8)
        )
        let staleOccurrence = try fixture.artifact(
            occurrenceID: Fixture.uuid(103),
            bytes: Fixture.artifactBytes
        )
        let subjects: [(String, ReconstructionSubjectCoordinate)] = [
            ("image content", .image(try fixture.image(artifact: staleContent))),
            ("function occurrence", .function(try fixture.function(artifact: staleOccurrence))),
        ]

        for (name, subject) in subjects {
            assertRejects(
                .artifactNotCurrent,
                candidate: try fixture.candidate(subject: subject),
                against: fixture.cut(authoritativeSubjects: [subject]),
                using: fixture.acceptor,
                scenario: name
            )
        }
    }

    func testFacetDependenciesMustUniquelyMatchTheAuthorityFingerprints() throws {
        struct Scenario {
            let name: String
            let dependencies: [ReconstructionFacetDependency]
            let fingerprints: [String: String]
        }

        let fixture = try Fixture()
        let wrongDependency = try ReconstructionFacetDependency(
            facetIdentity: Fixture.facetIdentity,
            fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(Data("wrong-facet".utf8))
        )
        let extraDependency = try ReconstructionFacetDependency(
            facetIdentity: "analysis.function.extra",
            fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(Data("extra-facet".utf8))
        )
        let scenarios = [
            Scenario(
                name: "wrong fingerprint",
                dependencies: [wrongDependency],
                fingerprints: fixture.facetFingerprints
            ),
            Scenario(
                name: "candidate omits required facet",
                dependencies: [],
                fingerprints: fixture.facetFingerprints
            ),
            Scenario(
                name: "candidate adds undeclared facet",
                dependencies: [fixture.facetDependency, extraDependency],
                fingerprints: fixture.facetFingerprints
            ),
            Scenario(
                name: "duplicate facet identity",
                dependencies: [fixture.facetDependency, fixture.facetDependency],
                fingerprints: fixture.facetFingerprints
            ),
        ]

        for scenario in scenarios {
            assertRejects(
                .facetMismatch,
                candidate: try fixture.candidate(facetDependencies: scenario.dependencies),
                against: fixture.cut(facetFingerprints: scenario.fingerprints),
                using: fixture.acceptor,
                scenario: scenario.name
            )
        }

        let acceptedWithoutFacetAuthority = try fixture.acceptor.validate(
            fixture.candidate(facetDependencies: []),
            against: fixture.cut(facetFingerprints: [:])
        )
        XCTAssertEqual(acceptedWithoutFacetAuthority.facetDependencies, [])
    }

    func testCitationAndFacetCountLimitsAcceptExactBoundaryAndRejectOneOver() throws {
        let fixture = try Fixture()
        let citations = try (0..<3).map { index in
            try fixture.citation(
                id: Fixture.uuid(600 + index),
                sourceEvidenceID: nil,
                subject: .function(fixture.currentFunction),
                locator: "anchor-\(index)"
            )
        }
        let citationBounded = fixture.acceptor(maximumCitationCount: 2)

        XCTAssertNoThrow(
            try citationBounded.validate(
                fixture.candidate(citations: Array(citations.prefix(2))),
                against: fixture.cut()
            )
        )
        assertRejects(
            .citationLimitExceeded,
            candidate: try fixture.candidate(citations: citations),
            against: fixture.cut(),
            using: citationBounded,
            scenario: "citation count one over"
        )

        let facets = try (0..<3).map { index in
            try ReconstructionFacetDependency(
                facetIdentity: "facet-\(index)",
                fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(
                    Data("facet-fingerprint-\(index)".utf8)
                )
            )
        }
        let facetBounded = fixture.acceptor(maximumFacetCount: 2)
        let exactFingerprints = Dictionary(
            uniqueKeysWithValues: facets.prefix(2).map {
                ($0.facetIdentity, $0.fingerprintSHA256)
            }
        )
        let excessiveFingerprints = Dictionary(
            uniqueKeysWithValues: facets.map {
                ($0.facetIdentity, $0.fingerprintSHA256)
            }
        )

        XCTAssertNoThrow(
            try facetBounded.validate(
                fixture.candidate(facetDependencies: Array(facets.prefix(2))),
                against: fixture.cut(facetFingerprints: exactFingerprints)
            )
        )
        assertRejects(
            .facetLimitExceeded,
            candidate: try fixture.candidate(facetDependencies: facets),
            against: fixture.cut(facetFingerprints: excessiveFingerprints),
            using: facetBounded,
            scenario: "facet count one over"
        )
    }

    func testCitationLocatorAndFacetIdentityUseExactUTF8ByteLimits() throws {
        let fixture = try Fixture()
        let locatorBounded = fixture.acceptor(maximumCitationLocatorUTF8Bytes: 4)
        let exactLocator = try fixture.citation(
            id: Fixture.uuid(610),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: "éé"
        )
        let excessiveLocator = try fixture.citation(
            id: Fixture.uuid(611),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: "ééa"
        )

        XCTAssertNoThrow(
            try locatorBounded.validate(
                fixture.candidate(citations: [exactLocator]),
                against: fixture.cut()
            )
        )
        assertRejects(
            .citationLocatorLimitExceeded,
            candidate: try fixture.candidate(citations: [excessiveLocator]),
            against: fixture.cut(),
            using: locatorBounded,
            scenario: "citation locator one UTF-8 byte over"
        )

        let exactFacet = try ReconstructionFacetDependency(
            facetIdentity: "éé",
            fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(Data("exact-identity".utf8))
        )
        let excessiveFacet = try ReconstructionFacetDependency(
            facetIdentity: "ééa",
            fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(Data("excessive-identity".utf8))
        )
        let identityBounded = fixture.acceptor(maximumFacetIdentityUTF8Bytes: 4)

        XCTAssertNoThrow(
            try identityBounded.validate(
                fixture.candidate(facetDependencies: [exactFacet]),
                against: fixture.cut(facetFingerprints: [
                    exactFacet.facetIdentity: exactFacet.fingerprintSHA256,
                ])
            )
        )
        assertRejects(
            .facetIdentityLimitExceeded,
            candidate: try fixture.candidate(facetDependencies: [excessiveFacet]),
            against: fixture.cut(facetFingerprints: [
                excessiveFacet.facetIdentity: excessiveFacet.fingerprintSHA256,
            ]),
            using: identityBounded,
            scenario: "facet identity one UTF-8 byte over"
        )
    }

    func testAggregateMetadataLimitAcceptsExactBoundaryAndRejectsOneOver() throws {
        let fixture = try Fixture()
        let exactLocator = try fixture.citation(
            id: Fixture.uuid(620),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: "éé"
        )
        let excessiveLocator = try fixture.citation(
            id: Fixture.uuid(621),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: "ééa"
        )
        let acceptor = fixture.acceptor(
            maximumCitationLocatorUTF8Bytes: 8,
            // Producer identity (203), candidate/citation symbol hints (16), locator (4).
            maximumMetadataUTF8Bytes: 223
        )
        let emptyFacetCut = fixture.cut(facetFingerprints: [:])

        XCTAssertNoThrow(
            try acceptor.validate(
                fixture.candidate(
                    facetDependencies: [],
                    citations: [exactLocator]
                ),
                against: emptyFacetCut
            )
        )
        assertRejects(
            .metadataLimitExceeded,
            candidate: try fixture.candidate(
                facetDependencies: [],
                citations: [excessiveLocator]
            ),
            against: emptyFacetCut,
            using: acceptor,
            scenario: "aggregate metadata one UTF-8 byte over"
        )
    }

    func testHugeUniqueMetadataWithTinyPayloadIsRejected() throws {
        let fixture = try Fixture()
        let citations = try (0..<2_048).map { index in
            let prefix = String(format: "%04d", index)
            return try fixture.citation(
                id: Fixture.uuid(10_000 + index),
                sourceEvidenceID: nil,
                subject: .function(fixture.currentFunction),
                locator: prefix + String(repeating: "x", count: 508)
            )
        }
        let acceptor = fixture.acceptor(
            maximumCitationCount: 2_048,
            maximumCitationLocatorUTF8Bytes: 512,
            maximumMetadataUTF8Bytes: 64 * 1_024
        )

        assertRejects(
            .metadataLimitExceeded,
            candidate: try fixture.candidate(
                payload: Data([0x01]),
                citations: citations
            ),
            against: fixture.cut(),
            using: acceptor,
            scenario: "unique citation metadata exceeds aggregate budget"
        )
    }

    func testCanonicalEvidenceLimitAcceptsExactBoundaryAndRejectsOneOver() throws {
        let fixture = try Fixture()
        let exactCitation = try fixture.citation(
            id: Fixture.uuid(630),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: "a"
        )
        let oneByteLargerCitation = try fixture.citation(
            id: Fixture.uuid(630),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: "aa"
        )
        let permissive = fixture.acceptor()
        let exactCandidate = try fixture.candidate(citations: [exactCitation])
        let largerCandidate = try fixture.candidate(citations: [oneByteLargerCitation])
        let exactRecord = try permissive.validate(exactCandidate, against: fixture.cut())
        let largerRecord = try permissive.validate(largerCandidate, against: fixture.cut())
        let exactCanonicalByteCount = try ReconstructionCanonicalJSON.encode(exactRecord).count

        XCTAssertEqual(
            try ReconstructionCanonicalJSON.encode(largerRecord).count,
            exactCanonicalByteCount + 1
        )

        let acceptor = fixture.acceptor(
            maximumCanonicalEvidenceBytes: exactCanonicalByteCount
        )
        XCTAssertNoThrow(try acceptor.validate(exactCandidate, against: fixture.cut()))
        assertRejects(
            .canonicalEvidenceLimitExceeded,
            candidate: largerCandidate,
            against: fixture.cut(),
            using: acceptor,
            scenario: "canonical evidence one byte over"
        )
    }

    func testPreCancelledAcceptanceThrowsCancellationError() async throws {
        let fixture = try Fixture()
        let validation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.acceptor.validate(
                fixture.candidate(),
                against: fixture.cut()
            )
        }

        do {
            _ = try await validation.value
            XCTFail("Pre-cancelled acceptance completed without observing cancellation")
        } catch is CancellationError {
            // Expected: acceptance has an entry cancellation gate and retains CancellationError.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testPayloadAndDiagnosticLimitsAreExactByteBoundaries() throws {
        struct Scenario {
            let name: String
            let payload: Data
            let byteCount: UInt64?
            let digest: String?
            let diagnostic: ReconstructionDiagnostic?
            let expected: ReconstructionEvidenceAcceptanceError
        }

        let fixture = try Fixture()
        let exactDiagnostic = ReconstructionDiagnostic.sanitizing("éé")
        let accepted = try fixture.acceptor.validate(
            fixture.candidate(diagnostic: exactDiagnostic),
            against: fixture.cut()
        )
        XCTAssertEqual(accepted.payloadByteCount, 8)
        XCTAssertEqual(accepted.diagnostic?.text.utf8.count, 4)

        let scenarios = [
            Scenario(
                name: "empty payload",
                payload: Data(),
                byteCount: 0,
                digest: CanonicalFixtureDigests.rawSHA256(Data()),
                diagnostic: nil,
                expected: .payloadByteCountMismatch
            ),
            Scenario(
                name: "declared byte count",
                payload: Fixture.payload,
                byteCount: 7,
                digest: Fixture.payloadSHA256,
                diagnostic: nil,
                expected: .payloadByteCountMismatch
            ),
            Scenario(
                name: "payload digest",
                payload: Fixture.payload,
                byteCount: 8,
                digest: CanonicalFixtureDigests.rawSHA256(Data("different".utf8)),
                diagnostic: nil,
                expected: .payloadDigestMismatch
            ),
            Scenario(
                name: "payload over maximum",
                payload: Data("123456789".utf8),
                byteCount: 9,
                digest: CanonicalFixtureDigests.rawSHA256(Data("123456789".utf8)),
                diagnostic: nil,
                expected: .payloadLimitExceeded
            ),
            Scenario(
                name: "diagnostic over maximum",
                payload: Fixture.payload,
                byteCount: 8,
                digest: Fixture.payloadSHA256,
                diagnostic: ReconstructionDiagnostic.sanitizing("ééa"),
                expected: .diagnosticLimitExceeded
            ),
        ]

        for scenario in scenarios {
            assertRejects(
                scenario.expected,
                candidate: try fixture.candidate(
                    payload: scenario.payload,
                    payloadByteCount: scenario.byteCount,
                    payloadSHA256: scenario.digest,
                    diagnostic: scenario.diagnostic
                ),
                against: fixture.cut(),
                using: fixture.acceptor,
                scenario: scenario.name
            )
        }
    }

    func testNonpositiveAcceptorLimitsFailBeforeCandidateAcceptance() throws {
        let fixture = try Fixture()
        let acceptors = [
            ReconstructionEvidenceAcceptor(
                maximumPayloadBytes: 0,
                maximumDiagnosticUTF8Bytes: 4
            ),
            ReconstructionEvidenceAcceptor(
                maximumPayloadBytes: 8,
                maximumDiagnosticUTF8Bytes: 0
            ),
            fixture.acceptor(maximumCitationCount: 0),
            fixture.acceptor(maximumFacetCount: 0),
            fixture.acceptor(maximumCitationLocatorUTF8Bytes: 0),
            fixture.acceptor(maximumFacetIdentityUTF8Bytes: 0),
            fixture.acceptor(maximumMetadataUTF8Bytes: 0),
            fixture.acceptor(maximumCanonicalEvidenceBytes: 0),
        ]

        for acceptor in acceptors {
            assertRejects(
                .invalidLimits,
                candidate: try fixture.candidate(),
                against: fixture.cut(),
                using: acceptor,
                scenario: "nonpositive limit"
            )
        }
    }

    func testJobTaskCheckpointAndReceiptCorrelationsMustMatchExactly() throws {
        struct Scenario {
            let name: String
            let candidateJobID: UUID?
            let candidateTaskID: UUID?
            let candidateCheckpointID: UUID?
            let candidateReceipts: Fixture.Receipts?
            let cutJobID: UUID?
            let cutTaskID: UUID?
            let cutCheckpointID: UUID?
            let cutReceipts: Fixture.Receipts?
            let expected: ReconstructionEvidenceAcceptanceError
        }

        let fixture = try Fixture()
        let modelReceipts = Fixture.Receipts(tool: nil, model: Fixture.modelReceiptID)
        let scenarios = [
            Scenario(
                name: "job",
                candidateJobID: Fixture.uuid(201),
                candidateTaskID: nil,
                candidateCheckpointID: nil,
                candidateReceipts: nil,
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: nil,
                expected: .taskCorrelationMismatch
            ),
            Scenario(
                name: "task",
                candidateJobID: nil,
                candidateTaskID: Fixture.uuid(202),
                candidateCheckpointID: nil,
                candidateReceipts: nil,
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: nil,
                expected: .taskCorrelationMismatch
            ),
            Scenario(
                name: "checkpoint",
                candidateJobID: nil,
                candidateTaskID: nil,
                candidateCheckpointID: Fixture.uuid(203),
                candidateReceipts: nil,
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: nil,
                expected: .checkpointCorrelationMismatch
            ),
            Scenario(
                name: "tool receipt",
                candidateJobID: nil,
                candidateTaskID: nil,
                candidateCheckpointID: nil,
                candidateReceipts: .init(tool: Fixture.uuid(204), model: nil),
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: nil,
                expected: .receiptCorrelationMismatch
            ),
            Scenario(
                name: "model receipt",
                candidateJobID: nil,
                candidateTaskID: nil,
                candidateCheckpointID: nil,
                candidateReceipts: .init(tool: nil, model: Fixture.uuid(205)),
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: modelReceipts,
                expected: .receiptCorrelationMismatch
            ),
            Scenario(
                name: "missing model receipt",
                candidateJobID: nil,
                candidateTaskID: nil,
                candidateCheckpointID: nil,
                candidateReceipts: .init(tool: nil, model: nil),
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: modelReceipts,
                expected: .receiptCorrelationMismatch
            ),
            Scenario(
                name: "authority has no receipt",
                candidateJobID: nil,
                candidateTaskID: nil,
                candidateCheckpointID: nil,
                candidateReceipts: .init(tool: nil, model: nil),
                cutJobID: nil,
                cutTaskID: nil,
                cutCheckpointID: nil,
                cutReceipts: .init(tool: nil, model: nil),
                expected: .receiptCorrelationMismatch
            ),
        ]

        for scenario in scenarios {
            assertRejects(
                scenario.expected,
                candidate: try fixture.candidate(
                    creatingJobID: scenario.candidateJobID,
                    creatingTaskID: scenario.candidateTaskID,
                    creatingCheckpointID: scenario.candidateCheckpointID,
                    receipts: scenario.candidateReceipts
                ),
                against: fixture.cut(
                    creatingJobID: scenario.cutJobID,
                    creatingTaskID: scenario.cutTaskID,
                    creatingCheckpointID: scenario.cutCheckpointID,
                    receipts: scenario.cutReceipts
                ),
                using: fixture.acceptor,
                scenario: scenario.name
            )
        }
    }

    func testCitationsRequireUniqueResolvedDurableAnchors() throws {
        struct Scenario {
            let name: String
            let citations: [ReconstructionEvidenceCitation]
            let expected: ReconstructionEvidenceAcceptanceError
        }

        let fixture = try Fixture()
        let baseline = try fixture.citation(
            id: Fixture.citationID,
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: nil
        )
        let duplicateAnchor = try fixture.citation(
            id: Fixture.uuid(301),
            sourceEvidenceID: nil,
            subject: .function(fixture.currentFunction),
            locator: nil
        )
        let staleSubject = ReconstructionSubjectCoordinate.artifact(
            try fixture.artifact(
                occurrenceID: Fixture.occurrenceUUID,
                bytes: Data("citation-stale".utf8)
            )
        )
        let scenarios = [
            Scenario(name: "missing", citations: [], expected: .missingCitation),
            Scenario(
                name: "duplicate citation ID",
                citations: [baseline, baseline],
                expected: .duplicateCitation
            ),
            Scenario(
                name: "duplicate durable anchor",
                citations: [baseline, duplicateAnchor],
                expected: .duplicateCitation
            ),
            Scenario(
                name: "unknown source evidence",
                citations: [
                    try fixture.citation(
                        id: Fixture.uuid(302),
                        sourceEvidenceID: Fixture.uuid(303),
                        subject: nil,
                        locator: nil
                    ),
                ],
                expected: .unresolvedCitation
            ),
            Scenario(
                name: "locator without durable anchor",
                citations: [
                    try fixture.citation(
                        id: Fixture.uuid(304),
                        sourceEvidenceID: nil,
                        subject: nil,
                        locator: "function+0x4"
                    ),
                ],
                expected: .unresolvedCitation
            ),
            Scenario(
                name: "stale subject anchor",
                citations: [
                    try fixture.citation(
                        id: Fixture.uuid(305),
                        sourceEvidenceID: nil,
                        subject: staleSubject,
                        locator: nil
                    ),
                ],
                expected: .unresolvedCitation
            ),
        ]

        for scenario in scenarios {
            assertRejects(
                scenario.expected,
                candidate: try fixture.candidate(citations: scenario.citations),
                against: fixture.cut(),
                using: fixture.acceptor,
                scenario: scenario.name
            )
        }
    }

    func testDuplicateEvidenceIDIsRejected() throws {
        let fixture = try Fixture()
        let duplicate = try fixture.record(
            id: Fixture.evidenceID,
            subject: .function(fixture.currentFunction)
        )

        assertRejects(
            .duplicateEvidenceID,
            candidate: try fixture.candidate(),
            against: fixture.cut(evidence: [duplicate]),
            using: fixture.acceptor,
            scenario: "duplicate evidence ID"
        )
    }

    func testProducerMustMatchAndExcludeTransientOrForbiddenIdentity() throws {
        let fixture = try Fixture()
        let differentProducer = try fixture.makeProducer(
            macScopeSourceIdentity: "source-build-other"
        )
        assertRejects(
            .producerMismatch,
            candidate: try fixture.candidate(producer: differentProducer),
            against: fixture.cut(),
            using: fixture.acceptor,
            scenario: "different canonical producer"
        )

        let forbiddenBuildIdentities = [
            "/Users/example/build-output",
            "build-pid=4217",
            "build-0x12345678",
            String(repeating: "x", count: 1_025),
        ]
        for identity in forbiddenBuildIdentities {
            let producer = try fixture.makeProducer(macScopeBuildIdentity: identity)
            assertRejects(
                .forbiddenProducerIdentity,
                candidate: try fixture.candidate(producer: producer),
                against: fixture.cut(producer: producer),
                using: fixture.acceptor,
                scenario: identity
            )
        }
    }

    func testValidSupersessionNamesTheCurrentSameSubjectPredecessor() throws {
        let fixture = try Fixture()
        let subject = ReconstructionSubjectCoordinate.function(fixture.currentFunction)
        let predecessor = try fixture.record(id: Fixture.predecessorID, subject: subject)
        let candidate = try fixture.candidate(
            supersedesEvidenceID: Fixture.predecessorID
        )

        let accepted = try fixture.acceptor.validate(
            candidate,
            against: fixture.cut(evidence: [predecessor])
        )

        XCTAssertEqual(accepted.evidenceID, Fixture.evidenceID)
        XCTAssertEqual(accepted.supersedesEvidenceID, Fixture.predecessorID)
        XCTAssertNil(accepted.supersededByEvidenceID)
        XCTAssertEqual(accepted.subject, subject)
    }

    func testSupersessionRejectsSelfMissingClaimedAndCrossSubjectPredecessors() throws {
        struct Scenario {
            let name: String
            let predecessorID: UUID
            let evidence: [ReconstructionEvidenceRecord]
        }

        let fixture = try Fixture()
        let subject = ReconstructionSubjectCoordinate.function(fixture.currentFunction)
        let predecessor = try fixture.record(id: Fixture.predecessorID, subject: subject)
        let alreadyLinked = try fixture.record(
            id: Fixture.predecessorID,
            subject: subject,
            supersededByEvidenceID: Fixture.existingSuccessorID
        )
        let existingSuccessor = try fixture.record(
            id: Fixture.existingSuccessorID,
            subject: subject,
            supersedesEvidenceID: Fixture.predecessorID
        )
        let crossSubject = try fixture.record(
            id: Fixture.predecessorID,
            subject: .image(fixture.currentImage)
        )
        let scenarios = [
            Scenario(
                name: "self supersession",
                predecessorID: Fixture.evidenceID,
                evidence: [predecessor]
            ),
            Scenario(
                name: "missing predecessor",
                predecessorID: Fixture.uuid(401),
                evidence: [predecessor]
            ),
            Scenario(
                name: "predecessor already links a successor",
                predecessorID: Fixture.predecessorID,
                evidence: [alreadyLinked]
            ),
            Scenario(
                name: "another successor already claims predecessor",
                predecessorID: Fixture.predecessorID,
                evidence: [predecessor, existingSuccessor]
            ),
            Scenario(
                name: "cross-subject predecessor",
                predecessorID: Fixture.predecessorID,
                evidence: [crossSubject]
            ),
        ]

        for scenario in scenarios {
            assertRejects(
                .invalidSupersession,
                candidate: try fixture.candidate(
                    supersedesEvidenceID: scenario.predecessorID
                ),
                against: fixture.cut(evidence: scenario.evidence),
                using: fixture.acceptor,
                scenario: scenario.name
            )
        }
    }
}

private extension ReconstructionEvidenceAcceptorBoundaryTests {
    func assertRejects(
        _ expected: ReconstructionEvidenceAcceptanceError,
        candidate: ReconstructionEvidenceCandidate,
        against cut: ReconstructionAuthorityCut,
        using acceptor: ReconstructionEvidenceAcceptor,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try acceptor.validate(candidate, against: cut),
            scenario,
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionEvidenceAcceptanceError,
                expected,
                scenario,
                file: file,
                line: line
            )
        }
    }

    struct Fixture {
        struct Receipts {
            let tool: UUID?
            let model: UUID?
        }

        static let evidenceID = uuid(1)
        static let citationID = uuid(2)
        static let occurrenceUUID = uuid(3)
        static let projectID = uuid(4)
        static let binaryID = uuid(5)
        static let jobID = uuid(6)
        static let taskID = uuid(7)
        static let checkpointID = uuid(8)
        static let toolReceiptID = uuid(9)
        static let modelReceiptID = uuid(10)
        static let predecessorID = uuid(11)
        static let existingSuccessorID = uuid(12)
        static let artifactBytes = Data("artifact-current".utf8)
        static let payload = Data("evidence".utf8)
        static let payloadSHA256 = CanonicalFixtureDigests.rawSHA256(payload)
        static let facetIdentity = "analysis.function.boundary"

        let currentArtifact: ReconstructionArtifactCoordinate
        let currentImage: ReconstructionImageCoordinate
        let currentFunction: ReconstructionFunctionCoordinate
        let producer: ReconstructionProducerIdentity
        let manifest: ReconstructionCorpusManifest
        let facetDependency: ReconstructionFacetDependency

        var acceptor: ReconstructionEvidenceAcceptor {
            ReconstructionEvidenceAcceptor(
                maximumPayloadBytes: 8,
                maximumDiagnosticUTF8Bytes: 4
            )
        }

        func acceptor(
            maximumCitationCount: Int = 4_096,
            maximumFacetCount: Int = 1_024,
            maximumCitationLocatorUTF8Bytes: Int = 16 * 1_024,
            maximumFacetIdentityUTF8Bytes: Int = 1_024,
            maximumMetadataUTF8Bytes: Int = 16 * 1_024 * 1_024,
            maximumCanonicalEvidenceBytes: Int = ReconstructionPackageLayout.maximumManifestBytes
        ) -> ReconstructionEvidenceAcceptor {
            ReconstructionEvidenceAcceptor(
                maximumPayloadBytes: 8,
                maximumDiagnosticUTF8Bytes: 4,
                limits: ReconstructionEvidenceAcceptor.Limits(
                    maximumCitationCount: maximumCitationCount,
                    maximumFacetCount: maximumFacetCount,
                    maximumCitationLocatorUTF8Bytes: maximumCitationLocatorUTF8Bytes,
                    maximumFacetIdentityUTF8Bytes: maximumFacetIdentityUTF8Bytes,
                    maximumMetadataUTF8Bytes: maximumMetadataUTF8Bytes,
                    maximumCanonicalEvidenceBytes: maximumCanonicalEvidenceBytes
                )
            )
        }

        var facetFingerprints: [String: String] {
            [facetDependency.facetIdentity: facetDependency.fingerprintSHA256]
        }

        init() throws {
            let artifact = try Self.makeArtifact(
                occurrenceID: Self.occurrenceUUID,
                bytes: Self.artifactBytes
            )
            let binding = Self.makeImageBinding(
                binaryID: Self.binaryID,
                imageSlot: .primary,
                selectedSliceIndex: 0,
                architecture: .arm64
            )
            let fingerprint = CanonicalFixtureDigests.rawSHA256(
                Data("analysis-current".utf8)
            )
            let image = try ReconstructionImageCoordinate(
                artifact: artifact,
                image: binding,
                analysisFingerprintSHA256: fingerprint
            )
            let function = try ReconstructionFunctionCoordinate(
                artifact: artifact,
                image: binding,
                analysisFingerprintSHA256: fingerprint,
                startAddress: 0x1_000,
                endAddressExclusive: 0x1_040,
                boundarySchemaVersion: 1,
                functionUUIDHint: Self.uuid(13),
                symbolHint: "_fixture"
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
            let facet = try ReconstructionFacetDependency(
                facetIdentity: Self.facetIdentity,
                fingerprintSHA256: CanonicalFixtureDigests.rawSHA256(
                    Data("facet-current".utf8)
                )
            )

            currentArtifact = artifact
            currentImage = image
            currentFunction = function
            producer = try CanonicalFixtureDigests.producer()
            manifest = try CanonicalFixtureDigests.manifest(
                reconstructionProjectID: Self.projectID,
                artifacts: [occurrence],
                relations: []
            )
            facetDependency = facet
        }

        func artifact(
            occurrenceID: UUID,
            bytes: Data
        ) throws -> ReconstructionArtifactCoordinate {
            try Self.makeArtifact(occurrenceID: occurrenceID, bytes: bytes)
        }

        func image(
            artifact: ReconstructionArtifactCoordinate? = nil,
            binaryID: UUID? = nil,
            imageSlot: ImageSlot? = nil,
            selectedSliceIndex: Int? = nil,
            architecture: ReconstructionArchitecture? = nil,
            fingerprintSHA256: String? = nil
        ) throws -> ReconstructionImageCoordinate {
            try ReconstructionImageCoordinate(
                artifact: artifact ?? currentArtifact,
                image: Self.makeImageBinding(
                    binaryID: binaryID ?? Self.binaryID,
                    imageSlot: imageSlot ?? .primary,
                    selectedSliceIndex: selectedSliceIndex ?? 0,
                    architecture: architecture ?? .arm64
                ),
                analysisFingerprintSHA256: fingerprintSHA256
                    ?? currentImage.analysisFingerprintSHA256
            )
        }

        func function(
            artifact: ReconstructionArtifactCoordinate? = nil,
            image: ReconstructionImageBinding? = nil,
            fingerprintSHA256: String? = nil,
            startAddress: UInt64? = nil,
            endAddressExclusive: UInt64? = nil,
            boundarySchemaVersion: Int? = nil
        ) throws -> ReconstructionFunctionCoordinate {
            try ReconstructionFunctionCoordinate(
                artifact: artifact ?? currentArtifact,
                image: image ?? currentFunction.image,
                analysisFingerprintSHA256: fingerprintSHA256
                    ?? currentFunction.analysisFingerprintSHA256,
                startAddress: startAddress ?? currentFunction.startAddress,
                endAddressExclusive: endAddressExclusive
                    ?? currentFunction.endAddressExclusive,
                boundarySchemaVersion: boundarySchemaVersion
                    ?? currentFunction.boundarySchemaVersion,
                functionUUIDHint: currentFunction.functionUUIDHint,
                symbolHint: currentFunction.symbolHint
            )
        }

        func makeProducer(
            macScopeBuildIdentity: String = "macscope-build-acceptor-boundary",
            macScopeSourceIdentity: String = "source-build-acceptor-boundary"
        ) throws -> ReconstructionProducerIdentity {
            try CanonicalFixtureDigests.producer(
                macScopeBuildIdentity: macScopeBuildIdentity,
                macScopeSourceIdentity: macScopeSourceIdentity
            )
        }

        func candidate(
            evidenceID: UUID = Fixture.evidenceID,
            subject: ReconstructionSubjectCoordinate? = nil,
            payload: Data = Fixture.payload,
            payloadByteCount: UInt64? = nil,
            payloadSHA256: String? = nil,
            facetDependencies: [ReconstructionFacetDependency]? = nil,
            producer: ReconstructionProducerIdentity? = nil,
            citations: [ReconstructionEvidenceCitation]? = nil,
            creatingJobID: UUID? = nil,
            creatingTaskID: UUID? = nil,
            creatingCheckpointID: UUID? = nil,
            receipts: Receipts? = nil,
            supersedesEvidenceID: UUID? = nil,
            diagnostic: ReconstructionDiagnostic? = nil
        ) throws -> ReconstructionEvidenceCandidate {
            let resolvedSubject = subject ?? .function(currentFunction)
            let resolvedReceipts = receipts
                ?? Receipts(tool: Self.toolReceiptID, model: nil)
            let resolvedCitations = try citations ?? [citation(
                id: Self.citationID,
                sourceEvidenceID: nil,
                subject: resolvedSubject,
                locator: nil
            )]
            return try ReconstructionEvidenceCandidate(
                evidenceID: evidenceID,
                subject: resolvedSubject,
                operationID: .functionReview,
                payloadKind: .structuredJSON,
                payload: payload,
                payloadByteCount: payloadByteCount ?? UInt64(payload.count),
                payloadSHA256: payloadSHA256
                    ?? CanonicalFixtureDigests.rawSHA256(payload),
                facetDependencies: facetDependencies ?? [facetDependency],
                producer: producer ?? self.producer,
                citations: resolvedCitations,
                creatingJobID: creatingJobID ?? Self.jobID,
                creatingTaskID: creatingTaskID ?? Self.taskID,
                creatingCheckpointID: creatingCheckpointID ?? Self.checkpointID,
                modelReceiptID: resolvedReceipts.model,
                toolReceiptID: resolvedReceipts.tool,
                supersedesEvidenceID: supersedesEvidenceID,
                diagnostic: diagnostic
            )
        }

        func cut(
            authoritativeSubjects: [ReconstructionSubjectCoordinate]? = nil,
            facetFingerprints: [String: String]? = nil,
            creatingJobID: UUID? = nil,
            creatingTaskID: UUID? = nil,
            creatingCheckpointID: UUID? = nil,
            receipts: Receipts? = nil,
            producer: ReconstructionProducerIdentity? = nil,
            evidence: [ReconstructionEvidenceRecord] = []
        ) -> ReconstructionAuthorityCut {
            let resolvedReceipts = receipts
                ?? Receipts(tool: Self.toolReceiptID, model: nil)
            return ReconstructionAuthorityCut(
                corpusManifest: manifest,
                authoritativeSubjects: authoritativeSubjects
                    ?? [.function(currentFunction)],
                facetFingerprints: facetFingerprints ?? self.facetFingerprints,
                creatingJobID: creatingJobID ?? Self.jobID,
                creatingTaskID: creatingTaskID ?? Self.taskID,
                creatingCheckpointID: creatingCheckpointID ?? Self.checkpointID,
                checkpointRevision: 9,
                operationID: .functionReview,
                toolReceiptID: resolvedReceipts.tool,
                modelReceiptID: resolvedReceipts.model,
                producer: producer ?? self.producer,
                evidence: evidence
            )
        }

        func citation(
            id: UUID,
            sourceEvidenceID: UUID?,
            subject: ReconstructionSubjectCoordinate?,
            locator: String?
        ) throws -> ReconstructionEvidenceCitation {
            try ReconstructionEvidenceCitation(
                citationID: id,
                sourceEvidenceID: sourceEvidenceID,
                subject: subject,
                locator: locator
            )
        }

        func record(
            id: UUID,
            subject: ReconstructionSubjectCoordinate,
            classification: ReconstructionEvidenceClassification = .acceptedCurrent,
            supersedesEvidenceID: UUID? = nil,
            supersededByEvidenceID: UUID? = nil
        ) throws -> ReconstructionEvidenceRecord {
            try ReconstructionEvidenceRecord(
                evidenceID: id,
                subject: subject,
                operationID: ReconstructionOperationID.functionReview.rawValue,
                payloadKind: .structuredJSON,
                payload: Self.payload,
                payloadByteCount: UInt64(Self.payload.count),
                payloadSHA256: Self.payloadSHA256,
                facetDependencies: [facetDependency],
                producer: producer,
                citations: [
                    try citation(
                        id: Self.uuid(500 + Self.idSuffix(id)),
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
                classification: classification,
                supersedesEvidenceID: supersedesEvidenceID,
                supersededByEvidenceID: supersededByEvidenceID,
                diagnostic: nil
            )
        }

        static func uuid(_ value: Int) -> UUID {
            UUID(
                uuidString: String(
                    format: "52000000-0000-0000-0000-%012d",
                    value
                )
            )!
        }

        private static func idSuffix(_ id: UUID) -> Int {
            Int(id.uuidString.suffix(4)) ?? 0
        }

        private static func makeArtifact(
            occurrenceID: UUID,
            bytes: Data
        ) throws -> ReconstructionArtifactCoordinate {
            ReconstructionArtifactCoordinate(
                occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: occurrenceID),
                contentIdentity: try ReconstructionContentIdentity(
                    algorithm: .sha256,
                    digest: CanonicalFixtureDigests.rawSHA256(bytes),
                    byteCount: UInt64(bytes.count)
                )
            )
        }

        private static func makeImageBinding(
            binaryID: UUID,
            imageSlot: ImageSlot,
            selectedSliceIndex: Int?,
            architecture: ReconstructionArchitecture
        ) -> ReconstructionImageBinding {
            ReconstructionImageBinding(
                binaryID: binaryID,
                imageSlot: imageSlot,
                selectedSliceIndex: selectedSliceIndex,
                architecture: architecture,
                machOIdentity: nil
            )
        }
    }
}

private enum CanonicalFixtureDigests {
    static func rawSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func producer(
        macScopeBuildIdentity: String = "macscope-build-acceptor-boundary",
        macScopeSourceIdentity: String = "source-build-acceptor-boundary"
    ) throws -> ReconstructionProducerIdentity {
        let capabilities = ["function-review-v1"]
        let preimage = ProducerDigestPreimage(
            schemaVersion: ReconstructionProducerIdentity.schemaVersion,
            macScopeBuildIdentity: macScopeBuildIdentity,
            macScopeSourceIdentity: macScopeSourceIdentity,
            operationIdentity: ReconstructionOperationID.functionReview.rawValue,
            registryIdentity: "reconstruction-operation-registry-v1",
            protocolIdentity: "reconstruction-evidence-v1",
            nativeProviderIdentity: "macscope-native",
            nativeCapabilityIdentities: capabilities.sorted(),
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
            canonicalSHA256: ReconstructionCanonicalJSON.sha256(of: preimage)
        )
    }

    static func manifest(
        reconstructionProjectID: UUID,
        artifacts: [ReconstructionArtifactOccurrenceRecord],
        relations: [ReconstructionArtifactRelationRecord]
    ) throws -> ReconstructionCorpusManifest {
        let sortedArtifacts = artifacts.sorted {
            $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString
        }
        let sortedRelations = relations.sorted {
            $0.relationID.uuidString < $1.relationID.uuidString
        }
        let preimage = CorpusManifestDigestPreimage(
            schemaVersion: ReconstructionCorpusManifest.schemaVersion,
            reconstructionProjectID: reconstructionProjectID,
            artifacts: sortedArtifacts,
            relations: sortedRelations
        )
        return try ReconstructionCorpusManifest(
            schemaVersion: preimage.schemaVersion,
            reconstructionProjectID: preimage.reconstructionProjectID,
            artifacts: preimage.artifacts,
            relations: preimage.relations,
            canonicalSHA256: ReconstructionCanonicalJSON.sha256(of: preimage)
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

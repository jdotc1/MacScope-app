import CryptoKit
import XCTest

@testable import MacScope

@MainActor
final class ReconstructionTask11IntegratedCandidateEvidenceTests: XCTestCase {
    private static let evidenceBindings: [Task11MixedCorpusEvidenceBinding] = [
        .init(name: "contract.h", kind: .header, role: .referenceHeader),
        .init(name: "failure.crash", kind: .diagnostic, role: .diagnosticEvidence),
        .init(name: "fixture.png", kind: .resource, role: .resource),
        .init(name: "implementation.c", kind: .source, role: .referenceSource),
    ]

    func testMixedCorpusAnalyzesDistinctBinariesAfterFailureThroughDetachedHeadlessBoundary()
        async throws
    {
        let fixture = try ReconstructionTask11MixedCorpusFixture.make()
        defer { fixture.remove() }

        let projectID = task11ID(1)
        let importResult = await ReconstructionCorpusImporter().ingest(
            selections: fixture.selections,
            projectID: projectID,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(importResult.failures.isEmpty)
        func occurrence(named name: String) throws -> ReconstructionArtifactOccurrenceRecord {
            try XCTUnwrap(importResult.occurrences.first { $0.originalName == name })
        }
        let primary = try occurrence(named: fixture.primaryName)
        let duplicate = try occurrence(named: fixture.duplicateName)
        let secondary = try occurrence(named: fixture.secondaryName)
        let failing = try occurrence(named: fixture.failingName)
        let application = try occurrence(named: fixture.applicationName)

        XCTAssertEqual(primary.kind, .machOImage)
        XCTAssertEqual(secondary.kind, .machOImage)
        XCTAssertEqual(primary.contentIdentity, duplicate.contentIdentity)
        XCTAssertNotEqual(primary.contentIdentity, secondary.contentIdentity)
        XCTAssertEqual(failing.kind, .opaque)
        XCTAssertNotNil(failing.diagnostic)

        let expectedKinds: Set<ReconstructionArtifactKind> = [
            .machOImage,
            .applicationBundle,
            .source,
            .header,
            .resource,
            .diagnostic,
            .opaque,
        ]
        XCTAssertTrue(expectedKinds.isSubset(of: Set(importResult.occurrences.map(\.kind))))
        XCTAssertTrue(importResult.relations.contains {
            $0.kind == .contains
                && application.occurrenceID == $0.sourceOccurrenceID
        })
        XCTAssertTrue(importResult.relations.contains {
            $0.kind == .unresolvedDependency
                && $0.sourceOccurrenceID == primary.occurrenceID
                && $0.targetOccurrenceID == nil
                && $0.unresolvedLocator?.isEmpty == false
        })

        let executor = ReconstructionHeadlessAnalysisExecutor(
            pool: try ReconstructionAnalysisProviderPool(
                factory: ReconstructionDefaultAnalysisProviderFactory(),
                budget: .init(
                    maximumActiveAnalyses: 2,
                    estimatedResidentBytesPerAnalysis: 1,
                    reservedHostBytes: 0
                ),
                processorCount: 2,
                physicalMemory: 2
            )
        )

        let primaryProjection = try await analyzeAndDecompile(
            occurrence: primary,
            source: try source(for: primary, in: importResult.attachmentSources),
            executor: executor,
            taskID: task11ID(10),
            jobID: task11ID(11)
        )

        var rejectedFailingInput = false
        do {
            _ = try await executor.execute(
                .init(
                    source: try source(for: failing, in: importResult.attachmentSources),
                    artifact: .init(
                        occurrenceID: failing.occurrenceID,
                        contentIdentity: failing.contentIdentity
                    ),
                    image: nil,
                    functionID: nil,
                    overrides: [:],
                    imageAuthorityIntent: .initialLoad
                ),
                cancellation: ReconstructionCancellation()
            )
        } catch {
            rejectedFailingInput = true
        }
        XCTAssertTrue(rejectedFailingInput)

        let secondaryProjection = try await analyzeAndDecompile(
            occurrence: secondary,
            source: try source(for: secondary, in: importResult.attachmentSources),
            executor: executor,
            taskID: task11ID(12),
            jobID: task11ID(13)
        )

        XCTAssertNotEqual(primaryProjection.artifact, secondaryProjection.artifact)
        XCTAssertNotEqual(primaryProjection.image.binaryID, secondaryProjection.image.binaryID)
        XCTAssertNotEqual(
            primaryProjection.analysisFingerprintSHA256,
            secondaryProjection.analysisFingerprintSHA256
        )
        XCTAssertFalse(try XCTUnwrap(primaryProjection.macScopePseudocode).isEmpty)
        XCTAssertFalse(try XCTUnwrap(secondaryProjection.macScopePseudocode).isEmpty)
        // Mutation RED: remove the second `analyzeAndDecompile` call and substitute
        // `primaryProjection` for `secondaryProjection`. The distinct artifact/image/fingerprint
        // assertions above must fail, proving this selector requires unrelated completion after
        // the deliberately rejected input rather than merely counting corpus entries.
    }

    func testMixedCorpusEvidenceBindsExactKindRoleAndRetrievesEveryAcceptedCurrentRecord()
        async throws
    {
        let fixture = try ReconstructionTask11MixedCorpusFixture.make()
        defer { fixture.remove() }
        let projectID = task11ID(300)
        let importResult = await ReconstructionCorpusImporter().ingest(
            selections: fixture.selections,
            projectID: projectID,
            cancellation: ReconstructionCancellation()
        )
        XCTAssertTrue(importResult.failures.isEmpty)

        let expectedBindings = Self.evidenceBindings
        let occurrencesByName = Dictionary(
            importResult.occurrences.compactMap { occurrence in
                occurrence.originalName.map { ($0, occurrence) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedOccurrences = try expectedBindings.map { binding in
            let occurrence = try XCTUnwrap(occurrencesByName[binding.name])
            XCTAssertEqual(occurrence.kind, binding.kind, binding.name)
            XCTAssertEqual(occurrence.roles, [binding.role], binding.name)
            return occurrence
        }
        let manifest = try makeCurrentManifest(
            projectID: projectID,
            occurrences: importResult.occurrences,
            relations: importResult.relations
        )
        XCTAssertEqual(manifest.canonicalSHA256, importResult.canonicalManifestSHA256)

        let subjects = selectedOccurrences.map { occurrence in
            ReconstructionSubjectCoordinate.artifact(.init(
                occurrenceID: occurrence.occurrenceID,
                contentIdentity: occurrence.contentIdentity
            ))
        }
        let producer = try makeEvidenceProducer()
        let jobID = task11ID(301)
        let taskID = task11ID(302)
        let checkpointID = task11ID(303)
        let toolReceiptID = task11ID(304)
        let acceptor = ReconstructionEvidenceAcceptor(
            maximumPayloadBytes: 64 * 1_024,
            maximumDiagnosticUTF8Bytes: 8 * 1_024
        )
        var accepted: [ReconstructionEvidenceRecord] = []

        for (offset, binding) in expectedBindings.enumerated() {
            let occurrence = try XCTUnwrap(occurrencesByName[binding.name])
            let subject = subjects[offset]
            let payload = try ReconstructionCanonicalJSON.encode(
                Task11MixedCorpusEvidencePayload(
                    name: binding.name,
                    kind: occurrence.kind.rawValue,
                    roles: occurrence.roles.map(\.rawValue),
                    contentSHA256: occurrence.contentIdentity.digest
                )
            )
            let candidate = try ReconstructionEvidenceCandidate(
                evidenceID: task11ID(320 + offset),
                subject: subject,
                operationID: .corpusArtifactDescribe,
                payloadKind: .structuredJSON,
                payload: payload,
                payloadByteCount: UInt64(payload.count),
                payloadSHA256: task11SHA256(payload),
                facetDependencies: [],
                producer: producer,
                citations: [try ReconstructionEvidenceCitation(
                    citationID: task11ID(340 + offset),
                    sourceEvidenceID: nil,
                    subject: subject,
                    locator: "mixed-corpus:\(binding.name)"
                )],
                creatingJobID: jobID,
                creatingTaskID: taskID,
                creatingCheckpointID: checkpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptID,
                supersedesEvidenceID: nil,
                diagnostic: nil
            )
            let record = try acceptor.validate(
                candidate,
                against: ReconstructionAuthorityCut(
                    corpusManifest: manifest,
                    authoritativeSubjects: subjects,
                    facetFingerprints: [:],
                    creatingJobID: jobID,
                    creatingTaskID: taskID,
                    creatingCheckpointID: checkpointID,
                    checkpointRevision: 11,
                    operationID: .corpusArtifactDescribe,
                    toolReceiptID: toolReceiptID,
                    modelReceiptID: nil,
                    producer: producer,
                    evidence: accepted
                )
            )
            XCTAssertEqual(record.classification, .acceptedCurrent)
            XCTAssertEqual(record.subject, subject)
            accepted.append(record)
        }
        XCTAssertEqual(accepted.count, expectedBindings.count)

        let classifications = Dictionary(uniqueKeysWithValues: accepted.map {
            ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
        })
        let checkpointRevisions = [checkpointID: UInt64(11)]
        let frontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: accepted,
            projectedClassificationsByEvidenceID: classifications,
            relations: [],
            gaps: [],
            checkpointRevisionsByID: checkpointRevisions
        )
        let cut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: accepted,
            relations: [],
            gaps: [],
            frontierSHA256: frontierSHA256,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: checkpointRevisions
        )
        let acceptedBySubject = Dictionary(
            uniqueKeysWithValues: accepted.map { ($0.subject, $0) }
        )

        for (offset, binding) in expectedBindings.enumerated() {
            let subject = subjects[offset]
            let expectedRecord = try XCTUnwrap(acceptedBySubject[subject])
            let packet = try ReconstructionRetrievalCompiler().compile(
                cut: cut,
                query: try ReconstructionRetrievalQuery(
                    corpusManifestSHA256: manifest.canonicalSHA256,
                    subject: subject,
                    operationIDs: [.corpusArtifactDescribe],
                    classifications: [.acceptedCurrent],
                    cursor: nil,
                    maximumRecords: 1,
                    maximumEncodedBytes: 64 * 1_024
                )
            )
            XCTAssertEqual(packet.records.map(\.evidenceID), [expectedRecord.evidenceID])
            XCTAssertEqual(packet.records.first?.classification, .acceptedCurrent)
            let decoded = try JSONDecoder().decode(
                Task11MixedCorpusEvidencePayload.self,
                from: try XCTUnwrap(packet.records.first?.payload)
            )
            XCTAssertEqual(decoded.name, binding.name)
            XCTAssertEqual(decoded.kind, binding.kind.rawValue)
            XCTAssertEqual(decoded.roles, [binding.role.rawValue])
        }
        // Mutation RED: swapping the source/header roles must fail their exact binding assertions.
        // Mutation RED: omitting `accepted.append(record)` must fail the four-record count and
        // exact-subject retrieval contract rather than leaving an ingestion-only false green.
    }

    private func analyzeAndDecompile(
        occurrence: ReconstructionArtifactOccurrenceRecord,
        source: ReconstructionAttachmentSource,
        executor: ReconstructionHeadlessAnalysisExecutor,
        taskID: UUID,
        jobID: UUID
    ) async throws -> ReconstructionTransientAnalysisProjection {
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: occurrence.occurrenceID,
            contentIdentity: occurrence.contentIdentity
        )
        let initial = try await executor.execute(
            .init(
                source: source,
                artifact: artifact,
                image: nil,
                functionID: nil,
                overrides: [:],
                imageAuthorityIntent: .initialLoad
            ),
            cancellation: ReconstructionCancellation()
        )
        let function = try XCTUnwrap(
            initial.detached.workspace
                .analysis(in: initial.detached.image.imageSlot)?
                .functions.first
        )
        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: initial.detached.image,
            analysisFingerprintSHA256: initial.detached.analysisInputFingerprintSHA256,
            startAddress: function.startAddress,
            endAddressExclusive: function.endAddress,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: function.id,
            symbolHint: function.name
        )
        let decompiled = try await executor.execute(
            .init(
                source: source,
                artifact: artifact,
                image: initial.detached.image,
                functionID: function.id,
                overrides: [:],
                functionCoordinate: coordinate
            ),
            cancellation: ReconstructionCancellation()
        )
        XCTAssertNotNil(decompiled.projection)
        let task = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: taskID,
                jobID: jobID,
                kind: .decompileMacScope,
                subject: .function(coordinate),
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.decompile-macscope.v1"
            ),
            state: .running,
            diagnostic: nil
        )
        return try ReconstructionTransientAnalysisProjection.project(
            task: task,
            detached: decompiled.detached
        )
    }

    private func source(
        for occurrence: ReconstructionArtifactOccurrenceRecord,
        in sources: [ReconstructionAttachmentSource]
    ) throws -> ReconstructionAttachmentSource {
        try XCTUnwrap(sources.first { $0.contentIdentity == occurrence.contentIdentity })
    }

    private func makeCurrentManifest(
        projectID: UUID,
        occurrences: [ReconstructionArtifactOccurrenceRecord],
        relations: [ReconstructionArtifactRelationRecord]
    ) throws -> ReconstructionCorpusManifest {
        let draft = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: occurrences,
            relations: relations,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        return try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: draft.artifacts,
            relations: draft.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
        )
    }

    private func makeEvidenceProducer() throws -> ReconstructionProducerIdentity {
        func producer(canonicalSHA256: String) throws -> ReconstructionProducerIdentity {
            try ReconstructionProducerIdentity(
                macScopeBuildIdentity: "task11-integrated-candidate",
                macScopeSourceIdentity: "task11-mixed-corpus",
                operationIdentity: ReconstructionOperationID.corpusArtifactDescribe.rawValue,
                registryIdentity: "reconstruction.v1",
                protocolIdentity: "reconstructionR1",
                canonicalSHA256: canonicalSHA256
            )
        }
        let draft = try producer(canonicalSHA256: String(repeating: "0", count: 64))
        return try producer(
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(draft)
        )
    }
}

private struct Task11MixedCorpusEvidenceBinding {
    let name: String
    let kind: ReconstructionArtifactKind
    let role: ReconstructionArtifactRole
}

private struct Task11MixedCorpusEvidencePayload: Codable, Equatable {
    let name: String
    let kind: String
    let roles: [String]
    let contentSHA256: String
}

private struct ReconstructionTask11MixedCorpusFixture {
    let rootURL: URL
    let primaryName = "PrimaryBinary"
    let duplicateName = "PrimaryBinaryCopy"
    let secondaryName = "SecondaryBinary"
    let failingName = "FailingBinary"
    let applicationName = "Fixture.app"
    let selections: [ReconstructionImportSelection]

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionTask11MixedCorpus-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let primaryName = "PrimaryBinary"
        let duplicateName = "PrimaryBinaryCopy"
        let secondaryName = "SecondaryBinary"
        let failingName = "FailingBinary"
        let applicationName = "Fixture.app"
        let primaryBytes = MachOFixture.makeExecutableWithLinkedLibraryMetadata().bytes
        let secondaryBytes = MachOFixture.makeExecutableWithConditionalBranches().bytes
        var failingBytes = MachOFixture.makeExecutable().bytes
        failingBytes.removeLast(4)

        let primaryURL = root.appendingPathComponent(primaryName)
        let duplicateURL = root.appendingPathComponent(duplicateName)
        let secondaryURL = root.appendingPathComponent(secondaryName)
        let failingURL = root.appendingPathComponent(failingName)
        try primaryBytes.write(to: primaryURL)
        try primaryBytes.write(to: duplicateURL)
        try secondaryBytes.write(to: secondaryURL)
        try failingBytes.write(to: failingURL)

        let applicationURL = root.appendingPathComponent(applicationName, isDirectory: true)
        let applicationMacOSURL = applicationURL.appendingPathComponent(
            "Contents/MacOS",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationMacOSURL,
            withIntermediateDirectories: true
        )
        try Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8).write(
            to: applicationURL.appendingPathComponent("Contents/Info.plist")
        )
        let applicationExecutableURL = applicationMacOSURL.appendingPathComponent("Fixture")
        try secondaryBytes.write(to: applicationExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: applicationExecutableURL.path
        )

        let sourceURL = root.appendingPathComponent("implementation.c")
        let headerURL = root.appendingPathComponent("contract.h")
        let resourceURL = root.appendingPathComponent("fixture.png")
        let diagnosticURL = root.appendingPathComponent("failure.crash")
        try Data("int task11_value(void) { return 11; }\n".utf8).write(to: sourceURL)
        try Data("#define TASK11_VALUE 11\n".utf8).write(to: headerURL)
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(
            to: resourceURL
        )
        try Data("Exception Type: EXC_BAD_ACCESS\n".utf8).write(to: diagnosticURL)

        return .init(
            rootURL: root,
            selections: [
                .init(rootURL: primaryURL, roles: [.primaryTarget]),
                .init(rootURL: duplicateURL, roles: [.auxiliary]),
                .init(rootURL: secondaryURL, roles: [.dependency]),
                .init(rootURL: failingURL, roles: [.testInput]),
                .init(rootURL: applicationURL, roles: [.auxiliary]),
                .init(rootURL: sourceURL, roles: [.referenceSource]),
                .init(rootURL: headerURL, roles: [.referenceHeader]),
                .init(rootURL: resourceURL, roles: [.resource]),
                .init(rootURL: diagnosticURL, roles: [.diagnosticEvidence]),
            ]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func task11ID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "b1100000-0000-4000-8000-%012d", value))!
}

private func task11SHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

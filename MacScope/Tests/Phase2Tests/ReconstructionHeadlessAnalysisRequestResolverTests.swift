import XCTest

@testable import MacScope

final class ReconstructionHeadlessAnalysisRequestResolverTests: XCTestCase {
    func testResolverRejectsTaskWhenBatchAuthorityIsStale() async throws {
        let fixture = try ResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source]
        )

        await XCTAssertThrowsErrorAsync(try await resolver.request(
            for: fixture.task,
            authority: fixture.authority(jobID: UUID())
        )) { error in
            XCTAssertEqual(error as? ReconstructionHeadlessAnalysisRequestResolutionError, .staleAuthority)
        }
    }

    func testResolverRejectsImageAuthorityForOccurrenceOutsideManifest() throws {
        let fixture = try ResolverFixture()
        let unknown = ReconstructionArtifactOccurrenceID(rawValue: UUID())

        XCTAssertThrowsError(try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source],
            imagesByOccurrence: [unknown: fixture.image]
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionHeadlessAnalysisRequestResolutionError,
                .missingOccurrence
            )
        }
    }

    func testResolverUsesCommittedOccurrenceWithoutConsultingUISelection() async throws {
        let fixture = try ResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source],
            overridesByOccurrence: [
                fixture.artifact.occurrenceID: [0x1000: AddressOverride(customName: "entry")]
            ]
        )

        let request = try await resolver.request(
            for: fixture.task,
            authority: fixture.authority()
        )

        XCTAssertEqual(request.artifact, fixture.artifact)
        XCTAssertEqual(request.image, fixture.image)
        XCTAssertEqual(request.functionID, fixture.functionID)
        XCTAssertEqual(request.functionCoordinate, fixture.functionCoordinate)
        XCTAssertEqual(request.imageAuthorityIntent, .existingImage)
        XCTAssertEqual(request.source.contentIdentity, fixture.artifact.contentIdentity)
        XCTAssertEqual(request.overrides[0x1000], AddressOverride(customName: "entry"))
    }

    func testResolverRejectsMissingAndContentDriftedOccurrences() async throws {
        let fixture = try ResolverFixture()
        let missing = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: []
        )
        await XCTAssertThrowsErrorAsync(try await missing.request(
            for: fixture.task,
            authority: fixture.authority()
        )) { error in
            XCTAssertEqual(error as? ReconstructionHeadlessAnalysisRequestResolutionError, .missingAttachment)
        }

        let otherIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: String(repeating: "f", count: 64),
            byteCount: 8
        )
        let drifted = ReconstructionAttachmentSource(
            contentIdentity: otherIdentity,
            verifiedURL: fixture.source.verifiedURL
        )
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [drifted]
        )
        await XCTAssertThrowsErrorAsync(try await resolver.request(
            for: fixture.task,
            authority: fixture.authority()
        )) { error in
            XCTAssertEqual(error as? ReconstructionHeadlessAnalysisRequestResolutionError, .missingAttachment)
        }

    }

    func testResolverResolvesMultipleCommittedArtifactRootsAndIsolatesPartialFailure() async throws {
        let fixture = try MultipleRootResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.sources[0]],
            imagesByOccurrence: fixture.imagesByOccurrence
        )

        let first = try await resolver.request(
            for: fixture.tasks[0],
            authority: fixture.authority
        )
        XCTAssertEqual(first.artifact, fixture.artifacts[0])
        XCTAssertNil(first.functionID)

        await XCTAssertThrowsErrorAsync(try await resolver.request(
            for: fixture.tasks[1],
            authority: fixture.authority
        )) { error in
            XCTAssertEqual(error as? ReconstructionHeadlessAnalysisRequestResolutionError, .missingAttachment)
        }

        let isolated = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: fixture.sources,
            imagesByOccurrence: fixture.imagesByOccurrence,
            overridesByOccurrence: [
                fixture.artifacts[0].occurrenceID: [
                    0x1000: AddressOverride(customName: "unrelated-ui-selection")
                ],
                fixture.artifacts[1].occurrenceID: [
                    0x1000: AddressOverride(customName: "committed-second-root")
                ],
            ]
        )
        let second = try await isolated.request(
            for: fixture.tasks[1],
            authority: fixture.authority
        )
        XCTAssertEqual(second.overrides[0x1000]?.customName, "committed-second-root")
    }

    func testResolverHonorsCancellationBeforeConsultingCommittedCut() async throws {
        let fixture = try ResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source]
        )
        let operation = Task {
            try await resolver.request(for: fixture.task, authority: fixture.authority())
        }
        operation.cancel()
        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCorpusOnlyArtifactWorkDoesNotRequireInventedImageAuthority() async throws {
        let fixture = try ResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source]
        )
        let task = ReconstructionTaskRecord(
            identity: try .init(
                taskID: UUID(),
                jobID: fixture.jobID,
                kind: .classify,
                subject: .artifact(fixture.artifact),
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.classify.v1",
                canonicalSHA256: String(repeating: "9", count: 64)
            ),
            state: .pending,
            diagnostic: nil
        )

        let request = try await resolver.request(for: task, authority: fixture.authority())

        XCTAssertNil(request.image)
        XCTAssertNil(request.functionID)
    }

    func testInitialLoadArtifactMayEstablishImageBindingWithoutCommittedMap() async throws {
        let fixture = try ResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source]
        )
        let request = try await resolver.request(
            for: try fixture.task(kind: .loadBinary, subject: .artifact(fixture.artifact)),
            authority: fixture.authority()
        )

        XCTAssertEqual(request.artifact, fixture.artifact)
        XCTAssertNil(request.image)
        XCTAssertNil(request.functionID)
        XCTAssertNil(request.functionCoordinate)
        XCTAssertEqual(request.imageAuthorityIntent, .initialLoad)
    }

    func testIndexAndEnumerationRequireImageScopedCommittedAuthority() async throws {
        let fixture = try ResolverFixture()
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source],
            imagesByOccurrence: [fixture.artifact.occurrenceID: fixture.image]
        )
        let image = try ReconstructionImageCoordinate(
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: fixture.functionCoordinate.analysisFingerprintSHA256
        )

        for kind in [ReconstructionTaskKind.indexImage, .enumerateFunctions] {
            await XCTAssertThrowsErrorAsync(try await resolver.request(
                for: try fixture.task(kind: kind, subject: .artifact(fixture.artifact)),
                authority: fixture.authority()
            )) { error in
                XCTAssertEqual(
                    error as? ReconstructionHeadlessAnalysisRequestResolutionError,
                    .unsupportedTask
                )
            }

            let request = try await resolver.request(
                for: try fixture.task(kind: kind, subject: .image(image)),
                authority: fixture.authority()
            )
            XCTAssertEqual(request.artifact, fixture.artifact)
            XCTAssertEqual(request.image, fixture.image)
            XCTAssertEqual(request.imageAuthorityIntent, .existingImage)
        }
    }

    func testFunctionCoordinateRemainsAuthorityWhenUUIDHintIsAbsent() async throws {
        let fixture = try ResolverFixture()
        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: fixture.image,
            analysisFingerprintSHA256: fixture.functionCoordinate.analysisFingerprintSHA256,
            startAddress: fixture.functionCoordinate.startAddress,
            endAddressExclusive: fixture.functionCoordinate.endAddressExclusive,
            boundarySchemaVersion: fixture.functionCoordinate.boundarySchemaVersion,
            functionUUIDHint: nil,
            symbolHint: fixture.functionCoordinate.symbolHint
        )
        let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
            manifest: fixture.manifest,
            attachmentSources: [fixture.source]
        )
        let request = try await resolver.request(
            for: try fixture.task(kind: .decompileMacScope, subject: .function(coordinate)),
            authority: fixture.authority()
        )

        XCTAssertNil(request.functionID)
        XCTAssertEqual(request.functionCoordinate, coordinate)
        XCTAssertEqual(request.imageAuthorityIntent, .existingImage)
    }
}

private struct ResolverFixture {
    let jobID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let checkpointID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let functionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let manifest: ReconstructionCorpusManifest
    let source: ReconstructionAttachmentSource
    let functionCoordinate: ReconstructionFunctionCoordinate
    let task: ReconstructionTaskRecord

    init() throws {
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: String(repeating: "a", count: 64),
            byteCount: 8
        )
        let occurrenceID = ReconstructionArtifactOccurrenceID(
            rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        )
        artifact = .init(occurrenceID: occurrenceID, contentIdentity: identity)
        image = .init(
            binaryID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: occurrenceID,
            contentIdentity: identity,
            kind: .machOImage,
            roles: [.primaryTarget],
            executableMode: true,
            originalName: "fixture",
            diagnostic: nil
        )
        let draft = try ReconstructionCorpusManifest(
            reconstructionProjectID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            artifacts: [occurrence],
            relations: [],
            canonicalSHA256: String(repeating: "b", count: 64)
        )
        manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: draft.reconstructionProjectID,
            artifacts: draft.artifacts,
            relations: draft.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
        )
        source = ReconstructionAttachmentSource(
            contentIdentity: identity,
            verifiedURL: URL(fileURLWithPath: "/private/tmp/reconstruction-resolver-fixture")
        )
        functionCoordinate = try ReconstructionFunctionCoordinate(
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: String(repeating: "c", count: 64),
            startAddress: 0x1000,
            endAddressExclusive: 0x1008,
            boundarySchemaVersion: 1,
            functionUUIDHint: functionID,
            symbolHint: "entry"
        )
        task = .init(
            identity: try .init(
                taskID: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
                jobID: jobID,
                kind: .decompileNative,
                subject: .function(functionCoordinate),
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.native-decompile.v1",
                canonicalSHA256: String(repeating: "d", count: 64)
            ),
            state: .pending,
            diagnostic: nil
        )
    }

    func authority(jobID: UUID? = nil) -> ReconstructionBatchAuthority {
        try! .init(
            jobID: jobID ?? self.jobID,
            checkpointID: checkpointID,
            checkpointRevision: 2,
            corpusManifestSHA256: manifest.canonicalSHA256
        )
    }

    func task(
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate
    ) throws -> ReconstructionTaskRecord {
        .init(
            identity: try .init(
                taskID: UUID(),
                jobID: jobID,
                kind: kind,
                subject: subject,
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.resolver-test.v1",
                canonicalSHA256: String(repeating: "e", count: 64)
            ),
            state: .pending,
            diagnostic: nil
        )
    }
}

private struct MultipleRootResolverFixture {
    let jobID = UUID(uuidString: "81000000-0000-0000-0000-000000000081")!
    let checkpointID = UUID(uuidString: "82000000-0000-0000-0000-000000000082")!
    let artifacts: [ReconstructionArtifactCoordinate]
    let manifest: ReconstructionCorpusManifest
    let sources: [ReconstructionAttachmentSource]
    let imagesByOccurrence: [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding]
    let tasks: [ReconstructionTaskRecord]
    let authority: ReconstructionBatchAuthority

    init() throws {
        var artifacts: [ReconstructionArtifactCoordinate] = []
        var occurrences: [ReconstructionArtifactOccurrenceRecord] = []
        var sources: [ReconstructionAttachmentSource] = []
        var images: [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding] = [:]
        var tasks: [ReconstructionTaskRecord] = []
        for index in 1...2 {
            let identity = try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: String(repeating: index == 1 ? "1" : "2", count: 64),
                byteCount: UInt64(index)
            )
            let occurrenceID = ReconstructionArtifactOccurrenceID(
                rawValue: UUID(uuidString: "83000000-0000-0000-0000-00000000008\(index)")!
            )
            let artifact = ReconstructionArtifactCoordinate(
                occurrenceID: occurrenceID,
                contentIdentity: identity
            )
            artifacts.append(artifact)
            occurrences.append(try .init(
                occurrenceID: occurrenceID,
                contentIdentity: identity,
                kind: .machOImage,
                roles: [.primaryTarget],
                executableMode: true,
                originalName: "root-\(index)",
                diagnostic: nil
            ))
            sources.append(.init(
                contentIdentity: identity,
                verifiedURL: URL(fileURLWithPath: "/private/tmp/root-\(index)")
            ))
            images[occurrenceID] = .init(
                binaryID: UUID(uuidString: "84000000-0000-0000-0000-00000000008\(index)")!,
                imageSlot: index == 1 ? .primary : ImageSlot(rawValue: 1),
                selectedSliceIndex: nil,
                architecture: .arm64,
                machOIdentity: nil
            )
            tasks.append(.init(
                identity: try .init(
                    taskID: UUID(uuidString: "85000000-0000-0000-0000-00000000008\(index)")!,
                    jobID: jobID,
                    kind: .enumerateFunctions,
                    subject: .image(try ReconstructionImageCoordinate(
                        artifact: artifact,
                        image: images[occurrenceID]!,
                        analysisFingerprintSHA256: String(repeating: "6", count: 64)
                    )),
                    dependencyTaskIDs: [],
                    operationContractIdentity: "reconstruction.enumerate.v1",
                    canonicalSHA256: String(repeating: index == 1 ? "3" : "4", count: 64)
                ),
                state: .pending,
                diagnostic: nil
            ))
        }
        let draft = try ReconstructionCorpusManifest(
            reconstructionProjectID: UUID(uuidString: "86000000-0000-0000-0000-000000000086")!,
            artifacts: occurrences,
            relations: [],
            canonicalSHA256: String(repeating: "5", count: 64)
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: draft.reconstructionProjectID,
            artifacts: draft.artifacts,
            relations: draft.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
        )
        self.artifacts = artifacts
        self.manifest = manifest
        self.sources = sources
        self.imagesByOccurrence = images
        self.tasks = tasks
        self.authority = try .init(
            jobID: jobID,
            checkpointID: checkpointID,
            checkpointRevision: 1,
            corpusManifestSHA256: manifest.canonicalSHA256
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

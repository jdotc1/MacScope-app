import Darwin
import Foundation
import Synchronization
import XCTest
@testable import MacScope

final class WorkspacePackageVersionProbeTests: XCTestCase {
    func testCancellationAtEachCancellableValidationBoundaryEscapesWithoutRetraversal() async throws {
        try await withReconstructionPackageFixture { fixture in
            for cancellationPoint in [
                "tree-enumeration",
                "manifest-validation",
                "reconstruction-graph-validation",
                "package-contents-validation",
            ] {
                let tracker = ProbeCancellationTracker(target: cancellationPoint)
                let probe = probe(
                    beforeCancellableWork: tracker.cancelIfTarget,
                    beforeTreeSnapshot: tracker.recordTreeSnapshot
                )

                let observation = Task {
                    try await probe.observe(fixture.packageURL)
                }
                let error: Error?
                do {
                    _ = try await observation.value
                    error = nil
                } catch let caughtError {
                    error = caughtError
                }

                XCTAssertTrue(error is CancellationError, cancellationPoint)
                XCTAssertEqual(tracker.treeSnapshotAttempts, 1, cancellationPoint)
            }
        }
    }

    func testManifestAndAttachmentCaptureBudgetsFailClosedBeforeUnboundedDataCapture() async throws {
        try await withPackageFixture { fixture in
            let observation = try await probe(
                limits: WorkspacePackageVersionProbe.Limits(
                    maximumManifestCaptureBytes: 1
                )
            ).observe(fixture.packageURL)

            XCTAssertEqual(observation.condition, .invalid)
            XCTAssertEqual(observation.boundedReason, "package-file-too-large")
        }

        for (name, limits, expectedReason) in [
            (
                "single-attachment",
                WorkspacePackageVersionProbe.Limits(
                    maximumAttachmentCaptureBytes: 3
                ),
                "package-file-too-large"
            ),
            (
                "total-attachments",
                WorkspacePackageVersionProbe.Limits(
                    maximumAttachmentCaptureBytes: 4,
                    maximumTotalAttachmentCaptureBytes: 3
                ),
                "package-attachment-capture-budget-exceeded"
            ),
        ] {
            try await withPackageFixture { fixture in
                let observation = try await probe(limits: limits).observe(
                    fixture.packageURL
                )

                XCTAssertEqual(observation.condition, .invalid, name)
                XCTAssertEqual(observation.boundedReason, expectedReason, name)
            }
        }
    }

    func testTreeEnumerationEntryAndNameByteBudgetsFailClosed() async throws {
        for (name, limits, expectedReason) in [
            (
                "entry-count",
                WorkspacePackageVersionProbe.Limits(maximumTreeEntryCount: 3),
                "package-tree-entry-budget-exceeded"
            ),
            (
                "name-bytes",
                WorkspacePackageVersionProbe.Limits(maximumTreeNameBytes: 1),
                "package-tree-name-byte-budget-exceeded"
            ),
        ] {
            try await withPackageFixture { fixture in
                let observation = try await probe(limits: limits).observe(
                    fixture.packageURL
                )

                XCTAssertEqual(observation.condition, .invalid, name)
                XCTAssertEqual(observation.boundedReason, expectedReason, name)
            }
        }
    }

    func testStableEmptyReconstructionLikeDirectoriesMatchDirectOpenCaseInsensitively() async throws {
        for relativePath in [
            "Reconstruction-extra",
            "rEcOnStRuCtIoN-shadow",
        ] {
            try await withReconstructionPackageFixture { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.packageURL.appendingPathComponent(
                        relativePath,
                        isDirectory: true
                    ),
                    withIntermediateDirectories: false
                )

                XCTAssertThrowsError(
                    try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                    relativePath
                )
                let observation = try await WorkspacePackageVersionProbe().observe(
                    fixture.packageURL
                )
                XCTAssertEqual(observation.condition, .invalid, relativePath)
            }
        }
    }

    func testLargeInventoryBuildsOneIndexPerSnapshotAndUsesBoundedDeclaredLookups() async throws {
        try await withPackageFixture { fixture in
            let extraDirectoryCount = 1_024
            for index in 0..<extraDirectoryCount {
                try FileManager.default.createDirectory(
                    at: fixture.packageURL.appendingPathComponent(
                        String(format: ".inventory-%04d", index),
                        isDirectory: true
                    ),
                    withIntermediateDirectories: false
                )
            }
            let metrics = ProbeInventoryMetrics()
            let probe = probe(
                didBuildTreeIndex: metrics.recordIndex,
                didUseTreeIndex: metrics.recordIndexedLookup
            )

            let observation = try await probe.observe(fixture.packageURL)

            XCTAssertEqual(observation.condition, .valid)
            XCTAssertEqual(
                metrics.indexedEntryCounts,
                [extraDirectoryCount + 5, extraDirectoryCount + 5]
            )
            XCTAssertEqual(metrics.indexedLookupCount, 5)
        }
    }

    func testCanonicalEmptyVersion3IsInvalidForProbeAndDirectOpen() async throws {
        let root = temporaryURL("empty-v3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = packageFixture(at: root.appendingPathComponent("fixture.mscope"))
        try writeCanonicalEmptyVersion3Package(fixture)

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        )

        let observation = try await WorkspacePackageVersionProbe().observe(fixture.packageURL)

        XCTAssertEqual(observation.condition, .invalid)
    }

    func testVersion3BlankBinaryHashWithSameLengthSubstitutionIsInvalidEverywhere()
        async throws
    {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        var manifest = try MacScopeDocumentPackage.readManifest(from: fixture.packageURL)
        let binary = try XCTUnwrap(manifest.binaries.first)
        manifest.binaries[0].fileHash = ""
        try MacScopeDocumentPackage.encodedManifest(manifest).write(
            to: manifestURL,
            options: .atomic
        )
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: fixture.packageURL,
            relativePath: binary.attachmentRelativePath
        )
        let substituted = Data(fixture.binaryBytes.map { $0 ^ 0xff })
        XCTAssertEqual(substituted.count, fixture.binaryBytes.count)
        XCTAssertNotEqual(substituted, fixture.binaryBytes)
        try substituted.write(to: attachmentURL, options: .atomic)

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .invalidAttachmentHash(binary.attachmentRelativePath)
            )
        }
        let observation = try await WorkspacePackageVersionProbe().observe(fixture.packageURL)
        XCTAssertEqual(observation.condition, .invalid)
    }

    func testManifestAndOrdinaryBinarySymlinkAndHardLinkLeavesAreInvalidEverywhere()
        async throws
    {
        for leaf in ["manifest", "binary"] {
            for linkKind in ["symbolic-link", "hard-link"] {
                let fixture = try ReconstructionPackageFixture.make()
                defer { fixture.remove() }
                try fixture.write()
                let leafURL: URL
                if leaf == "manifest" {
                    leafURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
                } else {
                    let manifest = try MacScopeDocumentPackage.readManifest(from: fixture.packageURL)
                    let binary = try XCTUnwrap(manifest.binaries.first)
                    leafURL = try MacScopeDocumentPackage.attachmentURL(
                        in: fixture.packageURL,
                        relativePath: binary.attachmentRelativePath
                    )
                }
                let externalURL = fixture.root.appendingPathComponent(
                    "external-\(leaf)-\(linkKind)"
                )
                try FileManager.default.moveItem(at: leafURL, to: externalURL)
                if linkKind == "symbolic-link" {
                    try FileManager.default.createSymbolicLink(
                        at: leafURL,
                        withDestinationURL: externalURL
                    )
                } else {
                    try FileManager.default.linkItem(at: externalURL, to: leafURL)
                }

                let context = "\(leaf) \(linkKind)"
                XCTAssertThrowsError(
                    try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                    context
                )
                let observation = try await WorkspacePackageVersionProbe().observe(
                    fixture.packageURL
                )
                XCTAssertEqual(observation.condition, .invalid, context)
            }
        }
    }

    func testVersion3ObservationBindsCanonicalManifestsAndCorpusObjects() async throws {
        let root = temporaryURL("reconstruction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = packageFixture(at: root.appendingPathComponent("fixture.mscope"))
        let corpusBytes = Data("probe reconstruction corpus".utf8)
        let sourceURL = root.appendingPathComponent("source.bin")
        try corpusBytes.write(to: sourceURL)
        let identity = try contentIdentity(for: corpusBytes)
        let state = try reconstructionState(contentIdentity: identity)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachments,
            reconstructionState: state,
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: identity,
                    verifiedURL: sourceURL
                ),
            ],
            to: fixture.packageURL
        )
        let probe = WorkspacePackageVersionProbe()

        let initial = try await probe.observe(fixture.packageURL)
        XCTAssertEqual(initial.condition, .valid)

        let attachmentURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
            in: fixture.packageURL,
            contentIdentity: identity
        )
        try Data(repeating: 0x5a, count: corpusBytes.count).write(
            to: attachmentURL,
            options: .atomic
        )
        let mutated = try await probe.observe(fixture.packageURL)
        XCTAssertEqual(mutated.condition, .invalid)
        XCTAssertNotEqual(mutated.observationSHA256, initial.observationSHA256)
    }

    func testVersion3ObservationRejectsUndeclaredReconstructionLeaf() async throws {
        let root = temporaryURL("reconstruction-extra-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = packageFixture(at: root.appendingPathComponent("fixture.mscope"))
        let corpusBytes = Data("probe reconstruction corpus".utf8)
        let sourceURL = root.appendingPathComponent("source.bin")
        try corpusBytes.write(to: sourceURL)
        let identity = try contentIdentity(for: corpusBytes)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachments,
            reconstructionState: try reconstructionState(contentIdentity: identity),
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: identity,
                    verifiedURL: sourceURL
                ),
            ],
            to: fixture.packageURL
        )
        try Data("undeclared".utf8).write(
            to: fixture.packageURL.appendingPathComponent("Reconstruction/undeclared.bin")
        )

        let observation = try await WorkspacePackageVersionProbe().observe(fixture.packageURL)

        XCTAssertEqual(observation.condition, .invalid)
    }

    func testVersion3InvalidHardLinkObservationBindsSameSizeAliasMutation() async throws {
        let root = temporaryURL("reconstruction-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = packageFixture(at: root.appendingPathComponent("fixture.mscope"))
        let corpusBytes = Data("probe reconstruction corpus".utf8)
        let sourceURL = root.appendingPathComponent("source.bin")
        try corpusBytes.write(to: sourceURL)
        let identity = try contentIdentity(for: corpusBytes)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachments,
            reconstructionState: try reconstructionState(contentIdentity: identity),
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: identity,
                    verifiedURL: sourceURL
                ),
            ],
            to: fixture.packageURL
        )
        let attachmentURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
            in: fixture.packageURL,
            contentIdentity: identity
        )
        try FileManager.default.removeItem(at: attachmentURL)
        try FileManager.default.linkItem(at: sourceURL, to: attachmentURL)

        let probe = WorkspacePackageVersionProbe()
        let baseline = try await probe.observe(fixture.packageURL)

        let mutatedBytes = Data(repeating: 0x5a, count: corpusBytes.count)
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: mutatedBytes)
        try handle.synchronize()
        try handle.close()
        let mutated = try await probe.observe(fixture.packageURL)

        XCTAssertEqual(baseline.condition, .invalid)
        XCTAssertEqual(mutated.condition, .invalid)
        XCTAssertNotEqual(mutated.observationSHA256, baseline.observationSHA256)
    }

    func testValidObservationIsStableAcrossModeChangesButBindsManifestBytes() async throws {
        try await withPackageFixture { fixture in
            let probe = WorkspacePackageVersionProbe()
            let first = try await probe.observe(fixture.packageURL)
            XCTAssertEqual(first.condition, .valid)

            let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
                in: fixture.packageURL,
                relativePath: fixture.manifest.binaries[0].attachmentRelativePath
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: attachmentURL.path
            )
            let modeChanged = try await probe.observe(fixture.packageURL)
            XCTAssertEqual(modeChanged, first)

            let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            let compact = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try compact.write(to: manifestURL, options: .atomic)
            let reformatted = try await probe.observe(fixture.packageURL)

            XCTAssertEqual(reformatted.condition, .valid)
            XCTAssertNotEqual(reformatted.observationSHA256, first.observationSHA256)
            XCTAssertNotEqual(reformatted.manifestSHA256, first.manifestSHA256)
            XCTAssertEqual(reformatted.validatedContentSHA256, first.validatedContentSHA256)
        }
    }

    func testNestedAttachmentMutationIsDetectedWhenDirectoryMTimeIsRestored() async throws {
        try await withPackageFixture { fixture in
            let probe = WorkspacePackageVersionProbe()
            let first = try await probe.observe(fixture.packageURL)
            let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
                in: fixture.packageURL,
                relativePath: fixture.manifest.binaries[0].attachmentRelativePath
            )
            let parentURL = attachmentURL.deletingLastPathComponent()
            let priorDate = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: parentURL.path)[.modificationDate] as? Date
            )
            try Data([0xde, 0xad, 0xbe, 0xef]).write(to: attachmentURL, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: priorDate], ofItemAtPath: parentURL.path)

            let changed = try await probe.observe(fixture.packageURL)
            XCTAssertEqual(changed.condition, .invalid)
            XCTAssertNotEqual(changed.observationSHA256, first.observationSHA256)
            XCTAssertFalse(changed.boundedReason?.contains(fixture.packageURL.path) == true)
        }
    }

    func testAbsentCorruptAndPartialPackagesProduceBoundedConditions() async throws {
        let root = temporaryURL("conditions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let absentURL = root.appendingPathComponent("absent.mscope")
        let probe = WorkspacePackageVersionProbe()

        let absent = try await probe.observe(absentURL)
        XCTAssertEqual(absent.condition, .absent)
        XCTAssertNil(absent.manifestSHA256)
        XCTAssertFalse(absent.observationSHA256.contains(root.path))

        let corruptURL = root.appendingPathComponent("corrupt.mscope")
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: MacScopeDocumentPackage.manifestURL(in: corruptURL))
        let corrupt = try await probe.observe(corruptURL)
        XCTAssertEqual(corrupt.condition, .invalid)
        XCTAssertLessThanOrEqual(corrupt.boundedReason?.utf8.count ?? 0, 256)
        XCTAssertFalse(corrupt.boundedReason?.contains(root.path) == true)

        let partialFixture = packageFixture(at: root.appendingPathComponent("partial.mscope"))
        try FileManager.default.createDirectory(
            at: partialFixture.packageURL,
            withIntermediateDirectories: true
        )
        try MacScopeDocumentPackage.encodedManifest(partialFixture.manifest)
            .write(to: MacScopeDocumentPackage.manifestURL(in: partialFixture.packageURL))
        let partial = try await probe.observe(partialFixture.packageURL)
        XCTAssertEqual(partial.condition, .invalid)
    }

    func testSymlinkAndUnsupportedSpecialLeavesAreInvalid() async throws {
        try await withPackageFixture { fixture in
            let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
                in: fixture.packageURL,
                relativePath: fixture.manifest.binaries[0].attachmentRelativePath
            )
            try FileManager.default.removeItem(at: attachmentURL)
            try FileManager.default.createSymbolicLink(
                at: attachmentURL,
                withDestinationURL: MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
            )
            let observation = try await WorkspacePackageVersionProbe().observe(
                fixture.packageURL
            )
            XCTAssertEqual(observation.condition, .invalid)
        }

        try await withPackageFixture { fixture in
            let fifoURL = fixture.packageURL.appendingPathComponent("unsupported.fifo")
            let result = fifoURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkfifo(path, 0o600)
            }
            XCTAssertEqual(result, 0)
            let observation = try await WorkspacePackageVersionProbe().observe(
                fixture.packageURL
            )
            XCTAssertEqual(observation.condition, .invalid)
        }
    }

    func testUndeclaredRegularLeafIsInvalid() async throws {
        try await withPackageFixture { fixture in
            try Data("hidden".utf8).write(
                to: fixture.packageURL.appendingPathComponent("undeclared.bin")
            )
            let observation = try await WorkspacePackageVersionProbe().observe(fixture.packageURL)
            XCTAssertEqual(observation.condition, .invalid)
        }
    }

    func testInjectedMidProbeMutationBecomesUnverifiable() async throws {
        try await withPackageFixture { fixture in
            let relativePath = fixture.manifest.binaries[0].attachmentRelativePath
            let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
                in: fixture.packageURL,
                relativePath: relativePath
            )
            let probe = WorkspacePackageVersionProbe(
                beforeReadingRelativePath: { observedPath in
                    guard observedPath == relativePath else { return }
                    try? Data([0x10, 0x20, 0x30, 0x40]).write(
                        to: attachmentURL,
                        options: .atomic
                    )
                }
            )

            let observation = try await probe.observe(fixture.packageURL)
            XCTAssertEqual(observation.condition, .unverifiable)
            XCTAssertLessThanOrEqual(observation.boundedReason?.utf8.count ?? 0, 256)
            XCTAssertFalse(observation.boundedReason?.contains(fixture.packageURL.path) == true)
        }
    }

    private struct Fixture {
        let packageURL: URL
        let manifest: WorkspacePackageManifest
        let attachments: [UUID: Data]
    }

    private func withPackageFixture(
        _ operation: (Fixture) async throws -> Void
    ) async throws {
        let packageURL = temporaryURL(UUID().uuidString).appendingPathExtension("mscope")
        let fixture = packageFixture(at: packageURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachments,
            to: fixture.packageURL
        )
        try await operation(fixture)
    }

    private func withReconstructionPackageFixture(
        _ operation: (Fixture) async throws -> Void
    ) async throws {
        let root = temporaryURL("reconstruction-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = packageFixture(at: root.appendingPathComponent("fixture.mscope"))
        let corpusBytes = Data("probe reconstruction corpus".utf8)
        let sourceURL = root.appendingPathComponent("source.bin")
        try corpusBytes.write(to: sourceURL)
        let identity = try contentIdentity(for: corpusBytes)
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.attachments,
            reconstructionState: try reconstructionState(contentIdentity: identity),
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: identity,
                    verifiedURL: sourceURL
                ),
            ],
            to: fixture.packageURL
        )
        try await operation(fixture)
    }

    private func probe(
        limits: WorkspacePackageVersionProbe.Limits = .init(),
        beforeCancellableWork: @escaping @Sendable (String) -> Void = { _ in },
        beforeTreeSnapshot: @escaping @Sendable () -> Void = {},
        didBuildTreeIndex: @escaping @Sendable (Int) -> Void = { _ in },
        didUseTreeIndex: @escaping @Sendable (String) -> Void = { _ in }
    ) -> WorkspacePackageVersionProbe {
        WorkspacePackageVersionProbe(
            limits: limits,
            beforeCancellableWork: beforeCancellableWork,
            beforeTreeSnapshot: beforeTreeSnapshot,
            didBuildTreeIndex: didBuildTreeIndex,
            didUseTreeIndex: didUseTreeIndex
        )
    }

    private func packageFixture(at packageURL: URL) -> Fixture {
        let binaryID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let attachment = Data([0xca, 0xfe, 0xba, 0xbe])
        let relativePath = "attachments/\(binaryID.uuidString.lowercased())/fixture.bin"
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
            workspaceUUID: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
            workspaceName: "Observation Fixture",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_001),
            binaries: [
                WorkspacePackageBinary(
                    id: binaryID,
                    displayName: "Observation Fixture",
                    originalPath: "/fixture/observation.bin",
                    attachmentRelativePath: relativePath,
                    kind: "Raw data",
                    architecture: "arm64",
                    fileHash: MacScopeDocumentPackage.fileHash(for: attachment),
                    fileSize: Int64(attachment.count)
                )
            ],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )
        return Fixture(
            packageURL: packageURL,
            manifest: manifest,
            attachments: [binaryID: attachment]
        )
    }

    private func contentIdentity(for data: Data) throws -> ReconstructionContentIdentity {
        try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: MacScopeDocumentPackage.fileHash(for: data),
            byteCount: UInt64(data.count)
        )
    }

    private func writeCanonicalEmptyVersion3Package(_ fixture: Fixture) throws {
        let seedIdentity = try contentIdentity(for: fixture.attachments.values.first ?? Data())
        var manifest = try MacScopeDocumentPackage.preparedManifest(
            fixture.manifest,
            reconstructionState: try reconstructionState(contentIdentity: seedIdentity)
        )
        let empty = try ReconstructionPackageCodec.encode(.empty)
        manifest.reconstruction = empty.descriptor

        try MacScopeDocumentPackage.preparePackageDirectory(
            at: fixture.packageURL,
            for: manifest
        )
        for binary in manifest.binaries {
            let bytes = try XCTUnwrap(fixture.attachments[binary.id])
            try bytes.write(
                to: MacScopeDocumentPackage.attachmentURL(
                    in: fixture.packageURL,
                    relativePath: binary.attachmentRelativePath
                )
            )
        }
        for (relativePath, data) in [
            (ReconstructionPackageLayout.corpusManifestPath, empty.corpusData),
            (ReconstructionPackageLayout.evidenceManifestPath, empty.evidenceData),
            (ReconstructionPackageLayout.checkpointManifestPath, empty.checkpointData),
        ] {
            let url = relativePath.split(separator: "/").reduce(fixture.packageURL) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        try MacScopeDocumentPackage.encodedManifest(manifest).write(
            to: MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        )
    }

    private func reconstructionState(
        contentIdentity: ReconstructionContentIdentity
    ) throws -> ReconstructionWorkspaceState {
        let projectID = UUID()
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
            contentIdentity: contentIdentity,
            kind: .opaque,
            roles: [.primaryTarget],
            executableMode: false,
            originalName: "source.bin",
            diagnostic: nil
        )
        let manifestSHA256 = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: []
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: [],
            canonicalSHA256: manifestSHA256
        )
        return try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Probe reconstruction",
                    currentCorpusManifestSHA256: manifest.canonicalSHA256
                ),
            ],
            corpusManifests: [manifest],
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

    private func temporaryURL(_ component: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePackageVersionProbeTests-\(component)")
    }
}

private final class ProbeCancellationTracker: Sendable {
    private struct State: Sendable {
        var treeSnapshotAttempts = 0
        var didCancel = false
    }

    private let target: String
    private let state = Mutex(State())

    init(target: String) {
        self.target = target
    }

    var treeSnapshotAttempts: Int {
        state.withLock { $0.treeSnapshotAttempts }
    }

    func cancelIfTarget(_ checkpoint: String) {
        guard checkpoint == target else { return }
        let shouldCancel = state.withLock { state in
            guard !state.didCancel else { return false }
            state.didCancel = true
            return true
        }
        guard shouldCancel else { return }
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
    }

    func recordTreeSnapshot() {
        state.withLock { $0.treeSnapshotAttempts += 1 }
    }
}

private final class ProbeInventoryMetrics: Sendable {
    private struct State: Sendable {
        var indexedEntryCounts: [Int] = []
        var indexedLookupCount = 0
    }

    private let state = Mutex(State())

    var indexedEntryCounts: [Int] {
        state.withLock { $0.indexedEntryCounts }
    }

    var indexedLookupCount: Int {
        state.withLock { $0.indexedLookupCount }
    }

    func recordIndex(entryCount: Int) {
        state.withLock { $0.indexedEntryCounts.append(entryCount) }
    }

    func recordIndexedLookup(relativePath: String) {
        state.withLock { $0.indexedLookupCount += 1 }
    }
}

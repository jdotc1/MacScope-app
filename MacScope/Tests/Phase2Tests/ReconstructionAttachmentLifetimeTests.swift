import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ReconstructionAttachmentLifetimeTests: XCTestCase {
    func testSourceCopiesRetainOwnedAttachmentUntilTheFinalCopyIsReleased() throws {
        let parent = try makeTemporaryDirectory(named: "source-copies")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedURL = parent.appendingPathComponent("owned.bin")
        let siblingURL = parent.appendingPathComponent("unowned.bin")
        let bytes = Data("copy-retained attachment".utf8)
        try bytes.write(to: ownedURL)
        try Data("unowned sibling".utf8).write(to: siblingURL)

        var lifetime: ReconstructionAttachmentLifetime? = ReconstructionAttachmentLifetime(
            owning: ownedURL,
            creationIdentity: try creationIdentity(for: ownedURL)
        )
        weak var weakLifetime = lifetime
        var source: ReconstructionAttachmentSource? = ReconstructionAttachmentSource(
            contentIdentity: try contentIdentity(for: bytes),
            verifiedURL: ownedURL,
            lifetimeToken: lifetime
        )
        var copiedSource = source
        lifetime = nil
        source = nil

        XCTAssertNotNil(weakLifetime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))
        copiedSource = nil

        XCTAssertNil(weakLifetime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    func testExplicitDiscardIsIdempotentAndRemovesOnlyTheOwnedRoot() throws {
        let parent = try makeTemporaryDirectory(named: "explicit-discard")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedRoot = parent.appendingPathComponent("owned", isDirectory: true)
        let siblingRoot = parent.appendingPathComponent("unowned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: false)
        try Data("owned".utf8).write(to: ownedRoot.appendingPathComponent("payload"))
        try Data("unowned".utf8).write(to: siblingRoot.appendingPathComponent("payload"))

        let lifetime = ReconstructionAttachmentLifetime(
            owning: ownedRoot,
            creationIdentity: try creationIdentity(for: ownedRoot, isDirectory: true)
        )
        let source = ReconstructionAttachmentSource(
            contentIdentity: try contentIdentity(for: Data("owned".utf8)),
            verifiedURL: ownedRoot.appendingPathComponent("payload"),
            lifetimeToken: lifetime
        )

        lifetime.discard()
        lifetime.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingRoot.path))
        withExtendedLifetime(source) {}
    }

    func testReplacementCreatedAfterCleanupDetachesOwnedObjectSurvives() async throws {
        let parent = try makeTemporaryDirectory(named: "replacement-after-detach")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedRoot = parent.appendingPathComponent("attachment", isDirectory: true)
        let replacement = Data("replacement created after detach".utf8)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        try Data("owned recursively deleted payload".utf8).write(
            to: ownedRoot.appendingPathComponent("owned.bin")
        )
        let creationIdentity = try creationIdentity(for: ownedRoot, isDirectory: true)
        let barrier = CleanupDetachBarrier()
        let lifetime = ReconstructionAttachmentLifetime(
            owning: ownedRoot,
            creationIdentity: creationIdentity,
            cleanupHooks: .init(afterAtomicDetach: barrier.afterAtomicDetach)
        )
        defer { barrier.resumeCleanup() }

        let cleanup = Task.detached {
            lifetime.discard()
        }
        let quarantineURL = try XCTUnwrap(barrier.waitForDetach())

        XCTAssertEqual(
            quarantineURL.deletingLastPathComponent().standardizedFileURL,
            ownedRoot.deletingLastPathComponent().standardizedFileURL
        )
        XCTAssertNotEqual(quarantineURL.standardizedFileURL, ownedRoot.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))

        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        let replacementURL = ownedRoot.appendingPathComponent("replacement.bin")
        try replacement.write(to: replacementURL)
        barrier.resumeCleanup()
        await cleanup.value

        XCTAssertEqual(try Data(contentsOf: replacementURL), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testReplacementInstalledAfterDetachedDescriptorVerificationIsPreserved() async throws {
        let parent = try makeTemporaryDirectory(named: "replacement-after-verification")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedRoot = parent.appendingPathComponent("attachment", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        let ownedPayload = Data("creator-owned payload".utf8)
        try ownedPayload.write(to: ownedRoot.appendingPathComponent("owned.bin"))
        let barrier = CleanupVerifiedObjectBarrier()
        let lifetime = ReconstructionAttachmentLifetime(
            owning: ownedRoot,
            creationIdentity: try creationIdentity(for: ownedRoot, isDirectory: true),
            cleanupHooks: .init(
                beforeRemovingVerifiedDetachedObject: barrier.beforeRemoval
            )
        )
        defer { barrier.resumeCleanup() }

        let cleanup = Task.detached {
            lifetime.discard()
        }
        let detachedURL = try XCTUnwrap(barrier.waitForVerifiedObject())
        let preservedOwnedURL = parent.appendingPathComponent("preserved-owned", isDirectory: true)
        try FileManager.default.moveItem(at: detachedURL, to: preservedOwnedURL)
        try FileManager.default.createDirectory(at: detachedURL, withIntermediateDirectories: false)
        let replacementPayload = Data("replacement must not be recursively deleted".utf8)
        let replacementURL = detachedURL.appendingPathComponent("replacement.bin")
        try replacementPayload.write(to: replacementURL)

        barrier.resumeCleanup()
        await cleanup.value

        XCTAssertEqual(try Data(contentsOf: replacementURL), replacementPayload)
        XCTAssertEqual(
            try Data(contentsOf: preservedOwnedURL.appendingPathComponent("owned.bin")),
            ownedPayload
        )
    }

    func testMismatchedDetachedObjectIsRestoredWhenOriginalPathIsAvailable() throws {
        let parent = try makeTemporaryDirectory(named: "restore-mismatch")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedURL = parent.appendingPathComponent("attachment.bin")
        let replacement = Data("replacement restored after identity mismatch".utf8)
        try Data("original".utf8).write(to: ownedURL)
        let creationIdentity = try creationIdentity(for: ownedURL)
        let observation = CleanupDetachObservation()
        let lifetime = ReconstructionAttachmentLifetime(
            owning: ownedURL,
            creationIdentity: creationIdentity,
            cleanupHooks: .init(afterAtomicDetach: observation.record)
        )

        try FileManager.default.removeItem(at: ownedURL)
        try replacement.write(to: ownedURL)
        lifetime.discard()

        let quarantineURL = try XCTUnwrap(observation.url)
        XCTAssertEqual(try Data(contentsOf: ownedURL), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testCreationIdentityComesFromCreatorDescriptorInsteadOfCurrentPath() throws {
        let parent = try makeTemporaryDirectory(named: "creator-descriptor")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedURL = parent.appendingPathComponent("attachment.bin")
        let replacement = Data("replacement present before lease initialization".utf8)
        try Data("creator-owned bytes".utf8).write(to: ownedURL)
        let creatorDescriptor = try openDescriptor(for: ownedURL)
        defer { Darwin.close(creatorDescriptor) }

        try FileManager.default.removeItem(at: ownedURL)
        try replacement.write(to: ownedURL)
        let lifetime = try ReconstructionAttachmentLifetime(
            owning: ownedURL,
            creatorDescriptor: creatorDescriptor
        )

        lifetime.discard()

        XCTAssertEqual(try Data(contentsOf: ownedURL), replacement)
    }

    func testMismatchedRecursiveDirectoryIsPreservedWhenRestoreCannotReplaceNewOriginal() async throws {
        let parent = try makeTemporaryDirectory(named: "preserve-mismatched-directory")
        defer { try? FileManager.default.removeItem(at: parent) }
        let ownedRoot = parent.appendingPathComponent("attachment", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        try Data("creator-owned directory".utf8).write(
            to: ownedRoot.appendingPathComponent("original.bin")
        )
        let creatorIdentity = try creationIdentity(for: ownedRoot, isDirectory: true)
        let lifetimeBarrier = CleanupDetachBarrier()
        let lifetime = ReconstructionAttachmentLifetime(
            owning: ownedRoot,
            creationIdentity: creatorIdentity,
            cleanupHooks: .init(afterAtomicDetach: lifetimeBarrier.afterAtomicDetach)
        )
        defer { lifetimeBarrier.resumeCleanup() }

        try FileManager.default.removeItem(at: ownedRoot)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        let mismatchedPayload = Data("mismatched recursive directory must survive".utf8)
        try mismatchedPayload.write(to: ownedRoot.appendingPathComponent("nested.bin"))

        let cleanup = Task.detached {
            lifetime.discard()
        }
        let quarantineURL = try XCTUnwrap(lifetimeBarrier.waitForDetach())
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        let blockerPayload = Data("new original-path occupant".utf8)
        try blockerPayload.write(to: ownedRoot.appendingPathComponent("blocker.bin"))
        lifetimeBarrier.resumeCleanup()
        await cleanup.value

        XCTAssertEqual(
            try Data(contentsOf: ownedRoot.appendingPathComponent("blocker.bin")),
            blockerPayload
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantineURL.appendingPathComponent("nested.bin")),
            mismatchedPayload
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testPackageBackedSourceWithoutLifetimeNeverDeletesItsFile() throws {
        let parent = try makeTemporaryDirectory(named: "package-backed")
        defer { try? FileManager.default.removeItem(at: parent) }
        let packageURL = parent.appendingPathComponent("package-attachment.bin")
        let bytes = Data("durable package bytes".utf8)
        try bytes.write(to: packageURL)

        var source: ReconstructionAttachmentSource? = ReconstructionAttachmentSource(
            contentIdentity: try contentIdentity(for: bytes),
            verifiedURL: packageURL
        )
        source = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testCatalogSourceSurvivesPayloadCopiesAndReleasesItsSharedRootAfterTheLastCopy() async throws {
        var payload: WorkspaceDocumentPackagePayload? = try await catalogPayload(
            for: Data("catalog payload".utf8)
        )
        let sourceURL = try XCTUnwrap(payload?.reconstructionAttachmentSources.first?.verifiedURL)
        let catalogRootURL = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
        var payloadCopy = payload
        payload = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogRootURL.path))
        payloadCopy = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogRootURL.path))
    }

    func testCatalogDiscardAllIsIdempotentEvenWhilePayloadCopiesRemain() async throws {
        let catalog = try ReconstructionAttachmentCatalog()
        let catalogued = try await catalog.catalogBytes(
            Data("discarded catalog payload".utf8),
            maximumByteCount: 1_024,
            cancellation: ReconstructionCancellation()
        )
        let rootURL = catalogued.source.verifiedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let payload = packagePayload(retaining: [catalogued.source])

        await catalog.discardAll()
        await catalog.discardAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
        XCTAssertEqual(payload.reconstructionAttachmentSources.count, 1)
    }

    func testCatalogRejectsSymlinkShardWithoutWritingOutsideOwnedRoot() async throws {
        let parent = try makeTemporaryDirectory(named: "catalog-shard-symlink")
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let interposer = CatalogShardSymlinkInterposer(outsideURL: outside)
        let catalog = try ReconstructionAttachmentCatalog(
            testHooks: .init(beforeAttachmentInstall: interposer.installShardSymlink)
        )

        do {
            _ = try await catalog.catalogBytes(
                Data("must stay inside the catalog".utf8),
                maximumByteCount: 1_024,
                cancellation: ReconstructionCancellation()
            )
            XCTFail("A symlink shard must fail closed.")
        } catch {
            // Expected: the catalog never follows a mutable shard path.
        }
        let rootURL = try XCTUnwrap(interposer.catalogRootURL)
        await catalog.discardAll()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: interposer.shardURL?.path ?? ""),
            "An unowned shard replacement must be preserved as an orphan."
        )
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testCatalogRollbackPreservesReplacementAtCataloguedPath() async throws {
        let swapper = CatalogRollbackReplacement()
        let catalog = try ReconstructionAttachmentCatalog(
            testHooks: .init(beforeRollbackRemoval: swapper.replaceCataloguedObject)
        )
        let checkpoint = await catalog.checkpoint()
        let catalogued = try await catalog.catalogBytes(
            Data("catalog-owned bytes".utf8),
            maximumByteCount: 1_024,
            cancellation: ReconstructionCancellation()
        )
        let rootURL = catalogued.source.verifiedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        await catalog.rollback(to: checkpoint)
        try swapper.rethrowFailure()

        let replacementURL = try XCTUnwrap(swapper.replacementPayloadURL)
        let preservedOwnedURL = try XCTUnwrap(swapper.preservedOwnedURL)
        XCTAssertEqual(
            try Data(contentsOf: replacementURL),
            Data("rollback replacement".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: preservedOwnedURL),
            Data("catalog-owned bytes".utf8)
        )
    }

    func testBuilderSourceSurvivesPayloadCopiesAndReleasesItsFileAfterTheLastCopy() async throws {
        let fixtureRoot = try makeTemporaryDirectory(named: "builder-input")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try Data("manifest input".utf8).write(
            to: fixtureRoot.appendingPathComponent("input.txt")
        )

        var payload: WorkspaceDocumentPackagePayload? = try await builderPayload(
            for: fixtureRoot
        )
        let attachmentURL = try XCTUnwrap(
            payload?.reconstructionAttachmentSources.first?.verifiedURL
        )
        var payloadCopy = payload
        payload = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))
        payloadCopy = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
    }

    func testOrdinaryNilAdoptionWritesRebindOnlyCapturedSourcesAndRetainPostCaptureImport() throws {
        let parent = try makeTemporaryDirectory(named: "ordinary-save")
        defer { try? FileManager.default.removeItem(at: parent) }
        let packageURL = parent.appendingPathComponent("Lifetime.mscope", isDirectory: true)
        let firstBytes = Data("first reconstruction attachment".utf8)
        let secondBytes = Data("post-capture reconstruction attachment".utf8)
        let firstIdentity = try contentIdentity(for: firstBytes)
        let secondIdentity = try contentIdentity(for: secondBytes)
        let projectID = UUID()
        let firstState = try reconstructionState(
            identities: [firstIdentity],
            projectID: projectID
        )
        let initialSourceURL = parent.appendingPathComponent("initial-source.bin")
        try firstBytes.write(to: initialSourceURL)
        let manifest = WorkspacePackageManifest(
            documentID: UUID(),
            workspaceUUID: UUID(),
            workspaceName: "Attachment lifetime",
            createdAt: Date(timeIntervalSince1970: 1_800_400_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_400_001),
            binaries: [],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [:],
            reconstructionState: firstState,
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: firstIdentity,
                    verifiedURL: initialSourceURL
                ),
            ],
            to: packageURL
        )
        let store = try WorkspaceStore.restoredPackage(
            from: packageURL,
            scheduleDurableRecovery: false
        )

        let firstTemporaryRoot = parent.appendingPathComponent("first-temporary", isDirectory: true)
        var firstTemporarySource: ReconstructionAttachmentSource? = try makeTemporarySource(
            bytes: firstBytes,
            owning: firstTemporaryRoot
        )
        store.publishCommittedReconstructionCorpus(
            ReconstructionCommittedCorpus(
                state: firstState,
                attachmentSources: [try XCTUnwrap(firstTemporarySource)]
            )
        )
        firstTemporarySource = nil
        var firstPayload: WorkspaceDocumentPackagePayload? = try store.makePackagePayload()

        let secondState = try reconstructionState(
            identities: [firstIdentity, secondIdentity],
            projectID: projectID
        )
        let secondTemporaryRoot = parent.appendingPathComponent("second-temporary", isDirectory: true)
        var secondTemporarySource: ReconstructionAttachmentSource? = try makeTemporarySource(
            bytes: secondBytes,
            owning: secondTemporaryRoot
        )
        store.publishCommittedReconstructionCorpus(
            ReconstructionCommittedCorpus(
                state: secondState,
                attachmentSources: [try XCTUnwrap(secondTemporarySource)]
            )
        )
        secondTemporarySource = nil

        let firstGeneration = try XCTUnwrap(firstPayload).capturedMutationGeneration
        try writePayload(try XCTUnwrap(firstPayload), to: packageURL)
        store.acceptPublishedWrite(capturedGeneration: firstGeneration, adopting: nil)
        firstPayload = nil

        let firstPackageURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
            in: packageURL,
            contentIdentity: firstIdentity
        )
        let sourcesAfterFirstWrite = Dictionary(
            uniqueKeysWithValues: store.reconstructionAttachmentSources.map {
                ($0.contentIdentity, $0.verifiedURL)
            }
        )
        let canonicalPackageURL = try WorkspaceDocumentLocation.canonicalized(
            from: packageURL
        ).canonicalURL
        XCTAssertEqual(store.documentURL, canonicalPackageURL)
        XCTAssertEqual(sourcesAfterFirstWrite[firstIdentity], firstPackageURL)
        XCTAssertEqual(
            sourcesAfterFirstWrite[secondIdentity],
            secondTemporaryRoot.appendingPathComponent(secondIdentity.digest)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstTemporaryRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTemporaryRoot.path))
        XCTAssertTrue(store.hasUnsavedChanges)

        var secondPayload: WorkspaceDocumentPackagePayload? = try store.makePackagePayload()
        let secondGeneration = try XCTUnwrap(secondPayload).capturedMutationGeneration
        try writePayload(try XCTUnwrap(secondPayload), to: packageURL)
        store.acceptPublishedWrite(capturedGeneration: secondGeneration, adopting: nil)
        secondPayload = nil

        let secondPackageURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
            in: packageURL,
            contentIdentity: secondIdentity
        )
        let sourcesAfterSecondWrite = Dictionary(
            uniqueKeysWithValues: store.reconstructionAttachmentSources.map {
                ($0.contentIdentity, $0.verifiedURL)
            }
        )
        XCTAssertEqual(sourcesAfterSecondWrite[firstIdentity], firstPackageURL)
        XCTAssertEqual(sourcesAfterSecondWrite[secondIdentity], secondPackageURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondTemporaryRoot.path))
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testSuccessfulFreshBinaryImportClearsReconstructionAndReleasesTemporaryStorage() async throws {
        let provider = LifetimeImportProvider(result: .success(importedSnapshot()))
        let store = makeStore(provider: provider)
        let parent = try makeTemporaryDirectory(named: "successful-import")
        defer { try? FileManager.default.removeItem(at: parent) }
        let bytes = Data("prior reconstruction".utf8)
        let identity = try contentIdentity(for: bytes)
        let state = try reconstructionState(identities: [identity], projectID: UUID())
        let ownedRoot = parent.appendingPathComponent("owned", isDirectory: true)
        var source: ReconstructionAttachmentSource? = try makeTemporarySource(
            bytes: bytes,
            owning: ownedRoot
        )
        store.publishCommittedReconstructionCorpus(
            ReconstructionCommittedCorpus(
                state: state,
                attachmentSources: [try XCTUnwrap(source)]
            )
        )
        source = nil

        await store.importBinary(url: parent.appendingPathComponent("replacement.bin"))

        XCTAssertEqual(store.reconstructionState, .empty)
        XCTAssertTrue(store.reconstructionAttachmentSources.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
    }

    func testFailedFreshBinaryImportPreservesReconstructionAndTemporaryStorage() async throws {
        struct ImportFailure: Error, LocalizedError {
            var errorDescription: String? { "injected import failure" }
        }
        let provider = LifetimeImportProvider(result: .failure(ImportFailure()))
        let store = makeStore(provider: provider)
        let parent = try makeTemporaryDirectory(named: "failed-import")
        defer { try? FileManager.default.removeItem(at: parent) }
        let bytes = Data("preserved reconstruction".utf8)
        let identity = try contentIdentity(for: bytes)
        let state = try reconstructionState(identities: [identity], projectID: UUID())
        let ownedRoot = parent.appendingPathComponent("owned", isDirectory: true)
        var source: ReconstructionAttachmentSource? = try makeTemporarySource(
            bytes: bytes,
            owning: ownedRoot
        )
        store.publishCommittedReconstructionCorpus(
            ReconstructionCommittedCorpus(
                state: state,
                attachmentSources: [try XCTUnwrap(source)]
            )
        )
        source = nil

        await store.importBinary(url: parent.appendingPathComponent("replacement.bin"))

        XCTAssertEqual(store.reconstructionState, state)
        XCTAssertEqual(store.reconstructionAttachmentSources.map(\.contentIdentity), [identity])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedRoot.path))
        XCTAssertEqual(store.lastIssue, "injected import failure")
    }

    func testCancelledFreshBinaryImportPreservesReconstructionAndTemporaryStorage() async throws {
        let provider = LifetimeImportProvider(result: .failure(AnalysisCancelled()))
        let store = makeStore(provider: provider)
        let parent = try makeTemporaryDirectory(named: "cancelled-import")
        defer { try? FileManager.default.removeItem(at: parent) }
        let bytes = Data("preserved after cancellation".utf8)
        let identity = try contentIdentity(for: bytes)
        let state = try reconstructionState(identities: [identity], projectID: UUID())
        let ownedRoot = parent.appendingPathComponent("owned", isDirectory: true)
        var source: ReconstructionAttachmentSource? = try makeTemporarySource(
            bytes: bytes,
            owning: ownedRoot
        )
        store.publishCommittedReconstructionCorpus(
            ReconstructionCommittedCorpus(
                state: state,
                attachmentSources: [try XCTUnwrap(source)]
            )
        )
        source = nil

        await store.importBinary(url: parent.appendingPathComponent("replacement.bin"))

        XCTAssertEqual(store.reconstructionState, state)
        XCTAssertEqual(store.reconstructionAttachmentSources.map(\.contentIdentity), [identity])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedRoot.path))
        XCTAssertNil(store.lastIssue)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacScope-ReconstructionAttachmentLifetimeTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func contentIdentity(for data: Data) throws -> ReconstructionContentIdentity {
        try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(data.count)
        )
    }

    private func creationIdentity(
        for url: URL,
        isDirectory: Bool = false
    ) throws -> ReconstructionAttachmentLifetime.CreationIdentity {
        var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        if isDirectory {
            flags |= O_DIRECTORY
        }
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        return try ReconstructionAttachmentLifetime.CreationIdentity(
            descriptor: descriptor
        )
    }

    private func openDescriptor(
        for url: URL,
        isDirectory: Bool = false
    ) throws -> Int32 {
        var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        if isDirectory {
            flags |= O_DIRECTORY
        }
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }

    private func makeTemporarySource(
        bytes: Data,
        owning rootURL: URL
    ) throws -> ReconstructionAttachmentSource {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        let identity = try contentIdentity(for: bytes)
        let sourceURL = rootURL.appendingPathComponent(identity.digest)
        try bytes.write(to: sourceURL)
        return ReconstructionAttachmentSource(
            contentIdentity: identity,
            verifiedURL: sourceURL,
            lifetimeToken: ReconstructionAttachmentLifetime(
                owning: rootURL,
                creationIdentity: try creationIdentity(for: rootURL, isDirectory: true)
            )
        )
    }

    private func packagePayload(
        retaining sources: [ReconstructionAttachmentSource]
    ) -> WorkspaceDocumentPackagePayload {
        WorkspaceDocumentPackagePayload(
            documentID: UUID(),
            workspaceID: UUID(),
            manifestData: Data(),
            attachmentsByBinaryID: [:],
            reconstructionAttachmentSources: sources,
            capturedMutationGeneration: .init(rawValue: 0)
        )
    }

    private func catalogPayload(
        for bytes: Data
    ) async throws -> WorkspaceDocumentPackagePayload {
        let catalog = try ReconstructionAttachmentCatalog()
        let catalogued = try await catalog.catalogBytes(
            bytes,
            maximumByteCount: 1_024,
            cancellation: ReconstructionCancellation()
        )
        return packagePayload(retaining: [catalogued.source])
    }

    private func builderPayload(
        for rootURL: URL
    ) async throws -> WorkspaceDocumentPackagePayload {
        let result = try await ReconstructionContainerManifestBuilder().build(
            rootURL: rootURL,
            limits: .init(
                maximumDepth: 8,
                maximumEntries: 32,
                maximumRelativePathUTF8Bytes: 1_024,
                maximumEncodedBytes: 64 * 1_024
            ),
            cancellation: ReconstructionCancellation()
        )
        return packagePayload(retaining: [result.attachmentSource])
    }

    private func reconstructionState(
        identities: [ReconstructionContentIdentity],
        projectID: UUID
    ) throws -> ReconstructionWorkspaceState {
        let artifacts = try identities.enumerated().map { index, identity in
            try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
                contentIdentity: identity,
                kind: .opaque,
                roles: index == 0 ? [.primaryTarget] : [.referenceSource],
                executableMode: false,
                originalName: "attachment-\(index).bin",
                diagnostic: nil
            )
        }
        let manifestDigest = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: []
        )
        let corpusManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: [],
            canonicalSHA256: manifestDigest
        )
        return try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Attachment lifetime",
                    currentCorpusManifestSHA256: manifestDigest
                ),
            ],
            corpusManifests: [corpusManifest],
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

    private func writePayload(
        _ payload: WorkspaceDocumentPackagePayload,
        to packageURL: URL
    ) throws {
        let contents = try MacScopeDocumentPackage.validatedContents(
            manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID,
            reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData
        )
        try MacScopeDocumentPackage.writePackage(
            contents.manifest,
            attachmentsByBinaryID: payload.attachmentsByBinaryID,
            reconstructionState: payload.reconstructionState,
            reconstructionAttachmentSources: payload.reconstructionAttachmentSources,
            to: packageURL, instructionSidecarData: payload.instructionSidecarData
        )
    }

    private func makeStore(provider: LifetimeImportProvider) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Attachment lifetime",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: provider,
            autosaveScheduler: nil
        )
    }

    private func importedSnapshot() -> WorkspaceSnapshot {
        let image = BinaryImage(
            id: UUID(),
            name: "replacement.bin",
            path: "/tmp/replacement.bin",
            kind: "fixture",
            architecture: "arm64"
        )
        return WorkspaceSnapshot(
            binaries: [image],
            functions: [],
            instructions: [],
            xrefs: [],
            hexBytes: Data([0xc0, 0x03, 0x5f, 0xd6])
        )
    }
}

private final class CleanupDetachObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURL: URL?

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedURL
    }

    func record(_ url: URL) {
        lock.lock()
        recordedURL = url
        lock.unlock()
    }
}

private final class CleanupDetachBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let didDetach = DispatchSemaphore(value: 0)
    private let mayContinue = DispatchSemaphore(value: 0)
    private var detachedURL: URL?
    private var hasResumed = false

    func afterAtomicDetach(_ url: URL) {
        lock.lock()
        detachedURL = url
        lock.unlock()
        didDetach.signal()
        mayContinue.wait()
    }

    func waitForDetach() -> URL? {
        guard didDetach.wait(timeout: .now() + .seconds(5)) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return detachedURL
    }

    func resumeCleanup() {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        lock.unlock()
        mayContinue.signal()
    }
}

private final class CleanupVerifiedObjectBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let didVerify = DispatchSemaphore(value: 0)
    private let mayContinue = DispatchSemaphore(value: 0)
    private var verifiedURL: URL?
    private var hasResumed = false

    func beforeRemoval(_ url: URL) {
        lock.lock()
        verifiedURL = url
        lock.unlock()
        didVerify.signal()
        mayContinue.wait()
    }

    func waitForVerifiedObject() -> URL? {
        guard didVerify.wait(timeout: .now() + .seconds(5)) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return verifiedURL
    }

    func resumeCleanup() {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        lock.unlock()
        mayContinue.signal()
    }
}

private final class CatalogShardSymlinkInterposer: @unchecked Sendable {
    private let lock = NSLock()
    private let outsideURL: URL
    private var recordedCatalogRootURL: URL?
    private var recordedShardURL: URL?

    init(outsideURL: URL) {
        self.outsideURL = outsideURL
    }

    var catalogRootURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedCatalogRootURL
    }

    var shardURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedShardURL
    }

    func installShardSymlink(
        catalogRootURL: URL,
        identity: ReconstructionContentIdentity
    ) throws {
        let shardURL = catalogRootURL.appendingPathComponent(String(identity.digest.prefix(2)))
        try FileManager.default.createSymbolicLink(
            at: shardURL,
            withDestinationURL: outsideURL
        )
        lock.lock()
        recordedCatalogRootURL = catalogRootURL
        recordedShardURL = shardURL
        lock.unlock()
    }
}

private final class CatalogRollbackReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var recordedReplacementPayloadURL: URL?
    private var recordedPreservedOwnedURL: URL?

    var replacementPayloadURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedReplacementPayloadURL
    }

    var preservedOwnedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedPreservedOwnedURL
    }

    func replaceCataloguedObject(_ source: ReconstructionAttachmentSource) {
        do {
            let preservedOwnedURL = source.verifiedURL
                .deletingLastPathComponent()
                .appendingPathComponent("preserved-owned-(UUID().uuidString)")
            try FileManager.default.moveItem(at: source.verifiedURL, to: preservedOwnedURL)
            try FileManager.default.createDirectory(
                at: source.verifiedURL,
                withIntermediateDirectories: false
            )
            let replacementPayloadURL = source.verifiedURL.appendingPathComponent("replacement.bin")
            try Data("rollback replacement".utf8).write(to: replacementPayloadURL)
            lock.lock()
            recordedPreservedOwnedURL = preservedOwnedURL
            recordedReplacementPayloadURL = replacementPayloadURL
            lock.unlock()
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }

    func rethrowFailure() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
    }
}

private final class LifetimeImportProvider: AnalysisProviding, @unchecked Sendable {
    private let result: Result<WorkspaceSnapshot, Error>

    init(result: Result<WorkspaceSnapshot, Error>) {
        self.result = result
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        try result.get()
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try result.get()
    }
}

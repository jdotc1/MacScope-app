import CryptoKit
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceStoreReconstructionPersistenceTests: XCTestCase {
    func testExistingWorkspaceSavePreservesDurableEvidenceAfterImageRemoval() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let initialSave = try store.saveWorkspace(to: database)
        let workspaceRowID = try XCTUnwrap(initialSave.workspace.id)
        let binaryID = try XCTUnwrap(store.snapshot.binaries.first?.id)
        let reconstructionState = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: binaryID,
            evidenceSubjectUsesImageBinding: true
        )
        XCTAssertFalse(reconstructionState.evidence.isEmpty)
        XCTAssertEqual(
            Set(reconstructionState.evidence.map(\.classification)),
            [.acceptedCurrent]
        )
        try database.replaceReconstructionState(
            workspaceID: store.workspaceID,
            state: reconstructionState
        )
        store.restoreWorkspace(
            try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceRowID))
        )

        store.snapshot.removeImage(in: .primary)
        let persisted = try store.saveWorkspace(to: database)
        let reloaded = try XCTUnwrap(
            database.loadWorkspaceState(workspaceID: workspaceRowID)
        )

        XCTAssertTrue(persisted.snapshot.binaries.isEmpty)
        XCTAssertEqual(
            Set(persisted.reconstructionState.evidence.map(\.classification)),
            [.acceptedCurrent]
        )
        XCTAssertEqual(persisted.reconstructionState.evidence, reconstructionState.evidence)
        XCTAssertEqual(store.reconstructionState, persisted.reconstructionState)
        XCTAssertEqual(reloaded.reconstructionState, persisted.reconstructionState)
        XCTAssertEqual(
            Set(reloaded.reconstructionState.evidence.map(\.evidenceID)),
            Set(reconstructionState.evidence.map(\.evidenceID))
        )
        XCTAssertEqual(
            reloaded.reconstructionState.evidence.map(\.subject),
            reconstructionState.evidence.map(\.subject)
        )
    }

    func testFreshDatabaseSaveRetryPreservesReconstructionAfterInjectedPersistenceFailure() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let savedURL = fixture.root.appendingPathComponent("Retry-Saved.mscope", isDirectory: true)
        let store = try WorkspaceStore.restoredPackage(from: fixture.packageURL)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        database.setReconstructionMutationFailureForTesting(after: .insertedProjects)

        XCTAssertThrowsError(try store.saveWorkspace(to: database)) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionInjectedFailure(
                    WorkspaceDatabase.ReconstructionMutationPhase.insertedProjects.rawValue
                )
            )
        }

        XCTAssertEqual(store.reconstructionState, fixture.state)
        XCTAssertEqual(
            try database.loadReconstructionState(workspaceID: store.workspaceID),
            .empty
        )

        let retried = try store.saveWorkspace(to: database)
        XCTAssertEqual(try database.workspaces().count, 1)
        XCTAssertEqual(store.reconstructionState, fixture.state)
        XCTAssertEqual(retried.reconstructionState, fixture.state)
        XCTAssertEqual(
            try database.loadReconstructionState(workspaceID: store.workspaceID),
            fixture.state
        )

        let manifest = try store.saveWorkspacePackage(to: savedURL, using: database)
        let package = try MacScopeDocumentPackage.openPackage(from: savedURL)
        XCTAssertEqual(
            manifest.formatVersion,
            WorkspacePackageManifest.reconstructionFormatVersion
        )
        XCTAssertEqual(package.reconstructionState, fixture.state)
    }

    func testDatabaseRestoreAllowsMetadataOnlyReconstructionWithoutPackagePath() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let source = WorkspaceStore.bootstrapForPreviewFixture()
        let persisted = try source.saveWorkspace(to: database)
        let workspaceRowID = try XCTUnwrap(persisted.workspace.id)
        let metadataOnlyState = try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: UUID(),
                    name: "Metadata-only reconstruction",
                    currentCorpusManifestSHA256: nil
                ),
            ],
            corpusManifests: [],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
        XCTAssertTrue(try ReconstructionPackageCodec.contentRecords(in: metadataOnlyState).isEmpty)
        try database.replaceReconstructionState(
            workspaceID: persisted.workspace.uuid,
            state: metadataOnlyState
        )
        XCTAssertNil(try database.workspaceDocumentMetadata(workspaceID: workspaceRowID))

        let restored = try XCTUnwrap(
            WorkspaceStore.restored(workspaceID: workspaceRowID, from: database)
        )

        XCTAssertEqual(restored.reconstructionState, metadataOnlyState)
        XCTAssertTrue(restored.reconstructionAttachmentSources.isEmpty)
    }

    func testDatabaseRestoreRecoversPackageSourcesAfterCheckpointOutrunsPackageWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionCheckpointCrashRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Checkpoint-Crash.mscope", isDirectory: true)
        let sourceURL = root.appendingPathComponent("fixture.bin")
        let corpusBytes = Data("test".utf8)
        try corpusBytes.write(to: sourceURL)

        let databaseURL = root.appendingPathComponent("workspace.sqlite", isDirectory: false)
        let database = try WorkspaceDatabase(path: databaseURL.path)
        try database.applySchema()
        var sourceStore: WorkspaceStore? = WorkspaceStore.bootstrapForPreviewFixture()
        let initialSave = try XCTUnwrap(sourceStore).saveWorkspace(to: database)
        let workspaceRowID = try XCTUnwrap(initialSave.workspace.id)
        let binaryID = try XCTUnwrap(sourceStore?.snapshot.binaries.first?.id)
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: binaryID
        )
        XCTAssertEqual(foundation.occurrence.contentIdentity.byteCount, UInt64(corpusBytes.count))
        try database.replaceReconstructionState(
            workspaceID: try XCTUnwrap(sourceStore).workspaceID,
            state: foundation.state
        )
        try XCTUnwrap(sourceStore).restoreWorkspace(
            try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceRowID)),
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: foundation.occurrence.contentIdentity,
                    verifiedURL: sourceURL
                ),
            ]
        )
        _ = try XCTUnwrap(sourceStore).saveWorkspacePackage(
            to: packageURL,
            using: database
        )

        let owner = try Self.makeDatabaseOwner(databaseURL: databaseURL)
        let committed = try await owner.commit(
            workspaceID: try XCTUnwrap(sourceStore).workspaceID,
            mutation: try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        )
        XCTAssertGreaterThan(committed.commitSequence, 0)
        XCTAssertNotEqual(committed.state, foundation.state)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: packageURL).reconstructionState,
            foundation.state
        )
        try FileManager.default.removeItem(at: sourceURL)
        sourceStore = nil

        let reopenedDatabase = try WorkspaceDatabase(path: databaseURL.path)
        let restored = try XCTUnwrap(
            WorkspaceStore.restored(workspaceID: workspaceRowID, from: reopenedDatabase)
        )
        let expectedPackageSourceURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
            in: packageURL,
            contentIdentity: foundation.occurrence.contentIdentity
        )

        XCTAssertEqual(restored.reconstructionState, committed.state)
        XCTAssertEqual(restored.reconstructionAttachmentSources.map(\.contentIdentity), [
            foundation.occurrence.contentIdentity,
        ])
        XCTAssertEqual(
            restored.reconstructionAttachmentSources.first?.verifiedURL,
            expectedPackageSourceURL
        )
        XCTAssertEqual(try Data(contentsOf: expectedPackageSourceURL), corpusBytes)
    }

    func testDatabaseRestoreUnionsOlderPackageSourceWithNewerCorpusVaultSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionCorpusCrashRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Corpus-Crash.mscope", isDirectory: true)
        let vaultRoot = root.appendingPathComponent("vault", isDirectory: true)
        let originalSourceURL = root.appendingPathComponent("fixture.bin")
        let originalBytes = Data("test".utf8)
        try originalBytes.write(to: originalSourceURL)

        let databaseURL = root.appendingPathComponent("workspace.sqlite", isDirectory: false)
        let database = try WorkspaceDatabase(path: databaseURL.path)
        try database.applySchema()
        var sourceStore: WorkspaceStore? = WorkspaceStore.bootstrapForPreviewFixture()
        let initialSave = try XCTUnwrap(sourceStore).saveWorkspace(to: database)
        let workspaceRowID = try XCTUnwrap(initialSave.workspace.id)
        let binaryID = try XCTUnwrap(sourceStore?.snapshot.binaries.first?.id)
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: binaryID
        )
        try database.replaceReconstructionState(
            workspaceID: try XCTUnwrap(sourceStore).workspaceID,
            state: foundation.state
        )
        try XCTUnwrap(sourceStore).restoreWorkspace(
            try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceRowID)),
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: foundation.occurrence.contentIdentity,
                    verifiedURL: originalSourceURL
                ),
            ]
        )
        _ = try XCTUnwrap(sourceStore).saveWorkspacePackage(
            to: packageURL,
            using: database
        )

        let successorBytes = Data("corpus bytes committed after the last package write".utf8)
        let successorIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: successorBytes)
                .map { String(format: "%02x", $0) }
                .joined(),
            byteCount: UInt64(successorBytes.count)
        )
        let successorOccurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
            contentIdentity: successorIdentity,
            kind: .source,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "successor.c",
            diagnostic: nil
        )
        let provisionalManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: foundation.project.projectID,
            artifacts: [successorOccurrence],
            relations: [],
            canonicalSHA256: ReconstructionDatabaseTestFixtures.digest("0")
        )
        let successorManifest = try ReconstructionCorpusManifest(
            schemaVersion: provisionalManifest.schemaVersion,
            reconstructionProjectID: provisionalManifest.reconstructionProjectID,
            artifacts: provisionalManifest.artifacts,
            relations: provisionalManifest.relations,
            canonicalSHA256: try ReconstructionCorpusCanonicalizer.canonicalSHA256(
                of: provisionalManifest
            )
        )
        let successorSourceURL = root.appendingPathComponent("successor.c")
        try successorBytes.write(to: successorSourceURL)
        var owner: ReconstructionDatabaseOwner? = try Self.makeDatabaseOwner(
            databaseURL: databaseURL,
            attachmentVaultRootURL: vaultRoot
        )
        let committed = try await XCTUnwrap(owner).commitCorpus(
            workspaceID: try XCTUnwrap(sourceStore).workspaceID,
            mutation: ReconstructionCorpusMutation(
                projectID: foundation.project.projectID,
                expectedCurrentManifestSHA256: foundation.manifest.canonicalSHA256,
                successorManifest: successorManifest,
                attachmentSources: [
                    ReconstructionAttachmentSource(
                        contentIdentity: successorIdentity,
                        verifiedURL: successorSourceURL
                    ),
                ]
            )
        )
        let vaultSource = try XCTUnwrap(committed.attachmentSources.first)
        XCTAssertGreaterThan(committed.commitSequence, 0)
        XCTAssertTrue(vaultSource.verifiedURL.path.hasPrefix(vaultRoot.path + "/"))
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: packageURL).reconstructionState,
            foundation.state
        )
        try FileManager.default.removeItem(at: originalSourceURL)
        try FileManager.default.removeItem(at: successorSourceURL)
        sourceStore = nil
        owner = nil

        let reopenedDatabase = try WorkspaceDatabase(path: databaseURL.path)
        reopenedDatabase.configureReconstructionAttachmentVault(rootURL: vaultRoot)
        let restored = try XCTUnwrap(
            WorkspaceStore.restored(workspaceID: workspaceRowID, from: reopenedDatabase)
        )
        let restoredSources = Dictionary(
            uniqueKeysWithValues: restored.reconstructionAttachmentSources.map {
                ($0.contentIdentity, $0.verifiedURL)
            }
        )
        let packageSourceURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
            in: packageURL,
            contentIdentity: foundation.occurrence.contentIdentity
        )

        XCTAssertEqual(restored.reconstructionState, committed.state)
        XCTAssertEqual(Set(restoredSources.keys), [
            foundation.occurrence.contentIdentity,
            successorIdentity,
        ])
        XCTAssertEqual(restoredSources[foundation.occurrence.contentIdentity], packageSourceURL)
        XCTAssertEqual(restoredSources[successorIdentity], vaultSource.verifiedURL)
        XCTAssertEqual(try Data(contentsOf: packageSourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: vaultSource.verifiedURL), successorBytes)
    }

    nonisolated private static func makeDatabaseOwner(
        databaseURL: URL,
        attachmentVaultRootURL: URL? = nil
    ) throws -> ReconstructionDatabaseOwner {
        let ownerDatabase = try WorkspaceDatabase(path: databaseURL.path)
        return ReconstructionDatabaseOwner(
            database: ownerDatabase,
            attachmentVaultRootURL: attachmentVaultRootURL
        )
    }
}

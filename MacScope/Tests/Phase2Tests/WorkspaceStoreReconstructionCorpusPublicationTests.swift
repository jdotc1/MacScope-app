import CryptoKit
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceStoreReconstructionCorpusPublicationTests: XCTestCase {
    func testFirstCorpusImportCommitsIntoEmptyWorkspaceWithoutSeededProject() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let database = try WorkspaceDatabase(path: scenario.databaseURL.path)
        try database.replaceReconstructionState(workspaceID: scenario.store.workspaceID, state: .empty)
        scenario.store.restoreWorkspace(scenario.emptyPersistedWorkspace)
        let publication = try await scenario.store.importReconstructionCorpus(
            selections: [ReconstructionImportSelection(
                rootURL: scenario.temporaryRoot.appendingPathComponent("successor.c"),
                roles: [.primaryTarget]
            )],
            using: scenario.owner,
            cancellation: ReconstructionCancellation()
        )
        let committed = try XCTUnwrap(publication.committed)
        XCTAssertTrue(publication.publicationAccepted)
        XCTAssertEqual(committed.state.projects.count, 1)
        XCTAssertEqual(committed.state.corpusManifests.first?.artifacts.compactMap(\.originalName), ["successor.c"])
        XCTAssertEqual(committed.state.corpusManifests.first?.artifacts.first?.roles, [.primaryTarget])
        let reopened = try await scenario.owner.load(workspaceID: scenario.store.workspaceID)
        XCTAssertEqual(reopened, committed.state)
    }

    func testOrdinaryImportDoesNotPublishAcrossRestoreDuringAcquisition() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let store = scenario.store
        let replacement = scenario.emptyPersistedWorkspace
        let importer = ReconstructionCorpusImporter(hooks: ReconstructionCorpusImporterHooks(
            didPrepareSuccessfulResult: {
                await MainActor.run { store.restoreWorkspace(replacement) }
            }
        ))
        let publication = try await store.importReconstructionCorpus(
            selections: [ReconstructionImportSelection(
                rootURL: scenario.temporaryRoot.appendingPathComponent("successor.c"),
                roles: [.referenceSource]
            )],
            using: scenario.owner,
            importer: importer,
            cancellation: ReconstructionCancellation()
        )
        XCTAssertNil(publication.committed)
        XCTAssertFalse(publication.publicationAccepted)
        XCTAssertEqual(store.reconstructionState, replacement.reconstructionState,
                       "An import must capture Store authority before acquisition suspends")
        XCTAssertTrue(store.reconstructionAttachmentSources.isEmpty)
    }

    func testCancelledOrdinaryImportPreservesCurrentCorpus() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let initialState = scenario.store.reconstructionState
        let cancellation = ReconstructionCancellation()
        let importer = ReconstructionCorpusImporter(hooks: ReconstructionCorpusImporterHooks(
            didPrepareSuccessfulResult: { cancellation.cancel() }
        ))
        let publication = try await scenario.store.importReconstructionCorpus(
            selections: [ReconstructionImportSelection(
                rootURL: scenario.temporaryRoot.appendingPathComponent("successor.c"),
                roles: [.referenceSource]
            )],
            using: scenario.owner,
            importer: importer,
            cancellation: cancellation
        )
        XCTAssertEqual(publication.result.failures.map(\.reason), [.cancelled])
        XCTAssertNil(publication.committed)
        XCTAssertFalse(publication.publicationAccepted)
        XCTAssertEqual(scenario.store.reconstructionState, initialState,
                       "Cancellation cannot replace a current corpus with an empty manifest")
    }

    func testOrdinaryImportRetainsPreviousArtifactsAndReportsRejectedSelection() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let database = try WorkspaceDatabase(path: scenario.databaseURL.path)
        try database.replaceReconstructionState(workspaceID: scenario.store.workspaceID, state: .empty)
        scenario.store.restoreWorkspace(scenario.emptyPersistedWorkspace)
        let first = try await scenario.store.importReconstructionCorpus(
            selections: [ReconstructionImportSelection(
                rootURL: scenario.temporaryRoot.appendingPathComponent("successor.c"),
                roles: [.primaryTarget]
            )],
            using: scenario.owner,
            cancellation: ReconstructionCancellation()
        )
        let firstCommitted = try XCTUnwrap(first.committed)
        let secondURL = scenario.temporaryRoot.appendingPathComponent("helper.c")
        try Data("int helper(void) { return 7; }\n".utf8).write(to: secondURL)
        let second = try await scenario.store.importReconstructionCorpus(
            selections: [
                ReconstructionImportSelection(rootURL: secondURL, roles: [.referenceSource]),
                ReconstructionImportSelection(
                    rootURL: scenario.temporaryRoot.appendingPathComponent("missing.c"),
                    roles: [.referenceSource]
                ),
            ],
            using: scenario.owner,
            cancellation: ReconstructionCancellation()
        )
        XCTAssertTrue(second.publicationAccepted)
        XCTAssertEqual(second.result.failures.map(\.reason), [.acquisitionFailed])
        let committed = try XCTUnwrap(second.committed)
        XCTAssertEqual(committed.state.projects.map(\.projectID), firstCommitted.state.projects.map(\.projectID))
        let currentDigest = try XCTUnwrap(committed.state.projects.first?.currentCorpusManifestSHA256)
        let current = try XCTUnwrap(committed.state.corpusManifests.first { $0.canonicalSHA256 == currentDigest })
        XCTAssertEqual(Set(current.artifacts.compactMap(\.originalName)), ["successor.c", "helper.c"])
        XCTAssertEqual(committed.attachmentSources.count, 2)
        for source in committed.attachmentSources {
            XCTAssertFalse(try Data(contentsOf: source.verifiedURL).isEmpty)
        }
        let reopened = try await scenario.owner.load(workspaceID: scenario.store.workspaceID)
        XCTAssertEqual(reopened, committed.state)
    }

    func testOrdinaryImportRejectsRootCountBeforeAcquiringOrCommitting() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let initial = scenario.store.reconstructionState
        do {
            _ = try await scenario.store.importReconstructionCorpus(
                selections: Array(repeating: ReconstructionImportSelection(
                    rootURL: scenario.temporaryRoot.appendingPathComponent("successor.c"),
                    roles: [.primaryTarget]
                ), count: 257),
                using: scenario.owner,
                cancellation: ReconstructionCancellation()
            )
            XCTFail("Too many roots cannot enter acquisition")
        } catch {
            XCTAssertEqual(error as? WorkspaceReconstructionCorpusImportError, .selectionBounds)
        }
        XCTAssertEqual(scenario.store.reconstructionState, initial)
        let reopened = try await scenario.owner.load(workspaceID: scenario.store.workspaceID)
        XCTAssertEqual(reopened, initial)
    }

    func testOrdinaryCommitPublishesDurableCorpusIntoCurrentStore() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID

        let committed = try await scenario.store.commitReconstructionCorpus(
            scenario.mutation,
            using: scenario.owner
        )

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        XCTAssertEqual(
            scenario.store.reconstructionAttachmentSources.map(\.contentIdentity),
            scenario.mutation.attachmentSources.map(\.contentIdentity)
        )
        let persistedState = try await scenario.owner.load(workspaceID: workspaceID)
        XCTAssertEqual(persistedState, committed.state)
    }

    func testOlderCorpusContinuationKeepsNewerCheckpointAndRecoversDurableSource() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let originalSource = try XCTUnwrap(scenario.mutation.attachmentSources.first)
        let expectedBytes = try Data(contentsOf: originalSource.verifiedURL)

        let committedCorpus = try await scenario.owner.commitCorpus(
            workspaceID: scenario.store.workspaceID,
            mutation: scenario.mutation
        )
        let committedCheckpoint = try await scenario.owner.commit(
            workspaceID: scenario.store.workspaceID,
            mutation: scenario.checkpointMutation
        )

        XCTAssertGreaterThan(committedCorpus.commitSequence, 0)
        XCTAssertGreaterThan(committedCheckpoint.commitSequence, committedCorpus.commitSequence)
        let durableSource = try XCTUnwrap(committedCorpus.attachmentSources.first)
        XCTAssertNotEqual(
            durableSource.verifiedURL.standardizedFileURL,
            originalSource.verifiedURL.standardizedFileURL
        )
        try FileManager.default.removeItem(at: originalSource.verifiedURL)
        XCTAssertEqual(try Data(contentsOf: durableSource.verifiedURL), expectedBytes)

        scenario.store.publishCommittedReconstructionCheckpoint(
            committedCheckpoint,
            attachmentSources: []
        )
        scenario.store.publishCommittedReconstructionCorpus(committedCorpus)

        XCTAssertEqual(scenario.store.reconstructionState, committedCheckpoint.state)
        XCTAssertEqual(
            scenario.store.reconstructionAttachmentSources.map(\.contentIdentity),
            [durableSource.contentIdentity]
        )
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(
                scenario.store.reconstructionAttachmentSources.first?.verifiedURL
            )),
            expectedBytes
        )
    }

    func testReplacementOwnerContinuesCommitSequenceAndPublishesLaterCheckpoint() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }

        let committedCorpus = try await scenario.store.commitReconstructionCorpus(
            scenario.mutation,
            using: scenario.owner
        )
        let replacementDatabase = try WorkspaceDatabase(path: scenario.databaseURL.path)
        try replacementDatabase.executeRawForTesting("PRAGMA busy_timeout = 10000;")
        let replacementOwner = ReconstructionDatabaseOwner(database: replacementDatabase)

        let committedCheckpoint = try await scenario.store.commitReconstructionCheckpoint(
            scenario.checkpointMutation,
            using: replacementOwner
        )

        XCTAssertGreaterThan(
            committedCheckpoint.commitSequence,
            committedCorpus.commitSequence
        )
        XCTAssertEqual(scenario.store.reconstructionState, committedCheckpoint.state)
        let persistedState = try await replacementOwner.load(
            workspaceID: scenario.store.workspaceID
        )
        XCTAssertEqual(
            persistedState,
            committedCheckpoint.state
        )
    }

    func testReplacementOwnerThroughDatabaseAliasContinuesCommitSequence() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }

        let committedCorpus = try await scenario.store.commitReconstructionCorpus(
            scenario.mutation,
            using: scenario.owner
        )
        let aliasDirectory = scenario.temporaryRoot.appendingPathComponent(
            "database-alias",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasDirectory,
            withDestinationURL: scenario.databaseURL.deletingLastPathComponent()
        )
        let aliasedDatabaseURL = aliasDirectory.appendingPathComponent(
            scenario.databaseURL.lastPathComponent,
            isDirectory: false
        )
        let replacementDatabase = try WorkspaceDatabase(path: aliasedDatabaseURL.path)
        try replacementDatabase.executeRawForTesting("PRAGMA busy_timeout = 10000;")
        let replacementOwner = ReconstructionDatabaseOwner(database: replacementDatabase)

        let committedCheckpoint = try await scenario.store.commitReconstructionCheckpoint(
            scenario.checkpointMutation,
            using: replacementOwner
        )

        XCTAssertGreaterThan(
            committedCheckpoint.commitSequence,
            committedCorpus.commitSequence
        )
        XCTAssertEqual(scenario.store.reconstructionState, committedCheckpoint.state)
    }

    func testStaleCorpusContinuationDoesNotMergeSourceAbsentFromWinningState() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let committedCorpus = try await scenario.owner.commitCorpus(
            workspaceID: scenario.store.workspaceID,
            mutation: scenario.mutation
        )
        let committedCheckpoint = try await scenario.owner.commit(
            workspaceID: scenario.store.workspaceID,
            mutation: scenario.checkpointMutation
        )
        scenario.store.publishCommittedReconstructionCheckpoint(
            committedCheckpoint,
            attachmentSources: []
        )

        let unrelatedBytes = Data("source absent from the winning reconstruction state".utf8)
        let unrelatedIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: unrelatedBytes)
                .map { String(format: "%02x", $0) }
                .joined(),
            byteCount: UInt64(unrelatedBytes.count)
        )
        let unrelatedURL = scenario.temporaryRoot.appendingPathComponent("unrelated-source")
        try unrelatedBytes.write(to: unrelatedURL)
        let staleWithUnrelatedSource = ReconstructionCommittedCorpus(
            state: committedCorpus.state,
            attachmentSources: committedCorpus.attachmentSources + [
                ReconstructionAttachmentSource(
                    contentIdentity: unrelatedIdentity,
                    verifiedURL: unrelatedURL
                ),
            ],
            commitSequence: committedCorpus.commitSequence
        )

        scenario.store.publishCommittedReconstructionCorpus(staleWithUnrelatedSource)

        XCTAssertEqual(scenario.store.reconstructionState, committedCheckpoint.state)
        XCTAssertFalse(
            scenario.store.reconstructionAttachmentSources
                .map(\.contentIdentity)
                .contains(unrelatedIdentity)
        )
    }

    func testEqualCommitSequenceReplayIsIdempotent() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let committed = try await scenario.owner.commitCorpus(
            workspaceID: scenario.store.workspaceID,
            mutation: scenario.mutation
        )
        scenario.store.publishCommittedReconstructionCorpus(committed)
        let generationAfterFirstPublication = scenario.store.mutationGeneration

        scenario.store.publishCommittedReconstructionCorpus(
            ReconstructionCommittedCorpus(
                state: .empty,
                attachmentSources: [],
                commitSequence: committed.commitSequence
            )
        )

        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        XCTAssertEqual(scenario.store.mutationGeneration, generationAfterFirstPublication)
    }

    func testDelayedCommitDoesNotPublishAfterFreshImportReplacesStoreAuthority() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let priorWorkspaceID = scenario.store.workspaceID
        let priorDocumentID = scenario.store.documentID
        let gate = try DelayedReconstructionOwnerGate(databaseURL: scenario.databaseURL)
        try gate.acquire()
        defer { gate.close() }

        let importTask = Task { @MainActor in
            await scenario.store.importBinary(
                url: scenario.temporaryRoot.appendingPathComponent("replacement.bin")
            )
            try gate.release()
        }

        let committed: ReconstructionCommittedCorpus
        do {
            committed = try await scenario.store.commitReconstructionCorpus(
                scenario.mutation,
                using: scenario.owner
            )
        } catch {
            gate.rollbackIfNeeded()
            _ = try? await importTask.value
            throw error
        }
        try await importTask.value

        XCTAssertNotEqual(scenario.store.workspaceID, priorWorkspaceID)
        XCTAssertNotEqual(scenario.store.documentID, priorDocumentID)
        XCTAssertEqual(
            scenario.store.snapshot.binaries.first?.id,
            scenario.importedSnapshot.binaries.first?.id
        )
        XCTAssertEqual(scenario.store.reconstructionState, .empty)
        XCTAssertTrue(scenario.store.reconstructionAttachmentSources.isEmpty)
        XCTAssertFalse(committed.state.projects.isEmpty)
        let persistedState = try await scenario.owner.load(workspaceID: priorWorkspaceID)
        XCTAssertEqual(
            persistedState,
            committed.state,
            "The old workspace commit remains durable even though it no longer owns the store"
        )
    }

    func testDelayedCommitDoesNotPublishAcrossSameIdentityRestoreGeneration() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID
        let capturedGeneration = scenario.store.mutationGeneration
        XCTAssertEqual(scenario.emptyPersistedWorkspace.reconstructionState, .empty)
        let gate = try DelayedReconstructionOwnerGate(databaseURL: scenario.databaseURL)
        try gate.acquire()
        defer { gate.close() }

        let restoreTask = Task { @MainActor in
            scenario.store.restoreWorkspace(scenario.emptyPersistedWorkspace)
            try gate.release()
        }

        let committed: ReconstructionCommittedCorpus
        do {
            committed = try await scenario.store.commitReconstructionCorpus(
                scenario.mutation,
                using: scenario.owner
            )
        } catch {
            gate.rollbackIfNeeded()
            _ = try? await restoreTask.value
            throw error
        }
        try await restoreTask.value

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertNotEqual(scenario.store.mutationGeneration, capturedGeneration)
        XCTAssertEqual(scenario.store.reconstructionState, .empty)
        XCTAssertTrue(scenario.store.reconstructionAttachmentSources.isEmpty)
        XCTAssertFalse(committed.state.projects.isEmpty)
        let persistedState = try await scenario.owner.load(workspaceID: workspaceID)
        XCTAssertEqual(
            persistedState,
            committed.state,
            "The durable result may return without overwriting the restored store generation"
        )
    }

    func testDelayedCorpusCommitStillPublishesAfterUnrelatedDocumentEdit() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID
        let capturedGeneration = scenario.store.mutationGeneration
        let bookmarkAddress = try XCTUnwrap(scenario.store.snapshot.instructions.first?.address)
        let gate = try DelayedReconstructionOwnerGate(databaseURL: scenario.databaseURL)
        try gate.acquire()
        defer { gate.close() }

        let editTask = Task { @MainActor in
            scenario.store.addBookmark(at: bookmarkAddress, name: "Concurrent edit")
            try gate.release()
        }

        let committed: ReconstructionCommittedCorpus
        do {
            committed = try await scenario.store.commitReconstructionCorpus(
                scenario.mutation,
                using: scenario.owner
            )
        } catch {
            gate.rollbackIfNeeded()
            _ = try? await editTask.value
            throw error
        }
        try await editTask.value

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertNotEqual(scenario.store.mutationGeneration, capturedGeneration)
        XCTAssertTrue(scenario.store.snapshot.bookmarks.contains {
            $0.address == bookmarkAddress && $0.name == "Concurrent edit"
        })
        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        let persistedState = try await scenario.owner.load(workspaceID: workspaceID)
        XCTAssertEqual(persistedState, committed.state)
    }

    func testDelayedCheckpointCommitDoesNotPublishAfterFreshImportReplacesStoreAuthority() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let priorWorkspaceID = scenario.store.workspaceID
        let priorDocumentID = scenario.store.documentID
        let gate = try DelayedReconstructionOwnerGate(databaseURL: scenario.databaseURL)
        try gate.acquire()
        defer { gate.close() }

        let importTask = Task { @MainActor in
            await scenario.store.importBinary(
                url: scenario.temporaryRoot.appendingPathComponent("checkpoint-replacement.bin")
            )
            try gate.release()
        }

        let committed: ReconstructionCommittedCheckpoint
        do {
            committed = try await scenario.store.commitReconstructionCheckpoint(
                scenario.checkpointMutation,
                using: scenario.owner
            )
        } catch {
            gate.rollbackIfNeeded()
            _ = try? await importTask.value
            throw error
        }
        try await importTask.value

        XCTAssertNotEqual(scenario.store.workspaceID, priorWorkspaceID)
        XCTAssertNotEqual(scenario.store.documentID, priorDocumentID)
        XCTAssertEqual(
            scenario.store.snapshot.binaries.first?.id,
            scenario.importedSnapshot.binaries.first?.id
        )
        XCTAssertEqual(scenario.store.reconstructionState, .empty)
        XCTAssertFalse(committed.state.projects.isEmpty)
        let persistedState = try await scenario.owner.load(workspaceID: priorWorkspaceID)
        XCTAssertEqual(persistedState, committed.state)
    }

    func testDelayedCheckpointCommitDoesNotPublishAcrossSameIdentityRestoreGeneration() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID
        let capturedGeneration = scenario.store.mutationGeneration
        let gate = try DelayedReconstructionOwnerGate(databaseURL: scenario.databaseURL)
        try gate.acquire()
        defer { gate.close() }

        let restoreTask = Task { @MainActor in
            scenario.store.restoreWorkspace(scenario.emptyPersistedWorkspace)
            try gate.release()
        }

        let committed: ReconstructionCommittedCheckpoint
        do {
            committed = try await scenario.store.commitReconstructionCheckpoint(
                scenario.checkpointMutation,
                using: scenario.owner
            )
        } catch {
            gate.rollbackIfNeeded()
            _ = try? await restoreTask.value
            throw error
        }
        try await restoreTask.value

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertNotEqual(scenario.store.mutationGeneration, capturedGeneration)
        XCTAssertEqual(scenario.store.reconstructionState, .empty)
        XCTAssertFalse(committed.state.projects.isEmpty)
        let persistedState = try await scenario.owner.load(workspaceID: workspaceID)
        XCTAssertEqual(persistedState, committed.state)
    }

    func testDelayedCheckpointCommitStillPublishesAfterUnrelatedDocumentEdit() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID
        let capturedGeneration = scenario.store.mutationGeneration
        let bookmarkAddress = try XCTUnwrap(scenario.store.snapshot.instructions.first?.address)
        let gate = try DelayedReconstructionOwnerGate(databaseURL: scenario.databaseURL)
        try gate.acquire()
        defer { gate.close() }

        let editTask = Task { @MainActor in
            scenario.store.addBookmark(at: bookmarkAddress, name: "Concurrent checkpoint edit")
            try gate.release()
        }

        let committed: ReconstructionCommittedCheckpoint
        do {
            committed = try await scenario.store.commitReconstructionCheckpoint(
                scenario.checkpointMutation,
                using: scenario.owner
            )
        } catch {
            gate.rollbackIfNeeded()
            _ = try? await editTask.value
            throw error
        }
        try await editTask.value

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertNotEqual(scenario.store.mutationGeneration, capturedGeneration)
        XCTAssertTrue(scenario.store.snapshot.bookmarks.contains {
            $0.address == bookmarkAddress && $0.name == "Concurrent checkpoint edit"
        })
        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        let persistedState = try await scenario.owner.load(workspaceID: workspaceID)
        XCTAssertEqual(persistedState, committed.state)
    }

    @MainActor
    private struct Scenario {
        let temporaryRoot: URL
        let databaseURL: URL
        let store: WorkspaceStore
        let ownerLease: ReconstructionOwnerLease
        let mutation: ReconstructionCorpusMutation
        let checkpointMutation: ReconstructionCheckpointMutation
        let emptyPersistedWorkspace: WorkspaceDatabase.PersistedWorkspace
        let importedSnapshot: WorkspaceSnapshot

        var owner: ReconstructionDatabaseOwner {
            ownerLease.owner
        }

        func remove() {
            ownerLease.close()
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private func makeScenario() throws -> Scenario {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-WorkspaceStoreReconstructionPublication-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        do {
            let databaseURL = temporaryRoot.appendingPathComponent("workspace.sqlite")
            let database = try WorkspaceDatabase(path: databaseURL.path)
            try database.applySchema()
            try database.executeRawForTesting("PRAGMA busy_timeout = 10000;")

            let initialSnapshot = AnalysisEngine.previewSnapshot()
            let importedSnapshot = makeImportedSnapshot()
            let store = WorkspaceStore(
                workspaceName: "Publication authority",
                snapshot: initialSnapshot,
                engine: ImmediateReconstructionImportProvider(snapshot: importedSnapshot),
                autosaveScheduler: nil
            )
            let emptyPersistedWorkspace = try store.saveWorkspace(to: database)
            let workspaceRowID = try XCTUnwrap(emptyPersistedWorkspace.workspace.id)
            let binaryID = try XCTUnwrap(initialSnapshot.binaries.first?.id)
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: binaryID
            )
            try database.replaceReconstructionState(
                workspaceID: store.workspaceID,
                state: foundation.state
            )
            store.restoreWorkspace(
                try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceRowID))
            )

            let mutation = try makeMutation(
                from: foundation,
                temporaryRoot: temporaryRoot
            )
            let ownerDatabase = try WorkspaceDatabase(path: databaseURL.path)
            try ownerDatabase.executeRawForTesting("PRAGMA busy_timeout = 10000;")
            let owner = ReconstructionDatabaseOwner(database: ownerDatabase)
            return Scenario(
                temporaryRoot: temporaryRoot,
                databaseURL: databaseURL,
                store: store,
                ownerLease: ReconstructionOwnerLease(owner: owner),
                mutation: mutation,
                checkpointMutation: try ReconstructionDatabaseTestFixtures.makeMutation(
                    from: foundation
                ),
                emptyPersistedWorkspace: emptyPersistedWorkspace,
                importedSnapshot: importedSnapshot
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    private func makeMutation(
        from foundation: ReconstructionDatabaseTestFixtures.StateFixture,
        temporaryRoot: URL
    ) throws -> ReconstructionCorpusMutation {
        let bytes = Data("successor corpus committed after an owner suspension".utf8)
        let contentIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count)
        )
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
            contentIdentity: contentIdentity,
            kind: .source,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "successor.c",
            diagnostic: nil
        )
        let provisionalManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: foundation.project.projectID,
            artifacts: [occurrence],
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
        let sourceURL = temporaryRoot.appendingPathComponent("successor.c")
        try bytes.write(to: sourceURL)
        return ReconstructionCorpusMutation(
            projectID: foundation.project.projectID,
            expectedCurrentManifestSHA256: foundation.manifest.canonicalSHA256,
            successorManifest: successorManifest,
            attachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: contentIdentity,
                    verifiedURL: sourceURL
                ),
            ]
        )
    }

    private func makeImportedSnapshot() -> WorkspaceSnapshot {
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

@MainActor
private final class DelayedReconstructionOwnerGate {
    private var database: WorkspaceDatabase?
    private var isHoldingWriterLock = false

    init(databaseURL: URL) throws {
        database = try WorkspaceDatabase(path: databaseURL.path)
    }

    func acquire() throws {
        guard let database else { preconditionFailure("Database gate is closed") }
        try database.executeRawForTesting("BEGIN IMMEDIATE TRANSACTION;")
        isHoldingWriterLock = true
    }

    func release() throws {
        guard isHoldingWriterLock else { return }
        guard let database else { preconditionFailure("Database gate is closed") }
        try database.executeRawForTesting("COMMIT;")
        isHoldingWriterLock = false
    }

    func rollbackIfNeeded() {
        guard isHoldingWriterLock else { return }
        try? database?.executeRawForTesting("ROLLBACK;")
        isHoldingWriterLock = false
    }

    func close() {
        rollbackIfNeeded()
        database = nil
    }
}

@MainActor
private final class ReconstructionOwnerLease {
    private var retainedOwner: ReconstructionDatabaseOwner?

    init(owner: ReconstructionDatabaseOwner) {
        retainedOwner = owner
    }

    var owner: ReconstructionDatabaseOwner {
        guard let retainedOwner else { preconditionFailure("Owner lease is closed") }
        return retainedOwner
    }

    func close() {
        retainedOwner = nil
    }
}

private final class ImmediateReconstructionImportProvider: AnalysisProviding, @unchecked Sendable {
    private let snapshot: WorkspaceSnapshot

    init(snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        snapshot
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        snapshot
    }
}

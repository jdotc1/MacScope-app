import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceStoreReconstructionIntegrationTests: XCTestCase {
    func testCreationCommitsPublishesSelectsThenStarts() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let generation = scenario.store.mutationGeneration
        let expectedGeneration = try generation.next()
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources,
            startObservation: { [weak store = scenario.store] jobID in
                guard let store else { return false }
                return store.reconstructionState.jobs.contains { $0.jobID == jobID }
                    && store.selectedReconstructionJobID == jobID
                    && store.selectedSidebarItemID
                        == WorkspaceStore.reconstructionSidebarItemID(jobID)
            }
        )

        let committed = try await scenario.store.createReconstructionJob(
            scenario.request,
            using: runtime
        )

        XCTAssertEqual(runtime.events, [.commitEntered, .commitReturned, .start])
        XCTAssertEqual(runtime.startObservedPublishedState, [true])
        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        XCTAssertEqual(scenario.store.selectedReconstructionJobID, committed.job.jobID)
        XCTAssertEqual(
            scenario.store.selectedSidebarItemID,
            WorkspaceStore.reconstructionSidebarItemID(committed.job.jobID)
        )
        XCTAssertEqual(scenario.store.mutationGeneration, expectedGeneration)
        XCTAssertEqual(
            scenario.store.reconstructionAttachmentSources.map(\.contentIdentity),
            scenario.attachmentSources.map(\.contentIdentity)
        )
    }

    func testFailedCreationLeavesStoreSelectionDirtyStateAndCoordinatorUntouched() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let state = scenario.store.reconstructionState
        let sources = scenario.store.reconstructionAttachmentSources.map(\.contentIdentity)
        let generation = scenario.store.mutationGeneration
        let selection = scenario.store.selectedReconstructionJobID
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources,
            mode: .failBeforeCommit
        )

        do {
            _ = try await scenario.store.createReconstructionJob(
                scenario.request,
                using: runtime
            )
            XCTFail("Expected the runtime commit failure")
        } catch {
            XCTAssertEqual(error as? IntegrationRuntimeFailure, .commit)
        }

        XCTAssertEqual(scenario.store.reconstructionState, state)
        XCTAssertEqual(
            scenario.store.reconstructionAttachmentSources.map(\.contentIdentity),
            sources
        )
        XCTAssertEqual(scenario.store.mutationGeneration, generation)
        XCTAssertEqual(scenario.store.selectedReconstructionJobID, selection)
        XCTAssertTrue(runtime.startedJobIDs.isEmpty)
    }

    func testDurableSourceFailureDoesNotPublishOrStart() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let state = scenario.store.reconstructionState
        let generation = scenario.store.mutationGeneration
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources,
            mode: .failAfterCommit
        )

        do {
            _ = try await scenario.store.createReconstructionJob(
                scenario.request,
                using: runtime
            )
            XCTFail("Expected durable-source aggregation to fail")
        } catch {
            XCTAssertEqual(error as? IntegrationRuntimeFailure, .sources)
        }

        let durable = try await scenario.owner.load(workspaceID: scenario.store.workspaceID)
        XCTAssertEqual(durable.jobs.count, state.jobs.count + 1)
        XCTAssertEqual(scenario.store.reconstructionState, state)
        XCTAssertEqual(scenario.store.mutationGeneration, generation)
        XCTAssertNil(scenario.store.selectedReconstructionJobID)
        XCTAssertTrue(runtime.startedJobIDs.isEmpty)
    }

    func testMalformedRuntimeCoordinatesAndSourceCutsFailClosed() async throws {
        for (mode, expectedError) in [
            (
                IntegrationJobRuntime.Mode.malformedCoordinates,
                WorkspaceReconstructionJobIntegrationError.runtimeCoordinateMismatch
            ),
            (
                IntegrationJobRuntime.Mode.omitSources,
                WorkspaceReconstructionJobIntegrationError.runtimeAttachmentSourceMismatch
            ),
        ] {
            let scenario = try makeScenario()
            defer { scenario.remove() }
            let state = scenario.store.reconstructionState
            let generation = scenario.store.mutationGeneration
            let runtime = IntegrationJobRuntime(
                owner: scenario.owner,
                attachmentSources: scenario.attachmentSources,
                mode: mode
            )

            do {
                _ = try await scenario.store.createReconstructionJob(
                    scenario.request,
                    using: runtime
                )
                XCTFail("Expected the malformed runtime publication to fail closed")
            } catch {
                XCTAssertEqual(
                    error as? WorkspaceReconstructionJobIntegrationError,
                    expectedError
                )
            }

            let durable = try await scenario.owner.load(
                workspaceID: scenario.store.workspaceID
            )
            XCTAssertEqual(durable.jobs.count, state.jobs.count + 1)
            XCTAssertEqual(scenario.store.reconstructionState, state)
            XCTAssertEqual(scenario.store.mutationGeneration, generation)
            XCTAssertNil(scenario.store.selectedReconstructionJobID)
            XCTAssertTrue(runtime.startedJobIDs.isEmpty)
        }
    }

    func testDelayedInitialCommitIsRejectedAfterFreshImport() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let oldWorkspaceID = scenario.store.workspaceID
        let oldDocumentID = scenario.store.documentID
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources,
            mode: .suspendBeforeCommit
        )
        let creation = Task { @MainActor in
            try await scenario.store.createReconstructionJob(
                scenario.request,
                using: runtime
            )
        }
        await runtime.waitUntilCommitEntered()

        await scenario.store.importBinary(
            url: scenario.temporaryRoot.appendingPathComponent("replacement.bin")
        )
        runtime.releaseCommit()
        let committed = try await creation.value

        XCTAssertNotEqual(scenario.store.workspaceID, oldWorkspaceID)
        XCTAssertNotEqual(scenario.store.documentID, oldDocumentID)
        XCTAssertEqual(scenario.store.reconstructionState, .empty)
        XCTAssertNil(scenario.store.selectedReconstructionJobID)
        XCTAssertTrue(scenario.store.reconstructionAttachmentSources.isEmpty)
        XCTAssertTrue(runtime.startedJobIDs.isEmpty)
        let durable = try await scenario.owner.load(workspaceID: oldWorkspaceID)
        XCTAssertTrue(durable.jobs.contains { $0.jobID == committed.job.jobID })
    }

    func testDelayedInitialCommitIsRejectedAcrossSameIdentityRestoreGeneration() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources,
            mode: .suspendBeforeCommit
        )
        let creation = Task { @MainActor in
            try await scenario.store.createReconstructionJob(
                scenario.request,
                using: runtime
            )
        }
        await runtime.waitUntilCommitEntered()

        scenario.store.restoreWorkspace(
            scenario.persistedFoundation,
            reconstructionAttachmentSources: scenario.attachmentSources
        )
        runtime.releaseCommit()
        let committed = try await creation.value

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertEqual(scenario.store.reconstructionState, scenario.foundation.state)
        XCTAssertFalse(
            scenario.store.reconstructionState.jobs.contains {
                $0.jobID == committed.job.jobID
            }
        )
        XCTAssertNil(scenario.store.selectedReconstructionJobID)
        XCTAssertTrue(runtime.startedJobIDs.isEmpty)
    }

    func testDelayedInitialCommitStillPublishesAcrossUnrelatedAuthoringEdit() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources,
            mode: .suspendBeforeCommit
        )
        let creation = Task { @MainActor in
            try await scenario.store.createReconstructionJob(
                scenario.request,
                using: runtime
            )
        }
        await runtime.waitUntilCommitEntered()

        let address = try XCTUnwrap(scenario.store.snapshot.instructions.first?.address)
        scenario.store.addBookmark(at: address, name: "Concurrent authoring edit")
        runtime.releaseCommit()
        let committed = try await creation.value

        XCTAssertTrue(scenario.store.snapshot.bookmarks.contains {
            $0.address == address && $0.name == "Concurrent authoring edit"
        })
        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        XCTAssertEqual(runtime.startObservedPublishedState, [true])
    }

    func testPositiveInitialCommitReplayDoesNotRedirty() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources
        )
        let committed = try await scenario.store.createReconstructionJob(
            scenario.request,
            using: runtime
        )
        let generation = scenario.store.mutationGeneration

        scenario.store.publishCommittedReconstructionCheckpoint(
            ReconstructionCommittedCheckpoint(
                state: .empty,
                checkpoint: committed.checkpoint,
                idempotentToolReceiptIDs: [],
                idempotentModelReceiptIDs: [],
                commitSequence: committed.commitSequence
            ),
            attachmentSources: []
        )

        XCTAssertEqual(scenario.store.reconstructionState, committed.state)
        XCTAssertEqual(scenario.store.mutationGeneration, generation)
    }

    func testControlCommandsForwardOnlyLegalCommittedAuthorities() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources
        )
        let committed = try await scenario.store.createReconstructionJob(
            scenario.request,
            using: runtime
        )
        runtime.resetCommandInvocations()
        let jobID = committed.job.jobID
        let foreignID = UUID()

        let didStart = await scenario.store.startReconstructionJob(jobID, using: runtime)
        XCTAssertTrue(didStart)
        let didPause = await scenario.store.pauseReconstructionJob(jobID, using: runtime)
        XCTAssertTrue(didPause)
        let didResume = await scenario.store.resumeReconstructionJob(jobID, using: runtime)
        XCTAssertFalse(didResume)
        let didCancel = await scenario.store.cancelReconstructionJob(jobID, using: runtime)
        XCTAssertTrue(didCancel)
        let didStartForeign = await scenario.store.startReconstructionJob(
            foreignID,
            using: runtime
        )
        XCTAssertFalse(didStartForeign)
        let didPauseForeign = await scenario.store.pauseReconstructionJob(
            foreignID,
            using: runtime
        )
        XCTAssertFalse(didPauseForeign)
        let didResumeForeign = await scenario.store.resumeReconstructionJob(
            foreignID,
            using: runtime
        )
        XCTAssertFalse(didResumeForeign)
        let didCancelForeign = await scenario.store.cancelReconstructionJob(
            foreignID,
            using: runtime
        )
        XCTAssertFalse(didCancelForeign)

        XCTAssertEqual(runtime.startedJobIDs, [jobID])
        XCTAssertEqual(runtime.pausedJobIDs, [jobID])
        XCTAssertTrue(runtime.resumedJobIDs.isEmpty)
        XCTAssertEqual(runtime.cancelledJobIDs, [jobID])

        let expectedAuthority = ReconstructionJobCommandAuthority(
            jobID: jobID,
            expectedJobState: .created,
            checkpointID: committed.checkpoint.checkpointID,
            checkpointRevision: committed.checkpoint.revision,
            corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256
        )
        XCTAssertEqual(runtime.startedAuthorities, [expectedAuthority])
        XCTAssertEqual(runtime.pausedAuthorities, [expectedAuthority])
        XCTAssertTrue(runtime.resumedAuthorities.isEmpty)
        XCTAssertEqual(runtime.cancelledAuthorities, [expectedAuthority])
    }

    func testResumeForwardsOnlyTheExactDurablePausedAuthority() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let runtime = IntegrationJobRuntime(
            owner: scenario.owner,
            attachmentSources: scenario.attachmentSources
        )
        let pauseContext = try ReconstructionJobPauseContext(
            cause: .pausedByUser,
            resumeTarget: .retrieving
        )
        let paused = try await scenario.owner.commit(
            Self.pausedMutation(
                try ReconstructionDatabaseTestFixtures.makeMutation(
                    from: scenario.foundation
                ),
                pauseContext: pauseContext
            )
        )
        scenario.store.publishCommittedReconstructionCheckpoint(
            paused,
            attachmentSources: scenario.attachmentSources
        )

        let jobID = scenario.foundation.job.jobID
        let didStart = await scenario.store.startReconstructionJob(jobID, using: runtime)
        let didPause = await scenario.store.pauseReconstructionJob(jobID, using: runtime)
        let didResume = await scenario.store.resumeReconstructionJob(jobID, using: runtime)
        let didCancel = await scenario.store.cancelReconstructionJob(jobID, using: runtime)
        XCTAssertFalse(didStart)
        XCTAssertFalse(didPause)
        XCTAssertTrue(didResume)
        // This recording runtime does not commit a resumed state. Cancellation therefore
        // remains authorized against the same exact durable paused checkpoint, not a guessed active state.
        XCTAssertTrue(didCancel)

        let expectedAuthority = ReconstructionJobCommandAuthority(
            jobID: jobID,
            expectedJobState: .paused,
            checkpointID: paused.checkpoint.checkpointID,
            checkpointRevision: paused.checkpoint.revision,
            corpusManifestSHA256: paused.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: paused.checkpoint.evidenceFrontierSHA256
        )
        XCTAssertTrue(runtime.startedAuthorities.isEmpty)
        XCTAssertTrue(runtime.pausedAuthorities.isEmpty)
        XCTAssertEqual(runtime.resumedAuthorities, [expectedAuthority])
        XCTAssertEqual(runtime.cancelledAuthorities, [expectedAuthority])
    }

    func testCoordinatorReceiptPublisherRejectsSameIdentityRestoreDuringSourceLookup() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let committed = try await scenario.owner.commitInitialJob(
            workspaceID: scenario.store.workspaceID,
            mutation: ReconstructionInitialJobMutation(
                jobID: UUID(),
                projectID: scenario.request.projectID,
                selectedOccurrenceIDs: scenario.request.selectedItems.map(\.occurrenceID),
                objective: scenario.request.objective,
                budget: scenario.request.budget
            )
        )
        let sourceGate = IntegrationSourceLoaderGate(sources: scenario.attachmentSources)
        let publisher = WorkspaceStoreReconstructionStatusPublisher(
            store: scenario.store,
            workspaceID: scenario.store.workspaceID,
            loadDurableSources: { workspaceID in
                try await sourceGate.load(workspaceID: workspaceID)
            }
        )
        let receipt = commitReceipt(for: committed)
        let publication = Task { await publisher.publish(receipt) }
        await sourceGate.waitUntilEntered()

        let workspaceID = scenario.store.workspaceID
        let documentID = scenario.store.documentID
        scenario.store.restoreWorkspace(
            scenario.persistedFoundation,
            reconstructionAttachmentSources: scenario.attachmentSources
        )
        await sourceGate.release()
        await publication.value

        XCTAssertEqual(scenario.store.workspaceID, workspaceID)
        XCTAssertEqual(scenario.store.documentID, documentID)
        XCTAssertEqual(scenario.store.reconstructionState, scenario.foundation.state)
        XCTAssertFalse(scenario.store.reconstructionState.jobs.contains {
            $0.jobID == committed.job.jobID
        })
    }

    func testCoordinatorReceiptPublisherRejectsStaleAuthorityBeforeSourceLookup() async throws {
        let scenario = try makeScenario()
        defer { scenario.remove() }
        let committed = try await scenario.owner.commitInitialJob(
            workspaceID: scenario.store.workspaceID,
            mutation: ReconstructionInitialJobMutation(
                jobID: UUID(),
                projectID: scenario.request.projectID,
                selectedOccurrenceIDs: scenario.request.selectedItems.map(\.occurrenceID),
                objective: scenario.request.objective,
                budget: scenario.request.budget
            )
        )
        let sourceProbe = IntegrationSourceLoaderProbe(sources: scenario.attachmentSources)
        let publisher = WorkspaceStoreReconstructionStatusPublisher(
            store: scenario.store,
            workspaceID: scenario.store.workspaceID,
            loadDurableSources: { workspaceID in
                await sourceProbe.load(workspaceID: workspaceID)
            }
        )

        scenario.store.restoreWorkspace(
            scenario.persistedFoundation,
            reconstructionAttachmentSources: scenario.attachmentSources
        )
        await publisher.publish(commitReceipt(for: committed))

        let loadCount = await sourceProbe.loadCount()
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(scenario.store.reconstructionState, scenario.foundation.state)
        XCTAssertFalse(scenario.store.reconstructionState.jobs.contains {
            $0.jobID == committed.job.jobID
        })
    }

    private func commitReceipt(
        for committed: ReconstructionCommittedInitialJob
    ) -> ReconstructionJobCommitReceipt {
        ReconstructionJobCommitReceipt(
            jobID: committed.job.jobID,
            checkpointRevision: committed.checkpoint.revision,
            evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256,
            disposition: .continue,
            committedCheckpoint: ReconstructionCommittedCheckpoint(
                state: committed.state,
                checkpoint: committed.checkpoint,
                idempotentToolReceiptIDs: [],
                idempotentModelReceiptIDs: [],
                commitSequence: committed.commitSequence
            )
        )
    }

    private static func pausedMutation(
        _ base: ReconstructionCheckpointMutation,
        pauseContext: ReconstructionJobPauseContext
    ) throws -> ReconstructionCheckpointMutation {
        let checkpoint = base.successorCheckpoint
        let pausedCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: checkpoint.checkpointID,
            schemaVersion: checkpoint.schemaVersion,
            jobID: checkpoint.jobID,
            revision: checkpoint.revision,
            parentCheckpointID: checkpoint.parentCheckpointID,
            parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: checkpoint.pendingTaskIDs,
            runningTaskIDs: checkpoint.runningTaskIDs,
            completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs,
            blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: checkpoint.modelReceiptIDs,
            toolReceiptIDs: checkpoint.toolReceiptIDs,
            coordinatorState: .paused,
            terminalReason: nil
        )
        return ReconstructionCheckpointMutation(
            jobID: base.jobID,
            expectedParentCheckpointID: base.expectedParentCheckpointID,
            expectedParentCheckpointSHA256: base.expectedParentCheckpointSHA256,
            expectedParentRevision: base.expectedParentRevision,
            evidence: base.evidence,
            evidenceRelations: base.evidenceRelations,
            evidenceGaps: base.evidenceGaps,
            toolReceipts: base.toolReceipts,
            modelReceipts: base.modelReceipts,
            newTasks: base.newTasks,
            taskTransitions: base.taskTransitions,
            freshnessAuthority: base.freshnessAuthority,
            successorCheckpoint: pausedCheckpoint,
            successorPauseContext: pauseContext
        )
    }

    private struct Scenario {
        let temporaryRoot: URL
        let store: WorkspaceStore
        let owner: ReconstructionDatabaseOwner
        let foundation: ReconstructionDatabaseTestFixtures.StateFixture
        let persistedFoundation: WorkspaceDatabase.PersistedWorkspace
        let attachmentSources: [ReconstructionAttachmentSource]
        let request: ReconstructionJobCreationRequest

        func remove() {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private func makeScenario() throws -> Scenario {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-WorkspaceReconstructionIntegration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        do {
            let database = try WorkspaceDatabase(
                path: temporaryRoot.appendingPathComponent("workspace.sqlite").path
            )
            try database.applySchema()
            let initialSnapshot = AnalysisEngine.previewSnapshot()
            let replacementSnapshot = WorkspaceSnapshot(
                binaries: [
                    BinaryImage(
                        id: UUID(),
                        name: "replacement.bin",
                        path: "/tmp/replacement.bin",
                        kind: "fixture",
                        architecture: "arm64"
                    ),
                ],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data([0xc0, 0x03, 0x5f, 0xd6])
            )
            let store = WorkspaceStore(
                workspaceName: "Reconstruction integration",
                snapshot: initialSnapshot,
                engine: IntegrationImportProvider(snapshot: replacementSnapshot),
                autosaveScheduler: nil
            )
            let initiallyPersisted = try store.saveWorkspace(to: database)
            let rowID = try XCTUnwrap(initiallyPersisted.workspace.id)
            let binaryID = try XCTUnwrap(initialSnapshot.binaries.first?.id)
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: binaryID
            )
            try database.replaceReconstructionState(
                workspaceID: store.workspaceID,
                state: foundation.state
            )
            let persistedFoundation = try XCTUnwrap(
                database.loadWorkspaceState(workspaceID: rowID)
            )
            let sourceURL = temporaryRoot.appendingPathComponent("fixture.bin")
            try Data("test".utf8).write(to: sourceURL)
            let attachmentSources = [
                ReconstructionAttachmentSource(
                    contentIdentity: foundation.occurrence.contentIdentity,
                    verifiedURL: sourceURL
                ),
            ]
            store.restoreWorkspace(
                persistedFoundation,
                reconstructionAttachmentSources: attachmentSources
            )
            let items = ReconstructionJobCreationItem.committedItems(
                in: store.reconstructionState
            )
            let request = try XCTUnwrap(
                ReconstructionJobCreationRequest(
                    selectedItems: items,
                    committedItems: items,
                    objective: "Recover the selected committed image",
                    budget: try ReconstructionJobBudget(
                        maxRounds: 4,
                        maxTasks: 64,
                        maxEvidenceRecords: 128,
                        maxEncodedBytes: 1_048_576
                    )
                )
            )
            let ownerDatabase = try WorkspaceDatabase(
                path: temporaryRoot.appendingPathComponent("workspace.sqlite").path
            )
            return Scenario(
                temporaryRoot: temporaryRoot,
                store: store,
                owner: ReconstructionDatabaseOwner(database: ownerDatabase),
                foundation: foundation,
                persistedFoundation: persistedFoundation,
                attachmentSources: attachmentSources,
                request: request
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }
}

private enum IntegrationRuntimeFailure: Error, Equatable {
    case commit
    case sources
}

@MainActor
private final class IntegrationJobRuntime: WorkspaceReconstructionJobRuntime, @unchecked Sendable {
    enum Mode: Equatable {
        case succeed
        case failBeforeCommit
        case failAfterCommit
        case suspendBeforeCommit
        case malformedCoordinates
        case omitSources
    }

    enum Event: Equatable {
        case commitEntered
        case commitReturned
        case start
    }

    private let owner: ReconstructionDatabaseOwner
    private let attachmentSources: [ReconstructionAttachmentSource]
    private let mode: Mode
    private let startObservation: ((UUID) -> Bool)?
    private var commitEntered = false
    private var commitEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitRelease: CheckedContinuation<Void, Never>?
    private var commitIsReleased = false

    private(set) var events: [Event] = []
    private(set) var startObservedPublishedState: [Bool] = []
    private(set) var startedJobIDs: [UUID] = []
    private(set) var pausedJobIDs: [UUID] = []
    private(set) var resumedJobIDs: [UUID] = []
    private(set) var cancelledJobIDs: [UUID] = []
    private(set) var startedAuthorities: [ReconstructionJobCommandAuthority] = []
    private(set) var pausedAuthorities: [ReconstructionJobCommandAuthority] = []
    private(set) var resumedAuthorities: [ReconstructionJobCommandAuthority] = []
    private(set) var cancelledAuthorities: [ReconstructionJobCommandAuthority] = []

    init(
        owner: ReconstructionDatabaseOwner,
        attachmentSources: [ReconstructionAttachmentSource],
        mode: Mode = .succeed,
        startObservation: ((UUID) -> Bool)? = nil
    ) {
        self.owner = owner
        self.attachmentSources = attachmentSources
        self.mode = mode
        self.startObservation = startObservation
    }

    func commitInitialJob(
        workspaceID: UUID,
        mutation: ReconstructionInitialJobMutation
    ) async throws -> WorkspaceReconstructionInitialJobPublication {
        events.append(.commitEntered)
        commitEntered = true
        commitEntryWaiters.forEach { $0.resume() }
        commitEntryWaiters.removeAll()
        if mode == .failBeforeCommit {
            throw IntegrationRuntimeFailure.commit
        }
        if mode == .suspendBeforeCommit, !commitIsReleased {
            await withCheckedContinuation { commitRelease = $0 }
        }
        let durableMutation = mode == .malformedCoordinates
            ? ReconstructionInitialJobMutation(
                jobID: UUID(),
                projectID: mutation.projectID,
                selectedOccurrenceIDs: mutation.selectedOccurrenceIDs,
                objective: mutation.objective,
                budget: mutation.budget
            )
            : mutation
        let committed = try await owner.commitInitialJob(
            workspaceID: workspaceID,
            mutation: durableMutation
        )
        if mode == .failAfterCommit {
            throw IntegrationRuntimeFailure.sources
        }
        events.append(.commitReturned)
        return WorkspaceReconstructionInitialJobPublication(
            committed: committed,
            attachmentSources: mode == .omitSources ? [] : attachmentSources
        )
    }

    func start(authority: ReconstructionJobCommandAuthority) async -> Bool {
        events.append(.start)
        startedAuthorities.append(authority)
        startedJobIDs.append(authority.jobID)
        startObservedPublishedState.append(startObservation?(authority.jobID) ?? true)
        return true
    }

    func pause(authority: ReconstructionJobCommandAuthority) async -> Bool {
        pausedAuthorities.append(authority)
        pausedJobIDs.append(authority.jobID)
        return true
    }

    func resume(authority: ReconstructionJobCommandAuthority) async -> Bool {
        resumedAuthorities.append(authority)
        resumedJobIDs.append(authority.jobID)
        return true
    }

    func cancel(authority: ReconstructionJobCommandAuthority) async -> Bool {
        cancelledAuthorities.append(authority)
        cancelledJobIDs.append(authority.jobID)
        return true
    }

    func restoreAndResumeEligibleJobs() async -> Bool { true }

    func retireTransiently() async {}

    func waitUntilCommitEntered() async {
        if commitEntered { return }
        await withCheckedContinuation { commitEntryWaiters.append($0) }
    }

    func releaseCommit() {
        commitIsReleased = true
        commitRelease?.resume()
        commitRelease = nil
    }

    func resetCommandInvocations() {
        startedJobIDs = []
        pausedJobIDs = []
        resumedJobIDs = []
        cancelledJobIDs = []
        startedAuthorities = []
        pausedAuthorities = []
        resumedAuthorities = []
        cancelledAuthorities = []
    }
}

private actor IntegrationSourceLoaderGate {
    private let sources: [ReconstructionAttachmentSource]
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(sources: [ReconstructionAttachmentSource]) {
        self.sources = sources
    }

    func load(workspaceID _: UUID) async throws -> [ReconstructionAttachmentSource] {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return sources
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor IntegrationSourceLoaderProbe {
    private let sources: [ReconstructionAttachmentSource]
    private var count = 0

    init(sources: [ReconstructionAttachmentSource]) {
        self.sources = sources
    }

    func load(workspaceID _: UUID) -> [ReconstructionAttachmentSource] {
        count += 1
        return sources
    }

    func loadCount() -> Int {
        count
    }
}

private final class IntegrationImportProvider: AnalysisProviding, @unchecked Sendable {
    private let snapshot: WorkspaceSnapshot

    init(snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
    }

    func analyze(
        url _: URL,
        requestedSliceIndex _: Int?,
        overrides _: [UInt64: AddressOverride],
        cancellation _: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        snapshot
    }

    func openBinary(
        url _: URL,
        requestedSliceIndex _: Int?,
        overrides _: [UInt64: AddressOverride],
        cancellation _: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        snapshot
    }
}

import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceIntentPersistenceTests: XCTestCase {
    func testInitialJobCheckpointDatabaseReloadAndPhysicalPackageReopenPreserveSourceIntent() throws {
        let fixture = try fixture(); defer { fixture.package.remove() }
        let initial = try createSourceJob(fixture)
        XCTAssertEqual(initial.job.sourceProfileID, ReconstructionSourceExecutionTaskContract.profileID)
        XCTAssertEqual(initial.job.state, .created)
        XCTAssertTrue(initial.state.tasks.allSatisfy { $0.state == .pending })
        let initialReload = try fixture.database.database.loadReconstructionState(workspaceID: fixture.database.workspaceUUID)
        XCTAssertEqual(initialReload, initial.state)

        let advanced = try advance(fixture, initial: initial)
        let reloaded = try fixture.database.database.loadReconstructionState(workspaceID: fixture.database.workspaceUUID)
        XCTAssertEqual(reloaded, advanced)
        XCTAssertEqual(reloaded.jobs.first?.sourceProfileID, ReconstructionSourceExecutionTaskContract.profileID)
        XCTAssertEqual(reloaded.jobs.first?.state, .ingesting)
        XCTAssertTrue(reloaded.tasks.allSatisfy { $0.state == .pending })
        XCTAssertTrue(reloaded.evidence.isEmpty)
        XCTAssertTrue(reloaded.modelReceipts.isEmpty)
        XCTAssertTrue(reloaded.toolReceipts.isEmpty)

        try MacScopeDocumentPackage.writePackage(fixture.package.manifest,
            attachmentsByBinaryID: [fixture.package.binaryID: fixture.package.binaryBytes],
            reconstructionState: reloaded, reconstructionAttachmentSources: [fixture.package.source],
            to: fixture.package.packageURL)
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.package.packageURL)
        XCTAssertEqual(opened.reconstructionState, reloaded)
        XCTAssertEqual(opened.reconstructionState.jobs.first?.sourceProfileID, ReconstructionSourceExecutionTaskContract.profileID)
        let secondURL = fixture.package.root.appendingPathComponent("SourceIntentResaved.mscope")
        try MacScopeDocumentPackage.writePackage(opened.manifest,
            attachmentsByBinaryID: opened.attachmentsByBinaryID,
            reconstructionState: opened.reconstructionState,
            reconstructionAttachmentSources: opened.reconstructionAttachmentSources, to: secondURL,
            instructionSidecarData: opened.instructionSidecarData)
        let second = try MacScopeDocumentPackage.openPackage(from: secondURL)
        XCTAssertEqual(second.reconstructionState, reloaded)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(second.reconstructionState.jobs),
            try ReconstructionCanonicalJSON.encode(reloaded.jobs))
    }

    /// F3: durable created/started/finished lifecycle columns on job and task rows, stamped at
    /// commit time outside the canonical records, read by the job-status summary; rows without
    /// observed times (older databases) load as nil and stay nil.
    @MainActor func testJobAndTaskLifecycleTimestampsAreDurableAndOlderRowsLoadAsNil() throws {
        let fixture = try fixture(); defer { fixture.package.remove() }
        let database = fixture.database.database, workspaceID = fixture.database.workspaceUUID
        let before = UInt64(Date().timeIntervalSince1970 * 1_000)
        let initial = try createSourceJob(fixture)
        let jobID = initial.job.jobID
        XCTAssertEqual(initial.lifecycle, try database.reconstructionLifecycleTimestamps(workspaceID: workspaceID))
        let created = try XCTUnwrap(initial.lifecycle.jobs[jobID])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(created.createdAtMilliseconds), before)
        XCTAssertNil(created.startedAtMilliseconds, "a .created job has not started")
        XCTAssertNil(created.finishedAtMilliseconds)
        XCTAssertEqual(Set(initial.lifecycle.tasks.keys), Set(initial.state.tasks.map(\.identity.taskID)))
        XCTAssertTrue(initial.lifecycle.tasks.values.allSatisfy {
            $0.createdAtMilliseconds != nil && $0.startedAtMilliseconds == nil && $0.finishedAtMilliseconds == nil })
        // The canonical state is clock-free: reload is still byte-identical to the committed state.
        XCTAssertEqual(try database.loadReconstructionState(workspaceID: workspaceID), initial.state)

        let advanced = try advance(fixture, initial: initial)
        let afterAdvance = try database.reconstructionLifecycleTimestamps(workspaceID: workspaceID)
        let started = try XCTUnwrap(afterAdvance.jobs[jobID])
        XCTAssertEqual(started.createdAtMilliseconds, created.createdAtMilliseconds, "created is never restamped")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(started.startedAtMilliseconds), try XCTUnwrap(created.createdAtMilliseconds))
        XCTAssertNil(started.finishedAtMilliseconds)
        let summary = try XCTUnwrap(ReconstructionJobStatusSummary.make(jobID: jobID, state: advanced, lifecycle: afterAdvance))
        XCTAssertEqual(summary.lifecycle, started)
        XCTAssertNil(summary.elapsedMilliseconds, "no wall clock until the job finishes")
        let scripted = try WorkspaceScriptingAPI.reconstructionJobsStatus(.object(["job": .string(jobID.uuidString)]),
            state: advanced, lifecycle: afterAdvance)
        XCTAssertEqual(scripted.arrayValue?.first?["lifecycle"]?["createdAtMilliseconds"]?.stringValue,
            created.createdAtMilliseconds.map(String.init))

        // Older rows: NULL lifecycle columns load as nil and are not given a partial clock later.
        try database.executeRawForTesting(
            "UPDATE reconstruction_jobs SET created_at_ms = NULL, started_at_ms = NULL, finished_at_ms = NULL;")
        try database.executeRawForTesting(
            "UPDATE reconstruction_tasks SET created_at_ms = NULL, started_at_ms = NULL, finished_at_ms = NULL;")
        XCTAssertEqual(try database.reconstructionLifecycleTimestamps(workspaceID: workspaceID), .empty)
        try database.replaceReconstructionState(workspaceID: workspaceID, state: advanced)
        XCTAssertEqual(try database.reconstructionLifecycleTimestamps(workspaceID: workspaceID), .empty)
        let legacy = try XCTUnwrap(ReconstructionJobStatusSummary.make(jobID: jobID, state: advanced,
            lifecycle: try database.reconstructionLifecycleTimestamps(workspaceID: workspaceID)))
        XCTAssertNil(legacy.lifecycle)
        XCTAssertNil(legacy.elapsedSource)
        // Re-applying the schema is idempotent (the column add runs on every open).
        try database.applySchema()
        XCTAssertEqual(try database.loadReconstructionState(workspaceID: workspaceID), advanced)
    }

    func testCheckpointDescendantsCannotGainOrLoseSourceIntent() throws {
        let fixture = try fixture(); defer { fixture.package.remove() }
        let initial = try createSourceJob(fixture)
        let advanced = try advance(fixture, initial: initial)
        let binding = ReconstructionWorkspaceStateBinding(workspaceID: fixture.database.workspaceUUID,
            documentID: UUID(), canonicalPackagePath: fixture.package.packageURL.path)
        let profiles: [String?] = [nil, ReconstructionSourceExecutionTaskContract.profileID]
        for profile in profiles {
            let ancestor = try replacingProfile(initial.state, with: profile)
            let descendant = try replacingProfile(advanced, with: profile)
            let control = try reconcile(ancestor: ancestor, descendant: descendant, binding: binding)
            guard case .useDurableDescendant(let resolution) = control else {
                return XCTFail("Expected valid pending-job descendant, got \(control)")
            }
            XCTAssertEqual(resolution.state, descendant)
            let changedProfile = profile == nil ? ReconstructionSourceExecutionTaskContract.profileID : nil
            let drifted = try replacingProfile(advanced, with: changedProfile)
            XCTAssertEqual(try reconcile(ancestor: ancestor, descendant: drifted, binding: binding),
                .conflict(.immutableRecordDrift(.job, initial.job.jobID.uuidString.lowercased())))
        }
    }

    private typealias Fixture = (database: ReconstructionDatabaseTestFixtures.DatabaseFixture, package: ReconstructionPackageFixture)
    private func fixture() throws -> Fixture {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let package = try ReconstructionPackageFixture.make()
        do {
            try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID, state: package.state)
            return (database, package)
        } catch { package.remove(); throw error }
    }
    private func createSourceJob(_ fixture: Fixture) throws -> ReconstructionCommittedInitialJob {
        let project = try XCTUnwrap(fixture.package.state.projects.first)
        let occurrence = try XCTUnwrap(fixture.package.state.corpusManifests.first?.artifacts.first)
        return try fixture.database.database.commitInitialReconstructionJob(workspaceID: fixture.database.workspaceUUID,
            mutation: .init(jobID: UUID(), projectID: project.projectID,
                selectedOccurrenceIDs: [occurrence.occurrenceID], objective: "Explicit app-owned fixed source target",
                budget: .init(maxRounds: 2, maxTasks: 20, maxEvidenceRecords: 20, maxEncodedBytes: 1_048_576),
                focus: .artifact(.init(occurrenceID: occurrence.occurrenceID, contentIdentity: occurrence.contentIdentity)),
                sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
    }
    private func advance(_ fixture: Fixture, initial: ReconstructionCommittedInitialJob) throws -> ReconstructionWorkspaceState {
        let parent = initial.checkpoint
        let successor = try ReconstructionCheckpoint.make(checkpointID: UUID(), jobID: initial.job.jobID,
            revision: parent.revision + 1, parentCheckpointID: parent.checkpointID,
            parentCheckpointSHA256: parent.canonicalSHA256, corpusManifestSHA256: parent.corpusManifestSHA256,
            evidenceFrontierSHA256: parent.evidenceFrontierSHA256, pendingTaskIDs: parent.pendingTaskIDs,
            runningTaskIDs: [], completedTaskIDs: [], failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: parent.unresolvedEvidenceGapSHA256, modelReceiptIDs: [], toolReceiptIDs: [],
            coordinatorState: .ingesting, terminalReason: nil)
        let manifest = try XCTUnwrap(initial.state.corpusManifests.first)
        let authority = try ReconstructionFreshnessAuthority(corpusManifestSHA256: manifest.canonicalSHA256,
            currentArtifacts: manifest.artifacts.map { .init(occurrenceID: $0.occurrenceID, contentIdentity: $0.contentIdentity) },
            currentImages: [], currentFacetFingerprints: [:])
        return try fixture.database.database.commitReconstructionCheckpoint(workspaceID: fixture.database.workspaceUUID,
            mutation: .init(jobID: initial.job.jobID, expectedParentCheckpointID: parent.checkpointID,
                expectedParentCheckpointSHA256: parent.canonicalSHA256, expectedParentRevision: parent.revision,
                evidence: [], evidenceRelations: [], toolReceipts: [], modelReceipts: [], taskTransitions: [],
                freshnessAuthority: authority, successorCheckpoint: successor)).state
    }
    private func replacingProfile(_ state: ReconstructionWorkspaceState, with profile: String?) throws -> ReconstructionWorkspaceState {
        let jobs = try state.jobs.map { job in
            try ReconstructionJobRecord(jobID: job.jobID, reconstructionProjectID: job.reconstructionProjectID,
                objective: job.objective, objectiveSHA256: job.objectiveSHA256,
                creationCorpusManifestSHA256: job.creationCorpusManifestSHA256, state: job.state,
                currentCheckpointID: job.currentCheckpointID, terminalReason: job.terminalReason, budget: job.budget,
                creationOrdinal: XCTUnwrap(job.creationOrdinal), pauseContext: job.pauseContext,
                focus: job.focus, sourceProfileID: profile)
        }
        return try ReconstructionWorkspaceState(projects: state.projects, corpusManifests: state.corpusManifests,
            evidence: state.evidence, evidenceRelations: state.evidenceRelations, evidenceGaps: state.evidenceGaps,
            jobs: jobs, tasks: state.tasks, checkpoints: state.checkpoints, toolReceipts: state.toolReceipts,
            modelReceipts: state.modelReceipts, finalResults: state.finalResults)
    }
    private func reconcile(ancestor: ReconstructionWorkspaceState, descendant: ReconstructionWorkspaceState,
                           binding: ReconstructionWorkspaceStateBinding) throws -> ReconstructionWorkspaceStateReconciliationDecision {
        func cut(_ state: ReconstructionWorkspaceState) throws -> ReconstructionWorkspaceStateCut {
            .init(binding: binding, state: state, contentAvailability: try ReconstructionPackageCodec.contentRecords(in: state).map {
                .init(contentIdentity: $0.contentIdentity, isAvailable: true)
            })
        }
        return try ReconstructionWorkspaceStateReconciler.reconcile(package: cut(ancestor),
            durable: .present(cut: cut(descendant), corpusBasis: .trustedSamePathAppOwned))
    }
}

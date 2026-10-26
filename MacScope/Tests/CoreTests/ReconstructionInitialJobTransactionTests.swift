import Dispatch
import Foundation
import XCTest
@testable import MacScope

private enum OwnerPostcheckProbeError: Error, Equatable {
    case pathAuthorityChanged
}

private final class LockedOwnerPostcheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

final class ReconstructionInitialJobTransactionTests: XCTestCase {
    func testInitialProfileAdmissionPreservesLegacyAndRejectsDisabledAtomically() async throws {
        let fixture = try makeOwnedFixture()
        let before = try await fixture.owner.load(workspaceID: fixture.workspaceID)
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            let base = mutation(jobID: UUID(), projectID: fixture.projectID,
                occurrenceID: fixture.occurrenceID, objective: "Profile admission boundary")
            let intent = ReconstructionInitialJobMutation(jobID: base.jobID, projectID: base.projectID,
                selectedOccurrenceIDs: base.selectedOccurrenceIDs, objective: base.objective,
                budget: base.budget, sourceProfileID: profile)
            let error = await captureError {
                _ = try await fixture.owner.commitInitialJob(workspaceID: fixture.workspaceID, mutation: intent)
            }
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("initial job source profile"))
            let after = try await fixture.owner.load(workspaceID: fixture.workspaceID)
            XCTAssertEqual(after, before)
        }
        for profile in [nil, ReconstructionSourceRevision.profileID] as [String?] {
            let base = mutation(jobID: UUID(), projectID: fixture.projectID,
                occurrenceID: fixture.occurrenceID, objective: "Retain initial job compatibility")
            let intent = ReconstructionInitialJobMutation(jobID: base.jobID, projectID: base.projectID,
                selectedOccurrenceIDs: base.selectedOccurrenceIDs, objective: base.objective,
                budget: base.budget, sourceProfileID: profile)
            let committed = try await fixture.owner.commitInitialJob(workspaceID: fixture.workspaceID, mutation: intent)
            XCTAssertEqual(committed.job.sourceProfileID, profile)
            XCTAssertEqual(committed.checkpoint.revision, 0,
                "Initial creation must not require a future original-function observation")
        }
    }

    func testFunctionFocusPersistsAndStaleAnalysisRejectsAtomically() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let rich = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID, evidenceSubjectUsesFunction: true
        )
        try fixture.database.replaceReconstructionState(workspaceID: fixture.workspaceUUID, state: rich)
        let focus = try XCTUnwrap(rich.evidence.first?.subject)
        let occurrence = try XCTUnwrap(rich.corpusManifests.first?.artifacts.first)
        let project = try XCTUnwrap(rich.projects.first)
        let base = mutation(jobID: Self.firstJobID, projectID: project.projectID,
            occurrenceID: occurrence.occurrenceID, objective: "Recover committed function")
        let intent = ReconstructionInitialJobMutation(jobID: base.jobID, projectID: base.projectID,
            selectedOccurrenceIDs: base.selectedOccurrenceIDs, objective: base.objective,
            budget: base.budget, focus: focus)
        let committed = try fixture.database.commitInitialReconstructionJob(
            workspaceID: fixture.workspaceUUID, mutation: intent)
        XCTAssertEqual(committed.job.focus, focus)
        XCTAssertEqual(try fixture.database.loadReconstructionState(
            workspaceID: fixture.workspaceUUID), committed.state)
        try ReconstructionDatabaseTestFixtures.replacePersistedAnalysisFingerprint(in: fixture,
            overallSHA256: ReconstructionDatabaseTestFixtures.digest("4"))
        let before = try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID)
        let stale = ReconstructionInitialJobMutation(jobID: UUID(), projectID: base.projectID,
            selectedOccurrenceIDs: base.selectedOccurrenceIDs, objective: base.objective,
            budget: base.budget, focus: focus)
        XCTAssertThrowsError(try fixture.database.commitInitialReconstructionJob(
            workspaceID: fixture.workspaceUUID, mutation: stale))
        XCTAssertEqual(try fixture.database.loadReconstructionState(
            workspaceID: fixture.workspaceUUID), before)
    }

    func testArtifactFocusPersistsAndRejectsUnselectedOccurrence() async throws {
        let fixture = try makeOwnedFixture()
        let state = try await fixture.owner.load(workspaceID: fixture.workspaceID)
        let occurrence = try XCTUnwrap(state.corpusManifests.first?.artifacts.first)
        let focus = ReconstructionSubjectCoordinate.artifact(.init(
            occurrenceID: occurrence.occurrenceID, contentIdentity: occurrence.contentIdentity
        ))
        let base = mutation(jobID: Self.firstJobID, projectID: fixture.projectID,
            occurrenceID: fixture.occurrenceID, objective: "Recover focused executable")
        let intent = ReconstructionInitialJobMutation(jobID: base.jobID, projectID: base.projectID,
            selectedOccurrenceIDs: base.selectedOccurrenceIDs, objective: base.objective,
            budget: base.budget, focus: focus)
        let committed = try await fixture.owner.commitInitialJob(workspaceID: fixture.workspaceID,
            mutation: intent)
        XCTAssertEqual(committed.job.focus, focus)
        let reloaded = try await fixture.owner.load(workspaceID: fixture.workspaceID)
        XCTAssertEqual(reloaded.jobs.first?.focus, focus)

        let wrongFocus = ReconstructionSubjectCoordinate.artifact(.init(
            occurrenceID: .init(rawValue: UUID()), contentIdentity: occurrence.contentIdentity
        ))
        let rejected = ReconstructionInitialJobMutation(jobID: UUID(), projectID: base.projectID,
            selectedOccurrenceIDs: base.selectedOccurrenceIDs, objective: base.objective,
            budget: base.budget, focus: wrongFocus)
        let error = await captureError {
            _ = try await fixture.owner.commitInitialJob(workspaceID: fixture.workspaceID,
                mutation: rejected)
        }
        XCTAssertNotNil(error)
        let after = try await fixture.owner.load(workspaceID: fixture.workspaceID)
        XCTAssertEqual(after, reloaded)
    }

    func testCreationAtomicallyPersistsJobTaskGraphAndCanonicalRevisionZero() async throws {
        let fixture = try makeOwnedFixture()
        let owner = fixture.owner

        let committed = try await owner.commitInitialJob(
            workspaceID: fixture.workspaceID,
            mutation: mutation(
                jobID: Self.firstJobID,
                projectID: fixture.projectID,
                occurrenceID: fixture.occurrenceID,
                objective: "  Recover the selected executable  "
            )
        )

        XCTAssertEqual(committed.commitSequence, 1)
        XCTAssertEqual(committed.job.objective, "Recover the selected executable")
        XCTAssertEqual(committed.job.creationOrdinal, 1)
        XCTAssertEqual(committed.checkpoint.revision, 0)
        XCTAssertNil(committed.checkpoint.parentCheckpointID)
        XCTAssertEqual(committed.checkpoint.pendingTaskIDs.count, 4)
        XCTAssertEqual(committed.state.tasks.count, 4)
        XCTAssertEqual(Set(committed.state.tasks.map(\.identity.kind)), [
            .ingest, .classify, .discoverRelations, .loadBinary,
        ])
        for task in committed.state.tasks {
            try task.identity.verifyCanonicalIdentity()
        }
        let tasksByKind = Dictionary(uniqueKeysWithValues: committed.state.tasks.map {
            ($0.identity.kind, $0)
        })
        let ingestID = try XCTUnwrap(tasksByKind[.ingest]?.identity.taskID)
        let classifyID = try XCTUnwrap(tasksByKind[.classify]?.identity.taskID)
        XCTAssertEqual(tasksByKind[.ingest]?.identity.dependencyTaskIDs, [])
        XCTAssertEqual(tasksByKind[.classify]?.identity.dependencyTaskIDs, [ingestID])
        XCTAssertEqual(tasksByKind[.discoverRelations]?.identity.dependencyTaskIDs, [classifyID])
        XCTAssertEqual(tasksByKind[.loadBinary]?.identity.dependencyTaskIDs, [ingestID])
        XCTAssertFalse(committed.state.tasks.contains { task in
            task.identity.kind == .indexImage || task.identity.kind == .enumerateFunctions
        })
        try committed.checkpoint.verifyCanonicalIdentity()
        let reloaded = try await owner.load(workspaceID: fixture.workspaceID)
        XCTAssertEqual(reloaded, committed.state)
    }

    func testRevokedOwnerRejectsEveryEntryPointWithoutChangingDurableState() async throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: foundation.state
        )
        let workspaceID = databaseFixture.workspaceUUID
        let before = try databaseFixture.database.loadReconstructionState(
            workspaceID: workspaceID
        )
        XCTAssertEqual(before, foundation.state)
        let admittedDatabaseOperations = LockedOwnerPostcheckCounter()
        let owner = ReconstructionDatabaseOwner(
            database: databaseFixture.database,
            databaseAuthorityValidator: {
                admittedDatabaseOperations.increment()
            }
        )
        let checkpointMutation = try ReconstructionDatabaseTestFixtures.makeMutation(
            from: foundation
        )
        let initialMutation = mutation(
            jobID: Self.firstJobID,
            projectID: foundation.project.projectID,
            occurrenceID: foundation.occurrence.occurrenceID,
            objective: "Must not commit after revocation"
        )
        let corpusMutation = ReconstructionCorpusMutation(
            projectID: foundation.project.projectID,
            expectedCurrentManifestSHA256: foundation.manifest.canonicalSHA256,
            successorManifest: foundation.manifest,
            attachmentSources: []
        )
        await owner.revoke()
        await owner.revoke()

        var errors: [Error?] = []
        errors.append(await captureError {
            _ = try await owner.load(workspaceID: workspaceID)
        })
        errors.append(await captureError {
            _ = try await owner.reconstructionProjectionSnapshotForTesting(
                workspaceID: workspaceID
            )
        })
        errors.append(await captureError {
            _ = try await owner.commitCorpus(
                workspaceID: workspaceID,
                mutation: corpusMutation
            )
        })
        errors.append(await captureError {
            _ = try await owner.commitInitialJob(
                workspaceID: workspaceID,
                mutation: initialMutation
            )
        })
        errors.append(await captureError {
            _ = try await owner.availableDurableAttachmentSources(
                workspaceID: workspaceID
            )
        })
        errors.append(await captureError {
            _ = try await owner.captureProductionRoundRows(
                workspaceID: workspaceID,
                jobID: foundation.job.jobID
            )
        })
        errors.append(await captureError {
            _ = try await owner.commit(checkpointMutation)
        })
        errors.append(await captureError {
            _ = try await owner.commit(
                workspaceID: workspaceID,
                mutation: checkpointMutation
            )
        })

        XCTAssertEqual(errors.count, 8)
        for error in errors {
            XCTAssertEqual(error as? ReconstructionDatabaseOwnerError, .revoked)
        }
        XCTAssertEqual(admittedDatabaseOperations.value, 0)
    }

    func testRevocationWaitsForAnAdmittedOwnerOperationToDrain() async throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: foundation.state
        )
        let workspaceID = databaseFixture.workspaceUUID
        let operationEntered = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let revocationFinished = DispatchSemaphore(value: 0)
        let owner = ReconstructionDatabaseOwner(
            database: databaseFixture.database,
            databaseAuthorityValidator: {
                operationEntered.signal()
                allowOperationToFinish.wait()
            }
        )
        let load = Task {
            try await owner.load(workspaceID: workspaceID)
        }
        XCTAssertEqual(
            operationEntered.wait(timeout: .now() + 1),
            .success,
            "Owner operation never reached the authority barrier"
        )
        let revoke = Task {
            await owner.revoke()
            revocationFinished.signal()
        }

        XCTAssertEqual(
            revocationFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "Revocation returned before the admitted owner operation drained"
        )
        allowOperationToFinish.signal()
        XCTAssertEqual(
            revocationFinished.wait(timeout: .now() + 1),
            .success,
            "Revocation did not finish after the owner operation drained"
        )
        let loaded = try await load.value
        XCTAssertEqual(loaded, foundation.state)
        await revoke.value
    }

    func testOwnerPostvalidatesEveryCompletedOperationWithoutMaskingPrimaryFailure()
        async throws
    {
        let successfulDatabaseFixture = try ReconstructionDatabaseTestFixtures
            .makeCurrentDatabase()
        let successfulFoundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: successfulDatabaseFixture.binaryID
        )
        try successfulDatabaseFixture.database.replaceReconstructionState(
            workspaceID: successfulDatabaseFixture.workspaceUUID,
            state: successfulFoundation.state
        )
        let successfulWorkspaceID = successfulDatabaseFixture.workspaceUUID
        let successfulPostchecks = LockedOwnerPostcheckCounter()
        let successfulOwner = ReconstructionDatabaseOwner(
            database: successfulDatabaseFixture.database,
            databaseAuthorityPostvalidator: {
                successfulPostchecks.increment()
            }
        )
        _ = try await successfulOwner.load(workspaceID: successfulWorkspaceID)
        XCTAssertEqual(successfulPostchecks.value, 1)

        let rejectingDatabaseFixture = try ReconstructionDatabaseTestFixtures
            .makeCurrentDatabase()
        let rejectingFoundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: rejectingDatabaseFixture.binaryID
        )
        try rejectingDatabaseFixture.database.replaceReconstructionState(
            workspaceID: rejectingDatabaseFixture.workspaceUUID,
            state: rejectingFoundation.state
        )
        let rejectingWorkspaceID = rejectingDatabaseFixture.workspaceUUID
        let rejectingPostchecks = LockedOwnerPostcheckCounter()
        let rejectingOwner = ReconstructionDatabaseOwner(
            database: rejectingDatabaseFixture.database,
            databaseAuthorityPostvalidator: {
                rejectingPostchecks.increment()
                throw OwnerPostcheckProbeError.pathAuthorityChanged
            }
        )
        let postcheckError = await captureError {
            _ = try await rejectingOwner.load(workspaceID: rejectingWorkspaceID)
        }
        XCTAssertEqual(
            postcheckError as? OwnerPostcheckProbeError,
            .pathAuthorityChanged
        )
        XCTAssertEqual(rejectingPostchecks.value, 1)

        let primaryError = await captureError {
            _ = try await rejectingOwner.captureProductionRoundRows(
                workspaceID: rejectingWorkspaceID,
                jobID: UUID()
            )
        }
        XCTAssertNotNil(primaryError)
        XCTAssertNil(primaryError as? OwnerPostcheckProbeError)
        XCTAssertEqual(
            rejectingPostchecks.value,
            2,
            "The post-check must run even when the database operation throws"
        )
    }

    func testDurableCreationOrderDoesNotCollapseBackToUUIDOrder() async throws {
        let fixture = try makeOwnedFixture()
        let owner = fixture.owner
        for jobID in [Self.firstJobID, Self.secondJobID] {
            _ = try await owner.commitInitialJob(
                workspaceID: fixture.workspaceID,
                mutation: mutation(
                    jobID: jobID,
                    projectID: fixture.projectID,
                    occurrenceID: fixture.occurrenceID,
                    objective: "Recover \(jobID.uuidString)"
                )
            )
        }

        let state = try await owner.load(workspaceID: fixture.workspaceID)
        XCTAssertEqual(state.jobs.map(\.jobID), [Self.firstJobID, Self.secondJobID])
        XCTAssertEqual(state.jobs.compactMap(\.creationOrdinal), [1, 2])
        XCTAssertGreaterThan(Self.firstJobID.uuidString, Self.secondJobID.uuidString)

        let persistence = ReconstructionDatabaseJobPersistence(
            workspaceID: fixture.workspaceID,
            owner: owner
        )
        let first = try await persistence.load(jobID: Self.firstJobID)
        let second = try await persistence.load(jobID: Self.secondJobID)
        XCTAssertEqual(first.jobCreationOrder, 1)
        XCTAssertEqual(second.jobCreationOrder, 2)

        let gappedJobs = try state.jobs.map { job in
            try job.upgraded(creationOrdinal: job.jobID == Self.secondJobID ? 3 : 1)
        }
        XCTAssertThrowsError(try ReconstructionWorkspaceState(
            projects: state.projects,
            corpusManifests: state.corpusManifests,
            evidence: state.evidence,
            evidenceRelations: state.evidenceRelations,
            evidenceGaps: state.evidenceGaps,
            jobs: gappedJobs,
            tasks: state.tasks,
            checkpoints: state.checkpoints,
            toolReceipts: state.toolReceipts,
            modelReceipts: state.modelReceipts
        ))
    }

    func testLegacyDatabaseStateNormalizesBeforeAllocatingNextOrdinal() throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        let currentJob = try XCTUnwrap(foundation.state.jobs.first)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ReconstructionCanonicalJSON.encode(currentJob)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "recordSchemaVersion")
        legacyObject.removeValue(forKey: "creationOrdinal")
        legacyObject.removeValue(forKey: "pauseContext")
        let legacyJob = try JSONDecoder().decode(
            ReconstructionJobRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        )
        let legacyState = try ReconstructionWorkspaceState(
            projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests,
            evidence: foundation.state.evidence,
            evidenceRelations: foundation.state.evidenceRelations,
            evidenceGaps: foundation.state.evidenceGaps,
            jobs: [legacyJob],
            tasks: foundation.state.tasks,
            checkpoints: foundation.state.checkpoints,
            toolReceipts: foundation.state.toolReceipts,
            modelReceipts: foundation.state.modelReceipts
        )
        XCTAssertTrue(legacyState.jobs.allSatisfy { $0.creationOrdinal == nil })
        let legacyStateData = try ReconstructionCanonicalJSON.encode(legacyState)
        let legacyJobData = try ReconstructionCanonicalJSON.encode(legacyJob)
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: foundation.state
        )
        try databaseFixture.database.executeRawForTesting(
            """
            UPDATE reconstruction_projects
            SET state_json = \(sqliteBlobLiteral(legacyStateData))
            WHERE workspace_uuid = '\(databaseFixture.workspaceUUID.uuidString)';
            UPDATE reconstruction_jobs
            SET record_json = \(sqliteBlobLiteral(legacyJobData))
            WHERE workspace_uuid = '\(databaseFixture.workspaceUUID.uuidString)'
              AND job_id = '\(legacyJob.jobID.uuidString)';
            """
        )

        let normalized = try databaseFixture.database.loadReconstructionState(
            workspaceID: databaseFixture.workspaceUUID
        )
        XCTAssertEqual(normalized.jobs.map(\.recordSchemaVersion), [ReconstructionJobRecord.schemaVersion])
        XCTAssertEqual(normalized.jobs.compactMap(\.creationOrdinal), [1])

        let committed = try databaseFixture.database.commitInitialReconstructionJob(
            workspaceID: databaseFixture.workspaceUUID,
            mutation: mutation(
                jobID: Self.firstJobID,
                projectID: foundation.project.projectID,
                occurrenceID: foundation.occurrence.occurrenceID,
                objective: "Recover alongside legacy state"
            )
        )
        XCTAssertEqual(committed.job.creationOrdinal, 2)
        XCTAssertEqual(committed.state.jobs.map(\.recordSchemaVersion),
            [ReconstructionJobRecord.schemaVersion, ReconstructionJobRecord.schemaVersion])
        XCTAssertEqual(committed.state.jobs.compactMap(\.creationOrdinal), [1, 2])
    }

    func testInvalidCreationIntentLeavesNoPartialState() async throws {
        let fixture = try makeFixture()
        let before = try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID)
        let unknown = ReconstructionArtifactOccurrenceID(rawValue: UUID())

        for invalid in [
            mutation(
                jobID: Self.firstJobID,
                projectID: fixture.projectID,
                occurrenceID: fixture.occurrenceID,
                objective: "   "
            ),
            mutation(
                jobID: Self.firstJobID,
                projectID: fixture.projectID,
                occurrenceID: unknown,
                objective: "Recover"
            ),
        ] {
            XCTAssertThrowsError(try fixture.database.commitInitialReconstructionJob(
                workspaceID: fixture.workspaceID,
                mutation: invalid
            ))
            XCTAssertEqual(
                try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID),
                before
            )
        }
    }

    func testInitialGraphFailsClosedWhenArtifactWorkExceedsTaskBudget() throws {
        let fixture = try makeFixture()
        let before = try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID)
        let undersized = ReconstructionInitialJobMutation(
            jobID: Self.firstJobID,
            projectID: fixture.projectID,
            selectedOccurrenceIDs: [fixture.occurrenceID],
            objective: "Recover",
            budget: try ReconstructionJobBudget(
                maxRounds: 8,
                maxTasks: 3,
                maxEvidenceRecords: 512,
                maxEncodedBytes: 4 * 1_024 * 1_024
            )
        )

        XCTAssertThrowsError(try fixture.database.commitInitialReconstructionJob(
            workspaceID: fixture.workspaceID,
            mutation: undersized
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("initial job task budget")
            )
        }
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID),
            before
        )
    }

    func testInitialGraphFailsClosedWhenCombinedAuthorityExceedsEncodedByteBudget()
        async throws
    {
        let sizingFixture = try makeOwnedFixture()
        let sized = try await sizingFixture.owner.commitInitialJob(
            workspaceID: sizingFixture.workspaceID,
            mutation: mutation(
                jobID: Self.firstJobID,
                projectID: sizingFixture.projectID,
                occurrenceID: sizingFixture.occurrenceID,
                objective: "Recover"
            )
        )
        let sizedTasks = sized.state.tasks.filter {
            $0.identity.jobID == sized.job.jobID
        }
        let individualByteCounts = [
            UInt64(try ReconstructionCanonicalJSON.encode(sizedTasks).count),
            sized.checkpoint.canonicalEncodedByteCount,
            UInt64(try ReconstructionCanonicalJSON.encode(sized.job).count),
        ]
        let maximumIndividualByteCount = try XCTUnwrap(individualByteCounts.max())
        XCTAssertGreaterThan(individualByteCounts.reduce(0, +), maximumIndividualByteCount)

        let fixture = try makeFixture()
        let before = try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID)
        let bounded = ReconstructionInitialJobMutation(
            jobID: Self.firstJobID,
            projectID: fixture.projectID,
            selectedOccurrenceIDs: [fixture.occurrenceID],
            objective: "Recover",
            budget: try ReconstructionJobBudget(
                maxRounds: 8,
                maxTasks: 128,
                maxEvidenceRecords: 512,
                maxEncodedBytes: maximumIndividualByteCount
            )
        )
        XCTAssertThrowsError(try fixture.database.commitInitialReconstructionJob(
            workspaceID: fixture.workspaceID,
            mutation: bounded
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .reconstructionStateInvalid("initial job authority encoded byte budget")
            )
        }
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID),
            before
        )
    }

    func testInjectedSQLFailureRollsBackInitialJobAndProjection() throws {
        for phase in WorkspaceDatabase.ReconstructionMutationPhase.allCases {
            let fixture = try makeFixture()
            let beforeState = try fixture.database.loadReconstructionState(
                workspaceID: fixture.workspaceID
            )
            let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
                workspaceID: fixture.workspaceID
            )
            fixture.database.setReconstructionMutationFailureForTesting(after: phase)

            XCTAssertThrowsError(try fixture.database.commitInitialReconstructionJob(
                workspaceID: fixture.workspaceID,
                mutation: mutation(
                    jobID: Self.firstJobID,
                    projectID: fixture.projectID,
                    occurrenceID: fixture.occurrenceID,
                    objective: "Recover"
                )
            ))
            XCTAssertEqual(
                try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceID),
                beforeState,
                "\(phase.rawValue) changed durable state"
            )
            XCTAssertEqual(
                try fixture.database.reconstructionProjectionSnapshotForTesting(
                    workspaceID: fixture.workspaceID
                ),
                beforeProjection,
                "\(phase.rawValue) changed projected rows"
            )
        }
    }

    private struct Fixture {
        let database: WorkspaceDatabase
        let workspaceID: UUID
        let projectID: UUID
        let occurrenceID: ReconstructionArtifactOccurrenceID
    }

    private struct OwnedFixture {
        let owner: ReconstructionDatabaseOwner
        let workspaceID: UUID
        let projectID: UUID
        let occurrenceID: ReconstructionArtifactOccurrenceID
    }

    private static let firstJobID = UUID(
        uuidString: "f0000000-0000-0000-0000-000000000001"
    )!
    private static let secondJobID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    )!

    private func makeFixture() throws -> Fixture {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        let seed = try ReconstructionWorkspaceState(
            projects: [foundation.project],
            corpusManifests: [foundation.manifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: seed
        )
        return Fixture(
            database: databaseFixture.database,
            workspaceID: databaseFixture.workspaceUUID,
            projectID: foundation.project.projectID,
            occurrenceID: foundation.occurrence.occurrenceID
        )
    }

    private func makeOwnedFixture() throws -> OwnedFixture {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: databaseFixture.binaryID
        )
        let seed = try ReconstructionWorkspaceState(
            projects: [foundation.project],
            corpusManifests: [foundation.manifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
        try databaseFixture.database.replaceReconstructionState(
            workspaceID: databaseFixture.workspaceUUID,
            state: seed
        )
        let workspaceID = databaseFixture.workspaceUUID
        let projectID = foundation.project.projectID
        let occurrenceID = foundation.occurrence.occurrenceID
        let owner = ReconstructionDatabaseOwner(database: databaseFixture.database)
        return OwnedFixture(
            owner: owner,
            workspaceID: workspaceID,
            projectID: projectID,
            occurrenceID: occurrenceID
        )
    }

    private func mutation(
        jobID: UUID,
        projectID: UUID,
        occurrenceID: ReconstructionArtifactOccurrenceID,
        objective: String
    ) -> ReconstructionInitialJobMutation {
        ReconstructionInitialJobMutation(
            jobID: jobID,
            projectID: projectID,
            selectedOccurrenceIDs: [occurrenceID],
            objective: objective,
            budget: try! ReconstructionJobBudget(
                maxRounds: 8,
                maxTasks: 128,
                maxEvidenceRecords: 512,
                maxEncodedBytes: 4 * 1_024 * 1_024
            )
        )
    }

    private func sqliteBlobLiteral(_ data: Data) -> String {
        "X'\(data.map { String(format: "%02x", $0) }.joined())'"
    }

    private func captureError(
        _ operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }
}

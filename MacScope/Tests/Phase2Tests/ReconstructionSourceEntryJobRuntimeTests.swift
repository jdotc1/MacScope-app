import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ReconstructionSourceEntryJobRuntimeTests: XCTestCase {
    func testCapturedImportMustMatchOneCurrentOccurrenceAndExactBytes() throws {
        let fixture = try EntryRuntimeFixture()
        let item = fixture.item
        let occurrence = try XCTUnwrap(fixture.state.corpusManifests.first?.artifacts.first)
        let candidate = ReconstructionSourceOriginalSession.ImportCandidate(
            executableURL: TestWorkRoot.authorityURL("controlled-candidate"),
            executable: .init(device: 1, inode: 1, byteCount: Int(item.contentIdentity.byteCount),
                              sha256: item.contentIdentity.digest),
            sourceSHA256: String(repeating: "a", count: 64),
            harnessSHA256: String(repeating: "b", count: 64), profileID: ReconstructionSourceRevision.profileID)
        let request = try ReconstructionSourceEntryJobRuntime.creationRequest(candidate: candidate,
            imported: [occurrence], committedItems: [item])
        XCTAssertEqual(request.focus, .artifact(item.artifactCoordinate))
        XCTAssertEqual(request.selectedItems, [item])
        XCTAssertEqual(request.budget.maxRounds, 8)
        XCTAssertEqual(request.sourceProfileID, ReconstructionSourceExecutionTaskContract.profileID)
        XCTAssertThrowsError(try ReconstructionSourceEntryJobRuntime.creationRequest(candidate: candidate,
            imported: [occurrence, occurrence], committedItems: [item]))
        XCTAssertThrowsError(try ReconstructionSourceEntryJobRuntime.creationRequest(candidate: candidate,
            imported: [occurrence], committedItems: []))
        let wrong = ReconstructionSourceOriginalSession.ImportCandidate(
            executableURL: candidate.executableURL,
            executable: .init(device: 1, inode: 1, byteCount: candidate.executable.byteCount + 1,
                              sha256: candidate.executable.sha256),
            sourceSHA256: candidate.sourceSHA256, harnessSHA256: candidate.harnessSHA256,
            profileID: candidate.profileID)
        XCTAssertThrowsError(try ReconstructionSourceEntryJobRuntime.creationRequest(candidate: wrong,
            imported: [occurrence], committedItems: [item]))
    }

    func testRegistrationCompletesBeforePublicationAndOnlyBoundJobCanStart() async throws {
        let fixture = try EntryRuntimeFixture()
        let proxy = ReconstructionSourceEntryJobRuntime(runtime: fixture,
            artifact: fixture.item.artifactCoordinate, projectID: fixture.item.projectID,
            validateCoordinate: {}, bindAndRegister: { project, job in
                XCTAssertEqual(project, fixture.item.projectID)
                fixture.events.append("register")
                fixture.registeredJob = job
            })
        let publication = try await proxy.commitInitialJob(workspaceID: fixture.workspaceID,
            mutation: fixture.mutation())
        XCTAssertEqual(fixture.events, ["commit", "register"])
        XCTAssertEqual(proxy.registeredJobID, publication.committed.job.jobID)
        XCTAssertEqual(publication.committed.job.sourceProfileID, ReconstructionSourceExecutionTaskContract.profileID)
        let accepted = await proxy.start(authority: fixture.authority(publication.committed))
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.events, ["commit", "register", "start"])
        let rejected = await proxy.start(authority: fixture.authority(publication.committed, jobID: UUID()))
        XCTAssertFalse(rejected)
        await proxy.retireTransiently()
        XCTAssertEqual(fixture.events, ["commit", "register", "start"])
    }

    func testInvalidSelectionNeverCommitsOrRegistersAndFailedBindingNeverStarts() async throws {
        let fixture = try EntryRuntimeFixture()
        let proxy = ReconstructionSourceEntryJobRuntime(runtime: fixture,
            artifact: fixture.item.artifactCoordinate, projectID: fixture.item.projectID,
            validateCoordinate: {}, bindAndRegister: { _, _ in
                throw ReconstructionSourceOriginalSession.Failure.invalidBinding
            })
        let mutation = try fixture.mutation()
        let wrong = ReconstructionInitialJobMutation(jobID: mutation.jobID, projectID: mutation.projectID,
            selectedOccurrenceIDs: mutation.selectedOccurrenceIDs, objective: mutation.objective,
            budget: mutation.budget, focus: nil,
            sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        do { _ = try await proxy.commitInitialJob(workspaceID: fixture.workspaceID, mutation: wrong)
            XCTFail("Unfocused source entry was accepted") } catch {}
        XCTAssertTrue(fixture.events.isEmpty)
        let untagged = ReconstructionInitialJobMutation(jobID: mutation.jobID, projectID: mutation.projectID,
            selectedOccurrenceIDs: mutation.selectedOccurrenceIDs, objective: mutation.objective,
            budget: mutation.budget, focus: mutation.focus)
        do { _ = try await proxy.commitInitialJob(workspaceID: fixture.workspaceID, mutation: untagged)
            XCTFail("Untagged source entry was accepted") } catch {}
        XCTAssertTrue(fixture.events.isEmpty)
        do { _ = try await proxy.commitInitialJob(workspaceID: fixture.workspaceID, mutation: mutation)
            XCTFail("Failed binding was accepted") } catch {}
        XCTAssertNil(proxy.registeredJobID)
        XCTAssertEqual(fixture.events, ["commit"])
    }
}

@MainActor
private final class EntryRuntimeFixture: WorkspaceReconstructionJobRuntime {
    private let commit: (UUID, ReconstructionInitialJobMutation) throws -> ReconstructionCommittedInitialJob
    let workspaceID: UUID
    let state: ReconstructionWorkspaceState
    let item: ReconstructionJobCreationItem
    var events: [String] = []
    var registeredJob: UUID?

    init() throws {
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        workspaceID = database.workspaceUUID
        state = try ReconstructionDatabaseTestFixtures.makeRichState(workspaceBinaryID: database.binaryID)
        try database.database.replaceReconstructionState(workspaceID: workspaceID, state: state)
        item = try XCTUnwrap(ReconstructionJobCreationItem.committedItems(in: state).first)
        commit = { workspace, mutation in
            try database.database.commitInitialReconstructionJob(workspaceID: workspace, mutation: mutation)
        }
    }
    func mutation() throws -> ReconstructionInitialJobMutation {
        .init(jobID: UUID(), projectID: item.projectID, selectedOccurrenceIDs: [item.occurrenceID],
            objective: "Reconstruct C sample", budget: try .init(maxRounds: 8, maxTasks: 256,
                maxEvidenceRecords: 512, maxEncodedBytes: 8_388_608), focus: .artifact(item.artifactCoordinate),
            sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
    }
    func authority(_ committed: ReconstructionCommittedInitialJob, jobID: UUID? = nil)
        -> ReconstructionJobCommandAuthority {
        .init(jobID: jobID ?? committed.job.jobID, expectedJobState: .created,
            checkpointID: committed.checkpoint.checkpointID, checkpointRevision: committed.checkpoint.revision,
            corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256)
    }
    func commitInitialJob(workspaceID: UUID, mutation: ReconstructionInitialJobMutation) async throws
        -> WorkspaceReconstructionInitialJobPublication {
        events.append("commit")
        return .init(committed: try commit(workspaceID, mutation), attachmentSources: [])
    }
    func start(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard authority.jobID == registeredJob else { return false }
        events.append("start"); return true
    }
    func pause(authority: ReconstructionJobCommandAuthority) async -> Bool { false }
    func resume(authority: ReconstructionJobCommandAuthority) async -> Bool { false }
    func cancel(authority: ReconstructionJobCommandAuthority) async -> Bool { false }
    func restoreAndResumeEligibleJobs() async -> Bool { false }
    func retireTransiently() async { events.append("retire") }
}

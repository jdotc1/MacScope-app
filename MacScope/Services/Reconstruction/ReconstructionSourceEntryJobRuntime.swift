import Foundation

/// Intercepts only the initial publication so the source intent is installed before the Store's
/// automatic start. All durable writes and session commands retain the existing window owner.
@MainActor
final class ReconstructionSourceEntryJobRuntime: WorkspaceReconstructionJobRuntime {
    private let runtime: any WorkspaceReconstructionJobRuntime
    private let artifact: ReconstructionArtifactCoordinate
    private let projectID: UUID
    private let validateCoordinate: @MainActor @Sendable () throws -> Void
    private let bindAndRegister: @MainActor @Sendable (UUID, UUID) async throws -> Void
    private(set) var registeredJobID: UUID?

    init(runtime: any WorkspaceReconstructionJobRuntime,
         artifact: ReconstructionArtifactCoordinate, projectID: UUID,
         validateCoordinate: @escaping @MainActor @Sendable () throws -> Void,
         bindAndRegister: @escaping @MainActor @Sendable (UUID, UUID) async throws -> Void) {
        self.runtime = runtime
        self.artifact = artifact
        self.projectID = projectID
        self.validateCoordinate = validateCoordinate
        self.bindAndRegister = bindAndRegister
    }

    func commitInitialJob(workspaceID: UUID, mutation: ReconstructionInitialJobMutation)
        async throws -> WorkspaceReconstructionInitialJobPublication {
        try validateCoordinate()
        guard registeredJobID == nil, mutation.projectID == projectID,
              mutation.sourceProfileID == ReconstructionSourceExecutionTaskContract.profileID,
              mutation.selectedOccurrenceIDs == [artifact.occurrenceID],
              mutation.focus == .artifact(artifact) else {
            throw ReconstructionWorkspaceRuntimeError.commandAuthorityMismatch
        }
        let publication = try await runtime.commitInitialJob(workspaceID: workspaceID, mutation: mutation)
        try validateCoordinate()
        let job = publication.committed.job
        guard job.jobID == mutation.jobID, job.reconstructionProjectID == projectID,
              job.sourceProfileID == mutation.sourceProfileID,
              job.focus == mutation.focus else {
            throw ReconstructionWorkspaceRuntimeError.commandAuthorityMismatch
        }
        try await bindAndRegister(projectID, job.jobID)
        // Capture identity before the last lifecycle check so the entry can remove a late intent.
        registeredJobID = job.jobID
        try validateCoordinate()
        return publication
    }

    func start(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard authority.jobID == registeredJobID else { return false }
        return await runtime.start(authority: authority)
    }
    func pause(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard authority.jobID == registeredJobID else { return false }
        return await runtime.pause(authority: authority)
    }
    func resume(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard authority.jobID == registeredJobID else { return false }
        return await runtime.resume(authority: authority)
    }
    func cancel(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard authority.jobID == registeredJobID else { return false }
        return await runtime.cancel(authority: authority)
    }
    func restoreAndResumeEligibleJobs() async -> Bool { false }
    // This temporary proxy does not own the shared window runtime's retirement.
    func retireTransiently() async {}

    static func creationRequest(candidate: ReconstructionSourceOriginalSession.ImportCandidate,
                                imported: [ReconstructionArtifactOccurrenceRecord],
                                committedItems: [ReconstructionJobCreationItem]) throws
        -> ReconstructionJobCreationRequest {
        let identities = imported.filter {
            $0.contentIdentity.algorithm == .sha256
                && $0.contentIdentity.digest == candidate.executable.sha256
                && $0.contentIdentity.byteCount == UInt64(candidate.executable.byteCount)
        }
        guard imported.count == 1, identities.count == 1,
              let occurrence = identities.first else {
            throw ReconstructionSourceOriginalSession.Failure.invalidBinding
        }
        let matches = committedItems.filter {
            $0.occurrenceID == occurrence.occurrenceID
                && $0.contentIdentity == occurrence.contentIdentity
        }
        guard matches.count == 1, let item = matches.first,
              let request = ReconstructionJobCreationRequest(
                selectedItems: [item], committedItems: committedItems,
                objective: "Reconstruct the imported C sample and validate it against the captured original.",
                budget: try ReconstructionJobBudget(maxRounds: 8, maxTasks: 256,
                    maxEvidenceRecords: 512, maxEncodedBytes: 8 * 1_024 * 1_024),
                focus: .artifact(item.artifactCoordinate),
                sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID) else {
            throw ReconstructionSourceOriginalSession.Failure.invalidBinding
        }
        return request
    }
}

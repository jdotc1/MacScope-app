import Foundation

/// The one Store-facing aggregate for initial job creation. The committed graph and the durable
/// source cut come from the same lifecycle-bound runtime, so UI code never gains a database handle
/// and cannot accidentally publish sources from another owner.
struct WorkspaceReconstructionInitialJobPublication: Sendable {
    let committed: ReconstructionCommittedInitialJob
    let attachmentSources: [ReconstructionAttachmentSource]
}

/// The exact durable cut a user command was authorized against.
///
/// A job ID alone is not sufficient authority: while a command is crossing actors the job can
/// advance to another state, checkpoint, corpus, or evidence frontier. The runtime must rebuild
/// its database-backed production basis immediately before dispatch and require exact equality
/// with every field in this value.
struct ReconstructionJobCommandAuthority: Equatable, Sendable {
    let jobID: UUID
    let expectedJobState: ReconstructionJobState
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
}

/// Narrow command surface supplied by the per-workspace Reconstruction runtime. Runtime
/// construction, restoration, and registry ownership deliberately remain outside WorkspaceStore.
@MainActor
protocol WorkspaceReconstructionJobRuntime: AnyObject, Sendable {
    func commitInitialJob(
        workspaceID: UUID,
        mutation: ReconstructionInitialJobMutation
    ) async throws -> WorkspaceReconstructionInitialJobPublication

    /// Accepts and retains a long-running coordinator command, then returns only after that
    /// retained session command settles or is rejected. The runtime must reject duplicates and
    /// recheck its exact Store/document/database authority immediately before execution.
    func start(authority: ReconstructionJobCommandAuthority) async -> Bool
    func pause(authority: ReconstructionJobCommandAuthority) async -> Bool
    func resume(authority: ReconstructionJobCommandAuthority) async -> Bool
    func cancel(authority: ReconstructionJobCommandAuthority) async -> Bool
    func restoreAndResumeEligibleJobs() async -> Bool
    /// Stops transient execution through the coordinator's non-durable suspension seam. This must
    /// never be implemented as bare Task cancellation, which could commit a user cancellation.
    func retireTransiently() async
}

enum WorkspaceReconstructionJobIntegrationError: Error, Equatable {
    case staleCreationRequest
    case runtimeCoordinateMismatch
    case runtimeAttachmentSourceMismatch
}

extension WorkspaceStore {
    /// Commits, publishes, selects, and starts one immutable creation request in that order.
    /// A late result remains durable in its runtime database but cannot cross a Store lifecycle
    /// replacement boundary into the current document.
    @discardableResult
    func createReconstructionJob(
        _ request: ReconstructionJobCreationRequest,
        using runtime: any WorkspaceReconstructionJobRuntime
    ) async throws -> ReconstructionCommittedInitialJob {
        let committedItems = ReconstructionJobCreationItem.committedItems(
            in: reconstructionState
        )
        guard let currentRequest = ReconstructionJobCreationRequest(
            selectedItems: request.selectedItems,
            committedItems: committedItems,
            objective: request.objective,
            budget: request.budget,
            focus: request.focus,
            committedFunctions: ReconstructionJobCreationRequest.committedFunctions(in: reconstructionState),
            sourceProfileID: request.sourceProfileID
        ),
        currentRequest.projectID == request.projectID,
        currentRequest.selectedArtifacts == request.selectedArtifacts,
        currentRequest.focus == request.focus,
        currentRequest.sourceProfileID == request.sourceProfileID else {
            throw WorkspaceReconstructionJobIntegrationError.staleCreationRequest
        }
        guard let publicationAuthority = captureReconstructionPublicationAuthority() else {
            throw ReconstructionPublicationError.authorityExhausted
        }

        let committedWorkspaceID = workspaceID
        let mutation = ReconstructionInitialJobMutation(
            jobID: UUID(),
            projectID: currentRequest.projectID,
            selectedOccurrenceIDs: currentRequest.selectedItems.map(\.occurrenceID),
            objective: currentRequest.objective,
            budget: currentRequest.budget,
            focus: currentRequest.focus,
            sourceProfileID: currentRequest.sourceProfileID
        )
        let publication = try await runtime.commitInitialJob(
            workspaceID: committedWorkspaceID,
            mutation: mutation
        )

        guard ownsReconstructionPublicationAuthority(publicationAuthority) else {
            // The transaction may already be durable. Its runtime owns later reconciliation; an
            // obsolete Store lifecycle must not publish, select, or start it.
            return publication.committed
        }
        try validateInitialReconstructionPublication(
            publication,
            mutation: mutation
        )

        let committed = publication.committed
        var checkpointPublication = ReconstructionCommittedCheckpoint(
            state: committed.state,
            checkpoint: committed.checkpoint,
            idempotentToolReceiptIDs: [],
            idempotentModelReceiptIDs: [],
            commitSequence: committed.commitSequence
        )
        checkpointPublication.lifecycle = committed.lifecycle
        publishCommittedReconstructionCheckpoint(
            checkpointPublication,
            attachmentSources: publication.attachmentSources
        )

        let sidebarItemID = Self.reconstructionSidebarItemID(committed.job.jobID)
        guard reconstructionState.jobs.contains(where: {
            $0.jobID == committed.job.jobID
                && $0.reconstructionProjectID == committed.job.reconstructionProjectID
        }),
        let sidebarTarget = sidebarNavigationTarget(for: sidebarItemID),
        activateSidebarItem(sidebarTarget) else {
            // A newer winning commit can reject this publication. Never automate a job that the
            // Store cannot prove belongs to its current durable presentation cut.
            return committed
        }
        _ = await startReconstructionJob(committed.job.jobID, using: runtime)
        return committed
    }

    /// The lifecycle-bound runtime owns task retention, duplicate suppression, and retirement.
    /// The caller may await this while a durable publication clears its UI intent earlier.
    @discardableResult
    func startReconstructionJob(
        _ jobID: UUID,
        using runtime: any WorkspaceReconstructionJobRuntime
    ) async -> Bool {
        guard let authority = reconstructionCommandAuthority(
            jobID: jobID,
            command: .start
        ) else { return false }
        return await runtime.start(authority: authority)
    }

    @discardableResult
    func pauseReconstructionJob(
        _ jobID: UUID,
        using runtime: any WorkspaceReconstructionJobRuntime
    ) async -> Bool {
        guard let authority = reconstructionCommandAuthority(
            jobID: jobID,
            command: .pause
        ) else { return false }
        return await runtime.pause(authority: authority)
    }

    /// Resume is another potentially long-running coordinator loop retained and coalesced by the
    /// runtime. A fresh post-reopen session may resume without a preexisting scheduler child.
    @discardableResult
    func resumeReconstructionJob(
        _ jobID: UUID,
        using runtime: any WorkspaceReconstructionJobRuntime
    ) async -> Bool {
        guard let authority = reconstructionCommandAuthority(
            jobID: jobID,
            command: .resume
        ) else { return false }
        return await runtime.resume(authority: authority)
    }

    @discardableResult
    func cancelReconstructionJob(
        _ jobID: UUID,
        using runtime: any WorkspaceReconstructionJobRuntime
    ) async -> Bool {
        guard let authority = reconstructionCommandAuthority(
            jobID: jobID,
            command: .cancel
        ) else { return false }
        return await runtime.cancel(authority: authority)
    }

    private func reconstructionCommandAuthority(
        jobID: UUID,
        command: ReconstructionCommandKind
    ) -> ReconstructionJobCommandAuthority? {
        let state = reconstructionState
        guard let job = state.jobs.first(where: { $0.jobID == jobID }),
              let project = state.projects.first(where: {
                  $0.projectID == job.reconstructionProjectID
              }),
              let currentManifestSHA256 = project.currentCorpusManifestSHA256,
              currentManifestSHA256 == job.creationCorpusManifestSHA256,
              let checkpointID = job.currentCheckpointID,
              let checkpoint = state.checkpoints.first(where: {
                  $0.checkpointID == checkpointID
              }),
              checkpoint.jobID == jobID,
              checkpoint.coordinatorState == job.state,
              checkpoint.corpusManifestSHA256 == currentManifestSHA256,
              (try? checkpoint.verifyCanonicalIdentity()) != nil else {
            return nil
        }

        do {
            switch command {
            case .create:
                return nil
            case .start:
                guard job.state == .created else { return nil }
                try ReconstructionJobStateMachine.transition(
                    from: job.state,
                    to: .ingesting,
                    resumeTarget: nil
                )
            case .pause:
                guard ReconstructionJobState.activeStates.contains(job.state) else {
                    return nil
                }
                try ReconstructionJobStateMachine.transition(
                    from: job.state,
                    to: .paused,
                    resumeTarget: job.state
                )
            case .resume:
                guard job.state == .paused,
                      let resumeTarget = job.pauseContext?.resumeTarget,
                      ReconstructionJobState.activeStates.contains(resumeTarget) else {
                    return nil
                }
                try ReconstructionJobStateMachine.transition(
                    from: job.state,
                    to: resumeTarget,
                    resumeTarget: resumeTarget
                )
            case .cancel:
                guard ReconstructionJobState.activeStates.contains(job.state)
                        || job.state == .paused else {
                    return nil
                }
                try ReconstructionJobStateMachine.transition(
                    from: job.state,
                    to: .cancelled,
                    resumeTarget: nil
                )
            }
        } catch {
            return nil
        }

        return ReconstructionJobCommandAuthority(
            jobID: jobID,
            expectedJobState: job.state,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256
        )
    }

    private func validateInitialReconstructionPublication(
        _ publication: WorkspaceReconstructionInitialJobPublication,
        mutation: ReconstructionInitialJobMutation
    ) throws {
        let committed = publication.committed
        let normalizedObjective = mutation.objective.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard committed.commitSequence > 0,
              committed.job.jobID == mutation.jobID,
              committed.job.reconstructionProjectID == mutation.projectID,
              committed.job.objective == normalizedObjective,
              committed.job.budget == mutation.budget,
              committed.job.focus == mutation.focus,
              committed.job.sourceProfileID == mutation.sourceProfileID,
              committed.job.state == .created,
              committed.job.terminalReason == nil,
              committed.job.pauseContext == nil,
              committed.job.currentCheckpointID == committed.checkpoint.checkpointID,
              committed.checkpoint.jobID == mutation.jobID,
              committed.checkpoint.revision == 0,
              committed.checkpoint.parentCheckpointID == nil,
              committed.checkpoint.parentCheckpointSHA256 == nil,
              committed.checkpoint.coordinatorState == .created,
              committed.checkpoint.terminalReason == nil,
              committed.checkpoint.corpusManifestSHA256
                == committed.job.creationCorpusManifestSHA256,
              committed.state.projects.contains(where: { $0.projectID == mutation.projectID }),
              committed.state.jobs.first(where: { $0.jobID == mutation.jobID })
                == committed.job,
              committed.state.checkpoints.first(where: {
                  $0.checkpointID == committed.checkpoint.checkpointID
              }) == committed.checkpoint else {
            throw WorkspaceReconstructionJobIntegrationError.runtimeCoordinateMismatch
        }
        try committed.checkpoint.verifyCanonicalIdentity()
        try ReconstructionPackageCodec.validateGraph(committed.state)

        let ingestTasks = committed.state.tasks.filter {
            $0.identity.jobID == mutation.jobID && $0.identity.kind == .ingest
        }
        let selectedOccurrenceIDs: [ReconstructionArtifactOccurrenceID] =
            ingestTasks.compactMap { task in
                guard case let .artifact(artifact)? = task.identity.subject else { return nil }
                return artifact.occurrenceID
            }
        guard ingestTasks.count == selectedOccurrenceIDs.count,
              Set(selectedOccurrenceIDs).count == selectedOccurrenceIDs.count,
              Set(selectedOccurrenceIDs) == Set(mutation.selectedOccurrenceIDs) else {
            throw WorkspaceReconstructionJobIntegrationError.runtimeCoordinateMismatch
        }

        let requiredIdentities = try ReconstructionPackageCodec.contentRecords(
            in: committed.state
        ).map(\.contentIdentity)
        let providedIdentities = publication.attachmentSources.map(\.contentIdentity)
        guard Set(requiredIdentities).count == requiredIdentities.count,
              Set(providedIdentities).count == providedIdentities.count,
              Set(providedIdentities) == Set(requiredIdentities) else {
            throw WorkspaceReconstructionJobIntegrationError.runtimeAttachmentSourceMismatch
        }
    }
}

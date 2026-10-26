import Foundation

@MainActor
final class WorkspaceStoreReconstructionStatusPublisher: ReconstructionJobStatusPublishing,
    @unchecked Sendable {
    typealias DurableSourceLoader = @Sendable (UUID) async throws
        -> [ReconstructionAttachmentSource]

    private weak var store: WorkspaceStore?
    private let workspaceID: UUID
    private let publicationAuthority: WorkspaceStore.ReconstructionPublicationAuthority?
    private let loadDurableSources: DurableSourceLoader

    init(
        store: WorkspaceStore,
        owner: ReconstructionDatabaseOwner,
        workspaceID: UUID
    ) {
        self.store = store
        self.workspaceID = workspaceID
        publicationAuthority = store.workspaceID == workspaceID
            ? store.captureReconstructionPublicationAuthority()
            : nil
        loadDurableSources = { workspaceID in
            try await owner.availableDurableAttachmentSources(workspaceID: workspaceID)
        }
    }

    /// Internal loader injection gives the lifecycle fence a deterministic suspension point in
    /// focused tests without exposing the database owner to production Store call sites.
    init(
        store: WorkspaceStore,
        workspaceID: UUID,
        loadDurableSources: @escaping DurableSourceLoader
    ) {
        self.store = store
        self.workspaceID = workspaceID
        publicationAuthority = store.workspaceID == workspaceID
            ? store.captureReconstructionPublicationAuthority()
            : nil
        self.loadDurableSources = loadDurableSources
    }

    func publish(_ receipt: ReconstructionJobCommitReceipt) async {
        guard let store,
              let publicationAuthority,
              let committed = receipt.committedCheckpoint,
              committed.checkpoint.jobID == receipt.jobID,
              committed.checkpoint.revision == receipt.checkpointRevision,
              committed.checkpoint.evidenceFrontierSHA256 == receipt.evidenceFrontierSHA256,
              store.ownsReconstructionPublicationAuthority(publicationAuthority),
              let sources = try? await loadDurableSources(workspaceID),
              store.ownsReconstructionPublicationAuthority(publicationAuthority) else { return }
        store.publishCommittedReconstructionCheckpoint(
            committed,
            attachmentSources: sources
        )
    }
}

extension WorkspaceStore {
    func makeReconstructionJobCoordinator(
        owner: ReconstructionDatabaseOwner,
        planner: any ReconstructionJobRoundPlanning,
        scheduler: ReconstructionModelRoundScheduler = .init()
    ) -> ReconstructionJobCoordinator {
        ReconstructionJobCoordinator(
            persistence: ReconstructionDatabaseJobPersistence(
                workspaceID: workspaceID,
                owner: owner
            ),
            planner: planner,
            publisher: WorkspaceStoreReconstructionStatusPublisher(
                store: self,
                owner: owner,
                workspaceID: workspaceID
            ),
            scheduler: scheduler
        )
    }
}

import Foundation

extension WorkspaceStore {
    @discardableResult
    func commitReconstructionCheckpoint(
        _ mutation: ReconstructionCheckpointMutation,
        using owner: ReconstructionDatabaseOwner
    ) async throws -> ReconstructionCommittedCheckpoint {
        guard let publicationAuthority = captureReconstructionPublicationAuthority() else {
            throw ReconstructionPublicationError.authorityExhausted
        }
        let committedWorkspaceID = workspaceID
        let committed = try await owner.commit(
            workspaceID: committedWorkspaceID,
            mutation: mutation
        )
        guard ownsReconstructionPublicationAuthority(publicationAuthority) else {
            // The old-lifecycle result is already durable. Return it for caller reconciliation,
            // but never splice its reconstruction frontier into the replacement store.
            return committed
        }
        let durableSources = try await owner.availableDurableAttachmentSources(
            workspaceID: committedWorkspaceID
        )
        guard ownsReconstructionPublicationAuthority(publicationAuthority) else {
            return committed
        }
        publishCommittedReconstructionCheckpoint(
            committed,
            attachmentSources: durableSources
        )
        return committed
    }
}

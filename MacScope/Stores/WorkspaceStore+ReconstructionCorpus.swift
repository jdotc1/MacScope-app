import Foundation

struct WorkspaceReconstructionCorpusImportPublication: Sendable {
    let result: ReconstructionImportResult
    let committed: ReconstructionCommittedCorpus?
    let publicationAccepted: Bool
}

enum WorkspaceReconstructionCorpusImportError: Error, Equatable {
    case selectionBounds
    case ambiguousProject
    case occurrenceIdentityConflict
    case relationIdentityConflict
}

extension WorkspaceStore {
    /// Captures the document lifecycle before filesystem acquisition crosses actors. Only this
    /// lifecycle may dispatch a commit; an already dispatched old-owner commit may remain durable.
    func importReconstructionCorpus(
        selections: [ReconstructionImportSelection],
        using owner: ReconstructionDatabaseOwner,
        importer: ReconstructionCorpusImporter = ReconstructionCorpusImporter(),
        cancellation: ReconstructionCancellation,
        progress: (@Sendable (ReconstructionImportProgress) async -> Void)? = nil
    ) async throws -> WorkspaceReconstructionCorpusImportPublication {
        guard !selections.isEmpty, selections.count <= 256 else {
            throw WorkspaceReconstructionCorpusImportError.selectionBounds
        }
        guard let authority = captureReconstructionPublicationAuthority() else {
            throw ReconstructionPublicationError.authorityExhausted
        }
        guard reconstructionState.projects.count <= 1 else {
            throw WorkspaceReconstructionCorpusImportError.ambiguousProject
        }
        let capturedWorkspaceID = workspaceID
        let project = reconstructionState.projects.first
        let projectID = project?.projectID ?? UUID()
        let currentManifest = reconstructionState.corpusManifests.first {
            $0.reconstructionProjectID == projectID
                && $0.canonicalSHA256 == project?.currentCorpusManifestSHA256
        }
        let retainedSources = reconstructionAttachmentSources
        let result = await importer.ingest(
            selections: selections,
            projectID: projectID,
            cancellation: cancellation,
            progress: progress
        )
        guard ownsReconstructionPublicationAuthority(authority),
              !cancellation.isCancelled, !Task.isCancelled,
              !result.occurrences.isEmpty,
              !result.failures.contains(where: { $0.reason == .cancelled }) else {
            return WorkspaceReconstructionCorpusImportPublication(
                result: result, committed: nil, publicationAccepted: false
            )
        }
        var artifacts = currentManifest?.artifacts ?? []
        var artifactIndex = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.occurrenceID, $0) })
        for artifact in result.occurrences {
            if let retained = artifactIndex[artifact.occurrenceID] {
                guard retained == artifact else {
                    throw WorkspaceReconstructionCorpusImportError.occurrenceIdentityConflict
                }
            } else {
                artifactIndex[artifact.occurrenceID] = artifact
                artifacts.append(artifact)
            }
        }
        var relations = currentManifest?.relations ?? []
        var relationIndex = Dictionary(uniqueKeysWithValues: relations.map { ($0.relationID, $0) })
        for relation in result.relations {
            if let retained = relationIndex[relation.relationID] {
                guard retained == relation else {
                    throw WorkspaceReconstructionCorpusImportError.relationIdentityConflict
                }
            } else {
                relationIndex[relation.relationID] = relation
                relations.append(relation)
            }
        }
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: artifacts,
            relations: relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(
                reconstructionProjectID: projectID, artifacts: artifacts, relations: relations
            )
        )
        let identities = Set(artifacts.map(\.contentIdentity))
        var sourceIdentities: Set<ReconstructionContentIdentity> = []
        let sources = (retainedSources + result.attachmentSources).filter {
            identities.contains($0.contentIdentity) && sourceIdentities.insert($0.contentIdentity).inserted
        }
        let committed = try await owner.commitCorpus(
            workspaceID: capturedWorkspaceID,
            mutation: ReconstructionCorpusMutation(
                projectID: projectID,
                expectedCurrentManifestSHA256: project?.currentCorpusManifestSHA256,
                successorManifest: manifest,
                attachmentSources: sources
            )
        )
        let accepted = ownsReconstructionPublicationAuthority(authority)
        if accepted { publishCommittedReconstructionCorpus(committed) }
        return WorkspaceReconstructionCorpusImportPublication(
            result: result, committed: committed, publicationAccepted: accepted
        )
    }

    @discardableResult
    func commitReconstructionCorpus(
        _ mutation: ReconstructionCorpusMutation,
        using owner: ReconstructionDatabaseOwner
    ) async throws -> ReconstructionCommittedCorpus {
        guard let publicationAuthority = captureReconstructionPublicationAuthority() else {
            throw ReconstructionPublicationError.authorityExhausted
        }
        let committedWorkspaceID = workspaceID
        let committed = try await owner.commitCorpus(
            workspaceID: committedWorkspaceID,
            mutation: mutation
        )
        guard ownsReconstructionPublicationAuthority(publicationAuthority) else {
            // The old-lifecycle result is already durable. Return it for caller reconciliation,
            // but never splice its state or attachment leases into the replacement store.
            return committed
        }
        publishCommittedReconstructionCorpus(committed)
        return committed
    }
}

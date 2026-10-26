import CryptoKit
import Foundation

extension WorkspaceStore {
    func reaAuthority(imageSHA256: String, snapshotID: UUID) -> REAResultAuthority? {
        guard let bytes = focusedAnalysis?.imageBytes, !bytes.isEmpty,
              REACaptureCommitment.digest(bytes) == imageSHA256,
              let identity = phase2ReadLedger.imageIdentity(in: focusedImageSlot, snapshot: snapshot) else { return nil }
        return REAResultAuthority(workspaceID: workspaceID, imageSHA256: imageSHA256,
            snapshotID: snapshotID, sourceGeneration: identity.analysisRevision,
            resourceSHA256: REAEmbeddedIdentity.resourceSHA256,
            implementationIdentity: REAEmbeddedIdentity.implementationIdentity)
    }

    func publishREAResult(_ candidate: REAResultEvidence) throws {
        guard let current = reaAuthority(imageSHA256: candidate.authority.imageSHA256,
                                         snapshotID: candidate.authority.snapshotID) else {
            throw REAResultEvidenceError.staleAuthority
        }
        var next = reaResultEvidence
        try next.publish(candidate, activeAuthority: current)
        reaResultEvidence = next
        markDocumentMutated()
    }
}

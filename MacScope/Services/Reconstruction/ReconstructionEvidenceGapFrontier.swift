import Foundation

/// Canonical identity for the unresolved evidence-gap frontier.
///
/// The complete durable gap records participate in the preimage. Callers must not replace them
/// with gap IDs or per-record digests because the reason, subject, and operation are part of the
/// resumable unresolved-work identity.
enum ReconstructionEvidenceGapFrontier {
    private struct Preimage: Encodable {
        let schemaVersion: Int
        let domain: String
        let gaps: [ReconstructionEvidenceGap]
    }

    static func canonicalSHA256(
        for gaps: [ReconstructionEvidenceGap]
    ) throws -> String {
        try Task.checkCancellation()
        let ordered = gaps.sorted {
            $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
        }
        try Task.checkCancellation()
        let digest = try ReconstructionCanonicalJSON.sha256(of: Preimage(
            schemaVersion: 1,
            domain: "reconstruction.unresolved-evidence-gap-frontier.v1",
            gaps: ordered
        ))
        try Task.checkCancellation()
        return digest
    }
}

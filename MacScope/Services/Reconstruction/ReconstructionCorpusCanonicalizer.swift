import Foundation

enum ReconstructionCorpusCanonicalizer {
    private struct DigestPayload: Encodable {
        let schemaVersion: Int
        let reconstructionProjectID: UUID
        let artifacts: [ReconstructionArtifactOccurrenceRecord]
        let relations: [ReconstructionArtifactRelationRecord]
    }

    static func canonicalSHA256(
        schemaVersion: Int = ReconstructionCorpusManifest.schemaVersion,
        reconstructionProjectID: UUID,
        artifacts: [ReconstructionArtifactOccurrenceRecord],
        relations: [ReconstructionArtifactRelationRecord]
    ) throws -> String {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        let payload = DigestPayload(
            schemaVersion: schemaVersion,
            reconstructionProjectID: reconstructionProjectID,
            artifacts: artifacts.sorted {
                $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString
            },
            relations: relations.sorted { $0.relationID.uuidString < $1.relationID.uuidString }
        )
        return try ReconstructionCanonicalJSON.sha256(of: payload)
    }

    static func canonicalSHA256(of manifest: ReconstructionCorpusManifest) throws -> String {
        try canonicalSHA256(
            schemaVersion: manifest.schemaVersion,
            reconstructionProjectID: manifest.reconstructionProjectID,
            artifacts: manifest.artifacts,
            relations: manifest.relations
        )
    }
}

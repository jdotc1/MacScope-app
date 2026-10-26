import Foundation

/// Inline, versioned source payload. This is admission authority, not build or behavior success.
struct ReconstructionSourceRevision: Codable, Hashable, Sendable {
    static let contractVersion = 1
    static let profileID = ReconstructionSourceProfile.scalarU32V1.rawValue
    /// Recognition is not execution authority. Only the retained scalar profile is admitted.
    enum ProfileDisposition: Equatable, Sendable { case legacy, disabled, unsupported }

    static func profileDisposition(for identifier: String) -> ProfileDisposition {
        switch identifier {
        case profileID: return .legacy
        case ReconstructionSourceProfile.adler32RecordV1.rawValue: return .disabled
        default: return .unsupported
        }
    }

    static let maximumSourceBytes = 65_536
    static let maximumEvidenceReferences = 64
    static let maximumPayloadBytes = 131_072

    enum Status: String, Codable, Sendable { case proposed }

    let version: Int
    let projectID: UUID
    let jobID: UUID
    let function: ReconstructionFunctionCoordinate
    let objectiveSHA256: String
    let evidenceFrontierSHA256: String
    let oracleSuiteSHA256: String
    let profileID: String
    let parentRevisionSHA256: String?
    let relativePath: String
    let sourceUTF8: Data
    let sourceSHA256: String
    let evidenceIDs: [UUID]
    let status: Status
    /// Content-addressed identity; independent of caller-generated revision/evidence UUIDs.
    let revisionSHA256: String
    /// Optional only for retained initial fixtures. Production captures this before model inference.
    let requestBinding: ReconstructionSourceRequestBinding?

    init(version: Int, projectID: UUID, jobID: UUID, function: ReconstructionFunctionCoordinate,
         objectiveSHA256: String, evidenceFrontierSHA256: String, oracleSuiteSHA256: String,
         profileID: String, parentRevisionSHA256: String?, relativePath: String, sourceUTF8: Data,
         sourceSHA256: String, evidenceIDs: [UUID], status: Status, revisionSHA256: String,
         requestBinding: ReconstructionSourceRequestBinding? = nil) {
        self.version = version; self.projectID = projectID; self.jobID = jobID; self.function = function
        self.objectiveSHA256 = objectiveSHA256; self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.oracleSuiteSHA256 = oracleSuiteSHA256; self.profileID = profileID
        self.parentRevisionSHA256 = parentRevisionSHA256; self.relativePath = relativePath
        self.sourceUTF8 = sourceUTF8; self.sourceSHA256 = sourceSHA256; self.evidenceIDs = evidenceIDs
        self.status = status; self.revisionSHA256 = revisionSHA256; self.requestBinding = requestBinding
    }
}

struct ReconstructionSourceRevisionProposal: Sendable {
    var version: Int = ReconstructionSourceRevision.contractVersion
    var profileID: String = ReconstructionSourceRevision.profileID
    var parentRevisionSHA256: String?
    var relativePath: String = "candidate.c"
    var sourceUTF8: Data
    var claimedSourceSHA256: String
    var evidenceIDs: [UUID]
}

/// Captured from committed state by the existing owner. No filesystem or writer authority.
struct ReconstructionSourceRevisionAuthority: Sendable {
    let projectID: UUID
    let jobID: UUID
    let function: ReconstructionFunctionCoordinate
    let objectiveSHA256: String
    let evidenceFrontierSHA256: String
    let oracleSuiteSHA256: String
    let profileID: String
    let admissibleEvidenceIDs: Set<UUID>
    let currentRevision: ReconstructionSourceRevision?
    let requestBinding: ReconstructionSourceRequestBinding?

    init(projectID: UUID, jobID: UUID, function: ReconstructionFunctionCoordinate,
         objectiveSHA256: String, evidenceFrontierSHA256: String, oracleSuiteSHA256: String,
         admissibleEvidenceIDs: Set<UUID>, currentRevision: ReconstructionSourceRevision?,
         requestBinding: ReconstructionSourceRequestBinding? = nil,
         profileID: String = ReconstructionSourceProfile.scalarU32V1.rawValue) {
        self.profileID = profileID
        self.projectID = projectID; self.jobID = jobID; self.function = function
        self.objectiveSHA256 = objectiveSHA256; self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.oracleSuiteSHA256 = oracleSuiteSHA256; self.admissibleEvidenceIDs = admissibleEvidenceIDs
        self.currentRevision = currentRevision; self.requestBinding = requestBinding
    }
}

/// Neutral durable owner attestation. The model proposal has no field capable of supplying this.
/// Exact request bytes are retained; no inference or worker DTO becomes a persistence dependency.
struct ReconstructionSourceRequestBinding: Codable, Hashable, Sendable {
    static let maximumRequestBytes = 65_536
    static let maximumContextBytes = 32_768
    let canonicalRequestBytes: Data
    let requestSHA256: String
    let taskID: UUID
    let roundID: UUID
    let checkpointRevision: UInt64
}

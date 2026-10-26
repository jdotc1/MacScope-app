import Foundation

struct Phase2GroundedContextLimits: Codable, Hashable, Sendable {
    let maximumRecords: Int
    let maximumCanonicalBytes: Int

    init(maximumRecords: Int, maximumCanonicalBytes: Int) {
        self.maximumRecords = maximumRecords
        self.maximumCanonicalBytes = maximumCanonicalBytes
    }

    static let maximum = Self(maximumRecords: 3, maximumCanonicalBytes: 1_048_576)

    var isValid: Bool {
        maximumRecords > 0
            && maximumRecords <= Self.maximum.maximumRecords
            && maximumCanonicalBytes > 0
            && maximumCanonicalBytes <= Self.maximum.maximumCanonicalBytes
    }
}

enum Phase2GroundedContextTrustClass: String, Codable, Hashable, Sendable {
    /// Typed native facts can still contain attacker-controlled strings from the analyzed binary.
    case untrustedProjectData
}

struct Phase2GroundedContextRecord: Codable, Hashable, Sendable {
    let evidenceID: UUID
    let candidateID: UUID
    let invocationID: UUID
    let sequence: UInt64
    let descriptor: Phase2ReadOperationDescriptor
    let producingPrincipal: Phase2Principal
    let trustClass: Phase2GroundedContextTrustClass
    let precondition: Phase2ReadPrecondition
    let citations: [Phase2ReadCitation]
    let data: Phase2ReadCandidateData
    let payloadDigest: String
}

enum Phase2GroundedContextOmissionReason: String, Codable, Hashable, Sendable {
    case recordBudgetExceeded
}

struct Phase2GroundedContextOmission: Codable, Hashable, Sendable {
    let evidenceID: UUID
    let reason: Phase2GroundedContextOmissionReason
}

/// Canonical provider-neutral context. `canonicalBytes` encode only the versioned manifest; the
/// digest is SHA-256 over those exact bytes and is intentionally not self-referential.
struct Phase2GroundedContext: Hashable, Sendable {
    let records: [Phase2GroundedContextRecord]
    let omissions: [Phase2GroundedContextOmission]
    let canonicalBytes: Data
    let digest: String

    fileprivate init(
        records: [Phase2GroundedContextRecord],
        omissions: [Phase2GroundedContextOmission],
        canonicalBytes: Data,
        digest: String
    ) {
        self.records = records
        self.omissions = omissions
        self.canonicalBytes = canonicalBytes
        self.digest = digest
    }
}

enum Phase2GroundedContextError: Error, Equatable, Sendable {
    case invalidLimits
    case missingAcceptedEvidence(UUID)
    case duplicateEvidenceID(UUID)
    case missingCurrentState(UUID)
    case ownerMismatch(UUID)
    case stale(UUID)
    case packetBudgetTooSmall
    case encodingFailed
}

struct Phase2GroundedContextManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let records: [Phase2GroundedContextRecord]
    let omissions: [Phase2GroundedContextOmission]

    init(
        records: [Phase2GroundedContextRecord],
        omissions: [Phase2GroundedContextOmission]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
        self.omissions = omissions
    }
}

extension Phase2GroundedContext {
    static func make(
        records: [Phase2GroundedContextRecord],
        omissions: [Phase2GroundedContextOmission],
        canonicalBytes: Data,
        digest: String
    ) -> Self {
        .init(
            records: records,
            omissions: omissions,
            canonicalBytes: canonicalBytes,
            digest: digest
        )
    }
}

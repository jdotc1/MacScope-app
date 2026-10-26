import CryptoKit
import Foundation

typealias ReconstructionDurableSubject = ReconstructionSubjectCoordinate

enum ReconstructionRetrievalError: Error, Equatable, Sendable {
    case invalidQuery
    case invalidProjectionInput
    case queryCorpusMismatch
    case cursorFenceMismatch
    case unknownOperation(String)
    case recordExceedsByteBudget(UUID)
    case packetEnvelopeExceedsByteBudget
}

/// Complete resume key for the deterministic retrieval ordering.
struct ReconstructionRetrievalCursor: Hashable, Codable, Sendable {
    let schemaVersion: Int
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let queryIdentitySHA256: String
    let currentBucket: Int
    let subjectSpecificity: Int
    let operationPriority: Int
    /// Fixed-width SHA-256 bytes of the canonical subject identity.
    let canonicalSubjectIdentity: Data
    let checkpointRevision: UInt64
    let evidenceID: UUID
}

struct ReconstructionRetrievalQuery: Hashable, Codable, Sendable {
    private static let maximumRecordBudget = 100_000
    private static let maximumEncodedByteBudget = ReconstructionPackageLayout.maximumManifestBytes

    let corpusManifestSHA256: String
    let subject: ReconstructionDurableSubject?
    /// Immutable job focus is independent of the exact tool/task subject filter.
    let focus: ReconstructionSubjectCoordinate?
    let operationIDs: [ReconstructionOperationID]
    let classifications: [ReconstructionEvidenceClassification]
    let cursor: ReconstructionRetrievalCursor?
    let maximumRecords: Int
    let maximumEncodedBytes: Int

    init(
        corpusManifestSHA256: String,
        subject: ReconstructionDurableSubject?,
        operationIDs: [ReconstructionOperationID],
        classifications: [ReconstructionEvidenceClassification],
        cursor: ReconstructionRetrievalCursor?,
        maximumRecords: Int,
        maximumEncodedBytes: Int,
        focus: ReconstructionSubjectCoordinate? = nil
    ) throws {
        if case .image = focus { throw ReconstructionRetrievalError.invalidQuery }
        guard Self.isCanonicalSHA256(corpusManifestSHA256),
              !operationIDs.isEmpty,
              Set(operationIDs).count == operationIDs.count,
              !classifications.isEmpty,
              Set(classifications).count == classifications.count,
              maximumRecords > 0,
              maximumRecords <= Self.maximumRecordBudget,
              maximumEncodedBytes > 0,
              maximumEncodedBytes <= Self.maximumEncodedByteBudget else {
            throw ReconstructionRetrievalError.invalidQuery
        }
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.subject = subject
        self.focus = focus
        self.operationIDs = operationIDs.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.rawValue < $1.rawValue
        }
        self.classifications = classifications.sorted { $0.rawValue < $1.rawValue }
        self.cursor = cursor
        self.maximumRecords = maximumRecords
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    private enum CodingKeys: String, CodingKey {
        case corpusManifestSHA256
        case subject
        case focus
        case operationIDs
        case classifications
        case cursor
        case maximumRecords
        case maximumEncodedBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            corpusManifestSHA256: container.decode(
                String.self,
                forKey: .corpusManifestSHA256
            ),
            subject: container.decodeIfPresent(
                ReconstructionDurableSubject.self,
                forKey: .subject
            ),
            operationIDs: container.decode(
                [ReconstructionOperationID].self,
                forKey: .operationIDs
            ),
            classifications: container.decode(
                [ReconstructionEvidenceClassification].self,
                forKey: .classifications
            ),
            cursor: container.decodeIfPresent(
                ReconstructionRetrievalCursor.self,
                forKey: .cursor
            ),
            maximumRecords: container.decode(Int.self, forKey: .maximumRecords),
            maximumEncodedBytes: container.decode(Int.self, forKey: .maximumEncodedBytes),
            focus: container.decodeIfPresent(ReconstructionSubjectCoordinate.self, forKey: .focus)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(corpusManifestSHA256, forKey: .corpusManifestSHA256)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encodeIfPresent(focus, forKey: .focus)
        try container.encode(operationIDs, forKey: .operationIDs)
        try container.encode(classifications, forKey: .classifications)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(maximumRecords, forKey: .maximumRecords)
        try container.encode(maximumEncodedBytes, forKey: .maximumEncodedBytes)
    }

    /// Artifact focus includes its image/function descendants; function focus is exact.
    /// Hints cannot change authority because function coordinate equality excludes hints.
    func includes(subject candidate: ReconstructionSubjectCoordinate) -> Bool {
        guard subject == nil || subject == candidate else { return false }
        switch focus {
        case nil: return true
        case .artifact(let artifact):
            switch candidate {
            case .artifact(let value): return value == artifact
            case .image(let value): return value.artifact == artifact
            case .function(let value): return value.artifact == artifact
            }
        case .function(let function): return candidate == .function(function)
        case .image: return false
        }
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

import Foundation

/// Workspace-owned bounded accepted history. Publication evicts the oldest records first;
/// surviving records remain immutable and source changes alone do not discard evidence.
/// The workspace transaction must serialize publication and active-authority replacement.
struct REAResultEvidenceStore: Codable, Equatable, Sendable {
    static let maximumRecords = 128
    static let maximumRetainedBytes = 64 * 1_024 * 1_024
    // The manifest base64-encodes this JSON; keep the existing package read limit.
    static let maximumEncodedBytes = 24 * 1_024 * 1_024
    static let maximumReadBytes = 65_536
    private(set) var records: [REAResultEvidence]

    init(records: [REAResultEvidence] = []) throws {
        self.records = records
        try validate()
    }

    mutating func publish(_ candidate: REAResultEvidence, activeAuthority: REAResultAuthority) throws {
        try candidate.validate()
        try activeAuthority.validate()
        guard candidate.authority == activeAuthority else { throw REAResultEvidenceError.staleAuthority }
        guard !records.contains(where: { $0.evidenceID == candidate.evidenceID || $0.requestID == candidate.requestID }) else {
            throw REAResultEvidenceError.duplicateIdentity
        }
        // Encode each considered immutable record once. The store representation is
        // {"records":[...]} plus one comma per additional record. This avoids repeatedly
        // encoding the entire history as old entries are removed.
        let encoder = JSONEncoder()
        var encodedBytes = try encoder.encode(candidate).count + 14
        var retainedBytes = candidate.requestJSON.count + candidate.responseJSON.count
        guard encodedBytes <= Self.maximumEncodedBytes, retainedBytes <= Self.maximumRetainedBytes else {
            throw REAResultEvidenceError.bounds
        }
        var retainedCount = 0
        for record in records.reversed() {
            guard retainedCount + 1 < Self.maximumRecords else { break }
            let bytes = record.requestJSON.count + record.responseJSON.count
            guard bytes <= Self.maximumRetainedBytes - retainedBytes else { break }
            let encodedCount = try encoder.encode(record).count + 1
            guard encodedCount <= Self.maximumEncodedBytes - encodedBytes else { break }
            retainedBytes += bytes
            encodedBytes += encodedCount
            retainedCount += 1
        }
        records = Array(records.suffix(retainedCount)) + [candidate]
    }

    /// Conservative admission estimate before expensive worker execution. A false value
    /// means a large response may be display-only; it must not disable future inspections.
    /// Base64 can expand to eight JSON bytes per three input bytes when slashes escape.
    static func canRetainLargestResponse(requestJSON: Data) throws -> Bool {
        let encodedRequestBytes = try JSONEncoder().encode(requestJSON).count
        let responseBound = ((REAInspectionLimits.maximumResponseBytes + 2) / 3) * 8
        return encodedRequestBytes + responseBound + 2_048 <= maximumEncodedBytes
    }

    func isCurrent(_ record: REAResultEvidence, activeAuthority: REAResultAuthority) -> Bool {
        record.authority == activeAuthority
    }

    /// Cursor is an explicit byte offset into the immutable, digest-bound accepted response.
    func read(evidenceID: UUID, responseSHA256: String, offset: Int, maximumBytes: Int) throws -> REAResultEvidencePage {
        guard maximumBytes > 0, maximumBytes <= Self.maximumReadBytes, offset >= 0 else {
            throw REAResultEvidenceError.bounds
        }
        guard let record = records.first(where: { $0.evidenceID == evidenceID }),
              record.responseSHA256 == responseSHA256 else { throw REAResultEvidenceError.unavailable }
        guard offset <= record.responseJSON.count else { throw REAResultEvidenceError.bounds }
        let end = offset + min(maximumBytes, record.responseJSON.count - offset)
        return .init(evidenceID: evidenceID, responseSHA256: responseSHA256,
            totalBytes: record.responseJSON.count, offset: offset,
            bytes: record.responseJSON.subdata(in: offset..<end),
            nextOffset: end < record.responseJSON.count ? end : nil)
    }

    private func validate() throws {
        guard records.count <= Self.maximumRecords,
              Set(records.map(\.evidenceID)).count == records.count,
              Set(records.map(\.requestID)).count == records.count else { throw REAResultEvidenceError.bounds }
        var remaining = Self.maximumRetainedBytes
        for record in records {
            try record.validate()
            for bytes in [record.requestJSON, record.responseJSON] {
                guard bytes.count <= remaining else { throw REAResultEvidenceError.bounds }
                remaining -= bytes.count
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case records }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(records: c.decode([REAResultEvidence].self, forKey: .records))
    }
}

struct REAResultEvidencePage: Equatable, Sendable {
    let evidenceID: UUID
    let responseSHA256: String
    let totalBytes: Int
    let offset: Int
    let bytes: Data
    let nextOffset: Int?
}

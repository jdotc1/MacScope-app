import Foundation

/// Bounded inert projection for app-authorized reads of previously accepted REA evidence.
/// These descriptors must be registered in the app read catalog before minting read handles.
enum REAResultReadProjection {
    static let listOperation = Phase2ReadOperationID(rawValue: "rea.results.list")
    static let getOperation = Phase2ReadOperationID(rawValue: "rea.results.get")
    static let descriptors: [Phase2ReadOperationDescriptor] = [listOperation, getOperation].map {
        .init(registryVersion: .v1, id: $0, operationVersion: .v1, effects: [.a1])
    }
    static let maximumListRecords = 32
    // Base64 encoding a byte page plus identity metadata stays comfortably below64KiB.
    static let maximumPageBytes = 32_768

    enum Freshness: String, Codable, Sendable { case current, stale, unknown }
    enum Failure: Error, Equatable { case bounds, unavailable, wrongWorkspace }
    struct Summary: Codable, Equatable, Sendable {
        let evidenceID: UUID
        let requestID: UUID
        let operation: String
        let imageSHA256: String
        let snapshotID: UUID
        let sourceGeneration: UInt64
        let resourceSHA256: String
        let implementationIdentity: String
        let responseSHA256: String
        let responseBytes: Int
        let freshness: Freshness
    }
    struct Listing: Codable, Equatable, Sendable {
        let records: [Summary]
        let nextOffset: Int?
    }
    struct Page: Codable, Equatable, Sendable {
        let record: Summary
        let offset: Int
        let bytes: Data
        let nextOffset: Int?
    }

    struct TextPage: Codable, Equatable, Sendable {
        let record: Summary
        let offset: Int
        let text: String
        let nextOffset: Int?
    }

    /// Model-facing text preserves UTF-8 bytes and never repairs split scalar sequences.
    static func getText(store: REAResultEvidenceStore, workspaceID: UUID,
                        activeAuthority: REAResultAuthority?, evidenceID: UUID,
                        responseSHA256: String, offset: Int, maximumBytes: Int) throws -> TextPage {
        let page = try get(store: store, workspaceID: workspaceID, activeAuthority: activeAuthority,
            evidenceID: evidenceID, responseSHA256: responseSHA256, offset: offset, maximumBytes: maximumBytes)
        var bytes = page.bytes
        // A valid UTF-8 scalar occupies at most four bytes. Only the final scalar may be
        // incomplete; an offset inside a scalar must fail rather than lose leading bytes.
        for _ in 0..<4 {
            if let text = String(data: bytes, encoding: .utf8) {
                guard !bytes.isEmpty || offset == page.record.responseBytes else { throw Failure.bounds }
                let end = offset + bytes.count
                return .init(record: page.record, offset: offset, text: text,
                    nextOffset: end < page.record.responseBytes ? end : nil)
            }
            guard !bytes.isEmpty else { break }
            bytes.removeLast()
        }
        throw Failure.bounds
    }

    static func list(store: REAResultEvidenceStore, workspaceID: UUID,
                     activeAuthority: REAResultAuthority?, offset: Int = 0,
                     maximumRecords: Int = maximumListRecords) throws -> Listing {
        try validateActive(activeAuthority, workspaceID: workspaceID)
        guard offset >= 0, maximumRecords > 0, maximumRecords <= maximumListRecords else { throw Failure.bounds }
        let records = store.records.filter { $0.authority.workspaceID == workspaceID }
        guard offset <= records.count else { throw Failure.bounds }
        let end = offset + min(maximumRecords, records.count - offset)
        return .init(records: records[offset..<end].map { summary($0, activeAuthority: activeAuthority) },
                     nextOffset: end < records.count ? end : nil)
    }

    static func get(store: REAResultEvidenceStore, workspaceID: UUID,
                    activeAuthority: REAResultAuthority?, evidenceID: UUID,
                    responseSHA256: String, offset: Int, maximumBytes: Int) throws -> Page {
        try validateActive(activeAuthority, workspaceID: workspaceID)
        guard maximumBytes > 0, maximumBytes <= maximumPageBytes else { throw Failure.bounds }
        guard let record = store.records.first(where: { $0.evidenceID == evidenceID && $0.authority.workspaceID == workspaceID }) else {
            throw Failure.unavailable
        }
        let page = try store.read(evidenceID: evidenceID, responseSHA256: responseSHA256,
                                  offset: offset, maximumBytes: maximumBytes)
        return .init(record: summary(record, activeAuthority: activeAuthority), offset: page.offset,
                     bytes: page.bytes, nextOffset: page.nextOffset)
    }

    private static func validateActive(_ authority: REAResultAuthority?, workspaceID: UUID) throws {
        if let authority {
            try authority.validate()
            guard authority.workspaceID == workspaceID else { throw Failure.wrongWorkspace }
        }
    }
    private static func summary(_ record: REAResultEvidence, activeAuthority: REAResultAuthority?) -> Summary {
        let authority = record.authority
        return .init(evidenceID: record.evidenceID, requestID: record.requestID, operation: record.operation,
            imageSHA256: authority.imageSHA256, snapshotID: authority.snapshotID,
            sourceGeneration: authority.sourceGeneration, resourceSHA256: authority.resourceSHA256,
            implementationIdentity: authority.implementationIdentity, responseSHA256: record.responseSHA256,
            responseBytes: record.responseJSON.count,
            freshness: activeAuthority.map {
                $0.workspaceID == authority.workspaceID && $0.imageSHA256 == authority.imageSHA256
                && $0.sourceGeneration == authority.sourceGeneration && $0.resourceSHA256 == authority.resourceSHA256
                && $0.implementationIdentity == authority.implementationIdentity ? .current : .stale
            } ?? .unknown)
    }
}

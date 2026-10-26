import Foundation

enum ReconstructionEvidenceReadAuthorityError: Error, Equatable {
    case invalidDescriptor
    case invalidReceipt
}

/// Receipt-qualified metadata for an app-executed evidence read. It retains references to existing
/// evidence and the projector's cursor, never another evidence payload or a native result.
struct ReconstructionEvidenceReadAuthority: Hashable, Codable, Sendable {
    static let maximumEncodedBytes = 262_144
    let schemaVersion: Int
    let request: ReconstructionToolRequestEnvelope
    let packetSHA256: String
    let readEvidenceIDs: [UUID]
    let nextCursor: ReconstructionRetrievalCursor?

    init(schemaVersion: Int = 1, request: ReconstructionToolRequestEnvelope,
        packetSHA256: String, readEvidenceIDs: [UUID],
        nextCursor: ReconstructionRetrievalCursor?) throws {
        self.schemaVersion = schemaVersion
        self.request = request
        self.packetSHA256 = packetSHA256
        self.readEvidenceIDs = readEvidenceIDs
        self.nextCursor = nextCursor
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, request, packetSHA256, readEvidenceIDs, nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            request: c.decode(ReconstructionToolRequestEnvelope.self, forKey: .request),
            packetSHA256: c.decode(String.self, forKey: .packetSHA256),
            readEvidenceIDs: c.decode([UUID].self, forKey: .readEvidenceIDs),
            nextCursor: c.decodeIfPresent(ReconstructionRetrievalCursor.self, forKey: .nextCursor))
    }

    func validate() throws {
        // The authority cut uses synthesized Codable, so reconstruct its validating initializer
        // before trusting any decoded field or re-minting a request handle.
        let authority = request.authority
        _ = try ReconstructionToolAuthorityCut(jobID: authority.jobID,
            checkpointRevision: authority.checkpointRevision, roundID: authority.roundID,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            evidenceFrontierSHA256: authority.evidenceFrontierSHA256,
            projectionFrontierSHA256: authority.projectionFrontierSHA256)
        guard schemaVersion == 1, request.schemaVersion == 1,
              request.operationID == .evidenceQuery, let query = request.retrievalQuery,
              readEvidenceIDs.count <= 4_096,
              readEvidenceIDs.count <= query.maximumRecords,
              Set(readEvidenceIDs).count == readEvidenceIDs.count,
              ReconstructionToolAuthorityCut.isCanonicalSHA256(packetSHA256) else {
            throw ReconstructionEvidenceReadAuthorityError.invalidDescriptor
        }
        _ = try ReconstructionToolRegistry().mintHandles(
            authority: request.authority, requests: [request.request])
        if let nextCursor {
            guard !readEvidenceIDs.isEmpty, readEvidenceIDs.last == nextCursor.evidenceID,
                  nextCursor != query.cursor else {
                throw ReconstructionEvidenceReadAuthorityError.invalidDescriptor
            }
            let continuation = try Self.copy(query, cursor: nextCursor)
            _ = try ReconstructionToolRegistry().mintHandles(authority: request.authority,
                requests: [.init(operationID: .evidenceQuery, taskID: request.taskID,
                    subject: request.subject, retrievalQuery: continuation, offset: 1,
                    maximumRecords: continuation.maximumRecords,
                    maximumEncodedBytes: continuation.maximumEncodedBytes)])
        }
        guard try ReconstructionCanonicalJSON.encode(self).count <= Self.maximumEncodedBytes else {
            throw ReconstructionEvidenceReadAuthorityError.invalidDescriptor
        }
    }

    func validate(receipt: ReconstructionToolReceipt) throws {
        try validate()
        let handle = try ReconstructionToolRegistry().mintHandles(
            authority: request.authority, requests: [request.request])[0]
        guard request.authority.checkpointRevision < UInt64.max,
              receipt.receiptID == handle.handleID,
              receipt.jobID == request.authority.jobID,
              receipt.taskID == request.taskID,
              receipt.checkpointRevision == request.authority.checkpointRevision + 1,
              receipt.requestIdentitySHA256 == handle.requestSHA256,
              receipt.producer.operationIdentity == ReconstructionOperationID.evidenceQuery.rawValue,
              receipt.outputEvidenceIDs.isEmpty, receipt.diagnostic == nil,
              receipt.terminalState == (nextCursor == nil ? .completed : .truncated) else {
            throw ReconstructionEvidenceReadAuthorityError.invalidReceipt
        }
    }

    static func copy(_ query: ReconstructionRetrievalQuery,
        cursor: ReconstructionRetrievalCursor?, maximumRecords: Int? = nil,
        maximumEncodedBytes: Int? = nil) throws -> ReconstructionRetrievalQuery {
        try .init(corpusManifestSHA256: query.corpusManifestSHA256, subject: query.subject,
            operationIDs: query.operationIDs, classifications: query.classifications, cursor: cursor,
            maximumRecords: maximumRecords ?? query.maximumRecords,
            maximumEncodedBytes: maximumEncodedBytes ?? query.maximumEncodedBytes, focus: query.focus)
    }
}

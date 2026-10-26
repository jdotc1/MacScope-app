import CryptoKit
import Foundation

struct ReconstructionToolAuthorityCut: Hashable, Codable, Sendable {
    let jobID: UUID
    let checkpointRevision: UInt64
    let roundID: UUID
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let projectionFrontierSHA256: String

    init(
        jobID: UUID,
        checkpointRevision: UInt64,
        roundID: UUID,
        corpusManifestSHA256: String,
        evidenceFrontierSHA256: String,
        projectionFrontierSHA256: String
    ) throws {
        guard Self.isCanonicalSHA256(corpusManifestSHA256),
              Self.isCanonicalSHA256(evidenceFrontierSHA256),
              Self.isCanonicalSHA256(projectionFrontierSHA256) else {
            throw ReconstructionToolRegistryError.invalidAuthorityCut
        }
        self.jobID = jobID
        self.checkpointRevision = checkpointRevision
        self.roundID = roundID
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.projectionFrontierSHA256 = projectionFrontierSHA256
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct ReconstructionAppToolCatalogEntry: Hashable, Sendable {
    let operationID: ReconstructionOperationID
    let functionName: String
    let description: String
}

enum ReconstructionAppToolCatalog {
    static let registryID = "reconstruction.v1"
    static let registryVersion = 1
    static let schemaSetID = "reconstruction.v1.schemas"
    static let schemaSetVersion = 1

    static let entries: [ReconstructionAppToolCatalogEntry] = [
        entry(.corpusSummary, "Read the immutable reconstruction corpus summary."),
        entry(.corpusArtifactsPage, "Read an app-bounded page of corpus artifacts."),
        entry(.corpusArtifactDescribe, "Describe one app-selected corpus artifact."),
        entry(.corpusRelationsPage, "Read an app-bounded page of corpus relations."),
        entry(.corpusSearch, "Read app-compiled corpus search results."),
        entry(.imagesPage, "Read an app-bounded page of analyzed images."),
        entry(.functionsPage, "Read an app-bounded page of analyzed functions."),
        entry(.functionReview, "Review one app-selected function."),
        entry(.decompilerNative, "Read one app-selected native decompilation."),
        entry(.decompilerMacScope, "Read one app-selected MacScope decompilation."),
        entry(.decompilerCompare, "Compare app-selected decompiler results."),
        entry(.evidenceQuery, "Read app-compiled deterministic evidence results."),
        entry(.evidenceGet, "Read one app-selected durable evidence record."),
        entry(.gapsPage, "Read an app-bounded page of unresolved evidence gaps."),
        entry(.checkpointStatus, "Read the immutable reconstruction checkpoint status."),
        entry(.analysisMacScopeRefresh, "Request one fresh MacScope analysis of the app-selected committed function. Select with continue; analysis runs after the selection commits, before the next model round."),
    ]

    private static func entry(
        _ operationID: ReconstructionOperationID,
        _ description: String
    ) -> ReconstructionAppToolCatalogEntry {
        .init(
            operationID: operationID,
            functionName: "macscope_\(operationID.rawValue.replacingOccurrences(of: ".", with: "_"))_v1",
            description: description
        )
    }
}

struct ReconstructionToolRequest: Hashable, Codable, Sendable {
    let operationID: ReconstructionOperationID
    let taskID: UUID
    let subject: ReconstructionDurableSubject?
    let retrievalQuery: ReconstructionRetrievalQuery?
    let offset: Int
    let maximumRecords: Int
    let maximumEncodedBytes: Int
}

struct ReconstructionToolRequestEnvelope: Hashable, Codable, Sendable {
    let schemaVersion: Int
    let authority: ReconstructionToolAuthorityCut
    let request: ReconstructionToolRequest

    var operationID: ReconstructionOperationID { request.operationID }
    var taskID: UUID { request.taskID }
    var subject: ReconstructionDurableSubject? { request.subject }
    var retrievalQuery: ReconstructionRetrievalQuery? { request.retrievalQuery }
    var offset: Int { request.offset }
    var maximumRecords: Int { request.maximumRecords }
    var maximumEncodedBytes: Int { request.maximumEncodedBytes }
}

enum ReconstructionToolRegistryError: Error, Equatable, Sendable {
    case invalidAuthorityCut
    case invalidRequestSet
    case invalidRequest
    case duplicateOperation
    case duplicateHandle
    case invalidHandleIdentity
    case requestOperationMismatch
    case nonCanonicalRequest
    case invalidRequestDigest
    case authorityMismatch
}

struct ReconstructionToolRegistry: Sendable {
    private static let schemaVersion = 1
    private static let maximumRequestCount = ReconstructionOperationID.allCases.count
    private static let maximumRecords = 100_000
    static let maximumOffset = 100_000
    private static let maximumRequestBytes = 1_048_576
    private static let maximumTotalRequestBytes = 4_194_304

    private struct HandlePreimage: Codable {
        let schemaVersion: Int
        let domain: String
        let operationID: String
        let requestSHA256: String
        let jobID: UUID
        let checkpointRevision: UInt64
        let roundID: UUID
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let projectionFrontierSHA256: String
    }

    private struct QueryIdentityPreimage: Encodable {
        let schemaVersion: Int
        let domain: String
        let subject: ReconstructionDurableSubject?
        let focus: ReconstructionSubjectCoordinate?
        let operationIDs: [String]
        let classifications: [String]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, domain, subject, focus, operationIDs, classifications
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(domain, forKey: .domain)
            try container.encodeIfPresent(subject, forKey: .subject)
            try container.encodeIfPresent(focus, forKey: .focus)
            try container.encode(operationIDs, forKey: .operationIDs)
            try container.encode(classifications, forKey: .classifications)
        }
    }

    func mintHandles(
        authority: ReconstructionToolAuthorityCut,
        requests: [ReconstructionToolRequest]
    ) throws -> [ReconstructionToolHandle] {
        guard (1...Self.maximumRequestCount).contains(requests.count) else {
            throw ReconstructionToolRegistryError.invalidRequestSet
        }
        var operations: Set<ReconstructionOperationID> = []
        var encoded: [(ReconstructionToolRequest, Data, String)] = []
        var totalBytes = 0
        for request in requests {
            guard operations.insert(request.operationID).inserted else {
                throw ReconstructionToolRegistryError.duplicateOperation
            }
            try validate(request, authority: authority)
            let envelope = ReconstructionToolRequestEnvelope(
                schemaVersion: Self.schemaVersion,
                authority: authority,
                request: request
            )
            let bytes = try ReconstructionCanonicalJSON.encode(envelope)
            guard bytes.count <= Self.maximumRequestBytes else {
                throw ReconstructionToolRegistryError.invalidRequest
            }
            totalBytes += bytes.count
            guard totalBytes <= Self.maximumTotalRequestBytes else {
                throw ReconstructionToolRegistryError.invalidRequestSet
            }
            encoded.append((request, bytes, Self.sha256(bytes)))
        }

        var handleIDs: Set<UUID> = []
        let handles = try encoded.map { request, bytes, requestDigest in
            let handleID = try Self.handleID(
                operationID: request.operationID,
                requestSHA256: requestDigest,
                authority: authority
            )
            guard handleIDs.insert(handleID).inserted else {
                throw ReconstructionToolRegistryError.duplicateHandle
            }
            return ReconstructionToolHandle(
                handleID: handleID,
                operationID: request.operationID,
                canonicalRequest: bytes,
                requestSHA256: requestDigest,
                jobID: authority.jobID,
                checkpointRevision: authority.checkpointRevision,
                roundID: authority.roundID
            )
        }
        return handles.sorted {
            if $0.operationID.priority != $1.operationID.priority {
                return $0.operationID.priority < $1.operationID.priority
            }
            return $0.operationID.rawValue < $1.operationID.rawValue
        }
    }

    func decodeCanonicalRequest(
        _ handle: ReconstructionToolHandle
    ) throws -> ReconstructionToolRequestEnvelope {
        let envelope: ReconstructionToolRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(
                ReconstructionToolRequestEnvelope.self,
                from: handle.canonicalRequest
            )
            guard try ReconstructionCanonicalJSON.encode(envelope) == handle.canonicalRequest else {
                throw ReconstructionToolRegistryError.nonCanonicalRequest
            }
        } catch let error as ReconstructionToolRegistryError {
            throw error
        } catch {
            throw ReconstructionToolRegistryError.nonCanonicalRequest
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw ReconstructionToolRegistryError.nonCanonicalRequest
        }
        guard ReconstructionToolAuthorityCut.isCanonicalSHA256(handle.requestSHA256),
              Self.sha256(handle.canonicalRequest) == handle.requestSHA256 else {
            throw ReconstructionToolRegistryError.invalidRequestDigest
        }
        guard envelope.operationID == handle.operationID else {
            throw ReconstructionToolRegistryError.requestOperationMismatch
        }
        guard envelope.authority.jobID == handle.jobID,
              envelope.authority.checkpointRevision == handle.checkpointRevision,
              envelope.authority.roundID == handle.roundID else {
            throw ReconstructionToolRegistryError.authorityMismatch
        }
        guard try Self.handleID(
            operationID: envelope.operationID,
            requestSHA256: handle.requestSHA256,
            authority: envelope.authority
        ) == handle.handleID else {
            throw ReconstructionToolRegistryError.invalidHandleIdentity
        }
        try validate(envelope.request, authority: envelope.authority)
        return envelope
    }

    private func validate(
        _ request: ReconstructionToolRequest,
        authority: ReconstructionToolAuthorityCut
    ) throws {
        guard ReconstructionAppToolCatalog.entries.contains(where: {
                  $0.operationID == request.operationID
              }),
              (0...Self.maximumOffset).contains(request.offset),
              (1...Self.maximumRecords).contains(request.maximumRecords),
              (64...Self.maximumRequestBytes).contains(request.maximumEncodedBytes) else {
            throw ReconstructionToolRegistryError.invalidRequest
        }
        if request.operationID == .evidenceQuery {
            guard let query = request.retrievalQuery,
                  query.corpusManifestSHA256 == authority.corpusManifestSHA256,
                  query.subject == request.subject,
                  query.maximumRecords == request.maximumRecords,
                  query.maximumEncodedBytes == request.maximumEncodedBytes else {
                throw ReconstructionToolRegistryError.invalidRequest
            }
            if let cursor = query.cursor {
                guard request.offset == 1,
                      cursor.schemaVersion == 1,
                      cursor.corpusManifestSHA256 == authority.corpusManifestSHA256,
                      cursor.evidenceFrontierSHA256 == authority.evidenceFrontierSHA256,
                      cursor.queryIdentitySHA256 == (try Self
                        .canonicalRetrievalQueryIdentitySHA256(query)),
                      (0...1).contains(cursor.currentBucket),
                      (0...2).contains(cursor.subjectSpecificity),
                      ReconstructionOperationID.allCases.map(\.priority)
                        .contains(cursor.operationPriority),
                      cursor.canonicalSubjectIdentity.count == SHA256.byteCount else {
                    throw ReconstructionToolRegistryError.invalidRequest
                }
            } else if request.offset != 0 {
                throw ReconstructionToolRegistryError.invalidRequest
            }
        } else if request.operationID == .analysisMacScopeRefresh {
            guard case .function? = request.subject,
                  request.retrievalQuery == nil,
                  request.offset == 0, request.maximumRecords == 1 else {
                throw ReconstructionToolRegistryError.invalidRequest
            }
        } else if request.retrievalQuery != nil {
            throw ReconstructionToolRegistryError.invalidRequest
        }
    }

    static func canonicalRetrievalQueryIdentitySHA256(
        _ query: ReconstructionRetrievalQuery
    ) throws -> String {
        try ReconstructionCanonicalJSON.sha256(of: QueryIdentityPreimage(
            schemaVersion: 1,
            domain: "reconstruction.evidence-retrieval-query.v1",
            subject: try query.subject.map { try structuralSubject($0) },
            focus: try query.focus.map { try structuralSubject($0) },
            operationIDs: query.operationIDs.map(\.rawValue),
            classifications: query.classifications.map(\.rawValue)
        ))
    }

    private static func structuralSubject(
        _ subject: ReconstructionDurableSubject
    ) throws -> ReconstructionDurableSubject {
        switch subject {
        case .artifact, .image: return subject
        case .function(let function):
            return .function(try ReconstructionFunctionCoordinate(
                artifact: function.artifact,
                image: function.image,
                analysisFingerprintSHA256: function.analysisFingerprintSHA256,
                startAddress: function.startAddress,
                endAddressExclusive: function.endAddressExclusive,
                boundarySchemaVersion: function.boundarySchemaVersion,
                functionUUIDHint: nil,
                symbolHint: nil
            ))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func handleID(
        operationID: ReconstructionOperationID,
        requestSHA256: String,
        authority: ReconstructionToolAuthorityCut
    ) throws -> UUID {
        let preimage = HandlePreimage(
            schemaVersion: schemaVersion,
            domain: "reconstruction.tool-handle.v1",
            operationID: operationID.rawValue,
            requestSHA256: requestSHA256,
            jobID: authority.jobID,
            checkpointRevision: authority.checkpointRevision,
            roundID: authority.roundID,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            evidenceFrontierSHA256: authority.evidenceFrontierSHA256,
            projectionFrontierSHA256: authority.projectionFrontierSHA256
        )
        return deterministicUUID(
            digest: Array(SHA256.hash(data: try ReconstructionCanonicalJSON.encode(preimage)))
        )
    }

    private static func deterministicUUID(digest: [UInt8]) -> UUID {
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

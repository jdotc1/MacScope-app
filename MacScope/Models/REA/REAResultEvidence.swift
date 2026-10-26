import Foundation
import CryptoKit

/// App-captured authority, separate from any claims made by the JavaScript result.
struct REAResultAuthority: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let imageSHA256: String
    let snapshotID: UUID
    let sourceGeneration: UInt64
    let resourceSHA256: String
    let implementationIdentity: String

    func validate() throws {
        guard [imageSHA256, resourceSHA256, implementationIdentity].allSatisfy(Self.isDigest) else {
            throw REAResultEvidenceError.invalidIdentity
        }
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum REAResultEvidenceError: Error, Equatable {
    case invalidIdentity, invalidEnvelope, staleAuthority, duplicateIdentity, bounds, unavailable
}

/// Validated successful result. This is a persistence DTO, never an upstream REA object graph.
/// Operation-specific admission must run before construction; wire success alone cannot prove
/// the captured input inventory or authenticate process-capture receipts.
struct REAResultEvidence: Codable, Equatable, Sendable {
    let evidenceID: UUID
    let requestID: UUID
    let operation: String
    let authority: REAResultAuthority
    let requestJSON: Data
    let responseJSON: Data
    let requestSHA256: String
    let responseSHA256: String

    init(evidenceID: UUID = UUID(), requestID: UUID, operation: String,
         authority: REAResultAuthority, requestJSON: Data, responseJSON: Data) throws {
        self.evidenceID = evidenceID
        self.requestID = requestID
        self.operation = operation
        self.authority = authority
        self.requestJSON = requestJSON
        self.responseJSON = responseJSON
        requestSHA256 = Self.digest(requestJSON)
        responseSHA256 = Self.digest(responseJSON)
        try validate()
    }

    func validate() throws {
        try authority.validate()
        let header = try REAInspectionWireCodec.validateRequest(requestJSON, requestID: requestID)
        guard header.operation.rawValue == operation,
              Self.digest(requestJSON) == requestSHA256,
              Self.digest(responseJSON) == responseSHA256 else { throw REAResultEvidenceError.invalidIdentity }
        try REAInspectionWireCodec.validateResponse(responseJSON, requestID: requestID,
            operation: header.operation, implementationIdentity: authority.implementationIdentity)
        guard let envelope = try JSONSerialization.jsonObject(with: responseJSON) as? [String: Any],
              let ok = envelope["ok"] as? Bool, ok else { throw REAResultEvidenceError.invalidEnvelope }
    }

    private enum CodingKeys: String, CodingKey {
        case evidenceID, requestID, operation, authority, requestJSON, responseJSON, requestSHA256, responseSHA256
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        evidenceID = try c.decode(UUID.self, forKey: .evidenceID)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        operation = try c.decode(String.self, forKey: .operation)
        authority = try c.decode(REAResultAuthority.self, forKey: .authority)
        requestJSON = try c.decode(Data.self, forKey: .requestJSON)
        responseJSON = try c.decode(Data.self, forKey: .responseJSON)
        requestSHA256 = try c.decode(String.self, forKey: .requestSHA256)
        responseSHA256 = try c.decode(String.self, forKey: .responseSHA256)
        try validate()
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

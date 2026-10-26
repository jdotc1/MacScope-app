import Foundation

/// Immutable capture supplied by MacScope's corpus/capture authority. No path is reopened.
struct REAUIResourceCapture: Sendable {
    let targetSHA256: String
    let snapshotID: String
    let relativePath: String
    let archiveSHA256: String
    let kind: REAUIResourceDocument.Kind
    let format: REAUIResourceDocument.Format
    let bytes: Data
}

/// Catalog metadata and the producer binding that the caller must admit before scheduling.
/// This projection verifies the supplied bytes and binding; it does not authenticate a producer.
struct REAUIAssetCatalogCapture: Sendable {
    let targetSHA256: String
    let snapshotID: String
    let path: String
    let catalogSHA256: String
    let captureID: String
    let toolSHA256: String
    let metadataSHA256: String
    let metadataBytes: Data
}

struct REAUIResourceInput: Encodable, Sendable {
    let targetSHA256: String
    let snapshotID: String
    let documents: [REAUIResourceDocument]
    let omittedDocuments: Int
    let omittedCatalogs: Int
    let metadata: REAUIBoundObjCMetadata
    /// nil means unavailable, never an assertion that the image contains no catalogs.
    let assetCatalogs: [REAUIAssetCatalogDocument]?
}

struct REAUIResourceDocument: Encodable, Sendable {
    enum Kind: String, Encodable, Sendable { case nib, storyboard_scene }
    /// keyedArchiveJSON is captured decoded JSON, not original binary-plist bytes.
    enum Format: String, Encodable, Sendable { case nibArchive, keyedArchiveJSON }
    let relativePath: String
    let archiveSHA256: String
    let kind: Kind
    let format: Format
    let bytesBase64: String
}

struct REAUIAssetCatalogDocument: Encodable, Sendable {
    let path: String
    let sha256: String
    let captureID: String
    let toolSHA256: String
    let metadataJSONBase64: String
    let metadataSHA256: String
}

struct REAUIBoundObjCMetadata: Encodable, Sendable {
    let targetSHA256: String
    let snapshotID: String
    let value: REAUIObjCMetadata
}

/// A MacScope-owned wire projection. The foreign graph is not a persisted product model.
struct REAUIObjCMetadata: Encodable, Sendable {
    let implementations: [REAUIObjCImplementation]
    let coverage: [REAUIObjCCoverage]
    enum CodingKeys: String, CodingKey {
        case implementations = "objc_dispatch_implementations"
        case coverage
        case databaseSaveResult = "db_save_result"
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(implementations, forKey: .implementations)
        try container.encode(coverage, forKey: .coverage)
        try container.encodeNil(forKey: .databaseSaveResult)
    }
}

struct REAUIObjCImplementation: Encodable, Sendable {
    let className: String
    let selector: String
    let methodType: String
    let implementationAddress: String?
    let category: String?
    let location: REAUILocation
    let decode: REAUIDecodeState
    let evidence: [REAUIObjCEvidence]
    enum CodingKeys: String, CodingKey {
        case className = "class_name", selector, methodType = "method_type"
        case implementationAddress = "implementation_address", category, location, decode, evidence
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(className, forKey: .className)
        try container.encode(selector, forKey: .selector)
        try container.encode(methodType, forKey: .methodType)
        if let implementationAddress { try container.encode(implementationAddress, forKey: .implementationAddress) }
        else { try container.encodeNil(forKey: .implementationAddress) }
        if let category { try container.encode(category, forKey: .category) }
        try container.encode(location, forKey: .location)
        try container.encode(decode, forKey: .decode)
        try container.encode(evidence, forKey: .evidence)
    }
}

struct REAUILocation: Encodable, Sendable {
    let address: String?
    // The existing ObjC records do not retain a verified field/file-offset location.
    enum CodingKeys: String, CodingKey { case address, fileOffset = "file_offset" }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let address { try container.encode(address, forKey: .address) }
        else { try container.encodeNil(forKey: .address) }
        try container.encodeNil(forKey: .fileOffset)
    }
}

struct REAUIDecodeState: Encodable, Sendable {
    let status: String
    let reason: String?
    enum CodingKeys: String, CodingKey { case status, reason }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let reason { try container.encode(reason, forKey: .reason) }
        else { try container.encodeNil(forKey: .reason) }
    }
}

struct REAUIObjCEvidence: Encodable, Sendable {
    let kind = "binary_metadata"
    let description: String
    let location: REAUILocation
    let artifactPath: String
    let artifactSHA256: String
    enum CodingKeys: String, CodingKey {
        case kind, description, location, artifactPath = "artifact_path", artifactSHA256 = "artifact_sha256"
    }
}

struct REAUIObjCCoverage: Encodable, Sendable {
    let facet: String
    let status: String
    let reason: String
    let examined: Int
    let decoded: Int
}

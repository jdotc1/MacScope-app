import Foundation

enum AnalysisFingerprintError: Error, Equatable, LocalizedError {
    case invalidSchemaVersion
    case invalidItemCount
    case invalidSHA256(field: String)
    case invalidArchiveMemberIdentity
    case duplicateFacetKind(AnalysisFingerprintFacetKind)

    var errorDescription: String? {
        switch self {
        case .invalidSchemaVersion:
            "Analysis fingerprint schema version must be positive."
        case .invalidItemCount:
            "Analysis fingerprint facet item count must be non-negative."
        case .invalidSHA256(let field):
            "Analysis fingerprint field \(field) must be canonical lowercase SHA-256."
        case .invalidArchiveMemberIdentity:
            "Analysis fingerprint ELF archive member identity is malformed."
        case .duplicateFacetKind(let kind):
            "Analysis fingerprint facet \(kind.rawValue) must appear at most once."
        }
    }
}

enum AnalysisFingerprintFacetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case selectedSliceBytes
    case loaderSections
    case codeDataRanges
    case relocations
    case machOLoadMetadata
    case decodedInstructions
    case functions
    case controlFlow
    case xrefs
    case debugSourceLines
}

struct AnalysisFacetFingerprint: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var kind: AnalysisFingerprintFacetKind
    var schemaVersion: Int
    var itemCount: Int
    var byteCount: UInt64?
    var sha256: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case itemCount
        case byteCount
        case sha256
    }

    init(
        kind: AnalysisFingerprintFacetKind,
        schemaVersion: Int = Self.currentSchemaVersion,
        itemCount: Int,
        byteCount: UInt64? = nil,
        sha256: String
    ) throws {
        guard schemaVersion > 0 else { throw AnalysisFingerprintError.invalidSchemaVersion }
        guard itemCount >= 0 else { throw AnalysisFingerprintError.invalidItemCount }
        guard Self.isLowercaseSHA256(sha256) else {
            throw AnalysisFingerprintError.invalidSHA256(field: "sha256")
        }
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(AnalysisFingerprintFacetKind.self, forKey: .kind),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            itemCount: container.decode(Int.self, forKey: .itemCount),
            byteCount: container.decodeIfPresent(UInt64.self, forKey: .byteCount),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

struct AnalysisInputFingerprint: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var imageSlot: ImageSlot
    var binaryID: UUID
    var binaryName: String
    var binaryPath: String
    var selectedSliceIndex: Int?
    var artifactIdentity: MachOSliceArtifactIdentity?
    /// Exact outer-container and ordinary-member identity for an ELF archive load. Optional so
    /// historical non-archive fingerprints retain their original schema and encoded shape.
    var elfArchiveMemberIdentity: ELFArchiveMemberSelection?
    var imageByteCount: UInt64
    var imageBytesSHA256: String
    var facets: [AnalysisFacetFingerprint]
    var overallSHA256: String
    /// Navigator analysis input key (lowercase SHA-256). Optional and absent unless the caller
    /// supplied a navigator input-key context, so historical fingerprints keep their encoded
    /// shape. It is not an input to `overallSHA256`.
    var inputKey: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case imageSlot
        case binaryID
        case binaryName
        case binaryPath
        case selectedSliceIndex
        case artifactIdentity
        case elfArchiveMemberIdentity
        case imageByteCount
        case imageBytesSHA256
        case facets
        case overallSHA256
        case inputKey
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        imageSlot: ImageSlot,
        binaryID: UUID,
        binaryName: String,
        binaryPath: String,
        selectedSliceIndex: Int?,
        artifactIdentity: MachOSliceArtifactIdentity?,
        elfArchiveMemberIdentity: ELFArchiveMemberSelection? = nil,
        imageByteCount: UInt64,
        imageBytesSHA256: String,
        facets: [AnalysisFacetFingerprint],
        overallSHA256: String,
        inputKey: String? = nil
    ) throws {
        guard schemaVersion > 0 else { throw AnalysisFingerprintError.invalidSchemaVersion }
        guard AnalysisFacetFingerprint.isLowercaseSHA256(imageBytesSHA256) else {
            throw AnalysisFingerprintError.invalidSHA256(field: "imageBytesSHA256")
        }
        guard AnalysisFacetFingerprint.isLowercaseSHA256(overallSHA256) else {
            throw AnalysisFingerprintError.invalidSHA256(field: "overallSHA256")
        }
        if let inputKey, !AnalysisFacetFingerprint.isLowercaseSHA256(inputKey) {
            throw AnalysisFingerprintError.invalidSHA256(field: "inputKey")
        }
        if let elfArchiveMemberIdentity,
           (!BinaryImage.isValidArchiveMemberIdentity(elfArchiveMemberIdentity)
               || selectedSliceIndex != nil) {
            throw AnalysisFingerprintError.invalidArchiveMemberIdentity
        }
        var seenFacetKinds = Set<AnalysisFingerprintFacetKind>()
        for facet in facets {
            guard seenFacetKinds.insert(facet.kind).inserted else {
                throw AnalysisFingerprintError.duplicateFacetKind(facet.kind)
            }
        }
        self.schemaVersion = schemaVersion
        self.imageSlot = imageSlot
        self.binaryID = binaryID
        self.binaryName = binaryName
        self.binaryPath = binaryPath
        self.selectedSliceIndex = selectedSliceIndex
        self.artifactIdentity = artifactIdentity
        self.elfArchiveMemberIdentity = elfArchiveMemberIdentity
        self.imageByteCount = imageByteCount
        self.imageBytesSHA256 = imageBytesSHA256
        self.facets = facets.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.sha256 < $1.sha256
        }
        self.overallSHA256 = overallSHA256
        self.inputKey = inputKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            imageSlot: container.decode(ImageSlot.self, forKey: .imageSlot),
            binaryID: container.decode(UUID.self, forKey: .binaryID),
            binaryName: container.decode(String.self, forKey: .binaryName),
            binaryPath: container.decode(String.self, forKey: .binaryPath),
            selectedSliceIndex: container.decodeIfPresent(Int.self, forKey: .selectedSliceIndex),
            artifactIdentity: container.decodeIfPresent(MachOSliceArtifactIdentity.self, forKey: .artifactIdentity),
            elfArchiveMemberIdentity: container.decodeIfPresent(
                ELFArchiveMemberSelection.self,
                forKey: .elfArchiveMemberIdentity
            ),
            imageByteCount: container.decode(UInt64.self, forKey: .imageByteCount),
            imageBytesSHA256: container.decode(String.self, forKey: .imageBytesSHA256),
            facets: container.decode([AnalysisFacetFingerprint].self, forKey: .facets),
            overallSHA256: container.decode(String.self, forKey: .overallSHA256),
            inputKey: container.decodeIfPresent(String.self, forKey: .inputKey)
        )
    }
}

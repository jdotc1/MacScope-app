import Foundation

/// A revision supplied by the user when accepting a local source checkout. MacScope does not
/// infer this value from a path, a compiler string, or the current checkout on disk.
struct SourceRevisionIdentity: Hashable, Codable, Sendable {
    let value: String

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 512,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        self.value = normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = Self(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Source revision identity is invalid."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Exact binary owner for a source link. A bare address or UUID is insufficient in a workspace
/// that can contain multiple versions and universal slices of the same program.
struct SourceLinkImageIdentity: Hashable, Codable, Sendable {
    let slot: ImageSlot
    let binaryID: UUID
    let imageUUID: UUID
    let architecture: String
    let selectedSliceIndex: Int?
    let sourceRevision: SourceRevisionIdentity

    init?(
        slot: ImageSlot,
        binaryID: UUID,
        imageUUID: String,
        architecture: String,
        selectedSliceIndex: Int?,
        sourceRevision: SourceRevisionIdentity
    ) {
        guard let imageUUID = UUID(uuidString: imageUUID) else { return nil }
        let architecture = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !architecture.isEmpty, architecture.utf8.count <= 128,
              selectedSliceIndex.map({ $0 >= 0 }) ?? true else { return nil }
        self.slot = slot
        self.binaryID = binaryID
        self.imageUUID = imageUUID
        self.architecture = architecture
        self.selectedSliceIndex = selectedSliceIndex
        self.sourceRevision = sourceRevision
    }

    /// Display names can omit arm64e or include universal-container prose. Use the selected
    /// loader-owned header when present; never equate arm64 and arm64e by string normalization.
    static func architecture(for binary: BinaryImage) -> String {
        guard let artifact = binary.artifactIdentity,
              artifact.uuid == binary.metadata.uuid.flatMap(UUID.init(uuidString:)) else {
            return binary.architecture
        }
        if artifact.architectureVariant != .other { return artifact.architectureVariant.rawValue }
        let subtype = artifact.rawCPUSubtype & ~MachOConstants.cpuSubtypeCapabilityMask
        return "cpu(\(artifact.rawCPUType),\(subtype))"
    }

    private enum CodingKeys: String, CodingKey {
        case slot, binaryID, imageUUID, architecture, selectedSliceIndex, sourceRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = Self(
            slot: try container.decode(ImageSlot.self, forKey: .slot),
            binaryID: try container.decode(UUID.self, forKey: .binaryID),
            imageUUID: try container.decode(String.self, forKey: .imageUUID),
            architecture: try container.decode(String.self, forKey: .architecture),
            selectedSliceIndex: try container.decodeIfPresent(Int.self, forKey: .selectedSliceIndex),
            sourceRevision: try container.decode(SourceRevisionIdentity.self, forKey: .sourceRevision)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .imageUUID, in: container,
                debugDescription: "Source-link image identity is invalid."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slot, forKey: .slot)
        try container.encode(binaryID, forKey: .binaryID)
        try container.encode(imageUUID.uuidString.lowercased(), forKey: .imageUUID)
        try container.encode(architecture, forKey: .architecture)
        try container.encodeIfPresent(selectedSliceIndex, forKey: .selectedSliceIndex)
        try container.encode(sourceRevision, forKey: .sourceRevision)
    }
}

/// An explicitly accepted relationship between paths recorded by a build and one local source
/// checkout. The recorded root may differ from the current machine's root; only the relative
/// suffix below it is remapped.
struct AcceptedLocalSourceCheckout: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let localRootPath: String
    let recordedSourceRoot: String
    let revision: SourceRevisionIdentity

    init?(
        id: UUID = UUID(),
        localRootPath: String,
        recordedSourceRoot: String,
        revision: SourceRevisionIdentity
    ) {
        let localRoot = Self.normalizedRoot(localRootPath)
        let recordedRoot = Self.normalizedRoot(recordedSourceRoot)
        guard localRoot.hasPrefix("/"), localRoot != "/", !recordedRoot.isEmpty,
              localRoot.utf8.count <= 4_096, recordedRoot.utf8.count <= 4_096 else { return nil }
        self.id = id
        self.localRootPath = localRoot
        self.recordedSourceRoot = recordedRoot
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, localRootPath, recordedSourceRoot, revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = Self(
            id: try container.decode(UUID.self, forKey: .id),
            localRootPath: try container.decode(String.self, forKey: .localRootPath),
            recordedSourceRoot: try container.decode(String.self, forKey: .recordedSourceRoot),
            revision: try container.decode(SourceRevisionIdentity.self, forKey: .revision)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .localRootPath, in: container,
                debugDescription: "Accepted local source checkout is invalid."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(localRootPath, forKey: .localRootPath)
        try container.encode(recordedSourceRoot, forKey: .recordedSourceRoot)
        try container.encode(revision, forKey: .revision)
    }

    private static func normalizedRoot(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        // A relative DWARF file table can be rooted at the compilation directory itself.
        guard standardized != "." else { return "." }
        guard standardized != "/" else { return standardized }
        var end = standardized.endIndex
        while end > standardized.startIndex,
              standardized[standardized.index(before: end)] == "/" {
            end = standardized.index(before: end)
        }
        return String(standardized[..<end])
    }
}

/// A compiler-emitted path or other marker can propose a source file, but never establishes an
/// address-to-line mapping or build identity on its own.
struct CompilerSourceMarker: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let recordedPath: String
    let line: Int?
    let column: Int?
    let functionAddress: UInt64?
    let sourceRevision: SourceRevisionIdentity?
    let description: String

    init?(
        id: UUID = UUID(),
        recordedPath: String,
        line: Int? = nil,
        column: Int? = nil,
        functionAddress: UInt64? = nil,
        sourceRevision: SourceRevisionIdentity? = nil,
        description: String
    ) {
        let path = recordedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !description.isEmpty, description.utf8.count <= 1_024,
              line.map({ $0 > 0 }) ?? true,
              column.map({ $0 > 0 }) ?? true else { return nil }
        self.id = id
        self.recordedPath = path
        self.line = line
        self.column = column
        self.functionAddress = functionAddress
        self.sourceRevision = sourceRevision
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordedPath, line, column, functionAddress, sourceRevision, description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = Self(
            id: try container.decode(UUID.self, forKey: .id),
            recordedPath: try container.decode(String.self, forKey: .recordedPath),
            line: try container.decodeIfPresent(Int.self, forKey: .line),
            column: try container.decodeIfPresent(Int.self, forKey: .column),
            functionAddress: try container.decodeIfPresent(UInt64.self, forKey: .functionAddress),
            sourceRevision: try container.decodeIfPresent(SourceRevisionIdentity.self, forKey: .sourceRevision),
            description: try container.decode(String.self, forKey: .description)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordedPath, in: container,
                debugDescription: "Compiler source marker is invalid."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(recordedPath, forKey: .recordedPath)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(column, forKey: .column)
        try container.encodeIfPresent(functionAddress, forKey: .functionAddress)
        try container.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
        try container.encode(description, forKey: .description)
    }
}

enum SourceLinkEvidence: Hashable, Codable, Sendable {
    case debugSymbols(
        artifactUUID: UUID,
        artifactMachOSHA256: String,
        artifactMachOByteCount: UInt64,
        lineProgramUnitOffset: UInt64,
        fileTableIndex: UInt32,
        architecture: String,
        sourceRevision: SourceRevisionIdentity
    )
    case compilerMarker(markerID: UUID, description: String)
    case functionCorrelation(referenceImage: SourceLinkImageIdentity, referenceAddress: UInt64,
                             debugArtifactUUID: UUID, debugArtifactSHA256: String,
                             normalizedBodyHash: String, semanticBodyHash: String)
}

enum SourceLinkQualification: String, Hashable, Codable, Sendable {
    case exactDebugSymbols
    case versionQualifiedCandidate
    case unresolved
}

enum SourceLinkUnresolvedReason: String, Hashable, Codable, Sendable {
    case imageHasNoUUID
    case debugArtifactIncomplete
    case debugArtifactUUIDMismatch
    case architectureMismatch
    case sourceRevisionMismatch
    case noAcceptedCheckout
    case recordedPathOutsideAcceptedRoot
    case noLineForAddress
}

/// One source candidate, including refusals. Keeping unresolved records visible prevents a marker
/// or a partially matched dSYM from disappearing into an apparently authoritative link.
struct SourceEvidenceLink: Hashable, Codable, Sendable, Identifiable {
    let image: SourceLinkImageIdentity?
    let functionAddress: UInt64
    let recordedPath: String?
    let localPath: String?
    let checkoutID: UUID?
    let line: Int?
    let column: Int?
    let qualification: SourceLinkQualification
    let evidence: SourceLinkEvidence?
    let unresolvedReason: SourceLinkUnresolvedReason?

    var id: String {
        let owner = image.map {
            "\($0.slot.rawValue):\($0.binaryID.uuidString):\($0.imageUUID.uuidString):\($0.architecture):\($0.selectedSliceIndex.map(String.init) ?? "thin"):\($0.sourceRevision.value)"
        } ?? "unowned"
        let evidenceID: String
        switch evidence {
        case .debugSymbols(let artifactUUID, let digest, _, let unitOffset, let fileIndex,
                           let architecture, let sourceRevision):
            evidenceID = "debug:\(artifactUUID.uuidString):\(digest):\(unitOffset):\(fileIndex):\(architecture):\(sourceRevision.value)"
        case .compilerMarker(let markerID, _):
            evidenceID = "marker:\(markerID.uuidString)"
        case .functionCorrelation(let reference, let address, let uuid, let digest, let body, let semantic):
            evidenceID = "correlation:\(reference.binaryID):\(reference.imageUUID):\(address):\(uuid):\(digest):\(body):\(semantic)"
        case nil:
            evidenceID = "none"
        }
        return "\(owner):\(functionAddress):\(recordedPath ?? ""):\(line ?? 0):\(qualification.rawValue):\(evidenceID)"
    }

    var isOpenable: Bool {
        image != nil && localPath != nil && (line.map { $0 > 0 } ?? true)
            && qualification != .unresolved && unresolvedReason == nil
    }
}

/// The same source opener services the focused inspector and either side of Compare Images. The
/// origin is part of the request so a stale row cannot silently open the other image's source.
enum SourceLinkOpenOrigin: Hashable, Codable, Sendable {
    case inspector(slot: ImageSlot)
    case compareImagesOld(slot: ImageSlot)
    case compareImagesNew(slot: ImageSlot)

    var slot: ImageSlot {
        switch self {
        case .inspector(let slot), .compareImagesOld(let slot), .compareImagesNew(let slot): slot
        }
    }
}

struct SourceFileOpenTarget: Hashable, Sendable {
    let fileURL: URL
    /// nil opens only the file; a compiler string must not invent an address-to-line mapping.
    let line: Int?
    let column: Int?
    let image: SourceLinkImageIdentity
    let origin: SourceLinkOpenOrigin
}

enum SourceLinkOpenError: LocalizedError, Equatable {
    case unresolved
    case staleImage
    case staleSourceRevision
    case staleCheckout
    case pathEscapesCheckout
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .unresolved: "This source candidate is not resolved to an accepted local checkout."
        case .staleImage: "The source link belongs to a different image, slice, or comparison side."
        case .staleSourceRevision: "The accepted source checkout no longer matches this link's revision."
        case .staleCheckout: "The source link belongs to a different accepted local checkout."
        case .pathEscapesCheckout: "The source path resolves outside the accepted checkout."
        case .fileUnavailable: "The linked source file is unavailable or is not a regular file."
        }
    }
}

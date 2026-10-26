import Foundation

/// Exact immutable identity of the outer archive bytes. The archive—not a member display name—
/// remains the filesystem and bookmark authority.
struct ELFArchiveContainerIdentity: Codable, Equatable, Hashable, Sendable {
    let byteCount: Int
    let sha256: String
}

/// Exact identity of one ordinary archive member. `index` is stable in ordinary-member source
/// order, while `archiveHeaderIndex` detects special-member insertion/removal and reordering.
struct ELFArchiveMemberIdentity: Codable, Equatable, Hashable, Sendable {
    let index: Int
    let archiveHeaderIndex: Int
    let name: String
    let payloadOffset: Int
    let byteCount: Int
    let sha256: String
}

/// The fail-closed coordinate passed when an archive contains more than one ELF member. Both the
/// outer bytes and selected member must still match at load/reanalysis time; an index alone is
/// deliberately insufficient because archive members can be reordered or replaced in place.
struct ELFArchiveMemberSelection: Codable, Equatable, Hashable, Sendable {
    let container: ELFArchiveContainerIdentity
    let member: ELFArchiveMemberIdentity

    var isWellFormed: Bool {
        container.byteCount >= 0
            && Self.isLowercaseSHA256(container.sha256)
            && member.index >= 0
            && member.archiveHeaderIndex >= 0
            && member.payloadOffset >= 0
            && member.byteCount >= 0
            && !member.name.isEmpty
            && member.name.utf8.count <= 4_096
            && Self.isLowercaseSHA256(member.sha256)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }
}

struct ELFArchiveMemberSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    let containerIdentity: ELFArchiveContainerIdentity
    let identity: ELFArchiveMemberIdentity

    var id: Int { identity.index }
    var index: Int { identity.index }
    var archiveHeaderIndex: Int { identity.archiveHeaderIndex }
    var name: String { identity.name }
    var byteCount: Int { identity.byteCount }
}

/// Format-neutral load choice carried separately from the binary URL. Existing Mach-O-only
/// callers can keep passing `requestedSliceIndex`; production import/XPC paths use this value so
/// archive selection never overloads or fabricates a path.
struct BinaryLoadSelection: Codable, Equatable, Hashable, Sendable {
    let requestedMachOSliceIndex: Int?
    let elfArchiveMember: ELFArchiveMemberSelection?
    /// nil selects the current layout for a fresh open; 0 explicitly preserves legacy COFF coordinates.
    let coffSectionLayoutVersion: Int?
    /// The install name of the dyld shared cache image to project (the open-time picker's choice).
    /// nil keeps the loader's historical default (the cache's first image).
    let dyldCacheImagePath: String?

    init(
        requestedMachOSliceIndex: Int? = nil,
        elfArchiveMember: ELFArchiveMemberSelection? = nil,
        coffSectionLayoutVersion: Int? = nil,
        dyldCacheImagePath: String? = nil
    ) {
        precondition(
            requestedMachOSliceIndex == nil || elfArchiveMember == nil,
            "Mach-O slice and ELF archive member selectors are mutually exclusive"
        )
        precondition(
            dyldCacheImagePath == nil || (requestedMachOSliceIndex == nil && elfArchiveMember == nil),
            "a dyld cache image selector excludes Mach-O slice and archive member selectors"
        )
        precondition(dyldCacheImagePath.map(Self.isWellFormedDyldCacheImagePath) != false)
        precondition(coffSectionLayoutVersion == nil || coffSectionLayoutVersion == 0 || coffSectionLayoutVersion == 1)
        self.requestedMachOSliceIndex = requestedMachOSliceIndex
        self.elfArchiveMember = elfArchiveMember
        self.coffSectionLayoutVersion = coffSectionLayoutVersion
        self.dyldCacheImagePath = dyldCacheImagePath
    }

    /// A cache image selector is a non-empty install name without NULs (the loader matches it
    /// exactly or by path suffix against the cache's image table; it never names a file).
    static func isWellFormedDyldCacheImagePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.utf8.contains(0)
    }

    static func dyldCacheImage(_ path: String) -> BinaryLoadSelection {
        BinaryLoadSelection(dyldCacheImagePath: path)
    }

    /// Typed construction for decoded or otherwise untrusted selectors. The ordinary initializer
    /// is reserved for trusted in-module construction and traps on a programmer-created conflict;
    /// every wire/Codable ingress uses this initializer and rejects conflicts as data errors.
    init(
        validatingRequestedMachOSliceIndex requestedMachOSliceIndex: Int?,
        elfArchiveMember: ELFArchiveMemberSelection?,
        coffSectionLayoutVersion: Int? = nil,
        dyldCacheImagePath: String? = nil
    ) throws {
        guard requestedMachOSliceIndex == nil || elfArchiveMember == nil else {
            throw BinaryLoadSelectionError.conflictingSelectors
        }
        guard dyldCacheImagePath == nil || (requestedMachOSliceIndex == nil && elfArchiveMember == nil) else {
            throw BinaryLoadSelectionError.conflictingSelectors
        }
        guard dyldCacheImagePath.map(Self.isWellFormedDyldCacheImagePath) != false else {
            throw BinaryLoadSelectionError.invalidDyldCacheImagePath
        }
        guard requestedMachOSliceIndex.map({ $0 >= 0 }) != false else {
            throw BinaryLoadSelectionError.invalidMachOSliceIndex
        }
        guard elfArchiveMember?.isWellFormed != false else {
            throw BinaryLoadSelectionError.invalidArchiveSelection
        }
        guard coffSectionLayoutVersion == nil || coffSectionLayoutVersion == 0 || coffSectionLayoutVersion == 1 else {
            throw BinaryLoadSelectionError.invalidCOFFSectionLayoutVersion
        }
        self.requestedMachOSliceIndex = requestedMachOSliceIndex
        self.elfArchiveMember = elfArchiveMember
        self.coffSectionLayoutVersion = coffSectionLayoutVersion
        self.dyldCacheImagePath = dyldCacheImagePath
    }

    var isWellFormed: Bool {
        (requestedMachOSliceIndex == nil || elfArchiveMember == nil)
            && (dyldCacheImagePath == nil || (requestedMachOSliceIndex == nil && elfArchiveMember == nil))
            && dyldCacheImagePath.map(Self.isWellFormedDyldCacheImagePath) != false
            && requestedMachOSliceIndex.map { $0 >= 0 } != false
            && elfArchiveMember?.isWellFormed != false
            && (coffSectionLayoutVersion == nil || coffSectionLayoutVersion == 0 || coffSectionLayoutVersion == 1)
    }

    /// Older rehydrate APIs carry persisted products but no metadata marker. Preserve their
    /// historical COFF coordinates; this bounded two-byte format sniff grants no byte mapping.
    static func legacyCOFFRehydrateLayoutVersion(for bytes: Data) -> Int? {
        guard bytes.count >= 2 else { return nil }
        let start = bytes.startIndex
        switch (bytes[start], bytes[start + 1]) {
        case (0x64, 0x86), (0x64, 0xaa), (0x4c, 0x01): return 0
        default: return nil
        }
    }

    static let automatic = BinaryLoadSelection()

    static func machOSlice(_ index: Int?) -> BinaryLoadSelection {
        BinaryLoadSelection(requestedMachOSliceIndex: index)
    }

    private enum CodingKeys: String, CodingKey {
        case requestedMachOSliceIndex
        case elfArchiveMember
        case coffSectionLayoutVersion
        case dyldCacheImagePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingRequestedMachOSliceIndex: container.decodeIfPresent(
                Int.self,
                forKey: .requestedMachOSliceIndex
            ),
            elfArchiveMember: container.decodeIfPresent(
                ELFArchiveMemberSelection.self,
                forKey: .elfArchiveMember
            ),
            coffSectionLayoutVersion: container.decodeIfPresent(Int.self, forKey: .coffSectionLayoutVersion),
            dyldCacheImagePath: container.decodeIfPresent(String.self, forKey: .dyldCacheImagePath)
        )
    }

    func encode(to encoder: Encoder) throws {
        guard requestedMachOSliceIndex == nil || elfArchiveMember == nil else {
            throw BinaryLoadSelectionError.conflictingSelectors
        }
        guard requestedMachOSliceIndex.map({ $0 >= 0 }) != false else {
            throw BinaryLoadSelectionError.invalidMachOSliceIndex
        }
        guard elfArchiveMember?.isWellFormed != false else {
            throw BinaryLoadSelectionError.invalidArchiveSelection
        }
        guard dyldCacheImagePath == nil || (requestedMachOSliceIndex == nil && elfArchiveMember == nil) else {
            throw BinaryLoadSelectionError.conflictingSelectors
        }
        guard dyldCacheImagePath.map(Self.isWellFormedDyldCacheImagePath) != false else {
            throw BinaryLoadSelectionError.invalidDyldCacheImagePath
        }
        guard isWellFormed else { throw BinaryLoadSelectionError.invalidCOFFSectionLayoutVersion }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(requestedMachOSliceIndex, forKey: .requestedMachOSliceIndex)
        try container.encodeIfPresent(elfArchiveMember, forKey: .elfArchiveMember)
        try container.encodeIfPresent(coffSectionLayoutVersion, forKey: .coffSectionLayoutVersion)
        try container.encodeIfPresent(dyldCacheImagePath, forKey: .dyldCacheImagePath)
    }
}

enum BinaryLoadSelectionError: LocalizedError, Equatable {
    case invalidCOFFSectionLayoutVersion
    case coffSectionLayoutUnsupported
    case archiveSelectionUnsupported
    case dyldCacheImageSelectionUnsupported
    case invalidArchiveSelection
    case invalidMachOSliceIndex
    case invalidDyldCacheImagePath
    case conflictingSelectors

    var errorDescription: String? {
        switch self {
        case .invalidCOFFSectionLayoutVersion:
            "The COFF section layout version is unsupported."
        case .coffSectionLayoutUnsupported:
            "This analysis provider cannot preserve the requested COFF section layout."
        case .archiveSelectionUnsupported:
            "This analysis provider cannot carry an ELF archive member selection."
        case .dyldCacheImageSelectionUnsupported:
            "This analysis provider cannot carry a dyld shared cache image selection."
        case .invalidArchiveSelection:
            "The ELF archive member selection is malformed."
        case .invalidMachOSliceIndex:
            "The Mach-O slice index is malformed."
        case .invalidDyldCacheImagePath:
            "The dyld shared cache image selection is malformed."
        case .conflictingSelectors:
            "Mach-O slice, ELF archive member and dyld cache image selectors cannot be combined."
        }
    }
}

import Darwin
import CryptoKit
import Foundation
import SwiftUI

enum EditorMode: String, CaseIterable, Codable, Identifiable {
    case disassembly = "Disassembly"
    case pseudocode = "Pseudocode"
    case graph = "Graph"
    case hex = "Hex"

    var id: String { rawValue }

    static func caseInsensitiveMatch(_ value: String?) -> EditorMode? {
        guard let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedValue.isEmpty
        else { return nil }

        return allCases.first { mode in
            mode.rawValue.lowercased() == normalizedValue || mode.id.lowercased() == normalizedValue
        }
    }

    var systemImage: String {
        switch self {
        case .disassembly: "lumen.disassembly"
        case .pseudocode: "lumen.pseudocode"
        case .graph: "lumen.callGraph"
        case .hex: "number"
        }
    }
}

enum WorkspaceTool: String, CaseIterable, Codable, Identifiable {
    case project = "Project"
    case symbols = "Symbols"
    case strings = "Strings"
    case xrefs = "Xrefs"
    case debug = "Debug"
    case extensions = "Extensions"
    /// Appended deliberately: existing raw values and dock order remain stable for persisted
    /// sessions while Reconstruction gains a first-class workspace destination.
    case reconstruction = "Reconstruction"
    /// U7a, appended for the same reason: the Type Atlas over the image's ObjC, Swift and user types.
    case types = "Types"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .project: "square.stack.3d.up"
        case .symbols: "function"
        case .strings: "text.quote"
        case .xrefs: "lumen.crossReference"
        case .debug: "ladybug"
        case .extensions: "puzzlepiece.extension"
        case .reconstruction: "arrow.trianglehead.2.clockwise.rotate.90"
        case .types: "cube"
        }
    }
}

/// A workspace-level address: a virtual address qualified by the image slot it belongs to.
/// Deliberately NOT Comparable — ordering addresses across images is a design error.
/// Inside a single image's analysis (the engine, per-image derived tables) bare `UInt64`
/// remains correct; `ImageAddress` is the identity for workspace-global user state
/// (overrides, breakpoints, bookmarks) where slots can collide on the same VA.
struct ImageAddress: Hashable, Codable, Sendable {
    var slot: ImageSlot
    var address: UInt64

    /// The primary-image qualification of a bare address — the single-image default and the
    /// shape every legacy call site means when it names a bare address.
    static func primary(_ address: UInt64) -> ImageAddress {
        ImageAddress(slot: .primary, address: address)
    }
}

/// Authority from one captured full Mach-O container and its verified selected slice.
/// This is session-local evidence. BinaryImage intentionally omits it from Codable,
/// because a saved digest or a restored thin slice cannot verify an outer container.
struct MachOContainerAdmissionWitness: Hashable, Codable, Sendable {
    let containerSHA256: String
    let containerByteCount: UInt64
    let sliceOffset: UInt64
    let sliceSize: UInt64
    let selectedSliceIdentity: MachOSliceArtifactIdentity

    private enum CodingKeys: String, CodingKey {
        case containerSHA256, containerByteCount, sliceOffset, sliceSize, selectedSliceIdentity
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let digest = try fields.decode(String.self, forKey: .containerSHA256)
        let count = try fields.decode(UInt64.self, forKey: .containerByteCount)
        let offset = try fields.decode(UInt64.self, forKey: .sliceOffset)
        let size = try fields.decode(UInt64.self, forKey: .sliceSize)
        let identity = try fields.decode(MachOSliceArtifactIdentity.self, forKey: .selectedSliceIdentity)
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              offset <= count, size > 0, size <= count - offset,
              size == identity.selectedSliceByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .containerSHA256, in: fields,
                debugDescription: "Malformed captured-container witness.")
        }
        containerSHA256 = digest
        containerByteCount = count
        sliceOffset = offset
        sliceSize = size
        selectedSliceIdentity = identity
    }

    init?(containerBytes: Data, sliceOffset: UInt64, sliceSize: UInt64?,
          selectedSliceIdentity: MachOSliceArtifactIdentity) {
        let total = UInt64(containerBytes.count)
        guard sliceOffset <= total else { return nil }
        let size = sliceSize ?? (total - sliceOffset)
        guard size == selectedSliceIdentity.selectedSliceByteCount,
              size > 0, size <= total - sliceOffset,
              let first = Int(exactly: sliceOffset),
              let last = Int(exactly: sliceOffset + size) else { return nil }
        let selectedDigest = SHA256.hash(data: containerBytes[first..<last])
            .map { String(format: "%02x", $0) }.joined()
        guard selectedDigest == selectedSliceIdentity.selectedSliceSHA256 else { return nil }
        self.containerSHA256 = SHA256.hash(data: containerBytes)
            .map { String(format: "%02x", $0) }.joined()
        self.containerByteCount = total
        self.sliceOffset = sliceOffset
        self.sliceSize = size
        self.selectedSliceIdentity = selectedSliceIdentity
    }
}

/// Loader-observed origin of the selected Mach-O image, not a requested selection.
/// Absence means unknown (including old snapshots); it never means thin or slice zero.
/// This descriptive fact does not confer byte or artifact admission authority.
struct MachOSelectedSliceFact: Hashable, Codable, Sendable {
    enum ContainerKind: String, Hashable, Codable, Sendable { case thin, universal }
    let containerKind: ContainerKind
    let sliceCount: Int
    let selectedSliceIndex: Int
    let cpuType: Int32
    let cpuSubtype: Int32

    enum ValidationError: Error { case invalidSelection }

    init(containerKind: ContainerKind, sliceCount: Int, selectedSliceIndex: Int,
         cpuType: Int32, cpuSubtype: Int32) throws {
        guard sliceCount > 0, selectedSliceIndex >= 0, selectedSliceIndex < sliceCount,
              containerKind != .thin || (sliceCount == 1 && selectedSliceIndex == 0) else {
            throw ValidationError.invalidSelection
        }
        self.containerKind = containerKind
        self.sliceCount = sliceCount
        self.selectedSliceIndex = selectedSliceIndex
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
    }

    private enum CodingKeys: String, CodingKey {
        case containerKind, sliceCount, selectedSliceIndex, cpuType, cpuSubtype
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(containerKind: fields.decode(ContainerKind.self, forKey: .containerKind),
                      sliceCount: fields.decode(Int.self, forKey: .sliceCount),
                      selectedSliceIndex: fields.decode(Int.self, forKey: .selectedSliceIndex),
                      cpuType: fields.decode(Int32.self, forKey: .cpuType),
                      cpuSubtype: fields.decode(Int32.self, forKey: .cpuSubtype))
    }

    var displayLabel: String {
        switch containerKind {
        case .thin: return "thin slice 0"
        case .universal: return "universal slice \(selectedSliceIndex) of \(sliceCount)"
        }
    }

    /// Compatibility projection for APIs that select from an outer universal container.
    var universalSliceIndex: Int? { containerKind == .universal ? selectedSliceIndex : nil }
}

struct BinaryImage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var kind: String
    var architecture: String
    var originalPathBookmark: Data? = nil
    var metadata: BinaryMetadataSummary = .empty
    /// Compatibility selection for reopening the outer universal container. Old records may
    /// contain only the request; nil is not evidence that the original container was thin.
    /// Persisted so re-analysis (mark-as-code/data) and document restore keep the same
    /// slice instead of silently reverting to the default architecture.
    var selectedSliceIndex: Int? = nil
    var machOSelectedSliceFact: MachOSelectedSliceFact? = nil
    /// Exact selected member when the filesystem path names an outer Unix archive. The outer
    /// archive remains path/bookmark authority; this identity is never encoded into `path`.
    var elfArchiveMemberIdentity: ELFArchiveMemberSelection? = nil
    /// Reconstructed exact selected-slice evidence. These values cross the same-build analysis
    /// worker boundary but are intentionally absent from database/package schemas and are rebuilt
    /// synchronously from verified attachments on reopen.
    var artifactIdentity: MachOSliceArtifactIdentity? = nil
    var preferredSegmentLayout: MachOPreferredSegmentLayout? = nil
    var artifactIntegrityState: MachOSliceArtifactIntegrityState = .unavailable
    /// Created only from a fresh full-container load; omitted from CodingKeys.
    var containerAdmissionWitness: MachOContainerAdmissionWitness? = nil
    /// Fresh-import display/corroboration hint only; never persisted as artifact authority.
    var resolvedExecutablePath: String? = nil
    /// The image's durable workspace slot (see `ImageSlot`). The engine always emits
    /// `.primary`; the store re-stamps the prior slot when splicing a re-analysis back in.
    var slot: ImageSlot = .primary

    init(
        id: UUID,
        name: String,
        path: String,
        kind: String,
        architecture: String,
        originalPathBookmark: Data? = nil,
        metadata: BinaryMetadataSummary = .empty,
        selectedSliceIndex: Int? = nil,
        machOSelectedSliceFact: MachOSelectedSliceFact? = nil,
        elfArchiveMemberIdentity: ELFArchiveMemberSelection? = nil,
        artifactIdentity: MachOSliceArtifactIdentity? = nil,
        preferredSegmentLayout: MachOPreferredSegmentLayout? = nil,
        artifactIntegrityState: MachOSliceArtifactIntegrityState = .unavailable,
        containerAdmissionWitness: MachOContainerAdmissionWitness? = nil,
        resolvedExecutablePath: String? = nil,
        slot: ImageSlot = .primary
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.architecture = architecture
        self.originalPathBookmark = originalPathBookmark
        self.metadata = metadata
        self.selectedSliceIndex = selectedSliceIndex
        self.machOSelectedSliceFact = machOSelectedSliceFact
        self.elfArchiveMemberIdentity = elfArchiveMemberIdentity
        self.artifactIdentity = artifactIdentity
        self.preferredSegmentLayout = preferredSegmentLayout
        self.artifactIntegrityState = artifactIntegrityState
        self.containerAdmissionWitness = containerAdmissionWitness
        self.resolvedExecutablePath = resolvedExecutablePath
        self.slot = slot
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, architecture, originalPathBookmark, metadata
        case selectedSliceIndex, machOSelectedSliceFact, elfArchiveMemberIdentity, artifactIdentity, preferredSegmentLayout
        case artifactIntegrityState, resolvedExecutablePath, slot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let artifactIdentity = try container.decodeIfPresent(
            MachOSliceArtifactIdentity.self,
            forKey: .artifactIdentity
        )
        var preferredSegmentLayout = try container.decodeIfPresent(
            MachOPreferredSegmentLayout.self,
            forKey: .preferredSegmentLayout
        )
        let artifactIntegrityState = try container.decodeIfPresent(
            MachOSliceArtifactIntegrityState.self,
            forKey: .artifactIntegrityState
        ) ?? .unavailable
        if artifactIntegrityState == .verified {
            guard let artifactIdentity, let layout = preferredSegmentLayout else {
                throw DecodingError.dataCorruptedError(
                    forKey: .artifactIntegrityState,
                    in: container,
                    debugDescription: "Verified artifact evidence requires both identity and layout."
                )
            }
            preferredSegmentLayout = try MachOPreferredSegmentLayout(
                records: layout.records,
                selectedSliceByteCount: artifactIdentity.selectedSliceByteCount
            )
        }
        let archiveMemberIdentity = try container.decodeIfPresent(
            ELFArchiveMemberSelection.self,
            forKey: .elfArchiveMemberIdentity
        )
        let selectedSliceIndex = try container.decodeIfPresent(Int.self, forKey: .selectedSliceIndex)
        let machOSelectedSliceFact = try container.decodeIfPresent(MachOSelectedSliceFact.self, forKey: .machOSelectedSliceFact)
        if let archiveMemberIdentity,
           (!Self.isValidArchiveMemberIdentity(archiveMemberIdentity) || selectedSliceIndex != nil || machOSelectedSliceFact != nil) {
            throw DecodingError.dataCorruptedError(
                forKey: .elfArchiveMemberIdentity,
                in: container,
                debugDescription: "ELF archive member identity is malformed or outside its container."
            )
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            path: try container.decode(String.self, forKey: .path),
            kind: try container.decode(String.self, forKey: .kind),
            architecture: try container.decode(String.self, forKey: .architecture),
            originalPathBookmark: try container.decodeIfPresent(Data.self, forKey: .originalPathBookmark),
            metadata: try container.decodeIfPresent(BinaryMetadataSummary.self, forKey: .metadata) ?? .empty,
            selectedSliceIndex: selectedSliceIndex,
            machOSelectedSliceFact: machOSelectedSliceFact,
            elfArchiveMemberIdentity: archiveMemberIdentity,
            artifactIdentity: artifactIdentity,
            preferredSegmentLayout: preferredSegmentLayout,
            artifactIntegrityState: artifactIntegrityState,
            resolvedExecutablePath: try container.decodeIfPresent(String.self, forKey: .resolvedExecutablePath),
            slot: try container.decodeIfPresent(ImageSlot.self, forKey: .slot) ?? .primary
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(kind, forKey: .kind)
        try container.encode(architecture, forKey: .architecture)
        try container.encodeIfPresent(originalPathBookmark, forKey: .originalPathBookmark)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(selectedSliceIndex, forKey: .selectedSliceIndex)
        try container.encodeIfPresent(machOSelectedSliceFact, forKey: .machOSelectedSliceFact)
        try container.encodeIfPresent(elfArchiveMemberIdentity, forKey: .elfArchiveMemberIdentity)
        try container.encodeIfPresent(artifactIdentity, forKey: .artifactIdentity)
        try container.encodeIfPresent(preferredSegmentLayout, forKey: .preferredSegmentLayout)
        try container.encode(artifactIntegrityState, forKey: .artifactIntegrityState)
        try container.encodeIfPresent(resolvedExecutablePath, forKey: .resolvedExecutablePath)
        if slot != .primary { try container.encode(slot, forKey: .slot) }
    }

    static func isValidArchiveMemberIdentity(_ selection: ELFArchiveMemberSelection) -> Bool {
        guard selection.isWellFormed,
              selection.member.payloadOffset <= selection.container.byteCount else {
            return false
        }
        return selection.member.byteCount
            <= selection.container.byteCount - selection.member.payloadOffset
    }
}

struct BinaryMetadataSummary: Hashable, Codable {
    var uuid: String?
    /// ELF `NT_GNU_BUILD_ID`, kept separate from Mach-O `LC_UUID` because the
    /// formats and identity domains are not interchangeable.
    var elfGNUBuildID: String? = nil
    /// nil retains legacy bare-COFF coordinates; version 1 uses section-ordinal synthetic bases.
    var coffSectionLayoutVersion: Int? = nil
    var platformName: String?
    var minimumOSVersion: String?
    var sdkVersion: String?
    var buildTools: [String] = []

    static let empty = BinaryMetadataSummary()
}

struct FunctionSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var startAddress: UInt64
    var endAddress: UInt64
    var confidence: Double
    /// HOP-1: analysis-recovered no-return knowledge. `nil` = not known to halt. A user
    /// `FunctionSignatureOverride.noReturnState` always takes precedence over this.
    var noReturnProvenance: AnalysisNoReturnProvenance? = nil
}

struct SymbolSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var address: UInt64?
    var kind: String
    var libraryName: String?
    /// Exact loader-authored linkage spelling, independent of demangled/custom display text.
    /// Legacy analyses omit it and remain displayable but cannot provide raw-symbol authority.
    var rawLinkageName: String? = nil
}

struct ImportSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var libraryName: String?
    var libraryOrdinal: Int?
}

struct IndirectSymbolSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var kind: String
    var sourceSection: String
    var address: UInt64
    var entrySize: UInt32
    var tableIndex: UInt32
    var rawSymbolIndex: UInt32
    var symbolIndex: Int?
    var symbolName: String?
    var libraryOrdinal: Int?
    var libraryName: String?
    var isLocal: Bool
    var isAbsolute: Bool
}

struct ExportSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var address: UInt64?
    var source: String
    /// Mach-O export-trie terminal flags. Nil means no terminal authority was recovered.
    var terminalFlags: UInt64? = nil
}

struct StringLiteralSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var value: String
    var address: UInt64
    var sourceSection: String
    var byteLength: Int
}

/// A format-neutral segment/section of the loaded binary (the model-layer projection of
/// the loader's `BinarySection`): a named region with a virtual address, size, file
/// offset, and whether it holds executable code.
struct SectionSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var address: UInt64
    /// VIRTUAL span (address-space extent).
    var size: UInt64
    var fileOffset: UInt64
    var isExecutable: Bool
    /// BSS-type: occupies VA space but has NO file bytes (its `fileOffset` is a placeholder).
    var isZeroFill: Bool = false
    /// Physical (raw) byte count when the format declares it separately from the virtual
    /// span (PE SizeOfRawData vs VirtualSize); nil when the format does not distinguish them.
    /// Consumed by `FileAddressMapping.verifiedMappings` so raw padding past the virtual span
    /// never acquires a synthetic address.
    var fileSize: UInt64? = nil
    /// Present only for sections analyzed in the versioned bare-COFF synthetic layout.
    var coffCoordinate: COFFSectionCoordinate? = nil
}

/// A loader-declared data range inside an otherwise executable code region. Mach-O's
/// `LC_DATA_IN_CODE` is the first producer. These ranges are derived, non-authoring facts:
/// they make breakpoint/run-to-cursor and code discovery abstain from bytes the binary itself
/// declares are inline data.
struct CodeDataRangeSummary: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var address: UInt64
    var size: UInt64
    var kind: String

    var endAddress: UInt64? {
        guard size > 0 else { return nil }
        let (end, overflow) = address.addingReportingOverflow(size)
        return overflow ? nil : end
    }

    func contains(_ target: UInt64) -> Bool {
        guard let endAddress else { return false }
        return target >= address && target < endAddress
    }
}

/// A format-neutral relocation entry, projected from the loader's per-format relocation data
/// (ELF `Elf64_Rela`/`Rel`, Mach-O `relocation_info`/scattered) so both reach the model/UI through
/// one type. `typeName` is a best-effort human label for the common relocation kinds; `symbolName`
/// is populated only when the loader can resolve the target symbol (never fabricated).
struct RelocationSummary: Identifiable, Hashable, Codable {
    let id: UUID
    /// The location being relocated — the relocated VA/offset (ELF `r_offset`, Mach-O address).
    var address: UInt64
    /// The section the relocation lives in, qualified for Mach-O (e.g. `.rela.text` / `__TEXT,__text`).
    var sectionName: String
    /// The raw, architecture-specific relocation type code.
    var typeCode: UInt32
    /// A human-readable relocation type (e.g. `R_X86_64_PLT32`, `ARM64_RELOC_BRANCH26`); nil if unknown.
    var typeName: String?
    /// The resolved target symbol, when available; nil for a purely section-relative relocation.
    var symbolName: String?
    /// The raw symbol-table index the relocation references, when applicable.
    var symbolIndex: UInt32?
    /// The RELA addend (ELF); nil for Mach-O and ELF `REL`.
    var addend: Int64?
    /// Whether the reference is PC-relative.
    var isPCRelative: Bool = false
    /// The width in bytes the relocation patches.
    var widthInBytes: UInt32 = 0
}

/// Loader-issued proof that one complete, file-backed preferred-address range needs no loader
/// mutation: the exact selected-slice bytes are also the effective bytes for this range. This is
/// deliberately derived-only (never persisted), and is valid only with the bound artifact identity.
enum IdentityEffectiveByteRangeAttestationError: Error, Equatable {
    case invalidEvidence
}

struct IdentityEffectiveByteRangeAttestation: Hashable, Sendable {
    static let modelIdentifier = "mach-o-identity-effective-byte-range-v1"

    let artifactIdentity: MachOSliceArtifactIdentity
    let segmentName: String
    let startAddress: UInt64
    let endAddressExclusive: UInt64
    let sliceRelativeFileOffset: UInt64
    let byteCount: UInt64
    let initialProtections: Int32
    let rawBytesSHA256: String

    /// Read authority alone never grants instruction/function authority. Consumers admitting
    /// executable coverage must independently require this bit and their own function bounds.
    var isExecutable: Bool { initialProtections & 4 != 0 }

    init(
        artifactIdentity: MachOSliceArtifactIdentity,
        segmentName: String,
        startAddress: UInt64,
        endAddressExclusive: UInt64,
        sliceRelativeFileOffset: UInt64,
        byteCount: UInt64,
        initialProtections: Int32,
        rawBytesSHA256: String
    ) throws {
        let nameBytes = segmentName.utf8
        let virtualEnd = startAddress.addingReportingOverflow(byteCount)
        let fileEnd = sliceRelativeFileOffset.addingReportingOverflow(byteCount)
        guard (1...16).contains(nameBytes.count),
              !segmentName.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }),
              byteCount > 0,
              !virtualEnd.overflow,
              virtualEnd.partialValue == endAddressExclusive,
              !fileEnd.overflow,
              fileEnd.partialValue <= artifactIdentity.selectedSliceByteCount,
              initialProtections & 1 != 0,
              initialProtections & 2 == 0,
              initialProtections & ~7 == 0,
              rawBytesSHA256.utf8.count == 64,
              rawBytesSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw IdentityEffectiveByteRangeAttestationError.invalidEvidence
        }
        self.artifactIdentity = artifactIdentity
        self.segmentName = segmentName
        self.startAddress = startAddress
        self.endAddressExclusive = endAddressExclusive
        self.sliceRelativeFileOffset = sliceRelativeFileOffset
        self.byteCount = byteCount
        self.initialProtections = initialProtections
        self.rawBytesSHA256 = rawBytesSHA256
    }
}

/// A recovered DWARF line-table row: the source coordinate that begins at `address`. Each row's
/// coverage runs from its `address` until the next row's address; an `endSequence` row terminates a
/// contiguous code range and carries no source line (it bounds lookups so a gap address maps to no
/// line). Populated from a matched dSYM's `.debug_line` program; address-sorted on the snapshot.
struct SourceLineEntry: Hashable, Codable {
    var address: UInt64
    var file: String?
    var line: Int
    var column: Int
    var endSequence: Bool
    /// Exact source-breakpoint identity. All fields are optional for legacy imported rows; a
    /// resolver may treat a row as authoritative only when the complete evidence set is present.
    var debugArtifactUUID: UUID? = nil
    var debugArtifactMachOSHA256: String? = nil
    var debugArtifactMachOByteCount: UInt64? = nil
    var lineProgramUnitOffset: UInt64? = nil
    var fileTableIndex: UInt32? = nil
    var tablePath: DebuggerCanonicalSourceTablePath? = nil
}

struct BasicBlockSummary: Identifiable, Hashable, Codable {
    let id: UUID
    var functionID: UUID
    var startAddress: UInt64
    var endAddress: UInt64
    var instructionCount: Int
}

struct InstructionRow: Identifiable, Hashable, Codable {
    var id: UInt64 { address }
    var address: UInt64
    var bytes: String
    var mnemonic: String
    var operands: String
    var hasBreakpoint: Bool
    var comment: String?
    var structuredOperands: InstructionOperands? = nil

    /// The instruction's encoded length in bytes, derived from the space-separated
    /// hex `bytes` text (e.g. "ff 83 00 d1" → 4). Always >= 1 so a row that lost its
    /// byte text (or carries none) still advances coverage by a byte rather than
    /// stalling a span walk. Used to compute the next-unexplored gap boundary.
    var byteWidth: UInt64 {
        let tokens = bytes.split(separator: " ").filter { !$0.isEmpty }
        return UInt64(max(tokens.count, 1))
    }
}

struct XRef: Identifiable, Hashable, Codable {
    let id: UUID
    var from: UInt64
    var to: UInt64
    var kind: String
}

/// The `XRef.kind` strings. Kept as raw strings (not an enum) because the SQLite
/// `kind TEXT` column and the `.mscope` manifest round-trip the value verbatim, so
/// new kinds need no migration; this namespace just stops the literals from
/// drifting across the produce/consume sites.
enum XRefKind {
    /// A `bl` direct call (the original, pre-existing kind).
    static let call = "call"
    /// A reference to a `__cstring`/literal string address.
    static let string = "string"
    /// A reference to an `__objc_selrefs` selector slot.
    static let selref = "selref"
    /// RX-02a: a reference to an `__objc_classrefs` class slot (`[Widget new]`, `Widget.class`).
    /// Added without a migration: older DB rows and packages simply carry no rows of this kind.
    static let classref = "classref"
    /// A reference to a global/literal in a data section (`__data`/`__const`/`__got`/…).
    static let data = "data"
}

struct ControlFlowEdge: Identifiable, Hashable, Codable {
    let id: UUID
    var from: UInt64
    var to: UInt64
    var kind: String
}

/// The user-authored presentation values the focused graph may apply at one image-local
/// address. Keeping this separate from `AddressOverride` prevents graph consumers from gaining
/// access to unrelated authoring state or reaching back into a workspace snapshot while laying
/// out one frozen projection.
struct GraphAddressPresentation: Equatable, Sendable {
    var customName: String?
    var tag: String?
    var colorTag: ColorTag?
}

/// One image's complete, transient graph input. The aggregate deliberately owns no workspace or
/// store reference: both the live canvas and PDF renderer can consume it without consulting flat
/// primary-image compatibility projections.
struct FocusedGraphProjection: Equatable, Sendable {
    var imageSlot: ImageSlot
    /// Binary generation that owned this rendered projection. A nil owner is reserved for
    /// binary-less compatibility fixtures; loaded images always carry their durable UUID.
    var ownerBinaryID: UUID? = nil
    var functions: [FunctionSummary]
    var basicBlocks: [BasicBlockSummary]
    var instructions: [InstructionRow]
    var controlFlowEdges: [ControlFlowEdge]
    var xrefs: [XRef]
    var presentationByAddress: [UInt64: GraphAddressPresentation]

    /// The conservative half-open range for the instruction-only graph fallback. The last row's
    /// real encoded width is the only evidence for the end; a wrapped or otherwise invalid end
    /// abstains so a sparse graph cannot manufacture an address range.
    var sparseInstructionRange: Range<UInt64>? {
        guard functions.isEmpty, basicBlocks.isEmpty,
              let first = instructions.first,
              let last = instructions.last
        else { return nil }

        let (end, overflow) = last.address.addingReportingOverflow(last.byteWidth)
        guard !overflow, end > first.address else { return nil }
        return first.address..<end
    }
}

/// Frozen identity for a rendered graph edge. `elementID` retains the image-local CFG/xref
/// identity while `id` supplies the slot-qualified SwiftUI identity used across a workspace.
struct GraphEdgeSelectionTarget: Identifiable, Hashable, Sendable {
    var imageSlot: ImageSlot
    var ownerBinaryID: UUID? = nil
    var elementID: String
    var fromAddress: UInt64
    var toAddress: UInt64
    var kind: String

    var id: String { "image:\(imageSlot.rawValue):\(elementID)" }
}

/// WS-6: a resolved reference that crosses an image boundary — a call/data site in one loaded
/// image whose target is a symbol EXPORTED by another loaded image, joined by verbatim symbol
/// name (A's import `_foo` → B's export `_foo`). Both endpoints are slot-qualified.
///
/// This is a SNAPSHOT-LEVEL, TRANSIENT product: it is re-derived on workspace restore and on any
/// image-set change (see `WorkspaceStore.recomputeCrossImageXrefs()`), and is NEVER persisted to
/// the DB or `.mscope`. A single-image workspace keeps an empty collection and stays byte-identical
/// on disk. Kept out of `ImageAnalysis` (whose `XRef` set is intra-image by construction) so the
/// per-image xref/golden/byte-identity paths are untouched.
struct CrossImageXRef: Identifiable, Hashable, Codable {
    let id: UUID
    var fromSlot: ImageSlot
    var from: UInt64
    var toSlot: ImageSlot
    var to: UInt64
    var symbol: String
    /// One of `XRefKind` (`.call` for `__stubs` sites, `.data` for `__got`/data sites).
    var kind: String
}

/// A USER-authored cross-reference edit on the analysis seam — either an ADDED xref
/// the recovery missed, or a SUPPRESSION of a spurious recovered one. Workspace-scoped
/// (not address-keyed like `AddressOverride`), persisted in its own `manual_xrefs`
/// table and `.mscope` array, and merged into / filtered out of the snapshot xref set
/// at query time (`effectiveXRefs()`), so it survives save/reload and re-analysis.
///
/// A suppression matches a recovered xref by its `(from, to, kind)` ENDPOINTS — the
/// recovered xref's volatile `UUID` is regenerated on every re-analysis, so matching on
/// the id would silently stop suppressing. An added xref carries the same endpoint
/// triple, materialized into the query result as a real `XRef`.
struct ManualXRef: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var from: UInt64
    var to: UInt64
    var kind: String
    /// When true this entry SUPPRESSES the recovered xref with the matching
    /// `(from, to, kind)`; when false it ADDS one.
    var isSuppression: Bool
    /// The image BOTH endpoints live in (manual xrefs are same-image this wave;
    /// cross-image edges are a later feature). Encoded only when non-primary so
    /// legacy rows stay byte-identical; absent decodes to `.primary`. Matching
    /// against recovered xrefs stays the id-independent `(from, to, kind)` triple
    /// WITHIN the slot — `effectiveXRefs(in:)` filters by slot first, preserving
    /// the survivability property the endpoint key exists for.
    var imageSlot: ImageSlot

    init(id: UUID = UUID(), from: UInt64, to: UInt64, kind: String, isSuppression: Bool,
         imageSlot: ImageSlot = .primary) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.isSuppression = isSuppression
        self.imageSlot = imageSlot
    }

    private enum CodingKeys: String, CodingKey { case id, from, to, kind, isSuppression, imageSlot }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        from = try container.decode(UInt64.self, forKey: .from)
        to = try container.decode(UInt64.self, forKey: .to)
        kind = try container.decode(String.self, forKey: .kind)
        isSuppression = try container.decode(Bool.self, forKey: .isSuppression)
        imageSlot = try container.decodeIfPresent(ImageSlot.self, forKey: .imageSlot) ?? .primary
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(kind, forKey: .kind)
        try container.encode(isSuppression, forKey: .isSuppression)
        if imageSlot != .primary { try container.encode(imageSlot, forKey: .imageSlot) }
    }

    /// The endpoint triple a suppression matches a recovered xref on (id-independent).
    var endpointKey: XRefEndpointKey { XRefEndpointKey(from: from, to: to, kind: kind) }
}

/// The id-independent identity of an xref edge: its `(from, to, kind)` endpoints. Used
/// to match a user SUPPRESSION against a recovered xref (whose UUID is regenerated on
/// every re-analysis) and to dedupe an ADD against an already-present recovered xref.
struct XRefEndpointKey: Hashable {
    var from: UInt64
    var to: UInt64
    var kind: String
}

/// A user-named navigation BOOKMARK at an address. Workspace-scoped, persisted in its
/// own `bookmarks` table and `.mscope` array. Surfaced in a Bookmarks list / menu and
/// the scripting API; navigable. A bookmark with an empty name is a bare marker (the
/// address shows in its place).
struct Bookmark: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var address: UInt64
    /// The image the bookmarked address belongs to. Encoded only when non-primary so
    /// legacy packages/rows stay byte-identical; absent decodes to `.primary`.
    var imageSlot: ImageSlot
    var name: String

    init(id: UUID = UUID(), address: UInt64, imageSlot: ImageSlot = .primary, name: String) {
        self.id = id
        self.address = address
        self.imageSlot = imageSlot
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case id, address, imageSlot, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        address = try container.decode(UInt64.self, forKey: .address)
        imageSlot = try container.decodeIfPresent(ImageSlot.self, forKey: .imageSlot) ?? .primary
        name = try container.decode(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(address, forKey: .address)
        if imageSlot != .primary { try container.encode(imageSlot, forKey: .imageSlot) }
        try container.encode(name, forKey: .name)
    }
}

/// A user-authored override on a SEGMENT/SECTION's DISPLAY (not its on-disk bytes):
/// a renamed display name and/or a REBASE delta that shifts the section's displayed
/// addresses by a signed offset. Workspace-scoped (not address-keyed), persisted in its
/// own `segment_overrides` table and `.mscope` array, and applied at query/display time
/// via `effectiveSections()` — the underlying analysis (`sections`, instructions, xrefs)
/// is NEVER mutated, so a rebase only changes how addresses are PRESENTED.
///
/// Keyed by the section's ORIGINAL name (the analysis-invariant identity), exactly as a
/// `ManualXRef` keys on endpoints rather than the volatile `SectionSummary.id` UUID, which
/// is regenerated on every re-analysis. Matching on the id would silently stop applying
/// the override after a mark-as-code/data re-flow; the original name survives it.
struct SegmentOverride: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    /// The ORIGINAL section name this override targets (e.g. "__TEXT,__text"). The stable
    /// key — matched against `SectionSummary.name`, which re-analysis reproduces verbatim.
    /// Section names repeat across images (every Mach-O has a __TEXT,__text), so the full
    /// key is `(imageSlot, originalName)`.
    var originalName: String
    /// The image whose section this override targets. Encoded only when non-primary so
    /// legacy rows stay byte-identical; absent decodes to `.primary`.
    var imageSlot: ImageSlot
    /// The user's replacement DISPLAY name. nil/empty keeps the original name.
    var displayName: String?
    /// A signed byte delta added to the section's displayed base address (and to every
    /// displayed address that falls inside the section). 0 = no rebase. Applied with
    /// two's-complement wraparound so a negative delta shifts addresses down safely.
    var rebaseDelta: Int64

    init(id: UUID = UUID(), originalName: String, imageSlot: ImageSlot = .primary,
         displayName: String? = nil, rebaseDelta: Int64 = 0) {
        self.id = id
        self.originalName = originalName
        self.imageSlot = imageSlot
        self.displayName = displayName
        self.rebaseDelta = rebaseDelta
    }

    private enum CodingKeys: String, CodingKey { case id, originalName, imageSlot, displayName, rebaseDelta }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalName = try container.decode(String.self, forKey: .originalName)
        imageSlot = try container.decodeIfPresent(ImageSlot.self, forKey: .imageSlot) ?? .primary
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        rebaseDelta = try container.decode(Int64.self, forKey: .rebaseDelta)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(originalName, forKey: .originalName)
        if imageSlot != .primary { try container.encode(imageSlot, forKey: .imageSlot) }
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(rebaseDelta, forKey: .rebaseDelta)
    }

    /// True when the override carries no signal (no rename and no rebase) so it can be
    /// pruned like any other cleared override, matching `AddressOverride.isEmpty`.
    var isEmpty: Bool {
        (displayName?.isEmpty ?? true) && rebaseDelta == 0
    }

    /// The display name to show for a section carrying this override: the user's
    /// replacement when set and non-empty, else the supplied original name.
    func resolvedName(default originalName: String) -> String {
        guard let displayName, !displayName.isEmpty else { return originalName }
        return displayName
    }

    /// Shifts a virtual address by this override's rebase delta, two's-complement
    /// wraparound-safe so a negative delta near 0 (or a positive one near `UInt64.max`)
    /// never traps. A zero delta returns the address unchanged.
    func rebased(_ address: UInt64) -> UInt64 {
        guard rebaseDelta != 0 else { return address }
        return address &+ UInt64(bitPattern: rebaseDelta)
    }
}

struct SidebarItem: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String?
    var systemImage: String
    /// User tag for the item's address, shown as a trailing chip.
    var tag: String?
    /// User highlight color for the item's address, shown as a leading dot.
    var colorTag: ColorTag?

    var isSectionHeader: Bool {
        id.hasPrefix("section:")
    }
}

/// A fixed palette of highlight colors a user can apply to an address. Pure model
/// (no SwiftUI) with a stable `rawValue` for persistence; the view layer maps each
/// case to a concrete `Color`. Decoding an unknown raw value from SQLite is lenient
/// (`init(rawValue:)` returns nil), so a future palette entry degrades to "no color"
/// rather than corrupting the load.
enum ColorTag: String, Codable, CaseIterable, Equatable, Identifiable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var id: String { rawValue }

    /// Human-facing label, e.g. "Red".
    var displayName: String { rawValue.capitalized }
}

/// A user-chosen display format for an instruction's immediate operand (the
/// `Format Operand` capability): re-render the first `#`-prefixed immediate as
/// hexadecimal, decimal, or a character literal. Keyed by address on the override
/// seam; the default (no override) keeps the decoder's rendering.
public enum OperandFormat: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    // NOTE: the raw values `hex`/`decimal`/`character` are persisted (operand_format
    // column) and exposed through the scripting `setOperandFormat` command, so they
    // MUST stay stable. `decimal` is the legacy *signed* (sign-preserving) decimal —
    // it keeps an explicit `#-16` as `-16` and renders an unsigned mask as its full
    // unsigned magnitude. The matrix-completion cases below are additive.
    case hex
    case decimal
    case character
    /// Always-unsigned decimal: the magnitude is printed verbatim, an explicit
    /// negative is reinterpreted as its two's-complement unsigned value (width-aware).
    case unsignedDecimal
    /// Octal (`0o…`), unsigned magnitude with a preserved sign.
    case octal
    /// Binary (`0b…`), unsigned magnitude with a preserved sign.
    case binary
    /// Two's-complement *signed* hex: an unsigned magnitude whose top bit is set
    /// renders as a negative `#-0x…` value (the signed reading of the bit pattern).
    case negativeHex

    public var id: String { rawValue }

    /// Human-facing label, e.g. "Hexadecimal".
    public var displayName: String {
        switch self {
        case .hex: return "Hexadecimal"
        case .decimal: return "Signed Decimal"
        case .character: return "Character"
        case .unsignedDecimal: return "Unsigned Decimal"
        case .octal: return "Octal"
        case .binary: return "Binary"
        case .negativeHex: return "Two's-Complement Hex"
        }
    }

    /// Re-renders the first `#`-prefixed integer immediate in `operands` in this
    /// format. Operands without an integer immediate (none, an unparseable one, or a
    /// fractional FP immediate like `#1.0`) pass through unchanged, so applying a
    /// format is always safe regardless of the instruction.
    public static func apply(to operands: String, format: OperandFormat) -> String {
        guard let range = immediateRange(in: operands),
              let value = parseImmediate(operands[range]) else { return operands }
        return operands.replacingCharacters(in: range, with: format.render(negative: value.negative, magnitude: value.magnitude))
    }

    /// Renders a parsed immediate (sign + magnitude) as a disassembly operand token.
    /// Numeric forms carry the leading `#` immediate marker; a printable `character`
    /// renders as a bare `'c'` literal (matching assembler syntax, no `#`). The
    /// magnitude is a full `UInt64` so 64-bit values with the high bit set (logical
    /// masks, high `movz`) reformat rather than silently passing through.
    public func render(negative: Bool, magnitude: UInt64) -> String {
        // The character literal is the one form that is not a `#`-prefixed immediate.
        if case .character = self,
           !negative, magnitude >= 0x20, magnitude <= 0x7E {
            return renderValue(negative: negative, magnitude: magnitude)
        }
        return "#" + renderValue(negative: negative, magnitude: magnitude)
    }

    /// Renders a parsed immediate (sign + magnitude) in this format as a bare value
    /// (no `#`). This is the pure formatter reused by both the operand-format override
    /// (which prepends `#`) and the Make-Array per-element display formatter (which
    /// emits raw element values). Edge values — 0, the unsigned max, and negatives —
    /// all render deterministically here.
    public func renderValue(negative: Bool, magnitude: UInt64) -> String {
        switch self {
        case .hex:
            return (negative ? "-0x" : "0x") + String(magnitude, radix: 16)
        case .decimal:
            return negative ? "-\(magnitude)" : "\(magnitude)"
        case .unsignedDecimal:
            // Reinterpret an explicit negative as its two's-complement unsigned value
            // so the result is always non-negative.
            return "\(unsignedBitPattern(negative: negative, magnitude: magnitude))"
        case .octal:
            return (negative ? "-0o" : "0o") + String(magnitude, radix: 8)
        case .binary:
            return (negative ? "-0b" : "0b") + String(magnitude, radix: 2)
        case .negativeHex:
            // Signed reading of the bit pattern: a top-bit-set magnitude (or an
            // explicit negative) prints as the negative of its absolute value.
            let bits = unsignedBitPattern(negative: negative, magnitude: magnitude)
            if bits > UInt64(Int64.max) {
                // Negative when interpreted as Int64: -(2^64 - bits).
                let absValue = (~bits) &+ 1 // two's-complement magnitude, overflow-safe
                return "-0x" + String(absValue, radix: 16)
            }
            return "0x" + String(bits, radix: 16)
        case .character:
            if !negative, magnitude >= 0x20, magnitude <= 0x7E, let scalar = Unicode.Scalar(UInt32(magnitude)) {
                let character = Character(scalar)
                if character == "'" { return "'\\''" }
                if character == "\\" { return "'\\\\'" }
                return "'\(character)'"
            }
            // Non-printable values have no sensible character form: fall back to hex.
            return (negative ? "-0x" : "0x") + String(magnitude, radix: 16)
        }
    }

    /// The unsigned 64-bit bit pattern of a parsed (sign, magnitude) immediate: the
    /// magnitude verbatim when non-negative, else its two's-complement negation.
    private func unsignedBitPattern(negative: Bool, magnitude: UInt64) -> UInt64 {
        negative ? (~magnitude) &+ 1 : magnitude
    }

    /// The string range of the first `#`-prefixed integer immediate token (`#`,
    /// optional sign, optional `0x`, hex/decimal digits), or nil when there is none
    /// — including a fractional FP immediate (`#1.0`), which is left untouched so it
    /// is never mangled into a garbage `#0x1.0`.
    private static func immediateRange(in operands: String) -> Range<String.Index>? {
        guard let hash = operands.firstIndex(of: "#") else { return nil }
        var end = operands.index(after: hash)
        if end < operands.endIndex, operands[end] == "-" { end = operands.index(after: end) }
        var sawDigit = false
        while end < operands.endIndex {
            let character = operands[end]
            if character.isHexDigit {
                sawDigit = true
                end = operands.index(after: end)
            } else if character == "x" || character == "X" {
                end = operands.index(after: end)
            } else {
                break
            }
        }
        // A trailing '.' means this is a fractional FP immediate, not an integer:
        // pass the whole operand through unchanged rather than reformat its head.
        if end < operands.endIndex, operands[end] == "." { return nil }
        return sawDigit ? hash..<end : nil
    }

    /// Parses a `#`-prefixed immediate token into sign + magnitude (hex `0x…` or
    /// decimal). The magnitude is `UInt64` so unsigned values above `Int64.max`
    /// parse rather than failing.
    private static func parseImmediate(_ token: Substring) -> (negative: Bool, magnitude: UInt64)? {
        guard token.first == "#" else { return nil }
        var body = token.dropFirst()
        var negative = false
        if body.first == "-" { negative = true; body = body.dropFirst() }
        let magnitude: UInt64?
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            magnitude = UInt64(body.dropFirst(2), radix: 16)
        } else {
            magnitude = UInt64(body)
        }
        return magnitude.map { (negative, $0) }
    }
}

/// Structural-invariant violations for `WorkspaceSnapshot.validateInvariants()`.
enum WorkspaceSnapshotInvariantError: Error, Equatable {
    /// Two images share the same durable slot.
    case duplicateSlot(ImageSlot)
    /// An analysis bucket has no owning binary (and is not the tolerated binary-less `.primary`).
    case orphanAnalysis(ImageSlot)
}

/// The complete transient input for one pseudocode rendering pass. Every image-local
/// value comes from `imageSlot`; only `types` is intentionally workspace-global.
struct PseudocodeRenderInput: Equatable, Sendable {
    var imageSlot: ImageSlot
    var functionName: String
    var startAddress: UInt64?
    var jumpTables: [UInt64: [UInt64]]
    var objcSelectors: [UInt64: String]
    /// HOP-5c: the image's stored constant-string map (`ImageAnalysis.constantStrings`), shared
    /// storage, so carrying it here is free; pass it to `PseudocodePrinter.print(constantStrings:)`.
    var constantStrings: [UInt64: MacIRConstantString] = [:]
    var nameOverrides: [String: String]
    var signatureOverrides: [UInt64: FunctionSignatureOverride]
    var authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:]
    var directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:]
    var machineCallUsage: MacIRMachineCallUsage? = nil
    var machineUsageContext: MacIRMachineUsageContext? = nil
    /// Same-image direct call instruction identities from the completed image report.
    /// Presentation eligibility only; this is not a void return contract.
    var ownDirectCallAddresses: Set<UInt64> = []
    var registerNameOverrides: [String: String]
    /// DP04 C1: stack local names/types for this procedure (authoring key → edit).
    var stackLocalOverrides: [String: StackLocalOverride] = [:]
    var types: [TypeDefinition]
    var instructions: [InstructionRow]
    /// Function-local indirect-call slot resolutions for this procedure, by call address.
    var resolvedIndirectCalls: [UInt64: PseudocodeIndirectCall] = [:]
    /// Proof-validated header slot contracts keyed by the original call instruction.
    var slotCallContracts: [UInt64: FunctionPointerSignatureV1] = [:]
    /// Complete image-wide caller evidence; nil keeps the function-local fallback.
    var callerReturnWidth: MacIRCallerReturnEvidence.Width?
    /// Return-only evidence does not replace the authored or recovered parameter plan.
    var callerReturnType: String? = nil
    /// Exact function identities, never inferred from a branch target spelling.
    var knownTailCallTargets: [UInt64: String] = [:]
    /// Fill only missing return authority from a completed, positively proven
    /// table entry. The feature flag is explicit so off/absent inputs stay intact.
    mutating func admitReturnContract(_ contract: ReturnContract, enabled: Bool) {
        guard enabled, let startAddress, let tier = contract.tier,
              signatureOverrides[startAddress] == nil,
              callerReturnType == nil,
              CallSignatureCatalog.standard.signature(for: functionName) == nil else { return }
        let declared = contract.evidence.contains {
            [.header, .catalog, .slotSignature].contains($0.source)
        }
        switch contract.kind {
        case .void:
            let proof = tier == .header && declared
                || tier == .derived && contract.evidence.contains { $0.source == .tailCall }
                || tier == .closedWorld && contract.evidence.contains { $0.source == .discard }
            guard proof, callerReturnWidth == nil else { return }
            callerReturnType = "void"
        case let .value(.gpr(width, type)):
            let proof = tier == .header && declared
                || tier == .derived
                    && contract.evidence.contains { $0.source == .consumer }
                    && contract.evidence.contains { $0.source == .producer }
            guard proof, width == 32 || width == 64 else { return }
            let admitted: MacIRCallerReturnEvidence.Width = width == 32 ? .w0 : .x0
            guard callerReturnWidth == nil || callerReturnWidth == admitted else { return }
            // Width-only caller evidence can admit a later FP scratch value in
            // the legacy builder. Require a real type that binds this exact GPR
            // carrier; a missing type stays unresolved rather than being invented.
            guard let type else { return }
            let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog:
                Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
            guard case let .single(.gpr(index, carrierWidth)) =
                DarwinARM64ParameterBinder.returnLocation(for: type, resolver: resolver),
                index == 0, carrierWidth == width else { return }
            callerReturnType = type
            callerReturnWidth = admitted
        case .unresolved, .noReturn, .value:
            return
        }
    }
}

/// The per-image derived analysis products for ONE binary image. Owned by
/// `WorkspaceSnapshot.analysisBySlot` keyed by the image's durable `ImageSlot`. DERIVED-ONLY —
/// it never stores a `BinaryImage` (identity lives solely in `WorkspaceSnapshot.binaries`), so a
/// single slot value is the only join between an image's identity and its analysis.
///
/// Every field defaults empty/nil so a reloaded snapshot (which has authoring but not-yet-recomputed
/// derived data) is representable, and so the package/DB reload paths stay byte-identical — exactly
/// the invariants the flat fields held before this refactor.
struct ImageAnalysis: Sendable {
    var functions: [FunctionSummary] = []
    var symbols: [SymbolSummary] = []
    var imports: [ImportSummary] = []
    var indirectSymbols: [IndirectSymbolSummary] = []
    var exports: [ExportSummary] = []
    var stringLiterals: [StringLiteralSummary] = []
    var basicBlocks: [BasicBlockSummary] = []
    var instructions: [InstructionRow] = [] {
        didSet {
            instructionFingerprintMemo = AnalysisFacetDigestMemo()
            exportInstructionMemo = ExportInstructionMemo()
        }
    }
    var exportInstructionMemo = ExportInstructionMemo()
    var instructionFingerprintMemo = AnalysisFacetDigestMemo()
    var controlFlowFingerprintMemo = AnalysisFacetDigestMemo()
    var xrefs: [XRef] = [] { didSet { typeCatalog = nil } }
    var controlFlowEdges: [ControlFlowEdge] = [] { didSet { controlFlowFingerprintMemo = AnalysisFacetDigestMemo() } }
    /// The fixed-size hex-view window (a bounded PREFIX of the selected slice), NOT the source of
    /// truth for the image's bytes — that is `imageBytes`, which is what gets persisted.
    var hexBytes: Data = Data()
    /// Resolved jump-table case targets keyed by the dispatching `br` address. Derived (never
    /// persisted): empty after a reload → the `br` stays opaque (conservative pre-existing behavior).
    var jumpTables: [UInt64: [UInt64]] = [:]
    /// Resolved Objective-C selector names keyed by the `__objc_selrefs` slot virtual address.
    /// Derived (never persisted): empty after a reload, mirroring `jumpTables`.
    var objcSelectors: [UInt64: String] = [:] { didSet { typeCatalog = nil } }
    /// HOP-5c: the decompiler's once-per-image constant-string map (C-string literals by address,
    /// plus `__cfstring` objects by object address), built by `ImageConstantStringProvider` when the
    /// image is analysed, rehydrated, or decoded from a worker reply. Renderers read it; none rebuild
    /// it. The CFString subset is persisted; C strings rebuild once from persisted literals on reopen.
    var constantStrings: [UInt64: MacIRConstantString] = [:]
    /// Objective-C classes from `__objc_classlist` — source for "Export Objective-C Header". Derived.
    var objcClasses: [ObjCClass] = [] { didSet { typeCatalog = nil } }
    /// Objective-C categories from `__objc_catlist`. Derived, mirroring `objcClasses`.
    var objcCategories: [ObjCCategory] = [] { didSet { typeCatalog = nil } }
    var objcProtocols: [ObjCProtocol] = [] { didSet { typeCatalog = nil } }
    /// Swift nominal types from `__swift5_types`/`__swift5_fieldmd` — source for "Export Swift
    /// Interface". Derived.
    var swiftTypes: [SwiftTypeDescriptor] = [] { didSet { typeCatalog = nil } }
    /// In-image Swift protocol conformances from `__swift5_proto`. Derived.
    var swiftConformances: [SwiftConformance] = [] { didSet { typeCatalog = nil } }
    /// The image's segments/sections (loader `BinarySection` projected to the model). Derived/
    /// never-persisted: populated on a fresh analysis, empty after a package reload.
    var sections: [SectionSummary] = []
    /// Loader-declared inline-data ranges within otherwise executable code. Derived/
    /// never-persisted, rebuilt from Mach-O `LC_DATA_IN_CODE` when bytes are available.
    var codeDataRanges: [CodeDataRangeSummary] = [] {
        didSet { exportInstructionMemo = ExportInstructionMemo() }
    }

    func exportInstructionIndex() -> ExportInstructionIndex {
        exportInstructionMemo.index(instructions: instructions, dataRanges: codeDataRanges)
    }
    /// Format-neutral relocations projected from the loader (ELF/Mach-O). Derived/never-persisted.
    var relocations: [RelocationSummary] = []
    /// Artifact-bound proof that raw selected-slice bytes are effective bytes for complete
    /// non-writable executable ranges. Derived/never-persisted; absence means no authority.
    var identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation] = []
    /// DWARF line-table rows from a matched dSYM (File ▸ Read Debug Symbols), address-sorted.
    /// Empty until a dSYM is imported; queried per-address via `sourceLine(at:)`.
    var sourceLines: [SourceLineEntry] = []
    /// The selected slice's full bytes (slice file offset → EOF). `SectionSummary.fileOffset` is
    /// slice-relative and indexes directly into this — the backing store for byte-level reads.
    /// Derived/never-persisted; separate from `hexBytes`, which stays a small fixed hex-view window.
    var imageBytes: Data = Data()
    /// Analysis-level diagnostics (unresolved branches, undecoded code, dangling xrefs, loader
    /// truncations) surfaced in the Problems panel. DERIVED — recomputed on every analysis, not
    /// persisted, so empty after a reload until re-analysis.
    var diagnostics: [AnalysisDiagnostic] = []
    /// Mach-O load metadata (code signature/entitlements, imported symbols, dependent dylibs)
    /// projected from the parsed `MachOFile`. DERIVED — nil for non-Mach-O formats and after a reload.
    var machOMetadata: MachOLoadMetadata? = nil
    /// Deterministic provenance of the exact analysis input and derived facets that produced this
    /// image analysis. Rebuilt on fresh analysis, carried across the worker boundary, and persisted
    /// with saved analysis records when present so Phase 2 freshness checks survive save/reload.
    var analysisInputFingerprint: AnalysisInputFingerprint? = nil
    /// RX-02a: `__objc_classrefs` slot → the class it names. Derived (never persisted), mirroring
    /// `objcSelectors`; maps `classref` xrefs to classes in the Type Atlas.
    var objcClassReferences: [UInt64: ObjCClassReferenceTarget] = [:] { didSet { typeCatalog = nil } }
    /// RX-02a: the image part of the Type Atlas, built once when the image is analysed, rehydrated
    /// or decoded (like `constantStrings`) and read through `WorkspaceSnapshot.typeCatalog(in:)`.
    /// Derived, never persisted. Any change to an input field above clears it; the accessor then
    /// projects on demand. Set it with `refreshTypeCatalog()`.
    var typeCatalog: ImageTypeCatalog? = nil

    /// Rebuilds the stored Type Atlas image part from the current fields.
    mutating func refreshTypeCatalog() {
        typeCatalog = ImageTypeCatalogBuilder.build(analysis: self)
    }
}

/// Durable authored expressions only. No runtime result or debugger coordinate belongs here.
struct WorkspaceSavedWatchDefinition: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let expression: String

    init(id: UUID, expression: String) throws {
        guard !expression.isEmpty,
              expression == expression.trimmingCharacters(in: .whitespacesAndNewlines),
              expression.utf8.count <= 1_024,
              !expression.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        self.id = id
        self.expression = expression
    }

    private enum CodingKeys: String, CodingKey { case id, expression }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      expression: container.decode(String.self, forKey: .expression))
    }
}

enum WorkspaceSavedWatchValidationError: Error { case invalid }

struct WorkspaceSavedWatchCatalog: Codable, Equatable, Sendable {
    static let empty = WorkspaceSavedWatchCatalog()
    let version: Int
    let definitions: [WorkspaceSavedWatchDefinition]

    private init() { version = 1; definitions = [] }
    init(definitions: [WorkspaceSavedWatchDefinition]) throws {
        guard definitions.count <= 16, Set(definitions.map(\.id)).count == definitions.count else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        self.version = 1
        self.definitions = definitions
    }

    private enum CodingKeys: String, CodingKey { case version, definitions }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        try self.init(definitions: container.decode([WorkspaceSavedWatchDefinition].self,
                                                   forKey: .definitions))
    }

    func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 32_768 else { throw WorkspaceSavedWatchValidationError.invalid }
        return bytes
    }

    static func decodeCanonicalBytes(_ bytes: Data) throws -> Self {
        guard bytes.count <= 32_768 else { throw WorkspaceSavedWatchValidationError.invalid }
        let catalog = try JSONDecoder().decode(Self.self, from: bytes)
        // Reject unknown/duplicate fields, noncanonical values and lossy runtime payloads.
        guard try catalog.canonicalBytes() == bytes else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        return catalog
    }
}

extension UInt64 {
    var hexAddress: String {
        "0x" + String(self, radix: 16, uppercase: false).leftPadded(to: 16, with: "0")
    }
}

extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        if count >= length { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}

/// Derived, immutable index shared only while an ImageAnalysis's row/range values are unchanged.
/// Mutation replaces the memo, so copies of a snapshot retain their own original index.
final class ExportInstructionMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: ExportInstructionIndex?

    func index(instructions: [InstructionRow], dataRanges: [CodeDataRangeSummary]) -> ExportInstructionIndex {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let index = ExportInstructionIndex(instructions: instructions, dataRanges: dataRanges)
        cached = index
        return index
    }
}

struct ExportInstructionIndex: Sendable {
    private let instructions: [InstructionRow]
    private let offsetsByAddress: [Int]
    let loaderExcludedAddresses: Set<UInt64>

    init(instructions: [InstructionRow], dataRanges: [CodeDataRangeSummary]) {
        self.instructions = instructions
        offsetsByAddress = instructions.indices.sorted {
            let left = instructions[$0].address, right = instructions[$1].address
            return left == right ? $0 < $1 : left < right
        }
        var excluded = Set<UInt64>()
        // Resolve loader exclusions once, using the same half-open/overflow semantics.
        for range in dataRanges {
            guard let end = range.endAddress else { continue }
            let lower = Self.lowerBound(range.address, instructions: instructions, offsets: offsetsByAddress)
            let upper = Self.lowerBound(end, instructions: instructions, offsets: offsetsByAddress)
            for offset in offsetsByAddress[lower..<upper] { excluded.insert(instructions[offset].address) }
        }
        loaderExcludedAddresses = excluded
    }

    /// O(log n + k), including original-order restoration for unsorted input and duplicates.
    func instructions(start: UInt64, end: UInt64) -> [InstructionRow] {
        let lower = Self.lowerBound(start, instructions: instructions, offsets: offsetsByAddress)
        let upper: Int
        if end > start {
            upper = Self.lowerBound(end, instructions: instructions, offsets: offsetsByAddress)
        } else if start < UInt64.max {
            upper = Self.lowerBound(start + 1, instructions: instructions, offsets: offsetsByAddress)
        } else {
            upper = offsetsByAddress.count
        }
        var offsets = Array(offsetsByAddress[lower..<upper])
        // Usually rows are already address-sorted. Fixed-width radix ordering keeps the
        // shuffled-input case linear in k as well, without sorting or scanning all n rows.
        if zip(offsets, offsets.dropFirst()).contains(where: { $0 > $1 }) {
            var scratch = offsets
            for shift in stride(from: 0, to: Int.bitWidth, by: 8) {
                var counts = [Int](repeating: 0, count: 256)
                for offset in offsets { counts[(offset >> shift) & 255] += 1 }
                var position = 0
                for bucket in counts.indices {
                    let count = counts[bucket]
                    counts[bucket] = position
                    position += count
                }
                for offset in offsets {
                    let bucket = (offset >> shift) & 255
                    scratch[counts[bucket]] = offset
                    counts[bucket] += 1
                }
                swap(&offsets, &scratch)
            }
        }
        return offsets.map { instructions[$0] }
    }

    private static func lowerBound(_ address: UInt64, instructions: [InstructionRow], offsets: [Int]) -> Int {
        var low = 0, high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if instructions[offsets[middle]].address < address { low = middle + 1 }
            else { high = middle }
        }
        return low
    }
}

/// The authoring-aware exclusion set is computed once per workspace snapshot and image.
final class ExportCodeExclusionMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [ImageSlot: Set<UInt64>] = [:]

    func addresses(in slot: ImageSlot, build: () -> Set<UInt64>) -> Set<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached[slot] { return cached }
        let addresses = build()
        cached[slot] = addresses
        return addresses
    }
}

/// Snapshot-owned image reports. Claim ownership before prerequisites, then lock the report build
/// and publication. Read-only consumers fall back locally; interrupted attempts never retry.
final class IndirectCallResolutionMemo: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let snapshotID: UUID
        let slot: ImageSlot
    }

    enum CheckpointPhase: Equatable, Sendable {
        case typedPrototypePrerequisite
    }

    /// Identifies prerequisite checkpoints without depending on preparation visit counts.
    @TaskLocal static var checkpointPhase: CheckpointPhase?

    private let lock = NSLock()
    private var attempted: Set<Key> = []
    struct ImageReport: Sendable {
        let indirectCalls: MacIRIndirectTargetResolution.Report
        var callerReturns: [UInt64: MacIRCallerReturnEvidence.Width] = [:]
        var slotReturns: MacIRSlotReturnAuthority.Report? = nil
        var returnContracts: ReturnContractTable? = nil
        var ownDirectCallAddresses: Set<UInt64> = []
        var ownCalleeReturns: MacIROwnCalleeReturnEvidence.Report? = nil
    }

    private var cached: [Key: ImageReport] = [:]

    func beginAttempt(for key: Key) -> Bool {
        lock.withLock { attempted.insert(key).inserted }
    }

    func report(for key: Key) -> MacIRIndirectTargetResolution.Report? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return cached[key]?.indirectCalls
    }

    func returnContractTable(for key: Key) -> ReturnContractTable? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return cached[key]?.returnContracts
    }

    func callerReturnWidth(for key: Key, at start: UInt64) -> MacIRCallerReturnEvidence.Width? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return cached[key]?.callerReturns[start]
    }

    func report(for key: Key, build: () -> MacIRIndirectTargetResolution.Report?) -> MacIRIndirectTargetResolution.Report? {
        imageReport(for: key) { build().map { ImageReport(indirectCalls: $0) } }?.indirectCalls
    }

    func imageReport(for key: Key, build: () -> ImageReport?) -> ImageReport? {
        guard beginAttempt(for: key) else {
            guard !Task.isCancelled, lock.try() else { return nil }
            defer { lock.unlock() }
            return cached[key]
        }
        return completeAttempt(for: key, build: build)
    }

    func completeAttempt(for key: Key, build: () -> ImageReport?) -> ImageReport? {
        lock.withLock {
            guard attempted.contains(key), !Task.isCancelled else { return nil }
            guard let report = build(), !Task.isCancelled else { return nil }
            cached[key] = report
            return report
        }
    }
}

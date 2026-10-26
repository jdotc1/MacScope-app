import Foundation

/// A format-NEUTRAL section of a loaded binary — the minimal surface the analysis
/// pipeline needs: where it lives in virtual-address space, where its bytes are in
/// the file, and whether it holds executable instructions. Mach-O `MachOSection`,
/// ELF sections, etc. each project down to this.
struct BinarySection: Hashable, Sendable {
    var name: String          // e.g. "__TEXT,__text" (Mach-O) or ".text" (ELF)
    var address: UInt64       // virtual address
    var size: UInt64          // VIRTUAL span (address-space extent)
    var fileOffset: UInt64    // byte offset within the slice (relative to sliceOffset)
    var isExecutable: Bool    // holds executable instructions (code)
    var isZeroFill: Bool = false  // BSS-type: occupies VA space but has NO file bytes (fileOffset is a placeholder)
    /// Physical (raw) byte count in the file when the format declares it separately from the
    /// virtual span (PE SizeOfRawData vs VirtualSize). nil = the format does not distinguish
    /// them; byte-mapping derivation then clamps by `size` and its other bounds.
    var fileSize: UInt64? = nil
    /// Original object-section identity for deterministic COFF analysis coordinates.
    var coffCoordinate: COFFSectionCoordinate? = nil
}

struct BinaryCodeDataRange: Hashable, Sendable {
    var address: UInt64
    var size: UInt64
    var kind: String
}

/// A format-NEUTRAL view of a loaded program image — everything the `AnalysisEngine`
/// needs to disassemble and analyze a binary, with NO Mach-O (or other format) types
/// leaking through. A `BinaryLoader` produces one of these; the engine consumes only
/// this. Symbol/import/export/string tables are carried as the already-neutral
/// summary types the snapshot uses, so a new format loader only has to fill this in.
struct LoadedBinary: Sendable {
    // Origin / display
    var name: String          // file name
    var path: String          // file system path
    var isBundle: Bool        // resolved from a .app bundle

    // Identity / architecture / metadata
    var cpuType: Int32        // architecture selector (e.g. Mach-O CPU type)
    /// Format-specific architecture subtype when the loader exposes one. Mach-O loaders project
    /// the raw `cpusubtype` value so consumers can conservatively distinguish arm64 from arm64e;
    /// nil for formats without an equivalent field. The default preserves existing loader and
    /// test construction sites.
    var cpuSubtype: Int32? = nil
    var fileTypeName: String  // e.g. "Mach-O executable"
    var architectureDisplayName: String
    var metadata: BinaryMetadataSummary
    /// Original container selection observed by the loader; never reconstructed from a request.
    var machOSelectedSliceFact: MachOSelectedSliceFact? = nil
    /// Exact selected-slice artifact evidence. Mach-O loaders populate these from the verified
    /// selected slice; non-Mach-O and synthetic loaders conservatively leave them unavailable.
    var artifactIdentity: MachOSliceArtifactIdentity? = nil
    var preferredSegmentLayout: MachOPreferredSegmentLayout? = nil
    var artifactIntegrityState: MachOSliceArtifactIntegrityState = .unavailable
    /// Fresh-import display hint only. It is not artifact identity and is never persisted.
    var resolvedExecutablePath: String? = nil
    /// Exact format-specific load choice used to construct this image. Archive member identity is
    /// never encoded into `path`; the outer container remains path/bookmark authority.
    var loadSelection: BinaryLoadSelection = .automatic

    // Byte layout
    var bytes: Data           // the full file bytes
    var sliceOffset: UInt64   // file offset of the selected slice (0 for thin/non-fat)
    /// The declared byte extent of the selected slice (a fat entry's `size`). nil means the
    /// slice runs to end of file — the correct interpretation for a thin/non-fat binary. When
    /// present, the analysis pipeline persists exactly `bytes[sliceOffset ..< sliceOffset+size]`
    /// so a universal binary's later slices and any trailing bytes are never captured.
    var sliceSize: UInt64? = nil
    var sections: [BinarySection]
    var executableTextSection: BinarySection?
    /// Loader-declared data ranges that live inside otherwise executable code sections.
    /// Mach-O projects `LC_DATA_IN_CODE` here; other formats can populate equivalent facts later.
    var codeDataRanges: [BinaryCodeDataRange] = []
    var entryPointAddress: UInt64?

    // Projected tables (already-neutral snapshot summaries)
    var symbols: [SymbolSummary]
    var imports: [ImportSummary]
    var indirectSymbols: [IndirectSymbolSummary]
    var exports: [ExportSummary]
    var stringLiterals: [StringLiteralSummary]
    var functionStarts: [UInt64]

    /// Objective-C selector-reference SLOT virtual address → resolved selector name
    /// (already filtered of unresolved/blank names). Empty for non-ObjC binaries.
    var objcSelectors: [UInt64: String]
    /// RX-02a: Objective-C class-reference SLOT virtual address (`__objc_classrefs`) → the class
    /// it names (in-image `class_t` address and/or resolved name). Empty for non-ObjC binaries;
    /// defaults to empty so the other loaders need not supply it.
    var objcClassReferences: [UInt64: ObjCClassReferenceTarget] = [:]
    /// HOP-5c: constant `CFString`/`NSConstantString` OBJECT address (`__DATA*,__cfstring`) →
    /// contents, read once at load time. Empty for non-Mach-O formats and images without
    /// `__cfstring`; defaults to empty so the other loaders need not supply it.
    var constantCFStrings: [UInt64: String] = [:]
    /// Objective-C classes recovered from `__objc_classlist` (names, superclasses, methods,
    /// ivars, properties, protocols). Empty for non-ObjC binaries / non-Mach-O formats; defaults
    /// to empty so the ELF/PE loaders need not supply it.
    var objcClasses: [ObjCClass] = []
    /// Addresses in executable text that are the target of a rebase/fixup pointer stored in
    /// data — function-pointer tables, vtables, dispatch tables. These are candidate function
    /// starts reached ONLY through an indirect (pointer) reference, which the linear
    /// function-starts pass, direct-call recovery, and prologue recovery all miss; AnalysisEngine
    /// validates + seeds them. Empty for non-Mach-O / position-dependent binaries.
    var codePointerTargets: [UInt64] = []
    /// Objective-C categories recovered from `__objc_catlist` (typically on external classes).
    /// Defaults to empty so the ELF/PE loaders need not supply it.
    var objcCategories: [ObjCCategory] = []
    var objcProtocols: [ObjCProtocol] = []

    /// Swift nominal types (class/struct/enum + stored fields) recovered from `__swift5_types` /
    /// `__swift5_fieldmd`. Empty for non-Swift binaries / non-Mach-O formats; defaults to empty so
    /// the ELF/PE loaders need not supply it.
    var swiftTypes: [SwiftTypeDescriptor] = []
    /// In-image Swift protocol conformances (`<type>: <protocol>`) from `__swift5_proto`. Defaults
    /// to empty so the ELF/PE loaders need not supply it.
    var swiftConformances: [SwiftConformance] = []

    /// Truncated / over-read structures the loader detected while parsing (e.g. a load
    /// command or table that ran past the end of the slice and was clamped). Surfaced as
    /// WARNING diagnostics in the Problems panel. Defaults empty so a loader that reports
    /// none — and every existing construction site — stays unchanged.
    var diagnosticTruncations: [LoaderDiagnosticTruncation] = []
    /// Typed per-image loader refusals (unsupported chained-fixup formats, chain stride/delta
    /// inconsistencies, ObjC metadata from a shared-cache extraction). Surfaced as WARNING rows
    /// in the Problems panel with their app-owned message. Derived, never persisted.
    var loaderFindings: [LoaderFinding] = []

    /// Mach-O load-command metadata (code signature / entitlements, imported symbols, dependent
    /// dylibs) projected from the parsed `MachOFile` at load time — surfaced in the "Signature &
    /// Dependencies" inspector. `MachOFile` is not retained past load, so this is computed here or
    /// not at all. nil for non-Mach-O formats and (being derived/never-persisted) after a package
    /// reload, exactly like `objcClasses`/`diagnosticTruncations`.
    var machOMetadata: MachOLoadMetadata? = nil
    /// Derived selected-slice loader facts for REA; never reopens or replaces image authority.
    var reaNativeImageFacts: REANativeImageFacts? = nil

    /// Format-neutral relocations projected from the loader's per-format data (ELF `.rel(a).*`,
    /// Mach-O `relocation_info`). Both were previously stranded on their format-specific parsers;
    /// surfacing them here lets the model/UI show them uniformly. Defaults empty so loaders that
    /// emit none — and every existing construction site — stay unchanged.
    var relocations: [RelocationSummary] = []

    /// Artifact- and range-bound proof that selected-slice raw bytes already equal effective bytes
    /// for complete non-writable executable ranges. Empty is the fail-closed default.
    var identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation] = []

    /// Loader-owned admission context for on-demand exception metadata analysis.
    /// Nil means the format or encryption declarations could not be established.
    var exceptionMetadataInput: BinaryExceptionMetadataInput? = nil

    /// True when this image was projected out of a dyld shared cache. Its bytes are a
    /// cache-relative projection, so the independent parser cross-check never runs on it.
    var isDyldSharedCacheProjection: Bool = false
}

struct BinaryExceptionMetadataInput: Sendable {
    let linkedMachOFileType: UInt32
    let encryptedSliceRanges: [Range<UInt64>]
}

/// A typed, format-neutral loader finding. `message` is app-owned text built from enum vocabulary
/// and numbers only (never file bytes), so the collector may retain it.
struct LoaderFinding: Hashable, Sendable {
    enum Category: String, Hashable, Sendable {
        /// A fixup/relocation structure the loader explicitly refused to interpret.
        case unsupportedFixup
        /// ObjC metadata that cannot be trusted without context the image does not carry.
        case objcMetadataUnavailable
        /// HS-12: two function-start sources (LC_FUNCTION_STARTS, unwind tables) disagree.
        /// Evidence only; discovery is unchanged.
        case functionStartsDisagreement
        /// HS-13: a Swift or Objective-C metadata walk skipped, abandoned or capped part of its work.
        case metadataParseIssue
    }

    var category: Category
    /// Stable machine code for the specific finding (e.g. `chainedFixupsUnhandledPointerFormat`).
    var code: String
    var address: UInt64
    var message: String
}

/// A loader-detected truncation / over-read flag: a structure whose declared extent ran
/// past the available bytes and was clamped or skipped. Carried on `LoadedBinary` so the
/// analysis pipeline can project it into an analysis diagnostic without knowing the format.
struct LoaderDiagnosticTruncation: Hashable, Sendable {
    /// The anchor address (e.g. the section/structure start) selecting the row jumps to.
    var address: UInt64
    /// Human-readable description of what was truncated / over-read.
    var message: String
}

/// Loads a binary file into the neutral `LoadedBinary` model. Mach-O is the first
/// implementor (`MachOBinaryLoader`); ELF/PE plug in by conforming to this and
/// projecting their own parser output down to `LoadedBinary` — without the analysis
/// pipeline knowing the difference.
protocol BinaryLoader: Sendable {
    func load(at url: URL) throws -> LoadedBinary
    func load(at url: URL, cancellation: AnalysisCancellationToken) throws -> LoadedBinary
}

extension BinaryLoader {
    func load(at url: URL, cancellation: AnalysisCancellationToken) throws -> LoadedBinary {
        try cancellation.check()
        return try load(at: url)
    }
}

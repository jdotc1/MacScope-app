import Darwin
import Dispatch
import Foundation
import CryptoKit
import SwiftUI

struct WorkspaceSnapshot: Sendable {
    /// Value copies share a memo only while their analysis inputs are unchanged. Newly
    /// constructed snapshots and mutations get a fresh identity, even with reused ImageAnalysis.
    private var indirectCallSnapshotID = UUID()
    private var indirectCallMemo = IndirectCallResolutionMemo()
    private var slotPrototypeMemo = SlotPrototypeMemo()
    /// Ephemeral evidence from the shared importer, not persisted authored state.
    private var headerLayoutEvidence: [String: TypeDefinition] = [:]

    private mutating func invalidateAnalysisMemos() {
        indirectCallSnapshotID = UUID()
        indirectCallMemo = IndirectCallResolutionMemo()
        slotPrototypeMemo = SlotPrototypeMemo()
        codeExclusionMemo = ExportCodeExclusionMemo()
    }

    /// The sole ordered authority for image identity + binary metadata. Each `BinaryImage.slot`
    /// keys into `analysisBySlot`.
    var binaries: [BinaryImage] { didSet { invalidateAnalysisMemos() } }
    /// The sole authority for per-image derived analysis. One `ImageAnalysis` bucket per image slot.
    /// The 23 legacy flat accessors below are primary-image compatibility projections over this.
    var analysisBySlot: [ImageSlot: ImageAnalysis] = [:] { didSet { invalidateAnalysisMemos() } }
    private var codeExclusionMemo = ExportCodeExclusionMemo()

    /// WS-6 cross-image reference edges (A's import → B's export, by name). TRANSIENT + derived:
    /// re-derived by `WorkspaceStore.recomputeCrossImageXrefs()` on restore and on any image-set
    /// change, and NEVER encoded to the DB or `.mscope` (nor decoded from them). Empty for a
    /// single-image workspace → nothing on disk changes.
    var crossImageXrefs: [CrossImageXRef] = []

    /// The fixed-size hex-view window (a bounded PREFIX of the selected slice), NOT the source
    /// of truth for the binary's bytes — that is `imageBytes`, which is what gets persisted.
    static let hexViewByteWindow = 4096

    // MARK: - Flat primary-image compatibility projections (see `ImageAnalysis` for field docs)
    //
    // COMPATIBILITY ONLY. These read/write the PRIMARY image's bucket (`analysisBySlot[primarySlot]`)
    // so existing golden/export/scripting/UI/test code that says `snapshot.functions` keeps working
    // and single-image output stays byte-identical. New focused-image code must use the image-scoped
    // API (`analysis(in:)` / `mutateAnalysis(in:)`) instead — NOT these shims.

    var functions: [FunctionSummary] {
        get { analysisBySlot[primarySlot]?.functions ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.functions = newValue } }
    }
    var symbols: [SymbolSummary] {
        get { analysisBySlot[primarySlot]?.symbols ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.symbols = newValue } }
    }
    var imports: [ImportSummary] {
        get { analysisBySlot[primarySlot]?.imports ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.imports = newValue } }
    }
    var indirectSymbols: [IndirectSymbolSummary] {
        get { analysisBySlot[primarySlot]?.indirectSymbols ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.indirectSymbols = newValue } }
    }
    var exports: [ExportSummary] {
        get { analysisBySlot[primarySlot]?.exports ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.exports = newValue } }
    }
    var stringLiterals: [StringLiteralSummary] {
        get { analysisBySlot[primarySlot]?.stringLiterals ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.stringLiterals = newValue } }
    }
    var basicBlocks: [BasicBlockSummary] {
        get { analysisBySlot[primarySlot]?.basicBlocks ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.basicBlocks = newValue } }
    }
    var instructions: [InstructionRow] {
        get { analysisBySlot[primarySlot]?.instructions ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.instructions = newValue } }
    }
    var xrefs: [XRef] {
        get { analysisBySlot[primarySlot]?.xrefs ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.xrefs = newValue } }
    }
    var controlFlowEdges: [ControlFlowEdge] {
        get { analysisBySlot[primarySlot]?.controlFlowEdges ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.controlFlowEdges = newValue } }
    }
    var hexBytes: Data {
        get { analysisBySlot[primarySlot]?.hexBytes ?? Data() }
        set { mutateAnalysis(in: primarySlot) { $0.hexBytes = newValue } }
    }
    var jumpTables: [UInt64: [UInt64]] {
        get { analysisBySlot[primarySlot]?.jumpTables ?? [:] }
        set { mutateAnalysis(in: primarySlot) { $0.jumpTables = newValue } }
    }
    var objcSelectors: [UInt64: String] {
        get { analysisBySlot[primarySlot]?.objcSelectors ?? [:] }
        set { mutateAnalysis(in: primarySlot) { $0.objcSelectors = newValue } }
    }
    /// HOP-5c: the primary image's stored constant-string map (see `constantStrings(in:)`).
    var constantStrings: [UInt64: MacIRConstantString] {
        get { analysisBySlot[primarySlot]?.constantStrings ?? [:] }
        set { mutateAnalysis(in: primarySlot) { $0.constantStrings = newValue } }
    }
    var objcClasses: [ObjCClass] {
        get { analysisBySlot[primarySlot]?.objcClasses ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.objcClasses = newValue } }
    }
    var objcProtocols: [ObjCProtocol] {
        get { analysisBySlot[primarySlot]?.objcProtocols ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.objcProtocols = newValue } }
    }
    var objcCategories: [ObjCCategory] {
        get { analysisBySlot[primarySlot]?.objcCategories ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.objcCategories = newValue } }
    }
    var swiftTypes: [SwiftTypeDescriptor] {
        get { analysisBySlot[primarySlot]?.swiftTypes ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.swiftTypes = newValue } }
    }
    var swiftConformances: [SwiftConformance] {
        get { analysisBySlot[primarySlot]?.swiftConformances ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.swiftConformances = newValue } }
    }
    var sections: [SectionSummary] {
        get { analysisBySlot[primarySlot]?.sections ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.sections = newValue } }
    }
    var codeDataRanges: [CodeDataRangeSummary] {
        get { analysisBySlot[primarySlot]?.codeDataRanges ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.codeDataRanges = newValue } }
    }
    var relocations: [RelocationSummary] {
        get { analysisBySlot[primarySlot]?.relocations ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.relocations = newValue } }
    }
    var identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation] {
        get { analysisBySlot[primarySlot]?.identityEffectiveByteRanges ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.identityEffectiveByteRanges = newValue } }
    }
    var sourceLines: [SourceLineEntry] {
        get { analysisBySlot[primarySlot]?.sourceLines ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.sourceLines = newValue } }
    }
    var imageBytes: Data {
        get { analysisBySlot[primarySlot]?.imageBytes ?? Data() }
        set { mutateAnalysis(in: primarySlot) { $0.imageBytes = newValue } }
    }
    var diagnostics: [AnalysisDiagnostic] {
        get { analysisBySlot[primarySlot]?.diagnostics ?? [] }
        set { mutateAnalysis(in: primarySlot) { $0.diagnostics = newValue } }
    }
    var machOMetadata: MachOLoadMetadata? {
        get { analysisBySlot[primarySlot]?.machOMetadata }
        set { mutateAnalysis(in: primarySlot) { $0.machOMetadata = newValue } }
    }
    var analysisInputFingerprint: AnalysisInputFingerprint? {
        get { analysisBySlot[primarySlot]?.analysisInputFingerprint }
        set { mutateAnalysis(in: primarySlot) { $0.analysisInputFingerprint = newValue } }
    }

    // MARK: - Authoring state (workspace-global; unchanged by the per-image refactor)

    /// User-authored overrides (custom names, comments) keyed by IMAGE-QUALIFIED
    /// address (`ImageAddress`): two images can legitimately contain the same VA, so a
    /// bare-address key would silently cross-bleed authoring between them. Unlike
    /// the two derived seams above, these ARE persisted (through
    /// `WorkspacePackageAnalysis` and the workspace database) so renames and
    /// comments survive save/reload. Defaults to empty so every existing
    /// construction site stays byte-identical. Single-image workspaces put
    /// everything in `ImageSlot.primary` — the exact legacy shape.
    var addressOverrides: [ImageAddress: AddressOverride] = [:] { didSet { invalidateAnalysisMemos() } }
    /// Explicit header-import contracts, below authored signatures in precedence.
    var importedPrototypes: [ImageAddress: FunctionSignatureOverride] = [:] { didSet { invalidateAnalysisMemos() } }
    /// User-defined type catalog (struct/union/enum/typedef), workspace-global
    /// rather than address-keyed. Persisted alongside the overrides. Defaults empty.
    var typeDefinitions: [TypeDefinition] = [] {
        didSet {
            // Undo/restore and catalog edits cannot silently preserve import origin.
            headerLayoutEvidence.removeAll()
            invalidateAnalysisMemos()
        }
    }

    /// Called only by real header-import mutation entries, never by render views.
    /// Re-importing identical declarations may establish new evidence even when
    /// the existing authoring wrapper has no mutation/undo work to perform.
    mutating func recordHeaderImportEvidence(_ headerLayoutDefinitions: [TypeDefinition]) {
        headerLayoutEvidence.removeAll()
        defer { invalidateAnalysisMemos() }
        guard !Task.isCancelled else { return }
        let current = Dictionary(grouping: typeDefinitions, by: \.name)
        let parsed = Dictionary(grouping: headerLayoutDefinitions, by: \.name)
        for (name, declarations) in parsed {
            guard declarations.count == 1, let declaration = declarations.first,
                  let matches = current[name], matches.count == 1, let existing = matches.first else { continue }
            var comparable = declaration
            comparable.id = existing.id
            guard comparable == existing else { continue }
            headerLayoutEvidence[name] = declaration
        }
    }
    /// User-authored cross-reference edits (added/suppressed xrefs), workspace-global.
    /// Persisted alongside the overrides; merged into / filtered out of `xrefs` at query
    /// time via `effectiveXRefs(...)`. Defaults empty.
    var manualXRefs: [ManualXRef] = []
    /// User-named navigation bookmarks, workspace-global. Persisted alongside the
    /// overrides; surfaced in a Bookmarks list / menu and the scripting API. Defaults empty.
    var bookmarks: [Bookmark] = []
    /// User-authored segment/section DISPLAY overrides (rename + rebase), keyed by the
    /// section's original name. Persisted alongside the overrides; applied at display time
    /// via `effectiveSections()` without mutating the derived `sections`. Defaults empty.
    var segmentOverrides: [SegmentOverride] = []
    /// WS-21 durable logical breakpoint authoring facts. Runtime bindings, transport receipts,
    /// hit counters, and debugger-session state deliberately live outside the workspace snapshot.
    var logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog = .freshPristine()
    /// WS-22 durable launch authoring. Process discovery, PIDs, session authority, LLDB state,
    /// runtime inventories, and console data deliberately never enter the workspace snapshot.
    var launchProfileCatalog: DebuggerLaunchProfileCatalog = .freshPristine()
    var savedWatchCatalog: WorkspaceSavedWatchCatalog = .empty
    /// Versioned app-owned source evidence, bounded to 1 MiB. Contains identities and paths only.
    var sourceLinkState: Data = Data()
    // NOTE: `diagnostics` and `machOMetadata` are now per-image (see the flat projections above +
    // `ImageAnalysis`); they are no longer stored directly on the snapshot.

    // MARK: - Initializers

    /// Image-aware initializer for new construction: supply the identity spine and the per-slot
    /// analysis buckets directly.
    init(
        binaries: [BinaryImage],
        analysisBySlot: [ImageSlot: ImageAnalysis],
        addressOverrides: [ImageAddress: AddressOverride] = [:],
        importedPrototypes: [ImageAddress: FunctionSignatureOverride] = [:],
        typeDefinitions: [TypeDefinition] = [],
        manualXRefs: [ManualXRef] = [],
        bookmarks: [Bookmark] = [],
        segmentOverrides: [SegmentOverride] = [],
        logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog = .freshPristine(),
        launchProfileCatalog: DebuggerLaunchProfileCatalog = .freshPristine(),
        savedWatchCatalog: WorkspaceSavedWatchCatalog = .empty,
        sourceLinkState: Data = Data()
    ) {
        self.binaries = binaries
        self.analysisBySlot = analysisBySlot
        self.addressOverrides = addressOverrides
        self.importedPrototypes = importedPrototypes
        self.typeDefinitions = typeDefinitions
        self.manualXRefs = manualXRefs
        self.bookmarks = bookmarks
        self.segmentOverrides = segmentOverrides
        self.logicalBreakpointCatalog = logicalBreakpointCatalog
        self.launchProfileCatalog = launchProfileCatalog
        self.savedWatchCatalog = savedWatchCatalog
        self.sourceLinkState = sourceLinkState
    }

    /// Compatibility initializer reproducing the pre-refactor memberwise signature. Every derived
    /// argument is routed into ONE `ImageAnalysis` bucket at the legacy slot
    /// (`binaries.first?.slot ?? .primary`) — NOT literal `.primary`, so a sole binary sitting at a
    /// nonzero slot (e.g. the codec fixture's `Int.max`) exposes its derived data through the flat
    /// projections. A binary-less snapshot with nonempty derived data stores under `.primary`
    /// without fabricating a `BinaryImage`.
    init(
        binaries: [BinaryImage],
        functions: [FunctionSummary],
        symbols: [SymbolSummary] = [],
        imports: [ImportSummary] = [],
        indirectSymbols: [IndirectSymbolSummary] = [],
        exports: [ExportSummary] = [],
        stringLiterals: [StringLiteralSummary] = [],
        basicBlocks: [BasicBlockSummary] = [],
        instructions: [InstructionRow],
        xrefs: [XRef],
        controlFlowEdges: [ControlFlowEdge] = [],
        hexBytes: Data,
        jumpTables: [UInt64: [UInt64]] = [:],
        objcSelectors: [UInt64: String] = [:],
        objcClassReferences: [UInt64: ObjCClassReferenceTarget] = [:],
        constantStrings: [UInt64: MacIRConstantString]? = nil,
        objcClasses: [ObjCClass] = [],
        objcCategories: [ObjCCategory] = [],
        objcProtocols: [ObjCProtocol] = [],
        swiftTypes: [SwiftTypeDescriptor] = [],
        swiftConformances: [SwiftConformance] = [],
        sections: [SectionSummary] = [],
        codeDataRanges: [CodeDataRangeSummary] = [],
        relocations: [RelocationSummary] = [],
        identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation] = [],
        sourceLines: [SourceLineEntry] = [],
        imageBytes: Data = Data(),
        addressOverrides: [ImageAddress: AddressOverride] = [:],
        importedPrototypes: [ImageAddress: FunctionSignatureOverride] = [:],
        typeDefinitions: [TypeDefinition] = [],
        manualXRefs: [ManualXRef] = [],
        bookmarks: [Bookmark] = [],
        segmentOverrides: [SegmentOverride] = [],
        logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog = .freshPristine(),
        launchProfileCatalog: DebuggerLaunchProfileCatalog = .freshPristine(),
        savedWatchCatalog: WorkspaceSavedWatchCatalog = .empty,
        sourceLinkState: Data = Data(),
        diagnostics: [AnalysisDiagnostic] = [],
        machOMetadata: MachOLoadMetadata? = nil,
        analysisInputFingerprint: AnalysisInputFingerprint? = nil
    ) {
        self.binaries = binaries
        self.addressOverrides = addressOverrides
        self.importedPrototypes = importedPrototypes
        self.typeDefinitions = typeDefinitions
        self.manualXRefs = manualXRefs
        self.bookmarks = bookmarks
        self.segmentOverrides = segmentOverrides
        self.logicalBreakpointCatalog = logicalBreakpointCatalog
        self.launchProfileCatalog = launchProfileCatalog
        self.savedWatchCatalog = savedWatchCatalog
        self.sourceLinkState = sourceLinkState
        let legacySlot = binaries.first?.slot ?? .primary
        self.analysisBySlot = [legacySlot: ImageAnalysis(
            functions: functions,
            symbols: symbols,
            imports: imports,
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: stringLiterals,
            basicBlocks: basicBlocks,
            instructions: instructions,
            xrefs: xrefs,
            controlFlowEdges: controlFlowEdges,
            hexBytes: hexBytes,
            jumpTables: jumpTables,
            objcSelectors: objcSelectors,
            // nil (hand-built snapshots, package reload) derives the C-string part once here.
            constantStrings: constantStrings ?? ImageConstantStringProvider.build(
                stringLiterals: stringLiterals, cfStrings: [:]
            ),
            objcClasses: objcClasses,
            objcCategories: objcCategories,
            objcProtocols: objcProtocols,
            swiftTypes: swiftTypes,
            swiftConformances: swiftConformances,
            sections: sections,
            codeDataRanges: codeDataRanges,
            relocations: relocations,
            identityEffectiveByteRanges: identityEffectiveByteRanges,
            sourceLines: sourceLines,
            imageBytes: imageBytes,
            diagnostics: diagnostics,
            machOMetadata: machOMetadata,
            analysisInputFingerprint: analysisInputFingerprint,
            objcClassReferences: objcClassReferences
        )]
        // RX-02a: the Type Atlas image part is derived once here, like `constantStrings`.
        analysisBySlot[legacySlot]?.refreshTypeCatalog()
    }

    // MARK: - Image-scoped access + mutation (invariant-preserving)

    /// The binary image occupying `slot`, if any.
    func binary(in slot: ImageSlot) -> BinaryImage? {
        binaries.first { $0.slot == slot }
    }

    /// The derived analysis bucket for `slot`, if any.
    func analysis(in slot: ImageSlot) -> ImageAnalysis? {
        analysisBySlot[slot]
    }

    /// HOP-5c: the image's once-per-image decompiler constant-string map (address → C string or
    /// `__cfstring` object contents). Stored on the image's analysis; this never rebuilds it.
    /// Pass it to `PseudocodePrinter.print/buildFunction(constantStrings:)`.
    func constantStrings(in slot: ImageSlot) -> [UInt64: MacIRConstantString] {
        analysisBySlot[slot]?.constantStrings ?? [:]
    }

    /// Mutate the analysis bucket at `slot` in place, creating an empty bucket if none exists.
    /// The single write chokepoint for per-image derived data (the flat projections route here).
    @discardableResult
    mutating func mutateAnalysis<R>(in slot: ImageSlot, _ body: (inout ImageAnalysis) -> R) -> R {
        var analysis = analysisBySlot[slot] ?? ImageAnalysis()
        let result = body(&analysis)
        analysisBySlot[slot] = analysis
        return result
    }

    /// Replace the entire analysis bucket at `slot` (used by the per-slot re-analysis splice).
    mutating func replaceAnalysis(_ analysis: ImageAnalysis, in slot: ImageSlot) {
        analysisBySlot[slot] = analysis
    }

    /// Insert a new image (identity + its analysis bucket) at `index` (default: append). The
    /// binary's `slot` must be vacant.
    mutating func insertImage(binary: BinaryImage, analysis: ImageAnalysis, at index: Int? = nil) {
        assert(self.binary(in: binary.slot) == nil, "insertImage: slot \(binary.slot.rawValue) already occupied")
        assert(analysisBySlot[binary.slot] == nil, "insertImage: analysis bucket \(binary.slot.rawValue) already present")
        binaries.insert(binary, at: index ?? binaries.count)
        analysisBySlot[binary.slot] = analysis
    }

    /// Remove the image at `slot` and its analysis bucket. Authoring keyed to that slot is left to
    /// the caller/store (it may be intentionally retained or cleared separately).
    mutating func removeImage(in slot: ImageSlot) {
        binaries.removeAll { $0.slot == slot }
        analysisBySlot[slot] = nil
    }

    /// Atomically renumber an image's slot across the identity spine, its analysis bucket, and every
    /// slot-qualified authoring collection — so all of them move together or not at all. The target
    /// slot must be vacant.
    mutating func remapImageSlot(from old: ImageSlot, to new: ImageSlot) {
        guard old != new else { return }
        assert(binary(in: new) == nil && analysisBySlot[new] == nil,
               "remapImageSlot: target slot \(new.rawValue) must be vacant")
        binaries = binaries.map { var b = $0; if b.slot == old { b.slot = new }; return b }
        if let moved = analysisBySlot.removeValue(forKey: old) { analysisBySlot[new] = moved }
        addressOverrides = Dictionary(uniqueKeysWithValues: addressOverrides.map { key, value in
            key.slot == old ? (ImageAddress(slot: new, address: key.address), value) : (key, value)
        })
        importedPrototypes = Dictionary(uniqueKeysWithValues: importedPrototypes.map { key, value in
            key.slot == old ? (ImageAddress(slot: new, address: key.address), value) : (key, value)
        })
        bookmarks = bookmarks.map { var b = $0; if b.imageSlot == old { b.imageSlot = new }; return b }
        manualXRefs = manualXRefs.map { var x = $0; if x.imageSlot == old { x.imageSlot = new }; return x }
        segmentOverrides = segmentOverrides.map { var o = $0; if o.imageSlot == old { o.imageSlot = new }; return o }
    }

    /// Structural invariants the container must uphold for a normal (non-fixture) workspace.
    /// Throws on the two corruption modes that matter: duplicate binary slots, and an analysis
    /// bucket with no owning binary. The binary-less `.primary` bucket used by test fixtures is
    /// permitted explicitly.
    func validateInvariants() throws {
        var seen = Set<ImageSlot>()
        for image in binaries where !seen.insert(image.slot).inserted {
            throw WorkspaceSnapshotInvariantError.duplicateSlot(image.slot)
        }
        let binarySlots = Set(binaries.map(\.slot))
        for slot in analysisBySlot.keys where !binarySlots.contains(slot) {
            // Tolerated fixture case: a binary-less snapshot may carry analysis under `.primary`.
            if binaries.isEmpty && slot == .primary { continue }
            throw WorkspaceSnapshotInvariantError.orphanAnalysis(slot)
        }
    }

    /// The slot of the primary (first) image — the target of every bare-address render
    /// helper below. The listing renders exactly one image (the primary) this wave; when
    /// multi-image rendering arrives, these helpers must take the row's own slot instead.
    var primarySlot: ImageSlot { binaries.first?.slot ?? .primary }

    /// The workspace key for a bare address in the PRIMARY image — the single chokepoint
    /// through which the bare-address helpers resolve into the qualified overrides map.
    func primaryKey(_ address: UInt64) -> ImageAddress {
        ImageAddress(slot: primarySlot, address: address)
    }

    /// The workspace key for `address` in `slot` (defaults to the primary image). The bare-address
    /// render helpers route through here so the focused UI can resolve authoring for a non-primary
    /// image by passing `in: focusedSlot`, while every existing primary-only caller is unchanged.
    func key(_ address: UInt64, in slot: ImageSlot? = nil) -> ImageAddress {
        ImageAddress(slot: slot ?? primarySlot, address: address)
    }

    /// The overrides for one image projected down to a bare-address map — the shape the
    /// image-local readers (inspector, command palette, exporters) consume. Single-image
    /// workspaces get exactly today's `[UInt64: AddressOverride]`.
    func overrides(in slot: ImageSlot) -> [UInt64: AddressOverride] {
        var result: [UInt64: AddressOverride] = [:]
        for (key, value) in addressOverrides where key.slot == slot {
            result[key.address] = value
        }
        return result
    }

    /// The primary image's overrides as a bare-address map.
    var primaryOverrides: [UInt64: AddressOverride] { overrides(in: primarySlot) }

    /// Freezes one image's complete graph input without consulting any flat primary projection.
    /// Recovered xrefs come directly from that image's analysis bucket: manual/effective xrefs
    /// and cross-image xrefs remain separate products and therefore cannot leak into this graph.
    /// A loaded image whose analysis is unavailable produces an identified empty projection.
    func graphProjection(in slot: ImageSlot) -> FocusedGraphProjection {
        guard let analysis = analysis(in: slot) else {
            return FocusedGraphProjection(
                imageSlot: slot,
                ownerBinaryID: binary(in: slot)?.id,
                functions: [],
                basicBlocks: [],
                instructions: [],
                controlFlowEdges: [],
                xrefs: [],
                presentationByAddress: [:]
            )
        }

        let presentationByAddress = overrides(in: slot).reduce(
            into: [UInt64: GraphAddressPresentation]()
        ) { result, entry in
            let (address, override) = entry
            guard override.customName != nil || override.tag != nil || override.colorTag != nil else {
                return
            }
            result[address] = GraphAddressPresentation(
                customName: override.customName,
                tag: override.tag,
                colorTag: override.colorTag
            )
        }

        return FocusedGraphProjection(
            imageSlot: slot,
            ownerBinaryID: binary(in: slot)?.id,
            functions: analysis.functions,
            basicBlocks: analysis.basicBlocks,
            instructions: analysis.instructions,
            controlFlowEdges: analysis.controlFlowEdges,
            xrefs: analysis.xrefs,
            presentationByAddress: presentationByAddress
        )
    }

    // MARK: - Image-qualified interactive lookups

    /// Interactive lookups require both sides of the image container. This rejects an absent
    /// image as well as a loaded image whose derived analysis is not currently available.
    private func loadedAnalysis(in slot: ImageSlot) -> ImageAnalysis? {
        guard binary(in: slot) != nil else { return nil }
        return analysis(in: slot)
    }

    /// The decoded row at one exact image-qualified address. An absent analysis bucket is not
    /// permission to consult the primary compatibility projection or a colliding sibling row.
    func instruction(at address: UInt64, in slot: ImageSlot) -> InstructionRow? {
        loadedAnalysis(in: slot)?.instructions.first { $0.address == address }
    }

    func instruction(at target: ImageAddress) -> InstructionRow? {
        instruction(at: target.address, in: target.slot)
    }

    /// The string literal beginning at one exact image-qualified address.
    func stringLiteral(at address: UInt64, in slot: ImageSlot) -> StringLiteralSummary? {
        loadedAnalysis(in: slot)?.stringLiterals.first { $0.address == address }
    }

    func stringLiteral(at target: ImageAddress) -> StringLiteralSummary? {
        stringLiteral(at: target.address, in: target.slot)
    }

    /// Qualified wrappers over the existing canonical containment lookups. Both abstain when the
    /// target slot has no current analysis rather than borrowing primary-image structure.
    func enclosingFunction(for target: ImageAddress) -> FunctionSummary? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return enclosingFunction(for: target.address, in: target.slot)
    }

    func section(containing target: ImageAddress) -> SectionSummary? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return section(containing: target.address, in: target.slot)
    }

    func sourceLine(at target: ImageAddress) -> SourceLineEntry? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return sourceLine(at: target.address, in: target.slot)
    }

    /// The authored state at `target`, but only while its image has a current analysis bucket.
    /// Interactive consumers use this qualified read for initial values and toggle state; legacy
    /// bare-address helpers below deliberately retain their primary-image compatibility behavior.
    func addressOverride(at target: ImageAddress) -> AddressOverride? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return addressOverrides[target]
    }

    func displayName(at target: ImageAddress, default parsed: String) -> String? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return addressOverrides[target]?.customName ?? parsed
    }

    func displayComment(at target: ImageAddress, default decoded: String?) -> String? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return addressOverrides[target]?.customComment ?? decoded
    }

    func operandFormat(at target: ImageAddress) -> OperandFormat? {
        addressOverride(at: target)?.operandFormat
    }

    func displayOperands(at target: ImageAddress, default raw: String) -> String? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        guard let format = addressOverrides[target]?.operandFormat else { return raw }
        return OperandFormat.apply(to: raw, format: format)
    }

    func hasOverride(at target: ImageAddress) -> Bool {
        guard let override = addressOverride(at: target) else { return false }
        return !override.isEmpty
    }

    func tag(at target: ImageAddress) -> String? {
        addressOverride(at: target)?.tag
    }

    func colorTag(at target: ImageAddress) -> ColorTag? {
        addressOverride(at: target)?.colorTag
    }

    func isData(at target: ImageAddress) -> Bool {
        guard let override = addressOverride(at: target) else { return false }
        return override.isData || !(override.dataShape?.isEmpty ?? true)
    }

    func dataShape(at target: ImageAddress) -> DataShapeOverride? {
        guard let shape = addressOverride(at: target)?.dataShape, !shape.isEmpty else { return nil }
        return shape
    }

    func isUndefined(at target: ImageAddress) -> Bool {
        addressOverride(at: target)?.isUndefined ?? false
    }

    func isMarkedAsProcedure(at target: ImageAddress) -> Bool {
        addressOverride(at: target)?.markAsProcedure ?? false
    }

    func patch(at target: ImageAddress) -> BytePatch? {
        guard let patch = addressOverride(at: target)?.patch, !patch.isEmpty else { return nil }
        return patch
    }

    func signatureOverride(at target: ImageAddress) -> FunctionSignatureOverride? {
        addressOverride(at: target)?.signature
    }

    func appliedType(at target: ImageAddress) -> TypeDefinition? {
        guard let name = addressOverride(at: target)?.appliedTypeName, !name.isEmpty else { return nil }
        return typeDefinitions.first { $0.name == name }
    }

    func switchHint(at target: ImageAddress) -> SwitchHintOverride? {
        guard let hint = addressOverride(at: target)?.switchHint, !hint.isEmpty else { return nil }
        return hint
    }

    func localLabel(at target: ImageAddress) -> String? {
        guard let label = addressOverride(at: target)?.localLabel, !label.isEmpty else { return nil }
        return label
    }

    func registerNameOverrides(forProcedureAt target: ImageAddress) -> [String: String] {
        guard let names = addressOverride(at: target)?.registerNames else { return [:] }
        return AddressOverride.prunedRegisterNames(names)
    }

    /// The bookmark at one exact image-qualified location. The legacy bare overload remains the
    /// primary-era compatibility query and is intentionally unchanged.
    func bookmark(at target: ImageAddress) -> Bookmark? {
        guard loadedAnalysis(in: target.slot) != nil else { return nil }
        return bookmarks.first { $0.imageSlot == target.slot && $0.address == target.address }
    }

    /// Effective xrefs are always resolved inside the target's analysis bucket. Manual edits from
    /// sibling slots and `crossImageXrefs` never enter these qualified intra-image queries.
    func effectiveXRefs(to target: ImageAddress) -> [XRef] {
        guard loadedAnalysis(in: target.slot) != nil else { return [] }
        return effectiveXRefs(to: target.address, in: target.slot)
    }

    func effectiveXRefs(from target: ImageAddress) -> [XRef] {
        guard loadedAnalysis(in: target.slot) != nil else { return [] }
        return effectiveXRefs(from: target.address, in: target.slot)
    }

    /// The primary image's VERIFIED file-offset → virtual-address mappings, derived from its
    /// sections and exact-slice payload length. This is the authority the hex pane uses to map
    /// an edited cell to its true virtual address (replacing the legacy `firstInstruction +
    /// offset` guess). A freshly analyzed image has both `sections` and `imageBytes`, so it
    /// maps precisely; a reloaded package/database snapshot has neither (both are derived,
    /// not persisted this stage), so this is empty and the hex pane stays conservatively
    /// read-only rather than editing at a fabricated address.
    var primaryImageByteMappings: [FileAddressMapping] {
        imageByteMappings(in: primarySlot)
    }

    /// The verified file-offset → virtual-address mappings for `slot` (defaults to the primary),
    /// so the hex pane can map an edited cell to the FOCUSED image's true VA. A freshly analyzed
    /// image has bytes + sections and maps precisely; a reloaded snapshot has neither and this is
    /// empty (hex pane stays read-only) — the same safety the primary path had.
    func imageByteMappings(in slot: ImageSlot? = nil) -> [FileAddressMapping] {
        let analysis = analysis(in: slot ?? primarySlot)
        let bytes = analysis?.imageBytes ?? Data()
        guard !bytes.isEmpty else { return [] }
        return FileAddressMapping.verifiedMappings(from: analysis?.sections ?? [], payloadLength: bytes.count)
    }

    /// The display name for the entity at `address`: the user's custom name when
    /// one is set, otherwise the supplied parsed/synthesized name. Used at every
    /// name-render site (listing, sidebar, inspector, graph, pseudocode).
    func displayName(at address: UInt64, in slot: ImageSlot? = nil, default parsed: String) -> String {
        addressOverrides[key(address, in: slot)]?.customName ?? parsed
    }

    /// The recovered source line covering `address` in `slot` (defaults to the primary image): the
    /// line-table row with the greatest address `<= address`. Returns nil when no dSYM is imported,
    /// when `address` precedes all rows, or when it falls in a gap past an `endSequence` terminator.
    /// The slot's `sourceLines` is address-sorted, so this is a binary search.
    func sourceLine(at address: UInt64, in slot: ImageSlot? = nil) -> SourceLineEntry? {
        let rows = analysis(in: slot ?? primarySlot)?.sourceLines ?? []
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].address <= address { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let entry = rows[low - 1]
        return entry.endSequence ? nil : entry
    }

    /// The display comment for the instruction at `address`: the user's custom
    /// comment when one is set, otherwise the decoder-generated comment.
    func displayComment(at address: UInt64, in slot: ImageSlot? = nil, default decoded: String?) -> String? {
        addressOverrides[key(address, in: slot)]?.customComment ?? decoded
    }

    /// The user's immediate-operand display format at `address`, if any.
    func operandFormat(at address: UInt64, in slot: ImageSlot? = nil) -> OperandFormat? {
        addressOverrides[key(address, in: slot)]?.operandFormat
    }

    /// The display operands for the instruction at `address`: the decoder's operand
    /// text with the user's immediate-operand format applied when one is set.
    func displayOperands(at address: UInt64, in slot: ImageSlot? = nil, default raw: String) -> String {
        guard let format = addressOverrides[key(address, in: slot)]?.operandFormat else { return raw }
        return OperandFormat.apply(to: raw, format: format)
    }

    /// True when the entity at `address` carries a user override (for an optional
    /// "edited" visual marker).
    func hasOverride(at address: UInt64, in slot: ImageSlot? = nil) -> Bool {
        if let override = addressOverrides[key(address, in: slot)] { return !override.isEmpty }
        return false
    }

    /// The user's free-text tag for the entity at `address`, if any.
    func tag(at address: UInt64, in slot: ImageSlot? = nil) -> String? {
        addressOverrides[key(address, in: slot)]?.tag
    }

    /// The user's highlight color for the entity at `address`, if any.
    func colorTag(at address: UInt64, in slot: ImageSlot? = nil) -> ColorTag? {
        addressOverrides[key(address, in: slot)]?.colorTag
    }

    /// True when the user marked the address as data (the listing renders it as a
    /// data directive rather than a decoded instruction). A data SHAPE (array /
    /// alignment / string) also counts as data — the shaped span is excluded from
    /// code analysis exactly like a plain mark-as-data.
    func isData(at address: UInt64, in slot: ImageSlot? = nil) -> Bool {
        guard let override = addressOverrides[key(address, in: slot)] else { return false }
        if override.isData { return true }
        if let shape = override.dataShape, !shape.isEmpty { return true }
        return false
    }

    /// The user-authored data shape at `address` (array / alignment / string), if any.
    /// A degenerate (empty) shape resolves to nil.
    func dataShape(at address: UInt64, in slot: ImageSlot? = nil) -> DataShapeOverride? {
        guard let shape = addressOverrides[key(address, in: slot)]?.dataShape, !shape.isEmpty else { return nil }
        return shape
    }

    /// True when the user marked the address UNDEFINED (the inverse of Mark-as-Procedure):
    /// the listing renders it as a raw `.byte` undefined directive and the address is
    /// excluded from every code-analysis pass, exactly like mark-as-data.
    func isUndefined(at address: UInt64, in slot: ImageSlot? = nil) -> Bool {
        addressOverrides[key(address, in: slot)]?.isUndefined ?? false
    }

    /// The user byte-patch at `address` (replacement bytes), if any. A degenerate (empty)
    /// patch resolves to nil. The listing/analysis re-decode from these bytes.
    func patch(at address: UInt64, in slot: ImageSlot? = nil) -> BytePatch? {
        guard let patch = addressOverrides[key(address, in: slot)]?.patch, !patch.isEmpty else { return nil }
        return patch
    }

    /// Every applied byte-patch keyed by its virtual address (empty patches pruned). The
    /// input to `MachOPatchWriter`, which maps each address to a file offset to write a
    /// patched copy of the original binary to disk.
    func patches(in slot: ImageSlot) -> [UInt64: BytePatch] {
        var result: [UInt64: BytePatch] = [:]
        for (key, override) in addressOverrides where key.slot == slot {
            guard let patch = override.patch, !patch.isEmpty else { continue }
            result[key.address] = patch
        }
        return result
    }

    /// Every address EXCLUDED from code analysis: a mark-as-data, a data shape, OR a
    /// mark-as-undefined. The single set the AnalysisEngine filters the code passes
    /// against, so all three authoring levers re-drive discovery identically.
    func codeExcludedAddresses(in slot: ImageSlot) -> Set<UInt64> {
        codeExclusionMemo.addresses(in: slot) {
            var result = Set<UInt64>()
            for (key, override) in addressOverrides
            where key.slot == slot
                && (override.isData || override.isUndefined || !(override.dataShape?.isEmpty ?? true)) {
                result.insert(key.address)
            }
            guard let analysis = analysis(in: slot), !analysis.codeDataRanges.isEmpty else {
                return result
            }
            result.formUnion(analysis.exportInstructionIndex().loaderExcludedAddresses)
            return result
        }
    }

    func isInLoaderDataRange(_ address: UInt64, in slot: ImageSlot) -> Bool {
        analysis(in: slot)?.codeDataRanges.contains { $0.contains(address) } ?? false
    }

    func isExecutableInstructionAddress(_ target: ImageAddress) -> Bool {
        guard let analysis = analysis(in: target.slot),
              analysis.instructions.contains(where: { $0.address == target.address }),
              !isData(at: target),
              !isUndefined(at: target),
              !isInLoaderDataRange(target.address, in: target.slot) else {
            return false
        }
        guard !analysis.sections.isEmpty else { return true }
        return analysis.sections.contains { section in
            guard section.isExecutable, !section.isZeroFill, section.size > 0 else { return false }
            let (end, overflow) = section.address.addingReportingOverflow(section.size)
            guard !overflow else { return false }
            return target.address >= section.address && target.address < end
        }
    }

    /// The effective cross-reference set: the recovered `xrefs` with user SUPPRESSIONS
    /// filtered out (matched by `(from, to, kind)` endpoints — id-independent, since a
    /// recovered xref's UUID is regenerated on every re-analysis) and user ADDED xrefs
    /// merged in (deduped against an already-present recovered xref by the same endpoint
    /// triple). The single source of truth for the xref inspector and the scripting API.
    func effectiveXRefs(in slot: ImageSlot? = nil) -> [XRef] {
        let s = slot ?? primarySlot
        let xrefs = analysis(in: s)?.xrefs ?? []
        // The recovered `xrefs` are image-local, so only manual edits authored in the SAME slot
        // participate; a sibling image's edits must never suppress or inject edges here.
        let manualXRefs = self.manualXRefs.filter { $0.imageSlot == s }
        guard !manualXRefs.isEmpty else { return xrefs }
        let suppressed = Set(manualXRefs.filter(\.isSuppression).map(\.endpointKey))
        var result = xrefs.filter { !suppressed.contains(XRefEndpointKey(from: $0.from, to: $0.to, kind: $0.kind)) }
        var present = Set(result.map { XRefEndpointKey(from: $0.from, to: $0.to, kind: $0.kind) })
        for manual in manualXRefs where !manual.isSuppression {
            let key = manual.endpointKey
            // Don't re-add an endpoint that already survives (recovered, not suppressed),
            // and don't add one the user also suppressed (a suppression wins).
            guard !present.contains(key), !suppressed.contains(key) else { continue }
            result.append(XRef(id: manual.id, from: manual.from, to: manual.to, kind: manual.kind))
            present.insert(key)
        }
        return result
    }

    enum XRefQueryDirection {
        case to(UInt64)
        case from(UInt64)

        func matches(from: UInt64, to: UInt64) -> Bool {
            switch self {
            case .to(let address): return to == address
            case .from(let address): return from == address
            }
        }
    }

    enum XRefQueryFailure: Error {
        case workBudget
        case resultBudget
    }

    /// Selects only the requested rows, without building the full effective cross-reference
    /// array. A caller-requested prefix may stop early; an implicit result cap must fail rather
    /// than make a partial list look complete. Recovered duplicates and authored-edit ordering
    /// follow `effectiveXRefs(in:)` exactly.
    func boundedEffectiveXRefs(
        _ direction: XRefQueryDirection,
        in slot: ImageSlot? = nil,
        limit: Int?,
        maximumRows: Int,
        maximumWork: Int,
        checkpoint: () throws -> Void
    ) throws -> [XRef] {
        try checkpoint()
        let rowBudget = max(0, maximumRows)
        let requested = limit.map { max(0, $0) }
        guard requested.map({ $0 <= rowBudget }) ?? true else { throw XRefQueryFailure.resultBudget }
        if requested == 0 { return [] }
        let selectedSlot = slot ?? primarySlot
        var work = 0
        func step() throws {
            guard work < maximumWork else { throw XRefQueryFailure.workBudget }
            // Check nonmatches too, so cancellation remains responsive for sparse queries.
            if work % 256 == 0 { try checkpoint() }
            work += 1
        }
        var suppressed = Set<XRefEndpointKey>()
        for edit in manualXRefs {
            try step()
            guard edit.imageSlot == selectedSlot, edit.isSuppression,
                  direction.matches(from: edit.from, to: edit.to) else { continue }
            suppressed.insert(edit.endpointKey)
        }
        var result: [XRef] = []
        var present = Set<XRefEndpointKey>()
        for ref in analysis(in: selectedSlot)?.xrefs ?? [] {
            try step()
            guard direction.matches(from: ref.from, to: ref.to) else { continue }
            let key = XRefEndpointKey(from: ref.from, to: ref.to, kind: ref.kind)
            guard !suppressed.contains(key) else { continue }
            guard result.count < rowBudget else { throw XRefQueryFailure.resultBudget }
            result.append(ref)
            present.insert(key)
            if result.count == requested { try checkpoint(); return result }
        }
        // Walk edits again instead of materializing every authored addition. Both passes
        // share the same work budget, including edits outside the requested image/address.
        for edit in manualXRefs {
            try step()
            guard edit.imageSlot == selectedSlot, !edit.isSuppression,
                  direction.matches(from: edit.from, to: edit.to) else { continue }
            let key = edit.endpointKey
            guard !suppressed.contains(key), !present.contains(key) else { continue }
            guard result.count < rowBudget else { throw XRefQueryFailure.resultBudget }
            result.append(XRef(id: edit.id, from: edit.from, to: edit.to, kind: edit.kind))
            present.insert(key)
            if result.count == requested { try checkpoint(); return result }
        }
        try checkpoint()
        return result
    }

    /// Effective cross-references whose target is `address` (references INTO here), with
    /// user suppressions/additions applied.
    func effectiveXRefs(to address: UInt64, in slot: ImageSlot? = nil) -> [XRef] {
        effectiveXRefs(in: slot).filter { $0.to == address }
    }

    /// Effective cross-references originating at `address` (references FROM here), with
    /// user suppressions/additions applied.
    func effectiveXRefs(from address: UInt64, in slot: ImageSlot? = nil) -> [XRef] {
        effectiveXRefs(in: slot).filter { $0.from == address }
    }

    /// The user bookmarks, sorted by address (ties broken by name) for a stable list.
    func sortedBookmarks() -> [Bookmark] {
        bookmarks.sorted { $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address }
    }

    /// The bookmark at `address`, if any (the first when several share an address).
    func bookmark(at address: UInt64) -> Bookmark? {
        bookmarks.first { $0.address == address }
    }

    /// Every address treated as DATA for navigation: user mark-as-data, mark-as-undefined,
    /// a data shape, and the recovered string-literal addresses. Used by Next-Data and to
    /// exclude these from Next-Code / Next-Unexplored. `isUndefined` is grouped with data
    /// here for the SAME reason it is in `codeExcludedAddresses()`: a mark-as-undefined row
    /// keeps its decoded instruction (so the listing can render it as `; undefined`), so
    /// without this it would leak into Next-Code as if it were live code. Unsorted (the
    /// navigator only needs the minimum / a membership test).
    func dataMarkedAddresses(in slot: ImageSlot) -> Set<UInt64> {
        var result = Set<UInt64>()
        for (key, override) in addressOverrides
        where key.slot == slot
            && (override.isData || override.isUndefined || !(override.dataShape?.isEmpty ?? true)) {
            result.insert(key.address)
        }
        for literal in analysis(in: slot)?.stringLiterals ?? [] {
            result.insert(literal.address)
        }
        return result
    }

    /// The section whose `[address, address + size)` range contains `virtualAddress`,
    /// if any. Skips zero-fill (BSS) sections, which occupy VA space but have no bytes.
    func section(containing virtualAddress: UInt64, in slot: ImageSlot? = nil) -> SectionSummary? {
        (analysis(in: slot ?? primarySlot)?.sections ?? []).first {
            !$0.isZeroFill && $0.size > 0
                && $0.address <= virtualAddress
                && virtualAddress < $0.address &+ $0.size
        }
    }

    /// The user segment override targeting the section named `name`, if any (the first
    /// when several share a name — the authoring layer keeps the list deduped by name).
    /// A degenerate (empty) override resolves to nil so a cleared rename/rebase never
    /// applies.
    func segmentOverride(for name: String, in slot: ImageSlot? = nil) -> SegmentOverride? {
        // Section names repeat across images (every Mach-O has a __TEXT,__text), so only the
        // requested slot's overrides match this image's sections.
        guard let override = segmentOverrides.first(where: {
            $0.originalName == name && $0.imageSlot == (slot ?? primarySlot)
        }), !override.isEmpty else { return nil }
        return override
    }

    /// The DISPLAY sections: the derived `sections` with each user override applied —
    /// renamed `name` and a rebased `address` (shifted by the override's signed delta).
    /// The underlying `sections`/instructions/xrefs are NEVER mutated, so this is a pure
    /// display projection. Sections without an override pass through unchanged, so the
    /// no-override case is byte-identical to `sections`.
    func effectiveSections(in slot: ImageSlot? = nil) -> [SectionSummary] {
        let s = slot ?? primarySlot
        let sections = analysis(in: s)?.sections ?? []
        guard !segmentOverrides.isEmpty else { return sections }
        return sections.map { section in
            guard let override = segmentOverride(for: section.name, in: s) else { return section }
            var copy = section
            copy.name = override.resolvedName(default: section.name)
            copy.address = override.rebased(section.address)
            return copy
        }
    }

    /// The DISPLAY name for the section named `name`: the user's rename when set, else
    /// `name` itself. Used at every section-name render site.
    func displaySectionName(for name: String) -> String {
        segmentOverride(for: name)?.resolvedName(default: name) ?? name
    }

    /// The DISPLAY address for `virtualAddress`: shifted by the rebase delta of the
    /// section that contains it, when one carries a rebase. Addresses outside every
    /// section (or in a section without a rebase) pass through unchanged. Used to render
    /// a rebased listing/inspector address without disturbing analysis (which keeps the
    /// original addresses).
    func displayAddress(for virtualAddress: UInt64) -> UInt64 {
        guard !segmentOverrides.isEmpty,
              let section = section(containing: virtualAddress),
              let override = segmentOverride(for: section.name),
              override.rebaseDelta != 0
        else { return virtualAddress }
        return override.rebased(virtualAddress)
    }

    /// The instruction `(address, byteWidth)` extents, ascending by address — the
    /// coverage map for the Next-Unexplored gap walk.
    func instructionExtents() -> [(address: UInt64, width: UInt64)] {
        instructions
            .sorted { $0.address < $1.address }
            .map { (address: $0.address, width: $0.byteWidth) }
    }

    /// The half-open `[start, end)` virtual-address spans of the EXECUTABLE sections
    /// (where unexplored code lives). Falls back to the decoded instructions' overall
    /// extent when there is no section table (hand-built / reloaded snapshots), so the
    /// gap walk still has a region to search.
    func executableSpans() -> [(start: UInt64, end: UInt64)] {
        let spans = sections
            .filter { $0.isExecutable && !$0.isZeroFill && $0.size > 0 }
            .map { (start: $0.address, end: $0.address &+ $0.size) }
            .filter { $0.end > $0.start }
        if !spans.isEmpty { return spans }
        guard let first = instructions.map(\.address).min(),
              let lastRow = instructions.max(by: { $0.address < $1.address }) else { return [] }
        let end = lastRow.address &+ lastRow.byteWidth
        guard end > first else { return [] }
        return [(start: first, end: end)]
    }

    /// True when the user forced a function start at `address` (Mark as Procedure).
    func isMarkedAsProcedure(at address: UInt64) -> Bool {
        addressOverrides[primaryKey(address)]?.markAsProcedure ?? false
    }

    /// The user-authored signature override for the function starting at `address`.
    func signatureOverride(at address: UInt64) -> FunctionSignatureOverride? {
        addressOverrides[primaryKey(address)]?.signature
    }

    /// The type applied at `address`, resolved against the catalog by name. Returns
    /// nil when no type is applied or the referenced name no longer exists (a
    /// deleted/renamed type degrades to no-type rather than dangling).
    func appliedType(at address: UInt64) -> TypeDefinition? {
        guard let name = addressOverrides[primaryKey(address)]?.appliedTypeName, !name.isEmpty else { return nil }
        return typeDefinitions.first { $0.name == name }
    }

    /// All function signature overrides keyed by function start address. Threaded
    /// into the pseudocode printer (address-keyed, NOT name-keyed: signatures are
    /// per-function and same-named functions must not collide).
    func functionSignatureOverrides(in slot: ImageSlot) -> [UInt64: FunctionSignatureOverride] {
        baseFunctionSignatureOverrides(in: slot)
    }

    /// Base authority only. Neither C1, direct-call contracts, nor proof roots may
    /// recursively consume S1-derived signatures.
    private func baseFunctionSignatureOverrides(in slot: ImageSlot) -> [UInt64: FunctionSignatureOverride] {
        var map = Dictionary(uniqueKeysWithValues: importedPrototypes.compactMap { key, value in
            key.slot == slot ? (key.address, value) : nil
        })
        for (key, override) in addressOverrides where key.slot == slot {
            if let signature = override.signature, signature.hasAnalysisEffect {
                map[key.address] = signature
            }
        }
        return map
    }

    /// Complete per-selected-image proof, exposed for diagnostics without a new
    /// global cache or parsing rendered output. Cancellation never publishes.
    func slotTypedPrototypeReport(in slot: ImageSlot, compute: Bool,
                                  checkpoint: () -> Bool = { !Task.isCancelled }) -> SlotTypedPrototypeBinding.Report? {
        typedPrototypeImageOutcome(in: slot, compute: compute, checkpoint: checkpoint).report?.slots
    }

    func closedWorldCallerReturnReport(in slot: ImageSlot, compute: Bool,
                                      checkpoint: () -> Bool = { !Task.isCancelled }) -> ReturnContractTable.Report? {
        returnContractTable(in: slot, compute: compute, checkpoint: checkpoint)?.report
    }

    func returnContractTable(in slot: ImageSlot, compute: Bool,
                             checkpoint: () -> Bool = { !Task.isCancelled }) -> ReturnContractTable? {
        if compute { _ = imageWideIndirectCalls(in: slot, compute: true, checkpoint: checkpoint) }
        let key = IndirectCallResolutionMemo.Key(snapshotID: indirectCallSnapshotID, slot: slot)
        return indirectCallMemo.returnContractTable(for: key)
    }

    private func typedPrototypeImageOutcome(
        in slot: ImageSlot, compute: Bool,
        checkpoint: () -> Bool = { !Task.isCancelled },
        admitInstructions: ([InstructionRow]) -> Bool = { _ in true },
        builtFunctionCache: SnapshotBuiltFunctionCache? = nil
    ) -> SlotPrototypeMemo.Outcome {
        let key = IndirectCallResolutionMemo.Key(snapshotID: indirectCallSnapshotID, slot: slot)
        guard compute else { return slotPrototypeMemo.outcome(for: key) }
        return slotPrototypeMemo.outcome(for: key) {
            guard checkpoint(), !Task.isCancelled else { return .interrupted }
            guard let analysis = analysis(in: slot),
                  analysis.functions.count <= Self.maximumImageWideIndirectCallFunctions else { return .unavailable }
            let base = baseFunctionSignatureOverrides(in: slot)
            let imported = Dictionary(uniqueKeysWithValues: importedPrototypes.compactMap { key, value in
                key.slot == slot ? (key.address, value) : nil
            })
            let tables = resolvedJumpTables(in: slot)
            let strings = constantStrings(in: slot)
            let authored = authoredCallSignaturesByTarget(in: slot)
            let printer = PseudocodePrinter()
            var built: [MacIRFunction] = []
            for summary in analysis.functions {
                guard checkpoint(), !Task.isCancelled else { return .interrupted }
                guard let target = pseudocodeTarget(selectedAddress: summary.startAddress, in: slot),
                      target.function.id == summary.id else { return .unavailable }
                guard admitInstructions(target.instructions) else { return .interrupted }
                let buildKey = SnapshotBuiltFunctionCache.Key(
                    snapshotID: indirectCallSnapshotID, slot: slot,
                    startAddress: summary.startAddress,
                    functionName: displayName(at: summary.startAddress, in: slot, default: summary.name),
                    jumpTables: tables, objcSelectors: analysis.objcSelectors, constantStrings: strings,
                    signatureOverrides: base, authoredCallSignaturesByTarget: authored,
                    types: typeDefinitions, instructions: target.instructions)
                if let function = builtFunctionCache?.function(for: buildKey) {
                    built.append(function)
                } else {
                    let perfBuild = MacScopePerfPhaseClock.begin("prerequisite.build", function: summary.startAddress)
                    let function = printer.buildFunction(
                        functionName: displayName(at: summary.startAddress, in: slot, default: summary.name),
                        startAddress: summary.startAddress, jumpTables: tables,
                        objcSelectors: analysis.objcSelectors, constantStrings: strings,
                        signatureOverrides: base, authoredCallSignaturesByTarget: authored,
                        types: typeDefinitions, explicitCFGEnabled: buildKey.explicitCFGEnabled,
                        ssaEnabled: buildKey.ssaEnabled, instructions: target.instructions)
                    MacScopePerfPhaseClock.end(perfBuild)
                    builtFunctionCache?.record(function, for: buildKey)
                    built.append(function)
                }
            }
            guard checkpoint(), !Task.isCancelled else { return .interrupted }
            let slots = SlotTypedPrototypeBinding.analyze(builtFunctions: built,
                originalInstructions: analysis.instructions,
                functionStarts: Set(analysis.functions.map(\.startAddress)),
                importedPrototypes: imported, effectiveSignatures: base,
                types: typeDefinitions,
                headerLayoutDefinitions: headerLayoutEvidence.values.sorted { $0.name < $1.name })
            // A caller-only closed-world certificate does NOT establish the slot
            // callee's separate code/data escape obligation. Missing proof is a
            // real, recorded refusal, never an empty escape inventory.
            let rawCalls = Dictionary(grouping: analysis.instructions.filter { $0.mnemonic.lowercased() == "bl" }, by: \.address)
            let callerFunctions = built.map { function in
                var copy = function
                copy.instructions = function.instructions.map { instruction in
                    guard instruction.source.mnemonic == "bl" else { return instruction }
                    var copy = instruction
                    let matches = rawCalls[instruction.source.address] ?? []
                    copy.source.operands = matches.count == 1 ? matches[0].operands : ""
                    return copy
                }
                return copy
            }
            let callers = MacIRConfiguration.returnContractEnabled
                ? MacIRCallerReturnEvidence.ClosedWorldReport()
                : MacIRCallerReturnEvidence.collectClosedWorld(analysis: analysis, functions: callerFunctions, effectiveSignatures: base)
            guard checkpoint(), !Task.isCancelled else { return .interrupted }
            return .completed(SlotPrototypeMemo.Report(slots: slots, callers: callers))
        }
    }

    /// The user's switch-hint declaration for the dispatching `br` at `address`.
    func switchHint(at address: UInt64) -> SwitchHintOverride? {
        guard let hint = addressOverrides[primaryKey(address)]?.switchHint, !hint.isEmpty else { return nil }
        return hint
    }

    /// The user's register renames (register-id → display-name) for the procedure starting
    /// at `address`. Empty when none are set. Threaded into the pseudocode printer so the
    /// renamed name replaces the raw register at every occurrence in that procedure's body.
    func registerNameOverrides(forProcedureAt address: UInt64, in slot: ImageSlot) -> [String: String] {
        guard let names = addressOverrides[key(address, in: slot)]?.registerNames else { return [:] }
        return AddressOverride.prunedRegisterNames(names)
    }

    /// DP04 C1: the user's stack local edits for the procedure starting at `address`, keyed by
    /// `MacIRStackStorage.authoringKey`. Orphaned keys are included.
    func stackLocalOverrides(forProcedureAt address: UInt64, in slot: ImageSlot) -> [String: StackLocalOverride] {
        guard let locals = addressOverrides[key(address, in: slot)]?.stackLocals else { return [:] }
        return AddressOverride.prunedStackLocals(locals)
    }

    /// Primary-image compatibility wrapper for scripting, goldens, and legacy callers.
    func registerNameOverrides(forProcedureAt address: UInt64) -> [String: String] {
        registerNameOverrides(forProcedureAt: address, in: primarySlot)
    }

    /// The user's LOCAL LABEL at `address` (a name scoped to the enclosing procedure), or
    /// nil when unset. Distinct from `displayName`, which resolves the GLOBAL symbol name.
    func localLabel(at address: UInt64) -> String? {
        guard let label = addressOverrides[primaryKey(address)]?.localLabel, !label.isEmpty else { return nil }
        return label
    }

    /// All user local labels keyed by address (procedure-scoped names). Threaded into the
    /// pseudocode printer and merged into the listing's label rows by
    /// `mergeLocalLabels(into:functionStarts:in:)`.
    func localLabels(in slot: ImageSlot) -> [UInt64: String] {
        var map: [UInt64: String] = [:]
        for (key, override) in addressOverrides where key.slot == slot {
            if let label = override.localLabel, !label.isEmpty { map[key.address] = label }
        }
        return map
    }

    /// The listing label-row projection of LOCAL LABELS: a local label names its address
    /// (and branch operands targeting it) unless that address is a function start or carries
    /// a user GLOBAL rename (`customName`), which keep precedence. It overrides a bare
    /// parsed symbol name. Shared by the listing builder and its uncached test oracle.
    func mergeLocalLabels(
        into names: inout [UInt64: String],
        functionStarts: Set<UInt64>,
        in slot: ImageSlot
    ) {
        for (address, label) in localLabels(in: slot) {
            guard !functionStarts.contains(address) else { continue }
            if let customName = addressOverrides[key(address, in: slot)]?.customName,
               !customName.isEmpty {
                continue
            }
            names[address] = label
        }
    }

    /// A byte reader over `hexBytes`, mapping a virtual address linearly from the
    /// first instruction's address (the same convention `DataInspectorReading`
    /// uses). Returns nil for any read that falls outside the loaded bytes — so a
    /// table that lives beyond the captured window simply doesn't resolve.
    /// A virtual-address byte reader used for hint resolution and the data inspector.
    ///
    /// The CORRECT mapping goes through the SECTION TABLE: `section.fileOffset` is
    /// slice-relative and `imageBytes` is the full slice, so a virtual address maps to
    /// `imageBytes[section.fileOffset + (va - section.address)]` (exactly how `read-bytes`
    /// reads). The earlier mapping `hexBytes[va - firstInstruction]` was WRONG on any real
    /// binary: `hexBytes` is the slice's leading window (header-first), so the first
    /// instruction is NOT at offset 0 — it read header bytes instead of the target.
    ///
    /// Falls back to the legacy linear mapping over `hexBytes` only for hand-built
    /// windows without retained artifact bytes. A real restored image whose section
    /// table is not ready has no readable VA span until mapping authority is rebuilt.
    /// Lane AJ: true while a restored image holds its bytes but not yet its section map. Packages
    /// persist the image bytes and deliberately omit loader-derived products (sections, Mach-O
    /// metadata); `WorkspaceStore.rehydrateLoadedImages` rebuilds them after reopen. Until that
    /// lands, `hexByteReader` and Address Detail cannot map a virtual address, so the inspector
    /// should say the map is being restored rather than that the selection is outside the bytes.
    func isAwaitingSectionRehydration(in slot: ImageSlot? = nil) -> Bool {
        guard let analysis = analysis(in: slot ?? primarySlot) else { return false }
        return !analysis.imageBytes.isEmpty && analysis.sections.isEmpty && analysis.machOMetadata == nil
    }

    func hexByteReader(in slot: ImageSlot? = nil) -> (_ virtualAddress: UInt64, _ count: Int) -> Data? {
        let slot = slot ?? primarySlot
        let analysis = analysis(in: slot)
        let image = analysis?.imageBytes ?? Data()
        let sections = analysis?.sections ?? []
        let hex = analysis?.hexBytes ?? Data()
        let linearBase = analysis?.instructions.first?.address
        let hasRetainedImage = !image.isEmpty
        let mappings = imageByteMappings(in: slot)
        let overlay = try? BytePatchOverlay(
            patches: patches(in: slot), mappings: hasRetainedImage ? mappings : nil
        )
        return { virtualAddress, count in
            guard count > 0, let overlay else { return nil }
            if hasRetainedImage {
                // A restoring real image without sections is not a linear fixture:
                // its raw prefix contains the header, not its first instruction.
                guard !sections.isEmpty, let range = FileAddressMapping.resolvedFileRange(
                    forVirtualAddress: virtualAddress, count: count, in: mappings
                ), range.upperBound <= image.count else { return nil }
                let start = image.startIndex + range.lowerBound
                let raw = image.subdata(in: start..<(start + count))
                return overlay.applying(to: raw, at: virtualAddress)
            }
            // Legacy fixtures without section authority retain their explicit linear window.
            guard let linearBase, virtualAddress >= linearBase else { return nil }
            let delta = virtualAddress - linearBase
            guard let offset = Int(exactly: delta), offset <= hex.count,
                  count <= hex.count - offset else { return nil }
            let start = hex.startIndex + offset
            return overlay.applying(to: hex.subdata(in: start..<(start + count)), at: virtualAddress)
        }
    }

    /// The auto-recovered jump tables MERGED with the user's switch hints. A hint
    /// that resolves (its declared table bytes are readable) fills or overrides the
    /// `br`'s entry; a hint that cannot be resolved leaves the auto entry (if any)
    /// untouched. Threaded into the pseudocode printer in place of the raw
    /// `jumpTables` so manual declarations drive the `switch` reconstruction.
    func resolvedJumpTables(in slot: ImageSlot) -> [UInt64: [UInt64]] {
        var hasHints = false
        for (key, override) in addressOverrides
        where key.slot == slot && !(override.switchHint?.isEmpty ?? true) {
            _ = key
            hasHints = true
            break
        }
        let recovered = analysis(in: slot)?.jumpTables ?? [:]
        guard hasHints else { return recovered }

        var result = recovered
        let reader = hexByteReader(in: slot)
        for (key, override) in addressOverrides where key.slot == slot {
            let address = key.address
            guard let hint = override.switchHint, !hint.isEmpty else { continue }
            if let targets = hint.resolveTargets(readBytes: reader), !targets.isEmpty {
                result[address] = targets
            }
        }
        return result
    }

    /// Renders an instruction's raw `bytes` (a space-separated hex string such as
    /// "ff 83 00 d1") as an assembler data directive for a data-marked row: a
    /// little-endian `.long` word for the canonical 4-byte ARM64 width, otherwise a
    /// `.byte` list. Returns `(mnemonic, operands)` for the listing's two columns.
    static func dataDirective(forBytes bytes: String) -> (mnemonic: String, operands: String) {
        let values = bytes
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { UInt8($0, radix: 16) }
        guard !values.isEmpty else { return (".long", "0x00000000") }
        if values.count == 4 {
            var word: UInt32 = 0
            for (index, byte) in values.enumerated() {
                word |= UInt32(byte) << (8 * index) // little-endian
            }
            return (".long", "0x" + String(format: "%08x", word))
        }
        return (".byte", values.map { "0x" + String(format: "%02x", $0) }.joined(separator: ", "))
    }

    /// Renders the assembler directive for a user-authored DATA SHAPE at `address`:
    ///
    /// - `.array`   → `.long[16]` style: a typed array directive naming the element
    ///                base type and the count (e.g. `int32_t[16]`).
    /// - `.alignment` → `.balign 8` (or `.align 0` when already aligned).
    /// - `.string`  → `.asciz "..."` for a NUL-terminated C string, `.ascii "..."` for a
    ///                fixed-length buffer. The text is read from the loaded bytes via
    ///                `readBytes` and C-escaped; an unreadable span renders a placeholder.
    ///
    /// Pure and GUI-free: `readBytes` is the snapshot's `hexByteReader()` (or any
    /// virtual-address reader) so the renderer can be unit-tested without a binary.
    static func dataDirective(
        forShape shape: DataShapeOverride,
        at address: UInt64,
        encoding: StringDisplayEncoding = .default,
        readBytes: (_ virtualAddress: UInt64, _ count: Int) -> Data?
    ) -> (mnemonic: String, operands: String) {
        switch shape.kind {
        case .array:
            let count = min(max(shape.elementCount, 0), DataShapeOverride.maxElementCount)
            let element = (shape.elementType?.isEmpty == false) ? shape.elementType! : "byte"
            let signature = "\(element)[\(count)]"
            // Legacy / no per-element format requested: render the type signature only.
            guard let format = shape.elementDisplayFormat else {
                return (".array", signature)
            }
            // Materialize each element's value in the chosen format. Bytes are read once
            // for the whole array span; an unreadable span degrades to the bare signature
            // rather than rendering wrong values.
            let values = arrayElementValues(forShape: shape, at: address, count: count, format: format, readBytes: readBytes)
            guard !values.isEmpty else { return (".array", signature) }
            return (".array", "\(signature) { \(values.joined(separator: ", ")) }")
        case .alignment:
            let boundary = min(max(shape.alignment, 1), DataShapeOverride.maxAlignment)
            let padding = shape.paddingSpan(from: address)
            return (".balign", "\(boundary)" + (padding == 0 ? "  ; already aligned" : "  ; pad \(padding)"))
        case .string:
            let directive = shape.isNullTerminated ? ".asciz" : ".ascii"
            let text = readCString(at: address, shape: shape, encoding: encoding, readBytes: readBytes)
            return (directive, "\"\(text)\"")
        }
    }

    /// Reads and C-escapes the bytes of a string shape for display. For a
    /// NUL-terminated shape it scans up to the first NUL (capped); for a fixed shape it
    /// reads exactly `stringLength` bytes. Returns "?" placeholder when the bytes are
    /// unavailable (a moved/closed source or a span past the loaded image) so a
    /// truncated read never renders a misleading literal.
    static func readCString(
        at address: UInt64,
        shape: DataShapeOverride,
        encoding: StringDisplayEncoding = .default,
        readBytes: (_ virtualAddress: UInt64, _ count: Int) -> Data?
    ) -> String {
        let maxScan: Int
        if shape.isNullTerminated {
            maxScan = 4096 // display cap; real C strings rendered here are short
        } else {
            maxScan = min(max(shape.stringLength, 0), DataShapeOverride.maxStringLength)
        }
        guard maxScan > 0 else { return "" }
        // The reader requires the FULL requested count to be in bounds, so a string at
        // (or near) the end of a section/image would fail a fixed `maxScan` read and fall
        // to "?". Back off until a read succeeds, so a short-but-valid span still renders
        // (the NUL terminator / fixed length is honored by the decode loop below).
        var span = maxScan
        var data: Data?
        while span > 0 {
            if let read = readBytes(address, span) { data = read; break }
            span /= 2
        }
        guard let data, !data.isEmpty else { return "?" }
        // The render itself is delegated to the chosen text-encoding so the SAME bytes
        // reinterpret under the user's preference. `.utf8` reproduces the historical
        // C-escape renderer byte-for-byte, so an un-configured app is unchanged.
        return encoding.render(bytes: [UInt8](data), stopAtNUL: shape.isNullTerminated)
    }

    /// Materializes the per-element values of a Make-Array shape, each rendered with the
    /// shape's chosen `format` (hex/dec/char/octal/binary/…) via the shared
    /// `OperandFormat` formatter — the same pure value→string path the operand-format
    /// override uses, so the matrix is identical in both places.
    ///
    /// Each element is read little-endian as a `UInt64` magnitude across its
    /// type-derived byte width (capped at 8). Signedness comes from the element type:
    /// a signed type whose top bit is set yields `(negative: true, magnitude: |value|)`
    /// so `signed decimal`/`two's-complement hex` print the negative reading, while an
    /// unsigned type always presents a non-negative magnitude. Pure and GUI-free.
    ///
    /// Returns an empty array (the caller then falls back to the bare type signature)
    /// when the element width is unknown/oversized or the array bytes are unreadable —
    /// never a wrong value. A partially-readable tail renders only the readable head.
    static func arrayElementValues(
        forShape shape: DataShapeOverride,
        at address: UInt64,
        count: Int,
        format: OperandFormat,
        readBytes: (_ virtualAddress: UInt64, _ count: Int) -> Data?
    ) -> [String] {
        let width = shape.elementWidth
        // Only fixed primitive widths (1/2/4/8) decode to a scalar value; an unknown
        // or oversized element falls back to the signature.
        guard width == 1 || width == 2 || width == 4 || width == 8, count > 0 else { return [] }
        let totalBytes = width &* count
        guard let data = readBytes(address, totalBytes), data.count >= width else { return [] }
        let bytes = [UInt8](data)
        let signed = isSignedElementType(shape.elementType)
        let topBit: UInt64 = width >= 8 ? (UInt64(1) << 63) : (UInt64(1) << (width * 8 - 1))

        var rendered: [String] = []
        rendered.reserveCapacity(count)
        var offset = 0
        for _ in 0..<count {
            guard offset + width <= bytes.count else { break } // only the readable head
            var raw: UInt64 = 0
            for index in 0..<width {
                raw |= UInt64(bytes[offset + index]) << (8 * index) // little-endian
            }
            offset += width

            let negative: Bool
            let magnitude: UInt64
            if signed, (raw & topBit) != 0 {
                negative = true
                // Two's-complement magnitude within the element width, overflow-safe.
                let mask: UInt64 = width >= 8 ? .max : ((UInt64(1) << (width * 8)) - 1)
                magnitude = ((~raw) &+ 1) & mask
            } else {
                negative = false
                magnitude = raw
            }
            rendered.append(format.renderValue(negative: negative, magnitude: magnitude))
        }
        return rendered
    }

    /// Whether an array element's base type is signed (drives the negative reading of a
    /// top-bit-set value). Unknown/empty types and pointers are treated as unsigned.
    private static func isSignedElementType(_ type: String?) -> Bool {
        let normalized = (type ?? "").trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "int8_t", "int16_t", "int32_t", "int64_t",
             "char", "short", "int", "long", "ssize_t", "intptr_t":
            return true
        default:
            return false
        }
    }

    /// Maps each function's parsed name to its user display name, for the subset
    /// of functions that carry a name override. Pseudocode emits call targets as
    /// the callee's symbol name (which equals the function's parsed name), so this
    /// parsed-name → display-name map lets the printer rename call expressions and
    /// the metadata "calls" list without threading addresses through the IR.
    /// The function whose body the pseudocode view should render for the current
    /// selection — the function enclosing `selectedAddress`, else the first
    /// discovered function — together with just that function's instructions
    /// (filtered to its address range) so the printer shows one procedure instead
    /// of the whole text section. Returns nil when there are no functions.
    ///
    /// Containment mirrors the half-open `[start, end)` rule used across the app
    /// (a degenerate function with `end <= start` owns only its `startAddress`),
    /// with the same lowest-`startAddress` fallback as the rename resolver.
    func pseudocodeTarget(
        selectedAddress: UInt64?,
        in slot: ImageSlot
    ) -> (function: FunctionSummary, instructions: [InstructionRow])? {
        let analysis = analysis(in: slot)
        let functions = analysis?.functions ?? []
        let resolved = selectedAddress.flatMap { enclosingFunction(for: $0, in: slot) } ?? functions.first
        guard let function = resolved else { return nil }
        let excludedAddresses = codeExcludedAddresses(in: slot)
        let body = (analysis?.exportInstructionIndex().instructions(
            start: function.startAddress, end: function.endAddress
        ) ?? []).filter { !excludedAddresses.contains($0.address) }
        // Name direct call targets (`bl 0x100000a04` → `bl _objc_msgSend$alpha`) so the printer
        // emits named callees. Calls only: intra-function branch targets must stay addresses for
        // MacIR's structurer.
        let symbolizer = BranchTargetSymbolizer(namesByAddress: branchTargetNames(
            in: slot,
            restrictedTo: WorkspaceSnapshot.directCallTargets(in: body)
        ))
        return (function, body.map { symbolizer.symbolized($0, callsOnly: true) })
    }

    /// Primary-image compatibility wrapper for deterministic non-interactive consumers.
    func pseudocodeTarget(selectedAddress: UInt64?) -> (function: FunctionSummary, instructions: [InstructionRow])? {
        pseudocodeTarget(selectedAddress: selectedAddress, in: primarySlot)
    }

    /// The function containing `address`: an exact range match for a normal function, an
    /// exact-start match for a zero-width function (one whose end collapsed to its start),
    /// else the nearest preceding function start. The single canonical address→function
    /// resolver — reused by the scripting command surface so it matches the GUI exactly.
    func enclosingFunction(for address: UInt64, in slot: ImageSlot) -> FunctionSummary? {
        let functions = analysis(in: slot)?.functions ?? []
        return functions.first { function in
            if function.endAddress > function.startAddress {
                return address >= function.startAddress && address < function.endAddress
            }
            return address == function.startAddress
        } ?? functions.last { $0.startAddress <= address }
    }

    /// Primary-image compatibility wrapper for bare-address callers.
    func enclosingFunction(for address: UInt64) -> FunctionSummary? {
        enclosingFunction(for: address, in: primarySlot)
    }

    // MARK: - Cross-reference queries

    /// All cross-references whose target is `address` (references INTO here).
    func xrefs(to address: UInt64) -> [XRef] {
        xrefs.filter { $0.to == address }
    }

    /// All cross-references originating at `address` (references FROM here).
    func xrefs(from address: UInt64) -> [XRef] {
        xrefs.filter { $0.from == address }
    }

    /// Direct `bl` callers of `function`: deduplicated call edges whose target
    /// lands inside the function's address range.
    func callers(of function: FunctionSummary) -> [XRef] {
        Self.dedupedByEndpoints(xrefs.filter { $0.kind == XRefKind.call && functionRange(function).contains($0.to) })
    }

    /// Direct `bl` callees of `function`: deduplicated call edges originating
    /// inside the function's address range.
    func callees(of function: FunctionSummary) -> [XRef] {
        Self.dedupedByEndpoints(xrefs.filter { $0.kind == XRefKind.call && functionRange(function).contains($0.from) })
    }

    /// A function's half-open address range, treating a zero-width function (end collapsed
    /// to start) as a single byte so it still contains its own start. The canonical
    /// function-range used by `callers`/`callees` and the scripting command surface.
    func functionRange(_ function: FunctionSummary) -> Range<UInt64> {
        let upper = function.endAddress > function.startAddress ? function.endAddress : function.startAddress &+ 1
        return function.startAddress..<upper
    }

    private static func dedupedByEndpoints(_ edges: [XRef]) -> [XRef] {
        var seen = Set<[UInt64]>()
        return edges.filter { seen.insert([$0.from, $0.to]).inserted }
    }

    /// A human label for a referenced address: a function name (honoring renames),
    /// a quoted string literal, an Objective-C selector, an export/symbol name, an
    /// enclosing-function offset, or a hex fallback. Recomputed at call time because
    /// selector names live in the non-persisted `objcSelectors`.
    func symbolizedLabel(for address: UInt64) -> String {
        if let function = functions.first(where: { $0.startAddress == address }) {
            return displayName(at: address, default: function.name)
        }
        if let string = stringLiterals.first(where: { $0.address == address }) {
            let value = string.value
            let trimmed = value.count > 40 ? String(value.prefix(40)) + "…" : value
            return "\"\(trimmed)\""
        }
        if let selector = objcSelectors[address] {
            return "@selector(\(selector))"
        }
        if let export = exports.first(where: { $0.address == address }) {
            return export.name
        }
        if let symbol = symbols.first(where: { $0.address == address }) {
            return symbol.name
        }
        // Only label an offset when the address is STRICTLY inside a function's real
        // range (not the greedy enclosingFunction fallback, which would mislabel a
        // far-off data address as "lastFunction+huge").
        if let function = functions.first(where: {
            $0.endAddress > $0.startAddress && address > $0.startAddress && address < $0.endAddress
        }) {
            let base = displayName(at: function.startAddress, default: function.name)
            return "\(base)+0x" + String(address - function.startAddress, radix: 16)
        }
        return address.hexAddress
    }

    /// True when `address` falls within the loaded byte window (so the hex view can
    /// show it) even if no instruction is decoded there. Lets Go-To distinguish a
    /// reachable data/padding address from one outside the binary.
    func containsLoadedAddress(_ address: UInt64) -> Bool {
        guard let base = instructions.first?.address, address >= base else { return false }
        return address - base < UInt64(hexBytes.count)
    }

    /// WS-8: whether `address` (an image-VA) belongs to `slot`'s image — a decoded instruction there
    /// OR inside one of its mapped (non-zero-fill) sections. Slot-scoped counterpart of the flat
    /// (primary) check above; the basis for multi-image Go-to / collision resolution. Uses the section
    /// extent (not the bounded hex window) so a data address anywhere in the image counts as navigable.
    func containsLoadedAddress(_ address: UInt64, in slot: ImageSlot) -> Bool {
        guard let analysis = analysis(in: slot) else { return false }
        if analysis.instructions.contains(where: { $0.address == address }) { return true }
        return analysis.sections.contains {
            !$0.isZeroFill && $0.address <= address && address < $0.address &+ $0.size
        }
    }

    /// Resolves a function / export / symbol NAME to its address for Go-To-by-name.
    /// Matches case-insensitively on a function's display (renamed) or parsed name,
    /// then exports and symbols, tolerating an omitted leading underscore so "main"
    /// finds "_main".
    func address(forSymbolName name: String) -> UInt64? {
        address(forSymbolName: name, in: primarySlot)
    }

    /// Image-qualified Go-To name resolution. The legacy overload above remains primary-bound;
    /// interactive lookup must never resolve a primary name and reinterpret its VA in a sibling.
    func address(forSymbolName name: String, in slot: ImageSlot) -> UInt64? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let analysis = analysis(in: slot) else { return nil }
        func matches(_ candidate: String) -> Bool {
            if candidate.caseInsensitiveCompare(query) == .orderedSame { return true }
            let strippedCandidate = candidate.hasPrefix("_") ? String(candidate.dropFirst()) : candidate
            let strippedQuery = query.hasPrefix("_") ? String(query.dropFirst()) : query
            return !strippedQuery.isEmpty && strippedCandidate.caseInsensitiveCompare(strippedQuery) == .orderedSame
        }
        if let function = analysis.functions.first(where: {
            let authoredName = addressOverrides[
                ImageAddress(slot: slot, address: $0.startAddress)
            ]?.customName
            return matches(authoredName ?? $0.name) || matches($0.name)
        }) {
            return function.startAddress
        }
        if let export = analysis.exports.first(where: { matches($0.name) }) {
            return export.address
        }
        if let symbol = analysis.symbols.first(where: { $0.address != nil && matches($0.name) }) {
            return symbol.address
        }
        return nil
    }

    func functionNameOverrides(in slot: ImageSlot) -> [String: String] {
        // The map is keyed by parsed name (call targets are emitted as symbols),
        // which collapses the address dimension the overrides are otherwise keyed
        // on. Drop any name shared by two or more functions: without the address
        // we can't tell which callee a renamed-but-ambiguous symbol refers to, and
        // relabeling every same-named call site would be wrong. Unique names — the
        // overwhelmingly common case — are unaffected.
        let functions = analysis(in: slot)?.functions ?? []
        var nameCounts: [String: Int] = [:]
        for function in functions {
            nameCounts[function.name, default: 0] += 1
        }

        var map: [String: String] = [:]
        for function in functions where nameCounts[function.name] == 1 {
            let display = displayName(at: function.startAddress, in: slot, default: function.name)
            if display != function.name {
                map[function.name] = display
            }
        }
        return map
    }

    /// Primary-image compatibility wrapper for scripting, goldens, and default exports.
    func functionNameOverrides() -> [String: String] {
        functionNameOverrides(in: primarySlot)
    }

    /// Builds one slot-coherent pseudocode handoff. A missing function intentionally falls
    /// back to that same image's full instruction list for the interactive `_main` view.
    func pseudocodeRenderInput(
        selectedAddress: UInt64?,
        in slot: ImageSlot
    ) -> PseudocodeRenderInput {
        let analysis = analysis(in: slot)
        let target = pseudocodeTarget(selectedAddress: selectedAddress, in: slot)
        return makePseudocodeRenderInput(target: target, analysis: analysis, in: slot)
    }

    /// The largest image whose typed (image-wide) slot resolution is computed; past it only
    /// function-local resolution is sound.
    static let maximumImageWideIndirectCallFunctions = 4_096

    /// Only complete image-wide reports can enable typed resolutions. Rendering only reads;
    /// explicit headless/export callers may compute. Cancellation and the cap fail closed.
    func imageWideIndirectCalls(
        in slot: ImageSlot, compute: Bool,
        checkpoint: () -> Bool = { !Task.isCancelled },
        admitInstructions: ([InstructionRow]) -> Bool = { _ in true },
        inspectFunctions: ([MacIRFunction]) -> Void = { _ in }
    ) -> MacIRIndirectTargetResolution.Report? {
        guard let analysis = analysis(in: slot),
              analysis.functions.count <= Self.maximumImageWideIndirectCallFunctions else { return nil }
        let key = IndirectCallResolutionMemo.Key(snapshotID: indirectCallSnapshotID, slot: slot)
        guard compute else { return indirectCallMemo.report(for: key) }
        guard indirectCallMemo.beginAttempt(for: key) else {
            return Task.isCancelled ? nil : indirectCallMemo.report(for: key)
        }
        guard !Task.isCancelled else { return nil }
        // The claim outlives interruption; prerequisites run without the indirect memo lock.
        // Scope the phase to checkpoints so printer work has no extra TaskLocal stack frames.
        let builtFunctionCache = SnapshotBuiltFunctionCache()
        let prerequisite = typedPrototypeImageOutcome(in: slot, compute: true, checkpoint: {
            IndirectCallResolutionMemo.$checkpointPhase.withValue(.typedPrototypePrerequisite) {
                checkpoint()
            }
        }, admitInstructions: admitInstructions, builtFunctionCache: builtFunctionCache)
        if case .interrupted = prerequisite { return nil }
        return indirectCallMemo.completeAttempt(for: key) {
            guard checkpoint() else { return nil }
            let printer = PseudocodePrinter()
            let signatures = baseFunctionSignatureOverrides(in: slot)
            guard checkpoint() else { return nil }
            let jumpTables = resolvedJumpTables(in: slot)
            let strings = constantStrings(in: slot)
            guard checkpoint() else { return nil }
            let authored = authoredCallSignaturesByTarget(in: slot)
            var built: [MacIRFunction] = []
            built.reserveCapacity(analysis.functions.count)
            for summary in analysis.functions {
                guard !Task.isCancelled, checkpoint(),
                      let target = pseudocodeTarget(selectedAddress: summary.startAddress, in: slot),
                      target.function.id == summary.id,
                      admitInstructions(target.instructions), checkpoint() else { return nil }
                let buildKey = SnapshotBuiltFunctionCache.Key(
                    snapshotID: indirectCallSnapshotID, slot: slot,
                    startAddress: summary.startAddress,
                    functionName: displayName(at: summary.startAddress, in: slot, default: summary.name),
                    jumpTables: jumpTables, objcSelectors: analysis.objcSelectors, constantStrings: strings,
                    signatureOverrides: signatures, authoredCallSignaturesByTarget: authored,
                    types: typeDefinitions, instructions: target.instructions)
                if let function = builtFunctionCache.function(for: buildKey) {
                    built.append(function)
                } else {
                    let perfBuild = MacScopePerfPhaseClock.begin("image.build", function: summary.startAddress)
                    let function = printer.buildFunction(
                        functionName: displayName(at: summary.startAddress, in: slot, default: summary.name),
                        startAddress: summary.startAddress, jumpTables: jumpTables,
                        objcSelectors: analysis.objcSelectors, constantStrings: strings,
                        signatureOverrides: signatures, authoredCallSignaturesByTarget: authored,
                        types: typeDefinitions, explicitCFGEnabled: buildKey.explicitCFGEnabled,
                        ssaEnabled: buildKey.ssaEnabled, instructions: target.instructions)
                    MacScopePerfPhaseClock.end(perfBuild)
                    builtFunctionCache.record(function, for: buildKey)
                    built.append(function)
                }
            }
            guard !Task.isCancelled, checkpoint() else { return nil }
            // Read-only diagnostics can inspect the exact pre-C2 IR without rebuilding it.
            inspectFunctions(built)
            let report = MacIRIndirectTargetResolution.resolve(functions: built,
                functionStarts: Set(analysis.functions.map(\.startAddress)))
            guard !Task.isCancelled, checkpoint() else { return nil }
            // pseudocodeTarget symbolizes BL operands for printing. Restore their
            // original address authority only in the caller-evidence copy: names
            // (including duplicate local/import names) cannot identify a callee.
            let rawCalls = Dictionary(grouping: analysis.instructions.filter { $0.mnemonic.lowercased() == "bl" },
                                      by: \.address)
            let callerFunctions = built.map { function in
                var copy = function
                copy.instructions = function.instructions.map { instruction in
                    guard instruction.source.mnemonic == "bl" else { return instruction }
                    var copy = instruction
                    let rows = rawCalls[instruction.source.address] ?? []
                    copy.source.operands = rows.count == 1 ? rows[0].operands : ""
                    return copy
                }
                return copy
            }
            // Reuse the frozen image lift. Only unique numeric branch targets at
            // unique same-image function starts establish own-call identity.
            let ownStarts = Set(Dictionary(grouping: built, by: \.startAddress)
                .filter { $0.value.count == 1 }.keys)
            var ownCalls: Set<UInt64> = []
            for function in callerFunctions {
                for instruction in function.instructions {
                    guard instruction.source.mnemonic.lowercased() == "bl",
                          case let .call(frame, _) = instruction.operation,
                          frame.controlInputs.indirectTarget == nil else { continue }
                    let operand = instruction.source.operands.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard operand.hasPrefix("0x"),
                          let target = UInt64(operand.dropFirst(2), radix: 16),
                          ownStarts.contains(target) else { continue }
                    ownCalls.insert(instruction.source.address)
                }
            }
            // Diagnostic tails also need original address authority, not display names.
            let ownRawRows = Dictionary(grouping: analysis.instructions, by: \.address)
            let ownBodies = built.map { function in
                var copy = function
                copy.instructions = function.instructions.map { instruction in
                    var row = instruction
                    let originals = ownRawRows[instruction.source.address] ?? []
                    row.source.operands = originals.count == 1 ? originals[0].operands : ""
                    return row
                }
                return copy
            }
            let ownReturns = MacIROwnCalleeReturnEvidence.collect(functions: ownBodies)
            let callerReturns = MacIRCallerReturnEvidence.collect(functions: callerFunctions)
            guard !Task.isCancelled, checkpoint() else { return nil }
            let directCallSources = ownRawRows.values.flatMap { $0 }
                .filter { ["bl", "b"].contains($0.mnemonic.lowercased()) }.map {
                MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                    mnemonic: $0.mnemonic, operands: $0.operands)
            }
            let slotReturns = MacIRSlotReturnAuthority.collectWithCallerUseEvidence(functions: built, types: typeDefinitions,
                signatures: signatures, callerReturns: callerReturns,
                directCallSources: directCallSources, callerFunctions: ownBodies)
            guard !Task.isCancelled, checkpoint() else { return nil }
            var returnContracts: ReturnContractTable?
            if MacIRConfiguration.returnContractEnabled {
                let originalRows = Dictionary(grouping: analysis.instructions, by: \.address)
                let contractFunctions = built.map { function in
                    var copy = function
                    copy.instructions = function.instructions.map { instruction in
                        var raw = instruction
                        if let rows = originalRows[instruction.source.address], rows.count == 1 {
                            raw.source.operands = rows[0].operands
                        }
                        return raw
                    }
                    return copy
                }
                returnContracts = ReturnContractTable.collect(
                    key: .init(snapshotID: indirectCallSnapshotID, slot: slot), analysis: analysis,
                    functions: contractFunctions, signatures: signatures, types: typeDefinitions,
                    callerWidths: callerReturns, slots: slotReturns, indirect: report,
                    slotCalls: prerequisite.report?.slots.callContracts ?? [:], authoredCalls: authored)
            }
            guard !Task.isCancelled, checkpoint() else { return nil }
            return IndirectCallResolutionMemo.ImageReport(indirectCalls: report, callerReturns: callerReturns,
                                                         slotReturns: slotReturns, returnContracts: returnContracts,
                                                         ownDirectCallAddresses: ownCalls, ownCalleeReturns: ownReturns)
        }?.indirectCalls
    }

    func indirectCallTargetName(_ address: UInt64, in slot: ImageSlot, analysis: ImageAnalysis) -> String {
        analysis.functions.first { $0.startAddress == address }
            .map { displayName(at: address, in: slot, default: $0.name) } ?? "0x" + String(address, radix: 16)
    }

    /// Builds an exact UUID-bound pseudocode handoff for headless Reconstruction work. Unlike the
    /// interactive selected-address helper, this never falls back to the first or nearest function.
    /// That distinction is load-bearing when malformed or partially recovered analyses contain two
    /// summaries with the same start address.
    func pseudocodeRenderInput(
        exactFunctionID: UUID,
        in slot: ImageSlot
    ) -> PseudocodeRenderInput? {
        guard let analysis = analysis(in: slot) else {
            return nil
        }
        let exactMatches = analysis.functions.filter { $0.id == exactFunctionID }
        guard exactMatches.count == 1, let function = exactMatches.first else {
            return nil
        }
        let excludedAddresses = codeExcludedAddresses(in: slot)
        let instructions = analysis.instructions.filter { row in
            guard row.address >= function.startAddress,
                  !excludedAddresses.contains(row.address) else {
                return false
            }
            return function.endAddress > function.startAddress
                ? row.address < function.endAddress
                : row.address == function.startAddress
        }
        return makePseudocodeRenderInput(
            target: (function, instructions),
            analysis: analysis,
            in: slot
        )
    }

    private func makePseudocodeRenderInput(
        target: (function: FunctionSummary, instructions: [InstructionRow])?,
        analysis: ImageAnalysis?,
        in slot: ImageSlot
    ) -> PseudocodeRenderInput {
        let startAddress = target?.function.startAddress
        var input = PseudocodeRenderInput(
            imageSlot: slot,
            functionName: target.map {
                displayName(at: $0.function.startAddress, in: slot, default: $0.function.name)
            } ?? "_main",
            startAddress: startAddress,
            jumpTables: resolvedJumpTables(in: slot),
            objcSelectors: analysis?.objcSelectors ?? [:],
            constantStrings: analysis?.constantStrings ?? [:],
            nameOverrides: functionNameOverrides(in: slot),
            signatureOverrides: functionSignatureOverrides(in: slot),
            authoredCallSignaturesByTarget: authoredCallSignaturesByTarget(in: slot),
            directCallVoidResultTargets: directCallVoidResultTargets(in: slot),
            ownDirectCallAddresses: ownDirectCallAddresses(in: slot),
            registerNameOverrides: startAddress.map {
                registerNameOverrides(forProcedureAt: $0, in: slot)
            } ?? [:],
            stackLocalOverrides: startAddress.map {
                stackLocalOverrides(forProcedureAt: $0, in: slot)
            } ?? [:],
            types: typeDefinitions,
            instructions: target?.instructions ?? analysis?.instructions ?? []
        )
        if let startAddress {
            let key = IndirectCallResolutionMemo.Key(snapshotID: indirectCallSnapshotID, slot: slot)
            input.callerReturnWidth = indirectCallMemo.callerReturnWidth(for: key, at: startAddress)
            if let report = typedPrototypeImageOutcome(in: slot, compute: false).report {
                input.slotCallContracts = report.slots.callContracts
                let rawIndirect = (target?.instructions ?? []).filter {
                    let mnemonic = $0.mnemonic.lowercased()
                    return mnemonic.hasPrefix("blr") || mnemonic.hasPrefix("br")
                        && mnemonic != "brk"
                }
                // Return-only authority must not alter an untyped indirect call's
                // result footprint. This is an IR/control-site guard, not text comparison.
                let isolated = rawIndirect.allSatisfy { report.slots.callContracts[$0.address] != nil }
                if baseFunctionSignatureOverrides(in: slot)[startAddress]?.returnType == nil,
                   isolated, let contract = report.callers.contracts[startAddress], contract.returnType == "void" {
                    input.callerReturnType = contract.returnType
                }
            }
        }
        if MacIRConfiguration.returnContractEnabled {
            // Duplicate starts are ambiguous identities, not a last-writer-wins
            // name choice. Builder frame and return-contract proofs still apply.
            let groups = Dictionary(grouping: analysis?.functions ?? [], by: \.startAddress)
            input.knownTailCallTargets = groups.compactMapValues { matches in
                guard matches.count == 1, let function = matches.first else { return nil }
                return function.name
            }
            // Do not compute a cold table here. Its snapshot/slot key and completed
            // publication are the same authorities used by existing memo readers.
            let hasCatalogAuthority = target.map {
                CallSignatureCatalog.standard.signature(for: $0.function.name) != nil
            } ?? false
            if let startAddress, !hasCatalogAuthority,
               let contract = returnContractTable(in: slot, compute: false)?.contract(forFunctionAt: startAddress) {
                // Retain the existing untyped-indirect isolation boundary for
                // void return-only authority, including authenticated transfers.
                let indirectSites = input.instructions.filter {
                    let mnemonic = $0.mnemonic.lowercased()
                    return mnemonic.hasPrefix("blr") || mnemonic.hasPrefix("br") && mnemonic != "brk"
                }
                let isolated = indirectSites.allSatisfy { input.slotCallContracts[$0.address] != nil }
                if contract.kind != .void || isolated {
                    input.admitReturnContract(contract, enabled: true)
                }
            }
        } else if MacIRConfiguration.ssaEnabled, let target, let analysis,
                  target.function.endAddress > target.function.startAddress,
                  baseFunctionSignatureOverrides(in: slot)[target.function.startAddress]?.returnType == "void",
                  input.instructions.allSatisfy({ row in
                      let mnemonic = row.mnemonic.lowercased()
                      return !mnemonic.hasPrefix("br") && !mnemonic.hasPrefix("blr")
                          && input.jumpTables[row.address] == nil
                  }) {
            // The disabled return-contract path admits only independently declared
            // void-to-void identities. No missing result use supplies authority.
            // Keep indirect/switch escape barriers and default-mode output unchanged.
            let groups = Dictionary(grouping: analysis.functions, by: \.startAddress)
            if groups[target.function.startAddress]?.count == 1 {
                let sourceRange = target.function.startAddress..<target.function.endAddress
                input.knownTailCallTargets = groups.compactMapValues { matches in
                    guard matches.count == 1, let function = matches.first,
                          !sourceRange.contains(function.startAddress),
                          !function.name.isEmpty,
                          MacIRBuilder.splitOperands(function.name) == [function.name],
                          MacIRBuilder.hasValidReturningCallOperands(mnemonic: "bl", operands: [function.name]),
                          input.authoredCallSignaturesByTarget[function.name]?.returnType == "void" else { return nil }
                    // Original-name call signatures require unique name identity;
                    // the builder still proves the frame at each exact branch PC.
                    return function.name
                }
            }
        }
        if let target, let analysis {
            input.resolvedIndirectCalls = functionLocalIndirectCalls(for: input, analysis: analysis, in: slot,
                                                                     rows: target.instructions)
        }
        if let handoff = machineCallUsageHandoff(for: target, in: slot) {
            input.machineCallUsage = handoff.usage
            input.machineUsageContext = handoff.context
        }
        return input
    }

    /// Only a procedure with both an indirect call and a store can resolve a slot, so the
    /// extra build is skipped everywhere else.
    private func functionLocalIndirectCalls(
        for input: PseudocodeRenderInput,
        analysis: ImageAnalysis,
        in slot: ImageSlot,
        rows: [InstructionRow]
    ) -> [UInt64: PseudocodeIndirectCall] {
        guard rows.contains(where: { $0.mnemonic.hasPrefix("blr") }) else { return [:] }
        // A warm image-wide report also carries the typed (cross-function) resolutions.
        if let start = input.startAddress, let report = imageWideIndirectCalls(in: slot, compute: false) {
            var calls: [UInt64: PseudocodeIndirectCall] = [:]
            for resolution in report.resolutions where resolution.functionStart == start {
                calls[resolution.callAddress] = PseudocodeIndirectCall(
                    target: resolution.target, name: indirectCallTargetName(resolution.target, in: slot, analysis: analysis),
                    slot: {
                        switch resolution.scope {
                        case .function: return resolution.slot.description
                        case let .type(name):
                            let offsets = resolution.slot.components.enumerated().map { index, offset in
                                (index == 0 ? "" : "->") + (offset < 0 ? "-0x" : "+0x")
                                    + String(offset.magnitude, radix: 16)
                            }.joined()
                            return "struct \(name) " + offsets
                        }
                    }())
            }
            return calls
        }
        guard rows.contains(where: { $0.mnemonic.hasPrefix("st") }) else { return [:] }
        let function = PseudocodePrinter().buildFunction(
            functionName: input.functionName, startAddress: input.startAddress, jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: baseFunctionSignatureOverrides(in: slot),
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            types: input.types, instructions: rows)
        let summaries = Dictionary(analysis.functions.map { ($0.startAddress, $0) }, uniquingKeysWith: { first, _ in first })
        return PseudocodePrinter.functionLocalIndirectCalls(in: function, functionStarts: Set(summaries.keys)) { address in
            summaries[address].map { displayName(at: address, in: slot, default: $0.name) } ?? "0x" + String(address, radix: 16)
        }
    }

    /// Cached same-image call identity only. A cold or interrupted report grants
    /// no permission; caller result liveness is proved separately at presentation.
    func ownDirectCallAddresses(in slot: ImageSlot) -> Set<UInt64> {
        let key = IndirectCallResolutionMemo.Key(snapshotID: indirectCallSnapshotID, slot: slot)
        guard indirectCallMemo.report(for: key) != nil else { return [] }
        return indirectCallMemo.imageReport(for: key, build: { nil })?.ownDirectCallAddresses ?? []
    }

    /// Caller-side permission to omit an unused direct-call result from the
    /// completed image report. It never declares the callee's own return type
    /// and remains separate from prototype binding and report invalidation.
    func directCallVoidResultTargets(in slot: ImageSlot) -> [String: FunctionSignatureOverride] {
        let key = IndirectCallResolutionMemo.Key(snapshotID: indirectCallSnapshotID, slot: slot)
        guard indirectCallMemo.report(for: key) != nil,
              let returns = indirectCallMemo.imageReport(for: key, build: { nil })?.slotReturns,
              let analysis = analysis(in: slot) else { return [:] }
        let overrides = baseFunctionSignatureOverrides(in: slot)
        let names = branchTargetNames(in: slot)
        let namesByIdentity = Dictionary(grouping: names, by: \.value)
        let functionsByAddress = Dictionary(grouping: analysis.functions, by: \.startAddress)
        let functionsByName = Dictionary(grouping: analysis.functions, by: \.name)
        var result: [String: FunctionSignatureOverride] = [:]
        for address in returns.callerSideVoidResultTargets {
            guard overrides[address] == nil,
                  let functions = functionsByAddress[address], functions.count == 1,
                  let function = functions.first, functionsByName[function.name]?.count == 1,
                  let name = names[address], !name.isEmpty,
                  namesByIdentity[name]?.count == 1 else { continue }
            let contract = FunctionSignatureOverride(returnType: "void")
            result[name] = contract
            result["0x" + String(address, radix: 16)] = contract
        }
        return result
    }

    // Shared with the existing scripting decompile extraction, without invoking
    // canonical render-input construction or any unrelated indirect-call build.
    func machineCallUsageHandoff(
        for target: (function: FunctionSummary, instructions: [InstructionRow])?, in slot: ImageSlot
    ) -> (usage: MacIRMachineCallUsage, context: MacIRMachineUsageContext)? {
        guard let target, let analysis = analysis(in: slot),
              analysis.functions.filter({ $0 == target.function }).count == 1,
              let context = machineUsageContext(in: slot),
              let usage = machineCallUsage(for: target, analysis: analysis, in: slot, context: context)
        else { return nil }
        return (usage, context)
    }

    // New private WorkspaceSnapshot helpers. No memo, persistent field, or name lookup.
    private func machineUsageContext(in slot: ImageSlot) -> MacIRMachineUsageContext? {
        let owners = binaries.filter { $0.slot == slot }
        guard owners.count == 1, let owner = owners.first,
              ["arm64", "arm64e"].contains(owner.architecture.lowercased()) else { return nil }
        return MacIRMachineUsageContext(snapshotID: indirectCallSnapshotID,
            imageID: owner.id, imageSlotRawValue: slot.rawValue)
    }

    private func machineCallUsage(
        for target: (function: FunctionSummary, instructions: [InstructionRow]),
        analysis: ImageAnalysis, in slot: ImageSlot, context: MacIRMachineUsageContext
    ) -> MacIRMachineCallUsage? {
        guard !Task.isCancelled, analysis.functions.count <= 4096,
              target.instructions.contains(where: { $0.mnemonic.lowercased() == "bl" }),
              analysis.functions.filter({ $0.startAddress == target.function.startAddress }).count == 1,
              !analysis.functions.contains(where: {
                  $0.id != target.function.id && $0.startAddress < target.function.endAddress
                      && target.function.startAddress < $0.endAddress
              }) else { return nil }
        func spans(_ rows: [InstructionRow]) -> [MacIRSourceSpan] {
            rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                mnemonic: $0.mnemonic, operands: $0.operands, comment: $0.comment,
                structuredOperands: $0.structuredOperands) }
        }
        let caller = MacIRMachineUsageBody(start: target.function.startAddress,
            end: target.function.endAddress, rows: spans(target.instructions))
        let referencedTargets = MacIRMachineCallUsage.directTargets(in: caller)
        guard !referencedTargets.isEmpty else { return nil }
        let excluded = codeExcludedAddresses(in: slot)
        let declarations = baseFunctionSignatureOverrides(in: slot)
        let index = analysis.exportInstructionIndex()
        var bodies: [MacIRMachineUsageBody] = []
        var retainedRowCount = 0
        for function in analysis.functions {
            guard !Task.isCancelled else { return nil }
            // Keep every extent for ambiguity checks. A declared, incomplete, or
            // over-budget body stays empty and cannot grant an incoming-read proof.
            var rows: [InstructionRow] = []
            if referencedTargets.contains(function.startAddress), declarations[function.startAddress] == nil,
               function.endAddress > function.startAddress,
               function.endAddress - function.startAddress <= 16384 {
                rows = index.instructions(start: function.startAddress, end: function.endAddress)
                    .filter { !excluded.contains($0.address) }
            }
            retainedRowCount += rows.count
            guard retainedRowCount <= 262144 else { return nil }
            bodies.append(MacIRMachineUsageBody(start: function.startAddress,
                end: function.endAddress, rows: spans(rows)))
        }
        // Use the exact handoff's caller spelling, including any existing call
        // symbolization. BL bytes bind its destination independently of that name.
        return MacIRMachineCallUsage.prove(context: context,
            caller: caller,
            callees: bodies)
    }

    func authoredCallSignaturesByTarget(in slot: ImageSlot) -> [String: FunctionSignatureOverride] {
        let overrides = baseFunctionSignatureOverrides(in: slot)
        let functions = analysis(in: slot)?.functions ?? []
        let groups = Dictionary(grouping: functions, by: \.name)
        var result: [String: FunctionSignatureOverride] = [:]
        for (name, matches) in groups where matches.count == 1 {
            guard let function = matches.first,
                  let override = overrides[function.startAddress] else { continue }
            result[name] = override
        }
        return result
    }
}

/// Confined to one synchronous image-wide call tree; never retained by a snapshot memo.
/// Keys retain exact values, rather than digests or selected-signature projections.
final class SnapshotBuiltFunctionCache {
    struct Key: Equatable {
        var snapshotID: UUID
        var slot: ImageSlot
        var startAddress: UInt64
        var functionName: String
        var jumpTables: [UInt64: [UInt64]] = [:]
        var objcSelectors: [UInt64: String] = [:]
        var constantStrings: [UInt64: MacIRConstantString] = [:]
        var signatureOverrides: [UInt64: FunctionSignatureOverride] = [:]
        var authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:]
        var directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:]
        var machineCallUsage: MacIRMachineCallUsage? = nil
        var machineUsageContext: MacIRMachineUsageContext? = nil
        var slotCallContracts: [UInt64: FunctionPointerSignatureV1] = [:]
        var callerReturnWidth: MacIRCallerReturnEvidence.Width? = nil
        var callerReturnType: String? = nil
        var types: [TypeDefinition] = []
        var instructions: [InstructionRow]
        // Resolve once into the key and pass these exact modes to the builder.
        var ssaEnabled = MacIRConfiguration.ssaEnabled
        var explicitCFGEnabled = MacIRConfiguration.explicitCFGEnabled

        fileprivate var identity: Identity {
            Identity(snapshotID: snapshotID, slot: slot, startAddress: startAddress)
        }

        fileprivate func admitsReuse(environment: [String: String], isCancelled: Bool) -> Bool {
            // C2 prints REJECTED_CFG_UNENUMERATED per build, so even lookup is bypassed.
            !isCancelled && environment["MACSCOPE_C2_OUT"] == nil
                && ssaEnabled == MacIRConfiguration.ssaEnabled
                && explicitCFGEnabled == MacIRConfiguration.explicitCFGEnabled
        }
    }

    fileprivate struct Identity: Hashable {
        let snapshotID: UUID
        let slot: ImageSlot
        let startAddress: UInt64
    }
    private var entries: [Identity: (key: Key, function: MacIRFunction)] = [:]

    func function(for key: Key,
                  environment: [String: String] = ProcessInfo.processInfo.environment,
                  isCancelled: Bool = Task.isCancelled) -> MacIRFunction? {
        guard key.admitsReuse(environment: environment, isCancelled: isCancelled),
              let entry = entries[key.identity], entry.key == key else { return nil }
        return entry.function
    }

    func record(_ function: MacIRFunction, for key: Key,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                isCancelled: Bool = Task.isCancelled) {
        guard key.admitsReuse(environment: environment, isCancelled: isCancelled),
              !function.refusals.contains(where: { $0.reason == .cancelled }) else { return }
        entries[key.identity] = (key, function)
    }
}

enum MacScopePerfPhaseClock {
    struct Token {
        let phase: String
        let function: UInt64?
        let start: UInt64
    }
    private static let enabled =
        ProcessInfo.processInfo.environment["MACSCOPE_PERF_PHASES"] == "1"

    static func begin(_ phase: String, function: UInt64? = nil) -> Token? {
        guard enabled else { return nil }
        let token = Token(phase: phase, function: function,
                          start: DispatchTime.now().uptimeNanoseconds)
        print("PERF_PHASE_BEGIN phase=\(phase) function=\(function.map { String($0) } ?? "image") start_ns=\(token.start)")
        return token
    }
    static func end(_ token: Token?) {
        guard let token else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds
            .subtractingReportingOverflow(token.start)
        if elapsed.overflow {
            print("PERF_PHASE_INVALID phase=\(token.phase) start_ns=\(token.start)")
            return
        }
        print("PERF_PHASE_END phase=\(token.phase) function=\(token.function.map { String($0) } ?? "image") start_ns=\(token.start) ns=\(elapsed.partialValue)")
    }
}

enum DebuggerLogicalBreakpointCatalogAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum DebuggerLogicalBreakpointCatalogPersistenceError: Error, Equatable {
    case unavailable
}

enum DebuggerLaunchProfileCatalogAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum DebuggerLaunchProfileCatalogPersistenceError: Error, Equatable {
    case unavailable
}

/// A value snapshot shares this reference only until any analysis input mutates.
/// The entire attempt is guarded, and interrupted attempts are never retried or published.
private final class SlotPrototypeMemo: @unchecked Sendable {
    struct Report: Sendable {
        var slots: SlotTypedPrototypeBinding.Report
        var callers: MacIRCallerReturnEvidence.ClosedWorldReport
    }
    enum Outcome: Sendable {
        case completed(Report)
        case unavailable
        case interrupted

        var report: Report? {
            guard case .completed(let report) = self else { return nil }
            return report
        }
    }
    private let lock = NSLock()
    private var cached: [IndirectCallResolutionMemo.Key: Outcome] = [:]
    func outcome(for key: IndirectCallResolutionMemo.Key) -> Outcome {
        guard lock.try() else { return .unavailable }
        defer { lock.unlock() }
        return cached[key] ?? .unavailable
    }
    func outcome(for key: IndirectCallResolutionMemo.Key, build: () -> Outcome) -> Outcome {
        guard lock.try() else { return .unavailable }
        defer { lock.unlock() }
        if let outcome = cached[key] { return outcome }
        cached[key] = .interrupted
        guard !Task.isCancelled else { return .interrupted }
        let outcome = build()
        guard !Task.isCancelled else { return .interrupted }
        cached[key] = outcome
        return outcome
    }
}

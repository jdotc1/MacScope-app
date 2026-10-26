import Foundation
import SwiftUI

struct WorkspaceBinaryOpenState: Equatable {
    enum Phase: Equatable {
        case inspecting, choosing, loading
        case completed(UUID)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            default: false
            }
        }
    }
    let id: UUID
    let phase: Phase
}

enum SearchSheetPresentation {
    case goToAddress
    case commandPalette
}

enum GraphNavigationDirection {
    case previous
    case next
}

enum SidebarNavigationDirection {
    case previous
    case next
}

enum InstructionNavigationDirection {
    case previous
    case next
}

/// Provenance returned by the explicit duplicate/fork identity seam. Package schema remains
/// unchanged in F1A; callers can retain this value when a later persistence wave stores lineage.
struct WorkspaceIdentityFork: Equatable {
    let sourceDocumentID: UUID
    let sourceWorkspaceID: UUID
    let documentID: UUID
    let workspaceID: UUID
}

private struct Phase2DebuggerRuntimeAuthorityKey: Equatable {
    let sessionID: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?

    init(
        sessionID: UUID,
        lifecycleRevision: UInt64,
        stopRevision: UInt64?,
        eventSequence: UInt64?
    ) {
        self.sessionID = sessionID
        self.lifecycleRevision = lifecycleRevision
        self.stopRevision = stopRevision
        self.eventSequence = eventSequence
    }

    init?(snapshot: DebuggerSessionSnapshot) {
        guard let coordinate = snapshot.transportSessionCoordinate else { return nil }
        sessionID = coordinate.epoch.rawValue
        lifecycleRevision = coordinate.lifecycleRevision.rawValue
        stopRevision = snapshot.transportStopCoordinate?.stopRevision.rawValue
        eventSequence = snapshot.transportEventSequence?.rawValue
    }
}

struct Phase2DebuggerReadOnlyRuntimeAuthorityConsumption: Equatable, Sendable {
    let evidenceDigest: String
    let sessionID: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?
}

private struct Phase2DebuggerControlledRuntimeAuthorityKey: Equatable {
    let eventID: UUID
    let sessionID: UUID
    let action: DebuggerControlAction
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?

    init(event: DebuggerControlledRuntimeActionEvent) {
        eventID = event.id
        sessionID = event.sessionID
        action = event.action
        lifecycleRevision = event.lifecycleRevision
        stopRevision = event.stopRevision
        eventSequence = event.eventSequence
    }
}

@MainActor
protocol Phase2AIDebuggerProposalExecuting: AnyObject {
    var phase2CurrentDebuggerSnapshot: DebuggerSessionSnapshot { get }
    func phase2DebuggerControlUnavailableReason(for action: Phase2AIDebuggerAction) -> String?
    func phase2ExecuteDebuggerProposalAction(
        _ request: Phase2AIDebuggerProposalExecutionRequest
    ) async -> DebuggerControlledRuntimeActionEvent?
}

struct WorkspaceLaunchConfiguration: Equatable {
    var editorMode: EditorMode?
    var windowFrame: WorkspaceLaunchWindowFrame?
    var loadsPreviewFixture: Bool
    var usesNativeDecompilerQualificationFixture: Bool

    init(
        editorMode: EditorMode? = nil,
        windowFrame: WorkspaceLaunchWindowFrame? = nil,
        loadsPreviewFixture: Bool = false,
        usesNativeDecompilerQualificationFixture: Bool = false
    ) {
        self.editorMode = editorMode
        self.windowFrame = windowFrame
        self.loadsPreviewFixture = loadsPreviewFixture
        self.usesNativeDecompilerQualificationFixture = usesNativeDecompilerQualificationFixture
    }

    static func parse(
        arguments: [String],
        environment: [String: String]
    ) -> WorkspaceLaunchConfiguration {
        let argumentMode = value(after: "--macscope-screenshot-mode", in: arguments)
        let environmentMode = environment["MACSCOPE_SCREENSHOT_EDITOR_MODE"]
        let argumentWindowFrame = value(after: "--macscope-window-frame", in: arguments)
        let environmentWindowFrame = environment["MACSCOPE_WINDOW_FRAME"]
        let editorMode = EditorMode.caseInsensitiveMatch(argumentMode ?? environmentMode)
        let qualificationScenario = environment["MACSCOPE_F1A_INSTALLED_SCENARIO_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usesQualificationFixture = isEnabled(
            environment["MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"]
        ) && qualificationScenario?.isEmpty == false

        return WorkspaceLaunchConfiguration(
            editorMode: editorMode,
            windowFrame: WorkspaceLaunchWindowFrame.parse(argumentWindowFrame ?? environmentWindowFrame),
            loadsPreviewFixture: usesQualificationFixture || editorMode != nil
                || previewFixtureRequested(arguments: arguments, environment: environment),
            usesNativeDecompilerQualificationFixture: usesQualificationFixture
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private static func previewFixtureRequested(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        arguments.contains("--macscope-preview-fixture")
            || isEnabled(environment["MACSCOPE_PREVIEW_FIXTURE"])
    }

    private static func isEnabled(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        default:
            false
        }
    }
}

struct WorkspaceLaunchWindowFrame: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    static func parse(_ value: String?) -> WorkspaceLaunchWindowFrame? {
        guard let value else { return nil }
        let parts = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3]),
              width >= 1080,
              height >= 680
        else {
            return nil
        }

        return WorkspaceLaunchWindowFrame(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }
}

struct GraphSelectionTarget: Identifiable, Hashable {
    var id: String
    var imageSlot: ImageSlot
    var ownerBinaryID: UUID? = nil
    var title: String
    var startAddress: UInt64
    var endAddress: UInt64
    var functionID: UUID?

    func contains(_ target: ImageAddress?) -> Bool {
        guard let target, target.slot == imageSlot else { return false }
        let address = target.address
        if endAddress > startAddress {
            return address >= startAddress && address < endAddress
        }
        return address == startAddress
    }
}

/// Immutable owner captured by a rendered primary-compatibility sidebar row. `ImageSlot` alone is
/// not durable because a package/document replacement may reuse the same slot for another binary.
struct SidebarNavigationTarget: Equatable {
    let itemID: SidebarItem.ID
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID?
}

/// Immutable Problems-row callback identity. The deterministic diagnostic id protects against
/// same-image reanalysis removal; the binary UUID protects against same-slot image replacement.
struct DiagnosticNavigationTarget: Equatable {
    let diagnosticID: String
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID?
}

/// Exact browser entity that produced a delayed navigation callback.
enum BrowserNavigationEntity: Equatable {
    case export(UUID)
    case section(UUID)
}

/// Immutable owner + entity + address captured by an Exports/Sections browser row.
struct BrowserRowNavigationTarget: Equatable {
    let imageAddress: ImageAddress
    let ownerBinaryID: UUID?
    let entity: BrowserNavigationEntity
}

/// Immutable local cross-reference identity captured by an inspector row. The endpoint alone is
/// ambiguous across images, and an XRef UUID alone is insufficient after same-slot replacement,
/// so delayed navigation validates the complete opening owner and edge projection.
struct XRefNavigationTarget: Equatable {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID?
    let xref: XRef
    let endpoint: UInt64
}

/// Immutable identity captured by a rendered cross-image inspector row. Both binary generations,
/// the exact derived edge, and the opening selection must survive until the delayed callback runs;
/// otherwise slot reuse, reanalysis, or a changed inspector context makes the row inert.
struct CrossImageXRefNavigationTarget: Equatable {
    let edge: CrossImageXRef
    let sourceOwnerBinaryID: UUID
    let destinationOwnerBinaryID: UUID
    let openingSelection: ImageAddress
    let endpoint: ImageAddress
}

/// Frozen owner/target captured when a delayed authoring presentation opens. The public request
/// fields remain mutable because SwiftUI edits a draft copy, but mutation of those fields must
/// never redirect the operation: store commits validate them against this immutable identity and
/// use this identity as the mutation target.
fileprivate struct DelayedAuthoringOpeningIdentity: Equatable {
    let target: ImageAddress
    let ownerBinaryID: UUID?

    func matches(target: ImageAddress, ownerBinaryID: UUID?) -> Bool {
        self.target == target && self.ownerBinaryID == ownerBinaryID
    }
}

/// A request to present the modal Rename / Edit-Comment editor for a specific
/// address. `Identifiable` drives SwiftUI `.sheet(item:)` presentation.
struct OverrideEditorRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case rename
        case comment
        case tag
        /// A procedure-scoped LOCAL LABEL at `address`.
        case localLabel
    }
    let id = UUID()
    var kind: Kind
    var address: UInt64
    var title: String
    var fieldPrompt: String
    var initialValue: String
    /// Image that owned the addressed entity when the editor opened. The default preserves
    /// legacy construction sites that predate multi-image workspaces.
    var imageSlot: ImageSlot = .primary
    /// Stable binary identity captured with `imageSlot`. A nil value is reserved for legacy
    /// binary-less fixtures; interactive presenters always populate it.
    var ownerBinaryID: UUID? = nil
}

/// One editable argument row in the signature editor sheet. `Identifiable` (stable
/// id) so SwiftUI list reorder/delete track rows correctly. The persisted row token
/// and provenance travel with the draft through rename, retype, reorder, and deletion;
/// source order is still the containing array's order.
struct ArgDraft: Identifiable, Equatable {
    let id = UUID()
    var rowToken: String
    /// The argument-register slot index (x0 -> 0, …), preserved through the editor
    /// as a compatibility/display coordinate. Commit derives canonical indices from
    /// source order rather than treating this value as row identity.
    var index: Int
    var name: String
    var type: String
    var provenance: ArgOverride.Provenance

    init(
        index: Int,
        name: String,
        type: String,
        rowToken: String? = nil,
        provenance: ArgOverride.Provenance = .user
    ) {
        self.rowToken = rowToken
            ?? UUID().uuidString.lowercased()
        self.index = index
        self.name = name
        self.type = type
        self.provenance = provenance
    }
}

/// Presence intent for the signature editor's visible argument rows. `.inherited`
/// means the rows are a recovered preview and are not persisted unless edited;
/// `.authoritative` means array order is the user's declaration, including `[]`
/// as explicit `(void)`.
enum SignatureParameterListIntent: Equatable {
    case inherited
    case authoritative
}

/// Drives the modal function-signature editor (return type + ordered args +
/// tri-state no-return authority). Richer than `OverrideEditorRequest` (a list of
/// args), so it has its
/// own `.sheet(item:)` presentation.
struct SignatureEditorRequest: Identifiable, Equatable {
    let id = UUID()
    fileprivate let openingIdentity: DelayedAuthoringOpeningIdentity
    var address: UInt64
    var functionName: String
    var returnType: String
    var args: [ArgDraft]
    /// The analysis-derived declaration captured when the editor opened. This is
    /// intentionally separate from `args`/`baselineArgs`: an authoritative override
    /// (including explicit `(void)`) must not masquerade as the recovered preview.
    var recoveredArgs: [ArgDraft]
    var noReturnState: FunctionSignatureOverride.NoReturnState

    /// Source compatibility for older tests and non-authoring consumers. Current
    /// editor surfaces bind directly to the tri-state property.
    var isNoReturn: Bool {
        get { noReturnState == .noReturn }
        set { noReturnState = newValue ? .noReturn : .returns }
    }
    var imageSlot: ImageSlot = .primary
    var parameterListIntent: SignatureParameterListIntent
    var quarantinedLegacyArgs: [LegacyArgOverride]

    /// Open-time state used to distinguish an unchanged recovered preview from an
    /// authored declaration. These values are intentionally editor-local and are
    /// never themselves persisted.
    var baselineArgs: [ArgDraft]
    var baselineReturnType: String
    var originalReturnType: String?
    var originalParameterListIntent: SignatureParameterListIntent
    var variadicState: FunctionSignatureOverride.VariadicState
    var originalVariadicState: FunctionSignatureOverride.VariadicState
    /// Stable owner captured when the delayed editor opened.
    var ownerBinaryID: UUID?
    /// Ephemeral Objective-C proposals for the method whose IMP owns this editor. These remain
    /// separate from the authored draft and are never encoded in a workspace.
    var objcCandidates: [ObjCSignatureCandidate]
    var appliedObjCCandidateContext: ObjCSignatureCandidate.Context? = nil

    init(
        address: UInt64,
        functionName: String,
        returnType: String,
        args: [ArgDraft],
        recoveredArgs: [ArgDraft],
        noReturnState: FunctionSignatureOverride.NoReturnState,
        imageSlot: ImageSlot = .primary,
        parameterListIntent: SignatureParameterListIntent = .authoritative,
        quarantinedLegacyArgs: [LegacyArgOverride] = [],
        baselineArgs: [ArgDraft]? = nil,
        baselineReturnType: String? = nil,
        originalReturnType: String? = nil,
        originalParameterListIntent: SignatureParameterListIntent? = nil,
        variadicState: FunctionSignatureOverride.VariadicState = .fixed,
        originalVariadicState: FunctionSignatureOverride.VariadicState? = nil,
        ownerBinaryID: UUID? = nil,
        objcCandidates: [ObjCSignatureCandidate] = []
    ) {
        self.openingIdentity = DelayedAuthoringOpeningIdentity(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
        self.address = address
        self.functionName = functionName
        self.returnType = returnType
        self.args = args
        self.recoveredArgs = recoveredArgs
        self.noReturnState = noReturnState
        self.imageSlot = imageSlot
        self.parameterListIntent = parameterListIntent
        self.quarantinedLegacyArgs = quarantinedLegacyArgs
        self.baselineArgs = baselineArgs ?? args
        self.baselineReturnType = baselineReturnType ?? returnType
        self.originalReturnType = originalReturnType
        self.originalParameterListIntent = originalParameterListIntent ?? parameterListIntent
        self.variadicState = variadicState
        self.originalVariadicState = originalVariadicState ?? variadicState
        self.ownerBinaryID = ownerBinaryID
        self.objcCandidates = objcCandidates
    }

    /// Compatibility initializer for pre-tri-state call sites.
    init(
        address: UInt64,
        functionName: String,
        returnType: String,
        args: [ArgDraft],
        recoveredArgs: [ArgDraft],
        isNoReturn: Bool,
        imageSlot: ImageSlot = .primary,
        parameterListIntent: SignatureParameterListIntent = .authoritative,
        quarantinedLegacyArgs: [LegacyArgOverride] = [],
        baselineArgs: [ArgDraft]? = nil,
        baselineReturnType: String? = nil,
        originalReturnType: String? = nil,
        originalParameterListIntent: SignatureParameterListIntent? = nil,
        variadicState: FunctionSignatureOverride.VariadicState = .fixed,
        originalVariadicState: FunctionSignatureOverride.VariadicState? = nil,
        ownerBinaryID: UUID? = nil,
        objcCandidates: [ObjCSignatureCandidate] = []
    ) {
        self.init(
            address: address,
            functionName: functionName,
            returnType: returnType,
            args: args,
            recoveredArgs: recoveredArgs,
            noReturnState: isNoReturn ? .noReturn : .unspecified,
            imageSlot: imageSlot,
            parameterListIntent: parameterListIntent,
            quarantinedLegacyArgs: quarantinedLegacyArgs,
            baselineArgs: baselineArgs,
            baselineReturnType: baselineReturnType,
            originalReturnType: originalReturnType,
            originalParameterListIntent: originalParameterListIntent,
            variadicState: variadicState,
            originalVariadicState: originalVariadicState,
            ownerBinaryID: ownerBinaryID,
            objcCandidates: objcCandidates
        )
    }

    var retainsOpeningIdentity: Bool {
        openingIdentity.matches(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
    }

    func hasSameOpeningPresentation(as other: SignatureEditorRequest) -> Bool {
        id == other.id && openingIdentity == other.openingIdentity
    }

    /// Explicitly adopts quarantined legacy array order through the model's atomic
    /// adoption seam. Quarantined rows otherwise remain hidden from `args` and inert.
    mutating func adoptQuarantinedLegacyArguments() {
        let adopted = FunctionSignatureOverride(
            quarantinedLegacyArgs: quarantinedLegacyArgs
        ).adoptingLegacyOrder()
        args = adopted.args.enumerated().map { offset, row in
            ArgDraft(
                index: offset,
                name: row.name,
                type: row.type,
                rowToken: row.rowToken,
                provenance: row.provenance
            )
        }
        parameterListIntent = .authoritative
        quarantinedLegacyArgs = adopted.quarantinedLegacyArgs
    }
}

/// Whether the type editor can safely round-trip a definition through its deliberately
/// small record-field form. Rich definitions remain available for rendering/export/delete,
/// but are never flattened into lossy mutable rows.
enum TypeEditorAccess: Equatable {
    case editablePlainRecord
    case readOnlyRichDefinition(reason: String)
}

/// One editable field row in the type editor sheet. `original` retains the complete
/// persisted field so a commit can change only the authored name/type leaves.
struct TypeFieldDraft: Identifiable, Equatable {
    let id = UUID()
    let original: FieldDef?
    var name: String
    var type: String

    init(original: FieldDef? = nil, name: String, type: String) {
        self.original = original
        self.name = name
        self.type = type
    }
}

/// Drives the modal type-definition editor (kind + name + fields). `typeID` keys
/// the catalog entry so editing an existing type upserts rather than duplicates.
struct TypeEditorRequest: Identifiable, Equatable {
    let id = UUID()
    let typeID: UUID
    let original: TypeDefinition?
    var kind: TypeKind
    let access: TypeEditorAccess
    var name: String
    var fields: [TypeFieldDraft]
    var imageSlot: ImageSlot = .primary
}

/// A path-free, per-definition export request. The store freezes rendered bytes and
/// suggested leaf name; the focused window remains the sole owner of Save-panel I/O.
struct RenderedTypeDefinitionExportRequest: Equatable, Sendable {
    let typeID: UUID
    let suggestedFileName: String
    let contents: String

    var suggestedBaseName: String {
        suggestedFileName.hasSuffix(".h")
            ? String(suggestedFileName.dropLast(2))
            : suggestedFileName
    }
}

/// Drives the modal switch-hint editor (manual jump-table declaration for a `br`).
/// Text-backed so the sheet can validate hex/decimal entry; `address` keys the
/// override and `entryCount == 0` on commit clears the hint.
struct SwitchHintEditorRequest: Identifiable, Equatable {
    let id = UUID()
    fileprivate let openingIdentity: DelayedAuthoringOpeningIdentity
    var address: UInt64
    var tableBaseText: String
    var entryCountText: String
    var entryStrideText: String
    var isRelativeToBase: Bool
    var imageSlot: ImageSlot = .primary
    var ownerBinaryID: UUID? = nil

    init(
        address: UInt64,
        tableBaseText: String,
        entryCountText: String,
        entryStrideText: String,
        isRelativeToBase: Bool,
        imageSlot: ImageSlot = .primary,
        ownerBinaryID: UUID? = nil
    ) {
        self.openingIdentity = DelayedAuthoringOpeningIdentity(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
        self.address = address
        self.tableBaseText = tableBaseText
        self.entryCountText = entryCountText
        self.entryStrideText = entryStrideText
        self.isRelativeToBase = isRelativeToBase
        self.imageSlot = imageSlot
        self.ownerBinaryID = ownerBinaryID
    }

    fileprivate var retainsOpeningIdentity: Bool {
        openingIdentity.matches(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
    }

    fileprivate func hasSameOpeningPresentation(as other: SwitchHintEditorRequest) -> Bool {
        id == other.id && openingIdentity == other.openingIdentity
    }
}

/// Drives the open-time loader-options dialog. Carries the file being opened and the
/// pure `LoaderOptionsModel` (slice list + default selection) the sheet renders.
struct LoaderOptionsRequest: Identifiable, Equatable {
    enum Operation: Equatable, Sendable {
        case replaceWorkspace
        case addImage
    }

    let id = UUID()
    var url: URL
    var model: LoaderOptionsModel
    var operation: Operation = .replaceWorkspace
}

/// Drives the modal Make Data sheet (array / string / alignment data-shape authoring).
/// `address` keys the shape override; the sheet's fields are text-backed so it can
/// validate count/length/boundary entry before committing. Distinct from a plain
/// mark-as-data — a shape spans its whole element/string run.
struct DataShapeEditorRequest: Identifiable, Equatable {
    /// Which data shape the sheet authors. The picker drives which fields are shown.
    enum Shape: String, CaseIterable, Identifiable {
        case array
        case string
        case alignment
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .array: return "Array"
            case .string: return "String"
            case .alignment: return "Alignment"
            }
        }
    }
    let id = UUID()
    fileprivate let openingIdentity: DelayedAuthoringOpeningIdentity
    var address: UInt64
    var shape: Shape = .array
    /// Array element type (e.g. "int32_t"); empty renders the byte count only.
    var elementType: String = "int32_t"
    /// Array element count (decimal).
    var countText: String = "1"
    /// String: NUL-terminated (true) or a fixed-length buffer.
    var isNullTerminated: Bool = true
    /// String fixed length when not NUL-terminated (decimal).
    var stringLengthText: String = "1"
    /// Alignment byte boundary (power of two: 2/4/8/16…).
    var boundaryText: String = "4"
    var imageSlot: ImageSlot = .primary
    var ownerBinaryID: UUID? = nil

    init(
        address: UInt64,
        imageSlot: ImageSlot = .primary,
        ownerBinaryID: UUID? = nil
    ) {
        self.openingIdentity = DelayedAuthoringOpeningIdentity(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
        self.address = address
        self.imageSlot = imageSlot
        self.ownerBinaryID = ownerBinaryID
    }

    fileprivate var retainsOpeningIdentity: Bool {
        openingIdentity.matches(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
    }

    fileprivate func hasSameOpeningPresentation(as other: DataShapeEditorRequest) -> Bool {
        id == other.id && openingIdentity == other.openingIdentity
    }
}

/// Drives the modal Import C Header sheet: a paste area for C `struct`/`union`/`enum`/
/// `typedef` declarations that are parsed into the type catalog (undoable). `result`
/// carries the post-commit summary so the sheet can show what was added/skipped.
struct CHeaderImportRequest: Identifiable, Equatable {
    let id = UUID()
    var source: String = ""
}

/// Stable `UndoManager` target for one numeric image-slot generation. Store-authored actions use
/// this proxy instead of `WorkspaceStore` itself so a slot remap can retire only actions whose
/// captured identity became invalid, while workspace-global and sibling-slot history survives.
@MainActor
private final class WorkspaceSlotUndoTarget {
    weak var store: WorkspaceStore?
    let slot: ImageSlot
    /// Number of this generation's currently applied undoable mutations. Undo decrements and
    /// initial application/redo increments it. This distinguishes pruning an applied edit (which
    /// breaks older dirty-token comparability) from pruning only a redo of an already-undone edit.
    var appliedMutationCount = 0

    init(store: WorkspaceStore, slot: ImageSlot) {
        self.store = store
        self.slot = slot
    }
}

@MainActor
/// Main-actor-owned revision ledger for the immutable workspace side of live debugger mapping.
/// It deliberately compares only artifact/owner evidence: analysis output, focus, selection, and
/// authoring changes cannot churn this catalog. Revision exhaustion is terminal and fail-closed;
/// an empty catalog prevents any previously correlated coordinate from being revalidated.
struct DebuggerWorkspaceArtifactCatalogLedger {
    private struct ArtifactEvidence: Hashable {
        let binaryID: UUID
        let slot: ImageSlot
        let artifactIdentity: MachOSliceArtifactIdentity?
        let preferredSegmentLayout: MachOPreferredSegmentLayout?
        let artifactIntegrityState: MachOSliceArtifactIntegrityState
        let sourcePathHint: String?
        let executablePathHint: String?

        init(binary: BinaryImage) {
            let normalized = DebuggerWorkspaceArtifactCatalogEntry(
                binaryID: binary.id,
                slot: binary.slot,
                ownerRevision: .init(rawValue: 0),
                artifactIdentity: binary.artifactIdentity,
                preferredSegmentLayout: binary.preferredSegmentLayout,
                artifactIntegrityState: binary.artifactIntegrityState,
                sourcePathHint: binary.path,
                executablePathHint: binary.resolvedExecutablePath
            )
            self.binaryID = normalized.binaryID
            self.slot = normalized.slot
            self.artifactIdentity = normalized.artifactIdentity
            self.preferredSegmentLayout = normalized.preferredSegmentLayout
            self.artifactIntegrityState = normalized.artifactIntegrityState
            self.sourcePathHint = normalized.sourcePathHint
            self.executablePathHint = normalized.executablePathHint
        }

        func entry(
            ownerRevision: DebuggerWorkspaceArtifactOwnerRevision
        ) -> DebuggerWorkspaceArtifactCatalogEntry {
            DebuggerWorkspaceArtifactCatalogEntry(
                binaryID: binaryID,
                slot: slot,
                ownerRevision: ownerRevision,
                artifactIdentity: artifactIdentity,
                preferredSegmentLayout: preferredSegmentLayout,
                artifactIntegrityState: artifactIntegrityState,
                sourcePathHint: sourcePathHint,
                executablePathHint: executablePathHint
            )
        }

        func hasSameOwnerEvidence(as other: Self) -> Bool {
            binaryID == other.binaryID
                && slot == other.slot
                && artifactIdentity == other.artifactIdentity
                && preferredSegmentLayout == other.preferredSegmentLayout
                && artifactIntegrityState == other.artifactIntegrityState
        }
    }

    private(set) var catalog: DebuggerWorkspaceArtifactCatalog
    private(set) var isExhausted: Bool
    private var evidenceByBinaryID: [UUID: ArtifactEvidence]
    private var ownerRevisionByBinaryID: [UUID: DebuggerWorkspaceArtifactOwnerRevision]
    /// Never discard retired coordinates: these tombstones prevent remove/re-add and A→B→A ABA.
    private var ownerHighWaterByBinaryID: [UUID: DebuggerWorkspaceArtifactOwnerRevision]
    private var ownerHighWaterBySlot: [ImageSlot: DebuggerWorkspaceArtifactOwnerRevision]
    private let initialOwnerRevision: DebuggerWorkspaceArtifactOwnerRevision

    init(
        snapshot: WorkspaceSnapshot,
        catalogRevision: DebuggerWorkspaceArtifactCatalogRevision = .init(rawValue: 1),
        initialOwnerRevision: DebuggerWorkspaceArtifactOwnerRevision = .init(rawValue: 1)
    ) {
        self.initialOwnerRevision = initialOwnerRevision
        guard catalogRevision.rawValue != .max,
              let evidence = Self.validatedEvidence(in: snapshot) else {
            self.catalog = .init(revision: .init(rawValue: .max), artifacts: [])
            self.evidenceByBinaryID = [:]
            self.ownerRevisionByBinaryID = [:]
            self.ownerHighWaterByBinaryID = [:]
            self.ownerHighWaterBySlot = [:]
            self.isExhausted = true
            return
        }
        let owners = Dictionary(
            uniqueKeysWithValues: evidence.keys.map { ($0, initialOwnerRevision) }
        )
        self.catalog = Self.makeCatalog(
            revision: catalogRevision,
            evidence: evidence,
            owners: owners
        )
        self.evidenceByBinaryID = evidence
        self.ownerRevisionByBinaryID = owners
        self.ownerHighWaterByBinaryID = owners
        self.ownerHighWaterBySlot = Dictionary(
            uniqueKeysWithValues: evidence.values.map { ($0.slot, initialOwnerRevision) }
        )
        self.isExhausted = false
    }

    mutating func reconcile(
        snapshot: WorkspaceSnapshot,
        fullWorkspaceReplacement: Bool = false
    ) -> DebuggerWorkspaceArtifactCatalog {
        guard !isExhausted else { return catalog }
        guard let nextEvidence = Self.validatedEvidence(in: snapshot) else {
            return failClosed()
        }
        guard fullWorkspaceReplacement || nextEvidence != evidenceByBinaryID else {
            return catalog
        }
        guard let nextCatalogRevision = catalog.revision.incremented(),
              nextCatalogRevision.rawValue != .max else {
            return failClosed()
        }

        var nextOwners: [UUID: DebuggerWorkspaceArtifactOwnerRevision] = [:]
        nextOwners.reserveCapacity(nextEvidence.count)
        for evidence in nextEvidence.values {
            let priorByID = evidenceByBinaryID[evidence.binaryID]
            let ownerRevision: DebuggerWorkspaceArtifactOwnerRevision

            if fullWorkspaceReplacement {
                guard let reminted = remintedOwnerRevision(for: evidence) else {
                    return failClosed()
                }
                ownerRevision = reminted
            } else if let priorByID,
                      let current = ownerRevisionByBinaryID[evidence.binaryID] {
                if priorByID.hasSameOwnerEvidence(as: evidence) {
                    ownerRevision = current
                } else {
                    guard let incremented = current.incremented() else {
                        return failClosed()
                    }
                    ownerRevision = incremented
                }
            } else {
                // An absent/replaced owner is reminted above every historical ID or slot owner.
                guard let reminted = remintedOwnerRevision(for: evidence) else {
                    return failClosed()
                }
                ownerRevision = reminted
            }
            nextOwners[evidence.binaryID] = ownerRevision
            ownerHighWaterByBinaryID[evidence.binaryID] = max(
                ownerHighWaterByBinaryID[evidence.binaryID] ?? ownerRevision,
                ownerRevision
            )
            ownerHighWaterBySlot[evidence.slot] = max(
                ownerHighWaterBySlot[evidence.slot] ?? ownerRevision,
                ownerRevision
            )
        }

        catalog = Self.makeCatalog(
            revision: nextCatalogRevision,
            evidence: nextEvidence,
            owners: nextOwners
        )
        evidenceByBinaryID = nextEvidence
        ownerRevisionByBinaryID = nextOwners
        return catalog
    }

    private func remintedOwnerRevision(
        for evidence: ArtifactEvidence
    ) -> DebuggerWorkspaceArtifactOwnerRevision? {
        let highWater = [
            ownerHighWaterByBinaryID[evidence.binaryID],
            ownerHighWaterBySlot[evidence.slot],
        ].compactMap { $0 }.max()
        guard let highWater else { return initialOwnerRevision }
        return highWater.incremented()
    }

    private mutating func failClosed() -> DebuggerWorkspaceArtifactCatalog {
        isExhausted = true
        evidenceByBinaryID.removeAll()
        ownerRevisionByBinaryID.removeAll()
        catalog = .init(revision: .init(rawValue: .max), artifacts: [])
        return catalog
    }

    private static func validatedEvidence(
        in snapshot: WorkspaceSnapshot
    ) -> [UUID: ArtifactEvidence]? {
        let evidence = snapshot.binaries.map(ArtifactEvidence.init(binary:))
        guard Set(evidence.map(\.binaryID)).count == evidence.count,
              Set(evidence.map(\.slot)).count == evidence.count else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: evidence.map { ($0.binaryID, $0) })
    }

    private static func makeCatalog(
        revision: DebuggerWorkspaceArtifactCatalogRevision,
        evidence: [UUID: ArtifactEvidence],
        owners: [UUID: DebuggerWorkspaceArtifactOwnerRevision]
    ) -> DebuggerWorkspaceArtifactCatalog {
        DebuggerWorkspaceArtifactCatalog(
            revision: revision,
            artifacts: evidence.values.compactMap { artifact in
                owners[artifact.binaryID].map(artifact.entry(ownerRevision:))
            }
        )
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaceName: String {
        didSet {
            if workspaceName != oldValue {
                phase2ReadLedger.noteWorkspaceMetadataChange()
            }
        }
    }
    private(set) var patternPublicationEpoch = PatternPublicationEpoch()
    private func revokePatternPublication() { patternPublicationEpoch = PatternPublicationEpoch() }

    @Published var snapshot: WorkspaceSnapshot {
        willSet { revokePatternPublication() }
        didSet {
            nativeDecompilerSnapshotRevision = UUID()
            guard !isCoordinatingSnapshotIdentityChange,
                  !isNormalizingLogicalBreakpointCompatibility else { return }
            // Direct analysis replacement/reanalysis may carry stale compatibility bits. Rebuild
            // them before any observer derives debugger state so the durable catalog remains the
            // sole post-initialization authority.
            var normalizedSnapshot = snapshot
            let didNormalize = Self.reprojectLogicalBreakpointCompatibility(
                in: &normalizedSnapshot,
                availability: logicalBreakpointCatalogAvailability
            )
            if didNormalize {
                isNormalizingLogicalBreakpointCompatibility = true
                snapshot = normalizedSnapshot
                isNormalizingLogicalBreakpointCompatibility = false
            }
            reconcileDebuggerWorkspaceArtifactCatalog()
            reconcileDebuggerBreakpointResolutionCatalog()
            phase2ReadLedger.ingestSnapshotTransition(from: oldValue, to: snapshot)
            invalidateUnwindAuditIfNeeded()
            retireUndoHistoryForChangedBinaryOwners(from: oldValue)
            revalidateInteractiveSelectionAfterSnapshotChange()
            cancelStaleObjCSignatureInference()
        }
    }
    /// Changes before observers or native submissions can reuse captured image inputs.
    private(set) var nativeDecompilerSnapshotRevision = UUID()
    /// Complete, immutable, all-image workspace evidence for debugger correlation. It is transient
    /// and never follows focus or enters persistence/XPC payloads.
    @Published private(set) var debuggerWorkspaceArtifactCatalog = DebuggerWorkspaceArtifactCatalog(
        revision: .init(rawValue: 1),
        artifacts: []
    )
    private var debuggerWorkspaceArtifactCatalogLedger = DebuggerWorkspaceArtifactCatalogLedger(
        snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
    )
    @Published private(set) var debuggerBreakpointResolutionCatalog =
        DebuggerBreakpointResolutionCatalog(
            coordinate: .init(
                workspaceID: UUID(),
                revision: .init(rawValue: 1),
                workspaceArtifactCatalogRevision: .init(rawValue: 1)
            ),
            owners: []
        )
    private var debuggerBreakpointResolutionCatalogLedger =
        DebuggerBreakpointResolutionCatalogLedger(
            snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            workspaceID: UUID(),
            artifactCatalog: DebuggerWorkspaceArtifactCatalog(
                revision: .init(rawValue: 1),
                artifacts: []
            )
        )
    let unwindAuditCoordinator = UnwindAuditCoordinator()
    /// Transient app-owned Phase 2 state. It is deliberately absent from persistence and XPC.
    var phase2ReadLedger = Phase2ReadRevisionLedger()
    var phase2EvidenceAcceptor = Phase2EvidenceAcceptor()
    private(set) var phase2ShellSession = Phase2WorkspaceShellSessionProjection.inactive
    private(set) var phase2ShellBrokerPTYBinding: Phase2ShellBrokerPTYBinding?
    @Published private(set) var phase2DebuggerReadOnlySnapshot = DebuggerSessionSnapshot.empty
    @Published private(set) var phase2DebuggerReadEvidenceSnapshot:
        Phase2DebuggerReadEvidenceSnapshot?
    @Published private(set) var phase2AIShellProposalReview = Phase2AIShellProposalReviewState.inactive
    @Published private(set) var phase2AssistantAuthoringProposalReview =
        Phase2AssistantAuthoringProposalReviewState.inactive
    @Published private(set) var phase2AIDebuggerProposalReview =
        Phase2AIDebuggerProposalReviewState.inactive
    @Published private(set) var phase2AIDebuggerProposalExecutionResults:
        [Phase2AIDebuggerProposalExecutionResult] = []
    @Published private(set) var phase2AIShellOneShotExecutionResults: [Phase2AIShellOneShotExecutionResult] = []
    @Published var phase2AIShellBrokerPTYExecutionResults: [Phase2AIShellBrokerPTYExecutionResult] = []
    let phase2ShellSessionClient: Phase2HumanPTYShellSessionClient
    let phase2ShellBrokerEndpoint: Phase2ShellBrokerEndpoint
    let phase2DurableShellCapabilityStore: Phase2DurableShellBrokerCapabilityStore
    private let phase2ShellTerminalSurfaceID: UUID
    var phase2ShellPendingControls: [UUID] = []
    var phase2ShellActiveControl: UUID?
    var phase2ShellRecoveryGeneration = UUID()
    var phase2ShellRecoveryTask: Task<Void, Never>?
    var phase2DurableLedgerSaverForTesting:
        ((WorkspaceDocumentSession) async -> WorkspaceDocumentWriteOutcome)?
    private weak var phase2DebuggerProposalExecutor: (any Phase2AIDebuggerProposalExecuting)?

    func publishPhase2AssistantAuthoringProposalReview(
        _ review: Phase2AssistantAuthoringProposalReviewState
    ) {
        phase2AssistantAuthoringProposalReview = review
    }
    private var debuggerRetirementTask: Task<Void, Never>?

    private func retainDebuggerDrain(_ drain: Task<Void, Never>?) {
        guard let drain else { return }
        let priorDrain = debuggerRetirementTask
        debuggerRetirementTask = Task { @MainActor in
            await priorDrain?.value
            await drain.value
        }
    }

    func retireDebuggerPresentationSession() {
        let currentDrain = (phase2DebuggerProposalExecutor as? DebuggerPanelViewModel)?
            .beginWorkspaceRetirement()
        phase2DebuggerProposalExecutor = nil
        retainDebuggerDrain(currentDrain)
        updateLiveProgramCounterTarget(nil)
    }

    func debuggerAdmissionDrain(for owner: SavedWatchOwner) -> Task<Void, Never>? {
        guard isCurrentSavedWatchOwner(owner) else { return nil }
        return debuggerRetirementTask
    }

    private func advanceDocumentInstallation() {
        // Revocation is synchronous. The new owner may exist immediately, but cannot execute
        // until its model has awaited every preceding debugger drain.
        retireDebuggerPresentationSession()
        phase2DebuggerReadOnlySnapshot = .empty
        phase2DebuggerReadEvidenceSnapshot = nil
        documentInstallationID = UUID()
        analystFindings = .empty
        pendingAnalystFinding = nil
        analystFindingIssue = nil
        resetNavigatorStates()
    }

    func awaitDebuggerPresentationRetirement() async {
        await debuggerRetirementTask?.value
    }
    private var phase2LastRecordedDebuggerAuthorityKey: Phase2DebuggerRuntimeAuthorityKey?
    private var phase2LastRecordedDebuggerControlAuthorityKey:
        Phase2DebuggerControlledRuntimeAuthorityKey?

    func installPhase2ShellSessionProjection(_ projection: Phase2WorkspaceShellSessionProjection) {
        let publishes = phase2ShellSession.publicationProjection != projection.publicationProjection
        if publishes { objectWillChange.send() }
        phase2ShellSession = projection
        if publishes {
            phase2ShellBrokerPTYBinding = projection.shellBrokerPTYBinding(
                terminalSurfaceID: phase2ShellTerminalSurfaceID
            )
        }
    }

    func updatePhase2DebuggerReadOnlySnapshot(
        _ snapshot: DebuggerSessionSnapshot,
        inspectionCoordinate: DebuggerInspectionCoordinate? = nil
    ) {
        let evidence = Phase2DebuggerReadEvidenceSnapshot(
            session: snapshot,
            coordinate: inspectionCoordinate
        )
        guard phase2DebuggerReadOnlySnapshot != snapshot
            || phase2DebuggerReadEvidenceSnapshot != evidence else { return }
        phase2DebuggerReadOnlySnapshot = snapshot
        phase2DebuggerReadEvidenceSnapshot = evidence
    }

    @discardableResult
    func installPhase2DebuggerProposalExecutor(
        _ executor: any Phase2AIDebuggerProposalExecuting, owner: SavedWatchOwner
    ) -> Bool {
        guard isCurrentSavedWatchOwner(owner) else {
            retainDebuggerDrain((executor as? DebuggerPanelViewModel)?.beginWorkspaceRetirement())
            return false
        }
        // Repeated appearance of the same view is harmless. A second model cannot silently
        // replace this installation's executor after capturing an earlier admission drain.
        if let current = phase2DebuggerProposalExecutor, current !== executor {
            retainDebuggerDrain((executor as? DebuggerPanelViewModel)?.beginWorkspaceRetirement())
            return false
        }
        phase2DebuggerProposalExecutor = executor
        return true
    }

    func updatePhase2DebuggerControlledRuntimeAction(
        _ event: DebuggerControlledRuntimeActionEvent?
    ) {
        guard let event else { return }
        let key = Phase2DebuggerControlledRuntimeAuthorityKey(event: event)
        guard phase2LastRecordedDebuggerControlAuthorityKey != key else { return }
        phase2LastRecordedDebuggerControlAuthorityKey = key
        recordPhase2RuntimeAuthorityUse(
            sessionID: event.sessionID,
            surfaces: [.debuggerControl],
            debuggerAuthorityPolicy: .controlledRuntimeActions,
            providerVisibleShellExecutionEnabled: false,
            createdAt: event.createdAt
        )
    }

    @discardableResult
    func recordPhase2AIDebuggerProposalExecutionResult(
        _ result: Phase2AIDebuggerProposalExecutionResult
    ) -> Phase2AIDebuggerProposalExecutionResult {
        phase2AIDebuggerProposalExecutionResults.insert(result, at: 0)
        if phase2AIDebuggerProposalExecutionResults.count > 20 {
            phase2AIDebuggerProposalExecutionResults.removeLast(
                phase2AIDebuggerProposalExecutionResults.count - 20
            )
        }
        if result.disposition != .dispatched {
            recordPhase2RuntimeAuthorityUse(
                sessionID: result.id,
                surfaces: [.debuggerControl],
                debuggerAuthorityPolicy: .disabled,
                providerVisibleShellExecutionEnabled: false,
                createdAt: result.createdAt
            )
        }
        return result
    }

    @discardableResult
    func stagePhase2AIShellProposalForReview(
        _ proposal: Phase2AIShellCommandProposal
    ) -> Phase2AIShellProposalReviewState {
        let next = Phase2AIShellProposalReviewState.review(proposal: proposal)
        phase2AIShellProposalReview = next
        return next
    }

    func dismissPhase2AIShellProposalReview(proposalID: UUID? = nil) {
        if let proposalID,
           phase2AIShellProposalReview.proposal?.proposalID != proposalID {
            return
        }
        phase2AIShellProposalReview = .inactive
    }

    @discardableResult
    func stagePhase2AIDebuggerProposalForReview(
        _ proposal: Phase2AIDebuggerActionProposal
    ) -> Phase2AIDebuggerProposalReviewState {
        let next = Phase2AIDebuggerProposalReviewState.review(proposal: proposal)
        phase2AIDebuggerProposalReview = next
        return next
    }

    func dismissPhase2AIDebuggerProposalReview(proposalID: UUID? = nil) {
        if let proposalID,
           phase2AIDebuggerProposalReview.proposal?.proposalID != proposalID {
            return
        }
        phase2AIDebuggerProposalReview = .inactive
    }

    @discardableResult
    func approvePhase2AIDebuggerProposalForFutureControl(
        proposalID: UUID? = nil
    ) -> Phase2AIDebuggerProposalReviewState {
        if let proposalID,
           phase2AIDebuggerProposalReview.proposal?.proposalID != proposalID {
            return phase2AIDebuggerProposalReview
        }
        let next = phase2AIDebuggerProposalReview.approvingForFutureDebuggerControl()
        phase2AIDebuggerProposalReview = next
        return next
    }

    @discardableResult
    func rejectPhase2AIDebuggerProposalReviewByUser(
        proposalID: UUID? = nil
    ) -> Phase2AIDebuggerProposalReviewState {
        if let proposalID,
           phase2AIDebuggerProposalReview.proposal?.proposalID != proposalID {
            return phase2AIDebuggerProposalReview
        }
        let next = phase2AIDebuggerProposalReview.rejectingByUser()
        phase2AIDebuggerProposalReview = next
        return next
    }

    @discardableResult
    func executeApprovedPhase2AIDebuggerProposalControl(
        proposalID: UUID? = nil,
        executor injectedExecutor: (any Phase2AIDebuggerProposalExecuting)? = nil
    ) async -> Phase2AIDebuggerProposalExecutionResult {
        let executor = injectedExecutor ?? phase2DebuggerProposalExecutor
        guard let proposal = phase2AIDebuggerProposalReview.proposal,
              phase2AIDebuggerProposalReview.disposition == .staged,
              phase2AIDebuggerProposalReview.humanDecision == .approvedForFutureDebuggerControl
        else {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: phase2AIDebuggerProposalReview.proposal,
                    requestedProposalID: proposalID,
                    disposition: .authorizationRejected,
                    message: "No currently approved debugger proposal is available."
                )
            )
        }
        guard Phase2AIDebuggerProposalValidator.validate(proposal).isAccepted else {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: proposal,
                    disposition: .validationRejected,
                    message: "The approved debugger proposal no longer passes validation."
                )
            )
        }
        if let proposalID, proposal.proposalID != proposalID {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: proposal,
                    disposition: .authorizationRejected,
                    message: "Requested proposal ID does not match the approved debugger proposal."
                )
            )
        }
        guard let executor else {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: proposal,
                    disposition: .debuggerUnavailable,
                    message: "The current debugger surface is not available to execute the approved action."
                )
            )
        }
        let snapshot = executor.phase2CurrentDebuggerSnapshot
        if let mismatch = Self.phase2DebuggerCoordinateMismatch(
            proposal: proposal,
            snapshot: snapshot
        ) {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: proposal,
                    disposition: .staleDebuggerCoordinate,
                    message: mismatch
                )
            )
        }
        if let disabledReason = executor.phase2DebuggerControlUnavailableReason(for: proposal.action) {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: proposal,
                    disposition: .debuggerUnavailable,
                    message: disabledReason
                )
            )
        }

        let executionID = UUID()
        let request = Phase2AIDebuggerProposalExecutionRequest(
            executionID: executionID,
            proposalID: proposal.proposalID,
            action: proposal.action
        )
        guard let event = await executor.phase2ExecuteDebuggerProposalAction(request) else {
            return recordPhase2AIDebuggerProposalExecutionResult(
                .rejected(
                    proposal: proposal,
                    disposition: .debuggerUnavailable,
                    message: "The debugger did not accept the proposed action."
                )
            )
        }
        guard event.correlationID == executionID,
              event.action == proposal.action.debuggerControlAction else {
            return recordPhase2AIDebuggerProposalExecutionResult(
                Phase2AIDebuggerProposalExecutionResult(
                    id: executionID,
                    proposalID: proposal.proposalID,
                    action: proposal.action,
                    disposition: .failed,
                    failureMessage: "The debugger returned an event without the exact proposal execution correlation.",
                    createdAt: Date()
                )
            )
        }
        updatePhase2DebuggerControlledRuntimeAction(event)
        return recordPhase2AIDebuggerProposalExecutionResult(
            Phase2AIDebuggerProposalExecutionResult(
                id: executionID,
                proposalID: proposal.proposalID,
                action: proposal.action,
                runtimeSessionID: event.sessionID,
                lifecycleRevision: event.lifecycleRevision,
                stopRevision: event.stopRevision,
                eventSequence: event.eventSequence,
                disposition: .dispatched,
                failureMessage: nil,
                createdAt: event.createdAt
            )
        )
    }

    private static func phase2DebuggerCoordinateMismatch(
        proposal: Phase2AIDebuggerActionProposal,
        snapshot: DebuggerSessionSnapshot
    ) -> String? {
        guard let session = snapshot.transportSessionCoordinate else {
            return "The current debugger snapshot has no exact runtime session coordinate."
        }
        guard session.epoch.rawValue == proposal.sessionID else {
            return "The approved debugger proposal targets a different debugger session."
        }
        guard session.lifecycleRevision.rawValue == proposal.lifecycleRevision else {
            return "The debugger lifecycle revision changed after the proposal was authored."
        }
        guard snapshot.transportEventSequence?.rawValue == proposal.eventSequence else {
            return "The debugger event sequence changed after the proposal was authored."
        }
        if let proposedStopRevision = proposal.stopRevision {
            guard let stop = snapshot.transportStopCoordinate,
                  stop.session == session,
                  stop.stopRevision.rawValue == proposedStopRevision else {
                return "The debugger stop coordinate changed after the proposal was authored."
            }
        } else if proposal.action.requiresStopCoordinate {
            return "The approved debugger proposal is missing the stopped-process coordinate required by this action."
        }
        return nil
    }

    @discardableResult
    func approvePhase2AIShellProposalForFutureOneShot(
        proposalID: UUID? = nil
    ) -> Phase2AIShellProposalReviewState {
        if let proposalID,
           phase2AIShellProposalReview.proposal?.proposalID != proposalID {
            return phase2AIShellProposalReview
        }
        let next = phase2AIShellProposalReview.approvingForFutureOneShot()
        phase2AIShellProposalReview = next
        return next
    }

    @discardableResult
    func approvePhase2AIShellProposalForFutureShellBrokerPTY(
        proposalID: UUID? = nil
    ) -> Phase2AIShellProposalReviewState {
        if let proposalID,
           phase2AIShellProposalReview.proposal?.proposalID != proposalID {
            return phase2AIShellProposalReview
        }
        let next = phase2AIShellProposalReview.approvingForFutureShellBrokerPTY()
        phase2AIShellProposalReview = next
        return next
    }

    func beginPhase2AIShellBrokerPTYExecution(
        proposalID: UUID
    ) -> Phase2AIShellProposalReviewState? {
        guard phase2AIShellProposalReview.proposal?.proposalID == proposalID,
              let next = phase2AIShellProposalReview.beginningShellBrokerPTYExecution()
        else { return nil }
        phase2AIShellProposalReview = next
        return next
    }

    func consumePhase2AIShellExecutionApproval(proposalID: UUID) {
        guard phase2AIShellProposalReview.proposal?.proposalID == proposalID else { return }
        phase2AIShellProposalReview = phase2AIShellProposalReview.consumingExecutionApproval()
    }

    @discardableResult
    func rejectPhase2AIShellProposalReviewByUser(
        proposalID: UUID? = nil
    ) -> Phase2AIShellProposalReviewState {
        if let proposalID,
           phase2AIShellProposalReview.proposal?.proposalID != proposalID {
            return phase2AIShellProposalReview
        }
        let next = phase2AIShellProposalReview.rejectingByUser()
        phase2AIShellProposalReview = next
        return next
    }

    @discardableResult
    func executeApprovedPhase2AIShellProposalOneShot(
        proposalID: UUID? = nil,
        executor: any Phase2AIShellOneShotExecuting = Phase2AIShellOneShotExecutor()
    ) async -> Phase2AIShellOneShotExecutionResult {
        guard let proposal = phase2AIShellProposalReview.proposal,
              phase2AIShellProposalReview.disposition == .staged,
              phase2AIShellProposalReview.humanDecision == .approvedForFutureOneShot,
              Phase2AIShellProposalValidator.validate(proposal).isAccepted
        else {
            let result = Phase2AIShellOneShotExecutionResult.rejected(
                proposal: phase2AIShellProposalReview.proposal,
                requestedProposalID: proposalID,
                disposition: .authorizationRejected,
                message: "No currently approved restricted one-shot shell proposal is available."
            )
            recordPhase2AIShellOneShotExecutionResult(result)
            recordPhase2RuntimeAuthorityUse(
                sessionID: result.id,
                surfaces: [.providerVisibleShellExecution],
                providerVisibleShellExecutionEnabled: false
            )
            return result
        }
        if let proposalID, proposal.proposalID != proposalID {
            let result = Phase2AIShellOneShotExecutionResult.rejected(
                proposal: proposal,
                disposition: .authorizationRejected,
                message: "Requested proposal ID does not match the approved shell proposal."
            )
            recordPhase2AIShellOneShotExecutionResult(result)
            recordPhase2RuntimeAuthorityUse(
                sessionID: result.id,
                surfaces: [.providerVisibleShellExecution],
                providerVisibleShellExecutionEnabled: false
            )
            return result
        }

        guard let executingReview = phase2AIShellProposalReview.beginningOneShotExecution() else {
            let result = Phase2AIShellOneShotExecutionResult.rejected(
                proposal: proposal,
                disposition: .authorizationRejected,
                message: "The approved restricted one-shot shell proposal was already consumed."
            )
            recordPhase2AIShellOneShotExecutionResult(result)
            return result
        }
        phase2AIShellProposalReview = executingReview

        let result = await executor.run(proposal)
        if phase2AIShellProposalReview.proposal?.proposalID == proposal.proposalID {
            phase2AIShellProposalReview = phase2AIShellProposalReview.consumingExecutionApproval()
        }
        recordPhase2AIShellOneShotExecutionResult(result)
        recordPhase2RuntimeAuthorityUse(
            sessionID: result.id,
            surfaces: [.providerVisibleShellExecution],
            providerVisibleShellExecutionEnabled: result.disposition == .completed
        )
        return result
    }

    /// Same-turn continuation variant. The caller must durably reserve `executionID` before this
    /// method is entered. Existing PTY execution is intentionally not routed through this seam.
    @discardableResult
    func executeApprovedPhase2AIShellProposalOneShot(
        expectedProposal: Phase2AIShellCommandProposal,
        reservedExecutionID executionID: UUID,
        executor: any Phase2AIShellOneShotExecuting = Phase2AIShellOneShotExecutor()
    ) async -> Phase2AIShellOneShotExecutionResult {
        guard let proposal = phase2AIShellProposalReview.proposal,
              proposal == expectedProposal,
              Phase2AssistantShellProposalCanonicalizer.digest(proposal)
                == Phase2AssistantShellProposalCanonicalizer.digest(expectedProposal),
              proposal.executionSurface == .restrictedOneShotJob,
              phase2AIShellProposalReview.disposition == .staged,
              phase2AIShellProposalReview.humanDecision == .approvedForFutureOneShot,
              Phase2AIShellProposalValidator.validate(proposal).isAccepted,
              let executingReview = phase2AIShellProposalReview.beginningOneShotExecution()
        else {
            return .rejected(
                proposal: phase2AIShellProposalReview.proposal,
                requestedProposalID: expectedProposal.proposalID,
                disposition: .authorizationRejected,
                message: "No exact approved restricted one-shot proposal is available."
            )
        }

        // Approval consumption becomes visible before the external process can start.
        phase2AIShellProposalReview = executingReview
        let unbound = await executor.run(proposal)
        let result = Phase2AIShellOneShotExecutionResult(
            id: executionID,
            schemaVersion: unbound.schemaVersion,
            proposalID: unbound.proposalID,
            executablePath: unbound.executablePath,
            arguments: unbound.arguments,
            workingDirectoryPath: unbound.workingDirectoryPath,
            timeoutMilliseconds: unbound.timeoutMilliseconds,
            maximumOutputBytes: unbound.maximumOutputBytes,
            disposition: unbound.disposition,
            terminationStatus: unbound.terminationStatus,
            standardOutput: unbound.standardOutput,
            standardError: unbound.standardError,
            outputWasTruncated: unbound.outputWasTruncated,
            startedAt: unbound.startedAt,
            completedAt: unbound.completedAt,
            failureMessage: unbound.failureMessage
        )
        if phase2AIShellProposalReview.proposal == expectedProposal {
            phase2AIShellProposalReview = phase2AIShellProposalReview.consumingExecutionApproval()
        }
        recordPhase2AIShellOneShotExecutionResult(result)
        recordPhase2RuntimeAuthorityUse(
            sessionID: executionID,
            surfaces: [.providerVisibleShellExecution],
            providerVisibleShellExecutionEnabled: result.disposition == .completed
        )
        return result
    }

    private func recordPhase2AIShellOneShotExecutionResult(
        _ result: Phase2AIShellOneShotExecutionResult
    ) {
        phase2AIShellOneShotExecutionResults.insert(result, at: 0)
        if phase2AIShellOneShotExecutionResults.count
            > Phase2AIShellExecutionResultRetention.maximumResults {
            phase2AIShellOneShotExecutionResults.removeLast(
                phase2AIShellOneShotExecutionResults.count
                    - Phase2AIShellExecutionResultRetention.maximumResults
            )
        }
    }

    func phase2ProviderVisibleShellExecutionEvidenceText(
        maximumResults: Int = 3,
        maximumUTF8Bytes: Int = 8_192,
        maximumStreamBytes: Int = 2_048,
        executionID: UUID? = nil
    ) -> String? {
        guard maximumResults > 0, maximumUTF8Bytes > 0 else { return nil }
        let visibleExecutionIDs = Set(
            phase2RuntimeAuthorityRecords.compactMap { record -> UUID? in
                guard record.providerVisibleShellExecutionEnabled,
                      record.surfaces.contains(.providerVisibleShellExecution)
                else { return nil }
                return record.sessionID
            }
        )
        guard !visibleExecutionIDs.isEmpty else { return nil }

        let oneShotEvidence = phase2AIShellOneShotExecutionResults
            .filter { result in
                visibleExecutionIDs.contains(result.id)
                    && result.disposition == .completed
                    && (executionID == nil || result.id == executionID)
            }
            .map { result in
                (
                    result.completedAt,
                    result.providerVisibleEvidenceText(maximumStreamBytes: maximumStreamBytes)
                )
            }
        let shellBrokerPTYEvidence = phase2AIShellBrokerPTYExecutionResults
            .filter { result in
                visibleExecutionIDs.contains(result.id)
                    && result.disposition == .dispatched
                    && (executionID == nil || result.id == executionID)
            }
            .map { result in
                (
                    result.createdAt,
                    result.providerVisibleEvidenceText(maximumUTF8Bytes: maximumStreamBytes)
                )
            }
        let visibleResults = (oneShotEvidence + shellBrokerPTYEvidence)
            .sorted { lhs, rhs in lhs.0 > rhs.0 }
            .prefix(maximumResults)
        guard !visibleResults.isEmpty else { return nil }

        let body = visibleResults
            .enumerated()
            .map { index, result in
                "Shell execution \(index + 1):\n" + result.1
            }
            .joined(separator: "\n\n")
        return Phase2AIShellOneShotExecutionResult.truncatedUTF8(body, maximumBytes: maximumUTF8Bytes)
    }

    func phase2ProviderVisibleDebuggerEvidenceText(maximumUTF8Bytes: Int = 4_096) -> String? {
        phase2DebuggerReadEvidenceSnapshot?.providerVisibleEvidenceText(
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    func phase2ProviderVisibleDebuggerControlEvidenceText(
        maximumResults: Int = 3,
        maximumUTF8Bytes: Int = 4_096,
        maximumResultBytes: Int = 1_024,
        executionID: UUID? = nil
    ) -> String? {
        guard maximumResults > 0, maximumUTF8Bytes > 0 else { return nil }
        let visibleSessionIDs = Set(
            phase2RuntimeAuthorityRecords.compactMap { record -> UUID? in
                guard record.surfaces.contains(.debuggerControl),
                      record.debuggerAuthorityPolicy == .controlledRuntimeActions
                else { return nil }
                return record.sessionID
            }
        )
        guard !visibleSessionIDs.isEmpty else { return nil }

        let visibleResults = phase2AIDebuggerProposalExecutionResults
            .filter { result in
                result.disposition == .dispatched
                    && result.runtimeSessionID.map(visibleSessionIDs.contains) == true
                    && (executionID == nil || result.id == executionID)
            }
            .prefix(maximumResults)
        guard !visibleResults.isEmpty else { return nil }

        let body = visibleResults
            .enumerated()
            .map { index, result in
                "Debugger control execution \(index + 1):\n"
                    + result.providerVisibleEvidenceText(maximumUTF8Bytes: maximumResultBytes)
            }
            .joined(separator: "\n\n")
        return Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            body,
            maximumBytes: maximumUTF8Bytes
        )
    }

    func phase2DebuggerReadOnlyRuntimeAuthorityConsumption(
        provenance: Phase2DebuggerReadOperationProvenance
    ) -> Phase2DebuggerReadOnlyRuntimeAuthorityConsumption? {
        guard let evidence = phase2DebuggerReadEvidenceSnapshot,
              evidence.evidenceDigest == provenance.evidenceDigest else { return nil }
        let snapshot = phase2DebuggerReadOnlySnapshot
        guard snapshot.providerVisibleReadOnlyEvidenceText(maximumUTF8Bytes: 1) != nil,
              let key = Phase2DebuggerRuntimeAuthorityKey(snapshot: snapshot),
              key.sessionID == provenance.sessionEpoch,
              key.lifecycleRevision == provenance.lifecycleRevision,
              key.stopRevision == provenance.stopRevision
        else { return nil }
        return .init(
            evidenceDigest: provenance.evidenceDigest,
            sessionID: key.sessionID,
            lifecycleRevision: key.lifecycleRevision,
            stopRevision: key.stopRevision,
            eventSequence: key.eventSequence
        )
    }

    /// Records read-only debugger authority only when an exact typed evidence cut is actually
    /// consumed for provider-visible inference. The immutable consumption was captured before
    /// dispatch, so a later debugger stop cannot erase or misattribute the audit event.
    @discardableResult
    func recordPhase2DebuggerReadOnlyRuntimeAuthorityConsumption(
        _ consumption: Phase2DebuggerReadOnlyRuntimeAuthorityConsumption
    ) -> Bool {
        let key = Phase2DebuggerRuntimeAuthorityKey(
            sessionID: consumption.sessionID,
            lifecycleRevision: consumption.lifecycleRevision,
            stopRevision: consumption.stopRevision,
            eventSequence: consumption.eventSequence
        )
        guard
              phase2LastRecordedDebuggerAuthorityKey != key,
              !phase2RuntimeAuthorityRecords.contains(where: { record in
                  record.sessionID == key.sessionID
                      && record.surfaces == [.debuggerReadOnly]
                      && record.debuggerAuthorityPolicy == .readOnlyInspection
              })
        else { return true }
        phase2LastRecordedDebuggerAuthorityKey = key
        recordPhase2RuntimeAuthorityUse(
            sessionID: key.sessionID,
            surfaces: [.debuggerReadOnly],
            debuggerAuthorityPolicy: .readOnlyInspection,
            providerVisibleShellExecutionEnabled: false
        )
        return true
    }

    @discardableResult
    func recordPhase2DebuggerReadOnlyRuntimeAuthorityConsumption(
        evidenceDigest: String
    ) -> Bool {
        guard let evidence = phase2DebuggerReadEvidenceSnapshot,
              evidence.evidenceDigest == evidenceDigest,
              let key = Phase2DebuggerRuntimeAuthorityKey(snapshot: phase2DebuggerReadOnlySnapshot)
        else { return false }
        return recordPhase2DebuggerReadOnlyRuntimeAuthorityConsumption(.init(
            evidenceDigest: evidenceDigest,
            sessionID: key.sessionID,
            lifecycleRevision: key.lifecycleRevision,
            stopRevision: key.stopRevision,
            eventSequence: key.eventSequence
        ))
    }
    /// The window's `UndoManager`, injected from `@Environment(\.undoManager)` by
    /// the root view. When present, authoring mutations register against it so the
    /// standard Edit ▸ Undo/Redo items, Cmd-Z, and dynamic "Undo Rename" titles work
    /// natively — and because it's the same window-scoped manager the responder
    /// chain resolves, a focused text field still gets its own typing-undo. Held
    /// weakly; the window owns it. Nil in tests / headless launches.
    weak var hostUndoManager: UndoManager?

    /// Fallback used when no window manager is available (tests, headless).
    /// `groupsByEvent` is disabled so a discrete edit is a closed, undoable step
    /// immediately, without a run-loop turn to flush the per-event group.
    private let fallbackUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    /// Current undo-target generation for each occupied authoring slot. Replacing/removing an
    /// entry creates a new object identity, so actions from a vacated generation can never become
    /// valid merely because the same numeric slot is occupied again later.
    private var slotUndoTargets: [ImageSlot: WorkspaceSlotUndoTarget] = [:]

    /// Drives Edit ▸ Undo/Redo for authoring mutations (renames, comments). Resolves
    /// to the injected window manager when available — wiring undo to the menu and
    /// Cmd-Z — otherwise the in-memory fallback.
    var undoManager: UndoManager { hostUndoManager ?? fallbackUndoManager }

    private func undoTarget(for slot: ImageSlot) -> WorkspaceSlotUndoTarget {
        if let current = slotUndoTargets[slot] {
            return current
        }
        let target = WorkspaceSlotUndoTarget(store: self, slot: slot)
        slotUndoTargets[slot] = target
        return target
    }

    /// The workspace identity a navigator producer run captures when it starts: the installed
    /// document, the whole-workspace reanalysis epoch, the slot's landing epoch and its binary owner.
    /// A run lands only when all four are unchanged.
    func navigatorLandingFence(for slot: ImageSlot) -> NavigatorLandingFence {
        NavigatorLandingFence(
            documentInstallationID: documentInstallationID,
            workspaceEpoch: reanalysisWorkspaceEpoch,
            landingEpoch: reanalysisLandingEpochsBySlot[slot] ?? 0,
            binaryID: snapshot.binary(in: slot)?.id
        )
    }

    /// Registers `action` as the Undo (or, while undoing, the Redo) of a slot-owned mutation on that
    /// slot's undo target, so retiring the slot's history (owner change or remap) retires it too.
    func registerSlotScopedUndo(in slot: ImageSlot, _ action: @escaping @MainActor (WorkspaceStore) -> Void) {
        undoManager.registerUndo(withTarget: undoTargetForRegistration(in: slot)) { target in
            guard let store = target.store else { return }
            action(store)
        }
    }

    private func undoTargetForRegistration(in slot: ImageSlot) -> WorkspaceSlotUndoTarget {
        let target = undoTarget(for: slot)
        if undoManager.isUndoing {
            target.appliedMutationCount = max(0, target.appliedMutationCount - 1)
        } else {
            // Both an initial edit and redo leave the registered mutation applied.
            target.appliedMutationCount += 1
        }
        return target
    }

    /// Retires both undo and redo actions owned by one vacated slot generation. The dirty-token
    /// generation advances only when that slot ever registered history; with no retired history,
    /// an unaffected sibling action may still legitimately rewind to the original clean baseline.
    private func retireUndoHistory(in slot: ImageSlot) {
        guard let target = slotUndoTargets.removeValue(forKey: slot) else { return }
        hostUndoManager?.removeAllActions(withTarget: target)
        fallbackUndoManager.removeAllActions(withTarget: target)
        if target.appliedMutationCount > 0 {
            dirtyUndoTokenGeneration &+= 1
        }
    }

    /// A numeric slot is only half of an undo target's identity. Direct snapshot replacement and
    /// image removal can vacate or reuse a slot without passing through `remapImageSlot`, so compare
    /// durable binary owners on every externally coordinated snapshot publication and retire only
    /// generations whose owner actually changed. Same-owner reanalysis deliberately keeps history.
    private func retireUndoHistoryForChangedBinaryOwners(from priorSnapshot: WorkspaceSnapshot) {
        let priorOwners = Dictionary(uniqueKeysWithValues: priorSnapshot.binaries.map { ($0.slot, $0.id) })
        let currentOwners = Dictionary(uniqueKeysWithValues: snapshot.binaries.map { ($0.slot, $0.id) })
        let candidateSlots = Set(priorOwners.keys).union(currentOwners.keys)

        for slot in candidateSlots where priorOwners[slot] != currentOwners[slot] {
            retireUndoHistory(in: slot)
            dropNavigatorState(in: slot)
        }
    }

    private func reconcileDebuggerWorkspaceArtifactCatalog(
        fullWorkspaceReplacement: Bool = false
    ) {
        let next = debuggerWorkspaceArtifactCatalogLedger.reconcile(
            snapshot: snapshot,
            fullWorkspaceReplacement: fullWorkspaceReplacement
        )
        if next != debuggerWorkspaceArtifactCatalog {
            debuggerWorkspaceArtifactCatalog = next
        }
    }

    private func reconcileDebuggerBreakpointResolutionCatalog(
        fullWorkspaceReplacement: Bool = false
    ) {
        let next = debuggerBreakpointResolutionCatalogLedger.reconcile(
            snapshot: snapshot,
            workspaceID: workspaceID,
            artifactCatalog: debuggerWorkspaceArtifactCatalog,
            fullWorkspaceReplacement: fullWorkspaceReplacement
        )
        if next != debuggerBreakpointResolutionCatalog {
            debuggerBreakpointResolutionCatalog = next
        }
    }

    @Published var selectedSidebarItemID: SidebarItem.ID?
    /// One-shot UI focus-transfer request for a programmatic source reveal. Selection is durable
    /// session state; keyboard focus is not. Keeping this transient prevents a reopened workspace
    /// from stealing focus merely because it restores a selected sidebar row.
    @Published private(set) var sidebarKeyboardFocusRequestID: SidebarItem.ID?
    /// The sole mutable runtime authority for an interactive workspace location. A bare virtual
    /// address is not workspace-unique: two loaded images may legitimately contain the same value.
    @Published private(set) var selectedImageAddress: ImageAddress? = nil {
        willSet { revokePatternPublication() }
        didSet {
            if oldValue != selectedImageAddress { cancelObjCSignatureInference() }
        }
    }

    /// Compatibility projection for existing synchronous, focused-image call sites and persisted
    /// session state. Direct assignment qualifies the address to the exact focused loaded image and
    /// rejects an address that image does not own. It is deliberately computed so it cannot drift
    /// independently from `selectedImageAddress`.
    var selectedAddress: UInt64? {
        get { selectedImageAddress?.address }
        set {
            // Any explicit interactive assignment supersedes the invisible restore-time intent.
            // Otherwise select-Q/clear-Q while rehydration is pending can resurrect stale P later.
            pendingRehydratedSelection = nil
            guard let newValue else {
                xrefCursor = nil
                clearInteractiveSelection()
                return
            }

            let slot = focusedImageSlot
            let target = ImageAddress(slot: slot, address: newValue)
            guard snapshot.containsLoadedAddress(newValue, in: slot) else {
                xrefCursor = nil
                clearInteractiveSelection()
                return
            }
            clearXRefCursorIfUnrelated(to: newValue)
            selectedImageAddress = target
        }
    }
    @Published var selectedGraphElementID: String?
    /// The exact image-owned starts of the graph nodes in the current color group. This state is
    /// transient and deliberately store-owned so focus/snapshot/reanalysis lifecycle changes can
    /// invalidate a delayed group action before it mutates authoring state.
    @Published private(set) var graphNodeMultiSelection: Set<ImageAddress> = []
    /// Suppresses the `snapshot` observer while one method is installing a snapshot together with
    /// its corresponding focus/selection identity (restore or slot remap). The coordinated method
    /// performs one explicit validation after all three values are available.
    private var isCoordinatingSnapshotIdentityChange = false
    /// Prevents the one normalization write needed by an externally supplied stale compatibility
    /// projection from recursively re-entering `snapshot.didSet`. The outer observer still owns
    /// all reconciliation so one logical publication produces one derived-state update.
    private var isNormalizingLogicalBreakpointCompatibility = false
    /// The debugger's stopped PC qualified by its immutable live workspace owner. The bare
    /// projection is exposed only when this owner is also the focused image.
    @Published private(set) var liveProgramCounterTarget: ImageAddress?
    /// Runtime-only, per-image coordination tokens for debugger breakpoint reconciliation.
    /// The window's debugger session as the Debug sidebar shows it (published by the editor's
    /// debugger view model; see WorkspaceStore+DebugExtensionsSidebar.swift).
    @Published var debuggerSidebarSummary = DebuggerSidebarSummary.notStarted
    @Published private(set) var debuggerBreakpointRevisions: [ImageSlot: UInt64] = [:]
    /// Changes whenever owner invalidation or revision rollover makes older tokens incomparable.
    @Published private(set) var debuggerBreakpointRevisionGeneration: UInt64 = 0
    private var lastKnownDebuggerBreakpointSets: [ImageSlot: Set<UInt64>] = [:]
    private var lastKnownDebuggerBinaryIDs: [ImageSlot: UUID] = [:]
    @Published var selectedTool: WorkspaceTool = .project
    /// Transient presentation selection only. Durable job identity and state remain database-owned;
    /// an invalid value is ignored in favor of creation-ordinal fallback by the projection layer.
    @Published var selectedReconstructionJobID: UUID?
    @Published var editorMode: EditorMode = .disassembly {
        didSet {
            guard !suppressHistoryRecording, let address = selectedAddress,
                  let location = navigationLocation(at: address) else { return }
            navigationHistory.updateCurrent(location)
        }
    }
    @Published var isInspectorPresented = true
    /// U8-0: the navigator sidebar, shown and hidden by the window's left toggle (⌃⌘S).
    @Published var isSidebarPresented = true
    /// Per-window presentation only; hiding a deck does not end its runtime session.
    @Published var bottomPanelPresentation = WorkspaceBottomPanelPresentation()
    @Published var isImporting = false
    /// HOP-3: the import's latest analysis phase (nil before the first report and when idle).
    @Published private(set) var analysisProgress: AnalysisProgress?
    /// The in-flight initial import, held so it can be cancelled — by the user (Cancel button /
    /// Esc on the "Indexing binary" panel), by a superseding import, or on window close (`deinit`).
    /// `nonisolated(unsafe)` because `Task.cancel()` (thread-safe; `Task` is `Sendable`) runs from
    /// the nonisolated deinit, same justification as `reanalysisTasksBySlot` / observer tokens;
    /// all writes stay on the main actor.
    private nonisolated(unsafe) var importTask: Task<Void, Never>?
    /// File-format inspection can map and hash a bounded archive before the picker appears. Keep
    /// that work off-main and independently cancellable from the authoritative import that follows.
    private nonisolated(unsafe) var loaderOptionsInspectionTask: Task<Void, Never>?
    /// Main-actor publication fence: a cancelled/superseded inspection may finish its current I/O,
    /// but it can never publish a sheet or start a load for an older Open request.
    private var loaderOptionsInspectionGeneration: UInt64 = 0

    /// Automatic window restoration yields as soon as an explicit load is requested, not
    /// merely once inspection finishes and import progress or a slice picker becomes visible.
    /// Keep this true after cancellation/failure so restoration cannot revive an older request.
    var hasRequestedBinaryLoad: Bool { loaderOptionsInspectionGeneration != 0 }
    /// The dyld-cache differential is supplemental and transient. It never replaces the primary
    /// snapshot, participates in persistence, or delays an authoritative import.
    private nonisolated(unsafe) var dyldCacheDifferentialTask: Task<Void, Never>?
    private nonisolated(unsafe) var dyldCacheDifferentialCancellation:
        DyldCacheSupplementalCancellation?
    private var dyldCacheDifferentialEpoch: UInt64 = 0
    @Published private(set) var dyldCacheDifferentialReport: DyldCacheDifferentialWorkflowReport?
    @Published var lastIssue: String?
    /// Drives the modal Rename / Edit-Comment editor sheet. Set by the command
    /// palette (or context actions); cleared on commit/cancel.
    @Published var overrideEditorRequest: OverrideEditorRequest?
    /// Drives the modal function-signature editor sheet.
    var objcDeclarationSourceGenerations: [ImageSlot: UUID] = [:]
    var objcSignatureDeclarations: [ImageSlot: ObjCSignatureDeclarationBatch] = [:]
    var objcSignatureInferenceTask: Task<Void, Never>?
    @Published var signatureEditorRequest: SignatureEditorRequest? {
        didSet {
            if oldValue?.id != signatureEditorRequest?.id {
                objcSignatureInferenceTask?.cancel()
                objcSignatureInferenceTask = nil
            }
        }
    }
    /// Drives the modal type-definition editor sheet.
    @Published var typeEditorRequest: TypeEditorRequest?
    @Published var switchHintEditorRequest: SwitchHintEditorRequest?
    /// Drives the open-time loader-options dialog (fat/universal slice picker). Set by
    /// `beginImport(url:)` when a binary needs a slice choice; cleared on confirm/cancel.
    @Published var loaderOptionsRequest: LoaderOptionsRequest?
    @Published private(set) var binaryOpenState: WorkspaceBinaryOpenState?
    /// Drives the modal Make Data sheet (array/string/alignment). Set by the Procedure ▸
    /// Make Data command (or the listing context menu); cleared on commit/cancel.
    @Published var dataShapeEditorRequest: DataShapeEditorRequest?
    /// Drives the modal Rename Register sheet. Set by the Procedure ▸ Rename Register command
    /// (no pre-filled register) or the pseudocode context menu (register pre-filled); cleared
    /// on commit/cancel.
    @Published var registerRenameRequest: RegisterRenameRequest?
    /// Drives the modal Import C Header sheet. Set by File ▸ Import C Header; cleared on
    /// commit/cancel.
    @Published var cHeaderImportRequest: CHeaderImportRequest?
    /// The most recent C-header import summary (added type names + diagnostics), surfaced
    /// in the Import C Header sheet after a commit. Cleared when the sheet reopens.
    @Published var cHeaderImportSummary: CHeaderImportSummary?
    @Published var searchSheetPresentation: SearchSheetPresentation = .goToAddress
    @Published var showGoTo = false
    @Published var showFind = false
    /// The active Find result set as a steppable cursor, seeded when a search runs. Drives
    /// Find Next / Find Previous (Cmd-G / Shift-Cmd-G); nil/empty disables them.
    @Published var searchCursor: SearchResultCursor?
    /// Non-nil while the Patch Bytes… sheet is presented (set by the `.patchBytes`
    /// command, cleared on apply/cancel).
    @Published var pendingPatchBytesRequest: PatchBytesRequest?
    /// Non-nil while the request-owned Assemble Instruction… sheet is presented.
    @Published var pendingAssembleRequest: AssembleRequest?
    /// Presentation tokens retired by an owner lifecycle transition or explicit dismissal. Tokens
    /// are never removed, so remapping a slot away and later back cannot revive an old callback.
    private var invalidatedAuthoringPresentationIDs: Set<UUID> = []
    /// IDs created by the interactive Make Data presenter. Such a request can never fall through
    /// to the binary-less synchronous compatibility seam after it has been dismissed.
    private var presentedDataShapeEditorRequestIDs: Set<UUID> = []
    /// Cursor for Next XREF / Previous XREF, cycling the referrers of a fixed anchor
    /// address. Rebuilt when stepping starts from outside the current cursor's orbit.
    @Published var xrefCursor: XRefStepCursor?
    /// The clipboard the Copy commands write to. Injectable for tests.
    var pasteboard: WorkspacePasteboard = SystemPasteboard()
    /// Records opened/saved `.mscope` projects so File ▸ Open Recent can reopen them. Injected
    /// so the record-on-open/save behavior is testable without touching the system recents.
    var recents: WorkspaceRecentsRecording = SystemDocumentRecents()
    /// Drives the Imports/Exports/Sections browser sheet (three distinct browsers,
    /// surfaced here as one segmented panel).
    @Published var showBrowsers = false
    /// The browser pane shown when `showBrowsers` is presented.
    @Published var browserSelection: BrowserPane = .imports
    @Published var sidebarSearchText = ""
    /// U8-3: the Symbols and Strings navigators' rule filters, per tool, for this window.
    @Published var navigatorFilterRules: [WorkspaceTool: NavigatorFilterRules] = [:]

    /// Drives the browsable Navigation History panel (View ▸ Navigation History). Lists the
    /// back/forward visit stack; selecting a row jumps there without truncating forward history.
    @Published var showNavigationHistory = false

    /// Drives the analysis Problems panel (View ▸ Problems). The panel lists
    /// `snapshot.diagnostics`; selecting a row jumps the editor to the diagnostic's address.
    @Published var showProblems = false

    /// Drives the Mach-O Signature & Dependencies panel (View ▸ Signature & Dependencies),
    /// which surfaces `snapshot.machOMetadata` (code signature / imports / dependent dylibs).
    @Published var showREAWorkbench = false
    @Published var reaResultEvidence = try! REAResultEvidenceStore()
    @Published var showMachOMetadata = false

    /// Back/forward navigation history of visited addresses. Published so the
    /// toolbar/menu Back/Forward affordances enable and disable as it changes.
    private let navigationHistorySessionID = UUID()
    private let savedWatchOwnerSessionID = UUID()
    @Published private(set) var documentInstallationID = UUID()
    @Published private(set) var analystFindings = AnalystFindingEnvelope.empty
    @Published private(set) var pendingAnalystFinding: PendingAnalystFinding?
    @Published private(set) var analystFindingIssue: String?

    func publishAnalystFindings(_ value: AnalystFindingEnvelope) { analystFindings = value }
    func publishPendingAnalystFinding(_ value: PendingAnalystFinding?) { pendingAnalystFinding = value }
    func publishAnalystFindingIssue(_ value: String?) { analystFindingIssue = value }


    struct SavedWatchOwner: Equatable {
        fileprivate let sessionID: UUID
        fileprivate let installationID: UUID
        let workspaceID: UUID
        let documentID: UUID
    }

    var savedWatchCatalog: WorkspaceSavedWatchCatalog { snapshot.savedWatchCatalog }

    func captureSavedWatchOwner() -> SavedWatchOwner? {
        guard !documentSessionWriterRetired else { return nil }
        return SavedWatchOwner(sessionID: savedWatchOwnerSessionID,
                              installationID: documentInstallationID,
                              workspaceID: workspaceID, documentID: documentID)
    }

    func isCurrentSavedWatchOwner(_ owner: SavedWatchOwner) -> Bool {
        owner == captureSavedWatchOwner()
    }

    /// Called synchronously before model authoring commits. A stale workspace model cannot
    /// overwrite another document; restoring definitions never evaluates them.
    func replaceSavedWatchDefinitions(
        _ definitions: [WorkspaceSavedWatchDefinition], owner: SavedWatchOwner
    ) throws {
        guard owner == captureSavedWatchOwner() else {
            throw WorkspaceDocumentSessionError.closed
        }
        let catalog = try WorkspaceSavedWatchCatalog(definitions: definitions)
        guard catalog != snapshot.savedWatchCatalog else { return }
        var next = snapshot
        next.savedWatchCatalog = catalog
        snapshot = next
        markDocumentMutated()
    }
    @Published private var navigationHistory = WorkspaceNavigationHistory()
    /// Suppresses history recording while replaying a Back/Forward navigation or
    /// while arrow-stepping between adjacent nodes — neither should append an entry.
    private var suppressHistoryRecording = false

    private(set) var persistedWorkspaceID: Int64?
    private(set) var documentMetadata: WorkspaceDatabase.WorkspaceDocumentMetadata?
    /// App-owned logical identities. Unlike the scratch database row id above, these values are
    /// durable across Save, autosave, Save As, and reopen.
    private(set) var documentID: UUID
    private(set) var workspaceID: UUID { willSet { revokePatternPublication() } }
    private(set) var reconstructionState: ReconstructionWorkspaceState = .empty
    /// F3: durable job/task lifecycle timestamps of the last published commit. They live in the
    /// runtime database's lifecycle columns, not in `reconstructionState`; empty until a commit
    /// publishes them (e.g. right after reopen), in which case job status reads fall back to the
    /// phase-sum elapsed time.
    private(set) var reconstructionLifecycle: ReconstructionLifecycleTimestamps = .empty

    struct ReconstructionPublicationAuthority: Sendable {
        fileprivate let workspaceID: UUID
        fileprivate let documentID: UUID
        fileprivate let lifecycleEpoch: UInt64
    }

    enum ReconstructionPublicationError: Error, Equatable {
        case authorityExhausted
    }

    /// Reconstruction commits may return after a restore/import has installed a different logical
    /// store lifecycle. Unlike document mutation generation, this advances only at those replacement
    /// boundaries, so an unrelated edit does not prevent a valid durable reconstruction result from
    /// publishing into the still-current store.
    private var reconstructionPublicationLifecycleEpoch: UInt64 = 0
    private var reconstructionPublicationLifecycleEpochExhausted = false
    /// Highest durable reconstruction commit published in the current logical Store lifecycle.
    /// Sequence zero is reserved for legacy synthetic callers and never advances this watermark.
    private var highestPublishedReconstructionCommitSequence: UInt64?
    /// A base workspace insert/replace may commit before reconstruction persistence fails. Only
    /// that known partial-save condition authorizes a later save to replay the in-memory aggregate.
    private var reconstructionPersistenceRetryPending = false
    private(set) var reconstructionAttachmentSources: [ReconstructionAttachmentSource] = []
    @Published private(set) var phase2AssistantSessionHistory: [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord] = []
    private var phase2AssistantInFlightConversationIDs: Set<UUID> = []
    @Published private(set) var phase2RuntimeAuthorityRecords: [WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord] = []
    /// The on-disk `.mscope` package this workspace was last saved to or opened
    /// from — the target for a plain Save. Nil until the first Save As / opened
    /// package, in which case Save falls back to presenting a Save-As panel.
    /// `@Published` so the window title reflects the current document.
    @Published private(set) var documentURL: URL?
    /// The most recent Save failure message, surfaced as an alert. Kept separate
    /// from `lastIssue` (the import/analysis banner channel) so a save error is
    /// never mislabeled as an import failure and a successful save doesn't clear an
    /// unrelated banner.
    @Published var saveError: String?

    /// A non-error informational message surfaced as an alert (e.g. the "patched binary is
    /// unsigned — re-sign with codesign" note after Save Patched Binary). Kept separate from
    /// `saveError` so a success note is never titled "Save Failed".
    @Published var infoMessage: String?

    /// Success note after a "Read Debug Symbols File…" import (how many names were applied).
    /// A dedicated channel so its alert is titled "Debug Symbols Imported", not the patched-
    /// binary or save-failed titles. nil unless an import just succeeded.
    @Published var debugSymbolsResultMessage: String?

    /// Failure note after a dSYM import (unreadable file, UUID mismatch, malformed DWARF, …).
    /// Separate from `saveError` so a UUID-mismatch is never mislabeled "Save Failed".
    @Published var debugSymbolsImportError: String?

    /// `true` whenever the document holds persisted edits not yet written to disk.
    /// Driven entirely by `dirtyTracker`; the window chrome ("Edited" close button,
    /// title-bar dot) and the autosave gate both observe it. Undo back to the last
    /// saved point clears it (see `DocumentDirtyTracker`).
    @Published private(set) var isDirty = false
    /// Catalog-atomic corruption latch. An unavailable catalog arms zero logical breakpoints and
    /// blocks ordinary authoring/save/autosave until the dedicated confirmed discard repair.
    @Published private(set) var logicalBreakpointCatalogAvailability:
        DebuggerLogicalBreakpointCatalogAvailability = .available
    /// Catalog-atomic launch-profile corruption latch. This authority is independent from logical
    /// breakpoints: repairing either catalog never clears the other catalog's conflict.
    @Published private(set) var launchProfileCatalogAvailability:
        DebuggerLaunchProfileCatalogAvailability = .available

    /// Pure dirty-state bookkeeping. Bumped on every persisted mutation, rewound by
    /// undo/redo, cleared on a successful save. Kept private so the only way to
    /// move dirty-state is through `markDocumentMutated` / `markDocumentSaved`.
    private var dirtyTracker = DocumentDirtyTracker()
    /// Strictly monotonic persisted-content event identity. Unlike `dirtyTracker.revision`, this
    /// never rewinds on undo: asynchronous document writes use it solely to reject stale
    /// completions while `dirtyTracker` remains the independent clean/dirty authority.
    private var documentMutationEventCounter: UInt64 = 0
    /// Once the event identity can no longer advance, no later write can be proven current. Keep
    /// the latch permanent and fail closed instead of wrapping into an earlier generation.
    private var documentMutationGenerationExhausted = false
    private struct DocumentWriteCapture {
        let generation: WorkspaceDocumentMutationGeneration
        let dirtyToken: Int
        let reconstructionContentIdentities: [ReconstructionContentIdentity]
    }
    /// A session admits only one write at a time, so one exact generation-to-dirty-token mapping
    /// is sufficient and prevents an unbounded history of stale save authority.
    private var activeDocumentWriteCapture: DocumentWriteCapture?
    /// The registry owns both objects. This weak callback lets the future per-window session mirror
    /// source changes without creating a store/session retain cycle.
    private weak var documentSessionMutationObserver:
        (any WorkspaceDocumentMutationObserving)?
    /// Selective history pruning makes old scalar revision tokens incomparable: a discarded slot-B
    /// edit can remain in the remapped snapshot while a surviving slot-A undo still holds a token
    /// from before B. Advancing this generation invalidates those old rewind tokens without
    /// discarding the surviving actions themselves.
    private var dirtyUndoTokenGeneration: UInt64 = 0

    struct DirtyUndoToken {
        let trackerToken: Int
        let generation: UInt64
    }

    /// Injectable autosave scheduler. Defaults to a real debounced timer; tests
    /// swap in a manual trigger so the "should autosave now" decision is exercised
    /// without any wall-clock sleep. `nil` disables autosave entirely.
    var autosaveScheduler: AutosaveScheduling?
    /// The analysis provider behind the `AnalysisProviding` seam. In-process `AnalysisEngine`
    /// today; the WS-3 XPC worker later — the store never knows the difference.
    private let engine: any AnalysisProviding
    /// Per-window supplemental authority. A coordinator is never shared between stores because
    /// its generation fence intentionally makes a newer request supersede an older one.
    private let dyldCacheDifferentialWorkflow: DyldCacheDifferentialWorkflowCoordinator?
    private let dyldCacheNativeFactsBuilder: any DyldCacheNativeCatalogFactBuilding
    /// One document-scoped native-drive authority. It remains inert in headless/test stores until
    /// a runtime session is bound, while preserving pending restore intent across binding order.
    let nativeDecompilerDriveContext = WorkspaceNativeDecompilerDriveContext()

    /// `true` while a structural override (mark-as-code/data/procedure/undefined, switch hint,
    /// data shape, patch) is re-flowing analysis off the main actor. The override applies
    /// instantly and undoably; the derived listing/CFG/xrefs catch up a beat later, so the UI
    /// shows a small "Re-analyzing…" indicator over the pre-re-flow state instead of freezing.
    @Published private(set) var isReanalyzing = false
    /// The typed reason the most recent structural reanalysis was refused (MS-16), else nil.
    @Published private(set) var lastReanalysisRefusal: ReanalysisRefusal?
    /// HS-1: what the last package open repaired in the persisted analysis (empty when consistent).
    @Published private(set) var lastAnalysisRepairs: [WorkspaceAnalysisRepair] = []

    /// Whole-workspace identity guard. Restore/import increments it before cancelling every slot,
    /// so a provider that ignores cancellation still cannot splice a result into a replacement
    /// workspace that happens to reuse both the numeric slot and durable binary UUID.
    private var reanalysisWorkspaceEpoch: UInt64 = 0
    /// Independent last-writer-wins generation for each image slot. A structural edit supersedes
    /// only the prior request for its own slot; requests for sibling images remain live.
    private var reanalysisEpochsBySlot: [ImageSlot: UInt64] = [:]
    /// Advances only when a structural reanalysis result actually lands for a slot. Restore-time
    /// loader work captures this value so a result built from an older structural bucket cannot
    /// replace a newer completed reanalysis merely because the two tasks finished out of order.
    private var reanalysisLandingEpochsBySlot: [ImageSlot: UInt64] = [:]
    /// All retained interactive reanalysis tasks, keyed by the exact slot they own. Nonisolated
    /// `deinit` only reads the Sendable tasks to cancel them; every dictionary mutation remains on
    /// the main actor, matching the existing import/rehydration task safety justification.
    private nonisolated(unsafe) var reanalysisTasksBySlot: [ImageSlot: Task<Void, Never>] = [:]

    /// Navigator-engine contract state per image slot. Written only through
    /// `WorkspaceStore+NavigatorState.swift`; persisted in the manifest's `navigatorState`.
    @Published var navigatorStates: [ImageSlot: NavigatorContractStore] = [:]
    /// The generation each slot's analysis last landed under (image identity, input key, knowledge version).
    var navigatorGenerations: [ImageSlot: NavigatorGeneration] = [:]
    /// The retained producer run of each slot (Swift metadata, then the function-start proofs); a
    /// newer landing cancels and replaces it.
    var navigatorProducerRunsBySlot: [ImageSlot: NavigatorProducerRun] = [:]
    /// The proof certificates of each slot's latest proof landing, keyed by certificate hash
    /// (`sha256:<hex>`). Not persisted: rebuilt when the producer re-runs after a landing or a reopen.
    var navigatorCertificatesBySlot: [ImageSlot: [String: NavigatorProofCertificate]] = [:]

    /// Monotonic guard for the restore-time derived-product pass. Cancellation asks in-flight
    /// loader work to stop; the epoch independently prevents a provider that returns after
    /// cancellation from splicing stale data into a newer workspace.
    private var rehydrationEpoch: UInt64 = 0
    var nativeDecompilerRehydrationEpoch: UInt64 { rehydrationEpoch }
    /// The retained restore-time pass. It is detached because `rehydrate` is synchronous and the
    /// store is main-actor isolated; only the guarded snapshot splice hops back to the main actor.
    private nonisolated(unsafe) var rehydrationTask: Task<Void, Never>?
    /// A mutation that cancels a restore-time pass schedules one replacement after the enclosing
    /// synchronous mutation has published its final snapshot. Keeping this task separate lets
    /// tests await an already-scheduled restart without accidentally starting a missing pass.
    private nonisolated(unsafe) var rehydrationRestartTask: Task<Void, Never>?
    /// Last-writer-wins identity for delayed restarts. Cancellation alone is insufficient because
    /// an already-enqueued main-actor task may resume after a newer lifecycle operation.
    private var rehydrationRestartGeneration: UInt64 = 0

    /// Everything the detached pass needs for one image, captured while the installed snapshot is
    /// stable on the main actor. `binaryID` protects against a later image reusing the same slot.
    private struct RehydrationCandidate: Sendable {
        let slot: ImageSlot
        let binaryID: UUID
        let imageBytes: Data
        let persistedAnalysis: ImageAnalysis
        let coffSectionLayoutVersion: Int?
        let overrides: [UInt64: AddressOverride]
        let artifactIntegrityDiagnostic: AnalysisDiagnostic?
        /// Structural-analysis version of `persistedAnalysis` at capture time. A different value
        /// at splice time proves that a newer full reanalysis already supplied authoritative
        /// loader and structural products, so this loader-only result must be discarded.
        let reanalysisLandingEpoch: UInt64
    }

    private static func artifactIntegrityDiagnostic(for binary: BinaryImage) -> AnalysisDiagnostic? {
        guard case let .contradictoryEvidence(message) = binary.artifactIntegrityState else {
            return nil
        }
        return AnalysisDiagnostic(
            severity: .error,
            address: 0,
            kind: .loaderTruncation,
            message: message
        )
    }

    private func restampAnalysisInputFingerprint(
        _ analysis: inout ImageAnalysis,
        for slot: ImageSlot
    ) {
        guard let binary = snapshot.binary(in: slot) else {
            analysis.analysisInputFingerprint = nil
            return
        }
        Self.restampAnalysisInputFingerprint(&analysis, using: binary)
    }

    private static func restampAnalysisInputFingerprint(
        _ analysis: inout ImageAnalysis,
        using binary: BinaryImage
    ) {
        analysis.analysisInputFingerprint = try? AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
    }

    /// A session coordinate that cannot be proven mapped until the persisted image's omitted
    /// section table has been reconstructed. It never becomes visible from the persisted value
    /// alone: the exact binary owner must survive and the rehydrated map must accept the address.
    private struct PendingRehydratedSelection: Equatable {
        let slot: ImageSlot
        let binaryID: UUID
        let address: UInt64
    }
    private var pendingRehydratedSelection: PendingRehydratedSelection?
    var nativeDecompilerPendingSelection: (
        slot: ImageSlot,
        binaryID: UUID,
        address: UInt64
    )? {
        pendingRehydratedSelection.map { ($0.slot, $0.binaryID, $0.address) }
    }
    /// When set, a structural edit re-flows analysis SYNCHRONOUSLY inline instead of off-main.
    /// The interactive UI leaves this false (non-blocking re-flow behind the indicator); the
    /// scripting/headless surface (CLI/MCP/AppleScript) flips it on for the span of one mutating
    /// command via `withSynchronousReanalysis`, so a scripted mutate-then-query is deterministic
    /// (the next query sees the re-flowed result) — those callers are synchronous and have no UI
    /// to keep responsive. Scoped, not persistent, so a script run against the LIVE document store
    /// doesn't make the human's subsequent edits synchronous too.
    private var reanalysisRunsSynchronously = false

    /// Runs `body` with structural re-analysis forced synchronous, restoring the prior mode after.
    /// The scripting layer wraps each mutating command in this so the edit's re-flow lands before
    /// the command returns. `rethrows`, so a throwing handler still propagates.
    func withSynchronousReanalysis<T>(_ body: () throws -> T) rethrows -> T {
        let previous = reanalysisRunsSynchronously
        reanalysisRunsSynchronously = true
        defer { reanalysisRunsSynchronously = previous }
        return try body()
    }
    /// Inspects a candidate file for fat/universal slices to drive the open-time dialog.
    private let loaderOptionsInspector: LoaderOptionsInspector

    init(
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        engine: any AnalysisProviding,
        autosaveScheduler: AutosaveScheduling? = DebouncedAutosaveScheduler(),
        documentID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability = .available,
        launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability = .available,
        phase2ShellSessionClient: Phase2HumanPTYShellSessionClient = Phase2HumanPTYShellSessionClient(
            transport: NSXPCShellBrokerTransport()
        ),
        phase2ShellBrokerEndpoint: Phase2ShellBrokerEndpoint = Phase2ShellBrokerLaunchAgentRegistration.endpoint,
        phase2DurableShellCapabilityStore: Phase2DurableShellBrokerCapabilityStore = .init(),
        phase2ShellTerminalSurfaceID: UUID = UUID(),
        loaderOptionsInspector: LoaderOptionsInspector = LoaderOptionsInspector(),
        dyldCacheDifferentialWorkflow: DyldCacheDifferentialWorkflowCoordinator? = nil,
        dyldCacheNativeFactsBuilder: any DyldCacheNativeCatalogFactBuilding =
            DyldCacheNativeCatalogFactBuilder()
    ) {
        var projectedSnapshot = snapshot
        var effectiveLogicalBreakpointCatalogAvailability = logicalBreakpointCatalogAvailability
        do {
            try Self.importLegacyBreakpointBitsIfNeeded(
                in: &projectedSnapshot,
                availability: effectiveLogicalBreakpointCatalogAvailability
            )
        } catch {
            effectiveLogicalBreakpointCatalogAvailability = .unavailable
        }
        Self.reprojectLogicalBreakpointCompatibility(
            in: &projectedSnapshot,
            availability: effectiveLogicalBreakpointCatalogAvailability
        )
        self.workspaceName = workspaceName
        self.snapshot = projectedSnapshot
        let initialDebuggerCatalogLedger = DebuggerWorkspaceArtifactCatalogLedger(
            snapshot: projectedSnapshot
        )
        self.debuggerWorkspaceArtifactCatalogLedger = initialDebuggerCatalogLedger
        self.debuggerWorkspaceArtifactCatalog = initialDebuggerCatalogLedger.catalog
        let initialResolutionCatalogLedger = DebuggerBreakpointResolutionCatalogLedger(
            snapshot: projectedSnapshot,
            workspaceID: workspaceID,
            artifactCatalog: initialDebuggerCatalogLedger.catalog
        )
        self.debuggerBreakpointResolutionCatalogLedger = initialResolutionCatalogLedger
        self.debuggerBreakpointResolutionCatalog = initialResolutionCatalogLedger.catalog
        self.engine = engine
        self.dyldCacheDifferentialWorkflow = dyldCacheDifferentialWorkflow
        self.dyldCacheNativeFactsBuilder = dyldCacheNativeFactsBuilder
        self.autosaveScheduler = autosaveScheduler
        self.documentID = documentID
        self.workspaceID = workspaceID
        self.phase2ShellSessionClient = phase2ShellSessionClient
        self.phase2ShellBrokerEndpoint = phase2ShellBrokerEndpoint
        self.phase2DurableShellCapabilityStore = phase2DurableShellCapabilityStore
        self.phase2ShellTerminalSurfaceID = phase2ShellTerminalSurfaceID
        self.loaderOptionsInspector = loaderOptionsInspector
        self.logicalBreakpointCatalogAvailability = effectiveLogicalBreakpointCatalogAvailability
        self.launchProfileCatalogAvailability = launchProfileCatalogAvailability
        self.phase2ReadLedger.installInitial(snapshot: projectedSnapshot)
        self.focusedImageSlotStorage = projectedSnapshot.primarySlot
        self.lastKnownDebuggerBreakpointSets = Self.debuggerBreakpointSets(
            in: projectedSnapshot,
            availability: effectiveLogicalBreakpointCatalogAvailability
        )
        self.lastKnownDebuggerBinaryIDs = Self.debuggerBinaryIDs(in: projectedSnapshot)
        self.selectedSidebarItemID = projectedSnapshot.binaries.first.map { "binary:\($0.id.uuidString)" }
        self.selectedAddress = projectedSnapshot.instructions.first?.address
        syncGraphElementToSelectedAddress()
        resetNavigationHistory(seed: selectedAddress)

        observeCommand(.macScopeShowGoTo) { store in
            store.searchSheetPresentation = .goToAddress
            store.showGoTo = true
        }
        observeCommand(.macScopeShowCommandPalette) { store in
            store.searchSheetPresentation = .commandPalette
            store.showGoTo = true
        }
        observeCommand(.macScopeFind) { store in
            store.showFind = true
        }
        observeCommand(.macScopeShowBrowsers, extracting: { $0.object as? BrowserPane }) { store, pane in
            if let pane { store.browserSelection = pane }
            store.showBrowsers = true
        }
        observeCommand(.macScopeToggleNavigationHistory) { store in
            store.showNavigationHistory.toggle()
        }
        observeCommand(.macScopeToggleProblems) { store in
            store.showProblems.toggle()
        }
        observeCommand(.macScopeToggleMachOMetadata) { store in
            store.showMachOMetadata.toggle()
        }
        observeCommand(.macScopeResetGraphLayout) { store in
            store.resetGraphLayoutSelection()
        }
        observeCommand(.macScopeNavigateBack) { store in
            store.navigateBack()
        }
        observeCommand(.macScopeNavigateForward) { store in
            store.navigateForward()
        }
        observeCommand(.macScopeToggleBreakpoint) { store in
            store.toggleBreakpointAtSelection()
        }
        observeCommand(.macScopeSetEditorMode, extracting: { $0.object as? EditorMode }) { store, mode in
            if let mode {
                store.editorMode = mode
            }
        }

        self.autosaveScheduler?.onFire = { [weak self] in
            self?.performAutosaveIfNeeded()
        }
    }

    // MARK: - Command targeting (WS-2 per-document sessions)

    /// The `userInfo` key under which a menu command carries its target document store.
    nonisolated static let commandTargetStoreKey = "macScopeTargetStore"

    /// True when a menu-command notification is addressed to THIS store (the focused document).
    /// Menu commands stamp the focused window's store into `userInfo[commandTargetStoreKey]`; a
    /// command whose target is a different store — or absent (no focused document) — is ignored,
    /// so with multiple document windows a command reaches only the front one. `object`/other
    /// `userInfo` are untouched, so existing per-command payloads keep working. Single-window:
    /// the focused store is always self, so this is byte-identical to the old broadcast.
    /// `nonisolated` so the notification callbacks (plain closures that hop to `@MainActor`) can
    /// call it synchronously; it only reads `userInfo` and compares reference identity.
    nonisolated func commandTargetsSelf(_ note: Notification) -> Bool {
        (note.userInfo?[WorkspaceStore.commandTargetStoreKey] as? WorkspaceStore) === self
    }

    /// The tokens for this store's command observers, released in `deinit` so a closed document
    /// window's observer blocks do not leak on `NotificationCenter.default` (WS-2: one store per
    /// window, so an un-removed observer would accumulate per window). `nonisolated(unsafe)`
    /// because `removeObserver` (thread-safe) is called from the nonisolated deinit.
    private nonisolated(unsafe) var commandObserverTokens: [NSObjectProtocol] = []

    /// Registers a command observer that runs `body` only when the notification targets THIS store,
    /// capturing the token for `deinit` cleanup. `body` takes the store as a parameter (never
    /// captures `self`), so there is no store → NotificationCenter → store retain cycle — that
    /// cycle would keep the store alive forever and its `deinit` (the cleanup) would never fire.
    private func observeCommand(_ name: Notification.Name,
                                _ body: @escaping @MainActor (WorkspaceStore) -> Void) {
        observeCommand(name, extracting: { _ in Optional<Never>.none }) { store, _ in body(store) }
    }

    /// Payload variant: extracts a SENDABLE value from the notification in the observer block
    /// (nonisolated, on the main queue) and hands it to `body`. `Notification` is not Sendable, so
    /// it must never cross into the `@MainActor` hop — only the extracted Sendable payload does.
    private func observeCommand<Payload: Sendable>(
        _ name: Notification.Name,
        extracting: @escaping @Sendable (Notification) -> Payload?,
        _ body: @escaping @MainActor (WorkspaceStore, Payload?) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            guard self?.commandTargetsSelf(note) == true else { return }
            let payload = extracting(note)
            Task { @MainActor [weak self] in
                guard let self else { return }
                body(self, payload)
            }
        }
        commandObserverTokens.append(token)
    }

    deinit {
        commandObserverTokens.forEach(NotificationCenter.default.removeObserver)
        // A closed window's in-flight analysis must STOP, not run to completion just to have its
        // result discarded by the task's `[weak self]` guard. Cancelling here flips
        // `Task.isCancelled`, which `openBinary` folds into the engine's cooperative token, so the
        // synchronous pipeline unwinds at its next pass boundary. Covers the initial import and
        // every independently retained structural re-analysis in flight when the window closes.
        importTask?.cancel()
        loaderOptionsInspectionTask?.cancel()
        dyldCacheDifferentialTask?.cancel()
        dyldCacheDifferentialCancellation?.cancel()
        reanalysisTasksBySlot.values.forEach { $0.cancel() }
        rehydrationTask?.cancel()
        rehydrationRestartTask?.cancel()
    }

    // MARK: - Document dirty-state + autosave

    var mutationGeneration: WorkspaceDocumentMutationGeneration {
        WorkspaceDocumentMutationGeneration(rawValue: documentMutationEventCounter)
    }

    var hasUnsavedChanges: Bool { isDirty }

    private var documentSessionWriterRetired = false
    private var hasOwnedDocumentSessionWriter = false

    func retireDocumentSessionWriter() {
        if let id = binaryOpenState?.id { cancelBinaryOpen(id) }
        documentSessionWriterRetired = true
        autosaveScheduler?.cancelPendingAutosave()
        autosaveScheduler?.onFire = nil
    }

    func bindDocumentSessionMutationObserver(
        _ observer: (any WorkspaceDocumentMutationObserving)?
    ) {
        documentSessionMutationObserver = observer
        if observer != nil {
            hasOwnedDocumentSessionWriter = true
        }
        observer?.noteMutation(mutationGeneration)
    }

    /// The durable shell ledger is part of the workspace document and must cross the same
    /// external-version, location-reservation, serialization, and publication boundary as an
    /// ordinary Save. A headless direct-package fallback would create a second writer authority.
    func savePhase2DurableLedgerThroughBoundDocumentSession(
        at packageURL: URL
    ) async -> WorkspaceDocumentWriteOutcome {
        guard let session = documentSessionMutationObserver as? WorkspaceDocumentSession,
              let sessionLocation = session.snapshot.location,
              let expectedLocation = try? WorkspaceDocumentLocation.canonicalized(from: packageURL),
              sessionLocation.canonicalURL == expectedLocation.canonicalURL,
              documentURL.map({ $0.standardizedFileURL.path }) == expectedLocation.canonicalURL.path
        else {
            return .failed("document-session-location-mismatch")
        }
        if let phase2DurableLedgerSaverForTesting {
            return await phase2DurableLedgerSaverForTesting(session)
        }
        return await session.save()
    }

    private func advanceDocumentMutationGeneration() {
        guard !documentMutationGenerationExhausted else { return }
        guard documentMutationEventCounter < UInt64.max else {
            documentMutationGenerationExhausted = true
            activeDocumentWriteCapture = nil
            saveError = "Couldn’t save the workspace: document mutation generation exhausted."
            return
        }
        documentMutationEventCounter += 1
        documentSessionMutationObserver?.noteMutation(mutationGeneration)
    }

    /// Records a persisted mutation: bumps the pure tracker, refreshes the
    /// published `isDirty`, and arms the autosave debounce. Returns the *prior*
    /// dirty-token so an undoable edit can register a matching restore. The generation makes the
    /// token comparable only while no independent retained mutation or selectively retired
    /// slot history has invalidated that content correspondence. Only Undo-registering helpers
    /// opt into preserving comparability.
    @discardableResult
    func markDocumentMutated(preservingUndoComparability: Bool = false) -> DirtyUndoToken {
        if !preservingUndoComparability { dirtyUndoTokenGeneration &+= 1 }
        // A late whole-bucket rehydration splice must never overwrite analysis changed by a user
        // edit. Invalidate it before recording the edit, then reconstruct omitted derived products
        // from the post-mutation snapshot when a restore-time pass was actually in flight.
        let shouldRestartRehydration = rehydrationTask != nil || rehydrationRestartTask != nil
        supersedeRehydration()
        pendingRehydratedSelection = nil
        let priorToken = DirtyUndoToken(
            trackerToken: dirtyTracker.recordMutation(),
            generation: dirtyUndoTokenGeneration
        )
        isDirty = dirtyTracker.isDirty
        advanceDocumentMutationGeneration()
        autosaveScheduler?.scheduleAutosave()
        if shouldRestartRehydration {
            scheduleRehydrationRestart()
        }
        return priorToken
    }

    func publishCommittedReconstructionCorpus(
        _ committed: ReconstructionCommittedCorpus
    ) {
        let advancesState = shouldAdvanceReconstructionState(
            commitSequence: committed.commitSequence
        )
        if advancesState {
            reconstructionState = committed.state
            reconstructionLifecycle = committed.lifecycle
        }
        mergeReconstructionAttachmentSources(
            committed.attachmentSources,
            for: reconstructionState,
            replacingExisting: advancesState
        )
        if advancesState {
            markDocumentMutated()
        }
    }

    func publishCommittedReconstructionCheckpoint(
        _ committed: ReconstructionCommittedCheckpoint,
        attachmentSources: [ReconstructionAttachmentSource]
    ) {
        let advancesState = shouldAdvanceReconstructionState(
            commitSequence: committed.commitSequence
        )
        if advancesState {
            reconstructionState = committed.state
            reconstructionLifecycle = committed.lifecycle
        }
        mergeReconstructionAttachmentSources(
            attachmentSources,
            for: reconstructionState,
            replacingExisting: advancesState
        )
        if advancesState {
            markDocumentMutated()
        }
    }

    private func shouldAdvanceReconstructionState(commitSequence: UInt64) -> Bool {
        if commitSequence == 0 {
            return highestPublishedReconstructionCommitSequence == nil
        }
        guard highestPublishedReconstructionCommitSequence.map({ commitSequence > $0 })
                ?? true else {
            return false
        }
        highestPublishedReconstructionCommitSequence = commitSequence
        return true
    }

    private func mergeReconstructionAttachmentSources(
        _ candidates: [ReconstructionAttachmentSource],
        for winningState: ReconstructionWorkspaceState,
        replacingExisting: Bool
    ) {
        var requiredContentsByDigest: [String: ReconstructionContentIdentity] = [:]
        for occurrence in winningState.corpusManifests.flatMap(\.artifacts) {
            requiredContentsByDigest[occurrence.contentIdentity.digest] = occurrence.contentIdentity
        }
        var sourcesByDigest: [String: ReconstructionAttachmentSource] = [:]
        for source in reconstructionAttachmentSources
            where requiredContentsByDigest[source.contentIdentity.digest]
                == source.contentIdentity {
            sourcesByDigest[source.contentIdentity.digest] = source
        }
        for source in candidates
            where requiredContentsByDigest[source.contentIdentity.digest]
                == source.contentIdentity {
            if replacingExisting || sourcesByDigest[source.contentIdentity.digest] == nil {
                sourcesByDigest[source.contentIdentity.digest] = source
            }
        }
        reconstructionAttachmentSources = sourcesByDigest.values.sorted {
            $0.contentIdentity.digest < $1.contentIdentity.digest
        }
    }

    /// Restores a comparable dirty-token captured before an edit (an undo/redo step) and re-arms
    /// autosave. A token from before selective slot-history retirement is deliberately ignored:
    /// its scalar revision predates persisted state that no remaining action can unwind.
    func restoreDocumentDirtyToken(_ token: DirtyUndoToken) {
        guard token.generation == dirtyUndoTokenGeneration else { return }
        dirtyTracker.restore(token: token.trackerToken)
        isDirty = dirtyTracker.isDirty
        advanceDocumentMutationGeneration()
        autosaveScheduler?.scheduleAutosave()
    }

    @discardableResult
    func recordPhase2AssistantTerminalState(
        _ finalState: Phase2AssistantSheetState,
        intent: Phase2AssistantIntent,
        userGoal: String,
        conversationID: UUID? = nil,
        turnSequence: Int = 1,
        inferenceTurnID: UUID? = nil,
        isLegacy: Bool = false,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        publicationToken: Phase2AssistantPublicationToken? = nil
    ) -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord? {
        guard finalState.isHistoryRecordable,
              turnSequence > 0,
              publicationToken?.isCurrent(in: self) ?? true else { return nil }
        let existingIndex = phase2AssistantSessionHistory.firstIndex { $0.id == id }
        let existing = existingIndex.map { phase2AssistantSessionHistory[$0] }
        let sequence = existing?.sequence
            ?? ((phase2AssistantSessionHistory.map(\.sequence).max() ?? 0) + 1)
        let effectiveGoal = intent.defaultGoal(userGoal: userGoal)
        let entry = Phase2AssistantHistoryEntry(
            id: id,
            sequence: sequence,
            intent: intent,
            userGoal: effectiveGoal,
            state: finalState,
            createdAt: createdAt
        )
        let record = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
            id: id,
            workspaceID: persistedWorkspaceID ?? -1,
            workspaceUUID: workspaceID,
            documentID: documentID,
            sequence: sequence,
            conversationID: conversationID ?? id,
            turnSequence: turnSequence,
            inferenceTurnID: inferenceTurnID ?? id,
            isLegacy: isLegacy,
            intentID: intent.rawValue,
            userGoal: effectiveGoal,
            status: Self.phase2AssistantPersistenceStatus(for: finalState),
            promptText: effectiveGoal,
            answerText: Self.phase2AssistantAnswerText(for: finalState),
            transcriptText: entry.plainTextExport,
            contextDigest: Self.phase2AssistantContextDigest(for: finalState),
            canonicalByteCount: Self.phase2AssistantCanonicalByteCount(for: finalState),
            providerToolCount: Self.phase2AssistantProviderToolCount(for: finalState),
            createdAt: createdAt,
            completedAt: createdAt,
            continuationCheckpoint: existing?.continuationCheckpoint
        )
        if let existingIndex {
            phase2AssistantSessionHistory[existingIndex] = record
        } else {
            phase2AssistantSessionHistory.insert(record, at: 0)
        }
        markDocumentMutated()
        return record
    }

    func makePhase2AssistantContinuationDatabaseOwner(
        baseDirectoryURL: URL? = nil
    ) throws -> Phase2AssistantContinuationDatabaseOwner {
        let owner = try Phase2AssistantContinuationDatabaseOwner(
            workspaceUUID: workspaceID,
            documentID: documentID,
            baseDirectoryURL: baseDirectoryURL
        )
        let priorWorkspaceID = persistedWorkspaceID
        let priorDocumentMetadata = documentMetadata
        defer {
            persistedWorkspaceID = priorWorkspaceID
            documentMetadata = priorDocumentMetadata
        }
        if let existing = try owner.database.workspaceRecord(workspaceUUID: workspaceID),
           let rowID = existing.id {
            try owner.bindWorkspaceRowID(rowID, workspaceUUID: workspaceID, documentID: documentID)
            return owner
        }
        let persisted = try saveWorkspace(to: try owner.database, documentID: documentID)
        guard let rowID = persisted.workspace.id else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }
        try owner.bindWorkspaceRowID(rowID, workspaceUUID: workspaceID, documentID: documentID)
        return owner
    }

    @discardableResult
    func seedPhase2AssistantShellContinuation(
        machine: Phase2AssistantShellContinuationMachine,
        proposal: Phase2AIShellCommandProposal,
        intent: Phase2AssistantIntent,
        userGoal: String,
        initialTerminalEventDigest: String,
        in owner: Phase2AssistantContinuationDatabaseOwner,
        createdAt: Date = Date()
    ) throws -> UUID {
        guard owner.workspaceUUID == workspaceID,
              owner.documentID == documentID,
              machine.state == .awaitingShellReview,
              machine.turnIdentity.workspaceID == workspaceID,
              let staged = machine.proposal,
              staged.proposalID == proposal.proposalID,
              staged.proposalDigest == Phase2AssistantShellProposalCanonicalizer.digest(proposal),
              Self.isLowercaseSHA256(initialTerminalEventDigest),
              let persistedID = owner.workspaceRowID else {
            throw Phase2AssistantContinuationDatabaseOwner.OwnerError.identityMismatch
        }
        let recordID = machine.turnIdentity.inferenceTurnID
        if let existing = try owner.assistantRecord(id: recordID) {
            guard existing.workspaceUUID == workspaceID,
                  existing.documentID == documentID,
                  existing.continuationCheckpoint?.logicalState
                    == Phase2AssistantShellContinuationState.awaitingShellReview.rawValue else {
                throw Phase2AssistantContinuationDatabaseOwner.OwnerError.identityMismatch
            }
            return existing.id
        }
        let sequence = (phase2AssistantSessionHistory.map(\.sequence).max() ?? 0) + 1
        let effectiveGoal = intent.defaultGoal(userGoal: userGoal)
        let checkpoint = Phase2AssistantContinuationCheckpointRecord(
            logicalState: machine.state.rawValue,
            initialRequestID: machine.turnIdentity.originatingFinalizationRequestID,
            initialTerminalEventDigest: initialTerminalEventDigest,
            shellProposalID: proposal.proposalID,
            shellProposalJSON: try Self.phase2AssistantShellProposalJSON(proposal),
            shellProposalSHA256: staged.proposalDigest,
            humanDecision: nil,
            approvalConsumedAt: nil,
            approvalState: nil,
            shellExecutionID: nil,
            completedExecutionReference: nil,
            shellExecutionSHA256: nil,
            runtimeAuthorityRecordID: nil,
            runtimeAuthoritySHA256: nil,
            continuationCoordinate: nil,
            continuationOrdinal: nil,
            continuationRequestID: nil,
            continuationDispatchState: nil,
            continuationTerminalEventDigest: nil,
            finalProvenanceJSON: nil
        )
        let record = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
            id: recordID,
            workspaceID: persistedID,
            workspaceUUID: workspaceID,
            documentID: documentID,
            sequence: sequence,
            conversationID: machine.turnIdentity.conversationID,
            turnSequence: Int(machine.turnIdentity.turnSequence),
            inferenceTurnID: machine.turnIdentity.inferenceTurnID,
            intentID: intent.rawValue,
            userGoal: effectiveGoal,
            status: .outcomeUnknown,
            promptText: effectiveGoal,
            answerText: nil,
            transcriptText: "MacScope Assistant same-turn shell continuation pending",
            contextDigest: machine.turnIdentity.workspaceDocumentIdentityDigest,
            canonicalByteCount: nil,
            providerToolCount: 0,
            createdAt: createdAt,
            completedAt: nil,
            continuationCheckpoint: checkpoint
        )
        try owner.database.upsertPhase2AssistantSessionRecord(record)
        phase2AssistantSessionHistory.removeAll { $0.id == record.id }
        phase2AssistantSessionHistory.insert(record, at: 0)
        markDocumentMutated()
        return record.id
    }

    @discardableResult
    func projectPhase2AssistantShellContinuation(
        recordID: UUID,
        from owner: Phase2AssistantContinuationDatabaseOwner
    ) throws -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord {
        guard owner.workspaceUUID == workspaceID,
              owner.documentID == documentID,
              let record = try owner.assistantRecord(id: recordID),
              record.workspaceUUID == workspaceID,
              record.documentID == documentID else {
            throw Phase2AssistantContinuationDatabaseOwner.OwnerError.identityMismatch
        }
        phase2AssistantSessionHistory.removeAll { $0.id == recordID }
        phase2AssistantSessionHistory.insert(record, at: 0)
        markDocumentMutated()
        return record
    }

    @discardableResult
    func recoverPhase2AssistantShellContinuations(
        from owner: Phase2AssistantContinuationDatabaseOwner,
        now: Date = Date()
    ) throws -> [Phase2AssistantContinuationDatabaseOwner.RecoveryProjection] {
        guard owner.workspaceUUID == workspaceID, owner.documentID == documentID else {
            throw Phase2AssistantContinuationDatabaseOwner.OwnerError.identityMismatch
        }
        let projections = try owner.recoverNonterminalCheckpoints(now: now)
        for projection in projections {
            phase2AssistantSessionHistory.removeAll { $0.id == projection.record.id }
            phase2AssistantSessionHistory.insert(projection.record, at: 0)
        }
        if !projections.isEmpty { markDocumentMutated() }
        return projections
    }

    private static func phase2AssistantShellProposalJSON(
        _ proposal: Phase2AIShellCommandProposal
    ) throws -> String {
        let object: [String: Any] = [
            "proposal_id": proposal.proposalID.uuidString.lowercased(),
            "executable_path": proposal.executablePath,
            "arguments": proposal.arguments,
            "environment": proposal.environment,
            "working_directory_path": proposal.workingDirectoryPath.map { $0 as Any } ?? NSNull(),
            "timeout_milliseconds": proposal.timeoutMilliseconds,
            "maximum_output_bytes": proposal.maximumOutputBytes,
            "execution_surface": proposal.executionSurface.rawValue,
            "requested_effects": proposal.requestedEffects.map(\.rawValue).sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    @discardableResult
    func recordPhase2AssistantTerminalState(
        _ finalState: Phase2AssistantSheetState,
        intent: Phase2AssistantIntent,
        userGoal: String,
        turnContext: Phase2AssistantConversationTurnContext,
        publicationToken: Phase2AssistantPublicationToken,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord? {
        recordPhase2AssistantTerminalState(
            finalState,
            intent: intent,
            userGoal: userGoal,
            conversationID: turnContext.conversationID,
            turnSequence: Int(turnContext.turnSequence),
            inferenceTurnID: turnContext.inferenceTurnID,
            id: id,
            createdAt: createdAt,
            publicationToken: publicationToken
        )
    }

    /// Admits exactly one provider request per conversation. Different conversations may run in
    /// parallel, while a second turn in the same conversation is rejected before any read or XPC
    /// dispatch occurs.
    @discardableResult
    func beginPhase2AssistantTurn(conversationID: UUID) -> Bool {
        phase2AssistantInFlightConversationIDs.insert(conversationID).inserted
    }

    func endPhase2AssistantTurn(conversationID: UUID) {
        phase2AssistantInFlightConversationIDs.remove(conversationID)
    }

    func phase2AssistantCompletedPriorTurns(
        conversationID: UUID
    ) -> [Phase2AssistantProviderVisiblePriorTurn] {
        phase2AssistantSessionHistory
            .filter {
                $0.conversationID == conversationID
                    && !$0.isLegacy
                    && $0.status == .completed
                    && $0.turnSequence > 0
            }
            .sorted { lhs, rhs in lhs.turnSequence < rhs.turnSequence }
            .compactMap { record in
                guard let answer = record.answerText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !answer.isEmpty else { return nil }
                let user = record.userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !user.isEmpty else { return nil }
                return Phase2AssistantProviderVisiblePriorTurn(
                    inferenceTurnID: record.inferenceTurnID,
                    turnSequence: record.turnSequence,
                    userMessage: user,
                    assistantMessage: answer
                )
            }
    }

    func preparePhase2AssistantConversationTurn(
        conversationID: UUID = UUID(),
        sessionID: UUID? = nil,
        inferenceTurnID: UUID = UUID()
    ) -> Phase2AssistantConversationTurnContext {
        let priorTurns = phase2AssistantCompletedPriorTurns(conversationID: conversationID)
        let nextSequence = UInt64(
            (phase2AssistantSessionHistory
                .filter { $0.conversationID == conversationID && !$0.isLegacy }
                .map(\.turnSequence)
                .max() ?? 0) + 1
        )
        return Phase2AssistantConversationTurnContext(
            conversationID: conversationID,
            sessionID: sessionID ?? conversationID,
            inferenceTurnID: inferenceTurnID,
            turnSequence: nextSequence,
            priorTurns: priorTurns
        )
    }

    func clearPhase2AssistantSessionHistory() {
        guard !phase2AssistantSessionHistory.isEmpty else { return }
        phase2AssistantSessionHistory.removeAll()
        markDocumentMutated()
    }

    func deletePhase2AssistantSessionHistoryEntry(id: UUID) {
        let priorCount = phase2AssistantSessionHistory.count
        phase2AssistantSessionHistory.removeAll { $0.id == id }
        guard phase2AssistantSessionHistory.count != priorCount else { return }
        markDocumentMutated()
    }

    func recordPhase2RuntimeAuthorityUse(
        sessionID: UUID,
        surfaces: Set<Phase2RuntimeAuthoritySurface>,
        terminalBackend: Phase2TerminalEmulationBackend = .ghosttyLib,
        ptyReusePolicy: Phase2TerminalPTYReusePolicy = .disabled,
        debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy = .disabled,
        providerVisibleShellExecutionEnabled: Bool,
        createdAt: Date = Date()
    ) {
        let record = WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
            workspaceID: persistedWorkspaceID ?? -1,
            workspaceUUID: workspaceID,
            documentID: documentID,
            sessionID: sessionID,
            surfaces: surfaces,
            terminalBackend: terminalBackend,
            ptyReusePolicy: ptyReusePolicy,
            debuggerAuthorityPolicy: debuggerAuthorityPolicy,
            providerVisibleShellExecutionEnabled: providerVisibleShellExecutionEnabled,
            createdAt: createdAt
        )
        phase2RuntimeAuthorityRecords.insert(record, at: 0)
        if phase2RuntimeAuthorityRecords.count > 100 {
            phase2RuntimeAuthorityRecords.removeLast(phase2RuntimeAuthorityRecords.count - 100)
        }
        markDocumentMutated()
    }

    private func phase2AssistantPersistenceRecords(
        workspaceID: Int64,
        documentID: UUID
    ) -> [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord] {
        phase2AssistantSessionHistory
            .sorted { $0.sequence < $1.sequence }
            .map { record in
                WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
                    id: record.id,
                    workspaceID: workspaceID,
                    workspaceUUID: self.workspaceID,
                    documentID: documentID,
                    sequence: record.sequence,
                    conversationID: record.conversationID,
                    turnSequence: record.turnSequence,
                    inferenceTurnID: record.inferenceTurnID,
                    isLegacy: record.isLegacy,
                    intentID: record.intentID,
                    userGoal: record.userGoal,
                    status: record.status,
                    promptText: record.promptText,
                    answerText: record.answerText,
                    transcriptText: record.transcriptText,
                    contextDigest: record.contextDigest,
                    canonicalByteCount: record.canonicalByteCount,
                    providerToolCount: record.providerToolCount,
                    recordSchemaVersion: record.recordSchemaVersion,
                    createdAt: record.createdAt,
                    completedAt: record.completedAt,
                    continuationCheckpoint: record.continuationCheckpoint
                )
            }
    }

    private func phase2RuntimeAuthorityPersistenceRecords(
        workspaceID: Int64,
        documentID: UUID
    ) -> [WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord] {
        phase2RuntimeAuthorityRecords.map { record in
            WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord(
                id: record.id,
                workspaceID: workspaceID,
                workspaceUUID: self.workspaceID,
                documentID: documentID,
                sessionID: record.sessionID,
                surfaces: record.surfaces,
                terminalBackend: record.terminalBackend,
                ptyReusePolicy: record.ptyReusePolicy,
                debuggerAuthorityPolicy: record.debuggerAuthorityPolicy,
                providerVisibleShellExecutionEnabled: record.providerVisibleShellExecutionEnabled,
                recordSchemaVersion: record.recordSchemaVersion,
                createdAt: record.createdAt
            )
        }
    }

    private func phase2ShellSessionPersistenceRecord(
        workspaceID: Int64,
        documentID: UUID,
        updatedAt: Date
    ) -> WorkspaceDatabase.Phase2ShellSessionPersistenceRecord? {
        phase2ShellSession.packagePhase2ShellSession.map { shellSession in
            WorkspaceDatabase.Phase2ShellSessionPersistenceRecord(
                workspaceID: workspaceID,
                workspaceUUID: self.workspaceID,
                documentID: documentID,
                shellSession: shellSession,
                updatedAt: updatedAt
            )
        }
    }

    private func phase2AssistantPersistenceRecords(
        from packageRecords: [WorkspacePackageAssistantSessionRecord]
    ) -> [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord] {
        packageRecords
            .sorted { $0.sequence > $1.sequence }
            .compactMap { record in
                guard let status = WorkspaceDatabase.Phase2AssistantPersistedSessionStatus(rawValue: record.status) else {
                    return nil
                }
                return WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
                    id: record.id,
                    workspaceID: persistedWorkspaceID ?? -1,
                    workspaceUUID: workspaceID,
                    documentID: documentID,
                    sequence: record.sequence,
                    conversationID: record.conversationID,
                    turnSequence: record.turnSequence,
                    inferenceTurnID: record.inferenceTurnID,
                    isLegacy: record.isLegacy,
                    intentID: record.intentID,
                    userGoal: record.userGoal,
                    status: status,
                    promptText: record.promptText,
                    answerText: record.answerText,
                    transcriptText: record.transcriptText,
                    contextDigest: record.contextDigest,
                    canonicalByteCount: record.canonicalByteCount,
                    providerToolCount: record.providerToolCount,
                    recordSchemaVersion: record.recordSchemaVersion,
                    createdAt: record.createdAt,
                    completedAt: record.completedAt,
                    continuationCheckpoint: record.continuationCheckpoint
                )
            }
    }

    private static func phase2AssistantPersistenceStatus(
        for state: Phase2AssistantSheetState
    ) -> WorkspaceDatabase.Phase2AssistantPersistedSessionStatus {
        switch state {
        case .completed:
            return .completed
        case .readinessBlocked:
            return .readinessBlocked
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        case .idle, .running:
            return .outcomeUnknown
        }
    }

    private static func phase2AssistantAnswerText(for state: Phase2AssistantSheetState) -> String? {
        if case .completed(let display) = state {
            return display.answer
        }
        return nil
    }

    private static func phase2AssistantContextDigest(for state: Phase2AssistantSheetState) -> String? {
        if case .completed(let display) = state {
            return display.contextDisclosure?.digest
        }
        return nil
    }

    private static func phase2AssistantCanonicalByteCount(for state: Phase2AssistantSheetState) -> Int? {
        if case .completed(let display) = state {
            return display.contextDisclosure?.canonicalByteCount
        }
        return nil
    }

    private static func phase2AssistantProviderToolCount(for state: Phase2AssistantSheetState) -> Int {
        if case .completed(let display) = state {
            return display.providerToolCount
        }
        return 0
    }

    /// The sole write chokepoint for durable logical-breakpoint authoring. Undo/redo replays the
    /// inverse authored intent rather than restoring an older catalog snapshot, so the stable
    /// logical ID survives while both catalog and restored-spec revisions remain monotonic.
    @discardableResult
    func applyLogicalBreakpointOperation(
        _ operation: WorkspaceLogicalBreakpointOperation,
        actionName: String
    ) throws -> WorkspaceLogicalBreakpointMutation? {
        guard logicalBreakpointCatalogAvailability == .available else {
            throw WorkspaceDatabase.DatabaseError.logicalBreakpointCatalogUnavailable
        }
        guard let mutation = try operation.applying(to: snapshot.logicalBreakpointCatalog) else {
            return nil
        }

        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent && !manager.isUndoing && !manager.isRedoing
        if needsExplicitGroup { manager.beginUndoGrouping() }
        defer {
            manager.setActionName(actionName)
            if needsExplicitGroup { manager.endUndoGrouping() }
        }

        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        manager.registerUndo(withTarget: self) { store in
            do {
                if try store.applyLogicalBreakpointOperation(
                    mutation.inverse,
                    actionName: actionName
                ) != nil {
                    store.restoreDocumentDirtyToken(priorToken)
                }
            } catch {
                // Revision exhaustion or invalid captured authority must never partially restore
                // an older catalog. Keep the authored state byte-identical and surface one issue.
                store.lastIssue = error.localizedDescription
            }
        }
        var next = snapshot
        next.logicalBreakpointCatalog = mutation.catalog
        Self.reprojectLogicalBreakpointCompatibility(
            in: &next,
            availability: logicalBreakpointCatalogAvailability
        )
        snapshot = next
        return mutation
    }

    /// Completes a confirmation-gated repair after any required persistence transaction has
    /// succeeded. Corrupt bytes never entered the snapshot and are intentionally not undoable.
    func installRepairedLogicalBreakpointCatalog(
        _ catalog: DebuggerLogicalBreakpointCatalog
    ) {
        guard logicalBreakpointCatalogAvailability == .unavailable else { return }
        var next = snapshot
        next.logicalBreakpointCatalog = catalog
        logicalBreakpointCatalogAvailability = .available
        Self.reprojectLogicalBreakpointCompatibility(in: &next, availability: .available)
        snapshot = next
        markDocumentMutated()
        lastIssue = catalogPersistenceConflictError?.localizedDescription
    }

    /// Completes the launch-profile equivalent of the catalog-atomic confirmed repair. Keeping
    /// the private availability setter inside the owning type preserves its read-only projection
    /// to feature extensions and UI consumers.
    func installRepairedLaunchProfileCatalog(_ catalog: DebuggerLaunchProfileCatalog) {
        guard launchProfileCatalogAvailability == .unavailable else { return }
        var next = snapshot
        next.launchProfileCatalog = catalog
        launchProfileCatalogAvailability = .available
        snapshot = next
        markDocumentMutated()
        lastIssue = catalogPersistenceConflictError?.localizedDescription
    }

    /// Marks the document clean at the revision captured before a write started.
    /// Edits that landed mid-write keep the document dirty against the new
    /// baseline, so nothing is silently dropped.
    private func markDocumentSaved(at token: Int) {
        dirtyTracker.markSaved(at: token)
        isDirty = dirtyTracker.isDirty
    }

    /// One ordered conflict seam for every ordinary persistence path. Logical-breakpoint
    /// unavailability remains the first reported error for compatibility; launch-profile
    /// unavailability is independently retained and is reported as soon as the logical catalog is
    /// repaired.
    var catalogPersistenceConflictError: WorkspaceDatabase.DatabaseError? {
        if logicalBreakpointCatalogAvailability == .unavailable {
            return .logicalBreakpointCatalogUnavailable
        }
        if launchProfileCatalogAvailability == .unavailable {
            return .launchProfileCatalogUnavailable
        }
        return nil
    }

    /// The pure autosave decision for the current state, exposed for the scheduler
    /// callback and for headless tests. A conflicted document is never autosaved.
    var autosaveDecision: AutosaveDecision {
        AutosavePolicy.decide(
            isDirty: isDirty,
            hasConflict: documentMetadata?.document.conflictDetectedAt != nil
                || catalogPersistenceConflictError != nil
        )
    }

    /// Invoked by the autosave scheduler when its debounce elapses. Consults the
    /// pure policy and only writes when the document is dirty, has a known package
    /// URL, and is conflict-free. The explicit Save path is untouched; this simply
    /// reuses it, so there is no double-persist.
    @discardableResult
    func performAutosaveIfNeeded() -> Task<WorkspaceDocumentWriteOutcome?, Never>? {
        guard !documentSessionWriterRetired else { return nil }
        if let session = documentSessionMutationObserver as? WorkspaceDocumentSession {
            return Task { @MainActor [weak session] in
                await session?.autosaveIfNeeded()
            }
        }

        // Headless compatibility: isolated store tests and command-line paths that deliberately
        // have no document session retain the legacy writer until they adopt the runtime seam.
        guard !hasOwnedDocumentSessionWriter,
              case .save = autosaveDecision, let url = documentURL else { return nil }
        writeDocumentPackage(to: url)
        return nil
    }

    static func bootstrap(
        launchConfiguration: WorkspaceLaunchConfiguration = WorkspaceLaunchConfiguration()
    ) -> WorkspaceStore {
        let snapshot: WorkspaceSnapshot
        if launchConfiguration.usesNativeDecompilerQualificationFixture {
            snapshot = AnalysisEngine.nativeDecompilerQualificationSnapshot()
        } else if launchConfiguration.loadsPreviewFixture {
            snapshot = AnalysisEngine.previewSnapshot()
        } else {
            snapshot = emptySnapshot()
        }
        return makeBootstrapStore(
            snapshot: snapshot,
            launchConfiguration: launchConfiguration
        )
    }

    static func bootstrapForPreviewFixture(
        launchConfiguration: WorkspaceLaunchConfiguration = WorkspaceLaunchConfiguration()
    ) -> WorkspaceStore {
        makeBootstrapStore(
            snapshot: AnalysisEngine.previewSnapshot(),
            launchConfiguration: launchConfiguration
        )
    }

    private static func makeBootstrapStore(
        snapshot: WorkspaceSnapshot,
        launchConfiguration: WorkspaceLaunchConfiguration
    ) -> WorkspaceStore {
        // GUI chokepoint for provider selection: real windows analyze through the out-of-process
        // XPC worker by default (crash isolation), or the in-process engine when forced off. Tests
        // and headless launchers construct stores with an explicit provider and never reach here.
        let store = WorkspaceStore(
            workspaceName: "MacScope Workspace",
            snapshot: snapshot,
            engine: AnalysisProviderFactory.makeDefault(),
            dyldCacheDifferentialWorkflow:
                AnalysisProviderFactory.makeDefaultDyldCacheDifferentialWorkflow()
        )
        store.applyLaunchConfiguration(launchConfiguration)
        return store
    }

    private static func emptySnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [],
            xrefs: [],
            hexBytes: Data()
        )
    }

    static func bootstrapForProcess() -> WorkspaceStore {
        bootstrap(
            launchConfiguration: WorkspaceLaunchConfiguration.parse(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            )
        )
    }

    static func restored(
        workspaceID: Int64,
        from database: WorkspaceDatabase,
        engine: any AnalysisProviding = AnalysisEngine()
    ) throws -> WorkspaceStore? {
        guard let persistedWorkspace = try database.loadWorkspaceState(workspaceID: workspaceID) else {
            return nil
        }

        let store = WorkspaceStore(
            workspaceName: persistedWorkspace.workspace.name,
            snapshot: persistedWorkspace.snapshot,
            engine: engine
        )
        let documentMetadata = try database.workspaceDocumentMetadata(workspaceID: workspaceID)
        let reconstructionSources = try verifiedReconstructionAttachmentSources(
            for: persistedWorkspace.reconstructionState,
            workspaceID: persistedWorkspace.workspace.uuid,
            documentID: documentMetadata?.document.documentID,
            documentMetadata: documentMetadata,
            database: database
        )
        store.restoreWorkspace(
            persistedWorkspace,
            documentMetadata: documentMetadata,
            reconstructionAttachmentSources: reconstructionSources
        )
        store.schedulePhase2DurableShellRecoveryIfNeeded()
        return store
    }

    static func restoredPackage(
        from packageURL: URL,
        fileManager: FileManager = .default,
        engine: any AnalysisProviding = AnalysisEngine(),
        scheduleDurableRecovery: Bool = true
    ) throws -> WorkspaceStore {
        let packageRoot = try canonicalPackageURL(
            packageURL,
            fileManager: fileManager
        )
        let package = try MacScopeDocumentPackage.openPackage(
            from: packageRoot,
            fileManager: fileManager
        )
        let store = WorkspaceStore(
            workspaceName: package.manifest.workspaceName,
            snapshot: package.snapshot,
            engine: engine
        )
        try store.restorePackage(package)
        store.documentURL = packageRoot
        if scheduleDurableRecovery {
            store.schedulePhase2DurableShellRecoveryIfNeeded()
        }
        return store
    }

    @discardableResult
    func saveWorkspace(
        to database: WorkspaceDatabase,
        now: Date = Date(),
        documentID: UUID? = nil
    ) throws -> WorkspaceDatabase.PersistedWorkspace {
        guard !documentSessionWriterRetired else {
            throw WorkspaceDocumentSessionError.closed
        }
        if let catalogPersistenceConflictError { throw catalogPersistenceConflictError }
        let hadPersistedWorkspace = persistedWorkspaceID != nil
        var persisted: WorkspaceDatabase.PersistedWorkspace
        if let persistedWorkspaceID {
            persisted = try database.replaceWorkspaceState(
                workspaceID: persistedWorkspaceID,
                workspaceName: workspaceName,
                snapshot: snapshot,
                selectedSidebarItemID: selectedSidebarItemID,
                selectedAddress: persistableSelectedAddress,
                selectedTool: selectedTool,
                editorMode: editorMode,
                isInspectorPresented: isInspectorPresented,
                sidebarSearchText: sidebarSearchText,
                focusedImageSlot: focusedImageSlotStorage,
                now: now
            )
        } else {
            // No prior identity yet (first save / fresh scratch DB): create a new
            // workspace. Once we have its id, every later save/autosave replaces by id
            // above — display name is never the overwrite key.
            persisted = try database.createWorkspaceState(
                workspaceUUID: workspaceID,
                workspaceName: workspaceName,
                snapshot: snapshot,
                selectedSidebarItemID: selectedSidebarItemID,
                selectedAddress: persistableSelectedAddress,
                selectedTool: selectedTool,
                editorMode: editorMode,
                isInspectorPresented: isInspectorPresented,
                sidebarSearchText: sidebarSearchText,
                focusedImageSlot: focusedImageSlotStorage,
                now: now
            )
        }

        persistedWorkspaceID = persisted.workspace.id
        let shouldReplayReconstruction = !hadPersistedWorkspace
            || reconstructionPersistenceRetryPending
        if shouldReplayReconstruction {
            if persisted.reconstructionState != reconstructionState {
                do {
                    try database.replaceReconstructionState(
                        workspaceID: workspaceID,
                        state: reconstructionState
                    )
                } catch {
                    reconstructionPersistenceRetryPending = true
                    throw error
                }
                persisted.reconstructionState = reconstructionState
            }
            if hadPersistedWorkspace {
                reconstructionPersistenceRetryPending = false
            }
        } else {
            reconstructionState = persisted.reconstructionState
        }
        if let workspaceID = persisted.workspace.id {
            try database.replacePhase2AssistantSessionRecords(
                workspaceID: workspaceID,
                records: phase2AssistantPersistenceRecords(
                    workspaceID: workspaceID,
                    documentID: documentID ?? self.documentID
                )
            )
            try database.replacePhase2RuntimeAuthorityRecords(
                workspaceID: workspaceID,
                records: phase2RuntimeAuthorityPersistenceRecords(
                    workspaceID: workspaceID,
                    documentID: documentID ?? self.documentID
                )
            )
            try database.replacePhase2ShellSessionRecord(
                workspaceID: workspaceID,
                record: phase2ShellSessionPersistenceRecord(
                    workspaceID: workspaceID,
                    documentID: documentID ?? self.documentID,
                    updatedAt: now
                )
            )
        }
        return persisted
    }

    func makePackagePayload() throws -> WorkspaceDocumentPackagePayload {
        guard !documentMutationGenerationExhausted else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-generation-exhausted"
            )
        }
        let capturedGeneration = mutationGeneration
        let capturedDirtyToken = dirtyTracker.token
        let priorPersistedWorkspaceID = persistedWorkspaceID
        let priorDocumentMetadata = documentMetadata
        let inputCopyingDecision = priorDocumentMetadata?.document.inputCopyingDecision
            ?? .copyInputsIntoPackage
        let bookmarkResolutionDecision = priorDocumentMetadata?.document.bookmarkResolutionDecision
            ?? .resolveStoredBookmarks
        defer {
            persistedWorkspaceID = priorPersistedWorkspaceID
            documentMetadata = priorDocumentMetadata
        }

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        persistedWorkspaceID = nil
        documentMetadata = nil
        let persisted = try saveWorkspace(
            to: database,
            documentID: documentID
        )
        guard let scratchWorkspaceID = persisted.workspace.id else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }
        let components = try database.packageComponents(
            workspaceID: scratchWorkspaceID,
            documentID: documentID,
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            phase2ShellSession: phase2ShellSession.packagePhase2ShellSession
        )
        guard components.manifest.documentID == documentID,
              components.manifest.workspaceUUID == workspaceID else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-payload-logical-identity-mismatch"
            )
        }
        let encoded = try encodedInstructionPackagePayload(
            components: components, reconstructionState: reconstructionState
        )
        let capturedReconstructionAttachmentSources = reconstructionAttachmentSources
        activeDocumentWriteCapture = DocumentWriteCapture(
            generation: capturedGeneration,
            dirtyToken: capturedDirtyToken,
            reconstructionContentIdentities: capturedReconstructionAttachmentSources
                .map(\.contentIdentity)
                .sorted { $0.digest < $1.digest }
        )
        return WorkspaceDocumentPackagePayload(
            documentID: documentID,
            workspaceID: workspaceID,
            manifestData: encoded.manifestData,
            attachmentsByBinaryID: components.attachmentsByBinaryID,
            reconstructionState: reconstructionState,
            reconstructionAttachmentSources: capturedReconstructionAttachmentSources,
            instructionSidecarData: encoded.instructionSidecarData,
            capturedMutationGeneration: capturedGeneration
        )
    }

    func acceptPublishedWrite(
        capturedGeneration: WorkspaceDocumentMutationGeneration,
        adopting location: WorkspaceDocumentLocation?
    ) {
        guard !documentMutationGenerationExhausted,
              let capture = activeDocumentWriteCapture,
              capture.generation == capturedGeneration else { return }
        activeDocumentWriteCapture = nil
        markDocumentSaved(at: capture.dirtyToken)
        if !isDirty {
            autosaveScheduler?.cancelPendingAutosave()
        }
        if let packageURL = location?.canonicalURL ?? documentURL,
           let packageRoot = try? Self.canonicalPackageURL(packageURL) {
            let capturedIdentities = Set(capture.reconstructionContentIdentities)
            reconstructionAttachmentSources = reconstructionAttachmentSources.map { source in
                guard capturedIdentities.contains(source.contentIdentity),
                      let packageBackedURL = try? MacScopeDocumentPackage.reconstructionAttachmentURL(
                          in: packageRoot,
                          contentIdentity: source.contentIdentity
                      ) else {
                    return source
                }
                return ReconstructionAttachmentSource(
                    contentIdentity: source.contentIdentity,
                    verifiedURL: packageBackedURL
                )
            }.sorted { $0.contentIdentity.digest < $1.contentIdentity.digest }
        }
        if let location {
            documentURL = location.canonicalURL
            documentMetadata?.document.packagePath = location.canonicalURL.path
            documentMetadata?.document.lastSavedAt = Date()
            documentMetadata?.document.isDirty = isDirty
            documentMetadata?.document.recentDocumentState = .available
            documentMetadata?.document.recentDocumentStateUpdatedAt = Date()
            recents.noteRecentDocument(location.canonicalURL)
        }
        saveError = nil
        documentSessionMutationObserver?.noteMutation(mutationGeneration)
    }

    func installValidatedPackage(
        _ package: WorkspaceDocumentValidatedPackage,
        from location: WorkspaceDocumentLocation
    ) throws {
        guard package.observation.condition == .valid,
              package.observation.location == location,
              package.observation.manifestSHA256
                == MacScopeDocumentPackage.fileHash(for: package.manifestData),
              package.observation.validatedContentSHA256 != nil else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-install-observation-mismatch"
            )
        }
        let contents = try MacScopeDocumentPackage.validatedContents(
            manifestData: package.manifestData,
            attachmentsByBinaryID: package.attachmentsByBinaryID,
            reconstructionState: package.reconstructionState,
            instructionSidecarData: package.instructionSidecarData
        )
        let sources = try Self.validatedReconstructionAttachmentSources(
            package.reconstructionAttachmentSources,
            for: package.reconstructionState,
            packageURL: location.canonicalURL
        )
        var restoredContents = contents
        restoredContents.reconstructionAttachmentSources = sources

        try restorePackage(restoredContents)
        documentURL = location.canonicalURL
        saveError = nil
        recents.noteRecentDocument(location.canonicalURL)
    }

    @discardableResult
    func saveWorkspacePackage(
        to packageURL: URL,
        using database: WorkspaceDatabase,
        documentID: UUID? = nil,
        inputCopyingDecision: WorkspaceInputCopyingDecision = .copyInputsIntoPackage,
        bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision = .resolveStoredBookmarks,
        now: Date = Date()
    ) throws -> WorkspacePackageManifest {
        guard !documentSessionWriterRetired else {
            throw WorkspaceDocumentSessionError.closed
        }
        let packageRoot = try Self.canonicalPackageURL(packageURL)
        // Snapshot the dirty-revision *before* writing: edits that race in during
        // the write keep the document dirty against this baseline, so a concurrent
        // mutation is never silently marked saved.
        let tokenAtWriteStart = dirtyTracker.token
        let effectiveDocumentID = documentID ?? self.documentID
        let persisted = try saveWorkspace(to: database, now: now, documentID: effectiveDocumentID)
        guard let workspaceID = persisted.workspace.id else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }
        let components = try database.packageComponents(
            workspaceID: workspaceID,
            documentID: effectiveDocumentID,
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            phase2ShellSession: phase2ShellSession.packagePhase2ShellSession
        )
        var capturedManifest = components.manifest
        capturedManifest.analystFindings = try persistableAnalystFindings()
        capturedManifest.navigatorState = persistableNavigatorState()
        var manifest = try MacScopeDocumentPackage.preparedManifest(
            capturedManifest,
            reconstructionState: reconstructionState
        )
        manifest.reaEvidence = reaResultEvidence.records.isEmpty ? nil : try JSONEncoder().encode(reaResultEvidence)
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: components.attachmentsByBinaryID,
            reconstructionState: reconstructionState,
            reconstructionAttachmentSources: reconstructionAttachmentSources,
            to: packageRoot
        )
        _ = try database.upsertWorkspaceDocument(
            WorkspaceDatabase.WorkspaceDocumentRecord(
                workspaceID: workspaceID,
                documentID: manifest.documentID,
                packagePath: packageRoot.path,
                lastOpenedAt: manifest.modifiedAt,
                lastSavedAt: manifest.modifiedAt,
                isDirty: false,
                inputCopyingDecision: inputCopyingDecision,
                bookmarkResolutionDecision: bookmarkResolutionDecision,
                recentDocumentState: .available,
                recentDocumentStateUpdatedAt: manifest.modifiedAt
            )
        )
        self.documentID = effectiveDocumentID
        documentMetadata = try database.workspaceDocumentMetadata(workspaceID: workspaceID)
        reconstructionAttachmentSources = try packageBackedReconstructionAttachmentSources(
            at: packageRoot
        )
        markDocumentSaved(at: tokenAtWriteStart)
        autosaveScheduler?.cancelPendingAutosave()
        return manifest
    }

    /// Writes the current workspace as a `.mscope` package to `url` (a Save As, or
    /// the first Save). A throwaway in-memory database is used purely as the
    /// serialization intermediary, so this works whether or not the workspace has
    /// ever been persisted. On success `documentURL` becomes the target for a
    /// subsequent plain Save; on failure it sets `lastIssue` and returns false.
    @discardableResult
    func writeDocumentPackage(to url: URL, now: Date = Date()) -> Bool {
        guard !documentSessionWriterRetired, !hasOwnedDocumentSessionWriter else {
            saveError = "The workspace document must be saved through its active session."
            return false
        }
        if let catalogPersistenceConflictError {
            saveError = "Couldn’t save the workspace: \(catalogPersistenceConflictError.localizedDescription)"
            return false
        }
        do {
            _ = try writeDocumentPackageThrowing(to: url, now: now)
            return true
        } catch {
            saveError = "Couldn’t save the workspace: \(error.localizedDescription)"
            return false
        }
    }

    /// HOP-6: the throwing form of `writeDocumentPackage(to:)` for headless callers (scripting,
    /// `--mcp`) that need the typed failure. Same scratch-database serialization, same atomic
    /// package publication and analyzer stamp; returns the canonical package root and manifest.
    @discardableResult
    func writeDocumentPackageThrowing(
        to url: URL, now: Date = Date()
    ) throws -> (url: URL, manifest: WorkspacePackageManifest) {
        guard !documentSessionWriterRetired, !hasOwnedDocumentSessionWriter else {
            throw WorkspaceDocumentSessionError.operationFailed("document-owned-by-active-session")
        }
        if let catalogPersistenceConflictError { throw catalogPersistenceConflictError }
        let databaseWorkspaceID = persistedWorkspaceID
        let databaseDocumentMetadata = documentMetadata
        defer {
            persistedWorkspaceID = databaseWorkspaceID
            documentMetadata = databaseDocumentMetadata
        }
        let packageRoot = try Self.canonicalPackageURL(url)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        persistedWorkspaceID = nil // fresh INSERT into the scratch database
        let manifest = try saveWorkspacePackage(to: packageRoot, using: database, now: now)
        documentURL = packageRoot
        saveError = nil
        recents.noteRecentDocument(packageRoot)
        return (packageRoot, manifest)
    }

    /// Opens a saved `.mscope` package at `url` and restores it into THIS workspace — the
    /// File ▸ Open Project… path, the symmetric counterpart to `writeDocumentPackage(to:)`.
    /// On success the package becomes `documentURL` (the target for a subsequent plain
    /// Save). On failure it sets `lastIssue` and returns false WITHOUT mutating the current
    /// workspace: `restoreWorkspacePackage(from:)` fully reads + validates the package
    /// before it touches any state, so a missing/corrupt package leaves the workspace
    /// intact (no silent data loss).
    @discardableResult
    func openDocumentPackage(at url: URL) -> Bool {
        do {
            _ = try openDocumentPackageThrowing(at: url)
            return true
        } catch {
            lastIssue = "Couldn’t open the workspace: \(error.localizedDescription)"
            return false
        }
    }

    /// HOP-6: the throwing form of `openDocumentPackage(at:)` for headless callers. Same full
    /// read + validation before any state changes (newer-analyzer refusal, HS-1 repair on open);
    /// returns the canonical package root.
    @discardableResult
    func openDocumentPackageThrowing(at url: URL) throws -> URL {
        let packageRoot = try Self.canonicalPackageURL(url)
        try restoreWorkspacePackage(from: packageRoot)
        documentURL = packageRoot
        schedulePhase2DurableShellRecoveryIfNeeded()
        // Keep the HS-1 repair diagnostic that restore just surfaced; add any catalog conflict.
        let issues = [catalogPersistenceConflictError?.localizedDescription,
                      WorkspaceAnalysisIntegrity.message(for: lastAnalysisRepairs)].compactMap { $0 }
        lastIssue = issues.isEmpty ? nil : issues.joined(separator: "\n\n")
        recents.noteRecentDocument(packageRoot)
        return packageRoot
    }

    @discardableResult
    func refreshDocumentMetadata(
        from database: WorkspaceDatabase
    ) throws -> WorkspaceDatabase.WorkspaceDocumentMetadata? {
        guard let persistedWorkspaceID else {
            documentMetadata = nil
            return nil
        }

        documentMetadata = try database.workspaceDocumentMetadata(workspaceID: persistedWorkspaceID)
        return documentMetadata
    }

    @discardableResult
    func markDocumentRecentState(
        _ state: WorkspaceRecentDocumentState,
        in database: WorkspaceDatabase,
        updatedAt: Date = Date()
    ) throws -> WorkspaceDatabase.WorkspaceDocumentMetadata? {
        guard let workspaceID = documentMetadata?.workspaceID ?? persistedWorkspaceID else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }

        try database.markWorkspaceDocumentRecentState(
            workspaceID: workspaceID,
            state: state,
            updatedAt: updatedAt
        )
        return try refreshDocumentMetadata(from: database)
    }

    @discardableResult
    func markBookmarkResolution(
        _ decision: WorkspaceBookmarkResolutionDecision,
        in database: WorkspaceDatabase,
        errorMessage: String? = nil
    ) throws -> WorkspaceDatabase.WorkspaceDocumentMetadata? {
        guard let workspaceID = documentMetadata?.workspaceID ?? persistedWorkspaceID else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }

        try database.markWorkspaceDocumentBookmarkResolution(
            workspaceID: workspaceID,
            decision: decision,
            errorMessage: errorMessage
        )
        return try refreshDocumentMetadata(from: database)
    }

    private static func verifiedReconstructionAttachmentSources(
        for state: ReconstructionWorkspaceState,
        workspaceID: UUID,
        documentID: UUID?,
        documentMetadata: WorkspaceDatabase.WorkspaceDocumentMetadata?,
        database: WorkspaceDatabase
    ) throws -> [ReconstructionAttachmentSource] {
        let contentRecords = try ReconstructionPackageCodec.contentRecords(in: state)
        guard !contentRecords.isEmpty else { return [] }
        let requiredRecordsByDigest = Dictionary(
            uniqueKeysWithValues: contentRecords.map {
                ($0.contentIdentity.digest, $0)
            }
        )

        var recoveredByDigest: [String: ReconstructionAttachmentSource] = [:]
        if let packagePath = documentMetadata?.document.packagePath,
           !packagePath.isEmpty {
            let packageURL = try canonicalPackageURL(
                URL(fileURLWithPath: packagePath, isDirectory: true)
            )
            let package = try MacScopeDocumentPackage.openPackage(from: packageURL)
            guard package.manifest.workspaceUUID == workspaceID,
                  documentID.map({ package.manifest.documentID == $0 }) ?? true else {
                throw WorkspaceDocumentSessionError.operationFailed(
                    "reconstruction-attachment-source-package-mismatch"
                )
            }

            let packageRecords = try ReconstructionPackageCodec.contentRecords(
                in: package.reconstructionState
            )
            let packageRecordsByDigest = Dictionary(
                uniqueKeysWithValues: packageRecords.map {
                    ($0.contentIdentity.digest, $0)
                }
            )
            for source in package.reconstructionAttachmentSources {
                let digest = source.contentIdentity.digest
                guard let requiredRecord = requiredRecordsByDigest[digest],
                      packageRecordsByDigest[digest] == requiredRecord else {
                    continue
                }
                guard source.contentIdentity == requiredRecord.contentIdentity else {
                    throw WorkspaceDocumentSessionError.operationFailed(
                        "reconstruction-attachment-source-catalog-mismatch"
                    )
                }
                let expectedURL = try canonicalPackageURL(
                    MacScopeDocumentPackage.reconstructionAttachmentURL(
                        in: packageURL,
                        contentIdentity: source.contentIdentity
                    )
                )
                let verifiedURL = try canonicalPackageURL(source.verifiedURL)
                guard verifiedURL == expectedURL else {
                    throw WorkspaceDocumentSessionError.operationFailed(
                        "reconstruction-attachment-source-location-mismatch"
                    )
                }
                recoveredByDigest[digest] = ReconstructionAttachmentSource(
                    contentIdentity: source.contentIdentity,
                    verifiedURL: verifiedURL
                )
            }
        }

        if recoveredByDigest.count < requiredRecordsByDigest.count {
            let durableSources = try database
                .availableDurableReconstructionAttachmentSources(workspaceID: workspaceID)
            for source in durableSources {
                let digest = source.contentIdentity.digest
                guard requiredRecordsByDigest[digest]?.contentIdentity
                        == source.contentIdentity else {
                    throw WorkspaceDocumentSessionError.operationFailed(
                        "reconstruction-attachment-source-catalog-mismatch"
                    )
                }
                if recoveredByDigest[digest] == nil {
                    recoveredByDigest[digest] = source
                }
            }
        }

        return try validatedReconstructionAttachmentSources(
            Array(recoveredByDigest.values),
            for: state,
            packageURL: nil
        )
    }

    private static func validatedReconstructionAttachmentSources(
        _ sources: [ReconstructionAttachmentSource],
        for state: ReconstructionWorkspaceState,
        packageURL: URL?
    ) throws -> [ReconstructionAttachmentSource] {
        let canonicalRoot = try packageURL.map { try canonicalPackageURL($0) }
        let expected = try ReconstructionPackageCodec.contentRecords(in: state)
        let expectedByDigest = Dictionary(
            uniqueKeysWithValues: expected.map {
                ($0.contentIdentity.digest, $0.contentIdentity)
            }
        )
        var seen = Set<String>()
        for source in sources {
            guard expectedByDigest[source.contentIdentity.digest] == source.contentIdentity,
                  seen.insert(source.contentIdentity.digest).inserted else {
                throw WorkspaceDocumentSessionError.operationFailed(
                    "reconstruction-attachment-source-catalog-mismatch"
                )
            }
            if let canonicalRoot {
                let expectedURL = try canonicalPackageURL(
                    MacScopeDocumentPackage.reconstructionAttachmentURL(
                        in: canonicalRoot,
                        contentIdentity: source.contentIdentity
                    )
                )
                let verifiedURL = try canonicalPackageURL(source.verifiedURL)
                guard verifiedURL == expectedURL else {
                    throw WorkspaceDocumentSessionError.operationFailed(
                        "reconstruction-attachment-source-location-mismatch"
                    )
                }
            }
        }
        guard seen.count == expectedByDigest.count else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "reconstruction-attachment-source-catalog-incomplete"
            )
        }
        return try sources.map { source in
            ReconstructionAttachmentSource(
                contentIdentity: source.contentIdentity,
                verifiedURL: try canonicalPackageURL(source.verifiedURL)
            )
        }.sorted { $0.contentIdentity.digest < $1.contentIdentity.digest }
    }

    private static func canonicalPackageURL(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try WorkspaceDocumentLocation.canonicalized(
            from: url,
            fileManager: fileManager
        ).canonicalURL
    }

    private func packageBackedReconstructionAttachmentSources(
        at packageURL: URL
    ) throws -> [ReconstructionAttachmentSource] {
        let packageRoot = try Self.canonicalPackageURL(packageURL)
        return try ReconstructionPackageCodec.contentRecords(in: reconstructionState).map { content in
            ReconstructionAttachmentSource(
                contentIdentity: content.contentIdentity,
                verifiedURL: try MacScopeDocumentPackage.reconstructionAttachmentURL(
                    in: packageRoot,
                    contentIdentity: content.contentIdentity
                )
            )
        }.sorted { $0.contentIdentity.digest < $1.contentIdentity.digest }
    }

    private func tryPackageBackedReconstructionAttachmentSources(
        at packageURL: URL
    ) -> [ReconstructionAttachmentSource] {
        (try? packageBackedReconstructionAttachmentSources(at: packageURL)) ?? []
    }

    @discardableResult
    func restoreWorkspace(
        workspaceID: Int64,
        from database: WorkspaceDatabase
    ) throws -> Bool {
        guard let persistedWorkspace = try database.loadWorkspaceState(workspaceID: workspaceID) else {
            return false
        }
        let documentMetadata = try database.workspaceDocumentMetadata(workspaceID: workspaceID)
        let reconstructionSources = try Self.verifiedReconstructionAttachmentSources(
            for: persistedWorkspace.reconstructionState,
            workspaceID: persistedWorkspace.workspace.uuid,
            documentID: documentMetadata?.document.documentID,
            documentMetadata: documentMetadata,
            database: database
        )

        restoreWorkspace(
            persistedWorkspace,
            documentMetadata: documentMetadata,
            reconstructionAttachmentSources: reconstructionSources
        )
        return true
    }

    func restoreWorkspace(
        _ persistedWorkspace: WorkspaceDatabase.PersistedWorkspace,
        documentMetadata: WorkspaceDatabase.WorkspaceDocumentMetadata? = nil,
        reconstructionAttachmentSources: [ReconstructionAttachmentSource] = []
    ) {
        persistedWorkspaceID = persistedWorkspace.workspace.id
        reconstructionPersistenceRetryPending = false
        self.documentMetadata = documentMetadata
        workspaceID = persistedWorkspace.workspace.uuid
        if let documentMetadata {
            documentID = documentMetadata.documentID
        }
        establishNativeDriveContext(origin: .authoritativeRestore)
        workspaceName = persistedWorkspace.workspace.name
        reconstructionState = persistedWorkspace.reconstructionState
        reconstructionLifecycle = .empty
        reaResultEvidence = try! REAResultEvidenceStore()
        selectedReconstructionJobID = nil
        self.reconstructionAttachmentSources = reconstructionAttachmentSources
            .sorted { $0.contentIdentity.digest < $1.contentIdentity.digest }
        phase2AssistantSessionHistory = persistedWorkspace.assistantSessionRecords
        phase2RuntimeAuthorityRecords = persistedWorkspace.runtimeAuthorityRecords
        logicalBreakpointCatalogAvailability = persistedWorkspace.logicalBreakpointCatalogAvailability
        launchProfileCatalogAvailability = persistedWorkspace.launchProfileCatalogAvailability
        // HS-2b: database restore/import gets the same load-time validation as the package open
        // path (#293): repair before install, then one diagnostic and a rebuild of each image.
        var restoredSnapshot = persistedWorkspace.snapshot
        let analysisRepairs = persistedWorkspace.analysisRepairs
            + WorkspaceAnalysisIntegrity.repair(&restoredSnapshot)
        installSnapshotForIdentityRestore(restoredSnapshot)
        restorePersistedSelection(
            persistedAddress: persistedWorkspace.session.selectedAddress,
            requestedFocus: persistedWorkspace.session.focusedImageSlot
        )
        rehydrateLoadedImages()
        recomputeCrossImageXrefs()
        selectedSidebarItemID = persistedWorkspace.session.selectedSidebarItemID
        selectedTool = persistedWorkspace.session.selectedTool
        restoreReconstructionSelectionFromSidebar()
        editorMode = persistedWorkspace.session.editorMode
        isInspectorPresented = persistedWorkspace.session.isInspectorPresented
        sidebarSearchText = persistedWorkspace.session.sidebarSearchText
        installPhase2ShellSessionProjection(
            persistedWorkspace.phase2ShellSessionRecord?.shellSession.restoredProjection
                ?? .inactive
        )
        syncGraphElementToSelectedAddress()
        resetNavigationHistory(seed: selectedAddress)
        lastIssue = catalogPersistenceConflictError?.localizedDescription
        // A freshly restored workspace matches its on-disk state, so it is clean.
        resetDirtyStateToClean()
        finishNativeDriveInstallation()
        surfaceAndRebuildAnalysisRepairs(analysisRepairs)
    }

    /// Resets the dirty tracker to a fresh clean baseline (used whenever the store
    /// adopts a snapshot that mirrors persisted/on-disk state). Clears any pending
    /// autosave so a stale debounce can't write the just-loaded document.
    private func resetDirtyStateToClean() {
        advanceReconstructionPublicationLifecycle()
        dirtyUndoTokenGeneration &+= 1
        slotUndoTargets.removeAll()
        activeDocumentWriteCapture = nil
        dirtyTracker = DocumentDirtyTracker()
        dirtyTracker.markSaved()
        isDirty = dirtyTracker.isDirty
        advanceDocumentMutationGeneration()
        autosaveScheduler?.cancelPendingAutosave()
        // Discard the PREVIOUS document's undo history: a fresh clean baseline (new /
        // imported / restored document) must not retain stale undo closures, which on
        // a later Cmd-Z would re-enter this new tracker via `restoreDocumentDirtyToken`,
        // spuriously dirty the document, and let autosave overwrite an unrelated file.
        hostUndoManager?.removeAllActions()
        fallbackUndoManager.removeAllActions()
    }

    func captureReconstructionPublicationAuthority() -> ReconstructionPublicationAuthority? {
        guard !reconstructionPublicationLifecycleEpochExhausted else { return nil }
        return ReconstructionPublicationAuthority(
            workspaceID: workspaceID,
            documentID: documentID,
            lifecycleEpoch: reconstructionPublicationLifecycleEpoch
        )
    }

    func ownsReconstructionPublicationAuthority(
        _ authority: ReconstructionPublicationAuthority
    ) -> Bool {
        !reconstructionPublicationLifecycleEpochExhausted
            && workspaceID == authority.workspaceID
            && documentID == authority.documentID
            && reconstructionPublicationLifecycleEpoch == authority.lifecycleEpoch
    }

    private func advanceReconstructionPublicationLifecycle() {
        highestPublishedReconstructionCommitSequence = nil
        guard !reconstructionPublicationLifecycleEpochExhausted else { return }
        guard reconstructionPublicationLifecycleEpoch < UInt64.max else {
            reconstructionPublicationLifecycleEpochExhausted = true
            return
        }
        reconstructionPublicationLifecycleEpoch += 1
    }

    func restoreWorkspacePackage(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let packageRoot = try Self.canonicalPackageURL(
            packageURL,
            fileManager: fileManager
        )
        let package = try MacScopeDocumentPackage.openPackage(
            from: packageRoot,
            fileManager: fileManager
        )
        try restorePackage(package)
    }

    private func restorePackage(_ package: WorkspacePackageContents) throws {
        let restoredAnalystFindings = package.manifest.analystFindings ?? .empty
        try Self.validateAnalystFindingsForRestore(restoredAnalystFindings,
            workspaceID: package.manifest.workspaceUUID, documentID: package.manifest.documentID)
        let restoredREA = try package.manifest.reaEvidence.map { bytes in
            guard bytes.count <= 24 * 1_024 * 1_024 else { throw REAResultEvidenceError.bounds }
            let history = try JSONDecoder().decode(REAResultEvidenceStore.self, from: bytes)
            guard history.records.allSatisfy({ $0.authority.workspaceID == package.manifest.workspaceUUID }) else {
                throw REAResultEvidenceError.invalidIdentity
            }
            return history
        } ?? REAResultEvidenceStore()
        // Legacy instruction bits must cross into durable owner-sealed intent before the install
        // path projects compatibility from the catalog. Keep this preparation transactional so an
        // unprovable migration leaves an already-open document untouched.
        var restoredSnapshot = package.snapshot
        try Self.importLegacyBreakpointBitsIfNeeded(
            in: &restoredSnapshot,
            availability: package.logicalBreakpointCatalogAvailability
        )
        let reconstructionSources = try Self.validatedReconstructionAttachmentSources(
            package.reconstructionAttachmentSources,
            for: package.reconstructionState,
            packageURL: nil
        )

        persistedWorkspaceID = nil
        reconstructionPersistenceRetryPending = false
        documentMetadata = nil
        documentID = package.manifest.documentID
        workspaceID = package.manifest.workspaceUUID
        establishNativeDriveContext(origin: .authoritativeRestore)
        workspaceName = package.manifest.workspaceName
        reconstructionState = package.reconstructionState
        reconstructionLifecycle = .empty
        reaResultEvidence = restoredREA
        selectedReconstructionJobID = nil
        reconstructionAttachmentSources = reconstructionSources
        phase2AssistantSessionHistory = phase2AssistantPersistenceRecords(from: package.manifest.assistantSessionRecords)
        logicalBreakpointCatalogAvailability = package.logicalBreakpointCatalogAvailability
        launchProfileCatalogAvailability = package.launchProfileCatalogAvailability
        installSnapshotForIdentityRestore(restoredSnapshot)
        installValidatedAnalystFindings(restoredAnalystFindings)
        restoreNavigatorStates(from: package.manifest)

        if let session = package.session {
            restorePersistedSelection(
                persistedAddress: session.selectedAddress,
                requestedFocus: session.focusedImageSlot
            )
            selectedSidebarItemID = session.selectedSidebarItemID
            selectedTool = session.selectedTool
            restoreReconstructionSelectionFromSidebar()
            editorMode = session.editorMode
            isInspectorPresented = session.isInspectorPresented
            sidebarSearchText = session.sidebarSearchText
            installPhase2ShellSessionProjection(
                session.phase2ShellSession?.restoredProjection ?? .inactive
            )
        } else {
            // A pre-session package has no persisted image owner. Preserve its historical primary
            // default explicitly rather than treating an absent owner like a stale requested slot.
            restorePersistedSelection(
                persistedAddress: package.snapshot.instructions.first?.address,
                requestedFocus: package.snapshot.primarySlot
            )
            selectedSidebarItemID = package.snapshot.binaries.first.map { "binary:\($0.id.uuidString)" }
            selectedTool = .project
            editorMode = .disassembly
            isInspectorPresented = true
            sidebarSearchText = ""
            installPhase2ShellSessionProjection(.inactive)
        }

        rehydrateLoadedImages()
        recomputeCrossImageXrefs()
        syncGraphElementToSelectedAddress()
        resetNavigationHistory(seed: selectedAddress)
        lastIssue = catalogPersistenceConflictError?.localizedDescription
        resetDirtyStateToClean()
        finishNativeDriveInstallation()
        surfaceAndRebuildAnalysisRepairs(package.analysisRepairs)
    }

    /// HS-1: one diagnostic listing what load-time validation removed, then a rebuild of each
    /// affected image through the existing structural reanalysis path (retained bytes, MS-16).
    private func surfaceAndRebuildAnalysisRepairs(_ repairs: [WorkspaceAnalysisRepair]) {
        lastAnalysisRepairs = repairs
        guard let message = WorkspaceAnalysisIntegrity.message(for: repairs) else { return }
        lastIssue = [lastIssue, message].compactMap { $0 }.joined(separator: "\n\n")
        for repair in repairs where snapshot.binary(in: repair.slot) != nil {
            reanalyzeHonoringOverrides(in: repair.slot)
        }
    }

    /// Creates a new logical document/workspace from the current content. Ordinary Save As is not
    /// a fork and therefore never calls this seam. Detaching the old URL prevents an autosave from
    /// overwriting the source package before the fork receives its own destination.
    @discardableResult
    func forkWorkspaceIdentity() -> WorkspaceIdentityFork {
        advanceDocumentInstallation()
        let sourceDocumentID = documentID
        let sourceWorkspaceID = workspaceID
        documentID = UUID()
        workspaceID = UUID()
        persistedWorkspaceID = nil
        reconstructionPersistenceRetryPending = false
        documentMetadata = nil
        documentURL = nil
        activeDocumentWriteCapture = nil
        advanceReconstructionPublicationLifecycle()
        advanceDocumentMutationGeneration()
        autosaveScheduler?.cancelPendingAutosave()
        return WorkspaceIdentityFork(
            sourceDocumentID: sourceDocumentID,
            sourceWorkspaceID: sourceWorkspaceID,
            documentID: documentID,
            workspaceID: workspaceID
        )
    }

    // MARK: - Restore-time derived-product rehydration

    /// Cancels the current pass and invalidates every result it captured. The epoch is necessary in
    /// addition to cooperative cancellation because an injected provider may ignore its token and
    /// still return after another document has replaced this store's snapshot.
    private func supersedeRehydration() {
        cancelScheduledRehydrationRestart()
        rehydrationEpoch &+= 1
        rehydrationTask?.cancel()
        rehydrationTask = nil
    }

    /// Retires an enqueued restart independently of the retained loader task. Generation checking
    /// protects against an already-enqueued main-actor task that observes cancellation too late.
    private func cancelScheduledRehydrationRestart() {
        rehydrationRestartGeneration &+= 1
        rehydrationRestartTask?.cancel()
        rehydrationRestartTask = nil
    }

    /// Re-drives rehydration only after the enclosing synchronous mutation has finished changing
    /// the snapshot. Multiple edits in one run-loop turn collapse to the last current snapshot.
    private func scheduleRehydrationRestart() {
        cancelScheduledRehydrationRestart()
        let generation = rehydrationRestartGeneration
        rehydrationRestartTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.rehydrationRestartGeneration == generation else {
                return
            }
            self.rehydrationRestartTask = nil
            self.rehydrateLoadedImages()
        }
    }

    /// Reconstructs the byte-derived products persistence deliberately omits. Candidate capture is
    /// main-actor isolated; loader work runs in the retained detached task; each completed image is
    /// spliced back independently so one bad attachment cannot prevent its siblings from restoring.
    func rehydrateLoadedImages() {
        supersedeRehydration()

        let candidates = snapshot.binaries.compactMap { binary -> RehydrationCandidate? in
            guard let analysis = snapshot.analysis(in: binary.slot),
                  !analysis.imageBytes.isEmpty,
                  analysis.sections.isEmpty,
                  analysis.machOMetadata == nil else {
                return nil
            }
            return RehydrationCandidate(
                slot: binary.slot,
                binaryID: binary.id,
                imageBytes: analysis.imageBytes,
                persistedAnalysis: analysis,
                coffSectionLayoutVersion: Self.savedCOFFSectionLayoutVersion(binary),
                overrides: Dictionary(uniqueKeysWithValues: snapshot.addressOverrides
                    .filter { $0.key.slot == binary.slot }.map { ($0.key.address, $0.value) }),
                artifactIntegrityDiagnostic: Self.artifactIntegrityDiagnostic(for: binary),
                reanalysisLandingEpoch: reanalysisLandingEpochsBySlot[binary.slot] ?? 0
            )
        }
        guard !candidates.isEmpty else { return }

        let epoch = rehydrationEpoch
        rehydrationTask = Task.detached(priority: .userInitiated) { [weak self, engine, candidates] in
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                do {
                    var rehydrated = try engine.rehydrate(
                        imageBytes: candidate.imageBytes,
                        // Attachments store the exact already-selected thin slice. Reapplying the
                        // container-local selection index would reinterpret thin bytes as a fat
                        // container and can select unrelated or nonexistent data.
                        requestedSliceIndex: nil,
                        preserving: candidate.persistedAnalysis,
                        overrides: candidate.overrides,
                        coffSectionLayoutVersion: candidate.coffSectionLayoutVersion,
                        cancellation: AnalysisCancellationToken { Task.isCancelled }
                    )
                    if let diagnostic = candidate.artifactIntegrityDiagnostic,
                       !rehydrated.diagnostics.contains(diagnostic) {
                        rehydrated.diagnostics.append(diagnostic)
                    }
                    guard !Task.isCancelled else { break }
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.rehydrationEpoch == epoch,
                              self.snapshot.binary(in: candidate.slot)?.id == candidate.binaryID,
                              self.snapshot.patches(in: candidate.slot) == candidate.overrides
                                .compactMapValues({ $0.patch }).filter({ !$0.value.isEmpty }) else {
                            return
                        }
                        // A full structural reanalysis that landed after candidate capture is
                        // authoritative for this slot, including its loader-derived products.
                        // Replacing it with `rehydrated` would resurrect the old functions and
                        // instructions carried in `candidate.persistedAnalysis`. If rehydration
                        // wins the race instead, applying it remains safe: the still-pending full
                        // reanalysis will replace it afterward.
                        guard (self.reanalysisLandingEpochsBySlot[candidate.slot] ?? 0)
                                == candidate.reanalysisLandingEpoch else {
                            self.restorePendingSelection(afterRehydrating: candidate)
                            self.acceptNativeReadiness(
                                imageSlot: candidate.slot,
                                binaryID: candidate.binaryID,
                                rehydrationEpoch: epoch
                            )
                            return
                        }
                        let previousNavigatorFingerprint = self.snapshot.analysis(in: candidate.slot)?.analysisInputFingerprint
                        self.restampAnalysisInputFingerprint(&rehydrated, for: candidate.slot)
                        self.snapshot.replaceAnalysis(rehydrated, in: candidate.slot)
                        self.navigatorAnalysisDidLand(in: candidate.slot, previousFingerprint: previousNavigatorFingerprint)
                        self.restorePendingSelection(afterRehydrating: candidate)
                        self.acceptNativeReadiness(
                            imageSlot: candidate.slot,
                            binaryID: candidate.binaryID,
                            rehydrationEpoch: epoch
                        )
                    }
                } catch {
                    if Task.isCancelled || error is AnalysisCancelled { break }
                    let diagnostic = AnalysisDiagnostic(
                        severity: .error,
                        address: candidate.persistedAnalysis.instructions.first?.address
                            ?? candidate.persistedAnalysis.functions.first?.startAddress
                            ?? 0,
                        kind: .loaderTruncation,
                        message: "Couldn’t restore derived analysis: \(error.localizedDescription)"
                    )
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.rehydrationEpoch == epoch,
                              self.snapshot.binary(in: candidate.slot)?.id == candidate.binaryID,
                              self.snapshot.patches(in: candidate.slot) == candidate.overrides
                                .compactMapValues({ $0.patch }).filter({ !$0.value.isEmpty }) else {
                            return
                        }
                        self.snapshot.mutateAnalysis(in: candidate.slot) { analysis in
                            if !analysis.diagnostics.contains(diagnostic) {
                                analysis.diagnostics.append(diagnostic)
                            }
                        }
                        self.discardPendingSelection(matching: candidate)
                        self.rejectNativeReadiness(
                            imageSlot: candidate.slot,
                            binaryID: candidate.binaryID,
                            rehydrationEpoch: epoch,
                            failure: .rehydrationFailed(
                                code: String(describing: type(of: error))
                            )
                        )
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.rehydrationEpoch == epoch else { return }
                self.rehydrationTask = nil
            }
        }
    }

    /// Deterministic test seam over the production path. A restore has already kicked a pass, so
    /// await that exact retained generation when present; direct store tests with no pending pass
    /// start one normally and then await it. The task clears its retained property when complete.
    func rehydrateLoadedImagesSynchronouslyForTesting() async {
        if let task = rehydrationTask {
            await task.value
            return
        }
        rehydrateLoadedImages()
        let task = rehydrationTask
        await task?.value
    }

    /// Await-only test seam for lifecycle operations that production code must restart itself.
    /// Unlike `rehydrateLoadedImagesSynchronouslyForTesting`, this never masks a missing restart by
    /// creating a pass when neither a scheduled nor a retained pass exists. A lifecycle mutation
    /// may replace either task while this method is suspended, so return only after observing both
    /// retained slots empty in the same main-actor turn.
    func awaitCurrentRehydrationForTesting() async {
        while true {
            if let scheduledRestart = rehydrationRestartTask {
                await scheduledRestart.value
                continue
            }
            if let currentPass = rehydrationTask {
                await currentPass.value
                continue
            }
            return
        }
    }

    /// Installs a replacement workspace identity without letting its observer momentarily
    /// reinterpret the previous document's qualified selection or runtime coordination tokens.
    /// Restore follows this with `restorePersistedSelection`; fresh import uses the primary image.
    private func installSnapshotForIdentityRestore(
        _ restoredSnapshot: WorkspaceSnapshot, preservingBinaryOpenTicket: UUID? = nil
    ) {
        advanceDocumentInstallation()
        if let state = binaryOpenState, !state.phase.isTerminal,
           state.id != preservingBinaryOpenTicket {
            cancelBinaryOpen(state.id)
        }
        var restoredSnapshot = restoredSnapshot
        Self.reprojectLogicalBreakpointCompatibility(
            in: &restoredSnapshot,
            availability: logicalBreakpointCatalogAvailability
        )
        // A result captured from the previous document must not land in this replacement, even if
        // it happens to reuse the same slot number. Epoch invalidation protects against providers
        // that return after cooperative cancellation.
        supersedeReanalysis()
        supersedeRehydration()
        pendingRehydratedSelection = nil
        invalidateAllOwnerBoundAuthoringPresentations()

        // Owner-bound drafts remain published so replacement never discards the user's visible
        // work; their permanent tombstones above force every eventual callback to reject. Clear
        // only workspace-global or non-authoring runtime presentations.
        typeEditorRequest = nil
        loaderOptionsRequest = nil
        cHeaderImportRequest = nil
        cHeaderImportSummary = nil
        searchCursor = nil
        xrefCursor = nil
        liveProgramCounterTarget = nil
        clearInteractiveSelection()
        navigationHistory.reset(seed: nil)

        // A whole-workspace replacement starts a new breakpoint coordination domain. Advance the
        // generation before resetting numeric revisions so pending async consumers cannot compare
        // an old zero token equal to the new baseline.
        invalidateDebuggerBreakpointRevisionGeneration()
        debuggerBreakpointRevisions.removeAll()

        phase2ReadLedger.replaceWorkspace(with: restoredSnapshot)
        isCoordinatingSnapshotIdentityChange = true
        snapshot = restoredSnapshot
        isCoordinatingSnapshotIdentityChange = false
        reconcileDebuggerWorkspaceArtifactCatalog(fullWorkspaceReplacement: true)
        reconcileDebuggerBreakpointResolutionCatalog(fullWorkspaceReplacement: true)
        focusedImageSlotStorage = restoredSnapshot.primarySlot
        lastKnownDebuggerBreakpointSets = Self.debuggerBreakpointSets(
            in: restoredSnapshot,
            availability: logicalBreakpointCatalogAvailability
        )
        lastKnownDebuggerBinaryIDs = Self.debuggerBinaryIDs(in: restoredSnapshot)
    }

    /// Restores focus and its bare persisted coordinate as one image-qualified value. An explicitly
    /// requested slot that is no longer present may clamp visible focus to the primary image for
    /// usability, but its old coordinate is always discarded rather than reinterpreted at a
    /// primary-image collision.
    private func restorePersistedSelection(
        persistedAddress: UInt64?,
        requestedFocus: ImageSlot
    ) {
        clearInteractiveSelection()
        pendingRehydratedSelection = nil
        let requestedImageExists = snapshot.binary(in: requestedFocus) != nil
        focusedImageSlotStorage = requestedImageExists ? requestedFocus : snapshot.primarySlot

        guard requestedImageExists, let persistedAddress else {
            clearInteractiveSelection()
            return
        }

        if snapshot.containsLoadedAddress(persistedAddress, in: requestedFocus) {
            selectedImageAddress = ImageAddress(slot: requestedFocus, address: persistedAddress)
            return
        }

        // Persistence deliberately omits byte-derived sections. Defer only when this exact binary
        // is eligible for the restore-time loader pass; an arbitrary invalid coordinate remains
        // rejected and can never become visible without fresh same-owner mapping evidence.
        guard let binary = snapshot.binary(in: requestedFocus),
              let analysis = snapshot.analysis(in: requestedFocus),
              !analysis.imageBytes.isEmpty,
              analysis.sections.isEmpty,
              analysis.machOMetadata == nil else {
            clearInteractiveSelection()
            return
        }
        pendingRehydratedSelection = PendingRehydratedSelection(
            slot: requestedFocus,
            binaryID: binary.id,
            address: persistedAddress
        )
    }

    private func restorePendingSelection(afterRehydrating candidate: RehydrationCandidate) {
        guard let pending = pendingRehydratedSelection,
              pending.slot == candidate.slot,
              pending.binaryID == candidate.binaryID else { return }
        pendingRehydratedSelection = nil
        guard selectedImageAddress == nil,
              focusedImageSlotStorage == pending.slot,
              snapshot.binary(in: pending.slot)?.id == pending.binaryID,
              snapshot.containsLoadedAddress(pending.address, in: pending.slot) else { return }
        selectedImageAddress = ImageAddress(slot: pending.slot, address: pending.address)
        syncGraphElementToSelectedAddress()
        resetNavigationHistory(seed: pending.address)
    }

    private func discardPendingSelection(matching candidate: RehydrationCandidate) {
        guard pendingRehydratedSelection?.slot == candidate.slot,
              pendingRehydratedSelection?.binaryID == candidate.binaryID else { return }
        pendingRehydratedSelection = nil
    }

    private func applyLaunchConfiguration(_ configuration: WorkspaceLaunchConfiguration) {
        if let editorMode = configuration.editorMode {
            self.editorMode = editorMode
        }
    }

    var sidebarItems: [SidebarItem] {
        switch selectedTool {
        case .project:
            var items: [SidebarItem] = [
                SidebarItem(id: "section:binaries", title: "Binaries", detail: "\(snapshot.binaries.count) target", systemImage: "lumen.binaryFile")
            ]
            items += snapshot.binaries.map {
                SidebarItem(id: "binary:\($0.id.uuidString)", title: $0.name, detail: "\($0.kind) - \($0.architecture)", systemImage: "lumen.binaryFile")
            }
            items.append(SidebarItem(id: "section:functions", title: "Functions", detail: "\(snapshot.functions.count) discovered", systemImage: "function"))
            items += snapshot.functions.map {
                SidebarItem(
                    id: "function:\($0.id.uuidString)",
                    title: snapshot.displayName(at: $0.startAddress, default: $0.name),
                    detail: $0.startAddress.hexAddress,
                    systemImage: "curlybraces",
                    tag: snapshot.tag(at: $0.startAddress),
                    colorTag: snapshot.colorTag(at: $0.startAddress)
                )
            }
            return items
        case .symbols:
            return symbolNavigatorItems
        case .strings:
            return snapshot.stringLiterals.map {
                SidebarItem(
                    id: "string:\($0.id.uuidString)",
                    title: Self.normalizedStringPreview($0.value),
                    detail: "\($0.address.hexAddress) - \($0.sourceSection)",
                    systemImage: "text.quote"
                )
            }
        case .xrefs:
            return snapshot.xrefs.map {
                SidebarItem(id: "xref:\($0.id.uuidString)", title: XRefKindPresentation.title($0.kind), detail: "\($0.from.hexAddress) -> \($0.to.hexAddress)", systemImage: XRefKindPresentation.objectKind($0.kind).symbol)
            }
        case .debug:
            return debugSidebarItems
        case .extensions:
            return extensionsSidebarItems
        case .reconstruction:
            let jobs = reconstructionState.jobs.enumerated().sorted { lhs, rhs in
                switch (lhs.element.creationOrdinal, rhs.element.creationOrdinal) {
                case let (left?, right?) where left != right:
                    return left > right
                default:
                    // Legacy ordering is never promoted into authority; retain the already
                    // committed collection order when no durable ordinal can distinguish rows.
                    return lhs.offset < rhs.offset
                }
            }.map(\.element)
            var items = [
                SidebarItem(
                    id: "section:reconstruction-jobs",
                    title: "Jobs",
                    detail: "\(jobs.count) committed",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                ),
            ]
            items += jobs.map { job in
                let ordinal = job.creationOrdinal.map { "#\($0) · " } ?? ""
                return SidebarItem(
                    id: Self.reconstructionSidebarItemID(job.jobID),
                    title: job.objective,
                    detail: "\(ordinal)\(job.state.rawValue)",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
            }
            return items
        case .types:
            return TypeAtlasNavigator.items(for: typeAtlasCatalog)
        }
    }

    /// U7a: the Type Atlas the Types navigator lists: the primary image's, like the other tools'
    /// compatibility rows, plus the workspace's user types.
    var typeAtlasCatalog: ImageTypeCatalog {
        snapshot.typeCatalog(in: snapshot.primarySlot)
    }

    /// The Type Atlas entry selected in the Types navigator, which the inspector shows.
    var selectedTypeAtlasEntry: TypeAtlasEntry? {
        guard selectedTool == .types, let itemID = selectedSidebarItemID,
              TypeAtlasNavigator.isEntryItem(itemID) else { return nil }
        return TypeAtlasNavigator.entry(forItemID: itemID, in: typeAtlasCatalog)
    }

    private var symbolNavigatorItems: [SidebarItem] {
        let imports = snapshot.imports
        let exports = snapshot.exports
        let symbols = snapshot.symbols

        guard !imports.isEmpty || !exports.isEmpty || !symbols.isEmpty else {
            return snapshot.functions.map {
                SidebarItem(id: "symbol:\($0.id.uuidString)", title: $0.name, detail: $0.startAddress.hexAddress, systemImage: "curlybraces")
            }
        }

        var items: [SidebarItem] = []

        if !imports.isEmpty {
            items.append(
                SidebarItem(id: "section:imports", title: "Imports", detail: "\(imports.count) referenced", systemImage: AppSidebarChrome.importRowIcon)
            )
            items += imports.map {
                SidebarItem(
                    id: "import:\($0.id.uuidString)",
                    title: $0.name,
                    detail: $0.libraryName ?? "Imported",
                    systemImage: AppSidebarChrome.importRowIcon
                )
            }
        }

        if !exports.isEmpty {
            items.append(
                SidebarItem(id: "section:exports", title: "Exports", detail: "\(exports.count) published", systemImage: AppSidebarChrome.exportRowIcon)
            )
            items += exports.map {
                SidebarItem(
                    id: "export:\($0.id.uuidString)",
                    title: $0.name,
                    detail: $0.address.map(\.hexAddress) ?? $0.source,
                    systemImage: AppSidebarChrome.exportRowIcon
                )
            }
        }

        if !symbols.isEmpty {
            items.append(
                SidebarItem(id: "section:symbols", title: "Symbols", detail: "\(symbols.count) defined", systemImage: "curlybraces")
            )
            items += symbols.map {
                SidebarItem(
                    id: "symbol:\($0.id.uuidString)",
                    title: $0.name,
                    detail: $0.address.map(\.hexAddress) ?? $0.kind,
                    systemImage: "curlybraces"
                )
            }
        }

        return items
    }

    var visibleSidebarItems: [SidebarItem] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = query.isEmpty ? sidebarItems : sidebarItems.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || (item.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
        if let rules = navigatorFilterRules[selectedTool], rules.isActive {
            items = Self.applying(rules, to: items, fields: navigatorRuleFields)
        }
        return items
    }

    /// The rows the rules keep, each section header only while its section still has rows.
    static func applying(
        _ rules: NavigatorFilterRules,
        to items: [SidebarItem],
        fields: [SidebarItem.ID: [String: String]]
    ) -> [SidebarItem] {
        var kept: [SidebarItem] = []
        var pendingHeader: SidebarItem?
        for item in items {
            if item.isSectionHeader {
                pendingHeader = item
                continue
            }
            guard rules.matches(fields[item.id] ?? [:]) else { continue }
            if let header = pendingHeader {
                kept.append(header)
                pendingHeader = nil
            }
            kept.append(item)
        }
        return kept
    }

    /// Each Symbols or Strings row's values for the rule filters, keyed by its sidebar id.
    var navigatorRuleFields: [SidebarItem.ID: [String: String]] {
        typealias Field = NavigatorFilterField
        var fields: [SidebarItem.ID: [String: String]] = [:]
        switch selectedTool {
        case .symbols:
            for item in snapshot.imports {
                fields["import:\(item.id.uuidString)"] = [Field.name: item.name, Field.kind: "Import", Field.library: item.libraryName ?? ""]
            }
            for item in snapshot.exports {
                fields["export:\(item.id.uuidString)"] = [Field.name: item.name, Field.kind: "Export",
                                                          Field.address: item.address.map(\.hexAddress) ?? ""]
            }
            for item in snapshot.symbols {
                fields["symbol:\(item.id.uuidString)"] = [Field.name: item.name, Field.kind: "Symbol", Field.library: item.libraryName ?? "",
                                                          Field.address: item.address.map(\.hexAddress) ?? ""]
            }
            if snapshot.imports.isEmpty && snapshot.exports.isEmpty && snapshot.symbols.isEmpty {
                for function in snapshot.functions {
                    fields["symbol:\(function.id.uuidString)"] = [Field.name: function.name, Field.kind: "Symbol",
                                                                  Field.address: function.startAddress.hexAddress]
                }
            }
        case .strings:
            for literal in snapshot.stringLiterals {
                fields["string:\(literal.id.uuidString)"] = [Field.text: literal.value, Field.section: literal.sourceSection,
                                                             Field.length: String(literal.byteLength), Field.address: literal.address.hexAddress]
            }
        default:
            break
        }
        return fields
    }

    var selectableVisibleSidebarItems: [SidebarItem] {
        visibleSidebarItems.filter { !$0.isSectionHeader }
    }

    var selectedInstruction: InstructionRow? {
        guard let selection = selectedImageAddress else { return nil }
        return snapshot.analysis(in: selection.slot)?.instructions.first {
            $0.address == selection.address
        }
    }

    var selectedStringLiteral: StringLiteralSummary? {
        guard selectedTool == .strings,
              let selection = selectedImageAddress else { return nil }
        return snapshot.analysis(in: selection.slot)?.stringLiterals.first {
            $0.address == selection.address
        }
    }

    var documentCommandPolicy: WorkspaceDocumentCommandPolicy {
        if let session = documentSessionMutationObserver as? WorkspaceDocumentSession {
            return WorkspaceDocumentCommandPolicy.resolve(snapshot: session.snapshot)
        }
        return WorkspaceDocumentCommandPolicy.resolve(metadata: documentMetadata)
    }

    /// The single slot-coherent handoff consumed by the live graph and its callbacks.
    var focusedGraphProjection: FocusedGraphProjection {
        snapshot.graphProjection(in: focusedImageSlot)
    }

    var graphNodeSelectionTargets: [GraphSelectionTarget] {
        graphNodeSelectionTargets(in: focusedGraphProjection)
    }

    /// C2 (vim profile): every selection change re-synced the graph element by rebuilding every
    /// node's target (~190 ms on vim). The targets depend only on the projection, whose arrays share
    /// the analysis' storage, so an unchanged projection compares equal at once and reuses them.
    private var graphSelectionTargetsCache: (projection: FocusedGraphProjection, targets: [GraphSelectionTarget])?

    private func graphNodeSelectionTargets(
        in projection: FocusedGraphProjection
    ) -> [GraphSelectionTarget] {
        if let cache = graphSelectionTargetsCache, cache.projection == projection {
            return cache.targets
        }
        let targets = FocusedGraphBuilder.selectionTargets(projection)
        graphSelectionTargetsCache = (projection, targets)
        return targets
    }

    /// The entry point for opening a binary from the UI. Inspects the file first: a
    /// fat/universal Mach-O with more than one slice presents the loader-options dialog
    /// so the user can pick a slice; anything else (thin Mach-O, ELF/PE) imports straight
    /// through with the default slice rule.
    @discardableResult
    func beginImport(url: URL) -> UUID {
        beginLoad(url: url, operation: .replaceWorkspace)
    }

    /// Additional-image imports use the exact same options/identity path as the initial import.
    /// In particular, a multi-member archive can never bypass the explicit member choice.
    func beginLoadAdditionalBinary(url: URL) {
        beginLoad(url: url, operation: .addImage)
    }

    @discardableResult
    private func beginLoad(url: URL, operation: LoaderOptionsRequest.Operation) -> UUID {
        let ticket = UUID()
        importTask?.cancel()
        isImporting = false
        loaderOptionsInspectionTask?.cancel()
        loaderOptionsInspectionGeneration &+= 1
        let generation = loaderOptionsInspectionGeneration
        let inspector = loaderOptionsInspector
        loaderOptionsRequest = nil
        binaryOpenState = .init(id: ticket, phase: .inspecting)

        loaderOptionsInspectionTask = Task { [weak self] in
            let model: LoaderOptionsModel
            do {
                model = try await inspector.inspectOffMain(url: url)
            } catch {
                guard let self, self.loaderOptionsInspectionGeneration == generation,
                      self.binaryOpenState?.id == ticket else { return }
                self.loaderOptionsInspectionTask = nil
                if Task.isCancelled {
                    self.binaryOpenState = .init(id: ticket, phase: .cancelled)
                } else {
                    self.lastIssue = error.localizedDescription
                    self.binaryOpenState = .init(id: ticket, phase: .failed(error.localizedDescription))
                }
                return
            }
            guard !Task.isCancelled, let self,
                  self.loaderOptionsInspectionGeneration == generation,
                  self.binaryOpenState?.id == ticket else { return }

            self.loaderOptionsInspectionTask = nil
            if model.requiresChoice {
                self.loaderOptionsRequest = LoaderOptionsRequest(
                    url: url,
                    model: model,
                    operation: operation
                )
                self.binaryOpenState = .init(id: ticket, phase: .choosing)
            } else {
                // Inspection is presentation evidence, never load authority. The loader/XPC path
                // deliberately reopens and revalidates exact bytes to close the selection TOCTOU.
                self.startLoad(
                    url: url,
                    selection: model.binaryLoadSelectionForLoad,
                    operation: operation
                )
            }
        }
        return ticket
    }

    /// Confirms the loader-options dialog: imports the file with the chosen slice and
    /// dismisses the sheet.
    func confirmLoaderOptions(_ request: LoaderOptionsRequest) {
        guard loaderOptionsRequest?.id == request.id,
              binaryOpenState?.phase == .choosing else { return }
        loaderOptionsInspectionGeneration &+= 1
        loaderOptionsInspectionTask?.cancel()
        loaderOptionsInspectionTask = nil
        loaderOptionsRequest = nil
        startLoad(
            url: request.url,
            selection: request.model.binaryLoadSelectionForLoad,
            operation: request.operation
        )
    }

    /// Cancels the loader-options dialog without importing.
    func cancelLoaderOptions() {
        loaderOptionsInspectionGeneration &+= 1
        loaderOptionsInspectionTask?.cancel()
        loaderOptionsInspectionTask = nil
        loaderOptionsRequest = nil
        if let id = binaryOpenState?.id, binaryOpenState?.phase == .choosing {
            binaryOpenState = .init(id: id, phase: .cancelled)
        }
    }

    /// Cancels only the acknowledged request; a timeout must never cancel a newer open.
    func cancelBinaryOpen(_ id: UUID) {
        guard let state = binaryOpenState, state.id == id, !state.phase.isTerminal else { return }
        loaderOptionsInspectionGeneration &+= 1
        loaderOptionsInspectionTask?.cancel()
        loaderOptionsInspectionTask = nil
        loaderOptionsRequest = nil
        importTask?.cancel()
        binaryOpenState = .init(id: id, phase: .cancelled)
    }

    /// Kicks the (cancellable) import off the main actor and retains its handle. A prior in-flight
    /// import is cancelled first so a second Open never leaves two analyses racing to set `snapshot`.
    private func startLoad(
        url: URL,
        selection: BinaryLoadSelection,
        operation: LoaderOptionsRequest.Operation
    ) {
        guard let ticket = binaryOpenState?.id else { return }
        binaryOpenState = .init(id: ticket, phase: .loading)
        importTask?.cancel()
        importTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.binaryOpenState?.id == ticket,
                  self.binaryOpenState?.phase == .loading else { return }
            switch operation {
            case .replaceWorkspace:
                await self.performImportBinary(url: url, selection: selection, ticket: ticket)
            case .addImage:
                await self.performAdditionalBinaryLoad(url: url, selection: selection, ticket: ticket)
            }
        }
    }

    /// Cancels and fences any supplemental cache request. Cancellation is cooperative, while the
    /// epoch and exact binary identity independently prevent a late result from publishing.
    private func supersedeDyldCacheDifferential(clearReport: Bool) {
        dyldCacheDifferentialEpoch &+= 1
        dyldCacheDifferentialCancellation?.cancel()
        dyldCacheDifferentialCancellation = nil
        dyldCacheDifferentialTask?.cancel()
        dyldCacheDifferentialTask = nil
        if clearReport {
            dyldCacheDifferentialReport = nil
        }
    }

    /// Starts the optional differential only after the primary import has installed authoritative
    /// bytes and analysis. The detached native-facts pass reads the exact source URL, reconstructs
    /// the selected artifact through MacScope's parser, and never consults the rendered image path.
    private func scheduleDyldCacheDifferential(
        sourceURL: URL,
        slot: ImageSlot,
        binary: BinaryImage
    ) {
        // Installing authoritative bytes retires every supplemental report owned by the prior
        // image, including when the replacement is not a dyld-cache projection and therefore
        // cannot start a new differential. Clear before eligibility checks so a successful
        // dyld -> ordinary-binary replacement can never leave the old report observable.
        supersedeDyldCacheDifferential(clearReport: true)
        guard let dyldCacheDifferentialWorkflow,
              binary.artifactIntegrityState == .verified,
              let artifactIdentity = binary.artifactIdentity else {
            return
        }

        let epoch = dyldCacheDifferentialEpoch
        let workspaceEpoch = reanalysisWorkspaceEpoch
        let workspaceID = workspaceID
        let binaryID = binary.id
        let cancellation = DyldCacheSupplementalCancellation()
        dyldCacheDifferentialCancellation = cancellation
        let builder = dyldCacheNativeFactsBuilder

        dyldCacheDifferentialTask = Task { @MainActor [weak self] in
            let native: DyldCacheNativeCatalogFacts
            do {
                native = try await Task.detached(priority: .utility) {
                    try builder.build(
                        sourceURL: sourceURL,
                        artifactIdentity: artifactIdentity,
                        cancellation: cancellation.token
                    )
                }.value
                try cancellation.token.check()
            } catch {
                guard let self, self.dyldCacheDifferentialEpoch == epoch else { return }
                self.dyldCacheDifferentialTask = nil
                self.dyldCacheDifferentialCancellation = nil
                return
            }

            let report = await dyldCacheDifferentialWorkflow.inspect(
                native: native,
                cancellation: cancellation.token
            )
            guard let self,
                  !cancellation.token.isCancelled,
                  self.dyldCacheDifferentialEpoch == epoch,
                  self.reanalysisWorkspaceEpoch == workspaceEpoch,
                  self.workspaceID == workspaceID,
                  let current = self.snapshot.binary(in: slot),
                  current.id == binaryID,
                  current.artifactIdentity == artifactIdentity else {
                return
            }
            self.dyldCacheDifferentialReport = report
            self.dyldCacheDifferentialTask = nil
            self.dyldCacheDifferentialCancellation = nil
        }
    }

    /// Cancels an in-flight initial import (the Cancel button / Esc on the "Indexing binary"
    /// panel). The engine unwinds at its next cooperative checkpoint; `importBinary` treats the
    /// resulting `AnalysisCancelled` as benign, so the window returns to its prior state with no
    /// error. A no-op when nothing is importing.
    func cancelImport() {
        guard isImporting else { return }
        importTask?.cancel()
    }

    /// Imports a binary into a fresh workspace. `requestedSliceIndex` carries the user's
    /// fat/universal slice pick from the open-time loader-options dialog (`nil` for a
    /// thin binary or to accept the default slice).
    func importBinary(url: URL, requestedSliceIndex: Int? = nil) async {
        await importBinary(url: url, selection: .machOSlice(requestedSliceIndex))
    }

    func importBinary(url: URL, selection: BinaryLoadSelection) async {
        await performImportBinary(url: url, selection: selection, ticket: nil)
    }

    /// HOP-3: a token that publishes each analysis phase of the running import.
    private func importProgressToken() -> AnalysisCancellationToken {
        .budgeted(progress: { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isImporting else { return }
                self.analysisProgress = progress
            }
        })
    }

    private func performImportBinary(url: URL, selection: BinaryLoadSelection, ticket: UUID?) async {
        var didInstallReplacement = false
        var outcome = WorkspaceBinaryOpenState.Phase.cancelled
        supersedeDyldCacheDifferential(clearReport: false)
        supersedeRehydration()
        isImporting = true
        analysisProgress = nil
        lastIssue = nil
        defer {
            if ticket == nil || binaryOpenState?.id == ticket { isImporting = false; analysisProgress = nil }
            if let ticket, binaryOpenState?.id == ticket, binaryOpenState?.phase == .loading {
                binaryOpenState = .init(id: ticket, phase: outcome)
            }
            if !didInstallReplacement {
                // Failure/cancellation preserves the old workspace. Reconstruct every still-
                // eligible old image regardless of whether a persisted selection is pending.
                rehydrateLoadedImages()
            }
        }

        do {
            // Import cancellation flows through the retained task's `Task.isCancelled`, which every
            // provider folds into this token; the token itself carries HOP-3 progress back here.
            var importedSnapshot = try await engine.openBinary(
                url: url, selection: selection, overrides: [:], cancellation: importProgressToken()
            )
            try Task.checkCancellation()
            if let ticket, binaryOpenState?.id != ticket || binaryOpenState?.phase != .loading {
                throw CancellationError()
            }
            if !importedSnapshot.binaries.isEmpty {
                importedSnapshot.binaries[0].originalPathBookmark = Self.originalPathBookmarkData(for: url)
            }
            logicalBreakpointCatalogAvailability = .available
            launchProfileCatalogAvailability = .available
            reconstructionState = .empty
            reconstructionLifecycle = .empty
            reaResultEvidence = try! REAResultEvidenceStore()
            selectedReconstructionJobID = nil
            reconstructionAttachmentSources = []
            didInstallReplacement = true
            workspaceName = url.deletingPathExtension().lastPathComponent
            persistedWorkspaceID = nil
            reconstructionPersistenceRetryPending = false
            documentMetadata = nil
            documentID = UUID()
            workspaceID = UUID()
            establishNativeDriveContext(origin: .freshImport)
            installSnapshotForIdentityRestore(importedSnapshot, preservingBinaryOpenTicket: ticket)
            // An imported binary is a NEW unsaved workspace — drop any previously-saved
            // package URL so autosave has no target to overwrite until the user saves.
            documentURL = nil
            selectedAddress = snapshot.instructions.first?.address
            syncGraphElementToSelectedAddress()
            resetNavigationHistory(seed: selectedAddress)
            selectedSidebarItemID = "binary:\(snapshot.binaries.first?.id.uuidString ?? "empty")"
            // A freshly imported binary has no edits to persist yet; treat it as a
            // clean baseline so the window isn't immediately flagged "edited".
            resetDirtyStateToClean()
            finishNativeDriveInstallation()
            navigatorAnalysisDidLand(in: snapshot.primarySlot, previousFingerprint: nil)
            if let binary = snapshot.binary(in: snapshot.primarySlot) {
                outcome = .completed(binary.id)
                scheduleDyldCacheDifferential(
                    sourceURL: url,
                    slot: snapshot.primarySlot,
                    binary: binary
                )
            } else {
                outcome = .failed("No binary was installed.")
            }
        } catch is AnalysisCancelled {
            // The user cancelled the import (or the window closed). Benign: leave the workspace as
            // it was — an empty first import stays on the empty state, no error banner.
        } catch is CancellationError {
            // An uncooperative provider returned after this exact import was cancelled.
        } catch {
            if !Task.isCancelled {
                lastIssue = error.localizedDescription
                outcome = .failed(error.localizedDescription)
            }
        }
    }

    /// The next durable slot for a newly loaded image: `max(existing slots) + 1`, so it is unique
    /// even across a noncontiguous set (e.g. slots 0 and 7 after a package collision-remap → 8).
    /// Authoritative over the persisted `next_image_slot` hint, which can lag a remapped workspace.
    func nextImageSlot() -> ImageSlot {
        let maxRaw = snapshot.binaries.map(\.slot.rawValue).max() ?? -1
        return ImageSlot(rawValue: maxRaw + 1)
    }

    /// Loads an ADDITIONAL binary into the current workspace as a new image, preserving every
    /// existing image + all authoring, then focuses the new image. A no-op when no binary is open
    /// yet (that is a normal `importBinary`). The engine is image-local: it analyzes the file as its
    /// own `.primary`, and we re-stamp that result into a freshly allocated slot before inserting.
    func loadAdditionalBinary(url: URL, requestedSliceIndex: Int? = nil) async {
        await loadAdditionalBinary(url: url, selection: .machOSlice(requestedSliceIndex))
    }

    func loadAdditionalBinary(url: URL, selection: BinaryLoadSelection) async {
        await performAdditionalBinaryLoad(url: url, selection: selection, ticket: nil)
    }

    private func performAdditionalBinaryLoad(url: URL, selection: BinaryLoadSelection, ticket: UUID?) async {
        guard !snapshot.binaries.isEmpty else {
            return await performImportBinary(url: url, selection: selection, ticket: ticket)
        }
        var outcome = WorkspaceBinaryOpenState.Phase.cancelled
        supersedeRehydration()
        isImporting = true
        lastIssue = nil
        defer {
            if ticket == nil || binaryOpenState?.id == ticket { isImporting = false }
            if let ticket, binaryOpenState?.id == ticket, binaryOpenState?.phase == .loading {
                binaryOpenState = .init(id: ticket, phase: outcome)
            }
            // Existing images remain installed on every outcome, including a successful add.
            // Candidate filtering excludes the fully analyzed new image and restarts any omitted
            // derived products from the current post-operation snapshot.
            rehydrateLoadedImages()
        }

        do {
            let fresh = try await engine.openBinary(
                url: url, selection: selection, overrides: [:], cancellation: .never
            )
            try Task.checkCancellation()
            if let ticket, binaryOpenState?.id != ticket || binaryOpenState?.phase != .loading {
                throw CancellationError()
            }
            let engineSlot = fresh.primarySlot
            guard var freshBinary = fresh.binaries.first,
                  var freshAnalysis = fresh.analysis(in: engineSlot) else {
                lastIssue = "The selected file did not analyze to a loadable image."
                outcome = .failed(lastIssue ?? "No binary was installed.")
                return
            }
            let newSlot = nextImageSlot()
            freshBinary.slot = newSlot
            freshBinary.originalPathBookmark = Self.originalPathBookmarkData(for: url)
            // HOP-4: engine ids derive from `.primary`; re-derive them for the landing slot.
            AnalysisStableIdentity.restamp(&freshAnalysis, to: freshBinary.slot)
            Self.restampAnalysisInputFingerprint(&freshAnalysis, using: freshBinary)
            snapshot.insertImage(binary: freshBinary, analysis: freshAnalysis)
            markDocumentMutated()
            recomputeCrossImageXrefs()
            navigatorAnalysisDidLand(in: newSlot, previousFingerprint: nil)
            focusImage(newSlot)
            selectedSidebarItemID = "binary:\(freshBinary.id.uuidString)"
            selectedAddress = freshAnalysis.instructions.first?.address
            syncGraphElementToSelectedAddress()
            if let address = selectedAddress, let location = navigationLocation(at: address) {
                navigationHistory.record(location)
            }
            reconcileNativeDecompilerDrive(reason: .selectionOrFocusChanged)
            scheduleDyldCacheDifferential(
                sourceURL: url,
                slot: newSlot,
                binary: freshBinary
            )
            outcome = .completed(freshBinary.id)
        } catch is AnalysisCancelled {
            // Benign: the user cancelled or the window closed — leave the workspace unchanged.
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                lastIssue = error.localizedDescription
                outcome = .failed(error.localizedDescription)
            }
        }
    }

    /// Explicit recovery for a persisted image whose selected-slice attachment contradicts its
    /// durable size/hash evidence. The current snapshot is left untouched until the replacement
    /// file has completed fresh analysis and produced verified Mach-O artifact evidence.
    @discardableResult
    func reimportBinary(
        in slot: ImageSlot,
        from url: URL,
        requestedSliceIndex: Int? = nil
    ) async -> Bool {
        guard let currentBinary = snapshot.binary(in: slot) else { return false }
        let ownerID = currentBinary.id
        let workspaceEpoch = reanalysisWorkspaceEpoch
        let slotEpoch = reanalysisEpochsBySlot[slot, default: 0]

        supersedeRehydration()
        isImporting = true
        lastIssue = nil
        defer {
            isImporting = false
            rehydrateLoadedImages()
        }

        do {
            let fresh = try await engine.openBinary(
                url: url,
                requestedSliceIndex: requestedSliceIndex,
                overrides: [:],
                cancellation: .never
            )
            let engineSlot = fresh.primarySlot
            guard var freshBinary = fresh.binaries.first,
                  var freshAnalysis = fresh.analysis(in: engineSlot),
                  freshBinary.artifactIntegrityState == .verified,
                  freshBinary.artifactIdentity != nil,
                  freshBinary.preferredSegmentLayout != nil else {
                lastIssue = "The selected file did not produce verified Mach-O artifact evidence."
                return false
            }

            // The await above permits document replacement and same-slot analysis mutations.
            // Fence the landing against both the exact durable owner and the captured generation;
            // a stale recovery must never resurrect its old owner into a newer workspace.
            guard reanalysisWorkspaceEpoch == workspaceEpoch,
                  (reanalysisEpochsBySlot[slot] ?? 0) == slotEpoch,
                  snapshot.binary(in: slot)?.id == ownerID else {
                return false
            }

            // Only now mutate the live image. The durable workspace owner/slot and all
            // workspace-global authoring remain stable while derived analysis and exact bytes are
            // replaced atomically in memory from the freshly verified import.
            supersedeReanalysis(in: slot)
            freshBinary = BinaryImage(
                id: ownerID,
                name: freshBinary.name,
                path: freshBinary.path,
                kind: freshBinary.kind,
                architecture: freshBinary.architecture,
                originalPathBookmark: Self.originalPathBookmarkData(for: url),
                metadata: freshBinary.metadata,
                selectedSliceIndex: freshBinary.selectedSliceIndex,
                machOSelectedSliceFact: freshBinary.machOSelectedSliceFact,
                artifactIdentity: freshBinary.artifactIdentity,
                preferredSegmentLayout: freshBinary.preferredSegmentLayout,
                artifactIntegrityState: .verified,
                containerAdmissionWitness: freshBinary.containerAdmissionWitness,
                resolvedExecutablePath: freshBinary.resolvedExecutablePath,
                slot: slot
            )
            guard let binaryIndex = snapshot.binaries.firstIndex(where: { $0.slot == slot }) else {
                return false
            }
            snapshot.binaries[binaryIndex] = freshBinary
            // HOP-4: engine ids derive from `.primary`; re-derive them for the landing slot.
            AnalysisStableIdentity.restamp(&freshAnalysis, to: freshBinary.slot)
            Self.restampAnalysisInputFingerprint(&freshAnalysis, using: freshBinary)
            let previousNavigatorFingerprint = snapshot.analysis(in: slot)?.analysisInputFingerprint
            snapshot.replaceAnalysis(freshAnalysis, in: slot)
            reanalysisLandingEpochsBySlot[slot, default: 0] &+= 1
            markDocumentMutated()
            recomputeCrossImageXrefs()

            if focusedImageSlot == slot {
                selectedAddress = freshAnalysis.instructions.first?.address
                syncGraphElementToSelectedAddress()
                pruneNavigationHistory()
                if let address = selectedAddress, let location = navigationLocation(at: address) {
                    navigationHistory.record(location)
                }
                selectedSidebarItemID = "binary:\(freshBinary.id.uuidString)"
            }
            reconcileNativeDecompilerDrive(reason: .acceptedStructuralAnalysis)
            navigatorAnalysisDidLand(in: slot, previousFingerprint: previousNavigatorFingerprint)
            return true
        } catch is AnalysisCancelled {
            return false
        } catch {
            lastIssue = error.localizedDescription
            return false
        }
    }

    /// Selects one exact image-owned address. Delayed and rendered callbacks use this entry point so
    /// an address captured in image A cannot be rebound after image B receives focus.
    @discardableResult
    func selectAddress(_ target: ImageAddress) -> Bool {
        // A rendered navigation attempt is new user intent even when the target is rejected.
        pendingRehydratedSelection = nil
        guard target.slot == focusedImageSlot,
              snapshot.containsLoadedAddress(target.address, in: target.slot) else {
            return false
        }

        clearXRefCursorIfUnrelated(to: target.address)
        selectedImageAddress = target
        syncGraphElementToSelectedAddress()
        // Every jump (Go-To, follow-reference, function/string/xref navigation) flows
        // through here; record it unless we're replaying Back/Forward.
        if !suppressHistoryRecording {
            if let location = navigationLocation(at: target.address) { navigationHistory.record(location) }
        }
        reconcileNativeDecompilerDrive(reason: .selectionOrFocusChanged)
        return true
    }

    /// An XREF step cursor is meaningful only while selection stays on its anchor/referrer orbit.
    /// Canonical direct assignment and adjacent stepping both pass through this check so an
    /// unrelated click or arrow move cannot leave Next/Previous XREF bound to an old address.
    private func clearXRefCursorIfUnrelated(to address: UInt64) {
        guard let cursor = xrefCursor, cursor.covers(address) else {
            xrefCursor = nil
            return
        }
    }

    /// Focused-image compatibility wrapper retained for synchronous bare-address callers. Despite
    /// its historical name, mapped data/reference locations remain valid selections.
    func selectInstruction(_ address: UInt64) {
        _ = selectAddress(ImageAddress(slot: focusedImageSlot, address: address))
    }

    func selectAdjacentInstruction(_ direction: InstructionNavigationDirection) {
        let instructions = focusedAnalysis?.instructions ?? []
        guard !instructions.isEmpty else {
            selectedAddress = nil
            selectedGraphElementID = nil
            return
        }

        let currentIndex = selectedAddress.flatMap { address in
            instructions.firstIndex { $0.address == address }
        }
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex.map { max($0 - 1, 0) } ?? 0
        case .next:
            nextIndex = currentIndex.map { min($0 + 1, instructions.count - 1) } ?? 0
        }

        // Arrow-key stepping is local movement, not a jump. Route through the same qualified
        // selection seam as direct callbacks so graph identity and unrelated XREF state clear,
        // while suppressing a history entry for each adjacent row.
        suppressHistoryRecording = true
        _ = selectAddress(ImageAddress(
            slot: focusedImageSlot,
            address: instructions[nextIndex].address
        ))
        suppressHistoryRecording = false
    }

    /// Selects a node captured from the production graph model only while that exact slot-owned
    /// identity is still present in the focused projection. Reanalysis-reminted IDs and delayed
    /// callbacks from another focus are guarded no-ops even when their bare addresses collide.
    @discardableResult
    func selectGraphNode(_ target: GraphSelectionTarget) -> Bool {
        guard target.imageSlot == focusedImageSlot,
              snapshot.binary(in: target.imageSlot)?.id == target.ownerBinaryID,
              let current = currentGraphNodeTarget(matching: target) else {
            return false
        }

        let projection = focusedGraphProjection
        let address = selectionAddress(for: current, in: projection)
        guard selectAddress(ImageAddress(slot: current.imageSlot, address: address)) else {
            return false
        }

        clearGraphNodeMultiSelection()
        selectedGraphElementID = current.id
        if current.imageSlot == snapshot.primarySlot {
            syncSidebarSelection(functionID: current.functionID)
        }
        return true
    }

    /// Synchronous focused-image compatibility wrapper. Rendered SwiftUI callbacks use the
    /// slot-qualified target overload above; this overload remains for legacy primary consumers.
    func selectGraphNode(id: String, address: UInt64, functionID: UUID?) {
        guard selectAddress(ImageAddress(slot: focusedImageSlot, address: address)) else { return }
        clearGraphNodeMultiSelection()
        selectedGraphElementID = id
        if focusedImageSlot == snapshot.primarySlot {
            syncSidebarSelection(functionID: functionID)
        }
    }

    /// Accepts an edge only if the current focused projection would still render the same
    /// slot-qualified element ID, endpoints, and kind.
    @discardableResult
    func selectGraphEdge(_ target: GraphEdgeSelectionTarget) -> Bool {
        guard target.imageSlot == focusedImageSlot,
              snapshot.binary(in: target.imageSlot)?.id == target.ownerBinaryID,
              let current = currentGraphEdgeSelectionTargets.first(where: { $0 == target }) else {
            return false
        }

        let projection = focusedGraphProjection
        let address = projection.instructions.first { $0.address == current.fromAddress }?.address
            ?? current.fromAddress
        guard selectAddress(ImageAddress(slot: current.imageSlot, address: address)) else {
            return false
        }

        clearGraphNodeMultiSelection()
        selectedGraphElementID = current.id
        guard current.imageSlot == snapshot.primarySlot else { return true }

        if selectedTool == .xrefs,
           let xref = xref(for: current, in: projection) {
            selectedSidebarItemID = "xref:\(xref.id.uuidString)"
            return true
        }

        let sourceNode = graphTarget(
            for: ImageAddress(slot: current.imageSlot, address: current.fromAddress),
            in: graphNodeSelectionTargets(in: projection)
        )
        syncSidebarSelection(functionID: sourceNode?.functionID)
        return true
    }

    /// Synchronous focused compatibility wrapper retained for non-rendered callers. SwiftUI must
    /// pass the complete `GraphEdgeSelectionTarget` instead.
    func selectGraphEdge(id: String, from fromAddress: UInt64, to toAddress: UInt64, kind: String) {
        let targetAddress = focusedGraphProjection.instructions.first { $0.address == fromAddress }?.address
            ?? fromAddress
        guard selectAddress(ImageAddress(slot: focusedImageSlot, address: targetAddress)) else { return }
        clearGraphNodeMultiSelection()
        selectedGraphElementID = id
        guard focusedImageSlot == snapshot.primarySlot else { return }

        if selectedTool == .xrefs,
           let xref = xref(
                forGraphElementID: id,
                from: fromAddress,
                to: toAddress,
                kind: kind,
                in: focusedGraphProjection
           ) {
            selectedSidebarItemID = "xref:\(xref.id.uuidString)"
            return
        }

        let sourceNode = graphTarget(
            for: ImageAddress(slot: focusedImageSlot, address: fromAddress),
            in: graphNodeSelectionTargets
        )
        syncSidebarSelection(functionID: sourceNode?.functionID)
    }

    func selectAdjacentGraphNode(_ direction: GraphNavigationDirection) {
        let targets = graphNodeSelectionTargets
        guard !targets.isEmpty else {
            selectedAddress = nil
            selectedGraphElementID = nil
            return
        }

        let currentIndex = currentGraphTargetIndex(in: targets)
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex.map { ($0 - 1 + targets.count) % targets.count } ?? targets.count - 1
        case .next:
            nextIndex = currentIndex.map { ($0 + 1) % targets.count } ?? 0
        }

        // Arrow-stepping between adjacent graph nodes is local movement, not a jump.
        suppressHistoryRecording = true
        selectGraphNode(targets[nextIndex])
        suppressHistoryRecording = false
    }

    /// Captures the exact binary owner of a rendered sidebar row. Binary rows own themselves;
    /// compatibility function/symbol/string/xref rows are owned by the primary image projection.
    func sidebarNavigationTarget(for itemID: SidebarItem.ID) -> SidebarNavigationTarget? {
        if Self.reconstructionJobID(fromSidebarItemID: itemID) != nil {
            return SidebarNavigationTarget(
                itemID: itemID,
                imageSlot: snapshot.primarySlot,
                ownerBinaryID: nil
            )
        }
        if itemID.hasPrefix("binary:") {
            let rawID = itemID.components(separatedBy: ":").dropFirst().joined(separator: ":")
            guard let id = UUID(uuidString: rawID),
                  let binary = snapshot.binaries.first(where: { $0.id == id }) else { return nil }
            return SidebarNavigationTarget(
                itemID: itemID,
                imageSlot: binary.slot,
                ownerBinaryID: binary.id
            )
        }
        let slot = snapshot.primarySlot
        return SidebarNavigationTarget(
            itemID: itemID,
            imageSlot: slot,
            ownerBinaryID: snapshot.binary(in: slot)?.id
        )
    }

    /// Synchronous compatibility wrapper derives the current owner immediately. Rendered callbacks
    /// retain and deliver the immutable overload below instead.
    func activateSidebarItem(_ itemID: SidebarItem.ID) {
        guard let target = sidebarNavigationTarget(for: itemID) else {
            selectedSidebarItemID = itemID
            return
        }
        _ = activateSidebarItem(target)
    }

    /// Requests keyboard focus for one already-selected sidebar row. This is intentionally an
    /// explicit seam rather than deriving focus from every selection mutation: user clicks, list
    /// navigation, restore, and background reconciliation must retain their ordinary focus owner.
    func requestSidebarKeyboardFocus(for itemID: SidebarItem.ID) {
        guard selectedSidebarItemID == itemID else { return }
        sidebarKeyboardFocusRequestID = itemID
    }

    /// The matching row consumes its one-shot request after assigning its local `@FocusState`.
    /// A stale or different row cannot clear another row's pending transfer.
    func acknowledgeSidebarKeyboardFocusRequest(for itemID: SidebarItem.ID) {
        guard sidebarKeyboardFocusRequestID == itemID else { return }
        sidebarKeyboardFocusRequestID = nil
    }

    @discardableResult
    func activateSidebarItem(_ target: SidebarNavigationTarget) -> Bool {
        let itemID = target.itemID
        if let jobID = Self.reconstructionJobID(fromSidebarItemID: itemID) {
            guard reconstructionState.jobs.contains(where: { $0.jobID == jobID }) else {
                return false
            }
            selectedReconstructionJobID = jobID
            selectedSidebarItemID = itemID
            return true
        }
        if itemID.hasPrefix("binary:") {
            let rawID = itemID.components(separatedBy: ":").dropFirst().joined(separator: ":")
            guard let rowID = UUID(uuidString: rawID),
                  let ownerBinaryID = target.ownerBinaryID,
                  rowID == ownerBinaryID,
                  snapshot.binary(in: target.imageSlot)?.id == ownerBinaryID else {
                return false
            }
            selectedSidebarItemID = itemID
            focusImage(target.imageSlot)
            return true
        }

        // Non-address utility rows remain selectable without a loaded image.
        if itemID.hasPrefix("debug:") || itemID.hasPrefix("extensions:") {
            selectedSidebarItemID = itemID
            return true
        }

        guard target.imageSlot == snapshot.primarySlot,
              isCurrentRequestOwner(target.imageSlot, ownerBinaryID: target.ownerBinaryID),
              let analysis = snapshot.analysis(in: target.imageSlot) else {
            return false
        }

        if TypeAtlasNavigator.isEntryItem(itemID) {
            // Selecting a type drives the inspector only; the editor stays where it is.
            guard TypeAtlasNavigator.entry(forItemID: itemID, in: snapshot.typeCatalog(in: target.imageSlot)) != nil else {
                return false
            }
            selectedSidebarItemID = itemID
            return true
        }

        if itemID.hasPrefix("import:") {
            // ImportSummary records carry no address, so the editor stays put.
            let rawID = itemID.components(separatedBy: ":").dropFirst().joined(separator: ":")
            guard let id = UUID(uuidString: rawID), analysis.imports.contains(where: { $0.id == id }) else {
                return false
            }
            selectedSidebarItemID = itemID
            return true
        }

        let rawID = itemID.components(separatedBy: ":").dropFirst().joined(separator: ":")
        guard let id = UUID(uuidString: rawID) else {
            selectedSidebarItemID = itemID
            return true
        }

        if itemID.hasPrefix("export:"),
           let export = analysis.exports.first(where: { $0.id == id }) {
            let didNavigate = navigateToSidebarAddress(
                export.address,
                in: target.imageSlot,
                requiresInstruction: true
            )
            if didNavigate { selectedSidebarItemID = itemID }
            return didNavigate
        }

        if itemID.hasPrefix("function:") || itemID.hasPrefix("symbol:") {
            if let symbol = analysis.symbols.first(where: { $0.id == id }) {
                let didNavigate = navigateToSidebarAddress(
                    symbol.address,
                    in: target.imageSlot,
                    requiresInstruction: true
                )
                if didNavigate { selectedSidebarItemID = itemID }
                return didNavigate
            }
            guard let function = analysis.functions.first(where: { $0.id == id }) else { return false }
            let didNavigate = navigateToSidebarAddress(
                function.startAddress,
                in: target.imageSlot,
                requiresInstruction: true
            )
            if didNavigate { selectedSidebarItemID = itemID }
            return didNavigate
        }

        if itemID.hasPrefix("string:"),
           let literal = analysis.stringLiterals.first(where: { $0.id == id }) {
            let didNavigate = navigateToSidebarAddress(
                literal.address,
                in: target.imageSlot,
                requiresInstruction: false
            )
            if didNavigate { selectedSidebarItemID = itemID }
            return didNavigate
        }

        if itemID.hasPrefix("xref:"),
           let xref = analysis.xrefs.first(where: { $0.id == id }) {
            let didNavigate = navigateToSidebarAddress(
                xref.from,
                in: target.imageSlot,
                requiresInstruction: false
            )
            if didNavigate { selectedSidebarItemID = itemID }
            return didNavigate
        }
        return false
    }

    @discardableResult
    private func navigateToSidebarAddress(
        _ address: UInt64?,
        in slot: ImageSlot,
        requiresInstruction: Bool
    ) -> Bool {
        guard let address,
              snapshot.containsLoadedAddress(address, in: slot),
              !requiresInstruction || snapshot.analysis(in: slot)?.instructions.contains(where: {
                  $0.address == address
              }) == true else {
            return false
        }
        if slot != focusedImageSlot {
            focusImage(slot)
        }
        guard selectAddress(ImageAddress(slot: slot, address: address)) else { return false }
        let isInstruction = snapshot.analysis(in: slot)?.instructions.contains {
            $0.address == address
        } ?? false
        editorMode = isInstruction ? .disassembly : .hex
        return true
    }

    func selectDefaultSidebarItemIfNeeded() {
        if selectedTool == .reconstruction {
            let selectedJob = selectedReconstructionJobID.flatMap { selectedID in
                reconstructionState.jobs.first { $0.jobID == selectedID }
            } ?? reconstructionState.jobs.compactMap { job in
                job.creationOrdinal.map { (ordinal: $0, job: job) }
            }.max { lhs, rhs in
                lhs.ordinal < rhs.ordinal
            }?.job
            selectedReconstructionJobID = selectedJob?.jobID
            let itemID = selectedJob.map { Self.reconstructionSidebarItemID($0.jobID) }
            selectedSidebarItemID = itemID.flatMap { candidate in
                visibleSidebarItems.contains {
                    $0.id == candidate && !$0.isSectionHeader
                } ? candidate : nil
            }
            return
        }
        guard let selectedSidebarItemID,
              visibleSidebarItems.contains(where: { $0.id == selectedSidebarItemID && !$0.isSectionHeader }) else {
            selectedSidebarItemID = selectableVisibleSidebarItems.first?.id
            return
        }
    }

    static func reconstructionSidebarItemID(_ jobID: UUID) -> SidebarItem.ID {
        "reconstruction:job:\(jobID.uuidString)"
    }

    static func reconstructionJobID(
        fromSidebarItemID itemID: SidebarItem.ID
    ) -> UUID? {
        let prefix = "reconstruction:job:"
        guard itemID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(itemID.dropFirst(prefix.count)))
    }

    private func restoreReconstructionSelectionFromSidebar() {
        guard selectedTool == .reconstruction,
              let selectedSidebarItemID,
              let jobID = Self.reconstructionJobID(
                fromSidebarItemID: selectedSidebarItemID
              ),
              reconstructionState.jobs.contains(where: { $0.jobID == jobID }) else {
            selectedReconstructionJobID = nil
            return
        }
        selectedReconstructionJobID = jobID
    }

    func selectAdjacentSidebarItem(_ direction: SidebarNavigationDirection) {
        let items = selectableVisibleSidebarItems
        guard !items.isEmpty else {
            selectedSidebarItemID = nil
            return
        }

        let currentIndex = selectedSidebarItemID.flatMap { selectedID in
            items.firstIndex { $0.id == selectedID }
        }
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex.map { ($0 - 1 + items.count) % items.count } ?? items.count - 1
        case .next:
            nextIndex = currentIndex.map { ($0 + 1) % items.count } ?? 0
        }

        activateSidebarItem(items[nextIndex].id)
    }

    func toggleBreakpoint(_ address: UInt64) {
        toggleBreakpoint(ImageAddress(slot: focusedImageSlot, address: address))
    }

    /// Exact-slot breakpoint mutation. The captured key is retained by Undo/Redo, so later focus
    /// changes cannot redirect a colliding address into another image.
    func toggleBreakpoint(_ target: ImageAddress) {
        guard isCurrentImageOwner(target.slot, binaryID: nil),
              let binary = snapshot.binary(in: target.slot) else { return }
        let existing = logicalBreakpointSpecifications(at: target)
        guard !existing.isEmpty || snapshot.isExecutableInstructionAddress(target) else { return }
        guard existing.count <= 1 else {
            // A gutter location can represent several separately authored logical breakpoints.
            // The presentation contract makes that a Manage action, never a destructive batch
            // delete whose repeated revision bumps obscure which authored intent was removed.
            selectedTool = .debug
            activateSidebarItem("debug:breakpoints")
            return
        }
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        defer { if needsExplicitGroup { manager.endUndoGrouping() } }
        do {
            if existing.isEmpty {
                _ = try createLogicalBreakpoint(
                    target: .preferredAddress(
                        owner: DebuggerWorkspaceImageOwnerSeal(
                            slot: target.slot,
                            binaryID: binary.id,
                            artifactIdentity: binary.artifactIdentity
                        ),
                        preferredVA: target.address
                    )
                )
            } else {
                for specification in existing {
                    _ = try deleteLogicalBreakpoint(specification.id)
                }
            }
        } catch {
            lastIssue = error.localizedDescription
        }
    }

    func canToggleBreakpoint(_ target: ImageAddress) -> Bool {
        guard isCurrentImageOwner(target.slot, binaryID: nil),
              snapshot.binary(in: target.slot) != nil else { return false }
        let existing = logicalBreakpointSpecifications(at: target)
        return !existing.isEmpty || snapshot.isExecutableInstructionAddress(target)
    }

    /// Complete document-wide debugger evidence. Unlike a launch proposal, this authority never
    /// follows editor focus and remains present when an arbitrary-process attach has no candidate.
    var debuggerWorkspaceAuthority: DebuggerWorkspaceAuthority? {
        let logicalCatalog = logicalBreakpointCatalogAvailability == .available
            ? snapshot.logicalBreakpointCatalog
            : .freshPristine(catalogID: snapshot.logicalBreakpointCatalog.catalogID)
        let logicalCoordinate = try! DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: logicalCatalog.catalogID,
            revision: logicalCatalog.revision
        )
        let authority = DebuggerWorkspaceAuthority(
            workspaceID: workspaceID,
            artifactCatalog: debuggerWorkspaceArtifactCatalog,
            logicalBreakpointCatalogAvailability: logicalBreakpointCatalogAvailability,
            logicalBreakpointCatalog: logicalCatalog,
            logicalBreakpointCatalogCoordinate: logicalCoordinate,
            breakpointResolutionCatalog: debuggerBreakpointResolutionCatalog,
            breakpointResolutionCatalogCoordinate: debuggerBreakpointResolutionCatalog.coordinate
        )
        return authority.isStructurallyValid ? authority : nil
    }

    /// The exact-slot next-launch proposal. A loaded image without analysis is valid with an empty
    /// gutter; an absent slot yields nil without weakening the document-wide authority above.
    func debuggerFocusedLaunchCandidate(in slot: ImageSlot) -> DebuggerFocusedLaunchCandidate? {
        guard let binary = snapshot.binary(in: slot) else { return nil }
        return DebuggerFocusedLaunchCandidate(
            imageSlot: slot,
            launchTarget: .importedWorkspaceBinary(binary),
            gutterBreakpointAddresses: enabledLogicalBreakpointPreferredAddresses(in: slot),
            breakpointRevision: logicalBreakpointCatalogAvailability == .available
                ? snapshot.logicalBreakpointCatalog.revision : 0
        )
    }

    /// The focused image is only the next-launch candidate; sidebar entity selection cannot retarget it.
    var debuggerFocusedLaunchCandidate: DebuggerFocusedLaunchCandidate? {
        debuggerFocusedLaunchCandidate(in: focusedImageSlot)
    }

    /// Deprecated compatibility aggregate for the existing active-session convergence machinery.
    func debuggerWorkspaceInput(in slot: ImageSlot) -> DebuggerWorkspaceInput? {
        guard let authority = debuggerWorkspaceAuthority,
              let candidate = debuggerFocusedLaunchCandidate(in: slot) else { return nil }
        return DebuggerWorkspaceInput(authority: authority, candidate: candidate)
    }

    var debuggerWorkspaceInput: DebuggerWorkspaceInput? {
        debuggerWorkspaceInput(in: focusedImageSlot)
    }

    /// Compatibility projections remain focused, but derive from the same atomic aggregate.
    var debuggerLaunchTargetDescriptor: DebuggerLaunchTargetDescriptor? {
        debuggerFocusedLaunchCandidate?.launchTarget
    }

    var gutterBreakpointAddresses: [UInt64] {
        debuggerFocusedLaunchCandidate?.gutterBreakpointAddresses ?? []
    }

    func toggleBreakpointAtSelection() {
        guard let selection = selectedImageAddress,
              canToggleBreakpoint(selection) else { return }
        toggleBreakpoint(selection)
    }

    /// Focus-qualified bare projection retained for existing listing and test consumers.
    var liveProgramCounter: UInt64? {
        guard let target = liveProgramCounterTarget,
              target.slot == focusedImageSlot,
              snapshot.analysis(in: target.slot)?.instructions.contains(where: {
                  $0.address == target.address
              }) == true else { return nil }
        return target.address
    }

    /// Installs a PC only when its exact owner still exists and contains that decoded instruction.
    func updateLiveProgramCounterTarget(_ target: ImageAddress?) {
        let validated = target.flatMap { candidate -> ImageAddress? in
            guard isCurrentImageOwner(candidate.slot, binaryID: nil),
                  snapshot.analysis(in: candidate.slot)?.instructions.contains(where: {
                      $0.address == candidate.address
                  }) == true else { return nil }
            return candidate
        }
        guard liveProgramCounterTarget != validated else { return }
        liveProgramCounterTarget = validated
    }

    /// Single-image compatibility wrapper. A bare PC has only the legacy primary owner; callers
    /// with a live multi-image session must use the qualified overload above.
    func updateLiveProgramCounter(_ programCounter: UInt64?) {
        updateLiveProgramCounterTarget(programCounter.map {
            ImageAddress(slot: snapshot.primarySlot, address: $0)
        })
    }

    // MARK: - Focused image (Phase 4)

    /// Clears the authoritative coordinate and every graph identity that could otherwise be
    /// interpreted against a different image. Navigation-history invalidation is owned by the
    /// lifecycle operation because a rejected direct assignment must not erase valid Back history.
    private func clearInteractiveSelection() {
        if selectedImageAddress != nil {
            selectedImageAddress = nil
        }
        clearGraphInteraction()
    }

    /// Clears every store-owned graph transient. It intentionally leaves the qualified editor
    /// address alone so Reset Graph Layout does not move the user's listing/hex selection.
    private func clearGraphInteraction() {
        if selectedGraphElementID != nil {
            selectedGraphElementID = nil
        }
        clearGraphNodeMultiSelection()
    }

    func clearGraphNodeMultiSelection() {
        guard !graphNodeMultiSelection.isEmpty else { return }
        graphNodeMultiSelection.removeAll()
    }

    /// View-command entry point for the deterministic graph reset. Geometry is derived, so the
    /// only stale state to invalidate is selection/group identity.
    func resetGraphLayoutSelection() {
        clearGraphInteraction()
    }

    /// Revalidates interactive identity after any direct snapshot replacement or mutation. This is
    /// intentionally read-only with respect to `snapshot`, preventing recursive publication from
    /// its `didSet` observer. A removed focus clamps once to the live primary image; a selection is
    /// retained only when its original slot still owns the exact loaded address.
    private func revalidateInteractiveSelectionAfterSnapshotChange() {
        pruneNavigationHistory()
        // Cursors capture derived results, not the current binary owner or analysis revision.
        // Retire them on any snapshot change, including same-slot owner reuse and XRef edits.
        searchCursor = nil
        xrefCursor = nil
        invalidateAuthoringPresentationsWithDisplacedOwners()
        if let pending = pendingRehydratedSelection,
           focusedImageSlotStorage != pending.slot
            || snapshot.binary(in: pending.slot)?.id != pending.binaryID {
            // The restore-time intent belongs to one immutable binary owner and one focus domain.
            // Removing/replacing that owner or moving focus permanently retires the token; later
            // same-slot reinsertion must never resurrect it.
            pendingRehydratedSelection = nil
        }
        reconcileDebuggerBreakpointRevisionsAfterSnapshotChange()
        // Snapshot replacement and in-place structural splices may re-mint function, block, CFG,
        // or xref identities. Invalidate callbacks/groups before address validation even when a
        // colliding coordinate remains mapped. Display-only mutations are safe but conservatively
        // clear the transient graph interaction as well; persisted authoring is unaffected.
        clearGraphInteraction()

        var focusWasClamped = false
        if !interactiveFocusOwnerExists(focusedImageSlotStorage) {
            let fallback = snapshot.primarySlot
            if focusedImageSlotStorage != fallback {
                focusedImageSlotStorage = fallback
            }
            focusWasClamped = true
            clearGraphInteraction()
        }

        guard let selection = selectedImageAddress else {
            if focusWasClamped {
                xrefCursor = nil
                selectedGraphElementID = nil
            }
            return
        }

        guard selection.slot == focusedImageSlotStorage,
              isCurrentImageOwner(selection.slot, binaryID: nil),
              snapshot.containsLoadedAddress(selection.address, in: selection.slot) else {
            xrefCursor = nil
            clearInteractiveSelection()
            return
        }
    }

    /// A visible focus is owned by a loaded binary even while its analysis is temporarily absent.
    /// The binary-less primary analysis bucket is the long-standing deterministic/headless fixture
    /// exception; treating that one form as an owner keeps snapshot revalidation coherent with the
    /// selection, command, and delayed-authoring compatibility seams without weakening real-image
    /// identity checks.
    private func interactiveFocusOwnerExists(_ slot: ImageSlot) -> Bool {
        if snapshot.binary(in: slot) != nil { return true }
        return snapshot.binaries.isEmpty
            && slot == snapshot.primarySlot
            && snapshot.analysis(in: slot) != nil
    }

    private static func debuggerBreakpointSets(
        in snapshot: WorkspaceSnapshot,
        availability: DebuggerLogicalBreakpointCatalogAvailability
    ) -> [ImageSlot: Set<UInt64>] {
        Dictionary(uniqueKeysWithValues: snapshot.binaries.map { binary in
            let specifications = availability == .available
                ? snapshot.logicalBreakpointCatalog.specifications : []
            let addresses = specifications.compactMap {
                specification -> UInt64? in
                guard specification.enabled,
                      case .preferredAddress(let owner, let preferredVA) = specification.target,
                      owner.slot == binary.slot,
                      owner.binaryID == binary.id,
                      owner.artifactIdentity == nil
                        || owner.artifactIdentity == binary.artifactIdentity else {
                    return nil
                }
                return preferredVA
            }
            return (binary.slot, Set(addresses))
        })
    }

    private static func debuggerBinaryIDs(in snapshot: WorkspaceSnapshot) -> [ImageSlot: UUID] {
        Dictionary(uniqueKeysWithValues: snapshot.binaries.map { ($0.slot, $0.id) })
    }

    /// Publishes the global logical-catalog revision into each currently loaded slot's compatibility
    /// channel. This preserves the existing view notification seam without minting a second revision
    /// authority; condition/action edits notify even when the projected address set is unchanged.
    /// Removing or replacing an owner still advances the generation before a numeric token can be
    /// interpreted in the new image domain.
    private func reconcileDebuggerBreakpointRevisionsAfterSnapshotChange() {
        let current = Self.debuggerBreakpointSets(
            in: snapshot,
            availability: logicalBreakpointCatalogAvailability
        )
        let currentBinaryIDs = Self.debuggerBinaryIDs(in: snapshot)
        let priorSlots = Set(lastKnownDebuggerBreakpointSets.keys)
        let currentSlots = Set(current.keys)
        let replacedSlots = currentSlots.filter { slot in
            guard let priorID = lastKnownDebuggerBinaryIDs[slot],
                  let currentID = currentBinaryIDs[slot] else { return false }
            return priorID != currentID
        }

        if !priorSlots.subtracting(currentSlots).isEmpty || !replacedSlots.isEmpty {
            invalidateDebuggerBreakpointRevisionGeneration()
        }

        let catalogRevision = logicalBreakpointCatalogAvailability == .available
            ? snapshot.logicalBreakpointCatalog.revision : 0
        let projectedRevisions = Dictionary(
            uniqueKeysWithValues: currentSlots.map { ($0, catalogRevision) }
        )
        if debuggerBreakpointRevisions != projectedRevisions {
            debuggerBreakpointRevisions = projectedRevisions
        }
        lastKnownDebuggerBreakpointSets = current
        lastKnownDebuggerBinaryIDs = currentBinaryIDs
    }

    private func invalidateDebuggerBreakpointRevisionGeneration() {
        if debuggerBreakpointRevisionGeneration == UInt64.max {
            debuggerBreakpointRevisionGeneration = 0
        } else {
            debuggerBreakpointRevisionGeneration += 1
        }
    }

    /// A session may serialize the bare coordinate only when the authoritative selection and the
    /// raw persisted focus name the same still-loaded image. This prevents the computed focus
    /// fallback from manufacturing an owner during save.
    private var persistableSelectedAddress: UInt64? {
        guard let selection = selectedImageAddress,
              selection.slot == focusedImageSlotStorage,
              snapshot.binary(in: selection.slot) != nil,
              snapshot.containsLoadedAddress(selection.address, in: selection.slot) else {
            return nil
        }
        return selection.address
    }

    /// The user's chosen focused image slot (what the listing/hex/inspector render + what bare-address
    /// authoring binds to). Stored so it is switchable and drives UI updates; `.primary` until the
    /// user picks another image. Never trust this raw value directly — read `focusedImageSlot`, which
    /// validates it against the live snapshot.
    @Published private(set) var focusedImageSlotStorage: ImageSlot = .primary {
        willSet { revokePatternPublication() }
        didSet {
            if focusedImageSlotStorage != oldValue {
                // Every supplemental report belongs to the image that admitted it. Centralize
                // retirement here so restore, remap, clamping, and explicit UI focus changes all
                // cancel/fence the old lane rather than relying on one focus entry point.
                supersedeDyldCacheDifferential(clearReport: true)
                phase2ReadLedger.noteWorkspaceMetadataChange()
            }
        }
    }

    /// The image slot every bare-address authoring edit binds to and the UI renders. Returns the
    /// user's stored focus when that image still exists; otherwise falls back to the primary image
    /// (so a reanalysis/restore/remove that drops the focused image can never strand focus on a
    /// vanished slot). This is the SINGLE chokepoint where a bare address becomes a workspace-unique
    /// key — `overrideKey` and every f4 authoring path route through it.
    var focusedImageSlot: ImageSlot {
        snapshot.binary(in: focusedImageSlotStorage) != nil ? focusedImageSlotStorage : snapshot.primarySlot
    }

    /// The focused image's derived analysis (COW — never deep-copies `instructions`/`imageBytes`).
    var focusedAnalysis: ImageAnalysis? { snapshot.analysis(in: focusedImageSlot) }

    /// The complete slot-coherent input for the interactive pseudocode pane. The model aggregate
    /// owns all printer inputs so the view cannot accidentally mix focused and primary evidence.
    var focusedPseudocodeRenderInput: PseudocodeRenderInput {
        snapshot.pseudocodeRenderInput(
            selectedAddress: selectedAddress,
            in: focusedImageSlot
        )
    }

    /// The focused image's identity record.
    var focusedBinary: BinaryImage? { snapshot.binary(in: focusedImageSlot) }

    /// Switch the focused image. A no-op when `slot` names no loaded image. Resets ambiguous
    /// transient selection/graph state so an address from image A can't be
    /// reinterpreted against image B at a colliding VA.
    func focusImage(_ slot: ImageSlot) {
        guard slot != focusedImageSlotStorage, snapshot.binary(in: slot) != nil else { return }
        // Publish selection clearing before the new focus so observers can never render the old
        // bare coordinate under the new image, even for one update cycle.
        resetTransientSelectionForFocusChange()
        focusedImageSlotStorage = slot
        reconcileNativeDecompilerDrive(reason: .selectionOrFocusChanged)
    }

    /// Clears transient state that is ambiguous across images sharing a VA. The selected location
    /// is qualified; graph identity remains focus-bound. Owner-qualified history survives.
    private func resetTransientSelectionForFocusChange() {
        pendingRehydratedSelection = nil
        selectedAddress = nil
        clearGraphInteraction()
        xrefCursor = nil
        syncGraphElementToSelectedAddress()
    }

    // MARK: - Image-qualified authoring keys

    /// Qualifies a bare address for the focused image. Every `snapshot.addressOverrides`
    /// subscript in this store goes through here, so no edit can silently land in slot 0
    /// when another image is focused.
    func overrideKey(_ address: UInt64) -> ImageAddress {
        ImageAddress(slot: focusedImageSlot, address: address)
    }

    private func isCurrentImageOwner(_ slot: ImageSlot, binaryID: UUID?) -> Bool {
        if let binaryID {
            return snapshot.binary(in: slot)?.id == binaryID
                && snapshot.analysis(in: slot) != nil
        }
        if snapshot.binaries.isEmpty {
            return slot == snapshot.primarySlot && snapshot.analysis(in: slot) != nil
        }
        return snapshot.binary(in: slot) != nil && snapshot.analysis(in: slot) != nil
    }

    private func hasInstruction(_ target: ImageAddress, binaryID: UUID? = nil) -> Bool {
        isCurrentImageOwner(target.slot, binaryID: binaryID)
            && (snapshot.analysis(in: target.slot)?.instructions.contains {
                $0.address == target.address
            } ?? false)
    }

    /// Delayed requests must carry a binary UUID whenever the workspace has real image owners.
    /// Nil ownership is accepted only by deterministic legacy fixtures with no `BinaryImage`.
    private func isCurrentRequestOwner(_ slot: ImageSlot, ownerBinaryID: UUID?) -> Bool {
        if let ownerBinaryID {
            return snapshot.binary(in: slot)?.id == ownerBinaryID
                && snapshot.analysis(in: slot) != nil
        }
        return snapshot.binaries.isEmpty
            && slot == snapshot.primarySlot
            && snapshot.analysis(in: slot) != nil
    }

    private func hasRequestOwnedInstruction(
        _ target: ImageAddress,
        ownerBinaryID: UUID?
    ) -> Bool {
        isCurrentRequestOwner(target.slot, ownerBinaryID: ownerBinaryID)
            && (snapshot.analysis(in: target.slot)?.instructions.contains {
                $0.address == target.address
            } ?? false)
    }

    private func hasRequestOwnedMappedAddress(
        _ target: ImageAddress,
        ownerBinaryID: UUID?
    ) -> Bool {
        isCurrentRequestOwner(target.slot, ownerBinaryID: ownerBinaryID)
            && snapshot.containsLoadedAddress(target.address, in: target.slot)
    }

    private func hasRequestOwnedFunctionStart(
        _ target: ImageAddress,
        ownerBinaryID: UUID?
    ) -> Bool {
        isCurrentRequestOwner(target.slot, ownerBinaryID: ownerBinaryID)
            && (snapshot.analysis(in: target.slot)?.functions.contains {
                $0.startAddress == target.address
            } ?? false)
    }

    private func hasMappedAddress(_ target: ImageAddress, binaryID: UUID? = nil) -> Bool {
        isCurrentImageOwner(target.slot, binaryID: binaryID)
            && snapshot.containsLoadedAddress(target.address, in: target.slot)
    }

    private func hasFunctionStart(_ target: ImageAddress, binaryID: UUID? = nil) -> Bool {
        isCurrentImageOwner(target.slot, binaryID: binaryID)
            && (snapshot.analysis(in: target.slot)?.functions.contains {
                $0.startAddress == target.address
            } ?? false)
    }

    private func rejectStaleAuthoringRequest(_ message: String) {
        lastIssue = message
    }

    private func invalidateAuthoringPresentation(_ id: UUID) {
        invalidatedAuthoringPresentationIDs.insert(id)
    }

    private func authoringPresentationIsCurrent(_ id: UUID) -> Bool {
        !invalidatedAuthoringPresentationIDs.contains(id)
    }

    /// Binary ownership alone drives lifecycle invalidation. Derived entity membership remains a
    /// commit-family check, so an ordinary analysis publication cannot retire an otherwise valid
    /// editor while removal or same-slot binary replacement always does.
    private func authoringOpeningOwnerStillOccupiesSlot(
        _ slot: ImageSlot,
        ownerBinaryID: UUID?
    ) -> Bool {
        if let ownerBinaryID {
            return snapshot.binary(in: slot)?.id == ownerBinaryID
        }
        return snapshot.binaries.isEmpty && slot == snapshot.primarySlot
    }

    private func invalidateAuthoringPresentationsWithDisplacedOwners() {
        if let request = overrideEditorRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.imageSlot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = signatureEditorRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.imageSlot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = registerRenameRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.imageSlot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.presentationID)
        }
        if let request = switchHintEditorRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.imageSlot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = dataShapeEditorRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.imageSlot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = pendingPatchBytesRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.target.slot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.presentationID)
        }
        if let request = pendingAssembleRequest,
           !authoringOpeningOwnerStillOccupiesSlot(request.target.slot, ownerBinaryID: request.ownerBinaryID) {
            invalidateAuthoringPresentation(request.presentationID)
        }
    }

    private func invalidateAuthoringPresentations(in slot: ImageSlot) {
        if let request = overrideEditorRequest, request.imageSlot == slot {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = signatureEditorRequest, request.imageSlot == slot {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = registerRenameRequest, request.imageSlot == slot {
            invalidateAuthoringPresentation(request.presentationID)
        }
        if let request = switchHintEditorRequest, request.imageSlot == slot {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = dataShapeEditorRequest, request.imageSlot == slot {
            invalidateAuthoringPresentation(request.id)
        }
        if let request = pendingPatchBytesRequest, request.target.slot == slot {
            invalidateAuthoringPresentation(request.presentationID)
        }
        if let request = pendingAssembleRequest, request.target.slot == slot {
            invalidateAuthoringPresentation(request.presentationID)
        }
    }

    private func invalidateAllOwnerBoundAuthoringPresentations() {
        if let request = overrideEditorRequest { invalidateAuthoringPresentation(request.id) }
        if let request = signatureEditorRequest { invalidateAuthoringPresentation(request.id) }
        if let request = registerRenameRequest { invalidateAuthoringPresentation(request.presentationID) }
        if let request = switchHintEditorRequest { invalidateAuthoringPresentation(request.id) }
        if let request = dataShapeEditorRequest { invalidateAuthoringPresentation(request.id) }
        if let request = pendingPatchBytesRequest { invalidateAuthoringPresentation(request.presentationID) }
        if let request = pendingAssembleRequest { invalidateAuthoringPresentation(request.presentationID) }
    }

    /// Rewrites EVERY slot-keyed collection from `old` to `new` in one mutation. Used when a
    /// package import must renumber an image's slot: a partial remap would orphan authoring,
    /// so all of overrides / bookmarks / manual xrefs / segment overrides / the image itself
    /// move together or not at all.
    func remapImageSlot(from old: ImageSlot, to new: ImageSlot) {
        guard logicalBreakpointCatalogAvailability == .available,
              old != new,
              let movingBinary = snapshot.binary(in: old),
              snapshot.binary(in: new) == nil,
              snapshot.analysis(in: new) == nil else { return }
        let remappedLogicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog
        do {
            remappedLogicalBreakpointCatalog = try Self.logicalBreakpointCatalog(
                snapshot.logicalBreakpointCatalog,
                remappingOwner: movingBinary.id,
                from: old,
                to: new
            )
        } catch {
            // Slot identity cannot move independently from durable breakpoint owner seals.
            // Refuse the complete remap before any side effect when revision authority is spent.
            lastIssue = error.localizedDescription
            return
        }
        markDocumentMutated()
        invalidateAuthoringPresentations(in: old)
        // A request captures its slot as part of its identity, so it cannot simply follow the
        // remapped snapshot. Retire that generation now and remember to re-drive the same live
        // overrides from the image's new slot after the atomic ownership move. Sibling slots are
        // deliberately untouched. Activity publication is deferred to the replacement kick so a
        // single active request does not visibly flicker idle during this synchronous method.
        let shouldRescheduleReanalysis = reanalysisTasksBySlot[old] != nil
        if shouldRescheduleReanalysis {
            supersedeReanalysis(in: old, updateActivity: false)
        }
        // A retained candidate captures the old slot. Cancel its invisible selection intent before
        // ownership moves so remap-away/remap-back cannot make that stale candidate valid again.
        let shouldRestartRehydration = rehydrationTask != nil || rehydrationRestartTask != nil
        supersedeRehydration()
        pendingRehydratedSelection = nil
        let priorFocus = focusedImageSlotStorage
        let priorSelection = selectedImageAddress
        // Every slot-owned Undo/Redo closure captures an exact qualified target. Once a slot is
        // renumbered those closures no longer describe a valid workspace identity. Retire only
        // this slot generation; sibling proxies, workspace-global store actions, and window text
        // editing targets remain intact in their original relative history.
        retireUndoHistory(in: old)
        // Publish a conservative nil selection before the snapshot changes ownership. `snapshot`,
        // focus, and selection are separate publishers; retaining the old qualified value across
        // the snapshot publication would briefly expose a selection whose slot no longer exists.
        if selectedImageAddress != nil {
            selectedImageAddress = nil
        }
        xrefCursor = nil
        // Delegate to the snapshot's atomic remap, which also moves the per-image analysis bucket
        // (analysisBySlot) alongside binaries + all slot-qualified authoring.
        var next = snapshot
        next.remapImageSlot(from: old, to: new)
        next.logicalBreakpointCatalog = remappedLogicalBreakpointCatalog
        Self.reprojectLogicalBreakpointCompatibility(in: &next, availability: .available)
        phase2ReadLedger.ingestSnapshotTransition(from: snapshot, to: next)
        isCoordinatingSnapshotIdentityChange = true
        snapshot = next
        isCoordinatingSnapshotIdentityChange = false
        remapNavigatorState(from: old, to: new)
        reconcileDebuggerWorkspaceArtifactCatalog()
        reconcileDebuggerBreakpointResolutionCatalog()

        reconcileDebuggerBreakpointRevisionsAfterSnapshotChange()

        focusedImageSlotStorage = priorFocus == old
            ? new
            : (snapshot.binary(in: priorFocus) != nil ? priorFocus : snapshot.primarySlot)

        let remappedSelection = priorSelection.map { selection in
            selection.slot == old
                ? ImageAddress(slot: new, address: selection.address)
                : selection
        }
        if let remappedSelection,
           remappedSelection.slot == focusedImageSlotStorage,
           snapshot.binary(in: remappedSelection.slot) != nil,
           snapshot.containsLoadedAddress(
               remappedSelection.address,
               in: remappedSelection.slot
           ) {
            selectedImageAddress = remappedSelection
        } else {
            clearInteractiveSelection()
        }
        // Graph callbacks cannot survive a slot remap. Retire old-slot visits, preserving
        // every sibling owner, then record the newly qualified current location.
        clearGraphInteraction()
        xrefCursor = nil
        pruneNavigationHistory()
        if let address = selectedAddress, let location = navigationLocation(at: address) {
            navigationHistory.record(location)
        }
        recomputeCrossImageXrefs()
        if shouldRestartRehydration {
            rehydrateLoadedImages()
        }
        if shouldRescheduleReanalysis,
           !reanalyzeHonoringOverrides(in: new) {
            // The remapped image lost both its original file and embedded bytes. No replacement
            // task can be created, so reconcile the aggregate indicator after retiring the old one.
            updateReanalysisActivity()
        }
    }

    // MARK: - Cross-image references (WS-6)

    /// Re-derives the transient cross-image edge set from the current snapshot (A's import →
    /// another image's export, by name). Cheap, synchronous, main-actor. This is a DERIVED-state
    /// restoration, NOT a user edit, so it must never call `markDocumentMutated()`. Fired at every
    /// image-set change: both restore paths, `loadAdditionalBinary`, `remapImageSlot`, and the
    /// reanalysis splice. Single-image workspaces resolve to an empty set (nothing rendered, nothing
    /// persisted). Ambiguous-export diagnostics surface through the focused image's Problems.
    func recomputeCrossImageXrefs() {
        // WS-7: the synthetic runtime layout is derived here too (it feeds the address-edge resolver
        // and the runtime-VA display mode). Symbolic (name-join) + address (value-in-range) edges
        // are merged into one transient set.
        let layout = ImageLayoutResolver.layout(snapshot)
        imageLayout = layout
        let symbolic = CrossImageReferenceResolver.resolve(snapshot)
        let address = CrossImageAddressResolver.resolve(snapshot, layout: layout)
        snapshot.crossImageXrefs = symbolic.edges + address
        crossImageDiagnostics = symbolic.diagnostics + Self.imageLayoutDiagnostics(layout, snapshot: snapshot)
    }

    /// MS-07: advisory text for images the runtime layout conservatively left unplaced (their
    /// runtime VAs are not resolvable). Deterministic slot order; empty for every ordinary layout.
    static func imageLayoutDiagnostics(_ layout: ImageLayout, snapshot: WorkspaceSnapshot) -> [String] {
        layout.rejections.keys.sorted().compactMap { slot in
            guard let rejection = layout.rejections[slot] else { return nil }
            let name = snapshot.binary(in: slot)?.name ?? "image \(slot.rawValue)"
            let reason: String
            switch rejection {
            case .sectionExtentOverflow:
                reason = "its section extent exceeds the 64-bit address space"
            case .addressSpaceExhausted:
                reason = "no disjoint runtime range remains above the images already placed"
            case .primaryExtentUnavailable:
                reason = "the primary image's extent could not be established"
            }
            return "\(name) has no runtime address range: \(reason)."
        }
    }

    /// Advisory diagnostics from the last cross-image resolution (e.g. a name exported by multiple
    /// images). Surfaced read-only; kept separate from per-image `AnalysisDiagnostic`s because these
    /// are workspace-level and carry no address.
    private(set) var crossImageDiagnostics: [String] = []

    /// WS-7 synthetic runtime layout (slot → slide). Transient + derived, never persisted; recomputed
    /// alongside the cross-image edges. Consulted only by the address-edge resolver and the runtime-VA
    /// display mode — never by selection/navigation/authoring, which stay image-VA/`ImageAddress`-keyed.
    private(set) var imageLayout = ImageLayout()

    /// Cross-image edges INTO the focused image at `address` (the inbound-xref inspector rows).
    func crossImageInbound(at address: UInt64) -> [CrossImageXRef] {
        let slot = focusedImageSlot
        return snapshot.crossImageXrefs.filter { $0.toSlot == slot && $0.to == address }
    }

    /// Cross-image edges OUT of the focused image at `address` (the outbound target annotation).
    func crossImageOutbound(at address: UInt64) -> [CrossImageXRef] {
        let slot = focusedImageSlot
        return snapshot.crossImageXrefs.filter { $0.fromSlot == slot && $0.from == address }
    }

    /// Captures the exact row projection before SwiftUI retains its delayed callback.
    func crossImageXRefNavigationTarget(
        for edge: CrossImageXRef,
        endpoint: ImageAddress
    ) -> CrossImageXRefNavigationTarget? {
        guard let openingSelection = selectedImageAddress,
              let sourceOwnerBinaryID = snapshot.binary(in: edge.fromSlot)?.id,
              let destinationOwnerBinaryID = snapshot.binary(in: edge.toSlot)?.id,
              snapshot.crossImageXrefs.contains(edge) else {
            return nil
        }

        let source = ImageAddress(slot: edge.fromSlot, address: edge.from)
        let destination = ImageAddress(slot: edge.toSlot, address: edge.to)
        guard (openingSelection == source && endpoint == destination)
                || (openingSelection == destination && endpoint == source),
              snapshot.containsLoadedAddress(endpoint.address, in: endpoint.slot) else {
            return nil
        }

        return CrossImageXRefNavigationTarget(
            edge: edge,
            sourceOwnerBinaryID: sourceOwnerBinaryID,
            destinationOwnerBinaryID: destinationOwnerBinaryID,
            openingSelection: openingSelection,
            endpoint: endpoint
        )
    }

    /// Follows a retained cross-image row only while its complete opening projection is current.
    /// Validation is complete before focus or selection changes, so rejection is a total no-op.
    @discardableResult
    func navigateCrossImage(_ target: CrossImageXRefNavigationTarget) -> Bool {
        guard focusedImageSlot == target.openingSelection.slot,
              selectedImageAddress == target.openingSelection,
              snapshot.binary(in: target.edge.fromSlot)?.id == target.sourceOwnerBinaryID,
              snapshot.binary(in: target.edge.toSlot)?.id == target.destinationOwnerBinaryID,
              snapshot.crossImageXrefs.contains(target.edge),
              snapshot.containsLoadedAddress(
                  target.endpoint.address,
                  in: target.endpoint.slot
              ) else {
            return false
        }

        let source = ImageAddress(slot: target.edge.fromSlot, address: target.edge.from)
        let destination = ImageAddress(slot: target.edge.toSlot, address: target.edge.to)
        guard (target.openingSelection == source && target.endpoint == destination)
                || (target.openingSelection == destination && target.endpoint == source) else {
            return false
        }

        focusImage(target.endpoint.slot)
        return selectAddress(target.endpoint)
    }

    /// Synchronous compatibility wrapper for callers that do not retain a rendered row.
    func navigateCrossImage(to slot: ImageSlot, address: UInt64) {
        guard snapshot.binary(in: slot) != nil else { return }
        focusImage(slot)
        _ = selectAddress(ImageAddress(slot: slot, address: address))
    }

    // MARK: - Runtime-VA display mode (WS-7)

    /// How addresses are RENDERED. `.image` = the image's own VA (default, single-image unchanged);
    /// `.runtime` = the unified slid runtime VA. PRESENTATION ONLY — selection, navigation, and
    /// authoring stay image-VA / `ImageAddress`-keyed regardless of this mode.
    enum AddressDisplayMode: String, Codable, CaseIterable { case image, runtime }

    @Published var addressDisplayMode: AddressDisplayMode = .image

    /// A go-to that honors the display mode: in `.runtime`, interpret `entered` as a runtime VA and
    /// resolve it to `(slot, image-VA)`, focusing that image; in `.image`, select the bare address.
    /// An unresolvable runtime value falls back to a bare selection.
    @discardableResult
    func gotoRuntimeOrImage(_ entered: UInt64) -> Bool {
        switch addressDisplayMode {
        case .image:
            // A bare value is a focused-image image-VA (WS-8 slot-aware goto).
            return goToAddress(entered)
        case .runtime:
            // A runtime VA resolves to exactly one (slot, image-VA); navigate there via the WS-8
            // primitive (focus + select + editor mode). Unresolvable → fall back to a focused goto.
            if let target = imageLayout.resolve(runtimeVA: entered) {
                return goToAddress(target.address, in: target.slot)
            }
            return goToAddress(entered)
        }
    }

    // MARK: - Authoring overrides (rename / comment)

    /// Sets (or clears, when the name is empty) the custom name for the entity at
    /// `address`, registering a reversible Undo action.
    func setCustomName(_ address: UInt64, name: String?) {
        setCustomName(overrideKey(address), name: name)
    }

    /// Slot-qualified rename for callers bound to an explicit command image rather than live
    /// focus. Scripting passes the snapshot's primary slot so `rename` writes exactly the image
    /// whose labels `functions`, `name-at` and the general `function` selector read.
    func setCustomName(_ address: UInt64, in slot: ImageSlot, name: String?) {
        setCustomName(ImageAddress(slot: slot, address: address), name: name)
    }

    private func setCustomName(_ key: ImageAddress, name: String?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.customName = Self.normalizedOverrideText(name)
        applyOverride(key, override, actionName: "Rename")
    }

    // MARK: - Debug symbols (dSYM) import

    /// Reads debug symbols from a `.dSYM` bundle and, when its UUID matches the loaded binary,
    /// injects each recovered name as a `customName` override at the function's address. The name
    /// import is ONE undoable group, persisted through the same override seam a manual rename uses
    /// — so dSYM names survive save/reopen and Undo reverts those names at once. When the matched
    /// image is focused, the group triggers one re-flow of that image; a non-focused sibling import
    /// never re-analyzes another image as a side effect.
    /// Recovered line rows and catalog-safe type definitions land as import-time enrichment.
    ///
    /// Result + failures surface through dedicated alert channels (`debugSymbolsResultMessage` /
    /// `debugSymbolsImportError`), never the save-failed banner. A name is only applied when its
    /// address falls inside the loaded image (a known function start or any in-range address),
    /// so a stale dSYM that somehow passed the UUID gate still can't scribble names off the map.
    /// `expectedUUID` overrides the loaded binary's UUID as the match gate (used by the
    /// scripting `read-debug-symbols` command, which may verify against a UUID the caller
    /// already trusts). When nil, the loaded binary's recorded UUID is used — the GUI default.
    func importDebugSymbols(at url: URL, expectedUUID: String? = nil, service: DSYMImportService = DSYMImportService()) {
        guard let primary = snapshot.binaries.first else {
            debugSymbolsImportError = "Open a binary before reading its debug symbols."
            return
        }

        // Resolve which IMAGE the dSYM belongs to. When the caller pins a UUID we honor it
        // against the primary (the scripting contract); otherwise we match the dSYM's own UUID
        // against EVERY loaded image's LC_UUID so a sibling image's dSYM lands names in that
        // image's slot — not scribbled onto the primary through the shared authoring map.
        let result: DSYMImportResult
        do {
            result = try service.importDebugSymbols(at: url, expectedUUID: expectedUUID ?? primary.metadata.uuid)
        } catch {
            // The primary didn't match; try each other image before reporting failure.
            if expectedUUID == nil,
               let (matched, sibling) = firstMatchingImageDSYM(at: url, service: service) {
                injectDebugSymbols(matched, into: sibling.slot)
                return
            }
            debugSymbolsImportError = error.localizedDescription
            return
        }
        // HS-9: a caller-pinned UUID gates the dSYM, never the image; the primary's own LC_UUID
        // must still agree before any name lands on it.
        do {
            try result.requireMatchingImage(uuid: primary.metadata.uuid)
        } catch {
            debugSymbolsImportError = error.localizedDescription
            return
        }

        injectDebugSymbols(result, into: primary.slot)
    }

    /// Attempts the dSYM import against each non-primary image's UUID, returning the first match
    /// with the image it belongs to. Nil when no loaded image matches the dSYM.
    private func firstMatchingImageDSYM(
        at url: URL, service: DSYMImportService
    ) -> (DSYMImportResult, BinaryImage)? {
        for image in snapshot.binaries.dropFirst() {
            guard let uuid = image.metadata.uuid else { continue }
            if let result = try? service.importDebugSymbols(at: url, expectedUUID: uuid) {
                return (result, image)
            }
        }
        return nil
    }

    /// Injects a recovered dSYM result's function names as `customName` overrides and reports
    /// the outcome through the dedicated alert channels. Split out from `importDebugSymbols`
    /// so the name-mapping policy (addressability + DEMANGLE) is unit-testable with a crafted
    /// `DSYMImportResult` (no real toolchain dSYM required).
    @discardableResult
    func injectDebugSymbols(_ result: DSYMImportResult) -> Int {
        injectDebugSymbols(result, into: snapshot.primarySlot)
    }

    /// Slot-explicit injection used after UUID matching identifies a particular loaded image.
    /// Requiring the slot here prevents callers from accidentally routing a sibling's dSYM
    /// through literal slot 0; the convenience overload above resolves the live primary image.
    @discardableResult
    func injectDebugSymbols(_ result: DSYMImportResult, into slot: ImageSlot) -> Int {
        guard let targetAnalysis = snapshot.analysis(in: slot) else {
            debugSymbolsImportError = "No analyzed image exists in slot \(slot.rawValue)."
            return 0
        }
        // Build the injection map: a recovered name overrides the address it defines, but only
        // when that address is addressable in the MATCHED image's analysis (it lands on a known
        // function start, or otherwise inside one of that image's loaded sections). Names that
        // don't map are reported as skipped rather than written at an address the listing can't
        // show. Every write is keyed to the matched slot, so colliding VAs remain independent.
        let functionStarts = Set(targetAnalysis.functions.map(\.startAddress))
        let targetSections = targetAnalysis.sections
        var overrides = snapshot.addressOverrides
        var applied = 0
        var skipped = 0
        // Land recovered line table and catalog-safe types on the snapshot up front, independent of
        // how many function names map. Setting them before the override re-analysis lets
        // `applyReanalysisResult` carry them across (see sourceLines/typeDefinitions preservation).
        let targetBinary = snapshot.binary(in: slot)
        retainObjCSignatureDeclarations(result, in: slot)
        retainSourceDebugImport(result, in: slot)
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.sourceLines = result.sourceLines
            if let targetBinary {
                Self.restampAnalysisInputFingerprint(&analysis, using: targetBinary)
            } else {
                analysis.analysisInputFingerprint = nil
            }
        }
        let importedTypes = Self.typeDefinitions(from: result.types, existingTypeNames: Set(snapshot.typeDefinitions.map(\.name)))
        if !importedTypes.isEmpty {
            snapshot.typeDefinitions.append(contentsOf: importedTypes)
        }
        // These retained writes are independent of the undoable name/signature operation.
        // Record them before an unmapped-name return and before capturing name Undo tokens.
        if targetAnalysis.sourceLines != result.sourceLines || !importedTypes.isEmpty {
            markDocumentMutated()
        }
        for symbol in result.functions {
            let isAddressable = functionStarts.contains(symbol.address)
                || targetSections.contains { section in
                    !section.isZeroFill && section.size > 0
                        && section.address <= symbol.address
                        && symbol.address < section.address &+ section.size
                }
            guard isAddressable else { skipped += 1; continue }
            let key = ImageAddress(slot: slot, address: symbol.address)
            var override = overrides[key] ?? AddressOverride()
            // A dSYM emitted from a release build carries MANGLED C++/Swift names. Run each
            // through the FROZEN demangler so the listing shows the readable form; fall back
            // to the raw name when it is not a mangled name we cover (displayName does both).
            override.customName = Demangler.displayName(for: symbol.name)
            // An active existing signature is authoritative. A quarantine-only legacy
            // payload is persisted but analysis-inert, so it must not suppress later
            // debug metadata; carry that quarantine alongside the recovered declaration.
            if override.signature?.hasAnalysisEffect != true,
               var recoveredSignature = result.signatures[symbol.address] {
                recoveredSignature.quarantinedLegacyArgs =
                    override.signature?.quarantinedLegacyArgs ?? []
                override.signature = recoveredSignature
            }
            overrides[key] = override
            applied += 1
        }

        guard applied > 0 else {
            debugSymbolsImportError = "Matched the dSYM (UUID \(result.matchedUUID)) but none of its "
                + "\(result.functions.count) recovered function address\(result.functions.count == 1 ? "" : "es") "
                + "fall inside the loaded image."
            return 0
        }

        // Name/signature authoring for a non-focused sibling must never kick re-analysis of the
        // focused image. Preserve the established single-image behavior when the matched target
        // is focused; Task 2.1 then captures and re-analyzes that same slot.
        applyOverrideMap(
            overrides,
            in: slot,
            actionName: "Import Debug Symbols",
            reanalyze: slot == focusedImageSlot
        )

        var note = "Imported \(applied) function name\(applied == 1 ? "" : "s") from "
            + "\(result.dwarfURL.lastPathComponent).\nMatched UUID \(result.matchedUUID)."
        if !importedTypes.isEmpty {
            note += "\nImported \(importedTypes.count) type definition\(importedTypes.count == 1 ? "" : "s")."
        }
        if skipped > 0 {
            note += "\n\nSkipped \(skipped) name\(skipped == 1 ? "" : "s") whose address is outside the loaded image."
        }
        debugSymbolsResultMessage = note
        return applied
    }

    /// Sets (or clears) the custom comment for the instruction at `address`,
    /// registering a reversible Undo action.
    func setCustomComment(_ address: UInt64, comment: String?) {
        setCustomComment(overrideKey(address), comment: comment)
    }

    /// Slot-qualified comment edit for callers bound to an explicit command image (scripting's
    /// primary scope) rather than live focus. Same undo/dirty path as the focused overload.
    func setCustomComment(_ address: UInt64, in slot: ImageSlot, comment: String?) {
        setCustomComment(ImageAddress(slot: slot, address: address), comment: comment)
    }

    private func setCustomComment(_ key: ImageAddress, comment: String?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.customComment = Self.normalizedOverrideText(comment)
        applyOverride(key, override, actionName: "Edit Comment")
    }

    /// Sets (or clears, when empty) the free-text tag for the address,
    /// registering a reversible Undo action.
    func setTag(_ address: UInt64, tag: String?) {
        setTag(overrideKey(address), tag: tag)
    }

    /// Slot-qualified tag edit for callers bound to an explicit command image (scripting's
    /// primary scope) rather than live focus. Same undo/dirty path as the focused overload.
    func setTag(_ address: UInt64, in slot: ImageSlot, tag: String?) {
        setTag(ImageAddress(slot: slot, address: address), tag: tag)
    }

    private func setTag(_ key: ImageAddress, tag: String?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.tag = Self.normalizedOverrideText(tag)
        applyOverride(key, override, actionName: "Edit Tag")
    }

    /// Sets (or clears, when nil) the highlight color for the address,
    /// registering a reversible Undo action.
    func setColorTag(_ address: UInt64, color: ColorTag?) {
        setColorTag(address, in: focusedImageSlot, color: color)
    }

    /// Slot-qualified color edit for callers bound to an explicit command image (scripting's
    /// primary scope) rather than live focus. The focused overload above forwards here, so the
    /// undo/dirty path is shared.
    func setColorTag(_ address: UInt64, in slot: ImageSlot, color: ColorTag?) {
        let key = ImageAddress(slot: slot, address: address)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.colorTag = color
        applyOverride(key, override, actionName: color == nil ? "Clear Color" : "Set Color")
    }

    /// Replaces the transient graph group only when every key belongs to the current projection's
    /// exact slot and names a current node start. Empty input is the explicit clear operation.
    @discardableResult
    func setGraphNodeMultiSelection(_ addresses: Set<ImageAddress>) -> Bool {
        guard !addresses.isEmpty else {
            clearGraphNodeMultiSelection()
            return true
        }
        guard isValidGraphNodeMultiSelection(addresses) else { return false }
        graphNodeMultiSelection = addresses
        return true
    }

    /// Cmd-click/VoiceOver group-toggle entry point. Like node selection, it validates the captured
    /// node's complete current identity before changing the qualified group.
    @discardableResult
    func toggleGraphNodeMultiSelection(_ target: GraphSelectionTarget) -> Bool {
        guard let current = currentGraphNodeTarget(matching: target) else { return false }
        let key = ImageAddress(slot: current.imageSlot, address: current.startAddress)
        var next = graphNodeMultiSelection
        if next.contains(key) {
            next.remove(key)
        } else {
            next.insert(key)
        }
        return setGraphNodeMultiSelection(next)
    }

    /// Slot-qualified graph-group color mutation. The request must equal the store's exact current
    /// group, so a delayed callback delivered after focus/reanalysis/reset (which clears the group)
    /// fails closed even if the same bare starts happen to exist again. The resulting undo captures
    /// the qualified keys in the override map and therefore remains bound after focus changes.
    @discardableResult
    func setGraphColorTag(at addresses: [ImageAddress], color: ColorTag?) -> Bool {
        let requested = Set(addresses)
        guard !requested.isEmpty,
              requested == graphNodeMultiSelection,
              isValidGraphNodeMultiSelection(requested) else {
            return false
        }

        let slot = requested.first!.slot
        let stableKeys = requested
            .filter { $0.slot == slot }
            .sorted { $0.address < $1.address }
        var overrides = snapshot.addressOverrides
        for key in stableKeys {
            var override = overrides[key] ?? AddressOverride()
            override.colorTag = color
            overrides[key] = override
        }
        applyOverrideMap(
            overrides,
            in: slot,
            actionName: color == nil ? "Clear Color" : "Set Color",
            reanalyze: false
        )
        return true
    }

    /// Bare focused-image compatibility overload retained for existing synchronous callers and
    /// tests. Interactive graph callbacks use the qualified overload above. Painting N addresses
    /// still collapses into one Undo; empty input is a no-op and other override fields survive.
    func setColorTag(at addresses: [UInt64], color: ColorTag?) {
        guard !addresses.isEmpty else { return }
        var overrides = snapshot.addressOverrides
        for address in addresses {
            let key = overrideKey(address)
            var override = overrides[key] ?? AddressOverride()
            override.colorTag = color
            overrides[key] = override
        }
        applyOverrideMap(
            overrides,
            in: focusedImageSlot,
            actionName: color == nil ? "Clear Color" : "Set Color",
            reanalyze: false
        )
    }

    /// Applies a highlight color to the currently selected instruction (nil clears
    /// it). Surfaced by the command palette's color commands.
    func setColorTagAtSelection(_ color: ColorTag?) {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to color."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.colorTag = color
        applyOverride(target, override, actionName: color == nil ? "Clear Color" : "Set Color")
    }

    /// Sets (or clears, when nil) the immediate-operand display format at `address`,
    /// reversibly through the shared address-override path. The listing and inspector
    /// re-render the immediate in the chosen radix/character form.
    func setOperandFormat(_ address: UInt64, _ format: OperandFormat?) {
        setOperandFormat(address, in: focusedImageSlot, format)
    }

    /// Slot-qualified operand-format edit for callers bound to an explicit command image
    /// (scripting's primary scope) rather than live focus. Same undo/dirty path.
    func setOperandFormat(_ address: UInt64, in slot: ImageSlot, _ format: OperandFormat?) {
        let key = ImageAddress(slot: slot, address: address)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.operandFormat = format
        applyOverride(key, override, actionName: format == nil ? "Clear Operand Format" : "Format Operand")
    }

    /// Applies an operand format to the selected instruction (nil clears it).
    /// Surfaced by the command palette's "Format Operand" commands.
    func setOperandFormatAtSelection(_ format: OperandFormat?) {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to format its operand."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.operandFormat = format
        applyOverride(target, override, actionName: format == nil ? "Clear Operand Format" : "Format Operand")
    }

    /// Renames a REGISTER in the pseudocode for the procedure starting at `procedureStart`:
    /// `register` is the register identifier (e.g. "x19"), `name` the user's display name (empty
    /// clears the rename for that register). KEYED AT THE PROCEDURE START — the same per-function
    /// scope a signature override uses — so a rename in one procedure never leaks into another.
    /// Display-only (the printer substitutes the name); does NOT re-drive analysis. Reversible.
    func renameRegister(procedureStart: UInt64, register: String, name: String?) {
        renameRegister(
            procedureStart: procedureStart,
            in: focusedImageSlot,
            register: register,
            name: name
        )
    }

    /// Slot-qualified implementation used by delayed UI requests. Capturing the slot separately
    /// from live focus prevents a sheet opened on one image from mutating another image that shares
    /// the same virtual procedure address.
    func renameRegister(
        procedureStart: UInt64,
        in imageSlot: ImageSlot,
        register: String,
        name: String?
    ) {
        let registerKey = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !registerKey.isEmpty else {
            lastIssue = "Provide a register identifier (e.g. x19)."
            return
        }
        let key = ImageAddress(slot: imageSlot, address: procedureStart)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        var names = override.registerNames ?? [:]
        if let normalized = Self.normalizedOverrideText(name) {
            names[registerKey] = normalized
        } else {
            names.removeValue(forKey: registerKey)
        }
        override.registerNames = names.isEmpty ? nil : names
        applyOverride(
            key,
            override,
            actionName: (name?.isEmpty ?? true) ? "Clear Register Name" : "Rename Register"
        )
    }

    /// DP04 C1: renames and/or retypes one stack local of the procedure at `procedureStart`,
    /// keyed by its entry-SP byte range. A nil field is left unchanged; an empty one clears
    /// it. Display edit only (undoable); it does not re-drive analysis.
    func editStackLocal(
        procedureStart: UInt64,
        in imageSlot: ImageSlot,
        entryRange: Range<Int64>,
        name: String?,
        typeName: String?
    ) {
        let localKey = MacIRStackStorage.authoringKey(for: entryRange)
        guard MacIRStackStorage.entryRange(forAuthoringKey: localKey) != nil else {
            lastIssue = "Provide a stack local's entry-SP byte range (e.g. -24:-16)."
            return
        }
        let key = ImageAddress(slot: imageSlot, address: procedureStart)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        var locals = override.stackLocals ?? [:]
        var edit = locals[localKey] ?? StackLocalOverride()
        if let name { edit.name = Self.normalizedOverrideText(name) }
        if let typeName { edit.typeName = Self.normalizedOverrideText(typeName) }
        if edit.normalized.isEmpty {
            locals.removeValue(forKey: localKey)
        } else {
            locals[localKey] = edit.normalized
        }
        override.stackLocals = locals.isEmpty ? nil : locals
        applyOverride(
            key,
            override,
            actionName: edit.normalized.isEmpty ? "Clear Stack Local" : "Edit Stack Local"
        )
    }

    /// Sets (or clears, when nil/empty) a LOCAL LABEL at `address` — a procedure-scoped name
    /// rendered in the listing/pseudocode within the enclosing procedure (distinct from a global
    /// symbol rename). Display-only; reversible; does NOT re-drive analysis.
    func setLocalLabel(_ address: UInt64, label: String?) {
        setLocalLabel(overrideKey(address), label: label)
    }

    /// Slot-qualified local-label edit for callers bound to an explicit command image
    /// (scripting's primary scope) rather than live focus. Same undo/dirty path.
    func setLocalLabel(_ address: UInt64, in slot: ImageSlot, label: String?) {
        setLocalLabel(ImageAddress(slot: slot, address: address), label: label)
    }

    private func setLocalLabel(_ key: ImageAddress, label: String?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.localLabel = Self.normalizedOverrideText(label)
        applyOverride(key, override, actionName: (label?.isEmpty ?? true) ? "Clear Local Label" : "Set Local Label")
    }

    /// Marks the address as data (`true`) or code (`false`, the default), registering
    /// a reversible Undo action. The listing renders data-marked rows as a data
    /// directive instead of a decoded instruction.
    func setIsData(_ address: UInt64, _ isData: Bool) {
        setIsData(address, in: focusedImageSlot, isData)
    }

    /// Slot-qualified mark-as-data for callers bound to an explicit command image (scripting's
    /// primary scope) rather than live focus. Same undo/dirty path; re-drives `slot`'s analysis.
    func setIsData(_ address: UInt64, in slot: ImageSlot, _ isData: Bool) {
        let key = ImageAddress(slot: slot, address: address)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.isData = isData
        applyOverride(key, override, actionName: isData ? "Mark as Data" : "Mark as Code")
    }

    /// Applies (or clears, when nil/empty) a DATA SHAPE at `address` — the Make Array /
    /// Make Alignment / Make String authoring types. A shaped address is data over its
    /// whole span, so this re-drives the analysis (see `registerAndApplyOverride`).
    /// Setting a shape also turns OFF the plain `isData` flag so the two never fight
    /// (the shape already implies data); clearing a shape leaves `isData` untouched.
    func setDataShape(_ address: UInt64, _ shape: DataShapeOverride?) {
        setDataShape(overrideKey(address), shape)
    }

    /// Slot-qualified data-shape edit for callers bound to an explicit command image
    /// (scripting's primary scope) rather than live focus. Same undo/dirty/re-analysis path.
    func setDataShape(_ address: UInt64, in slot: ImageSlot, _ shape: DataShapeOverride?) {
        setDataShape(ImageAddress(slot: slot, address: address), shape)
    }

    private func setDataShape(_ key: ImageAddress, _ shape: DataShapeOverride?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        let normalizedShape = (shape?.isEmpty ?? true) ? nil : shape
        override.dataShape = normalizedShape
        if normalizedShape != nil { override.isData = false }
        let actionName: String
        switch shape?.kind {
        case .array: actionName = "Make Array"
        case .alignment: actionName = "Make Alignment"
        case .string: actionName = "Make String"
        case nil: actionName = "Clear Data Shape"
        }
        applyOverride(key, override, actionName: actionName)
    }

    /// Makes the address an array of `count` elements of `elementType` (e.g. 16 ×
    /// int32_t). Surfaced by the command palette and the scripting `make-array` command.
    /// An optional `displayFormat` materializes each element's value in that radix/format
    /// (hex/dec/char/octal/binary/…) in the listing; nil renders the type signature only.
    func makeArray(_ address: UInt64, elementType: String?, count: Int, displayFormat: OperandFormat? = nil) {
        makeArray(address, in: focusedImageSlot, elementType: elementType, count: count, displayFormat: displayFormat)
    }

    /// Slot-qualified Make Array for callers bound to an explicit command image.
    func makeArray(_ address: UInt64, in slot: ImageSlot, elementType: String?, count: Int, displayFormat: OperandFormat? = nil) {
        setDataShape(address, in: slot, DataShapeOverride(kind: .array, elementType: elementType, elementCount: count, elementDisplayFormat: displayFormat))
    }

    /// Makes the address alignment padding to the given byte boundary (2/4/8/16…).
    func makeAlignment(_ address: UInt64, boundary: Int) {
        makeAlignment(address, in: focusedImageSlot, boundary: boundary)
    }

    /// Slot-qualified Make Alignment for callers bound to an explicit command image.
    func makeAlignment(_ address: UInt64, in slot: ImageSlot, boundary: Int) {
        setDataShape(address, in: slot, DataShapeOverride(kind: .alignment, alignment: boundary))
    }

    /// Makes the address a string: NUL-terminated C string (`length == nil`) or a
    /// fixed-length buffer (`length` bytes).
    func makeString(_ address: UInt64, length: Int? = nil) {
        makeString(address, in: focusedImageSlot, length: length)
    }

    /// Slot-qualified Make String for callers bound to an explicit command image.
    func makeString(_ address: UInt64, in slot: ImageSlot, length: Int? = nil) {
        if let length {
            setDataShape(address, in: slot, DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: length))
        } else {
            setDataShape(address, in: slot, DataShapeOverride(kind: .string, isNullTerminated: true))
        }
    }

    /// Marks the currently selected instruction as data / code. Surfaced by the
    /// command palette's "Mark as Data" / "Mark as Code" commands.
    func markSelectionAsData(_ isData: Bool) {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = isData ? "Select an instruction to mark as data." : "Select an instruction to mark as code."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.isData = isData
        applyOverride(target, override, actionName: isData ? "Mark as Data" : "Mark as Code")
    }

    /// Forces (`true`) or clears (`false`) a FUNCTION START at the address — the manual
    /// lever that splits a function discovery merged. Registers a reversible Undo and
    /// re-drives the analysis (see `registerAndApplyOverride`).
    func setMarkAsProcedure(_ address: UInt64, _ value: Bool) {
        setMarkAsProcedure(address, in: focusedImageSlot, value)
    }

    /// Slot-qualified Mark as Procedure for callers bound to an explicit command image
    /// (scripting's primary scope) rather than live focus. Same undo/dirty path; re-drives
    /// `slot`'s analysis.
    func setMarkAsProcedure(_ address: UInt64, in slot: ImageSlot, _ value: Bool) {
        let key = ImageAddress(slot: slot, address: address)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.markAsProcedure = value
        applyOverride(key, override, actionName: value ? "Mark as Function" : "Clear Function")
    }

    /// Forces a function start at the current selection. Surfaced by the command palette.
    func markSelectionAsProcedure(_ value: Bool) {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to mark as a function start."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.markAsProcedure = value
        applyOverride(target, override, actionName: value ? "Mark as Function" : "Clear Function")
    }

    // MARK: - Mark as Undefined (inverse of Mark as Procedure)

    /// Marks (`true`) or clears (`false`) the address as UNDEFINED — the inverse of
    /// Mark-as-Procedure: the span is removed from function/code analysis (re-driving
    /// discovery like mark-as-data) and the listing renders a raw `.byte` undefined
    /// directive. Reversible through the shared override path.
    func setMarkAsUndefined(_ address: UInt64, _ value: Bool) {
        setMarkAsUndefined(address, in: focusedImageSlot, value)
    }

    /// Slot-qualified Mark as Undefined for callers bound to an explicit command image
    /// (scripting's primary scope) rather than live focus. Same undo/dirty path; re-drives
    /// `slot`'s analysis.
    func setMarkAsUndefined(_ address: UInt64, in slot: ImageSlot, _ value: Bool) {
        let key = ImageAddress(slot: slot, address: address)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.isUndefined = value
        applyOverride(key, override, actionName: value ? "Mark as Undefined" : "Clear Undefined")
    }

    /// Marks the current selection as undefined / defined. Surfaced by the command palette.
    func markSelectionAsUndefined(_ value: Bool) {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to mark as undefined."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.isUndefined = value
        applyOverride(target, override, actionName: value ? "Mark as Undefined" : "Clear Undefined")
    }

    // MARK: - Patch bytes (instruction patch)

    /// Patches (or clears, when nil) the bytes at `address` with user-supplied replacement
    /// bytes. The listing/analysis RE-DECODE from the patched bytes; clearing restores the
    /// original. Re-drives analysis (the new encoding may change control flow). Reversible.
    @discardableResult
    func setPatch(_ address: UInt64, _ patch: BytePatch?) -> Bool {
        setPatch(address, in: focusedImageSlot, patch)
    }

    @discardableResult
    func setPatch(_ address: UInt64, in slot: ImageSlot, _ patch: BytePatch?) -> Bool {
        setPatch(ImageAddress(slot: slot, address: address), patch)
    }

    @discardableResult
    private func setPatch(_ key: ImageAddress, _ patch: BytePatch?) -> Bool {
        if let patch, !patch.isEmpty {
            do {
                // Reject malformed spans before mutation. Full mapping admission
                // belongs to the freshly loaded analysis input; the retained view
                // can be a partial/restoring snapshot. A later mapping failure is
                // surfaced by reanalysis and the edit remains undoable/correctable.
                _ = try BytePatchOverlay(patches: [key.address: patch])
            } catch {
                lastIssue = error.localizedDescription
                return false
            }
        }
        let previous = snapshot.addressOverrides[key]
        var override = previous ?? AddressOverride()
        override.patch = (patch?.isEmpty ?? true) ? nil : patch
        let updated: AddressOverride? = override.isEmpty ? nil : override
        lastIssue = nil
        if updated == previous, !(patch?.isEmpty ?? true) {
            // A retry of a failed edit must not clear its issue and then take
            // applyOverride's no-change fast path without validating the bytes.
            reanalyzeHonoringOverrides(in: key.slot)
        } else {
            applyOverride(key, updated, actionName: patch == nil ? "Clear Patch" : "Patch Bytes")
        }
        return true
    }

    /// Commits a delayed Patch Bytes sheet against its immutable image and binary owner. The
    /// published-request equality guard rejects callbacks from a canceled or replaced sheet;
    /// instruction membership and binary identity then reject removal, remap, or replacement.
    /// Only an accepted patch dismisses the request.
    @discardableResult
    func patchBytes(_ request: PatchBytesRequest, hex: String) -> Bool {
        guard authoringPresentationIsCurrent(request.presentationID),
              pendingPatchBytesRequest == request,
              hasRequestOwnedInstruction(
                request.target,
                ownerBinaryID: request.ownerBinaryID
              ) else {
            invalidateAuthoringPresentation(request.presentationID)
            rejectStaleAuthoringRequest(
                "The instruction that owned this patch request is no longer available."
            )
            return false
        }
        guard let patch = BytePatch.parse(hex: hex) else {
            lastIssue = "Invalid hex bytes — enter an even number of hex digits (e.g. 1f 20 03 d5)."
            return false
        }
        guard setPatch(request.target, patch) else { return false }
        invalidateAuthoringPresentation(request.presentationID)
        pendingPatchBytesRequest = nil
        return true
    }

    /// Cancels only the exact Patch Bytes presentation whose callback fired. Clearing the
    /// request drives `.sheet(item:)` dismissal; a late callback from a replaced sheet is inert.
    func cancelPatchBytes(_ request: PatchBytesRequest) {
        guard pendingPatchBytesRequest == request else { return }
        invalidateAuthoringPresentation(request.presentationID)
        pendingPatchBytesRequest = nil
    }

    /// Focused compatibility wrapper for synchronous callers. A delayed presentation must commit
    /// through its qualified request; a bare callback cannot prove that it owns whichever sheet is
    /// now current, even when the virtual address happens to match.
    @discardableResult
    func patchBytes(_ address: UInt64, hex: String) -> Bool {
        guard pendingPatchBytesRequest == nil else {
            lastIssue = "Finish or cancel the active Patch Bytes request before applying a direct patch."
            return false
        }
        let target = ImageAddress(slot: focusedImageSlot, address: address)
        guard hasInstruction(target) else {
            lastIssue = "Select an instruction to patch."
            return false
        }
        guard let patch = BytePatch.parse(hex: hex) else {
            lastIssue = "Invalid hex bytes — enter an even number of hex digits (e.g. 1f 20 03 d5)."
            return false
        }
        return setPatch(target, patch)
    }

    /// True when the focused target is x86_64 — selects the x86 assembler and NOP for immediate
    /// (non-sheet) byte authoring. A delayed Assemble sheet resolves its captured slot separately.
    private var isX86_64Target: Bool {
        isX86_64Target(in: focusedImageSlot)
    }

    private func isX86_64Target(in slot: ImageSlot) -> Bool {
        (snapshot.binary(in: slot)?.architecture ?? "").lowercased().hasPrefix("x86_64")
    }

    /// Human label for the Assemble sheet — the architecture the typed instruction is
    /// encoded for (i.e. which assembler `assemble(at:text:)` will use).
    var assemblyArchitectureLabel: String {
        let slot = pendingAssembleRequest?.target.slot ?? focusedImageSlot
        return isX86_64Target(in: slot) ? "x86-64" : "ARM64"
    }

    /// Neutralizes the entire selected instruction without moving later bytes.
    /// Each x86 byte becomes 0x90; ARM64 retains its four-byte architectural NOP.
    @discardableResult
    func patchNOP(_ address: UInt64) -> Bool {
        patchNOP(address, in: focusedImageSlot)
    }

    @discardableResult
    func patchNOP(_ address: UInt64, in slot: ImageSlot) -> Bool {
        let target = ImageAddress(slot: slot, address: address)
        guard let row = snapshot.instruction(at: target),
              let instructionBytes = BytePatch.parse(hex: row.bytes),
              !instructionBytes.isEmpty else {
            lastIssue = "Select a decoded instruction with known bytes to replace with NOP."
            return false
        }
        let (end, overflow) = address.addingReportingOverflow(UInt64(instructionBytes.bytes.count))
        guard !overflow else {
            lastIssue = "The selected instruction extends beyond the address space."
            return false
        }
        guard !snapshot.patches(in: target.slot).contains(where: {
            !$0.value.isEmpty && $0.key > address && $0.key < end
        }) else {
            lastIssue = "Clear the overlapping interior byte patches before replacing this instruction with NOP."
            return false
        }
        let patch = isX86_64Target(in: slot)
            ? BytePatch(bytes: Array(repeating: 0x90, count: instructionBytes.bytes.count))
            : BytePatch.arm64NOP
        return setPatch(target, patch)
    }

    /// Clears any patch at `address`, restoring the original bytes.
    func clearPatch(_ address: UInt64) {
        clearPatch(address, in: focusedImageSlot)
    }

    func clearPatch(_ address: UInt64, in slot: ImageSlot) {
        setPatch(address, in: slot, nil)
    }

    /// Patches the current selection from a hex string. A no-op (surfaced issue) when
    /// nothing is selected. Returns true when the patch applied.
    @discardableResult
    func patchSelection(hex: String) -> Bool {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to patch."
            return false
        }
        guard let patch = BytePatch.parse(hex: hex) else {
            lastIssue = "Invalid hex bytes — enter an even number of hex digits (e.g. 1f 20 03 d5)."
            return false
        }
        return setPatch(target, patch)
    }

    /// Assembles a single instruction from `text` and applies it as a reversible byte patch
    /// at `address` — the File ▸ Assemble Instruction… path. The assembler is chosen by the
    /// loaded target's architecture (`X86_64Assembler` for x86_64, `ARM64Assembler`
    /// otherwise), so an x86 binary encodes x86 text rather than silently mis-parsing it as
    /// ARM64. The address is consulted only for PC-relative forms. On success the encoded
    /// bytes replace the instruction through the canonical patch model (undoable, re-decoded
    /// + re-analyzed). On failure it surfaces the assembler's precise diagnostic via
    /// `lastIssue` and applies nothing, so a mistyped instruction can never leave a garbage
    /// patch behind.
    @discardableResult
    func assemble(_ request: AssembleRequest, text: String) -> Bool {
        guard authoringPresentationIsCurrent(request.presentationID),
              pendingAssembleRequest == request,
              hasRequestOwnedInstruction(
                request.target,
                ownerBinaryID: request.ownerBinaryID
              ) else {
            invalidateAuthoringPresentation(request.presentationID)
            rejectStaleAuthoringRequest(
                "The instruction that owned this assembly request is no longer available."
            )
            return false
        }
        guard assembleInstruction(text, at: request.target) else { return false }
        invalidateAuthoringPresentation(request.presentationID)
        pendingAssembleRequest = nil
        return true
    }

    /// Cancels only the exact Assemble presentation whose callback fired. A callback retained by
    /// an older sheet cannot dismiss a replacement request at the same virtual address.
    func cancelAssemble(_ request: AssembleRequest) {
        guard pendingAssembleRequest == request else { return }
        invalidateAuthoringPresentation(request.presentationID)
        pendingAssembleRequest = nil
    }

    /// Focused compatibility wrapper for synchronous callers. Active sheet work is deliberately
    /// rejected: without the presentation token a delayed callback cannot distinguish its opening
    /// request from a same-address replacement.
    @discardableResult
    func assemble(at address: UInt64, text: String) -> Bool {
        guard pendingAssembleRequest == nil else {
            lastIssue = "Finish or cancel the active Assemble request before assembling directly."
            return false
        }
        let target = ImageAddress(slot: focusedImageSlot, address: address)
        guard hasInstruction(target) else {
            lastIssue = "Select an instruction to assemble."
            return false
        }
        return assembleInstruction(text, at: target)
    }

    private func assembleInstruction(_ text: String, at target: ImageAddress) -> Bool {
        let bytes: [UInt8]?
        let diagnostic: String?
        if isX86_64Target(in: target.slot) {
            switch X86_64Assembler().assemble(text, at: target.address) {
            case let .success(encoded): bytes = encoded; diagnostic = nil
            case let .failure(reason): bytes = nil; diagnostic = reason.description
            }
        } else {
            let binary = snapshot.binary(in: target.slot)
            let architecture = binary.flatMap {
                ARM64AssemblyArchitecture.resolve(
                    architectureDisplayName: $0.architecture,
                    artifactVariant: $0.artifactIdentity?.architectureVariant
                )
            }
            switch ARM64AssemblyRouter(
                fallback: SwiftAssemblyARM64FallbackBackend()
            ).assemble(text, at: target.address, architecture: architecture) {
            case let .success(product):
                bytes = product.bytes
                diagnostic = nil
            case let .failure(reason):
                bytes = nil
                diagnostic = reason.description
            }
        }
        if let bytes {
            return setPatch(target, BytePatch(bytes: bytes))
        }
        lastIssue = "Couldn’t assemble: \(diagnostic ?? "unknown error")"
        return false
    }

    // MARK: - In-pane hex editing

    /// Applies a single-byte edit from the hex pane, preserving any covering patch span,
    /// routed through the canonical `setPatch` so it is undoable, persisted, re-decoded into
    /// the listing, and rendered with the existing patched highlight. This is the ONLY new
    /// store entry the editable hex pane needs — it reuses the patch model rather than
    /// introducing a parallel byte-store. Existing unrelated patch bytes remain authoritative.
    @discardableResult
    func patchByte(at address: UInt64, value: UInt8) -> Bool {
        // The highest-address covering edit wins in BytePatchOverlay. Update that
        // edit in place so a cell change never truncates a surrounding patch or
        // introduces a new overlapping span.
        let patches = snapshot.patches(in: focusedImageSlot)
        if let owner = patches.keys.sorted().last(where: { start in
            guard let patch = patches[start], address >= start else { return false }
            return address - start < UInt64(patch.bytes.count)
        }), let patch = patches[owner] {
            var bytes = patch.bytes
            bytes[Int(address - owner)] = value
            return setPatch(owner, BytePatch(bytes: bytes))
        }
        return setPatch(address, BytePatch(bytes: [value]))
    }

    /// The `HexEditModel` over the current hex window, the single place the offset→address
    /// mapping lives (used by both the typed-text and per-offset edit entries below).
    private func hexEditModel() -> HexEditModel {
        let window = hexWindowRange()
        return HexEditModel(bytes: hexWindowSourceBytes(range: window),
                            mappings: Self.rebasedMappings(snapshot.imageByteMappings(in: focusedImageSlot), to: window))
    }

    /// The verified mappings the hex pane renders and edits through (the FOCUSED image's),
    /// rebased to the current window: offset 0 is the window's first byte, so every window
    /// offset the pane, its edit model and its callbacks use is a mapping file offset.
    var hexWindowMappings: [FileAddressMapping] {
        Self.rebasedMappings(snapshot.imageByteMappings(in: focusedImageSlot), to: hexWindowRange())
    }

    // MARK: Hex window (MS-10)

    /// The hex pane's bytes: a window over the FULL persisted slice (`imageBytes`) that follows the
    /// selection, instead of the fixed 4 KiB prefix (`hexBytes`). A slice smaller than the window
    /// shows whole; a snapshot without `imageBytes` falls back to the legacy prefix.
    static let hexPaneWindowByteCount = 64 * 1024
    /// The window moves only when the selection comes within this many bytes of an edge, so caret
    /// moves inside the window never re-render it.
    static let hexPaneWindowMargin = 1024
    private var hexWindowStartBySlot: [ImageSlot: Int] = [:]

    /// The size of what the hex window is cut from (the full slice, or the legacy prefix).
    var hexSliceByteCount: Int { hexWindowSource.count }

    /// The bytes the window is cut from: the full slice when it is loaded, else the prefix.
    private var hexWindowSource: Data {
        let analysis = snapshot.analysis(in: focusedImageSlot)
        if let full = analysis?.imageBytes, !full.isEmpty { return full }
        return analysis?.hexBytes ?? Data()
    }

    /// The slice-relative byte range the hex pane shows now. Stable while the selection stays
    /// inside it (with a margin); re-centred, row-aligned, when the selection leaves it.
    private func setPatternAwareHexWindowStart(_ start: Int, for slot: ImageSlot) {
        if hexWindowStartBySlot[slot] != start {
            revokePatternPublication()
            hexWindowStartBySlot[slot] = start
        }
    }

    func hexWindowRange() -> Range<Int> {
        let total = hexWindowSource.count
        let size = Self.hexPaneWindowByteCount
        guard total > size else {
            setPatternAwareHexWindowStart(0, for: focusedImageSlot)
            return 0..<total
        }
        let maxStart = total - size
        var start = min(hexWindowStartBySlot[focusedImageSlot] ?? 0, maxStart)
        if let selected = selectedImageAddress, selected.slot == focusedImageSlot,
           let fileOffset = FileAddressMapping.resolvedFileOffset(
               forVirtualAddress: selected.address,
               in: snapshot.imageByteMappings(in: focusedImageSlot)
           ), fileOffset < UInt64(total) {
            let offset = Int(fileOffset)
            let margin = Self.hexPaneWindowMargin
            let lowOK = offset >= start + margin || start == 0
            let highOK = offset < start + size - margin || start == maxStart
            if !(lowOK && highOK) || offset < start || offset >= start + size {
                let row = AppEditorChrome.hexBytesPerRow
                let centred = max(0, offset - size / 2)
                start = min(maxStart, centred - centred % row)
            }
        }
        setPatternAwareHexWindowStart(start, for: focusedImageSlot)
        return start..<(start + size)
    }

    private func hexWindowSourceBytes(range: Range<Int>) -> Data {
        let source = hexWindowSource
        guard !range.isEmpty, range.upperBound <= source.count else { return Data() }
        return Data(source[(source.startIndex + range.lowerBound)..<(source.startIndex + range.upperBound)])
    }

    /// `mappings` clipped to `window` and shifted so the window's first byte is file offset 0.
    /// Each run keeps its virtual address for the bytes it still covers, so aliases and gaps
    /// resolve exactly as they did against the whole slice.
    static func rebasedMappings(_ mappings: [FileAddressMapping], to window: Range<Int>) -> [FileAddressMapping] {
        let low = UInt64(window.lowerBound), high = UInt64(window.upperBound)
        return mappings.compactMap { mapping in
            guard mapping.isWellFormed else { return nil }
            let start = max(mapping.fileOffset, low)
            let end = min(mapping.fileOffset + mapping.size, high)
            guard start < end else { return nil }
            return FileAddressMapping(
                fileOffset: start - low,
                size: end - start,
                virtualAddress: mapping.virtualAddress + (start - mapping.fileOffset),
                sectionName: mapping.sectionName
            )
        }
    }

    /// True when the current hex window has at least one uniquely-mapped, editable cell.
    /// A freshly analyzed binary is editable; a reloaded snapshot (no derived mappings this
    /// stage) is read-only, so a typed byte can never be written to a fabricated address.
    var isHexWindowEditable: Bool { !hexEditModel().isReadOnly }

    /// Resolves and applies a hex-pane edit from a full two-digit hex string: maps the offset to
    /// a virtual address through `HexEditModel`'s verified mapping table and writes a 1-byte
    /// patch on success. Invalid hex / out-of-range / an unmapped cell / a read-only window are
    /// surfaced via `lastIssue` and change nothing. Returns true when a patch was applied. The
    /// validation stays in one tested place.
    @discardableResult
    func applyHexEdit(offset: Int, hexByte input: String) -> Bool {
        switch hexEditModel().resolveEdit(offset: offset, hexByte: input) {
        case let .patch(address, byte):
            return patchByte(at: address, value: byte)
        case .invalidInput:
            lastIssue = "Invalid hex byte — enter exactly two hex digits (e.g. 4f)."
            return false
        case .outOfRange:
            lastIssue = "That byte is outside the loaded hex window."
            return false
        case .unmapped:
            lastIssue = "That byte has no verified virtual address and can’t be edited."
            return false
        case .readOnly:
            lastIssue = "No document is loaded to edit."
            return false
        }
    }

    /// Applies an already-validated byte value at a window offset (the per-keystroke path the
    /// AppKit bridge uses, where nibble composition + hex validation happened in the view's
    /// `HexEditModel`). Maps the offset to a virtual address and writes a 1-byte patch. Returns
    /// true when applied (a valid, in-range, editable offset).
    @discardableResult
    func applyHexByteEdit(offset: Int, value: UInt8) -> Bool {
        guard let address = hexEditModel().address(forOffset: offset) else {
            lastIssue = "That byte is outside the loaded hex window."
            return false
        }
        return patchByte(at: address, value: value)
    }

    /// The current hex window (see `hexWindowRange()`) with completely mapped edits applied in
    /// the same order as analysis; offsets are window-relative. An invalid persisted edit never
    /// paints a partial patch across a gap; reanalysis surfaces the failure and retains it for
    /// correction.
    func patchedHexWindow() -> (bytes: Data, patchedOffsets: Set<Int>) {
        let window = hexWindowRange()
        var bytes = hexWindowSourceBytes(range: window)
        guard !bytes.isEmpty else { return (bytes, []) }
        let mappings = snapshot.imageByteMappings(in: focusedImageSlot)
        guard let overlay = try? BytePatchOverlay(
            patches: snapshot.patches(in: focusedImageSlot), mappings: mappings
        ) else { return (bytes, []) }
        var patchedOffsets = Set<Int>()
        for edit in overlay.edits {
            guard let range = FileAddressMapping.resolvedFileRange(
                forVirtualAddress: edit.address, count: edit.bytes.count, in: mappings
            ) else { continue }
            // Clip the edit's slice range to the window, then shift it to window offsets.
            let low = max(range.lowerBound, window.lowerBound)
            let high = min(range.upperBound, window.upperBound)
            guard low < high else { continue }
            let skip = low - range.lowerBound
            let start = bytes.startIndex + (low - window.lowerBound)
            bytes.replaceSubrange(start..<(start + (high - low)),
                                  with: edit.bytes.dropFirst(skip).prefix(high - low))
            patchedOffsets.formUnion((low - window.lowerBound)..<(high - window.lowerBound))
        }
        return (bytes, patchedOffsets)
    }

    // MARK: - Manual cross-references (add / suppress)

    /// Adds a user cross-reference the recovery missed (`from -> to`, `kind`). Reversible.
    /// A no-op when an identical ADD already exists.
    func addManualXRef(from: UInt64, to: UInt64, kind: String) {
        addManualXRef(from: from, to: to, kind: kind, in: focusedImageSlot)
    }

    /// Slot-qualified form for callers bound to an explicit command image (scripting's primary
    /// scope) rather than live focus. The focused overload above forwards here unchanged.
    func addManualXRef(from: UInt64, to: UInt64, kind: String, in imageSlot: ImageSlot) {
        let key = XRefEndpointKey(from: from, to: to, kind: kind)
        guard !snapshot.manualXRefs.contains(where: {
            $0.imageSlot == imageSlot && !$0.isSuppression && $0.endpointKey == key
        }) else { return }
        var next = snapshot.manualXRefs
        // A new ADD overrides a prior SUPPRESSION of the same endpoint (the user changed
        // their mind) so the two never linger and fight.
        next.removeAll { $0.imageSlot == imageSlot && $0.isSuppression && $0.endpointKey == key }
        next.append(ManualXRef(
            from: from, to: to, kind: kind, isSuppression: false, imageSlot: imageSlot
        ))
        applyManualXRefs(next, in: imageSlot, actionName: "Add Cross-Reference")
    }

    /// Suppresses a spurious recovered cross-reference (`from -> to`, `kind`). Reversible.
    /// A no-op when an identical SUPPRESSION already exists.
    func suppressXRef(from: UInt64, to: UInt64, kind: String) {
        suppressXRef(from: from, to: to, kind: kind, in: focusedImageSlot)
    }

    /// Slot-qualified form for callers bound to an explicit command image (scripting's primary
    /// scope) rather than live focus. The focused overload above forwards here unchanged.
    func suppressXRef(from: UInt64, to: UInt64, kind: String, in imageSlot: ImageSlot) {
        let key = XRefEndpointKey(from: from, to: to, kind: kind)
        guard !snapshot.manualXRefs.contains(where: {
            $0.imageSlot == imageSlot && $0.isSuppression && $0.endpointKey == key
        }) else { return }
        var next = snapshot.manualXRefs
        // A SUPPRESSION removes any prior ADD of the same endpoint (they cancel).
        next.removeAll { $0.imageSlot == imageSlot && !$0.isSuppression && $0.endpointKey == key }
        next.append(ManualXRef(
            from: from, to: to, kind: kind, isSuppression: true, imageSlot: imageSlot
        ))
        applyManualXRefs(next, in: imageSlot, actionName: "Suppress Cross-Reference")
    }

    /// Removes a manual xref edit (an add or a suppression) by its id, restoring the
    /// recovered default for that endpoint. Reversible. A no-op when the id is unknown.
    func removeManualXRef(id: UUID) {
        guard let imageSlot = snapshot.manualXRefs.first(where: { $0.id == id })?.imageSlot else {
            return
        }
        var next = snapshot.manualXRefs
        next.removeAll { $0.id == id }
        applyManualXRefs(next, in: imageSlot, actionName: "Remove Cross-Reference Edit")
    }

    /// Replaces the manual-xref list as one undoable step. No re-analysis: manual xrefs are
    /// merged at QUERY time (`effectiveXRefs`), so they don't change the derived analysis.
    private func applyManualXRefs(
        _ next: [ManualXRef],
        in imageSlot: ImageSlot,
        actionName: String
    ) {
        let value = next.filter { $0.imageSlot == imageSlot }
        let previous = snapshot.manualXRefs.filter { $0.imageSlot == imageSlot }
        guard value != previous else { return }
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        registerAndApplyManualXRefs(value, previous: previous, in: imageSlot)
        mirrorAnalystXRefs(value, previous: previous, in: imageSlot)
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
    }

    private func registerAndApplyManualXRefs(
        _ value: [ManualXRef],
        previous: [ManualXRef],
        in imageSlot: ImageSlot
    ) {
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        undoManager.registerUndo(withTarget: undoTargetForRegistration(in: imageSlot)) { target in
            guard let store = target.store else { return }
            store.registerAndApplyManualXRefs(previous, previous: value, in: imageSlot)
            store.restoreDocumentDirtyToken(priorToken)
        }
        snapshot.manualXRefs.removeAll { $0.imageSlot == imageSlot }
        snapshot.manualXRefs.append(contentsOf: value)
    }

    // MARK: - Bookmarks

    /// Adds (or renames, when one already sits there) a named bookmark at `address`.
    /// Reversible. An empty name is a bare marker.
    func addBookmark(at address: UInt64, name: String) {
        addBookmark(at: address, in: focusedImageSlot, name: name)
    }

    /// Slot-qualified form for callers bound to an explicit command image (scripting's primary
    /// scope) rather than live focus. The focused overload above forwards here unchanged.
    func addBookmark(at address: UInt64, in imageSlot: ImageSlot, name: String) {
        var next = snapshot.bookmarks
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = next.firstIndex(where: { $0.imageSlot == imageSlot && $0.address == address }) {
            guard next[index].name != trimmed else { return }
            next[index].name = trimmed
        } else {
            next.append(Bookmark(address: address, imageSlot: imageSlot, name: trimmed))
        }
        applyBookmarks(next, in: imageSlot, actionName: "Add Bookmark")
    }

    /// Removes the bookmark at `address` (if any). Reversible.
    func removeBookmark(at address: UInt64) {
        removeBookmark(at: address, in: focusedImageSlot)
    }

    /// Slot-qualified form for callers bound to an explicit command image (scripting's primary
    /// scope) rather than live focus. The focused overload above forwards here unchanged.
    func removeBookmark(at address: UInt64, in imageSlot: ImageSlot) {
        guard snapshot.bookmarks.contains(where: {
            $0.imageSlot == imageSlot && $0.address == address
        }) else { return }
        var next = snapshot.bookmarks
        next.removeAll { $0.imageSlot == imageSlot && $0.address == address }
        applyBookmarks(next, in: imageSlot, actionName: "Remove Bookmark")
    }

    /// Bookmarks the current selection. A no-op (surfaced issue) when nothing is selected.
    func addBookmarkAtSelection(name: String = "") {
        guard let address = selectedAddress else {
            lastIssue = "Select an address to bookmark."
            return
        }
        addBookmark(at: address, name: name)
    }

    /// Navigates to the bookmark at `address` (records it in history). A no-op (surfaced
    /// issue) when there is no bookmark there.
    func navigateToBookmark(at address: UInt64) {
        let imageSlot = focusedImageSlot
        guard snapshot.bookmarks.contains(where: {
            $0.imageSlot == imageSlot && $0.address == address
        }) else {
            lastIssue = "No bookmark at that address."
            return
        }
        navigateToReference(address)
    }

    // MARK: - Analysis diagnostics (Problems panel)

    /// The analysis-level diagnostics for the focused image (derived, recomputed on each
    /// analysis). Surfaced read-only to the Problems panel.
    var diagnostics: [AnalysisDiagnostic] { focusedAnalysis?.diagnostics ?? [] }

    /// Jumps the editor to a diagnostic's address. Routed through `navigateToReference`, so a
    /// diagnostic anchored on a non-instruction address (a dangling branch/xref target) still
    /// lands — the editor falls back to the hex view when no decoded row matches.
    @discardableResult
    func navigateToDiagnostic(_ diagnostic: AnalysisDiagnostic) -> Bool {
        navigateToDiagnostic(id: diagnostic.id, in: focusedImageSlot)
    }

    /// Captures the current binary owner together with the deterministic diagnostic entity id.
    func diagnosticNavigationTarget(
        id: String,
        in slot: ImageSlot
    ) -> DiagnosticNavigationTarget? {
        guard isCurrentRequestOwner(slot, ownerBinaryID: snapshot.binary(in: slot)?.id),
              snapshot.analysis(in: slot)?.diagnostics.contains(where: { $0.id == id }) == true else {
            return nil
        }
        return DiagnosticNavigationTarget(
            diagnosticID: id,
            imageSlot: slot,
            ownerBinaryID: snapshot.binary(in: slot)?.id
        )
    }

    /// Accepts only a diagnostic still present in the exact image projection that rendered it.
    /// A queued row from an old focus or reanalysis generation is a guarded no-op.
    @discardableResult
    func navigateToDiagnostic(id: String, in slot: ImageSlot) -> Bool {
        guard let target = diagnosticNavigationTarget(id: id, in: slot) else {
            return false
        }
        return navigateToDiagnostic(target)
    }

    @discardableResult
    func navigateToDiagnostic(_ target: DiagnosticNavigationTarget) -> Bool {
        guard target.imageSlot == focusedImageSlot,
              isCurrentRequestOwner(
                  target.imageSlot,
                  ownerBinaryID: target.ownerBinaryID
              ),
              let diagnostic = snapshot.analysis(in: target.imageSlot)?.diagnostics.first(where: {
                  $0.id == target.diagnosticID
              }) else {
            return false
        }
        return navigateToReference(
            ImageAddress(slot: target.imageSlot, address: diagnostic.address)
        )
    }

    /// Replaces the bookmark list as one undoable step. No re-analysis (bookmarks are
    /// navigation metadata, not part of the derived analysis).
    private func applyBookmarks(
        _ next: [Bookmark],
        in imageSlot: ImageSlot,
        actionName: String
    ) {
        let value = next.filter { $0.imageSlot == imageSlot }
        let previous = snapshot.bookmarks.filter { $0.imageSlot == imageSlot }
        guard value != previous else { return }
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        registerAndApplyBookmarks(value, previous: previous, in: imageSlot)
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
    }

    private func registerAndApplyBookmarks(
        _ value: [Bookmark],
        previous: [Bookmark],
        in imageSlot: ImageSlot
    ) {
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        undoManager.registerUndo(withTarget: undoTargetForRegistration(in: imageSlot)) { target in
            guard let store = target.store else { return }
            store.registerAndApplyBookmarks(previous, previous: value, in: imageSlot)
            store.restoreDocumentDirtyToken(priorToken)
        }
        snapshot.bookmarks.removeAll { $0.imageSlot == imageSlot }
        snapshot.bookmarks.append(contentsOf: value)
    }

    // MARK: - Segment overrides (rename / rebase)

    /// Renames a segment/section's DISPLAYED name. `sectionName` is the section's ORIGINAL
    /// name (the stable key). An empty `displayName` clears the rename (keeping any rebase).
    /// Reversible. A no-op (surfaced issue) when no such section exists, so a typo'd name
    /// never silently creates a dangling override.
    func renameSegment(sectionName: String, displayName: String) {
        let imageSlot = focusedImageSlot
        guard snapshot.analysis(in: imageSlot)?.sections.contains(where: {
            $0.name == sectionName
        }) == true else {
            lastIssue = "No section named \(sectionName)."
            return
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSegmentOverride(forSection: sectionName, actionName: "Rename Segment") { override in
            override.displayName = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Sets a REBASE delta on a segment/section: a signed byte offset added to the
    /// section's displayed addresses (0 clears the rebase, keeping any rename). The
    /// underlying analysis is untouched — only the displayed addresses shift. Reversible.
    /// A no-op (surfaced issue) when no such section exists.
    func rebaseSegment(sectionName: String, delta: Int64) {
        let imageSlot = focusedImageSlot
        guard snapshot.analysis(in: imageSlot)?.sections.contains(where: {
            $0.name == sectionName
        }) == true else {
            lastIssue = "No section named \(sectionName)."
            return
        }
        updateSegmentOverride(forSection: sectionName, actionName: "Rebase Segment") { override in
            override.rebaseDelta = delta
        }
    }

    /// Clears any rename + rebase on a section (removing the override entirely). Reversible.
    func clearSegmentOverride(sectionName: String) {
        let imageSlot = focusedImageSlot
        guard snapshot.segmentOverrides.contains(where: {
            $0.imageSlot == imageSlot && $0.originalName == sectionName
        }) else { return }
        var next = snapshot.segmentOverrides
        next.removeAll { $0.imageSlot == imageSlot && $0.originalName == sectionName }
        applySegmentOverrides(next, in: imageSlot, actionName: "Clear Segment Override")
    }

    /// Mutates (or creates) the override for `sectionName` via `transform`, then prunes it
    /// if the result is empty (no rename and no rebase), so a cleared override never lingers
    /// as a no-op record — mirroring the address-override prune rule.
    private func updateSegmentOverride(
        forSection sectionName: String,
        actionName: String,
        _ transform: (inout SegmentOverride) -> Void
    ) {
        let imageSlot = focusedImageSlot
        var next = snapshot.segmentOverrides
        if let index = next.firstIndex(where: {
            $0.imageSlot == imageSlot && $0.originalName == sectionName
        }) {
            transform(&next[index])
            if next[index].isEmpty { next.remove(at: index) }
        } else {
            var override = SegmentOverride(originalName: sectionName, imageSlot: imageSlot)
            transform(&override)
            if !override.isEmpty { next.append(override) }
        }
        applySegmentOverrides(next, in: imageSlot, actionName: actionName)
    }

    /// Replaces the segment-override list as one undoable step. No re-analysis: segment
    /// overrides are a pure DISPLAY projection (applied via `effectiveSections()`), not part
    /// of the derived analysis — exactly like bookmarks.
    private func applySegmentOverrides(
        _ next: [SegmentOverride],
        in imageSlot: ImageSlot,
        actionName: String
    ) {
        let value = next.filter { $0.imageSlot == imageSlot }
        let previous = snapshot.segmentOverrides.filter { $0.imageSlot == imageSlot }
        guard value != previous else { return }
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        registerAndApplySegmentOverrides(value, previous: previous, in: imageSlot)
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
    }

    private func registerAndApplySegmentOverrides(
        _ value: [SegmentOverride],
        previous: [SegmentOverride],
        in imageSlot: ImageSlot
    ) {
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        undoManager.registerUndo(withTarget: undoTargetForRegistration(in: imageSlot)) { target in
            guard let store = target.store else { return }
            store.registerAndApplySegmentOverrides(previous, previous: value, in: imageSlot)
            store.restoreDocumentDirtyToken(priorToken)
        }
        snapshot.segmentOverrides.removeAll { $0.imageSlot == imageSlot }
        snapshot.segmentOverrides.append(contentsOf: value)
    }

    // MARK: - Next Code / Data / Unexplored navigation

    /// Jumps to the next *code* address after the current selection (the next decoded,
    /// not-data instruction). A no-op (surfaced issue) when there is no further code.
    func navigateToNextCode() {
        let target = AddressNavigation.nextCode(
            after: selectedAddress,
            instructionAddresses: snapshot.instructions.map(\.address),
            dataAddresses: snapshot.dataMarkedAddresses(in: snapshot.primarySlot)
        )
        navigateToNextResult(target, noneMessage: "No further code below the selection.")
    }

    /// Jumps to the next *data* address after the current selection (a mark-as-data /
    /// data-shape address, or a recovered string literal). A no-op when there is none.
    func navigateToNextData() {
        let target = AddressNavigation.nextData(
            after: selectedAddress,
            dataAddresses: snapshot.dataMarkedAddresses(in: snapshot.primarySlot)
        )
        navigateToNextResult(target, noneMessage: "No further data below the selection.")
    }

    /// Jumps to the next *unexplored* address after the current selection (the start of
    /// the next gap with no decoded instruction and no data mark). A no-op when every
    /// remaining loaded address is already explored.
    func navigateToNextUnexplored() {
        let target = AddressNavigation.nextUnexplored(
            after: selectedAddress,
            instructionExtents: snapshot.instructionExtents(),
            dataAddresses: snapshot.dataMarkedAddresses(in: snapshot.primarySlot),
            coverageSpans: snapshot.executableSpans()
        )
        navigateToNextResult(target, noneMessage: "No unexplored region below the selection.")
    }

    /// Shared tail for the three Next-* commands: navigate to `target` (recording it in
    /// history) or surface `noneMessage` when there is no next address.
    private func navigateToNextResult(_ target: UInt64?, noneMessage: String) {
        guard let target else {
            lastIssue = noneMessage
            return
        }
        navigateToReference(target)
    }

    // MARK: - Truncate / Select Procedure

    /// Truncates the function enclosing `address` so its end falls at `address` — the
    /// manual lever that bounds an over-extended function. Implemented by forcing a
    /// FUNCTION START at the truncation address (which slices the prior function to end
    /// there), reusing the procedure-start re-drive so discovery re-runs for the bounded
    /// function. Undoable through the shared override path. Validates the bounds first:
    /// a truncation point at/before the start or at/beyond the current end is a no-op
    /// (surfaced issue) rather than producing a degenerate function.
    func truncateProcedure(at address: UInt64) {
        truncateProcedure(at: ImageAddress(slot: focusedImageSlot, address: address))
    }

    private func truncateProcedure(at target: ImageAddress) {
        let functions = snapshot.analysis(in: target.slot)?.functions ?? []
        guard hasInstruction(target),
              ProcedureRange.truncatedBounds(at: target.address, functions: functions) != nil else {
            lastIssue = "Cannot truncate a function here."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.markAsProcedure = true
        applyOverride(target, override, actionName: "Mark as Function")
    }

    /// Truncates the function enclosing the current selection at the selected address.
    func truncateProcedureAtSelection() {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to truncate its function."
            return
        }
        truncateProcedure(at: target)
    }

    /// Selects the whole `[start, end)` address range of the function enclosing
    /// `address`: moves the cursor to the function start and records it in history.
    /// Returns the selected range (nil when no function encloses the address).
    @discardableResult
    func selectProcedure(at address: UInt64) -> ProcedureRange.Range? {
        selectProcedure(at: ImageAddress(slot: focusedImageSlot, address: address))
    }

    @discardableResult
    private func selectProcedure(at target: ImageAddress) -> ProcedureRange.Range? {
        let functions = snapshot.analysis(in: target.slot)?.functions ?? []
        guard let range = ProcedureRange.selectRange(for: target.address, functions: functions) else {
            lastIssue = "No function encloses this address."
            return nil
        }
        guard target.slot == focusedImageSlot else {
            lastIssue = "The selected function is no longer in the focused image."
            return nil
        }
        navigateToReference(range.start)
        return range
    }

    /// Selects the enclosing function's range for the current selection.
    @discardableResult
    func selectProcedureAtSelection() -> ProcedureRange.Range? {
        guard let target = selectedImageAddress else {
            lastIssue = "Select an instruction to select its function."
            return nil
        }
        return selectProcedure(at: target)
    }

    // MARK: - Transform Section to Strings (bulk string transform)

    /// Scans the named section for NUL-terminated printable C strings and marks each
    /// found span as a (NUL-terminated) string data-shape, applied as ONE undo group.
    /// Reuses the importer's cstring acceptance rule via `SectionStringScanner`. A
    /// no-op (surfaced issue) when the section is unknown, has no file bytes, or holds
    /// no strings. Returns the number of spans marked.
    @discardableResult
    func transformSectionToStrings(sectionName: String, minimumLength: Int = SectionStringScanner.defaultMinimumLength) -> Int {
        transformSectionToStrings(
            sectionName: sectionName,
            in: focusedImageSlot,
            minimumLength: minimumLength
        )
    }

    @discardableResult
    private func transformSectionToStrings(
        sectionName: String,
        in imageSlot: ImageSlot,
        minimumLength: Int
    ) -> Int {
        guard let section = snapshot.analysis(in: imageSlot)?.sections.first(where: { $0.name == sectionName }) else {
            lastIssue = "No section named \(sectionName)."
            return 0
        }
        guard !section.isZeroFill, section.size > 0 else {
            lastIssue = "Section \(sectionName) has no file bytes to scan."
            return 0
        }
        // Read the section's bytes through the section-accurate reader (bounds-checked,
        // overflow-safe). A section beyond the captured slice simply yields no bytes.
        guard section.size <= UInt64(Int.max) else {
            lastIssue = "Section \(sectionName) is too large to scan on this host."
            return 0
        }
        let reader = snapshot.hexByteReader(in: imageSlot)
        guard let bytes = reader(section.address, Int(section.size)), !bytes.isEmpty else {
            lastIssue = "Section \(sectionName) bytes are not loaded."
            return 0
        }
        let spans = SectionStringScanner.scan(bytes: bytes, baseAddress: section.address, minimumLength: minimumLength)
        guard !spans.isEmpty else {
            lastIssue = "No strings found in \(sectionName)."
            return 0
        }

        // Build the new override map: a NUL-terminated string shape at each span start.
        // A shape implies data, so clear any conflicting isData (mirrors setDataShape).
        var overrides = snapshot.addressOverrides
        for span in spans {
            let key = ImageAddress(slot: imageSlot, address: span.address)
            var override = overrides[key] ?? AddressOverride()
            override.dataShape = DataShapeOverride(kind: .string, isNullTerminated: true)
            override.isData = false
            overrides[key] = override
        }
        applyOverrideMap(overrides, in: imageSlot, actionName: "Transform Section to Strings")
        return spans.count
    }

    /// Transforms the section CONTAINING the current selection into strings. A no-op
    /// (surfaced issue) when nothing is selected or the selection isn't in a byte-backed
    /// section. Returns the number of spans marked.
    @discardableResult
    func transformSectionToStringsAtSelection(minimumLength: Int = SectionStringScanner.defaultMinimumLength) -> Int {
        guard let target = selectedImageAddress else {
            lastIssue = "Select an address inside the section to transform."
            return 0
        }
        guard let section = snapshot.section(containing: target) else {
            lastIssue = "The selection is not inside a byte-backed section."
            return 0
        }
        return transformSectionToStrings(
            sectionName: section.name,
            in: target.slot,
            minimumLength: minimumLength
        )
    }

    /// Replaces one slot's override-map partition as one undo step, then re-drives analysis once.
    /// Used by bulk authoring (Transform Section to Strings) so N edits collapse into a
    /// single undoable group with a single re-analysis, rather than N separate re-drives.
    /// `reanalyze` is `false` for structurally-inert bulk edits (e.g. painting a color across
    /// a graph node multi-select) so a display-only change doesn't pay for a full re-flow —
    /// mirroring how the single-address `applyOverride` skips re-analysis for color/name edits.
    private func applyOverrideMap(
        _ overrides: [ImageAddress: AddressOverride],
        in imageSlot: ImageSlot,
        actionName: String,
        reanalyze: Bool = true
    ) {
        // Prune emptied entries so a cleared edit doesn't linger (mirrors applyOverride).
        let value = overrides.filter { $0.key.slot == imageSlot && !$0.value.isEmpty }
        let previous = snapshot.addressOverrides.filter { $0.key.slot == imageSlot }
        guard value != previous else { return }
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        // Freeze the image that authored this bulk operation. Undo/redo may run after focus moves;
        // replay must re-flow this exact slot rather than redirecting through mutable UI focus.
        let reanalysisSlot = reanalyze ? imageSlot : nil
        registerAndApplyOverrideMap(
            value,
            previous: previous,
            in: imageSlot,
            reanalysisSlot: reanalysisSlot
        )
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
    }

    private func registerAndApplyOverrideMap(
        _ overrides: [ImageAddress: AddressOverride],
        previous: [ImageAddress: AddressOverride],
        in imageSlot: ImageSlot,
        reanalysisSlot: ImageSlot?
    ) {
        let semanticChanged = Set(previous.keys).union(overrides.keys).contains { key in
            Self.nativeDecompilerSemanticOverrideChanged(
                from: previous[key],
                to: overrides[key]
            )
        }
        let patchesChanged = Set(previous.keys).union(overrides.keys).contains { key in
            previous[key]?.patch != overrides[key]?.patch
        }
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        undoManager.registerUndo(withTarget: undoTargetForRegistration(in: imageSlot)) { target in
            guard let store = target.store else { return }
            store.registerAndApplyOverrideMap(
                previous,
                previous: overrides,
                in: imageSlot,
                reanalysisSlot: reanalysisSlot
            )
            store.restoreDocumentDirtyToken(priorToken)
        }
        snapshot.addressOverrides = snapshot.addressOverrides.filter { $0.key.slot != imageSlot }
        snapshot.addressOverrides.merge(overrides) { _, replacement in replacement }
        if patchesChanged {
            noteNativePatchMutation(imageSlots: [imageSlot])
        }
        if semanticChanged {
            noteNativeSemanticAuthoringMutation(
                imageSlots: [imageSlot],
                schedulesStructuralReanalysis: reanalysisSlot != nil
            )
        }
        // A bulk data-shape change alters the code/data structure, so re-drive once. A
        // display-only bulk edit (colors) opts out via `reanalyze: false`.
        if let reanalysisSlot {
            reanalyzeHonoringOverrides(in: reanalysisSlot)
        }
    }

    /// Sets (or clears, when empty) the user signature override for the function at
    /// `address`, registering one reversible Undo action for the whole edit.
    func setSignature(_ address: UInt64, _ signature: FunctionSignatureOverride?) {
        setSignature(overrideKey(address), signature)
    }

    private func setSignature(_ key: ImageAddress, _ signature: FunctionSignatureOverride?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.signature = (signature?.isEmpty ?? true) ? nil : signature
        applyOverride(key, override, actionName: "Edit Signature")
    }

    // MARK: - Signature editor presentation

    /// Opens the signature editor for the function enclosing the current selection,
    /// seeded from the existing override when present, else the recovered signature.
    func beginSignatureEditAtSelection() {
        guard let selection = selectedImageAddress,
              let function = enclosingFunction(for: selection.address, in: selection.slot)
        else {
            lastIssue = "Select a function to edit its signature."
            return
        }
        let slot = selection.slot
        let start = function.startAddress
        let recovered = recoveredSignature(for: function, in: slot)
        let existing = snapshot.addressOverrides[ImageAddress(slot: slot, address: start)]?.signature
        let returnType = existing?.returnType ?? recovered.returnType
        let variadicState = existing?.variadicState ?? .unspecified
        let recoveredArgs = recovered.args.enumerated().map { offset, row in
            ArgDraft(
                index: offset,
                name: row.name,
                type: row.type,
                rowToken: row.rowToken,
                provenance: row.provenance
            )
        }
        let parameterListIntent: SignatureParameterListIntent
        let args: [ArgDraft]
        if let existing, case let .authoritative(rows) = existing.parameterList {
            parameterListIntent = .authoritative
            args = rows.enumerated().map { offset, row in
                ArgDraft(
                    index: offset,
                    name: row.name,
                    type: row.type,
                    rowToken: row.rowToken,
                    provenance: row.provenance
                )
            }
        } else {
            parameterListIntent = .inherited
            args = recoveredArgs
        }
        signatureEditorRequest = SignatureEditorRequest(
            address: start,
            functionName: snapshot.displayName(at: start, in: slot, default: function.name),
            returnType: returnType,
            args: args,
            recoveredArgs: recoveredArgs,
            noReturnState: existing?.noReturnState ?? .unspecified,
            imageSlot: slot,
            parameterListIntent: parameterListIntent,
            quarantinedLegacyArgs: existing?.quarantinedLegacyArgs ?? [],
            baselineArgs: args,
            baselineReturnType: returnType,
            originalReturnType: existing?.returnType,
            originalParameterListIntent: parameterListIntent,
            variadicState: variadicState,
            originalVariadicState: variadicState,
            ownerBinaryID: snapshot.binary(in: slot)?.id,
            objcCandidates: objcSignatureCandidates(at: start, in: slot)
        )
    }

    /// Applies the in-progress signature editor draft. An unchanged recovered preview
    /// remains unspecified; an authoritative empty list persists as explicit `(void)`.
    /// Each row keeps its opaque identity. An explicitly edited/reordered declaration
    /// becomes user-authored; a blank name defaults to a per-index placeholder so
    /// distinct argument slots never collapse to one name.
    func commitSignatureEditor(_ draft: SignatureEditorRequest) {
        if let acceptedContext = draft.appliedObjCCandidateContext,
           acceptedContext != objcSignatureCandidateContext(at: draft.address, in: draft.imageSlot) {
            lastIssue = "The accepted candidate's image, slice or declaration source changed. Reopen the signature editor."
            return
        }
        guard authoringPresentationIsCurrent(draft.id),
              let openingRequest = signatureEditorRequest,
              openingRequest.hasSameOpeningPresentation(as: draft),
              openingRequest.retainsOpeningIdentity,
              draft.retainsOpeningIdentity else {
            invalidateAuthoringPresentation(draft.id)
            rejectStaleAuthoringRequest(
                "The function that owned this signature request is no longer available."
            )
            return
        }
        let target = openingRequest.openingIdentity.target
        guard hasRequestOwnedFunctionStart(
            target,
            ownerBinaryID: openingRequest.openingIdentity.ownerBinaryID
        ) else {
            invalidateAuthoringPresentation(openingRequest.id)
            rejectStaleAuthoringRequest("The function that owned this signature request is no longer available.")
            return
        }
        let isAuthoritative = draft.parameterListIntent == .authoritative
        let declarationWasExplicitlyAuthored = isAuthoritative
            && (draft.originalParameterListIntent != .authoritative
                || draft.args != draft.baselineArgs)
        let args = Self.committedSignatureArguments(from: draft.args).map { row in
            guard declarationWasExplicitlyAuthored else { return row }
            return ArgOverride(
                rowToken: row.rowToken,
                name: row.name,
                type: row.type,
                provenance: .user
            )
        }
        let parameterList: FunctionSignatureOverride.ParameterListState = isAuthoritative
            ? .authoritative(args)
            : .unspecified
        let displayedReturnType = Self.normalizedOverrideText(draft.returnType)
        let baselineReturnType = Self.normalizedOverrideText(draft.baselineReturnType)
        let returnType = draft.appliedObjCCandidateContext == nil && displayedReturnType == baselineReturnType
            ? draft.originalReturnType
            : displayedReturnType
        let signature = FunctionSignatureOverride(
            returnType: returnType,
            parameterList: parameterList,
            variadicState: draft.variadicState,
            quarantinedLegacyArgs: draft.quarantinedLegacyArgs,
            noReturnState: draft.noReturnState
        )
        setSignature(target, signature)
        invalidateAuthoringPresentation(openingRequest.id)
        signatureEditorRequest = nil
    }

    /// The private presentation-generation check exposed narrowly to the Objective-C candidate
    /// extension. A candidate may not bypass the editor's ordinary stale-request fence.
    func objcSignatureCandidatePresentationIsCurrent(
        _ candidate: ObjCSignatureCandidate,
        draft: SignatureEditorRequest
    ) -> Bool {
        guard authoringPresentationIsCurrent(draft.id),
              let openingRequest = signatureEditorRequest,
              openingRequest.hasSameOpeningPresentation(as: draft),
              openingRequest.retainsOpeningIdentity,
              draft.retainsOpeningIdentity,
              openingRequest.objcCandidates.contains(candidate) else {
            return false
        }
        return true
    }

    /// Removes the persisted signature for the exact image/address captured when
    /// this editor opened. The shared signature seam provides one undoable mutation
    /// and prunes the surrounding address override when it becomes empty.
    func clearSignatureEditorOverride(_ draft: SignatureEditorRequest) {
        guard authoringPresentationIsCurrent(draft.id),
              let openingRequest = signatureEditorRequest,
              openingRequest.hasSameOpeningPresentation(as: draft),
              openingRequest.retainsOpeningIdentity,
              draft.retainsOpeningIdentity else {
            invalidateAuthoringPresentation(draft.id)
            rejectStaleAuthoringRequest(
                "The function that owned this signature request is no longer available."
            )
            return
        }
        let target = openingRequest.openingIdentity.target
        guard hasRequestOwnedFunctionStart(
            target,
            ownerBinaryID: openingRequest.openingIdentity.ownerBinaryID
        ) else {
            invalidateAuthoringPresentation(openingRequest.id)
            rejectStaleAuthoringRequest("The function that owned this signature request is no longer available.")
            return
        }
        setSignature(target, nil)
        invalidateAuthoringPresentation(openingRequest.id)
        signatureEditorRequest = nil
    }

    private static func committedSignatureArguments(from drafts: [ArgDraft]) -> [ArgOverride] {
        drafts.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = row.type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !type.isEmpty else { return nil }
            return ArgOverride(
                rowToken: row.rowToken,
                name: name.isEmpty ? "arg\(row.index)" : name,
                type: type.isEmpty ? "int64_t" : type,
                provenance: row.provenance
            )
        }
    }

    /// Cancels only the exact presentation whose callback fired. A late callback from a replaced
    /// sheet leaves the currently visible request intact.
    func cancelSignatureEditor(_ request: SignatureEditorRequest) {
        guard signatureEditorRequest?.hasSameOpeningPresentation(as: request) == true else { return }
        invalidateAuthoringPresentation(request.id)
        signatureEditorRequest = nil
    }

    /// Compatibility for synchronous callers that intentionally cancel the currently published
    /// request. Interactive sheet callbacks must use the request-aware overload above.
    func cancelSignatureEditor() {
        guard let request = signatureEditorRequest else { return }
        cancelSignatureEditor(request)
    }

    // MARK: - Switch/Case hint (manual jump-table override)

    /// Applies (or clears, when nil) a manual switch-hint at the dispatching `br`
    /// address, reversibly through the shared address-override path.
    func setSwitchHint(_ address: UInt64, _ hint: SwitchHintOverride?) {
        setSwitchHint(overrideKey(address), hint)
    }

    private func setSwitchHint(_ key: ImageAddress, _ hint: SwitchHintOverride?) {
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.switchHint = (hint?.isEmpty ?? true) ? nil : hint
        applyOverride(key, override, actionName: hint == nil ? "Clear Switch Hint" : "Define Switch Hint")
    }

    /// Opens the switch-hint editor for the selected instruction, seeded from the
    /// existing hint when present. Defaults to a 4-byte, base-relative table (the
    /// classic `ldrsw` form) with the table base pre-filled to the selected address.
    func beginSwitchHintEditAtSelection() {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select the dispatching branch to declare a switch."
            return
        }
        let existing = snapshot.switchHint(at: target)
        switchHintEditorRequest = SwitchHintEditorRequest(
            address: target.address,
            tableBaseText: "0x" + String(existing?.tableBase ?? target.address, radix: 16),
            entryCountText: existing.map { String($0.entryCount) } ?? "",
            entryStrideText: String(existing?.entryStride ?? 4),
            isRelativeToBase: existing?.isRelativeToBase ?? true,
            imageSlot: target.slot,
            ownerBinaryID: snapshot.binary(in: target.slot)?.id
        )
    }

    /// Commits the switch-hint draft. An empty base/count or an explicit zero count removes the
    /// hint. Malformed NONEMPTY input is rejected with the editor kept open: a typo must never be
    /// reinterpreted as destructive intent. Out-of-range values are likewise rejected rather than
    /// silently coerced, because a coerced stride/count would read the wrong table locations.
    func commitSwitchHintEditor(_ draft: SwitchHintEditorRequest) {
        guard authoringPresentationIsCurrent(draft.id),
              let openingRequest = switchHintEditorRequest,
              openingRequest.hasSameOpeningPresentation(as: draft),
              openingRequest.retainsOpeningIdentity,
              draft.retainsOpeningIdentity else {
            invalidateAuthoringPresentation(draft.id)
            rejectStaleAuthoringRequest(
                "The instruction that owned this switch request is no longer available."
            )
            return
        }
        let target = openingRequest.openingIdentity.target
        guard hasRequestOwnedInstruction(
            target,
            ownerBinaryID: openingRequest.openingIdentity.ownerBinaryID
        ) else {
            invalidateAuthoringPresentation(openingRequest.id)
            rejectStaleAuthoringRequest("The instruction that owned this switch request is no longer available.")
            return
        }
        let tableBaseText = draft.tableBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let countText = draft.entryCountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let strideText = draft.entryStrideText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tableBaseText.isEmpty, !countText.isEmpty else {
            setSwitchHint(target, nil)
            invalidateAuthoringPresentation(openingRequest.id)
            switchHintEditorRequest = nil
            lastIssue = nil
            return
        }
        guard let entryCount = Int(countText) else {
            lastIssue = "Case count must be a nonnegative integer."
            return
        }
        if entryCount == 0 {
            setSwitchHint(target, nil)
            invalidateAuthoringPresentation(openingRequest.id)
            switchHintEditorRequest = nil
            lastIssue = nil
            return
        }
        guard entryCount > 0 else {
            lastIssue = "Case count must be a positive integer."
            return
        }
        guard let tableBase = Self.parseAddressText(tableBaseText) else {
            lastIssue = "Table base must be a hexadecimal or decimal address."
            return
        }
        guard entryCount <= SwitchHintOverride.maxEntryCount else {
            lastIssue = "Case count must be \(SwitchHintOverride.maxEntryCount) or fewer."
            return // keep the editor open to correct it
        }
        // Entry size, when provided, must be 1–8 bytes; a blank field defaults to 4.
        let stride: Int
        if strideText.isEmpty {
            stride = 4
        } else if let parsed = Int(strideText), parsed >= 1, parsed <= 8 {
            stride = parsed
        } else {
            lastIssue = "Entry size must be 1–8 bytes."
            return // keep the editor open rather than silently coercing
        }
        setSwitchHint(target, SwitchHintOverride(
            tableBase: tableBase,
            entryCount: entryCount,
            entryStride: stride,
            isRelativeToBase: draft.isRelativeToBase
        ))
        invalidateAuthoringPresentation(openingRequest.id)
        switchHintEditorRequest = nil
        lastIssue = nil
    }

    /// Removes the hint owned by the exact currently presented switch editor. The mutable draft
    /// may differ from the published seed, so its stable request ID is the presentation token;
    /// immutable image/binary ownership and instruction membership still must match at commit.
    /// A stale callback leaves the current presentation untouched.
    @discardableResult
    func removeSwitchHint(_ request: SwitchHintEditorRequest) -> Bool {
        guard authoringPresentationIsCurrent(request.id),
              let openingRequest = switchHintEditorRequest,
              openingRequest.hasSameOpeningPresentation(as: request),
              openingRequest.retainsOpeningIdentity,
              request.retainsOpeningIdentity else {
            invalidateAuthoringPresentation(request.id)
            rejectStaleAuthoringRequest(
                "The instruction that owned this switch request is no longer available."
            )
            return false
        }
        let target = openingRequest.openingIdentity.target
        guard hasRequestOwnedInstruction(
            target,
            ownerBinaryID: openingRequest.openingIdentity.ownerBinaryID
        ) else {
            invalidateAuthoringPresentation(openingRequest.id)
            rejectStaleAuthoringRequest(
                "The instruction that owned this switch request is no longer available."
            )
            return false
        }
        setSwitchHint(target, nil)
        invalidateAuthoringPresentation(openingRequest.id)
        switchHintEditorRequest = nil
        lastIssue = nil
        return true
    }

    func cancelSwitchHintEditor(_ request: SwitchHintEditorRequest) {
        guard switchHintEditorRequest?.hasSameOpeningPresentation(as: request) == true else { return }
        invalidateAuthoringPresentation(request.id)
        switchHintEditorRequest = nil
    }

    func cancelSwitchHintEditor() {
        guard let request = switchHintEditorRequest else { return }
        cancelSwitchHintEditor(request)
    }

    /// Parses an address from `0x`-prefixed hex or plain decimal text, nil otherwise.
    static func parseAddressText(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed)
    }

    // MARK: - Type catalog + apply-at-address

    /// Applies (or clears, when nil) a workspace type at `address`, registering a
    /// reversible Undo through the same address-override path as the other authoring.
    func setAppliedType(_ address: UInt64, name: String?) {
        setAppliedType(address, in: focusedImageSlot, name: name)
    }

    /// Slot-qualified type application for callers bound to an explicit command image
    /// (scripting's primary scope) rather than live focus. Same undo/dirty path.
    func setAppliedType(_ address: UInt64, in slot: ImageSlot, name: String?) {
        let key = ImageAddress(slot: slot, address: address)
        var override = snapshot.addressOverrides[key] ?? AddressOverride()
        override.appliedTypeName = Self.normalizedOverrideText(name)
        applyOverride(key, override, actionName: name == nil ? "Clear Type" : "Apply Type")
    }

    /// Applies a defined type (nil clears) at the selected instruction. Surfaced by
    /// the command palette's "Apply Type: <name>" / "Clear Type" commands.
    func applyTypeAtSelection(name: String?) {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to apply a type."
            return
        }
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.appliedTypeName = Self.normalizedOverrideText(name)
        applyOverride(target, override, actionName: name == nil ? "Clear Type" : "Apply Type")
    }

    /// Inserts or updates a type in the workspace catalog (keyed by id), undoable.
    func upsertTypeDefinition(_ type: TypeDefinition) {
        var types = snapshot.typeDefinitions
        if let index = types.firstIndex(where: { $0.id == type.id }) {
            types[index] = type
        } else {
            types.append(type)
        }
        applyTypeDefinitions(types, actionName: "Define Type")
    }

    /// Removes a type from the catalog, undoable. References to it degrade to
    /// no-type via `appliedType(at:)`'s name resolution.
    func deleteTypeDefinition(id: UUID) {
        var types = snapshot.typeDefinitions
        types.removeAll { $0.id == id }
        applyTypeDefinitions(types, actionName: "Delete Type")
    }

    /// Outcome of importing C declarations into the catalog: how many types were
    /// added, plus every parser diagnostic and any name-collision skips. The view
    /// model surfaces this so the user sees exactly what landed and what didn't.
    struct CHeaderImportSummary: Equatable {
        var addedNames: [String]
        var diagnostics: [String]
        var importedPrototypeCount: Int = 0
        var skippedPrototypeCount: Int = 0
    }

    /// Parses pasted C source into catalog types and exact exported prototypes,
    /// adding both in one undoable step. Names already in the catalog (or duplicated within the paste)
    /// are SKIPPED with a diagnostic rather than overwriting or colliding — the
    /// `type_definitions` UNIQUE(name) index would otherwise abort the whole
    /// workspace save. Returns a summary; an empty add-list leaves the catalog
    /// untouched (no spurious undo entry, because `applyTypeDefinitions` no-ops on
    /// an unchanged array).
    @discardableResult
    func defineTypesFromCHeader(_ source: String) -> CHeaderImportSummary {
        let slot = focusedImageSlot
        let prepared = HeaderImportCore.prepare(source: source,
            typeDefinitions: snapshot.typeDefinitions,
            exports: snapshot.analysis(in: slot)?.exports ?? [],
            functions: snapshot.analysis(in: slot)?.functions ?? [],
            importedPrototypes: snapshot.importedPrototypes, slot: slot)
        let types = prepared.types
        let imported = prepared.prototypes
        let added = prepared.addedNames
        let diagnostics = prepared.diagnostics
        applyHeaderImport(types: types, prototypes: imported)
        snapshot.recordHeaderImportEvidence(prepared.headerLayoutDefinitions)

        if added.isEmpty && prepared.importedPrototypeCount == 0 && diagnostics.isEmpty {
            lastIssue = "No type declarations were found in the pasted source."
        } else if !diagnostics.isEmpty {
            // Surface the first diagnostic inline; the full list rides the summary.
            lastIssue = added.isEmpty
                ? "No types added. \(diagnostics[0])"
                : "Added \(added.count) type(s). \(diagnostics.count) item(s) skipped."
        }
        return CHeaderImportSummary(addedNames: added, diagnostics: diagnostics,
            importedPrototypeCount: prepared.importedPrototypeCount,
            skippedPrototypeCount: prepared.skippedPrototypeCount)
    }

    private func applyHeaderImport(types: [TypeDefinition], prototypes: [ImageAddress: FunctionSignatureOverride]) {
        guard types != snapshot.typeDefinitions || prototypes != snapshot.importedPrototypes else { return }
        let manager = undoManager
        let explicitGroup = !manager.groupsByEvent
        if explicitGroup { manager.beginUndoGrouping() }
        registerAndApplyHeaderImport(types: types, prototypes: prototypes)
        manager.setActionName("Import C Header")
        if explicitGroup { manager.endUndoGrouping() }
    }

    private func registerAndApplyHeaderImport(types: [TypeDefinition], prototypes: [ImageAddress: FunctionSignatureOverride]) {
        let priorTypes = snapshot.typeDefinitions
        let priorPrototypes = snapshot.importedPrototypes
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        undoManager.registerUndo(withTarget: self) { store in
            store.registerAndApplyHeaderImport(types: priorTypes, prototypes: priorPrototypes)
            store.restoreDocumentDirtyToken(priorToken)
        }
        snapshot.typeDefinitions = types
        snapshot.importedPrototypes = prototypes
        noteNativeSemanticAuthoringMutation(imageSlots: Set(snapshot.binaries.map(\.slot)), schedulesStructuralReanalysis: false)
    }

    /// Replaces the whole type catalog as one undo step. The catalog is global (not
    /// address-keyed), so it can't ride `applyOverride`; this is the parallel
    /// array-snapshot undo helper, mirroring `registerAndApplyOverride`.
    private func applyTypeDefinitions(_ types: [TypeDefinition], actionName: String) {
        let previous = snapshot.typeDefinitions
        guard types != previous else { return }
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        registerAndApplyTypeDefinitions(types, previous: previous)
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
    }

    private func registerAndApplyTypeDefinitions(_ types: [TypeDefinition], previous: [TypeDefinition]) {
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        undoManager.registerUndo(withTarget: self) { store in
            store.registerAndApplyTypeDefinitions(previous, previous: types)
            store.restoreDocumentDirtyToken(priorToken)
        }
        snapshot.typeDefinitions = types
        noteNativeSemanticAuthoringMutation(
            imageSlots: Set(snapshot.binaries.map(\.slot)),
            schedulesStructuralReanalysis: false
        )
    }

    // MARK: - Type editor presentation

    /// Opens the type editor for a new struct (or an existing type when `editing`).
    func beginTypeDefinition(editing type: TypeDefinition? = nil) {
        if let type {
            typeEditorRequest = TypeEditorRequest(
                typeID: type.id,
                original: type,
                kind: type.kind,
                access: typeEditorAccess(for: type),
                name: type.name,
                fields: type.fields.map {
                    TypeFieldDraft(original: $0, name: $0.name, type: $0.type)
                },
                imageSlot: focusedImageSlot
            )
        } else {
            typeEditorRequest = TypeEditorRequest(
                typeID: UUID(),
                original: nil,
                kind: .struct,
                access: .editablePlainRecord,
                name: "",
                fields: [TypeFieldDraft(name: "", type: "")],
                imageSlot: focusedImageSlot
            )
        }
    }

    /// Commits the active editable draft. Existing definition kind/layout authority comes
    /// from the opening request; only explicit plain name/type leaves may change.
    func commitTypeEditor(_ draft: TypeEditorRequest) {
        guard activeTypeEditorRequest(matching: draft) != nil else { return }
        guard case .editablePlainRecord = draft.access else { return }
        guard let name = Self.asciiTrimmedNonempty(draft.name) else {
            typeEditorRequest = nil
            return
        }
        guard draft.kind == .struct || draft.kind == .union else {
            lastIssue = "New type definitions must be structs or unions."
            return
        }
        let committedKind: TypeKind
        let committedLayout: AggregateLayoutRules
        if let original = draft.original {
            guard let current = snapshot.typeDefinitions.first(where: { $0.id == draft.typeID }),
                  current == original else {
                lastIssue = "The type definition changed after the editor opened."
                return
            }
            committedKind = original.kind
            committedLayout = original.layoutRules
        } else {
            committedKind = draft.kind
            committedLayout = .default
        }
        // Names must be unique in the catalog: the SQLite `type_definitions` table
        // has UNIQUE(workspace_id, name), so persisting two same-named types (or
        // renaming one onto another) would abort the *entire* workspace save inside
        // its transaction and discard every pending edit. Reject the collision and
        // keep the editor open so the user can pick a different name.
        if snapshot.typeDefinitions.contains(where: { $0.name == name && $0.id != draft.typeID }) {
            lastIssue = "A type named “\(name)” already exists."
            return
        }

        var fields: [FieldDef] = []
        fields.reserveCapacity(draft.fields.count)
        for row in draft.fields {
            if row.original == nil, row.name.isEmpty, row.type.isEmpty { continue }
            guard !row.name.isEmpty, !row.type.isEmpty else {
                lastIssue = "Every type field needs both a name and a type."
                return
            }
            var field = row.original
                ?? FieldDef(name: row.name, type: row.type, declaratorSemanticsV1: .ordinary)
            field.name = row.name
            field.type = row.type
            field.declaratorSemanticsV1 = .ordinary
            fields.append(field)
        }

        let definition = TypeDefinition(
            id: draft.typeID,
            kind: committedKind,
            name: name,
            fields: fields,
            layoutRules: committedLayout
        )
        var prospectiveCatalog = snapshot.typeDefinitions
        if let index = prospectiveCatalog.firstIndex(where: { $0.id == definition.id }) {
            prospectiveCatalog[index] = definition
        } else {
            prospectiveCatalog.append(definition)
        }
        do {
            let catalog = try NativeAuthoredCatalogIndex(definitions: prospectiveCatalog)
            for (index, field) in fields.enumerated() {
                _ = try NativeAuthoredFieldStorageParserV1.parse(
                    field: field,
                    position: .init(ownerKind: committedKind, index: index, count: fields.count),
                    catalog: catalog
                )
            }
        } catch {
            lastIssue = "The edited type cannot be represented exactly."
            return
        }

        upsertTypeDefinition(definition)
        typeEditorRequest = nil
    }

    /// Request-aware dismissal: a callback from an older sheet cannot close a newer editor.
    func cancelTypeEditor(_ request: TypeEditorRequest) {
        guard activeTypeEditorRequest(matching: request) != nil else { return }
        typeEditorRequest = nil
    }

    /// Freezes one rich definition's rendered-C representation and routes it to the focused
    /// window. No path is selected and no document mutation occurs here.
    func requestRenderedCExport(_ request: TypeEditorRequest) {
        guard let active = activeTypeEditorRequest(matching: request),
              case .readOnlyRichDefinition = active.access,
              let definition = active.original,
              snapshot.typeDefinitions.first(where: { $0.id == definition.id }) == definition
        else { return }
        let safeName = Self.safeTypeExportName(definition)
        NotificationCenter.default.post(
            name: .macScopeExportRenderedTypeDefinition,
            object: RenderedTypeDefinitionExportRequest(
                typeID: definition.id,
                suggestedFileName: safeName,
                contents: CTypeHeaderRenderer.renderType(definition)
            ),
            userInfo: Notification.commandTargetUserInfo(self)
        )
    }

    /// Deletes only the exact rich definition captured by the still-active request.
    func deleteTypeEditorDefinition(_ request: TypeEditorRequest) {
        guard let active = activeTypeEditorRequest(matching: request),
              case .readOnlyRichDefinition = active.access,
              let definition = active.original,
              snapshot.typeDefinitions.first(where: { $0.id == definition.id }) == definition
        else { return }
        deleteTypeDefinition(id: definition.id)
        typeEditorRequest = nil
    }

    private func activeTypeEditorRequest(matching request: TypeEditorRequest) -> TypeEditorRequest? {
        guard let active = typeEditorRequest, active.id == request.id else {
            lastIssue = "The type editor request is no longer active."
            return nil
        }
        return active
    }

    private func typeEditorAccess(for definition: TypeDefinition) -> TypeEditorAccess {
        guard definition.kind == .struct || definition.kind == .union,
              definition.layoutRules == .default,
              definition.fields.allSatisfy({ field in
                  field.bitWidth == nil
                      && field.minimumAlignment == nil
                      && field.minimumAlignmentType == nil
                      && field.inlineAggregateKind == nil
                      && field.inlineFields.isEmpty
                      && field.inlineAggregateLayoutRules == .default
                      && !field.promotesInlineFields
                      && field.declaratorSemanticsV1 == .ordinary
              })
        else {
            return .readOnlyRichDefinition(
                reason: "This definition contains semantic details the plain record editor cannot preserve."
            )
        }
        do {
            let catalog = try NativeAuthoredCatalogIndex(definitions: snapshot.typeDefinitions)
            for (index, field) in definition.fields.enumerated() {
                let storage = try NativeAuthoredFieldStorageParserV1.parse(
                    field: field,
                    position: .init(
                        ownerKind: definition.kind,
                        index: index,
                        count: definition.fields.count
                    ),
                    catalog: catalog
                )
                switch storage {
                case .value, .fixedArray:
                    continue
                case .flexibleArray, .opaquePointerCarrier, .inlineAggregate:
                    return .readOnlyRichDefinition(
                        reason: "This field storage requires the read-only rich definition view."
                    )
                }
            }
            return .editablePlainRecord
        } catch {
            return .readOnlyRichDefinition(
                reason: "This definition cannot be reconstructed exactly by the plain record editor."
            )
        }
    }

    private static func asciiTrimmedNonempty(_ value: String) -> String? {
        let whitespace = CharacterSet(charactersIn: " \t\n\r\u{000B}\u{000C}")
        let trimmed = value.trimmingCharacters(in: whitespace)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeTypeExportName(_ definition: TypeDefinition) -> String {
        let unsafe = definition.name.utf8.contains { byte in
            byte < 0x21 || byte > 0x7e || byte == 0x2f || byte == 0x3a || byte == 0x5c
        }
        return unsafe ? "Type-\(definition.id.uuidString).h" : "\(definition.name).h"
    }

    /// Builds the IR for `function` (no signature override) to read the recovered
    /// return type + parameters — the baseline the editor seeds from.
    private func recoveredSignature(
        for function: FunctionSummary,
        in slot: ImageSlot
    ) -> (returnType: String, args: [ArgOverride]) {
        guard let analysis = snapshot.analysis(in: slot) else { return ("", []) }
        let instructions = analysis.instructions.filter { row in
            let override = snapshot.addressOverrides[
                ImageAddress(slot: slot, address: row.address)
            ]
            let isExcludedFromCode = override.map {
                $0.isData || $0.isUndefined || !($0.dataShape?.isEmpty ?? true)
            } ?? false
            guard row.address >= function.startAddress,
                  !isExcludedFromCode
            else { return false }
            return function.endAddress > function.startAddress
                ? row.address < function.endAddress
                : row.address == function.startAddress
        }
        let document = PseudocodePrinter().print(
            functionName: function.name,
            startAddress: function.startAddress,
            jumpTables: resolvedJumpTablesForSignatureEditor(in: slot),
            objcSelectors: analysis.objcSelectors,
            instructions: instructions
        )
        let args = document.parameters.map { parameter in
            ArgOverride(
                rowToken: parameter.id.rawValue,
                name: parameter.name,
                type: parameter.type,
                provenance: parameter.evidence == .authoritativeDebug ? .debug : .user
            )
        }
        return (document.returnType, args)
    }

    private func resolvedJumpTablesForSignatureEditor(in slot: ImageSlot) -> [UInt64: [UInt64]] {
        var result = snapshot.analysis(in: slot)?.jumpTables ?? [:]
        let readBytes = snapshot.hexByteReader(in: slot)
        for (key, override) in snapshot.addressOverrides where key.slot == slot {
            if let hint = override.switchHint,
               !hint.isEmpty,
               let targets = hint.resolveTargets(readBytes: readBytes),
               !targets.isEmpty {
                result[key.address] = targets
            }
        }
        return result
    }

    /// Applies a full override for `address` (pruning empties) as one undo group.
    /// No-ops short-circuit before any group is opened.
    func applyOverride(_ address: UInt64, _ override: AddressOverride?, actionName: String) {
        applyOverride(overrideKey(address), override, actionName: actionName)
    }

    /// Slot-qualified form — the real implementation. The bare-address overload above is the
    /// UI/scripting entry point and qualifies against the focused image.
    func applyOverride(_ key: ImageAddress, _ override: AddressOverride?, actionName: String) {
        let previous = snapshot.addressOverrides[key]
        let normalized = (override?.isEmpty ?? true) ? nil : override
        guard normalized != previous else { return }

        // On the window manager (groupsByEvent == true) the current run-loop event
        // already owns an undo group; opening a nested one here would strand the
        // action name on the inner group and the menu would fall back to a bare
        // "Undo". Only the fallback manager (groupsByEvent == false) needs an
        // explicit group so a direct call is a closed, named step without a run loop.
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        registerAndApplyOverride(key, normalized, previous: previous)
        mirrorAnalystOverride(key, previous: previous, value: normalized)
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
    }

    /// Sets the override value and registers an Undo that restores `previous`.
    /// The undo handler re-enters this helper (running inside the UndoManager's
    /// own undo group), which registers the matching Redo — so undo/redo chain
    /// without opening new groups of their own.
    private func registerAndApplyOverride(_ key: ImageAddress, _ value: AddressOverride?, previous: AddressOverride?) {
        // Capture the dirty-token *before* this edit advances it, then register an
        // Undo that both reverts the override AND rewinds the dirty-state to this
        // point. Undo/redo re-enter this helper, so each direction restores the
        // token it captured — undoing back to the saved baseline reads clean again.
        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        // The undo closure captures the QUALIFIED key, so Cmd-Z after focusing another image
        // still reverts the edit in the image it was authored in.
        undoManager.registerUndo(withTarget: undoTargetForRegistration(in: key.slot)) { target in
            guard let store = target.store else { return }
            store.registerAndApplyOverride(key, previous, previous: value)
            store.restoreDocumentDirtyToken(priorToken)
        }
        let schedulesStructuralReanalysis =
            (previous?.isData ?? false) != (value?.isData ?? false)
            || (previous?.markAsProcedure ?? false) != (value?.markAsProcedure ?? false)
            || (previous?.isUndefined ?? false) != (value?.isUndefined ?? false)
            || previous?.switchHint != value?.switchHint
            || previous?.dataShape != value?.dataShape
            || previous?.patch != value?.patch
        let semanticChanged = Self.nativeDecompilerSemanticOverrideChanged(
            from: previous,
            to: value
        )
        snapshot.addressOverrides[key] = value
        if previous?.patch != value?.patch ||
            previous?.appendedExecutableCave != value?.appendedExecutableCave {
            noteNativePatchMutation(imageSlots: [key.slot])
        }
        if semanticChanged {
            noteNativeSemanticAuthoringMutation(
                imageSlots: [key.slot],
                schedulesStructuralReanalysis: schedulesStructuralReanalysis
            )
        }
        // A mark-as-code/data OR mark-as-procedure change alters the code/data structure
        // or the function boundaries, so re-drive the analysis (functions/CFG/xrefs/
        // decompile) to honor it. Both the forward edit and Undo/Redo route through here,
        // so each re-flows correctly. Other override kinds (names/comments/tags/colors/
        // types/signatures/...) don't change the structure, so they skip re-analysis.
        if schedulesStructuralReanalysis {
            reanalyzeHonoringOverrides(in: key.slot)
        }
    }

    /// Publishes one aggregate busy bit for every independently retained image-slot request.
    private func updateReanalysisActivity() {
        isReanalyzing = !reanalysisTasksBySlot.isEmpty
    }

    /// Cancels and invalidates only one image's current generation. Epoch advancement remains
    /// authoritative when an injected provider ignores cooperative cancellation: the late task
    /// cannot remove or overwrite the newer task retained under the same slot.
    private func supersedeReanalysis(
        in slot: ImageSlot,
        updateActivity: Bool = true
    ) {
        reanalysisEpochsBySlot[slot, default: 0] &+= 1
        reanalysisTasksBySlot.removeValue(forKey: slot)?.cancel()
        if updateActivity {
            updateReanalysisActivity()
        }
    }

    /// Cancels every image's work for a whole-workspace identity replacement. The workspace epoch
    /// independently rejects late results even when the replacement reuses slot numbers and UUIDs.
    private func supersedeReanalysis() {
        reanalysisWorkspaceEpoch &+= 1
        reanalysisTasksBySlot.values.forEach { $0.cancel() }
        reanalysisTasksBySlot.removeAll()
        updateReanalysisActivity()
    }

    private func isCurrentReanalysis(
        workspaceEpoch: UInt64,
        slotEpoch: UInt64,
        slot: ImageSlot
    ) -> Bool {
        reanalysisWorkspaceEpoch == workspaceEpoch
            && reanalysisEpochsBySlot[slot] == slotEpoch
    }

    /// Removes a completed request only if it is still the generation retained for its slot. A
    /// superseded provider may return later, but it must never clear the newer task or busy state.
    private func finishReanalysis(
        workspaceEpoch: UInt64,
        slotEpoch: UInt64,
        slot: ImageSlot
    ) {
        guard isCurrentReanalysis(
            workspaceEpoch: workspaceEpoch,
            slotEpoch: slotEpoch,
            slot: slot
        ) else { return }
        reanalysisTasksBySlot.removeValue(forKey: slot)
        updateReanalysisActivity()
    }

    /// Re-runs analysis honoring the current override store (mark-as-code/data), replacing
    /// the derived analysis (instructions/functions/blocks/CFG/xrefs) while PRESERVING the
    /// authoring layer (overrides + type catalog) and per-row breakpoint state. Recovers from the
    /// retained PACKAGE bytes (`imageBytes` is the persisted selected slice); the original path
    /// is only a legacy fallback when no captured bytes exist.
    @discardableResult
    func reanalyzeHonoringOverrides(in targetSlot: ImageSlot? = nil, coffSectionLayoutVersion: Int? = nil) -> Bool {
        // Capture the target before resolving any inputs. Once focus becomes independently
        // switchable, it may move while the async analysis is running; every read and the final
        // splice must continue to use this operation's original slot.
        let reanalyzedSlot = targetSlot ?? focusedImageSlot
        let ownerBinaryID = snapshot.binary(in: reanalyzedSlot)?.id
        // MS-16: an unnamed dyld-cache image cannot be recaptured (reloading its cache path selects
        // a different image), so refuse with a typed result and keep the prior accepted analysis.
        if let binary = snapshot.binary(in: reanalyzedSlot), binary.isUnnamedDyldCacheImage {
            let refusal = ReanalysisRefusal.recaptureRequired(slot: reanalyzedSlot)
            lastReanalysisRefusal = refusal
            lastIssue = refusal.message
            return false
        }
        // An ELF archive member reanalyzes only from its persisted outer container plus the exact
        // member selection; the loader re-verifies both identities. When the container is gone,
        // refuse with a typed result instead of analyzing a temp copy of the retained bytes. The
        // new edit still supersedes any older flight (its result would not honor this override map).
        if let binary = snapshot.binary(in: reanalyzedSlot), binary.elfArchiveMemberIdentity != nil,
           binary.path.isEmpty || !FileManager.default.fileExists(atPath: binary.path) {
            supersedeReanalysis(in: reanalyzedSlot)
            let refusal = ReanalysisRefusal.archiveContainerUnavailable(
                slot: reanalyzedSlot, path: binary.path
            )
            lastReanalysisRefusal = refusal
            lastIssue = refusal.message
            return false
        }
        if lastReanalysisRefusal != nil { lastReanalysisRefusal = nil }
        guard let source = reanalysisSource(in: reanalyzedSlot, coffSectionLayoutVersion: coffSectionLayoutVersion) else {
            // The new structural edit still supersedes an older result even when this generation
            // cannot resolve bytes of its own. Keeping the older flight would land derived data
            // that does not honor the now-current override map.
            supersedeReanalysis(in: reanalyzedSlot)
            return false
        }
        // Capture the analyze INPUTS synchronously (the override that triggered this is already
        // in `snapshot.addressOverrides`). Preserve the loaded fat/universal slice; otherwise a
        // mark-as-code/data on a non-default slice would silently revert to the default arch.
        let url = source.url
        let selection = source.selection
        // The engine is image-local (bare UInt64). Project the focused image's authoring down to
        // a bare map for the re-flow; `applyReanalysisResult` re-stamps the captured slot while
        // leaving the live qualified map in place, so sibling authoring is never fed to analyze
        // and never lost.
        let overrides = Dictionary(uniqueKeysWithValues:
            snapshot.addressOverrides
                .filter { $0.key.slot == reanalyzedSlot }
                .map { ($0.key.address, $0.value) })
        // In the recovery case the analyze() input is a temp file, so its fresh BinaryImage would
        // carry the temp path — restore the user-facing original path after the re-flow.
        let displayPath = snapshot.binary(in: reanalyzedSlot)?.path

        // Bump only this slot's generation. Keep aggregate publication stable until the replacement
        // task is installed so a same-slot supersession does not momentarily flicker idle.
        supersedeReanalysis(in: reanalyzedSlot, updateActivity: false)
        let workspaceEpoch = reanalysisWorkspaceEpoch
        let slotEpoch = reanalysisEpochsBySlot[reanalyzedSlot] ?? 0

        // Scripting / headless path: re-flow synchronously inline so a scripted mutate-then-query
        // is deterministic (no UI to keep responsive, and the caller is synchronous).
        if reanalysisRunsSynchronously {
            defer { source.cleanup() }
            do {
                let fresh = try engine.analyze(url: url, selection: selection,
                                               overrides: overrides, cancellation: .never)
                applyReanalysisResult(fresh,
                    restoringDisplayPath: source.isRecovered ? displayPath : nil,
                    reanalyzedSlot: reanalyzedSlot, ownerBinaryID: ownerBinaryID)
            } catch {
                if !(error is AnalysisCancelled) {
                    lastIssue = "Couldn’t reanalyze the edited bytes: \(error.localizedDescription)"
                }
                updateReanalysisActivity()
                return false
            }
            updateReanalysisActivity()
            return true
        }

        // Interactive path: kick the heavy re-flow OFF the main actor so a mark-as-code/data edit
        // never freezes the listing. The override is already applied + undoable; only the derived
        // data (instructions/functions/CFG/xrefs/decompile) lags, behind the "Re-analyzing…"
        // indicator.
        let recovered = source.isRecovered
        let task = Task { [weak self, engine] in
            let fresh: WorkspaceSnapshot?
            let failureMessage: String?
            do {
                fresh = try await engine.openBinary(
                    url: url, selection: selection, overrides: overrides, cancellation: .never
                )
                failureMessage = nil
            } catch {
                fresh = nil
                failureMessage = error is AnalysisCancelled || Task.isCancelled
                    ? nil : "Couldn’t reanalyze the edited bytes: \(error.localizedDescription)"
            }
            source.cleanup()
            guard let self else { return }
            // A newer same-slot edit or whole-workspace replacement superseded this result. Leave
            // both the retained replacement task and aggregate indicator untouched.
            guard self.isCurrentReanalysis(
                workspaceEpoch: workspaceEpoch,
                slotEpoch: slotEpoch,
                slot: reanalyzedSlot
            ) else { return }
            if let failureMessage { self.lastIssue = failureMessage }
            self.applyReanalysisResult(fresh, restoringDisplayPath: recovered ? displayPath : nil,
                                       reanalyzedSlot: reanalyzedSlot,
                                       ownerBinaryID: ownerBinaryID)
            self.finishReanalysis(
                workspaceEpoch: workspaceEpoch,
                slotEpoch: slotEpoch,
                slot: reanalyzedSlot
            )
        }
        reanalysisTasksBySlot[reanalyzedSlot] = task
        updateReanalysisActivity()
        return true
    }

    /// A thin recovery reuses an existing in-memory witness only when its verified
    /// slice is exactly the same. A newly opened full container supplies its own
    /// witness. Restored workspaces have none to reuse.
    static func containerWitnessForReanalysis(
        current: BinaryImage, fresh: BinaryImage,
        preservingArtifactAuthority: Bool, usingThinRecovery: Bool
    ) -> MachOContainerAdmissionWitness? {
        if usingThinRecovery {
            guard preservingArtifactAuthority,
                  current.artifactIntegrityState == .verified,
                  fresh.artifactIntegrityState == .verified,
                  current.artifactIdentity == fresh.artifactIdentity else { return nil }
            return current.containerAdmissionWitness
        }
        return fresh.containerAdmissionWitness
    }

    /// Lands a completed background re-analysis on the main actor by replacing only the captured
    /// image's identity record and derived bucket. The live snapshot remains the authority for
    /// every workspace-global authoring collection, so siblings and edits made during the async
    /// window survive automatically. A `nil` result means analyze failed (file moved/unreadable):
    /// keep the current snapshot; the triggering override still applies cosmetically.
    private func applyReanalysisResult(
        _ result: WorkspaceSnapshot?,
        restoringDisplayPath displayPath: String? = nil,
        reanalyzedSlot: ImageSlot = .primary,
        ownerBinaryID: UUID?
    ) {
        guard let fresh = result else { return }

        // Slot alone is not identity: restore/import or image replacement may reuse the numeric
        // slot while this work is in flight. A nil owner is allowed only for legacy binary-less
        // fixtures and must remain binary-less until the result lands.
        if let ownerBinaryID {
            guard snapshot.binary(in: reanalyzedSlot)?.id == ownerBinaryID else { return }
        } else {
            guard snapshot.binaries.isEmpty else { return }
        }

        // Extract the engine's single-image payload BEFORE changing its binary slot. Re-stamping
        // first would change `fresh.primarySlot` while the analysis dictionary still uses the
        // engine's original key, making the fresh bucket unreachable for non-primary targets.
        let engineSlot = fresh.primarySlot
        guard var freshAnalysis = fresh.analysis(in: engineSlot),
              var freshBinary = fresh.binaries.first else { return }

        let currentAnalysis = snapshot.analysis(in: reanalyzedSlot)
        let currentBinary = snapshot.binary(in: reanalyzedSlot)
        assert(currentBinary != nil || snapshot.binaries.isEmpty,
               "re-analyzed slot \(reanalyzedSlot.rawValue) vanished from the workspace")
        guard currentBinary != nil || snapshot.binaries.isEmpty else { return }

        let preservesCurrentArtifactAuthority: Bool = {
            guard let currentBinary else { return false }
            if displayPath != nil { return true }
            if case .contradictoryEvidence = currentBinary.artifactIntegrityState { return true }
            return false
        }()

        // Re-stamp the engine's image-local result with its durable workspace identity. Recovery
        // analyzed a temporary thin file, so restore its user-facing path and embedded payload.
        if let currentBinary {
            // Analysis refreshes loader-derived metadata but never changes the durable workspace
            // owner. Delayed requests, debugger inputs, persistence, and sidebar identity all key
            // the image by this UUID.
            freshBinary = BinaryImage(
                id: currentBinary.id,
                name: displayPath != nil ? currentBinary.name : freshBinary.name,
                path: freshBinary.path,
                kind: displayPath != nil ? currentBinary.kind : freshBinary.kind,
                architecture: displayPath != nil ? currentBinary.architecture : freshBinary.architecture,
                originalPathBookmark: freshBinary.originalPathBookmark,
                metadata: freshBinary.metadata,
                selectedSliceIndex: preservesCurrentArtifactAuthority
                    ? currentBinary.selectedSliceIndex : freshBinary.selectedSliceIndex,
                machOSelectedSliceFact: preservesCurrentArtifactAuthority || displayPath != nil
                    ? currentBinary.machOSelectedSliceFact : freshBinary.machOSelectedSliceFact,
                elfArchiveMemberIdentity: displayPath != nil
                    ? currentBinary.elfArchiveMemberIdentity
                    : freshBinary.elfArchiveMemberIdentity,
                artifactIdentity: preservesCurrentArtifactAuthority
                    ? currentBinary.artifactIdentity : freshBinary.artifactIdentity,
                preferredSegmentLayout: preservesCurrentArtifactAuthority
                    ? currentBinary.preferredSegmentLayout : freshBinary.preferredSegmentLayout,
                artifactIntegrityState: preservesCurrentArtifactAuthority
                    ? currentBinary.artifactIntegrityState : freshBinary.artifactIntegrityState,
                containerAdmissionWitness: Self.containerWitnessForReanalysis(
                    current: currentBinary, fresh: freshBinary,
                    preservingArtifactAuthority: preservesCurrentArtifactAuthority,
                    usingThinRecovery: displayPath != nil),
                resolvedExecutablePath: preservesCurrentArtifactAuthority
                    ? currentBinary.resolvedExecutablePath : freshBinary.resolvedExecutablePath,
                slot: reanalyzedSlot
            )
        } else {
            freshBinary.slot = reanalyzedSlot
        }
        if let displayPath {
            freshBinary.path = displayPath
            // The recovery input is an already-selected thin Mach-O, so the engine cannot infer
            // which slice it came from. Keep the durable universal-container selection for the
            // next time the original path becomes available.
            freshBinary.selectedSliceIndex = currentBinary?.selectedSliceIndex
            freshBinary.machOSelectedSliceFact = currentBinary?.machOSelectedSliceFact
            freshBinary.resolvedExecutablePath = currentBinary?.resolvedExecutablePath
            if freshAnalysis.imageBytes.isEmpty {
                freshAnalysis.imageBytes = currentAnalysis?.imageBytes ?? Data()
            }
        }
        freshBinary.originalPathBookmark = currentBinary?.originalPathBookmark
        if preservesCurrentArtifactAuthority,
           let currentBinary,
           let diagnostic = Self.artifactIntegrityDiagnostic(for: currentBinary),
           !freshAnalysis.diagnostics.contains(diagnostic) {
            freshAnalysis.diagnostics.append(diagnostic)
        }

        // dSYM source rows are target-local state that the engine does not reproduce. Breakpoint
        // compatibility bits are rebuilt exclusively from the durable logical catalog.
        freshAnalysis.sourceLines = currentAnalysis?.sourceLines ?? []
        let breakpoints = Set(enabledLogicalBreakpointPreferredAddresses(in: reanalyzedSlot))
        freshAnalysis.instructions = freshAnalysis.instructions.map { row in
            var copy = row
            copy.hasBreakpoint = breakpoints.contains(row.address)
            return copy
        }

        // HOP-4: engine ids derive from `.primary`; re-derive them for the landing slot.
        AnalysisStableIdentity.restamp(&freshAnalysis, to: freshBinary.slot)
        Self.restampAnalysisInputFingerprint(&freshAnalysis, using: freshBinary)
        if let binaryIndex = snapshot.binaries.firstIndex(where: { $0.slot == reanalyzedSlot }) {
            snapshot.binaries[binaryIndex] = freshBinary
        } else {
            // Preserve the pre-existing binary-less fixture behavior: successful re-analysis
            // materializes the engine's one binary rather than leaving the snapshot identity-less.
            snapshot.binaries = [freshBinary]
        }
        snapshot.replaceAnalysis(freshAnalysis, in: reanalyzedSlot)
        reanalysisLandingEpochsBySlot[reanalyzedSlot, default: 0] &+= 1
        // Re-analysis can change this image's exports/indirect symbols → refresh cross-image edges
        // for EVERY slot (before the primary-only selection-repair guard below).
        recomputeCrossImageXrefs()
        reconcileNativeDecompilerDrive(reason: .acceptedStructuralAnalysis)
        navigatorAnalysisDidLand(in: reanalyzedSlot, previousFingerprint: currentAnalysis?.analysisInputFingerprint)

        // Re-analysis minted fresh function/block UUIDs, so a still-focused primary selection may
        // need repair. The completion is delayed: if focus or the qualified selection moved to a
        // sibling while analysis ran, the primary-only graph/sidebar projection must stay untouched.
        let primarySlot = snapshot.primarySlot
        guard reanalyzedSlot == primarySlot,
              focusedImageSlot == primarySlot,
              selectedImageAddress?.slot == primarySlot else { return }
        syncGraphElementToSelectedAddress()
        if let prefix = selectedSidebarItemID?.split(separator: ":").first,
           prefix == "function" || prefix == "symbol",
           let selection = selectedImageAddress,
           let function = enclosingFunction(for: selection.address, in: primarySlot) {
            syncSidebarSelection(functionID: function.id)
        }
    }

    /// Awaits every independently retained background re-analysis, including a replacement task
    /// installed while this method is suspended. The headless launcher and tests use this to
    /// observe a quiescent workspace deterministically.
    func awaitPendingReanalysis() async {
        while !reanalysisTasksBySlot.isEmpty {
            let tasks = Array(reanalysisTasksBySlot.values)
            for task in tasks {
                await task.value
            }
        }
    }

    /// Awaits the picker inspection (which may start the import) and then the import itself. Tests
    /// use this to observe the final state deterministically after cancelling; the interactive UI
    /// never needs it.
    func awaitPendingImport() async {
        await loaderOptionsInspectionTask?.value
        await importTask?.value
    }

    /// Lets focused tests and headless qualification observe the optional supplemental result
    /// without introducing a delay into the primary import itself.
    func awaitPendingDyldCacheDifferential() async {
        await dyldCacheDifferentialTask?.value
    }

    /// Awaits the currently retained picker inspection. Tests use this to observe publication
    /// deterministically; superseded workers are fenced by generation and cannot publish.
    func awaitPendingLoaderOptionsInspection() async {
        await loaderOptionsInspectionTask?.value
    }

    static func normalizedOverrideText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Override editor presentation

    /// Opens the Rename editor for the function enclosing the current selection.
    func beginRenameAtSelection() {
        guard let selection = selectedImageAddress,
              let function = enclosingFunction(for: selection.address, in: selection.slot) else {
            lastIssue = "Select a function to rename."
            return
        }
        let target = ImageAddress(slot: selection.slot, address: function.startAddress)
        overrideEditorRequest = OverrideEditorRequest(
            kind: .rename,
            address: function.startAddress,
            title: "Rename Function",
            fieldPrompt: "Name",
            initialValue: snapshot.displayName(at: target, default: function.name) ?? function.name,
            imageSlot: selection.slot,
            ownerBinaryID: snapshot.binary(in: selection.slot)?.id
        )
    }

    /// Opens the Comment editor for the currently selected instruction.
    func beginCommentEditAtSelection() {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to comment."
            return
        }
        overrideEditorRequest = OverrideEditorRequest(
            kind: .comment,
            address: target.address,
            title: "Edit Comment",
            fieldPrompt: "Comment",
            initialValue: snapshot.displayComment(at: target, default: selectedInstruction?.comment) ?? "",
            imageSlot: target.slot,
            ownerBinaryID: snapshot.binary(in: target.slot)?.id
        )
    }

    /// Opens the Tag editor for the currently selected instruction.
    func beginTagEditAtSelection() {
        guard let target = selectedImageAddress, hasInstruction(target) else {
            lastIssue = "Select an instruction to tag."
            return
        }
        overrideEditorRequest = OverrideEditorRequest(
            kind: .tag,
            address: target.address,
            title: "Set Tag",
            fieldPrompt: "Tag",
            initialValue: snapshot.tag(at: target) ?? "",
            imageSlot: target.slot,
            ownerBinaryID: snapshot.binary(in: target.slot)?.id
        )
    }

    /// Opens the Set Local Label editor for the currently selected address (a
    /// procedure-scoped name). Empty text on commit clears the label. A no-op (surfaced
    /// issue) when nothing is selected.
    func beginLocalLabelEditAtSelection() {
        guard let target = selectedImageAddress, hasMappedAddress(target) else {
            lastIssue = "Select an address to label."
            return
        }
        overrideEditorRequest = OverrideEditorRequest(
            kind: .localLabel,
            address: target.address,
            title: "Set Local Label",
            fieldPrompt: "Label",
            initialValue: snapshot.localLabel(at: target) ?? "",
            imageSlot: target.slot,
            ownerBinaryID: snapshot.binary(in: target.slot)?.id
        )
    }

    /// Opens the Rename Register sheet for the procedure enclosing the current selection.
    /// `register` pre-fills the register id when known (the pseudocode context menu); an
    /// empty `register` opens the sheet with an editable register field (the Procedure menu).
    /// The rename is keyed at the PROCEDURE START (the same per-function scope a signature
    /// override uses). A no-op (surfaced issue) when the selection isn't inside a discovered
    /// procedure.
    func beginRegisterRenameAtSelection(register: String = "") {
        guard let selection = selectedImageAddress,
              let function = enclosingFunction(for: selection.address, in: selection.slot) else {
            lastIssue = "Select an instruction inside a function to rename a register."
            return
        }
        registerRenameRequest = RegisterRenameRequest(
            imageSlot: selection.slot,
            procedureStart: function.startAddress,
            register: register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ownerBinaryID: snapshot.binary(in: selection.slot)?.id
        )
    }

    /// Applies a sheet-owned request to the image captured when the sheet opened, then closes the
    /// presentation. The request is authoritative even if focus changed while the sheet was open.
    /// Invalid register input leaves the request open so Return-key submission cannot discard the
    /// user's draft after validation fails.
    @discardableResult
    func commitRegisterRename(_ request: RegisterRenameRequest, register: String, name: String?) -> Bool {
        guard authoringPresentationIsCurrent(request.presentationID),
              let openingRequest = registerRenameRequest,
              openingRequest.hasSameOpeningPresentation(as: request),
              openingRequest.retainsOpeningIdentity,
              request.retainsOpeningIdentity else {
            invalidateAuthoringPresentation(request.presentationID)
            rejectStaleAuthoringRequest(
                "The function that owned this register request is no longer available."
            )
            return false
        }
        let target = openingRequest.target
        guard hasRequestOwnedFunctionStart(target, ownerBinaryID: openingRequest.ownerBinaryID) else {
            invalidateAuthoringPresentation(openingRequest.presentationID)
            rejectStaleAuthoringRequest("The function that owned this register request is no longer available.")
            return false
        }
        let normalizedRegister = register
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedRegister.isEmpty else {
            lastIssue = "Provide a register identifier (e.g. x19)."
            return false
        }
        let frozenRegister = openingRequest.register
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard frozenRegister.isEmpty || normalizedRegister == frozenRegister else {
            lastIssue = "This request is fixed to register \(frozenRegister)."
            return false
        }
        renameRegister(
            procedureStart: openingRequest.procedureStart,
            in: openingRequest.imageSlot,
            register: normalizedRegister,
            name: name
        )
        invalidateAuthoringPresentation(openingRequest.presentationID)
        registerRenameRequest = nil
        lastIssue = nil
        return true
    }

    func cancelRegisterRename(_ request: RegisterRenameRequest) {
        guard registerRenameRequest?.hasSameOpeningPresentation(as: request) == true else { return }
        invalidateAuthoringPresentation(request.presentationID)
        registerRenameRequest = nil
    }

    func cancelRegisterRename() {
        guard let request = registerRenameRequest else { return }
        cancelRegisterRename(request)
    }

    // MARK: - Make Data (array / string / alignment) presentation

    /// Opens the Make Data sheet for the currently selected address. A no-op (surfaced
    /// issue) when nothing is selected. Pre-seeds the sheet from any existing data shape
    /// at the address so editing starts from the live state.
    func beginMakeDataAtSelection() {
        guard let target = selectedImageAddress, hasMappedAddress(target) else {
            lastIssue = "Select an address to shape as data."
            return
        }
        var request = DataShapeEditorRequest(
            address: target.address,
            imageSlot: target.slot,
            ownerBinaryID: snapshot.binary(in: target.slot)?.id
        )
        // `hasMappedAddress` above has already proved the exact image owner. Read the authored
        // value through the slot-qualified compatibility accessor so the supported binary-less
        // primary fixture can pre-seed too, without borrowing state from a colliding image.
        if let shape = snapshot.dataShape(at: target.address, in: target.slot) {
            switch shape.kind {
            case .array:
                request.shape = .array
                request.elementType = shape.elementType ?? ""
                request.countText = String(shape.elementCount)
            case .string:
                request.shape = .string
                request.isNullTerminated = shape.isNullTerminated
                request.stringLengthText = String(max(shape.stringLength, 1))
            case .alignment:
                request.shape = .alignment
                request.boundaryText = String(shape.alignment)
            }
        }
        presentedDataShapeEditorRequestIDs.insert(request.id)
        dataShapeEditorRequest = request
    }

    /// Commits the Make Data sheet: applies the chosen array/string/alignment shape (each
    /// undoable + re-analysis-driving via `setDataShape`). Invalid numeric entry surfaces an
    /// issue and keeps the sheet open. Returns whether the shape applied.
    @discardableResult
    func commitDataShapeEditor(_ request: DataShapeEditorRequest) -> Bool {
        // Preserve the pre-sheet synchronous seam used by binary-less fixtures and scripts: it
        // has no delayed presentation to race, so an owner-less primary request may commit only
        // while no sheet request is published. Once a sheet exists, exact request identity is
        // mandatory and a canceled/replaced callback can never fall through to this seam.
        let isLegacySynchronousCommit = dataShapeEditorRequest == nil
            && request.ownerBinaryID == nil
            && request.imageSlot == snapshot.primarySlot
            && snapshot.binaries.isEmpty
            && !presentedDataShapeEditorRequestIDs.contains(request.id)
            && authoringPresentationIsCurrent(request.id)
        let key: ImageAddress
        let ownerBinaryID: UUID?
        if let openingRequest = dataShapeEditorRequest {
            guard authoringPresentationIsCurrent(request.id),
                  openingRequest.hasSameOpeningPresentation(as: request),
                  openingRequest.retainsOpeningIdentity,
                  request.retainsOpeningIdentity else {
                invalidateAuthoringPresentation(request.id)
                rejectStaleAuthoringRequest(
                    "The address that owned this data-shape request is no longer available."
                )
                return false
            }
            key = openingRequest.openingIdentity.target
            ownerBinaryID = openingRequest.openingIdentity.ownerBinaryID
        } else {
            guard isLegacySynchronousCommit, request.retainsOpeningIdentity else {
                invalidateAuthoringPresentation(request.id)
                rejectStaleAuthoringRequest(
                    "The address that owned this data-shape request is no longer available."
                )
                return false
            }
            key = request.openingIdentity.target
            ownerBinaryID = request.openingIdentity.ownerBinaryID
        }
        guard hasRequestOwnedMappedAddress(key, ownerBinaryID: ownerBinaryID) else {
            invalidateAuthoringPresentation(request.id)
            rejectStaleAuthoringRequest("The address that owned this data-shape request is no longer available.")
            return false
        }
        switch request.shape {
        case .array:
            guard let count = Int(request.countText.trimmingCharacters(in: .whitespaces)),
                  count > 0, count <= DataShapeOverride.maxElementCount else {
                lastIssue = "Array count must be a positive integer ≤ \(DataShapeOverride.maxElementCount)."
                return false
            }
            let type = request.elementType.trimmingCharacters(in: .whitespacesAndNewlines)
            setDataShape(key, DataShapeOverride(
                kind: .array,
                elementType: type.isEmpty ? nil : type,
                elementCount: count
            ))
        case .string:
            if request.isNullTerminated {
                setDataShape(key, DataShapeOverride(kind: .string, isNullTerminated: true))
            } else {
                guard let length = Int(request.stringLengthText.trimmingCharacters(in: .whitespaces)),
                      length > 0, length <= DataShapeOverride.maxStringLength else {
                    lastIssue = "String length must be a positive integer ≤ \(DataShapeOverride.maxStringLength)."
                    return false
                }
                setDataShape(key, DataShapeOverride(
                    kind: .string,
                    isNullTerminated: false,
                    stringLength: length
                ))
            }
        case .alignment:
            guard let boundary = Int(request.boundaryText.trimmingCharacters(in: .whitespaces)),
                  boundary > 1, boundary <= DataShapeOverride.maxAlignment,
                  boundary & (boundary - 1) == 0 else {
                lastIssue = "Alignment boundary must be a power of two (2, 4, 8, 16…) up to \(DataShapeOverride.maxAlignment)."
                return false
            }
            setDataShape(key, DataShapeOverride(kind: .alignment, alignment: boundary))
        }
        invalidateAuthoringPresentation(request.id)
        dataShapeEditorRequest = nil
        lastIssue = nil
        return true
    }

    func cancelDataShapeEditor(_ request: DataShapeEditorRequest) {
        guard dataShapeEditorRequest?.hasSameOpeningPresentation(as: request) == true else { return }
        invalidateAuthoringPresentation(request.id)
        dataShapeEditorRequest = nil
    }

    func cancelDataShapeEditor() {
        guard let request = dataShapeEditorRequest else { return }
        cancelDataShapeEditor(request)
    }

    /// Routes an authoring notification to its `begin…` presenter. Extracted from the
    /// `AuthoringCommandHandlers` view modifier so the notification→action wiring is
    /// unit-testable (a SwiftUI `.onReceive` inside a ViewModifier cannot be exercised from a
    /// unit test); the modifier is now a thin forwarder. Returns whether `name` was handled.
    @discardableResult
    func routeAuthoringCommand(_ name: Notification.Name, object: Any? = nil) -> Bool {
        switch name {
        case .macScopeMakeData: beginMakeDataAtSelection()
        case .macScopeImportCHeader: beginCHeaderImport()
        case .macScopeRenameRegister: beginRegisterRenameAtSelection(register: (object as? String) ?? "")
        case .macScopeSetLocalLabel: beginLocalLabelEditAtSelection()
        default: return false
        }
        return true
    }

    // MARK: - Import C Header presentation

    /// Opens the Import C Header sheet (an empty paste area). Clears any prior import
    /// summary so the sheet starts clean.
    func beginCHeaderImport() {
        cHeaderImportSummary = nil
        cHeaderImportRequest = CHeaderImportRequest()
    }

    /// Parses the pasted C source into the type catalog and stores the summary so the
    /// sheet can report what was added/skipped. The sheet stays open so the user sees the
    /// result; they dismiss it explicitly.
    func commitCHeaderImport(_ source: String) {
        cHeaderImportSummary = defineTypesFromCHeader(source)
    }

    func cancelCHeaderImport() {
        cHeaderImportRequest = nil
        cHeaderImportSummary = nil
    }

    /// Applies one exact currently presented editor request (empty text clears the override).
    /// A callback from a canceled/replaced sheet or an invalidated owner is rejected without
    /// dismissing whichever request is currently visible.
    func commitOverrideEditor(_ request: OverrideEditorRequest, text: String) {
        guard authoringPresentationIsCurrent(request.id),
              overrideEditorRequest == request else {
            invalidateAuthoringPresentation(request.id)
            rejectStaleAuthoringRequest(
                "The entity that owned this editor request is no longer available."
            )
            return
        }
        let key = ImageAddress(slot: request.imageSlot, address: request.address)
        let ownsCurrentEntity: Bool
        switch request.kind {
        case .rename:
            ownsCurrentEntity = hasRequestOwnedFunctionStart(
                key,
                ownerBinaryID: request.ownerBinaryID
            )
        case .comment, .tag:
            ownsCurrentEntity = hasRequestOwnedInstruction(
                key,
                ownerBinaryID: request.ownerBinaryID
            )
        case .localLabel:
            ownsCurrentEntity = hasRequestOwnedMappedAddress(
                key,
                ownerBinaryID: request.ownerBinaryID
            )
        }
        guard ownsCurrentEntity else {
            invalidateAuthoringPresentation(request.id)
            rejectStaleAuthoringRequest("The entity that owned this editor request is no longer available.")
            return
        }
        switch request.kind {
        case .rename: setCustomName(key, name: text)
        case .comment: setCustomComment(key, comment: text)
        case .tag: setTag(key, tag: text)
        case .localLabel:
            // `address` is the labelled address; an empty string clears the label.
            setLocalLabel(key, label: text)
        }
        invalidateAuthoringPresentation(request.id)
        overrideEditorRequest = nil
    }

    /// Synchronous compatibility for existing single-sheet callers. Interactive callbacks pass
    /// their captured request through the overload above so replacement races are observable.
    func commitOverrideEditor(_ text: String) {
        guard let request = overrideEditorRequest else { return }
        commitOverrideEditor(request, text: text)
    }

    func cancelOverrideEditor(_ request: OverrideEditorRequest) {
        guard overrideEditorRequest?.id == request.id else { return }
        invalidateAuthoringPresentation(request.id)
        overrideEditorRequest = nil
    }

    func cancelOverrideEditor() {
        guard let request = overrideEditorRequest else { return }
        cancelOverrideEditor(request)
    }

    private func enclosingFunction(for address: UInt64) -> FunctionSummary? {
        enclosingFunction(for: address, in: focusedImageSlot)
    }

    private func enclosingFunction(for address: UInt64, in slot: ImageSlot) -> FunctionSummary? {
        let functions = snapshot.analysis(in: slot)?.functions ?? []
        return functions.first { function in
            if function.endAddress > function.startAddress {
                return address >= function.startAddress && address < function.endAddress
            }
            return address == function.startAddress
        } ?? functions.last { $0.startAddress <= address }
    }

    /// Navigates to `address`: the disassembly when an instruction is decoded there,
    /// otherwise the hex view when the address is within the loaded byte window
    /// (data / padding / unanalyzed), otherwise a surfaced "outside the binary"
    /// issue. Lets Go-To reach raw addresses, not just indexed instructions.
    /// Returns whether it actually navigated (false = out of range, issue surfaced).
    /// Navigate to `address` in the FOCUSED image (the single-image default). A thin wrapper over the
    /// slot-aware `goToAddress(_:in:)`; single-image behaviour is unchanged (focused == primary).
    @discardableResult
    func goToAddress(_ address: UInt64) -> Bool {
        goToAddress(address, in: focusedImageSlot)
    }

    /// WS-8: navigate to `address` interpreted in `slot`'s image-VA space — focus that image if
    /// needed, then select. Resolves against `analysis(in: slot)`, NOT the primary projection, so
    /// Go-to / Find land in the right image in a multi-image workspace. Returns whether the address
    /// exists in that image.
    ///
    /// Ordering matters: `focusImage` resets transient selection, so it MUST run before
    /// `selectInstruction` — otherwise the freshly-set selection is cleared.
    @discardableResult
    func goToAddress(_ address: UInt64, in slot: ImageSlot) -> Bool {
        guard let binary = snapshot.binary(in: slot) else {
            lastIssue = "Target image is no longer loaded."
            return false
        }
        guard snapshot.containsLoadedAddress(address, in: slot) else {
            lastIssue = "Address \(address.hexAddress) is outside \(binary.name)."
            return false
        }
        if slot != focusedImageSlot { focusImage(slot) }
        selectInstruction(address)
        let isInstruction = snapshot.analysis(in: slot)?.instructions.contains { $0.address == address } ?? false
        editorMode = isInstruction ? .disassembly : .hex
        return true
    }

    /// WS-8: every loaded image whose instructions / mapped sections contain `address` (ascending
    /// slot). The collision resolver behind Go-to disambiguation; one element for a single-image
    /// workspace, empty when no image holds the address.
    func imagesContaining(_ address: UInt64) -> [ImageSlot] {
        snapshot.binaries.map(\.slot).sorted().filter { snapshot.containsLoadedAddress(address, in: $0) }
    }

    /// Resolves a Go-To query and navigates: a `0x`-prefixed hex address, else a
    /// known symbol/function name, else a bare hex number (in that order). Returns
    /// whether navigation actually succeeded — a query that resolves to nothing OR
    /// to an out-of-range address returns false (with a surfaced issue) so the sheet
    /// stays open for correction.
    @discardableResult
    func goTo(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // WS-7/8: a hex value honors the display mode — in runtime mode it is a runtime VA resolved
        // to its owning image; in image mode it targets the focused image. A symbol NAME is per-image
        // (not a runtime VA), so it always uses the focused-image goto.
        if trimmed.lowercased().hasPrefix("0x"), let address = parseHexAddress(trimmed) {
            return gotoRuntimeOrImage(address)
        }
        if let address = snapshot.address(forSymbolName: trimmed, in: focusedImageSlot) {
            return goToAddress(address)
        }
        if let address = parseHexAddress(trimmed) {
            return gotoRuntimeOrImage(address)
        }
        lastIssue = "Enter a hex address or a known symbol name."
        return false
    }

    /// Runs a binary `Find` over the loaded snapshot (text / regex / hex). Pure and
    /// read-only; the `Find` sheet calls this and navigates to a chosen result. The
    /// `total` is the full de-duplicated match count before the display cap.
    func runSearch(
        _ query: String,
        mode: BinarySearchMode,
        scope: BinarySearchScope = .everything
    ) -> (results: [BinarySearchResult], total: Int) {
        var scoped = scope
        scoped.focusedSlot = focusedImageSlot
        return BinarySearchService().searchWithCount(query: query, mode: mode, in: snapshot, scope: scoped)
    }

    /// A validation message for the current query/mode (bad regex, odd hex), or nil
    /// when the query is well-formed.
    func searchValidationMessage(_ query: String, mode: BinarySearchMode) -> String? {
        BinarySearchService().validate(query: query, mode: mode)
    }

    /// Navigates to a cross-reference endpoint: the disassembly when an instruction
    /// exists there, otherwise the hex view at that address (data targets — strings,
    /// globals, selector slots — have no instruction). Mirrors the strings-navigation
    /// hex fallback rather than failing into `lastIssue` like `goToAddress`.
    @discardableResult
    func navigateToReference(_ address: UInt64) -> Bool {
        navigateToReference(ImageAddress(slot: focusedImageSlot, address: address))
    }

    /// Captures the exact image owner and local XRef entity that produced an inspector row.
    func xrefNavigationTarget(
        for xref: XRef,
        endpoint: UInt64,
        in slot: ImageSlot
    ) -> XRefNavigationTarget? {
        guard let ownerBinaryID = snapshot.binary(in: slot)?.id,
              endpoint == xref.from || endpoint == xref.to,
              snapshot.effectiveXRefs(from: xref.from, in: slot).contains(xref) else {
            return nil
        }
        return XRefNavigationTarget(
            imageSlot: slot,
            ownerBinaryID: ownerBinaryID,
            xref: xref,
            endpoint: endpoint
        )
    }

    /// A retained XRef row is accepted only while its original image is focused and the exact edge
    /// still exists. Reanalysis, image replacement, or a focus change makes the callback inert.
    @discardableResult
    func navigateToReference(_ target: XRefNavigationTarget) -> Bool {
        guard target.imageSlot == focusedImageSlot,
              isCurrentRequestOwner(
                  target.imageSlot,
                  ownerBinaryID: target.ownerBinaryID
              ),
              target.endpoint == target.xref.from || target.endpoint == target.xref.to,
              snapshot.effectiveXRefs(
                  from: target.xref.from,
                  in: target.imageSlot
              ).contains(target.xref) else {
            return false
        }
        return navigateToReference(
            ImageAddress(slot: target.imageSlot, address: target.endpoint)
        )
    }

    @discardableResult
    private func navigateToReference(_ target: ImageAddress) -> Bool {
        guard target.slot == focusedImageSlot, selectAddress(target) else { return false }
        // WS-8: decide disassembly-vs-hex against the FOCUSED image (not the primary projection), so
        // following a reference inside a focused secondary image picks the right editor mode.
        let isInstruction = snapshot.analysis(in: target.slot)?.instructions
            .contains { $0.address == target.address } ?? false
        editorMode = isInstruction ? .disassembly : .hex
        return true
    }

    /// Navigates to an Imports/Exports/Sections browser row's address and dismisses
    /// the browser sheet. Address-less rows (import stubs, forwarder exports) carry no
    /// `address`, so they are inert — `BrowserNavigationTarget` already filters those
    /// out, and this guards again so a nil target never closes the sheet pointlessly.
    @discardableResult
    func navigateFromBrowser(to address: UInt64?) -> Bool {
        navigateFromBrowser(to: address, in: focusedImageSlot)
    }

    func browserNavigationTarget(
        forExportID id: UUID,
        address: UInt64?,
        in slot: ImageSlot
    ) -> BrowserRowNavigationTarget? {
        guard let address,
              isCurrentRequestOwner(slot, ownerBinaryID: snapshot.binary(in: slot)?.id),
              snapshot.analysis(in: slot)?.exports.contains(where: {
                  $0.id == id && $0.address == address
              }) == true else {
            return nil
        }
        return BrowserRowNavigationTarget(
            imageAddress: ImageAddress(slot: slot, address: address),
            ownerBinaryID: snapshot.binary(in: slot)?.id,
            entity: .export(id)
        )
    }

    func browserNavigationTarget(
        forSectionID id: UUID,
        address: UInt64,
        in slot: ImageSlot
    ) -> BrowserRowNavigationTarget? {
        guard isCurrentRequestOwner(slot, ownerBinaryID: snapshot.binary(in: slot)?.id),
              snapshot.analysis(in: slot)?.sections.contains(where: {
                  $0.id == id && $0.address == address
              }) == true else {
            return nil
        }
        return BrowserRowNavigationTarget(
            imageAddress: ImageAddress(slot: slot, address: address),
            ownerBinaryID: snapshot.binary(in: slot)?.id,
            entity: .section(id)
        )
    }

    /// Browser rows capture the image slot that produced them. Focus changes while the panel is
    /// pending cannot redirect a bare coordinate, and a rejected callback leaves the panel open.
    @discardableResult
    func navigateFromBrowser(to address: UInt64?, in slot: ImageSlot) -> Bool {
        guard let address,
              navigateToReference(ImageAddress(slot: slot, address: address)) else {
            return false
        }
        showBrowsers = false
        return true
    }

    /// Rendered browser rows must still name the same binary and the same current export/section.
    @discardableResult
    func navigateFromBrowser(_ target: BrowserRowNavigationTarget) -> Bool {
        guard target.imageAddress.slot == focusedImageSlot,
              isCurrentRequestOwner(
                  target.imageAddress.slot,
                  ownerBinaryID: target.ownerBinaryID
              ),
              let analysis = snapshot.analysis(in: target.imageAddress.slot) else {
            return false
        }
        let entityStillExists: Bool
        switch target.entity {
        case let .export(id):
            entityStillExists = analysis.exports.contains {
                $0.id == id && $0.address == target.imageAddress.address
            }
        case let .section(id):
            entityStillExists = analysis.sections.contains {
                $0.id == id && $0.address == target.imageAddress.address
            }
        }
        guard entityStillExists, navigateToReference(target.imageAddress) else { return false }
        showBrowsers = false
        return true
    }

    // MARK: - Back/forward navigation history

    var canNavigateBack: Bool { navigationHistory.canGoBack }
    var canNavigateForward: Bool { navigationHistory.canGoForward }

    /// Browser-style Back: returns to the previously visited address.
    func navigateBack() {
        pruneNavigationHistory()
        guard let address = navigationHistory.goBack() else { return }
        applyHistoryNavigation(to: address)
    }

    /// Browser-style Forward: re-advances to an address a prior Back stepped away from.
    func navigateForward() {
        pruneNavigationHistory()
        guard let address = navigationHistory.goForward() else { return }
        applyHistoryNavigation(to: address)
    }

    private func applyHistoryNavigation(to location: WorkspaceNavigationLocation) {
        guard isCurrentNavigationLocation(location) else { return }
        suppressHistoryRecording = true
        defer { suppressHistoryRecording = false }
        focusImage(location.target.slot)
        guard selectAddress(location.target) else { return }
        editorMode = location.editorMode
    }

    private func navigationLocation(at address: UInt64) -> WorkspaceNavigationLocation? {
        let target = ImageAddress(slot: focusedImageSlot, address: address)
        guard snapshot.containsLoadedAddress(address, in: target.slot) else { return nil }
        return .init(sessionID: navigationHistorySessionID, workspaceID: workspaceID,
            documentID: documentID, target: target,
            binaryID: snapshot.binary(in: target.slot)?.id, editorMode: editorMode)
    }

    private func resetNavigationHistory(seed address: UInt64?) {
        navigationHistory.reset(seed: address.flatMap { navigationLocation(at: $0) })
    }

    private func isCurrentNavigationLocation(_ location: WorkspaceNavigationLocation) -> Bool {
        guard location.sessionID == navigationHistorySessionID,
              location.workspaceID == workspaceID, location.documentID == documentID else { return false }
        if let binaryID = location.binaryID {
            guard snapshot.binary(in: location.target.slot)?.id == binaryID else { return false }
        } else {
            guard snapshot.binaries.isEmpty, location.target.slot == snapshot.primarySlot else { return false }
        }
        return snapshot.containsLoadedAddress(location.target.address, in: location.target.slot)
    }

    private func pruneNavigationHistory() {
        navigationHistory.prune(keeping: isCurrentNavigationLocation)
    }

    /// The browsable navigation-history rows for the History panel, newest visit first.
    /// Each row carries the address plus resolved symbol/section context so the panel can
    /// label it without re-deriving from the snapshot. The current cursor is flagged so the
    /// panel can highlight it. Pure projection over `navigationHistory` + the snapshot.
    var navigationHistoryRows: [NavigationHistoryRow] {
        navigationHistory.panelEntries.map { entry in
            // Reuse the canonical address labeler the listing/inspector use (function names,
            // strings, selectors, exports/symbols, function-relative offsets), so a history
            // row reads identically to the location it points at. It falls back to the bare
            // hex when nothing names the address — in which case the row has no symbol.
            let target = entry.location.target
            let analysis = snapshot.analysis(in: target.slot)
            var imageSnapshot = WorkspaceSnapshot(
                binaries: [], analysisBySlot: [.primary: analysis ?? ImageAnalysis()]
            )
            imageSnapshot.addressOverrides = Dictionary(uniqueKeysWithValues: snapshot.addressOverrides
                .filter { $0.key.slot == target.slot }.map {
                    (ImageAddress.primary($0.key.address), $0.value)
                })
            let label = imageSnapshot.symbolizedLabel(for: target.address)
            let symbolName = label == target.address.hexAddress ? nil : label
            return NavigationHistoryRow(
                panelIndex: entry.panelIndex,
                address: target.address,
                symbolName: symbolName,
                sectionName: snapshot.section(containing: target.address, in: target.slot)?.name,
                isCurrent: entry.isCurrent,
                imageName: snapshot.binaries.count > 1 ? snapshot.binary(in: target.slot)?.name : nil
            )
        }
    }

    /// Navigates to the history entry at `panelIndex` (a row's `panelIndex`), moving the
    /// back/forward cursor there WITHOUT truncating forward history — selecting an older row
    /// then a newer one both work, exactly like the Back/Forward buttons. A no-op for a
    /// stale/out-of-range index.
    func navigateToHistoryEntry(at panelIndex: Int) {
        pruneNavigationHistory()
        guard let address = navigationHistory.jump(to: panelIndex) else { return }
        applyHistoryNavigation(to: address)
    }

    private func selectionAddress(
        for target: GraphSelectionTarget,
        in projection: FocusedGraphProjection
    ) -> UInt64 {
        projection.instructions.first { row in
            target.contains(ImageAddress(slot: projection.imageSlot, address: row.address))
        }?.address ?? target.startAddress
    }

    private func currentGraphTargetIndex(in targets: [GraphSelectionTarget]) -> Int? {
        if let selectedGraphElementID,
           let exactIndex = targets.firstIndex(where: { $0.id == selectedGraphElementID }) {
            return exactIndex
        }

        guard let target = graphTarget(for: selectedImageAddress, in: targets) else {
            return nil
        }

        return targets.firstIndex { $0.id == target.id }
    }

    private func syncGraphElementToSelectedAddress() {
        let targets = graphNodeSelectionTargets
        selectedGraphElementID = graphTarget(for: selectedImageAddress, in: targets)?.id
    }

    func syncSidebarSelection(functionID: UUID?) {
        guard let functionID else { return }

        switch selectedTool {
        case .project:
            selectedSidebarItemID = "function:\(functionID.uuidString)"
        case .symbols:
            selectedSidebarItemID = "symbol:\(functionID.uuidString)"
        default:
            break
        }
    }

    private func graphTarget(
        for selection: ImageAddress?,
        in targets: [GraphSelectionTarget]
    ) -> GraphSelectionTarget? {
        guard let selection else { return nil }
        if let containingTarget = targets.first(where: { $0.contains(selection) }) {
            return containingTarget
        }

        let projection = snapshot.graphProjection(in: selection.slot)
        guard let containingFunction = function(containing: selection, in: projection) else {
            return nil
        }

        let functionTargets = targets.filter { $0.functionID == containingFunction.id }
        guard !functionTargets.isEmpty else { return nil }

        return functionTargets.last { $0.startAddress <= selection.address }
            ?? functionTargets.first
    }

    private func function(
        containing selection: ImageAddress,
        in projection: FocusedGraphProjection
    ) -> FunctionSummary? {
        guard selection.slot == projection.imageSlot else { return nil }
        return projection.functions
            .sorted { lhs, rhs in
                if lhs.startAddress == rhs.startAddress {
                    return lhs.name < rhs.name
                }
                return lhs.startAddress < rhs.startAddress
            }
            .first { function in
                if function.endAddress > function.startAddress {
                    return selection.address >= function.startAddress
                        && selection.address < function.endAddress
                }
                return selection.address == function.startAddress
            }
    }

    private func imageLocalGraphElementID(_ id: String, in slot: ImageSlot) -> String? {
        let prefix = "image:\(slot.rawValue):"
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    private func currentGraphNodeTarget(
        matching captured: GraphSelectionTarget
    ) -> GraphSelectionTarget? {
        guard captured.imageSlot == focusedImageSlot,
              let capturedElementID = imageLocalGraphElementID(
                captured.id,
                in: captured.imageSlot
              ) else {
            return nil
        }

        return graphNodeSelectionTargets.first { current in
            current.imageSlot == captured.imageSlot
                && current.ownerBinaryID == captured.ownerBinaryID
                && imageLocalGraphElementID(current.id, in: current.imageSlot) == capturedElementID
                && current.startAddress == captured.startAddress
                && current.endAddress == captured.endAddress
                && current.functionID == captured.functionID
        }
    }

    private func isValidGraphNodeMultiSelection(_ addresses: Set<ImageAddress>) -> Bool {
        guard let slot = addresses.first?.slot,
              slot == focusedImageSlot,
              addresses.allSatisfy({ $0.slot == slot }) else {
            return false
        }
        let currentStarts = Set(graphNodeSelectionTargets.map {
            ImageAddress(slot: $0.imageSlot, address: $0.startAddress)
        })
        return addresses.isSubset(of: currentStarts)
    }

    /// Membership is projected through the exact same production model as `GraphView`; viewport
    /// affects geometry only, never node/edge identity.
    private var currentGraphEdgeSelectionTargets: [GraphEdgeSelectionTarget] {
        FocusedGraphBuilder.build(focusedGraphProjection, viewport: .zero)
            .edges
            .map(\.selectionTarget)
    }

    private func xref(
        for target: GraphEdgeSelectionTarget,
        in projection: FocusedGraphProjection
    ) -> XRef? {
        guard target.imageSlot == projection.imageSlot else { return nil }
        if target.elementID.hasPrefix("xref:") {
            let rawID = target.elementID.components(separatedBy: ":").dropFirst().joined(separator: ":")
            if let uuid = UUID(uuidString: rawID) {
                return projection.xrefs.first { $0.id == uuid }
            }
        }

        return projection.xrefs.first {
            $0.from == target.fromAddress
                && $0.to == target.toAddress
                && $0.kind == target.kind
        }
    }

    private func xref(
        forGraphElementID id: String,
        from fromAddress: UInt64,
        to toAddress: UInt64,
        kind: String,
        in projection: FocusedGraphProjection
    ) -> XRef? {
        if id.hasPrefix("xref:") {
            let rawID = id.components(separatedBy: ":").dropFirst().joined(separator: ":")
            if let uuid = UUID(uuidString: rawID) {
                return projection.xrefs.first { $0.id == uuid }
            }
        }

        return projection.xrefs.first {
            $0.from == fromAddress && $0.to == toAddress && $0.kind == kind
        }
    }

    private static func normalizedStringPreview(_ value: String) -> String {
        let collapsed = value.unicodeScalars.map { scalar -> String in
            if scalar == " " {
                return " "
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()

        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > AppSidebarChrome.stringPreviewMaxLength else {
            return trimmed
        }

        let prefix = trimmed.prefix(AppSidebarChrome.stringPreviewMaxLength)
        return "\(prefix)…"
    }

    private static func originalPathBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

// MARK: - RX-01 annotation transfer commit (D10: inside WorkspaceStore.swift)

/// A reviewed transfer the user asked to apply: the exact compared pair (owners and analysis
/// fingerprints at compare time) and the planner preview built from the review selection.
struct AnnotationTransferCommitRequest: Hashable, Sendable {
    let pair: VersionComparePair
    let preview: AnnotationTransferPreview
}

enum AnnotationTransferSide: String, Hashable, Sendable { case old, new }

/// Why a commit wrote nothing. Every case is checked before any write.
enum AnnotationTransferRefusal: Error, Hashable, Sendable {
    case sameImage
    case imageReplaced(AnnotationTransferSide)
    case analysisChanged(AnnotationTransferSide)
    case reanalysisInFlight(AnnotationTransferSide)
    case destinationChanged([UInt64])
    case sourceChanged([UInt64])
    case destinationNotFunctionStart([UInt64])
    /// A change targets an address the preview never examined (defensive; never built by the planner).
    case unexaminedDestination([UInt64])
}

enum AnnotationTransferCommitOutcome: Hashable, Sendable {
    case applied(names: Int, comments: Int, conflicts: Int)
    case nothingToApply(conflicts: Int)
    case refused(AnnotationTransferRefusal)
}

extension WorkspaceStore {
    static let annotationTransferActionName = "Transfer Names and Comments"

    /// Re-validates both images and every examined annotation, then writes the destination slot's
    /// names and comments as ONE undoable step ("Transfer Names and Comments"). Synchronous on the
    /// MainActor, so the checks and the write share one turn. Nothing is overwritten: the planner
    /// only proposes fields whose destination is empty, and a destination edited since the preview
    /// refuses the whole commit. No reanalysis (names and comments are not structural).
    @discardableResult
    func commitAnnotationTransfer(_ request: AnnotationTransferCommitRequest) -> AnnotationTransferCommitOutcome {
        let pair = request.pair, preview = request.preview
        guard pair.old.slot != pair.new.slot else { return .refused(.sameImage) }
        for (side, image) in [(AnnotationTransferSide.old, pair.old), (.new, pair.new)] {
            guard snapshot.binary(in: image.slot)?.id == image.binaryID else {
                return .refused(.imageReplaced(side))
            }
            guard let analysis = snapshot.analysis(in: image.slot),
                  analysis.analysisInputFingerprint?.overallSHA256 == image.analysisFingerprint else {
                return .refused(.analysisChanged(side))
            }
            guard reanalysisTasksBySlot[image.slot] == nil else { return .refused(.reanalysisInFlight(side)) }
        }
        let destination = AnnotationTransferCandidates.annotations(
            in: pair.new.slot, at: preview.expectedDestination.keys, snapshot: snapshot)
        let staleDestinations = preview.staleDestinations(destination)
        guard staleDestinations.isEmpty else { return .refused(.destinationChanged(staleDestinations)) }
        let source = AnnotationTransferCandidates.annotations(
            in: pair.old.slot, at: preview.expectedSource.keys, snapshot: snapshot)
        let staleSources = preview.staleSources(source)
        guard staleSources.isEmpty else { return .refused(.sourceChanged(staleSources)) }
        let unexamined = preview.changes.map(\.destinationAddress)
            .filter { preview.expectedDestination[$0] == nil }
        guard unexamined.isEmpty else { return .refused(.unexaminedDestination(unexamined.sorted())) }
        let starts = Set(snapshot.analysis(in: pair.new.slot)?.functions.map(\.startAddress) ?? [])
        let missing = preview.changes.map(\.destinationAddress).filter { !starts.contains($0) }
        guard missing.isEmpty else { return .refused(.destinationNotFunctionStart(missing.sorted())) }
        guard !preview.changes.isEmpty else { return .nothingToApply(conflicts: preview.conflicts.count) }

        var partition = snapshot.addressOverrides.filter { $0.key.slot == pair.new.slot }
        for change in preview.changes {
            let key = ImageAddress(slot: pair.new.slot, address: change.destinationAddress)
            var override = partition[key] ?? AddressOverride()
            // The staleness check above guarantees these fields are still empty.
            if let name = change.newName { override.customName = Self.normalizedOverrideText(name) }
            if let comment = change.newComment { override.customComment = Self.normalizedOverrideText(comment) }
            partition[key] = override
        }
        applyOverrideMap(partition, in: pair.new.slot,
                         actionName: Self.annotationTransferActionName, reanalyze: false)
        return .applied(names: preview.nameCount, comments: preview.commentCount,
                        conflicts: preview.conflicts.count)
    }
}

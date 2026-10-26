import Foundation
import SwiftUI
import LumenTokens
import LumenUI

struct InspectorView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(store: store)

            let typeEntry = store.selectedTypeAtlasEntry
            let hasSelection = store.selectedImageAddress != nil
            let diagnostics = ImageDiagnosticsInspectorSection.groups(for: store.focusedAnalysis?.diagnostics ?? [])
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // U7a: the type picked in the Types navigator leads; an address selection
                    // still shows its sections below it.
                    if let typeEntry {
                        TypeAtlasInspector(store: store, entry: typeEntry)
                    }
                    if hasSelection {
                        InspectorSummaryCard(store: store)
                        SelectionInspectorSection(store: store)
                        ProcedureInspectorSection(store: store)
                        if let target = store.selectedImageAddress {
                            SourceLinksView(store: store, slot: target.slot, address: target.address,
                                            origin: .inspector(slot: target.slot))
                                .padding()
                        }
                        AppliedTypeInspectorSection(store: store)
                        SwitchHintInspectorSection(store: store)
                        DataInspectorSection(store: store)
                        AddressDetailInspectorSection(store: store)
                        SegmentInspectorSection(store: store)
                        XRefsInspectorSection(store: store)
                        LogicalBreakpointInspectorSection(store: store)
                        AnalysisInspectorSection(store: store)
                    } else if typeEntry == nil {
                        InspectorEmptyLine(Self.emptyMessage)
                    }
                    if !hasSelection, let binary = store.snapshot.binary(in: store.focusedImageSlot) {
                        SourceLinksView(store: store, slot: binary.slot, address: 0,
                                        origin: .inspector(slot: binary.slot))
                            .padding()
                    }
                    // The image's loader and metadata findings show with or without a selection.
                    ImageDiagnosticsInspectorSection(store: store, groups: diagnostics)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Lumen 0.14.0: with nothing selected, one message instead of a
            // paragraph in every section; the sections return with a selection.
            .dsInspectorEmptyState(!hasSelection && typeEntry == nil && diagnostics.isEmpty
                                  && store.snapshot.binary(in: store.focusedImageSlot) == nil,
                                  message: Self.emptyMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .workbenchPaneBackground(.inspector)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityPresentation.label)
        .accessibilityIdentifier("workspace.pane.inspector")
    }

    static let emptyMessage = "Select an instruction to see its bytes, function, data and cross-references."

    private var accessibilityPresentation: FocusedPresentationAccessibility.InspectorPresentation {
        FocusedPresentationAccessibility.inspector(
            snapshot: store.snapshot,
            focusedSlot: store.focusedImageSlot,
            target: store.selectedImageAddress
        )
    }
}

private struct InspectorHeader: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        DSInspectorHeader(title: title, subtitle: subtitle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workbenchPaneBackground(.inspector)
    }

    private var title: String {
        guard let instruction = store.selectedInstruction else {
            return "Inspector"
        }
        let rowState = DisassemblyListingBuilder.interpretation(
            of: instruction, snapshot: store.snapshot, slot: store.focusedImageSlot
        )
        if rowState.isUndefined {
            return rowState.undefinedDirective?.mnemonic
                ?? WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes).mnemonic
        }
        if rowState.isData {
            return rowState.shapeDirective?.mnemonic
                ?? WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes).mnemonic
        }
        return instruction.mnemonic
    }

    private var subtitle: String {
        store.selectedImageAddress?.address.hexAddress ?? "No selection"
    }
}

/// Lumen inspector summary: what the selection is,
/// its address with copy, its function as a link with offset and section, and callers, blocks and
/// bytes as counts. The sections below keep the details.
private struct InspectorSummaryCard: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if let address = store.selectedImageAddress?.address {
            let slot = store.focusedImageSlot
            let reading = ProcedureInspectorReading(store: store)
            let function = reading.function
            let functionName = function.map {
                store.snapshot.displayName(at: $0.startAddress, in: slot, default: $0.name)
            }
            let section = store.snapshot.section(containing: address, in: slot)?.name
            let offset = function.map { address - $0.startAddress }
            LumenInspectorSummary(
                kind: kind.title,
                hue: kind.hue,
                title: address.hexAddress,
                link: functionName,
                detail: [offset.map { String(format: "+0x%llX", $0) }, section].compactMap(\.self).joined(separator: " · "),
                stats: stats(reading: reading),
                onOpenLink: function.map { fn in { _ = store.goToAddress(fn.startAddress) } }
            )
            .padding(Lumen.Space.s4)
        }
    }

    private var kind: (title: String, hue: LumenToken) {
        if store.selectedStringLiteral != nil { return ("String", .hueOrange) }
        guard let instruction = store.selectedInstruction else { return ("Address", .hueGraphite) }
        let interpretation = DisassemblyListingBuilder.interpretation(
            of: instruction, snapshot: store.snapshot, slot: store.focusedImageSlot
        )
        if interpretation.isUndefined { return ("Undefined", .hueGraphite) }
        if interpretation.isData { return ("Data", .hueOrange) }
        return ("Instruction", .hueBlue)
    }

    /// Callers and blocks as the Function section counts them (de-duplicated call pairs landing
    /// anywhere in the function), and the selection's size.
    private func stats(reading: ProcedureInspectorReading) -> [LumenStat] {
        var counts: [LumenStat] = []
        if reading.isResolved {
            counts.append(LumenStat("Callers", count: reading.callerCount))
            counts.append(LumenStat("Blocks", count: reading.blockCount))
        }
        if let literal = store.selectedStringLiteral {
            counts.append(LumenStat("Bytes", count: literal.byteLength))
        } else if let instruction = store.selectedInstruction {
            counts.append(LumenStat("Bytes", count: instruction.bytes.filter(\.isHexDigit).count / 2))
        }
        return counts
    }
}

private struct SelectionInspectorSection: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        InspectorSection(id: .selection, title: "Selection", systemImage: "scope") {
            if let literal = store.selectedStringLiteral {
                InspectorValueGroup {
                    // The address and length are on the summary card.
                    MetadataRow(label: "Value", value: literal.value.isEmpty ? "-" : literal.value)
                    MetadataRow(label: "Section", value: literal.sourceSection)
                }
            } else if let instruction = store.selectedInstruction {
                // Mirror the resolved listing exactly. Undefined wins over data/shape so stale
                // decoder semantics cannot reappear in the visible or spoken inspector.
                let rowState = DisassemblyListingBuilder.interpretation(
                    of: instruction, snapshot: store.snapshot, slot: store.focusedImageSlot
                )
                let isUndefined = rowState.isUndefined
                let isData = rowState.isData
                let isDirective = isUndefined || isData
                let directive: DataDirective? = {
                    if isUndefined {
                        return rowState.undefinedDirective ?? {
                            let raw = WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes)
                            return DataDirective(
                                mnemonic: raw.mnemonic,
                                operands: raw.operands + "  ; undefined"
                            )
                        }()
                    }
                    if isData {
                        return rowState.shapeDirective.map {
                            DataDirective(mnemonic: $0.mnemonic, operands: $0.operands)
                        } ?? {
                            let raw = WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes)
                            return DataDirective(mnemonic: raw.mnemonic, operands: raw.operands)
                        }()
                    }
                    return nil
                }()
                let mnemonic = directive?.mnemonic ?? instruction.mnemonic
                let operands = directive?.operands ?? store.snapshot.displayOperands(
                    at: instruction.address,
                    in: store.focusedImageSlot,
                    default: instruction.operands
                )
                let comment = DisassemblyListingBuilder.resolvedComment(
                    snapshot: store.snapshot,
                    instruction: instruction,
                    slot: store.focusedImageSlot
                )
                // The address and byte count are on the summary card; the bytes themselves stay here.
                InspectorValueGroup {
                    MetadataRow(label: isDirective ? "Directive" : "Mnemonic", value: mnemonic, isMonospaced: true)
                    MetadataRow(label: isDirective ? "Value" : "Operands", value: operands.isEmpty ? "-" : operands, isMonospaced: true)
                    MetadataRow(label: "Bytes", value: instruction.bytes, isMonospaced: true)
                    if isDirective {
                        MetadataRow(label: "Kind", value: isUndefined ? "Undefined" : "Data")
                    }
                    if let comment, !comment.isEmpty {
                        MetadataRow(label: "Comment", value: comment)
                    }
                    // Recovered DWARF source location (present only after a matched dSYM is imported).
                    if let source = store.snapshot.sourceLine(at: instruction.address, in: store.focusedImageSlot) {
                        let location = source.file.map { "\($0):\(source.line)" } ?? "line \(source.line)"
                        MetadataRow(label: "Source", value: location, isMonospaced: true)
                    }
                }
            } else if store.selectedImageAddress != nil {
                InspectorEmptyLine(
                    FocusedPresentationAccessibility.inspectorEmptySelectionDetail(
                        hasSelectedAddress: true
                    )
                )
            } else {
                InspectorEmptyLine(
                    FocusedPresentationAccessibility.inspectorEmptySelectionDetail(
                        hasSelectedAddress: false
                    )
                )
            }
        }
    }
}

private struct ProcedureInspectorSection: View {
    @ObservedObject var store: WorkspaceStore
    @State private var recoveredSignatureResult: ProcedureSignatureRecoveryResult?

    private var signatureRecoveryRequest: ProcedureSignatureRecoveryRequest? {
        // Do not bind a freshly changed override to analysis rows from the
        // previous generation. The store publishes this gate before replacing
        // the derived image analysis; the completed generation will retrigger
        // the request with its new bounded instruction rows.
        guard !store.isReanalyzing,
              let analysis = store.focusedAnalysis else { return nil }
        return ProcedureSignatureRecoveryRequest(
            slot: store.focusedImageSlot,
            functions: analysis.functions,
            instructions: analysis.instructions,
            selectedAddress: store.selectedAddress,
            addressOverrides: store.snapshot.overrides(in: store.focusedImageSlot)
        )
    }

    private var recoveredSignatures: [UInt64: FunctionSignatureOverride] {
        guard let request = signatureRecoveryRequest,
              let result = recoveredSignatureResult,
              result.request == request,
              let signature = result.signature else {
            return [:]
        }
        return [request.functionStartAddress: signature]
    }

    private var reading: ProcedureInspectorReading {
        ProcedureInspectorReading(store: store, recoveredSignatures: recoveredSignatures)
    }

    var body: some View {
        let recoveryRequest = signatureRecoveryRequest
        InspectorSection(id: .function, title: "Function", systemImage: "function") {
            let reading = reading
            if reading.isResolved {
                InspectorValueGroup {
                    ForEach(reading.rows, id: \.label) { row in
                        MetadataRow(label: row.label, value: row.value, isMonospaced: row.isMonospaced)
                    }
                }
            } else {
                InspectorEmptyLine(reading.availabilityNote)
            }
        }
        .task(id: recoveryRequest) {
            guard let recoveryRequest else {
                recoveredSignatureResult = nil
                return
            }

            let signature = await ProcedureSignatureRecoveryWorker.recover(recoveryRequest)

            // `.task(id:)` cancels the superseded task, while the explicit key
            // comparison also protects against detached work finishing after the
            // user changes image, function, instructions, or a code/data override.
            guard !Task.isCancelled,
                  recoveryRequest == signatureRecoveryRequest else {
                return
            }
            recoveredSignatureResult = ProcedureSignatureRecoveryResult(
                request: recoveryRequest,
                signature: signature
            )
        }
    }
}

/// A bounded, slot-qualified input for recovering only the selected procedure's
/// declaration. Keeping this value hashable makes it both the SwiftUI task key and
/// the stale-result guard; no whole-image decompilation occurs in `body`.
struct ProcedureSignatureRecoveryRequest: Hashable, Sendable {
    let slot: ImageSlot
    let functionName: String
    let functionStartAddress: UInt64
    let instructions: [InstructionRow]

    init?(
        slot: ImageSlot,
        functions: [FunctionSummary],
        instructions: [InstructionRow],
        selectedAddress: UInt64?,
        addressOverrides: [UInt64: AddressOverride]
    ) {
        guard let function = ProcedureInspectorReading.enclosingFunction(
            in: functions,
            selectedAddress: selectedAddress
        ) else {
            return nil
        }

        let boundedInstructions = instructions.filter { row in
            let rowOverride = addressOverrides[row.address]
            let isExcludedFromCode = rowOverride.map {
                $0.isData || $0.isUndefined || !($0.dataShape?.isEmpty ?? true)
            } ?? false
            guard row.address >= function.startAddress,
                  !isExcludedFromCode else {
                return false
            }
            return function.endAddress > function.startAddress
                ? row.address < function.endAddress
                : row.address == function.startAddress
        }

        self.slot = slot
        self.functionName = function.name
        self.functionStartAddress = function.startAddress
        self.instructions = boundedInstructions
    }

    /// Recovers a return type plus a source-ordered list only when the lifter can
    /// prove at least one parameter and a complete dense source order. An empty or
    /// ABI-only result keeps its list unspecified rather than fabricating `(void)`
    /// or declaration order; its recovered return type can still complement an
    /// authored explicit list. Jump-table and selector context is intentionally
    /// omitted because it cannot change these declaration facts.
    func recoverSignature() -> FunctionSignatureOverride? {
        guard !Task.isCancelled, !instructions.isEmpty else { return nil }
        let document = PseudocodePrinter().print(
            functionName: functionName,
            startAddress: functionStartAddress,
            instructions: instructions
        )
        guard !Task.isCancelled else { return nil }

        let sourcePositions = document.parameters.compactMap(\.sourcePosition)
        let hasProvenSourceOrder = !document.parameters.isEmpty
            && sourcePositions.count == document.parameters.count
            && Set(sourcePositions).count == sourcePositions.count
            && sourcePositions.sorted() == Array(document.parameters.indices)
        let parameterList: FunctionSignatureOverride.ParameterListState
        if hasProvenSourceOrder {
            let rows = document.parameters
                .sorted { ($0.sourcePosition ?? .max) < ($1.sourcePosition ?? .max) }
                .map { parameter in
                    ArgOverride(
                        rowToken: parameter.id.rawValue,
                        name: parameter.name,
                        type: parameter.type,
                        provenance: parameter.evidence == .authoritativeDebug ? .debug : .user
                    )
                }
            parameterList = .authoritative(rows)
        } else {
            parameterList = .unspecified
        }
        return FunctionSignatureOverride(
            returnType: document.returnType,
            parameterList: parameterList
        )
    }
}

/// Runs signature recovery off the main actor while explicitly forwarding the
/// surrounding SwiftUI task's cancellation to the unstructured worker. The
/// injectable operation keeps cancellation propagation independently testable.
struct ProcedureSignatureRecoveryWorker {
    typealias Operation = @Sendable (
        ProcedureSignatureRecoveryRequest
    ) -> FunctionSignatureOverride?

    /// Execute the Swift job itself on the rendering thread so Task.isCancelled
    /// continues to observe the worker's cancellation inside synchronous recovery.
    private final class RenderingExecutor: TaskExecutor {
        static let shared = RenderingExecutor()

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            Task.detached(priority: .utility) {
                // The helper only rethrows its closure's errors; this job cannot throw.
                _ = try? await PseudocodeRenderingThread.run {
                    job.runSynchronously(on: self.asUnownedTaskExecutor())
                }
            }
        }
    }

    static func recover(
        _ request: ProcedureSignatureRecoveryRequest,
        operation: @escaping Operation = { $0.recoverSignature() }
    ) async -> FunctionSignatureOverride? {
        let worker = Task.detached(executorPreference: RenderingExecutor.shared, priority: .utility) {
            operation(request)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct ProcedureSignatureRecoveryResult: Equatable, Sendable {
    let request: ProcedureSignatureRecoveryRequest
    let signature: FunctionSignatureOverride?
}

/// Renders the members of a user type applied at the selected address: one row per
/// field with its byte offset, type, and the little-endian value decoded from the
/// loaded bytes. Hidden when no type is applied.
private struct AppliedTypeInspectorSection: View {
    @ObservedObject var store: WorkspaceStore

    private func appliedType(at address: UInt64) -> TypeDefinition? {
        guard let name = store.snapshot.overrides(in: store.focusedImageSlot)[address]?.appliedTypeName,
              !name.isEmpty else { return nil }
        return store.snapshot.typeDefinitions.first { $0.name == name }
    }

    var body: some View {
        if let address = store.selectedAddress, let type = appliedType(at: address) {
            InspectorSection(id: .type, title: "Type", systemImage: "curlybraces") {
                let baseOffset = DataInspectorReading(
                    bytes: store.focusedAnalysis?.hexBytes ?? Data(),
                    baseAddress: store.focusedAnalysis?.instructions.first?.address,
                    selectedAddress: address
                ).offset
                let members = StructMemberReading(
                    type: type,
                    bytes: store.focusedAnalysis?.hexBytes ?? Data(),
                    baseOffset: baseOffset,
                    catalog: Dictionary(store.snapshot.typeDefinitions.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
                )
                InspectorValueGroup {
                    MetadataRow(label: type.kind.displayName, value: type.name)
                }
                // U8-5a: the members as a Lumen table (offsets in hex, as the Types members table).
                DSAppliedTypeTable(rows: members.rows.enumerated().map { index, row in
                    DSAppliedTypeRow(id: index, offset: String(format: "+0x%X", row.offset), name: row.name,
                                     type: row.type, value: row.value)
                })
            }
        }
    }
}

/// Renders a manual switch-hint applied at the selected dispatching `br`: the
/// declared table base/case-count/stride/relativity plus the resolved case targets
/// (when the table bytes are readable). Hidden when no hint is set.
private struct SwitchHintInspectorSection: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if let address = store.selectedAddress,
           let hint = store.snapshot.overrides(in: store.focusedImageSlot)[address]?.switchHint,
           !hint.isEmpty {
            InspectorSection(id: .switchHint, title: "Switch Hint", systemImage: "tablecells") {
                let targets = hint.resolveTargets(
                    readBytes: store.snapshot.hexByteReader(in: store.focusedImageSlot)
                )
                InspectorValueGroup {
                    MetadataRow(label: "Table", value: hint.tableBase.hexAddress, isMonospaced: true)
                    MetadataRow(label: "Cases", value: "\(hint.entryCount)")
                    MetadataRow(label: "Entry size", value: "\(hint.entryStride) bytes")
                    MetadataRow(label: "Encoding", value: hint.isRelativeToBase ? "base-relative" : "absolute")
                    if let targets {
                        ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                            MetadataRow(label: "case \(index)", value: target.hexAddress, isMonospaced: true)
                        }
                    } else {
                        MetadataRow(label: "Targets", value: "unresolved (table bytes unavailable)")
                    }
                }
            }
        }
    }
}

private struct DataInspectorSection: View {
    @ObservedObject var store: WorkspaceStore
    @State private var byteOrder: DataByteOrder = .little
    @State private var radix: DataRadix = .decimal
    @State private var signedness: DataSignedness = .signed

    /// The bytes at the selection, read through the image's section table (`hexByteReader`) so
    /// they're the selection's own bytes wherever it is in the image. Mapping from the first
    /// instruction into `hexBytes` read header bytes on real binaries and stopped at the leading
    /// window.
    private var reading: DataInspectorReading {
        let address = store.selectedAddress
        let window = address.flatMap { address in
            DataInspectorReading.window(at: address, length: AppInspectorChrome.dataInspectorStringPreviewMaxLength,
                                        read: store.snapshot.hexByteReader(in: store.focusedImageSlot))
        }
        return DataInspectorReading(bytes: window ?? Data(), baseAddress: address, selectedAddress: address,
                                    hasLoadedBytes: !(store.focusedAnalysis?.imageBytes ?? Data()).isEmpty
                                        || !(store.focusedAnalysis?.hexBytes ?? Data()).isEmpty,
                                    isRestoringSectionMap: window == nil
                                        && store.snapshot.isAwaitingSectionRehydration(in: store.focusedImageSlot))
    }

    private func formatter(_ reading: DataInspectorReading) -> DataValueFormatter {
        DataValueFormatter(
            bytes: reading.bytes,
            offset: reading.offset,
            options: DataValueFormatOptions(byteOrder: byteOrder, radix: radix, signedness: signedness)
        )
    }

    var body: some View {
        InspectorSection(id: .data, title: "Data", systemImage: "number") {
            let reading = reading
            let formatter = formatter(reading)
            if reading.isResolvable {
                VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    formattingControls
                    InspectorValueGroup {
                        ForEach(formatter.rows, id: \.label) { row in
                            MetadataRow(label: row.label, value: row.value, isMonospaced: true)
                        }
                        // The character/string previews are format-agnostic; surface
                        // them from the original reading so the panel still shows text.
                        if let character = reading.character {
                            MetadataRow(label: "Char", value: character, isMonospaced: true)
                        }
                        if let preview = reading.stringPreview {
                            MetadataRow(label: "String", value: preview, isMonospaced: true)
                        }
                    }
                }
            } else {
                InspectorEmptyLine(reading.availabilityNote)
            }
        }
    }

    private var formattingControls: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Picker("Byte order", selection: $byteOrder) {
                ForEach(DataByteOrder.allCases) { order in
                    Text(order.shortName).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Byte order")

            Picker("Sign", selection: $signedness) {
                ForEach(DataSignedness.allCases) { sign in
                    Text(sign.displayName).tag(sign)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Signedness")

            // L5 (Lumen Tier 2e): a Lumen pop-up beside its label, as the segmented rows above.
            HStack(spacing: Lumen.Space.s4) {
                Text("Radix")
                    .lineLimit(1)
                    .lumenNeverTruncates("Radix")
                LumenPopUp(selection: $radix, options: DataRadix.allCases, title: { $0.displayName })
                    .accessibilityLabel("Radix")
            }
        }
    }
}

/// Resolves "what is at this address?" for a user-entered or currently-selected
/// address: the containing section, nearest symbol + offset, any applied
/// override/name/type, and the bidirectional xref count. The text field falls back
/// to the current selection when left empty.
private struct AddressDetailInspectorSection: View {
    @ObservedObject var store: WorkspaceStore
    @State private var query: String = ""

    /// The image slot + image-VA to inspect, plus the string to DISPLAY for the address. In
    /// `.runtime` mode a typed value is a runtime VA: it is resolved to `(slot, image-VA)` so the
    /// reading comes from the right image, and the displayed address stays the runtime VA the user
    /// sees elsewhere. `.image` mode (and single-image) is unchanged.
    private struct Target { let slot: ImageSlot; let imageAddress: UInt64; let displayAddress: String }

    private var target: Target? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = store.selectedAddress else { return nil }
            return Target(slot: store.focusedImageSlot, imageAddress: selected,
                          displayAddress: store.displayAddressString(selected))
        }
        guard let entered = parseHexAddress(trimmed) else { return nil }
        switch store.addressDisplayMode {
        case .image:
            return Target(slot: store.focusedImageSlot, imageAddress: entered,
                          displayAddress: entered.hexAddress)
        case .runtime:
            guard let resolved = store.imageLayout.resolve(runtimeVA: entered) else { return nil }
            return Target(slot: resolved.slot, imageAddress: resolved.address,
                          displayAddress: entered.hexAddress)
        }
    }

    var body: some View {
        InspectorSection(id: .addressDetail, title: "Address Detail", systemImage: "mappin.and.ellipse") {
            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                // Lumen address field: typing still inspects live; Go and
                // Return navigate there (a runtime address resolves to its image first).
                LumenAddressField(text: $query) { _ in
                    if let target {
                        store.goToAddress(target.imageAddress, in: target.slot)
                    }
                }

                if let target {
                    let reading = AddressDetailReading(
                        address: target.imageAddress,
                        snapshot: store.snapshot,
                        imageSlot: target.slot
                    )
                    InspectorValueGroup {
                        ForEach(reading.rows, id: \.label) { row in
                            // Show the display-mode address (runtime VA when the mode is on); other
                            // rows (section, symbol, refs) are unchanged.
                            MetadataRow(label: row.label,
                                        value: row.label == "Address" ? target.displayAddress : row.value,
                                        isMonospaced: row.isMonospaced)
                        }
                    }
                    if !reading.isInSection {
                        InspectorEmptyLine("Address is outside any mapped section.")
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    InspectorEmptyLine("Enter an address or select an instruction to inspect what lives there.")
                } else if store.addressDisplayMode == .runtime {
                    InspectorEmptyLine("\"\(query)\" is not a runtime address in any loaded image.")
                } else {
                    InspectorEmptyLine("Could not parse \"\(query)\" as a hex address.")
                }
            }
        }
    }
}

/// Exact owner of one segment-editor draft. The binary identity protects against a slot being
/// rebound, while the slot preserves ownership through ordinary multi-image focus changes.
struct SegmentInspectorOwner: Hashable {
    let imageSlot: ImageSlot
    let binaryID: UUID
    let originalSectionName: String
}

/// Tracks which exact image/section owns the text-field draft. Section names alone are not
/// identities because ordinary Mach-O images repeat names such as `__TEXT,__text`.
struct SegmentInspectorDraftIdentity: Equatable {
    private(set) var loadedOwner: SegmentInspectorOwner?

    mutating func markLoaded(_ owner: SegmentInspectorOwner) {
        loadedOwner = owner
    }

    func needsReload(for owner: SegmentInspectorOwner) -> Bool {
        loadedOwner != owner
    }

    func permitsApply(
        capturedOwner: SegmentInspectorOwner,
        currentOwner: SegmentInspectorOwner?
    ) -> Bool {
        loadedOwner == capturedOwner && currentOwner == capturedOwner
    }
}

/// Segment/section DISPLAY override editor: renames the section enclosing the current
/// selection and/or sets a REBASE offset (a signed byte delta shifting its displayed
/// addresses). The override is a pure display projection — analysis is untouched — and is
/// persisted + undoable. Hidden when the selection isn't inside any mapped section.
private struct SegmentInspectorSection: View {
    @ObservedObject var store: WorkspaceStore
    @State private var renameText: String = ""
    @State private var rebaseText: String = ""
    @State private var draftIdentity = SegmentInspectorDraftIdentity()

    /// The section the current selection lives in (by ORIGINAL name — the override key).
    private var targetSection: SectionSummary? {
        guard let address = store.selectedAddress else { return nil }
        return store.snapshot.section(containing: address, in: store.focusedImageSlot)
    }

    private var targetOwner: SegmentInspectorOwner? {
        guard let section = targetSection,
              let binary = store.focusedBinary else { return nil }
        return SegmentInspectorOwner(
            imageSlot: store.focusedImageSlot,
            binaryID: binary.id,
            originalSectionName: section.name
        )
    }

    var body: some View {
        if let section = targetSection,
           let owner = targetOwner {
            InspectorSection(id: .segment, title: "Segment", systemImage: "lumen.memoryMap") {
                let override = store.snapshot.segmentOverride(for: section.name, in: owner.imageSlot)
                let displayName = override?.resolvedName(default: section.name) ?? section.name
                let displayedBase = override?.rebased(section.address) ?? section.address
                VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    InspectorValueGroup {
                        MetadataRow(label: "Original", value: section.name, isMonospaced: true)
                        MetadataRow(label: "Display", value: displayName, isMonospaced: true)
                        MetadataRow(label: "Base", value: displayedBase.hexAddress, isMonospaced: true)
                        if let delta = override?.rebaseDelta, delta != 0 {
                            MetadataRow(label: "Rebase", value: Self.signedHex(delta), isMonospaced: true)
                        }
                    }

                    LumenTextField("Display name", text: $renameText) {
                        applyRename(section: section, owner: owner)
                    }
                    .help("Empty keeps the original name.")
                    .accessibilityLabel("Segment display name")

                    LumenTextField("Rebase offset", text: $rebaseText, monospaced: true) {
                        applyRebase(section: section, owner: owner)
                    }
                    .help("Examples: 0x1000 or -0x400.")
                    .accessibilityLabel("Segment rebase offset")

                    HStack(spacing: Lumen.Space.s5) {
                        Button("Apply") {
                            applyRename(section: section, owner: owner)
                            applyRebase(section: section, owner: owner)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            !rebaseFieldValid
                                || !draftIdentity.permitsApply(
                                    capturedOwner: owner,
                                    currentOwner: targetOwner
                                )
                        )

                        Button("Clear") {
                            clearOverride(section: section, owner: owner)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(override == nil || targetOwner != owner)
                    }

                    if !rebaseFieldValid {
                        InspectorEmptyLine("Rebase offset must be a (signed) hex or decimal value.")
                    }
                }
                .onAppear { reloadCurrentDraftIfNeeded() }
                .onChange(of: owner) { _, _ in reloadCurrentDraftIfNeeded() }
            }
        }
    }

    /// True when the rebase field is empty (no change) or parses to a signed delta.
    private var rebaseFieldValid: Bool {
        let trimmed = rebaseText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || Self.parseSignedDelta(trimmed) != nil
    }

    private func applyRename(section: SectionSummary, owner: SegmentInspectorOwner) {
        guard draftIdentity.permitsApply(
            capturedOwner: owner,
            currentOwner: targetOwner
        ) else { return }
        store.renameSegment(sectionName: section.name, displayName: renameText)
    }

    private func applyRebase(section: SectionSummary, owner: SegmentInspectorOwner) {
        guard draftIdentity.permitsApply(
            capturedOwner: owner,
            currentOwner: targetOwner
        ) else { return }
        let trimmed = rebaseText.trimmingCharacters(in: .whitespaces)
        // An empty field leaves the rebase untouched; a parseable value sets it.
        guard !trimmed.isEmpty, let delta = Self.parseSignedDelta(trimmed) else { return }
        store.rebaseSegment(sectionName: section.name, delta: delta)
    }

    private func clearOverride(section: SectionSummary, owner: SegmentInspectorOwner) {
        guard targetOwner == owner else { return }
        store.clearSegmentOverride(sectionName: section.name)
        loadFields(for: section, owner: owner)
    }

    private func reloadCurrentDraftIfNeeded() {
        guard let section = targetSection,
              let owner = targetOwner else { return }
        guard draftIdentity.needsReload(for: owner) else { return }
        loadFields(for: section, owner: owner)
    }

    /// Seeds the editor fields from the section's current override (so editing starts from
    /// the live state, not blank), and records which section they reflect.
    private func loadFields(for section: SectionSummary, owner: SegmentInspectorOwner) {
        guard targetOwner == owner,
              section.name == owner.originalSectionName else { return }
        let override = store.snapshot.segmentOverride(for: section.name, in: owner.imageSlot)
        renameText = override?.displayName ?? ""
        if let delta = override?.rebaseDelta, delta != 0 {
            rebaseText = Self.signedHex(delta)
        } else {
            rebaseText = ""
        }
        draftIdentity.markLoaded(owner)
    }

    /// Renders a signed delta as `±0x…` hex for display + round-trip back into the field.
    static func signedHex(_ delta: Int64) -> String {
        if delta < 0 {
            // magnitude is overflow-safe even for Int64.min.
            let magnitude = UInt64(bitPattern: ~delta &+ 1)
            return "-0x" + String(magnitude, radix: 16)
        }
        return "0x" + String(UInt64(delta), radix: 16)
    }

    /// Parses a signed `[±]0x…` (hex) or `[±]…` (decimal) delta from the rebase field.
    /// Returns nil on an unparseable input. Mirrors `WorkspaceScriptingAPI.signedDelta`
    /// (which parses the scripting form) so the GUI and scripting accept the same syntax.
    static func parseSignedDelta(_ input: String) -> Int64? {
        var body = input.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var negative = false
        if body.hasPrefix("-") { negative = true; body = String(body.dropFirst()) }
        else if body.hasPrefix("+") { body = String(body.dropFirst()) }
        let magnitude: UInt64?
        if body.lowercased().hasPrefix("0x") {
            magnitude = UInt64(body.dropFirst(2), radix: 16)
        } else {
            magnitude = UInt64(body)
        }
        guard let magnitude else { return nil }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            return Int64(bitPattern: ~magnitude &+ 1)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(magnitude)
    }
}

/// Bidirectional cross-reference panel for the selected address: references INTO
/// here (callers / data readers) and references FROM here (callees / data targets),
/// each endpoint symbolized to a function/string/selector name and tappable to
/// navigate. Surfaces the data xrefs (string/selref/global) alongside calls.
private struct XRefsInspectorSection: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        InspectorSection(id: .crossReferences, title: "Cross-References", systemImage: "lumen.crossReference") {
            let address = store.selectedAddress
            let toHere = address.map {
                store.snapshot.effectiveXRefs(to: $0, in: store.focusedImageSlot)
            } ?? []
            let fromHere = address.map {
                store.snapshot.effectiveXRefs(from: $0, in: store.focusedImageSlot)
            } ?? []
            // WS-6: edges that cross an image boundary at this address. Inbound = another image
            // references the focused image here; outbound = the focused image references another
            // image here. Navigating one switches the focused image (the Step-4 focusImage seam).
            let crossToHere = address.map { store.crossImageInbound(at: $0) } ?? []
            let crossFromHere = address.map { store.crossImageOutbound(at: $0) } ?? []

            if toHere.isEmpty && fromHere.isEmpty && crossToHere.isEmpty && crossFromHere.isEmpty {
                InspectorEmptyLine("No cross-references for the current selection.")
            } else {
                VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    if !toHere.isEmpty {
                        XRefDirectionList(
                            title: "References to here",
                            rows: toHere.map { xref in
                                XRefRowModel(
                                    id: xref.id,
                                    kind: xref.kind,
                                    endpoint: xref.from,
                                    label: symbolizedLabel(for: xref.from),
                                    navigationTarget: store.xrefNavigationTarget(
                                        for: xref,
                                        endpoint: xref.from,
                                        in: store.focusedImageSlot
                                    )
                                )
                            },
                            store: store
                        )
                    }
                    if !fromHere.isEmpty {
                        XRefDirectionList(
                            title: "References from here",
                            rows: fromHere.map { xref in
                                XRefRowModel(
                                    id: xref.id,
                                    kind: xref.kind,
                                    endpoint: xref.to,
                                    label: symbolizedLabel(for: xref.to),
                                    navigationTarget: store.xrefNavigationTarget(
                                        for: xref,
                                        endpoint: xref.to,
                                        in: store.focusedImageSlot
                                    )
                                )
                            },
                            store: store
                        )
                    }
                    if !crossToHere.isEmpty {
                        CrossImageXRefList(
                            title: "Cross-image references to here",
                            edges: crossToHere,
                            endpointFor: { (slot: $0.fromSlot, address: $0.from) },
                            store: store
                        )
                    }
                    if !crossFromHere.isEmpty {
                        CrossImageXRefList(
                            title: "Cross-image references from here",
                            edges: crossFromHere,
                            endpointFor: { (slot: $0.toSlot, address: $0.to) },
                            store: store
                        )
                    }
                }
            }
        }
    }

    /// Focus-aware equivalent of the snapshot's legacy primary-only xref label helper.
    /// Keep its match order identical so single-image labels do not change.
    private func symbolizedLabel(for address: UInt64) -> String {
        guard let analysis = store.focusedAnalysis else { return address.hexAddress }
        if let function = analysis.functions.first(where: { $0.startAddress == address }) {
            return store.snapshot.displayName(
                at: address,
                in: store.focusedImageSlot,
                default: function.name
            )
        }
        if let string = analysis.stringLiterals.first(where: { $0.address == address }) {
            let trimmed = string.value.count > 40 ? String(string.value.prefix(40)) + "…" : string.value
            return "\"\(trimmed)\""
        }
        if let selector = analysis.objcSelectors[address] {
            return "@selector(\(selector))"
        }
        if let export = analysis.exports.first(where: { $0.address == address }) {
            return export.name
        }
        if let symbol = analysis.symbols.first(where: { $0.address == address }) {
            return symbol.name
        }
        if let function = analysis.functions.first(where: {
            $0.endAddress > $0.startAddress && address > $0.startAddress && address < $0.endAddress
        }) {
            let name = store.snapshot.displayName(
                at: function.startAddress,
                in: store.focusedImageSlot,
                default: function.name
            )
            return "\(name)+0x" + String(address - function.startAddress, radix: 16)
        }
        return address.hexAddress
    }
}

private struct XRefRowModel: Identifiable {
    let id: UUID
    let kind: String
    let endpoint: UInt64
    let label: String
    let navigationTarget: XRefNavigationTarget?
}

private struct XRefDirectionList: View {
    let title: String
    let rows: [XRefRowModel]
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(rows.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                XRefNavigableRow(row: row) {
                    guard let target = row.navigationTarget else { return }
                    _ = store.navigateToReference(target)
                }
            }
        }
    }
}

/// WS-6: lists cross-image reference edges for the selected address, each labelled with the OTHER
/// image's name and tappable to jump across the image boundary (switching the focused image via the
/// Step-4 `focusImage` seam). `endpointFor` picks the far endpoint — the caller side for inbound, the
/// target side for outbound.
private struct CrossImageXRefList: View {
    let title: String
    let edges: [CrossImageXRef]
    let endpointFor: (CrossImageXRef) -> (slot: ImageSlot, address: UInt64)
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(edges.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(edges) { edge in
                let endpoint = endpointFor(edge)
                let navigationTarget = store.crossImageXRefNavigationTarget(
                    for: edge,
                    endpoint: ImageAddress(slot: endpoint.slot, address: endpoint.address)
                )
                let imageName = store.snapshot.binary(in: endpoint.slot)?.name ?? "image \(endpoint.slot.rawValue)"
                // A symbolic edge carries the joining name; an address-derived edge (WS-7) has none,
                // so fall back to the endpoint address.
                let name = edge.symbol.isEmpty ? endpoint.address.hexAddress : edge.symbol
                XRefNavigableRow(
                    row: XRefRowModel(
                        id: edge.id,
                        kind: edge.kind,
                        endpoint: endpoint.address,
                        label: "\(name) — \(imageName)",
                        navigationTarget: nil
                    )
                ) {
                    guard let navigationTarget else { return }
                    _ = store.navigateCrossImage(navigationTarget)
                }
            }
        }
    }
}

private struct XRefNavigableRow: View {
    let row: XRefRowModel
    let navigate: () -> Void

    /// Lumen reference row: the location as a link in code type, shortened in
    /// the middle, with its kind as a quiet tag.
    var body: some View {
        LumenReferenceRow("\(row.label)  \(row.endpoint.hexAddress)", kind: XRefKindPresentation.tag(row.kind), onOpen: navigate)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { navigate() }
        .accessibilityLabel("\(XRefKindPresentation.tag(row.kind)) reference, \(row.label), at \(row.endpoint.hexAddress)")
    }
}

private struct AnalysisInspectorSection: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        InspectorSection(id: .analysis, title: "Analysis", systemImage: "lumen.disassembly") {
            let analysis = store.focusedAnalysis
            let provenance = AnalysisProvenanceInspectorReading(
                fingerprint: analysis?.analysisInputFingerprint
            )
            let breakpointReading = LogicalBreakpointInspectorReading(
                catalogAvailability: store.logicalBreakpointCatalogAvailability,
                specifications: store.logicalBreakpointSpecifications,
                focusedBinary: store.focusedBinary,
                selection: store.selectedImageAddress
            )
            InspectorValueGroup {
                MetadataRow(label: "Targets", value: "\(store.snapshot.binaries.count)")
                MetadataRow(label: "Functions", value: "\(analysis?.functions.count ?? 0)")
                MetadataRow(label: "Instructions", value: "\(analysis?.instructions.count ?? 0)")
                MetadataRow(label: "Xrefs", value: "\(analysis?.xrefs.count ?? 0)")
                MetadataRow(label: "Breakpoints", value: breakpointReading.analysisSummary)
                ForEach(provenance.rows, id: \.label) { row in
                    MetadataRow(label: row.label, value: row.value, isMonospaced: row.isMonospaced)
                }
            }
            if !provenance.isAvailable {
                InspectorEmptyLine("Analysis provenance is unavailable until this image is freshly analyzed or reopened from a fingerprint-aware workspace.")
            }
        }
    }
}

struct AnalysisProvenanceInspectorReading: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
        var isMonospaced = false
    }

    let fingerprint: AnalysisInputFingerprint?

    var isAvailable: Bool {
        fingerprint != nil
    }

    var rows: [Row] {
        guard let fingerprint else { return [] }
        var rows: [Row] = [
            Row(label: "Provenance", value: shortDigest(fingerprint.overallSHA256), isMonospaced: true),
            Row(label: "Image bytes", value: shortDigest(fingerprint.imageBytesSHA256), isMonospaced: true),
            Row(label: "Fingerprint facets", value: "\(fingerprint.facets.count)"),
        ]
        rows.append(contentsOf: fingerprint.facets.map { facet in
            Row(
                label: facet.kind.inspectorDisplayName,
                value: facetValue(facet),
                isMonospaced: true
            )
        })
        return rows
    }

    private func facetValue(_ facet: AnalysisFacetFingerprint) -> String {
        var parts = [shortDigest(facet.sha256), "\(facet.itemCount) items"]
        if let byteCount = facet.byteCount {
            parts.append("\(byteCount) bytes")
        }
        return parts.joined(separator: " · ")
    }

    private func shortDigest(_ digest: String) -> String {
        guard digest.count > 16 else { return digest }
        return "\(digest.prefix(12))…\(digest.suffix(8))"
    }
}

private extension AnalysisFingerprintFacetKind {
    var inspectorDisplayName: String {
        switch self {
        case .selectedSliceBytes: "Slice bytes"
        case .loaderSections: "Sections"
        case .codeDataRanges: "Code/data"
        case .relocations: "Relocations"
        case .machOLoadMetadata: "Mach-O loads"
        case .decodedInstructions: "Instructions facet"
        case .functions: "Functions facet"
        case .controlFlow: "Control flow"
        case .xrefs: "Xrefs facet"
        case .debugSourceLines: "Debug lines"
        }
    }
}

/// Durable breakpoint facts for the exact focused image and selection. Runtime binding evidence
/// intentionally stays in the Breakpoints deck: the Inspector never infers pending, bound,
/// multi-location, or failure state from legacy instruction bits or an absent debugger session.
private struct LogicalBreakpointInspectorSection: View {
    @ObservedObject var store: WorkspaceStore

    private var reading: LogicalBreakpointInspectorReading {
        LogicalBreakpointInspectorReading(
            catalogAvailability: store.logicalBreakpointCatalogAvailability,
            specifications: store.logicalBreakpointSpecifications,
            focusedBinary: store.focusedBinary,
            selection: store.selectedImageAddress
        )
    }

    var body: some View {
        InspectorSection(id: .breakpoints, title: "Breakpoints", systemImage: "lumen.breakpoint") {
            switch reading.availability {
            case .catalogUnavailable:
                InspectorEmptyLine(
                    "The saved breakpoint catalog is unavailable. Repair it in the Breakpoints deck."
                )
            case .noFocusedImage:
                InspectorEmptyLine("Open or focus an image to inspect saved breakpoints.")
            case .available:
                InspectorValueGroup {
                    MetadataRow(
                        label: "Saved",
                        value: Self.countText(reading.focusedSpecifications.count)
                    )
                    MetadataRow(
                        label: "Enabled",
                        value: "\(reading.focusedSpecifications.lazy.filter(\.enabled).count)"
                    )

                    if let selection = reading.selection {
                        MetadataRow(
                            label: "Selection",
                            value: selection.address.hexAddress,
                            isMonospaced: true
                        )
                        MetadataRow(
                            label: "At selection",
                            value: Self.selectionCountText(reading.selectedSpecifications.count)
                        )
                        if !reading.selectedSpecifications.isEmpty {
                            MetadataRow(label: "State", value: reading.selectedStateText)
                        }
                    }
                }

                if reading.selection == nil {
                    InspectorEmptyLine(
                        "Select an address to inspect exact preferred-address specifications."
                    )
                } else if reading.selectedSpecifications.count == 1,
                          let specification = reading.selectedSpecifications.first {
                    InspectorValueGroup {
                        MetadataRow(label: "Target", value: "Preferred address")
                        MetadataRow(
                            label: "Condition",
                            value: specification.condition ?? "None",
                            isMonospaced: specification.condition != nil
                        )
                        MetadataRow(
                            label: "Hit policy",
                            value: Self.hitPolicyText(specification.hitPolicy)
                        )
                        MetadataRow(
                            label: "Actions",
                            value: Self.actionText(specification.actions)
                        )
                        MetadataRow(
                            label: "Disposition",
                            value: Self.dispositionText(specification.disposition)
                        )
                    }
                }

                InspectorEmptyLine(
                    "Runtime pending, binding, location, and failure details are shown in the Breakpoints deck."
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reading.accessibilityLabel)
        .accessibilityIdentifier("inspector.logical-breakpoints")
    }

    private static func countText(_ count: Int) -> String {
        "\(count) for focused image"
    }

    private static func selectionCountText(_ count: Int) -> String {
        switch count {
        case 0: "No exact address specification"
        case 1: "1 saved specification"
        default: "\(count) saved specifications"
        }
    }

    private static func hitPolicyText(_ policy: DebuggerBreakpointHitPolicy) -> String {
        switch policy {
        case .always:
            "Always"
        case .ignoreFirst(let count):
            "Skip first \(count) hits"
        }
    }

    private static func actionText(_ actions: [DebuggerBreakpointAction]) -> String {
        guard !actions.isEmpty else { return "None" }
        let logCount = actions.lazy.filter {
            if case .log = $0 { return true }
            return false
        }.count
        let expressionCount = actions.count - logCount
        var parts: [String] = []
        if logCount > 0 {
            parts.append("\(logCount) \(logCount == 1 ? "log" : "logs")")
        }
        if expressionCount > 0 {
            parts.append(
                "\(expressionCount) \(expressionCount == 1 ? "expression" : "expressions")"
            )
        }
        return parts.joined(separator: ", ")
    }

    private static func dispositionText(_ disposition: DebuggerBreakpointDisposition) -> String {
        switch disposition {
        case .stop:
            "Stop"
        case .continueAfterSuccessfulActions:
            "Continue after actions"
        }
    }
}

/// Pure owner/selection projection consumed by the Inspector and Analysis summary. A selection
/// matches only a durable preferred-address locator with the exact current image owner; resolving
/// function, symbol, source, or runtime locations belongs to the debugger resolver/deck.
private struct LogicalBreakpointInspectorReading {
    enum Availability {
        case catalogUnavailable
        case noFocusedImage
        case available
    }

    let availability: Availability
    let focusedSpecifications: [DebuggerLogicalBreakpointSpecification]
    let selectedSpecifications: [DebuggerLogicalBreakpointSpecification]
    let selection: ImageAddress?

    init(
        catalogAvailability: DebuggerLogicalBreakpointCatalogAvailability,
        specifications: [DebuggerLogicalBreakpointSpecification],
        focusedBinary: BinaryImage?,
        selection: ImageAddress?
    ) {
        guard catalogAvailability == .available else {
            self.availability = .catalogUnavailable
            self.focusedSpecifications = []
            self.selectedSpecifications = []
            self.selection = nil
            return
        }
        guard let focusedBinary else {
            self.availability = .noFocusedImage
            self.focusedSpecifications = []
            self.selectedSpecifications = []
            self.selection = nil
            return
        }

        let focusedSpecifications = specifications.filter {
            Self.owner(of: $0.target).matches(focusedBinary)
        }
        let acceptedSelection = selection.flatMap {
            $0.slot == focusedBinary.slot ? $0 : nil
        }
        let selectedSpecifications = acceptedSelection.map { target in
            focusedSpecifications.filter { specification in
                guard case .preferredAddress(_, let preferredVA) = specification.target else {
                    return false
                }
                return preferredVA == target.address
            }
        } ?? []

        self.availability = .available
        self.focusedSpecifications = focusedSpecifications
        self.selectedSpecifications = selectedSpecifications
        self.selection = acceptedSelection
    }

    var selectedStateText: String {
        if selectedSpecifications.allSatisfy(\.enabled) { return "Enabled" }
        if selectedSpecifications.allSatisfy({ !$0.enabled }) { return "Disabled" }
        return "Mixed enabled and disabled"
    }

    var analysisSummary: String {
        switch availability {
        case .catalogUnavailable:
            "Unavailable"
        case .noFocusedImage:
            "No focused image"
        case .available:
            "\(focusedSpecifications.count) saved"
        }
    }

    var accessibilityLabel: String {
        switch availability {
        case .catalogUnavailable:
            return "Breakpoints. Saved breakpoint catalog unavailable. Repair it in the Breakpoints deck."
        case .noFocusedImage:
            return "Breakpoints. No focused image."
        case .available:
            if let selection {
                return "Breakpoints. \(focusedSpecifications.count) saved for focused image. "
                    + "\(selectedSpecifications.count) exact address specifications at "
                    + "\(selection.address.hexAddress). Runtime details are in the Breakpoints deck."
            }
            return "Breakpoints. \(focusedSpecifications.count) saved for focused image. "
                + "No selected address. Runtime details are in the Breakpoints deck."
        }
    }

    private static func owner(
        of target: DebuggerLogicalBreakpointTarget
    ) -> DebuggerWorkspaceImageOwnerSeal {
        switch target {
        case .preferredAddress(let owner, _),
             .imageOffset(let owner, _, _, _),
             .function(let owner, _, _),
             .symbol(let owner, _, _, _, _),
             .source(let owner, _, _, _, _):
            owner
        }
    }
}

private extension DebuggerWorkspaceImageOwnerSeal {
    func matches(_ binary: BinaryImage) -> Bool {
        slot == binary.slot
            && binaryID == binary.id
            && (artifactIdentity == nil || artifactIdentity == binary.artifactIdentity)
    }
}

/// HS-13: the focused image's loader and metadata findings (chained-fixup refusals, dyld-cache
/// Objective-C diagnosis, function-start disagreements, partly unreadable Swift or Objective-C
/// metadata), grouped by kind; each row jumps to its address. The Problems sheet lists every
/// diagnostic; this section shows the first few of each kind.
struct ImageDiagnosticsInspectorSection: View {
    struct Group: Equatable, Identifiable {
        let kind: AnalysisDiagnostic.Kind
        /// The first `rowsPerKind`, by address.
        let shown: [AnalysisDiagnostic]
        let total: Int
        var id: AnalysisDiagnostic.Kind { kind }
        var hidden: Int { total - shown.count }
    }

    static let rowsPerKind = 5

    /// The loader-provenance diagnostics, grouped in `Kind` order.
    static func groups(for diagnostics: [AnalysisDiagnostic]) -> [Group] {
        let byKind = Dictionary(grouping: diagnostics.filter { $0.provenance == .loader }, by: \.kind)
        return AnalysisDiagnostic.Kind.allCases.compactMap { kind in
            guard let items = byKind[kind] else { return nil }
            let sorted = items.sorted { ($0.address, $0.message) < ($1.address, $1.message) }
            return Group(kind: kind, shown: Array(sorted.prefix(rowsPerKind)), total: sorted.count)
        }
    }

    @ObservedObject var store: WorkspaceStore
    let groups: [Group]

    var body: some View {
        if !groups.isEmpty {
            InspectorSection(id: .diagnostics, title: "Diagnostics", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: Lumen.Space.s3) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                            Text("\(group.kind.title) · \(group.total)")
                                .font(Lumen.Font.captionEmphasized)
                                .foregroundStyle(Color.lumen(.fgSecondary))
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.shown) { diagnostic in
                                LumenReferenceRow(diagnostic.addressText) { _ = store.goToAddress(diagnostic.address) }
                                    .help(diagnostic.message)
                                    .accessibilityHint(diagnostic.message)
                            }
                            if group.hidden > 0 {
                                Button("\(group.hidden) more in Problems") { store.showProblems = true }
                                    .buttonStyle(.link)
                                    .font(Lumen.Font.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct InspectorEmptyLine: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Lumen.Space.s2)
    }
}

private struct InspectorValueGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            content
        }
        .padding(.vertical, AppInspectorChrome.valueGroupVerticalPadding)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    var isMonospaced = false
    var allowsWrapping = false

    var effectiveLineLimit: Int? { allowsWrapping ? nil : valueLineLimit }
    var truncationMode: Text.TruncationMode { .middle }

    var body: some View {
        HStack(alignment: rowAlignment, spacing: Lumen.Space.s5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(allowsWrapping ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: allowsWrapping)
                .frame(width: AppInspectorChrome.metadataLabelWidth, alignment: .leading)

            Text(value)
                .font(isMonospaced ? AppTypography.bytes : AppTypography.metadata)
                .foregroundStyle(.primary)
                .lineLimit(effectiveLineLimit)
                .truncationMode(truncationMode)
                .minimumScaleFactor(allowsWrapping ? 1 : AppInspectorChrome.metadataValueMinimumScaleFactor)
                .fixedSize(horizontal: false, vertical: allowsExpandedValue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: AppInspectorChrome.metadataRowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppInspectorChrome.metadataAccessibilityLabel(label: label, value: value))
    }

    private var valueLineLimit: Int {
        AppInspectorChrome.metadataValueLineLimit(for: value)
    }

    private var allowsExpandedValue: Bool {
        allowsWrapping || valueLineLimit > AppInspectorChrome.metadataDefaultValueLineLimit
    }

    private var rowAlignment: VerticalAlignment {
        allowsExpandedValue ? .top : .firstTextBaseline
    }
}

/// Pure, GUI-free decode of the bytes at the selected address into primitive C
/// types. The byte offset uses the same arithmetic proven in
/// `HexNavigationState` (delta = selectedAddress - baseAddress, guarded against
/// `Int` overflow). All multi-byte values are assembled little-endian via
/// explicit byte shifts so endianness and sign handling are testable and never
/// rely on unaligned pointer loads.
struct DataInspectorReading: Equatable {
    let bytes: Data
    let offset: Int?
    /// Whether the image has bytes at all, so an empty window reads as "outside" rather than
    /// "nothing loaded". nil: decide from `bytes`.
    private let hasLoadedBytes: Bool?

    /// Up to `length` bytes at `address` from `read`, fewer near the end of a mapped range
    /// (at least the 8 the widest value needs, else what remains). nil when nothing is mapped there.
    static func window(at address: UInt64, length: Int,
                       read: (_ virtualAddress: UInt64, _ count: Int) -> Data?) -> Data? {
        for count in [max(length, 8), 8, 4, 2, 1] {
            if let bytes = read(address, count), bytes.count == count { return bytes }
        }
        return nil
    }

    /// True while a reopened image's section map is still being rebuilt (lane AJ).
    private let isRestoringSectionMap: Bool

    init(bytes: Data, baseAddress: UInt64?, selectedAddress: UInt64?, hasLoadedBytes: Bool? = nil,
         isRestoringSectionMap: Bool = false) {
        self.bytes = bytes
        self.hasLoadedBytes = hasLoadedBytes
        self.isRestoringSectionMap = isRestoringSectionMap
        self.offset = Self.byteOffset(
            byteCount: bytes.count,
            baseAddress: baseAddress,
            selectedAddress: selectedAddress
        )
    }

    private static func byteOffset(
        byteCount: Int,
        baseAddress: UInt64?,
        selectedAddress: UInt64?
    ) -> Int? {
        guard byteCount > 0,
              let baseAddress,
              let selectedAddress,
              selectedAddress >= baseAddress
        else { return nil }

        let delta = selectedAddress - baseAddress
        guard delta <= UInt64(Int.max) else { return nil }
        let offset = Int(delta)
        guard offset >= 0, offset < byteCount else { return nil }
        return offset
    }

    /// True when the selection resolves to a byte inside the loaded bytes.
    var isResolvable: Bool {
        offset != nil
    }

    /// Empty-state message shown when the selection cannot be decoded.
    var availabilityNote: String {
        if isRestoringSectionMap { return "Restoring the image’s section map…" }
        return !(hasLoadedBytes ?? !bytes.isEmpty)
            ? "No bytes are loaded for the current target."
            : "Selection is outside the loaded bytes."
    }

    // MARK: - Little-endian assembly

    /// Reads `count` bytes starting at the resolved offset, assembling them into
    /// an unsigned 64-bit value little-endian. Returns nil when fewer than
    /// `count` trailing bytes are available.
    private func littleEndianValue(byteCount count: Int) -> UInt64? {
        guard let offset, offset + count <= bytes.count else { return nil }
        let start = bytes.startIndex + offset
        var value: UInt64 = 0
        for index in 0..<count {
            let byte = bytes[start + index]
            value |= UInt64(byte) << (8 * index)
        }
        return value
    }

    private func unsignedByte() -> UInt8? {
        guard let offset else { return nil }
        return bytes[bytes.startIndex + offset]
    }

    // MARK: - Typed accessors

    var uint8: String? {
        unsignedByte().map { String($0) }
    }

    var int8: String? {
        unsignedByte().map { String(Int8(bitPattern: $0)) }
    }

    var uint16: String? {
        littleEndianValue(byteCount: 2).map { String(UInt16(truncatingIfNeeded: $0)) }
    }

    var int16: String? {
        littleEndianValue(byteCount: 2).map { String(Int16(bitPattern: UInt16(truncatingIfNeeded: $0))) }
    }

    var uint32: String? {
        littleEndianValue(byteCount: 4).map { String(UInt32(truncatingIfNeeded: $0)) }
    }

    var int32: String? {
        littleEndianValue(byteCount: 4).map { String(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) }
    }

    var uint64: String? {
        littleEndianValue(byteCount: 8).map { String($0) }
    }

    var int64: String? {
        littleEndianValue(byteCount: 8).map { String(Int64(bitPattern: $0)) }
    }

    var float32: String? {
        littleEndianValue(byteCount: 4).map { String(Float(bitPattern: UInt32(truncatingIfNeeded: $0))) }
    }

    var double64: String? {
        littleEndianValue(byteCount: 8).map { String(Double(bitPattern: $0)) }
    }

    /// The single selected byte rendered as a printable ASCII character, or a
    /// dotted placeholder when it is outside the printable range.
    var character: String? {
        guard let byte = unsignedByte() else { return nil }
        if byte >= 0x20, byte < 0x7F {
            return String(Character(UnicodeScalar(byte)))
        }
        return "."
    }

    /// A short preview of the printable ASCII run starting at the offset,
    /// clamped to `dataInspectorStringPreviewMaxLength` bytes. Returns nil when
    /// the first byte is not printable.
    var stringPreview: String? {
        guard let offset else { return nil }
        let start = bytes.startIndex + offset
        let limit = min(bytes.count - offset, AppInspectorChrome.dataInspectorStringPreviewMaxLength)
        var characters: [Character] = []
        for index in 0..<limit {
            let byte = bytes[start + index]
            guard byte >= 0x20, byte < 0x7F else { break }
            characters.append(Character(UnicodeScalar(byte)))
        }
        return characters.isEmpty ? nil : String(characters)
    }

    /// Ordered label/value rows for the decoded primitives, omitting any type
    /// that lacks enough trailing bytes.
    var rows: [(label: String, value: String)] {
        guard isResolvable else { return [] }
        var rows: [(label: String, value: String)] = []
        func append(_ label: String, _ value: String?) {
            if let value {
                rows.append((label: label, value: value))
            }
        }
        append("Int8", int8)
        append("UInt8", uint8)
        append("Int16", int16)
        append("UInt16", uint16)
        append("Int32", int32)
        append("UInt32", uint32)
        append("Int64", int64)
        append("UInt64", uint64)
        append("Float", float32)
        append("Double", double64)
        append("Char", character)
        append("String", stringPreview)
        return rows
    }
}

/// Pure, GUI-free resolution of the procedure (function) that encloses the
/// selected address, plus the per-function facts MacScope already computes.
///
/// Containment mirrors the rule proven in `WorkspaceStore.function(containing:)`
/// and `EditorSurfaceView.contextFunction`: a function with `endAddress >
/// startAddress` owns the half-open range `[start, end)`, otherwise it owns only
/// its single `startAddress`. The lowest-start matching function is chosen
/// deterministically (sorted by `startAddress` then `name`) — the rule is
/// duplicated here intentionally so the GUI track never reaches into the store's
/// private helper.
///
/// Caller/callee counts are derived only from `kind == "call"` edges. Because the
/// section feeds both `controlFlowEdges` and `xrefs`, the same call may appear
/// twice; counts are taken over a set deduped by `(from, to)` so a single logical
/// call is never inflated.
struct ProcedureInspectorReading: Equatable {
    let function: FunctionSummary?
    let nameText: String?
    /// The user-authored signature rendered as a prototype, when one is set.
    let signatureText: String?
    let blockCount: Int
    let instructionCount: Int
    let confidenceText: String?
    let entryText: String?
    let endText: String?
    let callerCount: Int
    let calleeCount: Int

    /// The focused image's reading at the store's selection; the summary card and the Function
    /// section share it, so their counts agree.
    @MainActor
    init(store: WorkspaceStore, recoveredSignatures: [UInt64: FunctionSignatureOverride] = [:]) {
        let analysis = store.focusedAnalysis
        let callEdges =
            (analysis?.controlFlowEdges ?? []).map { (from: $0.from, to: $0.to, kind: $0.kind) }
            + (analysis?.xrefs ?? []).map { (from: $0.from, to: $0.to, kind: $0.kind) }
        self.init(
            functions: analysis?.functions ?? [],
            basicBlocks: analysis?.basicBlocks ?? [],
            callEdges: callEdges,
            instructions: analysis?.instructions ?? [],
            selectedAddress: store.selectedAddress,
            addressOverrides: store.snapshot.overrides(in: store.focusedImageSlot),
            recoveredSignatures: recoveredSignatures
        )
    }

    init(
        functions: [FunctionSummary],
        basicBlocks: [BasicBlockSummary],
        callEdges: [(from: UInt64, to: UInt64, kind: String)],
        instructions: [InstructionRow],
        selectedAddress: UInt64?,
        addressOverrides: [UInt64: AddressOverride] = [:],
        recoveredSignatures: [UInt64: FunctionSignatureOverride] = [:]
    ) {
        let resolved = Self.enclosingFunction(in: functions, selectedAddress: selectedAddress)
        self.function = resolved
        // Blend the user's custom name (override at the entry address) over the
        // parsed name, matching WorkspaceSnapshot.displayName precedence.
        self.nameText = resolved.map { addressOverrides[$0.startAddress]?.customName ?? $0.name }
        // Render the effective signature only when its parameter-list disposition
        // is known. An unspecified override may borrow recovered rows when the
        // caller has them; without that context it must not collapse to `(void)`.
        self.signatureText = resolved.flatMap { fn -> String? in
            let signature = addressOverrides[fn.startAddress]?.signature
            let recovered = recoveredSignatures[fn.startAddress]
            let name = addressOverrides[fn.startAddress]?.customName ?? fn.name
            return ProcedurePrototypeFormatter.text(
                name: name,
                override: signature,
                recovered: recovered
            )
        }

        guard let resolved else {
            self.blockCount = 0
            self.instructionCount = 0
            self.confidenceText = nil
            self.entryText = nil
            self.endText = nil
            self.callerCount = 0
            self.calleeCount = 0
            return
        }

        self.blockCount = basicBlocks.filter { $0.functionID == resolved.id }.count
        self.instructionCount = instructions.filter {
            Self.range(of: resolved, contains: $0.address)
        }.count
        self.confidenceText = AppInspectorChrome.confidencePercentText(for: resolved.confidence)
        self.entryText = resolved.startAddress.hexAddress
        self.endText = resolved.endAddress > resolved.startAddress
            ? resolved.endAddress.hexAddress
            : nil

        let callPairs = Set(
            callEdges
                .filter { $0.kind == "call" }
                .map { CallPair(from: $0.from, to: $0.to) }
        )
        self.calleeCount = callPairs.filter {
            Self.range(of: resolved, contains: $0.from)
        }.count
        self.callerCount = callPairs.filter {
            Self.range(of: resolved, contains: $0.to)
        }.count
    }

    /// True when the selection resolves to a discovered function.
    var isResolved: Bool {
        function != nil
    }

    /// Empty-state message shown when no enclosing function can be resolved.
    var availabilityNote: String {
        "Select an instruction inside a discovered function to inspect function bounds, blocks, and call relationships."
    }

    /// Ordered label/value rows for the resolved procedure, omitting the end and
    /// confidence rows when they carry no signal. Callers and blocks are on the summary card.
    var rows: [(label: String, value: String, isMonospaced: Bool)] {
        guard let function else { return [] }
        var rows: [(label: String, value: String, isMonospaced: Bool)] = []
        rows.append((label: "Name", value: nameText ?? function.name, isMonospaced: false))
        if let signatureText {
            rows.append((label: "Signature", value: signatureText, isMonospaced: true))
        }
        if let entryText {
            rows.append((label: "Entry", value: entryText, isMonospaced: true))
        }
        if let endText {
            rows.append((label: "End", value: endText, isMonospaced: true))
        }
        rows.append((label: "Instructions", value: "\(instructionCount)", isMonospaced: false))
        if let confidenceText {
            rows.append((label: "Confidence", value: confidenceText, isMonospaced: false))
        }
        rows.append((label: "Callees", value: "\(calleeCount)", isMonospaced: false))
        return rows
    }

    private struct CallPair: Hashable {
        let from: UInt64
        let to: UInt64
    }

    fileprivate static func enclosingFunction(
        in functions: [FunctionSummary],
        selectedAddress: UInt64?
    ) -> FunctionSummary? {
        guard let selectedAddress else { return nil }
        return functions
            .sorted { lhs, rhs in
                if lhs.startAddress == rhs.startAddress {
                    return lhs.name < rhs.name
                }
                return lhs.startAddress < rhs.startAddress
            }
            .first { range(of: $0, contains: selectedAddress) }
    }

    private static func range(of function: FunctionSummary, contains address: UInt64) -> Bool {
        if function.endAddress > function.startAddress {
            return address >= function.startAddress && address < function.endAddress
        }
        return address == function.startAddress
    }
}

/// Pure prototype rendering for the inspector. Parameter-list presence is the
/// authority: authoritative array order is source order, while an unspecified
/// list inherits recovered rows only when the caller supplies them. Quarantined
/// legacy rows are intentionally ignored because they have no analysis effect.
struct ProcedurePrototypeFormatter {
    static func text(
        name: String,
        override: FunctionSignatureOverride?,
        recovered: FunctionSignatureOverride?
    ) -> String? {
        let parameterState = effectiveParameterState(override: override, recovered: recovered)
        guard case let .authoritative(rows) = parameterState else { return nil }

        var parameters = rows.map { "\($0.type) \($0.name)" }
        if effectiveVariadicState(override: override, recovered: recovered) == .variadic {
            parameters.append("...")
        }

        let parameterText = parameters.isEmpty ? "void" : parameters.joined(separator: ", ")
        let returnType = nonEmpty(override?.returnType)
            ?? nonEmpty(recovered?.returnType)
            ?? "int64_t"
        let qualifier = effectiveNoReturn(override: override, recovered: recovered)
            ? "noreturn "
            : ""
        return "\(qualifier)\(returnType) \(name)(\(parameterText))"
    }

    private static func effectiveParameterState(
        override: FunctionSignatureOverride?,
        recovered: FunctionSignatureOverride?
    ) -> FunctionSignatureOverride.ParameterListState {
        if let override {
            switch override.parameterList {
            case .authoritative:
                return override.parameterList
            case .unspecified:
                break
            }
        }
        return recovered?.parameterList ?? .unspecified
    }

    private static func effectiveVariadicState(
        override: FunctionSignatureOverride?,
        recovered: FunctionSignatureOverride?
    ) -> FunctionSignatureOverride.VariadicState {
        if let override, override.variadicState != .unspecified {
            return override.variadicState
        }
        return recovered?.variadicState ?? .unspecified
    }

    private static func effectiveNoReturn(
        override: FunctionSignatureOverride?,
        recovered: FunctionSignatureOverride?
    ) -> Bool {
        switch override?.noReturnState {
        case .noReturn:
            return true
        case .returns:
            return false
        case .unspecified, nil:
            return recovered?.noReturnState == .noReturn
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

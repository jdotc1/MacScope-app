import SwiftUI
import LumenUI

struct NativePseudocodeActionIdentity: Equatable, Sendable {
    let workspaceID: UUID
    let publication: NativeDecompilerPresentationPublicationIdentity
}

/// A current, verified display projection. Action payloads are checked against its token records;
/// neither an address printed in text nor a storage offset becomes navigation authority.
struct NativePseudocodeActionScope {
    let identity: NativePseudocodeActionIdentity
    let document: NativeDecompilerDocumentProjection
    let result: NativeDecompilerWireStructuredResult

    init?(
        workspaceID: UUID,
        publication: NativeDecompilerPresentationPublicationIdentity?,
        state: NativeDecompilerPresentationState,
        expected: DecompilerPresentationIdentity?
    ) {
        guard let publication,
              case let .ready(coordinate, success) = state,
              publication.coordinate == coordinate,
              publication.requestID == success.result.requestID,
              success.availability.available,
              expected?.matches(coordinate) == true else { return nil }
        let presentation = NativePseudocodePresentation.project(
            state: state, expected: expected, macScopeIsAvailable: false
        )
        guard presentation.status == .ready,
              let document = presentation.document,
              document.mappingState == .verified else { return nil }
        identity = .init(workspaceID: workspaceID, publication: publication)
        self.document = document
        result = success.result
    }

    @MainActor
    static func isVisible(
        selectedTool: WorkspaceTool,
        editorMode: EditorMode,
        source: PseudocodeSource,
        isImporting: Bool
    ) -> Bool {
        !isImporting
            && WorkspaceRootView.centralDestination(for: selectedTool) == .editor
            && editorMode == .pseudocode
            && source == .native
    }

    @MainActor
    static func current(
        store: WorkspaceStore,
        presentation: NativeDecompilerPresentationModel,
        sourceSelection: PseudocodeSourceSelectionModel
    ) -> Self? {
        guard isVisible(
                  selectedTool: store.selectedTool,
                  editorMode: store.editorMode,
                  source: sourceSelection.source,
                  isImporting: store.isImporting
              ),
              let binary = store.focusedBinary,
              let artifactUUID = binary.artifactIdentity?.uuid,
              let analysis = store.focusedAnalysis,
              let fingerprint = analysis.analysisInputFingerprint?.overallSHA256,
              let function = EditorContextResolution.function(
                  in: analysis.functions, selectedAddress: store.selectedAddress
              ) else { return nil }
        return Self(
            workspaceID: store.workspaceID,
            publication: presentation.readyPublicationIdentity,
            state: presentation.state,
            expected: .init(
                imageSlot: store.focusedImageSlot,
                ownerBinaryID: binary.id,
                artifactUUID: artifactUUID,
                functionID: function.id.uuidString.lowercased(),
                analysisInputFingerprintSHA256: fingerprint
            )
        )
    }

    func sourceRanges(
        for request: NativePseudocodeSourceRequest,
        captured: NativePseudocodeActionIdentity
    ) -> [NativeDecompilerWireSourceRange]? {
        guard captured == identity,
              let run = unique(document.tokenRuns, id: request.tokenID, key: \.tokenID),
              NativePseudocodeInteractionProjection.sourceAction(for: run) == request.action
        else { return nil }
        let ranges: [NativeDecompilerWireSourceRange]
        switch request.action {
        case let .navigate(range): ranges = [range]
        case let .choose(chooser): ranges = (0..<chooser.count).compactMap { chooser.range(at: $0) }
        }
        guard !ranges.isEmpty, ranges.allSatisfy({ range in
            range.imageID == identity.publication.coordinate.imageID
                && range.startAddress.value < range.endAddressExclusive.value
                && range.startAddress.value >= result.function.entryAddress.value
                && range.endAddressExclusive.value <= result.function.endAddressExclusive.value
        }) else { return nil }
        return ranges
    }

    func target(
        for range: NativeDecompilerWireSourceRange,
        request: NativePseudocodeSourceRequest,
        captured: NativePseudocodeActionIdentity
    ) -> ImageAddress? {
        guard sourceRanges(for: request, captured: captured)?.contains(range) == true else { return nil }
        return ImageAddress(slot: identity.publication.coordinate.imageSlot, address: range.startAddress.value)
    }

    func inspection(
        for detail: NativePseudocodeEntityDetail,
        captured: NativePseudocodeActionIdentity
    ) -> NativePseudocodeEntityInspection? {
        guard captured == identity,
              let run = unique(document.tokenRuns, id: detail.tokenID, key: \.tokenID),
              NativePseudocodeInteractionProjection.entityDetails(for: run).contains(detail)
        else { return nil }
        var fields = [NativePseudocodeEntityInspection.Field(label: "Entity ID", value: detail.entityID)]
        func add(_ label: String, _ value: String?) {
            guard let value else { return }
            fields.append(.init(label: label, value: value))
        }
        func ids(_ values: [String]) -> String {
            let visible = values.prefix(8).joined(separator: ", ")
            return values.count > 8 ? visible + " … (\(values.count) total)" : visible
        }
        switch detail.kind {
        case .instruction:
            guard let value = unique(result.instructions, id: detail.entityID, key: \.id) else { return nil }
            add("Address", Self.hex(value.address.value))
            add("Mnemonic", value.mnemonic)
            add("Operands", value.body)
            add("Bytes", value.bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
            add("Operations", ids(value.operationIDs))
        case .operation:
            guard let value = unique(result.operations, id: detail.entityID, key: \.id) else { return nil }
            add("Opcode", value.opcode.rawValue)
            add("Block", value.blockID)
            add("Sequence", String(value.sequence.value))
            add("Inputs", ids(value.inputVarnodeIDs))
            add("Output", value.outputVarnodeID)
            add("Direct target", value.directTargetAddress.map { Self.hex($0.value) })
        case .block:
            guard let value = unique(result.blocks, id: detail.entityID, key: \.id) else { return nil }
            add("Start", Self.hex(value.startAddress.value))
            add("End (exclusive)", Self.hex(value.endAddressExclusive.value))
            add("Terminator", value.terminatorKind.rawValue)
            add("Operations", ids(value.operationIDs))
            add("Predecessor edges", ids(value.predecessorEdgeIDs))
            add("Successor edges", ids(value.successorEdgeIDs))
        case .call:
            guard let value = unique(result.calls, id: detail.entityID, key: \.id) else { return nil }
            add("Kind", value.kind.rawValue)
            add("Operation", value.operationID)
            add("Target symbol", value.targetSymbol)
            add("Target address", value.targetAddress.map { Self.hex($0.value) })
            add("Prototype type", value.prototypeTypeID)
            add("Arguments", ids(value.argumentVariableIDs))
            add("Result", value.resultVariableID)
        case .region:
            guard let value = unique(result.regions, id: detail.entityID, key: \.id) else { return nil }
            add("Kind", value.kind.rawValue)
            add("Parent", value.parentRegionID)
            add("Children", ids(value.childRegionIDs))
            add("Blocks", ids(value.blockIDs))
            add("Condition operation", value.conditionOperationID)
        case .type:
            guard let value = unique(result.types, id: detail.entityID, key: \.id) else { return nil }
            add("Name", value.name)
            add("Kind", value.kind.rawValue)
            add("Size (bytes)", value.byteSize.map { String($0.value) })
            add("Signed", value.isSigned.map { $0 ? "Yes" : "No" })
            add("Pointee type", value.pointeeTypeID)
            add("Return type", value.returnTypeID)
            add("Parameter types", ids(value.parameterTypeIDs))
            add("Field count", String(value.fields.count))
            for field in value.fields.prefix(8) {
                add("Field \(field.name)", "\(field.typeID), bit offset \(field.bitOffset.value), size \(field.bitSize.value)")
            }
            add("Confidence", value.confidence.rawValue)
            add("Provenance", value.provenance)
        case .variable:
            guard let value = unique(result.variables, id: detail.entityID, key: \.id) else { return nil }
            add("Name", value.name)
            add("Role", value.role.rawValue)
            add("Type", value.typeID)
            add("Storage varnodes", ids(value.storageVarnodeIDs))
            add("Live range count", String(value.liveRanges.count))
            add("Confidence", value.confidence.rawValue)
            add("Provenance", value.provenance)
        case .varnode:
            guard let value = unique(result.varnodes, id: detail.entityID, key: \.id) else { return nil }
            add("Role", value.role.rawValue)
            add("Address space", value.addressSpaceID)
            add("Storage offset", Self.hex(value.offset.value))
            add("Size (bytes)", String(value.sizeBytes))
            add("Register", value.registerName)
            add("Type", value.typeID)
        }
        return .init(title: "Native \(detail.kind.rawValue)", fields: fields)
    }

    static func hex(_ address: UInt64) -> String { "0x" + String(address, radix: 16) }

    private func unique<T>(_ values: [T], id: String, key: KeyPath<T, String>) -> T? {
        var found: T?
        for value in values where value[keyPath: key] == id {
            if case .some = found { return nil }
            found = value
        }
        return found
    }
}

struct NativePseudocodeEntityInspection: Equatable {
    struct Field: Equatable {
        let label: String
        let value: String

        init(label: String, value: String) {
            self.label = Self.bounded(label, limit: 128)
            self.value = Self.bounded(value, limit: 512)
        }

        private static func bounded(_ text: String, limit: Int) -> String {
            let prefix = text.unicodeScalars.prefix(limit)
            let visible = String(String.UnicodeScalarView(prefix))
            return prefix.count < text.unicodeScalars.count ? visible + "…" : visible
        }
    }
    let title: String
    let fields: [Field]
}

struct NativePseudocodeActionSheet: Identifiable {
    enum Content {
        case sources(NativePseudocodeSourceRequest, [NativeDecompilerWireSourceRange])
        case entity(NativePseudocodeEntityInspection)
        case values(NativeValueNavigationSession)
    }
    let id = UUID()
    let identity: NativePseudocodeActionIdentity
    let content: Content
}

@MainActor
final class NativePseudocodeActionRouter: ObservableObject {
    @Published private(set) var sheet: NativePseudocodeActionSheet?
    private let currentScope: @MainActor () -> NativePseudocodeActionScope?
    private let navigate: @MainActor (ImageAddress) -> Bool

    init(
        currentScope: @escaping @MainActor () -> NativePseudocodeActionScope?,
        navigate: @escaping @MainActor (ImageAddress) -> Bool
    ) {
        self.currentScope = currentScope
        self.navigate = navigate
    }

    convenience init(
        store: WorkspaceStore,
        presentation: NativeDecompilerPresentationModel,
        sourceSelection: PseudocodeSourceSelectionModel
    ) {
        self.init(currentScope: {
            NativePseudocodeActionScope.current(
                store: store, presentation: presentation, sourceSelection: sourceSelection
            )
        }, navigate: { target in
            guard store.selectAddress(target) else { return false }
            store.editorMode = .disassembly
            return true
        })
    }

    func source(_ request: NativePseudocodeSourceRequest, captured: NativePseudocodeActionIdentity) {
        guard let scope = currentScope(),
              let ranges = scope.sourceRanges(for: request, captured: captured) else { return }
        if ranges.count == 1 {
            guard let target = scope.target(for: ranges[0], request: request, captured: captured),
                  navigate(target) else { return }
            dismiss()
        } else {
            dismiss()
            sheet = .init(identity: captured, content: .sources(request, ranges))
        }
    }

    func choose(_ range: NativeDecompilerWireSourceRange, sheetID: UUID) {
        guard let sheet, sheet.id == sheetID,
              case let .sources(request, ranges) = sheet.content,
              ranges.contains(range) else { return }
        guard let scope = currentScope(),
              let target = scope.target(for: range, request: request, captured: sheet.identity) else {
            dismiss()
            return
        }
        if navigate(target) { dismiss() }
    }

    func entity(_ detail: NativePseudocodeEntityDetail, captured: NativePseudocodeActionIdentity) {
        guard let scope = currentScope(),
              let inspection = scope.inspection(for: detail, captured: captured) else { return }
        dismiss()
        sheet = .init(identity: captured, content: .entity(inspection))
    }

    func value(_ request: NativePseudocodeValueRequest, captured: NativePseudocodeActionIdentity) {
        guard let scope = currentScope(),
              let capture = NativeValueNavigationCapture.capture(
                request: request, scope: scope, captured: captured
              ) else { return }
        dismiss()
        let session = NativeValueNavigationSession(
            capture: capture, direction: request.direction,
            currentScope: currentScope, navigate: navigate,
            onNavigated: { [weak self] in self?.dismiss() }
        )
        sheet = .init(identity: captured, content: .values(session))
        session.start()
    }

    func reconcile() {
        guard let sheet else { return }
        guard currentScope()?.identity == sheet.identity else { dismiss(); return }
        if case let .values(session) = sheet.content { session.reconcile() }
    }

    func dismiss() {
        if let sheet, case let .values(session) = sheet.content { session.invalidate() }
        sheet = nil
    }
}

struct NativePseudocodeActionSheetView: View {
    let sheet: NativePseudocodeActionSheet
    let onChoose: (NativeDecompilerWireSourceRange, UUID) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            switch sheet.content {
            case let .sources(_, ranges):
                Text("Choose Source Range").font(.headline).lumenNeverTruncates("Choose Source Range")
                Text("Select a range to reveal in disassembly.")
                    .foregroundStyle(.secondary)
                List(ranges.indices, id: \.self) { index in
                    let range = ranges[index]
                    Button {
                        onChoose(range, sheet.id)
                    } label: {
                        Text("\(NativePseudocodeActionScope.hex(range.startAddress.value))–\(NativePseudocodeActionScope.hex(range.endAddressExclusive.value))")
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("native.sourceRange.\(index)")
                }
                .accessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.tokenSourceChooser)
            case let .values(session):
                NativeValueNavigationSheetView(session: session)
            case let .entity(inspection):
                Text(inspection.title).font(.headline).lumenNeverTruncates(inspection.title)
                Text("Recovered structured evidence · Read only")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                        ForEach(inspection.fields.indices, id: \.self) { index in
                            let field = inspection.fields[index]
                            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                                Text(field.label).font(.caption).foregroundStyle(.secondary)
                                Text(field.value).font(.body.monospaced()).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .accessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.tokenEntityDetail)
            }
            HStack {
                Spacer()
                Button("Close", action: onDismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 440, idealWidth: 560, minHeight: 300, idealHeight: 440)
    }
}

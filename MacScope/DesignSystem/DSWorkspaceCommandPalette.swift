import AppKit
import SwiftUI
import LumenUI

/// Lumen presentation and persistence stay behind MacScope's design-system seam.
enum DSCommandPaletteAdapter {
    static let recentsKey = "MacScope.lumen.commandPalette.recents"
    static let addressHelp = "Enter arbitrary addresses or choose an image in Go to Address."

    @MainActor
    static func commands(bindings: KeyBindingSet, store: WorkspaceStore) -> [LumenCommand] {
        // Index once: mapping every function row through a linear lookup would be quadratic.
        let functionsByID = Dictionary(
            (store.focusedAnalysis?.functions ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return store.commandPaletteEntries.map {
            command(for: $0, bindings: bindings, store: store, functionsByID: functionsByID)
        }
    }

    @MainActor
    static func command(
        for entry: CommandPaletteEntry,
        bindings: KeyBindingSet,
        store: WorkspaceStore,
        functionsByID: [FunctionSummary.ID: FunctionSummary]? = nil
    ) -> LumenCommand {
        let invocation = DSCommandPaletteInvocation(entry: entry, store: store, functionsByID: functionsByID)
        var subtitle = entry.subtitle
        if case .showGoToAddress = entry.action {
            subtitle += " — " + addressHelp
        }
        if let reason = entry.availability.unavailableReason {
            subtitle += " — Unavailable: " + reason
        }
        return LumenCommand(
            id: entry.id,
            entry.title,
            subtitle: subtitle,
            category: entry.kind.rawValue,
            systemImage: entry.systemImage,
            shortcut: shortcut(for: entry.action, bindings: bindings),
            keywords: entry.keywords + [entry.subtitle] + (entry.detail.map { [$0] } ?? [])
                + (entry.availability.unavailableReason.map { [$0] } ?? []),
            isEnabled: entry.availability.isAvailable
        ) { [weak store] in
            guard let store else { return }
            invocation.perform(in: store)
        }
    }

    static func shortcut(for action: CommandPaletteAction, bindings: KeyBindingSet) -> KeyboardShortcut? {
        switch action {
        case .showGoToAddress:
            bindings.chord(for: .goToAddress).keyboardShortcut
        case .toggleInspector:
            bindings.chord(for: .toggleInspector).keyboardShortcut
        case .toggleBreakpoint:
            bindings.chord(for: .toggleBreakpoint).keyboardShortcut
        case .selectEditorMode(let mode):
            KeyboardShortcut(mode.keyboardShortcut, modifiers: .command)
        default:
            nil
        }
    }
}

private struct DSWorkspaceCommandPaletteHost: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    @AppStorage(KeyBindingSet.storageKey) private var overrides: Data?
    @State private var windowContext = DSCommandPaletteWindowContext()

    func body(content: Content) -> some View {
        let bindings = KeyBindingSet.resolvingOverrides(overrides)
        content
            .background(DSCommandPaletteWindowReader(windowContext: windowContext))
            .overlay(alignment: .top) {
                if store.isCommandPalettePresented {
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(.black.opacity(0.08))
                            .contentShape(.rect)
                            .onTapGesture { windowContext.dismissPalette(in: store) }
                        LumenCommandPalette(
                            DSCommandPaletteAdapter.commands(bindings: bindings, store: store),
                            recentsKey: DSCommandPaletteAdapter.recentsKey
                        ) {
                            // Lumen calls this synchronously before performing the command.
                            // Finish window-local cleanup before its destination sheet opens.
                            windowContext.dismissPalette(in: store)
                        }
                        .padding(.top, 64)
                    }
                }
            }
            .background {
                if store.isCommandPalettePresented {
                    Button("Close Open Quickly") { windowContext.dismissPalette(in: store) }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The originating window is the entire focus-cleanup authority. Never look up a
/// different key window later, and never clear focus after a destination sheet opens.
@MainActor
final class DSCommandPaletteWindowContext {
    weak var window: NSWindow?

    func dismissPalette(in store: WorkspaceStore) {
        guard store.isCommandPalettePresented else { return }
        if let window, window.isKeyWindow, window.attachedSheet == nil {
            window.makeFirstResponder(nil)
        }
        store.isCommandPalettePresented = false
    }
}

private struct DSCommandPaletteWindowReader: NSViewRepresentable {
    let windowContext: DSCommandPaletteWindowContext

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(windowContext: windowContext)
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: ()) {
        if nsView.windowContext.window === nsView.window {
            nsView.windowContext.window = nil
        }
    }

    final class WindowReaderView: NSView {
        let windowContext: DSCommandPaletteWindowContext

        init(windowContext: DSCommandPaletteWindowContext) {
            self.windowContext = windowContext
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowContext.window = window
        }
    }
}

extension View {
    /// MacScope owns presentation and dismissal; Lumen owns the palette component.
    /// Open Quickly remains the rebindable Navigate command with no added shortcut.
    func dsWorkspaceCommandPalette(store: WorkspaceStore) -> some View {
        modifier(DSWorkspaceCommandPaletteHost(store: store))
    }
}

extension WorkspaceStore {
    /// Key-path projections preserve the store's single visibility flag and mode authority.
    /// A delayed dismissal from one presenter must never close the other presenter.
    var isCommandPalettePresented: Bool {
        get { showGoTo && searchSheetPresentation == .commandPalette }
        set {
            if newValue {
                searchSheetPresentation = .commandPalette
                showGoTo = true
            } else if searchSheetPresentation == .commandPalette {
                showGoTo = false
            }
        }
    }

    var isGoToAddressPresented: Bool {
        get { showGoTo && searchSheetPresentation == .goToAddress }
        set {
            if newValue {
                searchSheetPresentation = .goToAddress
                showGoTo = true
            } else if searchSheetPresentation == .goToAddress {
                showGoTo = false
            }
        }
    }

    var commandPaletteEntries: [CommandPaletteEntry] {
        CommandPaletteCatalog.entries(
            functions: focusedAnalysis?.functions ?? [],
            hasSelection: selectedInstruction != nil,
            hasHexBytes: !(focusedAnalysis?.hexBytes.isEmpty ?? true),
            addressOverrides: snapshot.overrides(in: focusedImageSlot),
            typeDefinitions: snapshot.typeDefinitions
        )
    }
}

/// The sheet resolves addresses using the existing image-qualified catalog. Symbol-name
/// precedence stays the same as WorkspaceStore.goTo(query:), including bare hexadecimal names.
enum DSGoToAddressRouting {
    enum Submission: Equatable {
        case navigated
        case chooseImage
        /// Only the navigation authority supplies this message; presentation does not
        /// turn a failed query into a guessed target or a fabricated diagnostic.
        case failed(String?)
    }

    @MainActor
    static func submit(_ query: String, in store: WorkspaceStore) -> Submission {
        if let entries = entries(for: query, in: store), let entry = entries.first {
            if entries.count > 1 { return .chooseImage }
            return perform(DSCommandPaletteInvocation(entry: entry, store: store), in: store)
        }
        return store.goTo(query: query) ? .navigated : .failed(store.lastIssue)
    }

    @MainActor
    static func perform(_ invocation: DSCommandPaletteInvocation, in store: WorkspaceStore) -> Submission {
        invocation.perform(in: store) ? .navigated : .failed(store.lastIssue)
    }

    @MainActor
    static func entries(for query: String, in store: WorkspaceStore) -> [CommandPaletteEntry]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("0x"),
           store.snapshot.address(forSymbolName: trimmed, in: store.focusedImageSlot) != nil {
            return nil
        }
        guard let address = parseHexAddress(trimmed) else { return nil }
        return CommandPaletteCatalog.addressEntries(
            for: address,
            matchingSlots: store.imagesContaining(address),
            imageName: { store.snapshot.binary(in: $0)?.name },
            mode: store.addressDisplayMode,
            resolvedRuntimeTarget: store.imageLayout.resolve(runtimeVA: address)
        )
    }
}

/// A retained palette row may outlive focus, selection, reanalysis or image replacement.
/// Capture its original target and refuse a callback that no longer has that authority.
@MainActor
struct DSCommandPaletteInvocation {
    private let entry: CommandPaletteEntry
    private let workspaceID: UUID
    private let imageSlot: ImageSlot
    private let ownerBinaryID: UUID?
    private let selection: ImageAddress?
    private let instruction: InstructionRow?
    private let function: FunctionSummary?
    private let typeDefinition: TypeDefinition?

    init(
        entry: CommandPaletteEntry,
        store: WorkspaceStore,
        functionsByID: [FunctionSummary.ID: FunctionSummary]? = nil
    ) {
        self.entry = entry
        workspaceID = store.workspaceID
        if case .goToAddressInSlot(_, let slot) = entry.action {
            imageSlot = slot
        } else {
            imageSlot = store.focusedImageSlot
        }
        ownerBinaryID = store.snapshot.binary(in: imageSlot)?.id
        switch entry.action {
        case .toggleBreakpoint, .setColorTag, .setOperandFormat, .applyType:
            selection = store.selectedImageAddress
            instruction = store.selectedInstruction
        case .presentEditorScaffold(let affordance) where !affordance.isWorkspaceGlobal:
            selection = store.selectedImageAddress
            instruction = store.selectedInstruction
        default:
            selection = nil
            instruction = nil
        }
        if case .selectFunction(let id) = entry.action {
            if let functionsByID {
                function = functionsByID[id]
            } else {
                function = store.focusedAnalysis?.functions.first { $0.id == id }
            }
        } else {
            function = nil
        }
        switch entry.action {
        case .editType(let id), .deleteType(let id):
            typeDefinition = store.snapshot.typeDefinitions.first { $0.id == id }
        case .applyType(let name):
            typeDefinition = store.snapshot.typeDefinitions.first { $0.name == name }
        default:
            typeDefinition = nil
        }
    }

    @discardableResult
    func perform(in store: WorkspaceStore) -> Bool {
        guard entry.availability.isAvailable else {
            store.lastIssue = entry.availability.unavailableReason
            return false
        }
        guard store.workspaceID == workspaceID, targetIsCurrent(in: store) else {
            store.lastIssue = "The command target changed. Open Quickly again or choose the current address target."
            return false
        }
        // The Lumen component dismisses before performing. This is also safe for non-UI invocations,
        // and the guarded projection cannot dismiss an address sheet after a mode transition.
        store.isCommandPalettePresented = false
        switch entry.action {
        case .showGoToAddress:
            store.isGoToAddressPresented = true
        case .goToAddress(let address):
            return store.goToAddress(address, in: imageSlot)
        case .goToAddressInSlot(let address, let slot):
            return store.goToAddress(address, in: slot)
        case .selectFunction:
            guard let function else { return false }
            store.selectedTool = .symbols
            store.selectedSidebarItemID = "symbol:\(function.id.uuidString)"
            return store.goToAddress(function.startAddress, in: imageSlot)
        case .selectTool(let tool):
            store.selectedTool = tool
            store.selectedSidebarItemID = store.sidebarItems.first { !$0.id.hasPrefix("section:") }?.id
                ?? store.sidebarItems.first?.id
        case .selectEditorMode(let mode):
            store.editorMode = mode
        case .toggleInspector:
            store.isInspectorPresented.toggle()
        case .toggleBreakpoint:
            store.toggleBreakpointAtSelection()
        case .presentEditorScaffold(let affordance):
            switch affordance {
            case .renameSymbol: store.beginRenameAtSelection()
            case .editComment: store.beginCommentEditAtSelection()
            case .setTag: store.beginTagEditAtSelection()
            case .markAsData: store.markSelectionAsData(true)
            case .markAsCode: store.markSelectionAsData(false)
            case .editFunctionSignature: store.beginSignatureEditAtSelection()
            case .defineType: store.beginTypeDefinition()
            case .defineSwitchHint: store.beginSwitchHintEditAtSelection()
            }
        case .setColorTag(let color):
            store.setColorTagAtSelection(color)
        case .setOperandFormat(let format):
            store.setOperandFormatAtSelection(format)
        case .applyType(let name):
            store.applyTypeAtSelection(name: name)
        case .editType:
            guard let typeDefinition else { return false }
            store.beginTypeDefinition(editing: typeDefinition)
        case .deleteType(let id):
            store.deleteTypeDefinition(id: id)
        }
        return true
    }

    private func targetIsCurrent(in store: WorkspaceStore) -> Bool {
        switch entry.action {
        case .showGoToAddress, .selectTool, .selectEditorMode, .toggleInspector:
            return true
        case .goToAddress, .goToAddressInSlot:
            return ownerBinaryID != nil && store.snapshot.binary(in: imageSlot)?.id == ownerBinaryID
        case .selectFunction:
            return focusedImageIsCurrent(in: store) && function != nil
                && store.focusedAnalysis?.functions.first { $0.id == function?.id } == function
        case .editType, .deleteType:
            return typeDefinition != nil && store.snapshot.typeDefinitions.first { $0.id == typeDefinition?.id } == typeDefinition
        case .presentEditorScaffold(.defineType):
            return focusedImageIsCurrent(in: store)
        case .applyType(let name):
            return selectionIsCurrent(in: store) && (name == nil || typeDefinition != nil
                && store.snapshot.typeDefinitions.first { $0.id == typeDefinition?.id } == typeDefinition)
        case .toggleBreakpoint, .presentEditorScaffold, .setColorTag, .setOperandFormat:
            return selectionIsCurrent(in: store)
        }
    }

    private func focusedImageIsCurrent(in store: WorkspaceStore) -> Bool {
        store.focusedImageSlot == imageSlot && store.snapshot.binary(in: imageSlot)?.id == ownerBinaryID
    }

    private func selectionIsCurrent(in store: WorkspaceStore) -> Bool {
        focusedImageIsCurrent(in: store) && selection != nil && instruction != nil
            && store.selectedImageAddress == selection && store.selectedInstruction == instruction
    }
}

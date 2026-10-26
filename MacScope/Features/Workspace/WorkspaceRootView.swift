import AppKit
import Combine
import SwiftUI
import LumenTokens
import LumenUI
import UniformTypeIdentifiers

/// Product integration supplies these commands only after the per-workspace Reconstruction
/// runtime exists. Optional closures make an absent runtime visibly unavailable without letting
/// presentation code mutate durable Store state speculatively.
struct ReconstructionWorkspaceCommandContext: Equatable, Sendable {
    let windowID: UUID
    let commandScopeID: UUID
    let commandGeneration: UInt64
    let baseProjectionRevision: UInt64
    let jobID: UUID?
}

enum ReconstructionWorkspaceCommandDisposition: Equatable, Sendable {
    case completed
    case rejected
}

struct ReconstructionWorkspaceCommandOutcome: Equatable, Sendable {
    let context: ReconstructionWorkspaceCommandContext
    let disposition: ReconstructionWorkspaceCommandDisposition
    let createdJobID: UUID?
}

struct ReconstructionWorkspaceCommandActions: Sendable {
    /// Opaque lifetime identity minted by the owning runtime. A captured action from a retired
    /// runtime cannot complete a new same-window command whose visible durable cut happens to
    /// repeat (the lifecycle ABA case).
    let commandScopeID: UUID
    let importCorpus: (@MainActor @Sendable (
        [ReconstructionImportSelection],
        ReconstructionCancellation,
        (@Sendable (ReconstructionImportProgress) async -> Void)?
    ) async throws -> WorkspaceReconstructionCorpusImportPublication)?
    let createJob: (@MainActor @Sendable (
        ReconstructionJobCreationRequest,
        ReconstructionWorkspaceCommandContext
    ) async -> ReconstructionWorkspaceCommandOutcome)?
    let startSourceExample: (@MainActor @Sendable (
        ReconstructionWorkspaceCommandContext
    ) async -> ReconstructionWorkspaceCommandOutcome)?
    let startJob: (@MainActor @Sendable (
        UUID,
        ReconstructionWorkspaceCommandContext
    ) async -> ReconstructionWorkspaceCommandOutcome)?
    let pauseJob: (@MainActor @Sendable (
        UUID,
        ReconstructionWorkspaceCommandContext
    ) async -> ReconstructionWorkspaceCommandOutcome)?
    let resumeJob: (@MainActor @Sendable (
        UUID,
        ReconstructionWorkspaceCommandContext
    ) async -> ReconstructionWorkspaceCommandOutcome)?
    let cancelJob: (@MainActor @Sendable (
        UUID,
        ReconstructionWorkspaceCommandContext
    ) async -> ReconstructionWorkspaceCommandOutcome)?

    init(
        commandScopeID: UUID,
        importCorpus: (@MainActor @Sendable (
            [ReconstructionImportSelection],
            ReconstructionCancellation,
            (@Sendable (ReconstructionImportProgress) async -> Void)?
        ) async throws -> WorkspaceReconstructionCorpusImportPublication)? = nil,
        createJob: (@MainActor @Sendable (
            ReconstructionJobCreationRequest,
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)? = nil,
        startSourceExample: (@MainActor @Sendable (
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)? = nil,
        startJob: (@MainActor @Sendable (
            UUID,
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)? = nil,
        pauseJob: (@MainActor @Sendable (
            UUID,
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)? = nil,
        resumeJob: (@MainActor @Sendable (
            UUID,
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)? = nil,
        cancelJob: (@MainActor @Sendable (
            UUID,
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)? = nil
    ) {
        self.commandScopeID = commandScopeID
        self.importCorpus = importCorpus
        self.createJob = createJob
        self.startJob = startJob
        self.startSourceExample = startSourceExample
        self.pauseJob = pauseJob
        self.resumeJob = resumeJob
        self.cancelJob = cancelJob
    }

    static let unavailable = Self(commandScopeID: UUID())
}

enum WorkspaceCentralDestination: Equatable {
    case editor
    case reconstruction
}

/// The editor owns live debugger and shell presentation state. Keep its identity
/// mounted for the workspace lifetime, including when another tool is visible.
/// Hidden presentation cannot receive pointer input or contribute accessibility.
struct WorkspaceCentralHost<Editor: View, Reconstruction: View>: View {
    let destination: WorkspaceCentralDestination
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let reconstruction: () -> Reconstruction

    var body: some View {
        ZStack {
            editor()
                .opacity(destination == .editor ? 1 : 0)
                .allowsHitTesting(destination == .editor)
                .accessibilityHidden(destination != .editor)
                .disabled(destination != .editor)
                .background(WorkspaceEditorFocusBoundary(isVisible: destination == .editor))
            if destination == .reconstruction {
                reconstruction()
            }
        }
    }
}

/// Hiding a retained editor must also end native keyboard ownership: opacity and
/// hit testing alone do not resign an AppKit text or terminal first responder.
struct WorkspaceEditorFocusBoundary: NSViewRepresentable {
    let isVisible: Bool

    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.setEditorVisible(isVisible)
        return view
    }

    func updateNSView(_ view: BoundaryView, context: Context) {
        view.setEditorVisible(isVisible)
    }

    final class BoundaryView: NSView {
        private var editorVisible = true

        func setEditorVisible(_ visible: Bool) {
            guard visible != editorVisible else { return }
            editorVisible = visible
            if !visible { window?.makeFirstResponder(nil) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if !editorVisible { window?.makeFirstResponder(nil) }
        }
    }
}

struct WorkspaceRootView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var documentSession: WorkspaceDocumentSession
    @ObservedObject var nativeDecompilerPresentation: NativeDecompilerPresentationModel
    @ObservedObject private var reconstructionActivationModel:
        ReconstructionWorkspaceActivationModel
    let openCoordinator: WorkspaceOpenCoordinator
    let windowActivator: WorkspaceWindowActivator
    /// This window's identity (WS-2). Used to consume a pending binary import routed here from
    /// another window's Open command, and to key the store in the session registry.
    var windowID: WorkspaceWindowID = .primary
    var assistantInferenceCoordinator: (any Phase2AssistantInferenceCoordinating)?
    /// The one app-owned provider-controller cut. Readiness, activity, and revision must be
    /// projected together; reconstructing any field independently can grant false execution.
    var assistantProviderSnapshot: Phase2LocalAIProviderSnapshot?
    private let reconstructionCommandActions:
        @MainActor () -> ReconstructionWorkspaceCommandActions
    @StateObject private var assistantShellContinuation:
        Phase2AssistantLiveContinuationController
    @StateObject private var pseudocodeSourceSelection: PseudocodeSourceSelectionModel
    @StateObject private var retainedFind = RetainedFindModel()
    /// The code font for Lumen's code components in this window (U5f).
    @AppStorage(MacScopeCodeFont.storageKey) private var codeFontRaw = MacScopeCodeFont.current().rawValue
    /// The user's key bindings, so the window's panel toggles name the same shortcuts as the menu.
    @AppStorage(KeyBindingSet.storageKey) private var keyBindingOverrides: Data?
    /// Open Binary importer presentation (queues or refuses requests made while a sheet is up,
    /// so the importer flag can never wedge; see `WorkspaceOpenBinaryImporterGate`).
    @State private var openBinaryImporterGate = WorkspaceOpenBinaryImporterGate()
    @State private var isAssistantPresented = false
    @State private var workspaceWindowWidth = AppLayout.minimumSupportedWindowWidth
    @State private var isReconstructionCreationPresented = false
    @State private var reconstructionImportCancellation: ReconstructionCancellation?
    @State private var reconstructionImportProgress: ReconstructionImportProgress?
    @State private var reconstructionImportNotice: String?
    @State private var reconstructionImportFailureDetails: [String] = []
    /// The sole Reconstruction presentation owner for this document window. It is value-semantic
    /// and keyed from `WorkspaceWindowID`; durable state remains Store-owned.
    @State private var reconstructionPresentationState: ReconstructionWindowPresentationState
    /// A refused source reveal is transient, bounded, and local to this window. It must never be
    /// persisted into Reconstruction authority or overwrite the dashboard's durable notice.
    @State private var reconstructionTransientNotice: ReconstructionDashboardTransientNotice?
    /// Separate importer for Load Additional Binary — it adds a second image to THIS window's
    /// workspace (not a new document window), so it routes to `store.loadAdditionalBinary`.
    @State private var isLoadAdditionalImporterPresented = false
    /// The document-window session registry (WS-2): resolves/spawns per-window stores. Injected
    /// by the app so the Open commands can adopt a new store and open a new window.
    @EnvironmentObject private var registry: WorkspaceSessionRegistry
    /// SwiftUI's window opener — spawns a new document window for Open/New Window (WS-2 Stage 3).
    @Environment(\.openWindow) private var openWindow
    /// The window's undo manager. Bridged into the store so authoring mutations
    /// register against it, wiring undo to Edit ▸ Undo/Redo and Cmd-Z natively.
    @Environment(\.undoManager) private var windowUndoManager
    /// The app-lifetime debugger authority graph. A missing injection fails closed: previews and
    /// isolated roots receive an attach-unavailable client instead of inventing private actors
    /// that could race another document window.
    @Environment(\.debuggerRuntimeAuthorities) private var debuggerRuntimeAuthorities

    init(
        store: WorkspaceStore,
        documentSession: WorkspaceDocumentSession,
        openCoordinator: WorkspaceOpenCoordinator,
        windowActivator: WorkspaceWindowActivator,
        windowID: WorkspaceWindowID = .primary,
        nativeDecompilerPresentation: NativeDecompilerPresentationModel = .init(),
        assistantInferenceCoordinator: (any Phase2AssistantInferenceCoordinating)? = nil,
        assistantProviderSnapshot: Phase2LocalAIProviderSnapshot? = nil,
        reconstructionActivationModel: ReconstructionWorkspaceActivationModel? = nil,
        reconstructionCommandActions: @escaping @MainActor ()
            -> ReconstructionWorkspaceCommandActions = { .unavailable }
    ) {
        self.store = store
        self.documentSession = documentSession
        self.openCoordinator = openCoordinator
        self.windowActivator = windowActivator
        self.windowID = windowID
        self.nativeDecompilerPresentation = nativeDecompilerPresentation
        self.assistantInferenceCoordinator = assistantInferenceCoordinator
        self.assistantProviderSnapshot = assistantProviderSnapshot
        _reconstructionActivationModel = ObservedObject(
            wrappedValue: reconstructionActivationModel ?? .unavailable
        )
        self.reconstructionCommandActions = reconstructionCommandActions
        _reconstructionPresentationState = State(initialValue:
            ReconstructionWindowPresentationState(
                windowID: windowID.raw,
                selectedJobID: store.selectedReconstructionJobID
            )
        )
        _reconstructionTransientNotice = State(initialValue: nil)
        _pseudocodeSourceSelection = StateObject(
            wrappedValue: PseudocodeSourceSelectionModel()
        )
        _assistantShellContinuation = StateObject(wrappedValue:
            Phase2AssistantLiveContinuationController(
                store: store,
                coordinator: assistantInferenceCoordinator,
                durableTerminalFinalizer:
                    Phase2AssistantLiveContinuationController.productionTerminalFinalizer(
                        store: store
                    )
            )
        )
    }

    // The root body is composed from type-scope stages so the Swift type checker solves each
    // modifier cluster separately (the single expression previously took ~13 s to type-check).
    // Each stage applies the original modifiers in the original order to the previous stage's
    // view, so the concrete view type, state ownership, and environment propagation are
    // unchanged; only the expression boundaries moved.
    var body: some View {
        let documentDisplayName = WorkspaceDocumentCommandPolicy.resolve(
            snapshot: documentSession.snapshot
        ).displayName
        let layout = AppLayout.workspacePaneMetrics(for: workspaceWindowWidth)

        applyingStateSynchronization(
            to: applyingWorkspaceSheets(
                to: applyingStoreSheets(
                    to: applyingCommandHandlerModifiers(
                        to: applyingCommandReceivers(
                            to: applyingWindowIntegration(
                                to: workspaceLayout(layout: layout, documentDisplayName: documentDisplayName)
                                    .lumenCodeFont(LumenCodeFont(rawValue: codeFontRaw) ?? .standard),
                                documentDisplayName: documentDisplayName
                            )
                        )
                    )
                )
            )
        )
    }

    // MARK: Body stages (type-scope helpers; see `body`)

    private func workspaceLayout(
        layout: WorkspacePaneMetrics,
        documentDisplayName: String
    ) -> some View {
        // U8-0 (Lumen 0.39): Lumen's workspace window pins the top bar in the top safe area and
        // clips every region, so hiding a panel can never push the bar off screen. Its left, bottom
        // and right toggles follow `workspacePanels`; the bottom deck itself stays inside the
        // editor surface, which owns the debugger and shell state (0.39.1 `bottomPanelToggle`).
        LumenWorkspaceWindow(panels: workspacePanels(layout: layout)) {
            VStack(spacing: 0) {
                WorkspaceContentTabBar(store: store)
                editorPane(layout: layout)
            }
            .workbenchPaneBackground(.editor)
        } sidebar: {
            SidebarView(store: store)
        } inspector: {
            InspectorView(store: store)
                .disabled(!presentsInspector(layout: layout))
        } topLeading: {
            WorkspaceTopBar(
                store: store,
                documentDisplayName: documentDisplayName,
                requestOpenBinary: requestOpenBinaryImporter,
                isAssistantPresented: $isAssistantPresented
            )
        } topCenter: {
            WorkspaceTopBarCenter(store: store)
        }
        .contentMinimumWidth(AppLayout.editorMinimumReadableWidth)
        .bottomPanelToggle($store.bottomPanelPresentation.isPresented)
        // U8-1 (Lumen 0.39.2): MacScope's column widths and the user's panel shortcuts.
        .columnWidths(
            sidebar: (AppLayout.sidebarMinWidth, AppLayout.sidebarIdealWidth, AppLayout.sidebarMaxWidth),
            inspector: (layout.inspectorMinWidth, layout.inspectorIdealWidth, layout.inspectorMaxWidth)
        )
        .panelShortcuts(DSWorkspaceViewShortcuts(bindings: KeyBindingSet.resolvingOverrides(keyBindingOverrides)).lumenShortcuts)
    }

    private func presentsInspector(layout: WorkspacePaneMetrics) -> Bool {
        Self.shouldPresentInspector(
            for: store.selectedTool,
            requested: store.isInspectorPresented,
            layoutAllowsInspector: layout.allowsInspector
        )
    }

    /// The window's panels from the store: the sidebar flag, the bottom deck, and the inspector as
    /// it is actually presented (never in Reconstruction, nor when the window is too narrow). A
    /// toggle writes back only the panel it changed, so a hidden-by-layout inspector keeps the
    /// user's request.
    private func workspacePanels(layout: WorkspacePaneMetrics) -> Binding<LumenWorkspacePanels> {
        Binding(
            get: {
                LumenWorkspacePanels(
                    leading: store.isSidebarPresented,
                    bottom: store.bottomPanelPresentation.isPresented,
                    trailing: presentsInspector(layout: layout)
                )
            },
            set: { panels in
                if panels.leading != store.isSidebarPresented { store.isSidebarPresented = panels.leading }
                if panels.bottom != store.bottomPanelPresentation.isPresented {
                    store.bottomPanelPresentation.isPresented = panels.bottom
                }
                if panels.trailing != presentsInspector(layout: layout) { store.isInspectorPresented = panels.trailing }
            }
        )
    }

    // Keep the editor's intrinsic controls from becoming an NSSplitView minimum.
    // The clear sizing proxy participates in split-view negotiation; the real
    // editor is rendered inside that negotiated width. This preserves native split
    // behavior without allowing a wide editor subtree to center the root outside a
    // compact window and clip both supporting panes.
    private func editorPane(layout: WorkspacePaneMetrics) -> some View {
        Color.clear
            .frame(
                minWidth: layout.editorFrameMinimumWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .overlay {
                centralContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .layoutPriority(2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.centralAccessibilityIdentifier(for: store.selectedTool))
    }

    private func applyingWindowIntegration(
        to content: some View,
        documentDisplayName: String
    ) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.root")
            .background {
                GeometryReader { (proxy: GeometryProxy) in
                    Color.clear
                        .onAppear {
                            updateWorkspaceWindowWidth(proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { (_: CGFloat, width: CGFloat) in
                            updateWorkspaceWindowWidth(width)
                        }
                }
            }
            // Publish this window's store as the focused document (WS-2) so the menu-command layer
            // addresses THIS store; with one window it is always the focused store, so commands
            // behave exactly as before.
            .focusedSceneValue(\.workspaceStore, store)
            .focusedSceneValue(
                \.reconstructionWindowCommands,
                reconstructionFocusedCommandRouting
            )
            // Expose this window's store to descendant context menus (disassembly/pseudocode rows)
            // so their posted commands target THIS document.
            .environment(\.commandTargetStore, store)
            // Reflect the saved/opened document so a successful Save is visible.
            .navigationTitle(documentDisplayName)
            // Surface unsaved edits through the standard macOS document-dirty affordance
            // (the close-button dot / "— Edited" title), driven by the store's dirty flag.
            .background(
                WindowDocumentEditedReader(
                    isEdited: documentSession.snapshot.hasUnsavedChanges
                )
            )
            .fileImporter(isPresented: openBinaryImporterBinding, allowedContentTypes: [.item], allowsMultipleSelection: false) { (result: Result<[URL], any Error>) in
                guard case let .success(urls) = result, let url = urls.first else { return }
                // WS-2: open a binary in a NEW document window unless the current window is an
                // untitled, clean, empty document to reuse. The loader-options flow (slice picker)
                // runs in whichever window ends up importing.
                openBinary(at: url)
            }
            // Load Additional Binary: add a second image to the CURRENT workspace, in this window.
            .fileImporter(isPresented: $isLoadAdditionalImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: false) { (result: Result<[URL], any Error>) in
                guard case let .success(urls) = result, let url = urls.first else { return }
                store.beginLoadAdditionalBinary(url: url)
            }
            // WS-2: a window spawned by another window's Open Binary command imports its pending
            // binary once it appears, so the slice picker / progress belong to this document.
            .task(id: windowID) {
                if let pending = registry.takePendingBinaryOpen(for: windowID) {
                    store.beginImport(url: pending)
                }
            }
            // WS-2: track the key window so the scripting host targets the FRONT document, and evict
            // this window's store from the registry when the window closes.
            .background(windowLifecycleReader)
    }

    private var windowLifecycleReader: WindowLifecycleReader {
        WindowLifecycleReader(
            store: store,
            documentSession: documentSession,
            registry: registry,
            windowID: windowID,
            windowActivator: windowActivator,
            onWriteOutcome: { WorkspaceDocumentWritePresentation.apply($0, to: store) },
            onClose: {
                openCoordinator.windowDidClose(
                    windowID,
                    sessionID: documentSession.snapshot.sessionID
                )
            }
        )
    }

    /// Commands addressed to this window's store.
    private func targetedCommandPublisher(
        for name: Notification.Name
    ) -> Publishers.Filter<NotificationCenter.Publisher> {
        NotificationCenter.default.publisher(for: name).filter { (note: Notification) -> Bool in
            store.commandTargetsSelf(note)
        }
    }

    /// Commands addressed to this window's store, or untargeted commands while this is the only
    /// registered window (intents from Shortcuts, Spotlight, Siri).
    private func targetedOrSoleWindowCommandPublisher(
        for name: Notification.Name
    ) -> Publishers.Filter<NotificationCenter.Publisher> {
        NotificationCenter.default.publisher(for: name).filter { (note: Notification) -> Bool in
            store.commandTargetsSelf(note)
                || (note.userInfo?[WorkspaceStore.commandTargetStoreKey] == nil && registry.count == 1)
        }
    }

    private func applyingCommandReceivers(to content: some View) -> some View {
        content
            .onReceive(targetedCommandPublisher(for: .macScopeOpenBinary)) { (_: Notification) in
                requestOpenBinaryImporter()
            }
            // A request queued under a document alert replays once the alert closes.
            .onChange(of: isDocumentAlertPending) { (_: Bool, pending: Bool) in
                // Give the closing alert time to leave the window before presenting.
                if !pending {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drainDeferredOpenBinaryImporter() }
                }
            }
            // Open Binary intent (Shortcuts, Spotlight, Siri): a specific file, same spawn-or-reuse
            // rule as File ▸ Open Binary.
            .onReceive(targetedOrSoleWindowCommandPublisher(for: .macScopeOpenBinaryURL)) { (note: Notification) in
                if let url = note.object as? URL { openBinary(at: url) }
            }
            .onReceive(targetedCommandPublisher(for: .macScopeLoadAdditionalBinary)) { (_: Notification) in
                isLoadAdditionalImporterPresented = true
            }
            .onReceive(targetedCommandPublisher(for: .macScopeReadDebugSymbols)) { (_: Notification) in
                presentReadDebugSymbolsPanelAndImport()
            }
            .onReceive(targetedOrSoleWindowCommandPublisher(for: .macScopeShowAssistant)) { (_: Notification) in
                isAssistantPresented = true
            }
    }

    private func applyingCommandHandlerModifiers(to content: some View) -> some View {
        content
            .modifier(
                WorkspaceDocumentCommandHandlers(
                    store: store,
                    documentSession: documentSession,
                    openCoordinator: openCoordinator,
                    registry: registry,
                    windowID: windowID,
                    windowActivator: windowActivator
                )
            )
            .modifier(ExportCommandHandlers(store: store,
                nativePresentation: nativeDecompilerPresentation,
                providerSelection: pseudocodeSourceSelection,
                captureExportOwner: captureExportOwner))
            .modifier(NavigationCommandHandlers(store: store))
            .modifier(AuthoringCommandHandlers(store: store))
            .modifier(WorkspaceCommandHandlers(store: store))
            .modifier(VersionCompareCommandHandler(store: store))
            .modifier(DocumentAlerts(store: store))
            .dsWorkspaceCommandPalette(store: store)
    }

    private func applyingStoreSheets(to content: some View) -> some View {
        content
            .sheet(isPresented: $store.isGoToAddressPresented) {
                GoToSheet(store: store)
            }
            .sheet(isPresented: $store.showFind) {
                FindSheet(store: store, model: retainedFind)
            }
            .sheet(isPresented: $store.showBrowsers) {
                BrowsersSheet(store: store)
            }
            .sheet(isPresented: $store.showNavigationHistory) {
                NavigationHistorySheet(store: store)
            }
            .sheet(isPresented: $store.showProblems) {
                ProblemsSheet(store: store)
            }
            .sheet(isPresented: $store.showMachOMetadata) {
                MachOMetadataSheet(store: store)
            }
            .sheet(isPresented: $store.showREAWorkbench) {
                reaWorkbenchSheetContent
            }
    }

    @ViewBuilder
    private var reaWorkbenchSheetContent: some View {
        if let binary = store.focusedBinary, let bytes = store.focusedAnalysis?.imageBytes, !bytes.isEmpty {
            REAWorkbenchView(selectedBinaryURL: URL(fileURLWithPath: binary.resolvedExecutablePath ?? binary.path),
                expectedSelectedSHA256: REACaptureCommitment.digest(bytes),
                requestedSliceIndex: binary.selectedSliceIndex, workspaceID: store.workspaceID,
                history: store.reaResultEvidence.records,
                makeAuthority: { hash, snapshot in store.reaAuthority(imageSHA256: hash, snapshotID: snapshot) },
                onAccepted: { candidate in try store.publishREAResult(candidate) })
        } else {
            ContentUnavailableView("REA unavailable", systemImage: "doc.questionmark",
                description: Text("Open an image with captured source bytes first."))
        }
    }

    private func applyingWorkspaceSheets(to content: some View) -> some View {
        content
            .sheet(isPresented: $isAssistantPresented) {
                assistantSheet
            }
            .sheet(isPresented: $isReconstructionCreationPresented) {
                reconstructionCreationSheet
            }
            .sheet(item: $store.overrideEditorRequest) { (request: OverrideEditorRequest) in
                OverrideEditorSheet(request: request, store: store)
            }
            .sheet(item: $store.signatureEditorRequest) { (request: SignatureEditorRequest) in
                SignatureEditorSheet(request: request, store: store, inferenceCoordinator: assistantInferenceCoordinator)
            }
            // Agent attach (MCP): consent request and the "attached" indicator. A bottom inset, not
            // an overlay, so it takes its own space and never covers the editor mode buttons.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MCPAttachBanner(store: store)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .sheet(item: $store.typeEditorRequest) { (request: TypeEditorRequest) in
                TypeEditorSheet(request: request, store: store)
            }
            .sheet(item: $store.switchHintEditorRequest) { (request: SwitchHintEditorRequest) in
                SwitchHintEditorSheet(request: request, store: store)
            }
            .sheet(item: $store.loaderOptionsRequest) { (request: LoaderOptionsRequest) in
                LoaderOptionsSheet(request: request, store: store)
            }
            .sheet(item: $store.pendingPatchBytesRequest) { (request: PatchBytesRequest) in
                PatchBytesSheet(store: store, request: request)
            }
            .sheet(item: $store.pendingAssembleRequest) { (request: AssembleRequest) in
                AssembleSheet(store: store, request: request)
            }
            .modifier(AuthoringSheetPresenters(store: store))
    }

    private var assistantSheet: Phase2AssistantSheet {
        Phase2AssistantSheet(
            store: store,
            nativeDecompilerPresentation: nativeDecompilerPresentation,
            coordinator: assistantInferenceCoordinator,
            readiness: assistantReadiness,
            shellContinuationController: assistantShellContinuation,
            sameTurnShellPresentation: assistantShellContinuation.presentation,
            approveSameTurnShellAction: assistantShellContinuation.approve,
            runSameTurnShellAction: assistantShellContinuation.run,
            rejectSameTurnShellAction: assistantShellContinuation.reject,
            dismissSameTurnShellAction: assistantShellContinuation.dismiss,
            cancelSameTurnShellAction: assistantShellContinuation.cancel
        )
    }

    private var reconstructionCreationSheet: ReconstructionJobCreationSheet {
        ReconstructionJobCreationSheet(
            availableItems: reconstructionCreationItems,
            availableFunctions: ReconstructionJobCreationRequest.committedFunctions(in: store.reconstructionState),
            submissionAvailable: reconstructionCreationSubmissionAvailable,
            onImport: reconstructionImportAction,
            onCancel: {
                isReconstructionCreationPresented = false
            },
            onCreate: { (request: ReconstructionJobCreationRequest) in
                submitReconstructionCreation(request)
            }
        )
    }

    private func submitReconstructionCreation(_ request: ReconstructionJobCreationRequest) {
        guard reconstructionCreationSubmissionAvailable,
              let createJob = reconstructionCommands.createJob else { return }
        guard beginReconstructionCommand(
            .create,
            expectedCommittedState: nil,
            dispatch: { context in
                await createJob(request, context)
            }
        ) else { return }
        isReconstructionCreationPresented = false
    }

    private func applyingStateSynchronization(to content: some View) -> some View {
        content
            .onChange(of: retainedFind.bindingIdentity(for: store), initial: true) { _, _ in
                retainedFind.bind(store: store)
            }
            .onChange(of: windowUndoManager.map(ObjectIdentifier.init), initial: true) {
                store.hostUndoManager = windowUndoManager
            }
            .onChange(of: store.selectedReconstructionJobID, initial: true) {
                synchronizeReconstructionJobSelection()
            }
            .onChange(of: reconstructionDurableIdentity, initial: true) {
                reconcileReconstructionPendingIntent()
            }
            .onChange(of: reconstructionCommands.commandScopeID, initial: true) {
                reconcileReconstructionPendingIntent()
            }
            .onChange(of: reconstructionActivationModel.snapshot, initial: true) {
                fencePendingReconstructionIntentIfCommandBoundaryRetired()
            }
            .onChange(of: reconstructionPendingCommandBoundaryAvailable, initial: true) {
                fencePendingReconstructionIntentIfCommandBoundaryRetired()
            }
    }

    /// A detached export may finish after its requesting document has been retired.
    /// Capture all three authorities so a reused window ID cannot authorize its panel.
    private func captureExportOwner() -> (@MainActor () -> Bool)? {
        let ownerID = windowID
        guard let window = windowActivator.window(for: ownerID), window.attachedSheet == nil,
              registry.storeIfPresent(for: ownerID) === store,
              registry.documentSessionIfPresent(for: ownerID) === documentSession,
              !documentSession.isClosedForWindowClose,
              !documentSession.isTerminationPreparationActive else { return nil }
        return { [weak store, weak documentSession, weak registry, weak windowActivator, weak window] in
            guard let store, let documentSession, let registry, let windowActivator, let window else {
                return false
            }
            return !documentSession.isClosedForWindowClose
                && !documentSession.isTerminationPreparationActive
                && window.attachedSheet == nil
                && registry.storeIfPresent(for: ownerID) === store
                && registry.documentSessionIfPresent(for: ownerID) === documentSession
                && windowActivator.window(for: ownerID) === window
        }
    }

    private func updateWorkspaceWindowWidth(_ width: CGFloat) {
        guard width.isFinite, width >= AppLayout.minimumSupportedWindowWidth else { return }
        guard abs(workspaceWindowWidth - width) >= 0.5 else { return }
        workspaceWindowWidth = width
    }

    /// Builds the client captured by this window's stable debugger view model. Production windows
    /// share the complete graph retained by `MacScopeAppRuntimeServices`; missing composition
    /// deliberately creates no fallback authority.
    private var debuggerClient: any DebuggerClient {
        Self.makeDebuggerClient(runtimeAuthorities: debuggerRuntimeAuthorities)
    }

    private var assistantReadiness: Phase2LocalAIProviderReadiness {
        assistantProviderSnapshot?.readiness ?? .unavailable
    }

    private var assistantProviderActivity: Phase2LocalAIProviderActivity {
        assistantProviderSnapshot?.activity ?? .idle
    }

    private var assistantProviderRevision: UInt64 {
        assistantProviderSnapshot?.revision ?? 0
    }

    private var reconstructionCommands: ReconstructionWorkspaceCommandActions {
        reconstructionCommandActions()
    }

    private var reconstructionCreateAction: (() -> Void)? {
        guard reconstructionProjection.controls.create.enabled,
              reconstructionCreationSubmissionAvailable else { return nil }
        return {
            guard reconstructionProjection.controls.create.enabled,
                  reconstructionCreationSubmissionAvailable else { return }
            isReconstructionCreationPresented = true
        }
    }

    private var reconstructionSourceExampleAction: (() -> Void)? {
        guard reconstructionProjection.controls.create.enabled,
              documentSession.snapshot.location != nil,
              let action = reconstructionCommands.startSourceExample else { return nil }
        return {
            _ = beginReconstructionCommand(.create, expectedCommittedState: nil, dispatch: action)
        }
    }

    private var reconstructionDashboardCommandDispatcher:
        ReconstructionDashboardCommandDispatcher {
        ReconstructionDashboardCommandDispatcher(
            onCreate: reconstructionCreateAction,
            onStart: reconstructionAction(.start, reconstructionCommands.startJob),
            onPause: reconstructionAction(.pause, reconstructionCommands.pauseJob),
            onResume: reconstructionAction(.resume, reconstructionCommands.resumeJob),
            onCancel: reconstructionAction(.cancel, reconstructionCommands.cancelJob)
        )
    }

    private var reconstructionFocusedCommandRouting: ReconstructionWindowCommandRouting {
        ReconstructionWindowCommandRouting(
            controls: reconstructionProjection.controls,
            dispatcher: reconstructionDashboardCommandDispatcher
        )
    }

    static func centralDestination(for tool: WorkspaceTool) -> WorkspaceCentralDestination {
        tool == .reconstruction ? .reconstruction : .editor
    }

    static func centralAccessibilityIdentifier(for tool: WorkspaceTool) -> String {
        // A single accessible overlay can be reused by .contain instead of nested. Keep the
        // outer identifier aligned with its visible destination, never overriding it as editor.
        tool == .reconstruction
            ? ReconstructionAccessibilityIdentifiers.destination
            : "workspace.pane.editor"
    }

    static func shouldPresentInspector(
        for tool: WorkspaceTool,
        requested: Bool,
        layoutAllowsInspector: Bool
    ) -> Bool {
        tool != .reconstruction && requested && layoutAllowsInspector
    }

    private var centralContent: some View {
        WorkspaceCentralHost(destination: Self.centralDestination(for: store.selectedTool)) {
            EditorSurfaceView(
                store: store,
                nativeDecompilerPresentation: nativeDecompilerPresentation,
                pseudocodeSourceSelection: pseudocodeSourceSelection,
                debuggerClient: debuggerClient
            )
        } reconstruction: {
            let dispatcher = reconstructionDashboardCommandDispatcher
            ReconstructionDashboardView(
                projection: reconstructionProjection,
                onCreate: dispatcher.action(for: .create),
                onStart: dispatcher.action(for: .start),
                onPause: dispatcher.action(for: .pause),
                onResume: dispatcher.action(for: .resume),
                onCancel: dispatcher.action(for: .cancel),
                onSelectJob: selectReconstructionJob,
                onSelectTask: selectReconstructionTask,
                onSelectEvidence: selectReconstructionEvidence,
                onRevealEvidenceSource: revealReconstructionEvidenceSource,
                sourceNavigableEvidenceIDs: reconstructionSourceNavigableEvidenceIDs,
                transientNotice: reconstructionTransientNotice,
                onSourceExample: reconstructionSourceExampleAction,
                onImport: reconstructionImportAction,
                onCancelImport: reconstructionImportCancellation.map { cancellation in
                    { cancellation.cancel() }
                },
                onSaveBeforeImport: documentSession.snapshot.location == nil ? {
                    NotificationCenter.default.post(
                        name: .macScopeSave,
                        object: nil,
                        userInfo: [WorkspaceStore.commandTargetStoreKey: store]
                    )
                } : nil,
                importStatus: reconstructionImportStatus,
                importFailureDetails: reconstructionImportFailureDetails
            )
        }
        .id(EditorSceneIdentity(store: store))
    }

    private var reconstructionProjection: ReconstructionStatusProjection {
        let windowState = reconstructionPresentationState.windowID == windowID.raw
            ? reconstructionPresentationState
            : ReconstructionWindowPresentationState(
                windowID: windowID.raw,
                selectedJobID: store.selectedReconstructionJobID
            )
        let selectedJobID = windowState.selectedJobID
            ?? store.selectedReconstructionJobID
        let exactJobID = ReconstructionStatusProjection.selectedJob(
            in: store.reconstructionState,
            selectedJobID: selectedJobID
        )?.jobID
        let effectiveWindow = windowState.selectedJobID == exactJobID
            ? windowState
            : windowState.selectingJob(exactJobID)
        let runtimeAuthority = reconstructionActivationModel.snapshot
            .presentationAuthority.job(exactJobID)
        return ReconstructionStatusProjection.project(
            workspace: store.reconstructionState,
            selectedJobID: exactJobID,
            readiness: assistantReadiness,
            activity: assistantProviderActivity,
            providerRevision: assistantProviderRevision,
            restoreStatus: reconstructionRestoreStatus,
            windowState: effectiveWindow,
            currentEvidenceFrontierSHA256: runtimeAuthority?.evidenceFrontierSHA256,
            durableProjectionRevision: runtimeAuthority?.projectionRevision,
            creationValidation: reconstructionCreationValidation
        )
    }

    private var reconstructionCreationValidation: ReconstructionCreationValidation {
        documentSession.snapshot.location == nil
            ? .durableDocumentLocationMissing
            : .valid
    }

    private var reconstructionRestoreStatus: ReconstructionRestoreStatus {
        switch reconstructionActivationModel.snapshot.phase {
        case .inactive, .activating, .restoring:
            .restoring
        case .ready:
            .complete
        case .failed(let failure):
            .failed(failure)
        }
    }

    private var reconstructionCreationSubmissionAvailable: Bool {
        reconstructionCommands.createJob != nil
            && reconstructionCreationValidation == .valid
    }

    private var reconstructionDurableIdentity: ReconstructionDurablePresentationIdentity {
        let projection = reconstructionProjection
        return .init(
            jobID: projection.jobID,
            state: projection.state,
            projectionRevision: projection.projectionRevision,
            checkpointRevision: projection.checkpointRevision
        )
    }

    private var reconstructionCreationItems: [ReconstructionJobCreationItem] {
        ReconstructionJobCreationItem.committedItems(in: store.reconstructionState)
    }

    private var reconstructionImportAction: (() -> Void)? {
        guard reconstructionImportCancellation == nil,
              reconstructionCommands.importCorpus != nil else { return nil }
        return presentReconstructionImportPanel
    }

    private var reconstructionImportStatus: String {
        if let progress = reconstructionImportProgress, reconstructionImportCancellation != nil {
            return "Imported \(progress.completedSelectionCount) of \(progress.totalSelectionCount) selections; "
                + "\(progress.occurrenceCount) items; \(progress.failureCount) failures."
        }
        if let reconstructionImportNotice { return reconstructionImportNotice }
        if documentSession.snapshot.location == nil {
            return "Save the workspace before importing corpus items."
        }
        if reconstructionCommands.importCorpus == nil {
            return "Corpus import becomes available when Reconstruction finishes opening."
        }
        return "Choose files, folders, applications, or frameworks to import as selected targets."
    }

    private func presentReconstructionImportPanel() {
        guard reconstructionImportCancellation == nil,
              let importCorpus = reconstructionCommands.importCorpus else { return }
        let scope = reconstructionCommands.commandScopeID
        let panel = NSOpenPanel()
        panel.title = "Import Reconstruction Corpus"
        panel.message = "Choose the artifacts to reconstruct. Folder and bundle contents are imported within bounded limits."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK,
              reconstructionCommands.commandScopeID == scope,
              reconstructionCommands.importCorpus != nil else { return }
        let selections = panel.urls.map {
            ReconstructionImportSelection(rootURL: $0, roles: [.primaryTarget])
        }
        guard !selections.isEmpty else { return }
        let cancellation = ReconstructionCancellation()
        reconstructionImportCancellation = cancellation
        reconstructionImportProgress = nil
        reconstructionImportNotice = "Importing selected corpus items…"
        reconstructionImportFailureDetails = []
        Task { @MainActor in
            defer {
                if reconstructionImportCancellation === cancellation {
                    reconstructionImportCancellation = nil
                    reconstructionImportProgress = nil
                }
            }
            do {
                let publication = try await importCorpus(selections, cancellation, { progress in
                    await MainActor.run {
                        guard reconstructionCommands.commandScopeID == scope,
                              reconstructionImportCancellation === cancellation else { return }
                        reconstructionImportProgress = progress
                    }
                })
                guard reconstructionCommands.commandScopeID == scope else { return }
                reconstructionImportNotice = publication.publicationAccepted
                    ? "Imported \(publication.result.occurrences.count) corpus items; \(publication.result.failures.count) failures."
                    : "No corpus change committed; \(publication.result.failures.count) failures."
                reconstructionImportFailureDetails = publication.result.failures.prefix(20).map {
                    "\(String($0.sourceURL.lastPathComponent.prefix(512))): \($0.reason.rawValue)"
                }
                if publication.result.failures.count > 20 {
                    reconstructionImportFailureDetails.append(
                        "\(publication.result.failures.count - 20) additional failures."
                    )
                }
            } catch {
                guard reconstructionCommands.commandScopeID == scope else { return }
                reconstructionImportNotice = cancellation.isCancelled || error is CancellationError
                    ? "Corpus import cancelled."
                    : "Corpus import could not complete. Try the selection again."
            }
        }
    }

    private func reconstructionAction(
        _ kind: ReconstructionCommandKind,
        _ command: (@MainActor @Sendable (
            UUID,
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome)?
    ) -> (() -> Void)? {
        let projection = reconstructionProjection
        guard projection.controls.availability(for: kind).enabled,
              let jobID = projection.jobID,
              let command else { return nil }
        return {
            guard reconstructionProjection.jobID == jobID,
                  reconstructionProjection.controls.availability(for: kind).enabled else {
                return
            }
            _ = beginReconstructionCommand(
                kind.pendingKind,
                expectedCommittedState: expectedCommittedState(for: kind),
                dispatch: { context in
                    await command(jobID, context)
                }
            )
        }
    }

    @discardableResult
    private func beginReconstructionCommand(
        _ kind: ReconstructionPendingCommandKind,
        expectedCommittedState: ReconstructionJobState?,
        dispatch: @escaping @MainActor @Sendable (
            ReconstructionWorkspaceCommandContext
        ) async -> ReconstructionWorkspaceCommandOutcome
    ) -> Bool {
        let projection = reconstructionProjection
        guard let pendingWindow = projection.windowState.beginningCommand(
            kind,
            commandScopeID: reconstructionCommands.commandScopeID,
            against: reconstructionDurableIdentity,
            expectedCommittedState: expectedCommittedState
        ), let baseProjectionRevision = pendingWindow.pendingIntent.baseProjectionRevision
        else { return false }
        let context = ReconstructionWorkspaceCommandContext(
            windowID: pendingWindow.windowID,
            commandScopeID: reconstructionCommands.commandScopeID,
            commandGeneration: pendingWindow.pendingIntent.generation,
            baseProjectionRevision: baseProjectionRevision,
            jobID: pendingWindow.pendingIntent.jobID
        )
        // This write intentionally precedes the command closure. A synchronous re-entry therefore
        // observes every command disabled before it can attempt a duplicate submission.
        reconstructionPresentationState = pendingWindow
        Task { @MainActor in
            let outcome = await dispatch(context)
            resolveReconstructionCommandOutcome(outcome)
        }
        return true
    }

    private func resolveReconstructionCommandOutcome(
        _ outcome: ReconstructionWorkspaceCommandOutcome
    ) {
        let completion = ReconstructionCommandCompletion(
            windowID: outcome.context.windowID,
            commandScopeID: outcome.context.commandScopeID,
            commandGeneration: outcome.context.commandGeneration,
            baseProjectionRevision: outcome.context.baseProjectionRevision,
            jobID: outcome.context.jobID,
            selectedTaskID: nil,
            selectedEvidenceID: nil
        )
        let result = reconstructionPresentationState.accepting(
            completion,
            durableProjectionRevision: reconstructionDurableIdentity.projectionRevision
        )
        guard result.accepted else { return }

        var resolvedWindow = result.window
        if outcome.disposition == .completed,
           outcome.context.jobID == nil,
           let createdJobID = outcome.createdJobID,
           store.reconstructionState.jobs.contains(where: { $0.jobID == createdJobID }) {
            resolvedWindow = resolvedWindow.selectingJob(createdJobID)
        }
        reconstructionPresentationState = resolvedWindow
    }

    private func expectedCommittedState(
        for command: ReconstructionCommandKind
    ) -> ReconstructionJobState? {
        switch command {
        case .create: nil
        case .start: .ingesting
        case .pause: .paused
        case .resume: reconstructionProjection.controls.resume.requiredResumeTarget
        case .cancel: .cancelled
        }
    }

    private func synchronizeReconstructionJobSelection() {
        let state = store.reconstructionState
        let requestedJobID = store.selectedReconstructionJobID
            ?? reconstructionPresentationState.selectedJobID
        let selectedJobID = ReconstructionStatusProjection.selectedJob(
            in: state,
            selectedJobID: requestedJobID
        )?.jobID
        guard reconstructionPresentationState.selectedJobID != selectedJobID else { return }
        reconstructionPresentationState = reconstructionPresentationState.selectingJob(
            selectedJobID
        )
    }

    private func selectReconstructionJob(_ jobID: UUID) {
        guard store.reconstructionState.jobs.contains(where: { $0.jobID == jobID }) else {
            return
        }
        reconstructionTransientNotice = nil
        reconstructionPresentationState = reconstructionProjection.windowState.selectingJob(jobID)
    }

    private func selectReconstructionTask(_ taskID: UUID) {
        let projection = reconstructionProjection
        guard projection.taskSamples.contains(where: { $0.taskID == taskID }) else { return }
        reconstructionTransientNotice = nil
        reconstructionPresentationState = projection.windowState.selectingTask(taskID)
    }

    private func selectReconstructionEvidence(_ evidenceID: UUID) {
        let projection = reconstructionProjection
        guard projection.evidenceSamples.contains(where: { $0.evidenceID == evidenceID }) else {
            return
        }
        reconstructionTransientNotice = nil
        reconstructionPresentationState = projection.windowState.selectingEvidence(evidenceID)
    }

    private func reconcileReconstructionPendingIntent() {
        let result = reconstructionPresentationState.reconcilingPending(
            with: reconstructionDurableIdentity,
            activeCommandScopeID: reconstructionCommands.commandScopeID
        )
        guard result.window != reconstructionPresentationState else { return }
        reconstructionPresentationState = result.window
    }

    private var reconstructionPendingCommandBoundaryAvailable: Bool {
        switch reconstructionPresentationState.pendingIntent.kind {
        case .none: true
        case .create: reconstructionCommands.createJob != nil
        case .start: reconstructionCommands.startJob != nil
        case .pause: reconstructionCommands.pauseJob != nil
        case .resume: reconstructionCommands.resumeJob != nil
        case .cancel: reconstructionCommands.cancelJob != nil
        }
    }

    private func fencePendingReconstructionIntentIfCommandBoundaryRetired() {
        guard !reconstructionPendingCommandBoundaryAvailable else { return }
        let result = reconstructionPresentationState
            .fencingPendingForUnavailableCommandBoundary()
        guard result.window != reconstructionPresentationState else { return }
        reconstructionPresentationState = result.window
    }

    private var reconstructionSourceNavigableEvidenceIDs: Set<UUID> {
        let projection = reconstructionProjection
        return Set(projection.evidenceSamples.compactMap { sample in
            Self.reconstructionSourceNavigationRequest(
                evidenceID: sample.evidenceID,
                projection: projection,
                workspaceID: store.workspaceID,
                workspace: store.reconstructionState,
                snapshot: store.snapshot
            ) == nil ? nil : sample.evidenceID
        })
    }

    private func revealReconstructionEvidenceSource(_ evidenceID: UUID) {
        if ReconstructionInstalledSourceRevealQualificationBarrier.isRequested() {
            guard let renderedRequest = Self.reconstructionSourceNavigationRequest(
                evidenceID: evidenceID,
                projection: reconstructionProjection,
                workspaceID: store.workspaceID,
                workspace: store.reconstructionState,
                snapshot: store.snapshot
            ) else {
                reconstructionTransientNotice = Self.reconstructionSourceNavigationRefusal(
                    for: nil
                )
                return
            }
            Task { @MainActor in
                let barrierResult = await
                    ReconstructionInstalledSourceRevealQualificationBarrier.waitIfRequested(
                        evidenceID: evidenceID,
                        request: renderedRequest
                    )
                switch barrierResult {
                case .released:
                    guard store.retireReconstructionSourceAuthorityForInstalledQualification(
                        renderedRequest
                    ) else {
                        reconstructionTransientNotice =
                            Self.reconstructionSourceNavigationRefusal(for: nil)
                        return
                    }
                    // The synthetic retirement is restored before the Store method returns. It
                    // exists solely to prove the retained rendered action is stale; never route a
                    // restored request to the ordinary navigation boundary.
                    reconstructionTransientNotice = Self.reconstructionSourceNavigationRefusal(
                        for: .functionAuthorityMismatch
                    )
                    return
                case .refused:
                    reconstructionTransientNotice =
                        Self.reconstructionSourceNavigationRefusal(for: nil)
                    return
                case .notRequested:
                    break
                }
                reconstructionTransientNotice = Self.dispatchReconstructionSourceReveal(
                    currentRequest: {
                        Self.reconstructionSourceNavigationRequest(
                            evidenceID: evidenceID,
                            projection: reconstructionProjection,
                            workspaceID: store.workspaceID,
                            workspace: store.reconstructionState,
                            snapshot: store.snapshot
                        )
                    },
                    reveal: { try store.revealReconstructionSource($0) }
                )
            }
            return
        }
        reconstructionTransientNotice = Self.dispatchReconstructionSourceReveal(
            currentRequest: {
                Self.reconstructionSourceNavigationRequest(
                    evidenceID: evidenceID,
                    projection: reconstructionProjection,
                    workspaceID: store.workspaceID,
                    workspace: store.reconstructionState,
                    snapshot: store.snapshot
                )
            },
            reveal: { try store.revealReconstructionSource($0) }
        )
    }

    /// Re-resolves source authority at invocation time instead of retaining the request that made
    /// the rendered control eligible. This is the window-local TOCTOU fence: a retired corpus,
    /// analysis, or function coordinate produces only a bounded transient notice and never reaches
    /// the mutating Store navigation boundary.
    static func dispatchReconstructionSourceReveal(
        currentRequest: () -> ReconstructionSourceNavigationRequest?,
        reveal: (ReconstructionSourceNavigationRequest) throws -> Void
    ) -> ReconstructionDashboardTransientNotice? {
        guard let request = currentRequest() else {
            return reconstructionSourceNavigationRefusal(for: nil)
        }
        do {
            try reveal(request)
            return nil
        } catch {
            return reconstructionSourceNavigationRefusal(
                for: error as? ReconstructionSourceNavigationError
            )
        }
    }

    static func reconstructionSourceNavigationRefusal(
        for error: ReconstructionSourceNavigationError?
    ) -> ReconstructionDashboardTransientNotice {
        // Enumerate every current refusal without disclosing which mutable coordinate changed.
        // A caller outside the typed boundary receives the same bounded, fail-closed notice.
        switch error {
        case .workspaceMismatch, .workspaceStateInvalid, .projectUnavailable,
             .currentManifestUnavailable, .artifactOutsideCurrentManifest,
             .functionAuthorityMismatch, .addressUnavailable, nil:
            break
        }
        return ReconstructionDashboardTransientNotice(
            title: "Source reveal refused",
            detail: "Workspace, corpus, image, analysis, or function authority changed. "
                + "No source navigation was performed.",
            tone: .warning
        )
    }

    static func reconstructionSourceNavigationRequest(
        evidenceID: UUID,
        projection: ReconstructionStatusProjection,
        workspaceID: UUID,
        workspace: ReconstructionWorkspaceState,
        snapshot: WorkspaceSnapshot
    ) -> ReconstructionSourceNavigationRequest? {
        guard projection.evidenceSamples.contains(where: {
            $0.evidenceID == evidenceID && $0.sourceNavigationEligible
        }),
        let jobID = projection.jobID,
        let projectID = projection.projectID,
        let record = workspace.evidence.first(where: {
            $0.evidenceID == evidenceID
                && $0.creatingJobID == jobID
        }) else { return nil }
        return reconstructionSourceNavigationRequest(
            evidence: record,
            selectedJobID: jobID,
            projectID: projectID,
            workspaceID: workspaceID,
            workspace: workspace,
            snapshot: snapshot
        )
    }

    static func reconstructionSourceNavigationRequest(
        evidence: ReconstructionEvidenceRecord,
        selectedJobID: UUID,
        projectID: UUID,
        workspaceID: UUID,
        workspace: ReconstructionWorkspaceState,
        snapshot: WorkspaceSnapshot
    ) -> ReconstructionSourceNavigationRequest? {
        guard evidence.creatingJobID == selectedJobID,
              evidence.classification == .acceptedCurrent,
              case let .function(function) = evidence.subject else { return nil }
        let request = ReconstructionSourceNavigationRequest(
            workspaceID: workspaceID,
            projectID: projectID,
            function: function
        )
        guard (try? ReconstructionSourceNavigationAuthority.resolve(
            request: request,
            currentWorkspaceID: workspaceID,
            state: workspace,
            snapshot: snapshot
        )) != nil else { return nil }
        return request
    }

    static func makeDebuggerClient(
        runtimeAuthorities: DebuggerRuntimeAuthorities?
    ) -> LocalLLDBDebuggerClient {
        guard let runtimeAuthorities else {
            return LocalLLDBDebuggerClient()
        }
        return LocalLLDBDebuggerClient(
            debuggerRuntimeAuthorities: runtimeAuthorities
        )
    }

    /// Retires scripting authority only when the closing window still owns it. A sibling may
    /// already have become key before the close notification is delivered; that newer authority
    /// must remain untouched.
    static func retireScriptingAuthority(for store: WorkspaceStore) {
        guard ScriptingHost.shared.activeStore === store else { return }
        ScriptingHost.shared.activeStore = nil
    }

    // MARK: - WS-2 spawn-or-reuse

    /// The current window can be REUSED for an Open (rather than spawning a new window) only when
    /// it is an untitled, clean, empty document — i.e. the just-launched blank window. Opening a
    /// second document into a window that already holds one would silently discard the first.
    /// Also excludes a window with an import already IN FLIGHT (or its slice picker still open),
    /// so a second Open during an import spawns a fresh window instead of racing the first.
    private var canReuseCurrentWindowForOpen: Bool {
        store.documentURL == nil
            && !store.isDirty
            && store.snapshot.binaries.isEmpty
            && !store.isImporting
            && store.loaderOptionsRequest == nil
    }

    /// Opens a binary: in place when the current window is reusable, otherwise in a new window
    /// (routing the import there via the registry so the slice picker belongs to that document).
    // MARK: Open Binary importer presentation

    private var openBinaryImporterBinding: Binding<Bool> {
        Binding(
            get: { openBinaryImporterGate.isImporterPresented },
            set: { if !$0 { openBinaryImporterGate.importerDidDismiss() } }
        )
    }

    /// Any store-driven `DocumentAlerts` alert is pending or on screen.
    private var isDocumentAlertPending: Bool {
        store.saveError != nil || store.infoMessage != nil
            || store.debugSymbolsResultMessage != nil || store.debugSymbolsImportError != nil
    }

    private var openBinaryImporterContext: WorkspaceOpenBinaryImporterGate.Context {
        let window = windowActivator.window(for: windowID)
        let importerVisible = NSApp.windows.contains { candidate in
            candidate is NSOpenPanel && candidate.isVisible
                && (candidate.sheetParent == nil || candidate.sheetParent === window)
        }
        return .init(
            documentAlertPending: isDocumentAlertPending,
            windowHasSheet: window?.attachedSheet != nil,
            importerVisible: importerVisible
        )
    }

    private func requestOpenBinaryImporter() {
        applyOpenBinaryImporterDecision(openBinaryImporterGate.request(openBinaryImporterContext))
    }

    private func drainDeferredOpenBinaryImporter() {
        applyOpenBinaryImporterDecision(openBinaryImporterGate.drainDeferred(openBinaryImporterContext))
    }

    private func applyOpenBinaryImporterDecision(_ decision: WorkspaceOpenBinaryImporterGate.Decision) {
        switch decision {
        case .present, .deferredUntilAlertCloses, .none:
            break
        case .replayAfterReset:
            DispatchQueue.main.async { requestOpenBinaryImporter() }
        case .retryShortly:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drainDeferredOpenBinaryImporter() }
        case .alreadyVisible:
            let window = windowActivator.window(for: windowID)
            (window?.attachedSheet ?? NSApp.windows.first { $0 is NSOpenPanel && $0.isVisible })?
                .makeKeyAndOrderFront(nil)
        case .refused:
            NSSound.beep()
        }
    }

    private func openBinary(at url: URL) {
        if canReuseCurrentWindowForOpen {
            store.beginImport(url: url)
        } else {
            let id = WorkspaceWindowID.fresh()
            registry.setPendingBinaryOpen(url, for: id)
            openWindow(value: id)
        }
    }

    /// Presents an Open panel for a `.dSYM` bundle and imports its function-name debug
    /// symbols into the workspace. A `.dSYM` is a file package, so it is chosen as a file
    /// (`canChooseDirectories = false`) rather than browsed into; the dWARF-binary / bare-file
    /// case the service also accepts is reachable by enabling file selection. Result and
    /// failures surface through the store's dedicated dSYM alerts.
    private func presentReadDebugSymbolsPanelAndImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        // Accept the .dSYM bundle (treated as a file) and a bare DWARF Mach-O alike.
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        if let dsymType = UTType(filenameExtension: "dSYM") {
            panel.allowedContentTypes = [dsymType, .data]
        }
        panel.message = "Choose the .dSYM produced for the loaded binary."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importDebugSymbols(at: url)
    }

    private var functionCount: Int {
        store.focusedAnalysis?.functions.count ?? 0
    }

    private var instructionCount: Int {
        store.focusedAnalysis?.instructions.count ?? 0
    }
}

/// The persisted paths describe either a saved document or a loose binary, never both.
/// An empty startup store has no new identity to remember and must retain its scene state.
struct WorkspaceRestorationPolicy {
    var documentPath: String
    var binaryPath: String

    mutating func remember(documentPath: String?, binaryPath: String?) {
        if let documentPath, !documentPath.isEmpty {
            self.documentPath = documentPath
            self.binaryPath = ""
        } else if let binaryPath, !binaryPath.isEmpty {
            self.documentPath = ""
            self.binaryPath = binaryPath
        }
    }

    static func permitsAutomaticOpen(
        isCancelled: Bool,
        hasRequestedDocumentOpen: Bool,
        hasRequestedBinaryLoad: Bool
    ) -> Bool {
        !isCancelled && !hasRequestedDocumentOpen && !hasRequestedBinaryLoad
    }
}

/// Owns the complete package-document command surface for one window. Keeping this routing in a
/// focused modifier gives SwiftUI a bounded type-checking unit while preserving explicit,
/// window-scoped dependencies and one coordinator path for every open source.
private struct WorkspaceDocumentCommandHandlers: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var documentSession: WorkspaceDocumentSession
    let openCoordinator: WorkspaceOpenCoordinator
    let registry: WorkspaceSessionRegistry
    let windowID: WorkspaceWindowID
    let windowActivator: WorkspaceWindowActivator

    @Environment(\.openWindow) private var openWindow
    @State private var documentOpenError: String?
    @State private var isDocumentOpenErrorPresented = false
    @State private var hasRequestedDocumentOpen = false
    @State private var saveSheetPresenter = WorkspaceDocumentSaveSheetPresenter()
    @State private var savePanelError: String?
    @State private var isSavePanelErrorPresented = false
    /// Per-window restoration: what this window showed, so macOS window restoration after a
    /// relaunch reopens it. Scene storage follows the system "Close windows when quitting"
    /// setting, and is cleared when the window is closed rather than the app quit.
    @SceneStorage("macscope.restorable.document") private var restorableDocumentPath = ""
    @SceneStorage("macscope.restorable.binary") private var restorableBinaryPath = ""

    private static let workspacePackageType: UTType =
        UTType(MacScopeDocumentPackage.formatIdentifier)
        ?? UTType(
            filenameExtension: MacScopeDocumentPackage.fileExtension,
            conformingTo: .package
        )
        ?? .package

    private enum Command: Equatable {
        case openProject
        case openRecent
        case save
        case saveAs
        case saveCopy
        case reloadFromDisk
        case keepLocalVersion
        case openAutomation
    }

    private static var commandPublisher: AnyPublisher<(Command, Notification), Never> {
        let commands: [(Command, Notification.Name)] = [
            (.openProject, .macScopeOpenProject),
            (.openRecent, .macScopeOpenRecentDocument),
            (.save, .macScopeSave),
            (.saveAs, .macScopeSaveAs),
            (.saveCopy, .macScopeSaveCopy),
            (.reloadFromDisk, .macScopeReloadFromDisk),
            (.keepLocalVersion, .macScopeKeepLocalVersion),
            (.openAutomation, .macScopeOpenWorkspaceAutomation),
        ]
        return Publishers.MergeMany(
            commands.map { command, name in
                NotificationCenter.default.publisher(for: name)
                    .map { (command, $0) }
                    .eraseToAnyPublisher()
            }
        )
        .eraseToAnyPublisher()
    }

    func body(content: Content) -> some View {
        content
            .onReceive(Self.commandPublisher) { command, note in
                handle(command, notification: note)
            }
            .onChange(of: store.documentURL, initial: true) { _, _ in
                rememberRestorableBinary()
            }
            .onChange(of: store.snapshot.binaries.first?.path, initial: true) { _, _ in
                rememberRestorableBinary()
            }
            .task { await restoreIfNeeded() }
            .onOpenURL { url in
                guard isWorkspacePackage(url) else { return }
                routeOpen(
                    WorkspaceOpenRequest(
                        url: url,
                        source: .finder,
                        preferredReusableWindow: windowID
                    )
                )
            }
            .dropDestination(for: URL.self) { urls, _ in
                _ = acceptWorkspaceDrop(urls)
            }
            .alert(
                "Couldn’t Open Workspace",
                isPresented: $isDocumentOpenErrorPresented
            ) {
                Button("OK", role: .cancel) {
                    documentOpenError = nil
                    isDocumentOpenErrorPresented = false
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(documentOpenError ?? "The workspace could not be opened.")
            }
            .alert("Couldn’t Save Workspace", isPresented: $isSavePanelErrorPresented) {
                Button("OK", role: .cancel) {
                    savePanelError = nil
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(savePanelError ?? "The save dialog could not be presented. Try Save again.")
            }
    }

    private func handle(_ command: Command, notification: Notification) {
        if command == .openAutomation {
            let isUntargetedSingleWindow =
                notification.userInfo?[WorkspaceStore.commandTargetStoreKey] == nil
                    && registry.count == 1
            guard store.commandTargetsSelf(notification) || isUntargetedSingleWindow else {
                return
            }
        } else {
            guard store.commandTargetsSelf(notification) else { return }
        }

        switch command {
        case .openProject:
            presentOpenWorkspacePanel()
        case .openRecent:
            guard let url = notification.object as? URL else { return }
            routeOpen(
                WorkspaceOpenRequest(
                    url: url,
                    source: .recentMenu,
                    preferredReusableWindow: windowID
                )
            )
        case .save:
            save()
        case .saveAs:
            presentSavePanel(for: .saveAs)
        case .saveCopy:
            presentSavePanel(for: .saveCopy)
        case .reloadFromDisk:
            reloadDocumentFromDisk()
        case .keepLocalVersion:
            Task {
                handleDocumentWriteOutcome(
                    await documentSession.keepLocalVersion()
                )
            }
        case .openAutomation:
            guard let url = notification.object as? URL else { return }
            routeOpen(
                WorkspaceOpenRequest(
                    url: url,
                    source: .automation,
                    preferredReusableWindow: windowID
                )
            )
        }
    }

    /// A loose binary (no saved workspace) is remembered by path so it can be re-imported.
    private func rememberRestorableBinary() {
        var remembered = WorkspaceRestorationPolicy(
            documentPath: restorableDocumentPath,
            binaryPath: restorableBinaryPath
        )
        remembered.remember(
            documentPath: store.documentURL?.path(percentEncoded: false),
            binaryPath: store.snapshot.binaries.first?.path
        )
        restorableDocumentPath = remembered.documentPath
        restorableBinaryPath = remembered.binaryPath
    }

    /// Reopens this window's last workspace (or loose binary) after a relaunch. It runs only for
    /// a window that comes back empty, after a short settle so an explicit open (Finder,
    /// Shortcuts, a pending spawn) wins, and only if the file still exists.
    private func restoreIfNeeded() async {
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard canAutomaticallyRestore else { return }
        let fileManager = FileManager.default
        if !restorableDocumentPath.isEmpty, fileManager.fileExists(atPath: restorableDocumentPath) {
            await performOpen(
                WorkspaceOpenRequest(
                    url: URL(filePath: restorableDocumentPath),
                    source: .stateRestoration,
                    preferredReusableWindow: windowID
                )
            )
        } else if !restorableBinaryPath.isEmpty, fileManager.fileExists(atPath: restorableBinaryPath) {
            store.beginImport(url: URL(filePath: restorableBinaryPath))
        }
    }

    private var canAutomaticallyRestore: Bool {
        WorkspaceRestorationPolicy.permitsAutomaticOpen(
            isCancelled: Task.isCancelled,
            hasRequestedDocumentOpen: hasRequestedDocumentOpen,
            hasRequestedBinaryLoad: store.hasRequestedBinaryLoad
        )
            && registry.storeIfPresent(for: windowID) === store
            && store.documentURL == nil
            && store.snapshot.binaries.isEmpty
            && !store.isImporting
            && store.loaderOptionsRequest == nil
    }

    private enum SavePanelIntent {
        case saveAs
        case saveCopy
    }

    private func presentOpenWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.workspacePackageType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        routeOpen(
            WorkspaceOpenRequest(
                url: url,
                source: .fileMenu,
                preferredReusableWindow: windowID
            )
        )
    }

    private func acceptWorkspaceDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: isWorkspacePackage) else { return false }
        routeOpen(
            WorkspaceOpenRequest(
                url: url,
                source: .dragAndDrop,
                preferredReusableWindow: windowID
            )
        )
        return true
    }

    private func isWorkspacePackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased()
            == MacScopeDocumentPackage.fileExtension.lowercased()
    }

    private func routeOpen(_ request: WorkspaceOpenRequest) {
        // Record intent synchronously, before asynchronous package validation can suspend.
        if request.source != .stateRestoration { hasRequestedDocumentOpen = true }
        Task { @MainActor in
            await performOpen(request)
        }
    }

    private func performOpen(_ request: WorkspaceOpenRequest) async {
        guard !Task.isCancelled else { return }
        let disposition = await openCoordinator.open(request, shouldProceed: {
            request.source != .stateRestoration || canAutomaticallyRestore
        })
        guard !Task.isCancelled else { return }
        // Superseded automatic restoration is silent; the explicit open owns presentation.
        if request.source == .stateRestoration,
           disposition == .rejected("document-open-cancelled") { return }
        switch disposition {
        case .openedWindow(let id):
            openWindow(value: id)
        case .reusedWindow, .activatedExisting:
            break
        case .rejected(let reason):
            guard let message = WorkspaceOpenFailurePresentation.message(for: reason) else { return }
            documentOpenError = message
            isDocumentOpenErrorPresented = true
        }
    }

    private func save() {
        if documentSession.snapshot.location == nil {
            presentSavePanel(for: .saveAs)
            return
        }
        Task {
            handleDocumentWriteOutcome(await documentSession.save())
        }
    }

    private func presentSavePanel(for intent: SavePanelIntent) {
        guard !saveSheetPresenter.isPresenting else { return }
        guard let window = windowActivator.window(for: windowID),
              registry.storeIfPresent(for: windowID) === store,
              documentSession.snapshot.workspaceID == store.workspaceID,
              documentSession.snapshot.documentID == store.documentID else {
            reportSavePanelFailure("The workspace window is no longer available. Try Save from its current window.")
            return
        }
        guard window.attachedSheet == nil else {
            reportSavePanelFailure("Finish the current dialog in this workspace before saving.")
            return
        }
        let sessionID = documentSession.snapshot.sessionID
        let documentID = store.documentID
        let workspaceID = store.workspaceID
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.workspacePackageType]
        panel.canCreateDirectories = true
        let suffix: String
        switch intent {
        case .saveAs:
            suffix = ""
        case .saveCopy:
            suffix = " Copy"
        }
        panel.nameFieldStringValue =
            "\(store.workspaceName)\(suffix).\(MacScopeDocumentPackage.fileExtension)"
        let presented = saveSheetPresenter.present(panel, on: window) { [weak window] response in
            guard let window,
                  windowActivator.window(for: windowID) === window,
                  registry.storeIfPresent(for: windowID) === store,
                  documentSession.snapshot.sessionID == sessionID,
                  store.workspaceID == workspaceID,
                  documentSession.snapshot.workspaceID == workspaceID,
                  store.documentID == documentID,
                  documentSession.snapshot.documentID == documentID else { return }
            guard response != .cancel else { return }
            guard response == .OK, let url = panel.url else {
                reportSavePanelFailure("The save dialog stopped before a destination was selected. Try Save again.")
                return
            }
            Task { @MainActor in
                guard windowActivator.window(for: windowID) === window,
                      registry.storeIfPresent(for: windowID) === store,
                      documentSession.snapshot.sessionID == sessionID,
                      store.workspaceID == workspaceID,
                      documentSession.snapshot.workspaceID == workspaceID,
                      store.documentID == documentID,
                      documentSession.snapshot.documentID == documentID else { return }
                let outcome: WorkspaceDocumentWriteOutcome
                switch intent {
                case .saveAs:
                    outcome = await documentSession.saveAs(to: url)
                case .saveCopy:
                    outcome = await documentSession.saveCopy(to: url)
                }
                handleDocumentWriteOutcome(outcome)
            }
        }
        if !presented {
            reportSavePanelFailure("The save dialog could not be presented. Try Save again.")
        }
    }

    private func reportSavePanelFailure(_ message: String) {
        savePanelError = message
        isSavePanelErrorPresented = true
    }

    private func reloadDocumentFromDisk() {
        if documentSession.snapshot.hasUnsavedChanges {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Reload Workspace From Disk?"
            alert.informativeText = "This discards the unsaved changes in this window."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let documentID = store.documentID
        let workspaceID = store.workspaceID
        Task { @MainActor in
            let result = await documentSession.reloadFromDisk()
            switch result {
            case .success:
                store.saveError = nil
            case .failure(let error):
                guard store.documentID == documentID, store.workspaceID == workspaceID else { return }
                store.saveError = documentSessionErrorMessage(error)
            }
        }
    }

    private func handleDocumentWriteOutcome(
        _ outcome: WorkspaceDocumentWriteOutcome
    ) {
        WorkspaceDocumentWritePresentation.apply(outcome, to: store)
    }

    private func documentSessionErrorMessage(
        _ error: WorkspaceDocumentSessionError
    ) -> String {
        switch error {
        case .closed:
            return "The document window is closing."
        case .noActiveLocation:
            return "This workspace does not have a saved package location."
        case .writeAlreadyActive:
            return "A document operation is already in progress."
        case .unresolvedConflict:
            return "Resolve the package conflict before continuing."
        case .operationFailed("document-reload-newer-edits"):
            return "Reload was cancelled because this workspace changed while the package was being read. Your newer edits were kept."
        case .operationFailed("document-reload-identity-changed"):
            return "Reload was cancelled because a different workspace is now open."
        case .invalidResolution(let reason), .operationFailed(let reason):
            return documentOperationFailureMessage(reason)
        }
    }

    private func documentOperationFailureMessage(_ reason: String) -> String {
        WorkspaceDocumentWritePresentation.failureMessage(reason)
    }
}

/// Retains one sheet for one document command host. Completion identity prevents an old or
/// duplicate callback from releasing a newer panel; injected presentation permits focused
/// lifecycle tests without opening native dialogs.
@MainActor
final class WorkspaceDocumentSaveSheetPresenter {
    typealias BeginSheet = @MainActor (
        NSSavePanel,
        NSWindow,
        @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void

    private let beginSheet: BeginSheet
    private var activePanel: NSSavePanel?
    private var activeToken: UUID?

    var isPresenting: Bool { activePanel != nil }

    init(beginSheet: @escaping BeginSheet = { panel, window, completion in
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response) }
        }
    }) {
        self.beginSheet = beginSheet
    }

    @discardableResult
    func present(
        _ panel: NSSavePanel,
        on window: NSWindow,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Bool {
        guard activePanel == nil, window.attachedSheet == nil else { return false }
        let token = UUID()
        activeToken = token
        activePanel = panel
        beginSheet(panel, window) { [weak self] response in
            guard let self, self.activeToken == token else { return }
            self.activeToken = nil
            self.activePanel = nil
            completion(response)
        }
        return true
    }
}

/// Shared by menu writes and native close admission, which are owned by different view types.
@MainActor
private enum WorkspaceDocumentWritePresentation {
    static func apply(_ outcome: WorkspaceDocumentWriteOutcome, to store: WorkspaceStore) {
        switch outcome {
        case .saved, .copied: store.saveError = nil
        case .superseded: break
        case .conflicted(let conflict): store.saveError = conflictMessage(conflict.reason)
        case .destinationConflicted(let intent, let conflict):
            let operation: String
            switch intent {
            case .saveCopy: operation = "Save Copy"
            default: operation = "Save As"
            }
            let destinationState: String
            switch conflict.reason {
            case .externallyChanged: destinationState = "changed on disk"
            case .destinationMissing: destinationState = "is missing"
            case .destinationInvalid: destinationState = "is no longer valid"
            case .destinationUnverifiable: destinationState = "could not be verified"
            case .destinationOwnedByAnotherWindow: destinationState = "is open in another window"
            }
            store.saveError = "\(operation) could not write the selected destination because the destination \(destinationState). Choose another destination. The current workspace retains its original location and changes."
        case .failed(let reason): store.saveError = failureMessage(reason)
        }
    }

    private static func conflictMessage(_ reason: WorkspaceDocumentConflictReason) -> String {
        switch reason {
        case .externallyChanged, .destinationOwnedByAnotherWindow:
            return "The package changed on disk or is already open in another window. Resolve the conflict before saving."
        case .destinationMissing:
            return "The package is missing. Use Save As to choose a new destination."
        case .destinationInvalid:
            return "The package is no longer valid. Reload it or use Save As."
        case .destinationUnverifiable:
            return "The package state could not be verified, so MacScope will not overwrite it."
        }
    }

    static func failureMessage(_ reason: String) -> String {
        switch reason {
        case "document-save-copy-active-destination-use-save":
            return "Save Copy cannot replace the current workspace package. Use Save to update it, or choose another destination for the copy."
        case "document-conflict-unresolved":
            return "Resolve the package conflict before saving."
        case "document-location-unavailable":
            return "Use Save As to choose a package location."
        case "document-write-already-active":
            return "A document write is already in progress."
        case "document-close-in-progress":
            return "Finish or cancel the close request before starting another document operation."
        case "document-close-content-changed":
            return "The workspace changed while closing. Your changes are retained; close again when ready."
        case "document-close-analysis-in-progress":
            return "Finish or cancel the current import or analysis before closing this window."
        case "document-close-wait-timed-out":
            return "A document operation is still running. The window remains open; try closing again after it finishes."
        case "package-state-unverifiable":
            return "The package state could not be verified, so MacScope will not overwrite it."
        default:
            // Display only bounded code tokens, never recovery filenames or arbitrary error text.
            let safeReason = reason.utf8.count <= 128 && reason.hasPrefix("document-")
                && reason.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
                }
            return safeReason
                ? "The document operation could not be completed. Reason: \(reason)."
                : "The document operation could not be completed."
        }
    }

}

/// Bridges the store's `isDirty` flag onto the hosting `NSWindow`'s
/// `isDocumentEdited`, so unsaved edits show the standard close-button dot and the
/// "— Edited" title — the native macOS document-dirty indicator. A zero-size,
/// non-drawing helper that simply reaches the window from the view hierarchy.
private struct WindowDocumentEditedReader: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let edited = isEdited
        DispatchQueue.main.async {
            nsView.window?.isDocumentEdited = edited
        }
    }
}

/// Bridges each document window's AppKit lifecycle into WS-2 (mirrors `WindowDocumentEditedReader`'s
/// window-access pattern): (1) when the window becomes KEY it claims `ScriptingHost.activeStore`,
/// so an Apple event / MCP command targets the FRONT document; (2) when the window CLOSES it runs
/// `onClose`, which evicts this window's store from the session registry so closed documents don't
/// accumulate (and a reopened window id resolves a fresh store, not a stale one).
private struct WindowLifecycleReader: NSViewRepresentable {
    let store: WorkspaceStore
    let documentSession: WorkspaceDocumentSession
    let registry: WorkspaceSessionRegistry
    let windowID: WorkspaceWindowID
    let windowActivator: WorkspaceWindowActivator
    let onWriteOutcome: @MainActor @Sendable (WorkspaceDocumentWriteOutcome) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> LifecycleObservingNSView {
        let view = LifecycleObservingNSView(frame: .zero)
        view.store = store
        view.windowID = windowID
        view.windowActivator = windowActivator
        view.onClose = onClose
        configureCloseHandling(view)
        return view
    }

    func updateNSView(_ nsView: LifecycleObservingNSView, context: Context) {
        nsView.store = store
        nsView.configureWindowIdentity(
            windowID,
            activator: windowActivator
        )
        nsView.onClose = onClose
        configureCloseHandling(nsView)
        // Claim active immediately if this view's window is already key (e.g. a spawned window
        // that is front on first layout).
        if nsView.window?.isKeyWindow == true {
            ScriptingHost.shared.activeStore = store
        }
    }

    private func configureCloseHandling(_ view: LifecycleObservingNSView) {
        let ownerID = windowID
        if view.closeDelegate?.documentSession !== documentSession {
            view.closeDelegate?.detach()
            view.closeDelegate = WorkspaceWindowCloseDelegate(documentSession: documentSession)
        }
        view.closeDelegate?.workspaceName = store.workspaceName
        view.closeDelegate?.isCurrent = { [weak store, weak documentSession, weak registry] in
            guard let store, let documentSession, let registry else { return false }
            return registry.storeIfPresent(for: ownerID) === store
                && registry.documentSessionIfPresent(for: ownerID) === documentSession
        }
        view.closeDelegate?.drain = { [weak store] in
            guard let store else { return false }
            await store.awaitPendingImport()
            await store.awaitPendingReanalysis()
            await store.awaitPendingDyldCacheDifferential()
            await store.phase2ShellRecoveryTask?.value
            return !store.isImporting && !store.isReanalyzing && store.loaderOptionsRequest == nil
        }
        view.closeDelegate?.canCommit = { [weak store] in
            guard let store else { return false }
            return !store.isImporting && !store.isReanalyzing && store.loaderOptionsRequest == nil
        }
        view.closeDelegate?.onWriteOutcome = onWriteOutcome
        if let window = view.window { view.closeDelegate?.attach(to: window) }
    }

    static func dismantleNSView(_ nsView: LifecycleObservingNSView, coordinator: ()) {
        nsView.closeDelegate?.detach()
    }

    final class LifecycleObservingNSView: NSView {
        weak var store: WorkspaceStore?
        var windowID: WorkspaceWindowID = .primary
        weak var windowActivator: WorkspaceWindowActivator?
        weak var registeredWindow: NSWindow?
        var onClose: () -> Void = {}
        var closeDelegate: WorkspaceWindowCloseDelegate?
        // `removeObserver` is thread-safe, so releasing the tokens from the nonisolated deinit is
        // sound; the annotation just opts out of the Sendable check for those accesses.
        private nonisolated(unsafe) var keyObserver: NSObjectProtocol?
        private nonisolated(unsafe) var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            unregisterWindow()
            removeObservers()
            guard let window else { return }
            registeredWindow = window
            windowActivator?.register(window, for: windowID)
            closeDelegate?.attach(to: window)
            if window.isKeyWindow { claimActive() }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimActive() }
            }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unregisterWindow()
                    if let store = self.store {
                        WorkspaceRootView.retireScriptingAuthority(for: store)
                    }
                    self.onClose()
                }
            }
        }

        func configureWindowIdentity(
            _ windowID: WorkspaceWindowID,
            activator: WorkspaceWindowActivator
        ) {
            if self.windowID != windowID || windowActivator !== activator {
                unregisterWindow()
                self.windowID = windowID
                windowActivator = activator
                if let window {
                    registeredWindow = window
                    activator.register(window, for: windowID)
                }
            }
        }

        private func claimActive() {
            if let window { closeDelegate?.attach(to: window) }
            if let store { ScriptingHost.shared.activeStore = store }
        }

        private func unregisterWindow() {
            closeDelegate?.detach()
            guard let registeredWindow else { return }
            windowActivator?.unregister(windowID, window: registeredWindow)
            self.registeredWindow = nil
        }

        private func removeObservers() {
            keyObserver.map(NotificationCenter.default.removeObserver)
            closeObserver.map(NotificationCenter.default.removeObserver)
            keyObserver = nil
            closeObserver = nil
        }

        deinit {
            keyObserver.map(NotificationCenter.default.removeObserver)
            closeObserver.map(NotificationCenter.default.removeObserver)
        }
    }
}

/// Adds pre-close admission without replacing SwiftUI's other NSWindowDelegate behavior.
/// The reader retains this proxy because NSWindow.delegate is weak. It is reattached at native
/// window attachment, SwiftUI update and key-window activation, preserving any replacement
/// delegate at each attachment. No global method swizzling or application-wide Quit routing.
@MainActor
final class WorkspaceWindowCloseDelegate: NSObject, NSWindowDelegate {
    let documentSession: WorkspaceDocumentSession
    var workspaceName = "Workspace"
    var isCurrent: @MainActor () -> Bool = { false }
    var canCommit: @MainActor () -> Bool = { true }
    var drain: @MainActor () async -> Bool = { true }
    var onWriteOutcome: @MainActor (WorkspaceDocumentWriteOutcome) -> Void = { _ in }
    /// Injection seams exercise the real native delegate transaction without displaying sheets
    /// in CoreTests. Production leaves both nil and uses the window-bound AppKit sheets below.
    var choose: (@MainActor (NSWindow, WorkspaceDocumentSessionSnapshot) async -> WorkspaceDocumentWindowCloseChoice)?
    var chooseSaveDestination: (@MainActor (NSWindow) async -> URL?)?

    private weak var window: NSWindow?
    // Objective-C asks these two NSObject forwarding hooks outside Swift actor checking.
    // Delegate ownership changes only on AppKit's main actor; the weak reference preserves
    // SwiftUI's ownership rather than introducing a window/delegate retention cycle.
    private nonisolated(unsafe) weak var previousDelegate: (any NSWindowDelegate)?
    private var closeTask: Task<Void, Never>?
    private var activeRequest: WorkspaceDocumentWindowCloseRequest?
    private var nativePermit: WorkspaceDocumentWindowClosePermit?
    private var activeSheet: NSWindow?
    private var observedClose = false
    private var replayFailure: WorkspaceDocumentWriteOutcome?

    init(documentSession: WorkspaceDocumentSession) {
        self.documentSession = documentSession
        super.init()
    }

    func attach(to window: NSWindow) {
        if self.window !== window {
            detach()
            self.window = window
            observedClose = false
        }
        guard window.delegate !== self else { return }
        previousDelegate = window.delegate
        window.delegate = self
    }

    func detach() {
        let request = activeRequest
        activeRequest = nil
        nativePermit = nil
        closeTask?.cancel()
        closeTask = nil
        if let request, !observedClose {
            documentSession.cancelWindowClosePreparation(request)
        }
        if let sheet = activeSheet, let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .cancel)
        }
        activeSheet = nil
        if let window, window.delegate === self, !observedClose {
            window.delegate = previousDelegate
        }
        window = nil
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to: selector) == true { return previousDelegate }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard window === sender else { return false }
        // AppKit does not call windowShouldClose for Quit. A closed old session is therefore
        // never permission to close a window now owned by a replacement session.
        guard !documentSession.isClosedForWindowClose, isCurrent() else { return false }
        if let permit = nativePermit {
            nativePermit = nil
            // Consult the original delegate exactly once, at the actual close boundary. Its
            // synchronous callback may mutate content; consume rechecks generation afterward.
            guard previousDelegate?.windowShouldClose?(sender) ?? true, isCurrent() else { return false }
            guard canCommit() else {
                replayFailure = .failed("document-close-analysis-in-progress")
                return false
            }
            guard documentSession.consumeWindowClosePermit(permit) else {
                replayFailure = .failed("document-close-content-changed")
                return false
            }
            return true
        }
        guard closeTask == nil, sender.attachedSheet == nil, isCurrent(),
              let request = documentSession.beginWindowClosePreparation() else { return false }
        activeRequest = request
        replayFailure = nil
        closeTask = Task { @MainActor [weak self] in
            guard let self, let targetWindow = self.window else { return }
            let outcome = await self.documentSession.prepareForWindowClose(
                request,
                isCurrent: { [weak self, weak targetWindow] in
                    guard let self, let targetWindow else { return false }
                    return self.activeRequest == request && self.window === targetWindow
                        && targetWindow.delegate === self && self.isCurrent()
                },
                drain: self.drain,
                choose: { [weak self, weak targetWindow] snapshot in
                    guard let self, let targetWindow else { return .cancel }
                    if let choose = self.choose { return await choose(targetWindow, snapshot) }
                    return await self.presentChoice(on: targetWindow)
                },
                chooseSaveDestination: { [weak self, weak targetWindow] in
                    guard let self, let targetWindow else { return nil }
                    if let choose = self.chooseSaveDestination { return await choose(targetWindow) }
                    return await self.presentSaveDestination(on: targetWindow)
                }
            )
            guard self.activeRequest == request else { return }
            if case .admitted(let permit) = outcome,
               !Task.isCancelled, self.window === targetWindow,
               targetWindow.delegate === self, self.isCurrent(), self.canCommit() {
                self.nativePermit = permit
                // performClose invokes this delegate again. Only the one exact permit can pass;
                // an ordinary repeated Command-W while a sheet/save is pending cannot pass.
                targetWindow.performClose(nil)
                if let failure = self.replayFailure, self.isCurrent() {
                    self.onWriteOutcome(failure)
                }
            } else if case .refused(let failure) = outcome, self.isCurrent() {
                self.onWriteOutcome(failure)
            } else if case .admitted = outcome, self.isCurrent(), !Task.isCancelled {
                self.onWriteOutcome(.failed("document-close-analysis-in-progress"))
            }
            // A native veto or another change between preparation and replay leaves a live
            // window. Roll back the fence even when AppKit declines to call should-close again.
            if self.activeRequest == request {
                self.activeRequest = nil
                self.nativePermit = nil
                self.closeTask = nil
                self.documentSession.cancelWindowClosePreparation(request)
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        observedClose = true
        activeRequest = nil
        nativePermit = nil
        closeTask?.cancel()
        closeTask = nil
        previousDelegate?.windowWillClose?(notification)
        // Existing WindowLifecycleReader willClose notification performs exact-session eviction.
    }

    func awaitPendingClose() async { await closeTask?.value }

    private func presentChoice(on window: NSWindow) async -> WorkspaceDocumentWindowCloseChoice {
        guard window.attachedSheet == nil else { return .cancel }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(workspaceName)\" before closing?"
        alert.informativeText = "Your changes will be lost if you close without saving."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        activeSheet = alert.window
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    self?.activeSheet = nil
                    switch response {
                    case .alertFirstButtonReturn: continuation.resume(returning: .save)
                    case .alertThirdButtonReturn: continuation.resume(returning: .discard)
                    default: continuation.resume(returning: .cancel)
                    }
                }
            }
        }
    }

    private func presentSaveDestination(on window: NSWindow) async -> URL? {
        guard window.attachedSheet == nil else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(MacScopeDocumentPackage.formatIdentifier)
                ?? UTType(filenameExtension: MacScopeDocumentPackage.fileExtension, conformingTo: .package)
                ?? .package
        ]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(workspaceName).\(MacScopeDocumentPackage.fileExtension)"
        activeSheet = panel
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    self?.activeSheet = nil
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }
}

/// Tokens for the single, unified document-window command surface. They live with the app-owned
/// surface rather than being inferred from a platform titlebar so compact chrome remains stable
/// while the standard traffic lights keep their reserved leading space.
enum AppWindowChrome {
    static let commandBarHeight: CGFloat = 46
    static let trafficLightClearance: CGFloat = 88
    static let minimumDragRegionWidth: CGFloat = 36
}

/// The compact workspace toolbar uses the same public composition as Lumen's rehearsal.
private struct WorkspaceTopBar: View {
    /// Import progress and re-analysis share the window's temporary status item.
    static func toolbarActivity(for store: WorkspaceStore) -> LumenActivity? {
        if store.isImporting {
            return .working("Indexing", progress: AnalysisProgressPresentation(store.analysisProgress).fraction)
        }
        return store.isReanalyzing ? .working("Re-analyzing") : nil
    }

    @ObservedObject var store: WorkspaceStore
    let documentDisplayName: String
    let requestOpenBinary: () -> Void
    @Binding var isAssistantPresented: Bool
    @State private var isLauncherPresented = false
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        LumenWorkspaceToolbar {
            Button { isLauncherPresented = true } label: {
                LumenIconTile("cpu", hue: .huePink, size: metrics.layout.tileRow)
            }
            .buttonStyle(.lumenPlain)
            .help("MacScope actions")
            .lumenLaunchMenu(isPresented: $isLauncherPresented, items: launchItems)
        } project: {
            LumenToolbarIdentity(store.focusedBinary?.name ?? documentDisplayName,
                                 subtitle: store.focusedBinary.map { "\($0.architecture) · \($0.kind)" },
                                 systemImage: "lumen.binaryFile", hue: .hueIndigo)
        } tasks: {
            LumenTaskCluster([
                LumenTaskAction("Analyze", systemImage: "hammer.fill", hue: .hueOrange) {
                    store.reanalyzeHonoringOverrides()
                },
            ], activity: Self.toolbarActivity(for: store) ?? .idle())
            .disabled(store.focusedBinary == nil || store.isImporting || store.isReanalyzing)
        }
    }

    private var launchItems: [LumenLaunchItem] {
        var items = [
            LumenLaunchItem("Open Binary…", systemImage: "folder.badge.plus", hue: .hueIndigo,
                            perform: requestOpenBinary),
            LumenLaunchItem("Ask MacScope", systemImage: "sparkles", hue: .huePink) {
                isAssistantPresented = true
            },
            LumenLaunchItem("Go to address", systemImage: "location", hue: .hueOrange) {
                store.searchSheetPresentation = .goToAddress
                store.showGoTo = true
            },
            LumenLaunchItem("Imports, exports, and sections", systemImage: "tablecells", hue: .hueTeal) {
                store.showBrowsers = true
            },
        ]
        if store.isImporting {
            items.append(LumenLaunchItem("Cancel import", systemImage: "xmark", hue: .hueRed) {
                store.cancelImport()
            })
        }
        return items
    }
}

private struct WorkspaceTopBarCenter: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        LumenToolbarStatus(WorkspaceTopBar.toolbarActivity(for: store))
    }
}

/// Modes and navigation belong to the editor surface; Reconstruction retains its own title.
private struct WorkspaceContentTabBar: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        LumenContentTabBar {
            if store.selectedTool == .reconstruction {
                Label("Reconstruction", systemImage: store.selectedTool.systemImage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lumenNeverTruncates("Reconstruction")
                    .accessibilityAddTraits(.isHeader)
            } else {
                ToolbarModeSwitcher(selection: $store.editorMode)
            }
        } trailing: {
            LumenToolbarGroup {
                TopBarButton(systemImage: "chevron.backward", help: "Back (⌘[)", isEnabled: store.canNavigateBack, action: store.navigateBack)
                TopBarButton(systemImage: "chevron.forward", help: "Forward (⌘])", isEnabled: store.canNavigateForward, action: store.navigateForward)
            }
        }
    }
}

private struct TopBarButton: View {
    let systemImage: String
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(LumenToolbarIconButtonStyle())
        // No own dimming: every icon button sits in a LumenToolbarGroup, which dims once.
        .help(help)
        .accessibilityLabel(help)
        .disabled(!isEnabled)
    }
}

private struct ToolbarModeSwitcher: View {
    @Binding var selection: EditorMode

    var body: some View {
        // Lumen adapts the underline modes to the editor content width.
        modePicker
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
        .accessibilityValue(selection.rawValue)
    }

    private var modePicker: some View {
        LumenModeSwitcher(selection: $selection, options: EditorMode.allCases, style: .underline,
                          title: \.rawValue, systemImage: \.systemImage, hue: \.modeHue)
            .help("Editor mode")
    }
}

extension EditorMode {
    /// Each mode's tile color in the editor-mode switcher.
    var modeHue: LumenToken {
        switch self {
        case .disassembly: .hueIndigo
        case .pseudocode: .huePink
        case .graph: .hueTeal
        case .hex: .hueOrange
        }
    }
}

/// Modal editor for a single rename or comment override. Pre-fills the current
/// value, commits on Save/Return (empty clears the override), cancels on Escape.
struct OverrideEditorSheet: View {
    let request: OverrideEditorRequest
    @ObservedObject var store: WorkspaceStore
    @State private var text: String

    init(request: OverrideEditorRequest, store: WorkspaceStore) {
        self.request = request
        self.store = store
        _text = State(initialValue: request.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text(request.title)
                .font(.headline)
                .lumenNeverTruncates(request.title)
            Text("At \(request.address.hexAddress)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(request.fieldPrompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .dsInitialTextEntryFocus()
                .accessibilityIdentifier("overrideEditorInput")
                .onSubmit { store.commitOverrideEditor(request, text: text) }

            HStack {
                Spacer()
                Button("Cancel") { store.cancelOverrideEditor(request) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { store.commitOverrideEditor(request, text: text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 360)
    }
}

struct SignatureEditorDeclaredEmptyState: Equatable {
    var text: String
    var accessibilityLabel: String
}

enum SignatureEditorPresentation {
    static let parameterSourceAccessibilityHint =
        "Use Recovered keeps the named-parameter list analysis-owned. Declare Parameters saves the visible rows in source order."

    static func declaredEmptyState(
        for variadicState: FunctionSignatureOverride.VariadicState
    ) -> SignatureEditorDeclaredEmptyState {
        if variadicState == .variadic {
            return SignatureEditorDeclaredEmptyState(
                text: "… — no named parameters; accepts trailing arguments",
                accessibilityLabel: "No named parameters. This signature accepts trailing variadic arguments."
            )
        }
        return SignatureEditorDeclaredEmptyState(
            text: "void — explicitly declares no parameters",
            accessibilityLabel: "Void. This signature explicitly declares no parameters."
        )
    }
}

/// Modal editor for a function signature: return type, no-return flag, and an
/// editable, reorderable list of arguments (type + name). Commits the whole edit
/// as one undoable override on Save; empty clears it.
struct SignatureEditorSheet: View {
    @ObservedObject var store: WorkspaceStore
    var inferenceCoordinator: (any Phase2AssistantInferenceCoordinating)? = nil
    @State private var draft: SignatureEditorRequest
    @State private var hasAdoptedLegacyOrder = false
    @State private var recoveredSelection: ArgDraft.ID?
    private let openingQuarantinedLegacyArgs: [LegacyArgOverride]

    private enum ParameterMode: Int {
        case recovered
        case declared
    }

    init(request: SignatureEditorRequest, store: WorkspaceStore,
         inferenceCoordinator: (any Phase2AssistantInferenceCoordinating)? = nil) {
        self.store = store
        self.inferenceCoordinator = inferenceCoordinator
        openingQuarantinedLegacyArgs = request.quarantinedLegacyArgs
        _draft = State(initialValue: request)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Edit Signature")
                .font(.headline)
                .lumenNeverTruncates("Edit Signature")
            Text("\(draft.functionName) at \(draft.address.hexAddress)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Lumen.Space.s5) {
                Text("Returns")
                    .frame(width: 64, alignment: .leading)
                TextField("return type", text: $draft.returnType)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("No-return", selection: $draft.noReturnState) {
                Text("Preserve recovered state").tag(FunctionSignatureOverride.NoReturnState.unspecified)
                Text("Returns").tag(FunctionSignatureOverride.NoReturnState.returns)
                Text("Does not return").tag(FunctionSignatureOverride.NoReturnState.noReturn)
            }

            if ownerAmbiguityEvidence != nil || !presentedCandidates.isEmpty {
                objcCandidateSection
            }

            parameterEditor

            HStack {
                Button("Clear Override", role: .destructive) {
                    store.clearSignatureEditorOverride(draft)
                }
                .disabled(!hasPersistedSignatureOverride)
                .help(
                    hasPersistedSignatureOverride
                        ? "Remove this saved signature override and return the function to recovered signature information. This action can be undone."
                        : "There is no saved signature override to clear."
                )
                .accessibilityLabel("Clear signature override")
                .accessibilityHint("Removes the saved override and returns to recovered signature information. This action can be undone.")
                Spacer()
                Button("Cancel") { store.cancelSignatureEditor(draft) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { store.commitSignatureEditor(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 520)
    }

    private var hasPersistedSignatureOverride: Bool {
        store.snapshot.addressOverrides[
            ImageAddress(slot: draft.imageSlot, address: draft.address)
        ]?.signature != nil
    }

    private var presentedCandidates: [ObjCSignatureCandidate] {
        guard let request = store.signatureEditorRequest,
              request.hasSameOpeningPresentation(as: draft),
              ownerAmbiguityEvidence == nil else { return [] }
        return request.objcCandidates
    }

    private var ownerAmbiguityEvidence: ObjCSignatureCandidate.Evidence? {
        guard let request = store.signatureEditorRequest,
              request.hasSameOpeningPresentation(as: draft) else { return nil }
        return store.objcMethod(at: draft.address, in: draft.imageSlot).ambiguityEvidence
    }

    private var objcCandidateSection: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("Objective-C Signature Candidate")
                .font(.subheadline.weight(.semibold))
            Text("Evidence stays provisional until you apply a valid candidate and save this editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Image \(draft.imageSlot.rawValue) · \(store.objcCandidateSliceLabel(in: draft.imageSlot))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let evidence = ownerAmbiguityEvidence {
                candidateEvidenceRow(evidence)
            }
            ForEach(presentedCandidates) { candidate in
                VStack(alignment: .leading, spacing: Lumen.Space.s3) {
                    HStack {
                        Text(candidate.displayName)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                        Spacer()
                        Button("Apply to Draft") {
                            store.applyObjCSignatureCandidate(candidate, to: &draft)
                        }
                        .disabled(!candidate.canAccept)
                    }

                    Text(candidate.hypothesisState.label)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(candidate.evidence) { evidence in
                        candidateEvidenceRow(evidence)
                    }
                    candidateField("Returns", candidate.returnField)
                    ForEach(candidate.parameters) { parameter in
                        candidateField(
                            "Argument \(parameter.index + 1) · \(parameter.name)",
                            parameter.field
                        )
                    }
                    ForEach(candidate.diagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: diagnosticIcon(diagnostic.severity))
                            .font(.caption)
                            .foregroundStyle(
                                diagnostic.severity == .error
                                    ? Color.lumen(.statusDanger)
                                    : Color.secondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Lumen.Space.s4)
                .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.xs))
            }
        }
        .task { store.startObjCSignatureInference(coordinator: inferenceCoordinator) }
        .onDisappear { store.cancelObjCSignatureInference() }
    }

    private func candidateEvidenceRow(_ evidence: ObjCSignatureCandidate.Evidence) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            Text("\(evidence.kind) · \(evidence.source)")
                .font(.caption.weight(.semibold))
            Text(evidence.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func candidateField(
        _ label: String,
        _ field: ObjCSignatureCandidate.Field
    ) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .frame(width: 132, alignment: .leading)
                Text(field.type ?? "Unknown")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text(field.source?.rawValue ?? "No evidence")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(field.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func diagnosticIcon(
        _ severity: ObjCSignatureCandidate.DiagnosticSeverity
    ) -> String {
        switch severity {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var parameterModeSelection: Binding<Int> {
        Binding(
            get: {
                draft.parameterListIntent == .inherited
                    ? ParameterMode.recovered.rawValue
                    : ParameterMode.declared.rawValue
            },
            set: { newValue in
                if newValue == ParameterMode.recovered.rawValue {
                    draft.parameterListIntent = .inherited
                    // Adoption is not committed until Save. If the user returns to
                    // recovery first, retain the original inert quarantine rather
                    // than silently discarding migration evidence.
                    if hasAdoptedLegacyOrder {
                        draft.quarantinedLegacyArgs = openingQuarantinedLegacyArgs
                    }
                } else {
                    draft.parameterListIntent = .authoritative
                    if hasAdoptedLegacyOrder {
                        draft.quarantinedLegacyArgs = []
                    }
                }
            }
        )
    }

    private var variadicStateSelection: Binding<String> {
        Binding(
            get: { draft.variadicState.rawValue },
            set: { newValue in
                guard let state = FunctionSignatureOverride.VariadicState(rawValue: newValue) else {
                    return
                }
                draft.variadicState = state
            }
        )
    }

    @ViewBuilder
    private var parameterEditor: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Parameters")
                .font(.subheadline.weight(.semibold))

            declaratorEditor

            if !draft.quarantinedLegacyArgs.isEmpty {
                legacyQuarantineNotice
            }

            // U9-4c: the parameter source as Lumen radios; the chosen option owns its editor (the
            // recovered preview or the declared list) as its detail.
            LumenRadioGroup(
                selection: parameterModeSelection,
                options: [ParameterMode.recovered.rawValue, ParameterMode.declared.rawValue],
                title: { $0 == ParameterMode.recovered.rawValue ? "Use Recovered Parameters" : "Declare Parameters" }
            ) { option in
                if option == parameterModeSelection.wrappedValue {
                    VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                        if option == ParameterMode.recovered.rawValue {
                            recoveredParameters
                        } else {
                            declaredParameters
                        }
                    }
                }
            }
            .accessibilityLabel("Parameter source")
            .accessibilityHint(SignatureEditorPresentation.parameterSourceAccessibilityHint)
            .help("Choose whether analysis recovers the parameter list or this signature declares it explicitly. Authored rows remain available if you switch modes before saving.")
            .accessibilityIdentifier("signature.parameterSource")
        }
    }

    private var legacyQuarantineNotice: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Label("Legacy parameter order needs review", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
            Text("\(draft.quarantinedLegacyArgs.count) legacy parameter row\(draft.quarantinedLegacyArgs.count == 1 ? "" : "s") \(draft.quarantinedLegacyArgs.count == 1 ? "is" : "are") excluded because the original identity and order could not be proven.")
                .font(.caption)
                .foregroundStyle(.lumen(.fgSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Button("Adopt Legacy Order") {
                draft.adoptQuarantinedLegacyArguments()
                hasAdoptedLegacyOrder = true
            }
            .help("Create an explicit declaration using the legacy rows in their stored order.")
            .accessibilityHint("Makes the quarantined rows the active declared parameter list")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Lumen.Space.s5)
        // A warning, so the warning surface (fg.secondary on it is a validated pair).
        .background(
            Color.lumen(.statusWarningBackground),
            in: RoundedRectangle(cornerRadius: Lumen.Radius.xs)
        )
    }

    /// U9-4c: the declarator as Lumen radios, each with its explanation as detail.
    private var declaratorEditor: some View {
        LumenRadioGroup(
            selection: variadicStateSelection,
            options: [FunctionSignatureOverride.VariadicState.unspecified, .fixed, .variadic].map(\.rawValue),
            title: { raw in
                switch FunctionSignatureOverride.VariadicState(rawValue: raw) {
                case .fixed: "Fixed"
                case .variadic: "Variadic (…)"
                default: "Unspecified"
                }
            }
        ) { raw in
            Text(Self.variadicStateExplanation(FunctionSignatureOverride.VariadicState(rawValue: raw) ?? .unspecified))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel("Parameter declarator")
        .accessibilityHint(variadicStateExplanation)
        .help(variadicStateExplanation)
        .accessibilityIdentifier("signature.declarator")
    }

    private var variadicStateExplanation: String {
        Self.variadicStateExplanation(draft.variadicState)
    }

    private static func variadicStateExplanation(_ state: FunctionSignatureOverride.VariadicState) -> String {
        switch state {
        case .unspecified:
            "Do not override whether the recovered declaration accepts trailing arguments."
        case .fixed:
            "Explicitly declare only the named parameters."
        case .variadic:
            "Explicitly append an unbound … after the named parameters."
        }
    }

    @ViewBuilder
    private var recoveredParameters: some View {
        if draft.originalParameterListIntent == .authoritative {
            Text("The authored parameter declaration will be removed. MacScope will recover parameters after you save.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Use recovered parameters. The authored parameter declaration will be removed after saving.")
        }

        if draft.recoveredArgs.isEmpty {
            Text("No parameters are currently recovered. Saving in this mode leaves the parameter list unspecified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("No parameters are currently recovered. The parameter list remains unspecified.")
        } else {
            Text("Recovered preview. These rows remain analysis-owned and are not stored as a declaration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // U8-5c: a Lumen table with Type and Name headers (read-only preview).
            LumenTable(draft.recoveredArgs, selection: $recoveredSelection, minHeight: 100, columns: [
                .text("Type", monospaced: true) { $0.type },
                LumenTableColumn("Name") { arg in
                    Text(arg.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                },
            ])
            .frame(maxHeight: 180)
            .accessibilityLabel("Recovered parameter preview")
            .accessibilityIdentifier("signature.recoveredParameters")
        }
    }

    @ViewBuilder
    private var declaredParameters: some View {
        HStack {
            if !draft.args.isEmpty {
                Text("Array order is source order. Drag rows to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let nextIndex = (draft.args.map(\.index).max() ?? -1) + 1
                draft.args.append(ArgDraft(index: nextIndex, name: "", type: "int64_t"))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Append a parameter to the declaration")
            .accessibilityHint("Adds a new parameter at the end of the source-order list")
        }

        if draft.args.isEmpty {
            let state = SignatureEditorPresentation.declaredEmptyState(
                for: draft.variadicState
            )
            Text(state.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Lumen.Space.s5)
                .accessibilityLabel(state.accessibilityLabel)
        } else {
            List {
                ForEach($draft.args) { $arg in
                    let position = parameterPosition(for: arg.id)
                    HStack(spacing: Lumen.Space.s5) {
                        TextField("type", text: $arg.type)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Parameter \(position) type")
                            .help("Type for source-order parameter \(position)")
                        TextField("name", text: $arg.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Parameter \(position) name")
                            .help("Name for source-order parameter \(position)")
                    }
                }
                .onDelete { draft.args.remove(atOffsets: $0) }
                .onMove { source, destination in
                    draft.args.move(fromOffsets: source, toOffset: destination)
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
            .accessibilityLabel("Declared parameters in source order")
        }
    }

    private func parameterPosition(for id: UUID) -> Int {
        (draft.args.firstIndex { $0.id == id } ?? 0) + 1
    }
}

/// Modal editor for a manual jump-table (switch) declaration on the dispatching
/// `br`. Captures the table base, case count, entry stride, and relativity; saving
/// resolves the targets and feeds the pseudocode `switch` reconstruction. A blank
/// or zero case count removes the hint.
struct SwitchHintEditorSheet: View {
    @ObservedObject var store: WorkspaceStore
    @State private var draft: SwitchHintEditorRequest

    init(request: SwitchHintEditorRequest, store: WorkspaceStore) {
        self.store = store
        _draft = State(initialValue: request)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Define Switch Hint")
                .font(.headline)
                .lumenNeverTruncates("Define Switch Hint")
            Text("Dispatch at \(draft.address.hexAddress)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Lumen.Space.s5) {
                Text("Table base")
                    .frame(width: 90, alignment: .leading)
                TextField("0x…", text: $draft.tableBaseText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: Lumen.Space.s5) {
                Text("Case count")
                    .frame(width: 90, alignment: .leading)
                TextField("0", text: $draft.entryCountText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: Lumen.Space.s5) {
                Text("Entry size")
                    .frame(width: 90, alignment: .leading)
                TextField("4", text: $draft.entryStrideText)
                    .textFieldStyle(.roundedBorder)
                Text("bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Entries are signed offsets from the table base", isOn: $draft.isRelativeToBase)
            Text(draft.isRelativeToBase
                 ? "Each entry is a signed offset added to the table base (ldrsw form)."
                 : "Each entry is an absolute target address.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Remove", role: .destructive) {
                    _ = store.removeSwitchHint(draft)
                }
                Spacer()
                Button("Cancel") { store.cancelSwitchHintEditor(draft) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { store.commitSwitchHintEditor(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 460)
    }
}

/// One immutable input/presentation bundle for the graph PDF Save-panel flow.
struct GraphPDFExportContext {
    let projection: FocusedGraphProjection
    let title: String
    let defaultName: String
    let message: String?

    /// Freezes every focused-image-dependent export value before the modal Save panel is shown.
    /// The caller renders from `projection` immediately and passes the remaining captured values
    /// into the panel, so neither content nor presentation can follow a later focus change.
    @MainActor
    static func capture(from store: WorkspaceStore) -> GraphPDFExportContext {
        let projection = store.focusedGraphProjection
        let workspaceName = store.workspaceName
        let focusedBinaryName = store.focusedBinary?.name

        guard store.snapshot.binaries.count > 1, let focusedBinaryName else {
            return GraphPDFExportContext(
                projection: projection,
                title: workspaceName,
                defaultName: "\(workspaceName)-graph",
                message: nil
            )
        }

        return GraphPDFExportContext(
            projection: projection,
            title: "\(workspaceName) — \(focusedBinaryName)",
            defaultName: "\(workspaceName)-\(focusedBinaryName)-graph",
            message: "Export the control-flow graph from \(focusedBinaryName)."
        )
    }
}

/// The navigation / procedure / section command handlers, extracted into a
/// `ViewModifier` so the root view's `body` stays under the Swift type-checker's
/// complexity budget (the inline `.onReceive` chain otherwise fails to type-check).
/// Routes the File-menu "Export …" commands: each renders via the pure `DocumentExportService`
/// then writes through one shared Save panel. Grouped into a modifier (rather than inline in the
/// view body) so the body's modifier chain stays within the Swift type-checker's budget — the
/// same reason `NavigationCommandHandlers` exists.
@MainActor
struct BinExportUICapture {
    let snapshot: WorkspaceSnapshot
    let name: String
    let workspaceID: UUID
    let documentID: UUID
    let slot: ImageSlot
    let binaryID: UUID
    let mutationGeneration: UInt64

    static func capture(store: WorkspaceStore) -> Self? {
        let slot = store.focusedImageSlot
        guard let binary = store.snapshot.binary(in: slot) else { return nil }
        return Self(snapshot: store.snapshot, name: store.workspaceName,
            workspaceID: store.workspaceID, documentID: store.documentID,
            slot: slot, binaryID: binary.id,
            mutationGeneration: store.mutationGeneration.rawValue)
    }

    func isCurrent(store: WorkspaceStore) -> Bool {
        store.workspaceID == workspaceID && store.documentID == documentID
            && store.focusedImageSlot == slot
            && store.snapshot.binary(in: slot)?.id == binaryID
            && store.mutationGeneration.rawValue == mutationGeneration
    }
}

@MainActor
struct ProviderPseudocodeExportCapture {
    let input: ProviderPseudocodeExportInput
    let documentID: UUID

    static func expectedIdentity(in store: WorkspaceStore) -> DecompilerPresentationIdentity? {
        guard let binary = store.focusedBinary,
              let artifactUUID = binary.artifactIdentity?.uuid,
              let function = EditorContextResolution.function(
                in: store.focusedAnalysis?.functions ?? [], selectedAddress: store.selectedAddress),
              let fingerprint = store.focusedAnalysis?.analysisInputFingerprint?.overallSHA256 else { return nil }
        return DecompilerPresentationIdentity(imageSlot: store.focusedImageSlot,
            ownerBinaryID: binary.id, artifactUUID: artifactUUID,
            functionID: function.id.uuidString.lowercased(), analysisInputFingerprintSHA256: fingerprint)
    }

    static func capture(store: WorkspaceStore, presentation: NativeDecompilerPresentationModel,
                        provider: PseudocodeSource) throws -> Self {
        guard let expected = expectedIdentity(in: store), let analysis = store.focusedAnalysis,
              let function = EditorContextResolution.function(in: analysis.functions,
                selectedAddress: store.selectedAddress) else { throw ProviderPseudocodeExportError.nativeUnavailable }
        let comparison: DecompilerComparisonProjection?
        if case let .ready(coordinate, success) = presentation.state {
            comparison = DecompilerComparisonProjection.project(coordinate: coordinate, expected: expected,
                native: success, macScope: NativeDecompilerMacScopeComparisonInput(analysis: analysis, function: function))
        } else { comparison = nil }
        let input = ProviderPseudocodeExportInput(workspaceID: store.workspaceID,
            workspaceName: store.workspaceName, imageName: store.focusedBinary?.name ?? "Image",
            provider: provider, documentMutationGeneration: store.mutationGeneration.rawValue,
            expected: expected, publication: presentation.readyPublicationIdentity,
            nativeState: presentation.state,
            macScopeText: DocumentExportService().renderPseudocode(snapshot: store.snapshot,
                selectedAddress: store.selectedAddress, in: store.focusedImageSlot), comparison: comparison)
        return Self(input: input, documentID: store.documentID)
    }

    func isCurrent(store: WorkspaceStore, presentation: NativeDecompilerPresentationModel,
                   provider: PseudocodeSource) -> Bool {
        store.workspaceID == input.workspaceID && store.documentID == documentID
            && store.mutationGeneration.rawValue == input.documentMutationGeneration
            && provider == input.provider && Self.expectedIdentity(in: store) == input.expected
            && presentation.readyPublicationIdentity == input.publication
    }
}

private struct ExportCommandHandlers: ViewModifier {
    @StateObject private var allPseudocodeExport = AllPseudocodeExportController()
    let store: WorkspaceStore
    let nativePresentation: NativeDecompilerPresentationModel
    let providerSelection: PseudocodeSourceSelectionModel
    /// The fence is captured before asynchronous work and checked before panel presentation.
    let captureExportOwner: @MainActor () -> (@MainActor () -> Bool)?

    // Each command's handler is a named type-scope method and every publisher shares one typed
    // helper, so the type checker no longer infers ten notification closures in one expression.
    // The receivers are attached in the original order with the original filters.
    func body(content: Content) -> some View {
        content
            .onReceive(targetedCommandPublisher(for: .macScopeExportListing)) { (_: Notification) in
                exportListing()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportPseudocode)) { (_: Notification) in
                exportFocusedPseudocode()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportAllPseudocode)) { (_: Notification) in
                exportAllPseudocode()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportObjectiveCHeader)) { (_: Notification) in
                exportObjectiveCHeader()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportSwiftInterface)) { (_: Notification) in
                exportSwiftInterface()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportGraphPDF)) { (_: Notification) in
                exportGraphPDF()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportTypeCatalog)) { (_: Notification) in
                exportTypeCatalog()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportRenderedTypeDefinition)) { (note: Notification) in
                exportRenderedTypeDefinition(note)
            }
            .onReceive(targetedCommandPublisher(for: .macScopeExportBinExport2)) { (_: Notification) in
                exportBinExport2()
            }
            .onReceive(targetedCommandPublisher(for: .macScopeSavePatchedBinary)) { (_: Notification) in
                savePatchedBinary()
            }
            .overlay(alignment: .bottomTrailing) {
                if let progress = allPseudocodeExport.progress {
                    HStack {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            .frame(width: AppExportProgressChrome.progressWidth)
                        Text("Exporting \(progress.completed)/\(progress.total)")
                        Button("Cancel") { allPseudocodeExport.cancel() }
                    }
                    .padding(AppExportProgressChrome.padding)
                    .background(
                        AppExportProgressChrome.material,
                        in: RoundedRectangle(cornerRadius: AppExportProgressChrome.cornerRadius)
                    )
                    .padding(AppExportProgressChrome.padding)
                }
            }
            .onDisappear { allPseudocodeExport.cancel() }
    }

    private func targetedCommandPublisher(
        for name: Notification.Name
    ) -> Publishers.Filter<NotificationCenter.Publisher> {
        NotificationCenter.default.publisher(for: name).filter { (note: Notification) -> Bool in
            store.commandTargetsSelf(note)
        }
    }

    private func exportListing() {
        write(DocumentExportService().renderListing(snapshot: store.snapshot, in: store.focusedImageSlot),
              name: "\(store.workspaceName)-listing", extensions: ["txt", "asm"])
    }

    private func exportFocusedPseudocode() {
        guard providerSelection.source == .macScope else {
            exportSelectedProviderPseudocode()
            return
        }
        // Honor the current scope: the function enclosing the selection (or the first).
        write(DocumentExportService().renderPseudocode(
            snapshot: store.snapshot,
            selectedAddress: store.selectedAddress,
            in: store.focusedImageSlot
        ), name: "\(store.workspaceName)-pseudocode", extensions: ["txt"],
            message: focusedPseudocodeExportMessage)
    }

    private func exportAllPseudocode() {
        // With Native or Compare selected, ask which provider to export (never a silent switch).
        var native = false
        if let prompt = AllPseudocodeExportPrompt.prompt(for: providerSelection.source) {
            let alert = NSAlert()
            alert.messageText = prompt.title
            alert.informativeText = prompt.message
            alert.addButton(withTitle: prompt.nativeTitle)
            alert.addButton(withTitle: prompt.macScopeTitle)
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: native = true
            case .alertSecondButtonReturn: native = false
            default: return
            }
        }
        guard let isCurrentOwner = captureExportOwner() else { return }
        if native {
            allPseudocodeExport.startNative(store: store, isCurrentOwner: isCurrentOwner)
        } else {
            allPseudocodeExport.start(store: store, isCurrentOwner: isCurrentOwner)
        }
    }

    private func exportObjectiveCHeader() {
        // Class dump: every recovered Objective-C @interface, in __objc_classlist order.
        write(DocumentExportService().renderObjectiveCHeader(snapshot: store.snapshot, in: store.focusedImageSlot),
              name: "\(store.workspaceName)", extensions: ["h"])
    }

    private func exportSwiftInterface() {
        // Interface dump: every recovered Swift nominal type, in __swift5_types order.
        write(DocumentExportService().renderSwiftInterface(snapshot: store.snapshot, in: store.focusedImageSlot),
              name: "\(store.workspaceName)", extensions: ["swift"])
    }

    private func exportGraphPDF() {
        // Vector capture of the control-flow graph: one PDF page sized to fit the
        // whole graph. Capture every focus-derived input before the Save panel so a
        // pending export cannot be rebound to another image.
        let export = GraphPDFExportContext.capture(from: store)
        guard let data = GraphPDFRenderer().renderPDF(
            projection: export.projection,
            title: export.title
        ) else {
            store.saveError = "Could not render the control-flow graph to PDF."
            return
        }
        writeData(
            data,
            name: export.defaultName,
            extension: "pdf",
            message: export.message
        )
    }

    private func exportTypeCatalog() {
        // Type-set export: the authored struct/union/enum/typedef catalog as re-importable C.
        write(DocumentExportService().renderTypeCatalog(snapshot: store.snapshot),
              name: "\(store.workspaceName)-types", extensions: ["h"])
    }

    private func exportRenderedTypeDefinition(_ note: Notification) {
        guard let request = note.object as? RenderedTypeDefinitionExportRequest else { return }
        write(
            request.contents,
            name: request.suggestedBaseName,
            extensions: ["h"],
            message: "Export the rendered C declaration for this definition."
        )
    }

    private func exportBinExport2() {
        // BinExport2 (google/binexport) protobuf for BinDiff and compatible diff tooling.
        // The exporter is pure (`-> Data`); only writeData touches disk.
        guard let isCurrentOwner = captureExportOwner(),
              let capture = BinExportUICapture.capture(store: store) else { return }
        let snapshot = capture.snapshot
        let slot = capture.slot
        Task { @MainActor in
            // The exporter checks its bytes against the vendored upstream schema and
            // BinDiff's requirements; a non-conforming export is reported, never written.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BinExport2Exporter().exportForBinDiff(snapshot, in: slot) }
            }.value
            guard !Task.isCancelled, isCurrentOwner(), capture.isCurrent(store: store) else { return }
            let data: Data
            switch result {
            case .success(let bytes): data = bytes
            case .failure(let error):
                store.saveError = error.localizedDescription
                return
            }
            writeData(data, name: capture.name, extension: "BinExport2", validate: {
                isCurrentOwner() && capture.isCurrent(store: store)
            })
        }
    }

    private func exportSelectedProviderPseudocode() {
        guard let isCurrentOwner = captureExportOwner() else { return }
        do {
            let capture = try ProviderPseudocodeExportCapture.capture(
                store: store, presentation: nativePresentation, provider: providerSelection.source)
            let export = try DocumentExportService().renderProviderPseudocode(capture.input)
            write(export.text, name: export.suggestedName, extensions: ["txt"],
                  message: "Export \(capture.input.provider.rawValue) pseudocode from \(capture.input.imageName).",
                  validate: {
                      isCurrentOwner() && capture.isCurrent(store: store,
                          presentation: nativePresentation, provider: providerSelection.source)
                  })
        } catch let error as ProviderPseudocodeExportError {
            switch error {
            case .nativePending: store.saveError = "Native pseudocode is still being analyzed. Try export when the selected function is ready."
            case .nativeUnavailable: store.saveError = "Native pseudocode is unavailable for the selected function."
            case .stalePublication: store.saveError = "The native publication no longer matches the selected function. Refresh it before exporting."
            case .missingNativeDocument: store.saveError = "The native result has no pseudocode document to export."
            case .comparisonUnavailable: store.saveError = "A current structural comparison is unavailable for the selected function."
            }
        } catch { store.saveError = error.localizedDescription }
    }

    /// Identifies the image targeted by focused pseudocode export when the workspace can
    /// otherwise make an address or workspace-derived filename ambiguous. Single-image
    /// exports retain the existing Save-panel presentation without a message.
    private var focusedPseudocodeExportMessage: String? {
        guard store.snapshot.binaries.count > 1, let binary = store.focusedBinary else {
            return nil
        }
        return "Export pseudocode from \(binary.name)."
    }

    /// Writes a patched copy of the FOCUSED image to a chosen file (MS-15). The output is derived
    /// from the image bytes captured when the workspace loaded it (`ImageAnalysis.imageBytes`),
    /// never from whatever file is at `binary.path` now, through the shared
    /// `capturePatchedBinaryExport` / `PreparedMachOPatchExport` / `finishPatchedBinaryExport`
    /// path that scripting `save-patched-binary` also uses. The patch map is applied off the main
    /// actor by the pure `MachOPatchWriter`; owner, identity and patch-map digest are rechecked on
    /// the MainActor after the Save panel closes, so a patch edit while it was open is refused as
    /// stale. Universal-slice and dyld-cache origins are refused as before. On success the user is
    /// told how the output is signed (`PreparedMachOPatchExport.Signing.summary`): unchanged, ad hoc
    /// in process, or unsigned with the reason and a `codesign` hint.
    private func savePatchedBinary() {
        // A document retired while the patch map is applied must not get a Save panel or a write.
        guard let isCurrentOwner = captureExportOwner() else { return }
        let slot = store.focusedImageSlot
        guard let binary = store.snapshot.binary(in: slot) else {
            store.saveError = PatchedBinaryExportError.noImage.errorDescription
            return
        }
        let capture: PatchedBinaryExportCapture
        do {
            capture = try store.capturePatchedBinaryExport(in: slot)
        } catch {
            store.saveError = error.localizedDescription
            return
        }
        let defaultName = (binary.path as NSString).lastPathComponent.isEmpty
            ? binary.name : (binary.path as NSString).lastPathComponent
        let hasMultipleImages = store.snapshot.binaries.count > 1
        let sequence = PatchedBinarySaveSequence(
            isCurrentOwner: isCurrentOwner,
            prepare: {
                try await Task.detached(priority: .userInitiated) {
                    try capture.prepare()
                }.value
            },
            chooseDestination: { prepared in
                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                // No content-type filter: a Mach-O executable has no canonical extension, and the
                // default name mirrors the source so the relationship is obvious.
                panel.nameFieldStringValue = "\(defaultName)-patched"
                panel.message = hasMultipleImages
                    ? "Save a patched copy of \(capture.binaryName). \(prepared.signing.summary)"
                    : prepared.signing.summary
                // The app-modal panel runs from this Task, not from an event; give key status back so
                // the result alert takes Return/Escape.
                let response = ModalPanelFocus.run { panel.runModal() }
                guard response == .OK else { return nil }
                return panel.url
            },
            write: { prepared, url in
                do {
                    let patchedData = try store.finishPatchedBinaryExport(prepared, in: slot)
                    try capture.write(patchedData, to: url)
                    let count = prepared.patchCount
                    let writeSummary = hasMultipleImages
                        ? "Wrote \(count) patch\(count == 1 ? "" : "es") from \(capture.binaryName) to \(url.lastPathComponent).\n\n"
                        : "Wrote \(count) patch\(count == 1 ? "" : "es") to \(url.lastPathComponent).\n\n"
                    store.infoMessage = writeSummary + prepared.signing.summary
                } catch let error as PreparedMachOPatchExport.PreparationError {
                    store.saveError = error.localizedDescription
                } catch {
                    store.saveError = "Could not write the patched binary to \(url.lastPathComponent): \(error.localizedDescription)"
                }
            },
            reportPreparationError: { error in
                store.saveError = error.localizedDescription
            }
        )
        Task { @MainActor in
            await sequence.run()
        }
    }

    /// Presents a Save panel and, on confirmation, writes the already-rendered `text` (the
    /// `DocumentExportService` did the rendering with no I/O; this is the only place bytes touch
    /// disk). A write failure surfaces through the existing `saveError` alert rather than crashing.
    private func write(_ text: String, name: String, extensions: [String], message: String? = nil,
                       validate: @MainActor () -> Bool = { true }) {
        guard validate() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(name).\(extensions.first ?? "txt")"
        if let message {
            panel.message = message
        }
        // Some exports call this from a Task after an await (provider pseudocode); restore key
        // status so a following error alert takes Return/Escape.
        guard ModalPanelFocus.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        guard validate() else {
            store.saveError = "The export source changed while the Save panel was open. Start export again."
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.saveError = "Could not export to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Presents a Save panel and, on confirmation, writes already-rendered binary `data`
    /// (e.g. the `GraphPDFRenderer`'s PDF bytes). Mirrors `write(_:name:extensions:)` but for
    /// a binary blob; a write failure surfaces through the existing `saveError` alert.
    private func writeData(
        _ data: Data,
        name: String,
        extension ext: String,
        message: String? = nil,
        validate: @MainActor () -> Bool = { true }
    ) {
        guard validate() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext)].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(name).\(ext)"
        if let message {
            panel.message = message
        }
        // BinExport calls this from a Task after an await; restore key status as `write` does.
        guard ModalPanelFocus.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        guard validate() else {
            store.saveError = "The export owner changed while the Save panel was open. Start export again."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            store.saveError = "Could not export to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// The workspace document alerts (save failure, patched-binary saved, dSYM import result /
/// failure). Extracted into a `ViewModifier` so the root view's modifier chain stays within
/// the Swift type-checker's complexity budget — the same reason the command handlers and the
/// authoring sheets are modifiers.
private struct DocumentAlerts: ViewModifier {
    @ObservedObject var store: WorkspaceStore

    func body(content: Content) -> some View {
        content
            .alert(
                "Save Failed",
                isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })
            ) {
                // Cancel role keeps Escape; the default-action shortcut adds Return (as for
                // every single-button document alert; governed by DocumentAlertDefaultActionTests).
                Button("OK", role: .cancel) { store.saveError = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(store.saveError ?? "")
            }
            .alert(
                "Patched Binary Saved",
                isPresented: Binding(get: { store.infoMessage != nil }, set: { if !$0 { store.infoMessage = nil } })
            ) {
                // Cancel role keeps Escape; the default-action shortcut adds Return.
                Button("OK", role: .cancel) { store.infoMessage = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(store.infoMessage ?? "")
            }
            .alert(
                "Debug Symbols Imported",
                isPresented: Binding(get: { store.debugSymbolsResultMessage != nil }, set: { if !$0 { store.debugSymbolsResultMessage = nil } })
            ) {
                Button("OK", role: .cancel) { store.debugSymbolsResultMessage = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(store.debugSymbolsResultMessage ?? "")
            }
            .alert(
                "Could Not Read Debug Symbols",
                isPresented: Binding(get: { store.debugSymbolsImportError != nil }, set: { if !$0 { store.debugSymbolsImportError = nil } })
            ) {
                Button("OK", role: .cancel) { store.debugSymbolsImportError = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(store.debugSymbolsImportError ?? "")
            }
    }
}

/// Presents the W5-B GUI-reachability authoring sheets (Make Data, Rename Register, Import
/// C Header). Extracted into a `ViewModifier` so the root view's `.sheet(item:)` chain stays
/// within the Swift type-checker's complexity budget — adding these inline tips the body
/// over the "unable to type-check in reasonable time" threshold.
private struct AuthoringSheetPresenters: ViewModifier {
    @ObservedObject var store: WorkspaceStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.dataShapeEditorRequest) { request in
                MakeDataSheet(request: request, store: store)
            }
            .sheet(item: $store.registerRenameRequest) { request in
                RegisterRenameSheet(request: request, store: store)
            }
            .sheet(item: $store.cHeaderImportRequest) { request in
                CHeaderImportSheet(request: request, store: store)
            }
    }
}

/// Routes the W5-B GUI-reachability authoring commands that present a sheet (Make Data,
/// Import C Header, Rename Register, Set Local Label) from their menu/context notifications
/// into the store's `begin…` presenters. Mark as Procedure is NOT here — it rides the typed
/// `WorkspaceCommand` router (`WorkspaceCommandHandlers`) like Mark as Undefined. Grouped
/// into its own modifier so the root body's modifier chain stays within the Swift
/// type-checker's budget (the same reason `NavigationCommandHandlers` exists).
private struct AuthoringCommandHandlers: ViewModifier {
    let store: WorkspaceStore

    func body(content: Content) -> some View {
        content
            // Thin forwarders — the notification→action routing lives in (and is unit-tested
            // via) WorkspaceStore.routeAuthoringCommand. A pseudocode context menu passes the
            // register id as the notification object; the menu command passes nothing.
            .onReceive(NotificationCenter.default.publisher(for: .macScopeMakeData).filter { store.commandTargetsSelf($0) }) { _ in
                store.routeAuthoringCommand(.macScopeMakeData)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeImportCHeader).filter { store.commandTargetsSelf($0) }) { _ in
                store.routeAuthoringCommand(.macScopeImportCHeader)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeRenameRegister).filter { store.commandTargetsSelf($0) }) { note in
                store.routeAuthoringCommand(.macScopeRenameRegister, object: note.object)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeSetLocalLabel).filter { store.commandTargetsSelf($0) }) { _ in
                store.routeAuthoringCommand(.macScopeSetLocalLabel)
            }
    }
}

private struct NavigationCommandHandlers: ViewModifier {
    let store: WorkspaceStore

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .macScopeNextCode).filter { store.commandTargetsSelf($0) }) { _ in
                store.navigateToNextCode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeNextData).filter { store.commandTargetsSelf($0) }) { _ in
                store.navigateToNextData()
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeNextUnexplored).filter { store.commandTargetsSelf($0) }) { _ in
                store.navigateToNextUnexplored()
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeSelectProcedure).filter { store.commandTargetsSelf($0) }) { _ in
                store.selectProcedureAtSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeTruncateProcedure).filter { store.commandTargetsSelf($0) }) { _ in
                store.truncateProcedureAtSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeTransformSectionToStrings).filter { store.commandTargetsSelf($0) }) { _ in
                store.transformSectionToStringsAtSelection()
            }
    }
}

/// Routes EVERY `WorkspaceCommand` (the authoring + search-stepping menu commands) through
/// the typed `store.perform(_:)`. Built by merging all cases' notifications into one
/// subscription, so a new command is wired automatically and a visible menu command can
/// never post a notification that no one observes (the dead-command class the audit found:
/// Mark as Undefined, Add/Remove Bookmark, Patch Bytes, Replace with NOP, Clear Patch).
private struct WorkspaceCommandHandlers: ViewModifier {
    let store: WorkspaceStore

    func body(content: Content) -> some View {
        content.onReceive(Self.commandPublisher) { command, note in
            // WS-2: carry the Notification so this per-window modifier drops a command addressed
            // to a DIFFERENT document. Without the target check the typed router (which owns the
            // mutating authoring ops) would `perform` on every open window's store — corrupting
            // the wrong workspace. `perform(_:ifTargetedBy:)` is the unit-tested guard.
            store.perform(command, ifTargetedBy: note)
        }
    }

    private static let commandPublisher: AnyPublisher<(WorkspaceCommand, Notification), Never> =
        Publishers.MergeMany(
            WorkspaceCommand.allCases.map { command in
                NotificationCenter.default.publisher(for: command.notificationName)
                    .map { (command, $0) }
            }
        )
        .eraseToAnyPublisher()
}

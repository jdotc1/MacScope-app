import AppKit
import Combine
import SwiftUI
import LumenTokens
import LumenUI

/// An installation is distinct even when a restore reuses logical IDs and the same Store object.
struct EditorSceneIdentity: Hashable {
    let storeObjectID: ObjectIdentifier
    let workspaceID: UUID
    let documentID: UUID
    let documentInstallationID: UUID

    @MainActor init(store: WorkspaceStore) {
        storeObjectID = ObjectIdentifier(store)
        workspaceID = store.workspaceID
        documentID = store.documentID
        documentInstallationID = store.documentInstallationID
    }
}

struct EditorSurfaceView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var nativeDecompilerPresentation: NativeDecompilerPresentationModel
    @ObservedObject var pseudocodeSourceSelection: PseudocodeSourceSelectionModel
    @StateObject private var debuggerViewModel: DebuggerPanelViewModel
    @StateObject private var nativeDecompilerCommands: NativeDecompilerWindowCommandRouter
    // Lumen removes its panel subtree while hidden. Drafts and renderer-generation
    // ownership therefore belong to this stable editor identity, like the debugger model.
    @State private var shellPresentation = Phase2ShellAffordanceState()

    /// Production composition supplies a client bound to the app-lifetime debugger authority.
    /// `StateObject` retains the resulting model for this editor/window identity even when the
    /// workspace root recomputes its body.
    init(
        store: WorkspaceStore,
        nativeDecompilerPresentation: NativeDecompilerPresentationModel,
        pseudocodeSourceSelection: PseudocodeSourceSelectionModel,
        debuggerClient: @autoclosure @escaping () -> any DebuggerClient
    ) {
        self.store = store
        self.nativeDecompilerPresentation = nativeDecompilerPresentation
        self.pseudocodeSourceSelection = pseudocodeSourceSelection
        _debuggerViewModel = StateObject(
            wrappedValue: DebuggerPanelViewModel.makeWorkspaceModel(client: debuggerClient(), store: store)
        )
        _nativeDecompilerCommands = StateObject(
            wrappedValue: NativeDecompilerRuntimeRegistry.makeWindowCommandRouter(
                store: store,
                presentation: nativeDecompilerPresentation
            )
        )
    }

    /// Source-compatible isolated-view seam for tests and previews. The default local client does
    /// not carry the shared session lease registry, so arbitrary-process attach remains unavailable.
    init(store: WorkspaceStore) {
        self.init(
            store: store,
            nativeDecompilerPresentation: NativeDecompilerPresentationModel(),
            pseudocodeSourceSelection: PseudocodeSourceSelectionModel(),
            debuggerClient: LocalLLDBDebuggerClient()
        )
    }

    // Composed from type-scope stages that apply the original modifiers in the original order,
    // so each modifier cluster type-checks on its own; view types and ownership are unchanged.
    var body: some View {
        applyingDebuggerPresentationBridge(
            to: applyingDebuggerLifecycle(to: editorLayout)
        )
    }

    // MARK: Body stages (type-scope helpers; see `body`)

    private var editorLayout: some View {
        VStack(spacing: 0) {
            if let issue = store.lastIssue, !store.snapshot.binaries.isEmpty {
                IssueBanner(message: issue)
            }

            Divider()

            EditorContextBar(
                store: store,
                pseudocodeSourceSelection: pseudocodeSourceSelection
            )

            Divider()

            DSBottomPanel(
                presentation: $store.bottomPanelPresentation,
                debuggerExpanded: bottomPanelDebuggerExpanded
            ) {
                analysisContent
            } panel: {
                bottomPanelDeck
            }

            if store.focusedBinary != nil {
                EditorStatusBar(store: store)
                    .dsEditorSurface()
                    .dsPaletteRoot()
            }
        }
    }

    private var bottomPanelDebuggerExpanded: Bool {
        store.bottomPanelPresentation.debuggerTab == .breakpoints
            || debuggerViewModel.session.hasLiveProcessSession
            || (debuggerViewModel.capabilities.isBackendAvailable && !store.snapshot.binaries.isEmpty)
    }

    private var analysisContent: some View {
        AnalysisContentView(
            store: store,
            debuggerViewModel: debuggerViewModel,
            nativeDecompilerPresentation: nativeDecompilerPresentation,
            pseudocodeSourceSelection: pseudocodeSourceSelection,
            nativeDecompilerCommands: nativeDecompilerCommands
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The code canvas follows the editor theme, which may differ from the window
        // theme; the context bar above stays window chrome.
        .background(Color.lumen(.bgCanvas))
        .dsEditorSurface()
        .dsPaletteRoot()
    }

    @ViewBuilder
    private var bottomPanelDeck: some View {
        switch store.bottomPanelPresentation.selectedDeck {
        case .shell:
            Phase2ShellAffordanceView(store: store, state: shellPresentation)
        case .debugger:
            DebuggerPanelView(
                store: store,
                viewModel: debuggerViewModel,
                selectedTab: $store.bottomPanelPresentation.debuggerTab
            )
        }
    }

    private func applyingDebuggerLifecycle(to content: some View) -> some View {
        content
            .workbenchPaneBackground(.editor)
            .focusedValue(\.nativeDecompilerCommands, nativeDecompilerCommands)
            .onAppear {
                guard let owner = debuggerViewModel.savedWatchOwner,
                      store.installPhase2DebuggerProposalExecutor(debuggerViewModel, owner: owner) else {
                    _ = debuggerViewModel.beginWorkspaceRetirement()
                    return
                }
                reconcileDebuggerPresentation()
                store.debuggerSidebarSummary = DebuggerSidebarSummary(debuggerViewModel.session)
            }
            .onChange(of: debuggerViewModel.workspaceAdmissionPending) { (_: Bool, pending: Bool) in
                guard !pending, ownsDebuggerInstallation else { return }
                reconcileDebuggerPresentation()
            }
            // Sidebar activation republishes even when the selected row is unchanged.
            // A user may hide the panel and click that same row to show it again.
            .onReceive(store.$selectedSidebarItemID) { identifier in
                store.bottomPanelPresentation.routeSidebarSelection(identifier)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macScopeShowLogicalBreakpoints)) { (notification: Notification) in
                WorkspaceBottomPanelRouting.showLogicalBreakpoints(in: store, notification: notification)
            }
    }

    private func applyingDebuggerPresentationBridge(to content: some View) -> some View {
        content
            .onChange(of: debuggerViewModel.session) { _, session in
                guard ownsDebuggerInstallation else { return }
                store.debuggerSidebarSummary = DebuggerSidebarSummary(session)
                store.updatePhase2DebuggerReadOnlySnapshot(
                    session,
                    inspectionCoordinate: debuggerViewModel.currentInspectionCoordinate
                )
            }
            .onChange(of: debuggerViewModel.selectedFrameIndex) { _, _ in
                guard ownsDebuggerInstallation else { return }
                store.updatePhase2DebuggerReadOnlySnapshot(
                    debuggerViewModel.session,
                    inspectionCoordinate: debuggerViewModel.currentInspectionCoordinate
                )
            }
            .onChange(of: debuggerViewModel.lastControlledRuntimeActionEvent) { _, event in
                guard ownsDebuggerInstallation else { return }
                store.updatePhase2DebuggerControlledRuntimeAction(event)
            }
            .onChange(of: store.debuggerFocusedLaunchCandidate) { _, candidate in
                guard ownsDebuggerInstallation else { return }
                debuggerViewModel.reconcileFocusedLaunchCandidate(candidate)
            }
            .onChange(of: store.debuggerWorkspaceAuthority) { _, authority in
                guard ownsDebuggerInstallation else { return }
                guard let authority else { return }
                DebuggerWorkspaceAuthorityBridge.reconcile(
                    authority,
                    viewModel: debuggerViewModel,
                    updateLiveProgramCounter: { store.updateLiveProgramCounterTarget($0) }
                )
            }
            .onChange(of: store.debuggerBreakpointRevisions) { _, _ in
                guard ownsDebuggerInstallation else { return }
                guard let activeSlot = debuggerViewModel.activeWorkspaceImageSlot,
                      let input = store.debuggerWorkspaceInput(in: activeSlot),
                      debuggerViewModel.prepareActiveWorkspaceReconciliation(input) else { return }
                Task { await debuggerViewModel.reconcileActiveWorkspaceInput(input) }
            }
            .onChange(of: store.debuggerBreakpointRevisionGeneration) { _, _ in
                guard ownsDebuggerInstallation else { return }
                debuggerViewModel.invalidateWorkspaceReconciliationEpochs()
                let candidate = store.debuggerFocusedLaunchCandidate
                let activeInput = debuggerViewModel.activeWorkspaceImageSlot.flatMap {
                    store.debuggerWorkspaceInput(in: $0)
                }
                debuggerViewModel.reconcileFocusedLaunchCandidate(candidate)
                guard debuggerViewModel.prepareActiveWorkspaceReconciliation(activeInput) else {
                    return
                }
                Task {
                    await debuggerViewModel.reconcileActiveWorkspaceInput(activeInput)
                }
            }
            // Bridge the debugger's current PC into the editor store so the disassembly
            // listing flags + scrolls to the live-PC row. Clears (nil) on resume/exit.
            .onChange(of: debuggerViewModel.currentWorkspaceProgramCounter) { _, programCounter in
                guard ownsDebuggerInstallation else { return }
                store.updateLiveProgramCounterTarget(programCounter)
            }
            // Debug ▸ Run to Cursor: run the stopped target to the selected listing
            // address via a temporary one-shot breakpoint. A no-op when nothing is
            // selected; the view model gates the run to a paused live session.
            .onReceive(NotificationCenter.default.publisher(for: .macScopeRunToCursor).filter { store.commandTargetsSelf($0) }) { _ in
                guard ownsDebuggerInstallation else { return }
                guard let target = store.selectedImageAddress else { return }
                guard store.snapshot.isExecutableInstructionAddress(target) else { return }
                Task { await debuggerViewModel.runToCursor(to: target) }
            }
    }

    private var ownsDebuggerInstallation: Bool {
        debuggerViewModel.savedWatchOwner.map(store.isCurrentSavedWatchOwner) == true
    }

    private func reconcileDebuggerPresentation() {
        guard ownsDebuggerInstallation else { return }
        if let authority = store.debuggerWorkspaceAuthority {
            DebuggerWorkspaceAuthorityBridge.reconcile(authority, viewModel: debuggerViewModel,
                updateLiveProgramCounter: { store.updateLiveProgramCounterTarget($0) })
        }
        debuggerViewModel.reconcileFocusedLaunchCandidate(store.debuggerFocusedLaunchCandidate)
        store.updatePhase2DebuggerReadOnlySnapshot(debuggerViewModel.session,
            inspectionCoordinate: debuggerViewModel.currentInspectionCoordinate)
        store.updateLiveProgramCounterTarget(debuggerViewModel.currentWorkspaceProgramCounter)
    }
}

/// The production bridge installs the document-wide authority as one coherent value. Focused
/// launch proposals are observed independently above and cannot tear its catalog components.
@MainActor
enum DebuggerWorkspaceAuthorityBridge {
    static func reconcile(
        _ authority: DebuggerWorkspaceAuthority,
        viewModel: DebuggerPanelViewModel,
        updateLiveProgramCounter: (ImageAddress?) -> Void
    ) {
        viewModel.reconcileWorkspaceAuthority(authority)
        updateLiveProgramCounter(viewModel.currentWorkspaceProgramCounter)
    }
}

/// The single production bridge between workspace artifact ownership and debugger runtime mapping.
/// Reconciliation is synchronous so a catalog/owner replacement clears a stale editor highlight
/// before any asynchronous debugger request can complete.
@MainActor
enum DebuggerWorkspaceCatalogBridge {
    static func reconcile(
        _ catalog: DebuggerWorkspaceArtifactCatalog,
        viewModel: DebuggerPanelViewModel,
        updateLiveProgramCounter: (ImageAddress?) -> Void
    ) {
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        updateLiveProgramCounter(viewModel.currentWorkspaceProgramCounter)
    }
}

struct EditorContextSelectionPresentation: Equatable {
    let address: String
    let mnemonic: String?

    var accessibilitySummary: String {
        if let mnemonic {
            return ", selected instruction \(address), \(mnemonic)"
        }
        return ", selected address \(address)"
    }
}

/// Pure resolution shared by the context bar's visible pills and combined accessibility label.
/// A non-nil image-qualified selection is evidence in its own right even when decoding produced no
/// row at that exact address; function fallback is reserved for the no-selection overview state.
enum EditorContextResolution {
    static func function(
        in functions: [FunctionSummary],
        selectedAddress: UInt64?
    ) -> FunctionSummary? {
        guard let selectedAddress else {
            return functions.first
        }

        return functions.first { function in
            if function.endAddress > function.startAddress {
                return selectedAddress >= function.startAddress && selectedAddress < function.endAddress
            }
            return selectedAddress == function.startAddress
        }
    }

    static func selection(
        target: ImageAddress?,
        instruction: InstructionRow?,
        displayedMnemonic: String? = nil
    ) -> EditorContextSelectionPresentation? {
        guard let target else { return nil }
        let matchingMnemonic = instruction.flatMap { row in
            row.address == target.address ? (displayedMnemonic ?? row.mnemonic) : nil
        }
        return EditorContextSelectionPresentation(
            address: target.address.hexAddress,
            mnemonic: matchingMnemonic
        )
    }
}

private struct EditorContextBar: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.lumenMetrics) private var metrics
    @ObservedObject var pseudocodeSourceSelection: PseudocodeSourceSelectionModel

    var body: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label {
                Text(store.editorMode.rawValue)
            } icon: {
                DSSymbol(store.editorMode.systemImage)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            if let contextFunction {
                let functionName = store.snapshot.displayName(at: contextFunction.startAddress, in: store.focusedImageSlot, default: contextFunction.name)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Lumen.Space.s4) {
                        if store.snapshot.binaries.count > 1,
                           let binary = store.focusedBinary {
                            LumenPill(label: "image", value: binary.name)
                        }
                        contextTitle(functionName, help: functionName)

                        LumenPill(label: "start", value: contextFunction.startAddress.hexAddress)

                        if contextFunction.endAddress > contextFunction.startAddress {
                            LumenPill(label: "end", value: contextFunction.endAddress.hexAddress)
                        }
                    }

                    if store.snapshot.binaries.count > 1,
                       let binary = store.focusedBinary {
                        contextTitle("\(binary.name) — \(functionName)", help: functionName)
                    } else {
                        contextTitle(functionName, help: functionName)
                    }
                }
            } else if let binary = store.focusedBinary {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Lumen.Space.s4) {
                        contextTitle(binary.name, help: binary.path)
                        LumenPill(label: binary.kind, value: binary.architecture, systemImage: "cpu")
                    }

                    contextTitle(binary.name, help: binary.path)
                }
            } else {
                Text("No target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Lumen.Space.s5)

            if store.editorMode == .pseudocode {
                PseudocodeSourceSelector(selection: pseudocodeSourceSelection)
            }

            if let contextSelection {
                LumenPill(label: "sel", value: contextSelection.address)
                if let mnemonic = contextSelection.mnemonic {
                    LumenPill(label: "op", value: mnemonic)
                }
            }

            DSBottomPanelControls(presentation: $store.bottomPanelPresentation)
        }
        .padding(.horizontal, Lumen.Space.s7)
        .frame(height: AppEditorChrome.contextBarHeight, alignment: .center)
        // U10-3: on the pane's surface with a hairline below, not a toolbar band of its own.
        .overlay(alignment: .bottom) { Rectangle().fill(Color.lumen(.borderSubtle)).frame(height: metrics.stroke.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var contextFunction: FunctionSummary? {
        EditorContextResolution.function(
            in: store.focusedAnalysis?.functions ?? [],
            selectedAddress: store.selectedAddress
        )
    }

    private var contextSelection: EditorContextSelectionPresentation? {
        EditorContextResolution.selection(
            target: store.selectedImageAddress,
            instruction: store.selectedInstruction,
            displayedMnemonic: selectedDisplayedMnemonic
        )
    }

    private var selectedDisplayedMnemonic: String? {
        guard let instruction = store.selectedInstruction else { return nil }
        let slot = store.focusedImageSlot
        if store.snapshot.isUndefined(at: instruction.address, in: slot) {
            return WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes).mnemonic
        }
        if store.snapshot.isData(at: instruction.address, in: slot) {
            if let shape = store.snapshot.dataShape(at: instruction.address, in: slot) {
                return WorkspaceSnapshot.dataDirective(
                    forShape: shape, at: instruction.address,
                    readBytes: store.snapshot.hexByteReader(in: slot)
                ).mnemonic
            }
            return WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes).mnemonic
        }
        return instruction.mnemonic
    }

    private var accessibilitySummary: String {
        let selectionSummary = contextSelection?.accessibilitySummary ?? ""
        if let contextFunction {
            let functionName = store.snapshot.displayName(
                at: contextFunction.startAddress,
                in: store.focusedImageSlot,
                default: contextFunction.name
            )
            if store.snapshot.binaries.count > 1, let binary = store.focusedBinary {
                return "\(store.editorMode.rawValue), \(binary.name), \(functionName)\(selectionSummary)"
            }
            return "\(store.editorMode.rawValue), \(functionName)\(selectionSummary)"
        }
        if store.snapshot.binaries.count > 1, let binary = store.focusedBinary {
            return "\(store.editorMode.rawValue), \(binary.name)\(selectionSummary)"
        }
        return "\(store.editorMode.rawValue)\(selectionSummary)"
    }

    private func contextTitle(_ title: String, help: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .allowsTightening(true)
            .help(help)
    }
}

private struct AnalysisContentView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var debuggerViewModel: DebuggerPanelViewModel
    @ObservedObject var nativeDecompilerPresentation: NativeDecompilerPresentationModel
    @ObservedObject var pseudocodeSourceSelection: PseudocodeSourceSelectionModel
    let nativeDecompilerCommands: any NativeDecompilerWindowCommandRouting
    @StateObject private var nativePseudocodeActions: NativePseudocodeActionRouter

    init(
        store: WorkspaceStore,
        debuggerViewModel: DebuggerPanelViewModel,
        nativeDecompilerPresentation: NativeDecompilerPresentationModel,
        pseudocodeSourceSelection: PseudocodeSourceSelectionModel,
        nativeDecompilerCommands: any NativeDecompilerWindowCommandRouting
    ) {
        self.store = store
        self.debuggerViewModel = debuggerViewModel
        self.nativeDecompilerPresentation = nativeDecompilerPresentation
        self.pseudocodeSourceSelection = pseudocodeSourceSelection
        self.nativeDecompilerCommands = nativeDecompilerCommands
        _nativePseudocodeActions = StateObject(wrappedValue: NativePseudocodeActionRouter(
            store: store,
            presentation: nativeDecompilerPresentation,
            sourceSelection: pseudocodeSourceSelection
        ))
    }

    var body: some View {
        Group {
            if store.isImporting {
                let progress = AnalysisProgressPresentation(store.analysisProgress)
                LoadingStateView(
                    title: "Indexing binary",
                    detail: progress.detail,
                    cancel: .init { store.cancelImport() },
                    progress: progress.fraction
                )
            } else if let issue = store.lastIssue, store.snapshot.binaries.isEmpty {
                ErrorStateView(
                    title: "Import failed",
                    detail: issue,
                    recovery: "Open another macOS executable, app bundle, framework, or dylib to continue."
                )
            } else if store.snapshot.binaries.isEmpty {
                // The empty workspace is MacScope's welcome: Nova-style starfield, one action.
                // The title text stays "No binary open" for the installed-app UI tests.
                DSWelcomeView(
                    title: "No binary open",
                    message: "Open a macOS executable, app bundle, framework, or dylib to begin analysis.",
                    actionTitle: "Open Binary…",
                    secondaryActionTitle: "Open Workspace…",
                    secondaryAction: {
                        NotificationCenter.default.post(
                            name: .macScopeOpenProject,
                            object: nil,
                            userInfo: Notification.commandTargetUserInfo(store)
                        )
                    },
                    recents: NSDocumentController.shared.recentDocumentURLs.prefix(5).map { url in
                        DSWelcomeView.Recent(url: url) {
                            NotificationCenter.default.post(
                                name: .macScopeOpenRecentDocument,
                                object: url,
                                userInfo: Notification.commandTargetUserInfo(store)
                            )
                        }
                    }
                ) {
                    NotificationCenter.default.post(
                        name: .macScopeOpenBinary,
                        object: nil,
                        userInfo: Notification.commandTargetUserInfo(store)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch store.editorMode {
                case .disassembly:
                    DisassemblyView(store: store, debuggerViewModel: debuggerViewModel)
                case .pseudocode:
                    pseudocodeContent
                case .graph:
                    GraphView(store: store)
                case .hex:
                    if (store.focusedAnalysis?.hexBytes ?? Data()).isEmpty {
                        EmptyStateView(
                            title: "No bytes available",
                            detail: "The selected target did not expose readable bytes for the hex view.",
                            systemImage: "number"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HexEditorView(
                            store: store,
                            selectedAddress: store.selectedAddress,
                            baseAddress: store.focusedAnalysis?.instructions.first?.address
                        )
                    }
                }
            }
        }
        // Switching the focused image at a colliding VA presents the SAME addresses to the same
        // SwiftUI subtree; keying by slot forces a fresh identity so row/scroll/selection state
        // from image A never leaks into image B.
        .id(store.focusedImageSlot)
        .sheet(item: Binding(
            get: { nativePseudocodeActions.sheet },
            set: { _ in nativePseudocodeActions.dismiss() }
        )) { sheet in
            NativePseudocodeActionSheetView(
                sheet: sheet,
                onChoose: nativePseudocodeActions.choose,
                onDismiss: nativePseudocodeActions.dismiss
            )
        }
        .onChange(of: nativeDecompilerPresentation.readyPublicationIdentity) { _, _ in
            nativePseudocodeActions.reconcile()
        }
        .onChange(of: expectedIdentity) { _, _ in nativePseudocodeActions.reconcile() }
        .onChange(of: store.workspaceID) { _, _ in nativePseudocodeActions.reconcile() }
        .onChange(of: store.isImporting) { _, _ in nativePseudocodeActions.reconcile() }
        .onChange(of: store.selectedTool) { _, _ in nativePseudocodeActions.reconcile() }
        .onChange(of: store.editorMode) { _, _ in nativePseudocodeActions.reconcile() }
        .onChange(of: pseudocodeSourceSelection.source) { _, _ in nativePseudocodeActions.reconcile() }
        .onDisappear { nativePseudocodeActions.dismiss() }
    }

    @ViewBuilder
    private var pseudocodeContent: some View {
        // Capture when this document is rendered. Delayed menus and range choices must still match
        // this publication, even if the replacement result has the same request digest and tokens.
        let actionIdentity = nativeDecompilerPresentation.readyPublicationIdentity.map {
            NativePseudocodeActionIdentity(workspaceID: store.workspaceID, publication: $0)
        }
        let native = NativePseudocodePresentation.project(
            state: nativeDecompilerPresentation.state,
            expected: expectedIdentity,
            macScopeIsAvailable: macScopeComparisonInput != nil
        )
        switch pseudocodeSourceSelection.source {
        case .native:
            if native.usesMacScopeFallback {
                VStack(spacing: 0) {
                    NativePseudocodeStatusStrip(
                        presentation: native,
                        enabledCommands: nativeDecompilerCommands.enabledCommands,
                        onCommand: nativeDecompilerCommands.perform
                    )
                    Divider()
                    PseudocodeView(store: store)
                }
            } else {
                NativePseudocodeView(
                    presentation: native,
                    enabledCommands: nativeDecompilerCommands.enabledCommands,
                    onCommand: nativeDecompilerCommands.perform,
                    onSourceAction: { request in
                        guard let actionIdentity else { return }
                        nativePseudocodeActions.source(request, captured: actionIdentity)
                    },
                    onEntityDetail: { detail in
                        guard let actionIdentity else { return }
                        nativePseudocodeActions.entity(detail, captured: actionIdentity)
                    },
                    onValueAction: { request in
                        guard let actionIdentity else { return }
                        nativePseudocodeActions.value(request, captured: actionIdentity)
                    }
                )
            }

        case .macScope:
            PseudocodeView(store: store)

        case .compare:
            DecompilerComparisonView(
                projection: comparisonProjection,
                onShowNative: { pseudocodeSourceSelection.select(.native) }
            )
        }
    }

    private var contextFunction: FunctionSummary? {
        EditorContextResolution.function(
            in: store.focusedAnalysis?.functions ?? [],
            selectedAddress: store.selectedAddress
        )
    }

    private var expectedIdentity: DecompilerPresentationIdentity? {
        guard let binary = store.focusedBinary,
              let artifactUUID = binary.artifactIdentity?.uuid,
              let function = contextFunction,
              let fingerprint = store.focusedAnalysis?.analysisInputFingerprint?.overallSHA256
        else { return nil }

        return DecompilerPresentationIdentity(
            imageSlot: store.focusedImageSlot,
            ownerBinaryID: binary.id,
            artifactUUID: artifactUUID,
            functionID: function.id.uuidString.lowercased(),
            analysisInputFingerprintSHA256: fingerprint
        )
    }

    private var macScopeComparisonInput: NativeDecompilerMacScopeComparisonInput? {
        guard let analysis = store.focusedAnalysis,
              let function = contextFunction
        else { return nil }
        return NativeDecompilerMacScopeComparisonInput(analysis: analysis, function: function)
    }

    private var comparisonProjection: DecompilerComparisonProjection {
        if let unavailableReason = EditorDecompilerComparisonAvailability.unavailableReason(
            hasExpectedIdentity: expectedIdentity != nil,
            hasMacScopeInput: macScopeComparisonInput != nil
        ) {
            return .unavailable(unavailableReason)
        }
        guard let expectedIdentity else {
            return .unavailable(.nativeUnavailable)
        }

        switch nativeDecompilerPresentation.state {
        case let .ready(coordinate, success):
            return DecompilerComparisonProjection.project(
                coordinate: coordinate,
                expected: expectedIdentity,
                native: success,
                macScope: macScopeComparisonInput
            )
        case .idle, .analyzing, .unavailable, .failed:
            return .unavailable(.nativeUnavailable)
        }
    }
}

enum EditorDecompilerComparisonAvailability {
    static func unavailableReason(
        hasExpectedIdentity: Bool,
        hasMacScopeInput: Bool
    ) -> DecompilerComparisonUnavailableReason? {
        guard hasMacScopeInput else { return .macScopeUnavailable }
        guard hasExpectedIdentity else { return .nativeUnavailable }
        return nil
    }
}

struct HexNavigationState: Equatable {
    let byteCount: Int
    let baseOffset: Int
    let baseAddress: UInt64?
    let selectedAddress: UInt64?
    let bytesPerRow: Int
    /// Verified file-offset → virtual-address mappings for the window. When non-empty, the
    /// selection highlight resolves `selectedAddress` through these — the SAME table the hex
    /// editor writes through — so the highlighted cell and the editable cell for an address
    /// always agree. Empty falls back to the legacy linear `baseAddress + offset` anchoring
    /// (hand-built fixtures / reloaded windows with no mappings).
    let mappings: [FileAddressMapping]

    init(
        byteCount: Int,
        baseOffset: Int = 0,
        baseAddress: UInt64?,
        selectedAddress: UInt64?,
        mappings: [FileAddressMapping] = [],
        bytesPerRow: Int = AppEditorChrome.hexBytesPerRow
    ) {
        self.byteCount = byteCount
        self.baseOffset = baseOffset
        self.baseAddress = baseAddress
        self.selectedAddress = selectedAddress
        self.mappings = mappings
        self.bytesPerRow = max(1, bytesPerRow)
    }

    var rowCount: Int {
        guard byteCount > 0 else { return 0 }
        return Int(ceil(Double(byteCount) / Double(bytesPerRow)))
    }

    var selectedByteOffset: Int? {
        guard let selectedAddress else { return nil }
        // Preferred: resolve through the verified mapping table (alias-safe), matching the editor.
        if !mappings.isEmpty {
            guard let fileOffset = FileAddressMapping.resolvedFileOffset(
                forVirtualAddress: selectedAddress, in: mappings
            ) else { return nil }
            let windowBase = UInt64(max(0, baseOffset))
            guard fileOffset >= windowBase else { return nil }
            let delta = fileOffset - windowBase
            guard delta <= UInt64(Int.max) else { return nil }
            let offset = Int(delta) + baseOffset
            guard offset >= baseOffset, offset < baseOffset + byteCount else { return nil }
            return offset
        }
        // Fallback: legacy linear anchoring for windows without a mapping table.
        guard let baseAddress, selectedAddress >= baseAddress else { return nil }
        let delta = selectedAddress - baseAddress
        guard delta <= UInt64(Int.max) else { return nil }
        let offset = Int(delta) + baseOffset
        guard offset >= baseOffset, offset < baseOffset + byteCount else { return nil }
        return offset
    }

    var selectedRowIndex: Int? {
        guard let selectedByteOffset else { return nil }
        return (selectedByteOffset - baseOffset) / bytesPerRow
    }

    var selectedOffsetDescription: String? {
        guard let selectedByteOffset else { return nil }
        return String(format: "+0x%04X", selectedByteOffset - baseOffset)
    }

    var selectionSummary: String {
        guard let selectedOffsetDescription,
              let selectedRowIndex
        else {
            return "Selection outside loaded bytes"
        }

        return "Selected \(selectedOffsetDescription), row \(selectedRowIndex + 1)"
    }

    var byteSummary: String {
        "\(byteCount) bytes, \(rowCount) rows"
    }
}

/// Immutable owner + offset projection captured when one AppKit hex editor is configured.
/// `NSTextView` may deliver a delayed callback after SwiftUI has moved focus or replaced an image;
/// the callback must prove that its original slot, binary UUID, mappings, and qualified target all
/// still describe the live pane before it reaches the store's focused compatibility write path.
@MainActor
struct HexEditCallbackContext {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID
    let mappings: [FileAddressMapping]
    let captureProjectionVisitCount: Int
    let retainedAddressProjectionCount: Int
    private let byteCount: Int
    private let addressProjections: [FileAddressMapping]

    static func capture(
        imageSlot: ImageSlot,
        ownerBinaryID: UUID?,
        bytes: Data,
        mappings: [FileAddressMapping]
    ) -> HexEditCallbackContext? {
        guard let ownerBinaryID, !bytes.isEmpty else { return nil }

        // Retain only mappings that can project at least one byte in this window. Capture is
        // deliberately O(mapping count): a million-byte payload must not create a million-entry
        // target dictionary merely to protect a delayed AppKit callback.
        let lastFileOffset = UInt64(bytes.count - 1)
        var visitCount = 0
        var addressProjections: [FileAddressMapping] = []
        addressProjections.reserveCapacity(mappings.count)
        for mapping in mappings {
            visitCount += 1
            guard mapping.isWellFormed, mapping.fileOffset <= lastFileOffset else { continue }
            addressProjections.append(mapping)
        }
        guard !addressProjections.isEmpty else { return nil }

        return HexEditCallbackContext(
            imageSlot: imageSlot,
            ownerBinaryID: ownerBinaryID,
            mappings: mappings,
            captureProjectionVisitCount: visitCount,
            retainedAddressProjectionCount: addressProjections.count,
            byteCount: bytes.count,
            addressProjections: addressProjections
        )
    }

    func target(at offset: Int) -> ImageAddress? {
        guard offset >= 0, offset < byteCount else { return nil }
        guard let address = FileAddressMapping.resolvedVirtualAddress(
            forFileOffset: UInt64(offset),
            in: addressProjections
        ) else { return nil }
        return ImageAddress(slot: imageSlot, address: address)
    }

    func apply(offset: Int, value: UInt8, to store: WorkspaceStore) -> Bool {
        guard store.focusedImageSlot == imageSlot,
              store.focusedBinary?.id == ownerBinaryID,
              store.hexWindowMappings == mappings,
              let frozenTarget = target(at: offset)
        else { return false }

        // Re-resolve the live window and require exact agreement with the qualified target frozen
        // above. Only then is the legacy focused-offset store entry point safe to invoke.
        let liveBytes = store.patchedHexWindow().bytes
        guard offset >= 0, offset < liveBytes.count,
              FileAddressMapping.resolvedVirtualAddress(
                  forFileOffset: UInt64(offset),
                  in: store.hexWindowMappings
              ) == frozenTarget.address else { return false }
        return store.applyHexByteEdit(offset: offset, value: value)
    }
}

/// A navigation callback has the same image/window authority as editing, plus its workspace.
/// Byte patches do not invalidate a mapped caret; replaced windows, owners and mappings do.
@MainActor
struct HexCaretCallbackContext {
    let workspaceID: UUID
    private let projection: HexEditCallbackContext
    private let byteCount: Int

    static func capture(store: WorkspaceStore, bytes: Data,
                        mappings: [FileAddressMapping]) -> HexCaretCallbackContext? {
        guard store.hexWindowMappings == mappings,
              let projection = HexEditCallbackContext.capture(imageSlot: store.focusedImageSlot,
                ownerBinaryID: store.focusedBinary?.id, bytes: bytes, mappings: mappings) else { return nil }
        return .init(workspaceID: store.workspaceID, projection: projection, byteCount: bytes.count)
    }

    func target(at offset: Int) -> ImageAddress? { projection.target(at: offset) }

    func publish(offset: Int, target: ImageAddress, to store: WorkspaceStore) -> Bool {
        guard store.workspaceID == workspaceID,
              store.focusedImageSlot == projection.imageSlot,
              store.focusedBinary?.id == projection.ownerBinaryID,
              store.hexWindowMappings == projection.mappings,
              store.patchedHexWindow().bytes.count == byteCount,
              self.target(at: offset) == target,
              FileAddressMapping.resolvedVirtualAddress(forFileOffset: UInt64(max(0, offset)),
                in: store.hexWindowMappings) == target.address else { return false }
        if store.selectedImageAddress == target { return true }
        return store.selectAddress(target)
    }
}

private struct HexEditorView: View {
    @ObservedObject var store: WorkspaceStore
    let selectedAddress: UInt64?
    let baseAddress: UInt64?

    @StateObject private var patternInput: PatternPaneInputState
    @StateObject private var patternOwner: PatternInterpretationOwner

    init(store: WorkspaceStore, selectedAddress: UInt64?, baseAddress: UInt64?) {
        self.store = store
        self.selectedAddress = selectedAddress
        self.baseAddress = baseAddress
        let input = PatternPaneInputState()
        _patternInput = StateObject(wrappedValue: input)
        _patternOwner = StateObject(wrappedValue: PatternInterpretationOwner(live: {
            (PatternPaneFrame.read(store), input.record, input.source, input.sourceIdentity)
        }))
    }

    var body: some View {
        // MS-10: the window over the full slice that follows the selection; the store resolves
        // it once here so bytes, mappings and edits all see the same range.
        let frame = PatternPaneFrame.read(store)
        let windowRange = frame.window
        let sliceByteCount = store.hexSliceByteCount
        let frozenWindow = (bytes: frame.bytes, patchedOffsets: frame.patchedOffsets)
        let frozenMappings = frame.mappings
        let patternCommand = patternInput.isExpanded ? patternOwner.revealCommandIfCurrent(frame: frame, record: patternInput.record,
            source: patternInput.source, sourceIdentity: patternInput.sourceIdentity) : nil
        let preview = patternInput.record
        let recordPreview: Range<Int>? = patternInput.isExpanded && !preview.isEmpty && preview.upperBound <= frame.bytes.count ? preview : nil
        let frozenState = HexNavigationState(
            byteCount: frozenWindow.bytes.count,
            baseAddress: baseAddress,
            selectedAddress: selectedAddress,
            mappings: frozenMappings
        )
        let editable = store.isHexWindowEditable && !frozenWindow.bytes.isEmpty
        let editContext = editable ? HexEditCallbackContext.capture(
            imageSlot: store.focusedImageSlot,
            ownerBinaryID: store.focusedBinary?.id,
            bytes: frozenWindow.bytes,
            mappings: frozenMappings
        ) : nil
        let onByteEdit: ((Int, UInt8) -> Bool)? = editContext.map { context in
            { offset, value in
                // NSTextView invokes this callback synchronously on AppKit's main thread. Preserve
                // the Bool handshake (accepted edit advances the nibble caret) while making that
                // executor contract explicit to Swift 6.
                MainActor.assumeIsolated {
                    context.apply(offset: offset, value: value, to: store)
                }
            }
        }

        let caretContext = editable ? HexCaretCallbackContext.capture(
            store: store, bytes: frozenWindow.bytes, mappings: frozenMappings
        ) : nil
        let onCaretMove: ((Int, ImageAddress) -> Bool)? = caretContext.map { context in
            { offset, target in
                MainActor.assumeIsolated {
                    context.publish(offset: offset, target: target, to: store)
                }
            }
        }

        VStack(spacing: 0) {
            HexStatusStrip(state: frozenState, windowRange: windowRange, sliceByteCount: sliceByteCount)

            PatternPanel(owner: patternOwner, input: patternInput, frame: frame)

            Divider()

            HexViewRepresentable(
                bytes: frozenWindow.bytes,
                baseOffset: frozenState.baseOffset,
                mappings: frozenMappings,
                isEditable: editable,
                selection: store.selectedImageAddress,
                imageSlot: store.focusedImageSlot,
                ownerBinaryID: store.focusedBinary?.id,
                patchedOffsets: frozenWindow.patchedOffsets,
                onByteEdit: onByteEdit,
                onCaretMove: onCaretMove,
                displayOffset: windowRange.lowerBound,
                patternReveal: patternCommand,
                patternRecordPreview: recordPreview
            )
        }
        .onAppear {
            // A mapped caret may seed a start, never an inferred record length.
            guard patternInput.recordStart.isEmpty, let selectedAddress,
                  let offset = FileAddressMapping.resolvedFileOffset(forVirtualAddress: selectedAddress, in: frame.mappings),
                  offset < UInt64(frame.bytes.count),
                  FileAddressMapping.resolvedVirtualAddress(forFileOffset: offset, in: frame.mappings) == selectedAddress else { return }
            patternOwner.invalidate()
            patternInput.recordStart = String(offset)
        }
        .onChange(of: frame) { _, _ in patternOwner.invalidate() }
        .onDisappear { patternOwner.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editable ? "Hex editor, editable" : "Hex viewer, read only")
        .accessibilityValue(frozenState.selectionSummary)
    }
}

private struct HexStatusStrip: View {
    let state: HexNavigationState
    /// The slice range the window shows (MS-10) and the slice's size.
    var windowRange: Range<Int> = 0..<0
    var sliceByteCount = 0

    /// "bytes 0x10000–0x1FFFF of 1.2 MB" when the window is part of a larger slice.
    private var windowSummary: String? {
        guard sliceByteCount > windowRange.count, !windowRange.isEmpty else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(sliceByteCount), countStyle: .file)
        return String(format: "0x%X–0x%X of %@", windowRange.lowerBound, windowRange.upperBound - 1, size)
    }

    var body: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label("Hex", systemImage: "number")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(state.byteSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: AppEditorChrome.hexOffsetColumnWidth, alignment: .leading)

            if let windowSummary {
                Text(windowSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("The hex view shows a window of the slice that follows the selection.")
            }

            Text(state.selectionSummary)
                .font(.caption)
                .foregroundStyle(state.selectedByteOffset == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Lumen.Space.s5)

            Text("\(state.bytesPerRow) bytes/row")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Lumen.Space.s7)
        .frame(height: AppEditorChrome.hexStatusBarHeight, alignment: .center)
        // U10-3: on the pane's surface (its neighbour supplies the dividing hairline).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ["Hex status", state.byteSummary, windowSummary, state.selectionSummary].compactMap(\.self).joined(separator: ", ")
        )
    }
}

/// A stable, hashable scroll anchor for instruction rows so `ScrollViewReader` can
/// target a row by address (used by the live-PC auto-scroll).
enum DisassemblyScrollAnchor: Hashable {
    case instruction(ImageAddress)

    static func selectionTarget(_ selection: ImageAddress?, focusedSlot: ImageSlot,
                                containsInstruction: (UInt64) -> Bool) -> ImageAddress? {
        guard let selection, selection.slot == focusedSlot,
              containsInstruction(selection.address) else { return nil }
        return selection
    }
}

struct DisassemblyView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var debuggerViewModel: DebuggerPanelViewModel
    @StateObject private var listingCache = DisassemblyListingCache()

    // Disassembly display preferences. Reading them here (rather than leaving the keys
    // write-only) makes a Settings toggle actually re-render the listing: SwiftUI
    // re-evaluates `body` when any of these `@AppStorage` values change, rebuilding
    // `displayOptions` and so every row.
    @AppStorage(DisassemblyDisplayOptions.Key.uppercaseHex)
    private var uppercaseHex = DisassemblyDisplayOptions.default.uppercaseHex
    @AppStorage(DisassemblyDisplayOptions.Key.showInstructionBytes)
    private var showInstructionBytes = DisassemblyDisplayOptions.default.showInstructionBytes
    @AppStorage(DisassemblyDisplayOptions.Key.showAddresses)
    private var showAddresses = DisassemblyDisplayOptions.default.showAddresses
    @AppStorage(DisassemblyDisplayOptions.Key.operandSpacing)
    private var operandSpacing = DisassemblyDisplayOptions.default.operandSpacing
    // String literals reinterpret under this encoding preference. Read here so a Settings
    // change re-renders shaped string directives without an analysis re-run.
    @AppStorage(StringDisplayEncoding.storageKey)
    private var stringEncodingRaw = StringDisplayEncoding.default.rawValue

    private var displayOptions: DisassemblyDisplayOptions {
        DisassemblyDisplayOptions(
            uppercaseHex: uppercaseHex,
            showInstructionBytes: showInstructionBytes,
            showAddresses: showAddresses,
            operandSpacing: operandSpacing,
            // WS-7: reproject the focused image's addresses into the runtime space when the runtime
            // display mode is on. `.image` mode (and single-image, slide 0) leaves this at 0.
            runtimeSlide: store.addressDisplayMode == .runtime
                ? store.imageLayout.slide(store.focusedImageSlot) : 0
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Branch lanes take a leading gutter when the image has jumps to draw.
            let laneWidth = listingCache.listing.branchLanes.groups.isEmpty ? 0 : DisassemblyBranchLanes.gutterWidth
            let columns = DisassemblyColumns(
                width: proxy.size.width - laneWidth,
                coffAddressExtraWidth: showAddresses ? CGFloat(store.coffSectionAddressColumnExtraWidth) : 0
            )

            VStack(spacing: 0) {
                // WS-7: runtime-VA display toggle. Presentation only (selection/authoring stay
                // image-VA). Shown only when >1 image is loaded — for a single image the runtime
                // space equals the image VA, so the control would be a no-op.
                if store.snapshot.binaries.count >= 2 {
                    HStack(spacing: Lumen.Space.s4) {
                        Text("Addresses")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("Addresses", selection: $store.addressDisplayMode) {
                            Text("Image").tag(WorkspaceStore.AddressDisplayMode.image)
                            Text("Runtime").tag(WorkspaceStore.AddressDisplayMode.runtime)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("Show each image's own virtual addresses, or the unified runtime address space (per-image load slide applied).")
                        Spacer()
                    }
                    .padding(.horizontal, Lumen.Space.s5)
                    .padding(.vertical, Lumen.Space.s2)
                    Divider()
                }

                DisassemblyHeaderRow(columns: columns)
                    .padding(.leading, laneWidth)

                Divider()

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        let listing = listingCache.listing
                        let breakpointProjection = logicalBreakpointProjection
                        // Computed once per render: the selected instruction's basic block.
                        let currentBlock = CurrentBlockBand.resolve(
                            selection: store.selectedImageAddress,
                            blocks: store.selectedImageAddress.flatMap {
                                store.snapshot.analysis(in: $0.slot)?.basicBlocks
                            } ?? []
                        )

                        let lanes = listing.branchLanes
                        let selectedLaneRow = store.selectedImageAddress.flatMap { target in
                            target.slot == listing.slot ? lanes.endpointRows[target.address] : nil
                        }

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(listing.indexedRows) { indexedRow in
                                let index = indexedRow.index
                                let laneGutter = DisassemblyLaneGutter(
                                    lanes: lanes.lumenLanes(atRow: index, selectedRow: selectedLaneRow),
                                    row: index, width: laneWidth)
                                switch indexedRow.row {
                                case let .sectionHeader(header):
                                    DisassemblySectionHeaderRow(header: header, columns: columns, store: store)
                                        .modifier(laneGutter)
                                case let .label(label):
                                    DisassemblyLabelRow(label: label, columns: columns)
                                        .modifier(laneGutter)
                                case let .prefixComment(comment):
                                    DisassemblyPrefixCommentRow(comment: comment, columns: columns)
                                        .modifier(laneGutter)
                                case let .instruction(row):
                                    let resolved = listing.resolved[row.address]
                                    let rowTarget = ImageAddress(
                                        slot: store.focusedImageSlot,
                                        address: row.address
                                    )
                                    let callbackContext = DisassemblyRowCallbackContext.capture(
                                        imageSlot: rowTarget.slot,
                                        ownerBinaryID: store.snapshot.binary(in: rowTarget.slot)?.id,
                                        address: rowTarget.address
                                    )
                                    let breakpointGutter = logicalBreakpointGutter(
                                        at: rowTarget,
                                        projection: breakpointProjection
                                    )
                                    DisassemblyListingRow(
                                        row: resolved?.row ?? row,
                                        // For a data-marked row the decoder comment described the
                                        // (now-suppressed) code interpretation, so the builder shows
                                        // only a user comment. An own-line (prefix) comment is emitted
                                        // as a separate row above, so the inline slot here is nil.
                                        comment: resolved?.inlineComment,
                                        tag: resolved?.tag,
                                        sourceLocation: store.snapshot.sourceLine(at: rowTarget).map { entry in
                                            entry.file.map { "\($0):\(entry.line)" } ?? "line \(entry.line)"
                                        },
                                        colorTag: resolved?.colorTag,
                                        isData: resolved.map { $0.isData || $0.isUndefined } ?? false,
                                        isPatched: resolved?.isPatched ?? false,
                                        shapeDirective: resolved?.isUndefined == true
                                            ? resolved?.undefinedDirective
                                            : resolved?.shapeDirective,
                                        operandFormat: resolved?.operandFormat,
                                        displayOptions: displayOptions,
                                        coffSectionOffsetLabel: store.coffSectionOffsetLabel(for: rowTarget.address, in: rowTarget.slot),
                                        isLiveProgramCounter: store.liveProgramCounterTarget == rowTarget,
                                        isInCurrentBlock: currentBlock?.contains(rowTarget) ?? false,
                                        index: index,
                                        columns: columns,
                                        isSelected: store.selectedImageAddress == rowTarget,
                                        breakpointTarget: rowTarget,
                                        breakpointGutter: breakpointGutter,
                                        isBreakpointCatalogAvailable:
                                            store.logicalBreakpointCatalogAvailability == .available,
                                        toggleBreakpoint: {
                                            guard let callbackContext else { return }
                                            _ = callbackContext.toggleBreakpoint(in: store)
                                        },
                                        select: {
                                            guard let callbackContext else { return false }
                                            return callbackContext.select(in: store)
                                        }
                                    )
                                    // A scroll anchor keyed on the instruction address so the
                                    // live-PC auto-scroll can target this row.
                                    .modifier(laneGutter)
                                    .id(DisassemblyScrollAnchor.instruction(rowTarget))
                                }
                            }

                            DisassemblyContinuationRows(
                                startIndex: listing.indexedRows.count,
                                columns: columns
                            )
                            .padding(.leading, laneWidth + Lumen.Space.s5)
                        }
                        // U10-3 (Lumen §8, one surface per pane): bands (selection, PC, tag, patch,
                        // current block, section) run the pane's full width, so the rows take the
                        // lane gutter and the s5 side insets as padding inside their band.
                        .environment(\.disassemblyRowInsets,
                                     EdgeInsets(top: 0, leading: laneWidth + Lumen.Space.s5, bottom: 0, trailing: Lumen.Space.s5))
                        // The listing's Lumen row tints (selection, PC, tag, patch, current block)
                        // follow the editor theme, never the window theme.
                        .dsEditorSurface(ownsEveryColor: true)
                        .padding(.vertical, Lumen.Space.s4)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    // Auto-scroll the listing to the live-PC row whenever the debugger
                    // stops at a new PC. Clearing the PC (resume/exit/detach) leaves the
                    // view where it is rather than yanking it back.
                    .onChange(of: selectionScrollTarget, initial: true) { _, target in
                        guard let target else { return }
                        scrollProxy.scrollTo(DisassemblyScrollAnchor.instruction(target), anchor: .center)
                    }
                    .onChange(of: listingCache.listing.revision) { oldRevision, _ in
                        guard oldRevision == 0,
                              let target = store.liveProgramCounterTarget,
                              target.slot == store.focusedImageSlot,
                              listingCache.listing.resolved[target.address] != nil else { return }
                        scrollProxy.scrollTo(DisassemblyScrollAnchor.instruction(target), anchor: .center)
                    }
                    .onChange(of: store.liveProgramCounterTarget) { _, target in
                        guard let target, target.slot == store.focusedImageSlot,
                              listingCache.listing.resolved[target.address] != nil else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scrollProxy.scrollTo(
                                DisassemblyScrollAnchor.instruction(target),
                                anchor: .center
                            )
                        }
                    }
                }
            }
        }
        .onReceive(store.$snapshot) { snapshot in
            listingCache.snapshotDidChange(
                snapshot, slot: store.focusedImageSlot, encodingRaw: stringEncodingRaw
            )
        }
        .onChange(of: store.focusedImageSlot) { _, slot in
            listingCache.presentationDidChange(slot: slot, encodingRaw: stringEncodingRaw)
        }
        .onChange(of: stringEncodingRaw) { _, encoding in
            listingCache.presentationDidChange(slot: store.focusedImageSlot, encodingRaw: encoding)
        }
        .onDisappear { listingCache.cancel() }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                store.selectAdjacentInstruction(.previous)
            case .down:
                store.selectAdjacentInstruction(.next)
            default:
                break
            }
        }
    }

    private var selectionScrollTarget: ImageAddress? {
        DisassemblyScrollAnchor.selectionTarget(
            store.selectedImageAddress, focusedSlot: store.focusedImageSlot,
            containsInstruction: { address in
                listingCache.listing.resolved[address] != nil
            })
    }

    private var selectedInstructionAccessibilityValue: String {
        let target = store.selectedImageAddress
        let gutter = target.map {
            logicalBreakpointGutter(at: $0, projection: logicalBreakpointProjection)
        }
        return FocusedPresentationAccessibility.editorSelection(
            snapshot: store.snapshot,
            target: target,
            liveProgramCounter: store.liveProgramCounterTarget,
            breakpointGutter: gutter
        )
    }

    /// Complete durable + transient presentation projection for the shared editor/debugger session.
    /// The reducer snapshot is accepted only when its exact catalog coordinate matches, so stale
    /// session facts collapse conservatively to saved/offline inside the pure projector.
    private var logicalBreakpointProjection: DebuggerLogicalBreakpointPresentationSnapshot {
        let catalog = store.logicalBreakpointCatalogAvailability == .available
            ? store.snapshot.logicalBreakpointCatalog
            : DebuggerLogicalBreakpointCatalog.freshPristine(
                catalogID: store.snapshot.logicalBreakpointCatalog.catalogID
            )
        return DebuggerLogicalBreakpointPresentation.project(
            catalog: catalog,
            coordinate: store.logicalBreakpointCatalogCoordinate,
            reducerSnapshot: store.logicalBreakpointCatalogAvailability == .available
                ? debuggerViewModel.session.transportBreakpointBindingState : nil,
            imageIdentities: store.snapshot.binaries.map { binary in
                DebuggerLogicalBreakpointImagePresentationIdentity(
                    owner: DebuggerWorkspaceImageOwnerSeal(
                        slot: binary.slot,
                        binaryID: binary.id,
                        artifactIdentity: binary.artifactIdentity
                    ),
                    displayName: binary.name
                )
            }
        )
    }

    /// Project one exact image-qualified gutter location. An unavailable catalog never exposes its
    /// payload or looks authorable: every visible gutter becomes a disabled failure affordance that
    /// routes the user toward the dedicated repair surface through its help text.
    private func logicalBreakpointGutter(
        at target: ImageAddress,
        projection: DebuggerLogicalBreakpointPresentationSnapshot
    ) -> DebuggerLogicalBreakpointGutterPresentation {
        guard let binary = store.snapshot.binary(in: target.slot) else {
            return DebuggerLogicalBreakpointGutterPresentation(
                action: .set,
                symbol: .disabled,
                stateDescription: "Breakpoint unavailable",
                logicalBreakpointCount: 0,
                locationCount: 0,
                accessibilityLabel:
                    "Breakpoint unavailable, \(target.address.hexAddress), image owner unavailable"
            )
        }
        guard store.logicalBreakpointCatalogAvailability == .available else {
            return DebuggerLogicalBreakpointGutterPresentation(
                action: .set,
                symbol: .failure,
                stateDescription: "Breakpoint catalog unavailable",
                logicalBreakpointCount: 0,
                locationCount: 0,
                accessibilityLabel: [
                    "Breakpoint catalog unavailable",
                    binary.name,
                    target.address.hexAddress,
                    "no saved breakpoint is armed",
                ].joined(separator: ", ")
            )
        }
        return projection.gutter(
            at: target,
            owner: DebuggerWorkspaceImageOwnerSeal(
                slot: binary.slot,
                binaryID: binary.id,
                artifactIdentity: binary.artifactIdentity
            )
        )
    }
}

/// Immutable identity for one rendered disassembly row. SwiftUI may retain row and gutter
/// closures across focus changes or same-slot image replacement, so both actions revalidate the
/// exact binary UUID before selecting or mutating the row's image-qualified address.
@MainActor
struct DisassemblyRowCallbackContext {
    let target: ImageAddress
    let ownerBinaryID: UUID

    static func capture(
        imageSlot: ImageSlot,
        ownerBinaryID: UUID?,
        address: UInt64
    ) -> DisassemblyRowCallbackContext? {
        guard let ownerBinaryID else { return nil }
        return DisassemblyRowCallbackContext(
            target: ImageAddress(slot: imageSlot, address: address),
            ownerBinaryID: ownerBinaryID
        )
    }

    func select(in store: WorkspaceStore) -> Bool {
        guard ownsLiveInstruction(in: store) else { return false }
        return store.selectAddress(target)
    }

    func toggleBreakpoint(in store: WorkspaceStore) -> Bool {
        guard ownsLiveInstruction(in: store),
              store.canToggleBreakpoint(target) else { return false }
        store.toggleBreakpoint(target)
        return true
    }

    private func ownsLiveInstruction(in store: WorkspaceStore) -> Bool {
        store.focusedImageSlot == target.slot
            && store.focusedBinary?.id == ownerBinaryID
            && store.snapshot.binary(in: target.slot)?.id == ownerBinaryID
            && (store.snapshot.analysis(in: target.slot)?.instructions.contains {
                $0.address == target.address
            } == true)
    }
}

/// A context-menu command may run only after its rendered row has successfully re-established
/// selection ownership. Keeping this gate in production prevents a stale row from posting a
/// selection-keyed authoring notification against whichever image became focused later.
@MainActor
/// The basic block containing the selected instruction, as an address range in one image.
/// The block is the one with the greatest start at or before the selection, and the range ends at
/// the earlier of the block's end and the next block's start, so the band is right even if block
/// ends overlap their successors.
struct CurrentBlockBand: Equatable {
    let slot: ImageSlot
    let range: Range<UInt64>

    static func resolve(selection: ImageAddress?, blocks: [BasicBlockSummary]) -> CurrentBlockBand? {
        guard let selection, !blocks.isEmpty else { return nil }
        var owner: BasicBlockSummary?
        var nextStart = UInt64.max
        for block in blocks {
            if block.startAddress <= selection.address {
                if owner.map({ block.startAddress > $0.startAddress }) ?? true { owner = block }
            } else if block.startAddress < nextStart {
                nextStart = block.startAddress
            }
        }
        guard let owner else { return nil }
        let end = min(owner.endAddress, nextStart)
        guard selection.address < end, owner.startAddress < end else { return nil }
        return CurrentBlockBand(slot: selection.slot, range: owner.startAddress..<end)
    }

    func contains(_ target: ImageAddress) -> Bool {
        target.slot == slot && range.contains(target.address)
    }
}

struct DisassemblyRowActionGate {
    @discardableResult
    static func perform(select: () -> Bool, action: () -> Void) -> Bool {
        guard select() else { return false }
        action()
        return true
    }
}

struct DisassemblyColumns {
    let gutter: CGFloat
    let address: CGFloat
    let bytes: CGFloat
    let mnemonic: CGFloat
    let operands: CGFloat
    let comment: CGFloat

    init(width: CGFloat, coffAddressExtraWidth: CGFloat = 0) {
        let horizontalPadding: CGFloat = Lumen.Space.s5 * 2
        let isCompact = width < AppEditorChrome.disassemblyCompactWidthThreshold
        gutter = isCompact ? 28 : 34
        address = (isCompact ? 138 : min(max(width * 0.18, 150), 170)) + coffAddressExtraWidth
        bytes = isCompact ? 84 : min(max(width * 0.11, 96), 112)
        // Fits the 11-character PAuth_LR `pacnbibsppc` (81.6 pt in 12 pt semibold monospace).
        mnemonic = isCompact ? 84 : 90

        let fixed = horizontalPadding + gutter + address + bytes + mnemonic
        let flexible = max(width - fixed, AppEditorChrome.disassemblyMinimumFlexibleWidth)

        if isCompact {
            comment = min(max(flexible * 0.24, 72), 110)
        } else {
            comment = min(max(flexible * 0.34, 124), 250)
        }

        operands = max(flexible - comment, isCompact ? 132 : 180)
    }
}

extension EnvironmentValues {
    /// U10-3: the side insets a listing row takes inside its band (the lane gutter and s5 at the
    /// leading edge, s5 at the trailing edge), so every band spans the pane.
    @Entry var disassemblyRowInsets = EdgeInsets()
}

struct DisassemblyHeaderRow: View {
    let columns: DisassemblyColumns

    var body: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: columns.gutter)
            header("Address")
                .frame(width: columns.address, alignment: .leading)
            header("Bytes")
                .frame(width: columns.bytes, alignment: .leading)
            header("Mnemonic")
                .frame(width: columns.mnemonic, alignment: .leading)
            header("Operands")
                .frame(width: columns.operands, alignment: .leading)
            header("Comment")
                .frame(width: columns.comment, alignment: .leading)
        }
        .padding(.horizontal, Lumen.Space.s5)
        .frame(height: AppEditorChrome.disassemblyHeaderHeight, alignment: .center)
        // U10-3: the column header shares the pane surface; the Divider below is its hairline.
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.tableHeader)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct DisassemblyListingRow: View {
    @Environment(\.disassemblyRowInsets) private var rowInsets
    @Environment(\.commandTargetStore) private var commandTargetStore
    let row: InstructionRow
    /// The override-resolved comment (user comment wins over the decoder comment).
    let comment: String?
    /// The user's tag for this address, shown as a chip in the comment column.
    let tag: String?
    /// The recovered DWARF source location ("file.c:42") for this address, shown as a muted trailing
    /// token in the comment column. nil unless a matched dSYM has been imported. Defaulted so existing
    /// call sites are unaffected.
    var sourceLocation: String? = nil
    /// The user's highlight color for this address, tinting the row.
    let colorTag: ColorTag?
    /// When true, render the bytes as a data directive instead of the decoded
    /// instruction (the user marked this address as data).
    let isData: Bool
    /// True when the user has patched the bytes at this address (resolved from
    /// `snapshot.patch(at:)`). Drives the persistent patched-row tint + a11y label.
    var isPatched: Bool = false
    /// The pre-rendered directive for a data SHAPE (array/alignment/string) at this
    /// address, computed by the listing builder. When set it takes precedence over the
    /// plain `.long`/`.byte` derived from the raw bytes. nil for a plain data/code row.
    var shapeDirective: DataDirective? = nil
    /// The user's immediate-operand display format, applied to a decoded row.
    let operandFormat: OperandFormat?
    /// The user's disassembly *display* preferences (uppercase hex, show/hide the
    /// bytes + address columns). Read from `UserDefaults` once at the listing level and
    /// threaded in so a toggle in Settings re-renders every row. Defaults to the
    /// shipped behaviour so existing call sites are unaffected.
    var displayOptions: DisassemblyDisplayOptions = .default
    /// Original section coordinate shown beside the synthetic numeric address for bare COFF.
    var coffSectionOffsetLabel: String? = nil
    /// True when this row is the debugger's current program counter (the live-PC
    /// row). Rendered with a distinct highlight from both the breakpoint gutter and
    /// the selection. Defaults to `false`.
    var isLiveProgramCounter: Bool = false
    /// True when this row is in the same basic block as the selection: the listing's soft
    /// current-block band (Nova's current-line band, at basic-block granularity).
    var isInCurrentBlock: Bool = false
    let index: Int
    let columns: DisassemblyColumns
    let isSelected: Bool
    let breakpointTarget: ImageAddress
    let breakpointGutter: DebuggerLogicalBreakpointGutterPresentation
    let isBreakpointCatalogAvailable: Bool
    let toggleBreakpoint: () -> Void
    let select: () -> Bool
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    /// The mnemonic/operands to show: the decoded instruction, or — when marked as
    /// data — an assembler data directive derived from the raw bytes.
    private var displayed: (mnemonic: String, operands: String) {
        guard isData else {
            let operands = operandFormat.map { OperandFormat.apply(to: row.operands, format: $0) } ?? row.operands
            return (row.mnemonic, operands)
        }
        // A shaped row (Make Array/Alignment/String) renders its own directive; a plain
        // mark-as-data row falls back to the byte-derived `.long`/`.byte`.
        if let shapeDirective {
            return (shapeDirective.mnemonic, shapeDirective.operands)
        }
        return WorkspaceSnapshot.dataDirective(forBytes: row.bytes)
    }

    /// The four columns after the user's display preferences are applied (uppercase
    /// hex, hide bytes/address). Folds case + column visibility only — `displayed`
    /// already resolved data-directive / operand-format meaning.
    private var rendered: DisassemblyRowFormatter.RenderedColumns {
        DisassemblyRowFormatter.columns(
            address: row.address,
            bytes: row.bytes,
            mnemonic: displayed.mnemonic,
            operands: displayed.operands,
            options: displayOptions
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggleBreakpoint) {
                ZStack(alignment: .bottomTrailing) {
                    if isLiveProgramCounter {
                        LumenProgramCounterMarker()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: breakpointGutter.symbol.disassemblySystemImage)
                        .font(.system(size: Lumen.IconSize.small, weight: .semibold))
                        .foregroundStyle(breakpointColor)

                    if let breakpointBadgeText {
                        Text(breakpointBadgeText)
                            .font(Lumen.Font.gutterBadge)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Lumen.Space.s1)
                            .background(.lumen(.bgElevated), in: Capsule())
                            .offset(x: 3, y: 2)
                    }
                }
                .frame(width: columns.gutter, height: AppEditorChrome.disassemblyRowHeight)
            }
            .buttonStyle(.plain)
            .disabled(!isBreakpointCatalogAvailable)
            .help(breakpointControlAccessibility.help)
            .accessibilityLabel(breakpointControlAccessibility.label)
            .accessibilityHint(breakpointControlAccessibility.hint)
            .accessibilityIdentifier(breakpointControlAccessibility.identifier)

            ZStack {
                HStack(spacing: 0) {
                    HStack(spacing: Lumen.Space.s2) {
                        listingText(rendered.address, font: AppTypography.address, tone: Color.lumen(.listingSecondaryText))
                        if displayOptions.showAddresses, let coffSectionOffsetLabel {
                            listingText(coffSectionOffsetLabel, font: AppTypography.address, tone: Color.lumen(.listingSecondaryText))
                        }
                    }
                    .frame(width: columns.address, alignment: .leading)

                    listingText(rendered.bytes, font: AppTypography.bytes, tone: Color.lumen(.listingSecondaryText))
                        .frame(width: columns.bytes, alignment: .leading)

                    listingText(rendered.mnemonic, font: AppTypography.mnemonic, tone: mnemonicTone)
                        .frame(width: columns.mnemonic, alignment: .leading)

                    operandsText
                        .frame(width: columns.operands, alignment: .leading)

                    HStack(spacing: Lumen.Space.s4) {
                        if let tag, !tag.isEmpty {
                            ListingTagChip(text: tag, isSelected: false)
                        }
                        listingText(comment ?? "", font: .body, tone: .secondary)
                        if let sourceLocation, !sourceLocation.isEmpty {
                            listingText("↪ \(sourceLocation)", font: AppTypography.address,
                                        tone: Color.lumen(.listingSecondaryText))
                                .help("Source location (from imported debug symbols)")
                        }
                    }
                    .frame(width: columns.comment, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { _ = select() }
                .contextMenu { rowContextMenu }
                .focusable(true)
                .focused($isFocused)
                .focusEffectDisabled() // violet workbenchFocusRing is the sole focus affordance (no system blue)
                .accessibilityHidden(true)

                // Keep selectable SwiftUI text out of label synthesis. The existing native
                // child owns stored semantics without recursively querying its SwiftUI host.
                DisassemblyRowAccessibilityLeaf(
                    label: rowAccessibilityLabel,
                    identifier: "disassembly.row.\(breakpointTarget.slot.rawValue).\(row.address.hexAddress)",
                    help: AppAccessibilityText.disassemblyRowHint(isSelected: isSelected),
                    isSelected: isSelected,
                    press: { _ = select() }
                )
                .allowsHitTesting(false)
            }
        }
        .padding(rowInsets)
        .frame(height: AppEditorChrome.disassemblyRowHeight)
        // Lumen listing row: selection, program counter, patch,
        // color tag, current block, in that order; the selection is a tint plus an accent bar,
        // the program counter an amber tint, bar and gutter arrow. No striping.
        .dsListingRow(listingState, isActiveWindow: isActiveWindow)
        .workbenchFocusRing(isVisible: isFocused, radius: Lumen.Radius.xs)
    }

    /// The right-click menu for a listing row — the GUI affordance for the address-keyed
    /// authoring ops (Mark as Procedure, Set Local Label, Make Data). Each item first selects
    /// this row (so the selection-keyed command operates on it), then posts the same
    /// notification the menu bar uses, routing through the one shared handler. Keyboard-
    /// reachable as a context menu and mirrored by the Function menu's bound shortcuts.
    @ViewBuilder
    private var rowContextMenu: some View {
        Button(breakpointGutter.action.title) {
            _ = DisassemblyRowActionGate.perform(select: select, action: toggleBreakpoint)
        }
        .disabled(!isBreakpointCatalogAvailable)
        Divider()
        Button("Mark as Function") {
            performContextAction(.macScopeMarkAsProcedure)
        }
        Button("Mark as Undefined") {
            performContextAction(.macScopeMarkAsUndefined)
        }
        Divider()
        Button("Set Local Label...") {
            performContextAction(.macScopeSetLocalLabel)
        }
        Menu("Data") {
            Button("Make Array...") {
                performContextAction(.macScopeMakeData)
            }
            Button("Make String...") {
                performContextAction(.macScopeMakeData)
            }
            Button("Make Alignment...") {
                performContextAction(.macScopeMakeData)
            }
        }
    }

    private func performContextAction(_ name: Notification.Name) {
        DisassemblyRowActionGate.perform(select: select) {
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: Notification.commandTargetUserInfo(commandTargetStore)
            )
        }
    }

    private var listingState: LumenListingRowState {
        LumenListingRowState(
            isSelected: isSelected,
            isProgramCounter: isLiveProgramCounter,
            // A byte patch is gated by the display-options preference seam, as before.
            isPatched: displayOptions.highlightPatchedBytes && isPatched,
            tag: colorTag.flatMap { LumenTagColor(rawValue: $0.rawValue) },
            isInCurrentBlock: isInCurrentBlock
        )
    }

    private var mnemonicTone: Color {
        return isData ? Color.lumen(.syntaxAddress) : SyntaxPalette.mnemonicColor(for: displayed.mnemonic)
    }

    /// Operands as a per-token syntax-colored run (registers, immediates, addresses, labels). On a
    /// selected row we fall back to the flat selected foreground so the selection stays legible.
    @ViewBuilder
    private var operandsText: some View {
        Text(SyntaxPalette.highlightedOperands(rendered.operands, isData: isData, fallback: .primary))
            .font(AppTypography.address)
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
            .textSelection(.enabled)
    }

    /// Row label for VoiceOver, folding in the user tag and highlight color so
    /// the spoken description matches the visible chip + tint. Uses the displayed
    /// mnemonic/operands so a data-marked row is spoken as data.
    private var rowAccessibilityLabel: String {
        var label = AppAccessibilityText.disassemblyRowLabel(
            address: row.address.hexAddress,
            mnemonic: displayed.mnemonic,
            operands: displayed.operands,
            hasBreakpoint: false,
            comment: comment
        )
        if let summary = FocusedPresentationAccessibility.breakpointRowSummary(breakpointGutter) {
            label += ", \(summary)"
        }
        if let tag, !tag.isEmpty {
            label += ", tag \(tag)"
        }
        if let colorTag {
            label += ", \(colorTag.displayName) highlight"
        }
        if isPatched {
            label += ", patched"
        }
        if let sourceLocation, !sourceLocation.isEmpty {
            label += ", source \(sourceLocation)"
        }
        if isLiveProgramCounter {
            label += ", current program counter"
        }
        return label
    }

    private var breakpointColor: Color {
        switch breakpointGutter.symbol {
        case .none, .disabled:
            return DS.editorColor(.fgDisabled)
        case .saved:
            return Color.lumen(.debugBreakpoint)
        case .awaiting, .applying:
            return Color.lumen(.accent)
        case .pending, .armed:
            return Color.lumen(.statusWarning)
        case .bound, .multiple:
            return Color.lumen(.statusSuccess)
        case .failure:
            return Color.lumen(.statusDanger)
        }
    }

    private var breakpointBadgeText: String? {
        let count: Int
        if breakpointGutter.logicalBreakpointCount > 1 {
            count = breakpointGutter.logicalBreakpointCount
        } else if breakpointGutter.locationCount > 1 {
            count = breakpointGutter.locationCount
        } else {
            return nil
        }
        return count > 9 ? "9+" : String(count)
    }

    private var breakpointControlAccessibility:
        FocusedPresentationAccessibility.BreakpointGutterControlPresentation {
        FocusedPresentationAccessibility.breakpointGutterControl(
            breakpointGutter,
            target: breakpointTarget,
            isCatalogAvailable: isBreakpointCatalogAvailable
        )
    }

    private var isActiveWindow: Bool {
        controlActiveState != .inactive
    }

    private func listingText(_ text: String, font: Font, tone: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(tone)
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
            .textSelection(.enabled)
    }
}

private extension DebuggerLogicalBreakpointPresentationSymbol {
    /// Gutter-specific symbol vocabulary. Each state remains distinguishable by shape before
    /// semantic color is applied, including disabled, pending, multiple, and failure states.
    var disassemblySystemImage: String {
        switch self {
        case .none: "circle"
        case .saved: "bookmark.fill"
        case .disabled: "circle.slash"
        case .awaiting: "clock"
        case .pending: "hourglass"
        case .applying: "arrow.triangle.2.circlepath"
        case .bound: "checkmark.circle.fill"
        case .multiple: "point.3.connected.trianglepath.dotted"
        case .armed: "shield.lefthalf.filled"
        case .failure: "exclamationmark.octagon.fill"
        }
    }
}

/// A segment/section group-header row drawn at a section boundary in the listing.
struct DisassemblySectionHeaderRow: View {
    @Environment(\.disassemblyRowInsets) private var rowInsets
    let header: SectionHeaderRow
    let columns: DisassemblyColumns
    // WS-7: reproject the boundary address to the runtime space in runtime display mode, matching
    // the instruction rows below it (which reproject via DisassemblyDisplayOptions.runtimeSlide).
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        let addressText = store.displayAddressString(header.address)
        return HStack(spacing: Lumen.Space.s4) {
            Image(systemName: header.isExecutable ? "chevron.left.forwardslash.chevron.right" : "tablecells")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(header.name)
                .font(AppTypography.tableHeader)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(addressText)
                .font(AppTypography.address)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Lumen.Space.s5)
        .padding(rowInsets)
        .frame(height: AppEditorChrome.disassemblyRowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lumen(.listingAlternateRow))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Section \(header.name), \(addressText)")
    }
}

/// A standalone label row at a function start / named address, rendered as "name:".
struct DisassemblyLabelRow: View {
    @Environment(\.disassemblyRowInsets) private var rowInsets
    let label: LabelRow
    let columns: DisassemblyColumns

    var body: some View {
        HStack(spacing: 0) {
            // Align under the address column so the label sits above its instruction.
            Color.clear.frame(width: columns.gutter)

            Text("\(label.name):")
                .font(AppTypography.mnemonic)
                .foregroundStyle(Color.lumen(.syntaxAddress))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Lumen.Space.s5)
        .padding(rowInsets)
        .frame(height: AppEditorChrome.disassemblyRowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Lumen listing layout: a hairline rule above each function label.
        .overlay(alignment: .top) {
            if label.isFunctionStart {
                DSHairlineRule()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.isFunctionStart ? "Function" : "Label") \(label.name)")
    }
}

/// An own-line (prefix) comment row rendered above the instruction it annotates.
private struct DisassemblyPrefixCommentRow: View {
    @Environment(\.disassemblyRowInsets) private var rowInsets
    let comment: PrefixCommentRow
    let columns: DisassemblyColumns

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.gutter)

            Text("; \(comment.text)")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Lumen.Space.s5)
        .padding(rowInsets)
        .frame(minHeight: AppEditorChrome.disassemblyRowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Comment, \(comment.text)")
    }
}

/// A compact pill rendering a user tag inside the listing's comment column.
private struct ListingTagChip: View {
    let text: String
    let isSelected: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Lumen.Space.s4)
            .padding(.vertical, Lumen.Space.s1)
            // On a selected row the chip sits on the elevated surface with primary text: white on
            // the soft selection tint was 1.29:1 in Scope Light.
            .background(Capsule().fill(DS.editorColor(isSelected ? .bgElevated : .accentSubtle)))
            .foregroundStyle(DS.editorColor(isSelected ? .fgPrimary : .accent))
            .frame(maxWidth: AppEditorChrome.listingTagChipMaxWidth)
            // The row's accessibilityLabel already speaks the tag; keep the chip
            // out of the combined element so VoiceOver doesn't say it twice.
            .accessibilityHidden(true)
    }
}

private struct DisassemblyContinuationRows: View {
    let startIndex: Int
    let columns: DisassemblyColumns
    private let rowCount = AppEditorChrome.disassemblyContinuationRowCount

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { offset in
                HStack(spacing: 0) {
                    Color.clear.frame(width: columns.gutter)
                    Color.clear.frame(width: columns.address)
                    Color.clear.frame(width: columns.bytes)
                    Color.clear.frame(width: columns.mnemonic)
                    Color.clear.frame(width: columns.operands)
                    Color.clear.frame(width: columns.comment)
                }
                .frame(height: AppEditorChrome.disassemblyRowHeight)
                .background(rowBackground(for: startIndex + offset))
            }
        }
        .accessibilityHidden(true)
    }

    /// No striping (Lumen listing): the current-block band does that work.
    private func rowBackground(for index: Int) -> Color { .clear }
}

/// Pure scanner that extracts ARM64 register identifiers (`x0`–`x30`, `w0`–`w30`) appearing
/// as whole words in a pseudocode line, de-duplicated in first-seen order. Drives the
/// per-register entries in the pseudocode Rename Register context menu. Kept as a standalone
/// (internal) type so it can be unit-tested without exposing the private line view.
enum PseudocodeRegisterScanner {
    /// Whole-word x/w followed by 0–30 (so `x300`, `extract`, or `wx0` don't match).
    private static let pattern = #"\b([xw](?:[12]?[0-9]|30))\b"#
    private static let regex = try? NSRegularExpression(pattern: pattern)

    static func registers(in text: String) -> [String] {
        guard let regex else { return [] }
        // Scan only the CODE portion: pseudocode lines can carry a `// …` annotation (e.g. a
        // recovered call signature) whose register-like tokens are not live operands — offering
        // a rename for those would be misleading.
        let code = text.range(of: "//").map { String(text[..<$0.lowerBound]) } ?? text
        var seen: Set<String> = []
        var result: [String] = []
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in regex.matches(in: code, range: range) {
            guard let r = Range(match.range(at: 1), in: code) else { continue }
            let token = String(code[r]).lowercased()
            if seen.insert(token).inserted { result.append(token) }
        }
        return result
    }
}

/// Exact image-qualified source target captured from one frozen pseudocode render input.
/// A delayed row or context-menu callback may select only while that image still owns focus.
@MainActor
struct PseudocodeSourceSelection: Equatable {
    let target: ImageAddress
    let ownerBinaryID: UUID?

    init(imageSlot: ImageSlot, ownerBinaryID: UUID?, sourceAddress: UInt64) {
        target = ImageAddress(slot: imageSlot, address: sourceAddress)
        self.ownerBinaryID = ownerBinaryID
    }

    func select(in store: WorkspaceStore) -> Bool {
        guard let ownerBinaryID,
              store.snapshot.binary(in: target.slot)?.id == ownerBinaryID else { return false }
        return store.selectAddress(target)
    }
}

struct PseudocodeView: View {
    @ObservedObject var store: WorkspaceStore

    /// The pane's document for one render input, with the image's constant strings so printf/
    /// NSLog-family calls show the arguments their format string implies (HOP-5c).
    static func document(for input: PseudocodeRenderInput,
                         options: DecompilerOptions = DecompilerOptions(userDefaults: .standard)) -> PseudocodeDocument {
        PseudocodePrinter(options: options).print(
            functionName: input.functionName,
            startAddress: input.startAddress,
            jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors,
            constantStrings: input.constantStrings,
            nameOverrides: input.nameOverrides,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets,
            machineCallUsage: input.machineCallUsage,
            machineUsageContext: input.machineUsageContext,
            ownDirectCallAddresses: input.ownDirectCallAddresses,
            knownTailCallTargets: input.knownTailCallTargets,
            registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides,
            resolvedIndirectCalls: input.resolvedIndirectCalls,
            slotCallContracts: input.slotCallContracts,
            callerReturnWidth: input.callerReturnWidth,
            callerReturnType: input.callerReturnType,
            types: input.types,
            instructions: input.instructions
        )
    }

    var body: some View {
        // Capture one focused-image aggregate so every printer input belongs to the
        // same binary even when multiple images contain the same virtual address.
        let input = store.focusedPseudocodeRenderInput
        let document = Self.document(for: input)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.lines) { line in
                    let sourceSelection = line.sourceAddress.map {
                        PseudocodeSourceSelection(
                            imageSlot: input.imageSlot,
                            ownerBinaryID: store.snapshot.binary(in: input.imageSlot)?.id,
                            sourceAddress: $0
                        )
                    }
                    PseudocodeLineView(
                        line: line,
                        isSelected: sourceSelection?.target == store.selectedImageAddress
                    ) {
                        guard let sourceSelection else { return false }
                        // SwiftUI delivers tap/context-menu actions on the main actor. Keep the
                        // exact selection result synchronous so stale callbacks can suppress the
                        // follow-on register-rename notification.
                        return MainActor.assumeIsolated {
                            sourceSelection.select(in: store)
                        }
                    }
                }
            }
            .padding(.vertical, Lumen.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                store.selectAdjacentInstruction(.previous)
            case .down:
                store.selectAdjacentInstruction(.next)
            default:
                break
            }
        }
        .workbenchPaneBackground(.editor)
        .accessibilityLabel("Pseudocode editor")
        .accessibilityHint("Use arrow keys to move between source instructions.")
    }
}

private struct PseudocodeLineView: View {
    @Environment(\.commandTargetStore) private var commandTargetStore
    let line: PseudocodeLine
    let isSelected: Bool
    let select: () -> Bool
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s6) {
            Text(String(format: "%3d", line.lineNumber))
                .font(AppTypography.lineNumber)
                .foregroundStyle(Color.lumen(.listingSecondaryText))
                .frame(width: AppEditorChrome.pseudocodeLineNumberWidth, alignment: .trailing)

            Text(line.addressText ?? "")
                .font(AppTypography.lineNumber)
                .foregroundStyle(Color.lumen(.listingSecondaryText))
                .frame(width: AppEditorChrome.pseudocodeAddressWidth, alignment: .leading)

            Text(line.text)
                .font(AppTypography.pseudocode)
                .foregroundStyle(color(for: line.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Lumen.Space.s7)
        .frame(minHeight: AppEditorChrome.pseudocodeRowMinHeight)
        .background(isSelected ? AppInteractionChrome.selectedTokenFill(isActiveWindow: isActiveWindow, editorSurface: true) : Color.clear)
        .workbenchFocusRing(isVisible: isFocused, radius: Lumen.Radius.xs)
        .contentShape(Rectangle())
        .onTapGesture { _ = select() }
        .contextMenu { lineContextMenu }
        .focusable(line.sourceAddress != nil)
        .focused($isFocused)
        .focusEffectDisabled() // violet workbenchFocusRing is the sole focus affordance (no system blue)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(line.sourceAddress == nil ? "Pseudocode structure" : "Selects the source instruction")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The right-click menu for a pseudocode line — the GUI affordance for register renaming
    /// (the previously scripting-only `rename-register`). Each item selects the line's source
    /// instruction (so the rename keys to the enclosing procedure) then posts
    /// `.macScopeRenameRegister`; a register detected in the line text is passed as the
    /// notification object to pre-fill the sheet, with a generic entry always available.
    @ViewBuilder
    private var lineContextMenu: some View {
        let registers = PseudocodeRegisterScanner.registers(in: line.text)
        if !registers.isEmpty {
            ForEach(registers, id: \.self) { register in
                Button("Rename Register \(register)...") {
                    guard select() else { return }
                    NotificationCenter.default.post(name: .macScopeRenameRegister, object: register, userInfo: Notification.commandTargetUserInfo(commandTargetStore))
                }
            }
            Divider()
        }
        Button("Rename Register...") {
            guard select() else { return }
            NotificationCenter.default.post(name: .macScopeRenameRegister, object: nil, userInfo: Notification.commandTargetUserInfo(commandTargetStore))
        }
    }

    private var accessibilityLabel: String {
        if let addressText = line.addressText {
            return "Line \(line.lineNumber), \(addressText), \(line.text)"
        }
        return "Line \(line.lineNumber), \(line.text)"
    }

    private var isActiveWindow: Bool {
        controlActiveState != .inactive
    }

    private func color(for kind: PseudocodeLineKind) -> Color {
        switch kind {
        case .signature, .closingBrace:
            return .primary
        case .metadata:
            return .secondary
        case .declaration:
            return Color.lumen(.syntaxAddress)
        case .instruction:
            return .primary
        }
    }
}

/// The one production graph builder used by both `GraphView` and focused graph tests. It accepts
/// only a frozen one-image projection, so layout and interaction identity cannot consult a flat
/// primary-image workspace projection partway through a render.
enum FocusedGraphBuilder {
    /// The graph's node selection targets in `build`'s node order, without laying out or routing
    /// anything. The store's selection sync needs only these; building the whole graph for them
    /// stalled imports of large binaries (Tier 2b: /usr/bin/vim).
    static func selectionTargets(_ projection: FocusedGraphProjection) -> [GraphSelectionTarget] {
        graphSections(projection: projection, metrics: GraphLayoutMetrics(viewport: .zero))
            .flatMap { $0.nodes.map(\.selectionTarget) }
    }

    static func build(_ projection: FocusedGraphProjection, viewport: CGSize, layered: Bool = false) -> FocusedGraphModel {
        let metrics = GraphLayoutMetrics(viewport: viewport)
        var sections = graphSections(projection: projection, metrics: metrics)
        var nodes: [GraphNodeModel] = []

        for sectionIndex in sections.indices {
            let laneX = metrics.outerMargin + CGFloat(sectionIndex) * (metrics.laneWidth + metrics.laneGap)
            sections[sectionIndex].origin = CGPoint(x: laneX, y: metrics.outerMargin)
            sections[sectionIndex].width = metrics.laneWidth

            for nodeIndex in sections[sectionIndex].nodes.indices {
                var node = sections[sectionIndex].nodes[nodeIndex]
                node.center = CGPoint(
                    x: laneX + metrics.laneWidth / 2,
                    y: metrics.outerMargin
                        + metrics.headerHeight
                        + metrics.nodeTopPadding
                        + CGFloat(nodeIndex) * (metrics.nodeSize.height + metrics.nodeVerticalGap)
                        + metrics.nodeSize.height / 2
                )
                node.size = metrics.nodeSize
                sections[sectionIndex].nodes[nodeIndex] = node
                nodes.append(node)
            }

            sections[sectionIndex].height = max(
                metrics.minimumLaneHeight,
                metrics.headerHeight
                    + metrics.nodeTopPadding
                    + CGFloat(max(sections[sectionIndex].nodes.count, 1)) * metrics.nodeSize.height
                    + CGFloat(max(sections[sectionIndex].nodes.count - 1, 0)) * metrics.nodeVerticalGap
                    + metrics.outerMargin
            )
        }

        let canvasWidth = metrics.outerMargin * 2
            + CGFloat(max(sections.count, 1)) * metrics.laneWidth
            + CGFloat(max(sections.count - 1, 0)) * metrics.laneGap
        let canvasHeight = metrics.outerMargin * 2
            + max(sections.map(\.height).max() ?? metrics.minimumLaneHeight, metrics.minimumLaneHeight)

        // One function's blocks get the layered (Sugiyama) layout; the image overview keeps one
        // stacked lane per function. A graph over the layered caps falls back to the stack and
        // says so.
        var layoutNote: String?
        if layered, sections.count == 1, nodes.count > 1, nodes.allSatisfy({ $0.kind == .basicBlock }) {
            switch layeredModel(projection: projection, section: sections[0], metrics: metrics) {
            case .success(let model): return model
            case .failure(let refusal): layoutNote = refusal.message
            }
        }

        return FocusedGraphModel(
            imageSlot: projection.imageSlot,
            sections: sections,
            nodes: nodes,
            edges: graphEdges(projection: projection, nodes: nodes),
            nodeSize: metrics.nodeSize,
            canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
            layoutNote: layoutNote
        )
    }

    /// Lays one function's blocks out in layers: ranks from the entry with back edges removed,
    /// barycenter crossing reduction, and routed polylines; loops are flagged as back edges.
    private static func layeredModel(
        projection: FocusedGraphProjection,
        section: GraphFunctionSectionModel,
        metrics: GraphLayoutMetrics
    ) -> Result<FocusedGraphModel, LayeredGraphLayout.Refusal> {
        var nodes = section.nodes
        let inputs = edgeInputs(projection: projection)
        let index = GraphNodeIndex(nodes)
        let slotByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        var layeredEdges: [LayeredGraphLayout.EdgeInput] = []
        var inputForLayeredEdge: [Int] = []
        for (inputIndex, edge) in inputs.enumerated() {
            guard let source = index.first(containing: ImageAddress(slot: projection.imageSlot, address: edge.from)),
                  let target = index.first(containing: ImageAddress(slot: projection.imageSlot, address: edge.to),
                                           orStartingAt: edge.to),
                  let from = slotByID[source.id], let to = slotByID[target.id] else { continue }
            layeredEdges.append(.init(from: from, to: to))
            inputForLayeredEdge.append(inputIndex)
        }
        let gap = max(metrics.laneGap * 0.75, 36)
        let layoutMetrics = LayeredGraphLayout.Metrics(
            nodeSize: metrics.nodeSize, horizontalGap: gap, layerGap: metrics.nodeVerticalGap + 22, margin: 0)
        let layout: LayeredGraphLayout
        switch LayeredGraphLayout.layout(nodeCount: nodes.count, entry: nodes.firstIndex(where: \.isEntry) ?? 0,
                                         edges: layeredEdges, metrics: layoutMetrics) {
        case .success(let value): layout = value
        case .failure(let refusal): return .failure(refusal)
        }
        // The lane frames the layered drawing: header on top, the drawing inset by the lane padding.
        let inset = metrics.nodeTopPadding
        let origin = CGPoint(x: metrics.outerMargin + inset,
                             y: metrics.outerMargin + metrics.headerHeight + metrics.nodeTopPadding)
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + origin.x, y: point.y + origin.y) }
        for i in nodes.indices {
            nodes[i].center = shifted(layout.centers[i])
            nodes[i].size = metrics.nodeSize
        }
        var sectionModel = section
        sectionModel.nodes = nodes
        sectionModel.origin = CGPoint(x: metrics.outerMargin, y: metrics.outerMargin)
        sectionModel.width = max(metrics.laneWidth, layout.size.width + inset * 2)
        sectionModel.height = max(metrics.minimumLaneHeight,
                                  metrics.headerHeight + metrics.nodeTopPadding * 2 + layout.size.height)
        var routes: [Int: LayeredGraphLayout.RoutedEdge] = [:]
        for routed in layout.edges {
            var shiftedRoute = routed
            shiftedRoute.points = routed.points.map(shifted)
            routes[inputForLayeredEdge[routed.index]] = shiftedRoute
        }
        return .success(FocusedGraphModel(
            imageSlot: projection.imageSlot,
            sections: [sectionModel],
            nodes: nodes,
            edges: graphEdges(projection: projection, nodes: nodes, routes: routes),
            nodeSize: metrics.nodeSize,
            canvasSize: CGSize(width: sectionModel.width + metrics.outerMargin * 2,
                               height: sectionModel.height + metrics.outerMargin * 2)
        ))
    }

    private static func graphSections(
        projection: FocusedGraphProjection,
        metrics: GraphLayoutMetrics
    ) -> [GraphFunctionSectionModel] {
        let functions = projection.functions.sorted {
            GraphElementOrdering.isOrderedBefore(
                address: $0.startAddress,
                id: $0.id,
                than: $1.startAddress,
                id: $1.id
            )
        }
        let knownFunctionIDs = Set(functions.map(\.id))
        let blocksByFunction = Dictionary(grouping: projection.basicBlocks, by: \.functionID)
        // U9-5: sorted once, so each block-less function counts its rows by binary search instead
        // of scanning every instruction (functions × instructions cost ~17 s opening vim).
        let instructionAddresses = InstructionAddressIndex(projection.instructions)
        var sections: [GraphFunctionSectionModel] = []

        for function in functions {
            let sortedBlocks = (blocksByFunction[function.id] ?? []).sorted {
                GraphElementOrdering.isOrderedBefore(
                    address: $0.startAddress,
                    id: $0.id,
                    than: $1.startAddress,
                    id: $1.id
                )
            }
            let functionPresentation = projection.presentationByAddress[function.startAddress]
            let functionName = functionPresentation?.customName ?? function.name
            let nodes: [GraphNodeModel]

            if sortedBlocks.isEmpty {
                let target = selectionTarget(
                    imageSlot: projection.imageSlot,
                    ownerBinaryID: projection.ownerBinaryID,
                    elementID: "function:\(function.id.uuidString)",
                    title: functionName,
                    startAddress: function.startAddress,
                    endAddress: function.endAddress,
                    functionID: function.id
                )
                nodes = [GraphNodeModel(
                    selectionTarget: target,
                    title: functionName,
                    subtitle: function.startAddress.hexAddress,
                    instructionCount: instructionAddresses.count(in: target),
                    confidence: function.confidence,
                    kind: .function,
                    functionName: functionName,
                    ordinal: nil,
                    isEntry: true,
                    tag: functionPresentation?.tag,
                    colorTag: functionPresentation?.colorTag
                )]
            } else {
                nodes = sortedBlocks.enumerated().map { index, block in
                    let target = selectionTarget(
                        imageSlot: projection.imageSlot,
                        ownerBinaryID: projection.ownerBinaryID,
                        elementID: "block:\(block.id.uuidString)",
                        title: index == 0 ? "Entry block" : "Block \(index + 1)",
                        startAddress: block.startAddress,
                        endAddress: block.endAddress,
                        functionID: function.id
                    )
                    let presentation = projection.presentationByAddress[block.startAddress]
                    return GraphNodeModel(
                        selectionTarget: target,
                        title: target.title,
                        subtitle: "\(block.startAddress.hexAddress) - \(block.endAddress.hexAddress)",
                        instructionCount: block.instructionCount,
                        confidence: function.confidence,
                        kind: .basicBlock,
                        functionName: functionName,
                        ordinal: index + 1,
                        isEntry: index == 0,
                        tag: presentation?.tag,
                        colorTag: presentation?.colorTag
                    )
                }
            }

            sections.append(GraphFunctionSectionModel(
                id: qualifiedID(imageSlot: projection.imageSlot, elementID: "function:\(function.id.uuidString)"),
                title: functionName,
                subtitle: function.startAddress.hexAddress,
                confidence: function.confidence,
                blockCount: max(sortedBlocks.count, nodes.count),
                nodes: nodes,
                width: metrics.laneWidth
            ))
        }

        let orphanBlocks = projection.basicBlocks
            .filter { !knownFunctionIDs.contains($0.functionID) }
            .sorted {
                GraphElementOrdering.isOrderedBefore(
                    address: $0.startAddress,
                    id: $0.id,
                    than: $1.startAddress,
                    id: $1.id
                )
            }

        if !orphanBlocks.isEmpty {
            let nodes = orphanBlocks.enumerated().map { index, block in
                let target = selectionTarget(
                    imageSlot: projection.imageSlot,
                    ownerBinaryID: projection.ownerBinaryID,
                    elementID: "block:\(block.id.uuidString)",
                    title: index == 0 ? "Entry block" : "Block \(index + 1)",
                    startAddress: block.startAddress,
                    endAddress: block.endAddress,
                    functionID: nil
                )
                let presentation = projection.presentationByAddress[block.startAddress]
                return GraphNodeModel(
                    selectionTarget: target,
                    title: target.title,
                    subtitle: "\(block.startAddress.hexAddress) - \(block.endAddress.hexAddress)",
                    instructionCount: block.instructionCount,
                    confidence: 0,
                    kind: .basicBlock,
                    functionName: "Unowned blocks",
                    ordinal: index + 1,
                    isEntry: index == 0,
                    tag: presentation?.tag,
                    colorTag: presentation?.colorTag
                )
            }

            sections.append(GraphFunctionSectionModel(
                id: qualifiedID(imageSlot: projection.imageSlot, elementID: "unowned-blocks"),
                title: "Unowned blocks",
                subtitle: String(AttributedString(localized: "^[\(orphanBlocks.count) block](inflect: true)").characters),
                confidence: 0,
                blockCount: orphanBlocks.count,
                nodes: nodes,
                width: metrics.laneWidth
            ))
        }

        if sections.isEmpty,
           let instructionRange = projection.sparseInstructionRange,
           let firstInstruction = projection.instructions.first {
            let target = selectionTarget(
                imageSlot: projection.imageSlot,
                ownerBinaryID: projection.ownerBinaryID,
                elementID: "instructions:\(firstInstruction.address.hexAddress)",
                title: "Instruction range",
                startAddress: instructionRange.lowerBound,
                endAddress: instructionRange.upperBound,
                functionID: nil
            )
            let presentation = projection.presentationByAddress[firstInstruction.address]
            let fallbackNode = GraphNodeModel(
                selectionTarget: target,
                title: target.title,
                subtitle: "\(instructionRange.lowerBound.hexAddress) - \(instructionRange.upperBound.hexAddress)",
                instructionCount: projection.instructions.count,
                confidence: 0,
                kind: .basicBlock,
                functionName: "Instructions",
                ordinal: nil,
                isEntry: true,
                tag: presentation?.tag,
                colorTag: presentation?.colorTag
            )

            sections.append(GraphFunctionSectionModel(
                id: qualifiedID(imageSlot: projection.imageSlot, elementID: "instruction-range"),
                title: "Instructions",
                subtitle: String(AttributedString(localized: "^[\(projection.instructions.count) row](inflect: true)").characters),
                confidence: 0,
                blockCount: 1,
                nodes: [fallbackNode],
                width: metrics.laneWidth
            ))
        }

        return sections
    }

    /// Control-flow edges first, then xrefs whose endpoints and kind no CFG edge already covers.
    private static func edgeInputs(projection: FocusedGraphProjection) -> [GraphEdgeInput] {
        var edgeInputs = projection.controlFlowEdges.map {
            GraphEdgeInput(elementID: "cfg:\($0.id.uuidString)", from: $0.from, to: $0.to, kind: $0.kind)
        }
        var seenEdgeKeys = Set(edgeInputs.map(\.dedupeKey))

        for xref in projection.xrefs {
            let input = GraphEdgeInput(
                elementID: "xref:\(xref.id.uuidString)",
                from: xref.from,
                to: xref.to,
                kind: xref.kind
            )
            if seenEdgeKeys.insert(input.dedupeKey).inserted {
                edgeInputs.append(input)
            }
        }
        return edgeInputs
    }

    /// `routes`, keyed by `edgeInputs` index, replaces the Bézier shaping with a layered route.
    private static func graphEdges(
        projection: FocusedGraphProjection,
        nodes: [GraphNodeModel],
        routes: [Int: LayeredGraphLayout.RoutedEdge] = [:]
    ) -> [GraphEdgeModel] {
        let edgeInputs = edgeInputs(projection: projection)
        let conditionalSources = LumenGraphEdgeKind.conditionalSources(
            projection.controlFlowEdges.map { (from: $0.from, kind: $0.kind) }
        )
        var pairOffsets: [String: Int] = [:]
        let index = GraphNodeIndex(nodes)
        return edgeInputs.enumerated().compactMap { inputIndex, edge in
            let from = ImageAddress(slot: projection.imageSlot, address: edge.from)
            let to = ImageAddress(slot: projection.imageSlot, address: edge.to)
            guard
                let source = index.first(containing: from),
                let target = index.first(containing: to, orStartingAt: edge.to)
            else {
                return nil
            }

            let pairKey = "\(source.id)->\(target.id)"
            let offsetIndex = pairOffsets[pairKey, default: 0]
            pairOffsets[pairKey] = offsetIndex + 1
            let route = GraphEdgeRoute(source: source, target: target, offsetIndex: offsetIndex)
            let selectionTarget = GraphEdgeSelectionTarget(
                imageSlot: projection.imageSlot,
                ownerBinaryID: projection.ownerBinaryID,
                elementID: edge.elementID,
                fromAddress: edge.from,
                toAddress: edge.to,
                kind: edge.kind
            )

            var model = GraphEdgeModel(
                selectionTarget: selectionTarget,
                fromPoint: route.from,
                toPoint: route.to,
                control1: route.control1,
                control2: route.control2,
                labelPoint: route.labelPoint,
                arrowAngle: route.arrowAngle,
                sourceTitle: source.displayTitle,
                targetTitle: target.displayTitle,
                isConditionalSource: conditionalSources.contains(edge.from)
            )
            if let layered = routes[inputIndex], layered.points.count >= 2 {
                model.applyLayeredRoute(layered.points, isBackEdge: layered.isBackEdge)
            }
            return model
        }
    }

    private static func selectionTarget(
        imageSlot: ImageSlot,
        ownerBinaryID: UUID?,
        elementID: String,
        title: String,
        startAddress: UInt64,
        endAddress: UInt64,
        functionID: UUID?
    ) -> GraphSelectionTarget {
        GraphSelectionTarget(
            id: qualifiedID(imageSlot: imageSlot, elementID: elementID),
            imageSlot: imageSlot,
            ownerBinaryID: ownerBinaryID,
            title: title,
            startAddress: startAddress,
            endAddress: endAddress,
            functionID: functionID
        )
    }

    private static func qualifiedID(imageSlot: ImageSlot, elementID: String) -> String {
        "image:\(imageSlot.rawValue):\(elementID)"
    }

}

/// The focused graph's instruction addresses, sorted once, so a node counts the rows in its range
/// with two binary searches (U9-5). Counts match `GraphSelectionTarget.contains`: the half-open
/// `[start, end)` when `end > start`, else rows exactly at `start`; every row counts, duplicates
/// included.
struct InstructionAddressIndex {
    private let addresses: [UInt64]

    init(_ instructions: [InstructionRow]) {
        addresses = instructions.map(\.address).sorted()
    }

    func count(in target: GraphSelectionTarget) -> Int {
        let end = target.endAddress > target.startAddress ? target.endAddress : target.startAddress &+ 1
        guard end > target.startAddress else {
            // `start` is UInt64.max with an empty range: only rows exactly there.
            return addresses.count - firstIndex(atLeast: target.startAddress)
        }
        return firstIndex(atLeast: end) - firstIndex(atLeast: target.startAddress)
    }

    private func firstIndex(atLeast address: UInt64) -> Int {
        var low = 0, high = addresses.count
        while low < high {
            let mid = (low + high) / 2
            if addresses[mid] < address { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Routes GraphView move commands through the store's history-neutral adjacent-node operation.
/// Keeping this tiny seam testable prevents a view-local selection shortcut from turning routine
/// keyboard traversal into Back/Forward history entries.
@MainActor
enum GraphKeyboardNavigation {
    static func move(_ direction: MoveCommandDirection, in store: WorkspaceStore,
                     targets: [GraphSelectionTarget]) {
        guard !targets.isEmpty else { return }
        let current = targets.firstIndex { $0.id == store.selectedGraphElementID }
            ?? targets.firstIndex { $0.contains(store.selectedImageAddress) }
        let index: Int
        switch direction {
        case .up, .left: index = current.map { ($0 - 1 + targets.count) % targets.count } ?? targets.count - 1
        case .down, .right: index = current.map { ($0 + 1) % targets.count } ?? 0
        @unknown default: return
        }
        // Store admission revalidates the captured binary owner and exact current node.
        _ = store.selectGraphNode(targets[index])
    }

    static func move(_ direction: MoveCommandDirection, in store: WorkspaceStore) {
        switch direction {
        case .up, .left:
            store.selectAdjacentGraphNode(.previous)
        case .down, .right:
            store.selectAdjacentGraphNode(.next)
        @unknown default:
            break
        }
    }
}

enum GraphFunctionScope {
    static func project(_ source: FocusedGraphProjection, selection: ImageAddress?) -> FocusedGraphProjection? {
        guard source.ownerBinaryID != nil, let selection, selection.slot == source.imageSlot else { return nil }
        let candidates = source.functions.filter {
            $0.endAddress > $0.startAddress && selection.address >= $0.startAddress && selection.address < $0.endAddress
        }
        guard candidates.count == 1, let function = candidates.first else { return nil }
        let blocks = source.basicBlocks.filter { $0.functionID == function.id }
        guard !blocks.isEmpty, blocks.allSatisfy({
            $0.startAddress >= function.startAddress && $0.endAddress <= function.endAddress
                && $0.endAddress > $0.startAddress
        }) else { return nil }
        // Conflicting ownership of the same bytes cannot prove a function-local graph.
        guard !source.basicBlocks.contains(where: { other in
            other.functionID != function.id && blocks.contains {
                $0.startAddress < other.endAddress && other.startAddress < $0.endAddress
            }
        }) else { return nil }
        func contains(_ address: UInt64) -> Bool {
            blocks.contains { address >= $0.startAddress && address < $0.endAddress }
        }
        guard contains(selection.address) else { return nil }
        return FocusedGraphProjection(imageSlot: source.imageSlot, ownerBinaryID: source.ownerBinaryID,
            functions: [function], basicBlocks: blocks,
            instructions: source.instructions.filter { contains($0.address) },
            controlFlowEdges: source.controlFlowEdges.filter { contains($0.from) && contains($0.to) },
            xrefs: source.xrefs.filter { contains($0.from) && contains($0.to) },
            presentationByAddress: source.presentationByAddress.filter {
                $0.key == function.startAddress || contains($0.key)
            })
    }
}

/// What the Graph editor draws: the selected function's blocks (layered), its call graph, or
/// every function of the image as stacked lanes.
enum GraphScope: String, CaseIterable, Hashable {
    case function
    case callGraph
    case overview

    var title: String {
        switch self {
        case .function: "Selected function"
        case .callGraph: "Call graph"
        case .overview: "Image overview"
        }
    }
}

struct GraphView: View {
    @ObservedObject var store: WorkspaceStore

    /// The scroll content's current top-left offset within the canvas, tracked via a
    /// coordinate-space preference so the minimap can draw an accurate viewport rect.
    /// Positive values mean the content has scrolled up/left under the viewport.
    @State private var scrollOffset: CGPoint = .zero
    @State private var scope: GraphScope = .function
    @State private var callGraphDepth = 2
    /// Graph zoom (⌘= / ⌘− / ⌘0) per scope; the canvas is scaled, layout and hit testing stay in
    /// layout space. Each scope opens at `GraphZoomState.openingZoom`, which ⌘0 restores.
    @State private var zoomState = GraphZoomState()
    private var zoom: CGFloat { zoomState.zoom(for: scope) }
    private var zoomBinding: Binding<CGFloat> {
        Binding(get: { zoomState.zoom(for: scope) }, set: { zoomState.set($0, for: scope) })
    }

    private var showsImageOverview: Bool { scope == .overview }

    private static let graphCanvasSpace = "graph-canvas"

    var body: some View {
        // Freeze exactly one focused aggregate for this layout pass. Every node, edge,
        // presentation value, callback target, minimap mark, and accessibility value below comes
        // from the model built from this one value.
        let imageProjection = store.focusedGraphProjection
        let functionProjection = GraphFunctionScope.project(imageProjection, selection: store.selectedImageAddress)
        let projection = showsImageOverview ? imageProjection : functionProjection ?? FocusedGraphProjection(
            imageSlot: imageProjection.imageSlot, ownerBinaryID: imageProjection.ownerBinaryID,
            functions: [], basicBlocks: [], instructions: [], controlFlowEdges: [], xrefs: [], presentationByAddress: [:])
        let focusedBinaryName = store.snapshot.binaries.count > 1
            ? store.snapshot.binary(in: projection.imageSlot)?.name
                ?? "Image slot \(projection.imageSlot.rawValue)"
            : nil

        GeometryReader { proxy in
            let layout = FocusedGraphBuilder.build(projection, viewport: proxy.size, layered: scope == .function)
            VStack(spacing: 0) {
                // Lumen pill switcher.
                HStack(spacing: Lumen.Space.s4) {
                    LumenModeSwitcher(selection: $scope, options: GraphScope.allCases, style: .pill) { $0.title }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Graph scope")
                        .accessibilityIdentifier("graph.scope")
                    Spacer(minLength: Lumen.Space.s4)
                    if scope != .callGraph {
                        GraphZoomControls(zoom: zoomBinding)
                    }
                }
                .padding(Lumen.Space.s5)
                Divider()
            if scope == .callGraph {
                CallGraphPanel(store: store, projection: imageProjection, depth: $callGraphDepth,
                               focusedBinaryName: focusedBinaryName)
            } else {
            Group {
                if layout.nodes.count > GraphRenderBudget.maximumDrawnNodes {
                    EmptyStateView(
                        title: "Graph too large to draw",
                        detail: "This image's overview has \(layout.nodes.count) blocks, over the \(GraphRenderBudget.maximumDrawnNodes)-block limit. Choose Selected function or Call graph.",
                        systemImage: "lumen.callGraph"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if layout.nodes.isEmpty {
                    EmptyStateView(
                        title: showsImageOverview ? "No graph data" : "Function graph unavailable",
                        detail: showsImageOverview
                            ? "This image has no discovered functions or basic blocks to draw."
                            : "Select a function with proven basic-block ownership in the focused image, or choose Image overview.",
                        systemImage: "lumen.callGraph"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        GraphOverviewBar(
                            layout: layout,
                            focusedBinaryName: focusedBinaryName,
                            selectedAddress: store.selectedImageAddress,
                            selectedGraphElementID: store.selectedGraphElementID
                        )

                        Divider()

                        if let note = layout.layoutNote {
                            Label(note, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Lumen.Space.s5)
                                .padding(.vertical, Lumen.Space.s3)
                                .accessibilityIdentifier("graph.layoutNote")
                            Divider()
                        }

                        let canvasSize = CGSize(
                            width: max(proxy.size.width, layout.canvasSize.width),
                            height: max(proxy.size.height, layout.canvasSize.height)
                        )

                        ScrollView([.horizontal, .vertical]) {
                            ZStack(alignment: .topLeading) {
                                GeometryReader { contentProxy in
                                    Color.clear.preference(
                                        key: GraphScrollOffsetKey.self,
                                        value: CGPoint(
                                            x: -contentProxy.frame(in: .named(Self.graphCanvasSpace)).minX,
                                            y: -contentProxy.frame(in: .named(Self.graphCanvasSpace)).minY
                                        )
                                    )
                                }
                                .frame(width: 0, height: 0)
                                .accessibilityHidden(true)

                                if GraphRenderBudget.drawsAsCanvas(layout) {
                                    // Large graphs draw in one Canvas: one SwiftUI view per node
                                    // exhausted the attribute graph on a 914-function overview.
                                    GraphLargeCanvas(
                                        layout: layout,
                                        selectedAddress: store.selectedImageAddress,
                                        selectedEdgeID: store.selectedGraphElementID,
                                        onSelect: { node in _ = store.selectGraphNode(node.selectionTarget) }
                                    )
                                    .frame(width: canvasSize.width, height: canvasSize.height)
                                } else {
                                    ForEach(layout.sections) { section in
                                        GraphFunctionLaneView(section: section)
                                            .frame(width: section.width, height: section.height)
                                            .position(x: section.center.x, y: section.center.y)
                                            .accessibilityHidden(true)
                                    }

                                    ForEach(layout.edges) { edge in
                                        let isSelected = store.selectedGraphElementID == edge.id

                                        GraphEdgeShape(
                                            from: edge.fromPoint,
                                            to: edge.toPoint,
                                            control1: edge.control1,
                                            control2: edge.control2,
                                            waypoints: edge.waypoints
                                        )
                                        .stroke(
                                            edge.strokeColor(isSelected: isSelected),
                                            style: StrokeStyle(
                                                lineWidth: edge.strokeWidth(isSelected: isSelected),
                                                lineCap: .round,
                                                lineJoin: .round,
                                                dash: isSelected ? [] : edge.dash
                                            )
                                        )
                                        .accessibilityHidden(true)

                                        GraphArrowHead(color: edge.strokeColor(isSelected: isSelected))
                                            .frame(width: AppGraphChrome.arrowHeadSize, height: AppGraphChrome.arrowHeadSize)
                                            .rotationEffect(.radians(edge.arrowAngle))
                                            .position(edge.toPoint)
                                            .accessibilityHidden(true)

                                        GraphEdgeLabelView(
                                            edge: edge,
                                            focusedBinaryName: focusedBinaryName,
                                            isSelected: isSelected
                                        ) {
                                            _ = store.selectGraphEdge(edge.selectionTarget)
                                        }
                                        .position(edge.labelPoint)
                                    }

                                    ForEach(layout.nodes) { node in
                                        let nodeAddress = ImageAddress(slot: layout.imageSlot, address: node.startAddress)
                                        GraphNodeView(
                                            node: node,
                                            focusedBinaryName: focusedBinaryName,
                                            state: nodeState(for: node),
                                            isMultiSelected: store.graphNodeMultiSelection.contains(nodeAddress),
                                            selectedAddress: store.selectedImageAddress,
                                            width: layout.nodeSize.width,
                                            height: layout.nodeSize.height,
                                            onSelect: {
                                                _ = store.selectGraphNode(node.selectionTarget)
                                            },
                                            onToggleMultiSelect: {
                                                _ = store.toggleGraphNodeMultiSelection(node.selectionTarget)
                                            }
                                        )
                                        .position(x: node.center.x, y: node.center.y)
                                    }
                                }
                            }
                            .frame(
                                width: canvasSize.width,
                                height: canvasSize.height,
                                alignment: .topLeading
                            )
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
                        }
                        .coordinateSpace(name: Self.graphCanvasSpace)
                        .onPreferenceChange(GraphScrollOffsetKey.self) { offset in
                            scrollOffset = offset
                        }
                        .workbenchPaneBackground(.editor)
                        .overlay(alignment: .top) {
                            let capturedSelection = sortedGraphSelection
                            if !capturedSelection.isEmpty {
                                GraphNodeGroupBar(
                                    focusedBinaryName: focusedBinaryName,
                                    selectionCount: capturedSelection.count,
                                    onApplyColor: { color in
                                        _ = store.setGraphColorTag(at: capturedSelection, color: color)
                                    },
                                    onClearColor: {
                                        _ = store.setGraphColorTag(at: capturedSelection, color: nil)
                                    },
                                    onDismiss: {
                                        guard Set(capturedSelection) == store.graphNodeMultiSelection else { return }
                                        store.clearGraphNodeMultiSelection()
                                    }
                                )
                                .padding(Lumen.Space.s5)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            GraphMinimapView(
                                layout: layout,
                                focusedBinaryName: focusedBinaryName,
                                canvasSize: canvasSize,
                                // The minimap works in layout space; the scroll view is zoomed.
                                viewportSize: CGSize(width: proxy.size.width / zoom, height: proxy.size.height / zoom),
                                scrollOffset: CGPoint(x: scrollOffset.x / zoom, y: scrollOffset.y / zoom),
                                selectedAddress: store.selectedImageAddress
                            )
                            .padding(Lumen.Space.s5)
                        }
                    }
                }
            }
            .focusable(true)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                MainActor.assumeIsolated {
                    if showsImageOverview {
                        GraphKeyboardNavigation.move(direction, in: store)
                    } else {
                        GraphKeyboardNavigation.move(direction, in: store,
                            targets: layout.nodes.map(\.selectionTarget))
                    }
                }
            }
            }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macScopeResetGraphLayout).filter { store.commandTargetsSelf($0) }) { _ in
            store.resetGraphLayoutSelection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            FocusedPresentationAccessibility.graphCanvasLabel(binaryName: focusedBinaryName)
        )
        .accessibilityHint(FocusedPresentationAccessibility.graphCanvasHint)
    }

    private var sortedGraphSelection: [ImageAddress] {
        guard let slot = store.graphNodeMultiSelection.first?.slot,
              store.graphNodeMultiSelection.allSatisfy({ $0.slot == slot }) else {
            return []
        }
        return store.graphNodeMultiSelection.sorted { $0.address < $1.address }
    }

    private func nodeState(for node: GraphNodeModel) -> GraphNodeSelectionState {
        guard let selection = store.selectedImageAddress, node.contains(selection) else {
            return .normal
        }
        return selection.address == node.startAddress ? .selectedStart : .currentBlock
    }

}

/// The graph canvas's drawing without scrolling, focus or selection, for offscreen review
/// renders of a `FocusedGraphModel` (the live canvas wraps the same pieces in a scroll view).
struct GraphLayoutReviewCanvas: View {
    let layout: FocusedGraphModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.sections) { section in
                GraphFunctionLaneView(section: section)
                    .frame(width: section.width, height: section.height)
                    .position(x: section.center.x, y: section.center.y)
            }
            ForEach(layout.edges) { edge in
                GraphEdgeShape(from: edge.fromPoint, to: edge.toPoint, control1: edge.control1,
                               control2: edge.control2, waypoints: edge.waypoints)
                    .stroke(edge.strokeColor(isSelected: false),
                            style: StrokeStyle(lineWidth: edge.strokeWidth(isSelected: false), lineCap: .round,
                                               lineJoin: .round, dash: edge.dash))
                GraphArrowHead(color: edge.strokeColor(isSelected: false))
                    .frame(width: AppGraphChrome.arrowHeadSize, height: AppGraphChrome.arrowHeadSize)
                    .rotationEffect(.radians(edge.arrowAngle))
                    .position(edge.toPoint)
                GraphEdgeLabelView(edge: edge, focusedBinaryName: nil, isSelected: false) {}
                    .position(edge.labelPoint)
            }
            ForEach(layout.nodes) { node in
                GraphNodeView(node: node, focusedBinaryName: nil, state: .normal, isMultiSelected: false,
                              selectedAddress: nil, width: layout.nodeSize.width, height: layout.nodeSize.height,
                              onSelect: {}, onToggleMultiSelect: {})
                    .position(x: node.center.x, y: node.center.y)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
    }
}

/// Reports the graph scroll content's offset within the canvas coordinate space. The
/// last writer wins (there is a single probe), so the reduce keeps the most recent value.
private struct GraphScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// The pure geometry of the spatial minimap: the uniform scale that fits the whole graph
/// canvas into the minimap card, the scaled node rectangles to draw, and the viewport
/// rectangle (what the scroll view currently shows) in minimap space. Kept free of
/// SwiftUI so the projection math is unit-testable.
struct GraphMinimapGeometry: Equatable {
    /// Uniform scale factor mapping canvas points to minimap points (<= 1).
    let scale: CGFloat
    /// The drawn size of the whole canvas inside the minimap (canvasSize * scale).
    let contentSize: CGSize
    /// The viewport rectangle in minimap space, clamped to the content bounds.
    let viewportRect: CGRect

    init(canvasSize: CGSize, viewportSize: CGSize, scrollOffset: CGPoint, minimapSize: CGSize) {
        let safeCanvas = CGSize(width: max(canvasSize.width, 1), height: max(canvasSize.height, 1))
        let scale = min(minimapSize.width / safeCanvas.width, minimapSize.height / safeCanvas.height)
        self.scale = scale
        self.contentSize = CGSize(width: safeCanvas.width * scale, height: safeCanvas.height * scale)

        // The visible window is [offset, offset + viewport]; clamp the offset so a rubber-
        // band overscroll never pushes the rect outside the drawn content.
        let clampedX = min(max(scrollOffset.x, 0), max(safeCanvas.width - viewportSize.width, 0))
        let clampedY = min(max(scrollOffset.y, 0), max(safeCanvas.height - viewportSize.height, 0))
        let rectWidth = min(viewportSize.width, safeCanvas.width) * scale
        let rectHeight = min(viewportSize.height, safeCanvas.height) * scale
        self.viewportRect = CGRect(
            x: clampedX * scale,
            y: clampedY * scale,
            width: rectWidth,
            height: rectHeight
        )
    }

    /// Maps a node center+size from canvas space to a minimap-space rect.
    func nodeRect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: (center.x - size.width / 2) * scale,
            y: (center.y - size.height / 2) * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }
}

/// A small bird's-eye overview of the whole control-flow canvas, pinned to the editor's
/// bottom-trailing corner. It draws each function lane and node scaled-to-fit, plus a
/// highlighted rectangle showing the portion the scroll view currently displays, so the
/// user can orient within a large graph. Read-only (a spatial indicator) — it never
/// hijacks the scroll gesture. Hidden when the whole graph already fits the viewport.
private struct GraphMinimapView: View {
    let layout: FocusedGraphModel
    let focusedBinaryName: String?
    let canvasSize: CGSize
    let viewportSize: CGSize
    let scrollOffset: CGPoint
    let selectedAddress: ImageAddress?


    private var isActive: Bool {
        canvasSize.width > viewportSize.width + AppGraphChrome.minimapActivationSlack
            || canvasSize.height > viewportSize.height + AppGraphChrome.minimapActivationSlack
    }

    private var minimapBox: CGSize {
        // Fit the card to the canvas aspect ratio within the max bounds, so a tall graph
        // gets a tall minimap and a wide one a wide minimap (no distortion).
        let maxW = AppGraphChrome.minimapMaxWidth
        let maxH = AppGraphChrome.minimapMaxHeight
        let scale = min(maxW / max(canvasSize.width, 1), maxH / max(canvasSize.height, 1))
        return CGSize(width: max(canvasSize.width * scale, 1), height: max(canvasSize.height * scale, 1))
    }

    var body: some View {
        if isActive {
            let geometry = GraphMinimapGeometry(
                canvasSize: canvasSize,
                viewportSize: viewportSize,
                scrollOffset: scrollOffset,
                minimapSize: minimapBox
            )

            ZStack(alignment: .topLeading) {
                // One Canvas, not a view per lane and node (large overviews have thousands).
                Canvas { context, _ in
                    let lane = Color.lumen(.graphLaneBackground)
                    for section in layout.sections {
                        context.fill(Path(CGRect(
                            x: section.origin.x * geometry.scale, y: section.origin.y * geometry.scale,
                            width: section.width * geometry.scale, height: section.height * geometry.scale)), with: .color(lane))
                    }
                    for node in layout.nodes {
                        let rect = geometry.nodeRect(center: node.center, size: node.size)
                        context.fill(Path(CGRect(x: rect.midX - max(rect.width, 1.5) / 2, y: rect.midY - max(rect.height, 1.5) / 2,
                                                 width: max(rect.width, 1.5), height: max(rect.height, 1.5))),
                                     with: .color(nodeColor(for: node)))
                    }
                }
                .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)

                Rectangle()
                    .strokeBorder(Color.lumen(.accent), lineWidth: 1.5)
                    .background(Color.lumen(.accent).opacity(0.12)) // ds-allow: the minimap viewport must stay translucent over the content it frames
                    .frame(width: geometry.viewportRect.width, height: geometry.viewportRect.height)
                    .position(x: geometry.viewportRect.midX, y: geometry.viewportRect.midY)
            }
            .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
            .padding(AppGraphChrome.minimapPadding)
            .background {
                RoundedRectangle(cornerRadius: AppGraphChrome.minimapCornerRadius)
                    .fill(DS.editorColor(.bgElevated))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppGraphChrome.minimapCornerRadius)
                    .strokeBorder(Color.lumen(.borderSubtle), lineWidth: 0.75)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                FocusedPresentationAccessibility.graphMinimapLabel(binaryName: focusedBinaryName)
            )
            .accessibilityValue(
                FocusedPresentationAccessibility.graphMinimapValue(
                    binaryName: focusedBinaryName,
                    visibleWidthPercent: Int(
                        (geometry.viewportRect.width / max(geometry.contentSize.width, 1)) * 100
                    )
                )
            )
        }
    }

    private func nodeColor(for node: GraphNodeModel) -> Color {
        if let selectedAddress, node.contains(selectedAddress) {
            return Color.lumen(.accent)
        }
        return DS.editorColor(.fgTertiary)
    }
}

private struct GraphLayoutMetrics {
    let outerMargin: CGFloat = AppGraphChrome.outerMargin
    let laneGap: CGFloat = AppGraphChrome.laneGap
    let headerHeight: CGFloat = AppGraphChrome.headerHeight
    let nodeTopPadding: CGFloat = AppGraphChrome.nodeTopPadding
    let nodeVerticalGap: CGFloat = AppGraphChrome.nodeVerticalGap
    let nodeSize: CGSize
    let laneWidth: CGFloat
    let minimumLaneHeight: CGFloat

    init(viewport: CGSize) {
        laneWidth = AppGraphChrome.laneWidth(for: viewport.width)
        nodeSize = AppGraphChrome.nodeSize(for: laneWidth)
        minimumLaneHeight = max(
            AppGraphChrome.minimumLaneHeight,
            viewport.height - outerMargin * 2 - AppGraphChrome.overviewMinHeight - Lumen.Space.s4
        )
    }
}

struct FocusedGraphModel {
    var imageSlot: ImageSlot
    var sections: [GraphFunctionSectionModel]
    var nodes: [GraphNodeModel]
    var edges: [GraphEdgeModel]
    var nodeSize: CGSize
    var canvasSize: CGSize
    /// Why the layered layout was not used (over its caps), shown above the canvas.
    var layoutNote: String? = nil
}

struct GraphFunctionSectionModel: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var confidence: Double
    var blockCount: Int
    var nodes: [GraphNodeModel]
    var origin: CGPoint = .zero
    var width: CGFloat
    var height: CGFloat = 320

    var center: CGPoint {
        CGPoint(x: origin.x + width / 2, y: origin.y + height / 2)
    }

    var confidenceText: String? {
        guard confidence > 0 else { return nil }
        return "\(Int((confidence * 100).rounded()))%"
    }
}

struct GraphNodeModel: Identifiable, Hashable {
    var selectionTarget: GraphSelectionTarget
    var title: String
    var subtitle: String
    var instructionCount: Int
    var confidence: Double
    var kind: GraphNodeKind
    var functionName: String
    var ordinal: Int?
    var isEntry: Bool
    /// User tag for this node's address, shown as a chip.
    var tag: String? = nil
    /// User highlight color for this node's address, tinting the card accent.
    var colorTag: ColorTag? = nil
    var center: CGPoint = .zero
    var size: CGSize = .zero

    var id: String { selectionTarget.id }
    var startAddress: UInt64 { selectionTarget.startAddress }
    var endAddress: UInt64 { selectionTarget.endAddress }
    var functionID: UUID? { selectionTarget.functionID }

    func contains(_ address: ImageAddress?) -> Bool { selectionTarget.contains(address) }

    var displayTitle: String {
        if kind == .function {
            return title
        }
        return "\(functionName) \(title)"
    }

    var confidenceText: String? {
        guard confidence > 0 else { return nil }
        let percentage = Int((confidence * 100).rounded())
        return "\(percentage)% confidence"
    }

    var addressRangeText: String {
        if startAddress == endAddress {
            return startAddress.hexAddress
        }
        return "\(startAddress.hexAddress) - \(endAddress.hexAddress)"
    }
}

enum GraphNodeKind: String, Hashable {
    case function
    case basicBlock = "basic block"

    var systemImage: String {
        switch self {
        case .function:
            "function"
        case .basicBlock:
            "rectangle.split.3x1"
        }
    }

    var displayName: String {
        rawValue
    }
}

private enum GraphNodeSelectionState {
    case normal
    case currentBlock
    case selectedStart
}

private struct GraphEdgeInput: Hashable {
    var elementID: String
    var from: UInt64
    var to: UInt64
    var kind: String

    var dedupeKey: String {
        "\(from.hexAddress)->\(to.hexAddress):\(kind)"
    }
}

private struct GraphEdgeRoute {
    var from: CGPoint
    var to: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var labelPoint: CGPoint
    var arrowAngle: Double

    init(source: GraphNodeModel, target: GraphNodeModel, offsetIndex: Int) {
        let nodeWidth = max(source.size.width, target.size.width)
        let nodeHeight = max(source.size.height, target.size.height)
        let pairOffset = CGFloat(offsetIndex) * 18

        if source.id == target.id {
            let loopOffset = 42 + pairOffset
            from = CGPoint(x: source.center.x + nodeWidth / 2, y: source.center.y - nodeHeight * 0.24)
            to = CGPoint(x: target.center.x + nodeWidth / 2, y: target.center.y + nodeHeight * 0.24)
            control1 = CGPoint(x: from.x + loopOffset, y: from.y - 36)
            control2 = CGPoint(x: to.x + loopOffset, y: to.y + 36)
            labelPoint = CGPoint(x: source.center.x + nodeWidth / 2 + loopOffset, y: source.center.y)
        } else if abs(source.center.x - target.center.x) < 4 {
            let sideOffset = 46 + pairOffset
            let sourceIsAboveTarget = source.center.y <= target.center.y
            from = CGPoint(
                x: source.center.x + nodeWidth / 2,
                y: source.center.y + (sourceIsAboveTarget ? nodeHeight * 0.24 : -nodeHeight * 0.24)
            )
            to = CGPoint(
                x: target.center.x + nodeWidth / 2,
                y: target.center.y + (sourceIsAboveTarget ? -nodeHeight * 0.24 : nodeHeight * 0.24)
            )
            control1 = CGPoint(x: from.x + sideOffset, y: from.y)
            control2 = CGPoint(x: to.x + sideOffset, y: to.y)
            labelPoint = CGPoint(x: source.center.x + nodeWidth / 2 + sideOffset, y: (source.center.y + target.center.y) / 2)
        } else {
            let targetIsRight = target.center.x > source.center.x
            let sourceEdgeX = source.center.x + (targetIsRight ? nodeWidth / 2 : -nodeWidth / 2)
            let targetEdgeX = target.center.x + (targetIsRight ? -nodeWidth / 2 : nodeWidth / 2)
            let horizontalDelta = max(56, abs(targetEdgeX - sourceEdgeX) * 0.42)
            let signedDelta = targetIsRight ? horizontalDelta : -horizontalDelta

            from = CGPoint(x: sourceEdgeX, y: source.center.y - 12 + pairOffset)
            to = CGPoint(x: targetEdgeX, y: target.center.y - 12 + pairOffset)
            control1 = CGPoint(x: from.x + signedDelta, y: from.y)
            control2 = CGPoint(x: to.x - signedDelta, y: to.y)
            labelPoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 14 - pairOffset * 0.4)
        }

        arrowAngle = atan2(to.y - control2.y, to.x - control2.x)
    }
}

struct GraphEdgeModel: Identifiable {
    var selectionTarget: GraphEdgeSelectionTarget
    var fromPoint: CGPoint
    var toPoint: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var labelPoint: CGPoint
    var arrowAngle: Double
    var sourceTitle: String
    var targetTitle: String
    /// Whether the edge leaves a conditional jump (a branch and a fall-through from one address).
    var isConditionalSource = false
    /// Layered layout route (polyline through dummy slots); empty for the Bézier shaping.
    var waypoints: [CGPoint] = []
    /// A loop edge in the layered layout (it runs upward or back to its own block).
    var isBackEdge = false

    mutating func applyLayeredRoute(_ points: [CGPoint], isBackEdge: Bool) {
        waypoints = points
        self.isBackEdge = isBackEdge
        fromPoint = points[0]
        toPoint = points[points.count - 1]
        let before = points[points.count - 2]
        arrowAngle = atan2(toPoint.y - before.y, toPoint.x - before.x)
        // Label on the middle segment, nudged off the line.
        let mid = points.count / 2
        let a = points[mid - 1], b = points[mid]
        labelPoint = CGPoint(x: (a.x + b.x) / 2 + (isBackEdge ? 0 : 14), y: (a.y + b.y) / 2)
    }

    /// The edge's Lumen kind: taken/not-taken for a conditional jump, call for calls and
    /// cross-references, unconditional otherwise.
    var edgeKind: LumenGraphEdgeKind { .macScope(kind: kind, isConditionalSource: isConditionalSource) }

    var id: String { selectionTarget.id }
    var kind: String { selectionTarget.kind }
    var fromAddress: UInt64 { selectionTarget.fromAddress }
    var toAddress: UInt64 { selectionTarget.toAddress }

    var label: String {
        switch kind {
        case "call":
            "call"
        case "reference":
            "xref"
        case "fallthrough":
            "fallthrough"
        case "branch":
            "branch"
        default:
            kind.isEmpty ? "edge" : kind
        }
    }

    var systemImage: String {
        switch kind {
        case "call":
            "arrowshape.turn.up.right"
        case "reference":
            "lumen.crossReference"
        case "fallthrough":
            "arrow.down"
        case "branch":
            "point.topleft.down.curvedto.point.bottomright.up"
        default:
            "arrow.right"
        }
    }

    // Lumen edge styling: taken green, not taken red,
    // unconditional quiet, calls and cross-references accent and dashed; a selected edge is
    // fgPrimary at Lumen's selected width, always solid.
    var lineWidth: CGFloat {
        edgeKind.lineWidth(isSelected: false)
    }

    var dash: [CGFloat] {
        // Loop (back) edges are dotted unless their kind already draws dashed.
        if isBackEdge, edgeKind.dash.isEmpty { return [2, 4] }
        return edgeKind.dash
    }

    var color: Color {
        Color.lumen(edgeKind.token)
    }

    func strokeColor(isSelected: Bool) -> Color {
        // Lumen review: the selected edge is fgPrimary (never the accent, which call edges use).
        Color.lumen(isSelected ? .fgPrimary : edgeKind.token)
    }

    func strokeWidth(isSelected: Bool) -> CGFloat {
        edgeKind.lineWidth(isSelected: isSelected)
    }

    var accessibilityText: String {
        "\(label), \(sourceTitle) \(fromAddress.hexAddress) to \(targetTitle) \(toAddress.hexAddress)"
    }
}

private struct GraphOverviewBar: View {
    let layout: FocusedGraphModel
    let focusedBinaryName: String?
    let selectedAddress: ImageAddress?
    let selectedGraphElementID: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Lumen.Space.s6) {
                currentLabel
                    .layoutPriority(1)

                Spacer(minLength: Lumen.Space.s5)

                HStack(spacing: Lumen.Space.s4) {
                    LumenPill(label: "functions", value: "\(layout.sections.count)", systemImage: "function", style: .metric)
                    LumenPill(label: "nodes", value: "\(layout.nodes.count)", systemImage: "rectangle.split.3x1", style: .metric)
                    LumenPill(label: "edges", value: "\(layout.edges.count)", systemImage: "lumen.crossReference", style: .metric)
                }
                .layoutPriority(2)
            }

            HStack(spacing: Lumen.Space.s6) {
                currentLabel

                Spacer(minLength: Lumen.Space.s5)

                Text("^[\(layout.sections.count) function](inflect: true) · ^[\(layout.nodes.count) node](inflect: true) · ^[\(layout.edges.count) edge](inflect: true)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Lumen.Space.s7)
        .padding(.vertical, Lumen.Space.s4)
        .frame(minHeight: AppGraphChrome.overviewMinHeight)
        .workbenchPaneBackground(.toolbar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            FocusedPresentationAccessibility.graphOverviewLabel(
                binaryName: focusedBinaryName,
                layout: layout,
                selectedAddress: selectedAddress,
                selectedGraphElementID: selectedGraphElementID
            )
        )
        .accessibilityValue(
            FocusedPresentationAccessibility.graphOverviewValue(
                binaryName: focusedBinaryName,
                layout: layout
            )
        )
    }

    private var currentLabel: some View {
        Label {
            Text(currentText)
        } icon: {
            DSSymbol(currentSystemImage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var currentText: String {
        FocusedPresentationAccessibility.graphOverviewLabel(
            binaryName: focusedBinaryName,
            layout: layout,
            selectedAddress: selectedAddress,
            selectedGraphElementID: selectedGraphElementID
        )
    }

    private var selectedEdge: GraphEdgeModel? {
        guard let selectedGraphElementID else { return nil }
        return layout.edges.first { $0.id == selectedGraphElementID }
    }

    private var currentSystemImage: String {
        selectedEdge?.systemImage ?? "scope"
    }
}

private struct GraphFunctionLaneView: View {
    let section: GraphFunctionSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Lumen.Space.s4) {
                Image(systemName: "function")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(section.subtitle)
                        .font(AppTypography.lineNumber)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Lumen.Space.s4)

                VStack(alignment: .trailing, spacing: Lumen.Space.s1) {
                    Text("\(section.blockCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(section.blockCount == 1 ? "node" : "nodes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let confidenceText = section.confidenceText {
                    Text(confidenceText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Lumen.Space.s2)
                        .padding(.vertical, Lumen.Space.s1)
                        .background {
                            Capsule()
                                .fill(DS.editorColor(.bgElevated))
                        }
                }
            }
            .padding(.horizontal, Lumen.Space.s5)
            .frame(height: AppGraphChrome.headerHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.lumen(.borderSubtle))
                    .frame(height: 1)
            }

            Spacer(minLength: 0)
        }
        .background {
            RoundedRectangle(cornerRadius: Lumen.Radius.md)
                .fill(Color.lumen(.graphLaneBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Lumen.Radius.md)
                .stroke(Color.lumen(.borderSubtle), lineWidth: 1)
        }
    }
}

private struct GraphEdgeLabelView: View {
    let edge: GraphEdgeModel
    let focusedBinaryName: String?
    let isSelected: Bool
    let select: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if edge.edgeKind.letter != nil {
            // Lumen T/F badge for a conditional jump's edges.
            LumenGraphEdgeBadge(edge.edgeKind, isSelected: isSelected, onSelect: select)
                .help(accessibilityText)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        } else if edge.edgeKind == .unconditional {
            // unconditional jumps and fall-throughs need no text; the quiet
            // stroke already says it. A small dot keeps the edge selectable and focusable.
            dot
        } else {
            chip
        }
    }

    private var dot: some View {
        Button(action: select) {
            Circle()
                .fill(edge.strokeColor(isSelected: isSelected))
                .frame(width: 7, height: 7)
                .padding(Lumen.Space.s2)
                .background {
                    if isSelected || isFocused {
                        Circle().stroke(Color.lumen(.accent), lineWidth: 1.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Edges without a letter keep a small chip, so every edge stays selectable from its label.
    private var chip: some View {
        Button(action: select) {
            Label {
                Text(edge.label)
            } icon: {
                DSSymbol(edge.systemImage)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(edge.strokeColor(isSelected: isSelected))
            .lineLimit(1)
            .padding(.horizontal, Lumen.Space.s2)
            .padding(.vertical, Lumen.Space.s1)
            .background {
                Capsule()
                    .fill(DS.editorColor(.bgElevated))

                if isSelected {
                    Capsule()
                        .fill(AppInteractionChrome.selectedTokenFill(isActiveWindow: isActiveWindow, editorSurface: true))
                }
            }
            .overlay {
                Capsule()
                    .stroke(
                        isSelected || isFocused ? Color.lumen(.accent) : Color.lumen(.borderSubtle),
                        lineWidth: AppInteractionChrome.rowStrokeWidth(
                            isSelected: isSelected,
                            isFocused: isFocused,
                            contrast: colorSchemeContrast
                        )
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled() // the accent capsule stroke is the focus affordance (no system blue)
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        FocusedPresentationAccessibility.graphEdgeLabel(
            binaryName: focusedBinaryName,
            edge: edge
        )
    }

    private var isActiveWindow: Bool {
        controlActiveState != .inactive
    }
}

private struct GraphArrowHead: View {
    let color: Color

    var body: some View {
        GraphArrowHeadShape()
            .fill(color)
            .accessibilityHidden(true)
    }
}

private struct GraphArrowHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct GraphNodeView: View {
    let node: GraphNodeModel
    let focusedBinaryName: String?
    let state: GraphNodeSelectionState
    /// Whether this node is part of the current multi-selection (Cmd-click group). Drawn with
    /// a distinct accent ring so a grouped node reads apart from the single selection.
    let isMultiSelected: Bool
    let selectedAddress: ImageAddress?
    let width: CGFloat
    let height: CGFloat
    let onSelect: () -> Void
    /// Cmd-click: toggle this node in/out of the multi-selection group.
    let onToggleMultiSelect: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.controlActiveState) private var controlActiveState

    // Composed from typed type-scope parts so the node card, its rows and the accessibility
    // chain type-check separately; view types and modifier order are unchanged.
    var body: some View {
        Button(action: onSelect) {
            nodeCard
        }
        .buttonStyle(.plain)
        // Cmd-click toggles multi-selection. A high-priority modifier-keyed tap intercepts
        // the Cmd-click before the Button's plain action fires, so a normal click still
        // single-selects (and keyboard activation is unaffected).
        .highPriorityGesture(
            TapGesture().modifiers(.command).onEnded { onToggleMultiSelect() }
        )
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled() // the accent node stroke is the focus affordance (no system blue)
        .help(helpText)
        .accessibilityLabel(
            FocusedPresentationAccessibility.graphNodeLabel(
                binaryName: focusedBinaryName,
                node: node
            )
        )
        .accessibilityValue(
            FocusedPresentationAccessibility.graphNodeValue(
                binaryName: focusedBinaryName,
                isMultiSelected: isMultiSelected
            )
        )
        // VoiceOver can't perform a Cmd-click, so the group toggle is also a custom action
        // (rotor-reachable) — the feature is operable without a pointer.
        .accessibilityAction(
            named: FocusedPresentationAccessibility.graphNodeGroupActionLabel(
                isMultiSelected: isMultiSelected
            )
        ) {
            onToggleMultiSelect()
        }
        .accessibilityAddTraits(selectionTraits)
    }

    /// Lumen's summary card: kind tile, title and instruction
    /// count, address range; selection, current block, multi-selection and color tag drawn by the
    /// card. Confidence and the user's text tag move to the help tag.
    private var nodeCard: some View {
        DSGraphNode(
            title: node.title,
            detail: rangeDetail,
            systemImage: node.isEntry ? "lumen.entryPoint" : node.kind.systemImage,
            hue: node.isEntry ? .hueGreen : (node.kind == .function ? .hueIndigo : .hueBlue),
            count: node.instructionCount > 0 ? node.instructionCount : nil,
            state: cardState,
            isMultiSelected: isMultiSelected,
            tagRawValue: node.colorTag?.rawValue
        )
        .frame(width: width, height: height, alignment: .topLeading)
        .workbenchFocusRing(isVisible: isFocused, radius: Lumen.Radius.md)
        .contentShape(RoundedRectangle(cornerRadius: Lumen.Radius.md))
    }

    private var rangeDetail: String {
        node.startAddress == node.endAddress
            ? node.startAddress.hexAddress
            : "\(node.startAddress.hexAddress)–\(node.endAddress.hexAddress)"
    }

    private var cardState: DSGraphNodeState {
        switch state {
        case .selectedStart: .selected
        case .currentBlock: .currentBlock
        case .normal: .normal
        }
    }

    private var helpText: String {
        var lines = [FocusedPresentationAccessibility.graphNodeHelp(binaryName: focusedBinaryName, node: node)]
        if node.kind == .basicBlock, !node.functionName.isEmpty { lines.append(node.functionName) }
        if let confidenceText = node.confidenceText { lines.append(confidenceText) }
        if let tag = node.tag, !tag.isEmpty { lines.append("Tag: \(tag)") }
        return lines.joined(separator: "\n")
    }

    private var selectionTraits: AccessibilityTraits {
        state == .normal && !isMultiSelected ? [] : .isSelected
    }
}

/// The floating color/group bar shown over the graph while a node multi-selection is active.
/// Offers a swatch per `ColorTag` (paint the whole group that color), a Clear action, and a
/// Done that dismisses the grouping. Each swatch is a labeled button so it is keyboard- and
/// VoiceOver-operable.
private struct GraphNodeGroupBar: View {
    let focusedBinaryName: String?
    let selectionCount: Int
    let onApplyColor: (ColorTag) -> Void
    let onClearColor: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Lumen.Space.s5) {
            Text("\(selectionCount) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    FocusedPresentationAccessibility.graphGroupSelectionLabel(
                        binaryName: focusedBinaryName,
                        selectionCount: selectionCount
                    )
                )

            Divider().frame(height: 16)

            HStack(spacing: Lumen.Space.s4) {
                ForEach(ColorTag.allCases) { tag in
                    Button {
                        onApplyColor(tag)
                    } label: {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.lumen(.borderSubtle), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Color group \(tag.displayName)")
                    .accessibilityLabel("Apply \(tag.displayName)")
                }
            }

            Button("Clear", action: onClearColor)
                .help("Remove the color from the selected nodes")

            Divider().frame(height: 16)

            Button("Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
        .background(.lumen(.bgElevated), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.lumen(.borderSubtle), lineWidth: 1))
        .shadow(radius: 4, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            FocusedPresentationAccessibility.graphGroupToolsLabel(binaryName: focusedBinaryName)
        )
    }
}

private struct GraphEdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    /// A layered route: drawn as a polyline with rounded bends instead of the Bézier.
    var waypoints: [CGPoint] = []

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard waypoints.count >= 2 else {
            path.move(to: from)
            path.addCurve(to: to, control1: control1, control2: control2)
            return path
        }
        path.move(to: waypoints[0])
        for i in 1..<(waypoints.count - 1) {
            path.addArc(tangent1End: waypoints[i], tangent2End: waypoints[i + 1], radius: 18)
        }
        path.addLine(to: waypoints[waypoints.count - 1])
        return path
    }
}

/// Finds the first node (in array order) containing an address without scanning every node, so
/// edge routing stays near-linear on large images. Nodes are looked up by start address; only
/// starts within the widest node's span of the address can contain it.
struct GraphNodeIndex {
    private let nodes: [GraphNodeModel]
    /// Node indices sorted by start address.
    private let byStart: [Int]
    private let widestSpan: UInt64

    init(_ nodes: [GraphNodeModel]) {
        self.nodes = nodes
        byStart = nodes.indices.sorted { (nodes[$0].startAddress, $0) < (nodes[$1].startAddress, $1) }
        widestSpan = nodes.map { $0.endAddress > $0.startAddress ? $0.endAddress - $0.startAddress : 0 }.max() ?? 0
    }

    /// The first node that contains `address`, or (when `startAddress` is given) starts there.
    func first(containing address: ImageAddress, orStartingAt startAddress: UInt64? = nil) -> GraphNodeModel? {
        let target = address.address
        let lowerBound = target >= widestSpan ? target - widestSpan : 0
        // First position whose start exceeds the address; candidates lie before it.
        var low = 0, high = byStart.count
        while low < high {
            let mid = (low + high) / 2
            if nodes[byStart[mid]].startAddress <= max(target, startAddress ?? target) { low = mid + 1 } else { high = mid }
        }
        var best: Int?
        var position = low - 1
        while position >= 0 {
            let candidate = byStart[position]
            let node = nodes[candidate]
            if node.startAddress < lowerBound && node.startAddress < (startAddress ?? lowerBound) { break }
            if node.contains(address) || node.startAddress == startAddress {
                best = min(best ?? candidate, candidate)
            }
            position -= 1
        }
        return best.map { nodes[$0] }
    }
}

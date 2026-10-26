import SwiftUI
import LumenTokens
import LumenUI

struct DebuggerPanelView: View {
    @ObservedObject private var store: WorkspaceStore
    @ObservedObject private var viewModel: DebuggerPanelViewModel
    @Binding private var selectedTab: DebuggerDeckTab
    @State private var logicalBreakpointEditor: LogicalBreakpointEditorRoute?
    @State private var isLocalProcessAttachSheetPresented = false
    @State private var showsWatchpoints = false

    init(
        store: WorkspaceStore,
        viewModel: DebuggerPanelViewModel,
        selectedTab: Binding<DebuggerDeckTab>
    ) {
        self.store = store
        self.viewModel = viewModel
        _selectedTab = selectedTab
    }

    var body: some View {
        DebuggerPanelViewport { availableHeight in
            VStack(spacing: 0) {
                if selectedTab == .breakpoints {
                    header
                    Divider()
                    deck
                        .frame(height: DSBottomPanelContentLayout.debuggerHeight(
                            availableHeight: availableHeight, isBreakpoints: true
                        ))
                } else if viewModel.capabilities.isBackendAvailable {
                    if viewModel.session.hasLiveProcessSession {
                        header
                        Divider()
                        deck
                            .frame(height: DSBottomPanelContentLayout.debuggerHeight(
                                availableHeight: availableHeight, isBreakpoints: false
                            ))
                    } else {
                        CompactDebuggerStatusDeckView(
                            viewModel: viewModel,
                            presentation: .idle,
                            showsTargetPicker: hasDebuggerTarget,
                            onManageLogicalBreakpoints: presentLogicalBreakpointsManager,
                            onPresentLocalProcessAttachSheet: presentLocalProcessAttachSheet
                        )
                    }
                } else {
                    CompactDebuggerStatusDeckView(
                        viewModel: viewModel,
                        presentation: .unavailable,
                        showsTargetPicker: false,
                        onManageLogicalBreakpoints: presentLogicalBreakpointsManager,
                        onPresentLocalProcessAttachSheet: presentLocalProcessAttachSheet
                    )
                }
            }
        }
        .workbenchPaneBackground(.debugger)
        .frame(minHeight: 0, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Debugger deck")
        .accessibilityIdentifier("debugger.deck")
        .sheet(item: $logicalBreakpointEditor) { route in
            LogicalBreakpointEditorSheet(
                title: route.title,
                draft: route.draft,
                ownerChoices: logicalBreakpointOwnerChoices,
                sourceChoices: logicalBreakpointSourceChoices,
                capabilities: logicalBreakpointEditorCapabilities,
                onSave: { submission in
                    saveLogicalBreakpoint(submission, route: route)
                },
                onCancel: { logicalBreakpointEditor = nil }
            )
        }
        .sheet(isPresented: $isLocalProcessAttachSheetPresented) {
            LocalProcessAttachSheet(
                viewModel: viewModel,
                onDismiss: { isLocalProcessAttachSheetPresented = false }
            )
        }
    }

    private var hasDebuggerTarget: Bool {
        !store.snapshot.binaries.isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            HStack(spacing: Lumen.Space.s5) {
                Label("Debugger", systemImage: "ladybug")
                    .font(.body.weight(.semibold))
                    .fixedSize()
                    .layoutPriority(3)

                LumenBadge(viewModel.statusTitle, systemImage: viewModel.session.processState.systemImage)
                    .layoutPriority(2)

                Spacer(minLength: Lumen.Space.s5)

                DebuggerTransportControls(viewModel: viewModel)

                Picker("Debugger Pane", selection: $selectedTab) {
                    ForEach(DebuggerDeckTab.allCases) { tab in
                        DS.symbolImage(tab.systemImage)
                            .tag(tab)
                            .help(tab.title)
                            .accessibilityLabel(tab.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(
                    minWidth: AppDebuggerChrome.tabPickerMinWidth,
                    idealWidth: AppDebuggerChrome.tabPickerIdealWidth,
                    maxWidth: AppDebuggerChrome.tabPickerMaxWidth
                )
                .layoutPriority(1)
            }

            DebuggerInspectionStatusStrip(
                viewModel: viewModel,
                sourceStatus: sourceInspectionStatus
            )
        }
        .padding(.horizontal, AppDebuggerChrome.deckHorizontalPadding)
        .padding(.vertical, AppDebuggerChrome.headerVerticalPadding)
    }

    @ViewBuilder
    private var deck: some View {
        switch selectedTab {
        case .console:
            ConsoleDeckView(viewModel: viewModel)
        case .threads:
            ThreadsDeckView(viewModel: viewModel)
        case .frames:
            FramesDeckView(
                viewModel: viewModel,
                revealTarget: selectedFrameRevealTarget,
                onRevealSelectedFrame: revealSelectedFrame
            )
        case .breakpoints:
            VStack(spacing: 0) {
                Picker("Stop conditions", selection: $showsWatchpoints) {
                    Text("Breakpoints").tag(false)
                    Text("Watchpoints").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .padding(Lumen.Space.s3)
                if showsWatchpoints {
                    WatchpointsDeckView(
                        watchpoints: viewModel.session.watchpoints,
                        canEdit: viewModel.canEditWatchpoints,
                        error: viewModel.session.watchpointError,
                        onRequest: { request in
                            Task { await viewModel.updateWatchpoints(request) }
                        }
                    )
                } else {
                    logicalBreakpointsDeck
                }
            }
        case .registers:
            RegistersDeckView(viewModel: viewModel)
        case .variables:
            VariablesDeckView(
                viewModel: viewModel,
                sourceStatus: sourceInspectionStatus
            )
        case .memory:
            MemoryDeckView(viewModel: viewModel)
        case .problems:
            ProblemsDeckView(message: viewModel.lastError)
        }
    }

    private var logicalBreakpointsDeck: some View {
        LogicalBreakpointsDeckView(
            catalogAvailability: store.logicalBreakpointCatalogAvailability,
            rows: logicalBreakpointRows,
            sessionSummary: logicalBreakpointSessionSummary,
            onAdd: beginAddingLogicalBreakpoint,
            onSetEnabled: setLogicalBreakpointEnabled,
            onEdit: beginEditingLogicalBreakpoint,
            onDelete: deleteLogicalBreakpoint,
            onDiscardCorruptCatalog: discardCorruptLogicalBreakpointCatalog
        )
    }

    private var sourceInspectionStatus: DebuggerSourceInspectionPresentation {
        let resolvedAddress = viewModel.selectedFrameResolvedStaticAddress
        return DebuggerSourceInspectionPresentation.resolve(
            hasLiveProcessSession: viewModel.session.hasLiveProcessSession,
            coordinate: viewModel.currentInspectionCoordinate,
            selectedFrameResolvedStaticAddress: resolvedAddress,
            sourceLines: resolvedAddress.flatMap {
                store.snapshot.analysis(in: $0.imageAddress.slot)?.sourceLines
            } ?? [],
            focusedImageSlot: store.focusedImageSlot
        )
    }

    /// A stopped frame may reveal only an instruction in its exact current workspace image.
    /// Recheck this on activation as well as while presenting the button: a stop, runtime
    /// mapping, or workspace owner can change after the previous view update.
    private var selectedFrameRevealTarget: ImageAddress? {
        guard let inspection = viewModel.currentInspectionCoordinate,
              viewModel.session.liveProgramCounter != nil,
              let resolved = viewModel.selectedFrameResolvedStaticAddress,
              inspection.stop == resolved.projectionKey.stopCoordinate,
              inspection.frame.programCounter == resolved.runtimeAddress else {
            return nil
        }

        let owner = resolved.workspaceCoordinate
        let target = resolved.imageAddress
        let catalog = store.debuggerWorkspaceArtifactCatalog
        guard target.slot == owner.slot,
              catalog.revision == resolved.projectionKey.workspaceCatalogRevision,
              catalog.artifacts.filter({ artifact in
                  artifact.slot == owner.slot
                      && artifact.binaryID == owner.binaryID
                      && artifact.ownerRevision == owner.ownerRevision
                      && artifact.artifactIdentity == owner.artifactIdentity
                      && artifact.artifactIntegrityState == .verified
              }).count == 1,
              let binary = store.snapshot.binary(in: owner.slot),
              binary.id == owner.binaryID,
              binary.artifactIdentity == owner.artifactIdentity,
              let analysis = store.snapshot.analysis(in: owner.slot),
              analysis.instructions.contains(where: { $0.address == target.address }),
              store.snapshot.containsLoadedAddress(target.address, in: owner.slot) else {
            return nil
        }
        return target
    }

    private func revealSelectedFrame() {
        guard let target = selectedFrameRevealTarget else { return }
        store.goToAddress(target.address, in: target.slot)
    }

    private var logicalBreakpointRows: [DebuggerLogicalBreakpointRowPresentation] {
        guard store.logicalBreakpointCatalogAvailability == .available else { return [] }
        return DebuggerLogicalBreakpointPresentation.project(
            catalog: store.snapshot.logicalBreakpointCatalog,
            coordinate: store.logicalBreakpointCatalogCoordinate,
            reducerSnapshot: viewModel.session.transportBreakpointBindingState,
            imageIdentities: logicalBreakpointImageIdentities
        ).rows
    }

    private var logicalBreakpointImageIdentities:
        [DebuggerLogicalBreakpointImagePresentationIdentity] {
        store.snapshot.binaries.map { binary in
            DebuggerLogicalBreakpointImagePresentationIdentity(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: binary.slot,
                    binaryID: binary.id,
                    artifactIdentity: binary.artifactIdentity
                ),
                displayName: binary.name
            )
        }
    }

    private var logicalBreakpointOwnerChoices: [LogicalBreakpointOwnerChoice] {
        store.snapshot.binaries
            .sorted { lhs, rhs in
                if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { binary in
                LogicalBreakpointOwnerChoice(
                    owner: DebuggerWorkspaceImageOwnerSeal(
                        slot: binary.slot,
                        binaryID: binary.id,
                        artifactIdentity: binary.artifactIdentity
                    ),
                    title: binary.name,
                    detail: "Slot \(binary.slot.rawValue) · \(binary.architecture)"
                )
            }
    }

    /// Deduplicate only within one exact image owner, then order by owner and frozen source-identity
    /// bytes. A source identity is never detached from the resolver coordinate that supplied it.
    private var logicalBreakpointSourceChoices: [LogicalBreakpointSourceChoice] {
        store.debuggerBreakpointResolutionCatalog.owners.flatMap {
            resolutionOwner -> [LogicalBreakpointSourceChoice] in
            guard resolutionOwner.hasExactSourceAuthority else { return [] }
            let owner = DebuggerWorkspaceImageOwnerSeal(
                slot: resolutionOwner.coordinate.slot,
                binaryID: resolutionOwner.coordinate.binaryID,
                artifactIdentity: resolutionOwner.coordinate.artifactIdentity
            )
            var identityByExactBytes: [Data: DebuggerCanonicalSourceFileIdentity] = [:]
            for row in resolutionOwner.sourceRows {
                identityByExactBytes[exactSourceIdentityBytes(row.file)] = row.file
            }
            return identityByExactBytes
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }
                .map { _, identity in
                    LogicalBreakpointSourceChoice(
                        owner: owner,
                        ownerCoordinate: resolutionOwner.coordinate,
                        identity: identity,
                        title: logicalBreakpointSourceDisplayPath(identity.tablePath),
                        detail: "Exact debug source · unit \(identity.lineProgramUnitOffset) · file \(identity.fileTableIndex)"
                    )
                }
        }
    }

    private var logicalBreakpointSessionSummary: String {
        let count = store.logicalBreakpointCount
        let enabled = store.enabledLogicalBreakpointCount
        guard store.logicalBreakpointCatalogAvailability == .available else {
            return "Unavailable catalog · no saved breakpoint is armed"
        }
        guard viewModel.session.hasLiveProcessSession else {
            return "\(count) saved · \(enabled) enabled · offline"
        }
        return viewModel.session.transportBreakpointBindingState == nil
            ? "\(count) saved · live binding evidence unavailable"
            : "\(count) saved · \(enabled) enabled · live binding state"
    }

    /// Authoring is independent of whether a process is currently live, but it is never inferred
    /// from transport branding alone. The production backend must be ready for retained execution
    /// control, and each editor feature must also be in the exact current-Xcode live-proven runtime
    /// capability set. Any missing layer leaves that feature disabled.
    private var logicalBreakpointEditorCapabilities: LogicalBreakpointEditorCapabilities {
        let backend = viewModel.capabilities
        guard backend.isBackendAvailable,
              backend.executionControlSupport.isSupported else {
            return .unavailable
        }

        let runtime = LLDBLogicalBreakpointProgram.liveProvenCapabilities
        let canAuthorActions = runtime.contains(.actions)
        return LogicalBreakpointEditorCapabilities(
            canAuthorConditions: runtime.contains(.condition),
            canAuthorIgnoreFirst: runtime.contains(.ignoreFirst),
            canAuthorActions: canAuthorActions,
            canAuthorTargetExpressions: canAuthorActions && runtime.contains(.targetExpression),
            canAuthorContinueAfterActions: canAuthorActions
                && runtime.contains(.continueAfterSuccessfulActions)
        )
    }

    private func presentLogicalBreakpointsManager() {
        WorkspaceBottomPanelRouting.showLogicalBreakpoints(in: store)
    }

    private func presentLocalProcessAttachSheet() {
        isLocalProcessAttachSheetPresented = true
    }

    private func beginAddingLogicalBreakpoint() {
        guard store.logicalBreakpointCatalogAvailability == .available else { return }
        let binary = store.focusedBinary
        let owner = binary.map {
            DebuggerWorkspaceImageOwnerSeal(
                slot: $0.slot,
                binaryID: $0.id,
                artifactIdentity: $0.artifactIdentity
            )
        }
        let selectedAddress = store.selectedImageAddress.flatMap { selection in
            selection.slot == binary?.slot ? selection.address : nil
        }
        logicalBreakpointEditor = LogicalBreakpointEditorRoute(
            mode: .add,
            draft: LogicalBreakpointEditorDraft(
                owner: owner,
                preferredAddress: selectedAddress
            )
        )
    }

    private func beginEditingLogicalBreakpoint(_ id: DebuggerLogicalBreakpointID) {
        guard store.logicalBreakpointCatalogAvailability == .available,
              let specification = store.logicalBreakpoint(id: id) else { return }
        logicalBreakpointEditor = LogicalBreakpointEditorRoute(
            mode: .edit(id: id, revision: specification.revision),
            draft: LogicalBreakpointEditorDraft(specification: specification)
        )
    }

    private func saveLogicalBreakpoint(
        _ submission: LogicalBreakpointEditorSubmission,
        route: LogicalBreakpointEditorRoute
    ) {
        guard store.logicalBreakpointCatalogAvailability == .available else {
            store.lastIssue = "Repair the unavailable breakpoint catalog before authoring."
            return
        }
        do {
            switch route.mode {
            case .add:
                _ = try store.createLogicalBreakpoint(
                    enabled: submission.enabled,
                    target: submission.target,
                    condition: submission.condition,
                    hitPolicy: submission.hitPolicy,
                    actions: submission.actions,
                    disposition: submission.disposition
                )
            case .edit(let id, let revision):
                guard store.logicalBreakpoint(id: id)?.revision == revision else {
                    store.lastIssue = "The saved breakpoint changed while its editor was open. Reopen it and try again."
                    return
                }
                let changed = try store.editLogicalBreakpoint(
                    id: id,
                    draft: WorkspaceLogicalBreakpointDraft(
                        enabled: submission.enabled,
                        target: submission.target,
                        condition: submission.condition,
                        hitPolicy: submission.hitPolicy,
                        actions: submission.actions,
                        disposition: submission.disposition
                    )
                )
                guard changed || store.logicalBreakpoint(id: id)?.revision == revision else {
                    store.lastIssue = "The saved breakpoint is no longer available."
                    return
                }
            }
            logicalBreakpointEditor = nil
        } catch {
            store.lastIssue = error.localizedDescription
        }
    }

    private func setLogicalBreakpointEnabled(
        _ id: DebuggerLogicalBreakpointID,
        _ enabled: Bool
    ) {
        guard store.logicalBreakpointCatalogAvailability == .available else { return }
        do {
            _ = try store.setLogicalBreakpointEnabled(id, enabled: enabled)
        } catch {
            store.lastIssue = error.localizedDescription
        }
    }

    private func deleteLogicalBreakpoint(_ id: DebuggerLogicalBreakpointID) {
        guard store.logicalBreakpointCatalogAvailability == .available else { return }
        do {
            _ = try store.deleteLogicalBreakpoint(id)
        } catch {
            store.lastIssue = error.localizedDescription
        }
    }

    private func discardCorruptLogicalBreakpointCatalog() {
        guard store.logicalBreakpointCatalogAvailability == .unavailable else { return }
        if !store.discardCorruptLogicalBreakpointCatalog(confirmed: true) {
            store.lastIssue = "The unavailable breakpoint catalog could not be repaired."
        }
    }

    private func exactSourceIdentityBytes(
        _ identity: DebuggerCanonicalSourceFileIdentity
    ) -> Data {
        var data = Data()
        func append(_ bytes: Data) {
            var count = UInt64(bytes.count).bigEndian
            data.append(Data(bytes: &count, count: MemoryLayout<UInt64>.size))
            data.append(bytes)
        }
        withUnsafeBytes(of: identity.debugArtifactUUID.uuid) { append(Data($0)) }
        append(Data(identity.debugArtifactMachOSHA256.utf8))
        withUnsafeBytes(of: identity.debugArtifactMachOByteCount.bigEndian) { append(Data($0)) }
        withUnsafeBytes(of: identity.lineProgramUnitOffset.bigEndian) { append(Data($0)) }
        withUnsafeBytes(of: identity.fileTableIndex.bigEndian) { append(Data($0)) }
        switch identity.tablePath {
        case .absoluteUTF8(let path): data.append(0); append(Data(path.utf8))
        case .compilationDirectoryRelativeUTF8(let path):
            data.append(1); append(Data(path.utf8))
        }
        return data
    }

    private func logicalBreakpointSourceDisplayPath(
        _ tablePath: DebuggerCanonicalSourceTablePath
    ) -> String {
        let value: String
        switch tablePath {
        case .absoluteUTF8(let path), .compilationDirectoryRelativeUTF8(let path):
            value = path
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        if (value.hasPrefix("/Users/") || value.hasPrefix("/home/")), components.count >= 2 {
            let suffix = components.dropFirst(2).joined(separator: "/")
            return suffix.isEmpty ? "<home>" : "<home>/\(suffix)"
        }
        return value
    }
}

private struct LogicalBreakpointEditorRoute: Identifiable {
    enum Mode {
        case add
        case edit(
            id: DebuggerLogicalBreakpointID,
            revision: DebuggerLogicalBreakpointRevision
        )
    }

    let mode: Mode
    let draft: LogicalBreakpointEditorDraft

    var id: String {
        switch mode {
        case .add:
            "add"
        case .edit(let id, let revision):
            "edit:\(id.rawValue.uuidString):\(revision.rawValue)"
        }
    }

    var title: String {
        switch mode {
        case .add: "Add Logical Breakpoint"
        case .edit: "Edit Logical Breakpoint"
        }
    }
}

/// Nested deck lists retain their own scrolling; this outer viewport also makes
/// header/target controls reachable after a user shrinks the shared panel.
private struct DebuggerPanelViewport<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content(proxy.size.height)
            }
        }
    }
}

private enum CompactDebuggerPresentation {
    case idle
    case unavailable

    var transportProminence: DebuggerTransportProminence {
        switch self {
        case .idle:
            .compact
        case .unavailable:
            .disabled
        }
    }
}

private struct CompactDebuggerStatusDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let presentation: CompactDebuggerPresentation
    let showsTargetPicker: Bool
    let onManageLogicalBreakpoints: () -> Void
    let onPresentLocalProcessAttachSheet: () -> Void
    @State private var isShowingLaunchAdmissionDetails = false

    var body: some View {
        VStack(spacing: 0) {
            statusRow

            if showsTargetPicker {
                Divider()
                DebuggerTargetPickerView(
                    viewModel: viewModel,
                    onPresentLocalProcessAttachSheet: onPresentLocalProcessAttachSheet
                )
            }
        }
        .background(Color.lumen(.deckBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("debugger.compactStatusDeck")
    }

    private var statusRow: some View {
        // Lumen panel bar: tile and title, the state in quiet text,
        // Breakpoints as a quiet action and Attach to Process… as the one accent action. The
        // launch-diagnostic popover and the transport controls keep their places.
        HStack(spacing: Lumen.Space.s5) {
            HStack(spacing: Lumen.Space.s4) {
                LumenIconTile("ladybug.fill", hue: .hueRed, size: 20)
                Text("Debugger")
                    .font(Lumen.Font.headline)
            }
            .fixedSize()
            .layoutPriority(3)
            .accessibilityElement(children: .combine)

            Text(statusTitle)
                .font(Lumen.Font.callout.weight(.medium))
                .foregroundStyle(.lumen(.fgTertiary))
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
                .accessibilityLabel("Debugger state: \(statusTitle)")

            ViewThatFits(in: .horizontal) {
                Text(primaryStatusText)
                Text(fallbackStatusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(viewModel.statusDetail)
            .frame(minWidth: AppDebuggerChrome.statusDetailMinWidth, alignment: .leading)
            .layoutPriority(1)

            if let diagnostic = viewModel.launchAdmissionDiagnostic {
                Button {
                    isShowingLaunchAdmissionDetails.toggle()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Details…", systemImage: "info.circle")
                        Image(systemName: "info.circle")
                    }
                }
                .controlSize(.small)
                .help("Show why debugger launch is unavailable")
                .popover(isPresented: $isShowingLaunchAdmissionDetails, arrowEdge: .bottom) {
                    DebuggerLaunchAdmissionDetailsView(diagnostic: diagnostic)
                }
            }

            Spacer(minLength: Lumen.Space.s5)

            Button(action: onManageLogicalBreakpoints) {
                ViewThatFits(in: .horizontal) {
                    Label {
                        Text("Breakpoints")
                    } icon: {
                        DS.symbolImage(DebuggerDeckTab.breakpoints.systemImage)
                    }
                    DSSymbol(DebuggerDeckTab.breakpoints.systemImage)
                }
            }
            .buttonStyle(LumenQuietButtonStyle())
            .dsFocusRing()
            .help("Manage durable logical breakpoints")
            .accessibilityLabel("Manage Logical Breakpoints")
            .accessibilityIdentifier("debugger.manageLogicalBreakpoints")

            if showsTargetPicker {
                DebuggerTransportControls(viewModel: viewModel, prominence: presentation.transportProminence)
            } else if viewModel.capabilities.attachSupport.isSupported {
                Button("Attach to Process…", action: onPresentLocalProcessAttachSheet)
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .dsPrimaryFocusRing()
                    .fixedSize()
                .help("Open the exact-identity local process attach sheet")
                .accessibilityLabel("Attach to Local Process")
                .accessibilityIdentifier("debugger.attachLocalProcess")
            }
        }
        .padding(.horizontal, AppDebuggerChrome.deckHorizontalPadding)
        .padding(.vertical, AppDebuggerChrome.compactVerticalPadding)
    }

    private var statusTitle: String {
        switch presentation {
        case .idle:
            viewModel.statusTitle
        case .unavailable:
            "Backend unavailable"
        }
    }


    private var primaryStatusText: String {
        switch presentation {
        case .idle:
            idleStatusText
        case .unavailable:
            viewModel.statusDetail
        }
    }

    private var fallbackStatusText: String {
        switch presentation {
        case .idle:
            "No live debug process."
        case .unavailable:
            "\(viewModel.capabilities.backendName) unavailable."
        }
    }

    private var idleStatusText: String {
        if viewModel.capabilities.executionControlSupport.isSupported {
            return "No live debug process. LLDB live controls are ready."
        }
        if viewModel.capabilities.launchSupport.isSupported {
            return "No live debug process. Launch is available."
        }
        return "No live debug process."
    }

    private var accessibilityLabel: String {
        switch presentation {
        case .idle:
            "Debugger \(viewModel.statusTitle). \(viewModel.statusDetail)"
        case .unavailable:
            "Debugger backend unavailable. \(viewModel.statusDetail)"
        }
    }
}

private struct DebuggerLaunchAdmissionDetailsView: View {
    let diagnostic: DebuggerLaunchAdmissionDiagnosticPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Label(diagnostic.title, systemImage: diagnostic.systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(diagnostic.reason)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(diagnostic.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Lumen.Space.s7)
        .frame(width: 360, alignment: .leading)
        .background(Color.lumen(.deckBackground))
    }
}

private struct DebuggerTargetPickerView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let onPresentLocalProcessAttachSheet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            header
            selectedTargetSummary
            selectorFields
            LaunchConfigurationEditor(viewModel: viewModel)
            AttachToProcessEditor(
                viewModel: viewModel,
                onPresentLocalProcessAttachSheet: onPresentLocalProcessAttachSheet
            )
        }
        .padding(.horizontal, AppDebuggerChrome.deckHorizontalPadding)
        .padding(.vertical, Lumen.Space.s4)
        .background(Color.lumen(.deckBackground))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Label("Target", systemImage: viewModel.targetPickerSnapshot.policySummary.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize()

            Text(viewModel.targetPickerSnapshot.policySummary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(viewModel.targetPickerSnapshot.policySummary.detail)

            Spacer(minLength: Lumen.Space.s5)

            Button {
                Task { await viewModel.launchSelectedTarget() }
            } label: {
                Label("Launch Target", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(!viewModel.canLaunchSelectedTarget)
            .help(viewModel.selectedTargetControlHelp)
        }
    }

    private var selectedTargetSummary: some View {
        let summary = viewModel.selectedTargetSummary

        return HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
            Label(summary.title, systemImage: summary.systemImage)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(2)

            Text(summary.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: Lumen.Space.s4)

            Text(summary.statusTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(summary.disabledReason == nil ? Color.lumen(.statusSuccess) : Color.lumen(.statusWarning))
                .lineLimit(1)
        }
        .help(summary.disabledReason ?? summary.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
    }

    private var selectorFields: some View {
        HStack(spacing: Lumen.Space.s4) {
            LumenTextField("Imported executable path", text: $viewModel.importedExecutablePath, monospaced: true)
                .disabled(!viewModel.capabilities.launchSupport.isSupported)
                .accessibilityLabel("Imported executable path")
        }
    }

}

/// Authoring surface for the launch arguments, environment overrides, and
/// working directory. All parsing / validation lives in the view model; this
/// view is a thin binding over its string state plus the env-row list.
private struct LaunchConfigurationEditor: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text("Launch configuration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: Lumen.Space.s4) {
                LumenTextField("Arguments (e.g. --flag \"a b\")", text: $viewModel.launchArgumentsText)
                    .accessibilityLabel("Launch arguments")

                LumenTextField("Working directory (/path)", text: $viewModel.launchWorkingDirectoryText, monospaced: true)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Launch working directory")
            }
            .controlSize(.small)
            .disabled(!viewModel.capabilities.launchSupport.isSupported)

            environmentEditor

            if let message = viewModel.launchInvocationValidationMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Color.lumen(.statusWarning))
                    .lineLimit(2)
                    .help(message)
                    .accessibilityLabel("Launch configuration issue: \(message)")
            }
        }
        .padding(.top, Lumen.Space.s4)
    }

    /// U9-4b: launch environment overrides on `LumenKeyValueEditor` (+ adds a row and selects it,
    /// − removes the selection). Disabled as a whole while the backend can't launch.
    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text("Environment")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LumenKeyValueEditor(entries: environmentBinding, emptyMessage: "No environment overrides")
                .controlSize(.small)
                .disabled(!viewModel.capabilities.launchSupport.isSupported)
                .accessibilityLabel("Environment overrides")
                .accessibilityIdentifier("debugger.launch.environment")
        }
    }

    /// The view model's entries as key/value rows. A row Lumen just added ("key1" with no value)
    /// comes back blank, as the old + did, so an untouched new row never launches as `key1=`;
    /// removing the last row leaves one blank row (the view model's rule).
    private var environmentBinding: Binding<[LumenKeyValue]> {
        Binding(
            get: {
                viewModel.launchEnvironmentEntries.map { LumenKeyValue(key: $0.key, value: $0.value, id: $0.id) }
            },
            set: { rows in
                viewModel.launchEnvironmentEntries = DebuggerLaunchEnvironmentRows.entries(
                    from: rows, known: Set(viewModel.launchEnvironmentEntries.map(\.id))
                )
            }
        )
    }
}

/// U9-4b: maps `LumenKeyValueEditor` rows back to the view model's environment entries.
enum DebuggerLaunchEnvironmentRows {
    /// A row Lumen just added (an id not in `known`, an auto-named "keyN" key, no value) becomes a
    /// blank entry, so an untouched + never launches as `key1=`. No rows leaves one blank entry.
    static func entries(from rows: [LumenKeyValue], known: Set<UUID>) -> [DebuggerEnvironmentEntry] {
        let entries = rows.map { row in
            let isFreshPlaceholder = !known.contains(row.id) && row.value.isEmpty
                && row.key.range(of: #"^key\d+$"#, options: .regularExpression) != nil
            return DebuggerEnvironmentEntry(id: row.id, key: isFreshPlaceholder ? "" : row.key, value: row.value)
        }
        return entries.isEmpty ? [DebuggerEnvironmentEntry()] : entries
    }
}

/// Exact-identity local process attach entry. PID text is intentionally absent from the
/// product-facing surface; process IDs are display/search fields inside `LocalProcessAttachSheet`
/// and never transport authority.
private struct AttachToProcessEditor: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let onPresentLocalProcessAttachSheet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            HStack(spacing: Lumen.Space.s4) {
                Text("Local process attach")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    onPresentLocalProcessAttachSheet()
                } label: {
                    Label("Attach to Process…", systemImage: "scope")
                }
                .controlSize(.small)
                .help("Open the exact-identity local process attach sheet")
                .accessibilityLabel("Open local process attach sheet")
            }

            Text(viewModel.localProcessCatalogStatusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(viewModel.localProcessCatalogStatusMessage)
                .accessibilityLabel("Local process attach status: \(viewModel.localProcessCatalogStatusMessage)")
        }
        .padding(.top, Lumen.Space.s4)
    }
}

struct LocalProcessAttachSheet: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let onDismiss: () -> Void
    @State private var searchText = ""
    @State private var filter: LocalProcessAttachFilter = .eligible
    @State private var tableSelection: DebuggerLocalProcessCatalogSelection?
    @FocusState private var isSearchFocused: Bool

    /// Lumen sheet: tile, title and catalog status at the top; the process
    /// list; the status, a quiet Cancel (Esc) and Attach as the accent action (Return) at the foot.
    var body: some View {
        LumenSheet(
            "Attach to Process",
            subtitle: viewModel.localProcessCatalogStatusMessage,
            systemImage: "scope",
            hue: .hueTeal,
            status: LumenSheetStatus(viewModel.localProcessAttachSheetStatus.message,
                                     tone: viewModel.localProcessAttachSheetStatus.isWarning ? .warning : .neutral),
            cancelAccessibilityIdentifier: "localProcessAttach.cancel",
            onCancel: onDismiss,
            primary: LumenBarAction("Attach", isEnabled: viewModel.canAttachSelectedLocalProcess,
                                 accessibilityIdentifier: "localProcessAttach.attach") { attachSelected() }
        ) {
            Text("Select a freshly observed process. MacScope authorizes the exact identity again before any LLDB attach command is issued.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Lumen.Space.s5) {
                TextField("Search processes, paths, users, or PID", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search local processes")
                    .accessibilityIdentifier("localProcessAttach.search")

                LumenModeSwitcher(selection: $filter, options: LocalProcessAttachFilter.allCases, style: .pill, title: \.title)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Local process eligibility filter")
                    .accessibilityIdentifier("localProcessAttach.filter")

                Button {
                    Task { await viewModel.refreshLocalProcessCatalog() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LumenQuietButtonStyle())
                .dsFocusRing()
                .disabled(!viewModel.canRefreshLocalProcessCatalog)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("localProcessAttach.refresh")
            }

            if viewModel.localProcessDiscoverySnapshot.isStale {
                Label("Stale — refresh required", systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.lumen(.statusWarning))
            }

            processTable
            selectedProcessDetails
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 560)
        .accessibilityIdentifier("localProcessAttach.sheet")
        .task {
            if viewModel.localProcessDiscoverySnapshot.generation == 0 {
                await viewModel.refreshLocalProcessCatalog()
            }
        }
        .onAppear {
            tableSelection = viewModel.selectedLocalProcessSelection
        }
        .onChange(of: viewModel.selectedLocalProcessSelection) { _, selection in
            tableSelection = selection
        }
        .onChange(of: tableSelection) { _, selection in
            guard let selection,
                  let entry = viewModel.localProcessDiscoverySnapshot.entries.first(where: { $0.selection == selection }) else {
                return
            }
            viewModel.selectLocalProcess(entry)
        }
        .onChange(of: filteredEntries) { _, entries in
            guard let selected = tableSelection,
                  entries.contains(where: { $0.selection == selected }) else {
                tableSelection = entries.first?.selection
                return
            }
        }
        .onSubmit { attachSelected() }
    }

    private func attachSelected() {
        guard viewModel.canAttachSelectedLocalProcess else { return }
        Task {
            await viewModel.attachSelectedLocalProcess()
            if viewModel.session.hasLiveProcessSession {
                onDismiss()
            }
        }
    }

    /// Lumen process list. Each row's tile carries its catalog eligibility
    /// (a green check when attachable, an amber warning otherwise); user, architecture and the full
    /// eligibility text stay in the details below. Selection maps PIDs onto the exact-identity
    /// catalog selection within this discovery snapshot; double-click attaches.
    private var processTable: some View {
        let entries = filteredEntries
        return ScrollView {
            LumenProcessList(
                entries.map { entry in
                    let uid = entry.fingerprint.effectiveUserID
                    return LumenProcess(
                        pid: Int32(truncatingIfNeeded: entry.fingerprint.processID),
                        name: entry.displayName,
                        path: entry.fingerprint.canonicalExecutablePath,
                        user: uid == 0 ? "root" : "uid \(uid)",
                        isPrivileged: uid != getuid(),
                        systemImage: entry.eligibility.isAttachable ? "checkmark.circle" : "exclamationmark.triangle",
                        hue: entry.eligibility.isAttachable ? .hueGreen : .hueOrange
                    )
                },
                selection: Binding(
                    get: {
                        guard let tableSelection,
                              let entry = entries.first(where: { $0.selection == tableSelection }) else { return nil }
                        return Int32(truncatingIfNeeded: entry.fingerprint.processID)
                    },
                    set: { pid in
                        tableSelection = pid.flatMap { pid in
                            entries.first { Int32(truncatingIfNeeded: $0.fingerprint.processID) == pid }?.selection
                        }
                    }
                ),
                onActivate: { _ in attachSelected() }
            )
            .padding(Lumen.Space.s4)
        }
        .frame(minHeight: 250)
        .background(Color.lumen(.deckBackground))
        .clipShape(RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                .stroke(Color.lumen(.borderSubtle), lineWidth: 1)
        )
        .accessibilityLabel("Local process table")
        .accessibilityIdentifier("localProcessAttach.table")
        .background(searchFocusShortcut)
    }

    private var searchFocusShortcut: some View {
        Button("Focus Process Search") {
            isSearchFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var selectedProcessDetails: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("Selected Process")
                .font(.caption.weight(.semibold))

            Text(selectedProcessDetailsText)
                .font(.caption)
                .lineLimit(7)
                .textSelection(.enabled)
        }
        .padding(Lumen.Space.s5)
        .background(Color.lumen(.deckBackground))
        .clipShape(RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Lumen.Radius.lg, style: .continuous)
                .stroke(Color.lumen(.borderSubtle), lineWidth: 1)
        )
        .accessibilityIdentifier("localProcessAttach.details")
    }

    private var selectedProcessDetailsText: String {
        if viewModel.isAuthorizingLocalProcessAttach {
            return "Verifying selected process…"
        }
        guard let entry = viewModel.selectedLocalProcessEntry else {
            return "Select an eligible process. Catalog eligibility starts verification; attach repeats exact identity authorization before LLDB receives any command."
        }
        return """
        Name: \(entry.displayName)
        PID: \(entry.fingerprint.processID)
        User: \(userText(for: entry))
        Architecture: \(architectureText(for: entry.fingerprint.architecture))
        Executable: \(entry.fingerprint.canonicalExecutablePath)
        Eligibility: \(eligibilityText(for: entry))
        """
    }

    private var filteredEntries: [DebuggerLocalProcessCatalogEntry] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return viewModel.localProcessDiscoverySnapshot.entries.filter { entry in
            guard filter.includes(entry) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return searchableText(for: entry).localizedLowercase.contains(normalizedQuery)
        }
    }

    private func searchableText(for entry: DebuggerLocalProcessCatalogEntry) -> String {
        [
            entry.displayName,
            entry.fingerprint.canonicalExecutablePath,
            "\(entry.fingerprint.processID)",
            userText(for: entry),
            architectureText(for: entry.fingerprint.architecture),
            eligibilityText(for: entry)
        ].joined(separator: " ")
    }

    private func rowAccessibilityIdentifier(for entry: DebuggerLocalProcessCatalogEntry) -> String {
        [
            "localProcessAttach.row",
            "\(entry.selection.discoveryGeneration)",
            "\(entry.fingerprint.processID)",
            "\(entry.fingerprint.startTime.seconds)",
            "\(entry.fingerprint.startTime.microseconds)"
        ].joined(separator: ".")
    }

    private func eligibilityText(for entry: DebuggerLocalProcessCatalogEntry) -> String {
        switch entry.eligibility {
        case .eligible:
            viewModel.localProcessDiscoverySnapshot.isStale ? "Refresh required" : "Eligible"
        case let .ineligible(denial):
            denial.displayReason
        case let .unknown(denial):
            denial.displayReason
        }
    }

    private func userText(for entry: DebuggerLocalProcessCatalogEntry) -> String {
        entry.fingerprint.realUserID == entry.fingerprint.effectiveUserID
            ? "uid \(entry.fingerprint.effectiveUserID)"
            : "uid \(entry.fingerprint.effectiveUserID) / ruid \(entry.fingerprint.realUserID)"
    }

    private func architectureText(for architecture: DebuggerLocalProcessArchitecture) -> String {
        switch architecture {
        case .arm64: "arm64"
        case .arm64e: "arm64e"
        }
    }
}

enum LocalProcessAttachFilter: String, CaseIterable, Identifiable {
    case eligible
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eligible: "Eligible"
        case .all: "All"
        }
    }

    func includes(_ entry: DebuggerLocalProcessCatalogEntry) -> Bool {
        switch self {
        case .eligible:
            entry.eligibility.isAttachable
        case .all:
            true
        }
    }
}

private struct DebuggerTargetPickerRow: View {
    let descriptor: DebuggerTargetSelectionDescriptor
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Lumen.Space.s4) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.lumen(.accent) : Color.secondary)
                    .frame(width: AppDebuggerChrome.targetPickerIconWidth)

                Image(systemName: descriptor.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: AppDebuggerChrome.targetPickerIconWidth)

                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    Text(descriptor.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(descriptor.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(descriptor.policy.statusTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(policyForeground)
                    .lineLimit(1)
            }
            .padding(.horizontal, Lumen.Space.s4)
            .padding(.vertical, AppDebuggerChrome.targetPickerRowVerticalPadding)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(rowFill, in: RoundedRectangle(cornerRadius: Lumen.Radius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.Radius.xs)
                    .stroke(
                        rowStroke,
                        lineWidth: AppInteractionChrome.rowStrokeWidth(
                            isSelected: isSelected,
                            isFocused: isFocused,
                            contrast: colorSchemeContrast
                        )
                    )
            }
            .workbenchFocusRing(isVisible: isFocused, radius: Lumen.Radius.xs)
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled() // violet workbenchFocusRing is the sole focus affordance (no system blue)
        .onHover { isHovering = $0 }
        .animation(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: reduceMotion), value: isHovering)
        .animation(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: reduceMotion), value: isSelected)
        .disabled(!descriptor.policy.isEnabled)
        .help(descriptor.detail)
        .accessibilityLabel(
            AppAccessibilityText.debuggerTargetLabel(
                title: descriptor.title,
                status: descriptor.policy.statusTitle,
                detail: descriptor.detail
            )
        )
        .accessibilityHint(isSelected ? "Selected debugger target" : "Selects this debugger target")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: Color {
        switch interactionState {
        case .selectedActive, .selectedInactive:
            AppInteractionChrome.toolFill(for: interactionState)
        case .focused, .hovered:
            Color.lumen(.sidebarRowHover)
        case .disabled:
            Color.lumen(.deckBackground)
        case .normal:
            Color.lumen(.deckRowBackground)
        }
    }

    private var rowStroke: Color {
        interactionState.isSelected || isFocused ? Color.lumen(.borderFocus) : Color.lumen(.borderSubtle)
    }

    private var policyForeground: Color {
        switch descriptor.policy {
        case .enabled:
            Color.lumen(.statusSuccess)
        case .blocked:
            .secondary
        case .unavailable:
            Color.lumen(.statusWarning)
        }
    }

    private var interactionState: AppInteractionState {
        AppInteractionChrome.sourceListState(
            isSelected: isSelected,
            isFocused: isFocused,
            isHovering: isHovering,
            isEnabled: descriptor.policy.isEnabled,
            isActiveWindow: isActiveWindow
        )
    }

    private var isActiveWindow: Bool {
        controlActiveState != .inactive
    }
}

private enum DebuggerTransportProminence {
    case live
    case compact
    case disabled

    var opacity: Double {
        switch self {
        case .live:
            1
        case .compact:
            AppDebuggerChrome.compactTransportOpacity
        case .disabled:
            AppDebuggerChrome.disabledTransportOpacity
        }
    }

    var accessibilityHint: String {
        switch self {
        case .live:
            "Debugger transport controls"
        case .compact:
            "Debugger transport controls are visually de-emphasized until a live process is connected"
        case .disabled:
            "Debugger transport controls are disabled because the debugger backend is unavailable"
        }
    }
}

private struct DebuggerTransportControls: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    var prominence: DebuggerTransportProminence = .live

    var body: some View {
        let launch = viewModel.controlAvailability(for: .launch)
        let continueExecution = viewModel.controlAvailability(for: .continueExecution)
        let stepOver = viewModel.controlAvailability(for: .stepOver)
        let stepInto = viewModel.controlAvailability(for: .stepInto)
        let stepOut = viewModel.controlAvailability(for: .stepOut)
        let pause = viewModel.controlAvailability(for: .pause)
        let sessionEndAction = viewModel.sessionEndAction
        let sessionEnd = viewModel.controlAvailability(for: sessionEndAction)
        let refreshSnapshot = viewModel.controlAvailability(for: .refreshSnapshot)

        ControlGroup {
            Button {
                Task { await viewModel.launchSelectedTarget() }
            } label: {
                Label("Launch", systemImage: "play.fill")
            }
            .disabled(!launch.isEnabled)
            .help(launch.helpText)

            Button {
                Task { await viewModel.continueExecution() }
            } label: {
                Label("Continue", systemImage: "play")
            }
            .disabled(!continueExecution.isEnabled)
            .help(continueExecution.helpText)

            Button {
                Task { await viewModel.stepOver() }
            } label: {
                Label("Step Over", systemImage: "arrow.turn.down.right")
            }
            .disabled(!stepOver.isEnabled)
            .help(stepOver.helpText)

            Button {
                Task { await viewModel.stepInto() }
            } label: {
                Label("Step Into", systemImage: "arrow.down.to.line")
            }
            .disabled(!stepInto.isEnabled)
            .help(stepInto.helpText)

            Button {
                Task { await viewModel.stepOut() }
            } label: {
                Label("Step Out", systemImage: "arrow.up.to.line")
            }
            .disabled(!stepOut.isEnabled)
            .help(stepOut.helpText)

            Button {
                Task { await viewModel.pause() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!pause.isEnabled)
            .help(pause.helpText)

            if viewModel.showsSessionEndAction {
                Button {
                    Task {
                        if sessionEndAction == .detach {
                            await viewModel.detach()
                        } else {
                            await viewModel.terminate()
                        }
                    }
                } label: {
                    Label(
                        sessionEndAction.title,
                        systemImage: sessionEndAction == .detach ? "eject" : "stop.fill"
                    )
                }
                .disabled(!sessionEnd.isEnabled)
                .help(sessionEnd.helpText)
            }

            Button {
                Task { await viewModel.refreshSnapshot() }
            } label: {
                Label("Refresh Snapshot", systemImage: "arrow.clockwise")
            }
            .disabled(!refreshSnapshot.isEnabled)
            .help(refreshSnapshot.helpText)
        }
        .controlGroupStyle(.navigation)
        .controlSize(.small)
        .opacity(prominence.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityHint(prominence.accessibilityHint)
    }
}


private extension DebuggerSourceInspectionPresentation {
    var systemImage: String {
        switch self {
        case .fresh: "checkmark.seal"
        case .unavailable: "questionmark.folder"
        }
    }

    var tone: LumenBadge.Tone {
        switch self {
        case .fresh: .success
        case .unavailable: .neutral
        }
    }
}

private struct DebuggerInspectionStatusStrip: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let sourceStatus: DebuggerSourceInspectionPresentation

    var body: some View {
        let presentation = DebuggerInspectionStatusPresentation(
            hasInspectionCoordinate: hasCoordinate,
            sourceStatus: sourceStatus,
            selectedThread: viewModel.selectedThread,
            selectedFrame: viewModel.selectedFrame
        )
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Lumen.Space.s4) {
                LumenBadge(presentation.coordinateTitle, systemImage: coordinateImage, tone: coordinateTone)
                LumenBadge(sourceStatus.title, systemImage: sourceStatus.systemImage, tone: sourceStatus.tone)
                Text(presentation.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(presentation.accessibilitySummary)
            }

            HStack(spacing: Lumen.Space.s4) {
                LumenBadge(presentation.coordinateTitle, systemImage: coordinateImage, tone: coordinateTone)
                Text(presentation.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
    }

    private var hasCoordinate: Bool {
        viewModel.currentInspectionCoordinate != nil
    }

    private var coordinateImage: String {
        hasCoordinate ? "scope" : "scope.badge.questionmark"
    }

    private var coordinateTone: LumenBadge.Tone {
        hasCoordinate ? .success : .neutral
    }
}

private struct ConsoleDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        // Read-only Lumen console transcript (command input is DBG-1).
        LumenConsole(lines: consoleLines)
    }

    private var consoleLines: [LumenConsoleLine] {
        // Stable ids so the transcript doesn't re-scroll when nothing changed.
        var lines = [LumenConsoleLine(viewModel.lastError == nil ? .output : .warning, "lldb  \(viewModel.statusDetail)",
                                   id: Self.lldbLineID),
                     LumenConsoleLine(.output, "state  \(viewModel.session.processState.detail)", id: Self.stateLineID)]
        if viewModel.capabilities.summary != viewModel.statusDetail {
            lines.append(LumenConsoleLine(.output, "backend  \(viewModel.capabilities.summary)", id: Self.backendLineID))
        }
        return lines
    }

    private static let lldbLineID = UUID()
    private static let stateLineID = UUID()
    private static let backendLineID = UUID()
}

private struct ConsoleLine: View {
    let prefix: String
    let message: String
    let tone: Color
    var lineLimit = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Text(prefix)
                .font(AppTypography.bytes)
                .foregroundStyle(.secondary)
                .frame(width: AppDebuggerChrome.consolePrefixWidth, alignment: .trailing)
            Text(message)
                .font(AppTypography.pseudocode)
                .foregroundStyle(tone)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Lumen.Space.s1)
        .help(message)
    }
}

private struct FramesDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let revealTarget: ImageAddress?
    let onRevealSelectedFrame: () -> Void

    var body: some View {
        let frames = viewModel.frames
        let selectedFrameID = viewModel.selectedFrame?.id
        DeckScrollView {
            if frames.isEmpty {
                DeckEmptyView("No process is running.")
            } else {
                HStack {
                    Spacer()
                    Button(action: onRevealSelectedFrame) {
                        Label("Reveal in Disassembly", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                    .disabled(revealTarget == nil)
                    .help(revealTarget == nil
                        ? "A stopped frame must map to a decoded instruction in the current workspace image."
                        : "Open the selected frame's instruction in disassembly.")
                }
                // Lumen stack frame list.
                LumenStackFrameList(
                    frames.map { frame in
                        LumenStackFrame(
                            index: frame.index,
                            function: frame.functionName,
                            address: frame.address,
                            location: frame.sourceLocation ?? frame.moduleName,
                            isSystem: frame.sourceLocation == nil
                        )
                    },
                    selection: Binding(
                        get: { frames.first { $0.id == selectedFrameID }?.index },
                        set: { index in
                            if let index { Task { await viewModel.selectFrame(index) } }
                        }
                    )
                )
                .accessibilityHint("Selects a stack frame for source, variables, registers, and memory inspection.")
            }
        }
    }

}

private struct ThreadsDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let threads = viewModel.threads
        let availability = viewModel.controlAvailability(for: .selectThread)
        DeckScrollView {
            if threads.isEmpty {
                DeckEmptyView("No threads recovered.")
            } else {
                ForEach(threads) { thread in
                    Button {
                        Task { await viewModel.selectThread(thread.index) }
                    } label: {
                        DeckKeyValueRow(
                            key: thread.isSelected ? "▶ #\(thread.index)" : "#\(thread.index)",
                            value: thread.topFrameFunctionName ?? (thread.topFrameAddress?.hexAddress ?? "unknown"),
                            detail: threadDetail(for: thread)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!availability.isEnabled)
                    .help(availability.isEnabled ? "Select this thread" : availability.helpText)
                    .accessibilityLabel(threadAccessibilityLabel(thread))
                }
            }
        }
    }

    private func threadDetail(for thread: DebuggerThreadSummary) -> String? {
        var parts: [String] = []
        if let name = thread.name {
            parts.append(name)
        }
        if let queueName = thread.queueName {
            parts.append("queue \(queueName)")
        }
        if let stopReason = thread.stopReason {
            parts.append(stopReason.displayTitle)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func threadAccessibilityLabel(_ thread: DebuggerThreadSummary) -> String {
        var parts = [
            thread.isSelected ? "Selected thread \(thread.index)" : "Thread \(thread.index)"
        ]
        if let function = thread.topFrameFunctionName {
            parts.append(function)
        }
        if let address = thread.topFrameAddress {
            parts.append(address.hexAddress)
        }
        if let detail = threadDetail(for: thread) {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }
}

private struct RegistersDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let groups = viewModel.formattedGroupedRegisters
        DeckScrollView {
            ValueFormatPicker(viewModel: viewModel)

            if groups.isEmpty {
                DeckEmptyView("No register snapshot.")
            } else {
                ForEach(groups, id: \.group) { entry in
                    // Lumen register grid: one card per register; a register
                    // that changed since the last snapshot is marked.
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        LumenSectionHeader(entry.group.displayTitle)
                        LumenRegisterGrid(entry.registers.map { register in
                            LumenRegister(register.name, value: register.value, role: register.role,
                                       changed: viewModel.changedRegisterNames.contains(register.name))
                        }) { register in
                            // Seed the write field with the canonical hex form, not the (possibly
                            // decimal/float) display string, so `register write` accepts it.
                            viewModel.registerWriteNameText = register.name
                            viewModel.registerWriteValueText = viewModel.hexValue(forRegisterNamed: register.name) ?? register.value
                        }
                        .help("Click a register to edit it")
                    }
                    .padding(.top, Lumen.Space.s2)
                }
            }

            RegisterWriteEditor(viewModel: viewModel)
            ExpressionEvaluatorEditor(viewModel: viewModel)
        }
    }
}

/// Segmented control toggling how register / memory values are displayed
/// (hex / decimal / signed / float). Pure presentation — re-renders the already
/// read values without re-reading them from the target.
private struct ValueFormatPicker: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        // Lumen pill switcher.
        LumenModeSwitcher(selection: $viewModel.valueFormat, options: DebuggerValueFormat.allCases, style: .pill, title: \.displayTitle)
        .accessibilityElement(children: .contain)
        .help("Display register and memory values as hex, decimal, signed decimal, or float.")
        .accessibilityLabel("Value display format")
    }
}

private struct ExpressionEvaluatorEditor: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let availability = viewModel.controlAvailability(for: .evaluateExpression)
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            // Lumen command field and evaluation result.
            LumenCommandField(
                "expr",
                parts: [LumenCommandPart($viewModel.expressionText, prompt: "x0 + 1", accessibilityLabel: "Expression")],
                actionTitle: "Evaluate",
                isEnabled: availability.isEnabled,
                help: availability.helpText
            ) {
                Task { await viewModel.evaluate() }
            }
            if let result = viewModel.expressionResult {
                LumenEvaluationResult(result.value, type: result.type)
            }
            Divider()
            // Lumen watch list: the "may execute code" note is the caution by Evaluate.
            LumenWatchList(
                viewModel.watchDefinitions.map { definition in
                    let evaluation = viewModel.watchEvaluations[definition.id]
                    return LumenWatch(
                        id: definition.id.uuidString,
                        expression: definition.expression,
                        value: evaluation?.value,
                        type: evaluation?.type,
                        error: evaluation?.error
                    )
                },
                newExpression: $viewModel.watchExpressionText,
                limit: DebuggerPanelViewModel.maximumWatchCount,
                canEvaluate: viewModel.canEvaluateWatches,
                caution: viewModel.watchesAreSaved
                    ? "Definitions are saved with this workspace. Values are transient; evaluation is manual and may execute code."
                    : "Definitions are retained for this workspace session. Values are transient; evaluation is manual and may execute code.",
                onEvaluate: { Task { await viewModel.evaluateWatches() } },
                onAdd: { viewModel.addWatch(expression: $0) },
                onRemove: { id in
                    if let uuid = UUID(uuidString: id) { viewModel.removeWatch(id: uuid) }
                }
            )
            if let error = viewModel.watchAuthoringError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, Lumen.Space.s4)
    }
}

private struct RegisterWriteEditor: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let availability = viewModel.controlAvailability(for: .writeRegister)
        // Lumen command field: "reg" verb, inputs split by hairlines.
        LumenCommandField(
            "reg",
            parts: [LumenCommandPart($viewModel.registerWriteNameText, prompt: "x0", width: 44, accessibilityLabel: "Register name"),
                    LumenCommandPart($viewModel.registerWriteValueText, prompt: "0x… or decimal", accessibilityLabel: "Register value")],
            actionTitle: "Write",
            isEnabled: availability.isEnabled,
            help: availability.helpText
        ) {
            Task { await viewModel.writeRegister() }
        }
        .padding(.top, Lumen.Space.s4)
    }
}

private struct VariablesDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let sourceStatus: DebuggerSourceInspectionPresentation

    var body: some View {
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: viewModel.currentInspectionCoordinate,
            selectedFrame: viewModel.selectedFrame,
            variableScopes: viewModel.session.variableScopes,
            collapsedTokens: viewModel.collapsedVariableTokens,
            expansionStates: viewModel.variableExpansionStates,
            activeExpansionToken: viewModel.activeVariableExpansionToken,
            changedVariableKeys: viewModel.changedVariableKeys
        )
        DeckScrollView {
            // The selected frame shows in the stack list (Lumen parity); the source status stays.
            DeckKeyValueRow(
                key: "source",
                value: sourceStatus.title,
                detail: sourceStatus.detail
            )

            if presentation.groups.isEmpty {
                DeckEmptyView(presentation.variableStatusText)
                    .accessibilityLabel(presentation.variableStatusText)
            } else {
                ForEach(presentation.groups) { group in
                    VariableScopeSection(group: group, viewModel: viewModel)
                }
            }
        }
    }
}

/// One scope group as a Lumen variable tree section.
private struct VariableScopeSection: View {
    let group: DebuggerVariablesInspectionPresentation.Group
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let rowsByID = Dictionary(group.rows.map { (Self.variableID($0), $0) }, uniquingKeysWith: { first, _ in first })
        LumenVariableTree([
            LumenVariableSection(
                group.title,
                variables: group.rows.map { row in
                    LumenVariable(
                        id: Self.variableID(row),
                        depth: row.depth,
                        name: row.name,
                        type: row.detailText,
                        value: row.value,
                        disclosure: Self.disclosure(row),
                        changed: row.isChanged,
                        toggleDisabledReason: (row.isExpanded || row.isCollapsed)
                            ? nil : viewModel.variableExpansionDisabledReason(for: row)
                    )
                },
                emptyMessage: group.emptyText,
                truncationMessage: group.wasTruncated ? group.truncationText : nil
            )
        ]) { variable in
            if let row = rowsByID[variable.id] { viewModel.toggleVariableDisclosure(row) }
        }
        .padding(.top, Lumen.Space.s4)
    }

    /// A row's identity in the tree: its path from the scope root.
    private static func variableID(_ row: DebuggerVariablesInspectionPresentation.Row) -> String {
        row.pathComponents.joined(separator: "\u{1F}")
    }

    private static func disclosure(_ row: DebuggerVariablesInspectionPresentation.Row) -> LumenVariable.Disclosure {
        guard row.isExpandable else { return .none }
        if case .loading = row.expansionState { return .loading }
        if case .failed = row.expansionState { return .failed }
        return row.isExpanded ? .expanded : .collapsed
    }
}

private struct MemoryDeckView: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let regions = viewModel.session.memoryRegions
        DeckScrollView {
            ValueFormatPicker(viewModel: viewModel)
            MemoryInspectionStatusRow(viewModel: viewModel, regionCount: regions.count)

            if regions.isEmpty {
                DeckEmptyView("No memory summary.")
            } else {
                ForEach(regions) { region in
                    if viewModel.valueFormat == .hex, !region.previewBytes.isEmpty {
                        // Lumen quiet hex dump.
                        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                            LumenSectionHeader(region.label ?? "\(region.byteCount) bytes")
                            LumenHexDump(region.previewBytes, baseAddress: region.address,
                                      selection: selectionBinding(for: region))
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(memoryAccessibilityLabel(region))
                    } else {
                        DeckKeyValueRow(
                            key: region.address.hexAddress,
                            value: viewModel.formattedMemoryPreview(for: region),
                            detail: region.label ?? "\(region.byteCount) bytes"
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(memoryAccessibilityLabel(region))
                    }
                }
            }

            MemoryReadEditor(viewModel: viewModel)
            MemoryWriteEditor(viewModel: viewModel)
        }
    }

    @State private var selections: [DebuggerMemorySummary.ID: Range<Int>] = [:]

    private func selectionBinding(for region: DebuggerMemorySummary) -> Binding<Range<Int>?> {
        Binding(get: { selections[region.id] }, set: { selections[region.id] = $0 })
    }

    private func memoryAccessibilityLabel(_ region: DebuggerMemorySummary) -> String {
        let label = region.label ?? "\(region.byteCount) bytes"
        return "Memory at \(region.address.hexAddress), \(label), preview \(region.previewText)"
    }
}

private struct MemoryInspectionStatusRow: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel
    let regionCount: Int

    var body: some View {
        let presentation = DebuggerMemoryInspectionPresentation(
            hasInspectionCoordinate: viewModel.currentInspectionCoordinate != nil,
            regionCount: regionCount
        )
        HStack(spacing: Lumen.Space.s4) {
            LumenBadge(presentation.coordinateTitle, systemImage: coordinateImage, tone: coordinateTone)
            Text(presentation.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
    }

    private var hasCoordinate: Bool {
        viewModel.currentInspectionCoordinate != nil
    }

    private var coordinateImage: String {
        hasCoordinate ? "lock.open" : "lock"
    }

    private var coordinateTone: LumenBadge.Tone {
        hasCoordinate ? .success : .neutral
    }
}

private struct MemoryReadEditor: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let availability = viewModel.controlAvailability(for: .readMemory)
        // Lumen command field: "read" verb, inputs split by hairlines.
        LumenCommandField(
            "read",
            parts: [LumenCommandPart($viewModel.memoryReadAddressText, prompt: "0x…", accessibilityLabel: "Memory address"),
                    LumenCommandPart($viewModel.memoryReadByteCountText, prompt: "bytes", width: 60, accessibilityLabel: "Byte count")],
            actionTitle: "Read",
            isEnabled: availability.isEnabled,
            help: availability.helpText
        ) {
            Task { await viewModel.readMemory() }
        }
        .padding(.top, Lumen.Space.s4)
    }
}

private struct MemoryWriteEditor: View {
    @ObservedObject var viewModel: DebuggerPanelViewModel

    var body: some View {
        let availability = viewModel.controlAvailability(for: .writeMemory)
        // Lumen command field: "mem" verb, inputs split by hairlines.
        LumenCommandField(
            "mem",
            parts: [LumenCommandPart($viewModel.memoryWriteAddressText, prompt: "0x…", accessibilityLabel: "Memory address"),
                    LumenCommandPart($viewModel.memoryWriteBytesText, prompt: "0x2a 0xff", accessibilityLabel: "Bytes to write")],
            actionTitle: "Write",
            isEnabled: availability.isEnabled,
            help: availability.helpText
        ) {
            Task { await viewModel.writeMemory() }
        }
        .padding(.top, Lumen.Space.s4)
    }
}

private struct ProblemsDeckView: View {
    let message: String?

    var body: some View {
        DeckScrollView {
            if let message {
                ConsoleLine(prefix: "issue", message: message, tone: Color.lumen(.statusWarning))
            } else {
                DeckEmptyView("No debugger problems reported.")
            }
        }
    }
}

private struct DeckScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Lumen.Space.s7)
            .padding(.vertical, Lumen.Space.s4)
        }
        .background(Color.lumen(.deckBackground))
    }
}

private struct DeckKeyValueRow: View {
    let key: String
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s6) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: AppDebuggerChrome.deckKeyWidth, alignment: .leading)

            Text(value)
                .font(AppTypography.bytes)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(minWidth: AppDebuggerChrome.deckValueMinWidth, alignment: .leading)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Lumen.Space.s4)
        .padding(.vertical, Lumen.Space.s2)
        .background(Color.lumen(.deckRowBackground), in: RoundedRectangle(cornerRadius: Lumen.Radius.xs))
    }
}

private struct DeckEmptyView: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Lumen.Space.s4)
    }
}

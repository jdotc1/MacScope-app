import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App-owned File/Open ingress when no document supplies a focused command target.
/// Binary imports retain the existing once-consumed window queue; package opens retain
/// the coordinator's validation, canonical ownership and duplicate activation authority.
@MainActor
final class WorkspaceApplicationOpenRouter {
    static weak var installed: WorkspaceApplicationOpenRouter?
    private let registry: WorkspaceSessionRegistry
    private let coordinator: WorkspaceOpenCoordinator
    private let storeFactory: @MainActor () -> WorkspaceStore
    private let windowIdentity: @MainActor (WorkspaceWindowID) -> ObjectIdentifier?
    private var presentWindow: (@MainActor (WorkspaceWindowID) -> Void)?
    private var isOpening = false
    private var pendingExternalOpens: [URL] = []
    private var externalOpenTasks: [Task<Void, Never>] = []
    private(set) var lastExternalOpenOutcome: WorkspaceOpenDisposition?

    init(registry: WorkspaceSessionRegistry, coordinator: WorkspaceOpenCoordinator,
         storeFactory: @escaping @MainActor () -> WorkspaceStore = { WorkspaceStore.bootstrap() },
         windowIdentity: @escaping @MainActor (WorkspaceWindowID) -> ObjectIdentifier? = { _ in nil }) {
        self.registry = registry
        self.coordinator = coordinator
        self.storeFactory = storeFactory
        self.windowIdentity = windowIdentity
    }

    func installWindowPresenter(_ presenter: @escaping @MainActor (WorkspaceWindowID) -> Void) {
        presentWindow = presenter
        guard !pendingExternalOpens.isEmpty else { return }
        let pending = pendingExternalOpens
        pendingExternalOpens.removeAll()
        openExternalDocuments(pending)
    }

    /// LaunchServices open-document ingress (`open -a`, Finder double-click, Dock drop), delivered
    /// by `MacScopeApplicationDelegate.application(_:open:)` both at launch and while running.
    ///
    /// SwiftUI's `onOpenURL` never fires for these events in the value-keyed `WindowGroup`, so the
    /// app delegate owns them. A cold-launch event can arrive before any window has mounted its
    /// `openWindow` presenter; those URLs wait here and drain when the first window installs it.
    /// A package goes through the coordinator (validation, duplicate activation) and prefers the
    /// pristine launch window over leaving a stray Untitled Workspace beside the document.
    func openExternalDocuments(_ urls: [URL]) {
        guard let presentWindow else {
            pendingExternalOpens.append(contentsOf: urls)
            return
        }
        for url in urls {
            guard url.isFileURL else { continue }
            if url.pathExtension.lowercased() == "ips" {
                let focused = NSApp.keyWindow.flatMap {
                    registry.storeForWindow(identity: ObjectIdentifier($0), resolve: windowIdentity)
                }
                CrashReportWindowPresenter.shared.open(url, store: focused)
            } else if Self.isWorkspacePackage(url) {
                let reusable: WorkspaceWindowID? =
                    registry.isReusableDocumentWindow(.primary) ? .primary : nil
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let outcome = await self.coordinator.open(
                        WorkspaceOpenRequest(url: url, source: .finder,
                                             preferredReusableWindow: reusable)
                    )
                    switch outcome {
                    case .openedWindow(let id), .reusedWindow(let id):
                        presentWindow(id)
                    case .activatedExisting:
                        break
                    case .rejected:
                        self.presentFailureIfNeeded(outcome)
                    }
                    self.lastExternalOpenOutcome = outcome
                }
                externalOpenTasks.append(task)
            } else {
                _ = enqueueBinary(url, openWindow: presentWindow)
            }
        }
    }

    /// Test seam: waits for every package open started by `openExternalDocuments`.
    func waitForExternalOpens() async {
        while !externalOpenTasks.isEmpty {
            let tasks = externalOpenTasks
            externalOpenTasks.removeAll()
            for task in tasks { await task.value }
        }
    }

    static func isWorkspacePackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == MacScopeDocumentPackage.fileExtension.lowercased()
    }

    /// Intent success acknowledges the exact installed binary, not a transient notification.
    /// Wait through native slice selection; cancellation/timeouts retire only this ticket.
    func openBinaryAcknowledged(_ url: URL, preferredStore: WorkspaceStore? = nil,
                                timeout: Duration = .seconds(120)) async throws -> UUID {
        guard !isOpening else { throw WorkspaceApplicationOpenError.busy }
        isOpening = true
        defer { isOpening = false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while presentWindow == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw WorkspaceApplicationOpenError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard let presentWindow else { throw WorkspaceApplicationOpenError.unavailable }

        let id: WorkspaceWindowID
        let store: WorkspaceStore
        let createdEntry: Bool
        if let preferredStore, let owner = registry.windowID(for: preferredStore),
           registry.isReusableDocumentWindow(owner) {
            id = owner
            store = preferredStore
            createdEntry = false
        } else {
            id = .fresh()
            store = storeFactory()
            registry.adopt(store, for: id)
            createdEntry = true
        }
        guard registry.storeIfPresent(for: id) === store,
              let session = registry.documentSessionIfPresent(for: id),
              !session.isClosedForWindowClose else { throw WorkspaceApplicationOpenError.displaced }
        guard !session.isTerminationPreparationActive else { throw WorkspaceApplicationOpenError.terminating }
        let ticket = store.beginImport(url: url)
        presentWindow(id)
        var owningWindow = windowIdentity(id)
        defer {
            store.cancelBinaryOpen(ticket)
            // A scene that never mounted has no WindowLifecycleReader to release
            // its adopted authorities. Retire only our still-empty exact entry;
            // neither a mounted window nor an installed document is disposable.
            if createdEntry, owningWindow == nil, windowIdentity(id) == nil,
               registry.storeIfPresent(for: id) === store,
               registry.documentSessionIfPresent(for: id) === session,
               store.snapshot.binaries.isEmpty,
               store.binaryOpenState?.id == ticket {
                registry.evict(id)
            }
        }
        while true {
            try Task.checkCancellation()
            guard !session.isTerminationPreparationActive else { throw WorkspaceApplicationOpenError.terminating }
            guard registry.storeIfPresent(for: id) === store,
                  registry.documentSessionIfPresent(for: id) === session,
                  !session.isClosedForWindowClose,
                  let state = store.binaryOpenState, state.id == ticket else {
                throw WorkspaceApplicationOpenError.displaced
            }
            if let currentWindow = windowIdentity(id) {
                if let owningWindow, owningWindow != currentWindow {
                    throw WorkspaceApplicationOpenError.displaced
                }
                owningWindow = currentWindow
            } else if owningWindow != nil {
                throw WorkspaceApplicationOpenError.displaced
            }
            switch state.phase {
            case .completed(let binaryID):
                guard store.snapshot.binaries.contains(where: { $0.id == binaryID }) else {
                    throw WorkspaceApplicationOpenError.displaced
                }
                if owningWindow != nil { return binaryID }
            case .failed(let reason): throw WorkspaceApplicationOpenError.failed(reason)
            case .cancelled: throw CancellationError()
            default: break
            }
            guard clock.now < deadline else { throw WorkspaceApplicationOpenError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func openIntentBinary(_ url: URL, preferredStore: WorkspaceStore?,
                                 startupTimeout: Duration = .seconds(10)) async throws -> UUID {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        while installed == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw WorkspaceApplicationOpenError.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let router = installed else { throw WorkspaceApplicationOpenError.unavailable }
        return try await router.openBinaryAcknowledged(url, preferredStore: preferredStore)
    }

    @discardableResult
    func enqueueBinary(_ url: URL, openWindow: (WorkspaceWindowID) -> Void) -> Bool {
        let id = WorkspaceWindowID.fresh()
        guard registry.setPendingBinaryOpen(url, for: id) else { return false }
        openWindow(id)
        return true
    }

    func openWorkspace(_ url: URL, source: WorkspaceOpenSource,
                       openWindow: (WorkspaceWindowID) -> Void) async -> WorkspaceOpenDisposition {
        let outcome = await coordinator.open(.init(url: url, source: source,
                                                  preferredReusableWindow: nil))
        if case .openedWindow(let id) = outcome { openWindow(id) }
        return outcome
    }

    func presentBinaryPanel(openWindow: (WorkspaceWindowID) -> Void) {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a macOS executable, app bundle, framework, or dylib."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = enqueueBinary(url, openWindow: openWindow)
    }

    func presentWorkspacePanel(openWindow: (WorkspaceWindowID) -> Void) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(MacScopeDocumentPackage.formatIdentifier) ?? .package]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        presentFailureIfNeeded(await openWorkspace(url, source: .fileMenu, openWindow: openWindow))
    }

    func openRecent(_ url: URL, openWindow: (WorkspaceWindowID) -> Void) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        presentFailureIfNeeded(await openWorkspace(url, source: .recentMenu, openWindow: openWindow))
    }

    private func presentFailureIfNeeded(_ outcome: WorkspaceOpenDisposition) {
        guard case .rejected(let reason) = outcome,
              let message = WorkspaceOpenFailurePresentation.message(for: reason) else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t Open Workspace"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum WorkspaceApplicationOpenError: LocalizedError {
    case unavailable, busy, timedOut, displaced, terminating
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "MacScope's window opener is not ready."
        case .busy: "Another MacScope open request is still pending."
        case .timedOut: "The MacScope open request timed out before its window and binary were ready."
        case .displaced: "The requesting MacScope document was closed, replaced, or superseded."
        case .terminating: "MacScope is preparing to quit; the open request was cancelled."
        case .failed(let reason): "MacScope couldn’t open the binary: \(reason)"
        }
    }
}

struct MacScopeCommands: Commands {
    let applicationOpenRouter: WorkspaceApplicationOpenRouter
    /// The user's (possibly customized) keyboard bindings, resolved from `UserDefaults` at
    /// build time. For the curated set of `BindableCommand`s the chord comes from here so a
    /// keybinding-editor override actually rebinds the menu command; every other command
    /// keeps its hard-coded literal. The set is loaded once per `body` evaluation, which
    /// SwiftUI re-runs when the app reconfigures its commands.
    private let bindings = KeyBindingSet.load(from: .standard)

    /// The FOCUSED document's store (WS-2). Menu commands address this store so, with multiple
    /// document windows, a command reaches only the front one. Exactly one window today ⇒ this is
    /// always the only store ⇒ behavior is byte-identical.
    @FocusedValue(\FocusedValues.workspaceStore) private var focusedStore: WorkspaceStore?
    @FocusedValue(\.nativeDecompilerCommands)
    private var focusedNativeDecompilerCommands:
        (any NativeDecompilerWindowCommandRouting)?
    @FocusedValue(\.reconstructionWindowCommands)
    private var focusedReconstructionCommands: ReconstructionWindowCommandRouting?
    /// Whether the focused window has at least two analyzed images to compare (M8).
    @FocusedValue(\.versionCompareAvailable) private var versionCompareAvailable: Bool?
    /// SwiftUI's window opener — File ▸ New Window spawns a fresh document window (WS-2 Stage 3).
    @Environment(\.openWindow) private var openWindow

    /// The resolved chord for a bindable command, as a SwiftUI `KeyboardShortcut`.
    private func chord(_ command: BindableCommand) -> KeyboardShortcut {
        bindings.chord(for: command).keyboardShortcut
    }

    /// Posts a menu command stamped with the focused store as its target (WS-2). `object` keeps
    /// its existing per-command meaning (nil for most, a payload for a few); the target store
    /// rides in `userInfo` so no existing payload path changes. With no focused document the
    /// command is a no-op (nobody's guard matches an absent target).
    private func postCommand(name: Notification.Name, object: Any? = nil) {
        let userInfo = focusedStore.map { [WorkspaceStore.commandTargetStoreKey: $0] }
        NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
    }

    private func nativeCommandIsEnabled(_ command: NativeDecompilerControlCommand) -> Bool {
        focusedNativeDecompilerCommands?.enabledCommands.contains(command) == true
    }

    private func reconstructionCommandIsEnabled(_ command: ReconstructionCommandKind) -> Bool {
        focusedReconstructionCommands?.canPerform(command) == true
    }

    private func performReconstructionCommand(_ command: ReconstructionCommandKind) {
        _ = focusedReconstructionCommands?.perform(command)
    }

    private func reconstructionCommandHelp(_ command: ReconstructionCommandKind) -> String {
        focusedReconstructionCommands?.help(for: command)
            ?? "Focus a MacScope document window to use Reconstruction commands."
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Window") {
                // WS-2: a fresh, empty document window with its own store.
                openWindow(value: WorkspaceWindowID.fresh())
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open Binary...") {
                if focusedStore != nil {
                    postCommand(name: .macScopeOpenBinary, object: nil)
                } else {
                    applicationOpenRouter.presentBinaryPanel { openWindow(value: $0) }
                }
            }
            .keyboardShortcut(chord(.openBinary))

            Button("Open Crash Report...") {
                CrashReportWindowPresenter.shared.presentPanel(store: focusedStore)
            }

            Button("Load Additional Binary...") {
                postCommand(name: .macScopeLoadAdditionalBinary, object: nil)
            }
            // ⌥⌘O — ⇧⌘O is already taken by Open Workspace; avoid the collision.
            .keyboardShortcut("o", modifiers: [.command, .option])

            Button("Reanalyze COFF Object") {
                focusedStore?.reanalyzeFocusedCOFFObject()
            }
            .disabled(focusedStore?.canReanalyzeFocusedCOFFObject != true)
            .help("Assign stable section addresses. Existing annotations and overrides are preserved; annotations at old addresses may remain unresolved.")

            Button("Open Workspace...") {
                if focusedStore != nil {
                    postCommand(name: .macScopeOpenProject, object: nil)
                } else {
                    Task { @MainActor in
                        await applicationOpenRouter.presentWorkspacePanel { openWindow(value: $0) }
                    }
                }
            }
            .keyboardShortcut(chord(.openProject))

            Button("Read Debug Symbols File...") {
                postCommand(name: .macScopeReadDebugSymbols, object: nil)
            }

            Button("Import C Header...") {
                postCommand(name: .macScopeImportCHeader, object: nil)
            }

            Menu("Open Recent") {
                let recents = NSDocumentController.shared.recentDocumentURLs
                if recents.isEmpty {
                    Button("No Recent Workspaces") {}.disabled(true)
                } else {
                    ForEach(recents, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            if focusedStore != nil {
                                postCommand(name: .macScopeOpenRecentDocument, object: url)
                            } else {
                                Task { @MainActor in
                                    await applicationOpenRouter.openRecent(url) { openWindow(value: $0) }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                postCommand(name: .macScopeSave, object: nil)
            }
            .keyboardShortcut(chord(.save))

            Button("Save As...") {
                postCommand(name: .macScopeSaveAs, object: nil)
            }
            .keyboardShortcut(chord(.saveAs))

            Button("Save a Copy...") {
                postCommand(name: .macScopeSaveCopy, object: nil)
            }

            Divider()

            Button("Reload From Disk") {
                postCommand(name: .macScopeReloadFromDisk, object: nil)
            }

            Button("Keep Local Version") {
                postCommand(name: .macScopeKeepLocalVersion, object: nil)
            }

            Divider()

            Button("Export Listing...") {
                postCommand(name: .macScopeExportListing, object: nil)
            }
            .keyboardShortcut(chord(.exportListing))

            Button("Export Pseudocode...") {
                postCommand(name: .macScopeExportPseudocode, object: nil)
            }
            .keyboardShortcut(chord(.exportPseudocode))

            Button("Export All Pseudocode...") {
                postCommand(name: .macScopeExportAllPseudocode, object: nil)
            }

            Button("Export Objective-C Header...") {
                postCommand(name: .macScopeExportObjectiveCHeader, object: nil)
            }

            Button("Export Swift Interface...") {
                postCommand(name: .macScopeExportSwiftInterface, object: nil)
            }

            Button("Export Graph as PDF...") {
                postCommand(name: .macScopeExportGraphPDF, object: nil)
            }

            Button("Export Types as C Header...") {
                postCommand(name: .macScopeExportTypeCatalog, object: nil)
            }

            Button("Export BinExport2 (BinDiff)...") {
                postCommand(name: .macScopeExportBinExport2, object: nil)
            }
        }

        // Keep editor commands in the one system View menu. LumenViewCommands replaces
        // .sidebar for focused panel bindings; attaching these items to that replaced
        // group drops them from the native menu. The independent .toolbar View-menu
        // placement preserves the editor/history items and their keyboard shortcuts.
        CommandGroup(after: .toolbar) {
            Divider()

            ForEach(EditorMode.allCases) { mode in
                Button(mode.rawValue) {
                    postCommand(name: .macScopeSetEditorMode, object: mode)
                }
                .keyboardShortcut(mode.keyboardShortcut, modifiers: [.command])
            }

            Divider()

            Button("Navigation History") {
                postCommand(name: .macScopeToggleNavigationHistory, object: nil)
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])

            Button("Problems") {
                postCommand(name: .macScopeToggleProblems, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Signature & Dependencies") {
                postCommand(name: .macScopeToggleMachOMetadata, object: nil)
            }

            Button("Compare Images...") {
                postCommand(name: .macScopeShowVersionCompare, object: nil)
            }
            .disabled(versionCompareAvailable != true)
            .help("Match the functions of two images loaded in this workspace")

            Button("Reset Graph Layout") {
                postCommand(name: .macScopeResetGraphLayout, object: nil)
            }
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy Current Address") {
                postCommand(name: .macScopeCopyAddress, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Copy Hex String of Selected Bytes") {
                postCommand(name: .macScopeCopyHexString, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
        }

        CommandMenu("Navigate") {
            Button("Open Quickly...") {
                postCommand(name: .macScopeShowCommandPalette, object: nil)
            }
            .keyboardShortcut(chord(.openQuickly))

            Divider()

            Button("Go to Address...") {
                postCommand(name: .macScopeShowGoTo, object: nil)
            }
            .keyboardShortcut(chord(.goToAddress))

            Button("Find...") {
                postCommand(name: .macScopeFind, object: nil)
            }
            .keyboardShortcut(chord(.find))

            Button("Find Next") {
                postCommand(name: .macScopeFindNext, object: nil)
            }
            .keyboardShortcut(chord(.findNext))

            Button("Find Previous") {
                postCommand(name: .macScopeFindPrevious, object: nil)
            }
            .keyboardShortcut(chord(.findPrevious))

            Divider()

            Button("Imports...") {
                postCommand(name: .macScopeShowBrowsers, object: BrowserPane.imports)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Exports...") {
                postCommand(name: .macScopeShowBrowsers, object: BrowserPane.exports)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Sections...") {
                postCommand(name: .macScopeShowBrowsers, object: BrowserPane.sections)
            }

            Divider()

            Button("Back") {
                postCommand(name: .macScopeNavigateBack, object: nil)
            }
            .keyboardShortcut(chord(.navigateBack))

            Button("Forward") {
                postCommand(name: .macScopeNavigateForward, object: nil)
            }
            .keyboardShortcut(chord(.navigateForward))

            Divider()

            Button("Next Code") {
                postCommand(name: .macScopeNextCode, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .control])

            Button("Next Data") {
                postCommand(name: .macScopeNextData, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .control, .shift])

            Button("Next Unexplored") {
                postCommand(name: .macScopeNextUnexplored, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Divider()

            Button("Next Section") {
                postCommand(name: .macScopeNextSection, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])

            Button("Previous Section") {
                postCommand(name: .macScopePreviousSection, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])

            Button("Next XREF") {
                postCommand(name: .macScopeNextXRef, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control])

            Button("Previous XREF") {
                postCommand(name: .macScopePreviousXRef, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control])

            Divider()

            // Bookmarks are navigation targets, so they live with the other jump commands rather
            // than in a separate two-item top-level menu (menu-bar declutter).
            Button("Add Bookmark") {
                postCommand(name: .macScopeAddBookmark, object: nil)
            }
            .keyboardShortcut(chord(.addBookmark))

            Button("Remove Bookmark") {
                postCommand(name: .macScopeRemoveBookmark, object: nil)
            }
        }

        CommandMenu("Function") {
            Button("Request Native Pseudocode") {
                postCommand(name: .macScopeNativeRequest)
            }
            .disabled(!nativeCommandIsEnabled(.request))

            Button("Retry Native Pseudocode") {
                postCommand(name: .macScopeNativeRetry)
            }
            .disabled(!nativeCommandIsEnabled(.retry))

            Button("Refresh Native Pseudocode") {
                postCommand(name: .macScopeNativeRefresh)
            }
            .disabled(!nativeCommandIsEnabled(.refresh))

            Button("Cancel Native Pseudocode") {
                postCommand(name: .macScopeNativeCancel)
            }
            .disabled(!nativeCommandIsEnabled(.cancel))

            Divider()

            Button("Select Function") {
                postCommand(name: .macScopeSelectProcedure, object: nil)
            }
            // No ⇧⌘P here: that chord is the View ▸ Problems panel toggle (paired with ⇧⌘Y). A
            // duplicate binding makes macOS show the same shortcut on two menu items, only one of
            // which fires. This command stays menu-reachable in the already shortcut-dense Function
            // menu (its sibling "Mark as Function" keeps ⌃⌘P).

            Button("Truncate Function") {
                postCommand(name: .macScopeTruncateProcedure, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .control])

            Divider()

            Button("Next Function") {
                postCommand(name: .macScopeNextProcedure, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])

            Button("Previous Function") {
                postCommand(name: .macScopePreviousProcedure, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])

            Button("Go to Top of Function") {
                postCommand(name: .macScopeTopOfProcedure, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .control])

            Button("Mark as Undefined") {
                postCommand(name: .macScopeMarkAsUndefined, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .control])

            Button("Mark as Function") {
                postCommand(name: .macScopeMarkAsProcedure, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .control])

            Button("Set Local Label...") {
                postCommand(name: .macScopeSetLocalLabel, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .control])

            Divider()

            Button("Make Data...") {
                postCommand(name: .macScopeMakeData, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .control])

            Button("Rename Register...") {
                postCommand(name: .macScopeRenameRegister, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .control])

            Divider()

            Button("Transform Section to Strings...") {
                postCommand(name: .macScopeTransformSectionToStrings, object: nil)
            }
        }

        CommandMenu("Reconstruction") {
            Button("Create") {
                performReconstructionCommand(.create)
            }
            .disabled(!reconstructionCommandIsEnabled(.create))
            .help(reconstructionCommandHelp(.create))
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Start") {
                performReconstructionCommand(.start)
            }
            .disabled(!reconstructionCommandIsEnabled(.start))
            .help(reconstructionCommandHelp(.start))
            .keyboardShortcut(.return, modifiers: .command)

            Button("Pause") {
                performReconstructionCommand(.pause)
            }
            .disabled(!reconstructionCommandIsEnabled(.pause))
            .help(reconstructionCommandHelp(.pause))
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button("Resume") {
                performReconstructionCommand(.resume)
            }
            .disabled(!reconstructionCommandIsEnabled(.resume))
            .help(reconstructionCommandHelp(.resume))
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button("Cancel", role: .destructive) {
                performReconstructionCommand(.cancel)
            }
            .disabled(!reconstructionCommandIsEnabled(.cancel))
            .help(reconstructionCommandHelp(.cancel))
        }

        CommandMenu("Patch") {
            Button {
                postCommand(name: .macScopePatchBytes, object: nil)
            } label: {
                Label {
                    Text("Patch Bytes...")
                } icon: {
                    DS.symbolImage("lumen.patchedBytes")
                }
            }

            Button {
                postCommand(name: .macScopePatchNOP, object: nil)
            } label: {
                Label {
                    Text("Replace with NOP")
                } icon: {
                    DS.symbolImage("lumen.patchedBytes")
                }
            }

            Button {
                postCommand(name: .macScopeClearPatch, object: nil)
            } label: {
                Label {
                    Text("Clear Patch")
                } icon: {
                    DS.symbolImage("lumen.patchedBytes")
                }
            }

            Button {
                postCommand(name: .macScopeAssembleInstruction, object: nil)
            } label: {
                Label {
                    Text("Assemble Instruction...")
                } icon: {
                    DS.symbolImage("lumen.patchedBytes")
                }
            }

            Divider()

            Button {
                postCommand(name: .macScopeSavePatchedBinary, object: nil)
            } label: {
                Label {
                    Text("Save Patched Binary...")
                } icon: {
                    DS.symbolImage("lumen.patchedBytes")
                }
            }
        }

        CommandMenu("Debug") {
            Button("Logical Breakpoints...") {
                postCommand(name: .macScopeShowLogicalBreakpoints, object: nil)
            }
            .accessibilityLabel("Manage Logical Breakpoints")
            .accessibilityIdentifier("debug.menu.logicalBreakpoints")

            Divider()

            Button("Toggle Breakpoint") {
                postCommand(name: .macScopeToggleBreakpoint, object: nil)
            }
            .keyboardShortcut(chord(.toggleBreakpoint))

            Button("Run to Cursor") {
                postCommand(name: .macScopeRunToCursor, object: nil)
            }
        }

        CommandMenu("Assistant") {
            Button("Ask MacScope...") {
                postCommand(name: .macScopeShowAssistant, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }
    }
}

extension Notification.Name {
    static let macScopeNativeRequest = Notification.Name("MacScopeNativeRequest")
    static let macScopeNativeRetry = Notification.Name("MacScopeNativeRetry")
    static let macScopeNativeRefresh = Notification.Name("MacScopeNativeRefresh")
    static let macScopeNativeCancel = Notification.Name("MacScopeNativeCancel")
    static let macScopeOpenBinary = Notification.Name("MacScopeOpenBinary")
    static let macScopeLoadAdditionalBinary = Notification.Name("MacScopeLoadAdditionalBinary")
    /// Opens a saved `.mscope` project package and restores it into the workspace.
    static let macScopeOpenProject = Notification.Name("MacScopeOpenProject")
    /// Opens a specific recent `.mscope` document; the posted object is its URL.
    static let macScopeOpenRecentDocument = Notification.Name("MacScopeOpenRecentDocument")
    /// Presents an open panel for a `.dSYM` bundle and imports its function-name debug symbols
    /// into the workspace (applied as name overrides after a UUID match against the loaded binary).
    static let macScopeReadDebugSymbols = Notification.Name("MacScopeReadDebugSymbols")
    /// Presents the Phase 2 R1 local assistant sheet for the focused document window.
    static let macScopeShowAssistant = Notification.Name("MacScopeShowAssistant")
    static let macScopeSave = Notification.Name("MacScopeSave")
    static let macScopeSaveAs = Notification.Name("MacScopeSaveAs")
    static let macScopeSaveCopy = Notification.Name("MacScopeSaveCopy")
    static let macScopeReloadFromDisk = Notification.Name("MacScopeReloadFromDisk")
    static let macScopeKeepLocalVersion = Notification.Name("MacScopeKeepLocalVersion")
    /// Internal automation route for opening a `.mscope` package. The posted object is its URL.
    static let macScopeOpenWorkspaceAutomation = Notification.Name(
        "MacScopeOpenWorkspaceAutomation"
    )
    /// Exports the disassembly listing to a chosen `.txt`/`.asm` file.
    static let macScopeExportListing = Notification.Name("MacScopeExportListing")
    /// Exports the pseudocode (current function scope) to a chosen `.txt` file.
    static let macScopeExportPseudocode = Notification.Name("MacScopeExportPseudocode")
    /// Exports the pseudocode for EVERY discovered function (whole-binary scope).
    static let macScopeExportAllPseudocode = Notification.Name("MacScopeExportAllPseudocode")
    /// Exports the recovered Objective-C class interfaces to a chosen `.h` file (class dump).
    static let macScopeExportObjectiveCHeader = Notification.Name("MacScopeExportObjectiveCHeader")
    /// Exports the recovered Swift nominal types to a chosen `.swift` file (interface dump).
    static let macScopeExportSwiftInterface = Notification.Name("MacScopeExportSwiftInterface")
    /// Exports the control-flow graph view to a chosen `.pdf` file (vector graph capture).
    static let macScopeExportGraphPDF = Notification.Name("MacScopeExportGraphPDF")

    /// Exports the workspace type catalog (struct/union/enum/typedef) as re-importable C
    /// declarations to a chosen `.h` file (symmetric to the C-type-header import).
    static let macScopeExportTypeCatalog = Notification.Name("MacScopeExportTypeCatalog")
    /// Exports the analysis to a chosen `.BinExport2` file (Google/zynamics BinExport2 protobuf,
    /// readable by BinDiff and compatible diffing tooling).
    static let macScopeExportBinExport2 = Notification.Name("MacScopeExportBinExport2")
    static let macScopeShowGoTo = Notification.Name("MacScopeShowGoTo")
    static let macScopeFind = Notification.Name("MacScopeFind")
    /// Steps to the next Find match (Cmd-G), wrapping at the end.
    static let macScopeFindNext = Notification.Name("MacScopeFindNext")
    /// Steps to the previous Find match (Shift-Cmd-G), wrapping at the start.
    static let macScopeFindPrevious = Notification.Name("MacScopeFindPrevious")
    static let macScopeNavigateBack = Notification.Name("MacScopeNavigateBack")
    static let macScopeNavigateForward = Notification.Name("MacScopeNavigateForward")
    /// Jumps to the next decoded code address below the selection.
    static let macScopeNextCode = Notification.Name("MacScopeNextCode")
    /// Jumps to the next data-marked / string-literal address below the selection.
    static let macScopeNextData = Notification.Name("MacScopeNextData")
    /// Jumps to the next unexplored (undefined) region below the selection.
    static let macScopeNextUnexplored = Notification.Name("MacScopeNextUnexplored")
    /// Jumps to the start of the next / previous procedure.
    static let macScopeNextProcedure = Notification.Name("MacScopeNextProcedure")
    static let macScopePreviousProcedure = Notification.Name("MacScopePreviousProcedure")
    /// Jumps to the start of the procedure enclosing the selection.
    static let macScopeTopOfProcedure = Notification.Name("MacScopeTopOfProcedure")
    /// Jumps to the start of the next / previous section.
    static let macScopeNextSection = Notification.Name("MacScopeNextSection")
    static let macScopePreviousSection = Notification.Name("MacScopePreviousSection")
    /// Steps to the next / previous cross-reference targeting the selection.
    static let macScopeNextXRef = Notification.Name("MacScopeNextXREF")
    static let macScopePreviousXRef = Notification.Name("MacScopePreviousXREF")
    /// Copies the current address / the selected instruction's bytes to the clipboard.
    static let macScopeCopyAddress = Notification.Name("MacScopeCopyAddress")
    static let macScopeCopyHexString = Notification.Name("MacScopeCopyHexString")
    /// Selects the whole range of the function enclosing the selection.
    static let macScopeSelectProcedure = Notification.Name("MacScopeSelectProcedure")
    /// Truncates the enclosing function so it ends at the selected address.
    static let macScopeTruncateProcedure = Notification.Name("MacScopeTruncateProcedure")
    /// Marks the selected span as undefined (inverse of Mark as Procedure).
    static let macScopeMarkAsUndefined = Notification.Name("MacScopeMarkAsUndefined")
    /// Forces a function start at the selected address (inverse of Mark as Undefined);
    /// toggles off a prior force. Routed through the typed `WorkspaceCommand` router.
    static let macScopeMarkAsProcedure = Notification.Name("MacScopeMarkAsProcedure")
    /// Presents the Make Data sheet (array / string / alignment) for the selected address.
    static let macScopeMakeData = Notification.Name("MacScopeMakeData")
    /// Presents the Import C Header sheet (paste C declarations into the type catalog).
    static let macScopeImportCHeader = Notification.Name("MacScopeImportCHeader")
    /// Presents the Rename Register sheet for a register in the current procedure's pseudocode.
    static let macScopeRenameRegister = Notification.Name("MacScopeRenameRegister")
    /// Presents the Set Local Label sheet for the selected address (procedure-scoped name).
    static let macScopeSetLocalLabel = Notification.Name("MacScopeSetLocalLabel")
    /// Adds a named bookmark at the selected address.
    static let macScopeAddBookmark = Notification.Name("MacScopeAddBookmark")
    /// Removes the bookmark at the selected address.
    static let macScopeRemoveBookmark = Notification.Name("MacScopeRemoveBookmark")
    /// Patches the bytes at the selected address from user-entered hex.
    static let macScopePatchBytes = Notification.Name("MacScopePatchBytes")
    /// Replaces the selected instruction with a NOP patch.
    static let macScopePatchNOP = Notification.Name("MacScopePatchNOP")
    /// Clears any byte patch at the selected address.
    static let macScopeClearPatch = Notification.Name("MacScopeClearPatch")
    /// Writes a patched copy of the original binary to disk: the on-disk Mach-O with every
    /// applied byte patch mapped back to its file offset (thin Mach-O only; the output is
    /// unsigned and must be re-signed with `codesign` to run).
    static let macScopeSavePatchedBinary = Notification.Name("MacScopeSavePatchedBinary")
    /// Assembles one ARM64 instruction over the selected instruction (sheet).
    static let macScopeAssembleInstruction = Notification.Name("MacScopeAssembleInstruction")
    /// Scans a chosen section for C strings and marks each as a string.
    static let macScopeTransformSectionToStrings = Notification.Name("MacScopeTransformSectionToStrings")
    static let macScopeShowCommandPalette = Notification.Name("MacScopeShowCommandPalette")
    static let macScopeToggleBreakpoint = Notification.Name("MacScopeToggleBreakpoint")
    /// Routes the focused workspace to the durable Logical Breakpoints manager, including while
    /// the debugger is idle, exited, or unavailable.
    static let macScopeShowLogicalBreakpoints = Notification.Name("MacScopeShowLogicalBreakpoints")
    /// Runs the stopped debug target to the selected listing address via a temporary
    /// one-shot breakpoint (Debug ▸ Run to Cursor). A no-op when no live session is paused.
    static let macScopeRunToCursor = Notification.Name("MacScopeRunToCursor")
    static let macScopeSetEditorMode = Notification.Name("MacScopeSetEditorMode")
    /// Presents the Imports/Exports/Sections browser sheet. The posted `object`, when
    /// a `BrowserPane`, selects which pane opens.
    static let macScopeShowBrowsers = Notification.Name("MacScopeShowBrowsers")
    /// Toggles the browsable Navigation History panel (View ▸ Navigation History).
    static let macScopeToggleNavigationHistory = Notification.Name("MacScopeToggleNavigationHistory")
    /// Toggles the analysis Problems panel (View ▸ Problems).
    static let macScopeToggleProblems = Notification.Name("MacScopeToggleProblems")
    /// Toggles the Mach-O Signature & Dependencies panel (View ▸ Signature & Dependencies).
    static let macScopeToggleMachOMetadata = Notification.Name("MacScopeToggleMachOMetadata")
    /// Presents Compare Images: function-level version matching between two images already
    /// loaded in the focused workspace (View ▸ Compare Images…). Requires two analyzed images.
    static let macScopeShowVersionCompare = Notification.Name("MacScopeShowVersionCompare")
    /// Resets the control-flow graph to its default layout (clears any node multi-selection).
    static let macScopeResetGraphLayout = Notification.Name("MacScopeResetGraphLayout")
}

extension EditorMode {
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .disassembly: "1"
        case .pseudocode: "2"
        case .graph: "3"
        case .hex: "4"
        }
    }

    var keyboardShortcutDescription: String {
        switch self {
        case .disassembly: "Command-1"
        case .pseudocode: "Command-2"
        case .graph: "Command-3"
        case .hex: "Command-4"
        }
    }
}

enum WorkspaceDocumentCommandIntent: String, CaseIterable {
    case save
    case saveAs
    case autosave
}

struct WorkspaceDocumentCommandAvailability: Equatable {
    var intent: WorkspaceDocumentCommandIntent
    var title: String
    var systemImage: String
    var keyboardShortcutDescription: String?
    var isEnabled: Bool
    var disabledReason: String?
}

enum WorkspaceDocumentConflictActionIntent: String, CaseIterable {
    case saveAsCopy
    case reloadFromDisk
    case keepLocalVersion
}

struct WorkspaceDocumentConflictAction: Identifiable, Equatable {
    var intent: WorkspaceDocumentConflictActionIntent
    var title: String
    var systemImage: String
    var detail: String
    var isDestructive: Bool
    var isEnabled: Bool = true

    var id: String {
        intent.rawValue
    }
}

struct WorkspaceDocumentCommandPolicy: Equatable {
    var displayName: String
    var statusTitle: String
    var primarySave: WorkspaceDocumentCommandAvailability
    var saveAs: WorkspaceDocumentCommandAvailability
    var autosave: WorkspaceDocumentCommandAvailability
    var conflictActions: [WorkspaceDocumentConflictAction]

    var hasConflict: Bool {
        !conflictActions.isEmpty
    }

    static func resolve(
        snapshot: WorkspaceDocumentSessionSnapshot
    ) -> WorkspaceDocumentCommandPolicy {
        let displayName = snapshot.location?.canonicalURL
            .deletingPathExtension()
            .lastPathComponent ?? "Untitled Workspace"
        let hasLocation = snapshot.location != nil
        let isSaving = snapshot.activeSave != nil
        let conflict = snapshot.conflict
        let primaryIntent: WorkspaceDocumentCommandIntent = hasLocation ? .save : .saveAs
        let primaryTitle = hasLocation ? "Save" : "Save..."
        let primaryEnabled = !isSaving && conflict == nil
        let saveAsEnabled = !isSaving
        let autosaveEnabled = hasLocation
            && snapshot.hasUnsavedChanges
            && !isSaving
            && conflict == nil

        let statusTitle: String
        switch snapshot.lifecyclePresentationState {
        case .untitled:
            statusTitle = "Untitled"
        case .clean:
            statusTitle = "Saved"
        case .dirty:
            statusTitle = "Unsaved Changes"
        case .saving:
            statusTitle = "Saving"
        case .conflicted(let reason):
            statusTitle = conflictStatusTitle(for: reason)
        case .failed:
            statusTitle = "Save Failed"
        }

        return WorkspaceDocumentCommandPolicy(
            displayName: displayName,
            statusTitle: statusTitle,
            primarySave: WorkspaceDocumentCommandAvailability(
                intent: primaryIntent,
                title: primaryTitle,
                systemImage: "square.and.arrow.down",
                keyboardShortcutDescription: "Command-S",
                isEnabled: primaryEnabled,
                disabledReason: primaryEnabled
                    ? nil
                    : (isSaving
                        ? "A document write is already in progress."
                        : "Resolve the package conflict or use Save As before overwriting.")
            ),
            saveAs: WorkspaceDocumentCommandAvailability(
                intent: .saveAs,
                title: "Save As...",
                systemImage: "doc.badge.plus",
                keyboardShortcutDescription: "Shift-Command-S",
                isEnabled: saveAsEnabled,
                disabledReason: saveAsEnabled
                    ? nil
                    : "A document write is already in progress."
            ),
            autosave: WorkspaceDocumentCommandAvailability(
                intent: .autosave,
                title: "Autosave",
                systemImage: "arrow.triangle.2.circlepath",
                keyboardShortcutDescription: nil,
                isEnabled: autosaveEnabled,
                disabledReason: autosaveDisabledReason(
                    snapshot: snapshot,
                    hasLocation: hasLocation,
                    isSaving: isSaving
                )
            ),
            conflictActions: conflict.map {
                conflictActionModels(
                    keepLocalEnabled: $0.reason.isKeepLocalVersionAllowed
                )
            } ?? []
        )
    }

    @available(*, deprecated, message: "Headless compatibility; product commands use session snapshots")
    static func resolve(
        metadata: WorkspaceDatabase.WorkspaceDocumentMetadata?
    ) -> WorkspaceDocumentCommandPolicy {
        guard let metadata else {
            return WorkspaceDocumentCommandPolicy(
                displayName: "Untitled Workspace",
                statusTitle: "Not saved as a MacScope package",
                primarySave: WorkspaceDocumentCommandAvailability(
                    intent: .saveAs,
                    title: "Save...",
                    systemImage: "square.and.arrow.down",
                    keyboardShortcutDescription: "Command-S",
                    isEnabled: true,
                    disabledReason: nil
                ),
                saveAs: saveAsAvailability(),
                autosave: WorkspaceDocumentCommandAvailability(
                    intent: .autosave,
                    title: "Autosave",
                    systemImage: "arrow.triangle.2.circlepath",
                    keyboardShortcutDescription: nil,
                    isEnabled: false,
                    disabledReason: "Save this workspace as a MacScope package before autosave is available."
                ),
                conflictActions: []
            )
        }

        switch metadata.lifecycleState {
        case .clean:
            return WorkspaceDocumentCommandPolicy(
                displayName: metadata.packageDisplayName,
                statusTitle: "Saved",
                primarySave: WorkspaceDocumentCommandAvailability(
                    intent: .save,
                    title: "Save",
                    systemImage: "square.and.arrow.down",
                    keyboardShortcutDescription: "Command-S",
                    isEnabled: true,
                    disabledReason: nil
                ),
                saveAs: saveAsAvailability(),
                autosave: WorkspaceDocumentCommandAvailability(
                    intent: .autosave,
                    title: "Autosave",
                    systemImage: "arrow.triangle.2.circlepath",
                    keyboardShortcutDescription: nil,
                    isEnabled: false,
                    disabledReason: "No unsaved document changes are pending."
                ),
                conflictActions: []
            )
        case .dirty:
            return WorkspaceDocumentCommandPolicy(
                displayName: metadata.packageDisplayName,
                statusTitle: "Unsaved Changes",
                primarySave: WorkspaceDocumentCommandAvailability(
                    intent: .save,
                    title: "Save",
                    systemImage: "square.and.arrow.down",
                    keyboardShortcutDescription: "Command-S",
                    isEnabled: true,
                    disabledReason: nil
                ),
                saveAs: saveAsAvailability(),
                autosave: WorkspaceDocumentCommandAvailability(
                    intent: .autosave,
                    title: "Autosave",
                    systemImage: "arrow.triangle.2.circlepath",
                    keyboardShortcutDescription: nil,
                    isEnabled: metadata.allowsAutosave,
                    disabledReason: metadata.allowsAutosave ? nil : "Autosave is unavailable for this document state."
                ),
                conflictActions: []
            )
        case .conflicted(let reason):
            return WorkspaceDocumentCommandPolicy(
                displayName: metadata.packageDisplayName,
                statusTitle: reason ?? "Package changed on disk",
                primarySave: WorkspaceDocumentCommandAvailability(
                    intent: .save,
                    title: "Save",
                    systemImage: "square.and.arrow.down",
                    keyboardShortcutDescription: "Command-S",
                    isEnabled: false,
                    disabledReason: "Resolve the package conflict or use Save As before overwriting."
                ),
                saveAs: saveAsAvailability(),
                autosave: WorkspaceDocumentCommandAvailability(
                    intent: .autosave,
                    title: "Autosave",
                    systemImage: "arrow.triangle.2.circlepath",
                    keyboardShortcutDescription: nil,
                    isEnabled: false,
                    disabledReason: "Autosave is paused until the package conflict is resolved."
                ),
                conflictActions: conflictActionModels()
            )
        }
    }

    private static func saveAsAvailability() -> WorkspaceDocumentCommandAvailability {
        WorkspaceDocumentCommandAvailability(
            intent: .saveAs,
            title: "Save As...",
            systemImage: "doc.badge.plus",
            keyboardShortcutDescription: "Shift-Command-S",
            isEnabled: true,
            disabledReason: nil
        )
    }

    private static func conflictStatusTitle(
        for reason: WorkspaceDocumentConflictReason
    ) -> String {
        switch reason {
        case .externallyChanged, .destinationOwnedByAnotherWindow:
            return "Package Changed on Disk"
        case .destinationMissing:
            return "Package Missing"
        case .destinationInvalid:
            return "Package Invalid"
        case .destinationUnverifiable:
            return "Package State Could Not Be Verified"
        }
    }

    private static func autosaveDisabledReason(
        snapshot: WorkspaceDocumentSessionSnapshot,
        hasLocation: Bool,
        isSaving: Bool
    ) -> String? {
        if !hasLocation {
            return "Save this workspace as a MacScope package before autosave is available."
        }
        if snapshot.conflict != nil {
            return "Autosave is paused until the package conflict is resolved."
        }
        if isSaving {
            return "A document write is already in progress."
        }
        if !snapshot.hasUnsavedChanges {
            return "No unsaved document changes are pending."
        }
        return nil
    }

    private static func conflictActionModels(
        keepLocalEnabled: Bool = true
    ) -> [WorkspaceDocumentConflictAction] {
        [
            WorkspaceDocumentConflictAction(
                intent: .saveAsCopy,
                title: "Save As Copy...",
                systemImage: "doc.on.doc",
                detail: "Preserve the local workspace in a new package without overwriting the changed package.",
                isDestructive: false
            ),
            WorkspaceDocumentConflictAction(
                intent: .reloadFromDisk,
                title: "Reload From Disk",
                systemImage: "arrow.clockwise",
                detail: "Discard local unsaved changes and reopen the package from disk.",
                isDestructive: true
            ),
            WorkspaceDocumentConflictAction(
                intent: .keepLocalVersion,
                title: "Keep Local Version",
                systemImage: "checkmark.circle",
                detail: "Treat the current workspace as authoritative before saving over the package.",
                isDestructive: false,
                isEnabled: keepLocalEnabled
            )
        ]
    }
}

private extension WorkspaceDocumentConflictReason {
    var isKeepLocalVersionAllowed: Bool {
        if case .destinationUnverifiable = self { return false }
        return true
    }
}

struct RecentWorkspaceDocumentCommand: Identifiable, Equatable {
    var workspaceID: Int64
    var documentID: UUID
    var title: String
    var subtitle: String
    var packagePath: String
    var statusTitle: String?
    var systemImage: String
    var allowsAutosave: Bool

    var id: String {
        "recent-workspace:\(workspaceID)"
    }

    static func commands(
        from metadata: [WorkspaceDatabase.WorkspaceDocumentMetadata]
    ) -> [RecentWorkspaceDocumentCommand] {
        metadata.map { item in
            RecentWorkspaceDocumentCommand(
                workspaceID: item.workspaceID,
                documentID: item.documentID,
                title: item.packageDisplayName,
                subtitle: subtitle(for: item),
                packagePath: item.packageURL.path,
                statusTitle: statusTitle(for: item.lifecycleState),
                systemImage: systemImage(for: item.lifecycleState),
                allowsAutosave: item.allowsAutosave
            )
        }
    }

    private static func subtitle(
        for metadata: WorkspaceDatabase.WorkspaceDocumentMetadata
    ) -> String {
        if metadata.workspaceName != metadata.packageDisplayName {
            return metadata.workspaceName
        }

        let folderPath = metadata.packageURL.deletingLastPathComponent().path
        return folderPath.isEmpty ? metadata.packageURL.path : folderPath
    }

    private static func statusTitle(
        for lifecycleState: WorkspaceDatabase.WorkspaceDocumentLifecycleState
    ) -> String? {
        switch lifecycleState {
        case .clean:
            nil
        case .dirty:
            "Unsaved Changes"
        case .conflicted:
            "Conflict"
        }
    }

    private static func systemImage(
        for lifecycleState: WorkspaceDatabase.WorkspaceDocumentLifecycleState
    ) -> String {
        switch lifecycleState {
        case .clean:
            "doc"
        case .dirty:
            "pencil"
        case .conflicted:
            "exclamationmark.triangle"
        }
    }
}

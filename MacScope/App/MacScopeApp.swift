import AppKit
import CoreGraphics
import SwiftUI
import LumenUI

/// Immutable process inputs captured before any app scene or renderer view can be constructed.
/// `MacScopeGhosttySurfaceFeature.production` remains the policy authority; retaining its value
/// here forces that static snapshot to materialize at process entry instead of at a later view
/// reconstruction.
struct MacScopeAppProcessStartSnapshot: Equatable, Sendable {
    static let production: Self = {
        let processInfo = ProcessInfo.processInfo
        return Self(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            ghosttySurfaceFeature: MacScopeGhosttySurfaceFeature.production
        )
    }()

    let arguments: [String]
    let environment: [String: String]
    let ghosttySurfaceFeature: MacScopeGhosttySurfaceFeature
    let installedRendererSmokeRequested: Bool

    init(
        arguments: [String],
        environment: [String: String],
        ghosttySurfaceFeature: MacScopeGhosttySurfaceFeature
    ) {
        self.arguments = arguments
        self.environment = environment
        self.ghosttySurfaceFeature = ghosttySurfaceFeature
        installedRendererSmokeRequested =
            Phase2InstalledRendererEvidenceAdapter.isSmokeRequested(environment: environment)
    }
}

/// The process entry point. Routes to a headless automation mode when launched with
/// `--mcp <binary>` (serve JSON-RPC over stdio, then exit), `--run-script <script>
/// <binary>` (run a batch script, print JSON, then exit) or `--export-native-pseudocode
/// <binary> <output>` (native Export All, print JSON, then exit); otherwise starts the normal
/// SwiftUI app. These checks happen before any scene so a client gets a clean stdio
/// channel.
@main
struct AppEntry {
    static func main() {
        let processStartSnapshot = MacScopeAppProcessStartSnapshot.production
        let arguments = processStartSnapshot.arguments
        let environment = processStartSnapshot.environment
        MainActor.assumeIsolated {
            MacScopeHeadlessHostPolicy.installIfRequested(arguments: arguments, environment: environment)
        }
        if MainActor.assumeIsolated({
            ReconstructionResumeHost.runIfRequested(arguments: arguments, environment: environment)
        }) { return }
        if MainActor.assumeIsolated({
            HeadlessWorkspaceAcceptance.runIfRequested(arguments: arguments)
        }) {
            return
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            MacScopeUnitTestHostApp.main()
            return
        }
        if MainActor.assumeIsolated({
            WS24InstalledLiveGateApplicationRunner.runIfRequested(
                arguments: arguments,
                environment: environment
            )
        }) {
            return
        }
        if MainActor.assumeIsolated({
            Phase2QualificationGateApplicationRunner.runIfRequested(arguments: arguments)
        }) {
            return
        }
        let installedRendererSmokeRequested =
            processStartSnapshot.installedRendererSmokeRequested
        if installedRendererSmokeRequested {
            Phase2ShellBrokerLaunchAgentRegistration.prepareForApplicationLaunch()
        }
        if installedRendererSmokeRequested {
            let rendererAdapter = MainActor.assumeIsolated {
                Phase2InstalledRendererEvidenceAdapter.productionShared
            }
            if Phase2InstalledShellSmokeRunner.startIfRequested(
                environment: environment,
                rendererPresentationProvider: { request, snapshot in
                    try await rendererAdapter.present(request: request, snapshot: snapshot)
                },
                rendererEvidenceProvider: { request, presentation in
                    try await rendererAdapter.rendererEvidence(
                        request: request,
                        presentation: presentation
                    )
                }
            ) {
                MacScopeApp.main()
                return
            }
        }
        if let window = MCPAttachRelay.requestedWindow(from: arguments) {
            MCPAttachRelay.run(window: window) // relays to the running app, then exits
        }
        if let binaryURL = MCPLauncher.requestedBinary(from: arguments) {
            MainActor.assumeIsolated { MCPLauncher.run(binaryURL: binaryURL) } // serves, then exits
        }
        if let request = CLIRunner.request(from: arguments) {
            MainActor.assumeIsolated { CLIRunner.run(scriptURL: request.script, binaryURL: request.binary) } // runs, then exits
        }
        if let request = NativeExportCLI.request(from: arguments) {
            MainActor.assumeIsolated { NativeExportCLI.run(request) } // exports, then exits
        }
        Phase2ShellBrokerLaunchAgentRegistration.prepareForApplicationLaunch()
        MacScopeApp.main()
    }
}

/// Keeps hosted unit tests independent of production window construction. XCTest injects the
/// CoreTests bundle into this process and owns its lifetime; opening the full workspace scene
/// first adds needless startup work and can race AppKit's initial constraint pass.
private struct MacScopeUnitTestHostApp: App {
    @NSApplicationDelegateAdaptor(MacScopeHeadlessHostDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

struct MacScopeApp: App {
    @NSApplicationDelegateAdaptor(MacScopeApplicationDelegate.self)
    private var applicationDelegate
    private let launchConfiguration: WorkspaceLaunchConfiguration
    /// The exact process-start inputs and Ghostty recovery policy shared by every scene rebuild.
    private let processStartSnapshot: MacScopeAppProcessStartSnapshot
    /// Eagerly retained at app composition so ordinary renderer views can only observe the one
    /// process runtime bound to `processStartSnapshot.ghosttySurfaceFeature`.
    private let ghosttyRuntime: MacScopeGhosttyRuntime
    /// One app-lifetime composition is copied into every window root without recreating any of its
    /// process-global authorities.
    private let runtimeServices: MacScopeAppRuntimeServices
    /// One process-wide document composition owns the paired registry, duplicate-open
    /// coordinator, exact window activator, and per-session I/O factories.
    private let documentRuntime: WorkspaceDocumentRuntime
    /// One store PER DOCUMENT WINDOW (WS-2), owned by the registry — not a single shared
    /// App-level store. The cold-launch window resolves `.primary`, which bootstraps from the
    /// launch configuration exactly as the old single store did.
    @StateObject private var registry: WorkspaceSessionRegistry
    private let applicationOpenRouter: WorkspaceApplicationOpenRouter
    /// One provider-global controller for the whole app process. Its retained lifecycle service
    /// owns the current-runtime unload ledger, so it must not be recreated per window or Settings
    /// presentation.
    @StateObject private var localAIProviderController: Phase2LocalAIProviderController
    /// One process-global admission authority for ready inference. Document windows receive it
    /// through the narrow assistant seam so app ownership prevents parallel ready-inference lanes.
    @StateObject private var readyInferenceCoordinator: Phase2ReadyInferenceCoordinator
    /// User appearance preference. Defaults to `.auto` (follow system); applied as
    /// a `preferredColorScheme` on the root view ONLY when the user opts into a
    /// fixed scheme, so the system setting is honoured by default.
    @AppStorage(AppAppearancePreference.storageKey) private var appearanceRaw = AppAppearancePreference.auto.rawValue

    init() {
        DSThemeStore.installLumen()
        let processStartSnapshot = MacScopeAppProcessStartSnapshot.production
        self.processStartSnapshot = processStartSnapshot
        let ghosttyRuntime = MacScopeGhosttyRuntime.productionShared
        precondition(
            ghosttyRuntime.feature == processStartSnapshot.ghosttySurfaceFeature,
            "process Ghostty runtime must consume the app-entry recovery-policy snapshot"
        )
        self.ghosttyRuntime = ghosttyRuntime
        let runtimeServices = MacScopeAppRuntimeServices.productionShared
        self.runtimeServices = runtimeServices
        let providerPreferenceStore = UserDefaultsPhase2LocalAIProviderPreferenceStore()
        providerPreferenceStore.migrateOutputBudgetOnce()
        let providerController = Phase2LocalAIProviderController(
            preferenceStore: providerPreferenceStore,
            defaultPreference: try? .mtplxQualityDefault()
        )
        let readyInferenceCoordinator = Phase2ReadyInferenceCoordinator(
            controller: providerController
        )
        let documentRuntime = WorkspaceDocumentRuntime(
            nativeDecompilerSessions: runtimeServices.nativeDecompilerRuntime
        )
        documentRuntime.registry.installReconstructionRuntimeFactoryIfNeeded {
            await runtimeServices.reconstructionWorkspaceRuntimeFactory(
                inferenceCoordinator: readyInferenceCoordinator
            )
        }
        self.documentRuntime = documentRuntime
        let applicationOpenRouter = WorkspaceApplicationOpenRouter(
            registry: documentRuntime.registry,
            coordinator: documentRuntime.openCoordinator,
            windowIdentity: { [weak activator = documentRuntime.windowActivator] id in
                activator?.window(for: id).map(ObjectIdentifier.init)
            }
        )
        self.applicationOpenRouter = applicationOpenRouter
        WorkspaceApplicationOpenRouter.installed = applicationOpenRouter
        _registry = StateObject(wrappedValue: documentRuntime.registry)
        self.launchConfiguration = WorkspaceLaunchConfiguration.parse(
            arguments: processStartSnapshot.arguments,
            environment: processStartSnapshot.environment
        )
        _localAIProviderController = StateObject(wrappedValue: providerController)
        _readyInferenceCoordinator = StateObject(wrappedValue: readyInferenceCoordinator)
        applicationDelegate.installOpenDocuments { [weak applicationOpenRouter] urls in
            applicationOpenRouter?.openExternalDocuments(urls)
        }
        applicationDelegate.install {
            guard await documentRuntime.registry.shutdown() else {
                return false
            }
            await runtimeServices.shutdown()
            return true
        }
    }

    var body: some Scene {
        // Value-keyed so each window has its own identity → its own store. Cold launch
        // presents one window with the default `.primary` identity.
        WindowGroup("MacScope", for: WorkspaceWindowID.self) { $windowID in
            let resolvedID = windowID
            let store = registry.store(
                for: resolvedID,
                launchConfiguration: launchConfiguration
            )
            let documentSession = registry.documentSession(
                for: resolvedID,
                launchConfiguration: launchConfiguration
            )
            let nativeDecompilerPresentation = registry.nativeDecompilerPresentation(
                for: resolvedID
            )
            ReconstructionWorkspaceRootHost(
                registry: registry,
                launchConfiguration: launchConfiguration,
                store: store,
                documentSession: documentSession,
                openCoordinator: documentRuntime.openCoordinator,
                windowActivator: documentRuntime.windowActivator,
                windowID: resolvedID,
                nativeDecompilerPresentation: nativeDecompilerPresentation,
                applicationOpenRouter: applicationOpenRouter,
                assistantInferenceCoordinator: readyInferenceCoordinator,
                assistantProviderSnapshot: localAIProviderController.snapshot
            )
                .overlay {
                    if processStartSnapshot.installedRendererSmokeRequested,
                       resolvedID == .primary {
                        Phase2InstalledRendererPresentationHost(
                            store: store,
                            adapter: .productionShared
                        )
                    }
                }
                // The unified host reserves two compact bands; keep the native minimum at 1080×680.
                .frame(minWidth: 1080, minHeight: 680 - 2 * LumenLayout.unifiedTopBarHeight)
                .tint(Color.lumen(.accent))
                .preferredColorScheme(resolvedColorScheme)
                .dsPaletteRoot()
                .dsDensityRoot()
                .environmentObject(registry)
                .environmentObject(localAIProviderController)
                .environment(
                    \.debuggerRuntimeAuthorities,
                    runtimeServices.debuggerRuntimeAuthorities
                )
        } defaultValue: {
            .primary
        }
        // The workspace owns one compact custom command bar. Keep the system traffic lights and
        // window lifecycle while removing the duplicate conventional titlebar band; the root
        // continues to provide the document's logical navigation title for menus and accessibility.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 780)
        .defaultWindowPlacement { _, _ in
            // WS-2: the FIRST window takes the explicit launch frame (argv/env or the centered
            // default); each additional document window cascades off it so they don't all stack
            // on the same rectangle.
            let frame = launchConfiguration.windowFrame ?? MacScopeWindowPlacement.defaultFrame()
            let cascade = CGFloat(registry.nextWindowPlacementIndex()) * 28
            return WindowPlacement(
                x: frame.x + cascade,
                y: frame.y + cascade,
                width: frame.width,
                height: frame.height
            )
        }
        .commands {
            MacScopeCommands(applicationOpenRouter: applicationOpenRouter)
            DSWorkspaceViewCommands()
            NativeToolbarPrototypeCommands()
        }

        Settings {
            SettingsView(providerController: localAIProviderController)
                // The Settings scene is a sibling of the WindowGroup, so it does NOT
                // inherit the root .tint — tint it here so every native control
                // (toggles, pickers, steppers, buttons) uses the brand violet, not system blue.
                .tint(Color.lumen(.accent))
                .preferredColorScheme(resolvedColorScheme)
                .dsPaletteRoot()
                .dsDensityRoot()
        }

        // Developer-only comparison window for the native toolbar prototype. Never opens at
        // launch or on restoration; reachable from the Window menu when its default is set.
        Window("Native Toolbar Prototype", id: NativeToolbarPrototypeView.windowID) {
            NativeToolbarPrototypeView()
                .tint(Color.lumen(.accent))
                .preferredColorScheme(resolvedColorScheme)
                .dsPaletteRoot()
                .dsDensityRoot()
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }

    /// A single-appearance theme (Midnight is always dark) wins over the Light/Dark preference;
    /// otherwise the preference applies. Reading the theme here subscribes the scenes to it.
    private var resolvedColorScheme: ColorScheme? {
        DSThemeStore.shared.theme.forcedColorScheme
            ?? AppAppearancePreference.resolve(appearanceRaw).colorScheme
    }
}

@MainActor
private struct Phase2InstalledRendererPresentationHost: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var adapter: Phase2InstalledRendererEvidenceAdapter

    private enum Lifecycle {
        case presented
        case retiring
    }

    private struct Ownership {
        let request: Phase2InstalledRendererEvidenceAdapter.PresentationRequest
        let displacedProjection: Phase2WorkspaceShellSessionProjection
        var lifecycle: Lifecycle
        var didMount: Bool
    }

    @State private var ownership: Ownership?

    var body: some View {
        Group {
            if let ownership, ownership.lifecycle == .presented {
                presentationView(for: ownership.request)
                    .id(ownership.request.requestGeneration)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: adapter.presentationRequest, initial: true) { _, request in
            synchronizePresentation(with: request)
        }
        .onDisappear {
            retireOwnedPresentation()
        }
    }

    private func presentationView(
        for request: Phase2InstalledRendererEvidenceAdapter.PresentationRequest
    ) -> AnyView {
        let requestedMode: Phase2InstalledShellRendererPresentation.RequestedMode
        switch request.requestedMode {
        case .defaultFullGhosttySurface:
            requestedMode = .defaultFullGhosttySurface
        case .forcedLegacyGridRecoveryOverride:
            requestedMode = .forcedLegacyGridRecoveryOverride
        }
        let coordinate = Phase2InstalledShellRendererPresentation.ProcessCoordinate(
            sessionID: request.shellSessionID,
            requestID: request.shellRequestID,
            processIdentifier: request.shellProcessIdentifier
        )
        let stateChanged: Phase2InstalledShellRendererPresentation.StateHandler = { state in
            handle(state, requestGeneration: request.requestGeneration)
        }
        switch request.requestedMode {
        case .defaultFullGhosttySurface:
            return Phase2InstalledShellRendererPresentation.makeView(
                store: store,
                snapshot: request.snapshot,
                requestedMode: requestedMode,
                processCoordinate: coordinate,
                stateChanged: stateChanged
            )
        case .forcedLegacyGridRecoveryOverride:
            return AnyView(Phase2InstalledForcedLegacyRendererPresentationView(
                store: store,
                snapshot: request.snapshot,
                processCoordinate: coordinate,
                stateChanged: stateChanged
            ))
        }
    }

    private func synchronizePresentation(
        with request: Phase2InstalledRendererEvidenceAdapter.PresentationRequest?
    ) {
        guard let request else {
            retireOwnedPresentation()
            return
        }
        guard ownership == nil,
              store.phase2ShellSession.snapshot == nil,
              !store.phase2ShellSession.isCommandInFlight else {
            adapter.presentationFailed(requestGeneration: request.requestGeneration)
            return
        }

        let displaced = store.phase2ShellSession
        let adopted = Phase2WorkspaceShellSessionProjection(
            snapshot: request.snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: request.snapshot.transcriptEvents,
            lastBytesWritten: nil
        )
        store.installPhase2ShellSessionProjection(adopted)
        guard store.phase2ShellSession.snapshot == request.snapshot else {
            store.installPhase2ShellSessionProjection(displaced)
            adapter.presentationFailed(requestGeneration: request.requestGeneration)
            return
        }
        ownership = Ownership(
            request: request,
            displacedProjection: displaced,
            lifecycle: .presented,
            didMount: false
        )
    }

    private func retireOwnedPresentation() {
        guard var ownership, ownership.lifecycle == .presented else { return }
        ownership.lifecycle = .retiring
        self.ownership = ownership
        if !ownership.didMount {
            restoreDisplacedProjection(requestGeneration: ownership.request.requestGeneration)
        }
    }

    private func restoreDisplacedProjection(requestGeneration: UUID) {
        guard let ownership,
              ownership.request.requestGeneration == requestGeneration else { return }
        store.installPhase2ShellSessionProjection(ownership.displacedProjection)
        self.ownership = nil
    }

    private func handle(
        _ state: Phase2InstalledShellRendererPresentation.State,
        requestGeneration: UUID
    ) {
        guard var ownership,
              ownership.request.requestGeneration == requestGeneration else { return }
        switch state {
        case .idle:
            break
        case let .mounted(mounted):
            guard ownership.lifecycle == .presented else { return }
            ownership.didMount = true
            self.ownership = ownership
            adapter.presentationMounted(
                requestGeneration: requestGeneration,
                sessionID: mounted.processCoordinate.sessionID,
                requestID: mounted.processCoordinate.requestID,
                shellProcessIdentifier: mounted.processCoordinate.processIdentifier,
                rendererBinding: mounted.rendererBinding
            )
        case .failed:
            adapter.presentationFailed(requestGeneration: requestGeneration)
            retireOwnedPresentation()
        case let .retired(mounted):
            adapter.presentationRetired(
                requestGeneration: requestGeneration,
                sessionID: mounted.processCoordinate.sessionID,
                requestID: mounted.processCoordinate.requestID,
                shellProcessIdentifier: mounted.processCoordinate.processIdentifier,
                rendererBinding: mounted.rendererBinding
            )
            restoreDisplacedProjection(requestGeneration: requestGeneration)
        }
    }
}

/// The recovery proof must instantiate the real legacy grid without mutating the user's persistent
/// recovery preference. The ordinary product presentation remains runtime-selected; only the
/// explicit installed-smoke request supplies this process-local recovery selection.
@MainActor
private struct Phase2InstalledForcedLegacyRendererPresentationView: View {
    @ObservedObject var store: WorkspaceStore

    let snapshot: Phase2HumanPTYSessionSnapshot
    let processCoordinate: Phase2InstalledShellRendererPresentation.ProcessCoordinate
    let stateChanged: Phase2InstalledShellRendererPresentation.StateHandler

    @State private var mountedState:
        Phase2InstalledShellRendererPresentation.MountedState?
    @State private var didRetire = false
    @State private var rendererLifecycle = MacScopeGhosttySurfaceDiagnostics
        .RendererLifecycleCoordinator(diagnostics: .rendererEvidenceShared)

    private let rendererSelection = Phase2TerminalRendererSelection(
        backend: .macScopeGhosttyVTGrid,
        fallback: .recoveryOverride
    )

    private var presentation: Phase2ShellAffordancePresentation? {
        guard let candidate = store.phase2ShellSession.snapshot,
              processCoordinate.matches(candidate) else { return nil }
        return .project(store.phase2ShellSession)
    }

    var body: some View {
        Group {
            if let mountedState, let presentation {
                Phase2TerminalEmulatorView(
                    turns: presentation.transcriptTurns,
                    fallbackText: presentation.transcriptPreview,
                    terminalSize: presentation.currentTerminalSize,
                    terminalSessionID: mountedState.processCoordinate.sessionID,
                    terminalRequestID: mountedState.processCoordinate.requestID,
                    terminalRendererGeneration: nil,
                    terminalLifecycleState: presentation.terminalLifecycleState,
                    transcriptEvents: presentation.terminalTranscriptEvents,
                    isInputEnabled: false,
                    inputHandler: { _ in },
                    resizeHandler: { _ in },
                    rendererSelection: rendererSelection,
                    fullSurfaceRendererFactory: nil,
                    rendererLifecycle: rendererLifecycle
                )
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .onAppear(perform: admitMount)
        .onChange(of: store.phase2ShellSession) { _, _ in
            revalidateMount()
        }
        .onDisappear(perform: retireMount)
    }

    private func admitMount() {
        guard mountedState == nil, !didRetire else { return }
        stateChanged(.idle)
        do {
            guard processCoordinate.matches(snapshot) else {
                throw Phase2InstalledShellRendererPresentation.AdmissionError
                    .snapshotCoordinateMismatch
            }
            guard let liveSnapshot = store.phase2ShellSession.snapshot else {
                throw Phase2InstalledShellRendererPresentation.AdmissionError.storeSnapshotMismatch
            }
            let mounted = try Phase2InstalledShellRendererPresentation.admit(
                snapshot: liveSnapshot,
                requestedMode: .forcedLegacyGridRecoveryOverride,
                processCoordinate: processCoordinate,
                selection: rendererSelection,
                surfaceCoordinate: nil
            )
            mountedState = mounted
            stateChanged(.mounted(mounted))
        } catch let error as Phase2InstalledShellRendererPresentation.AdmissionError {
            stateChanged(.failed(error))
        } catch {
            stateChanged(.failed(.transcriptCannotRenderRequestedBackend))
        }
    }

    private func revalidateMount() {
        guard mountedState != nil else { return }
        guard let liveSnapshot = store.phase2ShellSession.snapshot else {
            stateChanged(.failed(.storeSnapshotMismatch))
            return
        }
        do {
            _ = try Phase2InstalledShellRendererPresentation.admit(
                snapshot: liveSnapshot,
                requestedMode: .forcedLegacyGridRecoveryOverride,
                processCoordinate: processCoordinate,
                selection: rendererSelection,
                surfaceCoordinate: nil
            )
        } catch let error as Phase2InstalledShellRendererPresentation.AdmissionError {
            stateChanged(.failed(error))
        } catch {
            stateChanged(.failed(.transcriptCannotRenderRequestedBackend))
        }
    }

    private func retireMount() {
        guard !didRetire else { return }
        didRetire = true
        guard let mountedState else { return }
        self.mountedState = nil
        stateChanged(.retired(mountedState))
    }
}

/// Observes startup readiness and the document authorities that invalidate a Reconstruction runtime.
/// Keeping runtime resolution inside this host guarantees that selecting Reconstruction and an
/// in-place Save/Save As both rebuild the activation identity for the exact current document path.
@MainActor
struct ReconstructionWorkspaceRootHost: View {
    @ObservedObject var registry: WorkspaceSessionRegistry
    let launchConfiguration: WorkspaceLaunchConfiguration
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var documentSession: WorkspaceDocumentSession
    let openCoordinator: WorkspaceOpenCoordinator
    let windowActivator: WorkspaceWindowActivator
    let windowID: WorkspaceWindowID
    @ObservedObject var nativeDecompilerPresentation: NativeDecompilerPresentationModel
    let applicationOpenRouter: WorkspaceApplicationOpenRouter
    @Environment(\.openWindow) private var openWindow
    let assistantInferenceCoordinator: (any Phase2AssistantInferenceCoordinating)?
    let assistantProviderSnapshot: Phase2LocalAIProviderSnapshot?

    var body: some View {
        let reconstructionRuntime = registry.reconstructionRuntime(
            for: windowID,
            launchConfiguration: launchConfiguration
        )
        WorkspaceRootView(
            store: store,
            documentSession: documentSession,
            openCoordinator: openCoordinator,
            windowActivator: windowActivator,
            windowID: windowID,
            nativeDecompilerPresentation: nativeDecompilerPresentation,
            assistantInferenceCoordinator: assistantInferenceCoordinator,
            assistantProviderSnapshot: assistantProviderSnapshot,
            reconstructionActivationModel: reconstructionRuntime?.activationModel,
            reconstructionCommandActions: {
                reconstructionRuntime?.commandActions ?? .unavailable
            }
        )
        .onAppear {
            let action = openWindow
            applicationOpenRouter.installWindowPresenter { action(value: $0) }
        }
        .task(id: ReconstructionDestinationActivationIdentity(
            selectedTool: store.selectedTool,
            runtimeLifecycleID: reconstructionRuntime?.lifecycleID,
            canonicalDocumentPath: documentSession.snapshot.location?.canonicalURL.path
        )) {
            guard store.selectedTool == .reconstruction else { return }
            await reconstructionRuntime?.activateReconstructionDestination()
        }
    }
}

private struct ReconstructionDestinationActivationIdentity: Equatable {
    let selectedTool: WorkspaceTool
    let runtimeLifecycleID: UUID?
    let canonicalDocumentPath: String?
}

@MainActor
final class MacScopeApplicationDelegate: NSObject, NSApplicationDelegate {
    typealias Shutdown = @MainActor @Sendable () async -> Bool

    private var shutdown: Shutdown?
    private var terminationCoordinator: MacScopeAppTerminationCoordinator?
    private var didCompleteAuthoritativeShutdown = false
    private var openDocuments: (@MainActor ([URL]) -> Void)?
    private var pendingOpenDocuments: [URL] = []

    /// Installs the app-owned open-document router. URLs AppKit delivered first are replayed.
    func installOpenDocuments(_ handler: @escaping @MainActor ([URL]) -> Void) {
        openDocuments = handler
        guard !pendingOpenDocuments.isEmpty else { return }
        let pending = pendingOpenDocuments
        pendingOpenDocuments.removeAll()
        handler(pending)
    }

    /// LaunchServices' open-document route (`open -a`, Finder double-click, Dock drop), at launch
    /// and while running. Implementing this makes SwiftUI forward `kAEOpenDocuments` here instead
    /// of spawning a scene window whose `onOpenURL` never received the URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = application
        guard let openDocuments else {
            pendingOpenDocuments.append(contentsOf: urls)
            return
        }
        openDocuments(urls)
    }

    func install(shutdown: @escaping Shutdown) {
        precondition(
            self.shutdown == nil,
            "application runtime services may only be installed once"
        )
        self.shutdown = shutdown
    }

    /// Starts the LLDB capability proof off the main thread before any window is built. Editor
    /// windows construct their debugger client inside a SwiftUI `StateObject` initializer, where
    /// running (and waiting for) a subprocess on the main thread froze the UI and, on timeout,
    /// re-entered AppKit layout mid-update and aborted in AttributeGraph. Clients read the
    /// memoized result; one built before the proof finishes waits on a condition, not a run loop.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = notification
        XcodeLLDBCommandLineAdapter.prewarmProductionCapabilityProof()
    }

    /// Agent attach (MCP over a per-user socket) follows its Settings toggle; off by default.
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        MCPAttachCoordinator.shared.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        MCPAttachCoordinator.shared.stopListening()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    /// Starts at most one deferred AppKit termination attempt at a time.
    ///
    /// AppKit can ask again while the first async document drain is still pending. Those repeated
    /// requests must share both the shutdown and its single eventual reply; replying once per
    /// caller would answer one AppKit termination transaction multiple times. Kept internal so
    /// CoreTests can exercise the exact coalescing state machine without substituting an
    /// `NSApplication` process singleton.
    func requestTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateCancel }
        guard !didCompleteAuthoritativeShutdown else { return .terminateNow }
        guard terminationCoordinator == nil else { return .terminateLater }

        let coordinator: MacScopeAppTerminationCoordinator
        let decision: MacScopeApplicationTerminationDecision
        decision = MacScopeApplicationTerminationDecision()
        coordinator = MacScopeAppTerminationCoordinator {
            let shouldTerminate = await shutdown()
            await decision.record(shouldTerminate)
        }
        terminationCoordinator = coordinator

        Task { @MainActor [weak self] in
            await coordinator.terminate()
            let shouldTerminate = await decision.value
            if self?.terminationCoordinator === coordinator {
                if shouldTerminate {
                    self?.didCompleteAuthoritativeShutdown = true
                } else {
                    self?.terminationCoordinator = nil
                }
            }
            reply(shouldTerminate)
        }
        return .terminateLater
    }
}

private actor MacScopeApplicationTerminationDecision {
    private var recordedValue = false

    func record(_ value: Bool) {
        recordedValue = value
    }

    var value: Bool { recordedValue }
}

private enum MacScopeWindowPlacement {
    static func defaultFrame() -> WorkspaceLaunchWindowFrame {
        let display = primaryDisplayBounds()
        let margin: CGFloat = 48
        let width = min(max(display.width - margin * 2, 1080), 1440)
        let height = min(max(display.height - margin * 2, 680), 840)

        return WorkspaceLaunchWindowFrame(
            x: display.minX + margin,
            y: display.minY + margin,
            width: width,
            height: height
        )
    }

    // Open on the main display (the one that carries the menu bar) rather than the
    // geometrically leftmost screen. On multi-display setups the leftmost screen is
    // often a secondary monitor positioned at a large negative origin, which placed
    // the window off the user's primary screen and broke screenshot validation.
    private static func primaryDisplayBounds() -> CGRect {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        if mainBounds.width > 0, mainBounds.height > 0 {
            return mainBounds
        }
        return CGRect(x: 0, y: 0, width: 1280, height: 780)
    }
}

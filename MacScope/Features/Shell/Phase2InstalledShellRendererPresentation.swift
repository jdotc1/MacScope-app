import SwiftUI

/// Opt-in renderer mount used only by the installed shell smoke adapter.
///
/// Creating this value has no effect. The adapter must explicitly mount the returned view with a
/// live `WorkspaceStore`; ordinary launches never call this seam. Renderer proof still comes only
/// from `Phase2TerminalEmulatorView` recording its real SwiftUI lifecycle in the process ledger.
@MainActor
enum Phase2InstalledShellRendererPresentation {
    enum RequestedMode: String, Equatable, Sendable {
        case defaultFullGhosttySurface
        case forcedLegacyGridRecoveryOverride
    }

    struct ProcessCoordinate: Equatable, Sendable {
        let sessionID: UUID
        let requestID: UUID
        let processIdentifier: Int32

        var isStructurallyValid: Bool {
            processIdentifier > 0
        }

        func matches(_ snapshot: Phase2HumanPTYSessionSnapshot) -> Bool {
            guard snapshot.sessionID == sessionID,
                  case let .running(candidateRequestID, candidateProcessIdentifier) = snapshot.state
            else { return false }
            return candidateRequestID == requestID
                && candidateProcessIdentifier == processIdentifier
        }
    }

    enum AdmissionError: Error, Equatable, Sendable {
        case invalidProcessCoordinate
        case snapshotCoordinateMismatch
        case storeSnapshotMismatch
        case rendererSelectionMismatch
        case fullSurfaceBindingUnavailable
        case legacySurfaceMustNotHaveGeneration
        case transcriptCannotRenderRequestedBackend
    }

    struct MountedState: Equatable, Sendable {
        let processCoordinate: ProcessCoordinate
        let selection: Phase2TerminalRendererSelection
        let rendererBinding: MacScopeGhosttySurfaceDiagnostics.RendererBinding
    }

    enum State: Equatable, Sendable {
        case idle
        case mounted(MountedState)
        case failed(AdmissionError)
        case retired(MountedState)
    }

    typealias StateHandler = @MainActor @Sendable (State) -> Void

    static func makeView(
        store: WorkspaceStore,
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestedMode: RequestedMode,
        processCoordinate: ProcessCoordinate,
        stateChanged: @escaping StateHandler
    ) -> AnyView {
        AnyView(Phase2InstalledShellRendererPresentationView(
            store: store,
            snapshot: snapshot,
            requestedMode: requestedMode,
            processCoordinate: processCoordinate,
            stateChanged: stateChanged
        ))
    }

    static func admit(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestedMode: RequestedMode,
        processCoordinate: ProcessCoordinate,
        selection: Phase2TerminalRendererSelection,
        surfaceCoordinate: Phase2ShellSurfaceCommandCoordinate?
    ) throws -> MountedState {
        guard processCoordinate.isStructurallyValid else {
            throw AdmissionError.invalidProcessCoordinate
        }
        guard processCoordinate.matches(snapshot) else {
            throw AdmissionError.snapshotCoordinateMismatch
        }

        let generation: MacScopeGhosttySurfaceDiagnostics.RendererGenerationBinding
        switch requestedMode {
        case .defaultFullGhosttySurface:
            guard selection.backend == .ghosttyFullSurface,
                  selection.fallback == nil
            else { throw AdmissionError.rendererSelectionMismatch }
            guard let surfaceCoordinate,
                  surfaceCoordinate.isStructurallyValid,
                  surfaceCoordinate.sessionID == processCoordinate.sessionID,
                  surfaceCoordinate.requestID == processCoordinate.requestID
            else { throw AdmissionError.fullSurfaceBindingUnavailable }
            guard case .complete = Phase2GhosttyTranscriptAdmissionState.replay(
                coordinate: surfaceCoordinate.rendererCoordinate,
                events: snapshot.transcriptEvents
            ) else {
                throw AdmissionError.transcriptCannotRenderRequestedBackend
            }
            generation = .exact(surfaceCoordinate.generation)

        case .forcedLegacyGridRecoveryOverride:
            guard selection.backend == .macScopeGhosttyVTGrid,
                  selection.fallback == .recoveryOverride
            else { throw AdmissionError.rendererSelectionMismatch }
            guard surfaceCoordinate == nil else {
                throw AdmissionError.legacySurfaceMustNotHaveGeneration
            }
#if canImport(GhosttyVt)
            guard Phase2TerminalSurfacePresentation.renderingPath(
                sessionID: snapshot.sessionID,
                events: snapshot.transcriptEvents
            ) == .ghostty(snapshot.sessionID) else {
                throw AdmissionError.transcriptCannotRenderRequestedBackend
            }
            generation = .notAllocated
#else
            throw AdmissionError.transcriptCannotRenderRequestedBackend
#endif
        }

        guard let rendererBinding = rendererBinding(
            processCoordinate: processCoordinate,
            generation: generation
        ) else {
            throw AdmissionError.invalidProcessCoordinate
        }

        return MountedState(
            processCoordinate: processCoordinate,
            selection: selection,
            rendererBinding: rendererBinding
        )
    }

    /// Keep the diagnostics dependency centralized so every mounted renderer uses the exact
    /// process coordinate admitted above. The diagnostics initializer independently rejects an
    /// invalid broker PID instead of permitting the presentation seam to manufacture evidence.
    private static func rendererBinding(
        processCoordinate: ProcessCoordinate,
        generation: MacScopeGhosttySurfaceDiagnostics.RendererGenerationBinding
    ) -> MacScopeGhosttySurfaceDiagnostics.RendererBinding? {
        MacScopeGhosttySurfaceDiagnostics.RendererBinding(
            sessionID: processCoordinate.sessionID,
            requestID: processCoordinate.requestID,
            shellBrokerProcessIdentifier: processCoordinate.processIdentifier,
            generation: generation
        )
    }
}

@MainActor
private struct Phase2InstalledShellRendererPresentationView: View {
    private struct Mount {
        let state: Phase2InstalledShellRendererPresentation.MountedState
        let surfaceCoordinate: Phase2ShellSurfaceCommandCoordinate?
    }

    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var runtime = MacScopeGhosttyRuntime.productionShared

    let snapshot: Phase2HumanPTYSessionSnapshot
    let requestedMode: Phase2InstalledShellRendererPresentation.RequestedMode
    let processCoordinate: Phase2InstalledShellRendererPresentation.ProcessCoordinate
    let stateChanged: Phase2InstalledShellRendererPresentation.StateHandler

    @State private var mount: Mount?
    @State private var ownedSurfaceCoordinate: Phase2ShellSurfaceCommandCoordinate?
    @State private var didRetire = false
    @State private var rendererLifecycle = MacScopeGhosttySurfaceDiagnostics
        .RendererLifecycleCoordinator(diagnostics: .rendererEvidenceShared)

    private var liveSnapshot: Phase2HumanPTYSessionSnapshot? {
        guard let candidate = store.phase2ShellSession.snapshot,
              processCoordinate.matches(candidate)
        else { return nil }
        return candidate
    }

    private var presentation: Phase2ShellAffordancePresentation? {
        guard let liveSnapshot else { return nil }
        return .project(Phase2WorkspaceShellSessionProjection(
            snapshot: liveSnapshot,
            inFlightCommand: store.phase2ShellSession.inFlightCommand,
            lastError: store.phase2ShellSession.lastError,
            lastAcceptedTranscriptEvents: store.phase2ShellSession.lastAcceptedTranscriptEvents,
            lastBytesWritten: store.phase2ShellSession.lastBytesWritten,
            durableRecoveryIdentity: store.phase2ShellSession.durableRecoveryIdentity,
            surfaceMediation: store.phase2ShellSession.surfaceMediation,
            inFlightOperation: store.phase2ShellSession.inFlightOperation,
            surfaceGenerationHighWater: store.phase2ShellSession.surfaceGenerationHighWater
        ))
    }

    private var fullSurfaceRendererFactory: Phase2TerminalEmulatorView.FullSurfaceRendererFactory? {
        guard let coordinate = mount?.surfaceCoordinate else { return nil }
        let store = store
        return { context in
            guard context.transcript.coordinate == coordinate.rendererCoordinate else { return nil }
            return AnyView(
                Phase2GhosttyBrokerSurface(
                    store: store,
                    coordinate: coordinate,
                    context: context
                )
                .id(coordinate)
            )
        }
    }

    var body: some View {
        Group {
            if let mount, let presentation {
                Phase2TerminalEmulatorView(
                    turns: presentation.transcriptTurns,
                    fallbackText: presentation.transcriptPreview,
                    terminalSize: presentation.currentTerminalSize,
                    terminalSessionID: mount.state.processCoordinate.sessionID,
                    terminalRequestID: mount.state.processCoordinate.requestID,
                    terminalRendererGeneration: mount.surfaceCoordinate?.generation,
                    terminalLifecycleState: presentation.terminalLifecycleState,
                    transcriptEvents: presentation.terminalTranscriptEvents,
                    isInputEnabled: presentation.canSendInput,
                    inputHandler: { bytes in
                        routeLegacyInput(bytes, mount: mount)
                    },
                    resizeHandler: { size in
                        routeLegacyResize(size, mount: mount)
                    },
                    rendererSelection: mount.state.selection,
                    fullSurfaceRendererFactory: fullSurfaceRendererFactory,
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
        .onChange(of: runtime.state) { _, _ in
            revalidateMount()
        }
        .onDisappear(perform: retireMount)
    }

    private func admitMount() {
        guard mount == nil, !didRetire else { return }
        stateChanged(.idle)

        do {
            guard processCoordinate.matches(snapshot) else {
                throw Phase2InstalledShellRendererPresentation.AdmissionError
                    .snapshotCoordinateMismatch
            }
            guard let liveSnapshot else {
                throw Phase2InstalledShellRendererPresentation.AdmissionError.storeSnapshotMismatch
            }
            let runtimeState = runtime.prepare()
            let selection = Phase2TerminalRendererSelection.resolve(
                feature: runtime.feature,
                runtimeState: runtimeState
            )
            let coordinate: Phase2ShellSurfaceCommandCoordinate?
            switch requestedMode {
            case .defaultFullGhosttySurface:
                coordinate = try bindFullSurface()
            case .forcedLegacyGridRecoveryOverride:
                guard store.phase2ShellSession.surfaceMediation == nil else {
                    throw Phase2InstalledShellRendererPresentation.AdmissionError
                        .legacySurfaceMustNotHaveGeneration
                }
                coordinate = nil
            }
            let state = try Phase2InstalledShellRendererPresentation.admit(
                snapshot: liveSnapshot,
                requestedMode: requestedMode,
                processCoordinate: processCoordinate,
                selection: selection,
                surfaceCoordinate: coordinate
            )
            let mount = Mount(state: state, surfaceCoordinate: coordinate)
            self.mount = mount
            stateChanged(.mounted(state))
        } catch let error as Phase2InstalledShellRendererPresentation.AdmissionError {
            fail(error)
        } catch {
            fail(.fullSurfaceBindingUnavailable)
        }
    }

    private func revalidateMount() {
        guard let mount else { return }
        do {
            guard let liveSnapshot else {
                throw Phase2InstalledShellRendererPresentation.AdmissionError.storeSnapshotMismatch
            }
            let currentSelection = Phase2TerminalRendererSelection.resolve(
                feature: runtime.feature,
                runtimeState: runtime.state
            )
            guard currentSelection == mount.state.selection else {
                throw Phase2InstalledShellRendererPresentation.AdmissionError
                    .rendererSelectionMismatch
            }
            if let coordinate = mount.surfaceCoordinate {
                guard store.phase2ShellSession.surfaceMediation?.coordinate == coordinate else {
                    throw Phase2InstalledShellRendererPresentation.AdmissionError
                        .fullSurfaceBindingUnavailable
                }
            } else if store.phase2ShellSession.surfaceMediation != nil {
                throw Phase2InstalledShellRendererPresentation.AdmissionError
                    .legacySurfaceMustNotHaveGeneration
            }
            _ = try Phase2InstalledShellRendererPresentation.admit(
                snapshot: liveSnapshot,
                requestedMode: requestedMode,
                processCoordinate: processCoordinate,
                selection: currentSelection,
                surfaceCoordinate: mount.surfaceCoordinate
            )
        } catch let error as Phase2InstalledShellRendererPresentation.AdmissionError {
            fail(error)
        } catch {
            fail(.fullSurfaceBindingUnavailable)
        }
    }

    private func bindFullSurface() throws -> Phase2ShellSurfaceCommandCoordinate {
        guard store.phase2ShellSession.surfaceMediation == nil,
              ownedSurfaceCoordinate == nil
        else {
            throw Phase2InstalledShellRendererPresentation.AdmissionError
                .fullSurfaceBindingUnavailable
        }
        let previousGeneration: UInt64
        if let highWater = store.phase2ShellSession.surfaceGenerationHighWater,
           highWater.sessionID == processCoordinate.sessionID,
           highWater.requestID == processCoordinate.requestID {
            previousGeneration = highWater.generation
        } else {
            previousGeneration = 0
        }
        let nextGeneration = previousGeneration.addingReportingOverflow(1)
        guard !nextGeneration.overflow, nextGeneration.partialValue > 0 else {
            throw Phase2InstalledShellRendererPresentation.AdmissionError
                .fullSurfaceBindingUnavailable
        }
        let candidate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: processCoordinate.sessionID,
            requestID: processCoordinate.requestID,
            generation: nextGeneration.partialValue
        )
        guard store.bindPhase2ShellSurface(generation: candidate.generation) == candidate else {
            throw Phase2InstalledShellRendererPresentation.AdmissionError
                .fullSurfaceBindingUnavailable
        }
        ownedSurfaceCoordinate = candidate
        return candidate
    }

    private func routeLegacyInput(_ bytes: [UInt8], mount: Mount) {
        guard mount.surfaceCoordinate == nil,
              presentation?.canSendInput == true,
              !bytes.isEmpty
        else { return }
        Task {
            guard self.mount?.state == mount.state,
                  presentation?.canSendInput == true,
                  liveSnapshot != nil
            else { return }
            await store.writePhase2ShellInput(bytes)
        }
    }

    private func routeLegacyResize(
        _ size: Phase2HumanPTYTerminalSize,
        mount: Mount
    ) {
        guard mount.surfaceCoordinate == nil,
              presentation?.canResize == true,
              size != presentation?.currentTerminalSize
        else { return }
        Task {
            guard self.mount?.state == mount.state,
                  presentation?.canResize == true,
                  liveSnapshot != nil
            else { return }
            await store.resizePhase2ShellSession(to: size)
        }
    }

    private func fail(
        _ error: Phase2InstalledShellRendererPresentation.AdmissionError
    ) {
        stateChanged(.failed(error))
        // A failure after admission still owes the host the matching retirement.
        // Keep the mount alive until retireMount captures and reports its exact state.
        retireMount()
    }

    private func retireMount() {
        guard !didRetire else { return }
        didRetire = true
        let mountedState = mount?.state
        mount = nil
        retireSurfaceBinding()
        if let mountedState {
            stateChanged(.retired(mountedState))
        }
    }

    private func retireSurfaceBinding() {
        guard let coordinate = ownedSurfaceCoordinate else { return }
        ownedSurfaceCoordinate = nil
        store.retirePhase2ShellSurface(coordinate)
    }
}

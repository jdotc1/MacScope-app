import XCTest
@testable import MacScope

/// Model-level teardown/rebind checks. Actual SwiftUI/AppKit unmounting and live PTY
/// continuity remain installed-app checks; constructing a view is not lifecycle proof.
@MainActor
final class Phase2ShellPanelRetentionTests: XCTestCase {
    func testRetiringPresentationPreservesDraftsHistoryAndSearchForReplacementView() async {
        let transport = PanelRetentionTransport()
        let store = makeStore(transport)
        let state = Phase2ShellAffordanceState()
        state.isAffordanceVisible = true
        state.pendingInput = "draft input"
        state.inputHistory.commit("pwd")
        state.launchExecutablePath = "/bin/bash"
        state.launchArgumentsText = "-l"
        state.launchEnvironmentText = "TERM=xterm-256color"
        state.launchWorkingDirectoryPath = "/tmp"
        state.terminalColumnsText = "120"
        state.terminalRowsText = "32"
        state.transcriptSearchText = "needle"
        state.visibleTranscriptCutoffSequence = 17
        state.isAutoPollingEnabled = false
        state.shouldFollowLatestTranscript = false
        let restoredID = UUID()
        state.lastAppliedRestoredLaunchSessionID = restoredID
        let oldPresentationID = state.terminalPresentationID

        state.retirePresentation(in: store)
        let replacement = Phase2ShellAffordanceView(store: store, state: state)

        XCTAssertTrue(replacement.state === state)
        XCTAssertEqual(replacement.state.pendingInput, "draft input")
        XCTAssertEqual(replacement.state.inputHistory.entries, ["pwd"])
        XCTAssertEqual(replacement.state.launchExecutablePath, "/bin/bash")
        XCTAssertEqual(replacement.state.launchArgumentsText, "-l")
        XCTAssertEqual(replacement.state.launchEnvironmentText, "TERM=xterm-256color")
        XCTAssertEqual(replacement.state.launchWorkingDirectoryPath, "/tmp")
        XCTAssertEqual(replacement.state.terminalColumnsText, "120")
        XCTAssertEqual(replacement.state.terminalRowsText, "32")
        XCTAssertEqual(replacement.state.transcriptSearchText, "needle")
        XCTAssertEqual(replacement.state.visibleTranscriptCutoffSequence, 17)
        XCTAssertFalse(replacement.state.isAutoPollingEnabled)
        XCTAssertFalse(replacement.state.shouldFollowLatestTranscript)
        XCTAssertEqual(replacement.state.lastAppliedRestoredLaunchSessionID, restoredID)
        XCTAssertFalse(state.isAffordanceVisible)
        XCTAssertNotEqual(state.terminalPresentationID, oldPresentationID)
        XCTAssertNil(store.phase2ShellSession.snapshot)
        let calls = await transport.calls
        XCTAssertEqual(calls, 0, "Hide/remount must not start an arbitrary session")
    }

    func testRetirementRevokesRendererOnlyAndRebindKeepsExactRunningSession() async throws {
        let transport = PanelRetentionTransport()
        let store = makeStore(transport)
        let sessionID = UUID()
        let requestID = UUID()
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 901),
            launchPlan: Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                initialSize: .defaultInteractive
            ),
            transcriptEvents: [],
            issues: []
        )
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))
        let state = Phase2ShellAffordanceState()
        state.isAffordanceVisible = true
        _ = state.rendererState.activate(.init(backend: .ghosttyFullSurface, fallback: nil))
        guard case let .replace(_, first) = state.ghosttySurfaceBinding.reconcile(
            sessionID: sessionID, requestID: requestID
        ) else { return XCTFail("Expected first renderer generation") }
        XCTAssertEqual(store.bindPhase2ShellSurface(generation: first.generation), first)

        state.retirePresentation(in: store)

        XCTAssertEqual(store.phase2ShellSession.snapshot, snapshot)
        XCTAssertNil(store.phase2ShellSession.surfaceMediation)
        XCTAssertEqual(store.phase2ShellSession.surfaceGenerationHighWater, first)
        XCTAssertNil(state.ghosttySurfaceBinding.activeCoordinate)
        XCTAssertFalse(state.rendererState.presentsTerminal)
        let retiredPresentationID = state.terminalPresentationID
        state.retirePresentation(in: store)
        XCTAssertEqual(state.terminalPresentationID, retiredPresentationID, "Retirement is idempotent")

        guard case let .replace(_, replacement) = state.ghosttySurfaceBinding.reconcile(
            sessionID: sessionID, requestID: requestID
        ) else { return XCTFail("Expected replacement renderer generation") }
        XCTAssertGreaterThan(replacement.generation, first.generation)
        XCTAssertEqual(store.bindPhase2ShellSurface(generation: replacement.generation), replacement)
        // A late disappearing view cannot revoke the newly bound generation.
        store.retirePhase2ShellSurface(first)
        XCTAssertEqual(store.phase2ShellSession.surfaceMediation?.coordinate, replacement)
        XCTAssertEqual(store.phase2ShellSession.snapshot, snapshot)
        let calls = await transport.calls
        XCTAssertEqual(calls, 0, "Presentation teardown must not request PTY cleanup, signal, or launch")
    }

    private func makeStore(_ transport: PanelRetentionTransport) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Panel retention",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(),
            autosaveScheduler: nil,
            phase2ShellSessionClient: Phase2HumanPTYShellSessionClient(transport: transport),
            phase2ShellBrokerEndpoint: .embeddedApplicationService
        )
    }
}

private actor PanelRetentionTransport: MacScope.ShellBrokerXPCTransport {
    private(set) var calls = 0

    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake {
        calls += 1
        throw MacScope.ShellBrokerXPCTransportError.unavailable("No broker allowed in retention test")
    }

    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        calls += 1
        throw MacScope.ShellBrokerXPCTransportError.unavailable("No broker allowed in retention test")
    }

    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        calls += 1
        throw MacScope.ShellBrokerXPCTransportError.unavailable("No broker allowed in retention test")
    }

    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool {
        calls += 1
        return false
    }

    func reset() async { calls += 1 }
}

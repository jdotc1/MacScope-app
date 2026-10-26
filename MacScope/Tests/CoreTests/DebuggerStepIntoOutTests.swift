import XCTest
@testable import MacScope

/// Focused coverage for the Step Into / Step Out debugger transport, mirroring
/// the existing Step Over end-to-end coverage in `DebuggerCoreTests`:
///
///  * the live LLDB command session issues `thread step-in` / `thread step-out`
///    (plus the stopped-state snapshot refresh) when the process is paused,
///  * the view-model `stepInto()` / `stepOut()` actions are gated exactly like
///    `stepOver()` (paused live process + execution-control support),
///  * the new control-action surface (`DebuggerControlAction.stepInto/.stepOut`)
///    is plumbed through `controlAvailability(for:)`.
///
/// Fixtures here are intentionally self-contained so this file never collides
/// with the shared test doubles in other debugger test files.
@MainActor
final class DebuggerStepIntoOutTests: XCTestCase {

    // MARK: - Live transport (mirrors the Step Over transport assertion)

    func testLiveCommandSessionStepsIntoAndOutThroughTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = StepFakeLLDBCommandSessionTransport(responses: [
            // launch setup + launch + status + stopped-refresh
            .empty,
            .empty,
            .launchStoppedAtEntry,
            .statusStopped,
            .backtrace,
            .registers,
            .stackMemory,
            // step-into + status + stopped-refresh
            .stepInStopped,
            .stepInStatusStopped,
            .backtrace,
            .registers,
            .stackMemory,
            // step-out + status + stopped-refresh
            .stepOutStopped,
            .stepOutStatusStopped,
            .backtrace,
            .registers,
            .stackMemory
        ])
        let runner = StepFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeStepProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        XCTAssertEqual(launched.processState, .paused(processID: 222, reason: .unknown("Stopped at entry")))

        let steppedInto = try await client.stepInto(from: launched)
        XCTAssertEqual(steppedInto.processState, .paused(processID: 222, reason: .step))
        XCTAssertEqual(
            steppedInto.lastCommandRun?.commandDisplay,
            "thread step-in; process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp"
        )

        let steppedOut = try await client.stepOut(from: steppedInto)
        XCTAssertEqual(steppedOut.processState, .paused(processID: 222, reason: .step))
        XCTAssertEqual(
            steppedOut.lastCommandRun?.commandDisplay,
            "thread step-out; process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp"
        )

        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp",
            "thread step-in",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp",
            "thread step-out",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
        XCTAssertEqual(transport.stopCallCount, 0)
    }

    // MARK: - View-model action dispatch (mirrors stepOver gating)

    func testViewModelStepIntoAndStepOutIssueClientCommandsInLiveSession() async {
        let client = StepRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canStepInto)
        XCTAssertTrue(viewModel.canStepOut)
        XCTAssertTrue(viewModel.controlAvailability(for: .stepInto).isEnabled)
        XCTAssertTrue(viewModel.controlAvailability(for: .stepOut).isEnabled)

        await viewModel.stepInto()
        XCTAssertEqual(client.stepIntoCallCount, 1)
        XCTAssertEqual(client.stepOutCallCount, 0)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.session.processState, .paused(processID: 222, reason: .step))
        XCTAssertEqual(viewModel.lastControlledRuntimeActionEvent?.action, .stepInto)
        XCTAssertEqual(viewModel.lastControlledRuntimeActionEvent?.sequence, 1)
        XCTAssertEqual(
            viewModel.lastControlledRuntimeActionEvent?.sessionID,
            UUID(uuidString: "50000000-0000-0000-0000-000000000001")
        )

        await viewModel.stepOut()
        XCTAssertEqual(client.stepIntoCallCount, 1)
        XCTAssertEqual(client.stepOutCallCount, 1)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.session.processState, .paused(processID: 222, reason: .step))
        XCTAssertEqual(viewModel.lastControlledRuntimeActionEvent?.action, .stepOut)
        XCTAssertEqual(viewModel.lastControlledRuntimeActionEvent?.sequence, 2)
    }

    func testViewModelStepIntoAndStepOutGatedExactlyLikeStepOver() async {
        // Mismatched backend pid -> not a live session -> all stepping gated off,
        // and invoking the actions must not reach the client (matches stepOver).
        let mismatched = DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 999, adapterName: "Step Recording LLDB")
        )
        let client = StepRecordingDebuggerClient(initialSnapshot: mismatched)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertEqual(viewModel.canStepInto, viewModel.canStepOver)
        XCTAssertEqual(viewModel.canStepOut, viewModel.canStepOver)
        XCTAssertFalse(viewModel.canStepInto)
        XCTAssertFalse(viewModel.canStepOut)

        await viewModel.stepInto()
        XCTAssertEqual(client.stepIntoCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Step into requires a paused live debug process.")
        XCTAssertEqual(viewModel.session.processState, mismatched.processState)
        XCTAssertEqual(viewModel.session.backendState, .failed(reason: "Step into requires a paused live debug process."))
        XCTAssertNil(viewModel.lastControlledRuntimeActionEvent)

        await viewModel.stepOut()
        XCTAssertEqual(client.stepOutCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Step out requires a paused live debug process.")
        XCTAssertEqual(viewModel.session.processState, mismatched.processState)
        XCTAssertEqual(viewModel.session.backendState, .failed(reason: "Step out requires a paused live debug process."))
        XCTAssertNil(viewModel.lastControlledRuntimeActionEvent)
    }

    func testViewModelStepIntoAndStepOutPreserveStateWhenBackendUnsupported() async {
        // A client without execution-control support keeps step into/out disabled
        // and surfaces the unavailable reason, identical to the stepOver posture.
        let client = StepUnsupportedControlDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canStepInto)
        XCTAssertFalse(viewModel.canStepOut)

        await viewModel.stepInto()
        XCTAssertEqual(client.stepIntoCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.hasPrefix("Step into unavailable:") ?? false)
        XCTAssertNil(viewModel.lastControlledRuntimeActionEvent)

        await viewModel.stepOut()
        XCTAssertEqual(client.stepOutCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.hasPrefix("Step out unavailable:") ?? false)
        XCTAssertNil(viewModel.lastControlledRuntimeActionEvent)
    }

    func testWorkspaceStoreRecordsAcceptedControlledDebuggerAuthorityEvent() async throws {
        let client = StepRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        let store = WorkspaceStore(
            workspaceName: "Debugger Control Authority",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )

        await viewModel.stepInto()
        let event = try XCTUnwrap(viewModel.lastControlledRuntimeActionEvent)
        store.updatePhase2DebuggerControlledRuntimeAction(event)
        store.updatePhase2DebuggerControlledRuntimeAction(event)

        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 1)
        let record = try XCTUnwrap(store.phase2RuntimeAuthorityRecords.first)
        XCTAssertEqual(record.sessionID, event.sessionID)
        XCTAssertEqual(record.surfaces, [.debuggerControl])
        XCTAssertEqual(record.debuggerAuthorityPolicy, .controlledRuntimeActions)
        XCTAssertFalse(record.providerVisibleShellExecutionEnabled)
        XCTAssertTrue(record.authorityRecord.isStructurallyValid)
    }

    func testControlActionTitlesForSteppingActions() {
        XCTAssertEqual(DebuggerControlAction.stepInto.title, "Step Into")
        XCTAssertEqual(DebuggerControlAction.stepOut.title, "Step Out")
    }

    // MARK: - Shared snapshot fixture

    private static var pausedLiveSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0010)],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused at breakpoint.",
            backendState: .connected(processID: 222, adapterName: "Step Recording LLDB"),
            transportSessionCoordinate: DebuggerSessionCoordinate(
                epoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!),
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
            ),
            transportStopCoordinate: DebuggerStopCoordinate(
                session: DebuggerSessionCoordinate(
                    epoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!),
                    lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
                ),
                stopRevision: DebuggerStopRevision(rawValue: 1)
            ),
            transportEventSequence: DebuggerEventSequence(rawValue: 3),
            transportTargetDisposition: .stopped(processID: 222)
        )
    }
}

// MARK: - Self-contained test doubles

@MainActor
private final class StepRecordingDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var stepIntoCallCount = 0
    private(set) var stepOutCallCount = 0

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Step Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        initialSnapshot
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepIntoCallCount += 1
        var copy = Self.advancedStoppedSnapshot(from: snapshot)
        copy.processState = .paused(processID: 222, reason: .step)
        copy.statusMessage = "Step into completed."
        return copy
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepOutCallCount += 1
        var copy = Self.advancedStoppedSnapshot(from: snapshot)
        copy.processState = .paused(processID: 222, reason: .step)
        copy.statusMessage = "Step out completed."
        return copy
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    private static func advancedStoppedSnapshot(
        from snapshot: DebuggerSessionSnapshot
    ) -> DebuggerSessionSnapshot {
        guard let coordinate = snapshot.transportSessionCoordinate else { return snapshot }
        var copy = snapshot
        let nextCoordinate = DebuggerSessionCoordinate(
            epoch: coordinate.epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: coordinate.lifecycleRevision.rawValue + 1)
        )
        copy.transportSessionCoordinate = nextCoordinate
        copy.transportStopCoordinate = DebuggerStopCoordinate(
            session: nextCoordinate,
            stopRevision: DebuggerStopRevision(
                rawValue: (snapshot.transportStopCoordinate?.stopRevision.rawValue ?? 0) + 1
            )
        )
        copy.transportEventSequence = DebuggerEventSequence(
            rawValue: (snapshot.transportEventSequence?.rawValue ?? 0) + 1
        )
        copy.transportTargetDisposition = .stopped(processID: 222)
        return copy
    }
}

@MainActor
private final class StepUnsupportedControlDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var stepIntoCallCount = 0
    private(set) var stepOutCallCount = 0

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Step Batch LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: false,
        limitations: ["Execution control disabled in this batch-only test client."],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        initialSnapshot
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepIntoCallCount += 1
        return snapshot
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepOutCallCount += 1
        return snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

private final class StepFakeDebuggerProcessRunner: DebuggerProcessRunning {
    private let result: DebuggerSubprocessResult
    private(set) var commands: [DebuggerExternalCommand] = []

    init(result: DebuggerSubprocessResult) {
        self.result = result
    }

    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult {
        commands.append(command)
        return result
    }
}

private final class StepFakeLLDBCommandSessionTransport: DebuggerLLDBCommandSessionTransport {
    private var responses: [DebuggerLLDBCommandResponse]
    private(set) var startCommands: [DebuggerExternalCommand] = []
    private(set) var sentCommands: [String] = []
    private(set) var stopCallCount = 0

    init(responses: [DebuggerLLDBCommandResponse]) {
        self.responses = responses
    }

    func start(_ command: DebuggerExternalCommand) throws {
        startCommands.append(command)
    }

    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse {
        sentCommands.append(command)
        guard !responses.isEmpty else {
            throw DebuggerLLDBCommandSessionError.writeFailed("Step fake transport has no queued response.")
        }
        var response = responses.removeFirst()
        response.command = command
        return response
    }

    func stop() {
        stopCallCount += 1
    }
}

private extension DebuggerLLDBCommandResponse {
    static var empty: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(command: "", standardOutput: "")
    }

    static var launchStoppedAtEntry: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process launch --stop-at-entry",
            standardOutput: """
            Process 222 launched: '/bin/echo' (arm64e)
            Process 222 stopped
                frame #0: 0x0000000100000000 dyld`_dyld_start
            """
        )
    }

    static var statusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: "Process 222 stopped"
        )
    }

    static var backtrace: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread backtrace",
            standardOutput: """
            * thread #1, queue = 'com.apple.main-thread'
              * frame #0: 0x00000001000003f8 echo`main + 8 at main.swift:12:5
                frame #1: 0x0000000180001000 dyld`start + 604
            """
        )
    }

    static var registers: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            standardOutput: """
                  pc = 0x00000001000003f8 echo`main + 8
                  sp = 0x000000016fdff200
                  fp = 0x000000016fdff220
                  lr = 0x0000000180001000 dyld`start + 604
                  x0 = 0x0000000000000001
            """
        )
    }

    static var stackMemory: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory read --format x --size 1 --count 64 $sp",
            standardOutput: """
            0x000000016fdff200: 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
            0x000000016fdff208: 0x08 0xf4 0xdf 0x6f 0x01 0x00 0x00 0x00
            """
        )
    }

    static var stepInStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread step-in",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = step in
            """
        )
    }

    static var stepInStatusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = step in
            """
        )
    }

    static var stepOutStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread step-out",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = step out
            """
        )
    }

    static var stepOutStatusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = step out
            """
        )
    }
}

private extension DebuggerSubprocessResult {
    static var successfulProof: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) version
            lldb-2103.0.23.6
            (lldb) platform status
              Platform: host
                Triple: arm64-apple-macosx
            (lldb) settings show target.default-arch
            target.default-arch (arch) =
            """,
            standardError: "",
            timedOut: false
        )
    }
}

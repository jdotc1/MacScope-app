import XCTest
@testable import MacScope

/// Tier-3 DEBUGGER-DEPTH: background wait-for-stop state machine + call-stack
/// frame selection.
///
/// These cover the non-UI / non-runtime logic for the two remaining debugger
/// items, mirroring the expression / thread-selection test style:
///
///  * `DebuggerWaitStopMachine` reducer transitions (idle → waiting → stopped on a
///    stop event; stays waiting on `.stillRunning`; handles exit / crash / fail),
///  * `DebuggerWaitStopMachine.state(for:)` snapshot bridging,
///  * `DebuggerFrameSelectionRequest` / `DebuggerFrameSelection` validation +
///    gating to a paused-live session,
///  * the `frame select <index>` command string,
///  * the view model's `selectFrame(_:)` gating, right client call, selected-frame
///    PC for listing navigation, and the wait-stop in-flight surfacing,
///  * the live LLDB command session issuing `frame select` through the transport.
@MainActor
final class DebuggerWaitStopFrameTests: XCTestCase {

    // MARK: - Wait-stop state machine transitions

    func testWaitStopMachineRunsThenStopsOnStopEvent() {
        var machine = DebuggerWaitStopMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(machine.state.canIssueRunCommand)

        XCTAssertTrue(machine.beginRun(.resume))
        XCTAssertEqual(machine.state, .waitingForStop(intent: .resume))
        XCTAssertTrue(machine.state.isWaiting)
        // While waiting, no new run command may be issued.
        XCTAssertFalse(machine.state.canIssueRunCommand)

        machine.apply(.stopped(reason: .breakpoint(address: 0x1000)))
        XCTAssertEqual(machine.state, .stopped(reason: .breakpoint(address: 0x1000)))
        XCTAssertTrue(machine.state.isStopped)
        XCTAssertTrue(machine.state.canIssueRunCommand)
    }

    func testWaitStopMachineStaysWaitingUntilStop() {
        var machine = DebuggerWaitStopMachine()
        machine.beginRun(.stepOver)

        // A poll that observes the process is still running keeps the machine
        // waiting, preserving the in-flight intent.
        machine.apply(.stillRunning)
        XCTAssertEqual(machine.state, .waitingForStop(intent: .stepOver))
        machine.apply(.stillRunning)
        XCTAssertEqual(machine.state, .waitingForStop(intent: .stepOver))

        machine.apply(.stopped(reason: .step))
        XCTAssertEqual(machine.state, .stopped(reason: .step))
    }

    func testWaitStopMachineHandlesExit() {
        var machine = DebuggerWaitStopMachine()
        machine.beginRun(.resume)
        machine.apply(.exited(code: 0))
        XCTAssertEqual(machine.state, .exited(code: 0))
        XCTAssertTrue(machine.state.isTerminated)
        // A terminated process cannot resume.
        XCTAssertFalse(machine.state.canIssueRunCommand)
    }

    func testWaitStopMachineHandlesCrash() {
        var machine = DebuggerWaitStopMachine()
        machine.beginRun(.resume)
        machine.apply(.crashed(signal: "SIGSEGV"))
        XCTAssertEqual(machine.state, .crashed(signal: "SIGSEGV"))
        XCTAssertTrue(machine.state.isTerminated)
    }

    func testWaitStopMachineFailureIsAlwaysHonoredAndRecoverable() {
        var machine = DebuggerWaitStopMachine()
        machine.beginRun(.resume)
        machine.apply(.failed(reason: "Wait timed out."))
        XCTAssertEqual(machine.state, .failed(reason: "Wait timed out."))
        // A failed wait is recoverable: a fresh run command may be issued.
        XCTAssertTrue(machine.state.canIssueRunCommand)
        XCTAssertTrue(machine.beginRun(.resume))
    }

    func testWaitStopMachineIgnoresStrayEventsWhenNotWaiting() {
        var machine = DebuggerWaitStopMachine(state: .stopped(reason: .step))
        // A stop event that arrives when we are not waiting does not regress the
        // lifecycle (no double-stop).
        machine.apply(.stopped(reason: .breakpoint(address: 0x2000)))
        XCTAssertEqual(machine.state, .stopped(reason: .step))

        // A late event after termination is also ignored (no resurrection).
        var terminated = DebuggerWaitStopMachine(state: .exited(code: 1))
        terminated.apply(.stopped(reason: .step))
        XCTAssertEqual(terminated.state, .exited(code: 1))
    }

    func testWaitStopMachineBeginRunRejectedWhileWaitingOrTerminated() {
        var waiting = DebuggerWaitStopMachine(state: .waitingForStop(intent: .resume))
        XCTAssertFalse(waiting.beginRun(.stepOver))
        XCTAssertEqual(waiting.state, .waitingForStop(intent: .resume))

        var exited = DebuggerWaitStopMachine(state: .exited(code: 0))
        XCTAssertFalse(exited.beginRun(.resume))
        XCTAssertEqual(exited.state, .exited(code: 0))
    }

    func testWaitStopStatusDetailIsHonest() {
        XCTAssertEqual(
            DebuggerWaitStopState.waitingForStop(intent: .stepInto).statusDetail,
            "Stepping into… waiting for the process to stop."
        )
        XCTAssertEqual(
            DebuggerWaitStopState.crashed(signal: "SIGABRT").statusDetail,
            "Process crashed: SIGABRT."
        )
    }

    // MARK: - Snapshot → state bridging

    func testWaitStopStateForPausedSnapshotIsStopped() {
        let state = DebuggerWaitStopMachine.state(for: Self.pausedLiveSnapshot)
        XCTAssertEqual(state, .stopped(reason: .breakpoint(address: 0x1000_0010)))
    }

    func testWaitStopStateForRunningSnapshotIsWaiting() {
        let running = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "WaitStop Recording LLDB")
        )
        XCTAssertEqual(
            DebuggerWaitStopMachine.state(for: running, runningIntent: .resume),
            .waitingForStop(intent: .resume)
        )
    }

    func testWaitStopStateForExitedSnapshotIsExited() {
        let exited = DebuggerSessionSnapshot(
            processState: .exited(code: 3),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Exited.",
            backendState: .ready(adapterName: "WaitStop Recording LLDB")
        )
        XCTAssertEqual(DebuggerWaitStopMachine.state(for: exited), .exited(code: 3))
    }

    // MARK: - Frame selection request validation

    func testFrameSelectionRequestAcceptsInRangeIndex() {
        guard case .success(let request) = DebuggerFrameSelectionRequest.parse(index: 0, frameCount: 3) else {
            return XCTFail("Frame index 0 of 3 should parse.")
        }
        XCTAssertEqual(request.index, 0)
    }

    func testFrameSelectionRequestRejectsNegativeIndex() {
        if case .success = DebuggerFrameSelectionRequest.parse(index: -1, frameCount: 3) {
            XCTFail("A negative frame index should be rejected.")
        }
    }

    func testFrameSelectionRequestRejectsOutOfRangeIndex() {
        if case .success = DebuggerFrameSelectionRequest.parse(index: 3, frameCount: 3) {
            XCTFail("An out-of-range frame index should be rejected.")
        }
    }

    func testFrameSelectionRequestRejectsWhenNoFrames() {
        if case .success = DebuggerFrameSelectionRequest.parse(index: 0, frameCount: 0) {
            XCTFail("Selecting a frame with no frames should be rejected.")
        }
    }

    // MARK: - Frame selection resolve + gating

    func testFrameSelectionResolveReturnsRightFrameAndPC() {
        guard case .success(let selection) = DebuggerFrameSelection.resolve(index: 1, in: Self.pausedLiveSnapshot) else {
            return XCTFail("Resolving frame 1 in a paused live session should succeed.")
        }
        XCTAssertEqual(selection.index, 1)
        XCTAssertEqual(selection.frame.functionName, "caller")
        // The listing navigates to the SELECTED frame's PC, not the innermost.
        XCTAssertEqual(selection.programCounter, 0x1000_0100)
    }

    func testFrameSelectionResolveGatedOffWhenNotPausedLive() {
        let running = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: Self.twoFrames,
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "WaitStop Recording LLDB")
        )
        if case .success = DebuggerFrameSelection.resolve(index: 0, in: running) {
            XCTFail("Frame selection should be gated off for a running session.")
        }
    }

    // MARK: - Command strings

    func testFrameSelectCommandString() {
        let request = DebuggerFrameSelectionRequest(index: 2)
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeFrameSelectCommand(for: request),
            "frame select 2"
        )
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.liveFrameVariablesCommand, "frame variable")
    }

    func testControlActionTitleForSelectFrame() {
        XCTAssertEqual(DebuggerControlAction.selectFrame.title, "Select Frame")
    }

    // MARK: - View model: selectFrame()

    func testViewModelSelectFrameFormsClientCallAndNavigatesPC() async {
        let client = WaitStopFrameRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canSelectFrame)
        XCTAssertTrue(viewModel.controlAvailability(for: .selectFrame).isEnabled)
        // Default selected-frame PC is the innermost frame.
        XCTAssertEqual(viewModel.selectedFrameProgramCounter, 0x1000_0010)

        await viewModel.selectFrame(1)

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.selectFrameCallCount, 1)
        XCTAssertEqual(client.lastFrameSelection, DebuggerFrameSelectionRequest(index: 1))
        XCTAssertEqual(viewModel.selectedFrameIndex, 1)
        // The listing now navigates to the SELECTED frame's PC.
        XCTAssertEqual(viewModel.selectedFrameProgramCounter, 0x1000_0100)
    }

    func testViewModelSelectFrameRejectsOutOfRangeWithoutClientCall() async {
        let client = WaitStopFrameRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.selectFrame(9)

        XCTAssertEqual(client.selectFrameCallCount, 0)
        XCTAssertNil(viewModel.selectedFrameIndex)
        XCTAssertTrue(viewModel.lastError?.contains("out of range") ?? false)
    }

    func testViewModelSelectFrameGatedOffWhenNotPausedLive() async {
        let mismatched = DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            breakpoints: [],
            frames: Self.twoFrames,
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 999, adapterName: "WaitStop Recording LLDB")
        )
        let client = WaitStopFrameRecordingDebuggerClient(initialSnapshot: mismatched)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canSelectFrame)
        await viewModel.selectFrame(0)

        XCTAssertEqual(client.selectFrameCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Frame selection requires a paused live debug process.")
    }

    // MARK: - View model: background wait-stop surfacing

    func testViewModelContinueSurfacesStoppedWaitStateAfterStop() async {
        let client = WaitStopFrameRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertEqual(viewModel.waitStopState, .stopped(reason: .breakpoint(address: 0x1000_0010)))

        await viewModel.continueExecution()

        // The recording client returns a paused snapshot, so the machine resolves
        // back to stopped (the transport await already collapsed the wait).
        XCTAssertEqual(client.continueCallCount, 1)
        XCTAssertFalse(viewModel.isWaitingForStop)
        if case .stopped = viewModel.waitStopState {} else {
            XCTFail("After a continue that stops again, the wait state should be .stopped.")
        }
    }

    func testViewModelContinueSurfacesExitInWaitState() async {
        let client = WaitStopFrameRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        client.continueResult = DebuggerSessionSnapshot(
            processState: .exited(code: 0),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Exited.",
            backendState: .ready(adapterName: "WaitStop Recording LLDB")
        )
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.continueExecution()

        XCTAssertEqual(viewModel.waitStopState, .exited(code: 0))
        XCTAssertTrue(viewModel.waitStopState.isTerminated)
    }

    // MARK: - Live transport (frame select through the session)

    func testLiveCommandSessionSelectsFrameThroughTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = WaitStopFrameFakeTransport(responses: [
            .empty,                  // settings set use-color false
            .empty,                  // target create
            .launchStoppedAtEntry,   // process launch --stop-at-entry
            .statusStopped,          // process status
            .backtrace,              // thread backtrace (stopped refresh)
            .registers,              // register read
            .stackMemory,            // memory read
            // frame select 1 + register read + frame variable
            .empty,
            .registers,
            .frameVariables
        ])
        let runner = WaitStopFrameFakeRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeWaitStopProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        XCTAssertEqual(launched.processState, .paused(processID: 222, reason: .unknown("Stopped at entry")))
        XCTAssertFalse(launched.frames.isEmpty)

        let afterSelect = try await client.selectFrame(
            DebuggerFrameSelectionRequest(index: 0),
            from: launched
        )
        XCTAssertTrue(afterSelect.statusMessage.hasPrefix("Selected frame #0"))
        XCTAssertEqual(
            afterSelect.lastCommandRun?.commandDisplay,
            "frame select 0; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); frame variable"
        )

        XCTAssertEqual(transport.sentCommands.suffix(3), [
            "frame select 0",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "frame variable"
        ])
    }

    func testLiveCommandSessionRejectsFrameSelectWhenNotPaused() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = WaitStopFrameFakeTransport(responses: [])
        let runner = WaitStopFrameFakeRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeWaitStopProof",
            liveSessionFactory: { transport }
        ))

        let running = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "Xcode LLDB Live")
        )

        do {
            _ = try await client.selectFrame(DebuggerFrameSelectionRequest(index: 0), from: running)
            XCTFail("Frame selection should be rejected when not paused.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Frame selection requires a paused live debug process."))
        }
        XCTAssertTrue(transport.sentCommands.isEmpty)
    }

    // MARK: - Shared fixtures

    private static var twoFrames: [DebuggerFrameSummary] {
        [
            DebuggerFrameSummary(index: 0, address: 0x1000_0010, functionName: "callee", moduleName: "echo", sourceLocation: nil),
            DebuggerFrameSummary(index: 1, address: 0x1000_0100, functionName: "caller", moduleName: "echo", sourceLocation: nil)
        ]
    }

    private static var pausedLiveSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0010)],
            threads: [],
            frames: twoFrames,
            registers: [DebuggerRegisterSummary(name: "x0", value: "0x000000000000002a", role: nil)],
            memoryRegions: [],
            statusMessage: "Paused at breakpoint.",
            backendState: .connected(processID: 222, adapterName: "WaitStop Recording LLDB")
        )
    }
}

// MARK: - Self-contained test doubles

@MainActor
private final class WaitStopFrameRecordingDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var selectFrameCallCount = 0
    private(set) var continueCallCount = 0
    private(set) var lastFrameSelection: DebuggerFrameSelectionRequest?
    var continueResult: DebuggerSessionSnapshot?

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "WaitStop Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        continueCallCount += 1
        return continueResult ?? snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        DebuggerExpressionResult(value: "0", type: nil)
    }
    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        selectFrameCallCount += 1
        lastFrameSelection = request
        var copy = snapshot
        copy.statusMessage = "Selected frame #\(request.index)."
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

private final class WaitStopFrameFakeRunner: DebuggerProcessRunning {
    private let result: DebuggerSubprocessResult
    init(result: DebuggerSubprocessResult) { self.result = result }
    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult { result }
}

private final class WaitStopFrameFakeTransport: DebuggerLLDBCommandSessionTransport {
    private var responses: [DebuggerLLDBCommandResponse]
    private(set) var sentCommands: [String] = []
    private(set) var stopCallCount = 0

    init(responses: [DebuggerLLDBCommandResponse]) {
        self.responses = responses
    }

    func start(_ command: DebuggerExternalCommand) throws {}

    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse {
        sentCommands.append(command)
        guard !responses.isEmpty else {
            throw DebuggerLLDBCommandSessionError.writeFailed("WaitStopFrame fake transport has no queued response.")
        }
        var response = responses.removeFirst()
        response.command = command
        return response
    }

    func stop() { stopCallCount += 1 }
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
        DebuggerLLDBCommandResponse(command: "process status", standardOutput: "Process 222 stopped")
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
                  x0 = 0x000000000000002a
            """
        )
    }

    static var stackMemory: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory read --format x --size 1 --count 64 $sp",
            standardOutput: "0x000000016fdff200: 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00"
        )
    }

    static var frameVariables: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "frame variable",
            standardOutput: "(int) argc = 1"
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

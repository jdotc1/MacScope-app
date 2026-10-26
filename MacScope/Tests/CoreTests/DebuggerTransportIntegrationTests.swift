import XCTest
@testable import MacScope

final class DebuggerTransportIntegrationTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!
    )

    func testLegacySnapshotInitializerRetainsNilTransportMetadataDefaults() {
        let legacy = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .step),
            breakpoints: [DebuggerBreakpoint(address: 0x1000)],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 42, adapterName: "Legacy")
        )

        XCTAssertNil(legacy.transportSessionCoordinate)
        XCTAssertNil(legacy.transportStopCoordinate)
        XCTAssertNil(legacy.transportEventSequence)
        XCTAssertNil(legacy.transportDiagnostic)
        XCTAssertNil(legacy.transportTargetDisposition)
        XCTAssertTrue(legacy.variableScopes.isEmpty)
        XCTAssertNil(DebuggerSessionSnapshot.empty.transportSessionCoordinate)
    }

    func testPausedReducerStateProjectsExistingLiveSnapshotBehaviorAndCoordinates() {
        var state = makeState()
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 4)
        state.stopRevision = DebuggerStopRevision(rawValue: 2)
        state.lastMintedStopRevision = DebuggerStopRevision(rawValue: 2)
        state.lastAcceptedEventSequence = DebuggerEventSequence(rawValue: 9)
        state.processPhase = .stopped(
            processID: 321,
            reason: .breakpoint(address: 0x1000_0040)
        )
        state.observedProcessID = 321
        state.targetDisposition = .stopped(processID: 321)
        state.breakpoints = [
            DebuggerTransportBreakpoint(
                address: 0x1000_0040,
                isEnabled: true,
                condition: "x0 == 1",
                hitCount: 3,
                ignoreCount: 1,
                backendIdentifier: 7
            )
        ]
        state.stoppedData = DebuggerStoppedData(
            threads: .available([
                DebuggerStoppedThread(
                    identifier: 1,
                    queueName: "main",
                    stopReason: .breakpoint(address: 0x1000_0040),
                    isSelected: false,
                    topFrameAddress: 0x1000_0040,
                    topFrameFunctionName: "main"
                )
            ]),
            frames: .available([
                DebuggerStoppedFrame(
                    identifier: 0,
                    address: 0x1000_0040,
                    functionName: "main",
                    moduleName: "Fixture",
                    sourceLocation: "main.c:12"
                )
            ]),
            registers: .available([
                DebuggerStoppedRegister(
                    name: "pc",
                    value: "0x100000040",
                    role: "program counter",
                    group: .generalPurpose
                )
            ]),
            memoryPreviews: .available([
                DebuggerStoppedMemoryPreview(
                    address: 0x16FF_F0000,
                    bytes: [0xAA, 0xBB, 0xCC],
                    label: "Stack"
                )
            ]),
            variables: .unavailable,
            selectedThreadID: 1,
            selectedFrameID: 0,
            currentProgramCounter: 0x1000_0040
        )

        let snapshot = DebuggerTransportSnapshotProjector.project(
            state,
            adapterName: "Persistent CLI",
            executableName: "Fixture"
        )

        XCTAssertEqual(
            snapshot.processState,
            .paused(processID: 321, reason: .breakpoint(address: 0x1000_0040))
        )
        XCTAssertEqual(
            snapshot.backendState,
            .connected(processID: 321, adapterName: "Persistent CLI")
        )
        XCTAssertTrue(snapshot.hasLiveProcessSession)
        XCTAssertTrue(snapshot.canRefreshStoppedSnapshot)
        XCTAssertEqual(snapshot.liveProgramCounter, 0x1000_0040)
        XCTAssertEqual(snapshot.breakpoints, [
            DebuggerBreakpoint(
                address: 0x1000_0040,
                isEnabled: true,
                condition: "x0 == 1",
                hitCount: 3,
                ignoreCount: 1
            )
        ])
        XCTAssertEqual(snapshot.threads.first?.index, 1)
        XCTAssertEqual(snapshot.threads.first?.isSelected, true)
        XCTAssertEqual(snapshot.frames.first?.functionName, "main")
        XCTAssertEqual(snapshot.registers.first?.group, .generalPurpose)
        XCTAssertEqual(snapshot.memoryRegions.first?.previewBytes, [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(snapshot.memoryRegions.first?.byteCount, 3)
        XCTAssertNil(snapshot.lastCommandRun)
        XCTAssertEqual(snapshot.transportSessionCoordinate, state.sessionCoordinate)
        XCTAssertEqual(snapshot.transportStopCoordinate, state.stopCoordinate)
        XCTAssertEqual(snapshot.transportEventSequence, DebuggerEventSequence(rawValue: 9))
        XCTAssertNil(snapshot.transportDiagnostic)
        XCTAssertEqual(snapshot.transportTargetDisposition, .stopped(processID: 321))
    }

    func testRunningReducerStateProjectsNoStopScopedData() {
        var state = makeState()
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 2)
        state.lastAcceptedEventSequence = DebuggerEventSequence(rawValue: 5)
        state.processPhase = .running(processID: 222)
        state.observedProcessID = 222
        state.targetDisposition = .running(processID: 222)
        state.stopRevision = nil
        state.stoppedData = nil

        let snapshot = DebuggerTransportSnapshotProjector.project(
            state,
            adapterName: "Persistent CLI",
            executableName: "Runner"
        )

        XCTAssertEqual(snapshot.processState, .running(processID: 222, executableName: "Runner"))
        XCTAssertEqual(
            snapshot.backendState,
            .connected(processID: 222, adapterName: "Persistent CLI")
        )
        XCTAssertTrue(snapshot.hasLiveProcessSession)
        XCTAssertTrue(snapshot.canPauseLiveProcess)
        XCTAssertFalse(snapshot.canRefreshStoppedSnapshot)
        XCTAssertTrue(snapshot.threads.isEmpty)
        XCTAssertTrue(snapshot.frames.isEmpty)
        XCTAssertTrue(snapshot.registers.isEmpty)
        XCTAssertTrue(snapshot.memoryRegions.isEmpty)
        XCTAssertNil(snapshot.transportStopCoordinate)
        XCTAssertEqual(snapshot.transportTargetDisposition, .running(processID: 222))
    }

    func testExitedReducerStateProjectsTerminalCompatibilityWithoutLiveAuthority() {
        var state = makeState()
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 7)
        state.lastAcceptedEventSequence = DebuggerEventSequence(rawValue: 14)
        state.processPhase = .exited(processID: 111, code: 9)
        state.observedProcessID = 111
        state.targetDisposition = .exited(code: 9)
        state.isInvalidated = true

        let snapshot = DebuggerTransportSnapshotProjector.project(state)

        XCTAssertEqual(snapshot.processState, .exited(code: 9))
        XCTAssertEqual(snapshot.backendState, .ready(adapterName: "Xcode LLDB CLI"))
        XCTAssertFalse(snapshot.hasLiveProcessSession)
        XCTAssertEqual(snapshot.statusMessage, "Process exited with code 9.")
        XCTAssertEqual(snapshot.transportSessionCoordinate, state.sessionCoordinate)
        XCTAssertNil(snapshot.transportStopCoordinate)
        XCTAssertEqual(snapshot.transportEventSequence, DebuggerEventSequence(rawValue: 14))
        XCTAssertEqual(snapshot.transportTargetDisposition, .exited(code: 9))
    }

    func testInvalidatedReducerStateProjectsBoundedDiagnosticAndUnknownDisposition() {
        let diagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: "adapter EOF after request",
            operation: .continue,
            targetDisposition: .unknown
        )
        var state = makeState()
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 3)
        state.lastAcceptedEventSequence = DebuggerEventSequence(rawValue: 8)
        state.processPhase = .invalidated
        state.observedProcessID = 456
        state.lastDiagnostic = diagnostic
        state.targetDisposition = .unknown
        state.isInvalidated = true

        let snapshot = DebuggerTransportSnapshotProjector.project(state)
        let expectedMessage = "Continue: adapter EOF after request"

        XCTAssertEqual(snapshot.processState, .unavailable(reason: expectedMessage))
        XCTAssertEqual(snapshot.backendState, .failed(reason: expectedMessage))
        XCTAssertEqual(snapshot.statusMessage, expectedMessage)
        XCTAssertFalse(snapshot.hasLiveProcessSession)
        XCTAssertEqual(snapshot.transportSessionCoordinate, state.sessionCoordinate)
        XCTAssertNil(snapshot.transportStopCoordinate)
        XCTAssertEqual(snapshot.transportEventSequence, DebuggerEventSequence(rawValue: 8))
        XCTAssertEqual(snapshot.transportDiagnostic, diagnostic)
        XCTAssertLessThanOrEqual(
            snapshot.transportDiagnostic?.preview.utf8.count ?? .max,
            DebuggerDiagnostic.maximumPreviewByteCount
        )
        XCTAssertEqual(snapshot.transportTargetDisposition, .unknown)
        XCTAssertNil(snapshot.lastCommandRun)
    }

    func testUnavailableStoppedCollectionsProjectAsEmptyCurrentStopData() {
        var state = makeState()
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 1)
        state.stopRevision = DebuggerStopRevision(rawValue: 1)
        state.lastMintedStopRevision = DebuggerStopRevision(rawValue: 1)
        state.processPhase = .stopped(processID: 77, reason: .unknown("Stopped"))
        state.observedProcessID = 77
        state.targetDisposition = .stopped(processID: 77)
        state.stoppedData = .unavailable

        let snapshot = DebuggerTransportSnapshotProjector.project(state)

        XCTAssertEqual(snapshot.processState, .paused(processID: 77, reason: .unknown("Stopped")))
        XCTAssertTrue(snapshot.threads.isEmpty)
        XCTAssertTrue(snapshot.frames.isEmpty)
        XCTAssertTrue(snapshot.registers.isEmpty)
        XCTAssertTrue(snapshot.memoryRegions.isEmpty)
        XCTAssertNil(snapshot.liveProgramCounter)
        XCTAssertEqual(snapshot.transportStopCoordinate, state.stopCoordinate)
    }

    private func makeState() -> DebuggerReducerState {
        DebuggerReducerState(
            epoch: epoch,
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            )
        )
    }
}

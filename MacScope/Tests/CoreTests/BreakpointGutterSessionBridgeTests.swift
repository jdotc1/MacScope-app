import XCTest
@testable import MacScope

/// Tests for the editor-gutter ↔ debugger-session breakpoint bridge (Tier 1.4).
///
/// The bug these guard against: the editor gutter's breakpoint set
/// (`snapshot.instructions[].hasBreakpoint`, toggled by `WorkspaceStore.toggleBreakpoint`)
/// was disconnected from the debugger session (`DebuggerSessionSnapshot.breakpoints`,
/// the only source of launch `initialBreakpoints`), so gutter breakpoints never
/// reached LLDB at launch. The bridge makes the session's breakpoint set derive
/// from the gutter set, flowing gutter -> session -> launch.
@MainActor
final class BreakpointGutterSessionBridgeTests: XCTestCase {

    // MARK: - WorkspaceStore gutter accessor

    func testGutterBreakpointAddressesReflectToggledRows() {
        let store = makeStore(addresses: [0x1000, 0x1004, 0x1008])

        XCTAssertEqual(store.gutterBreakpointAddresses, [])

        store.toggleBreakpoint(0x1008)
        store.toggleBreakpoint(0x1000)

        // Sorted, regardless of toggle order.
        XCTAssertEqual(store.gutterBreakpointAddresses, [0x1000, 0x1008])

        store.toggleBreakpoint(0x1000)
        XCTAssertEqual(store.gutterBreakpointAddresses, [0x1008])
    }

    // MARK: - Gutter -> session -> launch initialBreakpoints

    func testApplyingGutterBreakpointsStaysLocalAndLaunchSendsNoStaticAddresses() async throws {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        // Gutter toggles two breakpoints; the bridge feeds the sorted set in.
        await viewModel.applyGutterBreakpoints([0x1000_0030, 0x1000_0010])

        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x1000_0010, 0x1000_0030])

        let configuration = viewModel.importedLaunchConfiguration(executablePath: "/tmp/Fixture")
        await viewModel.launch(configuration: configuration)

        XCTAssertTrue(client.receivedLaunchConfiguration?.initialBreakpoints.isEmpty == true)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x1000_0010, 0x1000_0030])
    }

    func testTogglingGutterBreakpointOffRemovesItFromSession() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.applyGutterBreakpoints([0x2000, 0x2004])
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x2000, 0x2004])

        // Gutter clears 0x2000; bridge re-applies the surviving set.
        await viewModel.applyGutterBreakpoints([0x2004])
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x2004])

        // Clearing the last gutter breakpoint empties the session set.
        await viewModel.applyGutterBreakpoints([])
        XCTAssertTrue(viewModel.session.breakpoints.isEmpty)
    }

    func testReconcilingGutterBreakpointsRemainsLocalWithoutBackendBinding() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.applyGutterBreakpoints([0x3000])
        await viewModel.applyGutterBreakpoints([0x3000, 0x3008])

        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x3000, 0x3008])
        XCTAssertEqual(client.replaceBreakpointsCallCount, 0)
    }

    // MARK: - End-to-end: gutter set reaches LLDB launch

    func testGutterBreakpointSetDrivesLaunchInitialBreakpoints() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = temporaryDirectory.appendingPathComponent("FixtureTool", isDirectory: false)
        try writeExecutableFixture(to: executableURL)

        let binary = BinaryImage(
            id: UUID(),
            name: "FixtureTool",
            path: executableURL.path,
            kind: "Mach-O executable",
            architecture: "arm64"
        )
        let store = WorkspaceStore(
            workspaceName: "Gutter Bridge Fixture",
            snapshot: WorkspaceSnapshot(
                binaries: [binary],
                functions: [],
                instructions: [
                    instruction(at: 0x4000),
                    instruction(at: 0x4004),
                    instruction(at: 0x4008)
                ],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine()
        )

        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.bindWorkspaceLaunchTarget(try XCTUnwrap(store.debuggerLaunchTargetDescriptor))

        // User clicks two gutter breakpoints; the EditorSurfaceView bridge feeds
        // the store's gutter set into the view model.
        store.toggleBreakpoint(0x4008)
        store.toggleBreakpoint(0x4000)
        await viewModel.applyGutterBreakpoints(store.gutterBreakpointAddresses)

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.receivedLaunchConfiguration?.executablePath, executableURL.path)
        XCTAssertTrue(client.receivedLaunchConfiguration?.initialBreakpoints.isEmpty == true)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x4000, 0x4008])
        XCTAssertNil(viewModel.lastError)
    }

    // MARK: - Live process push

    func testApplyingGutterBreakpointsStaysLocalWhenLiveProcessAttached() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        // Launch puts the session into a live (.connected/.paused) state.
        await viewModel.launch(configuration: viewModel.importedLaunchConfiguration(executablePath: "/tmp/Fixture"))
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)

        await viewModel.applyGutterBreakpoints([0x5000, 0x5008])

        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x5000, 0x5008])
        XCTAssertEqual(client.replaceBreakpointsCallCount, 0)
    }

    func testApplyingGutterBreakpointsLeavesAttachPolicyUntouched() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.applyGutterBreakpoints([0x6000])

        // The dedicated local-process attach surface must remain governed by the
        // signed-target policy; the gutter bridge only flows launch breakpoints
        // and must not reintroduce the removed legacy inline PID picker row.
        let picker = viewModel.targetPickerSnapshot
        XCTAssertFalse(picker.pidTarget.selectionDescriptor.policy.isEnabled)
        XCTAssertEqual(picker.rows.map(\.kind), [.importedTarget])
    }

    // MARK: - Helpers

    private func makeStore(addresses: [UInt64]) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Gutter Bridge",
            snapshot: WorkspaceSnapshot(
                binaries: [
                    BinaryImage(
                        id: UUID(),
                        name: "Gutter Bridge Fixture",
                        path: "/bin/ls",
                        kind: "Mach-O executable",
                        architecture: "arm64"
                    )
                ],
                functions: [],
                instructions: addresses.map { instruction(at: $0) },
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine()
        )
    }

    private func instruction(at address: UInt64) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: "nop",
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScopeGutterBridge-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutableFixture(to url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

/// A launch-capturing debugger client mirroring the one in DebuggerCoreTests, kept
/// local to this stream's test file so the two files never collide on a shared
/// fixture. Supports execution control and launches into a live session so the
/// gutter bridge's "push to backend when live" path is exercisable.
private final class CapturingLaunchDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Capturing LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        backendAvailability: .ready(adapterName: "Capturing LLDB", details: "Capturing LLDB is available."),
        launchSupport: .supported,
        attachSupport: .unsupported(reason: "Attach is not enabled in this test client."),
        executionControlSupport: .supported
    )

    private(set) var receivedLaunchConfiguration: DebuggerLaunchConfiguration?
    private(set) var replaceBreakpointsCallCount = 0

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Capturing LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        receivedLaunchConfiguration = configuration
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .breakpoint(address: configuration.initialBreakpoints.first?.address ?? 0)),
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused at launch.",
            backendState: .connected(processID: 42, adapterName: "Capturing LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.processState = .exited(code: 9)
        copy.backendState = .ready(adapterName: "Capturing LLDB")
        copy.statusMessage = "Captured terminate."
        return copy
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        replaceBreakpointsCallCount += 1
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        copy.statusMessage = "Captured breakpoint replacement."
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}

/// A launch client whose launch stamps every initial breakpoint with a non-default
/// condition and hit count, so the bridge's metadata-preservation can be proven
/// against a public surface (no private session setters required).
private final class ConditionStampingDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Stamping LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        backendAvailability: .ready(adapterName: "Stamping LLDB", details: "Stamping LLDB is available."),
        launchSupport: .supported,
        attachSupport: .unsupported(reason: "Attach is not enabled in this test client."),
        executionControlSupport: .supported
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Stamping LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        let stamped = configuration.initialBreakpoints.map { breakpoint in
            DebuggerBreakpoint(
                address: breakpoint.address,
                isEnabled: breakpoint.isEnabled,
                condition: "x == 1",
                hitCount: 7,
                ignoreCount: breakpoint.ignoreCount
            )
        }
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 77, reason: .breakpoint(address: stamped.first?.address ?? 0)),
            breakpoints: stamped,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused at launch.",
            backendState: .connected(processID: 77, adapterName: "Stamping LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.processState = .exited(code: 0)
        copy.backendState = .ready(adapterName: "Stamping LLDB")
        return copy
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

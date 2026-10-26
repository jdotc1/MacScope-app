import XCTest
@testable import MacScope

final class DebuggerInspectionModelTests: XCTestCase {
    func testInspectionValuesAreSendableAndHashable() {
        Self.assertSendableAndHashable(DebuggerInspectionTargetDigest.self)
        Self.assertSendableAndHashable(DebuggerThreadIdentity.self)
        Self.assertSendableAndHashable(DebuggerFrameIdentity.self)
        Self.assertSendableAndHashable(DebuggerInspectionCoordinate.self)
    }

    func testCoordinateRequiresFrameOwnedBySelectedThread() throws {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let otherThread = try XCTUnwrap(DebuggerThreadIdentity(index: 2, tid: 0xdef))
        let mismatchedFrame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: otherThread,
            frameIndex: 0,
            programCounter: Self.stoppedAddress,
            canonicalFunctionName: "main"
        ))

        XCTAssertNil(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: mismatchedFrame
        ))
    }

    func testMatchingCoordinateRequiresSameStopAuthorityThreadAndFrame() throws {
        let stop = Self.stop(stopRevision: 7)
        let authority = try Self.authority(processID: 123)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: Self.stoppedAddress,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))

        XCTAssertTrue(coordinate.matches(
            stop: stop,
            targetAuthority: authority,
            selectedThread: thread,
            selectedFrame: frame
        ))

        XCTAssertFalse(coordinate.matches(
            stop: Self.stop(stopRevision: 8),
            targetAuthority: authority,
            selectedThread: thread,
            selectedFrame: frame
        ))
    }

    func testTargetDigestDistinguishesLaunchedAndAttachedAuthority() throws {
        let identity = try Self.identity(processID: 123)
        let launched = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
        let attached = DebuggerSessionTargetAuthority(origin: .attached(identity))

        XCTAssertNotEqual(
            DebuggerInspectionTargetDigest(authority: launched),
            DebuggerInspectionTargetDigest(authority: attached)
        )
    }

    func testFreshnessPolicyRejectsStopDriftBeforePublishingStaleInspection() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(
            DebuggerInspectionFreshnessPolicy.evaluate(
                cached: fixture.coordinate,
                currentStop: Self.stop(stopRevision: 2),
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress))
            ),
            .stale(reason: .stopChanged)
        )
    }

    func testFreshnessPolicyRejectsTargetAuthorityDrift() throws {
        let fixture = try Self.fixture()
        let otherAuthority = try Self.authority(processID: 456, executableSHA256: String(repeating: "b", count: 64))

        XCTAssertEqual(
            DebuggerInspectionFreshnessPolicy.evaluate(
                cached: fixture.coordinate,
                currentStop: fixture.stop,
                currentAuthority: otherAuthority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 456, reason: .breakpoint(address: Self.stoppedAddress))
            ),
            .stale(reason: .targetAuthorityChanged)
        )
    }

    func testFreshnessPolicyRejectsThreadAndFrameDriftSeparately() throws {
        let fixture = try Self.fixture()
        let otherThread = try XCTUnwrap(DebuggerThreadIdentity(index: 2, tid: 0xdef))
        let otherFrame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: fixture.thread,
            frameIndex: 1,
            programCounter: Self.calleeAddress,
            canonicalFunctionName: "callee"
        ))

        XCTAssertEqual(
            DebuggerInspectionFreshnessPolicy.evaluate(
                cached: fixture.coordinate,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: otherThread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress))
            ),
            .stale(reason: .frameThreadMismatch)
        )

        XCTAssertEqual(
            DebuggerInspectionFreshnessPolicy.evaluate(
                cached: fixture.coordinate,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: otherFrame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress))
            ),
            .stale(reason: .frameChanged)
        )
    }

    func testFreshnessPolicyInvalidatesRunningDetachedExitedAndUnavailableProcesses() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(
            Self.evaluate(fixture, processState: .running(processID: 123, executableName: "Fixture")),
            .stale(reason: .processRunning)
        )
        XCTAssertEqual(
            Self.evaluate(fixture, processState: .detaching(processID: 123)),
            .stale(reason: .processDetached)
        )
        XCTAssertEqual(
            Self.evaluate(fixture, processState: .exited(code: 0)),
            .stale(reason: .processExited)
        )
        XCTAssertEqual(
            Self.evaluate(fixture, processState: .notAttached),
            .unavailable(reason: .noLiveSession)
        )
        XCTAssertEqual(
            Self.evaluate(fixture, processState: .unavailable(reason: "transport lost")),
            .failed(reason: "transport lost")
        )
    }

    func testFreshnessPolicyInvalidatesRuntimeAndDebugArtifactEvidenceChanges() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(
            DebuggerInspectionFreshnessPolicy.evaluate(
                cached: fixture.coordinate,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress)),
                runtimeModuleEvidenceChanged: true
            ),
            .stale(reason: .runtimeModuleEvidenceChanged)
        )

        XCTAssertEqual(
            DebuggerInspectionFreshnessPolicy.evaluate(
                cached: fixture.coordinate,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress)),
                debugArtifactEvidenceChanged: true
            ),
            .stale(reason: .debugArtifactEvidenceChanged)
        )
    }

    func testFreshnessPolicyAcceptsExactCurrentCoordinate() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(
            Self.evaluate(fixture, processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress))),
            .fresh(fixture.coordinate)
        )
    }

    @MainActor
    func testViewModelPublishesCurrentInspectionCoordinateForSelectedStoppedFrame() throws {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        let snapshot = Self.stoppedSnapshot(stop: stop, authority: authority)
        let viewModel = DebuggerPanelViewModel(
            client: InspectionStubDebuggerClient(initialSnapshot: snapshot)
        )

        let coordinate = try XCTUnwrap(viewModel.currentInspectionCoordinate)

        XCTAssertEqual(coordinate.stop, stop)
        XCTAssertEqual(
            coordinate.targetDigest,
            DebuggerInspectionTargetDigest(authority: authority)
        )
        XCTAssertEqual(coordinate.thread.index, 2)
        XCTAssertEqual(coordinate.frame.thread.index, 2)
        XCTAssertEqual(coordinate.frame.frameIndex, 0)
        XCTAssertEqual(coordinate.frame.programCounter, Self.stoppedAddress)
    }

    @MainActor
    func testViewModelInspectionCoordinateRequiresExactTransportAuthority() throws {
        var snapshot = Self.stoppedSnapshot(
            stop: Self.stop(),
            authority: try Self.authority(processID: 123)
        )
        snapshot.transportTargetAuthority = nil

        let viewModel = DebuggerPanelViewModel(
            client: InspectionStubDebuggerClient(initialSnapshot: snapshot)
        )

        XCTAssertNil(viewModel.currentInspectionCoordinate)
    }

    @MainActor
    func testViewModelInspectionCoordinateRequiresExplicitSelectedThread() throws {
        var snapshot = Self.stoppedSnapshot(
            stop: Self.stop(),
            authority: try Self.authority(processID: 123)
        )
        snapshot.threads = snapshot.threads.map {
            DebuggerThreadSummary(
                index: $0.index,
                queueName: $0.queueName,
                stopReason: $0.stopReason,
                isSelected: false,
                topFrameAddress: $0.topFrameAddress,
                topFrameFunctionName: $0.topFrameFunctionName
            )
        }

        let viewModel = DebuggerPanelViewModel(
            client: InspectionStubDebuggerClient(initialSnapshot: snapshot)
        )

        XCTAssertNotNil(viewModel.selectedThread)
        XCTAssertNil(viewModel.currentInspectionCoordinate)
    }

    @MainActor
    func testViewModelInspectionCoordinateTracksSelectedFrame() async throws {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        let snapshot = Self.stoppedSnapshot(stop: stop, authority: authority)
        let viewModel = DebuggerPanelViewModel(
            client: InspectionStubDebuggerClient(initialSnapshot: snapshot)
        )

        await viewModel.selectFrame(1)

        let coordinate = try XCTUnwrap(viewModel.currentInspectionCoordinate)
        XCTAssertEqual(coordinate.frame.frameIndex, 1)
        XCTAssertEqual(coordinate.frame.programCounter, Self.calleeAddress)
    }

    @MainActor
    func testViewModelSuppressesDuplicateVariableExpansionAndCollapsesLocally() async throws {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        var initial = Self.stoppedSnapshot(stop: stop, authority: authority)
        let coordinateViewModel = DebuggerPanelViewModel(
            client: InspectionStubDebuggerClient(initialSnapshot: initial)
        )
        let coordinate = try XCTUnwrap(coordinateViewModel.currentInspectionCoordinate)
        let parentComponents = ["locals", "0", "pair"]
        let parentToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: parentComponents
        ))
        let parent = try XCTUnwrap(DebuggerVariableNode(
            id: parentToken,
            name: "pair",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: parentComponents
        ))
        initial.variableScopes = [DebuggerVariableScopeSnapshot(
            coordinate: coordinate,
            scope: .locals,
            nodes: [parent],
            wasTruncated: false
        )]

        let childComponents = parentComponents + ["0", "left"]
        let child = try XCTUnwrap(DebuggerVariableNode(
            id: try XCTUnwrap(DebuggerVariablePathToken(
                coordinate: coordinate,
                components: childComponents
            )),
            name: "left",
            typeName: "Int",
            value: .value("1"),
            childCount: 0,
            pathComponents: childComponents
        ))
        var expanded = initial
        expanded.variableScopes = [DebuggerVariableScopeSnapshot(
            coordinate: coordinate,
            scope: .locals,
            nodes: [try XCTUnwrap(parent.replacingChildren([child]))],
            wasTruncated: false
        )]

        let started = expectation(description: "one structured expansion started")
        let client = InspectionStubDebuggerClient(
            initialSnapshot: initial,
            expansionStarted: started
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let initialPresentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: viewModel.currentInspectionCoordinate,
            selectedFrame: viewModel.selectedFrame,
            variableScopes: viewModel.session.variableScopes
        )
        let row = try XCTUnwrap(initialPresentation.groups.first?.rows.first)

        viewModel.toggleVariableDisclosure(row)
        viewModel.toggleVariableDisclosure(row)
        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(client.expansionCallCount, 1)
        XCTAssertEqual(viewModel.activeVariableExpansionToken, row.id)
        XCTAssertNotNil(viewModel.variableExpansionDisabledReason(for: row))

        client.completeExpansion(with: expanded)
        for _ in 0..<20 where viewModel.activeVariableExpansionToken != nil {
            await Task.yield()
        }
        XCTAssertNil(viewModel.activeVariableExpansionToken)
        XCTAssertEqual(viewModel.session.variableScopes, expanded.variableScopes)

        let loadedPresentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: viewModel.currentInspectionCoordinate,
            selectedFrame: viewModel.selectedFrame,
            variableScopes: viewModel.session.variableScopes,
            collapsedTokens: viewModel.collapsedVariableTokens,
            expansionStates: viewModel.variableExpansionStates,
            activeExpansionToken: viewModel.activeVariableExpansionToken
        )
        let loadedRow = try XCTUnwrap(loadedPresentation.groups.first?.rows.first)
        XCTAssertTrue(loadedRow.isExpanded)
        viewModel.toggleVariableDisclosure(loadedRow)
        XCTAssertTrue(viewModel.collapsedVariableTokens.contains(loadedRow.id))

        let collapsedPresentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: viewModel.currentInspectionCoordinate,
            selectedFrame: viewModel.selectedFrame,
            variableScopes: viewModel.session.variableScopes,
            collapsedTokens: viewModel.collapsedVariableTokens,
            expansionStates: viewModel.variableExpansionStates,
            activeExpansionToken: viewModel.activeVariableExpansionToken
        )
        let collapsedRow = try XCTUnwrap(collapsedPresentation.groups.first?.rows.first)
        XCTAssertTrue(collapsedRow.isCollapsed)
        viewModel.toggleVariableDisclosure(collapsedRow)
        XCTAssertFalse(viewModel.collapsedVariableTokens.contains(collapsedRow.id))
        XCTAssertEqual(client.expansionCallCount, 1)
    }

    @MainActor
    func testVariableExpansionNeverDispatchesFromRetiredPendingOrQueuedRetiredModel() async throws {
        for scenario in ["retired", "pending", "queuedThenRetired"] {
            var snapshot = Self.stoppedSnapshot(stop: Self.stop(), authority: try Self.authority(processID: 123))
            let coordinateModel = DebuggerPanelViewModel(client: InspectionStubDebuggerClient(initialSnapshot: snapshot))
            let coordinate = try XCTUnwrap(coordinateModel.currentInspectionCoordinate)
            let components = ["locals", "0", "pair"]
            let parent = try XCTUnwrap(DebuggerVariableNode(
                id: XCTUnwrap(DebuggerVariablePathToken(coordinate: coordinate, components: components)),
                name: "pair", typeName: "Pair", value: .value("{...}"), childCount: 1,
                pathComponents: components
            ))
            snapshot.variableScopes = [DebuggerVariableScopeSnapshot(
                coordinate: coordinate, scope: .locals, nodes: [parent], wasTruncated: false
            )]
            let client = InspectionStubDebuggerClient(initialSnapshot: snapshot)
            let model = DebuggerPanelViewModel(client: client)
            let presentation = DebuggerVariablesInspectionPresentation(
                inspectionCoordinate: model.currentInspectionCoordinate,
                selectedFrame: model.selectedFrame, variableScopes: snapshot.variableScopes
            )
            let row = try XCTUnwrap(presentation.groups.first?.rows.first)
            XCTAssertNil(model.variableExpansionDisabledReason(for: row))
            var pendingDrain: Task<Void, Never>?
            var drainContinuation: CheckedContinuation<Void, Never>?
            if scenario == "pending" {
                let started = expectation(description: "prior drain held")
                let drain = Task { @MainActor in
                    await withCheckedContinuation { continuation in
                        drainContinuation = continuation
                        started.fulfill()
                    }
                }
                pendingDrain = drain
                await fulfillment(of: [started], timeout: 1)
                model.deferWorkspaceAdmission(until: drain, stillOwned: { true })
                XCTAssertTrue(model.workspaceAdmissionPending)
            } else if scenario == "retired" {
                await model.beginWorkspaceRetirement().value
            }
            if scenario != "queuedThenRetired" {
                XCTAssertNotNil(model.variableExpansionDisabledReason(for: row))
            }
            model.toggleVariableDisclosure(row)
            if scenario == "queuedThenRetired" {
                // Same main-actor turn: revoke before the queued expansion task can start.
                await model.beginWorkspaceRetirement().value
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(client.expansionCallCount, 0, scenario)
            XCTAssertNil(model.activeVariableExpansionToken, scenario)
            XCTAssertNil(model.lastError, scenario)
            XCTAssertEqual(model.session.variableScopes, snapshot.variableScopes, scenario)
            drainContinuation?.resume()
            await pendingDrain?.value
        }
    }

    private static func evaluate(
        _ fixture: Fixture,
        processState: DebuggerProcessState
    ) -> DebuggerInspectionFreshness {
        DebuggerInspectionFreshnessPolicy.evaluate(
            cached: fixture.coordinate,
            currentStop: fixture.stop,
            currentAuthority: fixture.authority,
            currentThread: fixture.thread,
            currentFrame: fixture.frame,
            processState: processState
        )
    }

    private struct Fixture {
        let stop: DebuggerStopCoordinate
        let authority: DebuggerSessionTargetAuthority
        let thread: DebuggerThreadIdentity
        let frame: DebuggerFrameIdentity
        let coordinate: DebuggerInspectionCoordinate
    }

    private static let stoppedAddress: UInt64 = 0x1_0000_1000
    private static let calleeAddress: UInt64 = 0x1_0000_2000

    private static func fixture() throws -> Fixture {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: Self.stoppedAddress,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        return Fixture(
            stop: stop,
            authority: authority,
            thread: thread,
            frame: frame,
            coordinate: coordinate
        )
    }

    private static func stop(stopRevision: UInt64 = 1) -> DebuggerStopCoordinate {
        let epoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
        )
        return DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: stopRevision)
        )
    }

    private static func authority(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerSessionTargetAuthority {
        try DebuggerSessionTargetAuthority(origin: .attached(identity(
            processID: processID,
            executableSHA256: executableSHA256
        )))
    }

    private static func identity(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerLocalProcessIdentity {
        let start = try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42))
        return try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: start,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: UInt64(processID) + 1_000,
            executableByteCount: 4096,
            executableSHA256: executableSHA256,
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
    }

    private static func stoppedSnapshot(
        stop: DebuggerStopCoordinate,
        authority: DebuggerSessionTargetAuthority
    ) -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(
                processID: authority.processID,
                reason: .breakpoint(address: Self.stoppedAddress)
            ),
            breakpoints: [],
            threads: [
                DebuggerThreadSummary(
                    index: 1,
                    queueName: "worker",
                    stopReason: nil,
                    isSelected: false,
                    topFrameAddress: nil,
                    topFrameFunctionName: nil
                ),
                DebuggerThreadSummary(
                    index: 2,
                    queueName: "main",
                    stopReason: .breakpoint(address: Self.stoppedAddress),
                    isSelected: true,
                    topFrameAddress: Self.stoppedAddress,
                    topFrameFunctionName: "main"
                )
            ],
            frames: [
                DebuggerFrameSummary(
                    index: 0,
                    address: Self.stoppedAddress,
                    functionName: "main",
                    moduleName: "Fixture",
                    sourceLocation: nil
                ),
                DebuggerFrameSummary(
                    index: 1,
                    address: Self.calleeAddress,
                    functionName: "callee",
                    moduleName: "Fixture",
                    sourceLocation: nil
                )
            ],
            registers: [],
            memoryRegions: [],
            statusMessage: "Stopped.",
            backendState: .connected(
                processID: authority.processID,
                adapterName: "Inspection Stub LLDB"
            ),
            transportSessionCoordinate: stop.session,
            transportStopCoordinate: stop,
            transportEventSequence: DebuggerEventSequence(rawValue: 1),
            transportTargetDisposition: .stopped(processID: authority.processID),
            transportTargetAuthority: authority
        )
    }

    private static func assertSendableAndHashable<T: Sendable & Hashable>(_ type: T.Type) {}
}

@MainActor
private final class InspectionStubDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Inspection Stub LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    private let initialSnapshot: DebuggerSessionSnapshot
    private let expansionStarted: XCTestExpectation?
    private var expansionContinuation:
        CheckedContinuation<DebuggerSessionSnapshot, any Error>?
    private(set) var expansionCallCount = 0

    init(
        initialSnapshot: DebuggerSessionSnapshot,
        expansionStarted: XCTestExpectation? = nil
    ) {
        self.initialSnapshot = initialSnapshot
        self.expansionStarted = expansionStarted
    }

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(
        _ breakpoints: [DebuggerBreakpoint],
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func expandVariableChildren(
        _ request: DebuggerVariableExpansionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        expansionCallCount += 1
        expansionStarted?.fulfill()
        guard expansionStarted != nil else {
            throw DebuggerClientError.unsupportedOperation("Variable expansion is not configured.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            expansionContinuation = continuation
        }
    }

    func completeExpansion(with snapshot: DebuggerSessionSnapshot) {
        expansionContinuation?.resume(returning: snapshot)
        expansionContinuation = nil
    }
    func selectFrame(
        _ request: DebuggerFrameSelectionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}

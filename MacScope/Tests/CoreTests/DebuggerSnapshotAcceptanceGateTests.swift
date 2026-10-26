import XCTest
@testable import MacScope

@MainActor
final class DebuggerSnapshotAcceptanceGateTests: XCTestCase {
    func testLegacySnapshotsRetainLocalTicketAcceptance() {
        var gate = DebuggerSnapshotAcceptanceGate()
        let legacy = Self.launchingSnapshot(path: "/tmp/legacy")
        let ticket = gate.beginRequest(for: legacy)

        XCTAssertTrue(gate.accept(ticket, currentSnapshot: legacy, candidateSnapshot: legacy))
    }

    func testTypedCandidateRequiresSameEpochForOrdinaryRequest() {
        var gate = DebuggerSnapshotAcceptanceGate()
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(epoch: epoch, lifecycle: 2, stop: 4, event: 8)
        let ticket = gate.beginRequest(for: current)
        let foreign = Self.typedSnapshot(
            epoch: DebuggerSessionEpoch(),
            lifecycle: 3,
            stop: 5,
            event: 9
        )

        XCTAssertFalse(gate.accept(ticket, currentSnapshot: current, candidateSnapshot: foreign))
    }

    func testNewSessionTicketPermitsForeignEpoch() {
        var gate = DebuggerSnapshotAcceptanceGate()
        let current = Self.typedSnapshot(
            epoch: DebuggerSessionEpoch(),
            lifecycle: 7,
            stop: nil,
            event: 12,
            disposition: .exited(code: 0)
        )
        let ticket = gate.beginNewSessionRequest(for: current)
        let replacement = Self.typedSnapshot(
            epoch: DebuggerSessionEpoch(),
            lifecycle: 1,
            stop: 1,
            event: 1
        )

        XCTAssertTrue(gate.accept(ticket, currentSnapshot: current, candidateSnapshot: replacement))
    }

    func testOrdinaryTypedCandidateAcceptsForwardAuthorityInSameEpoch() {
        var gate = DebuggerSnapshotAcceptanceGate()
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(epoch: epoch, lifecycle: 2, stop: 3, event: 5)
        let ticket = gate.beginRequest(for: current)
        let candidate = Self.typedSnapshot(epoch: epoch, lifecycle: 3, stop: 4, event: 6)

        XCTAssertTrue(gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate))
    }

    func testProjectorPublishesReducerRuntimeAndBreakpointBindingAuthority() {
        let reducer = DebuggerSessionReducer(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(attachPolicyReason: "test")
        )

        let snapshot = DebuggerTransportSnapshotProjector.project(reducer.state)

        XCTAssertEqual(
            snapshot.transportRuntimeModuleAuthorityRevision,
            reducer.runtimeModuleInventoryState.authorityRevision
        )
        XCTAssertEqual(
            snapshot.transportRuntimeModuleAuthority,
            reducer.runtimeModuleInventoryState.authority
        )
        XCTAssertEqual(
            snapshot.transportBreakpointBindingAuthorityRevision,
            reducer.breakpointBindingState.authorityRevision
        )
        XCTAssertEqual(
            snapshot.transportBreakpointBindingState,
            reducer.breakpointBindingState
        )
        XCTAssertEqual(
            snapshot.transportBreakpointBindingState?.sessionEpoch,
            snapshot.transportSessionCoordinate?.epoch
        )
        XCTAssertNil(snapshot.runtimeMappingProjection)
    }

    func testBreakpointBindingAuthorityRejectsPartialPairedProjection() {
        let reducer = DebuggerSessionReducer(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(attachPolicyReason: "test")
        )
        let current = DebuggerTransportSnapshotProjector.project(reducer.state)
        var candidate = current
        candidate.transportBreakpointBindingState = nil
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertFalse(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testBreakpointBindingAuthorityRejectsForeignEmbeddedSessionEpoch() {
        let reducer = DebuggerSessionReducer(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(attachPolicyReason: "test")
        )
        let foreignReducer = DebuggerSessionReducer(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(attachPolicyReason: "test")
        )
        let current = DebuggerTransportSnapshotProjector.project(reducer.state)
        var candidate = current
        candidate.transportBreakpointBindingAuthorityRevision =
            foreignReducer.breakpointBindingState.authorityRevision
        candidate.transportBreakpointBindingState = foreignReducer.breakpointBindingState
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertFalse(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testSameStopRuntimeModuleAuthorityAcceptsGreaterRevisionAndRejectsLowerRevision() {
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: 7,
            moduleAuthority: .unavailable(.refreshInProgress)
        )

        var forwardGate = DebuggerSnapshotAcceptanceGate()
        let forwardTicket = forwardGate.beginRequest(for: current)
        let forward = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 6,
            moduleAuthorityRevision: 8,
            moduleAuthority: .unavailable(.refreshFailed(.init(redacting: "failed")))
        )
        XCTAssertTrue(
            forwardGate.accept(
                forwardTicket,
                currentSnapshot: current,
                candidateSnapshot: forward
            )
        )

        var regressionGate = DebuggerSnapshotAcceptanceGate()
        let regressionTicket = regressionGate.beginRequest(for: current)
        let regressed = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 6,
            moduleAuthorityRevision: 6,
            moduleAuthority: .unavailable(.newStop)
        )
        XCTAssertFalse(
            regressionGate.accept(
                regressionTicket,
                currentSnapshot: current,
                candidateSnapshot: regressed
            )
        )
    }

    func testExhaustedRuntimeAuthorityAcceptsSameRevisionTerminalTombstone() {
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: .max,
            moduleAuthority: Self.availableRuntimeModuleAuthority(
                epoch: epoch,
                lifecycle: 2,
                stop: 3
            )
        )
        let candidate = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 3,
            stop: nil,
            event: 6,
            disposition: .exited(code: 0),
            moduleAuthorityRevision: .max,
            moduleAuthority: .unavailable(.terminal)
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertTrue(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testExhaustedRuntimeAuthorityAcceptsSameRevisionSessionInvalidationTombstone() {
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: .max,
            moduleAuthority: Self.availableRuntimeModuleAuthority(
                epoch: epoch,
                lifecycle: 2,
                stop: 3
            )
        )
        let candidate = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: nil,
            event: 6,
            disposition: .unknown,
            moduleAuthorityRevision: .max,
            moduleAuthority: .unavailable(.sessionInvalidated)
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertTrue(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testSameRevisionRuntimeAuthorityRejectsUnsafeChanges() {
        let epoch = DebuggerSessionEpoch()
        let currentAvailable = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: .max,
            moduleAuthority: Self.availableRuntimeModuleAuthority(
                epoch: epoch,
                lifecycle: 2,
                stop: 3
            )
        )
        let nonLifecycleTombstone = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 6,
            moduleAuthorityRevision: .max,
            moduleAuthority: .unavailable(.refreshInProgress)
        )
        var tombstoneGate = DebuggerSnapshotAcceptanceGate()
        let tombstoneTicket = tombstoneGate.beginRequest(for: currentAvailable)
        XCTAssertFalse(
            tombstoneGate.accept(
                tombstoneTicket,
                currentSnapshot: currentAvailable,
                candidateSnapshot: nonLifecycleTombstone
            )
        )

        let currentUnavailable = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: .max,
            moduleAuthority: .unavailable(.newStop)
        )
        let resurrectedAvailable = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 3,
            stop: 4,
            event: 6,
            moduleAuthorityRevision: .max,
            moduleAuthority: Self.availableRuntimeModuleAuthority(
                epoch: epoch,
                lifecycle: 3,
                stop: 4
            )
        )
        var resurrectionGate = DebuggerSnapshotAcceptanceGate()
        let resurrectionTicket = resurrectionGate.beginRequest(for: currentUnavailable)
        XCTAssertFalse(
            resurrectionGate.accept(
                resurrectionTicket,
                currentSnapshot: currentUnavailable,
                candidateSnapshot: resurrectedAvailable
            )
        )
    }

    func testTypedRuntimeModuleAuthorityCannotBeErasedByLegacyNilAtSameStop() {
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: 7,
            moduleAuthority: .unavailable(.refreshInProgress)
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)
        let legacyModuleAuthority = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 6
        )

        XCTAssertFalse(
            gate.accept(
                ticket,
                currentSnapshot: current,
                candidateSnapshot: legacyModuleAuthority
            )
        )
    }

    func testDerivedProjectionRefreshDoesNotInvalidateTransportTicket() {
        let epoch = DebuggerSessionEpoch()
        var current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 2,
            stop: 3,
            event: 5,
            moduleAuthorityRevision: 7,
            moduleAuthority: .unavailable(.refreshInProgress)
        )
        current.runtimeMappingProjection = Self.emptyProjection(
            snapshot: current,
            authorityRevision: 7,
            inventoryRevision: 2,
            catalogRevision: 10
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)
        var refreshedProjection = current
        refreshedProjection.runtimeMappingProjection = Self.emptyProjection(
            snapshot: current,
            authorityRevision: 7,
            inventoryRevision: 2,
            catalogRevision: 11
        )

        XCTAssertTrue(gate.isCurrent(ticket, currentSnapshot: refreshedProjection))
    }

    func testTypedCandidateRejectsRegressedEventLifecycleAndStopCoordinates() {
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(epoch: epoch, lifecycle: 3, stop: 5, event: 10)

        var eventGate = DebuggerSnapshotAcceptanceGate()
        let eventTicket = eventGate.beginRequest(for: current)
        let staleEvent = Self.typedSnapshot(epoch: epoch, lifecycle: 3, stop: 5, event: 9)
        XCTAssertFalse(
            eventGate.accept(eventTicket, currentSnapshot: current, candidateSnapshot: staleEvent)
        )

        var lifecycleGate = DebuggerSnapshotAcceptanceGate()
        let lifecycleTicket = lifecycleGate.beginRequest(for: current)
        let staleLifecycle = Self.typedSnapshot(epoch: epoch, lifecycle: 2, stop: 6, event: 11)
        XCTAssertFalse(
            lifecycleGate.accept(
                lifecycleTicket,
                currentSnapshot: current,
                candidateSnapshot: staleLifecycle
            )
        )

        var stopGate = DebuggerSnapshotAcceptanceGate()
        let stopTicket = stopGate.beginRequest(for: current)
        let staleStop = Self.typedSnapshot(epoch: epoch, lifecycle: 3, stop: 4, event: 11)
        XCTAssertFalse(
            stopGate.accept(stopTicket, currentSnapshot: current, candidateSnapshot: staleStop)
        )
    }

    func testTypedAuthorityCannotDowngradeToLegacyOrAcceptPartialMetadata() {
        let epoch = DebuggerSessionEpoch()
        let current = Self.typedSnapshot(epoch: epoch, lifecycle: 1, stop: 1, event: 1)

        var downgradeGate = DebuggerSnapshotAcceptanceGate()
        let downgradeTicket = downgradeGate.beginRequest(for: current)
        XCTAssertFalse(
            downgradeGate.accept(
                downgradeTicket,
                currentSnapshot: current,
                candidateSnapshot: Self.launchingSnapshot(path: "/tmp/legacy")
            )
        )

        var partialGate = DebuggerSnapshotAcceptanceGate()
        let legacy = Self.launchingSnapshot(path: "/tmp/legacy")
        let partialTicket = partialGate.beginNewSessionRequest(for: legacy)
        var partial = legacy
        partial.transportSessionCoordinate = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: .initial
        )
        XCTAssertFalse(
            partialGate.accept(
                partialTicket,
                currentSnapshot: legacy,
                candidateSnapshot: partial
            )
        )
    }

    func testTerminalTypedAuthorityCannotBeResurrectedWithoutNewSessionTicket() {
        for disposition in [
            DebuggerTargetDisposition.exited(code: 0),
            .detached,
            .terminated,
            .unknown,
        ] {
            var gate = DebuggerSnapshotAcceptanceGate()
            let epoch = DebuggerSessionEpoch()
            let terminal = Self.typedSnapshot(
                epoch: epoch,
                lifecycle: 4,
                stop: nil,
                event: 6,
                disposition: disposition
            )
            let ticket = gate.beginRequest(for: terminal)
            let resurrected = Self.typedSnapshot(
                epoch: epoch,
                lifecycle: 5,
                stop: 7,
                event: 7
            )

            XCTAssertFalse(
                gate.accept(ticket, currentSnapshot: terminal, candidateSnapshot: resurrected),
                "Unexpected resurrection from \(disposition)."
            )
        }
    }

    func testDetachingAuthorityAcceptsNewerDetachedProof() {
        let epoch = DebuggerSessionEpoch()
        let authority = Self.attachedAuthority(processID: 42, digestByte: "a")
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 6,
            disposition: .unknown,
            processState: .detaching(processID: 42),
            backendState: .disconnecting(
                processID: 42,
                adapterName: "Acceptance Gate LLDB"
            ),
            targetAuthority: authority
        )
        let candidate = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 7,
            disposition: .detached,
            processState: .notAttached,
            backendState: .ready(adapterName: "Acceptance Gate LLDB"),
            targetAuthority: authority
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertTrue(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testDetachingAuthorityAcceptsNewerExitedProof() {
        let epoch = DebuggerSessionEpoch()
        let authority = Self.attachedAuthority(processID: 42, digestByte: "b")
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 6,
            disposition: .unknown,
            processState: .detaching(processID: 42),
            backendState: .disconnecting(
                processID: 42,
                adapterName: "Acceptance Gate LLDB"
            ),
            targetAuthority: authority
        )
        let candidate = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 7,
            disposition: .exited(code: 0),
            processState: .exited(code: 0),
            backendState: .ready(adapterName: "Acceptance Gate LLDB"),
            targetAuthority: authority
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertTrue(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testInvalidatedUnknownAuthorityRemainsTerminal() {
        let epoch = DebuggerSessionEpoch()
        let authority = Self.attachedAuthority(processID: 42, digestByte: "c")
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 6,
            disposition: .unknown,
            processState: .unavailable(reason: "Transport authority invalidated."),
            backendState: .failed(reason: "Transport authority invalidated."),
            targetAuthority: authority
        )
        let candidate = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 5,
            stop: 7,
            event: 7,
            targetAuthority: authority
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertFalse(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testDetachingAuthorityRejectsMismatchedTargetIdentity() {
        let epoch = DebuggerSessionEpoch()
        let currentAuthority = Self.attachedAuthority(processID: 42, digestByte: "d")
        let current = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 6,
            disposition: .unknown,
            processState: .detaching(processID: 42),
            backendState: .disconnecting(
                processID: 42,
                adapterName: "Acceptance Gate LLDB"
            ),
            targetAuthority: currentAuthority
        )
        let candidate = Self.typedSnapshot(
            epoch: epoch,
            lifecycle: 4,
            stop: nil,
            event: 7,
            disposition: .detached,
            processState: .notAttached,
            backendState: .ready(adapterName: "Acceptance Gate LLDB"),
            targetAuthority: Self.attachedAuthority(processID: 42, digestByte: "e")
        )
        var gate = DebuggerSnapshotAcceptanceGate()
        let ticket = gate.beginRequest(for: current)

        XCTAssertFalse(
            gate.accept(ticket, currentSnapshot: current, candidateSnapshot: candidate)
        )
    }

    func testOlderLaunchCoordinateCannotSupersedeNewerSessionGeneration() {
        var gate = DebuggerSnapshotAcceptanceGate()
        let firstLaunching = Self.launchingSnapshot(path: "/tmp/first")
        let first = gate.beginNewSessionRequest(for: firstLaunching)
        let secondLaunching = Self.launchingSnapshot(path: "/tmp/second")
        let second = gate.beginNewSessionRequest(for: secondLaunching)

        XCTAssertFalse(gate.accept(first, currentSnapshot: secondLaunching))
        XCTAssertTrue(gate.accept(second, currentSnapshot: secondLaunching))
    }

    func testLateRefreshCannotResurrectSessionAfterNewerTerminate() async {
        let refreshStarted = expectation(description: "older refresh suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .refresh,
            operationStarted: refreshStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        let stalePausedSnapshot = viewModel.session

        let refresh = Task { @MainActor in
            await viewModel.refreshSnapshot()
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        await viewModel.terminate()
        client.resumeSuspendedOperation(with: .success(stalePausedSnapshot))
        await refresh.value

        XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
        XCTAssertEqual(viewModel.session.backendState, .ready(adapterName: "Acceptance Gate LLDB"))
        XCTAssertEqual(viewModel.waitStopState, .exited(code: 0))
        XCTAssertNil(viewModel.lastError)
    }

    func testLateContinueStopCannotResurrectTerminatedWorkspaceOwner() async throws {
        let continueStarted = expectation(description: "older continue suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .continueExecution,
            operationStarted: continueStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let binary = BinaryImage(
            id: UUID(),
            name: "Fixture",
            path: "/bin/ls",
            kind: "Mach-O executable",
            architecture: "arm64"
        )
        viewModel.reconcileWorkspaceCandidate(
            completeDebuggerWorkspaceInputFixture(
                imageSlot: .primary,
                launchTarget: .importedWorkspaceBinary(binary),
                gutterBreakpointAddresses: [0x1000]
            )
        )
        await viewModel.launchSelectedTarget()
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        var staleStop = viewModel.session
        staleStop.processState = .paused(processID: 42, reason: .step)
        staleStop.statusMessage = "Late old stop."

        let continueExecution = Task { @MainActor in
            await viewModel.continueExecution()
        }
        await fulfillment(of: [continueStarted], timeout: 2)
        await viewModel.terminate()
        client.resumeSuspendedOperation(with: .success(staleStop))
        await continueExecution.value

        XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
        XCTAssertEqual(viewModel.waitStopState, .exited(code: 0))
        XCTAssertNil(viewModel.activeWorkspaceImageSlot)
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
    }

    func testLateFailureCannotOverwriteNewerStoppedSnapshot() async {
        let refreshStarted = expectation(description: "older failing refresh suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .refresh,
            operationStarted: refreshStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        var newerStop = viewModel.session
        newerStop.processState = .paused(processID: 42, reason: .step)
        newerStop.statusMessage = "Newer stopped snapshot."
        client.immediateRefreshResult = newerStop

        let olderRefresh = Task { @MainActor in
            await viewModel.refreshSnapshot()
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        await viewModel.refreshSnapshot()
        client.resumeSuspendedOperation(
            with: .failure(DebuggerClientError.backendFailure("late old refresh failure"))
        )
        await olderRefresh.value

        XCTAssertEqual(viewModel.session.processState, .paused(processID: 42, reason: .step))
        XCTAssertEqual(viewModel.session.statusMessage, "Newer stopped snapshot.")
        XCTAssertEqual(viewModel.waitStopState, .stopped(reason: .step))
        XCTAssertNil(viewModel.lastError)
    }

    func testLocalGutterAuthoringPreservesNewerStoppedSnapshot() async {
        let client = SnapshotAcceptanceGateDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))

        var newerStop = viewModel.session
        newerStop.processState = .paused(processID: 42, reason: .step)
        newerStop.statusMessage = "Newer stopped snapshot."
        client.immediateRefreshResult = newerStop
        await viewModel.refreshSnapshot()

        await viewModel.applyGutterBreakpoints([0x2000])

        XCTAssertEqual(viewModel.session.processState, .paused(processID: 42, reason: .step))
        XCTAssertEqual(viewModel.session.statusMessage, "Newer stopped snapshot.")
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x2000])
        XCTAssertNil(viewModel.lastError)
    }

    func testAcceptedBackendFailureClearsPreviouslyEvaluatedExpression() async {
        let started = expectation(description: "failing refresh suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .refresh, operationStarted: started
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        viewModel.expressionText = "6 * 7"
        await viewModel.evaluate()
        XCTAssertEqual(viewModel.expressionResult?.value, "42")
        let refresh = Task { @MainActor in await viewModel.refreshSnapshot() }
        await fulfillment(of: [started], timeout: 2)
        client.resumeSuspendedOperation(with: .failure(
            DebuggerClientError.backendFailure("accepted backend failure")
        ))
        await refresh.value
        guard case .unavailable = viewModel.session.processState else {
            return XCTFail("An accepted backend failure must retire live process state")
        }
        XCTAssertNil(viewModel.expressionResult)
        XCTAssertEqual(viewModel.expressionText, "6 * 7")
    }

    func testRejectedOlderFailurePreservesNewerExpressionResult() async {
        let started = expectation(description: "old failing refresh suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .refresh, operationStarted: started
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        let refresh = Task { @MainActor in await viewModel.refreshSnapshot() }
        await fulfillment(of: [started], timeout: 2)
        viewModel.expressionText = "6 * 7"
        await viewModel.evaluate()
        XCTAssertEqual(viewModel.expressionResult?.value, "42")
        client.resumeSuspendedOperation(with: .failure(
            DebuggerClientError.backendFailure("obsolete backend failure")
        ))
        await refresh.value
        XCTAssertEqual(viewModel.expressionResult?.value, "42")
        XCTAssertNil(viewModel.lastError)
    }

    func testAcceptedTerminationClearsPreviouslyEvaluatedExpression() async {
        let client = SnapshotAcceptanceGateDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        viewModel.expressionText = "6 * 7"
        await viewModel.evaluate()
        XCTAssertEqual(viewModel.expressionResult?.value, "42")

        await viewModel.terminate()

        XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
        XCTAssertNil(viewModel.expressionResult)
        XCTAssertEqual(viewModel.expressionText, "6 * 7")
    }

    func testAcceptedRefreshClearsPreviouslyEvaluatedExpressionAtSameStop() async {
        let client = SnapshotAcceptanceGateDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        viewModel.expressionText = "6 * 7"
        await viewModel.evaluate()
        XCTAssertEqual(viewModel.expressionResult?.value, "42")
        let stoppedState = viewModel.session.processState
        client.immediateRefreshResult = viewModel.session

        await viewModel.refreshSnapshot()

        XCTAssertEqual(viewModel.session.processState, stoppedState)
        XCTAssertNil(viewModel.expressionResult)
        XCTAssertNil(viewModel.lastError)
    }

    func testRejectedOlderRefreshPreservesNewerExpressionResult() async {
        let refreshStarted = expectation(description: "older refresh suspended before evaluation")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .refresh,
            operationStarted: refreshStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        let oldSnapshot = viewModel.session
        let refresh = Task { @MainActor in
            await viewModel.refreshSnapshot()
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        viewModel.expressionText = "6 * 7"
        await viewModel.evaluate()
        XCTAssertEqual(viewModel.expressionResult?.value, "42")

        client.resumeSuspendedOperation(with: .success(oldSnapshot))
        await refresh.value

        XCTAssertEqual(viewModel.expressionResult, DebuggerExpressionResult(value: "42", type: "int"))
        XCTAssertEqual(viewModel.session.statusMessage, "6 * 7 = (int) 42")
        XCTAssertNil(viewModel.lastError)
    }

    func testExpressionWithAcceptedRefreshPublishesItsFreshResult() async {
        let evaluationStarted = expectation(description: "expression waiting for refreshed snapshot")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .evaluateExpression,
            operationStarted: evaluationStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        var refreshedSnapshot = viewModel.session
        refreshedSnapshot.statusMessage = "Post-expression refresh."
        viewModel.expressionText = "6 * 7"
        let evaluation = Task { @MainActor in
            await viewModel.evaluate()
        }
        await fulfillment(of: [evaluationStarted], timeout: 2)

        client.resumeSuspendedExpression(with: .success(DebuggerExpressionResult(
            value: "42",
            type: "int",
            refreshedSnapshot: refreshedSnapshot
        )))
        await evaluation.value

        XCTAssertEqual(viewModel.expressionResult, DebuggerExpressionResult(value: "42", type: "int"))
        XCTAssertEqual(viewModel.session.statusMessage, "6 * 7 = (int) 42")
        XCTAssertNil(viewModel.lastError)
    }

    func testLateExpressionSuccessCannotOverwriteNewerTermination() async {
        let evaluationStarted = expectation(description: "older expression suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .evaluateExpression,
            operationStarted: evaluationStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        viewModel.expressionText = "6 * 7"

        let evaluation = Task { @MainActor in
            await viewModel.evaluate()
        }
        await fulfillment(of: [evaluationStarted], timeout: 2)
        await viewModel.terminate()
        client.resumeSuspendedExpression(
            with: .success(DebuggerExpressionResult(value: "42", type: "int"))
        )
        await evaluation.value

        XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
        XCTAssertEqual(viewModel.session.statusMessage, "Terminated.")
        XCTAssertNil(viewModel.expressionResult)
        XCTAssertNil(viewModel.lastError)
    }

    func testLateExpressionFailureCannotDegradeNewerStoppedSnapshot() async {
        let evaluationStarted = expectation(description: "older expression suspended")
        let client = SnapshotAcceptanceGateDebuggerClient(
            suspendedOperation: .evaluateExpression,
            operationStarted: evaluationStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        viewModel.expressionText = "6 * 7"

        let evaluation = Task { @MainActor in
            await viewModel.evaluate()
        }
        await fulfillment(of: [evaluationStarted], timeout: 2)
        var newerStop = viewModel.session
        newerStop.processState = .paused(processID: 42, reason: .step)
        newerStop.statusMessage = "Newer stopped snapshot."
        client.immediateRefreshResult = newerStop
        await viewModel.refreshSnapshot()
        client.resumeSuspendedExpression(
            with: .failure(DebuggerClientError.backendFailure("late expression failure"))
        )
        await evaluation.value

        XCTAssertEqual(viewModel.session.processState, .paused(processID: 42, reason: .step))
        XCTAssertEqual(viewModel.session.statusMessage, "Newer stopped snapshot.")
        XCTAssertNil(viewModel.expressionResult)
        XCTAssertNil(viewModel.lastError)
    }

    func testRunObservationPollsSeriallyUntilObservedStop() async {
        let client = SnapshotAcceptanceGateDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        var running = viewModel.session
        running.processState = .running(processID: 42, executableName: "fixture")
        running.statusMessage = "Running."
        var stopped = running
        stopped.processState = .paused(processID: 42, reason: .step)
        stopped.statusMessage = "Observed stop."
        client.immediateContinueResult = running
        client.pollResults = [running, stopped]

        await viewModel.continueExecution()

        XCTAssertEqual(client.pollCallCount, 2)
        XCTAssertEqual(viewModel.session.processState, .paused(processID: 42, reason: .step))
        XCTAssertEqual(viewModel.waitStopState, .stopped(reason: .step))
        XCTAssertNil(viewModel.lastError)
    }

    func testNewerTerminateSupersedesDelayedObservationBeforePollIO() async {
        let client = SnapshotAcceptanceGateDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        var running = viewModel.session
        running.processState = .running(processID: 42, executableName: "fixture")
        running.statusMessage = "Running."
        client.immediateContinueResult = running

        let run = Task { @MainActor in
            await viewModel.continueExecution()
        }
        for _ in 0..<1_000 {
            if case .running = viewModel.session.processState { break }
            await Task.yield()
        }
        guard case .running = viewModel.session.processState else {
            XCTFail("Run result was not installed before the bounded yield loop completed.")
            run.cancel()
            return
        }

        await viewModel.terminate()
        await run.value

        XCTAssertEqual(client.pollCallCount, 0)
        XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
        XCTAssertEqual(viewModel.waitStopState, .exited(code: 0))
    }

    func testPauseReturningRunningContinuesObservationUntilObservedStop() async {
        let client = SnapshotAcceptanceGateDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        await viewModel.launch(configuration: .init(executablePath: "/tmp/fixture"))
        var running = viewModel.session
        running.processState = .running(processID: 42, executableName: "fixture")
        running.statusMessage = "Interrupt requested; target still running."
        var stopped = running
        stopped.processState = .paused(processID: 42, reason: .signal("SIGINT"))
        stopped.statusMessage = "Observed interrupt stop."
        client.immediateContinueResult = running
        client.immediatePauseResult = running
        client.pollResults = [stopped]

        let run = Task { @MainActor in
            await viewModel.continueExecution()
        }
        for _ in 0..<1_000 {
            if case .running = viewModel.session.processState { break }
            await Task.yield()
        }
        guard case .running = viewModel.session.processState else {
            XCTFail("Run result was not installed before the bounded yield loop completed.")
            run.cancel()
            return
        }

        await viewModel.pause()
        await run.value

        XCTAssertEqual(client.pollCallCount, 1)
        XCTAssertEqual(
            viewModel.session.processState,
            .paused(processID: 42, reason: .signal("SIGINT"))
        )
        XCTAssertEqual(viewModel.waitStopState, .stopped(reason: .signal("SIGINT")))
    }

    private static func launchingSnapshot(path: String) -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .launching(targetPath: path),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Launching.",
            backendState: .launching(targetPath: path)
        )
    }

    private static func typedSnapshot(
        epoch: DebuggerSessionEpoch,
        lifecycle: UInt64,
        stop: UInt64?,
        event: UInt64,
        disposition: DebuggerTargetDisposition = .stopped(processID: 42),
        moduleAuthorityRevision: UInt64? = nil,
        moduleAuthority: DebuggerRuntimeModuleAuthority? = nil,
        processState: DebuggerProcessState? = nil,
        backendState: DebuggerBackendSessionState? = nil,
        targetAuthority: DebuggerSessionTargetAuthority? = nil
    ) -> DebuggerSessionSnapshot {
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: lifecycle)
        )
        return DebuggerSessionSnapshot(
            processState: processState ?? Self.processState(for: disposition),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Typed snapshot.",
            backendState: backendState
                ?? .connected(processID: 42, adapterName: "Acceptance Gate LLDB"),
            transportSessionCoordinate: sessionCoordinate,
            transportStopCoordinate: stop.map {
                DebuggerStopCoordinate(
                    session: sessionCoordinate,
                    stopRevision: DebuggerStopRevision(rawValue: $0)
                )
            },
            transportEventSequence: DebuggerEventSequence(rawValue: event),
            transportTargetDisposition: disposition,
            transportTargetAuthority: targetAuthority,
            transportRuntimeModuleAuthorityRevision: moduleAuthorityRevision.map {
                DebuggerRuntimeModuleAuthorityRevision(rawValue: $0)
            },
            transportRuntimeModuleAuthority: moduleAuthority
        )
    }

    private static func attachedAuthority(
        processID: Int32,
        digestByte: Character
    ) -> DebuggerSessionTargetAuthority {
        let identity = DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeAcceptanceGateFixture",
            executableDeviceID: 7,
            executableFileID: UInt64(digestByte.asciiValue!),
            executableByteCount: 4_096,
            executableSHA256: String(repeating: String(digestByte), count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        )!
        return DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    private static func emptyProjection(
        snapshot: DebuggerSessionSnapshot,
        authorityRevision: UInt64,
        inventoryRevision: UInt64,
        catalogRevision: UInt64
    ) -> DebuggerRuntimeMappingProjection {
        DebuggerRuntimeMappingProjection(
            key: DebuggerRuntimeMappingProjectionKey(
                stopCoordinate: snapshot.transportStopCoordinate!,
                observedPID: 42,
                authorityRevision: .init(rawValue: authorityRevision),
                inventoryRevision: .init(rawValue: inventoryRevision),
                workspaceCatalogRevision: .init(rawValue: catalogRevision)
            ),
            modules: []
        )
    }

    private static func availableRuntimeModuleAuthority(
        epoch: DebuggerSessionEpoch,
        lifecycle: UInt64,
        stop: UInt64
    ) -> DebuggerRuntimeModuleAuthority {
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: lifecycle)
        )
        return .available(
            DebuggerRuntimeModuleInventory(
                revision: DebuggerRuntimeModuleInventoryRevision(rawValue: 1),
                stop: DebuggerStopCoordinate(
                    session: session,
                    stopRevision: DebuggerStopRevision(rawValue: stop)
                ),
                processID: 42,
                observedStopID: 1,
                modules: []
            )
        )
    }

    private static func processState(
        for disposition: DebuggerTargetDisposition
    ) -> DebuggerProcessState {
        switch disposition {
        case .running(let processID):
            return .running(processID: processID, executableName: "fixture")
        case .stopped(let processID):
            return .paused(processID: processID, reason: .step)
        case .exited(let code):
            return .exited(code: code)
        case .notApplicable, .notStarted:
            return .notAttached
        case .detached, .terminated:
            return .exited(code: nil)
        case .unknown:
            return .unavailable(reason: "Transport authority invalidated.")
        }
    }
}

@MainActor
private final class SnapshotAcceptanceGateDebuggerClient: DebuggerClient {
    enum SuspendedOperation: Equatable {
        case refresh
        case continueExecution
        case replaceBreakpoints
        case evaluateExpression
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Acceptance Gate LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    private let suspendedOperation: SuspendedOperation?
    private let operationStarted: XCTestExpectation?
    private var suspensionWasConsumed = false
    private var suspendedContinuation: CheckedContinuation<DebuggerSessionSnapshot, Error>?
    private var suspendedExpressionContinuation:
        CheckedContinuation<DebuggerExpressionResult, Error>?
    var immediateRefreshResult: DebuggerSessionSnapshot?
    var immediateContinueResult: DebuggerSessionSnapshot?
    var immediatePauseResult: DebuggerSessionSnapshot?
    var pollResults: [DebuggerSessionSnapshot] = []
    private(set) var pollCallCount = 0

    init(
        suspendedOperation: SuspendedOperation? = nil,
        operationStarted: XCTestExpectation? = nil
    ) {
        self.suspendedOperation = suspendedOperation
        self.operationStarted = operationStarted
    }

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Acceptance Gate LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .breakpoint(address: 0x1000)),
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused at launch.",
            backendState: .connected(processID: 42, adapterName: "Acceptance Gate LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if shouldSuspend(.continueExecution) {
            return try await suspendOperation()
        }
        return immediateContinueResult ?? snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        immediatePauseResult ?? snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.processState = .exited(code: 0)
        copy.backendState = .ready(adapterName: "Acceptance Gate LLDB")
        copy.statusMessage = "Terminated."
        return copy
    }

    func replaceBreakpoints(
        _ breakpoints: [DebuggerBreakpoint],
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        if shouldSuspend(.replaceBreakpoints) {
            return try await suspendOperation()
        }
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        if shouldSuspend(.refresh) {
            return try await suspendOperation()
        }
        return immediateRefreshResult ?? snapshot
    }

    func pollProcessStatus(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        pollCallCount += 1
        guard !pollResults.isEmpty else { return snapshot }
        return pollResults.removeFirst()
    }

    func evaluateExpression(
        _ request: DebuggerExpressionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerExpressionResult {
        if shouldSuspend(.evaluateExpression) {
            operationStarted?.fulfill()
            return try await withCheckedThrowingContinuation { continuation in
                suspendedExpressionContinuation = continuation
            }
        }
        return DebuggerExpressionResult(value: "42", type: "int")
    }

    func resumeSuspendedOperation(with result: Result<DebuggerSessionSnapshot, Error>) {
        guard let continuation = suspendedContinuation else {
            XCTFail("No debugger operation is suspended.")
            return
        }
        suspendedContinuation = nil
        continuation.resume(with: result)
    }

    func resumeSuspendedExpression(
        with result: Result<DebuggerExpressionResult, Error>
    ) {
        guard let continuation = suspendedExpressionContinuation else {
            XCTFail("No expression evaluation is suspended.")
            return
        }
        suspendedExpressionContinuation = nil
        continuation.resume(with: result)
    }

    private func shouldSuspend(_ operation: SuspendedOperation) -> Bool {
        guard !suspensionWasConsumed, suspendedOperation == operation else { return false }
        suspensionWasConsumed = true
        return true
    }

    private func suspendOperation() async throws -> DebuggerSessionSnapshot {
        operationStarted?.fulfill()
        return try await withCheckedThrowingContinuation { continuation in
            suspendedContinuation = continuation
        }
    }
}

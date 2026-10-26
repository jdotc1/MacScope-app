import XCTest
@testable import MacScope

final class DebuggerOriginAwareRecoveryPolicyTests: XCTestCase {
    func testEveryRecoveryReasonTerminatesOnlyAnExactLiveLaunchedAuthority() throws {
        let authority = launchedAuthority(try identity())
        let state = exactStoppedState(authority: authority)

        for reason in DebuggerRecoveryReason.allCases {
            XCTAssertEqual(
                DebuggerOriginAwareRecoveryPolicy(reason: reason).decision(for: state),
                .terminateLaunched(authority),
                "Unexpected launched-target decision for \(reason)"
            )
        }
    }

    func testEveryRecoveryReasonDetachesOnlyAnExactLiveAttachedAuthority() throws {
        let authority = attachedAuthority(try identity())
        let state = exactStoppedState(authority: authority)

        for reason in DebuggerRecoveryReason.allCases {
            XCTAssertEqual(
                DebuggerOriginAwareRecoveryPolicy(reason: reason).decision(for: state),
                .detachAttached(authority),
                "Unexpected attached-target decision for \(reason)"
            )
        }
    }

    func testInvalidatedStateRetiresOwnedTransportAndReobservesLastExactAuthority() throws {
        let authority = attachedAuthority(try identity())
        var state = exactStoppedState(authority: authority)
        state.processPhase = .invalidated
        state.targetDisposition = .unknown
        state.isInvalidated = true

        XCTAssertEqual(
            policy.decision(for: state),
            .retireOwnedTransportAndReobserve(authority)
        )
    }

    func testUnknownDispositionNeverAuthorizesAnAttachedTargetCommand() throws {
        let authority = attachedAuthority(try identity())
        var state = exactStoppedState(authority: authority)
        state.targetDisposition = .unknown

        let decision = policy.decision(for: state)

        XCTAssertEqual(decision, .retireOwnedTransportAndReobserve(authority))
        XCTAssertFalse(decision.authorizesTargetCommand)
        XCTAssertFalse(decision.authorizesAutomaticTermination)
    }

    func testMismatchedLiveIdentityFailsClosedUsingOnlyLastExactAuthorityForReobservation() throws {
        let authority = launchedAuthority(try identity(processID: 800))
        var state = exactStoppedState(authority: authority)
        state.processPhase = .running(processID: 801)
        state.observedProcessID = 801
        state.targetDisposition = .running(processID: 801)

        XCTAssertEqual(
            policy.decision(for: state),
            .retireOwnedTransportAndReobserve(authority)
        )
    }

    func testPendingRequestPreventsASecondAutomaticTargetCommand() throws {
        let authority = launchedAuthority(try identity())
        var state = exactStoppedState(authority: authority)
        let session = state.sessionCoordinate
        state.pendingRequest = DebuggerPendingRequest(
            context: DebuggerRequestContext(
                id: DebuggerRequestID(epoch: session.epoch, sequence: 1),
                operation: .replaceBreakpoints,
                expectedSession: session,
                targetAuthority: authority
            ),
            hasStarted: true
        )

        XCTAssertEqual(
            policy.decision(for: state),
            .retireOwnedTransportAndReobserve(authority)
        )
    }

    func testRunningStateWithStaleStopAuthorityFailsClosed() throws {
        let authority = attachedAuthority(try identity())
        var state = exactRunningState(authority: authority)
        state.stopRevision = DebuggerStopRevision(rawValue: 1)

        XCTAssertEqual(
            policy.decision(for: state),
            .retireOwnedTransportAndReobserve(authority)
        )
    }

    func testStoppedStateWithoutStopAuthorityFailsClosed() throws {
        let authority = attachedAuthority(try identity())
        var state = exactStoppedState(authority: authority)
        state.stopRevision = nil

        XCTAssertEqual(
            policy.decision(for: state),
            .retireOwnedTransportAndReobserve(authority)
        )
    }

    func testCoherentRunningStateUsesExactOriginPolicy() throws {
        let launched = launchedAuthority(try identity(processID: 800))
        let attached = attachedAuthority(try identity(processID: 801))

        XCTAssertEqual(
            policy.decision(for: exactRunningState(authority: launched)),
            .terminateLaunched(launched)
        )
        XCTAssertEqual(
            policy.decision(for: exactRunningState(authority: attached)),
            .detachAttached(attached)
        )
    }

    func testMissingAuthorityFailsClosedWithoutInventingReobservationAuthority() {
        var state = reducerState()
        state.processPhase = .running(processID: 800)
        state.observedProcessID = 800
        state.targetDisposition = .running(processID: 800)

        let decision = policy.decision(for: state)

        XCTAssertEqual(decision, .retireOwnedTransportAndReobserve(nil))
        XCTAssertFalse(decision.authorizesTargetCommand)
        XCTAssertFalse(decision.authorizesAutomaticTermination)
    }

    func testExactNoTargetRetiresIdleTransport() {
        XCTAssertEqual(policy.decision(for: reducerState()), .retireIdleTransport)
    }

    func testProvenTerminalStatesRetireIdleTransport() throws {
        let authority = launchedAuthority(try identity())
        let processID = authority.processID

        var exited = exactStoppedState(authority: authority)
        exited.processPhase = .exited(processID: processID, code: 0)
        exited.targetDisposition = .exited(code: 0)
        exited.stopRevision = nil

        var detached = exactStoppedState(authority: authority)
        detached.processPhase = .detached(processID: processID)
        detached.targetDisposition = .detached
        detached.stopRevision = nil
        detached.isInvalidated = true

        var terminated = exactStoppedState(authority: authority)
        terminated.processPhase = .terminated(processID: processID)
        terminated.targetDisposition = .terminated
        terminated.stopRevision = nil
        terminated.isInvalidated = true

        for state in [exited, detached, terminated] {
            XCTAssertEqual(policy.decision(for: state), .retireIdleTransport)
        }
    }

    func testControllerTerminalProofIsOriginAndIdentityExact() throws {
        let launched = launchedAuthority(try identity(processID: 800))
        let terminated = reducedTerminalState(
            authority: launched,
            establishmentOperation: .launch,
            terminalOperation: .terminate,
            terminalPayload: .processTerminated(authority: launched)
        )

        XCTAssertTrue(terminated.isInvalidated)
        XCTAssertTrue(
            PersistentLLDBProductionController.isExactLaunchedRecoveryTerminal(
                terminated,
                authority: launched
            )
        )

        var nonterminalLooking = terminated
        nonterminalLooking.isInvalidated = false
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactLaunchedRecoveryTerminal(
                nonterminalLooking,
                authority: launched
            )
        )

        var wrongDisposition = terminated
        wrongDisposition.targetDisposition = .detached
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactLaunchedRecoveryTerminal(
                wrongDisposition,
                authority: launched
            )
        )

        let foreign = launchedAuthority(try identity(processID: 801))
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactLaunchedRecoveryTerminal(
                terminated,
                authority: foreign
            )
        )
    }

    func testControllerExactDetachProofRequiresAttachedTerminalIdentity() throws {
        let attached = attachedAuthority(try identity(processID: 800))
        let detached = reducedTerminalState(
            authority: attached,
            establishmentOperation: .attach,
            terminalOperation: .detach,
            terminalPayload: .processDetached(authority: attached)
        )

        XCTAssertTrue(detached.isInvalidated)
        XCTAssertTrue(
            PersistentLLDBProductionController.isExactAttachedRecoveryTerminal(
                detached,
                authority: attached
            )
        )

        var nonterminalLooking = detached
        nonterminalLooking.isInvalidated = false
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactAttachedRecoveryTerminal(
                nonterminalLooking,
                authority: attached
            )
        )

        var terminated = detached
        terminated.processPhase = .terminated(processID: attached.processID)
        terminated.targetDisposition = .terminated
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactAttachedRecoveryTerminal(
                terminated,
                authority: attached
            )
        )
    }

    func testControllerExternalExitProofRequiresExactAttachedTerminalIdentityAndStatus() throws {
        let attached = attachedAuthority(try identity(processID: 800))
        var exited = exactStoppedState(authority: attached)
        exited.processPhase = .exited(processID: attached.processID, code: 9)
        exited.targetDisposition = .exited(code: 9)
        exited.stopRevision = nil
        exited.isInvalidated = true

        XCTAssertTrue(
            PersistentLLDBProductionController.isExactAttachedExternalExitTerminal(
                exited,
                authority: attached
            )
        )

        var statusMismatch = exited
        statusMismatch.targetDisposition = .exited(code: nil)
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactAttachedExternalExitTerminal(
                statusMismatch,
                authority: attached
            )
        )

        var detached = exited
        detached.processPhase = .detached(processID: attached.processID)
        detached.targetDisposition = .detached
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactAttachedExternalExitTerminal(
                detached,
                authority: attached
            )
        )

        let foreign = attachedAuthority(try identity(processID: 801))
        XCTAssertFalse(
            PersistentLLDBProductionController.isExactAttachedExternalExitTerminal(
                exited,
                authority: foreign
            )
        )
    }

    func testInconsistentTerminalEvidenceFailsClosed() throws {
        let authority = attachedAuthority(try identity())
        var state = exactStoppedState(authority: authority)
        state.processPhase = .detached(processID: authority.processID)
        state.targetDisposition = .unknown
        state.stopRevision = nil
        state.isInvalidated = true

        XCTAssertEqual(
            policy.decision(for: state),
            .retireOwnedTransportAndReobserve(authority)
        )
    }

    func testPartialMutationReasonNamesTheFailingOperation() {
        let cases: [(DebuggerOperation, DebuggerRecoveryReason)] = [
            (.selectThread, .partialThreadSelection), (.selectFrame, .partialFrameSelection),
            (.writeRegister, .partialRegisterWrite), (.writeMemory, .partialMemoryWrite),
            (.launch, .partialLaunch), (.runToCursor, .runToCursorCleanup),
            (.replaceBreakpoints, .partialBreakpointMutation),
            (.reconcileLogicalBreakpoints, .partialBreakpointMutation),
            (.pollProcessStatus, .callbackOrHelperAuthorityLoss),
        ]
        for (operation, expected) in cases {
            XCTAssertEqual(DebuggerRecoveryReason.partialMutation(operation: operation), expected)
        }
    }

    func testRecoveryReasonSetIsFrozen() {
        XCTAssertEqual(
            Set(DebuggerRecoveryReason.allCases),
            [
                .partialBreakpointMutation,
                .partialThreadSelection,
                .partialFrameSelection,
                .partialRegisterWrite,
                .partialMemoryWrite,
                .partialLaunch,
                .callbackOrHelperAuthorityLoss,
                .runToCursorCleanup,
                .unavailableLogicalCatalog,
                .sessionReplacement,
                .adapterInterruption,
                .userRequestedSessionEnd,
                .windowClose,
                .appTermination,
            ]
        )
    }

    private var policy: DebuggerOriginAwareRecoveryPolicy {
        DebuggerOriginAwareRecoveryPolicy(reason: .adapterInterruption)
    }

    private func reducerState() -> DebuggerReducerState {
        DebuggerReducerState(
            epoch: DebuggerSessionEpoch(
                rawValue: UUID(uuidString: "C2C2C2C2-C2C2-C2C2-C2C2-C2C2C2C2C2C2")!
            ),
            capabilities: .persistentCLI(
                attachPolicyReason: "Attach policy is irrelevant to this pure recovery test."
            )
        )
    }

    private func exactStoppedState(
        authority: DebuggerSessionTargetAuthority
    ) -> DebuggerReducerState {
        var state = reducerState()
        state.processPhase = .stopped(processID: authority.processID, reason: .step)
        state.observedProcessID = authority.processID
        state.acceptedTargetAuthority = authority
        state.targetDisposition = .stopped(processID: authority.processID)
        state.stopRevision = DebuggerStopRevision(rawValue: 1)
        return state
    }

    private func exactRunningState(
        authority: DebuggerSessionTargetAuthority
    ) -> DebuggerReducerState {
        var state = reducerState()
        state.processPhase = .running(processID: authority.processID)
        state.observedProcessID = authority.processID
        state.acceptedTargetAuthority = authority
        state.targetDisposition = .running(processID: authority.processID)
        return state
    }

    private func reducedTerminalState(
        authority: DebuggerSessionTargetAuthority,
        establishmentOperation: DebuggerOperation,
        terminalOperation: DebuggerOperation,
        terminalPayload: DebuggerEventPayload
    ) -> DebuggerReducerState {
        var reducer = supportedReducer()
        let establish = request(
            sequence: 1,
            operation: establishmentOperation,
            session: reducer.state.sessionCoordinate,
            target: authority
        )
        XCTAssertAccepted(reducer.admit(establish))
        XCTAssertAccepted(reducer.reduce(event(1, establish, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            2,
            establish,
            .authorizedSessionOpened(
                observedPID: authority.processID,
                authority: authority
            )
        )))
        XCTAssertAccepted(reducer.reduce(event(
            3,
            establish,
            .processStopped(observedPID: authority.processID, reason: .step)
        )))
        XCTAssertAccepted(reducer.reduce(event(
            4,
            establish,
            .requestCompleted(.completed(target: .stopped(processID: authority.processID)))
        )))

        let terminal = request(
            sequence: 2,
            operation: terminalOperation,
            session: reducer.state.sessionCoordinate,
            target: authority
        )
        XCTAssertAccepted(reducer.admit(terminal))
        XCTAssertAccepted(reducer.reduce(event(5, terminal, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(6, terminal, terminalPayload)))
        return reducer.state
    }

    private func supportedReducer() -> DebuggerSessionReducer {
        DebuggerSessionReducer(
            epoch: reducerState().epoch,
            capabilities: DebuggerTransportCapabilities(
                operationStates: Dictionary(
                    uniqueKeysWithValues: DebuggerOperation.allCases.map {
                        ($0, DebuggerOperationCapability.supportedAndObserved)
                    }
                ),
                mechanics: .persistentCLI
            )
        )
    }

    private func request(
        sequence: UInt64,
        operation: DebuggerOperation,
        session: DebuggerSessionCoordinate,
        target: DebuggerSessionTargetAuthority
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: DebuggerRequestID(epoch: session.epoch, sequence: sequence),
            operation: operation,
            expectedSession: session,
            requiredStop: nil,
            targetAuthority: target
        )
    }

    private func event(
        _ sequence: UInt64,
        _ context: DebuggerRequestContext,
        _ payload: DebuggerEventPayload
    ) -> DebuggerEventEnvelope {
        DebuggerEventEnvelope(
            sessionEpoch: context.id.epoch,
            eventSequence: DebuggerEventSequence(rawValue: sequence),
            requestID: context.id,
            operation: context.operation,
            capturedLifecycleRevision: context.expectedSession.lifecycleRevision,
            boundStopRevision: context.requiredStop?.stopRevision,
            payload: payload
        )
    }

    private func XCTAssertAccepted(
        _ admission: DebuggerRequestAdmission,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .accepted = admission else {
            XCTFail("Expected accepted request, got \(admission)", file: file, line: line)
            return
        }
    }

    private func XCTAssertAccepted(
        _ reduction: DebuggerEventReduction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reduction, .accepted, file: file, line: line)
    }

    private func identity(processID: Int32 = 800) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeRecoveryFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        ))
    }

    private func launchedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
    }

    private func attachedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(origin: .attached(identity))
    }
}

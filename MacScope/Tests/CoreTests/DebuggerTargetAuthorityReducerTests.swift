import XCTest
@testable import MacScope

final class DebuggerTargetAuthorityReducerTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
    )

    func testRequestedEstablishmentTargetOriginMustMatchOperation() {
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: .initial
        )
        let launched = launchedAuthority(identity())
        let attached = attachedAuthority(identity())

        XCTAssertTrue(request(1, .launch, session, target: launched).isInternallyConsistent)
        XCTAssertTrue(request(2, .launch, session, target: nil).isInternallyConsistent)
        XCTAssertTrue(request(3, .attach, session, target: attached).isInternallyConsistent)
        XCTAssertFalse(request(4, .launch, session, target: attached).isInternallyConsistent)
        XCTAssertFalse(request(5, .attach, session, target: launched).isInternallyConsistent)
        XCTAssertFalse(request(6, .attach, session, target: nil).isInternallyConsistent)
    }

    func testAdmissionPrecedenceRetainsCapabilityErrorsAndExactAuthorityFailClosed() {
        var policyReducer = DebuggerSessionReducer(
            epoch: epoch,
            capabilities: .persistentCLI(attachPolicyReason: "Attach unavailable.")
        )
        let unavailableAttach = request(
            1,
            .attach,
            policyReducer.state.sessionCoordinate,
            target: nil
        )
        XCTAssertEqual(policyReducer.admit(unavailableAttach), .rejected(.unavailableOperation))

        let authority = launchedAuthority(identity())
        var exactReducer = makeStoppedReducer(authority: authority)
        let missingAuthorityAndStop = request(
            2,
            .refreshSnapshot,
            exactReducer.state.sessionCoordinate,
            target: nil
        )
        XCTAssertEqual(
            exactReducer.admit(missingAuthorityAndStop),
            .rejected(.missingTargetAuthority)
        )
    }

    func testAuthorizedSessionOpenRequiresExactRequestedAuthorityAndPID() {
        let requested = launchedAuthority(identity())
        var reducer = makeReducer()
        let launch = request(
            1,
            .launch,
            reducer.state.sessionCoordinate,
            target: requested
        )
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))

        let beforeMismatch = reducer.state
        XCTAssertEqual(
            reducer.reduce(event(
                2,
                launch,
                .authorizedSessionOpened(
                    observedPID: requested.processID + 1,
                    authority: requested
                )
            )),
            .rejected(.wrongProcessID)
        )
        XCTAssertEqual(reducer.state, beforeMismatch)

        let foreign = launchedAuthority(identity(processID: 502))
        XCTAssertEqual(
            reducer.reduce(event(
                2,
                launch,
                .authorizedSessionOpened(
                    observedPID: foreign.processID,
                    authority: foreign
                )
            )),
            .rejected(.wrongTargetAuthority)
        )
        XCTAssertEqual(reducer.state, beforeMismatch)

        XCTAssertAccepted(reducer.reduce(event(
            2,
            launch,
            .authorizedSessionOpened(
                observedPID: requested.processID,
                authority: requested
            )
        )))
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, requested)
        XCTAssertEqual(reducer.state.observedProcessID, requested.processID)
    }

    func testAcceptedAuthorityIsMonotonicAndRequiredByPostAcceptOperations() {
        let accepted = launchedAuthority(identity())
        var reducer = makeStoppedReducer(authority: accepted)
        let before = reducer.state

        let missing = request(
            2,
            .refreshSnapshot,
            reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate,
            target: nil
        )
        XCTAssertEqual(reducer.admit(missing), .rejected(.missingTargetAuthority))
        XCTAssertEqual(reducer.state, before)

        let wrong = request(
            3,
            .refreshSnapshot,
            reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate,
            target: attachedAuthority(identity())
        )
        XCTAssertEqual(reducer.admit(wrong), .rejected(.wrongTargetAuthority))
        XCTAssertEqual(reducer.state, before)

        let exact = request(
            4,
            .refreshSnapshot,
            reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate,
            target: accepted
        )
        XCTAssertAccepted(reducer.admit(exact))
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, accepted)
    }

    func testAttachedDetachRetainsTerminalTombstoneAndClearsStopAuthorities() {
        let authority = attachedAuthority(identity())
        var reducer = makeStoppedReducer(authority: authority, operation: .attach)
        let detach = request(
            2,
            .detach,
            reducer.state.sessionCoordinate,
            target: authority
        )

        XCTAssertAccepted(reducer.admit(detach))
        XCTAssertAccepted(reducer.reduce(event(5, detach, .requestStarted)))

        XCTAssertEqual(reducer.state.processPhase, .detaching(processID: authority.processID))
        XCTAssertEqual(reducer.state.targetDisposition, .unknown)
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, authority)
        XCTAssertEqual(reducer.state.observedProcessID, authority.processID)
        XCTAssertNil(reducer.state.stopCoordinate)
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.terminal))
        XCTAssertTrue(reducer.breakpointBindingState.isTerminal)
        let detachingSnapshot = DebuggerTransportSnapshotProjector.project(reducer.state)
        XCTAssertEqual(detachingSnapshot.processState, .detaching(processID: authority.processID))
        XCTAssertEqual(
            detachingSnapshot.backendState,
            .disconnecting(processID: authority.processID, adapterName: "Xcode LLDB CLI")
        )

        XCTAssertAccepted(reducer.reduce(event(
            6,
            detach,
            .processDetached(authority: authority)
        )))

        XCTAssertEqual(reducer.state.processPhase, .detached(processID: authority.processID))
        XCTAssertEqual(reducer.state.targetDisposition, .detached)
        XCTAssertEqual(reducer.state.observedProcessID, authority.processID)
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, authority)
        XCTAssertNil(reducer.state.stopCoordinate)
        XCTAssertNil(reducer.state.pendingRequest)
        XCTAssertTrue(reducer.state.isInvalidated)
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.terminal))
        XCTAssertTrue(reducer.breakpointBindingState.isTerminal)

        let snapshot = DebuggerTransportSnapshotProjector.project(reducer.state)
        XCTAssertEqual(snapshot.processState, .notAttached)
        XCTAssertEqual(snapshot.transportTargetDisposition, .detached)
        XCTAssertEqual(snapshot.transportTargetAuthority, authority)
    }

    func testDetachCancellationBoundaryPreservesBeforeWriteAndFailsClosedAfterWrite() {
        let authority = attachedAuthority(identity())
        var beforeWrite = makeStoppedReducer(authority: authority, operation: .attach)
        let beforeRequest = request(
            2,
            .detach,
            beforeWrite.state.sessionCoordinate,
            target: authority
        )
        XCTAssertAccepted(beforeWrite.admit(beforeRequest))
        let admittedState = beforeWrite.state
        XCTAssertAccepted(beforeWrite.reduce(event(
            5,
            beforeRequest,
            .requestCancelled(.cancelledBeforeWrite)
        )))
        XCTAssertEqual(beforeWrite.state.processPhase, admittedState.processPhase)
        XCTAssertEqual(beforeWrite.state.stopCoordinate, admittedState.stopCoordinate)
        XCTAssertEqual(beforeWrite.state.acceptedTargetAuthority, authority)
        XCTAssertFalse(beforeWrite.state.isInvalidated)

        var afterWrite = makeStoppedReducer(authority: authority, operation: .attach)
        let afterRequest = request(
            2,
            .detach,
            afterWrite.state.sessionCoordinate,
            target: authority
        )
        XCTAssertAccepted(afterWrite.admit(afterRequest))
        XCTAssertAccepted(afterWrite.reduce(event(5, afterRequest, .requestStarted)))
        XCTAssertAccepted(afterWrite.reduce(event(
            6,
            afterRequest,
            .requestCancelled(.invalidatedAfterWrite(
                reason: .cancellationAfterWrite,
                target: .unknown
            ))
        )))
        XCTAssertEqual(afterWrite.state.processPhase, .invalidated)
        XCTAssertTrue(afterWrite.state.isInvalidated)
        XCTAssertEqual(afterWrite.state.acceptedTargetAuthority, authority)
        XCTAssertEqual(afterWrite.state.observedProcessID, authority.processID)
        XCTAssertNil(afterWrite.state.stopCoordinate)
    }

    func testExplicitTerminationRequiresExactAuthorityAndRetainsTerminalTombstone() {
        let authority = launchedAuthority(identity())
        var reducer = makeStoppedReducer(authority: authority)
        let terminate = request(
            2,
            .terminate,
            reducer.state.sessionCoordinate,
            target: authority
        )
        XCTAssertAccepted(reducer.admit(terminate))
        XCTAssertAccepted(reducer.reduce(event(5, terminate, .requestStarted)))

        let beforeMismatch = reducer.state
        XCTAssertEqual(
            reducer.reduce(event(
                6,
                terminate,
                .processTerminated(authority: attachedAuthority(identity()))
            )),
            .rejected(.wrongTargetAuthority)
        )
        XCTAssertEqual(reducer.state, beforeMismatch)

        XCTAssertAccepted(reducer.reduce(event(
            6,
            terminate,
            .processTerminated(authority: authority)
        )))
        XCTAssertEqual(reducer.state.processPhase, .terminated(processID: authority.processID))
        XCTAssertEqual(reducer.state.targetDisposition, .terminated)
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, authority)
        XCTAssertEqual(reducer.state.observedProcessID, authority.processID)
        XCTAssertTrue(reducer.state.isInvalidated)
    }

    func testNaturalExitRetainsExactAuthorityAndTerminalProjection() {
        let authority = launchedAuthority(identity())
        var reducer = makeStoppedReducer(authority: authority)
        let resume = request(
            2,
            .continue,
            reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate,
            target: authority
        )
        XCTAssertAccepted(reducer.admit(resume))
        XCTAssertAccepted(reducer.reduce(event(5, resume, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            6,
            resume,
            .processExited(observedPID: authority.processID, exitCode: 9)
        )))

        XCTAssertEqual(
            reducer.state.processPhase,
            .exited(processID: authority.processID, code: 9)
        )
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, authority)
        XCTAssertEqual(reducer.state.observedProcessID, authority.processID)
        XCTAssertNil(reducer.state.stopCoordinate)
        XCTAssertTrue(reducer.state.isInvalidated)
        let snapshot = DebuggerTransportSnapshotProjector.project(reducer.state)
        XCTAssertEqual(snapshot.processState, .exited(code: 9))
        XCTAssertEqual(snapshot.transportTargetAuthority, authority)
    }

    func testUnknownInvalidationRetainsTargetTombstoneWhileRevokingStopAuthority() {
        let authority = attachedAuthority(identity())
        var reducer = makeStoppedReducer(authority: authority, operation: .attach)
        let diagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: "correlated transport disposition became unknown",
            operation: .pollProcessStatus,
            targetDisposition: .unknown
        )
        let envelope = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: DebuggerEventSequence(rawValue: 5),
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: reducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .sessionInvalidated(diagnostic)
        )

        XCTAssertAccepted(reducer.reduce(envelope))
        XCTAssertEqual(reducer.state.processPhase, .invalidated)
        XCTAssertEqual(reducer.state.targetDisposition, .unknown)
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, authority)
        XCTAssertEqual(reducer.state.observedProcessID, authority.processID)
        XCTAssertNil(reducer.state.stopCoordinate)
        XCTAssertTrue(reducer.runtimeModuleInventoryState.isSessionInvalidated)
        XCTAssertTrue(reducer.breakpointBindingState.isInvalidated)
        let snapshot = DebuggerTransportSnapshotProjector.project(reducer.state)
        XCTAssertEqual(snapshot.transportTargetAuthority, authority)
        XCTAssertEqual(snapshot.transportTargetDisposition, .unknown)
    }

    func testLegacyPIDOnlySessionOpenIsLimitedToNilTargetLaunch() {
        var legacy = makeReducer()
        let legacyLaunch = request(
            1,
            .launch,
            legacy.state.sessionCoordinate,
            target: nil
        )
        XCTAssertAccepted(legacy.admit(legacyLaunch))
        XCTAssertAccepted(legacy.reduce(event(1, legacyLaunch, .requestStarted)))
        XCTAssertAccepted(legacy.reduce(event(
            2,
            legacyLaunch,
            .sessionOpened(observedPID: 501)
        )))
        XCTAssertNil(legacy.state.acceptedTargetAuthority)
        XCTAssertEqual(legacy.state.observedProcessID, 501)
        XCTAssertAccepted(legacy.reduce(event(
            3,
            legacyLaunch,
            .processStopped(observedPID: 501, reason: .step)
        )))
        XCTAssertAccepted(legacy.reduce(event(
            4,
            legacyLaunch,
            .requestCompleted(.completed(target: .stopped(processID: 501)))
        )))

        let legacyPostAccept = request(
            2,
            .pollProcessStatus,
            legacy.state.sessionCoordinate,
            target: nil
        )
        XCTAssertAccepted(legacy.admit(legacyPostAccept))

        var exact = makeReducer()
        let authority = launchedAuthority(identity())
        let exactLaunch = request(
            1,
            .launch,
            exact.state.sessionCoordinate,
            target: authority
        )
        XCTAssertAccepted(exact.admit(exactLaunch))
        XCTAssertAccepted(exact.reduce(event(1, exactLaunch, .requestStarted)))
        let before = exact.state
        XCTAssertEqual(
            exact.reduce(event(2, exactLaunch, .sessionOpened(observedPID: 501))),
            .rejected(.missingTargetAuthority)
        )
        XCTAssertEqual(exact.state, before)
    }

    func testPersistentCLIDetachIsHonestlyPolicyDeniedUntilTransportExists() {
        let capabilities = DebuggerTransportCapabilities.persistentCLI(
            attachPolicyReason: "Attach transaction not installed."
        )
        XCTAssertEqual(DebuggerOperation.detach.displayLabel, "Detach")
        XCTAssertEqual(DebuggerOperation.detach.classification, .lifecycleMutating)
        XCTAssertFalse(DebuggerOperation.detach.requiresStopCoordinate)
        guard case .policyDenied(let reason) = capabilities.capability(for: .detach) else {
            return XCTFail("Persistent CLI must not advertise an unimplemented detach transaction.")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    private func makeReducer() -> DebuggerSessionReducer {
        let states = Dictionary(
            uniqueKeysWithValues: DebuggerOperation.allCases.map {
                ($0, DebuggerOperationCapability.supportedAndObserved)
            }
        )
        return DebuggerSessionReducer(
            epoch: epoch,
            capabilities: DebuggerTransportCapabilities(
                operationStates: states,
                mechanics: .persistentCLI
            )
        )
    }

    private func makeStoppedReducer(
        authority: DebuggerSessionTargetAuthority,
        operation: DebuggerOperation = .launch
    ) -> DebuggerSessionReducer {
        var reducer = makeReducer()
        let establish = request(
            1,
            operation,
            reducer.state.sessionCoordinate,
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
        return reducer
    }

    private func request(
        _ sequence: UInt64,
        _ operation: DebuggerOperation,
        _ session: DebuggerSessionCoordinate,
        stop: DebuggerStopCoordinate? = nil,
        target: DebuggerSessionTargetAuthority?
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: DebuggerRequestID(epoch: session.epoch, sequence: sequence),
            operation: operation,
            expectedSession: session,
            requiredStop: stop,
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

    private func identity(processID: Int32 = 501) -> DebuggerLocalProcessIdentity {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeC0Fixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        )!
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
}

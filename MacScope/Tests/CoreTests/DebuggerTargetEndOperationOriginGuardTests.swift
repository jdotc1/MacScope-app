import XCTest
@testable import MacScope

final class DebuggerTargetEndOperationOriginGuardTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "C2E0C2E0-C2E0-C2E0-C2E0-C2E0C2E0C2E0")!
    )

    func testRequestStructureRequiresAttachedDetachAndLaunchedTerminateOrigins() {
        let session = DebuggerSessionCoordinate(epoch: epoch, lifecycleRevision: .initial)
        let launched = launchedAuthority(identity())
        let attached = attachedAuthority(identity())

        XCTAssertTrue(request(1, .detach, session, target: attached).isInternallyConsistent)
        XCTAssertFalse(request(2, .detach, session, target: launched).isInternallyConsistent)
        XCTAssertFalse(request(3, .detach, session, target: nil).isInternallyConsistent)

        XCTAssertTrue(request(4, .terminate, session, target: launched).isInternallyConsistent)
        XCTAssertFalse(request(5, .terminate, session, target: attached).isInternallyConsistent)
        XCTAssertTrue(
            request(6, .terminate, session, target: nil).isInternallyConsistent,
            "nil terminate remains structurally representable only for the legacy launch-created PID path"
        )
    }

    func testReducerRejectsTargetEndOperationWhoseOriginMatchesTheAcceptedTargetButNotTheOperation() {
        let launched = launchedAuthority(identity())
        var launchedReducer = makeStoppedReducer(authority: launched, establishment: .launch)
        let launchedBefore = launchedReducer.state

        XCTAssertEqual(
            launchedReducer.admit(
                request(2, .detach, launchedReducer.state.sessionCoordinate, target: launched)
            ),
            .rejected(.invalidTargetOrigin)
        )
        XCTAssertEqual(launchedReducer.state, launchedBefore)

        let attached = attachedAuthority(identity())
        var attachedReducer = makeStoppedReducer(authority: attached, establishment: .attach)
        let attachedBefore = attachedReducer.state

        XCTAssertEqual(
            attachedReducer.admit(
                request(2, .terminate, attachedReducer.state.sessionCoordinate, target: attached)
            ),
            .rejected(.invalidTargetOrigin)
        )
        XCTAssertEqual(attachedReducer.state, attachedBefore)
    }

    func testReducerAcceptsOnlyExactOriginAppropriateTargetEndAuthority() {
        let attached = attachedAuthority(identity())
        var attachedReducer = makeStoppedReducer(authority: attached, establishment: .attach)
        XCTAssertAccepted(
            attachedReducer.admit(
                request(2, .detach, attachedReducer.state.sessionCoordinate, target: attached)
            )
        )

        let launched = launchedAuthority(identity())
        var launchedReducer = makeStoppedReducer(authority: launched, establishment: .launch)
        XCTAssertAccepted(
            launchedReducer.admit(
                request(2, .terminate, launchedReducer.state.sessionCoordinate, target: launched)
            )
        )
    }

    func testReducerRejectsForeignAuthorityEvenWhenItsOriginMatchesTheEndOperation() {
        let attached = attachedAuthority(identity())
        var attachedReducer = makeStoppedReducer(authority: attached, establishment: .attach)
        XCTAssertEqual(
            attachedReducer.admit(
                request(
                    2,
                    .detach,
                    attachedReducer.state.sessionCoordinate,
                    target: attachedAuthority(identity(processID: 702))
                )
            ),
            .rejected(.wrongTargetAuthority)
        )

        let launched = launchedAuthority(identity())
        var launchedReducer = makeStoppedReducer(authority: launched, establishment: .launch)
        XCTAssertEqual(
            launchedReducer.admit(
                request(
                    2,
                    .terminate,
                    launchedReducer.state.sessionCoordinate,
                    target: launchedAuthority(identity(processID: 702))
                )
            ),
            .rejected(.wrongTargetAuthority)
        )
    }

    func testLegacyLaunchCreatedPIDSessionRetainsOnlyNilAuthorityTerminateCompatibility() {
        var detachReducer = makeLegacyStoppedReducer()
        let detachBefore = detachReducer.state
        XCTAssertEqual(
            detachReducer.admit(
                request(2, .detach, detachReducer.state.sessionCoordinate, target: nil)
            ),
            .rejected(.missingTargetAuthority)
        )
        XCTAssertEqual(detachReducer.state, detachBefore)

        var terminateReducer = makeLegacyStoppedReducer()
        XCTAssertAccepted(
            terminateReducer.admit(
                request(2, .terminate, terminateReducer.state.sessionCoordinate, target: nil)
            )
        )
    }

    private func makeReducer() -> DebuggerSessionReducer {
        DebuggerSessionReducer(
            epoch: epoch,
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

    private func makeStoppedReducer(
        authority: DebuggerSessionTargetAuthority,
        establishment: DebuggerOperation
    ) -> DebuggerSessionReducer {
        var reducer = makeReducer()
        let establish = request(
            1,
            establishment,
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

    private func makeLegacyStoppedReducer() -> DebuggerSessionReducer {
        var reducer = makeReducer()
        let launch = request(1, .launch, reducer.state.sessionCoordinate, target: nil)
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(2, launch, .sessionOpened(observedPID: 701))))
        XCTAssertAccepted(reducer.reduce(event(
            3,
            launch,
            .processStopped(observedPID: 701, reason: .step)
        )))
        XCTAssertAccepted(reducer.reduce(event(
            4,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 701)))
        )))
        return reducer
    }

    private func request(
        _ sequence: UInt64,
        _ operation: DebuggerOperation,
        _ session: DebuggerSessionCoordinate,
        target: DebuggerSessionTargetAuthority?
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: DebuggerRequestID(epoch: session.epoch, sequence: sequence),
            operation: operation,
            expectedSession: session,
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
            boundStopRevision: nil,
            payload: payload
        )
    }

    private func identity(processID: Int32 = 701) -> DebuggerLocalProcessIdentity {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeTargetEndGuardFixture",
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

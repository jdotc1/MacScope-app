import Foundation
import XCTest
@testable import MacScope

final class DebuggerEventReducerTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    private let foreignEpoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )

    func testWatchpointsRequireCurrentStopAndPublishOnlyCorrelatedResults() {
        var reducer = makeStoppedReducer()
        XCTAssertEqual(DebuggerOperation.updateWatchpoints.classification, .stoppedStateMutating)
        let missing = request(sequence: 2, operation: .updateWatchpoints, session: reducer.state.sessionCoordinate)
        XCTAssertEqual(reducer.admit(missing), .rejected(.missingStop))
        let update = request(sequence: 3, operation: .updateWatchpoints,
                             session: reducer.state.sessionCoordinate, stop: reducer.state.stopCoordinate)
        XCTAssertAccepted(reducer.admit(update))
        XCTAssertAccepted(reducer.reduce(event(4, update, .requestStarted)))
        let watchpoint = DebuggerWatchpoint(id: UUID(), address: 0x1000, size: 8,
                                           access: .readWrite, isEnabled: true, backendID: 1)
        let payload = DebuggerEventPayload.watchpointsUpdated(DebuggerWatchpointUpdate(watchpoints: [watchpoint], error: nil))
        let unchanged = reducer.state
        XCTAssertEqual(reducer.reduce(event(5, update, payload, stop: DebuggerStopRevision(rawValue: 99))), .rejected(.staleStop))
        XCTAssertEqual(reducer.state, unchanged)
        XCTAssertAccepted(reducer.reduce(event(6, update, payload)))
        XCTAssertEqual(DebuggerTransportSnapshotProjector.project(reducer.state).watchpoints, [watchpoint])
        XCTAssertAccepted(reducer.reduce(event(7, update, .requestCompleted(.completed(target: .stopped(processID: 88))))))
    }

    func testWatchpointRefusalKeepsCatalogAndExitClearsRuntimeAddresses() {
        var reducer = makeStoppedReducer()
        let update = request(sequence: 2, operation: .updateWatchpoints,
                             session: reducer.state.sessionCoordinate, stop: reducer.state.stopCoordinate)
        XCTAssertAccepted(reducer.admit(update))
        XCTAssertAccepted(reducer.reduce(event(4, update, .requestStarted)))
        let watchpoint = DebuggerWatchpoint(id: UUID(), address: 0x1000, size: 4,
                                           access: .write, isEnabled: true, backendID: 1)
        XCTAssertAccepted(reducer.reduce(event(5, update, .watchpointsUpdated(
            DebuggerWatchpointUpdate(watchpoints: [watchpoint], error: "Hardware watchpoint limit reached.")))))
        XCTAssertEqual(reducer.state.watchpoints, [watchpoint])
        XCTAssertNotNil(reducer.state.watchpointError)
        XCTAssertAccepted(reducer.reduce(event(6, update, .requestCompleted(.completed(target: .stopped(processID: 88))))))
        let resume = request(sequence: 3, operation: .continue,
                             session: reducer.state.sessionCoordinate, stop: reducer.state.stopCoordinate)
        XCTAssertAccepted(reducer.admit(resume))
        XCTAssertAccepted(reducer.reduce(event(7, resume, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(8, resume, .processExited(observedPID: 88, exitCode: 0))))
        XCTAssertTrue(reducer.state.watchpoints.isEmpty)
        XCTAssertNil(reducer.state.watchpointError)
    }

    func testAdmissionRequiresExactActiveCoordinatesCapabilityAndSingleFlight() {
        var reducer = makeReducer()
        let initial = reducer.state

        let attach = request(
            sequence: 1,
            operation: .attach,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertEqual(reducer.admit(attach), .rejected(.unavailableOperation))
        XCTAssertEqual(reducer.state, initial)

        let stale = request(
            sequence: 2,
            operation: .launch,
            session: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
            )
        )
        XCTAssertEqual(reducer.admit(stale), .rejected(.staleLifecycle))
        XCTAssertEqual(reducer.state, initial)

        let launch = request(
            sequence: 3,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertEqual(
            reducer.admit(launch),
            .accepted(DebuggerPendingRequest(context: launch, hasStarted: false))
        )
        let admitted = reducer.state

        let conflicting = request(
            sequence: 4,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertEqual(reducer.admit(conflicting), .rejected(.conflictingRequest))
        XCTAssertEqual(reducer.state, admitted)
    }

    func testStoppedOperationAdmissionRequiresExactCurrentStop() {
        var reducer = makeStoppedReducer()
        let before = reducer.state

        let missing = request(
            sequence: 2,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertEqual(reducer.admit(missing), .rejected(.missingStop))
        XCTAssertEqual(reducer.state, before)

        let staleStop = DebuggerStopCoordinate(
            session: reducer.state.sessionCoordinate,
            stopRevision: DebuggerStopRevision(rawValue: 99)
        )
        let stale = request(
            sequence: 3,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: staleStop
        )
        XCTAssertEqual(reducer.admit(stale), .rejected(.staleStop))
        XCTAssertEqual(reducer.state, before)

        let exact = request(
            sequence: 4,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertEqual(
            reducer.admit(exact),
            .accepted(DebuggerPendingRequest(context: exact, hasStarted: false))
        )
    }

    func testRunControlAdmissionBindsTheStopItResumesFrom() {
        var reducer = makeStoppedReducer()
        let missingStop = request(
            sequence: 2,
            operation: .continue,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertEqual(reducer.admit(missingStop), .rejected(.missingStop))

        let exact = request(
            sequence: 3,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertEqual(
            reducer.admit(exact),
            .accepted(DebuggerPendingRequest(context: exact, hasStarted: false))
        )
    }

    func testCanonicalLifecycleMintsMonotonicRevisionsAndReplacesStoppedData() {
        var reducer = makeReducer()
        let launch = request(
            sequence: 1,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(2, launch, .sessionOpened(observedPID: 321))))
        XCTAssertAccepted(reducer.reduce(event(
            3,
            launch,
            .processStopped(observedPID: 321, reason: .unknown("entry"))
        )))
        XCTAssertEqual(reducer.state.lifecycleRevision.rawValue, 1)
        XCTAssertEqual(reducer.state.stopRevision?.rawValue, 1)
        XCTAssertEqual(reducer.state.targetDisposition, .stopped(processID: 321))
        XCTAssertAccepted(reducer.reduce(event(
            4,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 321)))
        )))

        let refresh = request(
            sequence: 2,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertAccepted(reducer.reduce(event(5, refresh, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(6, refresh, .stoppedDataRefreshed(sampleStoppedData))))
        XCTAssertEqual(reducer.state.stoppedData, sampleStoppedData)
        XCTAssertAccepted(reducer.reduce(event(
            7,
            refresh,
            .requestCompleted(.completed(target: .stopped(processID: 321)))
        )))

        let resume = request(
            sequence: 3,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(resume))
        XCTAssertAccepted(reducer.reduce(event(8, resume, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(9, resume, .processRunning(observedPID: 321))))
        XCTAssertEqual(reducer.state.lifecycleRevision.rawValue, 2)
        XCTAssertNil(reducer.state.stopRevision)
        XCTAssertNil(reducer.state.stoppedData)
        XCTAssertNil(reducer.state.expressionEvaluation)
        XCTAssertEqual(reducer.state.targetDisposition, .running(processID: 321))

        XCTAssertAccepted(reducer.reduce(event(
            10,
            resume,
            .processStopped(observedPID: 321, reason: .step)
        )))
        XCTAssertEqual(reducer.state.lifecycleRevision.rawValue, 3)
        XCTAssertEqual(reducer.state.stopRevision?.rawValue, 2)
        XCTAssertNil(reducer.state.stoppedData)
        XCTAssertAccepted(reducer.reduce(event(
            11,
            resume,
            .requestCompleted(.completed(target: .stopped(processID: 321)))
        )))
    }

    func testCorroboratedDynamicLaunchAuthorityIsNarrowAndPropagatesToOrdinaryRequests() throws {
        var reducer = makeReducer()
        let launched = launchedAuthority(processID: 417)
        let attached = attachedAuthority(processID: 417)
        let launch = request(
            sequence: 1,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(launch))

        let beforeStart = reducer.state
        XCTAssertEqual(
            reducer.reduce(event(
                1,
                launch,
                .authorizedSessionOpened(observedPID: 417, authority: launched)
            )),
            .rejected(.requestNotStarted)
        )
        XCTAssertEqual(reducer.state, beforeStart)

        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        let pending = reducer.state
        XCTAssertEqual(
            reducer.reduce(event(
                2,
                launch,
                .authorizedSessionOpened(observedPID: 417, authority: attached)
            )),
            .rejected(.invalidTargetOrigin)
        )
        XCTAssertEqual(reducer.state, pending)
        XCTAssertEqual(
            reducer.reduce(event(
                2,
                launch,
                .authorizedSessionOpened(observedPID: 418, authority: launched)
            )),
            .rejected(.wrongProcessID)
        )
        XCTAssertEqual(reducer.state, pending)

        XCTAssertAccepted(reducer.reduce(event(
            2,
            launch,
            .authorizedSessionOpened(observedPID: 417, authority: launched)
        )))
        XCTAssertEqual(reducer.state.observedProcessID, 417)
        XCTAssertEqual(reducer.state.acceptedTargetAuthority, launched)

        let acceptedAuthority = reducer.state
        XCTAssertEqual(
            reducer.reduce(event(
                3,
                launch,
                .authorizedSessionOpened(observedPID: 417, authority: launched)
            )),
            .rejected(.invalidTransition)
        )
        XCTAssertEqual(reducer.state, acceptedAuthority)

        XCTAssertAccepted(reducer.reduce(event(
            3,
            launch,
            .processStopped(observedPID: 417, reason: .unknown("entry"))
        )))
        XCTAssertAccepted(reducer.reduce(event(
            4,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 417)))
        )))

        let completed = reducer.state
        XCTAssertEqual(
            reducer.reduce(event(
                5,
                launch,
                .authorizedSessionOpened(observedPID: 417, authority: launched)
            )),
            .rejected(.missingPendingRequest)
        )
        XCTAssertEqual(reducer.state, completed)

        let missingAuthority = request(
            sequence: 2,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertEqual(
            reducer.admit(missingAuthority),
            .rejected(.missingTargetAuthority)
        )
        XCTAssertEqual(reducer.state, completed)

        let exactAuthority = request(
            sequence: 3,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate,
            targetAuthority: launched
        )
        XCTAssertAccepted(reducer.admit(exactAuthority))
        XCTAssertEqual(reducer.state.pendingRequest?.context.targetAuthority, launched)
    }

    func testPreauthorizedEstablishmentStillRequiresExactRequestedAuthority() throws {
        let requestedLaunch = launchedAuthority(processID: 501)
        let foreignLaunch = launchedAuthority(processID: 502)
        var launchReducer = makeReducer(capabilities: allOperationsEnabledCapabilities())
        let launch = request(
            sequence: 1,
            operation: .launch,
            session: launchReducer.state.sessionCoordinate,
            targetAuthority: requestedLaunch
        )
        XCTAssertAccepted(launchReducer.admit(launch))
        XCTAssertAccepted(launchReducer.reduce(event(1, launch, .requestStarted)))
        let pendingLaunch = launchReducer.state
        XCTAssertEqual(
            launchReducer.reduce(event(
                2,
                launch,
                .authorizedSessionOpened(
                    observedPID: foreignLaunch.processID,
                    authority: foreignLaunch
                )
            )),
            .rejected(.wrongTargetAuthority)
        )
        XCTAssertEqual(launchReducer.state, pendingLaunch)

        let requestedAttach = attachedAuthority(processID: 601)
        let foreignAttach = attachedAuthority(processID: 602)
        var attachReducer = makeReducer(capabilities: allOperationsEnabledCapabilities())
        let attach = request(
            sequence: 1,
            operation: .attach,
            session: attachReducer.state.sessionCoordinate,
            targetAuthority: requestedAttach
        )
        XCTAssertAccepted(attachReducer.admit(attach))
        XCTAssertAccepted(attachReducer.reduce(event(1, attach, .requestStarted)))
        let pendingAttach = attachReducer.state
        XCTAssertEqual(
            attachReducer.reduce(event(
                2,
                attach,
                .authorizedSessionOpened(
                    observedPID: foreignAttach.processID,
                    authority: foreignAttach
                )
            )),
            .rejected(.wrongTargetAuthority)
        )
        XCTAssertEqual(attachReducer.state, pendingAttach)
        XCTAssertAccepted(attachReducer.reduce(event(
            2,
            attach,
            .authorizedSessionOpened(
                observedPID: requestedAttach.processID,
                authority: requestedAttach
            )
        )))
        XCTAssertEqual(attachReducer.state.acceptedTargetAuthority, requestedAttach)
    }

    func testDuplicateStopDoesNotMintAnotherRevisionOrConsumeSequence() {
        var reducer = makeReducer()
        let launch = request(sequence: 1, operation: .launch, session: reducer.state.sessionCoordinate)
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            2,
            launch,
            .processStopped(observedPID: 41, reason: .unknown("entry"))
        )))
        let beforeDuplicate = reducer.state

        XCTAssertEqual(
            reducer.reduce(event(
                3,
                launch,
                .processStopped(observedPID: 41, reason: .unknown("entry"))
            )),
            .rejected(.invalidTransition)
        )
        XCTAssertEqual(reducer.state, beforeDuplicate)
    }

    func testSynchronousRunControlStopAdvancesOnceWithoutIntermediateRunningEvent() {
        let operations: [DebuggerOperation] = [
            .continue,
            .runToCursor,
            .stepOver,
            .stepInto,
            .stepOut,
        ]

        for operation in operations {
            var reducer = makeStoppedReducer()
            let run = request(
                sequence: 2,
                operation: operation,
                session: reducer.state.sessionCoordinate,
                stop: reducer.state.stopCoordinate
            )
            XCTAssertAccepted(reducer.admit(run))
            XCTAssertAccepted(reducer.reduce(event(4, run, .requestStarted)))
            XCTAssertAccepted(reducer.reduce(event(
                5,
                run,
                .processStopped(observedPID: 88, reason: .step)
            )))
            XCTAssertEqual(reducer.state.lifecycleRevision.rawValue, 2, "\(operation)")
            XCTAssertEqual(reducer.state.stopRevision?.rawValue, 2, "\(operation)")

            let afterNewStop = reducer.state
            XCTAssertEqual(
                reducer.reduce(event(
                    6,
                    run,
                    .processStopped(observedPID: 88, reason: .step)
                )),
                .rejected(.invalidTransition),
                "\(operation)"
            )
            XCTAssertEqual(reducer.state, afterNewStop, "\(operation)")
        }
    }

    func testForeignDuplicateAndMismatchedEventsLeaveStateByteIdentical() {
        let base = reducerWithPendingRefresh()
        let context = base.state.pendingRequest!.context
        let firstSequence = base.state.lastAcceptedEventSequence.rawValue + 1

        let cases: [(DebuggerEventEnvelope, DebuggerReducerRejection)] = [
            (
                event(firstSequence, context, .requestStarted, epoch: foreignEpoch),
                .foreignEpoch
            ),
            (
                event(base.state.lastAcceptedEventSequence.rawValue, context, .requestStarted),
                .duplicateOrReorderedEvent
            ),
            (
                event(
                    firstSequence,
                    context,
                    .requestStarted,
                    requestID: DebuggerRequestID(epoch: epoch, sequence: 999)
                ),
                .wrongRequest
            ),
            (
                event(firstSequence, context, .requestStarted, operation: .readMemory),
                .wrongOperation
            ),
            (
                event(
                    firstSequence,
                    context,
                    .requestStarted,
                    lifecycle: DebuggerLifecycleRevision(rawValue: 0)
                ),
                .staleLifecycle
            ),
            (
                event(
                    firstSequence,
                    context,
                    .requestStarted,
                    stop: DebuggerStopRevision(rawValue: 777)
                ),
                .staleStop
            ),
        ]

        for (envelope, rejection) in cases {
            var reducer = base
            let before = reducer.state
            XCTAssertEqual(reducer.reduce(envelope), .rejected(rejection))
            XCTAssertEqual(reducer.state, before)
        }
    }

    func testWrongAndMissingObservedPIDCannotAuthorProcessState() {
        var reducer = makeStoppedReducer()
        let resume = request(
            sequence: 2,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(resume))
        XCTAssertAccepted(reducer.reduce(event(4, resume, .requestStarted)))
        let before = reducer.state

        XCTAssertEqual(
            reducer.reduce(event(5, resume, .processRunning(observedPID: 999))),
            .rejected(.wrongProcessID)
        )
        XCTAssertEqual(reducer.state, before)

        var invalidPIDReducer = makeReducer()
        let launch = request(
            sequence: 1,
            operation: .launch,
            session: invalidPIDReducer.state.sessionCoordinate
        )
        XCTAssertAccepted(invalidPIDReducer.admit(launch))
        XCTAssertAccepted(invalidPIDReducer.reduce(event(1, launch, .requestStarted)))
        let beforeInvalidPID = invalidPIDReducer.state
        XCTAssertEqual(
            invalidPIDReducer.reduce(event(
                2,
                launch,
                .processStopped(observedPID: 0, reason: .unknown("invalid"))
            )),
            .rejected(.invalidProcessID)
        )
        XCTAssertEqual(invalidPIDReducer.state, beforeInvalidPID)
    }

    func testLateSuccessAndLateFailureAreRejectedByTheSamePendingFence() {
        var reducer = reducerWithPendingRefresh()
        let context = reducer.state.pendingRequest!.context
        let startSequence = reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(reducer.reduce(event(startSequence, context, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            startSequence + 1,
            context,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))
        let completed = reducer.state

        XCTAssertEqual(
            reducer.reduce(event(
                startSequence + 2,
                context,
                .requestCompleted(.completed(target: .stopped(processID: 88)))
            )),
            .rejected(.missingPendingRequest)
        )
        XCTAssertEqual(reducer.state, completed)

        XCTAssertEqual(
            reducer.reduce(event(startSequence + 3, context, .requestFailed(sampleDiagnostic))),
            .rejected(.missingPendingRequest)
        )
        XCTAssertEqual(reducer.state, completed)
    }

    func testCrossedTerminalDispositionsAndUnownedTargetFactsAreRejectedByteIdentically() {
        let cases: [(started: Bool, payload: DebuggerEventPayload, rejection: DebuggerReducerRejection)] = [
            (
                false,
                .requestCancelled(.completed(target: .running(processID: 999))),
                .invalidTransition
            ),
            (true, .requestCompleted(.cancelledBeforeWrite), .invalidTransition),
            (
                true,
                .requestCompleted(.completed(target: .running(processID: 999))),
                .invalidTargetDisposition
            ),
            (
                true,
                .requestCancelled(.invalidatedAfterWrite(
                    reason: .cancellationAfterWrite,
                    target: .running(processID: 999)
                )),
                .invalidTargetDisposition
            ),
            (
                true,
                .requestCancelled(.invalidatedAfterWrite(
                    reason: .timeoutAfterWrite,
                    target: .unknown
                )),
                .invalidTransition
            ),
        ]

        for testCase in cases {
            var reducer = reducerWithPendingRefresh()
            let context = reducer.state.pendingRequest!.context
            var sequence = reducer.state.lastAcceptedEventSequence.rawValue + 1
            if testCase.started {
                XCTAssertAccepted(reducer.reduce(event(sequence, context, .requestStarted)))
                sequence += 1
            }
            let before = reducer.state

            XCTAssertEqual(
                reducer.reduce(event(sequence, context, testCase.payload)),
                .rejected(testCase.rejection)
            )
            XCTAssertEqual(reducer.state, before)
        }
    }

    func testDiagnosticTargetCannotReplaceReducerOwnedTargetAuthority() {
        var failedReducer = reducerWithPendingRefresh()
        let failedContext = failedReducer.state.pendingRequest!.context
        let failureSequence = failedReducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(failedReducer.reduce(event(
            failureSequence,
            failedContext,
            .requestStarted
        )))
        let beforeFailure = failedReducer.state
        let wrongTargetDiagnostic = DebuggerDiagnostic.make(
            code: .operationFailed,
            severity: .error,
            rawText: "operation failed",
            targetDisposition: .running(processID: 999)
        )
        XCTAssertEqual(
            failedReducer.reduce(event(
                failureSequence + 1,
                failedContext,
                .requestFailed(wrongTargetDiagnostic)
            )),
            .rejected(.invalidTargetDisposition)
        )
        XCTAssertEqual(failedReducer.state, beforeFailure)

        var invalidatedReducer = makeStoppedReducer(data: sampleStoppedData)
        let beforeInvalidation = invalidatedReducer.state
        let invalidation = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: DebuggerEventSequence(
                rawValue: invalidatedReducer.state.lastAcceptedEventSequence.rawValue + 1
            ),
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: invalidatedReducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .sessionInvalidated(wrongTargetDiagnostic)
        )
        XCTAssertEqual(
            invalidatedReducer.reduce(invalidation),
            .rejected(.invalidTargetDisposition)
        )
        XCTAssertEqual(invalidatedReducer.state, beforeInvalidation)
    }

    func testOperationPayloadCompatibilityRejectsUnrelatedMutationsByteIdentically() {
        let payloads: [DebuggerEventPayload] = [
            .breakpointsReplaced([]),
            .expressionEvaluated(DebuggerExpressionEvaluation(displayValue: "0", typeName: nil)),
            .sessionOpened(observedPID: 88),
        ]

        for payload in payloads {
            var reducer = reducerWithPendingRefresh()
            let context = reducer.state.pendingRequest!.context
            let sequence = reducer.state.lastAcceptedEventSequence.rawValue + 1
            XCTAssertAccepted(reducer.reduce(event(sequence, context, .requestStarted)))
            let before = reducer.state

            XCTAssertEqual(
                reducer.reduce(event(sequence + 1, context, payload)),
                .rejected(.invalidPayload)
            )
            XCTAssertEqual(reducer.state, before)
        }
    }

    func testVariableExpansionAdmissionLoadsOnlyExactNodeAndPublishesExactChildren() throws {
        var fixture = try variableExpansionFixture()
        let request = fixture.request

        XCTAssertAccepted(fixture.reducer.admit(request))
        XCTAssertEqual(
            try variableExpansionState(in: fixture.reducer, request: request),
            .loading
        )

        let startSequence = fixture.reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(fixture.reducer.reduce(event(
            startSequence,
            request,
            .requestStarted
        )))
        XCTAssertAccepted(fixture.reducer.reduce(event(
            startSequence + 1,
            request,
            .variableChildrenRefreshed(
                request: request.variableExpansionRequest!,
                snapshot: fixture.childSnapshot
            )
        )))
        XCTAssertEqual(
            try variableExpansionState(in: fixture.reducer, request: request),
            .loaded
        )
        XCTAssertEqual(
            try expandedChildren(in: fixture.reducer, request: request),
            fixture.childSnapshot.nodes
        )
        XCTAssertAccepted(fixture.reducer.reduce(event(
            startSequence + 2,
            request,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))
        XCTAssertNil(fixture.reducer.state.pendingRequest)
    }

    func testVariableExpansionRejectsMismatchedInnerRequestTransactionally() throws {
        var fixture = try variableExpansionFixture()
        let request = fixture.request
        XCTAssertAccepted(fixture.reducer.admit(request))
        let startSequence = fixture.reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(fixture.reducer.reduce(event(startSequence, request, .requestStarted)))

        let coordinate = try XCTUnwrap(request.variableExpansionRequest?.coordinate)
        let wrongComponents = ["locals", "0", "other"]
        let wrongToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: wrongComponents
        ))
        let wrongRequest = try XCTUnwrap(DebuggerVariableExpansionRequest(
            coordinate: coordinate,
            token: wrongToken,
            pathComponents: wrongComponents,
            depth: 1
        ))
        let before = fixture.reducer.state

        XCTAssertEqual(
            fixture.reducer.reduce(event(
                startSequence + 1,
                request,
                .variableChildrenRefreshed(
                    request: wrongRequest,
                    snapshot: fixture.childSnapshot
                )
            )),
            .rejected(.invalidPayload)
        )
        XCTAssertEqual(fixture.reducer.state, before)
    }

    func testVariableExpansionCancellationFailureAndRetryAreExactAndStaleSafe() throws {
        var cancelled = try variableExpansionFixture()
        let cancelledRequest = cancelled.request
        XCTAssertAccepted(cancelled.reducer.admit(cancelledRequest))
        let cancellationSequence = cancelled.reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(cancelled.reducer.reduce(event(
            cancellationSequence,
            cancelledRequest,
            .requestCancelled(.cancelledBeforeWrite)
        )))
        XCTAssertEqual(
            try variableExpansionState(in: cancelled.reducer, request: cancelledRequest),
            .notLoaded
        )

        var failed = try variableExpansionFixture()
        let firstRequest = failed.request
        XCTAssertAccepted(failed.reducer.admit(firstRequest))
        let startSequence = failed.reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(failed.reducer.reduce(event(startSequence, firstRequest, .requestStarted)))
        let diagnostic = DebuggerDiagnostic.make(
            code: .operationFailed,
            severity: .error,
            rawText: "/private/tmp/secret: native child read failed at 0x1234",
            operation: .expandVariableChildren,
            targetDisposition: .stopped(processID: 88)
        )
        XCTAssertAccepted(failed.reducer.reduce(event(
            startSequence + 1,
            firstRequest,
            .requestFailed(diagnostic)
        )))
        XCTAssertEqual(
            try variableExpansionState(in: failed.reducer, request: firstRequest),
            .failed(reason: "LLDB child read failed.")
        )

        let retry = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: firstRequest.id.sequence + 1),
            operation: .expandVariableChildren,
            expectedSession: failed.reducer.state.sessionCoordinate,
            requiredStop: failed.reducer.state.stopCoordinate,
            targetAuthority: firstRequest.targetAuthority,
            variableExpansionRequest: firstRequest.variableExpansionRequest
        )
        XCTAssertAccepted(failed.reducer.admit(retry))
        XCTAssertEqual(try variableExpansionState(in: failed.reducer, request: retry), .loading)
        let beforeStale = failed.reducer.state
        XCTAssertEqual(
            failed.reducer.reduce(event(
                startSequence + 2,
                firstRequest,
                .variableChildrenRefreshed(
                    request: firstRequest.variableExpansionRequest!,
                    snapshot: failed.childSnapshot
                )
            )),
            .rejected(.wrongRequest)
        )
        XCTAssertEqual(failed.reducer.state, beforeStale)
    }

    func testCancellationBeforeWritePreservesStateAndAfterWriteInvalidatesEpoch() {
        var beforeWriteReducer = makeStoppedReducer(data: sampleStoppedData)
        let beforeWriteRequest = request(
            sequence: 3,
            operation: .continue,
            session: beforeWriteReducer.state.sessionCoordinate,
            stop: beforeWriteReducer.state.stopCoordinate
        )
        XCTAssertAccepted(beforeWriteReducer.admit(beforeWriteRequest))
        let beforeCancellation = beforeWriteReducer.state
        XCTAssertAccepted(beforeWriteReducer.reduce(event(
            7,
            beforeWriteRequest,
            .requestCancelled(.cancelledBeforeWrite)
        )))
        XCTAssertNil(beforeWriteReducer.state.pendingRequest)
        XCTAssertEqual(beforeWriteReducer.state.processPhase, beforeCancellation.processPhase)
        XCTAssertEqual(beforeWriteReducer.state.stopRevision, beforeCancellation.stopRevision)
        XCTAssertEqual(beforeWriteReducer.state.stoppedData, beforeCancellation.stoppedData)
        XCTAssertFalse(beforeWriteReducer.state.isInvalidated)

        var afterWriteReducer = makeStoppedReducer(data: sampleStoppedData)
        let afterWriteRequest = request(
            sequence: 3,
            operation: .continue,
            session: afterWriteReducer.state.sessionCoordinate,
            stop: afterWriteReducer.state.stopCoordinate
        )
        XCTAssertAccepted(afterWriteReducer.admit(afterWriteRequest))
        XCTAssertAccepted(afterWriteReducer.reduce(event(7, afterWriteRequest, .requestStarted)))
        XCTAssertAccepted(afterWriteReducer.reduce(event(
            8,
            afterWriteRequest,
            .requestCancelled(.invalidatedAfterWrite(
                reason: .cancellationAfterWrite,
                target: .unknown
            ))
        )))
        XCTAssertTrue(afterWriteReducer.state.isInvalidated)
        XCTAssertEqual(afterWriteReducer.state.processPhase, .invalidated)
        XCTAssertNil(afterWriteReducer.state.pendingRequest)
        XCTAssertNil(afterWriteReducer.state.stopRevision)
        XCTAssertNil(afterWriteReducer.state.stoppedData)
        XCTAssertEqual(afterWriteReducer.state.targetDisposition, .unknown)
    }

    func testSessionInvalidationClearsAuthorityAndBlocksResurrection() {
        var reducer = makeStoppedReducer(data: sampleStoppedData)
        let invalidation = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: DebuggerEventSequence(
                rawValue: reducer.state.lastAcceptedEventSequence.rawValue + 1
            ),
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: reducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .sessionInvalidated(sampleDiagnostic)
        )
        XCTAssertAccepted(reducer.reduce(invalidation))
        XCTAssertTrue(reducer.state.isInvalidated)
        XCTAssertEqual(reducer.state.processPhase, .invalidated)
        XCTAssertNil(reducer.state.stopRevision)
        XCTAssertNil(reducer.state.stoppedData)
        XCTAssertNil(reducer.state.pendingRequest)
        XCTAssertEqual(reducer.state.targetDisposition, .unknown)
        let invalidated = reducer.state

        let oldLaunch = request(
            sequence: 99,
            operation: .launch,
            session: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: invalidated.lifecycleRevision
            )
        )
        XCTAssertEqual(reducer.admit(oldLaunch), .rejected(.invalidatedSession))
        XCTAssertEqual(
            reducer.reduce(event(
                invalidated.lastAcceptedEventSequence.rawValue + 1,
                oldLaunch,
                .processRunning(observedPID: 88)
            )),
            .rejected(.invalidatedSession)
        )
        XCTAssertEqual(reducer.state, invalidated)
    }

    func testObservedExitIsTerminalAndClearsStoppedAuthority() {
        var reducer = makeStoppedReducer(data: sampleStoppedData)
        let terminate = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .terminate,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(terminate))
        let eventSequence = reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(reducer.reduce(event(eventSequence, terminate, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            eventSequence + 1,
            terminate,
            .processExited(observedPID: 88, exitCode: 0)
        )))
        XCTAssertEqual(reducer.state.lifecycleRevision.rawValue, 2)
        XCTAssertEqual(reducer.state.processPhase, .exited(processID: 88, code: 0))
        XCTAssertEqual(reducer.state.targetDisposition, .exited(code: 0))
        XCTAssertTrue(reducer.state.isInvalidated)
        XCTAssertNil(reducer.state.stopRevision)
        XCTAssertNil(reducer.state.stoppedData)
        XCTAssertNil(reducer.state.pendingRequest)
    }

    func testRuntimeModuleRefreshPublishesCompleteInventoryTransactionally() throws {
        var reducer = makeStoppedReducer()
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.newStop))
        let refresh = request(
            sequence: 2,
            operation: .refreshRuntimeModules,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )

        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.refreshInProgress))
        XCTAssertAccepted(reducer.reduce(event(4, refresh, .requestStarted)))
        let payload = runtimeModulesPayload()
        XCTAssertAccepted(reducer.reduce(event(5, refresh, .runtimeModulesRefreshed(payload))))

        let inventory = try XCTUnwrap(reducer.runtimeModuleInventoryState.availableInventory)
        XCTAssertEqual(inventory.stop, reducer.state.stopCoordinate)
        XCTAssertEqual(inventory.processID, 88)
        XCTAssertEqual(inventory.observedStopID, 77)
        XCTAssertEqual(inventory.modules.map(\.observation), payload.observations)
        XCTAssertEqual(reducer.runtimeModuleInventoryState.inventoryRevision.rawValue, 1)
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authorityRevision.rawValue, 3)
        XCTAssertAccepted(reducer.reduce(event(
            6,
            refresh,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))
    }

    func testSameStopRuntimeModuleRefreshRejectsAdapterGenerationChangeTransactionally() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let refresh = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .refreshRuntimeModules,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        let startSequence = reducer.state.lastAcceptedEventSequence.rawValue + 1
        XCTAssertAccepted(reducer.reduce(event(startSequence, refresh, .requestStarted)))
        let before = reducer

        XCTAssertEqual(
            reducer.reduce(event(
                startSequence + 1,
                refresh,
                .runtimeModulesRefreshed(runtimeModulesPayload(adapterGeneration: 2))
            )),
            .rejected(.invalidPayload)
        )
        XCTAssertEqual(reducer, before)
    }

    func testRefreshExpressionAndResumeAdmissionsInstallMonotonicUnavailableTombstones() throws {
        var refreshReducer = try makeReducerWithAvailableRuntimeModules()
        let oldAuthorityRevision = refreshReducer.runtimeModuleInventoryState.authorityRevision
        let refresh = request(
            sequence: refreshReducer.state.lastAdmittedRequestSequence + 1,
            operation: .refreshRuntimeModules,
            session: refreshReducer.state.sessionCoordinate,
            stop: refreshReducer.state.stopCoordinate
        )
        XCTAssertAccepted(refreshReducer.admit(refresh))
        XCTAssertGreaterThan(refreshReducer.runtimeModuleInventoryState.authorityRevision, oldAuthorityRevision)
        XCTAssertEqual(refreshReducer.runtimeModuleInventoryState.authority, .unavailable(.refreshInProgress))

        var expressionReducer = try makeReducerWithAvailableRuntimeModules()
        let expression = request(
            sequence: expressionReducer.state.lastAdmittedRequestSequence + 1,
            operation: .evaluateExpression,
            session: expressionReducer.state.sessionCoordinate,
            stop: expressionReducer.state.stopCoordinate
        )
        XCTAssertAccepted(expressionReducer.admit(expression))
        XCTAssertEqual(
            expressionReducer.runtimeModuleInventoryState.authority,
            .unavailable(.expressionEvaluationAdmitted)
        )

        var resumeReducer = try makeReducerWithAvailableRuntimeModules()
        let resume = request(
            sequence: resumeReducer.state.lastAdmittedRequestSequence + 1,
            operation: .continue,
            session: resumeReducer.state.sessionCoordinate,
            stop: resumeReducer.state.stopCoordinate
        )
        XCTAssertAccepted(resumeReducer.admit(resume))
        XCTAssertEqual(
            resumeReducer.runtimeModuleInventoryState.authority,
            .unavailable(.resumeCapableOperationAdmitted)
        )
    }

    func testRuntimeModuleRefreshFailureCannotResurrectPriorSameStopInventory() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let previousInventoryRevision = reducer.runtimeModuleInventoryState.inventoryRevision
        let refresh = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .refreshRuntimeModules,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertAccepted(reducer.reduce(event(7, refresh, .requestStarted)))
        let failure = DebuggerDiagnostic.make(
            code: .operationFailed,
            severity: .error,
            rawText: "module collection failed",
            operation: .refreshRuntimeModules,
            targetDisposition: .stopped(processID: 88)
        )
        XCTAssertAccepted(reducer.reduce(event(8, refresh, .requestFailed(failure))))

        guard case .unavailable(.refreshFailed(let evidence)) = reducer.runtimeModuleInventoryState.authority else {
            return XCTFail("Expected refresh-failed tombstone")
        }
        XCTAssertEqual(evidence.code, .collectionFailed)
        XCTAssertEqual(reducer.runtimeModuleInventoryState.inventoryRevision, previousInventoryRevision)
        XCTAssertNil(reducer.runtimeModuleInventoryState.availableInventory)
    }

    func testRuntimeModuleAuthorityTracksRunningNewStopExitAndInvalidation() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let resume = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(resume))
        XCTAssertAccepted(reducer.reduce(event(7, resume, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(8, resume, .processRunning(observedPID: 88))))
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.running))
        XCTAssertAccepted(reducer.reduce(event(9, resume, .processStopped(observedPID: 88, reason: .step))))
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.newStop))
        XCTAssertEqual(reducer.runtimeModuleInventoryState.currentStop, reducer.state.stopCoordinate)
        XCTAssertAccepted(reducer.reduce(event(
            10,
            resume,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))

        let terminate = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .terminate,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(terminate))
        XCTAssertAccepted(reducer.reduce(event(11, terminate, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(12, terminate, .processExited(observedPID: 88, exitCode: 0))))
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.terminal))
        XCTAssertTrue(reducer.runtimeModuleInventoryState.activeModules.isEmpty)

        var invalidated = try makeReducerWithAvailableRuntimeModules()
        let invalidation = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: DebuggerEventSequence(
                rawValue: invalidated.state.lastAcceptedEventSequence.rawValue + 1
            ),
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: invalidated.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .sessionInvalidated(sampleDiagnostic)
        )
        XCTAssertAccepted(invalidated.reduce(invalidation))
        XCTAssertEqual(
            invalidated.runtimeModuleInventoryState.authority,
            .unavailable(.sessionInvalidated)
        )
        XCTAssertTrue(invalidated.runtimeModuleInventoryState.activeModules.isEmpty)
    }

    func testRuntimeModuleAuthorityTracksContinueRunningDirectlyToExit() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let resume = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(resume))
        XCTAssertAccepted(reducer.reduce(event(7, resume, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(8, resume, .processRunning(observedPID: 88))))

        XCTAssertAccepted(
            reducer.reduce(event(9, resume, .processExited(observedPID: 88, exitCode: 9)))
        )
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.terminal))
        XCTAssertTrue(reducer.runtimeModuleInventoryState.activeModules.isEmpty)
        XCTAssertEqual(reducer.state.targetDisposition, .exited(code: 9))
    }

    func testExitBeforeFirstStopPublishesTerminalRuntimeModuleAuthority() {
        var reducer = makeReducer()
        let launch = request(sequence: 1, operation: .launch, session: reducer.state.sessionCoordinate)
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(2, launch, .sessionOpened(observedPID: 88))))

        XCTAssertAccepted(
            reducer.reduce(event(3, launch, .processExited(observedPID: 88, exitCode: 78)))
        )
        XCTAssertEqual(reducer.runtimeModuleInventoryState.authority, .unavailable(.terminal))
        XCTAssertTrue(reducer.runtimeModuleInventoryState.activeModules.isEmpty)
        XCTAssertEqual(reducer.state.targetDisposition, .exited(code: 78))
    }

    func testRejectedRuntimeModulePayloadLeavesBothReducersByteIdentical() throws {
        var reducer = makeStoppedReducer()
        let refresh = request(
            sequence: 2,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertAccepted(reducer.reduce(event(4, refresh, .requestStarted)))
        let before = reducer

        XCTAssertEqual(
            reducer.reduce(event(5, refresh, .runtimeModulesRefreshed(runtimeModulesPayload()))),
            .rejected(.invalidPayload)
        )
        XCTAssertEqual(reducer, before)
    }

    func testLogicalBreakpointReconcileOperationRequiresExactStopWithoutTombstoningRuntimeAuthority() throws {
        var missingStopReducer = try makeReducerWithAvailableRuntimeModules()
        let missingStopBefore = missingStopReducer
        let missingStop = request(
            sequence: missingStopReducer.state.lastAdmittedRequestSequence + 1,
            operation: .reconcileLogicalBreakpoints,
            session: missingStopReducer.state.sessionCoordinate
        )
        XCTAssertEqual(missingStopReducer.admit(missingStop), .rejected(.missingStop))
        XCTAssertEqual(missingStopReducer, missingStopBefore)

        var staleStopReducer = try makeReducerWithAvailableRuntimeModules()
        let staleStopBefore = staleStopReducer
        let staleStop = DebuggerStopCoordinate(
            session: staleStopReducer.state.sessionCoordinate,
            stopRevision: .init(rawValue: 999)
        )
        let staleRequest = request(
            sequence: staleStopReducer.state.lastAdmittedRequestSequence + 1,
            operation: .reconcileLogicalBreakpoints,
            session: staleStopReducer.state.sessionCoordinate,
            stop: staleStop
        )
        XCTAssertEqual(staleStopReducer.admit(staleRequest), .rejected(.staleStop))
        XCTAssertEqual(staleStopReducer, staleStopBefore)

        var exactReducer = try makeReducerWithAvailableRuntimeModules()
        let runtimeBefore = exactReducer.runtimeModuleInventoryState
        let breakpointsBefore = exactReducer.breakpointBindingState
        let exactRequest = request(
            sequence: exactReducer.state.lastAdmittedRequestSequence + 1,
            operation: .reconcileLogicalBreakpoints,
            session: exactReducer.state.sessionCoordinate,
            stop: exactReducer.state.stopCoordinate
        )
        XCTAssertAccepted(exactReducer.admit(exactRequest))
        XCTAssertEqual(exactReducer.runtimeModuleInventoryState, runtimeBefore)
        XCTAssertEqual(exactReducer.breakpointBindingState, breakpointsBefore)
    }

    func testLogicalBreakpointObservationAndPlanAdmissionIsAtomic() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let fixture = try makeLogicalReconcileFixture(for: reducer)
        let runtimeBefore = reducer.runtimeModuleInventoryState

        XCTAssertTrue(reducer.admitLogicalBreakpointReconciliation(
            observation: fixture.observation,
            plan: fixture.plan
        ))
        XCTAssertEqual(
            reducer.breakpointBindingState.resolutionObservation,
            fixture.observation
        )
        XCTAssertEqual(reducer.breakpointBindingState.pendingPlan, fixture.plan)
        XCTAssertEqual(reducer.runtimeModuleInventoryState, runtimeBefore)
    }

    func testLogicalBreakpointDuplicateObservationCanAdmitRetryPlan() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let fixture = try makeLogicalReconcileFixture(for: reducer)
        XCTAssertTrue(reducer.admitLogicalBreakpointReconciliation(
            observation: fixture.observation,
            plan: fixture.plan
        ))
        XCTAssertTrue(reducer.cancelLogicalBreakpointBindingBeforeWrite(
            transactionID: fixture.plan.transactionID
        ))
        let retry = try makeLogicalPlan(
            for: fixture,
            transactionUUID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        XCTAssertTrue(reducer.admitLogicalBreakpointReconciliation(
            observation: fixture.observation,
            plan: retry
        ))
        XCTAssertEqual(reducer.breakpointBindingState.resolutionObservation, fixture.observation)
        XCTAssertEqual(reducer.breakpointBindingState.pendingPlan, retry)
    }

    func testLogicalBreakpointAtomicAdmissionFailureLeavesBothReducersByteIdentical() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let fixture = try makeLogicalReconcileFixture(for: reducer)
        let rejectedPlan = try makeLogicalPlan(
            for: fixture,
            transactionUUID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            resolutionObservationDigest: logicalDigest(0xEE)
        )
        let before = reducer

        XCTAssertFalse(reducer.admitLogicalBreakpointReconciliation(
            observation: fixture.observation,
            plan: rejectedPlan
        ))
        XCTAssertEqual(reducer, before)
    }

    func testPendingLogicalBreakpointPlanFencesResumeWithoutTombstoningAuthority() throws {
        var reducer = try makeReducerWithAvailableRuntimeModules()
        let fixture = try makeLogicalReconcileFixture(for: reducer)
        XCTAssertTrue(reducer.admitLogicalBreakpointReconciliation(
            observation: fixture.observation,
            plan: fixture.plan
        ))
        let beforeResume = reducer
        let resume = request(
            sequence: reducer.state.lastAdmittedRequestSequence + 1,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )

        XCTAssertEqual(reducer.admit(resume), .rejected(.invalidTransition))
        XCTAssertEqual(reducer, beforeResume)
    }

    // MARK: - Fixtures

    private struct LogicalReconcileFixture {
        let observation: DebuggerBreakpointResolutionObservation
        let mappingKey: DebuggerRuntimeMappingProjectionKey
        let catalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
        let resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate
        let adapterGeneration: UInt64
        let observedPID: Int32
        let observedStopID: UInt32
        let plan: DebuggerBreakpointBindingPlan
    }

    private func makeLogicalReconcileFixture(
        for reducer: DebuggerSessionReducer
    ) throws -> LogicalReconcileFixture {
        let runtime = reducer.runtimeModuleInventoryState
        let binding = reducer.breakpointBindingState
        let stop = try XCTUnwrap(reducer.state.stopCoordinate)
        let inventory = try XCTUnwrap(runtime.availableInventory)
        let adapterGeneration = try XCTUnwrap(binding.adapterGeneration)
        let observedPID = try XCTUnwrap(binding.observedPID)
        let observedStopID = try XCTUnwrap(binding.observedStopID)
        let workspaceCatalogRevision = DebuggerWorkspaceArtifactCatalogRevision(rawValue: 7)
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: observedPID,
            authorityRevision: runtime.authorityRevision,
            inventoryRevision: inventory.revision,
            workspaceCatalogRevision: workspaceCatalogRevision
        )
        let workspaceID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let catalogCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            revision: 1
        )
        let resolutionCatalogCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 1),
            workspaceArtifactCatalogRevision: workspaceCatalogRevision
        )
        let observation = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: catalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            mappingKey: mappingKey,
            expectedSpecifications: [],
            results: []
        ))
        let plan = try XCTUnwrap(DebuggerBreakpointBindingPlan(
            transactionID: .init(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            sessionEpoch: stop.session.epoch,
            adapterGeneration: adapterGeneration,
            stopCoordinate: stop,
            observedPID: observedPID,
            observedStopID: observedStopID,
            logicalCatalogCoordinate: catalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            resolutionObservationDigest: observation.canonicalDigest,
            mappingKey: mappingKey,
            bindings: [],
            ownershipTagDigest: logicalDigest(0x71),
            canonicalPlanDigest: logicalDigest(0x81)
        ))
        return LogicalReconcileFixture(
            observation: observation,
            mappingKey: mappingKey,
            catalogCoordinate: catalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            adapterGeneration: adapterGeneration,
            observedPID: observedPID,
            observedStopID: observedStopID,
            plan: plan
        )
    }

    private func makeLogicalPlan(
        for fixture: LogicalReconcileFixture,
        transactionUUID: UUID,
        resolutionObservationDigest: DebuggerBreakpointDigest? = nil
    ) throws -> DebuggerBreakpointBindingPlan {
        try XCTUnwrap(DebuggerBreakpointBindingPlan(
            transactionID: .init(rawValue: transactionUUID),
            sessionEpoch: fixture.mappingKey.stopCoordinate.session.epoch,
            adapterGeneration: fixture.adapterGeneration,
            stopCoordinate: fixture.mappingKey.stopCoordinate,
            observedPID: fixture.observedPID,
            observedStopID: fixture.observedStopID,
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            resolutionObservationDigest: resolutionObservationDigest
                ?? fixture.observation.canonicalDigest,
            mappingKey: fixture.mappingKey,
            bindings: [],
            ownershipTagDigest: logicalDigest(0x71),
            canonicalPlanDigest: logicalDigest(0x81)
        ))
    }

    private func logicalDigest(_ byte: UInt8) -> DebuggerBreakpointDigest {
        DebuggerBreakpointDigest(Data(repeating: byte, count: 32))!
    }

    private var sampleStoppedData: DebuggerStoppedData {
        DebuggerStoppedData(
            threads: .available([
                DebuggerStoppedThread(
                    identifier: 1,
                    queueName: "main",
                    stopReason: .step,
                    isSelected: true,
                    topFrameAddress: 0x1000,
                    topFrameFunctionName: "entry"
                )
            ]),
            frames: .available([
                DebuggerStoppedFrame(
                    identifier: 0,
                    address: 0x1000,
                    functionName: "entry",
                    moduleName: "Fixture",
                    sourceLocation: nil
                )
            ]),
            registers: .available([
                DebuggerStoppedRegister(
                    name: "pc",
                    value: "0x1000",
                    role: "program-counter",
                    group: .generalPurpose
                )
            ]),
            memoryPreviews: .available([
                DebuggerStoppedMemoryPreview(
                    address: 0x1000,
                    bytes: [0x00, 0x01],
                    label: "instruction"
                )
            ]),
            selectedThreadID: 1,
            selectedFrameID: 0,
            currentProgramCounter: 0x1000
        )
    }

    private var sampleDiagnostic: DebuggerDiagnostic {
        DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: "adapter generation invalidated",
            targetDisposition: .unknown
        )
    }

    private func runtimeModulesPayload(
        adapterGeneration: UInt64 = 1
    ) -> DebuggerRuntimeModulesRefreshPayload {
        let range = DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 0,
            sectionName: "__TEXT",
            staticStart: 0x1000,
            runtimeStart: 0x9000,
            byteCount: 0x100,
            permissions: 5
        )!
        let observation = DebuggerRuntimeModuleObservation(
            uuid: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            processID: 88,
            observedStopID: 77,
            mappedRanges: [range],
            fullPath: "/tmp/Fixture",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: 1,
            fingerprintSHA256: Data(repeating: 0xA5, count: 32)
        )!
        return DebuggerRuntimeModulesRefreshPayload(
            observations: [observation],
            observedStopID: 77,
            processID: 88,
            adapterGeneration: adapterGeneration
        )
    }

    private func makeReducerWithAvailableRuntimeModules() throws -> DebuggerSessionReducer {
        var reducer = makeStoppedReducer()
        let refresh = request(
            sequence: 2,
            operation: .refreshRuntimeModules,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertAccepted(reducer.reduce(event(4, refresh, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(5, refresh, .runtimeModulesRefreshed(runtimeModulesPayload()))))
        XCTAssertAccepted(reducer.reduce(event(
            6,
            refresh,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))
        _ = try XCTUnwrap(reducer.runtimeModuleInventoryState.availableInventory)
        return reducer
    }

    private func makeReducer(
        capabilities: DebuggerTransportCapabilities = .persistentCLI(
            attachPolicyReason: "Attach remains closed in WS-19."
        )
    ) -> DebuggerSessionReducer {
        DebuggerSessionReducer(
            epoch: epoch,
            capabilities: capabilities
        )
    }

    private func allOperationsEnabledCapabilities() -> DebuggerTransportCapabilities {
        DebuggerTransportCapabilities(
            operationStates: Dictionary(
                uniqueKeysWithValues: DebuggerOperation.allCases.map {
                    ($0, DebuggerOperationCapability.supportedAndObserved)
                }
            ),
            mechanics: .persistentCLI
        )
    }

    private func makeStoppedReducer(
        data: DebuggerStoppedData? = nil
    ) -> DebuggerSessionReducer {
        var reducer = makeReducer()
        let launch = request(
            sequence: 1,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            2,
            launch,
            .processStopped(observedPID: 88, reason: .unknown("entry"))
        )))
        XCTAssertAccepted(reducer.reduce(event(
            3,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))
        if let data {
            let refresh = request(
                sequence: 2,
                operation: .refreshSnapshot,
                session: reducer.state.sessionCoordinate,
                stop: reducer.state.stopCoordinate
            )
            XCTAssertAccepted(reducer.admit(refresh))
            XCTAssertAccepted(reducer.reduce(event(4, refresh, .requestStarted)))
            XCTAssertAccepted(reducer.reduce(event(5, refresh, .stoppedDataRefreshed(data))))
            XCTAssertAccepted(reducer.reduce(event(
                6,
                refresh,
                .requestCompleted(.completed(target: .stopped(processID: 88)))
            )))
        }
        return reducer
    }

    private func reducerWithPendingRefresh() -> DebuggerSessionReducer {
        var reducer = makeStoppedReducer()
        let refresh = request(
            sequence: 2,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        return reducer
    }

    private func request(
        sequence: UInt64,
        operation: DebuggerOperation,
        session: DebuggerSessionCoordinate,
        stop: DebuggerStopCoordinate? = nil,
        targetAuthority: DebuggerSessionTargetAuthority? = nil,
        variableExpansionRequest: DebuggerVariableExpansionRequest? = nil
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: DebuggerRequestID(epoch: session.epoch, sequence: sequence),
            operation: operation,
            expectedSession: session,
            requiredStop: stop,
            targetAuthority: targetAuthority,
            variableExpansionRequest: variableExpansionRequest
        )
    }

    private struct VariableExpansionFixture {
        var reducer: DebuggerSessionReducer
        let request: DebuggerRequestContext
        let childSnapshot: DebuggerVariableSnapshot
    }

    private func variableExpansionFixture() throws -> VariableExpansionFixture {
        var reducer = makeReducer(capabilities: allOperationsEnabledCapabilities())
        let authority = launchedAuthority(processID: 88)
        let launch = request(
            sequence: 1,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            2,
            launch,
            .authorizedSessionOpened(observedPID: 88, authority: authority)
        )))
        XCTAssertAccepted(reducer.reduce(event(
            3,
            launch,
            .processStopped(observedPID: 88, reason: .breakpoint(address: 0x1000))
        )))
        XCTAssertAccepted(reducer.reduce(event(
            4,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))

        let stop = try XCTUnwrap(reducer.state.stopCoordinate)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: 0x1000,
            canonicalFunctionName: "entry"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        let parentComponents = ["locals", "0", "aggregate"]
        let parentToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: parentComponents
        ))
        let parent = try XCTUnwrap(DebuggerVariableNode(
            id: parentToken,
            name: "aggregate",
            typeName: "Fixture",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: parentComponents
        ))
        let rootSnapshot = try XCTUnwrap(DebuggerVariableSnapshot(
            coordinate: coordinate,
            scope: .locals,
            nodes: [parent],
            depth: 0,
            wasTruncated: false
        ))
        let childComponents = parentComponents + ["0", "left"]
        let childToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: childComponents
        ))
        let child = try XCTUnwrap(DebuggerVariableNode(
            id: childToken,
            name: "left",
            typeName: "Int",
            value: .value("7"),
            childCount: 0,
            pathComponents: childComponents
        ))
        let childSnapshot = try XCTUnwrap(DebuggerVariableSnapshot(
            coordinate: coordinate,
            scope: .locals,
            nodes: [child],
            depth: 1,
            wasTruncated: false
        ))
        let stoppedData = DebuggerStoppedData(
            threads: .available([]),
            frames: .available([]),
            registers: .available([]),
            memoryPreviews: .available([]),
            variables: .available([rootSnapshot]),
            selectedThreadID: 1,
            selectedFrameID: 0,
            currentProgramCounter: 0x1000
        )
        let refresh = request(
            sequence: 2,
            operation: .refreshSnapshot,
            session: reducer.state.sessionCoordinate,
            stop: stop,
            targetAuthority: authority
        )
        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertAccepted(reducer.reduce(event(5, refresh, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(6, refresh, .stoppedDataRefreshed(stoppedData))))
        XCTAssertAccepted(reducer.reduce(event(
            7,
            refresh,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))

        let expansion = try XCTUnwrap(DebuggerVariableExpansionRequest(
            coordinate: coordinate,
            token: parentToken,
            pathComponents: parentComponents,
            depth: 1
        ))
        return VariableExpansionFixture(
            reducer: reducer,
            request: request(
                sequence: 3,
                operation: .expandVariableChildren,
                session: reducer.state.sessionCoordinate,
                stop: stop,
                targetAuthority: authority,
                variableExpansionRequest: expansion
            ),
            childSnapshot: childSnapshot
        )
    }

    private func variableExpansionState(
        in reducer: DebuggerSessionReducer,
        request: DebuggerRequestContext
    ) throws -> DebuggerVariableChildExpansionState {
        let expansion = try XCTUnwrap(request.variableExpansionRequest)
        let data = try XCTUnwrap(reducer.state.stoppedData)
        guard case .available(let snapshots) = data.variables else {
            throw NSError(domain: "DebuggerEventReducerTests", code: 1)
        }
        let scope = try XCTUnwrap(snapshots.first(where: {
            $0.scope.rawValue == expansion.pathComponents.first
        }))
        return try XCTUnwrap(scope.childExpansion(matching: expansion))
    }

    private func expandedChildren(
        in reducer: DebuggerSessionReducer,
        request: DebuggerRequestContext
    ) throws -> [DebuggerVariableNode] {
        let expansion = try XCTUnwrap(request.variableExpansionRequest)
        let data = try XCTUnwrap(reducer.state.stoppedData)
        guard case .available(let snapshots) = data.variables,
              let scope = snapshots.first(where: {
                  $0.scope.rawValue == expansion.pathComponents.first
              }) else {
            throw NSError(domain: "DebuggerEventReducerTests", code: 2)
        }
        return try XCTUnwrap(scope.nodes.first(where: {
            $0.id == expansion.token && $0.pathComponents == expansion.pathComponents
        })?.children)
    }

    private func launchedAuthority(
        processID: Int32
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(
            origin: .launched(
                DebuggerLaunchTargetAuthority(identity: processIdentity(processID: processID))
            )
        )
    }

    private func attachedAuthority(
        processID: Int32
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(origin: .attached(processIdentity(processID: processID)))
    }

    private func processIdentity(processID: Int32) -> DebuggerLocalProcessIdentity {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(
                seconds: UInt64(10_000 + processID),
                microseconds: UInt32(processID)
            )!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeEventReducerFixture-\(processID)",
            executableDeviceID: 7,
            executableFileID: UInt64(20_000 + processID),
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        )!
    }

    private func event(
        _ sequence: UInt64,
        _ context: DebuggerRequestContext,
        _ payload: DebuggerEventPayload,
        epoch: DebuggerSessionEpoch? = nil,
        requestID: DebuggerRequestID? = nil,
        operation: DebuggerOperation? = nil,
        lifecycle: DebuggerLifecycleRevision? = nil,
        stop: DebuggerStopRevision? = nil
    ) -> DebuggerEventEnvelope {
        DebuggerEventEnvelope(
            sessionEpoch: epoch ?? context.id.epoch,
            eventSequence: DebuggerEventSequence(rawValue: sequence),
            requestID: requestID ?? context.id,
            operation: operation ?? context.operation,
            capturedLifecycleRevision: lifecycle
                ?? context.expectedSession.lifecycleRevision,
            boundStopRevision: stop ?? context.requiredStop?.stopRevision,
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
}

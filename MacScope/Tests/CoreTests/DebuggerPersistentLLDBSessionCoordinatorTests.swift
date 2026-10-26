import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class DebuggerPersistentLLDBSessionCoordinatorTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    )

    func testLaunchReducesStartedOpenedObservedStopAndCompletionInOrder() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 431,
                observedState: .stopped(processID: 431)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        let result = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )

        let executionCount = await executor.executionCount
        let executedOperation = await executor.executedContexts.first?.operation
        let projectionInput = await coordinator.projectionInput
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(executedOperation, .launch)
        XCTAssertEqual(result.requestID.sequence, 1)
        XCTAssertEqual(result.reducerState.lastAcceptedEventSequence.rawValue, 4)
        XCTAssertEqual(result.reducerState.observedProcessID, 431)
        XCTAssertEqual(
            result.reducerState.processPhase,
            .stopped(processID: 431, reason: .unknown("LLDB reported a stopped process."))
        )
        XCTAssertEqual(result.reducerState.stopRevision, DebuggerStopRevision(rawValue: 1))
        XCTAssertNil(result.reducerState.pendingRequest)
        XCTAssertEqual(projectionInput, result.reducerState)
    }

    func testStaleExpectedSessionIsRejectedBeforePreparationOrExecution() async throws {
        let executor = CoordinatorExecutorFake(results: [])
        let preparer = CoordinatorRequestPreparerFake()
        let coordinator = makeCoordinator(executor: executor, preparer: preparer)
        let initial = await coordinator.reducerState
        let stale = DebuggerSessionCoordinate(
            epoch: initial.epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 9)
        )

        do {
            _ = try await coordinator.perform(
                .launch,
                expectedSession: stale,
                requiredStop: nil
            )
            XCTFail("Expected stale lifecycle rejection.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
            XCTAssertEqual(failure.reducerRejection, .staleLifecycle)
        }

        let executionCount = await executor.executionCount
        let preparationCount = await preparer.preparationCount
        let finalState = await coordinator.reducerState
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(finalState, initial)
    }

    func testMissingAndWrongObservedPIDInvalidateWithoutFallback() async throws {
        let cases: [(Int32?, LLDBCLIObservedProcessState?)] = [
            (nil, nil),
            (nil, .stopped(processID: 812)),
            (811, .stopped(processID: 812)),
        ]

        for (observedPID, observedState) in cases {
            let executor = CoordinatorExecutorFake(results: [
                .success(response(
                    requestSequence: 1,
                    observedPID: observedPID,
                    observedState: observedState
                )),
            ])
            let coordinator = makeCoordinator(executor: executor)
            let initial = await coordinator.reducerState

            do {
                _ = try await coordinator.perform(
                    .launch,
                    expectedSession: initial.sessionCoordinate,
                    requiredStop: nil
                )
                XCTFail("Expected observed identity failure.")
            } catch let failure as PersistentLLDBSessionCoordinatorFailure {
                XCTAssertEqual(failure.code, .invalidObservedProcess)
            }

            let failed = await coordinator.reducerState
            XCTAssertTrue(failed.isInvalidated)
            XCTAssertEqual(failed.processPhase, .invalidated)
            XCTAssertEqual(failed.targetDisposition, .unknown)
            XCTAssertNil(failed.observedProcessID)
            XCTAssertNil(failed.pendingRequest)
            let executionCount = await executor.executionCount
            XCTAssertEqual(executionCount, 1)
        }
    }

    /// §4.88: every adapter invalidation names its cause in the typed failure, in its `detail`
    /// (which the controller puts in the panel error) and in the reducer's invalidation
    /// diagnostic. A timeout also names the exchange deadline that expired.
    func testTranscriptDiagnosticReachesTypedInvalidationAndReducer() async throws {
        for code in [LLDBCLITranscriptDiagnosticCode.ambiguousMarker, .ambiguousObservedPID, .ambiguousObservedProcessState] {
            let executor = CoordinatorExecutorFake(results: [.failure(PersistentLLDBCLIAdapterFailure(
                code: .invalidatedGeneration,
                requestID: DebuggerRequestID(epoch: epoch, sequence: 1),
                generation: 3,
                disposition: .invalidatedAfterWrite(reason: .framingLoss, target: .unknown),
                transcriptDiagnosticCode: code
            ))])
            let coordinator = makeCoordinator(executor: executor)
            let initial = await coordinator.reducerState
            do {
                _ = try await coordinator.perform(.launch, expectedSession: initial.sessionCoordinate, requiredStop: nil)
                XCTFail("Expected invalidation")
            } catch let failure as PersistentLLDBSessionCoordinatorFailure {
                XCTAssertEqual(failure.invalidationCause, .transcriptValidation(code))
                XCTAssertTrue(failure.detail.contains(code.rawValue))
                let state = await coordinator.reducerState
                XCTAssertTrue(try XCTUnwrap(state.lastDiagnostic).preview.contains(code.rawValue))
            }
        }
    }

    func testAdapterInvalidationNamesItsCauseForEveryReason() async throws {
        let requestID = DebuggerRequestID(epoch: epoch, sequence: 1)
        func adapterFailure(
            _ disposition: DebuggerRequestDisposition,
            requestID: DebuggerRequestID
        ) -> Error {
            PersistentLLDBCLIAdapterFailure(
                code: .invalidatedGeneration,
                requestID: requestID,
                generation: 3,
                disposition: disposition
            )
        }
        let reasons: [DebuggerTransportInvalidationReason] = [
            .timeoutAfterWrite, .endOfFileAfterWrite, .oversizedTranscript, .framingLoss,
            .adapterFailure,
        ]
        var cases: [(Error, (Duration) -> PersistentLLDBAdapterInvalidationCause)] = reasons.map {
            reason in
            (
                adapterFailure(
                    .invalidatedAfterWrite(reason: reason, target: .unknown),
                    requestID: requestID
                ),
                { deadline in
                    .transport(reason, deadline: reason == .timeoutAfterWrite ? deadline : nil)
                }
            )
        }
        cases.append((
            adapterFailure(
                .invalidatedAfterWrite(reason: .timeoutAfterWrite, target: .unknown),
                requestID: DebuggerRequestID(epoch: epoch, sequence: 99)
            ),
            { _ in .failureCorrelationLost }
        ))
        cases.append((
            adapterFailure(.completed(target: .unknown), requestID: requestID),
            { _ in .invalidDisposition }
        ))
        cases.append((CoordinatorTestError.unexpectedExecution, { _ in .unboundedDisposition }))

        for (error, expectedCause) in cases {
            let executor = CoordinatorExecutorFake(results: [.failure(error)])
            let coordinator = makeCoordinator(executor: executor)
            let initial = await coordinator.reducerState
            do {
                _ = try await coordinator.perform(
                    .launch,
                    expectedSession: initial.sessionCoordinate,
                    requiredStop: nil
                )
                XCTFail("Expected adapter invalidation for \(error).")
            } catch let failure as PersistentLLDBSessionCoordinatorFailure {
                let timeouts = await executor.executedTimeouts
                let deadline = try XCTUnwrap(timeouts.first)
                let cause = expectedCause(deadline)
                XCTAssertEqual(failure.code, .adapterInvalidated)
                XCTAssertEqual(failure.invalidationCause, cause)
                XCTAssertEqual(failure.detail, "adapterInvalidated: \(cause.summary)")
                let state = await coordinator.reducerState
                let diagnostic = try XCTUnwrap(state.lastDiagnostic)
                XCTAssertTrue(diagnostic.preview.contains(cause.summary), diagnostic.preview)
                if case .transport(.timeoutAfterWrite, _) = cause {
                    let rendered = PersistentLLDBAdapterInvalidationCause.render(deadline)
                    XCTAssertTrue(failure.detail.contains("\(rendered) exchange deadline"))
                }
            }
        }
        XCTAssertEqual(PersistentLLDBAdapterInvalidationCause.render(.seconds(10)), "10 s")
        XCTAssertEqual(PersistentLLDBAdapterInvalidationCause.render(.milliseconds(1_500)), "1500 ms")
    }

    func testAdapterPostWriteInvalidationInvalidatesReducerEpoch() async throws {
        let adapterFailure = PersistentLLDBCLIAdapterFailure(
            code: .invalidatedGeneration,
            requestID: DebuggerRequestID(epoch: epoch, sequence: 1),
            generation: 3,
            disposition: .invalidatedAfterWrite(
                reason: .timeoutAfterWrite,
                target: .unknown
            )
        )
        let executor = CoordinatorExecutorFake(results: [.failure(adapterFailure)])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.perform(
                .launch,
                expectedSession: initial.sessionCoordinate,
                requiredStop: nil
            )
            XCTFail("Expected adapter invalidation.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .adapterInvalidated)
        }

        let failed = await coordinator.reducerState
        XCTAssertTrue(failed.isInvalidated)
        XCTAssertEqual(failed.processPhase, .invalidated)
        XCTAssertEqual(failed.targetDisposition, .unknown)
        XCTAssertEqual(failed.lastAcceptedEventSequence.rawValue, 2)
        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, 1)
    }

    func testSynchronousStoppedRunControlMintsANewExactStop() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 902,
                observedState: .stopped(processID: 902)
            )),
            .success(response(
                requestSequence: 2,
                observedPID: 902,
                observedState: .stopped(processID: 902)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let oldStop = try XCTUnwrap(launched.reducerState.stopCoordinate)

        let resumed = try await coordinator.perform(
            .continue,
            expectedSession: oldStop.session,
            requiredStop: oldStop
        )

        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, 2)
        XCTAssertEqual(resumed.reducerState.lifecycleRevision.rawValue, 2)
        XCTAssertEqual(resumed.reducerState.stopRevision?.rawValue, 2)
        XCTAssertNotEqual(resumed.reducerState.stopCoordinate, oldStop)
        XCTAssertEqual(
            resumed.reducerState.processPhase,
            .stopped(processID: 902, reason: .unknown("LLDB reported a stopped process."))
        )
        XCTAssertNil(resumed.reducerState.pendingRequest)
        XCTAssertEqual(resumed.reducerState.lastAcceptedEventSequence.rawValue, 7)
    }

    func testStatusPollCompletesSameRunningWithoutDuplicateThenAuthorsNewStop() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 615,
                observedState: .running(processID: 615)
            )),
            .success(response(
                requestSequence: 2,
                observedPID: 615,
                observedState: .running(processID: 615)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: 615,
                observedState: .stopped(processID: 615)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )

        let unchanged = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: launched.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        XCTAssertEqual(unchanged.reducerState.lifecycleRevision.rawValue, 1)
        XCTAssertEqual(unchanged.reducerState.lastAcceptedEventSequence.rawValue, 6)
        XCTAssertEqual(unchanged.reducerState.processPhase, .running(processID: 615))
        let pollCommands = await executor.executedSemanticCommands[1]
        XCTAssertTrue(pollCommands.isEmpty)

        let stopped = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: unchanged.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        XCTAssertEqual(stopped.reducerState.lifecycleRevision.rawValue, 2)
        XCTAssertEqual(stopped.reducerState.stopRevision?.rawValue, 1)
        XCTAssertEqual(stopped.reducerState.lastAcceptedEventSequence.rawValue, 9)
        XCTAssertEqual(
            stopped.reducerState.processPhase,
            .stopped(processID: 615, reason: .unknown("LLDB reported a stopped process."))
        )
    }

    func testPauseWaitsForOneWrittenPollWithoutCancellingIt() async throws {
        let executor = CoordinatorExecutorFake(
            results: [
                .success(response(
                    requestSequence: 1,
                    observedPID: 716,
                    observedState: .running(processID: 716)
                )),
                .success(response(
                    requestSequence: 2,
                    observedPID: 716,
                    observedState: .running(processID: 716)
                )),
                .success(response(
                    requestSequence: 3,
                    observedPID: 716,
                    observedState: .stopped(processID: 716)
                )),
            ],
            blockedExecutionNumber: 2
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )

        let poll = Task {
            try await coordinator.perform(
                .pollProcessStatus,
                expectedSession: launched.reducerState.sessionCoordinate,
                requiredStop: nil
            )
        }
        while await executor.executionCount < 2 {
            await Task.yield()
        }

        let pause = Task {
            try await coordinator.perform(
                .pause,
                expectedSession: launched.reducerState.sessionCoordinate,
                requiredStop: nil
            )
        }
        for _ in 0..<10 { await Task.yield() }
        let countWhilePollIsWritten = await executor.executionCount
        XCTAssertEqual(countWhilePollIsWritten, 2)

        await executor.releaseBlockedExecution()
        let polled = try await poll.value
        let paused = try await pause.value

        XCTAssertEqual(polled.reducerState.processPhase, .running(processID: 716))
        XCTAssertEqual(
            paused.reducerState.processPhase,
            .stopped(processID: 716, reason: .unknown("LLDB reported a stopped process."))
        )
        let finalExecutionCount = await executor.executionCount
        XCTAssertEqual(finalExecutionCount, 3)
    }

    func testAttachRemainsPolicyDeniedWithoutPreparingOrExecuting() async throws {
        let executor = CoordinatorExecutorFake(results: [])
        let preparer = CoordinatorRequestPreparerFake()
        let coordinator = makeCoordinator(executor: executor, preparer: preparer)
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.perform(
                .attach,
                expectedSession: initial.sessionCoordinate,
                requiredStop: nil
            )
            XCTFail("Expected attach policy denial.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
            XCTAssertEqual(failure.reducerRejection, .unavailableOperation)
        }

        let preparationCount = await preparer.preparationCount
        let executionCount = await executor.executionCount
        let finalState = await coordinator.reducerState
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(finalState, initial)
    }

    func testRuntimeModuleRefreshReservesPhysicalRangeAndPublishesOnlyOneParentResult() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 541,
                observedState: .stopped(processID: 541)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: 541,
                observedState: .stopped(processID: 541)
            )),
            .success(response(
                requestSequence: 4,
                observedPID: 541,
                observedState: .stopped(processID: 541)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: 541,
                observedState: .stopped(processID: 541)
            )),
        ])
        let preparer = CoordinatorRequestPreparerFake()
        let coordinator = makeCoordinator(executor: executor, preparer: preparer)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)
        let observation = try runtimeModuleObservation(processID: 541, observedStopID: 77)

        let refreshed = try await coordinator.performRuntimeModuleRefresh(
            expectedSession: stop.session,
            requiredStop: stop
        ) { channel in
            _ = try await channel.execute(.testRequest)
            _ = try await channel.execute(.testRequest)
            _ = try await channel.cleanup(.testRequest) { _ in }
            return PersistentLLDBRuntimeModuleRefreshCollection(
                observations: [observation],
                observedPID: 541,
                observedStopID: 77,
                adapterGeneration: 1
            )
        }

        let executedSequences = await executor.executedContexts.map(\.id.sequence)
        let preparedContexts = await preparer.preparedContexts
        XCTAssertEqual(executedSequences, [1, 3, 4, 114])
        XCTAssertEqual(preparedContexts.map(\.id.sequence), [1])
        XCTAssertEqual(refreshed.requestID.sequence, 2)
        XCTAssertEqual(refreshed.reducerState.lastAcceptedEventSequence.rawValue, 7)
        XCTAssertNil(refreshed.reducerState.pendingRequest)
        let inventory = try XCTUnwrap(
            refreshed.reducerState.runtimeModuleInventoryState.availableInventory
        )
        XCTAssertEqual(inventory.modules.map(\.observation), [observation])
        XCTAssertEqual(inventory.observedStopID, 77)
    }

    func testRuntimeModuleRefreshReservationOverflowPrecedesAdmissionAndExecution() async throws {
        let executor = CoordinatorExecutorFake(results: [])
        let coordinator = makeCoordinator(
            executor: executor,
            initialRequestSequence: UInt64.max - 112
        )
        let initial = await coordinator.reducerState
        let claimedStop = DebuggerStopCoordinate(
            session: initial.sessionCoordinate,
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )

        do {
            _ = try await coordinator.performRuntimeModuleRefresh(
                expectedSession: initial.sessionCoordinate,
                requiredStop: claimedStop
            ) { _ in
                XCTFail("Collection must not begin when the complete sequence range cannot be reserved.")
                throw CoordinatorTestError.unexpectedExecution
            }
            XCTFail("Expected checked sequence exhaustion.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .requestSequenceExhausted)
            XCTAssertNil(failure.requestID)
        }

        let executionCount = await executor.executionCount
        let finalState = await coordinator.reducerState
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(finalState, initial)
    }

    func testRuntimeModuleRefreshWithProvenCleanupFailsBoundedlyWithoutInvalidatingStop() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 642,
                observedState: .stopped(processID: 642)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: 642,
                observedState: .stopped(processID: 642)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: 642,
                observedState: .stopped(processID: 642)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)

        do {
            _ = try await coordinator.performRuntimeModuleRefresh(
                expectedSession: stop.session,
                requiredStop: stop
            ) { channel in
                _ = try await channel.execute(.testRequest)
                _ = try await channel.cleanup(.testRequest) { _ in }
                throw CoordinatorTestError.collectionFailed
            }
            XCTFail("Expected bounded collection failure.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .responseProjectionFailed)
            XCTAssertEqual(failure.requestID?.sequence, 2)
        }

        let failed = await coordinator.reducerState
        XCTAssertFalse(failed.isInvalidated)
        XCTAssertEqual(failed.stopCoordinate, stop)
        XCTAssertNil(failed.pendingRequest)
        guard case .unavailable(.refreshFailed) = failed.runtimeModuleInventoryState.authority else {
            return XCTFail("A bounded refresh failure must leave a newer unavailable tombstone.")
        }
        XCTAssertEqual(failed.lastAcceptedEventSequence.rawValue, 6)
    }

    func testRuntimeModuleRefreshWithoutProvenCleanupInvalidatesSession() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 743,
                observedState: .stopped(processID: 743)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: 743,
                observedState: .stopped(processID: 743)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)

        do {
            _ = try await coordinator.performRuntimeModuleRefresh(
                expectedSession: stop.session,
                requiredStop: stop
            ) { channel in
                _ = try await channel.execute(.testRequest)
                throw CoordinatorTestError.collectionFailed
            }
            XCTFail("Expected unproven cleanup to invalidate the session.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .adapterInvalidated)
            XCTAssertEqual(failure.requestID?.sequence, 2)
        }

        let failed = await coordinator.reducerState
        XCTAssertTrue(failed.isInvalidated)
        XCTAssertEqual(failed.processPhase, .invalidated)
        XCTAssertNil(failed.pendingRequest)
    }

    func testRuntimeModuleRefreshSerializesConcurrentPhysicalExchangesAndKeepsCleanupFinal() async throws {
        let executor = CoordinatorExecutorFake(
            results: [
                .success(response(
                    requestSequence: 1,
                    observedPID: 844,
                    observedState: .stopped(processID: 844)
                )),
                .success(response(
                    requestSequence: 3,
                    observedPID: 844,
                    observedState: .stopped(processID: 844)
                )),
                .success(response(
                    requestSequence: 4,
                    observedPID: 844,
                    observedState: .stopped(processID: 844)
                )),
                .success(response(
                    requestSequence: 114,
                    observedPID: 844,
                    observedState: .stopped(processID: 844)
                )),
            ],
            blockedExecutionNumber: 2
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)
        let observation = try runtimeModuleObservation(processID: 844, observedStopID: 81)

        let refreshed = try await coordinator.performRuntimeModuleRefresh(
            expectedSession: stop.session,
            requiredStop: stop
        ) { channel in
            let first = Task { try await channel.execute(.testRequest) }
            while await executor.executionCount < 2 {
                await Task.yield()
            }
            let second = Task { try await channel.execute(.testRequest) }
            for _ in 0..<100 { await Task.yield() }
            let countWhileFirstIsSuspended = await executor.executionCount
            XCTAssertEqual(
                countWhileFirstIsSuspended,
                2,
                "A second physical exchange must not enter the adapter while the first is suspended."
            )
            await executor.releaseBlockedExecution()
            _ = try await first.value
            _ = try await second.value
            _ = try await channel.cleanup(.testRequest) { _ in }
            do {
                _ = try await channel.execute(.testRequest)
                XCTFail("Cleanup must be the final physical exchange.")
            } catch let failure as PersistentLLDBSessionCoordinatorFailure {
                XCTAssertEqual(failure.code, .requestSequenceExhausted)
            }
            return PersistentLLDBRuntimeModuleRefreshCollection(
                observations: [observation],
                observedPID: 844,
                observedStopID: 81,
                adapterGeneration: 1
            )
        }

        XCTAssertFalse(refreshed.reducerState.isInvalidated)
        let executedSequences = await executor.executedContexts.map(\.id.sequence)
        XCTAssertEqual(executedSequences, [1, 3, 4, 114])
    }

    func testRuntimeModuleRefreshCollectorFailureBeforeAnyExchangeFailsParentWithoutInvalidation() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 845,
                observedState: .stopped(processID: 845)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)

        do {
            _ = try await coordinator.performRuntimeModuleRefresh(
                expectedSession: stop.session,
                requiredStop: stop
            ) { _ in
                throw CoordinatorTestError.collectionFailed
            }
            XCTFail("Expected immediate collector failure.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .responseProjectionFailed)
            XCTAssertEqual(failure.requestID?.sequence, 2)
        }

        let failed = await coordinator.reducerState
        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, 1)
        XCTAssertFalse(failed.isInvalidated)
        XCTAssertEqual(failed.stopCoordinate, stop)
        XCTAssertEqual(failed.lastAcceptedEventSequence.rawValue, 5)
        XCTAssertNil(failed.pendingRequest)
        guard case .unavailable(.refreshFailed) = failed.runtimeModuleInventoryState.authority else {
            return XCTFail("An immediate collector failure must produce a bounded tombstone.")
        }
    }

    func testRuntimeModuleRefreshPhysicalFailedBeforeWriteOverridesConservativeCollectorInvalidation() async throws {
        let adapterFailure = PersistentLLDBCLIAdapterFailure(
            code: .invalidRequest,
            requestID: DebuggerRequestID(epoch: epoch, sequence: 3),
            generation: 1,
            disposition: .failedBeforeWrite
        )
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 846,
                observedState: .stopped(processID: 846)
            )),
            .failure(adapterFailure),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)

        do {
            _ = try await coordinator.performRuntimeModuleRefresh(
                expectedSession: stop.session,
                requiredStop: stop
            ) { channel in
                do {
                    _ = try await channel.execute(.testRequest)
                    XCTFail("Expected the physical exchange to fail before write.")
                } catch {
                    throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .exchangeFailed)
                }
                throw CoordinatorTestError.unexpectedExecution
            }
            XCTFail("Expected bounded collection failure.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .responseProjectionFailed)
            XCTAssertEqual(failure.requestID?.sequence, 2)
        }

        let failed = await coordinator.reducerState
        let executedSequences = await executor.executedContexts.map(\.id.sequence)
        XCTAssertEqual(executedSequences, [1, 3])
        XCTAssertFalse(failed.isInvalidated)
        XCTAssertEqual(failed.stopCoordinate, stop)
        XCTAssertNil(failed.pendingRequest)
        guard case .unavailable(.refreshFailed) = failed.runtimeModuleInventoryState.authority else {
            return XCTFail("A proven pre-write physical failure must leave a bounded tombstone.")
        }
    }

    func testRuntimeModuleRefreshAcceptsExactRemainingParentEventBudget() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 846,
                observedState: .stopped(processID: 846)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: 846,
                observedState: .stopped(processID: 846)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: 846,
                observedState: .stopped(processID: 846)
            )),
        ])
        let coordinator = makeCoordinator(
            executor: executor,
            initialEventSequence: .init(rawValue: UInt64.max - 7)
        )
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)
        let observation = try runtimeModuleObservation(processID: 846, observedStopID: 82)

        let refreshed = try await coordinator.performRuntimeModuleRefresh(
            expectedSession: stop.session,
            requiredStop: stop
        ) { channel in
            _ = try await channel.execute(.testRequest)
            _ = try await channel.cleanup(.testRequest) { _ in }
            return PersistentLLDBRuntimeModuleRefreshCollection(
                observations: [observation],
                observedPID: 846,
                observedStopID: 82,
                adapterGeneration: 1
            )
        }

        XCTAssertEqual(refreshed.reducerState.lastAcceptedEventSequence.rawValue, UInt64.max)
        XCTAssertFalse(refreshed.reducerState.isInvalidated)
    }

    func testRuntimeModuleRefreshRejectsInsufficientParentEventBudgetBeforeAdmissionOrExecution() async throws {
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: 847,
                observedState: .stopped(processID: 847)
            )),
        ])
        let coordinator = makeCoordinator(
            executor: executor,
            initialEventSequence: .init(rawValue: UInt64.max - 6)
        )
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)

        do {
            _ = try await coordinator.performRuntimeModuleRefresh(
                expectedSession: stop.session,
                requiredStop: stop
            ) { _ in
                XCTFail("Collection must not begin without the complete parent event budget.")
                throw CoordinatorTestError.unexpectedExecution
            }
            XCTFail("Expected event-sequence exhaustion.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .eventSequenceExhausted)
            XCTAssertNil(failure.requestID)
        }

        let executionCount = await executor.executionCount
        let finalState = await coordinator.reducerState
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(finalState, launched.reducerState)
    }

    func testLogicalBreakpointReconciliationReservesBeforeAtomicAdmissionAndIO() async throws {
        let stop = DebuggerStopCoordinate(
            session: .init(epoch: epoch, lifecycleRevision: .init(rawValue: 1)),
            stopRevision: .init(rawValue: 1)
        )
        let input = try emptyLogicalBreakpointInput(
            stop: stop,
            processID: 901,
            observedStopID: 4
        )
        let initialSequence = UInt64.max - UInt64(input.reservation.physicalRequestCount) + 1
        let executor = CoordinatorExecutorFake(results: [])
        let coordinator = makeCoordinator(
            executor: executor,
            initialRequestSequence: initialSequence
        )
        let before = await coordinator.reducerState

        do {
            _ = try await coordinator.performLogicalBreakpointReconciliation(input)
            XCTFail("Expected complete reservation failure.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .requestSequenceExhausted)
        }

        let executionCount = await executor.executionCount
        let after = await coordinator.reducerState
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(after, before)
    }

    func testLogicalBreakpointReconciliationExecutesFixedOffsetsAndCommitsValidatedReceipt() async throws {
        let processID: Int32 = 902
        let observedStopID: UInt32 = 44
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let state = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try emptyLogicalBreakpointInput(
            state: state,
            helperPreparation: .proveInstallAndReprove
        )
        let receipt = logicalEmptyReceipt(for: input)
        let receiptDigest = Data(SHA256.hash(data: receipt))
        let tokenHex = hex(input.token)
        let helperFirstSequence: UInt64 = 115
        let firstSequence = helperFirstSequence
            + UInt64(input.reservation.helperPreparationRequestCount)
        let applySequence = firstSequence + UInt64(1 + input.prepared.pages.count)
        let receiptSequence = applySequence + 1
        let cleanupSequence = 114 + UInt64(input.reservation.physicalRequestCount)
        let helper = LLDBLogicalBreakpointProgram.current
        var transactionResponses: [Result<PersistentLLDBCLIResponse, Error>] = [
            .success(logicalSemanticFailure(
                sequence: helperFirstSequence,
                processID: processID
            )),
        ]
        transactionResponses += helper.installChunkCommands.indices.map { index in
            .success(response(
                requestSequence: helperFirstSequence + 1 + UInt64(index),
                observedPID: processID,
                observedState: .stopped(processID: processID)
            ))
        }
        let finalizeSequence = helperFirstSequence
            + 1
            + UInt64(helper.installChunkCommands.count)
        transactionResponses += [
            .success(logicalResponse(
                sequence: finalizeSequence,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.installSentinel,
                object: .object([
                    "ok": .bool(true), "schema": .number("1"),
                    "sha256": .string(helper.sourceSHA256Hex),
                ])
            )),
            .success(logicalResponse(
                sequence: finalizeSequence + 1,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.installSentinel,
                object: .object([
                    "ok": .bool(true), "schema": .number("1"),
                    "sha256": .string(helper.sourceSHA256Hex),
                ])
            )),
            .success(logicalResponse(
                sequence: firstSequence,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.beginSentinel,
                object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
            )),
        ]
        for page in input.prepared.pages {
            transactionResponses.append(.success(logicalResponse(
                sequence: firstSequence + 1 + UInt64(page.index),
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.uploadSentinel,
                object: .object([
                    "index": .number(String(page.index)), "ok": .bool(true),
                    "schema": .number("1"), "token": .string(tokenHex),
                ])
            )))
        }
        transactionResponses.append(.success(logicalResponse(
            sequence: applySequence,
            processID: processID,
            sentinel: LLDBLogicalBreakpointProgram.applySentinel,
            object: .object([
                "count": .number("0"), "digest": .string(hex(receiptDigest)),
                "ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex),
            ])
        )))
        transactionResponses.append(.success(logicalResponse(
            sequence: receiptSequence,
            processID: processID,
            sentinel: LLDBLogicalBreakpointProgram.receiptSentinel,
            object: .object([
                "cursor": .number("0"), "digest": .string(hex(receiptDigest)),
                "final": .bool(true), "next": .number(String(receipt.count)),
                "ok": .bool(true), "payload_b64": .string(receipt.base64EncodedString()),
                "schema": .number("1"), "token": .string(tokenHex),
            ])
        )))
        transactionResponses.append(.success(logicalResponse(
            sequence: cleanupSequence,
            processID: processID,
            sentinel: LLDBLogicalBreakpointProgram.cleanupSentinel,
            object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
        )))
        await executor.append(transactionResponses)

        let result = try await coordinator.performLogicalBreakpointReconciliation(input)

        XCTAssertEqual(result.receipt.completeOwnedInventory, [])
        XCTAssertNil(result.reducerState.breakpointBindingState.pendingPlan)
        XCTAssertEqual(result.reducerState.breakpointBindingState.backendState, .unbound)
        let logicalContexts = await executor.executedContexts
        let sequences = logicalContexts.map(\.id.sequence)
        XCTAssertEqual(
            Array(sequences.suffix(4 + input.prepared.pages.count)),
            [firstSequence]
                + input.prepared.pages.map { firstSequence + 1 + UInt64($0.index) }
                + [applySequence, receiptSequence, cleanupSequence]
        )
        XCTAssertTrue(logicalContexts.suffix(4).allSatisfy {
            $0.operation == .reconcileLogicalBreakpoints && $0.requiredStop == input.prepared.plan.stopCoordinate
        })
        let commands = await executor.executedSemanticCommands
        let helperCommands = Array(commands.dropFirst(3).prefix(
            input.reservation.helperPreparationRequestCount
        ))
        XCTAssertEqual(
            helperCommands,
            [[helper.installedProofCommand]]
                + helper.installChunkCommands.map { [$0] }
                + [[helper.installFinalizeCommand], [helper.installedProofCommand]]
        )
    }

    func testEmptyLogicalBreakpointReconciliationClearsRetainedCallbackAuthority() async throws {
        let processID: Int32 = 919
        let observedStopID: UInt32 = 56
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )

        let ownedInput = try ownedLogicalBreakpointInput(state: stopped)
        let ownedFirstSequence: UInt64 = 115
        await executor.append(try ownedLogicalReconciliationResponses(
            input: ownedInput,
            firstSequence: ownedFirstSequence,
            processID: processID
        ))
        let owned = try await coordinator.performLogicalBreakpointReconciliation(ownedInput)
        XCTAssertEqual(owned.receipt.completeOwnedInventory.count, 1)

        let emptyInput = try emptyLogicalBreakpointInput(
            stop: try XCTUnwrap(owned.reducerState.stopCoordinate),
            processID: processID,
            observedStopID: observedStopID,
            inventory: try XCTUnwrap(
                owned.reducerState.runtimeModuleInventoryState.availableInventory
            ),
            authorityRevision: owned.reducerState.runtimeModuleInventoryState.authorityRevision,
            workspaceID: UUID(
                uuidString: "41414141-4141-4141-4141-414141414141"
            )!,
            catalogID: UUID(
                uuidString: "42424242-4242-4242-4242-424242424242"
            )!,
            catalogRevision: 2,
            resolutionRevision: 2,
            transactionID: UUID(
                uuidString: "45454545-4545-4545-4545-454545454545"
            )!,
            token: Data(repeating: 0x56, count: 32)
        )
        let beforeEmptyCount = await executor.executionCount
        let oldAuthorityDrainSequence = ownedFirstSequence
            + UInt64(ownedInput.reservation.physicalRequestCount)
        let emptyFirstSequence = oldAuthorityDrainSequence
            + UInt64(PersistentLLDBSessionCoordinator.logicalBreakpointCallbackDrainPageCapacity)
        await executor.append([
            .success(callbackDrainResponse(
                requestSequence: oldAuthorityDrainSequence,
                processID: processID,
                input: ownedInput,
                afterSequence: 0,
                nextSequence: 0,
                isFinal: true,
                records: [],
                observedState: .stopped(processID: processID)
            )),
        ] + emptyLogicalReconciliationResponses(
            input: emptyInput,
            firstSequence: emptyFirstSequence,
            processID: processID
        ))
        let emptied = try await coordinator.performLogicalBreakpointReconciliation(emptyInput)
        XCTAssertEqual(emptied.receipt.completeOwnedInventory, [])
        XCTAssertEqual(emptied.reducerState.breakpointBindingState.backendState, .unbound)

        let continueSequence = emptyFirstSequence
            + UInt64(emptyInput.reservation.physicalRequestCount)
        await executor.append([.success(response(
            requestSequence: continueSequence,
            observedPID: processID,
            observedState: .running(processID: processID)
        ))])
        let beforeContinueCount = await executor.executionCount
        let stop = try XCTUnwrap(emptied.reducerState.stopCoordinate)
        let continued = try await coordinator.perform(
            .continue,
            expectedSession: stop.session,
            requiredStop: stop
        )

        let afterContinueCount = await executor.executionCount
        let commands = await executor.executedSemanticCommands
        XCTAssertEqual(afterContinueCount, beforeContinueCount + 1)
        XCTAssertTrue(commands[beforeEmptyCount].contains(where: {
            $0.contains("drain_logs") && $0.contains(hex(ownedInput.token))
        }))
        XCTAssertFalse(commands.last?.contains(where: { $0.contains("drain_logs") }) == true)
        XCTAssertEqual(continued.reducerState.processPhase, .running(processID: processID))
    }

    func testLogicalBreakpointApplyProvenBeforeWriteCleansAndCancels() async throws {
        let processID: Int32 = 903
        let observedStopID: UInt32 = 45
        let executor = CoordinatorExecutorFake(results: [
            .success(response(requestSequence: 1, observedPID: processID, observedState: .stopped(processID: processID))),
            .success(response(requestSequence: 3, observedPID: processID, observedState: .stopped(processID: processID))),
            .success(response(requestSequence: 114, observedPID: processID, observedState: .stopped(processID: processID))),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let state = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try emptyLogicalBreakpointInput(state: state)
        let tokenHex = hex(input.token)
        let firstSequence: UInt64 = 115
        let applySequence = firstSequence + UInt64(1 + input.prepared.pages.count)
        let cleanupSequence = 114 + UInt64(input.reservation.physicalRequestCount)
        var responses: [Result<PersistentLLDBCLIResponse, Error>] = [
            .success(logicalResponse(sequence: firstSequence, processID: processID, sentinel: LLDBLogicalBreakpointProgram.beginSentinel, object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)]))),
        ]
        responses += input.prepared.pages.map { page in
            .success(logicalResponse(
                sequence: firstSequence + 1 + UInt64(page.index), processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.uploadSentinel,
                object: .object(["index": .number(String(page.index)), "ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
            ))
        }
        responses.append(.failure(PersistentLLDBCLIAdapterFailure(
            code: .cancelledBeforeWrite,
            requestID: DebuggerRequestID(epoch: epoch, sequence: applySequence),
            generation: 1,
            disposition: .cancelledBeforeWrite
        )))
        responses.append(.success(logicalResponse(
            sequence: cleanupSequence, processID: processID,
            sentinel: LLDBLogicalBreakpointProgram.cleanupSentinel,
            object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
        )))
        await executor.append(responses)

        do {
            _ = try await coordinator.performLogicalBreakpointReconciliation(input)
            XCTFail("Expected bounded pre-write cancellation.")
        } catch let failure as PersistentLLDBLogicalBreakpointReconciliationFailure {
            XCTAssertEqual(failure.classification, .cancelBeforeWrite(cleanup: .proven))
            XCTAssertFalse(failure.reducerState.isInvalidated)
            XCTAssertNil(failure.reducerState.breakpointBindingState.pendingPlan)
        }
    }

    func testLogicalBreakpointApplyUncertaintyRequiresRecoveryWithoutPrematureInvalidation() async throws {
        let processID: Int32 = 904
        let observedStopID: UInt32 = 46
        let executor = CoordinatorExecutorFake(results: [
            .success(response(requestSequence: 1, observedPID: processID, observedState: .stopped(processID: processID))),
            .success(response(requestSequence: 3, observedPID: processID, observedState: .stopped(processID: processID))),
            .success(response(requestSequence: 114, observedPID: processID, observedState: .stopped(processID: processID))),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let state = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try emptyLogicalBreakpointInput(state: state)
        let tokenHex = hex(input.token)
        let firstSequence: UInt64 = 115
        let applySequence = firstSequence + UInt64(1 + input.prepared.pages.count)
        var responses: [Result<PersistentLLDBCLIResponse, Error>] = [
            .success(logicalResponse(
                sequence: firstSequence, processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.beginSentinel,
                object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
            )),
        ]
        responses += input.prepared.pages.map { page in
            .success(logicalResponse(
                sequence: firstSequence + 1 + UInt64(page.index), processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.uploadSentinel,
                object: .object(["index": .number(String(page.index)), "ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
            ))
        }
        responses.append(.failure(PersistentLLDBCLIAdapterFailure(
            code: .invalidatedGeneration,
            requestID: DebuggerRequestID(epoch: epoch, sequence: applySequence),
            generation: 1,
            disposition: .invalidatedAfterWrite(
                reason: .timeoutAfterWrite,
                target: .unknown
            )
        )))
        await executor.append(responses)

        do {
            _ = try await coordinator.performLogicalBreakpointReconciliation(input)
            XCTFail("Expected post-write recovery disposition.")
        } catch let failure as PersistentLLDBLogicalBreakpointReconciliationFailure {
            XCTAssertEqual(
                failure.classification,
                .rejectMalformedAfterPossibleWrite(
                    cleanup: .failedOrUnproven,
                    retainValidatedCompleteReceipt: false,
                    targetRecoveryRequired: true
                )
            )
            XCTAssertFalse(failure.reducerState.isInvalidated)
            XCTAssertEqual(
                failure.reducerState.breakpointBindingState.pendingPlan?.transactionID,
                input.prepared.plan.transactionID
            )
        }
    }

    func testRunToCursorCreatesCompactPrivateReceiptBeforeResumeAndCleansExactIdentity() async throws {
        let processID: Int32 = 915
        let observedStopID: UInt32 = 52
        let executor = CoordinatorExecutorFake(results: [
            .success(response(requestSequence: 1, observedPID: processID, observedState: .stopped(processID: processID))),
            .success(response(requestSequence: 3, observedPID: processID, observedState: .stopped(processID: processID))),
            .success(response(requestSequence: 114, observedPID: processID, observedState: .stopped(processID: processID))),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let state = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try runToCursorCreationInput(state: state)
        let receipt = privateRunToCursorReceipt(for: input.prepared)
        let receiptDigest = Data(SHA256.hash(data: receipt))
        let tokenHex = hex(input.token)
        let firstSequence: UInt64 = 115
        let applySequence = firstSequence + 1 + UInt64(input.prepared.pages.count)
        let cleanupSequence = 114 + UInt64(input.reservation.physicalRequestCount)
        var responses: [Result<PersistentLLDBCLIResponse, Error>] = [
            .success(logicalResponse(
                sequence: firstSequence, processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.beginSentinel,
                object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
            )),
        ]
        responses += input.prepared.pages.map { page in
            .success(logicalResponse(
                sequence: firstSequence + 1 + UInt64(page.index), processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.uploadSentinel,
                object: .object([
                    "index": .number(String(page.index)), "ok": .bool(true),
                    "schema": .number("1"), "token": .string(tokenHex),
                ])
            ))
        }
        responses += [
            .success(logicalResponse(
                sequence: applySequence, processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.applySentinel,
                object: .object([
                    "count": .number("1"), "digest": .string(hex(receiptDigest)),
                    "ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex),
                ])
            )),
            .success(logicalResponse(
                sequence: applySequence + 1, processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.receiptSentinel,
                object: .object([
                    "cursor": .number("0"), "digest": .string(hex(receiptDigest)),
                    "final": .bool(true), "next": .number(String(receipt.count)),
                    "ok": .bool(true), "payload_b64": .string(receipt.base64EncodedString()),
                    "schema": .number("1"), "token": .string(tokenHex),
                ])
            )),
            .success(logicalResponse(
                sequence: cleanupSequence, processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.cleanupSentinel,
                object: .object(["ok": .bool(true), "schema": .number("1"), "token": .string(tokenHex)])
            )),
        ]
        await executor.append(responses)

        let created = try await coordinator.createRunToCursorBinding(input)
        XCTAssertEqual(created.receipt.backendBreakpointID, 101)
        XCTAssertEqual(created.receipt.backendLocationID, 1)
        XCTAssertEqual(created.reducerState, state)
        let commands = await executor.executedSemanticCommands
        XCTAssertFalse(commands.joined().contains(where: {
            $0.contains("breakpoint set") || $0.contains("breakpoint delete --force")
        }))

        let exactCleanupSequence = cleanupSequence + 1
        await executor.append([.success(logicalResponse(
            sequence: exactCleanupSequence, processID: processID,
            sentinel: LLDBLogicalBreakpointProgram.privateCleanupSentinel,
            object: .object([
                "backend_breakpoint_id": .number("101"),
                "backend_location_id": .number("1"),
                "name_sha256": .string(hex(created.receipt.nameOwnerDigest.bytes)),
                "ok": .bool(true), "owner_tag_digest": .string(hex(input.prepared.ownerDigest.bytes)),
                "runtime_address": .string("0000000110000010"), "schema": .number("1"),
                "token": .string(tokenHex), "was_present": .bool(false),
            ])
        ))])
        let cleaned = try await coordinator.cleanupRunToCursorBinding(
            PersistentLLDBRunToCursorCleanupInput(
                receipt: created.receipt,
                ownerDigest: input.prepared.ownerDigest,
                token: input.token
            )
        )
        XCTAssertEqual(cleaned, state)
    }

    func testAcceptedLogicalAuthorityDrainsRunningToStoppedRaceBeforeNewStopLifecycle() async throws {
        let processID: Int32 = 903
        let observedStopID: UInt32 = 45
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: input,
            firstSequence: 115,
            processID: processID
        ))
        let reconciled = try await coordinator.performLogicalBreakpointReconciliation(input)
        let stop = try XCTUnwrap(reconciled.reducerState.stopCoordinate)
        let parentSequence = 114 + UInt64(input.reservation.physicalRequestCount) + 1
        let drainSequence = parentSequence + 1
        await executor.append([
            .success(response(
                requestSequence: parentSequence,
                observedPID: processID,
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: drainSequence,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 0,
                isFinal: true,
                records: []
            )),
        ])

        let resumed = try await coordinator.perform(
            .continue,
            expectedSession: stop.session,
            requiredStop: stop
        )

        let contexts = await executor.executedContexts
        let commands = await executor.executedSemanticCommands
        XCTAssertEqual(Array(contexts.suffix(2).map(\.id.sequence)), [parentSequence, drainSequence])
        XCTAssertEqual(contexts.last?.operation, .pollProcessStatus)
        XCTAssertNil(contexts.last?.requiredStop)
        XCTAssertTrue(commands.last?.first?.contains("drain_logs") == true)
        XCTAssertEqual(
            resumed.reducerState.lastAcceptedEventSequence.rawValue,
            reconciled.reducerState.lastAcceptedEventSequence.rawValue + 4
        )
        XCTAssertEqual(resumed.reducerState.breakpointBindingState.lastCallbackSequence, 0)
        XCTAssertEqual(resumed.reducerState.lifecycleRevision.rawValue, 2)
        XCTAssertEqual(resumed.reducerState.stopRevision?.rawValue, 2)
    }

    func testAcceptedLogicalAuthorityProgressivelyDrainsMultipleCallbackPages() async throws {
        let processID: Int32 = 919
        let observedStopID: UInt32 = 56
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: input,
            firstSequence: 115,
            processID: processID
        ))
        let reconciled = try await coordinator.performLogicalBreakpointReconciliation(input)
        let stop = try XCTUnwrap(reconciled.reducerState.stopCoordinate)
        let wire = try XCTUnwrap(input.prepared.wireBindings.first)
        let firstRecord = logicalCallbackRecord(
            input: input,
            wire: wire,
            processID: processID,
            sequence: 1,
            hitCount: 1,
            outcome: "ignored"
        )
        let secondRecord = logicalCallbackRecord(
            input: input,
            wire: wire,
            processID: processID,
            sequence: 2,
            hitCount: 2,
            outcome: "condition_false"
        )
        let parentSequence = 114 + UInt64(input.reservation.physicalRequestCount) + 1
        await executor.append([
            .success(response(
                requestSequence: parentSequence,
                observedPID: processID,
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: parentSequence + 1,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 1,
                isFinal: false,
                records: [firstRecord],
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: parentSequence + 2,
                processID: processID,
                input: input,
                afterSequence: 1,
                nextSequence: 2,
                isFinal: true,
                records: [secondRecord],
                observedState: .running(processID: processID)
            )),
        ])

        let running = try await coordinator.perform(
            .continue,
            expectedSession: stop.session,
            requiredStop: stop
        )

        let contexts = await executor.executedContexts
        let commands = await executor.executedSemanticCommands
        XCTAssertEqual(
            Array(contexts.suffix(3).map(\.id.sequence)),
            [parentSequence, parentSequence + 1, parentSequence + 2]
        )
        XCTAssertEqual(Array(contexts.suffix(2).map(\.operation)), [
            .pollProcessStatus,
            .pollProcessStatus,
        ])
        XCTAssertEqual(Array(commands.suffix(2).compactMap(\.first)), [
            try LLDBLogicalBreakpointProgram.current.drainLogsCommand(
                token: input.token,
                sessionEpoch: epoch,
                adapterGeneration: input.prepared.plan.adapterGeneration,
                expectedProcessID: processID,
                afterSequence: 0
            ),
            try LLDBLogicalBreakpointProgram.current.drainLogsCommand(
                token: input.token,
                sessionEpoch: epoch,
                adapterGeneration: input.prepared.plan.adapterGeneration,
                expectedProcessID: processID,
                afterSequence: 1
            ),
        ])
        XCTAssertEqual(
            running.reducerState.breakpointBindingState.callbackRecords.map(\.sequence),
            [1, 2]
        )
        XCTAssertEqual(
            running.reducerState.breakpointBindingState.callbackRecords.map(\.outcome),
            [.ignored, .conditionFalse]
        )
        XCTAssertEqual(
            running.reducerState.breakpointBindingState.observedHitCounts[wire.binding.id.logicalID],
            2
        )
        XCTAssertEqual(running.reducerState.breakpointBindingState.lastCallbackSequence, 2)
        XCTAssertEqual(running.reducerState.processPhase, .running(processID: processID))
        XCTAssertEqual(
            running.reducerState.targetDisposition,
            .running(processID: processID)
        )
        XCTAssertNil(running.reducerState.stopCoordinate)
    }

    func testStoppedCallbackRequiresFreshInventoryAndRemintsBindingIdentity() async throws {
        let processID: Int32 = 920
        let observedStopID: UInt32 = 57
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let oldInput = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: oldInput,
            firstSequence: 115,
            processID: processID
        ))
        let originallyBound = try await coordinator.performLogicalBreakpointReconciliation(oldInput)
        let oldStop = try XCTUnwrap(originallyBound.reducerState.stopCoordinate)
        let oldInventory = try XCTUnwrap(
            originallyBound.reducerState.runtimeModuleInventoryState.availableInventory
        )
        let oldWire = try XCTUnwrap(oldInput.prepared.wireBindings.first)
        let oldLocation = try XCTUnwrap(
            originallyBound.receipt.completeOwnedInventory.first
        )

        let callbackCapacity = UInt64(
            PersistentLLDBSessionCoordinator.logicalBreakpointCallbackDrainPageCapacity
        )
        let continueSequence = 114 + UInt64(oldInput.reservation.physicalRequestCount) + 1
        let stoppedRecord = logicalCallbackRecord(
            input: oldInput,
            wire: oldWire,
            processID: processID,
            sequence: 1,
            hitCount: 1,
            outcome: "stop"
        )
        await executor.append([
            .success(response(
                requestSequence: continueSequence,
                observedPID: processID,
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: continueSequence + 1,
                processID: processID,
                input: oldInput,
                afterSequence: 0,
                nextSequence: 1,
                isFinal: true,
                records: [stoppedRecord],
                observedState: .stopped(processID: processID)
            )),
        ])

        let hit = try await coordinator.perform(
            .continue,
            expectedSession: oldStop.session,
            requiredStop: oldStop
        )
        let newStop = try XCTUnwrap(hit.reducerState.stopCoordinate)
        let hitBindings = hit.reducerState.breakpointBindingState
        XCTAssertNotEqual(newStop, oldStop)
        XCTAssertNil(hitBindings.currentStop)
        XCTAssertEqual(
            hitBindings.resolutions.first?.state,
            .pending(.hitAwaitingInventory)
        )
        XCTAssertEqual(hitBindings.lastCallbackSequence, 1)
        XCTAssertEqual(hitBindings.observedHitCounts[oldWire.binding.id.logicalID], 1)
        XCTAssertEqual(hitBindings.ownedLocations, [oldLocation])

        let refreshParentSequence = continueSequence + callbackCapacity + 1
        let refreshCleanupSequence = refreshParentSequence + UInt64(
            PersistentLLDBSessionCoordinator.runtimeModulePhysicalContextCount
        )
        await executor.append([
            .success(response(
                requestSequence: refreshParentSequence + 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: refreshCleanupSequence,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let freshObservation = try runtimeModuleObservation(
            processID: processID,
            observedStopID: observedStopID + 1
        )
        let refreshed = try await coordinator.performRuntimeModuleRefresh(
            expectedSession: newStop.session,
            requiredStop: newStop
        ) { channel in
            _ = try await channel.execute(.testRequest)
            _ = try await channel.cleanup(.testRequest) { _ in }
            return PersistentLLDBRuntimeModuleRefreshCollection(
                observations: [freshObservation],
                observedPID: processID,
                observedStopID: observedStopID + 1,
                adapterGeneration: 1
            )
        }
        let freshInventory = try XCTUnwrap(
            refreshed.reducerState.runtimeModuleInventoryState.availableInventory
        )
        let freshModule = try XCTUnwrap(freshInventory.modules.first)
        XCTAssertEqual(freshInventory.stop, newStop)
        XCTAssertGreaterThan(freshInventory.revision, oldInventory.revision)
        XCTAssertNotEqual(freshModule.id, oldWire.binding.id.moduleInstanceID)
        XCTAssertEqual(
            refreshed.reducerState.breakpointBindingState.resolutions.first?.state,
            .pending(.awaitingRuntimeInventory)
        )
        XCTAssertEqual(
            refreshed.reducerState.breakpointBindingState.backendState,
            .armedUnobserved([oldLocation])
        )

        let newInput = try ownedLogicalBreakpointInput(state: refreshed.reducerState)
        let newWire = try XCTUnwrap(newInput.prepared.wireBindings.first)
        let oldAuthorityDrainSequence = refreshCleanupSequence + 1
        let newTransactionFirst = oldAuthorityDrainSequence + callbackCapacity
        await executor.append([
            .success(callbackDrainResponse(
                requestSequence: oldAuthorityDrainSequence,
                processID: processID,
                input: oldInput,
                afterSequence: 1,
                nextSequence: 1,
                isFinal: true,
                records: [],
                observedState: .stopped(processID: processID)
            )),
        ] + (try ownedLogicalReconciliationResponses(
            input: newInput,
            firstSequence: newTransactionFirst,
            processID: processID
        )))

        let rebound = try await coordinator.performLogicalBreakpointReconciliation(newInput)
        XCTAssertEqual(newWire.binding.id.logicalID, oldWire.binding.id.logicalID)
        XCTAssertEqual(newWire.binding.id.siteID, oldWire.binding.id.siteID)
        XCTAssertEqual(newWire.binding.runtimeAddress, oldWire.binding.runtimeAddress)
        XCTAssertEqual(newWire.binding.policyActionDigest, oldWire.binding.policyActionDigest)
        XCTAssertNotEqual(
            newWire.binding.id.moduleInstanceID,
            oldWire.binding.id.moduleInstanceID
        )
        XCTAssertNotEqual(newWire.binding.id, oldWire.binding.id)
        XCTAssertNotEqual(
            newWire.binding.mappingKey.stopCoordinate,
            oldWire.binding.mappingKey.stopCoordinate
        )
        XCTAssertNotEqual(
            newWire.binding.mappingKey.inventoryRevision,
            oldWire.binding.mappingKey.inventoryRevision
        )
        XCTAssertNotEqual(newWire.binding.issuanceDigest, oldWire.binding.issuanceDigest)
        XCTAssertEqual(
            rebound.receipt.completeOwnedInventory.map(\.bindingID),
            [newWire.binding.id]
        )
        XCTAssertEqual(
            rebound.reducerState.breakpointBindingState.ownedLocations,
            rebound.receipt.completeOwnedInventory
        )
        XCTAssertEqual(
            rebound.reducerState.breakpointBindingState.backendState,
            .bound(rebound.receipt.completeOwnedInventory)
        )
        XCTAssertEqual(
            rebound.reducerState.breakpointBindingState.resolutions.first?.state,
            .resolved(site: newWire.binding.site, binding: newWire.binding)
        )
    }

    func testCallbackDrainUsesAuthoritativeRunningBaselineAndQuarantinesRejectedFault() async throws {
        let processID: Int32 = 918
        let observedStopID: UInt32 = 55
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: input,
            firstSequence: 115,
            processID: processID
        ))
        let reconciled = try await coordinator.performLogicalBreakpointReconciliation(input)
        let stop = try XCTUnwrap(reconciled.reducerState.stopCoordinate)
        XCTAssertEqual(reconciled.receipt.completeOwnedInventory.count, 1)

        let continueSequence = 114 + UInt64(input.reservation.physicalRequestCount) + 1
        await executor.append([
            .success(response(
                requestSequence: continueSequence,
                observedPID: processID,
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: continueSequence + 1,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 0,
                isFinal: true,
                records: [],
                observedState: .running(processID: processID)
            )),
        ])
        let running = try await coordinator.perform(
            .continue,
            expectedSession: stop.session,
            requiredStop: stop
        )
        XCTAssertEqual(running.reducerState.processPhase, .running(processID: processID))

        let wire = try XCTUnwrap(input.prepared.wireBindings.first)
        let faultRecord = logicalCallbackRecord(
            input: input,
            wire: wire,
            processID: processID,
            sequence: 1,
            hitCount: 1,
            outcome: "fault_stop",
            faultCode: "expression-timeout"
        )
        let decoded = try LLDBLogicalBreakpointCallbackBatchDecoder(
            expectedSessionEpoch: epoch,
            expectedAdapterGeneration: 1,
            expectedProcessID: processID,
            bindingIDsByWireID: [wire.wireID: wire.binding.id]
        ).decode(
            canonicalRecords: Phase2ProductionJSONValue.array([faultRecord]).canonicalJSONBytes(),
            afterSequence: 0,
            nextSequence: 1,
            isFinal: true
        )
        XCTAssertEqual(decoded.records.map(\.outcome), [.fault(code: "expression-timeout")])

        let pollSequence = continueSequence
            + UInt64(PersistentLLDBSessionCoordinator.logicalBreakpointCallbackDrainPageCapacity)
            + 1
        await executor.append([
            .success(response(
                requestSequence: pollSequence,
                observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: pollSequence + 1,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 1,
                isFinal: true,
                records: [faultRecord],
                observedState: .running(processID: processID)
            )),
        ])

        do {
            _ = try await coordinator.perform(
                .pollProcessStatus,
                expectedSession: running.reducerState.sessionCoordinate,
                requiredStop: nil
            )
            XCTFail("Expected the callback fault to be rejected against the running reducer.")
        } catch let failure as PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            XCTAssertEqual(failure.code, .reducerRejected)
            switch failure.disposition {
            case .terminateAndReap: break
            }
            XCTAssertFalse(failure.reducerState.isInvalidated)
            XCTAssertNil(failure.reducerState.pendingRequest)
            XCTAssertEqual(failure.reducerState.processPhase, .running(processID: processID))
            XCTAssertTrue(failure.reducerState.breakpointBindingState.isInvalidated)
            XCTAssertEqual(
                failure.reducerState.breakpointBindingState.callbackRecords,
                decoded.records
            )
        }

        let terminateSequence = pollSequence
            + UInt64(PersistentLLDBSessionCoordinator.logicalBreakpointCallbackDrainPageCapacity)
            + 1
        await executor.append([.success(response(
            requestSequence: terminateSequence,
            observedPID: processID,
            observedState: .exited(processID: processID, status: 0)
        ))])
        let beforeTerminateCount = await executor.executionCount
        let recovered = try await coordinator.perform(
            .terminate,
            expectedSession: running.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        let commands = await executor.executedSemanticCommands
        let afterTerminateCount = await executor.executionCount
        XCTAssertEqual(afterTerminateCount, beforeTerminateCount + 1)
        XCTAssertFalse(commands.last?.contains(where: { $0.contains("drain_logs") }) == true)
        XCTAssertEqual(recovered.reducerState.processPhase, .exited(processID: processID, code: 0))
        XCTAssertTrue(recovered.reducerState.isInvalidated)
        XCTAssertNil(recovered.reducerState.pendingRequest)
    }

    func testMalformedCallbackDrainQuarantinesAuthorityAndAllowsTerminateRecoveryWithoutRecursion() async throws {
        let processID: Int32 = 904
        let observedStopID: UInt32 = 46
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: observedStopID
        )
        let input = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: input, firstSequence: 115, processID: processID
        ))
        let reconciled = try await coordinator.performLogicalBreakpointReconciliation(input)
        let stop = try XCTUnwrap(reconciled.reducerState.stopCoordinate)
        let parentSequence = 114 + UInt64(input.reservation.physicalRequestCount) + 1
        await executor.append([
            .success(response(
                requestSequence: parentSequence, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: parentSequence + 1,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 1,
                isFinal: true,
                records: []
            )),
        ])

        do {
            _ = try await coordinator.perform(
                .continue,
                expectedSession: stop.session,
                requiredStop: stop
            )
            XCTFail("Expected a specialized callback-drain recovery failure.")
        } catch let failure as PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            XCTAssertEqual(failure.code, .responseProjectionFailed)
            switch failure.disposition {
            case .terminateAndReap: break
            }
            XCTAssertFalse(failure.reducerState.isInvalidated)
            XCTAssertNil(failure.reducerState.pendingRequest)
            XCTAssertEqual(failure.reducerState.stopCoordinate, stop)
        }

        let terminateSequence = parentSequence
            + UInt64(PersistentLLDBSessionCoordinator.logicalBreakpointCallbackDrainPageCapacity)
            + 1
        await executor.append([.success(response(
            requestSequence: terminateSequence,
            observedPID: processID,
            observedState: .exited(processID: processID, status: 0)
        ))])
        let beforeTerminateCount = await executor.executionCount
        let recovered = try await coordinator.perform(
            .terminate,
            expectedSession: stop.session,
            requiredStop: nil
        )

        let commands = await executor.executedSemanticCommands
        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, beforeTerminateCount + 1)
        XCTAssertFalse(commands.last?.contains(where: { $0.contains("drain_logs") }) == true)
        XCTAssertEqual(recovered.reducerState.processPhase, .exited(processID: processID, code: 0))
        XCTAssertTrue(recovered.reducerState.isInvalidated)
        XCTAssertNil(recovered.reducerState.pendingRequest)
    }

    func testCallbackDrainRejectsNonFinalNoProgressAndQuarantinesAuthority() async throws {
        let processID: Int32 = 905
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: 47
        )
        let input = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: input, firstSequence: 115, processID: processID
        ))
        let reconciled = try await coordinator.performLogicalBreakpointReconciliation(input)
        let stop = try XCTUnwrap(reconciled.reducerState.stopCoordinate)
        let parentSequence = 114 + UInt64(input.reservation.physicalRequestCount) + 1
        await executor.append([
            .success(response(
                requestSequence: parentSequence, observedPID: processID,
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: parentSequence + 1,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 0,
                isFinal: false,
                records: [],
                observedState: .running(processID: processID)
            )),
        ])

        do {
            _ = try await coordinator.perform(
                .continue,
                expectedSession: stop.session,
                requiredStop: stop
            )
            XCTFail("Expected a no-progress callback page to fail closed.")
        } catch let failure as PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            XCTAssertEqual(failure.code, .responseProjectionFailed)
            switch failure.disposition {
            case .terminateAndReap: break
            }
            XCTAssertFalse(failure.reducerState.isInvalidated)
            XCTAssertNil(failure.reducerState.pendingRequest)
        }

        let contexts = await executor.executedContexts
        let commands = await executor.executedSemanticCommands
        XCTAssertEqual(
            Array(contexts.suffix(2).map(\.id.sequence)),
            [parentSequence, parentSequence + 1]
        )
        XCTAssertTrue(commands.last?.first?.contains("drain_logs") == true)
        let final = await coordinator.reducerState
        XCTAssertEqual(
            final.lastAcceptedEventSequence.rawValue,
            reconciled.reducerState.lastAcceptedEventSequence.rawValue + 2
        )
        XCTAssertEqual(final.processPhase, .stopped(processID: processID, reason: .unknown("LLDB reported a stopped process.")))
        XCTAssertEqual(final.breakpointBindingState.lastCallbackSequence, 0)
    }

    func testAcceptedLogicalAuthorityDrainsRunningToExitedRaceBeforeLifecycleReduction() async throws {
        let processID: Int32 = 907
        let executor = CoordinatorExecutorFake(results: [
            .success(response(
                requestSequence: 1, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 3, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
            .success(response(
                requestSequence: 114, observedPID: processID,
                observedState: .stopped(processID: processID)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let stopped = try await establishLogicalBreakpointStop(
            coordinator: coordinator,
            processID: processID,
            observedStopID: 49
        )
        let input = try ownedLogicalBreakpointInput(state: stopped)
        await executor.append(try ownedLogicalReconciliationResponses(
            input: input, firstSequence: 115, processID: processID
        ))
        let reconciled = try await coordinator.performLogicalBreakpointReconciliation(input)
        let stop = try XCTUnwrap(reconciled.reducerState.stopCoordinate)
        let parentSequence = 114 + UInt64(input.reservation.physicalRequestCount) + 1
        await executor.append([
            .success(response(
                requestSequence: parentSequence, observedPID: processID,
                observedState: .running(processID: processID)
            )),
            .success(callbackDrainResponse(
                requestSequence: parentSequence + 1,
                processID: processID,
                input: input,
                afterSequence: 0,
                nextSequence: 0,
                isFinal: true,
                records: [],
                observedState: .exited(processID: processID, status: 23)
            )),
        ])

        let exited = try await coordinator.perform(
            .continue,
            expectedSession: stop.session,
            requiredStop: stop
        )

        XCTAssertEqual(exited.reducerState.processPhase, .exited(processID: processID, code: 23))
        XCTAssertEqual(exited.reducerState.targetDisposition, .exited(code: 23))
        XCTAssertTrue(exited.reducerState.isInvalidated)
        XCTAssertNil(exited.reducerState.pendingRequest)
        XCTAssertEqual(
            exited.reducerState.lastAcceptedEventSequence.rawValue,
            reconciled.reducerState.lastAcceptedEventSequence.rawValue + 3
        )
    }

    func testCallbackDrainProcessStateTransitionsAreMonotonicAcrossPages() {
        XCTAssertTrue(PersistentLLDBSessionCoordinator.callbackDrainTransitionIsMonotonic(
            from: .running(processID: 907),
            to: .stopped(processID: 907),
            permitsResumeTransition: false
        ))
        XCTAssertTrue(PersistentLLDBSessionCoordinator.callbackDrainTransitionIsMonotonic(
            from: .stopped(processID: 907),
            to: .running(processID: 907),
            permitsResumeTransition: true
        ))
        XCTAssertFalse(PersistentLLDBSessionCoordinator.callbackDrainTransitionIsMonotonic(
            from: .stopped(processID: 907),
            to: .running(processID: 907),
            permitsResumeTransition: false
        ))
        XCTAssertFalse(PersistentLLDBSessionCoordinator.callbackDrainTransitionIsMonotonic(
            from: .exited(processID: 907, status: 0),
            to: .stopped(processID: 907),
            permitsResumeTransition: false
        ))
        XCTAssertFalse(PersistentLLDBSessionCoordinator.callbackDrainTransitionIsMonotonic(
            from: .exited(processID: 907, status: 0),
            to: .running(processID: 907),
            permitsResumeTransition: true
        ))
    }

    private func establishLogicalBreakpointStop(
        coordinator: PersistentLLDBSessionCoordinator,
        processID: Int32,
        observedStopID: UInt32
    ) async throws -> DebuggerReducerState {
        let initial = await coordinator.reducerState
        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        let stop = try XCTUnwrap(launched.reducerState.stopCoordinate)
        let module = try runtimeModuleObservation(
            processID: processID,
            observedStopID: observedStopID
        )
        return try await coordinator.performRuntimeModuleRefresh(
            expectedSession: stop.session,
            requiredStop: stop
        ) { channel in
            _ = try await channel.execute(.testRequest)
            _ = try await channel.cleanup(.testRequest) { _ in }
            return PersistentLLDBRuntimeModuleRefreshCollection(
                observations: [module],
                observedPID: processID,
                observedStopID: observedStopID,
                adapterGeneration: 1
            )
        }.reducerState
    }

    private func emptyLogicalBreakpointInput(
        state: DebuggerReducerState,
        helperPreparation: LLDBLogicalBreakpointHelperPreparation = .alreadyProvenForGeneration
    ) throws -> PersistentLLDBLogicalBreakpointReconciliationInput {
        let stop = try XCTUnwrap(state.stopCoordinate)
        let inventory = try XCTUnwrap(state.runtimeModuleInventoryState.availableInventory)
        return try emptyLogicalBreakpointInput(
            stop: stop,
            processID: inventory.processID,
            observedStopID: inventory.observedStopID,
            inventory: inventory,
            authorityRevision: state.runtimeModuleInventoryState.authorityRevision,
            helperPreparation: helperPreparation
        )
    }

    private func ownedLogicalBreakpointInput(
        state: DebuggerReducerState
    ) throws -> PersistentLLDBLogicalBreakpointReconciliationInput {
        let stop = try XCTUnwrap(state.stopCoordinate)
        let inventory = try XCTUnwrap(state.runtimeModuleInventoryState.availableInventory)
        let module = try XCTUnwrap(inventory.modules.first)
        let binaryID = try XCTUnwrap(module.observation.uuid)
        let workspaceID = UUID(uuidString: "41414141-4141-4141-4141-414141414141")!
        let catalogID = UUID(uuidString: "42424242-4242-4242-4242-424242424242")!
        let logicalID = DebuggerLogicalBreakpointID(
            rawValue: UUID(uuidString: "43434343-4343-4343-4343-434343434343")!
        )
        let artifact = try MachOSliceArtifactIdentity(
            uuid: binaryID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "b", count: 64),
            selectedSliceByteCount: 0x2_000
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: .primary,
            artifactIdentity: artifact,
            ownerRevision: .init(rawValue: 1)
        )
        let owner = DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: binaryID,
            artifactIdentity: artifact
        )
        let specification = try DebuggerLogicalBreakpointSpecification(
            id: logicalID,
            revision: try .init(validating: 1),
            enabled: true,
            target: .preferredAddress(owner: owner, preferredVA: 0x1_0000_0010),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: 1,
            specifications: [specification]
        )
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: inventory.processID,
            authorityRevision: state.runtimeModuleInventoryState.authorityRevision,
            inventoryRevision: inventory.revision,
            workspaceCatalogRevision: .init(rawValue: 1)
        )
        let imageAddress = ImageAddress.primary(0x1_0000_0010)
        let siteID = DebuggerLogicalBreakpointSiteID(
            logicalID: logicalID,
            specificationRevision: specification.revision,
            imageAddress: imageAddress,
            staticOrdinal: 0
        )
        let site = try XCTUnwrap(DebuggerResolvedLogicalBreakpointSite(
            logicalID: logicalID,
            specificationRevision: specification.revision,
            siteID: siteID,
            owner: owner,
            coordinate: coordinate,
            imageAddress: imageAddress,
            provenance: .preferredAddress
        ))
        let policy = Data(SHA256.hash(
            data: try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(specification)
        ))
        var issuanceMaterial = policy
        issuanceMaterial.append(contentsOf: logicalID.rawValue.uuidString.utf8)
        issuanceMaterial.append(contentsOf: String(specification.revision.rawValue).utf8)
        issuanceMaterial.append(contentsOf: String(siteID.staticOrdinal).utf8)
        issuanceMaterial.append(contentsOf: String(imageAddress.slot.rawValue).utf8)
        issuanceMaterial.append(contentsOf: String(imageAddress.address).utf8)
        issuanceMaterial.append(contentsOf: String(0x1_1000_0010 as UInt64).utf8)
        issuanceMaterial.append(contentsOf: String(module.id.ordinal).utf8)
        issuanceMaterial.append(contentsOf: String(inventory.revision.rawValue).utf8)
        let bindingID = try XCTUnwrap(DebuggerTransientBreakpointBindingID(
            logicalID: logicalID,
            siteID: siteID,
            moduleInstanceID: module.id
        ))
        let binding = try XCTUnwrap(DebuggerDesiredBreakpointBinding(
            id: bindingID,
            site: site,
            mappingKey: mappingKey,
            runtimeAddress: 0x1_1000_0010,
            policyActionDigest: try XCTUnwrap(DebuggerBreakpointDigest(policy)),
            issuanceDigest: try XCTUnwrap(DebuggerBreakpointDigest(
                Data(SHA256.hash(data: issuanceMaterial))
            ))
        ))
        let result = DebuggerLogicalBreakpointResolution(
            logicalID: logicalID,
            specificationRevision: specification.revision,
            state: .resolved(site: site, binding: binding)
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: 1
        )
        let observation = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: logicalCoordinate,
            resolutionCatalogCoordinate: .init(
                workspaceID: workspaceID,
                revision: .init(rawValue: 1),
                workspaceArtifactCatalogRevision: mappingKey.workspaceCatalogRevision
            ),
            mappingKey: mappingKey,
            expectedSpecifications: [
                .init(logicalID: logicalID, specificationRevision: specification.revision)
            ],
            results: [result]
        ))
        let request = try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        )
        let prepared = try LLDBLogicalBreakpointTransactionCodec().prepare(
            request: request,
            transactionID: .init(
                rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
            ),
            adapterGeneration: 1,
            runtimeInventory: inventory,
            ownershipTagDigest: DebuggerBreakpointDigest(Data(repeating: 0x44, count: 32))!
        )
        let reservation = try LLDBLogicalBreakpointTransactionReservation(
            helperPreparation: .alreadyProvenForGeneration,
            planPageCount: prepared.pages.count,
            receiptByteCountUpperBound: prepared.receiptByteCountUpperBound
        )
        return PersistentLLDBLogicalBreakpointReconciliationInput(
            observation: observation,
            prepared: prepared,
            reservation: reservation,
            token: Data(repeating: 0x55, count: 32)
        )
    }

    private func emptyLogicalBreakpointInput(
        stop: DebuggerStopCoordinate,
        processID: Int32,
        observedStopID: UInt32,
        inventory: DebuggerRuntimeModuleInventory? = nil,
        authorityRevision: DebuggerRuntimeModuleAuthorityRevision = .init(rawValue: 1),
        helperPreparation: LLDBLogicalBreakpointHelperPreparation = .alreadyProvenForGeneration,
        workspaceID: UUID = UUID(
            uuidString: "31313131-3131-3131-3131-313131313131"
        )!,
        catalogID: UUID = UUID(
            uuidString: "32323232-3232-3232-3232-323232323232"
        )!,
        catalogRevision: UInt64 = 1,
        resolutionRevision: UInt64 = 1,
        transactionID: UUID = UUID(
            uuidString: "33333333-3333-3333-3333-333333333333"
        )!,
        token: Data = Data(repeating: 0x55, count: 32)
    ) throws -> PersistentLLDBLogicalBreakpointReconciliationInput {
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: catalogRevision,
            specifications: []
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: catalogRevision
        )
        let runtimeInventory = inventory ?? DebuggerRuntimeModuleInventory(
            revision: .init(rawValue: 1),
            stop: stop,
            processID: processID,
            observedStopID: observedStopID,
            modules: []
        )
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: processID,
            authorityRevision: authorityRevision,
            inventoryRevision: runtimeInventory.revision,
            workspaceCatalogRevision: .init(rawValue: 1)
        )
        let observation = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: logicalCoordinate,
            resolutionCatalogCoordinate: .init(
                workspaceID: workspaceID,
                revision: .init(rawValue: resolutionRevision),
                workspaceArtifactCatalogRevision: mappingKey.workspaceCatalogRevision
            ),
            mappingKey: mappingKey,
            expectedSpecifications: [],
            results: []
        ))
        let request = try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        )
        let prepared = try LLDBLogicalBreakpointTransactionCodec().prepare(
            request: request,
            transactionID: .init(rawValue: transactionID),
            adapterGeneration: 1,
            runtimeInventory: runtimeInventory,
            ownershipTagDigest: DebuggerBreakpointDigest(Data(repeating: 0x44, count: 32))!
        )
        let reservation = try LLDBLogicalBreakpointTransactionReservation(
            helperPreparation: helperPreparation,
            planPageCount: prepared.pages.count,
            receiptByteCountUpperBound: prepared.receiptByteCountUpperBound
        )
        return PersistentLLDBLogicalBreakpointReconciliationInput(
            observation: observation,
            prepared: prepared,
            reservation: reservation,
            token: token
        )
    }

    private func runToCursorCreationInput(
        state: DebuggerReducerState
    ) throws -> PersistentLLDBRunToCursorCreationInput {
        let inventory = try XCTUnwrap(state.runtimeModuleInventoryState.availableInventory)
        let module = try XCTUnwrap(inventory.modules.first)
        let artifactUUID = try XCTUnwrap(module.observation.uuid)
        let artifact = try MachOSliceArtifactIdentity(
            uuid: artifactUUID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 0x2_000
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: artifactUUID,
            slot: .primary,
            artifactIdentity: artifact,
            ownerRevision: .init(rawValue: 1)
        )
        let key = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: inventory.stop,
            observedPID: inventory.processID,
            authorityRevision: state.runtimeModuleInventoryState.authorityRevision,
            inventoryRevision: inventory.revision,
            workspaceCatalogRevision: .init(rawValue: 1)
        )
        let resolved = DebuggerResolvedRuntimeAddress(
            projectionKey: key,
            moduleInstanceID: module.id,
            workspaceCoordinate: coordinate,
            imageAddress: .primary(0x1_0000_0010),
            runtimeAddress: 0x1_1000_0010
        )
        let runID = try XCTUnwrap(LLDBRunToCursorRunID(
            rawValue: UUID(uuidString: "36363636-3636-3636-3636-363636363636")!
        ))
        let prepared = try LLDBRunToCursorTransactionCodec().prepare(
            resolvedAddress: resolved,
            observedStopID: inventory.observedStopID,
            adapterGeneration: 1,
            runtimeInventory: inventory,
            runID: runID,
            ownerDigest: DebuggerBreakpointDigest(Data(repeating: 0x66, count: 32))!
        )
        let reservation = try LLDBLogicalBreakpointTransactionReservation(
            helperPreparation: .alreadyProvenForGeneration,
            planPageCount: prepared.pages.count,
            receiptByteCountUpperBound: prepared.receiptByteCountUpperBound
        )
        return PersistentLLDBRunToCursorCreationInput(
            prepared: prepared,
            reservation: reservation,
            token: Data(repeating: 0x77, count: 32)
        )
    }

    private func privateRunToCursorReceipt(
        for prepared: LLDBRunToCursorPreparedTransaction
    ) -> Data {
        Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(prepared.adapterGeneration)),
            "backend_breakpoint_id": .number("101"),
            "backend_location_id": .number("1"),
            "name_owner_digest": .string(hex(prepared.expectedNameOwnerDigest.bytes)),
            "observed_pid": .number(String(prepared.observedPID)),
            "observed_stop_id": .number(String(prepared.observedStopID)),
            "ok": .bool(true), "one_shot": .bool(true),
            "plan_digest": .string(hex(prepared.canonicalPlanDigest.bytes)),
            "purpose": .string("run_to_cursor"),
            "run_id": .string(prepared.runID.rawValue.uuidString.lowercased()),
            "runtime_address": .string("0000000110000010"),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }

    private func logicalEmptyReceipt(
        for input: PersistentLLDBLogicalBreakpointReconciliationInput
    ) -> Data {
        Phase2ProductionJSONValue.object([
            "adapter_generation": .number("1"), "deleted_backend_ids": .array([]),
            "did_write_backend": .bool(false), "locations": .array([]),
            "observed_pid": .number(String(input.prepared.plan.observedPID)),
            "observed_stop_id": .number(String(input.prepared.plan.observedStopID)),
            "ok": .bool(true), "plan_digest": .string(hex(input.prepared.plan.canonicalPlanDigest.bytes)),
            "pre_state": .array([]), "schema": .number("1"),
            "session_epoch": .string(input.prepared.plan.sessionEpoch.rawValue.uuidString.lowercased()),
            "token": .string(hex(input.token)),
            "transaction_id": .string(input.prepared.plan.transactionID.rawValue.uuidString.lowercased()),
        ]).canonicalJSONBytes()
    }

    private func logicalOwnedReceipt(
        for input: PersistentLLDBLogicalBreakpointReconciliationInput
    ) throws -> Data {
        let wire = try XCTUnwrap(input.prepared.wireBindings.first)
        let location: Phase2ProductionJSONValue = .object([
            "auto_continue": .bool(false),
            "backend_breakpoint_id": .number("101"),
            "backend_location_id": .number("1"),
            "binding_id": .string(wire.wireID),
            "enabled": .bool(true),
            "issuance_digest": .string(hex(wire.binding.issuanceDigest.bytes)),
            "logical_id": .string(wire.binding.id.logicalID.rawValue.uuidString.lowercased()),
            "name_sha256": .string(hex(wire.expectedOwnedNameSHA256)),
            "one_shot": .bool(false),
            "owner_tag_digest": .string(hex(input.prepared.plan.ownershipTagDigest.bytes)),
            "policy_action_digest": .string(hex(wire.binding.policyActionDigest.bytes)),
            "runtime_address": .string(String(format: "%016llx", wire.binding.runtimeAddress)),
            "specification_revision": .number(
                String(wire.binding.id.siteID.specificationRevision.rawValue)
            ),
        ])
        return Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(input.prepared.plan.adapterGeneration)),
            "deleted_backend_ids": .array([]),
            "did_write_backend": .bool(true),
            "locations": .array([location]),
            "observed_pid": .number(String(input.prepared.plan.observedPID)),
            "observed_stop_id": .number(String(input.prepared.plan.observedStopID)),
            "ok": .bool(true),
            "plan_digest": .string(hex(input.prepared.plan.canonicalPlanDigest.bytes)),
            "pre_state": .array([]),
            "schema": .number("1"),
            "session_epoch": .string(
                input.prepared.plan.sessionEpoch.rawValue.uuidString.lowercased()
            ),
            "token": .string(hex(input.token)),
            "transaction_id": .string(
                input.prepared.plan.transactionID.rawValue.uuidString.lowercased()
            ),
        ]).canonicalJSONBytes()
    }

    private func ownedLogicalReconciliationResponses(
        input: PersistentLLDBLogicalBreakpointReconciliationInput,
        firstSequence: UInt64,
        processID: Int32
    ) throws -> [Result<PersistentLLDBCLIResponse, Error>] {
        logicalReconciliationResponses(
            input: input,
            firstSequence: firstSequence,
            processID: processID,
            receipt: try logicalOwnedReceipt(for: input),
            appliedCount: 1
        )
    }

    private func emptyLogicalReconciliationResponses(
        input: PersistentLLDBLogicalBreakpointReconciliationInput,
        firstSequence: UInt64,
        processID: Int32
    ) -> [Result<PersistentLLDBCLIResponse, Error>] {
        logicalReconciliationResponses(
            input: input,
            firstSequence: firstSequence,
            processID: processID,
            receipt: logicalEmptyReceipt(for: input),
            appliedCount: 0
        )
    }

    private func logicalReconciliationResponses(
        input: PersistentLLDBLogicalBreakpointReconciliationInput,
        firstSequence: UInt64,
        processID: Int32,
        receipt: Data,
        appliedCount: Int
    ) -> [Result<PersistentLLDBCLIResponse, Error>] {
        let receiptDigest = Data(SHA256.hash(data: receipt))
        let tokenHex = hex(input.token)
        let applySequence = firstSequence + UInt64(1 + input.prepared.pages.count)
        let cleanupSequence = firstSequence
            + UInt64(input.reservation.physicalRequestCount - 1)
        var responses: [Result<PersistentLLDBCLIResponse, Error>] = [
            .success(logicalResponse(
                sequence: firstSequence,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.beginSentinel,
                object: .object([
                    "ok": .bool(true), "schema": .number("1"),
                    "token": .string(tokenHex),
                ])
            )),
        ]
        responses += input.prepared.pages.map { page in
            .success(logicalResponse(
                sequence: firstSequence + 1 + UInt64(page.index),
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.uploadSentinel,
                object: .object([
                    "index": .number(String(page.index)), "ok": .bool(true),
                    "schema": .number("1"), "token": .string(tokenHex),
                ])
            ))
        }
        responses += [
            .success(logicalResponse(
                sequence: applySequence,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.applySentinel,
                object: .object([
                    "count": .number(String(appliedCount)),
                    "digest": .string(hex(receiptDigest)),
                    "ok": .bool(true), "schema": .number("1"),
                    "token": .string(tokenHex),
                ])
            )),
            .success(logicalResponse(
                sequence: applySequence + 1,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.receiptSentinel,
                object: .object([
                    "cursor": .number("0"), "digest": .string(hex(receiptDigest)),
                    "final": .bool(true), "next": .number(String(receipt.count)),
                    "ok": .bool(true),
                    "payload_b64": .string(receipt.base64EncodedString()),
                    "schema": .number("1"), "token": .string(tokenHex),
                ])
            )),
            .success(logicalResponse(
                sequence: cleanupSequence,
                processID: processID,
                sentinel: LLDBLogicalBreakpointProgram.cleanupSentinel,
                object: .object([
                    "ok": .bool(true), "schema": .number("1"),
                    "token": .string(tokenHex),
                ])
            )),
        ]
        return responses
    }

    private func logicalCallbackRecord(
        input: PersistentLLDBLogicalBreakpointReconciliationInput,
        wire: LLDBLogicalBreakpointWireBinding,
        processID: Int32,
        sequence: UInt64,
        hitCount: UInt64,
        outcome: String,
        faultCode: String? = nil
    ) -> Phase2ProductionJSONValue {
        var object: [String: Phase2ProductionJSONValue] = [
            "adapter_generation": .number(String(input.prepared.plan.adapterGeneration)),
            "backend_breakpoint_id": .number("101"),
            "backend_location_id": .number("1"),
            "binding_id": .string(wire.wireID),
            "hit_count": .number(String(hitCount)),
            "issuance_digest": .string(hex(wire.binding.issuanceDigest.bytes)),
            "logical_id": .string(wire.binding.id.logicalID.rawValue.uuidString.lowercased()),
            "outcome": .string(outcome),
            "process_id": .number(String(processID)),
            "sequence": .number(String(sequence)),
            "session_epoch": .string(epoch.rawValue.uuidString.lowercased()),
            "specification_revision": .number(
                String(wire.binding.id.siteID.specificationRevision.rawValue)
            ),
        ]
        if let faultCode {
            object["code"] = .string(faultCode)
            object["drop_count"] = .number("0")
        }
        if outcome == "stop" || outcome == "continue_after_successful_actions" {
            object["outputs"] = .array([])
        }
        return .object(object)
    }

    private func callbackDrainResponse(
        requestSequence: UInt64,
        processID: Int32,
        input: PersistentLLDBLogicalBreakpointReconciliationInput,
        afterSequence: UInt64,
        nextSequence: UInt64,
        isFinal: Bool,
        records: [Phase2ProductionJSONValue],
        observedState: LLDBCLIObservedProcessState? = nil
    ) -> PersistentLLDBCLIResponse {
        logicalResponse(
            sequence: requestSequence,
            processID: processID,
            sentinel: LLDBLogicalBreakpointProgram.logsSentinel,
            object: .object([
                "adapter_generation": .number(String(input.prepared.plan.adapterGeneration)),
                "after_sequence": .number(String(afterSequence)),
                "final": .bool(isFinal), "next_sequence": .number(String(nextSequence)),
                "ok": .bool(true), "process_id": .number(String(processID)),
                "records": .array(records), "schema": .number("1"),
                "session_epoch": .string(epoch.rawValue.uuidString.lowercased()),
                "token": .string(hex(input.token)),
            ]),
            observedState: observedState
        )
    }

    private func logicalResponse(
        sequence: UInt64,
        processID: Int32,
        sentinel: String,
        object: Phase2ProductionJSONValue,
        observedState: LLDBCLIObservedProcessState? = nil
    ) -> PersistentLLDBCLIResponse {
        let semantic = sentinel + String(data: object.canonicalJSONBytes(), encoding: .utf8)! + "\n"
        return PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(epoch: epoch, sequence: sequence),
            generation: 1,
            transcript: LLDBCLITranscriptResult(
                transcript: "", authoritativeStatusTranscript: "",
                observedProcessID: processID,
                observedProcessState: observedState ?? .stopped(processID: processID),
                exchangeByteCount: semantic.utf8.count,
                exchangeSHA256: String(repeating: "a", count: 64),
                semanticCommandTranscripts: [semantic],
                semanticCommandResultLineByteCounts: [semantic.utf8.count]
            )
        )
    }

    private func logicalSemanticFailure(
        sequence: UInt64,
        processID: Int32
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(epoch: epoch, sequence: sequence),
            generation: 1,
            transcript: LLDBCLITranscriptResult(
                transcript: "", authoritativeStatusTranscript: "",
                observedProcessID: processID,
                observedProcessState: .stopped(processID: processID),
                exchangeByteCount: 1,
                exchangeSHA256: String(repeating: "a", count: 64),
                semanticCommandsSucceeded: false,
                firstFailedSemanticCommandIndex: 0
            )
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func makeCoordinator(
        executor: CoordinatorExecutorFake,
        preparer: CoordinatorRequestPreparerFake = CoordinatorRequestPreparerFake(),
        initialRequestSequence: UInt64 = 0,
        initialEventSequence: DebuggerEventSequence = .initial
    ) -> PersistentLLDBSessionCoordinator {
        PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: preparer,
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            ),
            initialRequestSequence: initialRequestSequence,
            initialEventSequence: initialEventSequence
        )
    }

    private func runtimeModuleObservation(
        processID: Int32,
        observedStopID: UInt32
    ) throws -> DebuggerRuntimeModuleObservation {
        let range = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 0,
            sectionName: "__TEXT",
            staticStart: 0x1_0000_0000,
            runtimeStart: 0x1_1000_0000,
            byteCount: 0x1000,
            permissions: 5
        ))
        return try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            processID: processID,
            observedStopID: observedStopID,
            mappedRanges: [range],
            fullPath: "/tmp/MacScopeCoordinatorFixture",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: 0,
            fingerprintSHA256: Data(repeating: 0xA5, count: 32)
        ))
    }

    private func response(
        requestSequence: UInt64,
        observedPID: Int32?,
        observedState: LLDBCLIObservedProcessState?
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(epoch: epoch, sequence: requestSequence),
            generation: 1,
            transcript: LLDBCLITranscriptResult(
                transcript: "bounded console",
                authoritativeStatusTranscript: "bounded status",
                observedProcessID: observedPID,
                observedProcessState: observedState,
                exchangeByteCount: 1,
                exchangeSHA256: String(repeating: "a", count: 64)
            )
        )
    }
}

private actor CoordinatorExecutorFake: PersistentLLDBCLIExecuting {
    private var results: [Result<PersistentLLDBCLIResponse, Error>]
    private let blockedExecutionNumber: Int?
    private var blockedExecutionContinuation: CheckedContinuation<Void, Never>?
    private(set) var executedContexts: [DebuggerRequestContext] = []
    private(set) var executedSemanticCommands: [[String]] = []
    private(set) var executedTimeouts: [Duration] = []

    init(
        results: [Result<PersistentLLDBCLIResponse, Error>],
        blockedExecutionNumber: Int? = nil
    ) {
        self.results = results
        self.blockedExecutionNumber = blockedExecutionNumber
    }

    var executionCount: Int {
        executedContexts.count
    }

    func append(_ additionalResults: [Result<PersistentLLDBCLIResponse, Error>]) {
        results.append(contentsOf: additionalResults)
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        executedContexts.append(request.context)
        executedSemanticCommands.append(request.semanticCommands)
        executedTimeouts.append(request.timeout)
        if executedContexts.count == blockedExecutionNumber {
            await withCheckedContinuation { continuation in
                blockedExecutionContinuation = continuation
            }
        }
        guard !results.isEmpty else {
            throw CoordinatorTestError.unexpectedExecution
        }
        return try results.removeFirst().get()
    }

    func releaseBlockedExecution() {
        let continuation = blockedExecutionContinuation
        blockedExecutionContinuation = nil
        continuation?.resume()
    }
}

private actor CoordinatorRequestPreparerFake: PersistentLLDBCLIRequestPreparing {
    private(set) var preparedContexts: [DebuggerRequestContext] = []

    var preparationCount: Int {
        preparedContexts.count
    }

    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        preparedContexts.append(context)
        return try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: context.operation == .pollProcessStatus ? [] : ["script pass"],
            observedPIDRequirement: context.operation == .replaceBreakpoints ? .optional : .required,
            timeout: .seconds(2)
        )
    }
}

private extension PersistentLLDBRuntimeModulePhysicalRequest {
    static var testRequest: Self {
        Self(
            semanticCommands: ["script pass"],
            observedPIDRequirement: .required,
            timeout: .seconds(2)
        )
    }
}

private enum CoordinatorTestError: Error {
    case unexpectedExecution
    case collectionFailed
}

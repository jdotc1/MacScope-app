import CryptoKit
import XCTest
@testable import MacScope

final class DebuggerPersistentLLDBExactAttachTransactionTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "B1B1B1B1-B1B1-B1B1-B1B1-B1B1B1B1B1B1")!
    )
    private let generation: UInt64 = 1

    func testExactAttachRejectsBeforeStagingWhenWriteInterlockIsAbsent() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: Data(repeating: 0, count: 32)
        )
        let coordinator = PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: RejectingExactAttachPreparer(),
            capabilities: allOperationsEnabledCapabilities()
        )
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.performExactAttachTransaction(
                try await makeExactAttachInput(
                    request: request,
                    admissionSession: initial.sessionCoordinate,
                    executor: executor
                )
            )
            XCTFail("Missing write-interlock authority must reject exact attach.")
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
            XCTAssertNil(failure.finalRequestID)
            XCTAssertEqual(
                failure.finalCommandDisposition,
                .definitelyNotDispatchedOrWritten
            )
        }

        let executionCount = await executor.executionCountValue()
        XCTAssertEqual(executionCount, 0)
    }
    private let token = Data(repeating: 0x6d, count: 32)

    func testExactAttachOwnsFrozenSingleCommandExchangesAndPublishesStoppedAuthority() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        let result = try await coordinator.performExactAttachTransaction(
            try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
        )

        let authority = DebuggerSessionTargetAuthority(origin: .attached(request.selectedIdentity))
        let requests = await executor.requests
        let expectedCommands = try frozenCommands(
            request: request,
            finalSequence: UInt64(requests.count),
            correlationToken: result.attachedSession.permit.correlationToken
        )
        XCTAssertEqual(requests.count, expectedCommands.count)
        XCTAssertEqual(requests.map(\.semanticCommands), expectedCommands.map { [$0] })
        XCTAssertEqual(
            requests.map { $0.context.id.sequence },
            Array(1...UInt64(expectedCommands.count))
        )
        XCTAssertTrue(requests.allSatisfy { $0.context.operation == .attach })
        XCTAssertTrue(requests.allSatisfy { $0.context.targetAuthority == authority })
        XCTAssertTrue(requests.dropLast().allSatisfy {
            $0.observedPIDRequirement == .optional
        })
        XCTAssertEqual(requests.last?.observedPIDRequirement, .required)
        XCTAssertTrue(requests.dropLast().allSatisfy {
            if case .exactAttachStaging(let authorization) = $0.writeRole {
                return authorization != nil
            }
            return false
        })
        let exactStagingAuthorizationCount = await executor
            .exactStagingAuthorizationCountValue()
        XCTAssertEqual(exactStagingAuthorizationCount, expectedCommands.count - 1)
        let exactStagingConsumptionCount = await executor.exactStagingConsumptionCountValue()
        XCTAssertEqual(exactStagingConsumptionCount, expectedCommands.count - 1)
        let exactFinalAuthorizationCount = await executor.exactFinalAuthorizationCountValue()
        XCTAssertEqual(exactFinalAuthorizationCount, 1)
        let finalWriteCommitCount = await executor.finalWriteCommitCountValue()
        XCTAssertEqual(finalWriteCommitCount, 1)
        XCTAssertEqual(
            result.requestID,
            DebuggerRequestID(epoch: epoch, sequence: UInt64(expectedCommands.count))
        )

        XCTAssertEqual(result.receipt.observedProcessID, authority.processID)
        XCTAssertEqual(result.receipt.lldbProcessUniqueID, 8_811)
        XCTAssertEqual(result.reducerState.acceptedTargetAuthority, authority)
        XCTAssertEqual(result.reducerState.observedProcessID, authority.processID)
        XCTAssertEqual(
            result.reducerState.processPhase,
            .stopped(
                processID: authority.processID,
                reason: .signal("5")
            )
        )
        XCTAssertEqual(result.reducerState.targetDisposition, .stopped(processID: authority.processID))
        XCTAssertNil(result.reducerState.pendingRequest)
        XCTAssertEqual(result.reducerState.lastAcceptedEventSequence.rawValue, 4)
        XCTAssertTrue(result.attachedSession.hasValidBinding())
    }

    func testPermitReplayOnFreshCoordinatorRejectsBeforeSecondExecutorAccess() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let firstCoordinator = makeCoordinator(executor: executor)
        let firstState = await firstCoordinator.reducerState
        let input = try await makeExactAttachInput(
            request: request,
            admissionSession: firstState.sessionCoordinate,
            executor: executor
        )

        _ = try await firstCoordinator.performExactAttachTransaction(input)
        let countAfterSuccess = await executor.executionCountValue()
        let secondCoordinator = makeCoordinator(executor: executor)

        do {
            _ = try await secondCoordinator.performExactAttachTransaction(input)
            XCTFail("A registry permit must authorize exactly one coordinator transaction.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
        } catch {
            XCTFail("Replay must be an ordinary, non-settleable admission failure: \(error)")
        }
        let countAfterReplay = await executor.executionCountValue()
        XCTAssertEqual(countAfterReplay, countAfterSuccess)
    }

    func testPermitReplayOnSameCoordinatorIsNonSettleableAndRejectsBeforeExecutorAccess() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let input = try await makeExactAttachInput(
            request: request,
            admissionSession: initial.sessionCoordinate,
            executor: executor
        )

        _ = try await coordinator.performExactAttachTransaction(input)
        let countAfterSuccess = await executor.executionCountValue()

        do {
            _ = try await coordinator.performExactAttachTransaction(input)
            XCTFail("A spent permit must not re-enter the same coordinator transaction.")
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            XCTFail(
                "Replay must not expose registry-settleable transaction evidence: \(failure)"
            )
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
        } catch {
            XCTFail("Replay must be an ordinary, non-settleable admission failure: \(error)")
        }

        let countAfterReplay = await executor.executionCountValue()
        XCTAssertEqual(countAfterReplay, countAfterSuccess)
    }

    func testPermitReplayAfterPolicyRevisionAdvanceRemainsNonSettleable() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let input = try await makeExactAttachInput(
            request: request,
            admissionSession: initial.sessionCoordinate,
            executor: executor
        )

        _ = try await coordinator.performExactAttachTransaction(input)
        let countAfterSuccess = await executor.executionCountValue()
        let snapshot = executor.attachWriteInterlock.currentSnapshot
        try executor.attachWriteInterlock.commitOwnedInfrastructureRevision(
            from: snapshot.revision.ownedInfrastructure,
            to: DebuggerOwnedInfrastructureRevision(
                rawValue: snapshot.revision.ownedInfrastructure.rawValue + 1
            )
        ) {}

        do {
            _ = try await coordinator.performExactAttachTransaction(input)
            XCTFail("A spent permit must remain a replay after its policy revision becomes stale.")
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            XCTFail(
                "Stale-policy replay must not expose registry-settleable evidence: \(failure)"
            )
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
        } catch {
            XCTFail("Replay must be an ordinary, non-settleable admission failure: \(error)")
        }

        let countAfterReplay = await executor.executionCountValue()
        XCTAssertEqual(countAfterReplay, countAfterSuccess)
    }

    func testRevisionDriftAtClaimReturnsSettleableUnclaimedFailureAndRemovesOnlyItsLease() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let interlock = executor.attachWriteInterlock
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let coordinatorState = await makeCoordinator(executor: executor).reducerState
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: coordinatorState.epoch,
            authority: DebuggerSessionTargetAuthority(origin: .attached(request.selectedIdentity))
        )
        let bystanderIdentity = try identity(
            processID: 7_778,
            canonicalExecutablePath: "/tmp/MacScopeExactAttachBystander",
            executableFileID: 7_002,
            executableSHA256: String(repeating: "b", count: 64),
            machOUUID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
        )
        let bystander = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: coordinatorState.epoch,
            authority: DebuggerSessionTargetAuthority(origin: .attached(bystanderIdentity))
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: coordinatorState.sessionCoordinate,
            adapterGeneration: generation,
            attachWriteInterlockSnapshot: interlock.currentSnapshot
        )
        await executor.configure(
            correlationToken: permit.correlationToken,
            instanceBinding: await makeAdapterInstanceBinding()
        )
        let coordinator = makeCoordinator(
            executor: executor,
            exactAttachClaimBoundaryAction: { _ in
                let snapshot = interlock.currentSnapshot
                try! interlock.commitOwnedInfrastructureRevision(
                    from: snapshot.revision.ownedInfrastructure,
                    to: DebuggerOwnedInfrastructureRevision(
                        rawValue: snapshot.revision.ownedInfrastructure.rawValue + 1
                    )
                ) {}
            }
        )
        let input = PersistentLLDBExactAttachTransactionInput(
            request: request,
            permit: permit
        )

        let capturedFailure = await XCTAssertThrowsExactAttachFailure(
            .admissionRejected,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            finalRequestWasAdmitted: false,
            operation: { try await coordinator.performExactAttachTransaction(input) }
        )
        let failure = try XCTUnwrap(capturedFailure)

        XCTAssertNil(failure.transactionClaim)
        let finalRequestID = try XCTUnwrap(failure.finalRequestID)
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(finalRequestID.epoch, epoch)
        XCTAssertEqual(finalRequestID.sequence, UInt64(expectedRequestCount))
        let executionCountBeforeSettlement = await executor.executionCountValue()
        let leaseCountBeforeSettlement = await registry.activeLeaseCount
        XCTAssertEqual(executionCountBeforeSettlement, 0)
        XCTAssertEqual(leaseCountBeforeSettlement, 2)

        try await registry.resolveExactAttachFailure(failure)

        let leaseCountAfterSettlement = await registry.activeLeaseCount
        let bystanderState = try await registry.state(for: bystander)
        XCTAssertEqual(leaseCountAfterSettlement, 1)
        XCTAssertEqual(bystanderState, .reservedBeforeWrite)
        do {
            _ = try await registry.state(for: reservation)
            XCTFail("Settlement must remove the authentic failed lease.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .staleReservation)
        }
    }

    func testConcurrentClaimAtBoundaryCannotSettleOrWrite() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let interlock = executor.attachWriteInterlock
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let coordinatorState = await makeCoordinator(executor: executor).reducerState
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: coordinatorState.epoch,
            authority: DebuggerSessionTargetAuthority(origin: .attached(request.selectedIdentity))
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: coordinatorState.sessionCoordinate,
            adapterGeneration: generation,
            attachWriteInterlockSnapshot: interlock.currentSnapshot
        )
        await executor.configure(
            correlationToken: permit.correlationToken,
            instanceBinding: await makeAdapterInstanceBinding()
        )
        let coordinator = makeCoordinator(
            executor: executor,
            exactAttachClaimBoundaryAction: { claimInput in
                _ = try! interlock.claimExactAttachTransaction(claimInput)
            }
        )
        let input = PersistentLLDBExactAttachTransactionInput(
            request: request,
            permit: permit
        )

        let capturedFailure = await XCTAssertThrowsExactAttachFailure(
            .admissionRejected,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            finalRequestWasAdmitted: false,
            operation: { try await coordinator.performExactAttachTransaction(input) }
        )
        let failure = try XCTUnwrap(capturedFailure)

        XCTAssertNil(failure.transactionClaim)
        let finalRequestID = try XCTUnwrap(failure.finalRequestID)
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(finalRequestID.epoch, epoch)
        XCTAssertEqual(finalRequestID.sequence, UInt64(expectedRequestCount))
        let executionCountBeforeSettlement = await executor.executionCountValue()
        let stateBeforeSettlement = try await registry.state(for: reservation)
        XCTAssertEqual(executionCountBeforeSettlement, 0)
        XCTAssertEqual(stateBeforeSettlement, .exactAttachClaimed)
        do {
            try await registry.resolveExactAttachFailure(failure)
            XCTFail("A competing claim must make nil-claim settlement non-authentic.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .invalidStateTransition)
        }
        let leaseCountAfterSettlement = await registry.activeLeaseCount
        let stateAfterSettlement = try await registry.state(for: reservation)
        let executionCountAfterSettlement = await executor.executionCountValue()
        XCTAssertEqual(leaseCountAfterSettlement, 1)
        XCTAssertEqual(stateAfterSettlement, .exactAttachClaimed)
        XCTAssertEqual(executionCountAfterSettlement, 0)
    }

    func testPolicyRevisionAdvanceAfterStagingPreventsFinalAttachWrite() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .barrierAtFirstStaging,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let input = try await makeExactAttachInput(
            request: request,
            admissionSession: initial.sessionCoordinate,
            executor: executor
        )
        let transaction = Task { try await coordinator.performExactAttachTransaction(input) }
        await executor.waitUntilFirstStagingStarts()

        let snapshot = executor.attachWriteInterlock.currentSnapshot
        try executor.attachWriteInterlock.commitOwnedInfrastructureRevision(
            from: snapshot.revision.ownedInfrastructure,
            to: DebuggerOwnedInfrastructureRevision(
                rawValue: snapshot.revision.ownedInfrastructure.rawValue + 1
            )
        ) {}
        await executor.releaseFirstStaging()

        _ = await XCTAssertThrowsExactAttachFailure(
            .admissionRejected,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            operation: { try await transaction.value }
        )
        let authorizationCount = await executor.exactFinalAuthorizationCountValue()
        let commitCount = await executor.finalWriteCommitCountValue()
        XCTAssertEqual(authorizationCount, 0)
        XCTAssertEqual(commitCount, 0)
    }

    func testMissingFinalWriteCommitCannotPublishAttachedAuthority() async throws {
        try await assertRejectedFinalWriteCommit(mode: .omitFinalWriteCommit)
    }

    func testIndependentFinalGrantReissuanceIsRejectedBeforeAnyCommit() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .returnDecoyFinalWriteCommit,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .adapterInvalidated,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await self.makeExactAttachInput(
                        request: request,
                        admissionSession: initial.sessionCoordinate,
                        executor: executor
                    )
                )
            }
        )
        let commitCount = await executor.finalWriteCommitCountValue()
        XCTAssertEqual(commitCount, 0)
    }

    func testForeignCoordinatorInterlockRejectsBeforeStaging() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let foreignInterlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
        let coordinator = PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: RejectingExactAttachPreparer(),
            capabilities: allOperationsEnabledCapabilities(),
            attachWriteInterlock: foreignInterlock
        )
        let initial = await coordinator.reducerState

        await XCTAssertThrowsCoordinatorFailure(
            .admissionRejected,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(
                        request: request,
                        admissionSession: initial.sessionCoordinate,
                        executor: executor
                    )
                )
            }
        )
        let executionCount = await executor.executionCountValue()
        XCTAssertEqual(executionCount, 0)
    }

    func testCoordinatorSealsCurrentExactAttachedExternalExitEvidence() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(
            executor: executor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let initial = await coordinator.reducerState
        let attached = try await coordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: initial.sessionCoordinate,
                executor: executor
            )
        )

        let execution = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: attached.reducerState.sessionCoordinate,
            requiredStop: nil
        )
        let result = try await coordinator.sealExactAttachedExternalExitResult(
            attachedSession: attached.attachedSession,
            executionResult: execution
        )
        let expectedAttachRequestCount = await executor.expectedRequestCount

        XCTAssertEqual(result.attachedSession, attached.attachedSession)
        XCTAssertEqual(
            result.adapterInstanceBindingDigest,
            attached.attachedSession.adapterInstanceBinding.digest
        )
        XCTAssertEqual(result.requestID, execution.requestID)
        XCTAssertEqual(result.requestID.epoch, epoch)
        XCTAssertEqual(
            result.requestID.sequence,
            UInt64(expectedAttachRequestCount + 1)
        )
        XCTAssertEqual(result.terminalLifecycleRevision, execution.reducerState.lifecycleRevision)
        XCTAssertEqual(result.processID, request.selectedIdentity.processID)
        XCTAssertEqual(result.exitStatus, 23)
        XCTAssertTrue(result.hasValidBinding())
        XCTAssertTrue(execution.reducerState.isInvalidated)
        XCTAssertNil(execution.reducerState.pendingRequest)
        XCTAssertNil(execution.reducerState.stopRevision)
    }

    func testExternalExitSealRejectsCallerReconstructedCurrentExecutionResult() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(
            executor: executor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let initial = await coordinator.reducerState
        let attached = try await coordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: initial.sessionCoordinate,
                executor: executor
            )
        )
        let execution = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: attached.reducerState.sessionCoordinate,
            requiredStop: nil
        )
        let reconstructed = PersistentLLDBSessionExecutionResult(
            requestID: execution.requestID,
            reducerState: execution.reducerState
        )

        XCTAssertEqual(reconstructed, execution)
        await XCTAssertRejectsExternalExitSeal {
            try await coordinator.sealExactAttachedExternalExitResult(
                attachedSession: attached.attachedSession,
                executionResult: reconstructed
            )
        }

        _ = try await coordinator.sealExactAttachedExternalExitResult(
            attachedSession: attached.attachedSession,
            executionResult: execution
        )
    }

    func testExternalExitSealRejectsStructurallyEqualResultMintedByDecoyCoordinator() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let realExecutor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let realCoordinator = makeCoordinator(
            executor: realExecutor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let realInitial = await realCoordinator.reducerState
        let realAttached = try await realCoordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: realInitial.sessionCoordinate,
                executor: realExecutor
            )
        )
        let realExecution = try await realCoordinator.perform(
            .pollProcessStatus,
            expectedSession: realAttached.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        let decoyExecutor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let decoyCoordinator = makeCoordinator(
            executor: decoyExecutor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let decoyInitial = await decoyCoordinator.reducerState
        let decoyAttached = try await decoyCoordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: decoyInitial.sessionCoordinate,
                executor: decoyExecutor
            )
        )
        let decoyExecution = try await decoyCoordinator.perform(
            .pollProcessStatus,
            expectedSession: decoyAttached.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        XCTAssertEqual(decoyExecution, realExecution)
        await XCTAssertRejectsExternalExitSeal {
            try await realCoordinator.sealExactAttachedExternalExitResult(
                attachedSession: realAttached.attachedSession,
                executionResult: decoyExecution
            )
        }

        _ = try await realCoordinator.sealExactAttachedExternalExitResult(
            attachedSession: realAttached.attachedSession,
            executionResult: realExecution
        )
    }

    func testExternalExitSealConsumesExactExecutionAuthorityAfterSuccess() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(
            executor: executor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let initial = await coordinator.reducerState
        let attached = try await coordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: initial.sessionCoordinate,
                executor: executor
            )
        )
        let execution = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: attached.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        _ = try await coordinator.sealExactAttachedExternalExitResult(
            attachedSession: attached.attachedSession,
            executionResult: execution
        )
        await XCTAssertRejectsExternalExitSeal {
            try await coordinator.sealExactAttachedExternalExitResult(
                attachedSession: attached.attachedSession,
                executionResult: execution
            )
        }
    }

    func testExternalExitSealRejectsLiveAndStaleExecutionResults() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(
            executor: executor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let initial = await coordinator.reducerState
        let attached = try await coordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: initial.sessionCoordinate,
                executor: executor
            )
        )
        let liveResult = PersistentLLDBSessionExecutionResult(
            requestID: attached.requestID,
            reducerState: attached.reducerState
        )

        await XCTAssertRejectsExternalExitSeal {
            try await coordinator.sealExactAttachedExternalExitResult(
                attachedSession: attached.attachedSession,
                executionResult: liveResult
            )
        }

        let exited = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: attached.reducerState.sessionCoordinate,
            requiredStop: nil
        )
        let staleResult = PersistentLLDBSessionExecutionResult(
            requestID: DebuggerRequestID(
                epoch: exited.requestID.epoch,
                sequence: exited.requestID.sequence - 1
            ),
            reducerState: exited.reducerState
        )
        await XCTAssertRejectsExternalExitSeal {
            try await coordinator.sealExactAttachedExternalExitResult(
                attachedSession: attached.attachedSession,
                executionResult: staleResult
            )
        }
    }

    func testExternalExitSealRejectsDecoyAttachedSessionEvidence() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let realExecutor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let realCoordinator = makeCoordinator(
            executor: realExecutor,
            requestPreparer: ExactAttachStatusRequestPreparer()
        )
        let realInitial = await realCoordinator.reducerState
        let realAttached = try await realCoordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: realInitial.sessionCoordinate,
                executor: realExecutor
            )
        )
        let exit = try await realCoordinator.perform(
            .pollProcessStatus,
            expectedSession: realAttached.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        let decoyExecutor = ExactAttachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let decoyCoordinator = makeCoordinator(executor: decoyExecutor)
        let decoyInitial = await decoyCoordinator.reducerState
        let decoyAttached = try await decoyCoordinator.performExactAttachTransaction(
            try await makeExactAttachInput(
                request: request,
                admissionSession: decoyInitial.sessionCoordinate,
                executor: decoyExecutor
            )
        )

        XCTAssertNotEqual(
            realAttached.attachedSession.adapterInstanceBinding,
            decoyAttached.attachedSession.adapterInstanceBinding
        )
        await XCTAssertRejectsExternalExitSeal {
            try await realCoordinator.sealExactAttachedExternalExitResult(
                attachedSession: decoyAttached.attachedSession,
                executionResult: exit
            )
        }
    }

    func testStagingFailureBeforeWriteNeverAdmitsAttach() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .failFirstStagingBeforeWrite,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        let failure = await XCTAssertThrowsExactAttachFailure(
            .adapterFailedBeforeWrite,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(failure?.finalRequestID?.sequence, UInt64(expectedRequestCount))

        let final = await coordinator.reducerState
        XCTAssertNil(final.pendingRequest)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertEqual(final.processPhase, .noTarget)
        XCTAssertEqual(final.targetDisposition, .notStarted)
        XCTAssertFalse(final.isInvalidated)
        XCTAssertNotNil(final.lastDiagnostic)
        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, 1)
    }

    func testCrossedStagingAuthorizationFailsBeforeWriteAndNeverMintsFinalGrant() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .crossSecondStagingAuthorization,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .adapterFailedBeforeWrite,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(
                        request: request,
                        admissionSession: initial.sessionCoordinate,
                        executor: executor
                    )
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertNil(final.pendingRequest)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertEqual(final.processPhase, .noTarget)
        XCTAssertEqual(final.targetDisposition, .notStarted)
        XCTAssertFalse(final.isInvalidated)
        let executionCount = await executor.executionCountValue()
        let stagingAuthorizationCount = await executor.exactStagingAuthorizationCountValue()
        let stagingConsumptionCount = await executor.exactStagingConsumptionCountValue()
        let finalAuthorizationCount = await executor.exactFinalAuthorizationCountValue()
        let finalWriteCommitCount = await executor.finalWriteCommitCountValue()
        XCTAssertEqual(executionCount, 2)
        XCTAssertEqual(stagingAuthorizationCount, 2)
        XCTAssertEqual(stagingConsumptionCount, 1)
        XCTAssertEqual(finalAuthorizationCount, 0)
        XCTAssertEqual(finalWriteCommitCount, 0)
    }

    func testFinalFailureBeforeWriteClearsAdmissionWithoutCreatingTargetAuthority() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .failFinalBeforeWrite,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .adapterFailedBeforeWrite,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertNil(final.pendingRequest)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertEqual(final.processPhase, .noTarget)
        XCTAssertEqual(final.targetDisposition, .notStarted)
        XCTAssertFalse(final.isInvalidated)
        let executionCount = await executor.executionCount
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(executionCount, expectedRequestCount)
    }

    func testPostFinalWriteUncertaintyInvalidatesWithoutRetryOrTargetAction() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .invalidateFinalAfterWrite,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .adapterInvalidated,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertTrue(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .invalidated)
        XCTAssertEqual(final.targetDisposition, .unknown)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.pendingRequest)
        let executionCount = await executor.executionCount
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(executionCount, expectedRequestCount)
    }

    func testContradictoryFinalTranscriptInvalidatesUnknownTarget() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .contradictFinalObservedState,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .invalidObservedProcess,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertTrue(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .invalidated)
        XCTAssertEqual(final.targetDisposition, .unknown)
        XCTAssertNil(final.acceptedTargetAuthority)
        let executionCount = await executor.executionCount
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(executionCount, expectedRequestCount)
    }

    func testUnexpectedStagingProcessObservationFailsBeforeFinalCommand() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .contradictFirstStagingObservation,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        await XCTAssertThrowsCoordinatorFailure(
            .invalidObservedProcess,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertNil(final.pendingRequest)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertEqual(final.processPhase, .invalidated)
        XCTAssertEqual(final.targetDisposition, .unknown)
        XCTAssertTrue(final.isInvalidated)
        let executionCount = await executor.executionCountValue()
        XCTAssertEqual(executionCount, 1)
    }

    func testWrongFinalGenerationInvalidatesUnknownTarget() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .mismatchFinalGeneration,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .responseCorrelationMismatch,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertTrue(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .invalidated)
        XCTAssertEqual(final.targetDisposition, .unknown)
        XCTAssertNil(final.acceptedTargetAuthority)
    }

    func testMalformedFinalReceiptInvalidatesUnknownWithoutRetry() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .malformedFinalReceipt,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .responseProjectionFailed,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertTrue(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .invalidated)
        XCTAssertEqual(final.targetDisposition, .unknown)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertNil(final.pendingRequest)
        let executionCount = await executor.executionCount
        let expectedRequestCount = await executor.expectedRequestCount
        XCTAssertEqual(executionCount, expectedRequestCount)
    }

    func testFinalCancellationBeforeWriteClearsAdmissionWithoutTarget() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .cancelFinalBeforeWrite,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .adapterCancelled,
            finalCommandDisposition: .definitelyNotDispatchedOrWritten,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertFalse(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .noTarget)
        XCTAssertEqual(final.targetDisposition, .notStarted)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertNil(final.pendingRequest)
    }

    func testWrongStagingResponseCorrelationClearsParentBeforeFinalAttach() async throws {
        for mode in [
            ExactAttachExecutor.Mode.mismatchFirstStagingRequest,
            .mismatchFirstStagingGeneration,
        ] {
            let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
            let executor = ExactAttachExecutor(
                mode: mode,
                epoch: epoch,
                attachRequest: request,
                generation: generation,
                token: token
            )
            let coordinator = makeCoordinator(executor: executor)
            let initial = await coordinator.reducerState

            await XCTAssertThrowsCoordinatorFailure(
                .responseCorrelationMismatch,
                operation: {
                    try await coordinator.performExactAttachTransaction(
                        try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                    )
                }
            )

            let final = await coordinator.reducerState
            XCTAssertFalse(final.isInvalidated)
            XCTAssertEqual(final.processPhase, .noTarget)
            XCTAssertEqual(final.targetDisposition, .notStarted)
            XCTAssertNil(final.acceptedTargetAuthority)
            XCTAssertNil(final.observedProcessID)
            XCTAssertNil(final.pendingRequest)
            let executionCount = await executor.executionCount
            XCTAssertEqual(executionCount, 1)
        }
    }

    func testFinalParentAdmissionBlocksASecondExactAttachDuringFirstStagingAwait() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .barrierAtFirstStaging,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let input = try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)

        let first = Task {
            try await coordinator.performExactAttachTransaction(input)
        }
        await executor.waitUntilFirstStagingStarts()

        await XCTAssertThrowsCoordinatorFailure(
            .admissionRejected,
            operation: {
                try await coordinator.performExactAttachTransaction(input)
            }
        )
        let blockedExecutionCount = await executor.executionCountValue()
        XCTAssertEqual(blockedExecutionCount, 1)

        await executor.releaseFirstStaging()
        let result = try await first.value
        XCTAssertEqual(
            result.reducerState.processPhase,
            .stopped(processID: request.selectedIdentity.processID, reason: .signal("5"))
        )
        let requests = await executor.requests
        let expectedCount = await executor.expectedRequestCount
        XCTAssertEqual(requests.count, expectedCount)
        XCTAssertEqual(
            requests.map { $0.context.id.sequence },
            Array(1...UInt64(expectedCount))
        )
    }

    func testWrongGenerationOnFinalPrewriteFailureInvalidatesUnknown() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .mismatchFinalFailureGeneration,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .adapterInvalidated,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertTrue(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .invalidated)
        XCTAssertEqual(final.targetDisposition, .unknown)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertNil(final.pendingRequest)
    }

    func testWrongGenerationOnStagingFailureRetiresAdapterWithoutUnknownTarget() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: .mismatchFirstStagingFailureGeneration,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        await XCTAssertThrowsCoordinatorFailure(
            .adapterInvalidated,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(request: request, admissionSession: initial.sessionCoordinate, executor: executor)
                )
            }
        )

        let final = await coordinator.reducerState
        XCTAssertFalse(final.isInvalidated)
        XCTAssertEqual(final.processPhase, .noTarget)
        XCTAssertEqual(final.targetDisposition, .notStarted)
        XCTAssertNil(final.acceptedTargetAuthority)
        XCTAssertNil(final.observedProcessID)
        XCTAssertNil(final.pendingRequest)
        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, 1)
    }

    private func assertRejectedFinalWriteCommit(
        mode: ExactAttachExecutor.Mode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachExecutor(
            mode: mode,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            token: token
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        _ = await XCTAssertThrowsExactAttachFailure(
            .responseCorrelationMismatch,
            finalCommandDisposition: .mayHaveWrittenOrAcceptedAuthority,
            operation: {
                try await coordinator.performExactAttachTransaction(
                    try await makeExactAttachInput(
                        request: request,
                        admissionSession: initial.sessionCoordinate,
                        executor: executor
                    )
                )
            },
            file: file,
            line: line
        )

        let final = await coordinator.reducerState
        XCTAssertTrue(final.isInvalidated, file: file, line: line)
        XCTAssertNil(final.acceptedTargetAuthority, file: file, line: line)
        XCTAssertNil(final.observedProcessID, file: file, line: line)
        let authorizationCount = await executor.exactFinalAuthorizationCountValue()
        XCTAssertEqual(authorizationCount, 1, file: file, line: line)
    }

    private func makeExactAttachInput(
        request: DebuggerLocalAttachRequest,
        admissionSession: DebuggerSessionCoordinate,
        executor: ExactAttachExecutor
    ) async throws -> PersistentLLDBExactAttachTransactionInput {
        let authority = DebuggerSessionTargetAuthority(origin: .attached(request.selectedIdentity))
        let registry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: executor.attachWriteInterlock
        )
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: admissionSession.epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: admissionSession,
            adapterGeneration: generation,
            attachWriteInterlockSnapshot: executor.attachWriteInterlock.currentSnapshot
        )
        await executor.configure(
            correlationToken: permit.correlationToken,
            instanceBinding: await makeAdapterInstanceBinding()
        )
        return PersistentLLDBExactAttachTransactionInput(request: request, permit: permit)
    }

    private func makeCoordinator(
        executor: ExactAttachExecutor,
        requestPreparer: any PersistentLLDBCLIRequestPreparing = RejectingExactAttachPreparer(),
        exactAttachClaimBoundaryAction: (@Sendable (
            DebuggerLocalProcessExactAttachTransactionClaimInput
        ) -> Void)? = nil
    ) -> PersistentLLDBSessionCoordinator {
        PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: requestPreparer,
            capabilities: allOperationsEnabledCapabilities(),
            attachWriteInterlock: executor.attachWriteInterlock,
            exactAttachClaimBoundaryAction: exactAttachClaimBoundaryAction
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

    private func makeAdapterInstanceBinding() async -> PersistentLLDBCLIAdapterInstanceBinding {
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: ExactAttachBindingChannel(),
            retainedProcess: ExactAttachBindingProcess(),
            markerSecret: Data(repeating: 0x72, count: 32)
        )
        return await adapter.adapterInstanceBinding()
    }

    private func identity(
        processID: Int32 = 7_777,
        canonicalExecutablePath: String = "/tmp/MacScopeExactAttachFixture",
        executableFileID: UInt64 = 7_001,
        executableSHA256: String = String(repeating: "a", count: 64),
        machOUUID: UUID? = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    ) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: canonicalExecutablePath,
            executableDeviceID: 7,
            executableFileID: executableFileID,
            executableByteCount: 4_096,
            executableSHA256: executableSHA256,
            architecture: .arm64,
            machOUUID: machOUUID,
            codeIdentity: nil
        ))
    }

    private func frozenCommands(
        request: DebuggerLocalAttachRequest,
        finalSequence: UInt64,
        correlationToken: Data
    ) throws -> [String] {
        let authority = DebuggerSessionTargetAuthority(origin: .attached(request.selectedIdentity))
        let programRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: finalSequence,
            adapterGeneration: generation,
            authority: authority,
            correlationToken: correlationToken
        )
        let program = PersistentLLDBAttachProgram.current
        return program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: programRequest))
    }

    private func XCTAssertThrowsCoordinatorFailure<T>(
        _ code: PersistentLLDBSessionCoordinatorFailureCode,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected coordinator failure.", file: file, line: line)
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func XCTAssertThrowsExactAttachFailure<T>(
        _ code: PersistentLLDBSessionCoordinatorFailureCode,
        finalCommandDisposition: PersistentLLDBExactAttachFinalCommandDisposition,
        finalRequestWasAdmitted: Bool = true,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> PersistentLLDBExactAttachTransactionFailure? {
        do {
            _ = try await operation()
            XCTFail("Expected exact attach transaction failure.", file: file, line: line)
            return nil
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
            XCTAssertEqual(
                failure.finalCommandDisposition,
                finalCommandDisposition,
                file: file,
                line: line
            )
            XCTAssertEqual(
                failure.finalRequestID?.epoch,
                failure.reducerState.epoch,
                file: file,
                line: line
            )
            if finalRequestWasAdmitted {
                XCTAssertEqual(
                    failure.finalRequestID?.sequence,
                    failure.reducerState.lastAdmittedRequestSequence,
                    file: file,
                    line: line
                )
            } else if let finalRequestSequence = failure.finalRequestID?.sequence {
                XCTAssertGreaterThan(
                    finalRequestSequence,
                    failure.reducerState.lastAdmittedRequestSequence,
                    file: file,
                    line: line
                )
            } else {
                XCTFail("Expected a reserved final request identity.", file: file, line: line)
            }
            return failure
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }

    private func XCTAssertRejectsExternalExitSeal<T>(
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected external-exit seal rejection.", file: file, line: line)
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor ExactAttachExecutor: PersistentLLDBCLIExecuting {
    enum Mode: Equatable, Sendable {
        case success
        case failFirstStagingBeforeWrite
        case failFinalBeforeWrite
        case invalidateFinalAfterWrite
        case contradictFinalObservedState
        case contradictFirstStagingObservation
        case mismatchFinalGeneration
        case malformedFinalReceipt
        case cancelFinalBeforeWrite
        case mismatchFirstStagingRequest
        case mismatchFirstStagingGeneration
        case barrierAtFirstStaging
        case mismatchFinalFailureGeneration
        case mismatchFirstStagingFailureGeneration
        case omitFinalWriteCommit
        case returnDecoyFinalWriteCommit
        case crossSecondStagingAuthorization
    }

    private let mode: Mode
    private let epoch: DebuggerSessionEpoch
    private let attachRequest: DebuggerLocalAttachRequest
    private let generation: UInt64
    nonisolated let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    private var instanceBinding: PersistentLLDBCLIAdapterInstanceBinding?
    private var token: Data
    private(set) var requests: [PersistentLLDBCLIRequest] = []
    private var firstStagingDidStart = false
    private var firstStagingStartWaiter: CheckedContinuation<Void, Never>?
    private var firstStagingRelease: CheckedContinuation<Void, Never>?
    private var exactStagingAuthorizationCount = 0
    private var exactStagingConsumptionCount = 0
    private var firstStagingIssuanceInput:
        DebuggerLocalProcessAttachStagingWriteIssuanceInput?
    private var exactFinalAuthorizationCount = 0
    private var finalWriteCommitCount = 0

    init(
        mode: Mode,
        epoch: DebuggerSessionEpoch,
        attachRequest: DebuggerLocalAttachRequest,
        generation: UInt64,
        token: Data
    ) {
        self.mode = mode
        self.epoch = epoch
        self.attachRequest = attachRequest
        self.generation = generation
        self.token = token
        self.attachWriteInterlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
    }

    func exactAdapterInstanceBinding() -> PersistentLLDBCLIAdapterInstanceBinding? {
        instanceBinding
    }

    var executionCount: Int { requests.count }

    func configure(
        correlationToken: Data,
        instanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    ) {
        precondition(requests.isEmpty)
        token = correlationToken
        self.instanceBinding = instanceBinding
    }

    func executionCountValue() -> Int { requests.count }

    func exactStagingAuthorizationCountValue() -> Int {
        exactStagingAuthorizationCount
    }

    func exactStagingConsumptionCountValue() -> Int {
        exactStagingConsumptionCount
    }

    func exactFinalAuthorizationCountValue() -> Int { exactFinalAuthorizationCount }

    func finalWriteCommitCountValue() -> Int { finalWriteCommitCount }

    func waitUntilFirstStagingStarts() async {
        if firstStagingDidStart { return }
        await withCheckedContinuation { continuation in
            firstStagingStartWaiter = continuation
        }
    }

    func releaseFirstStaging() {
        firstStagingRelease?.resume()
        firstStagingRelease = nil
    }

    var expectedRequestCount: Int {
        let finalSequence = UInt64(
            PersistentLLDBAttachProgram.current.installChunkCommands.count
                + 1
                + pathCommandCount
        )
        return Int(finalSequence)
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        requests.append(request)
        if case .exactAttachFinal = request.writeRole {
            exactFinalAuthorizationCount += 1
        }
        if requests.count > expectedRequestCount {
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
                generation: generation,
                transcript: LLDBCLITranscriptResult(
                    transcript: "",
                    authoritativeStatusTranscript: "",
                    observedProcessID: attachRequest.selectedIdentity.processID,
                    observedProcessState: .exited(
                        processID: attachRequest.selectedIdentity.processID,
                        status: 23
                    ),
                    exchangeByteCount: 1,
                    exchangeSHA256: String(repeating: "e", count: 64),
                    semanticCommandTranscripts: [""],
                    semanticCommandResultLineByteCounts: [1]
                )
            )
        }
        let isFinal = request.context.id.sequence == UInt64(expectedRequestCount)

        if mode == .failFirstStagingBeforeWrite, requests.count == 1 {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: request.context.id,
                generation: generation,
                disposition: .failedBeforeWrite
            )
        }
        if mode == .mismatchFirstStagingFailureGeneration, requests.count == 1 {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: request.context.id,
                generation: generation + 1,
                disposition: .failedBeforeWrite
            )
        }
        if !isFinal {
            guard case .exactAttachStaging(let wrappedAuthorization) = request.writeRole,
                  let wrappedAuthorization else {
                throw PersistentLLDBCLIAdapterFailure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            }
            let issuanceInput = wrappedAuthorization.issuanceInput
            let stagingCount = UInt64(issuanceInput.canonicalStagingCommandCount)
            let ordinal = UInt64(issuanceInput.stagingOrdinal)
            let firstSequence = issuanceInput.finalAttachRequest.id.sequence
                .subtractingReportingOverflow(stagingCount)
            let expectedSequence = firstSequence.partialValue
                .addingReportingOverflow(ordinal)
            guard request.context == issuanceInput.stagingRequest,
                  request.observedPIDRequirement == .optional,
                  instanceBinding == issuanceInput.adapterInstanceBinding,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == issuanceInput.semanticDigest,
                  issuanceInput.stagingOrdinal == requests.count - 1,
                  issuanceInput.canonicalStagingCommandCount == expectedRequestCount - 1,
                  !firstSequence.overflow,
                  !expectedSequence.overflow,
                  request.context.id.sequence == expectedSequence.partialValue else {
                throw PersistentLLDBCLIAdapterFailure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            }
            exactStagingAuthorizationCount += 1
            if mode == .crossSecondStagingAuthorization, requests.count == 1 {
                firstStagingIssuanceInput = issuanceInput
            }
            if mode == .crossSecondStagingAuthorization, requests.count == 2 {
                guard let firstStagingIssuanceInput else {
                    throw ExactAttachTestError.missingFirstStagingIssuanceInput
                }
                do {
                    try wrappedAuthorization.interlock
                        .consumeExactAttachStagingWriteAuthorization(
                            wrappedAuthorization.authorization,
                            matching: firstStagingIssuanceInput
                        )
                } catch {
                    throw PersistentLLDBCLIAdapterFailure(
                        code: .exactAttachWriteRejected,
                        requestID: request.context.id,
                        generation: generation,
                        disposition: .failedBeforeWrite
                    )
                }
                throw ExactAttachTestError.crossedStagingAuthorizationWasAccepted
            }
            do {
                try wrappedAuthorization.interlock
                    .consumeExactAttachStagingWriteAuthorization(
                        wrappedAuthorization.authorization,
                        matching: wrappedAuthorization.issuanceInput
                    )
                exactStagingConsumptionCount += 1
            } catch {
                throw PersistentLLDBCLIAdapterFailure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            }
        }
        if isFinal, mode == .failFinalBeforeWrite {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: request.context.id,
                generation: generation,
                disposition: .failedBeforeWrite
            )
        }
        if isFinal, mode == .cancelFinalBeforeWrite {
            throw PersistentLLDBCLIAdapterFailure(
                code: .cancelledBeforeWrite,
                requestID: request.context.id,
                generation: generation,
                disposition: .cancelledBeforeWrite
            )
        }
        if isFinal, mode == .mismatchFinalFailureGeneration {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: request.context.id,
                generation: generation + 1,
                disposition: .failedBeforeWrite
            )
        }
        if isFinal, mode == .invalidateFinalAfterWrite {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidatedGeneration,
                requestID: request.context.id,
                generation: generation,
                disposition: .invalidatedAfterWrite(
                    reason: .timeoutAfterWrite,
                    target: .unknown
                )
            )
        }
        if isFinal {
            let exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit?
            switch mode {
            case .omitFinalWriteCommit:
                exactAttachWriteCommit = nil
            case .returnDecoyFinalWriteCommit:
                exactAttachWriteCommit = try decoyExactAttachWriteCommit(for: request)
            default:
                exactAttachWriteCommit = try commitExactAttachWrite(for: request)
            }
            if mode == .malformedFinalReceipt {
                let malformed = PersistentLLDBAttachProgram.receiptSentinel
                    + Data("{}".utf8).base64EncodedString()
                    + "\n"
                return PersistentLLDBCLIResponse(
                    requestID: request.context.id,
                    generation: generation,
                    transcript: LLDBCLITranscriptResult(
                        transcript: "",
                        authoritativeStatusTranscript: "",
                        observedProcessID: attachRequest.selectedIdentity.processID,
                        observedProcessState: .stopped(
                            processID: attachRequest.selectedIdentity.processID
                        ),
                        exchangeByteCount: malformed.utf8.count,
                        exchangeSHA256: String(repeating: "d", count: 64),
                        semanticCommandTranscripts: [malformed],
                        semanticCommandResultLineByteCounts: [malformed.utf8.count]
                    ),
                    exactAttachWriteCommit: exactAttachWriteCommit
                )
            }
            let response = try finalResponse(
                context: request.context,
                observedState: mode == .contradictFinalObservedState
                    ? .running(processID: attachRequest.selectedIdentity.processID)
                    : .stopped(processID: attachRequest.selectedIdentity.processID),
                exactAttachWriteCommit: exactAttachWriteCommit
            )
            if mode == .mismatchFinalGeneration {
                return PersistentLLDBCLIResponse(
                    requestID: response.requestID,
                    generation: generation + 1,
                    transcript: response.transcript,
                    exactAttachWriteCommit: response.exactAttachWriteCommit
                )
            }
            return response
        }
        if requests.count == 1, mode == .mismatchFirstStagingRequest {
            let response = stagingResponse(context: request.context)
            return PersistentLLDBCLIResponse(
                requestID: DebuggerRequestID(
                    epoch: request.context.id.epoch,
                    sequence: request.context.id.sequence + 1
                ),
                generation: response.generation,
                transcript: response.transcript
            )
        }
        if requests.count == 1, mode == .mismatchFirstStagingGeneration {
            let response = stagingResponse(context: request.context)
            return PersistentLLDBCLIResponse(
                requestID: response.requestID,
                generation: generation + 1,
                transcript: response.transcript
            )
        }
        if requests.count == 1, mode == .barrierAtFirstStaging {
            firstStagingDidStart = true
            firstStagingStartWaiter?.resume()
            firstStagingStartWaiter = nil
            await withCheckedContinuation { continuation in
                firstStagingRelease = continuation
            }
        }
        if mode == .contradictFirstStagingObservation, requests.count == 1 {
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
                generation: generation,
                transcript: LLDBCLITranscriptResult(
                    transcript: "",
                    authoritativeStatusTranscript: "",
                    observedProcessID: attachRequest.selectedIdentity.processID,
                    observedProcessState: .stopped(
                        processID: attachRequest.selectedIdentity.processID
                    ),
                    exchangeByteCount: 1,
                    exchangeSHA256: String(repeating: "c", count: 64),
                    semanticCommandTranscripts: [""],
                    semanticCommandResultLineByteCounts: [1]
                )
            )
        }
        return stagingResponse(context: request.context)
    }

    private var pathCommandCount: Int {
        let pathByteCount = Data(attachRequest.selectedIdentity.canonicalExecutablePath.utf8)
            .base64EncodedString().utf8.count
        let chunkCount = (pathByteCount + PersistentLLDBAttachProgram.pathChunkCharacterCount - 1)
            / PersistentLLDBAttachProgram.pathChunkCharacterCount
        return chunkCount + 1
    }

    private func stagingResponse(
        context: DebuggerRequestContext
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: context.id,
            generation: generation,
            transcript: LLDBCLITranscriptResult(
                transcript: "",
                authoritativeStatusTranscript: "",
                observedProcessID: nil,
                observedProcessState: nil,
                exchangeByteCount: 1,
                exchangeSHA256: String(repeating: "a", count: 64),
                semanticCommandTranscripts: [""],
                semanticCommandResultLineByteCounts: [1]
            )
        )
    }

    private func finalResponse(
        context: DebuggerRequestContext,
        observedState: LLDBCLIObservedProcessState,
        exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit?
    ) throws -> PersistentLLDBCLIResponse {
        let authority = DebuggerSessionTargetAuthority(origin: .attached(attachRequest.selectedIdentity))
        let programRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: context.id.sequence,
            adapterGeneration: generation,
            authority: authority,
            correlationToken: token
        )
        let framed = PersistentLLDBAttachProgram.receiptSentinel
            + receiptBytes(for: programRequest).base64EncodedString()
            + "\n"
        return PersistentLLDBCLIResponse(
            requestID: context.id,
            generation: generation,
            transcript: LLDBCLITranscriptResult(
                transcript: "",
                authoritativeStatusTranscript: "",
                observedProcessID: authority.processID,
                observedProcessState: observedState,
                exchangeByteCount: framed.utf8.count,
                exchangeSHA256: String(repeating: "b", count: 64),
                semanticCommandTranscripts: [framed],
                semanticCommandResultLineByteCounts: [framed.utf8.count]
            ),
            exactAttachWriteCommit: exactAttachWriteCommit
        )
    }

    private func commitExactAttachWrite(
        for request: PersistentLLDBCLIRequest
    ) throws -> DebuggerLocalProcessAttachWriteCommit {
        guard case .exactAttachFinal(let authorization?) = request.writeRole else {
            throw ExactAttachTestError.missingFinalWriteAuthorization
        }
        let commit = try authorization.interlock.commitExactAttachWrite(
            authorization.grant,
            matching: authorization.issuanceInput
        )
        finalWriteCommitCount += 1
        return commit
    }

    private func decoyExactAttachWriteCommit(
        for request: PersistentLLDBCLIRequest
    ) throws -> DebuggerLocalProcessAttachWriteCommit {
        guard case .exactAttachFinal(let authorization?) = request.writeRole else {
            throw ExactAttachTestError.missingFinalWriteAuthorization
        }
        let decoyGrant = try authorization.interlock.issueExactAttachWriteGrant(
            for: authorization.issuanceInput
        )
        let commit = try authorization.interlock.commitExactAttachWrite(
            decoyGrant,
            matching: authorization.issuanceInput
        )
        finalWriteCommitCount += 1
        return commit
    }

    private func receiptBytes(for request: PersistentLLDBAttachProgramRequest) -> Data {
        let payload = Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(request.adapterGeneration)),
            "correlation_token": .string(hex(request.correlationToken)),
            "error": .object([
                "code": .number("0"),
                "kind": .number("0"),
                "message_b64": .string(""),
                "message_truncated": .bool(false),
            ]),
            "lldb_unique_id": .number("8811"),
            "observed_pid": .number(String(request.authority.processID)),
            "request_sequence": .number(String(request.requestSequence)),
            "requested_pid": .number(String(request.authority.processID)),
            "schema": .number("1"),
            "selected_thread_id": .number("44"),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
            "state": .string("stopped"),
            "stop_id": .number("19"),
            "stop_reason": .object([
                "data": .array([.number("5")]),
                "data_truncated": .bool(false),
                "kind": .string("signal"),
            ]),
            "target_path_b64": .string(
                Data(request.identity.canonicalExecutablePath.utf8).base64EncodedString()
            ),
            "target_uuid": .string(request.identity.machOUUID!.uuidString.lowercased()),
        ])
        let payloadBytes = payload.canonicalJSONBytes()
        return Phase2ProductionJSONValue.object([
            "payload": payload,
            "payload_sha256": .string(
                SHA256.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()
            ),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private actor RejectingExactAttachPreparer: PersistentLLDBCLIRequestPreparing {
    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        throw ExactAttachTestError.genericPreparerMustNotBeUsed
    }
}

private actor ExactAttachStatusRequestPreparer: PersistentLLDBCLIRequestPreparing {
    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: ["process status"],
            observedPIDRequirement: .required,
            timeout: .seconds(1)
        )
    }
}

private enum ExactAttachTestError: Error {
    case genericPreparerMustNotBeUsed
    case missingFinalWriteAuthorization
    case missingFirstStagingIssuanceInput
    case crossedStagingAuthorizationWasAccepted
}

private actor ExactAttachBindingChannel: PersistentLLDBCLIByteChannel {
    func write(_ data: Data) async throws {}
    func nextBytes() async throws -> Data? { nil }
    func closeInput() async {}
    func closeHandles() async {}
}

private actor ExactAttachBindingProcess: PersistentLLDBCLIRetainedProcess {
    func waitForExit(maximumDuration: Duration) async -> Bool { true }
    func terminateRetainedAdapter() async {}
    func killRetainedAdapterIfStillRunning() async -> Bool { true }
    func reapAndClose() async -> Bool { true }
}

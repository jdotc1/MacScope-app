import CryptoKit
import Foundation
import XCTest

@testable import MacScope

final class DebuggerPersistentLLDBExactDetachTransactionTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "91919191-9191-9191-9191-919191919191")!
    )
    private let generation: UInt64 = 1
    private let attachToken = Data(repeating: 0x31, count: 32)
    private let detachToken = Data(repeating: 0x42, count: 32)
    private let lldbUniqueID: UInt64 = 8_811

    func testSuccessUsesContiguousPrivateRequestsAndPublishesOnlyStartedThenDetached() async throws {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachDetachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            attachToken: attachToken,
            detachToken: detachToken,
            lldbUniqueID: lldbUniqueID
        )
        let coordinator = makeCoordinator(executor: executor)
        let attached = try await establishAttached(
            request,
            coordinator: coordinator,
            executor: executor
        )

        let outcome = try await coordinator.performExactDetachTransaction(
            detachInput(from: attached.attachedSession)
        )
        let detached = try requireDetached(outcome)

        let detachRequests = await executor.detachRequests
        let attachCount = await executor.attachRequestCount
        let expectedCommands = try frozenDetachCommands(
            authority: try XCTUnwrap(attached.reducerState.acceptedTargetAuthority),
            finalSequence: UInt64(attachCount + detachRequests.count),
            attachedSession: attached.attachedSession
        )
        XCTAssertEqual(detachRequests.map(\.context.id.sequence), Array(
            UInt64(attachCount + 1)...UInt64(attachCount + expectedCommands.count)
        ))
        XCTAssertEqual(detachRequests.map(\.semanticCommands), expectedCommands.map { [$0] })
        XCTAssertTrue(detachRequests.dropLast().allSatisfy {
            $0.observedPIDRequirement == .required
        })
        XCTAssertEqual(detachRequests.last?.observedPIDRequirement, .optional)
        XCTAssertFalse(detachRequests.flatMap(\.semanticCommands).contains("process kill"))
        XCTAssertFalse(detachRequests.flatMap(\.semanticCommands).contains("quit"))
        XCTAssertEqual(detached.requestID.epoch, detached.reducerState.epoch)
        XCTAssertEqual(
            detached.requestID.sequence,
            detached.reducerState.lastAdmittedRequestSequence
        )
        XCTAssertEqual(detached.requestID, try XCTUnwrap(detachRequests.last).context.id)
        XCTAssertEqual(detached.receipt.observedProcessID, request.selectedIdentity.processID)
        XCTAssertEqual(detached.receipt.lldbProcessUniqueID, lldbUniqueID)
        XCTAssertEqual(detached.reducerState.processPhase, .detached(processID: request.selectedIdentity.processID))
        XCTAssertEqual(detached.reducerState.targetDisposition, .detached)
        XCTAssertTrue(detached.reducerState.isInvalidated)
        XCTAssertNil(detached.reducerState.pendingRequest)
        XCTAssertNil(detached.reducerState.stopRevision)
        XCTAssertEqual(detached.reducerState.lastAcceptedEventSequence.rawValue, 6)
    }

    func testSealedTerminalReleaseAtomicallyRemovesLeaseAndPermitsReacquisition() async throws {
        let selectedIdentity = try identity()
        let request = DebuggerLocalAttachRequest(selectedIdentity: selectedIdentity)
        let provider = ExactDetachRegistryEvidenceProvider(
            evidence: try authorizationEvidence(identity: selectedIdentity)
        )
        let retirementAdapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: ExactDetachBindingChannel(),
            retainedProcess: ExactDetachBindingProcess(),
            markerSecret: Data(repeating: 0x74, count: 32)
        )
        let executor = ExactAttachDetachExecutor(
            mode: .success,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            attachToken: attachToken,
            detachToken: detachToken,
            lldbUniqueID: lldbUniqueID
        )
        let registry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: provider,
            attachWriteInterlock: executor.attachWriteInterlock
        )
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState
        let authority = DebuggerSessionTargetAuthority(origin: .attached(selectedIdentity))
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: initial.sessionCoordinate,
            adapterGeneration: generation,
            attachWriteInterlockSnapshot: executor.attachWriteInterlock.currentSnapshot
        )
        await executor.configure(
            permit: permit,
            instanceBinding: await retirementAdapter.adapterInstanceBinding()
        )
        let attached = try await coordinator.performExactAttachTransaction(
            PersistentLLDBExactAttachTransactionInput(request: request, permit: permit)
        )
        _ = try await registry.confirmExactAttach(attached)
        let outcome = try await coordinator.performExactDetachTransaction(
            detachInput(from: attached.attachedSession)
        )
        let detached = try requireDetached(outcome)
        let retirement = await retirementAdapter
            .retireExactAttachedAdapterWithoutDebuggerCommand(
                boundTo: attached.attachedSession
            )
        guard case .proven(let adapterProof) = retirement else {
            return XCTFail("The exact bound adapter must produce sealed command-free retirement proof.")
        }

        try await registry.completeExactAttachedTerminalRelease(
            detach: detached,
            adapterRetirement: adapterProof
        )

        let activeLeaseCount = await registry.activeLeaseCount
        let observationCount = await provider.observationCount
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(observationCount, 4)
        do {
            _ = try await registry.state(for: reservation)
            XCTFail("Atomic release must remove the old reservation and both ownership indexes.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .staleReservation)
        }
        let reacquired = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: authority
        )
        let reacquiredState = try await registry.state(for: reacquired)
        XCTAssertEqual(reacquiredState, .reservedBeforeWrite)
    }

    func testExactExitDuringFirstStagingReturnsSealedTargetExitAndDispatchesNothingLater() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(
            mode: .firstDetachStagingReportsExit
        )

        let outcome = try await coordinator.performExactDetachTransaction(
            detachInput(from: attached.attachedSession)
        )
        let (externalExit, terminalState) = try requireTargetExited(outcome)

        let detachRequests = await executor.detachRequests
        XCTAssertEqual(detachRequests.count, 1)
        XCTAssertEqual(detachRequests.first?.observedPIDRequirement, .required)
        XCTAssertEqual(externalExit.attachedSession, attached.attachedSession)
        XCTAssertEqual(externalExit.processID, attached.attachedSession.permit.authority.processID)
        XCTAssertEqual(externalExit.exitStatus, 23)
        XCTAssertTrue(externalExit.hasValidBinding())
        XCTAssertEqual(externalExit.requestID.epoch, epoch)
        XCTAssertEqual(externalExit.requestID.sequence, terminalState.lastAdmittedRequestSequence)
        XCTAssertNotEqual(externalExit.requestID, try XCTUnwrap(detachRequests.first).context.id)
        XCTAssertEqual(
            terminalState.processPhase,
            .exited(processID: externalExit.processID, code: externalExit.exitStatus)
        )
        XCTAssertEqual(terminalState.targetDisposition, .exited(code: 23))
        XCTAssertTrue(terminalState.isInvalidated)
        XCTAssertNil(terminalState.pendingRequest)
        XCTAssertNil(terminalState.stopRevision)
    }

    func testExactExitInFinalResponseNeedsNoDetachReceiptAndNeverRetries() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(
            mode: .finalDetachReportsExitWithoutReceipt
        )

        let outcome = try await coordinator.performExactDetachTransaction(
            detachInput(from: attached.attachedSession)
        )
        let (externalExit, terminalState) = try requireTargetExited(outcome)

        let detachRequests = await executor.detachRequests
        let expectedDetachRequestCount = await executor.expectedDetachRequestCount
        XCTAssertEqual(detachRequests.count, expectedDetachRequestCount)
        XCTAssertEqual(detachRequests.last?.observedPIDRequirement, .optional)
        XCTAssertEqual(detachRequests.last?.context.id, externalExit.requestID)
        XCTAssertEqual(externalExit.processID, attached.attachedSession.permit.authority.processID)
        XCTAssertEqual(externalExit.exitStatus, 29)
        XCTAssertTrue(externalExit.hasValidBinding())
        XCTAssertEqual(
            terminalState.processPhase,
            .exited(processID: externalExit.processID, code: externalExit.exitStatus)
        )
        XCTAssertEqual(terminalState.targetDisposition, .exited(code: 29))
        XCTAssertTrue(terminalState.isInvalidated)
        XCTAssertNil(terminalState.pendingRequest)
    }

    func testWrongPIDExitDuringStagingFailsClosedAndDispatchesNothingLater() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(
            mode: .firstDetachStagingReportsWrongPIDExit
        )

        await XCTAssertThrowsCoordinatorFailure(.invalidObservedProcess) {
            try await coordinator.performExactDetachTransaction(
                self.detachInput(from: attached.attachedSession)
            )
        }

        let after = await coordinator.reducerState
        let detachExecutionCount = await executor.detachExecutionCount
        XCTAssertEqual(detachExecutionCount, 1)
        XCTAssertEqual(after.processPhase, .invalidated)
        XCTAssertEqual(after.targetDisposition, .unknown)
        XCTAssertTrue(after.isInvalidated)
        XCTAssertNil(after.pendingRequest)
    }

    func testFinalExitPIDAndCorrelationMismatchesFailClosedWithoutRetry() async throws {
        let cases: [(ExactAttachDetachExecutor.Mode, PersistentLLDBSessionCoordinatorFailureCode)] = [
            (.finalExitObservedPIDIsWrong, .invalidObservedProcess),
            (.finalExitStatePIDIsWrong, .invalidObservedProcess),
            (.finalExitBothPIDsAreWrong, .invalidObservedProcess),
            (.finalExitRequestIDIsWrong, .responseCorrelationMismatch),
            (.finalExitGenerationIsWrong, .responseCorrelationMismatch),
        ]
        for (mode, expectedFailure) in cases {
            let (coordinator, executor, attached) = try await attachedFixture(mode: mode)

            await XCTAssertThrowsCoordinatorFailure(expectedFailure) {
                try await coordinator.performExactDetachTransaction(
                    self.detachInput(from: attached.attachedSession)
                )
            }

            let after = await coordinator.reducerState
            let detachExecutionCount = await executor.detachExecutionCount
            let expectedDetachRequestCount = await executor.expectedDetachRequestCount
            XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount, "mode: \(mode)")
            XCTAssertEqual(after.processPhase, .invalidated, "mode: \(mode)")
            XCTAssertEqual(after.targetDisposition, .unknown, "mode: \(mode)")
            XCTAssertTrue(after.isInvalidated, "mode: \(mode)")
            XCTAssertNil(after.pendingRequest, "mode: \(mode)")
        }
    }

    func testFirstStagingFailureBeforeWriteSendsNoDetachAndPreservesExactLiveAuthority() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(mode: .failFirstDetachBeforeWrite)
        let before = attached.reducerState

        await XCTAssertThrowsPreFinalFailure(.adapterFailedBeforeWrite, preserving: before) {
            try await coordinator.performExactDetachTransaction(self.detachInput(from: attached.attachedSession))
        }

        let after = await coordinator.reducerState
        let detachExecutionCount = await executor.detachExecutionCount
        XCTAssertEqual(detachExecutionCount, 1)
        XCTAssertEqual(after.processPhase, before.processPhase)
        XCTAssertEqual(after.targetDisposition, before.targetDisposition)
        XCTAssertEqual(after.observedProcessID, before.observedProcessID)
        XCTAssertEqual(after.acceptedTargetAuthority, before.acceptedTargetAuthority)
        XCTAssertEqual(after.stopCoordinate, before.stopCoordinate)
        XCTAssertFalse(after.isInvalidated)
        XCTAssertNil(after.pendingRequest)
    }

    func testFinalFailureBeforeWritePreservesExactLiveAuthorityWithoutPublishingDetaching() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(mode: .failFinalDetachBeforeWrite)
        let before = attached.reducerState

        await XCTAssertThrowsCoordinatorFailure(.adapterFailedBeforeWrite) {
            try await coordinator.performExactDetachTransaction(self.detachInput(from: attached.attachedSession))
        }

        let after = await coordinator.reducerState
        let detachExecutionCount = await executor.detachExecutionCount
        let expectedDetachRequestCount = await executor.expectedDetachRequestCount
        XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount)
        XCTAssertEqual(after.processPhase, before.processPhase)
        XCTAssertEqual(after.targetDisposition, before.targetDisposition)
        XCTAssertEqual(after.acceptedTargetAuthority, before.acceptedTargetAuthority)
        XCTAssertFalse(after.isInvalidated)
        XCTAssertNil(after.pendingRequest)
    }

    func testStagingAdapterRetirementFailuresPreserveExactLiveAuthority() async throws {
        for mode in [
            ExactAttachDetachExecutor.Mode.invalidateFirstDetachStagingAfterWrite,
            .completeFirstDetachStagingAsThrownFailure,
            .misCorrelateFirstDetachStagingFailure,
        ] {
            let (coordinator, executor, attached) = try await attachedFixture(mode: mode)
            let before = attached.reducerState

            await XCTAssertThrowsPreFinalFailure(.adapterInvalidated, preserving: before) {
                try await coordinator.performExactDetachTransaction(self.detachInput(from: attached.attachedSession))
            }

            let after = await coordinator.reducerState
            let detachExecutionCount = await executor.detachExecutionCount
            XCTAssertEqual(detachExecutionCount, 1)
            XCTAssertEqual(after.processPhase, before.processPhase)
            XCTAssertEqual(after.targetDisposition, before.targetDisposition)
            XCTAssertEqual(after.observedProcessID, before.observedProcessID)
            XCTAssertEqual(after.acceptedTargetAuthority, before.acceptedTargetAuthority)
            XCTAssertEqual(after.stopCoordinate, before.stopCoordinate)
            XCTAssertFalse(after.isInvalidated)
            XCTAssertNil(after.pendingRequest)
        }
    }

    func testWrongStagingResponseCorrelationPreservesExactLiveAuthority() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(
            mode: .misCorrelateFirstDetachStagingResponse
        )
        let before = attached.reducerState

        await XCTAssertThrowsPreFinalFailure(.responseCorrelationMismatch, preserving: before) {
            try await coordinator.performExactDetachTransaction(self.detachInput(from: attached.attachedSession))
        }

        let after = await coordinator.reducerState
        let detachExecutionCount = await executor.detachExecutionCount
        XCTAssertEqual(detachExecutionCount, 1)
        XCTAssertEqual(after.processPhase, before.processPhase)
        XCTAssertEqual(after.targetDisposition, before.targetDisposition)
        XCTAssertEqual(after.observedProcessID, before.observedProcessID)
        XCTAssertEqual(after.acceptedTargetAuthority, before.acceptedTargetAuthority)
        XCTAssertFalse(after.isInvalidated)
        XCTAssertNil(after.pendingRequest)
    }

    func testFinalPostWriteFailureInvalidatesUnknownAndNeverRetries() async throws {
        for mode in [
            ExactAttachDetachExecutor.Mode.invalidateFinalDetachAfterWrite,
            .completeFinalDetachAsThrownFailure,
        ] {
            let (coordinator, executor, attached) = try await attachedFixture(mode: mode)

            await XCTAssertThrowsCoordinatorFailure(.adapterInvalidated) {
                try await coordinator.performExactDetachTransaction(
                    self.detachInput(from: attached.attachedSession)
                )
            }

            let after = await coordinator.reducerState
            let detachExecutionCount = await executor.detachExecutionCount
            let expectedDetachRequestCount = await executor.expectedDetachRequestCount
            XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount)
            XCTAssertEqual(after.processPhase, .invalidated)
            XCTAssertEqual(after.targetDisposition, .unknown)
            XCTAssertTrue(after.isInvalidated)
            XCTAssertNil(after.pendingRequest)
            XCTAssertEqual(after.lastAcceptedEventSequence.rawValue, 6)
        }
    }

    func testMalformedFinalReceiptIsPostWriteUnknownAndNeverRetries() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(mode: .malformedFinalDetachReceipt)

        await XCTAssertThrowsCoordinatorFailure(.responseProjectionFailed) {
            try await coordinator.performExactDetachTransaction(
                self.detachInput(from: attached.attachedSession)
            )
        }

        let after = await coordinator.reducerState
        let detachExecutionCount = await executor.detachExecutionCount
        let expectedDetachRequestCount = await executor.expectedDetachRequestCount
        XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount)
        XCTAssertEqual(after.processPhase, .invalidated)
        XCTAssertEqual(after.targetDisposition, .unknown)
        XCTAssertTrue(after.isInvalidated)
    }

    func testSamePIDRunningOuterStateDoesNotContradictValidDetachReceipt() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(
            mode: .finalDetachReportsRunning
        )

        let outcome = try await coordinator.performExactDetachTransaction(
            detachInput(from: attached.attachedSession)
        )
        let detached = try requireDetached(outcome)

        let detachExecutionCount = await executor.detachExecutionCount
        let expectedDetachRequestCount = await executor.expectedDetachRequestCount
        XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount)
        XCTAssertEqual(
            detached.reducerState.processPhase,
            .detached(processID: attached.attachedSession.permit.authority.processID)
        )
        XCTAssertEqual(detached.reducerState.targetDisposition, .detached)
        XCTAssertTrue(detached.reducerState.isInvalidated)
    }

    func testWrongPIDOuterStateContradictsValidDetachReceipt() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(
            mode: .finalDetachReportsWrongPID
        )

        await XCTAssertThrowsCoordinatorFailure(.invalidObservedProcess) {
            try await coordinator.performExactDetachTransaction(
                self.detachInput(from: attached.attachedSession)
            )
        }

        let after = await coordinator.reducerState
        let detachExecutionCount = await executor.detachExecutionCount
        let expectedDetachRequestCount = await executor.expectedDetachRequestCount
        XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount)
        XCTAssertEqual(after.processPhase, .invalidated)
        XCTAssertEqual(after.targetDisposition, .unknown)
        XCTAssertTrue(after.isInvalidated)
    }

    func testParentAdmissionBlocksASecondDetachDuringFirstPrivateAwait() async throws {
        let (coordinator, executor, attached) = try await attachedFixture(mode: .barrierAtFirstDetachStaging)
        let input = detachInput(from: attached.attachedSession)
        let first = Task { try await coordinator.performExactDetachTransaction(input) }
        await executor.waitUntilFirstDetachStagingStarts()

        await XCTAssertThrowsCoordinatorFailure(.admissionRejected) {
            try await coordinator.performExactDetachTransaction(input)
        }
        let blockedExecutionCount = await executor.detachExecutionCount
        XCTAssertEqual(blockedExecutionCount, 1)

        await executor.releaseFirstDetachStaging()
        let result = try requireDetached(await first.value)
        XCTAssertEqual(result.reducerState.targetDisposition, .detached)
        let detachExecutionCount = await executor.detachExecutionCount
        let expectedDetachRequestCount = await executor.expectedDetachRequestCount
        XCTAssertEqual(detachExecutionCount, expectedDetachRequestCount)
    }

    private func attachedFixture(
        mode: ExactAttachDetachExecutor.Mode
    ) async throws -> (
        PersistentLLDBSessionCoordinator,
        ExactAttachDetachExecutor,
        PersistentLLDBExactAttachTransactionResult
    ) {
        let request = DebuggerLocalAttachRequest(selectedIdentity: try identity())
        let executor = ExactAttachDetachExecutor(
            mode: mode,
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            attachToken: attachToken,
            detachToken: detachToken,
            lldbUniqueID: lldbUniqueID
        )
        let coordinator = makeCoordinator(executor: executor)
        return (
            coordinator,
            executor,
            try await establishAttached(
                request,
                coordinator: coordinator,
                executor: executor
            )
        )
    }

    private func establishAttached(
        _ request: DebuggerLocalAttachRequest,
        coordinator: PersistentLLDBSessionCoordinator,
        executor: ExactAttachDetachExecutor
    ) async throws -> PersistentLLDBExactAttachTransactionResult {
        let initial = await coordinator.reducerState
        let authority = DebuggerSessionTargetAuthority(origin: .attached(request.selectedIdentity))
        let registry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: executor.attachWriteInterlock
        )
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: initial.sessionCoordinate,
            adapterGeneration: generation,
            attachWriteInterlockSnapshot: executor.attachWriteInterlock.currentSnapshot
        )
        await executor.configure(
            permit: permit,
            instanceBinding: await makeAdapterInstanceBinding()
        )
        return try await coordinator.performExactAttachTransaction(
            PersistentLLDBExactAttachTransactionInput(
                request: request,
                permit: permit
            )
        )
    }

    private func detachInput(
        from attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) -> PersistentLLDBExactDetachTransactionInput {
        PersistentLLDBExactDetachTransactionInput(attachedSession: attachedSession)
    }

    private func requireDetached(
        _ outcome: PersistentLLDBExactDetachTransactionOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PersistentLLDBExactDetachTransactionResult {
        guard case .detached(let result) = outcome else {
            XCTFail("Expected a receipt-backed detach outcome.", file: file, line: line)
            throw ExactDetachTestError.unexpectedOutcome
        }
        return result
    }

    private func requireTargetExited(
        _ outcome: PersistentLLDBExactDetachTransactionOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (PersistentLLDBExactAttachedExternalExitResult, DebuggerReducerState) {
        guard case .targetExited(let externalExit, let reducerState) = outcome else {
            XCTFail("Expected an exact target-exit outcome.", file: file, line: line)
            throw ExactDetachTestError.unexpectedOutcome
        }
        return (externalExit, reducerState)
    }

    private func makeCoordinator(
        executor: ExactAttachDetachExecutor
    ) -> PersistentLLDBSessionCoordinator {
        PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: RejectingExactDetachPreparer(),
            capabilities: DebuggerTransportCapabilities(
                operationStates: Dictionary(
                    uniqueKeysWithValues: DebuggerOperation.allCases.map {
                        ($0, DebuggerOperationCapability.supportedAndObserved)
                    }
                ),
                mechanics: .persistentCLI
            ),
            attachWriteInterlock: executor.attachWriteInterlock
        )
    }

    private func makeAdapterInstanceBinding() async -> PersistentLLDBCLIAdapterInstanceBinding {
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: ExactDetachBindingChannel(),
            retainedProcess: ExactDetachBindingProcess(),
            markerSecret: Data(repeating: 0x73, count: 32)
        )
        return await adapter.adapterInstanceBinding()
    }

    private func frozenDetachCommands(
        authority: DebuggerSessionTargetAuthority,
        finalSequence: UInt64,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) throws -> [String] {
        let request = try PersistentLLDBDetachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: finalSequence,
            adapterGeneration: generation,
            authority: authority,
            expectedLLDBProcessUniqueID: lldbUniqueID,
            correlationToken: attachedSession.permit.correlationToken
        )
        let program = PersistentLLDBDetachProgram()
        return program.installChunkCommands
            + [program.installFinalizeCommand]
            + [try program.command(for: request)]
    }

    private func identity() throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 7_777,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeExactDetachFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
    }

    private func authorizationEvidence(
        identity: DebuggerLocalProcessIdentity
    ) throws -> DebuggerLocalProcessAuthorizationEvidence {
        let fingerprint = try XCTUnwrap(DebuggerLocalProcessCatalogFingerprint(
            processID: identity.processID,
            startTime: identity.startTime,
            realUserID: identity.realUserID,
            effectiveUserID: identity.effectiveUserID,
            canonicalExecutablePath: identity.canonicalExecutablePath,
            executableDeviceID: identity.executableDeviceID,
            executableFileID: identity.executableFileID,
            executableByteCount: identity.executableByteCount,
            executableChangeTimeNanoseconds: 900,
            architecture: identity.architecture,
            machOUUID: identity.machOUUID,
            codeIdentity: identity.codeIdentity
        ))
        return DebuggerLocalProcessAuthorizationEvidence(
            catalogEvidence: DebuggerLocalProcessCatalogEvidence(
                fingerprint: fingerprint,
                displayName: "Exact detach registry fixture",
                parentProcessID: 1,
                savedUserID: identity.realUserID,
                dynamicState: .init()
            ),
            identity: identity
        )
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
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func XCTAssertThrowsPreFinalFailure<T>(
        _ code: PersistentLLDBSessionCoordinatorFailureCode,
        preserving expectedState: DebuggerReducerState,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected exact-detach pre-final failure.", file: file, line: line)
        } catch let failure as PersistentLLDBExactDetachPreFinalFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
            XCTAssertEqual(failure.disposition, .retireAdapterAndReobserve, file: file, line: line)
            XCTAssertEqual(failure.reducerState.processPhase, expectedState.processPhase, file: file, line: line)
            XCTAssertEqual(
                failure.reducerState.targetDisposition,
                expectedState.targetDisposition,
                file: file,
                line: line
            )
            XCTAssertEqual(
                failure.reducerState.acceptedTargetAuthority,
                expectedState.acceptedTargetAuthority,
                file: file,
                line: line
            )
            XCTAssertFalse(failure.reducerState.isInvalidated, file: file, line: line)
            XCTAssertNil(failure.reducerState.pendingRequest, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor ExactAttachDetachExecutor: PersistentLLDBCLIExecuting {
    enum Mode: Equatable, Sendable {
        case success
        case failFirstDetachBeforeWrite
        case invalidateFirstDetachStagingAfterWrite
        case completeFirstDetachStagingAsThrownFailure
        case misCorrelateFirstDetachStagingFailure
        case misCorrelateFirstDetachStagingResponse
        case failFinalDetachBeforeWrite
        case invalidateFinalDetachAfterWrite
        case completeFinalDetachAsThrownFailure
        case malformedFinalDetachReceipt
        case finalDetachReportsRunning
        case finalDetachReportsWrongPID
        case firstDetachStagingReportsExit
        case firstDetachStagingReportsWrongPIDExit
        case finalDetachReportsExitWithoutReceipt
        case finalExitObservedPIDIsWrong
        case finalExitStatePIDIsWrong
        case finalExitBothPIDsAreWrong
        case finalExitRequestIDIsWrong
        case finalExitGenerationIsWrong
        case barrierAtFirstDetachStaging
    }

    private let mode: Mode
    private let epoch: DebuggerSessionEpoch
    private let attachRequest: DebuggerLocalAttachRequest
    private let generation: UInt64
    nonisolated let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    private var instanceBinding: PersistentLLDBCLIAdapterInstanceBinding?
    private var attachToken: Data
    private var detachToken: Data
    private let lldbUniqueID: UInt64
    private(set) var requests: [PersistentLLDBCLIRequest] = []
    private var firstDetachStagingDidStart = false
    private var firstDetachStagingStartWaiter: CheckedContinuation<Void, Never>?
    private var firstDetachStagingRelease: CheckedContinuation<Void, Never>?

    init(
        mode: Mode,
        epoch: DebuggerSessionEpoch,
        attachRequest: DebuggerLocalAttachRequest,
        generation: UInt64,
        attachToken: Data,
        detachToken: Data,
        lldbUniqueID: UInt64
    ) {
        self.mode = mode
        self.epoch = epoch
        self.attachRequest = attachRequest
        self.generation = generation
        self.attachToken = attachToken
        self.detachToken = detachToken
        self.lldbUniqueID = lldbUniqueID
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

    var detachRequests: [PersistentLLDBCLIRequest] {
        requests.filter { $0.context.operation == .detach }
    }

    var detachExecutionCount: Int { detachRequests.count }
    var attachRequestCount: Int { requests.filter { $0.context.operation == .attach }.count }
    var expectedDetachRequestCount: Int {
        PersistentLLDBDetachProgram().installChunkCommands.count + 2
    }

    func configure(
        permit: DebuggerSessionLeaseExactAttachPermit,
        instanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    ) {
        attachToken = permit.correlationToken
        detachToken = permit.correlationToken
        self.instanceBinding = instanceBinding
    }

    func waitUntilFirstDetachStagingStarts() async {
        if firstDetachStagingDidStart { return }
        await withCheckedContinuation { firstDetachStagingStartWaiter = $0 }
    }

    func releaseFirstDetachStaging() {
        firstDetachStagingRelease?.resume()
        firstDetachStagingRelease = nil
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        requests.append(request)
        switch request.context.operation {
        case .attach:
            return try executeAttach(request)
        case .detach:
            return try await executeDetach(request)
        case .launch, .continue, .runToCursor, .stepOver, .stepInto, .stepOut, .pause,
             .terminate, .replaceBreakpoints, .reconcileLogicalBreakpoints, .updateWatchpoints, .writeRegister,
             .readMemory, .writeMemory, .evaluateExpression, .expandVariableChildren,
             .selectThread, .selectFrame, .refreshSnapshot, .refreshRuntimeModules,
             .pollProcessStatus:
            throw ExactDetachTestError.unexpectedOperation
        }
    }

    private func executeAttach(
        _ request: PersistentLLDBCLIRequest
    ) throws -> PersistentLLDBCLIResponse {
        let ordinal = requests.filter { $0.context.operation == .attach }.count
        let provisional = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: 1,
            adapterGeneration: generation,
            authority: authority,
            correlationToken: attachToken
        )
        let count = PersistentLLDBAttachProgram.current.installChunkCommands.count
            + 1
            + (try PersistentLLDBAttachProgram.current.requestCommands(for: provisional)).count
        if ordinal < count {
            guard case .exactAttachStaging(let wrappedAuthorization) = request.writeRole,
                  let wrappedAuthorization else {
                throw exactAttachWriteRejected(request)
            }
            let issuanceInput = wrappedAuthorization.issuanceInput
            let stagingCount = UInt64(issuanceInput.canonicalStagingCommandCount)
            let stagingOrdinal = UInt64(issuanceInput.stagingOrdinal)
            let firstSequence = issuanceInput.finalAttachRequest.id.sequence
                .subtractingReportingOverflow(stagingCount)
            let expectedSequence = firstSequence.partialValue
                .addingReportingOverflow(stagingOrdinal)
            guard request.context == issuanceInput.stagingRequest,
                  request.observedPIDRequirement == .optional,
                  instanceBinding == issuanceInput.adapterInstanceBinding,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == issuanceInput.semanticDigest,
                  issuanceInput.stagingOrdinal == ordinal - 1,
                  issuanceInput.canonicalStagingCommandCount == count - 1,
                  !firstSequence.overflow,
                  !expectedSequence.overflow,
                  request.context.id.sequence == expectedSequence.partialValue else {
                throw exactAttachWriteRejected(request)
            }
            do {
                try wrappedAuthorization.interlock
                    .consumeExactAttachStagingWriteAuthorization(
                        wrappedAuthorization.authorization,
                        matching: issuanceInput
                    )
            } catch {
                throw exactAttachWriteRejected(request)
            }
            return response(
                context: request.context,
                observedPID: nil,
                observedState: nil,
                semanticTranscript: ""
            )
        }
        let programRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: request.context.id.sequence,
            adapterGeneration: generation,
            authority: authority,
            correlationToken: attachToken
        )
        guard case .exactAttachFinal(let wrappedAuthorization) = request.writeRole,
              let wrappedAuthorization,
              request.context == wrappedAuthorization.issuanceInput.finalAttachRequest,
              request.observedPIDRequirement == .required,
              instanceBinding == wrappedAuthorization.issuanceInput.adapterInstanceBinding,
              let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                semanticCommands: request.semanticCommands
              ),
              semanticDigest == wrappedAuthorization.issuanceInput.semanticDigest else {
            throw exactAttachWriteRejected(request)
        }
        let exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit
        do {
            exactAttachWriteCommit = try wrappedAuthorization.interlock.commitExactAttachWrite(
                wrappedAuthorization.grant,
                matching: wrappedAuthorization.issuanceInput
            )
        } catch {
            throw exactAttachWriteRejected(request)
        }
        return response(
            context: request.context,
            observedPID: authority.processID,
            observedState: .stopped(processID: authority.processID),
            semanticTranscript: framed(
                attachReceiptBytes(for: programRequest),
                sentinel: PersistentLLDBAttachProgram.receiptSentinel
            ),
            exactAttachWriteCommit: exactAttachWriteCommit
        )
    }

    private func exactAttachWriteRejected(
        _ request: PersistentLLDBCLIRequest
    ) -> PersistentLLDBCLIAdapterFailure {
        PersistentLLDBCLIAdapterFailure(
            code: .exactAttachWriteRejected,
            requestID: request.context.id,
            generation: generation,
            disposition: .failedBeforeWrite
        )
    }

    private func executeDetach(
        _ request: PersistentLLDBCLIRequest
    ) async throws -> PersistentLLDBCLIResponse {
        let ordinal = detachRequests.count
        let isFinal = ordinal == expectedDetachRequestCount
        if ordinal == 1, mode == .failFirstDetachBeforeWrite {
            throw adapterFailure(request, disposition: .failedBeforeWrite)
        }
        if ordinal == 1, mode == .invalidateFirstDetachStagingAfterWrite {
            throw adapterFailure(
                request,
                code: .invalidatedGeneration,
                disposition: .invalidatedAfterWrite(reason: .timeoutAfterWrite, target: .unknown)
            )
        }
        if ordinal == 1, mode == .completeFirstDetachStagingAsThrownFailure {
            throw adapterFailure(
                request,
                disposition: .completed(target: .stopped(processID: authority.processID))
            )
        }
        if ordinal == 1, mode == .misCorrelateFirstDetachStagingFailure {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: DebuggerRequestID(
                    epoch: request.context.id.epoch,
                    sequence: request.context.id.sequence + 1
                ),
                generation: generation,
                disposition: .failedBeforeWrite
            )
        }
        if ordinal == 1, mode == .barrierAtFirstDetachStaging {
            firstDetachStagingDidStart = true
            firstDetachStagingStartWaiter?.resume()
            firstDetachStagingStartWaiter = nil
            await withCheckedContinuation { firstDetachStagingRelease = $0 }
        }
        if ordinal == 1, mode == .firstDetachStagingReportsExit {
            return response(
                context: request.context,
                observedPID: authority.processID,
                observedState: .exited(processID: authority.processID, status: 23),
                semanticTranscript: ""
            )
        }
        if ordinal == 1, mode == .firstDetachStagingReportsWrongPIDExit {
            return response(
                context: request.context,
                observedPID: authority.processID + 1,
                observedState: .exited(processID: authority.processID + 1, status: 23),
                semanticTranscript: ""
            )
        }
        if !isFinal {
            if mode == .misCorrelateFirstDetachStagingResponse {
                return response(
                    context: DebuggerRequestContext(
                        id: DebuggerRequestID(
                            epoch: request.context.id.epoch,
                            sequence: request.context.id.sequence + 1
                        ),
                        operation: request.context.operation,
                        expectedSession: request.context.expectedSession,
                        requiredStop: request.context.requiredStop,
                        targetAuthority: request.context.targetAuthority
                    ),
                    observedPID: authority.processID,
                    observedState: .stopped(processID: authority.processID),
                    semanticTranscript: ""
                )
            }
            return response(
                context: request.context,
                observedPID: authority.processID,
                observedState: .stopped(processID: authority.processID),
                semanticTranscript: ""
            )
        }
        if mode == .failFinalDetachBeforeWrite {
            throw adapterFailure(request, disposition: .failedBeforeWrite)
        }
        if mode == .invalidateFinalDetachAfterWrite {
            throw adapterFailure(
                request,
                code: .invalidatedGeneration,
                disposition: .invalidatedAfterWrite(reason: .timeoutAfterWrite, target: .unknown)
            )
        }
        if mode == .completeFinalDetachAsThrownFailure {
            throw adapterFailure(request, disposition: .completed(target: .detached))
        }
        if mode == .finalDetachReportsExitWithoutReceipt {
            return response(
                context: request.context,
                observedPID: authority.processID,
                observedState: .exited(processID: authority.processID, status: 29),
                semanticTranscript: ""
            )
        }
        if [
            Mode.finalExitObservedPIDIsWrong,
            .finalExitStatePIDIsWrong,
            .finalExitBothPIDsAreWrong,
            .finalExitRequestIDIsWrong,
            .finalExitGenerationIsWrong,
        ].contains(mode) {
            let responseContext: DebuggerRequestContext
            if mode == .finalExitRequestIDIsWrong {
                responseContext = DebuggerRequestContext(
                    id: DebuggerRequestID(
                        epoch: request.context.id.epoch,
                        sequence: request.context.id.sequence + 1
                    ),
                    operation: request.context.operation,
                    expectedSession: request.context.expectedSession,
                    requiredStop: request.context.requiredStop,
                    targetAuthority: request.context.targetAuthority
                )
            } else {
                responseContext = request.context
            }
            let observedPID = [
                Mode.finalExitObservedPIDIsWrong,
                .finalExitBothPIDsAreWrong,
            ].contains(mode) ? authority.processID + 1 : authority.processID
            let statePID = [
                Mode.finalExitStatePIDIsWrong,
                .finalExitBothPIDsAreWrong,
            ].contains(mode) ? authority.processID + 1 : authority.processID
            return response(
                context: responseContext,
                observedPID: observedPID,
                observedState: .exited(processID: statePID, status: 31),
                semanticTranscript: "",
                generationOverride: mode == .finalExitGenerationIsWrong ? generation + 1 : nil
            )
        }
        let programRequest = try PersistentLLDBDetachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: request.context.id.sequence,
            adapterGeneration: generation,
            authority: authority,
            expectedLLDBProcessUniqueID: lldbUniqueID,
            correlationToken: detachToken
        )
        if mode == .malformedFinalDetachReceipt {
            return response(
                context: request.context,
                observedPID: nil,
                observedState: nil,
                semanticTranscript: framed(
                    Data("{}".utf8),
                    sentinel: PersistentLLDBDetachProgram.receiptSentinel
                )
            )
        }
        let outer: (Int32?, LLDBCLIObservedProcessState?)
        switch mode {
        case .finalDetachReportsRunning:
            outer = (authority.processID, .running(processID: authority.processID))
        case .finalDetachReportsWrongPID:
            outer = (authority.processID + 1, .running(processID: authority.processID + 1))
        case .success, .failFirstDetachBeforeWrite,
             .invalidateFirstDetachStagingAfterWrite,
             .completeFirstDetachStagingAsThrownFailure,
             .misCorrelateFirstDetachStagingFailure,
             .misCorrelateFirstDetachStagingResponse,
             .failFinalDetachBeforeWrite,
             .invalidateFinalDetachAfterWrite, .completeFinalDetachAsThrownFailure,
             .malformedFinalDetachReceipt,
             .firstDetachStagingReportsExit,
             .firstDetachStagingReportsWrongPIDExit,
             .finalDetachReportsExitWithoutReceipt,
             .finalExitObservedPIDIsWrong,
             .finalExitStatePIDIsWrong,
             .finalExitBothPIDsAreWrong,
             .finalExitRequestIDIsWrong,
             .finalExitGenerationIsWrong,
             .barrierAtFirstDetachStaging:
            outer = (nil, nil)
        }
        return response(
            context: request.context,
            observedPID: outer.0,
            observedState: outer.1,
            semanticTranscript: framed(
                detachReceiptBytes(for: programRequest),
                sentinel: PersistentLLDBDetachProgram.receiptSentinel
            )
        )
    }

    private var authority: DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(origin: .attached(attachRequest.selectedIdentity))
    }

    private func adapterFailure(
        _ request: PersistentLLDBCLIRequest,
        code: PersistentLLDBCLIAdapterFailureCode = .invalidRequest,
        disposition: DebuggerRequestDisposition
    ) -> PersistentLLDBCLIAdapterFailure {
        PersistentLLDBCLIAdapterFailure(
            code: code,
            requestID: request.context.id,
            generation: generation,
            disposition: disposition
        )
    }

    private func response(
        context: DebuggerRequestContext,
        observedPID: Int32?,
        observedState: LLDBCLIObservedProcessState?,
        semanticTranscript: String,
        generationOverride: UInt64? = nil,
        exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit? = nil
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: context.id,
            generation: generationOverride ?? generation,
            transcript: LLDBCLITranscriptResult(
                transcript: "",
                authoritativeStatusTranscript: "",
                observedProcessID: observedPID,
                observedProcessState: observedState,
                exchangeByteCount: max(1, semanticTranscript.utf8.count),
                exchangeSHA256: String(repeating: "d", count: 64),
                semanticCommandTranscripts: [semanticTranscript],
                semanticCommandResultLineByteCounts: [max(1, semanticTranscript.utf8.count)]
            ),
            exactAttachWriteCommit: exactAttachWriteCommit
        )
    }

    private func framed(_ bytes: Data, sentinel: String) -> String {
        sentinel + bytes.base64EncodedString() + "\n"
    }

    private func attachReceiptBytes(
        for request: PersistentLLDBAttachProgramRequest
    ) -> Data {
        let payload = Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(request.adapterGeneration)),
            "correlation_token": .string(hex(request.correlationToken)),
            "error": .object([
                "code": .number("0"), "kind": .number("0"),
                "message_b64": .string(""), "message_truncated": .bool(false),
            ]),
            "lldb_unique_id": .number(String(lldbUniqueID)),
            "observed_pid": .number(String(request.authority.processID)),
            "request_sequence": .number(String(request.requestSequence)),
            "requested_pid": .number(String(request.authority.processID)),
            "schema": .number("1"), "selected_thread_id": .number("44"),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
            "state": .string("stopped"), "stop_id": .number("19"),
            "stop_reason": .object([
                "data": .array([.number("5")]),
                "data_truncated": .bool(false), "kind": .string("signal"),
            ]),
            "target_path_b64": .string(
                Data(request.identity.canonicalExecutablePath.utf8).base64EncodedString()
            ),
            "target_uuid": .string(request.identity.machOUUID!.uuidString.lowercased()),
        ])
        return envelope(payload)
    }

    private func detachReceiptBytes(
        for request: PersistentLLDBDetachProgramRequest
    ) -> Data {
        let payload = Phase2ProductionJSONValue.object([
            "acknowledged": .bool(true),
            "adapter_generation": .number(String(request.adapterGeneration)),
            "correlation_token": .string(hex(request.correlationToken)),
            "error": .object([
                "code": .number("0"), "kind": .number("0"),
                "message_b64": .string(""), "message_truncated": .bool(false),
                "message_utf8_bytes": .number("0"),
            ]),
            "identity_digest": .string(request.authority.identityDigest.lowercaseHex),
            "lldb_unique_id": .number(String(request.expectedLLDBProcessUniqueID)),
            "observed_pid": .number(String(request.expectedProcessID)),
            "request_sequence": .number(String(request.requestSequence)),
            "resume_on_detach": .bool(true), "schema": .number("1"),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
        ])
        return envelope(payload)
    }

    private func envelope(_ payload: Phase2ProductionJSONValue) -> Data {
        let bytes = payload.canonicalJSONBytes()
        return Phase2ProductionJSONValue.object([
            "payload": payload,
            "payload_sha256": .string(hex(Data(SHA256.hash(data: bytes)))),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private actor RejectingExactDetachPreparer: PersistentLLDBCLIRequestPreparing {
    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        throw ExactDetachTestError.genericPreparerMustNotBeUsed
    }
}

private enum ExactDetachTestError: Error {
    case genericPreparerMustNotBeUsed
    case unexpectedOperation
    case unexpectedOutcome
}

private actor ExactDetachRegistryEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private let evidence: DebuggerLocalProcessAuthorizationEvidence
    private(set) var observationCount = 0

    init(evidence: DebuggerLocalProcessAuthorizationEvidence) {
        self.evidence = evidence
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .unknown(.unstableSnapshot)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        .unknown(.unstableSnapshot)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        observationCount += 1
        guard processID == evidence.identity.processID else {
            return .unknown(.disappeared)
        }
        return .resolved(evidence)
    }
}

private actor ExactDetachBindingChannel: PersistentLLDBCLIByteChannel {
    func write(_ data: Data) async throws {}
    func nextBytes() async throws -> Data? { nil }
    func closeInput() async {}
    func closeHandles() async {}
}

private actor ExactDetachBindingProcess: PersistentLLDBCLIRetainedProcess {
    func waitForExit(maximumDuration: Duration) async -> Bool { true }
    func terminateRetainedAdapter() async {}
    func killRetainedAdapterIfStillRunning() async -> Bool { true }
    func reapAndClose() async -> Bool { true }
}

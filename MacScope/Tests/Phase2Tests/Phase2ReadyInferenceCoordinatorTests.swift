import XCTest
@testable import MacScope

@MainActor
final class Phase2ReadyInferenceCoordinatorTests: XCTestCase {
    func testIdleReadySnapshotProducesExactRevisionQualifiedLease() throws {
        let fixture = try ReadyInferenceFixture()
        XCTAssertEqual(fixture.endpoint.inferencePolicy, Phase2LocalInferencePolicy())
        XCTAssertEqual(fixture.configuration.inferencePolicy,
                       Phase2LocalInferencePolicy(effectiveContextTokens: 32_768))
        let snapshot = Phase2LocalAIProviderSnapshot(
            endpoint: fixture.endpoint,
            observation: .accepted(fixture.inventory),
            selection: fixture.selection,
            activity: .idle,
            revision: 41
        )

        XCTAssertEqual(
            snapshot.readyInferenceLease,
            Phase2ReadyInferenceLease(
                providerRevision: 41,
                configuration: fixture.configuration,
                observedModelInventorySHA256: Phase2LocalModelInventoryIdentity
                    .canonicalSHA256(fixture.inventory)
            )
        )

        let busy = Phase2LocalAIProviderSnapshot(
            endpoint: fixture.endpoint,
            observation: .accepted(fixture.inventory),
            selection: fixture.selection,
            activity: .discovering(requestID: phase2ReadyID(900)),
            revision: 41
        )
        XCTAssertNil(busy.readyInferenceLease)

        let exhausted = Phase2LocalAIProviderSnapshot(
            endpoint: fixture.endpoint,
            observation: .accepted(fixture.inventory),
            selection: fixture.selection,
            activity: .idle,
            revision: .max
        )
        XCTAssertNil(exhausted.readyInferenceLease)
    }

    func testAssistantSelectionAndFinalizationAcceptUnchangedMTPLXRefreshAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let initialLease = try XCTUnwrap(controller.captureReadyInferenceLease())
        let provider = TwoPhaseAssistantReadyInferenceProvider()
        let factory = ReadyInferenceProviderFactory { _ in provider }
        let coordinator = Phase2ReadyInferenceCoordinator(controller: controller, providerFactory: factory.make)
        let store = WorkspaceStore(workspaceName: "Refresh authority", snapshot: .init(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        let result = await Phase2AssistantSessionRunner().run(intent: .askMacScope,
            userGoal: "Summarize the workspace.", store: store, coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true))
        let requests = await provider.requests
        let finalLease = try XCTUnwrap(controller.captureReadyInferenceLease())
        XCTAssertEqual(requests.map(\.phase), [.toolSelection, .finalization])
        XCTAssertGreaterThan(finalLease.providerRevision, initialLease.providerRevision)
        XCTAssertEqual(finalLease.configuration, initialLease.configuration)
        XCTAssertEqual(finalLease.observedModelInventorySHA256, initialLease.observedModelInventorySHA256)
        XCTAssertNil(result.failure)
        XCTAssertNotNil(result.inferenceOutcome)
        XCTAssertEqual(result.providerRevision, finalLease.providerRevision)
        XCTAssertTrue(controller.isCurrent(finalLease))
    }

    func testNonreadyControllerDoesNotConstructProvider() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try fixture.makeUnselectedController()
        let factory = ReadyInferenceProviderFactory { _ in
            XCTFail("A nonready turn must not construct a provider")
            return CompletingReadyInferenceProvider()
        }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )

        let result = await coordinator.run(request: makeReadyInferenceRequest())

        XCTAssertEqual(result, .notReady(.selectionRequired))
        XCTAssertEqual(factory.configurations, [])
    }

    func testSuccessfulTurnForwardsExactPrebuiltRequestAndConfiguration() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = CompletingReadyInferenceProvider()
        let factory = ReadyInferenceProviderFactory { _ in provider }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(101))
        let providerRevision = try XCTUnwrap(
            controller.captureReadyInferenceLease()?.providerRevision
        )
        XCTAssertNotEqual(
            request.lifecycleRevision,
            providerRevision,
            "reducer lifecycle identity and provider authority revision are independent domains"
        )

        let result = await coordinator.run(request: request)

        let capturedRequests = await provider.requests
        XCTAssertEqual(capturedRequests, [request])
        XCTAssertEqual(factory.configurations, [fixture.configuration])
        guard case .finished(let lease, let outcome) = result else {
            return XCTFail("Expected one finished inference, got \(result)")
        }
        XCTAssertEqual(lease.configuration, fixture.configuration)
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.finalCandidate?.text, "grounded completion")
    }

    func testAuthorityChangeDuringProviderConstructionBlocksDispatch() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = CompletingReadyInferenceProvider()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in
                controller.clearSelection()
                return provider
            }
        )

        let result = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(105))
        )

        XCTAssertEqual(result, .providerAuthorityChanged)
        let capturedRequests = await provider.requests
        XCTAssertEqual(capturedRequests, [])
    }

    func testFinalizationWithToolHandlesIsRejectedBeforeProviderConstruction() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let factory = ReadyInferenceProviderFactory { _ in
            XCTFail("Finalization must not forward tool handles")
            return CompletingReadyInferenceProvider()
        }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )
        let request = makeReadyInferenceRequest(
            toolHandles: [
                .init(handleID: phase2ReadyID(102), operationID: .selectionExplain),
            ]
        )

        let result = await coordinator.run(request: request)

        XCTAssertEqual(result, .invalidRequest)
        XCTAssertEqual(factory.configurations, [])
    }

    func testToolSelectionForwardsHandlesAndStopsAwaitingAppAuthorization() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = AwaitingToolsReadyInferenceProvider()
        let factory = ReadyInferenceProviderFactory { _ in provider }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )
        let request = makeReadyInferenceRequest(
            requestID: phase2ReadyID(103),
            phase: .toolSelection,
            toolHandles: [
                .init(handleID: phase2ReadyID(104), operationID: .selectionExplain),
            ]
        )

        let result = await coordinator.run(request: request)

        let capturedRequests = await provider.requests
        XCTAssertEqual(capturedRequests, [request])
        guard case .finished(_, let outcome) = result else {
            return XCTFail("Expected a finished tool-selection phase, got \(result)")
        }
        XCTAssertEqual(outcome.disposition, .awaitingTools)
        XCTAssertEqual(outcome.toolProposals.map(\.handleID), [phase2ReadyID(104)])
    }

    func testMalformedRequestIsRejectedBeforeProviderConstruction() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let factory = ReadyInferenceProviderFactory { _ in
            XCTFail("An invalid request must not construct a provider")
            return CompletingReadyInferenceProvider()
        }
        let valid = makeReadyInferenceRequest(requestID: phase2ReadyID(106))
        let malformed = Phase2InferenceRequest(
            protocolVersion: valid.protocolVersion,
            sessionID: valid.sessionID,
            turnID: valid.turnID,
            requestID: valid.requestID,
            document: valid.document,
            workspace: valid.workspace,
            lifecycleRevision: valid.lifecycleRevision,
            userGoal: "",
            groundedContext: valid.groundedContext,
            toolHandles: valid.toolHandles,
            limits: valid.limits
        )

        let result = await coordinator(controller, factory).run(request: malformed)

        XCTAssertEqual(result, .invalidRequest)
        XCTAssertEqual(factory.configurations, [])
    }

    func testCoordinatorAdmitsOnlyOneTurnAtATime() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ControlledReadyInferenceProvider()
        let factory = ReadyInferenceProviderFactory { _ in provider }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )
        let firstRequest = makeReadyInferenceRequest(requestID: phase2ReadyID(110))
        let first = Task { await coordinator.run(request: firstRequest) }
        await provider.waitUntilStarted()

        let second = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(111))
        )

        XCTAssertEqual(second, .busy)
        XCTAssertEqual(factory.configurations.count, 1)
        first.cancel()
        _ = await first.value
    }

    func testSingleFlightAdmissionIsProcessGlobalAcrossCoordinatorInstances() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ControlledReadyInferenceProvider()
        let firstCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in provider }
        )
        let secondFactory = ReadyInferenceProviderFactory { _ in
            XCTFail("A second coordinator must not construct a parallel provider")
            return CompletingReadyInferenceProvider()
        }
        let secondCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: secondFactory.make
        )
        let first = Task {
            await firstCoordinator.run(
                request: makeReadyInferenceRequest(requestID: phase2ReadyID(115))
            )
        }
        await provider.waitUntilStarted()

        let second = await secondCoordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(116))
        )

        XCTAssertEqual(second, .busy)
        XCTAssertEqual(secondFactory.configurations, [])
        first.cancel()
        _ = await first.value
    }

    func testAuthorityRevisionABAInvalidatesActiveTurnAndCancelsExactRequest() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let originalLease = try XCTUnwrap(controller.captureReadyInferenceLease())
        let provider = ControlledReadyInferenceProvider()
        let factory = ReadyInferenceProviderFactory { _ in provider }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(120))
        let turn = Task { await coordinator.run(request: request) }
        await provider.waitUntilStarted()

        controller.clearSelection()
        try controller.select(
            modelKey: fixture.configuration.model,
            maximumTokens: fixture.configuration.maximumTokens
        )

        let restoredLease = try XCTUnwrap(controller.captureReadyInferenceLease())
        XCTAssertEqual(restoredLease.configuration, originalLease.configuration)
        XCTAssertNotEqual(restoredLease.providerRevision, originalLease.providerRevision)
        let result = await turn.value
        XCTAssertEqual(result, .providerAuthorityChanged)
        let cancelledRequestIDs = await provider.cancelledRequestIDs
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])
    }

    func testNoncooperativeLateSuccessIsRejectedAfterAuthorityInvalidation() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = NoncooperativeLateSuccessProvider()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in provider }
        )
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(125))
        let turn = Task { await coordinator.run(request: request) }
        await provider.waitUntilStarted()

        controller.clearSelection()
        await provider.waitUntilCancelled()
        await provider.releaseLateSuccess()

        let result = await turn.value
        let cancelledRequestIDs = await provider.cancelledRequestIDs
        XCTAssertEqual(result, .providerAuthorityChanged)
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])
    }

    func testCompletionRaceStillFailsMandatoryFinalLeaseRecheck() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = CompletionRaceReadyInferenceProvider {
            await MainActor.run { controller.clearSelection() }
        }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in provider }
        )

        let result = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(126))
        )

        XCTAssertEqual(result, .providerAuthorityChanged)
    }

    func testCallerCancellationCancelsExactRequestOnce() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ControlledReadyInferenceProvider()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in provider }
        )
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(130))
        let turn = Task { await coordinator.run(request: request) }
        await provider.waitUntilStarted()

        turn.cancel()
        let result = await turn.value

        guard case .finished(_, let outcome) = result else {
            return XCTFail("Caller cancellation should remain a runner outcome, got \(result)")
        }
        XCTAssertEqual(outcome.disposition, .cancelled)
        let cancelledRequestIDs = await provider.cancelledRequestIDs
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])
    }

    func testControlledCancellationBarrierCancelsAfterExactDispatchBeforeSemanticOutput()
        async throws
    {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ControlledReadyInferenceProvider()
        let observer = ReadyInferenceCancellationMeasurementObserver()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in provider }
        )
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(131))
        let barrier = Phase2ControlledCancellationBarrier(requestID: request.requestID)
        let turn = Task {
            await coordinator.run(
                request: request,
                measurementObserver: observer,
                controlledCancellationBarrier: barrier
            )
        }

        let wasDispatched = await barrier.waitForProviderDispatch()
        let requestsAtDispatch = await provider.startedRequestIDs
        XCTAssertTrue(wasDispatched)
        XCTAssertEqual(requestsAtDispatch, [request.requestID])
        XCTAssertEqual(observer.events, [.admitted, .generationBegan])

        turn.cancel()
        let result = await turn.value

        guard case .finished(_, let outcome) = result else {
            return XCTFail("Controlled cancellation should close as an outcome, got \(result)")
        }
        XCTAssertEqual(outcome.disposition, .cancelled)
        let requestsAfterCancellation = await provider.startedRequestIDs
        let cancelledRequestIDs = await provider.cancelledRequestIDs
        XCTAssertEqual(requestsAfterCancellation, [request.requestID])
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])
        XCTAssertTrue(barrier.hasProvenDispatchBeforeCancellation)
        XCTAssertEqual(
            observer.events,
            [.admitted, .generationBegan, .cancellationBegan, .providerDrained]
        )
    }

    func testControlledCancellationBarrierResolvesFalseWhenAdmissionIsDeclined() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try fixture.makeUnselectedController()
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(132))
        let barrier = Phase2ControlledCancellationBarrier(requestID: request.requestID)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in
                XCTFail("A declined turn must not construct a provider")
                return CompletingReadyInferenceProvider()
            }
        )
        let turn = Task {
            await coordinator.run(
                request: request,
                measurementObserver: nil,
                controlledCancellationBarrier: barrier
            )
        }

        let wasAdmitted = await barrier.waitForProviderDispatch()
        let result = await turn.value

        XCTAssertFalse(wasAdmitted)
        XCTAssertEqual(result, .notReady(.selectionRequired))
    }

    func testControlledCancellationFailsClosedWhenProviderReturnsWithoutHTTPDispatchReceipt()
        async throws
    {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let request = makeReadyInferenceRequest(requestID: phase2ReadyID(133))
        let barrier = Phase2ControlledCancellationBarrier(requestID: request.requestID)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in NoHTTPDispatchReceiptReadyInferenceProvider() }
        )
        let turn = Task {
            await coordinator.run(
                request: request,
                measurementObserver: nil,
                controlledCancellationBarrier: barrier
            )
        }

        let wasDispatched = await barrier.waitForProviderDispatch()
        let result = await turn.value

        XCTAssertFalse(wasDispatched)
        XCTAssertFalse(barrier.hasProvenDispatchBeforeCancellation)
        XCTAssertEqual(result, .providerAuthorityChanged)
    }

    func testControlledCancellationMarksLogicalCancellationBeforeImmediateProviderDrain()
        async throws
    {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()

        for offset in 0..<32 {
            let request = makeReadyInferenceRequest(
                requestID: phase2ReadyID(1_000 + offset)
            )
            let barrier = Phase2ControlledCancellationBarrier(
                requestID: request.requestID
            )
            let coordinator = Phase2ReadyInferenceCoordinator(
                controller: controller,
                providerFactory: { _ in ImmediateDrainReadyInferenceProvider() }
            )
            let turn = Task {
                await coordinator.run(
                    request: request,
                    measurementObserver: nil,
                    controlledCancellationBarrier: barrier
                )
            }

            let wasDispatched = await barrier.waitForProviderDispatch()
            XCTAssertTrue(wasDispatched)
            turn.cancel()
            let result = await turn.value

            guard case .finished(_, let outcome) = result else {
                return XCTFail("Immediate drain lost ordering proof at iteration \(offset)")
            }
            XCTAssertEqual(outcome.disposition, .cancelled)
            XCTAssertTrue(barrier.hasProvenDispatchBeforeCancellation)
        }
    }

    func testEachAcceptedTurnReceivesFreshProviderInstance() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let factory = ReadyInferenceProviderFactory { _ in CompletingReadyInferenceProvider() }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: factory.make
        )

        let first = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(140))
        )
        let second = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(141))
        )

        guard case .finished = first, case .finished = second else {
            return XCTFail("Both sequential turns should finish")
        }
        XCTAssertEqual(factory.providerIdentities.count, 2)
        XCTAssertNotEqual(factory.providerIdentities[0], factory.providerIdentities[1])
        XCTAssertEqual(factory.configurations, [fixture.configuration, fixture.configuration])
    }

    func testQualificationPreparesAcceptsAndRevalidatesExactFreshProviderReceipt() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let receipt = try readyWorkerReceipt(connectionIdentity: phase2ReadyID(150))
        let provider = ReceiptReadyInferenceProvider(
            receipt: receipt,
            revalidationResult: true
        )
        let receiptObserver = ReadyWorkerReceiptObserver(accepts: true)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: receiptObserver,
            providerFactory: { _ in provider }
        )

        let result = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(151))
        )

        guard case .finished = result else {
            return XCTFail("Expected receipt-qualified completion, got \(result)")
        }
        let lifecycle = await provider.lifecycle
        XCTAssertEqual(receiptObserver.receipts, [receipt])
        XCTAssertEqual(lifecycle, [.prepared, .ran, .revalidated])
    }

    func testQualificationRejectsMissingOrStaleWorkerReceiptBeforeSuccess() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let unsupportedProvider = CompletingReadyInferenceProvider()
        let observer = ReadyWorkerReceiptObserver(accepts: true)
        let unsupportedCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            providerFactory: { _ in unsupportedProvider }
        )

        let unsupported = await unsupportedCoordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(152))
        )
        let unsupportedRequests = await unsupportedProvider.requests

        XCTAssertEqual(unsupported, .providerAuthorityChanged)
        XCTAssertEqual(unsupportedRequests, [])
        XCTAssertEqual(observer.receipts, [])

        let staleReceipt = try readyWorkerReceipt(connectionIdentity: phase2ReadyID(153))
        let staleProvider = ReceiptReadyInferenceProvider(
            receipt: staleReceipt,
            revalidationResult: false
        )
        let staleCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            providerFactory: { _ in staleProvider }
        )

        let stale = await staleCoordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(154))
        )
        let staleLifecycle = await staleProvider.lifecycle

        XCTAssertEqual(stale, .providerAuthorityChanged)
        XCTAssertEqual(observer.receipts, [staleReceipt])
        XCTAssertEqual(staleLifecycle, [.prepared, .ran, .revalidated])
    }

    func testQualificationRejectsConfigurationMismatchedReceiptBeforeObservation() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let invalidReceipts = try [
            readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(155),
                profileID: phase2ReadyID(999)
            ),
            readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(156),
                configurationGeneration: fixture.configuration.generation + 1
            ),
            readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(157),
                protocolManifestDigest: String(repeating: "f", count: 64)
            ),
        ]

        for (offset, receipt) in invalidReceipts.enumerated() {
            let provider = ReceiptReadyInferenceProvider(
                receipt: receipt,
                revalidationResult: true
            )
            let observer = ReadyWorkerReceiptObserver(accepts: true)
            let coordinator = Phase2ReadyInferenceCoordinator(
                controller: controller,
                workerProcessReceiptObserver: observer,
                providerFactory: { _ in provider }
            )

            let result = await coordinator.run(
                request: makeReadyInferenceRequest(
                    requestID: phase2ReadyID(170 + offset)
                )
            )

            XCTAssertEqual(result, .providerAuthorityChanged)
            XCTAssertEqual(observer.receipts, [])
            let lifecycle = await provider.lifecycle
            XCTAssertEqual(lifecycle, [.prepared])
        }
    }

    func testSuspendedReceiptPreparationReservesProcessGlobalAdmission() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let receipt = try readyWorkerReceipt(connectionIdentity: phase2ReadyID(160))
        let provider = PreparationBlockingReceiptProvider(receipt: receipt)
        let factory = ReadyInferenceProviderFactory { _ in provider }
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: ReadyWorkerReceiptObserver(accepts: true),
            providerFactory: factory.make
        )
        let first = Task {
            await coordinator.run(
                request: makeReadyInferenceRequest(requestID: phase2ReadyID(161))
            )
        }
        await provider.waitUntilPreparationStarts()

        let second = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(162))
        )

        XCTAssertEqual(second, .busy)
        XCTAssertEqual(factory.configurations.count, 1)
        await provider.releasePreparation()
        guard case .finished = await first.value else {
            return XCTFail("First reserved qualification turn should finish")
        }
    }

    func testCancellationDuringReceiptPreparationSuppressesRetiredReceiptAndDispatch()
        async throws
    {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let receipt = try readyWorkerReceipt(connectionIdentity: phase2ReadyID(163))
        let provider = PreparationBlockingReceiptProvider(receipt: receipt)
        let observer = ReadyWorkerReceiptObserver(accepts: true)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            providerFactory: { _ in provider }
        )
        let first = Task {
            await coordinator.run(
                request: makeReadyInferenceRequest(requestID: phase2ReadyID(164))
            )
        }
        await provider.waitUntilPreparationStarts()

        first.cancel()
        let whileRetiring = await coordinator.run(
            request: makeReadyInferenceRequest(requestID: phase2ReadyID(165))
        )
        XCTAssertEqual(whileRetiring, .busy)
        await provider.releasePreparation()

        let firstResult = await first.value
        XCTAssertEqual(firstResult, .providerAuthorityChanged)
        XCTAssertEqual(observer.receipts, [])
        let startedRequestIDs = await provider.startedRequestIDs
        XCTAssertEqual(startedRequestIDs, [])
    }

    func testAuthorityChangeDuringReceiptPreparationSuppressesStaleReceipt() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let receipt = try readyWorkerReceipt(connectionIdentity: phase2ReadyID(166))
        let provider = PreparationBlockingReceiptProvider(receipt: receipt)
        let observer = ReadyWorkerReceiptObserver(accepts: true)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            providerFactory: { _ in provider }
        )
        let turn = Task {
            await coordinator.run(
                request: makeReadyInferenceRequest(requestID: phase2ReadyID(167))
            )
        }
        await provider.waitUntilPreparationStarts()

        controller.clearSelection()
        await provider.releasePreparation()

        let result = await turn.value
        XCTAssertEqual(result, .providerAuthorityChanged)
        XCTAssertEqual(observer.receipts, [])
        let startedRequestIDs = await provider.startedRequestIDs
        XCTAssertEqual(startedRequestIDs, [])
    }

    func testReconstructionFailedTerminalRetainsExactLeaseAndRequestAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ReadyReconstructionTerminalProvider(status: .failed)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )
        let request = readyReconstructionRoundRequest()

        let result = await coordinator.run(request: request)

        guard case let .failedWithTerminalAuthority(
            lease,
            requestAuthority,
            failure
        ) = result else {
            return XCTFail("Expected a terminal-authorized failure, got \(result)")
        }
        XCTAssertEqual(failure, .providerFailure)
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(requestAuthority.request, .round(request))
        XCTAssertEqual(
            requestAuthority.expectedRequestID,
            requestAuthority.terminalReceipt.requestID
        )
        XCTAssertEqual(requestAuthority.terminalReceipt.status, .failed)
        XCTAssertEqual(
            requestAuthority.requestIdentitySHA256,
            try ReconstructionCanonicalJSON.sha256(of: request)
        )
    }

    func testReconstructionMalformedEventsAfterExactTerminalRetainAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ReadyReconstructionTerminalProvider(status: .completed)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )
        let request = readyReconstructionRoundRequest()

        let result = await coordinator.run(request: request)

        guard case let .failedWithTerminalAuthority(
            lease,
            requestAuthority,
            failure
        ) = result else {
            return XCTFail("Expected a terminal-authorized malformed result, got \(result)")
        }
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(failure, .runner(.missingCompletion))
        XCTAssertEqual(requestAuthority.request, .round(request))
        XCTAssertEqual(requestAuthority.terminalReceipt.status, .completed)
    }

    func testReconstructionTerminalRequestIDDriftCannotMintAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ReadyReconstructionTerminalProvider(
            status: .failed,
            terminalRequestIDOverride: phase2ReadyID(971)
        )
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.run(request: readyReconstructionRoundRequest())

        XCTAssertEqual(
            result,
            .failedWithoutTerminalAuthority(.runner(.invalidTerminalReceipt))
        )
    }

    func testReconstructionLeaseDriftDiscardsOtherwiseExactTerminalAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ReadyReconstructionTerminalProvider(
            status: .failed,
            beforeReturningTerminal: {
                await MainActor.run { controller.clearSelection() }
            }
        )
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.run(request: readyReconstructionRoundRequest())

        XCTAssertEqual(result, .providerAuthorityChanged)
    }

    func testReconstructionProviderErrorWithoutTerminalCannotMintAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ReadyReconstructionTerminalProvider(
            status: .failed,
            failsBeforeTerminal: true
        )
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.run(request: readyReconstructionRoundRequest())

        XCTAssertEqual(result, .failedWithoutTerminalAuthority(.providerFailure))
    }

    func testReconstructionCancellationBeforeTerminalRemainsWithoutAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = PreTerminalCancellingReconstructionProvider()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.run(request: readyReconstructionRoundRequest())

        XCTAssertEqual(result, .failedWithoutTerminalAuthority(.cancelled))
    }

    func testReconstructionFinalCancellationBeforeTerminalRemainsWithoutAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = PreTerminalCancellingReconstructionProvider()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.synthesize(request: readyReconstructionFinalRequest())

        XCTAssertEqual(result, .failedWithoutTerminalAuthority(.cancelled))
    }

    func testReconstructionInvalidRequestRemainsReceiptFreeBeforeAdmission() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = ReadyReconstructionTerminalProvider(status: .failed)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )
        let valid = readyReconstructionRoundRequest()
        let invalid = ReconstructionInferenceRoundRequest(
            protocolVersion: valid.protocolVersion + 1,
            jobID: valid.jobID,
            checkpointRevision: valid.checkpointRevision,
            roundID: valid.roundID,
            corpusManifestSHA256: valid.corpusManifestSHA256,
            evidenceFrontierSHA256: valid.evidenceFrontierSHA256,
            registryManifestSHA256: valid.registryManifestSHA256,
            context: valid.context,
            handles: valid.handles
        )

        let result = await coordinator.run(request: invalid)

        let roundCallCount = await provider.roundCallCount()
        XCTAssertEqual(result, .invalidRequest)
        XCTAssertEqual(roundCallCount, 0)
    }

    func testReconstructionReceiptMustMatchLeaseAndProtocolBeforeObservation() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let provider = try ReceiptReadyReconstructionProvider(
            receipt: readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(976),
                configurationGeneration: fixture.configuration.generation + 1,
                protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR1
                    .manifestDigest
            )
        )
        let observer = ReadyWorkerReceiptObserver(accepts: true)
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.run(request: readyReconstructionRoundRequest())

        XCTAssertEqual(result, .providerAuthorityChanged)
        XCTAssertEqual(observer.receipts, [])
        let lifecycle = await provider.lifecycle
        XCTAssertEqual(lifecycle, [.prepared])
    }

    func testReceiptObserverRejectionBlocksBothReconstructionPaths() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let observer = ReadyWorkerReceiptObserver(accepts: false)
        let roundProvider = try ReceiptReadyReconstructionProvider(
            receipt: readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(972),
                protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR1
                    .manifestDigest
            )
        )
        let roundCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            reconstructionProviderFactory: { _ in roundProvider }
        )
        let finalProvider = try ReceiptReadyReconstructionProvider(
            receipt: readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(973),
                protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR1
                    .manifestDigest
            )
        )
        let finalCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            reconstructionProviderFactory: { _ in finalProvider }
        )

        let round = await roundCoordinator.run(request: readyReconstructionRoundRequest())
        let final = await finalCoordinator.synthesize(request: readyReconstructionFinalRequest())
        let roundLifecycle = await roundProvider.lifecycle
        let finalLifecycle = await finalProvider.lifecycle

        XCTAssertEqual(round, .providerAuthorityChanged)
        XCTAssertEqual(final, .providerAuthorityChanged)
        XCTAssertEqual(roundLifecycle, [.prepared])
        XCTAssertEqual(finalLifecycle, [.prepared])
        XCTAssertEqual(observer.receipts.count, 2)
        XCTAssertEqual(observer.providerConnections, [])
        XCTAssertEqual(observer.providerDispatches, [])
    }

    func testReceiptObserverBindsAndRevalidatesBothReconstructionPaths() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let observer = ReadyWorkerReceiptObserver(accepts: true)
        let roundRequest = readyReconstructionRoundRequest()
        let roundProvider = try ReceiptReadyReconstructionProvider(
            receipt: readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(974),
                protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR1
                    .manifestDigest
            )
        )
        let roundCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            reconstructionProviderFactory: { _ in roundProvider }
        )
        let finalRequest = readyReconstructionFinalRequest()
        let finalProvider = try ReceiptReadyReconstructionProvider(
            receipt: readyWorkerReceipt(
                connectionIdentity: phase2ReadyID(975),
                protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR1
                    .manifestDigest
            )
        )
        let finalCoordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: observer,
            reconstructionProviderFactory: { _ in finalProvider }
        )

        let round = await roundCoordinator.run(request: roundRequest)
        let final = await finalCoordinator.synthesize(request: finalRequest)

        guard case let .finished(_, roundAuthority, _) = round,
              case let .finished(_, finalAuthority, _) = final
        else {
            return XCTFail("Both receipt-qualified reconstruction paths must finish")
        }
        let expectedLifecycle: [ReceiptReadyReconstructionProvider.Event] = [
            .prepared, .connectionBound, .dispatchBound, .ran, .revalidated,
        ]
        let roundLifecycle = await roundProvider.lifecycle
        let finalLifecycle = await finalProvider.lifecycle
        XCTAssertEqual(roundLifecycle, expectedLifecycle)
        XCTAssertEqual(finalLifecycle, expectedLifecycle)
        XCTAssertEqual(observer.providerConnections.count, 2)
        XCTAssertEqual(
            Set(observer.providerDispatches.map(\.requestID)),
            Set([
                roundAuthority.expectedRequestID,
                finalAuthority.expectedRequestID,
            ])
        )
    }

    func testReconstructionSuccessfulRoundRetainsExactLeaseAndRequestAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let request = readyReconstructionRoundRequest()
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .continue,
            unresolvedGaps: []
        )
        let provider = ReadyReconstructionTerminalProvider(
            status: .completed,
            roundBodies: [
                .roundCandidate(candidate),
                .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
                .completed,
            ]
        )
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.run(request: request)

        guard case let .finished(lease, requestAuthority, outcome) = result else {
            return XCTFail("Expected a terminal-authorized success, got \(result)")
        }
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(outcome.candidate, candidate)
        XCTAssertEqual(requestAuthority.request, .round(request))
        XCTAssertEqual(requestAuthority.terminalReceipt, outcome.terminalReceipt)
    }

    func testReconstructionRoundCancellationAfterCompletedTerminalRetainsAuthority()
        async throws
    {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let request = readyReconstructionRoundRequest()
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .continue,
            unresolvedGaps: []
        )
        let provider = ReadyReconstructionTerminalProvider(
            status: .completed,
            roundBodies: [
                .roundCandidate(candidate),
                .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
                .completed,
            ]
        )
        let barrier = ReconstructionCompletedTerminalBarrier()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider },
            reconstructionInferenceRunner: .init { terminal in
                await barrier.pause(afterObserving: terminal)
            }
        )

        let turn = Task { await coordinator.run(request: request) }
        let terminal = await barrier.waitUntilObserved()
        turn.cancel()
        await barrier.release()
        let result = await turn.value

        guard case let .failedWithTerminalAuthority(
            lease,
            requestAuthority,
            failure
        ) = result else {
            return XCTFail("Expected terminal-authorized cancellation, got \(result)")
        }
        XCTAssertEqual(failure, .cancelled)
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(requestAuthority.request, .round(request))
        XCTAssertEqual(requestAuthority.terminalReceipt, terminal)
        XCTAssertEqual(terminal.status, .completed)
    }

    func testReconstructionSuccessfulFinalSynthesisRetainsExactRequestAuthority() async throws {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let request = readyReconstructionFinalRequest()
        let candidate = ReconstructionFinalSynthesisCandidate(
            kind: .synthesis,
            text: "Grounded synthesis.",
            evidenceIDs: request.acceptedEvidenceIDs
        )
        let provider = ReadyReconstructionTerminalProvider(
            status: .completed,
            finalBodies: [
                .finalCandidate(candidate),
                .usage(.init(promptTokens: 2, completionTokens: 1, totalTokens: 3)),
                .completed,
            ]
        )
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider }
        )

        let result = await coordinator.synthesize(request: request)

        guard case let .finished(lease, requestAuthority, outcome) = result else {
            return XCTFail("Expected a terminal-authorized final synthesis, got \(result)")
        }
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(outcome.candidate, candidate)
        XCTAssertEqual(requestAuthority.request, .finalSynthesis(request))
        XCTAssertEqual(requestAuthority.terminalReceipt, outcome.terminalReceipt)
    }

    func testReconstructionFinalCancellationAfterCompletedTerminalRetainsAuthority()
        async throws
    {
        let fixture = try ReadyInferenceFixture()
        let controller = try await fixture.makeReadyController()
        let request = readyReconstructionFinalRequest()
        let candidate = ReconstructionFinalSynthesisCandidate(
            kind: .synthesis,
            text: "Grounded synthesis.",
            evidenceIDs: request.acceptedEvidenceIDs
        )
        let provider = ReadyReconstructionTerminalProvider(
            status: .completed,
            finalBodies: [
                .finalCandidate(candidate),
                .usage(.init(promptTokens: 2, completionTokens: 1, totalTokens: 3)),
                .completed,
            ]
        )
        let barrier = ReconstructionCompletedTerminalBarrier()
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in provider },
            reconstructionInferenceRunner: .init { terminal in
                await barrier.pause(afterObserving: terminal)
            }
        )

        let turn = Task { await coordinator.synthesize(request: request) }
        let terminal = await barrier.waitUntilObserved()
        turn.cancel()
        await barrier.release()
        let result = await turn.value

        guard case let .failedWithTerminalAuthority(
            lease,
            requestAuthority,
            failure
        ) = result else {
            return XCTFail("Expected terminal-authorized cancellation, got \(result)")
        }
        XCTAssertEqual(failure, .cancelled)
        XCTAssertTrue(controller.isCurrent(lease))
        XCTAssertEqual(requestAuthority.request, .finalSynthesis(request))
        XCTAssertEqual(requestAuthority.terminalReceipt, terminal)
        XCTAssertEqual(terminal.status, .completed)
    }
}

private actor ReconstructionCompletedTerminalBarrier {
    private var observedTerminal: ReconstructionTerminalReceipt?
    private var observationWaiters:
        [CheckedContinuation<ReconstructionTerminalReceipt, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause(afterObserving terminal: ReconstructionTerminalReceipt) async {
        precondition(observedTerminal == nil && releaseWaiter == nil)
        observedTerminal = terminal
        let waiters = observationWaiters
        observationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: terminal) }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilObserved() async -> ReconstructionTerminalReceipt {
        if let observedTerminal { return observedTerminal }
        return await withCheckedContinuation { observationWaiters.append($0) }
    }

    func release() {
        let waiter = releaseWaiter
        releaseWaiter = nil
        waiter?.resume()
    }
}

private actor ReceiptReadyReconstructionProvider:
    ReconstructionInferenceProviding,
    ReconstructionInferenceWorkerProcessReceiptProviding
{
    enum Event: Equatable {
        case prepared
        case connectionBound
        case dispatchBound
        case ran
        case revalidated
    }

    private let receipt: Phase2InferenceWorkerProcessReceipt
    private let providerConnectionReceipt: Phase2InferenceProviderConnectionReceipt
    private var connectionValidator: ProviderConnectionValidator?
    private var dispatchValidator:
        (@MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool)?
    private var acceptedRequestIDs: Set<UUID> = []
    private(set) var lifecycle: [Event] = []

    init(receipt: Phase2InferenceWorkerProcessReceipt) throws {
        self.receipt = receipt
        providerConnectionReceipt = try .init(
            localAddress: "127.0.0.1",
            localPort: 54_321,
            remoteAddress: "127.0.0.1",
            remotePort: 1_234
        )
    }

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt {
        lifecycle.append(.prepared)
        return receipt
    }

    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool {
        guard workerReceipt == receipt, connectionValidator == nil else { return false }
        connectionValidator = validator
        lifecycle.append(.connectionBound)
        return true
    }

    func bindProviderDispatchValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping @MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool
    ) async -> Bool {
        guard workerReceipt == receipt, dispatchValidator == nil else { return false }
        dispatchValidator = validator
        lifecycle.append(.dispatchBound)
        return true
    }

    func acceptedProviderConnectionReceipt(
        requestID: UUID,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        workerReceipt == receipt && acceptedRequestIDs.contains(requestID)
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        lifecycle.append(.revalidated)
        return receipt == self.receipt
    }

    func runRound(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await authorize(requestID: requestID)
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .continue,
            unresolvedGaps: []
        )
        try await emit(.init(
            requestID: requestID,
            sequence: 1,
            body: .roundCandidate(candidate)
        ))
        try await emit(.init(
            requestID: requestID,
            sequence: 2,
            body: .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2))
        ))
        try await emit(.init(requestID: requestID, sequence: 3, body: .completed))
        return .init(
            requestID: requestID,
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            status: .completed
        )
    }

    func runFinalSynthesis(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await authorize(requestID: requestID)
        let candidate = ReconstructionFinalSynthesisCandidate(
            kind: .synthesis,
            text: "Receipt-qualified synthesis.",
            evidenceIDs: request.acceptedEvidenceIDs
        )
        try await emit(.init(
            requestID: requestID,
            sequence: 1,
            body: .finalCandidate(candidate)
        ))
        try await emit(.init(
            requestID: requestID,
            sequence: 2,
            body: .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2))
        ))
        try await emit(.init(requestID: requestID, sequence: 3, body: .completed))
        return .init(
            requestID: requestID,
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: nil,
            status: .completed
        )
    }

    func cancel(requestID: UUID) async {}

    private func authorize(requestID: UUID) async throws {
        lifecycle.append(.ran)
        guard let connectionValidator,
              await connectionValidator(providerConnectionReceipt),
              let dispatchValidator,
              await dispatchValidator(.init(requestID: requestID))
        else { throw ReadyReconstructionProviderFailure() }
        acceptedRequestIDs.insert(requestID)
    }
}

private struct PreTerminalCancellingReconstructionProvider:
    ReconstructionInferenceProviding
{
    func runRound(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        _ = requestID
        _ = request
        _ = emit
        throw CancellationError()
    }

    func runFinalSynthesis(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        _ = requestID
        _ = request
        _ = emit
        throw CancellationError()
    }

    func cancel(requestID: UUID) async {}
}

private actor ReadyReconstructionTerminalProvider: ReconstructionInferenceProviding {
    private let status: ReconstructionTerminalStatus
    private let terminalRequestIDOverride: UUID?
    private let beforeReturningTerminal: (@Sendable () async -> Void)?
    private let roundBodies: [ReconstructionAIWorkerEventBody]
    private let finalBodies: [ReconstructionAIWorkerEventBody]
    private let failsBeforeTerminal: Bool
    private var roundCalls = 0

    init(
        status: ReconstructionTerminalStatus,
        terminalRequestIDOverride: UUID? = nil,
        beforeReturningTerminal: (@Sendable () async -> Void)? = nil,
        roundBodies: [ReconstructionAIWorkerEventBody] = [],
        finalBodies: [ReconstructionAIWorkerEventBody] = [],
        failsBeforeTerminal: Bool = false
    ) {
        self.status = status
        self.terminalRequestIDOverride = terminalRequestIDOverride
        self.beforeReturningTerminal = beforeReturningTerminal
        self.roundBodies = roundBodies
        self.finalBodies = finalBodies
        self.failsBeforeTerminal = failsBeforeTerminal
    }

    func runRound(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        roundCalls += 1
        if failsBeforeTerminal { throw ReadyReconstructionProviderFailure() }
        for (index, body) in roundBodies.enumerated() {
            try await emit(.init(
                requestID: requestID,
                sequence: UInt64(index + 1),
                body: body
            ))
        }
        await beforeReturningTerminal?()
        return ReconstructionTerminalReceipt(
            requestID: terminalRequestIDOverride ?? requestID,
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            status: status
        )
    }

    func runFinalSynthesis(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        if failsBeforeTerminal { throw ReadyReconstructionProviderFailure() }
        for (index, body) in finalBodies.enumerated() {
            try await emit(.init(
                requestID: requestID,
                sequence: UInt64(index + 1),
                body: body
            ))
        }
        return ReconstructionTerminalReceipt(
            requestID: requestID,
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: nil,
            status: status
        )
    }

    func cancel(requestID: UUID) async {}
    func roundCallCount() -> Int { roundCalls }
}

private struct ReadyReconstructionProviderFailure: Error {}

@MainActor
private func coordinator(
    _ controller: Phase2LocalAIProviderController,
    _ factory: ReadyInferenceProviderFactory
) -> Phase2ReadyInferenceCoordinator {
    Phase2ReadyInferenceCoordinator(
        controller: controller,
        providerFactory: factory.make
    )
}

@MainActor
private final class ReadyInferenceProviderFactory {
    private let build: @MainActor (Phase2AIProviderConfiguration) -> any Phase2InferenceProviding
    private(set) var configurations: [Phase2AIProviderConfiguration] = []
    private(set) var providerIdentities: [ObjectIdentifier] = []
    private var retainedProviders: [AnyObject] = []

    init(
        build: @escaping @MainActor (Phase2AIProviderConfiguration)
            -> any Phase2InferenceProviding
    ) {
        self.build = build
    }

    func make(
        configuration: Phase2AIProviderConfiguration
    ) -> any Phase2InferenceProviding {
        configurations.append(configuration)
        let provider = build(configuration)
        if let object = provider as AnyObject? {
            retainedProviders.append(object)
            providerIdentities.append(ObjectIdentifier(object))
        }
        return provider
    }
}

/// Exercises the real coordinator/controller refresh and event reducer for both Assistant phases.
private actor TwoPhaseAssistantReadyInferenceProvider: Phase2InferenceProviding {
    private(set) var requests: [Phase2InferenceRequest] = []
    func run(request: Phase2InferenceRequest,
             emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void) async throws {
        requests.append(request)
        switch request.phase {
        case .toolSelection:
            let handle = request.toolHandles[0]
            try await emit(readyInferenceEvent(request, sequence: 1, body: .toolProposal(.init(
                callID: Phase2ProviderToolCallID(rawValue: "workspace-refresh")!, handleID: handle.handleID,
                functionName: "macscope_workspace_summary_v1", operationID: handle.operationID))))
        case .finalization:
            try await emit(readyInferenceEvent(request, sequence: 1, body: .finalCandidate(.init(
                kind: .insufficientEvidence, text: "No analyzed image is available.", evidenceIDs: []))))
        case .shellContinuation:
            throw CancellationError()
        }
        try await emit(readyInferenceEvent(request, sequence: 2, body: .usage(
            Phase2ProviderUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)!)))
        try await emit(readyInferenceEvent(request, sequence: 3,
            body: request.phase == .toolSelection ? .awaitingTools : .completed))
    }
    func cancel(requestID: UUID) async {}
}

private actor CompletingReadyInferenceProvider: Phase2InferenceProviding {
    private(set) var requests: [Phase2InferenceRequest] = []

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        try await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "grounded completion",
                evidenceIDs: []
            ))
        ))
        try await emit(readyInferenceEvent(
            request,
            sequence: 2,
            body: .usage(Phase2ProviderUsage(
                promptTokens: 7,
                completionTokens: 3,
                totalTokens: 10
            )!)
        ))
        try await emit(readyInferenceEvent(request, sequence: 3, body: .completed))
    }

    func cancel(requestID: UUID) async {}
}

@MainActor
private final class ReadyWorkerReceiptObserver:
    Phase2InferenceWorkerProcessReceiptObserving
{
    private let accepts: Bool
    private(set) var receipts: [Phase2InferenceWorkerProcessReceipt] = []
    private(set) var providerConnections: [Phase2InferenceProviderConnectionReceipt] = []
    private(set) var providerDispatches: [Phase2InferenceDispatchReceipt] = []

    init(accepts: Bool) {
        self.accepts = accepts
    }

    func acceptProviderConnectionReceipt(
        _ receipt: Phase2InferenceProviderConnectionReceipt,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        _ = workerReceipt
        providerConnections.append(receipt)
        return accepts
    }

    func acceptProviderDispatchReceipt(
        _ receipt: Phase2InferenceDispatchReceipt,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        _ = workerReceipt
        providerDispatches.append(receipt)
        return accepts
    }

    func acceptWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) -> Bool {
        receipts.append(receipt)
        return accepts
    }
}

private final class ReadyInferenceCancellationMeasurementObserver:
    Phase2InferenceMeasurementObserving, @unchecked Sendable
{
    enum Event: Equatable {
        case admitted
        case cancellationBegan
        case generationBegan
        case semanticAccepted
        case providerDrained
    }

    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    func admitted(phase _: Phase2InferencePhase) {
        lock.withLock { recordedEvents.append(.admitted) }
    }

    func generationBegan(phase _: Phase2InferencePhase) {
        lock.withLock { recordedEvents.append(.generationBegan) }
    }
    func acceptedSemantic(phase _: Phase2InferencePhase) {
        lock.withLock { recordedEvents.append(.semanticAccepted) }
    }
    func acceptedEvent(phase _: Phase2InferencePhase) {}

    func usageAccepted(
        phase _: Phase2InferencePhase,
        usage _: Phase2ProviderUsage
    ) {}

    func cancellationBegan(phase _: Phase2InferencePhase) {
        lock.withLock {
            guard !recordedEvents.contains(.cancellationBegan) else { return }
            recordedEvents.append(.cancellationBegan)
        }
    }

    func providerDrained(phase _: Phase2InferencePhase) {
        lock.withLock { recordedEvents.append(.providerDrained) }
    }
}

private actor ReceiptReadyInferenceProvider:
    Phase2InferenceWorkerProcessReceiptProviding
{
    enum Event: Equatable {
        case prepared
        case ran
        case revalidated
    }

    private let receipt: Phase2InferenceWorkerProcessReceipt
    private let revalidationResult: Bool
    private(set) var lifecycle: [Event] = []
    private var connectionValidator: ProviderConnectionValidator?
    private var dispatchValidator:
        (@MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool)?
    private var acceptedConnectionRequestID: UUID?

    init(
        receipt: Phase2InferenceWorkerProcessReceipt,
        revalidationResult: Bool
    ) {
        self.receipt = receipt
        self.revalidationResult = revalidationResult
    }

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt {
        lifecycle.append(.prepared)
        return receipt
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        lifecycle.append(.revalidated)
        return receipt == self.receipt && revalidationResult
    }

    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool {
        guard workerReceipt == receipt, connectionValidator == nil else { return false }
        connectionValidator = validator
        return true
    }

    func bindProviderDispatchValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping @MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool
    ) async -> Bool {
        guard workerReceipt == receipt, dispatchValidator == nil else { return false }
        dispatchValidator = validator
        return true
    }

    func acceptedProviderConnectionReceipt(
        requestID: UUID,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        workerReceipt == receipt && acceptedConnectionRequestID == requestID
    }

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        lifecycle.append(.ran)
        guard let dispatchValidator,
              await dispatchValidator(.init(requestID: request.requestID)),
              let connectionValidator,
              await connectionValidator(readyProviderConnectionReceipt())
        else { throw AIAgentXPCTransportError.malformedReply }
        acceptedConnectionRequestID = request.requestID
        try await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "receipt-qualified completion",
                evidenceIDs: []
            ))
        ))
        try await emit(readyInferenceEvent(
            request,
            sequence: 2,
            body: .usage(Phase2ProviderUsage(
                promptTokens: 7,
                completionTokens: 3,
                totalTokens: 10
            )!)
        ))
        try await emit(readyInferenceEvent(request, sequence: 3, body: .completed))
    }

    func cancel(requestID: UUID) async {}
}

private actor PreparationBlockingReceiptProvider:
    Phase2InferenceWorkerProcessReceiptProviding
{
    private let receipt: Phase2InferenceWorkerProcessReceipt
    private var preparationStarted = false
    private var preparationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private var connectionValidator: ProviderConnectionValidator?
    private var dispatchValidator:
        (@MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool)?
    private var acceptedConnectionRequestID: UUID?
    private(set) var startedRequestIDs: [UUID] = []

    init(receipt: Phase2InferenceWorkerProcessReceipt) {
        self.receipt = receipt
    }

    func prepareWorkerProcessReceipt() async throws -> Phase2InferenceWorkerProcessReceipt {
        preparationStarted = true
        let waiters = preparationStartWaiters
        preparationStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { preparationContinuation = $0 }
        return receipt
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        receipt == self.receipt
    }

    func bindProviderConnectionValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping ProviderConnectionValidator
    ) async -> Bool {
        guard workerReceipt == receipt, connectionValidator == nil else { return false }
        connectionValidator = validator
        return true
    }

    func bindProviderDispatchValidator(
        workerReceipt: Phase2InferenceWorkerProcessReceipt,
        validator: @escaping @MainActor @Sendable (Phase2InferenceDispatchReceipt) -> Bool
    ) async -> Bool {
        guard workerReceipt == receipt, dispatchValidator == nil else { return false }
        dispatchValidator = validator
        return true
    }

    func acceptedProviderConnectionReceipt(
        requestID: UUID,
        workerReceipt: Phase2InferenceWorkerProcessReceipt
    ) async -> Bool {
        workerReceipt == receipt && acceptedConnectionRequestID == requestID
    }

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        startedRequestIDs.append(request.requestID)
        guard let dispatchValidator,
              await dispatchValidator(.init(requestID: request.requestID)),
              let connectionValidator,
              await connectionValidator(readyProviderConnectionReceipt())
        else { throw AIAgentXPCTransportError.malformedReply }
        acceptedConnectionRequestID = request.requestID
        try await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "reserved qualification completion",
                evidenceIDs: []
            ))
        ))
        try await emit(readyInferenceEvent(
            request,
            sequence: 2,
            body: .usage(Phase2ProviderUsage(
                promptTokens: 7,
                completionTokens: 3,
                totalTokens: 10
            )!)
        ))
        try await emit(readyInferenceEvent(request, sequence: 3, body: .completed))
    }

    func cancel(requestID: UUID) async {}

    func waitUntilPreparationStarts() async {
        guard !preparationStarted else { return }
        await withCheckedContinuation { preparationStartWaiters.append($0) }
    }

    func releasePreparation() {
        let continuation = preparationContinuation
        preparationContinuation = nil
        continuation?.resume()
    }
}

private actor AwaitingToolsReadyInferenceProvider: Phase2InferenceProviding {
    private(set) var requests: [Phase2InferenceRequest] = []

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        try await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .toolProposal(.init(
                callID: Phase2ProviderToolCallID(rawValue: "provider-call-1")!,
                handleID: request.toolHandles[0].handleID,
                functionName: "macscope_selection_explain_v1",
                operationID: request.toolHandles[0].operationID
            ))
        ))
        try await emit(readyInferenceEvent(
            request,
            sequence: 2,
            body: .usage(Phase2ProviderUsage(
                promptTokens: 7,
                completionTokens: 3,
                totalTokens: 10
            )!)
        ))
        try await emit(readyInferenceEvent(request, sequence: 3, body: .awaitingTools))
    }

    func cancel(requestID: UUID) async {}
}

private actor ControlledReadyInferenceProvider: Phase2InferenceDispatchReceiptProviding {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var runWaiter: CheckedContinuation<Void, Never>?
    private(set) var startedRequestIDs: [UUID] = []
    private(set) var cancelledRequestIDs: [UUID] = []

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        _ = emit
        started = true
        startedRequestIDs.append(request.requestID)
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if cancelledRequestIDs.contains(request.requestID) {
            throw CancellationError()
        }
        await withCheckedContinuation { continuation in
            runWaiter = continuation
        }
        try Task.checkCancellation()
    }

    func run(
        request: Phase2InferenceRequest,
        onDispatched: @escaping @Sendable (Phase2InferenceDispatchReceipt) -> Void,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        started = true
        startedRequestIDs.append(request.requestID)
        onDispatched(.init(requestID: request.requestID))
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        // Race a semantic event immediately after dispatch. The controlled barrier must keep it
        // outside the inference state until the caller has actually issued cancellation.
        try await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "must not be accepted",
                evidenceIDs: []
            ))
        ))
        if cancelledRequestIDs.contains(request.requestID) {
            throw CancellationError()
        }
        await withCheckedContinuation { continuation in
            runWaiter = continuation
        }
        try Task.checkCancellation()
    }

    func cancel(requestID: UUID) async {
        cancelledRequestIDs.append(requestID)
        let waiter = runWaiter
        runWaiter = nil
        waiter?.resume()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private struct NoHTTPDispatchReceiptReadyInferenceProvider:
    Phase2InferenceDispatchReceiptProviding
{
    func run(
        request _: Phase2InferenceRequest,
        emit _: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {}

    func run(
        request _: Phase2InferenceRequest,
        onDispatched _: @escaping @Sendable (Phase2InferenceDispatchReceipt) -> Void,
        emit _: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        // Models an accepted app-to-XPC call whose worker never reaches URLSession response
        // headers. The missing HTTP-boundary control receipt must decline the barrier.
    }

    func cancel(requestID _: UUID) async {}
}

private struct ImmediateDrainReadyInferenceProvider:
    Phase2InferenceDispatchReceiptProviding
{
    func run(
        request _: Phase2InferenceRequest,
        emit _: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        try await Task.sleep(for: .seconds(60))
    }

    func run(
        request: Phase2InferenceRequest,
        onDispatched: @escaping @Sendable (Phase2InferenceDispatchReceipt) -> Void,
        emit _: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        onDispatched(.init(requestID: request.requestID))
        try await Task.sleep(for: .seconds(60))
    }

    func cancel(requestID _: UUID) async {}
}

private actor NoncooperativeLateSuccessProvider: Phase2InferenceProviding {
    private var started = false
    private var cancelled = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelledRequestIDs: [UUID] = []

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        try? await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "late success",
                evidenceIDs: []
            ))
        ))
        try? await emit(readyInferenceEvent(request, sequence: 2, body: .completed))
    }

    func cancel(requestID: UUID) async {
        cancelledRequestIDs.append(requestID)
        cancelled = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func releaseLateSuccess() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct CompletionRaceReadyInferenceProvider: Phase2InferenceProviding {
    let invalidate: @Sendable () async -> Void

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        try await emit(readyInferenceEvent(
            request,
            sequence: 1,
            body: .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "racing success",
                evidenceIDs: []
            ))
        ))
        try await emit(readyInferenceEvent(
            request,
            sequence: 2,
            body: .usage(Phase2ProviderUsage(
                promptTokens: 7,
                completionTokens: 3,
                totalTokens: 10
            )!)
        ))
        try await emit(readyInferenceEvent(request, sequence: 3, body: .completed))
        await invalidate()
    }

    func cancel(requestID: UUID) async {}
}

private struct ReadyInferenceDiscovery: Phase2LocalModelDiscovering {
    let inventory: Phase2LocalModelInventory

    func discoverModels(
        endpoint: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) async throws -> Phase2LocalModelDiscoveryOutcome {
        .success(inventory)
    }

    func cancel(requestID: UUID) async {}
}

private struct UnusedReadyInferenceLifecycle: Phase2LocalModelLifecycleControlling {
    func perform(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint,
        acceptedInventory: Phase2LocalModelInventory
    ) async throws -> Phase2LocalModelLifecycleOutcome {
        XCTFail("Inference readiness must not perform model lifecycle work")
        return .cancelledBeforeDispatch
    }

    func cancel(effectID: UUID) async {}
}

private struct ReadyInferenceFixture {
    let endpoint: Phase2LocalProviderEndpoint
    let inventory: Phase2LocalModelInventory
    let selection: Phase2LocalAISelection
    let configuration: Phase2AIProviderConfiguration

    init() throws {
        endpoint = try .init(
            profileID: phase2ReadyID(1),
            generation: 7,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 4_000,
            resourceTimeoutMilliseconds: 60_000,
            inferencePolicy: .init()
        )
        let model = Self.model(key: "publisher/exact-language-model@q4", instanceID: "loaded-instance-exact")
        inventory = try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [model]
        )
        selection = try .authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: model.key,
            maximumTokens: 2_048
        )
        configuration = selection.configuration
    }

    @MainActor
    func makeController() -> Phase2LocalAIProviderController {
        Phase2LocalAIProviderController(
            endpoint: endpoint,
            discovery: ReadyInferenceDiscovery(inventory: inventory),
            lifecycle: UnusedReadyInferenceLifecycle()
        )
    }

    /// Two served chat models, so discovery cannot pick one and the turn stays unselected.
    @MainActor
    func makeUnselectedController() throws -> Phase2LocalAIProviderController {
        let models = inventory.models + [
            Self.model(key: "publisher/second-language-model@q4", instanceID: "loaded-instance-second"),
        ]
        return Phase2LocalAIProviderController(
            endpoint: endpoint,
            discovery: ReadyInferenceDiscovery(inventory: try .init(
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                models: models
            )),
            lifecycle: UnusedReadyInferenceLifecycle()
        )
    }

    private static func model(key: String, instanceID: String) -> Phase2LocalModelDescriptor {
        Phase2LocalModelDescriptor(
            type: .language,
            publisher: "Local Test Publisher",
            key: key,
            displayName: "Exact Language Model",
            architecture: "transformer",
            quantization: .init(name: "Q4", bitsPerWeight: 4),
            sizeBytesOnDisk: 4_294_967_296,
            parameterCountDescription: "7B",
            maximumContextLength: 32_768,
            format: .gguf,
            capabilities: .init(
                supportsVision: false,
                trainedForToolUse: false,
                reasoning: .init(allowedOptions: [.off], defaultOption: .off)
            ),
            summary: "A complete local language-model fixture.",
            variants: ["q4"],
            providerSelectedVariant: "q4",
            loadedInstances: [.init(id: instanceID, configuration: .init(effectiveContextLength: 32_768))]
        )
    }

    @MainActor
    func makeReadyController() async throws -> Phase2LocalAIProviderController {
        let controller = makeController()
        _ = try await controller.refresh()
        try controller.select(
            modelKey: configuration.model,
            maximumTokens: configuration.maximumTokens
        )
        return controller
    }
}

private func makeReadyInferenceRequest(
    requestID: UUID = phase2ReadyID(10),
    phase: Phase2InferencePhase = .finalization,
    toolHandles: [Phase2InferenceToolHandle] = [],
    lifecycleRevision: UInt64 = 19
) -> Phase2InferenceRequest {
    let document = Phase2ReadDocumentIdentity(instanceID: phase2ReadyID(11))
    let workspace = Phase2ReadWorkspaceIdentity(
        document: document,
        instanceID: phase2ReadyID(12)
    )
    return .init(
        protocolVersion: .init(
            rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
        ),
        phase: phase,
        sessionID: phase2ReadyID(13),
        turnID: phase2ReadyID(14),
        requestID: requestID,
        document: document,
        workspace: workspace,
        lifecycleRevision: lifecycleRevision,
        userGoal: "Explain the exact selected function from grounded evidence.",
        groundedContext: try! Phase2GroundedContextCompiler().compile(
            records: [],
            currentStateByEvidenceID: [:]
        ),
        toolHandles: toolHandles,
        conversationContext: .init(turns: [], omittedTurnCount: 0),
        limits: .maximum
    )
}

private func readyReconstructionRoundRequest() -> ReconstructionInferenceRoundRequest {
    let contextBytes = Data(#"{"context":"ready-reconstruction"}"#.utf8)
    return ReconstructionInferenceRoundRequest(
        protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
        jobID: phase2ReadyID(960),
        checkpointRevision: 4,
        roundID: phase2ReadyID(961),
        corpusManifestSHA256: String(repeating: "a", count: 64),
        evidenceFrontierSHA256: String(repeating: "b", count: 64),
        registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
            .toolRegistry.identity.sha256,
        context: ReconstructionRetrievedContext(
            canonicalBytes: contextBytes,
            canonicalSHA256: ReconstructionPackageCodec.sha256(contextBytes),
            evidenceIDs: []
        ),
        handles: [
            MacScopeAnalysisCore.ReconstructionOfferedToolHandle(
                handleID: phase2ReadyID(962),
                operationID: .corpusSummary
            ),
        ]
    )
}

private func readyReconstructionFinalRequest() -> ReconstructionFinalSynthesisRequest {
    let evidenceID = phase2ReadyID(963)
    let contextBytes = Data(#"{"context":"ready-final-synthesis"}"#.utf8)
    return ReconstructionFinalSynthesisRequest(
        jobID: phase2ReadyID(960),
        checkpointRevision: 4,
        corpusManifestSHA256: String(repeating: "a", count: 64),
        evidenceFrontierSHA256: String(repeating: "b", count: 64),
        acceptedEvidenceIDs: [evidenceID],
        context: ReconstructionRetrievedContext(
            canonicalBytes: contextBytes,
            canonicalSHA256: ReconstructionPackageCodec.sha256(contextBytes),
            evidenceIDs: [evidenceID]
        )
    )
}

private func readyInferenceEvent(
    _ request: Phase2InferenceRequest,
    sequence: UInt64,
    body: Phase2InferenceEventBody
) -> Phase2InferenceEvent {
    .init(
        protocolVersion: request.protocolVersion,
        phase: request.phase,
        sessionID: request.sessionID,
        turnID: request.turnID,
        requestID: request.requestID,
        document: request.document,
        workspace: request.workspace,
        lifecycleRevision: request.lifecycleRevision,
        sequence: sequence,
        body: body
    )
}

private func phase2ReadyID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func readyWorkerReceipt(
    connectionIdentity: UUID,
    profileID: UUID = phase2ReadyID(1),
    configurationGeneration: UInt64 = 7,
    protocolManifestDigest: String = Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest
) throws -> Phase2InferenceWorkerProcessReceipt {
    try .init(
        processIdentifier: 7_001,
        providerGeneration: 9,
        connectionIdentity: connectionIdentity,
        profileID: profileID,
        configurationGeneration: configurationGeneration,
        protocolManifestDigest: protocolManifestDigest
    )
}

private func readyProviderConnectionReceipt() -> Phase2InferenceProviderConnectionReceipt {
    try! .init(
        localAddress: "127.0.0.1",
        localPort: 54_321,
        remoteAddress: "127.0.0.1",
        remotePort: 1_234
    )
}

import XCTest
@testable import MacScope

final class DebuggerBreakpointBindingReducerTests: XCTestCase {
    func testExactCurrentObservationPlanAndReceiptEstablishBoundOwnership() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)

        try establishResolution(&reducer, fixture: fixture)
        XCTAssertTrue(reducer.admit(fixture.plan))
        XCTAssertTrue(reducer.complete(fixture.receipt))

        XCTAssertEqual(reducer.snapshot.backendState, .bound([fixture.location]))
        XCTAssertEqual(reducer.snapshot.ownedLocations, [fixture.location])
        XCTAssertNil(reducer.snapshot.pendingPlan)
        XCTAssertEqual(reducer.snapshot.authorityRevision.rawValue, 4)
        XCTAssertFalse(reducer.snapshot.isInvalidated)
    }

    func testAdmitRejectsGenerationPIDStopAndObservationDigestDriftByteIdentically() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)

        let wrongGeneration = try XCTUnwrap(DebuggerBreakpointBindingPlan(
            transactionID: .init(rawValue: UUID()),
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration + 1,
            stopCoordinate: fixture.stop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID,
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            resolutionObservationDigest: fixture.observation.canonicalDigest,
            mappingKey: fixture.mappingKey,
            bindings: [fixture.binding],
            ownershipTagDigest: fixture.plan.ownershipTagDigest,
            canonicalPlanDigest: fixture.plan.canonicalPlanDigest
        ))
        let wrongDigest = try XCTUnwrap(DebuggerBreakpointBindingPlan(
            transactionID: .init(rawValue: UUID()),
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            stopCoordinate: fixture.stop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID,
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            resolutionObservationDigest: digest(99),
            mappingKey: fixture.mappingKey,
            bindings: [fixture.binding],
            ownershipTagDigest: fixture.plan.ownershipTagDigest,
            canonicalPlanDigest: fixture.plan.canonicalPlanDigest
        ))

        for rejected in [wrongGeneration, wrongDigest] {
            let before = reducer.snapshot
            XCTAssertFalse(reducer.admit(rejected))
            XCTAssertEqual(reducer.snapshot, before)
        }
    }

    func testObservationRequiresExactCompleteExpectedSpecificationSet() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        XCTAssertNil(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            mappingKey: fixture.mappingKey,
            expectedSpecifications: [],
            results: [fixture.resolution]
        ))
        XCTAssertNil(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            mappingKey: fixture.mappingKey,
            expectedSpecifications: [
                .init(logicalID: logicalID, specificationRevision: try .init(validating: 2))
            ],
            results: [fixture.resolution]
        ))

        let emptyCatalog = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: 2
        )
        XCTAssertNotNil(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: emptyCatalog,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            mappingKey: fixture.mappingKey,
            expectedSpecifications: [],
            results: []
        ))
        let duplicate = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            mappingKey: fixture.mappingKey,
            expectedSpecifications: fixture.observation.expectedSpecifications,
            results: [fixture.resolution]
        ))
        XCTAssertEqual(duplicate.canonicalDigest, fixture.observation.canonicalDigest)
        let pending = DebuggerLogicalBreakpointResolution(
            logicalID: logicalID,
            specificationRevision: fixture.binding.site.specificationRevision,
            state: .pending(.moduleUnloaded)
        )
        let changed = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: fixture.catalogCoordinate,
            resolutionCatalogCoordinate: fixture.resolutionCatalogCoordinate,
            mappingKey: fixture.mappingKey,
            expectedSpecifications: fixture.observation.expectedSpecifications,
            results: [pending]
        ))
        XCTAssertNotEqual(changed.canonicalDigest, fixture.observation.canonicalDigest)
    }

    func testNewerResolutionDuringApplyingRetainsOldReceiptWithoutClaimingConvergence() throws {
        let original = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        let newer = try makeFixture(
            epoch: original.epoch,
            stop: original.stop,
            catalogRevision: 2,
            specificationRevision: 2,
            resolutionRevision: 9,
            mappingAuthorityRevision: 6,
            transactionUUID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: original.epoch)
        try establishResolution(&reducer, fixture: original)
        XCTAssertTrue(reducer.admit(original.plan))
        XCTAssertTrue(reducer.observeResolution(newer.observation))
        XCTAssertTrue(reducer.complete(original.receipt))

        XCTAssertEqual(reducer.snapshot.ownedLocations, [original.location])
        XCTAssertEqual(reducer.snapshot.backendState, .armedUnobserved([original.location]))
        XCTAssertEqual(
            reducer.snapshot.resolutions.first?.state,
            .pending(.newerCatalogAwaitingConvergence)
        )
        XCTAssertEqual(reducer.snapshot.desiredCatalogCoordinate, newer.catalogCoordinate)
    }

    func testNewStopDuringApplyingSupersedesOldReceiptAndPreservesApplyingUntilReceipt() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        XCTAssertTrue(reducer.admit(fixture.plan))

        let newStop = makeStop(epoch: fixture.epoch, stopRevision: 4)
        XCTAssertTrue(reducer.beganNewStop(
            newStop,
            adapterGeneration: fixture.plan.adapterGeneration,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID + 1
        ))
        XCTAssertEqual(reducer.snapshot.backendState, .applying(fixture.plan.transactionID))
        XCTAssertTrue(reducer.complete(fixture.receipt))
        XCTAssertEqual(reducer.snapshot.backendState, .armedUnobserved([fixture.location]))
        XCTAssertEqual(reducer.snapshot.ownedLocations, [fixture.location])
    }

    func testBeforeWriteCancellationIsExactAndPreservesResolutionAndOwnership() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        XCTAssertTrue(reducer.admit(fixture.plan))

        let beforeForeign = reducer.snapshot
        XCTAssertFalse(reducer.cancelBeforeWrite(
            transactionID: .init(rawValue: UUID())
        ))
        XCTAssertEqual(reducer.snapshot, beforeForeign)
        XCTAssertTrue(reducer.cancelBeforeWrite(transactionID: fixture.plan.transactionID))
        XCTAssertNil(reducer.snapshot.pendingPlan)
        XCTAssertEqual(reducer.snapshot.backendState, .unbound)
        XCTAssertEqual(reducer.snapshot.resolutions, fixture.observation.results)
        let after = reducer.snapshot
        XCTAssertFalse(reducer.cancelBeforeWrite(transactionID: fixture.plan.transactionID))
        XCTAssertEqual(reducer.snapshot, after)
    }

    func testSameStopRuntimeInventoryInvalidationTombstonesResolutionAndRetainsOwnership() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        _ = reducer.admit(fixture.plan)
        _ = reducer.complete(fixture.receipt)

        XCTAssertTrue(reducer.runtimeInventoryInvalidatedAtCurrentStop(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            stopCoordinate: fixture.stop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID
        ))
        XCTAssertNil(reducer.snapshot.resolutionObservation)
        XCTAssertEqual(
            reducer.snapshot.resolutions.first?.state,
            .pending(.awaitingRuntimeInventory)
        )
        XCTAssertEqual(reducer.snapshot.backendState, .armedUnobserved([fixture.location]))
        XCTAssertEqual(reducer.snapshot.currentStop, fixture.stop)
        let after = reducer.snapshot
        XCTAssertFalse(reducer.runtimeInventoryInvalidatedAtCurrentStop(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            stopCoordinate: fixture.stop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID
        ))
        XCTAssertEqual(reducer.snapshot, after)
    }

    func testSessionReducerBlocksResumeUntilExactBeforeWriteCancellation() throws {
        let epoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        var reducer = makeSessionReducerWithBreakpointStop(epoch: epoch)
        let stop = try XCTUnwrap(reducer.state.stopCoordinate)
        let fixture = try makeFixture(
            epoch: epoch,
            stop: stop,
            catalogRevision: 1,
            specificationRevision: 1
        )
        XCTAssertTrue(reducer.observeLogicalBreakpointResolution(fixture.observation))
        XCTAssertTrue(reducer.admitLogicalBreakpointBindingPlan(fixture.plan))

        let resume = sessionRequest(
            sequence: 3,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: stop
        )
        XCTAssertEqual(reducer.admit(resume), .rejected(.invalidTransition))
        XCTAssertTrue(reducer.cancelLogicalBreakpointBindingBeforeWrite(
            transactionID: fixture.plan.transactionID
        ))
        guard case .accepted = reducer.admit(resume) else {
            return XCTFail("Resume must be admitted after exact before-write cancellation")
        }
        XCTAssertNil(reducer.state.breakpointBindingState.resolutionObservation)
    }

    func testSessionReducerTerminalEventClearsBindingOwnership() throws {
        let epoch = DebuggerSessionEpoch()
        var reducer = makeSessionReducerWithBreakpointStop(epoch: epoch)
        let stop = try XCTUnwrap(reducer.state.stopCoordinate)
        let fixture = try makeFixture(
            epoch: epoch,
            stop: stop,
            catalogRevision: 1,
            specificationRevision: 1
        )
        XCTAssertTrue(reducer.observeLogicalBreakpointResolution(fixture.observation))
        XCTAssertTrue(reducer.admitLogicalBreakpointBindingPlan(fixture.plan))
        XCTAssertTrue(reducer.completeLogicalBreakpointBinding(fixture.receipt))

        let terminate = sessionRequest(
            sequence: 3,
            operation: .terminate,
            session: reducer.state.sessionCoordinate
        )
        guard case .accepted = reducer.admit(terminate) else {
            return XCTFail("terminate admission failed")
        }
        XCTAssertEqual(reducer.reduce(sessionEvent(7, terminate, .requestStarted)), .accepted)
        XCTAssertEqual(reducer.reduce(sessionEvent(
            8,
            terminate,
            .processExited(observedPID: 77, exitCode: 0)
        )), .accepted)
        XCTAssertTrue(reducer.state.breakpointBindingState.isTerminal)
        XCTAssertEqual(reducer.state.breakpointBindingState.backendState, .unbound)
        XCTAssertTrue(reducer.state.breakpointBindingState.ownedLocations.isEmpty)
    }

    func testSessionReducerExplicitInvalidationFailsBindingAuthorityClosed() throws {
        let epoch = DebuggerSessionEpoch()
        var reducer = makeSessionReducerWithBreakpointStop(epoch: epoch)
        let stop = try XCTUnwrap(reducer.state.stopCoordinate)
        let fixture = try makeFixture(
            epoch: epoch,
            stop: stop,
            catalogRevision: 1,
            specificationRevision: 1
        )
        XCTAssertTrue(reducer.observeLogicalBreakpointResolution(fixture.observation))
        XCTAssertTrue(reducer.admitLogicalBreakpointBindingPlan(fixture.plan))
        XCTAssertTrue(reducer.completeLogicalBreakpointBinding(fixture.receipt))
        let diagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: "test invalidation",
            targetDisposition: .unknown
        )
        let invalidation = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: .init(rawValue: 7),
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: reducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .sessionInvalidated(diagnostic)
        )

        XCTAssertEqual(reducer.reduce(invalidation), .accepted)
        XCTAssertTrue(reducer.state.isInvalidated)
        XCTAssertTrue(reducer.state.breakpointBindingState.isInvalidated)
        XCTAssertEqual(
            reducer.state.breakpointBindingState.backendState,
            .failClosed(.sessionInvalidated)
        )
    }

    func testSessionReducerAttributesCallbackFaultToLogicalBreakpointReconciliation() throws {
        let epoch = DebuggerSessionEpoch()
        var reducer = makeSessionReducerWithBreakpointStop(epoch: epoch)
        let stop = try XCTUnwrap(reducer.state.stopCoordinate)
        let fixture = try makeFixture(
            epoch: epoch,
            stop: stop,
            catalogRevision: 1,
            specificationRevision: 1
        )
        XCTAssertTrue(reducer.observeLogicalBreakpointResolution(fixture.observation))
        XCTAssertTrue(reducer.admitLogicalBreakpointBindingPlan(fixture.plan))
        XCTAssertTrue(reducer.completeLogicalBreakpointBinding(fixture.receipt))

        let resume = sessionRequest(
            sequence: 3,
            operation: .continue,
            session: reducer.state.sessionCoordinate,
            stop: stop
        )
        guard case .accepted = reducer.admit(resume) else {
            return XCTFail("resume admission failed")
        }
        XCTAssertEqual(reducer.reduce(sessionEvent(7, resume, .requestStarted)), .accepted)
        XCTAssertEqual(reducer.reduce(sessionEvent(
            8,
            resume,
            .processRunning(observedPID: fixture.plan.observedPID)
        )), .accepted)

        let fault = try makeCallback(
            fixture: fixture,
            sequence: 1,
            hitCount: 0,
            outcome: .fault(code: "condition-timeout")
        )
        let batch = try XCTUnwrap(DebuggerBreakpointCallbackBatch(
            sessionEpoch: epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            processID: fixture.plan.observedPID,
            afterSequence: 0,
            nextSequence: 1,
            isFinal: true,
            records: [fault]
        ))
        let callbackEvent = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: .init(rawValue: 9),
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: reducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .logicalBreakpointCallbacksDrained(batch)
        )

        XCTAssertEqual(reducer.reduce(callbackEvent), .accepted)
        XCTAssertEqual(
            reducer.state.lastDiagnostic?.semanticLabel,
            DebuggerOperation.reconcileLogicalBreakpoints.displayLabel
        )
    }

    func testForeignAndBeforeWriteMalformedCompletionsAreByteIdenticalNoOps() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        XCTAssertTrue(reducer.admit(fixture.plan))
        let before = reducer.snapshot
        let foreign = try XCTUnwrap(DebuggerBreakpointBindingReceipt(
            transactionID: .init(rawValue: UUID()),
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            stopCoordinate: fixture.stop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID,
            canonicalPlanDigest: digest(8),
            didWriteBackend: false,
            completeOwnedInventory: []
        ))
        XCTAssertFalse(reducer.complete(foreign))
        XCTAssertEqual(reducer.snapshot, before)
        XCTAssertFalse(reducer.rejectMalformedCurrentCompletion(
            transactionID: fixture.plan.transactionID,
            didWriteMayHaveOccurred: false,
            positivelyKnownLocations: []
        ))
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testPostWriteUncertaintyRetainsPositiveIDsAndFailsClosed() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        XCTAssertTrue(reducer.admit(fixture.plan))
        XCTAssertTrue(reducer.rejectMalformedCurrentCompletion(
            transactionID: fixture.plan.transactionID,
            didWriteMayHaveOccurred: true,
            positivelyKnownLocations: [fixture.location]
        ))

        XCTAssertEqual(reducer.snapshot.backendState, .failClosed(.postWriteUncertainty))
        XCTAssertEqual(reducer.snapshot.ownedLocations, [fixture.location])
        XCTAssertTrue(reducer.snapshot.isInvalidated)
    }

    func testTypedCallbacksRequireContiguousGenerationSequenceAndExactIssuance() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        _ = reducer.admit(fixture.plan)
        _ = reducer.complete(fixture.receipt)
        _ = reducer.resumed(sessionEpoch: fixture.epoch)

        let first = try makeCallback(fixture: fixture, sequence: 1, hitCount: 1)
        let gap = try makeCallback(fixture: fixture, sequence: 2, hitCount: 2)
        let wrongIssuance = try XCTUnwrap(DebuggerBreakpointCallbackRecord(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            processID: fixture.plan.observedPID,
            sequence: 1,
            logicalID: logicalID,
            specificationRevision: fixture.binding.site.specificationRevision,
            bindingID: fixture.binding.id,
            backendBreakpointID: fixture.location.backendBreakpointID,
            backendLocationID: fixture.location.backendLocationID,
            issuanceDigest: digest(77),
            observedLogicalHitCount: 1,
            outcome: .stopped
        ))

        var before = reducer.snapshot
        XCTAssertFalse(reducer.recordCallback(gap))
        XCTAssertEqual(reducer.snapshot, before)
        XCTAssertFalse(reducer.recordCallback(wrongIssuance))
        XCTAssertEqual(reducer.snapshot, before)
        XCTAssertTrue(reducer.recordCallback(first))
        XCTAssertEqual(reducer.snapshot.lastCallbackSequence, 1)
        XCTAssertEqual(reducer.snapshot.observedHitCounts[logicalID], 1)
        XCTAssertEqual(
            reducer.snapshot.resolutions.first?.state,
            .pending(.hitAwaitingInventory)
        )
        before = reducer.snapshot
        XCTAssertFalse(reducer.recordCallback(first))
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testCallbackFaultIsOneAcceptedFailClosedMutationThenTombstone() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        _ = reducer.admit(fixture.plan)
        _ = reducer.complete(fixture.receipt)
        _ = reducer.resumed(sessionEpoch: fixture.epoch)
        let fault = try makeCallback(
            fixture: fixture,
            sequence: 1,
            hitCount: 0,
            outcome: .fault(code: "condition-timeout")
        )

        XCTAssertTrue(reducer.recordCallback(fault))
        XCTAssertEqual(reducer.snapshot.backendState, .failClosed(.callbackFault))
        XCTAssertEqual(reducer.snapshot.observedHitCounts[logicalID], 0)
        XCTAssertEqual(reducer.snapshot.lastCallbackSequence, 1)
        XCTAssertTrue(reducer.snapshot.isInvalidated)
        let after = reducer.snapshot
        XCTAssertFalse(reducer.recordCallback(fault))
        XCTAssertEqual(reducer.snapshot, after)
    }

    func testZeroCallbackHitCountIsRejectedForEveryNonFaultOutcome() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        let nonFaultOutcomes: [DebuggerBreakpointCallbackOutcome] = [
            .ignored,
            .conditionFalse,
            .stopped,
            .continued,
        ]

        for outcome in nonFaultOutcomes {
            XCTAssertNil(DebuggerBreakpointCallbackRecord(
                sessionEpoch: fixture.epoch,
                adapterGeneration: fixture.plan.adapterGeneration,
                processID: fixture.plan.observedPID,
                sequence: 1,
                logicalID: logicalID,
                specificationRevision: fixture.binding.site.specificationRevision,
                bindingID: fixture.binding.id,
                backendBreakpointID: fixture.location.backendBreakpointID,
                backendLocationID: fixture.location.backendLocationID,
                issuanceDigest: fixture.binding.issuanceDigest,
                observedLogicalHitCount: 0,
                outcome: outcome
            ))
        }
    }

    func testResumeNewStopAndInventoryRetainOwnershipWithoutRemintingOldBinding() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        _ = reducer.admit(fixture.plan)
        _ = reducer.complete(fixture.receipt)

        XCTAssertTrue(reducer.resumed(sessionEpoch: fixture.epoch))
        XCTAssertEqual(reducer.snapshot.backendState, .armedUnobserved([fixture.location]))
        let newStop = makeStop(epoch: fixture.epoch, stopRevision: 4)
        XCTAssertTrue(reducer.beganNewStop(
            newStop,
            adapterGeneration: fixture.plan.adapterGeneration,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID + 1
        ))
        let incomplete = try XCTUnwrap(DebuggerBreakpointOwnedInventoryObservation(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            stopCoordinate: newStop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID + 1,
            isComplete: false,
            locations: [fixture.location]
        ))
        let before = reducer.snapshot
        XCTAssertFalse(reducer.observeOwnedInventory(incomplete))
        XCTAssertEqual(reducer.snapshot, before)

        let complete = try XCTUnwrap(DebuggerBreakpointOwnedInventoryObservation(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            stopCoordinate: newStop,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID + 1,
            isComplete: true,
            locations: [fixture.location]
        ))
        XCTAssertTrue(reducer.observeOwnedInventory(complete))
        XCTAssertEqual(reducer.snapshot.backendInventoryRevision.rawValue, 1)
        XCTAssertEqual(reducer.snapshot.backendState, .armedUnobserved([fixture.location]))
        XCTAssertEqual(
            reducer.snapshot.resolutions.first?.state,
            .pending(.awaitingRuntimeInventory)
        )
    }

    func testTerminalClearsVisibleBackendIdentityAcrossEpochBoundary() throws {
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        var reducer = DebuggerBreakpointBindingReducer(sessionEpoch: fixture.epoch)
        try establishResolution(&reducer, fixture: fixture)
        _ = reducer.admit(fixture.plan)
        _ = reducer.complete(fixture.receipt)

        XCTAssertTrue(reducer.terminal(sessionEpoch: fixture.epoch))
        XCTAssertEqual(reducer.snapshot.backendState, .unbound)
        XCTAssertTrue(reducer.snapshot.ownedLocations.isEmpty)
        XCTAssertEqual(reducer.snapshot.resolutions.first?.state, .pending(.noSession))
        let after = reducer.snapshot
        XCTAssertFalse(reducer.observeResolution(fixture.observation))
        XCTAssertEqual(reducer.snapshot, after)
    }

    func testDigestAndBindingConstructorsRejectMalformedEvidence() throws {
        XCTAssertNil(DebuggerBreakpointDigest(Data(repeating: 0, count: 31)))
        XCTAssertNil(DebuggerBreakpointDigest(Data(repeating: 0, count: 33)))
        let fixture = try makeFixture(catalogRevision: 1, specificationRevision: 1)
        XCTAssertNil(DebuggerOwnedBackendBreakpointLocation(
            bindingID: fixture.binding.id,
            backendBreakpointID: 0,
            backendLocationID: 1,
            runtimeAddress: fixture.binding.runtimeAddress,
            ownershipTagDigest: digest(7),
            policyActionDigest: fixture.binding.policyActionDigest,
            issuanceDigest: fixture.binding.issuanceDigest
        ))
    }

    private struct Fixture {
        let epoch: DebuggerSessionEpoch
        let stop: DebuggerStopCoordinate
        let catalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
        let resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate
        let mappingKey: DebuggerRuntimeMappingProjectionKey
        let binding: DebuggerDesiredBreakpointBinding
        let resolution: DebuggerLogicalBreakpointResolution
        let observation: DebuggerBreakpointResolutionObservation
        let plan: DebuggerBreakpointBindingPlan
        let location: DebuggerOwnedBackendBreakpointLocation
        let receipt: DebuggerBreakpointBindingReceipt
    }

    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let logicalID = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    )
    private let binaryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func establishResolution(
        _ reducer: inout DebuggerBreakpointBindingReducer,
        fixture: Fixture
    ) throws {
        XCTAssertTrue(reducer.beganNewStop(
            fixture.stop,
            adapterGeneration: fixture.plan.adapterGeneration,
            observedPID: fixture.plan.observedPID,
            observedStopID: fixture.plan.observedStopID
        ))
        XCTAssertTrue(reducer.observeResolution(fixture.observation))
    }

    private func makeFixture(
        epoch: DebuggerSessionEpoch = .init(
            rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        ),
        stop: DebuggerStopCoordinate? = nil,
        catalogRevision: UInt64,
        specificationRevision: UInt64,
        resolutionRevision: UInt64 = 8,
        mappingAuthorityRevision: UInt64 = 5,
        transactionUUID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    ) throws -> Fixture {
        let stop = stop ?? makeStop(epoch: epoch, stopRevision: 3)
        let specificationRevision = try DebuggerLogicalBreakpointRevision(
            validating: specificationRevision
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: .primary,
            artifactIdentity: try MachOSliceArtifactIdentity(
                uuid: binaryID,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "a", count: 64),
                selectedSliceByteCount: 0x10_000
            ),
            ownerRevision: .init(rawValue: 2)
        )
        let owner = DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: binaryID,
            artifactIdentity: coordinate.artifactIdentity
        )
        let imageAddress = ImageAddress.primary(0x1010)
        let siteID = DebuggerLogicalBreakpointSiteID(
            logicalID: logicalID,
            specificationRevision: specificationRevision,
            imageAddress: imageAddress,
            staticOrdinal: 0
        )
        let site = try XCTUnwrap(DebuggerResolvedLogicalBreakpointSite(
            logicalID: logicalID,
            specificationRevision: specificationRevision,
            siteID: siteID,
            owner: owner,
            coordinate: coordinate,
            imageAddress: imageAddress,
            provenance: .preferredAddress
        ))
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: 77,
            authorityRevision: .init(rawValue: mappingAuthorityRevision),
            inventoryRevision: .init(rawValue: 6),
            workspaceCatalogRevision: .init(rawValue: 7)
        )
        let moduleID = DebuggerRuntimeModuleInstanceID(
            processID: 77,
            stop: stop,
            inventoryRevision: mappingKey.inventoryRevision,
            ordinal: 0
        )
        let bindingID = try XCTUnwrap(DebuggerTransientBreakpointBindingID(
            logicalID: logicalID,
            siteID: siteID,
            moduleInstanceID: moduleID
        ))
        let binding = try XCTUnwrap(DebuggerDesiredBreakpointBinding(
            id: bindingID,
            site: site,
            mappingKey: mappingKey,
            runtimeAddress: 0x9010,
            policyActionDigest: digest(9),
            issuanceDigest: digest(10)
        ))
        let resolution = DebuggerLogicalBreakpointResolution(
            logicalID: logicalID,
            specificationRevision: specificationRevision,
            state: .resolved(site: site, binding: binding)
        )
        let catalogCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: catalogRevision
        )
        let resolutionCatalogCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: resolutionRevision),
            workspaceArtifactCatalogRevision: mappingKey.workspaceCatalogRevision
        )
        let observation = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: catalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            mappingKey: mappingKey,
            expectedSpecifications: [
                .init(logicalID: logicalID, specificationRevision: specificationRevision)
            ],
            results: [resolution]
        ))
        let plan = try XCTUnwrap(DebuggerBreakpointBindingPlan(
            transactionID: .init(rawValue: transactionUUID),
            sessionEpoch: epoch,
            adapterGeneration: 4,
            stopCoordinate: stop,
            observedPID: 77,
            observedStopID: 12,
            logicalCatalogCoordinate: catalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            resolutionObservationDigest: observation.canonicalDigest,
            mappingKey: mappingKey,
            bindings: [binding],
            ownershipTagDigest: digest(7),
            canonicalPlanDigest: digest(8)
        ))
        let location = try XCTUnwrap(DebuggerOwnedBackendBreakpointLocation(
            bindingID: bindingID,
            backendBreakpointID: 101,
            backendLocationID: 201,
            runtimeAddress: binding.runtimeAddress,
            ownershipTagDigest: digest(7),
            policyActionDigest: binding.policyActionDigest,
            issuanceDigest: binding.issuanceDigest
        ))
        let receipt = try XCTUnwrap(DebuggerBreakpointBindingReceipt(
            transactionID: plan.transactionID,
            sessionEpoch: epoch,
            adapterGeneration: plan.adapterGeneration,
            stopCoordinate: stop,
            observedPID: plan.observedPID,
            observedStopID: plan.observedStopID,
            canonicalPlanDigest: plan.canonicalPlanDigest,
            didWriteBackend: true,
            completeOwnedInventory: [location]
        ))
        return Fixture(
            epoch: epoch,
            stop: stop,
            catalogCoordinate: catalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            mappingKey: mappingKey,
            binding: binding,
            resolution: resolution,
            observation: observation,
            plan: plan,
            location: location,
            receipt: receipt
        )
    }

    private func makeCallback(
        fixture: Fixture,
        sequence: UInt64,
        hitCount: UInt64,
        outcome: DebuggerBreakpointCallbackOutcome = .stopped
    ) throws -> DebuggerBreakpointCallbackRecord {
        try XCTUnwrap(DebuggerBreakpointCallbackRecord(
            sessionEpoch: fixture.epoch,
            adapterGeneration: fixture.plan.adapterGeneration,
            processID: fixture.plan.observedPID,
            sequence: sequence,
            logicalID: logicalID,
            specificationRevision: fixture.binding.site.specificationRevision,
            bindingID: fixture.binding.id,
            backendBreakpointID: fixture.location.backendBreakpointID,
            backendLocationID: fixture.location.backendLocationID,
            issuanceDigest: fixture.binding.issuanceDigest,
            observedLogicalHitCount: hitCount,
            outcome: outcome
        ))
    }

    private func makeSessionReducerWithBreakpointStop(
        epoch: DebuggerSessionEpoch
    ) -> DebuggerSessionReducer {
        var reducer = DebuggerSessionReducer(
            epoch: epoch,
            capabilities: .persistentCLI(attachPolicyReason: "test")
        )
        let launch = sessionRequest(
            sequence: 1,
            operation: .launch,
            session: reducer.state.sessionCoordinate
        )
        guard case .accepted = reducer.admit(launch) else {
            XCTFail("launch admission failed"); return reducer
        }
        XCTAssertEqual(reducer.reduce(sessionEvent(1, launch, .requestStarted)), .accepted)
        XCTAssertEqual(reducer.reduce(sessionEvent(
            2,
            launch,
            .processStopped(observedPID: 77, reason: .unknown("entry"))
        )), .accepted)
        XCTAssertEqual(reducer.reduce(sessionEvent(
            3,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 77)))
        )), .accepted)
        let refresh = sessionRequest(
            sequence: 2,
            operation: .refreshRuntimeModules,
            session: reducer.state.sessionCoordinate,
            stop: reducer.state.stopCoordinate
        )
        guard case .accepted = reducer.admit(refresh) else {
            XCTFail("refresh admission failed"); return reducer
        }
        XCTAssertEqual(reducer.reduce(sessionEvent(4, refresh, .requestStarted)), .accepted)
        XCTAssertEqual(reducer.reduce(sessionEvent(
            5,
            refresh,
            .runtimeModulesRefreshed(.init(
                observations: [],
                observedStopID: 12,
                processID: 77,
                adapterGeneration: 4
            ))
        )), .accepted)
        XCTAssertEqual(reducer.reduce(sessionEvent(
            6,
            refresh,
            .requestCompleted(.completed(target: .stopped(processID: 77)))
        )), .accepted)
        return reducer
    }

    private func sessionRequest(
        sequence: UInt64,
        operation: DebuggerOperation,
        session: DebuggerSessionCoordinate,
        stop: DebuggerStopCoordinate? = nil
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: .init(epoch: session.epoch, sequence: sequence),
            operation: operation,
            expectedSession: session,
            requiredStop: stop
        )
    }

    private func sessionEvent(
        _ sequence: UInt64,
        _ context: DebuggerRequestContext,
        _ payload: DebuggerEventPayload
    ) -> DebuggerEventEnvelope {
        DebuggerEventEnvelope(
            sessionEpoch: context.id.epoch,
            eventSequence: .init(rawValue: sequence),
            requestID: context.id,
            operation: context.operation,
            capturedLifecycleRevision: context.expectedSession.lifecycleRevision,
            boundStopRevision: context.requiredStop?.stopRevision,
            payload: payload
        )
    }

    private func digest(_ byte: UInt8) -> DebuggerBreakpointDigest {
        DebuggerBreakpointDigest(Data(repeating: byte, count: 32))!
    }

    private func makeStop(
        epoch: DebuggerSessionEpoch,
        stopRevision: UInt64
    ) -> DebuggerStopCoordinate {
        DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .init(rawValue: 2)
            ),
            stopRevision: .init(rawValue: stopRevision)
        )
    }
}

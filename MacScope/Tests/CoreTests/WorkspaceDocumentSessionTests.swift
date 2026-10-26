import AppKit
import Combine
import Foundation
import Synchronization
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceDocumentSessionTests: XCTestCase {
    func testWriteFailureClassificationExcludesAssociatedPrivateContent() {
        let privateValue = "/private/workspace/secret-content"
        XCTAssertEqual(
            WorkspaceDocumentSession.classifiedWriteError(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: privateValue)),
                phase: "capture"),
            .operationFailed("document-write-capture-decode-data-corrupted"))
        XCTAssertEqual(
            WorkspaceDocumentSession.classifiedWriteError(
                MacScopeDocumentPackage.PackageError.missingAttachment(privateValue), phase: "stage"),
            .operationFailed("document-write-stage-package-missingAttachment"))
        XCTAssertEqual(
            WorkspaceDocumentSession.classifiedWriteError(
                NSError(domain: NSCocoaErrorDomain, code: 513,
                        userInfo: [NSLocalizedDescriptionKey: privateValue]), phase: "publish"),
            .operationFailed("document-write-publish-cocoa-513"))
    }

    func testExplicitSaveRepublishesCleanDocumentInsteadOfReturningAutosaveNoOp() async throws {
        let harness = try makeHarness()
        XCTAssertFalse(harness.source.hasUnsavedChanges)
        let autosave = await harness.session.autosaveIfNeeded()
        XCTAssertNil(autosave)
        let before = harness.session.snapshot.expectedExternalVersion
        let replacement = WorkspaceFileObjectIdentity(device: 81, inode: 82)
        await harness.publisher.replaceRootIdentityOnNextPublish(with: replacement)

        let outcome = await harness.session.save()

        XCTAssertEqual(outcome, .saved(clean: true, adopted: nil))
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertEqual(harness.session.snapshot.nextSaveGeneration, .init(rawValue: 1))
        XCTAssertEqual(harness.session.snapshot.location?.fileObjectIdentity, replacement)
        XCTAssertNotEqual(harness.session.snapshot.expectedExternalVersion, before)
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 1)
    }

    func testOrdinarySaveUsesOneTransactionAndAcceptsExactCapturedGeneration() async throws {
        let harness = try makeHarness()
        harness.source.resetRecords()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)

        let outcome = await harness.session.save()

        XCTAssertEqual(outcome, .saved(clean: true, adopted: nil))
        XCTAssertFalse(harness.source.hasUnsavedChanges)
        XCTAssertEqual(harness.source.acceptedGenerations, [.init(rawValue: 1)])
        XCTAssertNil(harness.session.snapshot.activeSave)
        XCTAssertEqual(harness.session.snapshot.nextSaveGeneration, .init(rawValue: 1))
        let lastPublishedObservation = await harness.publisher.lastPublishedObservation
        XCTAssertEqual(
            harness.session.snapshot.expectedExternalVersion,
            lastPublishedObservation
        )
    }

    func testOrdinarySaveRefreshesPublishedFileIdentityAndReservationBeforeNextSave() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let replacementIdentity = WorkspaceFileObjectIdentity(device: 41, inode: 42)
        await harness.publisher.replaceRootIdentityOnNextPublish(with: replacementIdentity)

        let firstOutcome = await harness.session.save()
        let observedFirstPublication = await harness.publisher.lastPublishedObservation
        let firstPublishedObservation = try XCTUnwrap(observedFirstPublication)

        XCTAssertEqual(firstOutcome, .saved(clean: true, adopted: nil))
        XCTAssertEqual(
            harness.session.snapshot.location,
            firstPublishedObservation.location
        )
        XCTAssertEqual(
            harness.session.snapshot.expectedExternalVersion,
            firstPublishedObservation
        )
        let aliasLocation = WorkspaceDocumentLocation(
            canonicalURL: URL(fileURLWithPath: "/tmp/WorkspaceDocumentSessionTests/Published-Alias.mscope"),
            fileObjectIdentity: replacementIdentity
        )
        XCTAssertEqual(harness.reservations.owner(of: aliasLocation), harness.windowID)

        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)

        let secondOutcome = await harness.session.save()

        XCTAssertEqual(secondOutcome, .saved(clean: true, adopted: nil))
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 2)
        let secondExpectedObservation = await harness.publisher.lastExpectedObservation
        XCTAssertEqual(secondExpectedObservation, firstPublishedObservation)
    }

    func testOrdinarySaveHoldsPublicationAdmissionUntilPublishedIdentityIsReserved() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        await harness.publisher.pauseNextPublish()

        let save = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()

        XCTAssertEqual(harness.reservations.activePublicationCount, 1)
        await harness.publisher.releasePublish()
        let outcome = await save.value

        XCTAssertEqual(outcome, .saved(clean: true, adopted: nil))
        XCTAssertEqual(harness.reservations.activePublicationCount, 0)
        XCTAssertEqual(harness.reservations.completedPublicationCount, 1)
    }

    func testPublicationOwnershipConflictNeverAcceptsPublishedWrite() async throws {
        let harness = try makeHarness()
        harness.source.resetRecords()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        harness.reservations.forceNextPublicationCompletion(
            .alreadyOwned(.fresh())
        )

        let outcome = await harness.session.save()

        XCTAssertEqual(
            outcome,
            .failed("document-location-owned-by-another-window")
        )
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertTrue(harness.source.acceptedGenerations.isEmpty)
        XCTAssertEqual(harness.reservations.activePublicationCount, 0)
    }

    func testCloseAfterStageCompletionDiscardsOwnedStageBeforePublication() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        await harness.publisher.pauseNextStage()

        let save = Task { await harness.session.save() }
        await harness.publisher.waitUntilStageStarted()
        harness.session.close()
        await harness.publisher.releaseStage()

        let outcome = await save.value
        let discardCount = await harness.publisher.discardCount
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(discardCount, 1)
        XCTAssertEqual(publishCount, 0)
    }

    func testMutationDuringSaveRemainsDirtyAndCoalescesIntoLaterAutosave() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.resetRecords()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        await harness.publisher.pauseNextPublish()

        let firstSave = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        await harness.publisher.releasePublish()

        let firstOutcome = await firstSave.value
        XCTAssertEqual(firstOutcome, .saved(clean: false, adopted: nil))
        XCTAssertTrue(harness.session.snapshot.hasUnsavedChanges)

        let autosave = await harness.session.autosaveIfNeeded()
        XCTAssertEqual(autosave, .saved(clean: true, adopted: nil))
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 2)
    }

    func testAutosaveTimerFiringDuringSaveCoalescesLatestMutationAfterSuccess() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let (store, trigger) = makeAutosaveStore(for: harness.session)
        harness.source.resetRecords()
        harness.source.mutate()
        store.markDocumentMutated()
        await harness.publisher.pauseNextPublish()

        let firstSave = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        for _ in 0..<2 {
            harness.source.mutate()
            store.markDocumentMutated()
            let overlappingAutosave = try await fireAutosave(trigger, through: store)
            XCTAssertNil(overlappingAutosave)
        }
        XCTAssertFalse(trigger.isPending)
        let stageCountWhilePaused = await harness.publisher.stageCount
        XCTAssertEqual(stageCountWhilePaused, 1)
        XCTAssertEqual(
            harness.session.snapshot.activeSave?.capturedMutationGeneration,
            .init(rawValue: 1)
        )
        await harness.publisher.releasePublish()

        let firstOutcome = await firstSave.value
        XCTAssertEqual(firstOutcome, .saved(clean: false, adopted: nil))

        // No new mutation, timer fire, or direct autosave call may be needed after A finishes.
        await waitUntilSaved(.init(rawValue: 3), by: harness.session)
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertFalse(trigger.isPending)
        XCTAssertEqual(
            harness.source.acceptedGenerations,
            [.init(rawValue: 1), .init(rawValue: 3)]
        )
        let capturedGenerations = await harness.publisher.capturedGenerations
        XCTAssertEqual(capturedGenerations, [.init(rawValue: 1), .init(rawValue: 3)])
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 2)
    }

    func testPendingAutosaveDoesNotRetryFailedPublication() async throws {
        try await assertPendingAutosaveIsDroppedAfterFailedWrite(changedOnDisk: false)
    }

    func testPendingAutosaveDoesNotRetryAuthoritativeConflict() async throws {
        try await assertPendingAutosaveIsDroppedAfterFailedWrite(changedOnDisk: true)
    }

    func testAutosaveTimerDuringFirstSaveAsUsesAdoptedLocationAfterSuccess() async throws {
        let harness = try makeHarness(opened: false)
        defer { harness.session.close() }
        let (store, trigger) = makeAutosaveStore(for: harness.session)
        harness.source.mutate()
        store.markDocumentMutated()
        let destination = location("First-Save-As.mscope")
        await harness.probe.set(
            externalVersion(at: destination, condition: .absent, seed: "absent")
        )
        await harness.publisher.pauseNextPublish()

        let firstSave = Task { await harness.session.saveAs(to: destination.canonicalURL) }
        await harness.publisher.waitUntilPublishStarted()
        XCTAssertNil(harness.session.snapshot.location)
        harness.source.mutate()
        store.markDocumentMutated()
        let overlappingAutosave = try await fireAutosave(trigger, through: store)
        XCTAssertNil(overlappingAutosave)
        let stageCountWhilePaused = await harness.publisher.stageCount
        XCTAssertEqual(stageCountWhilePaused, 1)
        await harness.publisher.releasePublish()

        let firstOutcome = await firstSave.value
        guard case .saved(clean: false, let adopted) = firstOutcome else {
            return XCTFail("Expected a dirty Save As success, got \(firstOutcome)")
        }
        XCTAssertEqual(adopted?.canonicalURL, destination.canonicalURL)
        await waitUntilSaved(.init(rawValue: 2), by: harness.session)
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertEqual(harness.session.snapshot.location?.canonicalURL, destination.canonicalURL)
        XCTAssertEqual(
            harness.source.acceptedGenerations,
            [.init(rawValue: 1), .init(rawValue: 2)]
        )
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 2)
    }

    func testConcurrentWriteIsRejectedAndCloseSupersedesLateCompletion() async throws {
        let harness = try makeHarness()
        let (store, trigger) = makeAutosaveStore(for: harness.session)
        harness.source.mutate()
        store.markDocumentMutated()
        await harness.publisher.pauseNextPublish()
        let firstSave = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()

        let concurrentOutcome = await harness.session.save()
        XCTAssertEqual(concurrentOutcome, .failed("document-write-already-active"))
        harness.source.mutate()
        store.markDocumentMutated()
        let overlappingAutosave = try await fireAutosave(trigger, through: store)
        XCTAssertNil(overlappingAutosave)

        harness.session.close()
        await harness.publisher.releasePublish()

        let firstOutcome = await firstSave.value
        await yieldForAutosaveDrain()
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertNil(harness.session.snapshot.activeSave)
        XCTAssertEqual(harness.reservations.releaseAllCount, 1)
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 1)
    }

    /// RED anchor for process termination: this is intentionally different from `close()`. A
    /// dirty document that already has a validated, reserved location must use the production
    /// atomic write path before its session is made terminal.
    func testTerminationPersistsDirtyOpenedDocumentBeforeClose() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)

        let outcome = await harness.session.quiesceAndSaveForTermination()

        XCTAssertEqual(outcome, .ready)
        XCTAssertFalse(harness.source.hasUnsavedChanges)
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 1)
        XCTAssertNil(harness.session.snapshot.activeSave)
    }

    /// RED anchor for the original Quit data-loss defect. The first, already-admitted atomic
    /// publication must be allowed to complete. If a later mutation lands while it is paused,
    /// termination must issue one more normal save instead of calling `close()` and cancelling
    /// the original request.
    func testTerminationDrainsActiveSaveThenPersistsMutationThatLandedDuringIt() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let (store, trigger) = makeAutosaveStore(for: harness.session)
        harness.source.mutate()
        store.markDocumentMutated()
        await harness.publisher.pauseNextPublish()

        let firstSave = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        harness.source.mutate()
        store.markDocumentMutated()
        let overlappingAutosave = try await fireAutosave(trigger, through: store)
        XCTAssertNil(overlappingAutosave)

        let termination = Task {
            await harness.session.quiesceAndSaveForTermination()
        }
        await waitUntilTerminationPreparationStarts(harness.session)
        XCTAssertTrue(harness.session.isTerminationPreparationActive)
        let saveWhileTerminating = await harness.session.save()
        XCTAssertEqual(
            saveWhileTerminating,
            .failed("document-termination-in-progress")
        )
        let publishCountWhileFenced = await harness.publisher.publishCount
        XCTAssertEqual(publishCountWhileFenced, 1)
        await harness.publisher.releasePublish()

        let firstOutcome = await firstSave.value
        let terminationOutcome = await termination.value

        XCTAssertEqual(firstOutcome, .saved(clean: false, adopted: nil))
        XCTAssertEqual(terminationOutcome, .ready)
        XCTAssertFalse(harness.source.hasUnsavedChanges)
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertEqual(
            harness.source.acceptedGenerations,
            [.init(rawValue: 1), .init(rawValue: 2)]
        )
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 2)
        XCTAssertNil(harness.session.snapshot.activeSave)
    }

    func testCancelledTerminationPreparationDoesNotRevivePendingAutosave() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let (store, trigger) = makeAutosaveStore(for: harness.session)
        harness.source.mutate()
        store.markDocumentMutated()
        await harness.publisher.pauseNextPublish()
        let firstSave = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        harness.source.mutate()
        store.markDocumentMutated()
        let overlappingAutosave = try await fireAutosave(trigger, through: store)
        XCTAssertNil(overlappingAutosave)

        XCTAssertTrue(harness.session.beginTerminationPreparation())
        harness.session.cancelTerminationPreparation()
        XCTAssertFalse(harness.session.isTerminationPreparationActive)
        // The publisher intentionally ignores cancellation after physical publication starts.
        // Its late success must not revive demand revoked by the cancelled Quit attempt.
        await harness.publisher.releasePublish()
        let firstOutcome = await firstSave.value
        XCTAssertEqual(firstOutcome, .saved(clean: false, adopted: nil))
        await yieldForAutosaveDrain()

        XCTAssertFalse(harness.session.isTerminationPreparationActive)
        XCTAssertTrue(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertFalse(trigger.isPending)
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(harness.source.acceptedGenerations, [.init(rawValue: 1)])
    }

    /// Fail-closed termination anchor: an external-version conflict cannot be made writable by
    /// quitting. The caller must receive a refusal, retain the dirty session, and be able to
    /// continue with the existing conflict-resolution command after AppKit cancels termination.
    func testTerminationRefusesUnresolvedConflictWithoutClosingDirtySession() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let external = externalVersion(at: harness.currentLocation, seed: "external")
        await harness.publisher.failNextPublish("document-publish-destination-changed")
        await harness.probe.enqueue(external)
        guard case .conflicted = await harness.session.save() else {
            return XCTFail("Expected a conflict before termination")
        }

        let outcome = await harness.session.quiesceAndSaveForTermination()

        XCTAssertEqual(outcome, .refused(.failed("document-conflict-unresolved")))
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertTrue(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertNotNil(harness.session.snapshot.conflict)

        harness.session.cancelTerminationPreparation()
        let retry = await harness.session.keepLocalVersion()
        XCTAssertEqual(retry, .saved(clean: true, adopted: nil))
        XCTAssertFalse(harness.source.hasUnsavedChanges)
    }

    func testQuitDirtyUntitledAdoptsSaveAsBeforeRemoval() async throws {
        let harness = try makeHarness(opened: false)
        defer { harness.session.close() }
        harness.source.mutate()
        let destination = location("Quit-Save-As.mscope")
        await harness.probe.set(externalVersion(at: destination, condition: .absent, seed: "absent"))
        let outcome = await harness.session.quiesceAndSaveForTermination(
            choose: { _ in .saveAs }, chooseSaveDestination: { destination.canonicalURL }
        )
        XCTAssertEqual(outcome, .ready)
        XCTAssertTrue(harness.session.isReadyForTerminationRemoval())
        XCTAssertEqual(harness.source.adoptedLocations, [destination.canonicalURL])
        XCTAssertFalse(harness.source.hasUnsavedChanges)
    }

    func testQuitCancelledSaveAsRetainsUntitledContentAndCanRetry() async throws {
        let harness = try makeHarness(opened: false)
        defer { harness.session.close() }
        harness.source.mutate()
        let outcome = await harness.session.quiesceAndSaveForTermination(choose: { _ in .saveAs })
        XCTAssertEqual(outcome, .refused(.failed("document-termination-cancelled")))
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertNil(harness.session.snapshot.location)
        harness.session.cancelTerminationPreparation()
        XCTAssertFalse(harness.session.isTerminationPreparationActive)
        let destination = location("Quit-Retry.mscope")
        await harness.probe.set(externalVersion(at: destination, condition: .absent, seed: "absent"))
        let retry = await harness.session.saveAs(to: destination.canonicalURL)
        XCTAssertEqual(retry, .saved(clean: true, adopted: destination))
    }

    func testQuitDontSaveDiscardsUntitledContentWithoutWriting() async throws {
        let harness = try makeHarness(opened: false)
        defer { harness.session.close() }
        harness.source.mutate()
        let publications = await harness.publisher.publishCount
        var destinationAsked = false
        let outcome = await harness.session.quiesceAndSaveForTermination(
            choose: { _ in .discard },
            chooseSaveDestination: { destinationAsked = true; return nil }
        )
        XCTAssertEqual(outcome, .ready)
        XCTAssertFalse(destinationAsked)
        XCTAssertTrue(harness.session.isReadyForTerminationRemoval())
        let afterDiscard = await harness.publisher.publishCount
        XCTAssertEqual(afterDiscard, publications)
        XCTAssertTrue(harness.source.adoptedLocations.isEmpty)
    }

    func testQuitDontSaveApprovalNeverCoversLaterEditOrRollback() async throws {
        let harness = try makeHarness(opened: false)
        defer { harness.session.close() }
        harness.source.mutate()
        let outcome = await harness.session.quiesceAndSaveForTermination(choose: { _ in .discard })
        XCTAssertEqual(outcome, .ready)
        harness.source.mutate()
        XCTAssertFalse(harness.session.isReadyForTerminationRemoval())
        harness.session.cancelTerminationPreparation()
        XCTAssertFalse(harness.session.isTerminationPreparationActive)
    }

    func testQuitDontSaveIsRefusedForConflictedDocument() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        await harness.publisher.failNextPublish("document-publish-destination-changed")
        await harness.probe.enqueue(externalVersion(at: harness.currentLocation, seed: "external"))
        guard case .conflicted = await harness.session.save() else { return XCTFail("Expected conflict") }
        let outcome = await harness.session.quiesceAndSaveForTermination(choose: { _ in .discard })
        XCTAssertEqual(outcome, .refused(.failed("document-termination-discard-refused")))
        XCTAssertTrue(harness.source.hasUnsavedChanges)
    }

    func testQuitConflictKeepLocalRequiresExplicitChoiceAndObservedVersion() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        await harness.publisher.failNextPublish("document-publish-destination-changed")
        await harness.probe.enqueue(externalVersion(at: harness.currentLocation, seed: "external"))
        guard case .conflicted = await harness.session.save() else { return XCTFail("Expected conflict") }
        var choices = 0
        let outcome = await harness.session.quiesceAndSaveForTermination(choose: { snapshot in
            XCTAssertNotNil(snapshot.conflict)
            choices += 1
            return .keepLocalVersion
        })
        XCTAssertEqual(choices, 1)
        XCTAssertEqual(outcome, .ready)
        XCTAssertTrue(harness.session.isReadyForTerminationRemoval())
        XCTAssertFalse(harness.source.hasUnsavedChanges)
    }

    func testClosedStoreCancelsAutosaveAndCannotFallBackToLegacyWriter() async throws {
        let trigger = ManualAutosaveTrigger()
        let store = WorkspaceStore(
            workspaceName: "Closed", snapshot: WorkspaceSnapshot(
                binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
            ),
            engine: AnalysisEngine(), autosaveScheduler: trigger
        )
        let reservations = SessionTestReservations()
        let session = WorkspaceDocumentSession(
            sessionID: .init(rawValue: UUID()), windowID: .fresh(), source: store,
            io: WorkspaceDocumentIO(), reservations: reservations
        )
        trigger.scheduleAutosave()
        session.close()
        XCTAssertFalse(trigger.isPending)
        XCTAssertNil(trigger.onFire)
        XCTAssertNil(store.performAutosaveIfNeeded())
        XCTAssertFalse(store.writeDocumentPackage(to: location("Closed-No-Write.mscope").canonicalURL))
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        XCTAssertThrowsError(try store.saveWorkspace(to: database))
    }

    func testQuitConflictDecisionCannotApproveLaterContent() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        await harness.publisher.failNextPublish("document-publish-destination-changed")
        await harness.probe.enqueue(externalVersion(at: harness.currentLocation, seed: "external"))
        guard case .conflicted = await harness.session.save() else { return XCTFail("Expected conflict") }
        let publications = await harness.publisher.publishCount
        let outcome = await harness.session.quiesceAndSaveForTermination(choose: { _ in
            harness.source.mutate()
            return .keepLocalVersion
        })
        XCTAssertEqual(outcome, .refused(.failed("document-termination-content-changed")))
        let afterDecision = await harness.publisher.publishCount
        XCTAssertEqual(afterDecision, publications)
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertNotNil(harness.session.snapshot.conflict)
    }

    func testAutosaveAdmissionRequiresLocationDirtyStateAndNoConflictOrActiveWrite() async throws {
        let untitled = try makeHarness(opened: false)
        untitled.source.mutate()
        untitled.session.noteMutation(untitled.source.mutationGeneration)
        let untitledAutosave = await untitled.session.autosaveIfNeeded()
        XCTAssertNil(untitledAutosave)

        let clean = try makeHarness()
        let cleanAutosave = await clean.session.autosaveIfNeeded()
        XCTAssertNil(cleanAutosave)

        let active = try makeHarness()
        active.source.mutate()
        active.session.noteMutation(active.source.mutationGeneration)
        await active.publisher.pauseNextPublish()
        let save = Task { await active.session.save() }
        await active.publisher.waitUntilPublishStarted()
        let activeAutosave = await active.session.autosaveIfNeeded()
        XCTAssertNil(activeAutosave)
        await active.publisher.releasePublish()
        _ = await save.value

        let conflicted = try makeHarness()
        conflicted.source.mutate()
        conflicted.session.noteMutation(conflicted.source.mutationGeneration)
        await conflicted.publisher.failNextPublish("synthetic-publish-failure")
        await conflicted.probe.enqueue(
            externalVersion(at: conflicted.currentLocation, seed: "external")
        )
        guard case .conflicted = await conflicted.session.save() else {
            return XCTFail("Expected an authoritative conflict")
        }
        let conflictedAutosave = await conflicted.session.autosaveIfNeeded()
        XCTAssertNil(conflictedAutosave)
    }

    func testSaveAsAdoptsDestinationAndReleasesPriorReservationOnlyAfterSuccess() async throws {
        let harness = try makeHarness()
        harness.source.resetRecords()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let destination = location("Save-As.mscope")
        await harness.probe.set(
            externalVersion(at: destination, condition: .absent, seed: "absent")
        )

        let outcome = await harness.session.saveAs(to: destination.canonicalURL)

        guard case .saved(let clean, let adopted) = outcome else {
            return XCTFail("Expected Save As success, got \(outcome)")
        }
        XCTAssertTrue(clean)
        XCTAssertEqual(adopted?.canonicalURL, destination.canonicalURL)
        XCTAssertEqual(
            harness.session.snapshot.location?.canonicalURL,
            destination.canonicalURL
        )
        XCTAssertEqual(harness.source.adoptedLocations, [destination.canonicalURL])
        XCTAssertTrue(harness.reservations.releasedLocations.contains(harness.currentLocation))
        XCTAssertTrue(harness.reservations.isReserved(destination, by: harness.sessionID))
    }

    // BUG01: alternate destination failures are operation-scoped, including a genuine
    // pre-existing conflict. These fresh cases use the retained controllable IO seams.
    func testAlternateDestinationFailuresPreserveActiveStateAndSaveAdmission() async throws {
        for copy in [false, true] {
            for publicationFailure in [false, true] {
                for genuineConflict in [false, true] {
                    let harness = try makeHarness()
                    defer { harness.session.close() }
                    harness.source.mutate()
                    harness.session.noteMutation(harness.source.mutationGeneration)
                    if genuineConflict {
                        await harness.publisher.failNextPublish("synthetic-active-failure")
                        await harness.probe.enqueue(externalVersion(at: harness.currentLocation, seed: "active-changed"))
                        guard case .conflicted = await harness.session.save() else {
                            return XCTFail("Expected genuine active conflict")
                        }
                    }
                    let before = harness.session.snapshot
                    let destination = location("Alternate-\(copy)-\(publicationFailure)-\(genuineConflict).mscope")
                    let expected = externalVersion(at: destination, condition: .absent, seed: "alternate-before")
                    await harness.probe.set(expected)
                    if publicationFailure {
                        await harness.probe.enqueue(expected)
                        await harness.probe.enqueue(externalVersion(at: destination, seed: "alternate-changed"))
                        await harness.publisher.failNextPublish("synthetic-alternate-failure")
                    } else {
                        harness.reservations.forceOwner(.fresh(), for: destination)
                    }
                    let outcome: WorkspaceDocumentWriteOutcome
                    if copy { outcome = await harness.session.saveCopy(to: destination.canonicalURL) }
                    else { outcome = await harness.session.saveAs(to: destination.canonicalURL) }
                    guard case .destinationConflicted(let intent, let failure) = outcome else {
                        return XCTFail("Expected operation-scoped destination conflict, got \(outcome)")
                    }
                    XCTAssertEqual(intent, copy ? .saveCopy(to: destination) : .saveAs(adopting: destination))
                    XCTAssertEqual(failure.observed.location.canonicalURL, destination.canonicalURL)
                    let after = harness.session.snapshot
                    XCTAssertEqual(after.location, before.location)
                    XCTAssertEqual(after.expectedExternalVersion, before.expectedExternalVersion)
                    XCTAssertEqual(after.savedMutationGeneration, before.savedMutationGeneration)
                    XCTAssertEqual(after.mutationGeneration, before.mutationGeneration)
                    XCTAssertEqual(after.hasUnsavedChanges, before.hasUnsavedChanges)
                    XCTAssertEqual(after.conflict, before.conflict)
                    XCTAssertTrue(harness.source.acceptedGenerations.isEmpty)
                    XCTAssertTrue(harness.reservations.isReserved(harness.currentLocation, by: harness.sessionID))
                    if genuineConflict {
                        let refused = await harness.session.save()
                        XCTAssertEqual(refused, .failed("document-conflict-unresolved"))
                    } else {
                        // Separate branches prove explicit Save and eligible autosave admission.
                        let recovery: WorkspaceDocumentWriteOutcome?
                        if publicationFailure { recovery = await harness.session.autosaveIfNeeded() }
                        else { recovery = await harness.session.save() }
                        XCTAssertEqual(recovery, .saved(clean: true, adopted: nil))
                    }
                }
            }
        }
    }

    func testAlternateOwnershipObservationCannotPublishAfterCloseOrRebind() async throws {
        for copy in [false, true] {
            for rebind in [false, true] {
                let harness = try makeHarness()
                defer { harness.session.close() }
                let destination = location("Owned-delayed.mscope")
                harness.reservations.forceOwner(.fresh(), for: destination)
                await harness.probe.set(externalVersion(at: destination, seed: "owned"))
                await harness.probe.pauseNextObservation()
                let write = Task {
                    if copy { return await harness.session.saveCopy(to: destination.canonicalURL) }
                    return await harness.session.saveAs(to: destination.canonicalURL)
                }
                await harness.probe.waitForObservationCount(1)
                if rebind {
                    let replacement = location("Replacement.mscope")
                    let observation = externalVersion(at: replacement, seed: "replacement")
                    try harness.session.bindOpenedPackage(validatedPackage(at: replacement, observation: observation), at: replacement)
                } else {
                    harness.session.close()
                }
                let retired = harness.session.snapshot
                var publications = 0
                let subscription = harness.session.$snapshot.dropFirst().sink { _ in publications += 1 }
                await harness.probe.releaseObservation() // Probe intentionally ignores cancellation.
                let outcome = await write.value
                XCTAssertEqual(outcome, .superseded)
                XCTAssertEqual(harness.session.snapshot, retired)
                XCTAssertEqual(publications, 0)
                withExtendedLifetime(subscription) {}
                let stages = await harness.publisher.stageCount
                XCTAssertEqual(stages, 0)
            }
        }
    }

    func testAlternateFailedPublicationObservationCannotPublishAfterClose() async throws {
        for copy in [false, true] {
            let harness = try makeHarness()
            let destination = location("Failed-delayed.mscope")
            await harness.probe.set(externalVersion(at: destination, seed: "before"))
            await harness.publisher.pauseNextPublish()
            let write = Task {
                if copy { return await harness.session.saveCopy(to: destination.canonicalURL) }
                return await harness.session.saveAs(to: destination.canonicalURL)
            }
            await harness.publisher.waitUntilPublishStarted()
            await harness.publisher.failNextPublish("synthetic-publish-failure")
            await harness.probe.pauseNextObservation()
            await harness.publisher.releasePublish()
            await harness.probe.waitForObservationCount(2)
            harness.session.close()
            let retired = harness.session.snapshot
            await harness.probe.enqueue(externalVersion(at: destination, seed: "changed"))
            await harness.probe.releaseObservation()
            let outcome = await write.value
            XCTAssertEqual(outcome, .superseded)
            XCTAssertEqual(harness.session.snapshot, retired)
        }
    }

    func testSaveCopyRefusesActiveCanonicalAndObservedPhysicalAliasesBeforeStaging() async throws {
        let identity = WorkspaceFileObjectIdentity(device: 901, inode: 902)
        for knownIdentity in [nil, identity] {
            let active = WorkspaceDocumentLocation(canonicalURL: location("Current.mscope").canonicalURL, fileObjectIdentity: knownIdentity)
            let harness = try makeHarness(activeLocation: active)
            defer { harness.session.close() }
            harness.source.mutate()
            harness.session.noteMutation(harness.source.mutationGeneration)
            let before = harness.session.snapshot
            let samePathOutcome = await harness.session.saveCopy(to: active.canonicalURL)
            XCTAssertEqual(samePathOutcome, .failed("document-save-copy-active-destination-use-save"))
            XCTAssertEqual(harness.session.snapshot, before)
            let initialObservations = await harness.probe.observationCount
            XCTAssertEqual(initialObservations, 0)
            for canonicalAlias in [false, true] {
                // Initial target is separate; authoritative observation reveals the current
                // canonical path, or a different path with the known physical identity.
                if !canonicalAlias && knownIdentity == nil { continue }
                let target = location("Copy-alias.mscope")
                let observed = WorkspaceDocumentLocation(
                    canonicalURL: canonicalAlias ? active.canonicalURL : target.canonicalURL,
                    fileObjectIdentity: canonicalAlias ? nil : knownIdentity)
                await harness.probe.enqueue(externalVersion(at: observed, seed: "alias"))
                let outcome = await harness.session.saveCopy(to: target.canonicalURL)
                XCTAssertEqual(outcome, .failed("document-save-copy-active-destination-use-save"))
                XCTAssertEqual(harness.session.snapshot, before)
            }
            XCTAssertEqual(harness.reservations.owner(of: active), harness.windowID)
            let stages = await harness.publisher.stageCount
            XCTAssertEqual(stages, 0)
        }
    }

    func testSaveCopyInitialKnownPhysicalAliasRefusesWithoutObservation() async throws {
        // Real location canonicalization supplies the alias identity; the IO remains synthetic.
        let root = TestWorkRoot.scratch.appendingPathComponent("MacScope-self-copy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("alias.mscope")
        try Data().write(to: target)
        let alias = try WorkspaceDocumentLocation.canonicalized(from: target)
        let active = WorkspaceDocumentLocation(canonicalURL: root.appendingPathComponent("active.mscope"), fileObjectIdentity: alias.fileObjectIdentity)
        let harness = try makeHarness(activeLocation: active)
        defer { harness.session.close() }
        let before = harness.session.snapshot
        let outcome = await harness.session.saveCopy(to: target)
        XCTAssertEqual(outcome, .failed("document-save-copy-active-destination-use-save"))
        XCTAssertEqual(harness.session.snapshot, before)
        let observations = await harness.probe.observationCount
        let stages = await harness.publisher.stageCount
        XCTAssertEqual(observations, 0)
        XCTAssertEqual(stages, 0)
    }

    func testSaveCopySeparateUnknownOrDifferentIdentityRetainsActiveState() async throws {
        for activeIdentity in [nil, WorkspaceFileObjectIdentity(device: 910, inode: 911)] {
            for targetIdentity in [nil, WorkspaceFileObjectIdentity(device: 920, inode: 921)] {
                let active = WorkspaceDocumentLocation(canonicalURL: location("Current.mscope").canonicalURL, fileObjectIdentity: activeIdentity)
                let harness = try makeHarness(activeLocation: active)
                defer { harness.session.close() }
                harness.source.mutate()
                harness.session.noteMutation(harness.source.mutationGeneration)
                let before = harness.session.snapshot
                let destination = WorkspaceDocumentLocation(canonicalURL: location("Separate-copy.mscope").canonicalURL, fileObjectIdentity: targetIdentity)
                await harness.probe.enqueue(externalVersion(at: destination, seed: "separate"))
                let outcome = await harness.session.saveCopy(to: destination.canonicalURL)
                XCTAssertEqual(outcome, .copied(destination))
                XCTAssertEqual(harness.session.snapshot.location, before.location)
                XCTAssertEqual(harness.session.snapshot.expectedExternalVersion, before.expectedExternalVersion)
                XCTAssertEqual(harness.session.snapshot.hasUnsavedChanges, before.hasUnsavedChanges)
                XCTAssertEqual(harness.session.snapshot.savedMutationGeneration, before.savedMutationGeneration)
                XCTAssertTrue(harness.source.acceptedGenerations.isEmpty)
                XCTAssertFalse(harness.reservations.isReserved(destination, by: harness.sessionID))
            }
        }
    }

    func testSaveAsOwnershipCollisionAndFailurePreserveOriginalBinding() async throws {
        let collision = try makeHarness()
        collision.source.mutate()
        collision.session.noteMutation(collision.source.mutationGeneration)
        let ownedDestination = location("Owned.mscope")
        await collision.probe.set(
            externalVersion(at: ownedDestination, condition: .absent, seed: "owned")
        )
        collision.reservations.forceOwner(.fresh(), for: ownedDestination)

        let collisionOutcome = await collision.session.saveAs(
            to: ownedDestination.canonicalURL
        )
        guard case .destinationConflicted(_, let conflict) = collisionOutcome else {
            return XCTFail("Expected ownership conflict")
        }
        XCTAssertEqual(conflict.reason, .destinationOwnedByAnotherWindow)
        XCTAssertEqual(collision.session.snapshot.location, collision.currentLocation)
        let collisionStageCount = await collision.publisher.stageCount
        XCTAssertEqual(collisionStageCount, 0)

        let failed = try makeHarness()
        failed.source.mutate()
        failed.session.noteMutation(failed.source.mutationGeneration)
        let failedDestination = location("Failed.mscope")
        let absent = externalVersion(
            at: failedDestination,
            condition: .absent,
            seed: "failed"
        )
        await failed.probe.set(absent)
        await failed.probe.enqueue(absent)
        await failed.publisher.failNextPublish("synthetic-publish-failure")

        let failedOutcome = await failed.session.saveAs(to: failedDestination.canonicalURL)
        XCTAssertEqual(failedOutcome, .failed("synthetic-publish-failure"))
        XCTAssertEqual(failed.session.snapshot.location, failed.currentLocation)
        XCTAssertFalse(failed.reservations.isReserved(failedDestination, by: failed.sessionID))
        XCTAssertTrue(failed.reservations.isReserved(failed.currentLocation, by: failed.sessionID))
    }

    func testSaveAsCurrentLocationRetainsReservationAfterObservationFailure() async throws {
        let harness = try makeHarness()
        await harness.probe.failNextObservation("synthetic-observation-failure")

        let outcome = await harness.session.saveAs(to: harness.currentLocation.canonicalURL)

        XCTAssertEqual(outcome, .failed("synthetic-observation-failure"))
        XCTAssertTrue(harness.reservations.isReserved(harness.currentLocation, by: harness.sessionID))
        XCTAssertEqual(harness.reservations.owner(of: harness.currentLocation), harness.windowID)
        XCTAssertFalse(harness.reservations.releasedLocations.contains(harness.currentLocation))
    }

    func testSaveAsCurrentLocationCloseUsesTerminalReleaseOnly() async throws {
        let harness = try makeHarness()
        await harness.probe.pauseNextObservation()

        let save = Task {
            await harness.session.saveAs(to: harness.currentLocation.canonicalURL)
        }
        await harness.probe.waitForObservationCount(1)
        harness.session.close()
        await harness.probe.releaseObservation()

        let outcome = await save.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(harness.reservations.releaseAllCount, 1)
        XCTAssertNil(harness.reservations.owner(of: harness.currentLocation))
        XCTAssertFalse(harness.reservations.releasedLocations.contains(harness.currentLocation))
    }

    func testSaveAsCurrentLocationRetainsReservationAfterPublishFailure() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        await harness.publisher.failNextPublish("synthetic-publish-failure")

        let outcome = await harness.session.saveAs(to: harness.currentLocation.canonicalURL)

        XCTAssertEqual(outcome, .failed("synthetic-publish-failure"))
        XCTAssertTrue(harness.reservations.isReserved(harness.currentLocation, by: harness.sessionID))
        XCTAssertEqual(harness.reservations.owner(of: harness.currentLocation), harness.windowID)
        XCTAssertFalse(harness.reservations.releasedLocations.contains(harness.currentLocation))
    }

    func testSaveCopyPublishesWithoutAdoptingClearingOrReservingDestination() async throws {
        let harness = try makeHarness()
        harness.source.resetRecords()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let before = harness.session.snapshot
        let destination = location("Copy.mscope")
        await harness.probe.set(
            externalVersion(at: destination, condition: .absent, seed: "copy")
        )

        let outcome = await harness.session.saveCopy(to: destination.canonicalURL)

        XCTAssertEqual(outcome, .copied(destination))
        XCTAssertEqual(harness.session.snapshot.location, before.location)
        XCTAssertEqual(
            harness.session.snapshot.expectedExternalVersion,
            before.expectedExternalVersion
        )
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertTrue(harness.source.acceptedGenerations.isEmpty)
        XCTAssertFalse(harness.reservations.isReserved(destination, by: harness.sessionID))
    }

    func testPublishMismatchCreatesStructuredConflictForEveryObservedCondition() async throws {
        let cases: [(WorkspacePackageObservationCondition, WorkspaceDocumentConflictReason)] = [
            (.valid, .externallyChanged),
            (.absent, .destinationMissing),
            (.invalid, .destinationInvalid("invalid-package")),
            (.unverifiable, .destinationUnverifiable("unstable-package")),
        ]

        for (condition, expectedReason) in cases {
            let harness = try makeHarness()
            harness.source.mutate()
            harness.session.noteMutation(harness.source.mutationGeneration)
            await harness.publisher.failNextPublish("document-publish-destination-changed")
            await harness.probe.enqueue(
                externalVersion(
                    at: harness.currentLocation,
                    condition: condition,
                    seed: "observed-\(condition.rawValue)",
                    reason: condition == .invalid
                        ? "invalid-package"
                        : (condition == .unverifiable ? "unstable-package" : nil)
                )
            )

            guard case .conflicted(let conflict) = await harness.session.save() else {
                XCTFail("Expected conflict for \(condition)")
                continue
            }
            XCTAssertEqual(conflict.reason, expectedReason)
            XCTAssertEqual(harness.session.snapshot.conflict, conflict)
            XCTAssertTrue(harness.source.hasUnsavedChanges)
        }
    }

    func testKeepLocalUsesExactDisplayedObservationAndClearsConflictOnSuccess() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let external = externalVersion(at: harness.currentLocation, seed: "external")
        await harness.publisher.failNextPublish("document-publish-destination-changed")
        await harness.probe.enqueue(external)
        guard case .conflicted = await harness.session.save() else {
            return XCTFail("Expected setup conflict")
        }

        let outcome = await harness.session.keepLocalVersion()

        XCTAssertEqual(outcome, .saved(clean: true, adopted: nil))
        let expectedObservation = await harness.publisher.lastExpectedObservation
        XCTAssertEqual(expectedObservation, external)
        XCTAssertNil(harness.session.snapshot.conflict)
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
    }

    func testKeepLocalRefusesUnverifiableConflictWithoutStaging() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let unverifiable = externalVersion(
            at: harness.currentLocation,
            condition: .unverifiable,
            seed: "unverifiable",
            reason: "unstable-package"
        )
        await harness.publisher.failNextPublish("document-publish-destination-changed")
        await harness.probe.enqueue(unverifiable)
        guard case .conflicted = await harness.session.save() else {
            return XCTFail("Expected setup conflict")
        }
        let priorStageCount = await harness.publisher.stageCount

        let keepLocalOutcome = await harness.session.keepLocalVersion()
        XCTAssertEqual(keepLocalOutcome, .failed("package-state-unverifiable"))
        let stageCount = await harness.publisher.stageCount
        XCTAssertEqual(stageCount, priorStageCount)
    }

    func testReloadRejectsMutationBeforeItsObserverIsDelivered() async throws {
        let harness = try makeHarness()
        let expected = harness.session.snapshot.expectedExternalVersion
        let changed = externalVersion(at: harness.currentLocation, seed: "external-change")
        await harness.reader.set(validatedPackage(at: harness.currentLocation, observation: changed),
            for: harness.currentLocation)
        await harness.reader.pauseNextRead()
        let reload = Task { await harness.session.reloadFromDisk() }
        await harness.reader.waitUntilReadStarted()
        harness.source.mutate() // Deliberately do not call noteMutation.
        await harness.probe.set(changed)
        await harness.reader.releaseRead()
        let result = await reload.value
        guard case .failure(let error) = result else { return XCTFail("Reload unexpectedly installed") }
        XCTAssertEqual(error, .operationFailed("document-reload-newer-edits"))
        XCTAssertEqual(harness.source.installCount, 0)
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertEqual(harness.session.snapshot.expectedExternalVersion, expected)
        XCTAssertEqual(harness.session.snapshot.mutationGeneration, harness.source.mutationGeneration)
    }

    func testRejectedReloadRearmsAutosaveConsumedWhileReadWasPending() async throws {
        let harness = try makeHarness()
        let expected = try XCTUnwrap(harness.session.snapshot.expectedExternalVersion)
        await harness.reader.set(validatedPackage(at: harness.currentLocation, observation: expected),
            for: harness.currentLocation)
        await harness.reader.pauseNextRead()
        await harness.publisher.pauseNextPublish()
        let reload = Task { await harness.session.reloadFromDisk() }
        await harness.reader.waitUntilReadStarted()
        harness.source.mutate()
        // Represents a consumed debounce before its mutation observer is delivered.
        let consumed = await harness.session.autosaveIfNeeded()
        XCTAssertNil(consumed)
        await harness.reader.releaseRead()
        let result = await reload.value
        guard case .failure(let error) = result else { return XCTFail("Reload unexpectedly installed") }
        XCTAssertEqual(error, .operationFailed("document-reload-newer-edits"))
        await harness.publisher.waitUntilPublishStarted()
        XCTAssertEqual(harness.source.installCount, 0)
        await harness.publisher.releasePublish()
        await waitUntilSaved(harness.source.mutationGeneration, by: harness.session)
        XCTAssertFalse(harness.source.hasUnsavedChanges)
    }

    func testReloadCompletionCannotInstallOrPublishAfterSourceIdentityReplacement() async throws {
        let harness = try makeHarness()
        let expected = try XCTUnwrap(harness.session.snapshot.expectedExternalVersion)
        await harness.reader.set(validatedPackage(at: harness.currentLocation, observation: expected),
            for: harness.currentLocation)
        await harness.reader.pauseNextRead()
        let oldDocument = harness.session.snapshot.documentID
        let oldWorkspace = harness.session.snapshot.workspaceID
        let reload = Task { await harness.session.reloadFromDisk() }
        await harness.reader.waitUntilReadStarted()
        harness.source.documentID = UUID()
        harness.source.workspaceID = UUID()
        harness.source.mutate()
        let consumed = await harness.session.autosaveIfNeeded()
        XCTAssertNil(consumed)
        await harness.reader.releaseRead()
        let result = await reload.value
        guard case .failure(let error) = result else { return XCTFail("Reload unexpectedly installed") }
        XCTAssertEqual(error, .operationFailed("document-reload-identity-changed"))
        XCTAssertEqual(harness.source.installCount, 0)
        XCTAssertEqual(harness.session.snapshot.documentID, oldDocument)
        XCTAssertEqual(harness.session.snapshot.workspaceID, oldWorkspace)
        XCTAssertEqual(harness.session.snapshot.expectedExternalVersion, expected)
        await yieldForAutosaveDrain()
        let writes = await harness.publisher.stageCount
        XCTAssertEqual(writes, 0)
    }

    func testReloadValidatesThenAtomicallyRefreshesIdentityVersionAndMonitor() async throws {
        let harness = try makeHarness()
        let newDocumentID = UUID()
        let newWorkspaceID = UUID()
        let reloadedObservation = externalVersion(
            at: harness.currentLocation,
            seed: "reloaded"
        )
        harness.source.nextInstallState = (
            documentID: newDocumentID,
            workspaceID: newWorkspaceID,
            generation: .init(rawValue: 9)
        )
        await harness.reader.set(
            validatedPackage(
                at: harness.currentLocation,
                observation: reloadedObservation
            ),
            for: harness.currentLocation
        )

        let result = await harness.session.reloadFromDisk()

        guard case .success = result else {
            return XCTFail("Expected reload success, got \(result)")
        }
        XCTAssertEqual(harness.session.snapshot.documentID, newDocumentID)
        XCTAssertEqual(harness.session.snapshot.workspaceID, newWorkspaceID)
        XCTAssertEqual(harness.session.snapshot.mutationGeneration, .init(rawValue: 9))
        XCTAssertEqual(harness.session.snapshot.savedMutationGeneration, .init(rawValue: 9))
        XCTAssertFalse(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertEqual(harness.session.snapshot.expectedExternalVersion, reloadedObservation)
        XCTAssertNil(harness.session.snapshot.conflict)
        await harness.monitor.waitForRegistrationCount(2)
        XCTAssertEqual(harness.monitor.registrationCount, 2)
    }

    func testMonitorHintsCoalesceToOneFollowUpAuthoritativeProbe() async throws {
        let harness = try makeHarness()
        await harness.probe.pauseNextObservation()
        await harness.monitor.waitForRegistrationCount(1)

        harness.monitor.send(.changed, at: harness.currentLocation)
        await harness.probe.waitForObservationCount(1)
        harness.monitor.send(.changed, at: harness.currentLocation)
        harness.monitor.send(.moved, at: harness.currentLocation)
        harness.monitor.send(.deleted, at: harness.currentLocation)
        await harness.probe.releaseObservation()
        await harness.probe.waitForObservationCount(2)
        await Task.yield()

        let observationCount = await harness.probe.observationCount
        XCTAssertEqual(observationCount, 2)
        XCTAssertNil(harness.session.snapshot.conflict)
    }

    func testMonitorHintDuringFollowUpRequestsOneLaterProbe() async throws {
        let harness = try makeHarness()
        await harness.probe.pauseNextObservation()
        await harness.monitor.waitForRegistrationCount(1)

        harness.monitor.send(.changed, at: harness.currentLocation)
        await harness.probe.waitForObservationCount(1)
        harness.monitor.send(.moved, at: harness.currentLocation)
        await harness.probe.pauseNextObservation()
        await harness.probe.releaseObservation()
        await harness.probe.waitForObservationCount(2)

        harness.monitor.send(.deleted, at: harness.currentLocation)
        await harness.probe.releaseObservation()
        await harness.probe.waitForObservationCount(3)
        await Task.yield()

        let observationCount = await harness.probe.observationCount
        XCTAssertEqual(observationCount, 3)
        XCTAssertNil(harness.session.snapshot.conflict)
    }

    func testCloseIsTerminalAndReleasesReservationAndMonitor() async throws {
        let harness = try makeHarness()
        await harness.monitor.waitForRegistrationCount(1)

        harness.session.close()
        harness.monitor.send(.changed, at: harness.currentLocation)
        await Task.yield()

        let saveOutcome = await harness.session.save()
        XCTAssertEqual(saveOutcome, .failed("document-session-closed"))
        XCTAssertEqual(harness.reservations.releaseAllCount, 1)
        XCTAssertEqual(harness.monitor.terminationCount, 1)
        let observationCount = await harness.probe.observationCount
        XCTAssertEqual(observationCount, 0)
    }

    // MARK: - Ordinary window-close admission

    func testCleanWindowCloseNeedsNoDecisionAndItsPermitIsSingleUse() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let request = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        let outcome = await harness.session.prepareForWindowClose(
            request, isCurrent: { true }, drain: { true },
            choose: { _ in XCTFail("A clean document must not prompt"); return .cancel },
            chooseSaveDestination: { XCTFail("A clean document must not open Save As"); return nil }
        )
        guard case .admitted(let permit) = outcome else { return XCTFail("Expected admission") }
        XCTAssertTrue(harness.session.consumeWindowClosePermit(permit))
        XCTAssertFalse(harness.session.consumeWindowClosePermit(permit))
        let writes = await harness.publisher.publishCount
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(harness.session.isClosedForWindowClose, "willClose still owns terminal eviction")
    }

    func testDirtyNamedWindowCloseSavesBeforeItsSessionCanBeClosed() async throws {
        let harness = try makeHarness()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let outcome = try await prepareClose(harness, choice: .save)
        guard case .admitted(let permit) = outcome else { return XCTFail("Expected saved admission") }
        XCTAssertEqual(harness.source.acceptedGenerations, [.init(rawValue: 1)])
        XCTAssertFalse(harness.source.hasUnsavedChanges)
        XCTAssertEqual(harness.reservations.releaseAllCount, 0)
        XCTAssertTrue(harness.session.consumeWindowClosePermit(permit))
        harness.session.close()
        XCTAssertEqual(harness.reservations.releaseAllCount, 1)
    }

    func testDirtyUntitledWindowCloseAdoptsSaveAsBeforeAdmission() async throws {
        let harness = try makeHarness(opened: false)
        defer { harness.session.close() }
        harness.source.mutate()
        let destination = location("Close-Save-As.mscope")
        await harness.probe.set(externalVersion(at: destination, condition: .absent, seed: "absent"))
        let outcome = try await prepareClose(harness, choice: .save, destination: destination.canonicalURL)
        guard case .admitted(let permit) = outcome else { return XCTFail("Expected Save As admission") }
        XCTAssertEqual(harness.session.snapshot.location?.canonicalURL, destination.canonicalURL)
        XCTAssertEqual(harness.source.adoptedLocations, [destination.canonicalURL])
        XCTAssertFalse(harness.source.hasUnsavedChanges)
        XCTAssertTrue(harness.session.consumeWindowClosePermit(permit))
    }

    func testCancelAndCancelledSaveAsLeaveUntitledContentAndWriteAdmissionUsable() async throws {
        for choice in [WorkspaceDocumentWindowCloseChoice.cancel, .save] {
            let harness = try makeHarness(opened: false)
            defer { harness.session.close() }
            harness.source.mutate()
            let outcome = try await prepareClose(harness, choice: choice, destination: nil)
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertTrue(harness.source.hasUnsavedChanges)
            XCTAssertNil(harness.session.snapshot.location)
            let writes = await harness.publisher.publishCount
            XCTAssertEqual(writes, 0)
            let retry = try XCTUnwrap(harness.session.beginWindowClosePreparation())
            harness.session.cancelWindowClosePreparation(retry)
        }
    }

    func testDiscardRequiresTheExactRevisionShownToTheUser() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        let request = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        let outcome = await harness.session.prepareForWindowClose(
            request, isCurrent: { true }, drain: { true },
            choose: { _ in
                harness.source.mutate()
                harness.session.noteMutation(harness.source.mutationGeneration)
                return .discard
            }, chooseSaveDestination: { nil }
        )
        XCTAssertEqual(outcome, .refused(.failed("document-close-content-changed")))
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        let retry = try await prepareClose(harness, choice: .discard)
        guard case .admitted(let permit) = retry else { return XCTFail("Expected fresh discard admission") }
        XCTAssertTrue(harness.session.consumeWindowClosePermit(permit))
        XCTAssertTrue(harness.source.hasUnsavedChanges, "Discard is terminal close, not a false saved marker")
        let writes = await harness.publisher.publishCount
        XCTAssertEqual(writes, 0)
    }

    func testMutationBetweenPreparationAndNativeReplayRejectsPermit() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let outcome = try await prepareClose(harness, choice: .cancel)
        guard case .admitted(let permit) = outcome else { return XCTFail("Expected clean permit") }
        harness.source.mutate()
        XCTAssertFalse(harness.session.consumeWindowClosePermit(permit))
        XCTAssertTrue(harness.source.hasUnsavedChanges)
    }

    func testCloseDrainsAnAdmittedSaveAndThenSavesItsNewerMutation() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        await harness.publisher.pauseNextPublish()
        let save = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        let request = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        let started = expectation(description: "close reached admitted-work drain")
        let closing = Task { @MainActor in
            await harness.session.prepareForWindowClose(
                request, isCurrent: { true }, drain: { started.fulfill(); return true },
                choose: { _ in .save }, chooseSaveDestination: { nil }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(harness.session.beginWindowClosePreparation(), "Repeated close cannot create another writer")
        let concurrent = await harness.session.save()
        XCTAssertEqual(concurrent, .failed("document-close-in-progress"))
        await harness.publisher.releasePublish()
        let first = await save.value
        XCTAssertEqual(first, .saved(clean: false, adopted: nil))
        let outcome = await closing.value
        guard case .admitted(let permit) = outcome else { return XCTFail("Expected newest saved revision") }
        XCTAssertEqual(harness.source.acceptedGenerations, [.init(rawValue: 1), .init(rawValue: 2)])
        XCTAssertTrue(harness.session.consumeWindowClosePermit(permit))
    }

    func testEditDuringCloseSaveRemainsDirtyAndKeepsWindowOpen() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        await harness.publisher.pauseNextPublish()
        let closing = Task { try await prepareClose(harness, choice: .save) }
        await harness.publisher.waitUntilPublishStarted()
        harness.source.mutate()
        harness.session.noteMutation(harness.source.mutationGeneration)
        await harness.publisher.releasePublish()
        let outcome = try await closing.value
        XCTAssertEqual(outcome, .refused(.failed("document-close-content-changed")))
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        XCTAssertEqual(harness.source.acceptedGenerations, [.init(rawValue: 1)])
        XCTAssertEqual(harness.reservations.releaseAllCount, 0)
        let nextSave = await harness.session.save()
        XCTAssertEqual(nextSave, .saved(clean: true, adopted: nil))
    }

    func testFailedOrConflictingCloseSavePreservesSessionAndOriginalDestination() async throws {
        for externalChange in [false, true] {
            let harness = try makeHarness()
            defer { harness.session.close() }
            harness.source.mutate()
            await harness.publisher.failNextPublish("synthetic-close-save-failure")
            if externalChange {
                await harness.probe.enqueue(externalVersion(at: harness.currentLocation, seed: "external"))
            }
            let outcome = try await prepareClose(harness, choice: .save)
            guard case .refused(let write) = outcome else { return XCTFail("Failure must retain the window") }
            if externalChange {
                guard case .conflicted = write else { return XCTFail("Expected conflict") }
            } else {
                XCTAssertEqual(write, .failed("synthetic-close-save-failure"))
            }
            XCTAssertTrue(harness.source.hasUnsavedChanges)
            XCTAssertEqual(harness.session.snapshot.location, harness.currentLocation)
            XCTAssertEqual(harness.reservations.releaseAllCount, 0)
            let retry = try XCTUnwrap(harness.session.beginWindowClosePreparation())
            harness.session.cancelWindowClosePreparation(retry)
        }
    }

    func testTimedOutCloseLeavesTheAdmittedWriterOwnedByItsLiveSession() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        await harness.publisher.pauseNextPublish()
        let save = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        let outcome = try await prepareClose(harness, choice: .save, ioTimeout: .milliseconds(10))
        XCTAssertEqual(outcome, .refused(.failed("document-close-wait-timed-out")))
        XCTAssertFalse(harness.session.isClosedForWindowClose)
        XCTAssertEqual(harness.reservations.releaseAllCount, 0)
        await harness.publisher.releasePublish()
        let saved = await save.value
        XCTAssertEqual(saved, .saved(clean: true, adopted: nil))
        XCTAssertTrue(harness.session.beginTerminationPreparation())
        harness.session.cancelTerminationPreparation()
    }

    func testStaleCloseDecisionCannotCancelANewerCloseOrAReplacementSession() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        let request = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        let choosing = expectation(description: "decision is pending")
        var decision: CheckedContinuation<WorkspaceDocumentWindowCloseChoice, Never>?
        var current = true
        let old = Task { @MainActor in
            await harness.session.prepareForWindowClose(
                request, isCurrent: { current }, drain: { true },
                choose: { _ in
                    await withCheckedContinuation { continuation in
                        decision = continuation
                        choosing.fulfill()
                    }
                }, chooseSaveDestination: { nil }
            )
        }
        await fulfillment(of: [choosing], timeout: 2)
        current = false
        harness.session.cancelWindowClosePreparation(request)
        let newer = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        decision?.resume(returning: .discard)
        let outcome = await old.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(harness.session.beginWindowClosePreparation(), "Older cleanup must leave the newer request intact")
        harness.session.cancelWindowClosePreparation(newer)
        XCTAssertTrue(harness.source.hasUnsavedChanges)
    }

    func testWindowCloseAndQuitCannotAdoptOrCancelEachOthersPreparation() throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let request = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        XCTAssertFalse(harness.session.beginTerminationPreparation())
        harness.session.cancelTerminationPreparation()
        XCTAssertNil(harness.session.beginWindowClosePreparation())
        harness.session.cancelWindowClosePreparation(request)
        XCTAssertTrue(harness.session.beginTerminationPreparation())
        XCTAssertNil(harness.session.beginWindowClosePreparation())
        harness.session.cancelWindowClosePreparation(request)
        XCTAssertTrue(harness.session.isTerminationPreparationActive)
        harness.session.cancelTerminationPreparation()
    }

    func testClosingOneDocumentDoesNotSaveOrRetireTheOther() async throws {
        let first = try makeHarness()
        let second = try makeHarness()
        defer { first.session.close(); second.session.close() }
        first.source.mutate()
        second.source.mutate()
        let outcome = try await prepareClose(first, choice: .save)
        guard case .admitted(let permit) = outcome else { return XCTFail("Expected first-window admission") }
        XCTAssertTrue(first.session.consumeWindowClosePermit(permit))
        first.session.close()
        XCTAssertTrue(second.source.hasUnsavedChanges)
        XCTAssertFalse(second.session.isClosedForWindowClose)
        let secondWrites = await second.publisher.publishCount
        XCTAssertEqual(secondWrites, 0)
        XCTAssertEqual(second.reservations.releaseAllCount, 0)
    }

    func testNativePerformCloseSavesThenForwardsTheOriginalDelegateAndCloses() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        let window = closeTestWindow()
        let original = CloseTestWindowDelegate()
        original.onClose = { harness.session.close() }
        window.delegate = original
        let delegate = WorkspaceWindowCloseDelegate(documentSession: harness.session)
        delegate.isCurrent = { true }
        delegate.choose = { _, _ in .save }
        delegate.attach(to: window)
        defer { delegate.detach(); window.close() }

        window.performClose(nil)
        XCTAssertFalse(harness.session.isClosedForWindowClose)
        await delegate.awaitPendingClose()

        XCTAssertEqual(original.shouldCloseCount, 1)
        XCTAssertEqual(original.willCloseCount, 1)
        XCTAssertEqual(harness.source.acceptedGenerations, [.init(rawValue: 1)])
        XCTAssertTrue(harness.session.isClosedForWindowClose)
    }

    func testOriginalNativeDelegateCanVetoDiscardAndTheDocumentRemainsDirty() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        let window = closeTestWindow()
        let original = CloseTestWindowDelegate()
        original.allowsClose = false
        window.delegate = original
        let delegate = WorkspaceWindowCloseDelegate(documentSession: harness.session)
        delegate.isCurrent = { true }
        delegate.choose = { _, _ in .discard }
        delegate.attach(to: window)
        defer { delegate.detach(); window.close() }
        window.performClose(nil)
        await delegate.awaitPendingClose()
        XCTAssertEqual(original.shouldCloseCount, 1)
        XCTAssertEqual(original.willCloseCount, 0)
        XCTAssertTrue(harness.source.hasUnsavedChanges)
        let retry = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        harness.session.cancelWindowClosePreparation(retry)
    }

    func testNativeRepeatedCloseCoalescesAndCancelDoesNotSendWillClose() async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        harness.source.mutate()
        let window = closeTestWindow()
        let original = CloseTestWindowDelegate()
        window.delegate = original
        let delegate = WorkspaceWindowCloseDelegate(documentSession: harness.session)
        delegate.isCurrent = { true }
        var decision: CheckedContinuation<WorkspaceDocumentWindowCloseChoice, Never>?
        var choices = 0
        let choosing = expectation(description: "native close decision pending")
        delegate.choose = { _, _ in
            choices += 1
            return await withCheckedContinuation { continuation in
                decision = continuation
                choosing.fulfill()
            }
        }
        delegate.attach(to: window)
        defer { delegate.detach(); window.close() }
        window.performClose(nil)
        await fulfillment(of: [choosing], timeout: 2)
        window.performClose(nil)
        XCTAssertEqual(choices, 1)
        decision?.resume(returning: .cancel)
        await delegate.awaitPendingClose()
        XCTAssertEqual(original.willCloseCount, 0)
        XCTAssertTrue(harness.source.hasUnsavedChanges)
    }

    func testNativeDelegateForwardsOtherSelectorsAndRestoresAReplacementDelegate() throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let window = closeTestWindow()
        let original = CloseTestWindowDelegate()
        let replacement = CloseTestWindowDelegate()
        window.delegate = original
        let delegate = WorkspaceWindowCloseDelegate(documentSession: harness.session)
        delegate.attach(to: window)
        let selector = #selector(NSWindowDelegate.windowDidResize(_:))
        XCTAssertTrue(delegate.responds(to: selector))
        XCTAssertTrue(delegate.forwardingTarget(for: selector) as AnyObject? === original)
        window.delegate = replacement
        delegate.attach(to: window)
        XCTAssertTrue(delegate.forwardingTarget(for: selector) as AnyObject? === replacement)
        delegate.detach()
        XCTAssertTrue(window.delegate === replacement)
        window.close()
    }

    func testStaleNativeDelegateCannotCloseAReplacementDocument() async throws {
        let old = try makeHarness()
        let replacement = try makeHarness()
        defer { old.session.close(); replacement.session.close() }
        replacement.source.mutate()
        let window = closeTestWindow()
        let original = CloseTestWindowDelegate()
        window.delegate = original
        let delegate = WorkspaceWindowCloseDelegate(documentSession: old.session)
        delegate.isCurrent = { false }
        delegate.attach(to: window)
        defer { delegate.detach(); window.close() }
        old.session.close()

        window.performClose(nil)
        await delegate.awaitPendingClose()

        XCTAssertEqual(original.shouldCloseCount, 0)
        XCTAssertEqual(original.willCloseCount, 0)
        XCTAssertTrue(replacement.source.hasUnsavedChanges)
        XCTAssertFalse(replacement.session.isClosedForWindowClose)
    }

    func testCloseBeforeAutosavePublishesRealCommentAndPackageReopensWithIt() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloseAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Saved.mscope", isDirectory: true)
        let binary = BinaryImage(
            id: UUID(), name: "Primary", path: "/fixtures/close.bin", kind: "raw fixture",
            architecture: "arm64", slot: .primary
        )
        var analysis = ImageAnalysis()
        analysis.instructions = [InstructionRow(
            address: 0x1000, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "",
            hasBreakpoint: false, comment: nil
        )]
        analysis.imageBytes = Data([0x1f, 0x20, 0x03, 0xd5])
        analysis.hexBytes = analysis.imageBytes
        let trigger = ManualAutosaveTrigger()
        let store = WorkspaceStore(
            workspaceName: "Close fixture",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: trigger
        )
        store.recents = CloseTestRecents()
        let reservations = SessionTestReservations()
        let session = WorkspaceDocumentSession(
            sessionID: .init(rawValue: UUID()), windowID: .fresh(), source: store,
            io: WorkspaceDocumentIO(), reservations: reservations
        )
        defer { session.close() }
        let initial = await session.saveAs(to: destination)
        guard case .saved(let clean, _) = initial, clean else { return XCTFail("Initial package save failed") }
        store.setCustomComment(0x1000, comment: "Retain this investigation before closing")
        XCTAssertTrue(trigger.isPending, "The autosave debounce has not fired")
        let request = try XCTUnwrap(session.beginWindowClosePreparation())
        XCTAssertFalse(trigger.isPending)
        let outcome = await session.prepareForWindowClose(
            request, isCurrent: { true }, drain: { true }, choose: { _ in .save },
            chooseSaveDestination: { XCTFail("Named document must use its existing package"); return nil }
        )
        guard case .admitted(let permit) = outcome else { return XCTFail("Close save was not admitted") }
        XCTAssertTrue(session.consumeWindowClosePermit(permit))
        session.close()
        let reopened = try MacScopeDocumentPackage.openPackage(from: destination)
        XCTAssertEqual(
            reopened.snapshot.addressOverrides[.primary(0x1000)]?.customComment,
            "Retain this investigation before closing"
        )
    }

    /// P1 (round 4 lane AD): an untitled workspace holding a vim-scale import (6,623 functions,
    /// 91,434 xrefs, a manifest.json far above 64 MiB) must Save As and reopen. The probe used
    /// to cap manifest.json at the 64 MiB reconstruction sub-manifest bound, observed the fresh
    /// stage as `.invalid`, and the publisher reported "document-stage-observation-changed".
    func testUntitledSaveAsRightAfterVimScaleImportPublishesAndReopens() async throws {
        // Few rows with wide operand text: the manifest crosses 64 MiB without paying a Debug
        // build's per-row cost for the ~590k instruction rows a real vim import carries.
        let instructionCount = 20_000
        let wideOperands = String(repeating: "x0, [x1, #0x10]; ", count: 200)
        let binary = BinaryImage(
            id: UUID(), name: "vim-scale", path: "/fixtures/vim-scale.bin", kind: "raw fixture",
            architecture: "arm64", slot: .primary
        )
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data(
            (0..<instructionCount).flatMap { _ in [UInt8(0x1f), 0x20, 0x03, 0xd5] }
        )
        analysis.hexBytes = analysis.imageBytes
        analysis.instructions = (0..<instructionCount).map { index in
            InstructionRow(
                address: 0x1000 + UInt64(index) * 4, bytes: "1f 20 03 d5", mnemonic: "nop",
                operands: "x\(index % 31), " + wideOperands,
                hasBreakpoint: false, comment: nil
            )
        }
        let functionStride = instructionCount / 6_623
        analysis.functions = (0..<6_623).map { index in
            let start = 0x1000 + UInt64(index * functionStride) * 4
            return FunctionSummary(
                id: UUID(), name: "sub_\(String(start, radix: 16))", startAddress: start,
                endAddress: start + UInt64(functionStride) * 4, confidence: 1
            )
        }
        analysis.xrefs = (0..<91_434).map { index in
            XRef(
                id: UUID(), from: 0x1000 + UInt64(index % instructionCount) * 4,
                to: analysis.functions[index % analysis.functions.count].startAddress,
                kind: XRefKind.call
            )
        }
        let store = WorkspaceStore(
            workspaceName: "vim-scale",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        let reopened = try await assertUntitledSaveAsPublishesAndReopens(
            store, minimumManifestBytes: 64 * 1_024 * 1_024
        )
        XCTAssertEqual(reopened.snapshot.functions.count, 6_623)
        XCTAssertEqual(reopened.snapshot.instructions.count, instructionCount)
    }

    /// Lane AG: Save As into a `/private/tmp` (or `/private/var`) folder used to fail with
    /// "document-publish-location-mismatch": the stage parent resolved to `/tmp/…` while the
    /// not-yet-created destination kept `/private/tmp/…`.
    func testUntitledSaveAsIntoPrivateTmpPathPublishesAndReopens() async throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacScopeSaveAs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Private.mscope", isDirectory: true)
        let before = try WorkspaceDocumentLocation.canonicalized(from: destination)
        XCTAssertNil(before.fileObjectIdentity)

        let binary = BinaryImage(
            id: UUID(), name: "tiny", path: "/fixtures/tiny.bin", kind: "raw fixture",
            architecture: "arm64", slot: .primary
        )
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data([0x1f, 0x20, 0x03, 0xd5])
        analysis.hexBytes = analysis.imageBytes
        let store = WorkspaceStore(
            workspaceName: "private-tmp",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.recents = CloseTestRecents()
        let reservations = SessionTestReservations()
        let session = WorkspaceDocumentSession(
            sessionID: .init(rawValue: UUID()), windowID: .fresh(), source: store,
            io: WorkspaceDocumentIO(), reservations: reservations
        )
        defer { session.close() }

        let saved = await session.saveAs(to: destination)
        guard case .saved(clean: true, adopted: _) = saved else {
            return XCTFail("Save As into /private/tmp failed: \(saved)")
        }
        let after = try WorkspaceDocumentLocation.canonicalized(from: destination)
        XCTAssertEqual(after.canonicalURL, before.canonicalURL)
        XCTAssertNotNil(after.fileObjectIdentity)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: destination).manifest.workspaceName,
            "private-tmp"
        )
    }

    /// Real-path variant: production import of /usr/bin/vim's arm64e slice, then Save As.
    /// Opt-in (MACSCOPE_REAL_IMPORT_SAVE=1) because a Debug import of vim takes minutes.
    func testUntitledSaveAsRightAfterRealVimImportPublishesAndReopens() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_REAL_IMPORT_SAVE"] == "1" else {
            throw XCTSkip("set MACSCOPE_REAL_IMPORT_SAVE=1 to import and save /usr/bin/vim")
        }
        let vim = URL(fileURLWithPath: "/usr/bin/vim")
        guard FileManager.default.isReadableFile(atPath: vim.path) else {
            throw XCTSkip("/usr/bin/vim is not readable on this host")
        }
        let store = WorkspaceStore(
            workspaceName: "vim", snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        // Fat order on macOS 27: x86_64, arm64e, arm64e.x1 — slice 1 is the arm64e image.
        await store.importBinary(url: vim, requestedSliceIndex: 1)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(store.snapshot.binaries.first?.architecture.hasPrefix("arm64"), true)
        XCTAssertGreaterThan(store.snapshot.functions.count, 1_000)
        let reopened = try await assertUntitledSaveAsPublishesAndReopens(
            store, minimumManifestBytes: 64 * 1_024 * 1_024
        )
        XCTAssertEqual(reopened.snapshot.functions.count, store.snapshot.functions.count)
    }

    /// Lane AJ (Tier 2e): import a real binary, select an address in __TEXT,__text, Save As,
    /// then reopen through the production install path (validated read + a fresh store). The
    /// inspector's Data section (`hexByteReader`) and Address Detail (`AddressDetailReading`)
    /// must resolve the same bytes and section after reopen as before the save, and report the
    /// restore-in-progress window honestly before rehydration rebuilds the section map.
    func testSaveThenReopenKeepsLoadedBytesAndSectionForTextAddress() async throws {
        let binaryURL = URL(fileURLWithPath: "/bin/echo")  // present on every macOS host
        let store = WorkspaceStore(
            workspaceName: "echo", snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        // Fat order on macOS 27: x86_64, arm64e, arm64e.x1 — slice 1 is the arm64e image.
        await store.importBinary(url: binaryURL, requestedSliceIndex: 1)
        XCTAssertNil(store.lastIssue)
        let slot = store.snapshot.primarySlot
        let text = try XCTUnwrap(store.snapshot.analysis(in: slot)?.sections.first {
            $0.name == "__TEXT,__text"
        })
        let address = text.address + 0x10
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slot, address: address)))
        let bytesBefore = try XCTUnwrap(store.snapshot.hexByteReader(in: slot)(address, 8))
        XCTAssertEqual(AddressDetailReading(address: address, snapshot: store.snapshot,
                                            imageSlot: slot).section?.name, "__TEXT,__text")

        store.recents = CloseTestRecents()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReopenBytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Echo.mscope", isDirectory: true)
        let reservations = SessionTestReservations()
        let session = WorkspaceDocumentSession(
            sessionID: .init(rawValue: UUID()), windowID: .fresh(), source: store,
            io: WorkspaceDocumentIO(), reservations: reservations
        )
        let saved = await session.saveAs(to: destination)
        session.close()
        guard case .saved(clean: true, adopted: _) = saved else {
            return XCTFail("Save As failed: \(saved)")
        }

        let location = try WorkspaceDocumentLocation.canonicalized(from: destination)
        let package = try await WorkspaceDocumentReader().readValidated(from: location)
        let reopened = WorkspaceStore(
            workspaceName: "", snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        reopened.recents = CloseTestRecents()
        try reopened.installValidatedPackage(package, from: location)
        let reopenedSlot = reopened.snapshot.primarySlot
        // The package restores the bytes at once; the section map follows from rehydration. Until
        // it lands the inspector must say so, not "Selection is outside the loaded bytes".
        XCTAssertTrue(reopened.snapshot.isAwaitingSectionRehydration(in: reopenedSlot))
        XCTAssertEqual(DataInspectorReading(
            bytes: Data(), baseAddress: address, selectedAddress: address, hasLoadedBytes: true,
            isRestoringSectionMap: reopened.snapshot.isAwaitingSectionRehydration(in: reopenedSlot)
        ).availabilityNote, "Restoring the image’s section map…")
        await reopened.awaitCurrentRehydrationForTesting()

        XCTAssertFalse(reopened.snapshot.isAwaitingSectionRehydration(in: reopenedSlot))
        let analysis = try XCTUnwrap(reopened.snapshot.analysis(in: reopenedSlot))
        XCTAssertFalse(analysis.imageBytes.isEmpty, "the package must restore the image bytes")
        XCTAssertEqual(reopened.selectedAddress, address)
        XCTAssertTrue(analysis.sections.contains { $0.name == "__TEXT,__text" },
                      "diagnostics: \(analysis.diagnostics.map(\.message))")
        XCTAssertEqual(reopened.snapshot.hexByteReader(in: reopenedSlot)(address, 8), bytesBefore)
        XCTAssertEqual(AddressDetailReading(address: address, snapshot: reopened.snapshot,
                                            imageSlot: reopenedSlot).section?.name, "__TEXT,__text")
    }

    private func assertUntitledSaveAsPublishesAndReopens(
        _ store: WorkspaceStore,
        minimumManifestBytes: Int
    ) async throws -> WorkspacePackageContents {
        store.recents = CloseTestRecents()
        let reservations = SessionTestReservations()  // the session holds it weakly
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeImportSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Imported.mscope", isDirectory: true)
        let session = WorkspaceDocumentSession(
            sessionID: .init(rawValue: UUID()), windowID: .fresh(), source: store,
            io: WorkspaceDocumentIO(), reservations: reservations
        )
        defer { session.close() }

        let saved = await session.saveAs(to: destination)
        guard case .saved(clean: true, adopted: _) = saved else {
            XCTFail("Save As of the large import failed: \(saved)")
            throw CancellationError()
        }
        let manifestBytes = try FileManager.default.attributesOfItem(
            atPath: MacScopeDocumentPackage.manifestURL(in: destination).path
        )[.size] as? Int ?? 0
        let sidecarBytes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName).path
        )[.size] as? Int ?? 0
        XCTAssertGreaterThan(manifestBytes + sidecarBytes, minimumManifestBytes)
        XCTAssertLessThan(manifestBytes, 64 * 1_024 * 1_024, "Instruction rows must leave the JSON manifest")
        XCTAssertGreaterThan(sidecarBytes, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .filter { $0.hasPrefix(".macscope-stage-") },
            []
        )
        let location = try WorkspaceDocumentLocation.canonicalized(from: destination)
        let observation = try await WorkspacePackageVersionProbe().observe(destination)
        XCTAssertEqual(observation.condition, .valid, observation.boundedReason ?? "")
        let validated = try await WorkspaceDocumentReader().readValidated(from: location)
        XCTAssertEqual(validated.observation, observation)
        return try MacScopeDocumentPackage.openPackage(from: destination)
    }

    private func prepareClose(
        _ harness: Harness,
        choice: WorkspaceDocumentWindowCloseChoice,
        destination: URL? = nil,
        ioTimeout: Duration = .seconds(30)
    ) async throws -> WorkspaceDocumentWindowCloseOutcome {
        let request = try XCTUnwrap(harness.session.beginWindowClosePreparation())
        return await harness.session.prepareForWindowClose(
            request, isCurrent: { true }, drain: { true }, choose: { _ in choice },
            chooseSaveDestination: { destination }, ioTimeout: ioTimeout
        )
    }

    private func closeTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private struct Harness {
        let sessionID: WorkspaceDocumentSessionID
        let windowID: WorkspaceWindowID
        let currentLocation: WorkspaceDocumentLocation
        let source: SessionTestContentSource
        let probe: SessionTestProbe
        let reader: SessionTestReader
        let publisher: SessionTestPublisher
        let monitor: SessionTestMonitor
        let reservations: SessionTestReservations
        let session: WorkspaceDocumentSession
    }

    private func makeHarness(opened: Bool = true, activeLocation: WorkspaceDocumentLocation? = nil) throws -> Harness {
        let sessionID = WorkspaceDocumentSessionID(rawValue: UUID())
        let windowID = WorkspaceWindowID.fresh()
        let currentLocation = activeLocation ?? location("Current.mscope")
        let currentVersion = externalVersion(at: currentLocation, seed: "current")
        let source = SessionTestContentSource()
        let probe = SessionTestProbe(defaultObservation: currentVersion)
        let reader = SessionTestReader()
        let publisher = SessionTestPublisher()
        let monitor = SessionTestMonitor()
        let reservations = SessionTestReservations()
        let io = WorkspaceDocumentIO(
            probe: probe,
            reader: reader,
            publisher: publisher,
            monitor: monitor
        )
        let session = WorkspaceDocumentSession(
            sessionID: sessionID,
            windowID: windowID,
            source: source,
            io: io,
            reservations: reservations
        )
        if opened {
            try session.bindOpenedPackage(
                validatedPackage(at: currentLocation, observation: currentVersion),
                at: currentLocation
            )
        }
        return Harness(
            sessionID: sessionID,
            windowID: windowID,
            currentLocation: currentLocation,
            source: source,
            probe: probe,
            reader: reader,
            publisher: publisher,
            monitor: monitor,
            reservations: reservations,
            session: session
        )
    }

    private func makeAutosaveStore(
        for session: WorkspaceDocumentSession
    ) -> (WorkspaceStore, ManualAutosaveTrigger) {
        let trigger = ManualAutosaveTrigger()
        let store = WorkspaceStore(
            workspaceName: "Session autosave",
            snapshot: WorkspaceSnapshot(
                binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: trigger
        )
        store.bindDocumentSessionMutationObserver(session)
        return (store, trigger)
    }

    private func fireAutosave(
        _ trigger: ManualAutosaveTrigger,
        through store: WorkspaceStore
    ) async throws -> WorkspaceDocumentWriteOutcome? {
        let originalCallback = trigger.onFire
        defer { trigger.onFire = originalCallback }
        var firedTask: Task<WorkspaceDocumentWriteOutcome?, Never>?
        // Keep the real store-to-session Task hop, but await it so the timer has definitely
        // reached the active-write guard before the paused publisher is released.
        trigger.onFire = { firedTask = store.performAutosaveIfNeeded() }
        XCTAssertTrue(trigger.firePending())
        let task = try XCTUnwrap(firedTask)
        return await task.value
    }

    private func assertPendingAutosaveIsDroppedAfterFailedWrite(
        changedOnDisk: Bool
    ) async throws {
        let harness = try makeHarness()
        defer { harness.session.close() }
        let (store, trigger) = makeAutosaveStore(for: harness.session)
        harness.source.mutate()
        store.markDocumentMutated()
        await harness.publisher.pauseNextPublish()
        let firstSave = Task { await harness.session.save() }
        await harness.publisher.waitUntilPublishStarted()
        harness.source.mutate()
        store.markDocumentMutated()
        let overlappingAutosave = try await fireAutosave(trigger, through: store)
        XCTAssertNil(overlappingAutosave)
        await harness.publisher.failNextPublish("synthetic-publish-failure")
        if changedOnDisk {
            await harness.probe.enqueue(
                externalVersion(at: harness.currentLocation, seed: "external")
            )
        }
        await harness.publisher.releasePublish()

        let firstOutcome = await firstSave.value
        if changedOnDisk {
            guard case .conflicted = firstOutcome else {
                return XCTFail("Expected an authoritative conflict, got \(firstOutcome)")
            }
            XCTAssertNotNil(harness.session.snapshot.conflict)
        } else {
            XCTAssertEqual(firstOutcome, .failed("synthetic-publish-failure"))
            XCTAssertNil(harness.session.snapshot.conflict)
        }
        await yieldForAutosaveDrain()
        XCTAssertTrue(harness.session.snapshot.hasUnsavedChanges)
        XCTAssertTrue(harness.source.acceptedGenerations.isEmpty)
        XCTAssertFalse(trigger.isPending)
        XCTAssertNil(harness.session.snapshot.activeSave)
        let stageCount = await harness.publisher.stageCount
        let publishCount = await harness.publisher.publishCount
        XCTAssertEqual(stageCount, 1)
        XCTAssertEqual(publishCount, 1)
    }

    private func waitUntilSaved(
        _ generation: WorkspaceDocumentMutationGeneration,
        by session: WorkspaceDocumentSession
    ) async {
        for _ in 0..<1_000 {
            if session.snapshot.savedMutationGeneration == generation,
               session.snapshot.activeSave == nil { return }
            await Task.yield()
        }
        XCTFail("The retained autosave demand never saved generation \(generation.rawValue)")
    }

    private func yieldForAutosaveDrain() async {
        // Give any erroneously scheduled drain a chance to cross its actor hops. This does
        // not fire another timer or make a new autosave request.
        for _ in 0..<100 { await Task.yield() }
    }

    private func waitUntilTerminationPreparationStarts(
        _ session: WorkspaceDocumentSession
    ) async {
        for _ in 0..<1_000 {
            if session.isTerminationPreparationActive { return }
            await Task.yield()
        }
        XCTFail("Termination never reached its write-admission fence")
    }
}

@MainActor
private struct CloseTestRecents: WorkspaceRecentsRecording {
    func noteRecentDocument(_ url: URL) {}
    var recentDocumentURLs: [URL] { [] }
    func clearRecentDocuments() {}
}

@MainActor
private final class CloseTestWindowDelegate: NSObject, NSWindowDelegate {
    var allowsClose = true
    var onClose: () -> Void = {}
    private(set) var shouldCloseCount = 0
    private(set) var willCloseCount = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        willCloseCount += 1
        onClose()
    }

    func windowDidResize(_ notification: Notification) {}
}

@MainActor
private final class SessionTestContentSource: WorkspaceDocumentContentSource {
    var documentID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    var workspaceID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    var mutationGeneration = WorkspaceDocumentMutationGeneration(rawValue: 0)
    var hasUnsavedChanges = false
    var nextInstallState: (
        documentID: UUID,
        workspaceID: UUID,
        generation: WorkspaceDocumentMutationGeneration
    )?
    private(set) var acceptedGenerations: [WorkspaceDocumentMutationGeneration] = []
    private(set) var adoptedLocations: [URL] = []
    private(set) var installCount = 0
    private var capturedGeneration: WorkspaceDocumentMutationGeneration?

    func mutate() {
        mutationGeneration = try! mutationGeneration.next()
        hasUnsavedChanges = true
    }

    func resetRecords() {
        acceptedGenerations.removeAll()
        adoptedLocations.removeAll()
    }

    func makePackagePayload() throws -> WorkspaceDocumentPackagePayload {
        capturedGeneration = mutationGeneration
        return WorkspaceDocumentPackagePayload(
            documentID: documentID,
            workspaceID: workspaceID,
            manifestData: Data("session-test-manifest".utf8),
            attachmentsByBinaryID: [:],
            capturedMutationGeneration: mutationGeneration
        )
    }

    func installValidatedPackage(
        _ package: WorkspaceDocumentValidatedPackage,
        from location: WorkspaceDocumentLocation
    ) throws {
        installCount += 1
        if let nextInstallState {
            documentID = nextInstallState.documentID
            workspaceID = nextInstallState.workspaceID
            mutationGeneration = nextInstallState.generation
            self.nextInstallState = nil
        }
        hasUnsavedChanges = false
        capturedGeneration = nil
    }

    func acceptPublishedWrite(
        capturedGeneration: WorkspaceDocumentMutationGeneration,
        adopting location: WorkspaceDocumentLocation?
    ) {
        guard self.capturedGeneration == capturedGeneration else { return }
        acceptedGenerations.append(capturedGeneration)
        if let location {
            adoptedLocations.append(location.canonicalURL)
        }
        hasUnsavedChanges = mutationGeneration != capturedGeneration
        self.capturedGeneration = nil
    }
}

@MainActor
private final class SessionTestReservations: WorkspaceDocumentLocationReserving {
    private struct Reservation {
        let sessionID: WorkspaceDocumentSessionID
        let windowID: WorkspaceWindowID
        let physicalIdentity: WorkspaceFileObjectIdentity?
    }

    private struct Publication {
        let sessionID: WorkspaceDocumentSessionID
        let windowID: WorkspaceWindowID
        let retainingPublishedOwnership: Bool
    }

    private var reservations: [URL: Reservation] = [:]
    private var reservationsByPhysicalIdentity: [WorkspaceFileObjectIdentity: Reservation] = [:]
    private var forcedOwners: [URL: WorkspaceWindowID] = [:]
    private(set) var releasedLocations: [WorkspaceDocumentLocation] = []
    private(set) var releaseAllCount = 0
    private var activePublications:
        [WorkspaceDocumentPublicationReservation: Publication] = [:]
    private var nextPublicationCompletion:
        WorkspaceDocumentPublicationCompletionResult?
    private(set) var completedPublicationCount = 0

    var activePublicationCount: Int { activePublications.count }

    func forceNextPublicationCompletion(
        _ result: WorkspaceDocumentPublicationCompletionResult
    ) {
        nextPublicationCompletion = result
    }

    func forceOwner(_ owner: WorkspaceWindowID, for location: WorkspaceDocumentLocation) {
        forcedOwners[location.canonicalURL] = owner
    }

    func owner(of location: WorkspaceDocumentLocation) -> WorkspaceWindowID? {
        forcedOwners[location.canonicalURL]
            ?? reservations[location.canonicalURL]?.windowID
            ?? location.fileObjectIdentity.flatMap {
                reservationsByPhysicalIdentity[$0]?.windowID
            }
    }

    func reserve(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentLocationReservationResult {
        if let forced = forcedOwners[location.canonicalURL] {
            return .alreadyOwned(forced)
        }
        if let existing = reservations[location.canonicalURL] {
            if existing.sessionID != sessionID {
                return .alreadyOwned(existing.windowID)
            }
        }
        if let identity = location.fileObjectIdentity,
           let existing = reservationsByPhysicalIdentity[identity],
           existing.sessionID != sessionID {
            return .alreadyOwned(existing.windowID)
        }
        let priorIdentity = reservations[location.canonicalURL]?.physicalIdentity
        let reservation = Reservation(
            sessionID: sessionID,
            windowID: windowID,
            physicalIdentity: location.fileObjectIdentity
        )
        reservations[location.canonicalURL] = reservation
        if let identity = location.fileObjectIdentity {
            reservationsByPhysicalIdentity[identity] = reservation
        }
        if priorIdentity != location.fileObjectIdentity,
           let priorIdentity,
           !reservations.values.contains(where: { owner in
               owner.physicalIdentity == priorIdentity
           }) {
            reservationsByPhysicalIdentity[priorIdentity] = nil
        }
        return .reserved
    }

    func release(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID
    ) {
        releasedLocations.append(location)
        guard let reservation = reservations[location.canonicalURL],
              reservation.sessionID == sessionID else { return }
        reservations[location.canonicalURL] = nil
        if let identity = location.fileObjectIdentity,
           reservationsByPhysicalIdentity[identity]?.sessionID == reservation.sessionID,
           reservationsByPhysicalIdentity[identity]?.windowID == reservation.windowID {
            reservationsByPhysicalIdentity[identity] = nil
        }
    }

    func releaseAll(for sessionID: WorkspaceDocumentSessionID) {
        releaseAllCount += 1
        reservations = reservations.filter { $0.value.sessionID != sessionID }
        reservationsByPhysicalIdentity = reservationsByPhysicalIdentity.filter {
            $0.value.sessionID != sessionID
        }
    }

    func beginPhysicalPublication(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        retainingPublishedOwnership: Bool,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentPublicationReservationResult {
        if let owner = owner(of: destination), owner != windowID {
            return .alreadyOwned(owner)
        }
        let publication = WorkspaceDocumentPublicationReservation()
        activePublications[publication] = Publication(
            sessionID: sessionID,
            windowID: windowID,
            retainingPublishedOwnership: retainingPublishedOwnership
        )
        return .reserved(publication)
    }

    func completePhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation,
        at publishedLocation: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentPublicationCompletionResult {
        guard let pending = activePublications.removeValue(forKey: publication) else {
            return .invalid
        }
        if let forced = nextPublicationCompletion {
            nextPublicationCompletion = nil
            return forced
        }
        if pending.retainingPublishedOwnership {
            guard case .reserved = reserve(
                publishedLocation,
                for: pending.sessionID,
                windowID: pending.windowID
            ) else {
                return .invalid
            }
        }
        completedPublicationCount += 1
        return .completed
    }

    func cancelPhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation
    ) {
        activePublications[publication] = nil
    }

    func isReserved(
        _ location: WorkspaceDocumentLocation,
        by sessionID: WorkspaceDocumentSessionID
    ) -> Bool {
        reservations[location.canonicalURL]?.sessionID == sessionID
    }
}

private actor SessionTestProbe: WorkspacePackageVersionProbing {
    private var defaultObservation: WorkspacePackageExternalVersion
    private var observations: [URL: WorkspacePackageExternalVersion] = [:]
    private var queued: [WorkspacePackageExternalVersion] = []
    private var nextFailure: String?
    private var shouldPauseNext = false
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var observationCount = 0

    init(defaultObservation: WorkspacePackageExternalVersion) {
        self.defaultObservation = defaultObservation
    }

    func set(_ observation: WorkspacePackageExternalVersion) {
        observations[observation.location.canonicalURL] = observation
    }

    func enqueue(_ observation: WorkspacePackageExternalVersion) {
        queued.append(observation)
    }

    func failNextObservation(_ reason: String) {
        nextFailure = reason
    }

    func pauseNextObservation() {
        shouldPauseNext = true
    }

    func releaseObservation() {
        pausedContinuation?.resume()
        pausedContinuation = nil
    }

    func waitForObservationCount(_ expected: Int) async {
        if observationCount >= expected { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((expected, continuation))
        }
    }

    func observe(_ url: URL) async throws -> WorkspacePackageExternalVersion {
        observationCount += 1
        let ready = countWaiters.filter { observationCount >= $0.0 }
        countWaiters.removeAll { observationCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        if shouldPauseNext {
            shouldPauseNext = false
            await withCheckedContinuation { continuation in
                pausedContinuation = continuation
            }
        }
        if let nextFailure {
            self.nextFailure = nil
            throw WorkspaceDocumentSessionError.operationFailed(nextFailure)
        }
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return observations[url] ?? defaultObservation
    }
}

private actor SessionTestReader: WorkspaceDocumentReading {
    private var packages: [URL: WorkspaceDocumentValidatedPackage] = [:]
    private var shouldPauseNextRead = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseNextRead() { shouldPauseNextRead = true }

    func waitUntilReadStarted() async {
        if readContinuation != nil { return }
        await withCheckedContinuation { readStartWaiters.append($0) }
    }

    func releaseRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func set(
        _ package: WorkspaceDocumentValidatedPackage,
        for location: WorkspaceDocumentLocation
    ) {
        packages[location.canonicalURL] = package
    }

    func readValidated(
        from location: WorkspaceDocumentLocation
    ) async throws -> WorkspaceDocumentValidatedPackage {
        guard let package = packages[location.canonicalURL] else {
            throw WorkspaceDocumentSessionError.operationFailed("synthetic-read-missing")
        }
        if shouldPauseNextRead {
            shouldPauseNextRead = false
            await withCheckedContinuation { continuation in
                readContinuation = continuation
                let waiters = readStartWaiters
                readStartWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return package
    }
}

private actor SessionTestPublisher: WorkspaceDocumentPublishing {
    private var nextFailure: String?
    private var nextPublishedRootIdentity: WorkspaceFileObjectIdentity?
    private var shouldPauseNextStage = false
    private var pausedStageContinuation: CheckedContinuation<Void, Never>?
    private var stageStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldPauseNext = false
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var publishStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stageCount = 0
    private(set) var capturedGenerations: [WorkspaceDocumentMutationGeneration] = []
    private(set) var publishCount = 0
    private(set) var discardCount = 0
    private(set) var lastExpectedObservation: WorkspacePackageExternalVersion?
    private(set) var lastPublishedObservation: WorkspacePackageExternalVersion?

    func pauseNextPublish() {
        shouldPauseNext = true
    }

    func replaceRootIdentityOnNextPublish(with identity: WorkspaceFileObjectIdentity) {
        nextPublishedRootIdentity = identity
    }

    func pauseNextStage() {
        shouldPauseNextStage = true
    }

    func waitUntilStageStarted() async {
        if pausedStageContinuation != nil { return }
        await withCheckedContinuation { continuation in
            stageStartWaiters.append(continuation)
        }
    }

    func releaseStage() {
        pausedStageContinuation?.resume()
        pausedStageContinuation = nil
    }

    func failNextPublish(_ reason: String) {
        nextFailure = reason
    }

    func waitUntilPublishStarted() async {
        if pausedContinuation != nil { return }
        await withCheckedContinuation { continuation in
            publishStartWaiters.append(continuation)
        }
    }

    func releasePublish() {
        pausedContinuation?.resume()
        pausedContinuation = nil
    }

    func stage(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL
    ) async throws -> WorkspaceDocumentStagedPackage {
        stageCount += 1
        capturedGenerations.append(payload.capturedMutationGeneration)
        if shouldPauseNextStage {
            shouldPauseNextStage = false
            let waiters = stageStartWaiters
            stageStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                pausedStageContinuation = continuation
                waiters.forEach { $0.resume() }
            }
        }
        let stagingID = UUID()
        let stagingLocation = WorkspaceDocumentLocation(
            canonicalURL: parentDirectory.appendingPathComponent("stage-\(stagingID.uuidString)"),
            fileObjectIdentity: nil
        )
        return WorkspaceDocumentStagedPackage(
            stagingID: stagingID,
            stagingURL: stagingLocation.canonicalURL,
            stagedObservation: externalVersion(at: stagingLocation, seed: "stage"),
            capturedMutationGeneration: payload.capturedMutationGeneration
        )
    }

    func publish(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        expecting expected: WorkspacePackageExternalVersion
    ) async throws -> WorkspaceDocumentPublishReceipt {
        publishCount += 1
        lastExpectedObservation = expected
        guard expected.location == destination else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "synthetic-publish-location-mismatch"
            )
        }
        if shouldPauseNext {
            shouldPauseNext = false
            let waiters = publishStartWaiters
            publishStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                pausedContinuation = continuation
                waiters.forEach { $0.resume() }
            }
        }
        if let nextFailure {
            self.nextFailure = nil
            throw WorkspaceDocumentSessionError.operationFailed(nextFailure)
        }
        let publishedLocation = WorkspaceDocumentLocation(
            canonicalURL: destination.canonicalURL,
            fileObjectIdentity: nextPublishedRootIdentity ?? destination.fileObjectIdentity
        )
        nextPublishedRootIdentity = nil
        let published = externalVersion(
            at: publishedLocation,
            seed: "published-\(publishCount)"
        )
        lastPublishedObservation = published
        return WorkspaceDocumentPublishReceipt(
            stagingID: staged.stagingID,
            destination: destination,
            priorObservation: expected,
            publishedObservation: published
        )
    }

    func discard(_ staged: WorkspaceDocumentStagedPackage) async {
        discardCount += 1
    }
}

private final class SessionTestMonitor: WorkspaceDocumentChangeMonitoring, Sendable {
    private struct State {
        var continuations: [URL: AsyncStream<WorkspaceDocumentChangeHint>.Continuation] = [:]
        var probeDemands: [URL: WorkspaceDocumentProbeDemand] = [:]
        var registrations = 0
        var terminations = 0
        var registrationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var registrationCount: Int { state.withLock { $0.registrations } }
    var terminationCount: Int { state.withLock { $0.terminations } }

    func waitForRegistrationCount(_ expected: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                guard state.registrations < expected else { return true }
                state.registrationWaiters.append((expected, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func changes(
        at location: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentChangeFeed {
        let probeDemand = WorkspaceDocumentProbeDemand()
        let stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let ready = state.withLock { state in
                state.registrations += 1
                state.continuations[location.canonicalURL] = continuation
                state.probeDemands[location.canonicalURL] = probeDemand
                let ready = state.registrationWaiters.filter {
                    state.registrations >= $0.0
                }
                state.registrationWaiters.removeAll {
                    state.registrations >= $0.0
                }
                return ready.map(\.1)
            }
            ready.forEach { $0.resume() }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock {
                    $0.terminations += 1
                    $0.continuations[location.canonicalURL] = nil
                    $0.probeDemands[location.canonicalURL] = nil
                }
            }
        }
        return WorkspaceDocumentChangeFeed(
            stream: stream,
            probeDemand: probeDemand
        )
    }

    func send(
        _ hint: WorkspaceDocumentChangeHint,
        at location: WorkspaceDocumentLocation
    ) {
        let registration = state.withLock {
            (
                $0.continuations[location.canonicalURL],
                $0.probeDemands[location.canonicalURL]
            )
        }
        registration.1?.admit()
        registration.0?.yield(hint)
    }
}

private func location(_ name: String) -> WorkspaceDocumentLocation {
    WorkspaceDocumentLocation(
        canonicalURL: URL(fileURLWithPath: "/tmp/WorkspaceDocumentSessionTests/\(name)"),
        fileObjectIdentity: nil
    )
}

private func externalVersion(
    at location: WorkspaceDocumentLocation,
    condition: WorkspacePackageObservationCondition = .valid,
    seed: String,
    reason: String? = nil
) -> WorkspacePackageExternalVersion {
    let digest = MacScopeDocumentPackage.fileHash(for: Data(seed.utf8))
    return WorkspacePackageExternalVersion(
        location: location,
        condition: condition,
        observationSHA256: digest,
        manifestSHA256: condition == .valid ? digest : nil,
        validatedContentSHA256: condition == .valid ? digest : nil,
        boundedReason: reason
    )
}

private func validatedPackage(
    at location: WorkspaceDocumentLocation,
    observation: WorkspacePackageExternalVersion
) -> WorkspaceDocumentValidatedPackage {
    WorkspaceDocumentValidatedPackage(
        manifestData: Data("session-test-manifest".utf8),
        attachmentsByBinaryID: [:],
        observation: observation
    )
}

extension WorkspaceDocumentSessionTests {
    func testReloadFromDiskEstablishesOneAuthoritativeRestoreDriveContext() async throws {
        let tests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent().deletingLastPathComponent()
        let store = try String(
            contentsOf: root.appendingPathComponent("Stores/WorkspaceStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(store.contains("establishNativeDriveContext(origin: .authoritativeRestore)"))
    }
}

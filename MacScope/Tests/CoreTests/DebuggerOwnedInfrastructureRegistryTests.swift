import XCTest
@testable import MacScope

final class DebuggerOwnedInfrastructureRegistryTests: XCTestCase {
    func testBeginAndCancelAdvanceRevisionAndRestoreAuthoritativeSnapshot() async throws {
        let provider = OwnedInfrastructureEvidenceProvider()
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )

        let initial = await registry.snapshot
        let token = try await registry.beginSpawn()
        let pending = await registry.snapshot

        XCTAssertGreaterThan(pending.revision.rawValue, initial.revision.rawValue)
        XCTAssertFalse(pending.isAuthoritative)
        XCTAssertEqual(pending.pendingSpawnCount, 1)
        XCTAssertTrue(pending.excludedInstances.isEmpty)

        try await registry.cancelBeforeProcessLaunch(token)
        let cancelled = await registry.snapshot
        XCTAssertGreaterThan(cancelled.revision.rawValue, pending.revision.rawValue)
        XCTAssertTrue(cancelled.isAuthoritative)
        XCTAssertEqual(cancelled.pendingSpawnCount, 0)
        XCTAssertTrue(cancelled.excludedInstances.isEmpty)
    }

    func testOwnedPhaseRevisionInvalidatesPreviouslyCurrentInterlockVector() async throws {
        let initialVector = DebuggerLocalProcessObservationPolicyRevisionVector(
            ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
            leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
        )
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: initialVector
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999,
            attachWriteInterlock: interlock
        )

        XCTAssertTrue(interlock.validatesCurrentRevision(initialVector))
        _ = try await registry.beginSpawn()

        let snapshot = await registry.snapshot
        XCTAssertEqual(snapshot.attachWriteInterlockIdentity, interlock.identity)
        XCTAssertEqual(snapshot.revision.rawValue, 1)
        XCTAssertFalse(interlock.validatesCurrentRevision(initialVector))
        XCTAssertEqual(
            interlock.currentSnapshot.revision.ownedInfrastructure,
            snapshot.revision
        )
    }

    func testLaunchAttemptPermanentlyClosesPreLaunchCancellation() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        _ = try await registry.beginLaunchAttempt(token)

        do {
            try await registry.cancelBeforeProcessLaunch(token)
            XCTFail("A launch claim must permanently close pre-launch cancellation")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .invalidStateTransition
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertFalse(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.pendingSpawnCount, 1)
    }

    func testExactNotLaunchedSettlementRemovesClaimAndAdvancesRevision() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let claimed = await registry.snapshot
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 0,
            dispositions: [.notLaunched]
        )

        try await registry.settleUnlaunchedProcess(
            claim,
            retainedProcess: retainedProcess
        )

        let settled = await registry.snapshot
        XCTAssertGreaterThan(settled.revision, claimed.revision)
        XCTAssertTrue(settled.isAuthoritative)
        XCTAssertEqual(settled.pendingSpawnCount, 0)
        XCTAssertEqual(settled.unresolvedSpawnCount, 0)
        XCTAssertTrue(settled.excludedInstances.isEmpty)
    }

    func testUnlaunchedSettlementRejectsEveryNonNotLaunchedDisposition() async throws {
        for rejectedDisposition in [
            DebuggerOwnedInfrastructureRetainedProcessDisposition.running,
            .unknown,
            .exitedAndReaped,
        ] {
            let registry = DebuggerOwnedInfrastructureRegistry(
                processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
                hostProcessID: 9_999
            )
            let token = try await registry.beginSpawn()
            let claim = try await registry.beginLaunchAttempt(token)
            let retainedProcess = OwnedInfrastructureRetainedProcess(
                processID: 0,
                dispositions: [rejectedDisposition, .exitedAndReaped]
            )

            do {
                try await registry.settleUnlaunchedProcess(
                    claim,
                    retainedProcess: retainedProcess
                )
                XCTFail("Only exact not-launched evidence may settle a launch claim")
            } catch {
                XCTAssertEqual(
                    error as? DebuggerOwnedInfrastructureRegistryError,
                    .retainedProcessNotSettled
                )
            }

            let unresolved = await registry.snapshot
            XCTAssertFalse(unresolved.isAuthoritative)
            XCTAssertEqual(unresolved.pendingSpawnCount, 0)
            XCTAssertEqual(unresolved.unresolvedSpawnCount, 1)

            try await registry.retireUnresolvedSpawn(
                token,
                retainedProcess: retainedProcess
            )
            let recovered = await registry.snapshot
            XCTAssertTrue(recovered.isAuthoritative)
        }
    }

    func testUnlaunchedSettlementIsCancellationShielded() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let dispositionGate = OwnedInfrastructureDispositionGate()
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 0,
            dispositionGate: dispositionGate
        )

        let task = Task {
            try await registry.settleUnlaunchedProcess(
                claim,
                retainedProcess: retainedProcess
            )
        }
        await dispositionGate.waitUntilRequested()
        task.cancel()
        await dispositionGate.resolve(.notLaunched)
        try await task.value

        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.pendingSpawnCount, 0)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 0)
    }

    func testConsumedUnlaunchedClaimCannotBeReusedOrRedirected() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 0,
            dispositions: [.running, .notLaunched]
        )
        do {
            try await registry.settleUnlaunchedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("Running evidence must fail closed")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .retainedProcessNotSettled
            )
        }

        let substitute = OwnedInfrastructureRetainedProcess(
            processID: 0,
            dispositions: [.notLaunched]
        )
        do {
            try await registry.settleUnlaunchedProcess(
                claim,
                retainedProcess: substitute
            )
            XCTFail("A consumed claim must not be redirected to another object")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .staleSpawnToken
            )
        }
        do {
            try await registry.retireUnresolvedSpawn(
                token,
                retainedProcess: substitute
            )
            XCTFail("A substitute object must not recover the consumed claim")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .retainedProcessBindingMismatch
            )
        }

        try await registry.retireUnresolvedSpawn(
            token,
            retainedProcess: retainedProcess
        )
        let recovered = await registry.snapshot
        XCTAssertTrue(recovered.isAuthoritative)

        do {
            try await registry.settleUnlaunchedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("A removed claim must remain stale")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .staleSpawnToken
            )
        }
    }

    func testStableTwoPassCatalogCaptureRegistersExactProcessInstance() async throws {
        let evidence = try makeOwnedCatalogEvidence(processID: 101, startSeconds: 10)
        let provider = OwnedInfrastructureEvidenceProvider(
            catalogEvidence: [101: [.resolved(evidence), .resolved(evidence)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(processID: 101)

        let registration = try await registry.registerSpawnedProcess(
            claim,
            retainedProcess: retainedProcess
        )
        let snapshot = await registry.snapshot

        XCTAssertEqual(registration.fingerprint, evidence.fingerprint)
        XCTAssertEqual(registration.instanceKey.processID, 101)
        XCTAssertEqual(registration.instanceKey.startTime, evidence.fingerprint.startTime)
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.excludedInstances, [registration.instanceKey])
        let catalogRequestCount = await provider.catalogRequestCount
        XCTAssertEqual(catalogRequestCount, 2)
    }

    func testDriftingCatalogPinsUnresolvedAndRetryForSamePIDCanSucceed() async throws {
        let first = try makeOwnedCatalogEvidence(processID: 102, startSeconds: 20)
        let drifted = try makeOwnedCatalogEvidence(processID: 102, startSeconds: 21)
        let provider = OwnedInfrastructureEvidenceProvider(
            catalogEvidence: [
                102: [
                    .resolved(first), .resolved(drifted),
                    .resolved(drifted), .resolved(drifted),
                ],
            ]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 102,
            isRunning: [true, true, true, true, true, true]
        )

        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("Expected the A/B identity drift to fail closed")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .identityCaptureFailed(.identityChanged)
            )
        }
        let unresolved = await registry.snapshot
        XCTAssertFalse(unresolved.isAuthoritative)
        XCTAssertEqual(unresolved.unresolvedSpawnCount, 1)
        XCTAssertTrue(unresolved.excludedInstances.isEmpty)

        let registration = try await registry.retryIdentityCapture(
            token,
            retainedProcess: retainedProcess
        )
        let recovered = await registry.snapshot
        XCTAssertTrue(recovered.isAuthoritative)
        XCTAssertEqual(recovered.excludedInstances, [registration.instanceKey])
        XCTAssertEqual(registration.instanceKey.startTime, drifted.fingerprint.startTime)
        let catalogRequestCount = await provider.catalogRequestCount
        XCTAssertEqual(catalogRequestCount, 4)
    }

    func testRetryRejectsSubstitutedRetainedProcessBinding() async throws {
        let first = try makeOwnedCatalogEvidence(processID: 110, startSeconds: 100)
        let drifted = try makeOwnedCatalogEvidence(processID: 110, startSeconds: 101)
        let provider = OwnedInfrastructureEvidenceProvider(
            catalogEvidence: [110: [.resolved(first), .resolved(drifted)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(processID: 110)
        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("Expected identity drift to leave an unresolved spawn")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .identityCaptureFailed(.identityChanged)
            )
        }

        do {
            _ = try await registry.retryIdentityCapture(
                token,
                retainedProcess: OwnedInfrastructureRetainedProcess(processID: 110)
            )
            XCTFail("A different object must not substitute for the retained launch binding")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .retainedProcessBindingMismatch
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertFalse(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 1)
    }

    func testRetryFailsClosedWhenSameBindingReportsDifferentProcessID() async throws {
        let first = try makeOwnedCatalogEvidence(processID: 111, startSeconds: 110)
        let drifted = try makeOwnedCatalogEvidence(processID: 111, startSeconds: 111)
        let provider = OwnedInfrastructureEvidenceProvider(
            catalogEvidence: [111: [.resolved(first), .resolved(drifted)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processIDs: [111, 211]
        )
        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("Expected identity drift to leave an unresolved spawn")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .identityCaptureFailed(.identityChanged)
            )
        }

        do {
            _ = try await registry.retryIdentityCapture(
                token,
                retainedProcess: retainedProcess
            )
            XCTFail("A retained binding whose PID changed must fail closed")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .identityCaptureFailed(.identityChanged)
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertFalse(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 1)
        XCTAssertTrue(snapshot.excludedInstances.isEmpty)
        let catalogRequestCount = await provider.catalogRequestCount
        XCTAssertEqual(catalogRequestCount, 2)
    }

    func testConsumedLaunchClaimCannotBeReusedWithAnotherBinding() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(processID: 1)
        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("An invalid launched PID must fail closed")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .invalidProcessID
            )
        }

        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: OwnedInfrastructureRetainedProcess(processID: 112)
            )
            XCTFail("A launch claim must be single-use even when first registration fails")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .staleSpawnToken
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertFalse(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 1)
    }

    func testRetirementRequiresTwoAbsentPIDCatalogsBeforeRemovingRegistration() async throws {
        let evidence = try makeOwnedCatalogEvidence(processID: 103, startSeconds: 30)
        let provider = OwnedInfrastructureEvidenceProvider(
            processIDs: [.resolved([]), .resolved([103]), .resolved([]), .resolved([])],
            catalogEvidence: [103: [.resolved(evidence), .resolved(evidence)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let registration = try await registry.registerSpawnedProcess(
            claim,
            retainedProcess: OwnedInfrastructureRetainedProcess(processID: 103)
        )

        do {
            try await registry.retire(registration)
            XCTFail("One absent pass must not outweigh a present second pass")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .spawnedProcessStillPresent
            )
        }
        let preserved = await registry.snapshot
        XCTAssertEqual(preserved.excludedInstances, [registration.instanceKey])
        XCTAssertTrue(preserved.isAuthoritative)

        try await registry.retire(registration)
        let retired = await registry.snapshot
        XCTAssertTrue(retired.isAuthoritative)
        XCTAssertTrue(retired.excludedInstances.isEmpty)
        let processIDRequestCount = await provider.processIDRequestCount
        XCTAssertEqual(processIDRequestCount, 4)
    }

    func testPresentProcessPreservesRegisteredExclusion() async throws {
        let evidence = try makeOwnedCatalogEvidence(processID: 104, startSeconds: 40)
        let provider = OwnedInfrastructureEvidenceProvider(
            processIDs: [.resolved([104]), .resolved([])],
            catalogEvidence: [104: [.resolved(evidence), .resolved(evidence)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let registration = try await registry.registerSpawnedProcess(
            claim,
            retainedProcess: OwnedInfrastructureRetainedProcess(processID: 104)
        )

        do {
            try await registry.retire(registration)
            XCTFail("A present PID must preserve the registration")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .spawnedProcessStillPresent
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.excludedInstances, [registration.instanceKey])
    }

    func testUnknownRetirementEvidencePreservesRegisteredExclusion() async throws {
        let evidence = try makeOwnedCatalogEvidence(processID: 105, startSeconds: 50)
        let provider = OwnedInfrastructureEvidenceProvider(
            processIDs: [.unknown(.metadataAccessDenied), .resolved([])],
            catalogEvidence: [105: [.resolved(evidence), .resolved(evidence)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let registration = try await registry.registerSpawnedProcess(
            claim,
            retainedProcess: OwnedInfrastructureRetainedProcess(processID: 105)
        )

        do {
            try await registry.retire(registration)
            XCTFail("Unknown absence evidence must preserve the registration")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .retirementProofFailed(.metadataAccessDenied)
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.excludedInstances, [registration.instanceKey])
    }

    func testRetiredRegistrationBecomesStale() async throws {
        let evidence = try makeOwnedCatalogEvidence(processID: 106, startSeconds: 60)
        let provider = OwnedInfrastructureEvidenceProvider(
            processIDs: [.resolved([]), .resolved([])],
            catalogEvidence: [106: [.resolved(evidence), .resolved(evidence)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let registration = try await registry.registerSpawnedProcess(
            claim,
            retainedProcess: OwnedInfrastructureRetainedProcess(processID: 106)
        )
        try await registry.retire(registration)

        do {
            try await registry.retire(registration)
            XCTFail("A removed registration must not be reusable")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .staleRegistration
            )
        }
    }

    func testInvalidPIDCanSettleOnlyWithExactNotLaunchedBinding() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 777
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 1,
            dispositions: [.notLaunched]
        )

        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("PID 1 is not valid owned infrastructure")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .invalidProcessID
            )
        }

        do {
            try await registry.retireUnresolvedSpawn(
                token,
                retainedProcess: OwnedInfrastructureRetainedProcess(
                    processID: 1,
                    dispositions: [.notLaunched]
                )
            )
            XCTFail("Only the exact retained launch binding may settle the unresolved spawn")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .retainedProcessBindingMismatch
            )
        }


        try await registry.retireUnresolvedSpawn(token, retainedProcess: retainedProcess)
        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.pendingSpawnCount, 0)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 0)
    }

    func testSelfPIDCanSettleOnlyWithExactExitedAndReapedBinding() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 777
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 777,
            dispositions: [.exitedAndReaped]
        )
        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("The host process cannot register itself as child infrastructure")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .selfProcess
            )
        }

        try await registry.retireUnresolvedSpawn(token, retainedProcess: retainedProcess)
        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 0)
    }

    func testUnsettledExactBindingCannotRetireUnresolvedSpawn() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedInfrastructureEvidenceProvider(),
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 1,
            dispositions: [.running]
        )
        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("An invalid launched PID must fail closed")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .invalidProcessID
            )
        }

        do {
            try await registry.retireUnresolvedSpawn(token, retainedProcess: retainedProcess)
            XCTFail("A running retained process cannot settle an unresolved spawn")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .retainedProcessNotSettled
            )
        }

        let snapshot = await registry.snapshot
        XCTAssertFalse(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 1)
    }

    func testStoppedRetainedBindingPinsUnresolvedInsteadOfRegisteringReusedPIDCatalog() async throws {
        let unrelated = try makeOwnedCatalogEvidence(processID: 109, startSeconds: 90)
        let provider = OwnedInfrastructureEvidenceProvider(
            catalogEvidence: [109: [.resolved(unrelated), .resolved(unrelated)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let stoppedRetainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 109,
            isRunning: [false]
        )

        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: stoppedRetainedProcess
            )
            XCTFail("A stopped retained process must not authorize a reused PID's catalog")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .identityCaptureFailed(.disappeared)
            )
        }

        let snapshot = await registry.snapshot
        let catalogRequestCount = await provider.catalogRequestCount
        XCTAssertFalse(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 1)
        XCTAssertTrue(snapshot.excludedInstances.isEmpty)
        XCTAssertEqual(catalogRequestCount, 0)
    }

    func testUnresolvedSpawnCanRetireOnlyAfterTwoAbsentPIDCatalogs() async throws {
        let first = try makeOwnedCatalogEvidence(processID: 107, startSeconds: 70)
        let second = try makeOwnedCatalogEvidence(processID: 107, startSeconds: 71)
        let provider = OwnedInfrastructureEvidenceProvider(
            processIDs: [.resolved([]), .resolved([])],
            catalogEvidence: [107: [.resolved(first), .resolved(second)]]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let token = try await registry.beginSpawn()
        let claim = try await registry.beginLaunchAttempt(token)
        let retainedProcess = OwnedInfrastructureRetainedProcess(
            processID: 107,
            dispositions: [.exitedAndReaped]
        )
        do {
            _ = try await registry.registerSpawnedProcess(
                claim,
                retainedProcess: retainedProcess
            )
            XCTFail("Expected identity drift to leave an unresolved spawn")
        } catch {
            XCTAssertEqual(
                error as? DebuggerOwnedInfrastructureRegistryError,
                .identityCaptureFailed(.identityChanged)
            )
        }

        try await registry.retireUnresolvedSpawn(token, retainedProcess: retainedProcess)
        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 0)
        XCTAssertTrue(snapshot.excludedInstances.isEmpty)
        let processIDRequestCount = await provider.processIDRequestCount
        XCTAssertEqual(processIDRequestCount, 2)
    }

    func testPIDReuseCreatesASeparateExactProcessInstanceKey() async throws {
        let original = try makeOwnedCatalogEvidence(processID: 108, startSeconds: 80)
        let reused = try makeOwnedCatalogEvidence(processID: 108, startSeconds: 81)
        let provider = OwnedInfrastructureEvidenceProvider(
            processIDs: [.resolved([]), .resolved([])],
            catalogEvidence: [
                108: [
                    .resolved(original), .resolved(original),
                    .resolved(reused), .resolved(reused),
                ],
            ]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )

        let firstToken = try await registry.beginSpawn()
        let firstClaim = try await registry.beginLaunchAttempt(firstToken)
        let firstRegistration = try await registry.registerSpawnedProcess(
            firstClaim,
            retainedProcess: OwnedInfrastructureRetainedProcess(processID: 108)
        )
        try await registry.retire(firstRegistration)

        let secondToken = try await registry.beginSpawn()
        let secondClaim = try await registry.beginLaunchAttempt(secondToken)
        let secondRegistration = try await registry.registerSpawnedProcess(
            secondClaim,
            retainedProcess: OwnedInfrastructureRetainedProcess(processID: 108)
        )
        let snapshot = await registry.snapshot

        XCTAssertEqual(firstRegistration.instanceKey.processID, secondRegistration.instanceKey.processID)
        XCTAssertNotEqual(firstRegistration.instanceKey, secondRegistration.instanceKey)
        XCTAssertEqual(snapshot.excludedInstances, [secondRegistration.instanceKey])
        XCTAssertTrue(snapshot.isAuthoritative)
    }
}

private actor OwnedInfrastructureRetainedProcess:
    DebuggerOwnedInfrastructureRetainedProcessBinding {
    private var processIDResults: [Int32]
    private var isRunningResults: [Bool]
    private var dispositionResults: [DebuggerOwnedInfrastructureRetainedProcessDisposition]
    private let dispositionGate: OwnedInfrastructureDispositionGate?

    init(
        processID: Int32,
        isRunning: [Bool] = [true, true, true],
        dispositions: [DebuggerOwnedInfrastructureRetainedProcessDisposition] = [.running],
        dispositionGate: OwnedInfrastructureDispositionGate? = nil
    ) {
        processIDResults = [processID]
        isRunningResults = isRunning
        dispositionResults = dispositions
        self.dispositionGate = dispositionGate
    }

    init(
        processIDs: [Int32],
        isRunning: [Bool] = [true, true, true],
        dispositions: [DebuggerOwnedInfrastructureRetainedProcessDisposition] = [.running]
    ) {
        processIDResults = processIDs
        isRunningResults = isRunning
        dispositionResults = dispositions
        dispositionGate = nil
    }

    func retainedProcessIdentifierForInfrastructure() async -> Int32 {
        guard processIDResults.count > 1 else {
            return processIDResults.first ?? 0
        }
        return processIDResults.removeFirst()
    }

    func retainedProcessIsRunningForInfrastructure() async -> Bool {
        guard !isRunningResults.isEmpty else { return false }
        return isRunningResults.removeFirst()
    }

    func retainedProcessDispositionForInfrastructure() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition {
        if let dispositionGate {
            return await dispositionGate.requestDisposition()
        }
        guard dispositionResults.count > 1 else {
            return dispositionResults.first ?? .unknown
        }
        return dispositionResults.removeFirst()
    }
}

private actor OwnedInfrastructureDispositionGate {
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var dispositionContinuation:
        CheckedContinuation<DebuggerOwnedInfrastructureRetainedProcessDisposition, Never>?

    func requestDisposition() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition {
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            dispositionContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        if dispositionContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resolve(
        _ disposition: DebuggerOwnedInfrastructureRetainedProcessDisposition
    ) {
        dispositionContinuation?.resume(returning: disposition)
        dispositionContinuation = nil
    }
}

private actor OwnedInfrastructureEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private var processIDResults: [DebuggerLocalProcessResolution<[Int32]>]
    private var catalogResults:
        [Int32: [DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>]]
    private(set) var processIDRequestCount = 0
    private(set) var catalogRequestCount = 0

    init(
        processIDs: [DebuggerLocalProcessResolution<[Int32]>] = [],
        catalogEvidence:
            [Int32: [DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>]] = [:]
    ) {
        processIDResults = processIDs
        catalogResults = catalogEvidence
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        processIDRequestCount += 1
        guard !processIDResults.isEmpty else {
            return .unknown(.unstableSnapshot)
        }
        return processIDResults.removeFirst()
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        catalogRequestCount += 1
        guard var results = catalogResults[processID], !results.isEmpty else {
            return .unknown(.unstableSnapshot)
        }
        let result = results.removeFirst()
        catalogResults[processID] = results
        return result
    }

    func authorizationEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        .unknown(.unstableSnapshot)
    }
}

private func makeOwnedCatalogEvidence(
    processID: Int32,
    startSeconds: UInt64
) throws -> DebuggerLocalProcessCatalogEvidence {
    let startTime = try XCTUnwrap(
        DebuggerProcessStartIdentity(seconds: startSeconds, microseconds: 7)
    )
    let fingerprint = try XCTUnwrap(
        DebuggerLocalProcessCatalogFingerprint(
            processID: processID,
            startTime: startTime,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScope-owned-\(processID)",
            executableDeviceID: 11,
            executableFileID: UInt64(processID) + 100,
            executableByteCount: 4_096,
            executableChangeTimeNanoseconds: 123,
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        )
    )
    return DebuggerLocalProcessCatalogEvidence(
        fingerprint: fingerprint,
        displayName: "MacScope owned helper",
        parentProcessID: 1,
        savedUserID: 501,
        dynamicState: DebuggerLocalProcessDynamicState()
    )
}

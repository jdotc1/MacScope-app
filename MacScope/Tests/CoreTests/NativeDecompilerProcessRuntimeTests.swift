import Foundation
import XCTest
@testable import MacScope

@MainActor
final class NativeDecompilerProcessRuntimeTests: XCTestCase {
    func testEpochExhaustionTerminallyShutsDownWithoutReuse() async throws {
        let authority = makeRuntimeSuccess(
            for: makeRuntimeSubmission(label: "epoch-exhaustion-authority", digestScalar: "e")
        ).availability.runtimeIdentity
        let runtime = NativeDecompilerProcessRuntime(
            authorityProvider: StaticRuntimeAuthorityProvider(identity: authority),
            initialEpoch: .max,
            operation: { _, _, _ in .terminal(.transportFailure) }
        )

        await runtime.replaceEpoch()

        let exhausted = await runtime.snapshot()
        XCTAssertEqual(exhausted.epoch, UInt64.max)
        XCTAssertTrue(exhausted.isShutDown)
        do {
            _ = try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "exhausted", digestScalar: "f"),
                queuedWeight: 1
            )
            XCTFail("an exhausted runtime must reject every successor submission")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .shutDown)
        }
    }

    func testIdenticalRequestsAcrossOwnersCoalesceIntoOneExecution() async throws {
        let harness = NativeProcessRuntimeHarness()
        let runtime = makeRuntime(harness: harness, outcome: .terminal(.transportFailure))
        let submission = makeRuntimeSubmission(label: "shared", digestScalar: "a")

        let first = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 4)
        }
        try await waitUntil { await harness.startedLabels == ["shared"] }
        let second = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 4)
        }
        try await waitUntil { await runtime.snapshot().scheduler.waiterCount == 2 }

        await harness.release("shared")
        let firstResult = try await first.value
        let secondResult = try await second.value

        XCTAssertEqual(firstResult.completion, .terminal(.transportFailure))
        XCTAssertEqual(secondResult.completion, .terminal(.transportFailure))
        let invocationCount = await harness.invocationCount
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(
            [firstResult.source, secondResult.source].contains(.executed(.started))
        )
        XCTAssertTrue(
            [firstResult.source, secondResult.source].contains(.executed(.joinedActive))
        )
    }

    func testCancellingOneCoalescedWaiterPreservesSiblingAndOperation() async throws {
        let harness = NativeProcessRuntimeHarness()
        let runtime = makeRuntime(harness: harness, outcome: .terminal(.transportFailure))
        let submission = makeRuntimeSubmission(label: "shared", digestScalar: "b")
        let cancelled = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 4)
        }
        try await waitUntil { await harness.invocationCount == 1 }
        let survivor = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 4)
        }
        try await waitUntil { await runtime.snapshot().scheduler.waiterCount == 2 }

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled waiter must not receive the shared result")
        } catch is CancellationError {}
        let cancellationsBeforeRelease = await harness.cancellationCount
        XCTAssertEqual(cancellationsBeforeRelease, 0)

        await harness.release("shared")
        let survivorResult = try await survivor.value
        let invocationCount = await harness.invocationCount
        let cancellationCount = await harness.cancellationCount
        XCTAssertEqual(survivorResult.completion, .terminal(.transportFailure))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    func testRoundRobinAdmissionServesQuietOwnerBeforeBusyOwnersNextEntry() async throws {
        let harness = NativeProcessRuntimeHarness()
        let runtime = makeRuntime(harness: harness, outcome: .terminal(.transportFailure))
        let ownerA = UUID()
        let ownerB = UUID()
        let a1 = Task {
            try await runtime.submit(
                owner: ownerA,
                submission: makeRuntimeSubmission(label: "a1", digestScalar: "1"),
                queuedWeight: 1
            )
        }
        try await waitUntil { await harness.startedLabels == ["a1"] }
        let a2 = Task {
            try await runtime.submit(
                owner: ownerA,
                submission: makeRuntimeSubmission(label: "a2", digestScalar: "2"),
                queuedWeight: 1
            )
        }
        let b1 = Task {
            try await runtime.submit(
                owner: ownerB,
                submission: makeRuntimeSubmission(label: "b1", digestScalar: "3"),
                queuedWeight: 1
            )
        }
        try await waitUntil { await runtime.snapshot().scheduler.queuedEntryCount == 2 }

        await harness.release("a1")
        _ = try await a1.value
        try await waitUntil { await harness.startedLabels.count == 2 }
        let firstRotation = await harness.startedLabels
        XCTAssertEqual(firstRotation, ["a1", "b1"])
        await harness.release("b1")
        _ = try await b1.value
        try await waitUntil { await harness.startedLabels.count == 3 }
        let completeRotation = await harness.startedLabels
        XCTAssertEqual(completeRotation, ["a1", "b1", "a2"])
        await harness.release("a2")
        _ = try await a2.value
    }

    func testValidatedSuccessCachesByRequestRuntimeIdentityAndEpoch() async throws {
        let harness = NativeProcessRuntimeHarness(autoRelease: true)
        let submission = makeRuntimeSubmission(label: "cached", digestScalar: "c")
        let success = makeRuntimeSuccess(for: submission)
        let runtime = makeRuntime(harness: harness, outcome: .ready(success))
        let owner = UUID()

        let first = try await runtime.submit(
            owner: owner,
            submission: submission,
            queuedWeight: 4
        )
        let second = try await runtime.submit(
            owner: owner,
            submission: submission,
            queuedWeight: 4
        )

        XCTAssertEqual(first.source, .executed(.started))
        XCTAssertEqual(second.source, .validatedCache)
        XCTAssertEqual(second.completion, .ready(success))
        let firstInvocationCount = await harness.invocationCount
        let cachedSnapshot = await runtime.snapshot()
        XCTAssertEqual(firstInvocationCount, 1)
        XCTAssertEqual(cachedSnapshot.validatedCacheEntryCount, 1)
        XCTAssertGreaterThan(cachedSnapshot.validatedCacheByteCount, 0)
        XCTAssertEqual(
            cachedSnapshot.admissionRecords.map(\.state),
            [.completed(.started), .validatedCache]
        )

        await runtime.replaceEpoch()
        _ = try await runtime.submit(owner: owner, submission: submission, queuedWeight: 4)
        let replacedInvocationCount = await harness.invocationCount
        XCTAssertEqual(replacedInvocationCount, 2)
    }

    func testValidatedCacheIsNotServedForADifferentContextOmissionSet() async throws {
        let harness = NativeProcessRuntimeHarness(autoRelease: true)
        let complete = makeRuntimeSubmission(label: "omission", digestScalar: "d")
        let omitted = makeRuntimeSubmission(
            label: "omission",
            digestScalar: "d",
            contextOmissions: NativeDecompilerContextOmissionManifest(
                omissions: [.init(subjectKind: .authoredFunction, startAddress: 0x2000,
                                  endAddressExclusive: 0x2010, reason: .budget, relevanceDistance: nil)],
                omittedNameCount: 0, omittedSignatureCount: 1, omittedAppliedTypeCount: 0
            )
        )
        // Identical wire bytes; only the explicit omission set differs.
        XCTAssertEqual(complete.projection.requestSHA256, omitted.projection.requestSHA256)
        XCTAssertNotEqual(complete.projection.contextOmissionSHA256, omitted.projection.contextOmissionSHA256)
        let success = makeRuntimeSuccess(for: complete)
        let runtime = makeRuntime(harness: harness, outcome: .ready(success))
        let owner = UUID()

        let first = try await runtime.submit(owner: owner, submission: complete, queuedWeight: 4)
        let second = try await runtime.submit(owner: owner, submission: omitted, queuedWeight: 4)
        let third = try await runtime.submit(owner: owner, submission: complete, queuedWeight: 4)

        XCTAssertEqual(first.source, .executed(.started))
        XCTAssertEqual(second.source, .executed(.started), "a different omission set must not hit the cache")
        XCTAssertEqual(third.source, .validatedCache)
        let invocationCount = await harness.invocationCount
        XCTAssertEqual(invocationCount, 2)
    }

    func testTerminalResultsAreNeverCached() async throws {
        let harness = NativeProcessRuntimeHarness(autoRelease: true)
        let runtime = makeRuntime(harness: harness, outcome: .terminal(.transportFailure))
        let submission = makeRuntimeSubmission(label: "failure", digestScalar: "d")

        _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)

        let invocationCount = await harness.invocationCount
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(snapshot.validatedCacheEntryCount, 0)
    }

    func testSameDigestWithDifferentAnalysisFingerprintDoesNotCoalesceOrHitCache() async throws {
        let harness = NativeProcessRuntimeHarness()
        let firstSubmission = makeRuntimeSubmission(
            label: "shared",
            digestScalar: "7",
            analysisFingerprintScalar: "a"
        )
        let secondSubmission = makeRuntimeSubmission(
            label: "shared",
            digestScalar: "7",
            analysisFingerprintScalar: "b"
        )
        let runtime = makeRuntime(
            harness: harness,
            outcome: .ready(makeRuntimeSuccess(for: firstSubmission))
        )
        let first = Task {
            try await runtime.submit(owner: UUID(), submission: firstSubmission, queuedWeight: 1)
        }
        try await waitUntil { await harness.invocationCount == 1 }
        let second = Task {
            try await runtime.submit(owner: UUID(), submission: secondSubmission, queuedWeight: 1)
        }

        await harness.release("shared")
        _ = try await first.value
        _ = try await second.value

        let invocationCount = await harness.invocationCount
        let cacheEntryCount = await runtime.snapshot().validatedCacheEntryCount
        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(cacheEntryCount, 2)
    }

    func testValidatedCacheRejectsEntryAboveByteBudget() async throws {
        let harness = NativeProcessRuntimeHarness(autoRelease: true)
        let submission = makeRuntimeSubmission(label: "oversized", digestScalar: "6")
        let runtime = makeRuntime(
            harness: harness,
            outcome: .ready(makeRuntimeSuccess(for: submission)),
            configuration: .init(
                maximumValidatedCacheEntries: 8,
                maximumValidatedCacheBytes: 1
            )
        )

        _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)

        let invocationCount = await harness.invocationCount
        XCTAssertEqual(invocationCount, 2)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.validatedCacheEntryCount, 0)
        XCTAssertEqual(snapshot.validatedCacheByteCount, 0)
    }

    func testAdmissionLedgerIsBoundedAndSequenceOrdered() async throws {
        let harness = NativeProcessRuntimeHarness(autoRelease: true)
        let runtime = makeRuntime(
            harness: harness,
            outcome: .terminal(.transportFailure),
            configuration: .init(
                maximumValidatedCacheEntries: 0,
                maximumAdmissionRecords: 2
            )
        )
        var submittedRequestSHA256s: [String] = []
        for (label, scalar) in [("one", "1"), ("two", "2"), ("three", "3")] {
            let submission = makeRuntimeSubmission(
                label: label,
                digestScalar: Character(scalar)
            )
            submittedRequestSHA256s.append(submission.projection.requestSHA256)
            _ = try await runtime.submit(
                owner: UUID(),
                submission: submission,
                queuedWeight: 1
            )
        }

        let records = await runtime.snapshot().admissionRecords
        XCTAssertEqual(records.map(\.sequence), [2, 3])
        XCTAssertEqual(records.map(\.state), [.completed(.started), .completed(.started)])
        XCTAssertEqual(records.map(\.requestSHA256), Array(submittedRequestSHA256s.suffix(2)))
    }

    func testAdmissionLedgerExhaustionStopsRecordingWithoutSequenceReuse() async throws {
        let authority = makeRuntimeSuccess(
            for: makeRuntimeSubmission(label: "ledger-exhaustion-authority", digestScalar: "8")
        ).availability.runtimeIdentity
        let runtime = NativeDecompilerProcessRuntime(
            authorityProvider: StaticRuntimeAuthorityProvider(identity: authority),
            configuration: .init(
                maximumValidatedCacheEntries: 0,
                maximumAdmissionRecords: 2
            ),
            initialAdmissionSequence: .max,
            operation: { _, _, _ in .terminal(.transportFailure) }
        )

        _ = try await runtime.submit(
            owner: UUID(),
            submission: makeRuntimeSubmission(label: "exhausted-ledger", digestScalar: "9"),
            queuedWeight: 1
        )

        let records = await runtime.snapshot().admissionRecords
        XCTAssertEqual(records, [])
    }

    func testQueueWeightOverflowIsTypedAndStable() async throws {
        let harness = NativeProcessRuntimeHarness()
        let runtime = makeRuntime(
            harness: harness,
            outcome: .terminal(.transportFailure),
            configuration: .init(
                maximumQueuedEntries: 2,
                maximumQueuedWeight: 3,
                maximumValidatedCacheEntries: 0
            )
        )
        let active = Task {
            try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "active", digestScalar: "e"),
                queuedWeight: 100
            )
        }
        try await waitUntil { await harness.invocationCount == 1 }

        do {
            _ = try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "overflow", digestScalar: "f"),
                queuedWeight: 4
            )
            XCTFail("queued work above the aggregate bound must be rejected")
        } catch let error as FairSingleLaneSchedulerError {
            XCTAssertEqual(error, .queuedWeightLimitReached(limit: 3))
        }

        await harness.release("active")
        _ = try await active.value
    }

    func testEpochReplacementCancelsOldLaneAndSuppressesLateResult() async throws {
        let harness = NativeProcessRuntimeHarness()
        let runtime = makeRuntime(harness: harness, outcome: .terminal(.transportFailure))
        let obsolete = Task {
            try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "obsolete", digestScalar: "0"),
                queuedWeight: 1
            )
        }
        try await waitUntil { await harness.invocationCount == 1 }

        await runtime.replaceEpoch()
        do {
            _ = try await obsolete.value
            XCTFail("retired epoch must not publish")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .staleEpoch)
        }
        let cancellationCount = await harness.cancellationCount
        XCTAssertEqual(cancellationCount, 1)

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.epoch, 2)
        XCTAssertFalse(snapshot.scheduler.hasActiveEntry)
        XCTAssertEqual(snapshot.scheduler.waiterCount, 0)
    }

    func testAuthorityAttestationFailureRejectsWithoutDispatchOrCache() async throws {
        let invocationProbe = RuntimeInvocationProbe()
        let runtime = NativeDecompilerProcessRuntime(
            authorityProvider: ThrowingRuntimeAuthorityProvider()
        ) { _, _, _ in
            await invocationProbe.record()
            return .terminal(.transportFailure)
        }

        do {
            _ = try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "unattested", digestScalar: "4"),
                queuedWeight: 1
            )
            XCTFail("unattested runtime must reject before dispatch")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .runtimeAuthorityUnavailable)
        }

        let snapshot = await runtime.snapshot()
        let invocationCount = await invocationProbe.count
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(snapshot.authorityState, .unavailable)
        XCTAssertEqual(snapshot.validatedCacheEntryCount, 0)
        XCTAssertTrue(snapshot.admissionRecords.isEmpty)
    }

    func testTransitionBarrierRejectsAdmissionUntilFreshAuthorityIsInstalled() async throws {
        let submission = makeRuntimeSubmission(label: "barrier", digestScalar: "5")
        let authority = makeRuntimeSuccess(for: submission).availability.runtimeIdentity
        let provider = GatedRuntimeAuthorityProvider(identity: authority)
        let invocationProbe = RuntimeInvocationProbe()
        let runtime = NativeDecompilerProcessRuntime(authorityProvider: provider) { _, _, _ in
            await invocationProbe.record()
            return .terminal(.transportFailure)
        }

        _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        await provider.gateNextAttestation()
        let transition = Task { await runtime.replaceEpoch() }
        try await waitUntil { await provider.callCount == 2 }
        let transitioningSnapshot = await runtime.snapshot()
        XCTAssertEqual(transitioningSnapshot.authorityState, .transitioning)

        do {
            _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
            XCTFail("transitioning runtime must reject new admission")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .runtimeTransitionInProgress)
        }

        await provider.releaseAttestation()
        await transition.value
        let snapshot = await runtime.snapshot()
        let invocationCount = await invocationProbe.count
        XCTAssertEqual(snapshot.epoch, 2)
        XCTAssertEqual(snapshot.authorityState, .ready(authority))
        XCTAssertEqual(invocationCount, 1)
    }

    func testConcurrentInitialAdmissionsShareOneAuthorityAttestation() async throws {
        let firstSubmission = makeRuntimeSubmission(label: "cold-first", digestScalar: "a")
        let secondSubmission = makeRuntimeSubmission(label: "cold-second", digestScalar: "b")
        let firstExpectedSuccess = makeRuntimeSuccess(for: firstSubmission)
        let secondExpectedSuccess = makeRuntimeSuccess(for: secondSubmission)
        let authority = firstExpectedSuccess.availability.runtimeIdentity
        let provider = GatedRuntimeAuthorityProvider(identity: authority)
        let invocationProbe = RuntimeInvocationProbe()
        let runtime = NativeDecompilerProcessRuntime(authorityProvider: provider) { submission, _, _ in
            await invocationProbe.record()
            return .ready(
                submission.projection.requestSHA256 == firstSubmission.projection.requestSHA256
                    ? firstExpectedSuccess
                    : secondExpectedSuccess
            )
        }

        await provider.gateNextAttestation()
        let first = Task {
            try await runtime.submit(owner: UUID(), submission: firstSubmission, queuedWeight: 1)
        }
        try await waitUntil { await provider.callCount == 1 }
        let second = Task {
            try await runtime.submit(owner: UUID(), submission: secondSubmission, queuedWeight: 1)
        }
        try await waitUntil {
            await runtime.initialAuthorityAttestationWaiterCountForTesting() == 2
        }
        let heldState = await runtime.snapshot().authorityState
        let callsWhileHeld = await provider.callCount
        XCTAssertEqual(heldState, .transitioning)
        XCTAssertEqual(callsWhileHeld, 1)

        await provider.releaseAttestation()
        let firstResult = try await first.value
        let secondResult = try await second.value

        guard case let .ready(firstSuccess) = firstResult.completion,
              case let .ready(secondSuccess) = secondResult.completion else {
            return XCTFail("Both cold-start submissions should complete successfully")
        }
        XCTAssertEqual(firstSuccess, firstExpectedSuccess)
        XCTAssertEqual(secondSuccess, secondExpectedSuccess)
        let invocationCount = await invocationProbe.count
        let attestationCount = await provider.callCount
        let finalState = await runtime.snapshot().authorityState
        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(attestationCount, 1)
        XCTAssertEqual(finalState, .ready(authority))
    }

    func testCancellingOneInitialAttestationWaiterPreservesSibling() async throws {
        let cancelledSubmission = makeRuntimeSubmission(label: "cold-cancelled", digestScalar: "c")
        let survivingSubmission = makeRuntimeSubmission(label: "cold-survivor", digestScalar: "d")
        let expectedSurvivingSuccess = makeRuntimeSuccess(for: survivingSubmission)
        let authority = expectedSurvivingSuccess.availability.runtimeIdentity
        let provider = GatedRuntimeAuthorityProvider(identity: authority)
        let invocationProbe = RuntimeInvocationProbe()
        let runtime = NativeDecompilerProcessRuntime(authorityProvider: provider) { submission, _, _ in
            await invocationProbe.record()
            XCTAssertEqual(submission.projection.requestSHA256, survivingSubmission.projection.requestSHA256)
            return .ready(expectedSurvivingSuccess)
        }

        await provider.gateNextAttestation()
        let cancelled = Task {
            try await runtime.submit(owner: UUID(), submission: cancelledSubmission, queuedWeight: 1)
        }
        try await waitUntil { await provider.callCount == 1 }
        let survivor = Task {
            try await runtime.submit(owner: UUID(), submission: survivingSubmission, queuedWeight: 1)
        }
        try await waitUntil {
            await runtime.initialAuthorityAttestationWaiterCountForTesting() == 2
        }
        cancelled.cancel()
        await provider.releaseAttestation()

        do {
            _ = try await cancelled.value
            XCTFail("A cancelled admission waiter must not receive a result")
        } catch is CancellationError {}
        let survivingResult = try await survivor.value
        guard case let .ready(success) = survivingResult.completion else {
            return XCTFail("The uncancelled sibling should complete successfully")
        }
        XCTAssertEqual(success, expectedSurvivingSuccess)
        let invocationCount = await invocationProbe.count
        let attestationCount = await provider.callCount
        let finalState = await runtime.snapshot().authorityState
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(attestationCount, 1)
        XCTAssertEqual(finalState, .ready(authority))
    }

    func testLifecycleReplacementInvalidatesInFlightInitialAttestation() async throws {
        let submission = makeRuntimeSubmission(label: "initial-attestation", digestScalar: "7")
        let authority = makeRuntimeSuccess(for: submission).availability.runtimeIdentity
        let provider = GatedRuntimeAuthorityProvider(identity: authority)
        let invocationProbe = RuntimeInvocationProbe()
        let runtime = NativeDecompilerProcessRuntime(authorityProvider: provider) { _, _, _ in
            await invocationProbe.record()
            return .terminal(.transportFailure)
        }

        await provider.gateNextAttestation()
        let staleAdmission = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        }
        try await waitUntil { await provider.callCount == 1 }

        await runtime.replaceEpoch()
        try await waitUntil { await provider.callCount == 2 }
        let replacedSnapshot = await runtime.snapshot()
        XCTAssertEqual(replacedSnapshot.epoch, 2)
        XCTAssertEqual(replacedSnapshot.authorityState, .ready(authority))

        await provider.releaseAttestation()
        do {
            _ = try await staleAdmission.value
            XCTFail("pre-transition attestation must not reopen admission")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .staleEpoch)
        }

        let invocationCount = await invocationProbe.count
        let finalSnapshot = await runtime.snapshot()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(finalSnapshot.epoch, 2)
        XCTAssertEqual(finalSnapshot.authorityState, .ready(authority))
        XCTAssertEqual(finalSnapshot.validatedCacheEntryCount, 0)
        XCTAssertTrue(finalSnapshot.admissionRecords.isEmpty)
    }

    func testStaleFailingInitialAttestationCannotOverwriteReadySuccessor() async throws {
        let submission = makeRuntimeSubmission(label: "stale-failing-attestation", digestScalar: "2")
        let authority = makeRuntimeSuccess(for: submission).availability.runtimeIdentity
        let provider = GatedFirstFailureRuntimeAuthorityProvider(identity: authority)
        let runtime = NativeDecompilerProcessRuntime(authorityProvider: provider) { _, _, _ in
            .terminal(.transportFailure)
        }

        let staleAdmission = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        }
        try await waitUntil { await provider.callCount == 1 }

        await runtime.replaceEpoch(cause: .invalidated, connectionGeneration: 1)
        let successor = await runtime.snapshot()
        XCTAssertEqual(successor.authorityState, .ready(authority))

        await provider.releaseFirstFailure()
        do {
            _ = try await staleAdmission.value
            XCTFail("stale failed attestation must not reopen or retire authority")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .staleEpoch)
        }

        let finalSnapshot = await runtime.snapshot()
        XCTAssertEqual(finalSnapshot.authorityState, .ready(authority))
        XCTAssertEqual(finalSnapshot.epoch, 2)
    }

    func testMismatchedSuccessIdentityCannotEscapeOrEnterValidatedCache() async throws {
        let submission = makeRuntimeSubmission(label: "mismatch", digestScalar: "6")
        let expectedSuccess = makeRuntimeSuccess(for: submission)
        let expectedIdentity = expectedSuccess.availability.runtimeIdentity
        let mismatchedSuccess = NativeDecompilerWireSuccess(
            availability: .init(
                available: true,
                reasonCode: "",
                runtimeIdentity: .init(
                    backendID: "forged-backend",
                    engineVersion: expectedIdentity.engineVersion,
                    engineRevision: expectedIdentity.engineRevision,
                    wrapperVersion: expectedIdentity.wrapperVersion,
                    wrapperRevision: expectedIdentity.wrapperRevision,
                    packageManifestSHA256: expectedIdentity.packageManifestSHA256,
                    packageTreeSHA256: expectedIdentity.packageTreeSHA256,
                    languageID: expectedIdentity.languageID,
                    compilerSpecID: expectedIdentity.compilerSpecID,
                    targetProfileID: expectedIdentity.targetProfileID,
                    contextProfileSHA256: expectedIdentity.contextProfileSHA256
                ),
                capabilities: expectedSuccess.availability.capabilities
            ),
            result: expectedSuccess.result
        )
        let invocationProbe = RuntimeInvocationProbe()
        let runtime = NativeDecompilerProcessRuntime(
            authorityProvider: StaticRuntimeAuthorityProvider(identity: expectedIdentity)
        ) { _, _, _ in
            await invocationProbe.record()
            return .ready(mismatchedSuccess)
        }

        for _ in 0 ..< 2 {
            do {
                _ = try await runtime.submit(
                    owner: UUID(),
                    submission: submission,
                    queuedWeight: 1
                )
                XCTFail("a reply-supplied runtime identity must never escape validation")
            } catch let error as NativeDecompilerRuntimeValidationError {
                XCTAssertEqual(error, .replyRuntimeIdentityMismatch)
            }
        }

        let snapshot = await runtime.snapshot()
        let invocationCount = await invocationProbe.count
        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(snapshot.validatedCacheEntryCount, 0)
        XCTAssertEqual(snapshot.validatedCacheByteCount, 0)
    }

    func testStaleLifecycleGenerationCannotRetireReattestedSuccessor() async throws {
        let submission = makeRuntimeSubmission(label: "lifecycle-generation", digestScalar: "7")
        let success = makeRuntimeSuccess(for: submission)
        let runtime = NativeDecompilerProcessRuntime(
            authorityProvider: StaticRuntimeAuthorityProvider(
                identity: success.availability.runtimeIdentity
            )
        ) { _, _, _ in .ready(success) }

        _ = try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        await runtime.replaceEpoch(cause: .interrupted, connectionGeneration: 2)
        let successor = await runtime.snapshot()
        XCTAssertEqual(successor.epoch, 2)

        await runtime.replaceEpoch(cause: .invalidated, connectionGeneration: 1)
        let afterStaleEvent = await runtime.snapshot()
        XCTAssertEqual(afterStaleEvent.epoch, 2)
        XCTAssertEqual(afterStaleEvent.authorityState, successor.authorityState)
    }

    func testNewerLifecycleGenerationSupersedesAttestationAlreadyInProgress() async throws {
        let submission = makeRuntimeSubmission(label: "overlapping-lifecycle", digestScalar: "1")
        let authority = makeRuntimeSuccess(for: submission).availability.runtimeIdentity
        let provider = GatedRuntimeAuthorityProvider(identity: authority)
        let runtime = NativeDecompilerProcessRuntime(authorityProvider: provider) { _, _, _ in
            .terminal(.transportFailure)
        }

        await provider.gateNextAttestation()
        let firstTransition = Task {
            await runtime.replaceEpoch(cause: .interrupted, connectionGeneration: 1)
        }
        try await waitUntil { await provider.callCount == 1 }

        await runtime.replaceEpoch(cause: .invalidated, connectionGeneration: 2)
        await provider.releaseAttestation()
        await firstTransition.value

        let snapshot = await runtime.snapshot()
        let providerCallCount = await provider.callCount
        XCTAssertEqual(providerCallCount, 2)
        XCTAssertEqual(snapshot.epoch, 3)
        XCTAssertEqual(snapshot.authorityState, .ready(authority))
    }

    func testShutdownRejectsNewWorkAndDrainsTheActiveOperation() async throws {
        let harness = NativeProcessRuntimeHarness()
        let runtime = makeRuntime(harness: harness, outcome: .terminal(.transportFailure))
        let active = Task {
            try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "shutdown", digestScalar: "9"),
                queuedWeight: 1
            )
        }
        try await waitUntil { await harness.invocationCount == 1 }

        await runtime.shutdown()
        _ = try? await active.value
        let cancellationCount = await harness.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        do {
            _ = try await runtime.submit(
                owner: UUID(),
                submission: makeRuntimeSubmission(label: "late", digestScalar: "8"),
                queuedWeight: 1
            )
            XCTFail("terminal runtime must reject new work")
        } catch let error as NativeDecompilerProcessRuntimeError {
            XCTAssertEqual(error, .shutDown)
        }
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.isShutDown)
    }

    func testShutdownReturnsWithinBoundWhenOperationIgnoresCancellation() async throws {
        let submission = makeRuntimeSubmission(label: "noncooperative-shutdown", digestScalar: "8")
        let success = makeRuntimeSuccess(for: submission)
        let invocationProbe = RuntimeInvocationProbe()
        let gate = NativeDecompilerNonCooperativeGate()
        let runtime = NativeDecompilerProcessRuntime(
            authorityProvider: StaticRuntimeAuthorityProvider(
                identity: success.availability.runtimeIdentity
            )
        ) { _, _, _ in
            await invocationProbe.record()
            await gate.wait()
            return .ready(success)
        }
        let active = Task {
            try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1)
        }
        try await waitUntil { await invocationProbe.count == 1 }

        let clock = ContinuousClock()
        let started = clock.now
        await runtime.shutdown()
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(2))
        await gate.release()
        _ = try? await active.value
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.isShutDown)
    }

    /// The service SIGKILLs itself past its hard deadline (wall budget + grace); the client
    /// then sees the connection interrupted and the epoch is replaced. A request that had run
    /// past that deadline is reported as timed out, not as an epoch race.
    func testInterruptionPastTheServiceHardDeadlineReportsTimedOut() async throws {
        for (label, wait, expectTimedOut) in [
            ("deadline-kill", NativeDecompilerProductBudgetProfile.clientReplyMargin + .milliseconds(10), true),
            ("early-interrupt", Duration.seconds(5), false),
        ] {
            let base = makeRuntimeSubmission(label: label, digestScalar: expectTimedOut ? "7" : "8")
            let submission = try NativeDecompilerSubmission(
                projection: base.projection,
                analysisInputFingerprintSHA256: base.analysisInputFingerprintSHA256,
                elapsedTimeBudget: wait
            )
            let authority = makeRuntimeSuccess(for: submission).availability.runtimeIdentity
            let gate = NativeDeadlineTestGate()
            let runtime = NativeDecompilerProcessRuntime(
                authorityProvider: StaticRuntimeAuthorityProvider(identity: authority)
            ) { _, _, _ in
                await gate.enterAndWait()
                return .terminal(.client(.interrupted))
            }
            let running = Task { try await runtime.submit(owner: UUID(), submission: submission, queuedWeight: 1) }
            try await waitUntil { await gate.entered }
            if expectTimedOut { try await Task.sleep(for: .milliseconds(600)) }
            let retiringEpoch = await runtime.snapshot().epoch
            let transition = Task { await runtime.replaceEpoch(cause: .interrupted, connectionGeneration: 1) }
            let transitionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                let snapshot = await runtime.snapshot()
                if snapshot.authorityState == .transitioning || snapshot.epoch > retiringEpoch {
                    break
                }
                guard ContinuousClock.now < transitionDeadline else {
                    await gate.release()
                    await transition.value
                    _ = try? await running.value
                    throw NativeProcessRuntimeTestError.timedOut
                }
                await Task.yield()
            }
            await gate.release()
            await transition.value
            do {
                let execution = try await running.value
                XCTAssertTrue(expectTimedOut, "\(label) must stay an epoch race")
                XCTAssertEqual(execution.completion, .terminal(.client(.timedOut)), label)
            } catch let error as NativeDecompilerProcessRuntimeError {
                XCTAssertFalse(expectTimedOut, "\(label) was reported as \(error)")
                XCTAssertEqual(error, .staleEpoch, label)
            }
        }
    }

    private func makeRuntime(
        harness: NativeProcessRuntimeHarness,
        outcome: NativeDecompilerCompletion,
        configuration: NativeDecompilerProcessRuntimeConfiguration = .init()
    ) -> NativeDecompilerProcessRuntime {
        let authority = outcome.runtimeIdentity
            ?? makeRuntimeSuccess(
                for: makeRuntimeSubmission(label: "authority", digestScalar: "a")
            ).availability.runtimeIdentity
        return NativeDecompilerProcessRuntime(
            authorityProvider: StaticRuntimeAuthorityProvider(identity: authority),
            configuration: configuration
        ) { submission, _, _ in
            try await harness.run(label: submission.projection.function.name)
            return outcome
        }
    }
}

private extension NativeDecompilerCompletion {
    var runtimeIdentity: NativeDecompilerRuntimeIdentity? {
        guard case let .ready(success) = self else { return nil }
        return success.availability.runtimeIdentity
    }
}

private struct StaticRuntimeAuthorityProvider: NativeDecompilerRuntimeAuthorityProviding {
    let identity: NativeDecompilerRuntimeIdentity
    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity { identity }
}

private struct ThrowingRuntimeAuthorityProvider: NativeDecompilerRuntimeAuthorityProviding {
    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity {
        throw NativeDecompilerRuntimeAuthorityAttestationError.peerRequirementRejected
    }
}

private actor GatedRuntimeAuthorityProvider: NativeDecompilerRuntimeAuthorityProviding {
    let identity: NativeDecompilerRuntimeIdentity
    private(set) var callCount = 0
    private var shouldGate = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(identity: NativeDecompilerRuntimeIdentity) { self.identity = identity }

    func gateNextAttestation() { shouldGate = true }

    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity {
        callCount += 1
        if shouldGate {
            shouldGate = false
            await withCheckedContinuation { continuation = $0 }
        }
        return identity
    }

    func releaseAttestation() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedFirstFailureRuntimeAuthorityProvider:
    NativeDecompilerRuntimeAuthorityProviding
{
    let identity: NativeDecompilerRuntimeIdentity
    private(set) var callCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    init(identity: NativeDecompilerRuntimeIdentity) { self.identity = identity }

    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
            throw NativeDecompilerRuntimeAuthorityAttestationError.peerRequirementRejected
        }
        return identity
    }

    func releaseFirstFailure() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor RuntimeInvocationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor NativeDecompilerNonCooperativeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor NativeProcessRuntimeHarness {
    private(set) var startedLabels: [String] = []
    private(set) var cancellationCount = 0
    private var released: Set<String> = []
    private let autoRelease: Bool

    init(autoRelease: Bool = false) {
        self.autoRelease = autoRelease
    }

    var invocationCount: Int { startedLabels.count }

    func run(label: String) async throws {
        startedLabels.append(label)
        guard !autoRelease else { return }
        do {
            while !released.contains(label) {
                try await Task.sleep(for: .milliseconds(1))
            }
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func release(_ label: String) {
        released.insert(label)
    }
}

private func makeRuntimeSubmission(
    label: String,
    digestScalar: Character,
    analysisFingerprintScalar: Character = "f",
    contextOmissions: NativeDecompilerContextOmissionManifest = .empty
) -> NativeDecompilerSubmission {
    let bytes = Data([0xc0, 0x03, 0x5f, 0xd6])
    let target = try! NativeDecompilerSealedTargetProfile.normalizedTarget(
        rawCPUType: 0x0100_000c,
        rawCPUSubtype: 0,
        selectedSliceSHA256: String(repeating: digestScalar, count: 64),
        selectedSliceByteCount: UInt64(bytes.count)
    )
    let image = NativeDecompilerWireImageIdentity(
        imageID: "image:runtime",
        uuid: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        preferredLoadAddress: .init(0x1000)
    )
    let function = NativeDecompilerWireFunctionIdentity(
        functionID: "function:\(label)",
        name: label,
        entryAddress: .init(0x1000),
        endAddressExclusive: .init(0x1004)
    )
    let memoryRegions = [
        NativeDecompilerWireMemoryRegion(
            name: "__text",
            startAddress: .init(0x1000),
            permissions: .readExecute,
            rawBytes: bytes,
            effectiveBytes: bytes,
            appliedPatchIDs: []
        ),
    ]
    let symbols: [NativeDecompilerWireSymbolRecord] = []
    let authoredInputs = NativeDecompilerWireAuthoredInputs.empty
    let budgets = NativeDecompilerProductBudgetProfile.v1
    let requestSHA256 = try! NativeDecompilerWireCanonicalRequest.sha256(
        schemaVersion: NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
        operation: .decompile,
        target: target,
        image: image,
        function: function,
        memoryRegions: memoryRegions,
        symbols: symbols,
        authoredInputs: authoredInputs,
        budgets: budgets
    )
    let request = NativeDecompilerWireRequest(
        requestID: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
        requestSHA256: requestSHA256,
        target: target,
        image: image,
        function: function,
        memoryRegions: memoryRegions,
        symbols: symbols,
        authoredInputs: authoredInputs,
        budgets: budgets.wireValue
    )
    return try! NativeDecompilerSubmission(
        projection: .init(request: request, contextOmissions: contextOmissions),
        analysisInputFingerprintSHA256:
            String(repeating: analysisFingerprintScalar, count: 64),
        elapsedTimeBudget: .seconds(5)
    )
}

private func makeRuntimeSuccess(
    for submission: NativeDecompilerSubmission
) -> NativeDecompilerWireSuccess {
    let request = submission.projection.makeRequestEnvelope(requestID: UUID()).body
    let result = NativeDecompilerWireStructuredResult(
        requestID: request.requestID,
        requestSHA256: request.requestSHA256,
        image: request.image,
        function: request.function,
        addressSpaces: [],
        types: [],
        instructions: [],
        varnodes: [],
        operations: [],
        blocks: [],
        edges: [],
        ssaValues: [],
        ssaBindings: [],
        phis: [],
        memoryVersions: [],
        memoryPhis: [],
        memoryEffects: [],
        variables: [],
        calls: [],
        regions: [],
        tokens: [],
        warnings: []
    )
    return NativeDecompilerWireSuccess(
        availability: .init(
            available: true,
            reasonCode: "",
            runtimeIdentity: .init(
                backendID: "native-decompiler",
                engineVersion: "12.1.2",
                engineRevision: String(repeating: "b", count: 40),
                wrapperVersion: "dcp05c-v3",
                wrapperRevision: String(repeating: "c", count: 40),
                packageManifestSHA256: String(repeating: "d", count: 64),
                packageTreeSHA256: String(repeating: "e", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon",
                compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: String(repeating: "f", count: 64)
            ),
            capabilities: .init(
                nativeDecompilerHeritage: true,
                completeRegisterSSA: false,
                memorySSA: false,
                recoveredVariables: false,
                recoveredTypes: false,
                structuredControlFlow: true,
                tokenizedPseudocode: false,
                imageQualifiedSourceRanges: true
            )
        ),
        result: result
    )
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw NativeProcessRuntimeTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum NativeProcessRuntimeTestError: Error {
    case timedOut
}

private actor NativeDeadlineTestGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

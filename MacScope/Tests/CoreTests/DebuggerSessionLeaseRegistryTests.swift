import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class DebuggerSessionLeaseRegistryTests: XCTestCase {
    func testReserveAndArmMintNonReplayableExactAttachPermit() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: authority
        )

        let reservedState = try await registry.state(for: reservation)
        XCTAssertEqual(reservedState, .reservedBeforeWrite)
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 7
        )
        XCTAssertEqual(permit.leaseGeneration, reservation.generation)
        XCTAssertEqual(permit.authority, authority)
        XCTAssertEqual(permit.adapterGeneration, 7)
        XCTAssertEqual(permit.correlationToken.count, 32)
        XCTAssertEqual(permit.bindingDigest.count, 32)
        XCTAssertNotEqual(permit.correlationToken, permit.bindingDigest)
        let armedState = try await registry.state(for: reservation)
        XCTAssertEqual(armedState, .exactAttachArmed)

        let countAfterConfirmation = await registry.activeLeaseCount
        XCTAssertEqual(countAfterConfirmation, 1)
        await assertReservationRejected(
            registry,
            authority: authority,
            expected: .identityAlreadyReserved
        )
    }

    func testArmingRejectsStalePolicyVectorBeforePhaseTransition() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            hostProcessID: 9_999,
            attachWriteInterlock: interlock
        )
        let authority = attachedAuthority(try identity())
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: authority
        )
        let staleSnapshot = interlock.currentSnapshot
        _ = try await ownedRegistry.beginSpawn()

        do {
            _ = try await registry.armExactAttach(
                reservation,
                admissionSession: DebuggerSessionCoordinate(
                    epoch: epoch,
                    lifecycleRevision: .initial
                ),
                adapterGeneration: 1,
                attachWriteInterlockSnapshot: staleSnapshot
            )
            XCTFail("A stale policy vector must not advance the lease to armed.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .attachWriteInterlockMismatch
            )
        }
        let stateAfterRejectedArm = try await registry.state(for: reservation)
        XCTAssertEqual(stateAfterRejectedArm, .reservedBeforeWrite)
    }

    func testPhaseOnlyArmingPreservesLeaseMembershipRevision() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: attachedAuthority(try identity())
        )
        let before = try await registry.observationSnapshot()
        let snapshot = interlock.currentSnapshot

        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 1,
            attachWriteInterlockSnapshot: snapshot
        )

        let after = try await registry.observationSnapshot()
        XCTAssertEqual(after.membershipRevision, before.membershipRevision)
        XCTAssertEqual(interlock.currentSnapshot, snapshot)
        XCTAssertEqual(permit.observationPolicyRevision, snapshot.revision)
        XCTAssertEqual(permit.attachWriteInterlockIdentity, snapshot.identity)
    }

    func testCrossedInterlockSnapshotFailsClosedAtArm() async throws {
        let first = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: first)
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: attachedAuthority(try identity())
        )
        let foreign = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: first.currentSnapshot.revision
        )

        do {
            _ = try await registry.armExactAttach(
                reservation,
                admissionSession: DebuggerSessionCoordinate(
                    epoch: epoch,
                    lifecycleRevision: .initial
                ),
                adapterGeneration: 1,
                attachWriteInterlockSnapshot: foreign.currentSnapshot
            )
            XCTFail("Equal numeric revisions from a foreign interlock must not arm.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .attachWriteInterlockMismatch
            )
        }
        let stateAfterCrossedArm = try await registry.state(for: reservation)
        XCTAssertEqual(stateAfterCrossedArm, .reservedBeforeWrite)
    }

    func testExactIdentityAndSameInstanceExecAreRejectedBySeparateIndexes() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let original = try identity()
        let originalAuthority = attachedAuthority(original)
        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: originalAuthority
        )

        do {
            _ = try await registry.reserve(
                ownerID: owner(),
                sessionEpoch: DebuggerSessionEpoch(),
                authority: originalAuthority
            )
            XCTFail("An exact identity must be globally exclusive across windows.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .identityAlreadyReserved
            )
        }

        let execIdentity = try identity(
            executableFileID: original.executableFileID + 1,
            executableSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(
            DebuggerLocalProcessInstanceKey(identity: original),
            DebuggerLocalProcessInstanceKey(identity: execIdentity)
        )
        XCTAssertNotEqual(original, execIdentity)

        do {
            _ = try await registry.reserve(
                ownerID: owner(),
                sessionEpoch: DebuggerSessionEpoch(),
                authority: attachedAuthority(execIdentity)
            )
            XCTFail("A same-kernel-process exec must remain excluded by the instance index.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .processInstanceAlreadyReserved
            )
        }
    }

    func testPIDReuseAndDifferentProcessesUsingSameExecutableDoNotAlias() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let first = try identity(processID: 801)
        let reusedPID = try identity(
            processID: 801,
            startTime: try start(seconds: 9_000_002)
        )
        let otherProcess = try identity(
            processID: 802,
            startTime: try start(seconds: 9_000_003)
        )

        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(first)
        )
        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(reusedPID)
        )
        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(otherProcess)
        )

        let activeLeaseCount = await registry.activeLeaseCount
        XCTAssertEqual(activeLeaseCount, 3)
    }

    func testConcurrentDuplicateReservationHasExactlyOneWinner() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())

        let winners = await withTaskGroup(
            of: DebuggerSessionLeaseReservation?.self,
            returning: [DebuggerSessionLeaseReservation].self
        ) { group in
            for _ in 0..<64 {
                group.addTask {
                    try? await registry.reserve(
                        ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
                        sessionEpoch: DebuggerSessionEpoch(),
                        authority: authority
                    )
                }
            }

            var reservations: [DebuggerSessionLeaseReservation] = []
            for await reservation in group {
                if let reservation { reservations.append(reservation) }
            }
            return reservations
        }

        XCTAssertEqual(winners.count, 1)
        let activeLeaseCount = await registry.activeLeaseCount
        XCTAssertEqual(activeLeaseCount, 1)
    }

    func testOneOwnerCannotHoldTwoDifferentProcessLeases() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let ownerID = owner()
        let first = try await registry.reserve(
            ownerID: ownerID,
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(try identity(
                processID: 1_201,
                startTime: try start(seconds: 12_001)
            ))
        )

        do {
            _ = try await registry.reserve(
                ownerID: ownerID,
                sessionEpoch: DebuggerSessionEpoch(),
                authority: attachedAuthority(try identity(
                    processID: 1_202,
                    startTime: try start(seconds: 12_002)
                ))
            )
            XCTFail("One controller owner must not acquire a second live lease.")
        } catch let error as DebuggerSessionLeaseRegistryError {
            XCTAssertEqual(error, .ownerAlreadyReserved)
        }

        try await registry.cancelBeforeTransportWrite(first)
        _ = try await registry.reserve(
            ownerID: ownerID,
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(try identity(
                processID: 1_202,
                startTime: try start(seconds: 12_002)
            ))
        )
        let activeLeaseCount = await registry.activeLeaseCount
        XCTAssertEqual(activeLeaseCount, 1)
    }

    func testRetiredOwnerCannotResurrectAfterItsFinalLeaseIsRemoved() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let retiredOwner = owner()
        let reservation = try await registry.reserve(
            ownerID: retiredOwner,
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(try identity(
                processID: 1_203,
                startTime: try start(seconds: 12_003)
            ))
        )

        await registry.retireOwner(retiredOwner)
        try await registry.cancelBeforeTransportWrite(reservation)

        do {
            _ = try await registry.reserve(
                ownerID: retiredOwner,
                sessionEpoch: DebuggerSessionEpoch(),
                authority: attachedAuthority(try identity(
                    processID: 1_204,
                    startTime: try start(seconds: 12_004)
                ))
            )
            XCTFail("A retired controller owner must remain permanently fenced.")
        } catch let error as DebuggerSessionLeaseRegistryError {
            XCTAssertEqual(error, .ownerRetired)
        }

        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(try identity(
                processID: 1_204,
                startTime: try start(seconds: 12_004)
            ))
        )
        let activeLeaseCount = await registry.activeLeaseCount
        XCTAssertEqual(activeLeaseCount, 1)
    }

    func testCancelledTaskCannotReserveOrAdvanceGeneration() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())
        let cancelledAttempt = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await registry.reserve(
                ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
                sessionEpoch: DebuggerSessionEpoch(),
                authority: authority
            )
        }

        do {
            _ = try await cancelledAttempt.value
            XCTFail("A cancelled task must not acquire debugger authority.")
        } catch is CancellationError {
            // Expected: cancellation is checked before generation or either index mutates.
        }
        let countAfterCancellation = await registry.activeLeaseCount
        XCTAssertEqual(countAfterCancellation, 0)

        let firstReservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: authority
        )
        XCTAssertEqual(firstReservation.generation.rawValue, 1)
    }

    func testDifferentProcessReservationsRemainParallelUnderConcurrency() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authorities = try (0..<32).map { offset in
            attachedAuthority(try identity(
                processID: Int32(1_000 + offset),
                startTime: try start(seconds: UInt64(10_000 + offset))
            ))
        }

        let winnerCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for authority in authorities {
                group.addTask {
                    do {
                        _ = try await registry.reserve(
                            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
                            sessionEpoch: DebuggerSessionEpoch(),
                            authority: authority
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var count = 0
            for await won in group where won { count += 1 }
            return count
        }

        XCTAssertEqual(winnerCount, authorities.count)
        let activeLeaseCount = await registry.activeLeaseCount
        XCTAssertEqual(activeLeaseCount, authorities.count)
    }

    func testCancellationReleasesOnlyBeforeExactAttachIsArmed() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())
        let beforeWrite = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: authority
        )

        try await registry.cancelBeforeTransportWrite(beforeWrite)
        let countAfterCancellation = await registry.activeLeaseCount
        XCTAssertEqual(countAfterCancellation, 0)

        let afterWrite = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: authority
        )
        _ = try await registry.armExactAttach(
            afterWrite,
            admissionSession: DebuggerSessionCoordinate(
                epoch: afterWrite.sessionEpoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 1
        )
        do {
            try await registry.cancelBeforeTransportWrite(afterWrite)
            XCTFail("Possible post-write ownership must not be released as cancellation.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .invalidStateTransition
            )
        }
        let countAfterRejectedCancellation = await registry.activeLeaseCount
        XCTAssertEqual(countAfterRejectedCancellation, 1)
    }

    func testArmedLeasePinsBothIndexesWithoutSealedFailureOrTerminalEvidence() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let original = try identity()
        let authority = attachedAuthority(original)
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: authority
        )
        _ = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 3
        )
        let armedState = try await registry.state(for: reservation)
        XCTAssertEqual(armedState, .exactAttachArmed)

        for blockedIdentity in [
            original,
            try identity(
                executableFileID: original.executableFileID + 1,
                executableSHA256: String(repeating: "c", count: 64)
            )
        ] {
            do {
                _ = try await registry.reserve(
                    ownerID: owner(),
                    sessionEpoch: DebuggerSessionEpoch(),
                    authority: attachedAuthority(blockedIdentity)
                )
                XCTFail("Unknown disposition must retain both exact indexes.")
            } catch {
                XCTAssertTrue(error is DebuggerSessionLeaseRegistryError)
            }
        }

        let countWhileArmed = await registry.activeLeaseCount
        XCTAssertEqual(countWhileArmed, 1)
    }

    func testArmingRequiresExactSessionEpochAndAttachedAuthority() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: authority
        )
        do {
            _ = try await registry.armExactAttach(
                reservation,
                admissionSession: DebuggerSessionCoordinate(
                    epoch: DebuggerSessionEpoch(),
                    lifecycleRevision: .initial
                ),
                adapterGeneration: 1
            )
            XCTFail("A foreign reducer epoch must not arm a lease.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .targetAuthorityMismatch
            )
        }

        _ = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 1
        )
    }

    func testStaleGenerationTokenCannotCancelOrUnblockAReacquiredLease() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())
        let first = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: authority
        )
        try await registry.cancelBeforeTransportWrite(first)

        let second = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: authority
        )
        XCTAssertNotEqual(first.generation, second.generation)

        do {
            try await registry.cancelBeforeTransportWrite(first)
            XCTFail("An old generation token must never release a reacquired lease.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .staleReservation
            )
        }
        let secondState = try await registry.state(for: second)
        XCTAssertEqual(secondState, .reservedBeforeWrite)
        await assertReservationRejected(
            registry,
            authority: authority,
            expected: .identityAlreadyReserved
        )
    }

    func testTerminalShapedEnumsCannotReleaseAnArmedLease() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let authority = attachedAuthority(try identity())
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: authority
        )
        _ = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 11
        )

        // These values are deliberately ordinary data, not release capabilities. There is no
        // production API that accepts one as proof; trying the only caller-owned cleanup token
        // remains fail-closed after a possible write.
        let terminalShapes: [DebuggerTargetDisposition] = [
            .detached,
            .terminated,
            .exited(code: 0),
        ]
        XCTAssertEqual(terminalShapes.count, 3)
        do {
            try await registry.cancelBeforeTransportWrite(reservation)
            XCTFail("Terminal-shaped data must not turn a caller-owned token into release proof.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .invalidStateTransition
            )
        }
        let state = try await registry.state(for: reservation)
        XCTAssertEqual(state, .exactAttachArmed)
        await assertReservationRejected(
            registry,
            authority: authority,
            expected: .identityAlreadyReserved
        )
    }

    func testAuthenticExactAttachConfirmationPerformsExactlyTwoObservations() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let provider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)]
        )
        let registry = DebuggerSessionLeaseRegistry(processEvidenceProvider: provider)
        let attachment = try await authenticAttachment(
            identity: selectedIdentity,
            registry: registry
        )

        let confirmation = try await registry.confirmExactAttach(attachment.result)
        let finalState = try await registry.state(for: attachment.reservation)
        let observationCount = await provider.observationCount

        XCTAssertEqual(confirmation.attachedSession, attachment.result.attachedSession)
        XCTAssertEqual(finalState, .confirmed)
        XCTAssertEqual(observationCount, 2)
    }

    func testReplayIsNonSettleableAndCannotReleaseClaimedLeaseBeforeConfirmation() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let provider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)]
        )
        let registry = DebuggerSessionLeaseRegistry(processEvidenceProvider: provider)
        let attachment = try await authenticAttachment(
            identity: selectedIdentity,
            registry: registry
        )
        let replayInput = PersistentLLDBExactAttachTransactionInput(
            request: DebuggerLocalAttachRequest(selectedIdentity: selectedIdentity),
            permit: attachment.result.attachedSession.permit
        )
        let claimedState = try await registry.state(for: attachment.reservation)
        XCTAssertEqual(claimedState, .exactAttachClaimed)
        let executionCountBeforeReplay = await attachment.executor.executionCountValue()

        do {
            _ = try await attachment.coordinator.performExactAttachTransaction(replayInput)
            XCTFail("A spent permit must reject replay.")
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            XCTFail("Replay must not expose registry-settleable evidence: \(failure)")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
        } catch {
            XCTFail("Replay must be an ordinary admission failure: \(error)")
        }

        let executionCountAfterReplay = await attachment.executor.executionCountValue()
        XCTAssertEqual(executionCountAfterReplay, executionCountBeforeReplay)
        let countBeforeConfirmation = await registry.activeLeaseCount
        XCTAssertEqual(countBeforeConfirmation, 1)
        let stateBeforeConfirmation = try await registry.state(for: attachment.reservation)
        XCTAssertEqual(stateBeforeConfirmation, .exactAttachClaimed)
        _ = try await registry.confirmExactAttach(attachment.result)
        let confirmedState = try await registry.state(for: attachment.reservation)
        let countAfterConfirmation = await registry.activeLeaseCount
        XCTAssertEqual(confirmedState, .confirmed)
        XCTAssertEqual(countAfterConfirmation, 1)
    }

    func testCancellationAfterFirstObservationCannotTruncateConfirmation() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let provider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)],
            suspendFirstObservation: true
        )
        let registry = DebuggerSessionLeaseRegistry(processEvidenceProvider: provider)
        let attachment = try await authenticAttachment(
            identity: selectedIdentity,
            registry: registry
        )
        let confirmationTask = Task {
            try await registry.confirmExactAttach(attachment.result)
        }

        await provider.waitUntilFirstObservationStarts()
        let confirmingState = try await registry.state(for: attachment.reservation)
        XCTAssertEqual(confirmingState, .confirming)
        confirmationTask.cancel()
        await provider.resumeFirstObservation()
        let confirmation = try await confirmationTask.value
        let observationCount = await provider.observationCount
        let cancellationStates = await provider.cancellationStates
        let finalState = try await registry.state(for: attachment.reservation)

        XCTAssertEqual(confirmation.attachedSession, attachment.result.attachedSession)
        XCTAssertEqual(observationCount, 2)
        XCTAssertEqual(cancellationStates, [false, false])
        XCTAssertEqual(finalState, .confirmed)
    }

    func testIdentityDriftDuringAuthenticConfirmationPinsDispositionUnknown() async throws {
        let selectedIdentity = try identity()
        let driftedIdentity = try identity(
            executableFileID: selectedIdentity.executableFileID + 1,
            executableSHA256: String(repeating: "d", count: 64)
        )
        let provider = LeaseRegistryEvidenceProvider(
            observations: [
                .resolved(try authorizationEvidence(identity: selectedIdentity)),
                .resolved(try authorizationEvidence(identity: driftedIdentity)),
            ]
        )
        let registry = DebuggerSessionLeaseRegistry(processEvidenceProvider: provider)
        let attachment = try await authenticAttachment(
            identity: selectedIdentity,
            registry: registry
        )

        do {
            _ = try await registry.confirmExactAttach(attachment.result)
            XCTFail("Identity drift must prevent exact-attach confirmation.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .identityProofFailed
            )
        }

        let observationCount = await provider.observationCount
        let finalState = try await registry.state(for: attachment.reservation)
        XCTAssertEqual(observationCount, 2)
        XCTAssertEqual(finalState, .dispositionUnknown)
        await assertReservationRejected(
            registry,
            authority: attachedAuthority(selectedIdentity),
            expected: .identityAlreadyReserved
        )
    }

    func testConfirmationActorSuspensionBlocksSameIdentityButPermitsIndependentIdentity() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let provider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)],
            suspendFirstObservation: true
        )
        let registry = DebuggerSessionLeaseRegistry(processEvidenceProvider: provider)
        let attachment = try await authenticAttachment(
            identity: selectedIdentity,
            registry: registry
        )
        let confirmationTask = Task {
            try await registry.confirmExactAttach(attachment.result)
        }

        await provider.waitUntilFirstObservationStarts()
        let confirmingState = try await registry.state(for: attachment.reservation)
        XCTAssertEqual(confirmingState, .confirming)
        await assertReservationRejected(
            registry,
            authority: attachedAuthority(selectedIdentity),
            expected: .identityAlreadyReserved
        )

        let independentIdentity = try identity(
            processID: selectedIdentity.processID + 1,
            startTime: try start(seconds: selectedIdentity.startTime.seconds + 1),
            executableFileID: selectedIdentity.executableFileID + 2,
            executableSHA256: String(repeating: "e", count: 64)
        )
        let independentReservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(independentIdentity)
        )
        let independentState = try await registry.state(for: independentReservation)
        XCTAssertEqual(independentState, .reservedBeforeWrite)

        await provider.resumeFirstObservation()
        _ = try await confirmationTask.value
        let finalState = try await registry.state(for: attachment.reservation)
        let activeLeaseCount = await registry.activeLeaseCount

        XCTAssertEqual(finalState, .confirmed)
        XCTAssertEqual(activeLeaseCount, 2)
    }

    func testExactExternalExitAbsenceAtomicallyReleasesLeaseAndBothIndexes() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let identityProvider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)]
        )
        let absenceProver = LeaseRegistryInstanceAbsenceProver(
            resolutions: [.resolved(.absent)]
        )
        let registry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: identityProvider,
            processInstanceAbsenceProver: absenceProver
        )
        let fixture = try await authenticExternalExit(
            identity: selectedIdentity,
            registry: registry
        )
        let before = try await registry.observationSnapshot()

        try await registry.completeExactAttachedExternalExitRelease(
            exit: fixture.exit,
            adapterRetirement: fixture.adapterRetirement
        )

        let after = try await registry.observationSnapshot()
        let activeLeaseCount = await registry.activeLeaseCount
        let absenceCallCount = await absenceProver.callCount
        let requestedKeys = await absenceProver.requestedKeys
        let expectedKey = DebuggerLocalProcessInstanceKey(identity: selectedIdentity)
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(after.excludedProcessInstances, [])
        XCTAssertEqual(
            after.membershipRevision.rawValue,
            before.membershipRevision.rawValue + 1
        )
        XCTAssertEqual(absenceCallCount, 1)
        XCTAssertEqual(requestedKeys, [expectedKey])
        do {
            _ = try await registry.state(for: fixture.reservation)
            XCTFail("External-exit release must retire the exact reservation.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .staleReservation)
        }
        let reacquired = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(selectedIdentity)
        )
        let reacquiredState = try await registry.state(for: reacquired)
        XCTAssertEqual(reacquiredState, .reservedBeforeWrite)

        do {
            _ = try await registry.observationSnapshot(
                excluding: fixture.exit.attachedSession.permit
            )
            XCTFail("A permit from the released generation must not authenticate reacquisition.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .staleReservation)
        }

        do {
            try await registry.completeExactAttachedExternalExitRelease(
                exit: fixture.exit,
                adapterRetirement: fixture.adapterRetirement
            )
            XCTFail("Evidence from a retired lease generation must not release a reacquisition.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .staleReservation)
        }
        let stateAfterStaleEvidence = try await registry.state(for: reacquired)
        let proofCountAfterStaleEvidence = await absenceProver.callCount
        let keysAfterStaleEvidence = await absenceProver.requestedKeys
        XCTAssertEqual(stateAfterStaleEvidence, .reservedBeforeWrite)
        XCTAssertEqual(proofCountAfterStaleEvidence, 1)
        XCTAssertEqual(keysAfterStaleEvidence, [expectedKey])
    }

    func testCrossedAdapterRetirementProofCannotReleaseAnotherAttachedSession() async throws {
        let firstIdentity = try identity()
        let secondIdentity = try identity(
            processID: firstIdentity.processID + 1,
            startTime: try start(seconds: firstIdentity.startTime.seconds + 1),
            executableFileID: firstIdentity.executableFileID + 1,
            executableSHA256: String(repeating: "f", count: 64)
        )
        let firstEvidence = try authorizationEvidence(identity: firstIdentity)
        let secondEvidence = try authorizationEvidence(identity: secondIdentity)
        let identityProvider = LeaseRegistryEvidenceProvider(
            observations: [
                .resolved(firstEvidence), .resolved(firstEvidence),
                .resolved(secondEvidence), .resolved(secondEvidence),
            ]
        )
        let absenceProver = LeaseRegistryInstanceAbsenceProver(
            resolutions: [.resolved(.absent)]
        )
        let registry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: identityProvider,
            processInstanceAbsenceProver: absenceProver
        )
        let first = try await authenticExternalExit(identity: firstIdentity, registry: registry)
        let second = try await authenticExternalExit(identity: secondIdentity, registry: registry)

        do {
            try await registry.completeExactAttachedExternalExitRelease(
                exit: first.exit,
                adapterRetirement: second.adapterRetirement
            )
            XCTFail("A retirement proof from another exact adapter must not release this lease.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .adapterRetirementProofMismatch
            )
        }

        let firstState = try await registry.state(for: first.reservation)
        let secondState = try await registry.state(for: second.reservation)
        let activeLeaseCount = await registry.activeLeaseCount
        let requestedKeys = await absenceProver.requestedKeys
        XCTAssertEqual(firstState, .confirmed)
        XCTAssertEqual(secondState, .confirmed)
        XCTAssertEqual(activeLeaseCount, 2)
        XCTAssertEqual(requestedKeys, [])
    }

    func testStillPresentExternalExitProofPinsSameEvidenceAndAllowsCommandFreeRetry() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let identityProvider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)]
        )
        let absenceProver = LeaseRegistryInstanceAbsenceProver(
            resolutions: [.resolved(.stillPresent), .resolved(.absent)]
        )
        let registry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: identityProvider,
            processInstanceAbsenceProver: absenceProver
        )
        let fixture = try await authenticExternalExit(
            identity: selectedIdentity,
            registry: registry
        )
        let before = try await registry.observationSnapshot()

        do {
            try await registry.completeExactAttachedExternalExitRelease(
                exit: fixture.exit,
                adapterRetirement: fixture.adapterRetirement
            )
            XCTFail("A still-present process instance must retain both lease indexes.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .identityProofFailed)
        }

        let pinnedState = try await registry.state(for: fixture.reservation)
        let pinnedSnapshot = try await registry.observationSnapshot()
        XCTAssertEqual(pinnedState, .dispositionUnknown)
        XCTAssertEqual(pinnedSnapshot, before)
        await assertReservationRejected(
            registry,
            authority: attachedAuthority(selectedIdentity),
            expected: .identityAlreadyReserved
        )

        // Retry consumes the same sealed exit and already command-free retirement proof. It must
        // not require or authorize another debugger command.
        try await registry.completeExactAttachedExternalExitRelease(
            exit: fixture.exit,
            adapterRetirement: fixture.adapterRetirement
        )
        let activeLeaseCount = await registry.activeLeaseCount
        let absenceCallCount = await absenceProver.callCount
        let requestedKeys = await absenceProver.requestedKeys
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(absenceCallCount, 2)
        XCTAssertEqual(
            requestedKeys,
            [
                DebuggerLocalProcessInstanceKey(identity: selectedIdentity),
                DebuggerLocalProcessInstanceKey(identity: selectedIdentity),
            ]
        )
    }

    func testUnknownExternalExitAbsenceRestoresDispositionUnknownWithoutRevisionAdvance() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let identityProvider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)]
        )
        let absenceProver = LeaseRegistryInstanceAbsenceProver(
            resolutions: [.unknown(.unstableSnapshot)]
        )
        let registry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: identityProvider,
            processInstanceAbsenceProver: absenceProver
        )
        let fixture = try await authenticExternalExit(
            identity: selectedIdentity,
            registry: registry
        )
        let before = try await registry.observationSnapshot()

        do {
            try await registry.completeExactAttachedExternalExitRelease(
                exit: fixture.exit,
                adapterRetirement: fixture.adapterRetirement
            )
            XCTFail("Unknown absence evidence must retain both lease indexes.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, .identityProofFailed)
        }

        let pinnedState = try await registry.state(for: fixture.reservation)
        let pinnedSnapshot = try await registry.observationSnapshot()
        let activeLeaseCount = await registry.activeLeaseCount
        let requestedKeys = await absenceProver.requestedKeys
        XCTAssertEqual(pinnedState, .dispositionUnknown)
        XCTAssertEqual(pinnedSnapshot, before)
        XCTAssertEqual(activeLeaseCount, 1)
        XCTAssertEqual(
            requestedKeys,
            [DebuggerLocalProcessInstanceKey(identity: selectedIdentity)]
        )
    }

    func testCancellationCannotTruncateExternalExitAbsenceSettlement() async throws {
        let selectedIdentity = try identity()
        let exactEvidence = try authorizationEvidence(identity: selectedIdentity)
        let identityProvider = LeaseRegistryEvidenceProvider(
            observations: [.resolved(exactEvidence), .resolved(exactEvidence)]
        )
        let absenceProver = LeaseRegistryInstanceAbsenceProver(
            resolutions: [.resolved(.absent)],
            suspendFirstProof: true
        )
        let registry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: identityProvider,
            processInstanceAbsenceProver: absenceProver
        )
        let fixture = try await authenticExternalExit(
            identity: selectedIdentity,
            registry: registry
        )
        let settlement = Task {
            try await registry.completeExactAttachedExternalExitRelease(
                exit: fixture.exit,
                adapterRetirement: fixture.adapterRetirement
            )
        }

        await absenceProver.waitUntilFirstProofStarts()
        let provingState = try await registry.state(for: fixture.reservation)
        XCTAssertEqual(provingState, .provingExternalExitRelease)
        settlement.cancel()
        await absenceProver.resumeFirstProof()
        try await settlement.value

        let activeLeaseCount = await registry.activeLeaseCount
        let cancellationStates = await absenceProver.cancellationStates
        let requestedKeys = await absenceProver.requestedKeys
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(cancellationStates, [false])
        XCTAssertEqual(
            requestedKeys,
            [DebuggerLocalProcessInstanceKey(identity: selectedIdentity)]
        )
    }

    private func assertReservationRejected(
        _ registry: DebuggerSessionLeaseRegistry,
        authority: DebuggerSessionTargetAuthority,
        expected: DebuggerSessionLeaseRegistryError
    ) async {
        do {
            _ = try await registry.reserve(
                ownerID: owner(),
                sessionEpoch: DebuggerSessionEpoch(),
                authority: authority
            )
            XCTFail("The exact lease indexes must remain blocked.")
        } catch {
            XCTAssertEqual(error as? DebuggerSessionLeaseRegistryError, expected)
        }
    }

    private func owner() -> DebuggerSessionLeaseOwnerID {
        DebuggerSessionLeaseOwnerID(rawValue: UUID())
    }

    private func start(seconds: UInt64 = 9_000_001) throws -> DebuggerProcessStartIdentity {
        try XCTUnwrap(DebuggerProcessStartIdentity(seconds: seconds, microseconds: 17))
    }

    private func identity(
        processID: Int32 = 800,
        startTime: DebuggerProcessStartIdentity? = nil,
        executableFileID: UInt64 = 7_001,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: try startTime ?? start(),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeLeaseFixture",
            executableDeviceID: 7,
            executableFileID: executableFileID,
            executableByteCount: 4_096,
            executableSHA256: executableSHA256,
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        ))
    }

    private func attachedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    private func launchedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
    }

    private func authenticAttachment(
        identity: DebuggerLocalProcessIdentity,
        registry: DebuggerSessionLeaseRegistry
    ) async throws -> (
        result: PersistentLLDBExactAttachTransactionResult,
        reservation: DebuggerSessionLeaseReservation,
        coordinator: PersistentLLDBSessionCoordinator,
        executor: LeaseRegistryExactAttachExecutor,
        bindingAdapter: PersistentLLDBCLIAdapter
    ) {
        let epoch = DebuggerSessionEpoch()
        let generation: UInt64 = 1
        let request = DebuggerLocalAttachRequest(selectedIdentity: identity)
        let bindingAdapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: LeaseRegistryBindingByteChannel(),
            retainedProcess: LeaseRegistryBindingRetainedProcess(),
            markerSecret: Data(repeating: 0x6c, count: 32)
        )
        let executor = LeaseRegistryExactAttachExecutor(
            epoch: epoch,
            attachRequest: request,
            generation: generation,
            adapterInstanceBinding: await bindingAdapter.adapterInstanceBinding()
        )
        let coordinator = PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: LeaseRegistryStatusRequestPreparer(),
            capabilities: DebuggerTransportCapabilities(
                operationStates: Dictionary(
                    uniqueKeysWithValues: DebuggerOperation.allCases.map {
                        ($0, DebuggerOperationCapability.supportedAndObserved)
                    }
                ),
                mechanics: .persistentCLI
            ),
            attachWriteInterlock: registry.attachWriteInterlock
        )
        let initial = await coordinator.reducerState
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: attachedAuthority(identity)
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: initial.sessionCoordinate,
            adapterGeneration: generation
        )
        await executor.configure(correlationToken: permit.correlationToken)
        let result = try await coordinator.performExactAttachTransaction(
            PersistentLLDBExactAttachTransactionInput(request: request, permit: permit)
        )
        return (result, reservation, coordinator, executor, bindingAdapter)
    }

    private func authenticExternalExit(
        identity: DebuggerLocalProcessIdentity,
        registry: DebuggerSessionLeaseRegistry
    ) async throws -> (
        exit: PersistentLLDBExactAttachedExternalExitResult,
        adapterRetirement: PersistentLLDBCLICommandFreeAdapterExitReapProof,
        reservation: DebuggerSessionLeaseReservation
    ) {
        let attachment = try await authenticAttachment(identity: identity, registry: registry)
        _ = try await registry.confirmExactAttach(attachment.result)
        let execution = try await attachment.coordinator.perform(
            .pollProcessStatus,
            expectedSession: attachment.result.attachedSession.establishedSession,
            requiredStop: nil
        )
        let exit = try await attachment.coordinator.sealExactAttachedExternalExitResult(
            attachedSession: attachment.result.attachedSession,
            executionResult: execution
        )
        let retirement = await attachment.bindingAdapter
            .retireExactAttachedAdapterWithoutDebuggerCommand(
                boundTo: attachment.result.attachedSession
            )
        guard case .proven(let proof) = retirement else {
            throw LeaseRegistryIntegrationTestError.adapterRetirementWasNotProven
        }
        return (exit, proof, attachment.reservation)
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
                displayName: "Lease registry fixture",
                parentProcessID: 1,
                savedUserID: identity.realUserID,
                dynamicState: .init()
            ),
            identity: identity
        )
    }
}

private actor LeaseRegistryEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private var observations:
        [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>]
    private let suspendFirstObservation: Bool
    private var firstObservationStarted = false
    private var firstObservationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstObservationContinuation: CheckedContinuation<Void, Never>?
    private(set) var observationCount = 0
    private(set) var cancellationStates: [Bool] = []

    init(
        observations: [
            DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>
        ],
        suspendFirstObservation: Bool = false
    ) {
        self.observations = observations
        self.suspendFirstObservation = suspendFirstObservation
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
        cancellationStates.append(Task.isCancelled)
        if observationCount == 1, suspendFirstObservation {
            firstObservationStarted = true
            let waiters = firstObservationStartWaiters
            firstObservationStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstObservationContinuation = continuation
            }
        }
        guard !observations.isEmpty else { return .unknown(.unstableSnapshot) }
        return observations.removeFirst()
    }

    func waitUntilFirstObservationStarts() async {
        if firstObservationStarted { return }
        await withCheckedContinuation { continuation in
            firstObservationStartWaiters.append(continuation)
        }
    }

    func resumeFirstObservation() {
        firstObservationContinuation?.resume()
        firstObservationContinuation = nil
    }
}

private actor LeaseRegistryExactAttachExecutor: PersistentLLDBCLIExecuting {
    private let epoch: DebuggerSessionEpoch
    private let attachRequest: DebuggerLocalAttachRequest
    private let generation: UInt64
    private let adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    private var correlationToken = Data()
    private var didCompleteExactAttach = false
    private var consumedStagingCommandCount = 0
    private var expectedStagingCommandCount: Int?
    private var executionCount = 0

    init(
        epoch: DebuggerSessionEpoch,
        attachRequest: DebuggerLocalAttachRequest,
        generation: UInt64,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    ) {
        self.epoch = epoch
        self.attachRequest = attachRequest
        self.generation = generation
        self.adapterInstanceBinding = adapterInstanceBinding
    }

    func exactAdapterInstanceBinding() -> PersistentLLDBCLIAdapterInstanceBinding? {
        adapterInstanceBinding
    }

    func configure(correlationToken: Data) {
        precondition(self.correlationToken.isEmpty)
        self.correlationToken = correlationToken
    }

    func execute(
        _ request: PersistentLLDBCLIRequest
    ) async throws -> PersistentLLDBCLIResponse {
        executionCount += 1
        switch request.writeRole {
        case .exactAttachStaging(let wrappedAuthorization?):
            let issuanceInput = wrappedAuthorization.issuanceInput
            guard !didCompleteExactAttach,
                  request.context == issuanceInput.stagingRequest,
                  request.observedPIDRequirement == .optional,
                  adapterInstanceBinding == issuanceInput.adapterInstanceBinding,
                  issuanceInput.stagingOrdinal == consumedStagingCommandCount,
                  expectedStagingCommandCount == nil
                    || expectedStagingCommandCount == issuanceInput.canonicalStagingCommandCount,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == issuanceInput.semanticDigest else {
                throw invalidExactAttachWrite(for: request)
            }
            do {
                try wrappedAuthorization.interlock
                    .consumeExactAttachStagingWriteAuthorization(
                        wrappedAuthorization.authorization,
                        matching: issuanceInput
                    )
            } catch {
                throw invalidExactAttachWrite(for: request)
            }
            expectedStagingCommandCount = issuanceInput.canonicalStagingCommandCount
            consumedStagingCommandCount += 1
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
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

        case .exactAttachFinal(let wrappedAuthorization?):
            let issuanceInput = wrappedAuthorization.issuanceInput
            guard !didCompleteExactAttach,
                  request.context == issuanceInput.finalAttachRequest,
                  request.observedPIDRequirement == .required,
                  adapterInstanceBinding == issuanceInput.adapterInstanceBinding,
                  consumedStagingCommandCount == expectedStagingCommandCount,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == issuanceInput.semanticDigest else {
                throw invalidExactAttachWrite(for: request)
            }
            let exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit
            do {
                exactAttachWriteCommit = try wrappedAuthorization.interlock
                    .commitExactAttachWrite(
                        wrappedAuthorization.grant,
                        matching: issuanceInput
                    )
            } catch {
                throw invalidExactAttachWrite(for: request)
            }
            didCompleteExactAttach = true

            let authority = DebuggerSessionTargetAuthority(
                origin: .attached(attachRequest.selectedIdentity)
            )
            let programRequest = try PersistentLLDBAttachProgramRequest(
                sessionEpoch: epoch,
                requestSequence: request.context.id.sequence,
                adapterGeneration: generation,
                authority: authority,
                correlationToken: correlationToken
            )
            let framedReceipt = PersistentLLDBAttachProgram.receiptSentinel
                + receiptBytes(for: programRequest).base64EncodedString()
                + "\n"
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
                generation: generation,
                transcript: LLDBCLITranscriptResult(
                    transcript: "",
                    authoritativeStatusTranscript: "",
                    observedProcessID: authority.processID,
                    observedProcessState: .stopped(processID: authority.processID),
                    exchangeByteCount: framedReceipt.utf8.count,
                    exchangeSHA256: String(repeating: "b", count: 64),
                    semanticCommandTranscripts: [framedReceipt],
                    semanticCommandResultLineByteCounts: [framedReceipt.utf8.count]
                ),
                exactAttachWriteCommit: exactAttachWriteCommit
            )

        case .ordinary:
            guard didCompleteExactAttach,
                  request.observedPIDRequirement == .required else {
                throw invalidExactAttachWrite(for: request)
            }
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

        case .exactAttachStaging(nil), .exactAttachFinal(nil):
            throw invalidExactAttachWrite(for: request)
        }
    }

    func executionCountValue() -> Int {
        executionCount
    }

    private func invalidExactAttachWrite(
        for request: PersistentLLDBCLIRequest
    ) -> PersistentLLDBCLIAdapterFailure {
        PersistentLLDBCLIAdapterFailure(
            code: .exactAttachWriteRejected,
            requestID: request.context.id,
            generation: generation,
            disposition: .failedBeforeWrite
        )
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

private actor LeaseRegistryRejectingRequestPreparer: PersistentLLDBCLIRequestPreparing {
    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        throw LeaseRegistryIntegrationTestError.genericPreparerMustNotBeUsed
    }
}

private actor LeaseRegistryStatusRequestPreparer: PersistentLLDBCLIRequestPreparing {
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

private enum LeaseRegistryIntegrationTestError: Error {
    case genericPreparerMustNotBeUsed
    case adapterRetirementWasNotProven
}

private actor LeaseRegistryInstanceAbsenceProver:
    DebuggerLocalProcessInstanceAbsenceProving {
    private var resolutions: [
        DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation>
    ]
    private let suspendFirstProof: Bool
    private var firstProofStarted = false
    private var firstProofStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstProofContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private(set) var cancellationStates: [Bool] = []
    private(set) var requestedKeys: [DebuggerLocalProcessInstanceKey] = []

    init(
        resolutions: [
            DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation>
        ],
        suspendFirstProof: Bool = false
    ) {
        self.resolutions = resolutions
        self.suspendFirstProof = suspendFirstProof
    }

    func proveProcessInstanceAbsent(
        _ expected: DebuggerLocalProcessInstanceKey
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation> {
        callCount += 1
        cancellationStates.append(Task.isCancelled)
        requestedKeys.append(expected)
        if callCount == 1, suspendFirstProof {
            firstProofStarted = true
            let waiters = firstProofStartWaiters
            firstProofStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstProofContinuation = continuation
            }
        }
        guard !resolutions.isEmpty else { return .unknown(.unstableSnapshot) }
        return resolutions.removeFirst()
    }

    func waitUntilFirstProofStarts() async {
        guard !firstProofStarted else { return }
        await withCheckedContinuation { continuation in
            firstProofStartWaiters.append(continuation)
        }
    }

    func resumeFirstProof() {
        firstProofContinuation?.resume()
        firstProofContinuation = nil
    }
}

private actor LeaseRegistryBindingByteChannel: PersistentLLDBCLIByteChannel {
    func write(_ data: Data) async throws {}
    func nextBytes() async throws -> Data? { nil }
    func closeInput() async {}
    func closeHandles() async {}
}

private actor LeaseRegistryBindingRetainedProcess: PersistentLLDBCLIRetainedProcess {
    func waitForExit(maximumDuration: Duration) async -> Bool { true }
    func terminateRetainedAdapter() async {}
    func killRetainedAdapterIfStillRunning() async -> Bool { false }
    func reapAndClose() async -> Bool { true }
}

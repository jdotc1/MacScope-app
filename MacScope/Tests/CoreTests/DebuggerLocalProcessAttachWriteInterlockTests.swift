import Foundation
import XCTest
@testable import MacScope

final class DebuggerLocalProcessAttachWriteInterlockTests: XCTestCase {
    private typealias PermitFixture = (
        epoch: DebuggerSessionEpoch,
        permit: DebuggerSessionLeaseExactAttachPermit,
        adapterBinding: PersistentLLDBCLIAdapterInstanceBinding
    )

    func testRevisionCommitsAreExactSuccessorsAndRunMutationUnderAuthority() throws {
        let initial = revision(owned: 4, lease: 9)
        let interlock = DebuggerLocalProcessAttachWriteInterlock(initialRevision: initial)
        var committedMutations: [String] = []

        try interlock.commitOwnedInfrastructureRevision(
            from: initial.ownedInfrastructure,
            to: DebuggerOwnedInfrastructureRevision(rawValue: 5)
        ) {
            committedMutations.append("owned")
        }
        let afterOwned = revision(owned: 5, lease: 9)
        XCTAssertTrue(interlock.validatesCurrentRevision(afterOwned))

        try interlock.commitLeaseMembershipRevision(
            from: afterOwned.leaseMembership,
            to: DebuggerSessionLeaseMembershipRevision(rawValue: 10)
        ) {
            committedMutations.append("lease")
        }
        XCTAssertEqual(committedMutations, ["owned", "lease"])
        XCTAssertTrue(interlock.validatesCurrentRevision(revision(owned: 5, lease: 10)))

        XCTAssertThrowsError(
            try interlock.commitOwnedInfrastructureRevision(
                from: DebuggerOwnedInfrastructureRevision(rawValue: 4),
                to: DebuggerOwnedInfrastructureRevision(rawValue: 5)
            ) {
                committedMutations.append("stale")
            }
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .revisionMismatch
            )
        }
        XCTAssertThrowsError(
            try interlock.commitLeaseMembershipRevision(
                from: DebuggerSessionLeaseMembershipRevision(rawValue: 10),
                to: DebuggerSessionLeaseMembershipRevision(rawValue: 12)
            ) {
                committedMutations.append("skipped")
            }
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .nonSuccessorRevision
            )
        }
        XCTAssertEqual(committedMutations, ["owned", "lease"])
    }

    func testExactFailureLeaseRemovalExcludesConcurrentPermitClaim() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let expectedRevision = interlock.currentSnapshot.revision.leaseMembership
        let nextRevision = DebuggerSessionLeaseMembershipRevision(
            rawValue: expectedRevision.rawValue + 1
        )
        let claimInput = try XCTUnwrap(
            DebuggerLocalProcessExactAttachTransactionClaimInput(
                policyRevision: interlock.currentSnapshot.revision,
                interlockIdentity: interlock.identity,
                permit: fixture.permit,
                finalAttachRequest: attachContext(fixture: fixture, sequence: 500)
            )
        )
        let removalEntered = DispatchSemaphore(value: 0)
        let releaseRemoval = DispatchSemaphore(value: 0)
        let claimFinished = AttachWriteInterlockLockedFlag()

        let removalTask = Task.detached(priority: .userInitiated) {
            try interlock.commitExactAttachFailureLeaseRemoval(
                permit: fixture.permit,
                claim: nil,
                disposition: .definitelyNotDispatchedOrWritten,
                from: expectedRevision,
                to: nextRevision
            ) {
                removalEntered.signal()
                releaseRemoval.wait()
            }
        }

        XCTAssertEqual(removalEntered.wait(timeout: .now() + 1), .success)
        let claimTask = Task.detached(priority: .userInitiated) {
            defer { claimFinished.set() }
            do {
                _ = try interlock.claimExactAttachTransaction(claimInput)
                return nil as DebuggerLocalProcessAttachWriteInterlockError?
            } catch {
                return error as? DebuggerLocalProcessAttachWriteInterlockError
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            claimFinished.value,
            "The permit claim must block while failure settlement owns the interlock lock."
        )
        releaseRemoval.signal()
        try await removalTask.value

        let claimError = await claimTask.value
        XCTAssertEqual(claimError, .revisionMismatch)
        XCTAssertTrue(
            interlock.validatesCurrentRevision(revision(owned: 0, lease: nextRevision.rawValue))
        )
        XCTAssertFalse(interlock.hasBegunExactAttachTransaction(for: fixture.permit))
    }

    func testExactGrantCommitsOnceWithEveryFrozenBinding() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let transaction = try claimTransaction(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500
        )
        try consumeAllStaging(
            interlock: interlock,
            fixture: fixture,
            transaction: transaction
        )
        let input = try makeFinalIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            transaction: transaction
        )
        let grant = try interlock.issueExactAttachWriteGrant(for: input)
        let copiedGrant = grant
        var writeCommitCount = 0

        XCTAssertThrowsError(try interlock.issueExactAttachWriteGrant(for: input)) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .finalGrantAlreadyIssued
            )
        }

        let commit = try interlock.commitExactAttachWrite(grant, matching: input)
        writeCommitCount += 1
        XCTAssertEqual(writeCommitCount, 1)
        XCTAssertEqual(commit.interlockIdentity, interlock.identity)
        XCTAssertEqual(commit.requestID, input.finalAttachRequest.id)
        XCTAssertEqual(commit.bindingDigest, input.bindingDigest)
        XCTAssertTrue(interlock.validatesExactAttachWriteCommit(
            commit,
            for: copiedGrant,
            matching: input
        ))
        XCTAssertThrowsError(
            try interlock.commitExactAttachWrite(copiedGrant, matching: input)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .grantAlreadyConsumed
            )
        }
        XCTAssertEqual(writeCommitCount, 1)
    }

    func testRevisionAdvanceBetweenIssuanceAndCommitRejectsWithoutWrite() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let vector = interlock.currentSnapshot.revision
        let transaction = try claimTransaction(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500
        )
        try consumeAllStaging(
            interlock: interlock,
            fixture: fixture,
            transaction: transaction
        )
        let input = try makeFinalIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            transaction: transaction
        )
        let grant = try interlock.issueExactAttachWriteGrant(for: input)

        try interlock.commitOwnedInfrastructureRevision(
            from: vector.ownedInfrastructure,
            to: DebuggerOwnedInfrastructureRevision(rawValue: 1)
        ) {}

        var didWrite = false
        XCTAssertThrowsError(
            try interlock.commitExactAttachWrite(grant, matching: input)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .revisionMismatch
            )
        }
        XCTAssertFalse(didWrite)
    }

    func testCrossedBindingsAndCrossedInterlockAreRejected() async throws {
        let first = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: first)
        let second = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: first.currentSnapshot.revision
        )
        let transaction = try claimTransaction(
            interlock: first,
            fixture: fixture,
            finalRequestSequence: 500
        )
        try consumeAllStaging(
            interlock: first,
            fixture: fixture,
            transaction: transaction
        )
        let input = try makeFinalIssuanceInput(
            interlock: first,
            fixture: fixture,
            transaction: transaction
        )
        let crossedContext = attachContext(fixture: fixture, sequence: 501)
        let crossedCommand = try canonicalCommands(
            fixture: fixture,
            finalRequestSequence: 501
        ).last
        let crossed = try XCTUnwrap(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: first.currentSnapshot.revision,
            interlockIdentity: first.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            finalAttachRequest: crossedContext,
            semanticDigest: try XCTUnwrap(
                DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommand: try XCTUnwrap(crossedCommand)
                )
            ),
            transactionClaim: transaction.claim
        ))
        let grant = try first.issueExactAttachWriteGrant(for: input)
        var didWrite = false

        XCTAssertThrowsError(
            try first.commitExactAttachWrite(grant, matching: crossed)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .grantBindingMismatch
            )
        }
        XCTAssertThrowsError(
            try second.commitExactAttachWrite(grant, matching: input)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .foreignGrant
            )
        }
        XCTAssertFalse(didWrite)

        _ = try first.commitExactAttachWrite(grant, matching: input)
        didWrite = true
        XCTAssertTrue(didWrite)
    }

    func testIssuanceRejectsStalePolicyAndNonExactAttachCorrelations() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let vector = interlock.currentSnapshot.revision
        let wrongOperation = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: fixture.epoch, sequence: 1),
            operation: .launch,
            expectedSession: fixture.permit.admissionSession,
            targetAuthority: fixture.permit.authority
        )
        let semanticDigest = try XCTUnwrap(
            DebuggerLocalProcessAttachWriteSemanticDigest(
                semanticCommand: "script final-attach"
            )
        )
        let exactRequest = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: fixture.epoch, sequence: 2),
            operation: .attach,
            expectedSession: fixture.permit.admissionSession,
            targetAuthority: fixture.permit.authority
        )
        XCTAssertNil(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: revision(owned: 0, lease: 0),
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            finalAttachRequest: exactRequest,
            semanticDigest: semanticDigest
        ))
        let foreignInterlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: vector
        )
        XCTAssertNil(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: vector,
            interlockIdentity: foreignInterlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            finalAttachRequest: exactRequest,
            semanticDigest: semanticDigest
        ))
        XCTAssertNil(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: vector,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            finalAttachRequest: wrongOperation,
            semanticDigest: semanticDigest
        ))
        XCTAssertNil(DebuggerLocalProcessAttachWriteSemanticDigest(
            semanticCommands: ["script one", "script two"]
        ))

        let foreignAdapter = await makeAdapterBinding(epoch: DebuggerSessionEpoch())
        XCTAssertNil(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: vector,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: foreignAdapter,
            finalAttachRequest: exactRequest,
            semanticDigest: semanticDigest
        ))
    }

    func testCanonicalStagingAuthorizationIsOneShotAndExactOrdinalBound() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let transaction = try claimTransaction(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500
        )
        let first = try makeStagingIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500,
            stagingOrdinal: 0,
            transactionClaim: transaction.claim
        )
        let crossed = try makeStagingIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500,
            stagingOrdinal: 1,
            transactionClaim: transaction.claim
        )
        let authorization = try interlock.issueExactAttachStagingWriteAuthorization(for: first)
        let copiedAuthorization = authorization

        XCTAssertThrowsError(
            try interlock.consumeExactAttachStagingWriteAuthorization(
                authorization,
                matching: crossed
            )
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .stagingAuthorizationBindingMismatch
            )
        }

        try interlock.consumeExactAttachStagingWriteAuthorization(
            authorization,
            matching: first
        )
        XCTAssertThrowsError(
            try interlock.consumeExactAttachStagingWriteAuthorization(
                copiedAuthorization,
                matching: first
            )
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .stagingAuthorizationAlreadyConsumed
            )
        }
    }

    func testClaimEnforcesOrderedStagingAndFinalOnlyAfterEveryConsumption() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let transaction = try claimTransaction(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500
        )
        let second = try makeStagingIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500,
            stagingOrdinal: 1,
            transactionClaim: transaction.claim
        )
        XCTAssertThrowsError(
            try interlock.issueExactAttachStagingWriteAuthorization(for: second)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .stagingAuthorizationOutOfOrder
            )
        }

        let final = try makeFinalIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            transaction: transaction
        )
        XCTAssertThrowsError(try interlock.issueExactAttachWriteGrant(for: final)) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .finalGrantBeforeStagingComplete
            )
        }

        let first = try makeStagingIssuanceInput(
            interlock: interlock,
            fixture: fixture,
            finalRequestSequence: 500,
            stagingOrdinal: 0,
            transactionClaim: transaction.claim
        )
        let authorization = try interlock.issueExactAttachStagingWriteAuthorization(for: first)
        XCTAssertThrowsError(
            try interlock.issueExactAttachStagingWriteAuthorization(for: first)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerLocalProcessAttachWriteInterlockError,
                .stagingAuthorizationOutOfOrder
            )
        }
        try interlock.consumeExactAttachStagingWriteAuthorization(
            authorization,
            matching: first
        )
    }

    func testFinalAttachCommandCannotBeDowngradedToStagingAuthorization() async throws {
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: revision(owned: 0, lease: 0)
        )
        let fixture = try await makePermitFixture(interlock: interlock)
        let finalRequestSequence: UInt64 = 500
        let program = PersistentLLDBAttachProgram.current
        let request = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: fixture.permit.admissionSession.epoch,
            requestSequence: finalRequestSequence,
            adapterGeneration: fixture.permit.adapterGeneration,
            authority: fixture.permit.authority,
            correlationToken: fixture.permit.correlationToken
        )
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: request))
        let stagingCount = commands.count - 1
        let stagingCountValue = try XCTUnwrap(UInt64(exactly: stagingCount))
        let finalContext = attachContext(
            fixture: fixture,
            sequence: finalRequestSequence
        )
        let firstStagingContext = attachContext(
            fixture: fixture,
            sequence: finalRequestSequence - stagingCountValue
        )
        let finalDigest = try XCTUnwrap(
            DebuggerLocalProcessAttachWriteSemanticDigest(
                semanticCommand: try XCTUnwrap(commands.last)
            )
        )

        XCTAssertNil(DebuggerLocalProcessAttachStagingWriteIssuanceInput(
            policyRevision: interlock.currentSnapshot.revision,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            stagingRequest: firstStagingContext,
            finalAttachRequest: finalContext,
            stagingOrdinal: 0,
            semanticDigest: finalDigest
        ))
        XCTAssertNil(DebuggerLocalProcessAttachStagingWriteIssuanceInput(
            policyRevision: interlock.currentSnapshot.revision,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            stagingRequest: finalContext,
            finalAttachRequest: finalContext,
            stagingOrdinal: stagingCount,
            semanticDigest: finalDigest
        ))
    }

    private typealias ClaimedTransaction = (
        claim: DebuggerLocalProcessExactAttachTransactionClaim,
        finalRequestSequence: UInt64,
        commands: [String]
    )

    private func claimTransaction(
        interlock: DebuggerLocalProcessAttachWriteInterlock,
        fixture: PermitFixture,
        finalRequestSequence: UInt64
    ) throws -> ClaimedTransaction {
        let commands = try canonicalCommands(
            fixture: fixture,
            finalRequestSequence: finalRequestSequence
        )
        let input = try XCTUnwrap(DebuggerLocalProcessExactAttachTransactionClaimInput(
            policyRevision: interlock.currentSnapshot.revision,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            finalAttachRequest: attachContext(
                fixture: fixture,
                sequence: finalRequestSequence
            )
        ))
        let claim = try interlock.claimExactAttachTransaction(input)
        try interlock.bindExactAttachTransactionAdapter(fixture.adapterBinding, to: claim)
        return (claim, finalRequestSequence, commands)
    }

    private func makeFinalIssuanceInput(
        interlock: DebuggerLocalProcessAttachWriteInterlock,
        fixture: PermitFixture,
        transaction: ClaimedTransaction
    ) throws -> DebuggerLocalProcessAttachWriteIssuanceInput {
        let finalCommand = try XCTUnwrap(transaction.commands.last)
        return try XCTUnwrap(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: interlock.currentSnapshot.revision,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            finalAttachRequest: attachContext(
                fixture: fixture,
                sequence: transaction.finalRequestSequence
            ),
            semanticDigest: try XCTUnwrap(
                DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommand: finalCommand
                )
            ),
            transactionClaim: transaction.claim
        ))
    }

    private func consumeAllStaging(
        interlock: DebuggerLocalProcessAttachWriteInterlock,
        fixture: PermitFixture,
        transaction: ClaimedTransaction
    ) throws {
        for ordinal in 0..<(transaction.commands.count - 1) {
            let input = try makeStagingIssuanceInput(
                interlock: interlock,
                fixture: fixture,
                finalRequestSequence: transaction.finalRequestSequence,
                stagingOrdinal: ordinal,
                transactionClaim: transaction.claim
            )
            let authorization = try interlock
                .issueExactAttachStagingWriteAuthorization(for: input)
            try interlock.consumeExactAttachStagingWriteAuthorization(
                authorization,
                matching: input
            )
        }
    }

    private func canonicalCommands(
        fixture: PermitFixture,
        finalRequestSequence: UInt64
    ) throws -> [String] {
        let program = PersistentLLDBAttachProgram.current
        let request = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: fixture.permit.admissionSession.epoch,
            requestSequence: finalRequestSequence,
            adapterGeneration: fixture.permit.adapterGeneration,
            authority: fixture.permit.authority,
            correlationToken: fixture.permit.correlationToken
        )
        return program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: request))
    }

    private func makeStagingIssuanceInput(
        interlock: DebuggerLocalProcessAttachWriteInterlock,
        fixture: PermitFixture,
        finalRequestSequence: UInt64,
        stagingOrdinal: Int,
        transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim? = nil
    ) throws -> DebuggerLocalProcessAttachStagingWriteIssuanceInput {
        let program = PersistentLLDBAttachProgram.current
        let request = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: fixture.permit.admissionSession.epoch,
            requestSequence: finalRequestSequence,
            adapterGeneration: fixture.permit.adapterGeneration,
            authority: fixture.permit.authority,
            correlationToken: fixture.permit.correlationToken
        )
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: request))
        let stagingCount = commands.count - 1
        let stagingCountValue = try XCTUnwrap(UInt64(exactly: stagingCount))
        let ordinalValue = try XCTUnwrap(UInt64(exactly: stagingOrdinal))
        let firstStagingSequence = finalRequestSequence - stagingCountValue
        let semanticDigest = try XCTUnwrap(
            DebuggerLocalProcessAttachWriteSemanticDigest(
                semanticCommand: commands[stagingOrdinal]
            )
        )
        return try XCTUnwrap(DebuggerLocalProcessAttachStagingWriteIssuanceInput(
            policyRevision: interlock.currentSnapshot.revision,
            interlockIdentity: interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterBinding,
            stagingRequest: attachContext(
                fixture: fixture,
                sequence: firstStagingSequence + ordinalValue
            ),
            finalAttachRequest: attachContext(
                fixture: fixture,
                sequence: finalRequestSequence
            ),
            stagingOrdinal: stagingOrdinal,
            semanticDigest: semanticDigest,
            transactionClaim: transactionClaim
        ))
    }

    private func attachContext(
        fixture: PermitFixture,
        sequence: UInt64
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: DebuggerRequestID(epoch: fixture.epoch, sequence: sequence),
            operation: .attach,
            expectedSession: fixture.permit.admissionSession,
            targetAuthority: fixture.permit.authority
        )
    }

    private func makePermitFixture(
        interlock: DebuggerLocalProcessAttachWriteInterlock
    ) async throws -> PermitFixture {
        let epoch = DebuggerSessionEpoch()
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 8_801,
            startTime: try XCTUnwrap(
                DebuggerProcessStartIdentity(seconds: 9_000_101, microseconds: 23)
            ),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeAttachWriteInterlockFixture",
            executableDeviceID: 8,
            executableFileID: 8_801,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        ))
        let authority = DebuggerSessionTargetAuthority(origin: .attached(identity))
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 1,
            attachWriteInterlockSnapshot: interlock.currentSnapshot
        )
        let adapterBinding = await makeAdapterBinding(epoch: epoch)
        return (epoch, permit, adapterBinding)
    }

    private func makeAdapterBinding(
        epoch: DebuggerSessionEpoch
    ) async -> PersistentLLDBCLIAdapterInstanceBinding {
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: AttachWriteInterlockBindingChannel(),
            retainedProcess: AttachWriteInterlockBindingProcess(),
            markerSecret: Data(repeating: 0x31, count: 32)
        )
        return await adapter.adapterInstanceBinding()
    }

    private func revision(
        owned: UInt64,
        lease: UInt64
    ) -> DebuggerLocalProcessObservationPolicyRevisionVector {
        DebuggerLocalProcessObservationPolicyRevisionVector(
            ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: owned),
            leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: lease)
        )
    }
}

private final class AttachWriteInterlockLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private actor AttachWriteInterlockBindingChannel: PersistentLLDBCLIByteChannel {
    func write(_ data: Data) async throws {}
    func nextBytes() async throws -> Data? { nil }
    func closeInput() async {}
    func closeHandles() async {}
}

private actor AttachWriteInterlockBindingProcess: PersistentLLDBCLIRetainedProcess {
    func waitForExit(maximumDuration: Duration) async -> Bool { true }
    func terminateRetainedAdapter() async {}
    func killRetainedAdapterIfStillRunning() async -> Bool { false }
    func reapAndClose() async -> Bool { true }
}

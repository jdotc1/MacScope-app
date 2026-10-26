import Foundation

enum Phase2DurableShellSessionRecoveryIssue: String, Equatable, Sendable {
    case noRecoveryIdentity
    case invalidRecoveryIdentity
    case expiredRecoveryIdentity
    case secureAttachRejected
    case definitiveBrokerAbsence
}

enum Phase2DurableShellSessionCommitIssue: String, Equatable, Sendable {
    case provisionalLaunchMissingIdentity
    case invalidProvisionalIdentity
    case capabilityPersistenceFailed
    case publicLedgerPersistenceFailed
    case brokerCommitFailed
    case transactionSuperseded
}

enum Phase2DurableShellPublicLedgerRollbackOutcome: Equatable, Sendable {
    case cleared
    case clearanceUnproven
}

struct Phase2DurableShellSessionCommitResult: Equatable, Sendable {
    let projection: Phase2WorkspaceShellSessionProjection
    let issue: Phase2DurableShellSessionCommitIssue?
    let publicLedgerRollbackOutcome: Phase2DurableShellPublicLedgerRollbackOutcome?

    init(
        projection: Phase2WorkspaceShellSessionProjection,
        issue: Phase2DurableShellSessionCommitIssue?,
        publicLedgerRollbackOutcome: Phase2DurableShellPublicLedgerRollbackOutcome? = nil
    ) {
        self.projection = projection
        self.issue = issue
        self.publicLedgerRollbackOutcome = publicLedgerRollbackOutcome
    }

    var committed: Bool { issue == nil }
}

struct Phase2DurableShellSessionRecoveryResult: Equatable, Sendable {
    let projection: Phase2WorkspaceShellSessionProjection
    let issue: Phase2DurableShellSessionRecoveryIssue?

    var recovered: Bool {
        issue == nil && projection.isRunning
    }
}

/// Coordinates reopen recovery without owning credentials or transport.
///
/// The persisted projection contributes only a public identity. The injected operation owns the
/// Keychain lookup and authenticated broker attach, allowing package decoding to remain synchronous
/// while recovery is explicitly asynchronous and fail-closed.
struct Phase2DurableShellSessionCoordinator: Sendable {
    typealias SecureAttach = @Sendable (
        _ identity: Phase2DurableShellBrokerIdentity,
        _ restoredSnapshot: Phase2HumanPTYSessionSnapshot
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome

    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Completes a provisional launch in the required security order: capability secret, public
    /// workspace ledger, then explicit broker commit. A post-publication transaction failure cleans
    /// the broker first, then deletes the capability only when ledger rollback proves the public
    /// identity was cleared. A commit reply failure retains the durable records because the broker
    /// may already have committed; callers must recover status instead of launching a replacement.
    func commitProvisionalLaunch(
        previousProjection: Phase2WorkspaceShellSessionProjection,
        provisionalOutcome: Phase2HumanPTYShellSessionCommandOutcome,
        persistCapability: @Sendable (Phase2DurableShellBrokerIdentity) async throws -> Void,
        persistPublicLedger: @Sendable (Phase2WorkspaceShellSessionProjection) async throws -> Void,
        commitBrokerSession: @Sendable (Phase2DurableShellBrokerIdentity) async throws -> Void,
        validateTransaction: @Sendable () async -> Bool = { true },
        discardPublicLedger: @Sendable () async -> Phase2DurableShellPublicLedgerRollbackOutcome = {
            .clearanceUnproven
        },
        discardCapability: @Sendable (UUID) async -> Void,
        cleanupProvisionalBrokerSession: @Sendable (Phase2DurableShellBrokerIdentity) async -> Void
    ) async -> Phase2DurableShellSessionCommitResult {
        guard let identity = provisionalOutcome.brokerResponse?.durableIdentity else {
            return .init(projection: previousProjection, issue: .provisionalLaunchMissingIdentity)
        }
        guard identity.isStructurallyValid,
              provisionalOutcome.snapshot.sessionID == identity.sessionID,
              provisionalOutcome.snapshot.nextTranscriptSequence >= identity.nextTranscriptSequence else {
            await cleanupProvisionalBrokerSession(identity)
            return .init(projection: previousProjection, issue: .invalidProvisionalIdentity)
        }

        do {
            try await persistCapability(identity)
        } catch {
            await cleanupProvisionalBrokerSession(identity)
            await discardCapability(identity.capabilityID)
            return .init(projection: previousProjection, issue: .capabilityPersistenceFailed)
        }

        guard await validateTransaction() else {
            await cleanupProvisionalBrokerSession(identity)
            await discardCapability(identity.capabilityID)
            return .init(projection: previousProjection, issue: .transactionSuperseded)
        }

        let durableProjection = previousProjection.accepted(provisionalOutcome)
        do {
            try await persistPublicLedger(durableProjection)
        } catch {
            await cleanupProvisionalBrokerSession(identity)
            await discardCapability(identity.capabilityID)
            return .init(projection: previousProjection, issue: .publicLedgerPersistenceFailed)
        }

        guard await validateTransaction() else {
            await cleanupProvisionalBrokerSession(identity)
            let rollbackOutcome = await discardPublicLedger()
            if rollbackOutcome == .cleared {
                await discardCapability(identity.capabilityID)
            }
            return .init(
                projection: rollbackOutcome == .cleared ? previousProjection : durableProjection,
                issue: .transactionSuperseded,
                publicLedgerRollbackOutcome: rollbackOutcome
            )
        }

        do {
            try await commitBrokerSession(identity)
            return .init(projection: durableProjection, issue: nil)
        } catch {
            return .init(projection: durableProjection, issue: .brokerCommitFailed)
        }
    }

    func recover(
        _ projection: Phase2WorkspaceShellSessionProjection,
        secureAttach: SecureAttach
    ) async -> Phase2DurableShellSessionRecoveryResult {
        guard let identity = projection.durableRecoveryIdentity else {
            return failed(projection, issue: .noRecoveryIdentity)
        }
        guard identity.isStructurallyValid,
              identity.sessionID == projection.snapshot?.sessionID else {
            return failed(projection, issue: .invalidRecoveryIdentity)
        }
        guard now() < identity.expiresAt else {
            return failed(projection, issue: .expiredRecoveryIdentity)
        }
        guard let restoredSnapshot = projection.snapshot else {
            return failed(projection, issue: .invalidRecoveryIdentity)
        }

        do {
            let outcome = try await secureAttach(identity, restoredSnapshot)
            guard outcome.snapshot.sessionID == identity.sessionID,
                  outcome.snapshot.nextTranscriptSequence >= identity.nextTranscriptSequence,
                  outcome.brokerResponse?.durableIdentity == identity,
                  outcome.brokerResponse?.durableClientAttached == true,
                  {
                      if case .running = outcome.snapshot.state { return true }
                      return false
                  }()
            else {
                return failed(projection, issue: .secureAttachRejected)
            }
            return Phase2DurableShellSessionRecoveryResult(
                projection: projection.accepted(outcome),
                issue: nil
            )
        } catch Phase2HumanPTYShellSessionClientError.durableSessionAbsent {
            return failed(projection, issue: .definitiveBrokerAbsence)
        } catch {
            return failed(projection, issue: .secureAttachRejected)
        }
    }

    private func failed(
        _ projection: Phase2WorkspaceShellSessionProjection,
        issue: Phase2DurableShellSessionRecoveryIssue
    ) -> Phase2DurableShellSessionRecoveryResult {
        Phase2DurableShellSessionRecoveryResult(
            projection: Phase2WorkspaceShellSessionProjection(
                snapshot: projection.snapshot,
                inFlightCommand: nil,
                lastError: Phase2WorkspaceShellSessionProjection.restoredInactiveMessage,
                lastAcceptedTranscriptEvents: [],
                lastBytesWritten: nil,
                durableRecoveryIdentity: nil
            ),
            issue: issue
        )
    }
}

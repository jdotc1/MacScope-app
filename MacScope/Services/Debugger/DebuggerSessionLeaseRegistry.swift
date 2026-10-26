import CryptoKit
import Foundation

struct DebuggerSessionLeaseOwnerID: Hashable, Sendable {
    let rawValue: UUID
}

struct DebuggerSessionLeaseGeneration: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    fileprivate init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func < (
        lhs: DebuggerSessionLeaseGeneration,
        rhs: DebuggerSessionLeaseGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Revision of the exact process-instance exclusion set. It changes only when a lease is inserted
/// or removed; transaction phase changes deliberately do not invalidate process observations.
struct DebuggerSessionLeaseMembershipRevision: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (
        lhs: DebuggerSessionLeaseMembershipRevision,
        rhs: DebuggerSessionLeaseMembershipRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerSessionLeaseObservationSnapshot: Equatable, Sendable {
    let attachWriteInterlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let membershipRevision: DebuggerSessionLeaseMembershipRevision
    let excludedProcessInstances: Set<DebuggerLocalProcessInstanceKey>
}

enum DebuggerSessionLeaseState: Hashable, Sendable {
    case reservedBeforeWrite
    case exactAttachArmed
    case exactAttachClaimed
    case confirming
    case confirmed
    case dispositionUnknown
    case provingTerminalRelease
    case provingExternalExitRelease
}

struct DebuggerSessionLeaseReservation: Hashable, Sendable {
    fileprivate let leaseID: UUID
    let generation: DebuggerSessionLeaseGeneration
    let ownerID: DebuggerSessionLeaseOwnerID
    let sessionEpoch: DebuggerSessionEpoch
    let authority: DebuggerSessionTargetAuthority

    fileprivate init(
        leaseID: UUID,
        generation: DebuggerSessionLeaseGeneration,
        ownerID: DebuggerSessionLeaseOwnerID,
        sessionEpoch: DebuggerSessionEpoch,
        authority: DebuggerSessionTargetAuthority
    ) {
        self.leaseID = leaseID
        self.generation = generation
        self.ownerID = ownerID
        self.sessionEpoch = sessionEpoch
        self.authority = authority
    }
}

/// Registry-minted authority for one exact attached-target transaction. The complete binding is
/// readable by the coordinator, but only this registry file can construct a permit. A permit is
/// tied to one lease generation and one retained adapter generation and is therefore not reusable
/// after a release/reacquisition cycle, even when the same OS process identity survives.
struct DebuggerSessionLeaseExactAttachPermit: Hashable, Sendable {
    fileprivate let leaseID: UUID
    let leaseGeneration: DebuggerSessionLeaseGeneration
    let leaseNonce: UUID
    let admissionSession: DebuggerSessionCoordinate
    let adapterGeneration: UInt64
    let authority: DebuggerSessionTargetAuthority
    let observationPolicyRevision: DebuggerLocalProcessObservationPolicyRevisionVector
    let attachWriteInterlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let correlationToken: Data
    let bindingDigest: Data
    /// Reference-backed one-shot state is intentionally excluded from value equality and hashing.
    /// Copies of one permit share it; separately minted permits have distinct lease/nonces and
    /// therefore retain the pre-existing value semantics.
    let exactAttachTransactionAuthority:
        DebuggerLocalProcessExactAttachPermitTransactionAuthority

    fileprivate init(
        leaseID: UUID,
        leaseGeneration: DebuggerSessionLeaseGeneration,
        leaseNonce: UUID,
        admissionSession: DebuggerSessionCoordinate,
        adapterGeneration: UInt64,
        authority: DebuggerSessionTargetAuthority,
        observationPolicyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        attachWriteInterlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        correlationToken: Data,
        bindingDigest: Data
    ) {
        self.leaseID = leaseID
        self.leaseGeneration = leaseGeneration
        self.leaseNonce = leaseNonce
        self.admissionSession = admissionSession
        self.adapterGeneration = adapterGeneration
        self.authority = authority
        self.observationPolicyRevision = observationPolicyRevision
        self.attachWriteInterlockIdentity = attachWriteInterlockIdentity
        self.correlationToken = correlationToken
        self.bindingDigest = bindingDigest
        self.exactAttachTransactionAuthority =
            DebuggerLocalProcessExactAttachPermitTransactionAuthority(
                interlockIdentity: attachWriteInterlockIdentity,
                permitBindingDigest: bindingDigest,
                permitAdapterGeneration: adapterGeneration
            )
    }

    static func == (
        lhs: DebuggerSessionLeaseExactAttachPermit,
        rhs: DebuggerSessionLeaseExactAttachPermit
    ) -> Bool {
        lhs.leaseID == rhs.leaseID
            && lhs.leaseGeneration == rhs.leaseGeneration
            && lhs.leaseNonce == rhs.leaseNonce
            && lhs.admissionSession == rhs.admissionSession
            && lhs.adapterGeneration == rhs.adapterGeneration
            && lhs.authority == rhs.authority
            && lhs.observationPolicyRevision == rhs.observationPolicyRevision
            && lhs.attachWriteInterlockIdentity == rhs.attachWriteInterlockIdentity
            && lhs.correlationToken == rhs.correlationToken
            && lhs.bindingDigest == rhs.bindingDigest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(leaseID)
        hasher.combine(leaseGeneration)
        hasher.combine(leaseNonce)
        hasher.combine(admissionSession)
        hasher.combine(adapterGeneration)
        hasher.combine(authority)
        hasher.combine(observationPolicyRevision)
        hasher.combine(attachWriteInterlockIdentity)
        hasher.combine(correlationToken)
        hasher.combine(bindingDigest)
    }
}

struct DebuggerSessionLeaseConfirmedAttachment: Sendable {
    let attachedSession: PersistentLLDBExactAttachedSessionEvidence

    fileprivate init(attachedSession: PersistentLLDBExactAttachedSessionEvidence) {
        self.attachedSession = attachedSession
    }
}

enum DebuggerSessionLeaseRegistryError: Error, Hashable, Sendable {
    case generationOverflow
    case membershipRevisionOverflow
    case ownerAlreadyReserved
    case ownerRetired
    case identityAlreadyReserved
    case processInstanceAlreadyReserved
    case staleReservation
    case sessionEpochMismatch
    case targetAuthorityMismatch
    case invalidStateTransition
    case exactAttachPermitMismatch
    case attachedSessionEvidenceMismatch
    case adapterRetirementProofMismatch
    case identityProofFailed
    case attachWriteInterlockMismatch
    case registryInvariantViolation
}

/// Process-global debugger ownership authority. Every mutation is synchronous within the actor,
/// so the kernel-process and complete-identity indexes are acquired and released atomically.
actor DebuggerSessionLeaseRegistry {
    private enum RecordPhase: Equatable, Sendable {
        case reservedBeforeWrite
        case exactAttachArmed(DebuggerSessionLeaseExactAttachPermit)
        case confirming(PersistentLLDBExactAttachedSessionEvidence)
        case confirmed(PersistentLLDBExactAttachedSessionEvidence)
        case dispositionUnknown(PersistentLLDBExactAttachedSessionEvidence?)
        case provingTerminalRelease(PersistentLLDBExactAttachedSessionEvidence)
        case provingExternalExitRelease(PersistentLLDBExactAttachedExternalExitResult)
    }

    private struct Record: Equatable, Sendable {
        let reservation: DebuggerSessionLeaseReservation
        let processInstanceKey: DebuggerLocalProcessInstanceKey
        let identity: DebuggerLocalProcessIdentity
        let identityDigest: DebuggerLocalProcessIdentityDigest
        var phase: RecordPhase
    }

    private let identityObserver: DebuggerLocalProcessIdentityObserver
    private let processInstanceAbsenceProver:
        any DebuggerLocalProcessInstanceAbsenceProving
    nonisolated let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    private let permitsCompatibilityArming: Bool
    private var lastGeneration: UInt64 = 0
    private var membershipRevision: UInt64 = 0
    private var recordsByLeaseID: [UUID: Record] = [:]
    private var leaseIDByOwner: [DebuggerSessionLeaseOwnerID: UUID] = [:]
    private var leaseIDByProcessInstance: [DebuggerLocalProcessInstanceKey: UUID] = [:]
    private var leaseIDByCompleteIdentity: [DebuggerLocalProcessIdentity: UUID] = [:]
    private var retiredOwnerIDs: Set<DebuggerSessionLeaseOwnerID> = []

    init(
        processEvidenceProvider: any DebuggerLocalProcessEvidenceProviding =
            DarwinDebuggerLocalProcessEvidenceProvider(),
        processInstanceAbsenceProver:
            (any DebuggerLocalProcessInstanceAbsenceProving)? = nil,
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock? = nil
    ) {
        identityObserver = DebuggerLocalProcessIdentityObserver(
            provider: processEvidenceProvider
        )
        self.processInstanceAbsenceProver = processInstanceAbsenceProver
            ?? DebuggerLocalProcessInstanceAbsenceObserver(
                provider: processEvidenceProvider
            )
        if let attachWriteInterlock {
            self.attachWriteInterlock = attachWriteInterlock
            permitsCompatibilityArming = false
        } else {
            self.attachWriteInterlock = DebuggerLocalProcessAttachWriteInterlock(
                initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                    ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                    leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
                )
            )
            permitsCompatibilityArming = true
        }
    }

    /// Compatibility path for isolated pre-interlock tests. Production registries inject the
    /// process-global interlock and therefore cannot use this overload.
    func armExactAttach(
        _ reservation: DebuggerSessionLeaseReservation,
        admissionSession: DebuggerSessionCoordinate,
        adapterGeneration: UInt64
    ) throws -> DebuggerSessionLeaseExactAttachPermit {
        guard permitsCompatibilityArming else {
            throw DebuggerSessionLeaseRegistryError.attachWriteInterlockMismatch
        }
        return try armExactAttach(
            reservation,
            admissionSession: admissionSession,
            adapterGeneration: adapterGeneration,
            attachWriteInterlockSnapshot: attachWriteInterlock.currentSnapshot
        )
    }

    func armExactAttach(
        _ reservation: DebuggerSessionLeaseReservation,
        admissionSession: DebuggerSessionCoordinate,
        adapterGeneration: UInt64,
        attachWriteInterlockSnapshot:
            DebuggerLocalProcessAttachWriteInterlockSnapshot
    ) throws -> DebuggerSessionLeaseExactAttachPermit {
        var record = try validatedRecord(for: reservation)
        guard case .reservedBeforeWrite = record.phase else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        guard admissionSession.epoch == reservation.sessionEpoch,
              adapterGeneration > 0,
              case .attached(let identity) = reservation.authority.origin,
              identity == record.identity,
              identity.identityDigest == record.identityDigest else {
            throw DebuggerSessionLeaseRegistryError.targetAuthorityMismatch
        }
        guard attachWriteInterlock.currentSnapshot == attachWriteInterlockSnapshot else {
            throw DebuggerSessionLeaseRegistryError.attachWriteInterlockMismatch
        }

        let leaseNonce = UUID()
        let bindingDigest = Self.permitBindingDigest(
            leaseID: reservation.leaseID,
            generation: reservation.generation,
            nonce: leaseNonce,
            admissionSession: admissionSession,
            adapterGeneration: adapterGeneration,
            authority: reservation.authority,
            observationPolicyRevision: attachWriteInterlockSnapshot.revision
        )
        let permit = DebuggerSessionLeaseExactAttachPermit(
            leaseID: reservation.leaseID,
            leaseGeneration: reservation.generation,
            leaseNonce: leaseNonce,
            admissionSession: admissionSession,
            adapterGeneration: adapterGeneration,
            authority: reservation.authority,
            observationPolicyRevision: attachWriteInterlockSnapshot.revision,
            attachWriteInterlockIdentity: attachWriteInterlockSnapshot.identity,
            correlationToken: Self.correlationToken(for: bindingDigest),
            bindingDigest: bindingDigest
        )
        record.phase = .exactAttachArmed(permit)
        recordsByLeaseID[reservation.leaseID] = record
        return permit
    }

    private nonisolated static func permitBindingDigest(
        leaseID: UUID,
        generation: DebuggerSessionLeaseGeneration,
        nonce: UUID,
        admissionSession: DebuggerSessionCoordinate,
        adapterGeneration: UInt64,
        authority: DebuggerSessionTargetAuthority,
        observationPolicyRevision: DebuggerLocalProcessObservationPolicyRevisionVector
    ) -> Data {
        var material = Data("MacScope.DebuggerSessionLease.ExactAttachPermit.v1".utf8)
        material.append(0)
        material.appendLengthFramed(leaseID.uuidString.lowercased())
        material.appendLengthFramed(String(generation.rawValue))
        material.appendLengthFramed(nonce.uuidString.lowercased())
        material.appendLengthFramed(admissionSession.epoch.rawValue.uuidString.lowercased())
        material.appendLengthFramed(String(admissionSession.lifecycleRevision.rawValue))
        material.appendLengthFramed(String(adapterGeneration))
        material.appendLengthFramed(String(authority.processID))
        material.appendLengthFramed(authority.identityDigest.lowercaseHex)
        material.appendLengthFramed(
            String(observationPolicyRevision.ownedInfrastructure.rawValue)
        )
        material.appendLengthFramed(String(observationPolicyRevision.leaseMembership.rawValue))
        return Data(SHA256.hash(data: material))
    }

    private nonisolated static func correlationToken(for bindingDigest: Data) -> Data {
        var material = Data("MacScope.DebuggerSessionLease.ExactAttachCorrelation.v1".utf8)
        material.append(0)
        material.append(bindingDigest)
        return Data(SHA256.hash(data: material))
    }

    var activeLeaseCount: Int {
        recordsByLeaseID.count
    }

    /// Permanently closes admission for one controller-lifetime owner. Existing exact leases stay
    /// pinned until their ordinary proof-bearing release path completes; retirement is never
    /// authority to remove a possibly attached target. The tombstone prevents a late callback or
    /// stale window task from resurrecting ownership after that final release.
    func retireOwner(_ ownerID: DebuggerSessionLeaseOwnerID) {
        retiredOwnerIDs.insert(ownerID)
    }

    /// Returns one authoritative projection of every exact process instance currently owned by a
    /// lease. Indexes are validated before any values escape the actor.
    func observationSnapshot() throws -> DebuggerSessionLeaseObservationSnapshot {
        try validateIndexes()
        return makeObservationSnapshot()
    }

    /// Authenticates a live reservation, then projects the global exclusion set without only that
    /// reservation's own exact instance. The global membership revision is preserved.
    func observationSnapshot(
        excluding reservation: DebuggerSessionLeaseReservation
    ) throws -> DebuggerSessionLeaseObservationSnapshot {
        let record = try validatedRecord(for: reservation)
        try validateIndexes()
        return makeObservationSnapshot(excluding: record.processInstanceKey)
    }

    /// Authenticates a live registry-minted permit, then projects the global exclusion set without
    /// only its own exact instance. A stale or forged permit cannot influence policy inputs.
    func observationSnapshot(
        excluding permit: DebuggerSessionLeaseExactAttachPermit
    ) throws -> DebuggerSessionLeaseObservationSnapshot {
        let record = try validatedRecord(for: permit)
        try validateIndexes()
        return makeObservationSnapshot(excluding: record.processInstanceKey)
    }

    func reserve(
        ownerID: DebuggerSessionLeaseOwnerID,
        sessionEpoch: DebuggerSessionEpoch,
        authority: DebuggerSessionTargetAuthority
    ) throws -> DebuggerSessionLeaseReservation {
        try Task.checkCancellation()
        let identity = authority.leaseIdentity
        let processInstanceKey = DebuggerLocalProcessInstanceKey(identity: identity)

        guard !retiredOwnerIDs.contains(ownerID) else {
            throw DebuggerSessionLeaseRegistryError.ownerRetired
        }
        guard leaseIDByCompleteIdentity[identity] == nil else {
            throw DebuggerSessionLeaseRegistryError.identityAlreadyReserved
        }
        guard leaseIDByProcessInstance[processInstanceKey] == nil else {
            throw DebuggerSessionLeaseRegistryError.processInstanceAlreadyReserved
        }
        guard leaseIDByOwner[ownerID] == nil else {
            throw DebuggerSessionLeaseRegistryError.ownerAlreadyReserved
        }

        let (nextGeneration, overflowed) = lastGeneration.addingReportingOverflow(1)
        guard !overflowed, nextGeneration > 0 else {
            throw DebuggerSessionLeaseRegistryError.generationOverflow
        }
        let nextMembershipRevision = try nextMembershipRevision()

        var leaseID = UUID()
        while recordsByLeaseID[leaseID] != nil {
            leaseID = UUID()
        }
        let reservation = DebuggerSessionLeaseReservation(
            leaseID: leaseID,
            generation: DebuggerSessionLeaseGeneration(rawValue: nextGeneration),
            ownerID: ownerID,
            sessionEpoch: sessionEpoch,
            authority: authority
        )
        let record = Record(
            reservation: reservation,
            processInstanceKey: processInstanceKey,
            identity: identity,
            identityDigest: identity.identityDigest,
            phase: .reservedBeforeWrite
        )

        try commitMembershipRevision(to: nextMembershipRevision) {
            lastGeneration = nextGeneration
            recordsByLeaseID[leaseID] = record
            leaseIDByOwner[ownerID] = leaseID
            leaseIDByProcessInstance[processInstanceKey] = leaseID
            leaseIDByCompleteIdentity[identity] = leaseID
        }
        return reservation
    }

    /// Resolves the only safe post-permit failure split. The coordinator owns this sealed failure;
    /// callers cannot downgrade a possibly written attach to a pre-write cancellation.
    func resolveExactAttachFailure(
        _ failure: PersistentLLDBExactAttachTransactionFailure
    ) throws {
        var record = try validatedRecord(for: failure.permit)
        guard case .exactAttachArmed(let armedPermit) = record.phase,
              armedPermit == failure.permit else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        switch failure.finalCommandDisposition {
        case .definitelyNotDispatchedOrWritten:
            try remove(record, settling: failure)
        case .mayHaveWrittenOrAcceptedAuthority:
            guard attachWriteInterlock.validatesExactAttachFailureSettlement(
                permit: failure.permit,
                claim: failure.transactionClaim,
                disposition: failure.finalCommandDisposition
            ) else {
                throw DebuggerSessionLeaseRegistryError.invalidStateTransition
            }
            record.phase = .dispositionUnknown(nil)
            recordsByLeaseID[record.reservation.leaseID] = record
        }
    }

    /// Confirms exact attached authority only after the registry's own concrete observer completes
    /// both identity passes. Caller cancellation does not cancel the detached proof task.
    func confirmExactAttach(
        _ result: PersistentLLDBExactAttachTransactionResult
    ) async throws -> DebuggerSessionLeaseConfirmedAttachment {
        let attachedSession = result.attachedSession
        let permit = attachedSession.permit
        var record = try validatedRecord(for: permit)
        guard case .exactAttachArmed(let armedPermit) = record.phase,
              armedPermit == permit else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        guard attachWriteInterlock.validatesCompletedExactAttachClaim(
            attachedSession.transactionClaim,
            permit: permit
        ) else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        do {
            try validateAttachedSession(
                attachedSession,
                attachResult: result,
                record: record
            )
        } catch {
            // A sealed attach result means the final attach transaction may already have created
            // target authority. Contradictory result evidence therefore pins the exact record;
            // leaving it armed would incorrectly preserve the pre-write semantic phase.
            record.phase = .dispositionUnknown(attachedSession)
            recordsByLeaseID[record.reservation.leaseID] = record
            throw error
        }

        record.phase = .confirming(attachedSession)
        recordsByLeaseID[record.reservation.leaseID] = record
        let resolution = await reobserveIdentityCancellationShielded(record.identity)

        record = try validatedRecord(for: permit)
        guard case .confirming(let currentEvidence) = record.phase,
              currentEvidence == attachedSession else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        guard case .resolved(let identity) = resolution,
              identity == record.identity,
              identity.identityDigest == record.identityDigest else {
            record.phase = .dispositionUnknown(attachedSession)
            recordsByLeaseID[record.reservation.leaseID] = record
            throw DebuggerSessionLeaseRegistryError.identityProofFailed
        }

        record.phase = .confirmed(attachedSession)
        recordsByLeaseID[record.reservation.leaseID] = record
        return DebuggerSessionLeaseConfirmedAttachment(attachedSession: attachedSession)
    }

    func cancelBeforeTransportWrite(
        _ reservation: DebuggerSessionLeaseReservation
    ) throws {
        let record = try validatedRecord(for: reservation)
        guard case .reservedBeforeWrite = record.phase else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        try remove(record)
    }

    /// Atomically validates exact detach plus command-free adapter exit/reap evidence, performs the
    /// mandatory two-pass identity observation, revalidates after actor suspension, and removes all
    /// indexes in the same actor continuation. No releasable proof escapes this method.
    func completeExactAttachedTerminalRelease(
        detach: PersistentLLDBExactDetachTransactionResult,
        adapterRetirement: PersistentLLDBCLICommandFreeAdapterExitReapProof
    ) async throws {
        let attachedSession = detach.attachedSession
        let permit = attachedSession.permit
        var record = try validatedRecord(for: permit)
        // An exact attach whose confirmation proof failed may still complete one exact detach
        // recovery using the same sealed evidence. Unknown attach disposition with no sealed
        // evidence remains permanently pinned.
        guard phaseMayCompleteTerminalRelease(
            record.phase,
            attachedSession: attachedSession
        ) else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        try validateTerminalDetach(detach, record: record)
        guard adapterRetirement.sessionEpoch == permit.admissionSession.epoch,
              adapterRetirement.adapterGeneration == permit.adapterGeneration,
              adapterRetirement.adapterInstanceBindingDigest ==
                attachedSession.adapterInstanceBinding.digest,
              adapterRetirement.verifiedCommandQuiescence,
              adapterRetirement.attachedSessionBindingDigest == attachedSession.bindingDigest else {
            throw DebuggerSessionLeaseRegistryError.adapterRetirementProofMismatch
        }

        record.phase = .provingTerminalRelease(attachedSession)
        recordsByLeaseID[record.reservation.leaseID] = record
        let resolution = await reobserveIdentityCancellationShielded(record.identity)

        record = try validatedRecord(for: permit)
        guard case .provingTerminalRelease(let currentEvidence) = record.phase,
              currentEvidence == attachedSession else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        guard case .resolved(let identity) = resolution,
              identity == record.identity,
              identity.identityDigest == record.identityDigest else {
            record.phase = .dispositionUnknown(attachedSession)
            recordsByLeaseID[record.reservation.leaseID] = record
            throw DebuggerSessionLeaseRegistryError.identityProofFailed
        }
        try remove(record)
    }

    /// Releases an exact attached-target lease after a correlated natural exit. Unlike detach,
    /// external exit cannot be authorized by proving that the original identity survived. It
    /// requires coordinator-sealed terminal evidence, command-free retirement of the exact LLDB
    /// adapter, and a two-pass proof that the original PID/start-time instance is absent.
    func completeExactAttachedExternalExitRelease(
        exit: PersistentLLDBExactAttachedExternalExitResult,
        adapterRetirement: PersistentLLDBCLICommandFreeAdapterExitReapProof
    ) async throws {
        let attachedSession = exit.attachedSession
        let permit = attachedSession.permit
        var record = try validatedRecord(for: permit)
        guard phaseMayCompleteExternalExitRelease(
            record.phase,
            attachedSession: attachedSession
        ) else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        try validateExternalExit(exit, record: record)
        try validateAdapterRetirement(
            adapterRetirement,
            attachedSession: attachedSession
        )

        record.phase = .provingExternalExitRelease(exit)
        recordsByLeaseID[record.reservation.leaseID] = record
        let resolution = await proveProcessInstanceAbsentCancellationShielded(
            record.processInstanceKey
        )

        record = try validatedRecord(for: permit)
        guard case .provingExternalExitRelease(let currentExit) = record.phase,
              currentExit == exit else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        guard case .resolved(.absent) = resolution else {
            record.phase = .dispositionUnknown(attachedSession)
            recordsByLeaseID[record.reservation.leaseID] = record
            throw DebuggerSessionLeaseRegistryError.identityProofFailed
        }
        try remove(record)
    }

    /// Records that exact detach committed but command-free adapter exit/reap was not proven. The
    /// sealed detach is validated before the phase changes, so callers cannot pin an unrelated
    /// lease or use detached-looking ordinary values as evidence.
    func pinExactAttachedTerminalDispositionUnknown(
        detach: PersistentLLDBExactDetachTransactionResult
    ) throws {
        let attachedSession = detach.attachedSession
        let permit = attachedSession.permit
        var record = try validatedRecord(for: permit)
        guard phaseMayCompleteTerminalRelease(record.phase, attachedSession: attachedSession) else {
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        try validateTerminalDetach(detach, record: record)
        record.phase = .dispositionUnknown(attachedSession)
        recordsByLeaseID[record.reservation.leaseID] = record
    }

    /// Pins a coordinator-sealed attached session when exact detach or later recovery cannot prove
    /// terminal disposition. This operation never removes either ownership index and therefore
    /// cannot turn uncertain target state into permission for a new attach.
    func pinExactAttachedDispositionUnknown(
        _ attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) throws {
        let permit = attachedSession.permit
        var record = try validatedRecord(for: permit)
        try validateAttachedSessionBinding(attachedSession, record: record)
        switch record.phase {
        case .confirmed(let evidence):
            guard evidence == attachedSession else {
                throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
            }
        case .dispositionUnknown(let evidence):
            guard evidence == attachedSession else {
                throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
            }
        case .reservedBeforeWrite,
             .exactAttachArmed,
             .confirming,
             .provingTerminalRelease,
             .provingExternalExitRelease:
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
        record.phase = .dispositionUnknown(attachedSession)
        recordsByLeaseID[record.reservation.leaseID] = record
    }

    func state(
        for reservation: DebuggerSessionLeaseReservation
    ) throws -> DebuggerSessionLeaseState {
        switch try validatedRecord(for: reservation).phase {
        case .reservedBeforeWrite: .reservedBeforeWrite
        case .exactAttachArmed(let permit):
            attachWriteInterlock.hasBegunExactAttachTransaction(for: permit)
                ? .exactAttachClaimed
                : .exactAttachArmed
        case .confirming: .confirming
        case .confirmed: .confirmed
        case .dispositionUnknown: .dispositionUnknown
        case .provingTerminalRelease: .provingTerminalRelease
        case .provingExternalExitRelease: .provingExternalExitRelease
        }
    }

    private func validatedRecord(
        for reservation: DebuggerSessionLeaseReservation
    ) throws -> Record {
        guard let record = recordsByLeaseID[reservation.leaseID],
              record.reservation == reservation else {
            throw DebuggerSessionLeaseRegistryError.staleReservation
        }
        guard leaseIDByProcessInstance[record.processInstanceKey] == reservation.leaseID,
              leaseIDByCompleteIdentity[record.identity] == reservation.leaseID,
              leaseIDByOwner[record.reservation.ownerID] == reservation.leaseID,
              record.identity.identityDigest == record.identityDigest,
              reservation.authority.identityDigest == record.identityDigest else {
            throw DebuggerSessionLeaseRegistryError.registryInvariantViolation
        }
        return record
    }

    private func validatedRecord(
        for permit: DebuggerSessionLeaseExactAttachPermit
    ) throws -> Record {
        guard let record = recordsByLeaseID[permit.leaseID],
              record.reservation.leaseID == permit.leaseID,
              record.reservation.generation == permit.leaseGeneration else {
            throw DebuggerSessionLeaseRegistryError.staleReservation
        }
        guard leaseIDByProcessInstance[record.processInstanceKey] == permit.leaseID,
              leaseIDByCompleteIdentity[record.identity] == permit.leaseID,
              leaseIDByOwner[record.reservation.ownerID] == permit.leaseID,
              record.identity.identityDigest == record.identityDigest else {
            throw DebuggerSessionLeaseRegistryError.registryInvariantViolation
        }
        let expectedBinding = Self.permitBindingDigest(
            leaseID: permit.leaseID,
            generation: permit.leaseGeneration,
            nonce: permit.leaseNonce,
            admissionSession: permit.admissionSession,
            adapterGeneration: permit.adapterGeneration,
            authority: permit.authority,
            observationPolicyRevision: permit.observationPolicyRevision
        )
        guard permit.admissionSession.epoch == record.reservation.sessionEpoch,
              permit.authority == record.reservation.authority,
              permit.authority.identityDigest == record.identityDigest,
              permit.attachWriteInterlockIdentity == attachWriteInterlock.identity,
              permit.adapterGeneration > 0,
              permit.bindingDigest == expectedBinding,
              permit.correlationToken == Self.correlationToken(for: expectedBinding),
              permit.bindingDigest.count == 32,
              permit.correlationToken.count == 32 else {
            throw DebuggerSessionLeaseRegistryError.exactAttachPermitMismatch
        }
        return record
    }

    private func validateAttachedSession(
        _ attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        attachResult: PersistentLLDBExactAttachTransactionResult,
        record: Record
    ) throws {
        try validateAttachedSessionBinding(attachedSession, record: record)
        let permit = attachedSession.permit
        let state = attachResult.reducerState
        guard attachResult.requestID.epoch == permit.admissionSession.epoch,
              attachResult.requestID.sequence > 0,
              attachResult.requestID.sequence == state.lastAdmittedRequestSequence,
              state.epoch == permit.admissionSession.epoch,
              state.sessionCoordinate == attachedSession.establishedSession,
              state.pendingRequest == nil,
              !state.isInvalidated,
              state.acceptedTargetAuthority == permit.authority,
              state.observedProcessID == permit.authority.processID,
              attachResult.receipt.observedProcessID == permit.authority.processID,
              attachResult.receipt.lldbProcessUniqueID == attachedSession.lldbProcessUniqueID,
              attachResult.receipt.lldbProcessUniqueID > 0,
              attachResult.receipt.error.succeeded else {
            throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
        }
        guard case let .stopped(processID, _) = state.processPhase,
              case let .stopped(dispositionPID) = state.targetDisposition,
              processID == permit.authority.processID,
              dispositionPID == permit.authority.processID,
              state.stopRevision != nil,
              state.stopCoordinate?.session == attachedSession.establishedSession,
              attachResult.receipt.state == .stopped,
              attachResult.receipt.stopID > 0 else {
            throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
        }
    }

    private func validateAttachedSessionBinding(
        _ attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        record: Record
    ) throws {
        let permit = attachedSession.permit
        guard permit.leaseID == record.reservation.leaseID,
              permit.leaseGeneration == record.reservation.generation,
              attachedSession.establishedSession.epoch == permit.admissionSession.epoch,
              attachedSession.establishedSession.lifecycleRevision >=
                permit.admissionSession.lifecycleRevision,
              attachedSession.lldbProcessUniqueID > 0,
              attachedSession.adapterInstanceBinding.sessionEpoch ==
                permit.admissionSession.epoch,
              attachedSession.adapterInstanceBinding.adapterGeneration ==
                permit.adapterGeneration,
              attachedSession.adapterInstanceBinding.digest.count == 32,
              attachedSession.hasValidBinding() else {
            throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
        }
    }

    private func validateTerminalDetach(
        _ detach: PersistentLLDBExactDetachTransactionResult,
        record: Record
    ) throws {
        let attachedSession = detach.attachedSession
        try validateAttachedSessionBinding(attachedSession, record: record)
        let permit = attachedSession.permit
        let state = detach.reducerState
        guard detach.requestID.epoch == permit.admissionSession.epoch,
              detach.requestID.sequence > 0,
              detach.requestID.sequence == state.lastAdmittedRequestSequence,
              state.epoch == permit.admissionSession.epoch,
              state.pendingRequest == nil,
              state.isInvalidated,
              state.acceptedTargetAuthority == permit.authority,
              state.observedProcessID == permit.authority.processID,
              state.stopRevision == nil,
              detach.receipt.observedProcessID == permit.authority.processID,
              detach.receipt.lldbProcessUniqueID == attachedSession.lldbProcessUniqueID,
              detach.receipt.acknowledged,
              detach.receipt.resumeOnDetach,
              detach.receipt.error.succeeded,
              case .detached(let processID) = state.processPhase,
              processID == permit.authority.processID,
              state.targetDisposition == .detached else {
            throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
        }
    }

    private func validateExternalExit(
        _ exit: PersistentLLDBExactAttachedExternalExitResult,
        record: Record
    ) throws {
        let attachedSession = exit.attachedSession
        try validateAttachedSessionBinding(attachedSession, record: record)
        let permit = attachedSession.permit
        guard exit.hasValidBinding(),
              exit.adapterInstanceBindingDigest ==
                attachedSession.adapterInstanceBinding.digest,
              exit.requestID.epoch == permit.admissionSession.epoch,
              exit.requestID.sequence > 0,
              exit.terminalLifecycleRevision >
                attachedSession.establishedSession.lifecycleRevision,
              exit.processID == permit.authority.processID,
              case .attached(let identity) = permit.authority.origin,
              DebuggerLocalProcessInstanceKey(identity: identity) ==
                record.processInstanceKey else {
            throw DebuggerSessionLeaseRegistryError.attachedSessionEvidenceMismatch
        }
    }

    private func validateAdapterRetirement(
        _ adapterRetirement: PersistentLLDBCLICommandFreeAdapterExitReapProof,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) throws {
        let permit = attachedSession.permit
        guard adapterRetirement.sessionEpoch == permit.admissionSession.epoch,
              adapterRetirement.adapterGeneration == permit.adapterGeneration,
              adapterRetirement.adapterInstanceBindingDigest ==
                attachedSession.adapterInstanceBinding.digest,
              adapterRetirement.verifiedCommandQuiescence,
              adapterRetirement.attachedSessionBindingDigest ==
                attachedSession.bindingDigest else {
            throw DebuggerSessionLeaseRegistryError.adapterRetirementProofMismatch
        }
    }

    private func phaseMayCompleteTerminalRelease(
        _ phase: RecordPhase,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) -> Bool {
        switch phase {
        case .confirmed(let confirmedEvidence):
            confirmedEvidence == attachedSession
        case .dispositionUnknown(let uncertainEvidence):
            uncertainEvidence == attachedSession
        case .reservedBeforeWrite, .exactAttachArmed, .confirming,
             .provingTerminalRelease, .provingExternalExitRelease:
            false
        }
    }

    private func phaseMayCompleteExternalExitRelease(
        _ phase: RecordPhase,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) -> Bool {
        switch phase {
        case .confirmed(let confirmedEvidence):
            confirmedEvidence == attachedSession
        case .dispositionUnknown(let uncertainEvidence):
            uncertainEvidence == attachedSession
        case .reservedBeforeWrite, .exactAttachArmed, .confirming,
             .provingTerminalRelease, .provingExternalExitRelease:
            false
        }
    }

    private func reobserveIdentityCancellationShielded(
        _ expected: DebuggerLocalProcessIdentity
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity> {
        let observer = identityObserver
        let proofTask = Task.detached {
            await observer.reobserveIdentity(expected)
        }
        return await withTaskCancellationHandler {
            await proofTask.value
        } onCancel: {
            // Attach/detach authority has already committed. Cancellation must not truncate the
            // registry's two-pass identity proof or create a release window.
        }
    }

    private func proveProcessInstanceAbsentCancellationShielded(
        _ expected: DebuggerLocalProcessInstanceKey
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation> {
        let prover = processInstanceAbsenceProver
        let proofTask = Task.detached {
            await prover.proveProcessInstanceAbsent(expected)
        }
        return await withTaskCancellationHandler {
            await proofTask.value
        } onCancel: {
            // Correlated external exit and command-free adapter retirement have already committed.
            // Cancellation must not truncate the exact-instance absence proof or open a new lease.
        }
    }

    private func remove(_ record: Record) throws {
        let leaseID = record.reservation.leaseID
        guard recordsByLeaseID[leaseID] == record,
              leaseIDByOwner[record.reservation.ownerID] == leaseID,
              leaseIDByProcessInstance[record.processInstanceKey] == leaseID,
              leaseIDByCompleteIdentity[record.identity] == leaseID else {
            throw DebuggerSessionLeaseRegistryError.registryInvariantViolation
        }

        let nextMembershipRevision = try nextMembershipRevision()

        try commitMembershipRevision(to: nextMembershipRevision) {
            recordsByLeaseID.removeValue(forKey: leaseID)
            leaseIDByOwner.removeValue(forKey: record.reservation.ownerID)
            leaseIDByProcessInstance.removeValue(forKey: record.processInstanceKey)
            leaseIDByCompleteIdentity.removeValue(forKey: record.identity)
        }
    }

    private func remove(
        _ record: Record,
        settling failure: PersistentLLDBExactAttachTransactionFailure
    ) throws {
        let leaseID = record.reservation.leaseID
        guard recordsByLeaseID[leaseID] == record,
              leaseIDByOwner[record.reservation.ownerID] == leaseID,
              leaseIDByProcessInstance[record.processInstanceKey] == leaseID,
              leaseIDByCompleteIdentity[record.identity] == leaseID else {
            throw DebuggerSessionLeaseRegistryError.registryInvariantViolation
        }

        let nextRawValue = try nextMembershipRevision()
        let expected = DebuggerSessionLeaseMembershipRevision(rawValue: membershipRevision)
        let next = DebuggerSessionLeaseMembershipRevision(rawValue: nextRawValue)
        do {
            try attachWriteInterlock.commitExactAttachFailureLeaseRemoval(
                permit: failure.permit,
                claim: failure.transactionClaim,
                disposition: failure.finalCommandDisposition,
                from: expected,
                to: next
            ) {
                recordsByLeaseID.removeValue(forKey: leaseID)
                leaseIDByOwner.removeValue(forKey: record.reservation.ownerID)
                leaseIDByProcessInstance.removeValue(forKey: record.processInstanceKey)
                leaseIDByCompleteIdentity.removeValue(forKey: record.identity)
                membershipRevision = next.rawValue
            }
        } catch let error as DebuggerLocalProcessAttachWriteInterlockError {
            guard error == .transactionClaimBindingMismatch else { throw error }
            throw DebuggerSessionLeaseRegistryError.invalidStateTransition
        }
    }

    private func makeObservationSnapshot(
        excluding excludedInstance: DebuggerLocalProcessInstanceKey? = nil
    ) -> DebuggerSessionLeaseObservationSnapshot {
        var excludedProcessInstances = Set(leaseIDByProcessInstance.keys)
        if let excludedInstance {
            excludedProcessInstances.remove(excludedInstance)
        }
        return DebuggerSessionLeaseObservationSnapshot(
            attachWriteInterlockIdentity: attachWriteInterlock.identity,
            membershipRevision: DebuggerSessionLeaseMembershipRevision(
                rawValue: membershipRevision
            ),
            excludedProcessInstances: excludedProcessInstances
        )
    }

    private func validateIndexes() throws {
        guard recordsByLeaseID.count == leaseIDByOwner.count,
              recordsByLeaseID.count == leaseIDByProcessInstance.count,
              recordsByLeaseID.count == leaseIDByCompleteIdentity.count else {
            throw DebuggerSessionLeaseRegistryError.registryInvariantViolation
        }
        for (leaseID, record) in recordsByLeaseID {
            guard record.reservation.leaseID == leaseID,
                  record.processInstanceKey ==
                    DebuggerLocalProcessInstanceKey(identity: record.identity),
                  record.identity.identityDigest == record.identityDigest,
                  record.reservation.authority.identityDigest == record.identityDigest,
                  leaseIDByOwner[record.reservation.ownerID] == leaseID,
                  leaseIDByProcessInstance[record.processInstanceKey] == leaseID,
                  leaseIDByCompleteIdentity[record.identity] == leaseID else {
                throw DebuggerSessionLeaseRegistryError.registryInvariantViolation
            }
        }
    }

    private func nextMembershipRevision() throws -> UInt64 {
        let (next, overflowed) = membershipRevision.addingReportingOverflow(1)
        guard !overflowed, next > 0 else {
            throw DebuggerSessionLeaseRegistryError.membershipRevisionOverflow
        }
        return next
    }

    /// Linearizes membership/index visibility with the final attach-write fence. Phase-only
    /// transitions intentionally bypass this helper and therefore preserve membership revision.
    private func commitMembershipRevision(
        to nextRawValue: UInt64,
        _ mutation: () -> Void
    ) throws {
        let expected = DebuggerSessionLeaseMembershipRevision(rawValue: membershipRevision)
        let next = DebuggerSessionLeaseMembershipRevision(rawValue: nextRawValue)
        try attachWriteInterlock.commitLeaseMembershipRevision(
            from: expected,
            to: next
        ) {
            mutation()
            membershipRevision = next.rawValue
        }
    }
}

private extension DebuggerSessionTargetAuthority {
    var leaseIdentity: DebuggerLocalProcessIdentity {
        switch origin {
        case let .launched(authority):
            authority.identity
        case let .attached(identity):
            identity
        }
    }
}

private extension Data {
    mutating func appendLengthFramed(_ text: String) {
        let bytes = Data(text.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }
}

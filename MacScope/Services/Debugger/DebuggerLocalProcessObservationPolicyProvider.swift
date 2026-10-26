import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One complete revision of every process instance excluded from local attach discovery.
/// Neither component alone is sufficient: owned helper processes and active target leases are
/// maintained by independent process-global authorities.
struct DebuggerLocalProcessObservationPolicyRevisionVector: Hashable, Sendable {
    let ownedInfrastructure: DebuggerOwnedInfrastructureRevision
    let leaseMembership: DebuggerSessionLeaseMembershipRevision
}

struct DebuggerLocalProcessObservationPolicySnapshot: Hashable, Sendable {
    let attachWriteInterlockSnapshot: DebuggerLocalProcessAttachWriteInterlockSnapshot
    let policy: DebuggerLocalProcessObservationPolicy

    var revision: DebuggerLocalProcessObservationPolicyRevisionVector {
        attachWriteInterlockSnapshot.revision
    }
}

/// Process identity bound into production observation-policy provenance. Registry-backed
/// providers must describe this exact running process; scripted providers may retain synthetic
/// values for deterministic policy tests without acquiring production authority.
struct DebuggerLocalProcessObservationPolicyHostIdentity: Hashable, Sendable {
    let realUserID: UInt32
    let effectiveUserID: UInt32
    let processID: Int32

    static var current: Self {
        Self(
            realUserID: currentRealUserID,
            effectiveUserID: currentEffectiveUserID,
            processID: Int32(ProcessInfo.processInfo.processIdentifier)
        )
    }

    var isCurrentHostProcess: Bool {
        self == Self.current
    }

    private static var currentRealUserID: UInt32 {
        #if canImport(Darwin)
        getuid()
        #else
        0
        #endif
    }

    private static var currentEffectiveUserID: UInt32 {
        #if canImport(Darwin)
        geteuid()
        #else
        0
        #endif
    }
}

/// Immutable proof that a provider reads the exact two process-global registries coordinated by
/// one shared attach-write interlock and describes the exact current host process. Scripted
/// providers deliberately have no such authority.
struct DebuggerLocalProcessObservationPolicyRegistryAuthority: Hashable, Sendable {
    let ownedInfrastructureRegistryID: ObjectIdentifier
    let sessionLeaseRegistryID: ObjectIdentifier
    let attachWriteInterlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let hostIdentity: DebuggerLocalProcessObservationPolicyHostIdentity
}

enum DebuggerLocalProcessObservationPolicyScope: Hashable, Sendable {
    case all
    case excludingReservation(DebuggerSessionLeaseReservation)
    case excludingPermit(DebuggerSessionLeaseExactAttachPermit)
}

/// Injectable, process-global authority seam. Production reads the two registries; tests can
/// script revisions, partial capture, and registry rejection without weakening fail-closed rules.
protocol DebuggerLocalProcessObservationPolicySource: Sendable {
    func ownedInfrastructureSnapshot() async throws
        -> DebuggerOwnedInfrastructureSnapshot

    func leaseObservationSnapshot(
        scope: DebuggerLocalProcessObservationPolicyScope
    ) async throws -> DebuggerSessionLeaseObservationSnapshot
}

struct DebuggerLocalProcessObservationPolicyRegistrySource:
    DebuggerLocalProcessObservationPolicySource,
    Sendable
{
    let ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry
    let sessionLeaseRegistry: DebuggerSessionLeaseRegistry

    func ownedInfrastructureSnapshot() async throws
        -> DebuggerOwnedInfrastructureSnapshot
    {
        await ownedInfrastructureRegistry.snapshot
    }

    func leaseObservationSnapshot(
        scope: DebuggerLocalProcessObservationPolicyScope
    ) async throws -> DebuggerSessionLeaseObservationSnapshot {
        switch scope {
        case .all:
            try await sessionLeaseRegistry.observationSnapshot()
        case let .excludingReservation(reservation):
            try await sessionLeaseRegistry.observationSnapshot(excluding: reservation)
        case let .excludingPermit(permit):
            try await sessionLeaseRegistry.observationSnapshot(excluding: permit)
        }
    }
}

/// Produces a policy only from two equal, complete A/B captures of both process-global sources.
/// Cancellation, source errors, pending owned-process identity, stale exclusion scopes, or any
/// revision/content drift returns `.unknown(.unstableSnapshot)` and never falls back to a less
/// restrictive policy.
struct DebuggerLocalProcessObservationPolicyProvider: Sendable {
    private let source: any DebuggerLocalProcessObservationPolicySource
    private let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    private let hostIdentity: DebuggerLocalProcessObservationPolicyHostIdentity
    private let requiresCurrentHostIdentity: Bool
    let registryAuthority: DebuggerLocalProcessObservationPolicyRegistryAuthority?

    init(
        source: any DebuggerLocalProcessObservationPolicySource,
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock =
            DebuggerLocalProcessAttachWriteInterlock(
                initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                    ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                    leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
                )
            ),
        hostRealUserID: UInt32 = Self.currentRealUserID,
        hostEffectiveUserID: UInt32 = Self.currentEffectiveUserID,
        hostProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.source = source
        self.attachWriteInterlock = attachWriteInterlock
        hostIdentity = DebuggerLocalProcessObservationPolicyHostIdentity(
            realUserID: hostRealUserID,
            effectiveUserID: hostEffectiveUserID,
            processID: hostProcessID
        )
        requiresCurrentHostIdentity = false
        registryAuthority = nil
    }

    init(
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry,
        sessionLeaseRegistry: DebuggerSessionLeaseRegistry,
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock,
        hostRealUserID: UInt32 = Self.currentRealUserID,
        hostEffectiveUserID: UInt32 = Self.currentEffectiveUserID,
        hostProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        source = DebuggerLocalProcessObservationPolicyRegistrySource(
            ownedInfrastructureRegistry: ownedInfrastructureRegistry,
            sessionLeaseRegistry: sessionLeaseRegistry
        )
        self.attachWriteInterlock = attachWriteInterlock
        let hostIdentity = DebuggerLocalProcessObservationPolicyHostIdentity(
            realUserID: hostRealUserID,
            effectiveUserID: hostEffectiveUserID,
            processID: hostProcessID
        )
        self.hostIdentity = hostIdentity
        requiresCurrentHostIdentity = true
        if ownedInfrastructureRegistry.attachWriteInterlock.identity == attachWriteInterlock.identity,
           sessionLeaseRegistry.attachWriteInterlock.identity == attachWriteInterlock.identity,
           hostIdentity.isCurrentHostProcess {
            registryAuthority = DebuggerLocalProcessObservationPolicyRegistryAuthority(
                ownedInfrastructureRegistryID: ObjectIdentifier(ownedInfrastructureRegistry),
                sessionLeaseRegistryID: ObjectIdentifier(sessionLeaseRegistry),
                attachWriteInterlockIdentity: attachWriteInterlock.identity,
                hostIdentity: hostIdentity
            )
        } else {
            registryAuthority = nil
        }
    }

    /// Compatibility composition for callers that have not yet injected the process-global
    /// interlock explicitly. Crossed registries still fail closed because their snapshot identities
    /// cannot both equal this authority.
    init(
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry,
        sessionLeaseRegistry: DebuggerSessionLeaseRegistry,
        hostRealUserID: UInt32 = Self.currentRealUserID,
        hostEffectiveUserID: UInt32 = Self.currentEffectiveUserID,
        hostProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.init(
            ownedInfrastructureRegistry: ownedInfrastructureRegistry,
            sessionLeaseRegistry: sessionLeaseRegistry,
            attachWriteInterlock: ownedInfrastructureRegistry.attachWriteInterlock,
            hostRealUserID: hostRealUserID,
            hostEffectiveUserID: hostEffectiveUserID,
            hostProcessID: hostProcessID
        )
    }

    func snapshot(
        scope: DebuggerLocalProcessObservationPolicyScope = .all
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessObservationPolicySnapshot> {
        do {
            try Task.checkCancellation()
            guard !requiresCurrentHostIdentity || hostIdentity.isCurrentHostProcess else {
                return .unknown(.unstableSnapshot)
            }
            let ownedA = try await source.ownedInfrastructureSnapshot()
            try Task.checkCancellation()
            let leaseA = try await source.leaseObservationSnapshot(scope: scope)
            try Task.checkCancellation()
            let ownedB = try await source.ownedInfrastructureSnapshot()
            try Task.checkCancellation()
            let leaseB = try await source.leaseObservationSnapshot(scope: scope)
            try Task.checkCancellation()

            guard ownedA.isAuthoritative,
                  ownedB.isAuthoritative,
                  ownedA == ownedB,
                  leaseA == leaseB,
                  ownedB.attachWriteInterlockIdentity ==
                    leaseB.attachWriteInterlockIdentity else {
                return .unknown(.unstableSnapshot)
            }

            let revision = DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: ownedB.revision,
                leaseMembership: leaseB.membershipRevision
            )
            let interlockSnapshot = attachWriteInterlock.currentSnapshot
            guard interlockSnapshot.identity == ownedB.attachWriteInterlockIdentity,
                  interlockSnapshot.revision == revision else {
                return .unknown(.unstableSnapshot)
            }

            let excludedInfrastructure = ownedB.excludedInstances.union(
                leaseB.excludedProcessInstances
            )
            let policy = DebuggerLocalProcessObservationPolicy(
                hostRealUserID: hostIdentity.realUserID,
                hostEffectiveUserID: hostIdentity.effectiveUserID,
                selfProcessID: hostIdentity.processID,
                excludedInfrastructure: excludedInfrastructure
            )
            return .resolved(
                DebuggerLocalProcessObservationPolicySnapshot(
                    attachWriteInterlockSnapshot: interlockSnapshot,
                    policy: policy
                )
            )
        } catch {
            return .unknown(.unstableSnapshot)
        }
    }

    func snapshot(
        excluding reservation: DebuggerSessionLeaseReservation
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessObservationPolicySnapshot> {
        await snapshot(scope: .excludingReservation(reservation))
    }

    func snapshot(
        excluding permit: DebuggerSessionLeaseExactAttachPermit
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessObservationPolicySnapshot> {
        await snapshot(scope: .excludingPermit(permit))
    }

    private static var currentRealUserID: UInt32 {
        DebuggerLocalProcessObservationPolicyHostIdentity.current.realUserID
    }

    private static var currentEffectiveUserID: UInt32 {
        DebuggerLocalProcessObservationPolicyHostIdentity.current.effectiveUserID
    }
}

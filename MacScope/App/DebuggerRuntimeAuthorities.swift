import Foundation

/// The app-lifetime debugger authority graph shared by every document window.
///
/// The interlock and two registries are reference-identity authorities. The policy provider is
/// constructed from those exact instances once, here, so copying this value never forks debugger
/// ownership, exclusion state, or the final-write serialization domain. The complete graph is
/// retained through the production controller for future exact-attach authorization, but retaining
/// it does not dispatch or advertise process attach.
struct DebuggerRuntimeAuthorities: Sendable {
    let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    let sessionLeaseRegistry: DebuggerSessionLeaseRegistry
    let ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry
    let observationPolicyProvider: DebuggerLocalProcessObservationPolicyProvider

    init(
        sessionLeaseRegistry: DebuggerSessionLeaseRegistry? = nil,
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry? = nil,
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock? = nil
    ) {
        let sharedInterlock = attachWriteInterlock
            ?? sessionLeaseRegistry?.attachWriteInterlock
            ?? ownedInfrastructureRegistry?.attachWriteInterlock
            ?? DebuggerLocalProcessAttachWriteInterlock(
                initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                    ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                    leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
                )
            )
        let sessionLeaseRegistry = sessionLeaseRegistry
            ?? DebuggerSessionLeaseRegistry(attachWriteInterlock: sharedInterlock)
        let ownedInfrastructureRegistry = ownedInfrastructureRegistry
            ?? DebuggerOwnedInfrastructureRegistry(attachWriteInterlock: sharedInterlock)

        self.attachWriteInterlock = sharedInterlock
        self.sessionLeaseRegistry = sessionLeaseRegistry
        self.ownedInfrastructureRegistry = ownedInfrastructureRegistry
        self.observationPolicyProvider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: ownedInfrastructureRegistry,
            sessionLeaseRegistry: sessionLeaseRegistry,
            attachWriteInterlock: sharedInterlock
        )
    }
}

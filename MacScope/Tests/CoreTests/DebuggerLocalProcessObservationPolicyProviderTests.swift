import XCTest
@testable import MacScope

final class DebuggerLocalProcessObservationPolicyProviderTests: XCTestCase {
    func testStableCompleteCaptureUnionsBothAuthoritiesAndPublishesRevisionVector() async throws {
        let interlock = makeInterlock(ownedRevision: 7, leaseRevision: 9)
        let ownedKey = try processInstanceKey(processID: 101, startSeconds: 1_001)
        let leasedKey = try processInstanceKey(processID: 102, startSeconds: 1_002)
        let owned = ownedSnapshot(interlock: interlock, revision: 7, excluded: [ownedKey])
        let lease = leaseSnapshot(interlock: interlock, revision: 9, excluded: [leasedKey])
        let source = ScriptedObservationPolicySource(
            owned: [.value(owned), .value(owned)],
            leases: [.value(lease), .value(lease)]
        )
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock,
            hostRealUserID: 501,
            hostEffectiveUserID: 502,
            hostProcessID: 777
        )

        let result = await provider.snapshot()

        guard case let .resolved(snapshot) = result else {
            return XCTFail("Expected a stable policy, got \(result)")
        }
        XCTAssertEqual(snapshot.revision.ownedInfrastructure.rawValue, 7)
        XCTAssertEqual(snapshot.revision.leaseMembership.rawValue, 9)
        XCTAssertEqual(snapshot.attachWriteInterlockSnapshot, interlock.currentSnapshot)
        XCTAssertEqual(snapshot.policy.hostRealUserID, 501)
        XCTAssertEqual(snapshot.policy.hostEffectiveUserID, 502)
        XCTAssertEqual(snapshot.policy.selfProcessID, 777)
        XCTAssertEqual(snapshot.policy.excludedInfrastructure, [ownedKey, leasedKey])
        let scopes = await source.recordedScopes
        XCTAssertEqual(scopes, [.all, .all])
    }

    func testReservationScopeUsesExactProjectionForBothPasses() async throws {
        let reservation = try await makeReservation()
        let interlock = makeInterlock(ownedRevision: 1, leaseRevision: 2)
        let keptKey = try processInstanceKey(processID: 103, startSeconds: 1_003)
        let owned = ownedSnapshot(interlock: interlock, revision: 1)
        let lease = leaseSnapshot(interlock: interlock, revision: 2, excluded: [keptKey])
        let source = ScriptedObservationPolicySource(
            owned: [.value(owned), .value(owned)],
            leases: [.value(lease), .value(lease)]
        )
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        )

        let result = await provider.snapshot(excluding: reservation)

        guard case let .resolved(snapshot) = result else {
            return XCTFail("Expected an exact reservation projection")
        }
        XCTAssertEqual(snapshot.policy.excludedInfrastructure, [keptKey])
        let scopes = await source.recordedScopes
        XCTAssertEqual(
            scopes,
            [.excludingReservation(reservation), .excludingReservation(reservation)]
        )
    }

    func testPermitScopeUsesExactProjectionForBothPasses() async throws {
        let permit = try await makePermit()
        let interlock = makeInterlock(ownedRevision: 3, leaseRevision: 4)
        let keptKey = try processInstanceKey(processID: 104, startSeconds: 1_004)
        let owned = ownedSnapshot(interlock: interlock, revision: 3)
        let lease = leaseSnapshot(interlock: interlock, revision: 4, excluded: [keptKey])
        let source = ScriptedObservationPolicySource(
            owned: [.value(owned), .value(owned)],
            leases: [.value(lease), .value(lease)]
        )
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        )

        let result = await provider.snapshot(excluding: permit)

        guard case let .resolved(snapshot) = result else {
            return XCTFail("Expected an exact permit projection")
        }
        XCTAssertEqual(snapshot.policy.excludedInfrastructure, [keptKey])
        let scopes = await source.recordedScopes
        XCTAssertEqual(scopes, [.excludingPermit(permit), .excludingPermit(permit)])
    }

    func testPendingOrUnresolvedOwnedInfrastructureFailsClosed() async {
        let interlock = makeInterlock(ownedRevision: 1, leaseRevision: 1)
        let nonAuthoritative = DebuggerOwnedInfrastructureSnapshot(
            attachWriteInterlockIdentity: interlock.identity,
            revision: DebuggerOwnedInfrastructureRevision(rawValue: 1),
            excludedInstances: [],
            pendingSpawnCount: 1,
            unresolvedSpawnCount: 0
        )
        let lease = leaseSnapshot(interlock: interlock, revision: 1)
        let source = ScriptedObservationPolicySource(
            owned: [.value(nonAuthoritative), .value(nonAuthoritative)],
            leases: [.value(lease), .value(lease)]
        )

        let result = await DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        ).snapshot()

        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
    }

    func testOwnedRevisionOrContentDriftFailsClosed() async throws {
        let interlock = makeInterlock(ownedRevision: 1, leaseRevision: 1)
        let first = ownedSnapshot(interlock: interlock, revision: 1)
        let changed = ownedSnapshot(
            interlock: interlock,
            revision: 2,
            excluded: [try processInstanceKey(processID: 105, startSeconds: 1_005)]
        )
        let lease = leaseSnapshot(interlock: interlock, revision: 1)
        let source = ScriptedObservationPolicySource(
            owned: [.value(first), .value(changed)],
            leases: [.value(lease), .value(lease)]
        )

        let result = await DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        ).snapshot()

        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
    }

    func testLeaseRevisionOrContentDriftFailsClosed() async throws {
        let interlock = makeInterlock(ownedRevision: 1, leaseRevision: 1)
        let owned = ownedSnapshot(interlock: interlock, revision: 1)
        let first = leaseSnapshot(interlock: interlock, revision: 1)
        let changed = leaseSnapshot(
            interlock: interlock,
            revision: 2,
            excluded: [try processInstanceKey(processID: 106, startSeconds: 1_006)]
        )
        let source = ScriptedObservationPolicySource(
            owned: [.value(owned), .value(owned)],
            leases: [.value(first), .value(changed)]
        )

        let result = await DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        ).snapshot()

        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
    }

    func testSourceErrorFailsClosedWithoutFallbackPolicy() async {
        let interlock = makeInterlock(ownedRevision: 1, leaseRevision: 1)
        let owned = ownedSnapshot(interlock: interlock, revision: 1)
        let source = ScriptedObservationPolicySource(
            owned: [.value(owned)],
            leases: [.failure]
        )

        let result = await DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        ).snapshot()

        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
        let ownedCalls = await source.ownedCallCount
        let leaseCalls = await source.leaseCallCount
        XCTAssertEqual(ownedCalls, 1)
        XCTAssertEqual(leaseCalls, 1)
    }

    func testStaleReservationRejectedByRegistrySourceFailsClosed() async throws {
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(hostProcessID: 9_999)
        let leaseRegistry = DebuggerSessionLeaseRegistry()
        let reservation = try await leaseRegistry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: DebuggerSessionTargetAuthority(origin: .attached(try identity()))
        )
        try await leaseRegistry.cancelBeforeTransportWrite(reservation)
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: ownedRegistry,
            sessionLeaseRegistry: leaseRegistry,
            hostRealUserID: 501,
            hostEffectiveUserID: 501,
            hostProcessID: 9_999
        )

        let result = await provider.snapshot(excluding: reservation)

        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
    }

    func testCancellationFailsClosedEvenWhenSourceSuspends() async {
        let interlock = makeInterlock(ownedRevision: 1, leaseRevision: 1)
        let owned = ownedSnapshot(interlock: interlock, revision: 1)
        let lease = leaseSnapshot(interlock: interlock, revision: 1)
        let source = ScriptedObservationPolicySource(
            owned: [.value(owned), .value(owned)],
            leases: [.value(lease), .value(lease)],
            suspendFirstOwnedCapture: true
        )
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            source: source,
            attachWriteInterlock: interlock
        )
        let task = Task { await provider.snapshot() }
        await source.waitUntilFirstOwnedCaptureSuspends()

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
        let leaseCalls = await source.leaseCallCount
        XCTAssertEqual(leaseCalls, 0)
    }

    func testRegistryAuthorityRequiresExactSharedInterlockAndSourceProviderHasNone() async {
        let shared = makeInterlock(ownedRevision: 0, leaseRevision: 0)
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            hostProcessID: 9_999,
            attachWriteInterlock: shared
        )
        let leaseRegistry = DebuggerSessionLeaseRegistry(attachWriteInterlock: shared)
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: ownedRegistry,
            sessionLeaseRegistry: leaseRegistry,
            attachWriteInterlock: shared
        )

        XCTAssertEqual(
            provider.registryAuthority,
            DebuggerLocalProcessObservationPolicyRegistryAuthority(
                ownedInfrastructureRegistryID: ObjectIdentifier(ownedRegistry),
                sessionLeaseRegistryID: ObjectIdentifier(leaseRegistry),
                attachWriteInterlockIdentity: shared.identity,
                hostIdentity: .current
            )
        )

        let source = ScriptedObservationPolicySource(owned: [], leases: [])
        XCTAssertNil(
            DebuggerLocalProcessObservationPolicyProvider(
                source: source,
                attachWriteInterlock: shared
            ).registryAuthority
        )
    }

    func testRegistryAuthorityRejectsEveryWrongHostIdentityFieldOnSameGraph() async {
        let shared = makeInterlock(ownedRevision: 0, leaseRevision: 0)
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: shared
        )
        let leaseRegistry = DebuggerSessionLeaseRegistry(attachWriteInterlock: shared)
        let current = DebuggerLocalProcessObservationPolicyHostIdentity.current
        let wrongIdentities = [
            DebuggerLocalProcessObservationPolicyHostIdentity(
                realUserID: different(current.realUserID),
                effectiveUserID: current.effectiveUserID,
                processID: current.processID
            ),
            DebuggerLocalProcessObservationPolicyHostIdentity(
                realUserID: current.realUserID,
                effectiveUserID: different(current.effectiveUserID),
                processID: current.processID
            ),
            DebuggerLocalProcessObservationPolicyHostIdentity(
                realUserID: current.realUserID,
                effectiveUserID: current.effectiveUserID,
                processID: different(current.processID)
            ),
        ]

        for identity in wrongIdentities {
            let provider = DebuggerLocalProcessObservationPolicyProvider(
                ownedInfrastructureRegistry: ownedRegistry,
                sessionLeaseRegistry: leaseRegistry,
                attachWriteInterlock: shared,
                hostRealUserID: identity.realUserID,
                hostEffectiveUserID: identity.effectiveUserID,
                hostProcessID: identity.processID
            )

            XCTAssertNil(provider.registryAuthority)
            let result = await provider.snapshot()
            XCTAssertEqual(result.denial, .unstableSnapshot)
            XCTAssertFalse(result.isResolved)
        }
    }

    func testCrossedRegistryInterlockProjectsNoAuthorityAndFailsClosed() async {
        let first = makeInterlock(ownedRevision: 0, leaseRevision: 0)
        let second = makeInterlock(ownedRevision: 0, leaseRevision: 0)
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            hostProcessID: 9_999,
            attachWriteInterlock: first
        )
        let leaseRegistry = DebuggerSessionLeaseRegistry(attachWriteInterlock: second)
        let provider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: ownedRegistry,
            sessionLeaseRegistry: leaseRegistry,
            attachWriteInterlock: first
        )

        XCTAssertNil(provider.registryAuthority)
        let result = await provider.snapshot()
        XCTAssertEqual(result.denial, .unstableSnapshot)
        XCTAssertFalse(result.isResolved)
    }

    private func ownedSnapshot(
        interlock: DebuggerLocalProcessAttachWriteInterlock,
        revision: UInt64,
        excluded: Set<DebuggerLocalProcessInstanceKey> = []
    ) -> DebuggerOwnedInfrastructureSnapshot {
        DebuggerOwnedInfrastructureSnapshot(
            attachWriteInterlockIdentity: interlock.identity,
            revision: DebuggerOwnedInfrastructureRevision(rawValue: revision),
            excludedInstances: excluded,
            pendingSpawnCount: 0,
            unresolvedSpawnCount: 0
        )
    }

    private func leaseSnapshot(
        interlock: DebuggerLocalProcessAttachWriteInterlock,
        revision: UInt64,
        excluded: Set<DebuggerLocalProcessInstanceKey> = []
    ) -> DebuggerSessionLeaseObservationSnapshot {
        DebuggerSessionLeaseObservationSnapshot(
            attachWriteInterlockIdentity: interlock.identity,
            membershipRevision: DebuggerSessionLeaseMembershipRevision(rawValue: revision),
            excludedProcessInstances: excluded
        )
    }

    private func makeInterlock(
        ownedRevision: UInt64,
        leaseRevision: UInt64
    ) -> DebuggerLocalProcessAttachWriteInterlock {
        DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(
                    rawValue: ownedRevision
                ),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(
                    rawValue: leaseRevision
                )
            )
        )
    }

    private func different(_ value: UInt32) -> UInt32 {
        value == .max ? value - 1 : value + 1
    }

    private func different(_ value: Int32) -> Int32 {
        value == .max ? value - 1 : value + 1
    }

    private func processInstanceKey(
        processID: Int32,
        startSeconds: UInt64
    ) throws -> DebuggerLocalProcessInstanceKey {
        DebuggerLocalProcessInstanceKey(
            identity: try identity(processID: processID, startSeconds: startSeconds)
        )
    }

    private func identity(
        processID: Int32 = 800,
        startSeconds: UInt64 = 9_000_001
    ) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: try XCTUnwrap(
                DebuggerProcessStartIdentity(seconds: startSeconds, microseconds: 17)
            ),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopePolicyProviderFixture",
            executableDeviceID: 7,
            executableFileID: UInt64(processID) + 7_000,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        ))
    }

    private func makeReservation() async throws -> DebuggerSessionLeaseReservation {
        let registry = DebuggerSessionLeaseRegistry()
        return try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: DebuggerSessionTargetAuthority(origin: .attached(try identity()))
        )
    }

    private func makePermit() async throws -> DebuggerSessionLeaseExactAttachPermit {
        let registry = DebuggerSessionLeaseRegistry()
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: DebuggerSessionTargetAuthority(origin: .attached(try identity()))
        )
        return try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 1
        )
    }
}

private enum ScriptedObservationPolicyStep<Value: Sendable>: Sendable {
    case value(Value)
    case failure
}

private enum ScriptedObservationPolicyError: Error {
    case rejected
}

private actor ScriptedObservationPolicySource:
    DebuggerLocalProcessObservationPolicySource
{
    private var owned: [ScriptedObservationPolicyStep<DebuggerOwnedInfrastructureSnapshot>]
    private var leases: [ScriptedObservationPolicyStep<DebuggerSessionLeaseObservationSnapshot>]
    private let suspendFirstOwnedCapture: Bool
    private var firstOwnedCaptureStarted = false
    private var firstOwnedCaptureWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var recordedScopes: [DebuggerLocalProcessObservationPolicyScope] = []
    private(set) var ownedCallCount = 0
    private(set) var leaseCallCount = 0

    init(
        owned: [ScriptedObservationPolicyStep<DebuggerOwnedInfrastructureSnapshot>],
        leases: [ScriptedObservationPolicyStep<DebuggerSessionLeaseObservationSnapshot>],
        suspendFirstOwnedCapture: Bool = false
    ) {
        self.owned = owned
        self.leases = leases
        self.suspendFirstOwnedCapture = suspendFirstOwnedCapture
    }

    func ownedInfrastructureSnapshot() async throws
        -> DebuggerOwnedInfrastructureSnapshot
    {
        ownedCallCount += 1
        if suspendFirstOwnedCapture, ownedCallCount == 1 {
            firstOwnedCaptureStarted = true
            let waiters = firstOwnedCaptureWaiters
            firstOwnedCaptureWaiters.removeAll()
            waiters.forEach { $0.resume() }
            try await Task.sleep(for: .seconds(60))
        }
        guard !owned.isEmpty else { throw ScriptedObservationPolicyError.rejected }
        switch owned.removeFirst() {
        case let .value(snapshot): return snapshot
        case .failure: throw ScriptedObservationPolicyError.rejected
        }
    }

    func leaseObservationSnapshot(
        scope: DebuggerLocalProcessObservationPolicyScope
    ) async throws -> DebuggerSessionLeaseObservationSnapshot {
        leaseCallCount += 1
        recordedScopes.append(scope)
        guard !leases.isEmpty else { throw ScriptedObservationPolicyError.rejected }
        switch leases.removeFirst() {
        case let .value(snapshot): return snapshot
        case .failure: throw ScriptedObservationPolicyError.rejected
        }
    }

    func waitUntilFirstOwnedCaptureSuspends() async {
        if firstOwnedCaptureStarted { return }
        await withCheckedContinuation { continuation in
            firstOwnedCaptureWaiters.append(continuation)
        }
    }
}

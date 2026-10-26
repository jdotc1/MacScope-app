import XCTest
@testable import MacScope

final class DebuggerSessionLeaseObservationSnapshotTests: XCTestCase {
    func testEmptySnapshotStartsAtRevisionZero() async throws {
        let registry = DebuggerSessionLeaseRegistry()

        let snapshot = try await registry.observationSnapshot()

        XCTAssertEqual(snapshot.membershipRevision.rawValue, 0)
        XCTAssertEqual(snapshot.excludedProcessInstances, [])
    }

    func testReserveAddsExactInstanceAndAdvancesMembershipRevision() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let identity = try identity(processID: 901, startSeconds: 10_001)

        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(identity)
        )
        let snapshot = try await registry.observationSnapshot()

        XCTAssertEqual(snapshot.membershipRevision.rawValue, 1)
        XCTAssertEqual(
            snapshot.excludedProcessInstances,
            [DebuggerLocalProcessInstanceKey(identity: identity)]
        )
    }

    func testPhaseTransitionDoesNotAdvanceMembershipRevision() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let identity = try identity(processID: 902, startSeconds: 10_002)
        let epoch = DebuggerSessionEpoch()
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: epoch,
            authority: attachedAuthority(identity)
        )
        let before = try await registry.observationSnapshot()

        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            adapterGeneration: 1
        )
        let after = try await registry.observationSnapshot()
        let reservationScoped = try await registry.observationSnapshot(
            excluding: reservation
        )
        let permitScoped = try await registry.observationSnapshot(excluding: permit)

        XCTAssertEqual(after, before)
        XCTAssertEqual(reservationScoped.membershipRevision, before.membershipRevision)
        XCTAssertEqual(permitScoped.membershipRevision, before.membershipRevision)
        XCTAssertEqual(reservationScoped.excludedProcessInstances, [])
        XCTAssertEqual(permitScoped.excludedProcessInstances, [])
    }

    func testScopedSnapshotOmitsOnlyAuthenticatedLeaseInstance() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let firstIdentity = try identity(processID: 903, startSeconds: 10_003)
        let secondIdentity = try identity(processID: 904, startSeconds: 10_004)
        let first = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(firstIdentity)
        )
        _ = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(secondIdentity)
        )

        let global = try await registry.observationSnapshot()
        let scoped = try await registry.observationSnapshot(excluding: first)

        XCTAssertEqual(global.membershipRevision.rawValue, 2)
        XCTAssertEqual(scoped.membershipRevision, global.membershipRevision)
        XCTAssertEqual(
            scoped.excludedProcessInstances,
            [DebuggerLocalProcessInstanceKey(identity: secondIdentity)]
        )
    }

    func testRemovalAdvancesRevisionAndMakesReservationScopeStale() async throws {
        let registry = DebuggerSessionLeaseRegistry()
        let identity = try identity(processID: 905, startSeconds: 10_005)
        let reservation = try await registry.reserve(
            ownerID: owner(),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: attachedAuthority(identity)
        )

        try await registry.cancelBeforeTransportWrite(reservation)
        let snapshot = try await registry.observationSnapshot()

        XCTAssertEqual(snapshot.membershipRevision.rawValue, 2)
        XCTAssertEqual(snapshot.excludedProcessInstances, [])
        do {
            _ = try await registry.observationSnapshot(excluding: reservation)
            XCTFail("A removed reservation must not authenticate a scoped projection.")
        } catch {
            XCTAssertEqual(
                error as? DebuggerSessionLeaseRegistryError,
                .staleReservation
            )
        }
    }

    private func owner() -> DebuggerSessionLeaseOwnerID {
        DebuggerSessionLeaseOwnerID(rawValue: UUID())
    }

    private func attachedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    private func identity(
        processID: Int32,
        startSeconds: UInt64
    ) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: try XCTUnwrap(DebuggerProcessStartIdentity(
                seconds: startSeconds,
                microseconds: 17
            )),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeLeaseObservationFixture",
            executableDeviceID: 7,
            executableFileID: UInt64(processID) + 20_000,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        ))
    }
}

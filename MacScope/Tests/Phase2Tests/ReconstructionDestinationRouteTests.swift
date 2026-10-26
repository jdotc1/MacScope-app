import Foundation
import XCTest
@testable import MacScope

final class ReconstructionDestinationRouteTests: XCTestCase {
    private struct Session: Equatable, Sendable {
        let jobID: UUID
    }

    private actor Probe {
        private(set) var calls: [UUID] = []

        func make(jobID: UUID) -> Session {
            calls.append(jobID)
            return Session(jobID: jobID)
        }

        func callCount() -> Int { calls.count }
    }

    func testRouteRoundTripsWithoutRuntimeOrPathState() throws {
        let route = ReconstructionDestinationRoute(
            workspaceID: UUID(),
            durableJobID: UUID()
        )
        let encoded = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(
            ReconstructionDestinationRoute.self,
            from: encoded
        )

        XCTAssertEqual(decoded, route)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set(["workspaceID", "durableJobID"]))
    }

    func testEmptyWorkspaceRouteCannotResolveSessionAuthority() async throws {
        let probe = Probe()
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            await probe.make(jobID: jobID)
        }
        let route = ReconstructionDestinationRoute(workspaceID: UUID())

        XCTAssertTrue(route.isEmptyWorkspaceDestination)
        do {
            _ = try await resolver.resolve(for: route)
            XCTFail("expected empty destination refusal")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionDestinationSessionResolutionError,
                .durableJobRequired
            )
        }
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testDurableRouteBindsExactlyItsJobIdentity() async throws {
        let probe = Probe()
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            await probe.make(jobID: jobID)
        }
        let route = ReconstructionDestinationRoute(
            workspaceID: UUID(),
            durableJobID: UUID()
        )

        let session = try await resolver.resolve(for: route)
        let callCount = await probe.callCount()
        let durableJobID = try XCTUnwrap(route.durableJobID)
        XCTAssertEqual(session.jobID, durableJobID)
        XCTAssertEqual(callCount, 1)
    }
}

import XCTest

@testable import MacScope

final class MacScopeGhosttyLifecycleProcessOwnershipTests: XCTestCase {
    func testSurfaceLifecycleIsGenerationFencedAndRetainsTerminalOutcome() {
        let current = coordinate(generation: 8)
        let staleRequest = Phase2ShellSurfaceCommandCoordinate(
            sessionID: current.sessionID,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
            generation: current.generation
        )
        var state = Phase2ShellSurfaceMediationState(
            coordinate: current,
            acceptedTerminalSize: .init(columns: 80, rows: 24),
            lifecycle: .running
        )

        XCTAssertFalse(state.acceptLifecycle(.terminal(.canceled), from: staleRequest))
        XCTAssertEqual(state.lifecycle, .running)
        XCTAssertTrue(state.acceptLifecycle(.terminal(.exited(status: 7)), from: current))
        XCTAssertEqual(state.lifecycle, .terminal(.exited(status: 7)))
    }

    func testBindingLeavesChildAndPTYOwnershipWithShellBrokerLaunchAgent() {
        let binding = Phase2ShellBrokerPTYBinding(
            terminalSurfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000504")!,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            processIdentifier: 4242,
            terminalSize: .init(columns: 80, rows: 24),
            nextTranscriptSequence: 1
        )

        XCTAssertTrue(binding.isStructurallyValid)
        XCTAssertEqual(binding.childProcessOwner, .shellBrokerLaunchAgent)
        XCTAssertEqual(binding.ptyOwner, .shellBrokerLaunchAgent)
        XCTAssertEqual(binding.ptyReusePolicy, .shellBrokerSession)
        XCTAssertEqual(binding.debuggerAuthorityPolicy, .disabled)
        XCTAssertNil(binding.rendererChildProcessIdentifier)
        XCTAssertFalse(binding.rendererOwnsPTY)
    }

    func testSurfaceCoordinateRejectsZeroGeneration() {
        XCTAssertFalse(coordinate(generation: 0).isStructurallyValid)
        XCTAssertTrue(coordinate(generation: 1).isStructurallyValid)
    }

    private func coordinate(generation: UInt64) -> Phase2ShellSurfaceCommandCoordinate {
        Phase2ShellSurfaceCommandCoordinate(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            generation: generation
        )
    }
}

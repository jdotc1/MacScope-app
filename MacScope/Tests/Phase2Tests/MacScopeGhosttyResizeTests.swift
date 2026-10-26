import XCTest

@testable import MacScope

final class MacScopeGhosttyResizeTests: XCTestCase {
    func testGridProposalTracksProposedAndAcceptedSizesAndCoalescesDuplicates() {
        let coordinate = surfaceCoordinate(generation: 1)
        var state = Phase2ShellSurfaceMediationState(
            coordinate: coordinate,
            acceptedTerminalSize: .init(columns: 80, rows: 24),
            lifecycle: .running
        )
        let proposal = Phase2ShellSurfaceResizeProposal(
            terminalSize: .init(columns: 120, rows: 40),
            pixelSize: .init(width: 1_200, height: 800)
        )

        XCTAssertEqual(
            state.proposeResize(proposal, from: coordinate),
            .brokerResizeRequired(.init(columns: 120, rows: 40))
        )
        XCTAssertEqual(state.proposedTerminalSize, .init(columns: 120, rows: 40))
        XCTAssertEqual(state.acceptedTerminalSize, .init(columns: 80, rows: 24))
        XCTAssertEqual(state.proposeResize(proposal, from: coordinate), .coalesced)

        XCTAssertTrue(state.acceptBrokerTerminalSize(.init(columns: 120, rows: 40), from: coordinate))
        XCTAssertEqual(state.acceptedTerminalSize, .init(columns: 120, rows: 40))
    }

    func testBrokerAcceptedSizeRemainsDistinctFromNewerProposedSize() {
        let coordinate = surfaceCoordinate(generation: 5)
        var state = Phase2ShellSurfaceMediationState(
            coordinate: coordinate,
            acceptedTerminalSize: .init(columns: 80, rows: 24),
            lifecycle: .running
        )
        _ = state.proposeResize(
            .init(
                terminalSize: .init(columns: 140, rows: 50),
                pixelSize: .init(width: 1_400, height: 900)
            ),
            from: coordinate
        )

        XCTAssertTrue(state.acceptBrokerTerminalSize(.init(columns: 120, rows: 40), from: coordinate))
        XCTAssertEqual(state.proposedTerminalSize, .init(columns: 140, rows: 50))
        XCTAssertEqual(state.acceptedTerminalSize, .init(columns: 120, rows: 40))
    }

    func testScaleOnlyPixelChangeDoesNotRequestBrokerResize() {
        let coordinate = surfaceCoordinate(generation: 2)
        var state = Phase2ShellSurfaceMediationState(
            coordinate: coordinate,
            acceptedTerminalSize: .init(columns: 100, rows: 30),
            lifecycle: .running
        )

        XCTAssertEqual(
            state.proposeResize(
                .init(
                    terminalSize: .init(columns: 100, rows: 30),
                    pixelSize: .init(width: 1_000, height: 600)
                ),
                from: coordinate
            ),
            .presentationOnly
        )
        XCTAssertEqual(
            state.proposeResize(
                .init(
                    terminalSize: .init(columns: 100, rows: 30),
                    pixelSize: .init(width: 2_000, height: 1_200)
                ),
                from: coordinate
            ),
            .presentationOnly
        )
        XCTAssertEqual(state.acceptedTerminalSize, .init(columns: 100, rows: 30))
        XCTAssertEqual(state.proposedTerminalSize, .init(columns: 100, rows: 30))
        XCTAssertEqual(state.pixelSize, .init(width: 2_000, height: 1_200))
    }

    func testStaleCoordinateCannotProposeAcceptOrRollbackResize() {
        let coordinate = surfaceCoordinate(generation: 3)
        let stale = surfaceCoordinate(generation: 2)
        var state = Phase2ShellSurfaceMediationState(
            coordinate: coordinate,
            acceptedTerminalSize: .init(columns: 80, rows: 24),
            lifecycle: .running
        )

        XCTAssertEqual(
            state.proposeResize(
                .init(
                    terminalSize: .init(columns: 90, rows: 25),
                    pixelSize: .init(width: 900, height: 500)
                ),
                from: stale
            ),
            .rejectedStaleCoordinate
        )
        XCTAssertFalse(state.acceptBrokerTerminalSize(.init(columns: 90, rows: 25), from: stale))
        XCTAssertFalse(state.rejectProposedResize(from: stale))
        XCTAssertEqual(state.acceptedTerminalSize, .init(columns: 80, rows: 24))
        XCTAssertEqual(state.proposedTerminalSize, .init(columns: 80, rows: 24))
        XCTAssertNil(state.pixelSize)
    }

    func testInvalidGridAndPixelProposalsFailBeforeStateMutation() {
        let coordinate = surfaceCoordinate(generation: 4)
        var state = Phase2ShellSurfaceMediationState(
            coordinate: coordinate,
            acceptedTerminalSize: .init(columns: 80, rows: 24),
            lifecycle: .running
        )

        XCTAssertEqual(
            state.proposeResize(
                .init(
                    terminalSize: .init(columns: 0, rows: 24),
                    pixelSize: .init(width: 800, height: 600)
                ),
                from: coordinate
            ),
            .rejectedInvalid
        )
        XCTAssertEqual(
            state.proposeResize(
                .init(
                    terminalSize: .init(columns: 80, rows: 24),
                    pixelSize: .init(width: 0, height: 600)
                ),
                from: coordinate
            ),
            .rejectedInvalid
        )
        XCTAssertNil(state.pixelSize)
    }

    private func surfaceCoordinate(generation: UInt64) -> Phase2ShellSurfaceCommandCoordinate {
        Phase2ShellSurfaceCommandCoordinate(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            generation: generation
        )
    }
}

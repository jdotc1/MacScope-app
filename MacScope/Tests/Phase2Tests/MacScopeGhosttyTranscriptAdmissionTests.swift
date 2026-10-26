import XCTest

@testable import MacScope

final class MacScopeGhosttyTranscriptAdmissionTests: XCTestCase {
    func testCompleteReplayAdvancesAcrossAuditEventsButProjectsOnlyBrokerOutput() {
        let coordinate = rendererCoordinate(1)
        let events = [
            transcriptEvent(sessionID: coordinate.sessionID, sequence: 1, source: .human, payload: .input([0x41])),
            transcriptEvent(sessionID: coordinate.sessionID, sequence: 2, source: .app, payload: .resize(columns: 80, rows: 24)),
            transcriptEvent(sessionID: coordinate.sessionID, sequence: 3, source: .broker, payload: .output(stream: .standardOutput, bytes: [0x42, 0x43])),
            transcriptEvent(sessionID: coordinate.sessionID, sequence: 4, source: .broker, payload: .terminal(.exited(status: 0))),
        ]

        guard case let .complete(projection) = Phase2GhosttyTranscriptAdmissionState.replay(
            coordinate: coordinate,
            events: events
        ) else { return XCTFail("expected complete replay") }
        XCTAssertEqual(projection.coordinate, coordinate)
        XCTAssertEqual(projection.highWaterSequence, 4)
        XCTAssertEqual(projection.outputEvents.map(\.sequence), [3])
        XCTAssertEqual(projection.outputBytes, [0x42, 0x43])
    }

    func testWrongCoordinateAndSessionAreRejectedWithoutAdvancingHighWater() {
        let coordinate = rendererCoordinate(1)
        var state = Phase2GhosttyTranscriptAdmissionState(coordinate: coordinate)
        let event = transcriptEvent(
            sessionID: coordinate.sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [1])
        )
        let wrongRequest = Phase2GhosttyRendererCoordinate(
            sessionID: coordinate.sessionID,
            requestID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            generation: coordinate.generation
        )
        XCTAssertEqual(state.admit(event, coordinate: wrongRequest), .rejected(.wrongCoordinate))
        XCTAssertEqual(state.highWaterSequence, 0)

        let staleGeneration = Phase2GhosttyRendererCoordinate(
            sessionID: coordinate.sessionID,
            requestID: coordinate.requestID,
            generation: coordinate.generation + 1
        )
        XCTAssertEqual(state.admit(event, coordinate: staleGeneration), .rejected(.wrongCoordinate))
        XCTAssertEqual(state.highWaterSequence, 0)

        let foreign = transcriptEvent(
            sessionID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [1])
        )
        XCTAssertEqual(state.admit(foreign, coordinate: coordinate), .rejected(.wrongSession))
        XCTAssertEqual(state.highWaterSequence, 0)
    }

    func testDuplicateOutOfOrderAndGapFailClosed() {
        let coordinate = rendererCoordinate(1)
        let first = transcriptEvent(
            sessionID: coordinate.sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [1])
        )
        var duplicateState = Phase2GhosttyTranscriptAdmissionState(coordinate: coordinate)
        XCTAssertEqual(duplicateState.admit(first, coordinate: coordinate), .acceptedOutput(sequence: 1, bytes: [1]))
        XCTAssertEqual(duplicateState.admit(first, coordinate: coordinate), .rejected(.duplicate(sequence: 1)))

        let third = transcriptEvent(
            sessionID: coordinate.sessionID,
            sequence: 3,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [3])
        )
        var orderState = Phase2GhosttyTranscriptAdmissionState(coordinate: coordinate)
        XCTAssertEqual(
            orderState.admit(third, coordinate: coordinate),
            .rejected(.outOfOrder(expected: 1, actual: 3))
        )
        XCTAssertNil(orderState.projection)

        let gap = transcriptEvent(
            sessionID: coordinate.sessionID,
            sequence: 1,
            source: .broker,
            payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 9)
        )
        XCTAssertEqual(
            Phase2GhosttyTranscriptAdmissionState.replay(coordinate: coordinate, events: [gap]),
            .fallback(.rejected(.explicitGap(sequence: 1)))
        )
    }

    func testEmptyOrIncompleteReplaySelectsFallback() {
        let coordinate = rendererCoordinate(1)
        XCTAssertEqual(
            Phase2GhosttyTranscriptAdmissionState.replay(coordinate: coordinate, events: []),
            .fallback(.emptyReplay)
        )
        let second = transcriptEvent(
            sessionID: coordinate.sessionID,
            sequence: 2,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [2])
        )
        XCTAssertEqual(
            Phase2GhosttyTranscriptAdmissionState.replay(coordinate: coordinate, events: [second]),
            .fallback(.rejected(.outOfOrder(expected: 1, actual: 2)))
        )
    }

    private func rendererCoordinate(_ generation: UInt64) -> Phase2GhosttyRendererCoordinate {
        Phase2GhosttyRendererCoordinate(
            sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            requestID: generation == 1
                ? UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
                : UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            generation: generation
        )
    }

    private func transcriptEvent(
        sessionID: UUID,
        sequence: UInt64,
        source: Phase2HumanPTYEventSource,
        payload: Phase2HumanPTYEventPayload
    ) -> Phase2HumanPTYTranscriptEvent {
        Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: sequence,
            source: source,
            payload: payload
        )
    }
}

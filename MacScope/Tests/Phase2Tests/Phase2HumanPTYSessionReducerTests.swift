import XCTest
@testable import MacScope

final class Phase2HumanPTYSessionReducerTests: XCTestCase {
    func testReducerAcceptsLaunchPreparedRunningTranscriptAndBrokerTermination() {
        let sessionID = reducerUUID(1)
        let requestID = reducerUUID(2)
        let plan = launchPlan(sessionID: sessionID, requestID: requestID)
        var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)

        snapshot = reduce(snapshot, command: .launch(plan))
        snapshot = reduce(snapshot, brokerEvent: .prepared(requestID: requestID))
        snapshot = reduce(snapshot, brokerEvent: .running(processIdentifier: 12_345))
        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes("ready\n"))
        )))
        snapshot = reduce(snapshot, brokerEvent: .brokerTerminated(.exited(status: 0)))

        XCTAssertEqual(snapshot.state, .terminal(outcome: .exited(status: 0)))
        XCTAssertEqual(snapshot.launchPlan, plan)
        XCTAssertEqual(snapshot.transcriptEvents.count, 2)
        XCTAssertEqual(snapshot.issues, [])
        XCTAssertTrue(Phase2HumanPTYTranscriptValidator.validate(Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: snapshot.transcriptEvents
        )).isAccepted)
    }

    func testReducerRejectsOutOfOrderLifecycleEventsWithoutChangingState() {
        let sessionID = reducerUUID(3)
        var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)

        snapshot = reduce(snapshot, brokerEvent: .running(processIdentifier: 1))
        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes("bad\n"))
        )))

        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.transcriptEvents, [])
        XCTAssertEqual(snapshot.issues, [
            .eventNotAllowedInState(event: .running, state: .idle),
            .eventNotAllowedInState(event: .transcript, state: .idle),
        ])
    }

    func testReducerRejectsInvalidCommandAndCommandInWrongLifecycle() {
        let sessionID = reducerUUID(4)
        let otherSessionID = reducerUUID(5)
        var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)

        snapshot = reduce(snapshot, command: .writeInput(bytes("not running\n")))
        snapshot = Phase2HumanPTYSessionReducer.reduce(
            snapshot,
            command: command(
                sessionID: otherSessionID,
                authority: .human,
                payload: .launch(launchPlan(sessionID: otherSessionID, requestID: reducerUUID(6)))
            )
        )

        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.issues, [
            .commandNotAllowedInState(command: .writeInput, state: .idle),
            .invalidCommand([.sessionMismatch(expected: sessionID, actual: otherSessionID)]),
        ])
    }

    func testReducerRejectsRequestMismatchAndInvalidProcessIdentifier() {
        let sessionID = reducerUUID(7)
        let requestID = reducerUUID(8)
        let otherRequestID = reducerUUID(9)
        var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)

        snapshot = reduce(snapshot, command: .launch(launchPlan(sessionID: sessionID, requestID: requestID)))
        snapshot = reduce(snapshot, brokerEvent: .prepared(requestID: otherRequestID))
        snapshot = reduce(snapshot, brokerEvent: .prepared(requestID: requestID))
        snapshot = reduce(snapshot, brokerEvent: .launchRejected(requestID: otherRequestID, reason: "wrong request"))
        snapshot = reduce(snapshot, brokerEvent: .running(processIdentifier: 0))

        XCTAssertEqual(snapshot.state, .prepared(requestID: requestID))
        XCTAssertEqual(snapshot.issues, [
            .requestMismatch(expected: requestID, actual: otherRequestID),
            .requestMismatch(expected: requestID, actual: otherRequestID),
            .invalidProcessIdentifier(0),
        ])
    }

    func testReducerRejectsWrongBrokerSessionAndWrongTranscriptSession() {
        let sessionID = reducerUUID(10)
        let otherSessionID = reducerUUID(11)
        let requestID = reducerUUID(12)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        snapshot = Phase2HumanPTYSessionReducer.reduce(
            snapshot,
            event: Phase2HumanPTYBrokerEvent(
                sessionID: otherSessionID,
                eventID: reducerUUID(13),
                payload: .prepared(requestID: requestID)
            )
        )
        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: otherSessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes("wrong\n"))
        )))

        XCTAssertEqual(snapshot.state, .running(requestID: requestID, processIdentifier: 99))
        XCTAssertEqual(snapshot.transcriptEvents, [])
        XCTAssertEqual(snapshot.issues, [
            .eventSessionMismatch(expected: sessionID, actual: otherSessionID),
            .transcriptSessionMismatch(expected: sessionID, actual: otherSessionID),
        ])
    }

    func testReducerRejectsTranscriptSequenceGapAndInvalidTranscriptSource() {
        let sessionID = reducerUUID(14)
        let requestID = reducerUUID(15)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: sessionID,
            sequence: 2,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes("gap\n"))
        )))
        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .input(bytes("broker cannot type\n"))
        )))

        XCTAssertEqual(snapshot.transcriptEvents, [])
        XCTAssertEqual(snapshot.issues, [
            .transcriptSequenceMismatch(expected: 1, actual: 2),
            .invalidTranscriptEvent(
                sequence: 1,
                issues: [.disallowedSource(sequence: 1, source: .broker, payload: .input)]
            ),
        ])
    }

    func testReducerAcceptsBrokerGapThatAdvancesBoundedTranscriptStream() {
        let sessionID = reducerUUID(140)
        let requestID = reducerUUID(141)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: sessionID,
            sequence: 8,
            source: .broker,
            payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 4_096)
        )))
        snapshot = reduce(snapshot, brokerEvent: .transcript(transcriptEvent(
            sessionID: sessionID,
            sequence: 9,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes("retained\n"))
        )))

        XCTAssertEqual(snapshot.transcriptEvents.map(\.sequence), [8, 9])
        XCTAssertEqual(snapshot.issues, [])
    }

    func testReducerRejectsPostTerminalEventsAndCommands() {
        let sessionID = reducerUUID(16)
        let requestID = reducerUUID(17)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        snapshot = reduce(snapshot, brokerEvent: .brokerTerminated(.canceled))
        snapshot = reduce(snapshot, brokerEvent: .prepared(requestID: reducerUUID(18)))
        snapshot = reduce(snapshot, brokerEvent: .brokerTerminated(.outcomeUnknown))
        snapshot = reduce(snapshot, command: .cancel)

        XCTAssertEqual(snapshot.state, .terminal(outcome: .canceled))
        XCTAssertEqual(snapshot.transcriptEvents.count, 1)
        XCTAssertEqual(snapshot.issues, [
            .eventNotAllowedInState(event: .prepared, state: .terminal(outcome: .canceled)),
            .eventNotAllowedInState(event: .brokerTerminated, state: .terminal(outcome: .canceled)),
            .commandNotAllowedInState(command: .cancel, state: .terminal(outcome: .canceled)),
        ])
    }
}

private func runningSnapshot(
    sessionID: UUID,
    requestID: UUID
) -> Phase2HumanPTYSessionSnapshot {
    var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)
    snapshot = reduce(snapshot, command: .launch(launchPlan(sessionID: sessionID, requestID: requestID)))
    snapshot = reduce(snapshot, brokerEvent: .prepared(requestID: requestID))
    snapshot = reduce(snapshot, brokerEvent: .running(processIdentifier: 99))
    return snapshot
}

private func reduce(
    _ snapshot: Phase2HumanPTYSessionSnapshot,
    command payload: Phase2HumanPTYBrokerCommandPayload
) -> Phase2HumanPTYSessionSnapshot {
    Phase2HumanPTYSessionReducer.reduce(
        snapshot,
        command: command(
            sessionID: snapshot.sessionID,
            authority: authority(for: payload),
            payload: payload
        )
    )
}

private func reduce(
    _ snapshot: Phase2HumanPTYSessionSnapshot,
    brokerEvent payload: Phase2HumanPTYBrokerEventPayload
) -> Phase2HumanPTYSessionSnapshot {
    Phase2HumanPTYSessionReducer.reduce(
        snapshot,
        event: Phase2HumanPTYBrokerEvent(
            sessionID: snapshot.sessionID,
            eventID: reducerUUID(100),
            payload: payload
        )
    )
}

private func authority(
    for payload: Phase2HumanPTYBrokerCommandPayload
) -> Phase2HumanPTYCommandAuthority {
    switch payload {
    case .reconnect:
        .app
    case .launch, .writeInput, .resize, .signal, .cancel:
        .human
    }
}

private func launchPlan(
    sessionID: UUID,
    requestID: UUID
) -> Phase2HumanPTYLaunchPlan {
    Phase2HumanPTYLaunchPlan(
        sessionID: sessionID,
        requestID: requestID,
        executablePath: "/bin/zsh",
        workingDirectoryPath: "/tmp",
        initialSize: .defaultInteractive
    )
}

private func command(
    commandID: UUID = reducerUUID(200),
    sessionID: UUID,
    authority: Phase2HumanPTYCommandAuthority,
    payload: Phase2HumanPTYBrokerCommandPayload
) -> Phase2HumanPTYBrokerCommand {
    Phase2HumanPTYBrokerCommand(
        commandID: commandID,
        sessionID: sessionID,
        authority: authority,
        payload: payload
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

private func reducerUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "30000000-0000-0000-0000-%012llx", value))!
}

private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

import XCTest
@testable import MacScope

final class Phase2HumanPTYTranscriptTests: XCTestCase {
    func testSeededCorpusCoversRequiredR2TraceCountAndPassesIntegrityValidation() {
        let traces = Phase2HumanPTYTranscriptSeededCorpus.traces()

        XCTAssertEqual(traces.count, Phase2HumanPTYTranscriptSeededCorpus.requiredTraceCount)
        XCTAssertTrue(traces.allSatisfy { trace in
            Phase2HumanPTYTranscriptValidator.validate(trace).isAccepted
        })
        XCTAssertTrue(traces.contains { trace in
            trace.events.contains { event in
                if case .resize = event.payload { return true }
                return false
            }
        })
        XCTAssertTrue(traces.contains { trace in
            trace.events.contains { event in
                if case .signal = event.payload { return true }
                return false
            }
        })
        XCTAssertTrue(traces.contains { trace in
            trace.events.contains { event in
                if case .gap = event.payload { return true }
                return false
            }
        })
        XCTAssertTrue(traces.contains { trace in
            trace.events.contains { event in
                if case .reconnect = event.payload { return true }
                return false
            }
        })
    }

    func testValidatorRejectsModelLikeOrBrokerAuthoredHumanInput() {
        let sessionID = ptyUUID(1)
        let transcript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(sessionID: sessionID, sequence: 1, source: .broker, payload: .input(bytes("whoami\n"))),
                event(sessionID: sessionID, sequence: 2, source: .broker, payload: .terminal(.outcomeUnknown)),
            ]
        )

        let result = Phase2HumanPTYTranscriptValidator.validate(transcript)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.disallowedSource(
            sequence: 1,
            source: .broker,
            payload: .input
        )))
    }

    func testValidatorRejectsNonContiguousSessionMixedTranscript() {
        let sessionID = ptyUUID(2)
        let otherSessionID = ptyUUID(3)
        let transcript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(sessionID: sessionID, sequence: 1, source: .human, payload: .input(bytes("echo ok\n"))),
                event(
                    sessionID: otherSessionID,
                    sequence: 3,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: bytes("ok\n"))
                ),
                event(sessionID: sessionID, sequence: 4, source: .broker, payload: .terminal(.exited(status: 0))),
            ]
        )

        let result = Phase2HumanPTYTranscriptValidator.validate(transcript)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.sessionMismatch(
            sequence: 3,
            expected: sessionID,
            actual: otherSessionID
        )))
        XCTAssertTrue(result.issues.contains(.nonContiguousSequence(expected: 2, actual: 3)))
    }

    func testValidatorRejectsEventsAfterTerminalAndDuplicateTerminal() {
        let sessionID = ptyUUID(4)
        let transcript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(sessionID: sessionID, sequence: 1, source: .human, payload: .input(bytes("exit\n"))),
                event(sessionID: sessionID, sequence: 2, source: .broker, payload: .terminal(.exited(status: 0))),
                event(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: bytes("late\n"))
                ),
                event(sessionID: sessionID, sequence: 4, source: .broker, payload: .terminal(.outcomeUnknown)),
            ]
        )

        let result = Phase2HumanPTYTranscriptValidator.validate(transcript)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.eventAfterTerminal(sequence: 3, terminalSequence: 2)))
        XCTAssertTrue(result.issues.contains(.duplicateTerminal(firstSequence: 2, duplicateSequence: 4)))
    }

    func testValidatorRejectsOversizedPayloadsButAcceptsExplicitGapEvidence() {
        let sessionID = ptyUUID(5)
        let acceptedGapTranscript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(sessionID: sessionID, sequence: 1, source: .human, payload: .input(bytes("cat large.log\n"))),
                event(sessionID: sessionID, sequence: 2, source: .broker, payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 4_096)),
                event(sessionID: sessionID, sequence: 3, source: .broker, payload: .terminal(.outcomeUnknown)),
            ]
        )
        XCTAssertTrue(Phase2HumanPTYTranscriptValidator.validate(acceptedGapTranscript).isAccepted)

        let oversizedTranscript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(sessionID: sessionID, sequence: 1, source: .human, payload: .input(bytes("cat large.log\n"))),
                event(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: [UInt8](repeating: 0x41, count: 6))
                ),
                event(sessionID: sessionID, sequence: 3, source: .broker, payload: .terminal(.outcomeUnknown)),
            ]
        )
        let result = Phase2HumanPTYTranscriptValidator.validate(
            oversizedTranscript,
            limits: Phase2HumanPTYTranscriptLimits(maximumEvents: 8, maximumEventBytes: 5, maximumCumulativeBytes: 32)
        )

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.eventTooLarge(sequence: 2, byteCount: 6, limit: 5)))
    }

    func testValidatorAcceptsBrokerGapAsFirstRetainedSpoolEvent() {
        let sessionID = ptyUUID(50)
        let transcript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(
                    sessionID: sessionID,
                    sequence: 8,
                    source: .broker,
                    payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 2_048)
                ),
                event(
                    sessionID: sessionID,
                    sequence: 9,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: bytes("tail\n"))
                ),
                event(sessionID: sessionID, sequence: 10, source: .broker, payload: .terminal(.outcomeUnknown)),
            ]
        )

        XCTAssertTrue(Phase2HumanPTYTranscriptValidator.validate(transcript).isAccepted)
    }

    func testValidatorRequiresTerminalOutcomeAndValidPayloads() {
        let sessionID = ptyUUID(6)
        let transcript = Phase2HumanPTYTranscript(
            sessionID: sessionID,
            events: [
                event(sessionID: sessionID, sequence: 1, source: .human, payload: .resize(columns: 0, rows: 24)),
                event(sessionID: sessionID, sequence: 2, source: .broker, payload: .gap(reason: .brokerRestart, lostByteCount: 0)),
            ]
        )

        let result = Phase2HumanPTYTranscriptValidator.validate(transcript)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.invalidPayload(
            sequence: 1,
            reason: "terminal size must be positive"
        )))
        XCTAssertTrue(result.issues.contains(.invalidPayload(
            sequence: 2,
            reason: "gap lost-byte count must be positive"
        )))
        XCTAssertTrue(result.issues.contains(.missingTerminalOutcome))
    }
}

private func event(
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

private func ptyUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "10000000-0000-0000-0000-%012llx", value))!
}

private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

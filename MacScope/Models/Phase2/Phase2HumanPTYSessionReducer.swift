import Foundation

/// App-owned reducer for future R2 human PTY sessions.
///
/// The reducer consumes the pure broker events defined by `Phase2HumanPTYBroker`.
/// It does not launch, kill, attach to, or observe any process. Its job is to make
/// session lifecycle truth deterministic before a real broker exists.
struct Phase2HumanPTYSessionSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let state: Phase2HumanPTYSessionState
    let launchPlan: Phase2HumanPTYLaunchPlan?
    let transcriptEvents: [Phase2HumanPTYTranscriptEvent]
    let issues: [Phase2HumanPTYSessionReducerIssue]

    static func initial(sessionID: UUID) -> Self {
        Self(sessionID: sessionID, state: .idle, launchPlan: nil, transcriptEvents: [], issues: [])
    }

    var currentTerminalSize: Phase2HumanPTYTerminalSize? {
        for event in transcriptEvents.reversed() {
            if case .resize(let columns, let rows) = event.payload {
                return Phase2HumanPTYTerminalSize(columns: columns, rows: rows)
            }
        }
        return launchPlan?.initialSize
    }

    var nextTranscriptSequence: UInt64 {
        (transcriptEvents.last?.sequence ?? 0) &+ 1
    }
}

enum Phase2HumanPTYSessionState: Equatable, Sendable {
    case idle
    case launchRequested(requestID: UUID)
    case prepared(requestID: UUID)
    case launchRejected(requestID: UUID, reason: String)
    case running(requestID: UUID, processIdentifier: Int32)
    case terminal(outcome: Phase2HumanPTYTerminalOutcome)

    var isTerminal: Bool {
        switch self {
        case .launchRejected, .terminal:
            true
        case .idle, .launchRequested, .prepared, .running:
            false
        }
    }
}

enum Phase2HumanPTYSessionReducerIssue: Equatable, Sendable {
    case invalidCommand([Phase2HumanPTYBrokerCommandValidationIssue])
    case commandNotAllowedInState(command: Phase2HumanPTYBrokerCommandPayloadKind, state: Phase2HumanPTYSessionState)
    case eventSessionMismatch(expected: UUID, actual: UUID)
    case eventNotAllowedInState(event: Phase2HumanPTYBrokerEventPayloadKind, state: Phase2HumanPTYSessionState)
    case requestMismatch(expected: UUID, actual: UUID)
    case invalidProcessIdentifier(Int32)
    case transcriptSessionMismatch(expected: UUID, actual: UUID)
    case transcriptSequenceMismatch(expected: UInt64, actual: UInt64)
    case invalidTranscriptEvent(sequence: UInt64, issues: [Phase2HumanPTYTranscriptValidationIssue])
}

enum Phase2HumanPTYBrokerEventPayloadKind: String, Equatable, Sendable {
    case prepared
    case launchRejected
    case running
    case transcript
    case brokerTerminated
}

extension Phase2HumanPTYBrokerEventPayload {
    var kind: Phase2HumanPTYBrokerEventPayloadKind {
        switch self {
        case .prepared:
            .prepared
        case .launchRejected:
            .launchRejected
        case .running:
            .running
        case .transcript:
            .transcript
        case .brokerTerminated:
            .brokerTerminated
        }
    }
}

enum Phase2HumanPTYSessionReducer {
    static func reduce(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        command: Phase2HumanPTYBrokerCommand
    ) -> Phase2HumanPTYSessionSnapshot {
        let validationResult = Phase2HumanPTYBrokerCommandValidator.validate(
            command,
            expectedSessionID: snapshot.sessionID
        )
        guard validationResult.isAccepted else {
            return snapshot.recording(.invalidCommand(validationResult.issues))
        }

        switch command.payload {
        case .launch(let plan):
            guard case .idle = snapshot.state else {
                return snapshot.recording(.commandNotAllowedInState(command: .launch, state: snapshot.state))
            }
            return snapshot.replacing(
                state: .launchRequested(requestID: plan.requestID),
                launchPlan: plan
            )
        case .writeInput, .resize, .signal:
            guard case .running = snapshot.state else {
                return snapshot.recording(.commandNotAllowedInState(command: command.payload.kind, state: snapshot.state))
            }
            return snapshot
        case .reconnect:
            switch snapshot.state {
            case .prepared, .running:
                return snapshot
            case .idle, .launchRequested, .launchRejected, .terminal:
                return snapshot.recording(.commandNotAllowedInState(command: .reconnect, state: snapshot.state))
            }
        case .cancel:
            switch snapshot.state {
            case .launchRequested, .prepared, .running:
                return snapshot
            case .idle, .launchRejected, .terminal:
                return snapshot.recording(.commandNotAllowedInState(command: .cancel, state: snapshot.state))
            }
        }
    }

    static func reduce(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        event: Phase2HumanPTYBrokerEvent,
        limits: Phase2HumanPTYTranscriptLimits = .productionMaximum
    ) -> Phase2HumanPTYSessionSnapshot {
        guard event.sessionID == snapshot.sessionID else {
            return snapshot.recording(.eventSessionMismatch(
                expected: snapshot.sessionID,
                actual: event.sessionID
            ))
        }

        switch event.payload {
        case .prepared(let requestID):
            return reducePrepared(snapshot, requestID: requestID)
        case .launchRejected(let requestID, let reason):
            return reduceLaunchRejected(snapshot, requestID: requestID, reason: reason)
        case .running(let processIdentifier):
            return reduceRunning(snapshot, processIdentifier: processIdentifier)
        case .transcript(let transcriptEvent):
            return reduceTranscript(snapshot, transcriptEvent: transcriptEvent, limits: limits)
        case .brokerTerminated(let outcome):
            return reduceBrokerTerminated(snapshot, outcome: outcome, limits: limits)
        }
    }

    private static func reducePrepared(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID
    ) -> Phase2HumanPTYSessionSnapshot {
        guard case .launchRequested(let expectedRequestID) = snapshot.state else {
            return snapshot.recording(.eventNotAllowedInState(event: .prepared, state: snapshot.state))
        }
        guard expectedRequestID == requestID else {
            return snapshot.recording(.requestMismatch(expected: expectedRequestID, actual: requestID))
        }
        return snapshot.replacing(state: .prepared(requestID: requestID))
    }

    private static func reduceLaunchRejected(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        reason: String
    ) -> Phase2HumanPTYSessionSnapshot {
        switch snapshot.state {
        case .launchRequested(let expectedRequestID):
            guard expectedRequestID == requestID else {
                return snapshot.recording(.requestMismatch(expected: expectedRequestID, actual: requestID))
            }
            return snapshot.replacing(state: .launchRejected(requestID: requestID, reason: reason))
        case .prepared(let expectedRequestID):
            guard expectedRequestID == requestID else {
                return snapshot.recording(.requestMismatch(expected: expectedRequestID, actual: requestID))
            }
            return snapshot.replacing(state: .launchRejected(requestID: requestID, reason: reason))
        case .idle, .launchRejected, .running, .terminal:
            return snapshot.recording(.eventNotAllowedInState(event: .launchRejected, state: snapshot.state))
        }
    }

    private static func reduceRunning(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        processIdentifier: Int32
    ) -> Phase2HumanPTYSessionSnapshot {
        guard case .prepared(let requestID) = snapshot.state else {
            return snapshot.recording(.eventNotAllowedInState(event: .running, state: snapshot.state))
        }
        guard processIdentifier > 0 else {
            return snapshot.recording(.invalidProcessIdentifier(processIdentifier))
        }
        return snapshot.replacing(state: .running(requestID: requestID, processIdentifier: processIdentifier))
    }

    private static func reduceTranscript(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        transcriptEvent: Phase2HumanPTYTranscriptEvent,
        limits: Phase2HumanPTYTranscriptLimits
    ) -> Phase2HumanPTYSessionSnapshot {
        guard case .running = snapshot.state else {
            return snapshot.recording(.eventNotAllowedInState(event: .transcript, state: snapshot.state))
        }

        guard transcriptEvent.sessionID == snapshot.sessionID else {
            return snapshot.recording(.transcriptSessionMismatch(
                expected: snapshot.sessionID,
                actual: transcriptEvent.sessionID
            ))
        }

        let expectedSequence = snapshot.transcriptEvents.last?.sequence.advanced(by: 1) ?? 1
        let isBrokerGapAdvance: Bool
        if case .gap = transcriptEvent.payload, transcriptEvent.source == .broker {
            isBrokerGapAdvance = transcriptEvent.sequence > expectedSequence
        } else {
            isBrokerGapAdvance = false
        }
        guard transcriptEvent.sequence == expectedSequence || isBrokerGapAdvance else {
            return snapshot.recording(.transcriptSequenceMismatch(
                expected: expectedSequence,
                actual: transcriptEvent.sequence
            ))
        }

        let proposedEvents = snapshot.transcriptEvents + [transcriptEvent]
        let transcriptIssues = validatePartialTranscript(
            sessionID: snapshot.sessionID,
            events: proposedEvents,
            limits: limits
        )
        guard transcriptIssues.isEmpty else {
            return snapshot.recording(.invalidTranscriptEvent(
                sequence: transcriptEvent.sequence,
                issues: transcriptIssues
            ))
        }

        if case .terminal(let outcome) = transcriptEvent.payload {
            return snapshot.replacing(
                state: .terminal(outcome: outcome),
                transcriptEvents: proposedEvents
            )
        }

        return snapshot.replacing(transcriptEvents: proposedEvents)
    }

    private static func reduceBrokerTerminated(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        outcome: Phase2HumanPTYTerminalOutcome,
        limits: Phase2HumanPTYTranscriptLimits
    ) -> Phase2HumanPTYSessionSnapshot {
        guard case .running = snapshot.state else {
            return snapshot.recording(.eventNotAllowedInState(event: .brokerTerminated, state: snapshot.state))
        }

        let terminalEvent = Phase2HumanPTYTranscriptEvent(
            sessionID: snapshot.sessionID,
            sequence: (snapshot.transcriptEvents.last?.sequence ?? 0) &+ 1,
            source: .broker,
            payload: .terminal(outcome)
        )
        return reduceTranscript(snapshot, transcriptEvent: terminalEvent, limits: limits)
    }

    private static func validatePartialTranscript(
        sessionID: UUID,
        events: [Phase2HumanPTYTranscriptEvent],
        limits: Phase2HumanPTYTranscriptLimits
    ) -> [Phase2HumanPTYTranscriptValidationIssue] {
        let validationEvents: [Phase2HumanPTYTranscriptEvent]
        if let last = events.last, case .terminal = last.payload {
            validationEvents = events
        } else {
            validationEvents = events + [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: (events.last?.sequence ?? 0) &+ 1,
                    source: .broker,
                    payload: .terminal(.outcomeUnknown)
                ),
            ]
        }

        let transcript = Phase2HumanPTYTranscript(sessionID: sessionID, events: validationEvents)
        return Phase2HumanPTYTranscriptValidator.validate(transcript, limits: limits).issues
    }
}

private extension Phase2HumanPTYSessionSnapshot {
    func replacing(
        state: Phase2HumanPTYSessionState? = nil,
        launchPlan: Phase2HumanPTYLaunchPlan? = nil,
        transcriptEvents: [Phase2HumanPTYTranscriptEvent]? = nil
    ) -> Self {
        Self(
            sessionID: sessionID,
            state: state ?? self.state,
            launchPlan: launchPlan ?? self.launchPlan,
            transcriptEvents: transcriptEvents ?? self.transcriptEvents,
            issues: issues
        )
    }

    func recording(_ issue: Phase2HumanPTYSessionReducerIssue) -> Self {
        Self(
            sessionID: sessionID,
            state: state,
            launchPlan: launchPlan,
            transcriptEvents: transcriptEvents,
            issues: issues + [issue]
        )
    }
}

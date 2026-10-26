import Foundation

/// R2 human-terminal authority starts with transcript integrity, not process launch.
/// This model is deliberately app-side and inert: it represents events the app may accept
/// from a future human-owned broker, while exposing no model-input or AI-owned PTY path.
struct Phase2HumanPTYTranscript: Equatable, Sendable {
    let sessionID: UUID
    let events: [Phase2HumanPTYTranscriptEvent]
}

struct Phase2HumanPTYTranscriptEvent: Equatable, Sendable {
    let sessionID: UUID
    let sequence: UInt64
    let source: Phase2HumanPTYEventSource
    let payload: Phase2HumanPTYEventPayload

    init(
        sessionID: UUID,
        sequence: UInt64,
        source: Phase2HumanPTYEventSource,
        payload: Phase2HumanPTYEventPayload
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.source = source
        self.payload = payload
    }
}

enum Phase2HumanPTYEventSource: String, CaseIterable, Codable, Equatable, Sendable {
    case human
    case app
    case broker
}

enum Phase2HumanPTYOutputStream: String, CaseIterable, Codable, Equatable, Sendable {
    case standardOutput
    case standardError
}

enum Phase2HumanPTYSignal: String, CaseIterable, Codable, Equatable, Sendable {
    case interrupt
    case terminate
    case suspend
    case continueSignal
}

enum Phase2HumanPTYGapReason: String, CaseIterable, Codable, Equatable, Sendable {
    case spoolLimitExceeded
    case eventPayloadLimitExceeded
    case brokerRestart
    case reconnectDiscontinuity
}

enum Phase2HumanPTYTerminalOutcome: Equatable, Sendable {
    case exited(status: Int32)
    case signaled(Phase2HumanPTYSignal)
    case canceled
    case interrupted
    case brokerCrashed
    case outcomeUnknown
}

enum Phase2HumanPTYEventPayload: Equatable, Sendable {
    case input([UInt8])
    case output(stream: Phase2HumanPTYOutputStream, bytes: [UInt8])
    case resize(columns: Int, rows: Int)
    case signal(Phase2HumanPTYSignal)
    case reconnect(reconnectID: UUID)
    case gap(reason: Phase2HumanPTYGapReason, lostByteCount: Int)
    case terminal(Phase2HumanPTYTerminalOutcome)

    var byteCount: Int {
        switch self {
        case .input(let bytes):
            bytes.count
        case .output(_, let bytes):
            bytes.count
        case .resize, .signal, .reconnect, .gap, .terminal:
            0
        }
    }

    var kind: Phase2HumanPTYEventPayloadKind {
        switch self {
        case .input:
            .input
        case .output:
            .output
        case .resize:
            .resize
        case .signal:
            .signal
        case .reconnect:
            .reconnect
        case .gap:
            .gap
        case .terminal:
            .terminal
        }
    }
}

enum Phase2HumanPTYEventPayloadKind: String, Codable, Equatable, Sendable {
    case input
    case output
    case resize
    case signal
    case reconnect
    case gap
    case terminal
}

struct Phase2HumanPTYTranscriptLimits: Equatable, Sendable {
    let maximumEvents: Int
    let maximumEventBytes: Int
    let maximumCumulativeBytes: Int

    static let productionMaximum = Self(
        maximumEvents: 1_024,
        maximumEventBytes: 65_536,
        maximumCumulativeBytes: 4 * 1_024 * 1_024
    )

    var isValid: Bool {
        maximumEvents > 0 &&
            maximumEventBytes > 0 &&
            maximumCumulativeBytes > 0
    }
}

struct Phase2HumanPTYTranscriptValidationResult: Equatable, Sendable {
    let issues: [Phase2HumanPTYTranscriptValidationIssue]

    var isAccepted: Bool { issues.isEmpty }
}

enum Phase2HumanPTYTranscriptValidationIssue: Equatable, Sendable {
    case invalidLimits
    case emptyTranscript
    case eventCountExceeded(count: Int, limit: Int)
    case sessionMismatch(sequence: UInt64, expected: UUID, actual: UUID)
    case firstSequenceNotOne(actual: UInt64)
    case nonContiguousSequence(expected: UInt64, actual: UInt64)
    case disallowedSource(sequence: UInt64, source: Phase2HumanPTYEventSource, payload: Phase2HumanPTYEventPayloadKind)
    case invalidPayload(sequence: UInt64, reason: String)
    case eventTooLarge(sequence: UInt64, byteCount: Int, limit: Int)
    case cumulativeBytesExceeded(total: Int, limit: Int)
    case duplicateTerminal(firstSequence: UInt64, duplicateSequence: UInt64)
    case eventAfterTerminal(sequence: UInt64, terminalSequence: UInt64)
    case missingTerminalOutcome
}

enum Phase2HumanPTYTranscriptValidator {
    static func validate(
        _ transcript: Phase2HumanPTYTranscript,
        limits: Phase2HumanPTYTranscriptLimits = .productionMaximum
    ) -> Phase2HumanPTYTranscriptValidationResult {
        var issues: [Phase2HumanPTYTranscriptValidationIssue] = []

        guard limits.isValid else {
            return Phase2HumanPTYTranscriptValidationResult(issues: [.invalidLimits])
        }
        guard !transcript.events.isEmpty else {
            return Phase2HumanPTYTranscriptValidationResult(issues: [.emptyTranscript])
        }

        if transcript.events.count > limits.maximumEvents {
            issues.append(.eventCountExceeded(count: transcript.events.count, limit: limits.maximumEvents))
        }

        var expectedSequence: UInt64 = 1
        var cumulativeBytes = 0
        var terminalSequence: UInt64?

        for event in transcript.events {
            if event.sessionID != transcript.sessionID {
                issues.append(.sessionMismatch(
                    sequence: event.sequence,
                    expected: transcript.sessionID,
                    actual: event.sessionID
                ))
            }

            let isBrokerGapAdvance: Bool
            if case .gap = event.payload, event.source == .broker {
                isBrokerGapAdvance = event.sequence > expectedSequence
            } else {
                isBrokerGapAdvance = false
            }

            if event.sequence == expectedSequence {
                // valid contiguous sequence
            } else if isBrokerGapAdvance {
                // A broker-authored gap may jump over events lost from a bounded transcript spool.
            } else if expectedSequence == 1 {
                issues.append(.firstSequenceNotOne(actual: event.sequence))
            } else if event.sequence != expectedSequence {
                issues.append(.nonContiguousSequence(expected: expectedSequence, actual: event.sequence))
            }
            expectedSequence = event.sequence &+ 1

            if let terminalSequence {
                issues.append(.eventAfterTerminal(sequence: event.sequence, terminalSequence: terminalSequence))
            }

            if !isSourceAllowed(event.source, for: event.payload) {
                issues.append(.disallowedSource(
                    sequence: event.sequence,
                    source: event.source,
                    payload: event.payload.kind
                ))
            }

            issues.append(contentsOf: validatePayload(event.payload, sequence: event.sequence))

            let eventBytes = event.payload.byteCount
            if eventBytes > limits.maximumEventBytes {
                issues.append(.eventTooLarge(
                    sequence: event.sequence,
                    byteCount: eventBytes,
                    limit: limits.maximumEventBytes
                ))
            }
            cumulativeBytes += eventBytes
            if cumulativeBytes > limits.maximumCumulativeBytes {
                issues.append(.cumulativeBytesExceeded(
                    total: cumulativeBytes,
                    limit: limits.maximumCumulativeBytes
                ))
            }

            if case .terminal = event.payload {
                if let first = terminalSequence {
                    issues.append(.duplicateTerminal(firstSequence: first, duplicateSequence: event.sequence))
                } else {
                    terminalSequence = event.sequence
                }
            }
        }

        if terminalSequence == nil {
            issues.append(.missingTerminalOutcome)
        }

        return Phase2HumanPTYTranscriptValidationResult(issues: issues)
    }

    private static func isSourceAllowed(
        _ source: Phase2HumanPTYEventSource,
        for payload: Phase2HumanPTYEventPayload
    ) -> Bool {
        switch payload {
        case .input, .resize, .signal:
            source == .human
        case .reconnect:
            source == .app
        case .output, .gap, .terminal:
            source == .broker
        }
    }

    private static func validatePayload(
        _ payload: Phase2HumanPTYEventPayload,
        sequence: UInt64
    ) -> [Phase2HumanPTYTranscriptValidationIssue] {
        switch payload {
        case .input(let bytes):
            return bytes.isEmpty ? [.invalidPayload(sequence: sequence, reason: "input payload is empty")] : []
        case .output(_, let bytes):
            return bytes.isEmpty ? [.invalidPayload(sequence: sequence, reason: "output payload is empty")] : []
        case .resize(let columns, let rows):
            if columns <= 0 || rows <= 0 {
                return [.invalidPayload(sequence: sequence, reason: "terminal size must be positive")]
            }
            return []
        case .gap(_, let lostByteCount):
            if lostByteCount <= 0 {
                return [.invalidPayload(sequence: sequence, reason: "gap lost-byte count must be positive")]
            }
            return []
        case .signal, .reconnect, .terminal:
            return []
        }
    }
}

enum Phase2HumanPTYTranscriptSeededCorpus {
    static let requiredTraceCount = 100

    static func traces(count: Int = requiredTraceCount) -> [Phase2HumanPTYTranscript] {
        (0..<count).map(trace(seed:))
    }

    static func trace(seed: Int) -> Phase2HumanPTYTranscript {
        let sessionID = deterministicUUID(seed: seed, discriminator: 1)
        let reconnectID = deterministicUUID(seed: seed, discriminator: 2)
        var builder = Phase2HumanPTYTranscriptBuilder(sessionID: sessionID)

        builder.append(.input(utf8Bytes("echo trace-\(seed)\n")), source: .human)
        builder.append(.output(stream: .standardOutput, bytes: utf8Bytes("trace-\(seed)\n")), source: .broker)

        if seed.isMultiple(of: 2) {
            builder.append(.resize(columns: 100 + (seed % 20), rows: 30 + (seed % 7)), source: .human)
        }
        if seed.isMultiple(of: 3) {
            builder.append(.signal(.interrupt), source: .human)
            builder.append(.output(stream: .standardError, bytes: utf8Bytes("^C\n")), source: .broker)
        }
        if seed.isMultiple(of: 5) {
            builder.append(.gap(reason: .spoolLimitExceeded, lostByteCount: 64 + seed), source: .broker)
        }
        if seed.isMultiple(of: 7) {
            builder.append(.reconnect(reconnectID: reconnectID), source: .app)
            builder.append(.output(stream: .standardOutput, bytes: utf8Bytes("reconnected\n")), source: .broker)
        }

        builder.append(.terminal(seed.isMultiple(of: 11) ? .outcomeUnknown : .exited(status: 0)), source: .broker)
        return builder.transcript
    }

    private static func deterministicUUID(seed: Int, discriminator: Int) -> UUID {
        let value = UInt64(seed * 31 + discriminator)
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value))!
    }

    private static func utf8Bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }
}

private struct Phase2HumanPTYTranscriptBuilder {
    let sessionID: UUID
    private(set) var events: [Phase2HumanPTYTranscriptEvent] = []

    var transcript: Phase2HumanPTYTranscript {
        Phase2HumanPTYTranscript(sessionID: sessionID, events: events)
    }

    mutating func append(
        _ payload: Phase2HumanPTYEventPayload,
        source: Phase2HumanPTYEventSource
    ) {
        events.append(Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: UInt64(events.count + 1),
            source: source,
            payload: payload
        ))
    }
}

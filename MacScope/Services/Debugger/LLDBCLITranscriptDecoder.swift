import CryptoKit
import Foundation

struct LLDBCLIExchangeMarkers: Equatable, Sendable {
    static let tokenCharacterCount = 64

    let requestBeginLine: String
    let commandResultPrefix: String
    let commandsSucceededLine: String
    let commandsFailedPrefix: String
    let statusBeginLine: String
    let statusResultPrefix: String
    let statusEndLine: String
    let requestEndLine: String

    init(token: String) throws {
        guard token.utf8.count == Self.tokenCharacterCount,
              token.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
              }) else {
            throw makeLLDBCLITranscriptFailure(
                code: .invalidMarkerToken,
                evidence: Data(token.utf8)
            )
        }

        requestBeginLine = "__MACSCOPE_LLDB_REQUEST_BEGIN_\(token)__"
        commandResultPrefix = "__MACSCOPE_LLDB_COMMAND_RESULT_\(token)_"
        commandsSucceededLine = "__MACSCOPE_LLDB_COMMANDS_SUCCEEDED_\(token)__"
        commandsFailedPrefix = "__MACSCOPE_LLDB_COMMANDS_FAILED_\(token)_"
        statusBeginLine = "__MACSCOPE_LLDB_STATUS_BEGIN_\(token)__"
        statusResultPrefix = "__MACSCOPE_LLDB_STATUS_RESULT_\(token)_"
        statusEndLine = "__MACSCOPE_LLDB_STATUS_END_\(token)__"
        requestEndLine = "__MACSCOPE_LLDB_REQUEST_END_\(token)__"
    }

    func commandsFailedLine(firstFailedCommandIndex: Int) -> String {
        "\(commandsFailedPrefix)\(firstFailedCommandIndex)__"
    }

    func firstFailedCommandIndex(in line: String) -> Int? {
        guard line.hasPrefix(commandsFailedPrefix), line.hasSuffix("__") else {
            return nil
        }
        let start = line.index(line.startIndex, offsetBy: commandsFailedPrefix.count)
        let end = line.index(line.endIndex, offsetBy: -2)
        let text = line[start..<end]
        guard !text.isEmpty,
              text.allSatisfy(\.isNumber),
              (text == "0" || text.first != "0"),
              let index = Int(text),
              index >= 0 else {
            return nil
        }
        return index
    }

    func commandResult(in line: String) -> (index: Int, transcript: String)? {
        guard line.hasPrefix(commandResultPrefix), line.hasSuffix("__") else {
            return nil
        }
        let start = line.index(line.startIndex, offsetBy: commandResultPrefix.count)
        let end = line.index(line.endIndex, offsetBy: -2)
        let body = line[start..<end]
        guard let separator = body.firstIndex(of: "_") else { return nil }
        let indexText = body[..<separator]
        let payloadStart = body.index(after: separator)
        let payloadText = String(body[payloadStart...])
        guard !indexText.isEmpty,
              indexText.allSatisfy(\.isNumber),
              (indexText == "0" || indexText.first != "0"),
              let index = Int(indexText),
              index >= 0,
              let data = Data(base64Encoded: payloadText),
              data.base64EncodedString() == payloadText,
              let transcript = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (index, transcript)
    }

    func statusResult(in line: String) -> String? {
        guard line.hasPrefix(statusResultPrefix), line.hasSuffix("__") else {
            return nil
        }
        let start = line.index(line.startIndex, offsetBy: statusResultPrefix.count)
        let end = line.index(line.endIndex, offsetBy: -2)
        let payloadText = String(line[start..<end])
        guard let data = Data(base64Encoded: payloadText),
              data.base64EncodedString() == payloadText,
              let transcript = String(data: data, encoding: .utf8) else {
            return nil
        }
        return transcript
    }
}

enum LLDBCLIObservedPIDRequirement: Equatable, Sendable {
    case optional
    case required
}

enum LLDBCLITranscriptDiagnosticCode: String, Equatable, Sendable {
    case invalidMarkerToken
    case invalidRenderedCommand
    case commandTooLarge
    case exchangeTooLarge
    case invalidUTF8
    case ambiguousMarker
    case markerOrderViolation
    case missingRequestBeginMarker
    case missingCommandStatusMarker
    case invalidCommandResultMarker
    case missingStatusBeginMarker
    case missingStatusResultMarker
    case invalidStatusResultMarker
    case missingStatusEndMarker
    case missingRequestEndMarker
    case missingObservedPID
    case ambiguousObservedPID
    case invalidObservedPID
    case ambiguousObservedProcessState
}

struct LLDBCLITranscriptDiagnostic: Equatable, Sendable {
    let code: LLDBCLITranscriptDiagnosticCode
    let preview: String
    let evidenceSHA256: String
    let evidenceByteCount: Int
    let evidenceWasTruncated: Bool
}

struct LLDBCLITranscriptFailure: Error, LocalizedError, Equatable, Sendable {
    let diagnostic: LLDBCLITranscriptDiagnostic

    var code: LLDBCLITranscriptDiagnosticCode {
        diagnostic.code
    }

    var errorDescription: String? {
        diagnostic.preview
    }
}

struct LLDBCLITranscriptResult: Equatable, Sendable {
    let transcript: String
    let authoritativeStatusTranscript: String
    let observedProcessID: Int32?
    let observedProcessState: LLDBCLIObservedProcessState?
    let exchangeByteCount: Int
    let exchangeSHA256: String

    let semanticCommandsSucceeded: Bool
    /// Zero-based index of the first semantic command rejected by LLDB. A non-nil value is
    /// trusted only because it is carried by the per-request unpredictable marker family.
    let firstFailedSemanticCommandIndex: Int?
    /// Output captured directly from each `SBCommandReturnObject`, ordered by semantic-command
    /// index. Target stdout remains in `transcript` and is never eligible for typed projection.
    let semanticCommandTranscripts: [String]
    /// Exact byte count of each complete correlated command-result line, including its LF,
    /// ordered by semantic-command index. Typed decoders use this observed outer evidence instead
    /// of reconstructing a framing size from the decoded payload.
    let semanticCommandResultLineByteCounts: [Int]

    init(
        transcript: String,
        authoritativeStatusTranscript: String,
        observedProcessID: Int32?,
        observedProcessState: LLDBCLIObservedProcessState?,
        exchangeByteCount: Int,
        exchangeSHA256: String,
        semanticCommandsSucceeded: Bool = true,
        firstFailedSemanticCommandIndex: Int? = nil,
        semanticCommandTranscripts: [String] = [],
        semanticCommandResultLineByteCounts: [Int] = []
    ) {
        self.transcript = transcript
        self.authoritativeStatusTranscript = authoritativeStatusTranscript
        self.observedProcessID = observedProcessID
        self.observedProcessState = observedProcessState
        self.exchangeByteCount = exchangeByteCount
        self.exchangeSHA256 = exchangeSHA256
        self.semanticCommandsSucceeded = semanticCommandsSucceeded
        self.firstFailedSemanticCommandIndex = firstFailedSemanticCommandIndex
        self.semanticCommandTranscripts = semanticCommandTranscripts
        self.semanticCommandResultLineByteCounts = semanticCommandResultLineByteCounts
    }

    var trustedSemanticTranscript: String {
        semanticCommandTranscripts.joined(separator: "\n")
    }
}

enum LLDBCLIObservedProcessState: Equatable, Hashable, Sendable {
    case running(processID: Int32)
    case stopped(processID: Int32)
    case exited(processID: Int32, status: Int32?)

    var processID: Int32 {
        switch self {
        case .running(let processID), .stopped(let processID), .exited(let processID, _):
            processID
        }
    }
}

/// Pure incremental decoder for one persistent-CLI request exchange.
///
/// Only output between one exact, ordered marker pair becomes request output.
/// Marker-family text that is foreign or embedded is ambiguous rather than
/// console text. The decoder has no requested-PID input, so it cannot convert
/// an expected identity into an observed identity.
struct LLDBCLITranscriptDecoder: Sendable {
    static let maximumCommandBytes = 4 * 1_024
    static let maximumExchangeBytes = 256 * 1_024
    static let maximumDiagnosticBytes = 4 * 1_024

    private static let markerFamilyPrefix = "__MACSCOPE_LLDB_"

    /// LLDB's default interactive prompt. The retained interpreter reads piped stdin without
    /// libedit, and `IOHandlerEditline::PrintAsync` then re-prints the prompt, with no trailing
    /// newline, after every asynchronous block it writes (§4.88b). After a breakpoint stop that
    /// block (`Process N stopped` … the source listing … `Target 0: stopped.`) can still be
    /// printing when the next exchange runs, so the redrawn prompt lands at the start of the next
    /// line our trusted Python writes: a marker line arrives as `(lldb) __MACSCOPE_LLDB_…`, fails
    /// the exact marker match, and the whole generation was invalidated as an ambiguous marker.
    static let asyncPromptPrefix = "(lldb) "

    /// Removes redrawn prompts glued in front of a marker line, and only there: the remainder
    /// must start with the marker family, so console text is never rewritten and every marker
    /// still has to match exactly (secret token included) after the prompt is removed.
    static func removingAsyncPromptPrefix(_ line: String) -> String {
        guard line.hasPrefix(asyncPromptPrefix) else { return line }
        var remainder = Substring(line)
        while remainder.hasPrefix(asyncPromptPrefix) {
            remainder = remainder.dropFirst(asyncPromptPrefix.count)
        }
        return remainder.hasPrefix(markerFamilyPrefix) ? String(remainder) : line
    }

    private enum FramingPhase: Equatable, Sendable {
        case awaitingRequestBegin
        case collectingConsoleBeforeStatus
        case collectingAuthoritativeStatus
        case collectingConsoleAfterStatus
        case complete
    }

    private let markers: LLDBCLIExchangeMarkers
    private let observedPIDRequirement: LLDBCLIObservedPIDRequirement
    private let requiresSemanticCommandStatus: Bool
    private let expectedSemanticCommandCount: Int?
    private var bufferedBytes = Data()
    private var parsedByteOffset = 0
    private var framingPhase = FramingPhase.awaitingRequestBegin
    private var consoleBeforeStatusLines: [String] = []
    private var statusEnvelopeConsoleLines: [String] = []
    private var authoritativeStatusTranscript: String?
    private var consoleAfterStatusLines: [String] = []
    private var semanticCommandsSucceeded: Bool?
    private var firstFailedSemanticCommandIndex: Int?
    private var semanticCommandTranscripts: [Int: String] = [:]
    private var semanticCommandResultLineByteCounts: [Int: Int] = [:]
    private var terminalFailure: LLDBCLITranscriptFailure?

    init(
        markers: LLDBCLIExchangeMarkers,
        observedPIDRequirement: LLDBCLIObservedPIDRequirement = .optional,
        requiresSemanticCommandStatus: Bool = false,
        expectedSemanticCommandCount: Int? = nil
    ) {
        self.markers = markers
        self.observedPIDRequirement = observedPIDRequirement
        self.requiresSemanticCommandStatus = requiresSemanticCommandStatus
        self.expectedSemanticCommandCount = expectedSemanticCommandCount
    }

    static func validateRenderedCommand(_ command: String) throws {
        let bytes = Data(command.utf8)
        guard !bytes.isEmpty,
              !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
            throw makeLLDBCLITranscriptFailure(
                code: .invalidRenderedCommand,
                evidence: bytes
            )
        }
        guard bytes.count <= maximumCommandBytes else {
            throw makeLLDBCLITranscriptFailure(
                code: .commandTooLarge,
                evidence: bytes
            )
        }
    }

    /// Appends one read-pump fragment. A result is returned only after the exact
    /// end marker is available as a complete line. Partial UTF-8 code points and
    /// partial marker lines remain buffered until their terminating newline.
    mutating func append(_ bytes: Data) throws -> LLDBCLITranscriptResult? {
        if let terminalFailure {
            throw terminalFailure
        }

        let prospectiveCount = bufferedBytes.count.addingReportingOverflow(bytes.count)
        guard !prospectiveCount.overflow,
              prospectiveCount.partialValue <= Self.maximumExchangeBytes else {
            var boundedEvidence = bufferedBytes
            let remaining = max(0, Self.maximumExchangeBytes - boundedEvidence.count)
            boundedEvidence.append(bytes.prefix(remaining))
            let failure = makeLLDBCLITranscriptFailure(
                code: .exchangeTooLarge,
                evidence: boundedEvidence,
                originalEvidenceByteCount: prospectiveCount.overflow
                    ? Int.max
                    : prospectiveCount.partialValue,
                evidenceWasTruncated: true
            )
            terminalFailure = failure
            throw failure
        }

        bufferedBytes.append(bytes)
        do {
            try processAvailableLines(includeFinalPartialLine: false)
            return try completedResult()
        } catch let failure as LLDBCLITranscriptFailure {
            terminalFailure = failure
            throw failure
        }
    }

    /// Closes the exchange boundary. A final non-newline-terminated marker line
    /// is accepted, while a missing member of the marker pair fails closed.
    mutating func finish() throws -> LLDBCLITranscriptResult {
        if let terminalFailure {
            throw terminalFailure
        }

        do {
            try processAvailableLines(includeFinalPartialLine: true)
            if let result = try completedResult() {
                return result
            }
            let code: LLDBCLITranscriptDiagnosticCode
            switch framingPhase {
            case .awaitingRequestBegin:
                code = .missingRequestBeginMarker
            case .collectingConsoleBeforeStatus:
                code = .missingStatusBeginMarker
            case .collectingAuthoritativeStatus:
                code = .missingStatusEndMarker
            case .collectingConsoleAfterStatus:
                code = .missingRequestEndMarker
            case .complete:
                preconditionFailure("A completed exchange must have produced a result.")
            }
            throw makeLLDBCLITranscriptFailure(
                code: code,
                evidence: bufferedBytes
            )
        } catch let failure as LLDBCLITranscriptFailure {
            terminalFailure = failure
            throw failure
        }
    }

    /// Consumes each completed line exactly once. `parsedByteOffset` always
    /// points at the first byte not yet assigned to a line, so fragment arrival
    /// is linear in the total exchange size rather than reparsing the retained
    /// bounded evidence buffer after every read-pump callback.
    private mutating func processAvailableLines(
        includeFinalPartialLine: Bool
    ) throws {
        while parsedByteOffset < bufferedBytes.count {
            let unparsedRange = parsedByteOffset..<bufferedBytes.count
            guard let newlineIndex = bufferedBytes[unparsedRange].firstIndex(of: 0x0a) else {
                break
            }
            try processLine(bytes: bufferedBytes[parsedByteOffset..<newlineIndex])
            parsedByteOffset = newlineIndex + 1
        }

        if includeFinalPartialLine, parsedByteOffset < bufferedBytes.count {
            try processLine(bytes: bufferedBytes[parsedByteOffset..<bufferedBytes.count])
            parsedByteOffset = bufferedBytes.count
        }
    }

    private mutating func processLine(bytes: Data.SubSequence) throws {
        var lineBytes = Data(bytes)
        if lineBytes.last == 0x0d {
            lineBytes.removeLast()
        }
        guard let decodedLine = String(data: lineBytes, encoding: .utf8) else {
            throw failure(.invalidUTF8)
        }
        let line = Self.removingAsyncPromptPrefix(decodedLine)

        switch framingPhase {
        case .awaitingRequestBegin:
            if line == markers.requestBeginLine {
                framingPhase = .collectingConsoleBeforeStatus
            } else {
                try rejectUnexpectedMarker(in: line)
            }

        case .collectingConsoleBeforeStatus:
            if let commandResult = markers.commandResult(in: line) {
                guard semanticCommandsSucceeded == nil,
                      semanticCommandTranscripts[commandResult.index] == nil,
                      semanticCommandResultLineByteCounts[commandResult.index] == nil,
                      expectedSemanticCommandCount.map({ commandResult.index < $0 }) ?? true else {
                    throw failure(.invalidCommandResultMarker)
                }
                semanticCommandTranscripts[commandResult.index] = commandResult.transcript
                // `bytes` excludes the LF found by `processAvailableLines`; count it explicitly.
                // Preserve a preceding CR in the observed byte count even though parsing accepts
                // CRLF by stripping that CR from `lineBytes` above.
                semanticCommandResultLineByteCounts[commandResult.index] = bytes.count + 1
            } else if line.hasPrefix(markers.commandResultPrefix) {
                throw failure(.invalidCommandResultMarker)
            } else if line == markers.commandsSucceededLine {
                guard semanticCommandsSucceeded == nil else {
                    throw failure(.markerOrderViolation)
                }
                semanticCommandsSucceeded = true
            } else if let failureIndex = markers.firstFailedCommandIndex(in: line) {
                guard semanticCommandsSucceeded == nil,
                      expectedSemanticCommandCount.map({ failureIndex < $0 }) ?? true else {
                    throw failure(.markerOrderViolation)
                }
                semanticCommandsSucceeded = false
                firstFailedSemanticCommandIndex = failureIndex
            } else if line == markers.statusBeginLine {
                guard semanticCommandsSucceeded != nil || !requiresSemanticCommandStatus else {
                    throw failure(.missingCommandStatusMarker)
                }
                try validateSemanticCommandResults()
                framingPhase = .collectingAuthoritativeStatus
            } else if line == markers.requestEndLine {
                throw failure(.missingStatusBeginMarker)
            } else {
                try rejectUnexpectedMarker(in: line)
                consoleBeforeStatusLines.append(line)
            }

        case .collectingAuthoritativeStatus:
            if line == markers.statusEndLine {
                guard authoritativeStatusTranscript != nil else {
                    throw failure(.missingStatusResultMarker)
                }
                framingPhase = .collectingConsoleAfterStatus
            } else if let statusResult = markers.statusResult(in: line) {
                guard authoritativeStatusTranscript == nil else {
                    throw failure(.invalidStatusResultMarker)
                }
                authoritativeStatusTranscript = statusResult
            } else if line.hasPrefix(markers.statusResultPrefix) {
                throw failure(.invalidStatusResultMarker)
            } else {
                try rejectUnexpectedMarker(in: line)
                statusEnvelopeConsoleLines.append(line)
            }

        case .collectingConsoleAfterStatus:
            if line == markers.requestEndLine {
                framingPhase = .complete
            } else {
                try rejectUnexpectedMarker(in: line)
                consoleAfterStatusLines.append(line)
            }

        case .complete:
            try rejectUnexpectedMarker(in: line)
        }
    }

    private func rejectUnexpectedMarker(in line: String) throws {
        if line == markers.requestBeginLine
            || line == markers.commandsSucceededLine
            || line == markers.statusBeginLine
            || line == markers.statusEndLine
            || line == markers.requestEndLine {
            throw failure(.markerOrderViolation)
        }
        if line.contains(Self.markerFamilyPrefix) {
            throw failure(.ambiguousMarker)
        }
    }

    private func completedResult() throws -> LLDBCLITranscriptResult? {
        guard framingPhase == .complete else { return nil }
        guard semanticCommandsSucceeded != nil || !requiresSemanticCommandStatus else {
            throw failure(.missingCommandStatusMarker)
        }
        try validateSemanticCommandResults()

        let transcript = (consoleBeforeStatusLines
            + statusEnvelopeConsoleLines
            + consoleAfterStatusLines)
            .joined(separator: "\n")
        guard let authoritativeStatusTranscript else {
            throw failure(.missingStatusResultMarker)
        }
        let observedProcessState = try parseObservedProcessState(
            in: authoritativeStatusTranscript
        )
        let observedProcessID = observedProcessState?.processID
        if observedPIDRequirement == .required, observedProcessID == nil {
            throw failure(.missingObservedPID)
        }

        return LLDBCLITranscriptResult(
            transcript: transcript,
            authoritativeStatusTranscript: authoritativeStatusTranscript,
            observedProcessID: observedProcessID,
            observedProcessState: observedProcessState,
            exchangeByteCount: bufferedBytes.count,
            exchangeSHA256: sha256Hex(bufferedBytes),
            semanticCommandsSucceeded: semanticCommandsSucceeded ?? true,
            firstFailedSemanticCommandIndex: firstFailedSemanticCommandIndex,
            semanticCommandTranscripts: semanticCommandTranscripts
                .sorted { $0.key < $1.key }
                .map(\.value),
            semanticCommandResultLineByteCounts: semanticCommandResultLineByteCounts
                .sorted { $0.key < $1.key }
                .map(\.value)
        )
    }

    private func validateSemanticCommandResults() throws {
        guard requiresSemanticCommandStatus, let expectedSemanticCommandCount else { return }
        let expectedResultCount: Int
        if semanticCommandsSucceeded == true {
            expectedResultCount = expectedSemanticCommandCount
        } else if let firstFailedSemanticCommandIndex {
            expectedResultCount = firstFailedSemanticCommandIndex + 1
        } else {
            throw failure(.missingCommandStatusMarker)
        }
        guard semanticCommandTranscripts.count == expectedResultCount,
              semanticCommandTranscripts.keys.sorted() == Array(0..<expectedResultCount),
              semanticCommandResultLineByteCounts.count == expectedResultCount,
              semanticCommandResultLineByteCounts.keys.sorted() == Array(0..<expectedResultCount) else {
            throw failure(.invalidCommandResultMarker)
        }
    }

    private func parseObservedProcessState(
        in authoritativeStatusTranscript: String
    ) throws -> LLDBCLIObservedProcessState? {
        let expression = try! NSRegularExpression(
            pattern: #"(?m)^[ \t]*Process[ \t]+#?([0-9]+)[ \t]+(?:is[ \t]+)?(launched|running|stopped|exited)\b([^\r\n]*)"#,
            options: [.caseInsensitive]
        )
        let searchRange = NSRange(
            authoritativeStatusTranscript.startIndex..<authoritativeStatusTranscript.endIndex,
            in: authoritativeStatusTranscript
        )
        var observedStates: [LLDBCLIObservedProcessState] = []

        for match in expression.matches(in: authoritativeStatusTranscript, range: searchRange) {
            guard let pidRange = Range(match.range(at: 1), in: authoritativeStatusTranscript),
                  let stateRange = Range(match.range(at: 2), in: authoritativeStatusTranscript),
                  let parsed = Int64(authoritativeStatusTranscript[pidRange]),
                  parsed > 0,
                  parsed <= Int64(Int32.max) else {
                throw failure(.invalidObservedPID)
            }
            let processID = Int32(parsed)
            let stateWord = authoritativeStatusTranscript[stateRange].lowercased()
            let state: LLDBCLIObservedProcessState
            switch stateWord {
            case "launched", "running":
                state = .running(processID: processID)
            case "stopped":
                state = .stopped(processID: processID)
            case "exited":
                state = .exited(
                    processID: processID,
                    status: try parseExitStatus(
                        from: match,
                        in: authoritativeStatusTranscript
                    )
                )
            default:
                continue
            }
            observedStates.append(state)
        }

        let observedProcessIDs = Set(observedStates.map(\.processID))
        guard observedProcessIDs.count <= 1 else {
            throw failure(.ambiguousObservedPID)
        }
        let distinctStates = Set(observedStates)
        guard distinctStates.count <= 1 else {
            throw failure(.ambiguousObservedProcessState)
        }
        return distinctStates.first
    }

    private func parseExitStatus(
        from match: NSTextCheckingResult,
        in transcript: String
    ) throws -> Int32? {
        guard let suffixRange = Range(match.range(at: 3), in: transcript) else {
            return nil
        }
        let suffix = String(transcript[suffixRange])
        let expression = try! NSRegularExpression(
            pattern: #"status[ \t]*=[ \t]*(-?[0-9]+)"#
        )
        let searchRange = NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
        guard let statusMatch = expression.firstMatch(in: suffix, range: searchRange),
              let valueRange = Range(statusMatch.range(at: 1), in: suffix) else {
            return nil
        }
        guard let value = Int64(suffix[valueRange]),
              value >= Int64(Int32.min),
              value <= Int64(Int32.max) else {
            throw failure(.ambiguousObservedProcessState)
        }
        return Int32(value)
    }

    private func failure(
        _ code: LLDBCLITranscriptDiagnosticCode
    ) -> LLDBCLITranscriptFailure {
        makeLLDBCLITranscriptFailure(code: code, evidence: bufferedBytes)
    }
}

private func makeLLDBCLITranscriptFailure(
    code: LLDBCLITranscriptDiagnosticCode,
    evidence: Data,
    originalEvidenceByteCount: Int? = nil,
    evidenceWasTruncated: Bool = false
) -> LLDBCLITranscriptFailure {
    let messages: [LLDBCLITranscriptDiagnosticCode: String] = [
        .invalidMarkerToken: "LLDB CLI marker token is not canonical.",
        .invalidRenderedCommand: "LLDB CLI command must be nonempty, bounded, and single-line.",
        .commandTooLarge: "LLDB CLI command exceeds the 4 KiB UTF-8 bound.",
        .exchangeTooLarge: "LLDB CLI exchange exceeds the 256 KiB bound.",
        .invalidUTF8: "LLDB CLI exchange contains invalid UTF-8.",
        .ambiguousMarker: "LLDB CLI exchange contains a foreign or embedded marker.",
        .markerOrderViolation: "LLDB CLI exchange marker order is invalid or non-unique.",
        .missingRequestBeginMarker: "LLDB CLI exchange is missing its exact request-begin marker.",
        .missingCommandStatusMarker: "LLDB CLI exchange is missing its exact semantic-command status marker.",
        .missingStatusBeginMarker: "LLDB CLI exchange is missing its exact status-begin marker.",
        .missingStatusResultMarker: "LLDB CLI exchange is missing its exact correlated status result.",
        .invalidStatusResultMarker: "LLDB CLI exchange contains a malformed or duplicate correlated status result.",
        .missingStatusEndMarker: "LLDB CLI exchange is missing its exact status-end marker.",
        .missingRequestEndMarker: "LLDB CLI exchange is missing its exact request-end marker.",
        .missingObservedPID: "LLDB CLI exchange did not positively observe a process identifier.",
        .ambiguousObservedPID: "LLDB CLI exchange observed more than one process identifier.",
        .invalidObservedPID: "LLDB CLI exchange observed an invalid process identifier.",
        .ambiguousObservedProcessState: "LLDB CLI exchange observed contradictory process states."
    ]
    let fullPreview = messages[code] ?? "LLDB CLI exchange failed."
    let previewBytes = Data(fullPreview.utf8.prefix(LLDBCLITranscriptDecoder.maximumDiagnosticBytes))
    let preview = String(data: previewBytes, encoding: .utf8) ?? "LLDB CLI exchange failed."

    return LLDBCLITranscriptFailure(
        diagnostic: LLDBCLITranscriptDiagnostic(
            code: code,
            preview: preview,
            evidenceSHA256: sha256Hex(evidence),
            evidenceByteCount: originalEvidenceByteCount ?? evidence.count,
            evidenceWasTruncated: evidenceWasTruncated
        )
    )
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

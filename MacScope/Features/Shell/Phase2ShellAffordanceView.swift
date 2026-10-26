import AppKit
import Observation
import SwiftUI
import LumenTokens
import LumenUI
import UniformTypeIdentifiers

struct Phase2ShellTranscriptLine: Equatable, Identifiable {
    enum Tone: Equatable {
        case human
        case standardOutput
        case standardError
        case control
        case warning
    }

    let sequence: UInt64
    let source: String
    let text: String
    let tone: Tone
    let rawBytes: [UInt8]?

    init(
        sequence: UInt64,
        source: String,
        text: String,
        tone: Tone,
        rawBytes: [UInt8]? = nil
    ) {
        self.sequence = sequence
        self.source = source
        self.text = text
        self.tone = tone
        self.rawBytes = rawBytes
    }

    var id: UInt64 { sequence }
}

struct Phase2ShellTranscriptTurn: Equatable, Identifiable {
    let startSequence: UInt64
    let commandText: String
    let responseLines: [Phase2ShellTranscriptLine]

    var id: UInt64 { startSequence }
}

private struct Phase2ShellAutoPollTaskID: Equatable {
    let sessionID: UUID?
    let isEnabled: Bool
}

struct Phase2ShellTranscriptScrollRequest: Equatable {
    let turnID: UInt64
    let serial: UInt64
}

struct Phase2ShellAffordancePresentation: Equatable {
    let title: String
    let statusTitle: String
    let statusSystemImage: String
    let statusTone: LumenBadge.Tone
    let detail: String
    let transcriptPreview: String
    let transcriptLines: [Phase2ShellTranscriptLine]
    let transcriptTurns: [Phase2ShellTranscriptTurn]
    let transcriptSearchQuery: String
    let transcriptSearchMatchCount: Int
    let transcriptSearchEmptyMessage: String?
    let lastTurnClipboardText: String?
    let visibleTranscriptClipboardText: String?
    let fullTranscriptClipboardText: String?
    let fullTranscriptExportFilename: String?
    let latestVisibleTranscriptSequence: UInt64?
    let latestSourceTranscriptSequence: UInt64?
    let sessionWorkingDirectoryPath: String?
    let restoredLaunchSessionID: UUID?
    let restoredLaunchDraft: Phase2ShellLaunchDraft?
    let restoredTerminalSizeDraft: Phase2ShellTerminalSizeDraft?
    let currentTerminalSize: Phase2HumanPTYTerminalSize
    let terminalSessionID: UUID?
    let terminalRequestID: UUID?
    let terminalLifecycleState: Phase2HumanPTYSessionState?
    let terminalTranscriptEvents: [Phase2HumanPTYTranscriptEvent]
    let canLaunch: Bool
    let canRelaunch: Bool
    let canForgetRestoredContext: Bool
    let canSendInput: Bool
    let canPoll: Bool
    let canResize: Bool
    let canInterrupt: Bool
    let canReconnect: Bool
    let canRetrySessionRecovery: Bool
    let canCleanup: Bool
    let isBusy: Bool
    let isRestoredContext: Bool
    let error: String?
    let autoPollSessionID: UUID?

    var canCopyLastTurn: Bool { lastTurnClipboardText != nil }
    var canCopyVisibleTranscript: Bool { visibleTranscriptClipboardText != nil }
    var canCopyFullTranscript: Bool { fullTranscriptClipboardText != nil }
    var canSaveFullTranscript: Bool { fullTranscriptClipboardText != nil }
    var canClearVisibleTranscript: Bool { latestVisibleTranscriptSequence != nil }
    var isTranscriptSearchActive: Bool { !transcriptSearchQuery.isEmpty }

    func statusDetail(launchMessage: String?) -> String {
        error ?? launchMessage ?? detail
    }

    static func project(
        _ projection: Phase2WorkspaceShellSessionProjection,
        visibleAfterSequence: UInt64? = nil,
        transcriptSearchQuery: String = ""
    ) -> Self {
        let snapshot = projection.snapshot
        let state = snapshot?.state
        let isBusy = projection.isCommandInFlight && projection.inFlightCommand != .pollTranscript
        let isRestoredContext = projection.isRestoredInactiveContext
        let status = statusPresentation(for: state, isRestoredContext: isRestoredContext)
        let sourceEvents = transcriptSourceEvents(
            events: snapshot?.transcriptEvents ?? [],
            fallback: projection.lastAcceptedTranscriptEvents
        )
        let visibleEvents = visibleTranscriptEvents(
            in: sourceEvents,
            after: visibleAfterSequence
        )
        let unfilteredTranscriptPreview = transcriptPreview(
            events: visibleEvents,
            sourceEventsHidden: !sourceEvents.isEmpty && visibleEvents.isEmpty
        )
        let fullTranscriptTurns = transcriptTurns(
            from: sourceEvents,
            maximumRenderedLineCount: nil,
            maximumTurnCount: nil
        )
        let unfilteredTranscriptLines = transcriptLines(from: visibleEvents)
        let unfilteredTranscriptTurns = transcriptTurns(from: visibleEvents)
        let transcriptSearch = filterTranscript(
            lines: unfilteredTranscriptLines,
            turns: unfilteredTranscriptTurns,
            query: transcriptSearchQuery
        )
        let transcriptPreview = transcriptSearch.previewOverride ?? unfilteredTranscriptPreview
        let detail = detailText(
            state: state,
            snapshot: snapshot,
            lastBytesWritten: projection.lastBytesWritten,
            eventCount: snapshot?.transcriptEvents.count ?? 0
        )
        let restoredLaunchPlan = isRestoredContext ? snapshot?.launchPlan : nil
        let restoredLaunchSessionID = restoredLaunchPlan == nil ? nil : snapshot?.sessionID

        return Self(
            title: "Shell",
            statusTitle: isBusy ? busyTitle(for: projection.inFlightCommand) : status.title,
            statusSystemImage: isBusy ? "hourglass" : status.systemImage,
            statusTone: projection.lastError == nil ? status.tone : .warning,
            detail: projection.lastError ?? detail,
            transcriptPreview: transcriptPreview,
            transcriptLines: transcriptSearch.lines,
            transcriptTurns: transcriptSearch.turns,
            transcriptSearchQuery: transcriptSearch.normalizedQuery,
            transcriptSearchMatchCount: transcriptSearch.matchCount,
            transcriptSearchEmptyMessage: transcriptSearch.emptyMessage,
            lastTurnClipboardText: transcriptTurnClipboardText(from: transcriptSearch.turns.last),
            visibleTranscriptClipboardText: visibleTranscriptClipboardText(from: transcriptSearch.turns),
            fullTranscriptClipboardText: visibleTranscriptClipboardText(from: fullTranscriptTurns),
            fullTranscriptExportFilename: fullTranscriptExportFilename(sessionID: snapshot?.sessionID),
            latestVisibleTranscriptSequence: visibleEvents.last?.sequence,
            latestSourceTranscriptSequence: sourceEvents.last?.sequence,
            sessionWorkingDirectoryPath: snapshot?.launchPlan?.workingDirectoryPath,
            restoredLaunchSessionID: restoredLaunchSessionID,
            restoredLaunchDraft: restoredLaunchPlan.map(Phase2ShellLaunchDraft.init(restoredLaunchPlan:)),
            restoredTerminalSizeDraft: restoredLaunchPlan.map { Phase2ShellTerminalSizeDraft(restoredTerminalSize: $0.initialSize) },
            currentTerminalSize: snapshot?.currentTerminalSize ?? .defaultInteractive,
            terminalSessionID: snapshot?.sessionID,
            terminalRequestID: terminalRequestID(from: snapshot),
            terminalLifecycleState: state,
            terminalTranscriptEvents: snapshot?.transcriptEvents ?? [],
            canLaunch: !isBusy && projection.durableRecoveryIdentity == nil && canLaunch(from: state),
            canRelaunch: !isBusy && projection.durableRecoveryIdentity == nil && canLaunch(from: state) && snapshot?.launchPlan != nil,
            canForgetRestoredContext: !isBusy && isRestoredContext,
            canSendInput: isRunning(state),
            canPoll: !projection.isCommandInFlight && isRunning(state),
            canResize: !projection.isCommandInFlight && isRunning(state),
            canInterrupt: isRunning(state),
            canReconnect: !projection.isCommandInFlight && isRunning(state),
            canRetrySessionRecovery: !isBusy && projection.durableRecoveryIdentity != nil && canLaunch(from: state),
            canCleanup: !isBusy && canCleanup(from: state),
            isBusy: isBusy,
            isRestoredContext: isRestoredContext,
            error: projection.lastError,
            autoPollSessionID: (!isBusy && isRunning(state)) ? snapshot?.sessionID : nil
        )
    }

    private static func terminalRequestID(
        from snapshot: Phase2HumanPTYSessionSnapshot?
    ) -> UUID? {
        guard let snapshot else { return nil }
        switch snapshot.state {
        case let .launchRequested(requestID),
             let .prepared(requestID),
             let .launchRejected(requestID, _),
             let .running(requestID, _):
            return requestID
        case .idle, .terminal:
            return snapshot.launchPlan?.requestID
        }
    }

    private static func filterTranscript(
        lines: [Phase2ShellTranscriptLine],
        turns: [Phase2ShellTranscriptTurn],
        query: String
    ) -> (
        lines: [Phase2ShellTranscriptLine],
        turns: [Phase2ShellTranscriptTurn],
        normalizedQuery: String,
        matchCount: Int,
        previewOverride: String?,
        emptyMessage: String?
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return (lines, turns, "", 0, nil, nil)
        }

        let matchingLines = lines.filter { transcriptLine($0, matches: normalizedQuery) }
        let matchingTurns = turns.filter { transcriptTurn($0, matches: normalizedQuery) }
        let commandMatchCount = turns.filter {
            $0.commandText.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.count
        let matchCount = matchingLines.count + commandMatchCount

        if matchingTurns.isEmpty {
            let message = "No transcript matches “\(normalizedQuery)”"
            return ([], [], normalizedQuery, 0, message, message)
        }

        return (
            matchingLines,
            matchingTurns,
            normalizedQuery,
            matchCount,
            "\(matchCount) transcript \(matchCount == 1 ? "match" : "matches") for “\(normalizedQuery)”",
            nil
        )
    }

    private static func transcriptTurn(
        _ turn: Phase2ShellTranscriptTurn,
        matches query: String
    ) -> Bool {
        if turn.commandText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        return turn.responseLines.contains { transcriptLine($0, matches: query) }
    }

    private static func transcriptLine(
        _ line: Phase2ShellTranscriptLine,
        matches query: String
    ) -> Bool {
        line.source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || line.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func statusPresentation(
        for state: Phase2HumanPTYSessionState?,
        isRestoredContext: Bool
    ) -> (title: String, systemImage: String, tone: LumenBadge.Tone) {
        if isRestoredContext {
            return ("Restored", "clock.arrow.circlepath", .neutral)
        }
        guard let state else {
            return ("Not started", "terminal", .neutral)
        }
        switch state {
        case .idle:
            return ("Idle", "terminal", .neutral)
        case .launchRequested:
            return ("Launching", "hourglass", .neutral)
        case .prepared:
            return ("Prepared", "terminal", .neutral)
        case .launchRejected:
            return ("Rejected", "exclamationmark.triangle", .warning)
        case .running:
            return ("Running", "terminal.fill", .success)
        case .terminal:
            return ("Ended", "checkmark.circle", .neutral)
        }
    }

    private static func busyTitle(for command: Phase2WorkspaceShellSessionCommand?) -> String {
        guard let command else { return "Working" }
        switch command {
        case .launch:
            return "Launching"
        case .writeInput:
            return "Sending"
        case .resize:
            return "Resizing"
        case .signal:
            return "Signaling"
        case .reconnect:
            return "Reconnecting"
        case .pollTranscript:
            return "Polling"
        case .cleanup:
            return "Stopping"
        }
    }

    private static func detailText(
        state: Phase2HumanPTYSessionState?,
        snapshot: Phase2HumanPTYSessionSnapshot?,
        lastBytesWritten: Int?,
        eventCount: Int
    ) -> String {
        guard let state else {
            return "Launches a human-owned local shell through the signed ShellBroker."
        }
        switch state {
        case .idle:
            return "Ready to launch /bin/zsh through the signed ShellBroker."
        case .launchRequested:
            return "Launch request accepted locally; waiting for broker preparation."
        case .prepared:
            return "Broker prepared the session; waiting for process start."
        case .launchRejected(_, let reason):
            return "Launch rejected: \(reason)"
        case .running(_, let processIdentifier):
            let cwd = snapshot?.launchPlan?.workingDirectoryPath.map { " · cwd \($0)" } ?? ""
            if let lastBytesWritten {
                return "PID \(processIdentifier)\(cwd) · \(eventCount) transcript events · wrote \(lastBytesWritten) bytes"
            }
            return "PID \(processIdentifier)\(cwd) · \(eventCount) transcript events"
        case .terminal(let outcome):
            return "Session ended: \(terminalOutcomeText(outcome))"
        }
    }

    private static func transcriptSourceEvents(
        events: [Phase2HumanPTYTranscriptEvent],
        fallback: [Phase2HumanPTYTranscriptEvent]
    ) -> [Phase2HumanPTYTranscriptEvent] {
        events.isEmpty ? fallback : events
    }

    private static func transcriptPreview(
        events sourceEvents: [Phase2HumanPTYTranscriptEvent],
        sourceEventsHidden: Bool
    ) -> String {
        let snippets = sourceEvents.suffix(3).map(transcriptSnippet)
        guard !snippets.isEmpty else {
            return sourceEventsHidden ? "Visible transcript cleared" : "No transcript yet"
        }
        return snippets.joined(separator: " · ")
    }

    private static func visibleTranscriptEvents(
        in events: [Phase2HumanPTYTranscriptEvent],
        after sequence: UInt64?
    ) -> [Phase2HumanPTYTranscriptEvent] {
        guard let sequence else { return events }
        return events.filter { $0.sequence > sequence }
    }

    private static func transcriptLines(
        from events: [Phase2HumanPTYTranscriptEvent]
    ) -> [Phase2ShellTranscriptLine] {
        events
            .suffix(AppShellChrome.maximumRenderedTranscriptLines)
            .map(transcriptLine)
    }

    private static func transcriptTurns(
        from events: [Phase2HumanPTYTranscriptEvent],
        maximumRenderedLineCount: Int? = AppShellChrome.maximumRenderedTranscriptLines,
        maximumTurnCount: Int? = AppShellChrome.maximumRenderedTranscriptTurns
    ) -> [Phase2ShellTranscriptTurn] {
        var turns: [Phase2ShellTranscriptTurn] = []
        var activeTurn: Phase2ShellTranscriptTurn?

        let renderedEvents = maximumRenderedLineCount.map { events.suffix($0) } ?? events[...]
        for event in renderedEvents {
            let line = transcriptLine(event)

            if case .input = event.payload {
                if let activeTurn {
                    turns.append(activeTurn)
                }
                activeTurn = Phase2ShellTranscriptTurn(
                    startSequence: event.sequence,
                    commandText: commandTurnText(from: line.text),
                    responseLines: []
                )
                continue
            }

            if let current = activeTurn {
                activeTurn = Phase2ShellTranscriptTurn(
                    startSequence: current.startSequence,
                    commandText: current.commandText,
                    responseLines: current.responseLines + [line]
                )
            } else {
                activeTurn = Phase2ShellTranscriptTurn(
                    startSequence: event.sequence,
                    commandText: "Session",
                    responseLines: [line]
                )
            }
        }

        if let activeTurn {
            turns.append(activeTurn)
        }

        guard let maximumTurnCount else { return turns }
        return Array(turns.suffix(maximumTurnCount))
    }

    private static func transcriptTurnClipboardText(from turn: Phase2ShellTranscriptTurn?) -> String? {
        guard let turn else { return nil }

        var lines: [String] = turn.commandText == "Session"
            ? ["# Session"]
            : ["$ \(turn.commandText)"]
        lines.append(contentsOf: turn.responseLines.map { "\($0.source): \($0.text)" })
        return lines.joined(separator: "\n")
    }

    private static func visibleTranscriptClipboardText(
        from turns: [Phase2ShellTranscriptTurn]
    ) -> String? {
        let renderedTurns = turns.compactMap(transcriptTurnClipboardText)
        guard !renderedTurns.isEmpty else { return nil }
        return renderedTurns.joined(separator: "\n\n")
    }

    private static func fullTranscriptExportFilename(sessionID: UUID?) -> String? {
        guard let sessionID else { return nil }
        let shortID = sessionID.uuidString.prefix(8).lowercased()
        return "MacScope-Shell-Transcript-\(shortID)"
    }

    private static func commandTurnText(from inputText: String) -> String {
        inputText.hasSuffix("↵") ? String(inputText.dropLast()) : inputText
    }

    private static func transcriptLine(_ event: Phase2HumanPTYTranscriptEvent) -> Phase2ShellTranscriptLine {
        switch event.payload {
        case .input(let bytes):
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: "in",
                text: displayText(for: bytes),
                tone: .human,
                rawBytes: bytes
            )
        case .output(let stream, let bytes):
            let prefix = stream == .standardError ? "err" : "out"
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: prefix,
                text: displayText(for: bytes),
                tone: stream == .standardError ? .standardError : .standardOutput,
                rawBytes: bytes
            )
        case .resize(let columns, let rows):
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: "ctl",
                text: "resize \(columns)×\(rows)",
                tone: .control
            )
        case .signal(let signal):
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: "sig",
                text: signal.rawValue,
                tone: .warning
            )
        case .reconnect:
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: "ctl",
                text: "reconnect",
                tone: .control
            )
        case .gap(let reason, let lostByteCount):
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: "gap",
                text: "\(reason.rawValue), \(lostByteCount) bytes lost",
                tone: .warning
            )
        case .terminal(let outcome):
            return Phase2ShellTranscriptLine(
                sequence: event.sequence,
                source: "end",
                text: terminalOutcomeText(outcome),
                tone: .control
            )
        }
    }

    private static func transcriptSnippet(_ event: Phase2HumanPTYTranscriptEvent) -> String {
        let line = transcriptLine(event)
        return "\(line.source): \(line.text)"
    }

    private static func displayText(for bytes: [UInt8]) -> String {
        let decoded = String(decoding: bytes, as: UTF8.self)
        let collapsed = sanitizedTerminalDisplayText(decoded)
        if collapsed.count > AppShellChrome.transcriptLineCharacterLimit {
            return "\(collapsed.prefix(AppShellChrome.transcriptLineCharacterLimit - 3))…"
        }
        return collapsed.isEmpty ? "∅" : collapsed
    }

    private static func sanitizedTerminalDisplayText(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]

            if scalar.value == 0x1B {
                let next = text.unicodeScalars.index(after: index)
                if next < text.unicodeScalars.endIndex {
                    let introducer = text.unicodeScalars[next]
                    if introducer == "[" {
                        index = indexAfterControlSequence(
                            in: text.unicodeScalars,
                            startingAt: text.unicodeScalars.index(after: next),
                            terminator: { scalar in scalar.value >= 0x40 && scalar.value <= 0x7E }
                        )
                        continue
                    }
                    if introducer == "]" {
                        index = indexAfterOperatingSystemCommand(
                            in: text.unicodeScalars,
                            startingAt: text.unicodeScalars.index(after: next)
                        )
                        continue
                    }
                }
                output.append("\u{241B}")
                index = next
                continue
            }

            appendDisplayScalar(scalar, to: &output)
            index = text.unicodeScalars.index(after: index)
        }

        return String(output)
    }

    private static func indexAfterControlSequence(
        in scalars: String.UnicodeScalarView,
        startingAt start: String.UnicodeScalarView.Index,
        terminator: (UnicodeScalar) -> Bool
    ) -> String.UnicodeScalarView.Index {
        var index = start
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if terminator(scalar) {
                return index
            }
        }
        return scalars.endIndex
    }

    private static func indexAfterOperatingSystemCommand(
        in scalars: String.UnicodeScalarView,
        startingAt start: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index {
        var index = start
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 0x07 {
                return scalars.index(after: index)
            }
            if scalar.value == 0x1B {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\\" {
                    return scalars.index(after: next)
                }
            }
            index = scalars.index(after: index)
        }
        return scalars.endIndex
    }

    private static func appendDisplayScalar(
        _ scalar: UnicodeScalar,
        to output: inout String.UnicodeScalarView
    ) {
        switch scalar.value {
        case 0x09:
            output.append("\u{21E5}")
        case 0x0A:
            output.append("\u{21B5}")
        case 0x0D:
            return
        case 0x00...0x1F:
            output.append(UnicodeScalar(0x2400 + scalar.value)!)
        case 0x7F:
            output.append("\u{2421}")
        default:
            output.append(scalar)
        }
    }

    private static func terminalOutcomeText(_ outcome: Phase2HumanPTYTerminalOutcome) -> String {
        switch outcome {
        case .exited(let status):
            return "exited \(status)"
        case .signaled(let signal):
            return "signaled \(signal.rawValue)"
        case .canceled:
            return "canceled"
        case .interrupted:
            return "interrupted"
        case .brokerCrashed:
            return "broker crashed"
        case .outcomeUnknown:
            return "unknown"
        }
    }

    private static func canLaunch(from state: Phase2HumanPTYSessionState?) -> Bool {
        guard let state else { return true }
        switch state {
        case .idle, .launchRejected, .terminal:
            return true
        case .launchRequested, .prepared, .running:
            return false
        }
    }

    private static func isRunning(_ state: Phase2HumanPTYSessionState?) -> Bool {
        guard case .running = state else { return false }
        return true
    }

    private static func canCleanup(from state: Phase2HumanPTYSessionState?) -> Bool {
        switch state {
        case .launchRequested, .prepared, .running:
            return true
        case .none, .idle, .launchRejected, .terminal:
            return false
        }
    }
}

struct Phase2ShellAffordanceRendererWiring: Equatable {
    enum TerminalCallbackAuthority: Equatable {
        case unavailable
        case legacy(sessionID: UUID, requestID: UUID)
        case surface(Phase2ShellSurfaceCommandCoordinate)
    }

    let rendererSelection: Phase2TerminalRendererSelection?
    let terminalSessionID: UUID?
    let terminalRequestID: UUID?
    let terminalLifecycleState: Phase2HumanPTYSessionState?
    let fullSurfaceCoordinate: Phase2ShellSurfaceCommandCoordinate?
    let renderingResolution: Phase2TerminalSurfacePresentation.RenderingResolution?
    let pollingOwner: Phase2ShellTranscriptPollingOwner

    var terminalRendererGeneration: UInt64? {
        fullSurfaceCoordinate?.generation
    }

    var terminalCallbackAuthority: TerminalCallbackAuthority {
        guard let renderingResolution,
              let terminalSessionID,
              let terminalRequestID,
              pollingOwner != .unselected
        else { return .unavailable }

        switch renderingResolution.path {
        case .ghosttyFullSurface:
            guard let fullSurfaceCoordinate else { return .unavailable }
            return .surface(fullSurfaceCoordinate)
        case .ghostty:
            if let fullSurfaceCoordinate {
                return .surface(fullSurfaceCoordinate)
            }
            return .legacy(sessionID: terminalSessionID, requestID: terminalRequestID)
        case .transcriptFallback:
            return .unavailable
        }
    }

    static func project(
        isTerminalPresented: Bool,
        rendererSelection: Phase2TerminalRendererSelection?,
        terminalSessionID: UUID?,
        terminalRequestID: UUID?,
        terminalLifecycleState: Phase2HumanPTYSessionState?,
        transcriptEvents: [Phase2HumanPTYTranscriptEvent],
        bindingCoordinate: Phase2ShellSurfaceCommandCoordinate?,
        mediatedCoordinate: Phase2ShellSurfaceCommandCoordinate?
    ) -> Self {
        let hasExactRunningProcessAuthority: Bool
        if let terminalRequestID,
           case let .running(lifecycleRequestID, processIdentifier) = terminalLifecycleState,
           lifecycleRequestID == terminalRequestID,
           processIdentifier > 0 {
            hasExactRunningProcessAuthority = true
        } else {
            hasExactRunningProcessAuthority = false
        }
        let hasResidualSurfaceAuthority = bindingCoordinate != nil || mediatedCoordinate != nil

        let fullSurfaceCoordinate: Phase2ShellSurfaceCommandCoordinate?
        if isTerminalPresented,
           rendererSelection?.backend == .ghosttyFullSurface,
           hasExactRunningProcessAuthority,
           let terminalSessionID,
           let terminalRequestID,
           let bindingCoordinate,
           bindingCoordinate.isStructurallyValid,
           bindingCoordinate.sessionID == terminalSessionID,
           bindingCoordinate.requestID == terminalRequestID,
           mediatedCoordinate == bindingCoordinate {
            fullSurfaceCoordinate = bindingCoordinate
        } else {
            fullSurfaceCoordinate = nil
        }

        let hasCompleteFullSurfaceReplay: Bool
        if let fullSurfaceCoordinate,
           case .complete = Phase2GhosttyTranscriptAdmissionState.replay(
               coordinate: fullSurfaceCoordinate.rendererCoordinate,
               events: transcriptEvents
           ) {
            hasCompleteFullSurfaceReplay = true
        } else {
            hasCompleteFullSurfaceReplay = false
        }

        let renderingResolution: Phase2TerminalSurfacePresentation.RenderingResolution?
        if isTerminalPresented {
            renderingResolution = Phase2TerminalSurfacePresentation.renderingResolution(
                rendererSelection: rendererSelection,
                fullSurfaceAvailable: hasCompleteFullSurfaceReplay,
                fullSurfaceFallbackReason: fullSurfaceCoordinate == nil
                    ? .rendererCoordinateUnavailable
                    : .none,
                sessionID: terminalSessionID,
                events: transcriptEvents
            )
        } else {
            renderingResolution = nil
        }

        let pollingOwner: Phase2ShellTranscriptPollingOwner
        if !isTerminalPresented
            || !hasExactRunningProcessAuthority
            || terminalSessionID == nil
            || terminalRequestID == nil
            || rendererSelection == nil {
            pollingOwner = .unselected
        } else {
            switch rendererSelection?.backend {
            case .macScopeGhosttyVTGrid:
                pollingOwner = hasResidualSurfaceAuthority ? .unselected : .legacyManual
            case .ghosttyFullSurface:
                if let fullSurfaceCoordinate,
                   renderingResolution?.path == .ghosttyFullSurface {
                    pollingOwner = .continuousSurface(fullSurfaceCoordinate)
                } else if fullSurfaceCoordinate != nil {
                    // The native generation is bound, but an empty or rejected replay means the
                    // full-surface controller does not exist yet. Keep the legacy reducer alive
                    // so an empty launch can acquire its first authoritative broker event.
                    pollingOwner = .legacyManual
                } else {
                    pollingOwner = .unselected
                }
            case nil:
                pollingOwner = .unselected
            }
        }

        return Self(
            rendererSelection: rendererSelection,
            terminalSessionID: terminalSessionID,
            terminalRequestID: terminalRequestID,
            terminalLifecycleState: terminalLifecycleState,
            fullSurfaceCoordinate: fullSurfaceCoordinate,
            renderingResolution: renderingResolution,
            pollingOwner: pollingOwner
        )
    }

    func acceptsFullSurfaceTranscript(
        _ transcript: Phase2GhosttyTranscriptProjection
    ) -> Bool {
        guard let fullSurfaceCoordinate,
              renderingResolution?.path == .ghosttyFullSurface
        else { return false }
        return transcript.coordinate == fullSurfaceCoordinate.rendererCoordinate
    }
}

struct Phase2ShellAffordanceTerminalCallbackFence: Equatable {
    let presentationID: UUID
    let wiring: Phase2ShellAffordanceRendererWiring

    func permits(
        currentPresentationID: UUID,
        currentWiring: Phase2ShellAffordanceRendererWiring
    ) -> Bool {
        presentationID == currentPresentationID
            && wiring == currentWiring
            && wiring.terminalCallbackAuthority != .unavailable
    }
}

struct Phase2ShellAffordanceRendererState: Equatable {
    enum Phase: Equatable {
        case inactive
        case presenting(Phase2TerminalRendererSelection)
        case retiring(
            transitionID: UUID,
            replacement: Phase2TerminalRendererSelection
        )
    }

    enum Transition: Equatable {
        case unchanged
        case present(Phase2TerminalRendererSelection)
        case retireSurface(
            Phase2ShellSurfaceCommandCoordinate,
            transitionID: UUID
        )
    }

    private(set) var phase: Phase = .inactive

    var presentedSelection: Phase2TerminalRendererSelection? {
        guard case let .presenting(selection) = phase else { return nil }
        return selection
    }

    var pendingTransitionID: UUID? {
        guard case let .retiring(transitionID, _) = phase else { return nil }
        return transitionID
    }

    var presentsTerminal: Bool {
        presentedSelection != nil
    }

    mutating func activate(
        _ selection: Phase2TerminalRendererSelection
    ) -> Transition {
        guard case .inactive = phase else { return .unchanged }
        phase = .presenting(selection)
        return .present(selection)
    }

    mutating func update(
        to selection: Phase2TerminalRendererSelection,
        retiringCoordinate: Phase2ShellSurfaceCommandCoordinate?,
        transitionID: UUID = UUID()
    ) -> Transition {
        if case let .retiring(pendingTransitionID, _) = phase {
            phase = .retiring(
                transitionID: pendingTransitionID,
                replacement: selection
            )
            return .unchanged
        }

        if presentedSelection == selection {
            return .unchanged
        }

        if let current = presentedSelection,
           current.backend == .ghosttyFullSurface,
           selection.backend != .ghosttyFullSurface,
           let retiringCoordinate {
            phase = .retiring(
                transitionID: transitionID,
                replacement: selection
            )
            return .retireSurface(
                retiringCoordinate,
                transitionID: transitionID
            )
        }

        phase = .presenting(selection)
        return .present(selection)
    }

    mutating func completeRetirement(
        transitionID: UUID
    ) -> Phase2TerminalRendererSelection? {
        guard case let .retiring(candidate, replacement) = phase,
              candidate == transitionID
        else { return nil }
        phase = .presenting(replacement)
        return replacement
    }

    mutating func deactivate() {
        phase = .inactive
    }
}

@MainActor
@Observable
final class Phase2ShellAffordanceState {
    var pendingInput = ""
    var inputHistory = Phase2ShellInputHistory()
    var isApplyingHistoryNavigation = false
    var visibleTranscriptCutoffSequence: UInt64?
    var transcriptSearchText = ""
    var isAutoPollingEnabled = true
    var shouldFollowLatestTranscript = true
    var transcriptScrollRequestSerial: UInt64 = 0
    var transcriptScrollRequest: Phase2ShellTranscriptScrollRequest?
    var launchExecutablePath = "/bin/zsh"
    var launchArgumentsText = ""
    var launchEnvironmentText = ""
    var launchWorkingDirectoryPath = ""
    var isLaunchSettingsPresented = false
    var terminalColumnsText = "\(Phase2HumanPTYTerminalSize.defaultInteractive.columns)"
    var terminalRowsText = "\(Phase2HumanPTYTerminalSize.defaultInteractive.rows)"
    var lastAppliedRestoredLaunchSessionID: UUID?
    var rendererState = Phase2ShellAffordanceRendererState()
    var ghosttySurfaceBinding = Phase2GhosttySurfaceBindingState()
    var terminalPresentationID = UUID()
    var isAffordanceVisible = false
    let terminalRendererLifecycle = MacScopeGhosttySurfaceDiagnostics
        .RendererLifecycleCoordinator(diagnostics: .rendererEvidenceShared)

    /// Ends only the view's authority. The store still owns the exact broker session,
    /// transcript and operation lease; only explicit Stop may clean up the PTY.
    func retirePresentation(in store: WorkspaceStore) {
        guard isAffordanceVisible else { return }
        isAffordanceVisible = false
        isLaunchSettingsPresented = false
        terminalPresentationID = UUID()
        rendererState.deactivate()
        if let coordinate = ghosttySurfaceBinding.retire() {
            store.retirePhase2ShellSurface(coordinate)
        }
    }
}

@MainActor
struct Phase2ShellAffordanceView: View {
    @ObservedObject var store: WorkspaceStore
    @Bindable var state: Phase2ShellAffordanceState
    @State private var sendingInput = false
    @ObservedObject private var ghosttyRuntime = MacScopeGhosttyRuntime.productionShared

    private var presentation: Phase2ShellAffordancePresentation {
        Phase2ShellAffordancePresentation.project(
            store.phase2ShellSession,
            visibleAfterSequence: state.visibleTranscriptCutoffSequence,
            transcriptSearchQuery: state.transcriptSearchText
        )
    }

    private var autoPollTaskID: Phase2ShellAutoPollTaskID {
        Phase2ShellAutoPollTaskID(
            sessionID: presentation.autoPollSessionID,
            isEnabled: state.isAutoPollingEnabled && transcriptPollingOwner.permitsManualReduction
        )
    }

    private var terminalRendererSelection: Phase2TerminalRendererSelection? {
        state.rendererState.presentedSelection
    }

    private var rendererWiring: Phase2ShellAffordanceRendererWiring {
        Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: state.isAffordanceVisible && state.rendererState.presentsTerminal,
            rendererSelection: terminalRendererSelection,
            terminalSessionID: presentation.terminalSessionID,
            terminalRequestID: presentation.terminalRequestID,
            terminalLifecycleState: presentation.terminalLifecycleState,
            transcriptEvents: presentation.terminalTranscriptEvents,
            bindingCoordinate: state.ghosttySurfaceBinding.activeCoordinate,
            mediatedCoordinate: store.phase2ShellSession.surfaceMediation?.coordinate
        )
    }

    private var transcriptPollingOwner: Phase2ShellTranscriptPollingOwner {
        rendererWiring.pollingOwner
    }

    private var activeGhosttySurfaceCoordinate: Phase2ShellSurfaceCommandCoordinate? {
        rendererWiring.fullSurfaceCoordinate
    }

    @MainActor
    private var fullSurfaceRendererFactory: Phase2TerminalEmulatorView.FullSurfaceRendererFactory? {
        guard let coordinate = activeGhosttySurfaceCoordinate else { return nil }
        let store = store
        return { context in
            guard context.transcript.coordinate == coordinate.rendererCoordinate else { return nil }
            return AnyView(
                Phase2GhosttyBrokerSurface(
                    store: store,
                    coordinate: coordinate,
                    context: context
                )
                .id(coordinate)
            )
        }
    }

    private var launchDraft: Phase2ShellLaunchDraft {
        Phase2ShellLaunchDraft(
            executablePathText: state.launchExecutablePath,
            argumentsText: state.launchArgumentsText,
            environmentText: state.launchEnvironmentText,
            workingDirectoryPathText: state.launchWorkingDirectoryPath
        )
    }

    private var terminalSizeDraft: Phase2ShellTerminalSizeDraft {
        Phase2ShellTerminalSizeDraft(
            columnsText: state.terminalColumnsText,
            rowsText: state.terminalRowsText
        )
    }

    private var launchWorkingDirectoryMessage: String? {
        if let validation = launchDraft.launchConfigurationValidationMessage {
            return validation
        }
        if let validation = terminalSizeDraft.terminalSizeValidationMessage {
            return validation
        }
        if let sessionPath = presentation.sessionWorkingDirectoryPath {
            return "Session cwd \(sessionPath)"
        }
        return nil
    }

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .workbenchPaneBackground(.debugger)
        .frame(minHeight: 0, maxHeight: .infinity)
        .task(id: autoPollTaskID) {
            await runAutoPollLoop(sessionID: autoPollTaskID.sessionID)
        }
        .task(id: state.rendererState.pendingTransitionID) {
            await completeRendererRetirement(
                transitionID: state.rendererState.pendingTransitionID
            )
        }
        .onAppear {
            handleAffordanceAppearance()
        }
        .onChange(of: ghosttyRuntime.state) { _, runtimeState in
            guard state.isAffordanceVisible else { return }
            applyRendererSelection(.resolve(
                feature: ghosttyRuntime.feature,
                runtimeState: runtimeState
            ))
        }
        .onChange(of: store.phase2ShellSession) { _, _ in
            guard state.isAffordanceVisible else { return }
            applyRestoredLaunchDraftIfNeeded()
            reconcileGhosttySurfaceBinding(rendererSelection: terminalRendererSelection)
        }
        .onDisappear {
            handleAffordanceDisappearance()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack(spacing: Lumen.Space.s5) {
                Label(presentation.title, systemImage: "terminal")
                    .font(.body.weight(.semibold))
                    .fixedSize()

                LumenBadge(presentation.statusTitle, systemImage: presentation.statusSystemImage, tone: presentation.statusTone)

                Spacer(minLength: Lumen.Space.s5)

                Button("Launch") {
                    launchShell()
                }
                .controlSize(.small)
                .disabled(!presentation.canLaunch || !canUseLaunchDraft)
                .fixedSize(horizontal: true, vertical: false)

                Menu("Shell Actions") {
                    Button("Relaunch") {
                        relaunchShell()
                    }
                    .disabled(!presentation.canRelaunch)

                    Button("Copy Launch Configuration") {
                        copyLaunchSummary()
                    }
                    .disabled(launchSummaryClipboardText == nil)

                    Button("Forget Restored Context") {
                        forgetRestoredShellContext()
                    }
                    .disabled(!presentation.canForgetRestoredContext)

                    Divider()

                    Button("Poll Now") {
                        pollShell()
                    }
                    .disabled(
                        !presentation.canPoll || !transcriptPollingOwner.permitsManualReduction
                    )

                    Button("Resize Terminal") {
                        resizeShell()
                    }
                    .disabled(!presentation.canResize || !canUseTerminalSizeDraft)

                    Button("Interrupt Shell") {
                        interruptShell()
                    }
                    .disabled(!presentation.canInterrupt)

                    Button("Reconnect Shell") {
                        reconnectShell()
                    }
                    .disabled(!presentation.canReconnect)

                    Button("Retry Session Recovery") {
                        store.schedulePhase2DurableShellRecoveryIfNeeded()
                    }
                    .disabled(!presentation.canRetrySessionRecovery)

                    Button("Stop Shell") {
                        stopShell()
                    }
                    .disabled(!presentation.canCleanup)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Menu("Transcript") {
                    Button("Copy Last Turn") {
                        copyLastTurn()
                    }
                    .disabled(!presentation.canCopyLastTurn)

                    Button("Copy Visible Transcript") {
                        copyVisibleTranscript()
                    }
                    .disabled(!presentation.canCopyVisibleTranscript)

                    Button("Copy Full Transcript") {
                        copyFullTranscript()
                    }
                    .disabled(!presentation.canCopyFullTranscript)

                    Button("Save Full Transcript…") {
                        saveFullTranscript()
                    }
                    .disabled(!presentation.canSaveFullTranscript)

                    Button("Clear Visible Transcript") {
                        clearVisibleTranscript()
                    }
                    .disabled(!presentation.canClearVisibleTranscript)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }

            Text(presentation.statusDetail(launchMessage: launchWorkingDirectoryMessage))
                .font(.caption)
                .foregroundStyle(statusDetailForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    minWidth: AppShellChrome.statusDetailMinWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )

            ViewThatFits(in: .horizontal) {
                inlineLaunchConfiguration
                compactLaunchConfiguration
            }

            transcriptScrollback

            HStack(spacing: Lumen.Space.s5) {
                TextField("Find transcript", text: $state.transcriptSearchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(
                        minWidth: AppShellChrome.transcriptSearchMinWidth,
                        idealWidth: AppShellChrome.transcriptSearchIdealWidth,
                        maxWidth: 220
                    )
                    .disabled(presentation.latestSourceTranscriptSequence == nil)

                Button {
                    state.transcriptSearchText.removeAll()
                } label: {
                    Image(systemName: "xmark")
                }
                .controlSize(.small)
                .disabled(!presentation.isTranscriptSearchActive)
                .help("Clear transcript search")
                .accessibilityLabel("Clear transcript search")

                transcriptNavigationMenu

                TextField("Send shell input", text: $state.pendingInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(
                        minWidth: AppShellChrome.inputMinWidth,
                        idealWidth: AppShellChrome.inputIdealWidth
                    )
                    .disabled(!presentation.canSendInput)
                    .onSubmit(sendInput)
                    .onChange(of: state.pendingInput) { _, _ in
                        if state.isApplyingHistoryNavigation {
                            state.isApplyingHistoryNavigation = false
                            return
                        }
                        if state.inputHistory.cursor != nil {
                            state.inputHistory.resetNavigation()
                        }
                    }

                Button("Send") {
                    sendInput()
                }
                .controlSize(.small)
                .disabled(!presentation.canSendInput || state.pendingInput.isEmpty || sendingInput)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, AppShellChrome.horizontalPadding)
        .padding(.vertical, AppShellChrome.verticalPadding)
        .background(Color.lumen(.deckBackground))
    }

    private var statusDetailForeground: Color {
        presentation.error == nil
            && launchDraft.launchConfigurationValidationMessage == nil
            && terminalSizeDraft.terminalSizeValidationMessage == nil
        ? .secondary
        : Color.lumen(.statusWarning)
    }

    private var inlineLaunchConfiguration: some View {
        HStack(alignment: .bottom, spacing: Lumen.Space.s4) {
            launchField("Executable", "/bin/zsh", $state.launchExecutablePath, AppShellChrome.executableFieldMinWidth)
            launchField("Arguments", "-lc \"printf hi\"", $state.launchArgumentsText, AppShellChrome.argumentsFieldMinWidth)
            launchField("Environment", "KEY=value; TERM=xterm-256color", $state.launchEnvironmentText, AppShellChrome.environmentFieldMinWidth)
            launchField("Working Directory", "ShellBroker default", $state.launchWorkingDirectoryPath, AppShellChrome.workingDirectoryFieldMinWidth)
            terminalSizeFields
        }
    }

    private var compactLaunchConfiguration: some View {
        HStack(spacing: Lumen.Space.s5) {
            Button {
                state.isLaunchSettingsPresented = true
            } label: {
                Label("Launch Settings…", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .popover(isPresented: $state.isLaunchSettingsPresented, arrowEdge: .bottom) {
                launchSettingsPopover
            }

            Text("Executable \(launchDraft.normalizedExecutablePath ?? "Not set") · \(state.terminalColumnsText) × \(state.terminalRowsText)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: AppShellChrome.compactConfigurationSummaryMinWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func launchField(
        _ title: String,
        _ placeholder: String,
        _ text: Binding<String>,
        _ minWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(minWidth: minWidth)
                .disabled(!presentation.canLaunch)
        }
    }

    private var terminalSizeFields: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text("Terminal Size")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            terminalDimensionsRow
        }
    }

    private var terminalDimensionsRow: some View {
        HStack(spacing: Lumen.Space.s2) {
            TextField("cols", text: $state.terminalColumnsText)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(width: AppShellChrome.terminalDimensionFieldWidth)
            Text("×").foregroundStyle(.secondary)
            TextField("rows", text: $state.terminalRowsText)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(width: AppShellChrome.terminalDimensionFieldWidth)
        }
    }

    private var launchSettingsPopover: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Launch Settings").font(.headline)
            popoverField("Executable", "/bin/zsh", $state.launchExecutablePath)
            popoverField("Arguments", "-lc \"printf hi\"", $state.launchArgumentsText)
            popoverField("Environment", "KEY=value; TERM=xterm-256color", $state.launchEnvironmentText)
            popoverField("Working Directory", "ShellBroker default", $state.launchWorkingDirectoryPath)
            HStack(spacing: Lumen.Space.s5) {
                Text("Terminal Size")
                    .frame(width: AppShellChrome.configurationLabelWidth, alignment: .trailing)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                terminalDimensionsRow
            }
        }
        .padding(Lumen.Space.s6)
        .frame(width: AppShellChrome.launchSettingsPopoverWidth)
    }

    private func popoverField(
        _ title: String,
        _ placeholder: String,
        _ text: Binding<String>
    ) -> some View {
        HStack(spacing: Lumen.Space.s5) {
            Text(title)
                .frame(width: AppShellChrome.configurationLabelWidth, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(minWidth: AppShellChrome.launchSettingsPopoverFieldMinWidth)
                .disabled(!presentation.canLaunch)
        }
    }

    private var transcriptNavigationMenu: some View {
        Menu("Navigation") {
            Button(state.isAutoPollingEnabled ? "Turn Auto Polling Off" : "Turn Auto Polling On") {
                state.isAutoPollingEnabled.toggle()
            }
            .disabled(presentation.autoPollSessionID == nil || !transcriptPollingOwner.permitsManualReduction)
            Button(state.shouldFollowLatestTranscript ? "Stop Following Latest" : "Follow Latest") {
                toggleFollowLatestTranscript()
            }
            .disabled(presentation.transcriptTurns.isEmpty)
            Button("Jump to Latest") { jumpToLatestTranscript() }
                .disabled(presentation.transcriptTurns.isEmpty)
            Divider()
            Button("Previous Input") { showPreviousInput() }
                .disabled(!presentation.canSendInput || !state.inputHistory.canNavigatePrevious)
            Button("Next Input") { showNextInput() }
                .disabled(!presentation.canSendInput || !state.inputHistory.canNavigateNext)
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var transcriptScrollback: some View {
        ScrollViewReader { proxy in
            let wiring = rendererWiring
            let callbackFence = Phase2ShellAffordanceTerminalCallbackFence(
                presentationID: state.terminalPresentationID,
                wiring: wiring
            )

            Group {
                if state.rendererState.presentsTerminal {
                    Phase2TerminalEmulatorView(
                        turns: presentation.transcriptTurns,
                        fallbackText: presentation.transcriptPreview,
                        terminalSize: presentation.currentTerminalSize,
                        terminalSessionID: wiring.terminalSessionID,
                        terminalRequestID: wiring.terminalRequestID,
                        terminalRendererGeneration: wiring.terminalRendererGeneration,
                        terminalLifecycleState: wiring.terminalLifecycleState,
                        transcriptEvents: presentation.terminalTranscriptEvents,
                        isInputEnabled: presentation.canSendInput,
                        inputHandler: { bytes in
                            sendTerminalInput(bytes, fence: callbackFence)
                        },
                        resizeHandler: { size in
                            resizeTerminal(to: size, fence: callbackFence)
                        },
                        rendererSelection: wiring.rendererSelection,
                        fullSurfaceRendererFactory: fullSurfaceRendererFactory,
                        rendererLifecycle: state.terminalRendererLifecycle
                    )
                } else {
                    Color(nsColor: .textBackgroundColor)
                        .accessibilityHidden(true)
                }
            }
            .frame(
                minWidth: AppShellChrome.transcriptPreviewMinWidth,
                minHeight: AppShellChrome.transcriptScrollbackMinHeight,
                idealHeight: AppShellChrome.transcriptScrollbackIdealHeight,
                alignment: .leading
            )
            .compactControlBackground()
            .onChange(of: presentation.transcriptTurns.last?.id) { _, id in
                guard state.shouldFollowLatestTranscript, let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: state.transcriptScrollRequest) { _, request in
                guard let request else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(request.turnID, anchor: .bottom)
                }
            }
        }
    }

    private var canUseTerminalSizeDraft: Bool {
        terminalSizeDraft.terminalSizeValidationMessage == nil
    }

    private var canUseLaunchDraft: Bool {
        launchDraft.launchConfigurationValidationMessage == nil
            && terminalSizeDraft.terminalSizeValidationMessage == nil
    }

    private var launchSummaryClipboardText: String? {
        guard terminalSizeDraft.terminalSizeValidationMessage == nil,
              let terminalSize = terminalSizeDraft.normalizedTerminalSize
        else { return nil }
        return launchDraft.launchSummaryClipboardText(terminalSize: terminalSize)
    }

    private func transcriptTurnView(_ turn: Phase2ShellTranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                Text("$")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(Color.lumen(.accent))
                    .frame(width: AppShellChrome.transcriptLinePrefixWidth, alignment: .trailing)

                Text(turn.commandText)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(turn.responseLines) { line in
                transcriptLineView(line)
            }
        }
        .padding(.vertical, Lumen.Space.s2)
    }

    private func transcriptLineView(_ line: Phase2ShellTranscriptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
            Text(line.source)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(foreground(for: line.tone))
                .frame(width: AppShellChrome.transcriptLinePrefixWidth, alignment: .trailing)

            Text(line.text)
                .font(.caption.monospaced())
                .foregroundStyle(foreground(for: line.tone))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func foreground(for tone: Phase2ShellTranscriptLine.Tone) -> Color {
        switch tone {
        case .human:
            return Color.lumen(.accent)
        case .standardOutput:
            return .primary
        case .standardError, .warning:
            return Color.lumen(.statusWarning)
        case .control:
            return .secondary
        }
    }

    private func copyLastTurn() {
        guard let text = presentation.lastTurnClipboardText else { return }
        copyToPasteboard(text)
    }

    private func copyVisibleTranscript() {
        guard let text = presentation.visibleTranscriptClipboardText else { return }
        copyToPasteboard(text)
    }

    private func copyFullTranscript() {
        guard let text = presentation.fullTranscriptClipboardText else { return }
        copyToPasteboard(text)
    }

    private func saveFullTranscript() {
        guard let text = presentation.fullTranscriptClipboardText else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(presentation.fullTranscriptExportFilename ?? "MacScope-Shell-Transcript").txt"
        panel.message = "Save the complete retained shell transcript. Search filters and visible transcript clearing do not affect this export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.saveError = "Could not save shell transcript to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func copyLaunchSummary() {
        guard let text = launchSummaryClipboardText else { return }
        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func clearVisibleTranscript() {
        guard let sequence = presentation.latestVisibleTranscriptSequence else { return }
        state.visibleTranscriptCutoffSequence = sequence
        state.shouldFollowLatestTranscript = true
    }

    private func launchShell() {
        guard let executablePath = launchDraft.normalizedExecutablePath,
              let arguments = launchDraft.normalizedArguments,
              let environment = launchDraft.normalizedEnvironment
        else { return }
        state.visibleTranscriptCutoffSequence = nil
        state.transcriptSearchText = ""
        state.isAutoPollingEnabled = true
        state.shouldFollowLatestTranscript = true
        state.launchExecutablePath = executablePath
        if let normalizedWorkingDirectoryPath = launchDraft.normalizedWorkingDirectoryPath {
            state.launchWorkingDirectoryPath = normalizedWorkingDirectoryPath
        }
        let plan = store.makePhase2ShellLaunchPlan(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectoryPath: launchDraft.normalizedWorkingDirectoryPath,
            initialSize: terminalSizeDraft.normalizedTerminalSize ?? .defaultInteractive
        )
        Task { await store.launchPhase2ShellSession(plan: plan) }
    }

    private func relaunchShell() {
        state.visibleTranscriptCutoffSequence = nil
        state.transcriptSearchText = ""
        state.isAutoPollingEnabled = true
        state.shouldFollowLatestTranscript = true
        Task { await store.relaunchPhase2ShellSession() }
    }

    private func forgetRestoredShellContext() {
        state.visibleTranscriptCutoffSequence = nil
        state.transcriptSearchText = ""
        state.transcriptScrollRequest = nil
        state.lastAppliedRestoredLaunchSessionID = nil
        state.isAutoPollingEnabled = false
        store.forgetRestoredPhase2ShellSessionContext()
    }

    private func applyRestoredLaunchDraftIfNeeded() {
        let presentation = presentation
        guard let restoredLaunchSessionID = presentation.restoredLaunchSessionID,
              state.lastAppliedRestoredLaunchSessionID != restoredLaunchSessionID,
              let restoredLaunchDraft = presentation.restoredLaunchDraft,
              let restoredTerminalSizeDraft = presentation.restoredTerminalSizeDraft
        else { return }

        state.lastAppliedRestoredLaunchSessionID = restoredLaunchSessionID
        state.launchExecutablePath = restoredLaunchDraft.executablePathText
        state.launchArgumentsText = restoredLaunchDraft.argumentsText
        state.launchEnvironmentText = restoredLaunchDraft.environmentText
        state.launchWorkingDirectoryPath = restoredLaunchDraft.workingDirectoryPathText
        state.terminalColumnsText = restoredTerminalSizeDraft.columnsText
        state.terminalRowsText = restoredTerminalSizeDraft.rowsText
    }

    private func toggleFollowLatestTranscript() {
        state.shouldFollowLatestTranscript.toggle()
        if state.shouldFollowLatestTranscript {
            jumpToLatestTranscript()
        }
    }

    private func jumpToLatestTranscript() {
        guard let turnID = presentation.transcriptTurns.last?.id else { return }
        state.transcriptScrollRequestSerial &+= 1
        state.transcriptScrollRequest = Phase2ShellTranscriptScrollRequest(
            turnID: turnID,
            serial: state.transcriptScrollRequestSerial
        )
    }

    private func sendInput() {
        guard presentation.canSendInput, !state.pendingInput.isEmpty, !sendingInput else { return }
        let command = state.pendingInput
        let bytes = Array((command + "\n").utf8)
        let sessionID = store.phase2ShellSession.snapshot?.sessionID
        let sessionState = store.phase2ShellSession.snapshot?.state
        sendingInput = true
        Task {
            defer { sendingInput = false }
            guard store.phase2ShellSession.snapshot?.sessionID == sessionID,
                  store.phase2ShellSession.snapshot?.state == sessionState
            else { return }
            guard await store.writePhase2ShellInput(bytes),
                  store.phase2ShellSession.snapshot?.sessionID == sessionID,
                  store.phase2ShellSession.snapshot?.state == sessionState
            else { return }
            state.inputHistory.commit(command)
            if state.pendingInput == command { state.pendingInput = "" }
        }
    }

    private func sendTerminalInput(
        _ bytes: [UInt8],
        fence: Phase2ShellAffordanceTerminalCallbackFence
    ) {
        guard !bytes.isEmpty else { return }
        Task {
            guard terminalCallbackIsCurrent(fence), presentation.canSendInput else { return }
            switch fence.wiring.terminalCallbackAuthority {
            case .unavailable:
                return
            case let .legacy(sessionID, requestID):
                guard rendererWiring.terminalSessionID == sessionID,
                      rendererWiring.terminalRequestID == requestID
                else { return }
                await store.writePhase2ShellInput(bytes)
            case let .surface(coordinate):
                // The full surface routes through its own exact dispatcher. This closure exists
                // for the real VT-grid fallback that can be shown while a native coordinate is
                // still bound during replay bootstrap.
                guard fence.wiring.renderingResolution?.path != .ghosttyFullSurface else { return }
                _ = await store.writePhase2ShellInput(bytes, from: coordinate)
            }
        }
    }

    private func resizeTerminal(
        to size: Phase2HumanPTYTerminalSize,
        fence: Phase2ShellAffordanceTerminalCallbackFence
    ) {
        guard presentation.canResize,
              size != presentation.currentTerminalSize
        else { return }
        Task {
            guard terminalCallbackIsCurrent(fence),
                  presentation.canResize,
                  size != presentation.currentTerminalSize
            else { return }
            switch fence.wiring.terminalCallbackAuthority {
            case .unavailable:
                return
            case let .legacy(sessionID, requestID):
                guard rendererWiring.terminalSessionID == sessionID,
                      rendererWiring.terminalRequestID == requestID
                else { return }
                await store.resizePhase2ShellSession(to: size)
            case .surface:
                guard fence.wiring.renderingResolution?.path != .ghosttyFullSurface else { return }
                await store.resizePhase2ShellSession(to: size)
            }
        }
    }

    private func terminalCallbackIsCurrent(
        _ fence: Phase2ShellAffordanceTerminalCallbackFence
    ) -> Bool {
        state.isAffordanceVisible
            && state.rendererState.presentsTerminal
            && fence.permits(
                currentPresentationID: state.terminalPresentationID,
                currentWiring: rendererWiring
            )
    }

    private func reconcileGhosttySurfaceBinding(
        rendererSelection: Phase2TerminalRendererSelection?
    ) {
        let target: (sessionID: UUID?, requestID: UUID?)
        if state.isAffordanceVisible,
           rendererSelection?.backend == .ghosttyFullSurface,
           presentation.terminalLifecycleState?.isGhosttySurfacePresentable == true {
            target = (presentation.terminalSessionID, presentation.terminalRequestID)
        } else {
            target = (nil, nil)
        }

        let transition = reconcileGhosttySurfaceBindingState(
            sessionID: target.sessionID,
            requestID: target.requestID
        )
        switch transition {
        case .unchanged:
            return
        case let .retire(coordinate):
            rotateTerminalPresentationID()
            store.retirePhase2ShellSurface(coordinate)
        case let .replace(retiring, candidate):
            rotateTerminalPresentationID()
            if let retiring {
                store.retirePhase2ShellSurface(retiring)
            }
            guard store.bindPhase2ShellSurface(generation: candidate.generation) == candidate else {
                state.ghosttySurfaceBinding.reject(candidate)
                return
            }
        case let .exhausted(retiring):
            rotateTerminalPresentationID()
            if let retiring {
                store.retirePhase2ShellSurface(retiring)
            }
        }
    }

    private func reconcileGhosttySurfaceBindingState(
        sessionID: UUID?,
        requestID: UUID?
    ) -> Phase2GhosttySurfaceBindingTransition {
        if let active = state.ghosttySurfaceBinding.activeCoordinate,
           active.sessionID == sessionID,
           active.requestID == requestID,
           store.phase2ShellSession.surfaceMediation?.coordinate != active {
            state.ghosttySurfaceBinding.reject(active)
        }
        let initial = state.ghosttySurfaceBinding.reconcile(
            sessionID: sessionID,
            requestID: requestID
        )
        guard case let .replace(retiring, firstCandidate) = initial,
              let sessionID,
              let requestID,
              let highWater = store.phase2ShellSession.surfaceGenerationHighWater,
              highWater.sessionID == sessionID,
              highWater.requestID == requestID,
              firstCandidate.generation <= highWater.generation
        else { return initial }

        var candidate = firstCandidate
        while candidate.generation <= highWater.generation {
            state.ghosttySurfaceBinding.reject(candidate)
            switch state.ghosttySurfaceBinding.reconcile(
                sessionID: sessionID,
                requestID: requestID
            ) {
            case let .replace(_, replacement):
                candidate = replacement
            case .exhausted:
                return .exhausted(retiring: retiring)
            case .unchanged, .retire:
                return .exhausted(retiring: retiring)
            }
        }
        return .replace(retiring: retiring, candidate: candidate)
    }

    private func retireGhosttySurfaceBinding(
        expected coordinate: Phase2ShellSurfaceCommandCoordinate
    ) {
        guard state.ghosttySurfaceBinding.activeCoordinate == coordinate,
              state.ghosttySurfaceBinding.retire() == coordinate
        else { return }
        store.retirePhase2ShellSurface(coordinate)
    }

    private func handleAffordanceAppearance() {
        guard !state.isAffordanceVisible else { return }
        state.isAffordanceVisible = true
        rotateTerminalPresentationID()
        applyRestoredLaunchDraftIfNeeded()
        let runtimeState = ghosttyRuntime.prepare()
        let selection = Phase2TerminalRendererSelection.resolve(
            feature: ghosttyRuntime.feature,
            runtimeState: runtimeState
        )
        _ = state.rendererState.activate(selection)
        reconcileGhosttySurfaceBinding(rendererSelection: selection)
    }

    private func handleAffordanceDisappearance() {
        state.retirePresentation(in: store)
    }

    private func applyRendererSelection(
        _ selection: Phase2TerminalRendererSelection
    ) {
        let retiringCoordinate = activeGhosttySurfaceCoordinate
        let transition = state.rendererState.update(
            to: selection,
            retiringCoordinate: retiringCoordinate
        )
        switch transition {
        case .unchanged:
            reconcileGhosttySurfaceBinding(rendererSelection: terminalRendererSelection)
        case let .present(replacement):
            rotateTerminalPresentationID()
            reconcileGhosttySurfaceBinding(rendererSelection: replacement)
        case let .retireSurface(coordinate, _):
            // The renderer state is now a non-presenting barrier. Retire store mediation before
            // the next SwiftUI pass removes the evidenced native subtree. The replacement is
            // enabled only by the follow-up task created from that barrier pass.
            rotateTerminalPresentationID()
            retireGhosttySurfaceBinding(expected: coordinate)
        }
    }

    private func completeRendererRetirement(
        transitionID: UUID?
    ) async {
        guard let transitionID else { return }
        await Task.yield()
        guard !Task.isCancelled, state.isAffordanceVisible,
              let replacement = state.rendererState.completeRetirement(
                  transitionID: transitionID
              )
        else { return }
        rotateTerminalPresentationID()
        reconcileGhosttySurfaceBinding(rendererSelection: replacement)
    }

    private func rotateTerminalPresentationID() {
        state.terminalPresentationID = UUID()
    }

    private func showPreviousInput() {
        guard let input = state.inputHistory.previous(currentDraft: state.pendingInput) else { return }
        state.isApplyingHistoryNavigation = true
        state.pendingInput = input
    }

    private func showNextInput() {
        guard let input = state.inputHistory.next() else { return }
        state.isApplyingHistoryNavigation = true
        state.pendingInput = input
    }

    private func pollShell() {
        guard transcriptPollingOwner.permitsManualReduction else { return }
        Task { await store.pollPhase2ShellTranscript() }
    }

    private func resizeShell() {
        guard let size = terminalSizeDraft.normalizedTerminalSize else { return }
        Task { await store.resizePhase2ShellSession(to: size) }
    }

    private func interruptShell() {
        Task { await store.signalPhase2ShellSession(.interrupt) }
    }

    private func reconnectShell() {
        Task { await store.reconnectPhase2ShellSession() }
    }

    private func stopShell() {
        Task { await store.cleanupPhase2ShellSession(reason: "userStop") }
    }

    private func runAutoPollLoop(sessionID: UUID?) async {
        guard state.isAutoPollingEnabled,
              transcriptPollingOwner.permitsManualReduction,
              let sessionID
        else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: AppShellChrome.autoPollIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            guard state.isAutoPollingEnabled, transcriptPollingOwner.permitsManualReduction else {
                return
            }
            let currentPresentation = Phase2ShellAffordancePresentation.project(
                store.phase2ShellSession,
                visibleAfterSequence: state.visibleTranscriptCutoffSequence,
                transcriptSearchQuery: state.transcriptSearchText
            )
            guard currentPresentation.autoPollSessionID == sessionID else { return }
            guard currentPresentation.canPoll else { continue }
            await store.pollPhase2ShellTranscript(
                maximumEvents: AppShellChrome.autoPollMaximumEvents,
                maximumBytes: AppShellChrome.autoPollMaximumBytes,
                timeoutMilliseconds: AppShellChrome.autoPollTimeoutMilliseconds
            )
        }
    }
}

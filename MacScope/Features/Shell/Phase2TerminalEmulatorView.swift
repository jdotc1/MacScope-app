import Foundation
import SwiftUI
import LumenUI

/// Ephemeral presentation choice. This is never encoded into a workspace.
enum Phase2TerminalRendererBackend: Equatable, Sendable {
    case ghosttyFullSurface
    case macScopeGhosttyVTGrid
}

struct Phase2TerminalRendererSelection: Equatable, Sendable {
    enum Fallback: Equatable, Sendable {
        case compileTimeUnavailable
        case recoveryOverride
        case runtimeUnavailable
        case runtimeFailure
    }

    let backend: Phase2TerminalRendererBackend
    let fallback: Fallback?

    static func resolve(
        feature: MacScopeGhosttySurfaceFeature,
        runtimeState: MacScopeGhosttyRuntime.State
    ) -> Self {
        switch feature.startupSelection {
        case .legacyGrid(.compileTimeUnavailable):
            return Self(backend: .macScopeGhosttyVTGrid, fallback: .compileTimeUnavailable)
        case .legacyGrid(.recoveryOverride):
            return Self(backend: .macScopeGhosttyVTGrid, fallback: .recoveryOverride)
        case .legacyGrid:
            return Self(backend: .macScopeGhosttyVTGrid, fallback: .runtimeUnavailable)
        case .fullSurface:
            break
        }

        switch runtimeState {
        case .ready:
            return Self(backend: .ghosttyFullSurface, fallback: nil)
        case .failed:
            return Self(backend: .macScopeGhosttyVTGrid, fallback: .runtimeFailure)
        case .notStarted, .unavailable:
            return Self(backend: .macScopeGhosttyVTGrid, fallback: .runtimeUnavailable)
        }
    }

    @MainActor
    static func production() -> Self {
        let runtime = MacScopeGhosttyRuntime.productionShared
        return resolve(feature: runtime.feature, runtimeState: runtime.prepare())
    }
}

struct Phase2GhosttyRendererCoordinate: Hashable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let generation: UInt64
}

enum Phase2TerminalRendererEvidence {
    typealias Diagnostics = MacScopeGhosttySurfaceDiagnostics

    /// Derives renderer evidence only from the reducer's authoritative running broker state.
    /// The view never accepts a second PID input and never invents a native generation for the
    /// legacy grid.
    static func binding(
        sessionID: UUID?,
        requestID: UUID?,
        rendererGeneration: UInt64?,
        lifecycleState: Phase2HumanPTYSessionState?,
        observedMode: Diagnostics.RendererObservedMode
    ) -> Diagnostics.RendererBinding? {
        guard let sessionID, let requestID, let lifecycleState,
              case let .running(lifecycleRequestID, processIdentifier) = lifecycleState,
              lifecycleRequestID == requestID,
              processIdentifier > 0
        else { return nil }

        let generation: Diagnostics.RendererGenerationBinding
        switch observedMode {
        case .ghosttyFullSurface:
            guard let rendererGeneration, rendererGeneration > 0 else { return nil }
            generation = .exact(rendererGeneration)
        case .macScopeGhosttyVTGrid:
            generation = .notAllocated
        case .transcriptOnlyFallback:
            return nil
        }

        return Diagnostics.RendererBinding(
            sessionID: sessionID,
            requestID: requestID,
            shellBrokerProcessIdentifier: processIdentifier,
            generation: generation
        )
    }

    static func observation(
        binding: Diagnostics.RendererBinding,
        selection: Phase2TerminalRendererSelection?,
        observedMode: Diagnostics.RendererObservedMode,
        fallbackReason: Diagnostics.RendererFallbackReason
    ) -> Diagnostics.RendererObservation {
        Diagnostics.RendererObservation(
            binding: binding,
            requestedMode: requestedMode(for: selection),
            observedMode: observedMode,
            fallbackReason: normalizedFallbackReason(
                selection: selection,
                observedMode: observedMode,
                fallbackReason: fallbackReason
            )
        )
    }

    static func requestedMode(
        for selection: Phase2TerminalRendererSelection?
    ) -> Diagnostics.RendererRequestedMode {
        guard let selection else { return .unselected }
        switch selection.backend {
        case .ghosttyFullSurface: return .ghosttyFullSurface
        case .macScopeGhosttyVTGrid: return .macScopeGhosttyVTGrid
        }
    }

    private static func normalizedFallbackReason(
        selection: Phase2TerminalRendererSelection?,
        observedMode: Diagnostics.RendererObservedMode,
        fallbackReason: Diagnostics.RendererFallbackReason
    ) -> Diagnostics.RendererFallbackReason {
        switch observedMode {
        case .ghosttyFullSurface:
            return .none
        case .macScopeGhosttyVTGrid:
            guard fallbackReason == .none else { return fallbackReason }
            guard let selection else { return .rendererSelectionUnavailable }
            switch selection.fallback {
            case .compileTimeUnavailable: return .compileTimeUnavailable
            case .recoveryOverride: return .recoveryOverride
            case .runtimeUnavailable: return .runtimeUnavailable
            case .runtimeFailure: return .runtimeFailure
            case nil: return .none
            }
        case .transcriptOnlyFallback:
            return fallbackReason == .none ? .transcriptUnavailable : fallbackReason
        }
    }
}

enum Phase2GhosttyTranscriptAdmissionRejection: Equatable, Sendable {
    case wrongCoordinate
    case wrongSession
    case duplicate(sequence: UInt64)
    case outOfOrder(expected: UInt64, actual: UInt64)
    case explicitGap(sequence: UInt64)
    case nonBrokerOutput(sequence: UInt64)
    case sequenceExhausted
}

enum Phase2GhosttyTranscriptAdmission: Equatable, Sendable {
    case acceptedOutput(sequence: UInt64, bytes: [UInt8])
    case observedNonOutput(sequence: UInt64, kind: Phase2HumanPTYEventPayloadKind)
    case rejected(Phase2GhosttyTranscriptAdmissionRejection)
}

enum Phase2GhosttyTranscriptFallback: Equatable, Sendable {
    case emptyReplay
    case rejected(Phase2GhosttyTranscriptAdmissionRejection)
}

struct Phase2GhosttyTranscriptProjection: Equatable, Sendable {
    let coordinate: Phase2GhosttyRendererCoordinate
    let highWaterSequence: UInt64
    let outputEvents: [Phase2HumanPTYTranscriptEvent]

    var outputBytes: [UInt8] {
        outputEvents.reduce(into: []) { bytes, event in
            guard case let .output(_, payload) = event.payload else { return }
            bytes.append(contentsOf: payload)
        }
    }
}

enum Phase2GhosttyTranscriptReplay: Equatable, Sendable {
    case complete(Phase2GhosttyTranscriptProjection)
    case fallback(Phase2GhosttyTranscriptFallback)
}

/// Session-scoped integrity result used by the legacy grid and transcript fallback selector.
/// Unlike a full-surface projection, this result deliberately carries no request or generation.
enum Phase2GhosttyTranscriptSessionReplay: Equatable, Sendable {
    case complete
    case fallback(Phase2GhosttyTranscriptFallback)
}

/// Pure exact-coordinate admission state. It observes every authoritative sequence entry so
/// input/resize/lifecycle audit events cannot manufacture a numeric gap, but projects only broker
/// output bytes to the renderer.
struct Phase2GhosttyTranscriptAdmissionState: Equatable, Sendable {
    let coordinate: Phase2GhosttyRendererCoordinate
    private(set) var highWaterSequence: UInt64
    private(set) var outputEvents: [Phase2HumanPTYTranscriptEvent]
    private(set) var fallback: Phase2GhosttyTranscriptFallback?

    init(
        coordinate: Phase2GhosttyRendererCoordinate,
        highWaterSequence: UInt64 = 0,
        outputEvents: [Phase2HumanPTYTranscriptEvent] = []
    ) {
        self.coordinate = coordinate
        self.highWaterSequence = highWaterSequence
        self.outputEvents = outputEvents
    }

    mutating func admit(
        _ event: Phase2HumanPTYTranscriptEvent,
        coordinate candidate: Phase2GhosttyRendererCoordinate
    ) -> Phase2GhosttyTranscriptAdmission {
        if let fallback {
            return .rejected(rejection(from: fallback))
        }
        guard candidate == coordinate else { return .rejected(.wrongCoordinate) }
        guard event.sessionID == coordinate.sessionID else { return .rejected(.wrongSession) }
        guard event.sequence > highWaterSequence else {
            return .rejected(.duplicate(sequence: event.sequence))
        }
        let increment = highWaterSequence.addingReportingOverflow(1)
        guard !increment.overflow else { return rejectAndFallback(.sequenceExhausted) }
        guard event.sequence == increment.partialValue else {
            return rejectAndFallback(.outOfOrder(
                expected: increment.partialValue,
                actual: event.sequence
            ))
        }
        if case .gap = event.payload {
            return rejectAndFallback(.explicitGap(sequence: event.sequence))
        }

        switch event.payload {
        case let .output(_, bytes):
            guard event.source == .broker else {
                return rejectAndFallback(.nonBrokerOutput(sequence: event.sequence))
            }
            highWaterSequence = event.sequence
            outputEvents.append(event)
            return .acceptedOutput(sequence: event.sequence, bytes: bytes)
        default:
            highWaterSequence = event.sequence
            return .observedNonOutput(sequence: event.sequence, kind: event.payload.kind)
        }
    }

    var projection: Phase2GhosttyTranscriptProjection? {
        guard fallback == nil else { return nil }
        return Phase2GhosttyTranscriptProjection(
            coordinate: coordinate,
            highWaterSequence: highWaterSequence,
            outputEvents: outputEvents
        )
    }

    static func replay(
        coordinate: Phase2GhosttyRendererCoordinate,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> Phase2GhosttyTranscriptReplay {
        switch validatedReplay(sessionID: coordinate.sessionID, events: events) {
        case let .complete(highWaterSequence, outputEvents):
            return .complete(Phase2GhosttyTranscriptProjection(
                coordinate: coordinate,
                highWaterSequence: highWaterSequence,
                outputEvents: outputEvents
            ))
        case let .fallback(fallback):
            return .fallback(fallback)
        }
    }

    static func replay(
        sessionID: UUID,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> Phase2GhosttyTranscriptSessionReplay {
        switch validatedReplay(sessionID: sessionID, events: events) {
        case .complete:
            return .complete
        case let .fallback(fallback):
            return .fallback(fallback)
        }
    }

    private enum ValidatedReplay {
        case complete(
            highWaterSequence: UInt64,
            outputEvents: [Phase2HumanPTYTranscriptEvent]
        )
        case fallback(Phase2GhosttyTranscriptFallback)
    }

    private static func validatedReplay(
        sessionID: UUID,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> ValidatedReplay {
        guard !events.isEmpty else { return .fallback(.emptyReplay) }
        var highWaterSequence: UInt64 = 0
        var outputEvents: [Phase2HumanPTYTranscriptEvent] = []

        for event in events {
            guard event.sessionID == sessionID else {
                return .fallback(.rejected(.wrongSession))
            }
            guard event.sequence > highWaterSequence else {
                return .fallback(.rejected(.duplicate(sequence: event.sequence)))
            }
            let increment = highWaterSequence.addingReportingOverflow(1)
            guard !increment.overflow else {
                return .fallback(.rejected(.sequenceExhausted))
            }
            guard event.sequence == increment.partialValue else {
                return .fallback(.rejected(.outOfOrder(
                    expected: increment.partialValue,
                    actual: event.sequence
                )))
            }
            if case .gap = event.payload {
                return .fallback(.rejected(.explicitGap(sequence: event.sequence)))
            }
            if case .output = event.payload {
                guard event.source == .broker else {
                    return .fallback(.rejected(.nonBrokerOutput(sequence: event.sequence)))
                }
                outputEvents.append(event)
            }
            highWaterSequence = event.sequence
        }

        return .complete(
            highWaterSequence: highWaterSequence,
            outputEvents: outputEvents
        )
    }

    private mutating func rejectAndFallback(
        _ rejection: Phase2GhosttyTranscriptAdmissionRejection
    ) -> Phase2GhosttyTranscriptAdmission {
        fallback = .rejected(rejection)
        return .rejected(rejection)
    }

    private func rejection(
        from fallback: Phase2GhosttyTranscriptFallback
    ) -> Phase2GhosttyTranscriptAdmissionRejection {
        switch fallback {
        case let .rejected(reason): reason
        case .emptyReplay: .outOfOrder(expected: 1, actual: 0)
        }
    }
}

struct Phase2GhosttyFullSurfaceRenderContext {
    let transcript: Phase2GhosttyTranscriptProjection
    let lifecycleState: Phase2HumanPTYSessionState?
    let isInputEnabled: Bool
    let inputHandler: ([UInt8]) -> Void
    let resizeHandler: (Phase2HumanPTYTerminalSize) -> Void
}

private struct Phase2GhosttyFullSurfaceInstantiationAttempt {
    let view: AnyView?
    let fallbackReason: MacScopeGhosttySurfaceDiagnostics.RendererFallbackReason
}

struct Phase2TerminalEmulatorView: View {
    typealias FullSurfaceRendererFactory = @MainActor (
        Phase2GhosttyFullSurfaceRenderContext
    ) -> AnyView?

    let turns: [Phase2ShellTranscriptTurn]
    let fallbackText: String
    let terminalSize: Phase2HumanPTYTerminalSize
    let terminalSessionID: UUID?
    let terminalRequestID: UUID?
    let terminalRendererGeneration: UInt64?
    let terminalLifecycleState: Phase2HumanPTYSessionState?
    let transcriptEvents: [Phase2HumanPTYTranscriptEvent]
    let isInputEnabled: Bool
    let inputHandler: ([UInt8]) -> Void
    let resizeHandler: (Phase2HumanPTYTerminalSize) -> Void
    let rendererSelection: Phase2TerminalRendererSelection?
    let fullSurfaceRendererFactory: FullSurfaceRendererFactory?
    let rendererLifecycle: MacScopeGhosttySurfaceDiagnostics.RendererLifecycleCoordinator

    init(
        turns: [Phase2ShellTranscriptTurn],
        fallbackText: String,
        terminalSize: Phase2HumanPTYTerminalSize,
        terminalSessionID: UUID?,
        terminalRequestID: UUID? = nil,
        terminalRendererGeneration: UInt64? = nil,
        terminalLifecycleState: Phase2HumanPTYSessionState? = nil,
        transcriptEvents: [Phase2HumanPTYTranscriptEvent],
        isInputEnabled: Bool,
        inputHandler: @escaping ([UInt8]) -> Void,
        resizeHandler: @escaping (Phase2HumanPTYTerminalSize) -> Void,
        rendererSelection: Phase2TerminalRendererSelection? = nil,
        fullSurfaceRendererFactory: FullSurfaceRendererFactory? = nil,
        rendererLifecycle: MacScopeGhosttySurfaceDiagnostics.RendererLifecycleCoordinator
    ) {
        self.turns = turns
        self.fallbackText = fallbackText
        self.terminalSize = terminalSize
        self.terminalSessionID = terminalSessionID
        self.terminalRequestID = terminalRequestID
        self.terminalRendererGeneration = terminalRendererGeneration
        self.terminalLifecycleState = terminalLifecycleState
        self.transcriptEvents = transcriptEvents
        self.isInputEnabled = isInputEnabled
        self.inputHandler = inputHandler
        self.resizeHandler = resizeHandler
        self.rendererSelection = rendererSelection
        self.fullSurfaceRendererFactory = fullSurfaceRendererFactory
        self.rendererLifecycle = rendererLifecycle
    }

    private var terminalBytes: [UInt8] {
        guard !turns.isEmpty else { return Array(fallbackText.utf8) }
        var bytes: [UInt8] = []
        for (index, turn) in turns.enumerated() {
            if index > 0 { bytes.append(contentsOf: "\n".utf8) }
            bytes.append(contentsOf: "$ \(turn.commandText)\n".utf8)
            for line in turn.responseLines {
                if let rawBytes = line.rawBytes {
                    bytes.append(contentsOf: rawBytes)
                    if rawBytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
                } else {
                    bytes.append(contentsOf: "\(line.text)\n".utf8)
                }
            }
        }
        return bytes
    }

    private var terminalText: String {
        guard !turns.isEmpty else { return fallbackText }
        return turns.map { turn in
            (["$ \(turn.commandText)"] + turn.responseLines.map(\.text)).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private var renderedTerminalText: String {
        Phase2GhosttyVTTranscriptRenderer.renderPlainText(
            bytes: terminalBytes,
            columns: terminalSize.columns,
            rows: terminalSize.rows
        ) ?? terminalText
    }

    @MainActor
    private func fullSurfaceInstantiationAttempt(
        for selection: Phase2TerminalRendererSelection?
    ) -> Phase2GhosttyFullSurfaceInstantiationAttempt {
        guard let selection else {
            return .init(view: nil, fallbackReason: .rendererSelectionUnavailable)
        }
        guard selection.backend == .ghosttyFullSurface else {
            return .init(view: nil, fallbackReason: .none)
        }
        guard let sessionID = terminalSessionID,
              let requestID = terminalRequestID,
              let generation = terminalRendererGeneration,
              generation > 0
        else {
            return .init(view: nil, fallbackReason: .rendererCoordinateUnavailable)
        }
        guard let fullSurfaceRendererFactory else {
            return .init(view: nil, fallbackReason: .fullSurfaceFactoryUnavailable)
        }
        let coordinate = Phase2GhosttyRendererCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: generation
        )
        guard let callbackBinding = rendererEvidenceBinding(for: .ghosttyFullSurface) else {
            return .init(view: nil, fallbackReason: .rendererCoordinateUnavailable)
        }
        let transcript: Phase2GhosttyTranscriptProjection
        switch Phase2GhosttyTranscriptAdmissionState.replay(
            coordinate: coordinate,
            events: transcriptEvents
        ) {
        case let .complete(projection):
            transcript = projection
        case .fallback(.emptyReplay):
            return .init(view: nil, fallbackReason: .transcriptUnavailable)
        case .fallback(.rejected):
            return .init(view: nil, fallbackReason: .transcriptRejected)
        }
        let effectiveInputEnabled = isInputEnabled && terminalLifecycleState?.isTerminal != true
        guard let view = fullSurfaceRendererFactory(Phase2GhosttyFullSurfaceRenderContext(
            transcript: transcript,
            lifecycleState: terminalLifecycleState,
            isInputEnabled: effectiveInputEnabled,
            inputHandler: { bytes in
                guard effectiveInputEnabled else { return }
                rendererLifecycle.withAuthorizedCallback(for: callbackBinding) {
                    inputHandler(bytes)
                }
            },
            resizeHandler: { size in
                rendererLifecycle.withAuthorizedCallback(for: callbackBinding) {
                    resizeHandler(size)
                }
            }
        )) else {
            return .init(view: nil, fallbackReason: .fullSurfaceFactoryRejected)
        }
        return .init(view: view, fallbackReason: .none)
    }

    private func rendererEvidenceBinding(
        for observedMode: MacScopeGhosttySurfaceDiagnostics.RendererObservedMode
    ) -> MacScopeGhosttySurfaceDiagnostics.RendererBinding? {
        Phase2TerminalRendererEvidence.binding(
            sessionID: terminalSessionID,
            requestID: terminalRequestID,
            rendererGeneration: terminalRendererGeneration,
            lifecycleState: terminalLifecycleState,
            observedMode: observedMode
        )
    }

    @MainActor
    private func evidencedView(
        _ view: AnyView,
        observedMode: MacScopeGhosttySurfaceDiagnostics.RendererObservedMode,
        fallbackReason: MacScopeGhosttySurfaceDiagnostics.RendererFallbackReason
    ) -> AnyView {
        let observation = rendererEvidenceBinding(for: observedMode).map { binding in
            Phase2TerminalRendererEvidence.observation(
                binding: binding,
                selection: rendererSelection,
                observedMode: observedMode,
                fallbackReason: fallbackReason
            )
        }
        let binding = observation?.binding
        return AnyView(
            view
                .id(binding)
                .onAppear {
                    rendererLifecycle.rendererDidAppear(observation)
                }
                .onDisappear {
                    rendererLifecycle.rendererDidDisappear(binding: binding)
                }
        )
    }

    var body: some View {
        Group {
            let fullSurfaceAttempt = fullSurfaceInstantiationAttempt(for: rendererSelection)
            let resolution = Phase2TerminalSurfacePresentation.renderingResolution(
                rendererSelection: rendererSelection,
                fullSurfaceAvailable: fullSurfaceAttempt.view != nil,
                fullSurfaceFallbackReason: fullSurfaceAttempt.fallbackReason,
                sessionID: terminalSessionID,
                events: transcriptEvents
            )
            switch resolution.path {
            case .ghosttyFullSurface:
                if let fullSurface = fullSurfaceAttempt.view {
                    evidencedView(
                        fullSurface,
                        observedMode: .ghosttyFullSurface,
                        fallbackReason: .none
                    )
                }
            case let .ghostty(terminalSessionID):
#if canImport(GhosttyVt)
                let callbackBinding = rendererEvidenceBinding(for: .macScopeGhosttyVTGrid)
                evidencedView(
                    AnyView(
                        Phase2GhosttyTerminalSurface(
                            sessionID: terminalSessionID,
                            terminalSize: terminalSize,
                            transcriptEvents: transcriptEvents,
                            inputHandler: { bytes in
                                guard isInputEnabled else { return }
                                rendererLifecycle.withAuthorizedCallback(for: callbackBinding) {
                                    inputHandler(bytes)
                                }
                            },
                            resizeHandler: { size in
                                rendererLifecycle.withAuthorizedCallback(for: callbackBinding) {
                                    resizeHandler(size)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                    ),
                    observedMode: .macScopeGhosttyVTGrid,
                    fallbackReason: fullSurfaceAttempt.fallbackReason
                )
#else
                evidencedView(
                    AnyView(TranscriptFallbackTerminalView(text: renderedTerminalText)),
                    observedMode: .transcriptOnlyFallback,
                    fallbackReason: .legacyGridNotCompiled
                )
#endif
            case .transcriptFallback:
                evidencedView(
                    AnyView(TranscriptFallbackTerminalView(text: renderedTerminalText)),
                    observedMode: .transcriptOnlyFallback,
                    fallbackReason: resolution.fallbackReason
                )
            }
        }
    }
}

enum Phase2TerminalSurfacePresentation {
    typealias RendererFallbackReason = MacScopeGhosttySurfaceDiagnostics.RendererFallbackReason

    enum RenderingPath: Equatable {
        case ghosttyFullSurface
        case ghostty(UUID)
        case transcriptFallback
    }

    struct RenderingResolution: Equatable {
        let path: RenderingPath
        let fallbackReason: RendererFallbackReason
    }

    static func renderingResolution(
        rendererSelection: Phase2TerminalRendererSelection?,
        fullSurfaceAvailable: Bool,
        fullSurfaceFallbackReason: RendererFallbackReason,
        sessionID: UUID?,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> RenderingResolution {
        if rendererSelection?.backend == .ghosttyFullSurface, fullSurfaceAvailable {
            return .init(path: .ghosttyFullSurface, fallbackReason: .none)
        }
        let replayResolution = renderingResolution(sessionID: sessionID, events: events)
        guard case .ghostty = replayResolution.path else { return replayResolution }
        return .init(
            path: replayResolution.path,
            fallbackReason: fallbackReason(
                for: rendererSelection,
                fullSurfaceFallbackReason: fullSurfaceFallbackReason
            )
        )
    }

    static func renderingPath(
        rendererSelection: Phase2TerminalRendererSelection?,
        fullSurfaceAvailable: Bool,
        fullSurfaceFallbackReason: RendererFallbackReason = .none,
        sessionID: UUID?,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> RenderingPath {
        renderingResolution(
            rendererSelection: rendererSelection,
            fullSurfaceAvailable: fullSurfaceAvailable,
            fullSurfaceFallbackReason: fullSurfaceFallbackReason,
            sessionID: sessionID,
            events: events
        ).path
    }

    static func renderingPath(
        sessionID: UUID?,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> RenderingPath {
        renderingResolution(sessionID: sessionID, events: events).path
    }

    static func renderingResolution(
        sessionID: UUID?,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> RenderingResolution {
        guard let sessionID else {
            return .init(
                path: .transcriptFallback,
                fallbackReason: .rendererCoordinateUnavailable
            )
        }
        switch Phase2GhosttyTranscriptAdmissionState.replay(
            sessionID: sessionID,
            events: events
        ) {
        case .complete:
            return .init(path: .ghostty(sessionID), fallbackReason: .none)
        case .fallback(.emptyReplay):
            return .init(path: .transcriptFallback, fallbackReason: .transcriptUnavailable)
        case .fallback(.rejected):
            return .init(path: .transcriptFallback, fallbackReason: .transcriptRejected)
        }
    }

    private static func fallbackReason(
        for selection: Phase2TerminalRendererSelection?,
        fullSurfaceFallbackReason: RendererFallbackReason
    ) -> RendererFallbackReason {
        guard let selection else { return .rendererSelectionUnavailable }
        switch selection.backend {
        case .ghosttyFullSurface:
            return fullSurfaceFallbackReason
        case .macScopeGhosttyVTGrid:
            switch selection.fallback {
            case .compileTimeUnavailable: return .compileTimeUnavailable
            case .recoveryOverride: return .recoveryOverride
            case .runtimeUnavailable: return .runtimeUnavailable
            case .runtimeFailure: return .runtimeFailure
            case nil: return .none
            }
        }
    }

    static func canRenderGhosttySurface(
        sessionID: UUID?,
        events: [Phase2HumanPTYTranscriptEvent]
    ) -> Bool {
        if case .ghostty = renderingPath(sessionID: sessionID, events: events) { return true }
        return false
    }
}

private struct TranscriptFallbackTerminalView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Lumen.Space.s4)
                .padding(.vertical, Lumen.Space.s2)
        }
    }
}

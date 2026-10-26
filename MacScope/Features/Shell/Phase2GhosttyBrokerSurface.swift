import Darwin
import Foundation
import SwiftUI

enum Phase2GhosttySurfaceBindingTransition: Equatable, Sendable {
    case unchanged(Phase2ShellSurfaceCommandCoordinate?)
    case replace(
        retiring: Phase2ShellSurfaceCommandCoordinate?,
        candidate: Phase2ShellSurfaceCommandCoordinate
    )
    case retire(Phase2ShellSurfaceCommandCoordinate)
    case exhausted(retiring: Phase2ShellSurfaceCommandCoordinate?)
}

/// Pure, ephemeral generation allocator for one shell presentation.
///
/// A rejected or retired generation is never reused. Session and request identity remain broker
/// authority; this counter exists only to prevent a dismantled renderer from targeting its
/// replacement.
struct Phase2GhosttySurfaceBindingState: Equatable, Sendable {
    private(set) var activeCoordinate: Phase2ShellSurfaceCommandCoordinate?
    private(set) var lastIssuedGeneration: UInt64 = 0

    mutating func reconcile(
        sessionID: UUID?,
        requestID: UUID?
    ) -> Phase2GhosttySurfaceBindingTransition {
        guard let sessionID, let requestID else {
            guard let activeCoordinate else { return .unchanged(nil) }
            self.activeCoordinate = nil
            return .retire(activeCoordinate)
        }

        if let activeCoordinate,
           activeCoordinate.sessionID == sessionID,
           activeCoordinate.requestID == requestID {
            return .unchanged(activeCoordinate)
        }

        let retiring = activeCoordinate
        activeCoordinate = nil
        let next = lastIssuedGeneration.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue > 0 else {
            return .exhausted(retiring: retiring)
        }
        lastIssuedGeneration = next.partialValue
        let candidate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: next.partialValue
        )
        activeCoordinate = candidate
        return .replace(retiring: retiring, candidate: candidate)
    }

    mutating func reject(_ candidate: Phase2ShellSurfaceCommandCoordinate) {
        guard activeCoordinate == candidate else { return }
        activeCoordinate = nil
    }

    mutating func retire() -> Phase2ShellSurfaceCommandCoordinate? {
        defer { activeCoordinate = nil }
        return activeCoordinate
    }
}

extension Phase2ShellSurfaceCommandCoordinate {
    var rendererCoordinate: Phase2GhosttyRendererCoordinate {
        Phase2GhosttyRendererCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: generation
        )
    }

    var ghosttySurfaceGeneration: MacScopeGhosttySurfaceGeneration {
        MacScopeGhosttySurfaceGeneration(
            sessionID: sessionID,
            requestID: requestID,
            generation: generation
        )
    }
}

extension Phase2HumanPTYSessionState {
    var isGhosttySurfacePresentable: Bool {
        switch self {
        case .running, .terminal:
            true
        case .idle, .launchRequested, .prepared, .launchRejected:
            false
        }
    }
}

enum Phase2GhosttyBrokerSurfaceCommand: Equatable, Sendable {
    case write([UInt8])
    case resize(Phase2ShellSurfaceResizeProposal)
    case close(reason: String)

    static func project(
        _ work: MacScopeGhosttyExternalIOBridge.Work,
        expected coordinate: Phase2ShellSurfaceCommandCoordinate
    ) -> Self? {
        let generation: MacScopeGhosttySurfaceGeneration
        switch work {
        case let .write(candidate, _),
             let .resize(candidate, _),
             let .close(candidate, _),
             let .health(candidate, _, _):
            generation = candidate
        }
        guard generation == coordinate.ghosttySurfaceGeneration else { return nil }

        switch work {
        case let .write(_, bytes):
            guard !bytes.isEmpty else { return nil }
            return .write(Array(bytes))
        case let .resize(_, proposal):
            return .resize(Phase2ShellSurfaceResizeProposal(
                terminalSize: Phase2HumanPTYTerminalSize(
                    columns: proposal.columns,
                    rows: proposal.rows
                ),
                pixelSize: Phase2ShellSurfacePixelSize(
                    width: proposal.pixelWidth,
                    height: proposal.pixelHeight
                )
            ))
        case let .close(_, reason):
            return .close(reason: cleanupReason(for: reason))
        case .health:
            return nil
        }
    }

    private static func cleanupReason(
        for reason: MacScopeGhosttyExternalIOBridge.CloseReason
    ) -> String {
        switch reason {
        case .hostExited: "ghosttyHostExited"
        case .hostSignaled: "ghosttyHostSignaled"
        case .hostClosed: "ghosttyHostClosed"
        case .surfaceRequest: "ghosttySurfaceRequest"
        }
    }
}

struct Phase2GhosttyBrokerHealthFailure: Equatable, Sendable {
    let event: MacScopeGhosttyExternalIOBridge.HealthEvent
    let detail: UInt64

    static func project(
        _ work: MacScopeGhosttyExternalIOBridge.Work,
        expected coordinate: Phase2ShellSurfaceCommandCoordinate
    ) -> Self? {
        guard case let .health(generation, event, detail) = work,
              generation == coordinate.ghosttySurfaceGeneration
        else { return nil }

        switch event {
        case .outputOverflow, .outputSuppressed:
            return Self(event: event, detail: detail)
        case .feedReady, .outputBackpressured:
            return nil
        }
    }
}

enum Phase2GhosttyBrokerFeedRejection: Equatable, Sendable {
    case wrongCoordinate
    case highWaterRegression(previous: UInt64, actual: UInt64)
    case outputPrefixChanged(expectedSequence: UInt64, actualSequence: UInt64?)
    case malformedOutput(sequence: UInt64)
    case backendRejected(sequence: UInt64, admission: MacScopeGhosttySurfaceFeedAdmission)
}

enum Phase2GhosttyBrokerFeedDisposition: Equatable, Sendable {
    case accepted(
        eventCount: Int,
        byteCount: Int,
        highWaterSequence: UInt64,
        requiresContinuation: Bool
    )
    case rejected(Phase2GhosttyBrokerFeedRejection)
}

/// One main-actor turn may feed only this much cumulative transcript state. Output from adjacent
/// authoritative events is coalesced into a single backend call, and an oversized event is split
/// across turns without advancing its sequence until every byte has been accepted.
struct Phase2GhosttyBrokerFeedBudget: Equatable, Sendable {
    static let `default` = Self(maximumEvents: 32, maximumBytes: 16_384)

    let maximumEvents: Int
    let maximumBytes: Int

    init(maximumEvents: Int, maximumBytes: Int) {
        self.maximumEvents = min(max(maximumEvents, 1), 64)
        self.maximumBytes = min(max(maximumBytes, 1), 65_536)
    }
}

/// Tracks only output already consumed by the native renderer. Admission of session identity,
/// sequence continuity, audit events, and gaps is complete before this cursor receives a
/// `Phase2GhosttyTranscriptProjection`.
struct Phase2GhosttyBrokerFeedCursor: Equatable, Sendable {
    let coordinate: Phase2GhosttyRendererCoordinate
    private(set) var lastObservedHighWaterSequence: UInt64 = 0
    private(set) var lastFedOutputSequence: UInt64 = 0
    private(set) var nextOutputEventIndex: Int = 0
    private(set) var nextOutputByteOffset: Int = 0
    private var partialOutputSequence: UInt64?

    mutating func feed(
        _ projection: Phase2GhosttyTranscriptProjection,
        budget: Phase2GhosttyBrokerFeedBudget = .default,
        submit: (Data) -> MacScopeGhosttySurfaceFeedAdmission
    ) -> Phase2GhosttyBrokerFeedDisposition {
        guard projection.coordinate == coordinate else { return .rejected(.wrongCoordinate) }
        guard projection.highWaterSequence >= lastObservedHighWaterSequence else {
            return .rejected(.highWaterRegression(
                previous: lastObservedHighWaterSequence,
                actual: projection.highWaterSequence
            ))
        }

        guard nextOutputEventIndex <= projection.outputEvents.count else {
            return .rejected(.outputPrefixChanged(
                expectedSequence: lastFedOutputSequence,
                actualSequence: nil
            ))
        }
        if nextOutputEventIndex > 0 {
            let prefixSequence = projection.outputEvents[nextOutputEventIndex - 1].sequence
            guard prefixSequence == lastFedOutputSequence else {
                return .rejected(.outputPrefixChanged(
                    expectedSequence: lastFedOutputSequence,
                    actualSequence: prefixSequence
                ))
            }
        } else if lastFedOutputSequence != 0 {
            return .rejected(.outputPrefixChanged(
                expectedSequence: lastFedOutputSequence,
                actualSequence: projection.outputEvents.first?.sequence
            ))
        }

        var candidateIndex = nextOutputEventIndex
        var candidateOffset = nextOutputByteOffset
        var candidateLastFedSequence = lastFedOutputSequence
        var touchedEventCount = 0
        var completedEventCount = 0
        var coalescedBytes = Data()
        coalescedBytes.reserveCapacity(budget.maximumBytes)
        var firstSubmittedSequence: UInt64?

        while candidateIndex < projection.outputEvents.count,
              touchedEventCount < budget.maximumEvents,
              coalescedBytes.count < budget.maximumBytes {
            let event = projection.outputEvents[candidateIndex]
            guard event.sessionID == coordinate.sessionID,
                  event.source == .broker,
                  event.sequence > candidateLastFedSequence,
                  event.sequence <= projection.highWaterSequence,
                  case let .output(_, bytes) = event.payload
            else { return .rejected(.malformedOutput(sequence: event.sequence)) }

            if candidateOffset > 0 {
                guard partialOutputSequence == event.sequence,
                      candidateOffset < bytes.count
                else {
                    return .rejected(.outputPrefixChanged(
                        expectedSequence: partialOutputSequence ?? event.sequence,
                        actualSequence: event.sequence
                    ))
                }
            }

            touchedEventCount += 1
            firstSubmittedSequence = firstSubmittedSequence ?? event.sequence
            let availableByteCount = budget.maximumBytes - coalescedBytes.count
            let remainingByteCount = bytes.count - candidateOffset
            let copiedByteCount = min(availableByteCount, remainingByteCount)
            if copiedByteCount > 0 {
                let end = candidateOffset + copiedByteCount
                coalescedBytes.append(contentsOf: bytes[candidateOffset..<end])
                candidateOffset = end
            }

            guard candidateOffset == bytes.count else { break }
            candidateIndex += 1
            candidateOffset = 0
            candidateLastFedSequence = event.sequence
            completedEventCount += 1
        }

        if !coalescedBytes.isEmpty {
            let admission = submit(coalescedBytes)
            guard admission == .accepted else {
                return .rejected(.backendRejected(
                    sequence: firstSubmittedSequence ?? candidateLastFedSequence,
                    admission: admission
                ))
            }
        }

        nextOutputEventIndex = candidateIndex
        nextOutputByteOffset = candidateOffset
        partialOutputSequence = candidateOffset > 0
            ? projection.outputEvents[candidateIndex].sequence
            : nil
        lastFedOutputSequence = candidateLastFedSequence
        lastObservedHighWaterSequence = projection.highWaterSequence
        return .accepted(
            eventCount: completedEventCount,
            byteCount: coalescedBytes.count,
            highWaterSequence: projection.highWaterSequence,
            requiresContinuation: candidateIndex < projection.outputEvents.count
        )
    }
}

enum Phase2GhosttyBrokerProcessStateProjection {
    static func project(
        _ state: Phase2HumanPTYSessionState?
    ) -> MacScopeGhosttySurfaceProcessState? {
        guard let state else { return nil }
        switch state {
        case .running:
            return .running
        case let .terminal(outcome):
            return project(outcome)
        case .launchRejected:
            return .closed
        case .idle, .launchRequested, .prepared:
            return nil
        }
    }

    static func project(
        _ outcome: Phase2HumanPTYTerminalOutcome
    ) -> MacScopeGhosttySurfaceProcessState {
        switch outcome {
        case let .exited(status):
            return .exited(status: status)
        case let .signaled(signal):
            return .signaled(signal: signalNumber(for: signal))
        case .interrupted:
            return .signaled(signal: UInt32(SIGINT))
        case .canceled, .brokerCrashed, .outcomeUnknown:
            return .closed
        }
    }

    private static func signalNumber(for signal: Phase2HumanPTYSignal) -> UInt32 {
        switch signal {
        case .interrupt: UInt32(SIGINT)
        case .terminate: UInt32(SIGTERM)
        case .suspend: UInt32(SIGTSTP)
        case .continueSignal: UInt32(SIGCONT)
        }
    }
}

@MainActor
struct Phase2GhosttyBrokerSurface: View {
    @ObservedObject var store: WorkspaceStore
    let coordinate: Phase2ShellSurfaceCommandCoordinate
    let context: Phase2GhosttyFullSurfaceRenderContext

    @StateObject private var controller: Phase2GhosttyBrokerSurfaceController

    init(
        store: WorkspaceStore,
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        context: Phase2GhosttyFullSurfaceRenderContext
    ) {
        self.store = store
        self.coordinate = coordinate
        self.context = context
        _controller = StateObject(wrappedValue: Phase2GhosttyBrokerSurfaceController(
            store: store,
            coordinate: coordinate
        ))
    }

    var body: some View {
        Group {
            if !controller.requiresFallback {
                MacScopeGhosttySurfaceRepresentable(
                    generation: coordinate.ghosttySurfaceGeneration,
                    backendFactory: { generation in
                        controller.makeBackend(generation: generation)
                    },
                    availabilityChanged: { isAvailable in
                        controller.setAvailable(isAvailable)
                    }
                )
            }
        }
        .onAppear(perform: reconcileController)
        .onChange(of: context.transcript) { _, _ in reconcileController() }
        .onChange(of: context.lifecycleState) { _, _ in reconcileController() }
        .onChange(of: context.isInputEnabled) { _, _ in reconcileController() }
        .onDisappear {
            controller.retire()
        }
    }

    private func reconcileController() {
        controller.reconcile(
            transcript: context.transcript,
            lifecycleState: context.lifecycleState,
            isInputEnabled: context.isInputEnabled
        )
    }
}

private struct Phase2GhosttyBrokerCatchUpLease: Equatable, Sendable {
    let coordinate: Phase2ShellSurfaceCommandCoordinate
    let identifier: UUID
}

@MainActor
private final class Phase2GhosttyBrokerSurfaceController: ObservableObject {
    @Published private(set) var requiresFallback = false

    private let store: WorkspaceStore
    private let coordinate: Phase2ShellSurfaceCommandCoordinate
    private let generation: MacScopeGhosttySurfaceGeneration
    private let continuousPollingController = Phase2ContinuousShellTranscriptController()
    private let continuousPollCommandID = UUID()
    private let feedBudget = Phase2GhosttyBrokerFeedBudget.default
    private var feedCursor: Phase2GhosttyBrokerFeedCursor
    private var backend: (any MacScopeGhosttySurfaceBackend)?
    private var latestTranscript: Phase2GhosttyTranscriptProjection?
    private var latestLifecycleState: Phase2HumanPTYSessionState?
    private var lastReportedProcessState: MacScopeGhosttySurfaceProcessState?
    private var isAvailable = false
    private var didStartContinuousPolling = false
    private var catchUpLease: Phase2GhosttyBrokerCatchUpLease?
    private var catchUpTask: Task<Void, Never>?

    private lazy var commandPump = Phase2GhosttyBrokerCommandPump(
        store: store,
        coordinate: coordinate,
        failureHandler: { [weak self] _ in
            self?.failClosed()
        }
    )

    init(store: WorkspaceStore, coordinate: Phase2ShellSurfaceCommandCoordinate) {
        self.store = store
        self.coordinate = coordinate
        generation = coordinate.ghosttySurfaceGeneration
        feedCursor = Phase2GhosttyBrokerFeedCursor(coordinate: coordinate.rendererCoordinate)
    }

    func makeBackend(
        generation candidate: MacScopeGhosttySurfaceGeneration
    ) -> (any MacScopeGhosttySurfaceBackend)? {
        guard candidate == generation, !requiresFallback else { return nil }
        if let backend { return backend }
        let backend = MacScopeGhosttyLinkedSurfaceFactory.make(
            generation: generation,
            workHandler: { [commandPump] work in
                commandPump.submit(work)
            }
        )
        self.backend = backend
        return backend
    }

    func setAvailable(_ isAvailable: Bool) {
        guard isAvailable else {
            failClosed()
            return
        }
        self.isAvailable = true
        reconcileContinuousPolling()
        drainAuthoritativeState()
    }

    func reconcile(
        transcript: Phase2GhosttyTranscriptProjection,
        lifecycleState: Phase2HumanPTYSessionState?,
        isInputEnabled: Bool
    ) {
        latestTranscript = transcript
        latestLifecycleState = lifecycleState
        commandPump.setInputEnabled(isInputEnabled && lifecycleState?.isTerminal != true)
        if lifecycleState?.isTerminal == true {
            _ = continuousPollingController.stop(coordinate: coordinate)
        } else {
            reconcileContinuousPolling()
        }
        drainAuthoritativeState()
    }

    func retire() {
        isAvailable = false
        cancelCatchUpContinuation()
        commandPump.retire()
        _ = continuousPollingController.stop(coordinate: coordinate)
        backend = nil
    }

    private func drainAuthoritativeState() {
        guard isAvailable, !requiresFallback, let backend, let latestTranscript else { return }
        let disposition = feedCursor.feed(latestTranscript, budget: feedBudget) { [generation] bytes in
            backend.feed(bytes, generation: generation)
        }
        guard case let .accepted(_, _, _, requiresContinuation) = disposition else {
            failClosed()
            return
        }
        if requiresContinuation {
            scheduleCatchUpContinuation()
            return
        }
        cancelCatchUpContinuation()

        guard let processState = Phase2GhosttyBrokerProcessStateProjection.project(
            latestLifecycleState
        ), processState != lastReportedProcessState else { return }
        guard backend.setProcessState(processState, generation: generation) == .accepted else {
            failClosed()
            return
        }
        lastReportedProcessState = processState
    }

    private func failClosed() {
        guard !requiresFallback else { return }
        isAvailable = false
        cancelCatchUpContinuation()
        commandPump.retire()
        _ = continuousPollingController.stop(coordinate: coordinate)
        backend = nil
        requiresFallback = true
        MacScopeGhosttyRuntime.productionShared.recordHealthFailure()
    }

    private func scheduleCatchUpContinuation() {
        guard catchUpTask == nil, isAvailable, !requiresFallback else { return }
        let lease = Phase2GhosttyBrokerCatchUpLease(
            coordinate: coordinate,
            identifier: UUID()
        )
        catchUpLease = lease
        catchUpTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.catchUpLease == lease,
                  self.coordinate == lease.coordinate
            else { return }
            self.catchUpTask = nil
            self.catchUpLease = nil
            self.drainAuthoritativeState()
        }
    }

    private func cancelCatchUpContinuation() {
        catchUpLease = nil
        catchUpTask?.cancel()
        catchUpTask = nil
    }

    private func reconcileContinuousPolling() {
        guard isAvailable,
              !requiresFallback,
              !didStartContinuousPolling,
              case .running = latestLifecycleState
        else { return }

        didStartContinuousPolling = true
        continuousPollingController.start(
            coordinate: coordinate,
            commandID: continuousPollCommandID,
            poll: { [weak store] commandID, coordinate, maximumEvents, maximumBytes, timeout in
                guard let store,
                      store.phase2ShellSession.surfaceMediation?.coordinate == coordinate,
                      store.phase2ShellSession.isRunning
                else { return .retired }
                if store.phase2ShellSession.isCommandInFlight || !store.phase2ShellPendingControls.isEmpty {
                    return .deferred
                }
                guard let outcome = await store.pollPhase2ShellTranscript(
                    maximumEvents: maximumEvents,
                    maximumBytes: maximumBytes,
                    timeoutMilliseconds: timeout,
                    commandID: commandID,
                    surface: coordinate
                ) else {
                    guard store.phase2ShellSession.surfaceMediation?.coordinate == coordinate,
                          store.phase2ShellSession.isRunning
                    else { return .retired }
                    return .failed
                }
                return outcome.acceptedTranscriptEvents.isEmpty ? .acceptedEmpty : .accepted
            },
            healthFailure: { [weak self] candidate in
                guard self?.coordinate == candidate else { return }
                self?.failClosed()
            }
        )
    }
}

enum Phase2GhosttyBrokerCommandRouteDisposition: Equatable, Sendable {
    case accepted
    case deferred
    case retired
    case failed
}

enum Phase2GhosttyBrokerCommandPumpFailure: Equatable, Sendable {
    case bridgeHealth(Phase2GhosttyBrokerHealthFailure)
    case saturated(maximumPendingCommands: Int, maximumPendingWriteBytes: Int)
    case routeRejected(Phase2GhosttyBrokerSurfaceCommand)
}

/// Finite secondary pump between the bridge's callback queue and MainActor store routing.
///
/// The bridge already bounds its own queue, but its synchronous delivery handler can otherwise
/// transfer work into an unbounded async backlog. This pump applies an independent count/byte
/// ceiling, serializes exact-coordinate commands, and invalidates its drain/failure leases on
/// retirement so a replaced generation cannot resume after an awaited store call completes.
final class Phase2GhosttyBrokerCommandPump: @unchecked Sendable {
    typealias Route = @MainActor @Sendable (
        Phase2GhosttyBrokerSurfaceCommand
    ) async -> Phase2GhosttyBrokerCommandRouteDisposition
    typealias FailureHandler = @MainActor @Sendable (
        Phase2GhosttyBrokerCommandPumpFailure
    ) -> Void

    struct Configuration: Equatable, Sendable {
        static let `default` = Self(
            maximumPendingCommands: 64,
            maximumPendingWriteBytes: 4 << 20,
            contentionDelayNanoseconds: 5_000_000
        )

        let maximumPendingCommands: Int
        let maximumPendingWriteBytes: Int
        let contentionDelayNanoseconds: UInt64

        init(
            maximumPendingCommands: Int,
            maximumPendingWriteBytes: Int,
            contentionDelayNanoseconds: UInt64 = 5_000_000
        ) {
            self.maximumPendingCommands = min(max(maximumPendingCommands, 1), 64)
            self.maximumPendingWriteBytes = min(
                max(maximumPendingWriteBytes, 1),
                4 << 20
            )
            self.contentionDelayNanoseconds = min(
                max(contentionDelayNanoseconds, 1_000_000),
                50_000_000
            )
        }
    }

    enum Lifecycle: Equatable, Sendable {
        case active
        case failurePending
        case retired
    }

    struct Snapshot: Equatable, Sendable {
        let coordinate: Phase2ShellSurfaceCommandCoordinate
        let lifecycle: Lifecycle
        let pendingCommandCount: Int
        let pendingWriteByteCount: Int
        let maximumObservedPendingCommandCount: Int
        let maximumObservedPendingWriteByteCount: Int
        let isDraining: Bool
    }

    enum Submission: Equatable, Sendable {
        case accepted
        case ignored
        case inputDisabled
        case retired
        case failed(Phase2GhosttyBrokerCommandPumpFailure)
    }

    private struct DrainLease: Equatable, Sendable {
        let coordinate: Phase2ShellSurfaceCommandCoordinate
        let identifier: UUID
    }

    private struct FailureDelivery: Equatable, Sendable {
        let coordinate: Phase2ShellSurfaceCommandCoordinate
        let identifier: UUID
        let failure: Phase2GhosttyBrokerCommandPumpFailure
    }

    private enum RouteCompletion {
        case advance
        case retry
        case stop
        case deliver(FailureDelivery)
    }

    private let coordinate: Phase2ShellSurfaceCommandCoordinate
    private let configuration: Configuration
    private let route: Route
    private let failureHandler: FailureHandler
    private let lock = NSLock()
    private var pending: [Phase2GhosttyBrokerSurfaceCommand] = []
    private var pendingWriteByteCount = 0
    private var maximumObservedPendingCommandCount = 0
    private var maximumObservedPendingWriteByteCount = 0
    private var drainLease: DrainLease?
    private var drainTask: Task<Void, Never>?
    private var failureDelivery: FailureDelivery?
    private var lifecycle: Lifecycle = .active
    private var isInputEnabled = false

    @MainActor
    convenience init(
        store: WorkspaceStore,
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        configuration: Configuration = .default,
        failureHandler: @escaping FailureHandler
    ) {
        self.init(
            coordinate: coordinate,
            configuration: configuration,
            route: { [weak store] command in
                guard let store,
                      store.phase2ShellSession.surfaceMediation?.coordinate == coordinate
                else { return .retired }
                if store.phase2ShellSession.isCommandInFlight {
                    // Writes reserve store priority and wait without losing queued keystrokes.
                    if case .write = command { } else { return .deferred }
                }

                switch command {
                case let .write(bytes):
                    guard await store.writePhase2ShellInput(bytes, from: coordinate) else {
                        return store.phase2ShellSession.surfaceMediation?.coordinate == coordinate
                            ? .failed
                            : .retired
                    }
                    return .accepted
                case let .resize(proposal):
                    switch await store.resizePhase2ShellSession(proposal, from: coordinate) {
                    case .presentationOnly, .coalesced, .brokerAccepted:
                        return .accepted
                    case .rejectedStaleCoordinate:
                        return .retired
                    case .brokerResizeRequired, .rejectedInvalid, .brokerRejected:
                        return .failed
                    }
                case let .close(reason):
                    guard await store.cleanupPhase2ShellSession(
                        reason: reason,
                        from: coordinate
                    ) else {
                        return store.phase2ShellSession.surfaceMediation?.coordinate == coordinate
                            ? .failed
                            : .retired
                    }
                    return .accepted
                }
            },
            failureHandler: failureHandler
        )
    }

    init(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        configuration: Configuration = .default,
        route: @escaping Route,
        failureHandler: @escaping FailureHandler
    ) {
        self.coordinate = coordinate
        self.configuration = configuration
        self.route = route
        self.failureHandler = failureHandler
        pending.reserveCapacity(configuration.maximumPendingCommands)
    }

    func setInputEnabled(_ isEnabled: Bool) {
        lock.withLock {
            guard lifecycle == .active else { return }
            isInputEnabled = isEnabled
            guard !isEnabled else { return }
            pending.removeAll { command in
                if case .write = command { return true }
                return false
            }
            pendingWriteByteCount = pending.reduce(into: 0) { count, command in
                count += command.pendingWriteByteCount
            }
        }
    }

    @discardableResult
    func submit(_ work: MacScopeGhosttyExternalIOBridge.Work) -> Submission {
        if let health = Phase2GhosttyBrokerHealthFailure.project(work, expected: coordinate) {
            return fail(.bridgeHealth(health))
        }
        guard let command = Phase2GhosttyBrokerSurfaceCommand.project(
            work,
            expected: coordinate
        ) else { return .ignored }
        return submit(command)
    }

    @discardableResult
    func submit(_ command: Phase2GhosttyBrokerSurfaceCommand) -> Submission {
        var drainToSchedule: DrainLease?
        var failureToSchedule: FailureDelivery?
        let submission = lock.withLock { () -> Submission in
            guard lifecycle == .active else { return .retired }
            if case .write = command, !isInputEnabled { return .inputDisabled }

            let byteAddition = pendingWriteByteCount.addingReportingOverflow(
                command.pendingWriteByteCount
            )
            guard pending.count < configuration.maximumPendingCommands,
                  !byteAddition.overflow,
                  byteAddition.partialValue <= configuration.maximumPendingWriteBytes
            else {
                let failure = Phase2GhosttyBrokerCommandPumpFailure.saturated(
                    maximumPendingCommands: configuration.maximumPendingCommands,
                    maximumPendingWriteBytes: configuration.maximumPendingWriteBytes
                )
                failureToSchedule = transitionToFailureLocked(failure)
                return .failed(failure)
            }

            pending.append(command)
            pendingWriteByteCount = byteAddition.partialValue
            maximumObservedPendingCommandCount = max(
                maximumObservedPendingCommandCount,
                pending.count
            )
            maximumObservedPendingWriteByteCount = max(
                maximumObservedPendingWriteByteCount,
                pendingWriteByteCount
            )
            if drainLease == nil {
                let lease = DrainLease(coordinate: coordinate, identifier: UUID())
                drainLease = lease
                drainToSchedule = lease
            }
            return .accepted
        }

        if let drainToSchedule { scheduleDrain(drainToSchedule) }
        if let failureToSchedule { scheduleFailureDelivery(failureToSchedule) }
        return submission
    }

    func retire() {
        lock.withLock {
            transitionToRetiredLocked()
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                coordinate: coordinate,
                lifecycle: lifecycle,
                pendingCommandCount: pending.count,
                pendingWriteByteCount: pendingWriteByteCount,
                maximumObservedPendingCommandCount: maximumObservedPendingCommandCount,
                maximumObservedPendingWriteByteCount: maximumObservedPendingWriteByteCount,
                isDraining: drainLease != nil
            )
        }
    }

    private func fail(_ failure: Phase2GhosttyBrokerCommandPumpFailure) -> Submission {
        let delivery = lock.withLock { transitionToFailureLocked(failure) }
        guard let delivery else { return .retired }
        scheduleFailureDelivery(delivery)
        return .failed(failure)
    }

    private func scheduleDrain(_ lease: DrainLease) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain(lease: lease)
        }
        let installed = lock.withLock { () -> Bool in
            guard lifecycle == .active, drainLease == lease else { return false }
            drainTask = task
            return true
        }
        if !installed { task.cancel() }
    }

    @MainActor
    private func drain(lease: DrainLease) async {
        drainLoop: while !Task.isCancelled, let command = nextCommand(for: lease) {
            while !Task.isCancelled {
                let disposition = await route(command)
                let completion = lock.withLock {
                    completeRouteLocked(disposition, command: command, lease: lease)
                }
                switch completion {
                case .advance:
                    continue drainLoop
                case .retry:
                    do {
                        try await Task.sleep(
                            nanoseconds: configuration.contentionDelayNanoseconds
                        )
                    } catch {
                        return
                    }
                case .stop:
                    return
                case let .deliver(delivery):
                    scheduleFailureDelivery(delivery)
                    return
                }
            }
        }
    }

    private func nextCommand(
        for lease: DrainLease
    ) -> Phase2GhosttyBrokerSurfaceCommand? {
        lock.withLock {
            guard lifecycle == .active, drainLease == lease else { return nil }
            guard !pending.isEmpty else {
                drainLease = nil
                drainTask = nil
                return nil
            }
            let command = pending.removeFirst()
            pendingWriteByteCount -= command.pendingWriteByteCount
            return command
        }
    }

    private func completeRouteLocked(
        _ disposition: Phase2GhosttyBrokerCommandRouteDisposition,
        command: Phase2GhosttyBrokerSurfaceCommand,
        lease: DrainLease
    ) -> RouteCompletion {
        guard lifecycle == .active, drainLease == lease else { return .stop }
        switch disposition {
        case .accepted:
            return .advance
        case .deferred:
            return .retry
        case .retired:
            transitionToRetiredLocked()
            return .stop
        case .failed:
            guard let delivery = transitionToFailureLocked(.routeRejected(command)) else {
                return .stop
            }
            return .deliver(delivery)
        }
    }

    private func transitionToFailureLocked(
        _ failure: Phase2GhosttyBrokerCommandPumpFailure
    ) -> FailureDelivery? {
        guard lifecycle == .active else { return nil }
        lifecycle = .failurePending
        isInputEnabled = false
        clearPendingLocked()
        drainLease = nil
        drainTask?.cancel()
        drainTask = nil
        let delivery = FailureDelivery(
            coordinate: coordinate,
            identifier: UUID(),
            failure: failure
        )
        failureDelivery = delivery
        return delivery
    }

    private func transitionToRetiredLocked() {
        lifecycle = .retired
        isInputEnabled = false
        clearPendingLocked()
        drainLease = nil
        drainTask?.cancel()
        drainTask = nil
        failureDelivery = nil
    }

    private func clearPendingLocked() {
        pending.removeAll(keepingCapacity: false)
        pendingWriteByteCount = 0
    }

    private func scheduleFailureDelivery(_ delivery: FailureDelivery) {
        Task { @MainActor [weak self] in
            self?.deliverFailure(delivery)
        }
    }

    @MainActor
    private func deliverFailure(_ delivery: FailureDelivery) {
        let failure = lock.withLock { () -> Phase2GhosttyBrokerCommandPumpFailure? in
            guard lifecycle == .failurePending,
                  failureDelivery == delivery,
                  delivery.coordinate == coordinate
            else { return nil }
            lifecycle = .retired
            failureDelivery = nil
            return delivery.failure
        }
        guard let failure else { return }
        failureHandler(failure)
    }
}

private extension Phase2GhosttyBrokerSurfaceCommand {
    var pendingWriteByteCount: Int {
        switch self {
        case let .write(bytes): bytes.count
        case .resize, .close: 0
        }
    }
}

import Combine
import Foundation

/// View-model-local ordering authority for async debugger snapshots. The transport snapshots stay
/// protocol-neutral; a ticket binds one result to the exact session generation, accepted snapshot
/// revision, request issue order, and request snapshot that produced it.
struct DebuggerSnapshotAcceptanceGate {
    struct Coordinate: Equatable {
        var sessionGeneration: UInt64
        var snapshotRevision: UInt64
    }

    struct Ticket: Equatable {
        var sequence: UInt64
        var coordinate: Coordinate
        var requestSnapshot: DebuggerSessionSnapshot
        var permitsForeignEpoch: Bool
        var isValid: Bool
    }

    private(set) var coordinate = Coordinate(sessionGeneration: 0, snapshotRevision: 0)
    private var nextSequence: UInt64 = 0
    private var latestIssuedSequence: UInt64 = 0
    private var isExhausted = false

    mutating func beginRequest(for snapshot: DebuggerSessionSnapshot) -> Ticket {
        makeTicket(for: snapshot, permitsForeignEpoch: false)
    }

    mutating func beginNewSessionRequest(for snapshot: DebuggerSessionSnapshot) -> Ticket {
        let (nextGeneration, overflowed) = coordinate.sessionGeneration.addingReportingOverflow(1)
        guard !isExhausted, !overflowed else {
            isExhausted = true
            return invalidTicket(for: snapshot, permitsForeignEpoch: true)
        }
        coordinate = Coordinate(sessionGeneration: nextGeneration, snapshotRevision: 0)
        return makeTicket(for: snapshot, permitsForeignEpoch: true)
    }

    private mutating func makeTicket(
        for snapshot: DebuggerSessionSnapshot,
        permitsForeignEpoch: Bool
    ) -> Ticket {
        let (sequence, overflowed) = nextSequence.addingReportingOverflow(1)
        guard !isExhausted, !overflowed else {
            isExhausted = true
            return invalidTicket(for: snapshot, permitsForeignEpoch: permitsForeignEpoch)
        }
        nextSequence = sequence
        latestIssuedSequence = nextSequence
        return Ticket(
            sequence: nextSequence,
            coordinate: coordinate,
            requestSnapshot: snapshot,
            permitsForeignEpoch: permitsForeignEpoch,
            isValid: true
        )
    }

    private func invalidTicket(
        for snapshot: DebuggerSessionSnapshot,
        permitsForeignEpoch: Bool
    ) -> Ticket {
        Ticket(
            sequence: nextSequence,
            coordinate: coordinate,
            requestSnapshot: snapshot,
            permitsForeignEpoch: permitsForeignEpoch,
            isValid: false
        )
    }

    mutating func accept(
        _ ticket: Ticket,
        currentSnapshot: DebuggerSessionSnapshot,
        candidateSnapshot: DebuggerSessionSnapshot? = nil
    ) -> Bool {
        guard isCurrent(ticket, currentSnapshot: currentSnapshot) else {
            return false
        }
        if let candidateSnapshot,
           !acceptsTransportAuthority(
               from: currentSnapshot,
               candidate: candidateSnapshot,
               permitsForeignEpoch: ticket.permitsForeignEpoch
           ) {
            return false
        }
        if let candidateSnapshot,
           !acceptsRuntimeModuleAuthority(
               from: currentSnapshot,
               candidate: candidateSnapshot,
               permitsForeignEpoch: ticket.permitsForeignEpoch
           ) {
            return false
        }
        if let candidateSnapshot,
           !acceptsBreakpointBindingAuthority(
               from: currentSnapshot,
               candidate: candidateSnapshot,
               permitsForeignEpoch: ticket.permitsForeignEpoch
           ) {
            return false
        }
        let (nextRevision, overflowed) = coordinate.snapshotRevision.addingReportingOverflow(1)
        guard !overflowed else {
            isExhausted = true
            return false
        }
        coordinate.snapshotRevision = nextRevision
        return true
    }

    func isCurrent(
        _ ticket: Ticket,
        currentSnapshot: DebuggerSessionSnapshot
    ) -> Bool {
        ticket.isValid
            && !isExhausted
            && ticket.sequence == latestIssuedSequence
            && ticket.coordinate == coordinate
            && snapshotsMatchForTransportTicket(ticket.requestSnapshot, currentSnapshot)
    }

    private func snapshotsMatchForTransportTicket(
        _ requested: DebuggerSessionSnapshot,
        _ current: DebuggerSessionSnapshot
    ) -> Bool {
        var requestedTransport = requested
        var currentTransport = current
        requestedTransport.runtimeMappingProjection = nil
        currentTransport.runtimeMappingProjection = nil
        return requestedTransport == currentTransport
    }

    private func acceptsRuntimeModuleAuthority(
        from current: DebuggerSessionSnapshot,
        candidate: DebuggerSessionSnapshot,
        permitsForeignEpoch: Bool
    ) -> Bool {
        let currentAuthority = RuntimeModuleAuthority(snapshot: current)
        let candidateAuthority = RuntimeModuleAuthority(snapshot: candidate)

        if current.transportSessionCoordinate?.epoch
            != candidate.transportSessionCoordinate?.epoch {
            return permitsForeignEpoch && candidateAuthority != .invalid
        }

        switch (currentAuthority, candidateAuthority) {
        case (.legacy, .legacy), (.legacy, .typed):
            return true
        case (.typed, .legacy), (.invalid, _), (_, .invalid):
            return false
        case let (.typed(currentRevision, currentValue),
                  .typed(candidateRevision, candidateValue)):
            guard candidateRevision >= currentRevision else { return false }
            if candidateRevision > currentRevision || candidateValue == currentValue {
                return true
            }
            return acceptsSameRevisionFailClosedRuntimeModuleAuthority(
                from: current,
                candidate: candidate,
                authority: candidateValue
            )
        }
    }

    private func acceptsSameRevisionFailClosedRuntimeModuleAuthority(
        from current: DebuggerSessionSnapshot,
        candidate: DebuggerSessionSnapshot,
        authority: DebuggerRuntimeModuleAuthority
    ) -> Bool {
        guard case .unavailable(let reason) = authority,
              let currentSession = current.transportSessionCoordinate,
              let candidateSession = candidate.transportSessionCoordinate,
              currentSession.epoch == candidateSession.epoch,
              candidateSession.lifecycleRevision >= currentSession.lifecycleRevision,
              let currentEvent = current.transportEventSequence,
              let candidateEvent = candidate.transportEventSequence,
              candidateEvent > currentEvent,
              let disposition = candidate.transportTargetDisposition else {
            return false
        }

        switch (reason, disposition) {
        case (.running, .running),
             (.terminal, .exited),
             (.terminal, .detached),
             (.terminal, .terminated):
            return candidateSession.lifecycleRevision > currentSession.lifecycleRevision
        case (.sessionInvalidated, .unknown):
            return true
        default:
            return false
        }
    }

    private func acceptsBreakpointBindingAuthority(
        from current: DebuggerSessionSnapshot,
        candidate: DebuggerSessionSnapshot,
        permitsForeignEpoch: Bool
    ) -> Bool {
        let currentAuthority = BreakpointBindingAuthority(snapshot: current)
        let candidateAuthority = BreakpointBindingAuthority(snapshot: candidate)

        if current.transportSessionCoordinate?.epoch
            != candidate.transportSessionCoordinate?.epoch {
            return permitsForeignEpoch && candidateAuthority != .invalid
        }

        switch (currentAuthority, candidateAuthority) {
        case (.legacy, .legacy), (.legacy, .typed):
            return true
        case (.typed, .legacy), (.invalid, _), (_, .invalid):
            return false
        case let (.typed(currentRevision, currentValue),
                  .typed(candidateRevision, candidateValue)):
            guard candidateRevision >= currentRevision else { return false }
            if candidateRevision > currentRevision || candidateValue == currentValue {
                return true
            }
            // Revision overflow installs a one-way same-revision terminal/fail-closed tombstone.
            // Admit it only alongside a newer correlated transport event in the same epoch.
            guard (candidateValue.isInvalidated || candidateValue.isTerminal),
                  !(currentValue.isInvalidated || currentValue.isTerminal),
                  let currentEvent = current.transportEventSequence,
                  let candidateEvent = candidate.transportEventSequence,
                  candidateEvent > currentEvent else {
                return false
            }
            return true
        }
    }

    private func acceptsTransportAuthority(
        from current: DebuggerSessionSnapshot,
        candidate: DebuggerSessionSnapshot,
        permitsForeignEpoch: Bool
    ) -> Bool {
        let currentAuthority = TransportAuthority(snapshot: current)
        let candidateAuthority = TransportAuthority(snapshot: candidate)

        switch (currentAuthority, candidateAuthority) {
        case (.legacy, .legacy):
            return true
        case (.legacy, .typed):
            return permitsForeignEpoch
        case (.typed, .legacy), (.invalid, _), (_, .invalid):
            return false
        case (.typed(let currentTransport), .typed(let candidateTransport)):
            if currentTransport.session.epoch != candidateTransport.session.epoch {
                return permitsForeignEpoch
            }
            guard candidateTransport.eventSequence >= currentTransport.eventSequence,
                  candidateTransport.session.lifecycleRevision
                    >= currentTransport.session.lifecycleRevision else {
                return false
            }
            if let currentTargetAuthority = currentTransport.targetAuthority,
               candidateTransport.targetAuthority != currentTargetAuthority {
                return false
            }
            if isTerminal(currentTransport.disposition, snapshot: current),
               !permitsForeignEpoch {
                return candidateTransport.disposition == currentTransport.disposition
            }
            if candidateTransport.session.lifecycleRevision
                == currentTransport.session.lifecycleRevision,
               let currentStop = currentTransport.stop {
                if let candidateStop = candidateTransport.stop {
                    guard candidateStop.stopRevision >= currentStop.stopRevision else {
                        return false
                    }
                } else {
                    guard candidateTransport.eventSequence > currentTransport.eventSequence,
                          candidateTransport.disposition == .unknown,
                          candidate.transportRuntimeModuleAuthority
                            == .unavailable(.sessionInvalidated) else {
                        return false
                    }
                }
            }
            return true
        }
    }

    private func isTerminal(
        _ disposition: DebuggerTargetDisposition,
        snapshot: DebuggerSessionSnapshot
    ) -> Bool {
        switch disposition {
        case .exited, .detached, .terminated:
            return true
        case .unknown:
            if case .detaching = snapshot.processState,
               case .disconnecting = snapshot.backendState {
                return false
            }
            return true
        case .notApplicable, .notStarted, .running, .stopped:
            return false
        }
    }

    private enum TransportAuthority {
        struct Typed {
            let session: DebuggerSessionCoordinate
            let stop: DebuggerStopCoordinate?
            let eventSequence: DebuggerEventSequence
            let disposition: DebuggerTargetDisposition
            let targetAuthority: DebuggerSessionTargetAuthority?
        }

        case legacy
        case typed(Typed)
        case invalid

        init(snapshot: DebuggerSessionSnapshot) {
            let hasAnyMetadata = snapshot.transportSessionCoordinate != nil
                || snapshot.transportStopCoordinate != nil
                || snapshot.transportEventSequence != nil
                || snapshot.transportDiagnostic != nil
                || snapshot.transportTargetDisposition != nil
                || snapshot.transportTargetAuthority != nil
            guard hasAnyMetadata else {
                self = .legacy
                return
            }
            guard let session = snapshot.transportSessionCoordinate,
                  let eventSequence = snapshot.transportEventSequence,
                  let disposition = snapshot.transportTargetDisposition else {
                self = .invalid
                return
            }
            if let stop = snapshot.transportStopCoordinate,
               stop.session != session {
                self = .invalid
                return
            }
            if case .stopped = disposition,
               snapshot.transportStopCoordinate == nil {
                self = .invalid
                return
            }
            self = .typed(
                Typed(
                    session: session,
                    stop: snapshot.transportStopCoordinate,
                    eventSequence: eventSequence,
                    disposition: disposition,
                    targetAuthority: snapshot.transportTargetAuthority
                )
            )
        }
    }

    private enum RuntimeModuleAuthority: Equatable {
        case legacy
        case typed(DebuggerRuntimeModuleAuthorityRevision, DebuggerRuntimeModuleAuthority)
        case invalid

        init(snapshot: DebuggerSessionSnapshot) {
            switch (
                snapshot.transportRuntimeModuleAuthorityRevision,
                snapshot.transportRuntimeModuleAuthority
            ) {
            case (nil, nil):
                self = .legacy
            case let (.some(revision), .some(authority)):
                if case .available(let inventory) = authority {
                    guard inventory.stop == snapshot.transportStopCoordinate,
                          inventory.processID == snapshot.liveProcessID else {
                        self = .invalid
                        return
                    }
                }
                self = .typed(revision, authority)
            case (.some, nil), (nil, .some):
                self = .invalid
            }
        }
    }

    private enum BreakpointBindingAuthority: Equatable {
        case legacy
        case typed(
            DebuggerBreakpointBindingAuthorityRevision,
            DebuggerBreakpointBindingReducerSnapshot
        )
        case invalid

        init(snapshot: DebuggerSessionSnapshot) {
            switch (
                snapshot.transportBreakpointBindingAuthorityRevision,
                snapshot.transportBreakpointBindingState
            ) {
            case (nil, nil):
                self = .legacy
            case let (.some(revision), .some(state)):
                guard revision == state.authorityRevision,
                      state.sessionEpoch == snapshot.transportSessionCoordinate?.epoch else {
                    self = .invalid
                    return
                }
                self = .typed(revision, state)
            case (.some, nil), (nil, .some):
                self = .invalid
            }
        }
    }
}

/// App-observable proof that one existing debugger run-control action passed the view model's
/// transport acceptance gate. This value is intentionally emitted only after the underlying
/// `DebuggerClient` result is accepted, so disabled, rejected, stale, or superseded requests do not
/// widen Phase 2 runtime authority.
struct DebuggerControlledRuntimeActionEvent: Equatable, Identifiable {
    let id: UUID
    let correlationID: UUID?
    let sequence: UInt64
    let action: DebuggerControlAction
    let sessionID: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?
    let createdAt: Date

    init?(
        id: UUID = UUID(),
        correlationID: UUID? = nil,
        sequence: UInt64,
        action: DebuggerControlAction,
        snapshot: DebuggerSessionSnapshot,
        createdAt: Date = Date()
    ) {
        guard let coordinate = snapshot.transportSessionCoordinate else { return nil }
        self.id = id
        self.correlationID = correlationID
        self.sequence = sequence
        self.action = action
        self.sessionID = coordinate.epoch.rawValue
        self.lifecycleRevision = coordinate.lifecycleRevision.rawValue
        self.stopRevision = snapshot.transportStopCoordinate?.stopRevision.rawValue
        self.eventSequence = snapshot.transportEventSequence?.rawValue
        self.createdAt = createdAt
    }
}

@MainActor
final class DebuggerPanelViewModel: ObservableObject {
    static let maximumWatchCount = 16
    @Published private(set) var watchDefinitions: [DebuggerWatchDefinition] = []
    @Published private(set) var watchEvaluations: [UUID: DebuggerWatchEvaluation] = [:]
    @Published var watchExpressionText = ""
    @Published private(set) var watchAuthoringError: String?
    @Published private(set) var watchEvaluationRequestID: UUID?
    @Published private(set) var watchesAreSaved = false
    private var commitWatchDefinitions: (([DebuggerWatchDefinition]) throws -> Void)?
    private(set) var savedWatchOwner: WorkspaceStore.SavedWatchOwner?
    @Published private(set) var workspaceAdmissionPending = false
    private var workspaceAdmissionRequestID: UUID?
    private var ownsWorkspaceInstallation: (() -> Bool)?

    private var isWorkspaceAdmissionOpen: Bool {
        workspaceRetirementTask == nil && !workspaceAdmissionPending
            && (ownsWorkspaceInstallation?() ?? true)
    }

    /// Fresh models cannot issue backend work until the old exact document authority drains.
    func deferWorkspaceAdmission(
        until drain: Task<Void, Never>, stillOwned: @escaping () -> Bool
    ) {
        guard isWorkspaceAdmissionOpen else { return }
        workspaceAdmissionPending = true
        let requestID = UUID()
        workspaceAdmissionRequestID = requestID
        Task { @MainActor [weak self] in
            await drain.value
            guard let self, self.workspaceRetirementTask == nil,
                  self.workspaceAdmissionRequestID == requestID else { return }
            guard stillOwned() else {
                _ = self.beginWorkspaceRetirement()
                return
            }
            self.workspaceAdmissionRequestID = nil
            self.workspaceAdmissionPending = false
        }
    }

    /// Composition captures ownership once. Never recapture against a replacement document.
    static func makeWorkspaceModel(client: any DebuggerClient, store: WorkspaceStore) -> DebuggerPanelViewModel {
        let model = DebuggerPanelViewModel(client: client)
        do {
            guard let owner = store.captureSavedWatchOwner() else { throw WorkspaceDocumentSessionError.closed }
            model.savedWatchOwner = owner
            model.ownsWorkspaceInstallation = { [weak store] in store?.isCurrentSavedWatchOwner(owner) == true }
            let definitions = try store.savedWatchCatalog.definitions.map {
                try DebuggerWatchDefinition(id: $0.id, expression: $0.expression)
            }
            try model.configureWatchPersistence(initialDefinitions: definitions) { [weak store] definitions in
                guard let store else { throw WorkspaceDocumentSessionError.closed }
                try store.replaceSavedWatchDefinitions(definitions.map {
                    try WorkspaceSavedWatchDefinition(id: $0.id, expression: $0.expression)
                }, owner: owner)
            }
            let drain = store.debuggerAdmissionDrain(for: owner)
            guard store.installPhase2DebuggerProposalExecutor(model, owner: owner) else {
                throw WorkspaceDocumentSessionError.closed
            }
            if let drain {
                model.deferWorkspaceAdmission(until: drain) { [weak store] in
                    store?.isCurrentSavedWatchOwner(owner) == true
                }
            }
        } catch {
            model.ownsWorkspaceInstallation = { false }
            model.watchAuthoringError = error.localizedDescription
            // Failed production binding must not silently downgrade to session-only authoring.
            model.commitWatchDefinitions = { _ in throw WorkspaceDocumentSessionError.closed }
        }
        return model
    }

    /// Restore has no save echo and no evaluation. Authoring persists before changing local state.
    func configureWatchPersistence(
        initialDefinitions: [DebuggerWatchDefinition],
        commit: @escaping ([DebuggerWatchDefinition]) throws -> Void
    ) throws {
        guard commitWatchDefinitions == nil else {
            throw DebuggerAuthoringParseError.invalid("Watch persistence is already bound to this workspace.")
        }
        try replaceWatchDefinitions(initialDefinitions)
        commitWatchDefinitions = commit
        watchesAreSaved = true
    }

    var canEvaluateWatches: Bool {
        isWorkspaceAdmissionOpen && watchEvaluationRequestID == nil
            && !watchDefinitions.isEmpty && currentInspectionCoordinate != nil
            && session.canEvaluateExpressionLiveProcess
            && capabilities.executionControlSupport.isSupported
    }

    /// Atomic restore seam for a workspace persistence owner. Definitions only; no values survive.
    func replaceWatchDefinitions(_ definitions: [DebuggerWatchDefinition]) throws {
        let validated = try validatedWatchDefinitions(definitions)
        invalidateWatchEvaluations()
        watchDefinitions = validated
        watchAuthoringError = nil
    }

    private func validatedWatchDefinitions(_ definitions: [DebuggerWatchDefinition]) throws -> [DebuggerWatchDefinition] {
        guard workspaceRetirementTask == nil, ownsWorkspaceInstallation?() ?? true else {
            throw DebuggerAuthoringParseError.invalid("This workspace debugger has retired.")
        }
        guard definitions.count <= Self.maximumWatchCount,
              Set(definitions.map(\.id)).count == definitions.count else {
            throw DebuggerAuthoringParseError.invalid("Use at most 16 watches with unique identities.")
        }
        return try definitions.map { try DebuggerWatchDefinition(id: $0.id, expression: $0.expression) }
    }

    private func authorWatchDefinitions(_ definitions: [DebuggerWatchDefinition]) throws {
        let validated = try validatedWatchDefinitions(definitions)
        try commitWatchDefinitions?(validated)
        invalidateWatchEvaluations()
        watchDefinitions = validated
        watchAuthoringError = nil
    }

    func addWatch(expression: String) {
        guard workspaceRetirementTask == nil else {
            watchAuthoringError = "This workspace debugger has retired."
            return
        }
        do {
            try authorWatchDefinitions(watchDefinitions + [DebuggerWatchDefinition(expression: expression)])
            watchExpressionText = ""
        } catch { watchAuthoringError = error.localizedDescription }
    }

    func removeWatch(id: UUID) {
        guard workspaceRetirementTask == nil else {
            watchAuthoringError = "This workspace debugger has retired."
            return
        }
        do { try authorWatchDefinitions(watchDefinitions.filter { $0.id != id }) }
        catch { watchAuthoringError = error.localizedDescription }
    }

    private func invalidateWatchEvaluations() {
        watchEvaluationRequestID = nil
        watchEvaluations.removeAll()
    }

    private func beginSnapshotRequest() -> DebuggerSnapshotAcceptanceGate.Ticket {
        invalidateWatchEvaluations()
        return snapshotAcceptanceGate.beginRequest(for: session)
    }

    /// Manual only: LLDB expressions may execute code. Never invoked by stop/poll callbacks.
    func evaluateWatches() async {
        guard canEvaluateWatches, let coordinate = currentInspectionCoordinate else { return }
        invalidateWatchEvaluations()
        let requestID = UUID()
        watchEvaluationRequestID = requestID
        let definitions = watchDefinitions
        defer {
            if watchEvaluationRequestID == requestID {
                if Task.isCancelled || currentInspectionCoordinate != coordinate {
                    invalidateWatchEvaluations()
                } else { watchEvaluationRequestID = nil }
            }
        }
        for definition in definitions {
            guard isWorkspaceAdmissionOpen, !Task.isCancelled,
                  watchEvaluationRequestID == requestID,
                  currentInspectionCoordinate == coordinate else { return }
            let ticket = snapshotAcceptanceGate.beginRequest(for: session)
            // Preserve the same conservative post-expression mapping policy as scalar evaluation.
            revokedRuntimeModuleAuthority = Self.runtimeModuleAuthorityCoordinate(for: session)
            runtimeMappingProjection = nil
            do {
                let result = try await client.evaluateExpression(
                    DebuggerExpressionRequest(expression: definition.expression), from: ticket.requestSnapshot
                )
                guard isWorkspaceAdmissionOpen, !Task.isCancelled,
                      watchEvaluationRequestID == requestID,
                      currentInspectionCoordinate == coordinate else { return }
                if let next = result.refreshedSnapshot {
                    guard installAcceptedSnapshot(next, from: ticket, preservingWatchRequestID: requestID),
                          currentInspectionCoordinate == coordinate else {
                        if watchEvaluationRequestID == requestID { invalidateWatchEvaluations() }
                        return
                    }
                } else {
                    guard snapshotAcceptanceGate.accept(ticket, currentSnapshot: session) else { return }
                }
                watchEvaluations[definition.id] = DebuggerWatchEvaluation(
                    coordinate: coordinate, value: result.value, type: result.type, error: nil
                )
            } catch {
                guard isWorkspaceAdmissionOpen, !Task.isCancelled, watchEvaluationRequestID == requestID,
                      currentInspectionCoordinate == coordinate,
                      snapshotAcceptanceGate.accept(ticket, currentSnapshot: session) else { return }
                applyClientError(error)
                // All earlier successes are revoked on a batch failure; retain only this error.
                watchEvaluations[definition.id] = DebuggerWatchEvaluation(
                    coordinate: coordinate, value: nil, type: nil, error: error.localizedDescription
                )
                return
            }
        }
    }

    static let signedTargetAttachPolicyReason = DebuggerSignedTargetPolicySummary.pendingPolicyReason

    /// Transport-only identity of one available raw module inventory. Expression admission revokes
    /// this coordinate before target code executes; workspace catalog churn cannot make it current
    /// again. Only a subsequently accepted snapshot with different transport authority clears it.
    private struct RuntimeModuleAuthorityCoordinate: Equatable {
        let stop: DebuggerStopCoordinate
        let processID: Int32
        let authorityRevision: DebuggerRuntimeModuleAuthorityRevision
        let inventoryRevision: DebuggerRuntimeModuleInventoryRevision
    }

    @Published private(set) var session: DebuggerSessionSnapshot
    /// Registers whose value differs from the previous snapshot's: the register grid marks them
    /// (accent name, outline and dot; Lumen 0.16.0). Cleared when no registers are recovered.
    @Published private(set) var changedRegisterNames: Set<String> = []
    /// Variables whose value changed since the last stop (`DebuggerVariableChanges.key`).
    @Published private(set) var changedVariableKeys: Set<String> = []
    private var variableChanges = DebuggerVariableChanges()
    @Published private(set) var lastError: String?
    @Published var importedExecutablePath: String
    @Published var processIDText: String
    @Published var selectedTargetID: DebuggerTargetSelectionDescriptor.ID?
    @Published private(set) var workspaceLaunchTarget: DebuggerLaunchTargetDescriptor?
    @Published private(set) var workspaceAuthority: DebuggerWorkspaceAuthority?
    @Published private(set) var focusedLaunchCandidate: DebuggerFocusedLaunchCandidate?
    @Published private(set) var workspaceInput: DebuggerWorkspaceInput?
    /// The workspace image captured by the successful launch. Candidate focus changes never mutate
    /// this owner while a live process exists.
    @Published private(set) var activeWorkspaceImageSlot: ImageSlot?
    /// Workspace correlation is derived above transport authority and therefore lives outside the
    /// request-ticket snapshot identity. It may advance with the workspace catalog while a
    /// transport request is pending without invalidating that request.
    @Published private(set) var runtimeMappingProjection: DebuggerRuntimeMappingProjection?

    // MARK: Authoring fields (conditional breakpoints / register write / memory read)

    /// Address (hex) of the breakpoint currently selected for condition editing.
    @Published var breakpointEditAddressText: String
    @Published var breakpointConditionText: String
    @Published var breakpointIgnoreCountText: String

    @Published var registerWriteNameText: String
    @Published var registerWriteValueText: String

    @Published var memoryReadAddressText: String
    @Published var memoryReadByteCountText: String

    @Published var memoryWriteAddressText: String
    @Published var memoryWriteBytesText: String

    // MARK: Expression evaluation + thread selection authoring

    /// Free-form expression to evaluate in the current stopped frame.
    @Published var expressionText: String
    /// The most recent successful evaluation result, surfaced in the evaluator UI.
    @Published private(set) var expressionResult: DebuggerExpressionResult?

    // MARK: Call-stack frame selection + background wait-stop (Tier-3)

    /// The user-selected call-stack frame index (0-based, `frame #0` innermost), or
    /// `nil` to default to the innermost frame. Drives `selectedFrame` /
    /// `selectedFrameProgramCounter` and the listing navigation.
    @Published private(set) var selectedFrameIndex: Int?
    @Published private(set) var collapsedVariableTokens: Set<DebuggerVariablePathToken>
    @Published private(set) var variableExpansionStates:
        [DebuggerVariablePathToken: DebuggerVariablesInspectionPresentation.ExpansionState]
    @Published private(set) var activeVariableExpansionToken: DebuggerVariablePathToken?

    /// The background wait-for-stop lifecycle machine. Advanced honestly as run
    /// commands are issued (→ `.waitingForStop`) and the resulting snapshot is
    /// folded back in (→ `.stopped` / `.exited` / `.crashed`). Pure + testable.
    @Published private(set) var waitStopMachine: DebuggerWaitStopMachine
    @Published private(set) var lastControlledRuntimeActionEvent: DebuggerControlledRuntimeActionEvent?

    // MARK: Launch configuration authoring (arguments / environment / cwd)

    /// Raw arguments field; shell-word split when forming the launch invocation.
    @Published var launchArgumentsText: String
    /// Editable environment overrides. A trailing blank row is kept so the SwiftUI
    /// list always offers an empty pair to type into; blank rows are dropped at
    /// parse time.
    @Published var launchEnvironmentEntries: [DebuggerEnvironmentEntry]
    /// Authored working directory (absolute / tilde path), or empty to inherit the
    /// configuration's default (the executable's directory).
    @Published var launchWorkingDirectoryText: String

    // MARK: Value formatting (W4-B)

    /// The display interpretation applied to register / memory values in the panel
    /// (hex / decimal / signed-decimal / float). This is pure presentation: it
    /// re-renders the *already-read* values and never issues a transport command.
    @Published var valueFormat: DebuggerValueFormat = .hex

    // MARK: Attach-to-PID authoring (Tier-3 DEBUGGER-DEPTH)

    /// Legacy raw PID text retained only while the disabled picker migrates to
    /// exact observed identities. This value cannot authorize a transport command.
    @Published var attachProcessIDText: String
    /// The candidate running processes most-recently enumerated for the picker.
    @Published private(set) var attachProcessList: [DebuggerProcessListEntry]
    /// Exact-identity process catalog displayed by the product-facing attach sheet.
    @Published private(set) var localProcessDiscoverySnapshot: DebuggerLocalProcessDiscoverySnapshot
    /// Generation-bound selected process identity key. A PID alone is never enough authority.
    @Published var selectedLocalProcessSelection: DebuggerLocalProcessCatalogSelection?
    @Published private(set) var isAuthorizingLocalProcessAttach: Bool
    /// Single-flight latch for launch and attach. It is set synchronously before the first await
    /// of a start, so a second Attach/Launch issued from the same run-loop turn (sheet button plus
    /// Return/row double-click) is refused without touching `session`; mutating `session` while a
    /// start is in flight would invalidate that start's acceptance ticket and strand `.launching`.
    @Published private(set) var isSessionStartInFlight = false
    /// The latest refusal of a local-process attach (policy, state, authorization, transport or a
    /// superseded result). The attach sheet shows it until the selection or catalog changes.
    @Published private(set) var localProcessAttachRefusal: String?
    private var sessionStartToken: UInt64 = 0

    private let client: any DebuggerClient
    private var workspaceRetirementTask: Task<Void, Never>?
    var processObservationSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Document retirement closes backend admission independently of SwiftUI ownership.
    /// Repeated close/termination callbacks share the same origin-aware controller drain.
    func beginWorkspaceRetirement() -> Task<Void, Never> {
        if let workspaceRetirementTask { return workspaceRetirementTask }
        workspaceAdmissionRequestID = nil
        workspaceAdmissionPending = false
        invalidateWatchEvaluations()
        variableExpansionTask?.cancel()
        invalidateWorkspaceReconciliationEpochs()
        let task = Task { @MainActor [self] in await client.shutdown() }
        workspaceRetirementTask = task
        return task
    }
    private let processLister: any DebuggerProcessLister
    private let localProcessDiscoveryService: DebuggerLocalProcessDiscoveryService
    private let attachPolicyOverride: DebuggerAttachPolicy?
    private let selfProcessID: Int32
    private var activeWorkspaceInput: DebuggerWorkspaceInput?
    private var activeWorkspaceLaunchTarget: DebuggerLaunchTargetDescriptor?
    private var candidateWorkspaceInputsBySlot: [ImageSlot: DebuggerWorkspaceInput] = [:]
    private var workspaceOwnershipEpoch = UUID()
    private var activeReconciliationToken = UUID()
    private var latestAcceptedActiveWorkspaceInput: DebuggerWorkspaceInput? = nil
    private var pendingActiveWorkspaceInput: DebuggerWorkspaceInput? = nil
    private var activeWorkspaceInputBeingApplied: DebuggerWorkspaceInput? = nil
    private var isDrainingActiveWorkspaceInputs = false
    private var pendingLogicalBreakpointWorkspaceAuthority:
        DebuggerWorkspaceAuthority? = nil
    private var logicalBreakpointWorkspaceAuthorityBeingApplied:
        DebuggerWorkspaceAuthority? = nil
    private var isDrainingLogicalBreakpointWorkspaceAuthorities = false
    private var lastForwardedLogicalBreakpointReconcileRequest:
        DebuggerLogicalBreakpointReconcileRequest? = nil
    /// Local fail-closed tombstone for commands that can resume target execution. The accepted
    /// transport snapshot remains honest so Pause/Terminate can still recover the exact process.
    @Published private var resumeControlQuarantineReason: String? = nil
    /// Forces the derived compatibility gutter cache to be rebuilt after workspace ownership or
    /// reconciliation epochs change. This flag never authorizes a persistent backend mutation.
    private var activePresentationBreakpointsRequireConvergence = false
    private var snapshotAcceptanceGate = DebuggerSnapshotAcceptanceGate()
    private var nextControlledRuntimeActionSequence: UInt64 = 0
    /// Workspace observations are independent of transport command issue order. Their dedicated
    /// gate still requires an exact unchanged request snapshot, but cannot invalidate a user-issued
    /// continue/step/terminate ticket merely because a catalog revision arrived concurrently.
    private var logicalBreakpointSnapshotAcceptanceGate = DebuggerSnapshotAcceptanceGate()
    /// Current workspace-side identity authority. It is intentionally independent of the
    /// transport snapshot so workspace replacement cannot invalidate an in-flight transport ticket.
    private var workspaceArtifactCatalog: DebuggerWorkspaceArtifactCatalog?
    private var revokedRuntimeModuleAuthority: RuntimeModuleAuthorityCoordinate?
    private var variableExpansionTask: Task<Void, Never>?
    private var variableExpansionRequestID: UUID?

    init(
        client: (any DebuggerClient)? = nil,
        workspaceLaunchTarget: DebuggerLaunchTargetDescriptor? = nil,
        processLister: (any DebuggerProcessLister)? = nil,
        localProcessDiscoveryService: DebuggerLocalProcessDiscoveryService? = nil,
        attachPolicyOverride: DebuggerAttachPolicy? = nil,
        selfProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        let resolvedClient = client ?? LocalLLDBDebuggerClient()
        let initialSnapshot = resolvedClient.makeInitialSnapshot()
        self.client = resolvedClient
        self.processLister = processLister ?? SysctlDebuggerProcessLister(selfProcessID: selfProcessID)
        self.localProcessDiscoveryService = localProcessDiscoveryService
            ?? DebuggerLocalProcessDiscoveryService(
                observer: DebuggerLocalProcessIdentityObserver(
                    provider: DarwinDebuggerLocalProcessEvidenceProvider()
                )
            )
        self.attachPolicyOverride = attachPolicyOverride
        self.selfProcessID = selfProcessID
        self.session = initialSnapshot
        self.lastError = nil
        self.importedExecutablePath = workspaceLaunchTarget?.executablePath ?? ""
        self.processIDText = ""
        self.attachProcessIDText = ""
        self.attachProcessList = []
        self.localProcessDiscoverySnapshot = DebuggerLocalProcessDiscoverySnapshot(
            generation: 0,
            entries: [],
            isRefreshing: false,
            isStale: false,
            metrics: nil,
            aggregateDenials: [:]
        )
        self.selectedLocalProcessSelection = nil
        self.isAuthorizingLocalProcessAttach = false
        self.selectedTargetID = nil
        self.workspaceLaunchTarget = workspaceLaunchTarget
        self.workspaceAuthority = nil
        self.focusedLaunchCandidate = nil
        self.workspaceInput = nil
        self.activeWorkspaceImageSlot = nil
        self.runtimeMappingProjection = Self.transportCompatibleRuntimeMappingProjection(
            initialSnapshot.runtimeMappingProjection,
            for: initialSnapshot
        )
        self.workspaceArtifactCatalog = nil
        self.activeWorkspaceInput = nil
        self.activeWorkspaceLaunchTarget = nil
        self.breakpointEditAddressText = ""
        self.breakpointConditionText = ""
        self.breakpointIgnoreCountText = ""
        self.registerWriteNameText = ""
        self.registerWriteValueText = ""
        self.memoryReadAddressText = ""
        self.memoryReadByteCountText = ""
        self.memoryWriteAddressText = ""
        self.memoryWriteBytesText = ""
        self.expressionText = ""
        self.expressionResult = nil
        self.selectedFrameIndex = nil
        self.collapsedVariableTokens = []
        self.variableExpansionStates = [:]
        self.activeVariableExpansionToken = nil
        self.waitStopMachine = DebuggerWaitStopMachine(
            state: DebuggerWaitStopMachine.state(for: initialSnapshot)
        )
        self.lastControlledRuntimeActionEvent = nil
        self.launchArgumentsText = ""
        self.launchEnvironmentEntries = [DebuggerEnvironmentEntry()]
        self.launchWorkingDirectoryText = ""
    }

    var capabilities: DebuggerCapabilityReport {
        client.capabilities
    }

    var statusSummary: DebuggerSessionStatusSummary {
        DebuggerSessionStatusSummary(
            snapshot: session,
            capabilities: capabilities,
            lastError: lastError
        )
    }

    var statusTitle: String {
        statusSummary.title
    }

    var statusDetail: String {
        statusSummary.detail
    }

    var canLaunch: Bool {
        capabilities.launchSupport.isSupported && session.processState.canLaunchNewProcess
    }

    var canContinue: Bool {
        resumeControlQuarantineReason == nil
            && capabilities.executionControlSupport.isSupported
            && session.canContinueLiveProcess
    }

    var canRunToCursor: Bool {
        resumeControlQuarantineReason == nil
            && capabilities.executionControlSupport.isSupported
            && session.canRunToCursorLiveProcess
    }

    var canStepOver: Bool {
        resumeControlQuarantineReason == nil
            && capabilities.executionControlSupport.isSupported
            && session.canStepOverLiveProcess
    }

    var canStepInto: Bool {
        resumeControlQuarantineReason == nil
            && capabilities.executionControlSupport.isSupported
            && session.canStepIntoLiveProcess
    }

    var canStepOut: Bool {
        resumeControlQuarantineReason == nil
            && capabilities.executionControlSupport.isSupported
            && session.canStepOutLiveProcess
    }

    var canPause: Bool {
        capabilities.executionControlSupport.isSupported && session.canPauseLiveProcess
    }

    var canTerminate: Bool {
        capabilities.executionControlSupport.isSupported && session.canTerminateLiveProcess
    }

    var canDetach: Bool {
        capabilities.executionControlSupport.isSupported && session.canDetachLiveProcess
    }

    var showsSessionEndAction: Bool {
        capabilities.executionControlSupport.isSupported && session.hasLiveProcessSession
    }

    var sessionEndAction: DebuggerControlAction {
        session.canDetachLiveProcess ? .detach : .terminate
    }

    var canRefreshSnapshot: Bool {
        capabilities.executionControlSupport.isSupported && session.canRefreshStoppedSnapshot
    }

    var canWriteRegister: Bool {
        capabilities.executionControlSupport.isSupported && session.canWriteRegisterLiveProcess
    }

    var canReadMemory: Bool {
        capabilities.executionControlSupport.isSupported && session.canReadMemoryLiveProcess
    }

    var canWriteMemory: Bool {
        capabilities.executionControlSupport.isSupported && session.canWriteMemoryLiveProcess
    }

    var canEvaluateExpression: Bool {
        capabilities.executionControlSupport.isSupported && session.canEvaluateExpressionLiveProcess
    }

    var canSelectThread: Bool {
        capabilities.executionControlSupport.isSupported && session.canSelectThreadLiveProcess
    }

    var canSelectFrame: Bool {
        capabilities.executionControlSupport.isSupported && session.canSelectFrameLiveProcess
    }

    /// The stopped process's recovered registers bucketed into display groups
    /// (general-purpose, floating-point/SIMD, system), preserving each group's
    /// in-snapshot register order. Empty groups are dropped so the deck only shows
    /// sections that have registers. Surfaced to the grouped registers view.
    var groupedRegisters: [(group: DebuggerRegisterGroup, registers: [DebuggerRegisterSummary])] {
        var byGroup: [DebuggerRegisterGroup: [DebuggerRegisterSummary]] = [:]
        for register in session.registers {
            byGroup[register.group, default: []].append(register)
        }
        return DebuggerRegisterGroup.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { group in
                guard let registers = byGroup[group], !registers.isEmpty else { return nil }
                return (group: group, registers: registers)
            }
    }

    /// The grouped registers with their values re-rendered under the current
    /// `valueFormat`. Pure presentation over `groupedRegisters` — the underlying
    /// snapshot value is never re-read, only the same bits re-displayed — so the
    /// format picker issues no transport command. A value that carries no parseable
    /// numeric token (a purely symbolic register) is left as-is.
    /// The registers whose value changed between two snapshots, or nil when the register set is
    /// unchanged (the marks stay as they were). No registers: nothing is marked. A register seen
    /// for the first time is not marked.
    nonisolated static func changedRegisterNames(
        previous: [DebuggerRegisterSummary],
        next: [DebuggerRegisterSummary]
    ) -> Set<String>? {
        guard !next.isEmpty else { return [] }
        guard previous != next else { return nil }
        let before = Dictionary(previous.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        return Set(next.compactMap { register in
            guard let old = before[register.name], old != register.value else { return nil }
            return register.name
        })
    }

    var formattedGroupedRegisters: [(group: DebuggerRegisterGroup, registers: [DebuggerRegisterSummary])] {
        groupedRegisters.map { entry in
            (group: entry.group, registers: entry.registers.map(formatted(register:)))
        }
    }

    /// Re-renders one register's value string under the current `valueFormat`,
    /// width-aware: ARM64 `w`-registers and `s` SIMD lanes are 32-bit; everything
    /// else is treated as 64-bit. Hex preserves the snapshot's original text (which
    /// may carry an LLDB symbol annotation) verbatim.
    func formatted(register: DebuggerRegisterSummary) -> DebuggerRegisterSummary {
        var copy = register
        copy.value = DebuggerValueFormatter.reformat(
            value: register.value,
            bitWidth: Self.registerBitWidth(for: register.name),
            as: valueFormat
        )
        return copy
    }

    /// A memory region's preview bytes rendered under the current `valueFormat`.
    /// Memory is shown byte-granular, so hex / decimal / signed are per-byte (8-bit
    /// width); float has no meaningful single-byte interpretation, so it falls back
    /// to the region's canonical hex preview. Pure presentation over the already
    /// read bytes — no transport command is issued.
    func formattedMemoryPreview(for region: DebuggerMemorySummary) -> String {
        switch valueFormat {
        case .hex, .float:
            return region.previewText
        case .decimal, .signedDecimal:
            if region.previewBytes.isEmpty { return "No bytes" }
            return region.previewBytes.prefix(12)
                .map { DebuggerValueFormatter.format(bits: UInt64($0), bitWidth: 8, as: valueFormat) }
                .joined(separator: " ")
        }
    }

    /// The canonical hex value (the snapshot's original text) for the register with
    /// `name`, or `nil` when no such register is present. Used to seed the
    /// register-write field with a value the `register write` validator accepts even
    /// when the display format is decimal / signed / float.
    func hexValue(forRegisterNamed name: String) -> String? {
        session.registers.first { $0.name == name }?.value
    }

    /// The width, in bits, of a register by name. ARM64 `w0`–`w30` are the 32-bit
    /// views of the GPRs and `s0`–`s31` are the 32-bit single-precision SIMD lanes;
    /// every other register the panel reads (`x`/`v`/`pc`/`sp`/control) is 64-bit.
    static func registerBitWidth(for name: String) -> Int {
        let lowered = name.lowercased()
        guard let first = lowered.first else { return 64 }
        let rest = lowered.dropFirst()
        let restIsNumeric = !rest.isEmpty && rest.allSatisfy { $0.isNumber }
        if (first == "w" || first == "s"), restIsNumeric {
            return 32
        }
        return 64
    }

    /// The stopped process's recovered threads (parsed from the snapshot's
    /// backtrace), surfaced to the threads tab.
    var threads: [DebuggerThreadSummary] {
        session.threads
    }

    /// The stopped process's recovered call-stack frames, surfaced to the
    /// call-stack view. Innermost frame (`frame #0`) first.
    var frames: [DebuggerFrameSummary] {
        session.frames
    }

    /// The currently selected debugger thread, falling back to the first recovered
    /// thread when the backend does not mark one explicitly. This is presentation
    /// state only; transport requests still use their typed selection requests.
    var selectedThread: DebuggerThreadSummary? {
        session.threads.first(where: \.isSelected) ?? session.threads.first
    }

    /// The currently selected stack frame, resolved from `selectedFrameIndex`
    /// against the recovered frames. Defaults to the innermost frame when the
    /// selection is unset or out of range.
    var selectedFrame: DebuggerFrameSummary? {
        if let index = selectedFrameIndex,
           let frame = session.frames.first(where: { $0.index == index }) {
            return frame
        }
        return session.frames.first
    }

    /// The PC the listing should navigate to for the *selected* frame, or the live
    /// PC (innermost frame) when no explicit frame is selected. Non-nil only while
    /// paused at a live process, mirroring `currentProgramCounter`.
    var selectedFrameProgramCounter: UInt64? {
        guard session.liveProgramCounter != nil else { return nil }
        return selectedFrame?.address ?? session.liveProgramCounter
    }

    /// Selected-frame runtime PC translated only through the current exact WS-20 mapping.
    var selectedFrameWorkspaceProgramCounter: ImageAddress? {
        guard let address = selectedFrameProgramCounter else { return nil }
        return resolvedWorkspaceAddress(forRuntimeAddress: address)
    }

    /// Exact WS-23 identity for the currently selected stopped frame. Returns
    /// `nil` unless the accepted transport snapshot carries a stop coordinate,
    /// exact target authority, an explicitly selected thread, and selected frame
    /// that can be losslessly converted into inspection identity values. The
    /// display-only `selectedThread` fallback must not authorize inspection work.
    var currentInspectionCoordinate: DebuggerInspectionCoordinate? {
        guard let stop = session.transportStopCoordinate,
              let targetAuthority = session.transportTargetAuthority,
              let exactSelectedThread = session.threads.first(where: \.isSelected),
              let thread = DebuggerThreadIdentity(summary: exactSelectedThread),
              let selectedFrame,
              let frame = DebuggerFrameIdentity(thread: thread, summary: selectedFrame) else {
            return nil
        }
        return DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: targetAuthority,
            thread: thread,
            frame: frame
        )
    }

    /// Selected-frame runtime PC resolved to its exact current static workspace address,
    /// preserving the mapping key, runtime module instance, and workspace artifact coordinate
    /// needed by debugger source/debug-artifact freshness checks.
    var selectedFrameResolvedStaticAddress: DebuggerResolvedStaticAddress? {
        guard let address = selectedFrameProgramCounter,
              let projection = Self.validatedRuntimeMappingProjection(
                  runtimeMappingProjection,
                  for: session,
                  catalog: workspaceArtifactCatalog
              ) else {
            return nil
        }
        switch DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: address,
            in: projection,
            requiring: projection.key
        ) {
        case .resolved(let result):
            return result
        case .unresolved, .ambiguous:
            return nil
        }
    }

    /// The honest background wait-for-stop lifecycle state derived from the current
    /// session. `.waitingForStop` surfaces the "running, waiting to stop" affordance
    /// after a continue/step was issued; `.stopped` once the process halts again.
    var waitStopState: DebuggerWaitStopState {
        waitStopMachine.state
    }

    /// `true` while a run command (continue / step) is in flight and the UI should
    /// show a "running, waiting to stop" indicator rather than the stopped controls.
    var isWaitingForStop: Bool {
        waitStopMachine.state.isWaiting
    }

    /// The current program counter (top stack frame address) while the debugger is
    /// stopped at a live process, else `nil`. Bridged into the disassembly listing
    /// (via `WorkspaceStore.updateLiveProgramCounter`) to drive the live-PC row
    /// highlight + auto-scroll. Non-nil only while paused at a live process, so it
    /// clears the moment the process resumes, exits, or detaches. The derivation
    /// lives on `DebuggerSessionSnapshot.liveProgramCounter` so it stays pure and
    /// unit-testable without this view-model.
    var currentProgramCounter: UInt64? {
        session.liveProgramCounter
    }

    /// Live runtime PC translated before it crosses back into the workspace. Launches and arbitrary
    /// attaches are treated identically: a current exact mapping resolves; every other case abstains.
    var currentWorkspaceProgramCounter: ImageAddress? {
        guard let address = currentProgramCounter else { return nil }
        return resolvedWorkspaceAddress(forRuntimeAddress: address)
    }

    /// Installs the workspace's latest artifact authority without issuing a debugger request.
    /// A newer revision or same-revision owner replacement immediately revokes any projection
    /// that no longer names the exact binary, slot, artifact, and owner revision.
    func reconcileWorkspaceArtifactCatalog(_ catalog: DebuggerWorkspaceArtifactCatalog) {
        if let current = workspaceArtifactCatalog,
           catalog.revision < current.revision {
            return
        }
        workspaceArtifactCatalog = catalog
        runtimeMappingProjection = isRuntimeModuleAuthorityRevoked(for: session)
            ? nil
            : Self.derivedRuntimeMappingProjection(for: session, catalog: catalog)
        scheduleLogicalBreakpointResolution()
    }

    private func resolvedWorkspaceAddress(forRuntimeAddress address: UInt64) -> ImageAddress? {
        guard let projection = Self.validatedRuntimeMappingProjection(
            runtimeMappingProjection,
            for: session,
            catalog: workspaceArtifactCatalog
        ) else {
            return nil
        }
        switch DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: address,
            in: projection,
            requiring: projection.key
        ) {
        case .resolved(let result):
            return result.imageAddress
        case .unresolved, .ambiguous:
            return nil
        }
    }

    /// Resolves one image-qualified static workspace address to exactly one current runtime load
    /// instance. A missing/stale projection, replaced owner, unmapped address, or multiple current
    /// load instances abstains; Run to Cursor must never guess a runtime address.
    private func resolvedRuntimeAddress(
        forStaticAddress target: ImageAddress
    ) -> DebuggerResolvedRuntimeAddress? {
        guard let catalog = workspaceArtifactCatalog,
              let projection = Self.validatedRuntimeMappingProjection(
                  runtimeMappingProjection,
                  for: session,
                  catalog: catalog
              ) else {
            return nil
        }
        let coordinates = catalog.artifacts.compactMap { artifact -> DebuggerWorkspaceArtifactCoordinate? in
            guard artifact.slot == target.slot,
                  artifact.artifactIntegrityState == .verified,
                  let artifactIdentity = artifact.artifactIdentity else {
                return nil
            }
            return DebuggerWorkspaceArtifactCoordinate(
                binaryID: artifact.binaryID,
                slot: artifact.slot,
                artifactIdentity: artifactIdentity,
                ownerRevision: artifact.ownerRevision
            )
        }
        guard coordinates.count == 1 else { return nil }
        switch DebuggerRuntimeAddressTranslator.scalarRuntimeAddress(
            forStaticAddress: target,
            coordinate: coordinates[0],
            in: projection,
            requiring: projection.key
        ) {
        case .resolved(let result):
            return result
        case .unresolved, .ambiguous:
            return nil
        }
    }

    /// The breakpoint currently targeted for condition editing, resolved from the
    /// `breakpointEditAddressText` field against the session's breakpoint set.
    var editingBreakpoint: DebuggerBreakpoint? {
        guard let address = DebuggerAuthoringValidation.parseHexAddress(breakpointEditAddressText) else {
            return nil
        }
        return session.breakpoints.first { $0.address == address }
    }

    var canApplyBreakpointEdit: Bool {
        editingBreakpoint != nil
    }

    /// Loads an existing breakpoint's condition / ignore-count into the editor
    /// fields so the SwiftUI surface can stay a pure binding over these strings.
    func beginEditingBreakpoint(at address: UInt64) {
        breakpointEditAddressText = address.hexAddress
        guard let breakpoint = session.breakpoints.first(where: { $0.address == address }) else {
            breakpointConditionText = ""
            breakpointIgnoreCountText = ""
            return
        }
        breakpointConditionText = breakpoint.condition ?? ""
        breakpointIgnoreCountText = breakpoint.ignoreCount == 0 ? "" : String(breakpoint.ignoreCount)
    }

    var controlHelp: String {
        if capabilities.isBackendAvailable {
            return "Debugger control"
        }

        return capabilities.summary
    }

    // MARK: Launch configuration authoring helpers

    /// Appends a fresh empty environment row for the author to fill in.
    func addEnvironmentEntry() {
        launchEnvironmentEntries.append(DebuggerEnvironmentEntry())
    }

    /// Removes the identified environment row, always leaving at least one (empty)
    /// row so the editor never collapses to nothing.
    func removeEnvironmentEntry(id: DebuggerEnvironmentEntry.ID) {
        launchEnvironmentEntries.removeAll { $0.id == id }
        if launchEnvironmentEntries.isEmpty {
            launchEnvironmentEntries = [DebuggerEnvironmentEntry()]
        }
    }

    /// Parses the authored arguments / environment / working-directory fields into
    /// a normalized draft, or returns the rejection reason.
    func launchInvocationDraftResult() -> Result<DebuggerLaunchInvocationDraft, DebuggerAuthoringParseError> {
        DebuggerLaunchInvocationDraft.parse(
            argumentsText: launchArgumentsText,
            environmentEntries: launchEnvironmentEntries,
            workingDirectoryText: launchWorkingDirectoryText
        )
    }

    /// A short human-readable rejection reason for the authored launch inputs, or
    /// `nil` when they parse cleanly. Drives the editor's inline validation hint.
    var launchInvocationValidationMessage: String? {
        if case .failure(let error) = launchInvocationDraftResult() {
            return error.reason
        }
        return nil
    }

    var isLaunchInvocationValid: Bool {
        launchInvocationValidationMessage == nil
    }

    var targetPickerSnapshot: DebuggerTargetPickerSnapshot {
        let policy = attachPolicy
        let policySummary = DebuggerSignedTargetPolicySummary(
            capabilities: capabilities,
            attachPolicy: policy
        )
        let pidTarget = pidTargetDescriptor(
            policy: policy,
            policyDiagnostics: policySummary.diagnostics
        )
        let rows = [
            importedTargetSelectionDescriptor
        ]
        let fallbackID = rows.first?.id ?? ""
        let requestedID = selectedTargetID
        let resolvedSelectedID = requestedID.flatMap { id in
            rows.contains { $0.id == id } ? id : nil
        } ?? fallbackID

        return DebuggerTargetPickerSnapshot(
            rows: rows,
            selectedRowID: resolvedSelectedID,
            policySummary: policySummary,
            pidTarget: pidTarget
        )
    }

    var selectedTargetSummary: DebuggerSelectedTargetSummary {
        targetPickerSnapshot.selectedSummary
    }

    var canLaunchSelectedTarget: Bool {
        controlAvailability(for: .launch).isEnabled
    }

    var launchAdmissionDiagnostic: DebuggerLaunchAdmissionDiagnosticPresentation? {
        DebuggerLaunchAdmissionDiagnosticPresentation(capabilities: capabilities)
    }

    var selectedTargetControlHelp: String {
        controlAvailability(for: .launch).helpText
    }

    func controlAvailability(for action: DebuggerControlAction) -> DebuggerControlAvailability {
        guard isWorkspaceAdmissionOpen else {
            return DebuggerControlAvailability(action: action, isEnabled: false,
                disabledReason: workspaceAdmissionPending
                    ? "Waiting for the previous document's debugger session to retire."
                    : "This workspace debugger session has retired.")
        }
        switch action {
        case .launch:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: launchDisabledReason == nil,
                disabledReason: launchDisabledReason
            )
        case .attachProcess:
            return targetPickerSnapshot.pidTarget.attachAvailability
        case .continueExecution:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canContinue,
                disabledReason: canContinue ? nil : resumeControlQuarantineReason
                    ?? liveControlDisabledReason(
                    unavailablePrefix: "Continue unavailable",
                    stateReason: "Continue requires a paused live debug process."
                )
            )
        case .runToCursor:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canRunToCursor,
                disabledReason: canRunToCursor ? nil : resumeControlQuarantineReason
                    ?? liveControlDisabledReason(
                    unavailablePrefix: "Run to cursor unavailable",
                    stateReason: "Run to cursor requires a paused live debug process."
                )
            )
        case .stepOver:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canStepOver,
                disabledReason: canStepOver ? nil : resumeControlQuarantineReason
                    ?? liveControlDisabledReason(
                    unavailablePrefix: "Step over unavailable",
                    stateReason: "Step over requires a paused live debug process."
                )
            )
        case .stepInto:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canStepInto,
                disabledReason: canStepInto ? nil : resumeControlQuarantineReason
                    ?? liveControlDisabledReason(
                    unavailablePrefix: "Step into unavailable",
                    stateReason: "Step into requires a paused live debug process."
                )
            )
        case .stepOut:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canStepOut,
                disabledReason: canStepOut ? nil : resumeControlQuarantineReason
                    ?? liveControlDisabledReason(
                    unavailablePrefix: "Step out unavailable",
                    stateReason: "Step out requires a paused live debug process."
                )
            )
        case .pause:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canPause,
                disabledReason: canPause ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Pause unavailable",
                    stateReason: "Pause requires a running live debug process."
                )
            )
        case .detach:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canDetach,
                disabledReason: canDetach ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Detach unavailable",
                    stateReason: "Detach requires an attached live debug process."
                )
            )
        case .terminate:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canTerminate,
                disabledReason: canTerminate ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Terminate unavailable",
                    stateReason: "Terminate requires a live debug process."
                )
            )
        case .refreshSnapshot:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canRefreshSnapshot,
                disabledReason: canRefreshSnapshot ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Snapshot refresh unavailable",
                    stateReason: "Snapshot refresh requires a paused live debug process."
                )
            )
        case .writeRegister:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canWriteRegister,
                disabledReason: canWriteRegister ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Register write unavailable",
                    stateReason: "Register write requires a paused live debug process."
                )
            )
        case .readMemory:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canReadMemory,
                disabledReason: canReadMemory ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Memory read unavailable",
                    stateReason: "Memory read requires a paused live debug process."
                )
            )
        case .writeMemory:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canWriteMemory,
                disabledReason: canWriteMemory ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Memory write unavailable",
                    stateReason: "Memory write requires a paused live debug process."
                )
            )
        case .evaluateExpression:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canEvaluateExpression,
                disabledReason: canEvaluateExpression ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Expression evaluation unavailable",
                    stateReason: "Expression evaluation requires a paused live debug process."
                )
            )
        case .selectThread:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canSelectThread,
                disabledReason: canSelectThread ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Thread selection unavailable",
                    stateReason: "Thread selection requires a paused live debug process."
                )
            )
        case .selectFrame:
            return DebuggerControlAvailability(
                action: action,
                isEnabled: canSelectFrame,
                disabledReason: canSelectFrame ? nil : liveControlDisabledReason(
                    unavailablePrefix: "Frame selection unavailable",
                    stateReason: "Frame selection requires a paused live debug process."
                )
            )
        }
    }

    func importedTargetDescriptor(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) -> DebuggerTargetSelectionDescriptor {
        DebuggerTargetSelectionDescriptor.importedTarget(
            configuration: importedLaunchConfiguration(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            ),
            launchSupport: capabilities.launchSupport,
            requiresExecutableFile: true
        )
    }

    func importedLaunchConfiguration(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) -> DebuggerLaunchConfiguration {
        DebuggerLaunchConfiguration.importedTarget(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    func processAttachDescriptor(_ request: DebuggerAttachRequest) -> DebuggerTargetSelectionDescriptor {
        DebuggerTargetSelectionDescriptor.processAttach(
            request: request,
            policy: attachPolicy
        )
    }

    /// Compatibility binder for callers that have only a target descriptor. It can select the next
    /// launch target, but deliberately carries no slot/breakpoint ownership proof.
    func bindWorkspaceLaunchTarget(_ target: DebuggerLaunchTargetDescriptor?) {
        candidateWorkspaceInputsBySlot.removeAll()
        focusedLaunchCandidate = nil
        workspaceInput = nil
        workspaceLaunchTarget = target
        guard let target else { return }
        importedExecutablePath = target.executablePath
    }

    /// Installs complete document-owned debugger evidence without consulting editor focus.
    func reconcileWorkspaceAuthority(_ authority: DebuggerWorkspaceAuthority) {
        guard authority.isStructurallyValid else {
            rejectWorkspaceIdentity("Debugger workspace authority is structurally inconsistent.")
            return
        }
        if let current = workspaceAuthority {
            guard authority.workspaceID == current.workspaceID,
                  authority.artifactCatalog.revision >= current.artifactCatalog.revision,
                  authority.logicalBreakpointCatalogCoordinate.revision
                    >= current.logicalBreakpointCatalogCoordinate.revision,
                  authority.breakpointResolutionCatalogCoordinate.revision
                    >= current.breakpointResolutionCatalogCoordinate.revision else {
                return
            }
            guard authority.artifactCatalog.revision != current.artifactCatalog.revision
                    || authority.artifactCatalog == current.artifactCatalog,
                  authority.logicalBreakpointCatalogCoordinate
                    != current.logicalBreakpointCatalogCoordinate
                    || (authority.logicalBreakpointCatalog == current.logicalBreakpointCatalog
                        && authority.logicalBreakpointCatalogAvailability
                            == current.logicalBreakpointCatalogAvailability),
                  authority.breakpointResolutionCatalogCoordinate
                    != current.breakpointResolutionCatalogCoordinate
                    || authority.breakpointResolutionCatalog
                        == current.breakpointResolutionCatalog else {
                rejectWorkspaceIdentity("Debugger workspace authority reused a revision.")
                return
            }
        }

        workspaceAuthority = authority
        reconcileWorkspaceArtifactCatalog(authority.artifactCatalog)
        scheduleLogicalBreakpointResolution()

        if let focusedLaunchCandidate {
            reconcileWorkspaceCandidate(
                DebuggerWorkspaceInput(
                    authority: authority,
                    candidate: focusedLaunchCandidate
                )
            )
        }

        guard session.hasLiveProcessSession,
              let active = latestAcceptedActiveWorkspaceInput ?? activeWorkspaceInput else {
            return
        }
        let refreshed = DebuggerWorkspaceInput(
            authority: authority,
            candidate: active.focusedLaunchCandidate
        )
        guard prepareActiveWorkspaceReconciliation(refreshed) else { return }
        Task { @MainActor [weak self] in
            await self?.reconcileActiveWorkspaceInput(refreshed)
        }
    }

    /// Installs only the optional focused next-launch proposal. Clearing the candidate for an
    /// arbitrary attach intentionally retains document-wide workspace authority.
    func reconcileFocusedLaunchCandidate(_ candidate: DebuggerFocusedLaunchCandidate?) {
        guard let candidate else {
            reconcileWorkspaceCandidate(nil)
            return
        }
        guard let workspaceAuthority else {
            focusedLaunchCandidate = candidate
            workspaceLaunchTarget = candidate.launchTarget
            importedExecutablePath = candidate.launchTarget.executablePath
            return
        }
        reconcileWorkspaceCandidate(
            DebuggerWorkspaceInput(authority: workspaceAuthority, candidate: candidate)
        )
    }

    /// Reconciles one complete focused candidate synchronously. While idle its gutter set seeds the
    /// next launch; while live it updates only the candidate and cannot retarget or rewrite the
    /// active process. Direct main-actor delivery makes caller order authoritative, while the
    /// per-slot baseline rejects an older or value-mismatched reuse of an already observed revision.
    func reconcileWorkspaceCandidate(_ input: DebuggerWorkspaceInput?) {
        let previousCandidate = workspaceInput
        if let input, let current = candidateWorkspaceInputsBySlot[input.imageSlot] {
            guard input.breakpointRevision >= current.breakpointRevision else { return }
            if input.breakpointRevision == current.breakpointRevision,
               input != current,
               !isSameRevisionLaunchTargetRefresh(input, from: current) {
                rejectWorkspaceIdentity("Debugger candidate reused a stale workspace revision.")
                return
            }
        }

        focusedLaunchCandidate = input?.focusedLaunchCandidate
        if let input {
            candidateWorkspaceInputsBySlot[input.imageSlot] = input
        }
        workspaceInput = input
        workspaceLaunchTarget = input?.launchTarget
        if let input {
            importedExecutablePath = input.launchTarget.executablePath
        } else {
            importedExecutablePath = ""
            guard session.processState.canLaunchNewProcess else { return }
            candidateWorkspaceInputsBySlot.removeAll()
            session.replaceBreakpoints([])
            lastError = nil
            return
        }
        guard let input else { return }

        if session.hasLiveProcessSession,
           activeWorkspaceImageSlot == input.imageSlot,
           let activeWorkspaceLaunchTarget,
           sameWorkspaceOwner(input.launchTarget, activeWorkspaceLaunchTarget) {
            // This synchronous candidate seam is invoked directly by the editor/store change
            // before its untracked active-reconcile Task is scheduled. Latch here so an immediate
            // Continue/Step/Run-to-Cursor cannot race ahead with the prior binding/actions.
            _ = prepareActiveWorkspaceReconciliation(input)
        }

        guard session.processState.canLaunchNewProcess else { return }
        let preservesExistingMetadata = previousCandidate.map {
            sameWorkspaceOwner($0.launchTarget, input.launchTarget)
        } ?? false
        let reconciled = reconciledBreakpoints(
            for: input.gutterBreakpointAddresses,
            preservingExistingMetadata: preservesExistingMetadata
        )
        session.replaceBreakpoints(reconciled)
        lastError = nil
    }

    /// Synchronous preflight for store callbacks that will schedule candidate-specific presentation
    /// reconciliation in an untracked Task. It validates the immutable active owner and monotonic
    /// workspace input; document-wide logical-breakpoint authority is reconciled independently.
    @discardableResult
    func prepareActiveWorkspaceReconciliation(_ input: DebuggerWorkspaceInput?) -> Bool {
        guard session.hasLiveProcessSession else { return false }
        guard let input else { return true }
        guard let activeSlot = activeWorkspaceImageSlot,
              let immutableActiveTarget = activeWorkspaceLaunchTarget,
              input.imageSlot == activeSlot,
              sameWorkspaceOwner(input.launchTarget, immutableActiveTarget) else {
            return false
        }
        if let current = latestAcceptedActiveWorkspaceInput ?? activeWorkspaceInput {
            guard input.breakpointRevision >= current.breakpointRevision else { return false }
            if input.breakpointRevision == current.breakpointRevision,
               input != current,
               !isSameRevisionLaunchTargetRefresh(input, from: current) {
                return false
            }
        }
        return true
    }

    /// Reconciles a complete explicit-slot reread into local authoring state only when it names the
    /// immutable launch owner. The highest accepted revision is retained across actor reentrancy,
    /// and one single-flight drain coalesces pending work so an older input cannot supersede it.
    func reconcileActiveWorkspaceInput(_ input: DebuggerWorkspaceInput?) async {
        guard session.hasLiveProcessSession else { return }
        guard let input else {
            if session.hasLiveProcessSession, activeWorkspaceImageSlot != nil {
                activePresentationBreakpointsRequireConvergence = true
            }
            activeReconciliationToken = UUID()
            latestAcceptedActiveWorkspaceInput = nil
            pendingActiveWorkspaceInput = nil
            activeWorkspaceInputBeingApplied = nil
            if let activeWorkspaceImageSlot {
                candidateWorkspaceInputsBySlot[activeWorkspaceImageSlot] = nil
            }
            activeWorkspaceInput = nil
            return
        }
        guard let activeSlot = activeWorkspaceImageSlot,
              let immutableActiveTarget = activeWorkspaceLaunchTarget,
              input.imageSlot == activeSlot,
              sameWorkspaceOwner(input.launchTarget, immutableActiveTarget) else {
            rejectWorkspaceIdentity("Debugger breakpoint update does not belong to the active workspace image.")
            return
        }

        if let current = latestAcceptedActiveWorkspaceInput ?? activeWorkspaceInput {
            guard input.breakpointRevision >= current.breakpointRevision else { return }
            if input.breakpointRevision == current.breakpointRevision {
                guard input == current || isSameRevisionLaunchTargetRefresh(input, from: current) else {
                    rejectWorkspaceIdentity("Debugger breakpoint update reused a stale workspace revision.")
                    return
                }
                latestAcceptedActiveWorkspaceInput = input
                if activeWorkspaceInput == input {
                    lastError = nil
                    return
                }
                guard activeWorkspaceInputBeingApplied != input,
                      pendingActiveWorkspaceInput != input else { return }
            }
        }

        latestAcceptedActiveWorkspaceInput = input
        pendingActiveWorkspaceInput = input
        await drainActiveWorkspaceInputs()
    }

    private func drainActiveWorkspaceInputs() async {
        guard !isDrainingActiveWorkspaceInputs else { return }
        isDrainingActiveWorkspaceInputs = true
        defer {
            activeWorkspaceInputBeingApplied = nil
            isDrainingActiveWorkspaceInputs = false
        }

        while let input = pendingActiveWorkspaceInput {
            pendingActiveWorkspaceInput = nil
            activeWorkspaceInputBeingApplied = input
            await applyActiveWorkspaceInput(input)
            activeWorkspaceInputBeingApplied = nil
        }
    }

    private func applyActiveWorkspaceInput(_ input: DebuggerWorkspaceInput) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard let immutableActiveTarget = activeWorkspaceLaunchTarget,
              activeWorkspaceImageSlot == input.imageSlot,
              sameWorkspaceOwner(input.launchTarget, immutableActiveTarget),
              session.hasLiveProcessSession else { return }

        let reconciled = reconciledBreakpoints(for: input.gutterBreakpointAddresses)
        if reconciled != session.breakpoints || activePresentationBreakpointsRequireConvergence {
            // Compatibility projection only. Persistent LLDB mutation is owned exclusively by the
            // typed logical-binding path and never receives these static workspace addresses.
            session.replaceBreakpoints(reconciled)
        }

        activeWorkspaceInput = input
        activePresentationBreakpointsRequireConvergence = false
        lastError = nil
    }

    private func forwardLogicalBreakpointReconciliation(
        _ authority: DebuggerWorkspaceAuthority
    ) async {
        guard isWorkspaceAdmissionOpen else { return }
        if authority.logicalBreakpointCatalogAvailability == .unavailable {
            quarantineLiveSessionIfLogicalBreakpointOwnershipIsNotProvenClear()
            return
        }
        guard session.transportBreakpointBindingState != nil else {
            return
        }
        guard let projection = Self.validatedRuntimeMappingProjection(
            runtimeMappingProjection,
            for: session,
            catalog: authority.artifactCatalog
        ) else {
            quarantineResumeControlsForUnresolvedLogicalBreakpoints(authority)
            return
        }
        guard let reconcileRequest = Self.logicalBreakpointReconcileRequest(
            for: authority,
            runtimeProjection: projection
        ) else {
            quarantineResumeControlsForUnresolvedLogicalBreakpoints(authority)
            return
        }
        if session.transportBreakpointBindingState?.resolutionObservation
            == reconcileRequest.observation {
            lastForwardedLogicalBreakpointReconcileRequest = reconcileRequest
            clearResumeControlQuarantineIfExplicitlySettled(reconcileRequest)
            return
        }
        guard lastForwardedLogicalBreakpointReconcileRequest != reconcileRequest else { return }

        let request = logicalBreakpointSnapshotAcceptanceGate.beginRequest(for: session)
        do {
            var next = try await client.reconcileLogicalBreakpoints(
                reconcileRequest,
                from: request.requestSnapshot
            )
            // The reducer snapshot deliberately projects only legacy transport breakpoint rows.
            // Preserve the workspace-derived gutter cache locally; it is presentation, not input
            // to either the binding reducer or persistent LLDB backend.
            next.replaceBreakpoints(request.requestSnapshot.breakpoints)
            guard installAcceptedLogicalBreakpointSnapshot(next, from: request) else {
                requeueLatestWorkspaceAuthorityForLogicalBreakpointConvergence()
                return
            }
            lastForwardedLogicalBreakpointReconcileRequest = reconcileRequest
            clearResumeControlQuarantineIfExplicitlySettled(reconcileRequest)
        } catch {
        guard isWorkspaceAdmissionOpen else { return }
            guard logicalBreakpointSnapshotAcceptanceGate.accept(
                request,
                currentSnapshot: session
            ) else {
                requeueLatestWorkspaceAuthorityForLogicalBreakpointConvergence()
                return
            }
            applyClientError(error)
        }
    }

    private func quarantineResumeControlsForUnresolvedLogicalBreakpoints(
        _ authority: DebuggerWorkspaceAuthority
    ) {
        guard authority.logicalBreakpointCatalogAvailability == .available,
              authority.logicalBreakpointCatalog.specifications.contains(where: \.enabled) else {
            return
        }
        let message = "Resume controls are disabled because enabled saved logical breakpoints could not be resolved against the current runtime modules."
        resumeControlQuarantineReason = message
        lastError = message
    }

    /// Latches at the synchronous document-authority observation seam, before the logical reconcile
    /// task can suspend. This closes the edit/delete/disable-then-immediate-resume window without
    /// depending on an optional focused launch candidate.
    private func quarantineResumeControlsIfLogicalBreakpointConvergenceIsPending(
        for authority: DebuggerWorkspaceAuthority
    ) {
        guard let state = session.transportBreakpointBindingState else { return }
        if authority.logicalBreakpointCatalogAvailability == .unavailable {
            if Self.logicalBreakpointOwnershipMayRemainArmed(state) {
                resumeControlQuarantineReason = "Resume controls are disabled because the saved logical-breakpoint catalog is unavailable and backend breakpoint cleanup is unproven."
            }
            return
        }
        guard state.desiredCatalogCoordinate != authority.logicalBreakpointCatalogCoordinate
                || state.resolutionObservation?.logicalCatalogCoordinate
                    != authority.logicalBreakpointCatalogCoordinate
                || state.resolutionObservation?.resolutionCatalogCoordinate
                    != authority.breakpointResolutionCatalogCoordinate else {
            return
        }
        resumeControlQuarantineReason = "Resume controls are disabled while the newest saved logical-breakpoint changes converge with the live debugger."
    }

    /// A client return alone is not convergence. Only accepted reducer authority that exactly
    /// echoes the new observation, has no in-flight plan, and proves a stable bound/unbound backend
    /// may reopen resume-capable controls.
    private func clearResumeControlQuarantineIfExplicitlySettled(
        _ request: DebuggerLogicalBreakpointReconcileRequest
    ) {
        guard let authority = workspaceAuthority,
              let projection = Self.validatedRuntimeMappingProjection(
                  runtimeMappingProjection,
                  for: session,
                  catalog: authority.artifactCatalog
              ),
              Self.logicalBreakpointReconcileRequest(
                  for: authority,
                  runtimeProjection: projection
              ) == request,
              let state = session.transportBreakpointBindingState,
              state.desiredCatalogCoordinate == request.observation.logicalCatalogCoordinate,
              state.resolutionObservation == request.observation,
              state.pendingPlan == nil else {
            return
        }
        switch state.backendState {
        case .unbound, .bound:
            resumeControlQuarantineReason = nil
        case .applying, .armedUnobserved, .failClosed:
            break
        }
    }

    /// An unavailable durable catalog carries no authority to synthesize an empty replacement
    /// catalog or selectively delete backend breakpoints. View-model snapshots are not reducer-
    /// correlated origin proof, so this layer must not choose terminate versus detach. Keep every
    /// live target quarantined until controller-owned recovery performs that origin-aware action.
    private func quarantineLiveSessionIfLogicalBreakpointOwnershipIsNotProvenClear() {
        guard let bindingState = session.transportBreakpointBindingState,
              Self.logicalBreakpointOwnershipMayRemainArmed(bindingState) else {
            return
        }

        let quarantineMessage = "Resume controls are disabled because the saved logical-breakpoint catalog is unavailable and backend breakpoint cleanup is unproven."
        resumeControlQuarantineReason = quarantineMessage
        if let authority = session.transportTargetAuthority,
           case .attached = authority.origin {
            presentResumeControlQuarantine(
                "\(quarantineMessage) This session was attached, so MacScope will not terminate the target; detach recovery is required."
            )
            return
        }
        presentResumeControlQuarantine(
            "\(quarantineMessage) Automatic target commands are disabled until origin-aware debugger recovery is available."
        )
    }

    private static func logicalBreakpointOwnershipMayRemainArmed(
        _ state: DebuggerBreakpointBindingReducerSnapshot
    ) -> Bool {
        guard state.ownedLocations.isEmpty, state.pendingPlan == nil else { return true }
        if case .unbound = state.backendState { return false }
        return true
    }

    private static func logicalBreakpointReconcileRequest(
        for authority: DebuggerWorkspaceAuthority,
        runtimeProjection: DebuggerRuntimeMappingProjection
    ) -> DebuggerLogicalBreakpointReconcileRequest? {
        guard authority.logicalBreakpointCatalogAvailability == .available else { return nil }
        let catalog = authority.logicalBreakpointCatalog
        let results = DebuggerLogicalBreakpointResolver.resolve(
            catalog: catalog,
            coordinate: authority.logicalBreakpointCatalogCoordinate,
            resolutionCatalog: authority.breakpointResolutionCatalog,
            requiringResolutionCoordinate: authority.breakpointResolutionCatalogCoordinate,
            runtimeProjection: runtimeProjection,
            requiringMappingKey: runtimeProjection.key
        )
        let expected = catalog.specifications.map {
            DebuggerLogicalBreakpointResolutionExpectation(
                logicalID: $0.id,
                specificationRevision: $0.revision
            )
        }
        guard let observation = DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: authority.logicalBreakpointCatalogCoordinate,
            resolutionCatalogCoordinate: authority.breakpointResolutionCatalogCoordinate,
            mappingKey: runtimeProjection.key,
            expectedSpecifications: expected,
            results: results
        ) else { return nil }
        return try? DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: authority.logicalBreakpointCatalogAvailability,
            catalog: catalog,
            observation: observation
        )
    }

    private func scheduleLogicalBreakpointResolution() {
        guard session.transportBreakpointBindingState != nil,
              session.hasLiveProcessSession,
              let authority = workspaceAuthority else {
            return
        }
        if authority.logicalBreakpointCatalogAvailability == .available,
           session.transportStopCoordinate == nil {
            return
        }
        quarantineResumeControlsIfLogicalBreakpointConvergenceIsPending(for: authority)
        guard pendingLogicalBreakpointWorkspaceAuthority != authority,
              logicalBreakpointWorkspaceAuthorityBeingApplied != authority else {
            return
        }
        pendingLogicalBreakpointWorkspaceAuthority = authority
        Task { @MainActor [weak self] in
            await self?.drainLogicalBreakpointWorkspaceAuthorities()
        }
    }

    private func drainLogicalBreakpointWorkspaceAuthorities() async {
        guard !isDrainingLogicalBreakpointWorkspaceAuthorities else { return }
        isDrainingLogicalBreakpointWorkspaceAuthorities = true
        defer {
            logicalBreakpointWorkspaceAuthorityBeingApplied = nil
            isDrainingLogicalBreakpointWorkspaceAuthorities = false
        }

        while let authority = pendingLogicalBreakpointWorkspaceAuthority {
            pendingLogicalBreakpointWorkspaceAuthority = nil
            logicalBreakpointWorkspaceAuthorityBeingApplied = authority
            await forwardLogicalBreakpointReconciliation(authority)
            logicalBreakpointWorkspaceAuthorityBeingApplied = nil
        }
    }

    /// Retains the latest document authority after a stale completion. Logical breakpoint ownership
    /// is document-wide, so the corrective write must not depend on editor focus or a launch owner.
    private func requeueLatestWorkspaceAuthorityForLogicalBreakpointConvergence() {
        guard session.hasLiveProcessSession,
              let workspaceAuthority else {
            return
        }
        pendingLogicalBreakpointWorkspaceAuthority = workspaceAuthority
    }

    /// Store-side revision generation rollover invalidates every pending debugger apply before a
    /// numeric revision can be reused. Ownership remains immutable; the next explicit reread seeds
    /// a fresh active revision baseline.
    func invalidateWorkspaceReconciliationEpochs() {
        if session.hasLiveProcessSession, activeWorkspaceImageSlot != nil {
            activePresentationBreakpointsRequireConvergence = true
        }
        candidateWorkspaceInputsBySlot.removeAll()
        workspaceOwnershipEpoch = UUID()
        activeReconciliationToken = UUID()
        latestAcceptedActiveWorkspaceInput = nil
        pendingActiveWorkspaceInput = nil
        activeWorkspaceInputBeingApplied = nil
        activeWorkspaceInput = nil
    }

    func launchSelectedTarget() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard let selectedTarget = targetPickerSnapshot.selectedRow else {
            refusePreflight(DebuggerClientError.invalidConfiguration("No debugger target is selected."))
            return
        }

        guard selectedTarget.policy.isEnabled else {
            refusePreflight(DebuggerClientError.invalidConfiguration(selectedTarget.policy.displayText))
            return
        }

        guard selectedTarget.kind == .importedTarget else {
            refusePreflight(DebuggerClientError.unsupportedOperation(selectedTarget.detail))
            return
        }

        let draft: DebuggerLaunchInvocationDraft
        switch launchInvocationDraftResult() {
        case .success(let value):
            draft = value
        case .failure(let error):
            refusePreflight(DebuggerClientError.invalidConfiguration(error.reason))
            return
        }

        let configuration = draft.applied(to: importedLaunchConfiguration(for: selectedTarget))
        let launchInput = workspaceInput.flatMap { input in
            input.launchTarget == workspaceLaunchTarget ? input : nil
        }
        await launch(
            configuration: configuration,
            workspaceInput: launchInput,
            workspaceTarget: workspaceLaunchTarget
        )
    }

    var lastCommandRun: DebuggerCommandRunSummary? {
        session.lastCommandRun
    }

    var commandRunStatus: String? {
        session.lastCommandRun?.statusText
    }

    var commandStandardOutput: String {
        session.lastCommandRun?.standardOutput ?? ""
    }

    var commandStandardError: String {
        session.lastCommandRun?.standardError ?? ""
    }

    func launch(configuration: DebuggerLaunchConfiguration? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        await launch(
            configuration: configuration,
            workspaceInput: nil,
            workspaceTarget: nil
        )
    }

    private func launch(
        configuration: DebuggerLaunchConfiguration?,
        workspaceInput launchInput: DebuggerWorkspaceInput?,
        workspaceTarget launchTarget: DebuggerLaunchTargetDescriptor?
    ) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.launchSupport.isSupported else {
            applyUnavailable("Launch unavailable: \(capabilities.launchSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard !refuseIfSessionStartInFlight(attach: false) else { return }

        guard session.processState.canLaunchNewProcess else {
            refusePreflight(DebuggerClientError.invalidState("Cannot launch while the debugger is \(session.processState.displayTitle.lowercased())."))
            return
        }

        let startToken = beginSessionStart(attach: false)
        defer { endSessionStart(startToken) }
        let previousProcessState = session.processState
        let previousBackendState = session.backendState
        clearActiveWorkspaceOwnership()
        let launchOwnershipEpoch = workspaceOwnershipEpoch
        var config = configuration ?? DebuggerLaunchConfiguration(executablePath: "")
        let localBreakpoints = session.breakpoints
        // No stopped runtime inventory exists before launch. Static workspace addresses therefore
        // cannot be bound safely at this boundary; WS-21 owns post-stop transient bindings.
        config.initialBreakpoints = []
        let startingState = DebuggerProcessState.launching(targetPath: config.executablePath)
        session.processState = startingState
        session.backendState = .launching(targetPath: config.executablePath)
        session.statusMessage = "Launching \(URL(fileURLWithPath: config.executablePath).lastPathComponent)."
        invalidateWatchEvaluations()
        let request = snapshotAcceptanceGate.beginNewSessionRequest(for: session)

        do {
            let next = try await client.launch(config)
            guard installAcceptedSnapshot(next, from: request) else {
                settleUnacceptedSessionStart(
                    startingState: startingState,
                    previousProcessState: previousProcessState,
                    previousBackendState: previousBackendState,
                    message: "Launch of \(URL(fileURLWithPath: config.executablePath).lastPathComponent) did not complete: its result was superseded. The debugger is idle.",
                    isAttach: false
                )
                return
            }
            activePresentationBreakpointsRequireConvergence = false
            var latestWorkspaceInput: DebuggerWorkspaceInput?
            if session.hasLiveProcessSession {
                if let launchInput,
                   workspaceOwnershipEpoch == launchOwnershipEpoch,
                   let latestInput = candidateWorkspaceInputsBySlot[launchInput.imageSlot],
                   latestInput.breakpointRevision >= launchInput.breakpointRevision,
                   sameWorkspaceOwner(latestInput.launchTarget, launchInput.launchTarget) {
                    activeWorkspaceImageSlot = launchInput.imageSlot
                    activeWorkspaceInput = launchInput
                    latestAcceptedActiveWorkspaceInput = launchInput
                    activeWorkspaceLaunchTarget = launchInput.launchTarget
                    latestWorkspaceInput = latestInput
                } else {
                    activeWorkspaceImageSlot = nil
                    activeWorkspaceInput = nil
                    latestAcceptedActiveWorkspaceInput = nil
                    activeWorkspaceLaunchTarget = launchTarget
                }
            } else {
                clearActiveWorkspaceOwnership()
            }
            session.replaceBreakpoints(
                latestWorkspaceInput.map {
                    reconciledBreakpoints(for: $0.gutterBreakpointAddresses)
                } ?? localBreakpoints
            )
            // A fresh launch replaces the session: clear any stale frame selection
            // and reset the wait-stop lifecycle to the launched snapshot's state.
            selectedFrameIndex = nil
            waitStopMachine.reset(to: session)
            if let latestWorkspaceInput {
                // The launch stop and its freshly collected runtime mapping are new binding
                // authority even when durable workspace input itself did not change.
                pendingActiveWorkspaceInput = latestWorkspaceInput
                await drainActiveWorkspaceInputs()
            }
            // Launch completion preserves the prior synchronous contract for logical breakpoint
            // convergence, but consumes document authority rather than the optional launch candidate.
            await drainLogicalBreakpointWorkspaceAuthorities()
            // The start itself is settled; a long run-until-stop observation is not a start.
            endSessionStart(startToken)
            if case .running = session.processState {
                await observeRunningProcessUntilResolved()
            }
        } catch {
            if !acceptLaunchClientError(
                error,
                from: request,
                previousProcessState: previousProcessState
            ) {
                settleUnacceptedSessionStart(
                    startingState: startingState,
                    previousProcessState: previousProcessState,
                    previousBackendState: previousBackendState,
                    message: "Launch failed: \(error.localizedDescription)",
                    isAttach: false
                )
            }
        }
    }

    func continueExecution(correlationID: UUID? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Continue unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canContinueLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Continue requires a paused live debug process."))
            return
        }

        await runAwaitingStop(.resume, correlationID: correlationID) { snapshot in
            try await client.continueExecution(from: snapshot)
        }
    }

    /// Runs the stopped target until it reaches `address` (the disassembly cursor)
    /// by setting a temporary one-shot breakpoint there and continuing; the backend
    /// removes the temp breakpoint when it is hit or when the process otherwise
    /// stops. Gated to a paused live session, mirroring `continueExecution`; the
    /// user's own breakpoint set is never mutated.
    func runToCursor(to address: UInt64) async {
        guard isWorkspaceAdmissionOpen else { return }
        _ = address
        rejectWorkspaceIdentity(
            "Run to Cursor requires an image-qualified address and current runtime mapping."
        )
    }

    /// Exact workspace entry point. A colliding bare address is accepted only when its slot is the
    /// immutable owner captured by the live launch.
    func runToCursor(to target: ImageAddress) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard activeWorkspaceOwnerIsCurrent,
              let activeSlot = activeWorkspaceImageSlot,
              target.slot == activeSlot else {
            rejectWorkspaceIdentity("Run to Cursor requires a selection in the active workspace image.")
            return
        }
        guard let resolved = resolvedRuntimeAddress(forStaticAddress: target) else {
            rejectWorkspaceIdentity(
                "Run to Cursor is unavailable because the selected address has no unique current runtime mapping."
            )
            return
        }
        await runToCursorValidated(to: resolved)
    }

    private func runToCursorValidated(to resolved: DebuggerResolvedRuntimeAddress) async {
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Run to cursor unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canRunToCursorLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Run to cursor requires a paused live debug process."))
            return
        }

        guard resolvedRuntimeAddress(forStaticAddress: resolved.imageAddress) == resolved else {
            rejectWorkspaceIdentity("Run to Cursor runtime mapping changed before the request was issued.")
            return
        }

        guard let request = currentRunToCursorRequest(for: resolved) else {
            rejectWorkspaceIdentity(
                "Run to Cursor runtime authority changed before the request was issued."
            )
            return
        }
        await runAwaitingStop(.resume) { snapshot in
            try await client.runToCursor(request, from: snapshot)
        }
    }

    /// Derives LLDB's StopID only from the exact available transport inventory that authored the
    /// resolved projection. Workspace correlation cannot mint, repair, or substitute this value.
    private func currentRunToCursorRequest(
        for resolved: DebuggerResolvedRuntimeAddress
    ) -> DebuggerRunToCursorRequest? {
        guard let stop = session.transportStopCoordinate,
              let processID = session.liveProcessID,
              let authorityRevision = session.transportRuntimeModuleAuthorityRevision,
              case .available(let inventory) = session.transportRuntimeModuleAuthority,
              inventory.observedStopID > 0,
              inventory.stop == stop,
              inventory.processID == processID,
              resolved.projectionKey == DebuggerRuntimeMappingProjectionKey(
                  stopCoordinate: stop,
                  observedPID: processID,
                  authorityRevision: authorityRevision,
                  inventoryRevision: inventory.revision,
                  workspaceCatalogRevision: resolved.projectionKey.workspaceCatalogRevision
              ),
              resolved.moduleInstanceID.processID == processID,
              resolved.moduleInstanceID.stop == stop,
              resolved.moduleInstanceID.inventoryRevision == inventory.revision,
              inventory.modules.contains(where: { $0.id == resolved.moduleInstanceID }) else {
            return nil
        }
        return try? DebuggerRunToCursorRequest(
            resolvedAddress: resolved,
            observedStopID: inventory.observedStopID
        )
    }

    func stepOver(correlationID: UUID? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Step over unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canStepOverLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Step over requires a paused live debug process."))
            return
        }

        await runAwaitingStop(.stepOver, correlationID: correlationID) { snapshot in
            try await client.stepOver(from: snapshot)
        }
    }

    func stepInto(correlationID: UUID? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Step into unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canStepIntoLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Step into requires a paused live debug process."))
            return
        }

        await runAwaitingStop(.stepInto, correlationID: correlationID) { snapshot in
            try await client.stepInto(from: snapshot)
        }
    }

    func stepOut(correlationID: UUID? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Step out unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canStepOutLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Step out requires a paused live debug process."))
            return
        }

        await runAwaitingStop(.stepOut, correlationID: correlationID) { snapshot in
            try await client.stepOut(from: snapshot)
        }
    }

    func pause(correlationID: UUID? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Pause unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canPauseLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Pause requires a running live debug process."))
            return
        }

        await applyClientResult(controlledRuntimeAction: .pause, correlationID: correlationID) { snapshot in
            try await client.pause(from: snapshot)
        }
    }

    func detach() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Detach unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canDetachLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Detach requires an attached live debug process."))
            return
        }

        await applyClientResult { snapshot in
            try await client.detach(from: snapshot)
        }
    }

    func terminate() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Terminate unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canTerminateLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Terminate requires a live debug process."))
            return
        }

        await applyClientResult { snapshot in
            try await client.terminate(from: snapshot)
        }
    }

    func refreshSnapshot(correlationID: UUID? = nil) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Snapshot refresh unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        guard session.canRefreshStoppedSnapshot else {
            refusePreflight(DebuggerClientError.invalidState("Snapshot refresh requires a paused live debug process."))
            return
        }

        await applyClientResult(
            controlledRuntimeAction: .refreshSnapshot,
            correlationID: correlationID
        ) { snapshot in
            try await client.refreshSnapshot(from: snapshot)
        }
    }

    func toggleVariableDisclosure(_ row: DebuggerVariablesInspectionPresentation.Row) {
        if row.isExpanded {
            collapsedVariableTokens.insert(row.id)
            return
        }
        if row.isCollapsed {
            collapsedVariableTokens.remove(row.id)
            return
        }
        expandVariableChildren(row)
    }

    func variableExpansionDisabledReason(
        for row: DebuggerVariablesInspectionPresentation.Row
    ) -> String? {
        guard isWorkspaceAdmissionOpen else {
            return workspaceAdmissionPending
                ? "Variable expansion is waiting for the previous document's debugger session to retire."
                : "This workspace debugger session has retired."
        }
        guard row.isExpandable else { return "This variable has no expandable children." }
        guard capabilities.executionControlSupport.isSupported else {
            return "Variable expansion unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)"
        }
        guard session.canRefreshStoppedSnapshot, currentInspectionCoordinate != nil else {
            return "Variable expansion requires a paused live debug process with exact stopped-frame identity."
        }
        if let activeVariableExpansionToken, activeVariableExpansionToken != row.id {
            return "Another variable is currently loading."
        }
        if activeVariableExpansionToken == row.id {
            return "Children are loading."
        }
        return row.canRequestExpansion ? nil : "Children are already loaded."
    }

    private func expandVariableChildren(
        _ row: DebuggerVariablesInspectionPresentation.Row
    ) {
        guard isWorkspaceAdmissionOpen, variableExpansionDisabledReason(for: row) == nil,
              let coordinate = currentInspectionCoordinate,
              let request = DebuggerVariableExpansionRequest(
                  coordinate: coordinate,
                  token: row.id,
                  pathComponents: row.pathComponents,
                  depth: row.depth + 1
              ) else {
            return
        }

        let acceptanceRequest = beginSnapshotRequest()
        let requestID = UUID()
        variableExpansionRequestID = requestID
        activeVariableExpansionToken = row.id
        variableExpansionStates[row.id] = .loading
        lastError = nil
        variableExpansionTask = Task { [weak self] in
            guard let self else { return }
            guard isWorkspaceAdmissionOpen, !Task.isCancelled,
                  variableExpansionRequestID == requestID,
                  currentInspectionCoordinate == coordinate,
                  snapshotAcceptanceGate.isCurrent(acceptanceRequest, currentSnapshot: session) else {
                finishVariableExpansion(requestID: requestID, token: row.id, state: nil)
                return
            }
            do {
                let next = try await client.expandVariableChildren(
                    request,
                    from: acceptanceRequest.requestSnapshot
                )
                guard !Task.isCancelled,
                      variableExpansionRequestID == requestID,
                      currentInspectionCoordinate == coordinate,
                      installAcceptedSnapshot(next, from: acceptanceRequest) else {
                    finishVariableExpansion(requestID: requestID, token: row.id, state: nil)
                    return
                }
                collapsedVariableTokens.remove(row.id)
                finishVariableExpansion(requestID: requestID, token: row.id, state: nil)
            } catch is CancellationError {
                finishVariableExpansion(requestID: requestID, token: row.id, state: nil)
            } catch {
                guard isWorkspaceAdmissionOpen, !Task.isCancelled,
                      variableExpansionRequestID == requestID,
                      currentInspectionCoordinate == coordinate else {
                    finishVariableExpansion(requestID: requestID, token: row.id, state: nil)
                    return
                }
                finishVariableExpansion(
                    requestID: requestID,
                    token: row.id,
                    state: .failed("LLDB child read failed.")
                )
            }
        }
    }

    func toggleBreakpoint(at address: UInt64) async {
        guard isWorkspaceAdmissionOpen else { return }
        lastError = nil
        let result = session.toggleBreakpoint(at: address)
        if let breakpoint = result {
            session.statusMessage = "Breakpoint set at \(breakpoint.address.hexAddress)."
        } else {
            session.statusMessage = "Breakpoint removed at \(address.hexAddress)."
        }

        guard capabilities.executionControlSupport.isSupported, session.hasLiveProcessSession else {
            return
        }
        // Compatibility authoring stays local. WorkspaceStore owns durable logical intent, and
        // only its complete catalog can produce checked transient runtime bindings.
    }

    /// Bridges the editor gutter's breakpoint set (the addresses with
    /// `hasBreakpoint == true` in the workspace snapshot) into local debugger
    /// authoring state. Reconciling to exactly the gutter addresses preserves any
    /// existing per-breakpoint metadata (enabled state, condition) for surviving
    /// addresses, drops breakpoints whose gutter marker was cleared, and mints a
    /// default compatibility breakpoint for each newly marked address. Static
    /// workspace addresses are never sent directly to the live backend.
    func applyGutterBreakpoints(_ gutterAddresses: [UInt64]) async {
        guard isWorkspaceAdmissionOpen else { return }
        if session.hasLiveProcessSession,
           let activeWorkspaceLaunchTarget {
            guard let workspaceLaunchTarget,
                  sameWorkspaceOwner(workspaceLaunchTarget, activeWorkspaceLaunchTarget) else {
                rejectWorkspaceIdentity("Debugger breakpoints do not belong to the active workspace image.")
                return
            }
        }

        let reconciled = reconciledBreakpoints(for: gutterAddresses)

        guard reconciled != session.breakpoints else { return }

        lastError = nil
        session.replaceBreakpoints(reconciled)

        guard capabilities.executionControlSupport.isSupported, session.hasLiveProcessSession else {
            return
        }
        // Compatibility gutter rows stay local; logical catalog reconciliation owns runtime bind.
    }

    /// Applies an authored condition + ignore count to the breakpoint identified
    /// by `breakpointEditAddressText`, reconciling it into `session.breakpoints`
    /// (preserving the address / enabled-state / accumulated hit-count plumbing
    /// the compatibility gutter bridge relies on). This legacy edit never mutates
    /// the persistent backend; durable logical authoring is owned by WorkspaceStore.
    func applyBreakpointEdit() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard let address = DebuggerAuthoringValidation.parseHexAddress(breakpointEditAddressText) else {
            applyAuthoringError("Enter the hex address of a breakpoint to edit.")
            return
        }

        guard let existing = session.breakpoints.first(where: { $0.address == address }) else {
            applyAuthoringError("No breakpoint exists at \(address.hexAddress).")
            return
        }

        let parsed = DebuggerBreakpointEdit.parse(
            address: address,
            conditionText: breakpointConditionText,
            ignoreCountText: breakpointIgnoreCountText
        )

        let edit: DebuggerBreakpointEdit
        switch parsed {
        case .success(let value):
            edit = value
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        }

        let updated = edit.applied(to: existing)
        guard updated != existing else {
            lastError = nil
            session.statusMessage = "Breakpoint at \(address.hexAddress) is already up to date."
            return
        }

        lastError = nil
        session.upsertBreakpoint(updated)
        session.statusMessage = breakpointEditStatusMessage(for: updated)

        guard capabilities.executionControlSupport.isSupported, session.hasLiveProcessSession else {
            return
        }
        // Legacy compatibility editing stays local and cannot bypass logical binding authority.
    }

    /// Hardware watchpoints are runtime addresses owned by this stopped session only.
    var canEditWatchpoints: Bool {
        guard isWorkspaceAdmissionOpen,
              !isSessionStartInFlight,
              capabilities.executionControlSupport.isSupported,
              session.hasLiveProcessSession else { return false }
        if case .paused = session.processState { return true }
        return false
    }

    func updateWatchpoints(_ operation: DebuggerWatchpointRequest) async {
        guard canEditWatchpoints else {
            applyAuthoringError("Pause a live debugger session before changing watchpoints.")
            return
        }
        let request = beginSnapshotRequest()
        do {
            let next = try await client.updateWatchpoints(operation, from: request.requestSnapshot)
            guard installAcceptedSnapshot(next, from: request) else { return }
            lastError = next.watchpointError
        } catch {
            _ = acceptClientError(error, from: request)
        }
    }

    /// Validates the authored register name + value and, when a paused live
    /// session is attached, issues the backend register-write call.
    func writeRegister() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Register write unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        let parsed = DebuggerRegisterWriteRequest.parse(
            name: registerWriteNameText,
            value: registerWriteValueText
        )
        let request: DebuggerRegisterWriteRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        }

        guard session.canWriteRegisterLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Register write requires a paused live debug process."))
            return
        }

        await applyClientResult { snapshot in
            try await client.writeRegister(request, from: snapshot)
        }
    }

    /// Validates the authored hex address + byte count and, when a paused live
    /// session is attached, issues the backend memory-read call.
    func readMemory() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Memory read unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        let parsed = DebuggerMemoryReadRequest.parse(
            addressText: memoryReadAddressText,
            byteCountText: memoryReadByteCountText
        )
        let request: DebuggerMemoryReadRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        }

        guard session.canReadMemoryLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Memory read requires a paused live debug process."))
            return
        }

        await applyClientResult { snapshot in
            try await client.readMemory(request, from: snapshot)
        }
    }

    /// Validates the authored hex address + byte sequence and, when a paused live
    /// session is attached, issues the backend memory-write call (which reads the
    /// written bytes back so the panel reflects the mutation).
    func writeMemory() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Memory write unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        let parsed = DebuggerMemoryWriteRequest.parse(
            addressText: memoryWriteAddressText,
            bytesText: memoryWriteBytesText
        )
        let request: DebuggerMemoryWriteRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        }

        guard session.canWriteMemoryLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Memory write requires a paused live debug process."))
            return
        }

        await applyClientResult { snapshot in
            try await client.writeMemory(request, from: snapshot)
        }
    }

    /// Validates the authored expression and, when a paused live session is
    /// attached, issues the backend `expression --` evaluation, surfacing the
    /// typed result (or the rejection reason) without mutating the session
    /// process state.
    func evaluate() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Expression evaluation unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        let parsed = DebuggerExpressionRequest.parse(expressionText)
        let request: DebuggerExpressionRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            expressionResult = nil
            applyAuthoringError(error.reason)
            return
        }

        guard session.canEvaluateExpressionLiveProcess else {
            expressionResult = nil
            refusePreflight(DebuggerClientError.invalidState("Expression evaluation requires a paused live debug process."))
            return
        }

        let acceptanceRequest = beginSnapshotRequest()
        // Expression evaluation can execute arbitrary loader-affecting code. Revoke the derived
        // workspace mapping and its exact raw authority synchronously before the backend starts.
        // The revocation survives catalog reconciliation until a distinct accepted transport
        // authority proves the post-expression module state.
        revokedRuntimeModuleAuthority = Self.runtimeModuleAuthorityCoordinate(for: session)
        runtimeMappingProjection = nil
        do {
            let result = try await client.evaluateExpression(
                request,
                from: acceptanceRequest.requestSnapshot
            )
            if let refreshedSnapshot = result.refreshedSnapshot {
                guard installAcceptedSnapshot(
                    refreshedSnapshot,
                    from: acceptanceRequest
                ) else { return }
            } else {
                guard isWorkspaceAdmissionOpen, snapshotAcceptanceGate.accept(
                    acceptanceRequest,
                    currentSnapshot: session
                ) else { return }
            }
            expressionResult = DebuggerExpressionResult(value: result.value, type: result.type)
            lastError = nil
            session.statusMessage = "\(request.displayName) = \(result.displayName)"
        } catch {
            guard isWorkspaceAdmissionOpen, snapshotAcceptanceGate.accept(
                acceptanceRequest,
                currentSnapshot: session
            ) else { return }
            expressionResult = nil
            applyClientError(error)
        }
    }

    /// Selects LLDB thread `index` on the stopped target and re-reads its frames /
    /// registers (and the thread list) so the panel reflects the chosen thread.
    /// Gated to a paused live session, mirroring the snapshot-refresh posture.
    func selectThread(_ index: Int) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Thread selection unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        let parsed = DebuggerThreadSelectionRequest.parse(index: index)
        let request: DebuggerThreadSelectionRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        }

        guard session.canSelectThreadLiveProcess else {
            refusePreflight(DebuggerClientError.invalidState("Thread selection requires a paused live debug process."))
            return
        }

        await applyClientResult { snapshot in
            try await client.selectThread(request, from: snapshot)
        }
        // A newly selected thread starts at its own top frame (the backend projects frame #0 of
        // the selected thread). Keeping the previous thread's frame index would label the new
        // thread's frame with that index whenever the new stack happens to be deep enough.
        if session.threads.first(where: \.isSelected)?.index == request.index {
            selectedFrameIndex = nil
        }
    }

    // MARK: Attach-to-PID

    /// Parses the authored PID field into a validated attach request, or returns
    /// the rejection reason. `selfProcessID` is the injected host PID so a
    /// self-attach is rejected in tests as well as in the app.
    func attachRequestResult() -> Result<DebuggerAttachPIDRequest, DebuggerAuthoringParseError> {
        DebuggerAttachPIDRequest.parse(attachProcessIDText, selfProcessID: selfProcessID)
    }

    /// A short human-readable rejection reason for the authored PID, or `nil` when
    /// it parses cleanly. Drives the attach editor's inline validation hint.
    var attachValidationMessage: String? {
        if case .failure(let error) = attachRequestResult() {
            return error.reason
        }
        return nil
    }

    /// `true` when the authored PID is valid AND the backend permits an attach
    /// AND the session is idle (not already attached). The policy gate keeps this
    /// `false` under the default signed-target posture, so the UI honestly shows
    /// attach as blocked until that policy is proven.
    var canAttachToProcess: Bool {
        attachDisabledReason == nil
    }

    /// The reason the attach action is disabled, or `nil` when it is enabled. The
    /// order mirrors `launchDisabledReason`: policy/backend first, then session
    /// state, then the authored-PID validation hint.
    var attachDisabledReason: String? {
        guard capabilities.attachSupport.isSupported else {
            return "Attach unavailable: \(capabilities.attachSupport.unavailableReason ?? capabilities.summary)"
        }

        if let policyReason = attachPolicy.unavailableReason {
            return policyReason
        }

        guard !isSessionStartInFlight else {
            return Self.sessionStartInFlightReason
        }

        guard session.processState.canLaunchNewProcess else {
            return "Cannot attach while the debugger is \(session.processState.displayTitle.lowercased())."
        }

        return attachValidationMessage
    }

    var attachControlHelp: String {
        attachDisabledReason ?? "Attach to the entered process ID"
    }

    var selectedLocalProcessEntry: DebuggerLocalProcessCatalogEntry? {
        guard let selection = selectedLocalProcessSelection else { return nil }
        return localProcessDiscoverySnapshot.entries.first { $0.selection == selection }
    }

    var canRefreshLocalProcessCatalog: Bool {
        capabilities.isBackendAvailable && !isAuthorizingLocalProcessAttach
    }

    var localProcessCatalogStatusMessage: String {
        if localProcessDiscoverySnapshot.isRefreshing {
            return "Refreshing process catalog…"
        }
        if localProcessDiscoverySnapshot.entries.isEmpty {
            if localProcessDiscoverySnapshot.generation == 0 {
                return "Refresh to enumerate local processes with exact identity evidence."
            }
            if let denial = localProcessDiscoverySnapshot.aggregateDenials.first?.key {
                return denial.displayReason
            }
            return "No attachable local processes were found."
        }
        let retained = localProcessDiscoverySnapshot.entries.count
        if let metrics = localProcessDiscoverySnapshot.metrics {
            return "\(retained) retained of \(metrics.candidateCount) observed processes."
        }
        return "\(retained) candidate processes."
    }

    var selectedLocalProcessAttachDisabledReason: String? {
        guard capabilities.attachSupport.isSupported else {
            return "Attach unavailable: \(capabilities.attachSupport.unavailableReason ?? capabilities.summary)"
        }
        if let policyReason = attachPolicy.unavailableReason {
            return policyReason
        }
        guard !isSessionStartInFlight else {
            return Self.sessionStartInFlightReason
        }
        guard session.processState.canLaunchNewProcess else {
            return "Cannot attach while the debugger is \(session.processState.displayTitle.lowercased())."
        }
        guard let entry = selectedLocalProcessEntry else {
            return "Select an exactly observed process before attaching."
        }
        guard entry.eligibility.isAttachable else {
            return entry.eligibility.denial?.displayReason ?? "The selected process is not attachable."
        }
        guard !localProcessDiscoverySnapshot.isStale else {
            return "Refresh the stale process catalog before attaching."
        }
        guard !isAuthorizingLocalProcessAttach else {
            return "Authorizing the selected process."
        }
        return nil
    }

    var canAttachSelectedLocalProcess: Bool {
        selectedLocalProcessAttachDisabledReason == nil
    }

    var selectedLocalProcessAttachHelp: String {
        selectedLocalProcessAttachDisabledReason ?? "Authorize and attach to the selected process"
    }

    /// The attach sheet's foot status. A refused attach always shows its reason (warning tone)
    /// until the user changes the selection or refreshes the catalog; otherwise the disabled
    /// reason (warning) or the neutral help text.
    var localProcessAttachSheetStatus: (message: String, isWarning: Bool) {
        if let localProcessAttachRefusal {
            return (localProcessAttachRefusal, true)
        }
        if let reason = selectedLocalProcessAttachDisabledReason {
            return (reason, true)
        }
        return (selectedLocalProcessAttachHelp, false)
    }

    static let sessionStartInFlightReason = "A debugger launch or attach is already in progress."

    func refreshLocalProcessCatalog() async {
        guard canRefreshLocalProcessCatalog else {
            if !capabilities.isBackendAvailable {
                applyUnavailable("Process discovery unavailable: \(capabilities.summary)")
            }
            return
        }

        let finalSnapshot = await localProcessDiscoveryService.refresh(
            policy: localProcessObservationPolicy
        ) { _ in }
        localProcessDiscoverySnapshot = finalSnapshot
        localProcessAttachRefusal = nil

        if let selectedLocalProcessSelection,
           finalSnapshot.entries.contains(where: { $0.selection == selectedLocalProcessSelection }) {
            return
        }
        selectedLocalProcessSelection = finalSnapshot.entries.first {
            $0.eligibility.isAttachable
        }?.selection ?? finalSnapshot.entries.first?.selection
    }

    func selectLocalProcess(_ entry: DebuggerLocalProcessCatalogEntry) {
        if selectedLocalProcessSelection != entry.selection {
            localProcessAttachRefusal = nil
        }
        selectedLocalProcessSelection = entry.selection
        attachProcessIDText = String(entry.fingerprint.processID)
    }

    /// Selects a process from the enumerated list into the attach PID field.
    func selectAttachProcess(_ entry: DebuggerProcessListEntry) {
        attachProcessIDText = String(entry.processID)
    }

    /// Refreshes the candidate running-process list via the injected lister. A
    /// listing failure surfaces as a typed, human-readable error; it never
    /// attaches or escalates.
    func refreshAttachProcessList() {
        do {
            attachProcessList = try processLister.listProcesses()
            if attachProcessList.isEmpty {
                lastError = nil
            }
        } catch {
            attachProcessList = []
            lastError = error.localizedDescription
        }
    }

    /// Validates the legacy field, upgrades it through the exact identity observer,
    /// then submits only `DebuggerLocalAttachRequest` to the client. Raw PIDs never
    /// cross the transport boundary.
    func attachToProcess() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard !refuseIfSessionStartInFlight(attach: true) else { return }
        let parsed = attachRequestResult()
        let request: DebuggerAttachPIDRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        }

        guard capabilities.attachSupport.isSupported else {
            applyUnavailable("Attach unavailable: \(capabilities.attachSupport.unavailableReason ?? capabilities.summary)")
            localProcessAttachRefusal = lastError
            return
        }

        // Honor the signed-target/attach policy honestly: even when the backend
        // reports an attach transport, MacScope keeps attach blocked until the
        // signed-target policy is proven. The blocked policy surfaces as a typed
        // error rather than a silent no-op or a fake-success.
        if let policyReason = attachPolicy.unavailableReason {
            refuseAttach(DebuggerClientError.unsupportedOperation(policyReason))
            return
        }

        guard session.processState.canLaunchNewProcess else {
            refuseAttach(DebuggerClientError.invalidState("Cannot attach while the debugger is \(session.processState.displayTitle.lowercased())."))
            return
        }

        let startToken = beginSessionStart(attach: true)
        defer { endSessionStart(startToken) }
        let authorization = await localProcessDiscoveryService.resolveManualProcessID(
            request.processID,
            policy: localProcessObservationPolicy
        )
        guard case let .resolved(grant) = authorization else {
            refuseAttach(DebuggerClientError.invalidState(
                authorization.denial?.displayReason ?? "Could not authorize the selected process."
            ))
            return
        }

        await attachAuthorizedLocalProcess(
            DebuggerLocalAttachRequest(selectedIdentity: grant.identity),
            displayName: request.displayName
        )
    }

    func attachSelectedLocalProcess() async {
        guard isWorkspaceAdmissionOpen else { return }
        guard !refuseIfSessionStartInFlight(attach: true) else { return }
        guard capabilities.attachSupport.isSupported else {
            applyUnavailable("Attach unavailable: \(capabilities.attachSupport.unavailableReason ?? capabilities.summary)")
            localProcessAttachRefusal = lastError
            return
        }

        if let policyReason = attachPolicy.unavailableReason {
            refuseAttach(DebuggerClientError.unsupportedOperation(policyReason))
            return
        }

        guard session.processState.canLaunchNewProcess else {
            refuseAttach(DebuggerClientError.invalidState("Cannot attach while the debugger is \(session.processState.displayTitle.lowercased())."))
            return
        }

        guard let entry = selectedLocalProcessEntry else {
            applyAuthoringError("Select an exactly observed process before attaching.")
            localProcessAttachRefusal = lastError
            return
        }

        guard entry.eligibility.isAttachable else {
            applyAuthoringError(entry.eligibility.denial?.displayReason ?? "The selected process is not attachable.")
            localProcessAttachRefusal = lastError
            return
        }

        let startToken = beginSessionStart(attach: true)
        defer { endSessionStart(startToken) }
        isAuthorizingLocalProcessAttach = true
        defer { isAuthorizingLocalProcessAttach = false }
        let authorization = await localProcessDiscoveryService.authorize(
            selection: entry.selection,
            policy: localProcessObservationPolicy
        )
        guard case let .resolved(grant) = authorization else {
            refuseAttach(DebuggerClientError.invalidState(
                authorization.denial?.displayReason ?? "Could not authorize the selected process."
            ))
            return
        }

        await attachAuthorizedLocalProcess(
            DebuggerLocalAttachRequest(selectedIdentity: grant.identity),
            displayName: entry.displayName
        )
    }

    private func attachAuthorizedLocalProcess(
        _ request: DebuggerLocalAttachRequest,
        displayName: String
    ) async {
        guard isWorkspaceAdmissionOpen else { return }
        // Authorization awaited; re-check that nothing else started a session meanwhile.
        guard session.processState.canLaunchNewProcess else {
            refuseAttach(DebuggerClientError.invalidState("Cannot attach while the debugger is \(session.processState.displayTitle.lowercased())."))
            return
        }
        let previousProcessState = session.processState
        let previousBackendState = session.backendState
        let previousStatusMessage = session.statusMessage
        clearActiveWorkspaceOwnership()
        let startingState = DebuggerProcessState.launching(targetPath: displayName)
        session.processState = startingState
        session.backendState = .launching(targetPath: displayName)
        session.statusMessage = "Attaching to \(displayName)."
        invalidateWatchEvaluations()
        let acceptanceRequest = snapshotAcceptanceGate.beginNewSessionRequest(for: session)

        // The `.launching` placeholder is this view model's presentation of the in-flight start.
        // The transport must see the session it is starting FROM: the client refuses to attach
        // from any non-idle snapshot, so handing it the placeholder refused every real attach
        // with "Cannot attach while the debugger is launching." (Tier 2 GUI, round 4 lane X).
        var transportSnapshot = acceptanceRequest.requestSnapshot
        transportSnapshot.processState = previousProcessState
        transportSnapshot.backendState = previousBackendState
        transportSnapshot.statusMessage = previousStatusMessage

        do {
            let next = try await client.attach(
                request,
                from: transportSnapshot
            )
            guard installAcceptedSnapshot(next, from: acceptanceRequest) else {
                settleUnacceptedSessionStart(
                    startingState: startingState,
                    previousProcessState: previousProcessState,
                    previousBackendState: previousBackendState,
                    message: "Attach to \(displayName) did not complete: its result was superseded. The debugger is idle; attach again.",
                    isAttach: true
                )
                return
            }
            localProcessAttachRefusal = nil
            selectedFrameIndex = nil
            waitStopMachine.reset(to: session)
            reconcileWorkspaceOwnershipWithSession()
        } catch {
            if acceptLaunchClientError(
                error,
                from: acceptanceRequest,
                previousProcessState: previousProcessState
            ) {
                localProcessAttachRefusal = lastError
            } else {
                settleUnacceptedSessionStart(
                    startingState: startingState,
                    previousProcessState: previousProcessState,
                    previousBackendState: previousBackendState,
                    message: "Attach to \(displayName) failed: \(error.localizedDescription)",
                    isAttach: true
                )
            }
        }
    }

    /// The launch/attach single-flight latch. A second start while one is in flight is refused
    /// with a visible reason and WITHOUT mutating `session` (see `isSessionStartInFlight`).
    /// Call first, synchronously: refuses (without touching `session`) when a start is in flight.
    private func refuseIfSessionStartInFlight(attach: Bool) -> Bool {
        guard isSessionStartInFlight else { return false }
        lastError = Self.sessionStartInFlightReason
        if attach { localProcessAttachRefusal = Self.sessionStartInFlightReason }
        return true
    }

    /// Call after the synchronous pre-flight guards and before the first await, so no other
    /// main-actor work can interleave between the in-flight check and taking the latch.
    private func beginSessionStart(attach: Bool) -> UInt64 {
        sessionStartToken &+= 1
        isSessionStartInFlight = true
        if attach { localProcessAttachRefusal = nil }
        return sessionStartToken
    }

    private func endSessionStart(_ token: UInt64) {
        guard token == sessionStartToken else { return }
        isSessionStartInFlight = false
    }

    /// A pre-flight attach refusal: the typed error lands on the session as before, and the
    /// reason is always retained for the attach sheet.
    private func refuseAttach(_ error: DebuggerClientError) {
        refusePreflight(error)
        localProcessAttachRefusal = error.localizedDescription
    }

    /// A refusal decided before any transport call. While a launch/attach is in flight it only
    /// reports the reason: writing `session` then would invalidate the start's acceptance ticket.
    private func refusePreflight(_ error: DebuggerClientError) {
        guard !isSessionStartInFlight else {
            lastError = error.localizedDescription
            return
        }
        applyClientError(error)
    }

    /// A start whose result (snapshot or error) the acceptance gate did not take must never leave
    /// the session in the `.launching` state that start set: nothing else can ever clear it, and
    /// every later launch/attach would be refused with "...while the debugger is launching".
    /// If the session still shows exactly this start's placeholder, return to the pre-start state
    /// and surface why.
    private func settleUnacceptedSessionStart(
        startingState: DebuggerProcessState,
        previousProcessState: DebuggerProcessState,
        previousBackendState: DebuggerBackendSessionState,
        message: String,
        isAttach: Bool
    ) {
        guard isWorkspaceAdmissionOpen, session.processState == startingState else { return }
        if case .launching = previousProcessState {
            session.processState = .notAttached
        } else {
            session.processState = previousProcessState
        }
        if case .launching = previousBackendState {
            session.backendState = .failed(reason: message)
        } else {
            session.backendState = previousBackendState
        }
        session.statusMessage = message
        lastError = message
        if isAttach { localProcessAttachRefusal = message }
        waitStopMachine.reset(to: session)
        reconcileWorkspaceOwnershipWithSession()
    }

    private func breakpointEditStatusMessage(for breakpoint: DebuggerBreakpoint) -> String {
        var parts: [String] = []
        if let condition = breakpoint.condition, !condition.isEmpty {
            parts.append("condition \(condition)")
        } else {
            parts.append("condition cleared")
        }
        parts.append("ignore \(breakpoint.ignoreCount)")
        return "Updated breakpoint at \(breakpoint.address.hexAddress): \(parts.joined(separator: ", "))."
    }

    private func applyAuthoringError(_ message: String) {
        lastError = message
        // Never rewrite `session` under an in-flight start (see `isSessionStartInFlight`).
        guard !isSessionStartInFlight else { return }
        session.statusMessage = message
    }

    private func rejectWorkspaceIdentity(_ message: String) {
        lastError = message
        guard !isSessionStartInFlight else { return }
        session.statusMessage = message
    }

    private func reconciledBreakpoints(
        for addresses: [UInt64],
        preservingExistingMetadata: Bool = true
    ) -> [DebuggerBreakpoint] {
        let desiredAddresses = Set(addresses)
        let existingByAddress: [UInt64: DebuggerBreakpoint]
        if preservingExistingMetadata {
            existingByAddress = Dictionary(
                session.breakpoints.map { ($0.address, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            existingByAddress = [:]
        }
        return desiredAddresses
            .map { address in
                existingByAddress[address] ?? DebuggerBreakpoint(address: address)
            }
            .sorted { $0.address < $1.address }
    }

    private func clearActiveWorkspaceOwnership() {
        workspaceOwnershipEpoch = UUID()
        activeReconciliationToken = UUID()
        latestAcceptedActiveWorkspaceInput = nil
        pendingActiveWorkspaceInput = nil
        activeWorkspaceInputBeingApplied = nil
        pendingLogicalBreakpointWorkspaceAuthority = nil
        logicalBreakpointWorkspaceAuthorityBeingApplied = nil
        activePresentationBreakpointsRequireConvergence = false
        activeWorkspaceImageSlot = nil
        activeWorkspaceInput = nil
        activeWorkspaceLaunchTarget = nil
        resumeControlQuarantineReason = nil
    }

    /// A slot is not a binary identity. Keep qualifying live addresses only while the latest
    /// workspace evidence for the active slot still names the binary captured by the launch.
    private var activeWorkspaceOwnerIsCurrent: Bool {
        guard let slot = activeWorkspaceImageSlot,
              let target = activeWorkspaceLaunchTarget else { return false }
        if let current = candidateWorkspaceInputsBySlot[slot] {
            return sameWorkspaceOwner(current.launchTarget, target)
        }
        return activeWorkspaceInput.map {
            sameWorkspaceOwner($0.launchTarget, target)
        } ?? false
    }

    private func reconcileWorkspaceOwnershipWithSession() {
        guard !session.hasLiveProcessSession else { return }
        let endingTarget = activeWorkspaceLaunchTarget
        let hadWorkspaceOwner = activeWorkspaceImageSlot != nil
        guard endingTarget != nil || hadWorkspaceOwner else { return }
        clearActiveWorkspaceOwnership()
        guard let input = workspaceInput else { return }
        let preservesExistingMetadata = hadWorkspaceOwner && (
            endingTarget.map { sameWorkspaceOwner($0, input.launchTarget) } ?? false
        )
        session.replaceBreakpoints(
            reconciledBreakpoints(
                for: input.gutterBreakpointAddresses,
                preservingExistingMetadata: preservesExistingMetadata
            )
        )
    }

    private func sameWorkspaceOwner(
        _ lhs: DebuggerLaunchTargetDescriptor,
        _ rhs: DebuggerLaunchTargetDescriptor
    ) -> Bool {
        lhs.origin == rhs.origin
    }

    private func isSameRevisionLaunchTargetRefresh(
        _ input: DebuggerWorkspaceInput,
        from current: DebuggerWorkspaceInput
    ) -> Bool {
        guard input.imageSlot == current.imageSlot,
              input.breakpointRevision == current.breakpointRevision,
              input.gutterBreakpointAddresses == current.gutterBreakpointAddresses,
              sameWorkspaceOwner(input.launchTarget, current.launchTarget),
              input.logicalBreakpointCatalogAvailability
                == current.logicalBreakpointCatalogAvailability,
              input.logicalBreakpointCatalog == current.logicalBreakpointCatalog,
              input.logicalBreakpointCatalogCoordinate
                == current.logicalBreakpointCatalogCoordinate,
              input.breakpointResolutionCatalogCoordinate
                == input.breakpointResolutionCatalog.coordinate,
              current.breakpointResolutionCatalogCoordinate
                == current.breakpointResolutionCatalog.coordinate,
              input.breakpointResolutionCatalogCoordinate.workspaceID
                == current.breakpointResolutionCatalogCoordinate.workspaceID,
              input.breakpointResolutionCatalogCoordinate.revision
                >= current.breakpointResolutionCatalogCoordinate.revision,
              input.breakpointResolutionCatalogCoordinate.workspaceArtifactCatalogRevision
                >= current.breakpointResolutionCatalogCoordinate
                    .workspaceArtifactCatalogRevision else {
            return false
        }
        if input.breakpointResolutionCatalogCoordinate
            == current.breakpointResolutionCatalogCoordinate {
            return input.breakpointResolutionCatalog
                == current.breakpointResolutionCatalog
        }
        return true
    }

    private var attachPolicy: DebuggerAttachPolicy {
        if let attachPolicyOverride {
            return attachPolicyOverride
        }
        if capabilities.isBackendAvailable {
            if capabilities.attachSupport.isSupported {
                return .supported
            }
            let backendReason = capabilities.attachSupport.unavailableReason.map { " Backend: \($0)" } ?? ""
            return .denied(reason: "\(Self.signedTargetAttachPolicyReason)\(backendReason)")
        }

        let reason = capabilities.attachSupport.unavailableReason ?? capabilities.summary
        return .unavailable(reason: reason)
    }

    private var localProcessObservationPolicy: DebuggerLocalProcessObservationPolicy {
        DebuggerLocalProcessObservationPolicy(
            hostRealUserID: DebuggerLocalProcessObservationPolicyHostIdentity.current.realUserID,
            hostEffectiveUserID: DebuggerLocalProcessObservationPolicyHostIdentity.current.effectiveUserID,
            selfProcessID: selfProcessID,
            excludedInfrastructure: []
        )
    }

    private var launchDisabledReason: String? {
        guard capabilities.launchSupport.isSupported else {
            return "Launch unavailable: \(capabilities.launchSupport.unavailableReason ?? capabilities.summary)"
        }

        guard !isSessionStartInFlight else {
            return Self.sessionStartInFlightReason
        }

        guard session.processState.canLaunchNewProcess else {
            return "Cannot launch while the debugger is \(session.processState.displayTitle.lowercased())."
        }

        guard let selectedTarget = targetPickerSnapshot.selectedRow else {
            return "No debugger target is selected."
        }

        guard selectedTarget.kind == .importedTarget else {
            return selectedTarget.disabledReason ?? selectedTarget.detail
        }

        if let disabledReason = selectedTarget.disabledReason {
            return disabledReason
        }

        // A malformed arguments/environment/working-directory edit blocks launch
        // with the same human-readable reason the editor shows inline.
        return launchInvocationValidationMessage
    }

    private func liveControlDisabledReason(
        unavailablePrefix: String,
        stateReason: String
    ) -> String {
        guard capabilities.executionControlSupport.isSupported else {
            return "\(unavailablePrefix): \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)"
        }

        return stateReason
    }

    private var importedTargetSelectionDescriptor: DebuggerTargetSelectionDescriptor {
        guard let workspaceLaunchTarget else {
            return importedTargetDescriptor(executablePath: importedExecutablePath)
        }

        return workspaceLaunchTarget.importedTargetDescriptor(
            launchSupport: capabilities.launchSupport
        )
    }

    private func importedLaunchConfiguration(
        for selectedTarget: DebuggerTargetSelectionDescriptor
    ) -> DebuggerLaunchConfiguration {
        if let workspaceLaunchTarget,
           selectedTarget.id == importedTargetSelectionDescriptor.id {
            return workspaceLaunchTarget.launchConfiguration()
        }

        return importedLaunchConfiguration(executablePath: importedExecutablePath)
    }

    private func pidTargetDescriptor(
        policy: DebuggerAttachPolicy,
        policyDiagnostics: [DebuggerSignedTargetPolicyDiagnostic]
    ) -> DebuggerPIDTargetDescriptor {
        DebuggerPIDTargetDescriptor(
            processID: parsedProcessID,
            policy: policy,
            policyDiagnostics: policyDiagnostics
        )
    }

    private var parsedProcessID: Int32? {
        let trimmedText = processIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = Int32(trimmedText), processID > 0 else {
            return nil
        }

        return processID
    }

    private func applyUnavailable(_ message: String) {
        invalidateWatchEvaluations()
        // This accepted failure/unavailable state cannot carry a prior scalar result.
        expressionResult = nil
        lastError = message
        session.processState = .unavailable(reason: message)
        session.backendState = .unavailable(reason: message)
        session.statusMessage = message
        clearActiveWorkspaceOwnership()
    }

    @discardableResult
    private func installAcceptedSnapshot(
        _ next: DebuggerSessionSnapshot,
        from request: DebuggerSnapshotAcceptanceGate.Ticket,
        preservingWatchRequestID: UUID? = nil
    ) -> Bool {
        guard isWorkspaceAdmissionOpen else { return false }
        guard snapshotAcceptanceGate.accept(
            request,
            currentSnapshot: session,
            candidateSnapshot: next
        ) else {
            return false
        }
        installSnapshotAfterAcceptance(next, preservingWatchRequestID: preservingWatchRequestID)
        return true
    }

    @discardableResult
    private func installAcceptedLogicalBreakpointSnapshot(
        _ next: DebuggerSessionSnapshot,
        from request: DebuggerSnapshotAcceptanceGate.Ticket
    ) -> Bool {
        guard isWorkspaceAdmissionOpen else { return false }
        guard logicalBreakpointSnapshotAcceptanceGate.accept(
            request,
            currentSnapshot: session,
            candidateSnapshot: next
        ) else {
            return false
        }
        installSnapshotAfterAcceptance(next)
        return true
    }

    private func installSnapshotAfterAcceptance(
        _ next: DebuggerSessionSnapshot,
        preservingWatchRequestID: UUID? = nil
    ) {
        if preservingWatchRequestID == nil || preservingWatchRequestID != watchEvaluationRequestID {
            invalidateWatchEvaluations()
        }
        let previousInspectionCoordinate = currentInspectionCoordinate
        // The scalar value has no snapshot identity. An accepted snapshot may reflect a new
        // stop, frame, or same-stop mutation; evaluate() publishes its fresh result afterward.
        expressionResult = nil
        let nextProjection = isRuntimeModuleAuthorityRevoked(for: next)
            ? nil
            : Self.preferredRuntimeMappingProjection(
                current: runtimeMappingProjection,
                candidate: next.runtimeMappingProjection,
                for: next,
                catalog: workspaceArtifactCatalog
            )
        if let changed = Self.changedRegisterNames(previous: session.registers, next: next.registers) {
            changedRegisterNames = changed
        }
        variableChanges.record(next.variableScopes)
        if variableChanges.changedKeys != changedVariableKeys {
            changedVariableKeys = variableChanges.changedKeys
        }
        session = next
        runtimeMappingProjection = nextProjection
        if let revokedRuntimeModuleAuthority,
           Self.runtimeModuleAuthorityCoordinate(for: next) != revokedRuntimeModuleAuthority {
            self.revokedRuntimeModuleAuthority = nil
        }
        lastError = nil
        reconcileSelectedFrame()
        reconcileVariableExpansionLifecycle(
            previousCoordinate: previousInspectionCoordinate
        )
        scheduleLogicalBreakpointResolution()
    }

    private func reconcileVariableExpansionLifecycle(
        previousCoordinate: DebuggerInspectionCoordinate?
    ) {
        guard currentInspectionCoordinate != previousCoordinate else { return }
        variableExpansionTask?.cancel()
        variableExpansionTask = nil
        variableExpansionRequestID = nil
        activeVariableExpansionToken = nil
        variableExpansionStates.removeAll()
        collapsedVariableTokens.removeAll()
    }

    private func finishVariableExpansion(
        requestID: UUID,
        token: DebuggerVariablePathToken,
        state: DebuggerVariablesInspectionPresentation.ExpansionState?
    ) {
        guard variableExpansionRequestID == requestID else { return }
        variableExpansionRequestID = nil
        variableExpansionTask = nil
        activeVariableExpansionToken = nil
        if let state {
            variableExpansionStates[token] = state
        } else {
            variableExpansionStates.removeValue(forKey: token)
        }
    }

    private func isRuntimeModuleAuthorityRevoked(
        for snapshot: DebuggerSessionSnapshot
    ) -> Bool {
        guard let revokedRuntimeModuleAuthority else { return false }
        return Self.runtimeModuleAuthorityCoordinate(for: snapshot)
            == revokedRuntimeModuleAuthority
    }

    private static func runtimeModuleAuthorityCoordinate(
        for snapshot: DebuggerSessionSnapshot
    ) -> RuntimeModuleAuthorityCoordinate? {
        guard let stop = snapshot.transportStopCoordinate,
              let processID = snapshot.liveProcessID,
              let authorityRevision = snapshot.transportRuntimeModuleAuthorityRevision,
              case .available(let inventory) = snapshot.transportRuntimeModuleAuthority,
              inventory.stop == stop,
              inventory.processID == processID else {
            return nil
        }
        return RuntimeModuleAuthorityCoordinate(
            stop: stop,
            processID: processID,
            authorityRevision: authorityRevision,
            inventoryRevision: inventory.revision
        )
    }

    private static func preferredRuntimeMappingProjection(
        current: DebuggerRuntimeMappingProjection?,
        candidate: DebuggerRuntimeMappingProjection?,
        for snapshot: DebuggerSessionSnapshot,
        catalog: DebuggerWorkspaceArtifactCatalog?
    ) -> DebuggerRuntimeMappingProjection? {
        if let catalog {
            return derivedRuntimeMappingProjection(for: snapshot, catalog: catalog)
        }
        let current = transportCompatibleRuntimeMappingProjection(current, for: snapshot)
        let candidate = transportCompatibleRuntimeMappingProjection(candidate, for: snapshot)
        let preferred: DebuggerRuntimeMappingProjection?
        switch (current, candidate) {
        case (nil, nil):
            preferred = nil
        case let (.some(current), nil):
            preferred = current
        case let (nil, .some(candidate)):
            preferred = candidate
        case let (.some(current), .some(candidate)):
            preferred = candidate.key.workspaceCatalogRevision >= current.key.workspaceCatalogRevision
                ? candidate
                : current
        }
        return preferred
    }

    static func derivedRuntimeMappingProjection(
        for snapshot: DebuggerSessionSnapshot,
        catalog: DebuggerWorkspaceArtifactCatalog
    ) -> DebuggerRuntimeMappingProjection? {
        guard let authorityRevision = snapshot.transportRuntimeModuleAuthorityRevision,
              case .available(let inventory) = snapshot.transportRuntimeModuleAuthority,
              inventory.stop == snapshot.transportStopCoordinate,
              inventory.processID == snapshot.liveProcessID else {
            return nil
        }
        let projection = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: inventory,
            authorityRevision: authorityRevision,
            catalog: catalog
        )
        // A genuinely empty runtime inventory is exact evidence and must remain representable as
        // a zero-module projection. A nonempty inventory that correlates to nothing, however,
        // means the workspace owner/catalog no longer proves any mapping (for example after an
        // artifact replacement), so preserve the existing fail-closed revocation behavior.
        guard !projection.modules.isEmpty || inventory.modules.isEmpty else {
            return nil
        }
        return validatedRuntimeMappingProjection(
            projection,
            for: snapshot,
            catalog: catalog
        )
    }

    private static func transportCompatibleRuntimeMappingProjection(
        _ projection: DebuggerRuntimeMappingProjection?,
        for snapshot: DebuggerSessionSnapshot
    ) -> DebuggerRuntimeMappingProjection? {
        guard let projection,
              let authorityRevision = snapshot.transportRuntimeModuleAuthorityRevision,
              case .available(let inventory) = snapshot.transportRuntimeModuleAuthority,
              let stop = snapshot.transportStopCoordinate,
              let processID = snapshot.liveProcessID,
              inventory.stop == stop,
              inventory.processID == processID,
              projection.key == DebuggerRuntimeMappingProjectionKey(
                  stopCoordinate: stop,
                  observedPID: processID,
                  authorityRevision: authorityRevision,
                  inventoryRevision: inventory.revision,
                  workspaceCatalogRevision: projection.key.workspaceCatalogRevision
              ) else {
            return nil
        }
        let inventoryInstanceIDs = Set(inventory.modules.map(\.id))
        guard inventoryInstanceIDs.count == inventory.modules.count,
              projection.modules.allSatisfy({
                  inventoryInstanceIDs.contains($0.instanceID)
              }) else {
            return nil
        }
        return projection
    }

    private static func validatedRuntimeMappingProjection(
        _ projection: DebuggerRuntimeMappingProjection?,
        for snapshot: DebuggerSessionSnapshot,
        catalog: DebuggerWorkspaceArtifactCatalog?
    ) -> DebuggerRuntimeMappingProjection? {
        guard let catalog,
              let projection = transportCompatibleRuntimeMappingProjection(projection, for: snapshot),
              projection.key.workspaceCatalogRevision == catalog.revision,
              projection.modules.allSatisfy({ module in
                  catalog.artifacts.filter { artifact in
                      artifact.binaryID == module.coordinate.binaryID
                          && artifact.slot == module.coordinate.slot
                          && artifact.ownerRevision == module.coordinate.ownerRevision
                          && artifact.artifactIdentity == module.coordinate.artifactIdentity
                          && artifact.artifactIntegrityState == .verified
                  }.count == 1
              }) else {
            return nil
        }
        return projection
    }

    @discardableResult
    private func acceptClientError(
        _ error: Error,
        from request: DebuggerSnapshotAcceptanceGate.Ticket
    ) -> Bool {
        guard isWorkspaceAdmissionOpen, snapshotAcceptanceGate.accept(request, currentSnapshot: session) else {
            return false
        }
        applyClientError(error)
        return true
    }

    @discardableResult
    private func acceptLaunchClientError(
        _ error: Error,
        from request: DebuggerSnapshotAcceptanceGate.Ticket,
        previousProcessState: DebuggerProcessState
    ) -> Bool {
        guard isWorkspaceAdmissionOpen, snapshotAcceptanceGate.accept(request, currentSnapshot: session) else {
            return false
        }
        applyLaunchClientError(error, previousProcessState: previousProcessState)
        return true
    }

    private func applyClientResult(
        controlledRuntimeAction: DebuggerControlAction? = nil,
        correlationID: UUID? = nil,
        _ operation: (DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    ) async {
        guard isWorkspaceAdmissionOpen else { return }
        let request = beginSnapshotRequest()
        do {
            let next = try await operation(request.requestSnapshot)
            guard isWorkspaceAdmissionOpen, installAcceptedSnapshot(next, from: request) else { return }
            if let controlledRuntimeAction {
                recordControlledRuntimeAction(
                    controlledRuntimeAction,
                    correlationID: correlationID,
                    snapshot: session
                )
            }
            // Keep the wait-stop lifecycle consistent with non-run operations that
            // still replace the session (terminate / refresh / pause).
            waitStopMachine.reset(to: session)
            reconcileWorkspaceOwnershipWithSession()
            if case .running = session.processState {
                await observeRunningProcessUntilResolved()
            }
        } catch {
            _ = acceptClientError(error, from: request)
        }
    }

    /// Drives the background wait-for-stop lifecycle around a run command (continue
    /// / step): mark the machine `.waitingForStop(intent)` as the command is issued,
    /// run it, then fold the resulting (or failed) state back into the machine so
    /// the UI surfaces "running, waiting to stop" honestly and resolves to the real
    /// stop once the snapshot lands.
    ///
    /// Asynchronous transports return a running snapshot immediately. In that case this method
    /// observes the same persistent session with one serialized status request at a time until an
    /// observed stop/exit/failure resolves the wait. Every delayed observation owns a fresh
    /// acceptance ticket, so Pause or any newer user action supersedes it before transport I/O.
    private func runAwaitingStop(
        _ intent: DebuggerRunIntent,
        correlationID: UUID? = nil,
        _ operation: (DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot
    ) async {
        guard isWorkspaceAdmissionOpen else { return }
        if let resumeControlQuarantineReason {
            presentResumeControlQuarantine(resumeControlQuarantineReason)
            return
        }
        waitStopMachine.beginRun(intent)
        let request = beginSnapshotRequest()
        do {
            let next = try await operation(request.requestSnapshot)
            guard installAcceptedSnapshot(next, from: request) else { return }
            recordControlledRuntimeAction(
                intent.controlledRuntimeAction,
                correlationID: correlationID,
                snapshot: session
            )
            // Fold the produced snapshot into the wait machine: paused → stopped,
            // exited → exited, still-running → keep waiting.
            applyRunEvent(from: next)
            reconcileWorkspaceOwnershipWithSession()
            guard case .running = next.processState else { return }
            await observeRunningProcessUntilResolved()
        } catch {
            guard acceptClientError(error, from: request) else { return }
            waitStopMachine.apply(.failed(reason: error.localizedDescription))
        }
    }

    private func recordControlledRuntimeAction(
        _ action: DebuggerControlAction,
        correlationID: UUID? = nil,
        snapshot: DebuggerSessionSnapshot
    ) {
        let (sequence, overflowed) = nextControlledRuntimeActionSequence.addingReportingOverflow(1)
        guard !overflowed else { return }
        nextControlledRuntimeActionSequence = sequence
        guard let event = DebuggerControlledRuntimeActionEvent(
            correlationID: correlationID,
            sequence: sequence,
            action: action,
            snapshot: snapshot
        ) else { return }
        lastControlledRuntimeActionEvent = event
    }

    /// Quarantine is an admission decision above transport state, not a debugger failure. Surface
    /// the refusal without poisoning the accepted backend snapshot or clearing live ownership.
    private func presentResumeControlQuarantine(_ message: String) {
        lastError = message
        session.statusMessage = message
    }

    private func observeRunningProcessUntilResolved() async {
        let clock = ContinuousClock()
        let observationStart = clock.now

        while isWorkspaceAdmissionOpen, case .running = session.processState {
            let request = beginSnapshotRequest()
            let cadence: Duration = clock.now - observationStart < .seconds(1)
                ? .milliseconds(100)
                : .milliseconds(250)
            do {
                try await processObservationSleep(cadence)
            } catch {
                return
            }
            guard isWorkspaceAdmissionOpen,
                  snapshotAcceptanceGate.isCurrent(request, currentSnapshot: session),
                  case .running = session.processState else {
                return
            }

            do {
                let next = try await client.pollProcessStatus(from: request.requestSnapshot)
                guard installAcceptedSnapshot(next, from: request) else { return }
                applyRunEvent(from: next)
                reconcileWorkspaceOwnershipWithSession()
                guard case .running = next.processState else { return }
            } catch {
                if let debuggerError = error as? DebuggerClientError {
                    switch debuggerError {
                    case .unsupportedOperation:
                        // The protocol default lets legacy/test clients control a live target
                        // without claiming status-observation support. That limitation does not
                        // prove the already-observed running target or backend failed; preserve
                        // the live snapshot so Pause and Terminate remain available.
                        return
                    case .backendUnavailable, .invalidConfiguration, .invalidState, .backendFailure:
                        break
                    }
                }
                guard acceptClientError(error, from: request) else { return }
                waitStopMachine.apply(.failed(reason: error.localizedDescription))
                return
            }
        }
    }

    /// Maps a freshly produced session snapshot to the wait-stop event it implies.
    private func applyRunEvent(from snapshot: DebuggerSessionSnapshot) {
        guard let event = runEvent(for: snapshot) else {
            waitStopMachine.reset(to: snapshot)
            return
        }
        waitStopMachine.apply(event)
    }

    private func runEvent(for snapshot: DebuggerSessionSnapshot) -> DebuggerRunEvent? {
        switch snapshot.processState {
        case .paused(_, let reason):
            return .stopped(reason: reason)
        case .exited(let code):
            return .exited(code: code)
        case .running:
            return .stillRunning
        case .unavailable(let reason):
            return .failed(reason: reason)
        case .detaching:
            return nil
        case .notAttached, .launching, .batchStopped:
            return .stillRunning
        }
    }

    /// Clears a frame selection that the latest snapshot's frame set no longer
    /// contains, so `selectedFrame` never resolves to a stale index.
    private func reconcileSelectedFrame() {
        guard let index = selectedFrameIndex else { return }
        if !session.frames.contains(where: { $0.index == index }) {
            selectedFrameIndex = nil
        }
    }

    /// Selects call-stack frame `index` on the stopped target, re-reads that
    /// frame's registers / locals, and records the selection so the listing can
    /// navigate to the frame's PC. Gated to a paused live session; an out-of-range
    /// index is rejected without touching the client.
    func selectFrame(_ index: Int) async {
        guard isWorkspaceAdmissionOpen else { return }
        guard capabilities.executionControlSupport.isSupported else {
            applyUnavailable("Frame selection unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
            return
        }

        switch DebuggerFrameSelection.resolve(index: index, in: session) {
        case .failure(let error):
            applyAuthoringError(error.reason)
            return
        case .success(let selection):
            let previousInspectionCoordinate = currentInspectionCoordinate
            let request = DebuggerFrameSelectionRequest(index: selection.index)
            let acceptanceRequest = beginSnapshotRequest()
            do {
                let next = try await client.selectFrame(
                    request,
                    from: acceptanceRequest.requestSnapshot
                )
                guard installAcceptedSnapshot(next, from: acceptanceRequest) else { return }
                // Record the selection only after the client confirms it, so the
                // listing navigates to the frame the backend actually selected.
                if session.frames.contains(where: { $0.index == selection.index }) {
                    selectedFrameIndex = selection.index
                } else {
                    selectedFrameIndex = nil
                }
                reconcileVariableExpansionLifecycle(
                    previousCoordinate: previousInspectionCoordinate
                )
            } catch {
                _ = acceptClientError(error, from: acceptanceRequest)
            }
        }
    }

    private func applyClientError(_ error: Error) {
        invalidateWatchEvaluations()
        // This accepted failure/unavailable state cannot carry a prior scalar result.
        expressionResult = nil
        defer { reconcileWorkspaceOwnershipWithSession() }
        let message = error.localizedDescription
        lastError = message
        session.statusMessage = message

        guard let debuggerError = error as? DebuggerClientError else {
            session.processState = .unavailable(reason: message)
            session.backendState = .failed(reason: message)
            return
        }

        switch debuggerError {
        case .backendUnavailable:
            session.processState = .unavailable(reason: message)
            session.backendState = .unavailable(reason: message)
        case .unsupportedOperation:
            session.backendState = .failed(reason: message)
        case .invalidConfiguration, .invalidState:
            session.backendState = .failed(reason: message)
        case .backendFailure:
            session.processState = .unavailable(reason: message)
            session.backendState = .failed(reason: message)
        }
    }

    private func applyLaunchClientError(_ error: Error, previousProcessState: DebuggerProcessState) {
        invalidateWatchEvaluations()
        // This accepted failure/unavailable state cannot carry a prior scalar result.
        expressionResult = nil
        defer { reconcileWorkspaceOwnershipWithSession() }
        let message = error.localizedDescription
        lastError = message
        session.statusMessage = message

        guard let debuggerError = error as? DebuggerClientError else {
            session.processState = .unavailable(reason: message)
            session.backendState = .failed(reason: message)
            return
        }

        switch debuggerError {
        case .backendUnavailable:
            session.processState = .unavailable(reason: message)
            session.backendState = .unavailable(reason: message)
        case .backendFailure:
            session.processState = .unavailable(reason: message)
            session.backendState = .failed(reason: message)
        case .unsupportedOperation, .invalidConfiguration, .invalidState:
            session.processState = previousProcessState
            session.backendState = .failed(reason: message)
        }
    }
}

extension DebuggerPanelViewModel: Phase2AIDebuggerProposalExecuting {
    var phase2CurrentDebuggerSnapshot: DebuggerSessionSnapshot {
        session
    }

    func phase2DebuggerControlUnavailableReason(for action: Phase2AIDebuggerAction) -> String? {
        let availability = controlAvailability(for: action.debuggerControlAction)
        return availability.isEnabled ? nil : availability.disabledReason
    }

    func phase2ExecuteDebuggerProposalAction(
        _ request: Phase2AIDebuggerProposalExecutionRequest
    ) async -> DebuggerControlledRuntimeActionEvent? {
        let previousEventID = lastControlledRuntimeActionEvent?.id
        switch request.action {
        case .continueExecution:
            await continueExecution(correlationID: request.executionID)
        case .stepOver:
            await stepOver(correlationID: request.executionID)
        case .stepInto:
            await stepInto(correlationID: request.executionID)
        case .stepOut:
            await stepOut(correlationID: request.executionID)
        case .pause:
            await pause(correlationID: request.executionID)
        case .refreshSnapshot:
            await refreshSnapshot(correlationID: request.executionID)
        }
        guard lastControlledRuntimeActionEvent?.id != previousEventID,
              lastControlledRuntimeActionEvent?.correlationID == request.executionID else {
            return nil
        }
        return lastControlledRuntimeActionEvent
    }
}

extension Phase2AIDebuggerAction {
    var debuggerControlAction: DebuggerControlAction {
        switch self {
        case .continueExecution:
            .continueExecution
        case .stepOver:
            .stepOver
        case .stepInto:
            .stepInto
        case .stepOut:
            .stepOut
        case .pause:
            .pause
        case .refreshSnapshot:
            .refreshSnapshot
        }
    }
}

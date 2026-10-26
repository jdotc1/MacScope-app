import Foundation

/// Process authority accepted by ``DebuggerSessionReducer``. This is deliberately
/// smaller than the presentation process model: only positively observed process
/// facts may enter authoritative reducer state.
enum DebuggerReducerProcessPhase: Equatable, Sendable {
    case noTarget
    case running(processID: Int32)
    case stopped(processID: Int32, reason: DebuggerTransportStopReason)
    case detaching(processID: Int32)
    case exited(processID: Int32, code: Int32?)
    case detached(processID: Int32)
    case terminated(processID: Int32)
    case invalidated
}

struct DebuggerPendingRequest: Equatable, Sendable {
    var context: DebuggerRequestContext
    var hasStarted: Bool
}

struct DebuggerReducerState: Equatable, Sendable {
    let epoch: DebuggerSessionEpoch
    var lifecycleRevision: DebuggerLifecycleRevision
    var stopRevision: DebuggerStopRevision?
    var lastMintedStopRevision: DebuggerStopRevision
    var lastAcceptedEventSequence: DebuggerEventSequence
    var lastAdmittedRequestSequence: UInt64
    var pendingRequest: DebuggerPendingRequest?
    var processPhase: DebuggerReducerProcessPhase
    var observedProcessID: Int32?
    /// Exact authority independently accepted from a correlated session-open event. Requested
    /// establishment values never enter this field directly.
    var acceptedTargetAuthority: DebuggerSessionTargetAuthority?
    var stoppedData: DebuggerStoppedData?
    var breakpoints: [DebuggerTransportBreakpoint]
    var watchpoints: [DebuggerWatchpoint] = []
    var watchpointError: String? = nil
    var expressionEvaluation: DebuggerExpressionEvaluation?
    var capabilities: DebuggerTransportCapabilities
    var lastDiagnostic: DebuggerDiagnostic?
    var targetDisposition: DebuggerTargetDisposition
    var isInvalidated: Bool
    /// Read-only projection of the privately retained inventory reducer. The session reducer is
    /// the sole mutation authority; coordinators/projectors consume this exact synchronized state.
    fileprivate(set) var runtimeModuleInventoryState: DebuggerRuntimeModuleInventoryState
    /// Read-only projection of the privately retained logical-breakpoint binding reducer. Durable
    /// workspace specifications never enter this state; only current-session resolution, owned
    /// backend IDs, and checked transaction authority are projected.
    fileprivate(set) var breakpointBindingState: DebuggerBreakpointBindingReducerSnapshot

    init(
        epoch: DebuggerSessionEpoch,
        capabilities: DebuggerTransportCapabilities
    ) {
        self.epoch = epoch
        self.lifecycleRevision = .initial
        self.stopRevision = nil
        self.lastMintedStopRevision = .initial
        self.lastAcceptedEventSequence = .initial
        self.lastAdmittedRequestSequence = 0
        self.pendingRequest = nil
        self.processPhase = .noTarget
        self.observedProcessID = nil
        self.acceptedTargetAuthority = nil
        self.stoppedData = nil
        self.breakpoints = []
        self.expressionEvaluation = nil
        self.capabilities = capabilities
        self.lastDiagnostic = nil
        self.targetDisposition = .notStarted
        self.isInvalidated = false
        self.runtimeModuleInventoryState = DebuggerRuntimeModuleInventoryReducer(
            session: DebuggerSessionCoordinate(epoch: epoch, lifecycleRevision: .initial)
        ).state
        self.breakpointBindingState = DebuggerBreakpointBindingReducer(
            sessionEpoch: epoch
        ).snapshot
    }

    var sessionCoordinate: DebuggerSessionCoordinate {
        DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: lifecycleRevision
        )
    }

    var stopCoordinate: DebuggerStopCoordinate? {
        guard let stopRevision else { return nil }
        return DebuggerStopCoordinate(
            session: sessionCoordinate,
            stopRevision: stopRevision
        )
    }
}

enum DebuggerReducerRejection: Equatable, Sendable {
    case invalidatedSession
    case foreignEpoch
    case duplicateOrReorderedRequest
    case conflictingRequest
    case staleLifecycle
    case missingStop
    case staleStop
    case unavailableOperation
    case duplicateOrReorderedEvent
    case missingPendingRequest
    case wrongRequest
    case wrongOperation
    case requestNotStarted
    case invalidProcessID
    case wrongProcessID
    case missingTargetAuthority
    case wrongTargetAuthority
    case invalidTargetOrigin
    case invalidPayload
    case invalidTargetDisposition
    case invalidTransition
}

enum DebuggerRequestAdmission: Equatable, Sendable {
    case accepted(DebuggerPendingRequest)
    case rejected(DebuggerReducerRejection)
}

enum DebuggerEventReduction: Equatable, Sendable {
    case accepted
    case rejected(DebuggerReducerRejection)
}

/// Pure sole-authority debugger event reducer.
///
/// Request admission happens before transport I/O. Event reduction is performed
/// against a temporary state and committed only after every applicable coordinate
/// and transition check succeeds. Consequently, a rejected event cannot partially
/// advance an event sequence, replace stopped data, or consume request authority.
struct DebuggerSessionReducer: Equatable, Sendable {
    private(set) var state: DebuggerReducerState
    /// Retain the complete B2 reducer so its private reconciliation history survives accepted
    /// events. Every admission/event works on a copy and commits it with `state` transactionally.
    private var runtimeModuleInventoryReducer: DebuggerRuntimeModuleInventoryReducer
    /// Sole transient logical-breakpoint authority. As with the runtime-module reducer, every
    /// transition is applied to a copy and committed with the enclosing reducer state.
    private var breakpointBindingReducer: DebuggerBreakpointBindingReducer

    var runtimeModuleInventoryState: DebuggerRuntimeModuleInventoryState {
        state.runtimeModuleInventoryState
    }

    var breakpointBindingState: DebuggerBreakpointBindingReducerSnapshot {
        state.breakpointBindingState
    }

    init(
        epoch: DebuggerSessionEpoch,
        capabilities: DebuggerTransportCapabilities
    ) {
        let session = DebuggerSessionCoordinate(epoch: epoch, lifecycleRevision: .initial)
        self.runtimeModuleInventoryReducer = DebuggerRuntimeModuleInventoryReducer(session: session)
        self.breakpointBindingReducer = DebuggerBreakpointBindingReducer(sessionEpoch: epoch)
        self.state = DebuggerReducerState(
            epoch: epoch,
            capabilities: capabilities
        )
        self.state.runtimeModuleInventoryState = runtimeModuleInventoryReducer.state
        self.state.breakpointBindingState = breakpointBindingReducer.snapshot
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
    }

    @discardableResult
    mutating func admit(_ context: DebuggerRequestContext) -> DebuggerRequestAdmission {
        guard !state.isInvalidated else {
            return .rejected(.invalidatedSession)
        }
        if case .detaching = state.processPhase {
            return .rejected(.invalidatedSession)
        }
        guard context.id.epoch == state.epoch,
              context.expectedSession.epoch == state.epoch else {
            return .rejected(.foreignEpoch)
        }
        guard context.id.sequence > state.lastAdmittedRequestSequence else {
            return .rejected(.duplicateOrReorderedRequest)
        }
        guard state.pendingRequest == nil else {
            return .rejected(.conflictingRequest)
        }
        guard context.expectedSession.lifecycleRevision == state.lifecycleRevision else {
            return .rejected(.staleLifecycle)
        }
        switch state.capabilities.capability(for: context.operation) {
        case .supportedAndObserved:
            break
        case .unsupported, .policyDenied:
            return .rejected(.unavailableOperation)
        }

        // Preserve the established PID-only compatibility path's historical capability/stop
        // rejection precedence. Exact-authority sessions validate the target first so a caller
        // cannot use an omitted or foreign authority to probe the current stop coordinate.
        let isLegacyPIDOnlySession = state.acceptedTargetAuthority == nil
            && state.observedProcessID != nil
        if isLegacyPIDOnlySession,
           let rejection = stopCoordinateRejection(for: context, state: state) {
            return .rejected(rejection)
        }
        if let rejection = targetRequestShapeRejection(for: context) {
            return .rejected(rejection)
        }
        if let rejection = targetAuthorityRejection(for: context, state: state) {
            return .rejected(rejection)
        }
        if !isLegacyPIDOnlySession,
           let rejection = stopCoordinateRejection(for: context, state: state) {
            return .rejected(rejection)
        }

        var candidate = state
        var runtimeCandidate = runtimeModuleInventoryReducer
        var breakpointCandidate = breakpointBindingReducer
        guard applyRuntimeModuleAdmission(
            context,
            state: candidate,
            runtimeModules: &runtimeCandidate
        ) else {
            return .rejected(.invalidTransition)
        }
        guard applyBreakpointAdmission(
            context,
            breakpoints: &breakpointCandidate
        ) else {
            return .rejected(.invalidTransition)
        }
        if context.operation == .expandVariableChildren {
            guard context.isInternallyConsistent,
                  let request = context.variableExpansionRequest,
                  canBeginVariableExpansion(matching: request, state: candidate),
                  transitionVariableChildren(
                    matching: request,
                    from: variableChildExpansion(matching: request, state: candidate),
                    to: .loading,
                    state: &candidate
                  ) else {
                return .rejected(.invalidPayload)
            }
        }

        let pending = DebuggerPendingRequest(context: context, hasStarted: false)
        candidate.pendingRequest = pending
        candidate.lastAdmittedRequestSequence = context.id.sequence
        synchronizeRuntimeModuleState(&candidate, from: runtimeCandidate)
        synchronizeBreakpointBindingState(&candidate, from: breakpointCandidate)
        state = candidate
        runtimeModuleInventoryReducer = runtimeCandidate
        breakpointBindingReducer = breakpointCandidate
        return .accepted(pending)
    }

    @discardableResult
    mutating func reduce(_ envelope: DebuggerEventEnvelope) -> DebuggerEventReduction {
        guard !state.isInvalidated else {
            return .rejected(.invalidatedSession)
        }
        guard envelope.sessionEpoch == state.epoch else {
            return .rejected(.foreignEpoch)
        }
        guard envelope.eventSequence > state.lastAcceptedEventSequence else {
            return .rejected(.duplicateOrReorderedEvent)
        }

        var candidate = state
        var runtimeCandidate = runtimeModuleInventoryReducer
        var breakpointCandidate = breakpointBindingReducer
        let result = reduceValidated(
            envelope,
            into: &candidate,
            runtimeModules: &runtimeCandidate,
            breakpointBindings: &breakpointCandidate
        )
        guard result == .accepted else { return result }
        if candidate.isInvalidated {
            candidate.watchpoints = []
            candidate.watchpointError = nil
        }
        candidate.lastAcceptedEventSequence = envelope.eventSequence
        synchronizeRuntimeModuleState(&candidate, from: runtimeCandidate)
        synchronizeBreakpointBindingState(&candidate, from: breakpointCandidate)
        state = candidate
        runtimeModuleInventoryReducer = runtimeCandidate
        breakpointBindingReducer = breakpointCandidate
        return .accepted
    }

    // MARK: - WS-21 typed logical-breakpoint authority

    /// Accepts one complete pure resolution observation through the enclosing sole authority.
    /// Rejected/stale input leaves both the embedded reducer and public state byte-identical.
    @discardableResult
    mutating func observeLogicalBreakpointResolution(
        _ observation: DebuggerBreakpointResolutionObservation
    ) -> Bool {
        mutateBreakpointBindings { $0.observeResolution(observation) }
    }

    /// Atomically installs one complete resolution observation and admits its exact-stop backend
    /// plan. A duplicate current observation may admit a retry plan after a bounded cancellation;
    /// any other observation or plan rejection leaves both embedded reducers and public state
    /// byte-identical.
    @discardableResult
    mutating func admitLogicalBreakpointReconciliation(
        observation: DebuggerBreakpointResolutionObservation,
        plan: DebuggerBreakpointBindingPlan
    ) -> Bool {
        var candidate = breakpointBindingReducer
        if candidate.snapshot.resolutionObservation != observation {
            guard candidate.observeResolution(observation) else { return false }
        }
        guard candidate.admit(plan) else { return false }
        return commitBreakpointBindings(candidate)
    }

    /// Admits a complete exact-stop reconcile plan before any backend write.
    @discardableResult
    mutating func admitLogicalBreakpointBindingPlan(
        _ plan: DebuggerBreakpointBindingPlan
    ) -> Bool {
        mutateBreakpointBindings { $0.admit(plan) }
    }

    /// Commits only a complete structured receipt for the exact admitted transaction.
    @discardableResult
    mutating func completeLogicalBreakpointBinding(
        _ receipt: DebuggerBreakpointBindingReceipt
    ) -> Bool {
        mutateBreakpointBindings { $0.complete(receipt) }
    }

    /// Cancels only the exact admitted transaction before any backend write. Resolution and
    /// positive ownership remain intact; duplicate or foreign cancellation is a no-op.
    @discardableResult
    mutating func cancelLogicalBreakpointBindingBeforeWrite(
        transactionID: DebuggerBreakpointBindingTransactionID
    ) -> Bool {
        mutateBreakpointBindings { $0.cancelBeforeWrite(transactionID: transactionID) }
    }

    /// Records a potentially post-write malformed completion so positive backend ownership is
    /// retained and uncertainty fails closed instead of being mistaken for a stale no-op.
    @discardableResult
    mutating func rejectMalformedLogicalBreakpointCompletion(
        transactionID: DebuggerBreakpointBindingTransactionID,
        didWriteMayHaveOccurred: Bool,
        positivelyKnownLocations: [DebuggerOwnedBackendBreakpointLocation]
    ) -> Bool {
        mutateBreakpointBindings {
            $0.rejectMalformedCurrentCompletion(
                transactionID: transactionID,
                didWriteMayHaveOccurred: didWriteMayHaveOccurred,
                positivelyKnownLocations: positivelyKnownLocations
            )
        }
    }

    /// Publishes one complete current-stop owned backend inventory.
    @discardableResult
    mutating func observeLogicalBreakpointOwnedInventory(
        _ observation: DebuggerBreakpointOwnedInventoryObservation
    ) -> Bool {
        mutateBreakpointBindings { $0.observeOwnedInventory(observation) }
    }

    /// Admits one generation-local, ownership-ledger-checked callback record.
    @discardableResult
    mutating func recordLogicalBreakpointCallback(
        _ record: DebuggerBreakpointCallbackRecord
    ) -> Bool {
        mutateBreakpointBindings { $0.recordCallback(record) }
    }

    /// Atomically records one complete correlated helper-ring page. A stale generation, PID,
    /// cursor, sequence, backend ID, binding ID, or issuance digest leaves the session authority
    /// byte-identical.
    @discardableResult
    mutating func recordLogicalBreakpointCallbackBatch(
        _ batch: DebuggerBreakpointCallbackBatch
    ) -> Bool {
        mutateBreakpointBindings { $0.recordCallbackBatch(batch) }
    }

    private mutating func mutateBreakpointBindings(
        _ mutation: (inout DebuggerBreakpointBindingReducer) -> Bool
    ) -> Bool {
        var candidate = breakpointBindingReducer
        guard mutation(&candidate) else { return false }
        return commitBreakpointBindings(candidate)
    }

    private mutating func commitBreakpointBindings(
        _ candidate: DebuggerBreakpointBindingReducer
    ) -> Bool {
        var invalidatedRuntimeCandidate: DebuggerRuntimeModuleInventoryReducer?
        if candidate.snapshot.isInvalidated, !state.isInvalidated {
            var runtimeCandidate = runtimeModuleInventoryReducer
            guard runtimeCandidate.invalidateSession(epoch: state.epoch) == .accepted else {
                return false
            }
            invalidatedRuntimeCandidate = runtimeCandidate
        }

        breakpointBindingReducer = candidate
        state.breakpointBindingState = candidate.snapshot
        if let runtimeCandidate = invalidatedRuntimeCandidate {
            runtimeModuleInventoryReducer = runtimeCandidate
            synchronizeRuntimeModuleState(&state, from: runtimeCandidate)
            invalidate(
                &state,
                diagnostic: DebuggerDiagnostic.make(
                    code: .protocolViolation,
                    severity: .error,
                    rawText: "Logical breakpoint binding authority failed closed.",
                    operation: .replaceBreakpoints,
                    targetDisposition: .unknown
                )
            )
        }
        return true
    }

    private func reduceValidated(
        _ envelope: DebuggerEventEnvelope,
        into candidate: inout DebuggerReducerState,
        runtimeModules: inout DebuggerRuntimeModuleInventoryReducer,
        breakpointBindings: inout DebuggerBreakpointBindingReducer
    ) -> DebuggerEventReduction {
        if case .sessionInvalidated(let diagnostic) = envelope.payload {
            guard invalidationCoordinatesAreCurrent(envelope, state: candidate) else {
                return .rejected(.wrongRequest)
            }
            guard diagnostic.targetDisposition == .unknown else {
                return .rejected(.invalidTargetDisposition)
            }
            guard runtimeModules.invalidateSession(epoch: candidate.epoch) == .accepted else {
                return .rejected(.invalidTransition)
            }
            guard invalidateBreakpointBindingsIfNeeded(
                &breakpointBindings,
                epoch: candidate.epoch
            ) else {
                return .rejected(.invalidTransition)
            }
            invalidate(&candidate, diagnostic: diagnostic)
            return .accepted
        }
        if case .logicalBreakpointCallbacksDrained(let batch) = envelope.payload {
            guard envelope.requestID == nil,
                  envelope.operation == nil,
                  envelope.boundStopRevision == nil,
                  envelope.capturedLifecycleRevision == candidate.lifecycleRevision,
                  batch.sessionEpoch == candidate.epoch,
                  batch.processID == candidate.observedProcessID,
                  breakpointBindings.recordCallbackBatch(batch) else {
                return .rejected(.invalidPayload)
            }
            if breakpointBindings.snapshot.isInvalidated {
                // A callback fault invalidates the binding authority, but the correlated process
                // authority must remain live long enough for the coordinator/controller to issue
                // bounded terminate/poll/reap recovery. Tombstoning the whole session here would
                // erase the PID and pending operation before that fail-closed recovery can run.
                candidate.lastDiagnostic = DebuggerDiagnostic.make(
                    code: .protocolViolation,
                    severity: .error,
                    rawText: "Logical breakpoint callback authority failed closed.",
                    operation: .reconcileLogicalBreakpoints,
                    targetDisposition: candidate.targetDisposition
                )
            }
            return .accepted
        }

        guard var pending = candidate.pendingRequest else {
            return .rejected(.missingPendingRequest)
        }
        guard envelope.requestID == pending.context.id else {
            return .rejected(.wrongRequest)
        }
        guard envelope.operation == pending.context.operation else {
            return .rejected(.wrongOperation)
        }
        guard envelope.capturedLifecycleRevision
                == pending.context.expectedSession.lifecycleRevision else {
            return .rejected(.staleLifecycle)
        }
        guard envelope.boundStopRevision == pending.context.requiredStop?.stopRevision else {
            return .rejected(.staleStop)
        }

        switch envelope.payload {
        case .requestStarted:
            guard !pending.hasStarted else {
                return .rejected(.invalidTransition)
            }
            pending.hasStarted = true
            candidate.pendingRequest = pending
            if pending.context.operation == .detach {
                guard beginDetaching(
                    pending: pending,
                    state: &candidate,
                    runtimeModules: &runtimeModules,
                    breakpointBindings: &breakpointBindings
                ) else {
                    return .rejected(.invalidTransition)
                }
            }

        case .sessionOpened(let observedPID):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.operation == .launch else {
                return .rejected(.invalidPayload)
            }
            guard pending.context.targetAuthority == nil else {
                return .rejected(.missingTargetAuthority)
            }
            guard candidate.observedProcessID == nil,
                  candidate.acceptedTargetAuthority == nil,
                  isValidProcessID(observedPID) else {
                return .rejected(
                    isValidProcessID(observedPID) ? .invalidTransition : .invalidProcessID
                )
            }
            candidate.observedProcessID = observedPID

        case .authorizedSessionOpened(let observedPID, let authority):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.operation.classification == .sessionEstablishing else {
                return .rejected(.invalidPayload)
            }
            if let requested = pending.context.targetAuthority {
                guard requested == authority else {
                    return .rejected(.wrongTargetAuthority)
                }
            } else {
                // A launched process does not have a complete immutable identity until the
                // retained transport has created it and the OS observer has corroborated that
                // exact process. This is the sole dynamic-authority exception: attach and every
                // ordinary operation still require authority on their admitted request context.
                guard pending.context.operation == .launch else {
                    return .rejected(.missingTargetAuthority)
                }
                guard case .launched = authority.origin else {
                    return .rejected(.invalidTargetOrigin)
                }
            }
            guard operation(pending.context.operation, matches: authority.origin) else {
                return .rejected(.invalidTargetOrigin)
            }
            guard isValidProcessID(observedPID), observedPID == authority.processID else {
                return .rejected(
                    isValidProcessID(observedPID) ? .wrongProcessID : .invalidProcessID
                )
            }
            guard candidate.processPhase == .noTarget,
                  candidate.targetDisposition == .notStarted,
                  candidate.stopRevision == nil,
                  candidate.observedProcessID == nil,
                  candidate.acceptedTargetAuthority == nil,
                  !candidate.isInvalidated else {
                return .rejected(.invalidTransition)
            }
            candidate.observedProcessID = observedPID
            candidate.acceptedTargetAuthority = authority

        case .processRunning(let observedPID):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.targetAuthority == nil
                    || candidate.acceptedTargetAuthority != nil else {
                return .rejected(.missingTargetAuthority)
            }
            guard validateOrEstablishProcessID(
                observedPID,
                operation: pending.context.operation,
                requestedAuthority: pending.context.targetAuthority,
                state: &candidate
            ) else {
                return .rejected(processIDRejection(observedPID, state: candidate))
            }
            guard !isRunning(candidate.processPhase, processID: observedPID) else {
                return .rejected(.invalidTransition)
            }
            guard advanceLifecycle(&candidate) else {
                return .rejected(.invalidTransition)
            }
            guard runtimeModules.transitionToRunning(
                processID: observedPID,
                session: candidate.sessionCoordinate
            ) == .accepted else {
                return .rejected(.invalidTransition)
            }
            clearStoppedAuthority(&candidate)
            candidate.processPhase = .running(processID: observedPID)
            candidate.targetDisposition = .running(processID: observedPID)

        case .processStopped(let observedPID, let reason):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.targetAuthority == nil
                    || candidate.acceptedTargetAuthority != nil else {
                return .rejected(.missingTargetAuthority)
            }
            guard validateOrEstablishProcessID(
                observedPID,
                operation: pending.context.operation,
                requestedAuthority: pending.context.targetAuthority,
                state: &candidate
            ) else {
                return .rejected(processIDRejection(observedPID, state: candidate))
            }
            if isStopped(candidate.processPhase, processID: observedPID) {
                guard runControlConsumesCurrentStop(pending.context, state: candidate) else {
                    return .rejected(.invalidTransition)
                }
            }
            guard advanceLifecycle(&candidate), mintStopRevision(&candidate) else {
                return .rejected(.invalidTransition)
            }
            candidate.stoppedData = nil
            candidate.expressionEvaluation = nil
            candidate.processPhase = .stopped(processID: observedPID, reason: reason)
            candidate.targetDisposition = .stopped(processID: observedPID)
            guard let stop = candidate.stopCoordinate,
                  runtimeModules.observeStopped(processID: observedPID, at: stop) == .accepted else {
                return .rejected(.invalidTransition)
            }

        case .processExited(let observedPID, let exitCode):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.targetAuthority == nil
                    || candidate.acceptedTargetAuthority != nil else {
                return .rejected(.missingTargetAuthority)
            }
            guard let observedPID,
                  isValidProcessID(observedPID),
                  observedPID == candidate.observedProcessID else {
                return .rejected(
                    observedPID.map(isValidProcessID) == false
                        ? .invalidProcessID
                        : .wrongProcessID
                )
            }
            if isDetaching(candidate.processPhase, processID: observedPID) {
                guard runtimeModules.state.authority == .unavailable(.terminal),
                      breakpointBindings.snapshot.isTerminal else {
                    return .rejected(.invalidTransition)
                }
            } else {
                guard advanceLifecycle(&candidate) else {
                    return .rejected(.invalidTransition)
                }
                guard runtimeModules.transitionToTerminal(
                    processID: observedPID,
                    session: candidate.sessionCoordinate
                ) == .accepted else {
                    return .rejected(.invalidTransition)
                }
                guard transitionBreakpointBindingsToTerminal(
                    &breakpointBindings,
                    epoch: candidate.epoch
                ) else {
                    return .rejected(.invalidTransition)
                }
            }
            clearStoppedAuthority(&candidate)
            candidate.processPhase = .exited(processID: observedPID, code: exitCode)
            candidate.targetDisposition = .exited(code: exitCode)
            candidate.pendingRequest = nil
            candidate.isInvalidated = true

        case .processDetached(let authority):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.operation == .detach else {
                return .rejected(.invalidPayload)
            }
            guard case .attached = authority.origin else {
                return .rejected(.invalidTargetOrigin)
            }
            guard terminalAuthorityMatches(
                authority,
                pending: pending,
                state: candidate
            ) else {
                return .rejected(.wrongTargetAuthority)
            }
            guard transitionToTerminal(
                phase: .detached(processID: authority.processID),
                disposition: .detached,
                processID: authority.processID,
                state: &candidate,
                runtimeModules: &runtimeModules,
                breakpointBindings: &breakpointBindings
            ) else {
                return .rejected(.invalidTransition)
            }

        case .processTerminated(let authority):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.operation == .terminate else {
                return .rejected(.invalidPayload)
            }
            guard terminalAuthorityMatches(
                authority,
                pending: pending,
                state: candidate
            ) else {
                return .rejected(.wrongTargetAuthority)
            }
            guard transitionToTerminal(
                phase: .terminated(processID: authority.processID),
                disposition: .terminated,
                processID: authority.processID,
                state: &candidate,
                runtimeModules: &runtimeModules,
                breakpointBindings: &breakpointBindings
            ) else {
                return .rejected(.invalidTransition)
            }

        case .stoppedDataRefreshed(let stoppedData):
            guard operationCanRefreshStoppedData(pending.context.operation) else {
                return .rejected(.invalidPayload)
            }
            guard pending.hasStarted,
                  pending.context.requiredStop == candidate.stopCoordinate,
                  case .stopped = candidate.processPhase else {
                return .rejected(.staleStop)
            }
            candidate.stoppedData = stoppedData

        case .variableChildrenRefreshed(let request, let snapshot):
            guard pending.context.operation == .expandVariableChildren,
                  pending.context.variableExpansionRequest == request else {
                return .rejected(.invalidPayload)
            }
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard pending.context.requiredStop == candidate.stopCoordinate,
                  request.coordinate.stop == candidate.stopCoordinate,
                  case .stopped = candidate.processPhase else {
                return .rejected(.staleStop)
            }
            guard snapshot.coordinate == request.coordinate,
                  snapshot.scope.rawValue == request.pathComponents.first,
                  snapshot.depth == request.depth,
                  variableChildExpansion(matching: request, state: candidate) == .loading,
                  let stoppedData = candidate.stoppedData,
                  case .available(let variables) = stoppedData.variables else {
                return .rejected(.invalidPayload)
            }
            var didReplace = false
            let mergedVariables = variables.map { existing in
                guard !didReplace,
                      existing.coordinate == request.coordinate,
                      existing.scope == snapshot.scope,
                      let replacement = existing.replacingChildren(
                        matching: request,
                        with: snapshot.nodes,
                        wasTruncated: snapshot.wasTruncated
                      ) else {
                    return existing
                }
                didReplace = true
                return replacement
            }
            guard didReplace else {
                return .rejected(.invalidPayload)
            }
            candidate.stoppedData = replacingVariables(
                in: stoppedData,
                with: mergedVariables
            )

        case .breakpointsReplaced(let breakpoints):
            guard pending.context.operation == .replaceBreakpoints
                    || pending.context.operation == .launch else {
                return .rejected(.invalidPayload)
            }
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            candidate.breakpoints = breakpoints

        case .watchpointsUpdated(let update):
            guard pending.context.operation == .updateWatchpoints else { return .rejected(.invalidPayload) }
            guard pending.hasStarted, pending.context.requiredStop == candidate.stopCoordinate,
                  case .stopped = candidate.processPhase else { return .rejected(.staleStop) }
            candidate.watchpoints = update.watchpoints
            candidate.watchpointError = update.error

        case .expressionEvaluated(let evaluation):
            guard pending.context.operation == .evaluateExpression else {
                return .rejected(.invalidPayload)
            }
            guard pending.hasStarted,
                  pending.context.requiredStop == candidate.stopCoordinate,
                  case .stopped = candidate.processPhase else {
                return .rejected(.staleStop)
            }
            candidate.expressionEvaluation = evaluation

        case .runtimeModulesRefreshed(let refresh):
            guard pending.context.operation == .refreshRuntimeModules else {
                return .rejected(.invalidPayload)
            }
            guard pending.hasStarted,
                  let exactStop = candidate.stopCoordinate,
                  pending.context.requiredStop == exactStop,
                  case .stopped = candidate.processPhase else {
                return .rejected(.staleStop)
            }
            guard refresh.processID == candidate.observedProcessID else {
                return .rejected(.wrongProcessID)
            }
            guard runtimeModules.acceptInventory(
                refresh.observations,
                observedStopID: refresh.observedStopID,
                processID: refresh.processID,
                at: exactStop
            ) == .accepted else {
                return .rejected(.invalidPayload)
            }
            guard refresh.adapterGeneration > 0,
                  beginBreakpointStopIfNeeded(
                    &breakpointBindings,
                    stop: exactStop,
                    adapterGeneration: refresh.adapterGeneration,
                    observedPID: refresh.processID,
                    observedStopID: refresh.observedStopID
                  ) else {
                return .rejected(.invalidPayload)
            }

        case .logicalBreakpointCallbacksDrained:
            // Handled before request correlation because callback-ring drain events have their own
            // adapter-generation/PID/cursor authority and never borrow an unrelated operation.
            return .rejected(.invalidPayload)

        case .requestCompleted(let disposition):
            guard pending.hasStarted else {
                return .rejected(.requestNotStarted)
            }
            guard case .completed(let target) = disposition else {
                return .rejected(.invalidTransition)
            }
            guard target == candidate.targetDisposition else {
                return .rejected(.invalidTargetDisposition)
            }
            if pending.context.operation == .refreshRuntimeModules,
               runtimeModules.state.availableInventory == nil {
                return .rejected(.invalidTransition)
            }
            if pending.context.operation == .expandVariableChildren {
                guard let request = pending.context.variableExpansionRequest,
                      variableChildExpansion(matching: request, state: candidate) == .loaded else {
                    return .rejected(.invalidTransition)
                }
            }
            candidate.pendingRequest = nil

        case .requestCancelled(let disposition):
            switch disposition {
            case .cancelledBeforeWrite:
                guard !pending.hasStarted else {
                    return .rejected(.invalidTransition)
                }
                guard failPendingRuntimeModuleRefreshIfNeeded(
                    pending.context,
                    state: candidate,
                    runtimeModules: &runtimeModules,
                    evidenceText: "Runtime module refresh cancelled before write."
                ) else {
                    return .rejected(.invalidTransition)
                }
                if pending.context.operation == .expandVariableChildren {
                    guard let request = pending.context.variableExpansionRequest,
                          transitionVariableChildren(
                            matching: request,
                            from: .loading,
                            to: .notLoaded,
                            state: &candidate
                          ) else {
                        return .rejected(.invalidTransition)
                    }
                }
                candidate.pendingRequest = nil
            case .invalidatedAfterWrite(let reason, let target):
                guard pending.hasStarted,
                      reason == .cancellationAfterWrite else {
                    return .rejected(.invalidTransition)
                }
                guard target == .unknown else {
                    return .rejected(.invalidTargetDisposition)
                }
                clearStoppedAuthority(&candidate)
                guard runtimeModules.invalidateSession(epoch: candidate.epoch) == .accepted else {
                    return .rejected(.invalidTransition)
                }
                guard invalidateBreakpointBindingsIfNeeded(
                    &breakpointBindings,
                    epoch: candidate.epoch
                ) else {
                    return .rejected(.invalidTransition)
                }
                candidate.pendingRequest = nil
                candidate.processPhase = .invalidated
                candidate.targetDisposition = .unknown
                candidate.isInvalidated = true
            case .completed, .failedBeforeWrite:
                return .rejected(.invalidTransition)
            }

        case .requestFailed(let diagnostic):
            guard diagnostic.targetDisposition == candidate.targetDisposition else {
                return .rejected(.invalidTargetDisposition)
            }
            guard failPendingRuntimeModuleRefreshIfNeeded(
                pending.context,
                state: candidate,
                runtimeModules: &runtimeModules,
                evidenceText: diagnostic.preview
            ) else {
                return .rejected(.invalidTransition)
            }
            if pending.context.operation == .expandVariableChildren {
                guard let request = pending.context.variableExpansionRequest,
                      transitionVariableChildren(
                        matching: request,
                        from: .loading,
                        to: .failed(reason: "LLDB child read failed."),
                        state: &candidate
                      ) else {
                    return .rejected(.invalidTransition)
                }
            }
            candidate.pendingRequest = nil
            candidate.lastDiagnostic = diagnostic

        case .sessionInvalidated:
            preconditionFailure("Session invalidation is handled before request correlation")
        }

        return .accepted
    }

    private func canBeginVariableExpansion(
        matching request: DebuggerVariableExpansionRequest,
        state: DebuggerReducerState
    ) -> Bool {
        switch variableChildExpansion(matching: request, state: state) {
        case .notLoaded, .failed:
            return true
        case .loading, .loaded, nil:
            return false
        }
    }

    private func variableChildExpansion(
        matching request: DebuggerVariableExpansionRequest,
        state: DebuggerReducerState
    ) -> DebuggerVariableChildExpansionState? {
        guard request.coordinate.stop == state.stopCoordinate,
              let stoppedData = state.stoppedData,
              case .available(let variables) = stoppedData.variables else { return nil }
        return variables.lazy.compactMap { snapshot in
            snapshot.childExpansion(matching: request)
        }.first
    }

    private func transitionVariableChildren(
        matching request: DebuggerVariableExpansionRequest,
        from expected: DebuggerVariableChildExpansionState?,
        to expansion: DebuggerVariableChildExpansionState,
        state: inout DebuggerReducerState
    ) -> Bool {
        guard variableChildExpansion(matching: request, state: state) == expected,
              let stoppedData = state.stoppedData,
              case .available(let variables) = stoppedData.variables else { return false }
        var didReplace = false
        let replacements = variables.map { snapshot in
            guard !didReplace,
                  let replacement = snapshot.transitioningChildren(
                    matching: request,
                    to: expansion
                  ) else { return snapshot }
            didReplace = true
            return replacement
        }
        guard didReplace else { return false }
        state.stoppedData = replacingVariables(in: stoppedData, with: replacements)
        return true
    }

    private func replacingVariables(
        in stoppedData: DebuggerStoppedData,
        with variables: [DebuggerVariableSnapshot]
    ) -> DebuggerStoppedData {
        DebuggerStoppedData(
            threads: stoppedData.threads,
            threadIdentityDiagnostic: stoppedData.threadIdentityDiagnostic,
            frames: stoppedData.frames,
            registers: stoppedData.registers,
            memoryPreviews: stoppedData.memoryPreviews,
            variables: .available(variables),
            selectedThreadID: stoppedData.selectedThreadID,
            selectedFrameID: stoppedData.selectedFrameID,
            currentProgramCounter: stoppedData.currentProgramCounter
        )
    }

    private func invalidationCoordinatesAreCurrent(
        _ envelope: DebuggerEventEnvelope,
        state: DebuggerReducerState
    ) -> Bool {
        if envelope.requestID == nil, envelope.operation == nil {
            return envelope.capturedLifecycleRevision == state.lifecycleRevision
                && envelope.boundStopRevision == nil
        }
        guard let pending = state.pendingRequest else { return false }
        return envelope.requestID == pending.context.id
            && envelope.operation == pending.context.operation
            && envelope.capturedLifecycleRevision
                == pending.context.expectedSession.lifecycleRevision
            && envelope.boundStopRevision == pending.context.requiredStop?.stopRevision
    }

    private func applyRuntimeModuleAdmission(
        _ context: DebuggerRequestContext,
        state: DebuggerReducerState,
        runtimeModules: inout DebuggerRuntimeModuleInventoryReducer
    ) -> Bool {
        guard let stop = context.requiredStop,
              let processID = state.observedProcessID else {
            switch context.operation {
            case .refreshRuntimeModules, .evaluateExpression, .expandVariableChildren,
                 .continue, .runToCursor, .stepOver, .stepInto, .stepOut:
                return false
            default:
                return true
            }
        }

        let reduction: DebuggerRuntimeModuleInventoryReduction
        switch context.operation {
        case .refreshRuntimeModules:
            reduction = runtimeModules.admitRefresh(processID: processID, at: stop)
        case .evaluateExpression:
            reduction = runtimeModules.admitExpressionEvaluation(processID: processID, at: stop)
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut:
            reduction = runtimeModules.admitResumeCapableOperation(processID: processID, at: stop)
        default:
            return true
        }
        return reduction == .accepted
    }

    /// Resume-capable request admission tombstones exact-stop breakpoint resolution before any
    /// transport write. A reducer-owned in-flight reconcile blocks resume, enforcing convergence
    /// rather than racing a backend transaction.
    private func applyBreakpointAdmission(
        _ context: DebuggerRequestContext,
        breakpoints: inout DebuggerBreakpointBindingReducer
    ) -> Bool {
        switch context.operation {
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut:
            return breakpoints.resumed(sessionEpoch: context.id.epoch)
        case .refreshRuntimeModules, .evaluateExpression:
            return invalidateBreakpointRuntimeInventoryAtCurrentStopIfNeeded(
                context,
                breakpoints: &breakpoints
            )
        default:
            return true
        }
    }

    private func invalidateBreakpointRuntimeInventoryAtCurrentStopIfNeeded(
        _ context: DebuggerRequestContext,
        breakpoints: inout DebuggerBreakpointBindingReducer
    ) -> Bool {
        let snapshot = breakpoints.snapshot
        // The first stopped inventory has not established binding stop authority yet.
        guard let currentStop = snapshot.currentStop else { return true }
        guard context.requiredStop == currentStop,
              let adapterGeneration = snapshot.adapterGeneration,
              let observedPID = snapshot.observedPID,
              let observedStopID = snapshot.observedStopID else {
            return false
        }
        if snapshot.resolutionObservation == nil,
           snapshot.pendingPlan == nil,
           snapshot.resolutions.allSatisfy({ resolution in
               resolution.state == .pending(.awaitingRuntimeInventory)
           }) {
            // A prior same-stop refresh/expression admission already installed the tombstone;
            // retries do not advance binding authority again.
            return true
        }
        return breakpoints.runtimeInventoryInvalidatedAtCurrentStop(
            sessionEpoch: context.id.epoch,
            adapterGeneration: adapterGeneration,
            stopCoordinate: currentStop,
            observedPID: observedPID,
            observedStopID: observedStopID
        )
    }

    private func failPendingRuntimeModuleRefreshIfNeeded(
        _ context: DebuggerRequestContext,
        state: DebuggerReducerState,
        runtimeModules: inout DebuggerRuntimeModuleInventoryReducer,
        evidenceText: String
    ) -> Bool {
        guard context.operation == .refreshRuntimeModules else { return true }
        guard let processID = state.observedProcessID,
              let stop = context.requiredStop else {
            return false
        }
        return runtimeModules.failRefresh(
            processID: processID,
            at: stop,
            evidence: DebuggerRuntimeModuleFailureEvidence(redacting: evidenceText)
        ) == .accepted
    }

    private func synchronizeRuntimeModuleState(
        _ state: inout DebuggerReducerState,
        from reducer: DebuggerRuntimeModuleInventoryReducer
    ) {
        state.runtimeModuleInventoryState = reducer.state
    }

    private func synchronizeBreakpointBindingState(
        _ state: inout DebuggerReducerState,
        from reducer: DebuggerBreakpointBindingReducer
    ) {
        state.breakpointBindingState = reducer.snapshot
    }

    private func beginBreakpointStopIfNeeded(
        _ reducer: inout DebuggerBreakpointBindingReducer,
        stop: DebuggerStopCoordinate,
        adapterGeneration: UInt64,
        observedPID: Int32,
        observedStopID: UInt32
    ) -> Bool {
        let snapshot = reducer.snapshot
        if snapshot.currentStop == stop,
           snapshot.adapterGeneration == adapterGeneration,
           snapshot.observedPID == observedPID,
           snapshot.observedStopID == observedStopID {
            return true
        }
        return reducer.beganNewStop(
            stop,
            adapterGeneration: adapterGeneration,
            observedPID: observedPID,
            observedStopID: observedStopID
        )
    }

    private func transitionBreakpointBindingsToTerminal(
        _ reducer: inout DebuggerBreakpointBindingReducer,
        epoch: DebuggerSessionEpoch
    ) -> Bool {
        reducer.snapshot.isTerminal || reducer.terminal(sessionEpoch: epoch)
    }

    private func invalidateBreakpointBindingsIfNeeded(
        _ reducer: inout DebuggerBreakpointBindingReducer,
        epoch: DebuggerSessionEpoch
    ) -> Bool {
        reducer.snapshot.isInvalidated || reducer.invalidate(sessionEpoch: epoch)
    }

    private func validateOrEstablishProcessID(
        _ processID: Int32,
        operation: DebuggerOperation,
        requestedAuthority: DebuggerSessionTargetAuthority?,
        state: inout DebuggerReducerState
    ) -> Bool {
        guard isValidProcessID(processID) else { return false }
        if let observed = state.observedProcessID {
            return observed == processID
        }
        // Only the explicit legacy nil-target launch may establish PID authority without an
        // `authorizedSessionOpened` event. Exact launch/attach requests must first corroborate the
        // complete requested target through that event.
        guard operation == .launch, requestedAuthority == nil else { return false }
        state.observedProcessID = processID
        return true
    }

    private func targetAuthorityRejection(
        for context: DebuggerRequestContext,
        state: DebuggerReducerState
    ) -> DebuggerReducerRejection? {
        if let accepted = state.acceptedTargetAuthority {
            guard context.operation.classification != .sessionEstablishing else {
                return .invalidTransition
            }
            guard let requested = context.targetAuthority else {
                return .missingTargetAuthority
            }
            guard requested == accepted else { return .wrongTargetAuthority }
            switch context.operation {
            case .detach:
                return operation(.detach, matches: accepted.origin)
                    ? nil
                    : .invalidTargetOrigin
            case .terminate:
                return operation(.terminate, matches: accepted.origin)
                    ? nil
                    : .invalidTargetOrigin
            case .launch, .attach, .continue, .runToCursor, .stepOver, .stepInto,
                 .stepOut, .pause, .replaceBreakpoints, .reconcileLogicalBreakpoints,
                 .writeRegister, .readMemory, .writeMemory, .updateWatchpoints, .evaluateExpression,
                 .expandVariableChildren, .selectThread, .selectFrame, .refreshSnapshot,
                 .refreshRuntimeModules, .pollProcessStatus:
                return nil
            }
        }

        if state.observedProcessID != nil {
            // Compatibility is deliberately confined to the PID-only session created by a
            // nil-target launch. It cannot be upgraded or retargeted through a later request.
            guard context.operation.classification != .sessionEstablishing else {
                return .invalidTransition
            }
            switch context.operation {
            case .detach:
                // A PID-only legacy session has no exact attached identity and therefore can never
                // authorize detach. Its sole target-end compatibility remains nil terminate.
                return .missingTargetAuthority
            case .terminate:
                return context.targetAuthority == nil ? nil : .wrongTargetAuthority
            case .launch, .attach, .continue, .runToCursor, .stepOver, .stepInto,
                 .stepOut, .pause, .replaceBreakpoints, .reconcileLogicalBreakpoints,
                 .writeRegister, .readMemory, .writeMemory, .updateWatchpoints, .evaluateExpression,
                 .expandVariableChildren, .selectThread, .selectFrame, .refreshSnapshot,
                 .refreshRuntimeModules, .pollProcessStatus:
                return context.targetAuthority == nil ? nil : .wrongTargetAuthority
            }
        }

        switch context.operation {
        case .launch:
            if let authority = context.targetAuthority,
               !operation(.launch, matches: authority.origin) {
                return .invalidTargetOrigin
            }
            return nil
        case .attach:
            guard let authority = context.targetAuthority else {
                return .missingTargetAuthority
            }
            return operation(.attach, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .detach:
            guard let authority = context.targetAuthority else {
                return .missingTargetAuthority
            }
            return operation(.detach, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .terminate:
            // Preserve nil only for reducer-proven legacy PID-only launch sessions. Exact target
            // authority can terminate only when its frozen origin proves MacScope launched it.
            guard let authority = context.targetAuthority else { return nil }
            return operation(.terminate, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut, .pause,
             .replaceBreakpoints, .reconcileLogicalBreakpoints,
             .writeRegister, .readMemory, .writeMemory, .updateWatchpoints, .evaluateExpression,
             .expandVariableChildren, .selectThread, .selectFrame, .refreshSnapshot,
             .refreshRuntimeModules, .pollProcessStatus:
            return .missingTargetAuthority
        }
    }

    private func targetRequestShapeRejection(
        for context: DebuggerRequestContext
    ) -> DebuggerReducerRejection? {
        switch context.operation {
        case .launch:
            guard let authority = context.targetAuthority else { return nil }
            return operation(.launch, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .attach:
            guard let authority = context.targetAuthority else {
                return .missingTargetAuthority
            }
            return operation(.attach, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .detach:
            guard let authority = context.targetAuthority else {
                return .missingTargetAuthority
            }
            return operation(.detach, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .terminate:
            guard let authority = context.targetAuthority else { return nil }
            return operation(.terminate, matches: authority.origin)
                ? nil
                : .invalidTargetOrigin
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut, .pause,
             .replaceBreakpoints, .reconcileLogicalBreakpoints,
             .writeRegister, .readMemory, .writeMemory, .updateWatchpoints, .evaluateExpression,
             .expandVariableChildren, .selectThread, .selectFrame, .refreshSnapshot,
             .refreshRuntimeModules, .pollProcessStatus:
            return nil
        }
    }

    private func stopCoordinateRejection(
        for context: DebuggerRequestContext,
        state: DebuggerReducerState
    ) -> DebuggerReducerRejection? {
        if context.operation.requiresStopCoordinate {
            guard let requiredStop = context.requiredStop,
                  let currentStop = state.stopCoordinate else {
                return .missingStop
            }
            return requiredStop == currentStop ? nil : .staleStop
        }
        return context.requiredStop == nil ? nil : .staleStop
    }

    private func operation(
        _ operation: DebuggerOperation,
        matches origin: DebuggerSessionTargetOrigin
    ) -> Bool {
        switch (operation, origin) {
        case (.launch, .launched), (.attach, .attached), (.detach, .attached),
             (.terminate, .launched):
            true
        default: false
        }
    }

    private func terminalAuthorityMatches(
        _ authority: DebuggerSessionTargetAuthority,
        pending: DebuggerPendingRequest,
        state: DebuggerReducerState
    ) -> Bool {
        authority.processID == state.observedProcessID
            && authority == pending.context.targetAuthority
            && authority == state.acceptedTargetAuthority
    }

    private func transitionToTerminal(
        phase: DebuggerReducerProcessPhase,
        disposition: DebuggerTargetDisposition,
        processID: Int32,
        state: inout DebuggerReducerState,
        runtimeModules: inout DebuggerRuntimeModuleInventoryReducer,
        breakpointBindings: inout DebuggerBreakpointBindingReducer
    ) -> Bool {
        guard isValidProcessID(processID), processID == state.observedProcessID else {
            return false
        }
        if isDetaching(state.processPhase, processID: processID) {
            guard runtimeModules.state.authority == .unavailable(.terminal),
                  breakpointBindings.snapshot.isTerminal else {
                return false
            }
        } else {
            guard advanceLifecycle(&state),
                  runtimeModules.transitionToTerminal(
                      processID: processID,
                      session: state.sessionCoordinate
                  ) == .accepted,
                  transitionBreakpointBindingsToTerminal(
                      &breakpointBindings,
                      epoch: state.epoch
                  ) else {
                return false
            }
        }
        clearStoppedAuthority(&state)
        state.processPhase = phase
        state.targetDisposition = disposition
        state.pendingRequest = nil
        state.isInvalidated = true
        return true
    }

    private func beginDetaching(
        pending: DebuggerPendingRequest,
        state: inout DebuggerReducerState,
        runtimeModules: inout DebuggerRuntimeModuleInventoryReducer,
        breakpointBindings: inout DebuggerBreakpointBindingReducer
    ) -> Bool {
        guard pending.hasStarted,
              pending.context.operation == .detach,
              let authority = state.acceptedTargetAuthority,
              authority == pending.context.targetAuthority,
              case .attached = authority.origin,
              state.observedProcessID == authority.processID else {
            return false
        }
        switch state.processPhase {
        case .running(let processID), .stopped(let processID, _):
            guard processID == authority.processID else { return false }
        case .noTarget, .detaching, .exited, .detached, .terminated, .invalidated:
            return false
        }
        guard advanceLifecycle(&state),
              runtimeModules.transitionToTerminal(
                  processID: authority.processID,
                  session: state.sessionCoordinate
              ) == .accepted,
              transitionBreakpointBindingsToTerminal(
                  &breakpointBindings,
                  epoch: state.epoch
              ) else {
            return false
        }
        clearStoppedAuthority(&state)
        state.watchpoints = []
        state.watchpointError = nil
        state.processPhase = .detaching(processID: authority.processID)
        state.targetDisposition = .unknown
        return true
    }

    private func isDetaching(
        _ phase: DebuggerReducerProcessPhase,
        processID: Int32
    ) -> Bool {
        guard case .detaching(let detachingProcessID) = phase else { return false }
        return detachingProcessID == processID
    }

    private func processIDRejection(
        _ processID: Int32,
        state: DebuggerReducerState
    ) -> DebuggerReducerRejection {
        guard isValidProcessID(processID) else { return .invalidProcessID }
        return state.observedProcessID == nil ? .invalidTransition : .wrongProcessID
    }

    private func isValidProcessID(_ processID: Int32) -> Bool {
        processID > 0
    }

    private func operationCanRefreshStoppedData(_ operation: DebuggerOperation) -> Bool {
        switch operation {
        case .writeRegister, .readMemory, .writeMemory, .updateWatchpoints, .selectThread, .selectFrame,
             .refreshSnapshot:
            true
        case .launch, .attach, .continue, .runToCursor, .stepOver, .stepInto, .stepOut,
             .pause, .detach, .terminate, .replaceBreakpoints, .reconcileLogicalBreakpoints,
             .evaluateExpression, .expandVariableChildren, .refreshRuntimeModules,
             .pollProcessStatus:
            false
        }
    }

    private func isRunning(
        _ phase: DebuggerReducerProcessPhase,
        processID: Int32
    ) -> Bool {
        guard case .running(let currentPID) = phase else { return false }
        return currentPID == processID
    }

    private func isStopped(
        _ phase: DebuggerReducerProcessPhase,
        processID: Int32
    ) -> Bool {
        guard case .stopped(let currentPID, _) = phase else { return false }
        return currentPID == processID
    }

    /// LLDB's synchronous run-control commands commonly return only after the target has stopped
    /// again, so the isolated authoritative status exchange may contain no intermediate running
    /// observation. The exact old-stop binding proves this is a new run-control stop rather than a
    /// duplicate stopped callback. Once the new stop is minted, that binding no longer equals the
    /// current stop and a repeated callback is rejected.
    private func runControlConsumesCurrentStop(
        _ context: DebuggerRequestContext,
        state: DebuggerReducerState
    ) -> Bool {
        switch context.operation {
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut:
            return context.requiredStop == state.stopCoordinate
        case .launch, .attach, .pause, .detach, .terminate, .replaceBreakpoints,
             .reconcileLogicalBreakpoints, .writeRegister, .readMemory, .writeMemory, .updateWatchpoints,
             .evaluateExpression, .expandVariableChildren, .selectThread, .selectFrame,
             .refreshSnapshot, .refreshRuntimeModules, .pollProcessStatus:
            return false
        }
    }

    private func advanceLifecycle(_ state: inout DebuggerReducerState) -> Bool {
        guard let next = state.lifecycleRevision.incremented() else { return false }
        state.lifecycleRevision = next
        return true
    }

    private func mintStopRevision(_ state: inout DebuggerReducerState) -> Bool {
        guard let next = state.lastMintedStopRevision.incremented() else { return false }
        state.lastMintedStopRevision = next
        state.stopRevision = next
        return true
    }

    private func clearStoppedAuthority(_ state: inout DebuggerReducerState) {
        state.stopRevision = nil
        state.stoppedData = nil
        state.expressionEvaluation = nil
    }

    private func invalidate(
        _ state: inout DebuggerReducerState,
        diagnostic: DebuggerDiagnostic
    ) {
        clearStoppedAuthority(&state)
        state.pendingRequest = nil
        state.watchpoints = []
        state.watchpointError = nil
        state.processPhase = .invalidated
        state.lastDiagnostic = diagnostic
        state.targetDisposition = diagnostic.targetDisposition
        state.isInvalidated = true
    }

}

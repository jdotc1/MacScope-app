import Foundation

enum DebuggerRuntimeModuleInventoryRejection: Hashable, Sendable {
    case invalidatedSession
    case foreignEpoch
    case staleSession
    case staleStop
    case invalidProcess
    case wrongProcess
    case conflictingRefresh
    case refreshNotAdmitted
    case invalidObservation
    case invalidTransition
    case revisionOverflow
}

enum DebuggerRuntimeModuleInventoryReduction: Hashable, Sendable {
    case accepted
    case rejected(DebuggerRuntimeModuleInventoryRejection)
}

struct DebuggerRuntimeModuleInventoryState: Hashable, Sendable {
    /// A local call-order latch only. The enclosing debugger session reducer remains the sole
    /// lifecycle authority and supplies every accepted session/stop transition to this component.
    fileprivate enum CollectionPhase: Hashable, Sendable {
        case awaitingStoppedObservation
        case stopped
        case running
        case terminal
        case invalidated
    }

    var session: DebuggerSessionCoordinate
    var processID: Int32?
    var currentStop: DebuggerStopCoordinate?
    var inventoryRevision: DebuggerRuntimeModuleInventoryRevision
    var authorityRevision: DebuggerRuntimeModuleAuthorityRevision
    var authority: DebuggerRuntimeModuleAuthority
    var changes: DebuggerRuntimeModuleInventoryChanges
    var isSessionInvalidated: Bool
    fileprivate var lastObservedStop: DebuggerStopCoordinate?
    fileprivate var pendingRefreshStop: DebuggerStopCoordinate?
    fileprivate var collectionPhase: CollectionPhase

    var availableInventory: DebuggerRuntimeModuleInventory? {
        guard case .available(let inventory) = authority else { return nil }
        return inventory
    }

    var activeModules: [DebuggerRuntimeModuleInstance] {
        availableInventory?.modules ?? []
    }
}

/// Pure exact-stop authority for raw runtime module inventories.
/// Workspace correlation and address translation intentionally live above this reducer.
struct DebuggerRuntimeModuleInventoryReducer: Sendable {
    private struct ReconciliationKey: Hashable, Sendable {
        let uuid: UUID
        let normalizedArchitectureTriple: String
    }

    private struct ReconciliationRecord: Hashable, Sendable {
        let fingerprint: DebuggerRuntimeModuleObservationFingerprint
        let remapKey: ReconciliationKey?
    }

    private(set) var state: DebuggerRuntimeModuleInventoryState
    private var lastAcceptedReconciliationRecords: [ReconciliationRecord]

    init(
        session: DebuggerSessionCoordinate,
        initialAuthorityRevision: DebuggerRuntimeModuleAuthorityRevision = .initial
    ) {
        self.state = DebuggerRuntimeModuleInventoryState(
            session: session,
            processID: nil,
            currentStop: nil,
            inventoryRevision: .initial,
            authorityRevision: initialAuthorityRevision,
            authority: .unavailable(.noStoppedProcess),
            changes: .empty,
            isSessionInvalidated: false,
            lastObservedStop: nil,
            pendingRefreshStop: nil,
            collectionPhase: .awaitingStoppedObservation
        )
        self.lastAcceptedReconciliationRecords = []
    }

    @discardableResult
    mutating func observeStopped(
        processID: Int32,
        at stop: DebuggerStopCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard !state.isSessionInvalidated else { return .rejected(.invalidatedSession) }
        guard processID > 0 else { return .rejected(.invalidProcess) }
        guard stop.session.epoch == state.session.epoch else { return .rejected(.foreignEpoch) }
        guard state.collectionPhase != .terminal,
              state.collectionPhase != .invalidated else {
            return .rejected(.invalidTransition)
        }
        guard stop.session.lifecycleRevision >= state.session.lifecycleRevision else {
            return .rejected(.staleSession)
        }
        if let currentPID = state.processID, currentPID != processID {
            return .rejected(.wrongProcess)
        }
        if let lastStop = state.lastObservedStop {
            if stop.session.lifecycleRevision < lastStop.session.lifecycleRevision {
                return .rejected(.staleSession)
            }
            if stop.session.lifecycleRevision == lastStop.session.lifecycleRevision,
               stop.stopRevision <= lastStop.stopRevision {
                return .rejected(.staleStop)
            }
        }
        guard let nextAuthorityRevision = state.authorityRevision.incremented() else {
            return .rejected(.revisionOverflow)
        }

        state.session = stop.session
        state.processID = processID
        state.currentStop = stop
        state.lastObservedStop = stop
        state.pendingRefreshStop = nil
        state.collectionPhase = .stopped
        state.authorityRevision = nextAuthorityRevision
        state.authority = .unavailable(.newStop)
        return .accepted
    }

    @discardableResult
    mutating func admitRefresh(
        processID: Int32,
        at stop: DebuggerStopCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard let rejection = exactStoppedAuthorityRejection(processID: processID, stop: stop) else {
            guard state.pendingRefreshStop == nil else { return .rejected(.conflictingRefresh) }
            guard let nextAuthorityRevision = state.authorityRevision.incremented() else {
                return .rejected(.revisionOverflow)
            }
            state.pendingRefreshStop = stop
            state.authorityRevision = nextAuthorityRevision
            state.authority = .unavailable(.refreshInProgress)
            return .accepted
        }
        return .rejected(rejection)
    }

    @discardableResult
    mutating func acceptInventory(
        _ observations: [DebuggerRuntimeModuleObservation],
        observedStopID: UInt32,
        processID: Int32,
        at stop: DebuggerStopCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard let rejection = exactStoppedAuthorityRejection(processID: processID, stop: stop) else {
            guard state.pendingRefreshStop == stop else { return .rejected(.refreshNotAdmitted) }
            guard observations.count <= 4_096,
                  Set(observations.map(\.fingerprint)).count == observations.count,
                  Self.hasValidCollectionWideMappedRangeCount(observations),
                  observations.allSatisfy({ observation in
                      observation.processID == processID
                          && observation.observedStopID == observedStopID
                  }) else {
                return .rejected(.invalidObservation)
            }
            guard let nextInventoryRevision = state.inventoryRevision.incremented(),
                  let nextAuthorityRevision = state.authorityRevision.incremented() else {
                return .rejected(.revisionOverflow)
            }

            // The extractor's immutable snapshot order is the deterministic ordering authority.
            // Paths, UUID text, and backend display indices must never reorder load instances.
            let ordered = observations
            let modules = ordered.enumerated().map { index, observation in
                DebuggerRuntimeModuleInstance(
                    id: DebuggerRuntimeModuleInstanceID(
                        processID: processID,
                        stop: stop,
                        inventoryRevision: nextInventoryRevision,
                        ordinal: UInt32(index)
                    ),
                    observation: observation
                )
            }
            let inventory = DebuggerRuntimeModuleInventory(
                revision: nextInventoryRevision,
                stop: stop,
                processID: processID,
                observedStopID: observedStopID,
                modules: modules
            )
            state.inventoryRevision = nextInventoryRevision
            state.authorityRevision = nextAuthorityRevision
            state.authority = .available(inventory)
            state.pendingRefreshStop = nil
            let currentRecords = ordered.map(Self.reconciliationRecord)
            state.changes = Self.reconcile(
                previous: lastAcceptedReconciliationRecords,
                current: currentRecords
            )
            lastAcceptedReconciliationRecords = currentRecords
            return .accepted
        }
        return .rejected(rejection)
    }

    @discardableResult
    mutating func failRefresh(
        processID: Int32,
        at stop: DebuggerStopCoordinate,
        evidence: DebuggerRuntimeModuleFailureEvidence
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard let rejection = exactStoppedAuthorityRejection(processID: processID, stop: stop) else {
            guard state.pendingRefreshStop == stop else { return .rejected(.refreshNotAdmitted) }
            guard let nextAuthorityRevision = state.authorityRevision.incremented() else {
                return .rejected(.revisionOverflow)
            }
            state.authorityRevision = nextAuthorityRevision
            state.authority = .unavailable(.refreshFailed(evidence))
            state.pendingRefreshStop = nil
            return .accepted
        }
        return .rejected(rejection)
    }

    @discardableResult
    mutating func admitExpressionEvaluation(
        processID: Int32,
        at stop: DebuggerStopCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        invalidateStoppedAuthority(
            processID: processID,
            stop: stop,
            reason: .expressionEvaluationAdmitted
        )
    }

    @discardableResult
    mutating func admitResumeCapableOperation(
        processID: Int32,
        at stop: DebuggerStopCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        invalidateStoppedAuthority(
            processID: processID,
            stop: stop,
            reason: .resumeCapableOperationAdmitted
        )
    }

    @discardableResult
    mutating func transitionToRunning(
        processID: Int32,
        session: DebuggerSessionCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard state.collectionPhase == .awaitingStoppedObservation
                || state.collectionPhase == .stopped else {
            return .rejected(.invalidTransition)
        }
        if let rejection = lifecycleTransitionRejection(processID: processID, session: session) {
            return .rejected(rejection)
        }
        guard let nextAuthorityRevision = state.authorityRevision.incremented() else {
            return .rejected(.revisionOverflow)
        }
        state.session = session
        state.processID = processID
        state.authorityRevision = nextAuthorityRevision
        state.authority = .unavailable(.running)
        state.currentStop = nil
        state.lastObservedStop = nil
        state.pendingRefreshStop = nil
        state.collectionPhase = .running
        return .accepted
    }

    @discardableResult
    mutating func transitionToTerminal(
        processID: Int32,
        session: DebuggerSessionCoordinate
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard state.collectionPhase == .awaitingStoppedObservation
                || state.collectionPhase == .stopped
                || state.collectionPhase == .running else {
            return .rejected(.invalidTransition)
        }
        if let rejection = lifecycleTransitionRejection(processID: processID, session: session) {
            return .rejected(rejection)
        }

        // Terminal authority is fail-closed. At UInt64 exhaustion it is safer to install a
        // same-revision tombstone than to preserve an available inventory for a dead process.
        state.session = session
        state.processID = nil
        state.authorityRevision = state.authorityRevision.incremented() ?? state.authorityRevision
        state.authority = .unavailable(.terminal)
        state.currentStop = nil
        state.lastObservedStop = nil
        state.pendingRefreshStop = nil
        state.changes = .empty
        state.collectionPhase = .terminal
        lastAcceptedReconciliationRecords = []
        return .accepted
    }

    @discardableResult
    mutating func invalidateSession(
        epoch: DebuggerSessionEpoch
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard !state.isSessionInvalidated else { return .rejected(.invalidatedSession) }
        guard epoch == state.session.epoch else { return .rejected(.foreignEpoch) }
        // Session invalidation is also a fail-closed terminal boundary. Revision exhaustion must
        // never leave an available inventory authoritative for an invalid session.
        state.authorityRevision = state.authorityRevision.incremented() ?? state.authorityRevision
        state.authority = .unavailable(.sessionInvalidated)
        state.processID = nil
        state.currentStop = nil
        state.lastObservedStop = nil
        state.pendingRefreshStop = nil
        state.changes = .empty
        state.isSessionInvalidated = true
        state.collectionPhase = .invalidated
        lastAcceptedReconciliationRecords = []
        return .accepted
    }

    private func lifecycleTransitionRejection(
        processID: Int32,
        session: DebuggerSessionCoordinate
    ) -> DebuggerRuntimeModuleInventoryRejection? {
        if state.isSessionInvalidated { return .invalidatedSession }
        if session.epoch != state.session.epoch { return .foreignEpoch }
        if session.lifecycleRevision < state.session.lifecycleRevision { return .staleSession }
        guard processID > 0 else { return .invalidProcess }
        if let currentProcessID = state.processID, processID != currentProcessID {
            return .wrongProcess
        }
        return nil
    }

    private mutating func invalidateStoppedAuthority(
        processID: Int32,
        stop: DebuggerStopCoordinate,
        reason: DebuggerRuntimeModuleUnavailableReason
    ) -> DebuggerRuntimeModuleInventoryReduction {
        guard let rejection = exactStoppedAuthorityRejection(processID: processID, stop: stop) else {
            guard state.pendingRefreshStop == nil else { return .rejected(.conflictingRefresh) }
            guard let nextAuthorityRevision = state.authorityRevision.incremented() else {
                return .rejected(.revisionOverflow)
            }
            state.authorityRevision = nextAuthorityRevision
            state.authority = .unavailable(reason)
            return .accepted
        }
        return .rejected(rejection)
    }

    private func exactSessionRejection(
        processID: Int32,
        session: DebuggerSessionCoordinate
    ) -> DebuggerRuntimeModuleInventoryRejection? {
        if state.isSessionInvalidated { return .invalidatedSession }
        if session.epoch != state.session.epoch { return .foreignEpoch }
        if session.lifecycleRevision != state.session.lifecycleRevision { return .staleSession }
        guard processID > 0 else { return .invalidProcess }
        if processID != state.processID { return .wrongProcess }
        return nil
    }

    private func exactStoppedAuthorityRejection(
        processID: Int32,
        stop: DebuggerStopCoordinate
    ) -> DebuggerRuntimeModuleInventoryRejection? {
        if let rejection = exactSessionRejection(processID: processID, session: stop.session) {
            return rejection
        }
        guard state.collectionPhase == .stopped else { return .invalidTransition }
        guard let currentStop = state.currentStop else { return .staleStop }
        return currentStop == stop ? nil : .staleStop
    }

    private static func reconcile(
        previous: [ReconciliationRecord],
        current: [ReconciliationRecord]
    ) -> DebuggerRuntimeModuleInventoryChanges {
        // Multiplicity is authority from the complete snapshots. Measuring it only after exact
        // fingerprint pairs are removed could manufacture continuity for the one changed member
        // of a duplicated load set.
        let completePreviousByKey = Dictionary(grouping: previous.compactMap { record in
            record.remapKey.map { ($0, record) }
        }, by: \.0)
        let completeCurrentByKey = Dictionary(grouping: current.compactMap { record in
            record.remapKey.map { ($0, record) }
        }, by: \.0)
        var unmatchedPrevious = previous
        var unmatchedCurrent: [ReconciliationRecord] = []

        for observation in current {
            if let index = unmatchedPrevious.firstIndex(where: {
                $0.fingerprint == observation.fingerprint
            }) {
                unmatchedPrevious.remove(at: index)
            } else {
                unmatchedCurrent.append(observation)
            }
        }

        let unmatchedPreviousByKey = Dictionary(grouping: unmatchedPrevious.compactMap { record in
            record.remapKey.map { ($0, record) }
        }, by: \.0)
        let unmatchedCurrentByKey = Dictionary(grouping: unmatchedCurrent.compactMap { record in
            record.remapKey.map { ($0, record) }
        }, by: \.0)
        var remapped: [DebuggerRuntimeModuleRemap] = []
        var remappedPrevious = Set<DebuggerRuntimeModuleObservationFingerprint>()
        var remappedCurrent = Set<DebuggerRuntimeModuleObservationFingerprint>()
        for key in Set(unmatchedPreviousByKey.keys).intersection(unmatchedCurrentByKey.keys) {
            guard completePreviousByKey[key]?.count == 1,
                  completeCurrentByKey[key]?.count == 1,
                  let oldGroup = unmatchedPreviousByKey[key], oldGroup.count == 1,
                  let newGroup = unmatchedCurrentByKey[key], newGroup.count == 1 else {
                continue
            }
            let old = oldGroup[0].1
            let new = newGroup[0].1
            remapped.append(
                DebuggerRuntimeModuleRemap(previous: old.fingerprint, current: new.fingerprint)
            )
            remappedPrevious.insert(old.fingerprint)
            remappedCurrent.insert(new.fingerprint)
        }

        return DebuggerRuntimeModuleInventoryChanges(
            appeared: unmatchedCurrent
                .map(\.fingerprint)
                .filter { !remappedCurrent.contains($0) }
                .sorted(),
            disappeared: unmatchedPrevious
                .map(\.fingerprint)
                .filter { !remappedPrevious.contains($0) }
                .sorted(),
            remapped: remapped.sorted { lhs, rhs in
                if lhs.previous != rhs.previous { return lhs.previous < rhs.previous }
                return lhs.current < rhs.current
            }
        )
    }

    private static func reconciliationRecord(
        for observation: DebuggerRuntimeModuleObservation
    ) -> ReconciliationRecord {
        ReconciliationRecord(
            fingerprint: observation.fingerprint,
            remapKey: observation.uuid.flatMap { uuid in
                uuid == zeroUUID ? nil : ReconciliationKey(
                    uuid: uuid,
                    normalizedArchitectureTriple: observation.normalizedArchitectureTriple
                )
            }
        )
    }

    private static func hasValidCollectionWideMappedRangeCount(
        _ observations: [DebuggerRuntimeModuleObservation]
    ) -> Bool {
        var total = 0
        for observation in observations {
            let (next, overflowed) = total.addingReportingOverflow(observation.mappedRanges.count)
            guard !overflowed, next <= 32_768 else { return false }
            total = next
        }
        return true
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

import Foundation

private enum DebuggerBreakpointReducerUpdate<Value> {
    case keep
    case set(Value)
}

enum DebuggerBreakpointBackendState: Hashable, Sendable {
    case unbound
    case applying(DebuggerBreakpointBindingTransactionID)
    case bound([DebuggerOwnedBackendBreakpointLocation])
    case armedUnobserved([DebuggerOwnedBackendBreakpointLocation])
    case failClosed(DebuggerBreakpointBackendFailureReason)
}

struct DebuggerBreakpointBindingReducerSnapshot: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let authorityRevision: DebuggerBreakpointBindingAuthorityRevision
    let backendInventoryRevision: DebuggerBreakpointBackendInventoryRevision
    let desiredCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate?
    let resolutionObservation: DebuggerBreakpointResolutionObservation?
    let currentStop: DebuggerStopCoordinate?
    let lifecycleHighWater: DebuggerLifecycleRevision
    let stopHighWater: DebuggerStopRevision
    let adapterGeneration: UInt64?
    let observedPID: Int32?
    let observedStopID: UInt32?
    let resolutions: [DebuggerLogicalBreakpointResolution]
    let backendState: DebuggerBreakpointBackendState
    let ownedLocations: [DebuggerOwnedBackendBreakpointLocation]
    let pendingPlan: DebuggerBreakpointBindingPlan?
    let observedHitCounts: [DebuggerLogicalBreakpointID: UInt64]
    let lastCallbackSequence: UInt64
    var callbackRecords: [DebuggerBreakpointCallbackRecord] = []
    var callbackDropCount: UInt64 = 0
    let isTerminal: Bool
    let isInvalidated: Bool
}

/// Embedded pure subreducer for transient breakpoint binding authority. No value in this file is
/// Codable; session, stop, module-instance, backend, inventory, and hit facts remain memory-only.
struct DebuggerBreakpointBindingReducer: Sendable {
    private(set) var snapshot: DebuggerBreakpointBindingReducerSnapshot

    init(sessionEpoch: DebuggerSessionEpoch) {
        snapshot = DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: sessionEpoch,
            authorityRevision: .initial,
            backendInventoryRevision: .initial,
            desiredCatalogCoordinate: nil,
            resolutionObservation: nil,
            currentStop: nil,
            lifecycleHighWater: .initial,
            stopHighWater: .initial,
            adapterGeneration: nil,
            observedPID: nil,
            observedStopID: nil,
            resolutions: [],
            backendState: .unbound,
            ownedLocations: [],
            pendingPlan: nil,
            observedHitCounts: [:],
            lastCallbackSequence: 0,
            isTerminal: false,
            isInvalidated: false
        )
    }

    /// Accepts the newest complete pure resolution projection. Older observations and exact
    /// duplicates are byte-identical no-ops.
    @discardableResult
    mutating func observeResolution(
        _ observation: DebuggerBreakpointResolutionObservation
    ) -> Bool {
        let stop = observation.mappingKey.stopCoordinate
        let catalogCoordinate = observation.logicalCatalogCoordinate
        guard canAccept(sessionEpoch: stop.session.epoch),
              snapshot.currentStop == stop,
              snapshot.observedPID == observation.mappingKey.observedPID,
              stop.session.lifecycleRevision == snapshot.lifecycleHighWater,
              stop.stopRevision == snapshot.stopHighWater else {
            return false
        }
        if let current = snapshot.desiredCatalogCoordinate {
            guard current.workspaceID == catalogCoordinate.workspaceID,
                  current.catalogID == catalogCoordinate.catalogID,
                  catalogCoordinate.revision >= current.revision else {
                return false
            }
        }
        if let prior = snapshot.resolutionObservation {
            guard observation.resolutionCatalogCoordinate.revision
                    >= prior.resolutionCatalogCoordinate.revision,
                  observation.mappingKey.authorityRevision >= prior.mappingKey.authorityRevision,
                  observation.mappingKey.inventoryRevision >= prior.mappingKey.inventoryRevision else {
                return false
            }
            if observation == prior { return false }
            if observation.resolutionCatalogCoordinate
                    == prior.resolutionCatalogCoordinate,
               observation.mappingKey == prior.mappingKey {
                return false
            }
            if observation.resolutionCatalogCoordinate.revision
                    == prior.resolutionCatalogCoordinate.revision,
               observation.resolutionCatalogCoordinate != prior.resolutionCatalogCoordinate {
                return false
            }
            if observation.mappingKey.authorityRevision == prior.mappingKey.authorityRevision,
               observation.mappingKey != prior.mappingKey {
                return false
            }
        }

        let nextBackendState: DebuggerBreakpointBackendState
        if let pendingPlan = snapshot.pendingPlan {
            nextBackendState = .applying(pendingPlan.transactionID)
        } else if snapshot.ownedLocations.isEmpty {
            nextBackendState = .unbound
        } else {
            nextBackendState = .armedUnobserved(snapshot.ownedLocations)
        }
        replaceSnapshot(
            desiredCatalogCoordinate: catalogCoordinate,
            resolutionObservation: .set(observation),
            resolutions: canonicalResolutions(observation.results),
            backendState: nextBackendState
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Admits only an exact current-stop plan for the latest catalog and exact desired binding set.
    @discardableResult
    mutating func admit(_ plan: DebuggerBreakpointBindingPlan) -> Bool {
        guard canAccept(sessionEpoch: plan.sessionEpoch),
              snapshot.pendingPlan == nil,
              let observation = snapshot.resolutionObservation,
              snapshot.currentStop == plan.stopCoordinate,
              snapshot.adapterGeneration == plan.adapterGeneration,
              snapshot.observedPID == plan.observedPID,
              snapshot.observedStopID == plan.observedStopID,
              snapshot.desiredCatalogCoordinate == plan.logicalCatalogCoordinate,
              observation.logicalCatalogCoordinate == plan.logicalCatalogCoordinate,
              observation.resolutionCatalogCoordinate == plan.resolutionCatalogCoordinate,
              observation.mappingKey == plan.mappingKey,
              observation.canonicalDigest == plan.resolutionObservationDigest,
              Set(plan.bindings) == Set(desiredBindings()),
              !hasRuntimeAddressCollision(plan.bindings) else {
            return false
        }
        replaceSnapshot(
            backendState: .applying(plan.transactionID),
            pendingPlan: .set(plan)
        )
        return advanceAuthorityOrFailClosed()
    }

    /// A foreign or stale typed completion is a byte-identical no-op. A complete receipt for a
    /// superseded plan retains proven ownership but cannot claim convergence to the newer catalog.
    @discardableResult
    mutating func complete(_ receipt: DebuggerBreakpointBindingReceipt) -> Bool {
        guard canAccept(sessionEpoch: receipt.sessionEpoch),
              let plan = snapshot.pendingPlan,
              receipt.transactionID == plan.transactionID else {
            return false
        }
        guard receipt.stopCoordinate == plan.stopCoordinate,
              receipt.adapterGeneration == plan.adapterGeneration,
              receipt.observedPID == plan.observedPID,
              receipt.observedStopID == plan.observedStopID,
              receipt.canonicalPlanDigest == plan.canonicalPlanDigest else {
            if receipt.didWriteBackend {
                enterFailClosed(
                    .postWriteUncertainty,
                    retaining: receipt.completeOwnedInventory
                )
                return true
            }
            return false
        }
        guard receiptMatchesPlan(receipt, plan: plan) else {
            if receipt.didWriteBackend {
                enterFailClosed(
                    .contradictoryReceipt,
                    retaining: receipt.completeOwnedInventory
                )
                return true
            }
            return false
        }

        let owned = receipt.completeOwnedInventory
        let superseded = snapshot.desiredCatalogCoordinate != plan.logicalCatalogCoordinate
            || snapshot.currentStop != plan.stopCoordinate
            || snapshot.adapterGeneration != plan.adapterGeneration
            || snapshot.observedPID != plan.observedPID
            || snapshot.observedStopID != plan.observedStopID
            || snapshot.resolutionObservation?.logicalCatalogCoordinate
                != plan.logicalCatalogCoordinate
            || snapshot.resolutionObservation?.resolutionCatalogCoordinate
                != plan.resolutionCatalogCoordinate
            || snapshot.resolutionObservation?.mappingKey != plan.mappingKey
            || snapshot.resolutionObservation?.canonicalDigest
                != plan.resolutionObservationDigest
        let nextResolutions = superseded
            ? snapshot.resolutions.map { item in
                DebuggerLogicalBreakpointResolution(
                    logicalID: item.logicalID,
                    specificationRevision: item.specificationRevision,
                    state: .pending(.newerCatalogAwaitingConvergence)
                )
            }
            : snapshot.resolutions
        let backendState: DebuggerBreakpointBackendState = owned.isEmpty
            ? .unbound
            : (superseded ? .armedUnobserved(owned) : .bound(owned))
        replaceSnapshot(
            resolutions: nextResolutions,
            backendState: backendState,
            ownedLocations: owned,
            pendingPlan: .set(nil)
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Records malformed current-transaction completion. Before-write malformed output may be
    /// retried; any possible write retains positive ownership and fails closed.
    @discardableResult
    mutating func rejectMalformedCurrentCompletion(
        transactionID: DebuggerBreakpointBindingTransactionID,
        didWriteMayHaveOccurred: Bool,
        positivelyKnownLocations: [DebuggerOwnedBackendBreakpointLocation]
    ) -> Bool {
        guard let plan = snapshot.pendingPlan,
              plan.transactionID == transactionID else {
            return false
        }
        guard didWriteMayHaveOccurred else { return false }
        enterFailClosed(.postWriteUncertainty, retaining: positivelyKnownLocations)
        return true
    }

    /// Cancels only the exact admitted transaction before any backend write. Resolution and
    /// positive ownership remain unchanged; foreign and duplicate cancellation are no-ops.
    @discardableResult
    mutating func cancelBeforeWrite(
        transactionID: DebuggerBreakpointBindingTransactionID
    ) -> Bool {
        guard canAccept(sessionEpoch: snapshot.sessionEpoch),
              snapshot.pendingPlan?.transactionID == transactionID else {
            return false
        }
        replaceSnapshot(
            backendState: snapshot.ownedLocations.isEmpty
                ? .unbound
                : .armedUnobserved(snapshot.ownedLocations),
            pendingPlan: .set(nil)
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Tombstones exact same-stop site×module resolution when an admitted operation can mutate
    /// runtime module inventory without a resume or a new stop coordinate.
    @discardableResult
    mutating func runtimeInventoryInvalidatedAtCurrentStop(
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        stopCoordinate: DebuggerStopCoordinate,
        observedPID: Int32,
        observedStopID: UInt32
    ) -> Bool {
        guard canAccept(sessionEpoch: sessionEpoch),
              snapshot.pendingPlan == nil,
              snapshot.resolutionObservation != nil,
              snapshot.currentStop == stopCoordinate,
              snapshot.adapterGeneration == adapterGeneration,
              snapshot.observedPID == observedPID,
              snapshot.observedStopID == observedStopID else {
            return false
        }
        let pending = snapshot.resolutions.map { item in
            DebuggerLogicalBreakpointResolution(
                logicalID: item.logicalID,
                specificationRevision: item.specificationRevision,
                state: .pending(.awaitingRuntimeInventory)
            )
        }
        replaceSnapshot(
            resolutionObservation: .set(nil),
            resolutions: pending,
            backendState: snapshot.ownedLocations.isEmpty
                ? .unbound
                : .armedUnobserved(snapshot.ownedLocations)
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Resume invalidates exact-stop resolution while retaining positive backend IDs because they
    /// can still stop the running target. Those IDs never prove a new module instance.
    @discardableResult
    mutating func resumed(sessionEpoch: DebuggerSessionEpoch) -> Bool {
        guard canAccept(sessionEpoch: sessionEpoch), snapshot.pendingPlan == nil else {
            return false
        }
        let pending = snapshot.resolutions.map { item in
            DebuggerLogicalBreakpointResolution(
                logicalID: item.logicalID,
                specificationRevision: item.specificationRevision,
                state: .pending(.awaitingRuntimeInventory)
            )
        }
        replaceSnapshot(
            resolutionObservation: .set(nil),
            currentStop: .set(nil),
            observedStopID: .set(nil),
            resolutions: pending,
            backendState: snapshot.ownedLocations.isEmpty
                ? .unbound
                : .armedUnobserved(snapshot.ownedLocations)
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Begins a new stopped-state inventory epoch. Prior IDs stay in the ownership ledger but the
    /// prior site×module identities remain tombstoned until a fresh resolver projection remints.
    @discardableResult
    mutating func beganNewStop(
        _ stop: DebuggerStopCoordinate,
        adapterGeneration: UInt64,
        observedPID: Int32,
        observedStopID: UInt32
    ) -> Bool {
        guard canAccept(sessionEpoch: stop.session.epoch),
              isStrictlyNewer(stop),
              adapterGeneration > 0,
              observedPID > 0,
              observedStopID > 0 else {
            return false
        }
        let pending = snapshot.resolutions.map { item in
            DebuggerLogicalBreakpointResolution(
                logicalID: item.logicalID,
                specificationRevision: item.specificationRevision,
                state: .pending(.awaitingRuntimeInventory)
            )
        }
        let backendState: DebuggerBreakpointBackendState
        if let plan = snapshot.pendingPlan {
            backendState = .applying(plan.transactionID)
        } else if snapshot.ownedLocations.isEmpty {
            backendState = .unbound
        } else {
            backendState = .armedUnobserved(snapshot.ownedLocations)
        }
        let callbackSequence = adapterGeneration == snapshot.adapterGeneration
            ? snapshot.lastCallbackSequence
            : 0
        let callbackDropCount = adapterGeneration == snapshot.adapterGeneration
            ? snapshot.callbackDropCount
            : 0
        replaceSnapshot(
            resolutionObservation: .set(nil),
            currentStop: .set(stop),
            lifecycleHighWater: stop.session.lifecycleRevision,
            stopHighWater: stop.stopRevision,
            adapterGeneration: .set(adapterGeneration),
            observedPID: .set(observedPID),
            observedStopID: .set(observedStopID),
            resolutions: pending,
            backendState: backendState,
            lastCallbackSequence: callbackSequence,
            callbackDropCount: callbackDropCount
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Accepts only a complete current-stop inventory. Inventory never re-establishes a binding
    /// whose module-instance ID belongs to a previous stop.
    @discardableResult
    mutating func observeOwnedInventory(
        _ observation: DebuggerBreakpointOwnedInventoryObservation
    ) -> Bool {
        guard canAccept(sessionEpoch: observation.sessionEpoch),
              observation.isComplete,
              observation.stopCoordinate == snapshot.currentStop,
              observation.adapterGeneration == snapshot.adapterGeneration,
              observation.observedPID == snapshot.observedPID,
              observation.observedStopID == snapshot.observedStopID,
              Set(observation.locations.map(\.bindingID)).count == observation.locations.count,
              Set(observation.locations.map(\.backendBreakpointID)).count
                == observation.locations.count else {
            return false
        }
        guard let nextInventoryRevision = snapshot.backendInventoryRevision.incremented() else {
            enterFailClosed(.revisionOverflow, retaining: observation.locations)
            return true
        }
        let owned = canonicalLocations(observation.locations)
        replaceSnapshot(
            backendInventoryRevision: nextInventoryRevision,
            backendState: owned.isEmpty ? .unbound : .armedUnobserved(owned),
            ownedLocations: owned
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Callback ownership has been proven for an issued binding, but a resumed callback cannot
    /// prove continuity of the old module instance. The next stop must refresh inventory/remint.
    @discardableResult
    mutating func recordCallback(
        _ record: DebuggerBreakpointCallbackRecord
    ) -> Bool {
        let nextSequence = snapshot.lastCallbackSequence.addingReportingOverflow(1)
        let priorHitCount = snapshot.observedHitCounts[record.logicalID]
        let advancesHitCount = record.observedLogicalHitCount > (priorHitCount ?? 0)
        let isPreIncrementFault: Bool
        if case .fault = record.outcome {
            // Ownership/range faults can occur before the helper increments the logical hit
            // counter, including after earlier accepted hits. Equality is valid; regression is not.
            isPreIncrementFault = record.observedLogicalHitCount == (priorHitCount ?? 0)
        } else {
            isPreIncrementFault = false
        }
        guard canAccept(sessionEpoch: record.sessionEpoch),
              record.sessionEpoch == snapshot.sessionEpoch,
              record.adapterGeneration == snapshot.adapterGeneration,
              record.processID == snapshot.observedPID,
              !nextSequence.overflow,
              record.sequence == nextSequence.partialValue,
              let owned = snapshot.ownedLocations.first(where: {
                  $0.bindingID == record.bindingID
                      && $0.backendBreakpointID == record.backendBreakpointID
                      && $0.backendLocationID == record.backendLocationID
                      && $0.issuanceDigest == record.issuanceDigest
              }),
              owned.bindingID.logicalID == record.logicalID,
              owned.bindingID.siteID.specificationRevision == record.specificationRevision,
              record.reportedDropCount.map({ $0 >= snapshot.callbackDropCount }) ?? true,
              advancesHitCount || isPreIncrementFault else {
            return false
        }
        var hitCounts = snapshot.observedHitCounts
        hitCounts[record.logicalID] = record.observedLogicalHitCount
        let retainedRecords = Array(
            (snapshot.callbackRecords + [record])
                .suffix(DebuggerBreakpointCallbackBatch.maximumRecordCount)
        )
        let dropCount = record.reportedDropCount ?? snapshot.callbackDropCount
        let pending = snapshot.resolutions.map { item in
            guard item.logicalID == record.logicalID else { return item }
            return DebuggerLogicalBreakpointResolution(
                logicalID: item.logicalID,
                specificationRevision: item.specificationRevision,
                state: .pending(.hitAwaitingInventory)
            )
        }
        if case .fault = record.outcome {
            replaceSnapshot(
                resolutions: pending,
                backendState: .failClosed(.callbackFault),
                observedHitCounts: hitCounts,
                lastCallbackSequence: record.sequence,
                callbackRecords: retainedRecords,
                callbackDropCount: dropCount,
                isInvalidated: true
            )
            return advanceAuthorityOrFailClosed()
        }
        if record.sequence == UInt64.max {
            replaceSnapshot(
                resolutions: pending,
                backendState: .armedUnobserved(snapshot.ownedLocations),
                observedHitCounts: hitCounts,
                lastCallbackSequence: record.sequence,
                callbackRecords: retainedRecords,
                callbackDropCount: dropCount
            )
            enterFailClosed(.revisionOverflow, retaining: snapshot.ownedLocations)
            return true
        }
        replaceSnapshot(
            resolutions: pending,
            backendState: .armedUnobserved(snapshot.ownedLocations),
            observedHitCounts: hitCounts,
            lastCallbackSequence: record.sequence,
            callbackRecords: retainedRecords,
            callbackDropCount: dropCount
        )
        return advanceAuthorityOrFailClosed()
    }

    /// Applies a complete correlated drain page to a candidate reducer. No record, hit-count,
    /// sequence, history, or fault mutation escapes when any member is stale or malformed.
    @discardableResult
    mutating func recordCallbackBatch(_ batch: DebuggerBreakpointCallbackBatch) -> Bool {
        guard canAccept(sessionEpoch: batch.sessionEpoch),
              batch.sessionEpoch == snapshot.sessionEpoch,
              batch.adapterGeneration == snapshot.adapterGeneration,
              batch.processID == snapshot.observedPID,
              batch.afterSequence == snapshot.lastCallbackSequence else {
            return false
        }
        var candidate = self
        for record in batch.records {
            guard candidate.recordCallback(record) else { return false }
        }
        guard candidate.snapshot.lastCallbackSequence == batch.nextSequence else { return false }
        self = candidate
        return true
    }

    @discardableResult
    mutating func terminal(sessionEpoch: DebuggerSessionEpoch) -> Bool {
        guard sessionEpoch == snapshot.sessionEpoch, !snapshot.isTerminal else { return false }
        let offline = snapshot.resolutions.map { item in
            DebuggerLogicalBreakpointResolution(
                logicalID: item.logicalID,
                specificationRevision: item.specificationRevision,
                state: .pending(.noSession)
            )
        }
        replaceSnapshot(
            resolutionObservation: .set(nil),
            currentStop: .set(nil),
            adapterGeneration: .set(nil),
            observedPID: .set(nil),
            observedStopID: .set(nil),
            resolutions: offline,
            backendState: .unbound,
            ownedLocations: [],
            pendingPlan: .set(nil),
            isTerminal: true
        )
        return advanceAuthorityOrFailClosed()
    }

    @discardableResult
    mutating func invalidate(sessionEpoch: DebuggerSessionEpoch) -> Bool {
        guard sessionEpoch == snapshot.sessionEpoch, !snapshot.isInvalidated else { return false }
        replaceSnapshot(
            resolutionObservation: .set(nil),
            currentStop: .set(nil),
            observedStopID: .set(nil),
            resolutions: snapshot.resolutions.map { item in
                DebuggerLogicalBreakpointResolution(
                    logicalID: item.logicalID,
                    specificationRevision: item.specificationRevision,
                    state: .pending(.noSession)
                )
            },
            backendState: .failClosed(.sessionInvalidated),
            pendingPlan: .set(nil),
            isInvalidated: true
        )
        return advanceAuthorityOrFailClosed()
    }

    private func canAccept(sessionEpoch: DebuggerSessionEpoch) -> Bool {
        sessionEpoch == snapshot.sessionEpoch && !snapshot.isTerminal && !snapshot.isInvalidated
    }

    private func isStrictlyNewer(_ stop: DebuggerStopCoordinate) -> Bool {
        let lifecycle = stop.session.lifecycleRevision
        if lifecycle != snapshot.lifecycleHighWater {
            return lifecycle > snapshot.lifecycleHighWater
        }
        return stop.stopRevision > snapshot.stopHighWater
    }

    private func desiredBindings() -> [DebuggerDesiredBreakpointBinding] {
        snapshot.resolutions.flatMap { item in
            switch item.state {
            case .resolved(_, let binding): return [binding]
            case .resolvedMultiple(_, let bindings): return bindings
            default: return []
            }
        }
    }

    private func receiptMatchesPlan(
        _ receipt: DebuggerBreakpointBindingReceipt,
        plan: DebuggerBreakpointBindingPlan
    ) -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: plan.bindings.map { ($0.id, $0) })
        guard expected.count == receipt.completeOwnedInventory.count else { return false }
        return receipt.completeOwnedInventory.allSatisfy { location in
            guard let desired = expected[location.bindingID] else { return false }
            return location.runtimeAddress == desired.runtimeAddress
                && location.ownershipTagDigest == plan.ownershipTagDigest
                && location.policyActionDigest == desired.policyActionDigest
                && location.issuanceDigest == desired.issuanceDigest
        }
    }

    private mutating func enterFailClosed(
        _ reason: DebuggerBreakpointBackendFailureReason,
        retaining locations: [DebuggerOwnedBackendBreakpointLocation]
    ) {
        let retained = canonicalLocations(snapshot.ownedLocations + locations)
        replaceSnapshot(
            backendState: .failClosed(reason),
            ownedLocations: retained,
            pendingPlan: .set(nil),
            isInvalidated: true
        )
        _ = advanceAuthorityOrFailClosed()
    }

    @discardableResult
    private mutating func advanceAuthorityOrFailClosed() -> Bool {
        guard let next = snapshot.authorityRevision.incremented() else {
            replaceSnapshot(
                backendState: .failClosed(.revisionOverflow),
                pendingPlan: .set(nil),
                isInvalidated: true
            )
            return true
        }
        replaceSnapshot(authorityRevision: next)
        return true
    }

    private mutating func replaceSnapshot(
        authorityRevision: DebuggerBreakpointBindingAuthorityRevision? = nil,
        backendInventoryRevision: DebuggerBreakpointBackendInventoryRevision? = nil,
        desiredCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate? = nil,
        resolutionObservation: DebuggerBreakpointReducerUpdate<DebuggerBreakpointResolutionObservation?> = .keep,
        currentStop: DebuggerBreakpointReducerUpdate<DebuggerStopCoordinate?> = .keep,
        lifecycleHighWater: DebuggerLifecycleRevision? = nil,
        stopHighWater: DebuggerStopRevision? = nil,
        adapterGeneration: DebuggerBreakpointReducerUpdate<UInt64?> = .keep,
        observedPID: DebuggerBreakpointReducerUpdate<Int32?> = .keep,
        observedStopID: DebuggerBreakpointReducerUpdate<UInt32?> = .keep,
        resolutions: [DebuggerLogicalBreakpointResolution]? = nil,
        backendState: DebuggerBreakpointBackendState? = nil,
        ownedLocations: [DebuggerOwnedBackendBreakpointLocation]? = nil,
        pendingPlan: DebuggerBreakpointReducerUpdate<DebuggerBreakpointBindingPlan?> = .keep,
        observedHitCounts: [DebuggerLogicalBreakpointID: UInt64]? = nil,
        lastCallbackSequence: UInt64? = nil,
        callbackRecords: [DebuggerBreakpointCallbackRecord]? = nil,
        callbackDropCount: UInt64? = nil,
        isTerminal: Bool? = nil,
        isInvalidated: Bool? = nil
    ) {
        snapshot = DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: snapshot.sessionEpoch,
            authorityRevision: authorityRevision ?? snapshot.authorityRevision,
            backendInventoryRevision: backendInventoryRevision ?? snapshot.backendInventoryRevision,
            desiredCatalogCoordinate: desiredCatalogCoordinate ?? snapshot.desiredCatalogCoordinate,
            resolutionObservation: updated(
                resolutionObservation,
                current: snapshot.resolutionObservation
            ),
            currentStop: updated(currentStop, current: snapshot.currentStop),
            lifecycleHighWater: lifecycleHighWater ?? snapshot.lifecycleHighWater,
            stopHighWater: stopHighWater ?? snapshot.stopHighWater,
            adapterGeneration: updated(adapterGeneration, current: snapshot.adapterGeneration),
            observedPID: updated(observedPID, current: snapshot.observedPID),
            observedStopID: updated(observedStopID, current: snapshot.observedStopID),
            resolutions: resolutions ?? snapshot.resolutions,
            backendState: backendState ?? snapshot.backendState,
            ownedLocations: canonicalLocations(ownedLocations ?? snapshot.ownedLocations),
            pendingPlan: updated(pendingPlan, current: snapshot.pendingPlan),
            observedHitCounts: observedHitCounts ?? snapshot.observedHitCounts,
            lastCallbackSequence: lastCallbackSequence ?? snapshot.lastCallbackSequence,
            callbackRecords: callbackRecords ?? snapshot.callbackRecords,
            callbackDropCount: callbackDropCount ?? snapshot.callbackDropCount,
            isTerminal: isTerminal ?? snapshot.isTerminal,
            isInvalidated: isInvalidated ?? snapshot.isInvalidated
        )
    }

    private func updated<Value>(
        _ update: DebuggerBreakpointReducerUpdate<Value>,
        current: Value
    ) -> Value {
        return switch update {
        case .keep: current
        case .set(let value): value
        }
    }

    private func canonicalResolutions(
        _ values: [DebuggerLogicalBreakpointResolution]
    ) -> [DebuggerLogicalBreakpointResolution] {
        values.sorted { lhs, rhs in
            let left = withUnsafeBytes(of: lhs.logicalID.rawValue.uuid) { Array($0) }
            let right = withUnsafeBytes(of: rhs.logicalID.rawValue.uuid) { Array($0) }
            return left.lexicographicallyPrecedes(right)
        }
    }

    private func canonicalLocations(
        _ values: [DebuggerOwnedBackendBreakpointLocation]
    ) -> [DebuggerOwnedBackendBreakpointLocation] {
        Array(Set(values)).sorted {
            if $0.backendBreakpointID != $1.backendBreakpointID {
                return $0.backendBreakpointID < $1.backendBreakpointID
            }
            return $0.backendLocationID < $1.backendLocationID
        }
    }

    private func hasRuntimeAddressCollision(
        _ bindings: [DebuggerDesiredBreakpointBinding]
    ) -> Bool {
        Dictionary(grouping: bindings, by: \.runtimeAddress).values.contains {
            Set($0.map(\.id)).count > 1
        }
    }
}

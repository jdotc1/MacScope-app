import Foundation

/// A generation-fenced, bounded callback box for Ghostty's private external-I/O ABI.
///
/// The box deliberately has no GhosttyKit dependency. A future C trampoline recovers
/// `CallbackBox` from its userdata, copies the callback payload through these methods, and maps
/// `Admission` to the ABI result. Work is drained on a private serial queue; no callback invokes
/// an actor, store, or XPC client on its call stack.
final class MacScopeGhosttyExternalIOBridge: @unchecked Sendable {
    struct Limits: Equatable, Sendable {
        static let `default` = Limits(
            maximumWriteByteCount: 1 << 20,
            maximumPendingWorkCount: 64,
            maximumPendingByteCount: 4 << 20,
            maximumGridDimension: 16_384,
            maximumPixelDimension: 1_048_576
        )

        let maximumWriteByteCount: Int
        let maximumPendingWorkCount: Int
        let maximumPendingByteCount: Int
        let maximumGridDimension: Int
        let maximumPixelDimension: Int

        init(
            maximumWriteByteCount: Int,
            maximumPendingWorkCount: Int,
            maximumPendingByteCount: Int,
            maximumGridDimension: Int = 16_384,
            maximumPixelDimension: Int = 1_048_576
        ) {
            self.maximumWriteByteCount = min(max(1, maximumWriteByteCount), 1 << 20)
            self.maximumPendingWorkCount = min(max(1, maximumPendingWorkCount), 64)
            self.maximumPendingByteCount = min(max(1, maximumPendingByteCount), 4 << 20)
            self.maximumGridDimension = min(max(1, maximumGridDimension), 16_384)
            self.maximumPixelDimension = min(max(1, maximumPixelDimension), 1_048_576)
        }
    }

    enum Admission: Equatable, Sendable {
        case accepted
        case backpressured
        case closed
        case invalid
    }

    struct ResizeProposal: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    enum CloseReason: Equatable, Sendable {
        case hostExited
        case hostSignaled
        case hostClosed
        case surfaceRequest
    }

    enum HealthEvent: Equatable, Hashable, Sendable {
        case feedReady
        case outputBackpressured
        case outputOverflow
        case outputSuppressed
    }

    enum Work: Equatable, Sendable {
        case write(generation: MacScopeGhosttySurfaceGeneration, bytes: Data)
        case resize(generation: MacScopeGhosttySurfaceGeneration, proposal: ResizeProposal)
        case close(generation: MacScopeGhosttySurfaceGeneration, reason: CloseReason)
        case health(
            generation: MacScopeGhosttySurfaceGeneration,
            event: HealthEvent,
            detail: UInt64
        )

        fileprivate var byteCount: Int {
            switch self {
            case let .write(_, bytes): bytes.count
            case .resize, .close, .health: 0
            }
        }

        fileprivate var callbackKind: MacScopeGhosttySurfaceDiagnostics.CallbackKind {
            switch self {
            case .write: .write
            case .resize: .resize
            case .close: .close
            case .health: .health
            }
        }
    }

    typealias Handler = @Sendable (Work) -> Void
    typealias WriteCapacityRecovered = @Sendable (
        MacScopeGhosttySurfaceGeneration
    ) -> Void

    /// This is the object retained through the C ABI userdata lifetime. It references the locked
    /// state, never the surface host or bridge facade, so the ABI edge cannot form a host cycle.
    final class CallbackBox: @unchecked Sendable {
        let generation: MacScopeGhosttySurfaceGeneration
        private let state: State

        fileprivate init(generation: MacScopeGhosttySurfaceGeneration, state: State) {
            self.generation = generation
            self.state = state
        }

        func copyWrite(_ bytes: UnsafeRawPointer?, count: Int) -> Admission {
            state.copyWrite(bytes, count: count, callbackGeneration: generation)
        }

        func proposeResize(_ proposal: ResizeProposal) -> Admission {
            state.enqueue(
                .resize(generation: generation, proposal: proposal),
                callbackGeneration: generation
            )
        }

        func requestClose(_ reason: CloseReason) -> Admission {
            state.enqueue(
                .close(generation: generation, reason: reason),
                callbackGeneration: generation
            )
        }

        func reportHealth(_ event: HealthEvent, detail: UInt64) -> Admission {
            state.enqueue(
                .health(generation: generation, event: event, detail: detail),
                callbackGeneration: generation
            )
        }
    }

    struct Snapshot: Equatable, Sendable {
        enum Lifecycle: Equatable, Sendable {
            case active
            case retired
            case callbacksInvalidated
        }

        let lifecycle: Lifecycle
        let pendingWorkCount: Int
        let pendingByteCount: Int
    }

    let generation: MacScopeGhosttySurfaceGeneration
    let callbackBox: CallbackBox

    private let state: State

    init(
        generation: MacScopeGhosttySurfaceGeneration,
        limits: Limits = .default,
        diagnostics: MacScopeGhosttySurfaceDiagnostics = MacScopeGhosttySurfaceDiagnostics(),
        deliveryQueue: DispatchQueue? = nil,
        writeCapacityRecovered: @escaping WriteCapacityRecovered = { _ in },
        handler: @escaping Handler
    ) {
        self.generation = generation
        // Always own a serial queue. An injected queue is only a scheduling target; allowing a
        // concurrent queue to become the drain queue would invalidate the single-lease and
        // queue-specific reentrancy invariants below.
        let queue = DispatchQueue(
            label: "org.macscope.app.GhosttySurface.external-io.\(generation.generation)",
            qos: .userInteractive,
            target: deliveryQueue
        )
        let state = State(
            generation: generation,
            limits: limits,
            diagnostics: diagnostics,
            deliveryQueue: queue,
            writeCapacityRecovered: writeCapacityRecovered,
            handler: handler
        )
        self.state = state
        self.callbackBox = CallbackBox(generation: generation, state: state)
    }

    /// Retires only the exact active generation. A stale host cannot retire its replacement.
    @discardableResult
    func retire(generation candidate: MacScopeGhosttySurfaceGeneration) -> Bool {
        state.retire(generation: candidate)
    }

    /// Breaks callback ownership after the native surface has stopped invoking callbacks.
    /// This is idempotent and makes a retained `CallbackBox` fail closed.
    func invalidateCallbacks() {
        state.invalidateCallbacks()
    }

    func snapshot() -> Snapshot {
        state.snapshot()
    }

    deinit {
        state.retireAndInvalidate()
    }
}

private extension MacScopeGhosttyExternalIOBridge {
    final class State: @unchecked Sendable {
        private enum Lifecycle {
            case active
            case retiring
            case retired
            case invalidatingCallbacks
            case callbacksInvalidated
        }

        private struct DeliveryLease {
            let epoch: UInt64
            let work: Work
            let handler: Handler
            let writeCapacityRecovered: WriteCapacityRecovered?
        }

        private let generation: MacScopeGhosttySurfaceGeneration
        private let limits: Limits
        private let diagnostics: MacScopeGhosttySurfaceDiagnostics
        private let deliveryQueue: DispatchQueue
        private let deliveryQueueKey = DispatchSpecificKey<UInt8>()
        private let condition = NSCondition()

        private var lifecycle: Lifecycle = .active
        private var epoch: UInt64 = 1
        private var pending: [Work] = []
        private var ordinaryPendingWorkCount = 0
        private var pendingByteCount = 0
        private var drainScheduled = false
        private var activeDeliveryCount = 0
        private var activeDeliveryEpoch: UInt64?
        private var pendingRetirementDiagnostic: (work: Int, bytes: Int)?
        private var pendingInvalidationDiagnostic: (work: Int, bytes: Int)?
        private var pendingHealthEvents: Set<HealthEvent> = []
        private var activeHealthEvent: HealthEvent?
        private var latchedTerminalHealthEvents: Set<HealthEvent> = []
        private var pendingResize = false
        private var activeResize = false
        private var pendingWriteCapacityRequirement: Int?
        private var closeWasAccepted = false
        private var handler: Handler?
        private var writeCapacityRecovered: WriteCapacityRecovered?

        init(
            generation: MacScopeGhosttySurfaceGeneration,
            limits: Limits,
            diagnostics: MacScopeGhosttySurfaceDiagnostics,
            deliveryQueue: DispatchQueue,
            writeCapacityRecovered: @escaping WriteCapacityRecovered,
            handler: @escaping Handler
        ) {
            self.generation = generation
            self.limits = limits
            self.diagnostics = diagnostics
            self.deliveryQueue = deliveryQueue
            self.handler = handler
            self.writeCapacityRecovered = writeCapacityRecovered
            // Ordinary work obeys the configured limit. Four coalesced health edges and the
            // at-most-once close callback plus one latest-value resize have fixed reserved slots
            // because their native ABI callbacks are void and therefore cannot observe or retry
            // ordinary backpressure.
            pending.reserveCapacity(limits.maximumPendingWorkCount + 6)
            deliveryQueue.setSpecific(key: deliveryQueueKey, value: 1)
        }

        func copyWrite(
            _ bytes: UnsafeRawPointer?,
            count: Int,
            callbackGeneration: MacScopeGhosttySurfaceGeneration
        ) -> Admission {
            guard count >= 0,
                  count <= limits.maximumWriteByteCount,
                  count <= limits.maximumPendingByteCount
            else {
                recordRejected(.write, .invalidPayload)
                return .invalid
            }
            guard count == 0 || bytes != nil else {
                recordRejected(.write, .invalidPayload)
                return .invalid
            }
            if count == 0 {
                return admitNoOp(callbackGeneration: callbackGeneration)
            }

            let outcome: Admission
            let rejection: MacScopeGhosttySurfaceDiagnostics.CallbackRejection?
            var shouldScheduleDrain = false

            condition.lock()
            if callbackGeneration != generation {
                outcome = .closed
                rejection = .staleGeneration
            } else {
                switch lifecycle {
                case .retiring, .retired:
                    outcome = .closed
                    rejection = .retired
                case .invalidatingCallbacks, .callbacksInvalidated:
                    outcome = .closed
                    rejection = .callbacksInvalidated
                case .active:
                    if closeWasAccepted {
                        outcome = .closed
                        rejection = .retired
                    } else if ordinaryPendingWorkCount >= limits.maximumPendingWorkCount
                        || count > limits.maximumPendingByteCount - pendingByteCount
                    {
                        outcome = .backpressured
                        rejection = .queueFull
                        pendingWriteCapacityRequirement = max(
                            pendingWriteCapacityRequirement ?? 0,
                            count
                        )
                    } else {
                        // Admission is linearized before allocation, and the bounded copy remains
                        // under the same lock. Rejected, stale, and retired callbacks never touch
                        // caller memory; concurrently admitted writes cannot amplify allocations
                        // or commit out of callback order.
                        let copied = Data(bytes: bytes!, count: count)
                        pending.append(.write(
                            generation: callbackGeneration,
                            bytes: copied
                        ))
                        ordinaryPendingWorkCount += 1
                        pendingByteCount += count
                        outcome = .accepted
                        rejection = nil
                        if !drainScheduled {
                            drainScheduled = true
                            shouldScheduleDrain = true
                        }
                    }
                }
            }
            recordAdmissionLocked(.write, rejection: rejection)
            condition.unlock()

            if shouldScheduleDrain {
                scheduleDrain()
            }
            return outcome
        }

        func enqueue(_ work: Work, callbackGeneration: MacScopeGhosttySurfaceGeneration) -> Admission {
            precondition(work.byteCount == 0, "writes must use pre-copy admission")
            let outcome: Admission
            let rejection: MacScopeGhosttySurfaceDiagnostics.CallbackRejection?
            var shouldScheduleDrain = false

            condition.lock()
            if callbackGeneration != generation {
                outcome = .closed
                rejection = .staleGeneration
            } else {
                switch lifecycle {
                case .retiring, .retired:
                    outcome = .closed
                    rejection = .retired
                case .invalidatingCallbacks, .callbacksInvalidated:
                    outcome = .closed
                    rejection = .callbacksInvalidated
                case .active:
                    if closeWasAccepted {
                        if case .close = work {
                            outcome = .accepted
                            rejection = nil
                        } else {
                            outcome = .closed
                            rejection = .retired
                        }
                    } else if !isValid(work) {
                        outcome = .invalid
                        rejection = .invalidPayload
                    } else if coalesceControlWorkLocked(work) {
                        outcome = .accepted
                        rejection = nil
                    } else if isReservedControlWork(work) {
                        pending.append(work)
                        outcome = .accepted
                        rejection = nil
                        if !drainScheduled {
                            drainScheduled = true
                            shouldScheduleDrain = true
                        }
                    } else if ordinaryPendingWorkCount >= limits.maximumPendingWorkCount {
                        outcome = .backpressured
                        rejection = .queueFull
                    } else {
                        pending.append(work)
                        ordinaryPendingWorkCount += 1
                        outcome = .accepted
                        rejection = nil
                        if !drainScheduled {
                            drainScheduled = true
                            shouldScheduleDrain = true
                        }
                    }
                }
            }
            recordAdmissionLocked(work.callbackKind, rejection: rejection)
            condition.unlock()

            if shouldScheduleDrain {
                scheduleDrain()
            }
            return outcome
        }

        func retire(generation candidate: MacScopeGhosttySurfaceGeneration) -> Bool {
            condition.lock()
            guard candidate == generation else {
                condition.unlock()
                return false
            }

            switch lifecycle {
            case .retiring, .invalidatingCallbacks:
                // A handler may retire or invalidate reentrantly. Any later exact-generation
                // retirement still acts as a synchronous fence before its caller may install a
                // replacement, even though only the first caller owns the transition result.
                waitForOlderDeliveryLeasesLocked()
                finishLifecycleTransitionIfQuiescentLocked()
                condition.unlock()
                return false
            case .retired, .callbacksInvalidated:
                condition.unlock()
                return false
            case .active:
                break
            }

            lifecycle = .retiring
            advanceEpochLocked()
            let cancelled = cancelPendingLocked()
            pendingRetirementDiagnostic = cancelled

            waitForOlderDeliveryLeasesLocked()
            finishLifecycleTransitionIfQuiescentLocked()
            condition.unlock()
            return true
        }

        func invalidateCallbacks() {
            condition.lock()
            switch lifecycle {
            case .callbacksInvalidated:
                condition.unlock()
                return
            case .invalidatingCallbacks:
                break
            case .active, .retiring, .retired:
                lifecycle = .invalidatingCallbacks
                advanceEpochLocked()
                pendingInvalidationDiagnostic = cancelPendingLocked()
                handler = nil
                writeCapacityRecovered = nil
            }

            waitForOlderDeliveryLeasesLocked()
            finishLifecycleTransitionIfQuiescentLocked()
            condition.unlock()
        }

        func retireAndInvalidate() {
            _ = retire(generation: generation)
            invalidateCallbacks()
        }

        func snapshot() -> Snapshot {
            condition.lock()
            defer { condition.unlock() }
            let publicLifecycle: Snapshot.Lifecycle = switch lifecycle {
            case .active: .active
            case .retiring, .retired: .retired
            case .invalidatingCallbacks, .callbacksInvalidated: .callbacksInvalidated
            }
            return Snapshot(
                lifecycle: publicLifecycle,
                pendingWorkCount: pending.count,
                pendingByteCount: pendingByteCount
            )
        }

        private func admitNoOp(
            callbackGeneration: MacScopeGhosttySurfaceGeneration
        ) -> Admission {
            let outcome: Admission
            let rejection: MacScopeGhosttySurfaceDiagnostics.CallbackRejection?

            condition.lock()
            if callbackGeneration != generation {
                outcome = .closed
                rejection = .staleGeneration
            } else {
                switch lifecycle {
                case .active:
                    if closeWasAccepted {
                        outcome = .closed
                        rejection = .retired
                    } else {
                        outcome = .accepted
                        rejection = nil
                    }
                case .retiring, .retired:
                    outcome = .closed
                    rejection = .retired
                case .invalidatingCallbacks, .callbacksInvalidated:
                    outcome = .closed
                    rejection = .callbacksInvalidated
                }
            }
            recordAdmissionLocked(.write, rejection: rejection)
            condition.unlock()
            return outcome
        }

        private func drain() {
            while true {
                let lease: DeliveryLease?

                condition.lock()
                if lifecycle == .active, !pending.isEmpty, let handler {
                    let work = pending.removeFirst()
                    if !isReservedControlWork(work) {
                        ordinaryPendingWorkCount -= 1
                    }
                    pendingByteCount -= work.byteCount
                    beginActiveControlLocked(work)
                    activeDeliveryCount += 1
                    activeDeliveryEpoch = epoch
                    lease = DeliveryLease(
                        epoch: epoch,
                        work: work,
                        handler: handler,
                        writeCapacityRecovered: takeWriteCapacityRecoveryLocked()
                    )
                } else {
                    drainScheduled = false
                    lease = nil
                }
                condition.unlock()

                guard let lease else { return }
                lease.writeCapacityRecovered?(generation)
                lease.handler(lease.work)
                finishDelivery(lease)
            }
        }

        private func cancelPendingLocked() -> (work: Int, bytes: Int) {
            let cancelled = (pending.count, pendingByteCount)
            for work in pending {
                releasePendingControlLocked(work)
            }
            pending.removeAll(keepingCapacity: true)
            ordinaryPendingWorkCount = 0
            pendingByteCount = 0
            pendingWriteCapacityRequirement = nil
            return cancelled
        }

        private func finishDelivery(_ lease: DeliveryLease) {
            condition.lock()
            precondition(activeDeliveryCount == 1)
            precondition(activeDeliveryEpoch == lease.epoch)
            activeDeliveryCount = 0
            activeDeliveryEpoch = nil
            finishActiveControlLocked(lease.work)
            finishLifecycleTransitionIfQuiescentLocked()
            condition.broadcast()
            condition.unlock()
        }

        private func waitForOlderDeliveryLeasesLocked() {
            let reentrantLeaseCount = DispatchQueue.getSpecific(key: deliveryQueueKey) == nil ? 0 : 1
            while activeDeliveryCount > reentrantLeaseCount {
                condition.wait()
            }
        }

        private func finishLifecycleTransitionIfQuiescentLocked() {
            guard activeDeliveryCount == 0 else { return }
            switch lifecycle {
            case .retiring:
                lifecycle = .retired
            case .invalidatingCallbacks:
                lifecycle = .callbacksInvalidated
            case .active, .retired, .callbacksInvalidated:
                break
            }
            recordLifecycleDiagnosticsLocked()
            condition.broadcast()
        }

        private func recordLifecycleDiagnosticsLocked() {
            if let cancelled = pendingRetirementDiagnostic {
                diagnostics.record(.bridgeRetired(
                    cancelledWorkCount: cancelled.work,
                    cancelledByteCount: cancelled.bytes
                ))
                pendingRetirementDiagnostic = nil
            }
            if let cancelled = pendingInvalidationDiagnostic {
                diagnostics.record(.callbacksInvalidated(
                    cancelledWorkCount: cancelled.work,
                    cancelledByteCount: cancelled.bytes
                ))
                pendingInvalidationDiagnostic = nil
            }
        }

        private func advanceEpochLocked() {
            if epoch < UInt64.max {
                epoch += 1
            }
        }

        private func scheduleDrain() {
            deliveryQueue.async { [weak self] in self?.drain() }
        }

        private func recordRejected(
            _ kind: MacScopeGhosttySurfaceDiagnostics.CallbackKind,
            _ rejection: MacScopeGhosttySurfaceDiagnostics.CallbackRejection
        ) {
            condition.lock()
            diagnostics.record(.callbackRejected(kind, rejection))
            condition.unlock()
        }

        private func recordAdmissionLocked(
            _ kind: MacScopeGhosttySurfaceDiagnostics.CallbackKind,
            rejection: MacScopeGhosttySurfaceDiagnostics.CallbackRejection?
        ) {
            if let rejection {
                diagnostics.record(.callbackRejected(kind, rejection))
            } else {
                diagnostics.record(.callbackAccepted(kind))
            }
        }

        private func coalesceControlWorkLocked(_ work: Work) -> Bool {
            switch work {
            case let .health(_, event, _):
                if isTerminalHealth(event), latchedTerminalHealthEvents.contains(event) {
                    return true
                }
                if pendingHealthEvents.contains(event) {
                    // Transient readiness/backpressure signals are level-like. While one is
                    // actively delivering, retain one bounded follow-up; further callbacks
                    // refresh that follow-up and move it to their true position in callback
                    // order. Terminal health remains an exact-once latch above.
                    if !isTerminalHealth(event),
                       let index = pending.firstIndex(where: {
                           if case let .health(_, pendingEvent, _) = $0 {
                               return pendingEvent == event
                           }
                           return false
                       })
                    {
                        pending.remove(at: index)
                        pending.append(work)
                    }
                    return true
                }
                pendingHealthEvents.insert(event)
                if isTerminalHealth(event) {
                    latchedTerminalHealthEvents.insert(event)
                }
                return false
            case .close:
                if closeWasAccepted {
                    return true
                }
                closeWasAccepted = true
                pendingWriteCapacityRequirement = nil
                return false
            case .resize:
                if pendingResize,
                   let index = pending.firstIndex(where: {
                       if case .resize = $0 { return true }
                       return false
                   })
                {
                    // Resize is latest-value state. Move the replacement to the callback-order
                    // tail so intervening writes remain ordered before the newest geometry.
                    pending.remove(at: index)
                    pending.append(work)
                    return true
                }
                pendingResize = true
                return false
            case .write:
                return false
            }
        }

        private func beginActiveControlLocked(_ work: Work) {
            switch work {
            case let .health(_, event, _):
                pendingHealthEvents.remove(event)
                precondition(activeHealthEvent == nil)
                activeHealthEvent = event
            case .resize:
                precondition(pendingResize)
                pendingResize = false
                precondition(!activeResize)
                activeResize = true
            case .write, .close:
                break
            }
        }

        private func finishActiveControlLocked(_ work: Work) {
            switch work {
            case let .health(_, event, _):
                precondition(activeHealthEvent == event)
                activeHealthEvent = nil
            case .resize:
                precondition(activeResize)
                activeResize = false
            case .write, .close:
                break
            }
        }

        private func releasePendingControlLocked(_ work: Work) {
            switch work {
            case let .health(_, event, _):
                pendingHealthEvents.remove(event)
            case .resize:
                pendingResize = false
            case .write, .close:
                break
            }
        }

        private func isReservedControlWork(_ work: Work) -> Bool {
            switch work {
            case .resize, .close, .health: true
            case .write: false
            }
        }

        private func takeWriteCapacityRecoveryLocked() -> WriteCapacityRecovered? {
            guard lifecycle == .active,
                  !closeWasAccepted,
                  ordinaryPendingWorkCount < limits.maximumPendingWorkCount,
                  let requiredBytes = pendingWriteCapacityRequirement,
                  requiredBytes <= limits.maximumPendingByteCount - pendingByteCount,
                  let writeCapacityRecovered
            else { return nil }
            pendingWriteCapacityRequirement = nil
            return writeCapacityRecovered
        }

        private func isTerminalHealth(_ event: HealthEvent) -> Bool {
            switch event {
            case .outputOverflow, .outputSuppressed: true
            case .feedReady, .outputBackpressured: false
            }
        }

        private func isValid(_ work: Work) -> Bool {
            switch work {
            case .write:
                return true
            case let .resize(_, proposal):
                return proposal.columns > 0
                    && proposal.rows > 0
                    && proposal.columns <= limits.maximumGridDimension
                    && proposal.rows <= limits.maximumGridDimension
                    && proposal.pixelWidth >= 0
                    && proposal.pixelHeight >= 0
                    && proposal.pixelWidth <= limits.maximumPixelDimension
                    && proposal.pixelHeight <= limits.maximumPixelDimension
            case .close, .health:
                return true
            }
        }
    }
}

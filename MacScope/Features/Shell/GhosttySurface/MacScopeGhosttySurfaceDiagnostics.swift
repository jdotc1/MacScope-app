import Foundation

/// Content-free, process-local evidence for terminal-surface boundaries.
///
/// Renderer entries add only exact UUID/PID/generation bindings to closed enums and bounded
/// counts. Terminal bytes, titles, paths, URLs, and other user-controlled strings never enter
/// this ledger.
final class MacScopeGhosttySurfaceDiagnostics: @unchecked Sendable {
    static let defaultCapacity = 64
    static let maximumCapacity = 256
    static let maximumRendererWaitDuration: TimeInterval = 30

    /// Process-local observation only. Renderer selection and construction remain owned by the
    /// SwiftUI surface; this ledger can neither select, create, nor retire a renderer.
    static let rendererEvidenceShared = MacScopeGhosttySurfaceDiagnostics()

    enum CallbackKind: Equatable, Sendable {
        case write
        case resize
        case close
        case health
    }

    enum CallbackRejection: Equatable, Sendable {
        case retired
        case staleGeneration
        case invalidPayload
        case queueFull
        case callbacksInvalidated
    }

    enum ActionCategory: Equatable, Sendable {
        case render
        case wakeup
        case selection
        case pointer
        case titleMetadata
        case workingDirectoryMetadata
        case bell
        case close
        case hyperlink
        case clipboardControl
        case applicationLifecycle
    }

    enum ActionRejection: Equatable, Sendable {
        case applicationAuthority
        case clipboardControlDisabled
        case indirectActivation
        case invalidActivation
    }

    enum RendererRequestedMode: Equatable, Hashable, Sendable {
        case unselected
        case ghosttyFullSurface
        case macScopeGhosttyVTGrid
    }

    enum RendererObservedMode: Equatable, Hashable, Sendable {
        case ghosttyFullSurface
        case macScopeGhosttyVTGrid
        case transcriptOnlyFallback
    }

    enum RendererFallbackReason: Equatable, Hashable, Sendable {
        case none
        case rendererSelectionUnavailable
        case compileTimeUnavailable
        case recoveryOverride
        case runtimeUnavailable
        case runtimeFailure
        case rendererCoordinateUnavailable
        case fullSurfaceFactoryUnavailable
        case transcriptUnavailable
        case transcriptRejected
        case fullSurfaceFactoryRejected
        case legacyGridNotCompiled
    }

    /// A real legacy grid does not allocate a native-surface generation. Keeping that state
    /// explicit avoids inventing one while still binding evidence to the exact broker process.
    enum RendererGenerationBinding: Equatable, Hashable, Sendable {
        case notAllocated
        case exact(UInt64)
    }

    struct RendererBinding: Equatable, Hashable, Sendable {
        let sessionID: UUID
        let requestID: UUID
        let shellBrokerProcessIdentifier: Int32
        let generation: RendererGenerationBinding

        init?(
            sessionID: UUID,
            requestID: UUID,
            shellBrokerProcessIdentifier: Int32,
            generation: RendererGenerationBinding
        ) {
            guard shellBrokerProcessIdentifier > 0 else { return nil }
            self.sessionID = sessionID
            self.requestID = requestID
            self.shellBrokerProcessIdentifier = shellBrokerProcessIdentifier
            self.generation = generation
        }
    }

    struct RendererObservation: Equatable, Hashable, Sendable {
        let binding: RendererBinding
        let requestedMode: RendererRequestedMode
        let observedMode: RendererObservedMode
        let fallbackReason: RendererFallbackReason
    }

    enum RendererLifecycle: Equatable, Hashable, Sendable {
        case instantiated
        case retired
    }

    struct RendererEvidence: Equatable, Hashable, Sendable {
        let observation: RendererObservation
        let lifecycle: RendererLifecycle
    }

    struct RendererEntry: Equatable, Sendable {
        let sequence: UInt64
        let evidence: RendererEvidence
    }

    fileprivate struct RendererProcessCoordinate: Equatable, Hashable, Sendable {
        let sessionID: UUID
        let requestID: UUID
        let shellBrokerProcessIdentifier: Int32

        init(_ binding: RendererBinding) {
            sessionID = binding.sessionID
            requestID = binding.requestID
            shellBrokerProcessIdentifier = binding.shellBrokerProcessIdentifier
        }
    }

    /// Bounded current truth is independent of the bounded observation history. Evicting history
    /// must not resurrect a retired binding or erase an exact-generation high-water mark.
    fileprivate struct RendererProcessState: Equatable, Sendable {
        let coordinate: RendererProcessCoordinate
        var highestExactGeneration: UInt64?
        var currentEvidence: RendererEvidence
        var latestExactEvidence: RendererEvidence?
        var didRecordLegacyGrid: Bool
        var lastSequence: UInt64
    }

    enum RendererResolution: Equatable, Sendable {
        case instantiated(RendererEvidence)
        case retired(RendererEvidence)
        case shellBrokerProcessIdentifierMismatch(observed: Int32)
        case staleGeneration(observed: RendererGenerationBinding)
        case noInstantiatedRenderer
    }

    enum RendererRecordDisposition: Equatable, Sendable {
        case recorded(sequence: UInt64)
        case duplicate
        case shellBrokerProcessIdentifierMismatch(observed: Int32)
        case staleGeneration(observed: RendererGenerationBinding)
        case retired
        case superseded
        case noInstantiatedRenderer
        case invalidObservation
    }

    /// Serializes the renderer authority represented by nested SwiftUI lifecycle callbacks.
    ///
    /// SwiftUI may deliver a replacement's `onAppear` before the prior subtree's `onDisappear`.
    /// The coordinator therefore keys ownership by the exact binding, retires the observation it
    /// actually admitted before admitting a different binding, and ignores a late disappearance
    /// from the superseded subtree. Callback admission samples both the local mount and the shared
    /// evidence ledger, then releases its lock before invoking application code. The owning seam
    /// performs the final execution-time session/request/PID/generation fence.
    final class RendererLifecycleCoordinator: @unchecked Sendable {
        private struct ActiveRenderer {
            let binding: RendererBinding
            let observation: RendererObservation
        }

        private let diagnostics: MacScopeGhosttySurfaceDiagnostics
        private let lock = NSLock()
        private var activeRenderer: ActiveRenderer?

        init(diagnostics: MacScopeGhosttySurfaceDiagnostics) {
            self.diagnostics = diagnostics
        }

        @discardableResult
        func rendererDidAppear(_ observation: RendererObservation?) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard let observation else {
                retireActiveRendererLocked()
                return false
            }
            if let activeRenderer, activeRenderer.binding == observation.binding {
                // Metadata changes do not create a second renderer. Retain the exact observation
                // that was admitted so its eventual retirement cannot conflict with the ledger.
                guard diagnostics.rendererSnapshot().resolution(for: observation.binding)
                    == .instantiated(RendererEvidence(
                        observation: activeRenderer.observation,
                        lifecycle: .instantiated
                    ))
                else {
                    self.activeRenderer = nil
                    return false
                }
                return true
            }

            retireActiveRendererLocked()
            guard case .recorded = diagnostics.recordRendererInstantiation(observation) else {
                return false
            }
            activeRenderer = ActiveRenderer(
                binding: observation.binding,
                observation: observation
            )
            return true
        }

        func rendererDidDisappear(binding: RendererBinding?) {
            lock.lock()
            defer { lock.unlock() }
            guard let binding, activeRenderer?.binding == binding else { return }
            retireActiveRendererLocked()
        }

        func withAuthorizedCallback(
            for binding: RendererBinding?,
            _ operation: () -> Void
        ) {
            guard let binding else { return }
            lock.lock()
            let observation = activeRenderer?.binding == binding
                ? activeRenderer?.observation
                : nil
            lock.unlock()
            guard let observation,
                  diagnostics.rendererSnapshot().resolution(for: binding) == .instantiated(
                    RendererEvidence(observation: observation, lifecycle: .instantiated)
                  )
            else { return }
            operation()
        }

        private func retireActiveRendererLocked() {
            guard let activeRenderer else { return }
            self.activeRenderer = nil
            diagnostics.recordRendererRetirement(activeRenderer.observation)
        }
    }

    struct RendererSnapshot: Equatable, Sendable {
        let entries: [RendererEntry]
        let totalRecorded: UInt64
        let evictedEntryCount: UInt64
        fileprivate let processStates: [RendererProcessState]

        func resolution(for binding: RendererBinding) -> RendererResolution {
            MacScopeGhosttySurfaceDiagnostics.rendererResolution(
                processStates: processStates,
                for: binding
            )
        }
    }

    enum Event: Equatable, Sendable {
        case callbackAccepted(CallbackKind)
        case callbackRejected(CallbackKind, CallbackRejection)
        case bridgeRetired(cancelledWorkCount: Int, cancelledByteCount: Int)
        case callbacksInvalidated(cancelledWorkCount: Int, cancelledByteCount: Int)
        case actionAccepted(ActionCategory)
        case actionRejected(ActionCategory, ActionRejection)
    }

    struct Entry: Equatable, Sendable {
        let sequence: UInt64
        let event: Event
    }

    struct Snapshot: Equatable, Sendable {
        let entries: [Entry]
        let totalRecorded: UInt64
        let evictedEntryCount: UInt64
    }

    private let capacity: Int
    private let condition = NSCondition()
    private var entries: [Entry] = []
    private var totalRecorded: UInt64 = 0
    private var evictedEntryCount: UInt64 = 0
    private var rendererEntries: [RendererEntry] = []
    private var rendererTotalRecorded: UInt64 = 0
    private var rendererEvictedEntryCount: UInt64 = 0
    private var rendererProcessStates: [RendererProcessState] = []
    private var rendererEvictedCoordinates = Set<RendererProcessCoordinate>()
    private var rendererAdmissionSealed = false

    init(capacity: Int = defaultCapacity) {
        self.capacity = min(max(1, capacity), Self.maximumCapacity)
        entries.reserveCapacity(self.capacity)
        rendererEntries.reserveCapacity(self.capacity)
        rendererProcessStates.reserveCapacity(self.capacity)
        rendererEvictedCoordinates.reserveCapacity(self.capacity)
    }

    func record(_ event: Event) {
        condition.lock()
        defer { condition.unlock() }

        totalRecorded = Self.incrementingSaturating(totalRecorded)
        if entries.count == capacity {
            entries.removeFirst()
            evictedEntryCount = Self.incrementingSaturating(evictedEntryCount)
        }
        entries.append(Entry(sequence: totalRecorded, event: event))
    }

    func snapshot() -> Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(
            entries: entries,
            totalRecorded: totalRecorded,
            evictedEntryCount: evictedEntryCount
        )
    }

    @discardableResult
    func recordRendererInstantiation(
        _ observation: RendererObservation
    ) -> RendererRecordDisposition {
        condition.lock()
        defer { condition.unlock() }

        guard Self.isValid(observation) else { return .invalidObservation }
        if let observed = Self.mismatchedShellBrokerProcessIdentifier(
            in: rendererProcessStates,
            evictedCoordinates: rendererEvictedCoordinates,
            for: observation.binding
        ) {
            return .shellBrokerProcessIdentifierMismatch(observed: observed)
        }

        let coordinate = RendererProcessCoordinate(observation.binding)
        if let stateIndex = rendererProcessStates.firstIndex(where: {
            $0.coordinate == coordinate
        }) {
            let state = rendererProcessStates[stateIndex]
            switch observation.binding.generation {
            case let .exact(generation):
                if let highest = state.highestExactGeneration, highest > generation {
                    return .staleGeneration(observed: .exact(highest))
                }
                if let latest = state.latestExactEvidence,
                   latest.observation.binding == observation.binding {
                    switch latest.lifecycle {
                    case .retired:
                        return .retired
                    case .instantiated where latest.observation == observation:
                        return .duplicate
                    case .instantiated:
                        return .superseded
                    }
                }
                if state.highestExactGeneration == generation { return .superseded }
            case .notAllocated:
                if state.currentEvidence.observation.binding == observation.binding {
                    switch state.currentEvidence.lifecycle {
                    case .retired:
                        return .retired
                    case .instantiated where state.currentEvidence.observation == observation:
                        return .duplicate
                    case .instantiated:
                        return .superseded
                    }
                }
                guard !state.didRecordLegacyGrid else { return .superseded }
                if state.currentEvidence.observation.observedMode == .ghosttyFullSurface,
                   state.currentEvidence.lifecycle == .instantiated {
                    return .superseded
                }
            }
        } else {
            guard !rendererEvictedCoordinates.contains(coordinate),
                  !rendererAdmissionSealed
            else { return .noInstantiatedRenderer }
            makeRoomForRendererProcessStateLocked()
        }

        return appendRendererEvidenceLocked(RendererEvidence(
            observation: observation,
            lifecycle: .instantiated
        ))
    }

    @discardableResult
    func recordRendererRetirement(
        _ observation: RendererObservation
    ) -> RendererRecordDisposition {
        condition.lock()
        defer { condition.unlock() }

        guard Self.isValid(observation) else { return .invalidObservation }
        if let observed = Self.mismatchedShellBrokerProcessIdentifier(
            in: rendererProcessStates,
            evictedCoordinates: rendererEvictedCoordinates,
            for: observation.binding
        ) {
            return .shellBrokerProcessIdentifierMismatch(observed: observed)
        }

        let coordinate = RendererProcessCoordinate(observation.binding)
        guard let state = rendererProcessStates.first(where: {
            $0.coordinate == coordinate
        }) else {
            return .noInstantiatedRenderer
        }
        let latest: RendererEvidence
        switch observation.binding.generation {
        case let .exact(generation):
            if let highest = state.highestExactGeneration, highest > generation {
                return .staleGeneration(observed: .exact(highest))
            }
            guard let exact = state.latestExactEvidence,
                  exact.observation.binding == observation.binding
            else { return .noInstantiatedRenderer }
            guard state.currentEvidence.observation.binding == observation.binding else {
                return .superseded
            }
            latest = exact
        case .notAllocated:
            guard state.currentEvidence.observation.binding == observation.binding else {
                if state.didRecordLegacyGrid,
                   let highest = state.highestExactGeneration {
                    return .staleGeneration(observed: .exact(highest))
                }
                return state.didRecordLegacyGrid ? .superseded : .noInstantiatedRenderer
            }
            latest = state.currentEvidence
        }
        guard latest.lifecycle == .instantiated else { return .retired }
        guard latest.observation == observation else { return .superseded }

        return appendRendererEvidenceLocked(RendererEvidence(
            observation: observation,
            lifecycle: .retired
        ))
    }

    func rendererSnapshot() -> RendererSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return rendererSnapshotLocked()
    }

    /// Waits for positive evidence or a fail-closed terminal result. The caller-provided duration
    /// is clamped so a malformed smoke request cannot create an unbounded process-local wait.
    func waitForRendererEvidence(
        for binding: RendererBinding,
        timeout: TimeInterval
    ) -> RendererResolution {
        condition.lock()
        defer { condition.unlock() }

        let duration = Self.boundedRendererWaitDuration(timeout)
        let deadline = Date(timeIntervalSinceNow: duration)
        while true {
            let resolution = Self.rendererResolution(
                processStates: rendererProcessStates,
                for: binding
            )
            if resolution != .noInstantiatedRenderer { return resolution }
            guard duration > 0, condition.wait(until: deadline) else {
                return .noInstantiatedRenderer
            }
        }
    }

    private func appendRendererEvidenceLocked(
        _ evidence: RendererEvidence
    ) -> RendererRecordDisposition {
        rendererTotalRecorded = Self.incrementingSaturating(rendererTotalRecorded)
        if rendererEntries.count == capacity {
            rendererEntries.removeFirst()
            rendererEvictedEntryCount = Self.incrementingSaturating(
                rendererEvictedEntryCount
            )
        }
        rendererEntries.append(RendererEntry(
            sequence: rendererTotalRecorded,
            evidence: evidence
        ))
        updateRendererProcessStateLocked(
            with: evidence,
            sequence: rendererTotalRecorded
        )
        condition.broadcast()
        return .recorded(sequence: rendererTotalRecorded)
    }

    private func updateRendererProcessStateLocked(
        with evidence: RendererEvidence,
        sequence: UInt64
    ) {
        let binding = evidence.observation.binding
        let coordinate = RendererProcessCoordinate(binding)
        if let index = rendererProcessStates.firstIndex(where: {
            $0.coordinate == coordinate
        }) {
            var state = rendererProcessStates[index]
            switch binding.generation {
            case let .exact(generation):
                state.highestExactGeneration = max(
                    state.highestExactGeneration ?? generation,
                    generation
                )
                state.latestExactEvidence = evidence
            case .notAllocated:
                state.didRecordLegacyGrid = true
            }
            state.currentEvidence = evidence
            state.lastSequence = sequence
            rendererProcessStates[index] = state
            return
        }

        let exactGeneration: UInt64?
        let latestExactEvidence: RendererEvidence?
        let didRecordLegacyGrid: Bool
        switch binding.generation {
        case let .exact(generation):
            exactGeneration = generation
            latestExactEvidence = evidence
            didRecordLegacyGrid = false
        case .notAllocated:
            exactGeneration = nil
            latestExactEvidence = nil
            didRecordLegacyGrid = true
        }
        rendererProcessStates.append(RendererProcessState(
            coordinate: coordinate,
            highestExactGeneration: exactGeneration,
            currentEvidence: evidence,
            latestExactEvidence: latestExactEvidence,
            didRecordLegacyGrid: didRecordLegacyGrid,
            lastSequence: sequence
        ))
    }

    private func makeRoomForRendererProcessStateLocked() {
        guard rendererProcessStates.count == capacity,
              let evictionIndex = rendererProcessStates.indices.min(by: {
                  rendererProcessStates[$0].lastSequence
                    < rendererProcessStates[$1].lastSequence
              })
        else { return }

        let evicted = rendererProcessStates.remove(at: evictionIndex).coordinate
        if rendererEvictedCoordinates.count < capacity {
            rendererEvictedCoordinates.insert(evicted)
        } else {
            // Once bounded tombstones fill, unknown coordinates can no longer be distinguished
            // from evicted ones. Seal only new-coordinate admission; retained states still retire.
            rendererAdmissionSealed = true
        }
    }

    private func rendererSnapshotLocked() -> RendererSnapshot {
        RendererSnapshot(
            entries: rendererEntries,
            totalRecorded: rendererTotalRecorded,
            evictedEntryCount: rendererEvictedEntryCount,
            processStates: rendererProcessStates
        )
    }

    private static func isValid(_ observation: RendererObservation) -> Bool {
        guard observation.binding.shellBrokerProcessIdentifier > 0 else { return false }
        switch observation.observedMode {
        case .ghosttyFullSurface:
            guard observation.requestedMode == .ghosttyFullSurface,
                  case let .exact(generation) = observation.binding.generation,
                  generation > 0
            else { return false }
            return observation.fallbackReason == .none
        case .macScopeGhosttyVTGrid:
            guard observation.binding.generation == .notAllocated else { return false }
            if observation.requestedMode == .ghosttyFullSurface {
                return observation.fallbackReason != .none
            }
            if observation.requestedMode == .unselected {
                return observation.fallbackReason == .rendererSelectionUnavailable
            }
            return true
        case .transcriptOnlyFallback:
            return false
        }
    }

    private static func rendererResolution(
        processStates: [RendererProcessState],
        for binding: RendererBinding
    ) -> RendererResolution {
        if let observed = mismatchedShellBrokerProcessIdentifier(
            in: processStates,
            evictedCoordinates: [],
            for: binding
        ) {
            return .shellBrokerProcessIdentifierMismatch(observed: observed)
        }
        let coordinate = RendererProcessCoordinate(binding)
        guard let state = processStates.first(where: {
            $0.coordinate == coordinate
        }) else {
            return .noInstantiatedRenderer
        }

        switch binding.generation {
        case let .exact(generation):
            if let highest = state.highestExactGeneration, highest > generation {
                return .staleGeneration(observed: .exact(highest))
            }
            guard let evidence = state.latestExactEvidence,
                  evidence.observation.binding == binding
            else { return .noInstantiatedRenderer }
            return resolution(for: evidence)
        case .notAllocated:
            if state.currentEvidence.observation.binding == binding {
                return resolution(for: state.currentEvidence)
            }
            if state.didRecordLegacyGrid,
               let highest = state.highestExactGeneration {
                return .staleGeneration(observed: .exact(highest))
            }
            return .noInstantiatedRenderer
        }
    }

    private static func mismatchedShellBrokerProcessIdentifier(
        in processStates: [RendererProcessState],
        evictedCoordinates: Set<RendererProcessCoordinate>,
        for binding: RendererBinding
    ) -> Int32? {
        let retained = processStates
            .filter {
                $0.coordinate.sessionID == binding.sessionID
                    && $0.coordinate.requestID == binding.requestID
            }
            .max(by: { $0.lastSequence < $1.lastSequence })?
            .coordinate.shellBrokerProcessIdentifier
        if let retained, retained != binding.shellBrokerProcessIdentifier {
            return retained
        }
        if let evicted = evictedCoordinates.first(where: {
            $0.sessionID == binding.sessionID
                && $0.requestID == binding.requestID
                && $0.shellBrokerProcessIdentifier
                    != binding.shellBrokerProcessIdentifier
        }) {
            return evicted.shellBrokerProcessIdentifier
        }
        return nil
    }

    private static func resolution(for evidence: RendererEvidence) -> RendererResolution {
        switch evidence.lifecycle {
        case .instantiated: return .instantiated(evidence)
        case .retired: return .retired(evidence)
        }
    }

    private static func boundedRendererWaitDuration(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite, timeout > 0 else { return 0 }
        return min(timeout, maximumRendererWaitDuration)
    }

    private static func incrementingSaturating(_ value: UInt64) -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        return overflow ? UInt64.max : next
    }
}

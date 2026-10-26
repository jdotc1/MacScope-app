import Foundation

struct DebuggerLocalProcessCatalogEntry: Hashable, Sendable, Identifiable {
    let selection: DebuggerLocalProcessCatalogSelection
    let displayName: String
    let parentProcessID: Int32
    let dynamicState: DebuggerLocalProcessDynamicState
    let eligibility: DebuggerLocalProcessEligibility

    var id: DebuggerLocalProcessCatalogSelection { selection }
    var fingerprint: DebuggerLocalProcessCatalogFingerprint { selection.fingerprint }
}

struct DebuggerLocalProcessDiscoveryLimits: Hashable, Sendable {
    let maximumCandidateCount: Int
    let maximumRetainedRows: Int
    let maximumConcurrentObservers: Int
    let publicationBatchSize: Int

    init(
        maximumCandidateCount: Int = 8_192,
        maximumRetainedRows: Int = 4_096,
        maximumConcurrentObservers: Int = 8,
        publicationBatchSize: Int = 32
    ) {
        self.maximumCandidateCount = max(1, min(maximumCandidateCount, 16_384))
        self.maximumRetainedRows = max(1, min(maximumRetainedRows, 8_192))
        self.maximumConcurrentObservers = max(1, min(maximumConcurrentObservers, 32))
        self.publicationBatchSize = max(1, min(publicationBatchSize, 256))
    }
}

struct DebuggerLocalProcessDiscoveryMetrics: Hashable, Sendable {
    let candidateCount: Int
    let retainedCount: Int
    let droppedCount: Int
    let firstResultLatency: Duration?
    let completeRefreshLatency: Duration
}

struct DebuggerLocalProcessDiscoverySnapshot: Sendable {
    let generation: UInt64
    let entries: [DebuggerLocalProcessCatalogEntry]
    let isRefreshing: Bool
    let isStale: Bool
    let metrics: DebuggerLocalProcessDiscoveryMetrics?
    let aggregateDenials: [DebuggerLocalAttachDenial: Int]
}

actor DebuggerLocalProcessDiscoveryService {
    typealias UpdateHandler = @Sendable (DebuggerLocalProcessDiscoverySnapshot) async -> Void
    private typealias AuthorizationResult =
        DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationGrant>

    private struct AuthorizationOperation {
        let generation: UInt64
        let task: Task<AuthorizationResult, Never>
    }

    private let observer: DebuggerLocalProcessIdentityObserver
    private let limits: DebuggerLocalProcessDiscoveryLimits
    private var generation: UInt64 = 0
    private var authorizationToken: UInt64 = 0
    private var authorizationOperations: [UInt64: AuthorizationOperation] = [:]
    private(set) var currentSnapshot = DebuggerLocalProcessDiscoverySnapshot(
        generation: 0,
        entries: [],
        isRefreshing: false,
        isStale: false,
        metrics: nil,
        aggregateDenials: [:]
    )

    init(
        observer: DebuggerLocalProcessIdentityObserver,
        limits: DebuggerLocalProcessDiscoveryLimits = .init()
    ) {
        self.observer = observer
        self.limits = limits
    }

    func refresh(
        policy: DebuggerLocalProcessObservationPolicy,
        onUpdate: @escaping UpdateHandler
    ) async -> DebuggerLocalProcessDiscoverySnapshot {
        let retainedEntries = currentSnapshot.entries
        let requestedGeneration = advanceGeneration()
        let clock = ContinuousClock()
        let startedAt = clock.now
        var entries: [DebuggerLocalProcessCatalogEntry] = []
        var denials: [DebuggerLocalAttachDenial: Int] = [:]
        var firstResultLatency: Duration?

        currentSnapshot = DebuggerLocalProcessDiscoverySnapshot(
            generation: requestedGeneration,
            entries: retainedEntries,
            isRefreshing: true,
            isStale: true,
            metrics: nil,
            aggregateDenials: [:]
        )
        await onUpdate(currentSnapshot)
        guard requestedGeneration == generation else {
            return currentSnapshot
        }
        if Task.isCancelled {
            currentSnapshot = cancelledSnapshot(
                generation: requestedGeneration,
                entries: retainedEntries,
                startedAt: startedAt,
                clock: clock
            )
            await onUpdate(currentSnapshot)
            return currentSnapshot
        }

        let processResult = await observer.processIDs()
        guard requestedGeneration == generation else { return currentSnapshot }
        if Task.isCancelled {
            currentSnapshot = cancelledSnapshot(
                generation: requestedGeneration,
                entries: retainedEntries,
                startedAt: startedAt,
                clock: clock
            )
            await onUpdate(currentSnapshot)
            return currentSnapshot
        }
        guard case let .resolved(rawProcessIDs) = processResult else {
            let denial = processResult.denial ?? .unstableSnapshot
            currentSnapshot = unavailableEnumerationSnapshot(
                generation: requestedGeneration,
                entries: retainedEntries,
                denial: denial,
                startedAt: startedAt,
                clock: clock
            )
            await onUpdate(currentSnapshot)
            return currentSnapshot
        }

        let processIDs = Array(
            Set(rawProcessIDs.filter { $0 > 0 })
                .sorted()
                .prefix(limits.maximumCandidateCount)
        )
        let candidateCount = processIDs.count
        var completedSincePublication = 0
        let catalogObserver = self.observer

        await withTaskGroup(
            of: (Int32, DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogObservation>).self
        ) { group in
            var iterator = processIDs.makeIterator()
            for _ in 0..<min(limits.maximumConcurrentObservers, processIDs.count) {
                guard let processID = iterator.next() else { break }
                group.addTask {
                    (
                        processID,
                        await catalogObserver.observeCatalog(
                            processID: processID,
                            policy: policy
                        )
                    )
                }
            }

            while let (_, result) = await group.next() {
                guard requestedGeneration == generation, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let nextProcessID = iterator.next() {
                    group.addTask {
                        (
                            nextProcessID,
                            await catalogObserver.observeCatalog(
                                processID: nextProcessID,
                                policy: policy
                            )
                        )
                    }
                }

                switch result {
                case let .resolved(observation):
                    if entries.count < limits.maximumRetainedRows,
                       let selection = DebuggerLocalProcessCatalogSelection(
                           discoveryGeneration: requestedGeneration,
                           fingerprint: observation.fingerprint
                       ) {
                        entries.append(
                            DebuggerLocalProcessCatalogEntry(
                                selection: selection,
                                displayName: observation.displayName,
                                parentProcessID: observation.parentProcessID,
                                dynamicState: observation.dynamicState,
                                eligibility: observation.eligibility
                            )
                        )
                        if firstResultLatency == nil {
                            firstResultLatency = startedAt.duration(to: clock.now)
                        }
                    }
                case let .ineligible(denial), let .unknown(denial):
                    denials[denial, default: 0] += 1
                }
                completedSincePublication += 1

                if completedSincePublication >= limits.publicationBatchSize {
                    completedSincePublication = 0
                    entries.sort { $0.fingerprint.processID < $1.fingerprint.processID }
                    currentSnapshot = DebuggerLocalProcessDiscoverySnapshot(
                        generation: requestedGeneration,
                        entries: entries,
                        isRefreshing: true,
                        isStale: false,
                        metrics: nil,
                        aggregateDenials: denials
                    )
                    await onUpdate(currentSnapshot)
                    guard requestedGeneration == generation else {
                        group.cancelAll()
                        return
                    }
                }
            }
        }

        guard requestedGeneration == generation else {
            return currentSnapshot
        }
        if Task.isCancelled {
            currentSnapshot = cancelledSnapshot(
                generation: requestedGeneration,
                entries: currentSnapshot.entries,
                startedAt: startedAt,
                clock: clock
            )
            await onUpdate(currentSnapshot)
            return currentSnapshot
        }
        entries.sort { $0.fingerprint.processID < $1.fingerprint.processID }
        let droppedCount = max(0, candidateCount - entries.count)
        currentSnapshot = DebuggerLocalProcessDiscoverySnapshot(
            generation: requestedGeneration,
            entries: entries,
            isRefreshing: false,
            isStale: false,
            metrics: DebuggerLocalProcessDiscoveryMetrics(
                candidateCount: candidateCount,
                retainedCount: entries.count,
                droppedCount: droppedCount,
                firstResultLatency: firstResultLatency,
                completeRefreshLatency: startedAt.duration(to: clock.now)
            ),
            aggregateDenials: denials
        )
        await onUpdate(currentSnapshot)
        return currentSnapshot
    }

    func authorize(
        selection: DebuggerLocalProcessCatalogSelection,
        policy: DebuggerLocalProcessObservationPolicy
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationGrant> {
        let acceptedGeneration = generation
        guard selection.discoveryGeneration == acceptedGeneration,
              currentSnapshot.entries.contains(where: {
                  $0.selection == selection && $0.eligibility.isAttachable
              }),
              !currentSnapshot.isStale else {
            return .unknown(.identityChanged)
        }
        return await runAuthorization(
            selection: selection,
            policy: policy,
            acceptedGeneration: acceptedGeneration
        )
    }

    func resolveManualProcessID(
        _ processID: Int32,
        policy: DebuggerLocalProcessObservationPolicy
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationGrant> {
        if generation == 0 {
            _ = advanceGeneration()
            currentSnapshot = DebuggerLocalProcessDiscoverySnapshot(
                generation: generation,
                entries: [],
                isRefreshing: false,
                isStale: false,
                metrics: nil,
                aggregateDenials: [:]
            )
        }
        let acceptedGeneration = generation
        guard acceptedGeneration > 0, !Task.isCancelled else { return .unknown(.timeout) }
        let catalogResult = await observer.observeCatalog(processID: processID, policy: policy)
        guard case let .resolved(catalog) = catalogResult else {
            return catalogResult.forwardingFailure()
        }
        guard catalog.eligibility.isAttachable,
              let selection = DebuggerLocalProcessCatalogSelection(
                  discoveryGeneration: acceptedGeneration,
                  fingerprint: catalog.fingerprint
              ) else {
            return catalog.eligibility.denial.map {
                .ineligible($0)
            } ?? .unknown(.unstableSnapshot)
        }
        guard acceptedGeneration == generation, !Task.isCancelled else {
            return Task.isCancelled ? .unknown(.timeout) : .unknown(.identityChanged)
        }
        return await runAuthorization(
            selection: selection,
            policy: policy,
            acceptedGeneration: acceptedGeneration
        )
    }

    private func advanceGeneration() -> UInt64 {
        for operation in authorizationOperations.values {
            operation.task.cancel()
        }
        authorizationOperations.removeAll()
        generation &+= 1
        if generation == 0 { generation = 1 }
        return generation
    }

    private func runAuthorization(
        selection: DebuggerLocalProcessCatalogSelection,
        policy: DebuggerLocalProcessObservationPolicy,
        acceptedGeneration: UInt64
    ) async -> AuthorizationResult {
        authorizationToken &+= 1
        if authorizationToken == 0 { authorizationToken = 1 }
        let token = authorizationToken
        let identityObserver = observer
        let task = Task {
            await identityObserver.authorize(selection: selection, policy: policy)
        }
        authorizationOperations[token] = AuthorizationOperation(
            generation: acceptedGeneration,
            task: task
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if authorizationOperations[token]?.generation == acceptedGeneration {
            authorizationOperations[token] = nil
        }
        guard acceptedGeneration == generation else {
            return .unknown(.identityChanged)
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        return result
    }

    private func cancelledSnapshot(
        generation: UInt64,
        entries: [DebuggerLocalProcessCatalogEntry],
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> DebuggerLocalProcessDiscoverySnapshot {
        DebuggerLocalProcessDiscoverySnapshot(
            generation: generation,
            entries: entries,
            isRefreshing: false,
            isStale: true,
            metrics: DebuggerLocalProcessDiscoveryMetrics(
                candidateCount: 0,
                retainedCount: entries.count,
                droppedCount: 0,
                firstResultLatency: nil,
                completeRefreshLatency: startedAt.duration(to: clock.now)
            ),
            aggregateDenials: [.timeout: 1]
        )
    }

    private func unavailableEnumerationSnapshot(
        generation: UInt64,
        entries: [DebuggerLocalProcessCatalogEntry],
        denial: DebuggerLocalAttachDenial,
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> DebuggerLocalProcessDiscoverySnapshot {
        DebuggerLocalProcessDiscoverySnapshot(
            generation: generation,
            entries: entries,
            isRefreshing: false,
            isStale: true,
            metrics: DebuggerLocalProcessDiscoveryMetrics(
                candidateCount: 0,
                retainedCount: entries.count,
                droppedCount: 0,
                firstResultLatency: nil,
                completeRefreshLatency: startedAt.duration(to: clock.now)
            ),
            aggregateDenials: [denial: 1]
        )
    }
}

private extension DebuggerLocalProcessResolution {
    func forwardingFailure<NewValue: Sendable>()
        -> DebuggerLocalProcessResolution<NewValue> {
        switch self {
        case .resolved:
            .unknown(.unstableSnapshot)
        case let .ineligible(denial):
            .ineligible(denial)
        case let .unknown(denial):
            .unknown(denial)
        }
    }
}

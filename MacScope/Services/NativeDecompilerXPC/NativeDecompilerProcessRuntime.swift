import Foundation

struct NativeDecompilerProcessRuntimeConfiguration: Equatable, Sendable {
    let maximumQueuedEntries: Int
    let maximumQueuedWeight: UInt64
    let maximumValidatedCacheEntries: Int
    let maximumValidatedCacheBytes: UInt64
    let maximumAdmissionRecords: Int

    init(
        maximumQueuedEntries: Int = 32,
        maximumQueuedWeight: UInt64 = 64 * 1_048_576,
        maximumValidatedCacheEntries: Int = 64,
        maximumValidatedCacheBytes: UInt64 = 64 * 1_048_576,
        maximumAdmissionRecords: Int = 256
    ) {
        precondition(maximumQueuedEntries >= 0)
        precondition(maximumValidatedCacheEntries >= 0)
        precondition(maximumAdmissionRecords >= 0)
        self.maximumQueuedEntries = maximumQueuedEntries
        self.maximumQueuedWeight = maximumQueuedWeight
        self.maximumValidatedCacheEntries = maximumValidatedCacheEntries
        self.maximumValidatedCacheBytes = maximumValidatedCacheBytes
        self.maximumAdmissionRecords = maximumAdmissionRecords
    }
}

enum NativeDecompilerProcessRuntimeExecutionSource: Equatable, Sendable {
    case executed(FairSingleLaneSubmissionDisposition)
    case validatedCache
}

struct NativeDecompilerProcessRuntimeExecution: Equatable, Sendable {
    let completion: NativeDecompilerCompletion
    let source: NativeDecompilerProcessRuntimeExecutionSource
}

enum NativeDecompilerProcessRuntimeError: Error, Equatable, Sendable {
    case staleEpoch
    case runtimeTransitionInProgress
    case runtimeAuthorityUnavailable
    case shutDown
}

enum NativeDecompilerRuntimeValidationError: Error, Equatable, Sendable {
    case runtimeAuthorityMismatch
    case replyRuntimeIdentityMismatch
}

enum NativeDecompilerRuntimeTransitionCause: Equatable, Sendable {
    case appOwnedReattestation
    case interrupted
    case invalidated
}

enum NativeDecompilerProcessRuntimeAuthorityState: Equatable, Sendable {
    case unattested
    case ready(NativeDecompilerRuntimeIdentity)
    case transitioning
    case unavailable
    case shutDown
}

enum NativeDecompilerProcessRuntimeEventKind: String, Equatable, Sendable {
    case admitted
    case cacheHit
    case cacheStored
    case epochReplaced
    case shutDown
}

/// Privacy-safe process-runtime telemetry. It deliberately cannot carry binary bytes, paths,
/// symbols, pseudocode, request identifiers, or canonical digests.
struct NativeDecompilerProcessRuntimeEvent: Equatable, Sendable {
    let kind: NativeDecompilerProcessRuntimeEventKind
    let epoch: UInt64
    let queuedEntryCount: Int
    let queuedWeight: UInt64
}

struct NativeDecompilerProcessRuntimeSnapshot: Equatable, Sendable {
    let epoch: UInt64
    let scheduler: FairSingleLaneSchedulerSnapshot
    let validatedCacheEntryCount: Int
    let validatedCacheByteCount: UInt64
    let admissionRecords: [NativeDecompilerProcessAdmissionRecord]
    let authorityState: NativeDecompilerProcessRuntimeAuthorityState
    let isShutDown: Bool
}

enum NativeDecompilerProcessAdmissionState: Equatable, Sendable {
    case completed(FairSingleLaneSubmissionDisposition)
    case validatedCache
    case cancelled
    case rejected
}

/// Internal bounded ledger used for lifecycle fencing and deterministic diagnostics. Unlike the
/// operational event stream it may retain the canonical digest and owner token, but it is never
/// logged or persisted and exposes no paths, bytes, symbols, or rendered output.
struct NativeDecompilerProcessAdmissionRecord: Equatable, Sendable {
    let sequence: UInt64
    let epoch: UInt64
    let owner: UUID
    let requestSHA256: String
    let state: NativeDecompilerProcessAdmissionState
}

/// The application-process authority for native execution admission.
///
/// One runtime is shared by every document window. It admits unique canonical requests through a
/// single fair lane, coalesces identical requests across owners, removes only a cancelled caller's
/// waiter, and caches only validated successful replies. Runtime epoch replacement atomically
/// installs a fresh lane before draining the old one, so late work from an interrupted XPC process
/// cannot publish into the successor epoch.
actor NativeDecompilerProcessRuntime {
    typealias OwnerID = UUID
    typealias Operation = @Sendable (
        _ submission: NativeDecompilerSubmission,
        _ executionToken: UUID,
        _ expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity
    ) async throws -> NativeDecompilerCompletion
    typealias EventSink = @Sendable (NativeDecompilerProcessRuntimeEvent) -> Void

    private struct RequestKey: Hashable, Sendable {
        let requestSHA256: String
        /// A result computed for one context omission set is never served for another.
        let contextOmissionSHA256: String
        let schemaVersion: UInt32
        let analysisInputFingerprintSHA256: String?
        let targetProfileID: String
        let targetContextProfileSHA256: String
        let epoch: UInt64
    }

    private struct CachedSuccess: Sendable {
        let success: NativeDecompilerWireSuccess
        let encodedByteCount: UInt64
    }

    /// Validated cache authority includes both the complete canonical request digest and every
    /// runtime/package identity scalar returned by the signed provider, plus the process epoch.
    private struct CacheKey: Hashable, Sendable {
        let request: RequestKey
        let runtimeIdentity: NativeDecompilerRuntimeIdentity
    }

    private let configuration: NativeDecompilerProcessRuntimeConfiguration
    private let authorityProvider: any NativeDecompilerRuntimeAuthorityProviding
    private let operation: Operation
    private let eventSink: EventSink
    private var scheduler: FairSingleLaneWorkScheduler<OwnerID, RequestKey, NativeDecompilerCompletion>
    private var epoch: UInt64 = 1
    private var validatedCache: [CacheKey: CachedSuccess] = [:]
    private var validatedCacheByteCount: UInt64 = 0
    private var cacheKeyByRequest: [RequestKey: CacheKey] = [:]
    private var cacheRecency: [CacheKey] = []
    private var admissionRecords: [NativeDecompilerProcessAdmissionRecord] = []
    private var nextAdmissionSequence: UInt64 = 0
    private var authorityState: NativeDecompilerProcessRuntimeAuthorityState = .unattested
    private var authorityGeneration: UInt64 = 0
    private var initialAuthorityAttestation:
        (generation: UInt64, epoch: UInt64, task: Task<NativeDecompilerRuntimeIdentity, any Error>)?
    private var initialAuthorityAttestationWaiterCount = 0
    private var latestLifecycleConnectionGeneration: UInt64 = 0
    private var isShutDown = false
    private var shutdownTask: Task<Void, Never>?
    /// Why the last epoch was replaced; `.interrupted` means the service process went away.
    private var lastTransitionCause: NativeDecompilerRuntimeTransitionCause?

    init(
        authorityProvider: any NativeDecompilerRuntimeAuthorityProviding,
        configuration: NativeDecompilerProcessRuntimeConfiguration = .init(),
        initialEpoch: UInt64 = 1,
        initialAdmissionSequence: UInt64 = 0,
        eventSink: @escaping EventSink = { _ in },
        operation: @escaping Operation
    ) {
        precondition(initialEpoch > 0)
        self.authorityProvider = authorityProvider
        self.configuration = configuration
        self.eventSink = eventSink
        self.operation = operation
        epoch = initialEpoch
        nextAdmissionSequence = initialAdmissionSequence
        scheduler = Self.makeScheduler(configuration: configuration)
    }

    func submit(
        owner: OwnerID,
        submission: NativeDecompilerSubmission,
        queuedWeight: UInt64,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy = .allowValidatedCache
    ) async throws -> NativeDecompilerProcessRuntimeExecution {
        guard !isShutDown else { throw NativeDecompilerProcessRuntimeError.shutDown }
        let expectedRuntimeIdentity = try await runtimeAuthorityForAdmission()
        try Task.checkCancellation()
        guard !isShutDown else { throw NativeDecompilerProcessRuntimeError.shutDown }
        let submittedEpoch = epoch
        let key = RequestKey(
            requestSHA256: submission.projection.requestSHA256,
            contextOmissionSHA256: submission.projection.contextOmissionSHA256,
            schemaVersion: submission.projection.schemaVersion,
            analysisInputFingerprintSHA256:
                submission.analysisInputFingerprintSHA256,
            targetProfileID: submission.projection.target.profileID,
            targetContextProfileSHA256:
                submission.projection.target.contextProfileSHA256,
            epoch: submittedEpoch
        )
        if cacheLookupPolicy == .allowValidatedCache,
           let success = cachedSuccess(
            for: key,
            expectedRuntimeIdentity: expectedRuntimeIdentity
        ) {
            appendAdmission(owner: owner, request: key, state: .validatedCache)
            emit(.cacheHit, queuedEntryCount: 0, queuedWeight: 0)
            return NativeDecompilerProcessRuntimeExecution(
                completion: .ready(success),
                source: .validatedCache
            )
        }

        let lane = scheduler
        let executionToken = UUID()
        let operation = self.operation
        let admissionBox = NativeDecompilerAdmissionDispositionBox()
        let startBox = NativeDecompilerOperationStartBox()
        let completion: NativeDecompilerCompletion
        do {
            completion = try await lane.submit(
                owner: owner,
                key: key,
                queuedWeight: queuedWeight,
                admission: { admission in
                    admissionBox.record(admission.disposition)
                    self.eventSink(
                        NativeDecompilerProcessRuntimeEvent(
                            kind: .admitted,
                            epoch: submittedEpoch,
                            queuedEntryCount: admission.queuedEntryCount,
                            queuedWeight: admission.queuedWeight
                        )
                    )
                },
                operation: {
                    try await self.validateCurrentAdmission(
                        epoch: submittedEpoch,
                        expectedRuntimeIdentity: expectedRuntimeIdentity
                    )
                    startBox.record(ContinuousClock.now)
                    let completion = try await operation(
                        submission,
                        executionToken,
                        expectedRuntimeIdentity
                    )
                    try await self.validateCurrentCompletion(
                        completion,
                        epoch: submittedEpoch,
                        expectedRuntimeIdentity: expectedRuntimeIdentity
                    )
                    await self.storeIfValidatedSuccess(
                        completion,
                        for: key,
                        expectedRuntimeIdentity: expectedRuntimeIdentity
                    )
                    return completion
                }
            )
        } catch is CancellationError {
            appendAdmission(owner: owner, request: key, state: .cancelled)
            throw CancellationError()
        } catch let error as FairSingleLaneSchedulerError where error == .shutDown {
            appendAdmission(owner: owner, request: key, state: .rejected)
            if let timedOut = serviceDeadlineTermination(submission: submission, startedAt: startBox.value) {
                return timedOut
            }
            throw NativeDecompilerProcessRuntimeError.staleEpoch
        } catch {
            appendAdmission(owner: owner, request: key, state: .rejected)
            if error as? NativeDecompilerProcessRuntimeError == .staleEpoch,
               let timedOut = serviceDeadlineTermination(submission: submission, startedAt: startBox.value) {
                return timedOut
            }
            throw error
        }
        guard !isShutDown, epoch == submittedEpoch else {
            if let timedOut = serviceDeadlineTermination(submission: submission, startedAt: startBox.value) {
                return timedOut
            }
            throw NativeDecompilerProcessRuntimeError.staleEpoch
        }
        let disposition = admissionBox.value ?? .started
        appendAdmission(owner: owner, request: key, state: .completed(disposition))
        return NativeDecompilerProcessRuntimeExecution(
            completion: completion,
            source: .executed(disposition)
        )
    }

    /// Closes admission, drains the old process lane, independently re-attests the bundle, and
    /// reopens only after a fresh epoch and authority have both been installed.
    func replaceEpoch(
        cause: NativeDecompilerRuntimeTransitionCause = .appOwnedReattestation,
        connectionGeneration: UInt64? = nil
    ) async {
        guard !isShutDown else { return }
        if let connectionGeneration {
            guard connectionGeneration > latestLifecycleConnectionGeneration else { return }
            latestLifecycleConnectionGeneration = connectionGeneration
        }
        guard advanceAuthorityGeneration() else {
            authorityState = .shutDown
            isShutDown = true
            emit(.shutDown, queuedEntryCount: 0, queuedWeight: 0)
            await Self.boundedShutdown(of: scheduler)
            return
        }
        let transitionGeneration = authorityGeneration
        lastTransitionCause = cause
        let retiredScheduler = scheduler
        authorityState = .transitioning
        initialAuthorityAttestation?.task.cancel()
        initialAuthorityAttestation = nil
        clearCache()
        await Self.boundedShutdown(of: retiredScheduler)
        guard !isShutDown,
              authorityState == .transitioning,
              authorityGeneration == transitionGeneration
        else { return }
        guard advanceEpoch() else {
            authorityState = .shutDown
            isShutDown = true
            emit(.shutDown, queuedEntryCount: 0, queuedWeight: 0)
            return
        }
        do {
            let authority = try await authorityProvider.attestRuntimeAuthority()
            guard !isShutDown,
                  authorityState == .transitioning,
                  authorityGeneration == transitionGeneration
            else { return }
            scheduler = Self.makeScheduler(configuration: configuration)
            authorityState = .ready(authority)
            emit(.epochReplaced, queuedEntryCount: 0, queuedWeight: 0)
        } catch {
            guard !isShutDown,
                  authorityState == .transitioning,
                  authorityGeneration == transitionGeneration
            else { return }
            authorityState = .unavailable
        }
    }

    func shutdown() async {
        let task = beginShutdown()
        await task.value
    }

    /// Installs the terminal admission/publication fence actor-atomically and returns the one
    /// process-owned drain task shared by every shutdown caller.
    func beginShutdown() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        isShutDown = true
        authorityState = .shutDown
        _ = advanceAuthorityGeneration()
        _ = advanceEpoch()
        initialAuthorityAttestation?.task.cancel()
        initialAuthorityAttestation = nil
        clearCache()
        emit(.shutDown, queuedEntryCount: 0, queuedWeight: 0)
        let lane = scheduler
        let task = Task { await Self.boundedShutdown(of: lane) }
        shutdownTask = task
        return task
    }

    func clearValidatedCache() {
        guard !isShutDown else { return }
        clearCache()
    }

    func trimValidatedCache(maximumEntries: Int, maximumBytes: UInt64) {
        guard !isShutDown else { return }
        let entryLimit = max(0, maximumEntries)
        while cacheRecency.count > entryLimit || validatedCacheByteCount > maximumBytes {
            guard let evicted = cacheRecency.first else { break }
            cacheRecency.removeFirst()
            removeCachedValue(forKey: evicted)
            if cacheKeyByRequest[evicted.request] == evicted {
                cacheKeyByRequest.removeValue(forKey: evicted.request)
            }
        }
    }

    func snapshot() async -> NativeDecompilerProcessRuntimeSnapshot {
        NativeDecompilerProcessRuntimeSnapshot(
            epoch: epoch,
            scheduler: await scheduler.snapshot(),
            validatedCacheEntryCount: validatedCache.count,
            validatedCacheByteCount: validatedCacheByteCount,
            admissionRecords: admissionRecords,
            authorityState: authorityState,
            isShutDown: isShutDown
        )
    }

    private static func makeScheduler(
        configuration: NativeDecompilerProcessRuntimeConfiguration
    ) -> FairSingleLaneWorkScheduler<OwnerID, RequestKey, NativeDecompilerCompletion> {
        FairSingleLaneWorkScheduler(
            maximumQueuedEntries: configuration.maximumQueuedEntries,
            maximumQueuedWeight: configuration.maximumQueuedWeight
        )
    }

    private func cachedSuccess(
        for request: RequestKey,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity
    ) -> NativeDecompilerWireSuccess? {
        let expectedKey = CacheKey(
            request: request,
            runtimeIdentity: expectedRuntimeIdentity
        )
        guard cacheKeyByRequest[request] == expectedKey,
              let cached = validatedCache[expectedKey],
              cached.success.availability.runtimeIdentity == expectedRuntimeIdentity,
              case let .ready(currentRuntimeIdentity) = authorityState,
              currentRuntimeIdentity == expectedRuntimeIdentity,
              request.epoch == epoch
        else { return nil }
        touch(expectedKey)
        return cached.success
    }

    private func storeIfValidatedSuccess(
        _ completion: NativeDecompilerCompletion,
        for request: RequestKey,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity
    ) {
        guard !isShutDown, request.epoch == epoch,
              case let .ready(currentRuntimeIdentity) = authorityState,
              currentRuntimeIdentity == expectedRuntimeIdentity,
              configuration.maximumValidatedCacheEntries > 0,
              configuration.maximumValidatedCacheBytes > 0,
              case let .ready(success) = completion,
              success.availability.available,
              success.availability.runtimeIdentity == expectedRuntimeIdentity
        else { return }
        guard let encoded = try? JSONEncoder().encode(success) else { return }
        let encodedByteCount = UInt64(encoded.count)
        guard encodedByteCount <= configuration.maximumValidatedCacheBytes else { return }
        let cacheKey = CacheKey(
            request: request,
            runtimeIdentity: expectedRuntimeIdentity
        )
        if let replaced = cacheKeyByRequest.updateValue(cacheKey, forKey: request),
           replaced != cacheKey
        {
            removeCachedValue(forKey: replaced)
            cacheRecency.removeAll { $0 == replaced }
        }
        removeCachedValue(forKey: cacheKey)
        validatedCache[cacheKey] = CachedSuccess(
            success: success,
            encodedByteCount: encodedByteCount
        )
        validatedCacheByteCount = Self.saturatingAdd(
            validatedCacheByteCount,
            encodedByteCount
        )
        touch(cacheKey)
        while cacheRecency.count > configuration.maximumValidatedCacheEntries
            || validatedCacheByteCount > configuration.maximumValidatedCacheBytes
        {
            let evicted = cacheRecency.removeFirst()
            removeCachedValue(forKey: evicted)
            if cacheKeyByRequest[evicted.request] == evicted {
                cacheKeyByRequest.removeValue(forKey: evicted.request)
            }
        }
        emit(.cacheStored, queuedEntryCount: 0, queuedWeight: 0)
    }

    private func touch(_ key: CacheKey) {
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
    }

    private func clearCache() {
        validatedCache.removeAll(keepingCapacity: true)
        validatedCacheByteCount = 0
        cacheKeyByRequest.removeAll(keepingCapacity: true)
        cacheRecency.removeAll(keepingCapacity: true)
    }

    private func removeCachedValue(forKey key: CacheKey) {
        guard let removed = validatedCache.removeValue(forKey: key) else { return }
        validatedCacheByteCount = validatedCacheByteCount >= removed.encodedByteCount
            ? validatedCacheByteCount - removed.encodedByteCount
            : 0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private func appendAdmission(
        owner: UUID,
        request: RequestKey,
        state: NativeDecompilerProcessAdmissionState
    ) {
        guard configuration.maximumAdmissionRecords > 0,
              nextAdmissionSequence < .max else { return }
        nextAdmissionSequence += 1
        admissionRecords.append(NativeDecompilerProcessAdmissionRecord(
            sequence: nextAdmissionSequence,
            epoch: request.epoch,
            owner: owner,
            requestSHA256: request.requestSHA256,
            state: state
        ))
        let overflow = admissionRecords.count - configuration.maximumAdmissionRecords
        if overflow > 0 { admissionRecords.removeFirst(overflow) }
    }

    private func advanceEpoch() -> Bool {
        guard epoch < .max else { return false }
        epoch += 1
        return true
    }

    private func advanceAuthorityGeneration() -> Bool {
        guard authorityGeneration < .max else { return false }
        authorityGeneration += 1
        return true
    }

    private func runtimeAuthorityForAdmission() async throws -> NativeDecompilerRuntimeIdentity {
        switch authorityState {
        case let .ready(identity):
            return identity
        case .transitioning:
            guard initialAuthorityAttestation != nil else {
                throw NativeDecompilerProcessRuntimeError.runtimeTransitionInProgress
            }
            return try await awaitInitialAuthorityAttestation()
        case .unavailable:
            throw NativeDecompilerProcessRuntimeError.runtimeAuthorityUnavailable
        case .shutDown:
            throw NativeDecompilerProcessRuntimeError.shutDown
        case .unattested:
            guard advanceAuthorityGeneration() else {
                authorityState = .shutDown
                isShutDown = true
                emit(.shutDown, queuedEntryCount: 0, queuedWeight: 0)
                throw NativeDecompilerProcessRuntimeError.shutDown
            }
            let attestationGeneration = authorityGeneration
            let attestationEpoch = epoch
            authorityState = .transitioning
            let attestationTask = Task { [authorityProvider] in
                try await authorityProvider.attestRuntimeAuthority()
            }
            initialAuthorityAttestation = (
                generation: attestationGeneration,
                epoch: attestationEpoch,
                task: attestationTask
            )
            return try await awaitInitialAuthorityAttestation()
        }
    }

    /// Coalesces only the cold-start attestation. Explicit epoch replacement clears this task
    /// before awaiting its replacement, so admissions during that transition still fail closed.
    private func awaitInitialAuthorityAttestation() async throws -> NativeDecompilerRuntimeIdentity {
        initialAuthorityAttestationWaiterCount += 1
        defer { initialAuthorityAttestationWaiterCount -= 1 }

        guard let pending = initialAuthorityAttestation else {
            switch authorityState {
            case let .ready(identity): return identity
            case .shutDown: throw NativeDecompilerProcessRuntimeError.shutDown
            case .unavailable: throw NativeDecompilerProcessRuntimeError.runtimeAuthorityUnavailable
            case .unattested, .transitioning:
                throw NativeDecompilerProcessRuntimeError.runtimeTransitionInProgress
            }
        }
        do {
            let identity = try await pending.task.value
            guard !isShutDown else { throw NativeDecompilerProcessRuntimeError.shutDown }
            guard authorityGeneration == pending.generation, epoch == pending.epoch else {
                throw NativeDecompilerProcessRuntimeError.staleEpoch
            }
            switch authorityState {
            case .transitioning:
                authorityState = .ready(identity)
                initialAuthorityAttestation = nil
                return identity
            case let .ready(current) where current == identity:
                return current
            case .shutDown:
                throw NativeDecompilerProcessRuntimeError.shutDown
            default:
                throw NativeDecompilerProcessRuntimeError.staleEpoch
            }
        } catch let error as NativeDecompilerProcessRuntimeError {
            guard !isShutDown else { throw NativeDecompilerProcessRuntimeError.shutDown }
            guard authorityGeneration == pending.generation, epoch == pending.epoch else {
                throw NativeDecompilerProcessRuntimeError.staleEpoch
            }
            switch authorityState {
            case .transitioning:
                authorityState = .unavailable
                initialAuthorityAttestation = nil
            case .unavailable:
                break
            case .shutDown:
                throw NativeDecompilerProcessRuntimeError.shutDown
            default:
                throw NativeDecompilerProcessRuntimeError.staleEpoch
            }
            throw error == .runtimeAuthorityUnavailable
                ? error
                : NativeDecompilerProcessRuntimeError.runtimeAuthorityUnavailable
        } catch {
            guard !isShutDown else { throw NativeDecompilerProcessRuntimeError.shutDown }
            guard authorityGeneration == pending.generation, epoch == pending.epoch else {
                throw NativeDecompilerProcessRuntimeError.staleEpoch
            }
            switch authorityState {
            case .transitioning:
                authorityState = .unavailable
                initialAuthorityAttestation = nil
            case .unavailable:
                break
            case .shutDown:
                throw NativeDecompilerProcessRuntimeError.shutDown
            default:
                throw NativeDecompilerProcessRuntimeError.staleEpoch
            }
            throw NativeDecompilerProcessRuntimeError.runtimeAuthorityUnavailable
        }
    }

    /// A request that was running when the service went away, and had outlived the service's
    /// own hard deadline, was killed by that deadline: report it as timed out, never as an
    /// epoch race (libjpeg `_encode_one_block` read "runtime-staleEpoch" on b15b1cb02).
    private func serviceDeadlineTermination(
        submission: NativeDecompilerSubmission,
        startedAt: ContinuousClock.Instant?
    ) -> NativeDecompilerProcessRuntimeExecution? {
        guard lastTransitionCause == .interrupted, let startedAt,
              let wait = submission.elapsedTimeBudget,
              let deadline = NativeDecompilerProductBudgetProfile.serviceHardDeadline(forClientWait: wait),
              ContinuousClock.now - startedAt >= deadline
        else { return nil }
        return NativeDecompilerProcessRuntimeExecution(
            completion: .terminal(.client(.timedOut)),
            source: .executed(.started)
        )
    }

    func initialAuthorityAttestationWaiterCountForTesting() -> Int {
        initialAuthorityAttestationWaiterCount
    }

    private func validateCurrentAdmission(
        epoch submittedEpoch: UInt64,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity
    ) throws {
        guard !isShutDown else { throw NativeDecompilerProcessRuntimeError.shutDown }
        guard epoch == submittedEpoch,
              case let .ready(currentRuntimeIdentity) = authorityState,
              currentRuntimeIdentity == expectedRuntimeIdentity
        else { throw NativeDecompilerProcessRuntimeError.staleEpoch }
    }

    private func validateCurrentCompletion(
        _ completion: NativeDecompilerCompletion,
        epoch submittedEpoch: UInt64,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity
    ) throws {
        try validateCurrentAdmission(
            epoch: submittedEpoch,
            expectedRuntimeIdentity: expectedRuntimeIdentity
        )
        guard case let .ready(success) = completion else { return }
        guard success.availability.available,
              success.availability.runtimeIdentity == expectedRuntimeIdentity
        else {
            throw NativeDecompilerRuntimeValidationError.replyRuntimeIdentityMismatch
        }
    }

    private nonisolated static func boundedShutdown(
        of lane: FairSingleLaneWorkScheduler<OwnerID, RequestKey, NativeDecompilerCompletion>
    ) async {
        let completion = NativeDecompilerBoundedShutdownCompletion()
        Task {
            await lane.shutdown()
            completion.finish()
        }
        await completion.wait(maximumDuration: .seconds(1))
    }

    private func emit(
        _ kind: NativeDecompilerProcessRuntimeEventKind,
        queuedEntryCount: Int,
        queuedWeight: UInt64
    ) {
        eventSink(NativeDecompilerProcessRuntimeEvent(
            kind: kind,
            epoch: epoch,
            queuedEntryCount: queuedEntryCount,
            queuedWeight: queuedWeight
        ))
    }
}

private final class NativeDecompilerOperationStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?

    var value: ContinuousClock.Instant? { lock.withLock { instant } }
    func record(_ value: ContinuousClock.Instant) { lock.withLock { instant = value } }
}

private final class NativeDecompilerBoundedShutdownCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func wait(maximumDuration: Duration) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !isFinished else { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: maximumDuration)
                self?.finish()
            }
        }
    }

    func finish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !isFinished else { return nil }
            isFinished = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final class NativeDecompilerAdmissionDispositionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var disposition: FairSingleLaneSubmissionDisposition?

    var value: FairSingleLaneSubmissionDisposition? {
        lock.withLock { disposition }
    }

    func record(_ disposition: FairSingleLaneSubmissionDisposition) {
        lock.withLock { self.disposition = disposition }
    }
}

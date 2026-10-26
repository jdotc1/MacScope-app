import Darwin
import Foundation

#if MACSCOPE_PHASE2_INSTALLED_RENDERER_EVIDENCE_FOCUSED_MAIN
/// Executable-harness double for the concurrently frozen diagnostics contract. The normal
/// CoreTests build uses the production diagnostics implementation instead.
final class MacScopeGhosttySurfaceDiagnostics: @unchecked Sendable {
    static let maximumRendererWaitDuration: TimeInterval = 30
    static let rendererEvidenceShared = MacScopeGhosttySurfaceDiagnostics()

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

    enum RendererResolution: Equatable, Sendable {
        case instantiated(RendererEvidence)
        case retired(RendererEvidence)
        case staleGeneration(observed: RendererGenerationBinding)
        case shellBrokerProcessIdentifierMismatch(observed: Int32)
        case noInstantiatedRenderer
    }

    enum RendererRecordDisposition: Equatable, Sendable {
        case recorded(sequence: UInt64)
        case duplicate
        case staleGeneration(observed: RendererGenerationBinding)
        case shellBrokerProcessIdentifierMismatch(observed: Int32)
        case retired
        case superseded
        case noInstantiatedRenderer
        case invalidObservation
    }

    struct RendererSnapshot: Equatable, Sendable {
        let entries: [RendererEntry]
        let totalRecorded: UInt64
        let evictedEntryCount: UInt64

        func resolution(for binding: RendererBinding) -> RendererResolution {
            MacScopeGhosttySurfaceDiagnostics.resolution(entries: entries, binding: binding)
        }
    }

    private let capacity: Int
    private let condition = NSCondition()
    private var entries: [RendererEntry] = []
    private var totalRecorded: UInt64 = 0
    private var evictedEntryCount: UInt64 = 0

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    func rendererSnapshot() -> RendererSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return RendererSnapshot(
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
        guard Self.validRenderer(observation) else { return .invalidObservation }
        if case let .staleGeneration(observed) = Self.resolution(
            entries: entries,
            binding: observation.binding
        ) {
            return .staleGeneration(observed: observed)
        }
        return append(
            RendererEvidence(observation: observation, lifecycle: .instantiated)
        )
    }

    @discardableResult
    func recordRendererRetirement(
        _ observation: RendererObservation
    ) -> RendererRecordDisposition {
        condition.lock()
        defer { condition.unlock() }
        guard Self.validRenderer(observation) else { return .invalidObservation }
        guard case let .instantiated(instantiated) = Self.resolution(
            entries: entries,
            binding: observation.binding
        ) else { return .noInstantiatedRenderer }
        guard instantiated.observation == observation else { return .invalidObservation }
        return append(RendererEvidence(observation: observation, lifecycle: .retired))
    }

    func waitForRendererEvidence(
        for binding: RendererBinding,
        timeout: TimeInterval
    ) -> RendererResolution {
        condition.lock()
        defer { condition.unlock() }
        let duration = timeout.isFinite && timeout > 0
            ? min(timeout, Self.maximumRendererWaitDuration)
            : 0
        let deadline = Date().addingTimeInterval(duration)
        while true {
            let current = Self.resolution(entries: entries, binding: binding)
            if current != .noInstantiatedRenderer { return current }
            guard duration > 0, condition.wait(until: deadline) else {
                return .noInstantiatedRenderer
            }
        }
    }

    private func append(_ evidence: RendererEvidence) -> RendererRecordDisposition {
        totalRecorded &+= 1
        if entries.count == capacity {
            entries.removeFirst()
            evictedEntryCount &+= 1
        }
        entries.append(RendererEntry(sequence: totalRecorded, evidence: evidence))
        condition.broadcast()
        return .recorded(sequence: totalRecorded)
    }

    private static func validRenderer(_ observation: RendererObservation) -> Bool {
        switch observation.observedMode {
        case .ghosttyFullSurface:
            guard case .exact = observation.binding.generation else { return false }
            return observation.requestedMode == .ghosttyFullSurface
                && observation.fallbackReason == .none
        case .macScopeGhosttyVTGrid:
            return observation.requestedMode == .macScopeGhosttyVTGrid
                && observation.binding.generation == .notAllocated
                && observation.fallbackReason == .recoveryOverride
        case .transcriptOnlyFallback:
            return false
        }
    }

    private static func resolution(
        entries: [RendererEntry],
        binding: RendererBinding
    ) -> RendererResolution {
        if let mismatchedPID = entries.reversed().compactMap({ entry -> Int32? in
            let candidate = entry.evidence.observation.binding
            guard candidate.sessionID == binding.sessionID,
                  candidate.requestID == binding.requestID,
                  candidate.generation == binding.generation,
                  candidate.shellBrokerProcessIdentifier
                    != binding.shellBrokerProcessIdentifier else { return nil }
            return candidate.shellBrokerProcessIdentifier
        }).first {
            return .shellBrokerProcessIdentifierMismatch(observed: mismatchedPID)
        }
        if case let .exact(expected) = binding.generation {
            let newer = entries.compactMap { entry -> UInt64? in
                let candidate = entry.evidence.observation.binding
                guard candidate.sessionID == binding.sessionID,
                      candidate.requestID == binding.requestID,
                      candidate.shellBrokerProcessIdentifier
                        == binding.shellBrokerProcessIdentifier,
                      case let .exact(generation) = candidate.generation,
                      generation > expected else { return nil }
                return generation
            }.max()
            if let newer { return .staleGeneration(observed: .exact(newer)) }
        }
        guard let evidence = entries.last(where: {
            $0.evidence.observation.binding == binding
        })?.evidence else { return .noInstantiatedRenderer }
        switch evidence.lifecycle {
        case .instantiated: return .instantiated(evidence)
        case .retired: return .retired(evidence)
        }
    }
}

@main
private enum Phase2InstalledRendererEvidenceAdapterFocusedMain {
    static func main() async {
        let requestedScenarios = Set(CommandLine.arguments.dropFirst())
        let failures = await Phase2InstalledRendererEvidenceAdapterScenarios.run(
            requestedScenarios: requestedScenarios
        )
        if failures > 0 { exit(1) }
    }
}
#else
import XCTest

@testable import MacScope

@MainActor
final class Phase2InstalledRendererEvidenceAdapterTests: XCTestCase {
    func testDefaultFullSurfaceUsesFreshMountedLedgerEvidence() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.defaultFullSurface()
    }

    func testForcedLegacyUsesRealRecoveryGridEvidence() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.forcedLegacyOverride()
    }

    func testRetainedEvidenceCannotSatisfyANewPresentation() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.retainedEvidence()
    }

    func testRetiredAndNewerGenerationEvidenceFailClosed() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.retiredEvidence()
        try await Phase2InstalledRendererEvidenceAdapterScenarios.presentationRetiredBeforeEvidence()
        try await Phase2InstalledRendererEvidenceAdapterScenarios.newerGeneration()
    }

    func testMissingAndTranscriptOnlyEvidenceFailClosedWithinBound() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.missingEvidence()
        try await Phase2InstalledRendererEvidenceAdapterScenarios.presentationTimeout()
        try await Phase2InstalledRendererEvidenceAdapterScenarios.transcriptOnly()
    }

    func testPresentationAndPIDMismatchesFailClosed() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.presentationMismatch()
        try await Phase2InstalledRendererEvidenceAdapterScenarios.pidMismatch()
    }

    func testEvidenceWaitDoesNotStarveMainActorPresentation() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.mainActorNonstarvation()
    }

    func testSuccessWaitsForExactPresentationAndLedgerRetirement() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.retirementProof()
    }

    func testCancellationInterruptsEvidenceWaitAndDismissesPresentation() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.cancellation()
    }

    func testInstalledOperationDeadlineResetsTimeoutAndCancellation() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.operationDeadline()
    }

    func testOrdinaryLaunchDoesNotStartInstalledSmoke() async throws {
        try await Phase2InstalledRendererEvidenceAdapterScenarios.ordinaryLaunchNoninterference()
    }
}
#endif

private enum Phase2InstalledRendererEvidenceAdapterScenarioError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

@MainActor
private final class Phase2InstalledRendererEvidenceCompletionProbe {
    var didComplete = false
}

private final class Phase2InstalledRendererDeadlineProbe: @unchecked Sendable {
    private enum Failure: Error {
        case reset
    }

    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Error>?
    private var firstResetWaiters: [CheckedContinuation<Void, Never>] = []
    private var resetCount = 0

    var observedResetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resetCount
    }

    func neverReply() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            pending = continuation
            lock.unlock()
        }
    }

    func neverReplyAfterFirstReset() async throws {
        await waitForFirstReset()
        try await neverReply()
    }

    func reset() async {
        let (continuation, waiters) = recordReset()
        waiters.forEach { $0.resume() }
        continuation?.resume(throwing: Failure.reset)
    }

    private func waitForFirstReset() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if resetCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                firstResetWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func recordReset() -> (
        CheckedContinuation<Void, Error>?,
        [CheckedContinuation<Void, Never>]
    ) {
        lock.lock()
        defer { lock.unlock() }
        resetCount += 1
        let continuation = pending
        pending = nil
        let waiters = firstResetWaiters
        firstResetWaiters.removeAll()
        return (continuation, waiters)
    }
}

@MainActor
private enum Phase2InstalledRendererEvidenceAdapterScenarios {
    typealias Adapter = Phase2InstalledRendererEvidenceAdapter
    typealias Diagnostics = MacScopeGhosttySurfaceDiagnostics
    typealias Runner = Phase2InstalledShellSmokeRunner

    static func run(requestedScenarios: Set<String> = []) async -> Int {
        let scenarios: [(String, () async throws -> Void)] = [
            ("default-full", defaultFullSurface),
            ("forced-legacy", forcedLegacyOverride),
            ("retained-evidence", retainedEvidence),
            ("retired-evidence", retiredEvidence),
            ("retired-presentation", presentationRetiredBeforeEvidence),
            ("newer-generation", newerGeneration),
            ("missing-evidence", missingEvidence),
            ("presentation-timeout", presentationTimeout),
            ("transcript-only", transcriptOnly),
            ("presentation-mismatch", presentationMismatch),
            ("pid-mismatch", pidMismatch),
            ("mainactor-nonstarvation", mainActorNonstarvation),
            ("retirement-proof", retirementProof),
            ("cancellation", cancellation),
            ("operation-deadline", operationDeadline),
            ("ordinary-launch", ordinaryLaunchNoninterference),
        ]
        let knownNames = Set(scenarios.map(\.0))
        let unknownNames = requestedScenarios.subtracting(knownNames)
        if !unknownNames.isEmpty {
            FileHandle.standardError.write(Data(
                "FAIL: unknown scenarios: \(unknownNames.sorted().joined(separator: ", "))\n".utf8
            ))
            return unknownNames.count
        }
        var failureCount = 0
        for (name, scenario) in scenarios
        where requestedScenarios.isEmpty || requestedScenarios.contains(name) {
            do {
                try await scenario()
                print("PASS: \(name)")
            } catch {
                failureCount += 1
                FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
            }
        }
        return failureCount
    }

    static func defaultFullSurface() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.25)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let snapshot = runningSnapshot(for: request)
        let binding = rendererBinding(for: request, generation: .exact(7))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: snapshot,
            binding: binding
        )

        let renderer = observation(
            binding: binding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let evidence = try await collectEvidenceWithExactRetirement(
            adapter: adapter,
            diagnostics: diagnostics,
            request: request,
            presentation: lease,
            renderer: renderer
        )

        try require(evidence.generation == request.generation, "fresh request generation changed")
        try require(evidence.selectedBackend == .ghosttyFullSurface, "full backend changed")
        try require(evidence.fallbackReason == nil, "full renderer acquired a fallback")
        try require(evidence.shellSessionID == binding.sessionID, "session coordinate changed")
        try require(evidence.shellRequestID == binding.requestID, "request coordinate changed")
        try require(
            evidence.shellProcessIdentifier == binding.shellBrokerProcessIdentifier,
            "PID was not derived from the renderer binding"
        )
    }

    static func forcedLegacyOverride() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.25)
        let request = rendererRequest(mode: .forcedLegacyGridRecoveryOverride)
        let binding = rendererBinding(for: request, generation: .notAllocated)
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let renderer = observation(
            binding: binding,
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .recoveryOverride
        )
        let evidence = try await collectEvidenceWithExactRetirement(
            adapter: adapter,
            diagnostics: diagnostics,
            request: request,
            presentation: lease,
            renderer: renderer
        )
        try require(
            evidence.requestedMode == .forcedLegacyGridRecoveryOverride,
            "forced legacy request changed"
        )
        try require(evidence.selectedBackend == .macScopeGhosttyVTGrid, "legacy grid not observed")
        try require(evidence.fallbackReason == .recoveryOverride, "recovery override not observed")
    }

    static func retainedEvidence() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let request = rendererRequest(mode: .forcedLegacyGridRecoveryOverride)
        let binding = rendererBinding(for: request, generation: .notAllocated)
        _ = diagnostics.recordRendererInstantiation(observation(
            binding: binding,
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .recoveryOverride
        ))
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.1)
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        try await requireFailure(.staleEvidence) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
    }

    static func retiredEvidence() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.1)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(11))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let renderer = observation(
            binding: binding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = diagnostics.recordRendererInstantiation(renderer)
        _ = diagnostics.recordRendererRetirement(renderer)
        try await requireFailure(.retiredEvidence) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
    }

    static func presentationRetiredBeforeEvidence() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.1)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(11))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        _ = diagnostics.recordRendererInstantiation(observation(
            binding: binding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        ))
        adapter.presentationRetired(
            requestGeneration: request.generation,
            sessionID: binding.sessionID,
            requestID: binding.requestID,
            shellProcessIdentifier: binding.shellBrokerProcessIdentifier,
            rendererBinding: binding
        )
        try await requireFailure(.presentationRetired) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
    }

    static func newerGeneration() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.1)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(12))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let newerBinding = rendererBinding(for: request, generation: .exact(13))
        _ = diagnostics.recordRendererInstantiation(observation(
            binding: newerBinding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        ))
        try await requireFailure(.staleEvidence) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
    }

    static func missingEvidence() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.03)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(17))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let started = Date()
        try await requireFailure(.missingEvidence) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
        let elapsed = Date().timeIntervalSince(started)
        try require(elapsed >= 0.015, "missing evidence wait failed before its bound")
        try require(elapsed < 0.5, "missing evidence wait was unbounded")
    }

    static func presentationTimeout() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.03)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let started = Date()
        try await requireFailure(.presentationTimedOut) {
            _ = try await adapter.present(
                request: request,
                snapshot: runningSnapshot(for: request)
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        try require(elapsed >= 0.015, "presentation wait failed before its bound")
        try require(elapsed < 0.5, "presentation wait was unbounded")
        try require(adapter.presentationRequest == nil, "timed-out presentation remained mounted")
    }

    static func transcriptOnly() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.03)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(18))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let disposition = diagnostics.recordRendererInstantiation(observation(
            binding: binding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .transcriptOnlyFallback,
            fallbackReason: .transcriptRejected
        ))
        try require(
            disposition == .invalidObservation,
            "transcript-only fallback entered the renderer-instantiation ledger"
        )
        try await requireFailure(.missingEvidence) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
    }

    static func presentationMismatch() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.05)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let task = Task { @MainActor in
            try await adapter.present(request: request, snapshot: runningSnapshot(for: request))
        }
        try await waitForPresentation(adapter)
        let wrongBinding = try unwrap(Diagnostics.RendererBinding(
            sessionID: UUID(),
            requestID: request.shellRequestID,
            shellBrokerProcessIdentifier: request.shellProcessIdentifier,
            generation: .exact(2)
        ))
        adapter.presentationMounted(
            requestGeneration: request.generation,
            sessionID: request.shellSessionID,
            requestID: request.shellRequestID,
            shellProcessIdentifier: request.shellProcessIdentifier,
            rendererBinding: wrongBinding
        )
        try await requireFailure(.presentationCoordinateMismatch) {
            _ = try await task.value
        }
    }

    static func pidMismatch() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.1)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let expectedBinding = rendererBinding(for: request, generation: .exact(21))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: expectedBinding
        )
        let observedPID = request.shellProcessIdentifier + 1
        let wrongPIDBinding = try unwrap(Diagnostics.RendererBinding(
            sessionID: request.shellSessionID,
            requestID: request.shellRequestID,
            shellBrokerProcessIdentifier: observedPID,
            generation: .exact(21)
        ))
        _ = diagnostics.recordRendererInstantiation(observation(
            binding: wrongPIDBinding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        ))
        try await requireFailure(.shellBrokerProcessIdentifierMismatch(observed: observedPID)) {
            _ = try await adapter.rendererEvidence(request: request, presentation: lease)
        }
    }

    static func mainActorNonstarvation() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.2)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(31))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let evidenceTask = Task { @MainActor in
            try await adapter.rendererEvidence(request: request, presentation: lease)
        }
        let recorder = Task { @MainActor in
            try await Task.sleep(nanoseconds: 10_000_000)
            _ = diagnostics.recordRendererInstantiation(observation(
                binding: binding,
                requestedMode: .ghosttyFullSurface,
                observedMode: .ghosttyFullSurface,
                fallbackReason: .none
            ))
        }
        try await recorder.value
        try await waitForRetirementRequest(adapter)
        let renderer = observation(
            binding: binding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        adapter.presentationRetired(
            requestGeneration: request.generation,
            sessionID: binding.sessionID,
            requestID: binding.requestID,
            shellProcessIdentifier: binding.shellBrokerProcessIdentifier,
            rendererBinding: binding
        )
        _ = diagnostics.recordRendererRetirement(renderer)
        let evidence = try await evidenceTask.value
        try require(evidence.rendererPresented, "MainActor presentation never recorded evidence")
    }

    static func retirementProof() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 0.04)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(41))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let renderer = observation(
            binding: binding,
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = diagnostics.recordRendererInstantiation(renderer)
        let evidenceTask = Task { @MainActor in
            try await adapter.rendererEvidence(request: request, presentation: lease)
        }
        try await waitForRetirementRequest(adapter)
        adapter.presentationRetired(
            requestGeneration: request.generation,
            sessionID: binding.sessionID,
            requestID: binding.requestID,
            shellProcessIdentifier: binding.shellBrokerProcessIdentifier,
            rendererBinding: binding
        )
        try await requireFailure(.retirementTimedOut) {
            _ = try await evidenceTask.value
        }
    }

    static func cancellation() async throws {
        let diagnostics = Diagnostics(capacity: 8)
        let adapter = Adapter(diagnostics: diagnostics, waitDuration: 1)
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let binding = rendererBinding(for: request, generation: .exact(51))
        let lease = try await mount(
            adapter: adapter,
            request: request,
            snapshot: runningSnapshot(for: request),
            binding: binding
        )
        let started = Date()
        let evidenceTask = Task { @MainActor in
            try await adapter.rendererEvidence(request: request, presentation: lease)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        evidenceTask.cancel()
        do {
            _ = try await evidenceTask.value
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "cancelled evidence wait unexpectedly succeeded"
            )
        } catch is CancellationError {
            // Expected: cancellation must not wait for the diagnostics timeout.
        }
        try require(
            Date().timeIntervalSince(started) < 0.25,
            "cancelled evidence wait did not unwind promptly"
        )
        try require(adapter.presentationRequest == nil, "cancelled presentation remained mounted")
    }

    static func operationDeadline() async throws {
        let successProbe = Phase2InstalledRendererDeadlineProbe()
        let success: Int = try await Phase2InstalledSmokeOperationDeadline.perform(
            timeoutSeconds: 0.03,
            operationDescription: "focused successful operation",
            reset: { await successProbe.reset() },
            operation: { 7 }
        )
        try require(success == 7, "successful operation result changed")
        try require(
            successProbe.observedResetCount == 0,
            "losing deadline reset a successful operation"
        )

        let timedOutProbe = Phase2InstalledRendererDeadlineProbe()
        let timeoutStarted = Date()
        do {
            try await Phase2InstalledSmokeOperationDeadline.perform(
                timeoutSeconds: 0.03,
                operationDescription: "focused never-replying operation",
                reset: { await timedOutProbe.reset() },
                operation: { try await timedOutProbe.neverReply() }
            )
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "never-replying operation unexpectedly completed"
            )
        } catch is Phase2InstalledSmokeOperationDeadline.Timeout {
            // Expected timeout.
        }
        try require(timedOutProbe.observedResetCount >= 1, "timeout did not reset operation")
        try require(
            Date().timeIntervalSince(timeoutStarted) < 0.5,
            "operation timeout exceeded its bound"
        )

        let cancelledProbe = Phase2InstalledRendererDeadlineProbe()
        let cancellationStarted = Date()
        let task = Task {
            try await Phase2InstalledSmokeOperationDeadline.perform(
                timeoutSeconds: 1,
                operationDescription: "focused cancelled operation",
                reset: { await cancelledProbe.reset() },
                operation: { try await cancelledProbe.neverReply() }
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do {
            try await task.value
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "cancelled operation unexpectedly completed"
            )
        } catch is CancellationError {
            // Cancellation is the atomically selected result even though reset drains the operation.
        }
        try require(cancelledProbe.observedResetCount >= 1, "cancellation did not reset operation")
        try require(
            Date().timeIntervalSince(cancellationStarted) < 0.5,
            "cancelled operation did not unwind promptly"
        )

        let lateRegistrationProbe = Phase2InstalledRendererDeadlineProbe()
        let lateCancellationStarted = Date()
        let lateRegistrationTask = Task {
            try await Phase2InstalledSmokeOperationDeadline.perform(
                timeoutSeconds: 1,
                operationDescription: "focused post-reset registration",
                reset: { await lateRegistrationProbe.reset() },
                operation: { try await lateRegistrationProbe.neverReplyAfterFirstReset() }
            )
        }
        lateRegistrationTask.cancel()
        do {
            try await lateRegistrationTask.value
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "post-reset registration unexpectedly completed"
            )
        } catch is CancellationError {
            // The repeated reset must catch registration that begins after the first reset.
        }
        try require(
            lateRegistrationProbe.observedResetCount >= 2,
            "post-reset registration escaped the cancellation reset"
        )
        try require(
            Date().timeIntervalSince(lateCancellationStarted) < 0.5,
            "post-reset registration did not unwind promptly"
        )
    }

    static func ordinaryLaunchNoninterference() async throws {
        try require(!Adapter.isSmokeRequested(environment: [:]), "absent report started smoke")
        try require(
            !Adapter.isSmokeRequested(environment: [Runner.reportPathEnvironmentKey: "  \n"]),
            "empty report started smoke"
        )
        try require(
            Adapter.isSmokeRequested(environment: [Runner.reportPathEnvironmentKey: "/tmp/report"]),
            "nonempty report did not select smoke"
        )
        let started = Runner.startIfRequested(
            environment: [:],
            rendererPresentationProvider: { _, _ in
                throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                    "ordinary launch invoked renderer presentation"
                )
            },
            rendererEvidenceProvider: { _, _ in
                throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                    "ordinary launch invoked renderer evidence"
                )
            }
        )
        try require(!started, "ordinary launch was intercepted by the installed smoke")
    }

    private static func mount(
        adapter: Adapter,
        request: Runner.RendererEvidenceRequest,
        snapshot: Phase2HumanPTYSessionSnapshot,
        binding: Diagnostics.RendererBinding
    ) async throws -> Runner.RendererPresentationLease {
        let task = Task { @MainActor in
            try await adapter.present(request: request, snapshot: snapshot)
        }
        try await waitForPresentation(adapter)
        adapter.presentationMounted(
            requestGeneration: request.generation,
            sessionID: binding.sessionID,
            requestID: binding.requestID,
            shellProcessIdentifier: binding.shellBrokerProcessIdentifier,
            rendererBinding: binding
        )
        return try await task.value
    }

    private static func collectEvidenceWithExactRetirement(
        adapter: Adapter,
        diagnostics: Diagnostics,
        request: Runner.RendererEvidenceRequest,
        presentation: Runner.RendererPresentationLease,
        renderer: Diagnostics.RendererObservation
    ) async throws -> Runner.RendererRuntimeEvidence {
        let completion = Phase2InstalledRendererEvidenceCompletionProbe()
        let evidenceTask = Task { @MainActor in
            defer { completion.didComplete = true }
            return try await adapter.rendererEvidence(
                request: request,
                presentation: presentation
            )
        }
        let instantiation = diagnostics.recordRendererInstantiation(renderer)
        guard case .recorded = instantiation else {
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "fresh renderer instantiation was not recorded: \(instantiation)"
            )
        }
        try await waitForRetirementRequest(adapter)
        await Task.yield()
        try require(
            !completion.didComplete,
            "renderer evidence completed before exact retirement proof"
        )

        let binding = renderer.binding
        adapter.presentationRetired(
            requestGeneration: request.generation,
            sessionID: binding.sessionID,
            requestID: binding.requestID,
            shellProcessIdentifier: binding.shellBrokerProcessIdentifier,
            rendererBinding: binding
        )
        let retirement = diagnostics.recordRendererRetirement(renderer)
        guard case .recorded = retirement else {
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "exact renderer retirement was not recorded: \(retirement)"
            )
        }
        return try await evidenceTask.value
    }

    private static func waitForPresentation(_ adapter: Adapter) async throws {
        let deadline = Date().addingTimeInterval(0.25)
        while adapter.presentationRequest == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try require(adapter.presentationRequest != nil, "presentation request was not published")
    }

    private static func waitForRetirementRequest(_ adapter: Adapter) async throws {
        let deadline = Date().addingTimeInterval(0.25)
        while adapter.presentationRequest != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try require(adapter.presentationRequest == nil, "presentation retirement was not requested")
    }

    private static func rendererRequest(
        mode: Runner.RendererMode
    ) -> Runner.RendererEvidenceRequest {
        Runner.RendererEvidenceRequest(
            requestedMode: mode,
            generation: UUID(),
            shellSessionID: UUID(),
            shellRequestID: UUID(),
            shellProcessIdentifier: 4_321
        )
    }

    private static func runningSnapshot(
        for request: Runner.RendererEvidenceRequest
    ) -> Phase2HumanPTYSessionSnapshot {
        Phase2HumanPTYSessionSnapshot(
            sessionID: request.shellSessionID,
            state: .running(
                requestID: request.shellRequestID,
                processIdentifier: request.shellProcessIdentifier
            ),
            launchPlan: nil,
            transcriptEvents: [],
            issues: []
        )
    }

    private static func rendererBinding(
        for request: Runner.RendererEvidenceRequest,
        generation: Diagnostics.RendererGenerationBinding
    ) -> Diagnostics.RendererBinding {
        Diagnostics.RendererBinding(
            sessionID: request.shellSessionID,
            requestID: request.shellRequestID,
            shellBrokerProcessIdentifier: request.shellProcessIdentifier,
            generation: generation
        )!
    }

    private static func observation(
        binding: Diagnostics.RendererBinding,
        requestedMode: Diagnostics.RendererRequestedMode,
        observedMode: Diagnostics.RendererObservedMode,
        fallbackReason: Diagnostics.RendererFallbackReason
    ) -> Diagnostics.RendererObservation {
        Diagnostics.RendererObservation(
            binding: binding,
            requestedMode: requestedMode,
            observedMode: observedMode,
            fallbackReason: fallbackReason
        )
    }

    private static func requireFailure(
        _ expected: Adapter.Failure,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "operation unexpectedly succeeded; expected \(expected)"
            )
        } catch let failure as Adapter.Failure {
            try require(failure == expected, "wrong failure: \(failure); expected \(expected)")
        }
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else {
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(
                "failable frozen-contract initializer rejected valid coordinates"
            )
        }
        return value
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw Phase2InstalledRendererEvidenceAdapterScenarioError.assertion(message)
        }
    }
}

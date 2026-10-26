import Foundation

@MainActor
protocol Phase2LiveQualificationCoordinating: AnyObject {
    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult
    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?
    ) async -> Phase2ReadyInferenceExecutionResult
}

/// Production-only capability used by controlled cancellation trials. The concrete coordinator
/// proves exact request dispatch, gates provider events, then accepts cancellation at the frozen
/// after-dispatch-before-first-semantic-event injection point.
@MainActor
protocol Phase2ControlledCancellationCoordinating: AnyObject {
    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?,
        controlledCancellationBarrier: Phase2ControlledCancellationBarrier
    ) async -> Phase2ReadyInferenceExecutionResult
}

extension Phase2LiveQualificationCoordinating {
    func run(
        request: Phase2InferenceRequest,
        measurementObserver _: (any Phase2InferenceMeasurementObserving)?
    ) async -> Phase2ReadyInferenceExecutionResult {
        await run(request: request)
    }
}

extension Phase2ReadyInferenceCoordinator: Phase2LiveQualificationCoordinating {}
extension Phase2ReadyInferenceCoordinator: Phase2ControlledCancellationCoordinating {}

/// Revalidates the complete launch-local preflight result. A ready lease alone cannot prove that
/// the endpoint generation, exact loaded instance/configuration, or provider build stayed fixed.
@MainActor
protocol Phase2LiveQualificationRuntimeValidating: AnyObject {
    func isCurrent(_ binding: Phase2LiveQualificationRuntimeBinding) -> Bool
}

/// Composition adapter for a collector that independently recaptures every run-critical
/// observation without mutating provider state.
@MainActor
final class Phase2LiveQualificationRuntimeValidator:
    Phase2LiveQualificationRuntimeValidating
{
    typealias Capture = @MainActor () -> Phase2LiveQualificationFreshObservation?

    private let prepared: Phase2PreparedLiveQualification
    private let capture: Capture
    private let matcher: Phase2LiveQualificationFreshObservationMatcher

    init(
        prepared: Phase2PreparedLiveQualification,
        capture: @escaping Capture,
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) {
        self.prepared = prepared
        self.capture = capture
        matcher = .init(selector: selector)
    }

    func isCurrent(_ binding: Phase2LiveQualificationRuntimeBinding) -> Bool {
        guard prepared.runtimeBinding == binding, let observation = capture() else {
            return false
        }
        return matcher.compare(prepared: prepared, observation: observation).isCurrent
    }
}

struct Phase2LiveQualificationMeasurementConfiguration: Sendable {
    let metricPlan: Phase2QualificationMetricPlan
    let clock: any Phase2QualificationMonotonicClock
    /// A deferred qualification scope is permitted here: the coordinator binds its exact worker
    /// process receipt before admission, and the accumulator performs its first sample only after
    /// that callback. The scope identity is deliberately read at finalization rather than copied
    /// before the concrete provider exists.
    let residentSetSampler: any Phase2QualificationBoundResidentSetSampling
    /// Required whenever cancellation latency applies. A missing bound fails that trial closed;
    /// the canonical F4C policy supplies its frozen 2,000 ms maximum-inclusive threshold.
    let maximumCancellationDrainMilliseconds: Int64?

    init(
        metricPlan: Phase2QualificationMetricPlan,
        clock: any Phase2QualificationMonotonicClock,
        residentSetSampler: any Phase2QualificationBoundResidentSetSampling,
        maximumCancellationDrainMilliseconds: Int64? = nil
    ) {
        self.metricPlan = metricPlan
        self.clock = clock
        self.residentSetSampler = residentSetSampler
        self.maximumCancellationDrainMilliseconds =
            maximumCancellationDrainMilliseconds
    }
}

/// App-owned epoch timing for one finite live run. Unlike the injected monotonic test clock used
/// for durations, these report-bound timestamps always come from the host wall clock.
final class Phase2LiveQualificationRunTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var firstAdmission: Int64?
    private var terminal: Int64?

    func recordAdmission() throws {
        let now = try Self.nowEpochMilliseconds()
        lock.withLock {
            if firstAdmission == nil { firstAdmission = now }
        }
    }

    func recordTerminal() throws {
        let now = try Self.nowEpochMilliseconds()
        try lock.withLock {
            guard let firstAdmission, now >= firstAdmission else {
                throw Phase2QualificationMeasurementV2Error.clockRegression
            }
            terminal = now
        }
    }

    var snapshot: (start: Int64?, end: Int64?) {
        lock.withLock { (firstAdmission, terminal) }
    }

    private static func nowEpochMilliseconds() throws -> Int64 {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(Int64.max)
        else { throw Phase2QualificationMeasurementV2Error.outOfRange }
        return Int64(milliseconds.rounded(.down))
    }
}

/// One instance spans every provider phase of one logical trial. It lazily creates exactly one
/// accumulator at first admission and converts callback errors into a missing sample; measurement
/// failure can invalidate certification, but it can never alter provider execution.
final class Phase2LiveQualificationAttemptMeasurementObserver:
    Phase2InferenceAdmissionResolutionObserving, @unchecked Sendable
{
    private let trialKey: Phase2QualificationTrialKey
    private let configuration: Phase2LiveQualificationMeasurementConfiguration
    private let runTiming: Phase2LiveQualificationRunTiming
    private let applicableKinds: Set<Phase2QualificationMeasurementV2Kind>
    private let lock = NSLock()

    private var accumulator: Phase2QualificationAttemptAccumulator?
    private var admissionObserved = false
    private var admittedPhases: Set<Phase2InferencePhase> = []
    private var drainedPhases: Set<Phase2InferencePhase> = []
    private var generationPhases: Set<Phase2InferencePhase> = []
    private var usagePhases: Set<Phase2InferencePhase> = []
    private var recordedFirstSemantic = false
    private var recordedCancellation = false
    private var recordedCancellationDrain = false
    private var failed = false
    private var finished = false
    private var admissionResolution: Bool?
    private var admissionContinuation: CheckedContinuation<Bool, Never>?

    init(
        trialKey: Phase2QualificationTrialKey,
        configuration: Phase2LiveQualificationMeasurementConfiguration,
        runTiming: Phase2LiveQualificationRunTiming = .init()
    ) {
        self.trialKey = trialKey
        self.configuration = configuration
        self.runTiming = runTiming
        applicableKinds = Set(configuration.metricPlan.applicableTrialKeys.compactMap {
            kind, keys in keys.contains(trialKey) ? kind : nil
        })
    }

    var wasAdmitted: Bool {
        lock.lock(); defer { lock.unlock() }
        return admissionObserved
    }

    var hasFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    var hasCompletePhaseClosure: Bool {
        lock.lock(); defer { lock.unlock() }
        guard admittedPhases == drainedPhases else { return false }
        return !measuresUsage
            || (generationPhases == admittedPhases && usagePhases == generationPhases)
    }

    var trialKeyForCollection: Phase2QualificationTrialKey { trialKey }

    func admitted(phase: Phase2InferencePhase) {
        mutate {
            guard admittedPhases.insert(phase).inserted else {
                return fail()
            }
            try runTiming.recordAdmission()
            admissionObserved = true
            if accumulator == nil {
                accumulator = try Phase2QualificationAttemptAccumulator(
                    clock: configuration.clock,
                    residentSetSampler: configuration.residentSetSampler
                )
                if applicableKinds.contains(.peakResidentBytes),
                   accumulator?.residentScopeIsComplete != true {
                    return fail()
                }
            }
        }
        resolveAdmission(true)
    }

    func admissionDeclined(phase _: Phase2InferencePhase) {
        resolveAdmission(false)
    }

    func waitForAdmissionResolution() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let admissionResolution {
                lock.unlock()
                continuation.resume(returning: admissionResolution)
                return
            }
            guard admissionContinuation == nil else {
                failed = true
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            admissionContinuation = continuation
            lock.unlock()
        }
    }

    func generationBegan(phase: Phase2InferencePhase) {
        guard measuresUsage else { return }
        mutate {
            guard admittedPhases.contains(phase), let accumulator else { return fail() }
            try accumulator.beginPhaseGeneration(measuredPhase(phase))
            generationPhases.insert(phase)
        }
    }

    func acceptedSemantic(phase: Phase2InferencePhase) {
        guard applicableKinds.contains(.timeToFirstSemanticEventMilliseconds) else { return }
        mutate {
            guard admittedPhases.contains(phase), let accumulator else { return fail() }
            guard !recordedFirstSemantic else { return }
            try accumulator.recordFirstSemanticEvent()
            recordedFirstSemantic = true
        }
    }

    func acceptedEvent(phase: Phase2InferencePhase) {
        guard applicableKinds.contains(.peakResidentBytes) else { return }
        mutate {
            guard admittedPhases.contains(phase), let accumulator else { return fail() }
            try accumulator.recordResidentSet()
            if !accumulator.residentScopeIsComplete { return fail() }
        }
    }

    func usageAccepted(phase: Phase2InferencePhase, usage: Phase2ProviderUsage) {
        guard measuresUsage else { return }
        mutate {
            guard admittedPhases.contains(phase), let accumulator,
                  let promptTokens = Int64(exactly: usage.promptTokens),
                  let completionTokens = Int64(exactly: usage.completionTokens),
                  let totalTokens = Int64(exactly: usage.totalTokens)
            else { return fail() }
            try accumulator.endPhaseGeneration(
                measuredPhase(phase),
                usage: try .init(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: totalTokens
                )
            )
            usagePhases.insert(phase)
        }
    }

    func cancellationBegan(phase: Phase2InferencePhase) {
        mutate {
            guard admittedPhases.contains(phase), let accumulator else { return fail() }
            guard !recordedCancellation else { return }
            try accumulator.recordCancellation()
            recordedCancellation = true
        }
    }

    func providerDrained(phase: Phase2InferencePhase) {
        mutate {
            guard admittedPhases.contains(phase), let accumulator,
                  drainedPhases.insert(phase).inserted
            else { return fail() }
            if applicableKinds.contains(.peakResidentBytes) {
                try accumulator.recordResidentSet()
            }
            if generationPhases.contains(phase), !usagePhases.contains(phase) {
                try accumulator.abandonPhaseGeneration(measuredPhase(phase))
                if measuresUsage { return fail() }
            }
            if recordedCancellation, !recordedCancellationDrain {
                try accumulator.recordCancellationDrain()
                recordedCancellationDrain = true
            }
        }
    }

    func recordValidatedTerminalBoundary() {
        mutate {
            guard let accumulator else { return }
            if applicableKinds.contains(.peakResidentBytes) {
                try accumulator.recordResidentSet()
                if !accumulator.residentScopeIsComplete { return fail() }
            }
            try accumulator.recordTerminalBoundary()
            try runTiming.recordTerminal()
        }
    }

    func finish() -> Phase2QualificationAttemptMeasurement? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else {
            failed = true
            return nil
        }
        finished = true
        guard !failed, let accumulator else { return nil }
        do {
            return try accumulator.finish(
                trialKey: trialKey,
                scope: configuration.residentSetSampler.scopeIdentity
            )
        } catch {
            failed = true
            return nil
        }
    }

    private var measuresUsage: Bool {
        applicableKinds.contains(.generatedTokenCount)
            || applicableKinds.contains(.throughputMilliTokensPerSecond)
    }

    private func measuredPhase(
        _ phase: Phase2InferencePhase
    ) -> Phase2QualificationMeasuredPhase {
        switch phase {
        case .toolSelection: .toolSelection
        case .finalization: .finalization
        case .shellContinuation:
            preconditionFailure("Shell continuation is outside live qualification measurement")
        }
    }

    private func mutate(_ body: () throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !finished else { return }
        do {
            try body()
        } catch {
            failed = true
        }
    }

    private func fail() {
        failed = true
    }

    private func resolveAdmission(_ admitted: Bool) {
        lock.lock()
        guard admissionResolution == nil else {
            lock.unlock()
            return
        }
        admissionResolution = admitted
        let continuation = admissionContinuation
        admissionContinuation = nil
        lock.unlock()
        continuation?.resume(returning: admitted)
    }
}

@MainActor
protocol Phase2LiveQualificationScoring: AnyObject {
    func classifySelection(
        _ outcome: Phase2InferenceOutcome,
        fixture: Phase2LiveQualificationTrialFixture
    ) -> Phase2LiveQualificationSelectionClassification

    func classifyFinalization(
        _ outcome: Phase2InferenceOutcome,
        fixture: Phase2LiveQualificationTrialFixture,
        selectionEvidenceDigest: String?
    ) -> Phase2LiveQualificationClassification
}

/// Runner-owned evidence for the exact phase requests it dispatched. Construction is file-private
/// so callers cannot substitute a claimed denominator; Gate validates the records against the
/// canonical plan before using their count.
struct Phase2LiveQualificationDispatchedPhaseRequest: Hashable, Sendable {
    let trialKey: Phase2LiveQualificationTrialKey
    let phase: Phase2InferencePhase
    let requestID: UUID

    fileprivate init(
        trialKey: Phase2LiveQualificationTrialKey,
        phase: Phase2InferencePhase,
        requestID: UUID
    ) {
        self.trialKey = trialKey
        self.phase = phase
        self.requestID = requestID
    }
}

struct Phase2LiveQualificationDispatchEvidence: Hashable, Sendable {
    let phaseRequests: [Phase2LiveQualificationDispatchedPhaseRequest]

    fileprivate init(
        phaseRequests: [Phase2LiveQualificationDispatchedPhaseRequest]
    ) {
        self.phaseRequests = phaseRequests
    }
}

/// Finite app-owned live executor. Distinct trials are serialized and every declared phase is
/// dispatched exactly once. Semantic mismatches continue; caller cancellation, infrastructure
/// loss, or complete runtime-binding drift aborts and closes the remaining denominator.
@MainActor
final class Phase2LiveQualificationRunner {
    private enum PhaseResult {
        case outcome(Phase2InferenceOutcome)
        case abort(
            status: Phase2QualificationRunTerminationStatus,
            current: Phase2QualificationProbeOutcome,
            reason: Phase2LiveQualificationReasonCode
        )
    }

    private let coordinator: any Phase2LiveQualificationCoordinating
    private let runtimeValidator: any Phase2LiveQualificationRuntimeValidating
    private let scorer: any Phase2LiveQualificationScoring
    private let requestFactory: Phase2LiveQualificationRequestFactory
    private let measurementConfiguration: Phase2LiveQualificationMeasurementConfiguration?
    private let onTransition: @MainActor (Phase2LiveQualificationRunnerState) -> Void
    private let onFinalizedTrial:
        @MainActor (Phase2LiveQualificationFinalizedTrialEvidence) -> Bool

    private(set) var state: Phase2LiveQualificationRunnerState = .idle
    private var activeRunTiming: Phase2LiveQualificationRunTiming?
    private var activeDispatchedPhaseRequests: [
        Phase2LiveQualificationDispatchedPhaseRequest
    ] = []

    init(
        coordinator: any Phase2LiveQualificationCoordinating,
        runtimeValidator: any Phase2LiveQualificationRuntimeValidating,
        scorer: any Phase2LiveQualificationScoring,
        requestFactory: Phase2LiveQualificationRequestFactory = .init(),
        measurementConfiguration: Phase2LiveQualificationMeasurementConfiguration? = nil,
        onTransition: @escaping @MainActor (Phase2LiveQualificationRunnerState) -> Void = { _ in },
        onFinalizedTrial: @escaping @MainActor
            (Phase2LiveQualificationFinalizedTrialEvidence) -> Bool = { _ in true }
    ) {
        self.coordinator = coordinator
        self.runtimeValidator = runtimeValidator
        self.scorer = scorer
        self.requestFactory = requestFactory
        self.measurementConfiguration = measurementConfiguration
        self.onTransition = onTransition
        self.onFinalizedTrial = onFinalizedTrial
    }

    func run(
        plan: Phase2LiveQualificationPlan,
        runtimeBinding: Phase2LiveQualificationRuntimeBinding
    ) async -> Phase2LiveQualificationExecution {
        guard var collector = try? Phase2LiveQualificationObservationCollector(
            expectedTrialOrder: plan.expectedTrialOrder
        ) else {
            return failedExecution(
                for: plan.expectedTrialOrder,
                reason: .invalidFixture
            )
        }
        guard state == .idle else {
            // Reentrant rejection is deliberately side-effect free with respect to active state.
            return (try? collector.rejectWithoutStarting(reason: .runnerBusy))
                ?? failedExecution(for: plan.expectedTrialOrder, reason: .runnerBusy)
        }
        activeRunTiming = .init()
        activeDispatchedPhaseRequests = []

        transition(to: .preflighting)
        guard runtimeValidator.isCurrent(runtimeBinding) else {
            return terminate(
                collector: &collector,
                status: .failed,
                current: .unavailable,
                reason: .authorityChanged
            )
        }

        for scheduled in plan.scheduledTrials {
            let fixture = scheduled.fixture
            let measurementObserver = makeMeasurementObserver(for: fixture)
            switch scheduled.scenario.phaseFlow {
            case .toolSelection:
                let selection = await performSelection(
                    fixture: fixture,
                    runtimeBinding: runtimeBinding,
                    measurementObserver: measurementObserver
                )
                switch selection {
                case .abort(let status, let current, let reason):
                    _ = finishMeasurement(measurementObserver, collector: &collector)
                    return terminate(
                        collector: &collector,
                        status: status,
                        current: current,
                        reason: reason
                    )
                case .outcome(let outcome):
                    transition(to: .classifying(fixture.key, .toolSelection))
                    switch scorer.classifySelection(outcome, fixture: fixture) {
                    case .accepted(let evidenceDigest):
                        guard phase2IsSHA256Hex(evidenceDigest) else {
                            return invalidFixture(
                                collector: &collector,
                                measurementObserver: measurementObserver
                            )
                        }
                        guard record(
                            try? .passed(evidenceDigest: evidenceDigest),
                            fixture: fixture,
                            collector: &collector
                        ) else {
                            return invalidFixture(
                                collector: &collector,
                                measurementObserver: measurementObserver
                            )
                        }
                    case .failed(let classification):
                        guard classification.outcome == .failed,
                              record(classification, fixture: fixture, collector: &collector)
                        else {
                            return invalidFixture(
                                collector: &collector,
                                measurementObserver: measurementObserver
                            )
                        }
                    }
                    guard finishFinalizedAttempt(
                        measurementObserver,
                        fixture: fixture,
                        collector: &collector
                    ) else {
                        return measurementFailure(collector: &collector)
                    }
                }

            case .finalization:
                let result = await performFinalization(
                    fixture: fixture,
                    runtimeBinding: runtimeBinding,
                    cancelPhase: false,
                    measurementObserver: measurementObserver
                )
                guard case .outcome(let outcome) = result else {
                    return terminate(
                        result,
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                transition(to: .classifying(fixture.key, .finalization))
                let classification = scorer.classifyFinalization(
                    outcome,
                    fixture: fixture,
                    selectionEvidenceDigest: nil
                )
                guard record(classification, fixture: fixture, collector: &collector) else {
                    return invalidFixture(
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                guard finishFinalizedAttempt(
                    measurementObserver,
                    fixture: fixture,
                    collector: &collector
                ) else {
                    return measurementFailure(collector: &collector)
                }

            case .toolSelectionAndFinalization:
                let selection = await performSelection(
                    fixture: fixture,
                    runtimeBinding: runtimeBinding,
                    measurementObserver: measurementObserver
                )
                guard case .outcome(let selectionOutcome) = selection else {
                    return terminate(
                        selection,
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                transition(to: .classifying(fixture.key, .toolSelection))
                let selectionClassification = scorer.classifySelection(
                    selectionOutcome,
                    fixture: fixture
                )
                let selectionEvidenceDigest: String
                switch selectionClassification {
                case .accepted(let digest):
                    guard phase2IsSHA256Hex(digest) else {
                        return invalidFixture(
                            collector: &collector,
                            measurementObserver: measurementObserver
                        )
                    }
                    selectionEvidenceDigest = digest
                case .failed(let classification):
                    guard classification.outcome == .failed,
                          record(classification, fixture: fixture, collector: &collector)
                    else {
                        return invalidFixture(
                            collector: &collector,
                            measurementObserver: measurementObserver
                        )
                    }
                    guard finishFinalizedAttempt(
                        measurementObserver,
                        fixture: fixture,
                        collector: &collector
                    ) else {
                        return measurementFailure(collector: &collector)
                    }
                    continue
                }

                // This check is intentionally adjacent to finalization construction: a cancelled
                // task cannot emit a second semantic provider request after selection returns.
                guard !Task.isCancelled else {
                    finishMeasurement(measurementObserver, collector: &collector)
                    return terminate(
                        collector: &collector,
                        status: .cancelled,
                        current: .cancelled,
                        reason: .callerCancelled
                    )
                }
                let finalization = await performFinalization(
                    fixture: fixture,
                    runtimeBinding: runtimeBinding,
                    cancelPhase: false,
                    measurementObserver: measurementObserver
                )
                guard case .outcome(let finalizationOutcome) = finalization else {
                    return terminate(
                        finalization,
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                transition(to: .classifying(fixture.key, .finalization))
                let classification = scorer.classifyFinalization(
                    finalizationOutcome,
                    fixture: fixture,
                    selectionEvidenceDigest: selectionEvidenceDigest
                )
                guard record(classification, fixture: fixture, collector: &collector) else {
                    return invalidFixture(
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                guard finishFinalizedAttempt(
                    measurementObserver,
                    fixture: fixture,
                    collector: &collector
                ) else {
                    return measurementFailure(collector: &collector)
                }

            case .cancellation:
                let result = await performFinalization(
                    fixture: fixture,
                    runtimeBinding: runtimeBinding,
                    cancelPhase: true,
                    measurementObserver: measurementObserver
                )
                guard case .outcome(let outcome) = result else {
                    return terminate(
                        result,
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                transition(to: .classifying(fixture.key, .finalization))
                let classification = scorer.classifyFinalization(
                    outcome,
                    fixture: fixture,
                    selectionEvidenceDigest: nil
                )
                guard record(classification, fixture: fixture, collector: &collector) else {
                    return invalidFixture(
                        collector: &collector,
                        measurementObserver: measurementObserver
                    )
                }
                guard finishFinalizedAttempt(
                    measurementObserver,
                    fixture: fixture,
                    collector: &collector
                ) else {
                    return measurementFailure(collector: &collector)
                }
            }
        }

        guard runtimeValidator.isCurrent(runtimeBinding) else {
            return terminate(
                collector: &collector,
                status: .failed,
                current: nil,
                reason: .authorityChanged
            )
        }
        if activeRunTiming?.snapshot.start != nil {
            do {
                try activeRunTiming?.recordTerminal()
            } catch {
                return terminate(
                    collector: &collector,
                    status: .failed,
                    current: nil,
                    reason: .runAborted
                )
            }
        }
        transition(to: .collectingMeasurements)
        transition(to: .assemblingRun)
        guard let execution = try? collector.complete() else {
            transition(to: .finished)
            return stamped(failedExecution(
                for: plan.expectedTrialOrder,
                reason: .runAborted
            ))
        }
        transition(to: .finished)
        return stamped(execution)
    }

    private func performSelection(
        fixture: Phase2LiveQualificationTrialFixture,
        runtimeBinding: Phase2LiveQualificationRuntimeBinding,
        measurementObserver: Phase2LiveQualificationAttemptMeasurementObserver?
    ) async -> PhaseResult {
        guard !Task.isCancelled else { return callerCancellation() }
        guard runtimeValidator.isCurrent(runtimeBinding) else { return authorityLoss() }
        guard let request = try? requestFactory.selectionRequest(for: fixture) else {
            return invalidFixtureResult()
        }
        return await dispatch(
            request: request,
            key: fixture.key,
            runtimeBinding: runtimeBinding,
            cancelPhase: false,
            measurementObserver: measurementObserver
        )
    }

    private func performFinalization(
        fixture: Phase2LiveQualificationTrialFixture,
        runtimeBinding: Phase2LiveQualificationRuntimeBinding,
        cancelPhase: Bool,
        measurementObserver: Phase2LiveQualificationAttemptMeasurementObserver?
    ) async -> PhaseResult {
        guard !Task.isCancelled else { return callerCancellation() }
        guard runtimeValidator.isCurrent(runtimeBinding) else { return authorityLoss() }
        guard let request = try? requestFactory.finalizationRequest(for: fixture) else {
            return invalidFixtureResult()
        }
        return await dispatch(
            request: request,
            key: fixture.key,
            runtimeBinding: runtimeBinding,
            cancelPhase: cancelPhase,
            measurementObserver: measurementObserver
        )
    }

    private func dispatch(
        request: Phase2InferenceRequest,
        key: Phase2LiveQualificationTrialKey,
        runtimeBinding: Phase2LiveQualificationRuntimeBinding,
        cancelPhase: Bool,
        measurementObserver: Phase2LiveQualificationAttemptMeasurementObserver?
    ) async -> PhaseResult {
        transition(to: .running(key, request.phase))
        activeDispatchedPhaseRequests.append(.init(
            trialKey: key,
            phase: request.phase,
            requestID: request.requestID
        ))
        let result: Phase2ReadyInferenceExecutionResult
        if cancelPhase {
            if let controlledCoordinator = coordinator
                as? any Phase2ControlledCancellationCoordinating
            {
                let barrier = Phase2ControlledCancellationBarrier(
                    requestID: request.requestID
                )
                let phaseTask = Task { @MainActor in
                    await controlledCoordinator.run(
                        request: request,
                        measurementObserver: measurementObserver,
                        controlledCancellationBarrier: barrier
                    )
                }
                if await barrier.waitForProviderDispatch() {
                    phaseTask.cancel()
                }
                result = await phaseTask.value
            } else {
                let phaseTask = Task { @MainActor [coordinator] in
                    await coordinator.run(
                        request: request,
                        measurementObserver: measurementObserver
                    )
                }
                if let measurementObserver,
                   await measurementObserver.waitForAdmissionResolution()
                {
                    phaseTask.cancel()
                } else if measurementObserver == nil {
                    // Compatibility-only test coordinators do not expose the production barrier.
                    await Task.yield()
                    phaseTask.cancel()
                }
                result = await phaseTask.value
            }
        } else {
            result = await coordinator.run(
                request: request,
                measurementObserver: measurementObserver
            )
        }

        // Close timing only after the provider has drained and the final runtime validation has
        // executed. Semantic scoring below must not inflate provider-attempt latency.
        let callerCancelled = Task.isCancelled
        let runtimeIsCurrent = runtimeValidator.isCurrent(runtimeBinding)
        measurementObserver?.recordValidatedTerminalBoundary()

        // A provider/coordinator that ignores cancellation may still return a semantic result.
        // The caller's cancellation must win before classification or finalization can proceed.
        guard !callerCancelled else { return callerCancellation() }
        guard runtimeIsCurrent else { return authorityLoss() }
        guard measurementObserver?.hasFailed != true else {
            return .abort(
                status: .failed,
                current: .unavailable,
                reason: .runAborted
            )
        }

        switch result {
        case .notReady:
            return .abort(status: .failed, current: .unavailable, reason: .providerNotReady)
        case .busy:
            return .abort(status: .failed, current: .unavailable, reason: .coordinatorBusy)
        case .invalidRequest:
            return invalidFixtureResult()
        case .providerAuthorityChanged:
            return authorityLoss()
        case .finished(let lease, let outcome):
            guard lease == runtimeBinding.readyLease else { return authorityLoss() }
            switch outcome.disposition {
            case .cancelled where cancelPhase:
                return .outcome(outcome)
            case .cancelled:
                return callerCancellation()
            case .providerFailed:
                return .abort(
                    status: .failed,
                    current: .unavailable,
                    reason: .providerFailed
                )
            case .interrupted:
                return .abort(
                    status: .failed,
                    current: .unavailable,
                    reason: .providerInterrupted
                )
            case .completed, .awaitingTools, .protocolViolation, .limitExceeded:
                return .outcome(outcome)
            }
        }
    }

    private func record(
        _ classification: Phase2LiveQualificationClassification?,
        fixture: Phase2LiveQualificationTrialFixture,
        collector: inout Phase2LiveQualificationObservationCollector
    ) -> Bool {
        guard let classification else { return false }
        do {
            try collector.record(classification, for: fixture.key)
            return true
        } catch {
            return false
        }
    }

    private func terminate(
        _ result: PhaseResult,
        collector: inout Phase2LiveQualificationObservationCollector,
        measurementObserver: Phase2LiveQualificationAttemptMeasurementObserver? = nil
    ) -> Phase2LiveQualificationExecution {
        finishMeasurement(measurementObserver, collector: &collector)
        guard case .abort(let status, let current, let reason) = result else {
            return invalidFixture(collector: &collector)
        }
        return terminate(
            collector: &collector,
            status: status,
            current: current,
            reason: reason
        )
    }

    private func invalidFixture(
        collector: inout Phase2LiveQualificationObservationCollector,
        measurementObserver: Phase2LiveQualificationAttemptMeasurementObserver? = nil
    ) -> Phase2LiveQualificationExecution {
        finishMeasurement(measurementObserver, collector: &collector)
        return terminate(
            collector: &collector,
            status: .failed,
            current: .unavailable,
            reason: .invalidFixture
        )
    }

    private func terminate(
        collector: inout Phase2LiveQualificationObservationCollector,
        status: Phase2QualificationRunTerminationStatus,
        current: Phase2QualificationProbeOutcome?,
        reason: Phase2LiveQualificationReasonCode
    ) -> Phase2LiveQualificationExecution {
        guard let execution = try? collector.terminate(
            status: status,
            current: current,
            reason: reason
        ) else {
            transition(to: .finished)
            return stamped(failedExecution(
                for: collector.expectedOrderForFailure,
                reason: .runAborted
            ))
        }
        transition(to: .finished)
        return stamped(execution)
    }

    private func callerCancellation() -> PhaseResult {
        .abort(status: .cancelled, current: .cancelled, reason: .callerCancelled)
    }

    private func authorityLoss() -> PhaseResult {
        .abort(status: .failed, current: .unavailable, reason: .authorityChanged)
    }

    private func invalidFixtureResult() -> PhaseResult {
        .abort(status: .failed, current: .unavailable, reason: .invalidFixture)
    }

    private func makeMeasurementObserver(
        for fixture: Phase2LiveQualificationTrialFixture
    ) -> Phase2LiveQualificationAttemptMeasurementObserver? {
        guard let measurementConfiguration,
              let key = try? Phase2QualificationTrialKey(
                  requirementID: fixture.key.probeID,
                  trialIndex: fixture.key.trial,
                  attempt: 1
              )
        else { return nil }
        guard let activeRunTiming else { return nil }
        return .init(
            trialKey: key,
            configuration: measurementConfiguration,
            runTiming: activeRunTiming
        )
    }

    @discardableResult
    private func finishMeasurement(
        _ observer: Phase2LiveQualificationAttemptMeasurementObserver?,
        collector: inout Phase2LiveQualificationObservationCollector
    ) -> Bool {
        guard let observer else { return measurementConfiguration == nil }
        guard observer.wasAdmitted else { return false }
        if let sample = observer.finish(),
           observer.hasCompletePhaseClosure,
           measurementIsComplete(sample) {
            do {
                try collector.recordAdmission(sample.trialKey)
                try collector.recordMeasurement(sample)
                return !observer.hasFailed
            } catch {
                return false
            }
        } else if let key = measurementTrialKey(for: observer) {
            try? collector.recordAdmission(key)
        }
        return false
    }

    private func finishFinalizedAttempt(
        _ observer: Phase2LiveQualificationAttemptMeasurementObserver?,
        fixture: Phase2LiveQualificationTrialFixture,
        collector: inout Phase2LiveQualificationObservationCollector
    ) -> Bool {
        guard finishMeasurement(observer, collector: &collector) else { return false }
        guard measurementConfiguration != nil else { return true }
        guard let evidence = try? collector.finalizedEvidence(for: fixture.key) else {
            return false
        }
        return onFinalizedTrial(evidence)
    }

    private func measurementIsComplete(
        _ sample: Phase2QualificationAttemptMeasurement
    ) -> Bool {
        guard let metricPlan = measurementConfiguration?.metricPlan else { return false }
        guard metricPlan.containsEveryApplicableValue(in: sample) else { return false }
        let cancellationApplies = metricPlan.applicableTrialKeys[
            .cancellationLatencyMilliseconds
        ]?.contains(sample.trialKey) == true
        guard cancellationApplies else { return true }
        guard let maximum = measurementConfiguration?
                .maximumCancellationDrainMilliseconds,
              maximum >= 0,
              let observed = sample.cancellationLatencyMilliseconds
        else { return false }
        return observed <= maximum
    }

    private func measurementFailure(
        collector: inout Phase2LiveQualificationObservationCollector
    ) -> Phase2LiveQualificationExecution {
        terminate(
            collector: &collector,
            status: .failed,
            current: nil,
            reason: .runAborted
        )
    }

    private func measurementTrialKey(
        for observer: Phase2LiveQualificationAttemptMeasurementObserver
    ) -> Phase2QualificationTrialKey? {
        observer.trialKeyForCollection
    }

    private func transition(to state: Phase2LiveQualificationRunnerState) {
        self.state = state
        onTransition(state)
    }

    private func failedExecution(
        for expectedOrder: [Phase2LiveQualificationTrialKey],
        reason: Phase2LiveQualificationReasonCode
    ) -> Phase2LiveQualificationExecution {
        .init(
            terminationStatus: .failed,
            observations: expectedOrder.compactMap { key in
                try? .init(
                    probeID: key.probeID,
                    trial: key.trial,
                    attempt: 1,
                    outcome: .notRun,
                    reasonCode: reason.rawValue,
                    evidenceDigest: nil
                )
            }
        )
    }

    private func stamped(
        _ execution: Phase2LiveQualificationExecution
    ) -> Phase2LiveQualificationExecution {
        let timing = activeRunTiming?.snapshot
        return .init(
            terminationStatus: execution.terminationStatus,
            observations: execution.observations,
            admittedAttemptKeys: execution.admittedAttemptKeys,
            measurementSamples: execution.measurementSamples,
            firstAdmissionEpochMilliseconds: timing?.start,
            terminalEpochMilliseconds: timing?.end,
            dispatchEvidence: .init(
                phaseRequests: activeDispatchedPhaseRequests
            )
        )
    }
}

/// Closed app-owned execution path for the canonical 64 live trials. It intentionally emits only
/// bounded live execution evidence. The CoreTests-only Gate-G4 composer remains the sole authority
/// that may combine it with verified deterministic receipts into the complete 163-trial report.
@MainActor
enum Phase2ProductionLiveQualificationExecutor {
    enum ExecutionError: Error, Equatable, Sendable {
        case preparedBindingMismatch
        case invalidStandardPlan
        case evidenceSinkRejected
    }

    static func executeStandard(
        prepared: Phase2PreparedLiveQualification,
        controller: Phase2LocalAIProviderController,
        processAuthority: any Phase2ProductionLiveQualificationProcessAuthorizing,
        captureFreshObservation:
            @escaping Phase2LiveQualificationRuntimeValidator.Capture,
        onFinalizedTrial: @escaping @MainActor
            (Phase2LiveQualificationFinalizedTrialEvidence) -> Bool = { _ in true },
        onTerminalExecution: @escaping @MainActor
            (Phase2LiveQualificationExecution) -> Bool = { _ in true },
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) async throws -> Phase2LiveQualificationEvidence {
        let standard = Phase2QualificationProfileContract.resolve(selector).production
        let catalog = standard.liveScenarioCatalog
        guard let environmentIdentity = try? prepared.evidenceBinding
            .qualificationEnvironment.contentIdentity(),
              prepared.evidenceBinding.productionDefinition == standard.definitionIdentity,
              prepared.evidenceBinding.qualificationPolicy == standard.policyIdentity,
              prepared.evidenceBinding.protocolProbeCatalog
                == standard.protocolProbeCatalogIdentity,
              prepared.evidenceBinding.liveCorpus == catalog.identity,
              prepared.evidenceBinding.environment == environmentIdentity,
              standard.environmentPolicy.accepts(
                  prepared.evidenceBinding.qualificationEnvironment
              )
        else { throw ExecutionError.preparedBindingMismatch }

        guard let plan = try? Phase2LiveQualificationPlan(
            policy: standard.policy,
            catalog: catalog,
            fixtures: catalog.productionFixtures()
        ) else { throw ExecutionError.invalidStandardPlan }

        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            workerProcessReceiptObserver: processAuthority
        )
        let runtimeValidator = Phase2LiveQualificationRuntimeValidator(
            prepared: prepared,
            capture: captureFreshObservation,
            selector: selector
        )
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: runtimeValidator,
            scorer: Phase2ProductionLiveQualificationScorer(),
            measurementConfiguration: .init(
                metricPlan: standard.metricPlan,
                clock: Phase2ContinuousMonotonicClock(),
                residentSetSampler: processAuthority.residentSetSampler,
                maximumCancellationDrainMilliseconds: standard.thresholdSet.thresholds
                    .first(where: {
                        $0.requirementID
                            == "live.safety.cancellation-without-semantic-output"
                            && $0.rule.measurement == .cancellationLatencyMilliseconds
                            && $0.rule.scope == .perAttempt
                            && $0.rule.comparison == .maximumInclusive
                    })?.rule.threshold
            ),
            onFinalizedTrial: onFinalizedTrial
        )
        let execution = await runner.run(
            plan: plan,
            runtimeBinding: prepared.runtimeBinding
        )
        guard onTerminalExecution(execution) else {
            throw ExecutionError.evidenceSinkRejected
        }
        let runtimeProvenance = try processAuthority.finishRuntimeProvenance(
            for: execution
        )
        return try Phase2QualificationRunBuilder().buildLiveEvidence(
            environment: prepared.evidenceBinding.qualificationEnvironment,
            runtimeProvenance: runtimeProvenance,
            execution: execution
        )
    }
}

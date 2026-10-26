import Foundation
import XCTest
@testable import MacScope

@MainActor
final class Phase2LiveQualificationRunnerTests: XCTestCase {
    func testPlanExpandsExactPolicyCatalogDenominatorAndRejectsCorrelationReuse() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let policy = Phase2ProductionQualificationPolicy.standard.policy
        let fixtures = try makeFixtures(catalog: catalog)

        let plan = try Phase2LiveQualificationPlan(
            policy: policy,
            catalog: catalog,
            fixtures: fixtures
        )

        XCTAssertEqual(plan.scheduledTrials.count, 64)
        XCTAssertEqual(plan.expectedTrialOrder, fixtures.map(\.key))
        XCTAssertEqual(plan.scheduledTrials.map(\.scenario.id), fixtures.map(\.key.probeID))

        XCTAssertThrowsError(try Phase2LiveQualificationPlan(
            policy: policy,
            catalog: catalog,
            fixtures: Array(fixtures.dropLast())
        )) { error in
            XCTAssertEqual(error as? Phase2LiveQualificationPlan.ValidationError, .policyPlanMismatch)
        }

        var reused = fixtures
        let last = fixtures.last!
        reused[reused.index(before: reused.endIndex)] = try makeTrial(
            probeID: last.key.probeID,
            trial: last.key.trial,
            offset: 10
        )
        XCTAssertThrowsError(try Phase2LiveQualificationPlan(
            policy: policy,
            catalog: catalog,
            fixtures: reused
        )) { error in
            XCTAssertEqual(error as? Phase2LiveQualificationPlan.ValidationError, .duplicateCorrelationID)
        }
    }

    func testRunnerDispatchesEveryFrozenPhaseFlowSeriallyWithExactBindingChecks() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        let authority = RecordingQualificationAuthorityValidator()
        let scorer = CatalogQualificationScorer(catalog: catalog)
        var states: [Phase2LiveQualificationRunnerState] = []
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: authority,
            scorer: scorer,
            measurementConfiguration: try makeRunnerMeasurementConfiguration(),
            onTransition: { states.append($0) }
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .completed)
        XCTAssertEqual(execution.observations.count, 64)
        XCTAssertEqual(execution.admittedAttemptKeys.count, 64)
        XCTAssertEqual(execution.measurementSamples.count, 64)
        XCTAssertNotNil(execution.firstAdmissionEpochMilliseconds)
        XCTAssertNotNil(execution.terminalEpochMilliseconds)
        XCTAssertLessThanOrEqual(
            execution.firstAdmissionEpochMilliseconds!,
            execution.terminalEpochMilliseconds!
        )
        XCTAssertTrue(execution.observations.allSatisfy { $0.outcome == .passed })
        XCTAssertEqual(coordinator.requests.count, 74)
        XCTAssertEqual(coordinator.requests.filter { $0.phase == .toolSelection }.count, 28)
        XCTAssertEqual(coordinator.requests.filter { $0.phase == .finalization }.count, 46)
        XCTAssertTrue(coordinator.requests.allSatisfy {
            $0.protocolVersion.rawValue
                == Phase2AIWorkerProductionProtocol.inferenceVersion
        })
        XCTAssertEqual(coordinator.maximumConcurrentCallCount, 1)
        XCTAssertEqual(coordinator.cancelledRequestCount, 3)
        XCTAssertEqual(authority.checkedBindings.count, 2 + (2 * coordinator.requests.count))
        XCTAssertTrue(authority.checkedBindings.allSatisfy { $0 == binding })
        XCTAssertEqual(Set(coordinator.requests.map(\.requestID)).count, coordinator.requests.count)
        XCTAssertEqual(states.first, .preflighting)
        XCTAssertEqual(states.suffix(3), [.collectingMeasurements, .assemblingRun, .finished])
    }

    func testCancellationTrialFailsClosedWhenDrainThresholdIsUnavailable() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: .init(
                metricPlan: Phase2ProductionQualificationPolicy.standard.metricPlan,
                clock: RunnerAdvancingClock(),
                residentSetSampler: RunnerConstantResidentSetSampler()
            )
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .failed)
        XCTAssertLessThan(coordinator.requests.count, 74)
        XCTAssertEqual(
            execution.dispatchEvidence?.phaseRequests.last?.trialKey.probeID,
            "live.safety.cancellation-without-semantic-output"
        )
    }

    func testCancellationTrialFailsClosedWhenDrainExceedsFrozenThreshold() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: .init(
                metricPlan: Phase2ProductionQualificationPolicy.standard.metricPlan,
                clock: RunnerAdvancingClock(stepNanoseconds: 2_001_000_000),
                residentSetSampler: RunnerConstantResidentSetSampler(),
                maximumCancellationDrainMilliseconds: 2_000
            )
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .failed)
        XCTAssertLessThan(coordinator.requests.count, 74)
        XCTAssertEqual(
            execution.dispatchEvidence?.phaseRequests.last?.trialKey.probeID,
            "live.safety.cancellation-without-semantic-output"
        )
    }

    func testFinalizedTrialSinkReceivesCanonicalCompleteEvidenceExactlyOnce() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        let measurementConfiguration = try makeRunnerMeasurementConfiguration()
        var finalized: [Phase2LiveQualificationFinalizedTrialEvidence] = []
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: measurementConfiguration,
            onFinalizedTrial: {
                finalized.append($0)
                return true
            }
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .completed)
        XCTAssertEqual(finalized.count, plan.expectedTrialOrder.count)
        XCTAssertEqual(finalized.map(\.observation), execution.observations)
        XCTAssertEqual(finalized.map(\.admittedAttemptKey), execution.admittedAttemptKeys)
        XCTAssertEqual(finalized.map(\.measurementSample), execution.measurementSamples)
        XCTAssertEqual(
            finalized.map { $0.observation.trialID },
            plan.expectedTrialOrder.map(\.trialID)
        )
        for evidence in finalized {
            XCTAssertEqual(evidence.observation.attemptID, evidence.admittedAttemptKey.canonicalID)
            XCTAssertEqual(evidence.admittedAttemptKey, evidence.measurementSample.trialKey)
            XCTAssertTrue(
                measurementConfiguration.metricPlan.containsEveryApplicableValue(
                    in: evidence.measurementSample
                )
            )
        }
    }

    func testFinalizedTrialSinkRejectionAbortsWithoutRetryOrLaterDispatch() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        var finalized: [Phase2LiveQualificationFinalizedTrialEvidence] = []
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: try makeRunnerMeasurementConfiguration(),
            onFinalizedTrial: {
                finalized.append($0)
                return false
            }
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .failed)
        XCTAssertEqual(finalized.count, 1)
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertEqual(execution.observations.first, finalized.first?.observation)
        XCTAssertEqual(execution.admittedAttemptKeys, finalized.map(\.admittedAttemptKey))
        XCTAssertEqual(execution.measurementSamples, finalized.map(\.measurementSample))
        XCTAssertTrue(execution.observations.dropFirst().allSatisfy {
            $0.outcome == .notRun
                && $0.reasonCode == Phase2LiveQualificationReasonCode.runAborted.rawValue
        })
    }

    func testCollectorFinalizedEvidenceRequiresJustRecordedCanonicalCompleteTuple() throws {
        let liveKey = Phase2LiveQualificationTrialKey(probeID: "live.test", trial: 1)
        let attemptKey = try Phase2QualificationTrialKey(
            requirementID: liveKey.probeID,
            trialIndex: liveKey.trial,
            attempt: 1
        )
        let sample = try Phase2QualificationAttemptMeasurement(
            trialKey: attemptKey,
            totalLatencyMilliseconds: 10,
            timeToFirstSemanticEventMilliseconds: nil,
            phaseUsages: [],
            peakResidentBytes: nil,
            cancellationLatencyMilliseconds: nil,
            measurementScopeIdentity: component("phase2.r1.test-checkpoint-scope", "4")
        )
        var collector = try Phase2LiveQualificationObservationCollector(
            expectedTrialOrder: [liveKey]
        )

        XCTAssertThrowsError(try collector.finalizedEvidence(for: liveKey))
        try collector.record(try .passed(evidenceDigest: digest("5")), for: liveKey)
        XCTAssertThrowsError(try collector.finalizedEvidence(for: liveKey))
        try collector.recordAdmission(attemptKey)
        XCTAssertThrowsError(try collector.finalizedEvidence(for: liveKey))
        try collector.recordMeasurement(sample)

        let finalized = try collector.finalizedEvidence(for: liveKey)

        XCTAssertEqual(finalized.observation.trialID, liveKey.trialID)
        XCTAssertEqual(finalized.admittedAttemptKey, attemptKey)
        XCTAssertEqual(finalized.measurementSample, sample)
        XCTAssertThrowsError(try collector.finalizedEvidence(for: liveKey))
    }

    func testProductionExecutorDeclaresBoundedTrialAndTerminalEvidenceSinks() throws {
        let source = try String(
            contentsOf: TestSourceRoot.fileURL(#filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Services/Phase2/Phase2LiveQualificationRunner.swift"),
            encoding: .utf8
        )
        guard let executorRange = source.range(
            of: "enum Phase2ProductionLiveQualificationExecutor"
        ) else {
            return XCTFail("missing production executor")
        }
        let executor = String(source[executorRange.lowerBound...])
        XCTAssertTrue(executor.contains("onFinalizedTrial:"))
        XCTAssertTrue(executor.contains("onTerminalExecution:"))
        XCTAssertTrue(executor.contains("case evidenceSinkRejected"))
        XCTAssertFalse(executor.contains("FileManager"))
        XCTAssertFalse(executor.contains("write("))
        XCTAssertLessThan(
            try XCTUnwrap(executor.range(of: "onTerminalExecution(execution)")?.lowerBound),
            try XCTUnwrap(executor.range(of: "finishRuntimeProvenance")?.lowerBound)
        )
    }

    func testFirstMissingRequiredUsageAbortsBeforeAnyLaterDispatch() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = MissingUsageQualificationCoordinator(lease: binding.readyLease)
        let firstTrial = try Phase2QualificationTrialKey(
            requirementID: plan.expectedTrialOrder[0].probeID,
            trialIndex: plan.expectedTrialOrder[0].trial,
            attempt: 1
        )
        let standardMetricPlan = Phase2ProductionQualificationPolicy.standard.metricPlan
        var applicableTrialKeys = standardMetricPlan.applicableTrialKeys
        applicableTrialKeys[.generatedTokenCount, default: []].insert(firstTrial)
        let metricPlanRequiringFirstUsage = try Phase2QualificationMetricPlan(
            applicableTrialKeys: applicableTrialKeys,
            varianceRequirementID: standardMetricPlan.varianceRequirementID
        )
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: try makeRunnerMeasurementConfiguration(
                metricPlan: metricPlanRequiringFirstUsage
            )
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .failed)
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertEqual(execution.observations.first?.outcome, .unavailable)
        XCTAssertEqual(execution.observations.first?.reasonCode, "run-aborted")
        XCTAssertTrue(execution.observations.dropFirst().allSatisfy {
            $0.outcome == .notRun
        })
        XCTAssertEqual(execution.admittedAttemptKeys.count, 1)
        XCTAssertTrue(execution.measurementSamples.isEmpty)
    }

    func testCallerCancellationAfterAwaitWinsRaceAndNeverDispatchesFinalization() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = FirstCallGateQualificationCoordinator(lease: binding.readyLease)
        let scorer = CatalogQualificationScorer(catalog: catalog)
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: scorer,
            measurementConfiguration: try makeRunnerMeasurementConfiguration()
        )

        let task = Task { await runner.run(plan: plan, runtimeBinding: binding) }
        await coordinator.waitUntilFirstCallStarts()
        task.cancel()
        coordinator.releaseFirstCall()
        let execution = await task.value

        XCTAssertEqual(execution.terminationStatus, .cancelled)
        XCTAssertEqual(execution.observations.first?.outcome, .cancelled)
        XCTAssertEqual(execution.admittedAttemptKeys.count, 1)
        XCTAssertEqual(execution.measurementSamples.count, 1)
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection])
        XCTAssertTrue(scorer.selectionProbeIDs.isEmpty)
        XCTAssertTrue(scorer.finalizationProbeIDs.isEmpty)
    }

    func testCallerCancellationAfterSelectionClassificationWinsBeforeFinalization() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        let cancellation = QualificationTaskCancellationBox()
        let target = Phase2LiveQualificationTrialKey(
            probeID: "live.performance.standard-turn",
            trial: 1
        )
        let scorer = CatalogQualificationScorer(
            catalog: catalog,
            onSelection: { key in
                if key == target { cancellation.cancel() }
            }
        )
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: scorer,
            measurementConfiguration: try makeRunnerMeasurementConfiguration()
        )

        let task = Task { await runner.run(plan: plan, runtimeBinding: binding) }
        cancellation.task = task
        let execution = await task.value

        XCTAssertEqual(execution.terminationStatus, .cancelled)
        XCTAssertEqual(execution.observations[54].outcome, .cancelled)
        XCTAssertEqual(execution.admittedAttemptKeys.count, 55)
        XCTAssertEqual(execution.measurementSamples.count, 55)
        XCTAssertEqual(coordinator.requests.count, 55)
        XCTAssertEqual(coordinator.requests.last?.phase, .toolSelection)
        XCTAssertFalse(scorer.finalizationProbeIDs.contains(target.probeID))
    }

    func testTwoPhaseSelectionMismatchSkipsFinalizationAndContinuesDenominator() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        let failedKey = Phase2LiveQualificationTrialKey(
            probeID: "live.performance.standard-turn",
            trial: 1
        )
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(
                catalog: catalog,
                failedSelectionKey: failedKey
            )
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .completed)
        XCTAssertEqual(execution.observations[54].outcome, .failed)
        XCTAssertEqual(execution.observations.last?.outcome, .passed)
        XCTAssertEqual(coordinator.requests.count, 73)
    }

    func testReentrantRunIsRejectedWithoutMutatingActiveState() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = FirstCallGateQualificationCoordinator(lease: binding.readyLease)
        var transitions: [Phase2LiveQualificationRunnerState] = []
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: RecordingQualificationAuthorityValidator(),
            scorer: CatalogQualificationScorer(catalog: catalog),
            onTransition: { transitions.append($0) }
        )

        let active = Task { await runner.run(plan: plan, runtimeBinding: binding) }
        await coordinator.waitUntilFirstCallStarts()
        let stateBeforeReentry = runner.state
        let transitionCountBeforeReentry = transitions.count

        let rejected = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(rejected.terminationStatus, .failed)
        XCTAssertEqual(rejected.observations.count, plan.expectedTrialOrder.count)
        XCTAssertTrue(rejected.observations.allSatisfy { $0.outcome == .notRun })
        XCTAssertTrue(rejected.observations.allSatisfy {
            $0.reasonCode == Phase2LiveQualificationReasonCode.runnerBusy.rawValue
        })
        XCTAssertEqual(runner.state, stateBeforeReentry)
        XCTAssertEqual(transitions.count, transitionCountBeforeReentry)
        XCTAssertEqual(coordinator.requests.count, 1)

        active.cancel()
        coordinator.releaseFirstCall()
        _ = await active.value
    }

    func testRuntimeDriftBeforeFinalizationAbortsWithoutConstructingSecondPhase() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let binding = try makeRuntimeBinding()
        let coordinator = RecordingQualificationCoordinator(lease: binding.readyLease)
        // The first two-phase trial follows 54 one-phase trials. Initial + two checks per prior
        // phase + selection pre/post succeed; the adjacent finalization preflight then fails.
        let authority = RecordingQualificationAuthorityValidator(
            scriptedResults: Array(repeating: true, count: 111) + [false]
        )
        let runner = Phase2LiveQualificationRunner(
            coordinator: coordinator,
            runtimeValidator: authority,
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: try makeRunnerMeasurementConfiguration()
        )

        let execution = await runner.run(plan: plan, runtimeBinding: binding)

        XCTAssertEqual(execution.terminationStatus, .failed)
        XCTAssertEqual(coordinator.requests.count, 55)
        XCTAssertEqual(coordinator.requests.last?.phase, .toolSelection)
        XCTAssertEqual(execution.observations[54].outcome, .unavailable)
        XCTAssertEqual(execution.admittedAttemptKeys.count, 55)
        XCTAssertEqual(execution.measurementSamples.count, 55)
        XCTAssertEqual(
            execution.observations[54].reasonCode,
            Phase2LiveQualificationReasonCode.authorityChanged.rawValue
        )
    }

    func testPreAdmissionRuntimeFailureProducesNoMeasurementSample() async throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let plan = try makePlan(catalog: catalog)
        let runner = Phase2LiveQualificationRunner(
            coordinator: RecordingQualificationCoordinator(lease: try makeLease()),
            runtimeValidator: RecordingQualificationAuthorityValidator(
                scriptedResults: [false]
            ),
            scorer: CatalogQualificationScorer(catalog: catalog),
            measurementConfiguration: try makeRunnerMeasurementConfiguration()
        )

        let execution = await runner.run(
            plan: plan,
            runtimeBinding: try makeRuntimeBinding()
        )

        XCTAssertEqual(execution.terminationStatus, .failed)
        XCTAssertTrue(execution.admittedAttemptKeys.isEmpty)
        XCTAssertTrue(execution.measurementSamples.isEmpty)
        XCTAssertEqual(execution.observations.first?.outcome, .unavailable)
    }

    func testRunBuilderRejectsIncompleteRequiredLiveMeasurements() throws {
        let standard = Phase2ProductionQualificationPolicy.standard
        let prepared = try makePreparedQualification()
        let scope = component("phase2.r1.test-measurement-scope", "a")
        let runtime = try makeRuntimeProvenance(
            binding: prepared.runtimeBinding,
            scope: scope,
            workerManifestDigest: Phase2ModelProfileCanonicalizer().protocolManifestDigest(
                for: prepared.profile.protocolManifest
            )
        )
        let allKeys = try standard.liveRequirements.flatMap { requirement in
            try (1...requirement.requiredTrialCount).map { trial in
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: trial,
                    attempt: 1
                )
            }
        }
        let observations = try allKeys.map { key in
            try Phase2QualificationProbeObservation(
                probeID: key.requirementID,
                trial: key.trialIndex,
                outcome: .passed,
                evidenceDigest: digest("b")
            )
        }
        let samples = try allKeys.map { key in
            try Phase2QualificationAttemptMeasurement(
                trialKey: key,
                totalLatencyMilliseconds: Int64(key.trialIndex * 100),
                timeToFirstSemanticEventMilliseconds: nil,
                phaseUsages: [],
                peakResidentBytes: nil,
                cancellationLatencyMilliseconds: nil,
                measurementScopeIdentity: scope
            )
        }
        let execution = Phase2LiveQualificationExecution(
            terminationStatus: .completed,
            observations: observations,
            admittedAttemptKeys: allKeys,
            measurementSamples: samples,
            firstAdmissionEpochMilliseconds: 1_000,
            terminalEpochMilliseconds: 2_000
        )
        XCTAssertThrowsError(try Phase2QualificationRunBuilder().buildLiveEvidence(
            environment: prepared.evidenceBinding.qualificationEnvironment,
            runtimeProvenance: runtime,
            execution: execution
        )) {
            XCTAssertEqual(
                $0 as? Phase2QualificationEvidenceBundle.ValidationError,
                .incompleteRequiredMeasurement
            )
        }
    }

    func testRunnerSourcesCannotAcquireReadWorkspaceLifecycleOrRetryAuthority() throws {
        let testURL = TestSourceRoot.fileURL(#filePath)
        let macScopeRoot = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Models/Phase2/Phase2LiveQualification.swift",
            "Services/Phase2/Phase2LiveQualificationRequestFactory.swift",
            "Services/Phase2/Phase2LiveQualificationObservationCollector.swift",
            "Services/Phase2/Phase2LiveQualificationRunner.swift",
            "Services/Phase2/Phase2QualificationRunBuilder.swift",
        ]
        let forbidden = [
            "WorkspaceStore", "Phase2PreparedRead", "Phase2ReadProjector",
            "executePhase2Read", "loadModel", "unloadModel", "retryAttempt",
        ]

        for path in relativePaths {
            let source = try String(
                contentsOf: macScopeRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            for symbol in forbidden {
                XCTAssertFalse(source.contains(symbol), "\(path) must not reference \(symbol)")
            }
        }
    }
}

@MainActor
private final class RecordingQualificationCoordinator:
    Phase2LiveQualificationCoordinating,
    Phase2ControlledCancellationCoordinating
{
    private let lease: Phase2ReadyInferenceLease
    private(set) var requests: [Phase2InferenceRequest] = []
    private(set) var maximumConcurrentCallCount = 0
    private(set) var cancelledRequestCount = 0
    private var concurrentCallCount = 0

    init(lease: Phase2ReadyInferenceLease) {
        self.lease = lease
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        await run(request: request, measurementObserver: nil)
    }

    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?
    ) async -> Phase2ReadyInferenceExecutionResult {
        requests.append(request)
        measurementObserver?.admitted(phase: request.phase)
        measurementObserver?.generationBegan(phase: request.phase)
        concurrentCallCount += 1
        maximumConcurrentCallCount = max(maximumConcurrentCallCount, concurrentCallCount)
        defer { concurrentCallCount -= 1 }
        await Task.yield()
        if Task.isCancelled {
            cancelledRequestCount += 1
            measurementObserver?.cancellationBegan(phase: request.phase)
            measurementObserver?.providerDrained(phase: request.phase)
            return .finished(lease: lease, outcome: cancelledOutcome())
        }
        measurementObserver?.acceptedSemantic(phase: request.phase)
        measurementObserver?.acceptedEvent(phase: request.phase)
        measurementObserver?.usageAccepted(
            phase: request.phase,
            usage: Phase2ProviderUsage(
                promptTokens: 10,
                completionTokens: 5,
                totalTokens: 15
            )!
        )
        measurementObserver?.acceptedEvent(phase: request.phase)
        measurementObserver?.providerDrained(phase: request.phase)
        return .finished(
            lease: lease,
            outcome: request.phase == .toolSelection ? selectionOutcome() : finalizationOutcome()
        )
    }

    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?,
        controlledCancellationBarrier: Phase2ControlledCancellationBarrier
    ) async -> Phase2ReadyInferenceExecutionResult {
        requests.append(request)
        measurementObserver?.admitted(phase: request.phase)
        measurementObserver?.generationBegan(phase: request.phase)
        concurrentCallCount += 1
        maximumConcurrentCallCount = max(maximumConcurrentCallCount, concurrentCallCount)
        defer { concurrentCallCount -= 1 }

        controlledCancellationBarrier.providerDidDispatch(.init(
            requestID: request.requestID
        ))
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            // The runner owns cancellation after the exact synthetic HTTP-header boundary.
        }

        guard Task.isCancelled else {
            controlledCancellationBarrier.providerDidFinish()
            return .providerAuthorityChanged
        }
        cancelledRequestCount += 1
        measurementObserver?.cancellationBegan(phase: request.phase)
        measurementObserver?.providerDrained(phase: request.phase)
        controlledCancellationBarrier.providerDidFinish()
        return .finished(lease: lease, outcome: cancelledOutcome())
    }
}

@MainActor
private final class MissingUsageQualificationCoordinator:
    Phase2LiveQualificationCoordinating
{
    private let lease: Phase2ReadyInferenceLease
    private(set) var requests: [Phase2InferenceRequest] = []

    init(lease: Phase2ReadyInferenceLease) {
        self.lease = lease
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        await run(request: request, measurementObserver: nil)
    }

    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?
    ) async -> Phase2ReadyInferenceExecutionResult {
        requests.append(request)
        measurementObserver?.admitted(phase: request.phase)
        measurementObserver?.generationBegan(phase: request.phase)
        measurementObserver?.acceptedSemantic(phase: request.phase)
        measurementObserver?.acceptedEvent(phase: request.phase)
        measurementObserver?.providerDrained(phase: request.phase)
        return .finished(
            lease: lease,
            outcome: request.phase == .toolSelection
                ? selectionOutcome()
                : finalizationOutcome()
        )
    }
}

@MainActor
private final class FirstCallGateQualificationCoordinator: Phase2LiveQualificationCoordinating {
    private let lease: Phase2ReadyInferenceLease
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var firstCallStarted = false
    private var firstCallReleased = false
    private(set) var requests: [Phase2InferenceRequest] = []

    init(lease: Phase2ReadyInferenceLease) {
        self.lease = lease
    }

    func waitUntilFirstCallStarts() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCall() {
        firstCallReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        await run(request: request, measurementObserver: nil)
    }

    func run(
        request: Phase2InferenceRequest,
        measurementObserver: (any Phase2InferenceMeasurementObserving)?
    ) async -> Phase2ReadyInferenceExecutionResult {
        requests.append(request)
        measurementObserver?.admitted(phase: request.phase)
        measurementObserver?.generationBegan(phase: request.phase)
        if requests.count == 1 {
            firstCallStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !firstCallReleased {
                await withCheckedContinuation { releaseContinuation = $0 }
            }
        }
        if Task.isCancelled {
            measurementObserver?.cancellationBegan(phase: request.phase)
        }
        measurementObserver?.acceptedSemantic(phase: request.phase)
        measurementObserver?.acceptedEvent(phase: request.phase)
        measurementObserver?.usageAccepted(
            phase: request.phase,
            usage: Phase2ProviderUsage(
                promptTokens: 10,
                completionTokens: 5,
                totalTokens: 15
            )!
        )
        measurementObserver?.acceptedEvent(phase: request.phase)
        measurementObserver?.providerDrained(phase: request.phase)
        // Deliberately ignore caller cancellation and return a semantic result. The runner's
        // post-await cancellation check must win this race.
        return .finished(
            lease: lease,
            outcome: request.phase == .toolSelection ? selectionOutcome() : finalizationOutcome()
        )
    }
}

@MainActor
private final class RecordingQualificationAuthorityValidator:
    Phase2LiveQualificationRuntimeValidating
{
    private var scriptedResults: [Bool]
    private(set) var checkedBindings: [Phase2LiveQualificationRuntimeBinding] = []

    init(scriptedResults: [Bool] = []) {
        self.scriptedResults = scriptedResults
    }

    func isCurrent(_ binding: Phase2LiveQualificationRuntimeBinding) -> Bool {
        checkedBindings.append(binding)
        return scriptedResults.isEmpty ? true : scriptedResults.removeFirst()
    }
}

@MainActor
private final class CatalogQualificationScorer: Phase2LiveQualificationScoring {
    private let scenarios: [String: Phase2LiveQualificationScenario]
    private let failedSelectionKey: Phase2LiveQualificationTrialKey?
    private let onSelection: @MainActor (Phase2LiveQualificationTrialKey) -> Void
    private(set) var selectionProbeIDs: [String] = []
    private(set) var finalizationProbeIDs: [String] = []

    init(
        catalog: Phase2LiveQualificationScenarioCatalog,
        failedSelectionKey: Phase2LiveQualificationTrialKey? = nil,
        onSelection: @escaping @MainActor (Phase2LiveQualificationTrialKey) -> Void = { _ in }
    ) {
        scenarios = Dictionary(uniqueKeysWithValues: catalog.scenarios.map { ($0.id, $0) })
        self.failedSelectionKey = failedSelectionKey
        self.onSelection = onSelection
    }

    func classifySelection(
        _ outcome: Phase2InferenceOutcome,
        fixture: Phase2LiveQualificationTrialFixture
    ) -> Phase2LiveQualificationSelectionClassification {
        selectionProbeIDs.append(fixture.key.probeID)
        onSelection(fixture.key)
        if fixture.key == failedSelectionKey {
            return .failed(try! .failed(
                reason: .selectionMismatch,
                evidenceDigest: digest("0")
            ))
        }
        guard outcome.disposition == .awaitingTools else {
            return .failed(try! .failed(
                reason: .selectionMismatch,
                evidenceDigest: digest("e")
            ))
        }
        return .accepted(evidenceDigest: digest("f"))
    }

    func classifyFinalization(
        _ outcome: Phase2InferenceOutcome,
        fixture: Phase2LiveQualificationTrialFixture,
        selectionEvidenceDigest: String?
    ) -> Phase2LiveQualificationClassification {
        finalizationProbeIDs.append(fixture.key.probeID)
        let scenario = scenarios[fixture.key.probeID]!
        let expectedDisposition: Phase2InferenceDisposition = scenario.phaseFlow == .cancellation
            ? .cancelled : .completed
        guard outcome.disposition == expectedDisposition else {
            return try! .failed(reason: .finalizationMismatch, evidenceDigest: digest("1"))
        }
        if scenario.phaseFlow == .toolSelectionAndFinalization,
           !phase2IsSHA256Hex(selectionEvidenceDigest ?? "")
        {
            return try! .failed(reason: .invalidFixture, evidenceDigest: digest("2"))
        }
        return try! .passed(evidenceDigest: digest("3"))
    }
}

@MainActor
private final class QualificationTaskCancellationBox {
    var task: Task<Phase2LiveQualificationExecution, Never>?

    func cancel() {
        task?.cancel()
    }
}

private func makePlan(
    catalog: Phase2LiveQualificationScenarioCatalog
) throws -> Phase2LiveQualificationPlan {
    try .init(
        policy: Phase2ProductionQualificationPolicy.standard.policy,
        catalog: catalog,
        fixtures: makeFixtures(catalog: catalog)
    )
}

private func makeFixtures(
    catalog: Phase2LiveQualificationScenarioCatalog
) throws -> [Phase2LiveQualificationTrialFixture] {
    var offset = 10
    return try catalog.scenarios.flatMap { scenario in
        try (1...scenario.trialCount).map { trial in
            defer { offset += 10 }
            return try makeTrial(probeID: scenario.id, trial: trial, offset: offset)
        }
    }
}

private func makeTrial(
    probeID: String,
    trial: Int,
    offset: Int
) throws -> Phase2LiveQualificationTrialFixture {
    let document = Phase2ReadDocumentIdentity(instanceID: qualificationID(offset + 1))
    let workspace = Phase2ReadWorkspaceIdentity(
        document: document,
        instanceID: qualificationID(offset + 2)
    )
    let context = try Phase2GroundedContextCompiler().compile(
        records: [],
        currentStateByEvidenceID: [:]
    )
    return try .init(
        key: .init(probeID: probeID, trial: trial),
        sessionID: qualificationID(offset + 3),
        turnID: qualificationID(offset + 4),
        selectionRequestID: qualificationID(offset + 5),
        finalizationRequestID: qualificationID(offset + 6),
        document: document,
        workspace: workspace,
        lifecycleRevision: 7,
        userGoal: "Use only the inert qualification fixture.",
        selectionContext: context,
        finalizationContext: context,
        toolHandles: [
            .init(
                handleID: qualificationID(offset + 7),
                operationID: .workspaceSummary
            ),
        ],
        limits: .maximum
    )
}

private func makePreparedQualification() throws -> Phase2PreparedLiveQualification {
    let standard = Phase2ProductionQualificationPolicy.standard
    let runtime = try makeRuntimeBinding()
    let environment = try makeEnvironment()
    let manifest = Phase2ModelProtocolManifest.productionGroundedReadOnly
    let context = try Phase2ContextProfile(
        id: "phase2-standard-32k",
        version: 1,
        maximumInputTokens: 32_768,
        reservedOutputTokens: 4_096,
        maximumEvidenceBytes: 2_000_000,
        compactionThresholdTokens: 24_000
    )
    let generation = try Phase2GenerationProfile(
        id: "phase2-grounded-generation",
        version: 2,
        temperature: 0,
        topP: 1,
        seed: nil,
        stopSequences: [],
        reasoningOutputPolicy: .discard
    )
    let hardware = try Phase2HardwareTier(id: "apple-m1-max-64gb", version: 1)
    let profile = try Phase2ModelProfile(
        version: 2,
        provider: runtime.provider,
        artifact: try .init(
            modelKey: runtime.modelKey,
            source: runtime.artifactObservation.source,
            type: .language,
            format: .mlx,
            quantizationName: "8bit",
            bitsPerWeight: 8,
            backingDigest: runtime.artifactObservation.backingDigest
        ),
        loadedConfiguration: runtime.loadedConfiguration,
        context: context,
        generation: generation,
        hardwareTier: hardware,
        workflow: .groundedReadOnly,
        authorityCeiling: .groundedReadOnly,
        toolCallMode: .requiredReadOnly,
        structuredOutputMode: .jsonSchema,
        protocolManifest: manifest
    )
    return .init(
        profile: profile,
        runtimeBinding: runtime,
        evidenceBinding: .init(
            productionDefinition: standard.definitionIdentity,
            readToolRegistry: manifest.readToolRegistry,
            qualificationPolicy: standard.policyIdentity,
            protocolProbeCatalog: standard.protocolProbeCatalogIdentity,
            liveCorpus: standard.liveScenarioCatalog.identity,
            environment: try environment.contentIdentity(),
            qualificationEnvironment: environment
        )
    )
}

private func makeRuntimeBinding(
    loadedInstanceID: String = "instance-exact-1"
) throws -> Phase2LiveQualificationRuntimeBinding {
    let lease = try makeLease()
    return .init(
        endpointProfileID: lease.configuration.profileID,
        endpointGeneration: lease.configuration.generation,
        providerRevision: lease.providerRevision,
        readyLease: lease,
        modelKey: lease.configuration.model,
        loadedInstanceID: loadedInstanceID,
        loadedConfiguration: .init(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 512,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        ),
        provider: try .init(
            family: "local-provider",
            build: "0.4.19+2",
            apiCompatibility: "openai-v1",
            endpointTransport: .loopbackHTTP
        ),
        providerRuntimeIdentity: try makeProviderRuntimeIdentity(),
        advertisedMaximumContextLength: 32_768,
        artifactObservation: try makeArtifactObservation()
    )
}

private func makeLease() throws -> Phase2ReadyInferenceLease {
    .init(
        providerRevision: 11,
        configuration: try .init(
            profileID: qualificationID(9_000),
            generation: 3,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "publisher/exact-model@q4",
            maximumTokens: 2_048,
            requestTimeoutMilliseconds: 4_000,
            resourceTimeoutMilliseconds: 60_000
        ),
        observedModelInventorySHA256: String(repeating: "a", count: 64)
    )
}

private func makeEnvironment() throws -> Phase2QualificationEnvironmentV2 {
    try .init(
        bundleShortVersion: "2.0",
        bundleVersion: "100",
        macScopeCommit: String(repeating: "1", count: 40),
        appExecutableDigest: digest("6"),
        workerExecutableDigest: digest("7"),
        signingRequirementDigest: digest("8"),
        xcodeVersion: "27.0",
        xcodeBuild: "27A1",
        swiftCompilerVersion: "6.3",
        sdkVersion: "27.0",
        sdkBuild: "27A1",
        operatingSystemVersion: "27.0",
        operatingSystemBuild: "27A1",
        architecture: "arm64",
        hardwareModel: "MacBookPro18,2",
        processorFamily: "Apple M1 Max",
        physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
        physicalCoreCount: 10,
        logicalCoreCount: 10,
        performanceCoreCount: 8,
        efficiencyCoreCount: 2
    )
}

private func makeRuntimeProvenance(
    binding: Phase2LiveQualificationRuntimeBinding,
    scope: Phase2ProtocolComponentIdentity,
    workerManifestDigest: String
) throws -> Phase2QualificationRuntimeProvenance {
    try .init(
        endpointProfileID: binding.endpointProfileID,
        endpointGeneration: binding.endpointGeneration,
        providerRevision: binding.providerRevision,
        modelSource: Phase2ProductionQualificationPolicy.standard.modelRevision.modelSource,
        modelRevisionIdentity: Phase2ProductionQualificationPolicy.standard
            .modelRevision.identity,
        productionDefinitionIdentity: Phase2ProductionQualificationPolicy.standard
            .definitionIdentity,
        modelKeyIdentityDigest: digest("9"),
        loadedInstanceIdentityDigest: digest("a"),
        loadedConfigurationIdentityDigest: digest("b"),
        providerBuildObservationDigest: digest("c"),
        providerRuntimeIdentity: binding.providerRuntimeIdentity,
        workerManifestDigest: workerManifestDigest,
        measurementScopeIdentity: scope,
        startedAtEpochMilliseconds: 1_000,
        endedAtEpochMilliseconds: 2_000
    )
}

private func makeArtifactObservation() throws -> Phase2LiveQualificationArtifactObservation {
    .init(
        source: Phase2ProductionQualificationPolicy.standard.modelRevision.modelSource,
        backingDigest: try .sha256(digest("5")),
        modelRevision: Phase2ProductionQualificationPolicy.standard.modelRevision.identity
    )
}

private func makeProviderRuntimeIdentity() throws -> Phase2EndpointBoundProviderRuntimeIdentity {
    try .init(
        endpoint: component("phase2.r1.provider-endpoint.v1", "1"),
        processStart: component("phase2.r1.provider-process-start.v1", "2"),
        executableBuild: component("phase2.r1.provider-executable-build.v1", "3"),
        apiProbe: component("phase2.r1.provider-api-probe.v1", "4")
    )
}

private func selectionOutcome() -> Phase2InferenceOutcome {
    .init(
        disposition: .awaitingTools,
        previewDeltas: [],
        toolProposals: [],
        finalCandidate: nil,
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: 1,
        cumulativeEventBytes: 176
    )
}

private func finalizationOutcome() -> Phase2InferenceOutcome {
    .init(
        disposition: .completed,
        previewDeltas: [],
        toolProposals: [],
        finalCandidate: .init(kind: .answer, text: "transient", evidenceIDs: []),
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: 2,
        cumulativeEventBytes: 352
    )
}

private func cancelledOutcome() -> Phase2InferenceOutcome {
    .init(
        disposition: .cancelled,
        previewDeltas: [],
        toolProposals: [],
        finalCandidate: nil,
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: 0,
        cumulativeEventBytes: 0
    )
}

private func makeRunnerMeasurementConfiguration(
    metricPlan: Phase2QualificationMetricPlan = Phase2ProductionQualificationPolicy
        .standard.metricPlan
) throws
    -> Phase2LiveQualificationMeasurementConfiguration
{
    .init(
        metricPlan: metricPlan,
        clock: RunnerAdvancingClock(),
        residentSetSampler: RunnerConstantResidentSetSampler(),
        maximumCancellationDrainMilliseconds: 2_000
    )
}

private final class RunnerAdvancingClock:
    Phase2QualificationMonotonicClock, @unchecked Sendable
{
    private let lock = NSLock()
    private let stepNanoseconds: UInt64
    private var value: UInt64 = 0

    init(stepNanoseconds: UInt64 = 1_000_000) {
        self.stepNanoseconds = stepNanoseconds
    }

    func nowNanoseconds() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value += stepNanoseconds
        return value
    }
}

private struct RunnerConstantResidentSetSampler:
    Phase2QualificationBoundResidentSetSampling
{
    let scopeIdentity = component("phase2.r1.test-measurement-scope", "a")
    let measurementSemantics = Phase2QualificationResidentSetMeasurementSemantics
        .contemporaneousSnapshot

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        try .init(appBytes: 100, aiWorkerBytes: 200, providerBytes: 300)
    }
}

private func component(_ id: String, _ character: Character) -> Phase2ProtocolComponentIdentity {
    try! .init(id: id, version: 1, sha256: digest(character))
}

private func qualificationID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

import XCTest
@testable import MacScope

@MainActor
final class Phase2QualificationInferenceMeasurementObserverTests: XCTestCase {
    func testCoordinatorAdmitsBeforeGenerationAndActiveProtocolCompletesWithUsage() async throws {
        let fixture = try ObserverReadyFixture()
        XCTAssertEqual(fixture.endpoint.inferencePolicy, Phase2LocalInferencePolicy())
        XCTAssertEqual(fixture.configuration.inferencePolicy,
                       Phase2LocalInferencePolicy(effectiveContextTokens: 32_768))
        let controller = try await fixture.makeReadyController()
        let observer = RecordingInferenceMeasurementObserver()
        let usage = makeObserverUsage(prompt: 11, completion: 4)
        let provider = ObserverScriptedProvider(bodies: [
            .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "bounded v3 answer",
                evidenceIDs: []
            )),
            .usage(usage),
            .completed,
        ])
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            providerFactory: { _ in provider }
        )
        // The coordinator admits only the live production protocol; the
        // runner-paired v3 tests below pin their own accepted version and
        // stay on .v3 deliberately.
        let request = makeObserverInferenceRequest(
            protocolVersion: .init(
                rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
            )
        )

        let result = await coordinator.run(
            request: request,
            measurementObserver: observer
        )

        guard case .finished(_, let outcome) = result else {
            return XCTFail("Expected one finished active-protocol turn, got \(result)")
        }
        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.providerUsage, usage)
        XCTAssertEqual(
            observer.events,
            [
                .admitted(.finalization),
                .generationBegan(.finalization),
                .acceptedSemantic(.finalization),
                .acceptedEvent(.finalization),
                .usageAccepted(.finalization, usage),
                .acceptedEvent(.finalization),
                .acceptedEvent(.finalization),
                .providerDrained(.finalization),
            ]
        )
    }

    func testV3AcceptedUsageEndsMatchingGenerationWithExactAccounting() async {
        let observer = RecordingInferenceMeasurementObserver()
        let request = makeObserverInferenceRequest(protocolVersion: .v3)
        let usage = makeObserverUsage(prompt: 13, completion: 5)
        let provider = ObserverScriptedProvider(bodies: [
            .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "bounded v3 answer",
                evidenceIDs: []
            )),
            .usage(usage),
            .completed,
        ])

        let outcome = await Phase2InferenceRunner(acceptedProtocolVersion: .v3).run(
            request: request,
            provider: provider,
            measurementObserver: observer
        )

        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.providerUsage, usage)
        XCTAssertEqual(
            observer.events,
            [
                .generationBegan(.finalization),
                .acceptedSemantic(.finalization),
                .acceptedEvent(.finalization),
                .usageAccepted(.finalization, usage),
                .acceptedEvent(.finalization),
                .acceptedEvent(.finalization),
                .providerDrained(.finalization),
            ]
        )
    }

    func testEveryAcceptedSemanticAndEventIsReportedButRejectedEventIsNot() async {
        let acceptedObserver = RecordingInferenceMeasurementObserver()
        let acceptedRequest = makeObserverInferenceRequest(protocolVersion: .v3)
        let usage = makeObserverUsage(prompt: 8, completion: 3)
        let acceptedOutcome = await Phase2InferenceRunner(acceptedProtocolVersion: .v3).run(
            request: acceptedRequest,
            provider: ObserverScriptedProvider(bodies: [
                .contentDelta("first semantic"),
                .contentDelta("second semantic"),
                .finalCandidate(.init(
                    kind: .insufficientEvidence,
                    text: "third semantic",
                    evidenceIDs: []
                )),
                .usage(usage),
                .completed,
            ]),
            measurementObserver: acceptedObserver
        )

        XCTAssertEqual(acceptedOutcome.disposition, .completed)
        XCTAssertEqual(
            acceptedObserver.events.filter(\.isAcceptedSemantic).count,
            3,
            "The raw seam reports every accepted semantic; attempt measurement owns TTFS de-duplication"
        )
        XCTAssertEqual(acceptedObserver.events.filter(\.isAcceptedEvent).count, 5)

        let rejectedObserver = RecordingInferenceMeasurementObserver()
        let rejectedRequest = makeObserverInferenceRequest(protocolVersion: .v3)
        let rejectedOutcome = await Phase2InferenceRunner(acceptedProtocolVersion: .v3).run(
            request: rejectedRequest,
            provider: ObserverScriptedProvider(bodies: [
                .finalCandidate(.init(kind: .answer, text: "unsupported", evidenceIDs: [])),
            ]),
            measurementObserver: rejectedObserver
        )

        XCTAssertEqual(rejectedOutcome.disposition, .protocolViolation)
        XCTAssertEqual(rejectedOutcome.violation, .invalidFinalCandidate)
        XCTAssertEqual(
            rejectedObserver.events,
            [
                .generationBegan(.finalization),
                .providerDrained(.finalization),
            ],
            "Rejected provider events must not be counted as semantic or accepted-event milestones"
        )
    }

    func testCancellationBeginsBeforeProviderDrain() async {
        let observer = RecordingInferenceMeasurementObserver()
        let provider = ObserverBlockingProvider()
        let request = makeObserverInferenceRequest(protocolVersion: .v3)
        let task = Task {
            await Phase2InferenceRunner(acceptedProtocolVersion: .v3).run(
                request: request,
                provider: provider,
                measurementObserver: observer
            )
        }
        await provider.waitUntilStarted()

        task.cancel()
        let outcome = await task.value
        let cancelledRequestIDs = await provider.cancelledRequestIDs

        XCTAssertEqual(outcome.disposition, .cancelled)
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])
        XCTAssertEqual(
            observer.events,
            [
                .generationBegan(.finalization),
                .cancellationBegan(.finalization),
                .providerDrained(.finalization),
            ]
        )
    }

    func testNilObserverPreservesV2OutcomeAndNeedsNoUsageEvent() async {
        let request = makeObserverInferenceRequest(protocolVersion: .v2)
        let provider = ObserverScriptedProvider(bodies: [
            .finalCandidate(.init(
                kind: .insufficientEvidence,
                text: "legacy production answer",
                evidenceIDs: []
            )),
            .completed,
        ])

        let outcome = await Phase2InferenceRunner(acceptedProtocolVersion: .v2).run(
            request: request,
            provider: provider
        )

        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.finalCandidate?.text, "legacy production answer")
        XCTAssertNil(outcome.providerUsage)
        XCTAssertEqual(outcome.acceptedEventCount, 2)
    }

    func testObserverInternalFailureCannotChangeSemanticInferenceOutcome() async {
        let observer = InternallyFailingInferenceMeasurementObserver()
        let request = makeObserverInferenceRequest(protocolVersion: .v3)
        let usage = makeObserverUsage(prompt: 21, completion: 7)

        let outcome = await Phase2InferenceRunner(acceptedProtocolVersion: .v3).run(
            request: request,
            provider: ObserverScriptedProvider(bodies: [
                .finalCandidate(.init(
                    kind: .insufficientEvidence,
                    text: "semantic result survives measurement failure",
                    evidenceIDs: []
                )),
                .usage(usage),
                .completed,
            ]),
            measurementObserver: observer
        )

        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(
            outcome.finalCandidate?.text,
            "semantic result survives measurement failure"
        )
        XCTAssertEqual(outcome.providerUsage, usage)
        XCTAssertGreaterThan(observer.caughtFailureCount, 0)
    }

    func testAttemptObserverRecordsFirstSemanticOnlyOnceAcrossProviderPhases() throws {
        let key = try Phase2QualificationTrialKey(
            requirementID: "live.performance.standard-turn",
            trialIndex: 1,
            attempt: 1
        )
        let observer = Phase2LiveQualificationAttemptMeasurementObserver(
            trialKey: key,
            configuration: try observerMeasurementConfiguration(
                key: key,
                kinds: [.timeToFirstSemanticEventMilliseconds],
                clock: ObserverTestClock([0, 10_000_000, 20_000_000, 40_000_000]),
                sampler: ObserverTestRSSSampler([.some(try observerRSS(1, 2, 3))])
            )
        )

        observer.admitted(phase: .toolSelection)
        observer.acceptedSemantic(phase: .toolSelection)
        observer.acceptedSemantic(phase: .toolSelection)
        observer.providerDrained(phase: .toolSelection)
        observer.recordValidatedTerminalBoundary()
        observer.admitted(phase: .finalization)
        observer.acceptedSemantic(phase: .finalization)
        observer.providerDrained(phase: .finalization)
        observer.recordValidatedTerminalBoundary()
        let sample = try XCTUnwrap(observer.finish())

        XCTAssertFalse(observer.hasFailed)
        XCTAssertEqual(sample.timeToFirstSemanticEventMilliseconds, 10)
        XCTAssertEqual(sample.totalLatencyMilliseconds, 40)
    }

    func testAcceptedEventTriggersExactScopeResidentSetSample() throws {
        let key = try Phase2QualificationTrialKey(
            requirementID: "live.performance.standard-turn",
            trialIndex: 1,
            attempt: 1
        )
        let sampler = ObserverTestRSSSampler([
            .some(try observerRSS(1, 2, 3)),
            .some(try observerRSS(1_000, 2_000, 3_000)),
            .some(try observerRSS(10, 20, 30)),
            .some(try observerRSS(100, 200, 300)),
        ])
        let observer = Phase2LiveQualificationAttemptMeasurementObserver(
            trialKey: key,
            configuration: try observerMeasurementConfiguration(
                key: key,
                kinds: [.peakResidentBytes],
                clock: ObserverTestClock([0, 10_000_000]),
                sampler: sampler
            )
        )

        observer.admitted(phase: .finalization)
        observer.acceptedEvent(phase: .finalization)
        observer.providerDrained(phase: .finalization)
        observer.recordValidatedTerminalBoundary()
        let sample = try XCTUnwrap(observer.finish())

        XCTAssertEqual(sampler.sampleCount, 4)
        XCTAssertEqual(
            sample.peakResidentBytes,
            6_000,
            "The peak was visible only at the accepted-event boundary"
        )
    }
}

private enum RecordedInferenceMeasurementEvent: Equatable, Sendable {
    case admitted(Phase2InferencePhase)
    case generationBegan(Phase2InferencePhase)
    case acceptedSemantic(Phase2InferencePhase)
    case acceptedEvent(Phase2InferencePhase)
    case usageAccepted(Phase2InferencePhase, Phase2ProviderUsage)
    case cancellationBegan(Phase2InferencePhase)
    case providerDrained(Phase2InferencePhase)

    var isAcceptedSemantic: Bool {
        if case .acceptedSemantic = self { return true }
        return false
    }

    var isAcceptedEvent: Bool {
        if case .acceptedEvent = self { return true }
        return false
    }
}

private final class RecordingInferenceMeasurementObserver:
    Phase2InferenceMeasurementObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [RecordedInferenceMeasurementEvent] = []

    var events: [RecordedInferenceMeasurementEvent] {
        lock.withLock { storage }
    }

    func admitted(phase: Phase2InferencePhase) {
        append(.admitted(phase))
    }

    func generationBegan(phase: Phase2InferencePhase) {
        append(.generationBegan(phase))
    }

    func acceptedSemantic(phase: Phase2InferencePhase) {
        append(.acceptedSemantic(phase))
    }

    func acceptedEvent(phase: Phase2InferencePhase) {
        append(.acceptedEvent(phase))
    }

    func usageAccepted(phase: Phase2InferencePhase, usage: Phase2ProviderUsage) {
        append(.usageAccepted(phase, usage))
    }

    func cancellationBegan(phase: Phase2InferencePhase) {
        append(.cancellationBegan(phase))
    }

    func providerDrained(phase: Phase2InferencePhase) {
        append(.providerDrained(phase))
    }

    private func append(_ event: RecordedInferenceMeasurementEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class InternallyFailingInferenceMeasurementObserver:
    Phase2InferenceMeasurementObserving,
    @unchecked Sendable
{
    private enum Failure: Error { case measurementUnavailable }

    private let lock = NSLock()
    private var failures = 0

    var caughtFailureCount: Int {
        lock.withLock { failures }
    }

    func admitted(phase: Phase2InferencePhase) { catchFailure() }
    func generationBegan(phase: Phase2InferencePhase) { catchFailure() }
    func acceptedSemantic(phase: Phase2InferencePhase) { catchFailure() }
    func acceptedEvent(phase: Phase2InferencePhase) { catchFailure() }
    func usageAccepted(phase: Phase2InferencePhase, usage: Phase2ProviderUsage) { catchFailure() }
    func cancellationBegan(phase: Phase2InferencePhase) { catchFailure() }
    func providerDrained(phase: Phase2InferencePhase) { catchFailure() }

    private func catchFailure() {
        do {
            throw Failure.measurementUnavailable
        } catch {
            lock.withLock { failures += 1 }
        }
    }
}

private struct ObserverScriptedProvider: Phase2InferenceProviding {
    let bodies: [Phase2InferenceEventBody]

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        for (offset, body) in bodies.enumerated() {
            try await emit(observerInferenceEvent(
                request,
                sequence: UInt64(offset + 1),
                body: body
            ))
        }
    }

    func cancel(requestID: UUID) async {}
}

private actor ObserverBlockingProvider: Phase2InferenceProviding {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelledRequestIDs: [UUID] = []

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
    }

    func cancel(requestID: UUID) async {
        cancelledRequestIDs.append(requestID)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private struct ObserverReadyFixture {
    let endpoint: Phase2LocalProviderEndpoint
    let inventory: Phase2LocalModelInventory
    let configuration: Phase2AIProviderConfiguration

    init() throws {
        endpoint = try .init(
            profileID: observerID(1),
            generation: 7,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 4_000,
            resourceTimeoutMilliseconds: 60_000,
            inferencePolicy: .init()
        )
        let model = Phase2LocalModelDescriptor(
            type: .language,
            publisher: "Observer Test Publisher",
            key: "publisher/observer-model@q4",
            displayName: "Observer Model",
            architecture: "transformer",
            quantization: .init(name: "Q4", bitsPerWeight: 4),
            sizeBytesOnDisk: 4_294_967_296,
            parameterCountDescription: "7B",
            maximumContextLength: 32_768,
            format: .gguf,
            capabilities: .init(
                supportsVision: false,
                trainedForToolUse: false,
                reasoning: .init(allowedOptions: [.off], defaultOption: .off)
            ),
            summary: "A complete observer-seam test fixture.",
            variants: ["q4"],
            providerSelectedVariant: "q4",
            loadedInstances: [
                .init(
                    id: "observer-loaded-instance",
                    configuration: .init(effectiveContextLength: 32_768)
                ),
            ]
        )
        inventory = try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [model]
        )
        configuration = try Phase2LocalAISelection.authorize(
            endpoint: endpoint,
            inventory: inventory,
            modelKey: model.key,
            maximumTokens: 2_048
        ).configuration
    }

    @MainActor
    func makeReadyController() async throws -> Phase2LocalAIProviderController {
        let controller = Phase2LocalAIProviderController(
            endpoint: endpoint,
            discovery: ObserverReadyDiscovery(inventory: inventory),
            lifecycle: ObserverUnusedLifecycle()
        )
        _ = try await controller.refresh()
        try controller.select(
            modelKey: configuration.model,
            maximumTokens: configuration.maximumTokens
        )
        return controller
    }
}

private struct ObserverReadyDiscovery: Phase2LocalModelDiscovering {
    let inventory: Phase2LocalModelInventory

    func discoverModels(
        endpoint: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) async throws -> Phase2LocalModelDiscoveryOutcome {
        .success(inventory)
    }

    func cancel(requestID: UUID) async {}
}

private struct ObserverUnusedLifecycle: Phase2LocalModelLifecycleControlling {
    func perform(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint,
        acceptedInventory: Phase2LocalModelInventory
    ) async throws -> Phase2LocalModelLifecycleOutcome {
        XCTFail("Inference measurement tests must not perform lifecycle work")
        return .cancelledBeforeDispatch
    }

    func cancel(effectID: UUID) async {}
}

private func makeObserverInferenceRequest(
    protocolVersion: Phase2InferenceProtocolVersion
) -> Phase2InferenceRequest {
    let document = Phase2ReadDocumentIdentity(instanceID: observerID(11))
    let workspace = Phase2ReadWorkspaceIdentity(
        document: document,
        instanceID: observerID(12)
    )
    return .init(
        protocolVersion: protocolVersion,
        phase: .finalization,
        sessionID: observerID(13),
        turnID: observerID(14),
        requestID: observerID(15),
        document: document,
        workspace: workspace,
        lifecycleRevision: 19,
        userGoal: "Exercise the exact inference measurement seam.",
        groundedContext: try! Phase2GroundedContextCompiler().compile(
            records: [],
            currentStateByEvidenceID: [:]
        ),
        toolHandles: [],
        limits: .maximum
    )
}

private func observerInferenceEvent(
    _ request: Phase2InferenceRequest,
    sequence: UInt64,
    body: Phase2InferenceEventBody
) -> Phase2InferenceEvent {
    .init(
        protocolVersion: request.protocolVersion,
        phase: request.phase,
        sessionID: request.sessionID,
        turnID: request.turnID,
        requestID: request.requestID,
        document: request.document,
        workspace: request.workspace,
        lifecycleRevision: request.lifecycleRevision,
        sequence: sequence,
        body: body
    )
}

private func makeObserverUsage(prompt: Int, completion: Int) -> Phase2ProviderUsage {
    Phase2ProviderUsage(
        promptTokens: prompt,
        completionTokens: completion,
        totalTokens: prompt + completion
    )!
}

private func observerMeasurementConfiguration(
    key: Phase2QualificationTrialKey,
    kinds: [Phase2QualificationMeasurementV2Kind],
    clock: any Phase2QualificationMonotonicClock,
    sampler: any Phase2QualificationBoundResidentSetSampling
) throws -> Phase2LiveQualificationMeasurementConfiguration {
    .init(
        metricPlan: try .init(
            applicableTrialKeys: Dictionary(
                uniqueKeysWithValues: kinds.map { ($0, Set([key])) }
            )
        ),
        clock: clock,
        residentSetSampler: sampler
    )
}

private func observerRSS(
    _ appBytes: Int64,
    _ aiWorkerBytes: Int64,
    _ providerBytes: Int64
) throws -> Phase2QualificationResidentSetSnapshot {
    try .init(
        appBytes: appBytes,
        aiWorkerBytes: aiWorkerBytes,
        providerBytes: providerBytes
    )
}

private final class ObserverTestClock:
    Phase2QualificationMonotonicClock,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func nowNanoseconds() throws -> UInt64 {
        lock.withLock { values.removeFirst() }
    }
}

private final class ObserverTestRSSSampler:
    Phase2QualificationBoundResidentSetSampling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [Phase2QualificationResidentSetSnapshot?]
    private var count = 0

    let scopeIdentity = try! Phase2ProtocolComponentIdentity(
        id: "phase2.r1.measurement-scope.app-worker-provider",
        version: 1,
        sha256: String(repeating: "d", count: 64)
    )
    let measurementSemantics = Phase2QualificationResidentSetMeasurementSemantics
        .contemporaneousSnapshot

    init(_ values: [Phase2QualificationResidentSetSnapshot?]) {
        self.values = values
    }

    var sampleCount: Int {
        lock.withLock { count }
    }

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        lock.withLock {
            count += 1
            return values.isEmpty ? nil : values.removeFirst()
        }
    }
}

private func observerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

import XCTest

@testable import MacScope

final class AIAgentXPCModelLifecycleServiceTests: XCTestCase {
    func testTaskCancellationWhilePreTransportWorkIsSuspendedNeverCallsTransport()
        async throws
    {
        let fixture = try LifecycleServiceFixture()
        let gate = LifecyclePreTransportGate()
        await fixture.transport.enqueue(.succeeded(fixture.loadReceipt))
        await fixture.discovery.enqueue(.success(fixture.inventoryAfterLoad))
        let service = AIAgentXPCModelLifecycleService(
            transport: fixture.transport,
            discovery: fixture.discovery,
            ownership: fixture.ownership,
            codec: Phase2AIWorkerModelLifecycleAppCodec(),
            pauseBeforeTransport: { await gate.pause() }
        )
        let operation = Task {
            try await service.perform(
                command: fixture.loadCommand,
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )
        }
        try await gate.waitUntilPaused()

        operation.cancel()
        await gate.release()

        let outcome = try await operation.value
        XCTAssertEqual(outcome, .cancelledBeforeDispatch)
        let transportCallCount = await fixture.transport.callCount
        XCTAssertEqual(transportCallCount, 0)
    }

    func testExplicitCancellationWhilePreTransportWorkIsSuspendedNeverCallsTransport()
        async throws
    {
        let fixture = try LifecycleServiceFixture()
        let gate = LifecyclePreTransportGate()
        let service = AIAgentXPCModelLifecycleService(
            transport: fixture.transport,
            discovery: fixture.discovery,
            ownership: fixture.ownership,
            codec: Phase2AIWorkerModelLifecycleAppCodec(),
            pauseBeforeTransport: { await gate.pause() }
        )
        let operation = Task {
            try await service.perform(
                command: fixture.loadCommand,
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )
        }
        try await gate.waitUntilPaused()

        await service.cancel(effectID: fixture.loadCommand.effectID)
        await gate.release()

        let outcome = try await operation.value
        XCTAssertEqual(outcome, .cancelledBeforeDispatch)
        let transportCallCount = await fixture.transport.callCount
        XCTAssertEqual(transportCallCount, 0)
    }

    func testSerializesLifecycleTransactionsBeforeCallingTransport() async throws {
        let fixture = try LifecycleServiceFixture()
        await fixture.transport.setMode(.suspendFirst)

        let first = Task {
            try await fixture.service.perform(
                command: fixture.loadCommand,
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )
        }
        try await fixture.transport.waitForCallCount(1)

        do {
            _ = try await fixture.service.perform(
                command: fixture.loadCommand(effectID: UUID()),
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )
            XCTFail("a concurrent lifecycle transaction must fail closed")
        } catch {
            XCTAssertEqual(error as? AIAgentXPCModelLifecycleServiceError, .busy)
        }

        let serializedCallCount = await fixture.transport.callCount
        XCTAssertEqual(serializedCallCount, 1)
        await fixture.discovery.enqueue(.success(fixture.inventoryAfterLoad))
        await fixture.transport.completeFirst(with: .succeeded(fixture.loadReceipt))
        _ = try await first.value
    }

    func testSendsExactCommandAndEndpointAuthorityWithoutConfiguringInference() async throws {
        let fixture = try LifecycleServiceFixture()
        await fixture.transport.enqueue(.succeeded(fixture.loadReceipt))
        await fixture.discovery.enqueue(.success(fixture.inventoryAfterLoad))

        let inference = try Phase2AIProviderConfiguration(
            profileID: UUID(),
            generation: 4,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "publisher/already-selected",
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 15_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let unchangedInference = inference

        _ = try await fixture.service.perform(
            command: fixture.loadCommand,
            endpoint: fixture.endpoint,
            acceptedInventory: fixture.inventoryBeforeLoad
        )

        let observations = await fixture.transport.observations
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.effectID, fixture.loadCommand.effectID)
        XCTAssertEqual(observation.profileID, fixture.endpoint.profileID)
        XCTAssertEqual(observation.generation, fixture.endpoint.generation)
        XCTAssertEqual(observation.endpointOrigin, fixture.endpoint.endpointOrigin)
        XCTAssertEqual(
            observation.requestTimeoutMilliseconds,
            fixture.endpoint.requestTimeoutMilliseconds
        )
        XCTAssertEqual(
            observation.resourceTimeoutMilliseconds,
            fixture.endpoint.resourceTimeoutMilliseconds
        )
        XCTAssertEqual(
            observation.operation,
            .load(modelKey: LifecycleServiceFixture.modelKey, contextLength: 2_048)
        )
        XCTAssertEqual(inference, unchangedInference)
        let inferenceConfigurationCallCount = await fixture.transport.inferenceConfigurationCallCount
        XCTAssertEqual(inferenceConfigurationCallCount, 0)
    }

    func testEveryMayDispatchOutcomeUsesOneFreshSeparateDiscovery() async throws {
        let mayDispatch: [LifecycleTransportProbe.Result] = [
            .succeeded(LifecycleServiceFixture.loadReceiptValue),
            .rejected,
            .reconciliationRequired,
            .authenticationRequired,
        ]

        for result in mayDispatch {
            let fixture = try LifecycleServiceFixture()
            await fixture.transport.enqueue(result)
            await fixture.discovery.enqueue(.success(fixture.inventoryAfterLoad))

            _ = try await fixture.service.perform(
                command: fixture.loadCommand,
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )

            let transportCallCount = await fixture.transport.callCount
            let resetCount = await fixture.transport.resetCount
            let discoveryCallCount = await fixture.discovery.callCount
            let discoveryRequestIDs = await fixture.discovery.requestIDs
            XCTAssertEqual(transportCallCount, 1)
            XCTAssertEqual(resetCount, 1)
            XCTAssertEqual(discoveryCallCount, 1)
            XCTAssertEqual(discoveryRequestIDs.count, 1)
            XCTAssertNotEqual(
                discoveryRequestIDs.first,
                fixture.loadCommand.effectID,
                "reconciliation must use a fresh discovery request, not reuse the mutation ID"
            )
        }
    }

    func testReconcilesLoadOnlyWhenExactReturnedInstanceIsPresent() async throws {
        let fixture = try LifecycleServiceFixture()
        await fixture.transport.enqueue(.succeeded(fixture.loadReceipt))
        await fixture.discovery.enqueue(.success(fixture.inventoryAfterLoad))

        let outcome = try await fixture.service.perform(
            command: fixture.loadCommand,
            endpoint: fixture.endpoint,
            acceptedInventory: fixture.inventoryBeforeLoad
        )

        XCTAssertEqual(outcome, .loaded(fixture.loadReceipt))
        let ownsLoadedInstance = await fixture.ownership.contains(fixture.ownedIdentity)
        XCTAssertTrue(ownsLoadedInstance)
    }

    func testLoadReconciliationAcceptsDiscoveryParallelNotRepresentedByLoadReceipt() async throws {
        let fixture = try LifecycleServiceFixture()
        let discovered = try fixture.inventoryAfterLoad(parallelPredictions: 4)
        await fixture.transport.enqueue(.succeeded(fixture.loadReceipt))
        await fixture.discovery.enqueue(.success(discovered))

        let outcome = try await fixture.service.perform(
            command: fixture.loadCommand,
            endpoint: fixture.endpoint,
            acceptedInventory: fixture.inventoryBeforeLoad
        )

        XCTAssertEqual(outcome, .loaded(fixture.loadReceipt))
        let isOwned = await fixture.ownership.contains(fixture.ownedIdentity)
        XCTAssertTrue(isOwned)
    }

    func testMismatchedInventoryDoesNotEraseExistingEndpointOwnership() async throws {
        let fixture = try LifecycleServiceFixture()
        await fixture.ownership.recordReconciledLoad(fixture.ownedIdentity)
        let staleEndpoint = try Phase2LocalProviderEndpoint(
            profileID: fixture.endpoint.profileID,
            generation: fixture.endpoint.generation + 1,
            endpointOrigin: fixture.endpoint.endpointOrigin,
            requestTimeoutMilliseconds: fixture.endpoint.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: fixture.endpoint.resourceTimeoutMilliseconds
        )
        let staleCommand = try Phase2LocalModelLifecycleCommand.load(
            effectID: UUID(),
            profileID: staleEndpoint.profileID,
            generation: staleEndpoint.generation,
            modelKey: LifecycleServiceFixture.modelKey,
            requestedContextLength: 2_048
        )

        do {
            _ = try await fixture.service.perform(
                command: staleCommand,
                endpoint: staleEndpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )
            XCTFail("stale inventory must fail before changing ownership generation")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .inventoryIdentityMismatch
            )
        }

        let stillOwnsOriginal = await fixture.ownership.contains(fixture.ownedIdentity)
        XCTAssertTrue(stillOwnsOriginal)
        let transportCallCount = await fixture.transport.callCount
        XCTAssertEqual(transportCallCount, 0)
    }

    func testReconcilesUnloadOnlyWhenExactOwnedInstanceIsAbsent() async throws {
        let fixture = try LifecycleServiceFixture()
        await fixture.ownership.recordReconciledLoad(fixture.ownedIdentity)
        await fixture.transport.enqueue(.succeeded(fixture.unloadReceipt))
        await fixture.discovery.enqueue(.success(fixture.inventoryAfterUnload))

        let outcome = try await fixture.service.perform(
            command: fixture.unloadCommand,
            endpoint: fixture.endpoint,
            acceptedInventory: fixture.inventoryAfterLoad
        )

        XCTAssertEqual(outcome, .unloaded(fixture.unloadReceipt))
        let ownsUnloadedInstance = await fixture.ownership.contains(fixture.ownedIdentity)
        XCTAssertFalse(ownsUnloadedInstance)
    }

    func testContradictoryOrUnavailableReconciliationRequiresReconciliationAndPreservesOwnership()
        async throws
    {
        for discoveryResult in LifecycleServiceFixture.contradictoryLoadDiscoveries {
            let fixture = try LifecycleServiceFixture()
            await fixture.transport.enqueue(.succeeded(fixture.loadReceipt))
            await fixture.discovery.enqueue(discoveryResult)

            let outcome = try await fixture.service.perform(
                command: fixture.loadCommand,
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryBeforeLoad
            )

            XCTAssertEqual(outcome, .reconciliationRequired)
            let ownsContradictoryLoad = await fixture.ownership.contains(fixture.ownedIdentity)
            XCTAssertFalse(ownsContradictoryLoad)
        }

        for discoveryResult in LifecycleServiceFixture.contradictoryUnloadDiscoveries {
            let fixture = try LifecycleServiceFixture()
            await fixture.ownership.recordReconciledLoad(fixture.ownedIdentity)
            await fixture.transport.enqueue(.succeeded(fixture.unloadReceipt))
            await fixture.discovery.enqueue(discoveryResult)

            let outcome = try await fixture.service.perform(
                command: fixture.unloadCommand,
                endpoint: fixture.endpoint,
                acceptedInventory: fixture.inventoryAfterLoad
            )

            XCTAssertEqual(outcome, .reconciliationRequired)
            let ownsContradictoryUnload = await fixture.ownership.contains(fixture.ownedIdentity)
            XCTAssertTrue(ownsContradictoryUnload)
        }
    }
}

private struct LifecycleServiceFixture {
    static let profileID = UUID(uuidString: "A2BD98DE-456D-48ED-AE61-65CFBA5E022A")!
    static let modelKey = "publisher/exact-model"
    static let instanceID = "runtime-instance-7"
    static let instanceConfiguration = Phase2LocalModelInstanceConfiguration(
        effectiveContextLength: 2_048,
        evaluationBatchSize: 512,
        parallelPredictions: nil,
        flashAttention: true,
        expertCount: 8,
        offloadsKVCacheToGPU: true
    )
    static let loadReceiptValue = Phase2LocalModelLifecycleReceipt.load(
        modelKey: modelKey,
        instance: .init(id: instanceID, configuration: instanceConfiguration),
        loadTimeSeconds: 0.25
    )

    let endpoint: Phase2LocalProviderEndpoint
    let inventoryBeforeLoad: Phase2LocalModelInventory
    let inventoryAfterLoad: Phase2LocalModelInventory
    let inventoryAfterUnload: Phase2LocalModelInventory
    let loadCommand: Phase2LocalModelLifecycleCommand
    let unloadCommand: Phase2LocalModelLifecycleCommand
    let loadReceipt = Self.loadReceiptValue
    let unloadReceipt: Phase2LocalModelLifecycleReceipt
    let ownedIdentity: Phase2LocalModelOwnership
    let transport = LifecycleTransportProbe()
    let discovery = LifecycleDiscoveryProbe()
    let ownership = Phase2LocalModelOwnershipLedger()
    let service: AIAgentXPCModelLifecycleService

    init() throws {
        endpoint = try .init(
            profileID: Self.profileID,
            generation: 9,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let unloadedModel = Self.model(instances: [])
        let loadedInstance = Phase2LocalModelLoadedInstance(
            id: Self.instanceID,
            configuration: Self.instanceConfiguration
        )
        let loadedModel = Self.model(instances: [loadedInstance])
        inventoryBeforeLoad = try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [unloadedModel]
        )
        inventoryAfterLoad = try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [loadedModel]
        )
        inventoryAfterUnload = inventoryBeforeLoad
        loadCommand = try .load(
            effectID: UUID(uuidString: "401B58D2-9B39-4418-BAD5-0744C39898A3")!,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: Self.modelKey,
            requestedContextLength: 2_048
        )
        unloadCommand = try .unload(
            effectID: UUID(uuidString: "301438B2-4039-4483-B460-317519F4D9B3")!,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: Self.modelKey,
            instance: loadedInstance
        )
        unloadReceipt = .unload(modelKey: Self.modelKey, instanceID: Self.instanceID)
        ownedIdentity = .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: Self.modelKey,
            instanceID: Self.instanceID
        )
        service = AIAgentXPCModelLifecycleService(
            transport: transport,
            discovery: discovery,
            ownership: ownership,
            codec: Phase2AIWorkerModelLifecycleAppCodec()
        )
    }

    func loadCommand(effectID: UUID) throws -> Phase2LocalModelLifecycleCommand {
        try .load(
            effectID: effectID,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: Self.modelKey,
            requestedContextLength: 2_048
        )
    }

    func inventoryAfterLoad(parallelPredictions: Int?) throws -> Phase2LocalModelInventory {
        let configuration = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: Self.instanceConfiguration.effectiveContextLength,
            evaluationBatchSize: Self.instanceConfiguration.evaluationBatchSize,
            parallelPredictions: parallelPredictions,
            flashAttention: Self.instanceConfiguration.flashAttention,
            expertCount: Self.instanceConfiguration.expertCount,
            offloadsKVCacheToGPU: Self.instanceConfiguration.offloadsKVCacheToGPU
        )
        return try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [Self.model(instances: [.init(
                id: Self.instanceID,
                configuration: configuration
            )])]
        )
    }

    static var contradictoryLoadDiscoveries: [Phase2LocalModelDiscoveryOutcome] {
        [
            .success(try! .init(profileID: profileID, generation: 9, models: [model(instances: [])])),
            .unavailable,
        ]
    }

    static var contradictoryUnloadDiscoveries: [Phase2LocalModelDiscoveryOutcome] {
        let instance = Phase2LocalModelLoadedInstance(
            id: instanceID,
            configuration: instanceConfiguration
        )
        return [
            .success(try! .init(
                profileID: profileID,
                generation: 9,
                models: [model(instances: [instance])]
            )),
            .unavailable,
        ]
    }

    private static func model(
        instances: [Phase2LocalModelLoadedInstance]
    ) -> Phase2LocalModelDescriptor {
        .init(
            type: .language,
            publisher: "publisher",
            key: modelKey,
            displayName: "Exact Model",
            architecture: nil,
            quantization: nil,
            sizeBytesOnDisk: 1,
            parameterCountDescription: nil,
            maximumContextLength: 4_096,
            format: .gguf,
            capabilities: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: instances
        )
    }
}

private actor LifecyclePreTransportGate {
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            isPaused = true
            pauseContinuation = continuation
        }
    }

    func waitUntilPaused() async throws {
        for _ in 0..<2_000 {
            if isPaused { return }
            await Task.yield()
        }
        throw LifecycleTransportProbe.ProbeError.timeout
    }

    func release() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private actor LifecycleTransportProbe: Phase2AIWorkerModelLifecycleTransport {
    enum Mode {
        case immediate
        case suspendFirst
    }

    enum Result: Sendable {
        case succeeded(Phase2LocalModelLifecycleReceipt)
        case authenticationRequired
        case rejected
        case reconciliationRequired
    }

    struct Observation: Equatable, Sendable {
        let effectID: UUID
        let profileID: UUID
        let generation: UInt64
        let endpointOrigin: String
        let requestTimeoutMilliseconds: Int
        let resourceTimeoutMilliseconds: Int
        let operation: Phase2AIWorkerModelLifecycleOperationWire
    }

    private(set) var observations: [Observation] = []
    private(set) var resetCount = 0
    private(set) var inferenceConfigurationCallCount = 0
    private var mode: Mode = .immediate
    private var queued: [Result] = []
    private var suspended: CheckedContinuation<Data, Error>?
    private let codec = Phase2AIWorkerModelLifecycleWireCodec()

    var callCount: Int { observations.count }

    func setMode(_ mode: Mode) { self.mode = mode }
    func enqueue(_ result: Result) { queued.append(result) }

    func perform(requestData: Data, requestID: UUID) async throws -> Data {
        let request = try codec.decodeRequest(requestData)
        observations.append(.init(
            effectID: request.effectID,
            profileID: request.profileID,
            generation: request.generation,
            endpointOrigin: request.endpointOrigin,
            requestTimeoutMilliseconds: request.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: request.resourceTimeoutMilliseconds,
            operation: request.operation
        ))
        XCTAssertEqual(request.effectID, requestID)
        if mode == .suspendFirst, observations.count == 1 {
            return try await withCheckedThrowingContinuation { suspended = $0 }
        }
        return try encode(queued.removeFirst(), for: request)
    }

    func cancel(requestID _: UUID) async {}
    func reset() async { resetCount += 1 }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<2_000 {
            if observations.count >= expected { return }
            await Task.yield()
        }
        throw ProbeError.timeout
    }

    func completeFirst(with result: Result) {
        guard let suspended, let observation = observations.first else { return }
        self.suspended = nil
        do {
            let request = Phase2AIWorkerModelLifecycleRequest(
                schemaVersion: Phase2AIWorkerModelLifecycleWireCodec.schemaVersion,
                effectID: observation.effectID,
                profileID: observation.profileID,
                generation: observation.generation,
                endpointOrigin: observation.endpointOrigin,
                requestTimeoutMilliseconds: observation.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: observation.resourceTimeoutMilliseconds,
                operation: observation.operation
            )
            suspended.resume(returning: try encode(result, for: request))
        } catch {
            suspended.resume(throwing: error)
        }
    }

    private func encode(
        _ result: Result,
        for request: Phase2AIWorkerModelLifecycleRequest
    ) throws -> Data {
        let reply: Phase2AIWorkerModelLifecycleReply
        switch result {
        case .succeeded(let receipt):
            reply = .init(request: request, status: .succeeded, receipt: .init(receipt))
        case .authenticationRequired:
            reply = .init(request: request, status: .authenticationRequired, receipt: nil)
        case .rejected:
            reply = .init(request: request, status: .rejected, receipt: nil)
        case .reconciliationRequired:
            reply = .init(request: request, status: .reconciliationRequired, receipt: nil)
        }
        return try codec.encodeReply(reply)
    }

    enum ProbeError: Error { case timeout }
}

private actor LifecycleDiscoveryProbe: Phase2LocalModelDiscovering {
    private(set) var requestIDs: [UUID] = []
    private var queued: [Phase2LocalModelDiscoveryOutcome] = []

    var callCount: Int { requestIDs.count }

    func enqueue(_ result: Phase2LocalModelDiscoveryOutcome) { queued.append(result) }

    func discoverModels(
        endpoint _: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) async throws -> Phase2LocalModelDiscoveryOutcome {
        requestIDs.append(requestID)
        return queued.removeFirst()
    }

    func cancel(requestID _: UUID) async {}
}

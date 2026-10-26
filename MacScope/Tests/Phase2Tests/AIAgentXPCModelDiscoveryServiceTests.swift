import XCTest

@testable import MacScope

final class AIAgentXPCModelDiscoveryServiceTests: XCTestCase {
    func testProductionTransportCancellationBeforeRegistrationIsCancellation() async throws {
        let gate = DiscoveryTransportRegistrationGate()
        let transport = NSXPCAIWorkerModelDiscoveryTransport(
            pauseBeforePendingRegistration: { await gate.pause() }
        )
        let endpoint = try discoveryServiceEndpoint()
        let requestID = UUID()
        let requestData = try Phase2AIWorkerModelDiscoveryAppCodec().encodeRequest(
            endpoint: endpoint,
            requestID: requestID
        )
        let discovery = Task {
            try await transport.discover(requestData: requestData, requestID: requestID)
        }
        try await gate.waitUntilPaused()

        await transport.cancel(requestID: requestID)
        await gate.release()

        do {
            _ = try await discovery.value
            XCTFail("cancellation before pending registration must fail as cancellation")
        } catch is CancellationError {
            // Expected closed cancellation category.
        }
        await transport.reset()
    }

    func testDiscoveryMapsExactEndpointIdentityAndAlwaysResetsOneShotTransport() async throws {
        let endpoint = try discoveryServiceEndpoint(generation: 7)
        let transport = DiscoveryServiceTransport(mode: .immediate(.success))
        let service = AIAgentXPCModelDiscoveryService(transport: transport)

        let outcome = try await service.discoverModels(endpoint: endpoint)

        guard case .success(let inventory) = outcome else {
            return XCTFail("expected a successful inventory")
        }
        XCTAssertEqual(inventory.profileID, endpoint.profileID)
        XCTAssertEqual(inventory.generation, endpoint.generation)
        XCTAssertEqual(inventory.models.map(\.key), ["publisher/exact-model"])

        let observations = await transport.observations
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.profileID, endpoint.profileID)
        XCTAssertEqual(observations.first?.generation, endpoint.generation)
        XCTAssertEqual(observations.first?.endpointOrigin, endpoint.endpointOrigin)
        XCTAssertEqual(observations.first?.argumentID, observations.first?.envelopeID)
        let resetCount = await transport.resetCount
        XCTAssertEqual(resetCount, 1)
    }

    func testConcurrentDiscoveryFailsBusyBeforeCallingTransportTwice() async throws {
        let endpoint = try discoveryServiceEndpoint()
        let transport = DiscoveryServiceTransport(mode: .blockFirstRejectAdditional)
        let service = AIAgentXPCModelDiscoveryService(transport: transport)
        let first = Task { try await service.discoverModels(endpoint: endpoint) }
        try await waitForDiscoveryServiceCalls(1, transport: transport)

        do {
            _ = try await service.discoverModels(endpoint: endpoint)
            XCTFail("a second concurrent discovery must fail closed")
        } catch {
            // The exact presentation category is intentionally less important than proving the
            // second operation never crossed the one-shot transport boundary.
        }
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1)

        await transport.completeFirst(status: .success)
        _ = try await first.value
        let resetCount = await transport.resetCount
        XCTAssertEqual(resetCount, 1)
    }

    func testTaskCancellationCancelsExactRequestAndSuppressesLateSuccess() async throws {
        let endpoint = try discoveryServiceEndpoint()
        let transport = DiscoveryServiceTransport(mode: .lateSuccessAfterCancellation)
        let service = AIAgentXPCModelDiscoveryService(transport: transport)
        let discovery = Task { try await service.discoverModels(endpoint: endpoint) }
        try await waitForDiscoveryServiceCalls(1, transport: transport)

        discovery.cancel()
        let outcome = try await discovery.value

        XCTAssertEqual(outcome, .cancelled)
        let observations = await transport.observations
        let cancelledRequestIDs = await transport.cancelledRequestIDs
        let resetCount = await transport.resetCount
        XCTAssertEqual(cancelledRequestIDs, [observations[0].argumentID])
        XCTAssertEqual(resetCount, 1)
    }

    func testExplicitCancellationCancelsExactRequestAndSuppressesLateSuccess() async throws {
        let endpoint = try discoveryServiceEndpoint()
        let requestID = UUID()
        let transport = DiscoveryServiceTransport(mode: .lateSuccessAfterCancellation)
        let service = AIAgentXPCModelDiscoveryService(transport: transport)
        let discovery = Task {
            try await service.discoverModels(endpoint: endpoint, requestID: requestID)
        }
        try await waitForDiscoveryServiceCalls(1, transport: transport)

        await service.cancel(requestID: requestID)
        let outcome = try await discovery.value

        XCTAssertEqual(outcome, .cancelled)
        let cancelledRequestIDs = await transport.cancelledRequestIDs
        let resetCount = await transport.resetCount
        XCTAssertEqual(cancelledRequestIDs, [requestID])
        XCTAssertEqual(resetCount, 1)
    }

    func testTaskCancellationBeforeTransportRegistrationFailsClosedWithoutHanging() async throws {
        let endpoint = try discoveryServiceEndpoint()
        let transport = DiscoveryServiceTransport(mode: .pauseBeforeRegistration)
        let service = AIAgentXPCModelDiscoveryService(transport: transport)
        let discovery = Task { try await service.discoverModels(endpoint: endpoint) }
        try await waitForDiscoveryServiceCalls(1, transport: transport)

        discovery.cancel()
        let outcome = try await discovery.value

        XCTAssertEqual(outcome, .cancelled)
        let observations = await transport.observations
        let cancelledRequestIDs = await transport.cancelledRequestIDs
        let resetCount = await transport.resetCount
        XCTAssertEqual(cancelledRequestIDs, [observations[0].argumentID])
        XCTAssertEqual(resetCount, 1)
    }

    func testStaleReplyFailsClosedThenFreshDiscoverySucceedsAfterReset() async throws {
        let endpoint = try discoveryServiceEndpoint()
        let transport = DiscoveryServiceTransport(mode: .staleReply)
        let service = AIAgentXPCModelDiscoveryService(transport: transport)

        do {
            _ = try await service.discoverModels(endpoint: endpoint)
            XCTFail("a stale discovery reply must not become an inventory")
        } catch {
            XCTAssertEqual(
                error as? Phase2AIWorkerModelDiscoveryAppCodecError,
                .identityMismatch
            )
        }
        let firstResetCount = await transport.resetCount
        XCTAssertEqual(firstResetCount, 1)

        await transport.setMode(.immediate(.success))
        guard case .success(let inventory) = try await service.discoverModels(endpoint: endpoint) else {
            return XCTFail("a fresh one-shot discovery should work after teardown")
        }
        XCTAssertEqual(inventory.profileID, endpoint.profileID)
        let secondResetCount = await transport.resetCount
        XCTAssertEqual(secondResetCount, 2)
    }

    func testProviderFailureCategoriesRemainClosedPayloadFreeOutcomes() async throws {
        let endpoint = try discoveryServiceEndpoint()
        let pairs: [(Phase2AIWorkerModelDiscoveryReply.Status, Phase2LocalModelDiscoveryOutcome)] = [
            (.authenticationRequired, .authenticationRequired),
            (.unavailable, .unavailable),
            (.incompatible, .incompatible),
            (.cancelled, .cancelled),
        ]

        for (status, expected) in pairs {
            let transport = DiscoveryServiceTransport(mode: .immediate(status))
            let service = AIAgentXPCModelDiscoveryService(transport: transport)

            let actual = try await service.discoverModels(endpoint: endpoint)
            let resetCount = await transport.resetCount
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(resetCount, 1)
        }
    }
}

private actor DiscoveryTransportRegistrationGate {
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
            isPaused = true
        }
    }

    func waitUntilPaused() async throws {
        for _ in 0..<5_000 {
            if isPaused { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DiscoveryServiceTransport.ProbeError.unexpectedAdditionalCall
    }

    func release() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private actor DiscoveryServiceTransport: Phase2AIWorkerModelDiscoveryTransport {
    enum Mode: Sendable {
        case immediate(Phase2AIWorkerModelDiscoveryReply.Status)
        case blockFirstRejectAdditional
        case lateSuccessAfterCancellation
        case pauseBeforeRegistration
        case staleReply
    }

    struct Observation: Sendable {
        let argumentID: UUID
        let envelopeID: UUID
        let profileID: UUID
        let generation: UInt64
        let endpointOrigin: String
    }

    enum ProbeError: Error {
        case unexpectedAdditionalCall
    }

    private let codec = Phase2AIWorkerModelDiscoveryWireCodec()
    private(set) var observations: [Observation] = []
    private(set) var cancelledRequestIDs: [UUID] = []
    private(set) var resetCount = 0
    private var mode: Mode
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var requests: [UUID: Phase2AIWorkerModelDiscoveryRequest] = [:]
    private var preRegistrationGates: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    init(mode: Mode) {
        self.mode = mode
    }

    var callCount: Int { observations.count }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func discover(requestData: Data, requestID: UUID) async throws -> Data {
        let request = try codec.decodeRequest(requestData)
        observations.append(.init(
            argumentID: requestID,
            envelopeID: request.requestID,
            profileID: request.profileID,
            generation: request.generation,
            endpointOrigin: request.endpointOrigin
        ))
        requests[requestID] = request

        switch mode {
        case .immediate(let status):
            return try reply(for: request, status: status)
        case .staleReply:
            return try codec.encodeReply(.init(
                schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
                requestID: UUID(),
                profileID: request.profileID,
                generation: request.generation,
                status: .success,
                inventory: .init(models: [discoveryServiceWireModel()])
            ))
        case .blockFirstRejectAdditional:
            guard observations.count == 1 else { throw ProbeError.unexpectedAdditionalCall }
            return try await suspend(requestID: requestID)
        case .lateSuccessAfterCancellation:
            return try await suspend(requestID: requestID)
        case .pauseBeforeRegistration:
            await pauseBeforeRegistration(requestID: requestID)
            if cancelledBeforeRegistration.remove(requestID) != nil {
                throw CancellationError()
            }
            return try await suspend(requestID: requestID)
        }
    }

    func cancel(requestID: UUID) async {
        cancelledRequestIDs.append(requestID)
        if case .pauseBeforeRegistration = mode,
           let gate = preRegistrationGates.removeValue(forKey: requestID)
        {
            cancelledBeforeRegistration.insert(requestID)
            gate.resume()
            return
        }
        guard case .lateSuccessAfterCancellation = mode,
              let continuation = pending.removeValue(forKey: requestID),
              let request = requests[requestID]
        else { return }
        do {
            continuation.resume(returning: try reply(for: request, status: .success))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func reset() async {
        resetCount += 1
    }

    func completeFirst(status: Phase2AIWorkerModelDiscoveryReply.Status) {
        guard let requestID = observations.first?.argumentID,
              let continuation = pending.removeValue(forKey: requestID),
              let request = requests[requestID]
        else { return }
        do {
            continuation.resume(returning: try reply(for: request, status: status))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func suspend(requestID: UUID) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
        }
    }

    private func pauseBeforeRegistration(requestID: UUID) async {
        await withCheckedContinuation { continuation in
            preRegistrationGates[requestID] = continuation
        }
    }

    private func reply(
        for request: Phase2AIWorkerModelDiscoveryRequest,
        status: Phase2AIWorkerModelDiscoveryReply.Status
    ) throws -> Data {
        try codec.encodeReply(.init(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: request.requestID,
            profileID: request.profileID,
            generation: request.generation,
            status: status,
            inventory: status == .success
                ? .init(models: [discoveryServiceWireModel()])
                : nil
        ))
    }
}

private func discoveryServiceEndpoint(
    generation: UInt64 = 1
) throws -> Phase2LocalProviderEndpoint {
    try .init(
        profileID: UUID(uuidString: "8A33CD54-F8B0-4A7D-BB7F-D4FEC86C6A10")!,
        generation: generation,
        endpointOrigin: "http://127.0.0.1:1234",
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000
    )
}

private func discoveryServiceWireModel() -> Phase2AIWorkerModelWire {
    .init(
        type: .llm,
        publisher: "publisher",
        key: "publisher/exact-model",
        displayName: "Exact Model",
        architecture: nil,
        quantization: nil,
        sizeBytes: 1,
        parameters: nil,
        loadedInstances: [],
        maximumContextLength: 4_096,
        format: .gguf,
        capabilities: nil,
        summary: nil,
        variants: [],
        selectedVariant: nil
    )
}

private func waitForDiscoveryServiceCalls(
    _ expected: Int,
    transport: DiscoveryServiceTransport
) async throws {
    for _ in 0..<2_000 {
        if await transport.callCount >= expected { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for discovery transport call")
}

import XCTest

@testable import MacScope

final class Phase2AIWorkerModelDiscoveryPrincipalTests: XCTestCase {
    func testLegacyNilPolicyDiscoveryRejectsBeforeHandlerDispatch() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .immediate(.success))
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let request = discoveryPrincipalRequest(inferencePolicy: nil)
        let data = await invokeDiscovery(principal: principal, request: request)
        let reply = try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(data)
        XCTAssertEqual(reply.status, .incompatible)
        XCTAssertEqual(reply.requestID, request.requestID)
        XCTAssertNil(reply.inventory)
        let calls = await handler.callCount
        XCTAssertEqual(calls, 0)
    }

    func testInferenceFailureDiagnosticsExposeClosedCategoriesWithoutErrorPayloads() {
        XCTAssertEqual(Phase2AIWorkerPrincipal.failureDiagnosticCategory(
            Phase2OpenAIChatHTTPClientError.invalidStream), "http.invalidStream")
        XCTAssertEqual(Phase2AIWorkerPrincipal.failureDiagnosticCategory(
            Phase2GroundedFinalDecodingError.malformedEnvelope), "groundedFinal.malformedEnvelope")
        XCTAssertEqual(Phase2AIWorkerPrincipal.failureDiagnosticCategory(
            Phase2LiveInferenceHandlerError.unsupportedInferenceProtocol(123456)),
            "handler.unsupportedInferenceProtocol")
        let payload = "BEARER_SECRET private model text /Users/private/evidence"
        let unknown = NSError(domain: payload, code: 1, userInfo: [NSLocalizedDescriptionKey: payload])
        XCTAssertEqual(Phase2AIWorkerPrincipal.failureDiagnosticCategory(unknown), "unclassified")
    }

    func testDiscoverySucceedsBeforeInferenceConfigurationAndEchoesExactIdentity() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .immediate(.success))
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let request = discoveryPrincipalRequest()

        // Intentionally do not call the inference `configure` selector. Inventory discovery owns a
        // separate one-shot control connection and must precede model selection/configuration.
        let data = await invokeDiscovery(principal: principal, request: request)
        let reply = try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(data)

        XCTAssertEqual(reply.requestID, request.requestID)
        XCTAssertEqual(reply.profileID, request.profileID)
        XCTAssertEqual(reply.generation, request.generation)
        XCTAssertEqual(reply.status, .success)
        XCTAssertEqual(reply.inventory?.models.map(\.key), ["publisher/exact-model"])
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testDuplicateRequestIDFailsClosedWithoutStartingSecondHandlerTask() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .blockFirst)
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let request = discoveryPrincipalRequest()
        let first = Task { await invokeDiscovery(principal: principal, request: request) }
        try await waitForDiscoveryPrincipalCalls(1, handler: handler)

        let duplicateData = await invokeDiscovery(principal: principal, request: request)

        XCTAssertTrue(duplicateData.isEmpty)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 1)
        await handler.release()
        let firstReply = try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(await first.value)
        XCTAssertEqual(firstReply.status, .success)
    }

    func testCancellationReturnsExactlyOneCancelledTerminalAndSuppressesLateReply() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .blockFirst)
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let request = discoveryPrincipalRequest()
        let recorder = DiscoveryPrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelDiscoveryWireCodec().encodeRequest(request)

        principal.discoverModels(requestData: requestData, requestID: request.requestID) { data in
            recorder.receive(data)
        }
        try await waitForDiscoveryPrincipalCalls(1, handler: handler)
        principal.cancelModelDiscovery(requestID: request.requestID)

        let terminal = try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.requestID, request.requestID)
        XCTAssertEqual(terminal.profileID, request.profileID)
        XCTAssertEqual(terminal.generation, request.generation)
        XCTAssertEqual(terminal.status, .cancelled)
        XCTAssertNil(terminal.inventory)

        await handler.release()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(recorder.replyCount, 1)
    }

    func testMalformedOrMismatchedRequestFailsClosedWithoutInvokingHandler() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .immediate(.success))
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let request = discoveryPrincipalRequest()

        let malformed = await invokeDiscovery(
            principal: principal,
            requestData: Data("not-json".utf8),
            requestID: request.requestID
        )
        XCTAssertTrue(malformed.isEmpty)

        let encoded = try Phase2AIWorkerModelDiscoveryWireCodec().encodeRequest(request)
        let mismatched = await invokeDiscovery(
            principal: principal,
            requestData: encoded,
            requestID: UUID()
        )
        XCTAssertTrue(mismatched.isEmpty)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 0)

        let validAfterMalformed = await invokeDiscovery(principal: principal, request: request)
        XCTAssertTrue(validAfterMalformed.isEmpty)
        let finalCallCount = await handler.callCount
        XCTAssertEqual(finalCallCount, 0)
    }

    func testConnectionInvalidationIsTerminalBeforeDiscoveryRegistration() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .immediate(.success))
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)

        principal.cancelAllForConnectionInvalidation()
        let data = await invokeDiscovery(
            principal: principal,
            request: discoveryPrincipalRequest()
        )

        XCTAssertTrue(data.isEmpty)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testProviderFailureIsReturnedAsClosedPayloadFreeCategory() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .immediate(.unavailable))
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let request = discoveryPrincipalRequest()

        let data = await invokeDiscovery(principal: principal, request: request)
        let reply = try Phase2AIWorkerModelDiscoveryWireCodec().decodeReply(data)

        XCTAssertEqual(reply.requestID, request.requestID)
        XCTAssertEqual(reply.profileID, request.profileID)
        XCTAssertEqual(reply.generation, request.generation)
        XCTAssertEqual(reply.status, .unavailable)
        XCTAssertNil(reply.inventory)
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(serialized.contains("providerError"))
        XCTAssertFalse(serialized.contains("responseBody"))
    }

    func testConnectionAllowsOnlyOneSequentialDiscovery() async throws {
        let handler = DiscoveryPrincipalHandler(mode: .immediate(.success))
        let principal = Phase2AIWorkerPrincipal(modelDiscoveryHandler: handler)
        let first = discoveryPrincipalRequest()
        _ = await invokeDiscovery(principal: principal, request: first)

        let second = discoveryPrincipalRequest(requestID: UUID())
        let secondData = await invokeDiscovery(principal: principal, request: second)

        XCTAssertTrue(secondData.isEmpty)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testConnectionRoleCannotSwitchBetweenDiscoveryAndInference() async throws {
        let discoveryPrincipal = Phase2AIWorkerPrincipal(
            modelDiscoveryHandler: DiscoveryPrincipalHandler(mode: .immediate(.success))
        )
        _ = await invokeDiscovery(
            principal: discoveryPrincipal,
            request: discoveryPrincipalRequest()
        )
        let discoveryThenConfigure = await invokeConfiguration(principal: discoveryPrincipal)
        XCTAssertEqual(
            try Phase2AIWorkerConfigurationWireCodec()
                .decodeAcknowledgement(discoveryThenConfigure).status,
            .rejected
        )

        let inferencePrincipal = Phase2AIWorkerPrincipal(
            modelDiscoveryHandler: DiscoveryPrincipalHandler(mode: .immediate(.success))
        )
        let inferenceConfiguration = await invokeConfiguration(principal: inferencePrincipal)
        XCTAssertEqual(
            try Phase2AIWorkerConfigurationWireCodec()
                .decodeAcknowledgement(inferenceConfiguration).status,
            .accepted
        )
        let discoveryAfterInference = await invokeDiscovery(
            principal: inferencePrincipal,
            request: discoveryPrincipalRequest()
        )
        XCTAssertTrue(discoveryAfterInference.isEmpty)
    }
}

private actor DiscoveryPrincipalHandler: Phase2AIWorkerModelDiscoveryHandling {
    enum Mode: Sendable {
        case immediate(Phase2AIWorkerModelDiscoveryReply.Status)
        case blockFirst
    }

    private(set) var callCount = 0
    private var mode: Mode
    private var released = false

    init(mode: Mode) {
        self.mode = mode
    }

    func discoverModels(
        request: Phase2AIWorkerModelDiscoveryRequest
    ) async -> Phase2AIWorkerModelDiscoveryReply {
        callCount += 1
        let ordinal = callCount
        let status: Phase2AIWorkerModelDiscoveryReply.Status

        switch mode {
        case .immediate(let immediateStatus):
            status = immediateStatus
        case .blockFirst:
            if ordinal > 1 {
                status = .unavailable
            } else {
                while !released, !Task.isCancelled {
                    await Task.yield()
                }
                status = Task.isCancelled ? .cancelled : .success
            }
        }

        return .init(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: request.requestID,
            profileID: request.profileID,
            generation: request.generation,
            status: status,
            inventory: status == .success
                ? .init(models: [discoveryPrincipalWireModel()])
                : nil
        )
    }

    func release() {
        released = true
    }
}

private final class DiscoveryPrincipalReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Data] = []
    private var waiter: CheckedContinuation<Data, Never>?

    var replyCount: Int {
        lock.withLock { replies.count }
    }

    func receive(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Never>? in
            replies.append(data)
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: data)
    }

    func firstReply() async -> Data {
        if let existing = lock.withLock({ replies.first }) { return existing }
        return await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Data? in
                if let existing = replies.first { return existing }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

private func invokeDiscovery(
    principal: Phase2AIWorkerPrincipal,
    request: Phase2AIWorkerModelDiscoveryRequest
) async -> Data {
    let data = (try? Phase2AIWorkerModelDiscoveryWireCodec().encodeRequest(request)) ?? Data()
    return await invokeDiscovery(
        principal: principal,
        requestData: data,
        requestID: request.requestID
    )
}

private func invokeDiscovery(
    principal: Phase2AIWorkerPrincipal,
    requestData: Data,
    requestID: UUID
) async -> Data {
    await withCheckedContinuation { continuation in
        principal.discoverModels(requestData: requestData, requestID: requestID) { data in
            continuation.resume(returning: data)
        }
    }
}

private func discoveryPrincipalRequest(
    requestID: UUID = UUID(uuidString: "20B64FA2-EC7B-4E3A-9A33-6E714DDB8F91")!,
    inferencePolicy: Phase2LocalInferencePolicy? = .init()
) -> Phase2AIWorkerModelDiscoveryRequest {
    .init(
        schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
        requestID: requestID,
        profileID: UUID(uuidString: "AC8800C8-374C-4E14-BC4B-8D863793A264")!,
        generation: 4,
        endpointOrigin: "http://127.0.0.1:1234",
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000, inferencePolicy: inferencePolicy
    )
}

private func invokeConfiguration(principal: Phase2AIWorkerPrincipal) async -> Data {
    let configuration = Phase2AIWorkerConfigurationWire(
        schemaVersion: 1,
        profileID: UUID(uuidString: "AC8800C8-374C-4E14-BC4B-8D863793A264")!,
        generation: 4,
        endpointOrigin: "http://127.0.0.1:1234",
        model: "publisher/exact-model",
        protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest,
        maximumTokens: 1_024,
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000, inferencePolicy: .init()
    )
    let data = (try? Phase2AIWorkerConfigurationWireCodec()
        .encodeConfiguration(configuration)) ?? Data()
    return await withCheckedContinuation { continuation in
        principal.configure(configurationData: data) { reply in
            continuation.resume(returning: reply)
        }
    }
}

private func discoveryPrincipalWireModel() -> Phase2AIWorkerModelWire {
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

private func waitForDiscoveryPrincipalCalls(
    _ expected: Int,
    handler: DiscoveryPrincipalHandler
) async throws {
    for _ in 0..<2_000 {
        if await handler.callCount >= expected { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for worker discovery handler call")
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

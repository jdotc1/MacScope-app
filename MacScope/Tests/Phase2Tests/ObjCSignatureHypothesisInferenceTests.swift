import XCTest
@testable import MacScope

@MainActor
final class ObjCSignatureHypothesisInferenceTests: XCTestCase {
    func testRequestHasFixedBudgetsAndSelectedEvidence() throws {
        let request = try makeRequest()
        XCTAssertTrue(Phase2InferenceRunner.requestIsValid(request))
        XCTAssertEqual(request.phase, .finalization)
        XCTAssertTrue(request.toolHandles.isEmpty)
        XCTAssertEqual(request.maximumOutputTokens, 1_024)
        XCTAssertTrue(request.userGoal.contains("image 0, slice 1, source generation 2"))
        XCTAssertTrue(request.userGoal.contains("insufficient_evidence"))
        XCTAssertTrue(request.userGoal.contains("unknown fields as null"))
        XCTAssertThrowsError(try makeRequest(evidence: String(repeating: "x", count: 16_385)))
    }

    func testOutputBudgetOnlyLowersConfiguredLimit() throws {
        let request = try makeRequest()
        let configuration = try Phase2AIProviderConfiguration(
            profileID: UUID(), generation: 1, endpointOrigin: "http://127.0.0.1:1234",
            model: "local/test-model", maximumTokens: 4_096,
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 20_000
        )
        let bounded = try request.boundedProviderConfiguration(configuration)
        XCTAssertEqual(bounded.maximumTokens, 1_024)
        XCTAssertEqual(bounded.endpoint, configuration.endpoint)
        XCTAssertEqual(bounded.model, configuration.model)
        let encoded = try Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(
            bounded, protocolBundle: Phase2AIWorkerProductionProtocol.assistantR4
        )
        let transported = try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(encoded)
        XCTAssertEqual(transported.maximumTokens, 1_024)
        XCTAssertEqual(transported.endpointOrigin, configuration.endpointOrigin)
        XCTAssertEqual(transported.model, configuration.model)
        let smaller = try Phase2AIProviderConfiguration(
            endpoint: configuration.endpoint, model: configuration.model, maximumTokens: 512
        )
        XCTAssertEqual(try request.boundedProviderConfiguration(smaller), smaller)
        XCTAssertEqual(try withBudget(nil, request: request).boundedProviderConfiguration(configuration), configuration)
        for invalid in [0, -1, 16_385] {
            XCTAssertThrowsError(try withBudget(invalid, request: request).boundedProviderConfiguration(configuration))
        }
    }

    func testFakeProviderSuccessPreservesUnknownsAsHypothesis() async throws {
        let request = try makeRequest()
        let provider = SignatureHypothesisProvider()
        let result = await ObjCSignatureHypothesisInference().run(request: request, provider: provider)
        XCTAssertEqual(result, .available(.init(
            returnType: nil, parameterTypes: [nil, "id"], parameterNames: ["index", "value"],
            sdkVersion: nil, explanation: "Only the second argument has supported evidence."
        )))
        let captured = await provider.requests
        XCTAssertEqual(captured, [request])
    }

    func testMalformedAndOversizedAnswersFailClosed() throws {
        let valid = signatureHypothesisText
        let tooMany = Array(repeating: NSNull(), count: 65)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        var variants: [String] = [
            valid + " trailing", valid.replacingOccurrences(of: "{", with: "{\"extra\":true,"),
            valid.replacingOccurrences(of: "{", with: "{\"returnType\":\"id\","),
            String(repeating: " ", count: 16_385),
        ]
        let fields: [(String, Any)] = [
            ("returnType", true), ("returnType", String(repeating: "x", count: 257)),
            ("parameterTypes", tooMany), ("parameterTypes", [String(repeating: "x", count: 257)]),
            ("parameterNames", [String(repeating: "x", count: 129)]),
            ("parameterNames", Array(repeating: "name", count: 65)),
            ("sdkVersion", String(repeating: "x", count: 129)),
            ("explanation", String(repeating: "x", count: 4_097)),
        ]
        for (key, value) in fields {
            var changed = object
            changed[key] = value
            variants.append(String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self))
        }
        for variant in variants {
            XCTAssertNil(ObjCSignatureHypothesisInference.decode(variant))
        }
    }

    func testUnavailableAndProviderFailureTerminate() async throws {
        let request = try makeRequest()
        let service = ObjCSignatureHypothesisInference()
        let unavailable = await service.run(request: request, provider: nil)
        XCTAssertEqual(unavailable, .unavailable)
        let failed = await service.run(request: request, provider: SignatureHypothesisProvider(fails: true))
        guard case .failed = failed else { return XCTFail("Expected terminal provider failure") }
    }

    func testTimeoutCancelsNoncooperativeProviderAndRejectsLateSuccess() async throws {
        let request = try makeRequest()
        let provider = SignatureHypothesisProvider(held: true)
        let task = Task {
            await ObjCSignatureHypothesisInference(timeout: .milliseconds(100))
                .run(request: request, provider: provider)
        }
        await provider.waitUntilStarted()
        let result = await task.value
        XCTAssertEqual(result, .failed("MTPLX hypothesis timed out."))
        await provider.waitUntilCancelled()
        let cancellations = await provider.cancelledRequestIDs
        XCTAssertEqual(cancellations, [request.requestID])
        await provider.release()
        await provider.waitUntilFinished()
        XCTAssertEqual(result, .failed("MTPLX hypothesis timed out."))
    }

    func testSelectionCancellationReturnsBeforeNoncooperativeProviderDrains() async throws {
        let request = try makeRequest()
        let provider = SignatureHypothesisProvider(held: true)
        let task = Task { await ObjCSignatureHypothesisInference().run(request: request, provider: provider) }
        await provider.waitUntilStarted()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        await provider.waitUntilCancelled()
        let cancellations = await provider.cancelledRequestIDs
        XCTAssertEqual(cancellations, [request.requestID])
        await provider.release()
        await provider.waitUntilFinished()
        XCTAssertEqual(result, .cancelled)
    }

    func testProviderTokenUsageAboveCapIsRejected() async throws {
        let result = await ObjCSignatureHypothesisInference().run(
            request: try makeRequest(), provider: SignatureHypothesisProvider(completionTokens: 1_025)
        )
        guard case .failed = result else { return XCTFail("Expected output token cap rejection") }
    }

    private func makeRequest(
        evidence: String = "image 0, slice 1, source generation 2; selector setIndex:value:"
    ) throws -> Phase2InferenceRequest {
        let document = Phase2ReadDocumentIdentity(instanceID: UUID())
        return try ObjCSignatureHypothesisInference.makeRequest(
            document: document, workspace: .init(document: document, instanceID: UUID()),
            lifecycleRevision: 2, evidence: evidence
        )
    }

    private func withBudget(_ budget: Int?, request: Phase2InferenceRequest) -> Phase2InferenceRequest {
        .init(
            protocolVersion: request.protocolVersion, phase: request.phase,
            sessionID: request.sessionID, turnID: request.turnID, requestID: request.requestID,
            document: request.document, workspace: request.workspace, lifecycleRevision: request.lifecycleRevision,
            userGoal: request.userGoal, groundedContext: request.groundedContext,
            toolHandles: request.toolHandles, limits: request.limits, maximumOutputTokens: budget
        )
    }
}

private let signatureHypothesisText = """
{"returnType":null,"parameterTypes":[null,"id"],"parameterNames":["index","value"],"sdkVersion":null,"explanation":"Only the second argument has supported evidence."}
"""

private actor SignatureHypothesisProvider: Phase2InferenceProviding {
    enum Failure: Error { case expected }
    private let held: Bool
    private let fails: Bool
    private let completionTokens: Int
    private(set) var requests: [Phase2InferenceRequest] = []
    private(set) var cancelledRequestIDs: [UUID] = []
    private var released = false
    private var finished = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(held: Bool = false, fails: Bool = false, completionTokens: Int = 32) {
        self.held = held
        self.fails = fails
        self.completionTokens = completionTokens
    }

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        defer {
            finished = true
            finishWaiters.forEach { $0.resume() }
            finishWaiters.removeAll()
        }
        if fails { throw Failure.expected }
        if held && !released { await withCheckedContinuation { releaseWaiter = $0 } }
        guard let usage = Phase2ProviderUsage(
            promptTokens: 10, completionTokens: completionTokens, totalTokens: completionTokens + 10
        ) else { throw Failure.expected }
        let bodies: [Phase2InferenceEventBody] = [
            .finalCandidate(.init(kind: .insufficientEvidence, text: signatureHypothesisText, evidenceIDs: [])),
            .usage(usage), .completed,
        ]
        for (index, body) in bodies.enumerated() {
            try await emit(.init(
                protocolVersion: request.protocolVersion, phase: request.phase,
                sessionID: request.sessionID, turnID: request.turnID, requestID: request.requestID,
                document: request.document, workspace: request.workspace, lifecycleRevision: request.lifecycleRevision,
                sequence: UInt64(index + 1), body: body
            ))
        }
    }

    func cancel(requestID: UUID) async {
        cancelledRequestIDs.append(requestID)
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if requests.isEmpty { await withCheckedContinuation { startWaiters.append($0) } }
    }

    func waitUntilCancelled() async {
        if cancelledRequestIDs.isEmpty { await withCheckedContinuation { cancellationWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitUntilFinished() async {
        if !finished { await withCheckedContinuation { finishWaiters.append($0) } }
    }
}

import CFNetwork
import Foundation
import XCTest

@testable import MacScope

final class Phase2OpenAIChatHTTPClientTests: XCTestCase {
    func testPostsExactChatCompletionsRequestAndStreamsDecodedEvents() async throws {
        let recorder = EventRecorder()
        let loader = StubLoader { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.timeoutInterval, 7)

            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            XCTAssertEqual(object["model"] as? String, "model-1")
            XCTAssertEqual(object["stream"] as? Bool, true)
            XCTAssertEqual(object["max_tokens"] as? Int, 64)
            XCTAssertNotNil(object["response_format"])
            XCTAssertEqual(object["tool_choice"] as? String, "auto")
            XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
            let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 2)
            let functionNames = try tools.map {
                try XCTUnwrap(($0["function"] as? [String: Any])?["name"] as? String)
            }
            XCTAssertEqual(Set(functionNames), [
                "macscope_stage_shell_proposal_v1",
                "macscope_stage_debugger_action_proposal_v1",
            ])

            return response(contentType: "text/event-stream; charset=utf-8", chunks: [
                Data(sse(roleChunk()).utf8),
                Data((sse(contentChunk("hello")) + sse(stopChunk())).utf8),
                Data((sse(usageChunk()) + sse("[DONE]")).utf8)
            ])
        }
        let client = Phase2OpenAIChatHTTPClient(loader: loader, limits: .init(requestTimeout: 7))

        try await client.execute(input(acceptsFinalizationProposalTools: true), onEvent: { event in
            await recorder.append(event)
        })

        let events = await recorder.events
        XCTAssertEqual(events, [
            .contentDelta("hello"),
            .finished,
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .done
        ])
    }

    func testFinalizationOmitsProposalToolsWhenProtocolDoesNotAcceptThem() async throws {
        let loader = StubLoader { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                    as? [String: Any]
            )
            XCTAssertNil(object["tools"])
            XCTAssertNil(object["tool_choice"])
            XCTAssertNil(object["parallel_tool_calls"])
            XCTAssertNotNil(object["response_format"])
            return response(chunks: [
                Data(sse(contentChunk("hello")).utf8),
                Data((sse(stopChunk()) + sse(usageChunk()) + sse("[DONE]")).utf8),
            ])
        }
        let client = Phase2OpenAIChatHTTPClient(loader: loader)

        try await client.execute(input(), onEvent: { _ in })
    }

    func testToolSelectionUsesProductionToolsAndForwardsCallsOnlyAfterCleanEOF() async throws {
        let handleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let recorder = EventRecorder()
        let loader = StubLoader { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            XCTAssertEqual(object["tool_choice"] as? String, "required")
            XCTAssertEqual(object["parallel_tool_calls"] as? Bool, true)
            XCTAssertNil(object["response_format"])
            let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 1)
            let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "macscope_workspace_summary_v1")

            return response(chunks: [
                Data(sse(toolSelectionChunk(
                    handleID: handleID,
                    finishReason: "tool_calls"
                )).utf8),
                Data((sse(usageChunk()) + sse("[DONE]")).utf8),
            ])
        }
        let client = Phase2OpenAIChatHTTPClient(loader: loader)

        try await client.execute(input(phase: .toolSelection(handles: [
            .init(handleID: handleID, operationID: "workspace.summary"),
        ])), onEvent: { event in
            await recorder.append(event)
        })

        let events = await recorder.events
        XCTAssertEqual(events, [
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .toolCall(.init(
                opaqueCallID: "opaque-call-1",
                functionName: "macscope_workspace_summary_v1",
                handleID: handleID
            )),
            .awaitingTools,
        ])
    }

    func testRejectsRedirectStatusContentTypeAndFinalURLWithoutLeakingPayloads() async throws {
        let secret = "BEARER_SECRET_/Users/private"
        let cases: [(Phase2OpenAIChatHTTPResponse, Phase2OpenAIChatHTTPClientError)] = [
            (response(status: 302, contentType: "text/event-stream", chunks: [Data(secret.utf8)]), .redirectRejected),
            (response(status: 503, contentType: "text/event-stream", chunks: [Data(secret.utf8)]), .invalidStatus),
            (response(contentType: "application/json", chunks: [Data(secret.utf8)]), .invalidContentType),
            (response(contentType: "text/event-stream; charset=utf-8\r\nX-Artifact: secret", chunks: [Data(secret.utf8)]), .invalidContentType),
            (response(finalURL: URL(string: "http://127.0.0.1:1234/elsewhere")!, chunks: []), .redirectRejected)
        ]

        for (stubResponse, expected) in cases {
            let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in stubResponse })
            do {
                try await client.execute(input(), onEvent: { _ in })
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, expected)
                XCTAssertFalse(String(describing: error).contains(secret))
            }
        }
    }

    func testTransportAndDecoderErrorsAreStableAndPayloadFree() async throws {
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            throw StubError("BEARER_SECRET_/Users/private")
        })
        await assertClientError(.transportFailed) {
            try await client.execute(input(), onEvent: { _ in })
        }

        let malformed = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            response(chunks: [Data("BEARER_SECRET: /Users/private\n\n".utf8)])
        })
        await assertClientError(.invalidStream) {
            try await malformed.execute(input(), onEvent: { _ in })
        }
    }

    func testResponseByteBudgetIsEnforcedAcrossChunks() async throws {
        let client = Phase2OpenAIChatHTTPClient(
            loader: StubLoader { _ in
                response(chunks: [Data(repeating: 0x61, count: 5), Data(repeating: 0x62, count: 4)])
            },
            limits: .init(maximumResponseBytes: 8)
        )

        await assertClientError(.responseLimitExceeded) {
            try await client.execute(input(), onEvent: { _ in })
        }
    }

    func testProviderStreamErrorRemainsTypedAndDoesNotEmitCompletion() async throws {
        let recorder = EventRecorder()
        let body = #"{"error":{"message":"BEARER_SECRET /Users/private/context","type":"memory_refusal","code":507}}"#
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            response(chunks: [Data((sse(body) + sse("[DONE]")).utf8)])
        })

        do {
            try await client.execute(input(), onEvent: { event in
                await recorder.append(event)
            })
            XCTFail("Provider refusal must not produce a completed response")
        } catch {
            XCTAssertEqual(String(describing: error), "providerError")
            XCTAssertFalse(String(describing: error).contains("BEARER_SECRET"))
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
        }
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }

    func testCancellationIsReportedWithoutConsumingStream() async throws {
        let stream = AsyncThrowingStream<Data, Error> { _ in }
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            Phase2OpenAIChatHTTPResponse(
                statusCode: 200,
                contentType: "text/event-stream",
                finalURL: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
                body: stream
            )
        })

        let requestInput = input()
        let task = Task { @Sendable in
            try await client.execute(requestInput, onEvent: { _ in })
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, .cancelled)
        }
    }

    func testCancellationAfterPartialToolCallCancelsResponseWithoutForwardingProposal() async throws {
        let handleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let probe = PartialToolCancellationProbe()
        let partialToolCall = """
        {"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"opaque-call-1","type":"function","function":{"name":"macscope_workspace_summary_v1","arguments":"{\\\"handle_id\\\":\\\""}}]},"finish_reason":null}]}
        """
        let (stream, streamContinuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(0)
        )
        streamContinuation.onTermination = { @Sendable _ in
            Task { await probe.recordStreamTermination() }
        }
        let recorder = EventRecorder()
        let requestInput = input(phase: .toolSelection(handles: [
            .init(handleID: handleID, operationID: "workspace.summary"),
        ]))
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            await probe.recordLoad()
            return Phase2OpenAIChatHTTPResponse(
                statusCode: 200,
                contentType: "text/event-stream",
                finalURL: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
                body: stream,
                cancel: {
                    streamContinuation.finish(throwing: CancellationError())
                    Task { await probe.recordResponseCancellation() }
                }
            )
        })
        let task = Task { @Sendable in
            try await client.execute(requestInput, onEvent: { await recorder.append($0) })
        }

        let didLoad = await probe.waitUntilLoaded()
        XCTAssertTrue(didLoad)
        let partialData = Data(sse(partialToolCall).utf8)
        let clock = ContinuousClock()
        let deliveryDeadline = clock.now.advanced(by: .seconds(2))
        var didDeliverPartial = false
        while !didDeliverPartial, clock.now < deliveryDeadline {
            switch streamContinuation.yield(partialData) {
            case .enqueued:
                didDeliverPartial = true
            case .dropped:
                await Task.yield()
            case .terminated:
                break
            @unknown default:
                break
            }
        }
        XCTAssertTrue(didDeliverPartial)

        // A second zero-buffered delivery cannot enqueue until the client has
        // consumed and decoded the partial tool-call chunk, then requested its
        // next body element.
        let consumptionDeadline = clock.now.advanced(by: .seconds(2))
        var didConsumePartial = false
        while !didConsumePartial, clock.now < consumptionDeadline {
            switch streamContinuation.yield(Data()) {
            case .enqueued:
                didConsumePartial = true
            case .dropped:
                await Task.yield()
            case .terminated:
                break
            @unknown default:
                break
            }
        }
        XCTAssertTrue(didConsumePartial)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, .cancelled)
        }

        let forwardedEvents = await recorder.events
        XCTAssertEqual(forwardedEvents, [])
        let didCancel = await probe.waitUntilCancelled()
        XCTAssertTrue(didCancel)
        let cancellationCounts = await probe.cancellationCounts
        XCTAssertEqual(cancellationCounts.response, 1)
        XCTAssertEqual(cancellationCounts.stream, 1)
    }

    func testCancellationDuringEventDeliveryStopsRemainingEventsFromTheSameChunk() async {
        let recorder = EventRecorder()
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            response(chunks: [Data((
                sse(contentChunk("hello"))
                    + sse(stopChunk())
                    + sse(usageChunk())
                    + sse("[DONE]")
            ).utf8)])
        })
        let requestInput = input()

        let task = Task { @Sendable in
            try await client.execute(requestInput, onEvent: { event in
                await recorder.append(event)
                if case .contentDelta = event {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }

        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, .cancelled)
        }
        let events = await recorder.events
        XCTAssertEqual(events, [.contentDelta("hello")])
    }

    func testProductionSessionConfigurationDisablesAmbientState() {
        let configuration = Phase2OpenAIChatURLSessionLoader.makeSessionConfiguration(
            requestTimeout: 3,
            resourceTimeout: 9
        )

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 3)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 9)
        let proxyPolicy = try? XCTUnwrap(configuration.connectionProxyDictionary)
        XCTAssertEqual(proxyPolicy?[kCFNetworkProxiesHTTPEnable as String] as? Bool, false)
        XCTAssertEqual(proxyPolicy?[kCFNetworkProxiesHTTPSEnable as String] as? Bool, false)
        XCTAssertEqual(proxyPolicy?[kCFNetworkProxiesSOCKSEnable as String] as? Bool, false)
        XCTAssertEqual(
            proxyPolicy?[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool,
            false
        )
        XCTAssertEqual(
            proxyPolicy?[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Bool,
            false
        )
    }

    func testProductionLoaderDefaultsToChatBudgetAndAcceptsNarrowerProducerBudget() {
        XCTAssertEqual(
            Phase2OpenAIChatURLSessionLoader().maximumProducedResponseBytes,
            8 * 1_024 * 1_024
        )
        XCTAssertEqual(
            Phase2OpenAIChatURLSessionLoader(maximumProducedResponseBytes: 2 * 1_024 * 1_024)
                .maximumProducedResponseBytes,
            2 * 1_024 * 1_024
        )
    }

    func testProductionLoaderRejectsKnownOversizedContentLengthBeforeStreaming() {
        XCTAssertNoThrow(
            try Phase2OpenAIChatURLSessionLoader.validateExpectedContentLength(
                2 * 1_024 * 1_024,
                maximumProducedResponseBytes: 2 * 1_024 * 1_024
            )
        )
        XCTAssertNoThrow(
            try Phase2OpenAIChatURLSessionLoader.validateExpectedContentLength(
                NSURLSessionTransferSizeUnknown,
                maximumProducedResponseBytes: 2 * 1_024 * 1_024
            )
        )
        XCTAssertThrowsError(
            try Phase2OpenAIChatURLSessionLoader.validateExpectedContentLength(
                2 * 1_024 * 1_024 + 1,
                maximumProducedResponseBytes: 2 * 1_024 * 1_024
            )
        ) { error in
            XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, .responseLimitExceeded)
        }
    }

    func testMTPLXHTTPClientAcceptsInstalledRuntimeInlineFinishUsageAndDone() async throws {
        let telemetry = String(repeating: "x", count: 20_000)
        let terminal = String(stopChunk().dropLast()) + #","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10},"mtplx_stats":{"diagnostic_notes":"\#(telemetry)"}}"#
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            response(chunks: [Data((sse(contentChunk("hello")) + sse(String(terminal)) + sse("[DONE]")).utf8)])
        })
        let recorder = EventRecorder()
        try await client.execute(input(inferencePolicy: .init()), onEvent: { await recorder.append($0) })
        let events = await recorder.events
        XCTAssertEqual(events, [.contentDelta("hello"), .finished,
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)), .done])
    }

    func testTotalDeadlineIncludesWaitingForHTTPHeaders() async throws {
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            try await Task.sleep(for: .seconds(10))
            return response(chunks: [])
        }, limits: .init(requestTimeout: 0.03, resourceTimeout: 0.05))
        await assertClientError(.totalDeadlineExceeded) {
            try await client.execute(input(), onEvent: { _ in })
        }
    }

    func testMTPLXReasoningKeepsValidProgressAliveWithoutEnteringFinalContent() async throws {
        let recorder = EventRecorder()
        let reasoning = roleChunk().replacingOccurrences(of: #"{"role":"assistant"}"#,
            with: #"{"reasoning_content":"private"}"#)
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            timedResponse(chunks: Array(repeating: Data(sse(reasoning).utf8), count: 7)
                + [Data((sse(contentChunk("hello")) + sse(stopChunk())
                    + sse(usageChunk()) + sse("[DONE]")).utf8)], delay: .milliseconds(100))
        }, limits: .init(requestTimeout: 0.3, resourceTimeout: 2))
        try await client.execute(input(inferencePolicy: .init()), onEvent: { await recorder.append($0) })
        let events = await recorder.events
        XCTAssertEqual(events.filter { if case .reasoningProgress = $0 { return true }; return false }.count, 7)
        XCTAssertEqual(events.filter { if case .contentDelta = $0 { return true }; return false }, [.contentDelta("hello")])
    }

    func testMTPLXHeartbeatBytesCannotKeepAStalledModelAlive() async throws {
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            timedResponse(chunks: Array(repeating: Data(": heartbeat\n\n".utf8), count: 20),
                delay: .milliseconds(100))
        }, limits: .init(requestTimeout: 0.3, resourceTimeout: 2))
        await assertClientError(.inactivityTimeout) {
            try await client.execute(input(inferencePolicy: .init()), onEvent: { _ in })
        }
    }

    func testLengthTerminationHasDistinctIncompleteOutputFailure() async throws {
        let length = stopChunk().replacingOccurrences(of: #""stop""#, with: #""length""#)
        let client = Phase2OpenAIChatHTTPClient(loader: StubLoader { _ in
            response(chunks: [Data((sse(contentChunk("partial")) + sse(length)).utf8)])
        })
        await assertClientError(.outputLimitExceeded) {
            try await client.execute(input(), onEvent: { _ in })
        }
    }

    private func input(
        phase: Phase2OpenAIProductionChatPhase = .finalization,
        acceptsFinalizationProposalTools: Bool = false,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) -> Phase2OpenAIChatHTTPInput {
        Phase2OpenAIChatHTTPInput(
            endpoint: try! Phase2LoopbackEndpoint(validating: "http://127.0.0.1:1234"),
            model: "model-1",
            systemPrompt: "system",
            userPrompt: "user",
            maximumTokens: 64,
            phase: phase,
            generationVariant: .productionV1,
            acceptsFinalizationProposalTools: acceptsFinalizationProposalTools,
            inferencePolicy: inferencePolicy
        )
    }

    private func assertClientError(
        _ expected: Phase2OpenAIChatHTTPClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, expected)
            XCTAssertFalse(String(describing: error).contains("BEARER_SECRET"))
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
        }
    }
}

private struct StubLoader: Phase2OpenAIChatURLLoading {
    let handler: @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse

    init(handler: @escaping @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse) {
        self.handler = handler
    }

    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        try await handler(request)
    }
}

private struct StubError: Error, @unchecked Sendable {
    let payload: String
    init(_ payload: String) { self.payload = payload }
}

private actor EventRecorder {
    private(set) var events: [Phase2OpenAIChatStreamEvent] = []
    func append(_ event: Phase2OpenAIChatStreamEvent) { events.append(event) }
}

private actor PartialToolCancellationProbe {
    private var loaded = false
    private var responseCancellations = 0
    private var streamTerminations = 0

    var cancellationCounts: (response: Int, stream: Int) {
        (responseCancellations, streamTerminations)
    }

    func recordLoad() {
        loaded = true
    }

    func recordResponseCancellation() {
        responseCancellations += 1
    }

    func recordStreamTermination() {
        streamTerminations += 1
    }

    func waitUntilLoaded() async -> Bool {
        await waitUntil { loaded }
    }

    func waitUntilCancelled() async -> Bool {
        await waitUntil { responseCancellations > 0 && streamTerminations > 0 }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private func response(
    status: Int = 200,
    contentType: String = "text/event-stream",
    finalURL: URL = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
    chunks: [Data]
) -> Phase2OpenAIChatHTTPResponse {
    Phase2OpenAIChatHTTPResponse(
        statusCode: status,
        contentType: contentType,
        finalURL: finalURL,
        body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    )
}

private func sse(_ data: String) -> String { "data: \(data)\n\n" }

private func roleChunk() -> String {
    #"{"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#
}

private func contentChunk(_ content: String) -> String {
    #"{"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[{"index":0,"delta":{"content":"\#(content)"},"finish_reason":null}]}"#
}

private func stopChunk() -> String {
    #"{"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
}

private func usageChunk() -> String {
    #"{"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}"#
}

private func toolSelectionChunk(handleID: UUID, finishReason: String) -> String {
    """
    {"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"opaque-call-1","type":"function","function":{"name":"macscope_workspace_summary_v1","arguments":"{\\\"handle_id\\\":\\\"\(handleID.uuidString)\\\"}"}}]},"finish_reason":"\(finishReason)"}]}
    """
}

private func timedResponse(chunks: [Data], delay: Duration) -> Phase2OpenAIChatHTTPResponse {
    let body = AsyncThrowingStream<Data, Error> { continuation in
        let producer = Task {
            do {
                for chunk in chunks {
                    try await Task.sleep(for: delay)
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
    }
    return Phase2OpenAIChatHTTPResponse(statusCode: 200, contentType: "text/event-stream",
        finalURL: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!, body: body)
}

import CFNetwork
import Foundation
import XCTest

@testable import MacScope

final class Phase2NativeModelLifecycleHTTPClientTests: XCTestCase {
    func testLoadPostsExactBoundedNativeRequestAndReturnsProviderAppliedConfiguration() async throws {
        let invocations = LifecycleInvocationCounter()
        let client = Phase2NativeModelLifecycleHTTPClient(loader: LifecycleStubLoader { request in
            invocations.record(request)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/api/v1/models/load")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.timeoutInterval, 7)
            XCTAssertEqual(
                request.httpBody,
                Data(#"{"context_length":4096,"echo_load_config":true,"model":"model-a"}"#.utf8)
            )
            XCTAssertNil(request.httpBodyStream)
            return lifecycleResponse(
                finalURL: request.url!,
                chunks: [Data(validLoadResponse.utf8)]
            )
        }, requestTimeout: 7)

        let receipt = try await client.perform(
            .load(modelKey: "model-a", contextLength: 4_096),
            at: endpoint()
        )

        guard case let .loaded(result) = receipt else {
            return XCTFail("expected load receipt")
        }
        XCTAssertEqual(result.instanceID, "instance-a")
        XCTAssertEqual(result.loadTimeSeconds, 1.25)
        XCTAssertEqual(result.configuration.contextLength, 8_192)
        XCTAssertEqual(result.configuration.evaluationBatchSize, 256)
        XCTAssertEqual(result.configuration.flashAttention, true)
        XCTAssertEqual(result.configuration.expertCount, 4)
        XCTAssertEqual(result.configuration.offloadsKVCacheToGPU, false)
        XCTAssertEqual(invocations.count, 1)
    }

    func testUnloadPostsExactInstanceIdentityAndRequiresExactEcho() async throws {
        let client = Phase2NativeModelLifecycleHTTPClient(loader: LifecycleStubLoader { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/api/v1/models/unload")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.httpBody, Data(#"{"instance_id":"instance-a"}"#.utf8))
            return lifecycleResponse(
                finalURL: request.url!,
                chunks: [Data(#"{"instance_id":"instance-a"}"#.utf8)]
            )
        })

        let receipt = try await client.perform(.unload(instanceID: "instance-a"), at: endpoint())
        guard case let .unloaded(instanceID) = receipt else {
            return XCTFail("expected unload receipt")
        }
        XCTAssertEqual(instanceID, "instance-a")

        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { request in
                    lifecycleResponse(
                        finalURL: request.url!,
                        chunks: [Data(#"{"instance_id":"different-instance"}"#.utf8)]
                    )
                }
            ).perform(.unload(instanceID: "instance-a"), at: self.endpoint())
        }
    }

    func testRejectsRedirectAuthenticationFinalURLStatusAndMediaTypeWithoutPayloadDisclosure() async {
        let secret = "BEARER_SECRET_/Users/private"
        let requestedLoadURL = URL(string: "http://127.0.0.1:1234/api/v1/models/load")!
        let cases: [(Phase2OpenAIChatHTTPResponse, Phase2NativeModelLifecycleHTTPClientError)] = [
            (lifecycleResponse(status: 302, finalURL: requestedLoadURL, chunks: [Data(secret.utf8)]), .reconciliationRequired),
            (lifecycleResponse(finalURL: URL(string: "http://127.0.0.1:1234/elsewhere")!, chunks: []), .reconciliationRequired),
            (lifecycleResponse(status: 401, finalURL: requestedLoadURL, chunks: [Data(secret.utf8)]), .authenticationRequired),
            (lifecycleResponse(status: 403, finalURL: requestedLoadURL, chunks: [Data(secret.utf8)]), .authenticationRequired),
            (lifecycleResponse(status: 503, finalURL: requestedLoadURL, chunks: [Data(secret.utf8)]), .rejected),
            (lifecycleResponse(contentType: "text/plain", finalURL: requestedLoadURL, chunks: [Data(secret.utf8)]), .reconciliationRequired),
        ]

        for (response, expected) in cases {
            await assertLifecycleError(expected) {
                _ = try await Phase2NativeModelLifecycleHTTPClient(
                    loader: LifecycleStubLoader { _ in response }
                ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
            }
        }
    }

    func testRejectsContentTypeContainingHeaderLineBreaks() async {
        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { request in
                    lifecycleResponse(
                        contentType: "application/json; charset=utf-8\r\nX-Artifact: secret",
                        finalURL: request.url!,
                        chunks: [Data(validLoadResponse.utf8)]
                    )
                }
            ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
        }
    }

    func testRejectsNumericBooleanLoadConfigurationValues() async {
        for field in ["flash_attention", "offload_kv_cache_to_gpu"] {
            let response = "{\"type\":\"llm\",\"instance_id\":\"instance-a\",\"load_time_seconds\":1,\"status\":\"loaded\",\"load_config\":{\"context_length\":4096,\"\(field)\":1}}"
            await assertLifecycleError(.reconciliationRequired) {
                _ = try await Phase2NativeModelLifecycleHTTPClient(
                    loader: LifecycleStubLoader { request in
                        lifecycleResponse(finalURL: request.url!, chunks: [Data(response.utf8)])
                    }
                ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
            }
        }
    }

    func testRejectsExcessivelyNestedAdditiveLoadConfiguration() async {
        let depth = 33
        let nested = String(repeating: "[", count: depth)
            + "null"
            + String(repeating: "]", count: depth)
        let response = "{\"type\":\"llm\",\"instance_id\":\"instance-a\",\"load_time_seconds\":1,\"status\":\"loaded\",\"load_config\":{\"context_length\":4096,\"future\":\(nested)}}"

        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { request in
                    lifecycleResponse(finalURL: request.url!, chunks: [Data(response.utf8)])
                }
            ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
        }
    }

    func testTransportProducerLimitAndMalformedRepliesBecomePayloadFreeReconciliation() async {
        let secret = "BEARER_SECRET_/Users/private"
        let invalidReplies = [
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":1,"status":"loaded","load_config":{"context_length":4096},"unknown":true}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","instance_id":"again","load_time_seconds":1,"status":"loaded","load_config":{"context_length":4096}}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":1,"status":"loaded","load_config":{"context_length":4096,"context_length":8192}}"#.utf8),
            Data(#"{"type":"embedding","instance_id":"instance-a","load_time_seconds":1,"status":"loaded","load_config":{"context_length":4096}}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":-1,"status":"loaded","load_config":{"context_length":4096}}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":1e309,"status":"loaded","load_config":{"context_length":4096}}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":1,"status":"loading","load_config":{"context_length":4096}}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":1,"status":"loaded","load_config":{"context_length":4194305}}"#.utf8),
            Data(#"{"type":"llm","instance_id":"instance-a","load_time_seconds":1,"status":"loaded","load_config":{"context_length":4096}} trailing"#.utf8),
            Data([0xFF]),
        ]

        for data in invalidReplies {
            await assertLifecycleError(.reconciliationRequired) {
                _ = try await Phase2NativeModelLifecycleHTTPClient(
                    loader: LifecycleStubLoader { request in
                        lifecycleResponse(finalURL: request.url!, chunks: [data])
                    }
                ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
            }
        }

        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { _ in
                    throw Phase2OpenAIChatHTTPClientError.responseLimitExceeded
                }
            ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
        }
        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { _ in
                    throw LifecycleSecretError(payload: secret)
                }
            ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
        }
    }

    func testResponseBudgetAcceptsMaximumAndRejectsMaximumPlusOneAcrossChunks() async throws {
        let base = Data(validLoadResponse.utf8)
        let exact = base + Data(repeating: 0x20, count: 65_536 - base.count)
        _ = try await Phase2NativeModelLifecycleHTTPClient(
            loader: LifecycleStubLoader { request in
                lifecycleResponse(finalURL: request.url!, chunks: [exact])
            }
        ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: endpoint())

        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { request in
                    lifecycleResponse(finalURL: request.url!, chunks: [
                        Data(repeating: 0x20, count: 65_536),
                        Data([0x20]),
                    ])
                }
            ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
        }
    }

    func testIdentifierAndConfigurationBoundsAndAdditiveLoadConfiguration() async throws {
        let maximumID = String(repeating: "i", count: 512)
        let additive = #"{"type":"llm","instance_id":"\#(maximumID)","load_time_seconds":0,"status":"loaded","load_config":{"context_length":4194304,"future_provider_option":{"enabled":true}}}"#
        let receipt = try await Phase2NativeModelLifecycleHTTPClient(
            loader: LifecycleStubLoader { request in
                lifecycleResponse(finalURL: request.url!, chunks: [Data(additive.utf8)])
            }
        ).perform(.load(modelKey: "model-a", contextLength: 4_194_304), at: endpoint())
        guard case let .loaded(result) = receipt else { return XCTFail("expected load") }
        XCTAssertEqual(result.instanceID, maximumID)
        XCTAssertEqual(result.configuration.contextLength, 4_194_304)

        let oversizedID = String(repeating: "i", count: 513)
        let invalid = #"{"type":"llm","instance_id":"\#(oversizedID)","load_time_seconds":0,"status":"loaded","load_config":{"context_length":4096}}"#
        await assertLifecycleError(.reconciliationRequired) {
            _ = try await Phase2NativeModelLifecycleHTTPClient(
                loader: LifecycleStubLoader { request in
                    lifecycleResponse(finalURL: request.url!, chunks: [Data(invalid.utf8)])
                }
            ).perform(.load(modelKey: "model-a", contextLength: 4_096), at: self.endpoint())
        }
    }

    func testExactlyOneInvocationAndEveryTerminalResponseIsCancelledExactlyOnce() async throws {
        let invocations = LifecycleInvocationCounter()
        let cancellations = LifecycleCancellationCounter()
        let client = Phase2NativeModelLifecycleHTTPClient(loader: LifecycleStubLoader { request in
            invocations.record(request)
            return lifecycleResponse(
                finalURL: request.url!,
                cancel: { cancellations.cancel() },
                chunks: [Data(validLoadResponse.utf8)]
            )
        })

        _ = try await client.perform(.load(modelKey: "model-a", contextLength: 4_096), at: endpoint())
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(cancellations.count, 1)
    }

    func testCancellationBeforeDispatchProvesLoaderWasNotInvoked() async {
        let gate = LifecycleAsyncGate()
        let invocations = LifecycleInvocationCounter()
        let client = Phase2NativeModelLifecycleHTTPClient(loader: LifecycleStubLoader { request in
            invocations.record(request)
            return lifecycleResponse(finalURL: request.url!, chunks: [Data(validLoadResponse.utf8)])
        })
        let endpoint = endpoint()
        let task = Task {
            await gate.wait()
            return try await client.perform(
                .load(modelKey: "model-a", contextLength: 4_096),
                at: endpoint
            )
        }
        task.cancel()
        gate.open()

        do {
            _ = try await task.value
            XCTFail("expected cancellation before dispatch")
        } catch {
            XCTAssertEqual(error as? Phase2NativeModelLifecycleHTTPClientError, .cancelledBeforeDispatch)
        }
        XCTAssertEqual(invocations.count, 0)
    }

    func testCancellationAfterDispatchRequiresReconciliationCancelsOnceAndNeverRetries() async {
        let dispatched = expectation(description: "mutation loader invoked")
        let invocations = LifecycleInvocationCounter()
        let cancellations = LifecycleCancellationCounter()
        let body = AsyncThrowingStream<Data, Error> { _ in }
        let client = Phase2NativeModelLifecycleHTTPClient(loader: LifecycleStubLoader { request in
            invocations.record(request)
            dispatched.fulfill()
            return Phase2OpenAIChatHTTPResponse(
                statusCode: 200,
                contentType: "application/json",
                finalURL: request.url!,
                body: body,
                cancel: { cancellations.cancel() }
            )
        })
        let endpoint = endpoint()
        let task = Task {
            try await client.perform(.load(modelKey: "model-a", contextLength: 4_096), at: endpoint)
        }
        await fulfillment(of: [dispatched], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected reconciliation requirement")
        } catch {
            XCTAssertEqual(error as? Phase2NativeModelLifecycleHTTPClientError, .reconciliationRequired)
        }
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(cancellations.count, 1)
    }

    func testProductionLoaderAndSessionUseLifecycleBudgetAndDisableAmbientState() {
        let loader = Phase2NativeModelLifecycleHTTPClient.makeProductionLoader(
            requestTimeout: 3,
            resourceTimeout: 9,
            responseByteLimit: 65_536
        )
        XCTAssertEqual(loader.maximumProducedResponseBytes, 65_536)

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
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    private func endpoint() -> Phase2LoopbackEndpoint {
        try! Phase2LoopbackEndpoint(validating: "http://127.0.0.1:1234")
    }

    private func assertLifecycleError(
        _ expected: Phase2NativeModelLifecycleHTTPClientError,
        operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? Phase2NativeModelLifecycleHTTPClientError, expected)
            XCTAssertFalse(String(describing: error).contains("BEARER_SECRET"))
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
        }
    }
}

private struct LifecycleStubLoader: Phase2OpenAIChatURLLoading {
    let handler: @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse

    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        try await handler(request)
    }
}

private struct LifecycleSecretError: Error, @unchecked Sendable {
    let payload: String
}

private final class LifecycleInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var count: Int {
        lock.withLock { requests.count }
    }

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class LifecycleCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func cancel() {
        lock.withLock { value += 1 }
    }
}

private final class LifecycleAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private func lifecycleResponse(
    status: Int = 200,
    contentType: String = "application/json",
    finalURL: URL = URL(string: "http://127.0.0.1:1234/api/v1/models/load")!,
    cancel: @escaping @Sendable () -> Void = {},
    chunks: [Data]
) -> Phase2OpenAIChatHTTPResponse {
    Phase2OpenAIChatHTTPResponse(
        statusCode: status,
        contentType: contentType,
        finalURL: finalURL,
        body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        },
        cancel: cancel
    )
}

private let validLoadResponse = #"{"type":"llm","instance_id":"instance-a","load_time_seconds":1.25,"status":"loaded","load_config":{"context_length":8192,"eval_batch_size":256,"flash_attention":true,"num_experts":4,"offload_kv_cache_to_gpu":false}}"#

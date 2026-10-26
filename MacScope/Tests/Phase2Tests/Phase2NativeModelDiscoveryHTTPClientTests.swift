import Foundation
import XCTest

@testable import MacScope

final class Phase2NativeModelDiscoveryHTTPClientTests: XCTestCase {
    func testGetsExactNativeCatalogAndReturnsNormalizedDecoderResult() async throws {
        let cancellation = DiscoveryCancellationCounter()
        let loader = DiscoveryStubLoader { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/api/v1/models")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            return discoveryResponse(
                contentType: "application/json; charset=utf-8",
                cancel: { cancellation.cancel() },
                chunks: [Data(validDiscoveryCatalog.utf8)]
            )
        }

        let catalog = try await Phase2NativeModelDiscoveryHTTPClient(loader: loader).discover(
            at: try Phase2LoopbackEndpoint(validating: "http://127.0.0.1:1234")
        )

        XCTAssertEqual(catalog.models.map(\.key), ["model-a"])
        XCTAssertEqual(cancellation.count, 1)
    }

    func testRejectsRedirectStatusMediaTypeAndDecodeFailureWithStableErrors() async throws {
        let secret = "BEARER_SECRET_/Users/private"
        let changedURL = URL(string: "http://127.0.0.1:1234/elsewhere")!
        let cases: [(Phase2OpenAIChatHTTPResponse, Phase2NativeModelDiscoveryHTTPClientError)] = [
            (discoveryResponse(status: 302, chunks: [Data(secret.utf8)]), .redirectRejected),
            (discoveryResponse(finalURL: changedURL, chunks: []), .redirectRejected),
            (discoveryResponse(status: 401, chunks: [Data(secret.utf8)]), .authRequired),
            (discoveryResponse(status: 403, chunks: [Data(secret.utf8)]), .authRequired),
            (discoveryResponse(status: 503, chunks: [Data(secret.utf8)]), .unavailable),
            (discoveryResponse(contentType: "text/plain", chunks: [Data(secret.utf8)]), .incompatible),
            (discoveryResponse(chunks: [Data(#"{"models":{}}"#.utf8)]), .incompatible),
        ]

        for (response, expected) in cases {
            await assertDiscoveryError(expected) {
                _ = try await Phase2NativeModelDiscoveryHTTPClient(
                    loader: DiscoveryStubLoader { _ in response }
                ).discover(at: self.endpoint())
            }
        }

        await assertDiscoveryError(.unavailable) {
            _ = try await Phase2NativeModelDiscoveryHTTPClient(
                loader: DiscoveryStubLoader { _ in throw DiscoverySecretError(payload: secret) }
            ).discover(at: self.endpoint())
        }
    }

    func testRejectsContentTypeContainingHeaderLineBreaks() async {
        await assertDiscoveryError(.incompatible) {
            _ = try await Phase2NativeModelDiscoveryHTTPClient(
                loader: DiscoveryStubLoader { _ in
                    discoveryResponse(
                        contentType: "application/json; charset=utf-8\r\nX-Artifact: secret",
                        chunks: [Data(validDiscoveryCatalog.utf8)]
                    )
                }
            ).discover(at: self.endpoint())
        }
    }

    func testRejectsMaximumPlusOneBeforeAccumulatingMoreData() async {
        let client = Phase2NativeModelDiscoveryHTTPClient(loader: DiscoveryStubLoader { _ in
            discoveryResponse(chunks: [
                Data(repeating: 0x20, count: 2 * 1_024 * 1_024),
                Data([0x20]),
            ])
        })

        await assertDiscoveryError(.responseLimitExceeded) {
            _ = try await client.discover(at: self.endpoint())
        }
    }

    func testMapsProducerSideResponseLimitWithoutDowngradingItToUnavailable() async {
        let client = Phase2NativeModelDiscoveryHTTPClient(loader: DiscoveryStubLoader { _ in
            throw Phase2OpenAIChatHTTPClientError.responseLimitExceeded
        })

        await assertDiscoveryError(.responseLimitExceeded) {
            _ = try await client.discover(at: self.endpoint())
        }
    }

    func testProductionLoaderUsesTheExactDiscoveryConsumerBudget() {
        let loader = Phase2NativeModelDiscoveryHTTPClient.makeProductionLoader(
            requestTimeout: 5,
            resourceTimeout: 15,
            responseByteLimit: 2 * 1_024 * 1_024
        )

        XCTAssertEqual(loader.maximumProducedResponseBytes, 2 * 1_024 * 1_024)
    }

    func testCancellationCancelsResponseExactlyOnce() async throws {
        let loaded = expectation(description: "response loaded")
        let counter = DiscoveryCancellationCounter()
        let body = AsyncThrowingStream<Data, Error> { _ in }
        let client = Phase2NativeModelDiscoveryHTTPClient(loader: DiscoveryStubLoader { _ in
            loaded.fulfill()
            return Phase2OpenAIChatHTTPResponse(
                statusCode: 200,
                contentType: "application/json",
                finalURL: URL(string: "http://127.0.0.1:1234/api/v1/models")!,
                body: body,
                cancel: { counter.cancel() }
            )
        })

        let endpoint = endpoint()
        let task = Task { try await client.discover(at: endpoint) }
        await fulfillment(of: [loaded], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? Phase2NativeModelDiscoveryHTTPClientError, .cancelled)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testEveryTerminalPathCancelsResponseExactlyOnce() async {
        let counter = DiscoveryCancellationCounter()
        await assertDiscoveryError(.unavailable) {
            _ = try await Phase2NativeModelDiscoveryHTTPClient(
                loader: DiscoveryStubLoader { _ in
                    discoveryResponse(status: 500, cancel: { counter.cancel() }, chunks: [])
                }
            ).discover(at: self.endpoint())
        }
        XCTAssertEqual(counter.count, 1)
    }

    private func endpoint() -> Phase2LoopbackEndpoint {
        try! Phase2LoopbackEndpoint(validating: "http://127.0.0.1:1234")
    }

    private func assertDiscoveryError(
        _ expected: Phase2NativeModelDiscoveryHTTPClientError,
        operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? Phase2NativeModelDiscoveryHTTPClientError, expected)
            XCTAssertFalse(String(describing: error).contains("BEARER_SECRET"))
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
        }
    }
}

private struct DiscoveryStubLoader: Phase2OpenAIChatURLLoading {
    let handler: @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse

    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        try await handler(request)
    }
}

private struct DiscoverySecretError: Error, @unchecked Sendable {
    let payload: String
}

private final class DiscoveryCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private func discoveryResponse(
    status: Int = 200,
    contentType: String = "application/json",
    finalURL: URL = URL(string: "http://127.0.0.1:1234/api/v1/models")!,
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

private let validDiscoveryCatalog = #"{"models":[{"type":"llm","publisher":"publisher","key":"model-a","display_name":"Model A","quantization":null,"size_bytes":1,"params_string":null,"loaded_instances":[],"max_context_length":4096,"format":"gguf"}]}"#

import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

enum Phase2NativeModelDiscoveryHTTPClientError: Error, Equatable, Sendable {
    case invalidRequest
    case redirectRejected
    case authRequired
    case unavailable
    case incompatible
    case responseLimitExceeded
    case cancelled
}

struct Phase2NativeModelDiscoveryHTTPClient: Sendable {
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    private let load: @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse
    private let decoder: Phase2NativeModelCatalogDecoder
    private let responseByteLimit: Int
    private let requestTimeout: TimeInterval

    init<Loader: Phase2OpenAIChatURLLoading>(
        loader: Loader,
        decoder: Phase2NativeModelCatalogDecoder = .init(),
        responseByteLimit: Int = Self.maximumResponseBytes,
        requestTimeout: TimeInterval = 5
    ) {
        precondition(responseByteLimit > 0 && responseByteLimit <= Self.maximumResponseBytes)
        precondition(requestTimeout > 0)
        load = { request in try await loader.load(request) }
        self.decoder = decoder
        self.responseByteLimit = responseByteLimit
        self.requestTimeout = requestTimeout
    }

    init(
        decoder: Phase2NativeModelCatalogDecoder = .init(),
        responseByteLimit: Int = Self.maximumResponseBytes,
        requestTimeout: TimeInterval = 5,
        resourceTimeout: TimeInterval = 15
    ) {
        precondition(resourceTimeout >= requestTimeout)
        self.init(
            loader: Self.makeProductionLoader(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout,
                responseByteLimit: responseByteLimit
            ),
            decoder: decoder,
            responseByteLimit: responseByteLimit,
            requestTimeout: requestTimeout
        )
    }

    static func makeProductionLoader(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        responseByteLimit: Int
    ) -> Phase2OpenAIChatURLSessionLoader {
        Phase2OpenAIChatURLSessionLoader(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            maximumProducedResponseBytes: responseByteLimit
        )
    }

    func discover(at endpoint: Phase2LoopbackEndpoint,
                  provider: Phase2LocalAIProviderKind = .lmStudio) async throws -> Phase2NativeModelCatalog {
        if provider == .mtplx {
            let health = try await fetch(at: endpoint, path: "/health")
            let models = try await fetch(at: endpoint, path: "/v1/models")
            do {
                return try Phase2MTPLXModelCatalogDecoder().decode(health: health, models: models)
            } catch { throw Phase2NativeModelDiscoveryHTTPClientError.incompatible }
        }
        let body = try await fetch(at: endpoint, path: "/api/v1/models")
        do { return try decoder.decode(body) }
        catch { throw Phase2NativeModelDiscoveryHTTPClientError.incompatible }
    }

    private func fetch(at endpoint: Phase2LoopbackEndpoint, path: String) async throws -> Data {
        guard !Task.isCancelled,
              let url = URL(string: endpoint.origin.absoluteString + path)
        else {
            throw Task.isCancelled
                ? Phase2NativeModelDiscoveryHTTPClientError.cancelled
                : Phase2NativeModelDiscoveryHTTPClientError.invalidRequest
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let response: Phase2OpenAIChatHTTPResponse
        do {
            response = try await load(request)
        } catch is CancellationError {
            throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
        } catch Phase2OpenAIChatHTTPClientError.cancelled {
            throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
        } catch Phase2OpenAIChatHTTPClientError.responseLimitExceeded {
            throw Phase2NativeModelDiscoveryHTTPClientError.responseLimitExceeded
        } catch {
            guard !Task.isCancelled else {
                throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
            }
            throw Phase2NativeModelDiscoveryHTTPClientError.unavailable
        }

        let cancellation = Phase2NativeModelDiscoveryResponseCancellation(response.cancel)
        defer { cancellation.cancel() }

        guard !Task.isCancelled else {
            throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
        }
        guard response.finalURL == url, !(300...399).contains(response.statusCode) else {
            throw Phase2NativeModelDiscoveryHTTPClientError.redirectRejected
        }
        guard response.statusCode != 401, response.statusCode != 403 else {
            throw Phase2NativeModelDiscoveryHTTPClientError.authRequired
        }
        guard response.statusCode == 200 else {
            throw Phase2NativeModelDiscoveryHTTPClientError.unavailable
        }

        guard let contentType = response.contentType,
              !contentType.utf8.contains(0x0D),
              !contentType.utf8.contains(0x0A)
        else {
            throw Phase2NativeModelDiscoveryHTTPClientError.incompatible
        }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            throw Phase2NativeModelDiscoveryHTTPClientError.incompatible
        }

        var body = Data()
        body.reserveCapacity(min(responseByteLimit, 64 * 1_024))
        do {
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard chunk.count <= responseByteLimit - body.count else {
                    throw Phase2NativeModelDiscoveryHTTPClientError.responseLimitExceeded
                }
                body.append(chunk)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
        } catch Phase2OpenAIChatHTTPClientError.cancelled {
            throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
        } catch let error as Phase2NativeModelDiscoveryHTTPClientError {
            throw error
        } catch {
            guard !Task.isCancelled else {
                throw Phase2NativeModelDiscoveryHTTPClientError.cancelled
            }
            throw Phase2NativeModelDiscoveryHTTPClientError.unavailable
        }

        do {
            return body
        } catch {
            throw Phase2NativeModelDiscoveryHTTPClientError.incompatible
        }
    }
}

private final class Phase2NativeModelDiscoveryResponseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?

    init(_ operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func cancel() {
        lock.lock()
        let operation = operation
        self.operation = nil
        lock.unlock()
        operation?()
    }
}

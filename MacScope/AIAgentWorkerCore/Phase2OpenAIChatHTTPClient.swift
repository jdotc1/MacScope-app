import CFNetwork
import Foundation
import OSLog
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

struct Phase2OpenAIChatHTTPInput: Sendable {
    let endpoint: Phase2LoopbackEndpoint
    let model: String
    let systemPrompt: String
    let userPrompt: String
    let maximumTokens: Int
    let phase: Phase2OpenAIProductionChatPhase
    let generationVariant: Phase2OpenAIRequestGenerationVariant
    let acceptsFinalizationProposalTools: Bool
    let conversationContext: Phase2ProductionConversationContext?
    let inferencePolicy: Phase2LocalInferencePolicy?

    init(
        endpoint: Phase2LoopbackEndpoint,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maximumTokens: Int,
        phase: Phase2OpenAIProductionChatPhase,
        generationVariant: Phase2OpenAIRequestGenerationVariant,
        acceptsFinalizationProposalTools: Bool = false,
        conversationContext: Phase2ProductionConversationContext? = nil,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maximumTokens = maximumTokens
        self.phase = phase
        self.generationVariant = generationVariant
        self.acceptsFinalizationProposalTools = acceptsFinalizationProposalTools
        self.conversationContext = conversationContext
        self.inferencePolicy = inferencePolicy
    }
}

struct Phase2OpenAIChatHTTPClientLimits: Equatable, Sendable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let maximumResponseBytes: Int

    init(
        requestTimeout: TimeInterval = 120,
        resourceTimeout: TimeInterval = 900,
        maximumResponseBytes: Int = 8_388_608
    ) {
        precondition(requestTimeout > 0)
        precondition(resourceTimeout >= requestTimeout)
        precondition(maximumResponseBytes >= 0)
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

enum Phase2OpenAIChatHTTPClientError: Error, Equatable, Sendable {
    case invalidRequest
    case redirectRejected
    case invalidStatus
    case invalidContentType
    case responseLimitExceeded
    case transportFailed
    case invalidStream
    /// A well-framed provider error envelope, never its private payload.
    case providerError
    case cancelled
    case totalDeadlineExceeded
    case inactivityTimeout
    case outputLimitExceeded
}

struct Phase2OpenAIChatConnectionReceipt: Equatable, Sendable {
    let localAddress: String
    let localPort: Int
    let remoteAddress: String
    let remotePort: Int
}

struct Phase2OpenAIChatHTTPResponse: Sendable {
    let statusCode: Int
    let contentType: String?
    let finalURL: URL?
    let body: AsyncThrowingStream<Data, Error>
    let connectionReceipt: @Sendable () async throws -> Phase2OpenAIChatConnectionReceipt
    let cancel: @Sendable () -> Void

    init(
        statusCode: Int,
        contentType: String?,
        finalURL: URL?,
        body: AsyncThrowingStream<Data, Error>,
        connectionReceipt: @escaping @Sendable () async throws
            -> Phase2OpenAIChatConnectionReceipt = {
                throw Phase2OpenAIChatHTTPClientError.transportFailed
            },
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.finalURL = finalURL
        self.body = body
        self.connectionReceipt = connectionReceipt
        self.cancel = cancel
    }
}

protocol Phase2OpenAIChatURLLoading: Sendable {
    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse
}

struct Phase2OpenAIChatHTTPClient: Sendable {
    private static let failureLogger = Logger(subsystem: "org.macscope.MacScope", category: "AIWorkerHTTP")
    private let load: @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse
    private let limits: Phase2OpenAIChatHTTPClientLimits
    private let requestEncoder: Phase2OpenAIChatRequestEncoder

    init<Loader: Phase2OpenAIChatURLLoading>(
        loader: Loader,
        limits: Phase2OpenAIChatHTTPClientLimits = .init(),
        requestEncoder: Phase2OpenAIChatRequestEncoder = .init()
    ) {
        load = { request in try await loader.load(request) }
        self.limits = limits
        self.requestEncoder = requestEncoder
    }

    func execute(
        _ input: Phase2OpenAIChatHTTPInput,
        onEvent: @escaping @Sendable (Phase2OpenAIChatStreamEvent) async -> Void,
        onProviderDispatch: (@Sendable () async throws -> Void)? = nil,
        onConnectionReceipt: (@Sendable (Phase2OpenAIChatConnectionReceipt) async throws
            -> Void)? = nil,
        preparedRequestBody: Data? = nil
    ) async throws {
        guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }
        let progress = Phase2HTTPModelProgress()
        let totalDeadline = ContinuousClock.now.advanced(by: .seconds(limits.resourceTimeout))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await executeStream(input, preparedRequestBody: preparedRequestBody, progress: progress, onEvent: onEvent,
                        onProviderDispatch: onProviderDispatch, onConnectionReceipt: onConnectionReceipt)
                }
                group.addTask {
                    let clock = ContinuousClock()
                    while true {
                        try Task.checkCancellation()
                        let remainingTotal = clock.now.duration(to: totalDeadline)
                        guard remainingTotal > .zero else {
                            throw Phase2OpenAIChatHTTPClientError.totalDeadlineExceeded
                        }
                        if input.inferencePolicy != nil {
                            let lastProgress = await progress.lastProgress
                            let remainingActivity = clock.now.duration(to:
                                lastProgress.advanced(by: .seconds(limits.requestTimeout)))
                            guard remainingActivity > .zero else {
                                throw Phase2OpenAIChatHTTPClientError.inactivityTimeout
                            }
                            try await clock.sleep(for: min(remainingTotal, remainingActivity))
                        } else {
                            try await clock.sleep(for: remainingTotal)
                        }
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch is CancellationError {
            throw Phase2OpenAIChatHTTPClientError.cancelled
        }
    }

    private func executeStream(
        _ input: Phase2OpenAIChatHTTPInput,
        preparedRequestBody: Data? = nil,
        progress: Phase2HTTPModelProgress,
        onEvent: @escaping @Sendable (Phase2OpenAIChatStreamEvent) async -> Void,
        onProviderDispatch: (@Sendable () async throws -> Void)?,
        onConnectionReceipt: (@Sendable (Phase2OpenAIChatConnectionReceipt) async throws -> Void)?
    ) async throws {
        guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }

        let body: Data
        let toolSelectionFunctionHandles: [String: Set<UUID>]?
        do {
            if let preparedRequestBody {
                // Reconstruction owns its schema and prompt; reuse this exact transport, SSE,
                // cancellation, model binding, inactivity, and overall deadline lifecycle.
                guard let policy = input.inferencePolicy,
                      input.phase == .finalization, !input.acceptsFinalizationProposalTools,
                      preparedRequestBody.count <= Phase2ProductionPromptLimits.maximumEncodedRequestBodyBytes,
                      let object = try JSONSerialization.jsonObject(with: preparedRequestBody) as? [String: Any],
                      object["model"] as? String == input.model,
                      object["max_tokens"] as? Int == input.maximumTokens,
                      object["stream"] as? Bool == true,
                      object["enable_thinking"] as? Bool
                        == policy.sampling.map({ _ in policy.enableThinking }),
                      object["chat_template_kwargs"] == nil,
                      object["reasoning_effort"] as? String
                        == policy.sampling.map({ _ in policy.reasoningEffort.rawValue }),
                      object["generation_mode"] as? String == "mtp"
                else { throw Phase2OpenAIChatHTTPClientError.invalidRequest }
                try Phase2OpenAIChatRequestEncoder.admitContext(
                    body: object, policy: policy, maximumTokens: input.maximumTokens)
                body = preparedRequestBody
                toolSelectionFunctionHandles = nil
            } else {
                body = try requestEncoder.encodeProduction(.init(
                    model: input.model,
                    systemPrompt: input.systemPrompt,
                    userPrompt: input.userPrompt,
                    maximumTokens: input.maximumTokens,
                    phase: input.phase,
                    generationVariant: input.generationVariant,
                    allowsFinalizationProposalTools: input.acceptsFinalizationProposalTools,
                    conversationContext: input.conversationContext,
                    inferencePolicy: input.inferencePolicy
                ))
                switch input.phase {
                case .finalization, .shellContinuation:
                    toolSelectionFunctionHandles = nil
                case .toolSelection(let handles):
                    let version: Phase2ProductionToolRegistry.Version = handles.contains {
                        $0.operationID.hasPrefix("debugger.") || $0.operationID.hasPrefix("rea.")
                    } ? .assistantR2 : .qualificationR1
                    let projected = try Phase2ProductionToolRegistry(version: version).project(handles)
                    toolSelectionFunctionHandles = Dictionary(
                        uniqueKeysWithValues: projected.map { ($0.functionName, Set($0.acceptedHandleIDs)) }
                    )
                }
            }
        } catch let error as Phase2OpenAIChatRequestEncodingError {
            if case .contextBudgetExceeded = error { throw error }
            throw Phase2OpenAIChatHTTPClientError.invalidRequest
        } catch {
            throw Phase2OpenAIChatHTTPClientError.invalidRequest
        }

        let endpoint = input.endpoint.origin.absoluteString
        guard let url = URL(string: endpoint + "/v1/chat/completions") else {
            throw Phase2OpenAIChatHTTPClientError.invalidRequest
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: limits.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let response: Phase2OpenAIChatHTTPResponse
        do {
            response = try await load(request)
        } catch is CancellationError {
            throw Phase2OpenAIChatHTTPClientError.cancelled
        } catch let error as Phase2OpenAIChatHTTPClientError {
            throw error
        } catch {
            guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }
            if let urlError = error as? URLError, urlError.code == .timedOut,
               input.inferencePolicy != nil {
                throw Phase2OpenAIChatHTTPClientError.inactivityTimeout
            }
            throw Phase2OpenAIChatHTTPClientError.transportFailed
        }
        defer { response.cancel() }

        guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }
        guard response.finalURL == url else {
            throw Phase2OpenAIChatHTTPClientError.redirectRejected
        }
        guard !(300...399).contains(response.statusCode) else {
            throw Phase2OpenAIChatHTTPClientError.redirectRejected
        }
        guard response.statusCode == 200 else {
            throw Phase2OpenAIChatHTTPClientError.invalidStatus
        }
        guard Self.response(response, hasMediaType: "text/event-stream") else {
            throw Phase2OpenAIChatHTTPClientError.invalidContentType
        }
        guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }
        try await onProviderDispatch?()
        guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }

        let sseLimits = input.inferencePolicy?.provider == .mtplx
            ? Phase2OpenAIChatStreamDecoder.mtplxProductionSSELimits
            : Phase2OpenAIChatStreamDecoder.productionSSELimits
        var decoder = if input.phase == .shellContinuation {
            Phase2OpenAIChatStreamDecoder(
                expectedModel: input.model,
                acceptsInlineFinishUsage: input.inferencePolicy?.provider == .mtplx,
                shellContinuation: true,
                sseLimits: sseLimits
            )
        } else if let toolSelectionFunctionHandles {
            Phase2OpenAIChatStreamDecoder(
                expectedModel: input.model,
                acceptsInlineFinishUsage: input.inferencePolicy?.provider == .mtplx,
                toolSelectionAllowedHandles: toolSelectionFunctionHandles,
                acceptsMTPLXToolSelectionPreamble: input.inferencePolicy?.provider == .mtplx,
                sseLimits: sseLimits
            )
        } else {
            Phase2OpenAIChatStreamDecoder(
                expectedModel: input.model,
                acceptsInlineFinishUsage: input.inferencePolicy?.provider == .mtplx,
                acceptsShellProposalTool: input.acceptsFinalizationProposalTools,
                sseLimits: sseLimits
            )
        }
        var receivedBytes = 0
        do {
            for try await chunk in response.body {
                guard !Task.isCancelled else { throw CancellationError() }
                guard chunk.count <= limits.maximumResponseBytes - receivedBytes else {
                    throw Phase2OpenAIChatHTTPClientError.responseLimitExceeded
                }
                receivedBytes += chunk.count
                let previousProgress = decoder.modelProgressRevision
                let events = try decoder.append(chunk)
                if decoder.modelProgressRevision != previousProgress {
                    await progress.recordProgress()
                }
                for event in events {
                    try Task.checkCancellation()
                    await onEvent(event)
                }
            }
            try Task.checkCancellation()
            for event in try decoder.finish() {
                try Task.checkCancellation()
                await onEvent(event)
            }
            try Task.checkCancellation()
            if let onConnectionReceipt {
                let receipt = try await response.connectionReceipt()
                try Task.checkCancellation()
                guard Self.connectionReceipt(receipt, matches: input.endpoint) else {
                    throw Phase2OpenAIChatHTTPClientError.transportFailed
                }
                try await onConnectionReceipt(receipt)
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            throw Phase2OpenAIChatHTTPClientError.cancelled
        } catch let error as Phase2OpenAIChatHTTPClientError {
            throw error
        } catch Phase2OpenAIChatStreamError.outputLimitExceeded {
            throw Phase2OpenAIChatHTTPClientError.outputLimitExceeded
        } catch Phase2OpenAIChatStreamError.providerError {
            // A provider refusal is not malformed model output. Preserve the closed,
            // payload-free category through the HTTP boundary; the worker's existing
            // failed terminal remains retryable without expanding the wire schema.
            Self.failureLogger.error("MacScopeAIStream failure category=providerError")
            throw Phase2OpenAIChatHTTPClientError.providerError
        } catch let error as Phase2OpenAIChatStreamError {
            // This closed enum has no payloads; the log identifies framing/envelope errors
            // without recording any model reasoning, final text, metadata, or evidence.
            Self.failureLogger.error("MacScopeAIStream failure category=\(String(describing: error), privacy: .public)")
            throw Phase2OpenAIChatHTTPClientError.invalidStream
        } catch {
            guard !Task.isCancelled else { throw Phase2OpenAIChatHTTPClientError.cancelled }
            if let urlError = error as? URLError, urlError.code == .timedOut,
               input.inferencePolicy != nil {
                throw Phase2OpenAIChatHTTPClientError.inactivityTimeout
            }
            throw Phase2OpenAIChatHTTPClientError.invalidStream
        }
    }

    static func connectionReceipt(
        _ receipt: Phase2OpenAIChatConnectionReceipt,
        matches endpoint: Phase2LoopbackEndpoint
    ) -> Bool {
        guard receipt.localPort > 0,
              receipt.localPort <= Int(UInt16.max),
              receipt.remotePort == Int(endpoint.port)
        else { return false }
        switch endpoint.host {
        case .ipv4:
            return receipt.localAddress == "127.0.0.1"
                && receipt.remoteAddress == "127.0.0.1"
        case .ipv6:
            return receipt.localAddress == "::1"
                && receipt.remoteAddress == "::1"
        }
    }

    static func response(
        _ response: Phase2OpenAIChatHTTPResponse,
        hasMediaType expectedMediaType: String
    ) -> Bool {
        guard !expectedMediaType.isEmpty,
              let contentType = response.contentType,
              !contentType.utf8.contains(0x0D),
              !contentType.utf8.contains(0x0A),
              let mediaType = contentType
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else { return false }
        return mediaType == expectedMediaType.lowercased()
    }
}

struct Phase2OpenAIChatURLSessionLoader: Phase2OpenAIChatURLLoading, Sendable {
    static let defaultMaximumProducedResponseBytes = 8_388_608
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    let maximumProducedResponseBytes: Int

    init(
        requestTimeout: TimeInterval = 120,
        resourceTimeout: TimeInterval = 900,
        maximumProducedResponseBytes: Int = Self.defaultMaximumProducedResponseBytes
    ) {
        precondition(requestTimeout > 0)
        precondition(resourceTimeout >= requestTimeout)
        precondition(maximumProducedResponseBytes > 0)
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumProducedResponseBytes = maximumProducedResponseBytes
    }

    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        let delegate = Phase2OpenAIChatSessionDelegate()
        let session = URLSession(
            configuration: Self.makeSessionConfiguration(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            ),
            delegate: delegate,
            delegateQueue: nil
        )

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                session.invalidateAndCancel()
                throw Phase2OpenAIChatHTTPClientError.transportFailed
            }
            do {
                try Self.validateExpectedContentLength(
                    response.expectedContentLength,
                    maximumProducedResponseBytes: maximumProducedResponseBytes
                )
            } catch {
                session.invalidateAndCancel()
                throw error
            }
            let cancellation = Phase2HTTPBodyCancellation(session: session)
            let body = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    do {
                        var buffer = Data()
                        buffer.reserveCapacity(8_192)
                        var producedBytes = 0
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            guard producedBytes < maximumProducedResponseBytes else {
                                throw Phase2OpenAIChatHTTPClientError.responseLimitExceeded
                            }
                            producedBytes += 1
                            buffer.append(byte)
                            // Deliver SSE lines promptly instead of waiting for 8 KiB of
                            // generated output before publishing model progress.
                            if byte == 0x0A || buffer.count == 8_192 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                        session.invalidateAndCancel()
                    }
                }
                cancellation.install(task)
                continuation.onTermination = { @Sendable _ in
                    cancellation.cancel()
                }
            }
            return Phase2OpenAIChatHTTPResponse(
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                finalURL: http.url,
                body: body,
                connectionReceipt: { try await delegate.connectionReceipt() },
                cancel: { cancellation.cancel() }
            )
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    static func makeSessionConfiguration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: false,
        ]
        return configuration
    }

    static func validateExpectedContentLength(
        _ expectedContentLength: Int64,
        maximumProducedResponseBytes: Int
    ) throws {
        precondition(maximumProducedResponseBytes > 0)
        guard expectedContentLength == NSURLSessionTransferSizeUnknown
                || expectedContentLength <= Int64(maximumProducedResponseBytes)
        else {
            throw Phase2OpenAIChatHTTPClientError.responseLimitExceeded
        }
    }
}

private final class Phase2HTTPBodyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var isCancelled = false

    init(session: URLSession) { self.session = session }

    func install(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            if isCancelled { return true }
            self.task = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            isCancelled = true
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
        session.invalidateAndCancel()
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class Phase2OpenAIChatSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private enum MetricsResult {
        case pending
        case value(Result<Phase2OpenAIChatConnectionReceipt, Error>)
        case waiting(CheckedContinuation<Phase2OpenAIChatConnectionReceipt, Error>)
    }

    private let metricsLock = NSLock()
    private var metricsResult: MetricsResult = .pending

    func connectionReceipt() async throws -> Phase2OpenAIChatConnectionReceipt {
        try await withCheckedThrowingContinuation { continuation in
            let result = metricsLock.withLock { () -> Result<Phase2OpenAIChatConnectionReceipt, Error>? in
                switch metricsResult {
                case .pending:
                    metricsResult = .waiting(continuation)
                    return nil
                case .value(let result):
                    return result
                case .waiting:
                    return .failure(Phase2OpenAIChatHTTPClientError.transportFailed)
                }
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let result = Self.receipt(from: metrics)
        let continuation = metricsLock.withLock {
            () -> CheckedContinuation<Phase2OpenAIChatConnectionReceipt, Error>? in
            switch metricsResult {
            case .pending:
                metricsResult = .value(result)
                return nil
            case .waiting(let continuation):
                metricsResult = .value(result)
                return continuation
            case .value:
                metricsResult = .value(.failure(
                    Phase2OpenAIChatHTTPClientError.transportFailed
                ))
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    private static func receipt(
        from metrics: URLSessionTaskMetrics
    ) -> Result<Phase2OpenAIChatConnectionReceipt, Error> {
        guard metrics.redirectCount == 0,
              metrics.transactionMetrics.count == 1,
              let transaction = metrics.transactionMetrics.first,
              transaction.resourceFetchType == .networkLoad,
              !transaction.isProxyConnection,
              !transaction.isReusedConnection,
              let localAddress = transaction.localAddress,
              let localPort = transaction.localPort,
              let remoteAddress = transaction.remoteAddress,
              let remotePort = transaction.remotePort,
              (1...Int(UInt16.max)).contains(localPort),
              (1...Int(UInt16.max)).contains(remotePort)
        else {
            return .failure(Phase2OpenAIChatHTTPClientError.transportFailed)
        }
        return .success(.init(
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort
        ))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

/// Tracks only validated model deltas, never raw heartbeat or comment bytes.
private actor Phase2HTTPModelProgress {
    private(set) var lastProgress = ContinuousClock.now

    func recordProgress() { lastProgress = ContinuousClock.now }
}

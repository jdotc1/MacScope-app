import Foundation
import OSLog
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

enum Phase2ReconstructionAIWorkerHandlerError: Error, Equatable, Sendable {
    case protocolMismatch
    case unsupportedProvider
    case providerFailure
    case malformedProviderResponse
}

struct Phase2ReconstructionAIWorkerHandler: Sendable {
    typealias Execute = @Sendable (
        _ input: Phase2ReconstructionOpenAIChatInput,
        _ emit: @escaping @Sendable (Phase2ReconstructionChatStreamEvent) async -> Void
    ) async throws -> Void

    typealias EmitControl = @Sendable (Phase2AIWorkerWireEvent) async throws -> Void

    private typealias ExecuteWithProviderAuthority = @Sendable (
        _ input: Phase2ReconstructionOpenAIChatInput,
        _ emit: @escaping @Sendable (Phase2ReconstructionChatStreamEvent) async -> Void,
        _ onProviderDispatch: @escaping @Sendable () async throws -> Void,
        _ onConnectionReceipt: @escaping @Sendable (Phase2OpenAIChatConnectionReceipt)
            async throws -> Void
    ) async throws -> Void

    private let execute: ExecuteWithProviderAuthority
    private let requiresProviderAuthority: Bool

    typealias Load = @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse

    init(execute: @escaping Execute) {
        self.execute = { input, emit, _, _ in try await execute(input, emit) }
        requiresProviderAuthority = false
    }

    init(load: @escaping Load) {
        self.execute = { input, emit, onProviderDispatch, onConnectionReceipt in
            try await Self.executeLive(
                input: input,
                emit: emit,
                onProviderDispatch: onProviderDispatch,
                onConnectionReceipt: onConnectionReceipt,
                load: load
            )
        }
        requiresProviderAuthority = true
    }

    init() {
        self.execute = { input, emit, onProviderDispatch, onConnectionReceipt in
            let requestTimeout = TimeInterval(input.requestTimeoutMilliseconds) / 1_000
            let resourceTimeout = TimeInterval(input.resourceTimeoutMilliseconds) / 1_000
            let loader = Phase2OpenAIChatURLSessionLoader(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            )
            try await Self.executeLive(
                input: input,
                emit: emit,
                onProviderDispatch: onProviderDispatch,
                onConnectionReceipt: onConnectionReceipt,
                load: { request in try await loader.load(request) }
            )
        }
        requiresProviderAuthority = true
    }

    func run(
        requestID: UUID,
        request: ReconstructionAIWorkerRequest,
        configuration: Phase2AIWorkerConfigurationWire,
        emitControl: @escaping EmitControl,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws {
        do {
            try await runValidated(requestID: requestID, request: request,
                configuration: configuration, emitControl: emitControl, emit: emit)
        } catch {
            // Enum labels only: never log provider content, prompts, or source text.
            let reason: String
            if let failure = error as? Phase2ReconstructionRoundAccumulatorError {
                reason = "accumulator." + String(describing: failure)
            } else if let failure = error as? Phase2ReconstructionAIWorkerHandlerError {
                reason = "handler." + String(describing: failure)
            } else if error is CancellationError {
                reason = "cancelled"
            } else {
                reason = String(describing: type(of: error))
            }
            Logger(subsystem: "org.macscope.MacScope", category: "ReconstructionWorker")
                .error("Reconstruction worker rejected request: \(reason, privacy: .public)")
            throw error
        }
    }

    private func runValidated(
        requestID: UUID,
        request: ReconstructionAIWorkerRequest,
        configuration: Phase2AIWorkerConfigurationWire,
        emitControl: @escaping EmitControl,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws {
        guard configuration.inferencePolicy?.isValid == true else {
            throw Phase2ReconstructionAIWorkerHandlerError.unsupportedProvider
        }
        guard configuration.protocolManifestDigest
                == (try request.protocolBundle).manifestDigest
        else { throw Phase2ReconstructionAIWorkerHandlerError.protocolMismatch }

        let input = try Phase2ReconstructionOpenAIChatRequestEncoder().encode(
            request: request,
            configuration: configuration
        )
        let collector = Phase2ReconstructionProviderEventCollector(sourceBound: input.phase == .sourceRevision)
        let controlState = Phase2ReconstructionProviderControlEmissionState()
        let emitProviderDispatch: @Sendable () async throws -> Void = {
            guard await controlState.beginDispatch() else {
                throw Phase2ReconstructionAIWorkerHandlerError.providerFailure
            }
            try await emitControl(Self.controlEvent(
                requestID: requestID,
                body: .providerDispatch,
                sequence: UInt64.max - 1,
                bundle: (try request.protocolBundle)
            ))
            await controlState.finishDispatch()
        }
        let emitConnectionReceipt: @Sendable (Phase2OpenAIChatConnectionReceipt)
            async throws -> Void = { receipt in
                guard await controlState.beginConnection() else {
                    throw Phase2ReconstructionAIWorkerHandlerError.providerFailure
                }
                try await emitControl(Self.controlEvent(
                    requestID: requestID,
                    body: .providerConnection(.init(
                        localAddress: receipt.localAddress,
                        localPort: receipt.localPort,
                        remoteAddress: receipt.remoteAddress,
                        remotePort: receipt.remotePort
                    )),
                    sequence: UInt64.max,
                    bundle: (try request.protocolBundle)
                ))
                await controlState.finishConnection()
            }
        try await execute(
            input,
            { event in await collector.append(event) },
            emitProviderDispatch,
            emitConnectionReceipt
        )
        let didFinishProviderAuthority = await controlState.didFinishBoth
        guard !requiresProviderAuthority || didFinishProviderAuthority else {
            throw Phase2ReconstructionAIWorkerHandlerError.providerFailure
        }
        guard !(await collector.exceededBound) else { throw Phase2ReconstructionRoundAccumulatorError.outputTooLarge }
        let providerEvents = await collector.events
        var accumulator = Phase2ReconstructionRoundAccumulator()
        if input.phase != .sourceRevision {
            for providerEvent in providerEvents { try accumulator.consume(providerEvent) }
        }

        let authority: ReconstructionAIWorkerAuthority
        var bodies: [ReconstructionAIWorkerEventBody]
        switch request {
        case .sourceRevision(let source):
            authority = .sourceRevision(source)
            var sourceAccumulator = Phase2ReconstructionSourceAccumulator()
            for event in providerEvents { try sourceAccumulator.consume(event) }
            let (candidate, usage) = try sourceAccumulator.finish(for: source)
            bodies = [.sourceCandidate(candidate), .usage(usage), .completed]
        case .roundR2(let round):
            authority = .roundR2(round)
            let (candidate, usage) = try accumulator.finishRound()
            bodies = [.roundCandidate(candidate), .usage(usage), .completed]
        case .finalSynthesisR2(let final):
            authority = .finalSynthesisR2(final)
            let (candidate, usage) = try accumulator.finishFinal()
            bodies = [.finalCandidate(candidate), .usage(usage), .completed]
        case .round(let round):
            authority = .round(round)
            let (candidate, usage) = try accumulator.finishRound()
            bodies = [.roundCandidate(candidate), .usage(usage), .completed]
        case .finalSynthesis(let final):
            authority = .finalSynthesis(final)
            let (candidate, usage) = try accumulator.finishFinal()
            bodies = [.finalCandidate(candidate), .usage(usage), .completed]
        }

        let codec = Phase2ReconstructionAIWorkerWireCodec()
        for (index, body) in bodies.enumerated() {
            try Task.checkCancellation()
            let event = ReconstructionAIWorkerEvent(
                requestID: requestID,
                sequence: UInt64(index + 1),
                body: body
            )
            _ = try codec.encodeEvent(event, authority: authority)
            try await emit(event)
        }
    }

    private static func controlEvent(
        requestID: UUID,
        body: Phase2AIWorkerWireEventBody,
        sequence: UInt64,
        bundle: Phase2AIWorkerProductionProtocolBundle
    ) -> Phase2AIWorkerWireEvent {
        return .init(
            wireProtocol: bundle.wireIdentity,
            protocolVersion: bundle.inferenceVersion,
            phase: .finalization,
            sessionID: requestID,
            turnID: requestID,
            requestID: requestID,
            documentID: requestID,
            workspaceID: requestID,
            lifecycleRevision: 0,
            sequence: sequence,
            body: body
        )
    }

    private static func executeLive(
        input: Phase2ReconstructionOpenAIChatInput,
        emit: @escaping @Sendable (Phase2ReconstructionChatStreamEvent) async -> Void,
        onProviderDispatch: @escaping @Sendable () async throws -> Void,
        onConnectionReceipt: @escaping @Sendable (Phase2OpenAIChatConnectionReceipt)
            async throws -> Void,
        load: @escaping Load
    ) async throws {
        if let policy = input.inferencePolicy {
            let client = Phase2OpenAIChatHTTPClient(
                loader: ReconstructionPreparedBodyLoader(operation: load),
                limits: .init(requestTimeout: TimeInterval(input.requestTimeoutMilliseconds) / 1_000,
                              resourceTimeout: TimeInterval(input.resourceTimeoutMilliseconds) / 1_000)
            )
            do { try await client.execute(
                .init(endpoint: input.endpoint, model: input.model,
                      systemPrompt: input.systemPrompt, userPrompt: "Prepared reconstruction evidence",
                      maximumTokens: input.maximumTokens, phase: .finalization,
                      generationVariant: .assistantR4, inferencePolicy: policy),
                onEvent: { event in
                    switch event {
                    case .contentDelta(let value): await emit(.contentDelta(value))
                    case .usage(let usage): await emit(.usage(.init(
                        promptTokens: usage.promptTokens, completionTokens: usage.completionTokens,
                        totalTokens: usage.totalTokens)))
                    case .done: await emit(.done)
                    case .reasoningProgress, .finished: break
                    case .toolCall, .awaitingTools, .shellProposal, .debuggerActionProposal:
                        break // The shared finalization decoder rejects unsupported tool channels.
                    }
                },
                onProviderDispatch: onProviderDispatch, onConnectionReceipt: onConnectionReceipt,
                preparedRequestBody: input.requestBody
            ) } catch let error as Phase2OpenAIChatHTTPClientError {
                switch error {
                case .invalidStream, .invalidContentType, .responseLimitExceeded:
                    throw Phase2ReconstructionAIWorkerHandlerError.malformedProviderResponse
                case .redirectRejected, .invalidStatus, .transportFailed, .providerError:
                    throw Phase2ReconstructionAIWorkerHandlerError.providerFailure
                case .invalidRequest, .cancelled, .totalDeadlineExceeded, .inactivityTimeout, .outputLimitExceeded:
                    throw error
                }
            }
            return
        }
        throw Phase2ReconstructionAIWorkerHandlerError.unsupportedProvider

    }
}

private actor Phase2ReconstructionProviderControlEmissionState {
    private var beganDispatch = false
    private var finishedDispatch = false
    private var beganConnection = false
    private var finishedConnection = false

    var didFinishBoth: Bool { finishedDispatch && finishedConnection }

    func beginDispatch() -> Bool {
        guard !beganDispatch else { return false }
        beganDispatch = true
        return true
    }

    func finishDispatch() {
        guard beganDispatch else { return }
        finishedDispatch = true
    }

    func beginConnection() -> Bool {
        guard !beganConnection else { return false }
        beganConnection = true
        return true
    }

    func finishConnection() {
        guard beganConnection else { return }
        finishedConnection = true
    }
}

private actor Phase2ReconstructionProviderEventCollector {
    private(set) var events: [Phase2ReconstructionChatStreamEvent] = []
    private(set) var exceededBound = false
    private let sourceBound: Bool
    private var sourceBytes = 0
    init(sourceBound: Bool) { self.sourceBound = sourceBound }
    func append(_ event: Phase2ReconstructionChatStreamEvent) {
        guard !exceededBound else { return }
        if sourceBound {
            if case .contentDelta(let text) = event { sourceBytes += text.utf8.count }
            guard sourceBytes <= 524_288, events.count < 100_000 else { exceededBound = true; return }
        }
        events.append(event)
    }
}

private struct ReconstructionPreparedBodyLoader: Phase2OpenAIChatURLLoading {
    let operation: Phase2ReconstructionAIWorkerHandler.Load
    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        try await operation(request)
    }
}

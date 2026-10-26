import Foundation

enum AIAgentXPCModelDiscoveryServiceError: Error, Equatable, Sendable {
    case busy
}

actor AIAgentXPCModelDiscoveryService: Phase2LocalModelDiscovering {
    private let transport: any Phase2AIWorkerModelDiscoveryTransport
    private let codec: Phase2AIWorkerModelDiscoveryAppCodec
    private var activeRequestID: UUID?
    private var explicitlyCancelledRequestID: UUID?

    init(
        transport: any Phase2AIWorkerModelDiscoveryTransport =
            NSXPCAIWorkerModelDiscoveryTransport(),
        codec: Phase2AIWorkerModelDiscoveryAppCodec = .init()
    ) {
        self.transport = transport
        self.codec = codec
    }

    func discoverModels(
        endpoint: Phase2LocalProviderEndpoint
    ) async throws -> Phase2LocalModelDiscoveryOutcome {
        try await discoverModels(endpoint: endpoint, requestID: UUID())
    }

    func discoverModels(
        endpoint: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) async throws -> Phase2LocalModelDiscoveryOutcome {
        guard activeRequestID == nil else { throw AIAgentXPCModelDiscoveryServiceError.busy }
        activeRequestID = requestID
        let requestData: Data
        do {
            requestData = try codec.encodeRequest(endpoint: endpoint, requestID: requestID)
        } catch {
            activeRequestID = nil
            explicitlyCancelledRequestID = nil
            throw error
        }

        do {
            let replyData = try await withTaskCancellationHandler {
                try await transport.discover(requestData: requestData, requestID: requestID)
            } onCancel: { [transport] in
                Task { await transport.cancel(requestID: requestID) }
            }

            let outcome: Phase2LocalModelDiscoveryOutcome
            if Task.isCancelled || explicitlyCancelledRequestID == requestID
                || activeRequestID != requestID {
                outcome = .cancelled
            } else {
                outcome = try codec.decodeReply(
                    replyData,
                    expectedRequestID: requestID,
                    endpoint: endpoint
                )
            }
            await transport.reset()
            activeRequestID = nil
            explicitlyCancelledRequestID = nil
            return outcome
        } catch {
            let cancelled = Task.isCancelled || explicitlyCancelledRequestID == requestID
            await transport.reset()
            activeRequestID = nil
            explicitlyCancelledRequestID = nil
            if cancelled { return .cancelled }
            throw error
        }
    }

    func cancel(requestID: UUID) async {
        guard activeRequestID == requestID else { return }
        explicitlyCancelledRequestID = requestID
        await transport.cancel(requestID: requestID)
    }
}

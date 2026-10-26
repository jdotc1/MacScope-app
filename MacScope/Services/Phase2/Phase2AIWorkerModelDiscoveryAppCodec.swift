import Foundation

enum Phase2AIWorkerModelDiscoveryAppCodecError: Error, Equatable, Sendable {
    case identityMismatch
    case invalidInventory
}

/// App-owned translation between the strict discovery wire and one provider-neutral snapshot.
/// The app accepts a reply only when all lifecycle coordinates match the request it issued.
struct Phase2AIWorkerModelDiscoveryAppCodec: Sendable {
    private let wireCodec: Phase2AIWorkerModelDiscoveryWireCodec

    init(wireCodec: Phase2AIWorkerModelDiscoveryWireCodec = .init()) {
        self.wireCodec = wireCodec
    }

    func encodeRequest(
        endpoint: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) throws -> Data {
        try wireCodec.encodeRequest(.init(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: requestID,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            endpointOrigin: endpoint.endpointOrigin,
            requestTimeoutMilliseconds: endpoint.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: endpoint.resourceTimeoutMilliseconds,
                inferencePolicy: endpoint.inferencePolicy
        ))
    }

    func decodeReply(
        _ data: Data,
        expectedRequestID: UUID,
        endpoint: Phase2LocalProviderEndpoint
    ) throws -> Phase2LocalModelDiscoveryOutcome {
        let reply = try wireCodec.decodeReply(data)
        guard reply.requestID == expectedRequestID,
              reply.profileID == endpoint.profileID,
              reply.generation == endpoint.generation
        else { throw Phase2AIWorkerModelDiscoveryAppCodecError.identityMismatch }

        switch reply.status {
        case .success:
            guard let inventory = reply.inventory else {
                throw Phase2AIWorkerModelDiscoveryAppCodecError.invalidInventory
            }
            return .success(try makeInventory(inventory, endpoint: endpoint))
        case .authenticationRequired:
            return .authenticationRequired
        case .unavailable:
            return .unavailable
        case .incompatible:
            return .incompatible
        case .cancelled:
            return .cancelled
        }
    }

    private func makeInventory(
        _ wire: Phase2AIWorkerModelInventoryWire,
        endpoint: Phase2LocalProviderEndpoint
    ) throws -> Phase2LocalModelInventory {
        do {
            return try Phase2LocalModelInventory(
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                models: try wire.models.map(makeModel)
            )
        } catch {
            throw Phase2AIWorkerModelDiscoveryAppCodecError.invalidInventory
        }
    }

    private func makeModel(
        _ wire: Phase2AIWorkerModelWire
    ) throws -> Phase2LocalModelDescriptor {
        .init(
            type: wire.type == .llm ? .language : .embedding,
            publisher: wire.publisher,
            key: wire.key,
            displayName: wire.displayName,
            architecture: wire.architecture,
            quantization: wire.quantization.map {
                .init(name: $0.name, bitsPerWeight: $0.bitsPerWeight)
            },
            sizeBytesOnDisk: wire.sizeBytes,
            parameterCountDescription: wire.parameters,
            maximumContextLength: wire.maximumContextLength,
            format: wire.format.map { $0 == .gguf ? .gguf : .mlx },
            capabilities: try wire.capabilities.map(makeCapabilities),
            summary: wire.summary,
            variants: wire.variants,
            providerSelectedVariant: wire.selectedVariant,
            loadedInstances: wire.loadedInstances.map {
                .init(
                    id: $0.id,
                    configuration: .init(
                        effectiveContextLength: $0.configuration.contextLength,
                        evaluationBatchSize: $0.configuration.evaluationBatchSize,
                        parallelPredictions: $0.configuration.parallelPredictions,
                        flashAttention: $0.configuration.flashAttention,
                        expertCount: $0.configuration.expertCount,
                        offloadsKVCacheToGPU: $0.configuration.offloadsKVCacheToGPU
                    )
                )
            }
        )
    }

    private func makeCapabilities(
        _ wire: Phase2AIWorkerModelCapabilitiesWire
    ) throws -> Phase2LocalModelCapabilities {
        .init(
            supportsVision: wire.vision,
            trainedForToolUse: wire.trainedForToolUse,
            reasoning: try wire.reasoning.map(makeReasoning)
        )
    }

    private func makeReasoning(
        _ wire: Phase2AIWorkerModelReasoningWire
    ) throws -> Phase2LocalModelReasoningCapabilities {
        guard let defaultOption = Phase2LocalModelReasoningOption(
            rawValue: wire.defaultOption
        ) else {
            throw Phase2AIWorkerModelDiscoveryAppCodecError.invalidInventory
        }
        let allowedOptions = try wire.allowedOptions.map { value in
            guard let option = Phase2LocalModelReasoningOption(rawValue: value) else {
                throw Phase2AIWorkerModelDiscoveryAppCodecError.invalidInventory
            }
            return option
        }
        return .init(allowedOptions: allowedOptions, defaultOption: defaultOption)
    }
}

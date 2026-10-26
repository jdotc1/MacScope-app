import Foundation

enum Phase2LocalModelType: String, Hashable, Sendable {
    case language
    case embedding
}

enum Phase2LocalModelFormat: String, Hashable, Sendable {
    case gguf
    case mlx
}

enum Phase2LocalModelReasoningOption: String, Hashable, Sendable {
    case off
    case on
    case low
    case medium
    case high
}

struct Phase2LocalModelQuantization: Hashable, Sendable {
    let name: String?
    let bitsPerWeight: Double?
}

struct Phase2LocalModelReasoningCapabilities: Hashable, Sendable {
    let allowedOptions: [Phase2LocalModelReasoningOption]
    let defaultOption: Phase2LocalModelReasoningOption
}

struct Phase2LocalModelCapabilities: Hashable, Sendable {
    let supportsVision: Bool
    let trainedForToolUse: Bool
    let reasoning: Phase2LocalModelReasoningCapabilities?
}

struct Phase2LocalModelInstanceConfiguration: Hashable, Sendable {
    /// Context actually applied to this loaded instance, not the model's advertised maximum.
    let effectiveContextLength: Int
    let evaluationBatchSize: Int?
    let parallelPredictions: Int?
    let flashAttention: Bool?
    let expertCount: Int?
    let offloadsKVCacheToGPU: Bool?

    init(
        effectiveContextLength: Int,
        evaluationBatchSize: Int? = nil,
        parallelPredictions: Int? = nil,
        flashAttention: Bool? = nil,
        expertCount: Int? = nil,
        offloadsKVCacheToGPU: Bool? = nil
    ) {
        self.effectiveContextLength = effectiveContextLength
        self.evaluationBatchSize = evaluationBatchSize
        self.parallelPredictions = parallelPredictions
        self.flashAttention = flashAttention
        self.expertCount = expertCount
        self.offloadsKVCacheToGPU = offloadsKVCacheToGPU
    }
}

struct Phase2LocalModelLoadedInstance: Hashable, Sendable {
    /// Runtime instance identity. This is never interchangeable with the model key.
    let id: String
    let configuration: Phase2LocalModelInstanceConfiguration
}

struct Phase2LocalModelDescriptor: Hashable, Sendable {
    let type: Phase2LocalModelType
    let publisher: String
    /// Exact provider model identity used for later selection and inference configuration.
    let key: String
    let displayName: String
    let architecture: String?
    let quantization: Phase2LocalModelQuantization?
    /// Provider-reported bytes occupied by model files on disk. This is not memory usage.
    let sizeBytesOnDisk: UInt64
    let parameterCountDescription: String?
    /// Provider-reported model capability, distinct from every loaded instance's effective context.
    let maximumContextLength: Int
    let format: Phase2LocalModelFormat?
    let capabilities: Phase2LocalModelCapabilities?
    let summary: String?
    let variants: [String]
    /// Provider-observed variant state. This does not select a model for MacScope inference.
    let providerSelectedVariant: String?
    let loadedInstances: [Phase2LocalModelLoadedInstance]

    /// Technical candidate classification only. Model qualification and selection remain app-owned
    /// later decisions; embedding models can never enter the chat-inference path.
    var isInferenceCandidate: Bool { type == .language }

    init(
        type: Phase2LocalModelType,
        publisher: String,
        key: String,
        displayName: String,
        architecture: String?,
        quantization: Phase2LocalModelQuantization?,
        sizeBytesOnDisk: UInt64,
        parameterCountDescription: String?,
        maximumContextLength: Int,
        format: Phase2LocalModelFormat?,
        capabilities: Phase2LocalModelCapabilities?,
        summary: String? = nil,
        variants: [String],
        providerSelectedVariant: String?,
        loadedInstances: [Phase2LocalModelLoadedInstance]
    ) {
        self.type = type
        self.publisher = publisher
        self.key = key
        self.displayName = displayName
        self.architecture = architecture
        self.quantization = quantization
        self.sizeBytesOnDisk = sizeBytesOnDisk
        self.parameterCountDescription = parameterCountDescription
        self.maximumContextLength = maximumContextLength
        self.format = format
        self.capabilities = capabilities
        self.summary = summary
        self.variants = variants
        self.providerSelectedVariant = providerSelectedVariant
        self.loadedInstances = loadedInstances
    }

    fileprivate func replacingLoadedInstances(
        _ loadedInstances: [Phase2LocalModelLoadedInstance]
    ) -> Self {
        .init(
            type: type,
            publisher: publisher,
            key: key,
            displayName: displayName,
            architecture: architecture,
            quantization: quantization,
            sizeBytesOnDisk: sizeBytesOnDisk,
            parameterCountDescription: parameterCountDescription,
            maximumContextLength: maximumContextLength,
            format: format,
            capabilities: capabilities,
            summary: summary,
            variants: variants,
            providerSelectedVariant: providerSelectedVariant,
            loadedInstances: loadedInstances
        )
    }
}

/// One immutable, generation-qualified observation of the provider's complete model catalog.
/// Refresh replaces this value atomically; snapshots are never merged by display name.
struct Phase2LocalModelInventory: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidGeneration
        case duplicateModelKey(String)
        case duplicateLoadedInstanceID(String)
    }

    let profileID: UUID
    let generation: UInt64
    let models: [Phase2LocalModelDescriptor]

    init(
        profileID: UUID,
        generation: UInt64,
        models: [Phase2LocalModelDescriptor]
    ) throws {
        guard generation > 0 else { throw ValidationError.invalidGeneration }

        var modelKeys: Set<String> = []
        var instanceIDs: Set<String> = []
        for model in models {
            guard modelKeys.insert(model.key).inserted else {
                throw ValidationError.duplicateModelKey(model.key)
            }
            for instance in model.loadedInstances {
                guard instanceIDs.insert(instance.id).inserted else {
                    throw ValidationError.duplicateLoadedInstanceID(instance.id)
                }
            }
        }

        let sortedModels = models.map { model in
            model.replacingLoadedInstances(model.loadedInstances.sorted {
                unicodeScalarOrder($0.id, precedes: $1.id)
            })
        }.sorted {
            unicodeScalarOrder($0.key, precedes: $1.key)
        }

        self.profileID = profileID
        self.generation = generation
        self.models = sortedModels
    }
}

/// Durable identity for the stable semantic content of one observed model catalog.
///
/// Provider/controller revisions and loaded-instance identifiers are deliberately absent: both are
/// launch-local coordinates which the Reconstruction package contract forbids persisting. Loaded
/// configurations remain part of the identity, because they describe the model authority that was
/// actually available to the inference run.
enum Phase2LocalModelInventoryIdentity {
    static let schemaVersion = 1

    static func canonicalSHA256(_ inventory: Phase2LocalModelInventory) -> String {
        // All values below are constructed from an already validated app-owned inventory. An
        // encoding failure therefore indicates a programming error, not hostile provider input.
        let identity = try! Phase2QualificationV2Identity.make(
            id: "phase2.local-model-inventory.v1",
            version: schemaVersion,
            object: [
                "models": inventory.models.map(modelObject),
                "profile_id": inventory.profileID.uuidString.lowercased(),
                "version": schemaVersion,
            ]
        )
        return identity.sha256!
    }

    private static func modelObject(_ model: Phase2LocalModelDescriptor) -> [String: Any] {
        [
            "architecture": model.architecture ?? NSNull(),
            "capabilities": model.capabilities.map(capabilitiesObject) ?? NSNull(),
            "display_name": model.displayName,
            "format": model.format?.rawValue ?? NSNull(),
            "key": model.key,
            "loaded_configurations": sortedLoadedConfigurationObjects(model.loadedInstances),
            "maximum_context_length": model.maximumContextLength,
            "parameter_count_description": model.parameterCountDescription ?? NSNull(),
            "provider_selected_variant": model.providerSelectedVariant ?? NSNull(),
            "publisher": model.publisher,
            "quantization": model.quantization.map(quantizationObject) ?? NSNull(),
            "size_bytes_on_disk": String(model.sizeBytesOnDisk),
            "summary": model.summary ?? NSNull(),
            "type": model.type.rawValue,
            "variants": model.variants.sorted(by: unicodeScalarOrder),
        ]
    }

    private static func quantizationObject(
        _ quantization: Phase2LocalModelQuantization
    ) -> [String: Any] {
        [
            "bits_per_weight_ieee754": quantization.bitsPerWeight
                .map(canonicalDoubleBits) ?? NSNull(),
            "name": quantization.name ?? NSNull(),
        ]
    }

    private static func capabilitiesObject(
        _ capabilities: Phase2LocalModelCapabilities
    ) -> [String: Any] {
        [
            "reasoning": capabilities.reasoning.map { reasoning in
                [
                    "allowed_options": reasoning.allowedOptions.map(\.rawValue).sorted(),
                    "default_option": reasoning.defaultOption.rawValue,
                ] as [String: Any]
            } ?? NSNull(),
            "supports_vision": capabilities.supportsVision,
            "trained_for_tool_use": capabilities.trainedForToolUse,
        ]
    }

    private static func sortedLoadedConfigurationObjects(
        _ instances: [Phase2LocalModelLoadedInstance]
    ) -> [[String: Any]] {
        instances.map { configurationObject($0.configuration) }.sorted { lhs, rhs in
            let encoder = Phase2LengthFramedCanonicalEncoder()
            let left = try! encoder.encode(lhs)
            let right = try! encoder.encode(rhs)
            return left.lexicographicallyPrecedes(right)
        }
    }

    private static func configurationObject(
        _ configuration: Phase2LocalModelInstanceConfiguration
    ) -> [String: Any] {
        [
            "effective_context_length": configuration.effectiveContextLength,
            "evaluation_batch_size": configuration.evaluationBatchSize ?? NSNull(),
            "expert_count": configuration.expertCount ?? NSNull(),
            "flash_attention": configuration.flashAttention ?? NSNull(),
            "offloads_kv_cache_to_gpu": configuration.offloadsKVCacheToGPU ?? NSNull(),
            "parallel_predictions": configuration.parallelPredictions ?? NSNull(),
        ]
    }

    private static func canonicalDoubleBits(_ value: Double) -> String {
        let normalized = value == 0 ? 0.0 : value
        let unpadded = String(normalized.bitPattern, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - unpadded.count)) + unpadded
    }
}

private func unicodeScalarOrder(_ lhs: String, precedes rhs: String) -> Bool {
    lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(
        rhs.unicodeScalars.map(\.value)
    )
}

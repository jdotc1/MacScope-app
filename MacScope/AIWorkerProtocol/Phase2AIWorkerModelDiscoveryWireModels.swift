import Foundation

struct Phase2AIWorkerModelDiscoveryRequest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let requestID: UUID
    let profileID: UUID
    let generation: UInt64
    let endpointOrigin: String
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    var inferencePolicy: Phase2LocalInferencePolicy? = nil
}

struct Phase2AIWorkerModelDiscoveryReply: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case success
        case authenticationRequired
        case unavailable
        case incompatible
        case cancelled
    }

    let schemaVersion: Int
    let requestID: UUID
    let profileID: UUID
    let generation: UInt64
    let status: Status
    let inventory: Phase2AIWorkerModelInventoryWire?
}

struct Phase2AIWorkerModelInventoryWire: Codable, Equatable, Sendable {
    let models: [Phase2AIWorkerModelWire]
}

enum Phase2AIWorkerModelTypeWire: String, Codable, Sendable {
    case llm
    case embedding
}

enum Phase2AIWorkerModelFormatWire: String, Codable, Sendable {
    case gguf
    case mlx
}

struct Phase2AIWorkerModelWire: Codable, Equatable, Sendable {
    let type: Phase2AIWorkerModelTypeWire
    let publisher: String
    let key: String
    let displayName: String
    let architecture: String?
    let quantization: Phase2AIWorkerModelQuantizationWire?
    let sizeBytes: UInt64
    let parameters: String?
    let loadedInstances: [Phase2AIWorkerModelInstanceWire]
    let maximumContextLength: Int
    let format: Phase2AIWorkerModelFormatWire?
    let capabilities: Phase2AIWorkerModelCapabilitiesWire?
    let summary: String?
    let variants: [String]
    let selectedVariant: String?
}

struct Phase2AIWorkerModelQuantizationWire: Codable, Equatable, Sendable {
    let name: String?
    let bitsPerWeight: Double?
}

struct Phase2AIWorkerModelInstanceWire: Codable, Equatable, Sendable {
    let id: String
    let configuration: Phase2AIWorkerModelInstanceConfigurationWire
}

struct Phase2AIWorkerModelInstanceConfigurationWire: Codable, Equatable, Sendable {
    let contextLength: Int
    let evaluationBatchSize: Int?
    let parallelPredictions: Int?
    let flashAttention: Bool?
    let expertCount: Int?
    let offloadsKVCacheToGPU: Bool?
}

struct Phase2AIWorkerModelCapabilitiesWire: Codable, Equatable, Sendable {
    let vision: Bool
    let trainedForToolUse: Bool
    let reasoning: Phase2AIWorkerModelReasoningWire?
}

struct Phase2AIWorkerModelReasoningWire: Codable, Equatable, Sendable {
    let allowedOptions: [String]
    let defaultOption: String
}

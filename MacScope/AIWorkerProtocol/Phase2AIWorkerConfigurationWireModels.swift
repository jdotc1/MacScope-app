import Foundation

/// Closed, connection-scoped inference authority sent separately from every turn request.
struct Phase2AIWorkerConfigurationWire: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let generation: UInt64
    let endpointOrigin: String
    let model: String
    let protocolManifestDigest: String
    let maximumTokens: Int
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    var inferencePolicy: Phase2LocalInferencePolicy? = nil
}

struct Phase2AIWorkerConfigurationAcknowledgement: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case accepted
        case rejected
    }

    let schemaVersion: Int
    let profileID: UUID
    let generation: UInt64
    let protocolManifestDigest: String
    let status: Status
}

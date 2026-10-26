import Foundation

/// App-owned, immutable authority for observing one literal-loopback provider endpoint.
/// A model selection is intentionally absent so discovery can precede inference configuration.
struct Phase2LocalProviderEndpoint: Equatable, Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidGeneration
        case invalidEndpoint
        case invalidRequestTimeout
        case invalidResourceTimeout
    }

    let profileID: UUID
    let generation: UInt64
    let endpointOrigin: String
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    let inferencePolicy: Phase2LocalInferencePolicy?
    var providerKind: Phase2LocalAIProviderKind { inferencePolicy?.provider ?? .lmStudio }

    init(
        profileID: UUID,
        generation: UInt64,
        endpointOrigin: String,
        requestTimeoutMilliseconds: Int,
        resourceTimeoutMilliseconds: Int,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) throws {
        guard generation > 0 else { throw ValidationError.invalidGeneration }
        guard endpointOrigin.utf8.count <= 128,
              let canonicalOrigin = Phase2AIWorkerConfigurationValidation
                .canonicalLoopbackOrigin(endpointOrigin)
        else { throw ValidationError.invalidEndpoint }
        guard (1_000...(inferencePolicy == nil ? 30_000 : 900_000)).contains(requestTimeoutMilliseconds) else {
            throw ValidationError.invalidRequestTimeout
        }
        guard inferencePolicy?.isValid != false,
              (1_000...(inferencePolicy == nil ? 120_000 : 1_800_000)).contains(resourceTimeoutMilliseconds),
              resourceTimeoutMilliseconds >= requestTimeoutMilliseconds
        else { throw ValidationError.invalidResourceTimeout }

        self.profileID = profileID
        self.generation = generation
        self.endpointOrigin = canonicalOrigin
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.resourceTimeoutMilliseconds = resourceTimeoutMilliseconds
        self.inferencePolicy = inferencePolicy
    }
}

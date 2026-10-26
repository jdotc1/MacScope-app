import Foundation

/// App-owned immutable provider selection. It confers only bounded loopback inference authority.
struct Phase2AIProviderConfiguration: Equatable, Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidGeneration
        case invalidEndpoint
        case invalidModel
        case invalidMaximumTokens
        case invalidRequestTimeout
        case invalidResourceTimeout
    }

    let endpoint: Phase2LocalProviderEndpoint
    let model: String
    let maximumTokens: Int

    var inferencePolicy: Phase2LocalInferencePolicy? { endpoint.inferencePolicy }
    var profileID: UUID { endpoint.profileID }
    var generation: UInt64 { endpoint.generation }
    var endpointOrigin: String { endpoint.endpointOrigin }
    var requestTimeoutMilliseconds: Int { endpoint.requestTimeoutMilliseconds }
    var resourceTimeoutMilliseconds: Int { endpoint.resourceTimeoutMilliseconds }

    init(
        profileID: UUID,
        generation: UInt64,
        endpointOrigin: String,
        model: String,
        maximumTokens: Int,
        requestTimeoutMilliseconds: Int,
        resourceTimeoutMilliseconds: Int,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) throws {
        guard generation > 0 else { throw ValidationError.invalidGeneration }
        guard endpointOrigin.utf8.count <= 128,
              Phase2AIWorkerConfigurationValidation
                .canonicalLoopbackOrigin(endpointOrigin) != nil
        else { throw ValidationError.invalidEndpoint }

        let modelBytes = model.utf8
        guard !modelBytes.isEmpty,
              modelBytes.count <= 512,
              !modelBytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
        else { throw ValidationError.invalidModel }
        guard (1...(inferencePolicy == nil ? 8_192 : 16_384)).contains(maximumTokens) else {
            throw ValidationError.invalidMaximumTokens
        }

        let endpoint: Phase2LocalProviderEndpoint
        do {
            endpoint = try Phase2LocalProviderEndpoint(
                profileID: profileID,
                generation: generation,
                endpointOrigin: endpointOrigin,
                requestTimeoutMilliseconds: requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
                inferencePolicy: inferencePolicy
            )
        } catch let error as Phase2LocalProviderEndpoint.ValidationError {
            switch error {
            case .invalidGeneration: throw ValidationError.invalidGeneration
            case .invalidEndpoint: throw ValidationError.invalidEndpoint
            case .invalidRequestTimeout: throw ValidationError.invalidRequestTimeout
            case .invalidResourceTimeout: throw ValidationError.invalidResourceTimeout
            }
        }

        self.endpoint = endpoint
        self.model = model
        self.maximumTokens = maximumTokens
    }

    init(
        endpoint: Phase2LocalProviderEndpoint,
        model: String,
        maximumTokens: Int
    ) throws {

        let modelBytes = model.utf8
        guard !modelBytes.isEmpty,
              modelBytes.count <= 512,
              !modelBytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
        else { throw ValidationError.invalidModel }
        guard (1...(endpoint.inferencePolicy == nil ? 8_192 : 16_384)).contains(maximumTokens) else {
            throw ValidationError.invalidMaximumTokens
        }
        self.endpoint = endpoint
        self.model = model
        self.maximumTokens = maximumTokens
    }
}

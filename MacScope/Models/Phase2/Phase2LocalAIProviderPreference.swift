import Foundation

enum Phase2LocalAIProviderPreferenceValidationError: Error, Equatable, Sendable {
    case invalidModelKey
    case invalidMaximumTokens
}

/// A generation-free desired model preference. It is inert until it is authorized against a
/// fresh, endpoint-qualified inventory.
struct Phase2LocalAIDesiredSelection: Equatable, Hashable, Sendable {
    let modelKey: String
    let maximumTokens: Int

    init(modelKey: String, maximumTokens: Int, inferencePolicy: Phase2LocalInferencePolicy? = nil) throws {
        let modelBytes = modelKey.utf8
        guard !modelBytes.isEmpty,
              modelBytes.count <= 512,
              !modelBytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
        else {
            throw Phase2LocalAIProviderPreferenceValidationError.invalidModelKey
        }
        guard (1...(inferencePolicy == nil ? 8_192 : 16_384)).contains(maximumTokens) else {
            throw Phase2LocalAIProviderPreferenceValidationError.invalidMaximumTokens
        }
        self.modelKey = modelKey
        self.maximumTokens = maximumTokens
    }
}

/// App-global desired provider input that may survive restart without carrying runtime authority.
///
/// Profile identity, generation, inventory, ownership, activity, and readiness are deliberately
/// absent. Restoring this value can create only a fresh endpoint whose inventory is still required.
struct Phase2LocalAIProviderPreference: Equatable, Hashable, Sendable {
    let endpointOrigin: String
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    let desiredSelection: Phase2LocalAIDesiredSelection?
    let inferencePolicy: Phase2LocalInferencePolicy?

    init(
        endpointOrigin: String,
        requestTimeoutMilliseconds: Int,
        resourceTimeoutMilliseconds: Int,
        desiredSelection: Phase2LocalAIDesiredSelection?,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) throws {
        let validatedEndpoint = try Phase2LocalProviderEndpoint(
            profileID: UUID(),
            generation: 1,
            endpointOrigin: endpointOrigin,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
            inferencePolicy: inferencePolicy
        )
        self.endpointOrigin = validatedEndpoint.endpointOrigin
        self.requestTimeoutMilliseconds = validatedEndpoint.requestTimeoutMilliseconds
        self.resourceTimeoutMilliseconds = validatedEndpoint.resourceTimeoutMilliseconds
        self.desiredSelection = desiredSelection
        self.inferencePolicy = inferencePolicy
    }

    /// Mints runtime authority only from caller-supplied fresh identity. A restored preference
    /// never supplies or preserves either component of that identity.
    func makeEndpoint(profileID: UUID, generation: UInt64) throws -> Phase2LocalProviderEndpoint {
        try Phase2LocalProviderEndpoint(
            profileID: profileID,
            generation: generation,
            endpointOrigin: endpointOrigin,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: resourceTimeoutMilliseconds,
            inferencePolicy: inferencePolicy
        )
    }
}


extension Phase2LocalAIProviderPreference {
    /// Desired production defaults only. Fresh discovery must establish loaded-model authority.
    static func mtplxQualityDefault() throws -> Self {
        let policy = Phase2LocalInferencePolicy()
        return try .init(endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 900_000, resourceTimeoutMilliseconds: 1_800_000,
            desiredSelection: .init(modelKey: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
                maximumTokens: 16_384, inferencePolicy: policy), inferencePolicy: policy)
    }
}

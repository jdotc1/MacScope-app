import Foundation

enum Phase2LocalAISelectionValidationError: Error, Equatable, Sendable {
    case inventoryIdentityMismatch
    case modelMissing
    case modelNotLanguage
    case invalidMaximumTokens
}

/// One explicit, endpoint-qualified model preference. Selection is inert: it grants neither
/// lifecycle nor inference execution authority.
struct Phase2LocalAISelection: Equatable, Hashable, Sendable {
    let profileID: UUID
    let generation: UInt64
    let modelKey: String
    let maximumTokens: Int
    let configuration: Phase2AIProviderConfiguration

    static func authorize(
        endpoint: Phase2LocalProviderEndpoint,
        inventory: Phase2LocalModelInventory,
        modelKey: String,
        maximumTokens: Int
    ) throws -> Self {
        guard inventory.profileID == endpoint.profileID,
              inventory.generation == endpoint.generation
        else {
            throw Phase2LocalAISelectionValidationError.inventoryIdentityMismatch
        }
        guard let model = inventory.models.first(where: { $0.key == modelKey }) else {
            throw Phase2LocalAISelectionValidationError.modelMissing
        }
        guard model.type == .language else {
            throw Phase2LocalAISelectionValidationError.modelNotLanguage
        }
        let maximumAllowedTokens = min(endpoint.inferencePolicy == nil ? 8_192 : 16_384, model.maximumContextLength)
        guard maximumAllowedTokens >= 1,
              (1...maximumAllowedTokens).contains(maximumTokens)
        else {
            throw Phase2LocalAISelectionValidationError.invalidMaximumTokens
        }

        let observedContext = model.loadedInstances.map(\.configuration.effectiveContextLength).min()
        let policy = endpoint.inferencePolicy.map { $0.observingContext(observedContext ?? 0) }
        guard policy?.isValid != false else {
            throw Phase2LocalAISelectionValidationError.modelMissing
        }
        let observedEndpoint = try Phase2LocalProviderEndpoint(
            profileID: endpoint.profileID, generation: endpoint.generation,
            endpointOrigin: endpoint.endpointOrigin,
            requestTimeoutMilliseconds: endpoint.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: endpoint.resourceTimeoutMilliseconds,
            inferencePolicy: policy
        )
        return try Self(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: model.key,
            maximumTokens: maximumTokens,
            configuration: Phase2AIProviderConfiguration(
                endpoint: observedEndpoint,
                model: model.key,
                maximumTokens: maximumTokens
            )
        )
    }

    private init(
        profileID: UUID,
        generation: UInt64,
        modelKey: String,
        maximumTokens: Int,
        configuration: Phase2AIProviderConfiguration
    ) {
        self.profileID = profileID
        self.generation = generation
        self.modelKey = modelKey
        self.maximumTokens = maximumTokens
        self.configuration = configuration
    }
}

enum Phase2LocalAIProviderObservation: Equatable, Sendable {
    case inventoryRequired
    case accepted(Phase2LocalModelInventory)
    case authenticationRequired
    case unavailable
    case incompatible
    case reconciliationRequired
}

enum Phase2LocalAIProviderReadiness: Equatable, Sendable {
    case endpointMissing
    case inventoryRequired
    case authenticationRequired
    case unavailable
    case incompatible
    case reconciliationRequired
    case selectionRequired
    case selectionIdentityMismatch
    case selectedModelMissing
    case selectedModelNotLanguage
    case loadRequired(modelKey: String)
    case ready(Phase2AIProviderConfiguration)
}

enum Phase2LocalAIProviderActivity: Equatable, Sendable {
    case idle
    case discovering(requestID: UUID)
    case performingLifecycle(effectID: UUID)

    var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// Runtime-only authorization for one exact ready provider revision. The revision is controller
/// state, not endpoint generation, and is never persisted or reconstructed after launch.
struct Phase2ReadyInferenceLease: Equatable, Sendable {
    let providerRevision: UInt64
    let configuration: Phase2AIProviderConfiguration
    let observedModelInventorySHA256: String
}

/// An immutable presentation and composition snapshot. Readiness is always re-derived from the
/// current endpoint-qualified observation, never restored or accepted as an independent boolean.
struct Phase2LocalAIProviderSnapshot: Equatable, Sendable {
    let endpoint: Phase2LocalProviderEndpoint?
    let observation: Phase2LocalAIProviderObservation
    /// Restart-persistent user intent. This is deliberately distinct from `selection`, which is
    /// authorized runtime state derived only from a fresh endpoint-qualified inventory.
    let desiredSelection: Phase2LocalAIDesiredSelection?
    let selection: Phase2LocalAISelection?
    let activity: Phase2LocalAIProviderActivity
    /// Positive, launch-local controller state identity. It changes on every published transition.
    let revision: UInt64

    var inventory: Phase2LocalModelInventory? {
        guard case .accepted(let inventory) = observation else { return nil }
        return inventory
    }

    var readiness: Phase2LocalAIProviderReadiness {
        guard let endpoint else { return .endpointMissing }
        switch observation {
        case .inventoryRequired:
            return .inventoryRequired
        case .authenticationRequired:
            return .authenticationRequired
        case .unavailable:
            return .unavailable
        case .incompatible:
            return .incompatible
        case .reconciliationRequired:
            return .reconciliationRequired
        case .accepted(let inventory):
            guard inventory.profileID == endpoint.profileID,
                  inventory.generation == endpoint.generation
            else { return .inventoryRequired }
            guard let desiredSelection else { return .selectionRequired }
            guard let desiredModel = inventory.models.first(where: {
                $0.key == desiredSelection.modelKey
            }) else { return .selectedModelMissing }
            guard desiredModel.type == .language else { return .selectedModelNotLanguage }
            let desiredTokenCap = min(endpoint.inferencePolicy == nil ? 8_192 : 16_384, desiredModel.maximumContextLength)
            guard desiredTokenCap >= 1,
                  (1...desiredTokenCap).contains(desiredSelection.maximumTokens)
            else { return .selectionIdentityMismatch }
            guard let selection else { return .selectionIdentityMismatch }
            guard selection.profileID == endpoint.profileID,
                  selection.generation == endpoint.generation,
                  selection.modelKey == desiredSelection.modelKey,
                  selection.maximumTokens == desiredSelection.maximumTokens
            else { return .selectionIdentityMismatch }
            guard let model = inventory.models.first(where: {
                $0.key == selection.modelKey
            }) else { return .selectedModelMissing }
            guard model.type == .language else { return .selectedModelNotLanguage }
            let maximumAllowedTokens = min(endpoint.inferencePolicy == nil ? 8_192 : 16_384, model.maximumContextLength)
            guard maximumAllowedTokens >= 1,
                  (1...maximumAllowedTokens).contains(selection.maximumTokens)
            else { return .selectionIdentityMismatch }
            guard !model.loadedInstances.isEmpty else {
                return .loadRequired(modelKey: selection.modelKey)
            }
            return .ready(selection.configuration)
        }
    }

    /// Executable authority requires the exact ready state and an idle control plane. Readiness
    /// intentionally remains presentation-oriented, so lifecycle/discovery activity is checked
    /// again here at the execution boundary.
    var readyInferenceLease: Phase2ReadyInferenceLease? {
        guard activity == .idle,
              revision > 0,
              revision < UInt64.max,
              case .accepted(let inventory) = observation,
              case .ready(let configuration) = readiness
        else { return nil }
        return .init(
            providerRevision: revision,
            configuration: configuration,
            observedModelInventorySHA256: Phase2LocalModelInventoryIdentity
                .canonicalSHA256(inventory)
        )
    }

    init(
        endpoint: Phase2LocalProviderEndpoint? = nil,
        observation: Phase2LocalAIProviderObservation = .inventoryRequired,
        desiredSelection: Phase2LocalAIDesiredSelection? = nil,
        selection: Phase2LocalAISelection? = nil,
        activity: Phase2LocalAIProviderActivity = .idle,
        revision: UInt64 = 1
    ) {
        self.endpoint = endpoint
        self.observation = observation
        if let desiredSelection {
            self.desiredSelection = desiredSelection
        } else if let selection {
            self.desiredSelection = try? Phase2LocalAIDesiredSelection(
                modelKey: selection.modelKey,
                maximumTokens: selection.maximumTokens,
                inferencePolicy: selection.configuration.inferencePolicy
            )
        } else {
            self.desiredSelection = nil
        }
        self.selection = selection
        self.activity = activity
        self.revision = revision
    }
}

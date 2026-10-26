import Foundation

enum Phase2LocalModelLifecycleValidationError: Error, Equatable, Sendable {
    case invalidGeneration
    case invalidModelKey
    case invalidInstanceID
    case invalidContextLength
    case inventoryIdentityMismatch
    case modelNotFound
    case modelNotLanguage
    case instanceNotFound
    case instanceConfigurationMismatch
    case instanceNotOwned
    case managementUnavailable
}

enum Phase2LocalModelLifecycleOperation: Equatable, Hashable, Sendable {
    case load(modelKey: String, requestedContextLength: Int)
    case unload(
        modelKey: String,
        instanceID: String,
        observedConfiguration: Phase2LocalModelInstanceConfiguration
    )
}

struct Phase2LocalModelLifecycleCommand: Equatable, Hashable, Sendable {
    let effectID: UUID
    let profileID: UUID
    let generation: UInt64
    let operation: Phase2LocalModelLifecycleOperation

    static func load(
        effectID: UUID,
        profileID: UUID,
        generation: UInt64,
        modelKey: String,
        requestedContextLength: Int
    ) throws -> Self {
        guard generation > 0 else {
            throw Phase2LocalModelLifecycleValidationError.invalidGeneration
        }
        guard isValidLifecycleIdentifier(modelKey) else {
            throw Phase2LocalModelLifecycleValidationError.invalidModelKey
        }
        guard (1...4_194_304).contains(requestedContextLength) else {
            throw Phase2LocalModelLifecycleValidationError.invalidContextLength
        }
        return .init(
            effectID: effectID,
            profileID: profileID,
            generation: generation,
            operation: .load(
                modelKey: modelKey,
                requestedContextLength: requestedContextLength
            )
        )
    }

    static func unload(
        effectID: UUID,
        profileID: UUID,
        generation: UInt64,
        modelKey: String,
        instance: Phase2LocalModelLoadedInstance
    ) throws -> Self {
        guard generation > 0 else {
            throw Phase2LocalModelLifecycleValidationError.invalidGeneration
        }
        guard isValidLifecycleIdentifier(modelKey) else {
            throw Phase2LocalModelLifecycleValidationError.invalidModelKey
        }
        guard isValidLifecycleIdentifier(instance.id) else {
            throw Phase2LocalModelLifecycleValidationError.invalidInstanceID
        }
        guard (1...4_194_304).contains(instance.configuration.effectiveContextLength) else {
            throw Phase2LocalModelLifecycleValidationError.invalidContextLength
        }
        return .init(
            effectID: effectID,
            profileID: profileID,
            generation: generation,
            operation: .unload(
                modelKey: modelKey,
                instanceID: instance.id,
                observedConfiguration: instance.configuration
            )
        )
    }

    static func authorizeLoad(
        effectID: UUID,
        endpoint: Phase2LocalProviderEndpoint,
        inventory: Phase2LocalModelInventory,
        modelKey: String,
        requestedContextLength: Int
    ) throws -> Self {
        guard endpoint.providerKind == .lmStudio else {
            throw Phase2LocalModelLifecycleValidationError.managementUnavailable
        }
        try validateInventoryIdentity(inventory, endpoint: endpoint)
        guard let model = inventory.models.first(where: { $0.key == modelKey }) else {
            throw Phase2LocalModelLifecycleValidationError.modelNotFound
        }
        guard model.type == .language else {
            throw Phase2LocalModelLifecycleValidationError.modelNotLanguage
        }
        let maximumContextLength = min(model.maximumContextLength, 4_194_304)
        guard maximumContextLength >= 1,
              (1...maximumContextLength).contains(requestedContextLength)
        else {
            throw Phase2LocalModelLifecycleValidationError.invalidContextLength
        }
        return try load(
            effectID: effectID,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: modelKey,
            requestedContextLength: requestedContextLength
        )
    }

    static func authorizeUnload(
        effectID: UUID,
        endpoint: Phase2LocalProviderEndpoint,
        inventory: Phase2LocalModelInventory,
        modelKey: String,
        instanceID: String,
        observedConfiguration: Phase2LocalModelInstanceConfiguration,
        ownershipLedger: Phase2LocalModelOwnershipLedger
    ) async throws -> Self {
        guard endpoint.providerKind == .lmStudio else {
            throw Phase2LocalModelLifecycleValidationError.managementUnavailable
        }
        try validateInventoryIdentity(inventory, endpoint: endpoint)
        guard let model = inventory.models.first(where: { $0.key == modelKey }) else {
            throw Phase2LocalModelLifecycleValidationError.modelNotFound
        }
        guard model.type == .language else {
            throw Phase2LocalModelLifecycleValidationError.modelNotLanguage
        }
        guard let instance = model.loadedInstances.first(where: { $0.id == instanceID }) else {
            throw Phase2LocalModelLifecycleValidationError.instanceNotFound
        }
        guard instance.configuration == observedConfiguration else {
            throw Phase2LocalModelLifecycleValidationError.instanceConfigurationMismatch
        }

        let ownership = Phase2LocalModelOwnership(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: modelKey,
            instanceID: instanceID
        )
        guard await ownershipLedger.contains(ownership) else {
            throw Phase2LocalModelLifecycleValidationError.instanceNotOwned
        }
        return try unload(
            effectID: effectID,
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: modelKey,
            instance: instance
        )
    }

    private static func validateInventoryIdentity(
        _ inventory: Phase2LocalModelInventory,
        endpoint: Phase2LocalProviderEndpoint
    ) throws {
        guard inventory.profileID == endpoint.profileID,
              inventory.generation == endpoint.generation
        else {
            throw Phase2LocalModelLifecycleValidationError.inventoryIdentityMismatch
        }
    }
}

enum Phase2LocalModelLifecycleReceipt: Equatable, Hashable, Sendable {
    case load(
        modelKey: String,
        instance: Phase2LocalModelLoadedInstance,
        loadTimeSeconds: Double
    )
    case unload(modelKey: String, instanceID: String)
}

enum Phase2LocalModelLifecycleOutcome: Equatable, Sendable {
    case loaded(Phase2LocalModelLifecycleReceipt)
    case unloaded(Phase2LocalModelLifecycleReceipt)
    case authenticationRequired
    case unavailableBeforeDispatch
    case incompatibleBeforeDispatch
    case rejected
    case cancelledBeforeDispatch
    case reconciliationRequired
}

struct Phase2LocalModelOwnership: Equatable, Hashable, Sendable {
    let profileID: UUID
    let generation: UInt64
    let modelKey: String
    let instanceID: String
}

actor Phase2LocalModelOwnershipLedger {
    private struct EndpointIdentity: Equatable, Sendable {
        let profileID: UUID
        let generation: UInt64
    }

    private var activeEndpoint: EndpointIdentity?
    private var ownedInstances: Set<Phase2LocalModelOwnership> = []

    func activate(endpoint: Phase2LocalProviderEndpoint) {
        activate(profileID: endpoint.profileID, generation: endpoint.generation)
    }

    func recordReconciledLoad(_ ownership: Phase2LocalModelOwnership) {
        activate(profileID: ownership.profileID, generation: ownership.generation)
        ownedInstances.insert(ownership)
    }

    func recordReconciledUnload(_ ownership: Phase2LocalModelOwnership) {
        guard activeEndpoint == .init(
            profileID: ownership.profileID,
            generation: ownership.generation
        ) else { return }
        ownedInstances.remove(ownership)
    }

    func contains(_ ownership: Phase2LocalModelOwnership) -> Bool {
        guard activeEndpoint == .init(
            profileID: ownership.profileID,
            generation: ownership.generation
        ) else { return false }
        return ownedInstances.contains(ownership)
    }

    func entries() -> Set<Phase2LocalModelOwnership> {
        ownedInstances
    }

    private func activate(profileID: UUID, generation: UInt64) {
        let identity = EndpointIdentity(profileID: profileID, generation: generation)
        guard activeEndpoint != identity else { return }
        activeEndpoint = identity
        ownedInstances.removeAll(keepingCapacity: false)
    }
}

private func isValidLifecycleIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty
        && bytes.count <= 512
        && !bytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
}

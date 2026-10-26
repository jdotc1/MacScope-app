import Foundation

enum AIAgentXPCModelLifecycleServiceError: Error, Equatable, Sendable {
    case busy
}

/// Serializes one explicit mutation, tears down its lifecycle connection, and reconciles every
/// may-dispatch outcome through a fresh observational discovery connection before changing
/// ephemeral ownership.
actor AIAgentXPCModelLifecycleService: Phase2LocalModelLifecycleControlling {
    private let transport: any Phase2AIWorkerModelLifecycleTransport
    private let discovery: any Phase2LocalModelDiscovering
    private let ownership: Phase2LocalModelOwnershipLedger
    private let codec: Phase2AIWorkerModelLifecycleAppCodec
    private let pauseBeforeTransport: @Sendable () async -> Void
    private var activeEffectID: UUID?
    private var explicitlyCancelledEffectIDs: Set<UUID> = []

    init(
        transport: any Phase2AIWorkerModelLifecycleTransport =
            NSXPCAIWorkerModelLifecycleTransport(),
        discovery: any Phase2LocalModelDiscovering = AIAgentXPCModelDiscoveryService(),
        ownership: Phase2LocalModelOwnershipLedger = .init(),
        codec: Phase2AIWorkerModelLifecycleAppCodec = .init(),
        pauseBeforeTransport: @escaping @Sendable () async -> Void = {}
    ) {
        self.transport = transport
        self.discovery = discovery
        self.ownership = ownership
        self.codec = codec
        self.pauseBeforeTransport = pauseBeforeTransport
    }

    func perform(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint,
        acceptedInventory: Phase2LocalModelInventory
    ) async throws -> Phase2LocalModelLifecycleOutcome {
        guard activeEffectID == nil else { throw AIAgentXPCModelLifecycleServiceError.busy }
        activeEffectID = command.effectID
        explicitlyCancelledEffectIDs.remove(command.effectID)

        do {
            guard acceptedInventory.profileID == endpoint.profileID,
                  acceptedInventory.generation == endpoint.generation
            else {
                throw Phase2LocalModelLifecycleValidationError.inventoryIdentityMismatch
            }
            await ownership.activate(endpoint: endpoint)
            try await validate(
                command: command,
                endpoint: endpoint,
                inventory: acceptedInventory
            )
            let requestData = try codec.encodeRequest(command: command, endpoint: endpoint)
            await pauseBeforeTransport()
            guard !Task.isCancelled,
                  !explicitlyCancelledEffectIDs.contains(command.effectID)
            else {
                finish(effectID: command.effectID)
                return .cancelledBeforeDispatch
            }

            let transportOutcome: Phase2LocalModelLifecycleOutcome
            do {
                let replyData = try await withTaskCancellationHandler {
                    try await transport.perform(
                        requestData: requestData,
                        requestID: command.effectID
                    )
                } onCancel: { [transport] in
                    Task { await transport.cancel(requestID: command.effectID) }
                }
                do {
                    transportOutcome = try codec.decodeReply(
                        replyData,
                        expectedCommand: command
                    )
                } catch {
                    // A reply can exist only after the mutating selector may have been dispatched.
                    transportOutcome = .reconciliationRequired
                }
            } catch let error as Phase2AIWorkerModelLifecycleTransportError {
                switch error {
                case .unavailableBeforeDispatch:
                    transportOutcome = .unavailableBeforeDispatch
                case .cancelledBeforeDispatch:
                    transportOutcome = .cancelledBeforeDispatch
                case .reconciliationRequired:
                    transportOutcome = .reconciliationRequired
                }
            } catch {
                // Unknown transport failures cannot prove the mutation remained local.
                transportOutcome = .reconciliationRequired
            }

            await transport.reset()
            let result: Phase2LocalModelLifecycleOutcome
            if requiresReconciliation(transportOutcome) {
                result = await reconcile(
                    transportOutcome,
                    command: command,
                    endpoint: endpoint
                )
            } else {
                result = transportOutcome
            }
            finish(effectID: command.effectID)
            return result
        } catch {
            await transport.reset()
            finish(effectID: command.effectID)
            throw error
        }
    }

    func cancel(effectID: UUID) async {
        guard activeEffectID == effectID else { return }
        explicitlyCancelledEffectIDs.insert(effectID)
        await transport.cancel(requestID: effectID)
    }

    private func validate(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint,
        inventory: Phase2LocalModelInventory
    ) async throws {
        let authorized: Phase2LocalModelLifecycleCommand
        switch command.operation {
        case let .load(modelKey, requestedContextLength):
            authorized = try .authorizeLoad(
                effectID: command.effectID,
                endpoint: endpoint,
                inventory: inventory,
                modelKey: modelKey,
                requestedContextLength: requestedContextLength
            )
        case let .unload(modelKey, instanceID, observedConfiguration):
            authorized = try await .authorizeUnload(
                effectID: command.effectID,
                endpoint: endpoint,
                inventory: inventory,
                modelKey: modelKey,
                instanceID: instanceID,
                observedConfiguration: observedConfiguration,
                ownershipLedger: ownership
            )
        }
        guard authorized == command else {
            throw Phase2LocalModelLifecycleValidationError.inventoryIdentityMismatch
        }
    }

    private func requiresReconciliation(
        _ outcome: Phase2LocalModelLifecycleOutcome
    ) -> Bool {
        switch outcome {
        case .loaded, .unloaded, .authenticationRequired, .rejected,
             .reconciliationRequired:
            return true
        case .unavailableBeforeDispatch, .incompatibleBeforeDispatch,
             .cancelledBeforeDispatch:
            return false
        }
    }

    private func reconcile(
        _ transportOutcome: Phase2LocalModelLifecycleOutcome,
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint
    ) async -> Phase2LocalModelLifecycleOutcome {
        let discoveryResult: Phase2LocalModelDiscoveryOutcome
        do {
            let discovery = self.discovery
            discoveryResult = try await Task.detached {
                try await discovery.discoverModels(endpoint: endpoint, requestID: UUID())
            }.value
        } catch {
            return .reconciliationRequired
        }
        guard case .success(let inventory) = discoveryResult,
              inventory.profileID == endpoint.profileID,
              inventory.generation == endpoint.generation
        else { return .reconciliationRequired }

        switch transportOutcome {
        case .loaded(let receipt):
            guard case let .load(modelKey, instance, _) = receipt,
                  case let .load(commandModelKey, _) = command.operation,
                  modelKey == commandModelKey,
                  inventory.models.first(where: { $0.key == modelKey })?
                    .loadedInstances.contains(where: {
                        matchesLoadReceipt($0, instance)
                    }) == true
            else { return .reconciliationRequired }
            let identity = Phase2LocalModelOwnership(
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                modelKey: modelKey,
                instanceID: instance.id
            )
            await ownership.recordReconciledLoad(identity)
            return .loaded(receipt)

        case .unloaded(let receipt):
            guard case let .unload(modelKey, instanceID) = receipt,
                  case let .unload(commandModelKey, commandInstanceID, _) = command.operation,
                  modelKey == commandModelKey,
                  instanceID == commandInstanceID,
                  !inventory.models.flatMap(\.loadedInstances).contains(where: {
                      $0.id == instanceID
                  })
            else { return .reconciliationRequired }
            let identity = Phase2LocalModelOwnership(
                profileID: endpoint.profileID,
                generation: endpoint.generation,
                modelKey: modelKey,
                instanceID: instanceID
            )
            await ownership.recordReconciledUnload(identity)
            return .unloaded(receipt)

        case .authenticationRequired, .rejected, .reconciliationRequired:
            return transportOutcome
        case .unavailableBeforeDispatch, .incompatibleBeforeDispatch,
             .cancelledBeforeDispatch:
            return .reconciliationRequired
        }
    }

    private func matchesLoadReceipt(
        _ discovered: Phase2LocalModelLoadedInstance,
        _ receipt: Phase2LocalModelLoadedInstance
    ) -> Bool {
        let discoveredConfiguration = discovered.configuration
        let receiptConfiguration = receipt.configuration
        return discovered.id == receipt.id
            && discoveredConfiguration.effectiveContextLength
                == receiptConfiguration.effectiveContextLength
            && discoveredConfiguration.evaluationBatchSize
                == receiptConfiguration.evaluationBatchSize
            && discoveredConfiguration.flashAttention == receiptConfiguration.flashAttention
            && discoveredConfiguration.expertCount == receiptConfiguration.expertCount
            && discoveredConfiguration.offloadsKVCacheToGPU
                == receiptConfiguration.offloadsKVCacheToGPU
    }

    private func finish(effectID: UUID) {
        explicitlyCancelledEffectIDs.remove(effectID)
        if activeEffectID == effectID { activeEffectID = nil }
    }
}

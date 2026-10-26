import Foundation

enum Phase2AIWorkerModelLifecycleAppCodecError: Error, Equatable, Sendable {
    case identityMismatch
    case operationMismatch
    case receiptMismatch
}

/// App-owned translation between immutable lifecycle authority and the closed worker wire.
struct Phase2AIWorkerModelLifecycleAppCodec: Sendable {
    private let wireCodec: Phase2AIWorkerModelLifecycleWireCodec

    init(wireCodec: Phase2AIWorkerModelLifecycleWireCodec = .init()) {
        self.wireCodec = wireCodec
    }

    func encodeRequest(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint
    ) throws -> Data {
        guard command.profileID == endpoint.profileID,
              command.generation == endpoint.generation
        else { throw Phase2AIWorkerModelLifecycleAppCodecError.identityMismatch }

        return try wireCodec.encodeRequest(.init(
            schemaVersion: Phase2AIWorkerModelLifecycleWireCodec.schemaVersion,
            effectID: command.effectID,
            profileID: command.profileID,
            generation: command.generation,
            endpointOrigin: endpoint.endpointOrigin,
            requestTimeoutMilliseconds: endpoint.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: endpoint.resourceTimeoutMilliseconds,
            operation: .init(command.operation)
        ))
    }

    func decodeReply(
        _ data: Data,
        expectedCommand command: Phase2LocalModelLifecycleCommand
    ) throws -> Phase2LocalModelLifecycleOutcome {
        let reply = try wireCodec.decodeReply(data)
        guard reply.effectID == command.effectID,
              reply.profileID == command.profileID,
              reply.generation == command.generation
        else { throw Phase2AIWorkerModelLifecycleAppCodecError.identityMismatch }

        let expectedKind = Phase2AIWorkerModelLifecycleOperationKindWire(command.operation)
        guard reply.operationKind == expectedKind else {
            throw Phase2AIWorkerModelLifecycleAppCodecError.operationMismatch
        }

        switch reply.status {
        case .succeeded:
            guard let receipt = reply.receipt else {
                throw Phase2AIWorkerModelLifecycleAppCodecError.receiptMismatch
            }
            return try successOutcome(receipt, command: command)
        case .authenticationRequired:
            return .authenticationRequired
        case .unavailableBeforeDispatch:
            return .unavailableBeforeDispatch
        case .incompatibleBeforeDispatch:
            return .incompatibleBeforeDispatch
        case .rejected:
            return .rejected
        case .cancelledBeforeDispatch:
            return .cancelledBeforeDispatch
        case .reconciliationRequired:
            return .reconciliationRequired
        }
    }

    private func successOutcome(
        _ receipt: Phase2AIWorkerModelLifecycleReceiptWire,
        command: Phase2LocalModelLifecycleCommand
    ) throws -> Phase2LocalModelLifecycleOutcome {
        switch (command.operation, receipt) {
        case let (.load(modelKey, _), .load(value)):
            let localReceipt = Phase2LocalModelLifecycleReceipt.load(
                modelKey: modelKey,
                instance: .init(
                    id: value.instanceID,
                    configuration: .init(
                        effectiveContextLength: value.configuration.contextLength,
                        evaluationBatchSize: value.configuration.evaluationBatchSize,
                        parallelPredictions: nil,
                        flashAttention: value.configuration.flashAttention,
                        expertCount: value.configuration.expertCount,
                        offloadsKVCacheToGPU: value.configuration.offloadsKVCacheToGPU
                    )
                ),
                loadTimeSeconds: value.loadTimeSeconds
            )
            return .loaded(localReceipt)
        case let (.unload(modelKey, instanceID, _), .unload(value)):
            guard value.instanceID == instanceID else {
                throw Phase2AIWorkerModelLifecycleAppCodecError.receiptMismatch
            }
            return .unloaded(.unload(modelKey: modelKey, instanceID: instanceID))
        default:
            throw Phase2AIWorkerModelLifecycleAppCodecError.receiptMismatch
        }
    }
}

extension Phase2AIWorkerModelLifecycleOperationKindWire {
    init(_ operation: Phase2LocalModelLifecycleOperation) {
        switch operation {
        case .load: self = .load
        case .unload: self = .unload
        }
    }
}

extension Phase2AIWorkerModelLifecycleOperationWire {
    init(_ operation: Phase2LocalModelLifecycleOperation) {
        switch operation {
        case let .load(modelKey, requestedContextLength):
            self = .load(modelKey: modelKey, contextLength: requestedContextLength)
        case let .unload(_, instanceID, _):
            self = .unload(instanceID: instanceID)
        }
    }

}

extension Phase2AIWorkerModelLifecycleReceiptWire {
    init(_ receipt: Phase2LocalModelLifecycleReceipt) {
        switch receipt {
        case let .load(_, instance, loadTimeSeconds):
            self = .load(.init(
                instanceID: instance.id,
                loadTimeSeconds: loadTimeSeconds,
                configuration: .init(
                    contextLength: instance.configuration.effectiveContextLength,
                    evaluationBatchSize: instance.configuration.evaluationBatchSize,
                    flashAttention: instance.configuration.flashAttention,
                    expertCount: instance.configuration.expertCount,
                    offloadsKVCacheToGPU: instance.configuration.offloadsKVCacheToGPU
                )
            ))
        case let .unload(_, instanceID):
            self = .unload(.init(instanceID: instanceID))
        }
    }
}

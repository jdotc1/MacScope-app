import Foundation

struct Phase2AIWorkerModelLifecycleRequest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let effectID: UUID
    let profileID: UUID
    let generation: UInt64
    let endpointOrigin: String
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    let operation: Phase2AIWorkerModelLifecycleOperationWire
}

enum Phase2AIWorkerModelLifecycleOperationKindWire: String, Codable, Equatable, Sendable {
    case load
    case unload
}

enum Phase2AIWorkerModelLifecycleOperationWire: Codable, Equatable, Sendable {
    case load(modelKey: String, contextLength: Int)
    case unload(instanceID: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case modelKey
        case contextLength
        case instanceID
    }

    var kind: Phase2AIWorkerModelLifecycleOperationKindWire {
        switch self {
        case .load: .load
        case .unload: .unload
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Phase2AIWorkerModelLifecycleOperationKindWire.self, forKey: .kind) {
        case .load:
            self = try .load(
                modelKey: container.decode(String.self, forKey: .modelKey),
                contextLength: container.decode(Int.self, forKey: .contextLength)
            )
        case .unload:
            self = try .unload(instanceID: container.decode(String.self, forKey: .instanceID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .load(let modelKey, let contextLength):
            try container.encode(modelKey, forKey: .modelKey)
            try container.encode(contextLength, forKey: .contextLength)
        case .unload(let instanceID):
            try container.encode(instanceID, forKey: .instanceID)
        }
    }
}

struct Phase2AIWorkerModelLifecycleReply: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case succeeded
        case authenticationRequired
        case unavailableBeforeDispatch
        case incompatibleBeforeDispatch
        case rejected
        case cancelledBeforeDispatch
        case reconciliationRequired
    }

    let schemaVersion: Int
    let effectID: UUID
    let profileID: UUID
    let generation: UInt64
    let operationKind: Phase2AIWorkerModelLifecycleOperationKindWire
    let status: Status
    let receipt: Phase2AIWorkerModelLifecycleReceiptWire?

    init(
        schemaVersion: Int,
        effectID: UUID,
        profileID: UUID,
        generation: UInt64,
        operationKind: Phase2AIWorkerModelLifecycleOperationKindWire,
        status: Status,
        receipt: Phase2AIWorkerModelLifecycleReceiptWire?
    ) {
        self.schemaVersion = schemaVersion
        self.effectID = effectID
        self.profileID = profileID
        self.generation = generation
        self.operationKind = operationKind
        self.status = status
        self.receipt = receipt
    }

    init(
        request: Phase2AIWorkerModelLifecycleRequest,
        status: Status,
        receipt: Phase2AIWorkerModelLifecycleReceiptWire?
    ) {
        self.init(
            schemaVersion: request.schemaVersion,
            effectID: request.effectID,
            profileID: request.profileID,
            generation: request.generation,
            operationKind: request.operation.kind,
            status: status,
            receipt: receipt
        )
    }
}

enum Phase2AIWorkerModelLifecycleReceiptWire: Codable, Equatable, Sendable {
    case load(Phase2AIWorkerModelLoadReceiptWire)
    case unload(Phase2AIWorkerModelUnloadReceiptWire)

    private enum CodingKeys: String, CodingKey {
        case kind
        case instanceID
        case loadTimeSeconds
        case configuration
    }

    var kind: Phase2AIWorkerModelLifecycleOperationKindWire {
        switch self {
        case .load: .load
        case .unload: .unload
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(
            Phase2AIWorkerModelLifecycleOperationKindWire.self,
            forKey: .kind
        )
        let instanceID = try container.decode(String.self, forKey: .instanceID)
        switch kind {
        case .load:
            self = try .load(.init(
                instanceID: instanceID,
                loadTimeSeconds: container.decode(Double.self, forKey: .loadTimeSeconds),
                configuration: container.decode(
                    Phase2AIWorkerModelLoadConfigurationWire.self,
                    forKey: .configuration
                )
            ))
        case .unload:
            self = .unload(.init(instanceID: instanceID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .load(let receipt):
            try container.encode(receipt.instanceID, forKey: .instanceID)
            try container.encode(receipt.loadTimeSeconds, forKey: .loadTimeSeconds)
            try container.encode(receipt.configuration, forKey: .configuration)
        case .unload(let receipt):
            try container.encode(receipt.instanceID, forKey: .instanceID)
        }
    }
}

struct Phase2AIWorkerModelLoadReceiptWire: Equatable, Sendable {
    let instanceID: String
    let loadTimeSeconds: Double
    let configuration: Phase2AIWorkerModelLoadConfigurationWire
}

struct Phase2AIWorkerModelUnloadReceiptWire: Equatable, Sendable {
    let instanceID: String
}

struct Phase2AIWorkerModelLoadConfigurationWire: Codable, Equatable, Sendable {
    let contextLength: Int
    let evaluationBatchSize: Int?
    let flashAttention: Bool?
    let expertCount: Int?
    let offloadsKVCacheToGPU: Bool?
}

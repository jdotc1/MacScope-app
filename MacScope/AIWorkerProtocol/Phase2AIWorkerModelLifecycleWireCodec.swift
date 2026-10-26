import Foundation

struct Phase2AIWorkerModelLifecycleWireCodec: Sendable {
    static let schemaVersion = 1
    static let maximumRequestEnvelopeBytes = 4_096
    static let maximumReplyEnvelopeBytes = 65_536
    static let maximumIdentifierBytes = 512
    static let maximumContextLength = 4_194_304

    private static let requestKeys: Set<String> = [
        "schemaVersion", "effectID", "profileID", "generation", "endpointOrigin",
        "requestTimeoutMilliseconds", "resourceTimeoutMilliseconds", "operation",
    ]
    private static let loadOperationKeys: Set<String> = ["kind", "modelKey", "contextLength"]
    private static let unloadOperationKeys: Set<String> = ["kind", "instanceID"]
    private static let replyRequiredKeys: Set<String> = [
        "schemaVersion", "effectID", "profileID", "generation", "operationKind", "status",
    ]
    private static let loadReceiptKeys: Set<String> = [
        "kind", "instanceID", "loadTimeSeconds", "configuration",
    ]
    private static let unloadReceiptKeys: Set<String> = ["kind", "instanceID"]
    private static let loadConfigurationRequiredKeys: Set<String> = ["contextLength"]
    private static let loadConfigurationOptionalKeys: Set<String> = [
        "evaluationBatchSize", "flashAttention", "expertCount", "offloadsKVCacheToGPU",
    ]

    func encodeRequest(_ value: Phase2AIWorkerModelLifecycleRequest) throws -> Data {
        try validate(value)
        return try encode(value, ceiling: Self.maximumRequestEnvelopeBytes)
    }

    func decodeRequest(_ data: Data) throws -> Phase2AIWorkerModelLifecycleRequest {
        try requireBound(data, ceiling: Self.maximumRequestEnvelopeBytes)
        try requireNoDuplicateObjectKeys(data)
        let object = try requireObject(data)
        guard Set(object.keys) == Self.requestKeys,
              let operation = object["operation"] as? [String: Any]
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
        try requireIntegerFields(
            in: object,
            required: [
                "schemaVersion", "generation", "requestTimeoutMilliseconds",
                "resourceTimeoutMilliseconds",
            ]
        )
        try requireCanonicalUUIDs(in: object)
        try requireClosedOperationShape(operation)
        let value: Phase2AIWorkerModelLifecycleRequest = try decode(data)
        try validate(value)
        return value
    }

    func encodeReply(_ value: Phase2AIWorkerModelLifecycleReply) throws -> Data {
        try validate(value)
        return try encode(value, ceiling: Self.maximumReplyEnvelopeBytes)
    }

    func decodeReply(_ data: Data) throws -> Phase2AIWorkerModelLifecycleReply {
        try requireBound(data, ceiling: Self.maximumReplyEnvelopeBytes)
        try requireNoDuplicateObjectKeys(data)
        let object = try requireObject(data)
        let expected = Self.replyRequiredKeys.union(object["receipt"] == nil ? [] : ["receipt"])
        guard Set(object.keys) == expected else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        try requireIntegerFields(in: object, required: ["schemaVersion", "generation"])
        try requireCanonicalUUIDs(in: object)
        if let receipt = object["receipt"] {
            guard let receiptObject = receipt as? [String: Any] else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            try requireClosedReceiptShape(receiptObject)
        }
        let value: Phase2AIWorkerModelLifecycleReply = try decode(data)
        try validate(value)
        return value
    }

    private func validate(_ value: Phase2AIWorkerModelLifecycleRequest) throws {
        try requireCurrent(value.schemaVersion)
        guard value.generation > 0,
              value.endpointOrigin.utf8.count <= 128,
              Phase2AIWorkerConfigurationValidation.isCanonicalLoopbackOrigin(value.endpointOrigin),
              (1_000...30_000).contains(value.requestTimeoutMilliseconds),
              (1_000...120_000).contains(value.resourceTimeoutMilliseconds),
              value.resourceTimeoutMilliseconds >= value.requestTimeoutMilliseconds
        else { throw Phase2AIWorkerWireError.invalidEnvelope }

        switch value.operation {
        case .load(let modelKey, let contextLength):
            guard validIdentifier(modelKey),
                  (1...Self.maximumContextLength).contains(contextLength)
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
        case .unload(let instanceID):
            guard validIdentifier(instanceID) else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
        }
    }

    private func validate(_ value: Phase2AIWorkerModelLifecycleReply) throws {
        try requireCurrent(value.schemaVersion)
        guard value.generation > 0 else { throw Phase2AIWorkerWireError.invalidEnvelope }
        switch value.status {
        case .succeeded:
            guard let receipt = value.receipt, receipt.kind == value.operationKind else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            try validate(receipt)
        case .authenticationRequired, .unavailableBeforeDispatch, .incompatibleBeforeDispatch,
             .rejected, .cancelledBeforeDispatch, .reconciliationRequired:
            guard value.receipt == nil else { throw Phase2AIWorkerWireError.invalidEnvelope }
        }
    }

    private func validate(_ receipt: Phase2AIWorkerModelLifecycleReceiptWire) throws {
        switch receipt {
        case .load(let value):
            guard validIdentifier(value.instanceID),
                  value.loadTimeSeconds.isFinite,
                  value.loadTimeSeconds >= 0
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
            try validate(value.configuration)
        case .unload(let value):
            guard validIdentifier(value.instanceID) else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
        }
    }

    private func validate(_ configuration: Phase2AIWorkerModelLoadConfigurationWire) throws {
        guard (1...Self.maximumContextLength).contains(configuration.contextLength),
              positive(configuration.evaluationBatchSize),
              positive(configuration.expertCount)
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
    }

    private func requireClosedOperationShape(_ object: [String: Any]) throws {
        guard let kind = object["kind"] as? String else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        switch kind {
        case Phase2AIWorkerModelLifecycleOperationKindWire.load.rawValue:
            guard Set(object.keys) == Self.loadOperationKeys else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            try requireIntegerFields(in: object, required: ["contextLength"])
        case Phase2AIWorkerModelLifecycleOperationKindWire.unload.rawValue:
            guard Set(object.keys) == Self.unloadOperationKeys else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
        default:
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
    }

    private func requireClosedReceiptShape(_ object: [String: Any]) throws {
        guard let kind = object["kind"] as? String else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        switch kind {
        case Phase2AIWorkerModelLifecycleOperationKindWire.load.rawValue:
            guard Set(object.keys) == Self.loadReceiptKeys,
                  let configuration = object["configuration"] as? [String: Any]
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
            let keys = Set(configuration.keys)
            guard keys.isSuperset(of: Self.loadConfigurationRequiredKeys),
                  keys.subtracting(Self.loadConfigurationRequiredKeys)
                    .isSubset(of: Self.loadConfigurationOptionalKeys)
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
            try requireIntegerFields(
                in: configuration,
                required: ["contextLength"],
                optional: ["evaluationBatchSize", "expertCount"]
            )
            guard let loadTime = object["loadTimeSeconds"] as? NSNumber,
                  !isBoolean(loadTime)
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
        case Phase2AIWorkerModelLifecycleOperationKindWire.unload.rawValue:
            guard Set(object.keys) == Self.unloadReceiptKeys else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
        default:
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
    }

    private func positive(_ value: Int?) -> Bool { value.map({ $0 > 0 }) ?? true }

    private func validIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty
            && bytes.count <= Self.maximumIdentifierBytes
            && !bytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
    }

    private func encode<Value: Encodable>(_ value: Value, ceiling: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        try requireBound(data, ceiling: ceiling)
        return data
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        return value
    }

    private func requireObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        return object
    }

    private func requireIntegerFields(
        in object: [String: Any],
        required: [String],
        optional: [String] = []
    ) throws {
        for key in required {
            guard let value = object[key] else { throw Phase2AIWorkerWireError.invalidEnvelope }
            try requireInteger(value)
        }
        for key in optional {
            if let value = object[key] { try requireInteger(value) }
        }
    }

    private func requireInteger(_ value: Any) throws {
        guard let number = value as? NSNumber, !isBoolean(number) else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        let encoding = String(cString: number.objCType)
        guard encoding != "f", encoding != "d" else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func requireCanonicalUUIDs(in object: [String: Any]) throws {
        for key in ["effectID", "profileID"] {
            guard let encoded = object[key] as? String,
                  let value = UUID(uuidString: encoded),
                  encoded == value.uuidString
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
        }
    }

    private func requireBound(_ data: Data, ceiling: Int) throws {
        guard data.count <= ceiling else { throw Phase2AIWorkerWireError.envelopeTooLarge }
    }

    private func requireCurrent(_ version: Int) throws {
        guard version == Self.schemaVersion else {
            throw Phase2AIWorkerWireError.unsupportedProtocolVersion(version)
        }
    }

    private func requireNoDuplicateObjectKeys(_ data: Data) throws {
        var scanner = Phase2LifecycleJSONKeyScanner(data: data)
        try scanner.validate()
    }
}

private struct Phase2LifecycleJSONKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        skipWhitespace()
        try scanValue()
        skipWhitespace()
        guard index == bytes.count else { throw Phase2AIWorkerWireError.malformedEnvelope }
    }

    private mutating func scanValue() throws {
        skipWhitespace()
        guard index < bytes.count else { throw Phase2AIWorkerWireError.malformedEnvelope }
        switch bytes[index] {
        case UInt8(ascii: "{"): try scanObject()
        case UInt8(ascii: "["): try scanArray()
        case UInt8(ascii: "\""): _ = try scanString()
        default: try scanPrimitive()
        }
    }

    private mutating func scanObject() throws {
        index += 1
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let keyData = try scanString()
            guard let key = try? JSONDecoder().decode(String.self, from: keyData),
                  keys.insert(key).inserted
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else {
                throw Phase2AIWorkerWireError.malformedEnvelope
            }
            try scanValue()
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return }
            guard consume(UInt8(ascii: ",")) else {
                throw Phase2AIWorkerWireError.malformedEnvelope
            }
        }
    }

    private mutating func scanArray() throws {
        index += 1
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return }
        while true {
            try scanValue()
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return }
            guard consume(UInt8(ascii: ",")) else {
                throw Phase2AIWorkerWireError.malformedEnvelope
            }
        }
    }

    private mutating func scanString() throws -> Data {
        let start = index
        guard consume(UInt8(ascii: "\"")) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                return Data(bytes[start..<index])
            }
        }
        throw Phase2AIWorkerWireError.malformedEnvelope
    }

    private mutating func scanPrimitive() throws {
        let start = index
        while index < bytes.count,
              ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), 9, 10, 13, 32]
                .contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw Phase2AIWorkerWireError.malformedEnvelope }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

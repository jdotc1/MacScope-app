import Foundation

struct Phase2AIWorkerModelDiscoveryWireCodec: Sendable {
    static let schemaVersion = 1
    static let maximumRequestEnvelopeBytes = 2_048
    static let maximumReplyEnvelopeBytes = 2_097_152
    static let maximumModels = 512
    static let maximumInstancesPerModel = 32
    static let maximumIdentifierBytes = 512
    static let maximumCompactMetadataBytes = 512
    static let maximumDescriptiveMetadataBytes = 1_024
    static let maximumVariantsOrOptions = 64
    static let maximumAggregateStringBytes = 1_048_576

    private static let requestKeys: Set<String> = [
        "schemaVersion", "requestID", "profileID", "generation", "endpointOrigin",
        "requestTimeoutMilliseconds", "resourceTimeoutMilliseconds",
    ]
    private static let replyKeys: Set<String> = [
        "schemaVersion", "requestID", "profileID", "generation", "status",
    ]
    private static let inventoryKeys: Set<String> = ["models"]
    private static let modelRequiredKeys: Set<String> = [
        "type", "publisher", "key", "displayName", "sizeBytes", "loadedInstances",
        "maximumContextLength", "variants",
    ]
    private static let modelOptionalKeys: Set<String> = [
        "architecture", "quantization", "parameters", "format", "capabilities", "summary",
        "selectedVariant",
    ]
    private static let quantizationKeys: Set<String> = ["name", "bitsPerWeight"]
    private static let instanceKeys: Set<String> = ["id", "configuration"]
    private static let instanceConfigurationRequiredKeys: Set<String> = ["contextLength"]
    private static let instanceConfigurationOptionalKeys: Set<String> = [
        "evaluationBatchSize", "parallelPredictions", "flashAttention", "expertCount",
        "offloadsKVCacheToGPU",
    ]
    private static let capabilitiesRequiredKeys: Set<String> = ["vision", "trainedForToolUse"]
    private static let capabilitiesOptionalKeys: Set<String> = ["reasoning"]
    private static let reasoningKeys: Set<String> = ["allowedOptions", "defaultOption"]

    func encodeRequest(_ value: Phase2AIWorkerModelDiscoveryRequest) throws -> Data {
        try validate(value)
        return try encode(value, ceiling: Self.maximumRequestEnvelopeBytes)
    }

    func decodeRequest(_ data: Data) throws -> Phase2AIWorkerModelDiscoveryRequest {
        try requireBound(data, ceiling: Self.maximumRequestEnvelopeBytes)
        try requireNoDuplicateObjectKeys(data)
        let object = try requireObject(data)
        guard Set(object.keys) == Self.requestKeys || (Set(object.keys) == Self.requestKeys.union(["inferencePolicy"])
            && Phase2AIWorkerConfigurationWireCodec.hasClosedPolicy(object["inferencePolicy"])) else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        try requireIntegerFields(
            in: object,
            required: [
                "schemaVersion", "generation", "requestTimeoutMilliseconds",
                "resourceTimeoutMilliseconds",
            ]
        )
        try requireCanonicalUUIDs(in: object)
        let value: Phase2AIWorkerModelDiscoveryRequest = try decode(data)
        try validate(value)
        return value
    }

    func encodeReply(_ value: Phase2AIWorkerModelDiscoveryReply) throws -> Data {
        try validate(value)
        return try encode(value, ceiling: Self.maximumReplyEnvelopeBytes)
    }

    func decodeReply(_ data: Data) throws -> Phase2AIWorkerModelDiscoveryReply {
        try requireBound(data, ceiling: Self.maximumReplyEnvelopeBytes)
        try requireNoDuplicateObjectKeys(data)
        let object = try requireObject(data)
        try requireClosedReplyShape(object)
        try requireCanonicalUUIDs(in: object)
        let value: Phase2AIWorkerModelDiscoveryReply = try decode(data)
        try validate(value)
        return value
    }

    private func validate(_ value: Phase2AIWorkerModelDiscoveryRequest) throws {
        try requireCurrent(value.schemaVersion)
        guard value.generation > 0,
              value.endpointOrigin.utf8.count <= 128,
              Phase2AIWorkerConfigurationValidation.isCanonicalLoopbackOrigin(value.endpointOrigin),
              value.inferencePolicy?.isValid != false,
              (1_000...(value.inferencePolicy == nil ? 30_000 : 900_000)).contains(value.requestTimeoutMilliseconds),
              (1_000...(value.inferencePolicy == nil ? 120_000 : 1_800_000)).contains(value.resourceTimeoutMilliseconds),
              value.resourceTimeoutMilliseconds >= value.requestTimeoutMilliseconds
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
    }

    private func validate(_ value: Phase2AIWorkerModelDiscoveryReply) throws {
        try requireCurrent(value.schemaVersion)
        guard value.generation > 0 else { throw Phase2AIWorkerWireError.invalidEnvelope }
        switch value.status {
        case .success:
            guard let inventory = value.inventory else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            try validate(inventory)
        case .authenticationRequired, .unavailable, .incompatible, .cancelled:
            guard value.inventory == nil else { throw Phase2AIWorkerWireError.invalidEnvelope }
        }
    }

    private func validate(_ inventory: Phase2AIWorkerModelInventoryWire) throws {
        guard inventory.models.count <= Self.maximumModels else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        var modelKeys: Set<String> = []
        var instanceIDs: Set<String> = []
        var aggregateStringBytes = 0
        for model in inventory.models {
            guard modelKeys.insert(model.key).inserted else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            try validate(model)
            try addStrings(in: model, aggregate: &aggregateStringBytes)
            for instance in model.loadedInstances {
                guard instanceIDs.insert(instance.id).inserted else {
                    throw Phase2AIWorkerWireError.invalidEnvelope
                }
            }
        }
    }

    private func validate(_ model: Phase2AIWorkerModelWire) throws {
        guard validCompactMetadata(model.publisher),
              validIdentifier(model.key),
              validDescriptiveMetadata(model.displayName),
              validOptionalCompactMetadata(model.architecture),
              validOptionalCompactMetadata(model.parameters),
              validOptionalDescriptiveMetadata(model.summary),
              (1...4_194_304).contains(model.maximumContextLength),
              model.loadedInstances.count <= Self.maximumInstancesPerModel,
              model.variants.count <= Self.maximumVariantsOrOptions,
              model.variants.allSatisfy(validIdentifier),
              model.selectedVariant.map(validIdentifier) ?? true,
              model.selectedVariant.map({ model.variants.contains($0) }) ?? true
        else { throw Phase2AIWorkerWireError.invalidEnvelope }

        if let quantization = model.quantization {
            guard validOptionalCompactMetadata(quantization.name),
                  quantization.bitsPerWeight.map({ $0.isFinite && $0 >= 0 }) ?? true
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
        }
        for instance in model.loadedInstances {
            try validate(instance, maximumContextLength: model.maximumContextLength)
        }
        if let capabilities = model.capabilities { try validate(capabilities) }
    }

    private func validate(
        _ instance: Phase2AIWorkerModelInstanceWire,
        maximumContextLength: Int
    ) throws {
        let configuration = instance.configuration
        guard validIdentifier(instance.id),
              configuration.contextLength > 0,
              configuration.contextLength <= maximumContextLength,
              positive(configuration.evaluationBatchSize),
              positive(configuration.parallelPredictions),
              positive(configuration.expertCount)
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
    }

    private func validate(_ capabilities: Phase2AIWorkerModelCapabilitiesWire) throws {
        guard let reasoning = capabilities.reasoning else { return }
        let known = Set(["off", "on", "low", "medium", "high"])
        guard !reasoning.allowedOptions.isEmpty,
              reasoning.allowedOptions.count <= Self.maximumVariantsOrOptions,
              reasoning.allowedOptions.allSatisfy({ known.contains($0) }),
              reasoning.allowedOptions.contains(reasoning.defaultOption)
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
    }

    private func positive(_ value: Int?) -> Bool { value.map({ $0 > 0 }) ?? true }

    private func validIdentifier(_ value: String) -> Bool {
        valid(value, maximumBytes: Self.maximumIdentifierBytes)
    }

    private func validCompactMetadata(_ value: String) -> Bool {
        valid(value, maximumBytes: Self.maximumCompactMetadataBytes)
    }

    private func validDescriptiveMetadata(_ value: String) -> Bool {
        valid(value, maximumBytes: Self.maximumDescriptiveMetadataBytes)
    }

    private func validOptionalCompactMetadata(_ value: String?) -> Bool {
        value.map { valid($0, maximumBytes: Self.maximumCompactMetadataBytes, allowsEmpty: true) }
            ?? true
    }

    private func validOptionalDescriptiveMetadata(_ value: String?) -> Bool {
        value.map {
            valid($0, maximumBytes: Self.maximumDescriptiveMetadataBytes, allowsEmpty: true)
        } ?? true
    }

    private func valid(
        _ value: String,
        maximumBytes: Int,
        allowsEmpty: Bool = false
    ) -> Bool {
        let bytes = value.utf8
        return (allowsEmpty || !bytes.isEmpty)
            && bytes.count <= maximumBytes
            && !bytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
    }

    private func addStrings(
        in model: Phase2AIWorkerModelWire,
        aggregate: inout Int
    ) throws {
        try add(model.type.rawValue, aggregate: &aggregate)
        try add(model.publisher, aggregate: &aggregate)
        try add(model.key, aggregate: &aggregate)
        try add(model.displayName, aggregate: &aggregate)
        try add(model.architecture, aggregate: &aggregate)
        try add(model.quantization?.name, aggregate: &aggregate)
        try add(model.parameters, aggregate: &aggregate)
        for instance in model.loadedInstances {
            try add(instance.id, aggregate: &aggregate)
        }
        try add(model.format?.rawValue, aggregate: &aggregate)
        if let reasoning = model.capabilities?.reasoning {
            for option in reasoning.allowedOptions {
                try add(option, aggregate: &aggregate)
            }
            try add(reasoning.defaultOption, aggregate: &aggregate)
        }
        try add(model.summary, aggregate: &aggregate)
        for variant in model.variants {
            try add(variant, aggregate: &aggregate)
        }
        try add(model.selectedVariant, aggregate: &aggregate)
    }

    private func add(_ value: String?, aggregate: inout Int) throws {
        guard let value else { return }
        let (total, overflow) = aggregate.addingReportingOverflow(value.utf8.count)
        guard !overflow, total <= Self.maximumAggregateStringBytes else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        aggregate = total
    }

    private func requireClosedReplyShape(_ object: [String: Any]) throws {
        try requireIntegerFields(in: object, required: ["schemaVersion", "generation"])
        let expectedReplyKeys = Self.replyKeys.union(object["inventory"] == nil ? [] : ["inventory"])
        guard Set(object.keys) == expectedReplyKeys else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        guard let inventory = object["inventory"] else { return }
        guard let inventoryObject = inventory as? [String: Any],
              Set(inventoryObject.keys) == Self.inventoryKeys,
              let models = inventoryObject["models"] as? [[String: Any]]
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
        for model in models {
            try requireIntegerFields(
                in: model,
                required: ["sizeBytes", "maximumContextLength"]
            )
            let modelKeys = Set(model.keys)
            guard modelKeys.isSuperset(of: Self.modelRequiredKeys),
                  modelKeys.subtracting(Self.modelRequiredKeys).isSubset(of: Self.modelOptionalKeys),
                  let instances = model["loadedInstances"] as? [[String: Any]]
            else { throw Phase2AIWorkerWireError.invalidEnvelope }
            if let quantization = model["quantization"] {
                guard let object = quantization as? [String: Any],
                      Set(object.keys).isSubset(of: Self.quantizationKeys)
                else { throw Phase2AIWorkerWireError.invalidEnvelope }
            }
            if let capabilities = model["capabilities"] {
                guard let object = capabilities as? [String: Any] else {
                    throw Phase2AIWorkerWireError.invalidEnvelope
                }
                let keys = Set(object.keys)
                guard keys.isSuperset(of: Self.capabilitiesRequiredKeys),
                      keys.subtracting(Self.capabilitiesRequiredKeys)
                        .isSubset(of: Self.capabilitiesOptionalKeys)
                else { throw Phase2AIWorkerWireError.invalidEnvelope }
                if let reasoning = object["reasoning"] {
                    guard let reasoningObject = reasoning as? [String: Any],
                          Set(reasoningObject.keys) == Self.reasoningKeys
                    else { throw Phase2AIWorkerWireError.invalidEnvelope }
                }
            }
            for instance in instances {
                guard Set(instance.keys) == Self.instanceKeys,
                      let configuration = instance["configuration"] as? [String: Any]
                else { throw Phase2AIWorkerWireError.invalidEnvelope }
                let keys = Set(configuration.keys)
                guard keys.isSuperset(of: Self.instanceConfigurationRequiredKeys),
                      keys.subtracting(Self.instanceConfigurationRequiredKeys)
                        .isSubset(of: Self.instanceConfigurationOptionalKeys)
                else { throw Phase2AIWorkerWireError.invalidEnvelope }
                try requireIntegerFields(
                    in: configuration,
                    required: ["contextLength"],
                    optional: [
                        "evaluationBatchSize", "parallelPredictions", "expertCount",
                    ]
                )
            }
        }
    }

    private func requireIntegerFields(
        in object: [String: Any],
        required: [String],
        optional: [String] = []
    ) throws {
        for key in required {
            guard let value = object[key] else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            try requireInteger(value)
        }
        for key in optional {
            if let value = object[key] { try requireInteger(value) }
        }
    }

    private func requireInteger(_ value: Any) throws {
        guard let number = value as? NSNumber else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        let encoding = String(cString: number.objCType)
        guard encoding != "f", encoding != "d" else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
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

    private func requireCanonicalUUIDs(in object: [String: Any]) throws {
        for key in ["requestID", "profileID"] {
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
        do {
            var scanner = Phase2DiscoveryJSONKeyScanner(data: data)
            try scanner.validate()
        } catch let error as Phase2AIWorkerWireError {
            throw error
        } catch {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
    }
}

private struct Phase2DiscoveryJSONKeyScanner {
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

import Foundation

enum Phase2NativeModelCatalogDecodingError: Error, Equatable, Sendable {
    case envelopeByteLimitExceeded
    case invalidUTF8
    case malformedJSON
    case duplicateJSONKey
    case invalidSchema
    case modelLimitExceeded
    case loadedInstanceLimitExceeded
    case duplicateModelKey
    case duplicateInstanceID
    case stringByteLimitExceeded
    case aggregateStringByteLimitExceeded
    case invalidNumericValue
    case invalidContextLength
}

enum Phase2NativeModelKind: String, Decodable, Equatable, Sendable {
    case llm
    case embedding
}

enum Phase2NativeModelFormat: String, Decodable, Equatable, Sendable {
    case gguf
    case mlx
}

enum Phase2NativeReasoningOption: String, Decodable, Equatable, Sendable {
    case off
    case on
    case low
    case medium
    case high
}

struct Phase2NativeModelQuantization: Equatable, Sendable {
    let name: String?
    let bitsPerWeight: Double?
}

struct Phase2NativeModelReasoningConfiguration: Equatable, Sendable {
    let allowedOptions: [Phase2NativeReasoningOption]
    let defaultOption: Phase2NativeReasoningOption
}

struct Phase2NativeModelCapabilities: Equatable, Sendable {
    let supportsVision: Bool
    let trainedForToolUse: Bool
    let reasoning: Phase2NativeModelReasoningConfiguration?
}

struct Phase2NativeLoadedModelConfiguration: Equatable, Sendable {
    let contextLength: Int
    let evaluationBatchSize: Int?
    let parallelPredictions: Int?
    let flashAttention: Bool?
    let expertCount: Int?
    let offloadsKVCacheToGPU: Bool?
}

struct Phase2NativeLoadedModelInstance: Equatable, Sendable {
    let id: String
    let configuration: Phase2NativeLoadedModelConfiguration
}

struct Phase2NativeModel: Equatable, Sendable {
    let kind: Phase2NativeModelKind
    let publisher: String
    let key: String
    let displayName: String
    let architecture: String?
    let quantization: Phase2NativeModelQuantization?
    let sizeBytes: UInt64
    let parameters: String?
    let loadedInstances: [Phase2NativeLoadedModelInstance]
    let maximumContextLength: Int
    let format: Phase2NativeModelFormat?
    let capabilities: Phase2NativeModelCapabilities?
    let description: String?
    let variants: [String]?
    let selectedVariant: String?

    var isChatCompletionsEligible: Bool { kind == .llm }
}

struct Phase2NativeModelCatalog: Equatable, Sendable {
    let models: [Phase2NativeModel]
}

struct Phase2NativeModelCatalogDecoder: Sendable {
    static let maximumEnvelopeBytes = 2 * 1_024 * 1_024
    static let maximumModels = 512
    static let maximumLoadedInstancesPerModel = 32
    static let maximumIdentifierBytes = 512
    static let maximumCompactMetadataStringBytes = 512
    static let maximumMetadataStringBytes = 1_024
    static let maximumVariants = 64
    static let maximumReasoningOptions = 64
    static let maximumAggregateStringBytes = 1 * 1_024 * 1_024
    static let maximumContextLength = 4_194_304
    static let maximumJSONDepth = 32

    func decode(_ data: Data) throws -> Phase2NativeModelCatalog {
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw Phase2NativeModelCatalogDecodingError.envelopeByteLimitExceeded
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw Phase2NativeModelCatalogDecodingError.invalidUTF8
        }
        do {
            var validator = StrictJSONDuplicateKeyValidator(
                data: data,
                maximumDepth: Self.maximumJSONDepth
            )
            try validator.validate()
        } catch StrictJSONDuplicateKeyValidator.Failure.duplicateKey {
            throw Phase2NativeModelCatalogDecodingError.duplicateJSONKey
        } catch StrictJSONDuplicateKeyValidator.Failure.invalidIntegerLexeme {
            throw Phase2NativeModelCatalogDecodingError.invalidSchema
        } catch StrictJSONDuplicateKeyValidator.Failure.depthLimitExceeded {
            throw Phase2NativeModelCatalogDecodingError.invalidSchema
        } catch {
            throw Phase2NativeModelCatalogDecodingError.malformedJSON
        }

        let wireCatalog: WireCatalog
        do {
            wireCatalog = try JSONDecoder().decode(WireCatalog.self, from: data)
        } catch {
            throw Phase2NativeModelCatalogDecodingError.invalidSchema
        }
        guard wireCatalog.models.count <= Self.maximumModels else {
            throw Phase2NativeModelCatalogDecodingError.modelLimitExceeded
        }

        var aggregateStringBytes = 0
        var modelKeys: Set<String> = []
        var instanceIDs: Set<String> = []
        var models: [Phase2NativeModel] = []
        models.reserveCapacity(wireCatalog.models.count)

        for wire in wireCatalog.models {
            try validateIdentifier(wire.key, aggregate: &aggregateStringBytes)
            guard modelKeys.insert(wire.key).inserted else {
                throw Phase2NativeModelCatalogDecodingError.duplicateModelKey
            }
            try validateRequiredCompactMetadata(wire.publisher, aggregate: &aggregateStringBytes)
            try validateRequiredMetadata(wire.displayName, aggregate: &aggregateStringBytes)
            try validateOptionalCompactMetadata(wire.architecture, aggregate: &aggregateStringBytes)
            try validateOptionalCompactMetadata(wire.parameters, aggregate: &aggregateStringBytes)
            try validateOptionalMetadata(wire.description, aggregate: &aggregateStringBytes)
            try addString(wire.kind.rawValue, limit: Self.maximumCompactMetadataStringBytes, aggregate: &aggregateStringBytes)
            if let format = wire.format {
                try addString(format.rawValue, limit: Self.maximumCompactMetadataStringBytes, aggregate: &aggregateStringBytes)
            }

            guard (1 ... Self.maximumContextLength).contains(wire.maximumContextLength) else {
                throw Phase2NativeModelCatalogDecodingError.invalidContextLength
            }
            guard wire.loadedInstances.count <= Self.maximumLoadedInstancesPerModel else {
                throw Phase2NativeModelCatalogDecodingError.loadedInstanceLimitExceeded
            }

            var loadedInstances: [Phase2NativeLoadedModelInstance] = []
            loadedInstances.reserveCapacity(wire.loadedInstances.count)
            for instance in wire.loadedInstances {
                try validateIdentifier(instance.id, aggregate: &aggregateStringBytes)
                guard instanceIDs.insert(instance.id).inserted else {
                    throw Phase2NativeModelCatalogDecodingError.duplicateInstanceID
                }
                let config = instance.configuration
                guard config.contextLength > 0,
                      config.contextLength <= wire.maximumContextLength
                else {
                    throw Phase2NativeModelCatalogDecodingError.invalidContextLength
                }
                try validatePositive(config.evaluationBatchSize)
                try validatePositive(config.parallelPredictions)
                try validatePositive(config.expertCount)
                loadedInstances.append(
                    .init(
                        id: instance.id,
                        configuration: .init(
                            contextLength: config.contextLength,
                            evaluationBatchSize: config.evaluationBatchSize,
                            parallelPredictions: config.parallelPredictions,
                            flashAttention: config.flashAttention,
                            expertCount: config.expertCount,
                            offloadsKVCacheToGPU: config.offloadsKVCacheToGPU
                        )
                    )
                )
            }

            var quantization: Phase2NativeModelQuantization?
            if let value = wire.quantization {
                try validateOptionalCompactMetadata(value.name, aggregate: &aggregateStringBytes)
                if let bits = value.bitsPerWeight, !bits.isFinite || bits < 0 {
                    throw Phase2NativeModelCatalogDecodingError.invalidNumericValue
                }
                quantization = .init(name: value.name, bitsPerWeight: value.bitsPerWeight)
            }

            var capabilities: Phase2NativeModelCapabilities?
            if let value = wire.capabilities {
                var reasoning: Phase2NativeModelReasoningConfiguration?
                if let value = value.reasoning {
                    guard value.allowedOptions.count <= Self.maximumReasoningOptions,
                          value.allowedOptions.contains(value.defaultOption)
                    else {
                        throw Phase2NativeModelCatalogDecodingError.invalidSchema
                    }
                    for option in value.allowedOptions {
                        try addString(option.rawValue, limit: Self.maximumMetadataStringBytes, aggregate: &aggregateStringBytes)
                    }
                    try addString(value.defaultOption.rawValue, limit: Self.maximumMetadataStringBytes, aggregate: &aggregateStringBytes)
                    reasoning = .init(
                        allowedOptions: value.allowedOptions,
                        defaultOption: value.defaultOption
                    )
                }
                capabilities = .init(
                    supportsVision: value.supportsVision,
                    trainedForToolUse: value.trainedForToolUse,
                    reasoning: reasoning
                )
            }

            if let variants = wire.variants {
                guard variants.count <= Self.maximumVariants else {
                    throw Phase2NativeModelCatalogDecodingError.invalidSchema
                }
                for variant in variants {
                    try validateIdentifier(variant, aggregate: &aggregateStringBytes)
                }
            }
            if let selectedVariant = wire.selectedVariant {
                try validateIdentifier(selectedVariant, aggregate: &aggregateStringBytes)
                guard let variants = wire.variants, variants.contains(selectedVariant) else {
                    throw Phase2NativeModelCatalogDecodingError.invalidSchema
                }
            }

            models.append(
                .init(
                    kind: wire.kind,
                    publisher: wire.publisher,
                    key: wire.key,
                    displayName: wire.displayName,
                    architecture: wire.architecture,
                    quantization: quantization,
                    sizeBytes: wire.sizeBytes,
                    parameters: wire.parameters,
                    loadedInstances: loadedInstances.sorted { unicodeScalarOrder($0.id, $1.id) },
                    maximumContextLength: wire.maximumContextLength,
                    format: wire.format,
                    capabilities: capabilities,
                    description: wire.description,
                    variants: wire.variants,
                    selectedVariant: wire.selectedVariant
                )
            )
        }

        return .init(models: models.sorted { unicodeScalarOrder($0.key, $1.key) })
    }

    private func validateIdentifier(_ value: String, aggregate: inout Int) throws {
        guard !value.isEmpty else { throw Phase2NativeModelCatalogDecodingError.invalidSchema }
        try addString(value, limit: Self.maximumIdentifierBytes, aggregate: &aggregate)
    }

    private func validateRequiredCompactMetadata(_ value: String, aggregate: inout Int) throws {
        guard !value.isEmpty else { throw Phase2NativeModelCatalogDecodingError.invalidSchema }
        try addString(value, limit: Self.maximumCompactMetadataStringBytes, aggregate: &aggregate)
    }

    private func validateRequiredMetadata(_ value: String, aggregate: inout Int) throws {
        guard !value.isEmpty else { throw Phase2NativeModelCatalogDecodingError.invalidSchema }
        try validateMetadata(value, aggregate: &aggregate)
    }

    private func validateMetadata(_ value: String, aggregate: inout Int) throws {
        try addString(value, limit: Self.maximumMetadataStringBytes, aggregate: &aggregate)
    }

    private func validateOptionalCompactMetadata(_ value: String?, aggregate: inout Int) throws {
        if let value {
            try addString(value, limit: Self.maximumCompactMetadataStringBytes, aggregate: &aggregate)
        }
    }

    private func validateOptionalMetadata(_ value: String?, aggregate: inout Int) throws {
        if let value {
            try validateMetadata(value, aggregate: &aggregate)
        }
    }

    private func addString(_ value: String, limit: Int, aggregate: inout Int) throws {
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw Phase2NativeModelCatalogDecodingError.invalidSchema
        }
        let count = value.utf8.count
        guard count <= limit else {
            throw Phase2NativeModelCatalogDecodingError.stringByteLimitExceeded
        }
        let (newAggregate, overflow) = aggregate.addingReportingOverflow(count)
        guard !overflow, newAggregate <= Self.maximumAggregateStringBytes else {
            throw Phase2NativeModelCatalogDecodingError.aggregateStringByteLimitExceeded
        }
        aggregate = newAggregate
    }

    private func validatePositive(_ value: Int?) throws {
        if let value, value <= 0 {
            throw Phase2NativeModelCatalogDecodingError.invalidNumericValue
        }
    }

    private func unicodeScalarOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(
            rhs.unicodeScalars.map(\.value)
        )
    }
}

private struct WireCatalog: Decodable {
    let models: [WireModel]
}

private struct WireModel: Decodable {
    let kind: Phase2NativeModelKind
    let publisher: String
    let key: String
    let displayName: String
    let architecture: String?
    let quantization: WireQuantization?
    let sizeBytes: UInt64
    let parameters: String?
    let loadedInstances: [WireLoadedInstance]
    let maximumContextLength: Int
    let format: Phase2NativeModelFormat?
    let capabilities: WireCapabilities?
    let description: String?
    let variants: [String]?
    let selectedVariant: String?

    enum CodingKeys: String, CodingKey {
        case kind = "type"
        case publisher
        case key
        case displayName = "display_name"
        case architecture
        case quantization
        case sizeBytes = "size_bytes"
        case parameters = "params_string"
        case loadedInstances = "loaded_instances"
        case maximumContextLength = "max_context_length"
        case format
        case capabilities
        case description
        case variants
        case selectedVariant = "selected_variant"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Phase2NativeModelKind.self, forKey: .kind)
        publisher = try container.decode(String.self, forKey: .publisher)
        key = try container.decode(String.self, forKey: .key)
        displayName = try container.decode(String.self, forKey: .displayName)
        architecture = try container.decodeIfPresent(String.self, forKey: .architecture)
        guard container.contains(.quantization), container.contains(.parameters), container.contains(.format) else {
            throw DecodingError.keyNotFound(
                CodingKeys.quantization,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing required nullable model field")
            )
        }
        quantization = try container.decodeIfPresent(WireQuantization.self, forKey: .quantization)
        sizeBytes = try container.decode(UInt64.self, forKey: .sizeBytes)
        parameters = try container.decodeIfPresent(String.self, forKey: .parameters)
        loadedInstances = try container.decode([WireLoadedInstance].self, forKey: .loadedInstances)
        maximumContextLength = try container.decode(Int.self, forKey: .maximumContextLength)
        format = try container.decodeIfPresent(Phase2NativeModelFormat.self, forKey: .format)
        capabilities = try container.decodeIfPresent(WireCapabilities.self, forKey: .capabilities)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        variants = try container.decodeIfPresent([String].self, forKey: .variants)
        selectedVariant = try container.decodeIfPresent(String.self, forKey: .selectedVariant)
    }
}

private struct WireQuantization: Decodable {
    let name: String?
    let bitsPerWeight: Double?

    enum CodingKeys: String, CodingKey {
        case name
        case bitsPerWeight = "bits_per_weight"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.name), container.contains(.bitsPerWeight) else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing required nullable quantization field")
            )
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
        bitsPerWeight = try container.decodeIfPresent(Double.self, forKey: .bitsPerWeight)
    }
}

private struct WireLoadedInstance: Decodable {
    let id: String
    let configuration: WireLoadedConfiguration

    enum CodingKeys: String, CodingKey {
        case id
        case configuration = "config"
    }
}

private struct WireLoadedConfiguration: Decodable {
    let contextLength: Int
    let evaluationBatchSize: Int?
    let parallelPredictions: Int?
    let flashAttention: Bool?
    let expertCount: Int?
    let offloadsKVCacheToGPU: Bool?

    enum CodingKeys: String, CodingKey {
        case contextLength = "context_length"
        case evaluationBatchSize = "eval_batch_size"
        case parallelPredictions = "parallel"
        case flashAttention = "flash_attention"
        case expertCount = "num_experts"
        case offloadsKVCacheToGPU = "offload_kv_cache_to_gpu"
    }
}

private struct WireCapabilities: Decodable {
    let supportsVision: Bool
    let trainedForToolUse: Bool
    let reasoning: WireReasoning?

    enum CodingKeys: String, CodingKey {
        case supportsVision = "vision"
        case trainedForToolUse = "trained_for_tool_use"
        case reasoning
    }
}

private struct WireReasoning: Decodable {
    let allowedOptions: [Phase2NativeReasoningOption]
    let defaultOption: Phase2NativeReasoningOption

    enum CodingKeys: String, CodingKey {
        case allowedOptions = "allowed_options"
        case defaultOption = "default"
    }
}

private struct StrictJSONDuplicateKeyValidator {
    enum Failure: Error {
        case malformed
        case duplicateKey
        case invalidIntegerLexeme
        case depthLimitExceeded
    }

    private let bytes: [UInt8]
    private let maximumDepth: Int
    private var index = 0

    init(data: Data, maximumDepth: Int) {
        precondition(maximumDepth >= 0)
        bytes = Array(data)
        self.maximumDepth = maximumDepth
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(at: [], depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw Failure.malformed }
    }

    private mutating func parseValue(at path: [String], depth: Int) throws {
        guard depth <= maximumDepth else { throw Failure.depthLimitExceeded }
        guard index < bytes.count else { throw Failure.malformed }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            try parseObject(at: path, depth: depth)
        case UInt8(ascii: "["):
            try parseArray(at: path, depth: depth)
        case UInt8(ascii: "\""):
            _ = try scanString()
        case UInt8(ascii: "t"):
            try consumeLiteral("true")
        case UInt8(ascii: "f"):
            try consumeLiteral("false")
        case UInt8(ascii: "n"):
            try consumeLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
            try scanNumber(at: path)
        default:
            throw Failure.malformed
        }
    }

    private mutating func parseObject(at path: [String], depth: Int) throws {
        try consume(UInt8(ascii: "{"))
        skipWhitespace()
        if consumeIfPresent(UInt8(ascii: "}")) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let encodedKey = try scanString()
            guard let key = try? JSONDecoder().decode(String.self, from: encodedKey) else {
                throw Failure.malformed
            }
            guard keys.insert(key).inserted else { throw Failure.duplicateKey }
            skipWhitespace()
            try consume(UInt8(ascii: ":"))
            skipWhitespace()
            try parseValue(at: path + [key], depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) { return }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func parseArray(at path: [String], depth: Int) throws {
        try consume(UInt8(ascii: "["))
        skipWhitespace()
        if consumeIfPresent(UInt8(ascii: "]")) { return }
        while true {
            skipWhitespace()
            try parseValue(at: path, depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) { return }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func scanString() throws -> Data {
        let start = index
        try consume(UInt8(ascii: "\""))
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
        throw Failure.malformed
    }

    private mutating func scanNumber(at path: [String]) throws {
        let start = index
        while index < bytes.count,
              ![9, 10, 13, 32, UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw Failure.malformed }
        if isKnownIntegerPath(path), !isIntegerLexeme(bytes[start..<index]) {
            throw Failure.invalidIntegerLexeme
        }
    }

    private func isKnownIntegerPath(_ path: [String]) -> Bool {
        switch path {
        case ["models", "size_bytes"],
             ["models", "max_context_length"],
             ["models", "loaded_instances", "config", "context_length"],
             ["models", "loaded_instances", "config", "eval_batch_size"],
             ["models", "loaded_instances", "config", "parallel"],
             ["models", "loaded_instances", "config", "num_experts"]:
            true
        default:
            false
        }
    }

    private func isIntegerLexeme(_ lexeme: ArraySlice<UInt8>) -> Bool {
        var cursor = lexeme.startIndex
        guard cursor < lexeme.endIndex else { return false }
        if lexeme[cursor] == UInt8(ascii: "-") {
            cursor = lexeme.index(after: cursor)
            guard cursor < lexeme.endIndex else { return false }
        }
        if lexeme[cursor] == UInt8(ascii: "0") {
            return lexeme.index(after: cursor) == lexeme.endIndex
        }
        guard (UInt8(ascii: "1") ... UInt8(ascii: "9")).contains(lexeme[cursor]) else {
            return false
        }
        cursor = lexeme.index(after: cursor)
        while cursor < lexeme.endIndex {
            guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(lexeme[cursor]) else {
                return false
            }
            cursor = lexeme.index(after: cursor)
        }
        return true
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            try consume(byte)
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard consumeIfPresent(byte) else { throw Failure.malformed }
    }

    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
    }
}

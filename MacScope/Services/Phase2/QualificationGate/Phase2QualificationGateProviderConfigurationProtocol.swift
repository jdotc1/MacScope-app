import Foundation

/// Read-only wire vocabulary observed with installed SDK 1.5.0 / llmster 0.0.21-2.
/// This protocol codec has no network, process, credential-discovery, or session authority.
enum Phase2ProviderConfigurationRequest: Equatable, Sendable {
    case listLoaded
    case modelInfo(instanceReference: String)
    case loadConfiguration(instanceReference: String)
    case basePrediction(instanceReference: String, ignoreServerSession: Bool)

    static func authentication(guestNonce: Data, passkeyNonce: Data) throws -> Data {
        guard guestNonce.count == 18, passkeyNonce.count == 18 else {
            throw Phase2ProviderConfigurationProtocolError.schema
        }
        return Phase2ProductionJSONValue.object([
            "authVersion": .integer(1), "clientIdentifier": .string("guest:" + guestNonce.base64EncodedString()),
            "clientPasskey": .string(passkeyNonce.base64EncodedString()),
        ]).canonicalJSONBytes()
    }

    func encoded(callID: Int) throws -> Data {
        guard (0...6).contains(callID) else { throw Phase2ProviderConfigurationProtocolError.callID }
        let endpoint: String
        var parameter: [String: Phase2ProductionJSONValue]?
        switch self {
        case .listLoaded:
            endpoint = "listLoaded"
        case .modelInfo(let reference):
            endpoint = "getModelInfo"
            parameter = try Self.parameter(reference)
            parameter?["throwIfNotFound"] = .bool(true)
        case .loadConfiguration(let reference):
            endpoint = "getLoadConfig"
            parameter = try Self.parameter(reference)
        case .basePrediction(let reference, let ignore):
            endpoint = "getBasePredictionConfig"
            parameter = try Self.parameter(reference)
            // False means the observed default behavior: omit the optional member.
            if ignore { parameter?["ignoreServerSessionConfig"] = .bool(true) }
        }
        var message: [String: Phase2ProductionJSONValue] = [
            "type": .string("rpcCall"), "endpoint": .string(endpoint), "callId": .integer(callID),
        ]
        if let parameter { message["parameter"] = .object(parameter) }
        return Phase2ProductionJSONValue.object(message).canonicalJSONBytes()
    }

    private static func parameter(_ reference: String) throws -> [String: Phase2ProductionJSONValue] {
        guard !reference.isEmpty, reference.utf8.count <= 512,
              !reference.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw Phase2ProviderConfigurationProtocolError.schema
        }
        return ["specifier": .object(["type": .string("instanceReference"), "instanceReference": .string(reference)])]
    }
}

enum Phase2ProviderConfigurationProtocolError: Error, Equatable, Sendable {
    case bounds, schema, authentication, callID, remoteFailure, terminal
}

struct Phase2ProviderConfigurationModelInfo: Equatable, Sendable {
    let fields: [String: Phase2ProductionJSONValue]
    var immutableFields: [String: Phase2ProductionJSONValue] {
        fields.filter { $0.key != "lastUsedTime" && $0.key != "ttlMs" }
    }
    var temporalFields: [String: Phase2ProductionJSONValue] {
        fields.filter { $0.key == "lastUsedTime" || $0.key == "ttlMs" }
    }
}

struct Phase2ProviderConfigurationKV: Equatable, Sendable {
    /// Original typed values are retained; no defaults or performance settings are synthesized.
    let fields: [String: Phase2ProductionJSONValue]
}

enum Phase2ProviderConfigurationReply: Equatable, Sendable {
    case models([Phase2ProviderConfigurationModelInfo])
    case model(Phase2ProviderConfigurationModelInfo)
    case configuration(Phase2ProviderConfigurationKV)
}

struct Phase2ProviderConfigurationProtocolDecoder: Sendable {
    static let maximumMessageBytes = 1_048_576
    private var authenticated = false
    private var failed = false
    private var nextCallID = 0
    private var receivedBytes = 0
    private var receivedMessages = 0

    mutating func authentication(_ data: Data) throws {
        guard !failed else { throw Phase2ProviderConfigurationProtocolError.terminal }
        failed = true
        guard !authenticated else { throw Phase2ProviderConfigurationProtocolError.authentication }
        let value = try parse(data, maximumBytes: 4_096)
        guard let object = value.objectValue, object["success"] == .bool(true),
              Set(object.keys) == ["success"] else { throw Phase2ProviderConfigurationProtocolError.authentication }
        authenticated = true
        failed = false
    }

    mutating func reply(_ data: Data, to request: Phase2ProviderConfigurationRequest, callID: Int) throws
        -> Phase2ProviderConfigurationReply
    {
        guard !failed else { throw Phase2ProviderConfigurationProtocolError.terminal }
        failed = true
        guard authenticated, callID == nextCallID, (0...6).contains(callID) else {
            throw Phase2ProviderConfigurationProtocolError.callID
        }
        let value = try parse(data, maximumBytes: Self.maximumMessageBytes)
        guard let object = value.objectValue, object["callId"] == .integer(callID) else {
            throw Phase2ProviderConfigurationProtocolError.callID
        }
        if object["type"] == .string("rpcError") { throw Phase2ProviderConfigurationProtocolError.remoteFailure }
        guard Set(object.keys) == ["type", "callId", "result"], object["type"] == .string("rpcResult"),
              let result = object["result"] else { throw Phase2ProviderConfigurationProtocolError.schema }
        let decoded: Phase2ProviderConfigurationReply
        switch request {
        case .listLoaded:
            guard let models = result.arrayValue, models.count <= 16 else { throw Phase2ProviderConfigurationProtocolError.bounds }
            decoded = .models(try models.map(Self.model))
        case .modelInfo(let reference):
            let model = try Self.model(result)
            guard model.fields["instanceReference"] == .string(reference) else { throw Phase2ProviderConfigurationProtocolError.schema }
            decoded = .model(model)
        case .loadConfiguration:
            decoded = .configuration(try Self.configuration(result, load: true))
        case .basePrediction:
            decoded = .configuration(try Self.configuration(result, load: false))
        }
        nextCallID += 1
        failed = false
        return decoded
    }

    private mutating func parse(_ data: Data, maximumBytes: Int) throws -> Phase2ProductionJSONValue {
        guard data.count <= maximumBytes, receivedMessages < 8,
              receivedBytes <= 8 * Self.maximumMessageBytes - data.count else {
            throw Phase2ProviderConfigurationProtocolError.bounds
        }
        receivedBytes += data.count
        receivedMessages += 1
        return try Phase2StrictJSONParser().parse(data, limits: .init(
            maximumBytes: maximumBytes, maximumDepth: 16, maximumTokens: 8_192, maximumMembersAndElements: 4_096
        ))
    }

    private static func model(_ value: Phase2ProductionJSONValue) throws -> Phase2ProviderConfigurationModelInfo {
        guard let object = value.objectValue else { throw Phase2ProviderConfigurationProtocolError.schema }
        let strings: Set<String> = ["modelKey", "format", "displayName", "publisher", "path", "indexedModelIdentifier", "identifier", "instanceReference"]
        let integers: Set<String> = ["sizeBytes", "maxContextLength", "contextLength"]
        let optionalStrings: Set<String> = ["paramsString", "architecture", "selectedVariant"]
        let required = strings.union(integers).union(["type", "deviceIdentifier", "ttlMs", "lastUsedTime", "vision", "trainedForToolUse"])
        let allowed = required.union(optionalStrings).union(["quantization", "variants"])
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed),
              object["type"] == .string("llm"),
              strings.allSatisfy({ string(object[$0]) }), integers.allSatisfy({ integer(object[$0]) != nil }),
              optionalStrings.allSatisfy({ object[$0] == nil || string(object[$0]) }),
              object["vision"]?.boolValue != nil, object["trainedForToolUse"]?.boolValue != nil,
              object["deviceIdentifier"] == .null || string(object["deviceIdentifier"]),
              ["ttlMs", "lastUsedTime"].allSatisfy({ object[$0] == .null || number(object[$0]) }) else {
            throw Phase2ProviderConfigurationProtocolError.schema
        }
        if let quantization = object["quantization"] {
            guard let q = quantization.objectValue, Set(q.keys) == ["name", "bits"],
                  string(q["name"]), integer(q["bits"]) != nil else { throw Phase2ProviderConfigurationProtocolError.schema }
        }
        if let variants = object["variants"] {
            guard let values = variants.arrayValue, values.count <= 128, values.allSatisfy({ string($0) }) else {
                throw Phase2ProviderConfigurationProtocolError.schema
            }
        }
        return .init(fields: object)
    }

    private static func configuration(_ value: Phase2ProductionJSONValue, load: Bool) throws -> Phase2ProviderConfigurationKV {
        guard let object = value.objectValue, Set(object.keys) == ["fields"],
              let entries = object["fields"]?.arrayValue, entries.count <= 128 else {
            throw Phase2ProviderConfigurationProtocolError.schema
        }
        var fields: [String: Phase2ProductionJSONValue] = [:]
        for entry in entries {
            guard let field = entry.objectValue, Set(field.keys) == ["key", "value"],
                  let key = field["key"]?.stringValue, key.utf8.count <= 256,
                  let value = field["value"], fields[key] == nil else { throw Phase2ProviderConfigurationProtocolError.schema }
            fields[key] = value
        }
        let loadKeys: Set<String> = ["llm.load.contextLength", "llm.load.numParallelSessions", "llm.load.llama.acceleration.offloadRatio", "llm.load.llama.autoFit", "llm.load.llama.cpuThreadPoolSize", "llm.load.llama.tryDirectIO", "llm.load.mlx.autoFit"]
        let baseKeys: Set<String> = ["llm.prediction.llama.cpuThreads", "llm.prediction.promptTemplate", "llm.prediction.reasoning.enableThinking", "llm.prediction.repeatPenalty", "llm.prediction.temperature", "llm.prediction.topPSampling"]
        guard Set(fields.keys) == (load ? loadKeys : baseKeys) else { throw Phase2ProviderConfigurationProtocolError.schema }
        if load {
            guard ["llm.load.contextLength", "llm.load.numParallelSessions", "llm.load.llama.cpuThreadPoolSize"].allSatisfy({ integer(fields[$0]) != nil }),
                  number(fields["llm.load.llama.acceleration.offloadRatio"]),
                  ["llm.load.llama.autoFit", "llm.load.llama.tryDirectIO", "llm.load.mlx.autoFit"].allSatisfy({ fields[$0]?.boolValue != nil }) else {
                throw Phase2ProviderConfigurationProtocolError.schema
            }
        } else {
            guard integer(fields["llm.prediction.llama.cpuThreads"]) != nil,
                  fields["llm.prediction.reasoning.enableThinking"]?.boolValue != nil,
                  number(fields["llm.prediction.temperature"]),
                  checkedNumber(fields["llm.prediction.repeatPenalty"]), checkedNumber(fields["llm.prediction.topPSampling"]),
                  let template = fields["llm.prediction.promptTemplate"]?.objectValue,
                  Set(template.keys) == ["type", "jinjaPromptTemplate", "stopStrings"], template["type"] == .string("jinja"),
                  let jinja = template["jinjaPromptTemplate"]?.objectValue, Set(jinja.keys) == ["template"],
                  let text = jinja["template"]?.stringValue, text.utf8.count <= 65_536,
                  let stops = template["stopStrings"]?.arrayValue, stops.count <= 128, stops.allSatisfy({ string($0) }) else {
                throw Phase2ProviderConfigurationProtocolError.schema
            }
        }
        return .init(fields: fields)
    }

    private static func checkedNumber(_ value: Phase2ProductionJSONValue?) -> Bool {
        guard let object = value?.objectValue else { return false }
        return Set(object.keys) == ["checked", "value"] && object["checked"]?.boolValue != nil && number(object["value"])
    }
    private static func string(_ value: Phase2ProductionJSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return text.utf8.count <= 16_384
    }
    private static func number(_ value: Phase2ProductionJSONValue?) -> Bool {
        guard let value, case .number(let text) = value, let number = Double(text) else { return false }
        return number.isFinite
    }
    private static func integer(_ value: Phase2ProductionJSONValue?) -> Int? {
        guard let value, case .number(let text) = value, let number = Int(text), number >= 0 else { return nil }
        return number
    }
}

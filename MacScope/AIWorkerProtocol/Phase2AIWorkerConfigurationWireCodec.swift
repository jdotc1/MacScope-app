import Foundation

/// Strict codec for the small, closed configuration control plane.
struct Phase2AIWorkerConfigurationWireCodec: Sendable {
    static let schemaVersion = 1
    static let maximumEnvelopeBytes = 4_096
    static let structuralJSONLimits = Phase2AIWorkerWireJSONLimits(
        maximumDepth: 3,
        maximumTokens: 128,
        maximumMembersAndElements: 32
    )

    private static let configurationKeys: Set<String> = [
        "schemaVersion", "profileID", "generation", "endpointOrigin", "model",
        "protocolManifestDigest", "maximumTokens", "requestTimeoutMilliseconds",
        "resourceTimeoutMilliseconds",
    ]
    private static let acknowledgementKeys: Set<String> = [
        "schemaVersion", "profileID", "generation", "protocolManifestDigest", "status",
    ]

    func encodeConfiguration(_ value: Phase2AIWorkerConfigurationWire) throws -> Data {
        try validate(value)
        return try encode(value)
    }

    func decodeConfiguration(_ data: Data) throws -> Phase2AIWorkerConfigurationWire {
        try requireExactKeys(data, expected: Self.configurationKeys, allowsPolicy: true)
        let value: Phase2AIWorkerConfigurationWire = try decode(data)
        try validate(value)
        return value
    }

    func encodeAcknowledgement(
        _ value: Phase2AIWorkerConfigurationAcknowledgement
    ) throws -> Data {
        try validate(value)
        return try encode(value)
    }

    func decodeAcknowledgement(
        _ data: Data
    ) throws -> Phase2AIWorkerConfigurationAcknowledgement {
        try requireExactKeys(data, expected: Self.acknowledgementKeys)
        let value: Phase2AIWorkerConfigurationAcknowledgement = try decode(data)
        try validate(value)
        return value
    }

    private func validate(_ value: Phase2AIWorkerConfigurationWire) throws {
        guard value.schemaVersion == Self.schemaVersion else {
            throw Phase2AIWorkerWireError.unsupportedProtocolVersion(value.schemaVersion)
        }
        guard value.generation > 0,
              Self.isSupportedManifestDigest(value.protocolManifestDigest),
              value.endpointOrigin.utf8.count <= 128,
              Phase2AIWorkerConfigurationValidation.isCanonicalLoopbackOrigin(value.endpointOrigin),
              Self.isValidModel(value.model),
              (1...(value.inferencePolicy == nil ? 8_192 : 16_384)).contains(value.maximumTokens),
              value.inferencePolicy?.isValid != false,
              (1_000...(value.inferencePolicy == nil ? 30_000 : 900_000)).contains(value.requestTimeoutMilliseconds),
              (1_000...(value.inferencePolicy == nil ? 120_000 : 1_800_000)).contains(value.resourceTimeoutMilliseconds),
              value.resourceTimeoutMilliseconds >= value.requestTimeoutMilliseconds
        else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
    }

    private func validate(_ value: Phase2AIWorkerConfigurationAcknowledgement) throws {
        guard value.schemaVersion == Self.schemaVersion else {
            throw Phase2AIWorkerWireError.unsupportedProtocolVersion(value.schemaVersion)
        }
        guard value.generation > 0,
              Self.isSupportedManifestDigest(value.protocolManifestDigest)
        else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
    }

    private static func isValidModel(_ model: String) -> Bool {
        let bytes = model.utf8
        return !bytes.isEmpty
            && bytes.count <= 512
            && !bytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
    }

    private static func isSupportedManifestDigest(_ digest: String) -> Bool {
        digest == Phase2AIWorkerProductionProtocol.standard.manifestDigest
            || digest == Phase2AIWorkerProductionProtocol.assistantR2.manifestDigest
            || digest == Phase2AIWorkerProductionProtocol.assistantR3.manifestDigest
            || digest == Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest
            || digest == Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
            || digest == Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest
            || digest == Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        try requireBound(data)
        return data
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        try requireBound(data)
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        return value
    }

    private func requireExactKeys(_ data: Data, expected: Set<String>, allowsPolicy: Bool = false) throws {
        try requireBound(data)
        guard Phase2StrictJSONValidator.validate(data, limits: Self.structuralJSONLimits),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        let keys = Set(dictionary.keys)
        guard keys == expected || (allowsPolicy && keys == expected.union(["inferencePolicy"])
            && Self.hasClosedPolicy(dictionary["inferencePolicy"])) else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
    }

    static func hasClosedPolicy(_ object: Any?) -> Bool {
        guard let dictionary = object as? [String: Any] else { return false }
        let base: Set<String> = ["provider", "reasoningEffort", "enableThinking", "effectiveContextTokens"]
        let keys = Set(dictionary.keys)
        if keys == base { return true }
        guard keys == base.union(["sampling"]),
              let sampling = dictionary["sampling"] as? [String: Any] else { return false }
        return Set(sampling.keys) == ["temperature", "topP", "topK"]
    }

    private func requireBound(_ data: Data) throws {
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw Phase2AIWorkerWireError.envelopeTooLarge
        }
    }
}

enum Phase2AIWorkerConfigurationValidation {
    static func isCanonicalLoopbackOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              let port = components.port,
              (1...Int(UInt16.max)).contains(port),
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
        else { return false }
        let host: String
        switch components.percentEncodedHost {
        case "127.0.0.1": host = "127.0.0.1"
        case "[::1]": host = "[::1]"
        default: return false
        }
        let canonical = "http://\(host):\(port)"
        return value == canonical || value == canonical + "/"
    }

    static func canonicalLoopbackOrigin(_ value: String) -> String? {
        guard isCanonicalLoopbackOrigin(value) else { return nil }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}

import Foundation

/// Admission occurs before Foundation/JavaScript decoding can erase duplicate keys or Unicode
/// errors. Semantic operation schemas are separately enforced by the fixed resource and app DTOs.
enum REAInspectionWireCodec {
    enum Failure: Error, Equatable {
        case malformed, bounds, invalidIdentity, invalidOperation, invalidEnvelope, unsafeNumber
    }

    static func validateRequest(_ data: Data, requestID: UUID) throws -> REAInspectionHeader {
        let value = try parse(data, maximumBytes: REAInspectionLimits.maximumRequestBytes)
        guard let root = value.objectValue,
              Set(root.keys) == ["schemaVersion", "requestID", "operation", "input"],
              root["schemaVersion"] == .number("1"),
              root["input"]?.objectValue != nil else { throw Failure.invalidEnvelope }
        guard let text = root["requestID"]?.stringValue, UUID(uuidString: text) == requestID else {
            throw Failure.invalidIdentity
        }
        guard let name = root["operation"]?.stringValue,
              let operation = REAInspectionOperation(rawValue: name) else { throw Failure.invalidOperation }
        return .init(requestID: requestID, operation: operation)
    }

    static func validateResponse(_ data: Data, requestID: UUID,
                                 operation: REAInspectionOperation, implementationIdentity: String) throws {
        let value = try parse(data, maximumBytes: REAInspectionLimits.maximumResponseBytes)
        guard let root = value.objectValue,
              root["schemaVersion"] == .number("1"),
              let text = root["requestID"]?.stringValue, UUID(uuidString: text) == requestID,
              root["operation"]?.stringValue == operation.rawValue,
              root["implementationIdentity"]?.stringValue == implementationIdentity else {
            throw Failure.invalidIdentity
        }
        let common: Set<String> = ["schemaVersion", "requestID", "operation", "implementationIdentity", "ok"]
        switch root["ok"]?.boolValue {
        case true:
            guard Set(root.keys) == common.union(["result"]), root["result"]?.objectValue != nil else {
                throw Failure.invalidEnvelope
            }
        case false:
            guard Set(root.keys) == common.union(["error"]), let error = root["error"]?.objectValue,
                  Set(error.keys) == ["code", "message"], let code = error["code"]?.stringValue,
                  !code.isEmpty, code.utf8.count <= 128, let message = error["message"]?.stringValue,
                  message.utf8.count <= 1_024 else { throw Failure.invalidEnvelope }
        default: throw Failure.invalidEnvelope
        }
    }

    static func failure(requestID: UUID, operation: REAInspectionOperation?,
                        implementationIdentity: String, code: String, message: String) -> Data {
        // All values are locally produced bounded strings; this fallback cannot expose target data.
        let error: [String: Any] = ["code": String(code.prefix(128)), "message": String(message.prefix(256))]
        let value: [String: Any] = ["schemaVersion": 1, "requestID": requestID.uuidString,
            "operation": operation.map { $0.rawValue as Any } ?? NSNull(),
            "implementationIdentity": implementationIdentity, "ok": false, "error": error]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// REA-specific commitment encoding. UTF-16 key order matches JavaScript Object.keys.sort;
    /// raw Unicode is preserved. This does not alter any persisted Reconstruction identity.
    static func canonicalRequest<T: Encodable>(_ request: T, requestID: UUID) throws -> Data {
        let encoded = try JSONEncoder().encode(request)
        let value = try parse(encoded, maximumBytes: REAInspectionLimits.maximumRequestBytes)
        let result = try canonical(value)
        _ = try validateRequest(result, requestID: requestID)
        return result
    }

    static func canonicalCommitment(_ data: Data) throws -> Data {
        try canonical(parse(data, maximumBytes: REAInspectionLimits.maximumRequestBytes))
    }

    private static func canonical(_ value: Phase2ProductionJSONValue) throws -> Data {
        switch value {
        case .null: return Data("null".utf8)
        case .bool(let value): return Data((value ? "true" : "false").utf8)
        case .number(let spelling):
            // These versioned schemas use bounded integers; do not invent a cross-language
            // floating-point formatter or round an address while constructing a commitment.
            guard let number = Double(spelling), number.rounded(.towardZero) == number,
                  abs(number) <= 9_007_199_254_740_991 else { throw Failure.unsafeNumber }
            return Data(String(Int64(number)).utf8)
        case .string: return value.canonicalJSONBytes()
        case .array(let values):
            var result = Data("[".utf8)
            for (index, child) in values.enumerated() {
                if index != 0 { result.append(0x2C) }
                result.append(try canonical(child))
            }
            result.append(0x5D); return result
        case .object(let values):
            var result = Data("{".utf8)
            for (index, key) in values.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }).enumerated() {
                if index != 0 { result.append(0x2C) }
                result.append(Phase2ProductionJSONValue.string(key).canonicalJSONBytes())
                result.append(0x3A)
                guard let child = values[key] else { throw Failure.malformed }
                result.append(try canonical(child))
            }
            result.append(0x7D); return result
        }
    }

    private static func parse(_ data: Data, maximumBytes: Int) throws -> Phase2ProductionJSONValue {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.bounds }
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(data, limits: .init(maximumBytes: maximumBytes,
                maximumDepth: REAInspectionLimits.maximumDepth,
                maximumTokens: REAInspectionLimits.maximumValues * 2,
                maximumMembersAndElements: REAInspectionLimits.maximumValues))
        } catch { throw Failure.malformed }
        try validateNumbers(value)
        return value
    }

    private static func validateNumbers(_ value: Phase2ProductionJSONValue) throws {
        switch value {
        case .number(let spelling):
            guard let number = Double(spelling), number.isFinite,
                  abs(number) <= 9_007_199_254_740_991 else { throw Failure.unsafeNumber }
        case .array(let values):
            for child in values { try validateNumbers(child) }
        case .object(let values):
            for child in values.values { try validateNumbers(child) }
        default: break
        }
    }
}

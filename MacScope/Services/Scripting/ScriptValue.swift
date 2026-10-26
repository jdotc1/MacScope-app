import Foundation

/// A JSON-shaped value — the serialization boundary for the scripting API. Command
/// arguments arrive as a `ScriptValue` and results are returned as one, so any
/// binding (Python embed, MCP/JSON-RPC server, CLI) exchanges plain JSON with the
/// in-process command dispatcher.
enum ScriptValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ScriptValue])
    case object([String: ScriptValue])

    // MARK: - Typed accessors

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int64? {
        switch self {
        case let .int(value): return value
        // Checked conversion: a non-finite or out-of-Int64-range JSON number (e.g. a
        // `"limit": 1e19` argument) must yield nil, NOT trap the process. `Int64(value)`
        // is a fatal error for such inputs — and because a Swift trap is not an `Error`,
        // it would bypass the CLI's do/catch and crash instead of exiting cleanly.
        case let .double(value): return Int64(exactly: value.rounded(.towardZero))
        default: return nil
        }
    }

    /// An address argument — accepts a JSON number or a `"0x..."` / decimal string.
    var addressValue: UInt64? {
        switch self {
        case let .int(value): return value >= 0 ? UInt64(value) : nil
        case let .string(text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("0x") { return UInt64(trimmed.dropFirst(2), radix: 16) }
            return UInt64(trimmed)
        default: return nil
        }
    }

    subscript(key: String) -> ScriptValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var arrayValue: [ScriptValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    // MARK: - JSON

    func jsonData(prettyPrinted: Bool = false) throws -> Data {
        // `.fragmentsAllowed` is required because a command result can be a top-level
        // scalar (e.g. `name-at` returns a bare string), not just an object/array.
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if prettyPrinted { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: foundationObject, options: options)
    }

    static func decode(_ data: Data) throws -> ScriptValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return ScriptValue(foundationObject: object)
    }

    /// Bridges to the `Any` graph `JSONSerialization` expects.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(items): return items.map(\.foundationObject)
        case let .object(fields): return fields.mapValues(\.foundationObject)
        }
    }

    init(foundationObject: Any) {
        switch foundationObject {
        case let number as NSNumber:
            // NSNumber is the bridge for JSON bool/int/double; disambiguate by type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.stringValue.contains(".") || number.stringValue.contains("e") {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(ScriptValue.init(foundationObject:)))
        case let dict as [String: Any]: self = .object(dict.mapValues(ScriptValue.init(foundationObject:)))
        default: self = .null
        }
    }

    // MARK: - Ergonomic builders

    /// A non-negative JSON number for a UInt64 count/size. Values within `Int64` render
    /// as a JSON integer; a value above `Int64.max` (only ever from malformed input) falls
    /// back to a `Double` so it can never wrap to a NEGATIVE number — unlike a bit-pattern
    /// reinterpret, which turns the top half of the UInt64 range into negatives.
    static func count(_ value: UInt64) -> ScriptValue {
        value <= UInt64(Int64.max) ? .int(Int64(value)) : .double(Double(value))
    }
    static func hex(_ value: UInt64) -> ScriptValue { .string("0x" + String(value, radix: 16)) }
}

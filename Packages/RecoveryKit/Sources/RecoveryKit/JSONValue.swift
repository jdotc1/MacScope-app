import Foundation

/// Retains integer precision across the Python/native seam. A virtual address
/// must never pass through a Double merely because JSON is the transport.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .signed(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else { throw RecoveryError.invalid("unsupported JSON scalar") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .signed(let value): try c.encode(value)
        case .unsigned(let value): try c.encode(value)
        case .number(let value):
            guard value.isFinite else { throw RecoveryError.invalid("nonfinite JSON number") }
            try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    public var uint64: UInt64? {
        switch self {
        case .unsigned(let value): return value
        case .signed(let value) where value >= 0: return UInt64(value)
        default: return nil
        }
    }
    public subscript(_ key: String) -> JSONValue? { object?[key] }

    /// Bounds validation is iterative. Decoder allocation is additionally
    /// bounded by the byte limit enforced before JSONDecoder is invoked.
    public func validate(limits: RecoveryLimits = RecoveryLimits()) throws {
        try limits.validate()
        var stack: [(JSONValue, Int)] = [(self, 0)]
        var records = 0
        while let (value, depth) = stack.popLast() {
            records += 1
            guard records <= limits.records else { throw RecoveryError.budget("JSON records") }
            guard depth <= limits.depth else { throw RecoveryError.budget("JSON nesting") }
            switch value {
            case .array(let values): stack.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let values): stack.append(contentsOf: values.values.map { ($0, depth + 1) })
            case .number(let value): guard value.isFinite else { throw RecoveryError.invalid("nonfinite number") }
            default: break
            }
        }
    }
}

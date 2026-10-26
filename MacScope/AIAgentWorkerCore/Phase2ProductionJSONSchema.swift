import Foundation

indirect enum Phase2ProductionJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([Self])
    case object([String: Self])

    var objectValue: [String: Self]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [Self]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    static func integer(_ value: Int) -> Self { .number(String(value)) }

    func canonicalJSONBytes() -> Data {
        var bytes: [UInt8] = []
        appendCanonicalJSON(to: &bytes)
        return Data(bytes)
    }

    private func appendCanonicalJSON(to output: inout [UInt8]) {
        switch self {
        case .null:
            output += Array("null".utf8)
        case .bool(let value):
            output += Array((value ? "true" : "false").utf8)
        case .number(let value):
            output += Array(value.utf8)
        case .string(let value):
            Self.appendJSONString(value, to: &output)
        case .array(let values):
            output.append(0x5B)
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(0x2C) }
                value.appendCanonicalJSON(to: &output)
            }
            output.append(0x5D)
        case .object(let object):
            output.append(0x7B)
            for (index, key) in object.keys.sorted(by: Self.utf8Precedes).enumerated() {
                if index > 0 { output.append(0x2C) }
                Self.appendJSONString(key, to: &output)
                output.append(0x3A)
                object[key]!.appendCanonicalJSON(to: &output)
            }
            output.append(0x7D)
        }
    }

    private static func appendJSONString(_ value: String, to output: inout [UInt8]) {
        output.append(0x22)
        for byte in value.utf8 {
            switch byte {
            case 0x22: output += [0x5C, 0x22]
            case 0x5C: output += [0x5C, 0x5C]
            case 0x08: output += [0x5C, 0x62]
            case 0x0C: output += [0x5C, 0x66]
            case 0x0A: output += [0x5C, 0x6E]
            case 0x0D: output += [0x5C, 0x72]
            case 0x09: output += [0x5C, 0x74]
            case 0x00...0x1F:
                let hex = Array("0123456789abcdef".utf8)
                output += [0x5C, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            default:
                output.append(byte)
            }
        }
        output.append(0x22)
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

struct Phase2StrictJSONLimits: Equatable, Sendable {
    let maximumBytes: Int
    let maximumDepth: Int
    let maximumTokens: Int
    let maximumMembersAndElements: Int

    static let providerEnvelope = Self(
        maximumBytes: 8 * 1_024 * 1_024,
        maximumDepth: 16,
        maximumTokens: 4_096,
        maximumMembersAndElements: 1_024
    )
    static let toolArguments = Self(
        maximumBytes: 4_096,
        maximumDepth: 4,
        maximumTokens: 64,
        maximumMembersAndElements: 16
    )
    static let shellProposalToolArguments = Self(
        maximumBytes: 16_384,
        maximumDepth: 8,
        maximumTokens: 1_024,
        maximumMembersAndElements: 512
    )
    static let debuggerProposalToolArguments = Self(
        maximumBytes: 4_096,
        maximumDepth: 4,
        maximumTokens: 128,
        maximumMembersAndElements: 32
    )
    static let finalOutput = Self(
        maximumBytes: 65_536,
        maximumDepth: 8,
        maximumTokens: 4_096,
        maximumMembersAndElements: 512
    )
    static let groundedContext = Self(
        maximumBytes: 1_048_576,
        maximumDepth: 32,
        maximumTokens: 100_000,
        maximumMembersAndElements: 50_000
    )
}

enum Phase2StrictJSONError: Error, Equatable, Sendable {
    case invalidUTF8
    case byteLimitExceeded
    case malformed
    case nonCanonicalStringEncoding
    case duplicateKey
    case trailingBytes
    case depthLimitExceeded
    case tokenLimitExceeded
    case memberLimitExceeded
}

struct Phase2StrictJSONParser: Sendable {
    func parse(
        _ data: Data,
        limits: Phase2StrictJSONLimits = .providerEnvelope,
        requiringUnescapedStringValuesForObjectKeys requiredKeys: Set<String> = []
    ) throws -> Phase2ProductionJSONValue {
        guard data.count <= limits.maximumBytes else { throw Phase2StrictJSONError.byteLimitExceeded }
        guard String(data: data, encoding: .utf8) != nil else { throw Phase2StrictJSONError.invalidUTF8 }
        var parser = Parser(
            bytes: Array(data),
            limits: limits,
            requiringUnescapedStringValuesForObjectKeys: requiredKeys
        )
        let result = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw Phase2StrictJSONError.trailingBytes }
        return result
    }

    private struct Parser {
        let bytes: [UInt8]
        let limits: Phase2StrictJSONLimits
        let requiringUnescapedStringValuesForObjectKeys: Set<String>
        var index = 0
        var tokenCount = 0
        var memberCount = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func parseValue(
            depth: Int,
            requiresUnescapedStrings: Bool = false
        ) throws -> Phase2ProductionJSONValue {
            skipWhitespace()
            guard index < bytes.count else { throw Phase2StrictJSONError.malformed }
            switch bytes[index] {
            case 0x7B:
                return try parseObject(
                    depth: depth + 1,
                    requiresUnescapedStrings: requiresUnescapedStrings
                )
            case 0x5B:
                return try parseArray(
                    depth: depth + 1,
                    requiresUnescapedStrings: requiresUnescapedStrings
                )
            case 0x22:
                try countToken()
                return .string(try parseString(requiresUnescaped: requiresUnescapedStrings))
            case 0x74:
                try countToken(); try consume("true"); return .bool(true)
            case 0x66:
                try countToken(); try consume("false"); return .bool(false)
            case 0x6E:
                try countToken(); try consume("null"); return .null
            case 0x2D, 0x30...0x39:
                try countToken(); return .number(try parseNumber())
            default:
                throw Phase2StrictJSONError.malformed
            }
        }

        mutating func parseObject(
            depth: Int,
            requiresUnescapedStrings: Bool
        ) throws -> Phase2ProductionJSONValue {
            try checkDepth(depth)
            try countToken()
            index += 1
            skipWhitespace()
            var object: [String: Phase2ProductionJSONValue] = [:]
            if consumeIf(0x7D) {
                try countToken()
                return .object(object)
            }
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw Phase2StrictJSONError.malformed
                }
                try countToken()
                let key = try parseString(requiresUnescaped: false)
                guard object[key] == nil else { throw Phase2StrictJSONError.duplicateKey }
                skipWhitespace()
                guard consumeIf(0x3A) else { throw Phase2StrictJSONError.malformed }
                try countToken()
                try countMember()
                object[key] = try parseValue(
                    depth: depth,
                    requiresUnescapedStrings: requiresUnescapedStrings
                        || requiringUnescapedStringValuesForObjectKeys.contains(key)
                )
                skipWhitespace()
                if consumeIf(0x7D) {
                    try countToken()
                    return .object(object)
                }
                guard consumeIf(0x2C) else { throw Phase2StrictJSONError.malformed }
                try countToken()
                skipWhitespace()
            }
        }

        mutating func parseArray(
            depth: Int,
            requiresUnescapedStrings: Bool
        ) throws -> Phase2ProductionJSONValue {
            try checkDepth(depth)
            try countToken()
            index += 1
            skipWhitespace()
            var values: [Phase2ProductionJSONValue] = []
            if consumeIf(0x5D) {
                try countToken()
                return .array(values)
            }
            while true {
                try countMember()
                values.append(try parseValue(
                    depth: depth,
                    requiresUnescapedStrings: requiresUnescapedStrings
                ))
                skipWhitespace()
                if consumeIf(0x5D) {
                    try countToken()
                    return .array(values)
                }
                guard consumeIf(0x2C) else { throw Phase2StrictJSONError.malformed }
                try countToken()
                skipWhitespace()
            }
        }

        mutating func parseString(requiresUnescaped: Bool) throws -> String {
            guard consumeIf(0x22) else { throw Phase2StrictJSONError.malformed }
            var scalars = String.UnicodeScalarView()
            var rawStart = index
            func appendRaw(_ end: Int, from start: Int, bytes: [UInt8], to scalars: inout String.UnicodeScalarView) throws {
                guard end >= start else { throw Phase2StrictJSONError.malformed }
                if end == start { return }
                guard let text = String(bytes: bytes[start..<end], encoding: .utf8) else {
                    throw Phase2StrictJSONError.invalidUTF8
                }
                scalars.append(contentsOf: text.unicodeScalars)
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    try appendRaw(index, from: rawStart, bytes: bytes, to: &scalars)
                    index += 1
                    return String(scalars)
                }
                if byte < 0x20 { throw Phase2StrictJSONError.malformed }
                if byte != 0x5C {
                    index += 1
                    continue
                }
                guard !requiresUnescaped else {
                    throw Phase2StrictJSONError.nonCanonicalStringEncoding
                }
                try appendRaw(index, from: rawStart, bytes: bytes, to: &scalars)
                index += 1
                guard index < bytes.count else { throw Phase2StrictJSONError.malformed }
                switch bytes[index] {
                case 0x22: scalars.append("\"")
                case 0x5C: scalars.append("\\")
                case 0x2F: scalars.append("/")
                case 0x62: scalars.append("\u{8}")
                case 0x66: scalars.append("\u{C}")
                case 0x6E: scalars.append("\n")
                case 0x72: scalars.append("\r")
                case 0x74: scalars.append("\t")
                case 0x75:
                    let first = try parseHexEscape(afterSlashUAt: index)
                    index += 4
                    if (0xD800...0xDBFF).contains(first) {
                        guard index + 2 < bytes.count,
                              bytes[index + 1] == 0x5C,
                              bytes[index + 2] == 0x75 else {
                            throw Phase2StrictJSONError.malformed
                        }
                        index += 2
                        let second = try parseHexEscape(afterSlashUAt: index)
                        guard (0xDC00...0xDFFF).contains(second) else {
                            throw Phase2StrictJSONError.malformed
                        }
                        index += 4
                        let scalarValue = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
                        guard let scalar = UnicodeScalar(scalarValue) else {
                            throw Phase2StrictJSONError.malformed
                        }
                        scalars.append(scalar)
                    } else {
                        guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(first) else {
                            throw Phase2StrictJSONError.malformed
                        }
                        scalars.append(scalar)
                    }
                default:
                    throw Phase2StrictJSONError.malformed
                }
                index += 1
                rawStart = index
            }
            throw Phase2StrictJSONError.malformed
        }

        func parseHexEscape(afterSlashUAt uIndex: Int) throws -> UInt32 {
            guard uIndex + 4 < bytes.count else { throw Phase2StrictJSONError.malformed }
            var result: UInt32 = 0
            for position in (uIndex + 1)...(uIndex + 4) {
                let value: UInt32
                switch bytes[position] {
                case 0x30...0x39: value = UInt32(bytes[position] - 0x30)
                case 0x41...0x46: value = UInt32(bytes[position] - 0x41 + 10)
                case 0x61...0x66: value = UInt32(bytes[position] - 0x61 + 10)
                default: throw Phase2StrictJSONError.malformed
                }
                result = result * 16 + value
            }
            return result
        }

        mutating func parseNumber() throws -> String {
            let start = index
            if consumeIf(0x2D), index == bytes.count { throw Phase2StrictJSONError.malformed }
            if consumeIf(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw Phase2StrictJSONError.malformed
                }
            } else {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                    throw Phase2StrictJSONError.malformed
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            if consumeIf(0x2E) {
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                    throw Phase2StrictJSONError.malformed
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                    throw Phase2StrictJSONError.malformed
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func consume(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw Phase2StrictJSONError.malformed
            }
            index += expected.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func countToken() throws {
            tokenCount += 1
            if tokenCount > limits.maximumTokens { throw Phase2StrictJSONError.tokenLimitExceeded }
        }

        mutating func countMember() throws {
            memberCount += 1
            if memberCount > limits.maximumMembersAndElements {
                throw Phase2StrictJSONError.memberLimitExceeded
            }
        }

        func checkDepth(_ depth: Int) throws {
            if depth > limits.maximumDepth { throw Phase2StrictJSONError.depthLimitExceeded }
        }
    }
}

enum Phase2ProductionJSONSchemaError: Error, Equatable, Sendable {
    case invalidIdentifier
    case duplicateProperty
    case duplicateRequiredProperty
    case unknownRequiredProperty
    case invalidLengthBounds
    case invalidItemBounds
    case invalidEnumeration
    case invalidAlternatives
}

struct Phase2ProductionJSONSchema: Equatable, Sendable {
    struct Property: Equatable, Sendable {
        let name: String
        let schema: Phase2ProductionJSONSchema
        init(name: String, schema: Phase2ProductionJSONSchema) {
            self.name = name
            self.schema = schema
        }
    }

    private indirect enum Node: Equatable, Sendable {
        case string(enumeration: [String], minLength: Int?, maxLength: Int?)
        case exactUInt64(UInt64)
        case array(items: Phase2ProductionJSONSchema, minItems: Int?, maxItems: Int?, uniqueItems: Bool)
        case object(
            properties: [Property],
            required: [String],
            alternatives: [Phase2ProductionJSONSchema]
        )
        case nullable(Phase2ProductionJSONSchema)
    }

    private let node: Node

    static func string(
        enumeration: [String] = [],
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) throws -> Self {
        try validateBounds(minLength, maxLength, ceiling: 1_048_576, error: .invalidLengthBounds)
        guard maxLength != nil || !enumeration.isEmpty,
              Set(enumeration).count == enumeration.count,
              enumeration.allSatisfy({ isBoundedString($0, maximumBytes: 65_536) }) else {
            throw Phase2ProductionJSONSchemaError.invalidEnumeration
        }
        return Self(node: .string(
            enumeration: enumeration,
            minLength: minLength,
            maxLength: maxLength
        ))
    }

    /// Either JSON null or a value of `schema`, emitted as `anyOf` so strict
    /// structured-output grammars can choose the null branch.
    static func nullable(_ schema: Self) -> Self {
        Self(node: .nullable(schema))
    }

    static func exactUInt64(_ constant: UInt64) throws -> Self {
        Self(node: .exactUInt64(constant))
    }

    static func array(
        items: Self,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool
    ) throws -> Self {
        try validateBounds(minItems, maxItems, ceiling: 4_096, error: .invalidItemBounds)
        guard maxItems != nil else { throw Phase2ProductionJSONSchemaError.invalidItemBounds }
        return Self(node: .array(
            items: items,
            minItems: minItems,
            maxItems: maxItems,
            uniqueItems: uniqueItems
        ))
    }

    static func object(properties: [Property], required: [String]) throws -> Self {
        try validateObject(properties: properties, required: required)
        return Self(node: .object(
            properties: properties,
            required: required,
            alternatives: []
        ))
    }

    /// Emits a root object with mutually exclusive discriminator branches under `anyOf`. Keeping
    /// `type: object` at the root preserves strict structured-output provider compatibility; the
    /// exact discriminator values in the branches make `anyOf` logically exclusive.
    static func discriminatedObject(
        properties: [Property],
        required: [String],
        alternatives: [Self]
    ) throws -> Self {
        try validateObject(properties: properties, required: required)
        guard (2...16).contains(alternatives.count),
              Set(alternatives.map { $0.canonicalJSONBytes() }).count
                == alternatives.count else {
            throw Phase2ProductionJSONSchemaError.invalidAlternatives
        }
        return Self(node: .object(
            properties: properties,
            required: required,
            alternatives: alternatives
        ))
    }

    private static func validateObject(
        properties: [Property],
        required: [String]
    ) throws {
        guard properties.count <= 64, required.count <= properties.count else {
            throw Phase2ProductionJSONSchemaError.invalidIdentifier
        }
        var propertyNames: Set<String> = []
        for property in properties {
            guard isIdentifier(property.name) else {
                throw Phase2ProductionJSONSchemaError.invalidIdentifier
            }
            guard propertyNames.insert(property.name).inserted else {
                throw Phase2ProductionJSONSchemaError.duplicateProperty
            }
        }
        guard Set(required).count == required.count else {
            throw Phase2ProductionJSONSchemaError.duplicateRequiredProperty
        }
        guard required.allSatisfy(propertyNames.contains) else {
            throw Phase2ProductionJSONSchemaError.unknownRequiredProperty
        }
    }

    func canonicalJSONValue() -> Phase2ProductionJSONValue {
        switch node {
        case let .string(enumeration, minLength, maxLength):
            var object: [String: Phase2ProductionJSONValue] = ["type": .string("string")]
            if !enumeration.isEmpty { object["enum"] = .array(enumeration.map(Phase2ProductionJSONValue.string)) }
            if let minLength { object["minLength"] = .integer(minLength) }
            if let maxLength { object["maxLength"] = .integer(maxLength) }
            return .object(object)
        case .exactUInt64(let constant):
            return .object([
                "enum": .array([.number(String(constant))]),
                "type": .string("integer"),
            ])
        case let .array(items, minItems, maxItems, uniqueItems):
            var object: [String: Phase2ProductionJSONValue] = [
                "items": items.canonicalJSONValue(),
                "type": .string("array"),
                "uniqueItems": .bool(uniqueItems),
            ]
            if let minItems { object["minItems"] = .integer(minItems) }
            if let maxItems { object["maxItems"] = .integer(maxItems) }
            return .object(object)
        case let .object(properties, required, alternatives):
            var object: [String: Phase2ProductionJSONValue] = [
                "additionalProperties": .bool(false),
                "properties": .object(Dictionary(uniqueKeysWithValues: properties.map {
                    ($0.name, $0.schema.canonicalJSONValue())
                })),
                "required": .array(required.map(Phase2ProductionJSONValue.string)),
                "type": .string("object"),
            ]
            if !alternatives.isEmpty {
                object["anyOf"] = .array(alternatives.map { $0.canonicalJSONValue() })
            }
            return .object(object)
        case .nullable(let schema):
            return .object(["anyOf": .array([
                .object(["type": .string("null")]),
                schema.canonicalJSONValue(),
            ])])
        }
    }

    func canonicalJSONBytes() -> Data { canonicalJSONValue().canonicalJSONBytes() }

    private static func validateBounds(
        _ minimum: Int?,
        _ maximum: Int?,
        ceiling: Int,
        error: Phase2ProductionJSONSchemaError
    ) throws {
        guard minimum.map({ (0...ceiling).contains($0) }) ?? true,
              maximum.map({ (0...ceiling).contains($0) }) ?? true,
              minimum.map({ min in maximum.map({ min <= $0 }) ?? true }) ?? true else {
            throw error
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        isBoundedString(value, maximumBytes: 128)
            && value.utf8.allSatisfy { byte in
                (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || (0x30...0x39).contains(byte) || byte == 0x5F
            }
    }

    private static func isBoundedString(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.utf8.contains(where: { $0 <= 0x1F || $0 == 0x7F })
    }
}

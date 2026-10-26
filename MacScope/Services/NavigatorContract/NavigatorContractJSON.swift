import CryptoKit
import Foundation

/// JSON value of the navigator-engine contract v1 (`docs/contracts/navigator-engine/v1`).
///
/// Integers only (no floating point), so the canonical encoding is exact in every language. Use
/// `NavigatorJSONCanonical.encode` to compare values: `String` equality is canonical-equivalence,
/// the contract compares exact scalars.
enum NavigatorJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([NavigatorJSONValue])
    case object([String: NavigatorJSONValue])

    subscript(key: String) -> NavigatorJSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var intValue: Int64? { if case .int(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [NavigatorJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var objectValue: [String: NavigatorJSONValue]? { if case .object(let value) = self { return value }; return nil }
}

/// Strict RFC 8259 reader for untrusted contract input. Refuses floating-point numbers, integers
/// outside Int64, lone surrogates, raw control characters and nesting deeper than `maxDepth`.
/// A repeated object key keeps the last value (as Python's `json.loads` does).
struct NavigatorJSONParser {
    enum Failure: Error, Equatable, Sendable {
        case malformed(offset: Int, reason: String)
    }

    static let maxDepth = 256

    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> NavigatorJSONValue {
        var parser = NavigatorJSONParser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.fail("trailing bytes") }
        return value
    }

    static func parse(_ text: String) throws -> NavigatorJSONValue { try parse(Data(text.utf8)) }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func fail(_ reason: String) -> Failure { .malformed(offset: index, reason: reason) }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func literal(_ word: String, _ value: NavigatorJSONValue) throws -> NavigatorJSONValue {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else {
            throw fail("bad literal")
        }
        index += expected.count
        return value
    }

    private mutating func value(depth: Int) throws -> NavigatorJSONValue {
        guard depth <= Self.maxDepth else { throw fail("nesting deeper than \(Self.maxDepth)") }
        guard index < bytes.count else { throw fail("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "["):
            index += 1
            var items: [NavigatorJSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        case UInt8(ascii: "{"):
            index += 1
            var fields: [String: NavigatorJSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(fields) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected :") }
                index += 1
                skipWhitespace()
                fields[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw fail("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(fields) }
                throw fail("expected , or }")
            }
        default:
            return try number()
        }
    }

    private mutating func number() throws -> NavigatorJSONValue {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) else { throw fail("bad value") }
        if bytes[index] == 0x30 {
            index += 1
        } else {
            while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
            throw fail("floating-point numbers are not allowed")
        }
        let text = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard let value = Int64(text) else { throw fail("integer outside Int64") }
        return .int(value)
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("short \\u escape") }
        var result: UInt32 = 0
        for _ in 0 ..< 4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 0x30 ... 0x39: digit = UInt32(byte - 0x30)
            case 0x41 ... 0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61 ... 0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw fail("bad \\u escape")
            }
            result = result << 4 | digit
            index += 1
        }
        return result
    }

    private mutating func string() throws -> String {
        index += 1  // opening quote
        var scalars = String.UnicodeScalarView()
        var run = index
        func flush(_ end: Int) throws {
            guard run < end else { return }
            var iterator = bytes[run ..< end].makeIterator()
            var decoder = UTF8()
            while true {
                switch decoder.decode(&iterator) {
                case .scalarValue(let scalar): scalars.append(scalar)
                case .emptyInput: return
                case .error: throw fail("invalid UTF-8")
                }
            }
        }
        while true {
            guard index < bytes.count else { throw fail("unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                try flush(index)
                index += 1
                return String(scalars)
            }
            if byte < 0x20 { throw fail("raw control character in string") }
            if byte != UInt8(ascii: "\\") { index += 1; continue }
            try flush(index)
            index += 1
            guard index < bytes.count else { throw fail("unterminated escape") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800 ... 0xDBFF).contains(code) {
                    guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                        throw fail("lone surrogate")
                    }
                    index += 2
                    let low = try hex4()
                    guard (0xDC00 ... 0xDFFF).contains(low) else { throw fail("lone surrogate") }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00 ... 0xDFFF).contains(code) {
                    throw fail("lone surrogate")
                }
                guard let scalar = Unicode.Scalar(code) else { throw fail("bad scalar") }
                scalars.append(scalar)
            default:
                throw fail("bad escape")
            }
            run = index
        }
    }
}

/// Canonical encoding and stable ids (README §2). Byte-identical to Python's
/// `json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` on contract values.
enum NavigatorJSONCanonical {
    enum Failure: Error, Equatable, Sendable {
        case nonIdentifierKey(String)
    }

    static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        func letter(_ s: Unicode.Scalar) -> Bool { (0x41 ... 0x5A).contains(s.value) || (0x61 ... 0x7A).contains(s.value) || s == "_" }
        return letter(first) && key.unicodeScalars.dropFirst().allSatisfy { letter($0) || (0x30 ... 0x39).contains($0.value) }
    }

    /// Code-point order, as Python sorts `str` keys.
    static func sortedKeys(_ keys: Dictionary<String, NavigatorJSONValue>.Keys) -> [String] {
        keys.sorted { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
    }

    static func encode(_ value: NavigatorJSONValue) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: NavigatorJSONValue, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let number): out += String(number)
        case .string(let text): writeString(text, into: &out)
        case .array(let items):
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                try write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (offset, key) in sortedKeys(fields.keys).enumerated() {
                guard isIdentifier(key) else { throw Failure.nonIdentifierKey(key) }
                if offset > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                try write(fields[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// `prefix-` + the first 32 hex digits of SHA-256 over the canonical UTF-8 bytes.
    static func digest(_ prefix: String, _ payload: NavigatorJSONValue) throws -> String {
        let hash = SHA256.hash(data: Data(try encode(payload).utf8))
        return prefix + "-" + hash.prefix(16).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }
}

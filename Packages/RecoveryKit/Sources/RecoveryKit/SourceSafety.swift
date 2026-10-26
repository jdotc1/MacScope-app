import Foundation

public struct SwiftIdentifier: Hashable, Sendable {
    public let value: String
    public init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard let first = bytes.first,
              first == 95 || (65 ... 90).contains(first) || (97 ... 122).contains(first),
              bytes.dropFirst().allSatisfy({ $0 == 95 || (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) }),
              value != "_" else { throw RecoveryError.invalid("unsupported/injectable Swift identifier") }
        self.value = value
    }
    public var rendered: String {
        Self.keywords.contains(value) ? "`\(value)`" : value
    }
    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as", "Any",
        "false", "is", "nil", "self", "Self", "super", "throws", "true", "try", "actor", "async", "await", "some", "any"
    ]
}

public enum SwiftLiteral {
    public static func string(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: output += "\\\""
            case 92: output += "\\\\"
            case 10: output += "\\n"
            case 13: output += "\\r"
            case 9: output += "\\t"
            case 0 ... 31, 127: output += "\\u{\(String(scalar.value, radix: 16))}"
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }
}

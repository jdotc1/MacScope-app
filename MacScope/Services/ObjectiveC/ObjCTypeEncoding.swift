import Foundation

/// Decodes Objective-C runtime type encodings into readable C/Objective-C type text, and
/// renders method signatures. A best-effort, CORRECTNESS-OVER-COVERAGE decoder: anything it
/// cannot decode becomes `id` (or `void` for an anonymous struct) rather than a guessed,
/// possibly-wrong type. The encoding grammar is the one in the Objective-C runtime (`@encode`).
enum ObjCTypeEncoding {

    /// Decodes a SINGLE leading type token of `encoding` (e.g. `@"NSString"` → `NSString *`,
    /// `^i` → `int *`, `{CGRect=…}` → `CGRect`, `r*` → `const char *`). Unknown/empty → `id`.
    static func decode(_ encoding: String) -> String {
        var i = 0
        let chars = Array(encoding)
        guard i < chars.count else { return "id" }
        return decodeType(chars, &i)
    }

    /// Renders a full method declaration, e.g. `- (id)initWithFrame:(CGRect)arg0;`. Argument
    /// names are positional (`arg0`, `arg1`, …) since the encoding carries no parameter names.
    static func methodSignature(_ method: ObjCMethod) -> String {
        let prefix = method.isClassMethod ? "+" : "-"
        let argCount = method.selector.filter { $0 == ":" }.count

        var returnType = "id"
        var argTypes = [String](repeating: "id", count: argCount)
        if let encoding = method.typeEncoding {
            let types = decodedTypes(of: encoding)
            if let first = types.first { returnType = first }
            // types[0] = return, types[1] = self (@), types[2] = SEL (:), types[3...] = args.
            let parsed = Array(types.dropFirst(3))
            for index in 0..<argCount where index < parsed.count { argTypes[index] = parsed[index] }
        }
        return "\(prefix) \(methodBody(returnType: returnType, selector: method.selector, argTypes: argTypes));"
    }

    /// Renders `Type name` with the pointer star hugging the name (`NSString *_title`, `int x`).
    static func declaration(type: String, name: String) -> String {
        let split = splitTrailingArraySubscripts(type)
        let declarator = split.base.hasSuffix("*") ? "\(split.base)\(name)" : "\(split.base) \(name)"
        return declarator + split.subscripts
    }

    // MARK: - Internals

    private static func methodBody(returnType: String, selector: String, argTypes: [String]) -> String {
        let returnPart = "(\(returnType))"
        guard selector.contains(":") else { return "\(returnPart)\(selector)" }
        // "foo:bar:" → keywords ["foo", "bar"] (the trailing "" component is dropped by the count guard).
        let parts = selector.components(separatedBy: ":")
        var pieces: [String] = []
        for index in 0..<argTypes.count where index < parts.count {
            pieces.append("\(parts[index]):(\(argTypes[index]))arg\(index)")
        }
        return returnPart + pieces.joined(separator: " ")
    }

    /// Splits a method/encoding string into its successive type tokens, decoded, skipping the
    /// numeric stack offsets/sizes the runtime interleaves.
    private static func decodedTypes(of encoding: String) -> [String] {
        let chars = Array(encoding)
        var i = 0
        var result: [String] = []
        while i < chars.count {
            if chars[i].isNumber { i += 1; continue }
            let start = i
            let decoded = decodeType(chars, &i)
            if i > start { result.append(decoded) } else { i += 1 }
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        return result
    }

    /// Decodes the type token at `i`, advancing `i` past it.
    private static func decodeType(_ chars: [Character], _ i: inout Int) -> String {
        var isConst = false
        while i < chars.count, "rnNoORV".contains(chars[i]) {
            if chars[i] == "r" { isConst = true }
            i += 1
        }
        guard i < chars.count else { return "id" }

        let base: String
        switch chars[i] {
        case "v": i += 1; base = "void"
        case "c": i += 1; base = "char"
        case "C": i += 1; base = "unsigned char"
        case "s": i += 1; base = "short"
        case "S": i += 1; base = "unsigned short"
        case "i": i += 1; base = "int"
        case "I": i += 1; base = "unsigned int"
        case "l": i += 1; base = "long"
        case "L": i += 1; base = "unsigned long"
        case "q": i += 1; base = "long long"
        case "Q": i += 1; base = "unsigned long long"
        case "f": i += 1; base = "float"
        case "d": i += 1; base = "double"
        case "D": i += 1; base = "long double"
        case "B": i += 1; base = "BOOL"
        case "*": i += 1; base = "char *"
        case "#": i += 1; base = "Class"
        case ":": i += 1; base = "SEL"
        case "@":
            i += 1
            if i < chars.count, chars[i] == "\"" {
                i += 1
                var name = ""
                while i < chars.count, chars[i] != "\"" { name.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 } // closing quote
                base = name.isEmpty ? "id" : "\(name) *"
            } else {
                if i < chars.count, chars[i] == "?" { i += 1 } // block
                base = "id"
            }
        case "^":
            i += 1
            let pointee = decodeType(chars, &i)
            base = pointee.hasSuffix("*") ? "\(pointee)*" : "\(pointee) *"
        case "{", "(":
            base = decodeAggregate(chars, &i)
        case "[":
            i += 1
            var extent = ""
            while i < chars.count, chars[i].isNumber {
                extent.append(chars[i])
                i += 1
            }
            let element = decodeType(chars, &i)
            if i < chars.count, chars[i] == "]" { i += 1 }
            let split = splitTrailingArraySubscripts(element)
            base = "\(split.base)[\(extent)]\(split.subscripts)"
        case "b":
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
            base = "unsigned int"
        default:
            i += 1
            base = "id"
        }
        return isConst ? "const \(base)" : base
    }

    /// `{Name=…}` / `(Name=…)` → `Name` (the tag), skipping the balanced body. Anonymous → `void`.
    private static func decodeAggregate(_ chars: [Character], _ i: inout Int) -> String {
        let open = chars[i]
        let close: Character = open == "{" ? "}" : ")"
        let bodyStart = i
        var depth = 0
        var j = i
        while j < chars.count {
            if chars[j] == open { depth += 1 } else if chars[j] == close {
                depth -= 1
                if depth == 0 { j += 1; break }
            }
            j += 1
        }
        var name = ""
        var k = bodyStart + 1
        while k < chars.count, k < j, chars[k] != "=", chars[k] != close { name.append(chars[k]); k += 1 }
        i = j
        return (name.isEmpty || name == "?") ? "void" : name
    }

    private static func splitTrailingArraySubscripts(_ type: String) -> (base: String, subscripts: String) {
        let chars = Array(type)
        var end = chars.count
        var suffixStart = chars.count

        while end > 0, chars[end - 1] == "]" {
            var cursor = end - 2
            let digitEnd = cursor
            while cursor >= 0, chars[cursor].isNumber { cursor -= 1 }
            guard cursor >= 0, chars[cursor] == "[", cursor < digitEnd else { break }
            suffixStart = cursor
            end = cursor
        }

        guard suffixStart < chars.count else { return (type, "") }
        return (String(chars[..<suffixStart]), String(chars[suffixStart...]))
    }
}

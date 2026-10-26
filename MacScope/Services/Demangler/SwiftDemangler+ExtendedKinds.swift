import Foundation

// Rare compiler-generated kinds, kept apart from the core entity/signature parser.
extension SwiftDemangler.Parser {
        // MARK: Macro expansions (HS-13)

        /// A whole-symbol macro-expansion entity (upstream `demangleMacroExpansion`): a module or
        /// nominal-type context, or an `fMX` source location (module, file, line, column), followed
        /// by one expansion operator (`fMa/r/m/p/c/e/q/b` attached, `fMf` freestanding, `fMu`
        /// unique name) and any chained ones. Text matches `xcrun swift-demangle` (Swift 6.4).
        /// Entities nested inside an expansion context are out of scope here; in emitted binaries
        /// they reference the expansion as a `$s…`-prefixed identifier, handled by the identifier path.
        mutating func parseMacroExpansionSymbol() -> String? {
            guard chars.count >= 4, containsMacroOperator() else { return nil }
            let start = saveState()
            if let rendered = parseMacroExpansionBody(), isAtEnd { return rendered }
            restore(start)
            return nil
        }

        private func containsMacroOperator() -> Bool {
            var i = pos
            while i + 1 < chars.count {
                if chars[i] == "f", chars[i + 1] == "M" { return true }
                i += 1
            }
            return false
        }

        private mutating func parseMacroExpansionBody() -> String? {
            guard let module = parseMacroIdentifier() else { return nil }
            var context = module
            let locStart = saveState()
            if let file = parseMacroIdentifier(), consumeLiteral("fMX"),
               let line = parseMacroIndex(), let column = parseMacroIndex() {
                context = "module \(module) file \(file) line \(line) column \(column)"
            } else {
                restore(locStart)
                while true {
                    let levelStart = saveState()
                    guard let name = parseMacroIdentifier(), let kind = peek(),
                          kind == "V" || kind == "C" || kind == "O" else {
                        restore(levelStart); break
                    }
                    advance()
                    context += "." + name
                }
            }
            var rendered: String?
            while !isAtEnd {
                var names: [String] = []
                var privateDiscriminator: String?
                while !(peek() == "f" && peek(1) == "M") {
                    guard let name = parseMacroIdentifier() else { return nil }
                    if consumeLiteral("Ll") {
                        guard privateDiscriminator == nil, names.isEmpty else { return nil }
                        privateDiscriminator = name
                        continue
                    }
                    names.append(name)
                    guard names.count <= 2 else { return nil }
                }
                advance(2)
                guard let kind = peek() else { return nil }
                advance()
                guard let index = parseMacroIndex() else { return nil }
                let number = index + 1
                let enclosing = rendered ?? context
                let attachedRole: String?
                switch kind {
                case "a": attachedRole = "accessor"
                case "r": attachedRole = "memberAttribute"
                case "m": attachedRole = "member"
                case "p": attachedRole = "peer"
                case "c": attachedRole = "conformance"
                case "e": attachedRole = "extension"
                case "q": attachedRole = "preamble"
                case "b": attachedRole = "body"
                default: attachedRole = nil
                }
                if let role = attachedRole {
                    guard names.count == 2, privateDiscriminator == nil else { return nil }
                    rendered = "\(role) macro @\(names[1]) expansion #\(number) of \(names[0]) in \(enclosing)"
                } else if kind == "f" {
                    guard names.count == 1 else { return nil }
                    let discriminator = privateDiscriminator.map { "(in \($0))" } ?? ""
                    rendered = "freestanding macro expansion #\(number) of \(names[0])\(discriminator) in \(enclosing)"
                } else if kind == "u" {
                    guard names.count == 1, privateDiscriminator == nil else { return nil }
                    rendered = "unique name #\(number) of \(names[0]) in \(enclosing)"
                } else {
                    return nil
                }
            }
            return rendered
        }

        /// `_` -> 0, `<digits>_` -> digits + 1 (upstream `demangleIndex`).
        private mutating func parseMacroIndex() -> Int? {
            if consume("_") { return 0 }
            var digits = ""
            while let c = peek(), c.isASCIIDigit, digits.count < 9 {
                digits.unicodeScalars.append(c)
                advance()
            }
            guard !digits.isEmpty, consume("_"), let value = Int(digits) else { return nil }
            return value + 1
        }

        /// A plain identifier, or a Swift-punycode one (`00<length><encoded>`), as used for source
        /// file names such as `mac.swift` in `fMX` locations.
        private mutating func parseMacroIdentifier() -> String? {
            guard peek() == "0", peek(1) == "0" else { return parseIdentifier() }
            let start = saveState()
            advance(2)
            var lengthStr = ""
            while let c = peek(), c.isASCIIDigit, lengthStr.count < 6 {
                lengthStr.unicodeScalars.append(c)
                advance()
            }
            guard let length = Int(lengthStr), length > 0, pos + length <= chars.count,
                  let decoded = SwiftDemangler.decodeSwiftPunycode(Array(chars[pos..<(pos + length)])) else {
                restore(start); return nil
            }
            advance(length)
            return decoded
        }

}

extension SwiftDemangler {
    /// Swift's punycode variant (lib/Demangling/Punycode.cpp): `_` delimiter, digits `a-z` = 0-25 and
    /// `A-J` = 26-35, and code points 0xD800-0xD87F mapping back to non-identifier ASCII.
    static func decodeSwiftPunycode(_ input: [Unicode.Scalar]) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        func digitValue(_ c: Unicode.Scalar) -> Int? {
            switch c.value {
            case 0x61...0x7A: return Int(c.value) - 0x61
            case 0x41...0x4A: return Int(c.value) - 0x41 + 26
            default: return nil
            }
        }
        func adapt(_ delta: Int, _ numPoints: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / numPoints
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + ((base - tMin + 1) * delta) / (delta + skew)
        }
        var output: [UInt32] = []
        var position = 0
        if let delimiter = input.lastIndex(of: "_") {
            for c in input[..<delimiter] {
                guard c.value < 0x80 else { return nil }
                output.append(c.value)
            }
            position = delimiter + 1
        }
        var n = 128, i = 0, bias = 72
        while position < input.count {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard position < input.count, let digit = digitValue(input[position]) else { return nil }
                position += 1
                i += digit * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                w *= base - t
                k += base
                guard i < 0x110000, w < 0x110000 else { return nil }
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n >= 0x80, n < 0x110000 else { return nil }
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for value in output {
            let mapped = (0xD800..<0xD880).contains(value) ? value - 0xD800 : value
            guard let scalar = Unicode.Scalar(mapped) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }
}

extension SwiftDemangler {
    /// `HX` is a list of conformances, not a suffix on an ordinary protocol conformance.
    /// This bounded stack handles its concrete operands and enclosing pack metadata. It deliberately
    /// declines function signatures, dependent conformances and symbolic references. Retroactive
    /// requirements are parsed and validated even though Swift's default printer hides them inside
    /// a bound generic type. Grammar: Swift ABI Mangling.rst, any-protocol-conformance-list.
    static func demanglePackConformance(_ payload: String, typesOnly: Bool = false) -> String? {
        guard payload.contains("HX") else { return nil }
        var parser = PackConformanceParser(chars: Array(payload.unicodeScalars), typesOnly: typesOnly)
        return parser.parse()
    }

    private struct PackConformanceParser {
        enum Kind { case identifier, type, nominal, proto, empty, first, conformance, conformanceRef, retroactive }
        struct Node {
            let kind: Kind
            let text: String
            var depth = 0
            var isType: Bool { kind == .type || kind == .nominal || kind == .proto }
        }
        let chars: [Unicode.Scalar]
        let typesOnly: Bool
        var pos = 0
        var stack: [Node] = []
        var substitutions: [Node] = []
        var words: [String] = []
        var sawPack = false

        mutating func parse() -> String? {
            while pos < chars.count {
                if chars[pos].isASCIIDigit {
                    guard let name = identifier() else { return nil }
                    let node = Node(kind: .identifier, text: name)
                    stack.append(node); substitutions.append(node)
                    continue
                }
                let op = chars[pos]; pos += 1
                switch op {
                case "A":
                    guard substitute() else { return nil }
                case "s": stack.append(Node(kind: .identifier, text: "Swift"))
                case "V", "C", "O", "P":
                    guard let name = pop(.identifier), let context = stack.popLast(),
                          context.kind == .identifier || context.kind == .nominal else { return nil }
                    let node = Node(kind: op == "P" ? .proto : .nominal,
                                    text: context.text + "." + name.text, depth: context.depth + 1)
                    stack.append(node); substitutions.append(node)
                case "y": stack.append(Node(kind: .empty, text: ""))
                case "_": stack.append(Node(kind: .first, text: ""))
                case "Q":
                    guard take("P"), let elements = list(types: true) else { return nil }
                    stack.append(Node(kind: .type, text: "Pack{" + elements.map(\.text).joined(separator: ", ") + "}",
                                      depth: 1 + (elements.map(\.depth).max() ?? 0)))
                case "H":
                    guard pos < chars.count else { return nil }
                    let kind = chars[pos]; pos += 1
                    if kind == "X" {
                        guard let elements = list(types: false) else { return nil }
                        stack.append(Node(kind: .conformance, text: "pack protocol conformance " + renderList(elements),
                                          depth: 1 + (elements.map(\.depth).max() ?? 0)))
                        sawPack = true
                    } else if kind == "C" {
                        guard let conditions = list(types: false) else { return nil }
                        let reference: Node
                        if let ref = pop(.conformanceRef) { reference = ref }
                        else {
                            guard let module = pop(.identifier), let proto = protocolOperand() else { return nil }
                            reference = Node(kind: .conformanceRef,
                                             text: "protocol conformance ref (retroactive) " + proto.text + module.text)
                        }
                        guard let type = stack.popLast(), type.isType else { return nil }
                        let suffix = conditions.isEmpty ? "" : " with conditional requirements: " + renderList(conditions)
                        stack.append(Node(kind: .conformance,
                                          text: "concrete protocol conformance " + type.text + " to " + reference.text + suffix,
                                          depth: 1 + max(type.depth, conditions.map(\.depth).max() ?? 0)))
                    } else if kind == "P" || kind == "p" {
                        guard let proto = protocolOperand() else { return nil }
                        let owner = kind == "P" ? "type's" : "protocol's"
                        stack.append(Node(kind: .conformanceRef,
                                          text: "protocol conformance ref (\(owner) module) " + proto.text))
                    } else { return nil }
                case "g":
                    guard let index = index(), let conformance = pop(.conformance) else { return nil }
                    stack.append(Node(kind: .retroactive, text: "retroactive conformance @\(index) " + conformance.text,
                                      depth: conformance.depth + 1))
                case "G":
                    while stack.last?.kind == .retroactive { stack.removeLast() }
                    var args: [Node] = []
                    while let last = stack.last, last.isType { args.append(stack.removeLast()) }
                    guard pop(.empty) != nil, let base = pop(.nominal) else { return nil }
                    let node = Node(kind: .type,
                                    text: base.text + (args.isEmpty ? "" : "<" + args.reversed().map(\.text).joined(separator: ", ") + ">"),
                                    depth: 1 + max(base.depth, args.map(\.depth).max() ?? 0))
                    stack.append(node); substitutions.append(node)
                case "M", "N":
                    guard !typesOnly else { return nil }
                    let prefix: String
                    if op == "N" { prefix = "type metadata for " }
                    else if take("D") || take("d") { prefix = "demangling cache variable for type metadata for " }
                    else if take("R") { prefix = "mangled name ref for type metadata for " }
                    else if take("a") { prefix = "type metadata accessor for " }
                    else { return nil }
                    guard pos == chars.count, sawPack, stack.count == 1,
                          let type = stack.last, type.isType else { return nil }
                    let result = prefix + type.text
                    return result.utf8.count <= maxRenderedLength ? result : tooComplexMarker
                default: return nil
                }
                guard stack.count <= maxMangledLength, substitutions.count <= maxMangledLength,
                      stack.allSatisfy({ $0.depth <= maxTypeDepth && $0.text.utf8.count <= maxRenderedLength }) else {
                    return tooComplexMarker
                }
            }
            guard sawPack, stack.count == 1, let node = stack.last,
                  node.isType || (!typesOnly && (node.kind == .conformance || node.kind == .retroactive)) else { return nil }
            return node.text
        }

        mutating func pop(_ kind: Kind) -> Node? {
            guard stack.last?.kind == kind else { return nil }
            return stack.removeLast()
        }
        mutating func take(_ c: Unicode.Scalar) -> Bool {
            guard pos < chars.count, chars[pos] == c else { return false }
            pos += 1; return true
        }
        mutating func index() -> Int? {
            if take("_") { return 0 }
            guard let n = natural(), take("_"), n < Int.max else { return nil }
            return n + 1
        }
        mutating func natural() -> Int? {
            let start = pos
            while pos < chars.count, chars[pos].isASCIIDigit { pos += 1 }
            guard start != pos else { return nil }
            return Int(String(String.UnicodeScalarView(chars[start..<pos])))
        }
        mutating func protocolOperand() -> Node? {
            if let proto = pop(.proto) { return proto }
            guard let name = pop(.identifier), let module = pop(.identifier) else { return nil }
            return Node(kind: .proto, text: module.text + "." + name.text)
        }
        mutating func list(types: Bool) -> [Node]? {
            if pop(.empty) != nil { return [] }
            var result: [Node] = []
            while !stack.isEmpty {
                let first = pop(.first) != nil
                guard let node = stack.popLast(), types ? node.isType : node.kind == .conformance else { return nil }
                result.append(node)
                if first { return result.reversed() }
            }
            return nil
        }
        func renderList(_ nodes: [Node]) -> String {
            nodes.isEmpty ? "" : "(" + nodes.map(\.text).joined(separator: ", ") + ")"
        }
        mutating func substitute() -> Bool {
            while pos < chars.count {
                let countStart = pos
                let count = natural()
                guard pos == countStart || count != nil else { return false }
                if take("_") {
                    // Check the table bound before applying the extended-index bias.
                    let encoded = count ?? -1
                    guard substitutions.count >= 27, encoded < substitutions.count - 27 else { return false }
                    let index = encoded + 27
                    guard substitutions.indices.contains(index) else { return false }
                    stack.append(substitutions[index]); return true
                }
                guard pos < chars.count else { return false }
                let c = chars[pos]; pos += 1
                let lower = c >= "a" && c <= "z"
                guard lower || (c >= "A" && c <= "Z") else { return false }
                let index = Int(c.value - (lower ? 97 : 65))
                guard substitutions.indices.contains(index), (count ?? 1) > 0, (count ?? 1) <= 64 else { return false }
                stack.append(contentsOf: repeatElement(substitutions[index], count: count ?? 1))
                if !lower { return true }
            }
            return false
        }
        mutating func identifier() -> String? {
            var hasWords = take("0")
            guard !(hasWords && pos < chars.count && chars[pos] == "0") else { return nil }
            var text = ""
            repeat {
                while hasWords, pos < chars.count {
                    let c = chars[pos]
                    let lower = c >= "a" && c <= "z"
                    guard lower || (c >= "A" && c <= "Z") else { break }
                    pos += 1
                    let index = Int(c.value - (lower ? 97 : 65))
                    guard words.indices.contains(index) else { return nil }
                    text += words[index]; hasWords = lower
                }
                if take("0") { break }
                guard let length = natural(), length > 0, length <= chars.count - pos else { return nil }
                let slice = Array(chars[pos..<(pos + length)])
                guard slice.allSatisfy(\.isIdentifierScalar) else { return nil }
                text += String(String.UnicodeScalarView(slice)); pos += length
                // Swift word substitutions start at letters and end at underscores or
                // an uppercase letter after a non-uppercase letter. Only words of length >= 2 count.
                var start: Int?
                for i in 0...slice.count {
                    let c: Unicode.Scalar = i < slice.count ? slice[i] : "\0"
                    let letter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
                    let upper = c >= "A" && c <= "Z"
                    let previousUpper = i > 0 && slice[i - 1] >= "A" && slice[i - 1] <= "Z"
                    if let begin = start, c == "_" || c == "\0" || (upper && !previousUpper) {
                        if i - begin >= 2, words.count < 26 {
                            words.append(String(String.UnicodeScalarView(slice[begin..<i])))
                        }
                        start = nil
                    }
                    if start == nil, letter { start = i }
                }
            } while hasWords
            return text.isEmpty ? nil : text
        }
    }
}

// Compiler descriptors and synthesized wrappers observed in the bounded Swift 6.4 samples.
extension SwiftDemangler.Parser {
    mutating func parseCompilerGeneratedKind() -> String? {
        let start = saveState()
        if let type = parseSymbolType(), consumeLiteral("Hn"), isAtEnd {
            return "nominal type descriptor runtime record for " + type
        }
        restore(start)
        if let conformance = parseProtocolConformance(), consumeLiteral("Hc"), isAtEnd {
            return "protocol conformance descriptor runtime record for " + conformance.rendered
        }
        restore(start)
        if let proto = parseProtocolType(), consumeLiteral("Hr"), isAtEnd {
            return "protocol descriptor runtime record for " + proto
        }
        restore(start)
        if let proto = parseSymbolType(), let associated = parseIdentifier(),
           let context = parseSubstitutionType(), context == proto, consume("_"),
           let requirement = parseProtocolType(), consumeLiteral("Tn"), isAtEnd {
            return "associated conformance descriptor for " + proto + "." + context + "." + associated + ": " + requirement
        }
        restore(start)
        if let module = parseIdentifier(), consumeLiteral("MXM"), isAtEnd {
            return "module descriptor " + module
        }
        restore(start)
        if let associated = parseIdentifier(), let proto = parseProtocolType(),
           consumeLiteral("PTl"), isAtEnd {
            return "associated type descriptor for " + proto + "." + associated
        }
        restore(start)
        let suffix = Array("QOMQ".unicodeScalars)
        if chars.suffix(suffix.count).elementsEqual(suffix) {
            var inner = SwiftDemangler.Parser(budget: budget, Array(chars.dropLast(suffix.count)))
            if let entity = inner.parseTopLevel() {
                return "opaque type descriptor for <<opaque return type of " + entity + ">>"
            }
        }
        return nil
    }

    mutating func parseBuiltinType() -> String? {
        let start = saveState()
        guard consume("B"), let kind = peek() else { return nil }
        advance()
        let name: String
        switch kind {
        case "o": name = "NativeObject"
        case "O": name = "UnknownObject"
        case "p": name = "RawPointer"
        case "w": name = "Word"
        case "e": name = "Executor"
        case "i":
            var bits = ""
            while let c = peek(), c.isASCIIDigit { bits.unicodeScalars.append(c); advance() }
            guard !bits.isEmpty, consume("_") else { restore(start); return nil }
            name = "Int" + bits
        default: restore(start); return nil
        }
        return "Builtin." + name
    }
}

extension SwiftDemangler.Parser {
    /// A synthesized local function has an accessor context, local name and numbered discriminator.
    /// The sample uses `$defer`; require its exact zero-argument signature instead of guessing locals.
    mutating func parseAccessorLocalFunction() -> String? {
        let tail = Array("6$deferL_yyF".unicodeScalars)
        guard chars.suffix(tail.count).elementsEqual(tail) else { return nil }
        var inner = SwiftDemangler.Parser(budget: budget, Array(chars.dropLast(tail.count)))
        guard let accessor = inner.parseTopLevel() else { return nil }
        return "$defer #1 () -> () in " + accessor
    }
}

// Swift 6.4 still emits this old spelling for Objective-C runtime class names.
// This does not claim support for the older _TF function-mangling grammar.
extension SwiftDemangler {
    static func demangleLegacyClassName(_ symbol: String) -> String? {
        guard symbol.hasPrefix("_TtC"), symbol.utf8.count <= maxMangledLength else { return nil }
        let chars = Array(symbol.unicodeScalars)
        var position = 3
        var levels = 0
        while position < chars.count, chars[position] == "C" {
            levels += 1; position += 1
            guard levels <= maxTypeDepth else { return nil }
        }
        var names: [String] = []
        for _ in 0...levels {
            let start = position
            while position < chars.count, chars[position].isASCIIDigit { position += 1 }
            guard position > start, chars[start] != "0",
                  let length = Int(String(String.UnicodeScalarView(chars[start..<position]))),
                  length > 0, length <= chars.count - position else { return nil }
            let name = chars[position..<(position + length)]
            guard name.allSatisfy(\.isIdentifierScalar) else { return nil }
            names.append(String(String.UnicodeScalarView(name))); position += length
        }
        guard position == chars.count else { return nil }
        return names.joined(separator: ".")
    }
}

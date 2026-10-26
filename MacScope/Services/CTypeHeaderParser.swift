import Foundation

/// An explicit imported declaration supplies types only, never call-target or
/// memory-effect authority. Binding to a particular image is a separate step.
struct HeaderFunctionPrototype: Equatable, Sendable {
    var name: String
    var signature: FunctionSignatureOverride
}

/// Clean-room C type-declaration parser. Turns a pasted subset of C source —
/// `struct` / `union` / `enum` / `typedef` declarations — into the workspace
/// type catalog's `TypeDefinition` values (kind + name + ordered fields, with
/// enum cases carried as `FieldDef(name: case, type: value)`).
///
/// CORRECTNESS-OVER-COVERAGE. This parser deliberately covers only the forms it
/// can model exactly. Anything it cannot parse is *skipped with a diagnostic*
/// rather than turned into a wrong type — a half-understood declaration must
/// never silently produce a `TypeDefinition` with the wrong fields or layout.
///
/// HARDENING. The tokenizer and parser are bounded and iterative (no recursion
/// on hostile input): an input-length cap, a token-count cap, and a
/// monotonic-cursor invariant (every loop iteration consumes at least one token
/// or bails) guarantee termination on adversarial bytes. Brace matching is
/// depth-counted with an explicit cap, never recursive.
///
/// SUPPORTED SUBSET
///   - `struct Name { fields }` / `union Name { fields }`
///   - `enum Name { A, B = 3, C }`  (explicit + implicit auto-increment values)
///   - `typedef <existing-type> Alias;`  (alias to a primitive / pointer)
///   - `typedef struct Name { fields } Alias;`  (tagged + alias in one shot)
///   - field base types: char/short/int/long/float/double (+ signed/unsigned),
///     the fixed-width <stdint.h> spellings, `bool`/`_Bool`, `void *`, pointers
///     (one or more `*`), and fixed-size arrays `T name[N]`.
///   - integer bit-fields (`T name : N`, `T : N`, `T : 0`) with literal widths.
///   - inline struct/union members, including C11 anonymous aggregate members
///     (`struct { … };` / `union { … };`) whose fields promote into the parent.
///   - field parenthesized-pointer declarators that lay out as pointers:
///     function pointers, pointer-to-array fields, and arrays of function pointers.
///   - struct/union layout modifiers: `__attribute__((packed))`,
///     `__attribute__((aligned(N)))`, `#pragma pack`, member `_Alignas`, and
///     last-member flexible arrays.
///   - trailing `;` after a closing brace; line (`//`) and block (`/* */`)
///     comments. Unsupported preprocessing refuses the entire import.
enum CTypeHeaderParser {
    /// Hard cap on the source length we will even attempt to parse. A pasted
    /// header is small; this keeps a hostile multi-megabyte blob from driving
    /// pathological work.
    static let maxSourceLength = 1 << 20 // 1 MiB
    /// Hard cap on the number of tokens. Bounds the parser independently of the
    /// byte cap (e.g. a file of single-char tokens).
    static let maxTokenCount = 200_000
    /// Hard cap on brace nesting depth. Real declarations nest shallowly; this
    /// rejects pathologically deep `{{{{…` without recursion.
    static let maxBraceDepth = 64

    /// One recovered type plus any diagnostics. `types` holds only fully,
    /// unambiguously parsed declarations; `diagnostics` explains every construct
    /// that was skipped (so the caller can surface "what didn't parse").
    struct Result: Equatable {
        var types: [TypeDefinition]
        var diagnostics: [String]
        var prototypes: [HeaderFunctionPrototype] = []
        var skippedPrototypeCount: Int = 0

        var isEmpty: Bool { types.isEmpty && prototypes.isEmpty && diagnostics.isEmpty }
    }

    /// Parses `source` into catalog types. Never throws; failures become
    /// diagnostics. `idProvider` lets tests pin deterministic ids (defaults to a
    /// fresh `UUID()` per type).
    static func parse(_ source: String, idProvider: @escaping () -> UUID = UUID.init) -> Result {
        guard source.utf8.count <= maxSourceLength else {
            return Result(types: [], diagnostics: ["Input too large to parse (\(source.utf8.count) bytes; limit \(maxSourceLength))."])
        }
        // C trigraph replacement precedes line splicing, including in comments
        // and literals. This subset parser has no language-mode authority: refuse
        // translation-dependent input instead of recovering inactive declarations
        // or interpreting a trigraph-created backslash as ordinary punctuation.
        let trigraphs = ["??=", "??/", "??'", "??(", "??)", "??!", "??<", "??>", "??-"]
        if trigraphs.contains(where: { source.contains($0) }) {
            return Result(types: [], diagnostics: ["Unsupported C trigraph preprocessing in pasted header; use Clang import."])
        }
        // C line splicing precedes comment/directive recognition. Do not let a
        // continued comment or split directive change which declarations we admit.
        let logicalSource = source.replacingOccurrences(of: "\\\r\n", with: "")
            .replacingOccurrences(of: "\\\n", with: "")
        let tokens = Tokenizer.tokenize(logicalSource, limit: maxTokenCount)
        if tokens.unsupportedPreprocessing {
            return Result(types: [], diagnostics: ["Unsupported preprocessing in pasted header; use Clang import. Only #pragma pack is supported."])
        }
        guard !tokens.truncated else {
            return Result(types: [], diagnostics: ["Input exceeded the \(maxTokenCount)-token limit; no declarations were imported."])
        }
        let declarations = PrototypeParser.declarations(in: tokens.tokens)
        let prototypeRanges = Dictionary(uniqueKeysWithValues: declarations.compactMap { declaration in
            PrototypeParser.isPrototypeCandidate(declaration.tokens)
                ? (declaration.start, declaration.end) : nil
        })
        var parser = DeclParser(tokens: tokens.tokens, idProvider: idProvider)
        parser.prototypeRanges = prototypeRanges
        parser.signatureContext = PrototypeParser.context(declarations)
        var result = parser.parseAll()
        PrototypeParser.copyCallbackSignatures(into: &result.types)
        let prototypes = PrototypeParser.parse(declarations, types: result.types)
        result.prototypes = prototypes.prototypes
        result.skippedPrototypeCount = prototypes.skipped
        result.diagnostics.append(contentsOf: prototypes.diagnostics)
        return result
    }

    // MARK: - Explicit function declarations

    /// A second bounded pass keeps declarator identity separate from the type
    /// catalog's layout lowering (which intentionally erases record keywords and
    /// lowers callback fields to pointer carriers).
    private enum PrototypeParser {
        struct Declaration {
            var start: Int
            var end: Int
            var tokens: [Token]
        }

        static func declarations(in tokens: [Token]) -> [Declaration] {
            var result: [Declaration] = []
            var start = 0
            var depth = 0
            for (index, token) in tokens.enumerated() {
                if case .pragmaPack = token, depth == 0 {
                    start = index + 1
                    continue
                }
                if token == .punct("{") { depth += 1 }
                if token == .punct("}") { depth = max(0, depth - 1) }
                if token == .punct(";"), depth == 0 {
                    result.append(Declaration(start: start, end: index + 1, tokens: Array(tokens[start..<index])))
                    start = index + 1
                }
            }
            return result
        }

        static func isPrototypeCandidate(_ tokens: [Token]) -> Bool {
            guard tokens.first != .identifier("typedef"),
                  !tokens.contains(.punct("{")), !tokens.contains(.punct("=")),
                  let open = tokens.firstIndex(of: .punct("(")), open > 0,
                  case .identifier = tokens[open - 1]
            else { return false }
            return true
        }

        struct Context {
            var aliases: [String: [Token]] = [:]
            var callbacks: [String: [Token]] = [:]
            var unsupported: Set<String> = []
            var nominalAliases: Set<String> = []
            var arrayElements: [String: [Token]] = [:]
        }

        static func context(_ declarations: [Declaration]) -> Context {
            var context = Context()
            for declaration in declarations where declaration.tokens.first == .identifier("typedef") {
                let body = Array(declaration.tokens.dropFirst())
                if let parts = callbackParts(body), let name = parts.name {
                    if context.aliases[name] != nil || (context.callbacks[name] != nil && context.callbacks[name] != body) {
                        context.unsupported.insert(name)
                    }
                    context.callbacks[name] = body
                    continue
                }
                if !body.contains(.punct("{")),
                   let open = body.firstIndex(of: .punct("[")), open > 1,
                   case let .identifier(name) = body[open - 1] {
                    // Fixed arrays retain their typedef identity in signatures;
                    // DeclParser remains the sole authority for their layout.
                    if context.aliases[name] != nil || context.callbacks[name] != nil {
                        context.unsupported.insert(name)
                    }
                    context.aliases[name] = [.identifier(name)]
                    context.arrayElements[name] = Array(body[..<(open - 1)])
                    context.nominalAliases.insert(name)
                    var index = open
                    while index < body.count {
                        guard index + 2 < body.count, body[index] == .punct("["),
                              case let .number(text) = body[index + 1],
                              let count = parseIntegerLiteral(text), count >= 0,
                              body[index + 2] == .punct("]") else {
                            context.unsupported.insert(name)
                            break
                        }
                        index += 3
                    }
                    continue
                }
                guard let last = body.last, case let .identifier(name) = last else { continue }
                var target = Array(body.dropLast())
                if let brace = target.firstIndex(of: .punct("{")) {
                    // Anonymous record/enum typedefs retain their nominal alias, just
                    // as ordinary prototype import does; never invent a record tag.
                    if brace == 1, let first = target.first,
                       [Token.identifier("struct"), .identifier("union"), .identifier("enum")].contains(first),
                       target.last == .punct("}") {
                        target = [.identifier(name)]
                        context.nominalAliases.insert(name)
                    } else if brace == 2, let close = target.lastIndex(of: .punct("}")) {
                        target = Array(target.prefix(2)) + Array(target.dropFirst(close + 1))
                    } else {
                        context.unsupported.insert(name)
                        continue
                    }
                }
                if context.arrayElements[name] != nil || context.callbacks[name] != nil
                    || (context.aliases[name] != nil && context.aliases[name] != target) {
                    context.unsupported.insert(name)
                }
                context.aliases[name] = target
            }
            return context
        }

        static func parse(_ declarations: [Declaration], types: [TypeDefinition])
            -> (prototypes: [HeaderFunctionPrototype], skipped: Int, diagnostics: [String]) {
            var context = context(declarations)
            // Only admitted typedef carriers can admit an ordinary prototype.
            let admitted = Set(types.filter { $0.kind == .typedef && $0.fields.first?.functionPointerSignatureV1 != nil }.map(\.name))
            context.unsupported.formUnion(Set(context.callbacks.keys).subtracting(admitted))
            var prototypes: [HeaderFunctionPrototype] = []
            var skipped = 0
            var diagnostics: [String] = []
            for declaration in declarations where isPrototypeCandidate(declaration.tokens) {
                let tokens = declaration.tokens
                guard let open = tokens.firstIndex(of: .punct("(")),
                      case let .identifier(name) = tokens[open - 1] else { continue }
                guard tokens.last == .punct(")"),
                      let returnType = signatureType(Array(tokens[..<(open - 1)]).filter { $0 != .identifier("extern") },
                                                     context: context),
                      let parameters = parameters(Array(tokens[(open + 1)..<(tokens.count - 1)]),
                                                  context: context)
                else {
                    skipped += 1
                    diagnostics.append("Skipped function prototype `\(name)`: unresolved or unsupported declaration.")
                    continue
                }
                prototypes.append(HeaderFunctionPrototype(name: name, signature: FunctionSignatureOverride(
                    returnType: returnType,
                    parameterList: .authoritative(parameters.values.enumerated().map {
                        ArgOverride(index: $0.offset, name: $0.element.name ?? "", type: $0.element.type)
                    }),
                    variadicState: parameters.variadic ? .variadic : .fixed
                )))
            }
            return (prototypes, skipped, diagnostics)
        }

        private static func parameters(_ tokens: [Token], context: Context, depth: Int = 0,
                                       visiting: Set<String> = []) -> (values: [FunctionPointerSignatureV1.Parameter], variadic: Bool)? {
            guard depth < maxBraceDepth else { return nil }
            // Empty C parentheses are an unspecified list, not an explicit void
            // prototype, so they cannot supply an authoritative parameter plan.
            guard !tokens.isEmpty else { return nil }
            if tokens == [.identifier("void")] { return ([], false) }
            var groups: [[Token]] = [[]]
            var nesting = 0
            for token in tokens {
                if token == .punct("(") || token == .punct("[") { nesting += 1 }
                if token == .punct(")") || token == .punct("]") { nesting -= 1 }
                guard nesting >= 0, nesting <= maxBraceDepth else { return nil }
                if token == .punct(","), nesting == 0 { groups.append([]) }
                else { groups[groups.count - 1].append(token) }
            }
            guard nesting == 0 else { return nil }
            var values: [FunctionPointerSignatureV1.Parameter] = []
            var names: Set<String> = []
            var variadic = false
            for (index, group) in groups.enumerated() {
                if group == [.punct("."), .punct("."), .punct(".")] {
                    guard index == groups.count - 1, !values.isEmpty else { return nil }
                    variadic = true
                    continue
                }
                var type: String?
                var name: String?
                var nested: FunctionPointerSignatureV1?
                if let parts = callbackParts(group) {
                    guard let signature = signature(returnTokens: parts.returnTokens, parameterTokens: parts.parameterTokens,
                                                    context: context, depth: depth + 1, visiting: visiting) else { return nil }
                    nested = signature
                    name = parts.name
                    type = spelling(signature)
                } else {
                    // Same canonical type resolver and unnamed-before-named rule as
                    // ordinary prototypes, including qualifiers and pointer aliases.
                    type = signatureType(group, context: context, visiting: visiting)
                    if type == nil, let last = group.last, case let .identifier(candidate) = last {
                        name = candidate
                        type = signatureType(Array(group.dropLast()), context: context, visiting: visiting)
                    }
                }
                guard let type, type != "void" else { return nil }
                if let name, !names.insert(name).inserted { return nil }
                values.append(.init(name: name, type: type, functionPointerSignatureV1: nested))
            }
            return (values, variadic)
        }

        /// The bounded subset accepts named and abstract callback parameters.
        private static func callbackParts(_ tokens: [Token]) -> (name: String?, returnTokens: [Token], parameterTokens: [Token])? {
            guard let open = tokens.firstIndex(of: .punct("(")), open > 0,
                  open + 3 < tokens.count, tokens[open + 1] == .punct("*") else { return nil }
            var close = open + 2
            var name: String?
            if case let .identifier(candidate) = tokens[close] {
                name = candidate
                close += 1
            }
            guard close + 2 < tokens.count, tokens[close] == .punct(")"),
                  tokens[close + 1] == .punct("("), tokens.last == .punct(")") else { return nil }
            return (name, Array(tokens[..<open]), Array(tokens[(close + 2)..<(tokens.count - 1)]))
        }

        static func signature(returnTokens: [Token], parameterTokens: [Token], context: Context,
                              depth: Int = 0, visiting: Set<String> = []) -> FunctionPointerSignatureV1? {
            guard depth < maxBraceDepth,
                  let returnType = signatureType(returnTokens, context: context, visiting: visiting) else { return nil }
            if parameterTokens.isEmpty {
                return .init(returnType: returnType, parameters: [], hasUnspecifiedParameters: true)
            }
            guard let parsed = parameters(parameterTokens, context: context, depth: depth + 1, visiting: visiting) else { return nil }
            return .init(returnType: returnType, parameters: parsed.values, isVariadic: parsed.variadic)
        }

        private static func spelling(_ signature: FunctionPointerSignatureV1) -> String {
            var parameters = signature.parameters.map(\.type)
            if signature.isVariadic { parameters.append("...") }
            if parameters.isEmpty && !signature.hasUnspecifiedParameters { parameters = ["void"] }
            return signature.returnType + " (*)(" + parameters.joined(separator: ", ") + ")"
        }

        /// Materialize typedef metadata onto fields at import time, including alias
        /// chains, so the workspace/renderer needs no second signature lookup API.
        static func copyCallbackSignatures(into types: inout [TypeDefinition]) {
            let catalog = Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            func resolve(_ name: String, visiting: Set<String> = []) -> FunctionPointerSignatureV1? {
                guard visiting.count < maxBraceDepth, !visiting.contains(name),
                      let type = catalog[name], type.kind == .typedef, let field = type.fields.first else { return nil }
                return field.functionPointerSignatureV1 ?? resolve(field.type, visiting: visiting.union([name]))
            }
            func copy(_ fields: [FieldDef]) -> [FieldDef] {
                fields.map { original in
                    var field = original
                    if field.functionPointerSignatureV1 == nil { field.functionPointerSignatureV1 = resolve(field.type) }
                    field.inlineFields = copy(field.inlineFields)
                    return field
                }
            }
            for index in types.indices { types[index].fields = copy(types[index].fields) }
        }

        /// C adjusts bare array parameters to pointers, but this importer does
        /// not infer that adjustment (or admit array return types). Resolve aliases
        /// first so an alias of an array receives the same refusal.
        private static func signatureType(_ tokens: [Token], context: Context, visiting: Set<String> = []) -> String? {
            guard let type = canonicalType(tokens, context: context, visiting: visiting) else { return nil }
            let words = type.split(separator: " ").map(String.init).filter {
                !["const", "volatile", "restrict"].contains($0)
            }
            if words.count == 1, context.arrayElements[words[0]] != nil { return nil }
            return type
        }

        private static func canonicalType(_ tokens: [Token], context: Context, visiting: Set<String> = []) -> String? {
            guard !tokens.isEmpty, visiting.count < maxBraceDepth else { return nil }
            let firstStar = tokens.firstIndex(of: .punct("*")) ?? tokens.count
            let baseTokens = Array(tokens[..<firstStar])
            let suffixTokens = Array(tokens[firstStar...])
            let qualifiers: Set<String> = ["const", "volatile", "restrict"]
            var words: [String] = []
            var baseQualifiers: [String] = []
            for token in baseTokens {
                guard case let .identifier(word) = token else { return nil }
                if qualifiers.contains(word) { baseQualifiers.append(word) }
                else { words.append(word) }
            }
            var suffix = ""
            for token in suffixTokens {
                switch token {
                case .punct("*"): suffix += "*"
                case let .identifier(word) where qualifiers.contains(word): suffix += " \(word) "
                default: return nil
                }
            }
            guard !words.isEmpty else { return nil }
            var base: String
            if words.count == 2, ["struct", "union", "enum"].contains(words[0]), isValidIdentifier(words[1]) {
                base = words.joined(separator: " ")
            } else if words.count == 1, context.callbacks[words[0]] != nil {
                let name = words[0]
                guard !context.unsupported.contains(name), !visiting.contains(name) else { return nil }
                // A callback typedef is a nominal parameter type. Its own
                // declaration supplies its signature; recursively revalidating
                // sibling references here would multiply work at each level.
                base = name
            } else if words.count == 1, let target = context.aliases[words[0]] {
                let name = words[0]
                guard !context.unsupported.contains(name), !visiting.contains(name) else { return nil }
                if target == [.identifier(name)], context.nominalAliases.contains(name) {
                    if let element = context.arrayElements[name] {
                        guard canonicalType(element, context: context, visiting: visiting.union([name])) != nil else { return nil }
                    }
                    base = name
                } else {
                    var visited = visiting
                    visited.insert(name)
                    guard let resolved = canonicalType(target, context: context, visiting: visited) else { return nil }
                    // Qualifying an alias-to-pointer qualifies the pointer itself;
                    // refuse rather than moving that qualifier to the pointee.
                    guard baseQualifiers.isEmpty || !resolved.contains("*") else { return nil }
                    base = resolved
                }
            } else {
                let primitives: Set<String> = ["void", "bool", "_Bool", "char", "signed", "unsigned", "short", "int", "long",
                                               "float", "double", "__int128", "int8_t", "uint8_t", "int16_t", "uint16_t",
                                               "int32_t", "uint32_t", "int64_t", "uint64_t", "size_t", "ssize_t",
                                               "intptr_t", "uintptr_t", "ptrdiff_t", "wchar_t"]
                guard words.allSatisfy({ primitives.contains($0) }),
                      let normalized = normalizePrimitive(words: words) else { return nil }
                base = normalized
            }
            if !baseQualifiers.isEmpty { base = baseQualifiers.joined(separator: " ") + " " + base }
            if !suffix.isEmpty { base += " " + suffix.trimmingCharacters(in: .whitespaces) }
            return base
        }
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case identifier(String)   // keywords + type names + field names
        case number(String)       // integer literal (decimal/hex), raw text
        case punct(Character)     // { } ; , * [ ] = ( ) etc.
        case pragmaPack(String)   // raw payload after `#pragma pack`, e.g. "(push, 1)"
    }

    private enum Tokenizer {
        static func tokenize(_ source: String, limit: Int) -> (tokens: [Token], truncated: Bool, unsupportedPreprocessing: Bool) {
            var tokens: [Token] = []
            let scalars = Array(source.unicodeScalars)
            var i = 0
            let n = scalars.count
            while i < n {
                if tokens.count >= limit { return (tokens, true, false) }
                let c = scalars[i]
                // Whitespace.
                if isSpace(c) { i += 1; continue }
                // Comments.
                if c == "/" && i + 1 < n {
                    if scalars[i + 1] == "/" { // line comment
                        i += 2
                        while i < n && scalars[i] != "\n" { i += 1 }
                        continue
                    }
                    if scalars[i + 1] == "*" { // block comment
                        i += 2
                        while i + 1 < n && !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
                        i = min(n, i + 2)
                        continue
                    }
                }
                // Only supported packing directives may enter subset parsing.
                // Any other directive invalidates the whole pasted import.
                if c == "#" || (c == "%" && i + 1 < n && scalars[i + 1] == ":") {
                    let lineStart = i
                    while i < n && scalars[i] != "\n" { i += 1 }
                    let line = String(String.UnicodeScalarView(scalars[lineStart..<i]))
                    if let payload = pragmaPackPayload(from: line) {
                        tokens.append(.pragmaPack(payload))
                    } else {
                        return ([], false, true)
                    }
                    continue
                }
                // Identifier / keyword: [A-Za-z_][A-Za-z0-9_]*
                if isIdentStart(c) {
                    var j = i + 1
                    while j < n && isIdentCont(scalars[j]) { j += 1 }
                    tokens.append(.identifier(String(String.UnicodeScalarView(scalars[i..<j]))))
                    i = j
                    continue
                }
                // Number: decimal or hex (0x…), optional unsigned/long suffix.
                if isDigit(c) {
                    var j = i + 1
                    while j < n && isNumberCont(scalars[j]) { j += 1 }
                    tokens.append(.number(String(String.UnicodeScalarView(scalars[i..<j]))))
                    i = j
                    continue
                }
                // Single-character punctuation (anything else). Negative enum
                // values are handled by treating '-' as punctuation the parser
                // can attach to a following number.
                tokens.append(.punct(Character(c)))
                i += 1
            }
            return (tokens, false, false)
        }

        private static func isSpace(_ c: Unicode.Scalar) -> Bool {
            c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}"
        }
        private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        private static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_"
        }
        private static func isIdentCont(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) }
        private static func isNumberCont(_ c: Unicode.Scalar) -> Bool {
            isDigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F") || c == "x" || c == "X"
                || c == "u" || c == "U" || c == "l" || c == "L"
        }

        private static func pragmaPackPayload(from line: String) -> String? {
            var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.first == "#" else { return nil }
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("pragma"), text.dropFirst(6).first?.isWhitespace == true else { return nil }
            text.removeFirst("pragma".count)
            text = text.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("pack"), let next = text.dropFirst(4).first, next.isWhitespace || next == "(" else { return nil }
            text.removeFirst("pack".count)
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Parser

    private struct DeclParser {
        let tokens: [Token]
        var pos = 0
        let idProvider: () -> UUID
        var types: [TypeDefinition] = []
        var diagnostics: [String] = []
        /// Names already recovered this run, so an in-file duplicate is skipped
        /// with a diagnostic rather than emitting two same-named types (which the
        /// catalog's UNIQUE(name) index would later abort the whole save on).
        var seenNames: Set<String> = []
        var currentPackAlignment: Int? = nil
        var packAlignmentStack: [Int?] = []
        var prototypeRanges: [Int: Int] = [:]
        var signatureContext = PrototypeParser.Context()

        private struct ParsedAttributes {
            var layoutIsUnknown = false
            var isPacked = false
            var vectorByteSize: Int? = nil
            var minimumAlignment: Int? = nil

            mutating func merge(_ other: ParsedAttributes) {
                layoutIsUnknown = layoutIsUnknown || other.layoutIsUnknown
                isPacked = isPacked || other.isPacked
                vectorByteSize = other.vectorByteSize ?? vectorByteSize
                if let alignment = other.minimumAlignment {
                    minimumAlignment = max(minimumAlignment ?? 1, alignment)
                }
            }
        }

        private struct MemberAlignment {
            var isAtomic: Bool? = nil
            var layoutIsUnknown: Bool? = nil
            var isPacked: Bool? = nil
            var minimumAlignment: Int? = nil
            var minimumAlignmentType: String? = nil

            var isEmpty: Bool {
                minimumAlignment == nil && minimumAlignmentType == nil && isPacked == nil && layoutIsUnknown == nil && isAtomic == nil
            }

            mutating func merge(_ other: MemberAlignment) {
                if other.isAtomic == true { isAtomic = true }
                if other.layoutIsUnknown == true { layoutIsUnknown = true }
                if other.isPacked == true { isPacked = true }
                if let alignment = other.minimumAlignment {
                    minimumAlignment = max(minimumAlignment ?? 1, alignment)
                }
                if minimumAlignmentType == nil {
                    minimumAlignmentType = other.minimumAlignmentType
                }
            }
        }

        private struct ParsedDeclarator {
            var name: String
            var loweredType: String
            var arrayDimensions: [UInt64]
            var declaratorSemanticsV1: FieldDef.DeclaratorSemanticsV1
            var functionPointerSignatureV1: FunctionPointerSignatureV1? = nil
        }

        init(tokens: [Token], idProvider: @escaping () -> UUID) {
            self.tokens = tokens
            self.idProvider = idProvider
        }

        mutating func parseAll() -> Result {
            // Top-level loop: each iteration must consume at least one token or we
            // force-advance, guaranteeing termination regardless of input.
            while pos < tokens.count {
                let start = pos
                parseTopLevelDecl()
                if pos == start { pos += 1 } // monotonic-cursor guard
            }
            return Result(types: types, diagnostics: diagnostics)
        }

        private mutating func parseTopLevelDecl() {
            // Prototype parsing uses the complete declaration and typedef context;
            // do not misreport an admitted function as a skipped type declaration.
            if let end = prototypeRanges[pos] {
                pos = end
                return
            }
            guard let tok = peek() else { return }
            switch tok {
            case .identifier("typedef"):
                advance()
                parseTypedef()
            case .identifier("struct"), .identifier("union"):
                let isUnion = tok == .identifier("union")
                advance()
                _ = parseRecord(isUnion: isUnion, aliasFromTypedef: nil)
            case .identifier("enum"):
                advance()
                _ = parseEnum(aliasFromTypedef: nil)
            case let .pragmaPack(payload):
                advance()
                applyPragmaPack(payload)
            case .punct(";"):
                advance() // stray semicolon
            default:
                // Unknown top-level construct (e.g. a bare function/global). Skip
                // to the next ';' or balanced '}' so one unsupported line doesn't
                // poison the rest of the file.
                let skipped = describeCurrentLine()
                skipToStatementEnd()
                diagnostics.append("Skipped unsupported top-level construct near “\(skipped)”.")
            }
        }

        // typedef <base> Alias ;
        // typedef struct [Tag] { … } Alias ;
        // typedef enum  [Tag] { … } Alias ;
        private mutating func parseTypedef() {
            guard let tok = peek() else {
                diagnostics.append("Skipped a `typedef` with no body.")
                return
            }
            if tok == .identifier("struct") || tok == .identifier("union") {
                let isUnion = tok == .identifier("union")
                advance()
                // Tagged record body, then a single trailing alias name.
                if let alias = parseRecordThenAlias(isUnion: isUnion) {
                    _ = alias
                }
                return
            }
            if tok == .identifier("enum") {
                advance()
                parseEnumThenAlias()
                return
            }
            // Plain alias: typedef <type-tokens…> Alias ;
            parsePlainTypedef()
        }

        private mutating func parsePlainTypedef() {
            if parseParenthesizedPointerTypedef() {
                return
            }

            // Collect type tokens until ';'. The LAST identifier is the alias; the
            // rest form the aliased base type (which we normalize). Pointers and a
            // trailing array suffixes are honored.
            var attributes = ParsedAttributes()
            var typeWords: [String] = []
            var stars = 0
            var arraySuffixes = ""
            var sawClose = false
            var guardCounter = 0
            while let t = peek(), guardCounter < 4096 {
                guardCounter += 1
                if t == .identifier("__attribute__") { attributes.merge(consumeAttributes()); continue }
                if t == .punct(";") { advance(); sawClose = true; break }
                if t == .punct("*") { stars += 1; advance(); continue }
                if t == .punct("[") {
                    guard let suffixes = parseArraySuffixes() else {
                        diagnostics.append("Skipped a malformed array `typedef`.")
                        skipToStatementEnd()
                        return
                    }
                    arraySuffixes += suffixes
                    continue
                }
                if case let .identifier(word) = t { typeWords.append(word); advance(); continue }
                if case .number = t { advance(); continue } // unexpected, tolerate
                // Anything else (e.g. '(') means a typedef shape we don't model.
                advance()
                diagnostics.append("Skipped an unsupported `typedef` form.")
                skipToStatementEnd()
                return
            }
            guard sawClose, typeWords.count >= 2 else {
                diagnostics.append("Skipped a malformed `typedef` (need `<type> <alias>;`).")
                return
            }
            let alias = typeWords.removeLast()
            guard isValidIdentifier(alias) else {
                diagnostics.append("Skipped a `typedef` with an invalid alias name.")
                return
            }
            guard var base = normalizePrimitive(words: typeWords) else {
                diagnostics.append("Skipped `typedef … \(alias)`: unsupported base type “\(typeWords.joined(separator: " "))”.")
                return
            }
            if stars > 0 { base += " " + String(repeating: "*", count: stars) }
            if !arraySuffixes.isEmpty { base += arraySuffixes }
            emit(
                kind: .typedef,
                name: alias,
                fields: [
                    FieldDef(
                        name: alias,
                        type: base,
                        declaratorSemanticsV1: .ordinary,
                        isAtomic: typeWords.contains("_Atomic") ? true : nil
                    ),
                ],
                attributes: attributes
            )
        }

        private mutating func parseParenthesizedPointerTypedef() -> Bool {
            let start = pos
            var typeWords: [String] = []
            var returnStars = 0
            var guardCounter = 0
            while let t = peek(), guardCounter < 256 {
                guardCounter += 1
                if t == .punct("(") { break }
                if t == .punct("*") {
                    returnStars += 1
                    advance()
                    continue
                }
                if case let .identifier(word) = t {
                    typeWords.append(word)
                    advance()
                    continue
                }
                pos = start
                return false
            }
            guard peek() == .punct("("),
                  let declarator = parseParenthesizedPointerDeclarator(
                    typeWords: typeWords,
                    returnStars: returnStars
                  )
            else {
                pos = start
                return false
            }
            consumeTrailingSemicolon()
            emit(
                kind: .typedef,
                name: declarator.name,
                fields: [makeField(from: declarator)]
            )
            return true
        }

        // After `typedef struct` (the struct keyword already consumed).
        private mutating func parseRecordThenAlias(isUnion: Bool) -> String? {
            var attributes = consumeAttributes()
            let tag = consumeOptionalTag()
            attributes.merge(consumeAttributes())
            guard let fields = parseBraceFields() else {
                // parseBraceFields already emitted a diagnostic / skipped.
                return nil
            }
            attributes.merge(consumeAttributes())
            // Trailing alias name(s) before ';'. Use the first identifier as the
            // catalog name; fall back to the tag if the alias is missing.
            let alias = consumeTypedefAlias()
            let name = alias ?? tag
            guard let name, isValidIdentifier(name) else {
                diagnostics.append("Skipped a `typedef \(isUnion ? "union" : "struct")` with no usable name.")
                return nil
            }
            emit(kind: isUnion ? .union : .struct, name: name, fields: fields, attributes: attributes)
            return name
        }

        private mutating func parseEnumThenAlias() {
            var attributes = consumeAttributes()
            let tag = consumeOptionalTag()
            attributes.merge(consumeAttributes())
            guard let cases = parseEnumBody() else { return }
            attributes.merge(consumeAttributes())
            let alias = consumeTypedefAlias()
            let name = alias ?? tag
            guard let name, isValidIdentifier(name) else {
                diagnostics.append("Skipped a `typedef enum` with no usable name.")
                return
            }
            emit(kind: .enum, name: name, fields: cases.fields, attributes: attributes, enumValuesIncomplete: cases.incomplete ? true : nil)
        }

        // struct/union (keyword already consumed). Returns the recovered name.
        @discardableResult
        private mutating func parseRecord(isUnion: Bool, aliasFromTypedef: String?) -> String? {
            var attributes = consumeAttributes()
            let tag = consumeOptionalTag()
            attributes.merge(consumeAttributes())
            guard let fields = parseBraceFields() else { return nil }
            attributes.merge(consumeAttributes())
            consumeTrailingSemicolon()
            let name = aliasFromTypedef ?? tag
            guard let name, isValidIdentifier(name) else {
                diagnostics.append("Skipped an anonymous \(isUnion ? "union" : "struct") (no tag/typedef name).")
                return nil
            }
            emit(kind: isUnion ? .union : .struct, name: name, fields: fields, attributes: attributes)
            return name
        }

        @discardableResult
        private mutating func parseEnum(aliasFromTypedef: String?) -> String? {
            var attributes = consumeAttributes()
            let tag = consumeOptionalTag()
            attributes.merge(consumeAttributes())
            guard let cases = parseEnumBody() else { return nil }
            attributes.merge(consumeAttributes())
            consumeTrailingSemicolon()
            let name = aliasFromTypedef ?? tag
            guard let name, isValidIdentifier(name) else {
                diagnostics.append("Skipped an anonymous enum (no tag/typedef name).")
                return nil
            }
            emit(kind: .enum, name: name, fields: cases.fields, attributes: attributes, enumValuesIncomplete: cases.incomplete ? true : nil)
            return name
        }

        // MARK: brace field bodies

        /// Parses a `{ field; field; … }` body into ordered `FieldDef`s. Returns
        /// nil (with a diagnostic) on a missing/unbalanced brace. A single
        /// invalid declaration may be skipped with a diagnostic. Unsupported but
        /// syntactically recognizable members remain as unknown layout poison points.
        private mutating func parseBraceFields() -> [FieldDef]? {
            guard peek() == .punct("{") else {
                diagnostics.append("Skipped a struct/union without a `{ … }` body.")
                skipToStatementEnd()
                return nil
            }
            advance() // consume '{'
            var fields: [FieldDef] = []
            var guardCounter = 0
            while let t = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if t == .punct("}") { advance(); break }
                if t == .punct(";") { advance(); continue } // empty statement
                if case let .pragmaPack(payload) = t {
                    diagnostics.append("Ignored `#pragma pack\(payload)` inside a record body.")
                    advance()
                    continue
                }
                let before = pos
                if let fieldList = parseFieldDeclaration() {
                    fields.append(contentsOf: fieldList)
                } else {
                    // parseFieldDeclaration skipped to the next ';'. If it made no
                    // progress, force-advance to keep the cursor monotonic.
                    if pos == before { advance() }
                }
            }
            return fields
        }

        /// Parses one `type name[ , name2 …] ;` field declaration into one or more
        /// `FieldDef`s (C allows `int a, b;`). Inline struct/union fields carry
        /// aggregate metadata so layout can either keep a named member or promote a
        /// C11 anonymous aggregate member; integer bit-fields carry `FieldDef.bitWidth`.
        private mutating func parseFieldDeclaration() -> [FieldDef]? {
            guard var declarationAlignment = consumeMemberAlignmentSpecifiers() else {
                return nil
            }
            // A field whose type is an inline record is handled before the generic
            // type-word parser. Plain references (`struct Tag *p;`, `struct Tag t;`)
            // fall through; the keyword is later dropped by `normalizePrimitive`.
            if peek() == .identifier("struct") || peek() == .identifier("union") {
                if fieldStartsInlineRecord() {
                    return parseInlineAggregateFieldDeclaration(memberAlignment: declarationAlignment)
                }
            } else if peek() == .identifier("enum"), fieldStartsInlineRecord() {
                diagnostics.append("Skipped a nested/inline enum field (not supported).")
                skipFieldToSemicolon()
                return nil
            }
            var typeWords: [String] = []
            var guardCounter = 0
            // Gather leading type identifiers (e.g. "unsigned long").
            while let t = peek(), guardCounter < 256 {
                guardCounter += 1
                if case let .identifier(word) = t {
                    // Stop when the next token starts a declarator (* or the name
                    // followed by ; , [). We can't know until we see the name, so
                    // we collect identifiers greedily and split off the last as the
                    // field name below.
                    typeWords.append(word)
                    advance()
                    // Peek: if a '*' or '[' or the next identifier follows, keep going;
                    // but if punctuation that ends the declarator follows, stop.
                    if peek() == .punct("*") || peek() == .punct(";") || peek() == .punct(",") || peek() == .punct("[") || isMemberAlignmentSpecifierStart(peek()) {
                        break
                    }
                    continue
                }
                break
            }
            if typeWords.contains("_Atomic") { declarationAlignment.isAtomic = true }
            // Pointers between type and name — consume BEFORE validating the word
            // count. A pointer field (`void * context`, `int *p`) has its name AFTER
            // the stars, so only the type word(s) are in `typeWords` (need >= 1); a
            // non-pointer field carries the name as the trailing type word (need >= 2).
            var stars = 0
            while peek() == .punct("*") { stars += 1; advance() }
            // Unnamed bit-field (`T : N` / `T : 0`). This must be recognized before
            // the type/name guard below, because there is deliberately no name. A
            // named bit-field also has `:` after the greedily collected words
            // (`unsigned a : 3`), so only take this branch when all words form a type.
            if peek() == .punct(":"), stars == 0, let baseType = normalizePrimitive(words: typeWords) {
                guard let field = parseBitFieldDeclarator(name: "", type: baseType) else {
                    skipFieldToSemicolon()
                    return nil
                }
                var result = [field]
                var bitAlignment = declarationAlignment
                guard consumeMemberAlignmentSpecifiers(into: &bitAlignment) else { return nil }
                apply(bitAlignment, to: &result)
                parseAdditionalDeclarators(into: &result, baseType: baseType, typeWords: typeWords, firstFieldName: "", memberAlignment: declarationAlignment)
                consumeTrailingSemicolon()
                return result
            }
            if peek() == .punct("(") {
                if let declarator = parseParenthesizedPointerDeclarator(
                    typeWords: typeWords,
                    returnStars: stars
                ) {
                    var field = makeField(from: declarator)
                    var fieldAlignment = declarationAlignment
                    let attributesWereBalanced = consumeMemberAlignmentSpecifiers(into: &fieldAlignment)
                    apply(fieldAlignment, to: &field)
                    if !attributesWereBalanced {
                        return [field]
                    }
                    consumeTrailingSemicolon()
                    return [field]
                }
                diagnostics.append("Skipped a parenthesized pointer field with an unsupported declarator.")
                skipFieldToSemicolon()
                if typeWords.contains("_Atomic") {
                    return [FieldDef(name: "", type: "_Atomic", declaratorSemanticsV1: .ordinary, layoutIsUnknown: true)]
                }
                return nil
            }
            guard typeWords.count >= (stars > 0 ? 1 : 2) else {
                diagnostics.append("Skipped a field with no type/name pair.")
                skipFieldToSemicolon()
                return nil
            }
            // The field name is the last identifier collected *unless* a '*' was
            // consumed (then the name follows the stars). Handle both: if we saw
            // stars, the name is the next identifier; else it's typeWords.last.
            var fieldName: String
            if stars > 0 {
                guard case let .identifier(name)? = peek() else {
                    diagnostics.append("Skipped a pointer field with no name.")
                    skipFieldToSemicolon()
                    return nil
                }
                fieldName = name
                advance()
            } else {
                fieldName = typeWords.removeLast()
            }
            guard !typeWords.isEmpty, isValidIdentifier(fieldName) else {
                diagnostics.append("Skipped a field with an invalid name “\(fieldName)”.")
                skipFieldToSemicolon()
                return nil
            }
            guard var baseType = normalizePrimitive(words: typeWords) else {
                diagnostics.append("Unknown layout for field “\(fieldName)”: unsupported type “\(typeWords.joined(separator: " "))”.")
                skipFieldToSemicolon()
                return [FieldDef(name: fieldName, type: typeWords.joined(separator: " "), declaratorSemanticsV1: .ordinary, layoutIsUnknown: true)]
            }
            if stars > 0 { baseType += " " + String(repeating: "*", count: stars) }
            // Bit-field (`name : N`).
            if peek() == .punct(":") {
                guard let field = parseBitFieldDeclarator(name: fieldName, type: baseType) else {
                    skipFieldToSemicolon()
                    return nil
                }
                var result = [field]
                var bitAlignment = declarationAlignment
                guard consumeMemberAlignmentSpecifiers(into: &bitAlignment) else { return nil }
                apply(bitAlignment, to: &result)
                parseAdditionalDeclarators(into: &result, baseType: baseType, typeWords: typeWords, firstFieldName: fieldName, memberAlignment: declarationAlignment)
                consumeTrailingSemicolon()
                return result
            }
            // Optional array suffix on the name.
            var fieldType = baseType
            if peek() == .punct("[") {
                if let suffix = parseArraySuffixes() {
                    fieldType += suffix
                } else {
                    diagnostics.append("Unknown layout for field “\(fieldName)”: unsupported array size.")
                    skipFieldToSemicolon()
                    return [FieldDef(name: fieldName, type: fieldType, declaratorSemanticsV1: .ordinary, layoutIsUnknown: true)]
                }
            }
            var fieldAlignment = declarationAlignment
            let attributesWereBalanced = consumeMemberAlignmentSpecifiers(into: &fieldAlignment)
            var result = [FieldDef(
                name: fieldName,
                type: fieldType,
                declaratorSemanticsV1: .ordinary,
                isPacked: fieldAlignment.isPacked,
                layoutIsUnknown: fieldAlignment.layoutIsUnknown,
                isAtomic: fieldAlignment.isAtomic,
                minimumAlignment: fieldAlignment.minimumAlignment,
                minimumAlignmentType: fieldAlignment.minimumAlignmentType
            )]
            if !attributesWereBalanced {
                return result
            }
            parseAdditionalDeclarators(into: &result, baseType: baseType, typeWords: typeWords, firstFieldName: fieldName, memberAlignment: declarationAlignment)
            consumeTrailingSemicolon()
            return result
        }

        private mutating func parseInlineAggregateFieldDeclaration(memberAlignment: MemberAlignment) -> [FieldDef]? {
            guard peek() == .identifier("struct") || peek() == .identifier("union") else { return nil }
            let isUnion = peek() == .identifier("union")
            let kind: TypeKind = isUnion ? .union : .struct
            let kindName = isUnion ? "union" : "struct"
            advance()

            var attributes = consumeAttributes()
            let tag = consumeOptionalTag()
            attributes.merge(consumeAttributes())
            guard let aggregateFields = parseBraceFields() else { return nil }
            attributes.merge(consumeAttributes())
            let baseType = tag ?? "anonymous \(kindName)"
            let inlineRules = layoutRules(from: attributes)

            var stars = 0
            while peek() == .punct("*") {
                stars += 1
                advance()
            }

            if peek() == .punct(";") {
                advance()
                guard stars == 0 else {
                    diagnostics.append("Skipped an unnamed pointer to an inline \(kindName) member.")
                    return []
                }
                guard tag == nil else {
                    diagnostics.append("Skipped tagged unnamed \(kindName) member “\(tag!)” (not a C11 anonymous aggregate member).")
                    return []
                }
                return [
                    FieldDef(
                        name: "",
                        type: baseType,
                        declaratorSemanticsV1: .ordinary,
                        isPacked: memberAlignment.isPacked,
                        layoutIsUnknown: memberAlignment.layoutIsUnknown,
                        isAtomic: memberAlignment.isAtomic,
                        minimumAlignment: memberAlignment.minimumAlignment,
                        minimumAlignmentType: memberAlignment.minimumAlignmentType,
                        inlineAggregateKind: kind,
                        inlineFields: aggregateFields,
                        inlineAggregateLayoutRules: inlineRules,
                        promotesInlineFields: true
                    ),
                ]
            }

            guard case let .identifier(fieldName)? = peek(), isValidIdentifier(fieldName) else {
                diagnostics.append("Skipped an inline \(kindName) field with no valid member name.")
                skipFieldToSemicolon()
                return nil
            }
            advance()

            var result: [FieldDef] = []
            if stars > 0 {
                var pointerType = baseType + " " + String(repeating: "*", count: stars)
                if peek() == .punct("[") {
                    if let suffix = parseArraySuffixes() {
                        pointerType += suffix
                    } else {
                        diagnostics.append("Skipped field “\(fieldName)”: malformed array size.")
                        skipFieldToSemicolon()
                        return nil
                    }
                }
                result.append(FieldDef(
                    name: fieldName,
                    type: pointerType,
                    declaratorSemanticsV1: .ordinary,
                    isPacked: memberAlignment.isPacked,
                    layoutIsUnknown: memberAlignment.layoutIsUnknown,
                    isAtomic: memberAlignment.isAtomic,
                    minimumAlignment: memberAlignment.minimumAlignment,
                    minimumAlignmentType: memberAlignment.minimumAlignmentType
                ))
            } else {
                if peek() == .punct("[") {
                    diagnostics.append("Skipped field “\(fieldName)”: arrays of inline \(kindName) members are not supported.")
                    skipFieldToSemicolon()
                    return [FieldDef(name: fieldName, type: baseType, declaratorSemanticsV1: .ordinary, layoutIsUnknown: true)]
                }
                result.append(
                    FieldDef(
                        name: fieldName,
                        type: baseType,
                        declaratorSemanticsV1: .ordinary,
                        isPacked: memberAlignment.isPacked,
                        layoutIsUnknown: memberAlignment.layoutIsUnknown,
                        isAtomic: memberAlignment.isAtomic,
                        minimumAlignment: memberAlignment.minimumAlignment,
                        minimumAlignmentType: memberAlignment.minimumAlignmentType,
                        inlineAggregateKind: kind,
                        inlineFields: aggregateFields,
                        inlineAggregateLayoutRules: inlineRules
                    )
                )
            }

            var trailingAlignment = memberAlignment
            guard consumeMemberAlignmentSpecifiers(into: &trailingAlignment) else { return result }
            apply(trailingAlignment, to: &result)
            parseAdditionalInlineAggregateDeclarators(
                into: &result,
                kind: kind,
                kindName: kindName,
                baseType: baseType,
                aggregateFields: aggregateFields,
                inlineRules: inlineRules,
                memberAlignment: memberAlignment,
                firstFieldName: fieldName
            )
            consumeTrailingSemicolon()
            return result
        }

        private mutating func parseAdditionalInlineAggregateDeclarators(
            into result: inout [FieldDef],
            kind: TypeKind,
            kindName: String,
            baseType: String,
            aggregateFields: [FieldDef],
            inlineRules: AggregateLayoutRules,
            memberAlignment: MemberAlignment,
            firstFieldName: String
        ) {
            while peek() == .punct(",") {
                advance()
                var stars = 0
                while peek() == .punct("*") {
                    stars += 1
                    advance()
                }
                guard case let .identifier(name)? = peek(), isValidIdentifier(name) else {
                    diagnostics.append("Skipped a malformed comma-declarator in “\(firstFieldName)”'s declaration.")
                    skipFieldToSemicolon()
                    return
                }
                advance()

                if stars > 0 {
                    var pointerType = baseType + " " + String(repeating: "*", count: stars)
                    if peek() == .punct("[") {
                        if let suffix = parseArraySuffixes() {
                            pointerType += suffix
                        } else {
                            diagnostics.append("Skipped field “\(name)”: malformed array size.")
                            skipFieldToSemicolon()
                            return
                        }
                    }
                    result.append(FieldDef(
                        name: name,
                        type: pointerType,
                        declaratorSemanticsV1: .ordinary,
                        isPacked: memberAlignment.isPacked,
                        layoutIsUnknown: memberAlignment.layoutIsUnknown,
                        isAtomic: memberAlignment.isAtomic,
                        minimumAlignment: memberAlignment.minimumAlignment,
                        minimumAlignmentType: memberAlignment.minimumAlignmentType
                    ))
                    var alignment = memberAlignment
                    guard consumeMemberAlignmentSpecifiers(into: &alignment) else { return }
                    apply(alignment, to: &result[result.count - 1])
                    continue
                }

                if peek() == .punct("[") {
                    diagnostics.append("Skipped field “\(name)”: arrays of inline \(kindName) members are not supported.")
                    skipFieldToSemicolon()
                    result.append(FieldDef(name: name, type: baseType, declaratorSemanticsV1: .ordinary, layoutIsUnknown: true))
                    return
                }

                result.append(
                    FieldDef(
                        name: name,
                        type: baseType,
                        declaratorSemanticsV1: .ordinary,
                        isPacked: memberAlignment.isPacked,
                        layoutIsUnknown: memberAlignment.layoutIsUnknown,
                        isAtomic: memberAlignment.isAtomic,
                        minimumAlignment: memberAlignment.minimumAlignment,
                        minimumAlignmentType: memberAlignment.minimumAlignmentType,
                        inlineAggregateKind: kind,
                        inlineFields: aggregateFields,
                        inlineAggregateLayoutRules: inlineRules
                    )
                )
                var alignment = memberAlignment
                guard consumeMemberAlignmentSpecifiers(into: &alignment) else { return }
                apply(alignment, to: &result[result.count - 1])
            }
        }

        private mutating func parseAdditionalDeclarators(
            into result: inout [FieldDef],
            baseType: String,
            typeWords: [String],
            firstFieldName: String,
            memberAlignment: MemberAlignment
        ) {
            // Additional comma-separated declarators sharing the base type.
            while peek() == .punct(",") {
                advance()
                var fieldAlignment = memberAlignment
                guard consumeMemberAlignmentSpecifiers(into: &fieldAlignment) else {
                    return
                }
                if peek() == .punct(":") {
                    if var field = parseBitFieldDeclarator(name: "", type: baseType) {
                        guard consumeMemberAlignmentSpecifiers(into: &fieldAlignment) else { return }
                        apply(fieldAlignment, to: &field)
                        result.append(field)
                        continue
                    }
                    skipFieldToSemicolon()
                    return
                }

                var moreStars = 0
                while peek() == .punct("*") { moreStars += 1; advance() }
                guard case let .identifier(more)? = peek(), isValidIdentifier(more) else {
                    diagnostics.append("Skipped a malformed comma-declarator in “\(firstFieldName)”'s declaration.")
                    skipFieldToSemicolon()
                    return
                }
                advance()
                var t2 = baseType
                if moreStars > 0 {
                    t2 = (typeWords.isEmpty ? baseType : (normalizePrimitive(words: typeWords) ?? baseType)) + " " + String(repeating: "*", count: moreStars)
                }
                if peek() == .punct(":") {
                    if var field = parseBitFieldDeclarator(name: more, type: t2) {
                        guard consumeMemberAlignmentSpecifiers(into: &fieldAlignment) else { return }
                        apply(fieldAlignment, to: &field)
                        result.append(field)
                        continue
                    }
                    skipFieldToSemicolon()
                    return
                }
                if peek() == .punct("[") {
                    if let suffix = parseArraySuffixes() {
                        t2 += suffix
                    } else {
                        diagnostics.append("Unknown layout for field “\(more)”: unsupported array size.")
                        result.append(FieldDef(name: more, type: t2, declaratorSemanticsV1: .ordinary, layoutIsUnknown: true))
                        // The caller owns the trailing semicolon. Consuming it
                        // here would also discard the next field during recovery.
                        return
                    }
                }
                let attributesWereBalanced = consumeMemberAlignmentSpecifiers(into: &fieldAlignment)
                result.append(FieldDef(
                    name: more,
                    type: t2,
                    declaratorSemanticsV1: .ordinary,
                    isPacked: fieldAlignment.isPacked,
                    layoutIsUnknown: fieldAlignment.layoutIsUnknown,
                    isAtomic: fieldAlignment.isAtomic,
                    minimumAlignment: fieldAlignment.minimumAlignment,
                    minimumAlignmentType: fieldAlignment.minimumAlignmentType
                ))
                if !attributesWereBalanced {
                    return
                }
            }
        }

        private mutating func parseBitFieldDeclarator(name: String, type: String) -> FieldDef? {
            let label = name.isEmpty ? "unnamed bit-field" : "bit-field “\(name)”"
            guard let width = parseBitFieldWidth() else {
                diagnostics.append("Unknown layout for \(label): unsupported width expression.")
                return FieldDef(name: name, type: type, declaratorSemanticsV1: .ordinary, layoutIsUnknown: true)
            }
            guard width > 0 || name.isEmpty else {
                diagnostics.append("Skipped \(label): zero-width bit-fields must be unnamed.")
                return nil
            }
            let catalog = Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let capacity = TypeDefinition.bitFieldValueCapacityBits(type, in: catalog)
            if capacity == nil, TypeDefinition.size(ofType: type, in: catalog) != nil {
                diagnostics.append("Skipped \(label): non-integer type “\(type)”.")
                return nil
            }
            if let capacity, width > capacity {
                diagnostics.append("Skipped \(label): width \(width) exceeds \(type)'s \(capacity)-bit capacity.")
                return nil
            }
            return FieldDef(
                name: name,
                type: type,
                declaratorSemanticsV1: .ordinary,
                bitWidth: width
            )
        }

        /// Parses the C declarator family whose field name sits inside `(*name)`:
        /// function pointers (`T (*f)(...)`), pointer-to-array (`T (*p)[N]`), arrays
        /// of function pointers (`T (*f[N])(...)`), and function pointers whose
        /// return type is itself a pointer (`T *(*f)(...)`). The stored field type is
        /// intentionally a pointer-sized surrogate that the existing layout model
        /// already understands: `T *`, or `T *[N]` for arrays of function pointers.
        private mutating func parseParenthesizedPointerDeclarator(
            typeWords: [String],
            returnStars: Int
        ) -> ParsedDeclarator? {
            let start = pos
            guard peek() == .punct("(") else { return nil }
            guard var baseType = normalizePrimitive(words: typeWords) else { return nil }
            if returnStars > 0 {
                baseType += " " + String(repeating: "*", count: returnStars)
            }

            advance() // '('
            guard peek() == .punct("*") else { pos = start; return nil }
            advance()
            guard case let .identifier(fieldName)? = peek(), isValidIdentifier(fieldName) else {
                pos = start
                return nil
            }
            advance()

            let carrierArrayDimensions: [UInt64]
            if peek() == .punct("[") {
                guard let dimensions = parseFixedArrayDimensions() else {
                    pos = start
                    return nil
                }
                carrierArrayDimensions = dimensions
            } else {
                carrierArrayDimensions = []
            }
            guard peek() == .punct(")") else { pos = start; return nil }
            advance()

            let pointerType = pointerSizedType(from: baseType)
            if peek() == .punct("(") {
                let parameterStart = pos + 1
                guard consumeBalancedParentheses() else { pos = start; return nil }
                let signature = PrototypeParser.signature(
                    returnTokens: typeWords.map(Token.identifier) + Array(repeating: .punct("*"), count: returnStars),
                    parameterTokens: Array(tokens[parameterStart..<(pos - 1)]), context: signatureContext)
                let semantics: FieldDef.DeclaratorSemanticsV1 = carrierArrayDimensions.isEmpty
                    ? .functionPointerCarrier
                    : .arrayOfFunctionPointerCarrier
                return ParsedDeclarator(
                    name: fieldName,
                    loweredType: pointerType,
                    arrayDimensions: carrierArrayDimensions,
                    declaratorSemanticsV1: semantics,
                    functionPointerSignatureV1: signature
                )
            }
            if peek() == .punct("[") {
                // The closed provenance vocabulary has no array-of-pointer-to-array
                // case, so do not silently discard an inner carrier dimension.
                guard carrierArrayDimensions.isEmpty,
                      let pointeeArrayDimensions = parseFixedArrayDimensions()
                else {
                    pos = start
                    return nil
                }
                return ParsedDeclarator(
                    name: fieldName,
                    loweredType: pointerType,
                    arrayDimensions: pointeeArrayDimensions,
                    declaratorSemanticsV1: .pointerToArrayCarrier
                )
            }

            pos = start
            return nil
        }

        private func makeField(from declarator: ParsedDeclarator) -> FieldDef {
            var loweredType = declarator.loweredType
            if declarator.declaratorSemanticsV1 == .arrayOfFunctionPointerCarrier {
                loweredType += renderArraySuffixes(declarator.arrayDimensions)
            }
            return FieldDef(
                name: declarator.name,
                type: loweredType,
                declaratorSemanticsV1: declarator.declaratorSemanticsV1,
                functionPointerSignatureV1: declarator.functionPointerSignatureV1
            )
        }

        private mutating func applyPragmaPack(_ payload: String) {
            let trimmed = payload.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else {
                diagnostics.append("Ignored unsupported `#pragma pack\(payload)`.")
                return
            }
            let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty {
                currentPackAlignment = nil
                return
            }

            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let command = parts.first else { return }
            switch command {
            case "push":
                guard parts.count <= 2 else {
                    diagnostics.append("Ignored unsupported `#pragma pack\(payload)`.")
                    return
                }
                if parts.count == 2 {
                    let parsed = parsePackAlignment(parts[1])
                    guard parsed.isValid else {
                        diagnostics.append("Ignored unsupported `#pragma pack\(payload)`.")
                        return
                    }
                    packAlignmentStack.append(currentPackAlignment)
                    currentPackAlignment = parsed.value
                } else {
                    packAlignmentStack.append(currentPackAlignment)
                }
            case "pop":
                guard parts.count == 1 else {
                    diagnostics.append("Ignored unsupported `#pragma pack\(payload)`.")
                    return
                }
                if let restored = packAlignmentStack.popLast() {
                    currentPackAlignment = restored
                } else {
                    diagnostics.append("Ignored `#pragma pack(pop)` with an empty stack.")
                }
            default:
                let parsed = parsePackAlignment(command)
                guard parts.count == 1, parsed.isValid else {
                    diagnostics.append("Ignored unsupported `#pragma pack\(payload)`.")
                    return
                }
                currentPackAlignment = parsed.value
            }
        }

        private func parsePackAlignment(_ text: String) -> (isValid: Bool, value: Int?) {
            guard let value = parseIntegerLiteral(text), value >= 0, value <= Int64(Int.max) else {
                return (false, nil)
            }
            return (true, value == 0 ? nil : Int(value))
        }

        private mutating func consumeAttributes() -> ParsedAttributes {
            var result = ParsedAttributes()
            while peek() == .identifier("__attribute__") {
                guard let tokens = consumeAttributeInvocation() else {
                    diagnostics.append("Ignored malformed `__attribute__`.")
                    break
                }
                result.merge(parseAttributes(from: tokens))
            }
            return result
        }

        private mutating func consumeAttributeInvocation() -> [Token]? {
            guard peek() == .identifier("__attribute__") else { return nil }
            advance()
            guard let outer = consumeParenthesizedTokens() else { return nil }
            guard outer.count >= 2, outer.first == .punct("("), outer.last == .punct(")") else {
                return []
            }
            return Array(outer.dropFirst().dropLast())
        }

        private func parseAttributes(from tokens: [Token]) -> ParsedAttributes {
            var attributes = ParsedAttributes()
            var index = 0
            while index < tokens.count {
                switch tokens[index] {
                case .identifier("__macscope_unknown_layout__"):
                    attributes.layoutIsUnknown = true
                    index += 1
                case .identifier("packed"):
                    attributes.isPacked = true
                    index += 1
                case .identifier("vector_size"):
                    index += 1
                    if let (argument, nextIndex) = parenthesizedTokens(in: tokens, startingAt: index) {
                        // Preserve unsupported sizes too: the layout resolver returns unknown.
                        attributes.vectorByteSize = numericAlignment(from: argument) ?? -1
                        index = nextIndex
                    } else {
                        attributes.vectorByteSize = -1
                    }
                case .identifier("aligned"):
                    index += 1
                    if let (argument, nextIndex) = parenthesizedTokens(in: tokens, startingAt: index) {
                        if let alignment = numericAlignment(from: argument) {
                            attributes.minimumAlignment = max(attributes.minimumAlignment ?? 1, alignment)
                        }
                        index = nextIndex
                    }
                default:
                    index += 1
                }
            }
            return attributes
        }

        private mutating func consumeAlignasSpecifiers() -> MemberAlignment {
            var result = MemberAlignment()
            while peek() == .identifier("_Alignas") || peek() == .identifier("alignas") {
                advance()
                guard let argument = consumeParenthesizedTokens() else {
                    diagnostics.append("Ignored malformed `_Alignas` specifier.")
                    break
                }
                if let alignment = numericAlignment(from: argument) {
                    result.merge(MemberAlignment(minimumAlignment: alignment))
                    continue
                }
                if let type = normalizedTypeName(from: argument) {
                    result.merge(MemberAlignment(minimumAlignmentType: type))
                    continue
                }
                diagnostics.append("Ignored unsupported `_Alignas` argument.")
            }
            return result
        }

        private mutating func consumeMemberAlignmentSpecifiers() -> MemberAlignment? {
            var result = MemberAlignment()
            guard consumeMemberAlignmentSpecifiers(into: &result) else {
                return nil
            }
            return result
        }

        @discardableResult
        private mutating func consumeMemberAlignmentSpecifiers(into result: inout MemberAlignment) -> Bool {
            while true {
                if peek() == .identifier("_Alignas") || peek() == .identifier("alignas") {
                    advance()
                    guard let argument = consumeMemberParenthesizedTokens() else {
                        diagnostics.append("Skipped field with malformed member `_Alignas` specifier.")
                        skipFieldToSemicolon()
                        return false
                    }
                    mergeAlignasArgument(argument, into: &result)
                    continue
                }

                if peek() == .identifier("__attribute__") {
                    guard let tokens = consumeMemberAttributeInvocation() else {
                        diagnostics.append("Skipped field with malformed member `__attribute__`.")
                        skipFieldToSemicolon()
                        return false
                    }
                    mergeMemberAttributes(from: tokens, into: &result)
                    continue
                }

                return true
            }
        }

        private mutating func consumeMemberAttributeInvocation() -> [Token]? {
            guard peek() == .identifier("__attribute__") else { return nil }
            advance()
            guard let outer = consumeMemberParenthesizedTokens() else { return nil }
            guard outer.count >= 2, outer.first == .punct("("), outer.last == .punct(")") else {
                diagnostics.append("Ignored member `__attribute__` without GCC's double-parentheses form.")
                return []
            }
            return Array(outer.dropFirst().dropLast())
        }

        private mutating func consumeMemberParenthesizedTokens() -> [Token]? {
            guard peek() == .punct("(") else { return nil }
            advance()
            var depth = 1
            var content: [Token] = []
            var guardCounter = 0
            while let token = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if token == .punct(";") || token == .punct("}") {
                    return nil
                }
                if token == .punct("(") {
                    depth += 1
                    content.append(token)
                    advance()
                    continue
                }
                if token == .punct(")") {
                    advance()
                    depth -= 1
                    if depth == 0 {
                        return content
                    }
                    content.append(token)
                    continue
                }
                content.append(token)
                advance()
            }
            return nil
        }

        private mutating func mergeAlignasArgument(_ argument: [Token], into result: inout MemberAlignment) {
            if let alignment = numericAlignment(from: argument) {
                result.merge(MemberAlignment(minimumAlignment: alignment))
                return
            }
            if let type = normalizedTypeName(from: argument) {
                result.merge(MemberAlignment(minimumAlignmentType: type))
                return
            }
            diagnostics.append("Ignored unsupported member alignment argument.")
        }

        private mutating func mergeMemberAttributes(from tokens: [Token], into result: inout MemberAlignment) {
            var index = 0
            while index < tokens.count {
                switch tokens[index] {
                case .identifier("vector_size"), .identifier("ext_vector_type"), .identifier("__macscope_unknown_layout__"):
                    result.layoutIsUnknown = true
                    index += 1
                case .identifier("packed"):
                    result.isPacked = true
                    index += 1
                case .identifier("aligned"):
                    index += 1
                    guard let (argument, nextIndex) = parenthesizedTokens(in: tokens, startingAt: index) else {
                        diagnostics.append("Ignored malformed member `aligned` attribute.")
                        continue
                    }
                    if let alignment = numericAlignment(from: argument) {
                        result.merge(MemberAlignment(minimumAlignment: alignment))
                    } else {
                        diagnostics.append("Ignored unsupported member `aligned` attribute argument.")
                    }
                    index = nextIndex
                default:
                    index += 1
                }
            }
        }

        private mutating func consumeParenthesizedTokens() -> [Token]? {
            guard peek() == .punct("(") else { return nil }
            advance()
            var depth = 1
            var content: [Token] = []
            var guardCounter = 0
            while let token = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if token == .punct("(") {
                    depth += 1
                    content.append(token)
                    advance()
                    continue
                }
                if token == .punct(")") {
                    advance()
                    depth -= 1
                    if depth == 0 {
                        return content
                    }
                    content.append(token)
                    continue
                }
                content.append(token)
                advance()
            }
            return nil
        }

        private func parenthesizedTokens(in tokens: [Token], startingAt index: Int) -> (tokens: [Token], nextIndex: Int)? {
            guard index < tokens.count, tokens[index] == .punct("(") else { return nil }
            var depth = 1
            var cursor = index + 1
            var content: [Token] = []
            while cursor < tokens.count {
                let token = tokens[cursor]
                if token == .punct("(") {
                    depth += 1
                    content.append(token)
                    cursor += 1
                    continue
                }
                if token == .punct(")") {
                    depth -= 1
                    cursor += 1
                    if depth == 0 {
                        return (content, cursor)
                    }
                    content.append(token)
                    continue
                }
                content.append(token)
                cursor += 1
            }
            return nil
        }

        private func numericAlignment(from tokens: [Token]) -> Int? {
            guard tokens.count == 1, case let .number(text) = tokens[0],
                  let value = parseIntegerLiteral(text), value > 0, value <= Int64(Int.max)
            else {
                return nil
            }
            return Int(value)
        }

        private func normalizedTypeName(from tokens: [Token]) -> String? {
            var words: [String] = []
            var stars = 0
            for token in tokens {
                switch token {
                case let .identifier(word):
                    words.append(word)
                case .punct("*"):
                    stars += 1
                default:
                    return nil
                }
            }
            guard var type = normalizePrimitive(words: words) else { return nil }
            if stars > 0 {
                type += " " + String(repeating: "*", count: stars)
            }
            return type
        }

        private func layoutRules(from attributes: ParsedAttributes) -> AggregateLayoutRules {
            AggregateLayoutRules(
                isPacked: attributes.isPacked,
                packAlignment: currentPackAlignment,
                minimumAlignment: attributes.minimumAlignment
            )
        }

        private func apply(_ alignment: MemberAlignment, to field: inout FieldDef) {
            guard !alignment.isEmpty else { return }
            // A later attribute cannot erase semantic flags established by the declarator.
            if alignment.isPacked == true { field.isPacked = true }
            if alignment.layoutIsUnknown == true { field.layoutIsUnknown = true }
            if alignment.isAtomic == true { field.isAtomic = true }
            if let minimumAlignment = alignment.minimumAlignment {
                field.minimumAlignment = max(field.minimumAlignment ?? 1, minimumAlignment)
            }
            if field.minimumAlignmentType == nil {
                field.minimumAlignmentType = alignment.minimumAlignmentType
            }
        }

        private func apply(_ alignment: MemberAlignment, to fields: inout [FieldDef]) {
            guard !alignment.isEmpty else { return }
            for index in fields.indices {
                apply(alignment, to: &fields[index])
            }
        }

        // MARK: enum bodies

        /// Parses `{ A, B = 3, C }` into ordered `FieldDef(name, value)` with
        /// auto-incrementing implicit values (C semantics: start at 0, each
        /// implicit case is previous+1; an explicit value resets the counter).
        private mutating func parseEnumBody() -> (fields: [FieldDef], incomplete: Bool)? {
            guard peek() == .punct("{") else {
                diagnostics.append("Skipped an enum without a `{ … }` body.")
                skipToStatementEnd()
                return nil
            }
            advance() // '{'
            var cases: [FieldDef] = []
            var incomplete = false
            var closed = false
            var next: String? = "0"
            var guardCounter = 0
            while let t = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if t == .punct("}") { advance(); closed = true; break }
                if t == .punct(",") { advance(); continue }
                guard case let .identifier(name) = t, isValidIdentifier(name) else {
                    incomplete = true
                    next = nil
                    diagnostics.append("Skipped a malformed enum case.")
                    // Force progress to the next comma or close.
                    advance()
                    continue
                }
                advance()
                var value = next
                if peek() == .punct("=") {
                    advance()
                    if let parsed = parseEnumValue() {
                        value = parsed
                    } else {
                        incomplete = true
                        next = nil
                        diagnostics.append("Skipped enum case “\(name)”: unparsable value.")
                        // Skip to next comma/close.
                        skipEnumValue()
                        continue
                    }
                }
                guard let value else {
                    incomplete = true
                    next = nil
                    diagnostics.append("Skipped enum case “\(name)”: implicit value overflow.")
                    continue
                }
                cases.append(
                    FieldDef(
                        name: name,
                        type: value,
                        declaratorSemanticsV1: .ordinary
                    )
                )
                if value.hasPrefix("-"), let signed = Int64(value) {
                    next = String(signed + 1)
                } else if let unsigned = UInt64(value), unsigned < UInt64.max {
                    next = String(unsigned + 1)
                } else {
                    next = nil
                }
            }
            return (cases, incomplete || !closed)
        }

        /// Parses an enum case value: optional leading '-' then a decimal/hex
        /// integer literal. Returns nil for anything else (e.g. an expression),
        /// so that case is skipped rather than mis-valued.
        private mutating func parseEnumValue() -> String? {
            var negative = false
            if peek() == .punct("-") { negative = true; advance() }
            else if peek() == .punct("+") { advance() }
            guard case let .number(text)? = peek() else { return nil }
            advance()
            // Unary minus on an unsigned C literal depends on its literal type;
            // decline those expressions instead of treating them as signed values.
            guard let magnitude = parseUnsignedIntegerLiteral(text),
                  !negative || (!text.lowercased().contains("u") && magnitude <= UInt64(Int64.max)) else { return nil }
            // Unsuffixed octal/hex/binary literals can choose unsigned int before
            // signed long. Their unary-minus result is not the signed magnitude.
            if negative, text.hasPrefix("0"), magnitude > UInt64(Int32.max) { return nil }
            // Reject if the very next token isn't a separator/close — that means an
            // expression (`A = 1 << 2`) we don't evaluate.
            if let after = peek(), after != .punct(",") && after != .punct("}") {
                return nil
            }
            return negative && magnitude != 0 ? "-" + String(magnitude) : String(magnitude)
        }

        // MARK: shared helpers

        /// True when the current `struct`/`union`/`enum` keyword introduces an
        /// inline/anonymous record body (`{` directly, or `Tag {`) rather than a
        /// reference to an existing named type (`Tag *p` / `Tag t`). Pure lookahead
        /// — does not advance the cursor.
        private func fieldStartsInlineRecord() -> Bool {
            // pos points at the keyword.
            let nextIndex = indexAfterAttributes(from: pos + 1)
            let next = nextIndex < tokens.count ? tokens[nextIndex] : nil
            if next == .punct("{") { return true }
            if case .identifier = next {
                let afterIndex = indexAfterAttributes(from: nextIndex + 1)
                let after = afterIndex < tokens.count ? tokens[afterIndex] : nil
                return after == .punct("{")
            }
            return false
        }

        private func indexAfterAttributes(from index: Int) -> Int {
            var cursor = index
            while cursor < tokens.count, tokens[cursor] == .identifier("__attribute__") {
                guard let next = indexAfterAttributeInvocation(startingAt: cursor) else {
                    return cursor + 1
                }
                cursor = next
            }
            return cursor
        }

        private func indexAfterAttributeInvocation(startingAt index: Int) -> Int? {
            guard index < tokens.count, tokens[index] == .identifier("__attribute__") else { return nil }
            let outerStart = index + 1
            guard outerStart < tokens.count, tokens[outerStart] == .punct("(") else { return index + 1 }
            return indexAfterBalancedParentheses(startingAt: outerStart)
        }

        private func indexAfterBalancedParentheses(startingAt index: Int) -> Int? {
            guard index < tokens.count, tokens[index] == .punct("(") else { return nil }
            var cursor = index
            var depth = 0
            while cursor < tokens.count {
                let token = tokens[cursor]
                if token == .punct("(") {
                    depth += 1
                } else if token == .punct(")") {
                    depth -= 1
                    if depth == 0 {
                        return cursor + 1
                    }
                }
                cursor += 1
            }
            return nil
        }

        private mutating func parseBitFieldWidth() -> Int? {
            guard peek() == .punct(":") else { return nil }
            advance()
            guard case let .number(text)? = peek() else { return nil }
            advance()
            guard let value = parseIntegerLiteral(text), value >= 0, value <= Int64(Int.max) else { return nil }
            // Never accept the numeric prefix of an unevaluated C expression.
            guard peek() == .punct(";") || peek() == .punct(",") || peek() == .punct("}")
                    || isMemberAlignmentSpecifierStart(peek()) else { return nil }
            return Int(value)
        }

        private mutating func parseArraySuffix() -> String? {
            // Assumes current token is '['. Consumes `[ N ]` and returns "[N]"
            // (or "[]" for a flexible array). Returns nil on malformed input.
            guard peek() == .punct("[") else { return nil }
            advance()
            if peek() == .punct("]") { advance(); return "[]" }
            guard case let .number(text)? = peek() else { return nil }
            advance()
            guard peek() == .punct("]") else { return nil }
            advance()
            guard let count = parseIntegerLiteral(text), count >= 0 else { return nil }
            return "[\(count)]"
        }

        private mutating func parseArraySuffixes() -> String? {
            var suffixes = ""
            while peek() == .punct("[") {
                guard let suffix = parseArraySuffix() else { return nil }
                suffixes += suffix
            }
            return suffixes.isEmpty ? nil : suffixes
        }

        private mutating func parseFixedArrayDimensions() -> [UInt64]? {
            guard peek() == .punct("[") else { return nil }
            var dimensions: [UInt64] = []
            while peek() == .punct("[") {
                advance()
                guard case let .number(text)? = peek() else { return nil }
                advance()
                guard peek() == .punct("]") else { return nil }
                advance()
                guard let count = parseIntegerLiteral(text), count >= 0 else { return nil }
                dimensions.append(UInt64(count))
            }
            return dimensions
        }

        private func renderArraySuffixes(_ dimensions: [UInt64]) -> String {
            dimensions.map { "[\($0)]" }.joined()
        }

        private mutating func consumeBalancedParentheses() -> Bool {
            guard peek() == .punct("(") else { return false }
            var depth = 0
            var guardCounter = 0
            while let t = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if t == .punct("(") {
                    depth += 1
                    guard depth <= maxBraceDepth else { return false }
                    advance()
                    continue
                }
                if t == .punct(")") {
                    advance()
                    depth -= 1
                    if depth == 0 { return true }
                    continue
                }
                advance()
            }
            return false
        }

        private func pointerSizedType(from baseType: String) -> String {
            let trimmed = baseType.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix("*") ? trimmed : trimmed + " *"
        }

        private func isMemberAlignmentSpecifierStart(_ token: Token?) -> Bool {
            token == .identifier("__attribute__") || token == .identifier("_Alignas") || token == .identifier("alignas")
        }

        /// An optional `struct Tag` / `enum Tag` tag identifier (the keyword was
        /// already consumed; the tag, if present, is the identifier before `{`).
        private mutating func consumeOptionalTag() -> String? {
            if case let .identifier(tag)? = peek() {
                advance()
                return tag
            }
            return nil
        }

        /// After a record/enum body in a typedef, the trailing `Alias` (possibly
        /// with pointer stars, which we ignore for the catalog name) before ';'.
        private mutating func consumeTypedefAlias() -> String? {
            while peek() == .punct("*") { advance() }
            var alias: String? = nil
            if case let .identifier(name)? = peek() { alias = name; advance() }
            consumeTrailingSemicolon()
            return alias
        }

        private mutating func consumeTrailingSemicolon() {
            // Tolerate trailing declarator junk up to the ';'.
            var guardCounter = 0
            while let t = peek(), t != .punct(";"), guardCounter < 256 {
                advance(); guardCounter += 1
            }
            if peek() == .punct(";") { advance() }
        }

        /// Skips the rest of a field declaration up to and including its
        /// terminating ';'. Brace-aware: a nested `{ … }` (e.g. an anonymous inner
        /// record) is consumed whole, so the inner `;`s don't end the skip early
        /// and the enclosing record's close brace is preserved.
        private mutating func skipFieldToSemicolon() {
            var depth = 0
            var guardCounter = 0
            while let t = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if t == .punct("{") { depth = min(maxBraceDepth, depth + 1); advance(); continue }
                if t == .punct("}") {
                    if depth == 0 { return } // don't eat the record close
                    depth -= 1; advance(); continue
                }
                if t == .punct(";") {
                    advance()
                    if depth == 0 { return }
                    continue
                }
                advance()
            }
        }

        private mutating func skipEnumValue() {
            var guardCounter = 0
            while let t = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                if t == .punct(",") { advance(); return }
                if t == .punct("}") { return }
                advance()
            }
        }

        /// Skips to the end of the current top-level statement: the next ';' at
        /// brace-depth 0, or the matching '}' of a body. Depth-counted, capped.
        private mutating func skipToStatementEnd() {
            var depth = 0
            var guardCounter = 0
            while let t = peek(), guardCounter < maxTokenCount {
                guardCounter += 1
                switch t {
                case .punct("{"):
                    depth = min(maxBraceDepth, depth + 1); advance()
                case .punct("}"):
                    advance()
                    if depth == 0 {
                        if peek() == .punct(";") { advance() }
                        return
                    }
                    depth -= 1
                case .punct(";"):
                    advance()
                    if depth == 0 { return }
                default:
                    advance()
                }
            }
        }

        private func describeCurrentLine() -> String {
            var parts: [String] = []
            var p = pos
            while p < tokens.count, parts.count < 4 {
                switch tokens[p] {
                case let .identifier(s): parts.append(s)
                case let .number(s): parts.append(s)
                case let .pragmaPack(payload): parts.append("#pragma pack\(payload)")
                case let .punct(c):
                    if c == ";" || c == "{" { return parts.joined(separator: " ") }
                    parts.append(String(c))
                }
                p += 1
            }
            return parts.joined(separator: " ")
        }

        private mutating func emit(
            kind: TypeKind,
            name: String,
            fields: [FieldDef],
            attributes: ParsedAttributes = ParsedAttributes(),
            enumValuesIncomplete: Bool? = nil
        ) {
            guard !seenNames.contains(name) else {
                diagnostics.append("Skipped duplicate type “\(name)” (already defined earlier in this header).")
                return
            }
            seenNames.insert(name)
            let rules: AggregateLayoutRules = (kind == .struct || kind == .union) ? layoutRules(from: attributes) : .default
            let unsupportedAliasAttributes = kind == .typedef && (attributes.isPacked || attributes.minimumAlignment != nil || attributes.layoutIsUnknown)
            var storedFields = fields
            if unsupportedAliasAttributes, !storedFields.isEmpty { storedFields[0].layoutIsUnknown = true }
            let incompleteEnum = enumValuesIncomplete == true || (kind == .enum && (attributes.isPacked || attributes.minimumAlignment != nil))
            types.append(TypeDefinition(id: idProvider(), kind: kind, name: name, fields: storedFields, layoutRules: rules,
                                        vectorByteSize: attributes.vectorByteSize, enumValuesIncomplete: incompleteEnum ? true : nil))
        }

        // cursor primitives
        private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }
        private mutating func advance() { if pos < tokens.count { pos += 1 } }
    }

    // MARK: - Type normalization

    /// Maps a multi-word C base type to the catalog's canonical primitive
    /// spelling (matching `TypeDefinition.size(ofType:)`). Returns nil for a type
    /// we cannot size/name with confidence. Such a member remains an opaque
    /// poison point rather than disappearing and shifting later members.
    ///
    /// User-defined struct/enum/typedef names (single unknown identifiers) are
    /// passed through verbatim so a field can reference another catalog type.
    static func normalizePrimitive(words rawWords: [String]) -> String? {
        // Drop qualifiers that don't change the size/identity.
        let dropped: Set<String> = ["const", "volatile", "register", "static", "struct", "union", "enum", "_Atomic", "restrict"]
        let words = rawWords.filter { !dropped.contains($0) }
        guard !words.isEmpty else { return nil }

        // C integer specifiers are order-independent. Reorder only this closed
        // vocabulary, retaining duplicates so the existing spelling table still
        // rejects conflicting signs, repeated int/short, or more than two longs.
        // Other accepted types keep their existing identity and Darwin layout.
        let integerOrder = ["signed": 0, "unsigned": 0, "char": 1, "short": 2, "long": 3, "int": 4]
        let orderedWords = words.allSatisfy { integerOrder[$0] != nil }
            ? words.sorted { integerOrder[$0]! < integerOrder[$1]! } : words
        let joined = orderedWords.joined(separator: " ")
        // Exact canonical/aliased spellings first.
        switch joined {
        case "void": return "void"
        case "bool", "_Bool": return "_Bool"
        case "char": return "char"
        case "signed char": return "int8_t"
        case "unsigned char": return "uint8_t"
        case "short", "short int", "signed short", "signed short int": return "int16_t"
        case "unsigned short", "unsigned short int": return "uint16_t"
        case "int", "signed", "signed int": return "int32_t"
        case "unsigned", "unsigned int": return "uint32_t"
        case "long", "long int", "signed long", "signed long int": return "int64_t"
        case "unsigned long", "unsigned long int": return "uint64_t"
        case "long long", "long long int", "signed long long", "signed long long int": return "int64_t"
        case "unsigned long long", "unsigned long long int": return "uint64_t"
        case "__int128", "signed __int128": return "__int128"
        case "unsigned __int128": return "unsigned __int128"
        case "float": return "float"
        case "double", "long double": return "double"
        // Fixed-width <stdint.h> spellings pass through canonically.
        case "int8_t", "uint8_t", "int16_t", "uint16_t",
             "int32_t", "uint32_t", "int64_t", "uint64_t",
             "size_t", "ssize_t", "intptr_t", "uintptr_t",
             "ptrdiff_t", "wchar_t":
            return joined
        default:
            break
        }
        // A single unknown identifier is treated as a user-defined type reference
        // (struct/typedef/enum name) and passed through. Multi-word unknowns are
        // ambiguous — reject them.
        if words.count == 1, isValidIdentifier(words[0]) {
            return words[0]
        }
        return nil
    }

    static func bitFieldValueCapacityBits(for type: String) -> Int? {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "_Bool": return 1
        case "__int128", "unsigned __int128": return 128
        case "char", "int8_t", "uint8_t": return 8
        case "int16_t", "uint16_t": return 16
        case "int32_t", "uint32_t", "int": return 32
        case "int64_t", "uint64_t", "long", "size_t", "ssize_t", "intptr_t", "uintptr_t": return 64
        default: return nil
        }
    }

    // MARK: - Lexical helpers

    /// Parses a C integer literal (decimal, octal, hexadecimal or binary) with optional u/l
    /// suffixes into its magnitude. Returns nil on overflow or malformed text.
    static func parseIntegerLiteral(_ raw: String) -> Int64? {
        guard let value = parseUnsignedIntegerLiteral(raw), value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }

    /// C literal bases and a bounded set of valid integer suffixes. Invalid digits
    /// or overflow stay unknown, rather than being silently interpreted as decimal.
    private static func parseUnsignedIntegerLiteral(_ raw: String) -> UInt64? {
        var text = raw
        var suffix = ""
        while let last = text.last, "uUlL".contains(last) {
            suffix = String(last) + suffix
            text.removeLast()
        }
        guard ["", "u", "l", "ul", "lu", "ll", "ull", "llu"].contains(suffix.lowercased()), !text.isEmpty else { return nil }
        let radix: Int
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            radix = 16; text = String(text.dropFirst(2))
        } else if text.hasPrefix("0b") || text.hasPrefix("0B") {
            radix = 2; text = String(text.dropFirst(2))
        } else if text.count > 1 && text.hasPrefix("0") {
            radix = 8
        } else {
            radix = 10
        }
        guard !text.isEmpty else { return nil }
        return UInt64(text, radix: radix)
    }

    static func isValidIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        let isStart = (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") || first == "_"
        guard isStart else { return false }
        return s.unicodeScalars.dropFirst().allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_"
        }
    }
}

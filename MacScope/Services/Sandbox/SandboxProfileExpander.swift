import Foundation

/// Expands caller-supplied SBPL text. This is a declaration browser, not a sandbox
/// policy evaluator: filter predicates, rule precedence, and the running OS policy
/// are not evaluated. Never use this report to authorize an operation.
enum SandboxProfileExpander {
    struct Location: Equatable, Sendable {
        let line: Int
        let column: Int
    }

    indirect enum Expression: Equatable, Sendable {
        case symbol(String, Location)
        case string(String, Location)
        case regexString(String, Location)
        case list([Expression], Location)

        var location: Location {
            switch self {
            case .symbol(_, let at), .string(_, let at), .regexString(_, let at), .list(_, let at): at
            }
        }

        var symbol: String? {
            if case .symbol(let value, _) = self { return value }
            return nil
        }

        var string: String? {
            if case .string(let value, _) = self { return value }
            return nil
        }

        var elements: [Expression]? {
            if case .list(let value, _) = self { return value }
            return nil
        }

        var rendered: String {
            switch self {
            case .symbol(let value, _): return value
            case .string(let value, _):
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\t", with: "\\t")
                return "\"\(escaped)\""
            case .regexString(let value, _):
                return "#\"\(value)\""
            case .list(let values, _):
                return "(" + values.map(\.rendered).joined(separator: " ") + ")"
            }
        }
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unexpectedCharacter(Int, Int)
        case unterminatedString(Int, Int)
        case unexpectedClose(Int, Int)
        case unclosedList(Int, Int)
        case limitExceeded

        var description: String {
            switch self {
            case .unexpectedCharacter(let line, let column): "Unexpected character at \(line):\(column)"
            case .unterminatedString(let line, let column): "Unterminated string at \(line):\(column)"
            case .unexpectedClose(let line, let column): "Unexpected ')' at \(line):\(column)"
            case .unclosedList(let line, let column): "Unclosed list at \(line):\(column)"
            case .limitExceeded: "SBPL input exceeds parser limits"
            }
        }
    }

    private enum TokenKind: Equatable {
        case open, close, symbol(String), string(String), regexString(String)
    }

    private struct Token {
        let kind: TokenKind
        let at: Location
    }

    static func parse(_ source: String) throws -> [Expression] {
        let tokens = try tokenize(source)
        var index = 0
        func read(_ depth: Int) throws -> Expression {
            guard depth <= 128 else { throw ParseError.limitExceeded }
            let token = tokens[index]
            index += 1
            switch token.kind {
            case .symbol(let value): return .symbol(value, token.at)
            case .string(let value): return .string(value, token.at)
            case .regexString(let value): return .regexString(value, token.at)
            case .close: throw ParseError.unexpectedClose(token.at.line, token.at.column)
            case .open:
                var children: [Expression] = []
                while index < tokens.count {
                    if tokens[index].kind == .close {
                        index += 1
                        return .list(children, token.at)
                    }
                    children.append(try read(depth + 1))
                }
                throw ParseError.unclosedList(token.at.line, token.at.column)
            }
        }
        var result: [Expression] = []
        while index < tokens.count { result.append(try read(0)) }
        return result
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        let scalars = Array(source.unicodeScalars)
        guard scalars.count <= 2_000_000 else { throw ParseError.limitExceeded }
        var tokens: [Token] = []
        var index = 0
        var line = 1
        var column = 1
        func advance() {
            if scalars[index] == "\n" { line += 1; column = 1 } else { column += 1 }
            index += 1
        }
        while index < scalars.count {
            let value = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(value) { advance(); continue }
            if value == ";" {
                while index < scalars.count && scalars[index] != "\n" { advance() }
                continue
            }
            let at = Location(line: line, column: column)
            if value == "(" || value == ")" {
                tokens.append(Token(kind: value == "(" ? .open : .close, at: at))
                advance()
            } else if value == "#", index + 1 < scalars.count, scalars[index + 1] == "\"" {
                advance() // #
                advance() // opening quote
                var content = ""
                var closed = false
                while index < scalars.count {
                    let next = scalars[index]
                    if next == "\"" { advance(); closed = true; break }
                    if next == "\\" {
                        content.unicodeScalars.append(next)
                        advance()
                        guard index < scalars.count else { break }
                    }
                    content.unicodeScalars.append(scalars[index])
                    advance()
                }
                guard closed else { throw ParseError.unterminatedString(at.line, at.column) }
                tokens.append(Token(kind: .regexString(content), at: at))
            } else if value == "\"" {
                advance()
                var content = ""
                var closed = false
                while index < scalars.count {
                    let next = scalars[index]
                    if next == "\"" { advance(); closed = true; break }
                    if next == "\\" {
                        advance()
                        guard index < scalars.count else { break }
                        switch scalars[index] {
                        case "n": content.append("\n")
                        case "t": content.append("\t")
                        case "r": content.append("\r")
                        case "\"": content.append("\"")
                        case "\\": content.append("\\")
                        default: content.append("\\"); content.unicodeScalars.append(scalars[index])
                        }
                    } else { content.unicodeScalars.append(next) }
                    advance()
                }
                guard closed else { throw ParseError.unterminatedString(at.line, at.column) }
                tokens.append(Token(kind: .string(content), at: at))
            } else {
                var content = ""
                while index < scalars.count {
                    let next = scalars[index]
                    if CharacterSet.whitespacesAndNewlines.contains(next) || next == "(" || next == ")" || next == ";" { break }
                    if next == "\"" { throw ParseError.unexpectedCharacter(line, column) }
                    content.unicodeScalars.append(next)
                    advance()
                }
                guard !content.isEmpty else { throw ParseError.unexpectedCharacter(at.line, at.column) }
                tokens.append(Token(kind: .symbol(content), at: at))
            }
            guard tokens.count <= 250_000 else { throw ParseError.limitExceeded }
        }
        return tokens
    }

    struct Rule: Codable, Equatable, Hashable {
        let decision: String
        let operation: String
        /// Raw SBPL filter/argument forms; no regex, subpath, require-any,
        /// require-all, or metafilter semantics are interpreted here.
        let arguments: [String]
        let unlockedBy: [String]
    }

    struct Report: Codable, Equatable {
        let effectiveRules: [Rule]
        let grantedNamedMachServices: [String]
        let entitlementRules: [String: [Rule]]
        let unresolvedImports: [String]
        let unresolvedMacros: [String]
        let unresolvedConditions: [String]
        let expansionCycles: [String]
    }

    private struct Macro {
        let parameters: [String]
        let body: [Expression]
    }

    private struct RuleIdentity: Hashable {
        let decision: String
        let operation: String
        let arguments: [String]
    }

    /// `imports` is a complete, caller-owned map keyed by the literal import
    /// operand. No filesystem lookup or implicit system-profile access occurs.
    static func expand(profile: String, imports: [String: String] = [:], entitlements: Set<String>) throws -> Report {
        let root = try parse(profile)
        var sources: [String: [Expression]] = [:]
        for (name, text) in imports { sources[name] = try parse(text) }
        var macros: [String: Macro] = [:]
        var values: [String: Expression] = [:]
        var unresolvedImports = Set<String>()
        var unresolvedMacros = Set<String>()
        var unresolvedConditions = Set<String>()
        var cycles = Set<String>()
        var remainingSteps = 1_000_000
        var expansionLimitReached = false

        func takeStep() -> Bool {
            guard !expansionLimitReached else { return false }
            guard remainingSteps > 0 else {
                expansionLimitReached = true
                cycles.insert("expansion limit")
                return false
            }
            remainingSteps -= 1
            return true
        }

        func importName(_ form: Expression) -> String? {
            guard let parts = form.elements, parts.first?.symbol == "import", parts.count == 2 else { return nil }
            return parts[1].string
        }
        func collect(_ forms: [Expression], stack: [String]) {
            for form in forms {
                guard takeStep() else { return }
                if let name = importName(form) {
                    guard let imported = sources[name] else { unresolvedImports.insert(name); continue }
                    if stack.contains(name) { cycles.insert("import: " + (stack + [name]).joined(separator: " -> ")); continue }
                    collect(imported, stack: stack + [name])
                    continue
                }
                guard let parts = form.elements, parts.first?.symbol == "define", parts.count >= 3 else { continue }
                if let signature = parts[1].elements, let name = signature.first?.symbol,
                   signature.dropFirst().allSatisfy({ $0.symbol != nil }) {
                    macros[name] = Macro(parameters: signature.dropFirst().compactMap(\.symbol), body: Array(parts.dropFirst(2)))
                } else if let name = parts[1].symbol, parts.count == 3 {
                    values[name] = parts[2]
                }
            }
        }
        collect(root, stack: [])

        func substitute(_ expression: Expression, bindings: [String: Expression], seen: Set<String> = []) -> Expression? {
            guard takeStep() else { return nil }
            switch expression {
            case .symbol(let name, let at):
                guard !seen.contains(name) else { cycles.insert("value: " + name); return .symbol(name, at) }
                if let replacement = bindings[name] ?? values[name] {
                    return substitute(replacement, bindings: [:], seen: seen.union([name]))
                }
                return .symbol(name, at)
            case .string, .regexString: return expression
            case .list(let parts, let at):
                var substituted: [Expression] = []
                for part in parts {
                    guard let next = substitute(part, bindings: bindings, seen: seen) else { return nil }
                    substituted.append(next)
                }
                return .list(substituted, at)
            }
        }
        func truth(_ condition: Expression) -> Bool? {
            if condition.symbol == "#t" { return true }
            if condition.symbol == "#f" { return false }
            guard let parts = condition.elements, let head = parts.first?.symbol else { return nil }
            switch head {
            case "entitlement" where parts.count == 2:
                guard let name = parts[1].string else { return nil }
                return entitlements.contains(name)
            case "not" where parts.count == 2:
                return truth(parts[1]).map(!)
            case "and":
                let results = parts.dropFirst().map(truth)
                if results.contains(false) { return false }
                return results.allSatisfy { $0 == true } ? true : nil
            case "or":
                let results = parts.dropFirst().map(truth)
                if results.contains(true) { return true }
                return results.allSatisfy { $0 == false } ? false : nil
            default: return nil
            }
        }
        func positiveEntitlements(_ condition: Expression) -> Set<String> {
            guard let parts = condition.elements, let head = parts.first?.symbol else { return [] }
            if head == "entitlement", parts.count == 2, let name = parts[1].string, entitlements.contains(name) { return [name] }
            if head == "and" || head == "or" { return parts.dropFirst().reduce(into: Set<String>()) { $0.formUnion(positiveEntitlements($1)) } }
            return []
        }
        var rules: [Rule] = []
        func visit(_ form: Expression, importsStack: [String], macrosStack: [String], gates: Set<String>, depth: Int) {
            guard takeStep() else { return }
            guard depth <= 128, rules.count < 100_000 else {
                expansionLimitReached = true
                cycles.insert("expansion limit")
                return
            }
            if let name = importName(form) {
                guard let imported = sources[name] else { unresolvedImports.insert(name); return }
                if importsStack.contains(name) { cycles.insert("import: " + (importsStack + [name]).joined(separator: " -> ")); return }
                imported.forEach { visit($0, importsStack: importsStack + [name], macrosStack: macrosStack, gates: gates, depth: depth + 1) }
                return
            }
            guard let parts = form.elements, let head = parts.first?.symbol else { return }
            switch head {
            case "define", "version", "debug", "trace": return
            case "begin":
                parts.dropFirst().forEach { visit($0, importsStack: importsStack, macrosStack: macrosStack, gates: gates, depth: depth + 1) }
            case "when" where parts.count >= 2:
                guard let isTrue = truth(parts[1]) else { unresolvedConditions.insert(parts[1].rendered); return }
                if isTrue {
                    let next = gates.union(positiveEntitlements(parts[1]))
                    parts.dropFirst(2).forEach { visit($0, importsStack: importsStack, macrosStack: macrosStack, gates: next, depth: depth + 1) }
                }
            case "if" where parts.count == 3 || parts.count == 4:
                guard let isTrue = truth(parts[1]) else { unresolvedConditions.insert(parts[1].rendered); return }
                let branch = isTrue ? parts[2] : (parts.count == 4 ? parts[3] : nil)
                if let branch {
                    let next = isTrue ? gates.union(positiveEntitlements(parts[1])) : gates
                    visit(branch, importsStack: importsStack, macrosStack: macrosStack, gates: next, depth: depth + 1)
                }
            case "allow", "deny":
                for item in parts.dropFirst() {
                    guard let operation = item.symbol else { continue }
                    let arguments = parts.dropFirst().filter { $0.symbol == nil }.map(\.rendered)
                    rules.append(Rule(decision: head, operation: operation, arguments: arguments, unlockedBy: gates.sorted()))
                }
            default:
                if parts.count == 1, let value = values[head] {
                    if macrosStack.contains(head) { cycles.insert("value: " + (macrosStack + [head]).joined(separator: " -> ")); return }
                    guard let substituted = substitute(value, bindings: [:]) else { return }
                    visit(substituted, importsStack: importsStack,
                          macrosStack: macrosStack + [head], gates: gates, depth: depth + 1)
                    return
                }
                guard let macro = macros[head], macro.parameters.count == parts.count - 1 else {
                    unresolvedMacros.insert(head); return
                }
                if macrosStack.contains(head) { cycles.insert("macro: " + (macrosStack + [head]).joined(separator: " -> ")); return }
                let bindings = Dictionary(uniqueKeysWithValues: zip(macro.parameters, parts.dropFirst()))
                macro.body.compactMap { substitute($0, bindings: bindings) }.forEach {
                    visit($0, importsStack: importsStack, macrosStack: macrosStack + [head], gates: gates, depth: depth + 1)
                }
            }
        }
        root.forEach { visit($0, importsStack: [], macrosStack: [], gates: [], depth: 0) }
        var uniqueRules: [Rule] = []
        var indices: [RuleIdentity: Int] = [:]
        for rule in rules {
            let identity = RuleIdentity(decision: rule.decision, operation: rule.operation, arguments: rule.arguments)
            if let index = indices[identity] {
                let existing = uniqueRules[index]
                uniqueRules[index] = Rule(decision: existing.decision, operation: existing.operation,
                                          arguments: existing.arguments,
                                          unlockedBy: Array(Set(existing.unlockedBy).union(rule.unlockedBy)).sorted())
            } else {
                indices[identity] = uniqueRules.count
                uniqueRules.append(rule)
            }
        }
        let serviceNames = Set(uniqueRules.filter { $0.decision == "allow" && $0.operation == "mach-lookup" }
            .flatMap { rule in rule.arguments.compactMap { argument -> String? in
                guard let expression = try? parse(argument).first, let parts = expression.elements,
                      parts.count == 2, parts[0].symbol == "global-name" else { return nil }
                return parts[1].string
            } })
        var entitlementRules: [String: [Rule]] = [:]
        for entitlement in entitlements { entitlementRules[entitlement] = uniqueRules.filter { $0.unlockedBy.contains(entitlement) } }
        return Report(effectiveRules: uniqueRules, grantedNamedMachServices: serviceNames.sorted(),
                      entitlementRules: entitlementRules, unresolvedImports: unresolvedImports.sorted(),
                      unresolvedMacros: unresolvedMacros.sorted(), unresolvedConditions: unresolvedConditions.sorted(),
                      expansionCycles: cycles.sorted())
    }
}

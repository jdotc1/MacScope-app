import Foundation

/// Test-only ordinary-control parser. It has no IR, register-bank, source-machine,
/// certificate, or RegionTree input. Source tags identify observations, not values.
/// SOURCE_ONLY / NOT_RUN: these new checks are not an acceptance receipt.
enum OrdinaryC {
    enum Failure: Error, CustomStringConvertible {
        case unsupportedSyntax(String), invalidContract(String), uninitializedRead(String)
        case undefinedC(String), callAuthorityViolation(String), scriptMismatch(String)
        case fuelExhausted, semanticMismatch(String)
        var description: String {
            switch self {
            case let .unsupportedSyntax(s): return "unsupportedSyntax: \(s)"
            case let .invalidContract(s): return "invalidContract: \(s)"
            case let .uninitializedRead(s): return "uninitializedRead: \(s)"
            case let .undefinedC(s): return "undefinedC: \(s)"
            case let .callAuthorityViolation(s): return "callAuthorityViolation: \(s)"
            case let .scriptMismatch(s): return "scriptMismatch: \(s)"
            case .fuelExhausted: return "fuelExhausted"
            case let .semanticMismatch(s): return "semanticMismatch: \(s)"
            }
        }
    }
    struct CType: Hashable {
        let width: Int
        let unsigned: Bool
        let pointee: String?
        let constQualified: Bool
        init(_ width: Int, _ unsigned: Bool, pointee: String? = nil, constQualified: Bool = false) {
            self.width = width; self.unsigned = unsigned; self.pointee = pointee
            self.constQualified = constQualified
        }
        static let i32 = CType(32, false), i64 = CType(64, false)
        static let u32 = CType(32, true), u64 = CType(64, true)
        static let jpegPointer = CType(64, true, pointee: "jpeg_decompress_struct")
        var pointer: Bool { pointee != nil }
        var bytePointer: Bool { pointee == "uint8_t" }
        var objectPointer: Bool { pointer && pointee.flatMap(Self.named) == nil }
        var unqualified: CType { .init(width, unsigned, pointee: pointee) }
        var mask: UInt64 { width == 64 ? .max : (UInt64(1) << width) - 1 }
        var sign: UInt64 { UInt64(1) << (width - 1) }
        var maximumSigned: UInt64 { sign - 1 }
        var promoted: CType { !pointer && width < 32 ? .i32 : self }
        static func named(_ name: String) -> CType? {
            for width in [8, 16, 32, 64] {
                if name == "int\(width)_t" { return .init(width, false) }
                if name == "uint\(width)_t" { return .init(width, true) }
            }
            return nil
        }
        static func common(_ a: CType, _ b: CType) throws -> CType {
            if a.pointer || b.pointer {
                guard a == b else { throw Failure.unsupportedSyntax("incompatible pointer operands") }
                return a
            }
            let a = a.promoted, b = b.promoted
            if a.width == b.width { return .init(a.width, a.unsigned || b.unsigned) }
            let wide = a.width > b.width ? a : b, narrow = a.width > b.width ? b : a
            if wide.unsigned || !narrow.unsigned || wide.width > narrow.width { return wide }
            return .init(wide.width, true)
        }
    }
    struct Origin: Hashable { let row: Int; let occurrence: Int }
    struct ObjectAddress: Equatable {
        let base: UInt64
        let owner: String
        let offset: Int64
    }
    struct Value: Equatable {
        let bits: UInt64
        let type: CType
        var origins: Set<Origin>
        let objectAddress: ObjectAddress?
        init(_ bits: UInt64, _ type: CType, origins: Set<Origin> = [], objectAddress: ObjectAddress? = nil) {
            self.bits = bits & type.mask; self.type = type; self.origins = origins
            self.objectAddress = objectAddress ?? (type.objectPointer ? type.pointee.map { .init(base: bits, owner: $0, offset: 0) } : nil)
        }
        var negative: Bool { !type.unsigned && !type.pointer && bits & type.sign != 0 }
        var signed: Int64 {
            if type.width == 64 { return Int64(bitPattern: bits) }
            return negative ? Int64(bitPattern: bits | ~type.mask) : Int64(bits)
        }
        var extended: UInt64 { negative ? bits | ~type.mask : bits }
    }
    struct SourceSite: Hashable { let row: Int; let effectOrdinal: Int }
    struct SourceEdge: Hashable { let fromBlock: Int; let toBlock: Int; let successorOrdinal: Int }
    struct Span: Hashable { let first: Int; let last: Int }
    struct Token: Equatable {
        let text: String
        let line: Int
        let byteOffset: Int
        let source: UInt64?
    }
    struct PhiEdgeSource: Equatable {
        let blockAddress: UInt64
        // A virtual entry edge has no original machine predecessor. Keep the
        // edge metadata, but let original-row ownership validation refuse it.
        let predecessorAddress: UInt64?
    }
    struct TextLine {
        let text: String
        let source: UInt64?
        let envelope: EnvelopeKind
        var phiEdge: PhiEdgeSource? = nil
    }
    enum EnvelopeKind: Equatable { case signature, metadata, closingBrace, body }
    struct Expression {
        let span: Span
        let node: Node
        indirect enum Node {
            case literal(Value), name(String), cast(CType, Expression)
            case unary(String, Expression), binary(String, Expression, Expression)
            case select(Expression, Expression, Expression)
            case load(CType, Expression), field(Expression, String)
            case helper(String, [Expression]), update(String, Int, Bool)
        }
    }
    struct Statement {
        let span: Span
        let scopes: [Int]
        let node: Node
        indirect enum Node {
            case compound(Int, [Statement]), empty
            case declaration(CType, String, Expression?)
            case declarations(CType, [String])
            case assign([Expression], [Expression])
            case update(Expression)
            case conditional(Expression, Statement, Statement?)
            case whileLoop(Expression, Statement), doLoop(Statement, Expression)
            case forLoop(Statement?, Expression?, Statement?, Statement)
            case breakLoop, continueLoop, jump(String), label(String, Statement)
            case call(Int, String?, Expression?, [Expression])
            case returned(Expression?), unavailableReturn
        }
    }
    struct Symbol { let type: CType; let scope: Int; let external: Bool; let declared: Bool }
    struct Instruction {
        let span: Span
        let scopes: [Int]
        var node: Node
        enum Node {
            case nop, declaration(String, Expression?), assign([Expression], [Expression]), update(Expression)
            case branch(Expression, Int, Int), jump(Int), unresolved(String)
            case call(Int, String?, Expression?, [Expression]), returned(Expression?), unavailableReturn
        }
    }
    struct Program {
        let contract: Contract
        let lines: [TextLine]
        let tokens: [Token]
        let root: Statement
        let symbols: [String: Symbol]
        let expressionTypes: [Span: CType]
        let representationCasts: Set<Span>
        let code: [Instruction]
        let memorySites: [Span: SourceSite]
        let protectedNames: Set<String>
        init(lines: [TextLine], contract: Contract) throws {
            self.contract = contract; self.lines = lines
            let text = lines.map(\.text).joined(separator: "\n")
            let sources = Dictionary(uniqueKeysWithValues: lines.enumerated().compactMap { index, line in
                line.source.map { (index + 1, $0) }
            })
            let tokens = try OrdinaryC.lex(text, sources: sources)
            self.tokens = tokens
            try contract.validateEnvelope(lines: lines, tokens: tokens)
            var parser = Parser(tokens: tokens, lines: lines, contract: contract)
            let root = try parser.parse()
            self.root = root
            var resolver = Resolver(contract: contract, tokens: tokens)
            try resolver.resolve(root)
            symbols = resolver.symbols; expressionTypes = resolver.types
            representationCasts = resolver.representationCasts
            memorySites = try resolver.assignMemorySites(root)
            protectedNames = try contract.protectedIdentifiers()
            var compiler = Compiler()
            try compiler.emit(root)
            code = try compiler.finish()
        }
        func row(at span: Span) throws -> Int {
            guard tokens.indices.contains(span.first) else {
                throw Failure.invalidContract("missing original source identity at token \(span.first)")
            }
            let token = tokens[span.first]
            // Edge copies retain an independent provenance channel. Resolving
            // their predecessor for ownership does not turn them into an
            // architectural source statement or a source-machine definition.
            let edge = lines.indices.contains(token.line - 1) ? lines[token.line - 1].phiEdge : nil
            guard edge == nil || edge?.predecessorAddress != nil,
                  let address = token.source ?? edge?.predecessorAddress,
                  let row = contract.rowsByAddress[address] else {
                throw Failure.invalidContract("missing original source identity at token \(span.first)")
            }
            return row
        }
        func phiEdge(at span: Span) -> PhiEdgeSource? {
            guard tokens.indices.contains(span.first) else { return nil }
            let line = tokens[span.first].line - 1
            return lines.indices.contains(line) ? lines[line].phiEdge : nil
        }
    }
    static func identifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func letter(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 }
        guard let first = bytes.first, letter(first) else { return false }
        return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
    }
    static func literal(_ text: String) throws -> Value {
        let hexadecimal = text.hasPrefix("0x") || text.hasPrefix("0X")
        let digits = hexadecimal ? String(text.dropFirst(2)) : text
        guard !digits.isEmpty, hexadecimal || digits == "0" || !digits.hasPrefix("0"),
              let bits = UInt64(digits, radix: hexadecimal ? 16 : 10) else {
            throw Failure.unsupportedSyntax("noncanonical integer literal \(text)")
        }
        let type: CType
        if bits <= UInt64(Int32.max) { type = .i32 }
        else if hexadecimal && bits <= UInt64(UInt32.max) { type = .u32 }
        else if bits <= UInt64(Int64.max) { type = .i64 }
        else if hexadecimal { type = .u64 }
        else { throw Failure.unsupportedSyntax("decimal literal exceeds signed64") }
        return .init(bits, type)
    }
    static func lex(_ text: String, sources: [Int: UInt64] = [:]) throws -> [Token] {
        let bytes = Array(text.utf8)
        var i = 0, line = 1, result: [Token] = []
        func peek(_ delta: Int = 0) -> UInt8? { i + delta < bytes.count ? bytes[i + delta] : nil }
        func letter(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 }
        while i < bytes.count {
            let c = bytes[i]
            if [9, 10, 13, 32].contains(c) { if c == 10 { line += 1 }; i += 1; continue }
            if c == 47 && peek(1) == 47 {
                while i < bytes.count && bytes[i] != 10 { i += 1 }; continue
            }
            if c == 47 && peek(1) == 42 {
                i += 2; var closed = false
                while i < bytes.count {
                    if bytes[i] == 42 && peek(1) == 47 { i += 2; closed = true; break }
                    if bytes[i] == 10 { line += 1 }; i += 1
                }
                guard closed else { throw Failure.unsupportedSyntax("unterminated block comment") }
                continue
            }
            guard c < 128, c != 34, c != 39 else {
                let lineStart = bytes[..<i].lastIndex(of: 10).map { $0 + 1 } ?? 0
                let lineEnd = bytes[i...].firstIndex(of: 10) ?? bytes.count
                throw Failure.unsupportedSyntax("non-ASCII token or unsupported executable literal at line \(line): \(String(decoding: bytes[lineStart..<lineEnd], as: UTF8.self))")
            }
            let start = i
            if letter(c) || (48...57).contains(c) {
                i += 1
                while i < bytes.count && (letter(bytes[i]) || (48...57).contains(bytes[i])) { i += 1 }
            } else {
                let pair = i + 1 < bytes.count ? String(decoding: bytes[i...i + 1], as: UTF8.self) : ""
                if ["==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "++", "--", "->"].contains(pair) { i += 2 }
                else {
                    guard "{}();,:?=+-*~!<>&^|".utf8.contains(c) else {
                        throw Failure.unsupportedSyntax("unsupported token at line \(line), byte \(i)")
                    }
                    i += 1
                }
            }
            result.append(.init(text: String(decoding: bytes[start..<i], as: UTF8.self), line: line,
                                byteOffset: start, source: sources[line]))
        }
        return result
    }

    struct Parser {
        let tokens: [Token]
        let lines: [TextLine]
        let contract: Contract
        var index = 0
        var scopes: [Int] = []
        var nextScope = 0
        var seenCalls: Set<Int> = []
        var seenExterior: Set<Int> = []
        var current: String { index < tokens.count ? tokens[index].text : "<end>" }
        func peek(_ offset: Int) -> String { index + offset < tokens.count ? tokens[index + offset].text : "<end>" }
        mutating func take(_ text: String) throws {
            guard current == text else { throw Failure.unsupportedSyntax("expected \(text), got \(current), token \(index)") }
            index += 1
        }
        mutating func name() throws -> String {
            guard OrdinaryC.identifier(current), !Self.reserved.contains(current) else {
                throw Failure.unsupportedSyntax("expected scalar identifier, got \(current)")
            }
            let value = current; index += 1; return value
        }
        static let reserved: Set<String> = ["if", "else", "while", "do", "for", "break", "continue", "goto", "return", "switch", "case", "default", "struct", "void", "double", "true", "false"]
        mutating func parse() throws -> Statement {
            let signatureTokens = try OrdinaryC.lex(contract.signature).map(\.text)
            guard !signatureTokens.isEmpty, Array(tokens.prefix(signatureTokens.count).map(\.text)) == signatureTokens,
                  signatureTokens.last == "{" else { throw Failure.invalidContract("changed function signature") }
            index = signatureTokens.count - 1
            let root = try statement()
            guard index == tokens.count else { throw Failure.unsupportedSyntax("trailing executable text") }
            guard seenCalls == Set(contract.calls.keys), seenExterior == Set(contract.exterior.keys) else {
                throw Failure.invalidContract("missing protected call or exterior statement")
            }
            return root
        }
        mutating func parenthesized() throws -> Expression {
            try take("("); let e = try expression(); try take(")"); return e
        }
        mutating func statement() throws -> Statement {
            let start = index, owner = scopes
            var statementScopes = owner
            guard index < tokens.count else { throw Failure.unsupportedSyntax("missing statement") }
            if current == "{" {
                index += 1; nextScope += 1; let scope = nextScope; scopes.append(scope)
                var statements: [Statement] = []
                while current != "}" { statements.append(try statement()) }
                try take("}"); scopes.removeLast()
                return .init(span: .init(first: start, last: index), scopes: owner + [scope], node: .compound(scope, statements))
            }
            let node: Statement.Node
            if current == ";" { index += 1; node = .empty }
            else if current == "if" {
                index += 1; let condition = try parenthesized(), yes = try statement()
                let no: Statement?
                if current == "else" { index += 1; no = try statement() } else { no = nil }
                node = .conditional(condition, yes, no)
            } else if current == "while" {
                index += 1; let e = try parenthesized(); node = .whileLoop(e, try statement())
            } else if current == "do" {
                index += 1; let body = try statement(); try take("while")
                let e = try parenthesized(); try take(";"); node = .doLoop(body, e)
            } else if current == "for" {
                nextScope += 1; scopes.append(nextScope); statementScopes = scopes
                index += 1; try take("(")
                let initial = current == ";" ? nil : try simple(terminator: ";")
                try take(";")
                let condition = current == ";" ? nil : try expression()
                try take(";")
                let step = current == ")" ? nil : try simple(terminator: ")")
                try take(")"); node = .forLoop(initial, condition, step, try statement())
                scopes.removeLast()
            } else if current == "break" || current == "continue" {
                let isBreak = current == "break"; index += 1; try take(";")
                node = isBreak ? .breakLoop : .continueLoop
            } else if current == "goto" {
                index += 1; let label = try nativeLabel(); try take(";"); node = .jump(label)
            } else if current == "return" {
                if contract.noCallUnavailableTerminal {
                    guard tokens[start].source.flatMap({ contract.rowsByAddress[$0] }) == contract.terminalRow,
                          peek(1) == "unresolved_return_contract", peek(2) == ";" else {
                        throw Failure.invalidContract("changed nonnumeric terminal/source identity")
                    }
                    index += 3; node = .unavailableReturn
                } else {
                    index += 1; let e = current == ";" ? nil : try expression(); try take(";")
                    node = .returned(e)
                }
            } else if OrdinaryC.identifier(current), peek(1) == ":" {
                let label = try nativeLabel(); try take(":")
                guard CType.named(current) == nil else { throw Failure.unsupportedSyntax("declaration-only label target requires null statement") }
                node = .label(label, try statement())
            } else {
                let statement = try simple(terminator: ";"); try take(";")
                return .init(span: .init(first: start, last: index), scopes: owner, node: statement.node)
            }
            return .init(span: .init(first: start, last: index), scopes: statementScopes, node: node)
        }
        mutating func nativeLabel() throws -> String {
            let text = current
            guard text.hasPrefix("L_"), !text.dropFirst(2).isEmpty,
                  UInt64(text.dropFirst(2), radix: 16) != nil,
                  contract.allowedLabels.contains(text) else {
                throw Failure.unsupportedSyntax("non-native or unowned label \(text)")
            }
            index += 1; return text
        }
        mutating func simple(terminator: String) throws -> Statement {
            let start = index
            let line = tokens[index].line
            let sourceRow = tokens[index].source.flatMap { contract.rowsByAddress[$0] }
            let payload = String(lines[line - 1].text.drop(while: { $0 == " " || $0 == "\t" }))
            var frozenTuple = false
            if let row = sourceRow, let frozen = contract.exterior[row] {
                guard payload == frozen, !seenExterior.contains(row) else { throw Failure.invalidContract("changed/duplicated exterior row \(row)") }
                seenExterior.insert(row); frozenTuple = true
            }
            let node: Statement.Node
            if let row = sourceRow, let call = contract.calls[row], payload == call.payload {
                guard !seenCalls.contains(row), terminator == ";" else { throw Failure.invalidContract("duplicated/nested protected call") }
                seenCalls.insert(row)
                let destination: String?
                if peek(1) == "=" { destination = try name(); try take("=") } else { destination = nil }
                guard destination == call.resultName else { throw Failure.invalidContract("changed call result role") }
                let control: Expression?
                if current == "(" {
                    try take("("); try take("*"); control = try expression(); try take(")")
                } else { try take(call.target); control = nil }
                try take("("); var args: [Expression] = []
                if current != ")" {
                    args.append(try expression())
                    while current == "," { index += 1; args.append(try expression()) }
                }
                try take(")")
                guard args.count == call.arguments.count, (control != nil) == (call.control != nil) else {
                    throw Failure.invalidContract("call carrier shape mismatch")
                }
                guard current == ";", index + 1 == tokens.count || tokens[index + 1].line != line else {
                    throw Failure.invalidContract("protected call is not a whole original statement")
                }
                node = .call(row, destination, control, args)
            } else if let type = CType.named(current) {
                index += 1; let name = try name()
                if current == "," {
                    var names = [name]
                    while current == "," { index += 1; names.append(try self.name()) }
                    guard names.count <= 6 else { throw Failure.unsupportedSyntax("declaration list exceeds reviewed native grouping") }
                    node = .declarations(type, names)
                } else {
                    var initializer: Expression?
                    if current == "=" { index += 1; initializer = try expression() }
                    node = .declaration(type, name, initializer)
                }
            } else {
                var left = [try expression()]
                while current == "," {
                    guard frozenTuple else { throw Failure.unsupportedSyntax("new tuple outside frozen exterior") }
                    index += 1; left.append(try expression())
                }
                if current == "=" {
                    index += 1; var right = [try expression()]
                    while current == "," {
                        guard frozenTuple else { throw Failure.unsupportedSyntax("comma expression/new tuple") }
                        index += 1; right.append(try expression())
                    }
                    guard left.count == right.count else { throw Failure.unsupportedSyntax("tuple arity mismatch") }
                    node = .assign(left, right)
                } else {
                    guard left.count == 1, case .update = left[0].node else {
                        throw Failure.unsupportedSyntax("unsupported expression statement")
                    }
                    node = .update(left[0])
                }
            }
            guard current == terminator else { throw Failure.unsupportedSyntax("unsupported statement token \(current)") }
            return .init(span: .init(first: start, last: index), scopes: scopes, node: node)
        }
        static let precedence: [String: Int] = ["||": 1, "&&": 2, "|": 3, "^": 4, "&": 5,
            "==": 6, "!=": 6, "<": 7, "<=": 7, ">": 7, ">=": 7, "<<": 8, ">>": 8, "+": 9, "-": 9, "*": 10]
        mutating func expression(_ minimum: Int = 0) throws -> Expression {
            let start = index; var lhs = try prefix()
            while let precedence = Self.precedence[current], precedence >= minimum {
                let op = current; index += 1; let rhs = try expression(precedence + 1)
                lhs = .init(span: .init(first: start, last: index), node: .binary(op, lhs, rhs))
            }
            if minimum == 0, current == "?" {
                index += 1; let yes = try expression(); try take(":"); let no = try expression()
                lhs = .init(span: .init(first: start, last: index), node: .select(lhs, yes, no))
            }
            return lhs
        }
        func pointerCast() -> (scalar: CType, pointer: CType, count: Int)? {
            guard current == "(" else { return nil }
            let qualified = peek(1) == "const", nameIndex = qualified ? 2 : 1
            guard let scalar = CType.named(peek(nameIndex)), peek(nameIndex + 1) == "*",
                  peek(nameIndex + 2) == ")" else { return nil }
            return (.init(scalar.width, scalar.unsigned, constQualified: qualified),
                    .init(64, true, pointee: peek(nameIndex), constQualified: qualified), nameIndex + 3)
        }
        mutating func prefix() throws -> Expression {
            let start = index
            let node: Expression.Node
            if ["+", "-", "~", "!"].contains(current) {
                let op = current; index += 1; node = .unary(op, try prefix())
            } else if current == "++" || current == "--" {
                let step = current == "++" ? 1 : -1; index += 1
                node = .update(try name(), step, true)
            } else if current == "*" {
                index += 1
                let type: CType
                if let parsed = pointerCast() {
                    index += parsed.count; type = parsed.scalar
                } else { type = .u64 }
                guard current == "(" else { throw Failure.unsupportedSyntax("memory address must be parenthesized") }
                node = .load(type, try parenthesized())
            } else if let parsed = pointerCast() {
                index += parsed.count; node = .cast(parsed.pointer, try prefix())
            } else if current == "(", let type = CType.named(peek(1)), peek(2) == ")" {
                index += 3; node = .cast(type, try prefix())
            } else if current == "(" {
                index += 1; let e = try expression(); try take(")"); node = e.node
            } else if current == "true" || current == "false" {
                node = .literal(.init(current == "true" ? 1 : 0, .i32)); index += 1
            } else if current.first?.isNumber == true {
                node = .literal(try OrdinaryC.literal(current)); index += 1
            } else if OrdinaryC.identifier(current) {
                let name = try name()
                if current == "(" {
                    guard ["__adrp", "__a64_sdiv32"].contains(name) else { throw Failure.unsupportedSyntax("unknown executable helper \(name)") }
                    index += 1; var args = [try expression()]
                    while current == "," { index += 1; args.append(try expression()) }
                    try take(")")
                    guard args.count == (name == "__adrp" ? 1 : 2) else { throw Failure.unsupportedSyntax("helper arity") }
                    if name == "__adrp", case .literal = args[0].node {} else if name == "__adrp" {
                        throw Failure.unsupportedSyntax("__adrp requires printed literal")
                    }
                    node = .helper(name, args)
                } else if current == "++" || current == "--" {
                    let step = current == "++" ? 1 : -1; index += 1; node = .update(name, step, false)
                } else { node = .name(name) }
            } else { throw Failure.unsupportedSyntax("unsupported expression \(current)") }
            var result = Expression(span: .init(first: start, last: index), node: node)
            if current == "->" {
                index += 1; let field = try name()
                result = .init(span: .init(first: start, last: index), node: .field(result, field))
            }
            return result
        }
    }
}

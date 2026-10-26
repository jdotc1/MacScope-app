import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Strict execution of the actual repaired switch document. The original capture
/// supplies only its function signature and exact opaque call statements; scalar
/// expression values and control flow come exclusively from the candidate text.
struct RegionalSwitchTextMachine {
    enum Failure: Error { case invalid(String), undefined(String) }
    struct CType: Equatable {
        let width: Int
        let unsigned: Bool
        let isPointer: Bool
        static let pointer = CType(width: 64, unsigned: true, isPointer: true)
        static let u32 = CType(width: 32, unsigned: true)
        static let u64 = CType(width: 64, unsigned: true)
        static let i32 = CType(width: 32, unsigned: false)
        static let i64 = CType(width: 64, unsigned: false)
        init(width: Int, unsigned: Bool, isPointer: Bool = false) {
            self.width = width; self.unsigned = unsigned; self.isPointer = isPointer
        }
        init?(_ text: String) {
            let unsigned = text.hasPrefix("uint")
            guard text.hasSuffix("_t"), text.hasPrefix("int") || unsigned else { return nil }
            let digits = text.dropFirst(unsigned ? 4 : 3).dropLast(2)
            guard let width = Int(digits), [8, 16, 32, 64].contains(width),
                  String(width) == String(digits) else { return nil }
            self.init(width: width, unsigned: unsigned)
        }
        var mask: UInt64 { width == 64 ? .max : (UInt64(1) << width) - 1 }
    }
    struct Value: Equatable {
        let bits: UInt64
        let type: CType
        init(bits: UInt64, type: CType) { self.bits = bits & type.mask; self.type = type }
        var signed: Int64 {
            if type.width == 64 { return Int64(bitPattern: bits) }
            let sign = UInt64(1) << (type.width - 1)
            return Int64(bitPattern: (bits ^ sign) &- sign)
        }
        func cast(_ target: CType) -> Value {
            let extended = !type.unsigned && signed < 0 ? UInt64(bitPattern: signed) : bits
            return .init(bits: extended, type: target)
        }
        var promoted: Value { type.width < 32 ? cast(.i32) : self }
    }
    indirect enum Expression {
        case literal(Value), variable(String), cast(CType, Expression)
        case binary(String, Expression, Expression), unary(String, Expression)
        case memory(CType, Expression)
        var containsMemory: Bool {
            switch self {
            case .memory: return true
            case .literal, .variable: return false
            case let .cast(_, value), let .unary(_, value): return value.containsMemory
            case let .binary(_, left, right): return left.containsMemory || right.containsMemory
            }
        }
        var variables: Set<String> {
            switch self {
            case .literal: return []
            case let .variable(name): return [name]
            case let .cast(_, value), let .unary(_, value), let .memory(_, value): return value.variables
            case let .binary(_, left, right): return left.variables.union(right.variables)
            }
        }
    }
    enum Operation {
        case assign([Expression], [Expression], CType?)
        case declare(String)
        case branch(Expression, Int)
        case jump(Int)
        case returned(Expression?)
        case unresolvedReturn
        case opaque(OpaqueSite)
    }
    struct Instruction { let operation: Operation; let source: UInt64? }
    struct OpaqueSite {
        let row: Int
        let frame: MacIRCallFrame
        let exactStatement: String
        let tokens: [String]
        let destination: String?
        let control: Expression?
        let arguments: [Expression]
        init(_ original: RegionalSwitchOracle.OpaqueSite) throws {
            row = original.row; frame = original.frame
            exactStatement = Program.payload(original.exactStatement)
            var tokens = try Program.lex(exactStatement.components(separatedBy: "//")[0])
            guard tokens.last == ";" else { throw Failure.invalid("original opaque call lacks terminator") }
            tokens.removeLast()
            self.tokens = tokens
            let rhs: [String]
            if let name = original.printedDestination {
                guard tokens.count >= 5, tokens[0] == name, tokens[1] == "=",
                      Program.identifier(name) else {
                    throw Failure.invalid("original opaque printed result does not match its contract")
                }
                destination = name
                rhs = Array(tokens.dropFirst(2))
            } else {
                guard !tokens.contains("=") else { throw Failure.invalid("printless call gained a result") }
                destination = nil
                rhs = tokens
            }
            let argumentsStart: Int
            if frame.controlInputs.indirectTarget != nil {
                guard rhs.count >= 6, rhs[0] == "(", rhs[1] == "*", rhs[3] == ")", rhs[4] == "(" else {
                    throw Failure.invalid("unsupported original indirect-call text")
                }
                control = try Program.expression([rhs[2]]); argumentsStart = 5
            } else {
                guard rhs.count >= 3, rhs[0] == frame.target, rhs[1] == "(" else {
                    throw Failure.invalid("original direct-call target text changed")
                }
                control = nil; argumentsStart = 2
            }
            guard rhs.last == ")" else { throw Failure.invalid("unclosed opaque call") }
            let inner = Array(rhs[argumentsStart..<rhs.count - 1])
            arguments = inner.isEmpty ? [] : try Program.split(inner, at: ",").map(Program.expression)
            guard arguments.count == frame.arguments.canonicalPhysicalEntriesForAudit.count else {
                throw Failure.invalid("original call argument count differs from frame")
            }
        }
    }
    struct Program {
        var code: [Instruction]
        var declarations: [String: CType]
        var rowByAddress: [UInt64: Int]
        /// One PC per contiguous source-effect group, not one per statement.
        /// Disjoint copies remain distinct and cannot silently select an arm.
        var entryPCsBySourceAddress: [UInt64: [Int]]
        init(document: PseudocodeDocument, source: RegionalSwitchOracle.Program,
             baselineText: String) throws {
            let signatures = document.lines.filter { $0.kind == .signature }
            let baselineLines = baselineText.components(separatedBy: "\n")
            guard signatures.count == 1, let originalSignature = baselineLines.first,
                  signatures[0].text.utf8.elementsEqual(originalSignature.utf8),
                  document.lines.first?.kind == .signature,
                  document.lines.filter({ $0.kind == .closingBrace }).count == 1,
                  document.lines.last?.kind == .closingBrace,
                  document.lines.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "}" else {
                throw Failure.invalid("misclassified or changed function envelope")
            }
            var sites: [UInt64: OpaqueSite] = [:]
            for (row, original) in source.opaqueSites {
                guard row == original.row, source.rows.indices.contains(row),
                      source.rows[row].address == original.address,
                      sites[original.address] == nil else { throw Failure.invalid("invalid original opaque site correspondence") }
                let site = try OpaqueSite(original)
                let lines = document.lines.filter {
                    $0.sourceAddress == original.address && $0.kind == .instruction &&
                    Self.payload($0.text).utf8.elementsEqual(site.exactStatement.utf8)
                }
                guard lines.count == 1 else { throw Failure.invalid("original opaque statement changed, missing, or duplicated") }
                sites[original.address] = site
            }
            var compiler = Compiler(document: document, callSites: sites)
            try compiler.compile()
            code = compiler.code
            let sourceAddresses = Set(source.rows.map(\.address))
            for instruction in code {
                let expressions: [Expression]
                switch instruction.operation {
                case let .assign(left, right, _): expressions = left + right
                case let .branch(value, _): expressions = [value]
                case let .returned(value): expressions = value.map { [$0] } ?? []
                case let .opaque(site): expressions = site.arguments + (site.control.map { [$0] } ?? [])
                default: expressions = []
                }
                if expressions.contains(where: \.containsMemory) {
                    guard let address = instruction.source, sourceAddresses.contains(address) else {
                        throw Failure.invalid("memory expression lacks original source association")
                    }
                }
                switch instruction.operation {
                case .returned(.some(_)), .unresolvedReturn:
                    throw Failure.invalid("candidate changed the original void terminal contract")
                default: break
                }
            }
            declarations = compiler.declarations
            for site in sites.values {
                guard let destination = site.destination else { continue }
                guard declarations[destination] == nil || declarations[destination] == .i64 else {
                    throw Failure.invalid("original opaque X0 result representation changed")
                }
            }
            rowByAddress = Dictionary(uniqueKeysWithValues: source.rows.enumerated().map { ($0.element.address, $0.offset) })
            entryPCsBySourceAddress = compiler.entryPCsBySourceAddress
        }
        func entryPC(forSourceAddress address: UInt64) throws -> Int {
            guard let entries = entryPCsBySourceAddress[address], !entries.isEmpty else {
                throw Failure.invalid("missing emitted source entry 0x\(String(address, radix: 16))")
            }
            guard entries.count == 1 else {
                throw Failure.invalid("ambiguous emitted source entry 0x\(String(address, radix: 16))")
            }
            guard code.indices.contains(entries[0]), code[entries[0]].source == address else {
                throw Failure.invalid("source entry does not precede an attributed effect")
            }
            return entries[0]
        }
        static func payload(_ text: String) -> String {
            // Preserve comments, trailing whitespace, and all interior bytes.
            String(text.drop(while: { $0 == " " }))
        }
        static func identifier(_ text: String) -> Bool {
            guard text.first?.isLetter == true || text.first == "_",
                  text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), CType(text) == nil else { return false }
            return !["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
                     "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict",
                     "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
                     "unsigned", "void", "volatile", "while", "true", "false", "_Alignas", "_Alignof", "_Atomic",
                     "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local"].contains(text)
        }
        static func number(_ text: String) -> UInt64? {
            text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
        }
        static func lex(_ text: String) throws -> [String] {
            let chars = Array(text)
            var result: [String] = [], index = 0
            while index < chars.count {
                let char = chars[index]
                if char.isWhitespace { index += 1; continue }
                if char.isLetter || char.isNumber || char == "_" {
                    let start = index
                    while index < chars.count && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_") { index += 1 }
                    result.append(String(chars[start..<index])); continue
                }
                if index + 1 < chars.count {
                    let pair = String(chars[index...index + 1])
                    if ["==", "!=", "<<", ">>", "<=", ">=", "&&", "||"].contains(pair) {
                        result.append(pair); index += 2; continue
                    }
                }
                guard "()+-*/%&|^~=,;{}<>!:".contains(char) else { throw Failure.invalid("unknown token \(char)") }
                result.append(String(char)); index += 1
            }
            return result
        }
        static func split(_ tokens: [String], at separator: String) throws -> [[String]] {
            var result: [[String]] = [[]], depth = 0
            for token in tokens {
                if token == "(" { depth += 1 }
                if token == ")" { depth -= 1 }
                guard depth >= 0 else { throw Failure.invalid("unbalanced expression") }
                if token == separator && depth == 0 { result.append([]) }
                else { result[result.count - 1].append(token) }
            }
            guard depth == 0 else { throw Failure.invalid("unclosed expression") }
            return result
        }
        static func expression(_ tokens: [String]) throws -> Expression {
            var parser = ExpressionParser(tokens: tokens)
            let result = try parser.parse()
            guard parser.index == tokens.count else { throw Failure.invalid("trailing expression / unknown helper: \(tokens)") }
            return result
        }
    }
    /// Compile only the deliberately enumerated scalar text grammar. No line
    /// is ignored because it is unfamiliar; source metadata only locates raw
    /// goto targets and records observations, never supplies expression values.
    struct Compiler {
        struct Token { let text: String; let source: UInt64? }
        struct SourceGroup {
            let source: UInt64
            let context: [Int]
        }
        struct Loop {
            let continueTarget: Int?
            var label: String? = nil
            var isLoop = true
            var breaks: [Int] = []
            var continues: [Int] = []
        }
        let document: PseudocodeDocument
        let callSites: [UInt64: OpaqueSite]
        var tokens: [Token] = []
        var markers: [Int: [UInt64]] = [:]
        var exactOpaqueStarts: [Int: OpaqueSite] = [:]
        var index = 0
        var code: [Instruction] = []
        var declarations: [String: CType] = [:]
        var addresses: [UInt64: Int] = [:]
        var entryPCsBySourceAddress: [UInt64: [Int]] = [:]
        var currentSourceGroup: SourceGroup?
        var controlContext: [Int] = []
        var nextControlContext = 0
        var labels: [String: Int] = [:]
        var pending: [(Int, String)] = []
        var loops: [Loop] = []
        var braceDepth = 0
        var seenExecutable = false
        var current: String? { index < tokens.count ? tokens[index].text : nil }
        mutating func mark() {
            // sequence() and statement() may visit the same token boundary.
            // Consume its raw-goto marker once. Regional entries are recorded
            // at actual effects, including an else-if after a closing brace.
            for source in markers.removeValue(forKey: index) ?? [] {
                if addresses[source] == nil { addresses[source] = code.count }
            }
        }
        mutating func enterControlBody() {
            controlContext.append(nextControlContext)
            nextControlContext += 1
        }
        mutating func take(_ expected: String) throws {
            guard current == expected else { throw Failure.invalid("expected \(expected), got \(current ?? "end")") }
            index += 1
        }
        mutating func emit(_ operation: Operation, source: UInt64?) -> Int {
            let pc = code.count
            if let source {
                // Repeated assignments of one source row have one entry. A
                // group may descend through control it starts, but cannot move
                // from one sibling arm to another or escape its initial arm.
                let sameGroup = currentSourceGroup.map {
                    $0.source == source && controlContext.starts(with: $0.context)
                } ?? false
                if !sameGroup {
                    entryPCsBySourceAddress[source, default: []].append(pc)
                    currentSourceGroup = .init(source: source, context: controlContext)
                }
            }
            code.append(.init(operation: operation, source: source))
            return pc
        }
        mutating func patch(_ pc: Int, _ target: Int) throws {
            switch code[pc].operation {
            case let .branch(predicate, _): code[pc] = .init(operation: .branch(predicate, target), source: code[pc].source)
            case .jump: code[pc] = .init(operation: .jump(target), source: code[pc].source)
            default: throw Failure.invalid("invalid control patch")
            }
        }
        mutating func compile() throws {
            for line in document.lines {
                let clean = line.text.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                switch line.kind {
                case .signature: continue // The declared function frame is not an executable statement.
                case .closingBrace:
                    guard clean == "}" else { throw Failure.invalid("invalid function close") }
                    continue
                case .metadata:
                    guard clean.isEmpty else { throw Failure.invalid("executable metadata must not be skipped") }
                    continue
                case .instruction, .declaration: break
                }
                if let source = line.sourceAddress { markers[tokens.count, default: []].append(source) }
                if let source = line.sourceAddress, let site = callSites[source],
                   Program.payload(line.text).utf8.elementsEqual(site.exactStatement.utf8) {
                    guard line.kind == .instruction, exactOpaqueStarts[tokens.count] == nil else {
                        throw Failure.invalid("misclassified original opaque statement")
                    }
                    exactOpaqueStarts[tokens.count] = site
                }
                tokens += try Program.lex(clean).map { Token(text: $0, source: line.sourceAddress) }
            }
            try sequence(untilClose: false)
            for (pc, target) in pending {
                let resolved = Program.number(target).flatMap { addresses[$0] } ?? labels[target]
                guard let resolved else { throw Failure.invalid("unresolved emitted goto \(target)") }
                try patch(pc, resolved)
            }
        }
        mutating func sequence(untilClose: Bool) throws {
            while index < tokens.count {
                mark()
                if current == "}" {
                    guard untilClose else { throw Failure.invalid("unexpected closing brace") }
                    index += 1
                    return
                }
                try statement()
            }
            mark()
            guard !untilClose else { throw Failure.invalid("unclosed body") }
        }
        mutating func condition() throws -> Expression {
            try take("(")
            let start = index
            var depth = 1
            while index < tokens.count {
                if current == "(" { depth += 1 }
                if current == ")" { depth -= 1 }
                if depth == 0 {
                    let expression = try Program.expression(tokens[start..<index].map(\.text))
                    index += 1
                    return expression
                }
                index += 1
            }
            throw Failure.invalid("unclosed condition")
        }
        mutating func statement(label: String? = nil) throws {
            mark()
            guard index < tokens.count else { throw Failure.invalid("missing statement") }
            let source = tokens[index].source
            if index + 1 < tokens.count, tokens[index + 1].text == ":" {
                guard label == nil else { throw Failure.invalid("nested labels on one scope") }
                let name = tokens[index].text
                guard Program.identifier(name) else { throw Failure.invalid("invalid label identifier") }
                guard labels[name] == nil else { throw Failure.invalid("duplicate label") }
                labels[name] = code.count
                index += 2
                guard ["{", "while", "do"].contains(current ?? "") else { throw Failure.invalid("unsupported labelled statement") }
                try statement(label: name)
                return
            }
            if current == "{" {
                if let label { loops.append(.init(continueTarget: nil, label: label, isLoop: false)) }
                index += 1; braceDepth += 1
                try sequence(untilClose: true)
                braceDepth -= 1
                if label != nil {
                    let scope = loops.removeLast()
                    guard scope.continues.isEmpty else { throw Failure.invalid("continue to non-loop scope") }
                    for site in scope.breaks { try patch(site, code.count) }
                }
                return
            }
            if current == "if" {
                seenExecutable = true
                index += 1
                let predicate = try condition()
                let falsePC = emit(.branch(.unary("!", predicate), -1), source: source)
                enterControlBody()
                try statement()
                controlContext.removeLast()
                if current == "else" {
                    index += 1
                    let endPC = emit(.jump(-1), source: nil)
                    try patch(falsePC, code.count)
                    enterControlBody()
                    try statement()
                    controlContext.removeLast()
                    try patch(endPC, code.count)
                } else { try patch(falsePC, code.count) }
                return
            }
            if current == "while" {
                seenExecutable = true
                index += 1
                let start = code.count
                let predicate = try condition()
                let exitPC = emit(.branch(.unary("!", predicate), -1), source: source)
                loops.append(.init(continueTarget: start, label: label))
                enterControlBody()
                try statement()
                controlContext.removeLast()
                _ = emit(.jump(start), source: nil)
                let loop = loops.removeLast()
                try patch(exitPC, code.count)
                for site in loop.breaks { try patch(site, code.count) }
                for site in loop.continues { try patch(site, start) }
                return
            }
            if current == "do" {
                seenExecutable = true
                index += 1
                let start = code.count
                loops.append(.init(continueTarget: nil, label: label))
                enterControlBody()
                try statement()
                controlContext.removeLast()
                mark()
                let conditionSource = index < tokens.count ? tokens[index].source : nil
                try take("while")
                let predicate = try condition()
                try take(";")
                let test = emit(.branch(predicate, start), source: conditionSource)
                let loop = loops.removeLast()
                for site in loop.breaks { try patch(site, code.count) }
                for site in loop.continues { try patch(site, test) }
                return
            }
            if current == "break" || current == "continue" {
                let isBreak = current == "break"
                index += 1
                var targetName: String?
                if current != ";" { targetName = current; index += 1 }
                try take(";")
                let target = targetName.flatMap { name in loops.lastIndex(where: { $0.label == name }) }
                    ?? (targetName == nil ? loops.lastIndex(where: { $0.isLoop }) : nil)
                guard let target, isBreak || loops[target].isLoop else { throw Failure.invalid("invalid lexical transfer target") }
                let site = emit(.jump(-1), source: source)
                if isBreak { loops[target].breaks.append(site) }
                else { loops[target].continues.append(site) }
                return
            }
            if current == "goto" {
                seenExecutable = true
                index += 1
                guard let target = current else { throw Failure.invalid("missing goto target") }
                index += 1; try take(";")
                pending.append((emit(.jump(-1), source: source), target))
                return
            }
            let start = index
            while index < tokens.count && current != ";" {
                guard current != "{" && current != "}" else { throw Failure.invalid("unterminated simple statement") }
                index += 1
            }
            guard current == ";" else { throw Failure.invalid("missing semicolon") }
            var body = tokens[start..<index].map(\.text)
            index += 1
            guard !body.isEmpty else { throw Failure.invalid("empty statement not in emitted subset") }
            if let site = exactOpaqueStarts[start] {
                guard source != nil, body == site.tokens else { throw Failure.invalid("split original opaque statement") }
                seenExecutable = true
                _ = emit(.opaque(site), source: source)
                return
            }
            if body.first == "return" {
                seenExecutable = true
                body.removeFirst()
                if body == ["unresolved_return_contract"] { _ = emit(.unresolvedReturn, source: source) }
                else { _ = emit(.returned(body.isEmpty ? nil : try Program.expression(body)), source: source) }
                return
            }
            let declared = body.first.flatMap(CType.init)
            if declared != nil { body.removeFirst() }
            let parts = try Program.split(body, at: "=")
            if let declared {
                guard braceDepth == 0, !seenExecutable else {
                    throw Failure.invalid("nested or late declaration outside the supported function-scope storage grammar")
                }
                guard parts[0].count == 1, let name = parts[0].first,
                      Program.identifier(name),
                      declarations[name] == nil,
                      !document.parameters.contains(where: { $0.name == name }),
                      !document.localVariables.contains(where: { $0.name == name }) else {
                    throw Failure.invalid("duplicate, colliding, or non-scalar declaration")
                }
                declarations[name] = declared
                if parts.count == 1 { _ = emit(.declare(name), source: source); return }
            }
            if declared == nil { seenExecutable = true }
            guard parts.count == 2 else { throw Failure.invalid("unknown statement / helper: \(body)") }
            let left = try Program.split(parts[0], at: ",").map(Program.expression)
            let right = try Program.split(parts[1], at: ",").map(Program.expression)
            guard left.count == right.count, !left.isEmpty else { throw Failure.invalid("tuple arity") }
            for destination in left {
                switch destination {
                case let .variable(name):
                    guard Program.identifier(name) else { throw Failure.invalid("invalid assignment lvalue") }
                    if document.parameters.contains(where: { $0.name == name }) {
                        throw Failure.invalid("assignment to an external input parameter outside the storage grammar")
                    }
                case .memory: break
                default: throw Failure.invalid("invalid assignment lvalue")
                }
            }
            _ = emit(.assign(left, right, declared), source: source)
        }
    }
    struct ExpressionParser {
        let tokens: [String]
        var index = 0
        let precedence = ["||": 1, "&&": 2, "|": 3, "^": 4, "&": 5, "==": 6, "!=": 6,
                          "<": 7, ">": 7, "<=": 7, ">=": 7, "<<": 8, ">>": 8, "+": 9, "-": 9, "*": 10, "/": 10, "%": 10]
        mutating func take(_ expected: String) throws {
            guard index < tokens.count, tokens[index] == expected else { throw Failure.invalid("expected \(expected): \(tokens)") }
            index += 1
        }
        mutating func parse(_ minimum: Int = 0) throws -> Expression {
            var left = try prefix()
            while index < tokens.count, let priority = precedence[tokens[index]], priority >= minimum {
                let op = tokens[index]; index += 1
                let right = try parse(priority + 1)
                left = .binary(op, left, right)
            }
            return left
        }
        mutating func prefix() throws -> Expression {
            guard index < tokens.count else { throw Failure.invalid("empty expression") }
            let token = tokens[index]; index += 1
            if token == "*" {
                try take("(")
                if index < tokens.count, let type = CType(tokens[index]) {
                    index += 1; try take("*"); try take(")")
                    return .memory(type, try prefix())
                }
                let address = try parse(); try take(")")
                // The existing scalar wide-memory dialect prints *(address).
                return .memory(.u64, address)
            }
            if token == "(" {
                if index < tokens.count, let type = CType(tokens[index]) {
                    index += 1; try take(")")
                    return .cast(type, try prefix())
                }
                let result = try parse(); try take(")"); return result
            }
            if token == "-" || token == "~" || token == "!" { return .unary(token, try prefix()) }
            if token == "true" || token == "false" { return .literal(.init(bits: token == "true" ? 1 : 0, type: .i32)) }
            if token.first?.isNumber == true {
                guard let bits = Program.number(token) else { throw Failure.invalid("unsupported integer literal \(token)") }
                let type: CType
                if token.hasPrefix("0x") {
                    // Unsuffixed hexadecimal LP64 candidates are int,
                    // unsigned int, long, unsigned long (then equivalent LL).
                    if bits <= UInt64(Int32.max) { type = .i32 }
                    else if bits <= UInt64(UInt32.max) { type = .u32 }
                    else if bits <= UInt64(Int64.max) { type = .i64 }
                    else { type = .u64 }
                } else {
                    // Unsuffixed decimal has no unsigned candidate. Extended
                    // integer types and decimal values outside signed64 are
                    // intentionally outside this emitted subset.
                    guard bits <= UInt64(Int64.max) else { throw Failure.invalid("unsupported decimal overflow \(token)") }
                    type = bits <= UInt64(Int32.max) ? .i32 : .i64
                }
                return .literal(.init(bits: bits, type: type))
            }
            guard Program.identifier(token) else { throw Failure.invalid("invalid expression atom \(token)") }
            return .variable(token)
        }
    }
    struct Commit { let source: UInt64; let values: [Value] }
    struct Result {
        var commits: [Commit] = []
        var events: [RegionalSwitchOracle.Event] = []
        // Emitted predicates only. A grouped ladder may evaluate a different
        // number of predicates than the source dispatch; source-branch count
        // equality is not a semantic observation for this switch oracle.
        var decisions: [Bool] = []
        var assignments: [UInt64: [[Value]]] = [:]
        var finalAssignments: [UInt64: [[Value]]] = [:]
        var memory: [UInt64: UInt8]
        var returned = false
        var reachedRegionBoundary = false
        var finalEnvironment: [String: Value] = [:]
        var observedEnvironments: [UInt64: [[String: Value]]] = [:]
        var returnValue: Value?
        var returnMarker: String?
    }
    let program: Program
    var environment: [String: Value]
    var result: Result
    let responses: [RegionalSwitchOracle.Response]
    let startSourceAddress: UInt64?
    let stopBeforeSourceAddress: UInt64?
    let observeAfterSourceAddresses: Set<UInt64>
    var responseIndex = 0
    var activeRow: Int?
    var occurrences: [Int: Int] = [:]
    init(program: Program, inputs: [String: Value], memory: [UInt64: UInt8],
         responses: [RegionalSwitchOracle.Response],
         startSourceAddress: UInt64? = nil, stopBeforeSourceAddress: UInt64? = nil,
         observeAfterSourceAddresses: Set<UInt64> = []) {
        self.program = program; environment = inputs; result = .init(memory: memory)
        self.responses = responses
        self.startSourceAddress = startSourceAddress
        self.stopBeforeSourceAddress = stopBeforeSourceAddress
        self.observeAfterSourceAddresses = observeAfterSourceAddresses
    }
    func run() throws -> Result {
        var machine = self
        return try machine.execute()
    }
    private mutating func observe(_ address: UInt64?) {
        guard let address, observeAfterSourceAddresses.contains(address) else { return }
        result.observedEnvironments[address, default: []].append(environment)
    }
    private mutating func execute() throws -> Result {
        var pc = try startSourceAddress.map { try program.entryPC(forSourceAddress: $0) } ?? 0
        let stopPC = try stopBeforeSourceAddress.map { try program.entryPC(forSourceAddress: $0) }
        var fuel = 20000
        var previousSource: UInt64?
        var lastAssignment: [UInt64: Int] = [:]
        for (site, instruction) in program.code.enumerated() {
            if let source = instruction.source, case .assign = instruction.operation { lastAssignment[source] = site }
        }
        while program.code.indices.contains(pc), fuel > 0 {
            let nextSource = program.code[pc].source
            if previousSource != nextSource {
                observe(previousSource)
                previousSource = nextSource
            }
            if pc == stopPC {
                guard responseIndex == responses.count else { throw Failure.invalid("emitted region skipped scripted opaque calls") }
                result.reachedRegionBoundary = true
                result.finalEnvironment = environment
                return result
            }
            fuel -= 1
            let instruction = program.code[pc]
            activeRow = instruction.source.flatMap { program.rowByAddress[$0] }
            switch instruction.operation {
            case let .assign(left, right, declared):
                // Evaluate all RHS and all memory lvalue addresses before any
                // assignment. This models the printer's parallel tuple dialect.
                var values: [Value] = []
                for expression in right { values.append(try evaluate(expression)) }
                var addresses: [UInt64?] = []
                for target in left {
                    if case let .memory(_, address) = target { addresses.append(try evaluate(address).bits) }
                    else { addresses.append(nil) }
                }
                var committed: [Value] = []
                for index in left.indices {
                    let value = try declared.map { try checkedCast(values[index], $0) } ?? values[index]
                    switch left[index] {
                    case let .variable(name):
                        let stored = try program.declarations[name].map { try checkedCast(value, $0) } ?? value
                        environment[name] = stored
                        committed.append(stored)
                    case let .memory(type, _):
                        guard let address = addresses[index] else { throw Failure.invalid("missing lvalue address") }
                        let narrowed = try checkedCast(value, type)
                        committed.append(narrowed)
                        guard let row = activeRow else { throw Failure.invalid("unsourced emitted memory store") }
                        result.events.append(.store(row: row, address: address, bytes: type.width / 8, bits: narrowed.bits))
                        for offset in 0..<(type.width / 8) {
                            result.memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: narrowed.bits >> (offset * 8))
                        }
                    default: throw Failure.invalid("non-lvalue assignment")
                    }
                }
                if let source = instruction.source {
                    result.assignments[source, default: []].append(values)
                    result.commits.append(.init(source: source, values: committed))
                    if lastAssignment[source] == pc { result.finalAssignments[source, default: []].append(committed) }
                }
                pc += 1
            case let .declare(name):
                environment.removeValue(forKey: name)
                pc += 1
            case let .jump(target): pc = target
            case let .branch(predicate, target):
                let taken = try evaluate(predicate).bits != 0
                result.decisions.append(taken)
                pc = taken ? target : pc + 1
            case let .opaque(site):
                try opaque(site)
                pc += 1
            case let .returned(value):
                guard responseIndex == responses.count else { throw Failure.invalid("emitted program skipped scripted opaque calls") }
                if let value { result.returnValue = try evaluate(value) }
                result.returned = true
                result.finalEnvironment = environment
                return result
            case .unresolvedReturn:
                throw Failure.invalid("unresolved terminal is not the original void return")
            }
        }
        throw Failure.invalid(fuel == 0 ? "unproductive control-flow fuel exhaustion" : "fell out without RET")
    }
    private mutating func opaque(_ site: OpaqueSite) throws {
        guard responseIndex < responses.count else { throw Failure.invalid("unscripted emitted opaque call") }
        let response = responses[responseIndex]
        guard response.row == site.row else { throw Failure.invalid("emitted call event order differs") }
        var arguments: [RegionalSwitchOracle.Carrier] = []
        for (expression, descriptor) in zip(site.arguments, site.frame.arguments.canonicalPhysicalEntriesForAudit) {
            guard case let .gpr(index, width) = descriptor.location else { throw Failure.invalid("unsupported emitted call carrier") }
            let bits = try evaluate(expression).cast(width == 32 ? .u32 : .u64).bits
            arguments.append(.init(register: index, width: width, bits: bits))
        }
        var control: [RegionalSwitchOracle.Carrier] = []
        if let expression = site.control {
            guard let descriptor = site.frame.controlInputs.indirectTarget,
                  case let .gpr(index) = descriptor.register else { throw Failure.invalid("missing original indirect control") }
            control.append(.init(register: index, width: 64, bits: try evaluate(expression).cast(.u64).bits))
        }
        for write in response.writes {
            guard [1, 2, 4, 8].contains(write.bytes) else { throw Failure.invalid("unsupported opaque write width") }
            for offset in 0..<write.bytes {
                result.memory[write.address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: write.bits >> (offset * 8))
            }
        }
        let boundResult = Value(bits: response.result, type: .i64)
        // A printless opaque result exists only in the script/event observation.
        // It must never acquire a text binding or feed a later expression.
        if let destination = site.destination { environment[destination] = boundResult }
        let occurrence = occurrences[site.row, default: 0]
        occurrences[site.row] = occurrence + 1
        result.events.append(.call(.init(row: site.row, occurrence: occurrence, target: site.frame.target,
            control: control, arguments: arguments, result: boundResult.bits, writes: response.writes)))
        responseIndex += 1
    }
    private func checkedCast(_ value: Value, _ target: CType, explicit: Bool = false) throws -> Value {
        if value.type.isPointer {
            guard explicit, target == .u64 else {
                throw Failure.invalid("pointer representation conversion requires explicit uint64_t cast")
            }
        }
        if !target.unsigned {
            let maximum = target.width == 64 ? UInt64(Int64.max) : (UInt64(1) << (target.width - 1)) - 1
            if value.type.unsigned {
                guard value.bits <= maximum else { throw Failure.undefined("implementation-defined unsigned-to-signed conversion") }
            } else {
                let minimum = target.width == 64 ? Int64.min : -(Int64(1) << (target.width - 1))
                guard value.signed >= minimum, value.signed <= Int64(maximum) else {
                    throw Failure.undefined("implementation-defined signed narrowing")
                }
            }
        }
        return value.cast(target)
    }
    private mutating func evaluate(_ expression: Expression) throws -> Value {
        switch expression {
        case let .literal(value): return value
        case let .variable(name):
            guard let value = environment[name] else { throw Failure.invalid("unbound emitted identifier \(name)") }
            return value
        case let .cast(type, value): return try checkedCast(evaluate(value), type, explicit: true)
        case let .memory(type, address):
            let location = try evaluate(address).bits
            var bits: UInt64 = 0
            for offset in 0..<(type.width / 8) {
                guard let byte = result.memory[location &+ UInt64(offset)] else {
                    throw Failure.invalid("read of undefined memory at \(location &+ UInt64(offset))")
                }
                bits |= UInt64(byte) << (offset * 8)
            }
            guard let row = activeRow else { throw Failure.invalid("unsourced emitted memory load") }
            result.events.append(.load(row: row, address: location, bytes: type.width / 8, bits: bits))
            return .init(bits: bits, type: type)
        case let .unary(op, expression):
            let value = try evaluate(expression).promoted
            guard !value.type.isPointer || op == "!" else { throw Failure.invalid("pointer unary arithmetic requires explicit bit representation") }
            if op == "~" { return .init(bits: ~value.bits, type: value.type) }
            if op == "!" { return .init(bits: value.bits == 0 ? 1 : 0, type: .i32) }
            guard op == "-" else { throw Failure.invalid("unknown unary operator \(op)") }
            return try binary("-", .init(bits: 0, type: value.type), value)
        case let .binary(op, lhs, rhs):
            let left = try evaluate(lhs)
            if op == "&&", left.bits == 0 { return .init(bits: 0, type: .i32) }
            if op == "||", left.bits != 0 { return .init(bits: 1, type: .i32) }
            let right = try evaluate(rhs)
            if op == "&&" || op == "||" { return .init(bits: right.bits != 0 ? 1 : 0, type: .i32) }
            return try binary(op, left, right)
        }
    }
    private func binary(_ op: String, _ lhs: Value, _ rhs: Value) throws -> Value {
        let left = lhs.promoted, right = rhs.promoted
        guard !left.type.isPointer, !right.type.isPointer else { throw Failure.invalid("pointer arithmetic requires explicit bit representation") }
        if op == "<<" || op == ">>" {
            guard right.type.unsigned || right.signed >= 0, right.bits < UInt64(left.type.width) else {
                throw Failure.undefined("shift amount outside width")
            }
            let shift = Int(right.bits)
            if op == ">>" {
                guard left.type.unsigned || left.signed >= 0 else { throw Failure.undefined("implementation-defined signed right shift") }
                return .init(bits: left.type.unsigned ? left.bits >> shift : UInt64(bitPattern: left.signed >> shift), type: left.type)
            }
            if !left.type.unsigned && (left.signed < 0 || left.bits > (left.type.mask >> 1) >> shift) {
                throw Failure.undefined("signed left shift overflow")
            }
            return .init(bits: left.bits << shift, type: left.type)
        }
        let type: CType
        if left.type.width == right.type.width {
            type = .init(width: left.type.width, unsigned: left.type.unsigned || right.type.unsigned)
        } else {
            // The wider signed type represents every value of a narrower
            // unsigned type for the supported 32/64-bit integer domains.
            type = left.type.width > right.type.width ? left.type : right.type
        }
        let a = left.cast(type), b = right.cast(type)
        if op == "==" || op == "!=" { return .init(bits: (op == "==" ? a.bits == b.bits : a.bits != b.bits) ? 1 : 0, type: .i32) }
        if ["<", ">", "<=", ">="].contains(op) {
            let less = type.unsigned ? a.bits < b.bits : a.signed < b.signed
            let equal = a.bits == b.bits
            let truth: Bool
            switch op {
            case "<": truth = less
            case ">": truth = !less && !equal
            case "<=": truth = less || equal
            default: truth = !less
            }
            return .init(bits: truth ? 1 : 0, type: .i32)
        }
        if op == "&" { return .init(bits: a.bits & b.bits, type: type) }
        if op == "|" { return .init(bits: a.bits | b.bits, type: type) }
        if op == "^" { return .init(bits: a.bits ^ b.bits, type: type) }
        if op == "/" || op == "%" {
            guard b.bits != 0 else { throw Failure.undefined("emitted division by zero") }
            if type.unsigned { return .init(bits: op == "/" ? a.bits / b.bits : a.bits % b.bits, type: type) }
            let minimum = type.width == 64 ? Int64.min : Int64(Int32.min)
            guard !(a.signed == minimum && b.signed == -1) else { throw Failure.undefined("emitted signed division overflow") }
            return .init(bits: UInt64(bitPattern: op == "/" ? a.signed / b.signed : a.signed % b.signed), type: type)
        }
        if type.unsigned {
            switch op {
            case "+": return .init(bits: a.bits &+ b.bits, type: type)
            case "-": return .init(bits: a.bits &- b.bits, type: type)
            case "*": return .init(bits: a.bits &* b.bits, type: type)
            default: throw Failure.invalid("unknown binary operator \(op)")
            }
        }
        let checked: (partialValue: Int64, overflow: Bool)
        switch op {
        case "+": checked = a.signed.addingReportingOverflow(b.signed)
        case "-": checked = a.signed.subtractingReportingOverflow(b.signed)
        case "*": checked = a.signed.multipliedReportingOverflow(by: b.signed)
        default: throw Failure.invalid("unknown signed binary operator \(op)")
        }
        guard !checked.overflow,
              type.width == 64 || (checked.partialValue >= Int64(Int32.min) && checked.partialValue <= Int64(Int32.max)) else {
            throw Failure.undefined("signed arithmetic overflow")
        }
        return .init(bits: UInt64(bitPattern: checked.partialValue), type: type)
    }
}

import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Independent, bounded control-syntax/edge audit. This is NOT a C compiler or
/// a scalar semantic oracle. Comments and literals cannot contribute transfers.
/// It never calls the old permissive labelled-region text grammar to grant credit.
enum OrdinaryCOutputAudit {
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case let .invalid(text): return text } }
    }
    struct Token {
        let text: String
        let line: Int
        let source: UInt64?
    }
    struct Transfer {
        let ordinal: Int
        let line: Int
        let kind: String
        let target: String?
        let source: UInt64?
        var sourceBlock: Int?
        var targetBlock: Int?
        var targetAddress: UInt64?
        var rawEquivalent: Bool
        var proof: String
        var countsAsGoto: Bool { kind == "goto" || ((kind == "break" || kind == "continue") && target != nil) }
    }
    struct Loop {
        let kind: String
        let first: Int
        let last: Int
        let condition: [Token]
        let increment: [Token]
    }
    struct Predicate {
        let kind: String
        let first: Int
        let last: Int
        let condition: [Token]
    }
    struct Report {
        let tokens: [Token]
        let transfers: [Transfer]
        let loops: [Loop]
        let predicates: [Predicate]
        let errors: [String]
        let structuredSourceAddresses: Set<UInt64>
        var gotoEquivalentTotal: Int { transfers.filter(\.countsAsGoto).count }
        var rawEquivalentTotal: Int { transfers.filter { $0.rawEquivalent && $0.kind != "__branch" }.count }
        var rawBranchTotal: Int { transfers.filter { $0.kind == "__branch" }.count }
        var allRawControlHelpers: Int { transfers.filter { isRawControlHelper($0.kind) }.count }
        var ledger: String {
            (["ordinal\tline\tkind\tsource_pc\tsource_block\ttarget\ttarget_pc\ttarget_block\tcounts_as_goto\traw_equivalent\tproof"] + transfers.map {
                "\($0.ordinal)\t\($0.line)\t\($0.kind)\t\(hex($0.source))\t\($0.sourceBlock.map(String.init) ?? "-")\t\($0.target ?? "-")\t\(hex($0.targetAddress))\t\($0.targetBlock.map(String.init) ?? "-")\t\($0.countsAsGoto)\t\($0.rawEquivalent)\t\($0.proof)"
            }).joined(separator: "\n")
        }
    }
    static func hex(_ value: UInt64?) -> String { value.map { "0x" + String($0, radix: 16) } ?? "-" }
    static func physicalLines(_ text: String) -> Int {
        // A final newline terminates the last physical line, not an extra line.
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.count
    }
    static func isRawControlHelper(_ text: String) -> Bool {
        matches(#"^__branch(?:_[A-Za-z0-9_]+)?$"#, text)
    }
    static func identifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func lex(_ text: String, sources: [Int: UInt64] = [:]) throws -> [Token] {
        let chars = Array(text)
        var index = 0, line = 1, result: [Token] = []
        func at(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }
        while index < chars.count {
            let char = chars[index]
            if char == "\n" { line += 1; index += 1; continue }
            if char.isWhitespace { index += 1; continue }
            if char == "/", at(1) == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/", at(1) == "*" {
                index += 2
                var closed = false
                while index < chars.count {
                    if chars[index] == "*", at(1) == "/" { index += 2; closed = true; break }
                    if chars[index] == "\n" { line += 1 }; index += 1
                }
                guard closed else { throw Failure.invalid("unclosed block comment") }
                continue
            }
            if char == "\"" || char == "'" {
                let quote = char, startLine = line
                index += 1
                var closed = false
                while index < chars.count {
                    if chars[index] == "\\" { index += min(2, chars.count - index); continue }
                    if chars[index] == quote { index += 1; closed = true; break }
                    if chars[index] == "\n" { line += 1 }; index += 1
                }
                guard closed else { throw Failure.invalid("unclosed literal") }
                result.append(.init(text: "$literal", line: startLine, source: sources[startLine]))
                continue
            }
            let start = index
            if char.isLetter || char.isNumber || char == "_" {
                index += 1
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { index += 1 }
            } else {
                index += 1
                if index < chars.count, ["==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "++", "--", "->", "+=", "-="].contains(String(chars[start...index])) { index += 1 }
            }
            result.append(.init(text: String(chars[start..<index]), line: line, source: sources[line]))
        }
        return result
    }

    /// Reads control statements, not RHS semantics. Scalar statements are opaque
    /// here and must separately pass the independent emitted-expression oracle.
    struct Parser {
        let tokens: [Token]
        var index = 0
        var loops: [Loop] = []
        var predicates: [Predicate] = []
        var labels: [String: Int] = [:]
        var labelledNonloops: Set<String> = []
        var labelStatementStarts: [String: Int] = [:]
        var errors: [String] = []
        var enclosing: [String] = []
        var transferScope: [Int: [String]] = [:]
        var conditionalOrigins: [UInt64?] = []
        var transferSource: [Int: UInt64] = [:]
        var structuredSources: Set<UInt64> = []
        var current: String { index < tokens.count ? tokens[index].text : "<end>" }
        mutating func take(_ text: String) throws {
            guard current == text else { throw Failure.invalid("expected \(text), got \(current), token \(index)") }; index += 1
        }
        mutating func parentheses() throws -> [Token] {
            try take("(")
            let start = index
            var depth = 1
            while index < tokens.count {
                if current == "(" { depth += 1 }
                if current == ")" { depth -= 1; if depth == 0 { let value = Array(tokens[start..<index]); index += 1; return value } }
                index += 1
            }
            throw Failure.invalid("unclosed condition")
        }
        mutating func parse() throws {
            // Exactly one complete native function envelope is checked by caller.
            guard let opening = tokens.firstIndex(where: { $0.text == "{" }) else { throw Failure.invalid("no function body") }
            index = opening
            try statement()
            guard index == tokens.count else { throw Failure.invalid("trailing text after function body") }
        }
        mutating func statement() throws {
            guard index < tokens.count else { throw Failure.invalid("missing statement") }
            let start = index, kind = current
            if kind != "default", kind != "case", identifier(kind),
               index + 1 < tokens.count, tokens[index + 1].text == ":" {
                if labels.updateValue(index, forKey: kind) != nil { errors.append("duplicate label \(kind)") }
                index += 2
                labelStatementStarts[kind] = index
                if current == "{" { labelledNonloops.insert(kind); errors.append("labelled non-loop scope \(kind)") }
                try statement(); return
            }
            if kind == "{" {
                index += 1
                while current != "}", index < tokens.count { try statement() }
                try take("}"); return
            }
            if kind == "if" {
                if let pc = tokens[index].source { structuredSources.insert(pc) }
                let origin = tokens[index].source
                index += 1; let predicate = try parentheses()
                conditionalOrigins.append(origin); try statement(); conditionalOrigins.removeLast()
                if current == "else" {
                    index += 1; conditionalOrigins.append(origin); try statement(); conditionalOrigins.removeLast()
                }
                predicates.append(.init(kind: "if", first: start, last: index, condition: predicate)); return
            }
            if kind == "while" || kind == "for" {
                if let pc = tokens[index].source { structuredSources.insert(pc) }
                index += 1
                let header = try parentheses()
                var condition = header, increment: [Token] = []
                if kind == "for" {
                    let separators = header.indices.filter { header[$0].text == ";" }
                    guard separators.count == 2 else { throw Failure.invalid("for header must retain init, predicate, increment") }
                    condition = Array(header[(separators[0] + 1)..<separators[1]])
                    increment = Array(header.dropFirst(separators[1] + 1))
                }
                enclosing.append(kind); try statement(); enclosing.removeLast()
                loops.append(.init(kind: kind, first: start, last: index, condition: condition, increment: increment)); return
            }
            if kind == "do" {
                index += 1; enclosing.append(kind); try statement(); enclosing.removeLast()
                if let pc = index < tokens.count ? tokens[index].source : nil { structuredSources.insert(pc) }
                try take("while"); let condition = try parentheses(); try take(";")
                loops.append(.init(kind: kind, first: start, last: index, condition: condition, increment: [])); return
            }
            if kind == "switch" {
                index += 1; _ = try parentheses(); enclosing.append(kind); try statement(); enclosing.removeLast(); return
            }
            if kind == "case" || kind == "default" {
                repeat { index += 1 } while index < tokens.count && current != ":"
                try take(":"); return
            }
            if ["goto", "break", "continue"].contains(kind) {
                transferScope[index] = enclosing
                if let origin = tokens[index].source ?? conditionalOrigins.reversed().compactMap({ $0 }).first { transferSource[index] = origin }
                index += 1
                if kind == "goto" {
                    guard identifier(current) else { throw Failure.invalid("goto requires one C label identifier") }
                    index += 1
                } else if current != ";" {
                    // Preserve a labelled transfer for accounting, but never
                    // admit it as ordinary C. Trailing arithmetic is rejected.
                    guard identifier(current) else { throw Failure.invalid("invalid labelled transfer token") }
                    index += 1
                }
                try take(";"); return
            }
            // Every transfer is recorded later, including multiple tokens on one
            // line, while this pass retains nearest lexical breakable scope.
            var parens = 0, brackets = 0
            while index < tokens.count {
                if ["goto", "break", "continue", "__branch", "return"].contains(current) {
                    transferScope[index] = enclosing
                    if let origin = tokens[index].source ?? conditionalOrigins.reversed().compactMap({ $0 }).first { transferSource[index] = origin }
                }
                if current == "(" { parens += 1 }; if current == ")" { parens -= 1 }
                if current == "[" { brackets += 1 }; if current == "]" { brackets -= 1 }
                if current == ";", parens == 0, brackets == 0 { index += 1; return }
                if current == "{" || current == "}" { throw Failure.invalid("unsupported scalar/control statement at line \(tokens[index].line)") }
                index += 1
            }
            throw Failure.invalid("unterminated statement")
        }
    }

    /// The printed landing may follow erased, effect-free direct B rows. This
    /// is not reachability: every intermediate block has exactly one decoded B,
    /// no side metadata or printed statement, and one agreeing successor. A
    /// unique source-successor route is required; cycles and loop-body skips fail.
    static func unprintedBranchPath(from origin: Int, to destination: Int,
                                    function: MacIRFunction, cfg: CFG,
                                    observedSourceAddresses: Set<UInt64>,
                                    forbiddenIntermediateBlocks: Set<Int>) -> [Int]? {
        guard cfg.blocks.indices.contains(origin), cfg.blocks.indices.contains(destination) else { return nil }
        var routes: [[Int]] = []
        for successor in cfg.blocks[origin].successors {
            var path = [origin], current = successor, seen: Set<Int> = [origin]
            while current != destination {
                guard cfg.blocks.indices.contains(current), seen.insert(current).inserted,
                      !forbiddenIntermediateBlocks.contains(current) else { break }
                let block = cfg.blocks[current]
                guard block.instructionRange.count == 1, block.successors.count == 1 else { break }
                let instruction = function.instructions[block.startIndex], source = instruction.source
                guard !observedSourceAddresses.contains(source.address),
                      instruction == MacIRInstruction(source: source, operation: instruction.operation),
                      source.mnemonic == "b", let envelope = source.structuredOperands,
                      envelope.architecture == .arm64, envelope.schemaVersion == 1,
                      envelope.coverage == .complete, envelope.opcodeClass == "b",
                      envelope.operands.count == 1, case let .pcRelative(reference) = envelope.operands[0],
                      reference.baseAddress == source.address, !reference.pageRelative,
                      envelope.semantics?.memoryAccess == nil, envelope.semantics?.memoryAccessWidth == nil,
                      case let .intrinsic(output, name, arguments) = instruction.operation,
                      output == nil, name == "branch", arguments.count == 1,
                      let irTarget = CFGBuilder.address(of: arguments[0]) else { break }
                let byteWords = source.byteText.split(separator: " ")
                let bytes = byteWords.compactMap { UInt8($0, radix: 16) }
                guard byteWords.count == 4, bytes.count == 4 else { break }
                let word = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
                guard word & 0xfc000000 == 0x14000000, source.address <= UInt64(Int64.max) else { break }
                let raw = Int64(word & 0x03ffffff)
                let delta = (raw >= 0x02000000 ? raw - 0x04000000 : raw) * 4
                let (decoded, overflow) = Int64(source.address).addingReportingOverflow(delta)
                let operand = source.operands.trimmingCharacters(in: .whitespaces)
                guard !overflow, decoded >= 0, reference.displacement == delta,
                      reference.target == UInt64(decoded), operand.hasPrefix("0x"),
                      UInt64(operand.dropFirst(2), radix: 16) == UInt64(decoded), irTarget == UInt64(decoded),
                      let next = block.successors.first, cfg.blocks.indices.contains(next),
                      function.instructions[cfg.blocks[next].startIndex].source.address == irTarget else { break }
                path.append(current); current = next
            }
            if current == destination { routes.append(path + [destination]) }
        }
        return routes.count == 1 ? routes[0] : nil
    }

    static func analyze(document: PseudocodeDocument, function: MacIRFunction, baselineText: String) throws -> Report {
        let sources = Dictionary(uniqueKeysWithValues: document.lines.compactMap { line in line.sourceAddress.map { (line.lineNumber, $0) } })
        let tokens = try lex(document.text, sources: sources)
        var parser = Parser(tokens: tokens)
        // Invalid legacy syntax is behavioral failure, not a Swift compilation error.
        do { try parser.parse() } catch { parser.errors.append("ORDINARY_C_GRAMMAR_REQUIRED: \(error)") }
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        var blockByAddress: [UInt64: Int] = [:]
        for block in cfg.blocks { for row in block.instructionRange { blockByAddress[function.instructions[row].source.address] = block.index } }
        func block(_ token: Token) -> Int? { token.source.flatMap { blockByAddress[$0] } }
        func address(_ token: String) -> UInt64? {
            if token.hasPrefix("0x") { return UInt64(token.dropFirst(2), radix: 16) }
            if token.hasPrefix("L_") { return UInt64(token.dropFirst(2), radix: 16) }
            return nil
        }
        var naturalLoops: [Int: Set<Int>] = [:]
        for edge in cfg.backEdges {
            var members: Set<Int> = [edge.to, edge.from]
            var work = edge.from == edge.to ? [] : [edge.from]
            while let item = work.popLast() {
                if item == edge.to { continue }
                for previous in cfg.blocks[item].predecessors where !members.contains(previous) {
                    members.insert(previous); if previous != edge.to { work.append(previous) }
                }
            }
            naturalLoops[edge.to, default: []].formUnion(members)
        }
        var loopHeaders: [Int: Int] = [:]
        for (ordinal, loop) in parser.loops.enumerated() {
            let visible = Set(tokens[loop.first..<loop.last].compactMap(block))
            let candidates = naturalLoops.keys.filter { header in
                cfg.backEdges.contains { $0.to == header && visible.contains($0.from) && visible.contains($0.to) }
            }
            if candidates.count == 1 {
                if loopHeaders.values.contains(candidates[0]) {
                    parser.errors.append("one CFG cycle cannot authorize an extra synthetic wrapper loop")
                }
                loopHeaders[ordinal] = candidates[0]
            }
            else { parser.errors.append("REAL_CFG_LOOP_REQUIRED: \(loop.kind) at line \(tokens[loop.first].line) owns \(candidates.count) independently identified loop headers") }
            let predicate = loop.condition.map(\.text)
            if predicate.isEmpty || predicate == ["0"] || predicate == ["false"] {
                parser.errors.append("synthetic one-shot or predicate-free loop at line \(tokens[loop.first].line)")
            }
        }
        var transfers: [Transfer] = []
        for index in tokens.indices {
            let token = tokens[index]
            guard ["goto", "break", "continue", "return"].contains(token.text) || isRawControlHelper(token.text) else { continue }
            let next = index + 1 < tokens.count ? tokens[index + 1].text : "<end>"
            let target = token.text == "goto" ? next : ((token.text == "break" || token.text == "continue") && next != ";" ? next : nil)
            if token.text == "goto" {
                if index + 2 >= tokens.count || !identifier(next) || tokens[index + 2].text != ";" {
                    parser.errors.append("goto must be exactly goto identifier; at line \(token.line)")
                }
            } else if token.text == "break" || token.text == "continue" {
                let bare = next == ";"
                let labelled = identifier(next) && index + 2 < tokens.count && tokens[index + 2].text == ";"
                if !bare && !labelled { parser.errors.append("malformed \(token.text) at line \(token.line)") }
            }
            let originPC = token.source ?? parser.transferSource[index]
            var row = Transfer(ordinal: transfers.count + 1, line: token.line, kind: token.text, target: target,
                source: originPC, sourceBlock: originPC.flatMap { blockByAddress[$0] }, targetBlock: nil, targetAddress: nil,
                rawEquivalent: token.text == "goto" && next.hasPrefix("0x"), proof: "unresolved")
            if token.text == "return" { row.proof = "terminal; not a goto"; transfers.append(row); continue }
            if let origin = row.sourceBlock {
                let terminatorPC = function.instructions[cfg.blocks[origin].endIndex - 1].source.address
                if originPC != terminatorPC {
                    parser.errors.append("transfer at line \(token.line) is attributed to a nonterminating source row")
                }
            } else { parser.errors.append("transfer at line \(token.line) has no original source terminator") }
            if isRawControlHelper(token.text) {
                // The exact five fixtures have only in-function raw branches.
                // Do not invent an expectation change for an unchanged opaque
                // exterior tail in a future adapter: certify it, keep it visible,
                // and give it no structuring/removal credit.
                let original = function.instructions.first { $0.source.address == originPC }
                let unchangedLine = document.lines.first { $0.lineNumber == token.line }.map { $0.text.trimmingCharacters(in: .whitespaces) }
                let baselineLines = Set(baselineText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
                var preservedExterior = false
                if token.text == "__branch", let original,
                   case let .unconditionalBranch(target) = CFGBuilder.terminatorKind(of: original.operation),
                   let target, blockByAddress[target] == nil, let unchangedLine,
                   baselineLines.contains(unchangedLine) {
                    preservedExterior = true; row.targetAddress = target
                }
                if !preservedExterior { parser.errors.append("RAW_CONTROL_HELPER_MUST_REMAIN_EXPLICIT_COUNTED_GOTO: \(token.text), line \(token.line)") }
                row.rawEquivalent = false
                row.proof = preservedExterior ? "unchanged opaque exterior, uncredited; separate raw-branch diagnostic" : "raw control helper; separate diagnostic, not hidden owner-total credit"
                transfers.append(row); continue
            }
            if (token.text == "break" || token.text == "continue"), let target {
                row.rawEquivalent = parser.labelledNonloops.contains(target)
                row.proof = row.rawEquivalent ? "invalid non-loop scope exit, counted once as goto and classified raw-equivalent" : "invalid labelled transfer, counted once as goto"
                parser.errors.append("ORDINARY_C_NO_LABELLED_TRANSFER: \(token.text) \(target) at line \(token.line)")
                transfers.append(row); continue
            }
            if token.text == "goto" {
                guard let target, matches(#"^L_[0-9a-fA-F]+$"#, target), let pc = address(target),
                      let labelIndex = parser.labels[target], var statementIndex = parser.labelStatementStarts[target], let destination = blockByAddress[pc] else {
                    parser.errors.append("residual goto must resolve exactly once to native L_<hex> and an original source block at line \(token.line)")
                    transfers.append(row); continue
                }
                row.targetAddress = pc; row.targetBlock = destination
                // Follow only consecutive labels, never skip an unrelated
                // statement in search of some convenient source address.
                while statementIndex + 1 < tokens.count, identifier(tokens[statementIndex].text), tokens[statementIndex + 1].text == ":" { statementIndex += 2 }
                let labelSource = statementIndex < tokens.count ? tokens[statementIndex].source : nil
                _ = labelIndex
                if labelSource.flatMap({ blockByAddress[$0] }) != destination {
                    parser.errors.append("label \(target) does not identify its source block statement boundary")
                }
                if let origin = row.sourceBlock, cfg.blocks[origin].successors.contains(destination) {
                    row.proof = "original CFG edge \(origin)->\(destination); residual/uncredited, never raw-removal credit"
                } else { parser.errors.append("goto at line \(token.line) lacks an original source CFG edge") }
                transfers.append(row); continue
            }
            let enclosingLoops = parser.loops.indices.filter { parser.loops[$0].first <= index && index < parser.loops[$0].last }
            let nearest = enclosingLoops.min { (parser.loops[$0].last - parser.loops[$0].first) < (parser.loops[$1].last - parser.loops[$1].first) }
            guard let nearest, let header = loopHeaders[nearest], let members = naturalLoops[header],
                  let origin = row.sourceBlock, members.contains(origin),
                  parser.transferScope[index]?.last != "switch" else {
                parser.errors.append("plain \(token.text) at line \(token.line) lacks innermost REAL CFG-loop source ownership")
                transfers.append(row); continue
            }
            let loop = parser.loops[nearest]
            let destination: Int?
            if token.text == "break" {
                destination = tokens.dropFirst(loop.last).first(where: { $0.source != nil }).flatMap(block)
            } else if loop.kind == "do" {
                destination = loop.condition.first(where: { $0.source != nil }).flatMap(block)
            } else if loop.kind == "for", !loop.increment.isEmpty {
                destination = loop.increment.first(where: { $0.source != nil }).flatMap(block)
            } else { destination = header }
            let route = destination.flatMap { target -> [Int]? in
                if cfg.blocks[origin].successors.contains(target) { return [origin, target] }
                guard token.text == "break" else { return nil }
                return unprintedBranchPath(from: origin, to: target, function: function, cfg: cfg,
                    observedSourceAddresses: Set(tokens.compactMap(\.source)), forbiddenIntermediateBlocks: members)
            }
            if let destination, let route,
               (token.text == "break" ? !members.contains(destination) : members.contains(destination)) {
                row.targetBlock = destination
                row.targetAddress = function.instructions[cfg.blocks[destination].startIndex].source.address
                let edgeNames = zip(route, route.dropFirst()).map { from, to in
                    "\(from)-[\(cfg.blocks[from].successors.firstIndex(of: to)!)]->\(to)"
                }
                row.proof = "plain \(token.text), innermost real loop H\(header), original successor-ordinal path \(edgeNames.joined(separator: ",")); intermediate rows are unprinted decoded B-only blocks"
            } else { parser.errors.append("plain \(token.text) at line \(token.line) does not prove its precise C destination (including do condition/for increment)") }
            transfers.append(row)
        }
        for index in tokens.indices where index + 1 < tokens.count {
            let token = tokens[index]
            guard token.text.hasPrefix("__"), identifier(token.text), tokens[index + 1].text == "(",
                  !isRawControlHelper(token.text), let pc = token.source,
                  let original = function.instructions.first(where: { $0.source.address == pc }) else { continue }
            switch CFGBuilder.terminatorKind(of: original.operation) {
            case .conditionalBranch, .unconditionalBranch, .switchDispatch:
                parser.errors.append("unclassified helper on original control row \(hex(pc)): \(token.text)")
            default: break
            }
        }
        return .init(tokens: tokens, transfers: transfers, loops: parser.loops, predicates: parser.predicates, errors: parser.errors,
                     structuredSourceAddresses: parser.structuredSources)
    }
}

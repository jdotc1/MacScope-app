import Foundation

#if DEBUG
/// A check of the *emitted* recovery control language, not another rendering of
/// RecoveryRegion. The existing block renderer remains responsible for real
/// expression/statement semantics. Its exact payload snapshots identify block
/// occurrences (including empty branch-only blocks), and keep opaque statements
/// out of this deliberately small control parser. No visit markers reach output.
///
/// The parser reads braces, labels, transfers and actual predicate spelling from
/// PseudocodeLine.text. It then checks strong, ordered transitions against both
/// the plan's individual occurrences and the CFG, including cycles and returns.
/// This does not prove the lifter or arbitrary C-like payload expressions correct.
enum CP6RecoveryTextCheck {
    struct BlockOccurrence: Sendable {
        var block: Int
        var start: Int
        var payload: [PseudocodeLine]
    }

    struct Branch: Sendable {
        var block: Int
        var lineIndex: Int
        var forward: String
        var inverted: String?
        var source: MacIRSourceSpan
    }

    struct Emission: Sendable {
        var bodyStart: Int
        var blocks: [BlockOccurrence] = []
        var branches: [Branch] = []

        mutating func recordBlock(_ block: Int, payloadStart: Int, lines: [PseudocodeLine]) {
            blocks.append(BlockOccurrence(block: block, start: payloadStart,
                                          payload: Array(lines[payloadStart...])))
        }

        mutating func recordBranch(_ block: Int, lineIndex: Int, forward: String,
                                   inverted: String?, source: MacIRSourceSpan) {
            branches.append(Branch(block: block, lineIndex: lineIndex,
                                   forward: forward, inverted: inverted, source: source))
        }
    }

    struct Snapshot: Sendable {
        var lines: [PseudocodeLine]
        var plan: RegionTree.RecoveryRegion
        var cfg: CFG
        var emission: Emission

        var isValid: Bool {
            CP6RecoveryTextCheck.validate(lines: lines, plan: plan, cfg: cfg, emission: emission)
        }
    }

    /// Instance-scoped test observation; no process-global callback or mutable
    /// shared parser state. The lock protects the optional value for Sendable.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Snapshot?

        var snapshot: Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func record(lines: [PseudocodeLine], plan: RegionTree.RecoveryRegion,
                    cfg: CFG, emission: Emission) {
            lock.lock()
            defer { lock.unlock() }
            value = Snapshot(lines: lines, plan: plan, cfg: cfg, emission: emission)
        }
    }

    private enum Failure: Error {
        case invalid(String)
    }

    private enum Operation {
        case visit(Int) // unique plan occurrence, not just the original block
        case decision(block: Int, taken: Int, notTaken: Int)
        case jump(Int)
        case terminal
        case end
    }

    private struct PayloadLine: Equatable {
        var kind: PseudocodeLineKind
        var text: String
        var source: MacIRSourceSpan?
    }

    static func validate(lines: [PseudocodeLine], plan: RegionTree.RecoveryRegion,
                         cfg: CFG, emission: Emission) -> Bool {
        failure(lines: lines, plan: plan, cfg: cfg, emission: emission) == nil
    }

    /// Kept internal so focused mutation tests can report the failing invariant.
    static func failure(lines: [PseudocodeLine], plan: RegionTree.RecoveryRegion,
                        cfg: CFG, emission: Emission) -> String? {
        do {
            try check(lines: lines, plan: plan, cfg: cfg, emission: emission)
            return nil
        } catch Failure.invalid(let reason) {
            return reason
        } catch {
            return "unexpected recovery text check error"
        }
    }

    private static func check(lines: [PseudocodeLine], plan: RegionTree.RecoveryRegion,
                              cfg: CFG, emission: Emission) throws {
        guard emission.bodyStart >= 0, emission.bodyStart <= lines.count,
              !emission.blocks.isEmpty, emission.blocks.count <= 8192,
              RegionTree.recoveryIsEquivalent(plan, to: cfg) else {
            throw Failure.invalid("invalid recovery plan or emission bounds")
        }
        let expected = try expectedTransitions(plan, cfg: cfg, occurrences: emission.blocks)
        var previousEnd = emission.bodyStart
        var canonicalPayloads: [Int: [PayloadLine]] = [:]
        for occurrence in emission.blocks {
            let end = occurrence.start + occurrence.payload.count
            guard cfg.blocks.indices.contains(occurrence.block),
                  occurrence.start >= previousEnd, end <= lines.count,
                  Array(lines[occurrence.start..<end]) == occurrence.payload else {
                throw Failure.invalid("changed, missing or overlapping block payload")
            }
            let payload = occurrence.payload.map {
                PayloadLine(kind: $0.kind, text: $0.text.trimmingCharacters(in: .whitespaces), source: $0.source)
            }
            if let first = canonicalPayloads[occurrence.block], first != payload {
                throw Failure.invalid("duplicate occurrences have different block payloads")
            }
            canonicalPayloads[occurrence.block] = payload
            previousEnd = end
        }
        var branches: [Int: Branch] = [:]
        for branch in emission.branches {
            guard branches[branch.lineIndex] == nil,
                  (emission.bodyStart..<lines.count).contains(branch.lineIndex),
                  cfg.blocks.indices.contains(branch.block),
                  cfg.blocks[branch.block].successors.count == 2,
                  branch.forward != branch.inverted else {
                throw Failure.invalid("invalid branch metadata")
            }
            branches[branch.lineIndex] = branch
        }
        guard branches.count == emission.blocks.filter({ cfg.blocks[$0.block].successors.count == 2 }).count else {
            throw Failure.invalid("missing or duplicate decision metadata")
        }

        var cursor = emission.bodyStart
        var occurrenceIndex = 0
        var code: [Operation] = []
        var breaks: [String: [Int]] = [:]
        var continues: [String: Int] = [:]
        var consumedBranches = Set<Int>()
        var parserBudget = 32768

        func appendTransfer(_ text: String) throws {
            if text.hasPrefix("break "), text.hasSuffix(";") {
                let label = String(text.dropFirst(6).dropLast())
                guard validLabel(label), breaks[label] != nil else {
                    throw Failure.invalid("unbound break label")
                }
                breaks[label]!.append(code.count)
                code.append(.jump(-1))
            } else if text.hasPrefix("continue "), text.hasSuffix(";") {
                let label = String(text.dropFirst(9).dropLast())
                guard validLabel(label), let start = continues[label] else {
                    throw Failure.invalid("unbound continue label")
                }
                code.append(.jump(start))
            } else {
                throw Failure.invalid("invalid recovery transfer")
            }
        }

        func parseBlock(_ depth: Int) throws {
            guard depth <= 256 else { throw Failure.invalid("text nesting budget") }
            while true {
                parserBudget -= 1
                guard parserBudget >= 0 else { throw Failure.invalid("text parser budget") }
                // Boundaries, rather than source-address heuristics, preserve
                // empty blocks and several distinct occurrences at one boundary.
                while occurrenceIndex < emission.blocks.count,
                      emission.blocks[occurrenceIndex].start == cursor {
                    let occurrence = emission.blocks[occurrenceIndex]
                    code.append(.visit(occurrenceIndex))
                    var terminal = false
                    for line in occurrence.payload {
                        let statement = executableText(line.text)
                        guard !terminal, line.kind == .instruction,
                              !isRecoveryControl(statement) else {
                            throw Failure.invalid("non-straight-line or unreachable opaque payload")
                        }
                        terminal = isTerminal(statement)
                    }
                    guard terminal == cfg.blocks[occurrence.block].successors.isEmpty else {
                        throw Failure.invalid("payload termination differs from CFG")
                    }
                    if terminal { code.append(.terminal) }
                    cursor += occurrence.payload.count
                    occurrenceIndex += 1
                }
                if cursor == lines.count { return }
                guard lines.indices.contains(cursor),
                      occurrenceIndex == emission.blocks.count || emission.blocks[occurrenceIndex].start >= cursor,
                      lines[cursor].kind == .instruction else {
                    throw Failure.invalid("invalid executable line boundary")
                }
                let lineIndex = cursor
                let line = lines[cursor]
                let value = executableText(line.text)
                if value == "}" || value == "} else {" { return }
                cursor += 1

                if value.hasSuffix(": while (true) {") {
                    let label = String(value.dropLast(16))
                    guard validLabel(label), continues[label] == nil, breaks[label] == nil else {
                        throw Failure.invalid("invalid or duplicate live loop label")
                    }
                    let start = code.count
                    continues[label] = start
                    try parseBlock(depth + 1)
                    guard cursor < lines.count, executableText(lines[cursor].text) == "}" else {
                        throw Failure.invalid("missing loop close")
                    }
                    cursor += 1
                    code.append(.jump(start))
                    continues.removeValue(forKey: label)
                } else if value.hasSuffix(": {") {
                    let label = String(value.dropLast(3))
                    guard validLabel(label), breaks[label] == nil, continues[label] == nil else {
                        throw Failure.invalid("invalid or duplicate live scope label")
                    }
                    breaks[label] = []
                    try parseBlock(depth + 1)
                    guard cursor < lines.count, executableText(lines[cursor].text) == "}" else {
                        throw Failure.invalid("missing scope close")
                    }
                    cursor += 1
                    for site in breaks.removeValue(forKey: label)! { code[site] = .jump(code.count) }
                } else if value.hasPrefix("if (") {
                    guard let branch = branches[lineIndex], line.source == branch.source,
                          consumedBranches.insert(lineIndex).inserted,
                          let parsed = conditionAndBody(value) else {
                        throw Failure.invalid("unattributed or malformed predicate")
                    }
                    let inverted: Bool
                    if parsed.condition == branch.forward { inverted = false }
                    else if let inverse = branch.inverted, parsed.condition == inverse { inverted = true }
                    else { throw Failure.invalid("changed predicate") }
                    let site = code.count
                    code.append(.decision(block: branch.block, taken: -1, notTaken: -1))
                    let trueStart = code.count
                    let falseStart: Int
                    if parsed.body == "{" {
                        try parseBlock(depth + 1)
                        guard cursor < lines.count else { throw Failure.invalid("missing if close") }
                        let close = executableText(lines[cursor].text)
                        if close == "} else {" {
                            cursor += 1
                            let skipElse = code.count
                            code.append(.jump(-1))
                            falseStart = code.count
                            try parseBlock(depth + 1)
                            guard cursor < lines.count, executableText(lines[cursor].text) == "}" else {
                                throw Failure.invalid("missing else close")
                            }
                            cursor += 1
                            code[skipElse] = .jump(code.count)
                        } else if close == "}" {
                            cursor += 1
                            falseStart = code.count
                        } else {
                            throw Failure.invalid("invalid if close")
                        }
                    } else {
                        // The only unbraced form is a single named transfer.
                        try appendTransfer(parsed.body)
                        falseStart = code.count
                    }
                    code[site] = .decision(block: branch.block,
                                           taken: inverted ? falseStart : trueStart,
                                           notTaken: inverted ? trueStart : falseStart)
                } else {
                    try appendTransfer(value)
                }
            }
        }
        try parseBlock(0)
        guard cursor == lines.count, occurrenceIndex == emission.blocks.count,
              consumedBranches.count == branches.count else {
            throw Failure.invalid("unmatched braces or unconsumed emission metadata")
        }
        code.append(.end) // Falling out is observably distinct from a return.

        func nextObservable(_ start: Int) -> Int? {
            var pc = start
            var seen = Set<Int>()
            while code.indices.contains(pc), seen.insert(pc).inserted {
                if case .jump(let destination) = code[pc] { pc = destination }
                else { return pc }
            }
            return nil // includes unproductive structural cycles
        }
        guard let entry = nextObservable(0), case .visit(let first) = code[entry],
              first == expected.entry, emission.blocks[first].block == cfg.entryIndex else {
            throw Failure.invalid("text entry differs from plan")
        }
        var pending = [entry]
        var visited = Set<Int>()
        var visitedDecisions = Set<Int>()
        while let site = pending.popLast() {
            guard visited.insert(site).inserted else { continue }
            guard case .visit(let occurrence) = code[site],
                  let next = nextObservable(site + 1) else {
                throw Failure.invalid("lost block occurrence or structural-only cycle")
            }
            let block = emission.blocks[occurrence].block
            let successors = cfg.blocks[block].successors
            let destinations: [Int]
            switch successors.count {
            case 0:
                guard case .terminal = code[next] else { throw Failure.invalid("missing terminal payload") }
                destinations = []
            case 1:
                destinations = [next]
            case 2:
                guard case .decision(let original, let taken, let notTaken) = code[next], original == block,
                      let a = nextObservable(taken), let b = nextObservable(notTaken) else {
                    throw Failure.invalid("missing or misplaced ordered decision")
                }
                visitedDecisions.insert(next)
                destinations = [a, b]
            default:
                throw Failure.invalid("unsupported successor arity")
            }
            guard expected.successors[occurrence].count == destinations.count else {
                throw Failure.invalid("text arity differs from plan")
            }
            for (edge, destination) in destinations.enumerated() {
                guard case .visit(let actual) = code[destination],
                      actual == expected.successors[occurrence][edge],
                      emission.blocks[actual].block == successors[edge] else {
                    throw Failure.invalid("ordered text transition differs from plan or CFG")
                }
                pending.append(destination)
            }
        }
        guard visited.count == emission.blocks.count, visitedDecisions.count == branches.count else {
            throw Failure.invalid("unreachable duplicate payload or decision")
        }
    }

    private struct ExpectedTransitions {
        var entry: Int
        var successors: [[Int]]
    }

    /// Extract *individual occurrence* edges from the plan. Reverse traversal
    /// allocates occurrence IDs in reverse pre-order, matching emission order
    /// without consulting a single emitted control token or branch annotation.
    private static func expectedTransitions(_ plan: RegionTree.RecoveryRegion, cfg: CFG,
                                            occurrences: [BlockOccurrence]) throws -> ExpectedTransitions {
        struct Vertex {
            var occurrence: Int?
            var next: [Int]
        }
        var graph = [Vertex(occurrence: nil, next: [])]
        var occurrence = occurrences.count
        var budget = 8192
        func add(_ original: Int?, _ next: [Int]) -> Int {
            graph.append(Vertex(occurrence: original, next: next))
            return graph.count - 1
        }
        func extract(_ region: RegionTree.RecoveryRegion, next: Int,
                     breaks: [Int: Int], continues: [Int: Int], depth: Int) throws -> Int {
            budget -= 1
            guard budget >= 0, depth <= 256 else { throw Failure.invalid("plan extraction budget") }
            switch region {
            case .sequence(let children):
                var cursor = next
                for child in children.reversed() {
                    cursor = try extract(child, next: cursor, breaks: breaks, continues: continues, depth: depth + 1)
                }
                return cursor
            case .block(let block, let exits):
                var targets: [Int] = []
                for exit in exits.reversed() {
                    targets.append(try extract(exit, next: next, breaks: breaks, continues: continues, depth: depth + 1))
                }
                occurrence -= 1
                guard occurrence >= 0, occurrences[occurrence].block == block,
                      cfg.blocks.indices.contains(block), exits.count == cfg.blocks[block].successors.count else {
                    throw Failure.invalid("emission block inventory differs from plan")
                }
                return add(occurrence, Array(targets.reversed()))
            case .scope(let target, let body):
                guard breaks[target] == nil else { throw Failure.invalid("duplicate plan scope") }
                var environment = breaks
                environment[target] = next
                return try extract(body, next: next, breaks: environment, continues: continues, depth: depth + 1)
            case .loop(let header, let body):
                guard continues[header] == nil else { throw Failure.invalid("duplicate plan loop") }
                let start = add(nil, [])
                var environment = continues
                environment[header] = start
                let bodyStart = try extract(body, next: start, breaks: breaks, continues: environment, depth: depth + 1)
                graph[start].next = [bodyStart]
                return start
            case .breakTo(let target):
                guard let target = breaks[target] else { throw Failure.invalid("unbound plan break") }
                return target
            case .continueAt(let header):
                guard let target = continues[header] else { throw Failure.invalid("unbound plan continue") }
                return target
            }
        }
        let start = try extract(plan, next: 0, breaks: [:], continues: [:], depth: 0)
        guard occurrence == 0 else { throw Failure.invalid("extra emission block occurrences") }
        func event(_ start: Int) -> Int? {
            var cursor = start
            var seen = Set<Int>()
            while graph.indices.contains(cursor), seen.insert(cursor).inserted {
                if let occurrence = graph[cursor].occurrence { return occurrence }
                guard graph[cursor].next.count == 1 else { return nil }
                cursor = graph[cursor].next[0]
            }
            return nil
        }
        guard let first = event(start) else { throw Failure.invalid("no plan entry event") }
        var successors = Array(repeating: [Int](), count: occurrences.count)
        for vertex in graph {
            guard let occurrence = vertex.occurrence else { continue }
            for edge in vertex.next {
                guard let target = event(edge) else { throw Failure.invalid("unproductive plan edge") }
                successors[occurrence].append(target)
            }
        }
        return ExpectedTransitions(entry: first, successors: successors)
    }

    private static func validLabel(_ label: String) -> Bool {
        let prefixes = ["exit_0x", "loop_0x", "cont_0x"]
        guard let prefix = prefixes.first(where: { label.hasPrefix($0) }) else { return false }
        let parts = label.dropFirst(prefix.count).split(separator: "_", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isHexDigit }) else { return false }
        if parts.count == 2 {
            guard let suffix = Int(parts[1]), suffix >= 2, String(suffix) == parts[1] else { return false }
        }
        return true
    }

    private static func isTerminal(_ text: String) -> Bool {
        text == "return;" || (text.hasPrefix("return ") && text.hasSuffix(";"))
            || (text.hasPrefix("__branch(") && text.hasSuffix(");"))
            || (text.hasPrefix("__branch_register(") && text.hasSuffix(");"))
            || (text.hasPrefix("goto ") && text.hasSuffix(";"))
    }

    private static func isRecoveryControl(_ text: String) -> Bool {
        text == "}" || text == "} else {" || text.hasPrefix("if (")
            || text.hasPrefix("break ") || text.hasPrefix("continue ")
            || text.hasSuffix(": {") || text.hasSuffix(": while (true) {")
    }

    /// Strip only an actual line comment. Quoted strings containing ` //`,
    /// braces, escaped quotes or parentheses remain part of the expression.
    private static func executableText(_ text: String) -> String {
        let characters = Array(text)
        var quote: Character?
        var escaped = false
        var end = characters.count
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let current = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                end = index
                break
            }
            index += 1
        }
        return String(characters[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func conditionAndBody(_ text: String) -> (condition: String, body: String)? {
        guard text.hasPrefix("if (") else { return nil }
        let characters = Array(text)
        var parentheses = 1
        var quote: Character?
        var escaped = false
        for index in 4..<characters.count {
            let character = characters[index]
            if let current = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                parentheses += 1
            } else if character == ")" {
                parentheses -= 1
                if parentheses == 0 {
                    let condition = String(characters[4..<index])
                    let body = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
                    return (condition, body)
                }
            }
        }
        return nil
    }
}
#endif

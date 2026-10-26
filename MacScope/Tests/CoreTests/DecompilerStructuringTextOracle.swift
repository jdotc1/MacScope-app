import Foundation
@testable import MacScope

/// Test-only oracle for the concrete recovery language, independent of its AST
/// and proof checker. Parses printed braces/labels into a flat branch program,
/// then checks its visible visit/decision/return transitions against the input
/// abstract graph. These synthetic payloads deliberately cannot be peephole-folded.
enum CP2TextOracle {
    enum Failure: Error { case invalid(String) }
    enum Operation {
        case visit(Int)
        case decision(Int, Int, Int) // source logical node, taken PC, false PC
        case jump(Int)
        case end
    }
    struct Program { var operations: [Operation]; var entry: Int }

    static func parse(_ document: PseudocodeDocument, edges: [[Int]]) throws -> Program {
        let starts = CP2GraphFixture.addresses(edges)
        let branchNode = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1 + 4, $0) })
        let lines = document.lines.filter { $0.kind == .instruction }
        var cursor = 0, code: [Operation] = []
        var breaks: [String: [Int]] = [:], continues: [String: Int] = [:]
        func text(_ i: Int) -> String { lines[i].text.components(separatedBy: " //")[0].trimmingCharacters(in: .whitespaces) }
        func parseBlock(_ depth: Int) throws {
            guard depth < 256 else { throw Failure.invalid("text nesting budget") }
            while cursor < lines.count {
                let line = lines[cursor], value = text(cursor)
                if value == "}" || value == "} else {" { return }
                cursor += 1
                if value.hasPrefix("exit_0x"), value.hasSuffix(": {") {
                    let label = String(value.dropLast(3))
                    guard breaks[label] == nil else { throw Failure.invalid("duplicate live break label") }
                    breaks[label] = []
                    try parseBlock(depth + 1)
                    guard cursor < lines.count, text(cursor) == "}" else { throw Failure.invalid("scope close") }
                    cursor += 1
                    for site in breaks.removeValue(forKey: label)! { code[site] = .jump(code.count) }
                } else if value.hasPrefix("loop_0x"), value.hasSuffix(": while (true) {") {
                    let label = String(value.dropLast(16))
                    guard continues[label] == nil else { throw Failure.invalid("duplicate live loop label") }
                    let start = code.count
                    continues[label] = start
                    try parseBlock(depth + 1)
                    guard cursor < lines.count, text(cursor) == "}" else { throw Failure.invalid("loop close") }
                    cursor += 1
                    code.append(.jump(start))
                    continues.removeValue(forKey: label)
                } else if value.hasPrefix("if (") {
                    guard let address = line.source?.address, let node = branchNode[address], edges[node].count == 2 else {
                        throw Failure.invalid("unknown branch source")
                    }
                    // Independently recognize the synthetic predicate. Reversing
                    // it also reverses the ordered branch projection below.
                    let forward = "if (x0_0 != 0x0) "
                    let reverse = "if (x0_0 == 0x0) "
                    let inverted: Bool
                    let body: String
                    if value.hasPrefix(forward) { inverted = false; body = String(value.dropFirst(forward.count)) }
                    else if value.hasPrefix(reverse) { inverted = true; body = String(value.dropFirst(reverse.count)) }
                    else { throw Failure.invalid("wrong branch predicate: \(value)") }
                    let site = code.count
                    code.append(.decision(node, -1, -1))
                    let takenStart = code.count
                    let elseStart: Int
                    if body == "{" {
                        try parseBlock(depth + 1)
                        guard cursor < lines.count else { throw Failure.invalid("if close") }
                        if text(cursor) == "} else {" {
                            cursor += 1
                            let skipElse = code.count
                            code.append(.jump(-1))
                            elseStart = code.count
                            try parseBlock(depth + 1)
                            guard cursor < lines.count, text(cursor) == "}" else { throw Failure.invalid("else close") }
                            cursor += 1
                            code[skipElse] = .jump(code.count)
                        } else {
                            guard text(cursor) == "}" else { throw Failure.invalid("if close") }
                            cursor += 1
                            elseStart = code.count
                        }
                    } else if body.hasPrefix("break "), body.hasSuffix(";") {
                        let label = String(body.dropFirst(6).dropLast())
                        guard breaks[label] != nil else { throw Failure.invalid("unbound compact break") }
                        breaks[label]!.append(code.count)
                        code.append(.jump(-1))
                        elseStart = code.count
                    } else if body.hasPrefix("continue "), body.hasSuffix(";") {
                        let label = String(body.dropFirst(9).dropLast())
                        guard let pc = continues[label] else { throw Failure.invalid("unbound compact continue") }
                        code.append(.jump(pc))
                        elseStart = code.count
                    } else { throw Failure.invalid("unknown compact branch body") }
                    code[site] = inverted ? .decision(node, elseStart, takenStart) : .decision(node, takenStart, elseStart)
                } else if value.hasPrefix("break ") {
                    let label = String(value.dropFirst(6).dropLast())
                    guard value.hasSuffix(";"), breaks[label] != nil else { throw Failure.invalid("unbound break \(label)") }
                    breaks[label]!.append(code.count)
                    code.append(.jump(-1))
                } else if value.hasPrefix("continue ") {
                    let label = String(value.dropFirst(9).dropLast())
                    guard value.hasSuffix(";"), let pc = continues[label] else { throw Failure.invalid("unbound continue \(label)") }
                    code.append(.jump(pc))
                } else if let comment = line.source?.comment, comment.hasPrefix("visit_"),
                          let node = Int(comment.dropFirst(6)), edges.indices.contains(node) {
                    guard line.source?.address == starts[node],
                          value == "x20_\(node + 1) = 0x\(String(node, radix: 16));" else {
                        throw Failure.invalid("changed or missing visit payload: \(value)")
                    }
                    code.append(.visit(node))
                } else if value == "return;" {
                    code.append(.end)
                } else {
                    throw Failure.invalid("unknown executable line: \(value)")
                }
            }
        }
        try parseBlock(0)
        guard cursor == lines.count else { throw Failure.invalid("unmatched close") }
        code.append(.end) // falling out is visible, never silently dropped
        return Program(operations: code, entry: 0)
    }

    static func equivalent(_ document: PseudocodeDocument, edges: [[Int]]) -> Bool {
        guard let program = try? parse(document, edges: edges) else { return false }
        let code = program.operations
        func nextObservable(_ start: Int) -> Int? {
            var cursor = start, seen = Set<Int>()
            while code.indices.contains(cursor), seen.insert(cursor).inserted {
                if case .jump(let target) = code[cursor] { cursor = target } else { return cursor }
            }
            return nil // an unproductive epsilon loop changes termination
        }
        guard let first = nextObservable(program.entry), case .visit(0) = code[first] else { return false }
        var pending = [first], visited = Set<Int>()
        while let site = pending.popLast() {
            guard visited.insert(site).inserted else { continue }
            guard case .visit(let node) = code[site], edges.indices.contains(node),
                  let next = nextObservable(site + 1) else { return false }
            let successors = edges[node]
            var targets: [Int] = []
            switch successors.count {
            case 0:
                guard case .end = code[next] else { return false }
            case 1:
                targets = [next]
            case 2:
                guard case .decision(let original, let taken, let fallthroughPC) = code[next], original == node,
                      let a = nextObservable(taken), let b = nextObservable(fallthroughPC) else { return false }
                targets = [a, b]
            default: return false
            }
            for (target, expected) in zip(targets, successors) {
                guard case .visit(let actual) = code[target], actual == expected else { return false }
                pending.append(target)
            }
        }
        let allVisits = Set(code.indices.filter { if case .visit = code[$0] { return true }; return false })
        return visited == allVisits
    }
}

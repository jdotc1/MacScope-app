import Foundation

/// Renders a once-owned topology over the original graph. Edge copies keep
/// their synthetic identities; every visible transfer belongs to its original
/// predecessor, and no projected copy block becomes a control-flow label.
struct PseudocodeSSARecoveryEmitter {
    struct Fragment {
        var text: String
        var kind: PseudocodeLineKind
        var source: MacIRSourceSpan?
    }
    struct Emission {
        var fragments: [Fragment]
        var region: PseudocodeRegionNode
    }
    struct Rendering {
        var block: (Int, Int, Set<Int>) -> [PseudocodeLine]?
        var value: (MacIRValue) -> String
        var condition: (MacIROperation, Bool) -> String?
        var copy: (MacIRInstruction) -> String
        var comment: (MacIRInstruction) -> String
        var cancelled: () -> Bool
    }

    static func diagnose(function: MacIRFunction, stage: String, reason: String) {
        guard RegionTree.diagnosticsEnabled else { return }
        let text = "SSA_RECOVERY_DIAGNOSTICS\tfunction=\(function.name)\tstage=\(stage)\treason=\(reason)\n"
        if let data = text.data(using: .utf8) { FileHandle.standardError.write(data) }
    }

    static func emit(function: MacIRFunction, cfg: CFG, plan: RegionTree.RecoveryRegion,
                     copies: [CFGEdge: [MacIRInstruction]], depth: Int, lineOffset: Int,
                     rendering: Rendering) -> Emission? {
        var writer = Writer(function: function, cfg: cfg, copies: copies,
                            baseDepth: depth, lineOffset: lineOffset, rendering: rendering)
        guard writer.collectLabels(plan, next: nil, loops: [], depth: 0) else {
            diagnose(function: function, stage: "labels", reason: "node-or-depth-budget")
            return nil
        }
        guard let region = writer.emit(plan, depth: depth, next: nil, loops: [], origin: nil),
              !writer.failed else {
            diagnose(function: function, stage: "emission", reason: writer.failureReason ?? "empty-root")
            return nil
        }
        guard writer.blocks == Set(cfg.blocks.indices) else {
            diagnose(function: function, stage: "coverage", reason: "blocks=\(writer.blocks.count)/\(cfg.blocks.count)")
            return nil
        }
        let expectedEdges = Set(cfg.blocks.flatMap { block in block.successors.map { CFGEdge(block.index, $0) } })
        guard Set(writer.edges.keys) == expectedEdges, writer.edges.values.allSatisfy({ $0 == 1 }) else {
            diagnose(function: function, stage: "coverage", reason: "edges=\(writer.edges.count)/\(expectedEdges.count)")
            return nil
        }
        guard writer.labels == writer.targets, !rendering.cancelled() else {
            diagnose(function: function, stage: "coverage", reason: "labels=\(writer.labels.count)/\(writer.targets.count);cancelled=\(rendering.cancelled())")
            return nil
        }
        diagnose(function: function, stage: "accepted", reason: "blocks=\(writer.blocks.count);edges=\(writer.edges.count)")
        return .init(fragments: writer.fragments, region: region)
    }

    private struct Loop {
        var header: Int
        var exit: Int?
    }
    private struct Writer {
        let function: MacIRFunction
        let cfg: CFG
        let copies: [CFGEdge: [MacIRInstruction]]
        let baseDepth: Int
        let lineOffset: Int
        let rendering: Rendering
        var fragments: [Fragment] = []
        var blocks: Set<Int> = []
        var edges: [CFGEdge: Int] = [:]
        var targets: Set<Int> = []
        var labels: Set<Int> = []
        var budget = 8192
        var failed = false
        var failureReason: String?

        mutating func fail(_ reason: String) {
            if !failed { failureReason = reason }
            failed = true
        }

        func first(_ node: RegionTree.RecoveryRegion, next: Int?) -> Int? {
            switch node {
            case let .sequence(parts):
                for part in parts { if let block = first(part, next: nil) { return block } }
                return next
            case let .block(block, _), let .loop(block, _): return block
            case let .scope(_, body): return first(body, next: next)
            case let .breakTo(target), let .continueAt(target): return target
            }
        }
        func successorIndices(_ parts: [RegionTree.RecoveryRegion], next: Int?) -> [Int?] {
            var result = Array<Int?>(repeating: nil, count: parts.count), cursor = next
            for index in parts.indices.reversed() {
                result[index] = cursor
                cursor = first(parts[index], next: cursor)
            }
            return result
        }
        mutating func collectLabels(_ node: RegionTree.RecoveryRegion, next: Int?,
                                    loops: [Loop], depth: Int) -> Bool {
            budget -= 1
            guard budget >= 0, depth <= 128 else { return false }
            switch node {
            case let .sequence(parts):
                let successors = successorIndices(parts, next: next)
                for index in parts.indices {
                    guard collectLabels(parts[index], next: successors[index], loops: loops, depth: depth + 1) else { return false }
                }
            case let .scope(target, body):
                return collectLabels(body, next: target, loops: loops, depth: depth + 1)
            case let .loop(header, body):
                return collectLabels(body, next: header, loops: loops + [Loop(header: header, exit: next)], depth: depth + 1)
            case let .block(_, exits):
                for exit in exits {
                    guard collectLabels(exit, next: next, loops: loops, depth: depth + 1) else { return false }
                }
            case let .breakTo(target):
                if loops.last?.exit != target { targets.insert(target) }
            case let .continueAt(header):
                if loops.last?.header != header { targets.insert(header) }
            }
            return true
        }
        func indent(_ depth: Int) -> String { String(repeating: "    ", count: depth + 1) }
        func label(_ block: Int) -> String {
            "L_" + String(function.instructions[cfg.blocks[block].startIndex].source.address, radix: 16)
        }
        mutating func append(_ text: String, kind: PseudocodeLineKind = .instruction,
                             source: MacIRSourceSpan? = nil) {
            guard fragments.count < 100_000, !rendering.cancelled() else { fail("fragment-budget-or-cancellation"); return }
            fragments.append(.init(text: text, kind: kind, source: source))
        }
        func empty(_ node: RegionTree.RecoveryRegion) -> Bool {
            if case let .sequence(parts) = node { return parts.allSatisfy(empty) }
            return false
        }
        func emptyExit(_ node: RegionTree.RecoveryRegion, from: Int, ordinal: Int) -> Bool {
            copies[CFGEdge(from, cfg.blocks[from].successors[ordinal]), default: []].isEmpty && empty(node)
        }
        func exitsInnermostLoop(_ node: RegionTree.RecoveryRegion, loops: [Loop]) -> Bool {
            if case let .breakTo(target) = node { return loops.last?.exit == target }
            if case let .sequence(parts) = node, parts.count == 1 {
                return exitsInnermostLoop(parts[0], loops: loops)
            }
            return false
        }
        mutating func edge(_ node: RegionTree.RecoveryRegion, from: Int, ordinal: Int,
                           depth: Int, next: Int?, loops: [Loop]) -> PseudocodeRegionNode? {
            let key = CFGEdge(from, cfg.blocks[from].successors[ordinal])
            edges[key, default: 0] += 1
            guard edges[key] == 1 else { fail("duplicate-edge:\(from)->\(key.to)"); return nil }
            let start = lineOffset + fragments.count + 1
            for copy in copies[key, default: []] {
                guard copy.source.syntheticPhiEdge != nil else { fail("copy-source:\(from)->\(key.to)"); return nil }
                append("\(indent(depth))\(rendering.copy(copy));", source: copy.source)
            }
            let child = emit(node, depth: depth, next: next, loops: loops, origin: from)
            guard lineOffset + fragments.count >= start else { return nil }
            return .init(kind: .sequence, startLine: start, endLine: lineOffset + fragments.count,
                         children: child.map { [$0] } ?? [])
        }
        mutating func emit(_ node: RegionTree.RecoveryRegion, depth: Int, next: Int?,
                           loops: [Loop], origin: Int?) -> PseudocodeRegionNode? {
            budget -= 1
            guard !failed, budget >= 0, depth - baseDepth <= 128, !rendering.cancelled() else {
                fail("node-depth-budget-or-cancellation:\(depth - baseDepth)"); return nil
            }
            let start = lineOffset + fragments.count + 1
            var kind: PseudocodeRegionNode.Kind = .sequence
            var children: [PseudocodeRegionNode] = []
            var condition: String?, conditionSource: UInt64?
            switch node {
            case let .sequence(parts):
                let successors = successorIndices(parts, next: next)
                for index in parts.indices {
                    if let child = emit(parts[index], depth: depth, next: successors[index], loops: loops, origin: origin) { children.append(child) }
                }
            case let .scope(target, body):
                if let child = emit(body, depth: depth, next: target, loops: loops, origin: origin) { children.append(child) }
            case let .loop(header, body):
                kind = .whileLoop; condition = "true"
                append("\(indent(depth))while (true) {")
                if let child = emit(body, depth: depth + 1, next: header,
                                    loops: loops + [Loop(header: header, exit: next)], origin: nil) { children.append(child) }
                append("\(indent(depth))}")
            case let .breakTo(target), let .continueAt(target):
                guard let origin, cfg.blocks[origin].successors.contains(target) else { fail("transfer-not-successor:\(origin.map(String.init) ?? "nil")->\(target)"); return nil }
                let terminal = function.instructions[cfg.blocks[origin].endIndex - 1]
                guard terminal.source.syntheticPhiEdge == nil else { fail("synthetic-transfer:\(origin)->\(target)"); return nil }
                switch CFGBuilder.terminatorKind(of: terminal.operation) {
                case .conditionalBranch, .unconditionalBranch, .switchDispatch: break
                default:
                    fail("transfer-without-terminator:\(origin)->\(target);pc=\(String(terminal.source.address, radix: 16));mnemonic=\(terminal.source.mnemonic)")
                    return nil
                }
                let transfer: String
                if case .breakTo = node, loops.last?.exit == target { transfer = "break" }
                else if case .continueAt = node, loops.last?.header == target { transfer = "continue" }
                else { transfer = "goto \(label(target))" }
                append("\(indent(depth))\(transfer);", source: terminal.source)
            case let .block(index, exits):
                return emitBlock(index, exits: exits, depth: depth, next: next, loops: loops)
            }
            guard lineOffset + fragments.count >= start else { return nil }
            return .init(kind: kind, startLine: start, endLine: lineOffset + fragments.count,
                         condition: condition, conditionSourceAddress: conditionSource, children: children)
        }
        /// An else arm that is exactly one nested conditional is one `else if`.
        /// The region tree proves the arm owns nothing else: its single node
        /// starts at the arm's first line and ends at its last, which closes
        /// that conditional. Only indentation and the removed lines change.
        mutating func flattenedElseIf(_ arm: PseudocodeRegionNode, armStart: Int, depth: Int) -> PseudocodeRegionNode? {
            var node = arm
            while node.kind == .sequence, node.children.count == 1, node.startLine == arm.startLine,
                  node.endLine == arm.endLine { node = node.children[0] }
            guard node.kind == .ifThen || node.kind == .ifThenElse,
                  node.startLine == lineOffset + armStart + 1, node.endLine == lineOffset + fragments.count,
                  armStart >= 1, fragments.count - armStart >= 2,
                  fragments[armStart - 1].text == "\(indent(depth))} else {",
                  fragments[armStart].text.hasPrefix("\(indent(depth + 1))if ("),
                  fragments[fragments.count - 1].text == "\(indent(depth + 1))}" else { return nil }
            let step = "    "
            guard fragments[armStart...].allSatisfy({ $0.text.hasPrefix(step) }) else { return nil }
            for position in armStart..<fragments.count { fragments[position].text.removeFirst(step.count) }
            fragments[armStart].text = "\(indent(depth))} else " + String(fragments[armStart].text.dropFirst(indent(depth).count))
            fragments.remove(at: armStart - 1)
            return Self.shifted(arm, by: -1)
        }
        static func shifted(_ node: PseudocodeRegionNode, by delta: Int) -> PseudocodeRegionNode {
            var result = node
            result.startLine += delta; result.endLine += delta
            result.children = node.children.map { shifted($0, by: delta) }
            return result
        }
        mutating func emitBlock(_ index: Int, exits: [RegionTree.RecoveryRegion], depth: Int,
                                next: Int?, loops: [Loop]) -> PseudocodeRegionNode? {
            let start = lineOffset + fragments.count + 1
            var kind: PseudocodeRegionNode.Kind = .block
            var children: [PseudocodeRegionNode] = []
            var condition: String?, conditionSource: UInt64?
            guard blocks.insert(index).inserted, exits.count == cfg.blocks[index].successors.count else { fail("block-ownership-or-exits:\(index)"); return nil }
            kind = .block
            let block = cfg.blocks[index], last = block.endIndex - 1
            let terminal = function.instructions[last]
            let terminator = CFGBuilder.terminatorKind(of: terminal.operation)
            var suppressed: Set<Int> = []
            switch terminator {
            case .conditionalBranch, .switchDispatch, .unconditionalBranch: suppressed.insert(last)
            default: break
            }
            if targets.contains(index) {
                guard labels.insert(index).inserted else { fail("duplicate-label:\(index)"); return nil }
                append("\(indent(depth))\(label(index)):",
                       source: function.instructions[block.startIndex].source)
            }
            guard let payload = rendering.block(index, depth, suppressed) else { fail("block-payload:\(index)"); return nil }
            for line in payload { append(line.text, kind: line.kind, source: line.source) }
            let hasTransferStatement: Bool
            if let exit = exits.first, exits.count == 1 {
                switch exit {
                case .breakTo, .continueAt: hasTransferStatement = true
                default: hasTransferStatement = false
                }
            } else { hasTransferStatement = false }
            if payload.isEmpty, targets.contains(index), exits.count <= 1, !hasTransferStatement {
                // An otherwise suppressed one-row branch remains an exact
                // original statement boundary before its edge-only copies.
                // A following explicit transfer already supplies that boundary
                // and the label's required C statement.
                append("\(indent(depth));", source: terminal.source)
            }
            switch terminal.operation {
            case .conditionalBranch:
                guard exits.count == 2, let forward = rendering.condition(terminal.operation, false) else { fail("conditional-predicate:\(index)"); return nil }
                let inverse = rendering.condition(terminal.operation, true)
                let preferExit = exitsInnermostLoop(exits[1], loops: loops)
                    && !exitsInnermostLoop(exits[0], loops: loops)
                // A jump-table bounds guard reads as the in-range test owning the
                // dispatch, with the default route as its else arm.
                func entersDispatch(_ ordinal: Int) -> Bool {
                    let successor = cfg.blocks[cfg.blocks[index].successors[ordinal]]
                    if case .switchDispatch = CFGBuilder.terminatorKind(of: function.instructions[successor.endIndex - 1].operation) { return true }
                    return false
                }
                // Two arms that rejoin without a transfer keep the original code
                // order: the fall-through arm is written first.
                func fallThroughDiamond() -> Bool {
                    let successors = cfg.blocks[index].successors
                    guard successors.count == 2 else { return false }
                    let taken = cfg.blocks[successors[0]], fall = cfg.blocks[successors[1]]
                    return fall.startIndex == cfg.blocks[index].endIndex
                        && taken.successors.count == 1 && taken.successors == fall.successors
                }
                let flip = inverse != nil && (preferExit
                    || (entersDispatch(1) && !entersDispatch(0))
                    || fallThroughDiamond()
                    || (emptyExit(exits[0], from: index, ordinal: 0)
                        && !emptyExit(exits[1], from: index, ordinal: 1)))
                let taken = flip ? 1 : 0, other = 1 - taken
                let text = flip ? (inverse ?? forward) : forward
                condition = text; conditionSource = terminal.source.address
                let hasOther = !emptyExit(exits[other], from: index, ordinal: other)
                kind = hasOther ? .ifThenElse : .ifThen
                append("\(indent(depth))if (\(text)) {\(rendering.comment(terminal))", source: terminal.source)
                if let child = edge(exits[taken], from: index, ordinal: taken, depth: depth + 1, next: next, loops: loops) { children.append(child) }
                if hasOther { append("\(indent(depth))} else {") }
                let armStart = fragments.count
                let otherChild = edge(exits[other], from: index, ordinal: other,
                                      depth: depth + 1, next: next, loops: loops)
                if hasOther, let otherChild, let flat = flattenedElseIf(otherChild, armStart: armStart, depth: depth) {
                    children.append(flat)
                } else {
                    if let otherChild { children.append(otherChild) }
                    append("\(indent(depth))}")
                }
            case let .switchDispatch(selector, cases, defaultTarget):
                var ordinals: [UInt64: Int] = [:]
                for (ordinal, target) in block.successors.enumerated() {
                    ordinals[function.instructions[cfg.blocks[target].startIndex].source.address] = ordinal
                }
                guard let defaultTarget, let defaultAddress = CFGBuilder.address(of: defaultTarget),
                      cfg.blocks.contains(where: {
                          function.instructions[$0.startIndex].source.address == defaultAddress
                      }) else { fail("switch-default:\(index)"); return nil }
                var groups: [(ordinal: Int, values: [Int64])] = []
                for item in cases {
                    guard let address = CFGBuilder.address(of: item.target), let ordinal = ordinals[address] else { fail("switch-case:\(index):\(item.value)"); return nil }
                    if let group = groups.firstIndex(where: { $0.ordinal == ordinal }) { groups[group].values.append(item.value) }
                    else { groups.append((ordinal, [item.value])) }
                }
                kind = .ifThenElse; conditionSource = terminal.source.address
                // The bounds guard compares the selector as unsigned; each case
                // test does too, so a signed difference cannot change a case.
                let coversGuardedDomain = Set(cases.map(\.value)) == Set((0..<Int64(cases.count)).map { $0 })
                var selectorText = rendering.value(selector)
                if case let .register(name, _) = selector {
                    selectorText = "\(name.lowercased().hasPrefix("w") ? "(uint32_t)" : "(uint64_t)")(\(selectorText))"
                }
                for (position, group) in groups.enumerated() {
                    let text = group.values.map { "(\(selectorText)) == (\(rendering.value(.immediate($0))))" }.joined(separator: " || ")
                    if position == 0 { condition = text }
                    // Cases 0..<n are all of the guarded domain, so the last
                    // arm needs no test and no unmatched route leaves the chain.
                    if position > 0, position == groups.count - 1, coversGuardedDomain {
                        append("\(indent(depth))} else {", source: terminal.source)
                    } else {
                        let prefix = position == 0 ? "if" : "} else if"
                        append("\(indent(depth))\(prefix) (\(text)) {\(position == 0 ? rendering.comment(terminal) : "")", source: terminal.source)
                    }
                    if let child = edge(exits[group.ordinal], from: index, ordinal: group.ordinal,
                                        depth: depth + 1, next: next, loops: loops) { children.append(child) }
                }
                // The bounds guard already owns the default route. Only
                // enumerated table cases leave this machine dispatch block.
                if !groups.isEmpty { append("\(indent(depth))}") }
            default:
                guard exits.count <= 1 else { fail("nonconditional-exits:\(index)"); return nil }
                if let exit = exits.first,
                   let child = edge(exit, from: index, ordinal: 0, depth: depth, next: next, loops: loops) { children.append(child) }
            }
            guard lineOffset + fragments.count >= start else { return nil }
            return .init(kind: kind, startLine: start, endLine: lineOffset + fragments.count,
                         condition: condition, conditionSourceAddress: conditionSource, children: children)
        }

    }
}

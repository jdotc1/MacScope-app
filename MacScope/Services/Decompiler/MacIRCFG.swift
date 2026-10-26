import Foundation

// Keep comparison support beside the new representation; the legacy builder
// and its computations remain unchanged while both paths coexist.
extension CFG: Equatable {
    static func == (lhs: CFG, rhs: CFG) -> Bool {
        lhs.entryIndex == rhs.entryIndex && lhs.domTree == rhs.domTree &&
        lhs.postDomTree == rhs.postDomTree && lhs.loopHeaders == rhs.loopHeaders &&
        lhs.backEdges == rhs.backEdges && lhs.irreducibleBlocks == rhs.irreducibleBlocks &&
        lhs.blockByStartIndex == rhs.blockByStartIndex &&
        lhs.hasUnresolvedTargets == rhs.hasUnresolvedTargets &&
        lhs.blocks.count == rhs.blocks.count && zip(lhs.blocks, rhs.blocks).allSatisfy { a, b in
            a.index == b.index && a.startIndex == b.startIndex && a.endIndex == b.endIndex &&
            a.successors == b.successors && a.predecessors == b.predecessors &&
            a.isLoopHeader == b.isLoopHeader
        }
    }
}

// Graph algorithms are shared with the transitional structuring adapter.
enum MacIRCFGAlgorithms {
    // MARK: - Dominators

    /// Cooper-Harvey-Kennedy iterative dominators over reverse-post-order.
    static func computeDominators(blocks: [BasicBlock], entryIndex: Int, cancelled: () -> Bool = { false }) -> [Int: Int] {
        guard !blocks.isEmpty else { return [:] }
        let order = reversePostOrder(blocks: blocks, entryIndex: entryIndex)
        var postOrderNumber = [Int](repeating: -1, count: blocks.count)
        // post-order number: reverse of reverse-post-order.
        let postOrder = Array(order.reversed())
        for (number, block) in postOrder.enumerated() {
            postOrderNumber[block] = number
        }

        var idom = [Int](repeating: -1, count: blocks.count)
        idom[entryIndex] = entryIndex

        func intersect(_ first: Int, _ second: Int) -> Int {
            var a = first
            var b = second
            while a != b {
                while postOrderNumber[a] < postOrderNumber[b] { a = idom[a] }
                while postOrderNumber[b] < postOrderNumber[a] { b = idom[b] }
            }
            return a
        }

        var changed = true
        while changed {
            if cancelled() { return [:] }
            changed = false
            for block in order where block != entryIndex {
                let preds = blocks[block].predecessors.filter { idom[$0] != -1 }
                guard var newIdom = preds.first else { continue }
                for pred in preds.dropFirst() {
                    newIdom = intersect(pred, newIdom)
                }
                if idom[block] != newIdom {
                    idom[block] = newIdom
                    changed = true
                }
            }
        }

        var result: [Int: Int] = [:]
        for block in blocks.indices where idom[block] != -1 {
            result[block] = idom[block]
        }
        return result
    }

    /// Post-dominators via the same iterative algorithm on the reversed CFG.
    /// Exit blocks (no successors, or whose terminator returns / leaves the
    /// graph) flow to a synthetic exit node which is the post-dominator root.
    static func computePostDominators(blocks: [BasicBlock], exitingBlocks: Set<Int> = [], cancelled: () -> Bool = { false }) -> [Int: Int] {
        guard !blocks.isEmpty else { return [:] }
        let exitNode = blocks.count // synthetic

        // Reversed successors. Synthetic exit has the real exits as predecessors
        // in the reversed graph (i.e. exit -> realExit edges).
        var reverseSuccessors = [[Int]](repeating: [], count: blocks.count + 1)
        var reversePredecessors = [[Int]](repeating: [], count: blocks.count + 1)

        func isExitBlock(_ block: BasicBlock) -> Bool {
            block.successors.isEmpty || exitingBlocks.contains(block.index)
        }

        for block in blocks {
            for succ in block.successors {
                // Reversed: succ -> block.
                reverseSuccessors[succ].append(block.index)
                reversePredecessors[block.index].append(succ)
            }
            if isExitBlock(block) {
                reverseSuccessors[exitNode].append(block.index)
                reversePredecessors[block.index].append(exitNode)
            }
        }

        let total = blocks.count + 1
        // Reverse-post-order from exitNode over reverseSuccessors.
        var visited = [Bool](repeating: false, count: total)
        var order: [Int] = []
        func dfs(_ start: Int) {
            var stack: [(node: Int, childIndex: Int)] = [(start, 0)]
            visited[start] = true
            while let top = stack.last {
                if top.childIndex < reverseSuccessors[top.node].count {
                    stack[stack.count - 1].childIndex += 1
                    let next = reverseSuccessors[top.node][top.childIndex]
                    if !visited[next] {
                        visited[next] = true
                        stack.append((next, 0))
                    }
                } else {
                    order.append(top.node)
                    stack.removeLast()
                }
            }
        }
        dfs(exitNode)
        let rpo = Array(order.reversed())

        var postOrderNumber = [Int](repeating: -1, count: total)
        for (number, node) in order.enumerated() {
            postOrderNumber[node] = number
        }

        var ipdom = [Int](repeating: -1, count: total)
        ipdom[exitNode] = exitNode

        func intersect(_ first: Int, _ second: Int) -> Int {
            var a = first
            var b = second
            while a != b {
                while postOrderNumber[a] < postOrderNumber[b] { a = ipdom[a] }
                while postOrderNumber[b] < postOrderNumber[a] { b = ipdom[b] }
            }
            return a
        }

        var changed = true
        while changed {
            if cancelled() { return [:] }
            changed = false
            for node in rpo where node != exitNode {
                let preds = reversePredecessors[node].filter { ipdom[$0] != -1 }
                guard var newIpdom = preds.first else { continue }
                for pred in preds.dropFirst() {
                    newIpdom = intersect(pred, newIpdom)
                }
                if ipdom[node] != newIpdom {
                    ipdom[node] = newIpdom
                    changed = true
                }
            }
        }

        var result: [Int: Int] = [:]
        for block in blocks.indices where ipdom[block] != -1 {
            result[block] = ipdom[block]
        }
        return result
    }

    /// Reverse-post-order over forward successors from the entry.
    static func reversePostOrder(blocks: [BasicBlock], entryIndex: Int) -> [Int] {
        var visited = [Bool](repeating: false, count: blocks.count)
        var order: [Int] = []
        var stack: [(node: Int, childIndex: Int)] = [(entryIndex, 0)]
        visited[entryIndex] = true
        while let top = stack.last {
            if top.childIndex < blocks[top.node].successors.count {
                stack[stack.count - 1].childIndex += 1
                let next = blocks[top.node].successors[top.childIndex]
                if !visited[next] {
                    visited[next] = true
                    stack.append((next, 0))
                }
            } else {
                order.append(top.node)
                stack.removeLast()
            }
        }
        return Array(order.reversed())
    }

    /// True iff `a` dominates `b` (walking idom chain from `b` up to entry).
    static func dominates(_ a: Int, _ b: Int, domTree: [Int: Int]) -> Bool {
        var current = b
        while true {
            if current == a { return true }
            guard let parent = domTree[current], parent != current else { return false }
            current = parent
        }
    }

    /// True iff `a` post-dominates `b`.
    static func postDominates(_ a: Int, _ b: Int, postDomTree: [Int: Int]) -> Bool {
        var current = b
        while true {
            if current == a { return true }
            guard let parent = postDomTree[current], parent != current else { return false }
            current = parent
        }
    }

    // MARK: - Irreducibility

    /// Blocks that participate in a cycle of the residual graph (forward edges
    /// minus back-edges). A reducible CFG's residual graph is a DAG; any
    /// residual cycle (including a residual self-loop) is irreducible.
    static func irreducibleBlocks(blocks: [BasicBlock], backEdges: Set<CFGEdge>) -> Set<Int> {
        guard !blocks.isEmpty else { return [] }
        // Build residual adjacency.
        var adjacency = [[Int]](repeating: [], count: blocks.count)
        for block in blocks {
            for succ in block.successors where !backEdges.contains(CFGEdge(block.index, succ)) {
                adjacency[block.index].append(succ)
            }
        }

        // Tarjan SCC.
        var index = 0
        var indices = [Int](repeating: -1, count: blocks.count)
        var lowlink = [Int](repeating: 0, count: blocks.count)
        var onStack = [Bool](repeating: false, count: blocks.count)
        var stack: [Int] = []
        var result: Set<Int> = []

        func strongConnect(_ root: Int) {
            // Iterative Tarjan.
            var work: [(node: Int, childIndex: Int)] = [(root, 0)]
            indices[root] = index
            lowlink[root] = index
            index += 1
            stack.append(root)
            onStack[root] = true

            while let top = work.last {
                let node = top.node
                if top.childIndex < adjacency[node].count {
                    work[work.count - 1].childIndex += 1
                    let next = adjacency[node][top.childIndex]
                    if indices[next] == -1 {
                        indices[next] = index
                        lowlink[next] = index
                        index += 1
                        stack.append(next)
                        onStack[next] = true
                        work.append((next, 0))
                    } else if onStack[next] {
                        lowlink[node] = min(lowlink[node], indices[next])
                    }
                } else {
                    if lowlink[node] == indices[node] {
                        var component: [Int] = []
                        while let popped = stack.popLast() {
                            onStack[popped] = false
                            component.append(popped)
                            if popped == node { break }
                        }
                        if component.count > 1 {
                            result.formUnion(component)
                        } else if let single = component.first,
                                  adjacency[single].contains(single) {
                            // Residual self-loop.
                            result.insert(single)
                        }
                    }
                    work.removeLast()
                    if let parent = work.last?.node {
                        lowlink[parent] = min(lowlink[parent], lowlink[node])
                    }
                }
            }
        }

        for block in blocks.indices where indices[block] == -1 {
            strongConnect(block)
        }
        return result
    }}

public struct MacIRBlock: Hashable, Sendable {
    public var index: Int
    public var startAddress: UInt64
    public var instructionRange: Range<Int>
    public var successors: [MacIREdge]
    public var predecessors: [Int]
    public var loopHeaderOf: Int?
}

public struct MacIREdge: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case `fallthrough`, branch, jumpTable, callReturn, noReturn, tail, exit
    }
    public var from: Int
    public var to: Int?
    public var kind: Kind
    public var label: Int?
}

public struct MacIRLoop: Hashable, Sendable {
    public var id: Int
    public var header: Int
    public var latches: [Int]
    public var body: [Int]
    public var isIrreducible: Bool
}

public struct MacIRRefusal: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable, CaseIterable {
        case unresolvedIndirectBranch, targetOutsideFunction, jumpTableOutsideFunction, undecodableRow, unknownEffects
        case irreducibleLoop, unreachableBlock, stackPointerOpaque, vectorRegionRefused
        case rowBudgetExceeded, cancelled
    }
    public enum Scope: Hashable, Sendable {
        case function, block(Int), row(UInt64), cell(Int, UInt64)
    }
    public var reason: Reason
    public var scope: Scope
    public var detail: String?
}

/// Architectural transfers, independent of the printer's historical control model.
public enum MacIRTerminator: Hashable, Sendable {
    case none
    case conditional(target: UInt64?)
    case unconditional(target: UInt64?)
    case indirect(table: [UInt64]?)
    case call(target: String, returns: Bool)
    case callRegister(returns: Bool)
    case ret
    case tail(target: UInt64)
    case undecodable

    static func classify(
        row: MacIRSourceSpan,
        functionRange: Range<UInt64>?,
        jumpTables: [UInt64: [UInt64]],
        knownTailCallTargets: [UInt64: String],
        provenTailCallTargets: [UInt64: UInt64] = [:],
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride]
    ) -> MacIRTerminator {
        let mnemonic = row.mnemonic.lowercased()
        let operands = MacIRBuilder.splitOperands(row.operands)
        func address() -> UInt64? {
            if let envelope = row.structuredOperands, envelope.coverage == .complete,
               let last = envelope.operands.last, case let .pcRelative(reference) = last {
                return reference.target
            }
            guard let text = operands.last?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let value = text.lowercased()
            return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
        }
        if mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.") ||
            ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) {
            return .conditional(target: address())
        }
        // Identity alone does not certify the frame at this branch site.
        if mnemonic == "b" {
            if let target = address(), functionRange?.contains(target) != true,
               knownTailCallTargets[target] != nil, provenTailCallTargets[row.address] == target {
                return .tail(target: target)
            }
            return .unconditional(target: address())
        }
        if mnemonic == "br" || mnemonic.hasPrefix("braa") || mnemonic.hasPrefix("brab") {
            return .indirect(table: jumpTables[row.address])
        }
        if mnemonic == "bl" {
            let target = operands.first ?? ""
            let returns: Bool
            switch authoredCallSignaturesByTarget[target]?.noReturnState {
            case .noReturn?: returns = false
            case .returns?: returns = true
            default:
                returns = !(NoReturnCatalog.isNoReturn(target) ||
                    CallSignaturePack.bundledNoReturnCanonicalNames.contains(
                        NoReturnCatalog.canonicalName(for: target)))
            }
            return .call(target: target, returns: returns)
        }
        if mnemonic == "blr" || mnemonic.hasPrefix("blraa") || mnemonic.hasPrefix("blrab") {
            return .callRegister(returns: true)
        }
        if ["ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr",
            "eret", "eretaa", "eretab", "svc", "hvc", "smc", "hlt", "brk", "udf"].contains(mnemonic) {
            return .ret
        }
        if mnemonic.isEmpty || [".word", ".long", ".byte", ".inst"].contains(mnemonic) {
            return .undecodable
        }
        return .none
    }

    var splitsBlock: Bool {
        switch self {
        case .none, .undecodable, .call(_, returns: true), .callRegister(returns: true): return false
        default: return true
        }
    }

    var targetAddresses: [UInt64] {
        switch self {
        case let .conditional(target), let .unconditional(target): return target.map { [$0] } ?? []
        case let .indirect(table): return table ?? []
        default: return []
        }
    }
}

/// Derived, in-memory control flow. The compatibility view retains the existing
/// structurer's topology while richer architectural transfers remain available
/// to analysis. In particular, traps and unresolved exits must not silently
/// change the current renderer's admission rules.
public struct MacIRCFG: Hashable, Sendable {
    public var blocks: [MacIRBlock]
    public var entry: Int
    /// -1 denotes an unreachable block with no immediate dominator.
    public var idom: [Int]
    /// Nil denotes the synthetic exit or absence of a postdominator.
    public var ipostdom: [Int?]
    /// Distinguishes a synthetic-exit postdominator from no path to an exit.
    public var hasPostdominator: [Bool]
    public var dominanceFrontier: [[Int]]
    public var loops: [MacIRLoop]
    public var unreachable: [Int]
    public var refusals: [MacIRRefusal]
    public var terminators: [MacIRTerminator]
    let compatibilityCFG: CFG

    // Hash only structural counts and refusals. Equality remains structural;
    // collisions never establish equality or replace graph comparisons.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(blocks.count)
        hasher.combine(edgeCount)
        hasher.combine(refusals)
    }
    private let edgeCount: Int

    /// Compare only facts that determine architectural or compatibility edges.
    /// Value repairs may change branch predicates, but never their destinations.
    static func hasSameTopology(_ old: [MacIRInstruction], _ new: [MacIRInstruction]) -> Bool {
        guard old.count == new.count else { return false }
        for (before, after) in zip(old, new) {
            if before == after { continue }
            guard before.source.address == after.source.address,
                  CFGBuilder.terminatorKind(of: before.operation) ==
                    CFGBuilder.terminatorKind(of: after.operation) else { return false }
            switch (before.operation, after.operation) {
            case let (.conditionalBranch(_, _, _, a), .conditionalBranch(_, _, _, b)):
                guard a == b else { return false }
            case let (.switchDispatch(_, a, aDefault), .switchDispatch(_, b, bDefault)):
                guard a == b, aDefault == bDefault else { return false }
            case let (.intrinsic(_, aName, aArguments), .intrinsic(_, bName, bArguments))
                where aName.hasPrefix("branch") || bName.hasPrefix("branch"):
                guard aName == bName, aArguments == bArguments else { return false }
            default: break
            }
            if before.source != after.source {
                func transfer(_ source: MacIRSourceSpan) -> MacIRTerminator {
                    MacIRTerminator.classify(row: source, functionRange: nil, jumpTables: [:],
                        knownTailCallTargets: [:], authoredCallSignaturesByTarget: [:])
                }
                guard transfer(before.source) == transfer(after.source) else { return false }
            }
        }
        return true
    }

    static func build(
        instructions: [MacIRInstruction],
        jumpTables: [UInt64: [UInt64]],
        knownTailCallTargets: [UInt64: String],
        provenTailCallTargets: [UInt64: UInt64] = [:],
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride],
        owningFunctionRange: Range<UInt64>? = nil
    ) -> MacIRCFG? {
        guard !Task.isCancelled else { return nil }
        let functionRange = owningFunctionRange ?? CFGBuilder.functionAddressRange(instructions: instructions)
        let ownedIndices = instructions.indices.filter {
            owningFunctionRange?.contains(instructions[$0].source.address) ?? true
        }
        let ownedEndIndex = ownedIndices.last.map { $0 + 1 } ?? 0
        var firstIndex: [UInt64: Int] = [:]
        var transfers = [MacIRTerminator](repeating: .none, count: instructions.count)
        var refusals: [MacIRRefusal] = []
        for index in ownedIndices {
            guard !Task.isCancelled else { return nil }
            let source = instructions[index].source
            if firstIndex[source.address] == nil { firstIndex[source.address] = index }
            // Expanded effects share one architectural transfer, at the last effect.
            if index + 1 < instructions.count,
               instructions[index + 1].source.address == source.address { continue }
            transfers[index] = MacIRTerminator.classify(row: source, functionRange: functionRange,
                jumpTables: jumpTables, knownTailCallTargets: knownTailCallTargets,
                provenTailCallTargets: provenTailCallTargets,
                authoredCallSignaturesByTarget: authoredCallSignaturesByTarget)
            if transfers[index] == .undecodable || source.mnemonic.lowercased() == "udf" {
                refusals.append(.init(reason: .undecodableRow, scope: .row(source.address),
                                      detail: source.assemblyText))
            }
        }
        var leaders: Set<Int> = Set(ownedIndices.prefix(1))
        for index in ownedIndices {
            if transfers[index].splitsBlock, index + 1 < ownedEndIndex { leaders.insert(index + 1) }
            for target in transfers[index].targetAddresses {
                if let destination = firstIndex[target] { leaders.insert(destination) }
            }
        }
        let starts = leaders.sorted()
        let blockAtStart = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1, $0) })
        var blocks: [MacIRBlock] = starts.enumerated().map { block, start in
            .init(index: block, startAddress: instructions[start].source.address,
                  instructionRange: start..<(block + 1 < starts.count ? starts[block + 1] : ownedEndIndex),
                  successors: [], predecessors: [], loopHeaderOf: nil)
        }
        var terminators: [MacIRTerminator] = []
        for block in blocks {
            guard !Task.isCancelled else { return nil }
            let last = block.instructionRange.upperBound - 1
            let transfer = transfers[last]
            terminators.append(transfer)
            let address = instructions[last].source.address
            var edges: [MacIREdge] = []
            func refusal(_ reason: MacIRRefusal.Reason, _ detail: String? = nil) {
                refusals.append(.init(reason: reason, scope: .row(address), detail: detail))
            }
            func exit(_ kind: MacIREdge.Kind) {
                edges.append(.init(from: block.index, to: nil, kind: kind, label: nil))
            }
            func target(_ address: UInt64?, kind: MacIREdge.Kind, label: Int? = nil) {
                // The supplied extent owns jump-table destinations even when the
                // row buffer also contains decoded rows from the next function.
                // Without an extent, retain the historical graph construction.
                let isOwned = kind != .jumpTable || address.map {
                    owningFunctionRange?.contains($0) ?? true
                } == true
                if isOwned, let address, let index = firstIndex[address],
                   let destination = blockAtStart[index] {
                    edges.append(.init(from: block.index, to: destination, kind: kind, label: label))
                } else {
                    let detail = address.map { "target 0x" + String($0, radix: 16) } ?? "missing target"
                    if kind == .jumpTable, owningFunctionRange != nil {
                        refusals.append(.init(reason: .targetOutsideFunction, scope: .block(block.index),
                            detail: label.map { "case \($0): " + detail } ?? detail))
                        if !isOwned, address.map({ knownTailCallTargets[$0] == nil }) == true,
                           !refusals.contains(where: {
                               $0.reason == .jumpTableOutsideFunction && $0.scope == .function
                           }) {
                            // External code may redefine cells and re-enter a
                            // reachable local block through an unknown edge.
                            refusals.append(.init(reason: .jumpTableOutsideFunction,
                                scope: .function, detail: "external case may re-enter the function"))
                        }
                    } else {
                        refusal(.targetOutsideFunction, detail)
                    }
                    // Preserve the case label, but never attach this edge to a
                    // decoded destination or a lexical fallthrough block.
                    edges.append(.init(from: block.index, to: nil, kind: kind, label: label))
                }
            }
            func addFallthrough(_ kind: MacIREdge.Kind = .fallthrough) {
                edges.append(.init(from: block.index,
                    to: block.index + 1 < blocks.count ? block.index + 1 : nil, kind: kind, label: nil))
            }
            switch transfer {
            case let .conditional(destination):
                if let destination, firstIndex[destination] != nil {
                    target(destination, kind: .branch)
                } else {
                    refusal(.targetOutsideFunction,
                        destination.map { "target 0x" + String($0, radix: 16) } ?? "missing target")
                }
                addFallthrough()
            case let .unconditional(destination): target(destination, kind: .branch)
            case let .indirect(table):
                if let table, !table.isEmpty {
                    // Cases retain labels even when several cases share a target;
                    // predecessor and adapter successor sets deduplicate blocks.
                    for (label, destination) in table.enumerated() {
                        target(destination, kind: .jumpTable, label: label)
                    }
                } else {
                    refusal(.unresolvedIndirectBranch)
                    exit(.exit)
                }
            case .call(_, returns: false), .callRegister(returns: false): exit(.noReturn)
            case .call(_, returns: true), .callRegister(returns: true): addFallthrough(.callReturn)
            case .ret: exit(.exit)
            case .tail: exit(.tail)
            case .none, .undecodable: addFallthrough()
            }
            blocks[block.index].successors = edges
        }
        for block in blocks {
            for destination in block.successors.compactMap(\.to) {
                if !blocks[destination].predecessors.contains(block.index) {
                    blocks[destination].predecessors.append(block.index)
                }
            }
        }
        let ordinary: [BasicBlock] = blocks.map { block in
            var seen: Set<Int> = []
            let successors = block.successors.compactMap(\.to).filter { seen.insert($0).inserted }
            return .init(index: block.index, startIndex: block.instructionRange.lowerBound,
                         endIndex: block.instructionRange.upperBound, successors: successors,
                         predecessors: block.predecessors, isLoopHeader: false)
        }
        let dom = MacIRCFGAlgorithms.computeDominators(blocks: ordinary, entryIndex: 0,
                                                       cancelled: { Task.isCancelled })
        guard !Task.isCancelled else { return nil }
        let postdom = MacIRCFGAlgorithms.computePostDominators(blocks: ordinary,
            exitingBlocks: Set(blocks.filter { $0.successors.contains { $0.to == nil } }.map(\.index)),
                                                              cancelled: { Task.isCancelled })
        guard !Task.isCancelled else { return nil }
        let unreachable = blocks.indices.filter { dom[$0] == nil }
        for index in unreachable {
            refusals.append(.init(reason: .unreachableBlock, scope: .block(index),
                                  detail: "entry 0x" + String(blocks[index].startAddress, radix: 16)))
        }
        var frontier = [Set<Int>](repeating: [], count: blocks.count)
        for block in ordinary where block.predecessors.count >= 2 || block.index == 0 && !block.predecessors.isEmpty {
            guard !Task.isCancelled else { return nil }
            guard let immediate = dom[block.index] else { continue }
            // Entry also has an implicit predecessor outside the function.
            let stop = block.index == 0 ? -1 : immediate
            for predecessor in block.predecessors where dom[predecessor] != nil {
                var runner = predecessor
                var visited: Set<Int> = []
                while runner != stop, visited.insert(runner).inserted {
                    guard !Task.isCancelled else { return nil }
                    frontier[runner].insert(block.index)
                    guard let parent = dom[runner], parent != runner else { break }
                    runner = parent
                }
            }
        }
        var backEdges: Set<CFGEdge> = []
        for block in ordinary where dom[block.index] != nil {
            for successor in block.successors where MacIRCFGAlgorithms.dominates(successor, block.index, domTree: dom) {
                backEdges.insert(.init(block.index, successor))
            }
        }
        var loops: [MacIRLoop] = []
        for header in Set(backEdges.map(\.to)).sorted() {
            guard !Task.isCancelled else { return nil }
            let latches = backEdges.filter { $0.to == header }.map(\.from).sorted()
            var body: Set<Int> = [header]
            var pending = latches
            while let next = pending.popLast() {
                guard !Task.isCancelled else { return nil }
                if body.insert(next).inserted {
                    pending.append(contentsOf: ordinary[next].predecessors.filter { dom[$0] != nil })
                }
            }
            let id = loops.count
            loops.append(.init(id: id, header: header, latches: latches, body: body.sorted(), isIrreducible: false))
            blocks[header].loopHeaderOf = id
        }
        // Keep each residual SCC distinct; two unrelated irreducible cycles
        // must not become one apparent loop region.
        let components = residualComponents(blocks: ordinary, backEdges: backEdges)
        guard !Task.isCancelled else { return nil }
        for component in components {
            guard let header = component.first else { continue }
            let id = loops.count
            loops.append(.init(id: id, header: header, latches: [], body: component, isIrreducible: true))
            if blocks[header].loopHeaderOf == nil { blocks[header].loopHeaderOf = id }
            refusals.append(.init(reason: .irreducibleLoop, scope: .block(header),
                                  detail: "entries " + component.map { "0x" + String(blocks[$0].startAddress, radix: 16) }.joined(separator: ", ")))
        }
        // The adapter captures the historical operation-based topology once.
        // Its unresolved-target and postdominator-presence facts cannot be
        // reconstructed from semantic refusals (for example, BR and BRK differ).
        let compatibility = CFGBuilder.buildCFG(instructions: instructions)
        guard !Task.isCancelled else { return nil }
        return .init(blocks: blocks, entry: 0,
                     idom: blocks.indices.map { dom[$0] ?? -1 },
                     ipostdom: blocks.indices.map { postdom[$0].flatMap { $0 == blocks.count ? nil : $0 } },
                     hasPostdominator: blocks.indices.map { postdom[$0] != nil },
                     dominanceFrontier: frontier.map { $0.sorted() }, loops: loops,
                     unreachable: unreachable, refusals: refusals, terminators: terminators,
                     compatibilityCFG: compatibility, edgeCount: blocks.reduce(0) { $0 + $1.successors.count })
    }

    /// Reindex expanded row effects without discovering another graph.
    func reindexed(instructions: [MacIRInstruction]) -> MacIRCFG {
        var first: [UInt64: Int] = [:]
        for (index, instruction) in instructions.enumerated() where first[instruction.source.address] == nil {
            first[instruction.source.address] = index
        }
        var updated = blocks
        for index in updated.indices {
            let start = first[updated[index].startAddress] ?? 0
            let end = index + 1 < updated.count
                ? first[updated[index + 1].startAddress] ?? instructions.count : instructions.count
            updated[index].instructionRange = start..<end
        }
        let basic = updated.map { block in
            BasicBlock(index: block.index, startIndex: block.instructionRange.lowerBound,
                endIndex: block.instructionRange.upperBound,
                successors: block.successors.compactMap(\.to).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } },
                predecessors: block.predecessors, isLoopHeader: block.loopHeaderOf != nil)
        }
        var dom: [Int: Int] = [:], post: [Int: Int] = [:]
        for index in updated.indices {
            if idom[index] >= 0 { dom[index] = idom[index] }
            if hasPostdominator[index] { post[index] = ipostdom[index] ?? updated.count }
        }
        let backEdges = Set(loops.flatMap { loop in loop.latches.map { CFGEdge($0, loop.header) } })
        // Preserve the legacy operation-level unresolved-target contract.
        // In particular, a direct branch beyond the function is an exit;
        // semantic target refusals do not make that exit unresolved.
        let functionRange = CFGBuilder.functionAddressRange(instructions: instructions)
        let hasUnresolvedTargets = instructions.contains { instruction in
            switch CFGBuilder.terminatorKind(of: instruction.operation) {
            case let .conditionalBranch(target):
                return target.map { first[$0] == nil } ?? true
            case let .unconditionalBranch(target):
                guard let target else { return true }
                return first[target] == nil && functionRange?.contains(target) == true
            case let .switchDispatch(targets):
                return targets.contains { first[$0] == nil }
            case .returnTerminator, .indirectBranch, .none:
                return false
            }
        }
        let compatibility = CFG(blocks: basic, entryIndex: entry, domTree: dom, postDomTree: post,
            loopHeaders: Set(loops.filter { !$0.isIrreducible }.map(\.header)), backEdges: backEdges,
            irreducibleBlocks: Set(loops.filter(\.isIrreducible).flatMap(\.body)),
            blockByStartIndex: Dictionary(uniqueKeysWithValues: basic.map { ($0.startIndex, $0.index) }),
            hasUnresolvedTargets: hasUnresolvedTargets)
        return .init(blocks: updated, entry: entry, idom: idom, ipostdom: ipostdom,
            hasPostdominator: hasPostdominator, dominanceFrontier: dominanceFrontier, loops: loops,
            unreachable: unreachable, refusals: refusals, terminators: terminators,
            compatibilityCFG: compatibility, edgeCount: edgeCount)
    }

    private static func residualComponents(blocks: [BasicBlock], backEdges: Set<CFGEdge>) -> [[Int]] {
        let adjacency = blocks.map { block in
            block.successors.filter { !backEdges.contains(.init(block.index, $0)) }
        }
        var visited: Set<Int> = []
        var order: [Int] = []
        for root in blocks.indices where !visited.contains(root) {
            var work = [(root, 0)]
            visited.insert(root)
            while let (node, child) = work.last {
                if Task.isCancelled { return [] }
                if child < adjacency[node].count {
                    work[work.count - 1].1 += 1
                    let next = adjacency[node][child]
                    if visited.insert(next).inserted { work.append((next, 0)) }
                } else {
                    order.append(node)
                    work.removeLast()
                }
            }
        }
        var reversed = [[Int]](repeating: [], count: blocks.count)
        for node in blocks.indices {
            for successor in adjacency[node] { reversed[successor].append(node) }
        }
        visited.removeAll(keepingCapacity: true)
        var result: [[Int]] = []
        for root in order.reversed() where !visited.contains(root) {
            var work = [root]
            var component: [Int] = []
            while let node = work.popLast() {
                if Task.isCancelled { return [] }
                guard visited.insert(node).inserted else { continue }
                component.append(node)
                work.append(contentsOf: reversed[node])
            }
            if component.count > 1 || adjacency[root].contains(root) { result.append(component.sorted()) }
        }
        return result.sorted { ($0.first ?? -1) < ($1.first ?? -1) }
    }
}

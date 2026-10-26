import Foundation

/// A directed edge between two basic blocks, identified by block index.
struct CFGEdge: Hashable, Sendable {
    var from: Int
    var to: Int

    init(_ from: Int, _ to: Int) {
        self.from = from
        self.to = to
    }
}

/// A maximal straight-line run of IR instructions with a single entry and a
/// single exit. `startIndex..<endIndex` is the half-open span of instruction
/// indices the block covers; `index` is the block's position in `CFG.blocks`.
struct BasicBlock: Hashable, Sendable {
    var index: Int
    var startIndex: Int
    var endIndex: Int
    var successors: [Int]
    var predecessors: [Int]
    var isLoopHeader: Bool

    var instructionRange: Range<Int> { startIndex..<endIndex }
}

/// A control-flow graph recovered from a linear `[MacIRInstruction]`. The IR
/// carries no explicit CFG; this is the reconstruction the structurer needs.
///
/// `domTree`/`postDomTree` map each block index to its immediate
/// (post-)dominator (the entry maps to itself in `domTree`). `loopHeaders`
/// and `backEdges` capture natural-loop structure; `irreducibleBlocks` flags
/// blocks that take part in a multi-entry (irreducible) cycle that the region
/// builder must NOT try to structure.
struct CFG: Sendable {
    var blocks: [BasicBlock]
    var entryIndex: Int
    var domTree: [Int: Int]
    var postDomTree: [Int: Int]
    var loopHeaders: Set<Int>
    var backEdges: Set<CFGEdge>
    var irreducibleBlocks: Set<Int>
    /// Block index keyed by the instruction index at which the block starts.
    var blockByStartIndex: [Int: Int]
    /// True when any branch target could not be resolved to an in-range
    /// instruction, or any structural assumption was violated. The region
    /// builder treats this as a hard "do not structure" signal.
    var hasUnresolvedTargets: Bool
}

/// Builds a `CFG` from a linear IR instruction list. Pure and deterministic.
enum CFGBuilder {
    /// Block-discovery + edge-construction + dominators + post-dominators +
    /// natural loops + irreducibility, in that order.
    static func buildCFG(instructions: [MacIRInstruction]) -> CFG {
        guard !instructions.isEmpty else {
            return CFG(
                blocks: [],
                entryIndex: 0,
                domTree: [:],
                postDomTree: [:],
                loopHeaders: [],
                backEdges: [],
                irreducibleBlocks: [],
                blockByStartIndex: [:],
                hasUnresolvedTargets: false
            )
        }

        // Address -> first effect index, for branch-target resolution. One
        // architectural row may expand to ordered effects at the same address;
        // control transfers enter before its memory effect, not at writeback.
        var indexByAddress: [UInt64: Int] = [:]
        indexByAddress.reserveCapacity(instructions.count)
        for (index, instruction) in instructions.enumerated() {
            if indexByAddress[instruction.source.address] == nil {
                indexByAddress[instruction.source.address] = index
            }
        }

        var hasUnresolvedTargets = false
        let functionRange = Self.functionAddressRange(instructions: instructions)

        // 1) Leaders: index 0, every branch target, every instruction after a
        //    terminator.
        var leaders: Set<Int> = [0]
        for (index, instruction) in instructions.enumerated() {
            let terminator = Self.terminatorKind(of: instruction.operation)
            if terminator != .none, index + 1 < instructions.count {
                leaders.insert(index + 1)
            }
            for target in Self.branchTargetAddresses(of: instruction.operation) {
                if let targetIndex = indexByAddress[target] {
                    leaders.insert(targetIndex)
                } else if case .unconditionalBranch = terminator,
                          let functionRange,
                          !functionRange.contains(target) {
                    continue
                } else {
                    hasUnresolvedTargets = true
                }
            }
        }

        let sortedLeaders = leaders.sorted()
        var blockByStartIndex: [Int: Int] = [:]
        for (blockIndex, leader) in sortedLeaders.enumerated() {
            blockByStartIndex[leader] = blockIndex
        }

        // 2) Block spans.
        var blocks: [BasicBlock] = []
        blocks.reserveCapacity(sortedLeaders.count)
        for (blockIndex, leader) in sortedLeaders.enumerated() {
            let end = blockIndex + 1 < sortedLeaders.count ? sortedLeaders[blockIndex + 1] : instructions.count
            blocks.append(
                BasicBlock(
                    index: blockIndex,
                    startIndex: leader,
                    endIndex: end,
                    successors: [],
                    predecessors: [],
                    isLoopHeader: false
                )
            )
        }

        // 3) Edges, keyed off each block's terminating instruction.
        for block in blocks {
            let lastIndex = block.endIndex - 1
            guard lastIndex >= block.startIndex else { continue }
            let terminator = instructions[lastIndex]
            var successors: [Int] = []

            func addSuccessor(address: UInt64) {
                if let targetIndex = indexByAddress[address], let succ = blockByStartIndex[targetIndex] {
                    if !successors.contains(succ) { successors.append(succ) }
                } else {
                    hasUnresolvedTargets = true
                }
            }

            func addFallthrough() {
                if block.endIndex < instructions.count, let succ = blockByStartIndex[block.endIndex] {
                    if !successors.contains(succ) { successors.append(succ) }
                }
            }

            switch Self.terminatorKind(of: terminator.operation) {
            case .conditionalBranch(let target):
                if let target { addSuccessor(address: target) } else { hasUnresolvedTargets = true }
                addFallthrough()
            case .unconditionalBranch(let target):
                if let target {
                    if let targetIndex = indexByAddress[target], let succ = blockByStartIndex[targetIndex] {
                        if !successors.contains(succ) { successors.append(succ) }
                    } else if let functionRange, functionRange.contains(target) {
                        hasUnresolvedTargets = true
                    }
                } else {
                    hasUnresolvedTargets = true
                }
            case .switchDispatch(let targets):
                for target in targets { addSuccessor(address: target) }
            case .returnTerminator, .indirectBranch:
                // Flows to exit (no in-graph successor).
                break
            case .none:
                addFallthrough()
            }

            blocks[block.index].successors = successors
        }

        // Predecessors.
        for block in blocks {
            for succ in block.successors {
                blocks[succ].predecessors.append(block.index)
            }
        }

        // 4) Dominators (Cooper-Harvey-Kennedy).
        let domTree = Self.computeDominators(blocks: blocks, entryIndex: 0)

        // 5) Post-dominators: same algorithm on the reversed CFG with a
        //    synthetic exit all exit blocks flow to.
        let postDomTree = Self.computePostDominators(blocks: blocks)

        // 6) Back-edges + natural loops: edge (a,b) where b dominates a.
        var backEdges: Set<CFGEdge> = []
        var loopHeaders: Set<Int> = []
        for block in blocks {
            for succ in block.successors {
                if Self.dominates(succ, block.index, domTree: domTree) {
                    backEdges.insert(CFGEdge(block.index, succ))
                    loopHeaders.insert(succ)
                }
            }
        }
        for header in loopHeaders {
            blocks[header].isLoopHeader = true
        }

        // 7) Irreducibility: the residual graph (edges minus back-edges) still
        //    has a cycle. Any SCC of size > 1 (or a self-loop) in the residual
        //    means the loop structure is not reducible -> flag those blocks.
        let irreducibleBlocks = Self.irreducibleBlocks(blocks: blocks, backEdges: backEdges)

        return CFG(
            blocks: blocks,
            entryIndex: 0,
            domTree: domTree,
            postDomTree: postDomTree,
            loopHeaders: loopHeaders,
            backEdges: backEdges,
            irreducibleBlocks: irreducibleBlocks,
            blockByStartIndex: blockByStartIndex,
            hasUnresolvedTargets: hasUnresolvedTargets
        )
    }

    static func functionAddressRange(instructions: [MacIRInstruction]) -> Range<UInt64>? {
        guard let first = instructions.first, let last = instructions.last else { return nil }
        let byteLength = instructionByteLength(of: last.source)
        let endAddress = last.source.address.addingReportingOverflow(byteLength)
        let upperBound = endAddress.overflow ? UInt64.max : endAddress.partialValue
        guard first.source.address <= upperBound else {
            return first.source.address..<first.source.address
        }
        return first.source.address..<upperBound
    }

    private static func instructionByteLength(of source: MacIRSourceSpan) -> UInt64 {
        let hexDigitCount = source.byteText.unicodeScalars.filter(Self.isHexDigit).count
        return UInt64(hexDigitCount / 2)
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }

    // MARK: - Terminator classification

    enum TerminatorKind: Equatable {
        case none
        case conditionalBranch(target: UInt64?)
        case unconditionalBranch(target: UInt64?)
        case switchDispatch(targets: [UInt64])
        case returnTerminator
        case indirectBranch
    }

    static func terminatorKind(of operation: MacIROperation) -> TerminatorKind {
        switch operation {
        case let .conditionalBranch(_, _, _, target):
            return .conditionalBranch(target: Self.address(of: target))
        case .returnValue:
            return .returnTerminator
        case let .call(frame, _) where NoReturnCatalog.isNoReturn(frame.target):
            return .returnTerminator
        case let .switchDispatch(_, cases, defaultTarget):
            var targets: [UInt64] = []
            for switchCase in cases {
                if let address = Self.address(of: switchCase.target) { targets.append(address) }
            }
            if let defaultTarget, let address = Self.address(of: defaultTarget) { targets.append(address) }
            return .switchDispatch(targets: targets)
        case let .intrinsic(_, name, arguments):
            if name == "branch" {
                return .unconditionalBranch(target: arguments.first.flatMap(Self.address(of:)))
            }
            if name == "branch_register" {
                return .indirectBranch
            }
            if name.hasPrefix("branch_") {
                // A conditional branch suffix the builder couldn't fold into a
                // comparison (e.g. branch_hs without a preceding cmp). Forward
                // target + fallthrough, like any conditional branch.
                return .conditionalBranch(target: arguments.first.flatMap(Self.address(of:)))
            }
            return .none
        default:
            return .none
        }
    }

    /// All branch-target addresses an operation can transfer to (for leader
    /// discovery). Does not include fallthrough.
    static func branchTargetAddresses(of operation: MacIROperation) -> [UInt64] {
        switch Self.terminatorKind(of: operation) {
        case let .conditionalBranch(target):
            return target.map { [$0] } ?? []
        case let .unconditionalBranch(target):
            return target.map { [$0] } ?? []
        case let .switchDispatch(targets):
            return targets
        case .none, .returnTerminator, .indirectBranch:
            return []
        }
    }

    static func address(of value: MacIRValue) -> UInt64? {
        guard case let .immediate(raw) = value, raw >= 0 else { return nil }
        return UInt64(raw)
    }

    // MARK: - Dominators

    /// Cooper-Harvey-Kennedy iterative dominators over reverse-post-order.
    static func computeDominators(blocks: [BasicBlock], entryIndex: Int) -> [Int: Int] {
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
    static func computePostDominators(blocks: [BasicBlock]) -> [Int: Int] {
        guard !blocks.isEmpty else { return [:] }
        let exitNode = blocks.count // synthetic

        // Reversed successors. Synthetic exit has the real exits as predecessors
        // in the reversed graph (i.e. exit -> realExit edges).
        var reverseSuccessors = [[Int]](repeating: [], count: blocks.count + 1)
        var reversePredecessors = [[Int]](repeating: [], count: blocks.count + 1)

        func isExitBlock(_ block: BasicBlock) -> Bool {
            block.successors.isEmpty
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
    }
}

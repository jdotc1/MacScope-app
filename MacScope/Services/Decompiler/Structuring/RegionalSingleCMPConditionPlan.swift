import Foundation

/// Pure CFG facts only. This helper does not establish decoded-byte identity,
/// producer correspondence, the meaning of a writer, or printing authority.
/// The physical-plan caller supplies its already parsed NZCV-writer/call rows
/// and must separately require an exact original EQ marker and a parsed CMP.
enum RegionalSingleCMPConditionPlan {
    struct Analysis {
        /// Writer identities reaching the input of each instruction, not the
        /// row's output. Calls are writer identities, never preserved NZCV.
        let reachingWriterRows: [Set<Int>]
        /// The function-entry path can reach this instruction without a known
        /// writer. A nonempty writer set must not conceal this alternative.
        let hasUnknownOrigin: [Bool]
        private let successors: [[Int]]
        private let predecessors: [[Int]]
        private let writerRows: Set<Int>

        fileprivate init(reachingWriterRows: [Set<Int>], hasUnknownOrigin: [Bool],
                         successors: [[Int]], predecessors: [[Int]], writerRows: Set<Int>) {
            self.reachingWriterRows = reachingWriterRows
            self.hasUnknownOrigin = hasUnknownOrigin
            self.successors = successors
            self.predecessors = predecessors
            self.writerRows = writerRows
        }

        /// Returns a writer identity, NOT a CMP certificate. The caller must
        /// check that identity against its parsed original instruction.
        func uniqueWriterWithoutInterveningWriter(before consumer: Int) -> Int? {
            guard reachingWriterRows.indices.contains(consumer), !hasUnknownOrigin[consumer],
                  reachingWriterRows[consumer].count == 1,
                  let writer = reachingWriterRows[consumer].first,
                  writer != consumer else { return nil }

            // Keep only paths that can arrive at this consumer. A writer on an
            // unrelated outgoing arm is irrelevant to the flags consumed here.
            var canReachConsumer: Set<Int> = [consumer]
            var pending = [consumer]
            while let row = pending.popLast() {
                for previous in predecessors[row] where canReachConsumer.insert(previous).inserted {
                    pending.append(previous)
                }
            }

            // The stronger path requirement is deliberately additional to the
            // ordinary reaching-definitions result. In particular, W -> X -> W
            // -> consumer has the singleton reaching identity {W}, yet violates
            // the rule that every W-to-consumer path has no intervening writer.
            // Re-entry to W itself also counts as an intervening writer.
            pending = successors[writer].filter { canReachConsumer.contains($0) }
            var visited = Set<Int>()
            while let row = pending.popLast() {
                guard visited.insert(row).inserted else { continue }
                if row == consumer { continue } // This occurrence consumes NZCV.
                guard !writerRows.contains(row) else { return nil }
                pending.append(contentsOf: successors[row].filter { canReachConsumer.contains($0) })
            }
            return writer
        }
    }

    /// Analyze the supplied topology, even when used by an isolated test with
    /// a derived CFG. This is not the production canonical-CFG admission gate.
    static func analyze(rowCount: Int, cfg: CFG, writerRows: Set<Int>) -> Analysis? {
        guard rowCount > 0, !cfg.hasUnresolvedTargets,
              cfg.blocks.indices.contains(cfg.entryIndex),
              writerRows.allSatisfy({ (0..<rowCount).contains($0) }) else { return nil }
        var rowOwner = Array(repeating: -1, count: rowCount)
        var blockByStart: [Int: Int] = [:]
        var expectedPredecessors = Array(repeating: Set<Int>(), count: cfg.blocks.count)
        for (index, block) in cfg.blocks.enumerated() {
            guard block.index == index, block.startIndex >= 0, block.endIndex <= rowCount,
                  block.startIndex < block.endIndex,
                  Set(block.successors).count == block.successors.count,
                  Set(block.predecessors).count == block.predecessors.count,
                  blockByStart.updateValue(index, forKey: block.startIndex) == nil else { return nil }
            for row in block.instructionRange {
                guard rowOwner[row] == -1 else { return nil }
                rowOwner[row] = index
            }
            for successor in block.successors {
                guard cfg.blocks.indices.contains(successor) else { return nil }
                expectedPredecessors[successor].insert(index)
            }
        }
        guard rowOwner.allSatisfy({ $0 >= 0 }), blockByStart == cfg.blockByStartIndex else { return nil }
        for block in cfg.blocks {
            guard Set(block.predecessors) == expectedPredecessors[block.index] else { return nil }
        }

        var successors = Array(repeating: [Int](), count: rowCount)
        var predecessors = successors
        for block in cfg.blocks {
            for row in block.instructionRange {
                successors[row] = row + 1 < block.endIndex ? [row + 1]
                    : block.successors.map { cfg.blocks[$0].startIndex }
                for successor in successors[row] { predecessors[successor].append(row) }
            }
        }
        let entry = cfg.blocks[cfg.entryIndex].startIndex
        var reachable: Set<Int> = [entry]
        var pending = [entry]
        while let row = pending.popLast() {
            for successor in successors[row] where reachable.insert(successor).inserted {
                pending.append(successor)
            }
        }
        guard reachable.count == rowCount else { return nil }

        // -1 is solely the function-entry unknown marker; all writer identities
        // have already been checked against 0..<rowCount. The monotone worklist
        // computes the least fixed point across real CFG edges, including loops.
        var incoming = Array(repeating: Set<Int>(), count: rowCount)
        incoming[entry] = [-1]
        pending = [entry]
        var queued: Set<Int> = [entry]
        var cursor = 0
        while cursor < pending.count {
            let row = pending[cursor]
            cursor += 1
            queued.remove(row)
            let outgoing: Set<Int> = writerRows.contains(row) ? [row] : incoming[row]
            for successor in successors[row] {
                let combined = incoming[successor].union(outgoing)
                if combined != incoming[successor] {
                    incoming[successor] = combined
                    if queued.insert(successor).inserted { pending.append(successor) }
                }
            }
        }
        return Analysis(reachingWriterRows: incoming.map { Set($0.filter { $0 >= 0 }) },
            hasUnknownOrigin: incoming.map { $0.contains(-1) },
            successors: successors, predecessors: predecessors, writerRows: writerRows)
    }
}

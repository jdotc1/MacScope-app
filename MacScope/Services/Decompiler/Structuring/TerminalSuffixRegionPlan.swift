import Foundation

/// A supported acyclic prefix followed by one unchanged legacy interval.
/// Creates no loops, labels or values. The printer separately certifies that
/// cutting the legacy range changes no peephole across the boundary.
struct TerminalSuffixRegionPlan {
    var region: Region
    var suffixStartIndex: Int

    static func prove(prefix: [Region], suffixEntry: Int, suffix: [Int],
                      cfg: CFG, instructions: [MacIRInstruction]) -> Self? {
        guard cfg.blocks.indices.contains(suffixEntry), !prefix.isEmpty else { return nil }
        var proof = PrefixProof(cfg: cfg, instructions: instructions)
        guard let owned = proof.verify(.sequence(prefix), continuation: suffixEntry),
              owned.entry == cfg.entryIndex, proof.conditionalCount > 0,
              owned.order == owned.order.sorted(by: { cfg.blocks[$0].startIndex < cfg.blocks[$1].startIndex }) else { return nil }
        let suffixSet = Set(suffix)
        guard !suffixSet.isEmpty, suffixSet.count == suffix.count,
              owned.blocks.isDisjoint(with: suffixSet),
              owned.blocks.union(suffixSet) == Set(cfg.blocks.indices) else { return nil }
        let cut = cfg.blocks[suffixEntry].startIndex
        guard covers(owned.blocks, range: 0..<cut, cfg: cfg),
              covers(suffixSet, range: cut..<instructions.count, cfg: cfg) else { return nil }
        for block in cfg.blocks {
            for next in block.successors {
                if suffixSet.contains(block.index) {
                    guard suffixSet.contains(next) else { return nil }
                } else if suffixSet.contains(next), next != suffixEntry { return nil }
            }
        }
        var visiting: Set<Int> = [], visited: Set<Int> = []
        func hasCycle(_ block: Int) -> Bool {
            if visiting.contains(block) { return true }
            if visited.contains(block) { return false }
            visiting.insert(block)
            for next in cfg.blocks[block].successors where owned.blocks.contains(next) {
                if hasCycle(next) { return true }
            }
            visiting.remove(block)
            visited.insert(block)
            return false
        }
        guard !owned.blocks.contains(where: { hasCycle($0) }) else { return nil }
        return Self(region: .sequence(prefix + [.gotoLeaf(blocks: suffix.sorted())]),
                    suffixStartIndex: cut)
    }

    private static func covers(_ blocks: Set<Int>, range: Range<Int>, cfg: CFG) -> Bool {
        var cursor = range.lowerBound
        for block in blocks.map({ cfg.blocks[$0] }).sorted(by: { $0.startIndex < $1.startIndex }) {
            guard block.startIndex == cursor, block.endIndex > cursor else { return false }
            cursor = block.endIndex
        }
        return cursor == range.upperBound
    }

    private struct Owned { var entry: Int; var blocks: Set<Int>; var order: [Int] }

    private struct PrefixProof {
        let cfg: CFG
        let instructions: [MacIRInstruction]
        var conditionalCount = 0

        /// Check multiplicity before union, and prove every suppressed edge is
        /// the AST's actual lexical continuation, with the original polarity.
        mutating func verify(_ region: Region, continuation: Int) -> Owned? {
            switch region {
            case let .sequence(items):
                guard !items.isEmpty else { return nil }
                var next = continuation
                var blocks: Set<Int> = []
                var order: [Int] = []
                for item in items.reversed() {
                    guard let owned = verify(item, continuation: next),
                          blocks.isDisjoint(with: owned.blocks) else { return nil }
                    blocks.formUnion(owned.blocks)
                    order = owned.order + order
                    next = owned.entry
                }
                return Owned(entry: next, blocks: blocks, order: order)
            case let .block(index):
                guard cfg.blocks.indices.contains(index) else { return nil }
                let block = cfg.blocks[index]
                guard block.endIndex > block.startIndex else { return nil }
                switch CFGBuilder.terminatorKind(of: instructions[block.endIndex - 1].operation) {
                case .conditionalBranch, .switchDispatch: return nil
                case .none, .unconditionalBranch:
                    guard block.successors.isEmpty || block.successors == [continuation] else { return nil }
                case .returnTerminator, .indirectBranch:
                    guard block.successors.isEmpty else { return nil }
                }
                return Owned(entry: index, blocks: [index], order: [index])
            case let .ifThen(condition, body, join, inverted):
                guard join == continuation, let header = conditionHeader(condition),
                      let arm = verify(body, continuation: join), !arm.blocks.contains(header),
                      cfg.blocks[header].successors == (inverted ? [join, arm.entry] : [arm.entry, join]),
                      privateEntry(arm, header: header), stateNeutral(arm.blocks) else { return nil }
                conditionalCount += 1
                return Owned(entry: header, blocks: arm.blocks.union([header]), order: [header] + arm.order)
            case let .ifThenElse(condition, thenBody, elseBody, join):
                guard join == continuation, let header = conditionHeader(condition),
                      let thenArm = verify(thenBody, continuation: join),
                      let elseArm = verify(elseBody, continuation: join),
                      !thenArm.blocks.contains(header), !elseArm.blocks.contains(header),
                      thenArm.blocks.isDisjoint(with: elseArm.blocks),
                      cfg.blocks[header].successors == [elseArm.entry, thenArm.entry],
                      privateEntry(thenArm, header: header), privateEntry(elseArm, header: header),
                      stateNeutral(thenArm.blocks), stateNeutral(elseArm.blocks) else { return nil }
                conditionalCount += 1
                return Owned(entry: header, blocks: thenArm.blocks.union(elseArm.blocks).union([header]),
                             order: [header] + thenArm.order + elseArm.order)
            case .whileLoop, .doWhileLoop, .naturalLoop, .switchDispatch, .gotoLeaf, .irreducible, .certifiedEdge, .certifiedSelection:
                return nil
            }
        }

        private func privateEntry(_ arm: Owned, header: Int) -> Bool {
            arm.blocks.allSatisfy { block in
                cfg.blocks[block].predecessors.allSatisfy {
                    arm.blocks.contains($0) || (block == arm.entry && $0 == header)
                }
            }
        }

        /// Empty phis do not establish a correct join. Admit no path-dependent
        /// register, memory, stack-forwarding or NZCV writes, including on an
        /// exiting arm whose physical-last facts could leak into the continuation.
        private func stateNeutral(_ blocks: Set<Int>) -> Bool {
            blocks.allSatisfy { block in
                cfg.blocks[block].instructionRange.allSatisfy { index in
                    let instruction = instructions[index]
                    switch instruction.operation {
                    case let .intrinsic(destination, name, arguments):
                        if destination != nil { return false }
                        if name == "nop", arguments.isEmpty,
                           instruction.source.mnemonic.lowercased() == "nop" { return true }
                        return name == "branch" && instruction.source.mnemonic.lowercased() == "b"
                    case .conditionalBranch:
                        return ["cbz", "cbnz", "tbz", "tbnz"].contains(instruction.source.mnemonic.lowercased())
                    case .returnValue: return true
                    default: return false
                    }
                }
            }
        }

        /// Existing permissive if recovery is not a reaching-NZCV proof. Use
        /// direct zero/bit tests, or exact CMP operands across actual NOPs only.
        private func conditionHeader(_ condition: BranchCondition) -> Int? {
            guard condition.continuationGotoTargets.isEmpty,
                  let block = cfg.blocks.first(where: { $0.endIndex - 1 == condition.branchIndex }),
                  case let .conditionalBranch(op, left, right, _) = instructions[condition.branchIndex].operation,
                  condition.condition == op, condition.left == left, condition.right == right else { return nil }
            let branch = instructions[condition.branchIndex]
            if ["cbz", "cbnz", "tbz", "tbnz"].contains(branch.source.mnemonic.lowercased()) {
                return condition.isZeroCheck && condition.compareIndex == nil ? block.index : nil
            }
            guard !condition.isZeroCheck else { return nil }
            var index = condition.branchIndex - 1
            var nextAddress = branch.source.address
            while index >= block.startIndex {
                let instruction = instructions[index]
                guard instruction.source.address.isContiguous(to: nextAddress) else { return nil }
                if case let .intrinsic(destination, name, arguments) = instruction.operation,
                   destination == nil, name == "nop", arguments.isEmpty,
                   instruction.source.mnemonic.lowercased() == "nop" {
                    nextAddress = instruction.source.address
                    index -= 1
                    continue
                }
                guard instruction.source.mnemonic.lowercased() == "cmp",
                      case let .intrinsic(_, name, arguments) = instruction.operation,
                      name == "compare", arguments == [left, right],
                      condition.compareIndex == nil || condition.compareIndex == index else { return nil }
                return block.index
            }
            return nil
        }
    }
}

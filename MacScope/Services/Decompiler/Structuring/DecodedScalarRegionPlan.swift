import Foundation

/// An independent edge/ownership check between a certified physical-state CFG
/// and the region tree. A successful shape recovery is not itself an edge proof.
struct DecodedScalarRegionPlan {
    let region: Region
    let absorbedStubs: [Int: Int]
    let blockByInstruction: [Int: Int]
    let whileExitOnTaken: [Int: Bool]

    static func prove(cfg: CFG, instructions: [MacIRInstruction],
                      state: DecodedScalarCFGPlan,
                      control: RegionTree.CertifiedBuildResult) -> Self? {
        guard state.matches(cfg: cfg, instructions: instructions),
              state.groups.count == instructions.count else { return nil }
        var checker = Checker(cfg: cfg, instructions: instructions, state: state,
                              absorbedStubs: control.absorbedStubs)
        guard let entry = try? checker.visit(control.region, continuation: nil),
              entry == cfg.entryIndex,
              checker.owned == Set(cfg.blocks.indices),
              checker.usedStubs == Set(control.absorbedStubs.keys) else { return nil }
        return Self(region: control.region, absorbedStubs: control.absorbedStubs,
                    blockByInstruction: checker.blockByInstruction, whileExitOnTaken: checker.whileExitOnTaken)
    }

    private enum Refusal: Error { case unproved }

    private struct Checker {
        let cfg: CFG
        let instructions: [MacIRInstruction]
        let state: DecodedScalarCFGPlan
        let absorbedStubs: [Int: Int]
        var owned: Set<Int> = []
        var usedStubs: Set<Int> = []
        var activeDepth = 0
        var whileExitOnTaken: [Int: Bool] = [:]
        var blockByInstruction: [Int: Int] {
            var result: [Int: Int] = [:]
            for block in cfg.blocks {
                for index in block.startIndex..<block.endIndex { result[index] = block.index }
            }
            return result
        }

        mutating func claim(_ block: Int) throws {
            guard cfg.blocks.indices.contains(block), owned.insert(block).inserted else {
                throw Refusal.unproved
            }
        }

        func branchBlock(_ condition: BranchCondition) throws -> Int {
            guard condition.continuationGotoTargets.isEmpty,
                  let block = blockByInstruction[condition.branchIndex],
                  cfg.blocks[block].endIndex - 1 == condition.branchIndex,
                  condition.compareIndex == nil else { throw Refusal.unproved }
            return block
        }

        func edges(_ condition: BranchCondition) throws -> (taken: Int, otherwise: Int) {
            let block = try branchBlock(condition)
            guard case let .conditionalBranch(_, _, _, .immediate(target)) = instructions[condition.branchIndex].operation,
                  let taken = cfg.blocks.first(where: {
                      instructions[$0.startIndex].source.address == UInt64(bitPattern: target)
                  })?.index,
                  let otherwise = blockByInstruction[condition.branchIndex + 1],
                  taken != otherwise,
                  Set(cfg.blocks[block].successors) == Set([taken, otherwise]),
                  cfg.blocks[block].successors.count == 2 else { throw Refusal.unproved }
            return (taken, otherwise)
        }

        func canonical(_ condition: BranchCondition) throws -> BranchCondition {
            guard let original = state.branchConditions[condition.branchIndex] else { throw Refusal.unproved }
            return original
        }

        func trueAndFalseEdges(_ condition: BranchCondition) throws -> (yes: Int, no: Int) {
            let original = try canonical(condition)
            let edge = try edges(condition)
            if condition == original { return (edge.taken, edge.otherwise) }
            let inverse = ["==": "!=", "!=": "==", "<": ">=", ">=": "<", ">": "<=", "<=": ">"]
            var inverted = original
            guard let op = inverse[original.condition] else { throw Refusal.unproved }
            inverted.condition = op
            guard condition == inverted else { throw Refusal.unproved }
            return (edge.otherwise, edge.taken)
        }

        mutating func visit(_ region: Region, continuation: Int?) throws -> Int? {
            guard activeDepth < 4096 else { throw Refusal.unproved }
            activeDepth += 1
            defer { activeDepth -= 1 }
            switch region {
            case let .sequence(parts):
                var next = continuation
                for part in parts.reversed() { next = try visit(part, continuation: next) }
                return next
            case let .block(block):
                try claim(block)
                let basic = cfg.blocks[block]
                if basic.successors.isEmpty {
                    guard case .returnValue = instructions[basic.endIndex - 1].operation else {
                        throw Refusal.unproved
                    }
                } else {
                    guard let continuation, basic.successors == [continuation],
                          state.branchConditions[basic.endIndex - 1] == nil else { throw Refusal.unproved }
                }
                return block
            case let .ifThen(condition, body, join, inverted):
                guard continuation == join, condition == (try canonical(condition)) else { throw Refusal.unproved }
                let block = try branchBlock(condition)
                try claim(block)
                guard let bodyEntry = try visit(body, continuation: join) else { throw Refusal.unproved }
                let edge = try edges(condition)
                guard edge.taken == (inverted ? join : bodyEntry),
                      edge.otherwise == (inverted ? bodyEntry : join) else { throw Refusal.unproved }
                return block
            case let .ifThenElse(condition, thenBody, elseBody, join):
                guard continuation == join, condition == (try canonical(condition)) else { throw Refusal.unproved }
                let block = try branchBlock(condition)
                try claim(block)
                guard let thenEntry = try visit(thenBody, continuation: join),
                      let elseEntry = try visit(elseBody, continuation: join) else { throw Refusal.unproved }
                let edge = try edges(condition)
                // RegionTree's then arm is the original fallthrough arm.
                guard edge.taken == elseEntry, edge.otherwise == thenEntry else { throw Refusal.unproved }
                return block
            case let .doWhileLoop(body, condition):
                guard let continuation else { throw Refusal.unproved }
                let test = try branchBlock(condition)
                try claim(test)
                guard let header = try visit(body, continuation: test) else { throw Refusal.unproved }
                let edge = try trueAndFalseEdges(condition)
                guard edge.no == continuation else { throw Refusal.unproved }
                if let stub = absorbedStubs[condition.branchIndex] {
                    try claim(stub)
                    usedStubs.insert(condition.branchIndex)
                    let basic = cfg.blocks[stub]
                    guard edge.yes == stub, basic.successors == [header],
                          basic.predecessors == [test], basic.endIndex == basic.startIndex + 1,
                          case let .intrinsic(nil, "branch", arguments) = instructions[basic.startIndex].operation,
                          arguments == [.immediate(Int64(bitPattern: instructions[cfg.blocks[header].startIndex].source.address))],
                          state.groups[basic.startIndex].isEmpty,
                          cfg.backEdges.contains(CFGEdge(stub, header)) else { throw Refusal.unproved }
                } else {
                    guard edge.yes == header, cfg.backEdges.contains(CFGEdge(test, header)) else { throw Refusal.unproved }
                }
                return header
            case let .whileLoop(condition, body, header):
                guard let continuation, condition == (try canonical(condition)),
                      (try branchBlock(condition)) == header else { throw Refusal.unproved }
                try claim(header)
                guard let bodyEntry = try visit(body, continuation: header) else { throw Refusal.unproved }
                let edge = try edges(condition)
                guard Set([edge.taken, edge.otherwise]) == Set([bodyEntry, continuation]),
                      cfg.backEdges.contains(where: { $0.to == header }) else { throw Refusal.unproved }
                whileExitOnTaken[condition.branchIndex] = edge.taken == continuation
                return header
            case .naturalLoop, .switchDispatch, .gotoLeaf, .irreducible, .certifiedEdge, .certifiedSelection:
                throw Refusal.unproved
            }
        }
    }
}

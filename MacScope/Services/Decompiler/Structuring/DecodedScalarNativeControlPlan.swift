/// Native control projection of an already-proved decoded scalar Region tree.
/// This plan owns no scalar expressions, rendered names, casts or statement text.
struct DecodedScalarNativeControlPlan {
    /// Region's token is only an integer. Resolution belongs exclusively to the
    /// active scalar context, never to the captured-call ordinary control plan.
    typealias EdgeEmissionSlotID = RegionalOrdinaryControlPlan.EdgeEmissionSlotID

    struct OriginalEdgeID: Hashable, Sendable {
        let sourceBlock: Int
        let successorOrdinal: Int
        let targetBlock: Int
        var cfgEdge: CFGEdge { CFGEdge(sourceBlock, targetBlock) }
    }
    enum EdgePhase: Equatable, Sendable { case copiesAndTransfer }
    enum Transfer: Equatable, Sendable {
        case `fallthrough`
        case breakLoop(header: Int)
    }
    struct EdgeEmissionSlot: Equatable, Sendable {
        let id: EdgeEmissionSlotID
        let origins: [OriginalEdgeID]
        let phase: EdgePhase
        let transfer: Transfer
        let nearestLoopHeader: Int?
    }
    enum LoopKind: Equatable, Sendable { case doWhile, natural }
    struct LoopBinding: Sendable {
        let header: Int
        /// The condition-owning block; equal to header for a top-tested loop.
        let latch: Int
        let exit: Int
        let members: Set<Int>
        let condition: BranchCondition
        let kind: LoopKind
        let backedge: OriginalEdgeID
        let continueEdge: OriginalEdgeID
        let exitEdge: OriginalEdgeID
        let absorbedStub: Int?
        let implicitEdges: [OriginalEdgeID]
        let implicitBlocks: Set<Int>
        let implicitRows: Set<Int>
    }

    let root: Region
    let edgeSlots: [EdgeEmissionSlotID: EdgeEmissionSlot]
    let loops: [Int: LoopBinding]
    let ownedBlocks: Set<Int>
    let ownedRows: Set<Int>
    let originalEdges: Set<OriginalEdgeID>
    private let originalFunction: MacIRFunction
    private let originalCFG: CFG

    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        function == originalFunction && Self.sameCFG(cfg, originalCFG)
    }

    static func prove(function: MacIRFunction, cfg: CFG, state: DecodedScalarCFGPlan,
                      topology: DecodedScalarRegionPlan,
                      values: DecodedScalarNativeValuePlan) -> Self? {
        guard state.matches(cfg: cfg, instructions: function.instructions),
              values.matches(function: function, cfg: cfg),
              values.groups.count == function.instructions.count,
              values.ownedRows == Set(function.instructions.indices),
              Set(values.branchConditions.keys) == Set(state.branchConditions.keys),
              let checkedTopology = DecodedScalarRegionPlan.prove(cfg: cfg,
                  instructions: function.instructions, state: state,
                  control: RegionTree.CertifiedBuildResult(region: topology.region,
                      absorbedStubs: topology.absorbedStubs)) else { return nil }
        let input = Input(function: function, cfg: cfg, state: state, values: values)
        guard let edges = try? input.allEdges(),
              Set(values.edgeCopies.keys).isSubset(of: Set(edges.map(\.cfgEdge))) else { return nil }
        var builder = Builder(input: input, topology: checkedTopology)
        guard let projection = try? builder.project(checkedTopology.region,
                  continuation: nil, activeLoops: [], depth: 0),
              projection.entry == cfg.entryIndex,
              builder.owned == Set(cfg.blocks.indices) else { return nil }
        var checker = Checker(input: input, slots: builder.slots, loops: builder.loops,
                              originalEdges: edges)
        guard checker.verify(projection.region) else { return nil }
        // Bound this capability by the independently checked complete natural-loop
        // header set, not by function identity or a partial Region traversal.
        guard builder.loops.count <= 2 else {
            return nil
        }
        return Self(root: projection.region, edgeSlots: builder.slots, loops: builder.loops,
                    ownedBlocks: checker.owned, ownedRows: values.ownedRows,
                    originalEdges: edges, originalFunction: function, originalCFG: cfg)
    }

    private enum Refusal: Error { case unproved }
    private struct Input {
        let function: MacIRFunction
        let cfg: CFG
        let state: DecodedScalarCFGPlan
        let values: DecodedScalarNativeValuePlan

        func allEdges() throws -> Set<OriginalEdgeID> {
            var result: Set<OriginalEdgeID> = []
            var cursor = 0
            for (index, block) in cfg.blocks.enumerated() {
                guard block.index == index, block.startIndex == cursor,
                      block.endIndex > cursor, block.endIndex <= function.instructions.count,
                      Set(block.successors).count == block.successors.count else { throw Refusal.unproved }
                cursor = block.endIndex
                for (ordinal, target) in block.successors.enumerated() {
                    guard cfg.blocks.indices.contains(target) else { throw Refusal.unproved }
                    result.insert(OriginalEdgeID(sourceBlock: index,
                        successorOrdinal: ordinal, targetBlock: target))
                }
            }
            guard cursor == function.instructions.count else { throw Refusal.unproved }
            return result
        }
        func edge(_ source: Int, _ target: Int) throws -> OriginalEdgeID {
            guard cfg.blocks.indices.contains(source), cfg.blocks.indices.contains(target),
                  let ordinal = cfg.blocks[source].successors.firstIndex(of: target) else { throw Refusal.unproved }
            return OriginalEdgeID(sourceBlock: source, successorOrdinal: ordinal, targetBlock: target)
        }
        func block(at row: Int) throws -> Int {
            guard function.instructions.indices.contains(row),
                  let block = cfg.blocks.first(where: { $0.startIndex <= row && row < $0.endIndex }) else {
                throw Refusal.unproved
            }
            return block.index
        }
        func branchBlock(_ condition: BranchCondition) throws -> Int {
            let block = try block(at: condition.branchIndex)
            guard cfg.blocks[block].endIndex - 1 == condition.branchIndex,
                  cfg.blocks[block].successors.count == 2,
                  condition.compareIndex == nil, condition.continuationGotoTargets.isEmpty,
                  let native = values.branchConditions[condition.branchIndex],
                  native.branchIndex == condition.branchIndex,
                  native.compareIndex == nil, native.continuationGotoTargets.isEmpty else { throw Refusal.unproved }
            return block
        }
        /// Resolve original polarity from the original target and next row,
        /// never from a cached topology inversion or assumed successor order.
        func originalBranchEdges(_ row: Int) throws -> (taken: OriginalEdgeID, otherwise: OriginalEdgeID) {
            let source = try block(at: row)
            guard cfg.blocks[source].endIndex - 1 == row,
                  case let .conditionalBranch(_, _, _, .immediate(target)) = function.instructions[row].operation,
                  let taken = cfg.blocks.first(where: {
                      function.instructions[$0.startIndex].source.address == UInt64(bitPattern: target)
                  })?.index else { throw Refusal.unproved }
            let otherwise = try block(at: row + 1)
            guard taken != otherwise, cfg.blocks[source].successors.count == 2,
                  Set(cfg.blocks[source].successors) == Set([taken, otherwise]) else { throw Refusal.unproved }
            return (try edge(source, taken), try edge(source, otherwise))
        }
        func native(_ old: BranchCondition) throws -> BranchCondition {
            guard let canonical = state.branchConditions[old.branchIndex],
                  let native = values.branchConditions[old.branchIndex] else { throw Refusal.unproved }
            if old == canonical { return native }
            guard old == (try DecodedScalarNativeControlPlan.inverted(canonical)) else { throw Refusal.unproved }
            return try DecodedScalarNativeControlPlan.inverted(native)
        }
        func nativeEdges(_ condition: BranchCondition) throws -> (yes: OriginalEdgeID, no: OriginalEdgeID) {
            _ = try branchBlock(condition)
            guard let canonical = values.branchConditions[condition.branchIndex] else { throw Refusal.unproved }
            let edges = try originalBranchEdges(condition.branchIndex)
            if condition == canonical { return (edges.taken, edges.otherwise) }
            guard condition == (try DecodedScalarNativeControlPlan.inverted(canonical)) else { throw Refusal.unproved }
            return (edges.otherwise, edges.taken)
        }
        func backedge(to header: Int) throws -> OriginalEdgeID {
            let candidates = cfg.backEdges.filter { $0.to == header }
            guard candidates.count == 1, let edge = candidates.first else { throw Refusal.unproved }
            return try self.edge(edge.from, header)
        }
        func naturalMembers(_ backedge: OriginalEdgeID) throws -> Set<Int> {
            guard cfg.backEdges.contains(backedge.cfgEdge),
                  cfg.loopHeaders.contains(backedge.targetBlock) else { throw Refusal.unproved }
            let header = backedge.targetBlock
            var members: Set<Int> = [header, backedge.sourceBlock]
            var pending = backedge.sourceBlock == header ? [] : [backedge.sourceBlock]
            while let block = pending.popLast() {
                guard cfg.blocks.indices.contains(block) else { throw Refusal.unproved }
                for predecessor in cfg.blocks[block].predecessors where predecessor != header {
                    if members.insert(predecessor).inserted { pending.append(predecessor) }
                }
            }
            return members
        }
    }

    private struct Projection {
        let region: Region
        let entry: Int?
        let blocks: Set<Int>
    }
    private struct Builder {
        let input: Input
        let topology: DecodedScalarRegionPlan
        var slots: [EdgeEmissionSlotID: EdgeEmissionSlot] = [:]
        var loops: [Int: LoopBinding] = [:]
        var owned: Set<Int> = []
        var budget = 16384

        mutating func claim(_ block: Int) throws {
            guard input.cfg.blocks.indices.contains(block), owned.insert(block).inserted else { throw Refusal.unproved }
        }
        mutating func slot(_ edge: OriginalEdgeID, active: [Int],
                           transfer: Transfer = .fallthrough) -> Region {
            let id = EdgeEmissionSlotID(rawValue: slots.count)
            slots[id] = EdgeEmissionSlot(id: id, origins: [edge], phase: .copiesAndTransfer,
                                         transfer: transfer, nearestLoopHeader: active.last)
            return .certifiedEdge(id)
        }
        func firstBlock(_ region: Region, depth: Int = 0) throws -> Int? {
            guard depth < 4096 else { throw Refusal.unproved }
            switch region {
            case let .sequence(parts):
                for part in parts { if let block = try firstBlock(part, depth: depth + 1) { return block } }
                return nil
            case let .block(block): return block
            case let .ifThen(condition, _, _, _), let .ifThenElse(condition, _, _, _):
                return try input.branchBlock(condition)
            case let .doWhileLoop(body, condition):
                // A payload self-loop has an empty Region body: its original
                // block is owned by the latch and emitted as leading effects.
                if let entry = try firstBlock(body, depth: depth + 1) { return entry }
                return try input.branchBlock(condition)
            case let .whileLoop(_, _, header): return header
            default: throw Refusal.unproved
            }
        }
        mutating func project(_ region: Region, continuation: Int?, activeLoops: [Int], depth: Int) throws -> Projection {
            budget -= 1
            guard budget >= 0, depth < 4096 else { throw Refusal.unproved }
            switch region {
            case let .sequence(parts):
                var next = continuation, results: [Region] = [], blocks: Set<Int> = []
                for part in parts.reversed() {
                    let result = try project(part, continuation: next, activeLoops: activeLoops, depth: depth + 1)
                    results.append(result.region); blocks.formUnion(result.blocks)
                    if let entry = result.entry { next = entry }
                }
                return Projection(region: Self.sequence(results.reversed()),
                                  entry: next, blocks: blocks)
            case let .block(block):
                try claim(block)
                let basic = input.cfg.blocks[block]
                guard input.values.branchConditions[basic.endIndex - 1] == nil else { throw Refusal.unproved }
                if basic.successors.isEmpty {
                    guard case .returnValue = input.function.instructions[basic.endIndex - 1].operation else { throw Refusal.unproved }
                    return Projection(region: .block(blockIndex: block), entry: block, blocks: [block])
                }
                guard let continuation, basic.successors == [continuation] else { throw Refusal.unproved }
                let edge = try input.edge(block, continuation)
                return Projection(region: .sequence([.block(blockIndex: block), slot(edge, active: activeLoops)]),
                                  entry: block, blocks: [block])
            case let .ifThen(condition, body, join, inverted):
                guard continuation == join else { throw Refusal.unproved }
                let block = try input.branchBlock(condition)
                try claim(block)
                let projected = try project(body, continuation: join, activeLoops: activeLoops, depth: depth + 1)
                guard let bodyEntry = projected.entry,
                      let native = input.values.branchConditions[condition.branchIndex],
                      condition == input.state.branchConditions[condition.branchIndex] else { throw Refusal.unproved }
                let edges = try input.originalBranchEdges(condition.branchIndex)
                guard edges.taken.targetBlock == (inverted ? join : bodyEntry),
                      edges.otherwise.targetBlock == (inverted ? bodyEntry : join) else { throw Refusal.unproved }
                let thenParts = [slot(edges.otherwise, active: activeLoops)] + (inverted ? [projected.region] : [])
                let elseParts = [slot(edges.taken, active: activeLoops)] + (inverted ? [] : [projected.region])
                return Projection(region: .ifThenElse(cond: native, then: Self.sequence(thenParts),
                    els: Self.sequence(elseParts), join: join), entry: block, blocks: projected.blocks.union([block]))
            case let .ifThenElse(condition, thenBody, elseBody, join):
                guard continuation == join else { throw Refusal.unproved }
                let block = try input.branchBlock(condition)
                try claim(block)
                let left = try project(thenBody, continuation: join, activeLoops: activeLoops, depth: depth + 1)
                let right = try project(elseBody, continuation: join, activeLoops: activeLoops, depth: depth + 1)
                let edges = try input.originalBranchEdges(condition.branchIndex)
                guard left.entry == edges.otherwise.targetBlock, right.entry == edges.taken.targetBlock,
                      condition == input.state.branchConditions[condition.branchIndex],
                      let native = input.values.branchConditions[condition.branchIndex] else { throw Refusal.unproved }
                return Projection(region: .ifThenElse(cond: native,
                    then: Self.sequence([slot(edges.otherwise, active: activeLoops), left.region]),
                    els: Self.sequence([slot(edges.taken, active: activeLoops), right.region]), join: join),
                    entry: block, blocks: left.blocks.union(right.blocks).union([block]))
            case let .doWhileLoop(body, condition):
                guard let continuation else { throw Refusal.unproved }
                let latch = try input.branchBlock(condition)
                // Match the certified topology's empty-body continuation. The
                // unchanged backedge/member checks below prove this real block.
                let header = try firstBlock(body) ?? latch
                guard loops[header] == nil else { throw Refusal.unproved }
                try claim(latch)
                let active = activeLoops + [header]
                let projected = try project(body, continuation: latch, activeLoops: active, depth: depth + 1)
                let nativeCondition = try input.native(condition)
                let edges = try input.nativeEdges(nativeCondition)
                guard edges.no.targetBlock == continuation else { throw Refusal.unproved }
                let backedge = try input.backedge(to: header)
                let stub = topology.absorbedStubs[condition.branchIndex]
                var members = projected.blocks.union([latch])
                var implicitEdges = [edges.yes, edges.no]
                var implicitBlocks: Set<Int> = [], implicitRows: Set<Int> = []
                if let stub {
                    try claim(stub)
                    let basic = input.cfg.blocks[stub]
                    guard edges.yes.targetBlock == stub, basic.successors == [header],
                          basic.predecessors == [latch], basic.endIndex == basic.startIndex + 1,
                          input.values.groups[basic.startIndex].isEmpty,
                          input.state.groups[basic.startIndex].isEmpty,
                          case let .intrinsic(nil, "branch", arguments) = input.function.instructions[basic.startIndex].operation,
                          arguments == [.immediate(Int64(bitPattern: input.function.instructions[input.cfg.blocks[header].startIndex].source.address))],
                          backedge == (try input.edge(stub, header)) else { throw Refusal.unproved }
                    members.insert(stub); implicitBlocks.insert(stub); implicitRows.insert(basic.startIndex)
                    implicitEdges.append(backedge)
                } else {
                    guard edges.yes == backedge, edges.yes.targetBlock == header else { throw Refusal.unproved }
                }
                let implicit = implicitEdges.allSatisfy { (input.values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }
                let kind: LoopKind = implicit ? .doWhile : .natural
                guard let canonicalNative = input.values.branchConditions[condition.branchIndex] else { throw Refusal.unproved }
                let actualCondition = implicit ? nativeCondition : canonicalNative
                loops[header] = LoopBinding(header: header, latch: latch, exit: continuation, members: members,
                    condition: actualCondition, kind: kind, backedge: backedge, continueEdge: edges.yes,
                    exitEdge: edges.no, absorbedStub: stub, implicitEdges: implicit ? implicitEdges : [],
                    implicitBlocks: implicit ? implicitBlocks : [], implicitRows: implicit ? implicitRows : [])
                if implicit {
                    return Projection(region: .doWhileLoop(body: projected.region, cond: nativeCondition),
                                      entry: header, blocks: members)
                }
                let rawEdges = try input.originalBranchEdges(condition.branchIndex)
                let exitSlot = slot(edges.no, active: active, transfer: .breakLoop(header: header))
                let guardRegion = Region.ifThen(cond: actualCondition, body: exitSlot,
                    join: edges.yes.targetBlock, inverted: edges.no == rawEdges.otherwise)
                var parts = [projected.region, guardRegion, slot(edges.yes, active: active)]
                if let stub { parts += [.block(blockIndex: stub), slot(backedge, active: active)] }
                return Projection(region: .naturalLoop(body: Self.sequence(parts), header: header),
                                  entry: header, blocks: members)
            case let .whileLoop(condition, body, header):
                guard let continuation, loops[header] == nil,
                      (try input.branchBlock(condition)) == header,
                      condition == input.state.branchConditions[condition.branchIndex],
                      let native = input.values.branchConditions[condition.branchIndex] else { throw Refusal.unproved }
                try claim(header)
                let active = activeLoops + [header]
                let projected = try project(body, continuation: header, activeLoops: active, depth: depth + 1)
                let edges = try input.originalBranchEdges(condition.branchIndex)
                let exitEdge = edges.taken.targetBlock == continuation ? edges.taken : edges.otherwise
                let continueEdge = exitEdge == edges.taken ? edges.otherwise : edges.taken
                guard exitEdge.targetBlock == continuation, projected.entry == continueEdge.targetBlock else { throw Refusal.unproved }
                let members = projected.blocks.union([header])
                let backedge = try input.backedge(to: header)
                loops[header] = LoopBinding(header: header, latch: header, exit: continuation, members: members,
                    condition: native, kind: .natural, backedge: backedge, continueEdge: continueEdge,
                    exitEdge: exitEdge, absorbedStub: nil, implicitEdges: [], implicitBlocks: [], implicitRows: [])
                let exitSlot = slot(exitEdge, active: active, transfer: .breakLoop(header: header))
                let guardRegion = Region.ifThen(cond: native, body: exitSlot, join: continueEdge.targetBlock,
                    inverted: exitEdge == edges.otherwise)
                return Projection(region: .naturalLoop(body: Self.sequence([guardRegion,
                    slot(continueEdge, active: active), projected.region]), header: header), entry: header, blocks: members)
            case .naturalLoop, .switchDispatch, .gotoLeaf, .irreducible, .certifiedEdge, .certifiedSelection:
                throw Refusal.unproved
            }
        }
        private static func sequence<S: Sequence>(_ parts: S) -> Region where S.Element == Region {
            let parts = Array(parts)
            return parts.count == 1 ? parts[0] : .sequence(parts)
        }
    }

    /// Extract actual Region control, then compare every ordered original
    /// successor and its complete copy phase. Builder claims are not proof.
    private struct Checker {
        enum Kind { case end, anchor, original(Int), slot(EdgeEmissionSlotID) }
        struct Vertex { let kind: Kind; var next: [Int] }
        struct LoopContext { let header: Int; let breakVertex: Int }
        let input: Input
        let slots: [EdgeEmissionSlotID: EdgeEmissionSlot]
        let loops: [Int: LoopBinding]
        let originalEdges: Set<OriginalEdgeID>
        var graph = [Vertex(kind: .end, next: [])]
        var owned: Set<Int> = []
        var originals: [Int: Int] = [:]
        var usedSlots: Set<EdgeEmissionSlotID> = []
        var usedLoops: Set<Int> = []
        var implicitEdges: Set<OriginalEdgeID> = []
        var budget = 32768

        mutating func verify(_ root: Region) -> Bool {
            guard Set(loops.keys) == input.cfg.loopHeaders,
                  let entry = try? extract(root, next: 0, active: [], depth: 0),
                  owned == Set(input.cfg.blocks.indices), usedSlots == Set(slots.keys),
                  usedLoops == Set(loops.keys),
                  let first = trace(entry, edge: nil), first.block == input.cfg.entryIndex,
                  first.phases.isEmpty else { return false }
            var executedSlots: Set<EdgeEmissionSlotID> = []
            var checkedEdges: Set<OriginalEdgeID> = []
            for block in input.cfg.blocks {
                guard let vertex = originals[block.index],
                      graph[vertex].next.count == block.successors.count else { return false }
                for (ordinal, target) in block.successors.enumerated() {
                    let edge = OriginalEdgeID(sourceBlock: block.index, successorOrdinal: ordinal, targetBlock: target)
                    guard checkedEdges.insert(edge).inserted,
                          let path = trace(graph[vertex].next[ordinal], edge: edge), path.block == target else { return false }
                    if implicitEdges.contains(edge) {
                        guard path.phases.isEmpty, (input.values.edgeCopies[edge.cfgEdge] ?? []).isEmpty else { return false }
                    } else {
                        guard path.phases.count == 1, let id = path.phases.first,
                              let slot = slots[id], slot.phase == .copiesAndTransfer,
                              slot.origins == [edge], executedSlots.insert(id).inserted else { return false }
                    }
                }
            }
            return checkedEdges == originalEdges && executedSlots == Set(slots.keys)
        }
        mutating func add(_ kind: Kind, next: [Int]) -> Int {
            let index = graph.count
            graph.append(Vertex(kind: kind, next: next))
            return index
        }
        mutating func claim(_ block: Int, vertex: Int) throws {
            guard input.cfg.blocks.indices.contains(block), owned.insert(block).inserted,
                  originals[block] == nil else { throw Refusal.unproved }
            originals[block] = vertex
        }
        func validLoop(_ loop: LoopBinding, active: [LoopContext]) throws -> Bool {
            guard loop.header == loop.backedge.targetBlock,
                  loop.backedge == (try input.backedge(to: loop.header)),
                  loop.members == (try input.naturalMembers(loop.backedge)),
                  loop.members.contains(loop.latch), !loop.members.contains(loop.exit),
                  loop.continueEdge.sourceBlock == loop.latch, loop.exitEdge.sourceBlock == loop.latch,
                  loop.exitEdge.targetBlock == loop.exit,
                  loop.members.contains(loop.continueEdge.targetBlock),
                  (try input.branchBlock(loop.condition)) == loop.latch else { return false }
            let branch = try input.originalBranchEdges(loop.condition.branchIndex)
            guard Set([loop.continueEdge, loop.exitEdge]) == Set([branch.taken, branch.otherwise]) else { return false }
            for block in loop.members {
                guard input.cfg.blocks[block].predecessors.allSatisfy({ loop.members.contains($0) || block == loop.header }) else { return false }
                for target in input.cfg.blocks[block].successors where !loop.members.contains(target) {
                    guard (try input.edge(block, target)) == loop.exitEdge else { return false }
                }
            }
            // Lexical containment must exactly represent original containment.
            for ancestor in active {
                guard let outer = loops[ancestor.header], loop.members.isStrictSubset(of: outer.members) else { return false }
            }
            for other in loops.values where other.header != loop.header && other.members.isStrictSuperset(of: loop.members) {
                guard active.contains(where: { $0.header == other.header }) else { return false }
            }
            if let stub = loop.absorbedStub {
                guard input.cfg.blocks.indices.contains(stub), loop.continueEdge.targetBlock == stub,
                      loop.backedge.sourceBlock == stub,
                      input.cfg.blocks[stub].predecessors == [loop.latch],
                      input.cfg.blocks[stub].successors == [loop.header],
                      input.cfg.blocks[stub].endIndex == input.cfg.blocks[stub].startIndex + 1,
                      input.values.groups[input.cfg.blocks[stub].startIndex].isEmpty,
                      input.state.groups[input.cfg.blocks[stub].startIndex].isEmpty,
                      case let .intrinsic(nil, "branch", arguments) = input.function.instructions[input.cfg.blocks[stub].startIndex].operation,
                      arguments == [.immediate(Int64(bitPattern: input.function.instructions[input.cfg.blocks[loop.header].startIndex].source.address))] else { return false }
            }
            if loop.kind == .doWhile {
                let expected = [loop.continueEdge, loop.exitEdge] + (loop.absorbedStub == nil ? [] : [loop.backedge])
                let blocks = Set(loop.absorbedStub.map { [$0] } ?? [])
                let rows = Set(blocks.map { input.cfg.blocks[$0].startIndex })
                let oriented = try input.nativeEdges(loop.condition)
                return loop.implicitEdges == expected && Set(expected).count == expected.count
                    && expected.allSatisfy { (input.values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }
                    && loop.implicitBlocks == blocks && loop.implicitRows == rows
                    && oriented.yes == loop.continueEdge && oriented.no == loop.exitEdge
                    && (loop.absorbedStub != nil || loop.continueEdge == loop.backedge)
            }
            return loop.implicitEdges.isEmpty && loop.implicitBlocks.isEmpty && loop.implicitRows.isEmpty
                && input.values.branchConditions[loop.condition.branchIndex] == loop.condition
        }
        mutating func extract(_ region: Region, next: Int, active: [LoopContext], depth: Int) throws -> Int {
            budget -= 1
            guard budget >= 0, depth < 4096 else { throw Refusal.unproved }
            switch region {
            case let .sequence(parts):
                var cursor = next
                for part in parts.reversed() { cursor = try extract(part, next: cursor, active: active, depth: depth + 1) }
                return cursor
            case let .block(block):
                guard input.cfg.blocks.indices.contains(block),
                      input.values.branchConditions[input.cfg.blocks[block].endIndex - 1] == nil,
                      input.cfg.blocks[block].successors.count <= 1 else { throw Refusal.unproved }
                let terminal = input.cfg.blocks[block].successors.isEmpty
                if terminal {
                    guard case .returnValue = input.function.instructions[input.cfg.blocks[block].endIndex - 1].operation else { throw Refusal.unproved }
                }
                let vertex = add(.original(block), next: terminal ? [] : [next])
                try claim(block, vertex: vertex)
                return vertex
            case let .ifThen(condition, body, join, inverted):
                guard input.cfg.blocks.indices.contains(join),
                      input.values.branchConditions[condition.branchIndex] == condition else { throw Refusal.unproved }
                let block = try input.branchBlock(condition)
                let edges = try input.nativeEdges(condition)
                let bodyEntry = try extract(body, next: next, active: active, depth: depth + 1)
                var successors = [next, next]
                successors[(inverted ? edges.no : edges.yes).successorOrdinal] = bodyEntry
                let vertex = add(.original(block), next: successors)
                try claim(block, vertex: vertex)
                return vertex
            case let .ifThenElse(condition, thenBody, elseBody, join):
                guard input.cfg.blocks.indices.contains(join),
                      input.values.branchConditions[condition.branchIndex] == condition else { throw Refusal.unproved }
                let block = try input.branchBlock(condition)
                let edges = try input.nativeEdges(condition)
                let thenEntry = try extract(thenBody, next: next, active: active, depth: depth + 1)
                let elseEntry = try extract(elseBody, next: next, active: active, depth: depth + 1)
                var successors = [next, next]
                successors[edges.no.successorOrdinal] = thenEntry
                successors[edges.yes.successorOrdinal] = elseEntry
                let vertex = add(.original(block), next: successors)
                try claim(block, vertex: vertex)
                return vertex
            case let .certifiedEdge(id):
                guard let slot = slots[id], slot.id == id, usedSlots.insert(id).inserted,
                      slot.origins.count == 1, let edge = slot.origins.first,
                      originalEdges.contains(edge), slot.phase == .copiesAndTransfer,
                      slot.nearestLoopHeader == active.last?.header else { throw Refusal.unproved }
                switch slot.transfer {
                case .fallthrough: return add(.slot(id), next: [next])
                case let .breakLoop(header):
                    guard let inner = active.last, inner.header == header,
                          let loop = loops[header], loop.kind == .natural,
                          edge == loop.exitEdge else { throw Refusal.unproved }
                    return add(.slot(id), next: [inner.breakVertex])
                }
            case let .doWhileLoop(body, condition):
                let latch = try input.branchBlock(condition)
                guard let loop = loops.values.first(where: { $0.latch == latch }), loop.kind == .doWhile,
                      loop.condition == condition, try validLoop(loop, active: active),
                      usedLoops.insert(loop.header).inserted else { throw Refusal.unproved }
                let before = owned
                let anchor = add(.anchor, next: [])
                let test = add(.original(latch), next: [])
                try claim(latch, vertex: test)
                let stubVertex: Int?
                if let stub = loop.absorbedStub {
                    let vertex = add(.original(stub), next: [])
                    try claim(stub, vertex: vertex); stubVertex = vertex
                } else { stubVertex = nil }
                let context = LoopContext(header: loop.header, breakVertex: next)
                let entry = try extract(body, next: test, active: active + [context], depth: depth + 1)
                guard owned.subtracting(before) == loop.members else { throw Refusal.unproved }
                if let stubVertex { graph[stubVertex].next = [entry] }
                var successors = [next, next]
                successors[loop.continueEdge.successorOrdinal] = stubVertex ?? entry
                successors[loop.exitEdge.successorOrdinal] = next
                graph[test].next = successors; graph[anchor].next = [entry]
                for edge in loop.implicitEdges {
                    guard implicitEdges.insert(edge).inserted else { throw Refusal.unproved }
                }
                return anchor
            case let .naturalLoop(body, header):
                guard let loop = loops[header], loop.kind == .natural,
                      try validLoop(loop, active: active), usedLoops.insert(header).inserted else { throw Refusal.unproved }
                let before = owned
                let anchor = add(.anchor, next: [])
                let context = LoopContext(header: header, breakVertex: next)
                let entry = try extract(body, next: anchor, active: active + [context], depth: depth + 1)
                guard owned.subtracting(before) == loop.members else { throw Refusal.unproved }
                graph[anchor].next = [entry]
                return anchor
            case .whileLoop, .switchDispatch, .gotoLeaf, .irreducible, .certifiedSelection:
                throw Refusal.unproved
            }
        }
        func trace(_ start: Int, edge: OriginalEdgeID?) -> (block: Int, phases: [EdgeEmissionSlotID])? {
            var cursor = start, seen: Set<Int> = [], phases: [EdgeEmissionSlotID] = []
            while graph.indices.contains(cursor), seen.insert(cursor).inserted {
                switch graph[cursor].kind {
                case let .original(block): return (block, phases)
                case .end: return nil
                case .anchor: break
                case let .slot(id):
                    guard let edge, slots[id]?.origins == [edge] else { return nil }
                    phases.append(id)
                }
                guard graph[cursor].next.count == 1 else { return nil }
                cursor = graph[cursor].next[0]
            }
            return nil
        }
    }

    private static func inverted(_ condition: BranchCondition) throws -> BranchCondition {
        let inverse = ["==": "!=", "!=": "==", "<": ">=", ">=": "<", ">": "<=", "<=": ">"]
        guard let op = inverse[condition.condition] else { throw Refusal.unproved }
        var result = condition; result.condition = op
        return result
    }
    private static func sameCFG(_ left: CFG, _ right: CFG) -> Bool {
        left.blocks == right.blocks && left.entryIndex == right.entryIndex &&
        left.domTree == right.domTree && left.postDomTree == right.postDomTree &&
        left.loopHeaders == right.loopHeaders && left.backEdges == right.backEdges &&
        left.irreducibleBlocks == right.irreducibleBlocks &&
        left.blockByStartIndex == right.blockByStartIndex && left.hasUnresolvedTargets == right.hasUnresolvedTargets
    }
}

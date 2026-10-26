import Foundation

/// An input-bound projection into the native Region grammar. This type owns no
/// text, names, casts, payload lowering, or second recursive printer.
struct RegionalOrdinaryControlPlan {
    struct EdgeEmissionSlotID: Hashable, Sendable { let rawValue: Int }
    struct SelectionPlanID: Hashable, Sendable { let rawValue: Int }
    struct OriginalEdgeID: Hashable, Sendable {
        let sourceBlock: Int
        let successorOrdinal: Int
        let targetBlock: Int
        var cfgEdge: CFGEdge { CFGEdge(sourceBlock, targetBlock) }
    }
    enum EdgePhase: Equatable, Sendable { case copiesAndTransfer, copiesOnly, transferOnly }
    enum Transfer: Equatable, Sendable {
        case `fallthrough`
        case gotoLabel(target: Int)
        case breakLoop(header: Int)
        case continueLoop(header: Int)
    }
    struct EdgeEmissionSlot: Sendable {
        let id: EdgeEmissionSlotID
        let origins: [OriginalEdgeID]
        let phase: EdgePhase
        let transfer: Transfer
        let commonTransferAnchor: EdgeEmissionSlotID?
        let nearestLoopHeader: Int?
    }
    struct LabelBinding: Sendable {
        let block: Int
        let address: UInt64
        let name: String
        /// Loop-header labels precede the loop, not its first body statement.
        let isLoopEntry: Bool
    }
    struct SelectionArm: Sendable {
        let caseValues: [Int64]
        let edge: OriginalEdgeID
        let region: Region
    }
    struct SelectionCase: Sendable {
        let value: Int64
        let edge: OriginalEdgeID
    }
    /// Only a bounds-proved, alias-free default-only model edge may disappear
    /// from text. The actual default remains the original B.HI's taken edge.
    struct GuardedDefaultElision: Sendable {
        let dispatchRow: Int
        let guardRow: Int
        let origin: OriginalEdgeID
        let slot: EdgeEmissionSlotID
    }
    struct Selection: Sendable {
        let block: Int
        let row: Int
        let selector: MacIRValue
        let arms: [SelectionArm]
        let defaultArm: SelectionArm
        /// Includes aliases routed to the default body without another test.
        let originalCases: [SelectionCase]
        /// Explicit authority for omitting an impossible, empty BR-default slot.
        let guardedDefault: GuardedDefaultElision?
    }
    enum LoopKind: Equatable, Sendable { case doWhile, natural }
    struct LoopBinding: Sendable {
        let header: Int
        let latch: Int
        let exit: Int
        let members: Set<Int>
        let backedge: OriginalEdgeID
        let exitEdge: OriginalEdgeID
        let condition: BranchCondition
        let kind: LoopKind
    }
    struct ResidualEdge: Sendable {
        let edge: OriginalEdgeID
        let sourceAddress: UInt64
        let targetAddress: UInt64
        let label: String
        let slot: EdgeEmissionSlotID
        let nearestLoopHeader: Int?
        let reason: String
    }

    let root: Region
    let edgeSlots: [EdgeEmissionSlotID: EdgeEmissionSlot]
    let selections: [SelectionPlanID: Selection]
    let labels: [Int: LabelBinding]
    let loops: [Int: LoopBinding]
    let residualEdges: [ResidualEdge]
    let ownedBlocks: Set<Int>
    let ownedRows: Set<Int>
    let originalEdges: Set<OriginalEdgeID>
    private let originalFunction: MacIRFunction
    private let originalCFG: CFG

    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        function == originalFunction && Self.sameCFG(cfg, originalCFG)
    }

    /// A shared edge emits one already-certified sequential copy schedule, not
    /// a union or a new parallel-copy lowering. Source spans remain attached to
    /// each origin in the value plan; the returned first schedule is only the
    /// representative for rendering. Reaching definitions must agree as well
    /// as operations, and no non-copy semantic metadata may be discarded.
    static func commonCopySchedule(for origins: [OriginalEdgeID],
                                   values: RegionalOrdinaryValuePlan) -> [MacIRInstruction]? {
        guard let first = origins.first, Set(origins).count == origins.count else { return nil }
        let reference = values.edgeCopies[first.cfgEdge] ?? []
        let bindings = values.edgeBindings.filter { $0.edge == first.cfgEdge }.sorted { $0.register < $1.register }
        guard Set(bindings.map(\.register)).count == bindings.count else { return nil }
        for origin in origins {
            let schedule = values.edgeCopies[origin.cfgEdge] ?? []
            let incoming = values.edgeBindings.filter { $0.edge == origin.cfgEdge }.sorted { $0.register < $1.register }
            guard schedule.count == reference.count, incoming.count == bindings.count,
                  Set(incoming.map(\.register)).count == incoming.count,
                  zip(incoming, bindings).allSatisfy({
                      $0.register == $1.register && $0.source == $1.source && $0.destination == $1.destination
                  }),
                  zip(schedule, reference).allSatisfy({ instruction, expected in
                      guard case .assign = instruction.operation,
                            instruction.operation == expected.operation else { return false }
                      return instruction == MacIRInstruction(source: instruction.source, operation: instruction.operation)
                  }) else { return nil }
        }
        return reference
    }

    /// A representative copy span must not impersonate an original payload
    /// row on another arm. Shared schedules currently retain only zero-effect
    /// branch provenance; non-control terminal rows keep their separate slots.
    private static func hasBranchCopyProvenance(for origins: [OriginalEdgeID],
                                                function: MacIRFunction, cfg: CFG,
                                                values: RegionalOrdinaryValuePlan) -> Bool {
        origins.allSatisfy { origin in
            guard cfg.blocks.indices.contains(origin.sourceBlock) else { return false }
            let row = cfg.blocks[origin.sourceBlock].endIndex - 1
            guard function.instructions.indices.contains(row) else { return false }
            let terminal = function.instructions[row]
            switch CFGBuilder.terminatorKind(of: terminal.operation) {
            case .conditionalBranch, .unconditionalBranch:
                return (values.edgeCopies[origin.cfgEdge] ?? []).allSatisfy {
                    if function.ssaEnabled, let identity = $0.source.syntheticPhiEdge {
                        return identity.machineAddress == terminal.source.address
                            && identity.blockAddress == function.instructions[cfg.blocks[origin.targetBlock].startIndex].source.address
                    }
                    return $0.source == terminal.source
                }
            default:
                return false
            }
        }
    }

    static func prove(function: MacIRFunction, cfg: CFG,
                      certifiedBy state: RegionalPhysicalStatePlan,
                      values: RegionalOrdinaryValuePlan) -> Self? {
        guard state.matches(function: function, cfg: cfg),
              values.matches(function: function, cfg: cfg),
              values.groups.count == function.instructions.count,
              values.ownedRows == Set(function.instructions.indices) else { return nil }
        var builder = Builder(function: function, cfg: cfg, state: state, values: values)
        guard let root = try? builder.build() else { return nil }
        let targets = Set(builder.slots.values.compactMap { slot -> Int? in
            if case let .gotoLabel(target) = slot.transfer { return target }
            return nil
        })
        var labels: [Int: LabelBinding] = [:]
        var names: Set<String> = []
        for target in targets.sorted() {
            guard cfg.blocks.indices.contains(target) else { return nil }
            let address = function.instructions[cfg.blocks[target].startIndex].source.address
            let name = "L_" + String(address, radix: 16)
            guard names.insert(name).inserted else { return nil }
            labels[target] = LabelBinding(block: target, address: address, name: name,
                                          isLoopEntry: builder.loops[target] != nil)
        }
        var checker = Checker(function: function, cfg: cfg, values: values,
                              slots: builder.slots, selections: builder.selections,
                              loops: builder.loops, labels: labels)
        guard checker.verify(root), checker.owned == Set(cfg.blocks.indices) else { return nil }
        let residuals = builder.slots.values.sorted { $0.id.rawValue < $1.id.rawValue }.flatMap { slot -> [ResidualEdge] in
            guard case let .gotoLabel(target) = slot.transfer, let label = labels[target] else { return [] }
            return slot.origins.map { edge in
                ResidualEdge(edge: edge,
                    sourceAddress: function.instructions[cfg.blocks[edge.sourceBlock].endIndex - 1].source.address,
                    targetAddress: label.address, label: label.name, slot: slot.id,
                    nearestLoopHeader: slot.nearestLoopHeader,
                    reason: "Single-owner shared continuation is not the lexical successor")
            }
        }
        return Self(root: root, edgeSlots: builder.slots, selections: builder.selections,
                    labels: labels, loops: builder.loops, residualEdges: residuals,
                    ownedBlocks: checker.owned, ownedRows: values.ownedRows,
                    originalEdges: builder.allEdges,
                    originalFunction: function, originalCFG: cfg)
    }

    private enum Refusal: Error { case unsupported }
    private struct Scope {
        let atoms: Set<Int>
        let successors: [Int: Set<Int>]
        let predecessors: [Int: Set<Int>]
        let order: [Int]
        let activeLoop: Int?
    }
    private struct Builder {
        let function: MacIRFunction
        let cfg: CFG
        let state: RegionalPhysicalStatePlan
        let values: RegionalOrdinaryValuePlan
        var loops: [Int: LoopBinding] = [:]
        var slots: [EdgeEmissionSlotID: EdgeEmissionSlot] = [:]
        var selections: [SelectionPlanID: Selection] = [:]
        var allEdges: Set<OriginalEdgeID> = []
        var nextSlotID = 0
        var budget = 8192

        mutating func build() throws -> Region {
            let rows = function.instructions
            guard !cfg.blocks.isEmpty, cfg.blocks.count <= 512,
                  !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
                  cfg.blocks.indices.contains(cfg.entryIndex) else { throw Refusal.unsupported }
            var cursor = 0, conditions: Set<Int> = [], dispatches: Set<Int> = []
            for (index, block) in cfg.blocks.enumerated() {
                guard block.index == index, block.startIndex == cursor,
                      block.endIndex > cursor, block.endIndex <= rows.count,
                      Set(block.successors).count == block.successors.count,
                      block.successors.allSatisfy({ cfg.blocks.indices.contains($0) }) else { throw Refusal.unsupported }
                cursor = block.endIndex
                let row = block.endIndex - 1
                switch CFGBuilder.terminatorKind(of: rows[row].operation) {
                case .conditionalBranch:
                    guard block.successors.count == 2 else { throw Refusal.unsupported }
                    conditions.insert(row)
                case .switchDispatch:
                    guard !block.successors.isEmpty else { throw Refusal.unsupported }
                    dispatches.insert(row)
                case .none, .unconditionalBranch:
                    guard block.successors.count == 1 else { throw Refusal.unsupported }
                case .returnTerminator:
                    guard block.successors.isEmpty else { throw Refusal.unsupported }
                case .indirectBranch: throw Refusal.unsupported
                }
                for (ordinal, target) in block.successors.enumerated() {
                    allEdges.insert(OriginalEdgeID(sourceBlock: index, successorOrdinal: ordinal, targetBlock: target))
                }
            }
            guard cursor == rows.count, Set(values.branchConditions.keys) == conditions,
                  Set(state.branchConditions.keys) == conditions,
                  Set(values.switches.keys) == dispatches,
                  Set(state.switches.keys) == dispatches,
                  Set(values.edgeCopies.keys).isSubset(of: Set(allEdges.map(\.cfgEdge))) else { throw Refusal.unsupported }
            var reached: Set<Int> = [], pending = [cfg.entryIndex]
            while let block = pending.popLast() {
                if reached.insert(block).inserted { pending += cfg.blocks[block].successors }
            }
            guard reached == Set(cfg.blocks.indices) else { throw Refusal.unsupported }
            try bindLoops()
            let scope = try makeScope(members: Set(cfg.blocks.indices), activeLoop: nil)
            guard scope.order.first == cfg.entryIndex else { throw Refusal.unsupported }
            return try layout(scope.atoms, continuation: nil, scope: scope, depth: 0)
        }

        mutating func bindLoops() throws {
            var members: [Int: Set<Int>] = [:]
            var latches: [Int: Set<Int>] = [:]
            for edge in cfg.backEdges {
                guard cfg.blocks.indices.contains(edge.from), cfg.blocks.indices.contains(edge.to),
                      cfg.blocks[edge.from].successors.contains(edge.to) else { throw Refusal.unsupported }
                var body: Set<Int> = [edge.from, edge.to]
                var pending = edge.from == edge.to ? [] : [edge.from]
                while let block = pending.popLast() {
                    for predecessor in cfg.blocks[block].predecessors where predecessor != edge.to {
                        if body.insert(predecessor).inserted { pending.append(predecessor) }
                    }
                }
                guard body.allSatisfy({ dominates(edge.to, $0) }) else { throw Refusal.unsupported }
                members[edge.to, default: []].formUnion(body)
                latches[edge.to, default: []].insert(edge.from)
            }
            guard Set(members.keys) == cfg.loopHeaders else { throw Refusal.unsupported }
            // This route currently proves disjoint natural loops only. Nested or
            // multi-latch graphs retain fallback rather than guessing bindings.
            for header in members.keys.sorted() {
                let body = members[header]!
                guard members.keys.allSatisfy({ $0 == header || body.isDisjoint(with: members[$0]!) }),
                      latches[header]?.count == 1, let latch = latches[header]?.first,
                      let condition = values.branchConditions[cfg.blocks[latch].endIndex - 1],
                      condition.compareIndex == nil, condition.continuationGotoTargets.isEmpty,
                      cfg.blocks[latch].successors.count == 2,
                      let backOrdinal = cfg.blocks[latch].successors.firstIndex(of: header) else { throw Refusal.unsupported }
                let exitOrdinal = 1 - backOrdinal, exit = cfg.blocks[latch].successors[exitOrdinal]
                guard !body.contains(exit), body.allSatisfy({ block in
                    cfg.blocks[block].predecessors.allSatisfy { body.contains($0) || block == header }
                        && cfg.blocks[block].successors.allSatisfy { body.contains($0) || (block == latch && $0 == exit) }
                }) else { throw Refusal.unsupported }
                let back = OriginalEdgeID(sourceBlock: latch, successorOrdinal: backOrdinal, targetBlock: header)
                let leaving = OriginalEdgeID(sourceBlock: latch, successorOrdinal: exitOrdinal, targetBlock: exit)
                let normalized: BranchCondition
                if backOrdinal == 0 { normalized = condition }
                else { normalized = try RegionalOrdinaryControlPlan.inverted(condition) }
                let noCopies = (values.edgeCopies[back.cfgEdge] ?? []).isEmpty
                    && (values.edgeCopies[leaving.cfgEdge] ?? []).isEmpty
                loops[header] = LoopBinding(header: header, latch: latch, exit: exit, members: body,
                    backedge: back, exitEdge: leaving, condition: normalized,
                    kind: noCopies ? .doWhile : .natural)
            }
        }

        func dominates(_ header: Int, _ block: Int) -> Bool {
            var cursor = block, seen: Set<Int> = []
            while seen.insert(cursor).inserted {
                if cursor == header { return true }
                guard let next = cfg.domTree[cursor], next != cursor else { return false }
                cursor = next
            }
            return false
        }

        func makeScope(members: Set<Int>, activeLoop: Int?) throws -> Scope {
            var atoms = members, owner: [Int: Int] = [:]
            if activeLoop == nil {
                for loop in loops.values {
                    guard loop.members.isSubset(of: members) else { throw Refusal.unsupported }
                    atoms.subtract(loop.members); atoms.insert(loop.header)
                    for block in loop.members { owner[block] = loop.header }
                }
            }
            for block in atoms where owner[block] == nil { owner[block] = block }
            var successors: [Int: Set<Int>] = [:], predecessors: [Int: Set<Int>] = [:]
            for block in members {
                guard let from = owner[block] else { throw Refusal.unsupported }
                for target in cfg.blocks[block].successors {
                    if let activeLoop, target == activeLoop, cfg.backEdges.contains(CFGEdge(block, target)) { continue }
                    guard members.contains(target), let to = owner[target] else { continue }
                    if from == to {
                        guard activeLoop == nil, loops[from] != nil else { throw Refusal.unsupported }
                        continue
                    }
                    successors[from, default: []].insert(to)
                    predecessors[to, default: []].insert(from)
                }
            }
            var incoming = Dictionary(uniqueKeysWithValues: atoms.map { ($0, predecessors[$0]?.count ?? 0) })
            var ready = atoms.filter { incoming[$0] == 0 }.sorted(), order: [Int] = []
            while !ready.isEmpty {
                let next = ready.removeFirst(); order.append(next)
                for target in (successors[next] ?? []).sorted() {
                    incoming[target]! -= 1
                    if incoming[target] == 0 { ready.append(target); ready.sort() }
                }
            }
            guard order.count == atoms.count else { throw Refusal.unsupported }
            return Scope(atoms: atoms, successors: successors, predecessors: predecessors,
                         order: order, activeLoop: activeLoop)
        }

        func reachable(_ entry: Int, in owned: Set<Int>, scope: Scope) -> Set<Int> {
            var result: Set<Int> = [], pending = [entry]
            while let block = pending.popLast() {
                guard owned.contains(block), result.insert(block).inserted else { continue }
                pending.append(contentsOf: scope.successors[block] ?? [])
            }
            return result
        }

        /// Arm ownership is the exclusive reach set, pruned until every entry
        /// comes from that arm or its actual branching predecessor. Shared tails
        /// remain in their common sequence; address order is only a tie breaker.
        func privateArms(_ block: Int, successors: [Int], pending: Set<Int>, scope: Scope) -> [Set<Int>] {
            let reaches = successors.map { reachable($0, in: pending, scope: scope) }
            return reaches.indices.map { index in
                let other = reaches.indices.filter { $0 != index }.reduce(into: Set<Int>()) { $0.formUnion(reaches[$1]) }
                var owned = reaches[index].subtracting(other)
                var changed = true
                while changed {
                    let invalid = owned.filter { target in
                        !(scope.predecessors[target] ?? []).allSatisfy { owned.contains($0) || $0 == block }
                    }
                    changed = !invalid.isEmpty
                    owned.subtract(invalid)
                }
                if !owned.contains(successors[index]) { return [] }
                return owned
            }
        }

        mutating func layout(_ owned: Set<Int>, continuation: Int?, scope: Scope, depth: Int) throws -> Region {
            guard depth <= 128 else { throw Refusal.unsupported }
            var pending = owned, parts: [Region] = []
            while let block = scope.order.first(where: { pending.contains($0) }) {
                budget -= 1
                guard budget >= 0 else { throw Refusal.unsupported }
                pending.remove(block)
                if scope.activeLoop == nil, let loop = loops[block] {
                    let next = scope.order.first(where: { pending.contains($0) }) ?? continuation
                    guard next == loop.exit else { throw Refusal.unsupported }
                    let bodyMembers = loop.kind == .doWhile ? loop.members.subtracting([loop.latch]) : loop.members
                    let inner = try makeScope(members: bodyMembers, activeLoop: loop.header)
                    if !bodyMembers.isEmpty {
                        guard inner.order.first == loop.header else { throw Refusal.unsupported }
                    }
                    let body = try layout(inner.atoms,
                        continuation: loop.kind == .doWhile ? loop.latch : loop.header,
                        scope: inner, depth: depth + 1)
                    if loop.kind == .doWhile {
                        parts.append(.doWhileLoop(body: body, cond: loop.condition))
                    } else {
                        parts.append(.naturalLoop(body: body, header: loop.header))
                    }
                    continue
                }
                let basic = cfg.blocks[block], row = basic.endIndex - 1
                if let condition = values.branchConditions[row] {
                    guard condition.branchIndex == row, condition.compareIndex == nil,
                          condition.continuationGotoTargets.isEmpty else { throw Refusal.unsupported }
                    let ownedArms = privateArms(block, successors: basic.successors, pending: pending, scope: scope)
                    for arm in ownedArms { pending.subtract(arm) }
                    guard let next = scope.order.first(where: { pending.contains($0) }) ?? continuation else { throw Refusal.unsupported }
                    let taken = try arm(block: block, ordinal: 0, owned: ownedArms[0], next: next, scope: scope, depth: depth)
                    let otherwise = try arm(block: block, ordinal: 1, owned: ownedArms[1], next: next, scope: scope, depth: depth)
                    let branch = Region.ifThenElse(cond: condition, then: otherwise, els: taken, join: next)
                    parts.append(try factorCommonTransfer(branch))
                } else if let operation = values.switches[row] {
                    guard case let .switchDispatch(selector, cases, optionalDefault) = operation,
                          let defaultValue = optionalDefault,
                          let defaultTarget = targetBlock(defaultValue),
                          let defaultOrdinal = basic.successors.firstIndex(of: defaultTarget),
                          let original = state.switches[row],
                          original.successorBlocks == basic.successors else { throw Refusal.unsupported }
                    let ownedArms = privateArms(block, successors: basic.successors, pending: pending, scope: scope)
                    for ownedArm in ownedArms { pending.subtract(ownedArm) }
                    guard let next = scope.order.first(where: { pending.contains($0) }) ?? continuation else { throw Refusal.unsupported }
                    var originalCases: [SelectionCase] = [], caseValues: [Int: [Int64]] = [:], seen: Set<Int64> = []
                    for item in cases {
                        guard seen.insert(item.value).inserted, let target = targetBlock(item.target),
                              let ordinal = basic.successors.firstIndex(of: target) else { throw Refusal.unsupported }
                        let edge = edge(block, ordinal)
                        originalCases.append(SelectionCase(value: item.value, edge: edge))
                        caseValues[ordinal, default: []].append(item.value)
                    }
                    var arms: [SelectionArm] = []
                    for ordinal in basic.successors.indices where ordinal != defaultOrdinal {
                        guard let aliases = caseValues[ordinal], !aliases.isEmpty else { throw Refusal.unsupported }
                        arms.append(SelectionArm(caseValues: aliases, edge: edge(block, ordinal),
                            region: try arm(block: block, ordinal: ordinal, owned: ownedArms[ordinal], next: next, scope: scope, depth: depth)))
                    }
                    let defaultArm = SelectionArm(caseValues: caseValues[defaultOrdinal] ?? [], edge: edge(block, defaultOrdinal),
                        region: try arm(block: block, ordinal: defaultOrdinal, owned: ownedArms[defaultOrdinal], next: next, scope: scope, depth: depth))
                    // Only the retained typed guard can discharge a default-only slot.
                    let guardedDefault = guardedDefaultElision(row: row, selector: selector,
                        cases: originalCases, arm: defaultArm, guardRow: original.guardRow)
                    let id = SelectionPlanID(rawValue: selections.count)
                    selections[id] = Selection(block: block, row: row, selector: selector, arms: arms,
                        defaultArm: defaultArm, originalCases: originalCases, guardedDefault: guardedDefault)
                    parts.append(.certifiedSelection(id))
                } else {
                    parts.append(.block(blockIndex: block))
                    if !basic.successors.isEmpty {
                        guard basic.successors.count == 1 else { throw Refusal.unsupported }
                        let next = scope.order.first(where: { pending.contains($0) }) ?? continuation
                        parts.append(try route(edge(block, 0), next: next, scope: scope))
                    }
                }
            }
            return RegionalOrdinaryControlPlan.sequence(parts)
        }

        /// Domain exhaustion alone is insufficient: preserve the exact guard
        /// read and omit no aliases, payload blocks, copies or shared edge phases.
        func guardedDefaultElision(row: Int, selector: MacIRValue, cases: [SelectionCase],
                                   arm: SelectionArm, guardRow: Int) -> GuardedDefaultElision? {
            guard !cases.isEmpty,
                  cases.enumerated().allSatisfy({ $0.element.value == Int64($0.offset) }),
                  arm.caseValues.isEmpty,
                  cases.allSatisfy({ $0.edge != arm.edge }),
                  let bounds = values.branchConditions[guardRow], bounds.branchIndex == guardRow,
                  bounds.condition == ">", bounds.left == selector,
                  bounds.right == .unary(op: "(uint32_t)", value: .immediate(Int64(cases.count - 1))),
                  case let .certifiedEdge(id) = arm.region, let slot = slots[id],
                  slot.origins == [arm.edge], slot.phase == .copiesAndTransfer,
                  slot.commonTransferAnchor == nil,
                  (values.edgeCopies[arm.edge.cfgEdge] ?? []).isEmpty else { return nil }
            return GuardedDefaultElision(dispatchRow: row, guardRow: guardRow,
                                         origin: arm.edge, slot: id)
        }

        func targetBlock(_ value: MacIRValue) -> Int? {
            guard let address = CFGBuilder.address(of: value) else { return nil }
            return cfg.blocks.first { function.instructions[$0.startIndex].source.address == address }?.index
        }
        func edge(_ block: Int, _ ordinal: Int) -> OriginalEdgeID {
            OriginalEdgeID(sourceBlock: block, successorOrdinal: ordinal,
                           targetBlock: cfg.blocks[block].successors[ordinal])
        }
        mutating func arm(block: Int, ordinal: Int, owned: Set<Int>, next: Int, scope: Scope, depth: Int) throws -> Region {
            let original = edge(block, ordinal)
            if owned.isEmpty { return try route(original, next: next, scope: scope) }
            guard scope.order.first(where: { owned.contains($0) }) == original.targetBlock else { throw Refusal.unsupported }
            let prefix = try route(original, next: original.targetBlock, scope: scope)
            return RegionalOrdinaryControlPlan.sequence([prefix, try layout(owned, continuation: next, scope: scope, depth: depth + 1)])
        }
        mutating func route(_ original: OriginalEdgeID, next: Int?, scope: Scope) throws -> Region {
            let transfer: Transfer
            if let header = scope.activeLoop, let loop = loops[header], original == loop.exitEdge {
                guard loop.kind == .natural else { throw Refusal.unsupported }
                transfer = .breakLoop(header: header)
            } else if original.targetBlock == next {
                transfer = .fallthrough
            } else {
                // Backedges are represented by a real loop only, never a goto
                // into a body or a continue to the wrong do/while test point.
                guard !cfg.backEdges.contains(original.cfgEdge) else { throw Refusal.unsupported }
                transfer = .gotoLabel(target: original.targetBlock)
            }
            let id = allocateSlotID()
            slots[id] = EdgeEmissionSlot(id: id, origins: [original], phase: .copiesAndTransfer,
                                         transfer: transfer, commonTransferAnchor: nil,
                                         nearestLoopHeader: scope.activeLoop)
            return .certifiedEdge(id)
        }

        mutating func allocateSlotID() -> EdgeEmissionSlotID {
            let id = EdgeEmissionSlotID(rawValue: nextSlotID)
            nextSlotID += 1
            return id
        }

        /// Only terminal edge schedules are factored. Predicates and original
        /// payload blocks remain in their arms. A nonempty schedule can move
        /// after the conditional only when both certified sequential schedules
        /// and their reaching-definition bindings agree exactly.
        mutating func factorCommonTransfer(_ region: Region) throws -> Region {
            guard case let .ifThenElse(condition, thenBody, elseBody, join) = region,
                  let left = terminalSlot(thenBody), let right = terminalSlot(elseBody), left != right,
                  let a = slots[left], let b = slots[right],
                  a.phase == .copiesAndTransfer, b.phase == .copiesAndTransfer,
                  a.transfer == b.transfer, a.nearestLoopHeader == b.nearestLoopHeader,
                  case .gotoLabel = a.transfer else { return region }
            let origins = a.origins + b.origins
            guard Set(origins).count == origins.count else { throw Refusal.unsupported }
            if origins.contains(where: { !(values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }) {
                guard RegionalOrdinaryControlPlan.hasBranchCopyProvenance(for: origins, function: function, cfg: cfg, values: values),
                      let copies = RegionalOrdinaryControlPlan.commonCopySchedule(for: origins, values: values),
                      !copies.isEmpty else { return region }
                let thenPrefix = try removingTerminalSlot(thenBody, id: left)
                let elsePrefix = try removingTerminalSlot(elseBody, id: right)
                // Keep the original predicate even when factoring would leave
                // neither arm with payload. Never erase it to obtain sharing.
                guard !hasOnlyEmptyEdgeSlots(thenPrefix) || !hasOnlyEmptyEdgeSlots(elsePrefix) else { return region }
                let id = allocateSlotID()
                slots.removeValue(forKey: left)
                slots.removeValue(forKey: right)
                slots[id] = EdgeEmissionSlot(id: id, origins: origins, phase: .copiesAndTransfer,
                    transfer: a.transfer, commonTransferAnchor: nil, nearestLoopHeader: a.nearestLoopHeader)
                return RegionalOrdinaryControlPlan.sequence([
                    .ifThenElse(cond: condition, then: thenPrefix, els: elsePrefix, join: join), .certifiedEdge(id)
                ])
            }
            let id = allocateSlotID()
            slots[left] = EdgeEmissionSlot(id: left, origins: a.origins, phase: .copiesOnly,
                transfer: .fallthrough, commonTransferAnchor: id, nearestLoopHeader: a.nearestLoopHeader)
            slots[right] = EdgeEmissionSlot(id: right, origins: b.origins, phase: .copiesOnly,
                transfer: .fallthrough, commonTransferAnchor: id, nearestLoopHeader: b.nearestLoopHeader)
            slots[id] = EdgeEmissionSlot(id: id, origins: origins, phase: .transferOnly,
                transfer: a.transfer, commonTransferAnchor: nil, nearestLoopHeader: a.nearestLoopHeader)
            return RegionalOrdinaryControlPlan.sequence([.ifThenElse(cond: condition, then: thenBody, els: elseBody, join: join), .certifiedEdge(id)])
        }
        func hasOnlyEmptyEdgeSlots(_ region: Region) -> Bool {
            switch region {
            case let .sequence(parts): return parts.allSatisfy(hasOnlyEmptyEdgeSlots)
            case let .certifiedEdge(id):
                guard let slot = slots[id], slot.transfer == .fallthrough else { return false }
                return slot.phase == .transferOnly || slot.origins.allSatisfy { (values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }
            default: return false
            }
        }
        func removingTerminalSlot(_ region: Region, id: EdgeEmissionSlotID) throws -> Region {
            switch region {
            case let .certifiedEdge(candidate) where candidate == id:
                return .sequence([])
            case let .sequence(parts):
                guard let last = parts.last else { throw Refusal.unsupported }
                return RegionalOrdinaryControlPlan.sequence(Array(parts.dropLast()) + [try removingTerminalSlot(last, id: id)])
            default:
                throw Refusal.unsupported
            }
        }
        func terminalSlot(_ region: Region) -> EdgeEmissionSlotID? {
            switch region {
            case let .certifiedEdge(id): return id
            case let .sequence(parts): return parts.last.flatMap(terminalSlot)
            default: return nil
            }
        }
    }

    /// Independent extraction of the actual native Region grammar, including
    /// lexical loop semantics and every edge-copy phase. A successful layout is
    /// a proposal until this checker proves its ordered successor relation.
    private struct Checker {
        enum ScopePart: Equatable { case arm(Int, Int), loop(Int) }
        enum Kind { case end, anchor, original(Int), slot(EdgeEmissionSlotID) }
        struct Vertex {
            let kind: Kind
            var next: [Int]
            let scope: [ScopePart]
            var gotoTarget: Int?
        }
        struct LoopContext {
            let header: Int
            let breakVertex: Int
            let continueVertex: Int
        }
        let function: MacIRFunction
        let cfg: CFG
        let values: RegionalOrdinaryValuePlan
        let slots: [EdgeEmissionSlotID: EdgeEmissionSlot]
        let selections: [SelectionPlanID: Selection]
        let loops: [Int: LoopBinding]
        let labels: [Int: LabelBinding]
        var graph = [Vertex(kind: .end, next: [], scope: [], gotoTarget: nil)]
        var owned: Set<Int> = []
        var originalVertices: [Int: Int] = [:]
        var labelVertices: [Int: Int] = [:]
        var usedSlots: Set<EdgeEmissionSlotID> = []
        var usedSelections: Set<SelectionPlanID> = []
        var usedLoops: Set<Int> = []
        var consumedLoopEdges: Set<OriginalEdgeID> = []
        var budget = 16384

        mutating func verify(_ root: Region) -> Bool {
            guard let entry = try? extract(root, next: 0, scope: [], active: [], depth: 0),
                  owned == Set(cfg.blocks.indices), usedSlots == Set(slots.keys),
                  usedSelections == Set(selections.keys), usedLoops == Set(loops.keys) else { return false }
            for index in graph.indices {
                guard let target = graph[index].gotoTarget else { continue }
                guard let label = labels[target], label.block == target,
                      label.address == function.instructions[cfg.blocks[target].startIndex].source.address,
                      label.name == "L_" + String(label.address, radix: 16),
                      label.isLoopEntry == (loops[target] != nil),
                      let destination = labelVertices[target],
                      isPrefix(graph[destination].scope, of: graph[index].scope) else { return false }
                graph[index].next = [destination]
            }
            guard let first = trace(entry, edge: nil), first.block == cfg.entryIndex,
                  first.phases.isEmpty else { return false }
            var executedOrigins: [EdgeEmissionSlotID: Set<OriginalEdgeID>] = [:]
            for block in cfg.blocks {
                guard let vertex = originalVertices[block.index],
                      graph[vertex].next.count == block.successors.count else { return false }
                for (ordinal, target) in block.successors.enumerated() {
                    let edge = OriginalEdgeID(sourceBlock: block.index, successorOrdinal: ordinal, targetBlock: target)
                    guard let path = trace(graph[vertex].next[ordinal], edge: edge), path.block == target else { return false }
                    for id in path.phases { executedOrigins[id, default: []].insert(edge) }
                    if consumedLoopEdges.contains(edge) {
                        guard path.phases.isEmpty, (values.edgeCopies[edge.cfgEdge] ?? []).isEmpty else { return false }
                    } else {
                        guard !path.phases.isEmpty else { return false }
                        let phases = path.phases.compactMap { slots[$0] }
                        guard phases.count == path.phases.count,
                              phases.filter({ $0.phase != .transferOnly }).count == 1,
                              phases.filter({ $0.phase != .copiesOnly }).count == 1 else { return false }
                        if phases.count == 1 {
                            guard phases[0].phase == .copiesAndTransfer,
                                  phases[0].origins.contains(edge), phases[0].commonTransferAnchor == nil else { return false }
                        } else {
                            guard phases.count == 2, phases[0].phase == .copiesOnly,
                                  phases[1].phase == .transferOnly,
                                  phases[0].origins == [edge],
                                  phases[0].commonTransferAnchor == phases[1].id,
                                  phases[1].commonTransferAnchor == nil else { return false }
                        }
                    }
                }
            }
            guard Set(executedOrigins.keys) == Set(slots.keys) else { return false }
            for (id, slot) in slots {
                guard executedOrigins[id] == Set(slot.origins) else { return false }
            }
            // Every referenced label is needed by an actual residual statement;
            // there is no decorative label or alternate owner hidden in context.
            let needed = Set(slots.values.compactMap { slot -> Int? in
                if case let .gotoLabel(target) = slot.transfer { return target }; return nil
            })
            return needed == Set(labels.keys)
        }

        func isPrefix(_ prefix: [ScopePart], of value: [ScopePart]) -> Bool {
            prefix.count <= value.count && Array(value.prefix(prefix.count)) == prefix
        }
        mutating func add(_ kind: Kind, next: [Int], scope: [ScopePart], target: Int? = nil) -> Int {
            let index = graph.count
            graph.append(Vertex(kind: kind, next: next, scope: scope, gotoTarget: target))
            return index
        }
        mutating func claim(_ block: Int, vertex: Int) throws {
            guard cfg.blocks.indices.contains(block), owned.insert(block).inserted else { throw Refusal.unsupported }
            originalVertices[block] = vertex
            if labelVertices[block] == nil { labelVertices[block] = vertex }
        }
        func validLoop(_ binding: LoopBinding) -> Bool {
            guard cfg.loopHeaders.contains(binding.header),
                  cfg.blocks.indices.contains(binding.latch),
                  binding.backedge.sourceBlock == binding.latch,
                  binding.backedge.targetBlock == binding.header,
                  binding.exitEdge.sourceBlock == binding.latch,
                  binding.exitEdge.targetBlock == binding.exit,
                  Set([binding.backedge.successorOrdinal, binding.exitEdge.successorOrdinal]) == Set([0, 1]),
                  cfg.blocks[binding.latch].successors.count == 2,
                  cfg.blocks[binding.latch].successors[binding.backedge.successorOrdinal] == binding.header,
                  cfg.blocks[binding.latch].successors[binding.exitEdge.successorOrdinal] == binding.exit,
                  Set(cfg.backEdges.filter({ $0.to == binding.header })) == Set([binding.backedge.cfgEdge]) else { return false }
            var members: Set<Int> = [binding.header, binding.latch]
            var pending = binding.header == binding.latch ? [] : [binding.latch]
            while let block = pending.popLast() {
                guard cfg.blocks.indices.contains(block) else { return false }
                for predecessor in cfg.blocks[block].predecessors where predecessor != binding.header {
                    if members.insert(predecessor).inserted { pending.append(predecessor) }
                }
            }
            return members == binding.members && !members.contains(binding.exit)
                && members.allSatisfy { block in
                    cfg.blocks[block].predecessors.allSatisfy { members.contains($0) || block == binding.header }
                    && cfg.blocks[block].successors.allSatisfy { members.contains($0) || (block == binding.latch && $0 == binding.exit) }
                }
        }
        func branchBlock(_ condition: BranchCondition) throws -> Int {
            guard condition.compareIndex == nil, condition.continuationGotoTargets.isEmpty,
                  let block = cfg.blocks.first(where: { $0.endIndex - 1 == condition.branchIndex }),
                  block.successors.count == 2,
                  values.branchConditions[condition.branchIndex] != nil else { throw Refusal.unsupported }
            return block.index
        }
        mutating func extract(_ region: Region, next: Int, scope: [ScopePart],
                              active: [LoopContext], depth: Int) throws -> Int {
            budget -= 1
            guard budget >= 0, depth <= 256 else { throw Refusal.unsupported }
            switch region {
            case let .sequence(parts):
                var cursor = next
                for part in parts.reversed() {
                    cursor = try extract(part, next: cursor, scope: scope, active: active, depth: depth + 1)
                }
                return cursor
            case let .block(block):
                guard cfg.blocks.indices.contains(block),
                      values.branchConditions[cfg.blocks[block].endIndex - 1] == nil,
                      values.switches[cfg.blocks[block].endIndex - 1] == nil,
                      cfg.blocks[block].successors.count <= 1 else { throw Refusal.unsupported }
                let exits = cfg.blocks[block].successors.isEmpty ? [] : [next]
                let id = add(.original(block), next: exits, scope: scope)
                try claim(block, vertex: id)
                return id
            case let .ifThenElse(condition, thenBody, elseBody, join):
                let block = try branchBlock(condition)
                guard cfg.blocks.indices.contains(join),
                      values.branchConditions[condition.branchIndex] == condition else { throw Refusal.unsupported }
                // Native Region convention: then = original fallthrough.
                let thenEntry = try extract(thenBody, next: next,
                    scope: scope + [.arm(condition.branchIndex, 1)], active: active, depth: depth + 1)
                let elseEntry = try extract(elseBody, next: next,
                    scope: scope + [.arm(condition.branchIndex, 0)], active: active, depth: depth + 1)
                let id = add(.original(block), next: [elseEntry, thenEntry], scope: scope)
                try claim(block, vertex: id)
                return id
            case let .certifiedEdge(slotID):
                guard let slot = slots[slotID], slot.id == slotID,
                      usedSlots.insert(slotID).inserted,
                      !slot.origins.isEmpty, Set(slot.origins).count == slot.origins.count,
                      slot.nearestLoopHeader == active.last?.header else { throw Refusal.unsupported }
                for edge in slot.origins {
                    guard cfg.blocks.indices.contains(edge.sourceBlock),
                          cfg.blocks[edge.sourceBlock].successors.indices.contains(edge.successorOrdinal),
                          cfg.blocks[edge.sourceBlock].successors[edge.successorOrdinal] == edge.targetBlock else { throw Refusal.unsupported }
                }
                if slot.phase == .copiesOnly {
                    guard slot.transfer == .fallthrough, slot.origins.count == 1,
                          let anchor = slot.commonTransferAnchor,
                          slots[anchor]?.phase == .transferOnly else { throw Refusal.unsupported }
                } else {
                    guard slot.commonTransferAnchor == nil else { throw Refusal.unsupported }
                }
                if slot.phase == .copiesAndTransfer, slot.origins.count > 1 {
                    guard case .gotoLabel = slot.transfer,
                          RegionalOrdinaryControlPlan.hasBranchCopyProvenance(for: slot.origins, function: function, cfg: cfg, values: values),
                          let copies = RegionalOrdinaryControlPlan.commonCopySchedule(for: slot.origins, values: values),
                          !copies.isEmpty else { throw Refusal.unsupported }
                } else if slot.phase == .transferOnly {
                    // Empty-copy factoring retains its original split phases.
                    guard slot.origins.count > 1,
                          slot.origins.allSatisfy({ (values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }) else { throw Refusal.unsupported }
                }
                switch slot.transfer {
                case .fallthrough:
                    return add(.slot(slotID), next: [next], scope: scope)
                case let .gotoLabel(target):
                    guard slot.phase != .copiesOnly, slot.origins.allSatisfy({ $0.targetBlock == target }) else { throw Refusal.unsupported }
                    return add(.slot(slotID), next: [], scope: scope, target: target)
                case let .breakLoop(header):
                    guard slot.phase != .copiesOnly, let loop = active.last, loop.header == header,
                          let binding = loops[header],
                          slot.origins.allSatisfy({ $0 == binding.exitEdge }) else { throw Refusal.unsupported }
                    return add(.slot(slotID), next: [loop.breakVertex], scope: scope)
                case let .continueLoop(header):
                    guard slot.phase != .copiesOnly, let loop = active.last, loop.header == header,
                          let binding = loops[header], binding.kind == .natural,
                          slot.origins.allSatisfy({ $0 == binding.backedge }) else { throw Refusal.unsupported }
                    return add(.slot(slotID), next: [loop.continueVertex], scope: scope)
                }
            case let .certifiedSelection(selectionID):
                guard let selection = selections[selectionID], usedSelections.insert(selectionID).inserted,
                      cfg.blocks.indices.contains(selection.block),
                      cfg.blocks[selection.block].endIndex - 1 == selection.row,
                      case let .switchDispatch(selector, cases, optionalDefault)? = values.switches[selection.row],
                      selector == selection.selector, let defaultTarget = optionalDefault,
                      CFGBuilder.address(of: defaultTarget) == function.instructions[cfg.blocks[selection.defaultArm.edge.targetBlock].startIndex].source.address,
                      selection.originalCases.count == cases.count else { throw Refusal.unsupported }
                let allArms = selection.arms + [selection.defaultArm]
                guard Set(allArms.map { $0.edge.successorOrdinal }) == Set(cfg.blocks[selection.block].successors.indices),
                      allArms.count == cfg.blocks[selection.block].successors.count else { throw Refusal.unsupported }
                for (original, planned) in zip(cases, selection.originalCases) {
                    guard original.value == planned.value, planned.edge.sourceBlock == selection.block,
                          CFGBuilder.address(of: original.target) == function.instructions[cfg.blocks[planned.edge.targetBlock].startIndex].source.address else { throw Refusal.unsupported }
                }
                var exits: [Int: Int] = [:]
                for arm in allArms {
                    guard arm.edge.sourceBlock == selection.block,
                          cfg.blocks[selection.block].successors.indices.contains(arm.edge.successorOrdinal),
                          cfg.blocks[selection.block].successors[arm.edge.successorOrdinal] == arm.edge.targetBlock,
                          arm.caseValues == selection.originalCases.filter({ $0.edge == arm.edge }).map(\.value) else { throw Refusal.unsupported }
                    exits[arm.edge.successorOrdinal] = try extract(arm.region, next: next,
                        scope: scope + [.arm(selection.row, arm.edge.successorOrdinal)], active: active, depth: depth + 1)
                }
                let ordered = cfg.blocks[selection.block].successors.indices.compactMap { exits[$0] }
                guard ordered.count == allArms.count else { throw Refusal.unsupported }
                let id = add(.original(selection.block), next: ordered, scope: scope)
                try claim(selection.block, vertex: id)
                return id
            case let .doWhileLoop(body, condition):
                let latch = try branchBlock(condition)
                guard let binding = loops.values.first(where: { $0.latch == latch }), binding.kind == .doWhile,
                      validLoop(binding),
                      binding.condition == condition, usedLoops.insert(binding.header).inserted,
                      let canonical = values.branchConditions[condition.branchIndex] else { throw Refusal.unsupported }
                let expected: BranchCondition
                if binding.backedge.successorOrdinal == 0 { expected = canonical }
                else { expected = try RegionalOrdinaryControlPlan.inverted(canonical) }
                guard condition == expected else { throw Refusal.unsupported }
                let before = owned
                let start = add(.anchor, next: [], scope: scope)
                labelVertices[binding.header] = start
                let latchVertex = add(.original(latch), next: [], scope: scope + [.loop(binding.header)])
                try claim(latch, vertex: latchVertex)
                let context = LoopContext(header: binding.header, breakVertex: next, continueVertex: latchVertex)
                let entry = try extract(body, next: latchVertex, scope: scope + [.loop(binding.header)],
                    active: active + [context], depth: depth + 1)
                guard owned.subtracting(before) == binding.members else { throw Refusal.unsupported }
                var exits = [next, next]
                exits[binding.backedge.successorOrdinal] = entry
                exits[binding.exitEdge.successorOrdinal] = next
                graph[latchVertex].next = exits
                graph[start].next = [entry]
                consumedLoopEdges.insert(binding.backedge); consumedLoopEdges.insert(binding.exitEdge)
                return start
            case let .naturalLoop(body, header):
                guard let binding = loops[header], binding.kind == .natural, validLoop(binding),
                      usedLoops.insert(header).inserted else { throw Refusal.unsupported }
                let before = owned
                let start = add(.anchor, next: [], scope: scope)
                labelVertices[header] = start
                let context = LoopContext(header: header, breakVertex: next, continueVertex: start)
                let entry = try extract(body, next: start, scope: scope + [.loop(header)],
                    active: active + [context], depth: depth + 1)
                guard owned.subtracting(before) == binding.members else { throw Refusal.unsupported }
                graph[start].next = [entry]
                return start
            case .ifThen, .whileLoop, .switchDispatch, .gotoLeaf, .irreducible:
                throw Refusal.unsupported
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
                    guard let edge, let slot = slots[id], slot.origins.contains(edge) else { return nil }
                    phases.append(id)
                }
                guard graph[cursor].next.count == 1 else { return nil }
                cursor = graph[cursor].next[0]
            }
            return nil
        }
    }

    private static func sameCFG(_ left: CFG, _ right: CFG) -> Bool {
        left.blocks == right.blocks && left.entryIndex == right.entryIndex &&
        left.domTree == right.domTree && left.postDomTree == right.postDomTree &&
        left.loopHeaders == right.loopHeaders && left.backEdges == right.backEdges &&
        left.irreducibleBlocks == right.irreducibleBlocks &&
        left.blockByStartIndex == right.blockByStartIndex && left.hasUnresolvedTargets == right.hasUnresolvedTargets
    }
    private static func sequence(_ parts: [Region]) -> Region {
        parts.count == 1 ? parts[0] : .sequence(parts)
    }
    private static func inverted(_ condition: BranchCondition) throws -> BranchCondition {
        let inverses = ["==": "!=", "!=": "==", "<": ">=", ">=": "<", ">": "<=", "<=": ">"]
        guard let op = inverses[condition.condition] else { throw Refusal.unsupported }
        var result = condition; result.condition = op
        return result
    }
}

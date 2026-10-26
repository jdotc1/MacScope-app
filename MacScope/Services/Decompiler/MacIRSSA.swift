import Foundation

/// Architectural SSA planning is independent of instruction emission. A plan is
/// published only after every predecessor slot and every read has been bound.
enum MacIRSSA {
    struct CellSet: Hashable, Sendable {
        private var low: UInt64 = 0
        private var high: UInt64 = 0

        init<S: Sequence>(_ cells: S) where S.Element == Int {
            for cell in cells { insert(cell) }
        }

        init() {}

        mutating func insert(_ cell: Int) {
            guard (0..<99).contains(cell) else { return }
            if cell < 64 { low |= UInt64(1) << cell }
            else { high |= UInt64(1) << (cell - 64) }
        }

        func contains(_ cell: Int) -> Bool {
            guard (0..<99).contains(cell) else { return false }
            if cell < 64 { return low & (UInt64(1) << cell) != 0 }
            return high & (UInt64(1) << (cell - 64)) != 0
        }

        func union(_ other: Self) -> Self {
            var result = self
            result.low |= other.low
            result.high |= other.high
            return result
        }

        mutating func formUnion(_ other: Self) { self = union(other) }

        func subtracting(_ other: Self) -> Self {
            var result = self
            result.low &= ~other.low
            result.high &= ~other.high
            return result
        }

        func intersection(_ other: Self) -> Self {
            var result = self
            result.low &= other.low
            result.high &= other.high
            return result
        }

        var isEmpty: Bool { low == 0 && high == 0 }
        var cells: [Int] { (0..<99).filter(contains) }
    }

    enum ScalarView: Hashable, Sendable {
        case integer, float32, float64, bits, flags, memoryEpoch, qc
    }

    enum DefinitionOrigin: Hashable, Sendable {
        case entry
        case instruction(UInt64)
        case phi(block: Int)
        case callResult(target: String?)
        case callClobber(UInt64)
        case refusal(MacIRRefusal.Reason, UInt64)
    }

    struct Write: Hashable, Sendable {
        var cell: Int
        var bitWidth: Int
        var view: ScalarView
        var origin: DefinitionOrigin

        init(cell: Int, bitWidth: Int, view: ScalarView = .integer,
             origin: DefinitionOrigin = .entry) {
            self.cell = cell
            self.bitWidth = bitWidth
            self.view = view
            self.origin = origin
        }
    }

    struct RowEffects: Hashable, Sendable {
        var address: UInt64
        var reads: CellSet
        var writes: [Write]
        var readViews: [Int: ScalarView]
        var refusals: [MacIRRefusal]

        init(address: UInt64, reads: CellSet, writes: [Write],
             readViews: [Int: ScalarView] = [:], refusals: [MacIRRefusal] = []) {
            self.address = address
            self.reads = reads
            self.writes = writes
            self.readViews = readViews
            self.refusals = refusals
        }
    }

    struct Definition: Hashable, Sendable {
        var id: Int
        var cell: Int
        var bitWidth: Int
        var view: ScalarView
        var origin: DefinitionOrigin
    }

    struct Incoming: Hashable, Sendable {
        enum Predecessor: Hashable, Sendable {
            case functionEntry
            case machine(block: Int, address: UInt64)
        }
        var predecessor: Predecessor
        var definition: Int

        init(predecessorBlock: Int, predecessorAddress: UInt64, definition: Int) {
            self.predecessor = .machine(block: predecessorBlock, address: predecessorAddress)
            self.definition = definition
        }

        init(predecessor: Predecessor, definition: Int) {
            self.predecessor = predecessor
            self.definition = definition
        }

        var machineAddress: UInt64? {
            if case let .machine(_, address) = predecessor { return address }
            return nil
        }

        var publicPredecessor: MacIRPhiPredecessor {
            switch predecessor {
            case .functionEntry: return .functionEntry
            case let .machine(_, address): return .machine(address)
            }
        }
    }

    struct Phi: Hashable, Sendable {
        var block: Int
        var cell: Int
        var destination: Int
        var incoming: [Incoming]
    }

    struct Plan: Hashable, Sendable {
        var definitions: [Definition]
        var phis: [Phi]
        var rowReadBindings: [[Int: Int]]
        var rowWriteBindings: [[Int: Int]]
        /// Entry bindings include the block's phi destinations.
        var blockEntryBindings: [[Int: Int]]
        var blockExitBindings: [[Int: Int]]
        var liveIn: [CellSet]
        var liveOut: [CellSet]
        var aliases: [Int: Int]
        var refusals: [MacIRRefusal]

        func canonicalID(_ id: Int) -> Int {
            var current = id
            while let next = aliases[current], next != current { current = next }
            return current
        }
    }

    enum PlanningError: Error, Equatable {
        case cancelled
        case entryBlockHasPredecessor
        case invalidInput(String)
    }

    private static func defaultWrite(cell: Int) -> Write {
        switch cell {
        case 0...31: return .init(cell: cell, bitWidth: 64, view: .integer)
        case 32...95: return .init(cell: cell, bitWidth: 64, view: .bits)
        case 96: return .init(cell: cell, bitWidth: 4, view: .flags)
        case 97: return .init(cell: cell, bitWidth: 64, view: .memoryEpoch)
        case 98: return .init(cell: cell, bitWidth: 1, view: .qc)
        default: return .init(cell: cell, bitWidth: 32, view: .bits)
        }
    }

    static func plan(
        cfg: MacIRCFG,
        rows: [RowEffects],
        rowIndicesByBlock suppliedRows: [[Int]]? = nil,
        entry: [Write] = [],
        cellCount: Int = 98,
        permitsVirtualEntry: Bool = false,
        cancelled: () -> Bool = { Task.isCancelled },
        beforeRenaming: (() -> Void)? = nil
    ) throws -> Plan {
        func checkpoint() throws {
            if cancelled() { throw PlanningError.cancelled }
        }
        try checkpoint()
        guard cellCount == 98 || cellCount == 99 || cellCount == 101 else {
            throw PlanningError.invalidInput("SSA requires98 cells,99 with QC,or101 with separate exception/control cells")
        }
        let blockCount = cfg.blocks.count
        let blockRows = suppliedRows ?? cfg.blocks.map { Array($0.instructionRange) }
        guard blockRows.count == blockCount,
              cfg.idom.count == blockCount,
              cfg.dominanceFrontier.count == blockCount else {
            throw PlanningError.invalidInput("CFG and row partitions have different sizes")
        }
        if blockCount > 0 {
            guard cfg.blocks.indices.contains(cfg.entry) else {
                throw PlanningError.invalidInput("CFG entry is absent")
            }
            guard cfg.blocks[cfg.entry].predecessors.isEmpty || permitsVirtualEntry else {
                throw PlanningError.entryBlockHasPredecessor
            }
        }
        var rowOwner = [Int](repeating: -1, count: rows.count)
        for block in cfg.blocks {
            try checkpoint()
            guard block.index >= 0, block.index < blockCount,
                  !blockRows[block.index].isEmpty else {
                throw PlanningError.invalidInput("CFG block has no architectural rows")
            }
            for row in blockRows[block.index] {
                guard rows.indices.contains(row), rowOwner[row] == -1 else {
                    throw PlanningError.invalidInput("Architectural row belongs to multiple blocks")
                }
                rowOwner[row] = block.index
            }
            guard block.predecessors.allSatisfy({ cfg.blocks.indices.contains($0) }),
                  block.successors.allSatisfy({ $0.to.map { cfg.blocks.indices.contains($0) } ?? true }),
                  cfg.dominanceFrontier[block.index].allSatisfy({ cfg.blocks.indices.contains($0) }) else {
                throw PlanningError.invalidInput("CFG refers to an absent block")
            }
        }
        guard rowOwner.allSatisfy({ $0 >= 0 }) else {
            throw PlanningError.invalidInput("Architectural row has no CFG block")
        }
        let reachable = Set(cfg.blocks.indices.filter { cfg.idom[$0] >= 0 })
        let unreachable = cfg.blocks.indices.filter { !reachable.contains($0) }
        var rowWrites: [[Write]] = []
        for row in rows {
            var finalWrite: [Int: Write] = [:]
            guard row.reads.cells.allSatisfy({ $0 < cellCount }),
                  row.readViews.keys.allSatisfy({ (0..<cellCount).contains($0) }) else {
                throw PlanningError.invalidInput("Row reads a cell outside the architectural state")
            }
            for write in row.writes {
                guard (0..<cellCount).contains(write.cell), write.bitWidth > 0 else {
                    throw PlanningError.invalidInput("Row defines an invalid cell or width")
                }
                finalWrite[write.cell] = write
            }
            rowWrites.append(finalWrite.keys.sorted().compactMap { finalWrite[$0] })
        }

        // Upward-exposed reads, followed by a least fixed point. Reads from a
        // partially written cell belong in the effects input's read set.
        var uses = [CellSet](repeating: .init(), count: blockCount)
        var writes = [CellSet](repeating: .init(), count: blockCount)
        for block in cfg.blocks {
            try checkpoint()
            for row in blockRows[block.index] {
                uses[block.index].formUnion(rows[row].reads.subtracting(writes[block.index]))
                writes[block.index].formUnion(CellSet(rowWrites[row].map(\.cell)))
            }
        }
        var liveIn = [CellSet](repeating: .init(), count: blockCount)
        var liveOut = liveIn
        var changed = true
        while changed {
            changed = false
            for block in cfg.blocks.reversed() where reachable.contains(block.index) {
                try checkpoint()
                var out = CellSet()
                for successor in block.successors.compactMap(\.to) where reachable.contains(successor) {
                    out.formUnion(liveIn[successor])
                }
                let incoming = uses[block.index].union(out.subtracting(writes[block.index]))
                if incoming != liveIn[block.index] || out != liveOut[block.index] {
                    liveIn[block.index] = incoming
                    liveOut[block.index] = out
                    changed = true
                }
            }
        }

        var phiCells = [CellSet](repeating: .init(), count: blockCount)
        if blockCount > 0 {
            for cell in 0..<cellCount {
                try checkpoint()
                let sites = cfg.blocks.indices.filter {
                    reachable.contains($0) && ($0 == cfg.entry || writes[$0].contains(cell))
                }
                var pending = sites
                var enqueued = Set(sites)
                var cursor = 0
                while cursor < pending.count {
                    try checkpoint()
                    let site = pending[cursor]
                    cursor += 1
                    for frontier in cfg.dominanceFrontier[site] where reachable.contains(frontier) {
                        guard liveIn[frontier].contains(cell), !phiCells[frontier].contains(cell) else { continue }
                        phiCells[frontier].insert(cell)
                        if enqueued.insert(frontier).inserted { pending.append(frontier) }
                    }
                }
            }
        }

        var definitions: [Definition] = []
        func allocate(_ write: Write) -> Int {
            let id = definitions.count
            definitions.append(.init(id: id, cell: write.cell, bitWidth: write.bitWidth,
                                     view: write.view, origin: write.origin))
            return id
        }
        var suppliedEntry: [Int: Write] = [:]
        for write in entry {
            guard (0..<cellCount).contains(write.cell), write.bitWidth > 0 else {
                throw PlanningError.invalidInput("Invalid entry definition")
            }
            suppliedEntry[write.cell] = write
        }
        var entryBindings: [Int: Int] = [:]
        for cell in 0..<cellCount {
            entryBindings[cell] = allocate(suppliedEntry[cell] ?? defaultWrite(cell: cell))
        }
        var opaqueEntries: [Int: [Int: Int]] = [:]
        for block in unreachable {
            try checkpoint()
            var bindings: [Int: Int] = [:]
            for cell in 0..<cellCount {
                var write = defaultWrite(cell: cell)
                write.origin = .refusal(.unreachableBlock, cfg.blocks[block].startAddress)
                bindings[cell] = allocate(write)
            }
            opaqueEntries[block] = bindings
        }
        var phis: [Phi] = []
        var blockPhis = [[Int]](repeating: [], count: blockCount)
        for block in cfg.blocks {
            try checkpoint()
            for cell in phiCells[block.index].cells {
                var write = defaultWrite(cell: cell)
                if cell < 32 { write.bitWidth = 32 }
                write.origin = .phi(block: block.index)
                let id = allocate(write)
                blockPhis[block.index].append(phis.count)
                phis.append(.init(block: block.index, cell: cell, destination: id, incoming: []))
            }
        }
        var rowWriteBindings = [[Int: Int]](repeating: [:], count: rows.count)
        for row in rows.indices {
            for write in rowWrites[row] { rowWriteBindings[row][write.cell] = allocate(write) }
        }
        var rowReadBindings = [[Int: Int]](repeating: [:], count: rows.count)
        var blockEntryBindings = [[Int: Int]](repeating: [:], count: blockCount)
        var blockExitBindings = blockEntryBindings
        var children = [[Int]](repeating: [], count: blockCount)
        for block in cfg.blocks.indices where reachable.contains(block) && block != cfg.entry {
            let parent = cfg.idom[block]
            guard cfg.blocks.indices.contains(parent), parent != block else {
                throw PlanningError.invalidInput("Invalid immediate dominator")
            }
            children[parent].append(block)
        }
        for block in children.indices {
            children[block].sort { cfg.blocks[$0].startAddress < cfg.blocks[$1].startAddress }
        }
        beforeRenaming?()
        try checkpoint()

        // Explicit frames avoid a recursion limit on long dominator chains.
        // Saving the 98-cell map is equivalent to popping version stacks.
        enum WalkEvent { case enter(Int), leave([Int: Int]) }
        var current = entryBindings
        var events: [WalkEvent] = blockCount == 0 ? [] : [.enter(cfg.entry)]
        var visited: Set<Int> = []
        while let event = events.popLast() {
            try checkpoint()
            switch event {
            case let .leave(saved): current = saved
            case let .enter(block):
                guard visited.insert(block).inserted else {
                    throw PlanningError.invalidInput("Dominator tree contains a cycle")
                }
                let saved = current
                for phi in blockPhis[block] { current[phis[phi].cell] = phis[phi].destination }
                blockEntryBindings[block] = current
                for row in blockRows[block] {
                    for cell in rows[row].reads.cells { rowReadBindings[row][cell] = current[cell] }
                    for (cell, id) in rowWriteBindings[row] { current[cell] = id }
                }
                blockExitBindings[block] = current
                events.append(.leave(saved))
                for child in children[block].reversed() { events.append(.enter(child)) }
            }
        }
        guard visited == reachable else {
            throw PlanningError.invalidInput("Dominator tree does not cover reachable blocks")
        }
        // No value crosses an unreachable entry. Its local row definitions may
        // still supply a refused predecessor slot in a reachable successor.
        for block in unreachable {
            try checkpoint()
            current = opaqueEntries[block] ?? [:]
            blockEntryBindings[block] = current
            for row in blockRows[block] {
                for cell in rows[row].reads.cells { rowReadBindings[row][cell] = current[cell] }
                for (cell, id) in rowWriteBindings[row] { current[cell] = id }
            }
            blockExitBindings[block] = current
        }
        for index in phis.indices {
            try checkpoint()
            let phi = phis[index]
            if permitsVirtualEntry, phi.block == cfg.entry,
               !cfg.blocks[cfg.entry].predecessors.isEmpty {
                guard let definition = entryBindings[phi.cell] else {
                    throw PlanningError.invalidInput("Virtual entry has no original entry definition")
                }
                phis[index].incoming.append(.init(predecessor: .functionEntry, definition: definition))
            }
            for predecessor in cfg.blocks[phi.block].predecessors {
                guard let last = blockRows[predecessor].last,
                      let definition = blockExitBindings[predecessor][phi.cell] else {
                    throw PlanningError.invalidInput("Phi predecessor has no reaching definition")
                }
                phis[index].incoming.append(.init(predecessorBlock: predecessor,
                    predecessorAddress: rows[last].address, definition: definition))
            }
        }

        // A repeated definition identity is redundant. Equal constants written
        // by different machine rows remain distinct producers.
        var aliases: [Int: Int] = [:]
        func canonical(_ id: Int) -> Int {
            var current = id
            while let next = aliases[current], next != current { current = next }
            return current
        }
        changed = true
        while changed {
            changed = false
            for phi in phis where aliases[phi.destination] == nil {
                try checkpoint()
                let incoming = Set(phi.incoming.map { canonical($0.definition) }
                    .filter { $0 != phi.destination })
                if incoming.count == 1, let replacement = incoming.first {
                    aliases[phi.destination] = replacement
                    changed = true
                }
            }
        }
        phis.removeAll { aliases[$0.destination] != nil }
        for index in phis.indices {
            for incoming in phis[index].incoming.indices {
                phis[index].incoming[incoming].definition = canonical(phis[index].incoming[incoming].definition)
            }
        }
        for id in Array(aliases.keys) { aliases[id] = canonical(id) }
        for row in rows.indices {
            rowReadBindings[row] = rowReadBindings[row].mapValues(canonical)
            rowWriteBindings[row] = rowWriteBindings[row].mapValues(canonical)
        }
        for block in cfg.blocks.indices {
            blockEntryBindings[block] = blockEntryBindings[block].mapValues(canonical)
            blockExitBindings[block] = blockExitBindings[block].mapValues(canonical)
        }

        changed = true
        while changed {
            changed = false
            for phi in phis {
                try checkpoint()
                let width = phi.incoming.reduce(definitions[phi.destination].bitWidth) {
                    max($0, definitions[$1.definition].bitWidth)
                }
                if width != definitions[phi.destination].bitWidth {
                    definitions[phi.destination].bitWidth = width
                    changed = true
                }
            }
        }

        // View proof uses evidence, rather than seeding every SIMD phi as bits.
        // Propagating use requirements backwards through phi inputs preserves
        // bits whenever any numeric interpretation is unproved or mixed.
        let phiIDs = Set(phis.map(\.destination))
        var viewEvidence: [Int: Set<ScalarView>] = [:]
        for definition in definitions where !phiIDs.contains(definition.id) && aliases[definition.id] == nil {
            viewEvidence[definition.id] = [definition.view]
        }
        for row in rows.indices {
            for (cell, view) in rows[row].readViews {
                if let id = rowReadBindings[row][cell] {
                    viewEvidence[id, default: []].insert(view)
                }
            }
        }
        changed = true
        while changed {
            changed = false
            for phi in phis {
                try checkpoint()
                var evidence = viewEvidence[phi.destination, default: []]
                for incoming in phi.incoming {
                    evidence.formUnion(viewEvidence[incoming.definition, default: []])
                }
                if evidence != viewEvidence[phi.destination, default: []] {
                    viewEvidence[phi.destination] = evidence
                    changed = true
                }
                for incoming in phi.incoming where phiIDs.contains(incoming.definition) {
                    let merged = viewEvidence[incoming.definition, default: []].union(evidence)
                    if merged != viewEvidence[incoming.definition, default: []] {
                        viewEvidence[incoming.definition] = merged
                        changed = true
                    }
                }
            }
        }
        for phi in phis {
            let evidence = viewEvidence[phi.destination, default: []]
            definitions[phi.destination].view = evidence.count == 1 ? (evidence.first ?? .bits) : .bits
        }
        for (alias, target) in aliases {
            definitions[alias].bitWidth = definitions[target].bitWidth
            definitions[alias].view = definitions[target].view
        }
        try checkpoint()
        var seenRefusals: [MacIRRefusal.Reason: Set<MacIRRefusal.Scope>] = [:]
        let refusals = (cfg.refusals + rows.flatMap(\.refusals)).filter {
            // Different escaped cases may share a block and reason while
            // naming different edges. Only duplicate row diagnoses coalesce.
            guard case .row = $0.scope else { return true }
            return seenRefusals[$0.reason, default: []].insert($0.scope).inserted
        }
        return .init(definitions: definitions, phis: phis,
            rowReadBindings: rowReadBindings, rowWriteBindings: rowWriteBindings,
            blockEntryBindings: blockEntryBindings, blockExitBindings: blockExitBindings,
            liveIn: liveIn, liveOut: liveOut, aliases: aliases,
            refusals: refusals)
    }
}

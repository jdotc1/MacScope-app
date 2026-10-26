import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// SOURCE_ONLY / NOT_RUN. Independent document/AST-to-literal-CFG accounting.
/// No production region, value, physical-state or control certificate is an input.
/// This does not replace numerical execution. A topology gap never earns credit.
enum OrdinaryCSourceEdgeLedger {
    typealias C = OrdinaryC
    enum Role: Hashable {
        case taken, notTaken, unconditional, `fallthrough`, tableCase(Int), tableDefault
    }
    struct Origin: Hashable {
        let edge: C.SourceEdge
        let row: Int
        let role: Role
        // A default retains its dispatch identity but physically takes the
        // preceding unsigned bounds guard. It is one account, not two edges.
        var machineRole: Role { role == .tableDefault ? .taken : role }
    }
    struct Block {
        let index: Int
        let rows: Range<Int>
        let successors: [Int]
    }
    struct Dispatch {
        let row: Int
        let targets: [Int] // Case ordinals remain distinct even for equal targets.
        let defaultRow: Int
        let guardRow: Int
    }
    struct Source {
        let rows: [InstructionRow]
        let blocks: [Block]
        let blockAtRow: [Int: Int]
        let origins: Set<Origin>
        let outgoing: [Int: [Origin]]
        let dispatches: [Int: Dispatch]
        let branchTargets: [Int: Int]
        let returns: Set<Int>
        let backedges: Set<C.SourceEdge>
        let naturalLoops: [C.SourceEdge: Set<Int>]
    }
    enum PrintedKind: Equatable { case goto, breakLoop, continueLoop }
    struct PrintedTransfer {
        let span: C.Span
        let kind: PrintedKind
        let nearestLoop: C.Span?
        let pc: Int
        let target: Int
    }
    struct Choice: Equatable {
        let pc: Int
        let expression: C.Span
        let taken: Bool
    }
    struct Route {
        let fromBlock: Int
        let toBlock: Int
        let entryPC: Int
        let destinationPC: Int
        let executedPCs: [Int]
        let choices: [Choice]
        let origins: [Origin]
        let residualSpans: Set<C.Span>
        let structuredTransferSpans: Set<C.Span>
    }
    enum Disposition: Equatable { case residual, structured, mixed, unresolved }
    struct EdgeAccount {
        let origin: Origin
        let disposition: Disposition
        let routeIndices: [Int]
        let residualSpans: Set<C.Span>
    }
    struct ResidualSlot {
        let span: C.Span
        let pc: Int
        let target: Int
        let origins: Set<Origin>
    }
    struct Gap: Equatable { let kind: String; let detail: String }
    struct InfeasibleFallback {
        let entry: Int
        let destination: Int
        let decisions: [Choice]
        let path: [Int]
    }
    struct Report {
        let source: Source
        let anchors: [Int: Int] // Actual compiled PC -> literal source block.
        let anchorRows: [Int: Int]
        let entries: [Int: Set<Int>]
        let printed: [PrintedTransfer]
        let routes: [Route]
        let accounts: [EdgeAccount]
        let residualSlots: [ResidualSlot]
        let gaps: [Gap]
        var infeasiblePrintedTransfers: [PrintedTransfer] = []
        var infeasibleFallbacks: [InfeasibleFallback] = []
        var printedGotoCount: Int { residualSlots.count + infeasiblePrintedTransfers.filter { $0.kind == .goto }.count }
        var residualTopologyOrigins: Set<Origin> {
            Set(accounts.filter { $0.disposition != .structured }.map(\.origin))
        }
        var topologyStructuredOrigins: Set<Origin> {
            Set(accounts.filter { $0.disposition == .structured }.map(\.origin))
        }
        // Literal roles cannot establish historical printed spelling. Baseline
        // already structured some conditionals; no raw-removal credit follows
        // from these topology counts without a separate frozen text-site map.
        var rawAccountingStatus: String { "UNBOUND: require OrdinaryCBaselineTransferOrigins frozen mapping; absent for up/skip" }
        func requireCompleteTopology() throws {
            guard gaps.isEmpty, accounts.allSatisfy({ $0.disposition != .unresolved && $0.disposition != .mixed }),
                  residualSlots.allSatisfy({ !$0.origins.isEmpty }) else {
                throw C.Failure.invalidContract("SOURCE_EDGE_COVERAGE_GAP: " + gaps.map { "\($0.kind): \($0.detail)" }.joined(separator: "; "))
            }
        }
    }
    struct Observation {
        let sourceEdges: [C.SourceEdge]
        let candidateEdges: [C.SourceEdge]
        let possibleOriginGroups: [Set<Origin>] // One set per observed CFG edge; never case-ordinal coverage.
        let observedRouteIndices: [Int]
        let residualOccurrences: [C.Span: [Set<Origin>]]
        // An observation has exact edge credit, never universal value equivalence.
    }
    private static func terminal(_ instruction: C.Instruction) -> Bool {
        switch instruction.node {
        case .returned, .unavailableReturn: return true
        default: return false
        }
    }

    /// For colors, the immutable complete capture supplies ordered dispatch
    /// metadata. Literal direct branches and all block boundaries are rebuilt
    /// here and checked against that frozen capture, not a current CFGBuilder.
    static func source(rows: [InstructionRow], color: RegionalSwitchFixture.Capture? = nil) throws -> Source {
        let expected: [UInt64: (rows: Int, blocks: Int)] = [
            0x26c78: (331,101), 0x2893c: (321,98), 0x3ae18: (216,49), 0x3b774: (188,43), 0x33418: (58,10)]
        guard let start = rows.first?.address, let count = expected[start], rows.count == count.rows,
              rows.enumerated().allSatisfy({ $0.element.address == start + UInt64($0.offset * 4) && $0.element.byteWidth == 4 }) else {
            throw C.Failure.invalidContract("edge ledger is bounded to the five complete frozen streams")
        }
        let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.address,$0.offset) })
        func row(_ text: String) throws -> Int {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("0x"), let address = UInt64(text.dropFirst(2), radix:16), let index = positions[address] else {
                throw C.Failure.invalidContract("literal edge leaves retained stream: \(text)")
            }
            return index
        }
        var dispatches: [Int: Dispatch] = [:]
        if let color {
            guard [UInt64(0x26c78),0x2893c].contains(start), color.input_rows == rows,
                  color.switch_facts.count == 2 else { throw C.Failure.invalidContract("wrong frozen color edge context") }
            for fact in color.switch_facts {
                guard rows.indices.contains(fact.lifted_index), rows[fact.lifted_index].mnemonic == "br",
                      fact.cases.count == 10, let raw = fact.raw_table_targets, raw.count == 10,
                      fact.raw_table_matches_ordered_cases == true, fact.case_values_match_ordinals,
                      let defaultAddress = fact.default_address else { throw C.Failure.invalidContract("incomplete frozen dispatch identity") }
                var targets: [Int] = []
                for (ordinal, item) in fact.cases.enumerated() {
                    guard item.ordinal == ordinal, item.value_decimal == String(ordinal),
                          let address = item.target_address, address == raw[ordinal],
                          try UInt64(bitPattern: item.typed_target.value()) == rows[row(address)].address else {
                        throw C.Failure.invalidContract("frozen dispatch ordinal/target contradiction")
                    }
                    targets.append(try row(address))
                }
                let defaultRow = try row(defaultAddress)
                // The lifted default is a frozen model edge, not an invented
                // physical BR outcome. Its direct range guard witnesses target.
                let guardRow = fact.lifted_index - 6
                guard rows.indices.contains(guardRow), rows[guardRow].mnemonic == "b.hi",
                      try row(rows[guardRow].operands) == defaultRow else {
                    throw C.Failure.invalidContract("dispatch default lacks its original unsigned range-guard target")
                }
                dispatches[fact.lifted_index] = .init(row: fact.lifted_index, targets: targets,
                                                     defaultRow: defaultRow, guardRow: guardRow)
            }
        } else if start == 0x26c78 || start == 0x2893c {
            throw C.Failure.invalidContract("color edges need the original immutable complete capture")
        }
        var targets: [Int: Int] = [:], returns: Set<Int> = [], leaders: Set<Int> = [0]
        for (i, instruction) in rows.enumerated() {
            if conditional(instruction.mnemonic) || instruction.mnemonic == "b" {
                let operand = instruction.operands.split(separator: ",").last.map(String.init) ?? ""
                targets[i] = try row(operand); leaders.insert(targets[i]!)
                if i + 1 < rows.count { leaders.insert(i + 1) }
            } else if instruction.mnemonic == "br" {
                guard let dispatch = dispatches[i] else { throw C.Failure.invalidContract("unbounded indirect source branch") }
                leaders.formUnion(dispatch.targets); leaders.insert(dispatch.defaultRow)
                if i + 1 < rows.count { leaders.insert(i + 1) }
            } else if instruction.mnemonic == "ret" {
                returns.insert(i); if i + 1 < rows.count { leaders.insert(i + 1) }
            }
        }
        let starts = leaders.sorted()
        var blockAt: [Int: Int] = [:], ranges: [Range<Int>] = []
        for (i, first) in starts.enumerated() {
            let range = first..<(i + 1 < starts.count ? starts[i + 1] : rows.count)
            ranges.append(range); for r in range { blockAt[r] = i }
        }
        var blocks: [Block] = [], origins: Set<Origin> = [], outgoing: [Int: [Origin]] = [:]
        for (index, range) in ranges.enumerated() {
            let last = range.upperBound - 1, mnemonic = rows[last].mnemonic
            let defaultDispatch = dispatches.values.first { $0.guardRow == last }
            var roles: [(Role, Int)] = []
            if let dispatch = dispatches[last] {
                roles = dispatch.targets.enumerated().map { (.tableCase($0.offset),$0.element) }
            } else if conditional(mnemonic), let target = targets[last] {
                roles = [(defaultDispatch == nil ? .taken : .tableDefault,target),(.notTaken,last + 1)]
            } else if mnemonic == "b", let target = targets[last] { roles = [(.unconditional,target)] }
            else if mnemonic != "ret" {
                guard last + 1 < rows.count else { throw C.Failure.invalidContract("source falls off frozen body") }
                roles = [(.fallthrough,last + 1)]
            }
            // CFG ordinals use frozen first-distinct-target order. Semantic
            // roles above retain same-target parallel outcomes independently.
            var successors: [Int] = []
            for (_, destination) in roles {
                guard let block = blockAt[destination] else { throw C.Failure.invalidContract("source target not a block") }
                if !successors.contains(block) { successors.append(block) }
            }
            for (role, destination) in roles {
                let block = blockAt[destination]!, ordinal = successors.firstIndex(of:block)!
                let identityRow = role == .tableDefault ? defaultDispatch!.row : last
                let origin = Origin(edge: .init(fromBlock:index,toBlock:block,successorOrdinal:ordinal),
                                    row:identityRow,role:role)
                origins.insert(origin); outgoing[index,default:[]].append(origin)
            }
            blocks.append(.init(index:index,rows:range,successors:successors))
        }
        guard blocks.count == count.blocks, returns.count == 1 else { throw C.Failure.invalidContract("literal block/terminal inventory drift") }
        if let color {
            guard color.cfg_blocks.count == blocks.count else { throw C.Failure.invalidContract("frozen CFG block count") }
            for (block, saved) in zip(blocks,color.cfg_blocks) {
                // Historical captures include the model default at BR. Its
                // physical edge belongs only to the already checked guard.
                let expectedSuccessors: [Int]
                if let dispatch = dispatches[block.rows.upperBound - 1] {
                    let defaultBlock = blockAt[dispatch.defaultRow]!
                    expectedSuccessors = saved.successors.filter {
                        $0 != defaultBlock || dispatch.targets.contains { blockAt[$0] == defaultBlock }
                    }
                } else { expectedSuccessors = saved.successors }
                guard saved.index == block.index, saved.start_index == block.rows.lowerBound,
                      saved.end_index_exclusive == block.rows.upperBound, expectedSuccessors == block.successors else {
                    throw C.Failure.invalidContract("literal CFG disagrees with frozen successor ordinals at block \(block.index)")
                }
            }
        }
        let loops = naturalLoops(blocks:blocks)
        return .init(rows:rows,blocks:blocks,blockAtRow:blockAt,origins:origins,outgoing:outgoing,
                     dispatches:dispatches,branchTargets:targets,returns:returns,
                     backedges:Set(loops.keys),naturalLoops:loops)
    }

    static func analyze(candidate: C.Program, source: Source) throws -> Report {
        try analyze(candidate: candidate, source: source, nativeScalar: nil)
    }

    /// Opt-in native scalar topology only. The internally built certificate owns
    /// this exact Program and complete independent original inventory. Its source
    /// slots and administrative operations are validated again against full routes.
    static func analyzeNativeScalar(_ certificate: NativeScalarSourceAnchors.Certificate) throws -> Report {
        let report = try analyze(candidate: certificate.candidate, source: certificate.inventory.source, nativeScalar: certificate)
        try NativeScalarSourceAnchors.requireRoutes(report, certificate: certificate)
        return report
    }

    private static func analyze(candidate: C.Program, source: Source,
                                nativeScalar: NativeScalarSourceAnchors.Certificate?) throws -> Report {
        guard candidate.contract.rowsByAddress.count == source.rows.count,
              source.rows.enumerated().allSatisfy({ candidate.contract.rowsByAddress[$0.element.address] == $0.offset }) else {
            throw C.Failure.invalidContract("candidate/source edge identity disagreement")
        }
        let inventory = try syntax(candidate,source:source)
        var gaps: [Gap] = [], anchors: [Int:Int] = [:], anchorRows: [Int:Int] = [:]
        if let nativeScalar {
            for (pc, row) in nativeScalar.anchorRows {
                guard candidate.code.indices.contains(pc), source.rows.indices.contains(row),
                      let block = source.blockAtRow[row] else {
                    throw C.Failure.invalidContract("native source-slot anchor is outside its exact parsed program/source")
                }
                anchors[pc] = block; anchorRows[pc] = row
            }
        } else {
        for (pc, instruction) in candidate.code.enumerated() {
            let span: C.Span
            switch instruction.node {
            case let .branch(expression,_,_):
                span = expression.span
                guard let r = try? candidate.row(at:span),
                      conditional(source.rows[r].mnemonic) || source.rows[r].mnemonic == "br" else { continue }
            case .assign, .update, .call, .returned, .unavailableReturn: span = instruction.span
            case let .declaration(_, initializer):
                guard initializer != nil else { continue }; span = instruction.span
            case .nop, .jump, .unresolved: continue
            }
            guard let r = try? candidate.row(at:span), let block = source.blockAtRow[r] else {
                gaps.append(.init(kind:"unowned-effect",detail:"parsed PC \(pc) has no literal row")); continue
            }
            // Copies attributed to a zero-effect source control row are not
            // manufactured source blocks. Their actual PCs remain in every route.
            if case .assign = instruction.node, control(source.rows[r].mnemonic) { continue }
            anchors[pc] = block; anchorRows[pc] = r
        }
        }
        let nativeLoops = try nativeScalar.map { _ in
            try NativeScalarLoopOwnership.bind(candidate: candidate, source: source, anchors: anchors, loops: inventory.loops)
        }
        let segments = try segments(candidate, anchors:anchors)
        var entries: [Int:Set<Int>] = [:]
        for segment in segments {
            guard let from = segment.from else {
                if let to = segment.to, let owner = anchors[to] { entries[owner,default:[]].insert(to) }
                continue
            }
            if let to = segment.to, anchors[from] != anchors[to], let owner = anchors[to] { entries[owner,default:[]].insert(to) }
        }
        let byStart = Dictionary(grouping:segments.filter { $0.from != nil },by:{ $0.from! })
        for block in Set(anchors.values) where entries[block,default:[]].isEmpty {
            gaps.append(.init(kind:"unestablished-block-entry",detail:"block \(block) has no independently traced candidate entry"))
        }
        let represented = Set(anchors.values)
        var routes: [Route] = []
        var infeasiblePCs: Set<Int> = []
        var infeasibleFallbacks: [InfeasibleFallback] = []
        for block in entries.keys.sorted() {
            for entry in entries[block]!.sorted() {
                var work: [(Int,[Int],[Choice],Set<Int>)] = [(entry,[],[],[])]
                while let (pc, prior, choices, visited) = work.popLast() {
                    guard prior.count <= candidate.code.count * 2 else { throw C.Failure.invalidContract("unbounded within-block ledger path") }
                    for segment in byStart[pc,default:[]] {
                        let path = prior + segment.executed, decisions = choices + segment.choices
                        guard let next = segment.to, let targetBlock = anchors[next] else {
                            if terminal(candidate.code[pc]) { continue }
                            gaps.append(.init(kind:"unowned-route-terminal",detail:"block \(block), parsed PC \(pc)")); continue
                        }
                        if targetBlock == block && !visited.contains(next) && next != entry {
                            work.append((next,path,decisions,visited.union([pc]))); continue
                        }
                        if targetBlock == block && next != entry {
                            gaps.append(.init(kind:"internal-cycle",detail:"block \(block) cycles without its entry anchor")); continue
                        }
                        let possibilities = sourcePaths(source, from:block,to:targetBlock,represented:represented)
                        let selected = try selectPath(possibilities, candidate:candidate, source:source, choices:decisions)
                        guard let origins = selected else {
                            if try guardedDispatchFallback(candidate: candidate, source: source, entry: entry,
                                                           destination: next, decisions: decisions, path: path, anchors: anchors) {
                                infeasiblePCs.formUnion(path)
                                infeasibleFallbacks.append(.init(entry: entry, destination: next, decisions: decisions, path: path))
                                continue
                            }
                            gaps.append(.init(kind:"unmapped-source-route",detail:"block \(block)->\(targetBlock), entry PC \(entry), destination PC \(next), source paths \(possibilities.count), choices \(decisions.map { "\($0.pc):\($0.taken):\((try? candidate.row(at:$0.expression)).map(String.init) ?? "nil")" })")); continue
                        }
                        let printed = inventory.transfers.filter { path.contains($0.pc) }
                        let residual = Set(printed.filter { $0.kind == .goto }.map(\.span))
                        let structured = Set(printed.filter { $0.kind != .goto }.map(\.span))
                        var validLoops = true
                        for transfer in printed {
                            guard let position = path.firstIndex(of:transfer.pc) else { continue }
                            let following = path.dropFirst(position + 1).first { anchors[$0] != nil } ?? next
                            if following != next {
                                validLoops = false
                                gaps.append(.init(kind:"intra-block-printed-transfer",detail:"PC \(transfer.pc) precedes another owned source operation before the mapped outgoing edge"))
                            }
                        }
                        for origin in origins where source.backedges.contains(origin.edge) && residual.isEmpty {
                            let owners: [C.Span]
                            if let nativeLoops {
                                owners = inventory.loops.filter { loop in
                                    nativeLoops.owns(origin.edge, span: loop) &&
                                    contains(loop,candidate.code[entry].span) && contains(loop,candidate.code[next].span)
                                }
                                // The original latch's last owned source operation
                                // must belong to this exact nearest lexical loop,
                                // not merely some enclosing ancestor.
                                let latchPC: Int?
                                if represented.contains(origin.edge.fromBlock) {
                                    latchPC = path.last { anchors[$0] == origin.edge.fromBlock }
                                } else if source.blocks[origin.edge.fromBlock].rows.allSatisfy({ source.rows[$0].mnemonic == "b" }) {
                                    // sourcePaths permits only literal B-only
                                    // unrepresented forwarders and retains every
                                    // origin. The final actual owned operation on
                                    // this route therefore supplies the latch site.
                                    latchPC = path.last { anchors[$0] != nil }
                                } else { latchPC = nil }
                                if let loop = owners.first, let latchPC,
                                   nativeLoops.innermost(containing: candidate.code[latchPC].span) == loop {} else {
                                    validLoops = false
                                    gaps.append(.init(kind:"native-backedge-nearest-owner",detail:"\(origin.edge) lacks its own nearest lexical latch"))
                                }
                            } else {
                                owners = inventory.loops.filter { contains($0,candidate.code[entry].span) && contains($0,candidate.code[next].span) }
                            }
                            if owners.count != 1 {
                                validLoops = false
                                gaps.append(.init(kind:"backedge-loop-owner",detail:"\(origin.edge) has \(owners.count) actual lexical loop owners"))
                            }
                        }
                        for transfer in printed where transfer.kind != .goto {
                            guard let loop = transfer.nearestLoop else { throw C.Failure.invalidContract("parsed break/continue lacks nearest loop") }
                            if let nativeLoops {
                                // This bounded scalar product emits no continue.
                                // Do not broaden continue semantics speculatively.
                                guard transfer.kind == .breakLoop else {
                                    throw C.Failure.invalidContract("nativeScalar continue requires a separately proved exact route")
                                }
                                guard let header = nativeLoops.headers[loop], let members = nativeLoops.membersByHeader[header],
                                      members.contains(block), !members.contains(targetBlock),
                                      origins.contains(where: { members.contains($0.edge.fromBlock) && !members.contains($0.edge.toBlock) }) else {
                                    validLoops = false
                                    gaps.append(.init(kind:"native-break-route",detail:"PC \(transfer.pc) lacks an exact exit of its bound nearest source loop"))
                                    continue
                                }
                                // `origins` retains every zero-effect B forwarder;
                                // `path` retains every selected edge-copy PC.
                                continue
                            }
                            let loopBackedges = source.backedges.filter { edge in
                                guard let members = source.naturalLoops[edge] else { return false }
                                let pcs = anchors.keys.filter { members.contains(anchors[$0]!) }
                                return !pcs.isEmpty && pcs.allSatisfy { contains(loop,candidate.code[$0].span) }
                            }
                            if loopBackedges.isEmpty {
                                validLoops = false
                                gaps.append(.init(kind:"unjustified-loop-transfer",detail:"printed transfer PC \(transfer.pc) has no original natural-loop ownership"))
                            }
                        }
                        if validLoops {
                            routes.append(.init(fromBlock:block,toBlock:targetBlock,entryPC:entry,destinationPC:next,
                                                executedPCs:path,choices:decisions,origins:origins,residualSpans:residual,
                                                structuredTransferSpans:structured))
                        }
                    }
                }
            }
        }
        var accounts: [EdgeAccount] = []
        for origin in source.origins.sorted(by:originLess) {
            let indices = routes.indices.filter { routes[$0].origins.contains(origin) }
            let residual = indices.reduce(into:Set<C.Span>()) { $0.formUnion(routes[$1].residualSpans) }
            let anyStructured = indices.contains { routes[$0].residualSpans.isEmpty }
            let disposition: Disposition = indices.isEmpty ? .unresolved : residual.isEmpty ? .structured : anyStructured ? .mixed : .residual
            if disposition == .unresolved { gaps.append(.init(kind:"unaccounted-source-origin",detail:describe(origin))) }
            if disposition == .mixed { gaps.append(.init(kind:"mixed-source-disposition",detail:describe(origin))) }
            accounts.append(.init(origin:origin,disposition:disposition,routeIndices:indices,residualSpans:residual))
        }
        // Printed fallbacks proved impossible receive no physical origin and no
        // historical removal credit. Retain them separately for explicit audit.
        let infeasible = inventory.transfers.filter { transfer in
            infeasiblePCs.contains(transfer.pc) && !routes.contains { $0.executedPCs.contains(transfer.pc) }
        }
        let slots = inventory.transfers.filter { transfer in
            transfer.kind == .goto && !infeasible.contains { $0.pc == transfer.pc }
        }.map { transfer -> ResidualSlot in
            let origins = Set(routes.filter { $0.residualSpans.contains(transfer.span) }.flatMap(\.origins))
            if origins.isEmpty { gaps.append(.init(kind:"unexplained-printed-goto",detail:"PC \(transfer.pc)")) }
            return .init(span:transfer.span,pc:transfer.pc,target:transfer.target,origins:origins)
        }
        for loop in inventory.loops {
            let witnessed = routes.contains { route in
                route.origins.contains { origin in
                    source.backedges.contains(origin.edge) && (nativeLoops?.owns(origin.edge, span: loop) ?? true)
                } && route.residualSpans.isEmpty &&
                contains(loop,candidate.code[route.entryPC].span) && contains(loop,candidate.code[route.destinationPC].span)
            }
            if !witnessed { gaps.append(.init(kind:"one-shot-or-unproved-loop",detail:"native loop token \(loop.first) lacks an independently mapped source backedge")) }
        }
        return .init(source:source,anchors:anchors,anchorRows:anchorRows,entries:entries,printed:inventory.transfers,
                     routes:routes,accounts:accounts,residualSlots:slots,gaps:unique(gaps),
                     infeasiblePrintedTransfers:infeasible, infeasibleFallbacks:infeasibleFallbacks)
    }

    /// Uses only an already completed actual execution. PC reconstruction checks
    /// every recorded transfer against the AST CFG; no reference decision is
    /// consulted until the complete candidate edge sequence has been obtained.
    static func observe(_ report: Report, candidate: C.Program, actual: C.Result,
                        referenceBranches: [RegionalCallOracle.Branch], referenceRowVisits: [Int:Int],
                        referenceReturned: Bool, name: String) throws -> Observation {
        try report.requireCompleteTopology()
        guard actual.returned, !actual.reachedRegionBoundary, referenceReturned else {
            throw C.Failure.invalidContract("edge comparison requires two completed whole-entry executions")
        }
        let trace = try replay(candidate,actual)
        guard let first = trace.pcs.firstIndex(where: { report.anchors[$0] != nil }),
              report.anchors[trace.pcs[first]] == 0 else { throw C.Failure.invalidContract("candidate entry has no block-zero anchor") }
        var cursor = first, edges: [C.SourceEdge] = [], originGroups: [Set<Origin>] = [], routeIndices: [Int] = []
        var occurrences: [C.Span:[Set<Origin>]] = [:]
        while cursor < trace.pcs.count {
            let entry = trace.pcs[cursor]
            guard let block = report.anchors[entry] else { throw C.Failure.invalidContract("lost dynamic candidate anchor") }
            let possible = report.routes.indices.filter { index in
                let route = report.routes[index], end = cursor + route.executedPCs.count
                guard route.entryPC == entry, end < trace.pcs.count,
                      Array(trace.pcs[cursor..<end]) == route.executedPCs, trace.pcs[end] == route.destinationPC else { return false }
                let choices = trace.choices.filter { (cursor..<end).contains($0.offset) }.map(\.choice)
                return choices == route.choices
            }
            if possible.isEmpty {
                let remaining = trace.pcs[cursor...]
                let owners = Set(remaining.compactMap { report.anchors[$0] })
                guard owners == [block], report.source.outgoing[block,default:[]].isEmpty,
                      let last = remaining.last, terminal(candidate.code[last]) else {
                    throw C.Failure.invalidContract("dynamic route is absent from independent static ledger at PC \(entry)")
                }
                break
            }
            guard possible.count == 1 else { throw C.Failure.invalidContract("dynamic route remains ambiguous, no singular origin credited") }
            let index = possible[0], route = report.routes[index]
            routeIndices.append(index)
            let routeEdges = orderedEdges(route.origins)
            edges += routeEdges
            originGroups += routeEdges.map { edge in Set(route.origins.filter { $0.edge == edge }) }
            // Preserve plural roles for genuinely indistinguishable same-target
            // paths. Dynamic history is not permission to choose an arbitrary one.
            for span in route.residualSpans { occurrences[span,default:[]].append(Set(route.origins)) }
            cursor += route.executedPCs.count
        }
        let reference = try sourceTrace(report.source,branches:referenceBranches,rowVisits:referenceRowVisits)
        guard edges == reference else {
            let mismatch = Array(zip(edges,reference)).firstIndex { $0.0 != $0.1 } ?? min(edges.count,reference.count)
            throw C.Failure.semanticMismatch("\(name): complete independent edge sequence differs at event \(mismatch); candidate \(edges.count), source \(reference.count)")
        }
        return .init(sourceEdges:reference,candidateEdges:edges,possibleOriginGroups:originGroups,
                     observedRouteIndices:routeIndices,residualOccurrences:occurrences)
    }

    private struct Segment {
        let from: Int?
        let to: Int?
        let executed: [Int]
        let choices: [Choice]
    }
    private static func segments(_ program: C.Program, anchors: [Int:Int]) throws -> [Segment] {
        var result: [Segment] = []
        for start in [Int?.none] + anchors.keys.sorted().map({ Optional($0) }) {
            var work: [(Int,[Int],[Choice],Set<Int>)] = [(start ?? 0,[],[],[])]
            while let (pc,path,choices,seen) = work.popLast() {
                if anchors[pc] != nil && (start == nil || !path.isEmpty) {
                    result.append(.init(from:start,to:pc,executed:path,choices:choices)); continue
                }
                guard program.code.indices.contains(pc) else { throw C.Failure.invalidContract("candidate CFG falls out before an owned terminal") }
                guard !seen.contains(pc) else { throw C.Failure.invalidContract("epsilon candidate CFG cycle has no literal source anchor") }
                let executed = path + [pc], visited = seen.union([pc])
                switch program.code[pc].node {
                case let .branch(expression,yes,no):
                    if let value = closedValue(expression) {
                        let taken = value.bits != 0
                        work.append((taken ? yes : no,executed,choices + [.init(pc:pc,expression:expression.span,taken:taken)],visited))
                    } else {
                        work.append((no,executed,choices + [.init(pc:pc,expression:expression.span,taken:false)],visited))
                        work.append((yes,executed,choices + [.init(pc:pc,expression:expression.span,taken:true)],visited))
                    }
                case let .jump(target): work.append((target,executed,choices,visited))
                case .returned, .unavailableReturn: result.append(.init(from:start,to:nil,executed:executed,choices:choices))
                case .unresolved: throw C.Failure.invalidContract("unresolved actual CFG")
                default: work.append((pc + 1,executed,choices,visited))
                }
            }
        }
        return result
    }
    /// A BR has only its literal table cases. The printer may also retain a
    /// conservative default. Exclude that syntactic route only with a complete
    /// finite predicate proof and a matching, dominating unsigned bounds guard.
    static func guardedDispatchFallback(candidate: C.Program, source: Source, entry: Int,
                                                destination: Int, decisions: [Choice], path: [Int], anchors: [Int:Int]) throws -> Bool {
        guard let block = anchors[entry], let target = anchors[destination] else { return false }
        let dispatches = source.dispatches.values.filter { source.blockAtRow[$0.row] == block }
        guard dispatches.count == 1, let dispatch = dispatches.first,
              source.blockAtRow[dispatch.defaultRow] == target,
              dispatch.targets.count == 10 else { return false }
        let predicates = decisions.filter { (try? candidate.row(at: $0.expression)) == dispatch.row }
        guard !predicates.isEmpty else { return false }
        var key: String?
        for ordinal in 0..<10 {
            var matches = true
            for choice in predicates {
                guard case let .branch(expression, _, _) = candidate.code[choice.pc].node,
                      let result = try dispatchPredicate(expression, ordinal: UInt64(ordinal),
                                                         selector: &key, candidate: candidate) else { return false }
                if result != choice.taken { matches = false }
            }
            if matches { return false }
        }
        guard let key, !path.contains(where: { changesSelector(candidate.code[$0], selector: key) }) else { return false }
        return boundsGuardDominates(candidate: candidate, guardRow: dispatch.guardRow,
                                    entry: entry, selector: key)
    }

    private static func boundsSelector(_ expression: C.Expression, candidate: C.Program) -> String? {
        switch expression.node {
        case let .unary("!", child): return boundsSelector(child, candidate: candidate)
        case let .binary(op, left, right) where op == "==" || op == "!=":
            if closedValue(right)?.bits == 0 { return boundsSelector(left, candidate: candidate) }
            if closedValue(left)?.bits == 0 { return boundsSelector(right, candidate: candidate) }
            return nil
        case let .binary(op, value, _) where op == ">" || op == "<=":
            if case let .cast(type, child) = value.node, candidate.expressionTypes[child.span] == type {
                return selectorKey(child)
            }
            return selectorKey(value)
        default: return nil
        }
    }

    /// Explore the actual parsed CFG with one fact: the exact selector is in
    /// 0...9. Every path reaching entry must carry that fact. Assignments to the
    /// selector and calls invalidate it; a guard for another selector cannot set it.
    private static func boundsGuardDominates(candidate: C.Program, guardRow: Int,
                                             entry: Int, selector: String) -> Bool {
        struct State: Hashable { let pc: Int; let bounded: Bool }
        var work = [State(pc: 0, bounded: false)], seen: Set<State> = []
        var reached = false
        while let state = work.popLast() {
            guard seen.insert(state).inserted else { continue }
            guard candidate.code.indices.contains(state.pc) else { return false }
            if state.pc == entry {
                guard state.bounded else { return false }
                reached = true
                continue
            }
            let instruction = candidate.code[state.pc]
            var bounded = state.bounded
            switch instruction.node {
            case let .branch(expression, yes, no):
                if (try? candidate.row(at: expression.span)) == guardRow,
                   boundsSelector(expression, candidate: candidate) == selector,
                   let outOfRange = boundsGuardPredicate(expression, candidate: candidate) {
                    work.append(.init(pc: yes, bounded: !outOfRange))
                    work.append(.init(pc: no, bounded: outOfRange))
                } else {
                    if changesSelector(instruction, selector: selector) { bounded = false }
                    work.append(.init(pc: yes, bounded: bounded))
                    work.append(.init(pc: no, bounded: bounded))
                }
                continue
            case let .jump(target): work.append(.init(pc: target, bounded: bounded)); continue
            case .returned, .unavailableReturn: continue
            case .unresolved: return false
            case .assign, .declaration, .update, .call, .nop:
                if changesSelector(instruction, selector: selector) { bounded = false }
            }
            work.append(.init(pc: state.pc + 1, bounded: bounded))
        }
        return reached
    }

    private static func changesSelector(_ instruction: C.Instruction, selector: String) -> Bool {
        func writes(_ expression: C.Expression) -> Bool {
            guard let key = selectorKey(expression) else { return true }
            return selector == key || selector.contains("(" + key + ")")
        }
        func pure(_ expression: C.Expression) -> Bool {
            switch expression.node {
            case .name, .literal: return true
            case let .cast(_, child), let .unary(_, child), let .load(_, child), let .field(child, _): return pure(child)
            case let .binary(_, left, right): return pure(left) && pure(right)
            case let .select(condition, yes, no): return pure(condition) && pure(yes) && pure(no)
            case let .helper(name, arguments): return name == "__adrp" && arguments.allSatisfy(pure)
            case .update: return false
            }
        }
        switch instruction.node {
        case let .assign(destinations, values): return destinations.contains(where: writes) || !values.allSatisfy(pure)
        case let .declaration(name, value):
            return selector == "name:" + name || selector.contains("(name:" + name + ")") || value.map { !pure($0) } == true
        case let .branch(expression, _, _): return !pure(expression)
        case .update, .call, .unresolved: return true
        case .nop, .jump, .returned, .unavailableReturn: return false
        }
    }

    private static func sourcePaths(_ source: Source, from: Int, to: Int, represented: Set<Int>) -> [[Origin]] {
        var results: [[Origin]] = [], work: [(Int,[Origin],Set<Int>)] = [(from,[],[])]
        while let (block,path,seen) = work.popLast() {
            for origin in source.outgoing[block,default:[]] {
                let next = origin.edge.toBlock, extended = path + [origin]
                if next == to { results.append(extended); continue }
                guard !represented.contains(next), !seen.contains(next),
                      source.blocks[next].rows.allSatisfy({ source.rows[$0].mnemonic == "b" }) else { continue }
                work.append((next,extended,seen.union([block])))
            }
        }
        return results
    }
    private static func selectPath(_ paths: [[Origin]], candidate: C.Program, source: Source, choices: [Choice]) throws -> [Origin]? {
        guard !paths.isEmpty else { return nil }
        var retained: [[Origin]] = []
        for path in paths {
            var compatible = true
            for origin in path {
                guard let dispatch = source.dispatches[origin.row] else { continue }
                let predicateRow = origin.role == .tableDefault ? dispatch.guardRow : dispatch.row
                let relevant = choices.filter { (try? candidate.row(at:$0.expression)) == predicateRow }
                guard !relevant.isEmpty else { compatible = false; break }
                if origin.role == .tableDefault {
                    for choice in relevant {
                        guard origin.machineRole == .taken,
                              case let .branch(expression,_,_) = candidate.code[choice.pc].node,
                              let value = boundsGuardPredicate(expression, candidate: candidate),
                              value == choice.taken else { compatible = false; break }
                    }
                    continue
                }
                let ordinal: UInt64
                switch origin.role {
                case let .tableCase(value): ordinal = UInt64(value)
                default: throw C.Failure.invalidContract("non-dispatch role at dispatch row")
                }
                var selector: String?
                for choice in relevant {
                    guard case let .branch(expression,_,_) = candidate.code[choice.pc].node,
                          let value = try dispatchPredicate(expression,ordinal:ordinal,selector:&selector,candidate:candidate),
                          value == choice.taken else { compatible = false; break }
                }
            }
            if compatible { retained.append(path) }
        }
        guard !retained.isEmpty else { return nil }
        // Multiple table case roles may share one CFG edge/path. Keep all of
        // them; any other ambiguity is an explicit unresolved relation.
        let edgePaths = retained.map { $0.map(\.edge) }
        guard edgePaths.dropFirst().allSatisfy({ $0 == edgePaths[0] }) else { return nil }
        if retained.count > 1 {
            for index in retained[0].indices {
                let roles = Set(retained.map { $0[index].role })
                if roles.count > 1 && !roles.allSatisfy({ role in
                    switch role { case .tableCase, .tableDefault: return true; default: return false }
                }) { return nil }
            }
        }
        var result: [Origin] = []
        // Group parallel roles at their edge position, not all edges of path A
        // then all edges of path B, so dynamic edge order stays unambiguous.
        for index in retained[0].indices {
            for path in retained where !result.contains(path[index]) { result.append(path[index]) }
        }
        return result
    }
    /// Evaluate only the original unsigned >9 guard's taken outcome. Native
    /// presentation may invert it or wrap the Boolean in an explicit zero test.
    private static func boundsGuardPredicate(_ e: C.Expression, candidate: C.Program) -> Bool? {
        switch e.node {
        case let .unary("!", child):
            return boundsGuardPredicate(child, candidate: candidate).map { !$0 }
        case let .binary(op, left, right) where op == "==" || op == "!=":
            if let zero = closedValue(right), zero.bits == 0, !zero.type.pointer,
               let value = boundsGuardPredicate(left, candidate: candidate) {
                return op == "!=" ? value : !value
            }
            if let zero = closedValue(left), zero.bits == 0, !zero.type.pointer,
               let value = boundsGuardPredicate(right, candidate: candidate) {
                return op == "!=" ? value : !value
            }
            return nil
        case let .binary(op, selector, bound) where op == ">" || op == "<=":
            guard let nine = closedValue(bound), nine.bits == 9, !nine.type.pointer,
                  selectorKey(selector) != nil,
                  let type = candidate.expressionTypes[selector.span],
                  !type.pointer, type.unsigned, type.width == 32 || type.width == 64 else { return nil }
            return op == ">"
        default: return nil
        }
    }
    static func dispatchPredicate(_ e: C.Expression, ordinal: UInt64, selector: inout String?, candidate: C.Program) throws -> Bool? {
        switch e.node {
        case let .unary("!",child):
            guard let value = try dispatchPredicate(child,ordinal:ordinal,selector:&selector,candidate:candidate) else { return nil }; return !value
        case let .binary(op,left,right) where op == "&&" || op == "||":
            // This is a static truth-set proof over pure equality syntax, not
            // candidate execution or a reference-supplied branch decision.
            guard let a = try dispatchPredicate(left,ordinal:ordinal,selector:&selector,candidate:candidate),
                  let b = try dispatchPredicate(right,ordinal:ordinal,selector:&selector,candidate:candidate) else { return nil }
            return op == "&&" ? a && b : a || b
        case let .binary(op,left,right) where op == "==" || op == "!=":
            // Native singleton arms print a Boolean equality followed by an
            // explicit zero test, e.g. ((selector == 0) != 0). Prove the child
            // using this same closed predicate grammar before normalizing it;
            // an arbitrary integer expression is not a Boolean certificate.
            // Preserve polarity, including a reversed literal-zero operand.
            if case let .literal(zero) = right.node, zero.bits == 0, !zero.type.pointer,
               let value = try dispatchPredicate(left,ordinal:ordinal,selector:&selector,candidate:candidate) {
                return op == "!=" ? value : !value
            }
            if case let .literal(zero) = left.node, zero.bits == 0, !zero.type.pointer,
               let value = try dispatchPredicate(right,ordinal:ordinal,selector:&selector,candidate:candidate) {
                return op == "!=" ? value : !value
            }
            let expression: C.Expression, constant: C.Value
            if let value = closedValue(right), selectorKey(left) != nil { expression = left; constant = value }
            else if let value = closedValue(left), selectorKey(right) != nil { expression = right; constant = value }
            else { return nil }
            guard constant.bits < 10, let key = selectorKey(expression),
                  let type = candidate.expressionTypes[expression.span], !type.pointer, type.unsigned,
                  type.width == 32 || type.width == 64 else { return nil }
            if let old = selector, old != key { return nil }; selector = key
            return op == "==" ? ordinal == constant.bits : ordinal != constant.bits
        default: return nil
        }
    }
    private static func selectorKey(_ e: C.Expression) -> String? {
        switch e.node {
        case let .name(name): return "name:\(name)"
        case let .cast(type,child):
            guard type == .u32 || type == .u64, let key = selectorKey(child) else { return nil }
            return "u\(type.width)(\(key))"
        default: return nil
        }
    }
    private static func closedValue(_ e: C.Expression) -> C.Value? {
        switch e.node {
        case let .literal(value): return value
        case let .cast(type,child): guard let value = closedValue(child) else { return nil }; return try? C.converted(value,to:type)
        case let .unary("!",child): guard let value = closedValue(child) else { return nil }; return .init(value.bits == 0 ? 1 : 0,.i32)
        default: return nil
        }
    }

    private struct SyntaxInventory { let transfers: [PrintedTransfer]; let loops: [C.Span] }
    private struct LoopOwner { let span: C.Span; let breakPC: Int; let continuePC: Int }
    private static func syntax(_ program: C.Program, source: Source) throws -> SyntaxInventory {
        var transfers: [PrintedTransfer] = [], loops: [C.Span] = [], labels: [String:Int] = [:]
        var gotos: [(C.Statement,String,[LoopOwner])] = []
        func pc(_ span: C.Span) throws -> Int {
            guard let value = program.code.indices.first(where: { program.code[$0].span == span }) else {
                throw C.Failure.invalidContract("parsed syntax has no actual compiled site")
            }
            return value
        }
        func loopOwner(_ s: C.Statement, expression: C.Expression?, step: C.Statement?, isFor: Bool = false) throws -> LoopOwner {
            let condition: Int, end: Int
            if let expression {
                let sites = program.code.indices.filter { index in
                    if case let .branch(e,_,_) = program.code[index].node { return e.span == expression.span }; return false
                }
                guard sites.count == 1, case let .branch(_,_,no) = program.code[sites[0]].node else {
                    throw C.Failure.invalidContract("native loop condition does not have one actual branch")
                }
                condition = sites[0]; end = no
            } else {
                let contained = program.code.indices.filter { contains(s.span,program.code[$0].span) }
                guard let last = contained.last else { throw C.Failure.invalidContract("empty native loop") }
                condition = try pc(s.span); end = last + 1
            }
            let continuation: Int
            if let step { continuation = try pc(step.span) }
            else if isFor {
                // A step-less for continue lands on its tail administrative
                // jump, not directly on the condition. Verify that exact tail.
                let tails = program.code.indices.filter { index in
                    guard program.code[index].span == s.span else { return false }
                    if case let .jump(target) = program.code[index].node { return target == condition }; return false
                }
                guard tails.count == 1 else { throw C.Failure.invalidContract("for continuation lacks its unique administrative tail") }
                continuation = tails[0]
            } else { continuation = condition }
            return .init(span:s.span,breakPC:end,continuePC:continuation)
        }
        func walk(_ s: C.Statement, stack: [LoopOwner]) throws {
            switch s.node {
            case let .compound(_,body): for child in body { try walk(child,stack:stack) }
            case let .conditional(_,yes,no): try walk(yes,stack:stack); if let no { try walk(no,stack:stack) }
            case let .whileLoop(e,body):
                let owner = try loopOwner(s,expression:e,step:nil); loops.append(s.span); try walk(body,stack:stack + [owner])
            case let .doLoop(body,e):
                let owner = try loopOwner(s,expression:e,step:nil); loops.append(s.span); try walk(body,stack:stack + [owner])
            case let .forLoop(initial,e,step,body):
                if let initial { try walk(initial,stack:stack) }
                let owner = try loopOwner(s,expression:e,step:step,isFor:true); loops.append(s.span)
                try walk(body,stack:stack + [owner]); if let step { try walk(step,stack:stack + [owner]) }
            case let .label(name,body):
                let row = try program.row(at:s.span)
                guard let block = source.blockAtRow[row], source.blocks[block].rows.lowerBound == row,
                      UInt64(name.dropFirst(2),radix:16) == source.rows[row].address else {
                    throw C.Failure.invalidContract("native label identity is not its literal target-block entry")
                }
                let target = try pc(body.span)
                guard labels.updateValue(target,forKey:name) == nil else { throw C.Failure.invalidContract("duplicate AST label") }
                try walk(body,stack:stack)
            case let .jump(name): gotos.append((s,name,stack))
            case .breakLoop, .continueLoop:
                let site = try pc(s.span)
                guard let owner = stack.last, case let .jump(target) = program.code[site].node else {
                    throw C.Failure.invalidContract("native loop exit is not an actual resolved transfer")
                }
                let kind: PrintedKind
                if case .breakLoop = s.node { kind = .breakLoop } else { kind = .continueLoop }
                guard target == (kind == .breakLoop ? owner.breakPC : owner.continuePC) else {
                    throw C.Failure.invalidContract("break/continue violates nearest lexical loop")
                }
                transfers.append(.init(span:s.span,kind:kind,nearestLoop:owner.span,pc:site,target:target))
            default: break
            }
        }
        try walk(program.root,stack:[])
        for (statement,name,stack) in gotos {
            let site = try pc(statement.span)
            guard let landing = labels[name], case let .jump(target) = program.code[site].node, target == landing else {
                throw C.Failure.invalidContract("actual goto does not land at its unique parsed label")
            }
            transfers.append(.init(span:statement.span,kind:.goto,nearestLoop:stack.last?.span,pc:site,target:target))
        }
        return .init(transfers:transfers.sorted { $0.pc < $1.pc },loops:loops)
    }

    private struct ReplayedChoice { let offset: Int; let choice: Choice }
    private struct ReplayedTrace { let pcs: [Int]; let choices: [ReplayedChoice] }
    private static func replay(_ program: C.Program, _ result: C.Result) throws -> ReplayedTrace {
        var pc = 0, cursor = 0, pcs: [Int] = [], choices: [ReplayedChoice] = []
        let (bound,overflow) = (result.transfers.count + 1).multipliedReportingOverflow(by:program.code.count + 1)
        guard !overflow else { throw C.Failure.invalidContract("candidate trace bound overflow") }
        while program.code.indices.contains(pc), pcs.count <= bound {
            let instruction = program.code[pc], offset = pcs.count
            pcs.append(pc)
            switch instruction.node {
            case let .branch(expression,yes,no):
                guard result.transfers.indices.contains(cursor) else { throw C.Failure.invalidContract("missing actual branch trace") }
                let transfer = result.transfers[cursor]; cursor += 1
                guard transfer.span == expression.span, let taken = transfer.taken,
                      transfer.destination == (taken ? yes : no) else { throw C.Failure.invalidContract("actual branch trace contradicts parsed CFG") }
                choices.append(.init(offset:offset,choice:.init(pc:pc,expression:expression.span,taken:taken)))
                pc = transfer.destination
            case let .jump(destination):
                guard result.transfers.indices.contains(cursor) else { throw C.Failure.invalidContract("missing actual jump trace") }
                let transfer = result.transfers[cursor]; cursor += 1
                guard transfer.span == instruction.span, transfer.taken == nil, transfer.destination == destination else {
                    throw C.Failure.invalidContract("actual jump trace contradicts parsed CFG")
                }
                pc = destination
            case .returned, .unavailableReturn:
                guard cursor == result.transfers.count else { throw C.Failure.invalidContract("extra actual transfers after original return") }
                return .init(pcs:pcs,choices:choices)
            case .unresolved: throw C.Failure.invalidContract("unresolved actual transfer")
            default: pc += 1
            }
        }
        throw C.Failure.invalidContract("actual transfer trace cannot reconstruct a normal return")
    }
    private static func sourceTrace(_ source: Source, branches: [RegionalCallOracle.Branch], rowVisits: [Int:Int]) throws -> [C.SourceEdge] {
        guard rowVisits.values.allSatisfy({ $0 > 0 }) else { throw C.Failure.invalidContract("invalid completed source row visits") }
        let bound = rowVisits.values.reduce(0,+)
        var pc = 0, cursor = 0, visited: [Int:Int] = [:], edges: [C.SourceEdge] = []
        for _ in 0..<bound {
            guard source.rows.indices.contains(pc), let block = source.blockAtRow[pc] else { throw C.Failure.invalidContract("source trace leaves complete rows") }
            visited[pc,default:0] += 1
            let mnemonic = source.rows[pc].mnemonic
            if mnemonic == "ret" {
                guard cursor == branches.count, visited == rowVisits else { throw C.Failure.invalidContract("literal source reconstruction disagrees with completed independent execution") }
                return edges
            }
            var next = pc + 1
            var role: Role? = .fallthrough
            if conditional(mnemonic) || mnemonic == "b" || mnemonic == "br" {
                guard branches.indices.contains(cursor), branches[cursor].row == pc else { throw C.Failure.invalidContract("missing ordered literal source branch") }
                let branch = branches[cursor]; cursor += 1
                guard let destination = source.rows.firstIndex(where: { $0.address == branch.target }) else { throw C.Failure.invalidContract("source branch target outside body") }
                if let dispatch = source.dispatches[pc] {
                    guard branch.taken, dispatch.targets.contains(destination) else { throw C.Failure.invalidContract("physical BR invented a default/out-of-table edge") }
                    next = destination
                    role = nil
                    // Branch target alone does not establish a case ordinal.
                    // Keep its plural case roles; compare only their common CFG edge.
                } else {
                    guard source.branchTargets[pc] == destination, mnemonic != "b" || branch.taken else { throw C.Failure.invalidContract("literal direct branch identity changed") }
                    if branch.taken { next = destination }
                    role = mnemonic == "b" ? .unconditional : branch.taken ? .taken : .notTaken
                }
            }
            guard let nextBlock = source.blockAtRow[next] else { throw C.Failure.invalidContract("source falls beyond terminal") }
            if nextBlock != block || pc == source.blocks[block].rows.upperBound - 1 {
                let matching = source.outgoing[block,default:[]].filter { origin in
                    guard origin.edge.toBlock == nextBlock else { return false }
                    if let role { return origin.machineRole == role }
                    if case .tableCase = origin.role { return true }; return false
                }
                let candidates = Set(matching.map(\.edge))
                guard candidates.count == 1, let edge = candidates.first else { throw C.Failure.invalidContract("source event has no unique CFG successor ordinal") }
                edges.append(edge)
            }
            pc = next
        }
        throw C.Failure.invalidContract("completed source visits do not reach the original terminal")
    }
    private static func naturalLoops(blocks: [Block]) -> [C.SourceEdge:Set<Int>] {
        var predecessors: [Int:Set<Int>] = [:]
        for block in blocks { for target in block.successors { predecessors[target,default:[]].insert(block.index) } }
        var reachable: Set<Int> = [], work = [0]
        while let block = work.popLast() {
            guard reachable.insert(block).inserted else { continue }; work += blocks[block].successors
        }
        var dominators: [Int:Set<Int>] = [:]
        for block in reachable { dominators[block] = block == 0 ? [0] : reachable }
        var changed = true
        while changed {
            changed = false
            for block in reachable.sorted() where block != 0 {
                let incoming = predecessors[block,default:[]].intersection(reachable)
                var common = reachable
                for predecessor in incoming { common.formIntersection(dominators[predecessor,default:[]]) }
                common.insert(block)
                if common != dominators[block] { dominators[block] = common; changed = true }
            }
        }
        var result: [C.SourceEdge:Set<Int>] = [:]
        for block in blocks where reachable.contains(block.index) {
            for (ordinal,target) in block.successors.enumerated() where dominators[block.index,default:[]].contains(target) {
                let edge = C.SourceEdge(fromBlock:block.index,toBlock:target,successorOrdinal:ordinal)
                var members: Set<Int> = [target,block.index], work = block.index == target ? [] : [block.index]
                while let current = work.popLast() {
                    for predecessor in predecessors[current,default:[]] where members.insert(predecessor).inserted { work.append(predecessor) }
                }
                result[edge] = members
            }
        }
        return result
    }
    private static func conditional(_ mnemonic: String) -> Bool {
        mnemonic.hasPrefix("b.") || mnemonic == "cbz" || mnemonic == "cbnz"
    }
    private static func control(_ mnemonic: String) -> Bool {
        conditional(mnemonic) || mnemonic == "b" || mnemonic == "br" || mnemonic == "cmp" || mnemonic == "ccmp" || mnemonic == "tst"
    }
    private static func contains(_ outer: C.Span, _ inner: C.Span) -> Bool { outer.first <= inner.first && outer.last >= inner.last }
    private static func orderedEdges(_ origins: [Origin]) -> [C.SourceEdge] {
        var result: [C.SourceEdge] = []
        for origin in origins where result.last != origin.edge { result.append(origin.edge) }
        return result
    }
    private static func roleKey(_ role: Role) -> String {
        switch role {
        case .taken: return "taken"
        case .notTaken: return "notTaken"
        case .unconditional: return "unconditional"
        case .fallthrough: return "fallthrough"
        case let .tableCase(n): return "case\(n)"
        case .tableDefault: return "default"
        }
    }
    private static func originLess(_ a: Origin, _ b: Origin) -> Bool {
        if a.edge.fromBlock != b.edge.fromBlock { return a.edge.fromBlock < b.edge.fromBlock }
        if a.edge.successorOrdinal != b.edge.successorOrdinal { return a.edge.successorOrdinal < b.edge.successorOrdinal }
        return roleKey(a.role) < roleKey(b.role)
    }
    private static func describe(_ origin: Origin) -> String {
        "block \(origin.edge.fromBlock), successor \(origin.edge.successorOrdinal), \(roleKey(origin.role)), target \(origin.edge.toBlock), row \(origin.row)"
    }
    private static func unique(_ gaps: [Gap]) -> [Gap] {
        var result: [Gap] = []
        for gap in gaps where !result.contains(gap) { result.append(gap) }
        return result
    }
}

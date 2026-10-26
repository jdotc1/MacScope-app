import Foundation

/// A recovered control-flow condition feeding a structured construct's guard.
/// Carries the operands/operator AND the bookkeeping the emitter needs to stay
/// byte-identical with the legacy structurer: which instruction anchors the
/// header line (address + comment) and which preceding compare to suppress.
struct BranchCondition: Sendable, Equatable {
    /// Index of the branch instruction; its source address + comment anchor the
    /// rendered header line (click-to-jump + comment parity).
    var branchIndex: Int
    /// Index of a preceding `.intrinsic(name:"compare", …)` whose flags feed the
    /// branch and which must be suppressed — nil for a zero-check branch.
    var compareIndex: Int?
    var left: MacIRValue
    var condition: String
    var right: MacIRValue
    /// cbz/cbnz/tbz/tbnz zero-check branch → truthiness shortening applies.
    var isZeroCheck: Bool
    /// Secondary exits that render as gotos into the continuation, including
    /// loop exits and conditional SSA edge-copy blocks.
    var continuationGotoTargets: Set<Int> = []
}

/// A structured control-flow region recovered from the CFG.
///
/// Index conventions: `block(blockIndex)` / loop `header` / `switchDispatch`
/// indices are CFG block indices; `join` is a CFG block index. `.irreducible`
/// is the explicit "do not guess" leaf carrying the block indices involved.
indirect enum Region: Sendable {
    case sequence([Region])
    /// `inverted` selects the guard polarity: `true` renders the INVERTED branch
    /// condition (the body sits on the fall-through edge — the common case),
    /// `false` renders the RAW condition (the body was hot/cold-split onto the
    /// branch-TAKEN edge, so entering it IS "branch taken").
    case ifThen(cond: BranchCondition, body: Region, join: Int, inverted: Bool)
    case ifThenElse(cond: BranchCondition, then: Region, els: Region, join: Int)
    case whileLoop(cond: BranchCondition, body: Region, header: Int)
    case doWhileLoop(body: Region, cond: BranchCondition)
    case naturalLoop(body: Region, header: Int)
    case switchDispatch(index: Int, cases: [Int], default: Int?)
    case block(blockIndex: Int)
    case gotoLeaf(blocks: [Int])
    case irreducible([Int])
    /// Exact regional edge/case ownership requires the fallback-only certified context.
    case certifiedEdge(RegionalOrdinaryControlPlan.EdgeEmissionSlotID)
    case certifiedSelection(RegionalOrdinaryControlPlan.SelectionPlanID)
}

/// Builds a `Region` tree from a recovered `CFG`. Conservative by construction:
/// anything that cannot be cleanly proven reducible collapses to `.irreducible`,
/// and the printer falls back to the legacy goto-emitting `structure()` for the
/// whole function on that signal (correctness-over-coverage).
enum RegionTree {
    struct SyntheticPhiLatchLoop {
        var latch: Int
        var test: Int
        var exit: Int
        var blocks: Set<Int>
        var condition: BranchCondition
    }

    /// A split SSA backedge carries real parallel-copy assignments. It is
    /// neither an empty latch nor safe to execute on the loop's exiting path.
    static func syntheticPhiLatchLoop(
        header: Int, cfg: CFG, instructions: [MacIRInstruction]
    ) -> SyntheticPhiLatchLoop? {
        let backedges = cfg.backEdges.filter { $0.to == header }
        guard backedges.count == 1, let latch = backedges.first?.from,
              latch != header else { return nil }
        let copyBlock = cfg.blocks[latch]
        guard copyBlock.successors == [header], copyBlock.predecessors.count == 1,
              let test = copyBlock.predecessors.first,
              copyBlock.endIndex > copyBlock.startIndex + 1 else { return nil }
        let branchIndex = cfg.blocks[test].endIndex - 1
        let headerAddress = instructions[cfg.blocks[header].startIndex].source.address
        let predecessorAddress = instructions[branchIndex].source.address
        guard copyBlock.instructionRange.allSatisfy({ index in
            guard let edge = instructions[index].source.syntheticPhiEdge else { return false }
            return edge.blockAddress == headerAddress && edge.machineAddress == predecessorAddress
        }), copyBlock.instructionRange.dropLast().allSatisfy({ index in
            if case .assign = instructions[index].operation { return true }
            return false
        }), case let .unconditionalBranch(target) = CFGBuilder.terminatorKind(
            of: instructions[copyBlock.endIndex - 1].operation), target == headerAddress,
              case let .conditionalBranch(condition, left, right, _) = instructions[branchIndex].operation,
              cfg.blocks[test].successors.count == 2,
              cfg.blocks[test].successors.contains(latch),
              let exit = cfg.blocks[test].successors.first(where: { $0 != latch }) else { return nil }
        var blocks: Set<Int> = [header]
        var pending = [latch]
        while let block = pending.popLast() {
            guard blocks.insert(block).inserted else { continue }
            pending.append(contentsOf: cfg.blocks[block].predecessors.filter { $0 != header })
        }
        guard blocks.contains(test), !blocks.contains(exit), blocks.allSatisfy({ block in
            CFGBuilder.dominates(header, block, domTree: cfg.domTree)
                && (block == header || cfg.blocks[block].predecessors.allSatisfy(blocks.contains))
        }), blocks.flatMap({ block in
            cfg.blocks[block].successors.filter { !blocks.contains($0) }.map { CFGEdge(block, $0) }
        }) == [CFGEdge(test, exit)] else { return nil }
        let mnemonic = instructions[branchIndex].source.mnemonic.lowercased()
        let isZeroCheck = ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
        var compareIndex: Int?
        if !isZeroCheck {
            let prior = branchIndex - 1
            guard prior >= cfg.blocks[test].startIndex,
                  instructions[prior].source.address.isContiguous(to: predecessorAddress) else { return nil }
            switch instructions[prior].operation {
            case let .intrinsic(_, "compare", arguments) where arguments == [left, right]:
                compareIndex = prior
            case let .binary(_, "-", lhs, rhs)
                where instructions[prior].source.mnemonic.lowercased() == "subs"
                    && ["b.eq", "b.ne"].contains(mnemonic)
                    && ["==", "!="].contains(condition) && lhs == left && rhs == right:
                // Keep the subtract assignment; only its exact adjacent
                // equality predicate becomes the loop's conditional break.
                break
            default:
                return nil
            }
        }
        return SyntheticPhiLatchLoop(latch: latch, test: test, exit: exit, blocks: blocks,
            condition: BranchCondition(branchIndex: branchIndex, compareIndex: compareIndex,
                left: left, condition: condition, right: right, isZeroCheck: isZeroCheck))
    }

    static func syntheticPhiLatchCondition(
        test: Int, cfg: CFG, instructions: [MacIRInstruction]
    ) -> BranchCondition? {
        for successor in cfg.blocks[test].successors {
            guard let header = cfg.blocks[successor].successors.first,
                  instructions[cfg.blocks[successor].startIndex].source.syntheticPhiEdge != nil,
                  let loop = syntheticPhiLatchLoop(header: header, cfg: cfg, instructions: instructions),
                  loop.test == test, loop.latch == successor else { continue }
            return loop.condition
        }
        return nil
    }

    enum Veto: String, CaseIterable, Sendable {
        case emptyCFG
        case unresolvedTargets
        case irreducibleBlocks
        case unreachableBlocks
        case recursionGuard
        case switchHasInGraphSuccessors
        case conditionalSuccessorCount
        case conditionalMissingCondition
        case conditionalOverReachesStop
        case conditionalDoubleGuardToJoin
        case ifThenBodyUnstructured
        case ifElseArmUnstructured
        case ifElseTakenBodyOrientation
        case ifElseArmsShareExitTail
        case ifElseArmsShareRejoiningTail
        case gotoLeafRejoiningEmitted
        case gotoLeafRejoiningNoSharedTail
        case gotoLeafRejoiningAmbiguousEntry
        case gotoLeafRejoiningOverReachesStop
        case gotoLeafRejoiningNonContiguous
        case gotoLeafRejoiningLeafEscapes
        case gotoLeafRejoiningDoubleReachable
        case gotoLeafRejoiningArmUnstructured
        case gotoLeafRejoiningContinuationUnstructured
        case gotoLeafRejoiningPartition
        case armDominanceFailed
        case earlyExitArmNotClean
        case earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail
        case earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicNoreturnTail
        case earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicPlainTail
        case earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicNoreturnTail
        case earlyExitFallthroughBranchDominanceFailedInLoopAcyclicPlainTail
        case earlyExitFallthroughBranchDominanceFailedInLoopAcyclicNoreturnTail
        case earlyExitFallthroughBranchDominanceFailedInLoopCyclicPlainTail
        case earlyExitFallthroughBranchDominanceFailedInLoopCyclicNoreturnTail
        case earlyExitFallthroughReachesContinuationOutOfLoopAcyclicPlainTail
        case earlyExitFallthroughReachesContinuationOutOfLoopAcyclicNoreturnTail
        case earlyExitFallthroughReachesContinuationOutOfLoopCyclicPlainTail
        case earlyExitFallthroughReachesContinuationOutOfLoopCyclicNoreturnTail
        case earlyExitFallthroughReachesContinuationInLoopAcyclicPlainTail
        case earlyExitFallthroughReachesContinuationInLoopAcyclicNoreturnTail
        case earlyExitFallthroughReachesContinuationInLoopCyclicPlainTail
        case earlyExitFallthroughReachesContinuationInLoopCyclicNoreturnTail
        case earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail
        case earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicNoreturnTail
        case earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicPlainTail
        case earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicNoreturnTail
        case earlyExitFallthroughArmDominanceFailedInLoopAcyclicPlainTail
        case earlyExitFallthroughArmDominanceFailedInLoopAcyclicNoreturnTail
        case earlyExitFallthroughArmDominanceFailedInLoopCyclicPlainTail
        case earlyExitFallthroughArmDominanceFailedInLoopCyclicNoreturnTail
        case earlyExitTakenBranchDominanceFailedOutOfLoopAcyclicPlainTail
        case earlyExitTakenBranchDominanceFailedOutOfLoopAcyclicNoreturnTail
        case earlyExitTakenBranchDominanceFailedOutOfLoopCyclicPlainTail
        case earlyExitTakenBranchDominanceFailedOutOfLoopCyclicNoreturnTail
        case earlyExitTakenBranchDominanceFailedInLoopAcyclicPlainTail
        case earlyExitTakenBranchDominanceFailedInLoopAcyclicNoreturnTail
        case earlyExitTakenBranchDominanceFailedInLoopCyclicPlainTail
        case earlyExitTakenBranchDominanceFailedInLoopCyclicNoreturnTail
        case earlyExitTakenReachesContinuationOutOfLoopAcyclicPlainTail
        case earlyExitTakenReachesContinuationOutOfLoopAcyclicNoreturnTail
        case earlyExitTakenReachesContinuationOutOfLoopCyclicPlainTail
        case earlyExitTakenReachesContinuationOutOfLoopCyclicNoreturnTail
        case earlyExitTakenReachesContinuationInLoopAcyclicPlainTail
        case earlyExitTakenReachesContinuationInLoopAcyclicNoreturnTail
        case earlyExitTakenReachesContinuationInLoopCyclicPlainTail
        case earlyExitTakenReachesContinuationInLoopCyclicNoreturnTail
        case earlyExitTakenArmDominanceFailedOutOfLoopAcyclicPlainTail
        case earlyExitTakenArmDominanceFailedOutOfLoopAcyclicNoreturnTail
        case earlyExitTakenArmDominanceFailedOutOfLoopCyclicPlainTail
        case earlyExitTakenArmDominanceFailedOutOfLoopCyclicNoreturnTail
        case earlyExitTakenArmDominanceFailedInLoopAcyclicPlainTail
        case earlyExitTakenArmDominanceFailedInLoopAcyclicNoreturnTail
        case earlyExitTakenArmDominanceFailedInLoopCyclicPlainTail
        case earlyExitTakenArmDominanceFailedInLoopCyclicNoreturnTail
        case earlyExitTakenSinglePred
        case earlyExitTakenSharedExit
        case earlyExitOverReachesStop
        case loopMissingBackEdge
        case loopMultipleExitTargets
        case loopSecondaryExitNotTerminal
        case loopSecondaryExitNotInContinuation
        case whileBodyEntryInvalid
        case whileBodyUnstructured
        case doWhileBodyUnstructured
        case loopShapeUnsupported
        case loopBodyEscapes
        case multiLatch
        case branchConditionNotConditional
        case branchConditionMissingAdjacentCompare
        case emitterUnsupportedRegion
    }

    struct Diagnostics: Sendable, Equatable {
        private(set) var enabled: Bool
        private(set) var siteCounts: [Veto: Int] = [:]
        private(set) var fatalVeto: Veto?
        private var lastSiteVeto: Veto?

        init(enabled: Bool = false) {
            self.enabled = enabled
        }

        mutating func recordSite(_ veto: Veto) {
            guard enabled else { return }
            siteCounts[veto, default: 0] += 1
            lastSiteVeto = veto
        }

        mutating func recordFatal(_ veto: Veto) {
            guard enabled else { return }
            if fatalVeto == nil {
                fatalVeto = veto
            }
        }

        mutating func recordFatalFromLastSite(default defaultVeto: Veto) {
            recordFatal(lastSiteVeto ?? defaultVeto)
        }

        func siteCountsText() -> String {
            Veto.allCases.compactMap { veto -> String? in
                guard let count = siteCounts[veto], count > 0 else { return nil }
                return "\(veto.rawValue):\(count)"
            }
            .joined(separator: ",")
        }
    }

    struct BuildResult: Sendable {
        var region: Region?
        var diagnostics: Diagnostics
    }

    /// Separate from ordinary recovery: each absorbed source is a conditional
    /// continuation edge, not an effect executed on the final loop iteration.
    struct CertifiedBuildResult: Sendable {
        let region: Region
        let absorbedStubs: [Int: Int]
    }

    static let diagnosticsEnvironmentKey = "MACSCOPE_REGIONTREE_DIAGNOSTICS"

    static var diagnosticsEnabled: Bool {
        let value = ProcessInfo.processInfo.environment[diagnosticsEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Returns the recovered region tree, or `nil` when the CFG is empty, has
    /// unresolved targets, or contains an irreducible block (caller must then
    /// use the legacy structurer for the entire function).
    static func build(cfg: MacIRCFG, instructions: [MacIRInstruction]) -> Region? {
        build(cfg: cfg.compatibilityCFG, instructions: instructions)
    }

    static func buildWithDiagnostics(
        cfg: MacIRCFG,
        instructions: [MacIRInstruction],
        collectDiagnostics: Bool = diagnosticsEnabled
    ) -> BuildResult {
        buildWithDiagnostics(cfg: cfg.compatibilityCFG, instructions: instructions,
                             collectDiagnostics: collectDiagnostics)
    }

    static func build(cfg: CFG, instructions: [MacIRInstruction]) -> Region? {
        buildWithDiagnostics(cfg: cfg, instructions: instructions).region
    }

    /// Only a successful, input-bound decoded certificate can supply conditions
    /// that retain their writer effects or admit an empty unconditional latch.
    /// The ordinary builder and its diagnostic contract remain independent.
    static func build(
        cfg: CFG,
        instructions: [MacIRInstruction],
        certifiedBy plan: DecodedScalarCFGPlan
    ) -> CertifiedBuildResult? {
        guard plan.matches(cfg: cfg, instructions: instructions),
              !cfg.blocks.isEmpty, !cfg.hasUnresolvedTargets,
              cfg.irreducibleBlocks.isEmpty, allBlocksReachable(cfg: cfg) else { return nil }
        var builder = Builder(cfg: cfg, instructions: instructions,
                              diagnostics: Diagnostics(), fallbackPolicy: .wholeFunction,
                              certifiedBy: plan)
        let region = builder.buildRegion(entry: cfg.entryIndex, stop: nil)
        return builder.certifiedBuildResult(for: region)
    }

    static func buildWithDiagnostics(
        cfg: CFG,
        instructions: [MacIRInstruction],
        collectDiagnostics: Bool = diagnosticsEnabled,
        allowRejoiningContinuationGotos: Bool = false
    ) -> BuildResult {
        var diagnostics = Diagnostics(enabled: collectDiagnostics)
        guard !cfg.blocks.isEmpty else {
            diagnostics.recordSite(.emptyCFG)
            diagnostics.recordFatal(.emptyCFG)
            return BuildResult(region: nil, diagnostics: diagnostics)
        }
        guard !cfg.hasUnresolvedTargets else {
            diagnostics.recordSite(.unresolvedTargets)
            diagnostics.recordFatal(.unresolvedTargets)
            return BuildResult(region: nil, diagnostics: diagnostics)
        }
        guard cfg.irreducibleBlocks.isEmpty else {
            diagnostics.recordSite(.irreducibleBlocks)
            diagnostics.recordFatal(.irreducibleBlocks)
            return BuildResult(region: nil, diagnostics: diagnostics)
        }
        // Every block must be reachable from the entry. An unreachable (orphan)
        // block would be silently dropped by the depth-first region walk,
        // losing its instructions — bail to the legacy flat emitter, which
        // renders every instruction faithfully.
        guard allBlocksReachable(cfg: cfg) else {
            diagnostics.recordSite(.unreachableBlocks)
            diagnostics.recordFatal(.unreachableBlocks)
            return BuildResult(region: nil, diagnostics: diagnostics)
        }

        var builder = Builder(cfg: cfg, instructions: instructions, diagnostics: diagnostics,
                              fallbackPolicy: .wholeFunction,
                              allowRejoiningContinuationGotos: allowRejoiningContinuationGotos)
        let region = builder.buildRegion(entry: cfg.entryIndex, stop: nil)
        return BuildResult(region: region, diagnostics: builder.diagnostics)
    }

    /// Supplementary root-only attempt; the normal diagnostic contract stays
    /// unchanged, and nested unsupported arms and loops remain unsupported.
    static func buildTerminalSuffixFallback(
        cfg: CFG, instructions: [MacIRInstruction]
    ) -> TerminalSuffixRegionPlan? {
        guard !cfg.blocks.isEmpty, !cfg.hasUnresolvedTargets,
              cfg.irreducibleBlocks.isEmpty, allBlocksReachable(cfg: cfg) else { return nil }
        var builder = Builder(cfg: cfg, instructions: instructions,
                              diagnostics: Diagnostics(), fallbackPolicy: .terminalSuffix)
        _ = builder.buildRegion(entry: cfg.entryIndex, stop: nil)
        return builder.terminalSuffixPlan
    }

    static func emitDiagnosticsIfEnabled(
        functionName: String,
        fallback: String?,
        diagnostics: Diagnostics
    ) {
        guard diagnostics.enabled else { return }
        let fallbackText = fallback ?? "structured"
        let fatalText = diagnostics.fatalVeto?.rawValue ?? "none"
        let siteText = diagnostics.siteCountsText()
        let line = "REGIONTREE_DIAGNOSTICS\tfunction=\(functionName)\tfallback=\(fallbackText)\tfatal=\(fatalText)\tsites=\(siteText)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    /// True iff every block is reachable from the entry over forward edges.
    private static func allBlocksReachable(cfg: CFG) -> Bool {
        var visited: Set<Int> = []
        var stack = [cfg.entryIndex]
        while let block = stack.popLast() {
            if visited.contains(block) { continue }
            visited.insert(block)
            for succ in cfg.blocks[block].successors { stack.append(succ) }
        }
        return visited.count == cfg.blocks.count
    }

    /// Mutable region-construction state.
    private struct Builder {
        enum FallbackPolicy { case wholeFunction, terminalSuffix }
        let cfg: CFG
        let instructions: [MacIRInstruction]
        var diagnostics: Diagnostics
        let fallbackPolicy: FallbackPolicy
        let allowRejoiningContinuationGotos: Bool
        private(set) var terminalSuffixPlan: TerminalSuffixRegionPlan?
        private let certifiedConditions: [Int: BranchCondition]?
        private let certifiedTestPrefixStarts: [Int: Int]
        private var certifiedAbsorbedStubs: [Int: Int] = [:]

        /// Guard against non-terminating recursion on degenerate / nested-loop
        /// CFGs. `buildRegion` recurses through `classifyConditional`,
        /// `classifyLoop`, `structuredSubregion`, and `loopBodyRegion`; a
        /// pathological CFG (e.g. a nested loop that re-enters the same header)
        /// can otherwise recurse forever and crash (SIGSEGV). On a repeat visit
        /// of the same `(entry, stop)` scope, or when the recursion depth
        /// exceeds the cap, we return `.irreducible` so the printer falls back
        /// to the legacy structurer for the whole function (correct goto).
        private var activeScopes: Set<ScopeKey> = []
        private var depth: Int = 0
        /// Generous cap: real functions structure in O(blocks) depth; anything
        /// deeper than this is a pathology we refuse to structure.
        private static let maxDepth = 4096

        private struct ScopeKey: Hashable {
            let entry: Int
            let stop: Int
        }

        private struct LoopContext {
            var exitTarget: Int
            var loopBlocks: Set<Int>
            var terminalExitLeavesByEntry: [Int: [Int]]
            var terminalExitOwnersByEntry: [Int: Int]
            var continuationGotoTargets: Set<Int>
            var continuationGotoOwnersByEntry: [Int: Int]
        }

        init(cfg: CFG, instructions: [MacIRInstruction], diagnostics: Diagnostics,
             fallbackPolicy: FallbackPolicy, certifiedBy plan: DecodedScalarCFGPlan? = nil,
             allowRejoiningContinuationGotos: Bool = false) {
            self.cfg = cfg
            self.instructions = instructions
            self.diagnostics = diagnostics
            self.fallbackPolicy = fallbackPolicy
            self.allowRejoiningContinuationGotos = allowRejoiningContinuationGotos
            self.certifiedConditions = plan?.branchConditions
            self.certifiedTestPrefixStarts = plan?.testPrefixStarts ?? [:]
        }

        /// Count ownership, rather than taking a set union that can conceal a
        /// duplicated block. Select absorption claims only from the final tree;
        /// abandoned speculative arms must not contribute source ownership.
        func certifiedBuildResult(for region: Region) -> CertifiedBuildResult? {
            guard certifiedConditions != nil else { return nil }
            var owned = Set<Int>()
            var usedStubs: [Int: Int] = [:]
            func claim(_ block: Int) -> Bool {
                cfg.blocks.indices.contains(block) && owned.insert(block).inserted
            }
            func claimCondition(_ condition: BranchCondition) -> Bool {
                guard condition.compareIndex == nil,
                      let block = blockContaining(instructionIndex: condition.branchIndex).first,
                      lastInstruction(of: block) == condition.branchIndex else { return false }
                return claim(block)
            }
            func visit(_ node: Region) -> Bool {
                switch node {
                case let .sequence(children):
                    return children.allSatisfy(visit)
                case let .ifThen(condition, body, _, _):
                    return claimCondition(condition) && visit(body)
                case let .ifThenElse(condition, thenBody, elseBody, _):
                    return claimCondition(condition) && visit(thenBody) && visit(elseBody)
                case let .whileLoop(condition, body, header):
                    return cfg.blocks.indices.contains(header)
                        && lastInstruction(of: header) == condition.branchIndex
                        && claimCondition(condition) && visit(body)
                case let .doWhileLoop(body, condition):
                    guard claimCondition(condition), visit(body) else { return false }
                    if let stub = certifiedAbsorbedStubs[condition.branchIndex] {
                        guard claim(stub) else { return false }
                        usedStubs[condition.branchIndex] = stub
                    }
                    return true
                case let .block(block):
                    return claim(block)
                case .naturalLoop, .switchDispatch, .gotoLeaf, .irreducible, .certifiedEdge, .certifiedSelection:
                    return false
                }
            }
            guard visit(region), owned == Set(cfg.blocks.indices) else { return nil }
            return CertifiedBuildResult(region: region, absorbedStubs: usedStubs)
        }

        /// Recursively structures the linear chain of blocks beginning at
        /// `entry`, stopping (exclusive) when the chain reaches block `stop`
        /// (the enclosing join/header). Returns `.irreducible` for the whole
        /// chain if any block cannot be cleanly classified.
        mutating func buildRegion(entry: Int, stop: Int?) -> Region {
            buildRegion(entry: entry, stop: stop, loopContext: nil)
        }

        private mutating func buildRegion(
            entry: Int,
            stop: Int?,
            loopContext: LoopContext?,
            skipLoopHeaderAt: Int? = nil
        ) -> Region {
            // Recursion guard: repeat-visit of the same scope or excessive depth
            // means the CFG is not cleanly reducible here — bail to legacy.
            // (`stop == nil` is encoded as -1, never a valid block index.)
            let scope = ScopeKey(entry: entry, stop: stop ?? -1)
            if activeScopes.contains(scope) || depth >= Self.maxDepth {
                diagnostics.recordSite(.recursionGuard)
                diagnostics.recordFatal(.recursionGuard)
                return .irreducible(reachableBlocks(from: entry, stop: stop))
            }
            activeScopes.insert(scope)
            depth += 1
            defer {
                activeScopes.remove(scope)
                depth -= 1
            }

            var items: [Region] = []
            var current: Int? = entry

            while let block = current {
                if let stop, block == stop { break }

                // A do-while's body walk STARTS at the loop's own header (the back-edge
                // target); re-dispatching that block into classifyLoop self-recurses into the
                // recursion guard, which is why multi-block do-whiles never structured before
                // 2026-07-09 (found driving LE-2 — the canonical shared-ret scan loop is
                // latch-tested). The exemption is exactly the OWN header: a genuinely nested
                // inner loop headed at a DIFFERENT block still classifies.
                if cfg.loopHeaders.contains(block), block != skipLoopHeaderAt {
                    guard let loop = classifyLoop(header: block, stop: stop) else {
                        diagnostics.recordFatalFromLastSite(default: .loopShapeUnsupported)
                        return unsupportedRemainder(prefix: items, current: block, entry: entry, stop: stop)
                    }
                    items.append(loop.region)
                    current = loop.next
                    continue
                }

                let terminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: block)].operation)
                switch terminator {
                case .switchDispatch:
                    // The region path only supports a switch whose case targets
                    // are ALL out-of-window exits (no in-graph successors). If
                    // any case resolves to an in-function block, there is a
                    // post-switch join `J` reachable from the case arms plus a
                    // tail; structuring just the dispatch block here and ending
                    // the walk (`current = nil`) would SILENTLY DROP `J` and
                    // every following block. We cannot faithfully render that
                    // shape, so bail to the legacy goto-per-case structurer for
                    // the whole function.
                    guard cfg.blocks[block].successors.isEmpty else {
                        diagnostics.recordSite(.switchHasInGraphSuccessors)
                        diagnostics.recordFatal(.switchHasInGraphSuccessors)
                        return unsupportedRemainder(prefix: items, current: block, entry: entry, stop: stop)
                    }
                    items.append(.block(blockIndex: block))
                    // Switch cases are out-of-window exits in the supported
                    // idiom; nothing structured follows in-graph.
                    current = nil

                case .conditionalBranch:
                    if let loopContext,
                       let terminalExit = loopTerminalExitContinuation(block: block, context: loopContext) {
                        let continuation = buildRegion(
                            entry: terminalExit.continuation,
                            stop: stop,
                            loopContext: loopContext
                        )
                        items.append(.sequence([
                            .block(blockIndex: block),
                            continuation,
                            .gotoLeaf(blocks: terminalExit.blocks)
                        ]))
                        current = nil
                        continue
                    }
                    if let loopContext,
                       cfg.blocks[block].successors.contains(loopContext.exitTarget) {
                        guard let next = loopBreakContinuation(block: block, context: loopContext) else {
                            diagnostics.recordFatalFromLastSite(default: .loopShapeUnsupported)
                            return .irreducible(reachableBlocks(from: entry, stop: stop))
                        }
                        items.append(.block(blockIndex: block))
                        current = next
                        continue
                    }
                    if let loopContext,
                       let next = loopContinuationGotoContinuation(block: block, context: loopContext) {
                        items.append(.block(blockIndex: block))
                        current = next
                        continue
                    }
                    guard let conditional = classifyConditional(block: block, stop: stop) else {
                        diagnostics.recordFatalFromLastSite(default: .conditionalMissingCondition)
                        return unsupportedRemainder(prefix: items, current: block, entry: entry, stop: stop)
                    }
                    items.append(conditional.region)
                    current = conditional.next

                case .returnTerminator, .indirectBranch:
                    items.append(.block(blockIndex: block))
                    current = nil

                case .unconditionalBranch:
                    if let loopContext,
                       cfg.blocks[block].successors.first == loopContext.exitTarget {
                        items.append(.block(blockIndex: block))
                        current = nil
                        continue
                    }
                    items.append(.block(blockIndex: block))
                    current = cfg.blocks[block].successors.first

                case .none:
                    items.append(.block(blockIndex: block))
                    current = cfg.blocks[block].successors.first
                }
            }

            if items.count == 1 { return items[0] }
            return .sequence(items)
        }

        private mutating func unsupportedRemainder(
            prefix: [Region], current: Int, entry: Int, stop: Int?
        ) -> Region {
            if fallbackPolicy == .terminalSuffix, depth == 1,
               entry == cfg.entryIndex, stop == nil,
               let plan = TerminalSuffixRegionPlan.prove(
                   prefix: prefix, suffixEntry: current,
                   suffix: reachableBlocks(from: current, stop: nil),
                   cfg: cfg, instructions: instructions
               ) {
                terminalSuffixPlan = plan
                return plan.region
            }
            return .irreducible(reachableBlocks(from: entry, stop: stop))
        }

        private mutating func loopBreakContinuation(block: Int, context: LoopContext) -> Int? {
            let successors = cfg.blocks[block].successors
            guard successors.count == 2 else {
                diagnostics.recordSite(.conditionalSuccessorCount)
                return nil
            }
            let takenTarget = successors[0]
            let fallThrough = successors[1]
            guard takenTarget == context.exitTarget || fallThrough == context.exitTarget else {
                return nil
            }
            guard takenTarget != context.exitTarget || fallThrough != context.exitTarget else {
                diagnostics.recordSite(.loopBodyEscapes)
                return nil
            }
            guard conditionForStructure(for: block) != nil else {
                diagnostics.recordSite(.conditionalMissingCondition)
                return nil
            }
            let continuation = takenTarget == context.exitTarget ? fallThrough : takenTarget
            guard context.loopBlocks.contains(continuation) else {
                diagnostics.recordSite(.loopBodyEscapes)
                return nil
            }
            return continuation
        }

        private struct LoopTerminalExitContinuation {
            var blocks: [Int]
            var continuation: Int
        }

        private func loopTerminalExitContinuation(block: Int, context: LoopContext) -> LoopTerminalExitContinuation? {
            let successors = cfg.blocks[block].successors
            guard successors.count == 2 else { return nil }
            let takenTarget = successors[0]
            let fallThrough = successors[1]

            if let blocks = context.terminalExitLeavesByEntry[takenTarget] {
                guard context.terminalExitOwnersByEntry[takenTarget] == block,
                      context.loopBlocks.contains(fallThrough) else {
                    return nil
                }
                return LoopTerminalExitContinuation(blocks: blocks, continuation: fallThrough)
            }

            if let blocks = context.terminalExitLeavesByEntry[fallThrough] {
                guard context.terminalExitOwnersByEntry[fallThrough] == block,
                      context.loopBlocks.contains(takenTarget) else {
                    return nil
                }
                return LoopTerminalExitContinuation(blocks: blocks, continuation: takenTarget)
            }

            return nil
        }

        private func loopContinuationGotoContinuation(block: Int, context: LoopContext) -> Int? {
            let successors = cfg.blocks[block].successors
            let terminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: block)].operation)
            guard case .conditionalBranch = terminator,
                  successors.count == 2 else {
                return nil
            }
            let takenTarget = successors[0]
            let fallThrough = successors[1]

            if context.continuationGotoTargets.contains(takenTarget) {
                guard context.continuationGotoOwnersByEntry[takenTarget] == block,
                      context.loopBlocks.contains(fallThrough) else {
                    return nil
                }
                return fallThrough
            }

            if context.continuationGotoTargets.contains(fallThrough) {
                guard context.continuationGotoOwnersByEntry[fallThrough] == block,
                      context.loopBlocks.contains(takenTarget) else {
                    return nil
                }
                return takenTarget
            }

            return nil
        }

        // MARK: Conditional classification (if-then / if-then-else)

        private struct Classified {
            var region: Region
            var next: Int?
        }

        private mutating func classifyConditional(block: Int, stop: Int?) -> Classified? {
            let successors = cfg.blocks[block].successors
            guard successors.count == 2 else {
                diagnostics.recordSite(.conditionalSuccessorCount)
                return nil
            }
            guard let condition = conditionForStructure(for: block, allowNonAdjacentCompare: true) else {
                diagnostics.recordSite(.conditionalMissingCondition)
                return nil
            }

            // Successor[0] is the branch TAKEN target, successor[1] is the
            // fall-through (edge construction appends target before fall-through).
            let takenTarget = successors[0]
            let fallThrough = successors[1]

            // Immediate post-dominator of the branch block = structural join.
            guard let join = cfg.postDomTree[block], join != block, join < cfg.blocks.count else {
                // No in-graph join: both successors reach the function exit. This is the
                // early-exit (guard-clause) shape — try to recover it before bailing.
                return classifyEarlyExit(
                    condition: condition,
                    takenTarget: takenTarget,
                    fallThrough: fallThrough,
                    branch: block,
                    stop: stop
                )
            }

            // Over-reach guard: this conditional lives inside an enclosing scope
            // bounded (exclusive) by `stop`. When `stop` is a FORWARD boundary
            // (the enclosing arm's join, i.e. ahead of this block), an inner
            // join that lands strictly PAST it would let the inner arm claim
            // blocks belonging to the OUTER sequence — producing wrong structure
            // or double-emitted blocks. (`join == stop` is the legitimate case
            // of an inner conditional whose join IS the arm boundary.) The
            // legacy structurer renders this shape faithfully, so bail.
            //
            // We require `stop > block` so this never fires when `stop` is a
            // loop HEADER (a backward target with a smaller index than `block`):
            // a loop body legitimately contains conditionals whose joins sit
            // inside the loop but numerically above the header, and the body
            // walk already stops at the header via the `block == stop` check.
            if let stop, stop > block, join > stop {
                diagnostics.recordSite(.conditionalOverReachesStop)
                return nil
            }

            // The header line renders the INVERTED branch condition (the C
            // `if (...)` guards entry into the fallthrough body). So the
            // fallthrough is the then-body; the taken target is either the join
            // (if-then) or the else-body (if-then-else).
            if takenTarget == join {
                // if-then: body = fallthrough chain up to join.
                guard let body = structuredSubregion(entry: fallThrough, join: join, stop: stop) else {
                    diagnostics.recordSite(.ifThenBodyUnstructured)
                    return nil
                }
                return Classified(region: .ifThen(cond: condition, body: body, join: join, inverted: true), next: join)
            }

            // Taken-edge if-then (hot/cold split): the fall-through goes straight
            // to the join, so the conditional body lives on the branch-TAKEN
            // edge. `if (RAW cc) { takenArm } join` is faithful — entering the
            // body IS "branch taken", so the guard uses the non-inverted
            // condition. The taken arm must be a clean single-entry region whose
            // only exit is the join, exactly like a fall-through then-body.
            if fallThrough == join {
                guard let body = structuredSubregion(entry: takenTarget, join: join, stop: stop) else {
                    diagnostics.recordSite(.ifElseTakenBodyOrientation)
                    return nil
                }
                return Classified(region: .ifThen(cond: condition, body: body, join: join, inverted: false), next: join)
            }
            let thenBody = structuredSubregion(entry: fallThrough, join: join, stop: stop)
            let elseBody = structuredSubregion(entry: takenTarget, join: join, stop: stop)
            guard let thenBody, let elseBody else {
                // Attribution: distinguish the compiler-merged SHARED-TAIL shape
                // (both arms reach common blocks — the dominance failure that
                // isCleanArm rejects) from other arm pathologies, and whether
                // the shared blocks are exit-only (a goto-leaf could reference
                // them once) or re-join the diamond (cross edges; hard).
                if diagnostics.enabled {
                    let thenReach = reachableSet(from: fallThrough, stopAt: join)
                    let elseReach = reachableSet(from: takenTarget, stopAt: join)
                    let shared = thenReach.intersection(elseReach)
                    if shared.isEmpty {
                        diagnostics.recordSite(.ifElseArmUnstructured)
                    } else if shared.contains(where: { canReach(from: $0, target: join) }) {
                        diagnostics.recordSite(.ifElseArmsShareRejoiningTail)
                    } else {
                        diagnostics.recordSite(.ifElseArmsShareExitTail)
                    }
                }
                if let classified = classifyRejoiningTailGotoLeaf(
                    condition: condition,
                    branch: block,
                    takenTarget: takenTarget,
                    fallThrough: fallThrough,
                    join: join,
                    stop: stop
                ) {
                    return classified
                }
                return nil
            }
            return Classified(
                region: .ifThenElse(cond: condition, then: thenBody, els: elseBody, join: join),
                next: join
            )
        }

        /// Builds the region for a branch arm `entry..join`, requiring that the
        /// arm is a single-entry region whose only exit is `join`. Returns nil
        /// if the arm escapes elsewhere (so the caller bails to legacy).
        private mutating func structuredSubregion(entry: Int, join: Int, stop: Int?) -> Region? {
            guard entry != join else { return .sequence([]) }
            // Verify the arm is dominated by `entry` and post-dominated by join,
            // i.e. a clean single-entry/single-exit region.
            guard isCleanArm(entry: entry, join: join) else {
                diagnostics.recordSite(.armDominanceFailed)
                return nil
            }
            return buildRegion(entry: entry, stop: join)
        }

        /// Diagnostics-only: the set of blocks reachable from `entry` without
        /// passing through `stopAt` (exclusive of `stopAt` itself).
        private func reachableSet(from entry: Int, stopAt: Int) -> Set<Int> {
            var visited: Set<Int> = []
            var stack = [entry]
            while let block = stack.popLast() {
                if block == stopAt || visited.contains(block) { continue }
                visited.insert(block)
                for succ in cfg.blocks[block].successors { stack.append(succ) }
            }
            return visited
        }

        /// Diagnostics-only: true iff `target` is reachable from `from`.
        private func canReach(from: Int, target: Int) -> Bool {
            var visited: Set<Int> = []
            var stack = [from]
            while let block = stack.popLast() {
                if block == target { return true }
                if visited.contains(block) { continue }
                visited.insert(block)
                for succ in cfg.blocks[block].successors { stack.append(succ) }
            }
            return false
        }

        /// True iff every block reachable from `entry` without passing through
        /// `join` ultimately funnels to `join` (clean SESE arm) and `entry`
        /// dominates that set.
        private func isCleanArm(entry: Int, join: Int) -> Bool {
            var visited: Set<Int> = []
            var stack = [entry]
            while let block = stack.popLast() {
                if block == join { continue }
                if visited.contains(block) { continue }
                visited.insert(block)
                // entry must dominate every block in the arm.
                guard CFGBuilder.dominates(entry, block, domTree: cfg.domTree) else { return false }
                let successors = cfg.blocks[block].successors
                if successors.isEmpty {
                    // An exit (return) inside the arm that never reaches join is
                    // fine ONLY if it is a clean terminator; treat as part of arm.
                    continue
                }
                for succ in successors { stack.append(succ) }
            }
            return true
        }

        // MARK: Early-exit (guard clause)

        /// Recovers `if (!cc) { exitArm } continuation` for a conditional with NO in-graph
        /// post-dominator join: the fall-through arm always exits the function and the taken
        /// target is the continuation. Only this orientation is faithfully expressible via the
        /// inverted-condition `ifThen` emitter (the C `if` guards entry into the FALL-THROUGH),
        /// so a *taken*-exits guard bails to legacy rather than guess.
        ///
        /// Faithfulness: the fall-through arm and the continuation are each entered ONLY through
        /// this branch (dominated by it), and the arm reaches the function exit on every path
        /// without ever reaching the continuation. So `if (!cc) { arm…; return } continuation`
        /// has exactly the branch's semantics, the arm and continuation are disjoint block sets
        /// (the arm is dominated by the fall-through, the continuation cannot reach it), and the
        /// continuation is emitted once as the branch's successor with no other entry.
        private mutating func classifyEarlyExit(
            condition: BranchCondition,
            takenTarget: Int,
            fallThrough: Int,
            branch: Int,
            stop: Int?
        ) -> Classified? {
            let fallthroughFailure = earlyExitArmFailure(
                orientation: .fallthroughArm,
                armEntry: fallThrough,
                continuation: takenTarget,
                branch: branch
            )
            guard fallthroughFailure == nil else {
                // Attribution probe: distinguish the MIRRORED orientation (the
                // TAKEN edge is the clean exit arm, fall-through is the
                // continuation) from a genuinely messy arm — and split the
                // mirror by predecessor count: a single-pred taken arm is
                // privately owned by this guard (orientation fix suffices),
                // while a multi-pred arm is a SHARED exit tail (`if (err)
                // goto fail` idiom; needs a goto-leaf/shared-tail design).
                let takenFailure = earlyExitArmFailure(
                    orientation: .takenArm,
                    armEntry: takenTarget,
                    continuation: fallThrough,
                    branch: branch
                )
                if takenFailure == nil {
                    diagnostics.recordSite(
                        cfg.blocks[takenTarget].predecessors.count == 1
                            ? .earlyExitTakenSinglePred
                            : .earlyExitTakenSharedExit
                    )
                    if let classified = classifyTerminalSharedExitGotoLeaf(
                        branch: branch,
                        takenTarget: takenTarget,
                        fallThrough: fallThrough,
                        stop: stop
                    ) {
                        return classified
                    }
                } else {
                    diagnostics.recordSite(earlyExitVeto(
                        orientation: .fallthroughArm,
                        failure: fallthroughFailure!
                    ))
                }
                return nil
            }
            // Over-reach guard (mirrors the in-graph-join case): a continuation past the
            // enclosing scope boundary would steal blocks belonging to the outer sequence.
            if let stop, stop > branch, takenTarget > stop {
                diagnostics.recordSite(.earlyExitOverReachesStop)
                return nil
            }
            let body = buildRegion(entry: fallThrough, stop: takenTarget)
            return Classified(
                region: .ifThen(cond: condition, body: body, join: takenTarget, inverted: true),
                next: takenTarget
            )
        }

        private func earlyExitArmFailure(
            orientation: EarlyExitOrientation,
            armEntry: Int,
            continuation: Int,
            branch: Int
        ) -> EarlyExitArmFailure? {
            let cause: EarlyExitArmFailureCause?
            if !CFGBuilder.dominates(branch, armEntry, domTree: cfg.domTree)
                || !CFGBuilder.dominates(branch, continuation, domTree: cfg.domTree) {
                cause = .branchDominanceFailed
            } else {
                cause = cleanExitArmFailure(entry: armEntry, continuation: continuation)
            }
            guard let cause else { return nil }
            return EarlyExitArmFailure(
                cause: cause,
                isInLoop: isBlockInNaturalLoop(branch),
                isAcyclic: isAcyclicArm(entry: armEntry),
                hasNoreturnTail: hasSuccessorlessNoreturnTerminalTail(entry: armEntry)
            )
        }

        private func earlyExitVeto(
            orientation: EarlyExitOrientation,
            failure: EarlyExitArmFailure
        ) -> Veto {
            switch (
                orientation,
                failure.cause,
                failure.isInLoop,
                failure.isAcyclic,
                failure.hasNoreturnTail
            ) {
            case (.fallthroughArm, .branchDominanceFailed, false, true, false):
                return .earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail
            case (.fallthroughArm, .branchDominanceFailed, false, true, true):
                return .earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicNoreturnTail
            case (.fallthroughArm, .branchDominanceFailed, false, false, false):
                return .earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicPlainTail
            case (.fallthroughArm, .branchDominanceFailed, false, false, true):
                return .earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicNoreturnTail
            case (.fallthroughArm, .branchDominanceFailed, true, true, false):
                return .earlyExitFallthroughBranchDominanceFailedInLoopAcyclicPlainTail
            case (.fallthroughArm, .branchDominanceFailed, true, true, true):
                return .earlyExitFallthroughBranchDominanceFailedInLoopAcyclicNoreturnTail
            case (.fallthroughArm, .branchDominanceFailed, true, false, false):
                return .earlyExitFallthroughBranchDominanceFailedInLoopCyclicPlainTail
            case (.fallthroughArm, .branchDominanceFailed, true, false, true):
                return .earlyExitFallthroughBranchDominanceFailedInLoopCyclicNoreturnTail
            case (.fallthroughArm, .reachesContinuation, false, true, false):
                return .earlyExitFallthroughReachesContinuationOutOfLoopAcyclicPlainTail
            case (.fallthroughArm, .reachesContinuation, false, true, true):
                return .earlyExitFallthroughReachesContinuationOutOfLoopAcyclicNoreturnTail
            case (.fallthroughArm, .reachesContinuation, false, false, false):
                return .earlyExitFallthroughReachesContinuationOutOfLoopCyclicPlainTail
            case (.fallthroughArm, .reachesContinuation, false, false, true):
                return .earlyExitFallthroughReachesContinuationOutOfLoopCyclicNoreturnTail
            case (.fallthroughArm, .reachesContinuation, true, true, false):
                return .earlyExitFallthroughReachesContinuationInLoopAcyclicPlainTail
            case (.fallthroughArm, .reachesContinuation, true, true, true):
                return .earlyExitFallthroughReachesContinuationInLoopAcyclicNoreturnTail
            case (.fallthroughArm, .reachesContinuation, true, false, false):
                return .earlyExitFallthroughReachesContinuationInLoopCyclicPlainTail
            case (.fallthroughArm, .reachesContinuation, true, false, true):
                return .earlyExitFallthroughReachesContinuationInLoopCyclicNoreturnTail
            case (.fallthroughArm, .armDominanceFailed, false, true, false):
                return .earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail
            case (.fallthroughArm, .armDominanceFailed, false, true, true):
                return .earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicNoreturnTail
            case (.fallthroughArm, .armDominanceFailed, false, false, false):
                return .earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicPlainTail
            case (.fallthroughArm, .armDominanceFailed, false, false, true):
                return .earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicNoreturnTail
            case (.fallthroughArm, .armDominanceFailed, true, true, false):
                return .earlyExitFallthroughArmDominanceFailedInLoopAcyclicPlainTail
            case (.fallthroughArm, .armDominanceFailed, true, true, true):
                return .earlyExitFallthroughArmDominanceFailedInLoopAcyclicNoreturnTail
            case (.fallthroughArm, .armDominanceFailed, true, false, false):
                return .earlyExitFallthroughArmDominanceFailedInLoopCyclicPlainTail
            case (.fallthroughArm, .armDominanceFailed, true, false, true):
                return .earlyExitFallthroughArmDominanceFailedInLoopCyclicNoreturnTail
            case (.takenArm, .branchDominanceFailed, false, true, false):
                return .earlyExitTakenBranchDominanceFailedOutOfLoopAcyclicPlainTail
            case (.takenArm, .branchDominanceFailed, false, true, true):
                return .earlyExitTakenBranchDominanceFailedOutOfLoopAcyclicNoreturnTail
            case (.takenArm, .branchDominanceFailed, false, false, false):
                return .earlyExitTakenBranchDominanceFailedOutOfLoopCyclicPlainTail
            case (.takenArm, .branchDominanceFailed, false, false, true):
                return .earlyExitTakenBranchDominanceFailedOutOfLoopCyclicNoreturnTail
            case (.takenArm, .branchDominanceFailed, true, true, false):
                return .earlyExitTakenBranchDominanceFailedInLoopAcyclicPlainTail
            case (.takenArm, .branchDominanceFailed, true, true, true):
                return .earlyExitTakenBranchDominanceFailedInLoopAcyclicNoreturnTail
            case (.takenArm, .branchDominanceFailed, true, false, false):
                return .earlyExitTakenBranchDominanceFailedInLoopCyclicPlainTail
            case (.takenArm, .branchDominanceFailed, true, false, true):
                return .earlyExitTakenBranchDominanceFailedInLoopCyclicNoreturnTail
            case (.takenArm, .reachesContinuation, false, true, false):
                return .earlyExitTakenReachesContinuationOutOfLoopAcyclicPlainTail
            case (.takenArm, .reachesContinuation, false, true, true):
                return .earlyExitTakenReachesContinuationOutOfLoopAcyclicNoreturnTail
            case (.takenArm, .reachesContinuation, false, false, false):
                return .earlyExitTakenReachesContinuationOutOfLoopCyclicPlainTail
            case (.takenArm, .reachesContinuation, false, false, true):
                return .earlyExitTakenReachesContinuationOutOfLoopCyclicNoreturnTail
            case (.takenArm, .reachesContinuation, true, true, false):
                return .earlyExitTakenReachesContinuationInLoopAcyclicPlainTail
            case (.takenArm, .reachesContinuation, true, true, true):
                return .earlyExitTakenReachesContinuationInLoopAcyclicNoreturnTail
            case (.takenArm, .reachesContinuation, true, false, false):
                return .earlyExitTakenReachesContinuationInLoopCyclicPlainTail
            case (.takenArm, .reachesContinuation, true, false, true):
                return .earlyExitTakenReachesContinuationInLoopCyclicNoreturnTail
            case (.takenArm, .armDominanceFailed, false, true, false):
                return .earlyExitTakenArmDominanceFailedOutOfLoopAcyclicPlainTail
            case (.takenArm, .armDominanceFailed, false, true, true):
                return .earlyExitTakenArmDominanceFailedOutOfLoopAcyclicNoreturnTail
            case (.takenArm, .armDominanceFailed, false, false, false):
                return .earlyExitTakenArmDominanceFailedOutOfLoopCyclicPlainTail
            case (.takenArm, .armDominanceFailed, false, false, true):
                return .earlyExitTakenArmDominanceFailedOutOfLoopCyclicNoreturnTail
            case (.takenArm, .armDominanceFailed, true, true, false):
                return .earlyExitTakenArmDominanceFailedInLoopAcyclicPlainTail
            case (.takenArm, .armDominanceFailed, true, true, true):
                return .earlyExitTakenArmDominanceFailedInLoopAcyclicNoreturnTail
            case (.takenArm, .armDominanceFailed, true, false, false):
                return .earlyExitTakenArmDominanceFailedInLoopCyclicPlainTail
            case (.takenArm, .armDominanceFailed, true, false, true):
                return .earlyExitTakenArmDominanceFailedInLoopCyclicNoreturnTail
            }
        }

        private func isBlockInNaturalLoop(_ block: Int) -> Bool {
            for edge in cfg.backEdges {
                if naturalLoopBody(header: edge.to, latch: edge.from).contains(block) {
                    return true
                }
            }
            return false
        }

        private func isAcyclicArm(entry: Int) -> Bool {
            let reachable = Set(reachableBlocks(from: entry, stop: nil))
            for edge in cfg.backEdges where reachable.contains(edge.from) && reachable.contains(edge.to) {
                return false
            }
            return !containsCycle(in: reachable)
        }

        private func containsCycle(in blocks: Set<Int>) -> Bool {
            var visiting: Set<Int> = []
            var visited: Set<Int> = []

            func visit(_ block: Int) -> Bool {
                if visiting.contains(block) { return true }
                if visited.contains(block) { return false }
                visiting.insert(block)
                for successor in cfg.blocks[block].successors where blocks.contains(successor) {
                    if visit(successor) { return true }
                }
                visiting.remove(block)
                visited.insert(block)
                return false
            }

            for block in blocks {
                if visit(block) { return true }
            }
            return false
        }

        private func hasSuccessorlessNoreturnTerminalTail(entry: Int) -> Bool {
            let reachable = reachableBlocks(from: entry, stop: nil)
            let terminalBlocks = reachable.filter { cfg.blocks[$0].successors.isEmpty }
            guard !terminalBlocks.isEmpty else { return false }
            return terminalBlocks.allSatisfy { block in
                let lastIndex = lastInstruction(of: block)
                guard instructions.indices.contains(lastIndex) else { return false }
                if case .call = instructions[lastIndex].operation {
                    return true
                }
                return false
            }
        }

        private mutating func classifyTerminalSharedExitGotoLeaf(
            branch: Int,
            takenTarget: Int,
            fallThrough: Int,
            stop: Int?
        ) -> Classified? {
            guard let exitBlocks = terminalGotoLeafBlocks(
                entry: takenTarget,
                rejecting: [branch, fallThrough],
                branch: branch,
                stop: stop,
                overReachVeto: .earlyExitOverReachesStop
            ) else {
                return nil
            }
            if canReach(from: fallThrough, target: takenTarget) {
                let continuation = buildRegion(entry: fallThrough, stop: takenTarget)
                return Classified(
                    region: .sequence([
                        .block(blockIndex: branch),
                        continuation,
                        .gotoLeaf(blocks: exitBlocks)
                    ]),
                    next: nil
                )
            }
            return Classified(
                region: .sequence([
                    .block(blockIndex: branch),
                    .gotoLeaf(blocks: exitBlocks)
                ]),
                next: fallThrough
            )
        }

        private mutating func terminalGotoLeafBlocks(
            entry: Int,
            rejecting rejectedBlocks: Set<Int>,
            branch: Int?,
            stop: Int?,
            overReachVeto: Veto? = nil
        ) -> [Int]? {
            let exitBlocks = reachableBlocks(from: entry, stop: nil)
            let exitSet = Set(exitBlocks)
            guard !exitSet.isEmpty,
                  exitSet.isDisjoint(with: rejectedBlocks) else {
                return nil
            }
            if let stop, let branch, stop > branch, exitBlocks.contains(where: { $0 > stop }) {
                if let overReachVeto {
                    diagnostics.recordSite(overReachVeto)
                }
                return nil
            }
            guard isContiguousBlockSet(exitSet),
                  allPathsReachFunctionExitWithinLeaf(entry: entry, leafBlocks: exitSet) else {
                return nil
            }
            return exitBlocks
        }

        private mutating func classifyRejoiningTailGotoLeaf(
            condition: BranchCondition,
            branch: Int,
            takenTarget: Int,
            fallThrough: Int,
            join: Int,
            stop: Int?
        ) -> Classified? {
            let thenReach = reachableSet(from: fallThrough, stopAt: join)
            let elseReach = reachableSet(from: takenTarget, stopAt: join)
            let shared = thenReach.intersection(elseReach)
            let rejoiningShared = shared.filter { canReach(from: $0, target: join) }
            guard !rejoiningShared.isEmpty else {
                diagnostics.recordSite(.gotoLeafRejoiningNoSharedTail)
                return nil
            }

            let entryBlocks = sharedTailEntryBlocks(in: rejoiningShared)
            guard entryBlocks.count == 1, let leafEntry = entryBlocks.first else {
                diagnostics.recordSite(.gotoLeafRejoiningDoubleReachable)
                diagnoseRejoiningTail(reason: "shared-entry-count", branch: branch, join: join,
                    stop: stop, leafBlocks: rejoiningShared)
                return nil
            }

            let leafBlocks = Set(reachableBlocks(from: leafEntry, stop: join))
            guard leafBlocks == rejoiningShared,
                  !leafBlocks.contains(branch),
                  !leafBlocks.contains(fallThrough),
                  !leafBlocks.contains(takenTarget),
                  !leafBlocks.contains(join) else {
                diagnostics.recordSite(.gotoLeafRejoiningAmbiguousEntry)
                return nil
            }

            if let stop, stop > branch {
                let claimedBlocks = leafBlocks.union([join])
                if claimedBlocks.contains(where: { $0 > stop }) {
                    diagnostics.recordSite(.gotoLeafRejoiningOverReachesStop)
                    return nil
                }
            }

            guard isContiguousBlockSet(leafBlocks) else {
                diagnostics.recordSite(.gotoLeafRejoiningNonContiguous)
                return nil
            }

            guard allPathsReachContinuationWithinLeaf(
                entry: leafEntry,
                continuation: join,
                leafBlocks: leafBlocks
            ) else {
                diagnostics.recordSite(.gotoLeafRejoiningLeafEscapes)
                return nil
            }

            let continuationReentersLeaf: Bool
            if allowRejoiningContinuationGotos, let stop {
                // The enclosing region owns the boundary and what follows it.
                // Reaching this leaf in a later loop iteration does not claim
                // it twice within the current continuation.
                continuationReentersLeaf = !reachableSet(from: join, stopAt: stop)
                    .isDisjoint(with: leafBlocks)
            } else {
                continuationReentersLeaf = leafBlocks.contains { canReach(from: join, target: $0) }
            }
            if continuationReentersLeaf {
                diagnostics.recordSite(.gotoLeafRejoiningDoubleReachable)
                diagnoseRejoiningTail(reason: "continuation-reentry", branch: branch, join: join,
                    stop: stop, leafBlocks: leafBlocks)
                return nil
            }

            let thenPrivate = thenReach.subtracting(leafBlocks)
            let elsePrivate = elseReach.subtracting(leafBlocks)
            guard thenPrivate.isDisjoint(with: elsePrivate),
                  leafHasOnlyOwnedExternalPredecessors(
                    leafEntry: leafEntry,
                    leafBlocks: leafBlocks,
                    allowedPredecessors: thenPrivate.union(elsePrivate)
                  ) else {
                diagnostics.recordSite(.gotoLeafRejoiningDoubleReachable)
                diagnoseRejoiningTail(reason: "private-partition-or-external-predecessor",
                    branch: branch, join: join, stop: stop, leafBlocks: leafBlocks)
                return nil
            }

            var diamondCondition = condition
            guard let thenPartial = partialRejoiningArmRegion(
                    entry: fallThrough,
                    ownedBlocks: thenPrivate,
                    leafBlocks: leafBlocks,
                    continuation: join,
                    continuationGotoTargets: &diamondCondition.continuationGotoTargets
                  ),
                  let elsePartial = partialRejoiningArmRegion(
                    entry: takenTarget,
                    ownedBlocks: elsePrivate,
                    leafBlocks: leafBlocks,
                    continuation: join,
                    continuationGotoTargets: &diamondCondition.continuationGotoTargets
                  ) else {
                diagnostics.recordSite(.gotoLeafRejoiningArmUnstructured)
                return nil
            }

            let continuation: Region
            let next: Int?
            if join == stop {
                continuation = .sequence([])
                next = stop
            } else {
                continuation = buildRegion(entry: join, stop: stop)
                guard !containsIrreducible(continuation) else {
                    diagnostics.recordSite(.gotoLeafRejoiningContinuationUnstructured)
                    return nil
                }
                if let stop, canReach(from: join, target: stop) {
                    next = stop
                } else {
                    next = nil
                }
            }

            let diamond = Region.ifThenElse(
                cond: diamondCondition,
                then: thenPartial,
                els: elsePartial,
                join: leafEntry
            )
            let diamondBlocks = emittedBlockSet(in: diamond)
            let continuationBlocks = emittedBlockSet(in: continuation)
            guard leafBlocks.isDisjoint(with: diamondBlocks),
                  leafBlocks.isDisjoint(with: continuationBlocks),
                  diamondBlocks.isDisjoint(with: continuationBlocks) else {
                diagnostics.recordSite(.gotoLeafRejoiningPartition)
                return nil
            }

            diagnostics.recordSite(.gotoLeafRejoiningEmitted)
            return Classified(
                region: .sequence([
                    diamond,
                    .gotoLeaf(blocks: leafBlocks.sorted()),
                    continuation
                ]),
                next: next
            )
        }

        private func diagnoseRejoiningTail(
            reason: String, branch: Int, join: Int, stop: Int?, leafBlocks: Set<Int>
        ) {
            guard diagnostics.enabled else { return }
            func address(_ block: Int) -> String {
                "0x\(String(blockStartAddress(block), radix: 16))"
            }
            let leaves = leafBlocks.sorted().map(address).joined(separator: ",")
            let entries = sharedTailEntryBlocks(in: leafBlocks).sorted().map(address).joined(separator: ",")
            let external = leafBlocks.sorted().flatMap { block in
                cfg.blocks[block].predecessors.filter { !leafBlocks.contains($0) }.map {
                    "\(address($0))->\(address(block))"
                }
            }.joined(separator: ",")
            let message = "REGIONTREE_REJOINING_TAIL\treason=\(reason)\tbranch=\(address(branch))\tjoin=\(address(join))\tstop=\(stop.map(address) ?? "none")\tleaf=\(leaves)\tentries=\(entries)\texternal=\(external)\n"
            if let data = message.data(using: .utf8) { FileHandle.standardError.write(data) }
        }

        private func sharedTailEntryBlocks(in sharedBlocks: Set<Int>) -> Set<Int> {
            Set(sharedBlocks.filter { block in
                cfg.blocks[block].predecessors.contains { !sharedBlocks.contains($0) }
            })
        }

        private func leafHasOnlyOwnedExternalPredecessors(
            leafEntry: Int,
            leafBlocks: Set<Int>,
            allowedPredecessors: Set<Int>
        ) -> Bool {
            for block in leafBlocks {
                for predecessor in cfg.blocks[block].predecessors where !leafBlocks.contains(predecessor) {
                    guard block == leafEntry,
                          allowedPredecessors.contains(predecessor) else {
                        return false
                    }
                }
            }
            return true
        }

        private func allPathsReachContinuationWithinLeaf(
            entry: Int,
            continuation: Int,
            leafBlocks: Set<Int>
        ) -> Bool {
            var visiting: Set<Int> = []
            var memo: [Int: Bool] = [:]
            return allPathsReachContinuationWithinLeaf(
                from: entry,
                continuation: continuation,
                leafBlocks: leafBlocks,
                visiting: &visiting,
                memo: &memo
            )
        }

        private func allPathsReachContinuationWithinLeaf(
            from block: Int,
            continuation: Int,
            leafBlocks: Set<Int>,
            visiting: inout Set<Int>,
            memo: inout [Int: Bool]
        ) -> Bool {
            if block == continuation { return true }
            guard leafBlocks.contains(block) else { return false }
            if let cached = memo[block] { return cached }
            if visiting.contains(block) { return false }
            let successors = cfg.blocks[block].successors
            guard !successors.isEmpty else {
                memo[block] = false
                return false
            }
            visiting.insert(block)
            defer { visiting.remove(block) }
            for successor in successors {
                guard successor == continuation
                        || (leafBlocks.contains(successor)
                            && allPathsReachContinuationWithinLeaf(
                                from: successor,
                                continuation: continuation,
                                leafBlocks: leafBlocks,
                                visiting: &visiting,
                                memo: &memo
                            )) else {
                    memo[block] = false
                    return false
                }
            }
            memo[block] = true
            return true
        }

        private mutating func partialRejoiningArmRegion(
            entry: Int,
            ownedBlocks: Set<Int>,
            leafBlocks: Set<Int>,
            continuation: Int,
            continuationGotoTargets: inout Set<Int>,
            nestingDepth: Int = 0
        ) -> Region? {
            func rejected(_ reason: String, at block: Int) -> Region? {
                if diagnostics.enabled {
                    let current = cfg.blocks[block]
                    let terminal = instructions[current.endIndex - 1]
                    let successors = current.successors.map { successor in
                        let role = successor == continuation ? "continuation"
                            : ownedBlocks.contains(successor) ? "owned"
                            : leafBlocks.contains(successor) ? "leaf" : "outside"
                        let target = cfg.blocks[successor]
                        let synthetic = target.instructionRange.filter {
                            instructions[$0].source.syntheticPhiEdge != nil
                        }.count
                        return "\(successor):0x\(String(blockStartAddress(successor), radix: 16)):\(role):synthetic=\(synthetic)"
                    }.joined(separator: ",")
                    let message = "REGIONTREE_REJOINING_ARM\treason=\(reason)\tentry=0x\(String(blockStartAddress(entry), radix: 16))\tblock=\(block)\tpc=0x\(String(terminal.source.address, radix: 16))\tmnemonic=\(terminal.source.mnemonic)\tsuccessors=\(successors)\n"
                    if let data = message.data(using: .utf8) { FileHandle.standardError.write(data) }
                }
                return nil
            }
            guard ownedBlocks.contains(entry) else { return rejected("entry-not-owned", at: entry) }
            guard nestingDepth < Self.maxDepth else { return rejected("private-arm-depth-limit", at: entry) }
            let hasSyntheticPhiEdges = ownedBlocks.contains { block in
                cfg.blocks[block].instructionRange.contains {
                    instructions[$0].source.syntheticPhiEdge != nil
                }
            }

            var items: [Region] = []
            var visited: Set<Int> = []
            var current: Int? = entry
            while let block = current {
                guard ownedBlocks.contains(block), !visited.contains(block) else {
                    return rejected("walk-revisits-or-leaves-owned-blocks", at: block)
                }
                visited.insert(block)
                items.append(.block(blockIndex: block))

                let terminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: block)].operation)
                let successors = cfg.blocks[block].successors
                guard successors.allSatisfy({ ownedBlocks.contains($0) || leafBlocks.contains($0) || $0 == continuation }) else {
                    return rejected("successor-outside-partition", at: block)
                }

                switch terminator {
                case .conditionalBranch:
                    guard successors.count == 2 else { return rejected("conditional-successor-count", at: block) }
                    let takenTarget = successors[0]
                    let fallThrough = successors[1]
                    if ownedBlocks.contains(takenTarget),
                       !visited.contains(takenTarget),
                       cfg.blocks[takenTarget].predecessors == [block],
                       cfg.blocks[takenTarget].successors == [continuation],
                       case .unconditionalBranch = CFGBuilder.terminatorKind(
                           of: instructions[lastInstruction(of: takenTarget)].operation),
                       cfg.blocks[takenTarget].instructionRange.allSatisfy({
                           instructions[$0].source.syntheticPhiEdge != nil
                       }),
                       ownedBlocks.contains(fallThrough) || leafBlocks.contains(fallThrough),
                       var condition = conditionForStructure(for: block, allowNonAdjacentCompare: true) {
                        // Copy splitting does not change the original predicate.
                        // Recover it as for any other conditional arm, retaining
                        // leading compare effects when they are not absorbed.
                        // A split SSA edge must execute its copies only on the
                        // taken path and retain the jump over the shared leaf.
                        condition.continuationGotoTargets.insert(continuation)
                        // Preserve the original raw branch comparison when
                        // adding the conditional copy body.
                        condition.isZeroCheck = false
                        items.removeLast()
                        items.append(.ifThen(cond: condition,
                            body: .gotoLeaf(blocks: [takenTarget]), join: continuation, inverted: false))
                        visited.insert(takenTarget)
                        current = ownedBlocks.contains(fallThrough) ? fallThrough : nil
                        continue
                    }
                    if allowRejoiningContinuationGotos,
                       ownedBlocks.contains(takenTarget),
                       ownedBlocks.contains(fallThrough) {
                        // A private arm can itself branch before reaching the
                        // shared leaf. Compose disjoint private subtrees once;
                        // neither subtree may claim a prior block or enter the
                        // other subtree through an unowned edge.
                        func privateBlocks(from start: Int) -> Set<Int>? {
                            var pending = [start]
                            var blocks: Set<Int> = []
                            while let next = pending.popLast() {
                                if next == continuation || leafBlocks.contains(next) { continue }
                                guard ownedBlocks.contains(next), !visited.contains(next) else { return nil }
                                if !blocks.insert(next).inserted { continue }
                                guard !cfg.blocks[next].successors.isEmpty else { return nil }
                                pending.append(contentsOf: cfg.blocks[next].successors)
                            }
                            return blocks
                        }
                        guard let takenBlocks = privateBlocks(from: takenTarget),
                              let fallBlocks = privateBlocks(from: fallThrough)
                        else { return rejected("nested-private-arm-reachability", at: block) }
                        if takenBlocks.isStrictSubset(of: fallBlocks)
                            || fallBlocks.isStrictSubset(of: takenBlocks) {
                            // One successor starts the common suffix. Execute
                            // only the other successor's exclusive prefix under
                            // the predicate, then emit that suffix exactly once.
                            let common = takenBlocks.isSubset(of: fallBlocks) ? takenTarget : fallThrough
                            let exclusiveEntry = common == takenTarget ? fallThrough : takenTarget
                            let exclusive = takenBlocks.symmetricDifference(fallBlocks)
                            guard takenBlocks.union(fallBlocks) == ownedBlocks.subtracting(visited),
                                  !containsCycle(in: exclusive),
                                  isContiguousBlockSet(exclusive),
                                  leafHasOnlyOwnedExternalPredecessors(
                                    leafEntry: exclusiveEntry, leafBlocks: exclusive,
                                    allowedPredecessors: [block]),
                                  allPathsReachContinuationWithinLeaf(
                                    entry: exclusiveEntry, continuation: common, leafBlocks: exclusive),
                                  let condition = conditionForStructure(for: block, allowNonAdjacentCompare: true),
                                  let body = structuredSubregion(entry: exclusiveEntry, join: common, stop: common),
                                  !containsIrreducible(body),
                                  emittedBlockSet(in: body) == exclusive
                            else { return rejected("nested-private-prefix-partition", at: block) }
                            items.removeLast()
                            items.append(.ifThen(cond: condition, body: body, join: common,
                                                 inverted: exclusiveEntry == fallThrough))
                            visited.formUnion(exclusive)
                            current = common
                            continue
                        }
                        guard
                              takenBlocks.isDisjoint(with: fallBlocks),
                              takenBlocks.union(fallBlocks) == ownedBlocks.subtracting(visited),
                              leafHasOnlyOwnedExternalPredecessors(
                                leafEntry: takenTarget, leafBlocks: takenBlocks, allowedPredecessors: [block]),
                              leafHasOnlyOwnedExternalPredecessors(
                                leafEntry: fallThrough, leafBlocks: fallBlocks, allowedPredecessors: [block]),
                              let condition = conditionForStructure(for: block, allowNonAdjacentCompare: true)
                        else { return rejected("nested-private-arm-partition", at: block) }
                        var nestedTargets: Set<Int> = []
                        guard let takenRegion = partialRejoiningArmRegion(
                                entry: takenTarget, ownedBlocks: takenBlocks, leafBlocks: leafBlocks,
                                continuation: continuation, continuationGotoTargets: &nestedTargets,
                                nestingDepth: nestingDepth + 1),
                              let fallRegion = partialRejoiningArmRegion(
                                entry: fallThrough, ownedBlocks: fallBlocks, leafBlocks: leafBlocks,
                                continuation: continuation, continuationGotoTargets: &nestedTargets,
                                nestingDepth: nestingDepth + 1)
                        else { return rejected("nested-private-arm-unstructured", at: block) }
                        items.removeLast()
                        items.append(.ifThenElse(cond: condition, then: fallRegion,
                            els: takenRegion, join: continuation))
                        continuationGotoTargets.formUnion(nestedTargets)
                        visited.formUnion(takenBlocks)
                        visited.formUnion(fallBlocks)
                        current = nil
                        continue
                    }
                    guard !ownedBlocks.contains(takenTarget),
                          fallThrough != continuation else {
                        return rejected("conditional-owned-target-or-fallthrough-continuation", at: block)
                    }
                    if ownedBlocks.contains(fallThrough) {
                        current = fallThrough
                    } else if leafBlocks.contains(fallThrough) {
                        current = nil
                    } else {
                        return rejected("conditional-fallthrough-not-owned-or-leaf", at: block)
                    }

                case .unconditionalBranch, .none:
                    guard let successor = successors.first else { return rejected("missing-successor", at: block) }
                    if ownedBlocks.contains(successor) {
                        current = successor
                    } else if leafBlocks.contains(successor) {
                        current = nil
                    } else if allowRejoiningContinuationGotos || hasSyntheticPhiEdges, successor == continuation,
                              successors == [continuation],
                              case .unconditionalBranch = terminator {
                        // Preserve the skip even when presentation pruning
                        // removes every copy in this arm. A block would suppress this
                        // transfer and incorrectly fall through into the leaf.
                        items.removeLast()
                        items.append(.gotoLeaf(blocks: [block]))
                        continuationGotoTargets.insert(continuation)
                        current = nil
                    } else {
                        // An unconditional skip to the continuation would be
                        // suppressed by the structured block emitter, causing
                        // fallthrough into the leaf. Leave it to legacy.
                        return rejected("unconditional-skip-to-continuation", at: block)
                    }

                case .returnTerminator, .indirectBranch, .switchDispatch:
                    return rejected("unsupported-terminator", at: block)
                }
            }

            guard visited == ownedBlocks else { return rejected("unvisited-owned-blocks", at: entry) }
            if items.count == 1 { return items[0] }
            return .sequence(items)
        }

        private func containsIrreducible(_ region: Region) -> Bool {
            switch region {
            case .irreducible, .certifiedEdge, .certifiedSelection:
                return true
            case let .sequence(items):
                return items.contains(where: containsIrreducible)
            case let .ifThen(_, body, _, _):
                return containsIrreducible(body)
            case let .ifThenElse(_, thenBody, elseBody, _):
                return containsIrreducible(thenBody) || containsIrreducible(elseBody)
            case let .whileLoop(_, body, _),
                 let .doWhileLoop(body, _),
                 let .naturalLoop(body, _):
                return containsIrreducible(body)
            case .switchDispatch, .block, .gotoLeaf:
                return false
            }
        }

        private func emittedBlockSet(in region: Region) -> Set<Int> {
            switch region {
            case let .sequence(items):
                return items.reduce(into: Set<Int>()) { result, item in
                    result.formUnion(emittedBlockSet(in: item))
                }
            case let .ifThen(cond, body, _, _):
                var blocks = blockContaining(instructionIndex: cond.branchIndex)
                blocks.formUnion(emittedBlockSet(in: body))
                return blocks
            case let .ifThenElse(cond, thenBody, elseBody, _):
                var blocks = blockContaining(instructionIndex: cond.branchIndex)
                blocks.formUnion(emittedBlockSet(in: thenBody))
                blocks.formUnion(emittedBlockSet(in: elseBody))
                return blocks
            case let .whileLoop(_, body, header),
                 let .naturalLoop(body, header):
                var blocks: Set<Int> = [header]
                blocks.formUnion(emittedBlockSet(in: body))
                return blocks
            case let .doWhileLoop(body, cond):
                var blocks = blockContaining(instructionIndex: cond.branchIndex)
                blocks.formUnion(emittedBlockSet(in: body))
                if let stub = certifiedAbsorbedStubs[cond.branchIndex] {
                    blocks.insert(stub)
                }
                return blocks
            case let .switchDispatch(index, _, _),
                 let .block(index):
                return [index]
            case let .gotoLeaf(blocks):
                return Set(blocks)
            case let .irreducible(blocks):
                return Set(blocks)
            case .certifiedEdge, .certifiedSelection:
                return []
            }
        }

        private func blockContaining(instructionIndex: Int) -> Set<Int> {
            guard let block = cfg.blocks.first(where: { $0.instructionRange.contains(instructionIndex) }) else {
                return []
            }
            return [block.index]
        }

        private func isContiguousBlockSet(_ blockSet: Set<Int>) -> Bool {
            guard !blockSet.isEmpty,
                  blockSet.allSatisfy({ $0 >= 0 && $0 < cfg.blocks.count }) else {
                return false
            }
            let sortedBlocks = blockSet
                .map { cfg.blocks[$0] }
                .sorted { lhs, rhs in
                    if lhs.startIndex == rhs.startIndex { return lhs.endIndex < rhs.endIndex }
                    return lhs.startIndex < rhs.startIndex
                }
            guard let first = sortedBlocks.first else { return false }
            var cursor = first.startIndex
            let lowerBound = cursor
            for block in sortedBlocks {
                guard block.startIndex == cursor, block.endIndex > block.startIndex else { return false }
                cursor = block.endIndex
            }
            let range = lowerBound..<cursor
            let coveredBlocks = Set(
                cfg.blocks
                    .filter { $0.instructionRange.overlaps(range) }
                    .map(\.index)
            )
            return coveredBlocks == blockSet
        }

        private func allPathsReachFunctionExitWithinLeaf(entry: Int, leafBlocks: Set<Int>) -> Bool {
            var memo: [Int: Bool] = [:]
            var visiting: Set<Int> = []
            return allPathsReachFunctionExitWithinLeaf(
                from: entry,
                leafBlocks: leafBlocks,
                visiting: &visiting,
                memo: &memo
            )
        }

        private func allPathsReachFunctionExitWithinLeaf(
            from block: Int,
            leafBlocks: Set<Int>,
            visiting: inout Set<Int>,
            memo: inout [Int: Bool]
        ) -> Bool {
            guard leafBlocks.contains(block) else { return false }
            if let cached = memo[block] { return cached }
            if visiting.contains(block) { return false }
            let successors = cfg.blocks[block].successors
            guard !successors.isEmpty else {
                memo[block] = true
                return true
            }
            visiting.insert(block)
            defer { visiting.remove(block) }
            for successor in successors {
                guard leafBlocks.contains(successor),
                      allPathsReachFunctionExitWithinLeaf(
                        from: successor,
                        leafBlocks: leafBlocks,
                        visiting: &visiting,
                        memo: &memo
                      ) else {
                    memo[block] = false
                    return false
                }
            }
            memo[block] = true
            return true
        }

        /// True iff `entry` heads a clean EXIT arm relative to `continuation`: every block
        /// reachable from `entry` is dominated by `entry` (single-entry — nothing outside it
        /// enters) and NONE is `continuation`. With every leaf a function exit, this means each
        /// path from `entry` returns from the function without ever merging back to the
        /// continuation, so the arm can be wrapped in a guard with no loss of behavior.
        private func isCleanExitArm(entry: Int, continuation: Int) -> Bool {
            cleanExitArmFailure(entry: entry, continuation: continuation) == nil
        }

        private func cleanExitArmFailure(entry: Int, continuation: Int) -> EarlyExitArmFailureCause? {
            var visited: Set<Int> = []
            var stack = [entry]
            while let block = stack.popLast() {
                if visited.contains(block) { continue }
                visited.insert(block)
                if block == continuation { return .reachesContinuation }
                guard CFGBuilder.dominates(entry, block, domTree: cfg.domTree) else { return .armDominanceFailed }
                for succ in cfg.blocks[block].successors { stack.append(succ) }
            }
            return nil
        }

        // MARK: Loop classification

        private struct ClassifiedLoop {
            var region: Region
            var next: Int?
        }

        private enum LoopPrimaryKind {
            case whileLoop(bodyEntry: Int)
            case doWhileLoop
            case emptyLatch(test: Int, stub: Int)
            case syntheticPhiLatch
        }

        private enum EarlyExitOrientation {
            case fallthroughArm
            case takenArm
        }

        private enum EarlyExitArmFailureCause {
            case branchDominanceFailed
            case reachesContinuation
            case armDominanceFailed
        }

        private struct EarlyExitArmFailure {
            var cause: EarlyExitArmFailureCause
            var isInLoop: Bool
            var isAcyclic: Bool
            var hasNoreturnTail: Bool
        }

        private struct LoopPrimaryCandidate {
            var exitTarget: Int
            var condition: BranchCondition
            var kind: LoopPrimaryKind
        }

        private mutating func classifyLoop(header: Int, stop: Int?) -> ClassifiedLoop? {
            // Natural-loop body: blocks that reach the back-edge tail without
            // leaving via the header.
            guard let latch = backEdgeTail(forHeader: header) else { return nil }
            let loopBlocks = naturalLoopBody(header: header, latch: latch)

            // Exit targets of the loop (successors of loop blocks that are
            // outside the natural loop). Multi-exit loops are admissible only
            // when one header/latch-tested exit is the primary loop exit and
            // every other exit is a validated terminal gotoLeaf arm.
            let exits = loopExitTargets(loopBlocks: loopBlocks)
            guard !exits.isEmpty else {
                diagnostics.recordSite(.loopMultipleExitTargets)
                return nil
            }

            let primaryCandidates = loopPrimaryExitCandidates(
                header: header,
                latch: latch,
                loopBlocks: loopBlocks,
                exits: exits
            )
            guard let primary = primaryCandidates.min(by: { lhs, rhs in
                blockStartAddress(lhs.exitTarget) < blockStartAddress(rhs.exitTarget)
            }) else {
                diagnostics.recordSite(exits.count == 1 ? .loopShapeUnsupported : .loopMultipleExitTargets)
                return nil
            }

            let secondaryExitTargets = exits.subtracting([primary.exitTarget])
            let secondaryQualification: LoopSecondaryExitQualification
            if secondaryExitTargets.isEmpty {
                secondaryQualification = LoopSecondaryExitQualification(
                    leavesByEntry: [:],
                    ownersByEntry: [:],
                    continuationGotoTargets: [],
                    continuationGotoOwnersByEntry: [:]
                )
            } else {
                guard let qualified = qualifyLoopSecondaryTerminalExits(
                    secondaryExitTargets,
                    primaryExit: primary.exitTarget,
                    allExits: exits,
                    loopBlocks: loopBlocks,
                    stop: stop
                ) else {
                    return nil
                }
                secondaryQualification = qualified
            }

            var loopCondition = primary.condition
            loopCondition.continuationGotoTargets = secondaryQualification.continuationGotoTargets

            // While-loop: header is a TOP test — a conditional branch that exits
            // the loop, with NO body statements preceding the test in the header
            // block (otherwise the loop is bottom-tested → do-while). A self-loop
            // whose single block holds body statements followed by the test is a
            // do-while, never a while with an empty body.
            switch primary.kind {
            case let .whileLoop(bodyEntry):
                // Body = the in-loop successor of the header, up to the header.
                guard loopBlocks.contains(bodyEntry) else {
                    diagnostics.recordSite(.whileBodyEntryInvalid)
                    return nil
                }
                guard let body = loopBodyRegion(
                    entry: bodyEntry,
                    header: header,
                    loopBlocks: loopBlocks,
                    exitTarget: primary.exitTarget,
                    terminalExitLeavesByEntry: secondaryQualification.leavesByEntry,
                    terminalExitOwnersByEntry: secondaryQualification.ownersByEntry,
                    continuationGotoTargets: secondaryQualification.continuationGotoTargets,
                    continuationGotoOwnersByEntry: secondaryQualification.continuationGotoOwnersByEntry
                ) else {
                    diagnostics.recordSite(.whileBodyUnstructured)
                    return nil
                }
                return ClassifiedLoop(
                    region: .whileLoop(cond: loopCondition, body: body, header: header),
                    next: primary.exitTarget
                )

            // Do-while: the latch block is a conditional branch back to header,
            // header is not the test.
            case .doWhileLoop:
                // The do-while body STARTS at this loop's own header — exempt exactly that
                // block from loop re-dispatch or the walk self-recurses into the recursion
                // guard (the pre-2026-07-09 multi-block-do-while wall).
                guard let body = loopBodyRegion(
                    entry: header,
                    header: latch,
                    loopBlocks: loopBlocks,
                    exitTarget: primary.exitTarget,
                    terminalExitLeavesByEntry: secondaryQualification.leavesByEntry,
                    terminalExitOwnersByEntry: secondaryQualification.ownersByEntry,
                    continuationGotoTargets: secondaryQualification.continuationGotoTargets,
                    continuationGotoOwnersByEntry: secondaryQualification.continuationGotoOwnersByEntry,
                    skipLoopHeaderAt: header
                ) else {
                    diagnostics.recordSite(.doWhileBodyUnstructured)
                    return nil
                }
                return ClassifiedLoop(
                    region: .doWhileLoop(body: body, cond: loopCondition),
                    next: primary.exitTarget
                )

            case .syntheticPhiLatch:
                guard let body = loopBodyRegion(
                    entry: header, header: latch, loopBlocks: loopBlocks,
                    exitTarget: primary.exitTarget, terminalExitLeavesByEntry: [:],
                    terminalExitOwnersByEntry: [:], continuationGotoTargets: [],
                    continuationGotoOwnersByEntry: [:], skipLoopHeaderAt: header
                ), !containsIrreducible(body),
                   emittedBlockSet(in: body) == loopBlocks.subtracting([latch]) else { return nil }
                return ClassifiedLoop(
                    region: .naturalLoop(body: .sequence([body, .block(blockIndex: latch)]), header: header),
                    next: primary.exitTarget)

            case let .emptyLatch(test, stub):
                guard let body = loopBodyRegion(
                    entry: header,
                    header: test,
                    loopBlocks: loopBlocks,
                    exitTarget: primary.exitTarget,
                    terminalExitLeavesByEntry: [:],
                    terminalExitOwnersByEntry: [:],
                    continuationGotoTargets: [],
                    continuationGotoOwnersByEntry: [:],
                    skipLoopHeaderAt: header
                ), !containsIrreducible(body),
                   emittedBlockSet(in: body) == loopBlocks.subtracting([test, stub]) else {
                    return nil
                }
                certifiedAbsorbedStubs[loopCondition.branchIndex] = stub
                return ClassifiedLoop(
                    region: .doWhileLoop(body: body, cond: loopCondition),
                    next: primary.exitTarget
                )
            }
        }

        private struct LoopSecondaryExitQualification {
            var leavesByEntry: [Int: [Int]]
            var ownersByEntry: [Int: Int]
            var continuationGotoTargets: Set<Int>
            var continuationGotoOwnersByEntry: [Int: Int]
        }

        private mutating func loopPrimaryExitCandidates(
            header: Int,
            latch: Int,
            loopBlocks: Set<Int>,
            exits: Set<Int>
        ) -> [LoopPrimaryCandidate] {
            var candidates: [LoopPrimaryCandidate] = []

            let headerTerminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: header)].operation)
            if case .conditionalBranch = headerTerminator,
               headerTestIsAtTop(header: header),
               let condition = conditionForStructure(for: header) {
                for exitTarget in cfg.blocks[header].successors where exits.contains(exitTarget) {
                    if let bodyEntry = cfg.blocks[header].successors.first(where: { $0 != exitTarget }),
                       loopBlocks.contains(bodyEntry) {
                        candidates.append(
                            LoopPrimaryCandidate(
                                exitTarget: exitTarget,
                                condition: condition,
                                kind: .whileLoop(bodyEntry: bodyEntry)
                            )
                        )
                    }
                }
            }

            let latchTerminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: latch)].operation)
            if case .conditionalBranch = latchTerminator,
               cfg.blocks[latch].successors.contains(header),
               let condition = conditionForStructure(for: latch) {
                for exitTarget in cfg.blocks[latch].successors where exits.contains(exitTarget) {
                    candidates.append(
                        LoopPrimaryCandidate(
                            exitTarget: exitTarget,
                            condition: condition,
                            kind: .doWhileLoop
                        )
                    )
                }
            }

            if certifiedConditions == nil,
               let loop = RegionTree.syntheticPhiLatchLoop(header: header, cfg: cfg, instructions: instructions),
               loop.latch == latch, loop.blocks == loopBlocks, exits == [loop.exit] {
                candidates.append(LoopPrimaryCandidate(exitTarget: loop.exit,
                    condition: loop.condition, kind: .syntheticPhiLatch))
            }

            if let candidate = certifiedEmptyLatchCandidate(
                header: header, stub: latch, loopBlocks: loopBlocks, exits: exits
            ) {
                candidates.append(candidate)
            }

            return candidates
        }

        /// A single effect-free B may carry the backedge after a conditional
        /// bottom test. This is not general natural-loop or internal-break
        /// recovery: the test owns the only exiting edge, and no other block
        /// may enter the stub or any nonheader member from outside the loop.
        private mutating func certifiedEmptyLatchCandidate(
            header: Int, stub: Int, loopBlocks: Set<Int>, exits: Set<Int>
        ) -> LoopPrimaryCandidate? {
            guard certifiedConditions != nil, exits.count == 1,
                  let exit = exits.first, stub != header else { return nil }
            let stubBlock = cfg.blocks[stub]
            guard stubBlock.endIndex == stubBlock.startIndex + 1,
                  stubBlock.successors == [header], stubBlock.predecessors.count == 1,
                  let test = stubBlock.predecessors.first,
                  test != header, test != stub, loopBlocks.contains(test),
                  instructions[stubBlock.startIndex].source.mnemonic.lowercased() == "b",
                  case let .intrinsic(destination, name, arguments) = instructions[stubBlock.startIndex].operation,
                  destination == nil, name == "branch", arguments.count == 1,
                  case let .unconditionalBranch(target) = CFGBuilder.terminatorKind(of: instructions[stubBlock.startIndex].operation),
                  target == blockStartAddress(header),
                  cfg.blocks[test].successors.count == 2,
                  Set(cfg.blocks[test].successors) == [stub, exit],
                  var condition = conditionForStructure(for: test),
                  loopBlocks.allSatisfy({ block in
                      CFGBuilder.dominates(header, block, domTree: cfg.domTree)
                          && (block == header || cfg.blocks[block].predecessors.allSatisfy(loopBlocks.contains))
                  }) else { return nil }
            let exitEdges = loopBlocks.flatMap { block in
                cfg.blocks[block].successors.filter { !loopBlocks.contains($0) }
                    .map { CFGEdge(block, $0) }
            }
            guard exitEdges == [CFGEdge(test, exit)] else { return nil }
            // A footer means continue. If the decoded taken edge exits, use
            // its inverse so that only the edge into the stub repeats the body.
            if cfg.blocks[test].successors[0] != stub {
                switch condition.condition {
                case "==": condition.condition = "!="
                case "!=": condition.condition = "=="
                case "<": condition.condition = ">="
                case "<=": condition.condition = ">"
                case ">": condition.condition = "<="
                case ">=": condition.condition = "<"
                default: return nil
                }
            }
            return LoopPrimaryCandidate(exitTarget: exit, condition: condition,
                                        kind: .emptyLatch(test: test, stub: stub))
        }

        private mutating func qualifyLoopSecondaryTerminalExits(
            _ secondaryExitTargets: Set<Int>,
            primaryExit: Int,
            allExits: Set<Int>,
            loopBlocks: Set<Int>,
            stop: Int?
        ) -> LoopSecondaryExitQualification? {
            var leavesByEntry: [Int: [Int]] = [:]
            var ownersByEntry: [Int: Int] = [:]
            var continuationGotoTargets: Set<Int> = []
            var continuationGotoOwnersByEntry: [Int: Int] = [:]
            let continuationBlocks = Set(reachableBlocks(from: primaryExit, stop: stop))

            for exitEntry in secondaryExitTargets {
                if let terminal = qualifyLoopSecondaryTerminalExit(
                    exitEntry: exitEntry,
                    primaryExit: primaryExit,
                    allExits: allExits,
                    loopBlocks: loopBlocks
                ) {
                    leavesByEntry[exitEntry] = terminal.blocks
                    ownersByEntry[exitEntry] = terminal.owner
                    continue
                }

                guard !loopBlocks.contains(exitEntry),
                      continuationBlocks.contains(exitEntry),
                      let owner = singleLoopOwner(ofExitEntry: exitEntry, loopBlocks: loopBlocks),
                      isLoopContinuationGotoEdge(
                        from: owner,
                        exitEntry: exitEntry,
                        loopBlocks: loopBlocks
                      ) else {
                    diagnostics.recordSite(.loopSecondaryExitNotInContinuation)
                    return nil
                }

                continuationGotoTargets.insert(exitEntry)
                continuationGotoOwnersByEntry[exitEntry] = owner
            }

            return LoopSecondaryExitQualification(
                leavesByEntry: leavesByEntry,
                ownersByEntry: ownersByEntry,
                continuationGotoTargets: continuationGotoTargets,
                continuationGotoOwnersByEntry: continuationGotoOwnersByEntry
            )
        }

        private struct LoopTerminalExitQualification {
            var blocks: [Int]
            var owner: Int
        }

        private mutating func qualifyLoopSecondaryTerminalExit(
            exitEntry: Int,
            primaryExit: Int,
            allExits: Set<Int>,
            loopBlocks: Set<Int>
        ) -> LoopTerminalExitQualification? {
            guard !loopBlocks.contains(exitEntry),
                  let owner = singleLoopOwner(ofExitEntry: exitEntry, loopBlocks: loopBlocks),
                  isLoopTerminalExitEdge(
                    from: owner,
                    exitEntry: exitEntry,
                    loopBlocks: loopBlocks
                  ) else {
                return nil
            }

            var rejectedBlocks = loopBlocks
            rejectedBlocks.formUnion(allExits.subtracting([exitEntry]))
            rejectedBlocks.insert(primaryExit)

            guard let leafBlocks = terminalGotoLeafBlocks(
                entry: exitEntry,
                rejecting: rejectedBlocks,
                branch: nil,
                stop: nil
            ) else {
                return nil
            }
            let leafSet = Set(leafBlocks)
            guard leafSet.isDisjoint(with: loopBlocks),
                  !leafContainsBackEdge(leafSet),
                  terminalLeafHasSingleExternalEntry(
                    entry: exitEntry,
                    owner: owner,
                    leafBlocks: leafSet
                  ) else {
                return nil
            }

            return LoopTerminalExitQualification(blocks: leafBlocks, owner: owner)
        }

        private func singleLoopOwner(ofExitEntry exitEntry: Int, loopBlocks: Set<Int>) -> Int? {
            let owners = loopBlocks.filter { cfg.blocks[$0].successors.contains(exitEntry) }
            guard owners.count == 1 else { return nil }
            return owners.first
        }

        private func isLoopTerminalExitEdge(from block: Int, exitEntry: Int, loopBlocks: Set<Int>) -> Bool {
            let successors = cfg.blocks[block].successors
            let terminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: block)].operation)
            guard case .conditionalBranch = terminator,
                  successors.count == 2,
                  successors.contains(exitEntry) else {
                return false
            }
            let continuation = successors[0] == exitEntry ? successors[1] : successors[0]
            return loopBlocks.contains(continuation)
        }

        private func isLoopContinuationGotoEdge(from block: Int, exitEntry: Int, loopBlocks: Set<Int>) -> Bool {
            let successors = cfg.blocks[block].successors
            let terminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: block)].operation)
            guard case .conditionalBranch = terminator,
                  successors.count == 2,
                  successors.contains(exitEntry) else {
                return false
            }
            let continuation = successors[0] == exitEntry ? successors[1] : successors[0]
            return loopBlocks.contains(continuation)
        }

        private func terminalLeafHasSingleExternalEntry(entry: Int, owner: Int, leafBlocks: Set<Int>) -> Bool {
            var externalEntries: [(pred: Int, block: Int)] = []
            for block in leafBlocks {
                for pred in cfg.blocks[block].predecessors where !leafBlocks.contains(pred) {
                    externalEntries.append((pred: pred, block: block))
                }
            }
            return externalEntries.count == 1
                && externalEntries[0].pred == owner
                && externalEntries[0].block == entry
        }

        private func leafContainsBackEdge(_ leafBlocks: Set<Int>) -> Bool {
            cfg.backEdges.contains { edge in
                leafBlocks.contains(edge.from) || leafBlocks.contains(edge.to)
            }
        }

        private func blockStartAddress(_ blockIndex: Int) -> UInt64 {
            guard blockIndex >= 0,
                  blockIndex < cfg.blocks.count else {
                return UInt64.max
            }
            let instructionIndex = cfg.blocks[blockIndex].startIndex
            guard instructionIndex >= 0,
                  instructionIndex < instructions.count else {
                return UInt64.max
            }
            return instructions[instructionIndex].source.address
        }

        /// True iff the header block's conditional test sits at the TOP — the
        /// block contains only the test (a `compare` + branch, or a bare
        /// zero-check branch) with no preceding body statements. A header that
        /// carries body statements before its test is a bottom test (do-while).
        private mutating func headerTestIsAtTop(header: Int) -> Bool {
            let block = cfg.blocks[header]
            if certifiedConditions != nil {
                return certifiedTestPrefixStarts[lastInstruction(of: header)] == block.startIndex
            }
            guard let cond = branchCondition(for: header) else { return false }
            let firstTestIndex = cond.compareIndex ?? cond.branchIndex
            // The test must be the FIRST instruction of the header block (no
            // preceding body statements → top-tested while). `==` is intended:
            // `<=` would silently treat a header whose test index somehow
            // precedes its own start as top-tested if the gating is ever
            // relaxed. The test can never be before the block's start, so `==`
            // is the precise invariant.
            return firstTestIndex == block.startIndex
        }

        private mutating func loopBodyRegion(
            entry: Int,
            header: Int,
            loopBlocks: Set<Int>,
            exitTarget: Int,
            terminalExitLeavesByEntry: [Int: [Int]],
            terminalExitOwnersByEntry: [Int: Int],
            continuationGotoTargets: Set<Int>,
            continuationGotoOwnersByEntry: [Int: Int],
            skipLoopHeaderAt: Int? = nil
        ) -> Region? {
            // The body excludes the latch/header test block; walk the linear
            // body chain stopping at `header`.
            guard entry != header else { return .sequence([]) }
            // `buildRegion` is bounded only by `stop` (= header), not by
            // `loopBlocks`. Enforce the loop-membership invariant BEFORE
            // recursing: every block the body walk can reach from `entry`
            // without passing through `header` must belong to the natural loop.
            // If the walk can escape the loop, the recovered loop shape is not
            // trustworthy — bail to legacy rather than emit an over-included
            // loop body. (This also makes the previously-unused `loopBlocks`
            // parameter load-bearing.)
            guard bodyReachStaysInLoop(
                entry: entry,
                header: header,
                loopBlocks: loopBlocks,
                exitTarget: exitTarget,
                terminalExitOwnersByEntry: terminalExitOwnersByEntry,
                continuationGotoOwnersByEntry: continuationGotoOwnersByEntry
            ) else {
                diagnostics.recordSite(.loopBodyEscapes)
                return nil
            }
            return buildRegion(
                entry: entry,
                stop: header,
                loopContext: LoopContext(
                    exitTarget: exitTarget,
                    loopBlocks: loopBlocks,
                    terminalExitLeavesByEntry: terminalExitLeavesByEntry,
                    terminalExitOwnersByEntry: terminalExitOwnersByEntry,
                    continuationGotoTargets: continuationGotoTargets,
                    continuationGotoOwnersByEntry: continuationGotoOwnersByEntry
                ),
                skipLoopHeaderAt: skipLoopHeaderAt
            )
        }

        /// True iff every block reachable from `entry` over forward edges
        /// without passing through `header` is a member of `loopBlocks`.
        private func bodyReachStaysInLoop(
            entry: Int,
            header: Int,
            loopBlocks: Set<Int>,
            exitTarget: Int,
            terminalExitOwnersByEntry: [Int: Int],
            continuationGotoOwnersByEntry: [Int: Int]
        ) -> Bool {
            var visited: Set<Int> = []
            var stack = [entry]
            while let block = stack.popLast() {
                if block == header { continue }
                if visited.contains(block) { continue }
                visited.insert(block)
                guard loopBlocks.contains(block) else { return false }
                for succ in cfg.blocks[block].successors {
                    if succ == exitTarget {
                        guard isLoopBreakExitEdge(from: block, exitTarget: exitTarget, loopBlocks: loopBlocks) else {
                            return false
                        }
                        continue
                    }
                    if let owner = terminalExitOwnersByEntry[succ] {
                        guard owner == block,
                              isLoopTerminalExitEdge(
                                from: block,
                                exitEntry: succ,
                                loopBlocks: loopBlocks
                              ) else {
                            return false
                        }
                        continue
                    }
                    if let owner = continuationGotoOwnersByEntry[succ] {
                        guard owner == block,
                              isLoopContinuationGotoEdge(
                                from: block,
                                exitEntry: succ,
                                loopBlocks: loopBlocks
                              ) else {
                            return false
                        }
                        continue
                    }
                    stack.append(succ)
                }
            }
            return true
        }

        private func isLoopBreakExitEdge(from block: Int, exitTarget: Int, loopBlocks: Set<Int>) -> Bool {
            let successors = cfg.blocks[block].successors
            let terminator = CFGBuilder.terminatorKind(of: instructions[lastInstruction(of: block)].operation)
            switch terminator {
            case .unconditionalBranch:
                return successors.first == exitTarget
            case .conditionalBranch:
                guard successors.count == 2, successors.contains(exitTarget) else { return false }
                let continuation = successors[0] == exitTarget ? successors[1] : successors[0]
                return loopBlocks.contains(continuation)
            default:
                return false
            }
        }

        private mutating func backEdgeTail(forHeader header: Int) -> Int? {
            let tails = cfg.backEdges.filter { $0.to == header }.map { $0.from }
            // Exactly one back-edge for the supported (reducible) idioms; more
            // than one means an unsupported multi-latch loop → bail.
            guard tails.count == 1 else {
                diagnostics.recordSite(tails.count > 1 ? .multiLatch : .loopMissingBackEdge)
                return nil
            }
            return tails.first
        }

        private func naturalLoopBody(header: Int, latch: Int) -> Set<Int> {
            var body: Set<Int> = [header]
            var stack = [latch]
            while let block = stack.popLast() {
                if body.contains(block) { continue }
                body.insert(block)
                for pred in cfg.blocks[block].predecessors where pred != header {
                    stack.append(pred)
                }
            }
            return body
        }

        private func loopExitTargets(loopBlocks: Set<Int>) -> Set<Int> {
            var exits: Set<Int> = []
            for block in loopBlocks {
                for succ in cfg.blocks[block].successors where !loopBlocks.contains(succ) {
                    exits.insert(succ)
                }
            }
            return exits
        }

        // MARK: Condition recovery

        private mutating func conditionForStructure(
            for block: Int, allowNonAdjacentCompare: Bool = false
        ) -> BranchCondition? {
            if let certifiedConditions {
                return certifiedConditions[lastInstruction(of: block)]
            }
            if let condition = RegionTree.syntheticPhiLatchCondition(test: block, cfg: cfg, instructions: instructions) {
                return condition
            }
            return branchCondition(for: block, allowNonAdjacentCompare: allowNonAdjacentCompare)
        }

        private mutating func branchCondition(for block: Int, allowNonAdjacentCompare: Bool = false) -> BranchCondition? {
            let branchIndex = lastInstruction(of: block)
            guard case let .conditionalBranch(condition, left, right, _) = instructions[branchIndex].operation else {
                diagnostics.recordSite(.branchConditionNotConditional)
                return nil
            }
            let mnemonic = instructions[branchIndex].source.mnemonic.lowercased()
            let isZeroCheck = mnemonic == "cbz" || mnemonic == "cbnz" || mnemonic == "tbz" || mnemonic == "tbnz"
            if isZeroCheck {
                return BranchCondition(
                    branchIndex: branchIndex,
                    compareIndex: nil,
                    left: left,
                    condition: condition,
                    right: right,
                    isZeroCheck: true
                )
            }
            if allowNonAdjacentCompare,
               let compound = compoundBranchCondition(branchIndex: branchIndex, blockStart: cfg.blocks[block].startIndex) {
                return compound
            }
            // Compare-fed: a preceding `compare` intrinsic at branchIndex-1 whose
            // operands match and is physically adjacent.
            let compareIndex = branchIndex - 1
            if compareIndex >= cfg.blocks[block].startIndex,
               case let .intrinsic(_, name, arguments) = instructions[compareIndex].operation,
               name == "compare",
               arguments.count == 2,
               instructions[compareIndex].source.address.isContiguous(to: instructions[branchIndex].source.address),
               arguments[0] == MacIRBuilder.droppingSignedProjection(left),
               arguments[1] == MacIRBuilder.droppingSignedProjection(right) {
                return BranchCondition(
                    branchIndex: branchIndex,
                    compareIndex: compareIndex,
                    left: left,
                    condition: condition,
                    right: right,
                    isZeroCheck: false
                )
            }
            if allowNonAdjacentCompare,
               blockContainsConditionalCompare(blockStart: cfg.blocks[block].startIndex, branchIndex: branchIndex) {
                diagnostics.recordSite(.branchConditionMissingAdjacentCompare)
                return nil
            }
            // Compare-fed but the `cmp` is not physically adjacent (shared cmp /
            // three-way compare). Only widen for if/else structuring; loop
            // headers/latches keep returning nil so stale-condition loops cannot
            // be emitted. compareIndex = nil preserves every leading statement
            // and folds only the branch into the structured header.
            if allowNonAdjacentCompare {
                return BranchCondition(
                    branchIndex: branchIndex,
                    compareIndex: nil,
                    left: left,
                    condition: condition,
                    right: right,
                    isZeroCheck: false
                )
            }
            // A conditional branch with no opt-in compare context — don't structure
            // (legacy renders it as `if (...) goto`).
            diagnostics.recordSite(.branchConditionMissingAdjacentCompare)
            return nil
        }

        private func compoundBranchCondition(branchIndex: Int, blockStart: Int) -> BranchCondition? {
            guard branchIndex - 2 >= blockStart,
                  case let .conditionalBranch(condition, left, right, _) = instructions[branchIndex].operation,
                  condition == "!=",
                  right == .immediate(0),
                  isCompoundCondition(left) else {
                return nil
            }

            let conditionalCompareIndex = branchIndex - 1
            let compareIndex = branchIndex - 2
            guard isConditionalCompareInstruction(instructions[conditionalCompareIndex]),
                  instructions[compareIndex].source.address.isContiguous(to: instructions[conditionalCompareIndex].source.address),
                  instructions[conditionalCompareIndex].source.address.isContiguous(to: instructions[branchIndex].source.address),
                  case let .intrinsic(_, name, arguments) = instructions[compareIndex].operation,
                  name == "compare",
                  arguments.count == 2,
                  firstCompoundLeafMatchesCompare(left, compareLeft: arguments[0], compareRight: arguments[1]) else {
                return nil
            }

            return BranchCondition(
                branchIndex: branchIndex,
                compareIndex: compareIndex,
                left: left,
                condition: condition,
                right: right,
                isZeroCheck: false
            )
        }

        private func blockContainsConditionalCompare(blockStart: Int, branchIndex: Int) -> Bool {
            guard blockStart < branchIndex else { return false }
            return (blockStart..<branchIndex).contains { isConditionalCompareInstruction(instructions[$0]) }
        }

        private func isConditionalCompareInstruction(_ instruction: MacIRInstruction) -> Bool {
            switch instruction.source.mnemonic.lowercased() {
            case "ccmp", "ccmn", "fccmp", "fccmpe":
                return true
            default:
                return false
            }
        }

        private func isCompoundCondition(_ value: MacIRValue) -> Bool {
            guard case let .binaryExpression(op, _, _) = value else { return false }
            return op == "&&" || op == "||"
        }

        private func firstCompoundLeafMatchesCompare(
            _ value: MacIRValue,
            compareLeft: MacIRValue,
            compareRight: MacIRValue
        ) -> Bool {
            guard case let .binaryExpression(_, firstLeaf, _) = value,
                  case let .binaryExpression(op, left, right) = firstLeaf,
                  ["==", "!=", "<", "<=", ">", ">="].contains(op) else {
                return false
            }
            return strippedComparisonCast(left) == compareLeft
                && strippedComparisonCast(right) == compareRight
        }

        private func strippedComparisonCast(_ value: MacIRValue) -> MacIRValue {
            let value = MacIRBuilder.droppingSignedProjection(value)
            guard case let .unary(op, inner) = value,
                  op == "(uint32_t)" || op == "(uint64_t)" else {
                return value
            }
            return inner
        }

        private func lastInstruction(of block: Int) -> Int {
            cfg.blocks[block].endIndex - 1
        }

        private func reachableBlocks(from entry: Int, stop: Int?) -> [Int] {
            var visited: Set<Int> = []
            var ordered: [Int] = []
            var stack = [entry]
            while let block = stack.popLast() {
                if let stop, block == stop { continue }
                if visited.contains(block) { continue }
                visited.insert(block)
                ordered.append(block)
                for succ in cfg.blocks[block].successors { stack.append(succ) }
            }
            return ordered.sorted()
        }
    }
}

// MARK: - Proof-checked recovery for vetoed, reducible regions

extension RegionTree {
    /// A fallback presentation, not an extension of the legacy Region grammar.
    /// Every block occurrence executes that original block's instructions. Only
    /// the successor syntax changes. A duplicate is edge-local, never hoisted.
    indirect enum RecoveryRegion: Sendable {
        case sequence([RecoveryRegion])
        case block(Int, exits: [RecoveryRegion]) // ordered: branch-taken, fallthrough
        case scope(target: Int, body: RecoveryRegion) // labelled one-shot block
        case loop(header: Int, body: RecoveryRegion)
        case breakTo(Int)
        case continueAt(Int)
    }

    struct RecoveryPlan: Sendable {
        var root: RecoveryRegion
        var duplicatedBlocks: Set<Int>
        var extraInstructionCount: Int
        var originalVeto: Veto
    }

    /// Kept deliberately narrower than a general-purpose graph-to-code pass.
    /// Unsupported predicates, unresolved edges, unreachable/irreducible blocks,
    /// non-laminar loops and exhausted budgets keep their existing fallback.
    static func recoveryPlan(
        cfg: CFG, instructions: [MacIRInstruction], options: DecompilerOptions,
        veto: Veto
    ) -> RecoveryPlan? {
        guard options.structureControlFlow else { return nil }
        let needsTail: Bool
        switch veto {
        case .gotoLeafRejoiningDoubleReachable, .gotoLeafRejoiningAmbiguousEntry,
             .gotoLeafRejoiningNonContiguous, .gotoLeafRejoiningArmUnstructured:
            guard options.recoverSharedTails else { return nil }
            needsTail = true
        case .loopMultipleExitTargets, .loopSecondaryExitNotInContinuation,
             .loopShapeUnsupported:
            guard options.recoverLoopExits else { return nil }
            needsTail = false
        case .conditionalDoubleGuardToJoin:
            needsTail = false
        case .earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail,
             .earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicPlainTail:
            guard options.recoverGuardRegions else { return nil }
            needsTail = false
        default:
            return nil
        }
        var builder = RecoveryBuilder(cfg: cfg, instructions: instructions,
                                      options: options, needsTail: needsTail)
        guard let (raw, duplicates, extra) = try? builder.build(),
              let root = simplifiedRecovery(raw, to: cfg) else { return nil }
        return RecoveryPlan(root: root, duplicatedBlocks: duplicates,
                            extraInstructionCount: extra, originalVeto: veto)
    }

    /// Compose the original SSA graph before edge-copy blocks are materialized.
    /// Payloads and copy schedules stay with their original blocks and edges;
    /// this proof only changes the syntax used for those ordered successors.
    static func ssaRecoveryPlan(function: MacIRFunction, cfg: CFG) -> RecoveryRegion? {
        func refused(_ reason: String, block: Int? = nil) -> RecoveryRegion? {
            if diagnosticsEnabled {
                let address = block.flatMap { index -> String? in
                    guard cfg.blocks.indices.contains(index),
                          function.instructions.indices.contains(cfg.blocks[index].startIndex) else { return nil }
                    return String(function.instructions[cfg.blocks[index].startIndex].source.address, radix: 16)
                } ?? "none"
                let message = "SSA_RECOVERY_PLAN\tfunction=\(function.name)\treason=\(reason)\tblock=\(address)\n"
                if let data = message.data(using: .utf8) { FileHandle.standardError.write(data) }
            }
            return nil
        }
        guard function.ssaEnabled, !cfg.blocks.isEmpty, cfg.blocks.count <= 512,
              !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              cfg.entryIndex == 0 else { return refused("graph-admission") }
        let instructions = function.instructions
        var cursor = 0
        var blockByAddress: [UInt64: Int] = [:]
        var starts: [Int: Int] = [:]
        for (index, block) in cfg.blocks.enumerated() {
            guard block.index == index, block.startIndex == cursor,
                  block.endIndex > cursor, block.endIndex <= instructions.count,
                  blockByAddress.updateValue(index, forKey: instructions[cursor].source.address) == nil
            else { return refused("block-partition", block: index) }
            starts[cursor] = index
            cursor = block.endIndex
            // A supplied partition must not hide control inside a payload.
            guard block.instructionRange.dropLast().allSatisfy({
                CFGBuilder.terminatorKind(of: instructions[$0].operation) == .none
            }) else { return refused("interior-control", block: index) }
        }
        guard cursor == instructions.count, starts == cfg.blockByStartIndex else { return refused("block-coverage") }
        func target(_ value: MacIRValue) -> Int? {
            CFGBuilder.address(of: value).flatMap { blockByAddress[$0] }
        }
        var switches: [Int: MacIROperation] = [:]
        var predecessors = Array(repeating: [Int](), count: cfg.blocks.count)
        for block in cfg.blocks {
            let last = block.endIndex - 1
            let operation = instructions[last].operation
            let successors: [Int]
            switch operation {
            case let .conditionalBranch(_, _, _, destination):
                guard let taken = target(destination), block.index + 1 < cfg.blocks.count,
                      taken != block.index + 1 else { return refused("conditional-target", block: block.index) }
                successors = [taken, block.index + 1]
            case let .switchDispatch(_, cases, defaultTarget):
                guard !cases.isEmpty, cases.count <= 512,
                      Set(cases.map(\.value)).count == cases.count,
                      let defaultTarget else { return refused("switch-shape", block: block.index) }
                var ordered: [Int] = []
                guard target(defaultTarget) != nil else { return refused("switch-default", block: block.index) }
                // The default belongs to the preceding bounds guard. Keep its
                // metadata, but only table cases are outgoing machine edges.
                for destination in cases.map(\.target) {
                    guard let successor = target(destination) else { return refused("switch-target", block: block.index) }
                    if !ordered.contains(successor) { ordered.append(successor) }
                }
                successors = ordered
                switches[last] = operation
            default:
                switch CFGBuilder.terminatorKind(of: operation) {
                case let .unconditionalBranch(address):
                    guard let address, let successor = blockByAddress[address] else { return refused("direct-target", block: block.index) }
                    successors = [successor]
                case .none:
                    guard block.index + 1 < cfg.blocks.count else { return refused("implicit-exit", block: block.index) }
                    successors = [block.index + 1]
                case .returnTerminator:
                    successors = []
                case .conditionalBranch, .switchDispatch, .indirectBranch:
                    // An unfolded or unresolved control operation cannot borrow
                    // a condition from a certificate or a neighboring writer.
                    return refused("untyped-control", block: block.index)
                }
            }
            guard successors == block.successors else {
                return refused("successor-order:expected=\(successors):actual=\(block.successors)", block: block.index)
            }
            for successor in successors { predecessors[successor].append(block.index) }
        }
        guard cfg.blocks.allSatisfy({ $0.predecessors == predecessors[$0.index] }) else { return refused("predecessors") }
        var builder = RecoveryBuilder(cfg: cfg, instructions: instructions,
            options: .default, needsTail: false, originalSwitches: switches,
            preservesFallthroughChains: true)
        guard let (raw, duplicates, extra) = try? builder.build() else { return refused("topology-builder") }
        guard duplicates.isEmpty, extra == 0 else { return refused("duplicate-payload") }
        guard let result = simplifiedSSARecovery(raw, to: cfg) else { return refused("graph-equivalence") }
        var occurrences: Set<Int> = []
        var budget = 8192
        var ownershipFailure = "block-coverage"
        func unique(_ region: RecoveryRegion, depth: Int) -> Bool {
            budget -= 1
            guard budget >= 0, depth <= 128 else {
                ownershipFailure = "ownership-budget:depth=\(depth):nodes=\(8192 - budget)"
                return false
            }
            switch region {
            case let .sequence(parts):
                return parts.allSatisfy { unique($0, depth: depth + 1) }
            case let .block(block, exits):
                guard occurrences.insert(block).inserted else {
                    ownershipFailure = "duplicate-block:\(block)"
                    return false
                }
                return exits.allSatisfy { unique($0, depth: depth + 1) }
            case let .scope(_, body), let .loop(_, body):
                return unique(body, depth: depth + 1)
            case .breakTo, .continueAt:
                return true
            }
        }
        guard unique(result, depth: 0), occurrences == Set(cfg.blocks.indices) else { return refused(ownershipFailure) }
        return result
    }

    /// Reuse only the topology builder for a separately proved decoded-state
    /// function. Old payloads and predicates are never admitted through this API.
    /// Unlike optional shared-tail recovery, every static block occurs once.
    static func certifiedRegionalRecoveryPlan(
        function: MacIRFunction, cfg: CFG, certifiedBy state: RegionalPhysicalStatePlan
    ) -> RecoveryRegion? {
        guard state.matches(function: function, cfg: cfg),
              state.groups.count == function.instructions.count else { return nil }
        var branches = Set<Int>(), switches = Set<Int>()
        for block in cfg.blocks {
            let last = block.endIndex - 1
            guard !block.instructionRange.isEmpty,
                  function.instructions.indices.contains(last) else { return nil }
            switch CFGBuilder.terminatorKind(of: function.instructions[last].operation) {
            case .conditionalBranch: branches.insert(last)
            case .switchDispatch: switches.insert(last)
            default: break
            }
        }
        guard Set(state.branchConditions.keys) == branches,
              Set(state.switches.keys) == switches else { return nil }
        // Unfolded condition intrinsics need the same exact-function physical
        // certificate. Ordinary optional recovery receives no such authority.
        var certifiedConditions: [Int: MacIROperation] = [:]
        for row in branches {
            if case .conditionalBranch = function.instructions[row].operation { continue }
            certifiedConditions[row] = function.instructions[row].operation
        }
        guard Set(certifiedConditions.keys) == Set(state.singleCMPBranches.keys) else { return nil }
        var builder = RecoveryBuilder(cfg: cfg, instructions: function.instructions,
                                      options: .default, needsTail: false,
                                      certifiedSwitches: state.switches,
                                      certifiedConditions: certifiedConditions)
        guard let (raw, duplicates, extra) = try? builder.build(),
              duplicates.isEmpty, extra == 0 else { return nil }
        // Switch aliases may reuse only transfer syntax. The binary simplifier
        // can move payload suffixes into arms, so retain raw topology here.
        let result: RecoveryRegion
        if switches.isEmpty {
            guard let simplified = simplifiedRecovery(raw, to: cfg) else { return nil }
            result = simplified
        } else {
            result = raw
        }
        guard recoveryIsEquivalent(result, to: cfg) else { return nil }
        var occurrences: [Int: Int] = [:]
        var budget = 8192
        func visit(_ node: RecoveryRegion, depth: Int) -> Bool {
            budget -= 1
            guard budget >= 0, depth <= 128 else { return false }
            switch node {
            case let .sequence(parts): return parts.allSatisfy { visit($0, depth: depth + 1) }
            case let .block(block, exits):
                guard cfg.blocks.indices.contains(block) else { return false }
                occurrences[block, default: 0] += 1
                return occurrences[block] == 1 && exits.allSatisfy { visit($0, depth: depth + 1) }
            case let .scope(_, body), let .loop(_, body): return visit(body, depth: depth + 1)
            case .breakTo, .continueAt: return true
            }
        }
        guard visit(result, depth: 0), Set(occurrences.keys) == Set(cfg.blocks.indices),
              occurrences.values.allSatisfy({ $0 == 1 }) else { return nil }
        return result
    }

    static func simplifiedSSARecovery(_ root: RecoveryRegion, to cfg: CFG) -> RecoveryRegion? {
        // Raw recovery wraps forward intervals in scopes. First expose their
        // existing branch arms; moving prefixes before that normalization can
        // hide the shared continuation from lexical-transfer simplification.
        guard let normalized = simplifiedRecovery(root, to: cfg),
              let folded = ssaPrivateArmRecovery(normalized, to: cfg) else { return nil }
        return simplifiedRecovery(folded, to: cfg)
    }

    /// Move a sibling prefix into the only arm that can enter it. The original
    /// blocks and their ordered exits move together, including edge-copy owners.
    /// This is used only by SSA recovery; legacy and certified plans are unchanged.
    static func ssaPrivateArmRecovery(_ root: RecoveryRegion, to cfg: CFG) -> RecoveryRegion? {
        guard recoveryIsEquivalent(root, to: cfg) else { return nil }
        var occurrences: Set<Int> = []
        var ownershipBudget = 8192
        func unique(_ node: RecoveryRegion, depth: Int) -> Bool {
            ownershipBudget -= 1
            guard ownershipBudget >= 0, depth <= 256 else { return false }
            switch node {
            case let .sequence(parts): return parts.allSatisfy { unique($0, depth: depth + 1) }
            case let .block(index, exits):
                return occurrences.insert(index).inserted
                    && exits.allSatisfy { unique($0, depth: depth + 1) }
            case let .scope(_, body), let .loop(_, body): return unique(body, depth: depth + 1)
            case .breakTo, .continueAt: return true
            }
        }
        guard unique(root, depth: 0), occurrences == Set(cfg.blocks.indices) else { return nil }
        let folder = PrivateArmFolder(cfg: cfg)
        let prefixCandidate = folder.rewrite(root)
        let folded = recoveryIsEquivalent(prefixCandidate, to: cfg) ? prefixCandidate : root
        return folder.foldNoncontiguousArms(folded)
    }

    private struct PrivateArmFolder {
        let cfg: CFG
        /// Natural loop bodies by header, the innermost header of each block and
        /// every backedge source. Used only to keep folds inside one loop body.
        private let loopBodies: [Int: Set<Int>]
        private let innermostHeader: [Int: Int]
        private let backedgeSources: Set<Int>

        init(cfg: CFG) {
            self.cfg = cfg
            var bodies: [Int: Set<Int>] = [:]
            for edge in cfg.backEdges {
                var body: Set<Int> = [edge.to, edge.from]
                var pending = edge.from == edge.to ? [] : [edge.from]
                while let block = pending.popLast() {
                    for predecessor in cfg.blocks[block].predecessors where predecessor != edge.to {
                        if body.insert(predecessor).inserted { pending.append(predecessor) }
                    }
                }
                bodies[edge.to, default: []].formUnion(body)
            }
            var innermost: [Int: Int] = [:]
            for (header, body) in bodies.sorted(by: { $0.key < $1.key }) {
                for block in body {
                    if let current = innermost[block], let existing = bodies[current],
                       existing.count <= body.count { continue }
                    innermost[block] = header
                }
            }
            loopBodies = bodies
            innermostHeader = innermost
            backedgeSources = Set(cfg.backEdges.map(\.from))
        }

        /// An arm may move only within the loop body of the branch that owns it:
        /// all of its blocks share that innermost loop and none is a header,
        /// a backedge source or a source of an edge leaving the loop.
        private func armStaysInLoopBody(_ members: Set<Int>, owner: Int) -> Bool {
            let loop = innermostHeader[owner]
            return members.allSatisfy { member in
                guard innermostHeader[member] == loop else { return false }
                guard let loop else { return true }
                return member != loop && loopBodies[member] == nil
                    && !backedgeSources.contains(member)
                    && cfg.blocks[member].successors.allSatisfy { loopBodies[loop]?.contains($0) == true }
            }
        }

        func rewrite(_ node: RecoveryRegion) -> RecoveryRegion {
            switch node {
            case let .sequence(children):
                var parts = children.map(rewrite)
                var index = 0
                while index + 1 < parts.count {
                    defer { index += 1 }
                    guard case let .block(block, originalExits) = parts[index],
                          originalExits.count == 2 else { continue }
                    let emptyArms = originalExits.indices.filter { isEmpty(originalExits[$0]) }
                    guard emptyArms.count == 1, let arm = emptyArms.first,
                          let entry = firstBlock(parts[index + 1]),
                          cfg.blocks[block].successors[arm] == entry else { continue }
                    var members = Set<Int>(), prefixEnd: Int?
                    for end in (index + 1)..<parts.count {
                        guard collect(parts[end], into: &members),
                              !members.contains(cfg.blocks[block].successors[1 - arm]) else { break }
                        let privateEntry = members.allSatisfy { member in
                            cfg.blocks[member].predecessors.allSatisfy { predecessor in
                                members.contains(predecessor) || (member == entry && predecessor == block)
                            }
                        }
                        if privateEntry { prefixEnd = end }
                    }
                    guard let end = prefixEnd, !members.isEmpty else { continue }
                    var armMembers = Set<Int>()
                    for part in parts[(index + 1)...end] { _ = collect(part, into: &armMembers) }
                    guard armStaysInLoopBody(armMembers, owner: block) else { continue }
                    var exits = originalExits
                    let prefix = Array(parts[(index + 1)...end])
                    exits[arm] = prefix.count == 1 ? prefix[0] : .sequence(prefix)
                    parts[index] = .block(block, exits: exits)
                    parts.removeSubrange((index + 1)...end)
                }
                return .sequence(parts)
            case let .block(block, exits):
                return .block(block, exits: exits.map(rewrite))
            case let .scope(target, body):
                return .scope(target: target, body: rewrite(body))
            case let .loop(header, body):
                // Only the body is rewritten; the header, backedges and exits
                // keep their lexical form, and arms never contain a loop.
                return .loop(header: header, body: rewrite(body))
            case .breakTo, .continueAt:
                return node
            }
        }

        /// A private handler need not be the next lexical sibling: switch
        /// handlers can be separated by other arms and their binding scopes.
        /// Move its existing payload once into its sole incoming branch edge.
        /// Existing bindings must still prove every outgoing route; otherwise
        /// retain the previous plan rather than introducing a new scope grammar.
        /// Natural fallthrough exits stay empty; they never acquire a break.
        func foldNoncontiguousArms(_ root: RecoveryRegion) -> RecoveryRegion {
            var result = root
            for entry in cfg.blocks.indices {
                let predecessors = Set(cfg.blocks[entry].predecessors)
                guard predecessors.count == 1, let predecessor = predecessors.first,
                      cfg.blocks[predecessor].successors.count >= 2,
                      cfg.blocks[predecessor].successors.filter({ $0 == entry }).count == 1,
                      let arm = cfg.blocks[predecessor].successors.firstIndex(of: entry),
                      let payload = block(entry, in: result),
                      let owner = block(predecessor, in: result),
                      case let .block(_, exits) = owner,
                      isEmpty(exits[arm]) || isBreak(exits[arm], to: entry) else { continue }
                var members = Set<Int>()
                guard collect(payload, into: &members), !members.contains(predecessor),
                      armStaysInLoopBody(members, owner: predecessor),
                      members.allSatisfy({ member in
                          cfg.blocks[member].predecessors.allSatisfy { incoming in
                              members.contains(incoming) || (member == entry && incoming == predecessor)
                          }
                      }) else { continue }
                let candidate = relocate(result, entry: entry, predecessor: predecessor,
                                         arm: arm, payload: payload)
                if RegionTree.recoveryIsEquivalent(candidate, to: cfg) { result = candidate }
            }
            return result
        }

        private func block(_ target: Int, in node: RecoveryRegion) -> RecoveryRegion? {
            switch node {
            case let .block(index, exits):
                if index == target { return node }
                for exit in exits {
                    if let found = block(target, in: exit) { return found }
                }
            case let .sequence(parts):
                for part in parts {
                    if let found = block(target, in: part) { return found }
                }
            case let .scope(_, body), let .loop(_, body): return block(target, in: body)
            case .breakTo, .continueAt: break
            }
            return nil
        }

        private func isBreak(_ node: RecoveryRegion, to target: Int) -> Bool {
            if case let .breakTo(destination) = node { return destination == target }
            return false
        }

        private func relocate(_ node: RecoveryRegion, entry: Int, predecessor: Int,
                              arm: Int, payload: RecoveryRegion) -> RecoveryRegion {
            switch node {
            case let .block(index, exits):
                if index == entry { return .sequence([]) }
                var moved = exits.map { relocate($0, entry: entry, predecessor: predecessor,
                                                 arm: arm, payload: payload) }
                if index == predecessor { moved[arm] = payload }
                return .block(index, exits: moved)
            case let .sequence(parts):
                return .sequence(parts.map { relocate($0, entry: entry, predecessor: predecessor,
                                                       arm: arm, payload: payload) })
            case let .scope(target, body):
                return .scope(target: target, body: relocate(body, entry: entry, predecessor: predecessor,
                                                            arm: arm, payload: payload))
            case let .loop(header, body):
                return .loop(header: header, body: relocate(body, entry: entry, predecessor: predecessor,
                                                            arm: arm, payload: payload))
            case .breakTo, .continueAt: return node
            }
        }

        private func isEmpty(_ node: RecoveryRegion) -> Bool {
            if case let .sequence(parts) = node { return parts.allSatisfy(isEmpty) }
            return false
        }

        private func firstBlock(_ node: RecoveryRegion) -> Int? {
            switch node {
            case let .block(block, _): return block
            case let .scope(_, body): return firstBlock(body)
            case let .sequence(parts):
                for part in parts {
                    if isEmpty(part) { continue }
                    return firstBlock(part)
                }
                return nil
            case .loop, .breakTo, .continueAt: return nil
            }
        }

        private func collect(_ node: RecoveryRegion, into members: inout Set<Int>) -> Bool {
            switch node {
            case let .sequence(parts): return parts.allSatisfy { collect($0, into: &members) }
            case let .block(block, exits):
                return members.insert(block).inserted
                    && exits.allSatisfy { collect($0, into: &members) }
            case let .scope(_, body): return collect(body, into: &members)
            case .breakTo: return true
            case .loop, .continueAt: return false
            }
        }
    }

    /// Simplification is only a presentation proposal. Prove the input first,
    /// and retain that proven plan if the proposal fails the same full check.
    static func simplifiedRecovery(_ root: RecoveryRegion, to cfg: CFG) -> RecoveryRegion? {
        guard recoveryIsEquivalent(root, to: cfg) else { return nil }
        let candidate = RecoverySimplifier().rewrite(root, fallthrough: [])
        return recoveryIsEquivalent(candidate, to: cfg) ? candidate : root
    }

    private struct RecoverySimplifier {
        enum Transfer: Hashable {
            case breakTo(Int)
            case continueAt(Int)
        }

        /// These are bound transfers known to arrive at this exact lexical
        /// continuation. Entering a loop replaces, rather than inherits, them.
        func rewrite(_ node: RecoveryRegion, fallthrough tail: Set<Transfer>) -> RecoveryRegion {
            switch node {
            case .sequence(let parts):
                var suffix: [RecoveryRegion] = []
                for part in parts.reversed() {
                    let rewritten = rewrite(part, fallthrough: suffix.isEmpty ? tail : [])
                    for item in children(of: rewritten).reversed() {
                        // A guard that jumps to the end of this sequence can
                        // instead contain the remaining sequence in its other
                        // arm. Move that suffix exactly once, never duplicate it.
                        if !suffix.isEmpty, case .block(let index, var exits) = item,
                           exits.count == 2,
                           let arm = exits.indices.first(where: {
                               transfer(exits[$0]).map { tail.contains($0) } == true
                                   && children(of: exits[1 - $0]).isEmpty
                           }) {
                            exits[arm] = .sequence([])
                            exits[1 - arm] = sequence(suffix)
                            suffix = [.block(index, exits: exits)]
                        } else {
                            suffix.insert(item, at: 0)
                        }
                    }
                }
                return sequence(suffix)
            case .block(let index, let exits):
                return .block(index, exits: exits.map { rewrite($0, fallthrough: tail) })
            case .scope(let target, let body):
                let rewritten = rewrite(body, fallthrough: tail.union([.breakTo(target)]))
                let parts = children(of: rewritten)
                guard let firstUse = parts.firstIndex(where: { containsBreak(to: target, in: $0) }) else {
                    return rewritten
                }
                // A one-shot scope has no execution effect before its first
                // reference. Keep its bound transfers inside while allowing the
                // leading statements to print at their enclosing indentation.
                let scoped = RecoveryRegion.scope(target: target, body: sequence(Array(parts[firstUse...])))
                return sequence(Array(parts[..<firstUse]) + [scoped])
            case .loop(let header, let body):
                return .loop(header: header, body: rewrite(body, fallthrough: [.continueAt(header)]))
            case .breakTo(let target):
                return tail.contains(.breakTo(target)) ? .sequence([]) : node
            case .continueAt(let header):
                return tail.contains(.continueAt(header)) ? .sequence([]) : node
            }
        }

        private func children(of node: RecoveryRegion) -> [RecoveryRegion] {
            if case .sequence(let parts) = node { return parts }
            return [node]
        }

        private func sequence(_ parts: [RecoveryRegion]) -> RecoveryRegion {
            parts.count == 1 ? parts[0] : .sequence(parts)
        }

        private func transfer(_ node: RecoveryRegion) -> Transfer? {
            switch node {
            case .breakTo(let target): return .breakTo(target)
            case .continueAt(let header): return .continueAt(header)
            default: return nil
            }
        }

        private func containsBreak(to target: Int, in node: RecoveryRegion) -> Bool {
            switch node {
            case .sequence(let parts): return parts.contains { containsBreak(to: target, in: $0) }
            case .block(_, let exits): return exits.contains { containsBreak(to: target, in: $0) }
            case .scope(_, let body), .loop(_, let body): return containsBreak(to: target, in: body)
            case .breakTo(let destination): return destination == target
            case .continueAt: return false
            }
        }
    }

    /// Re-extract a control-flow graph from the emitted grammar. Eliminate only
    /// structural epsilon edges, then check the ordered successor projection at
    /// EVERY emitted block occurrence. Together with identical block payloads,
    /// this is a strong bisimulation (not a finite path-depth approximation).
    /// It covers termination and infinite loops, and permits mutually exclusive
    /// duplicates while rejecting dropped/reordered visits and wrong loop exits.
    static func recoveryIsEquivalent(_ root: RecoveryRegion, to cfg: CFG) -> Bool {
        struct Vertex {
            var original: Int?
            var next: [Int]
        }
        var graph = [Vertex(original: nil, next: [])] // explicit end-of-function
        enum ExtractionError: Error { case malformed }
        var budget = 8192
        func add(_ original: Int?, _ next: [Int]) -> Int {
            let id = graph.count
            graph.append(Vertex(original: original, next: next))
            return id
        }
        func extract(_ region: RecoveryRegion, next: Int,
                     breaks: [Int: Int], continues: [Int: Int], depth: Int) throws -> Int {
            budget -= 1
            guard budget >= 0, depth <= 256 else { throw ExtractionError.malformed }
            switch region {
            case .sequence(let children):
                var cursor = next
                for child in children.reversed() {
                    cursor = try extract(child, next: cursor, breaks: breaks,
                                     continues: continues, depth: depth + 1)
                }
                return cursor
            case .block(let original, let exits):
                guard cfg.blocks.indices.contains(original),
                      exits.count == cfg.blocks[original].successors.count else {
                    throw ExtractionError.malformed
                }
                return add(original, try exits.map {
                    try extract($0, next: next, breaks: breaks, continues: continues, depth: depth + 1)
                })
            case .scope(let target, let body):
                guard breaks[target] == nil else { throw ExtractionError.malformed }
                var environment = breaks
                environment[target] = next
                return try extract(body, next: next, breaks: environment,
                               continues: continues, depth: depth + 1)
            case .loop(let header, let body):
                guard continues[header] == nil else { throw ExtractionError.malformed }
                let start = add(nil, [])
                var environment = continues
                environment[header] = start
                let bodyStart = try extract(body, next: start, breaks: breaks,
                                        continues: environment, depth: depth + 1)
                graph[start].next = [bodyStart]
                return start
            case .breakTo(let target):
                guard let destination = breaks[target] else { throw ExtractionError.malformed }
                return destination
            case .continueAt(let header):
                guard let destination = continues[header] else { throw ExtractionError.malformed }
                return destination
            }
        }
        guard let entry = try? extract(root, next: 0, breaks: [:], continues: [:], depth: 0) else { return false }
        func event(after start: Int) -> Int? {
            var cursor = start, seen = Set<Int>()
            while graph[cursor].original == nil {
                guard seen.insert(cursor).inserted, graph[cursor].next.count == 1 else { return nil }
                cursor = graph[cursor].next[0]
            }
            return cursor
        }
        guard let first = event(after: entry), graph[first].original == cfg.entryIndex else { return false }
        var visited = Set<Int>(), originals = Set<Int>(), pending = [first]
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let original = graph[id].original else { continue }
            originals.insert(original)
            let expected = cfg.blocks[original].successors
            guard graph[id].next.count == expected.count else { return false }
            for (edge, target) in zip(graph[id].next, expected) {
                guard let next = event(after: edge), graph[next].original == target else { return false }
                pending.append(next)
            }
        }
        let payloads = Set(graph.indices.filter { graph[$0].original != nil })
        return visited == payloads && originals == Set(cfg.blocks.indices)
    }

    private struct RecoveryBuilder {
        enum Failure: Error { case unsupported }
        let cfg: CFG
        let instructions: [MacIRInstruction]
        let options: DecompilerOptions
        let needsTail: Bool
        var certifiedSwitches: [Int: RegionalPhysicalStatePlan.SwitchDispatch] = [:]
        var certifiedConditions: [Int: MacIROperation] = [:]
        var originalSwitches: [Int: MacIROperation] = [:]
        var preservesFallthroughChains = false
        var loops: [Int: Set<Int>] = [:]
        var parent: [Int: Int] = [:]
        var duplicates = Set<Int>()
        var extra = 0

        mutating func build() throws -> (RecoveryRegion, Set<Int>, Int) {
            guard !cfg.blocks.isEmpty, cfg.blocks.count <= 512,
                  !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty else { throw Failure.unsupported }
            var reached = Set<Int>(), work = [cfg.entryIndex]
            while let block = work.popLast() {
                guard cfg.blocks.indices.contains(block) else { throw Failure.unsupported }
                if reached.insert(block).inserted { work += cfg.blocks[block].successors }
            }
            guard reached.count == cfg.blocks.count else { throw Failure.unsupported }
            var consumedSwitches = Set<Int>(), consumedConditions = Set<Int>()
            var consumedOriginalSwitches = Set<Int>()
            for block in cfg.blocks {
                guard block.startIndex < block.endIndex,
                      instructions.indices.contains(block.endIndex - 1) else { throw Failure.unsupported }
                let last = block.endIndex - 1, operation = instructions[last].operation
                if case .switchDispatch = CFGBuilder.terminatorKind(of: operation) {
                    if let original = originalSwitches[last] {
                        guard !needsTail, certifiedSwitches.isEmpty, certifiedConditions.isEmpty,
                              case .switchDispatch = operation, operation == original,
                              !block.successors.isEmpty else { throw Failure.unsupported }
                        consumedOriginalSwitches.insert(last)
                    } else {
                        guard let dispatch = certifiedSwitches[last], !needsTail,
                              dispatch.originalOperation == operation,
                              dispatch.successorBlocks == block.successors,
                              !block.successors.isEmpty else { throw Failure.unsupported }
                        consumedSwitches.insert(last)
                    }
                } else {
                    guard certifiedSwitches[last] == nil,
                          block.successors.count <= 2 else { throw Failure.unsupported }
                    switch CFGBuilder.terminatorKind(of: operation) {
                    case .conditionalBranch:
                        guard block.successors.count == 2 else { throw Failure.unsupported }
                        if case .conditionalBranch = operation {
                            guard certifiedConditions[last] == nil else { throw Failure.unsupported }
                        } else {
                            guard !needsTail, certifiedConditions[last] == operation else { throw Failure.unsupported }
                            consumedConditions.insert(last)
                        }
                    case .none:
                        // An implicit function exit is not an executable return.
                        guard block.successors.count == 1 else { throw Failure.unsupported }
                    default: break
                    }
                }
            }
            guard consumedSwitches == Set(certifiedSwitches.keys),
                  consumedConditions == Set(certifiedConditions.keys),
                  consumedOriginalSwitches == Set(originalSwitches.keys) else { throw Failure.unsupported }
            for edge in cfg.backEdges {
                var body: Set<Int> = [edge.to, edge.from]
                var pending = edge.from == edge.to ? [] : [edge.from]
                while let block = pending.popLast() {
                    for predecessor in cfg.blocks[block].predecessors where predecessor != edge.to {
                        if body.insert(predecessor).inserted { pending.append(predecessor) }
                    }
                }
                guard body.allSatisfy({ dominates(header: edge.to, block: $0) }) else { throw Failure.unsupported }
                loops[edge.to, default: []].formUnion(body)
            }
            let headers = loops.keys.sorted()
            for h in headers {
                for other in headers where h != other {
                    let a = loops[h]!, b = loops[other]!
                    guard a.isDisjoint(with: b) || a.isStrictSubset(of: b) || b.isStrictSubset(of: a) else {
                        throw Failure.unsupported
                    }
                }
                parent[h] = headers.filter { h != $0 && loops[h]!.isStrictSubset(of: loops[$0]!) }
                    .min { loops[$0]!.count < loops[$1]!.count }
            }
            if needsTail { try selectTails() }
            let root = try scope(nil, ancestors: [])
            return (root, duplicates, extra)
        }

        func dominates(header: Int, block: Int) -> Bool {
            var cursor = block, seen = Set<Int>()
            while seen.insert(cursor).inserted {
                if cursor == header { return true }
                guard let next = cfg.domTree[cursor], next != cursor else { return false }
                cursor = next
            }
            return false
        }

        mutating func selectTails() throws {
            let cyclic = loops.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
            func arm(_ start: Int, stop: Int) -> Set<Int> {
                var seen = Set<Int>(), stack = [start]
                while let block = stack.popLast() {
                    guard block != stop, seen.insert(block).inserted else { continue }
                    stack += cfg.blocks[block].successors
                }
                return seen
            }
            for branch in cfg.blocks where branch.successors.count == 2 {
                guard let join = cfg.postDomTree[branch.index], join != branch.index,
                      cfg.blocks.indices.contains(join) else { continue }
                let shared = arm(branch.successors[0], stop: join)
                    .intersection(arm(branch.successors[1], stop: join))
                guard !shared.isEmpty else { continue }
                // Refuse to substitute labels for an oversized tail. This path
                // is admitted only when the entire shared region is bounded,
                // acyclic, single-successor and outside every natural loop.
                let cost = shared.reduce(0) { $0 + cfg.blocks[$1].instructionRange.count }
                guard shared.isDisjoint(with: cyclic), cost <= options.sharedTailInstructionLimit,
                      shared.allSatisfy({ cfg.blocks[$0].successors.count == 1 }) else {
                    throw Failure.unsupported
                }
                duplicates.formUnion(shared)
            }
            guard !duplicates.isEmpty, !duplicates.contains(cfg.entryIndex) else { throw Failure.unsupported }
            // Count copies reaching each selected block, including internal
            // chains, rather than bounding only the number of selected nodes.
            var counts: [Int: Int] = [:], pending = duplicates
            while !pending.isEmpty {
                guard let block = pending.sorted().first(where: { b in
                    cfg.blocks[b].predecessors.allSatisfy { !pending.contains($0) }
                }) else { throw Failure.unsupported }
                var count = 0
                for pred in cfg.blocks[block].predecessors {
                    count += duplicates.contains(pred) ? (counts[pred] ?? 0) : 1
                    guard count <= 64 else { throw Failure.unsupported }
                }
                counts[block] = count
                extra += max(0, count - 1) * cfg.blocks[block].instructionRange.count
                guard extra <= 64 else { throw Failure.unsupported }
                pending.remove(block)
            }
        }

        func destination(_ start: Int) throws -> Int {
            var next = start, seen = Set<Int>()
            while duplicates.contains(next) {
                guard seen.insert(next).inserted, let successor = cfg.blocks[next].successors.first else {
                    throw Failure.unsupported
                }
                next = successor
            }
            return next
        }

        /// Collapse immediate child loops and topologically order the remaining
        /// acyclic atoms. Forward edges are lexical breaks; backedges are lexical
        /// continues. An edge leaving several loops breaks the enclosing target
        /// scope, not whichever loop happens to be innermost.
        func scope(_ header: Int?, ancestors: [Int]) throws -> RecoveryRegion {
            guard ancestors.count <= 64 else { throw Failure.unsupported }
            let universe = header.flatMap { loops[$0] } ?? Set(cfg.blocks.indices)
            let active = ancestors + (header.map { [$0] } ?? [])
            let children = loops.keys.filter { parent[$0] == header }.sorted()
            var owner: [Int: Int] = [:], atoms = universe.subtracting(duplicates)
            for child in children {
                for block in loops[child]! { owner[block] = child; atoms.remove(block) }
                atoms.insert(child)
            }
            for block in atoms where owner[block] == nil { owner[block] = block }
            var edges: [Int: Set<Int>] = [:]
            for atom in atoms {
                let blocks = children.contains(atom) ? loops[atom]! : [atom]
                for block in blocks {
                    for target in cfg.blocks[block].successors {
                        let target = try destination(target)
                        if active.contains(target) { continue }
                        guard universe.contains(target) else { continue }
                        guard let to = owner[target] else { throw Failure.unsupported }
                        if to == atom {
                            guard children.contains(atom) else { throw Failure.unsupported }
                            continue
                        }
                        guard to == target else { throw Failure.unsupported } // no mid-loop entry
                        edges[atom, default: []].insert(to)
                    }
                }
            }
            // A physical fallthrough cannot acquire a synthetic transfer.
            // Schedule its whole chain only when every external incoming edge
            // is ready; explicit branches may still enter interior members.
            var chainNext: [Int: Int] = [:], chainPrevious: [Int: Int] = [:]
            if preservesFallthroughChains {
                for atom in atoms where !children.contains(atom) {
                    let block = cfg.blocks[atom]
                    guard CFGBuilder.terminatorKind(of: instructions[block.endIndex - 1].operation) == .none,
                          block.successors.count == 1 else { continue }
                    let target = block.successors[0]
                    guard atoms.contains(target), owner[target] == target,
                          edges[atom]?.contains(target) == true else { throw Failure.unsupported }
                    guard chainPrevious.updateValue(atom, forKey: target) == nil else { throw Failure.unsupported }
                    chainNext[atom] = target
                }
            }
            var chains: [Int: [Int]] = [:], chainOwner: [Int: Int] = [:]
            for start in atoms.sorted() where chainPrevious[start] == nil {
                var cursor: Int? = start
                while let atom = cursor {
                    guard chainOwner.updateValue(start, forKey: atom) == nil else { throw Failure.unsupported }
                    chains[start, default: []].append(atom)
                    cursor = chainNext[atom]
                }
            }
            guard chainOwner.count == atoms.count else { throw Failure.unsupported }
            var chainEdges: [Int: Set<Int>] = [:]
            for (atom, successors) in edges {
                for target in successors where chainOwner[atom] != chainOwner[target] {
                    chainEdges[chainOwner[atom]!, default: []].insert(chainOwner[target]!)
                }
            }
            var indegree = Dictionary(uniqueKeysWithValues: chains.keys.map { ($0, 0) })
            for successors in chainEdges.values { for target in successors { indegree[target, default: 0] += 1 } }
            var ready = chains.keys.filter { indegree[$0] == 0 }.sorted(), order: [Int] = []
            while !ready.isEmpty {
                let atom = ready.removeFirst(); order += chains[atom]!
                for target in (chainEdges[atom] ?? []).sorted() {
                    indegree[target]! -= 1
                    if indegree[target] == 0 { ready.append(target); ready.sort() }
                }
            }
            guard order.count == atoms.count, order.first == (header ?? cfg.entryIndex) else { throw Failure.unsupported }
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            var starts: [Int: Int] = [:]
            for (i, atom) in order.enumerated() {
                for target in edges[atom] ?? [] {
                    guard let j = position[target], j > i else { throw Failure.unsupported }
                    if children.contains(atom) || j != i + 1 { starts[j] = min(starts[j] ?? i, i) }
                }
            }
            // Turn crossing forward intervals into a laminar family. This
            // widens only scopes, never the execution range of their blocks.
            for j in starts.keys.sorted() {
                var start = starts[j]!
                var changed = true
                while changed {
                    changed = false
                    for k in starts.keys.sorted() where k < j && start < k && starts[k]! < start {
                        start = starts[k]!; changed = true
                    }
                }
                starts[j] = start
            }
            func route(_ target: Int, next: Int?) throws -> RecoveryRegion {
                if duplicates.contains(target) {
                    let successor = cfg.blocks[target].successors[0]
                    return .block(target, exits: [try route(successor, next: next)])
                }
                if active.contains(target) { return .continueAt(target) }
                if target == next { return .sequence([]) }
                return .breakTo(target)
            }
            var nodes: [RecoveryRegion] = []
            for (i, atom) in order.enumerated() {
                if children.contains(atom) {
                    nodes.append(.loop(header: atom, body: try scope(atom, ancestors: active)))
                } else {
                    let next = i + 1 < order.count ? order[i + 1] : nil
                    nodes.append(.block(atom, exits: try cfg.blocks[atom].successors.map { try route($0, next: next) }))
                }
            }
            // Assemble lexical scopes with explicit nesting, closing immediately
            // before the destination block. A break thus projects to that block.
            var stack: [(end: Int, nodes: [RecoveryRegion])] = [(order.count, [])]
            for i in 0...order.count {
                while stack.count > 1, stack.last!.end == i {
                    let completed = stack.removeLast()
                    stack[stack.count - 1].nodes.append(.scope(target: order[i], body: .sequence(completed.nodes)))
                }
                if i == order.count { break }
                for end in starts.keys.filter({ starts[$0] == i }).sorted(by: >) {
                    guard end <= stack.last!.end else { throw Failure.unsupported }
                    stack.append((end, []))
                }
                stack[stack.count - 1].nodes.append(nodes[i])
            }
            guard stack.count == 1 else { throw Failure.unsupported }
            return .sequence(stack[0].nodes)
        }
    }
}
